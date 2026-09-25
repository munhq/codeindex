//! Drift between the tables migrations create and the tables code uses.
//!
//! Two questions, each about the whole repository:
//!
//!   orphan_migration   a table the migrations leave standing that no code
//!                      file names
//!   missing_migration  a model an SQL ORM maps to a table that no migration
//!                      creates
//!
//! A model counts only on positive evidence that an SQL database backs it: an
//! ORM attribute that names a table, or a table name in a file that imports an
//! SQL library. A LanceDB table also has a `tableName`, and it creates itself
//! at connect time; reported as schema drift, it reached a task board as a
//! high-priority card.

const std = @import("std");
const explorer = @import("../index/explorer.zig");
const models = @import("../core/models.zig");

pub const TableDef = struct {
    name: []const u8,
    source: enum { migration, code },
    file: []const u8,
    line: usize,
};

pub const IssueType = enum { orphan_migration, missing_migration };

pub const SchemaIssue = struct {
    table: []const u8,
    issue_type: IssueType,
    description: []const u8,
    file: []const u8,
    line: usize,
};

pub const Report = struct {
    /// Tables the migrations leave standing after every drop and rename.
    tables_in_migrations: usize,
    tables_in_code: usize,
    /// Files that define schema: migrations and `.sql` files.
    migration_files: usize,
    issues: []SchemaIssue,
};

// ── Migrations ───────────────────────────────────────────────────────────────

/// A file that defines schema: anything under a directory whose name holds
/// `migration` (`migrations/`, and Rails' `db/migrate`), and a `.sql` file that
/// creates a table. A `.sql` file of queries alone is code that uses tables.
fn is_schema_file(path: []const u8, content: []const u8) bool {
    if (in_migration_dir(path)) return true;
    return std.mem.endsWith(u8, path, ".sql") and std.ascii.indexOfIgnoreCase(content, "create table") != null;
}

fn in_migration_dir(path: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (std.mem.indexOf(u8, seg, "migration") != null) return true;
        if (std.mem.eql(u8, seg, "migrate") or std.mem.eql(u8, seg, "alembic")) return true;
    }
    return false;
}

const Event = struct {
    kind: enum { create, drop, rename },
    name: []const u8,
    /// `rename` only: the new name.
    to: []const u8 = "",
    file: []const u8,
    line: usize,
};

fn ident_char(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
}

/// The next word of `s` from `i`, case-folded comparison against `word`.
fn word_at(s: []const u8, i: usize, word: []const u8) bool {
    if (i + word.len > s.len) return false;
    if (!std.ascii.eqlIgnoreCase(s[i .. i + word.len], word)) return false;
    if (i > 0 and ident_char(s[i - 1])) return false;
    if (i + word.len < s.len and ident_char(s[i + word.len])) return false;
    return true;
}

fn skip_space(s: []const u8, i_in: usize) usize {
    var i = i_in;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\n' or s[i] == '\r')) i += 1;
    return i;
}

/// A table name at `i`: bare, quoted with `"`, `` ` `` or `[]`, and schema
/// qualified. The last part is the table. Returns it and the index after it.
fn table_name_at(s: []const u8, i_in: usize) ?struct { name: []const u8, end: usize } {
    var i = i_in;
    var last: []const u8 = "";
    while (true) {
        i = skip_space(s, i);
        if (i >= s.len) break;
        const open = s[i];
        if (open == '"' or open == '`' or open == '[') {
            const close: u8 = if (open == '[') ']' else open;
            const start = i + 1;
            const end = std.mem.indexOfScalarPos(u8, s, start, close) orelse return null;
            last = s[start..end];
            i = end + 1;
        } else {
            const start = i;
            while (i < s.len and ident_char(s[i])) i += 1;
            if (i == start) break;
            last = s[start..i];
        }
        if (i < s.len and s[i] == '.') {
            i += 1;
            continue;
        }
        break;
    }
    if (last.len == 0) return null;
    return .{ .name = last, .end = i };
}

fn line_of(s: []const u8, at: usize) usize {
    return std.mem.count(u8, s[0..at], "\n") + 1;
}

/// `CREATE [OR REPLACE] [TEMP | TEMPORARY | UNLOGGED] TABLE [IF NOT EXISTS] x`,
/// `DROP TABLE [IF EXISTS] a, b` and `ALTER TABLE a RENAME TO b`, one event per
/// statement wherever it sits on its line.
fn sql_events(allocator: std.mem.Allocator, path: []const u8, s: []const u8, out: *std.ArrayList(Event)) !void {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        // Skip `--` comments.
        if (s[i] == '-' and i + 1 < s.len and s[i + 1] == '-') {
            i = std.mem.indexOfScalarPos(u8, s, i, '\n') orelse s.len;
            continue;
        }
        if (word_at(s, i, "create")) {
            var j = skip_space(s, i + 6);
            if (word_at(s, j, "or")) {
                j = skip_space(s, j + 2);
                if (word_at(s, j, "replace")) j = skip_space(s, j + 7);
            }
            var temporary = false;
            for ([_][]const u8{ "temporary", "temp", "unlogged", "global", "local" }) |w| {
                if (word_at(s, j, w)) {
                    if (!std.mem.eql(u8, w, "unlogged")) temporary = true;
                    j = skip_space(s, j + w.len);
                }
            }
            if (!word_at(s, j, "table")) continue;
            j = skip_space(s, j + 5);
            if (word_at(s, j, "if")) {
                j = skip_space(s, j + 2);
                if (word_at(s, j, "not")) j = skip_space(s, j + 3);
                if (word_at(s, j, "exists")) j = skip_space(s, j + 6);
            }
            const t = table_name_at(s, j) orelse continue;
            // `fleet_events_%s` in a format string is a name template.
            const templated = t.end < s.len and (s[t.end] == '%' or s[t.end] == '{' or s[t.end] == '$');
            // A partition holds the parent's rows, and code reaches it
            // through the parent: `CREATE TABLE e_default PARTITION OF e`.
            const after = skip_space(s, t.end);
            const partition = word_at(s, after, "partition");
            if (!temporary and !templated and !partition) try out.append(allocator, .{ .kind = .create, .name = t.name, .file = path, .line = line_of(s, i) });
            i = t.end;
        } else if (word_at(s, i, "drop")) {
            var j = skip_space(s, i + 4);
            if (!word_at(s, j, "table")) continue;
            j = skip_space(s, j + 5);
            if (word_at(s, j, "if")) {
                j = skip_space(s, j + 2);
                if (word_at(s, j, "exists")) j = skip_space(s, j + 6);
            }
            while (table_name_at(s, j)) |t| {
                try out.append(allocator, .{ .kind = .drop, .name = t.name, .file = path, .line = line_of(s, i) });
                j = skip_space(s, t.end);
                if (j < s.len and s[j] == ',') {
                    j += 1;
                    continue;
                }
                break;
            }
            i = j;
        } else if (word_at(s, i, "alter")) {
            var j = skip_space(s, i + 5);
            if (!word_at(s, j, "table")) continue;
            j = skip_space(s, j + 5);
            if (word_at(s, j, "if")) {
                j = skip_space(s, j + 2);
                if (word_at(s, j, "exists")) j = skip_space(s, j + 6);
            }
            const from = table_name_at(s, j) orelse continue;
            j = skip_space(s, from.end);
            if (!word_at(s, j, "rename")) continue;
            j = skip_space(s, j + 6);
            if (!word_at(s, j, "to")) continue;
            const to = table_name_at(s, j + 2) orelse continue;
            try out.append(allocator, .{ .kind = .rename, .name = from.name, .to = to.name, .file = path, .line = line_of(s, i) });
            i = to.end;
        }
    }
}

/// The first string literal after `at`, or a Ruby `:symbol`.
fn string_after(s: []const u8, at: usize) ?[]const u8 {
    var i = at;
    while (i < s.len and s[i] != '\n') : (i += 1) {
        const c = s[i];
        if (c == '"' or c == '\'') {
            const end = std.mem.indexOfScalarPos(u8, s, i + 1, c) orelse return null;
            return s[i + 1 .. end];
        }
        if (c == ':' and i + 1 < s.len and std.ascii.isAlphabetic(s[i + 1])) {
            var e = i + 1;
            while (e < s.len and ident_char(s[e])) e += 1;
            return s[i + 1 .. e];
        }
    }
    return null;
}

/// Migration frameworks that create tables through a call: Django,
/// Rails, Alembic, Knex and Sequelize.
fn framework_events(allocator: std.mem.Allocator, path: []const u8, s: []const u8, out: *std.ArrayList(Event)) !void {
    const Form = struct { marker: []const u8, kind: @TypeOf(@as(Event, undefined).kind), name_key: ?[]const u8 = null };
    const forms = [_]Form{
        .{ .marker = "migrations.CreateModel(", .kind = .create, .name_key = "name" },
        .{ .marker = "migrations.DeleteModel(", .kind = .drop, .name_key = "name" },
        .{ .marker = "create_table", .kind = .create },
        .{ .marker = "drop_table", .kind = .drop },
        .{ .marker = "createTable(", .kind = .create },
        .{ .marker = "dropTable(", .kind = .drop },
    };
    for (&forms) |f| {
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, s, pos, f.marker)) |at| {
            pos = at + f.marker.len;
            if (at > 0 and ident_char(s[at - 1]) and s[at - 1] != '.') continue;
            var from = pos;
            if (f.name_key) |key| {
                // Django names the model on a later line: `name='Invoice',`.
                const window_end = @min(s.len, pos + 400);
                const k = std.mem.indexOf(u8, s[pos..window_end], key) orelse continue;
                from = pos + k + key.len;
            }
            const name = string_after(s, from) orelse continue;
            if (name.len == 0) continue;
            try out.append(allocator, .{ .kind = f.kind, .name = name, .file = path, .line = line_of(s, at) });
        }
    }
}

// ── Code models ──────────────────────────────────────────────────────────────

/// Libraries that put a table in an SQL database. A `tableName` in a file
/// that imports one of these is an SQL table.
const sql_libraries = [_][]const u8{
    "sequelize",  "typeorm", "knex",   "objection", "mikro-orm",      "@mikro-orm", "drizzle-orm", "pg",
    "mysql",      "mysql2",  "sqlite", "sqlite3",   "better-sqlite3", "kysely",     "prisma",      "@prisma/client",
    "sqlalchemy", "gorm",    "diesel", "sea_orm",   "sqlx",
};

fn imports_sql_library(outline: models.FileOutline) bool {
    for (outline.imports) |imp| {
        for (&sql_libraries) |lib| {
            if (std.mem.eql(u8, imp, lib)) return true;
            if (std.mem.startsWith(u8, imp, lib) and imp.len > lib.len and (imp[lib.len] == '/' or imp[lib.len] == ':' or imp[lib.len] == '.')) return true;
        }
    }
    return false;
}

/// The struct or class a line at 1-based `line` belongs to or annotates: the
/// innermost one that contains it, else the first that starts within three
/// lines below (an attribute above its struct).
fn model_at(outline: models.FileOutline, line: usize) ?models.Symbol {
    var inside: ?models.Symbol = null;
    var below: ?models.Symbol = null;
    for (outline.symbols) |sym| {
        if (sym.kind != .@"struct" and sym.kind != .class) continue;
        if (sym.start_1() <= line and sym.end_1() >= line) {
            if (inside == null or sym.start_1() > inside.?.start_1()) inside = sym;
        } else if (sym.start_1() > line and sym.start_1() <= line + 3) {
            if (below == null or sym.start_1() < below.?.start_1()) below = sym;
        }
    }
    return inside orelse below;
}

/// An ORM model and the table it names. `table` is null when the ORM takes
/// the table name from the class.
const Model = struct { class: []const u8, table: ?[]const u8, file: []const u8, line: usize };

/// Hints that an SQL ORM maps the struct or class beside them to a table,
/// and whether the hint is evidence of SQL on its own.
const Hint = struct { text: []const u8, sql_by_itself: bool, names_table: bool };

const hints = [_]Hint{
    .{ .text = "#[diesel(table_name", .sql_by_itself = true, .names_table = true },
    .{ .text = "#[table_name", .sql_by_itself = true, .names_table = true },
    .{ .text = "#[sea_orm(table_name", .sql_by_itself = true, .names_table = true },
    .{ .text = "__tablename__", .sql_by_itself = true, .names_table = true },
    .{ .text = "db_table", .sql_by_itself = true, .names_table = true },
    .{ .text = "(models.Model)", .sql_by_itself = true, .names_table = false },
    .{ .text = "@Table(", .sql_by_itself = true, .names_table = true },
    .{ .text = "@Entity", .sql_by_itself = true, .names_table = false },
    .{ .text = "TableName() string", .sql_by_itself = false, .names_table = false },
    .{ .text = "tableName", .sql_by_itself = false, .names_table = true },
};

fn code_models(allocator: std.mem.Allocator, outline: models.FileOutline, content: []const u8, out: *std.ArrayList(Model)) !void {
    const sql_file = imports_sql_library(outline);
    var line_no: usize = 0;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |raw| {
        line_no += 1;
        const t = std.mem.trim(u8, raw, " \t\r");
        for (&hints) |h| {
            const at = std.mem.indexOf(u8, t, h.text) orelse continue;
            if (!h.sql_by_itself and !sql_file) break;
            const sym = model_at(outline, line_no) orelse break;
            var table: ?[]const u8 = if (h.names_table) string_after(t, at + h.text.len) else null;
            // `#[diesel(table_name = users)]` names it bare.
            if (h.names_table and table == null) {
                if (std.mem.indexOfScalarPos(u8, t, at, '=')) |eq| {
                    var s = eq + 1;
                    while (s < t.len and t[s] == ' ') s += 1;
                    var e = s;
                    while (e < t.len and ident_char(t[e])) e += 1;
                    if (e > s) table = t[s..e];
                }
            }
            // `@Entity("users")` and `@Entity({ name: "users" })`.
            if (!h.names_table and std.mem.eql(u8, h.text, "@Entity")) table = string_after(t, at + h.text.len);
            // gorm: `func (User) TableName() string { return "users" }`.
            if (std.mem.eql(u8, h.text, "TableName() string")) table = string_after(t, at + h.text.len);
            try out.append(allocator, .{ .class = sym.name, .table = table, .file = outline.path, .line = sym.start_1() });
            break;
        }
    }
}

// ── Matching ─────────────────────────────────────────────────────────────────

/// `user_profiles`, `UserProfile` and `userprofiles` compare equal: case and
/// separators are dropped, and one trailing `s` is.
fn normalize(name: []const u8, buf: []u8) []const u8 {
    var pos: usize = 0;
    for (name) |c| {
        if (c == '_' or c == '-') continue;
        if (pos < buf.len) {
            buf[pos] = std.ascii.toLower(c);
            pos += 1;
        }
    }
    if (pos > 1 and buf[pos - 1] == 's') pos -= 1;
    return buf[0..pos];
}

fn names_match(a: []const u8, b: []const u8) bool {
    var ab: [128]u8 = undefined;
    var bb: [128]u8 = undefined;
    return std.mem.eql(u8, normalize(a, &ab), normalize(b, &bb));
}

fn is_code_language(lang: models.Language) bool {
    return switch (lang) {
        .rust, .python, .go, .typescript, .javascript, .java, .kotlin, .ruby, .c_sharp, .php, .scala, .elixir, .sql => true,
        else => false,
    };
}

/// Whether a code file that defines no schema names the table as a word:
/// `FROM goals`, `"goals"`. An unquoted SQL name folds to one case, so the
/// lowercase spelling counts too.
fn referenced_by_code(exp: *explorer.Explorer, schema: *const std.AutoHashMap(u32, void), table: []const u8) bool {
    var buf: [128]u8 = undefined;
    const lower = if (table.len <= buf.len) std.ascii.lowerString(&buf, table) else table;
    for ([_][]const u8{ table, lower }) |word| {
        for (exp.words.search(word)) |fid| {
            if (exp.deleted_files.get(fid) != null or schema.contains(fid)) continue;
            const o = exp.outlines.get(fid) orelse continue;
            if (!is_code_language(o.language)) continue;
            return true;
        }
    }
    return false;
}

fn path_less(_: void, a: Event, b: Event) bool {
    const o = std.mem.order(u8, a.file, b.file);
    if (o != .eq) return o == .lt;
    return a.line < b.line;
}

pub fn analyze(allocator: std.mem.Allocator, exp: *explorer.Explorer) !Report {
    var events = std.ArrayList(Event).empty;
    defer events.deinit(allocator);
    var code = std.ArrayList(Model).empty;
    defer code.deinit(allocator);
    var issues = std.ArrayList(SchemaIssue).empty;
    errdefer issues.deinit(allocator);
    var schema = std.AutoHashMap(u32, void).init(allocator);
    defer schema.deinit();

    var it = exp.outlines.iterator();
    while (it.next()) |entry| {
        const file_id = entry.key_ptr.*;
        if (exp.deleted_files.get(file_id) != null) continue;
        const outline = entry.value_ptr.*;
        const content = exp.content_of(allocator, file_id) orelse continue;
        if (is_schema_file(outline.path, content)) {
            try schema.put(file_id, {});
            if (outline.language == .sql or std.mem.endsWith(u8, outline.path, ".sql")) {
                try sql_events(allocator, outline.path, content, &events);
            } else {
                try framework_events(allocator, outline.path, content, &events);
                // Raw SQL inside a Go, Rust or TypeScript migration file.
                try sql_events(allocator, outline.path, content, &events);
            }
        } else if (is_code_language(outline.language) and outline.language != .sql) {
            try code_models(allocator, outline, content, &code);
        }
    }

    // Apply the migrations in file order: numbered and timestamped migration
    // names sort into the order they run.
    std.mem.sort(Event, events.items, {}, path_less);
    var live = std.ArrayList(TableDef).empty;
    defer live.deinit(allocator);
    for (events.items) |e| {
        switch (e.kind) {
            .create => {
                var exists = false;
                for (live.items) |t| {
                    if (names_match(t.name, e.name)) exists = true;
                }
                if (!exists) try live.append(allocator, .{ .name = e.name, .source = .migration, .file = e.file, .line = e.line });
            },
            .drop => {
                var i: usize = 0;
                while (i < live.items.len) {
                    if (names_match(live.items[i].name, e.name)) {
                        _ = live.orderedRemove(i);
                    } else i += 1;
                }
            },
            .rename => {
                for (live.items) |*t| {
                    if (names_match(t.name, e.name)) t.name = e.to;
                }
            },
        }
    }

    for (live.items) |t| {
        if (referenced_by_code(exp, &schema, t.name)) continue;
        // A model named after the table references it too.
        var modeled = false;
        for (code.items) |m| {
            if (names_match(m.table orelse m.class, t.name) or names_match(m.class, t.name)) modeled = true;
        }
        if (modeled) continue;
        try issues.append(allocator, .{
            .table = t.name,
            .issue_type = .orphan_migration,
            .description = "The migrations create this table and no code file names it",
            .file = t.file,
            .line = t.line,
        });
    }

    // Without any migration there is nothing to compare a model against: the
    // ORM may create its tables itself.
    if (events.items.len > 0) {
        for (code.items) |m| {
            var found = false;
            for (live.items) |t| {
                if (names_match(t.name, m.table orelse m.class) or names_match(t.name, m.class)) found = true;
            }
            if (found) continue;
            try issues.append(allocator, .{
                .table = m.table orelse m.class,
                .issue_type = .missing_migration,
                .description = "An SQL ORM maps this model to a table that no migration creates",
                .file = m.file,
                .line = m.line,
            });
        }
    }

    return .{
        .tables_in_migrations = live.items.len,
        .tables_in_code = code.items.len,
        .migration_files = schema.count(),
        .issues = try issues.toOwnedSlice(allocator),
    };
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "db_schema: one statement is one table, whatever its form" {
    var events = std.ArrayList(Event).empty;
    defer events.deinit(testing.allocator);
    const sql =
        \\CREATE TABLE IF NOT EXISTS goals (id TEXT);
        \\create table "public"."Users" (id int);
        \\-- CREATE TABLE commented_out (id int);
        \\CREATE TEMP TABLE scratch (id int); CREATE UNLOGGED TABLE events (id int);
        \\ALTER TABLE events RENAME TO audit_events;
        \\DROP TABLE IF EXISTS goals, legacy;
        \\
    ;
    try sql_events(testing.allocator, "migrations/0001.sql", sql, &events);
    // `IF` was recorded as a table from every `CREATE TABLE IF NOT EXISTS`,
    // and each line matched twice, once per case-folded pattern.
    try testing.expectEqual(@as(usize, 6), events.items.len);
    try testing.expectEqualStrings("goals", events.items[0].name);
    try testing.expectEqualStrings("Users", events.items[1].name);
    try testing.expectEqualStrings("events", events.items[2].name);
    try testing.expectEqualStrings("audit_events", events.items[3].to);
    try testing.expectEqual(@as(@TypeOf(events.items[4].kind), .drop), events.items[4].kind);
    try testing.expectEqualStrings("legacy", events.items[5].name);

    // A partition and a name template create no table code names.
    events.clearRetainingCapacity();
    try sql_events(testing.allocator, "migrations/0104.sql",
        \\EXECUTE format('CREATE TABLE IF NOT EXISTS fleet_events_%s PARTITION OF fleet_events', m);
        \\CREATE TABLE IF NOT EXISTS fleet_events_default PARTITION OF fleet_events DEFAULT;
        \\
    , &events);
    try testing.expectEqual(@as(usize, 0), events.items.len);
}

fn add(exp: *explorer.Explorer, path: []const u8, lang: models.Language, imports: []const []const u8, syms: []const models.Symbol, src: []const u8) !void {
    const a = testing.allocator;
    const s = try a.alloc(models.Symbol, syms.len);
    for (syms, 0..) |sym, i| {
        s[i] = sym;
        s[i].name = try a.dupe(u8, sym.name);
    }
    const imps = try a.alloc([]const u8, imports.len);
    for (imports, 0..) |imp, i| imps[i] = try a.dupe(u8, imp);
    _ = try exp.add_file(.{
        .path = try a.dupe(u8, path),
        .language = lang,
        .line_count = std.mem.count(u8, src, "\n") + 1,
        .byte_size = src.len,
        .symbols = s,
        .imports = imps,
    }, src);
}

test "db_schema: a raw-SQL repository has no orphan for a table its queries name" {
    var exp = try explorer.Explorer.init(testing.allocator);
    defer exp.deinit();
    try add(&exp, "/ws/migrations/0001_init.sql", .sql, &.{}, &.{}, "CREATE TABLE IF NOT EXISTS goals (id TEXT);\nCREATE TABLE forgotten (id TEXT);\nCREATE TABLE old (id TEXT);\n");
    try add(&exp, "/ws/migrations/0002_drop.sql", .sql, &.{}, &.{}, "DROP TABLE old;\n");
    try add(&exp, "/ws/src/goals.rs", .rust, &.{"sqlx"}, &.{}, "let rows = sqlx::query(\"SELECT id FROM goals\").fetch_all(p).await?;\n");
    exp.mark_indexing_complete();

    const report = try analyze(testing.allocator, &exp);
    defer testing.allocator.free(report.issues);
    try testing.expectEqual(@as(usize, 2), report.tables_in_migrations);
    try testing.expectEqual(@as(usize, 1), report.issues.len);
    try testing.expectEqual(IssueType.orphan_migration, report.issues[0].issue_type);
    try testing.expectEqualStrings("forgotten", report.issues[0].table);
}

test "db_schema: a vector-store model is not schema drift, an SQL model without its migration is" {
    var exp = try explorer.Explorer.init(testing.allocator);
    defer exp.deinit();
    try add(&exp, "/ws/migrations/0001.sql", .sql, &.{}, &.{}, "CREATE TABLE users (id TEXT);\n");
    try add(&exp, "/ws/src/vectors.ts", .typescript, &.{"@lancedb/lancedb"}, &.{
        .{ .name = "Embedding", .kind = .class, .line_start = 1, .line_end = 3 },
    }, "import * as lancedb from '@lancedb/lancedb';\nclass Embedding {\n  tableName = 'embeddings';\n}\n");
    try add(&exp, "/ws/src/invoice.ts", .typescript, &.{"sequelize"}, &.{
        .{ .name = "Invoice", .kind = .class, .line_start = 1, .line_end = 3 },
        .{ .name = "User", .kind = .class, .line_start = 4, .line_end = 6 },
    }, "import { Model } from 'sequelize';\nclass Invoice extends Model {\n  static tableName = 'invoices';\n}\nclass User extends Model {\n  static tableName = 'users';\n}\n");
    exp.mark_indexing_complete();

    const report = try analyze(testing.allocator, &exp);
    defer testing.allocator.free(report.issues);
    try testing.expectEqual(@as(usize, 2), report.tables_in_code);
    try testing.expectEqual(@as(usize, 1), report.issues.len);
    try testing.expectEqual(IssueType.missing_migration, report.issues[0].issue_type);
    try testing.expectEqualStrings("invoices", report.issues[0].table);
}

test "db_schema: Django and Rails migrations create tables through calls" {
    var events = std.ArrayList(Event).empty;
    defer events.deinit(testing.allocator);
    try framework_events(testing.allocator, "app/migrations/0001_initial.py",
        \\migrations.CreateModel(
        \\    name='Invoice',
        \\    fields=[],
        \\),
        \\
    , &events);
    try framework_events(testing.allocator, "db/migrate/20240101_create_users.rb", "create_table :users do |t|\nend\n", &events);
    try testing.expectEqual(@as(usize, 2), events.items.len);
    try testing.expectEqualStrings("Invoice", events.items[0].name);
    try testing.expectEqualStrings("users", events.items[1].name);
}

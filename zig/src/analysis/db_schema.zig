const std = @import("std");
const explorer = @import("../index/explorer.zig");
const models = @import("../core/models.zig");

pub const TableDef = struct {
    name: []const u8,
    source: enum { migration, code },
    file: []const u8,
    line: usize,
    columns: [][]const u8,
};

pub const SchemaIssue = struct {
    table: []const u8,
    issue_type: enum { orphan_migration, missing_migration, column_mismatch },
    description: []const u8,
    file: []const u8,
    line: usize,
};

pub const Report = struct {
    tables_in_migrations: usize,
    tables_in_code: usize,
    issues: []SchemaIssue,
};

const create_patterns = [_][]const u8{
    "CREATE TABLE ",
    "CREATE TABLE IF NOT EXISTS ",
    "create table ",
    "create_table ",
};

const struct_db_hints = [_][]const u8{
    "#[table_name",
    "#[diesel(",
    "tableName",
    "@Entity",
    "db.Model",
    "models.Model",
    "@Table(",
};

pub fn analyze(allocator: std.mem.Allocator, exp: *explorer.Explorer) !Report {
    var migration_tables = std.ArrayList(TableDef){};
    var code_tables = std.ArrayList(TableDef){};
    var issues = std.ArrayList(SchemaIssue){};

    var it = exp.outlines.iterator();
    while (it.next()) |entry| {
        const file_id = entry.key_ptr.*;
        if (exp.deleted_files.get(file_id) != null) continue;
        const outline = entry.value_ptr.*;
        const content = exp.content_cache.get(file_id) orelse continue;

        const is_migration = std.mem.indexOf(u8, outline.path, "migration") != null or
            std.mem.endsWith(u8, outline.path, ".sql");

        var line_num: usize = 1;
        var lines_it = std.mem.splitScalar(u8, content, '\n');
        while (lines_it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");

            // Look for CREATE TABLE in SQL/migration files
            if (is_migration) {
                for (&create_patterns) |pat| {
                    if (std.ascii.startsWithIgnoreCase(trimmed, pat)) {
                        const after = trimmed[pat.len..];
                        const end = std.mem.indexOfAny(u8, after, " (\n\r") orelse after.len;
                        const table_name = after[0..end];
                        if (table_name.len > 0) {
                            try migration_tables.append(allocator, .{
                                .name = table_name,
                                .source = .migration,
                                .file = outline.path,
                                .line = line_num,
                                .columns = &.{},
                            });
                        }
                    }
                }
            }

            // Look for ORM/model annotations in code
            for (&struct_db_hints) |hint| {
                if (std.mem.indexOf(u8, trimmed, hint) != null) {
                    // Find the struct/class name from nearby symbols
                    for (outline.symbols) |sym| {
                        if (sym.line_start <= line_num + 3 and sym.line_end >= line_num) {
                            if (sym.kind == .@"struct" or sym.kind == .class) {
                                try code_tables.append(allocator, .{
                                    .name = sym.name,
                                    .source = .code,
                                    .file = outline.path,
                                    .line = sym.line_start,
                                    .columns = &.{},
                                });
                            }
                        }
                    }
                    break;
                }
            }
            line_num += 1;
        }
    }

    // Cross-reference: find tables in migrations without code models and vice versa
    for (migration_tables.items) |mt| {
        var found = false;
        for (code_tables.items) |ct| {
            if (tableNamesMatch(mt.name, ct.name)) {
                found = true;
                break;
            }
        }
        if (!found) {
            try issues.append(allocator, .{
                .table = mt.name,
                .issue_type = .orphan_migration,
                .description = "Table in migration but no matching code model",
                .file = mt.file,
                .line = mt.line,
            });
        }
    }

    for (code_tables.items) |ct| {
        var found = false;
        for (migration_tables.items) |mt| {
            if (tableNamesMatch(mt.name, ct.name)) {
                found = true;
                break;
            }
        }
        if (!found) {
            try issues.append(allocator, .{
                .table = ct.name,
                .issue_type = .missing_migration,
                .description = "Code model but no matching migration table",
                .file = ct.file,
                .line = ct.line,
            });
        }
    }

    return .{
        .tables_in_migrations = migration_tables.items.len,
        .tables_in_code = code_tables.items.len,
        .issues = try issues.toOwnedSlice(allocator),
    };
}

fn tableNamesMatch(migration_name: []const u8, code_name: []const u8) bool {
    // Direct match
    if (std.ascii.eqlIgnoreCase(migration_name, code_name)) return true;
    // Snake_case migration vs PascalCase code (e.g., "user_profiles" matches "UserProfile")
    // Simple heuristic: lowercase both and strip underscores/plurals
    var a_buf: [128]u8 = undefined;
    var b_buf: [128]u8 = undefined;
    const a = normalize(migration_name, &a_buf);
    const b = normalize(code_name, &b_buf);
    return std.mem.eql(u8, a, b);
}

fn normalize(name: []const u8, buf: []u8) []const u8 {
    var pos: usize = 0;
    for (name) |c| {
        if (c != '_' and c != '-') {
            if (pos < buf.len) {
                buf[pos] = std.ascii.toLower(c);
                pos += 1;
            }
        }
    }
    // Strip trailing 's' (naive plural)
    if (pos > 1 and buf[pos - 1] == 's') pos -= 1;
    return buf[0..pos];
}

fn startsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (haystack[0..needle.len], needle) |h, n| {
        if (std.ascii.toLower(h) != std.ascii.toLower(n)) return false;
    }
    return true;
}

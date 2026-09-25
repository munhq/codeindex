const std = @import("std");
const explorer = @import("../index/explorer.zig");
const models = @import("../core/models.zig");

pub const Category = enum {
    /// Nothing in the repository references it, and nothing outside the
    /// repository can.
    dead,
    /// Public in a package another project can depend on, and unreferenced
    /// inside this repository. Its users, if any, live elsewhere.
    unused_public_api,

    pub fn as_str(self: Category) []const u8 {
        return @tagName(self);
    }
};

pub const DeadSymbol = struct {
    name: []const u8,
    kind: models.SymbolKind,
    visibility: models.Visibility,
    category: Category,
    file: []const u8,
    line: usize,
};

pub const Report = struct {
    dead: []DeadSymbol,
    unused_public_api: []DeadSymbol,
    /// Definitions the analysis looked up.
    checked: usize,

    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        allocator.free(self.dead);
        allocator.free(self.unused_public_api);
    }
};

/// Skip list: symbols that are commonly used externally without explicit references.
const skip_names = [_][]const u8{
    "main",  "new",  "default",  "init",     "deinit",      "drop",   "clone",     "fmt",
    "from",  "into", "try_from", "try_into", "as_ref",      "as_mut", "serialize", "deserialize",
    "build", "run",  "start",    "stop",     "constructor",
};

/// Names a JavaScript framework calls by export: Next.js route handlers and
/// page functions. A file-based router imports them, never the source.
const framework_exports = [_][]const u8{
    "GET",              "POST",                 "PUT",      "PATCH",    "DELETE",     "HEAD",   "OPTIONS",
    "generateMetadata", "generateStaticParams", "metadata", "viewport", "middleware", "config", "getServerSideProps",
    "getStaticProps",   "getStaticPaths",       "loader",   "action",
};

/// A test runner finds its tests by attribute or by name, so a test function
/// has no caller by definition and is never dead.
///
/// `kind == .test` alone does not cover it: the vendored Rust tags query reports
/// `#[test] fn foo()` as a plain function, and Go, Python and JavaScript name
/// their tests by convention instead of marking them. Without this every test in
/// the tree came back as dead code — 276 of them in one repository.
fn is_test_symbol(name: []const u8, kind: models.SymbolKind, path: []const u8, language: models.Language) bool {
    if (kind == .@"test") return true;

    // A file the test runner owns.
    const basename = std.fs.path.basenamePosix(path);
    if (std.mem.indexOf(u8, basename, "_test.") != null) return true;
    if (std.mem.indexOf(u8, basename, ".test.") != null) return true;
    if (std.mem.indexOf(u8, basename, ".spec.") != null) return true;
    if (std.mem.startsWith(u8, basename, "test_")) return true;
    if (std.mem.eql(u8, basename, "conftest.py")) return true;
    var comp_it = std.mem.splitScalar(u8, path, '/');
    while (comp_it.next()) |component| {
        if (std.mem.eql(u8, component, "tests") or std.mem.eql(u8, component, "test") or
            std.mem.eql(u8, component, "__tests__") or std.mem.eql(u8, component, "spec")) return true;
    }

    // A name the runner looks for.
    switch (language) {
        .rust, .python => {
            if (std.mem.startsWith(u8, name, "test_")) return true;
        },
        .go => {
            // `TestX`, `BenchmarkX`, `FuzzX`, `ExampleX` — the runner's prefixes.
            const prefixes = [_][]const u8{ "Test", "Benchmark", "Fuzz", "Example" };
            for (&prefixes) |p| {
                if (!std.mem.startsWith(u8, name, p)) continue;
                const rest = name[p.len..];
                if (rest.len == 0 or std.ascii.isUpper(rest[0])) return true;
            }
        },
        .java, .kotlin, .c_sharp => {
            if (std.mem.startsWith(u8, name, "test") or std.mem.startsWith(u8, name, "Test")) return true;
        },
        else => {},
    }
    return false;
}

fn should_skip(name: []const u8, kind: models.SymbolKind, language: models.Language) bool {
    switch (kind) {
        .impl, .import, .module, .comment, .unknown, .@"test" => return true,
        else => {},
    }
    // Short names are loop variables and getters that every file spells.
    if (name.len <= 2) return true;
    // Rust and Zig declare "unused on purpose" with a leading underscore:
    // `_pad`, `_guard`.
    if (name[0] == '_' and (language == .rust or language == .zig)) return true;
    for (&skip_names) |s| {
        if (std.mem.eql(u8, name, s)) return true;
    }
    return false;
}

/// Languages whose symbols are code. A YAML key or a JSON field is a symbol in
/// the outline, and a key nobody greps for is not dead code.
fn is_code(language: models.Language) bool {
    return switch (language) {
        .rust, .python, .go, .typescript, .javascript, .zig, .c, .cpp, .java, .ruby, .c_sharp, .kotlin, .lua, .scala, .swift, .dart, .php, .elixir, .bash, .solidity => true,
        else => false,
    };
}

fn ident_char(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
}

/// Whether `content` names `word` on a 0-based line outside [skip_start, skip_end].
fn named_outside(content: []const u8, word: []const u8, skip_start: usize, skip_end: usize) bool {
    var line: usize = 0;
    var counted: usize = 0; // `line` is the line of byte `counted`
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, content, pos, word)) |at| {
        line += std.mem.count(u8, content[counted..at], "\n");
        counted = at;
        pos = at + word.len;
        if (at > 0 and ident_char(content[at - 1])) continue;
        if (pos < content.len and ident_char(content[pos])) continue;
        if (line >= skip_start and line <= skip_end) continue;
        return true;
    }
    return false;
}

/// Where a package's public API ends and its users begin, per manifest
/// directory.
const Packages = struct {
    /// Manifest directory → whether other projects can depend on that
    /// package, one map per ecosystem. A `Cargo.toml` says nothing about the
    /// Python scripts beside it: with one shared map, a Rust library at the root
    /// made every script under it a library too.
    cargo: std.StringHashMap(bool),
    npm: std.StringHashMap(bool),
    zig: std.StringHashMap(bool),

    fn deinit(self: *Packages) void {
        self.cargo.deinit();
        self.npm.deinit();
        self.zig.deinit();
    }

    /// Whether the nearest manifest of the file's own ecosystem above `path`
    /// describes a library.
    fn is_library(self: *const Packages, language: models.Language, path: []const u8) bool {
        const map = switch (language) {
            .rust => &self.cargo,
            .typescript, .javascript => &self.npm,
            .zig => &self.zig,
            else => return false,
        };
        var dir = std.fs.path.dirnamePosix(path);
        while (dir) |d| : (dir = std.fs.path.dirnamePosix(d)) {
            if (map.get(d)) |lib| return lib;
        }
        return false;
    }
};

/// A Rust crate with a `src/lib.rs` that is not `publish = false`, an npm
/// package that declares an entry point and is not `"private": true`, and a Zig
/// package that exports a module. Every other package is an application: its
/// public items have no users outside the repository.
fn find_packages(allocator: std.mem.Allocator, exp: *explorer.Explorer) !Packages {
    var p = Packages{
        .cargo = std.StringHashMap(bool).init(allocator),
        .npm = std.StringHashMap(bool).init(allocator),
        .zig = std.StringHashMap(bool).init(allocator),
    };
    errdefer p.deinit();
    var it = exp.outlines.iterator();
    while (it.next()) |entry| {
        const file_id = entry.key_ptr.*;
        if (exp.deleted_files.get(file_id) != null) continue;
        const path = entry.value_ptr.path;
        const base = std.fs.path.basenamePosix(path);
        const dir = std.fs.path.dirnamePosix(path) orelse continue;
        const content = exp.content_of(allocator, file_id) orelse continue;
        if (std.mem.eql(u8, base, "Cargo.toml")) {
            var buf: [1024]u8 = undefined;
            const lib_rs = std.fmt.bufPrint(&buf, "{s}/src/lib.rs", .{dir}) catch continue;
            const has_lib = exp.file_map.get(lib_rs) != null or std.mem.indexOf(u8, content, "[lib]") != null;
            const unpublished = std.mem.indexOf(u8, content, "publish = false") != null;
            try p.cargo.put(dir, has_lib and !unpublished);
        } else if (std.mem.eql(u8, base, "package.json")) {
            const entry_point = std.mem.indexOf(u8, content, "\"main\"") != null or
                std.mem.indexOf(u8, content, "\"exports\"") != null or
                std.mem.indexOf(u8, content, "\"module\"") != null or
                std.mem.indexOf(u8, content, "\"types\"") != null;
            const private = std.mem.indexOf(u8, content, "\"private\": true") != null or
                std.mem.indexOf(u8, content, "\"private\":true") != null;
            try p.npm.put(dir, entry_point and !private);
        } else if (std.mem.eql(u8, base, "build.zig")) {
            try p.zig.put(dir, std.mem.indexOf(u8, content, "addModule(") != null);
        }
    }
    return p;
}

/// A symbol inside `mod tests` / `mod test`: a Rust unit-test module.
fn in_test_module(outline: models.FileOutline, sym: models.Symbol) bool {
    for (outline.symbols) |m| {
        if (m.kind != .module) continue;
        if (!std.mem.eql(u8, m.name, "tests") and !std.mem.eql(u8, m.name, "test")) continue;
        if (sym.line_start > m.line_start and sym.line_end <= m.line_end) return true;
    }
    return false;
}

fn is_framework_export(language: models.Language, sym: models.Symbol) bool {
    if (language != .typescript and language != .javascript) return false;
    if (sym.visibility != .public) return false;
    for (&framework_exports) |n| {
        if (std.mem.eql(u8, sym.name, n)) return true;
    }
    return false;
}

/// A definition is dead when nothing names it outside its own definition, in
/// any file, and nothing outside the source can reach it.
///
/// The check used to count hits in other files only. A private method that its
/// own file calls has none, so every such method was reported: 2310 of the
/// 4508 findings on a 991-file Rust repository were methods. Its own file's
/// hits outside its own range now count as references.
pub fn find_dead_code(allocator: std.mem.Allocator, exp: *explorer.Explorer) !Report {
    var dead = std.ArrayList(DeadSymbol).empty;
    errdefer dead.deinit(allocator);
    var api = std.ArrayList(DeadSymbol).empty;
    errdefer api.deinit(allocator);
    var packages = try find_packages(allocator, exp);
    defer packages.deinit();
    var checked: usize = 0;

    var it = exp.outlines.iterator();
    while (it.next()) |entry| {
        const file_id = entry.key_ptr.*;
        if (exp.deleted_files.get(file_id) != null) continue;
        const outline = entry.value_ptr.*;
        if (!is_code(outline.language)) continue;

        var content: ?[]const u8 = null;
        for (outline.symbols) |sym| {
            if (should_skip(sym.name, sym.kind, outline.language)) continue;
            if (is_test_symbol(sym.name, sym.kind, outline.path, outline.language)) continue;
            if (sym.flags.implements or sym.flags.registered) continue;
            if (in_test_module(outline, sym)) continue;
            if (is_framework_export(outline.language, sym)) continue;
            checked += 1;

            // Another file that names it. Postings are file-id sets and may
            // be stale toward "used" (a file that dropped the word keeps its
            // entry until compaction), which errs away from a false report.
            var used = false;
            for (exp.words.search(sym.name)) |hit| {
                if (hit != file_id and exp.deleted_files.get(hit) == null) {
                    used = true;
                    break;
                }
            }
            if (!used) {
                if (content == null) content = exp.content_of(allocator, file_id);
                const c = content orelse continue;
                used = named_outside(c, sym.name, sym.line_start, sym.line_end);
            }
            if (used) continue;

            const is_api = sym.visibility == .public and packages.is_library(outline.language, outline.path);
            const found = DeadSymbol{
                .name = sym.name,
                .kind = sym.kind,
                .visibility = sym.visibility,
                .category = if (is_api) .unused_public_api else .dead,
                .file = outline.path,
                .line = sym.start_1(),
            };
            if (is_api) try api.append(allocator, found) else try dead.append(allocator, found);
        }
    }

    return .{
        .dead = try dead.toOwnedSlice(allocator),
        .unused_public_api = try api.toOwnedSlice(allocator),
        .checked = checked,
    };
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "dead_code: a test function is never dead" {
    // The vendored Rust tags query reports `#[test] fn` as a plain function, so
    // `kind == .test` alone missed every one of them. Go, Python and JavaScript
    // mark theirs by name or by path instead.
    try testing.expect(is_test_symbol("test_parses_utf8", .function, "src/text.rs", .rust));
    try testing.expect(is_test_symbol("TestServeHTTP", .function, "pkg/api/server.go", .go));
    try testing.expect(is_test_symbol("BenchmarkParse", .function, "pkg/api/server.go", .go));
    try testing.expect(is_test_symbol("renders_the_form", .function, "src/form.test.ts", .typescript));
    try testing.expect(is_test_symbol("helper", .function, "tests/support/mod.rs", .rust));

    // Production code that merely reads like a test is not one.
    try testing.expect(!is_test_symbol("testable_config", .function, "src/config.rs", .rust));
    try testing.expect(!is_test_symbol("Tester", .@"struct", "src/harness.rs", .rust));
    try testing.expect(!is_test_symbol("latest_version", .function, "src/providers/latest.rs", .rust));
}

test "dead_code: an unreferenced test function is not reported" {
    const allocator = testing.allocator;
    var exp = try explorer.Explorer.init(allocator);
    defer exp.deinit();

    const src =
        \\pub fn parse(s: &str) -> u32 { s.len() as u32 }
        \\
        \\#[test]
        \\fn test_parses_utf8() { assert_eq!(parse("ab"), 2); }
        \\
    ;
    var syms = try allocator.alloc(models.Symbol, 2);
    syms[0] = .{ .name = try allocator.dupe(u8, "parse"), .kind = .function, .line_start = 0, .line_end = 0 };
    syms[1] = .{ .name = try allocator.dupe(u8, "test_parses_utf8"), .kind = .function, .line_start = 3, .line_end = 3 };
    _ = try exp.add_file(.{
        .path = try allocator.dupe(u8, "src/text.rs"),
        .language = .rust,
        .line_count = 4,
        .byte_size = src.len,
        .symbols = syms,
        .imports = &[_][]const u8{},
    }, src);
    exp.mark_indexing_complete();

    var report = try find_dead_code(allocator, &exp);
    defer report.deinit(allocator);
    // `parse` is named on line 4 of its own file, so it is used.
    try testing.expectEqual(@as(usize, 0), report.dead.len);
}

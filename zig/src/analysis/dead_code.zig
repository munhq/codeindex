const std = @import("std");
const explorer = @import("../index/explorer.zig");
const models = @import("../core/models.zig");

pub const DeadSymbol = struct {
    name: []const u8,
    kind: models.SymbolKind,
    file: []const u8,
    line: usize,
    reason: []const u8,
};

/// Skip list: symbols that are commonly used externally without explicit references.
const skip_names = [_][]const u8{
    "main",  "new",  "default",  "init",     "deinit", "drop",   "clone",     "fmt",
    "from",  "into", "try_from", "try_into", "as_ref", "as_mut", "serialize", "deserialize",
    "build", "run",  "start",    "stop",
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
    const basename = std.fs.path.basename(path);
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

fn should_skip(name: []const u8, kind: models.SymbolKind) bool {
    // Skip impl blocks
    if (kind == .impl) return true;
    // Skip imports/modules
    if (kind == .import or kind == .module) return true;
    // Skip short names (likely getters/setters)
    if (name.len <= 2) return true;
    // Skip known names
    for (&skip_names) |s| {
        if (std.mem.eql(u8, name, s)) return true;
    }
    // Skip PascalCase in tsx/jsx (React components)
    if (name.len > 0 and std.ascii.isUpper(name[0])) return false; // don't skip, but it's noted
    return false;
}

pub fn find_dead_code(allocator: std.mem.Allocator, exp: *explorer.Explorer) ![]DeadSymbol {
    var results = std.ArrayList(DeadSymbol).empty;

    var it = exp.outlines.iterator();
    while (it.next()) |entry| {
        const file_id = entry.key_ptr.*;
        if (exp.deleted_files.get(file_id) != null) continue;
        const outline = entry.value_ptr.*;

        for (outline.symbols) |sym| {
            if (should_skip(sym.name, sym.kind)) continue;
            if (is_test_symbol(sym.name, sym.kind, outline.path, outline.language)) continue;

            // Check if symbol appears in word index in other files. Postings
            // are file-id sets and may be stale toward false positives (a file
            // that dropped the word keeps its entry until compaction) — for
            // dead-code detection that errs toward "used", never toward
            // falsely reporting dead.
            const hits = exp.words.search(sym.name);
            var used_externally = false;
            for (hits) |hit_file_id| {
                if (hit_file_id != file_id) {
                    used_externally = true;
                    break;
                }
            }

            if (!used_externally) {
                try results.append(allocator, .{
                    .name = sym.name,
                    .kind = sym.kind,
                    .file = outline.path,
                    .line = sym.start_1(),
                    .reason = "no references outside defining file",
                });
            }
        }
    }

    return try results.toOwnedSlice(allocator);
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

    const dead = try find_dead_code(allocator, &exp);
    defer allocator.free(dead);
    try testing.expectEqual(@as(usize, 1), dead.len);
    try testing.expectEqualStrings("parse", dead[0].name);
}

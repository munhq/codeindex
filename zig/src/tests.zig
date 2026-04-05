const std = @import("std");
const testing = std.testing;
const models = @import("core/models.zig");
const explorer_mod = @import("index/explorer.zig");
const version_mod = @import("index/version.zig");
const filter_mod = @import("core/filter.zig");

// ── Language detection ───────────────────────────────────────────────────────

test "language detection from extensions" {
    try testing.expectEqual(models.Language.rust, models.Language.from_path("main.rs"));
    try testing.expectEqual(models.Language.python, models.Language.from_path("app.py"));
    try testing.expectEqual(models.Language.typescript, models.Language.from_path("index.ts"));
    try testing.expectEqual(models.Language.javascript, models.Language.from_path("app.js"));
    try testing.expectEqual(models.Language.go, models.Language.from_path("main.go"));
    try testing.expectEqual(models.Language.c, models.Language.from_path("lib.c"));
    try testing.expectEqual(models.Language.cpp, models.Language.from_path("lib.cpp"));
    try testing.expectEqual(models.Language.java, models.Language.from_path("Main.java"));
    try testing.expectEqual(models.Language.ruby, models.Language.from_path("app.rb"));
    try testing.expectEqual(models.Language.bash, models.Language.from_path("script.sh"));
    try testing.expectEqual(models.Language.yaml, models.Language.from_path("config.yml"));
    try testing.expectEqual(models.Language.toml, models.Language.from_path("Cargo.toml"));
    try testing.expectEqual(models.Language.json, models.Language.from_path("package.json"));
    try testing.expectEqual(models.Language.hcl, models.Language.from_path("main.tf"));
    try testing.expectEqual(models.Language.dockerfile, models.Language.from_path("Dockerfile"));
    try testing.expectEqual(models.Language.unknown, models.Language.from_path("binary.exe"));
}

// ── TrigramIndex ─────────────────────────────────────────────────────────────

test "trigram insert and search" {
    var idx = explorer_mod.TrigramIndex.init(testing.allocator);
    defer idx.deinit();

    try idx.add_text(0, "hello world function");
    const results = try idx.query("hello");
    defer if (results.len > 0) testing.allocator.free(results);
    try testing.expect(results.len > 0);
}

test "trigram short query returns empty" {
    var idx = explorer_mod.TrigramIndex.init(testing.allocator);
    defer idx.deinit();

    try idx.add_text(0, "hello world");
    const results = try idx.query("ab");
    try testing.expectEqual(@as(usize, 0), results.len);
}

test "trigram remove file" {
    var idx = explorer_mod.TrigramIndex.init(testing.allocator);
    defer idx.deinit();

    try idx.add_text(0, "hello world");
    try idx.add_text(1, "hello there");

    const before = try idx.query("hello");
    defer if (before.len > 0) testing.allocator.free(before);
    try testing.expect(before.len >= 2);

    idx.remove_file(0);
    const after = try idx.query("hello");
    defer if (after.len > 0) testing.allocator.free(after);
    try testing.expect(after.len < before.len);
}

// ── WordIndex ────────────────────────────────────────────────────────────────

test "word insert and search" {
    var idx = explorer_mod.WordIndex.init(testing.allocator);
    defer idx.deinit();

    try idx.add_text(0, "fn hello_world() { }");
    const hits = idx.search("hello_world");
    try testing.expect(hits.len > 0);
}

test "word search is case sensitive" {
    var idx = explorer_mod.WordIndex.init(testing.allocator);
    defer idx.deinit();

    try idx.add_text(0, "fn HelloWorld() {}");
    try testing.expectEqual(@as(usize, 0), idx.search("helloworld").len);
    try testing.expect(idx.search("HelloWorld").len > 0);
}

test "word short words skipped" {
    var idx = explorer_mod.WordIndex.init(testing.allocator);
    defer idx.deinit();

    try idx.add_text(0, "a b c");
    try testing.expectEqual(@as(usize, 0), idx.search("a").len);
}

// ── VersionStore ─────────────────────────────────────────────────────────────

test "version store records and queries" {
    var vs = version_mod.VersionStore.init(testing.allocator);
    defer vs.deinit();

    try vs.record("a.rs", .added);
    try vs.record("b.rs", .modified);

    try testing.expectEqual(@as(u64, 2), vs.latest_seq());

    const changes = vs.changes_since(0);
    try testing.expectEqual(@as(usize, 2), changes.items.len);
    try testing.expect(!changes.truncated);
}

test "version store changes_since filters" {
    var vs = version_mod.VersionStore.init(testing.allocator);
    defer vs.deinit();

    try vs.record("a.rs", .added);
    try vs.record("b.rs", .added);
    try vs.record("c.rs", .added);

    const changes = vs.changes_since(2);
    try testing.expectEqual(@as(usize, 1), changes.items.len);
}

test "version store hot_files returns newest" {
    var vs = version_mod.VersionStore.init(testing.allocator);
    defer vs.deinit();

    try vs.record("a.rs", .added);
    try vs.record("b.rs", .added);
    try vs.record("c.rs", .added);

    const hot = vs.hot_files(2);
    try testing.expectEqual(@as(usize, 2), hot.len);
}

// ── Explorer ─────────────────────────────────────────────────────────────────

test "explorer add and query file" {
    var exp = explorer_mod.Explorer.init(testing.allocator);
    defer exp.deinit();

    const sym = models.Symbol{
        .name = try testing.allocator.dupe(u8, "main"),
        .kind = .function,
        .line_start = 1,
        .line_end = 5,
    };
    var syms = try testing.allocator.alloc(models.Symbol, 1);
    syms[0] = sym;

    const outline = models.FileOutline{
        .path = try testing.allocator.dupe(u8, "test.rs"),
        .language = .rust,
        .line_count = 10,
        .byte_size = 100,
        .symbols = syms,
        .imports = &[_][]const u8{},
    };

    _ = try exp.add_file(outline, "fn main() {\n    println!(\"hello\");\n}\n");
    exp.mark_indexing_complete();

    try testing.expectEqual(@as(usize, 1), exp.file_count());
    try testing.expectEqual(@as(usize, 1), exp.symbol_count());
    try testing.expect(!exp.is_indexing());
}

test "explorer find_symbol" {
    var exp = explorer_mod.Explorer.init(testing.allocator);
    defer exp.deinit();

    var syms = try testing.allocator.alloc(models.Symbol, 1);
    syms[0] = .{
        .name = try testing.allocator.dupe(u8, "MyStruct"),
        .kind = .@"struct",
        .line_start = 1,
        .line_end = 10,
    };

    _ = try exp.add_file(.{
        .path = try testing.allocator.dupe(u8, "lib.rs"),
        .language = .rust,
        .line_count = 10,
        .byte_size = 50,
        .symbols = syms,
        .imports = &[_][]const u8{},
    }, "struct MyStruct {}");
    exp.mark_indexing_complete();

    const results = try exp.find_symbol("MyStruct", 10);
    defer testing.allocator.free(results);
    try testing.expectEqual(@as(usize, 1), results.len);
    try testing.expectEqualStrings("MyStruct", results[0].symbol.name);
}

test "explorer search_content" {
    var exp = explorer_mod.Explorer.init(testing.allocator);
    defer exp.deinit();

    _ = try exp.add_file(.{
        .path = try testing.allocator.dupe(u8, "main.rs"),
        .language = .rust,
        .line_count = 3,
        .byte_size = 40,
        .symbols = &[_]models.Symbol{},
        .imports = &[_][]const u8{},
    }, "fn main() {\n    hello_world();\n}\n");
    exp.mark_indexing_complete();

    const results = try exp.search_content("hello_world", 10);
    defer testing.allocator.free(results);
    try testing.expectEqual(@as(usize, 1), results.len);
    try testing.expectEqual(@as(u32, 2), results[0].line_num);
}

test "explorer remove_file" {
    var exp = explorer_mod.Explorer.init(testing.allocator);
    defer exp.deinit();

    _ = try exp.add_file(.{
        .path = try testing.allocator.dupe(u8, "a.rs"),
        .language = .rust,
        .line_count = 1,
        .byte_size = 10,
        .symbols = &[_]models.Symbol{},
        .imports = &[_][]const u8{},
    }, "fn a() {}");

    try testing.expectEqual(@as(usize, 1), exp.file_count());

    try exp.remove_file("a.rs");
    try testing.expectEqual(@as(usize, 0), exp.file_count());
}

// ── Filter ───────────────────────────────────────────────────────────────────

test "filter skips hidden dirs" {
    var f = filter_mod.Filter.init(testing.allocator);
    defer f.deinit();

    try testing.expect(f.should_ignore(".git/config"));
    try testing.expect(f.should_ignore(".cache/data"));
    try testing.expect(!f.should_ignore("src/main.rs"));
}

test "filter skips builtin dirs" {
    var f = filter_mod.Filter.init(testing.allocator);
    defer f.deinit();

    try testing.expect(f.should_ignore("node_modules/package/index.js"));
    try testing.expect(f.should_ignore("target/debug/binary"));
    try testing.expect(f.should_ignore("__pycache__/module.pyc"));
}

test "filter skips binary extensions" {
    var f = filter_mod.Filter.init(testing.allocator);
    defer f.deinit();

    try testing.expect(f.should_ignore("image.png"));
    try testing.expect(f.should_ignore("archive.zip"));
    try testing.expect(f.should_ignore("binary.exe"));
    try testing.expect(!f.should_ignore("code.rs"));
}

// ── DepGraph ─────────────────────────────────────────────────────────────────

test "depgraph add and query" {
    var dg = explorer_mod.DepGraph.init(testing.allocator);
    defer dg.deinit();

    try dg.add_dependency(0, 1);
    try dg.add_dependency(0, 2);

    const imports = dg.imports.get(0).?;
    try testing.expectEqual(@as(usize, 2), imports.items.len);

    const rev = dg.reverse_deps.get(1).?;
    try testing.expectEqual(@as(usize, 1), rev.items.len);
    try testing.expectEqual(@as(u32, 0), rev.items[0]);
}

test "depgraph clear_file" {
    var dg = explorer_mod.DepGraph.init(testing.allocator);
    defer dg.deinit();

    try dg.add_dependency(0, 1);
    try dg.add_dependency(0, 2);
    dg.clear_file(0);

    const imports = dg.imports.get(0).?;
    try testing.expectEqual(@as(usize, 0), imports.items.len);
}

test "depgraph no duplicates" {
    var dg = explorer_mod.DepGraph.init(testing.allocator);
    defer dg.deinit();

    try dg.add_dependency(0, 1);
    try dg.add_dependency(0, 1);

    const imports = dg.imports.get(0).?;
    try testing.expectEqual(@as(usize, 1), imports.items.len);
}

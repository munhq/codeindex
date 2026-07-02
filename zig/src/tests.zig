const std = @import("std");
const testing = std.testing;
const io_mod = @import("core/io.zig");
const models = @import("core/models.zig");
const explorer_mod = @import("index/explorer.zig");
const version_mod = @import("index/version.zig");
const filter_mod = @import("core/filter.zig");
const security_scan = @import("analysis/security_scan.zig");
const unwrap_audit = @import("analysis/unwrap_audit.zig");
const dead_code = @import("analysis/dead_code.zig");
const cycles = @import("analysis/cycles.zig");
const coupling = @import("analysis/coupling.zig");
const test_coverage = @import("analysis/test_coverage.zig");
const architecture = @import("analysis/architecture.zig");
const treesitter = @import("parser/treesitter.zig");
const import_scan = @import("parser/import_scan.zig");
const duplication = @import("analysis/duplication.zig");
const clones = @import("analysis/clones.zig");

// ── Test helpers ──────────────────────────────────────────────────────────────

/// Create a FileOutline with owned copies of the given symbols.
fn make_outline(allocator: std.mem.Allocator, path: []const u8, lang: models.Language, sym_defs: []const struct { name: []const u8, kind: models.SymbolKind, line_start: usize, line_end: usize }, imports: []const []const u8) !models.FileOutline {
    var syms = try allocator.alloc(models.Symbol, sym_defs.len);
    for (sym_defs, 0..) |d, i| {
        syms[i] = .{
            .name = try allocator.dupe(u8, d.name),
            .kind = d.kind,
            .line_start = d.line_start,
            .line_end = d.line_end,
        };
    }
    var imps = try allocator.alloc([]const u8, imports.len);
    for (imports, 0..) |imp, i| {
        imps[i] = try allocator.dupe(u8, imp);
    }
    return .{
        .path = try allocator.dupe(u8, path),
        .language = lang,
        .line_count = 10,
        .byte_size = 100,
        .symbols = syms,
        .imports = imps,
    };
}

/// Build an Explorer with a few files. Content strings should match the symbols.
fn build_test_explorer(allocator: std.mem.Allocator, files: []const struct { outline: models.FileOutline, content: []const u8 }) !explorer_mod.Explorer {
    var exp = explorer_mod.Explorer.init(allocator);
    for (files) |f| {
        _ = try exp.add_file(f.outline, f.content);
    }
    exp.mark_indexing_complete();
    return exp;
}

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

test "trigram postings are one entry per file" {
    var idx = explorer_mod.TrigramIndex.init(testing.allocator);
    defer idx.deinit();

    // Many occurrences of the same trigram in one file → single posting.
    try idx.add_text(0, "aaaa aaaa aaaa\naaaa aaaa\n");
    const results = try idx.query("aaa");
    defer if (results.len > 0) testing.allocator.free(results);
    try testing.expectEqual(@as(usize, 1), results.len);
    try testing.expectEqual(@as(u32, 0), results[0]);
}

test "trigram re-add same file stays deduplicated" {
    var idx = explorer_mod.TrigramIndex.init(testing.allocator);
    defer idx.deinit();

    try idx.add_text(0, "hello world");
    try idx.add_text(0, "hello world"); // watcher re-index of the same file
    try idx.add_text(1, "hello there");

    const results = try idx.query("hello");
    defer if (results.len > 0) testing.allocator.free(results);
    try testing.expectEqual(@as(usize, 2), results.len);
    // Sorted ascending — the invariant the intersection merge depends on.
    try testing.expectEqual(@as(u32, 0), results[0]);
    try testing.expectEqual(@as(u32, 1), results[1]);
}

test "trigram out-of-order insert keeps postings sorted" {
    var idx = explorer_mod.TrigramIndex.init(testing.allocator);
    defer idx.deinit();

    try idx.add_text(7, "hello seven");
    try idx.add_text(2, "hello two");
    try idx.add_text(5, "hello five");

    const results = try idx.query("hello");
    defer if (results.len > 0) testing.allocator.free(results);
    try testing.expectEqual(@as(usize, 3), results.len);
    try testing.expectEqual(@as(u32, 2), results[0]);
    try testing.expectEqual(@as(u32, 5), results[1]);
    try testing.expectEqual(@as(u32, 7), results[2]);
}

test "trigram intersection across query trigrams" {
    var idx = explorer_mod.TrigramIndex.init(testing.allocator);
    defer idx.deinit();

    try idx.add_text(0, "hello world");
    try idx.add_text(1, "hello there");

    // "world" only matches file 0; "hello" matches both.
    const results = try idx.query("world");
    defer if (results.len > 0) testing.allocator.free(results);
    try testing.expectEqual(@as(usize, 1), results.len);
    try testing.expectEqual(@as(u32, 0), results[0]);
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
    defer {
        for (results) |r| testing.allocator.free(r.line_text);
        testing.allocator.free(results);
    }
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

// ── Explorer advanced queries ────────────────────────────────────────────────

test "explorer find_word exact lookup" {
    var exp = explorer_mod.Explorer.init(testing.allocator);
    defer exp.deinit();

    _ = try exp.add_file(.{
        .path = try testing.allocator.dupe(u8, "lib.rs"),
        .language = .rust,
        .line_count = 2,
        .byte_size = 30,
        .symbols = &[_]models.Symbol{},
        .imports = &[_][]const u8{},
    }, "fn compute() {}\nfn other() {}\n");
    exp.mark_indexing_complete();

    const hits = try exp.find_word("compute", 10);
    defer testing.allocator.free(hits);
    try testing.expectEqual(@as(usize, 1), hits.len);
}

test "explorer modified file drops stale results" {
    var exp = explorer_mod.Explorer.init(testing.allocator);
    defer exp.deinit();

    _ = try exp.add_file(.{
        .path = try testing.allocator.dupe(u8, "mod.rs"),
        .language = .rust,
        .line_count = 1,
        .byte_size = 20,
        .symbols = &[_]models.Symbol{},
        .imports = &[_][]const u8{},
    }, "fn alpha_token() {}\n");

    // Re-index the same path with new content (watcher modify event).
    _ = try exp.add_file(.{
        .path = try testing.allocator.dupe(u8, "mod.rs"),
        .language = .rust,
        .line_count = 1,
        .byte_size = 19,
        .symbols = &[_]models.Symbol{},
        .imports = &[_][]const u8{},
    }, "fn beta_token() {}\n");
    exp.mark_indexing_complete();

    // Stale trigram postings for alpha_token still exist, but content
    // verification must filter them out of every query path.
    const search_old = try exp.search_content("alpha_token", 10);
    defer testing.allocator.free(search_old);
    try testing.expectEqual(@as(usize, 0), search_old.len);

    const word_old = try exp.find_word("alpha_token", 10);
    defer testing.allocator.free(word_old);
    try testing.expectEqual(@as(usize, 0), word_old.len);

    const search_new = try exp.search_content("beta_token", 10);
    defer {
        for (search_new) |r| testing.allocator.free(r.line_text);
        testing.allocator.free(search_new);
    }
    try testing.expectEqual(@as(usize, 1), search_new.len);
    try testing.expectEqual(@as(usize, 1), exp.dirty_ops);
}

test "explorer compact sweeps stale postings and preserves results" {
    var exp = explorer_mod.Explorer.init(testing.allocator);
    defer exp.deinit();

    _ = try exp.add_file(.{
        .path = try testing.allocator.dupe(u8, "a.rs"),
        .language = .rust,
        .line_count = 1,
        .byte_size = 20,
        .symbols = &[_]models.Symbol{},
        .imports = &[_][]const u8{},
    }, "fn alpha_token() {}\n");
    _ = try exp.add_file(.{
        .path = try testing.allocator.dupe(u8, "a.rs"),
        .language = .rust,
        .line_count = 1,
        .byte_size = 19,
        .symbols = &[_]models.Symbol{},
        .imports = &[_][]const u8{},
    }, "fn beta_token() {}\n");
    exp.mark_indexing_complete();

    // Stale candidate exists before compaction (filtered only by verification)…
    const before = try exp.trigrams.query("alpha_token");
    defer if (before.len > 0) testing.allocator.free(before);
    try testing.expectEqual(@as(usize, 1), before.len);

    try exp.compact();
    try testing.expectEqual(@as(usize, 0), exp.dirty_ops);

    // …and is physically gone after: the trigram index has no candidate files.
    const stale = try exp.trigrams.query("alpha_token");
    defer if (stale.len > 0) testing.allocator.free(stale);
    try testing.expectEqual(@as(usize, 0), stale.len);

    // Live content still fully searchable after the swap.
    const live = try exp.search_content("beta_token", 10);
    defer {
        for (live) |r| testing.allocator.free(r.line_text);
        testing.allocator.free(live);
    }
    try testing.expectEqual(@as(usize, 1), live.len);
}

test "explorer search falls back to disk when content is evicted" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io_mod.io(), .{ .sub_path = "evicted.rs", .data = "fn gamma_token() {}\n" });
    const real_path = try tmp.dir.realPathFileAlloc(io_mod.io(), "evicted.rs", testing.allocator);
    defer testing.allocator.free(real_path);

    var exp = explorer_mod.Explorer.init(testing.allocator);
    defer exp.deinit();
    // Zero-byte cache: everything is evicted immediately after add_file.
    exp.max_cache_bytes = 0;

    _ = try exp.add_file(.{
        .path = try testing.allocator.dupe(u8, real_path),
        .language = .rust,
        .line_count = 1,
        .byte_size = 20,
        .symbols = &[_]models.Symbol{},
        .imports = &[_][]const u8{},
    }, "fn gamma_token() {}\n");
    exp.mark_indexing_complete();

    // Not in cache — must be re-read from disk, not silently skipped.
    const results = try exp.search_content("gamma_token", 10);
    defer {
        for (results) |r| testing.allocator.free(r.line_text);
        testing.allocator.free(results);
    }
    try testing.expectEqual(@as(usize, 1), results.len);

    const words = try exp.find_word("gamma_token", 10);
    defer testing.allocator.free(words);
    try testing.expectEqual(@as(usize, 1), words.len);
}

test "explorer oversized file gets no postings" {
    var exp = explorer_mod.Explorer.init(testing.allocator);
    defer exp.deinit();
    exp.max_posting_file_bytes = 16; // force the cap for the test

    _ = try exp.add_file(.{
        .path = try testing.allocator.dupe(u8, "big.json"),
        .language = .json,
        .line_count = 1,
        .byte_size = 32,
        .symbols = &[_]models.Symbol{},
        .imports = &[_][]const u8{},
    }, "{\"key\": \"delta_token_value\"}\n");
    exp.mark_indexing_complete();

    const candidates = try exp.trigrams.query("delta_token");
    defer if (candidates.len > 0) testing.allocator.free(candidates);
    try testing.expectEqual(@as(usize, 0), candidates.len);
}

test "explorer get_imports and get_imported_by" {
    var exp = explorer_mod.Explorer.init(testing.allocator);
    defer exp.deinit();

    const o1 = try make_outline(testing.allocator, "src/main.rs", .rust, &.{
        .{ .name = "main", .kind = .function, .line_start = 0, .line_end = 5 },
    }, &.{"crate::lib"});
    const o2 = try make_outline(testing.allocator, "src/lib.rs", .rust, &.{
        .{ .name = "helper", .kind = .function, .line_start = 0, .line_end = 3 },
    }, &.{});

    _ = try exp.add_file(o1, "fn main() {}\n");
    _ = try exp.add_file(o2, "fn helper() {}\n");
    exp.mark_indexing_complete();

    // main.rs imports lib.rs (resolved by crate::lib -> src/lib.rs)
    const imports = exp.get_imports("src/main.rs");
    try testing.expect(imports.len > 0);

    const imported_by = exp.get_imported_by("src/lib.rs");
    try testing.expect(imported_by.len > 0);
}

test "explorer file_path lookup" {
    var exp = explorer_mod.Explorer.init(testing.allocator);
    defer exp.deinit();

    _ = try exp.add_file(.{
        .path = try testing.allocator.dupe(u8, "module.rs"),
        .language = .rust,
        .line_count = 1,
        .byte_size = 10,
        .symbols = &[_]models.Symbol{},
        .imports = &[_][]const u8{},
    }, "fn foo() {}\n");
    exp.mark_indexing_complete();

    const path = exp.file_path(0);
    try testing.expect(path != null);
    try testing.expectEqualStrings("module.rs", path.?);

    try testing.expect(exp.file_path(999) == null);
}

test "explorer get_change_impact" {
    var exp = explorer_mod.Explorer.init(testing.allocator);
    defer exp.deinit();

    const o_main = try make_outline(testing.allocator, "src/main.rs", .rust, &.{
        .{ .name = "main", .kind = .function, .line_start = 0, .line_end = 5 },
    }, &.{"crate::lib"});
    const o_lib = try make_outline(testing.allocator, "src/lib.rs", .rust, &.{
        .{ .name = "helper", .kind = .function, .line_start = 0, .line_end = 3 },
    }, &.{});

    _ = try exp.add_file(o_main, "fn main() {}\n");
    _ = try exp.add_file(o_lib, "fn helper() {}\n");
    exp.mark_indexing_complete();

    const impact = try exp.get_change_impact("src/lib.rs", 10);
    defer testing.allocator.free(impact.direct);
    defer testing.allocator.free(impact.transitive);
    // main.rs depends on lib.rs, so lib.rs has at least 1 direct dependent
    try testing.expect(impact.direct.len > 0);
}

test "explorer total_content_bytes and total_line_count" {
    var exp = explorer_mod.Explorer.init(testing.allocator);
    defer exp.deinit();

    _ = try exp.add_file(.{
        .path = try testing.allocator.dupe(u8, "a.rs"),
        .language = .rust,
        .line_count = 3,
        .byte_size = 20,
        .symbols = &[_]models.Symbol{},
        .imports = &[_][]const u8{},
    }, "fn a() {}\nfn b() {}\n");
    _ = try exp.add_file(.{
        .path = try testing.allocator.dupe(u8, "b.rs"),
        .language = .rust,
        .line_count = 2,
        .byte_size = 15,
        .symbols = &[_]models.Symbol{},
        .imports = &[_][]const u8{},
    }, "fn c() {}\n");
    exp.mark_indexing_complete();

    try testing.expect(exp.total_content_bytes() > 0);
    try testing.expect(exp.total_line_count() >= 3);
}

test "explorer get_hot_files" {
    var exp = explorer_mod.Explorer.init(testing.allocator);
    defer exp.deinit();

    _ = try exp.add_file(.{
        .path = try testing.allocator.dupe(u8, "a.rs"),
        .language = .rust,
        .line_count = 1,
        .byte_size = 10,
        .symbols = &[_]models.Symbol{},
        .imports = &[_][]const u8{},
    }, "fn a() {}\n");
    _ = try exp.add_file(.{
        .path = try testing.allocator.dupe(u8, "b.rs"),
        .language = .rust,
        .line_count = 1,
        .byte_size = 10,
        .symbols = &[_]models.Symbol{},
        .imports = &[_][]const u8{},
    }, "fn b() {}\n");
    exp.mark_indexing_complete();

    const hot = exp.get_hot_files(2);
    try testing.expectEqual(@as(usize, 2), hot.len);
}

// ── Security scan ─────────────────────────────────────────────────────────────

test "security scan detects hardcoded secrets" {
    var exp = explorer_mod.Explorer.init(testing.allocator);
    defer exp.deinit();

    _ = try exp.add_file(.{
        .path = try testing.allocator.dupe(u8, "config.rs"),
        .language = .rust,
        .line_count = 2,
        .byte_size = 50,
        .symbols = &[_]models.Symbol{},
        .imports = &[_][]const u8{},
    }, "fn config() {\n    password = \"hunter2\"\n}\n");
    exp.mark_indexing_complete();

    const findings = try security_scan.scan(testing.allocator, &exp);
    defer security_scan.free_findings(testing.allocator, findings);
    var found_secret = false;
    for (findings) |f| {
        if (std.mem.eql(u8, f.rule, "hardcoded_secret")) found_secret = true;
    }
    try testing.expect(found_secret);
}

test "security scan detects unsafe blocks" {
    var exp = explorer_mod.Explorer.init(testing.allocator);
    defer exp.deinit();

    _ = try exp.add_file(.{
        .path = try testing.allocator.dupe(u8, "lowlevel.rs"),
        .language = .rust,
        .line_count = 3,
        .byte_size = 40,
        .symbols = &[_]models.Symbol{},
        .imports = &[_][]const u8{},
    }, "fn do_thing() {\n    unsafe { }\n}\n");
    exp.mark_indexing_complete();

    const findings = try security_scan.scan(testing.allocator, &exp);
    defer security_scan.free_findings(testing.allocator, findings);
    var found_unsafe = false;
    for (findings) |f| {
        if (std.mem.eql(u8, f.rule, "unsafe_block")) found_unsafe = true;
    }
    try testing.expect(found_unsafe);
}

test "security scan skips test files" {
    var exp = explorer_mod.Explorer.init(testing.allocator);
    defer exp.deinit();

    _ = try exp.add_file(.{
        .path = try testing.allocator.dupe(u8, "test_config.rs"),
        .language = .rust,
        .line_count = 2,
        .byte_size = 50,
        .symbols = &[_]models.Symbol{},
        .imports = &[_][]const u8{},
    }, "fn test_config() {\n    password = \"test\"\n}\n");
    exp.mark_indexing_complete();

    const findings = try security_scan.scan(testing.allocator, &exp);
    defer security_scan.free_findings(testing.allocator, findings);
    try testing.expectEqual(@as(usize, 0), findings.len);
}

test "security scan summary counts by severity" {
    const findings = [_]security_scan.Finding{
        .{ .file = "a.rs", .line = 1, .line_text = "", .rule = "r1", .severity = .critical },
        .{ .file = "a.rs", .line = 2, .line_text = "", .rule = "r2", .severity = .high },
        .{ .file = "a.rs", .line = 3, .line_text = "", .rule = "r3", .severity = .medium },
        .{ .file = "a.rs", .line = 4, .line_text = "", .rule = "r4", .severity = .low },
    };
    const s = security_scan.summarize(&findings);
    try testing.expectEqual(@as(usize, 4), s.total);
    try testing.expectEqual(@as(usize, 1), s.critical);
    try testing.expectEqual(@as(usize, 1), s.high);
    try testing.expectEqual(@as(usize, 1), s.medium);
    try testing.expectEqual(@as(usize, 1), s.low);
}

// ── Unwrap audit ──────────────────────────────────────────────────────────────

test "unwrap audit finds .unwrap() in non-test Rust" {
    var exp = explorer_mod.Explorer.init(testing.allocator);
    defer exp.deinit();

    _ = try exp.add_file(.{
        .path = try testing.allocator.dupe(u8, "handler.rs"),
        .language = .rust,
        .line_count = 2,
        .byte_size = 40,
        .symbols = &[_]models.Symbol{},
        .imports = &[_][]const u8{},
    }, "fn handle() {\n    let x = thing.unwrap();\n}\n");
    exp.mark_indexing_complete();

    const findings = try unwrap_audit.audit(testing.allocator, &exp);
    defer testing.allocator.free(findings);
    try testing.expect(findings.len > 0);
    try testing.expectEqual(unwrap_audit.Kind.unwrap, findings[0].kind);
}

test "unwrap audit skips non-rust files" {
    var exp = explorer_mod.Explorer.init(testing.allocator);
    defer exp.deinit();

    _ = try exp.add_file(.{
        .path = try testing.allocator.dupe(u8, "app.py"),
        .language = .python,
        .line_count = 2,
        .byte_size = 40,
        .symbols = &[_]models.Symbol{},
        .imports = &[_][]const u8{},
    }, "def handle():\n    x = thing.unwrap()\n");
    exp.mark_indexing_complete();

    const findings = try unwrap_audit.audit(testing.allocator, &exp);
    defer testing.allocator.free(findings);
    try testing.expectEqual(@as(usize, 0), findings.len);
}

// ── Dead code ─────────────────────────────────────────────────────────────────

test "dead code finds unreferenced symbols" {
    var exp = explorer_mod.Explorer.init(testing.allocator);
    defer exp.deinit();

    const o_a = try make_outline(testing.allocator, "a.rs", .rust, &.{
        .{ .name = "used_func", .kind = .function, .line_start = 0, .line_end = 3 },
        .{ .name = "lonely_func", .kind = .function, .line_start = 4, .line_end = 7 },
    }, &.{});
    const o_b = try make_outline(testing.allocator, "b.rs", .rust, &.{}, &.{});

    _ = try exp.add_file(o_a, "fn used_func() {}\nfn lonely_func() {}\n");
    _ = try exp.add_file(o_b, "// b references used_func\n");
    exp.mark_indexing_complete();

    const dead = try dead_code.find_dead_code(testing.allocator, &exp);
    defer testing.allocator.free(dead);
    var found_lonely = false;
    for (dead) |d| {
        if (std.mem.eql(u8, d.name, "lonely_func")) found_lonely = true;
    }
    try testing.expect(found_lonely);
}

test "dead code skips short names and test symbols" {
    var exp = explorer_mod.Explorer.init(testing.allocator);
    defer exp.deinit();

    const o = try make_outline(testing.allocator, "lib.rs", .rust, &.{
        .{ .name = "ab", .kind = .function, .line_start = 0, .line_end = 1 },
        .{ .name = "test_thing", .kind = .@"test", .line_start = 2, .line_end = 3 },
    }, &.{});

    _ = try exp.add_file(o, "fn ab() {}\n#[test] fn test_thing() {}\n");
    exp.mark_indexing_complete();

    const dead = try dead_code.find_dead_code(testing.allocator, &exp);
    defer testing.allocator.free(dead);
    // Both should be skipped (short name + test kind)
    for (dead) |d| {
        try testing.expect(!std.mem.eql(u8, d.name, "ab"));
        try testing.expect(!std.mem.eql(u8, d.name, "test_thing"));
    }
}

// ── Cycles ───────────────────────────────────────────────────────────────────

test "cycles detects two-file circular dependency" {
    var exp = explorer_mod.Explorer.init(testing.allocator);
    defer exp.deinit();

    const o_a = try make_outline(testing.allocator, "src/a.rs", .rust, &.{}, &.{"crate::b"});
    const o_b = try make_outline(testing.allocator, "src/b.rs", .rust, &.{}, &.{"crate::a"});

    _ = try exp.add_file(o_a, "fn a() {}\n");
    _ = try exp.add_file(o_b, "fn b() {}\n");
    exp.mark_indexing_complete();

    var report = try cycles.analyze(testing.allocator, &exp);
    defer cycles.free_report(testing.allocator, &report);
    try testing.expect(report.cycles.len > 0);
}

test "cycles returns empty for acyclic graph" {
    var exp = explorer_mod.Explorer.init(testing.allocator);
    defer exp.deinit();

    const o_a = try make_outline(testing.allocator, "src/a.rs", .rust, &.{}, &.{"crate::b"});
    const o_b = try make_outline(testing.allocator, "src/b.rs", .rust, &.{}, &.{});

    _ = try exp.add_file(o_a, "fn a() {}\n");
    _ = try exp.add_file(o_b, "fn b() {}\n");
    exp.mark_indexing_complete();

    var report = try cycles.analyze(testing.allocator, &exp);
    defer cycles.free_report(testing.allocator, &report);
    try testing.expectEqual(@as(usize, 0), report.cycles.len);
}

// ── Coupling ──────────────────────────────────────────────────────────────────

test "coupling computes fan_in and fan_out" {
    var exp = explorer_mod.Explorer.init(testing.allocator);
    defer exp.deinit();

    const o_a = try make_outline(testing.allocator, "src/a.rs", .rust, &.{}, &.{"crate::b"});
    const o_b = try make_outline(testing.allocator, "src/b.rs", .rust, &.{}, &.{});

    _ = try exp.add_file(o_a, "fn a() {}\n");
    _ = try exp.add_file(o_b, "fn b() {}\n");
    exp.mark_indexing_complete();

    var report = try coupling.analyze(testing.allocator, &exp);
    defer coupling.free_report(testing.allocator, &report);
    // a.rs has fan_out=1, fan_in=0; b.rs has fan_out=0, fan_in=1
    var found_b_imported = false;
    for (report.metrics) |m| {
        if (std.mem.eql(u8, m.file, "src/a.rs")) {
            try testing.expectEqual(@as(usize, 0), m.fan_in);
        }
        if (std.mem.eql(u8, m.file, "src/b.rs")) {
            try testing.expect(m.fan_in > 0);
            found_b_imported = true;
        }
    }
    try testing.expect(found_b_imported);
}

// ── Test coverage ─────────────────────────────────────────────────────────────

test "test_coverage classifies files" {
    var exp = explorer_mod.Explorer.init(testing.allocator);
    defer exp.deinit();

    const o_src = try make_outline(testing.allocator, "src/lib.rs", .rust, &.{
        .{ .name = "public_fn", .kind = .function, .line_start = 0, .line_end = 3 },
    }, &.{});
    const o_test = try make_outline(testing.allocator, "tests/lib_test.rs", .rust, &.{
        .{ .name = "test_public_fn", .kind = .@"test", .line_start = 0, .line_end = 5 },
        .{ .name = "public_fn", .kind = .function, .line_start = 6, .line_end = 8 },
    }, &.{});

    _ = try exp.add_file(o_src, "pub fn public_fn() {}\n");
    _ = try exp.add_file(o_test, "#[test] fn test_public_fn() {}\nfn public_fn() {}\n");
    exp.mark_indexing_complete();

    const coverage = try test_coverage.analyze(testing.allocator, &exp);
    defer testing.allocator.free(coverage);
    // src/lib.rs should have at least some coverage (public_fn is referenced in test)
    var found_src = false;
    for (coverage) |c| {
        if (std.mem.eql(u8, c.file, "src/lib.rs")) {
            try testing.expect(c.total_symbols > 0);
            try testing.expect(c.referenced_in_tests > 0);
            found_src = true;
        }
    }
    try testing.expect(found_src);
}

// ── Architecture ──────────────────────────────────────────────────────────────

test "architecture detects layer violations" {
    var exp = explorer_mod.Explorer.init(testing.allocator);
    defer exp.deinit();

    // domain importing from gateway = violation (infrastructure -> presentation)
    const o_domain = try make_outline(testing.allocator, "src/domain/model.rs", .rust, &.{}, &.{"crate::gateway::api"});
    const o_gateway = try make_outline(testing.allocator, "src/gateway/api.rs", .rust, &.{}, &.{});

    _ = try exp.add_file(o_domain, "fn model() {}\n");
    _ = try exp.add_file(o_gateway, "fn api() {}\n");
    exp.mark_indexing_complete();

    const violations = try architecture.analyze(testing.allocator, &exp);
    defer testing.allocator.free(violations);
    try testing.expect(violations.len > 0);
}

test "architecture no violations for correct layering" {
    var exp = explorer_mod.Explorer.init(testing.allocator);
    defer exp.deinit();

    // gateway importing from domain = correct (presentation -> domain)
    const o_gateway = try make_outline(testing.allocator, "src/gateway/api.rs", .rust, &.{}, &.{"crate::domain::model"});
    const o_domain = try make_outline(testing.allocator, "src/domain/model.rs", .rust, &.{}, &.{});

    _ = try exp.add_file(o_gateway, "fn api() {}\n");
    _ = try exp.add_file(o_domain, "fn model() {}\n");
    exp.mark_indexing_complete();

    const violations = try architecture.analyze(testing.allocator, &exp);
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
}

// ── Language detection edge cases ─────────────────────────────────────────────

test "language detection edge cases" {
    try testing.expectEqual(models.Language.unknown, models.Language.from_path("file"));
    try testing.expectEqual(models.Language.unknown, models.Language.from_path(""));
    try testing.expectEqual(models.Language.make, models.Language.from_path("Makefile"));
    try testing.expectEqual(models.Language.make, models.Language.from_path("makefile"));
    try testing.expectEqual(models.Language.dockerfile, models.Language.from_path("Dockerfile"));
    try testing.expectEqual(models.Language.dockerfile, models.Language.from_path("Dockerfile.dev"));
    try testing.expectEqual(models.Language.gitignore, models.Language.from_path(".gitignore"));
    try testing.expectEqual(models.Language.cmake, models.Language.from_path("CMakeLists.txt"));
    try testing.expectEqual(models.Language.javascript, models.Language.from_path("app.mjs"));
    try testing.expectEqual(models.Language.javascript, models.Language.from_path("app.cjs"));
    try testing.expectEqual(models.Language.typescript, models.Language.from_path("app.tsx"));
    try testing.expectEqual(models.Language.cpp, models.Language.from_path("lib.cc"));
    try testing.expectEqual(models.Language.cpp, models.Language.from_path("lib.cxx"));
    try testing.expectEqual(models.Language.hcl, models.Language.from_path("main.tf"));
    try testing.expectEqual(models.Language.ini, models.Language.from_path("app.ini"));
    try testing.expectEqual(models.Language.ini, models.Language.from_path("app.cfg"));
    try testing.expectEqual(models.Language.ini, models.Language.from_path("app.conf"));
}

test "symbol kind as_str round-trip" {
    try testing.expectEqualStrings("function", models.SymbolKind.function.as_str());
    try testing.expectEqualStrings("method", models.SymbolKind.method.as_str());
    try testing.expectEqualStrings("struct", models.SymbolKind.@"struct".as_str());
    try testing.expectEqualStrings("test", models.SymbolKind.@"test".as_str());
    try testing.expectEqualStrings("unknown", models.SymbolKind.unknown.as_str());
}

// ── Explorer update / remove ──────────────────────────────────────────────────

test "explorer re-add file updates indexes" {
    var exp = explorer_mod.Explorer.init(testing.allocator);
    defer exp.deinit();

    _ = try exp.add_file(.{
        .path = try testing.allocator.dupe(u8, "lib.rs"),
        .language = .rust,
        .line_count = 1,
        .byte_size = 20,
        .symbols = &[_]models.Symbol{},
        .imports = &[_][]const u8{},
    }, "fn old_name() {}\n");

    // Re-add with new content
    _ = try exp.add_file(.{
        .path = try testing.allocator.dupe(u8, "lib.rs"),
        .language = .rust,
        .line_count = 1,
        .byte_size = 20,
        .symbols = &[_]models.Symbol{},
        .imports = &[_][]const u8{},
    }, "fn new_name() {}\n");
    exp.mark_indexing_complete();

    // Old content should be gone
    const old_results = try exp.search_content("old_name", 5);
    defer testing.allocator.free(old_results);
    try testing.expectEqual(@as(usize, 0), old_results.len);

    // New content should be indexed
    const new_results = try exp.search_content("new_name", 5);
    defer {
        for (new_results) |r| testing.allocator.free(r.line_text);
        testing.allocator.free(new_results);
    }
    try testing.expectEqual(@as(usize, 1), new_results.len);
}

test "explorer remove file cleans all indexes" {
    var exp = explorer_mod.Explorer.init(testing.allocator);
    defer exp.deinit();

    _ = try exp.add_file(.{
        .path = try testing.allocator.dupe(u8, "temp.rs"),
        .language = .rust,
        .line_count = 1,
        .byte_size = 20,
        .symbols = &[_]models.Symbol{},
        .imports = &[_][]const u8{},
    }, "fn unique_name() {}\n");
    exp.mark_indexing_complete();

    try testing.expectEqual(@as(usize, 1), exp.file_count());

    try exp.remove_file("temp.rs");
    try testing.expectEqual(@as(usize, 0), exp.file_count());

    const results = try exp.search_content("unique_name", 5);
    defer testing.allocator.free(results);
    try testing.expectEqual(@as(usize, 0), results.len);
}

test "explorer set_status and indexing flag" {
    var exp = explorer_mod.Explorer.init(testing.allocator);
    defer exp.deinit();

    try testing.expect(exp.is_indexing());
    exp.set_status("test message");
    try testing.expect(exp.status_message != null);
    try testing.expectEqualStrings("test message", exp.status_message.?);

    exp.mark_indexing_complete();
    try testing.expect(!exp.is_indexing());
}

// ── Parser / tags.scm symbol extraction ────────────────────────────────────────
// Real tree-sitter parses guarding against grammar bumps silently breaking the
// hand-written queries under src/parser/queries/ (a broken query yields zero
// symbols, so each language must keep extracting its expected symbols).

/// Parse literal source and assert a symbol with `name` was extracted.
fn expect_symbol(lang: models.Language, source: []const u8, name: []const u8) !void {
    var parser = try treesitter.Parser.init(testing.allocator);
    defer parser.deinit();
    var outline = try parser.parse_source("test_input", lang, source);
    defer outline.deinit(testing.allocator);

    for (outline.symbols) |s| {
        if (std.mem.eql(u8, s.name, name)) return;
    }
    std.debug.print("symbol '{s}' not found in {s}; got: ", .{ name, @tagName(lang) });
    for (outline.symbols) |s| std.debug.print("{s} ", .{s.name});
    std.debug.print("\n", .{});
    return error.SymbolNotFound;
}

test "parser: rust extracts fn and struct" {
    try expect_symbol(.rust, "pub fn greet() {}\nstruct User { id: u64 }\n", "greet");
    try expect_symbol(.rust, "pub fn greet() {}\nstruct User { id: u64 }\n", "User");
}

test "parser: zig extracts fn, const decl and test" {
    const src =
        \\pub fn hello() void {}
        \\const Foo = struct { x: u32 };
        \\test "it works" {}
        \\
    ;
    try expect_symbol(.zig, src, "hello");
    try expect_symbol(.zig, src, "Foo");
}

test "parser: json extracts top-level keys only" {
    const src = "{ \"name\": \"demo\", \"nested\": { \"inner\": 1 } }";
    try expect_symbol(.json, src, "name");
    // nested keys must NOT be extracted (query anchored to document > object)
    var parser = try treesitter.Parser.init(testing.allocator);
    defer parser.deinit();
    var outline = try parser.parse_source("t.json", .json, src);
    defer outline.deinit(testing.allocator);
    for (outline.symbols) |s| try testing.expect(!std.mem.eql(u8, s.name, "inner"));
}

test "parser: toml extracts tables and top-level keys" {
    const src = "title = \"demo\"\n[server]\nhost = \"x\"\n";
    try expect_symbol(.toml, src, "title");
    try expect_symbol(.toml, src, "server");
}

test "parser: yaml extracts top-level mapping keys" {
    try expect_symbol(.yaml, "name: demo\nserver:\n  host: x\n", "name");
}

test "parser: sql extracts table, view and index names" {
    const src =
        \\CREATE TABLE users (id INT);
        \\CREATE VIEW active AS SELECT * FROM users;
        \\CREATE INDEX idx_users ON users (id);
        \\
    ;
    try expect_symbol(.sql, src, "users");
    try expect_symbol(.sql, src, "active");
    try expect_symbol(.sql, src, "idx_users");
}

test "parser: css extracts class, id and keyframes" {
    const src = ".btn { color: red; }\n#main { width: 100%; }\n@keyframes spin { from {} to {} }\n";
    try expect_symbol(.css, src, "btn");
    try expect_symbol(.css, src, "main");
    try expect_symbol(.css, src, "spin");
}

test "parser: scss extracts function and mixin" {
    const src = "@function double($n) { @return $n * 2; }\n@mixin center { margin: auto; }\n";
    try expect_symbol(.scss, src, "double");
    try expect_symbol(.scss, src, "center");
}

test "parser: nix extracts attribute bindings" {
    try expect_symbol(.nix, "let myPackage = 1;\nin { inherit myPackage; }\n", "myPackage");
}

// ── Dependency resolution + path lookup ─────────────────────────────────────────
// Guards the two-pass resolver (edges to later-indexed files) and relative-path
// query lookup (files are stored with full paths; callers pass relative paths).

test "deps resolve regardless of index order and query by relative path" {
    var exp = explorer_mod.Explorer.init(testing.allocator);
    defer exp.deinit();

    // Stored with full paths, as the scanner does. lib & foo are indexed BEFORE
    // bar, so without a second resolution pass their edges to bar would be lost.
    const o_lib = try make_outline(testing.allocator, "/ws/src/lib.rs", .rust, &.{}, &.{ "foo", "bar" });
    const o_foo = try make_outline(testing.allocator, "/ws/src/foo.rs", .rust, &.{}, &.{"crate::bar::helper"});
    const o_bar = try make_outline(testing.allocator, "/ws/src/bar.rs", .rust, &.{}, &.{});
    _ = try exp.add_file(o_lib, "pub mod foo;\npub mod bar;\n");
    _ = try exp.add_file(o_foo, "use crate::bar::helper;\n");
    _ = try exp.add_file(o_bar, "pub fn helper() {}\n");
    exp.mark_indexing_complete();

    // Query by workspace-relative path (find_file_id suffix match).
    try testing.expectEqual(@as(usize, 2), exp.get_imports("src/lib.rs").len);
    // `use crate::bar::helper` must resolve to bar.rs (case-2 trailing strip).
    try testing.expectEqual(@as(usize, 1), exp.get_imports("src/foo.rs").len);
    // Reverse deps: bar is imported by both lib and foo.
    try testing.expectEqual(@as(usize, 2), exp.get_imported_by("src/bar.rs").len);
    // get_outline by relative path must succeed (the get_outline path-lookup bug).
    try testing.expect(exp.get_outline("src/foo.rs") != null);
}

test "find_file_id does not match across path-segment boundaries" {
    var exp = explorer_mod.Explorer.init(testing.allocator);
    defer exp.deinit();
    const o = try make_outline(testing.allocator, "/ws/src/barfoo.rs", .rust, &.{}, &.{});
    _ = try exp.add_file(o, "fn x() {}\n");
    exp.mark_indexing_complete();
    // "foo.rs" must NOT match "barfoo.rs" (no '/' boundary).
    try testing.expect(exp.get_outline("foo.rs") == null);
    try testing.expect(exp.get_outline("barfoo.rs") != null);
}

test "zig @import resolves relative paths" {
    var exp = explorer_mod.Explorer.init(testing.allocator);
    defer exp.deinit();
    // snapshot.zig imports ../index/explorer.zig and ../core/io.zig; std is ignored.
    const o_snap = try make_outline(testing.allocator, "/ws/src/storage/snapshot.zig", .zig, &.{}, &.{ "std", "../index/explorer.zig", "../core/io.zig" });
    const o_exp = try make_outline(testing.allocator, "/ws/src/index/explorer.zig", .zig, &.{}, &.{});
    const o_io = try make_outline(testing.allocator, "/ws/src/core/io.zig", .zig, &.{}, &.{});
    _ = try exp.add_file(o_snap, "const std = @import(\"std\");\n");
    _ = try exp.add_file(o_exp, "pub const Explorer = struct {};\n");
    _ = try exp.add_file(o_io, "pub fn io() void {}\n");
    exp.mark_indexing_complete();

    // Two relative .zig imports resolve; "std" is skipped.
    try testing.expectEqual(@as(usize, 2), exp.get_imports("src/storage/snapshot.zig").len);
    try testing.expectEqual(@as(usize, 1), exp.get_imported_by("src/core/io.zig").len);
}

// ── Axis A: symbol extraction for the remaining languages ───────────────────────

test "axis A: bash/dockerfile/make/markdown/ini/hcl symbols" {
    try expect_symbol(.bash, "greet() { echo hi; }\nfunction deploy() { :; }\n", "greet");
    try expect_symbol(.dockerfile, "FROM alpine AS runtime\n", "runtime");
    try expect_symbol(.make, "build:\n\tgo build\n", "build");
    try expect_symbol(.markdown, "# Title\n## Install\n", "Title");
    try expect_symbol(.ini, "[server]\nhost = x\n", "host");
    // HCL captures block labels (resource type/name), not the block keyword.
    try expect_symbol(.hcl, "resource \"aws_instance\" \"web\" {}\n", "aws_instance");
    try expect_symbol(.hcl, "resource \"aws_instance\" \"web\" {}\n", "web");
}

// ── Axis B: import resolution for the remaining languages ────────────────────────

fn expect_resolves(lang: models.Language, importer: []const u8, imps: []const []const u8, target: []const u8) !void {
    var exp = explorer_mod.Explorer.init(testing.allocator);
    defer exp.deinit();
    const o1 = try make_outline(testing.allocator, importer, lang, &.{}, imps);
    const o2 = try make_outline(testing.allocator, target, lang, &.{}, &.{});
    _ = try exp.add_file(o1, "x\n");
    _ = try exp.add_file(o2, "x\n");
    exp.mark_indexing_complete();
    try testing.expectEqual(@as(usize, 1), exp.get_imports(importer).len);
}

test "axis B: resolver maps imports to files per language" {
    try expect_resolves(.java, "/ws/com/foo/Main.java", &.{"com.foo.Helper"}, "/ws/com/foo/Helper.java");
    try expect_resolves(.kotlin, "/ws/app/App.kt", &.{"lib.Service"}, "/ws/lib/Service.kt");
    try expect_resolves(.scala, "/ws/app/App.scala", &.{"lib.Service"}, "/ws/lib/Service.scala");
    try expect_resolves(.lua, "/ws/app/init.lua", &.{"lib.util"}, "/ws/lib/util.lua");
    try expect_resolves(.ruby, "/ws/app/main.rb", &.{"util"}, "/ws/app/util.rb");
    try expect_resolves(.dart, "/ws/app/page.dart", &.{"../lib/widget.dart"}, "/ws/lib/widget.dart");
}

fn extracted(lang: models.Language, src: []const u8, expected: []const u8) !bool {
    var imps = std.ArrayList([]const u8).empty;
    defer {
        for (imps.items) |i| testing.allocator.free(i);
        imps.deinit(testing.allocator);
    }
    try import_scan.extract(testing.allocator, lang, src, &imps);
    for (imps.items) |i| if (std.mem.eql(u8, i, expected)) return true;
    return false;
}

test "axis B: import_scan extracts import specs" {
    try testing.expect(try extracted(.ruby, "require_relative 'util'\n", "util"));
    try testing.expect(try extracted(.lua, "local m = require('lib.util')\n", "lib.util"));
    try testing.expect(try extracted(.dart, "import '../lib/widget.dart';\n", "../lib/widget.dart"));
    try testing.expect(try extracted(.kotlin, "import lib.Service\n", "lib.Service"));
    try testing.expect(try extracted(.scala, "import a.b.{X, Y}\n", "a.b"));
}

test "language detection: headers and case-insensitivity" {
    // C/C++ headers must be recognized so #include targets get indexed.
    try testing.expectEqual(models.Language.c, models.Language.from_path("lib.h"));
    try testing.expectEqual(models.Language.cpp, models.Language.from_path("lib.hpp"));
    // Extension match is case-insensitive (.R is the conventional R extension).
    try testing.expectEqual(models.Language.r, models.Language.from_path("script.R"));
    try testing.expectEqual(models.Language.python, models.Language.from_path("App.PY"));
}

test "parser: typescript and javascript extract real declarations" {
    const ts = "export function aa(){}\nclass Widget {}\ninterface Props {}\nconst x = 1;\n";
    try expect_symbol(.typescript, ts, "aa");
    try expect_symbol(.typescript, ts, "Widget");
    try expect_symbol(.typescript, ts, "Props");
    try expect_symbol(.javascript, "export function go(){}\nclass App {}\n", "go");
    try expect_symbol(.javascript, "export function go(){}\nclass App {}\n", "App");
}

test "http: write_json_string escapes quotes and control chars" {
    const http = @import("server/http.zig");
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    // A symbol name with embedded quotes (e.g. Go import "x/y") must stay valid JSON.
    try http.write_json_string(&w, "\"x/y\"");
    try testing.expectEqualStrings("\"\\\"x/y\\\"\"", w.buffered());
}

// ── Symbol extraction: the remaining working languages ──────────────────────────

test "parser: symbols for go/python/c/cpp/java/ruby/csharp/kotlin/scala/lua/elixir/r/swift/dart/html" {
    try expect_symbol(.go, "package main\nfunc Main(){}\n", "Main");
    try expect_symbol(.python, "def thing():\n    pass\n", "thing");
    try expect_symbol(.c, "int helper(){ return 0; }\n", "helper");
    try expect_symbol(.cpp, "class Foo {};\n", "Foo");
    try expect_symbol(.java, "public class Helper {}\n", "Helper");
    try expect_symbol(.ruby, "def helper\nend\n", "helper");
    try expect_symbol(.c_sharp, "class Program { void Run(){} }\n", "Program");
    try expect_symbol(.kotlin, "class Service\n", "Service");
    try expect_symbol(.scala, "class Service {}\n", "Service");
    try expect_symbol(.lua, "function aa() end\n", "aa");
    try expect_symbol(.elixir, "defmodule MyMod do\nend\n", "MyMod");
    try expect_symbol(.r, "my_func <- function(x) { x }\n", "my_func");
    try expect_symbol(.swift, "func greet() {}\n", "greet");
    try expect_symbol(.dart, "class Page {}\n", "Page");
    try expect_symbol(.html, "<div id=\"app\"></div>\n", "div");
}

// ── JSON output validity for every working language ─────────────────────────────
// Serialize parsed symbols exactly as the get_outline handler does (via the real
// http.write_json_string escaper) and assert the result parses as valid JSON.

fn expect_valid_json_outline(lang: models.Language, source: []const u8) !void {
    const http = @import("server/http.zig");
    var parser = try treesitter.Parser.init(testing.allocator);
    defer parser.deinit();
    var outline = try parser.parse_source("t", lang, source);
    defer outline.deinit(testing.allocator);

    var buf: [1 << 16]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try w.writeAll("{\"symbols\":[");
    for (outline.symbols, 0..) |s, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"name\":");
        try http.write_json_string(&w, s.name);
        try w.print(",\"kind\":\"{s}\",\"line_start\":{d},\"line_end\":{d}}}", .{ s.kind.as_str(), s.line_start, s.line_end });
    }
    try w.writeAll("]}");

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, w.buffered(), .{});
    parsed.deinit();
}

test "every working language serializes to valid JSON" {
    const cases = [_]struct { lang: models.Language, src: []const u8 }{
        .{ .lang = .rust, .src = "pub fn f(){}\nstruct S{}\n" },
        .{ .lang = .python, .src = "def f():\n    pass\n" },
        // Go import paths yield symbol names containing quotes — the original bug.
        .{ .lang = .go, .src = "package m\nimport \"ex.com/m/u\"\nfunc F(){}\n" },
        .{ .lang = .typescript, .src = "export function f(){}\nclass C{}\n" },
        .{ .lang = .javascript, .src = "function f(){}\nclass C{}\n" },
        .{ .lang = .c, .src = "int f(){return 0;}\n" },
        .{ .lang = .cpp, .src = "class C{};\n" },
        .{ .lang = .zig, .src = "pub fn f() void {}\n" },
        .{ .lang = .java, .src = "class C {}\n" },
        .{ .lang = .ruby, .src = "def f\nend\n" },
        .{ .lang = .c_sharp, .src = "class C { void M(){} }\n" },
        .{ .lang = .kotlin, .src = "class C\n" },
        .{ .lang = .scala, .src = "class C {}\n" },
        .{ .lang = .elixir, .src = "defmodule M do\nend\n" },
        .{ .lang = .r, .src = "f <- function(x){x}\n" },
        .{ .lang = .swift, .src = "func f(){}\n" },
        .{ .lang = .dart, .src = "class C {}\n" },
        .{ .lang = .lua, .src = "function aa() end\n" },
        .{ .lang = .nix, .src = "let a = 1;\nin a\n" },
        .{ .lang = .json, .src = "{\"k\":1}\n" },
        .{ .lang = .toml, .src = "k = 1\n" },
        .{ .lang = .yaml, .src = "k: 1\n" },
        .{ .lang = .css, .src = ".c{}\n" },
        .{ .lang = .scss, .src = ".c{}\n" },
        .{ .lang = .html, .src = "<div></div>\n" },
        .{ .lang = .sql, .src = "CREATE TABLE t(id INT);\n" },
        .{ .lang = .bash, .src = "f(){ echo x; }\n" },
        .{ .lang = .hcl, .src = "resource \"a\" \"b\" {}\n" },
        .{ .lang = .dockerfile, .src = "FROM x AS y\n" },
        .{ .lang = .make, .src = "build:\n\tx\n" },
        .{ .lang = .markdown, .src = "# H\n" },
        .{ .lang = .ini, .src = "[s]\nk = v\n" },
    };
    for (cases) |c| try expect_valid_json_outline(c.lang, c.src);
}

test "axis B: dep resolution for go/python/ts/js/c/cpp" {
    try expect_resolves(.go, "/ws/main.go", &.{"ex.com/m/util"}, "/ws/util/util.go");
    try expect_resolves(.python, "/ws/app.py", &.{"helpers"}, "/ws/helpers.py");
    try expect_resolves(.typescript, "/ws/a.ts", &.{"./b"}, "/ws/b.ts");
    try expect_resolves(.javascript, "/ws/a.js", &.{"./b"}, "/ws/b.js");
    try expect_resolves(.c, "/ws/main.c", &.{"lib.h"}, "/ws/lib.h");
    try expect_resolves(.cpp, "/ws/main.cpp", &.{"lib.hpp"}, "/ws/lib.hpp");
}

// ── Symbol cleanliness: only definitions, no reference/call/import noise ─────────

fn expect_no_symbol(lang: models.Language, source: []const u8, unwanted: []const u8) !void {
    var parser = try treesitter.Parser.init(testing.allocator);
    defer parser.deinit();
    var outline = try parser.parse_source("t", lang, source);
    defer outline.deinit(testing.allocator);
    for (outline.symbols) |s| {
        if (std.mem.eql(u8, s.name, unwanted)) {
            std.debug.print("unexpected non-definition symbol '{s}' in {s}\n", .{ unwanted, @tagName(lang) });
            return error.UnexpectedSymbol;
        }
    }
}

test "parser: references and call-sites are not emitted as symbols" {
    // Go: the import string literal and call-sites must not be symbols.
    const go = "package main\nimport \"x/y\"\nfunc Main(){ Do() }\n";
    try expect_no_symbol(.go, go, "\"x/y\"");
    try expect_no_symbol(.go, go, "main");
    try expect_symbol(.go, go, "Main");
    // Lua: the require call is not a symbol.
    try expect_no_symbol(.lua, "local u = require('x')\nfunction aa() end\n", "require");
    // Ruby: require_relative is not a symbol.
    try expect_no_symbol(.ruby, "require_relative 'x'\ndef run\nend\n", "require_relative");
    // Elixir: the defmodule/def macro keywords are not symbols.
    try expect_no_symbol(.elixir, "defmodule M do\n  def hi, do: 1\nend\n", "defmodule");
    try expect_no_symbol(.elixir, "defmodule M do\n  def hi, do: 1\nend\n", "def");
}

test "axis B: file-level dep resolution for nix/css/scss/bash/make/html/hcl/r" {
    try expect_resolves(.nix, "/ws/default.nix", &.{"./lib.nix"}, "/ws/lib.nix");
    try expect_resolves(.css, "/ws/main.css", &.{"base.css"}, "/ws/base.css");
    try expect_resolves(.scss, "/ws/main.scss", &.{"buttons"}, "/ws/_buttons.scss");
    try expect_resolves(.bash, "/ws/run.sh", &.{"./lib.sh"}, "/ws/lib.sh");
    try expect_resolves(.make, "/ws/Makefile", &.{"common.mk"}, "/ws/common.mk");
    try expect_resolves(.html, "/ws/index.html", &.{"app.js"}, "/ws/app.js");
    try expect_resolves(.hcl, "/ws/main.tf", &.{"./modules/vpc"}, "/ws/modules/vpc/main.tf");
    try expect_resolves(.r, "/ws/main.R", &.{"util.R"}, "/ws/util.R");
}

test "axis B: ansible (yaml) includes and jinja template deps" {
    try expect_resolves(.yaml, "/ws/play.yml", &.{"setup.yml"}, "/ws/setup.yml");
    try expect_resolves(.jinja2, "/ws/page.j2", &.{"base.html"}, "/ws/base.html");
    // dialect extractors fire on the right syntax
    try testing.expect(try extracted(.yaml, "tasks:\n  - include_tasks: setup.yml\n", "setup.yml"));
    try testing.expect(try extracted(.yaml, "- import_playbook: deploy.yml\n", "deploy.yml"));
    try testing.expect(try extracted(.jinja2, "{% extends \"base.html\" %}\n", "base.html"));
    try testing.expect(try extracted(.jinja2, "{% include 'nav.html' %}\n", "nav.html"));
    // plain (non-Ansible) yaml keys are NOT treated as imports
    try testing.expect(!try extracted(.yaml, "name: x\nhost: y\n", "y"));
}

test "axis B: typescript ESM .js import maps to .ts source" {
    try expect_resolves(.typescript, "/ws/src/index.ts", &.{"./queue.js"}, "/ws/src/queue.ts");
    try expect_resolves(.typescript, "/ws/src/a.ts", &.{"./b.ts"}, "/ws/src/b.ts");
}

test "analyze: duplication flags reinvented free functions, not interface methods" {
    var exp = explorer_mod.Explorer.init(testing.allocator);
    defer exp.deinit();
    // getEnv as a free function in two files = reinvention.
    _ = try exp.add_file(try make_outline(testing.allocator, "/ws/a/util.go", .go, &.{.{ .name = "getEnv", .kind = .function, .line_start = 0, .line_end = 1 }}, &.{}), "x\n");
    _ = try exp.add_file(try make_outline(testing.allocator, "/ws/b/util.go", .go, &.{.{ .name = "getEnv", .kind = .function, .line_start = 0, .line_end = 1 }}, &.{}), "x\n");
    // Close as a *method* in two files = interface conformance, must NOT count.
    _ = try exp.add_file(try make_outline(testing.allocator, "/ws/c.go", .go, &.{.{ .name = "Close", .kind = .method, .line_start = 0, .line_end = 1 }}, &.{}), "x\n");
    _ = try exp.add_file(try make_outline(testing.allocator, "/ws/d.go", .go, &.{.{ .name = "Close", .kind = .method, .line_start = 0, .line_end = 1 }}, &.{}), "x\n");
    exp.mark_indexing_complete();

    var report = try duplication.analyze(testing.allocator, &exp);
    defer report.deinit(testing.allocator);
    var found_getenv = false;
    var found_close = false;
    for (report.clusters) |c| {
        if (std.mem.eql(u8, c.name, "getEnv")) {
            found_getenv = true;
            try testing.expectEqual(@as(usize, 2), c.files.len);
        }
        if (std.mem.eql(u8, c.name, "Close")) found_close = true;
    }
    try testing.expect(found_getenv);
    try testing.expect(!found_close);
}

test "clones: fingerprint is whitespace/comment/name-independent" {
    // >=6 real lines so the MIN_LINES gate passes; differ only in formatting/comments.
    const a = [_][]const u8{ "  let x = compute(a, b);", "  // explain", "  if (x > 0) {", "    log(x);", "    return x;", "  }", "  cleanup();", "  return 0;" };
    const b = [_][]const u8{ "let x = compute(a, b);", "if (x > 0) {", "log(x);", "return x;", "}", "cleanup();", "return 0;" };
    const fa = clones.fingerprint(&a, 0, a.len - 1) orelse return error.NoFingerprint;
    const fb = clones.fingerprint(&b, 0, b.len - 1) orelse return error.NoFingerprint;
    try testing.expectEqual(fa.hash, fb.hash);
    const tiny = [_][]const u8{ "return 1;", "return 2;" };
    try testing.expect(clones.fingerprint(&tiny, 0, tiny.len - 1) == null);
}
test "parser: solidity contracts, functions, events, state vars" {
    const src =
        \\contract Token is IERC20 {
        \\    uint256 public totalSupply;
        \\    event Transfer(address indexed from, address indexed to, uint256 value);
        \\    modifier onlyOwner() { _; }
        \\    function transfer(address to, uint256 amount) public returns (bool) { return true; }
        \\}
        \\library Math { function add(uint a, uint b) internal pure returns (uint) { return a+b; } }
        \\
    ;
    try expect_symbol(.solidity, src, "Token");
    try expect_symbol(.solidity, src, "totalSupply");
    try expect_symbol(.solidity, src, "Transfer");
    try expect_symbol(.solidity, src, "onlyOwner");
    try expect_symbol(.solidity, src, "transfer");
    try expect_symbol(.solidity, src, "Math");
}

test "axis B: solidity import resolution" {
    try expect_resolves(.solidity, "/ws/src/Token.sol", &.{"./IERC20.sol"}, "/ws/src/IERC20.sol");
    try expect_resolves(.solidity, "/ws/src/a/X.sol", &.{"../lib/Y.sol"}, "/ws/src/lib/Y.sol");
    try testing.expect(try extracted(.solidity, "import {FHE, euint256} from \"./Lib.sol\";\n", "./Lib.sol"));
    try testing.expect(try extracted(.solidity, "import \"./IERC20.sol\";\n", "./IERC20.sol"));
}

test "parser: protobuf messages, enums, services, rpcs" {
    const src =
        \\message User { string name = 1; uint64 id = 2; }
        \\enum Status { ACTIVE = 0; INACTIVE = 1; }
        \\service UserService { rpc GetUser(GetUserRequest) returns (User); }
        \\
    ;
    try expect_symbol(.protobuf, src, "User");
    try expect_symbol(.protobuf, src, "Status");
    try expect_symbol(.protobuf, src, "UserService");
    try expect_symbol(.protobuf, src, "GetUser");
}

test "axis B: protobuf import resolution" {
    try expect_resolves(.protobuf, "/ws/proto/svc.proto", &.{"common/types.proto"}, "/ws/proto/common/types.proto");
    try testing.expect(try extracted(.protobuf, "import \"common/types.proto\";\n", "common/types.proto"));
}

test "security: env-style secret detection (catches .env leaks)" {
    // Real secret assignments fire; placeholders and refs don't.
    try testing.expect(security_scan.env_secret("PRIVATE_KEY=0xabc123def456abc123def456abc123def456abc123def456") != null);
    try testing.expect(security_scan.env_secret("STRIPE_SECRET=sk_live_abcd1234efgh5678") != null);
    try testing.expect(security_scan.env_secret("API_KEY: aReal0ApiKey0Value") != null);
    try testing.expect(security_scan.env_secret("DB_PASSWORD=${VAULT_PW}") == null); // env ref
    try testing.expect(security_scan.env_secret("API_KEY=your_api_key_here") == null); // placeholder
    try testing.expect(security_scan.env_secret("PORT=8080") == null); // not a secret name
    try testing.expect(security_scan.env_secret("let token = getToken();") == null); // function call
}

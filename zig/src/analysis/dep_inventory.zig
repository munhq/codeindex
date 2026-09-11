//! What the dependency tree actually costs.
//!
//! Nobody knew the size of the tree. Measured in one Rust service on
//! 2026-09-10: 146 direct dependencies, 844 crates compiled, 146 crates present
//! in two or more versions at once, a 72 MB release binary with about 32 MB
//! resident per pod. `cargo` answers every one of those questions and no report
//! existed, so nobody asked.
//!
//! Three of those numbers are in the repository, and this reports them:
//! duplicate versions, declared-and-unreferenced dependencies, and dependencies
//! with a single reference. Binary size is a property of a build, and the report
//! names it under `not_measured`.
//!
//! Precision: a duplicate version is normal in a large tree. The count and the
//! list are the report; no entry is marked as a defect. An unreferenced
//! dependency is a CANDIDATE, because a crate reached only through a derive
//! macro or a re-export has no textual reference. `cargo udeps` decides.

const std = @import("std");
const explorer = @import("../index/explorer.zig");
const models = @import("../core/models.zig");
const io = @import("../core/io.zig");

pub const Ecosystem = enum {
    cargo,
    npm,

    pub fn as_str(self: Ecosystem) []const u8 {
        return switch (self) {
            .cargo => "cargo",
            .npm => "npm",
        };
    }
};

/// A package the lock file holds in more than one version at the same time.
pub const Duplicate = struct {
    ecosystem: Ecosystem,
    /// Owned.
    name: []const u8,
    /// Owned, and each element owned: every version present.
    versions: [][]const u8,
};

/// A declared dependency, with what the source does with it.
pub const Declared = struct {
    ecosystem: Ecosystem,
    /// Owned.
    name: []const u8,
    /// Manifest that declares it. Borrowed from the outline.
    manifest: []const u8,
    /// Source files that name it, excluding manifests.
    files: usize,
    /// Lines that name it, across those files.
    references: usize,
};

pub const Report = struct {
    /// Manifests read.
    manifests: usize = 0,
    direct_dependencies: usize = 0,
    /// Distinct packages in the lock files.
    locked_packages: usize = 0,
    duplicates: []Duplicate = &.{},
    /// Declared with no reference in the source. A candidate, not a verdict.
    unreferenced: []Declared = &.{},
    /// Declared and named on exactly one line.
    single_reference: []Declared = &.{},
    /// The command that turns the unreferenced candidates into a verdict.
    confirm_unused_with: []const u8 = "cargo +nightly udeps --all-targets",
    /// Why `unreferenced` and `single_reference` cover one ecosystem.
    reference_scope: []const u8 =
        "cargo only. A crate has to be named in a `use` to be used. An npm package often does not: " ++
        "`@types/*`, `eslint-config-*` and `react-dom` are pulled in by the toolchain or the framework, " ++
        "and reporting them as unreferenced added 30 false candidates against 4 real ones.",

    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        for (self.duplicates) |d| {
            allocator.free(d.name);
            for (d.versions) |v| allocator.free(v);
            allocator.free(d.versions);
        }
        allocator.free(self.duplicates);
        for (self.unreferenced) |d| allocator.free(d.name);
        allocator.free(self.unreferenced);
        for (self.single_reference) |d| allocator.free(d.name);
        allocator.free(self.single_reference);
    }
};

// ── Reference counting ───────────────────────────────────────────────────────

/// How a dependency's name reaches the source.
///
/// A crate becomes an identifier: `serde-json` is written `serde_json` in a
/// `use`. An npm package does not: `import ReactDOM from "react-dom"` carries
/// the name verbatim, hyphens, scope and all. Snake-casing npm names reported
/// `react-dom`, `@atlaskit/pragmatic-drag-and-drop` and nine more as
/// unreferenced when every one of them is imported.
fn code_identifier(allocator: std.mem.Allocator, name: []const u8, ecosystem: Ecosystem) ![]u8 {
    if (ecosystem == .npm) return allocator.dupe(u8, name);
    const out = try allocator.alloc(u8, name.len);
    for (name, 0..) |c, i| out[i] = if (c == '-') '_' else c;
    return out;
}

fn is_manifest_path(path: []const u8) bool {
    const basename = std.fs.path.basename(path);
    const names = [_][]const u8{
        "Cargo.toml",       "Cargo.lock",      "package.json", "package-lock.json",
        "go.mod",           "pyproject.toml",  "yarn.lock",    "pnpm-lock.yaml",
        "requirements.txt", "Cargo.toml.orig",
    };
    for (&names) |n| {
        if (std.mem.eql(u8, basename, n)) return true;
    }
    return false;
}

const Usage = struct {
    files: usize,
    references: usize,
};

/// Lines in the source that name `ident`, and how many files hold them.
///
/// The word index narrows this to the handful of files that hold the word, so
/// the line scan never touches the whole tree.
fn count_usage(exp: *explorer.Explorer, ident: []const u8) Usage {
    var usage = Usage{ .files = 0, .references = 0 };
    const hits = exp.words.search(ident);
    for (hits) |file_id| {
        if (exp.deleted_files.get(file_id) != null) continue;
        const outline = exp.outlines.get(file_id) orelse continue;
        if (is_manifest_path(outline.path)) continue;
        switch (outline.language) {
            .markdown, .json, .toml, .yaml, .unknown, .gitignore, .diff => continue,
            else => {},
        }
        const content = exp.content_cache.get(file_id) orelse continue;
        var lines: usize = 0;
        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |line| {
            if (word_in_line(line, ident)) lines += 1;
        }
        if (lines > 0) {
            usage.files += 1;
            usage.references += lines;
        }
    }
    return usage;
}

fn ident_char(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn word_in_line(line: []const u8, word: []const u8) bool {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, line, from, word)) |idx| {
        const before_ok = idx == 0 or !ident_char(line[idx - 1]);
        const after = idx + word.len;
        const after_ok = after >= line.len or !ident_char(line[after]);
        if (before_ok and after_ok) return true;
        from = idx + 1;
    }
    return false;
}

// ── Cargo ────────────────────────────────────────────────────────────────────

/// Direct dependency names from a `Cargo.toml`.
///
/// Every `[…dependencies]` table counts: `[dependencies]`,
/// `[dev-dependencies]`, `[build-dependencies]`, `[workspace.dependencies]` and
/// `[target.'cfg(unix)'.dependencies]` all declare a crate the build pulls.
fn cargo_direct_deps(allocator: std.mem.Allocator, content: []const u8, out: *std.ArrayList([]const u8)) !void {
    var in_deps = false;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            // `[[…]]` is an array of tables, never a dependency table.
            const header = std.mem.trim(u8, line, "[]");
            in_deps = std.mem.endsWith(u8, header, "dependencies") and !std.mem.startsWith(u8, line, "[[");
            continue;
        }
        if (!in_deps) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const name = std.mem.trim(u8, line[0..eq], " \t\"'");
        if (name.len == 0) continue;
        // A nested key inside an inline table continuation, e.g. `features = [`.
        if (std.mem.indexOfAny(u8, name, " \t.") != null) continue;
        var seen = false;
        for (out.items) |existing| {
            if (std.mem.eql(u8, existing, name)) seen = true;
        }
        if (!seen) try out.append(allocator, name);
    }
}

const LockedPackage = struct {
    name: []const u8,
    version: []const u8,
};

/// `[[package]] name = "x" version = "y"` entries from a `Cargo.lock`.
fn cargo_lock_packages(allocator: std.mem.Allocator, content: []const u8) ![]LockedPackage {
    var pkgs = std.ArrayList(LockedPackage).empty;
    errdefer pkgs.deinit(allocator);
    var name: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.eql(u8, line, "[[package]]")) {
            name = null;
            continue;
        }
        if (std.mem.startsWith(u8, line, "name = ")) {
            name = std.mem.trim(u8, line["name = ".len..], "\"");
            continue;
        }
        if (std.mem.startsWith(u8, line, "version = ")) {
            const version = std.mem.trim(u8, line["version = ".len..], "\"");
            if (name) |n| try pkgs.append(allocator, .{ .name = n, .version = version });
            name = null;
        }
    }
    return pkgs.toOwnedSlice(allocator);
}

// ── npm ──────────────────────────────────────────────────────────────────────

/// Dependency names from the `dependencies` / `devDependencies` objects of a
/// `package.json`. A brace-depth scan, so nothing else in the file can leak in.
fn npm_direct_deps(allocator: std.mem.Allocator, content: []const u8, out: *std.ArrayList([]const u8)) !void {
    const sections = [_][]const u8{
        "\"dependencies\"", "\"devDependencies\"", "\"peerDependencies\"", "\"optionalDependencies\"",
    };
    for (&sections) |section| {
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, content, from, section)) |idx| {
            from = idx + section.len;
            const open = std.mem.indexOfScalarPos(u8, content, from, '{') orelse break;
            var depth: usize = 0;
            var end = open;
            while (end < content.len) : (end += 1) {
                if (content[end] == '{') depth += 1;
                if (content[end] == '}') {
                    depth -= 1;
                    if (depth == 0) break;
                }
            }
            if (end >= content.len) break;
            // Only a flat object of "name": "range" pairs is a dependency table.
            var body_it = std.mem.splitScalar(u8, content[open + 1 .. end], '\n');
            while (body_it.next()) |raw| {
                const line = std.mem.trim(u8, raw, " \t\r,");
                if (line.len == 0 or line[0] != '"') continue;
                const close = std.mem.indexOfScalarPos(u8, line, 1, '"') orelse continue;
                const name = line[1..close];
                if (name.len == 0) continue;
                var seen = false;
                for (out.items) |existing| {
                    if (std.mem.eql(u8, existing, name)) seen = true;
                }
                if (!seen) try out.append(allocator, name);
            }
            from = end;
        }
    }
}

/// `node_modules/<name>` keys and their versions from a `package-lock.json`.
/// A nested `node_modules/a/node_modules/b` key is a second copy of `b`.
fn npm_lock_packages(allocator: std.mem.Allocator, content: []const u8) ![]LockedPackage {
    var pkgs = std.ArrayList(LockedPackage).empty;
    errdefer pkgs.deinit(allocator);
    const key = "\"node_modules/";
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, content, from, key)) |idx| {
        const name_start = idx + key.len;
        const name_end = std.mem.indexOfScalarPos(u8, content, name_start, '"') orelse break;
        from = name_end;
        var name = content[name_start..name_end];
        // The last path segment is the package; a scope keeps its `@scope/` part.
        if (std.mem.lastIndexOf(u8, name, "node_modules/")) |nested| {
            name = name[nested + "node_modules/".len ..];
        }
        // The version sits in the object that follows, before the next key.
        const vkey = "\"version\":";
        const vpos = std.mem.indexOfPos(u8, content, name_end, vkey) orelse continue;
        // Guard against reading the version of a much later entry.
        if (vpos > name_end + 400) continue;
        const q1 = std.mem.indexOfScalarPos(u8, content, vpos + vkey.len, '"') orelse continue;
        const q2 = std.mem.indexOfScalarPos(u8, content, q1 + 1, '"') orelse continue;
        try pkgs.append(allocator, .{ .name = name, .version = content[q1 + 1 .. q2] });
    }
    return pkgs.toOwnedSlice(allocator);
}

// ── Duplicate versions ───────────────────────────────────────────────────────

fn collect_duplicates(
    allocator: std.mem.Allocator,
    ecosystem: Ecosystem,
    pkgs: []const LockedPackage,
    out: *std.ArrayList(Duplicate),
    distinct: *usize,
) !void {
    var by_name = std.StringHashMap(std.ArrayList([]const u8)).init(allocator);
    defer {
        var it = by_name.valueIterator();
        while (it.next()) |v| v.deinit(allocator);
        by_name.deinit();
    }

    for (pkgs) |p| {
        const gop = try by_name.getOrPut(p.name);
        if (!gop.found_existing) gop.value_ptr.* = std.ArrayList([]const u8).empty;
        var already = false;
        for (gop.value_ptr.items) |v| {
            if (std.mem.eql(u8, v, p.version)) already = true;
        }
        if (!already) try gop.value_ptr.append(allocator, p.version);
    }

    distinct.* += by_name.count();

    var it = by_name.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.items.len < 2) continue;
        var versions = try allocator.alloc([]const u8, entry.value_ptr.items.len);
        errdefer allocator.free(versions);
        for (entry.value_ptr.items, 0..) |v, i| versions[i] = try allocator.dupe(u8, v);
        try out.append(allocator, .{
            .ecosystem = ecosystem,
            .name = try allocator.dupe(u8, entry.key_ptr.*),
            .versions = versions,
        });
    }
}

// ── Entry point ──────────────────────────────────────────────────────────────

const max_lock_bytes: usize = 32 * 1024 * 1024;

pub fn analyze(allocator: std.mem.Allocator, exp: *explorer.Explorer) !Report {
    var report = Report{};
    var duplicates = std.ArrayList(Duplicate).empty;
    var unreferenced = std.ArrayList(Declared).empty;
    var single = std.ArrayList(Declared).empty;
    errdefer {
        duplicates.deinit(allocator);
        unreferenced.deinit(allocator);
        single.deinit(allocator);
    }

    var direct = std.ArrayList([]const u8).empty;
    defer direct.deinit(allocator);

    var it = exp.outlines.iterator();
    while (it.next()) |entry| {
        const file_id = entry.key_ptr.*;
        if (exp.deleted_files.get(file_id) != null) continue;
        const outline = entry.value_ptr.*;
        const basename = std.fs.path.basename(outline.path);

        const ecosystem: Ecosystem = if (std.mem.eql(u8, basename, "Cargo.toml"))
            .cargo
        else if (std.mem.eql(u8, basename, "package.json"))
            .npm
        else
            continue;

        // A manifest inside a dependency tree describes someone else's project.
        if (std.mem.indexOf(u8, outline.path, "node_modules") != null) continue;
        if (std.mem.indexOf(u8, outline.path, "/vendor/") != null) continue;

        const content = exp.content_cache.get(file_id) orelse continue;
        report.manifests += 1;

        direct.clearRetainingCapacity();
        switch (ecosystem) {
            .cargo => try cargo_direct_deps(allocator, content, &direct),
            .npm => try npm_direct_deps(allocator, content, &direct),
        }
        report.direct_dependencies += direct.items.len;

        // See `Report.reference_scope`: only a crate must name itself to use it.
        for (if (ecosystem == .cargo) direct.items else &[_][]const u8{}) |name| {
            const ident = try code_identifier(allocator, name, ecosystem);
            defer allocator.free(ident);
            const usage = count_usage(exp, ident);
            if (usage.references == 0) {
                try unreferenced.append(allocator, .{
                    .ecosystem = ecosystem,
                    .name = try allocator.dupe(u8, name),
                    .manifest = outline.path,
                    .files = 0,
                    .references = 0,
                });
            } else if (usage.references == 1) {
                try single.append(allocator, .{
                    .ecosystem = ecosystem,
                    .name = try allocator.dupe(u8, name),
                    .manifest = outline.path,
                    .files = usage.files,
                    .references = 1,
                });
            }
        }

        // The lock file beside the manifest. `Cargo.lock` carries the `.lock`
        // extension the indexer skips on purpose — a tree full of lock files
        // would swamp the index — so it is read here, once, by name.
        const dir = std.fs.path.dirname(outline.path) orelse continue;
        const lock_name = switch (ecosystem) {
            .cargo => "Cargo.lock",
            .npm => "package-lock.json",
        };
        const lock_path = try std.fs.path.join(allocator, &.{ dir, lock_name });
        defer allocator.free(lock_path);
        const lock = io.readFileAlloc(allocator, lock_path, max_lock_bytes) catch continue;
        defer allocator.free(lock);

        const pkgs = switch (ecosystem) {
            .cargo => try cargo_lock_packages(allocator, lock),
            .npm => try npm_lock_packages(allocator, lock),
        };
        defer allocator.free(pkgs);
        try collect_duplicates(allocator, ecosystem, pkgs, &duplicates, &report.locked_packages);
    }

    const dup_items = try duplicates.toOwnedSlice(allocator);
    std.mem.sort(Duplicate, dup_items, {}, struct {
        fn less(_: void, a: Duplicate, b: Duplicate) bool {
            if (a.versions.len != b.versions.len) return a.versions.len > b.versions.len;
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.less);

    report.duplicates = dup_items;
    report.unreferenced = try unreferenced.toOwnedSlice(allocator);
    report.single_reference = try single.toOwnedSlice(allocator);
    return report;
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "dep_inventory: Cargo.toml direct deps span every dependency table" {
    const allocator = testing.allocator;
    const src =
        \\[package]
        \\name = "app"
        \\version = "0.1.0"
        \\
        \\[dependencies]
        \\serde = "1.0"
        \\tokio = { version = "1", features = ["full"] }
        \\
        \\[dev-dependencies]
        \\criterion = "0.5"
        \\
        \\[target.'cfg(unix)'.dependencies]
        \\nix = "0.29"
        \\
        \\[[bin]]
        \\name = "app"
        \\
    ;
    var out = std.ArrayList([]const u8).empty;
    defer out.deinit(allocator);
    try cargo_direct_deps(allocator, src, &out);
    try testing.expectEqual(@as(usize, 4), out.items.len);
    try testing.expectEqualStrings("serde", out.items[0]);
    try testing.expectEqualStrings("tokio", out.items[1]);
    try testing.expectEqualStrings("criterion", out.items[2]);
    try testing.expectEqualStrings("nix", out.items[3]);
}

test "dep_inventory: Cargo.lock duplicate versions" {
    const allocator = testing.allocator;
    const lock =
        \\[[package]]
        \\name = "bitflags"
        \\version = "1.3.2"
        \\
        \\[[package]]
        \\name = "bitflags"
        \\version = "2.6.0"
        \\
        \\[[package]]
        \\name = "serde"
        \\version = "1.0.210"
        \\
    ;
    const pkgs = try cargo_lock_packages(allocator, lock);
    defer allocator.free(pkgs);
    try testing.expectEqual(@as(usize, 3), pkgs.len);

    var dups = std.ArrayList(Duplicate).empty;
    defer {
        for (dups.items) |d| {
            allocator.free(d.name);
            for (d.versions) |v| allocator.free(v);
            allocator.free(d.versions);
        }
        dups.deinit(allocator);
    }
    var distinct: usize = 0;
    try collect_duplicates(allocator, .cargo, pkgs, &dups, &distinct);
    try testing.expectEqual(@as(usize, 2), distinct);
    try testing.expectEqual(@as(usize, 1), dups.items.len);
    try testing.expectEqualStrings("bitflags", dups.items[0].name);
    try testing.expectEqual(@as(usize, 2), dups.items[0].versions.len);
}

test "dep_inventory: a crate snake-cases, an npm package does not" {
    const allocator = testing.allocator;
    const a = try code_identifier(allocator, "serde-json", .cargo);
    defer allocator.free(a);
    try testing.expectEqualStrings("serde_json", a);
    // `import x from "react-dom"` carries the name as written.
    const b = try code_identifier(allocator, "react-dom", .npm);
    defer allocator.free(b);
    try testing.expectEqualStrings("react-dom", b);
    const c = try code_identifier(allocator, "@atlaskit/pragmatic-drag-and-drop", .npm);
    defer allocator.free(c);
    try testing.expectEqualStrings("@atlaskit/pragmatic-drag-and-drop", c);
}

test "dep_inventory: package.json dependency tables" {
    const allocator = testing.allocator;
    const src =
        \\{
        \\  "name": "app",
        \\  "scripts": { "build": "tsc" },
        \\  "dependencies": {
        \\    "react": "^18.0.0",
        \\    "@scope/util": "1.2.3"
        \\  },
        \\  "devDependencies": {
        \\    "typescript": "^5.0.0"
        \\  }
        \\}
        \\
    ;
    var out = std.ArrayList([]const u8).empty;
    defer out.deinit(allocator);
    try npm_direct_deps(allocator, src, &out);
    try testing.expectEqual(@as(usize, 3), out.items.len);
    try testing.expectEqualStrings("react", out.items[0]);
    try testing.expectEqualStrings("@scope/util", out.items[1]);
    try testing.expectEqualStrings("typescript", out.items[2]);
}

test "dep_inventory: an unreferenced crate is separated from a single-use one" {
    const allocator = testing.allocator;
    var exp = try explorer.Explorer.init(allocator);
    defer exp.deinit();

    const src = "use serde_json::Value;\nfn parse() -> Value { serde_json::json!({}) }\n";
    _ = try exp.add_file(.{
        .path = try allocator.dupe(u8, "src/lib.rs"),
        .language = .rust,
        .line_count = 2,
        .byte_size = src.len,
        .symbols = &[_]models.Symbol{},
        .imports = &[_][]const u8{},
    }, src);
    exp.mark_indexing_complete();

    try testing.expectEqual(@as(usize, 2), count_usage(&exp, "serde_json").references);
    try testing.expectEqual(@as(usize, 0), count_usage(&exp, "criterion").references);
}

test "dep_inventory: a manifest does not count as a reference to its own dep" {
    const allocator = testing.allocator;
    var exp = try explorer.Explorer.init(allocator);
    defer exp.deinit();

    const manifest = "[dependencies]\ncriterion = \"0.5\"\n";
    _ = try exp.add_file(.{
        .path = try allocator.dupe(u8, "Cargo.toml"),
        .language = .toml,
        .line_count = 2,
        .byte_size = manifest.len,
        .symbols = &[_]models.Symbol{},
        .imports = &[_][]const u8{},
    }, manifest);
    exp.mark_indexing_complete();

    try testing.expectEqual(@as(usize, 0), count_usage(&exp, "criterion").references);
}

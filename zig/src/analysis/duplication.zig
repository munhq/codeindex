//! Duplication & reuse analysis.
//!
//! Surfaces the same *definition name* declared in multiple files — the signal
//! for copy-paste, reinvented utilities (a `new_logger`/`retry`/`parse_config`
//! redefined in ten places instead of imported from one module), and "we wrote
//! this by hand instead of reusing what exists." Heuristic, not exact-clone
//! detection: it answers "are we reusing code or rewriting it?" cheaply.

const std = @import("std");
const explorer = @import("../index/explorer.zig");
const models = @import("../core/models.zig");

pub const DupCluster = struct {
    name: []const u8, // borrowed from the symbol outline
    kind: models.SymbolKind,
    files: [][]const u8, // owned slice of borrowed path refs (distinct files)
};

pub const Report = struct {
    clusters: []DupCluster, // sorted by file count desc
    total_clusters: usize,

    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        for (self.clusters) |c| allocator.free(c.files);
        allocator.free(self.clusters);
    }
};

/// Only named, reuse-worthy definitions. Methods are deliberately excluded:
/// the same method name across many files is almost always interface/trait
/// conformance (`Close`, `execute`), not reinvention. Free functions and types
/// repeating across files is the real "we rewrote this" signal.
fn relevant_kind(kind: models.SymbolKind) bool {
    return switch (kind) {
        .function, .class, .@"struct", .@"enum", .trait, .type_alias, .@"union" => true,
        else => false,
    };
}

/// Names too generic to mean duplication (overrides, conventional methods).
const generic = [_][]const u8{
    "new",      "default", "init",     "deinit",    "drop",        "clone", "main",
    "build",    "from",    "into",     "with",      "next",        "value", "name",
    "run",      "start",   "stop",     "close",     "open",        "get",   "set",
    "handle",   "process", "create",   "update",    "delete",      "list",  "format",
    "toString", "equals",  "hashCode", "serialize", "deserialize",
};

fn is_generic(name: []const u8) bool {
    if (name.len <= 3) return true;
    for (generic) |g| {
        if (std.mem.eql(u8, name, g)) return true;
    }
    return false;
}

/// Reinvention only makes sense for real code. Markup/data/config formats
/// (HTML tags, CSS selectors, JSON/YAML keys) repeat by nature, not by copy-paste.
fn is_code(lang: models.Language) bool {
    return switch (lang) {
        .html, .css, .scss, .json, .yaml, .toml, .ini, .markdown, .sql, .dockerfile, .make, .xml, .jinja2, .gitignore, .diff, .hcl => false,
        else => true,
    };
}

pub fn analyze(allocator: std.mem.Allocator, exp: *explorer.Explorer) !Report {
    const Entry = struct { kind: models.SymbolKind, files: std.ArrayList([]const u8) };
    var map = std.StringHashMap(Entry).init(allocator);
    defer {
        var dit = map.iterator();
        while (dit.next()) |e| e.value_ptr.files.deinit(allocator);
        map.deinit();
    }

    var oit = exp.outlines.iterator();
    while (oit.next()) |entry| {
        const file_id = entry.key_ptr.*;
        if (exp.deleted_files.get(file_id) != null) continue;
        const outline = entry.value_ptr.*;
        if (!is_code(outline.language)) continue;
        for (outline.symbols) |sym| {
            if (!relevant_kind(sym.kind)) continue;
            if (is_generic(sym.name)) continue;

            const gop = try map.getOrPut(sym.name);
            if (!gop.found_existing) gop.value_ptr.* = .{ .kind = sym.kind, .files = std.ArrayList([]const u8).empty };
            // Count distinct files only (a name overloaded within one file isn't duplication).
            var present = false;
            for (gop.value_ptr.files.items) |f| {
                if (std.mem.eql(u8, f, outline.path)) {
                    present = true;
                    break;
                }
            }
            if (!present) try gop.value_ptr.files.append(allocator, outline.path);
        }
    }

    var clusters = std.ArrayList(DupCluster).empty;
    errdefer {
        for (clusters.items) |c| allocator.free(c.files);
        clusters.deinit(allocator);
    }
    var it = map.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.files.items.len >= 2) {
            try clusters.append(allocator, .{
                .name = e.key_ptr.*,
                .kind = e.value_ptr.kind,
                .files = try allocator.dupe([]const u8, e.value_ptr.files.items),
            });
        }
    }

    const C = struct {
        fn lessThan(_: void, a: DupCluster, b: DupCluster) bool {
            return a.files.len > b.files.len; // most-duplicated first
        }
    };
    std.mem.sort(DupCluster, clusters.items, {}, C.lessThan);

    const slice = try clusters.toOwnedSlice(allocator);
    return Report{ .clusters = slice, .total_clusters = slice.len };
}

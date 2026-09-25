//! Line-level helpers that more than one analysis needs.

const std = @import("std");
const models = @import("../core/models.zig");

/// Tests, benchmarks, examples, vendored and generated trees. A cost in them
/// is never paid in production.
pub fn is_excluded_path(path: []const u8) bool {
    const dirs = [_][]const u8{
        "test",         "tests",  "spec",   "benches",  "bench",    "examples", "example",
        "node_modules", "vendor", "target", "testdata", "fixtures", "docs",
    };
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |component| {
        for (&dirs) |d| {
            if (std.mem.eql(u8, component, d)) return true;
        }
    }
    const basename = std.fs.path.basename(path);
    if (std.mem.indexOf(u8, basename, "_test.") != null) return true;
    if (std.mem.indexOf(u8, basename, ".test.") != null) return true;
    if (std.mem.indexOf(u8, basename, ".spec.") != null) return true;
    if (std.mem.startsWith(u8, basename, "test_")) return true;
    return false;
}

pub fn ident_char(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

pub fn contains_any(hay: []const u8, needles: []const []const u8) bool {
    for (needles) |n| {
        if (std.mem.indexOf(u8, hay, n) != null) return true;
    }
    return false;
}

pub fn contains_any_ci(hay: []const u8, needles: []const []const u8) bool {
    for (needles) |n| {
        if (std.ascii.indexOfIgnoreCase(hay, n) != null) return true;
    }
    return false;
}

/// A trimmed line that is a comment in `lang`.
pub fn is_comment(t: []const u8, lang: models.Language) bool {
    if (std.mem.startsWith(u8, t, "//")) return true;
    if (std.mem.startsWith(u8, t, "/*")) return true;
    if (std.mem.startsWith(u8, t, "*")) return true;
    if ((lang == .python or lang == .yaml or lang == .bash or lang == .ruby) and std.mem.startsWith(u8, t, "#")) return true;
    return false;
}

/// The lines of `content`, 0-based. Caller frees the slice.
pub fn split_lines(allocator: std.mem.Allocator, content: []const u8) ![][]const u8 {
    var lines = std.ArrayList([]const u8).empty;
    errdefer lines.deinit(allocator);
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |l| try lines.append(allocator, l);
    return lines.toOwnedSlice(allocator);
}

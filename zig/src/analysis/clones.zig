//! Clone detection — finds functions/methods with near-identical *bodies*,
//! regardless of their names. This catches what name-based duplication can't:
//! copy-pasted code that was lightly renamed, and the same block pasted into
//! many files. Whitespace- and comment-insensitive (Type-1 clones): two bodies
//! that differ only in formatting or comments hash to the same fingerprint.

const std = @import("std");
const explorer = @import("../index/explorer.zig");
const models = @import("../core/models.zig");
const io = @import("../core/io.zig");

/// Functions shorter than this (after stripping blanks/comments) are ignored —
/// trivial getters/wrappers legitimately look alike.
const MIN_LINES: usize = 6;

pub const Member = struct {
    name: []const u8, // borrowed from the symbol outline
    file: []const u8, // borrowed from the outline path
    line: usize,
};

pub const CloneGroup = struct {
    lines: usize, // normalized body size (how much code is duplicated)
    members: []Member, // owned slice; >= 2 functions sharing this body
};

pub const Report = struct {
    groups: []CloneGroup, // sorted by (members * lines) desc — biggest waste first
    total_groups: usize,
    total_cloned_fns: usize,

    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        for (self.groups) |g| allocator.free(g.members);
        allocator.free(self.groups);
    }
};

fn is_comment(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "//") or std.mem.startsWith(u8, line, "#") or
        std.mem.startsWith(u8, line, "--") or std.mem.startsWith(u8, line, "/*") or
        std.mem.startsWith(u8, line, "*") or std.mem.startsWith(u8, line, ";;");
}

/// Hash a body's lines with whitespace collapsed and blank/comment lines
/// dropped. Returns null if fewer than MIN_LINES of real code remain. Callers
/// pass `start` one past the signature line so the fingerprint is name- and
/// parameter-independent (a renamed copy still matches).
pub fn fingerprint(lines: []const []const u8, start: usize, end: usize) ?struct { hash: u64, n: usize } {
    var h = std.hash.Wyhash.init(0);
    var n: usize = 0;
    var i = start;
    while (i <= end and i < lines.len) : (i += 1) {
        const t = std.mem.trim(u8, lines[i], " \t\r");
        if (t.len == 0 or is_comment(t)) continue;
        // Collapse internal whitespace runs to a single space so indentation
        // and spacing don't affect the fingerprint.
        var prev_space = true;
        for (t) |c| {
            if (c == ' ' or c == '\t') {
                if (!prev_space) {
                    h.update(" ");
                    prev_space = true;
                }
            } else {
                h.update(&[_]u8{c});
                prev_space = false;
            }
        }
        h.update("\n");
        n += 1;
    }
    if (n < MIN_LINES) return null;
    return .{ .hash = h.final(), .n = n };
}

pub fn analyze(allocator: std.mem.Allocator, exp: *explorer.Explorer) !Report {
    const Bucket = struct { lines: usize, members: std.ArrayList(Member) };
    var map = std.AutoHashMap(u64, Bucket).init(allocator);
    defer {
        var dit = map.iterator();
        while (dit.next()) |e| e.value_ptr.members.deinit(allocator);
        map.deinit();
    }

    var lines = std.ArrayList([]const u8).empty;
    defer lines.deinit(allocator);

    var it = exp.outlines.iterator();
    while (it.next()) |entry| {
        const file_id = entry.key_ptr.*;
        if (exp.deleted_files.get(file_id) != null) continue;
        const outline = entry.value_ptr.*;

        // Skip files with no function-like symbols big enough to matter.
        var has_candidate = false;
        for (outline.symbols) |s| {
            if ((s.kind == .function or s.kind == .method) and s.line_end > s.line_start + MIN_LINES) {
                has_candidate = true;
                break;
            }
        }
        if (!has_candidate) continue;

        const content = io.readFileAlloc(allocator, outline.path, 10 * 1024 * 1024) catch continue;
        defer allocator.free(content);

        lines.clearRetainingCapacity();
        var lit = std.mem.splitScalar(u8, content, '\n');
        while (lit.next()) |l| try lines.append(allocator, l);

        for (outline.symbols) |sym| {
            if (sym.kind != .function and sym.kind != .method) continue;
            if (sym.line_end <= sym.line_start) continue;
            // Skip the signature line → matches even when the copy was renamed.
            const fp = fingerprint(lines.items, sym.line_start + 1, sym.line_end) orelse continue;
            const gop = try map.getOrPut(fp.hash);
            if (!gop.found_existing) gop.value_ptr.* = .{ .lines = fp.n, .members = std.ArrayList(Member).empty };
            try gop.value_ptr.members.append(allocator, .{ .name = sym.name, .file = outline.path, .line = sym.line_start });
        }
    }

    var groups = std.ArrayList(CloneGroup).empty;
    errdefer {
        for (groups.items) |g| allocator.free(g.members);
        groups.deinit(allocator);
    }
    var total_cloned: usize = 0;
    var mit = map.iterator();
    while (mit.next()) |e| {
        if (e.value_ptr.members.items.len >= 2) {
            total_cloned += e.value_ptr.members.items.len;
            try groups.append(allocator, .{
                .lines = e.value_ptr.lines,
                .members = try allocator.dupe(Member, e.value_ptr.members.items),
            });
        }
    }

    const C = struct {
        fn lessThan(_: void, a: CloneGroup, b: CloneGroup) bool {
            return a.members.len * a.lines > b.members.len * b.lines; // biggest waste first
        }
    };
    std.mem.sort(CloneGroup, groups.items, {}, C.lessThan);

    const slice = try groups.toOwnedSlice(allocator);
    return Report{ .groups = slice, .total_groups = slice.len, .total_cloned_fns = total_cloned };
}

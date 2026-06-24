const std = @import("std");
const io = @import("io.zig");

pub const FileEdit = struct {
    path: []const u8,
    line_start: usize, // 1-indexed
    line_end: usize,   // 1-indexed
    new_content: []const u8,
};

pub const EditResult = struct {
    path: []const u8,
    old_hash: u64,
    new_hash: u64,
    lines_changed: usize,
    seq: u64,

    pub fn deinit(self: *EditResult, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

pub const EditEngine = struct {
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    seq: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator, workspace_root: []const u8) !EditEngine {
        return EditEngine{
            .allocator = allocator,
            .workspace_root = try allocator.dupe(u8, workspace_root),
            .seq = std.atomic.Value(u64).init(1),
        };
    }

    pub fn deinit(self: *EditEngine) void {
        self.allocator.free(self.workspace_root);
    }

    fn next_seq(self: *EditEngine) u64 {
        return self.seq.fetchAdd(1, .monotonic);
    }

    pub fn apply(self: *EditEngine, edit: FileEdit) !EditResult {
        const full_path = try std.fs.path.join(self.allocator, &.{ self.workspace_root, edit.path });
        defer self.allocator.free(full_path);

        const content = try io.readFileAlloc(self.allocator, full_path, 1024 * 1024 * 10);
        defer self.allocator.free(content);

        const new_content = try self.apply_line_edit(content, edit.line_start, edit.line_end, edit.new_content);
        defer self.allocator.free(new_content);

        const old_hash = std.hash.Wyhash.hash(0, content);
        const new_hash = std.hash.Wyhash.hash(0, new_content);

        // Atomic write: .tmp then rename
        try io.writeFileAtomic(self.allocator, full_path, new_content);

        const replaced = if (edit.line_end >= edit.line_start) edit.line_end - edit.line_start + 1 else 0;
        const inserted = std.mem.count(u8, edit.new_content, "\n") + 1;

        return EditResult{
            .path = try self.allocator.dupe(u8, edit.path),
            .old_hash = old_hash,
            .new_hash = new_hash,
            .lines_changed = @max(replaced, inserted),
            .seq = self.next_seq(),
        };
    }

    /// Preview an edit without writing to disk. Returns the new file content.
    pub fn preview(self: *EditEngine, edit: FileEdit) ![]u8 {
        const full_path = try std.fs.path.join(self.allocator, &.{ self.workspace_root, edit.path });
        defer self.allocator.free(full_path);

        const content = try io.readFileAlloc(self.allocator, full_path, 1024 * 1024 * 10);
        defer self.allocator.free(content);

        return try self.apply_line_edit(content, edit.line_start, edit.line_end, edit.new_content);
    }

    pub fn apply_batch(self: *EditEngine, edits: []const FileEdit) ![]EditResult {
        var results = std.ArrayList(EditResult).empty;
        for (edits) |edit| {
            try results.append(self.allocator, try self.apply(edit));
        }
        return try results.toOwnedSlice(self.allocator);
    }

    fn apply_line_edit(self: *EditEngine, content: []const u8, line_start: usize, line_end: usize, new_content: []const u8) ![]u8 {
        if (line_start == 0) return error.InvalidLineStart;
        
        var lines = std.ArrayList([]const u8).empty;
        defer lines.deinit(self.allocator);

        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |line| {
            try lines.append(self.allocator, line);
        }

        if (line_start > lines.items.len) return error.LineStartOutOfBounds;
        if (line_end > lines.items.len) return error.LineEndOutOfBounds;
        if (line_end < line_start - 1) return error.InvalidLineRange;

        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(self.allocator);

        // Lines before
        for (0..line_start - 1) |i| {
            try result.appendSlice(self.allocator, lines.items[i]);
            try result.append(self.allocator, '\n');
        }

        // New content
        try result.appendSlice(self.allocator, new_content);
        if (new_content.len > 0 and new_content[new_content.len - 1] != '\n') {
            try result.append(self.allocator, '\n');
        }

        // Lines after
        if (line_end < lines.items.len) {
            for (line_end..lines.items.len) |i| {
                try result.appendSlice(self.allocator, lines.items[i]);
                if (i < lines.items.len - 1 or content[content.len - 1] == '\n') {
                    try result.append(self.allocator, '\n');
                }
            }
        }

        return result.toOwnedSlice(self.allocator);
    }
};

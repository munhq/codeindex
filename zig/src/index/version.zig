const std = @import("std");
const models = @import("../core/models.zig");

const MAX_CHANGES: usize = 1000;

/// Ring buffer of ChangeRecords for tracking file mutations.
pub const VersionStore = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(models.ChangeRecord),
    seq: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator) VersionStore {
        return .{
            .allocator = allocator,
            .buffer = std.ArrayList(models.ChangeRecord){},
            .seq = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *VersionStore) void {
        for (self.buffer.items) |*r| {
            self.allocator.free(r.path);
        }
        self.buffer.deinit(self.allocator);
    }

    pub fn record(self: *VersionStore, path: []const u8, op: models.ChangeOp) !void {
        const new_seq = self.seq.fetchAdd(1, .monotonic) + 1;
        const path_dup = try self.allocator.dupe(u8, path);

        if (self.buffer.items.len >= MAX_CHANGES) {
            // Evict oldest
            self.allocator.free(self.buffer.items[0].path);
            _ = self.buffer.orderedRemove(0);
        }

        try self.buffer.append(self.allocator, .{
            .seq = new_seq,
            .path = path_dup,
            .op = op,
            .timestamp_ms = std.time.milliTimestamp(),
        });
    }

    pub fn latest_seq(self: *const VersionStore) u64 {
        return self.seq.load(.monotonic);
    }

    /// Returns changes since the given sequence number.
    /// Second return value is true if the buffer was truncated (consumer fell behind).
    pub fn changes_since(self: *const VersionStore, since: u64) struct { items: []const models.ChangeRecord, truncated: bool } {
        if (self.buffer.items.len == 0) {
            return .{ .items = &.{}, .truncated = false };
        }

        const oldest_seq = self.buffer.items[0].seq;
        const truncated = since > 0 and since < oldest_seq;

        // Find start index
        var start: usize = 0;
        for (self.buffer.items, 0..) |rec, i| {
            if (rec.seq > since) {
                start = i;
                break;
            }
            start = self.buffer.items.len; // nothing newer
        }

        return .{
            .items = self.buffer.items[start..],
            .truncated = truncated,
        };
    }

    /// Get the most recently changed files, newest first.
    pub fn hot_files(self: *const VersionStore, limit: usize) []const models.ChangeRecord {
        const items = self.buffer.items;
        if (items.len == 0) return &.{};
        const start = if (items.len > limit) items.len - limit else 0;
        return items[start..];
    }
};

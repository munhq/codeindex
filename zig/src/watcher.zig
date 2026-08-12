const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const io = @import("core/io.zig");

const DEBOUNCE_MS: i64 = 200;

/// Linux syscalls return errors as the top 4 KiB of the unsigned range
/// (i.e. -4095..-1 reinterpreted). 0.16 dropped the std.posix inotify wrappers,
/// so we call the raw linux syscalls and check the return this way.
fn syscall_ok(rc: usize) bool {
    return rc <= std.math.maxInt(usize) - 4096;
}

pub const Watcher = struct {
    allocator: std.mem.Allocator,
    fd: i32,
    wd_map: std.AutoHashMap(i32, []const u8),
    last_event: std.StringHashMap(i64), // path -> timestamp for debouncing

    pub fn init(allocator: std.mem.Allocator) !Watcher {
        const rc = linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
        if (!syscall_ok(rc)) return error.INotifyInitFailed;
        const fd: i32 = @intCast(rc);

        return Watcher{
            .allocator = allocator,
            .fd = fd,
            .wd_map = std.AutoHashMap(i32, []const u8).init(allocator),
            .last_event = std.StringHashMap(i64).init(allocator),
        };
    }

    pub fn deinit(self: *Watcher) void {
        var le_it = self.last_event.iterator();
        while (le_it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.last_event.deinit();
        var it = self.wd_map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.wd_map.deinit();
        _ = linux.close(self.fd);
    }

    pub fn add_recursive(self: *Watcher, root_path: []const u8) !void {
        var dir = io.cwd().openDir(io.io(), root_path, .{ .iterate = true }) catch return;
        defer dir.close(io.io());

        const mask = linux.IN.MODIFY | linux.IN.CREATE | linux.IN.DELETE | linux.IN.MOVED_FROM | linux.IN.MOVED_TO;

        // Add watch for the directory itself (inotify needs a null-terminated path)
        const root_z = try self.allocator.dupeZ(u8, root_path);
        defer self.allocator.free(root_z);
        const wd_rc = linux.inotify_add_watch(self.fd, root_z, mask);
        if (!syscall_ok(wd_rc)) return error.INotifyAddWatchFailed;
        try self.wd_map.put(@intCast(wd_rc), try self.allocator.dupe(u8, root_path));

        var walker = try dir.walk(self.allocator);
        defer walker.deinit();

        while (try walker.next(io.io())) |entry| {
            if (entry.kind == .directory) {
                const full_path = try std.fs.path.join(self.allocator, &.{ root_path, entry.path });
                const fp_z = self.allocator.dupeZ(u8, full_path) catch {
                    self.allocator.free(full_path);
                    continue;
                };
                defer self.allocator.free(fp_z);
                const sub_rc = linux.inotify_add_watch(self.fd, fp_z, mask);
                if (!syscall_ok(sub_rc)) {
                    self.allocator.free(full_path);
                    continue;
                }
                try self.wd_map.put(@intCast(sub_rc), full_path);
            }
        }
    }

    pub const Event = struct {
        path: []const u8,
        op: enum { create, modify, delete },
    };

    pub fn poll_events(self: *Watcher, context: anytype, callback: anytype) !void {
        var buf: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;
        const n = posix.read(self.fd, &buf) catch |err| {
            if (err == error.WouldBlock) return;
            return err;
        };

        if (n == 0) return;

        var i: usize = 0;
        while (i < n) {
            const event = @as(*const linux.inotify_event, @ptrCast(@alignCast(&buf[i])));
            const name_ptr = @as([*:0]const u8, @ptrCast(&buf[i + @sizeOf(linux.inotify_event)]));
            const name = std.mem.span(name_ptr);

            if (self.wd_map.get(event.wd)) |dir_path| {
                const full_path = try std.fs.path.join(self.allocator, &.{ dir_path, name });
                defer self.allocator.free(full_path);

                // Debounce: skip if we got an event for this path recently
                const now = io.milliTimestamp();
                if (self.last_event.getEntry(full_path)) |entry| {
                    if (now - entry.value_ptr.* < DEBOUNCE_MS) continue;
                    entry.value_ptr.* = now;
                } else {
                    // HashMap stores the slice header by value but the bytes must outlive the entry,
                    // so dupe the key into allocator-owned memory.
                    const owned_key = self.allocator.dupe(u8, full_path) catch full_path;
                    self.last_event.put(owned_key, now) catch self.allocator.free(owned_key);
                }

                if (event.mask & (linux.IN.CREATE | linux.IN.MOVED_TO) != 0) {
                    try callback(context, Event{ .path = full_path, .op = .create });
                } else if (event.mask & linux.IN.MODIFY != 0) {
                    try callback(context, Event{ .path = full_path, .op = .modify });
                } else if (event.mask & (linux.IN.DELETE | linux.IN.MOVED_FROM) != 0) {
                    try callback(context, Event{ .path = full_path, .op = .delete });
                }
            }

            i += @sizeOf(linux.inotify_event) + event.len;
        }
    }
};

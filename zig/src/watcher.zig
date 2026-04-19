const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

const DEBOUNCE_MS: i64 = 200;

pub const Watcher = struct {
    allocator: std.mem.Allocator,
    fd: i32,
    wd_map: std.AutoHashMap(i32, []const u8),
    last_event: std.StringHashMap(i64), // path -> timestamp for debouncing

    pub fn init(allocator: std.mem.Allocator) !Watcher {
        const fd = try posix.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);

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
        posix.close(self.fd);
    }

    pub fn add_recursive(self: *Watcher, root_path: []const u8) !void {
        var dir = std.fs.cwd().openDir(root_path, .{ .iterate = true }) catch return;
        defer dir.close();

        // Add watch for the directory itself
        const wd = try posix.inotify_add_watch(self.fd, root_path, linux.IN.MODIFY | linux.IN.CREATE | linux.IN.DELETE | linux.IN.MOVED_FROM | linux.IN.MOVED_TO);
        try self.wd_map.put(wd, try self.allocator.dupe(u8, root_path));

        var walker = try dir.walk(self.allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind == .directory) {
                const full_path = try std.fs.path.join(self.allocator, &.{ root_path, entry.path });
                const sub_wd = posix.inotify_add_watch(self.fd, full_path, linux.IN.MODIFY | linux.IN.CREATE | linux.IN.DELETE | linux.IN.MOVED_FROM | linux.IN.MOVED_TO) catch {
                    self.allocator.free(full_path);
                    continue;
                };
                try self.wd_map.put(sub_wd, full_path);
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
                const now = std.time.milliTimestamp();
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

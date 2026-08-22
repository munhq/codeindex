const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const linux = std.os.linux;
const io = @import("core/io.zig");
const filter_mod = @import("core/filter.zig");

const DEBOUNCE_MS: i64 = 200;

/// How the live index learns a file changed, chosen at compile time.
///
/// This module was inotify and nothing else, with no guard on the OS. It still
/// compiled for macOS — `std.os.linux` is just a namespace of syscall wrappers —
/// and the published Mach-O binary carried inotify strings it could never use.
/// `main.zig` does `Watcher.init(...) catch return`, so at best the watcher was
/// silently absent on every Mac and the README advertised a live watcher anyway.
///
/// Polling is the portable answer rather than a second and third native backend
/// (kqueue, ReadDirectoryChangesW) that no test here could reach. It reuses the
/// stamp comparison the snapshot reconcile pass already relies on: walk the
/// tree, compare mtime and size against the last walk, and report the
/// difference. Slower to notice a change than inotify, and correct everywhere.
pub var poll_interval_ms: i64 = 2000;

pub const Watcher = if (builtin.os.tag == .linux) INotify else Polling;

/// Which implementation is live, so `status` can say so instead of implying
/// every platform watches the same way.
pub const backend = if (builtin.os.tag == .linux) "inotify" else "polling";

pub const Event = struct {
    path: []const u8,
    op: enum { create, modify, delete },
};

/// Interval between tree walks for the polling backend. Long enough that a walk
/// is a rounding error against an editor save, short enough that an agent asking
/// a question right after an edit sees the new code. Mutable so the test can
/// drive several walks without waiting real seconds for each.
/// Walk the tree and report what changed since the previous walk.
///
/// Public so the test suite can exercise it on every platform, not only the
/// ones where it is the compiled default. A backend that only ran on macOS and
/// Windows could only be tested where this project has no local machine, which
/// is how the inotify-everywhere bug survived in the first place.
pub const Polling = struct {
    allocator: std.mem.Allocator,
    roots: std.ArrayList([]const u8),
    /// path -> stamp as of the last completed walk. Keys are owned here.
    seen: std.StringHashMap(io.Stamp),
    f: filter_mod.Filter,
    last_walk_ms: i64,
    /// The first walk records the tree without reporting it. The caller has just
    /// finished indexing or loading a snapshot, so announcing every file as
    /// created would re-index the whole workspace on startup.
    primed: bool,

    pub fn init(allocator: std.mem.Allocator) !Polling {
        return .{
            .allocator = allocator,
            .roots = std.ArrayList([]const u8).empty,
            .seen = std.StringHashMap(io.Stamp).init(allocator),
            .f = filter_mod.Filter.init(allocator),
            .last_walk_ms = 0,
            .primed = false,
        };
    }

    pub fn deinit(self: *Polling) void {
        for (self.roots.items) |r| self.allocator.free(r);
        self.roots.deinit(self.allocator);
        var it = self.seen.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.seen.deinit();
        self.f.deinit();
    }

    pub fn add_recursive(self: *Polling, root_path: []const u8) !void {
        self.f.load_gitignore(root_path) catch {};
        try self.roots.append(self.allocator, try self.allocator.dupe(u8, root_path));
    }

    fn walk_into(self: *Polling, root: []const u8, current: *std.StringHashMap(io.Stamp)) !void {
        var dir = io.cwd().openDir(io.io(), root, .{ .iterate = true }) catch return;
        defer dir.close(io.io());
        var walker = try dir.walk(self.allocator);
        defer walker.deinit();

        while (walker.next(io.io()) catch null) |entry| {
            if (entry.kind == .directory) {
                if (self.f.should_skip_dir(entry.path)) continue;
                continue;
            }
            if (entry.kind != .file) continue;
            if (self.f.should_ignore(entry.path)) continue;

            const stamp = io.stampFileFrom(entry.dir, entry.basename) orelse continue;
            const full = std.fs.path.join(self.allocator, &.{ root, entry.path }) catch continue;
            const gop = current.getOrPut(full) catch {
                self.allocator.free(full);
                continue;
            };
            if (gop.found_existing) {
                self.allocator.free(full);
            } else {
                gop.key_ptr.* = full;
            }
            gop.value_ptr.* = stamp;
        }
    }

    pub fn poll_events(self: *Polling, context: anytype, callback: anytype) !void {
        const now = io.milliTimestamp();
        if (now - self.last_walk_ms < poll_interval_ms) return;
        self.last_walk_ms = now;

        var current = std.StringHashMap(io.Stamp).init(self.allocator);
        defer {
            var it = current.keyIterator();
            while (it.next()) |k| self.allocator.free(k.*);
            current.deinit();
        }
        for (self.roots.items) |root| try self.walk_into(root, &current);

        if (!self.primed) {
            self.primed = true;
            try self.adopt(&current);
            return;
        }

        var it = current.iterator();
        while (it.next()) |entry| {
            const path = entry.key_ptr.*;
            if (self.seen.get(path)) |before| {
                if (!before.eql(entry.value_ptr.*)) {
                    try callback(context, Event{ .path = path, .op = .modify });
                }
            } else {
                try callback(context, Event{ .path = path, .op = .create });
            }
        }

        // Anything the previous walk held and this one did not is gone. Collect
        // before reporting: the callback mutates the index, not this map, but
        // the keys are freed by adopt() below and must not be read after.
        var vanished = std.ArrayList([]const u8).empty;
        defer vanished.deinit(self.allocator);
        var sit = self.seen.keyIterator();
        while (sit.next()) |k| {
            if (current.contains(k.*)) continue;
            try vanished.append(self.allocator, k.*);
        }
        for (vanished.items) |path| {
            try callback(context, Event{ .path = path, .op = .delete });
        }

        try self.adopt(&current);
    }

    /// Replace `seen` with this walk's result, taking ownership of its keys.
    fn adopt(self: *Polling, current: *std.StringHashMap(io.Stamp)) !void {
        var old = self.seen;
        var next = std.StringHashMap(io.Stamp).init(self.allocator);
        var it = current.iterator();
        while (it.next()) |entry| {
            const key = try self.allocator.dupe(u8, entry.key_ptr.*);
            next.put(key, entry.value_ptr.*) catch {
                self.allocator.free(key);
                continue;
            };
        }
        self.seen = next;
        var oit = old.keyIterator();
        while (oit.next()) |k| self.allocator.free(k.*);
        old.deinit();
    }
};

/// Linux syscalls return errors as the top 4 KiB of the unsigned range
/// (i.e. -4095..-1 reinterpreted). 0.16 dropped the std.posix inotify wrappers,
/// so we call the raw linux syscalls and check the return this way.
fn syscall_ok(rc: usize) bool {
    return rc <= std.math.maxInt(usize) - 4096;
}

const INotify = struct {
    allocator: std.mem.Allocator,
    fd: i32,
    wd_map: std.AutoHashMap(i32, []const u8),
    last_event: std.StringHashMap(i64), // path -> timestamp for debouncing

    pub fn init(allocator: std.mem.Allocator) !INotify {
        const rc = linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
        if (!syscall_ok(rc)) return error.INotifyInitFailed;
        const fd: i32 = @intCast(rc);

        return INotify{
            .allocator = allocator,
            .fd = fd,
            .wd_map = std.AutoHashMap(i32, []const u8).init(allocator),
            .last_event = std.StringHashMap(i64).init(allocator),
        };
    }

    pub fn deinit(self: *INotify) void {
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

    pub fn add_recursive(self: *INotify, root_path: []const u8) !void {
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

    pub fn poll_events(self: *INotify, context: anytype, callback: anytype) !void {
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

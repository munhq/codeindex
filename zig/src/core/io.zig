//! Centralized I/O backend.
//!
//! Zig 0.16 removed the implicit process-global that used to back
//! `std.fs.cwd()`, so every filesystem operation now requires an explicit `Io`
//! handle. Rather than thread that handle through every function in the
//! codebase, we own exactly one blocking backend here and expose it plus a few
//! reusable helpers. All `std.Io` churn is isolated to this file — when a future
//! Zig release reshuffles the I/O API again, this is the only place to touch.

const std = @import("std");

pub const File = std.Io.File;
pub const Dir = std.Io.Dir;
pub const Limit = std.Io.Limit;

var backend: std.Io.Threaded = undefined;
var handle: std.Io = undefined;
var ready = false;

/// The shared blocking handle, lazily initialized on first use. `main` calls
/// `init` explicitly with the program allocator; this fallback (page allocator)
/// covers tests and any path that touches I/O before `init` runs.
fn h() std.Io {
    if (!ready) init(std.heap.page_allocator);
    return handle;
}

/// Reader/writer lock. 0.16 replaced `std.Thread.RwLock` with an Io-based lock
/// that needs an `Io` on every call; this wraps it with the shared handle so
/// call sites keep the familiar argument-free lock()/unlock().
pub const RwLock = struct {
    inner: std.Io.RwLock = .init,

    pub fn lock(self: *RwLock) void {
        self.inner.lockUncancelable(h());
    }
    pub fn unlock(self: *RwLock) void {
        self.inner.unlock(h());
    }
    pub fn lockShared(self: *RwLock) void {
        self.inner.lockSharedUncancelable(h());
    }
    pub fn unlockShared(self: *RwLock) void {
        self.inner.unlockShared(h());
    }
};

/// Mutual-exclusion lock; same wrapping rationale as `RwLock`.
pub const Mutex = struct {
    inner: std.Io.Mutex = .init,

    pub fn lock(self: *Mutex) void {
        self.inner.lockUncancelable(h());
    }
    pub fn unlock(self: *Mutex) void {
        self.inner.unlock(h());
    }
};

/// Initialize the process-wide blocking I/O backend. Call once at startup
/// (before any other helper here) and pair with `deinit`.
pub fn init(gpa: std.mem.Allocator) void {
    backend = std.Io.Threaded.init(gpa, .{});
    handle = backend.io();
    ready = true;
}

pub fn deinit() void {
    if (ready) backend.deinit();
    ready = false;
}

/// The shared blocking `Io` handle, for call sites that drive the File/Dir APIs
/// directly (incremental writers, directory walks).
pub fn io() std.Io {
    return h();
}

pub fn cwd() Dir {
    return Dir.cwd();
}

/// Milliseconds since the Unix epoch (wall clock). 0.16 made time an I/O
/// operation; centralized here so call sites stay argument-free.
pub fn milliTimestamp() i64 {
    return std.Io.Timestamp.now(h(), .real).toMilliseconds();
}

/// Sleep for the given number of nanoseconds. 0.16 made sleep an I/O operation.
pub fn sleep(nanoseconds: u64) void {
    std.Io.sleep(h(), .{ .nanoseconds = @intCast(nanoseconds) }, .awake) catch {};
}

/// Look up an environment variable for the current process. Caller owns the
/// returned slice. Returns null if unset or on error. 0.16 reworked env access
/// (the env block must otherwise be threaded from `main`); since we link libc,
/// we read it via C `getenv`, centralized here with the rest of the platform glue.
pub fn getEnv(gpa: std.mem.Allocator, key: []const u8) ?[]u8 {
    const key_z = gpa.dupeZ(u8, key) catch return null;
    defer gpa.free(key_z);
    const val = std.c.getenv(key_z.ptr) orelse return null;
    return gpa.dupe(u8, std.mem.span(val)) catch null;
}

pub fn stdout() File {
    return File.stdout();
}

pub fn stdin() File {
    return File.stdin();
}

/// Change the process working directory (process-global, unrelated to `handle`).
pub fn changeCurDir(path: []const u8) !void {
    return std.Io.Threaded.chdir(path);
}

/// Canonical absolute path of `path` relative to cwd. Caller frees.
pub fn realpathAlloc(gpa: std.mem.Allocator, path: []const u8) ![:0]u8 {
    return cwd().realPathFileAlloc(h(), path, gpa);
}

/// Read an entire file (relative to cwd) into an allocated buffer, capped at `max`.
pub fn readFileAlloc(gpa: std.mem.Allocator, path: []const u8, max: usize) ![]u8 {
    return readFileFrom(cwd(), gpa, path, max);
}

/// Read an entire file relative to `dir` into an allocated buffer, capped at `max`.
pub fn readFileFrom(dir: Dir, gpa: std.mem.Allocator, sub_path: []const u8, max: usize) ![]u8 {
    var file = try dir.openFile(h(), sub_path, .{});
    defer file.close(h());
    var buf: [64 * 1024]u8 = undefined;
    var fr = file.reader(h(), &buf);
    return fr.interface.allocRemaining(gpa, Limit.limited(max));
}

/// Write all of `bytes` to an open file via a temporary writer, then flush.
pub fn writeAll(file: File, bytes: []const u8) !void {
    var buf: [64 * 1024]u8 = undefined;
    var fw = file.writer(h(), &buf);
    try fw.interface.writeAll(bytes);
    try fw.interface.flush();
}

/// Atomically write `bytes` to `path`: write to `<path>.tmp`, fsync, rename.
pub fn writeFileAtomic(gpa: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
    const tmp_path = try std.fmt.allocPrint(gpa, "{s}.tmp", .{path});
    defer gpa.free(tmp_path);

    const d = cwd();
    var file = try d.createFile(h(), tmp_path, .{});
    errdefer d.deleteFile(h(), tmp_path) catch {};
    {
        defer file.close(h());
        var buf: [64 * 1024]u8 = undefined;
        var fw = file.writer(h(), &buf);
        try fw.interface.writeAll(bytes);
        try fw.interface.flush();
        try file.sync(h());
    }
    try d.rename(tmp_path, d, path, h());
}

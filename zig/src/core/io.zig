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

/// Modification time and size of a file — the pair that decides whether an
/// indexed file changed while the server was not running to watch it.
pub const Stamp = struct {
    /// Nanoseconds since the epoch. i64 holds that until the year 2262 and is
    /// what JSON round-trips losslessly, unlike the i96 std reports.
    mtime_ns: i64,
    size: u64,

    pub fn eql(self: Stamp, other: Stamp) bool {
        return self.mtime_ns == other.mtime_ns and self.size == other.size;
    }
};

/// Stamp for `path` relative to cwd, or null when it cannot be read. A null is
/// treated as "changed" by callers, which errs toward re-indexing.
pub fn stampFile(path: []const u8) ?Stamp {
    const st = cwd().statFile(h(), path, .{}) catch return null;
    return .{ .mtime_ns = @intCast(st.mtime.toNanoseconds()), .size = st.size };
}

/// Stamp for `sub_path` relative to `dir`. Same contract as `stampFile`; used by
/// the directory walk, which already holds an open handle on the parent.
pub fn stampFileFrom(dir: Dir, sub_path: []const u8) ?Stamp {
    const st = dir.statFile(h(), sub_path, .{}) catch return null;
    return .{ .mtime_ns = @intCast(st.mtime.toNanoseconds()), .size = st.size };
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
/// One read from `file`, at most `buffer.len` bytes. Mirrors the POSIX read
/// contract the MCP loop was written against: the byte count, and 0 at EOF.
///
/// The loop used `std.posix.read(std.posix.STDIN_FILENO, ...)`, which does not
/// compile for Windows — there `fd_t` is a HANDLE, not an int. std reports EOF
/// as `error.EndOfStream`, so that is translated back to 0 here rather than at
/// every call site.
/// The separator every stored path key uses, on every platform.
///
/// Index keys are compared against import specifiers, which are written with
/// forward slashes in every language this indexes. The resolver therefore tests
/// for '/' throughout. On Windows `std.fs.path.join` produces '\\', so no key
/// ever matched and the dependency graph came back empty — while the resolver
/// tests kept passing, because their fixtures are literal "/ws/src/a.ts"
/// strings rather than paths the scanner built. Win32 accepts '/' in a path, so
/// normalising costs nothing and makes a snapshot portable between platforms.
pub const key_sep = '/';

/// Join into a path key. Same as std.fs.path.join except the separator is always
/// `key_sep`, and any separator already inside a component is normalised too.
pub fn joinKey(gpa: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    var total: usize = 0;
    for (parts) |part| total += part.len + 1;
    var out = try std.ArrayList(u8).initCapacity(gpa, total);
    errdefer out.deinit(gpa);
    for (parts) |part| {
        if (part.len == 0) continue;
        if (out.items.len > 0 and out.items[out.items.len - 1] != key_sep) {
            try out.append(gpa, key_sep);
        }
        const trimmed = if (out.items.len > 0)
            std.mem.trimStart(u8, part, "/\\")
        else
            part;
        for (trimmed) |c| try out.append(gpa, if (c == '\\') key_sep else c);
    }
    return out.toOwnedSlice(gpa);
}

/// Rewrite a path in place to use `key_sep`. Used on the workspace root, so the
/// absolute prefix of every key agrees with the joined remainder.
///
/// Returns nothing on purpose. It returned the slice, and callers assigned that
/// to a `[]const u8` — which silently dropped the sentinel on the `[:0]u8` that
/// realpath hands back, so the later free released one byte less than was
/// allocated. Mutating in place keeps the caller's own slice, with its own
/// length and sentinel, as the thing that gets freed.
pub fn normalizeKey(path: []u8) void {
    for (path) |*c| {
        if (c.* == '\\') c.* = key_sep;
    }
}

pub fn readSome(file: File, buffer: []u8) !usize {
    var bufs: [1][]u8 = .{buffer};
    return file.readStreaming(h(), &bufs) catch |err| switch (err) {
        error.EndOfStream => 0,
        else => err,
    };
}

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

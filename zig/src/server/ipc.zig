//! Where a workspace's daemon listens, and how a client reaches it.
//!
//! One index per workspace, not one per session. Every MCP client that opens
//! the same project connects to the same socket, so the tree is parsed once,
//! watched once and written once, however many agents are attached.
//!
//! The transport is a Unix-domain socket on every supported platform. Windows
//! has had AF_UNIX since Windows 10 1803 and `std.Io.net.has_unix_sockets`
//! reports it, so this needs no second transport and no loopback TCP port with
//! a shared secret to guard it — the socket is a file, and the directory it
//! sits in is the permission boundary.

const std = @import("std");
const builtin = @import("builtin");
const io = @import("../core/io.zig");

pub const net = std.Io.net;

/// True when this build can talk to a daemon at all. A platform without
/// AF_UNIX keeps the in-process server, which is the behaviour that predates
/// the daemon and is never worse than it.
pub const supported = net.has_unix_sockets;

/// POSIX caps a socket path at 108 bytes including the terminator, and macOS at
/// 104. Everything below is built to stay far inside that; a candidate that
/// does not is rejected in favour of a shorter directory.
const max_path = 100;

/// Identify the daemon by the tree it serves AND the binary serving it. Without
/// the version a rebuilt binary would hand its clients to a daemon still
/// running the old code, which is the one upgrade bug that would be invisible:
/// the client connects, the handshake succeeds, and every answer comes from the
/// version the user thought they had replaced.
pub fn slug(buf: *[16]u8, workspace_abs: []const u8, version: []const u8) []const u8 {
    var h = std.hash.Wyhash.init(0x0de1_2de1);
    h.update(workspace_abs);
    h.update("\x00");
    h.update(version);
    return std.fmt.bufPrint(buf, "{x:0>16}", .{h.final()}) catch unreachable;
}

/// The directory the socket and the daemon log live in. Caller frees.
///
/// Ordered by how private and how short each candidate is. XDG_RUNTIME_DIR is
/// both: it is per-user, mode 0700, and on a tmpfs that is cleared on logout,
/// so a socket never outlives the session that made it.
pub fn runtime_dir(gpa: std.mem.Allocator) ![]u8 {
    if (builtin.os.tag == .windows) {
        if (io.getEnv(gpa, "LOCALAPPDATA")) |base| {
            defer gpa.free(base);
            return std.fs.path.join(gpa, &.{ base, "codeindex", "run" });
        }
        if (io.getEnv(gpa, "TEMP")) |base| {
            defer gpa.free(base);
            return std.fs.path.join(gpa, &.{ base, "codeindex-run" });
        }
        return error.NoRuntimeDir;
    }

    if (io.getEnv(gpa, "XDG_RUNTIME_DIR")) |base| {
        defer gpa.free(base);
        if (base.len > 0) {
            const p = try std.fs.path.join(gpa, &.{ base, "codeindex" });
            if (p.len + 1 + 16 + 5 <= max_path) return p;
            gpa.free(p);
        }
    }

    // No XDG_RUNTIME_DIR (macOS never sets it) or it was too long. Fall back to
    // a per-uid directory, which is what keeps one user's socket out of
    // another's reach on a shared /tmp.
    const uid = std.c.getuid();
    const tmp = io.getEnv(gpa, "TMPDIR") orelse try gpa.dupe(u8, "/tmp");
    defer gpa.free(tmp);
    const trimmed = std.mem.trimEnd(u8, tmp, "/");
    const named = try std.fmt.allocPrint(gpa, "{s}/codeindex-{d}", .{ trimmed, uid });
    if (named.len + 1 + 16 + 5 <= max_path) return named;
    gpa.free(named);

    // A TMPDIR long enough to break the limit still leaves /tmp.
    return std.fmt.allocPrint(gpa, "/tmp/codeindex-{d}", .{uid});
}

pub const Paths = struct {
    dir: []u8,
    sock: []u8,
    log: []u8,

    pub fn deinit(self: Paths, gpa: std.mem.Allocator) void {
        gpa.free(self.dir);
        gpa.free(self.sock);
        gpa.free(self.log);
    }
};

fn dir_exists(path: []const u8) bool {
    var d = io.cwd().openDir(io.io(), path, .{}) catch return false;
    d.close(io.io());
    return true;
}

/// How many missing levels this will create before giving up. A runtime
/// directory is one or two below something that already exists; anything deeper
/// is a sign the path is wrong, not a directory worth building.
const max_missing_levels = 8;

/// Create `dir` and any missing parents, then report whether it is usable.
///
/// Deliberately NOT `std.Io.Dir.createDirPath`. Zig 0.16's implementation walks
/// BACK to the parent whenever a component returns ENOENT and forward again
/// when one exists — and a path whose parent exists while the child still
/// reports ENOENT makes it oscillate between the two forever, at 100% of a
/// core. `/proc/anything` does exactly that on Linux: `mkdir /proc/x` returns
/// ENOENT, not EACCES. This path comes from XDG_RUNTIME_DIR or TMPDIR, which
/// are precisely the values this program does not control, so it must not be
/// handed to a loop a bad value can hang.
///
/// This walks up to the deepest ancestor that exists, bounded, then creates
/// forward from there. It never revisits a level, so it cannot spin.
pub fn usable_dir(dir: []const u8) bool {
    if (dir_exists(dir)) return true;

    var missing: [max_missing_levels][]const u8 = undefined;
    var n: usize = 0;
    var found_base = false;
    var cur: []const u8 = dir;
    while (n < missing.len) {
        const parent = std.fs.path.dirname(cur) orelse break;
        if (parent.len == 0 or std.mem.eql(u8, parent, cur)) break;
        missing[n] = cur;
        n += 1;
        if (dir_exists(parent)) {
            found_base = true;
            break;
        }
        cur = parent;
    }
    // Nothing that exists within the bound: the path is not somewhere this
    // program should be building a tree.
    if (!found_base) return false;

    var i: usize = n;
    while (i > 0) {
        i -= 1;
        io.cwd().createDir(io.io(), missing[i], .default_dir) catch {};
        if (!dir_exists(missing[i])) return false;
    }
    return true;
}

/// Resolve every path this workspace's daemon uses, and make sure the directory
/// exists and is private to this user.
///
/// The preferred directory is tried first, then `/tmp`. One candidate was not
/// enough: XDG_RUNTIME_DIR and TMPDIR are both environment-supplied, and a
/// sandbox, a read-only mount or a stale TMPDIR pointing at a directory this
/// user cannot write makes the first choice fail. That failure used to end the
/// daemon with `error.NoRuntimeDir` — and because the client waits for a socket
/// that will now never appear, every session paid a ten-second stall before
/// falling back to indexing in-process.
pub fn paths(gpa: std.mem.Allocator, workspace_abs: []const u8, version: []const u8) !Paths {
    var dir = try runtime_dir(gpa);
    errdefer gpa.free(dir);

    // Each candidate must be creatable, made 0700, and then PROVE it is ours
    // and closed to others — see `private_usable_dir`.
    if (!private_usable_dir(dir)) {
        gpa.free(dir);
        dir = try fallback_dir(gpa);
        if (!private_usable_dir(dir)) return error.NoRuntimeDir;
    }

    var buf: [16]u8 = undefined;
    const s = slug(&buf, workspace_abs, version);

    const sock = try std.fmt.allocPrint(gpa, "{s}{c}{s}.sock", .{ dir, std.fs.path.sep, s });
    errdefer gpa.free(sock);
    const log = try std.fmt.allocPrint(gpa, "{s}{c}{s}.log", .{ dir, std.fs.path.sep, s });

    return .{ .dir = dir, .sock = sock, .log = log };
}

/// The last resort when the preferred runtime directory cannot be used. `/tmp`
/// is writable on every system this runs on; the uid keeps one user's socket out
/// of another's reach when it is shared.
fn fallback_dir(gpa: std.mem.Allocator) ![]u8 {
    if (builtin.os.tag == .windows) {
        if (io.getEnv(gpa, "TEMP")) |base| {
            defer gpa.free(base);
            return std.fs.path.join(gpa, &.{ base, "codeindex-run" });
        }
        return error.NoRuntimeDir;
    }
    return std.fmt.allocPrint(gpa, "/tmp/codeindex-{d}", .{std.c.getuid()});
}

/// A candidate is accepted only when it can be created AND made private.
///
/// `usable_dir` alone accepted any writable directory, which on a shared /tmp
/// includes one another local user created first; our socket would then sit in
/// their directory, theirs to swap out. The ownership proof is chmod itself:
/// chmod(2) fails with EPERM for anyone but the owner, so a chmod that
/// succeeded means we own the directory and its mode is now 0700 — nobody else
/// can even traverse it. No stat, no uid comparison, no window between the two.
pub fn private_usable_dir(dir: []const u8) bool {
    return usable_dir(dir) and set_private(dir);
}

/// The socket file itself: connect() needs write permission on it, so 0600
/// closes it to every other user even if the directory were traversable.
fn restrict_socket(sock_path: []const u8) void {
    if (builtin.os.tag == .windows) return;
    const z = std.heap.page_allocator.dupeZ(u8, sock_path) catch return;
    defer std.heap.page_allocator.free(z);
    _ = std.c.chmod(z.ptr, 0o600);
}

/// 0700. A socket inherits the directory's reachability, so this is what
/// stops another local user connecting to the index of this one's private
/// repository. Returns whether it took effect — which doubles as the proof
/// that this user owns the directory (see `private_usable_dir`). Windows has
/// no POSIX modes; the per-user LOCALAPPDATA path is the protection there.
fn set_private(dir: []const u8) bool {
    if (builtin.os.tag == .windows) return true;
    const z = std.heap.page_allocator.dupeZ(u8, dir) catch return false;
    defer std.heap.page_allocator.free(z);
    return std.c.chmod(z.ptr, 0o700) == 0;
}

/// Connect to the daemon for this workspace, or null when none is listening.
///
/// A refusal is not an error here. The common case on a cold machine is that
/// nothing is listening yet, and the caller's answer to that is to start one.
pub fn connect(sock_path: []const u8) ?net.Stream {
    if (!supported) return null;
    const addr = net.UnixAddress.init(sock_path) catch return null;
    return addr.connect(io.io()) catch null;
}

/// Bind the workspace's socket, removing a socket file left behind by a daemon
/// that died without cleaning up.
///
/// The stale check is a connect, never a timestamp or a pid file: the only
/// question that matters is whether something is answering on that path right
/// now. `AddressInUse` after the unlink means another daemon won the same race
/// legitimately, and the caller must not take the workspace from it.
pub fn listen(sock_path: []const u8) !net.Server {
    const srv = try listen_inner(sock_path);
    restrict_socket(sock_path);
    return srv;
}

fn listen_inner(sock_path: []const u8) !net.Server {
    const addr = try net.UnixAddress.init(sock_path);
    return addr.listen(io.io(), .{}) catch |err| switch (err) {
        error.AddressInUse => {
            if (connect(sock_path)) |live| {
                // Someone is serving. Hand the caller the refusal so it
                // connects as a client instead of stealing the socket.
                live.close(io.io());
                return error.AddressInUse;
            }
            io.cwd().deleteFile(io.io(), sock_path) catch {};
            return addr.listen(io.io(), .{});
        },
        else => err,
    };
}

//! Live binary hot-reload for the MCP stdio server.
//!
//! On SIGHUP the server re-execs the current binary in place, preserving fd 0/1
//! (the MCP socket), so a client never sees a disconnect — an operator can roll
//! out a rebuilt binary to every running server with one `pkill -HUP -f
//! 'codeindex --mcp'`, no session restart. The already-running process that
//! receives the signal must itself carry this code, so the very first rollout
//! after adding it still needs a normal restart; every rollout after that is
//! seamless.
//!
//! execve() is async-signal-safe, so the handler can re-exec directly — but only
//! when it is safe to do so. The MCP loop marks itself "safe" only while blocked
//! in read() (no response half-written); a signal that lands mid-request is
//! deferred via `pending` and applied by the loop the instant the current
//! response is fully flushed. Net effect: reload is immediate when idle, and
//! never truncates an in-flight JSON-RPC line.
//!
//! All exec arguments (resolved exe path, argv, envp) are captured once in
//! arm(), before the handler is installed, so the handler itself only performs
//! async-signal-safe work (atomic loads + execve).

const std = @import("std");
const builtin = @import("builtin");

/// Selected at compile time. The implementation is SIGHUP + execve + the
/// process command line read from /proc, none of which exist off Linux: on
/// Windows `std.posix.Sigaction` is `void`, so even naming it fails to compile.
/// The stub keeps the four call sites in the MCP loop unconditional, and hot
/// reload is simply a feature Linux has and the others do not.
pub const supported = builtin.os.tag == .linux;
const impl = if (supported) Posix else Stub;

pub fn arm(gpa: std.mem.Allocator) void {
    return impl.arm(gpa);
}
pub fn check_pending() void {
    return impl.check_pending();
}
pub fn enter_wait() void {
    return impl.enter_wait();
}
pub fn leave_wait() void {
    return impl.leave_wait();
}

/// Every function is a no-op, so a server on a platform without signals runs
/// the same loop and simply never re-execs. It reports `supported == false`
/// rather than pretending a reload happened.
const Stub = struct {
    fn arm(gpa: std.mem.Allocator) void {
        _ = gpa;
    }
    fn check_pending() void {}
    fn enter_wait() void {}
    fn leave_wait() void {}
};

const Posix = struct {
    var g_armed: bool = false;
    /// Set only while the MCP loop is parked in read() with nothing half-written.
    var g_safe = std.atomic.Value(bool).init(false);
    /// A signal that arrived while unsafe (mid-request); applied at the next safe point.
    var g_pending = std.atomic.Value(bool).init(false);

    // Exec state, built once in arm() and never freed (process-lifetime).
    var g_exe_path: [:0]const u8 = undefined;
    var g_argv: [*:null]const ?[*:0]const u8 = undefined;

    /// Re-exec the current binary with its original argv and environment. Returns
    /// only if execve fails (kept minimal + async-signal-safe: no allocation, no
    /// stdio — a handler must not call non-reentrant code).
    fn do_exec() void {
        _ = std.os.linux.execve(g_exe_path.ptr, g_argv, @ptrCast(std.c.environ));
        // execve only returns on failure. Nothing safe to log from a signal
        // handler; leave the server running so a failed reload is a no-op.
        g_pending.store(false, .release);
    }

    fn on_sighup(_: std.posix.SIG) callconv(.c) void {
        if (g_safe.load(.acquire)) {
            do_exec();
        } else {
            // Mid-request: defer. check_pending() applies it once the response is out.
            g_pending.store(true, .release);
        }
    }

    /// Capture exec arguments from /proc and install the SIGHUP handler. Best-effort:
    /// if /proc is unreadable the handler is simply not installed (reload disabled),
    /// never fatal. Call once, from the MCP server before its read loop.
    fn arm(allocator: std.mem.Allocator) void {
        // Resolved path of the running binary (follows the /proc/self/exe symlink,
        // so it survives the original argv[0] being relative or a bare name).
        const buf = allocator.alloc(u8, std.fs.max_path_bytes + 1) catch return;
        // Raw readlink syscall (Linux server): returns bytes written, or a negative
        // errno. std.posix has no readlink in this Zig; the linux syscall is exact.
        const rc = std.os.linux.readlink("/proc/self/exe", buf.ptr, std.fs.max_path_bytes);
        if (@as(isize, @bitCast(rc)) < 0) return; // errno → reload just stays disarmed
        const exe_len: usize = rc;
        buf[exe_len] = 0;
        g_exe_path = buf[0..exe_len :0];

        // Original argv, verbatim: /proc/self/cmdline is the NUL-separated argument
        // vector (each arg already NUL-terminated in place), with a trailing NUL.
        // Read via the raw syscall, NOT a file reader: /proc files report stat size
        // 0, and the std File.Reader pre-sizes from that and yields nothing.
        const cmd_buf = allocator.alloc(u8, 256 * 1024) catch return;
        const ofd = std.os.linux.open("/proc/self/cmdline", .{}, 0);
        if (@as(isize, @bitCast(ofd)) < 0) return;
        const cfd: i32 = @intCast(ofd);
        var total: usize = 0;
        while (total < cmd_buf.len) {
            const r = std.os.linux.read(cfd, cmd_buf.ptr + total, cmd_buf.len - total);
            if (@as(isize, @bitCast(r)) < 0) {
                _ = std.os.linux.close(cfd);
                return;
            }
            if (r == 0) break;
            total += r;
        }
        _ = std.os.linux.close(cfd);
        if (total == 0) return;
        const cmdline = cmd_buf[0..total];
        var nargs: usize = 0;
        for (cmdline) |c| {
            if (c == 0) nargs += 1;
        }
        if (nargs == 0) return; // no trailing NUL — malformed, don't risk a bad argv
        const argv = allocator.alloc(?[*:0]const u8, nargs + 1) catch return;
        var idx: usize = 0;
        var start: usize = 0;
        for (cmdline, 0..) |c, i| {
            if (c != 0) continue;
            argv[idx] = @ptrCast(cmdline.ptr + start); // cmdline[i] == 0 → NUL-terminated
            idx += 1;
            start = i + 1;
        }
        argv[idx] = null;
        g_argv = @ptrCast(argv.ptr);

        var act = std.posix.Sigaction{
            .handler = .{ .handler = on_sighup },
            .mask = std.posix.sigemptyset(),
            // No SA_RESTART is needed: the handler either execs (never returns) or
            // just sets a flag, after which the interrupted read is retried normally.
            .flags = 0,
        };
        std.posix.sigaction(.HUP, &act, null);
        g_armed = true;
    }

    /// Mark the calling thread as parked (safe to re-exec now). Call immediately
    /// before the blocking read; pair with leave_wait().
    fn enter_wait() void {
        if (g_armed) g_safe.store(true, .release);
    }

    /// Mark the calling thread as busy (a response may be in flight). Call the
    /// instant read() returns, before processing.
    fn leave_wait() void {
        if (g_armed) g_safe.store(false, .release);
    }

    /// Apply a reload that was deferred because it arrived mid-request. Call at the
    /// top of the loop, after the previous response has been fully flushed. No-op
    /// unless a signal is pending.
    fn check_pending() void {
        if (g_armed and g_pending.load(.acquire)) do_exec();
    }
};

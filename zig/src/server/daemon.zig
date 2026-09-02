//! One index, many clients.
//!
//! The daemon owns a workspace: it parses the tree once, watches it once, and
//! writes its snapshot once. Every MCP session that opens the project connects
//! here and gets its own protocol conversation over its own socket, all served
//! from the one `Explorer` they share.
//!
//! What is per-connection and what is shared is the whole design:
//!
//!   per connection   a `Server` value — the MCP handshake state, the client's
//!                    `roots` capability, the id of an in-flight request
//!   shared           the `Explorer`, the tree-sitter parser, the ignore filter,
//!                    the file watcher, the snapshot
//!
//! The parser is the one shared thing that is not safe to touch concurrently,
//! so it travels with the mutex that guards it. Nothing else here takes a lock
//! the single-process server did not already take: `Explorer` was built for one
//! writer and many readers, which is exactly this shape.

const std = @import("std");
const builtin = @import("builtin");
const io = @import("../core/io.zig");
const conn_mod = @import("../core/conn.zig");
const http = @import("http.zig");
const explorer = @import("../index/explorer.zig");
const treesitter = @import("../parser/treesitter.zig");
const filter_mod = @import("../core/filter.zig");
const storage = @import("../storage/snapshot.zig");
const ipc = @import("ipc.zig");

pub const net = std.Io.net;

/// Sent to a client when the daemon is winding down mid-handshake, so the
/// session fails loudly instead of hanging on a socket nobody will answer.
const shutting_down_ms: u64 = 200;

pub const Daemon = struct {
    gpa: std.mem.Allocator,
    exp: *explorer.Explorer,
    parser: *treesitter.Parser,
    filter: *filter_mod.Filter,
    /// Guards the tree-sitter parser, which is shared by every connection's
    /// `index_workspace` and by the watcher thread. Tree-sitter parsers hold
    /// mutable scratch state and are not safe to enter twice.
    parser_lock: *io.Mutex,
    workspace_abs: []const u8,
    snapshot_path: []const u8,
    sock_path: []const u8,

    server: net.Server = undefined,
    /// Connections currently being served. The daemon retires itself only at
    /// zero, so a long-lived agent session never has its index pulled away.
    live: std.atomic.Value(i64) = .init(0),
    /// When the last connection closed. Idle is measured from here, not from
    /// the last query, so a client that is attached but quiet keeps the index.
    idle_since_ms: std.atomic.Value(i64) = .init(0),
    running: std.atomic.Value(bool) = .init(true),
    /// Seconds with no connection at all before the daemon exits and returns
    /// its memory. 0 keeps it alive indefinitely.
    idle_exit_secs: i64 = 900,

    const ConnCtx = struct {
        d: *Daemon,
        stream: net.Stream,
    };

    /// Serve one client for the life of its socket. Runs on its own detached
    /// thread; everything it allocates it frees here.
    fn serve_conn(ctx: *ConnCtx) void {
        const d = ctx.d;
        const gpa = d.gpa;
        defer {
            const remaining = d.live.fetchSub(1, .acq_rel) - 1;
            if (remaining == 0) d.idle_since_ms.store(io.milliTimestamp(), .release);
            gpa.destroy(ctx);
        }

        const sock = conn_mod.Socket.create(gpa, ctx.stream) catch {
            ctx.stream.close(io.io());
            return;
        };
        defer sock.destroy(gpa);

        var srv = http.Server.init(gpa, d.exp);
        srv.with_parser(d.parser, d.filter);
        srv.with_parser_lock(d.parser_lock);
        // The daemon is only ever started with a workspace somebody resolved
        // explicitly, so the root is never a guess and the `roots` round trip
        // that corrects a guess never fires. That is also what keeps adoption
        // out of the daemon: one client must not be able to move the tree
        // another client is reading.
        srv.with_workspace(d.workspace_abs, null, false);
        srv.watcher_live = true;

        const c = conn_mod.Conn{ .socket = sock };
        srv.run_mcp_conn(c, c) catch {};
    }

    /// Accept until `stop` is called. One thread per client.
    pub fn serve(self: *Daemon) !void {
        self.idle_since_ms.store(io.milliTimestamp(), .release);

        var monitor: ?std.Thread = null;
        if (self.idle_exit_secs > 0)
            monitor = std.Thread.spawn(.{}, idle_monitor, .{self}) catch null;

        while (self.running.load(.acquire)) {
            const stream = self.server.accept(io.io()) catch |err| switch (err) {
                // `shutdown` on the listening socket is how `stop` cancels this
                // blocking accept; both spellings mean the same thing here.
                error.SocketNotListening, error.Canceled => break,
                error.ConnectionAborted, error.WouldBlock => continue,
                else => break,
            };
            if (!self.running.load(.acquire)) {
                stream.close(io.io());
                break;
            }

            const ctx = self.gpa.create(ConnCtx) catch {
                stream.close(io.io());
                continue;
            };
            ctx.* = .{ .d = self, .stream = stream };
            _ = self.live.fetchAdd(1, .acq_rel);

            const t = std.Thread.spawn(.{}, serve_conn, .{ctx}) catch {
                _ = self.live.fetchSub(1, .acq_rel);
                stream.close(io.io());
                self.gpa.destroy(ctx);
                continue;
            };
            t.detach();
        }

        // Stop taking new work before anything else, so a client that arrives
        // during the wind-down is refused at connect and starts a fresh daemon
        // rather than attaching to one that is about to exit.
        io.cwd().deleteFile(io.io(), self.sock_path) catch {};

        // Let sessions in flight finish. They are agent conversations, not
        // requests, so this waits on the connection closing rather than on any
        // one answer.
        var waited: u64 = 0;
        while (self.live.load(.acquire) > 0 and waited < 10 * std.time.ms_per_s) {
            io.sleep(shutting_down_ms * std.time.ns_per_ms);
            waited += shutting_down_ms;
        }

        if (monitor) |t| {
            self.running.store(false, .release);
            t.join();
        }
    }

    /// Retire the daemon once nothing has been connected for `idle_exit_secs`.
    ///
    /// Without this every workspace a person ever opened would keep a resident
    /// index for the life of the login session — which is the problem the
    /// daemon exists to fix, moved rather than solved.
    fn idle_monitor(self: *Daemon) void {
        const poll_ns: u64 = 5 * std.time.ns_per_s;
        while (self.running.load(.acquire)) {
            io.sleep(poll_ns);
            if (!self.running.load(.acquire)) break;
            if (self.live.load(.acquire) > 0) continue;
            const idle_ms = io.milliTimestamp() - self.idle_since_ms.load(.acquire);
            if (idle_ms < self.idle_exit_secs * std.time.ms_per_s) continue;
            self.stop();
            return;
        }
    }

    /// Cancel the blocking `accept` so `serve` returns and the process can save
    /// its snapshot and exit cleanly.
    ///
    /// A listening socket has no `shutdown` to cancel an accept with, so the
    /// flag is lowered first and then one throwaway connection is made to this
    /// daemon's own socket. `accept` returns it, the loop sees the flag, and it
    /// closes the connection and leaves. A client that connects in the same
    /// instant is dropped rather than served — which is why the socket file is
    /// removed before the wind-down waits, so the next client starts a fresh
    /// daemon instead of attaching to one that is leaving.
    pub fn stop(self: *Daemon) void {
        self.running.store(false, .release);
        if (ipc.connect(self.sock_path)) |s| s.close(io.io());
    }
};

/// Write the snapshot one last time, so the next daemon starts from disk rather
/// than re-parsing a tree this one already knows.
pub fn save_on_exit(d: *Daemon) void {
    storage.Snapshot.save(d.exp, d.snapshot_path, d.workspace_abs) catch {};
}

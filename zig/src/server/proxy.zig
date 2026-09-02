//! The client half of the daemon split: relay this process's stdio to the
//! workspace's daemon and back.
//!
//! An MCP client spawns one server process per session and speaks JSON-RPC to
//! it over stdio. That contract does not change. What changes is what the
//! process does: instead of parsing the tree and holding an index of its own,
//! it forwards bytes to the one process that already has them. Eight sessions
//! on one repository stop being eight indexes, eight file watchers and eight
//! writers of the same snapshot.

const std = @import("std");
const io = @import("../core/io.zig");

pub const net = std.Io.net;

const Pump = struct {
    stream: net.Stream,
    /// Set when either direction ends, so the other stops rather than blocking
    /// forever on a peer that has gone.
    done: *std.atomic.Value(bool),
};

/// Daemon -> our stdout. Runs on its own thread; the caller pumps the other way.
fn pump_out(ctx: *Pump) void {
    var buf: [64 * 1024]u8 = undefined;
    var r = ctx.stream.reader(io.io(), &buf);
    var chunk: [64 * 1024]u8 = undefined;
    const out = io.stdout();
    while (!ctx.done.load(.acquire)) {
        var data: [1][]u8 = .{&chunk};
        const n = r.interface.readVec(&data) catch break;
        if (n == 0) break;
        io.writeAll(out, chunk[0..n]) catch break;
    }
    ctx.done.store(true, .release);
}

/// Relay until either side closes. Returns when the session is over.
pub fn run(stream: net.Stream) !void {
    var done = std.atomic.Value(bool).init(false);
    var ctx = Pump{ .stream = stream, .done = &done };
    const t = try std.Thread.spawn(.{}, pump_out, .{&ctx});

    var buf: [64 * 1024]u8 = undefined;
    var w = stream.writer(io.io(), &buf);
    var chunk: [1024 * 1024]u8 = undefined;

    while (!done.load(.acquire)) {
        const n = io.readSome(io.stdin(), &chunk) catch break;
        if (n == 0) break; // the MCP client closed our stdin: the session ended
        w.interface.writeAll(chunk[0..n]) catch break;
        w.interface.flush() catch break;
    }

    // Tell the daemon this client is finished so it can retire the connection,
    // then wait for anything still in flight the other way.
    stream.shutdown(io.io(), .send) catch {};
    t.join();
    stream.close(io.io());
}

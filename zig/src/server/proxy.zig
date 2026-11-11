//! The client half of the daemon split: relay this process's stdio to the
//! workspace's daemon and back.
//!
//! An MCP client spawns one server process per session and speaks JSON-RPC to
//! it over stdio. That contract does not change. What changes is what the
//! process does: instead of parsing the tree and holding an index of its own,
//! it forwards bytes to the one process that already has them. Eight sessions
//! on one repository stop being eight indexes, eight file watchers and eight
//! writers of the same snapshot.
//!
//! A daemon serves one tree, and other sessions read it, so it never re-points.
//! A session can still move: an agent that starts in one checkout and works in
//! another (a second worktree, or a work folder that a checkout tool keeps
//! outside the first checkout) calls
//! `index_workspace` with the folder it works in. The relay sees that call,
//! connects to the daemon of that folder's project, replays the session's
//! `initialize` to it, and sends the call there. The client keeps one stdio
//! session and the old daemon keeps its tree.

const std = @import("std");
const io = @import("../core/io.zig");

pub const net = std.Io.net;

/// How the relay reaches another project's daemon. main.zig owns the project
/// rules and the daemon launch; the relay owns only the session.
pub const Switcher = struct {
    ctx: *anyopaque,
    /// The project root that `path` belongs to, owned by the caller, or null
    /// when the path is not a project the startup guards would allow.
    resolve: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, path: []const u8) ?[]u8,
    /// A connection to the daemon of `root`, started when none runs.
    connect: *const fn (ctx: *anyopaque, root: []const u8) ?net.Stream,
};

/// The longest wait for the old daemon to answer what this session still has
/// in flight on it before the session moves. An analysis of a large tree takes
/// seconds; a minute is far past any answer the daemon sends.
const switch_drain_ms: u64 = 60 * std.time.ms_per_s;

const Pump = struct {
    stream: net.Stream,
    /// Set when this direction ends, so the input loop stops rather than
    /// writing to a peer that has gone.
    done: std.atomic.Value(bool) = .init(false),
    /// Lines of daemon output to drop before anything reaches the client. A
    /// replayed `initialize` has an answer the client already received once.
    skip_lines: usize = 0,
};

/// Daemon -> our stdout. Runs on its own thread; the caller pumps the other way.
///
/// What the reader already holds goes out before the socket is read again.
/// `readVec` fills `chunk` and leaves the rest of a large answer in the reader's
/// own buffer, and on the next pass it copies that rest and then waits on the
/// socket for more before returning. No more comes until the client sends its
/// next request, so an answer over 64 KiB sat in the proxy while the client
/// waited for it: a 66 KB `read_symbol` took over 120 s in a live session.
/// A zero from `readVec` is not the end of the stream either; `EndOfStream` is.
fn pump_out(ctx: *Pump) void {
    var buf: [64 * 1024]u8 = undefined;
    var r = ctx.stream.reader(io.io(), &buf);
    var chunk: [64 * 1024]u8 = undefined;
    const out = io.stdout();
    while (true) {
        const held = r.interface.buffered();
        if (held.len > 0) {
            const keep = drop_skipped_lines(&ctx.skip_lines, held);
            io.writeAll(out, held[held.len - keep.len ..]) catch break;
            r.interface.toss(held.len);
            continue;
        }
        var data: [1][]u8 = .{&chunk};
        const n = r.interface.readVec(&data) catch break;
        if (n > 0) {
            const keep = drop_skipped_lines(&ctx.skip_lines, chunk[0..n]);
            io.writeAll(out, keep) catch break;
        }
    }
    ctx.done.store(true, .release);
}

/// The part of `bytes` that follows the first `skip.*` newlines, counting the
/// lines it consumes down. Bytes of a skipped line that ends in a later chunk
/// are dropped too: the count goes down only at the newline.
pub fn drop_skipped_lines(skip: *usize, bytes: []const u8) []const u8 {
    var rest = bytes;
    while (skip.* > 0) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse return rest[rest.len..];
        rest = rest[nl + 1 ..];
        skip.* -= 1;
    }
    return rest;
}

/// The `path` argument of an `index_workspace` call, or null for any other
/// line. Owned by the caller.
pub fn index_workspace_path(gpa: std.mem.Allocator, line: []const u8) ?[]u8 {
    // Most lines are other calls; parse only the ones that can match.
    if (std.mem.indexOf(u8, line, "index_workspace") == null) return null;
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, line, .{}) catch return null;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const method = obj.get("method") orelse return null;
    if (method != .string or !std.mem.eql(u8, method.string, "tools/call")) return null;
    const params = obj.get("params") orelse return null;
    if (params != .object) return null;
    const name = params.object.get("name") orelse return null;
    if (name != .string or !std.mem.eql(u8, name.string, "index_workspace")) return null;
    const args = params.object.get("arguments") orelse return null;
    if (args != .object) return null;
    const path = args.object.get("path") orelse return null;
    if (path != .string or path.string.len == 0) return null;
    return gpa.dupe(u8, path.string) catch null;
}

/// True for the client's `initialize` request.
pub fn is_initialize(gpa: std.mem.Allocator, line: []const u8) bool {
    if (std.mem.indexOf(u8, line, "\"initialize\"") == null) return false;
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, line, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const method = parsed.value.object.get("method") orelse return false;
    return method == .string and std.mem.eql(u8, method.string, "initialize");
}

/// `line` with the `path` argument of its `index_workspace` call set to
/// `root`, newline-terminated. The new daemon serves `root` exactly, and it
/// refuses any path that is not its own tree, a subfolder included.
pub fn with_path(gpa: std.mem.Allocator, line: []const u8, root: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, line, .{});
    defer parsed.deinit();
    const args = &parsed.value.object.getPtr("params").?.object.getPtr("arguments").?.object;
    try args.put(parsed.arena.allocator(), "path", .{ .string = root });
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try std.json.Stringify.value(parsed.value, .{}, &out.writer);
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

fn same_tree(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, std.mem.trimEnd(u8, a, "/"), std.mem.trimEnd(u8, b, "/"));
}

/// The JSON-RPC id of a request line, or null for a notification and for a
/// line that does not parse.
pub fn request_id(gpa: std.mem.Allocator, line: []const u8) ?i64 {
    if (std.mem.indexOf(u8, line, "\"id\"") == null) return null;
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, line, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const id = parsed.value.object.get("id") orelse return null;
    return switch (id) {
        .integer => |n| n,
        else => null,
    };
}

/// The answer to an `index_workspace` call this session cannot move for: the
/// daemon of `wanted` did not open, so the session stays on `served`.
///
/// Forwarding the call to `served` instead made that daemon answer "no project
/// marker" about a folder that has one. It cannot see the reason: a session
/// whose executable was replaced by an install or removed by a cache cleanup
/// cannot start any daemon at all. Name the two folders here, where the relay
/// knows both.
pub fn move_failed_answer(gpa: std.mem.Allocator, id: i64, served: []const u8, wanted: []const u8) ![]u8 {
    var msg: std.Io.Writer.Allocating = .init(gpa);
    defer msg.deinit();
    try msg.writer.print(
        "Refused: this session serves {s}. It could not start the daemon of {s}, so it did not move, and this call did not reach that project. Start a session in that folder; if it fails too, check that the codeindex executable of this session still exists.",
        .{ served, wanted },
    );
    return error_answer(gpa, id, msg.written());
}

/// The answer to a call that arrived after the daemon of `root` went away and no
/// new one could be started.
pub fn daemon_gone_answer(gpa: std.mem.Allocator, id: i64, root: []const u8) ![]u8 {
    var msg: std.Io.Writer.Allocating = .init(gpa);
    defer msg.deinit();
    try msg.writer.print(
        "Refused: the daemon of {s} went away and a new one did not start, so this call did not reach the index. Check that the codeindex executable of this session still exists, then reconnect the MCP server.",
        .{root},
    );
    return error_answer(gpa, id, msg.written());
}

fn error_answer(gpa: std.mem.Allocator, id: i64, text: []const u8) ![]u8 {
    const Content = struct { type: []const u8 = "text", text: []const u8 };
    const Result = struct { content: []const Content, isError: bool = true };
    const Answer = struct { jsonrpc: []const u8 = "2.0", id: i64, result: Result };

    const content = [1]Content{.{ .text = text }};
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try std.json.Stringify.value(Answer{ .id = id, .result = .{ .content = &content } }, .{}, &out.writer);
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

/// Tell the client why its call did not move. False only when the write to the
/// client failed, which ends the session.
/// Answer a call this session could not forward, on the client's own stream.
/// `send` writes to the daemon, so the answer goes to stdout, where the client
/// reads. A notification gets no answer, and a failure to build one is not a
/// reason to end the session.
fn answer_move_failed(gpa: std.mem.Allocator, line: []const u8, served: []const u8, wanted: []const u8) bool {
    const id = request_id(gpa, line) orelse return true; // a notification: nothing to answer
    const answer = move_failed_answer(gpa, id, served, wanted) catch return true;
    defer gpa.free(answer);
    io.writeAll(io.stdout(), answer) catch return false;
    return true;
}

/// Answer a call that cannot reach any daemon, on the client's own stream. A
/// notification gets no answer. False only when the write to the client failed.
fn answer_daemon_gone(gpa: std.mem.Allocator, line: []const u8, root: []const u8) bool {
    const id = request_id(gpa, line) orelse return true;
    const answer = daemon_gone_answer(gpa, id, root) catch return true;
    defer gpa.free(answer);
    io.writeAll(io.stdout(), answer) catch return false;
    return true;
}

fn send(stream: net.Stream, bytes: []const u8) bool {
    var buf: [4096]u8 = undefined;
    var w = stream.writer(io.io(), &buf);
    w.interface.writeAll(bytes) catch return false;
    w.interface.flush() catch return false;
    return true;
}

/// End one daemon connection: ask the daemon to finish, let it answer what is
/// still in flight, then close. The pump thread is joined before this returns,
/// so two daemons never write to stdout at once.
fn retire(pump: *Pump, thread: std.Thread, drain_ms: u64) void {
    // Ending the send side asks the daemon to close its half, which is what
    // unblocks the reader. A peer that does not close would leave this process
    // alive forever, so the drain is bounded and the read side ends here.
    pump.stream.shutdown(io.io(), .send) catch {};
    var waited_ms: u64 = 0;
    while (!pump.done.load(.acquire) and waited_ms < drain_ms) {
        io.sleep(10 * std.time.ns_per_ms);
        waited_ms += 10;
    }
    if (!pump.done.load(.acquire)) pump.stream.shutdown(io.io(), .recv) catch {};
    thread.join();
    pump.stream.close(io.io());
}

/// Give a session whose daemon went away a connection to the daemon of `root`,
/// started when none runs. The daemon retires itself when its executable is
/// replaced by an install, so this is how a running session picks up the new
/// build: the new daemon gets the handshake the client sent the first one, and
/// the answer to the replayed `initialize` is dropped because the client has
/// one already.
///
/// False means no daemon could be reached and the session is over. The error
/// means the pump thread could not start; `pump` is gone then.
fn reconnect(
    gpa: std.mem.Allocator,
    sw: Switcher,
    root: []const u8,
    init_line: ?[]const u8,
    pump: *Pump,
    thread: *std.Thread,
) !bool {
    const replay = init_line orelse return false;
    const next = sw.connect(sw.ctx, root) orelse return false;
    const handshake = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n";
    if (!send(next, replay) or !send(next, handshake)) {
        next.close(io.io());
        return false;
    }
    retire(pump, thread.*, 0);
    pump.* = .{ .stream = next, .skip_lines = 1 };
    thread.* = std.Thread.spawn(.{}, pump_out, .{pump}) catch {
        next.close(io.io());
        gpa.destroy(pump);
        return error.ThreadSpawnFailed;
    };
    std.debug.print("codeindex: session reconnected to the daemon of {s}\n", .{root});
    return true;
}

/// Relay until either side closes. Returns when the session is over.
///
/// `root` is the project the daemon behind `stream` serves. With a `switcher`,
/// an `index_workspace` call for another project moves the session to that
/// project's daemon, and a daemon that went away is replaced by a new one for
/// the same project; without one, every line goes to `stream` unchanged.
pub fn run(gpa: std.mem.Allocator, stream: net.Stream, root: []const u8, switcher: ?Switcher) !void {
    var pump = try gpa.create(Pump);
    pump.* = .{ .stream = stream };
    var thread = std.Thread.spawn(.{}, pump_out, .{pump}) catch |err| {
        gpa.destroy(pump);
        return err;
    };

    var current_root = try gpa.dupe(u8, root);
    defer gpa.free(current_root);
    // The client's `initialize`, kept to replay to the next daemon.
    var init_line: ?[]u8 = null;
    defer if (init_line) |l| gpa.free(l);

    var chunk: [1024 * 1024]u8 = undefined;
    var carry = std.ArrayList(u8).empty;
    defer carry.deinit(gpa);

    session: while (true) {
        const n = io.readSome(io.stdin(), &chunk) catch break;
        if (n == 0) break; // the MCP client closed our stdin: the session ended
        try carry.appendSlice(gpa, chunk[0..n]);

        var start: usize = 0;
        lines: while (std.mem.indexOfScalarPos(u8, carry.items, start, '\n')) |nl| {
            const raw = carry.items[start .. nl + 1];
            start = nl + 1;
            const line = std.mem.trimEnd(u8, raw, "\r\n");

            if (init_line == null and is_initialize(gpa, line)) {
                init_line = gpa.dupe(u8, raw) catch null;
            }

            // The daemon closed its side while the client stayed: it retired
            // because its executable was replaced, or it was stopped.
            if (pump.done.load(.acquire)) {
                const sw = switcher orelse break :session;
                if (!(try reconnect(gpa, sw, current_root, init_line, pump, &thread))) {
                    if (!answer_daemon_gone(gpa, line, current_root)) break :session;
                    continue :lines;
                }
            }

            if (switcher) |sw| move: {
                const path = index_workspace_path(gpa, line) orelse break :move;
                defer gpa.free(path);
                const new_root = sw.resolve(sw.ctx, gpa, path) orelse break :move;
                if (same_tree(new_root, current_root)) {
                    gpa.free(new_root);
                    break :move;
                }
                const replay = init_line orelse {
                    // Without the client's handshake the new daemon cannot
                    // answer as this session. Say so instead of letting the old
                    // daemon refuse a tree it does not serve.
                    const ok = answer_move_failed(gpa, line, current_root, new_root);
                    gpa.free(new_root);
                    if (!ok) break :session;
                    continue :lines;
                };
                const rewritten = with_path(gpa, line, new_root) catch {
                    gpa.free(new_root);
                    break :move;
                };
                defer gpa.free(rewritten);
                const next = sw.connect(sw.ctx, new_root) orelse {
                    // The daemon of the target did not open: none runs and this
                    // process could not start one. Its own executable may have
                    // been replaced by an install or removed by a cleanup.
                    // Answer for that here; `current_root` refuses for itself
                    // with a reason it cannot know.
                    const ok = answer_move_failed(gpa, line, current_root, new_root);
                    gpa.free(new_root);
                    if (!ok) break :session;
                    continue :lines;
                };

                // The new daemon gets the same handshake the client sent the
                // first one. Its answer to `initialize` is dropped: the client
                // has one already. The daemon answers in order, so that answer
                // is the first line it writes.
                const handshake = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n";
                if (!send(next, replay) or !send(next, handshake)) {
                    next.close(io.io());
                    const ok = answer_move_failed(gpa, line, current_root, new_root);
                    gpa.free(new_root);
                    if (!ok) break :session;
                    continue :lines;
                }

                retire(pump, thread, switch_drain_ms);
                pump.* = .{ .stream = next, .skip_lines = 1 };
                thread = std.Thread.spawn(.{}, pump_out, .{pump}) catch {
                    next.close(io.io());
                    gpa.free(new_root);
                    gpa.destroy(pump);
                    return error.ThreadSpawnFailed;
                };
                gpa.free(current_root);
                current_root = new_root;
                // A relative path in a later call means the folder the session
                // now works in, as it does in the daemon.
                io.changeCurDir(current_root) catch {};
                std.debug.print("codeindex: session moved to the daemon of {s}\n", .{current_root});

                if (!send(pump.stream, rewritten)) break :session;
                continue;
            }

            if (!send(pump.stream, raw)) {
                // The write found the daemon gone before the reader did.
                const sw = switcher orelse break :session;
                if (!(try reconnect(gpa, sw, current_root, init_line, pump, &thread))) {
                    if (!answer_daemon_gone(gpa, line, current_root)) break :session;
                    continue :lines;
                }
                if (!send(pump.stream, raw)) break :session;
            }
        }
        // Keep the part of a line that has not ended yet.
        const rest = carry.items[start..];
        std.mem.copyForwards(u8, carry.items[0..rest.len], rest);
        carry.items.len = rest.len;
    }

    // Tell the daemon this client is finished so it can retire the connection,
    // then wait a bounded moment for anything still in flight the other way.
    retire(pump, thread, 2000);
    gpa.destroy(pump);
}

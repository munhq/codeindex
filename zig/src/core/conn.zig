//! The MCP loop's endpoint: this process's stdio, or one socket connection.
//!
//! The loop was written straight against stdin and stdout. The daemon serves
//! the same protocol to several clients at once, each on its own socket, so the
//! endpoint had to become a value the loop is handed rather than a global it
//! reaches for. Both variants expose the only two operations the loop performs:
//! read whatever has arrived, and write one complete message.

const std = @import("std");
const io = @import("io.zig");

pub const Stream = std.Io.net.Stream;

/// One socket endpoint.
///
/// Self-referential: `r` and `w` borrow the buffers stored beside them, so this
/// is always heap-allocated and never moved or copied after `create`.
pub const Socket = struct {
    stream: Stream,
    read_buf: [64 * 1024]u8 = undefined,
    write_buf: [64 * 1024]u8 = undefined,
    r: Stream.Reader = undefined,
    w: Stream.Writer = undefined,

    pub fn create(gpa: std.mem.Allocator, stream: Stream) !*Socket {
        const self = try gpa.create(Socket);
        self.* = .{ .stream = stream };
        self.r = stream.reader(io.io(), &self.read_buf);
        self.w = stream.writer(io.io(), &self.write_buf);
        return self;
    }

    pub fn destroy(self: *Socket, gpa: std.mem.Allocator) void {
        self.stream.close(io.io());
        gpa.destroy(self);
    }
};

pub const Conn = union(enum) {
    stdio,
    socket: *Socket,

    /// Read whatever has arrived, up to `buffer.len` bytes. Returns 0 at end of
    /// stream, which is how the MCP loop learns its client has gone.
    ///
    /// This must not be `readSliceShort`: that one blocks until the buffer is
    /// full or the stream ends, and the loop's buffer is a megabyte. A
    /// request/response protocol needs the bytes that are here now.
    pub fn readSome(self: Conn, buffer: []u8) !usize {
        switch (self) {
            .stdio => return io.readSome(io.stdin(), buffer),
            .socket => |s| {
                const r = &s.r.interface;
                // Anything the Reader already holds is the answer; `readVec`
                // goes to the socket and would leave it stranded.
                const held = r.buffered();
                if (held.len > 0) {
                    const n = @min(buffer.len, held.len);
                    @memcpy(buffer[0..n], held[0..n]);
                    r.toss(n);
                    return n;
                }
                var data: [1][]u8 = .{buffer};
                return r.readVec(&data) catch |err| switch (err) {
                    error.EndOfStream => 0,
                    else => err,
                };
            },
        }
    }

    /// Write one complete message, then flush it. A half-flushed frame is a
    /// half-written JSON-RPC message: the client cannot parse it and has no way
    /// to resynchronise, so every write here is all-or-nothing.
    pub fn writeAll(self: Conn, bytes: []const u8) !void {
        switch (self) {
            .stdio => try io.writeAll(io.stdout(), bytes),
            .socket => |s| {
                try s.w.interface.writeAll(bytes);
                try s.w.interface.flush();
            },
        }
    }
};

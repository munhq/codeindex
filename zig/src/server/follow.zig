//! The folder a session works in, as a hook of the client reports it.
//!
//! An MCP server starts in one folder and never learns that the agent changed
//! folders: a `find_symbol` call carries a name and no folder, and the client
//! sends its roots once, at startup. The PreToolUse hook of the plugin
//! (plugin/hooks/follow-folder.sh) runs before every tool call and knows the
//! folder of the call. It writes that folder to
//!
//!     $XDG_RUNTIME_DIR/codeindex-follow/<pid>
//!
//! for the client process and for the processes above the hook, and the relay
//! reads the file of the nearest ancestor it shares with the hook. The first
//! tool call after a change of folder then moves the session, as an
//! `index_workspace` call for that folder would.
//!
//! The process tree is read from /proc, so this exists on Linux only. Elsewhere
//! no folder is ever reported and the session keeps the folder it started in.

const std = @import("std");
const builtin = @import("builtin");
const io = @import("../core/io.zig");

/// The most processes above the relay that are looked at. The client is one to
/// three levels up: directly, or through `npm exec` and a shell.
const max_depth: usize = 8;
const max_folder_bytes: usize = 4096;

/// The parent pid in the text of /proc/<pid>/stat. The name of the process sits
/// in parentheses and may hold spaces and parentheses, so the fields are counted
/// from the last closing one: `state ppid ...`.
pub fn parent_of_stat(stat: []const u8) ?i64 {
    const close = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return null;
    var it = std.mem.tokenizeScalar(u8, stat[close + 1 ..], ' ');
    _ = it.next() orelse return null; // state
    const ppid = it.next() orelse return null;
    return std.fmt.parseInt(i64, std.mem.trimEnd(u8, ppid, "\n"), 10) catch null;
}

/// The first line of a follow file, trimmed. Null for an empty file and for a
/// path that is not absolute.
pub fn folder_of_file(text: []const u8) ?[]const u8 {
    const line = std.mem.trim(u8, text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len], " \t\r");
    if (line.len == 0 or line[0] != '/') return null;
    return line;
}

fn parent_pid(gpa: std.mem.Allocator, pid: i64) ?i64 {
    var buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "/proc/{d}/stat", .{pid}) catch return null;
    const stat = io.readFileAlloc(gpa, path, 4096) catch return null;
    defer gpa.free(stat);
    return parent_of_stat(stat);
}

/// The folder that the hook of the nearest ancestor client reported, or null.
/// Owned by the caller.
pub fn client_folder(gpa: std.mem.Allocator) ?[]u8 {
    if (comptime builtin.os.tag != .linux) return null;
    const base = io.getEnv(gpa, "XDG_RUNTIME_DIR") orelse return null;
    defer gpa.free(base);
    if (base.len == 0) return null;

    var pid: i64 = @intCast(std.os.linux.getppid());
    var depth: usize = 0;
    while (pid > 1 and depth < max_depth) : (depth += 1) {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/codeindex-follow/{d}", .{ base, pid }) catch return null;
        if (io.readFileAlloc(gpa, path, max_folder_bytes)) |text| {
            defer gpa.free(text);
            if (folder_of_file(text)) |folder| return gpa.dupe(u8, folder) catch null;
        } else |_| {}
        pid = parent_pid(gpa, pid) orelse return null;
    }
    return null;
}

const std = @import("std");
const builtin = @import("builtin");
const io = @import("io.zig");

pub const Config = struct {
    workspace_root: []const u8 = ".",
    project_id: []const u8 = "default",
    /// Where the index snapshot lives. Always inside `workspace_root` — see
    /// `resolve_snapshot_path`. Never a bare relative name: that made the file a
    /// property of the launch directory rather than of the indexed project, so
    /// `--workspace B` run from A read A's snapshot and wrote B's index into it.
    snapshot_path: []const u8 = ".codeindex.json",
    max_file_size: u64 = 10 * 1024 * 1024,
    max_cache_bytes: usize = 50 * 1024 * 1024,
    respect_gitignore: bool = true,
    skip_hidden: bool = true,
    mcp_mode: bool = false,
    /// True when the caller named the workspace (`--workspace`, or a
    /// CODEINDEX_WORKSPACE that is not empty and not "."). A default workspace
    /// is only a guess about the launch directory, and in --mcp mode the client
    /// chooses that directory, not the user — so main() is allowed to prefer a
    /// better candidate over the default, and never over an explicit one.
    workspace_explicit: bool = false,
    show_version: bool = false,
    show_help: bool = false,
    /// Idle window (seconds) after which the MCP server evicts its in-RAM
    /// trigram/word postings back to the OS; the next query rebuilds them. 0
    /// disables idle eviction. Env: CODEINDEX_IDLE_EVICT_SECS, flag:
    /// --idle-evict-secs. Only used in --mcp mode.
    idle_evict_secs: i64 = 300,

    pub fn from_args(allocator: std.mem.Allocator, args_vec: std.process.Args) !Config {
        var config = Config{};

        // Check env vars first
        // An empty or "." value carries no information: it repeats the
        // default. Treated as set, it suppressed the launch-directory
        // resolution in main() and left the server indexing whatever directory
        // the client happened to spawn it in.
        if (io.getEnv(allocator, "CODEINDEX_WORKSPACE")) |val| {
            if (val.len > 0 and !std.mem.eql(u8, val, ".")) {
                config.workspace_root = val;
                config.workspace_explicit = true;
            } else {
                allocator.free(val);
            }
        }

        if (io.getEnv(allocator, "CODEINDEX_PROJECT_ID")) |val| {
            config.project_id = val;
        }

        if (io.getEnv(allocator, "CODEINDEX_IDLE_EVICT_SECS")) |val| {
            defer allocator.free(val);
            if (std.fmt.parseInt(i64, std.mem.trim(u8, val, " \t\r\n"), 10)) |secs| {
                config.idle_evict_secs = secs;
            } else |_| {}
        }

        // CLI args override env vars. On POSIX these slices point into the
        // process argv and live for the whole program, so storing them in
        // `config` without duping is safe.
        //
        // Windows has no argv array to point into: the OS hands over one UTF-16
        // command line, so std refuses `init` there and requires an allocator to
        // split it. The slices are then owned by the iterator, and every value
        // kept in `config` must outlive it — see the dupes below.
        var args = if (comptime builtin.os.tag == .windows)
            try std.process.Args.Iterator.initAllocator(args_vec, allocator)
        else
            std.process.Args.Iterator.init(args_vec);
        defer args.deinit();
        _ = args.next(); // skip program name

        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "-V")) {
                config.show_version = true;
            } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                config.show_help = true;
            } else if (std.mem.eql(u8, arg, "--mcp")) {
                config.mcp_mode = true;
            } else if (std.mem.eql(u8, arg, "--workspace")) {
                if (args.next()) |val| {
                    config.workspace_root = val;
                    config.workspace_explicit = true;
                }
            } else if (std.mem.eql(u8, arg, "--project-id")) {
                if (args.next()) |val| {
                    config.project_id = val;
                }
            } else if (std.mem.eql(u8, arg, "--idle-evict-secs")) {
                if (args.next()) |val| {
                    if (std.fmt.parseInt(i64, val, 10)) |secs| {
                        config.idle_evict_secs = secs;
                    } else |_| {}
                }
            }
        }

        config.snapshot_path = try resolve_snapshot_path(allocator, config.workspace_root);

        return config;
    }
};

pub const SNAPSHOT_NAME = ".codeindex.json";

/// Join the snapshot name onto the workspace so the file belongs to the project
/// it describes. `workspace_root` of "." keeps the bare name: main() chdirs into
/// the project root in that case, so the plain relative path already lands
/// there, and keeping it short keeps the common case readable in logs.
pub fn resolve_snapshot_path(allocator: std.mem.Allocator, workspace_root: []const u8) ![]const u8 {
    if (std.mem.eql(u8, workspace_root, ".")) return SNAPSHOT_NAME;
    return std.fs.path.join(allocator, &.{ workspace_root, SNAPSHOT_NAME });
}

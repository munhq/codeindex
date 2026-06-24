const std = @import("std");
const io = @import("io.zig");

pub const Config = struct {
    workspace_root: []const u8 = ".",
    project_id: []const u8 = "default",
    snapshot_path: []const u8 = ".codeindex.json",
    max_file_size: u64 = 10 * 1024 * 1024,
    max_cache_bytes: usize = 50 * 1024 * 1024,
    respect_gitignore: bool = true,
    skip_hidden: bool = true,
    mcp_mode: bool = false,
    show_version: bool = false,
    show_help: bool = false,

    pub fn from_args(allocator: std.mem.Allocator, args_vec: std.process.Args) !Config {
        var config = Config{};

        // Check env vars first
        if (io.getEnv(allocator, "CODEINDEX_WORKSPACE")) |val| {
            config.workspace_root = val;
        }

        if (io.getEnv(allocator, "CODEINDEX_PROJECT_ID")) |val| {
            config.project_id = val;
        }

        // CLI args override env vars. On POSIX these slices point into the
        // process argv and live for the whole program, so storing them in
        // `config` without duping is safe.
        var args = std.process.Args.Iterator.init(args_vec);
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
                }
            } else if (std.mem.eql(u8, arg, "--project-id")) {
                if (args.next()) |val| {
                    config.project_id = val;
                }
            }
        }

        return config;
    }
};

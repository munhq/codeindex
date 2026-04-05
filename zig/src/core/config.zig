const std = @import("std");

pub const Config = struct {
    workspace_root: []const u8 = ".",
    project_id: []const u8 = "default",
    snapshot_path: []const u8 = ".codeindex.json",
    max_file_size: u64 = 10 * 1024 * 1024,
    max_cache_bytes: usize = 50 * 1024 * 1024,
    respect_gitignore: bool = true,
    skip_hidden: bool = true,
    mcp_mode: bool = false,

    pub fn from_args(allocator: std.mem.Allocator) !Config {
        var config = Config{};

        // Check env vars first
        if (std.process.getEnvVarOwned(allocator, "CODEINDEX_WORKSPACE")) |val| {
            config.workspace_root = val;
        } else |_| {}

        if (std.process.getEnvVarOwned(allocator, "CODEINDEX_PROJECT_ID")) |val| {
            config.project_id = val;
        } else |_| {}

        // CLI args override env vars
        var args = try std.process.argsWithAllocator(allocator);
        defer args.deinit();
        _ = args.next(); // skip program name

        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--mcp")) {
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

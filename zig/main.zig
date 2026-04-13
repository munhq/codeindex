const std = @import("std");
const models = @import("src/core/models.zig");
const treesitter = @import("src/parser/treesitter.zig");
const explorer = @import("src/index/explorer.zig");
const server = @import("src/server/http.zig");
const watcher = @import("src/watcher.zig");
const storage = @import("src/storage/snapshot.zig");
const filter = @import("src/core/filter.zig");
const config = @import("src/core/config.zig");

const WatchCtx = struct {
    allocator: std.mem.Allocator,
    exp: *explorer.Explorer,
    parser: *treesitter.Parser,
    f: *filter.Filter,
    max_file_size: u64,
    workspace_root: []const u8,
    running: *bool,
};

fn watch_callback(c: *WatchCtx, e: watcher.Watcher.Event) !void {
    if (c.f.should_ignore(e.path)) return;

    const language = models.Language.from_path(e.path);
    if (language == .unknown) return;

    switch (e.op) {
        .create, .modify => {
            const file = std.fs.cwd().openFile(e.path, .{}) catch return;
            defer file.close();
            const content = file.readToEndAlloc(c.allocator, c.max_file_size) catch return;
            defer c.allocator.free(content);

            const outline = c.parser.parse_file(e.path, language) catch |err| {
                if (err == error.UnsupportedLanguage) {
                    _ = c.exp.add_file(models.FileOutline{
                        .path = c.allocator.dupe(u8, e.path) catch return,
                        .language = language,
                        .line_count = std.mem.count(u8, content, "\n") + 1,
                        .byte_size = content.len,
                        .symbols = &[_]models.Symbol{},
                        .imports = &[_][]const u8{},
                    }, content) catch return;
                    return;
                }
                return err;
            };
            std.debug.print("Reindexed: {s}\n", .{e.path});
            _ = try c.exp.add_file(outline, content);
        },
        .delete => {
            std.debug.print("Removed: {s}\n", .{e.path});
            try c.exp.remove_file(e.path);
        },
    }
}

fn watch_loop(ctx: *WatchCtx) void {
    var w = watcher.Watcher.init(ctx.allocator) catch return;
    defer w.deinit();
    w.add_recursive(ctx.workspace_root) catch return;
    std.debug.print("Watcher active on {s}\n", .{ctx.workspace_root});

    while (ctx.running.*) {
        w.poll_events(ctx, watch_callback) catch {};
        std.Thread.sleep(200 * std.time.ns_per_ms);
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cfg = config.Config.from_args(allocator) catch config.Config{};

    var parser = try treesitter.Parser.init(allocator);
    defer parser.deinit();

    var f = filter.Filter.init(allocator);
    defer f.deinit();
    try f.load_gitignore(cfg.workspace_root);

    const snapshot_path = cfg.snapshot_path;
    var exp: explorer.Explorer = undefined;
    var loaded_from_snapshot = false;

    if (std.fs.cwd().openFile(snapshot_path, .{})) |file| {
        file.close();
        std.debug.print("Loading from snapshot...\n", .{});
        if (storage.Snapshot.load(allocator, snapshot_path)) |loaded| {
            exp = loaded;
            loaded_from_snapshot = true;
        } else |err| {
            std.debug.print("Snapshot invalid ({s}), re-indexing fresh\n", .{@errorName(err)});
            exp = explorer.Explorer.init(allocator);
        }
    } else |_| {
        exp = explorer.Explorer.init(allocator);
    }
    defer exp.deinit();

    // Background indexing for MCP mode, blocking for watcher mode
    if (!loaded_from_snapshot) {
        if (cfg.mcp_mode) {
            const IndexCtx = struct {
                allocator: std.mem.Allocator,
                exp: *explorer.Explorer,
                parser: *treesitter.Parser,
                f: *filter.Filter,
                workspace_root: []const u8,
                max_file_size: u64,
                snapshot_path: []const u8,
            };
            var idx_ctx = IndexCtx{
                .allocator = allocator,
                .exp = &exp,
                .parser = &parser,
                .f = &f,
                .workspace_root = cfg.workspace_root,
                .max_file_size = cfg.max_file_size,
                .snapshot_path = snapshot_path,
            };
            const bg_thread = try std.Thread.spawn(.{}, struct {
                fn run(ctx: *IndexCtx) void {
                    std.debug.print("Indexing {s}...\n", .{ctx.workspace_root});
                    index_directory(ctx.allocator, ctx.exp, ctx.parser, ctx.f, ctx.workspace_root, ctx.max_file_size) catch |err| {
                        std.debug.print("Indexing failed: {}\n", .{err});
                        ctx.exp.mark_indexing_complete();
                        return;
                    };
                    ctx.exp.mark_indexing_complete();
                    std.debug.print("Indexed {d} files, {d} symbols\n", .{ ctx.exp.file_count(), ctx.exp.symbol_count() });
                    storage.Snapshot.save(ctx.exp, ctx.snapshot_path) catch {};
                }
            }.run, .{&idx_ctx});
            defer bg_thread.join();
        } else {
            std.debug.print("Indexing {s}...\n", .{cfg.workspace_root});
            try index_directory(allocator, &exp, &parser, &f, cfg.workspace_root, cfg.max_file_size);
            exp.mark_indexing_complete();
            std.debug.print("Indexed {d} files, {d} symbols\n", .{ exp.file_count(), exp.symbol_count() });
            try storage.Snapshot.save(&exp, snapshot_path);
        }
    } else {
        exp.mark_indexing_complete();
    }

    // Start watcher (background thread for MCP, foreground for standalone)
    var watch_running = true;
    var watch_ctx = WatchCtx{
        .allocator = allocator,
        .exp = &exp,
        .parser = &parser,
        .f = &f,
        .max_file_size = cfg.max_file_size,
        .workspace_root = cfg.workspace_root,
        .running = &watch_running,
    };

    if (cfg.mcp_mode) {
        const watch_thread = try std.Thread.spawn(.{}, watch_loop, .{&watch_ctx});
        defer {
            watch_running = false;
            watch_thread.join();
        }

        var srv = server.Server.init(allocator, &exp);
        srv.with_parser(&parser, &f);
        try srv.run_mcp();
    } else {
        std.debug.print("\nWatcher active. Press Ctrl+C to stop.\n", .{});
        watch_loop(&watch_ctx);
    }
}

fn index_directory(allocator: std.mem.Allocator, exp: *explorer.Explorer, parser: *treesitter.Parser, f: *filter.Filter, path: []const u8, max_file_size: u64) !void {
    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch |err| {
        std.debug.print("Cannot open directory {s}: {}\n", .{ path, err });
        return;
    };
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (walker.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (f.should_ignore(entry.path)) continue;

        const language = models.Language.from_path(entry.path);
        if (language == .unknown) continue;

        const file = entry.dir.openFile(entry.basename, .{}) catch continue;
        defer file.close();
        const content = file.readToEndAlloc(allocator, max_file_size) catch continue;
        defer allocator.free(content);

        const full_path = std.fs.path.join(allocator, &.{ path, entry.path }) catch continue;
        defer allocator.free(full_path);

        const outline = parser.parse_file(full_path, language) catch |err| {
            if (err == error.UnsupportedLanguage) {
                _ = try exp.add_file(models.FileOutline{
                    .path = try allocator.dupe(u8, entry.path),
                    .language = language,
                    .line_count = std.mem.count(u8, content, "\n") + 1,
                    .byte_size = content.len,
                    .symbols = &[_]models.Symbol{},
                    .imports = &[_][]const u8{},
                }, content);
                continue;
            }
            continue;
        };

        _ = try exp.add_file(outline, content);
    }
}

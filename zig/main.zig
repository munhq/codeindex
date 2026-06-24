const std = @import("std");
const models = @import("src/core/models.zig");
const treesitter = @import("src/parser/treesitter.zig");
const explorer = @import("src/index/explorer.zig");
const server = @import("src/server/http.zig");
const watcher = @import("src/watcher.zig");
const storage = @import("src/storage/snapshot.zig");
const filter = @import("src/core/filter.zig");
const config = @import("src/core/config.zig");
const scanner = @import("src/index/scanner.zig");
const io = @import("src/core/io.zig");

const VERSION = "0.1.0";

const project_markers = [_][]const u8{
    ".git",         "build.zig",      "package.json", "go.mod",
    "Cargo.toml",   "pyproject.toml", "deno.json",    "pom.xml",
    ".hg",          ".svn",           ".codeindex.json",
};

/// Walk up from `start_abs` looking for a project marker. Returns the owned
/// absolute path of the enclosing project root, or null if none is found.
fn find_project_root(allocator: std.mem.Allocator, start_abs: []const u8) ?[]u8 {
    var cur: []const u8 = start_abs;
    while (true) {
        for (project_markers) |m| {
            const p = std.fs.path.join(allocator, &.{ cur, m }) catch continue;
            defer allocator.free(p);
            io.cwd().access(io.io(), p, .{}) catch continue;
            return allocator.dupe(u8, cur) catch null;
        }
        const parent = std.fs.path.dirname(cur) orelse break;
        if (parent.len == 0 or std.mem.eql(u8, parent, cur)) break;
        cur = parent;
    }
    return null;
}

fn print_help() !void {
    try io.writeAll(io.stdout(),
        \\codeindex — fast tree-sitter code index with an MCP server
        \\
        \\USAGE:
        \\  codeindex [OPTIONS]
        \\
        \\OPTIONS:
        \\  --mcp                 Run as an MCP server over stdio
        \\  --workspace <DIR>     Directory to index (default: enclosing project root)
        \\  --project-id <ID>     Project identifier
        \\  -v, --version         Print version and exit
        \\  -h, --help            Print this help and exit
        \\
        \\ENVIRONMENT:
        \\  CODEINDEX_WORKSPACE   Same as --workspace
        \\  CODEINDEX_PROJECT_ID  Same as --project-id
        \\
    );
}

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
            const content = io.readFileAlloc(c.allocator, e.path, c.max_file_size) catch return;
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
        io.sleep(200 * std.time.ns_per_ms);
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    io.init(allocator);
    defer io.deinit();

    const cfg = config.Config.from_args(allocator, init.args) catch config.Config{};

    // Handle --help / --version before doing any work. These previously fell
    // through to the default path and silently started a full index + watcher.
    if (cfg.show_help) {
        try print_help();
        return;
    }
    if (cfg.show_version) {
        try io.writeAll(io.stdout(), "codeindex " ++ VERSION ++ "\n");
        return;
    }

    // Resolve the effective workspace and guard against scanning a whole home
    // directory. When the default workspace ("." = cwd) is used, locate the
    // enclosing project root and chdir into it so all paths stay project-relative.
    if (std.mem.eql(u8, cfg.workspace_root, ".")) {
        if (io.realpathAlloc(allocator, ".")) |abs| {
            defer allocator.free(abs);
            if (find_project_root(allocator, abs)) |proj| {
                defer allocator.free(proj);
                io.changeCurDir(proj) catch {};
            }
        } else |_| {}
    }

    var refused_reason: ?[]const u8 = null;
    if (io.realpathAlloc(allocator, cfg.workspace_root)) |eff| {
        defer allocator.free(eff);
        const home = io.getEnv(allocator, "HOME");
        defer if (home) |h| allocator.free(h);
        if (eff.len <= 1) {
            refused_reason = "workspace resolves to the filesystem root";
        } else if (home != null and std.mem.eql(u8, eff, home.?)) {
            refused_reason = "workspace resolves to your home directory";
        }
    } else |_| {}

    var parser = try treesitter.Parser.init(allocator);
    defer parser.deinit();

    var f = filter.Filter.init(allocator);
    defer f.deinit();
    try f.load_gitignore(cfg.workspace_root);

    const snapshot_path = cfg.snapshot_path;
    var exp: explorer.Explorer = undefined;
    var loaded_from_snapshot = false;

    if (refused_reason != null) {
        exp = explorer.Explorer.init(allocator);
    } else if (io.cwd().openFile(io.io(), snapshot_path, .{})) |file| {
        file.close(io.io());
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
    if (refused_reason) |reason| {
        var buf: [320]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Indexing refused: {s}. This MCP server scans the directory it is launched in — pass --workspace <dir> or set CODEINDEX_WORKSPACE to a specific project.", .{reason}) catch reason;
        exp.set_status(msg);
        std.debug.print("{s}\n", .{msg});
        exp.mark_indexing_complete();
    } else if (!loaded_from_snapshot) {
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
                    const res = scanner.index_tree(ctx.allocator, ctx.exp, ctx.parser, ctx.f, ctx.workspace_root, ctx.max_file_size, .{}) catch |err| {
                        std.debug.print("Indexing failed: {}\n", .{err});
                        ctx.exp.mark_indexing_complete();
                        return;
                    };
                    if (res.capped) ctx.exp.set_status("Workspace too large — indexing stopped at the safety cap; results are partial. Narrow the scope with --workspace or CODEINDEX_WORKSPACE.");
                    ctx.exp.mark_indexing_complete();
                    std.debug.print("Indexed {d} files, {d} symbols\n", .{ ctx.exp.file_count(), ctx.exp.symbol_count() });
                    storage.Snapshot.save(ctx.exp, ctx.snapshot_path) catch {};
                }
            }.run, .{&idx_ctx});
            defer bg_thread.join();
        } else {
            std.debug.print("Indexing {s}...\n", .{cfg.workspace_root});
            const res = try scanner.index_tree(allocator, &exp, &parser, &f, cfg.workspace_root, cfg.max_file_size, .{});
            if (res.capped) exp.set_status("Workspace too large — indexing stopped at the safety cap; results are partial. Narrow the scope with --workspace or CODEINDEX_WORKSPACE.");
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

    // Never start a recursive filesystem watch on a refused (home/root) workspace.
    const start_watcher = refused_reason == null;

    if (cfg.mcp_mode) {
        var watch_thread: ?std.Thread = null;
        if (start_watcher) watch_thread = try std.Thread.spawn(.{}, watch_loop, .{&watch_ctx});
        defer {
            watch_running = false;
            if (watch_thread) |t| t.join();
        }

        var srv = server.Server.init(allocator, &exp);
        srv.with_parser(&parser, &f);
        try srv.run_mcp();
    } else if (start_watcher) {
        std.debug.print("\nWatcher active. Press Ctrl+C to stop.\n", .{});
        watch_loop(&watch_ctx);
    }
}

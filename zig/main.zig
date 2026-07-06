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

// NOTE: `.codeindex.json` (the snapshot, see config.zig) is deliberately NOT a
// marker. It used to be, which self-poisoned: running codeindex in a directory
// wrote `.codeindex.json` there, and that same file then made the directory a
// permanent "project root" — so a stray run in e.g. ~/code turned the whole
// multi-project parent into one 50k-file index on every subsequent launch.
// Project roots are defined only by real project files; use --workspace or
// CODEINDEX_WORKSPACE to index a marker-less directory explicitly.
const project_markers = [_][]const u8{
    ".git",       "build.zig",      "package.json", "go.mod",
    "Cargo.toml", "pyproject.toml", "deno.json",    "pom.xml",
    ".hg",        ".svn",
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
        // Modifies/deletes leave stale postings behind (postings are add-only
        // file-id sets); sweep them once enough accumulate. Runs on this
        // thread — the sole mutator — so it can't race add_file.
        if (ctx.exp.needs_compaction()) {
            ctx.exp.compact() catch |err| {
                std.debug.print("codeindex: compaction failed: {}\n", .{err});
            };
        }
        io.sleep(200 * std.time.ns_per_ms);
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    // Long-running server: use the thread-safe general allocator, not
    // DebugAllocator (per-allocation metadata + safety checks are wrong for
    // production; tests still run under std.testing.allocator's leak checks).
    const allocator = std.heap.smp_allocator;

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
    //
    // If no project marker exists anywhere up the tree, the launch dir is not a
    // single project — it is a marker-less parent (e.g. ~/code holding dozens of
    // repos). Indexing it pulls every project into one index (tens of thousands
    // of files) and makes import resolution quadratic. Flag it for refusal below
    // rather than silently scanning the lot.
    var no_project_root = false;
    if (std.mem.eql(u8, cfg.workspace_root, ".")) {
        if (io.realpathAlloc(allocator, ".")) |abs| {
            defer allocator.free(abs);
            if (find_project_root(allocator, abs)) |proj| {
                defer allocator.free(proj);
                io.changeCurDir(proj) catch {};
            } else {
                no_project_root = true;
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
        } else if (no_project_root) {
            refused_reason = "no enclosing project found (no .git/build.zig/package.json/Cargo.toml/go.mod/… marker walking up from the launch directory)";
        }
    } else |_| {}

    var parser = try treesitter.Parser.init(allocator);
    defer parser.deinit();

    var f = filter.Filter.init(allocator);
    defer f.deinit();
    try f.load_gitignore(cfg.workspace_root);

    const snapshot_path = cfg.snapshot_path;

    // The live Explorer the MCP server serves from. It starts EMPTY with
    // indexing=true; a background worker fills it (snapshot load or full scan).
    // This is what keeps the MCP handshake instant: the expensive snapshot
    // reprime (one disk read per file to rebuild the search indexes) and the
    // cold index both run off the `initialize`/`tools/list` path. Query tools
    // already block on is_indexing() until the data is ready (see http.zig).
    var exp = explorer.Explorer.init(allocator);
    defer exp.deinit();

    // Cheap check: is there a snapshot to prefer over a full scan? (The heavy
    // load itself happens later, on the background worker.)
    var snapshot_exists = false;
    if (refused_reason == null) {
        if (io.cwd().openFile(io.io(), snapshot_path, .{})) |file| {
            file.close(io.io());
            snapshot_exists = true;
        } else |_| {}
    }

    // Refused (home/root) workspace: never scan, just surface why via `status`.
    if (refused_reason) |reason| {
        var buf: [320]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Indexing refused: {s}. This MCP server scans the directory it is launched in — pass --workspace <dir> or set CODEINDEX_WORKSPACE to a specific project.", .{reason}) catch reason;
        exp.set_status(msg);
        std.debug.print("{s}\n", .{msg});
        exp.mark_indexing_complete();
    }

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

    const BuildCtx = struct {
        allocator: std.mem.Allocator,
        exp: *explorer.Explorer,
        parser: *treesitter.Parser,
        f: *filter.Filter,
        workspace_root: []const u8,
        max_file_size: u64,
        snapshot_path: []const u8,
        snapshot_exists: bool,
        watch_ctx: *WatchCtx,
        start_watcher: bool,

        // Fill `exp` in place: prefer the snapshot, fall back to a full scan.
        fn build(ctx: *@This()) void {
            var loaded_ok = false;
            if (ctx.snapshot_exists) {
                std.debug.print("Loading from snapshot...\n", .{});
                if (storage.Snapshot.load_into(ctx.exp, ctx.allocator, ctx.snapshot_path)) |_| {
                    loaded_ok = true;
                } else |err| {
                    std.debug.print("Snapshot load failed ({s}), indexing fresh\n", .{@errorName(err)});
                }
            }
            // Only scan if the snapshot didn't load AND nothing was partially
            // populated — guards against duplicate entries on a mid-load error.
            if (!loaded_ok and ctx.exp.file_count() == 0) {
                std.debug.print("Indexing {s}...\n", .{ctx.workspace_root});
                if (scanner.index_tree(ctx.allocator, ctx.exp, ctx.parser, ctx.f, ctx.workspace_root, ctx.max_file_size, .{})) |res| {
                    if (res.capped) ctx.exp.set_status("Workspace too large — indexing stopped at the safety cap; results are partial. Narrow the scope with --workspace or CODEINDEX_WORKSPACE.");
                    storage.Snapshot.save(ctx.exp, ctx.snapshot_path) catch {};
                    std.debug.print("Indexed {d} files, {d} symbols\n", .{ ctx.exp.file_count(), ctx.exp.symbol_count() });
                } else |err| {
                    std.debug.print("Indexing failed: {}\n", .{err});
                }
            }
            ctx.exp.mark_indexing_complete();
        }

        // Background worker: build the index, THEN take over file-watching.
        // Watching starts only after the build so the lock-free snapshot restore
        // never races a concurrent watcher write into the same Explorer.
        fn build_then_watch(ctx: *@This()) void {
            ctx.build();
            if (ctx.start_watcher) watch_loop(ctx.watch_ctx);
        }
    };

    var build_ctx = BuildCtx{
        .allocator = allocator,
        .exp = &exp,
        .parser = &parser,
        .f = &f,
        .workspace_root = cfg.workspace_root,
        .max_file_size = cfg.max_file_size,
        .snapshot_path = snapshot_path,
        .snapshot_exists = snapshot_exists,
        .watch_ctx = &watch_ctx,
        .start_watcher = refused_reason == null,
    };

    if (cfg.mcp_mode) {
        // Build + watch on a background thread so `initialize` is answered NOW,
        // not after a cold index / snapshot reprime (which can exceed the MCP
        // client's connection timeout on large or cold-cache workspaces).
        var worker: ?std.Thread = null;
        if (refused_reason == null) worker = try std.Thread.spawn(.{}, BuildCtx.build_then_watch, .{&build_ctx});
        defer {
            watch_running = false;
            if (worker) |t| t.join();
        }

        var srv = server.Server.init(allocator, &exp);
        srv.with_parser(&parser, &f);
        try srv.run_mcp();
    } else {
        // Standalone: build synchronously, then watch in the foreground.
        if (refused_reason == null) {
            build_ctx.build();
            std.debug.print("\nWatcher active. Press Ctrl+C to stop.\n", .{});
            watch_loop(&watch_ctx);
        }
    }
}

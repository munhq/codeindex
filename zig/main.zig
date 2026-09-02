const std = @import("std");
const builtin = @import("builtin");
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
const ipc = @import("src/server/ipc.zig");
const proxy = @import("src/server/proxy.zig");
const daemon_mod = @import("src/server/daemon.zig");

// 0.2.0 changes two things a user can observe: the snapshot carries an identity
// and is rejected when it does not match (format 3), and every line number the
// server reports is 1-based, where it used to be one line low.
// Injected by build.zig, which takes it from the release tag. See the comment
// there: a literal here drifted from the tag it shipped under.
const VERSION = @import("build_options").version;

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

/// Why a candidate directory is not a workspace, or null when it is usable.
/// Both the startup path and the client-supplied candidates run through this,
/// so a directory refused at startup can never be adopted by another route.
/// `is_guess` marks a directory nobody named explicitly — only a guess gets the
/// repo-parent check, which exists to catch a stray marker in a folder of many
/// repositories rather than to override a deliberate `--workspace`.
fn workspace_refusal(allocator: std.mem.Allocator, eff_abs: []const u8, is_guess: bool) ?[]const u8 {
    if (eff_abs.len <= 1) return "workspace resolves to the filesystem root";
    const home = io.getEnv(allocator, "HOME");
    defer if (home) |h| allocator.free(h);
    if (home != null and std.mem.eql(u8, eff_abs, home.?)) return "workspace resolves to your home directory";
    if (is_guess and looks_like_repo_parent(eff_abs)) {
        // A marker exists here, but the directory is not itself a git repo and
        // holds several independent repos — a parent/workspace folder (e.g. a
        // stray package.json in a directory of checkouts). Indexing it would
        // pull in every project at once.
        return "the launch directory is not a git repo but contains several independent git repositories — it looks like a parent/workspace folder, not a single project";
    }
    return null;
}

/// Resolve one workspace candidate to a project root the guards allow, or null.
/// Returns an owned absolute path. A null answer is not an error: the caller
/// tries the next candidate, and only the last one produces a refusal message.
pub fn usable_project_root(allocator: std.mem.Allocator, candidate: []const u8) ?[]u8 {
    if (candidate.len == 0) return null;
    const abs = io.realpathAlloc(allocator, candidate) catch return null;
    defer allocator.free(abs);
    const proj = find_project_root(allocator, abs) orelse return null;
    if (workspace_refusal(allocator, proj, true) != null) {
        allocator.free(proj);
        return null;
    }
    return proj;
}

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

// A directory holding this many independent git repositories is treated as a
// parent/workspace folder (e.g. ~/code) rather than a single project, and is
// refused. A directory that is ITSELF a git repo counts as one repo and stops
// the descent there, so monorepos and repos-with-submodules are exempt — their
// .git is at the root, never below it. Override with --workspace / env.
const repo_parent_threshold: u32 = 3;
const repo_scan_max_depth: u8 = 4;
const repo_scan_max_dirs: u32 = 20_000; // backstop against pathological trees

/// Count independent git repos at or below `dir`, stopping at `limit`. A dir
/// that contains a `.git` is one repo and is not descended into (its nested
/// submodules must not inflate the count). Prunes dependency/build noise.
fn count_repos(dir: *io.Dir, depth: u8, count: *u32, visited: *u32) void {
    if (count.* >= repo_parent_threshold) return;
    visited.* += 1;
    if (visited.* > repo_scan_max_dirs) return;

    // Is this directory itself a repo? If so, count it and stop here.
    if (dir.openDir(io.io(), ".git", .{})) |g| {
        var gg = g;
        gg.close(io.io());
        count.* += 1;
        return;
    } else |_| {}

    if (depth >= repo_scan_max_depth) return;

    const noise = [_][]const u8{ "node_modules", "vendor", "target", "dist", "build" };
    var it = dir.iterate();
    while (true) {
        const maybe = it.next(io.io()) catch return;
        const entry = maybe orelse return;
        if (entry.kind != .directory) continue;
        const name = entry.name;
        if (name.len == 0 or name[0] == '.') continue; // hidden (incl. .git, handled above)
        var skip = false;
        for (noise) |n| {
            if (std.mem.eql(u8, name, n)) {
                skip = true;
                break;
            }
        }
        if (skip) continue;

        var sub = dir.openDir(io.io(), name, .{ .iterate = true }) catch continue;
        defer sub.close(io.io());
        count_repos(&sub, depth + 1, count, visited);
        if (count.* >= repo_parent_threshold) return;
    }
}

/// True if `root` is not itself a git repo but contains `repo_parent_threshold`+
/// independent repos beneath it — i.e. it looks like a parent/workspace folder.
fn looks_like_repo_parent(root: []const u8) bool {
    var d = io.cwd().openDir(io.io(), root, .{ .iterate = true }) catch return false;
    defer d.close(io.io());
    var count: u32 = 0;
    var visited: u32 = 0;
    count_repos(&d, 0, &count, &visited);
    return count >= repo_parent_threshold;
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
        \\  --idle-evict-secs <N> Evict in-RAM postings to the OS after N seconds
        \\                        idle; next query rebuilds them (default 300, 0=off)
        \\  --no-daemon           Keep the index in this process instead of sharing
        \\                        the workspace daemon (default: share it)
        \\  --daemon              Run as the workspace daemon (started for you)
        \\  --daemon-idle-secs <N> Exit the daemon after N seconds with no client
        \\                        (default 900, 0=never)
        \\  -v, --version         Print version and exit
        \\  -h, --help            Print this help and exit
        \\
        \\ENVIRONMENT:
        \\  CODEINDEX_WORKSPACE        Same as --workspace
        \\  CODEINDEX_PROJECT_ID       Same as --project-id
        \\  CODEINDEX_IDLE_EVICT_SECS  Same as --idle-evict-secs
        \\  CODEINDEX_NO_DAEMON        Set to 1 for --no-daemon
        \\  CODEINDEX_DAEMON_IDLE_SECS Same as --daemon-idle-secs
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
    /// Guards the parser. In the daemon the same parser is reachable from every
    /// connection's `index_workspace`; tree-sitter parsers hold mutable scratch
    /// state and cannot be entered twice.
    parser_lock: ?*io.Mutex = null,
};

fn watch_callback(c: *WatchCtx, e: watcher.Event) !void {
    if (c.f.should_ignore(e.path)) return;

    const language = models.Language.from_path(e.path);
    if (language == .unknown) return;

    switch (e.op) {
        .create, .modify => {
            const content = io.readFileAlloc(c.allocator, e.path, c.max_file_size) catch return;
            defer c.allocator.free(content);

            if (c.parser_lock) |m| m.lock();
            defer if (c.parser_lock) |m| m.unlock();

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

const IdleCtx = struct {
    exp: *explorer.Explorer,
    running: *bool,
    idle_ms: i64,
    /// Sessions currently attached, when this server is the workspace daemon.
    ///
    /// Eviction is skipped while any of them is connected. On the single-process
    /// server the reprime that follows an eviction cost the one session that
    /// asked; in the daemon it runs under `rebuild_mutex` and stalls EVERY
    /// attached session at once — so the same trade is now several times worse,
    /// and it is taken on behalf of people who are still working.
    ///
    /// Null in the single-process server, where the old behaviour is right.
    live: ?*std.atomic.Value(i64) = null,
};

/// Return the in-RAM trigram/word postings to the OS once the MCP server has
/// gone `idle_ms` without a tool call; the next query transparently rebuilds
/// them (see explorer.evict / reprime_all). This is what stops an idle server
/// from pinning its peak RSS in swap for days — smp_allocator never unmaps the
/// sub-64KB posting slabs on a plain free, so a page-backed arena that we drop
/// wholesale is the only thing that actually returns the pages. Own thread;
/// no-op when idle_ms <= 0.
fn idle_loop(ctx: *IdleCtx) void {
    // Short poll cadence so shutdown (running=false) is observed promptly; the
    // real threshold is idle_ms, measured from the last recorded activity.
    const poll_ns: u64 = 5 * std.time.ns_per_s;
    while (ctx.running.*) {
        io.sleep(poll_ns);
        if (!ctx.running.*) break;
        if (ctx.idle_ms <= 0) continue;
        if (ctx.exp.is_indexing() or ctx.exp.is_evicted()) continue;
        // Somebody is attached. Their next query would pay for this.
        if (ctx.live) |l| if (l.load(.acquire) > 0) continue;
        const idle = io.milliTimestamp() - ctx.exp.last_activity_ms.load(.acquire);
        if (idle >= ctx.idle_ms) ctx.exp.evict();
    }
}

/// Absolute path to this binary, resolved from argv[0].
///
/// Must be called before anything chdirs. The daemon is spawned later, from the
/// project root, and a relative argv[0] such as `./codeindex` would no longer
/// name this binary from there. A bare name is left alone on purpose: `spawn`
/// resolves one through PATH, which is exactly what a PATH install wants.
fn resolve_self_exe(allocator: std.mem.Allocator, args_vec: std.process.Args) ?[]u8 {
    var args = if (comptime builtin.os.tag == .windows)
        (std.process.Args.Iterator.initAllocator(args_vec, allocator) catch return null)
    else
        std.process.Args.Iterator.init(args_vec);
    defer args.deinit();
    const a0 = args.next() orelse return null;
    if (a0.len == 0) return null;
    if (std.mem.indexOfAny(u8, a0, "/\\") == null) return allocator.dupe(u8, a0) catch null;
    if (io.realpathAlloc(allocator, a0)) |abs| {
        defer allocator.free(abs);
        return allocator.dupe(u8, abs) catch null;
    } else |_| {
        return allocator.dupe(u8, a0) catch null;
    }
}

/// Start the workspace's daemon and leave it running.
///
/// Detached deliberately: its stdio is /dev/null because the client's stdio is
/// a live JSON-RPC channel that must not carry another process's output, and
/// its own process group means a Ctrl+C aimed at the session that happened to
/// start it does not take the index away from every other session.
fn spawn_daemon(
    allocator: std.mem.Allocator,
    environ: std.process.Environ,
    exe: []const u8,
    workspace_abs: []const u8,
    sock_path: []const u8,
    log_path: []const u8,
    cfg: config.Config,
) !void {
    var idle_buf: [24]u8 = undefined;
    const idle = try std.fmt.bufPrint(&idle_buf, "{d}", .{cfg.daemon_idle_secs});
    var evict_buf: [24]u8 = undefined;
    const evict = try std.fmt.bufPrint(&evict_buf, "{d}", .{cfg.idle_evict_secs});

    // Every setting travels as an argument, including the socket path. The
    // daemon must not re-derive any of this: it would be deriving it from a
    // different process's view, and a socket path derived differently is a
    // daemon nobody can reach.
    const argv = [_][]const u8{
        exe,                  "--daemon",
        "--workspace",        workspace_abs,
        "--socket",           sock_path,
        "--daemon-idle-secs", idle,
        "--idle-evict-secs",  evict,
    };

    // Hand the child this process's environment explicitly. `spawn` with no
    // `environ_map` does NOT inherit it — the daemon started with an empty
    // environment, so XDG_RUNTIME_DIR was unset and it chose a different
    // runtime directory from the client that had just started it. Nothing
    // failed loudly: the client waited out its timeout and quietly indexed the
    // workspace itself, which is the whole cost the daemon exists to remove.
    var env_map = environ.createMap(allocator) catch null;
    defer if (env_map) |*m| m.deinit();

    // The daemon's diagnostics go to a file of its own. They cannot go to this
    // client's stderr: that belongs to one MCP session, and the daemon outlives
    // it and serves others. A log that cannot be opened is not worth failing
    // the launch over — the daemon still runs, silently.
    const log: ?io.File = io.cwd().createFile(io.io(), log_path, .{}) catch null;
    defer if (log) |lf| lf.close(io.io());

    var child = try std.process.spawn(io.io(), .{
        .argv = &argv,
        .environ_map = if (env_map) |*m| m else null,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = if (log) |lf| .{ .file = lf } else .ignore,
        .pgid = if (comptime builtin.os.tag == .windows) null else 0,
    });
    _ = &child;
}

/// Serve this session from the workspace's daemon instead of indexing here.
///
/// Returns true when the whole session was served over the socket. False means
/// the caller must go on and be a full server itself — the fallback is never
/// worse than the behaviour that predates the daemon, so every failure here is
/// a silent one.
fn attach_to_daemon(
    allocator: std.mem.Allocator,
    environ: std.process.Environ,
    exe: ?[]const u8,
    workspace_abs: []const u8,
    cfg: config.Config,
) bool {
    const p = ipc.paths(allocator, workspace_abs, VERSION) catch return false;
    defer p.deinit(allocator);

    if (ipc.connect(p.sock)) |stream| {
        proxy.run(stream) catch {};
        return true;
    }

    const exe_path = exe orelse return false;
    spawn_daemon(allocator, environ, exe_path, workspace_abs, p.sock, p.log, cfg) catch return false;

    // The daemon binds its socket before it parses anything, so this waits for
    // a process to start, never for a tree to be indexed.
    var waited_ms: u64 = 0;
    while (waited_ms < 10 * std.time.ms_per_s) {
        io.sleep(50 * std.time.ns_per_ms);
        waited_ms += 50;
        if (ipc.connect(p.sock)) |stream| {
            proxy.run(stream) catch {};
            return true;
        }
    }
    return false;
}

pub fn main(init: std.process.Init.Minimal) !void {
    // Long-running server: use the thread-safe general allocator, not
    // DebugAllocator (per-allocation metadata + safety checks are wrong for
    // production; tests still run under std.testing.allocator's leak checks).
    const allocator = std.heap.smp_allocator;

    io.init(allocator);
    defer io.deinit();

    // Before any chdir below: a relative argv[0] stops naming this binary once
    // the process moves to the project root.
    const self_exe = resolve_self_exe(allocator, init.args);
    defer if (self_exe) |e| allocator.free(e);

    var cfg = config.Config.from_args(allocator, init.args) catch config.Config{};

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
    //
    // The launch directory is the LAST candidate, not the first. In --mcp mode
    // the client picks it, and the client's choice is regularly not the user's
    // project: Claude Code launches a plugin's MCP server from the plugin's own
    // directory and a user-scope server from the config directory. Both walk up
    // to something — a plugin's marketplace clone, or nothing at all — so this
    // server indexed the wrong tree and said nothing, or indexed no tree and
    // refused. Ask the client where the project is before guessing.
    var no_project_root = false;
    var workspace_source: []const u8 = if (cfg.workspace_explicit)
        "--workspace / CODEINDEX_WORKSPACE"
    else
        "the launch directory";
    if (!cfg.workspace_explicit) {
        var resolved = false;

        // Claude Code sets CLAUDE_PROJECT_DIR in every MCP server it spawns, to
        // the project root, precisely because the working directory does not
        // answer that question. Honour it in --mcp mode only: a person running
        // the CLI in a directory means THAT directory, whatever a parent agent
        // exported.
        if (cfg.mcp_mode) {
            if (io.getEnv(allocator, "CLAUDE_PROJECT_DIR")) |hint| {
                defer allocator.free(hint);
                if (usable_project_root(allocator, hint)) |proj| {
                    defer allocator.free(proj);
                    if (io.changeCurDir(proj)) |_| {
                        resolved = true;
                        workspace_source = "CLAUDE_PROJECT_DIR";
                    } else |_| {}
                }
            }
        }

        if (!resolved) {
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
    }

    var refused_reason: ?[]const u8 = null;
    if (io.realpathAlloc(allocator, cfg.workspace_root)) |eff| {
        defer allocator.free(eff);
        refused_reason = workspace_refusal(allocator, eff, std.mem.eql(u8, cfg.workspace_root, "."));
        if (refused_reason == null and no_project_root) {
            refused_reason = "no enclosing project found (no .git/build.zig/package.json/Cargo.toml/go.mod/… marker walking up from the launch directory)";
        }
    } else |_| {}

    // The identity written into the snapshot and checked when one is loaded.
    // Resolved after the chdir above, so the default (".") case names the
    // project root rather than whatever directory the client happened to launch
    // from. Lives for the whole process; the snapshot code only borrows it.
    // Normalised to the key separator, so the absolute prefix of every path key
    // agrees with the joined remainder. Left mixed, a Windows root produced
    // `D:\\repo/src/a.zig` and the resolver's '/' comparisons matched only part
    // of the key.
    // realpath returns a sentinel-terminated slice, allocated one byte longer
    // than its length. Coercing that to []const u8 and freeing it releases one
    // byte less than was allocated, so the sentinel slice is freed with its own
    // type and a plain copy is what lives on.
    const workspace_abs: []u8 = blk: {
        if (io.realpathAlloc(allocator, cfg.workspace_root)) |abs| {
            defer allocator.free(abs);
            break :blk try allocator.dupe(u8, abs);
        } else |_| {
            break :blk try allocator.dupe(u8, cfg.workspace_root);
        }
    };
    defer allocator.free(workspace_abs);
    io.normalizeKey(workspace_abs);

    if (refused_reason == null) {
        std.debug.print("codeindex: workspace {s} (from {s})\n", .{ workspace_abs, workspace_source });
    }

    // Every path key in the index is `join(root, rel)`, so the root form decides
    // the key form: a "." root produced "./main.zig" and `--workspace /abs`
    // produced "/abs/main.zig" for the same file. Both launch modes share one
    // snapshot, so the file was stored twice and the reconcile pass matched
    // neither set. Scan, watch and filter from the canonical absolute root only.
    cfg.workspace_root = workspace_abs;

    // One index per workspace, not one per session. Eight agents on one
    // repository were eight parses of the same tree, eight file watchers and
    // eight writers of the same snapshot; they are now eight sockets onto one.
    // Tried before any of the expensive setup below, and skipped entirely when
    // this launch has nothing to serve.
    if (cfg.mcp_mode and !cfg.daemon_mode and cfg.use_daemon and ipc.supported and refused_reason == null) {
        if (attach_to_daemon(allocator, init.environ, self_exe, workspace_abs, cfg)) return;
        std.debug.print("codeindex: no daemon available, serving this session in-process\n", .{});
    }

    var parser = try treesitter.Parser.init(allocator);
    defer parser.deinit();

    // Shared by the watcher and by every `index_workspace` call. One parser,
    // one lock: tree-sitter keeps mutable scratch state across a parse.
    var parser_lock = io.Mutex{};

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
    var exp = try explorer.Explorer.init(allocator);
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
        .parser_lock = &parser_lock,
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
        workspace_abs: []const u8,
        watch_ctx: *WatchCtx,
        start_watcher: bool,

        // Fill `exp` in place: prefer the snapshot, fall back to a full scan.
        fn build(ctx: *@This()) void {
            var loaded_ok = false;
            if (ctx.snapshot_exists) {
                std.debug.print("Loading from snapshot...\n", .{});
                var stamps = storage.Stamps.init(ctx.allocator);
                defer stamps.deinit();
                if (storage.Snapshot.load_into(ctx.exp, ctx.allocator, ctx.snapshot_path, ctx.workspace_abs, &stamps)) |_| {
                    loaded_ok = true;
                    // A snapshot describes the workspace as it was when saved.
                    // The watcher covers changes from now on; this covers every
                    // change made while no server was running.
                    if (scanner.reconcile_tree(ctx.allocator, ctx.exp, ctx.parser, ctx.f, ctx.workspace_root, ctx.max_file_size, .{}, &stamps)) |res| {
                        if (res.added + res.changed + res.removed > 0) {
                            std.debug.print("Snapshot reconciled: +{d} new, {d} changed, -{d} gone, {d} unchanged\n", .{ res.added, res.changed, res.removed, res.unchanged });
                            storage.Snapshot.save(ctx.exp, ctx.snapshot_path, ctx.workspace_abs) catch {};
                        }
                    } else |err| {
                        std.debug.print("Reconcile failed ({s}); index reflects the snapshot, not the working tree\n", .{@errorName(err)});
                    }
                } else |err| {
                    // WorkspaceMismatch is the common one: a snapshot left by
                    // another project, or by this directory in a previous life.
                    // Say so plainly — silently serving it is the failure this
                    // check exists to prevent — then index for real below.
                    std.debug.print("Snapshot rejected ({s}), indexing fresh\n", .{@errorName(err)});
                }
            }
            // Only scan if the snapshot didn't load AND nothing was partially
            // populated — guards against duplicate entries on a mid-load error.
            if (!loaded_ok and ctx.exp.file_count() == 0) {
                std.debug.print("Indexing {s}...\n", .{ctx.workspace_root});
                if (scanner.index_tree(ctx.allocator, ctx.exp, ctx.parser, ctx.f, ctx.workspace_root, ctx.max_file_size, .{})) |res| {
                    if (res.capped) ctx.exp.set_status("Workspace too large — indexing stopped at the safety cap; results are partial. Narrow the scope with --workspace or CODEINDEX_WORKSPACE.");
                    storage.Snapshot.save(ctx.exp, ctx.snapshot_path, ctx.workspace_abs) catch {};
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
        .workspace_abs = workspace_abs,
        .watch_ctx = &watch_ctx,
        .start_watcher = refused_reason == null,
    };

    if (cfg.daemon_mode) {
        // The workspace daemon. Started by whichever client found no socket,
        // never by a person, and always with an explicit --workspace — which is
        // also why it never adopts a root from a client's `roots`: one session
        // must not be able to move the tree another session is reading.
        if (refused_reason != null or !ipc.supported) return;

        // No usable runtime directory means no daemon is possible on this
        // machine. Exit quietly rather than crash: the client that started us
        // falls back to serving in-process, which is the behaviour that
        // predates the daemon.
        const p = ipc.paths(allocator, workspace_abs, VERSION) catch |err| {
            std.debug.print("codeindex: no runtime directory for the daemon ({s}); sessions will index in-process\n", .{@errorName(err)});
            return;
        };
        defer p.deinit(allocator);

        // Bind BEFORE indexing. The client that started this process is already
        // waiting to connect, and the MCP handshake must be answered while the
        // tree is still being parsed — the same reason the single-process
        // server builds its index on a background thread.
        //
        // AddressInUse means a sibling daemon won the same race honestly. It
        // serves the workspace; there is nothing for this process to add.
        // The client that started this daemon already picked the path and is
        // waiting on it. Its choice wins over anything recomputed here.
        const sock_path = cfg.socket_path orelse p.sock;

        var listener = ipc.listen(sock_path) catch |err| switch (err) {
            error.AddressInUse => return,
            else => return err,
        };
        defer listener.deinit(io.io());

        const worker = try std.Thread.spawn(.{}, BuildCtx.build_then_watch, .{&build_ctx});

        // Declared before the idle monitor because the monitor reads its
        // connection count: postings are not evicted out from under an attached
        // session.
        var d = daemon_mod.Daemon{
            .gpa = allocator,
            .exp = &exp,
            .parser = &parser,
            .filter = &f,
            .parser_lock = &parser_lock,
            .workspace_abs = workspace_abs,
            .snapshot_path = snapshot_path,
            .sock_path = sock_path,
            .server = listener,
            .idle_exit_secs = cfg.daemon_idle_secs,
        };

        var idle_ctx = IdleCtx{
            .exp = &exp,
            .running = &watch_running,
            .idle_ms = cfg.idle_evict_secs * std.time.ms_per_s,
            .live = &d.live,
        };
        var idle_thread: ?std.Thread = null;
        if (cfg.idle_evict_secs > 0)
            idle_thread = try std.Thread.spawn(.{}, idle_loop, .{&idle_ctx});
        std.debug.print("codeindex: daemon for {s} listening on {s}\n", .{ workspace_abs, sock_path });

        try d.serve();

        watch_running = false;
        worker.join();
        if (idle_thread) |t| t.join();
        daemon_mod.save_on_exit(&d);
        return;
    }

    if (cfg.mcp_mode) {
        // Build + watch on a background thread so `initialize` is answered NOW,
        // not after a cold index / snapshot reprime (which can exceed the MCP
        // client's connection timeout on large or cold-cache workspaces).
        var worker: ?std.Thread = null;
        if (refused_reason == null) worker = try std.Thread.spawn(.{}, BuildCtx.build_then_watch, .{&build_ctx});

        // Idle-eviction monitor: reclaims the postings arena after inactivity.
        // Shares `watch_running` as its stop flag so it winds down with the worker.
        var idle_ctx = IdleCtx{
            .exp = &exp,
            .running = &watch_running,
            .idle_ms = cfg.idle_evict_secs * std.time.ms_per_s,
        };
        var idle_thread: ?std.Thread = null;
        if (refused_reason == null and cfg.idle_evict_secs > 0)
            idle_thread = try std.Thread.spawn(.{}, idle_loop, .{&idle_ctx});

        defer {
            watch_running = false;
            if (worker) |t| t.join();
            if (idle_thread) |t| t.join();
        }

        var srv = server.Server.init(allocator, &exp);
        srv.with_parser(&parser, &f);
        srv.with_parser_lock(&parser_lock);
        srv.with_workspace(workspace_abs, refused_reason, !cfg.workspace_explicit);

        // A refused launch directory used to end the story: no index, no
        // watcher, and every tool answering "No results" for the whole session.
        // A launch directory in the WRONG project was worse — every tool
        // answered confidently about a tree the user was not working in. The
        // client knows where the project is, MCP `roots` is how it says so, and
        // this is what turns that answer into the right index. Adoption
        // replaces a guessed root only (see Server.workspace_is_guess).
        const AdoptCtx = struct {
            allocator: std.mem.Allocator,
            cfg: *config.Config,
            exp: *explorer.Explorer,
            f: *filter.Filter,
            build_ctx: *BuildCtx,
            watch_ctx: *WatchCtx,
            worker: *?std.Thread,
            /// The watcher's stop flag, shared with main's shutdown path.
            running: *bool,

            /// Index and watch `path`, or return null when it fails the same
            /// guards the startup path applies. The returned root is owned for
            /// the rest of the process: the watcher, the snapshot path and
            /// `status` all keep it, and it is replaced at most once.
            fn adopt(ctx_any: *anyopaque, path: []const u8) ?[]const u8 {
                const ctx: *@This() = @ptrCast(@alignCast(ctx_any));
                const proj = usable_project_root(ctx.allocator, path) orelse return null;

                // Correcting a live index: stop the worker and take the index
                // apart only once the thread that writes to it has exited.
                // Joining also waits out a build still in progress, which is
                // why this runs during the handshake and never mid-query.
                if (ctx.worker.*) |t| {
                    ctx.running.* = false;
                    t.join();
                    ctx.worker.* = null;
                    ctx.running.* = true;
                    ctx.exp.deinit();
                    ctx.exp.* = explorer.Explorer.init(ctx.allocator) catch {
                        ctx.allocator.free(proj);
                        return null;
                    };
                }
                io.changeCurDir(proj) catch {
                    ctx.allocator.free(proj);
                    return null;
                };
                io.normalizeKey(proj);

                const snap = config.resolve_snapshot_path(ctx.allocator, proj) catch {
                    ctx.allocator.free(proj);
                    return null;
                };
                var snap_exists = false;
                if (io.cwd().openFile(io.io(), snap, .{})) |file| {
                    file.close(io.io());
                    snap_exists = true;
                } else |_| {}

                ctx.f.load_gitignore(proj) catch {};
                ctx.cfg.workspace_root = proj;
                ctx.build_ctx.workspace_root = proj;
                ctx.build_ctx.workspace_abs = proj;
                ctx.build_ctx.snapshot_path = snap;
                ctx.build_ctx.snapshot_exists = snap_exists;
                ctx.build_ctx.start_watcher = true;
                ctx.watch_ctx.workspace_root = proj;

                // Queries must wait for this build like they wait for the
                // startup one; the refusal path had already marked indexing
                // complete, so without this a query could answer from a
                // half-built index.
                ctx.exp.mark_indexing_started();
                ctx.worker.* = std.Thread.spawn(.{}, BuildCtx.build_then_watch, .{ctx.build_ctx}) catch {
                    ctx.exp.mark_indexing_complete();
                    return null;
                };
                // The caller says WHY the workspace moved: the roots handshake
                // and an explicit index_workspace call are different stories,
                // and `status` is where a user reads them.
                return proj;
            }
        };
        var adopt_ctx = AdoptCtx{
            .allocator = allocator,
            .cfg = &cfg,
            .exp = &exp,
            .f = &f,
            .build_ctx = &build_ctx,
            .watch_ctx = &watch_ctx,
            .worker = &worker,
            .running = &watch_running,
        };
        srv.with_adopt(AdoptCtx.adopt, &adopt_ctx);

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

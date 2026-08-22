const std = @import("std");
const models = @import("../core/models.zig");
const treesitter = @import("../parser/treesitter.zig");
const explorer = @import("./explorer.zig");
const filter = @import("../core/filter.zig");
const snapshot = @import("../storage/snapshot.zig");
const io = @import("../core/io.zig");

/// Hard safety backstops. With the project-root guard and directory pruning in
/// place a real project never reaches these — they exist to stop an accidental
/// scan of a giant tree (e.g. a home directory) from exhausting RAM.
pub const Caps = struct {
    max_files: usize = 100_000,
    max_bytes: u64 = 1024 * 1024 * 1024, // 1 GiB of source scanned
};

pub const Result = struct {
    files: usize = 0,
    bytes: u64 = 0,
    capped: bool = false,
    /// Reconcile counters. A cold index reports everything as `added`.
    added: usize = 0,
    changed: usize = 0,
    unchanged: usize = 0,
    removed: usize = 0,
};

/// State threaded through the walk. `stamps` non-null puts the walk in reconcile
/// mode: a file whose mtime and size still match the snapshot is left alone
/// instead of being re-parsed, and every path seen on disk is recorded so the
/// caller can tell which indexed files have gone away.
const Walk = struct {
    allocator: std.mem.Allocator,
    exp: *explorer.Explorer,
    parser: *treesitter.Parser,
    f: *const filter.Filter,
    root: []const u8,
    max_file_size: u64,
    caps: Caps,
    result: Result = .{},
    stamps: ?*const snapshot.Stamps = null,
    seen: ?*std.StringHashMap(void) = null,
};

/// Recursively index `root`, pruning ignored directories at the directory level
/// (so package caches like node_modules / go/pkg/mod are never descended into),
/// and stopping with `capped = true` once a cap is hit.
pub fn index_tree(
    allocator: std.mem.Allocator,
    exp: *explorer.Explorer,
    parser: *treesitter.Parser,
    f: *const filter.Filter,
    root: []const u8,
    max_file_size: u64,
    caps: Caps,
) !Result {
    var walk = Walk{
        .allocator = allocator,
        .exp = exp,
        .parser = parser,
        .f = f,
        .root = root,
        .max_file_size = max_file_size,
        .caps = caps,
    };
    try run(&walk);
    return walk.result;
}

/// Bring an index restored from a snapshot back in line with what is on disk.
///
/// The watcher only sees changes while the server runs, so everything edited
/// while it was down is invisible to it: without this pass a snapshot for the
/// right workspace still serves outlines for code as it looked at save time.
/// Re-parses the files whose mtime or size moved, indexes files that appeared,
/// drops files that vanished, and skips the rest — which is the majority, and
/// the reason this is cheaper than rescanning.
pub fn reconcile_tree(
    allocator: std.mem.Allocator,
    exp: *explorer.Explorer,
    parser: *treesitter.Parser,
    f: *const filter.Filter,
    root: []const u8,
    max_file_size: u64,
    caps: Caps,
    stamps: *const snapshot.Stamps,
) !Result {
    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var kit = seen.keyIterator();
        while (kit.next()) |k| allocator.free(k.*);
        seen.deinit();
    }

    var walk = Walk{
        .allocator = allocator,
        .exp = exp,
        .parser = parser,
        .f = f,
        .root = root,
        .max_file_size = max_file_size,
        .caps = caps,
        .stamps = stamps,
        .seen = &seen,
    };
    try run(&walk);

    // Anything the snapshot knew about that the walk did not reach is gone from
    // disk (deleted, renamed, or newly ignored). Collect first, then remove:
    // remove_file mutates the explorer, not `stamps`, so iteration stays valid,
    // but collecting keeps the intent obvious.
    var vanished = std.ArrayList([]const u8).empty;
    defer vanished.deinit(allocator);
    var it = stamps.map.iterator();
    while (it.next()) |entry| {
        if (seen.contains(entry.key_ptr.*)) continue;
        try vanished.append(allocator, entry.key_ptr.*);
    }
    for (vanished.items) |p| {
        exp.remove_file(p) catch continue;
        walk.result.removed += 1;
    }

    return walk.result;
}

fn run(walk: *Walk) !void {
    var root_dir = io.cwd().openDir(io.io(), walk.root, .{ .iterate = true }) catch |err| {
        std.debug.print("Cannot open directory {s}: {}\n", .{ walk.root, err });
        return;
    };
    defer root_dir.close(io.io());
    try walk_dir(walk, &root_dir, "");
}

fn walk_dir(walk: *Walk, dir: *io.Dir, rel_prefix: []const u8) !void {
    const allocator = walk.allocator;
    var it = dir.iterate();
    while (try it.next(io.io())) |entry| {
        if (walk.result.capped) return;

        const rel = if (rel_prefix.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try io.joinKey(allocator, &.{ rel_prefix, entry.name });
        defer allocator.free(rel);

        switch (entry.kind) {
            .directory => {
                if (walk.f.should_skip_dir(rel)) continue;
                var sub = dir.openDir(io.io(), entry.name, .{ .iterate = true }) catch continue;
                defer sub.close(io.io());
                try walk_dir(walk, &sub, rel);
            },
            .file => {
                if (walk.f.should_ignore(rel)) continue;
                const language = models.Language.from_path(rel);
                if (language == .unknown) continue;

                if (walk.result.files >= walk.caps.max_files or walk.result.bytes >= walk.caps.max_bytes) {
                    walk.result.capped = true;
                    return;
                }

                const full_path = io.joinKey(allocator, &.{ walk.root, rel }) catch continue;
                defer allocator.free(full_path);

                // Reconcile mode: an unchanged file is already in the index with
                // a correct outline, so skip the read and the parse entirely.
                if (walk.stamps) |stamps| {
                    if (walk.seen) |seen| {
                        if (!seen.contains(full_path)) {
                            // `seen` outlives this iteration's `full_path`, so it
                            // owns a copy; reconcile_tree frees them.
                            const owned = allocator.dupe(u8, full_path) catch continue;
                            seen.put(owned, {}) catch {
                                allocator.free(owned);
                                continue;
                            };
                        }
                    }
                    if (stamps.map.get(full_path)) |recorded| {
                        const current = io.stampFileFrom(dir.*, entry.name);
                        if (current != null and recorded.eql(current.?)) {
                            walk.result.unchanged += 1;
                            continue;
                        }
                        walk.result.changed += 1;
                    } else {
                        walk.result.added += 1;
                    }
                } else {
                    walk.result.added += 1;
                }

                const content = io.readFileFrom(dir.*, allocator, entry.name, walk.max_file_size) catch continue;
                defer allocator.free(content);

                const outline = walk.parser.parse_file(full_path, language) catch |err| {
                    if (err == error.UnsupportedLanguage) {
                        _ = walk.exp.add_file(.{
                            .path = allocator.dupe(u8, full_path) catch continue,
                            .language = language,
                            .line_count = std.mem.count(u8, content, "\n") + 1,
                            .byte_size = content.len,
                            .symbols = &[_]models.Symbol{},
                            .imports = &[_][]const u8{},
                        }, content) catch continue;
                        walk.result.files += 1;
                        walk.result.bytes += content.len;
                        continue;
                    }
                    continue;
                };
                _ = walk.exp.add_file(outline, content) catch continue;
                walk.result.files += 1;
                walk.result.bytes += content.len;
            },
            else => {},
        }
    }
}

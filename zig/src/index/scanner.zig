const std = @import("std");
const models = @import("../core/models.zig");
const treesitter = @import("../parser/treesitter.zig");
const explorer = @import("./explorer.zig");
const filter = @import("../core/filter.zig");
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
    var result = Result{};
    var root_dir = io.cwd().openDir(io.io(), root, .{ .iterate = true }) catch |err| {
        std.debug.print("Cannot open directory {s}: {}\n", .{ root, err });
        return result;
    };
    defer root_dir.close(io.io());
    try walk_dir(allocator, exp, parser, f, root, &root_dir, "", max_file_size, caps, &result);
    return result;
}

fn walk_dir(
    allocator: std.mem.Allocator,
    exp: *explorer.Explorer,
    parser: *treesitter.Parser,
    f: *const filter.Filter,
    root: []const u8,
    dir: *io.Dir,
    rel_prefix: []const u8,
    max_file_size: u64,
    caps: Caps,
    result: *Result,
) !void {
    var it = dir.iterate();
    while (try it.next(io.io())) |entry| {
        if (result.capped) return;

        const rel = if (rel_prefix.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fs.path.join(allocator, &.{ rel_prefix, entry.name });
        defer allocator.free(rel);

        switch (entry.kind) {
            .directory => {
                if (f.should_skip_dir(rel)) continue;
                var sub = dir.openDir(io.io(), entry.name, .{ .iterate = true }) catch continue;
                defer sub.close(io.io());
                try walk_dir(allocator, exp, parser, f, root, &sub, rel, max_file_size, caps, result);
            },
            .file => {
                if (f.should_ignore(rel)) continue;
                const language = models.Language.from_path(rel);
                if (language == .unknown) continue;

                if (result.files >= caps.max_files or result.bytes >= caps.max_bytes) {
                    result.capped = true;
                    return;
                }

                const content = io.readFileFrom(dir.*, allocator, entry.name, max_file_size) catch continue;
                defer allocator.free(content);

                const full_path = std.fs.path.join(allocator, &.{ root, rel }) catch continue;
                defer allocator.free(full_path);

                const outline = parser.parse_file(full_path, language) catch |err| {
                    if (err == error.UnsupportedLanguage) {
                        _ = exp.add_file(.{
                            .path = allocator.dupe(u8, full_path) catch continue,
                            .language = language,
                            .line_count = std.mem.count(u8, content, "\n") + 1,
                            .byte_size = content.len,
                            .symbols = &[_]models.Symbol{},
                            .imports = &[_][]const u8{},
                        }, content) catch continue;
                        result.files += 1;
                        result.bytes += content.len;
                        continue;
                    }
                    continue;
                };
                _ = exp.add_file(outline, content) catch continue;
                result.files += 1;
                result.bytes += content.len;
            },
            else => {},
        }
    }
}

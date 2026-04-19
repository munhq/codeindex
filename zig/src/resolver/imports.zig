const std = @import("std");
const models = @import("../core/models.zig");

/// Resolve an import string to actual file paths in the workspace.
/// Returns file paths that match, or empty if unresolved.
pub fn resolve(
    allocator: std.mem.Allocator,
    import_str: []const u8,
    language: models.Language,
    source_path: []const u8,
    known_files: []const []const u8,
) ![][]const u8 {
    return switch (language) {
        .rust => try resolve_rust(allocator, import_str, known_files),
        .go => try resolve_go(allocator, import_str, known_files),
        .typescript, .javascript => try resolve_ts(allocator, import_str, source_path, known_files),
        .python => try resolve_python(allocator, import_str, source_path, known_files),
        .c, .cpp => try resolve_c(allocator, import_str, source_path, known_files),
        else => &[_][]const u8{},
    };
}

// ── Rust ─────────────────────────────────────────────────────────────────────

fn resolve_rust(allocator: std.mem.Allocator, import_str: []const u8, known_files: []const []const u8) ![][]const u8 {
    // Skip std/core/alloc crates
    if (std.mem.startsWith(u8, import_str, "std::") or
        std.mem.startsWith(u8, import_str, "core::") or
        std.mem.startsWith(u8, import_str, "alloc::"))
        return &[_][]const u8{};

    // use crate::foo::bar -> src/foo/bar.rs or src/foo/bar/mod.rs
    var path_part = import_str;
    if (std.mem.startsWith(u8, path_part, "crate::")) {
        path_part = path_part[7..];
    } else if (std.mem.startsWith(u8, path_part, "super::")) {
        path_part = path_part[7..];
    }

    // Convert :: to /
    var results = std.ArrayList([]const u8){};
    var buf: [512]u8 = undefined;
    var pos: usize = 0;
    pos += copy_replacing(&buf, pos, path_part, "::", "/");

    // Try src/{path}.rs
    const as_file = try std.fmt.allocPrint(allocator, "src/{s}.rs", .{buf[0..pos]});
    defer allocator.free(as_file);
    for (known_files) |f| {
        if (std.mem.endsWith(u8, f, as_file)) {
            try results.append(allocator, f);
            return try results.toOwnedSlice(allocator);
        }
    }

    // Try src/{path}/mod.rs
    const as_mod = try std.fmt.allocPrint(allocator, "src/{s}/mod.rs", .{buf[0..pos]});
    defer allocator.free(as_mod);
    for (known_files) |f| {
        if (std.mem.endsWith(u8, f, as_mod)) {
            try results.append(allocator, f);
            return try results.toOwnedSlice(allocator);
        }
    }

    results.deinit(allocator);
    return &[_][]const u8{};
}

// ── TypeScript/JavaScript ────────────────────────────────────────────────────

fn resolve_ts(allocator: std.mem.Allocator, import_str: []const u8, source_path: []const u8, known_files: []const []const u8) ![][]const u8 {
    // Skip bare package specifiers (node_modules). Still handle path aliases
    // like `@/foo` and `~/foo` by falling through to the suffix-match pass.
    const is_relative = std.mem.startsWith(u8, import_str, ".");
    const is_alias = std.mem.startsWith(u8, import_str, "@/") or std.mem.startsWith(u8, import_str, "~/");
    if (!is_relative and !is_alias) return &[_][]const u8{};

    const source_dir = std.fs.path.dirname(source_path) orelse ".";
    const extensions = [_][]const u8{ "", ".ts", ".tsx", ".js", ".jsx", ".json", "/index.ts", "/index.tsx", "/index.js", "/index.js" };

    var results = std.ArrayList([]const u8){};

    // Build normalized candidates
    for (&extensions) |ext| {
        var candidate: []u8 = undefined;
        if (is_relative) {
            const joined = try std.fmt.allocPrint(allocator, "{s}/{s}{s}", .{ source_dir, import_str, ext });
            defer allocator.free(joined);
            candidate = try normalize_path(allocator, joined);
        } else {
            // Alias — strip the alias prefix, try matching anywhere in known_files
            const stripped = import_str[2..];
            candidate = try std.fmt.allocPrint(allocator, "/{s}{s}", .{ stripped, ext });
        }
        defer allocator.free(candidate);

        for (known_files) |f| {
            if (std.mem.endsWith(u8, f, candidate)) {
                try results.append(allocator, f);
                break;
            }
        }
        if (results.items.len > 0) break;
    }

    return try results.toOwnedSlice(allocator);
}

/// Collapse `./` and `foo/../` segments. Returns owned memory.
fn normalize_path(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var segments = std.ArrayList([]const u8){};
    defer segments.deinit(allocator);

    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (seg.len == 0) {
            // Preserve leading slash by appending empty segment only for the very first entry
            if (segments.items.len == 0) try segments.append(allocator, "");
            continue;
        }
        if (std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (segments.items.len > 0 and !std.mem.eql(u8, segments.items[segments.items.len - 1], "")) {
                _ = segments.pop();
            }
            continue;
        }
        try segments.append(allocator, seg);
    }

    // Re-join
    var total: usize = 0;
    for (segments.items, 0..) |s, i| {
        total += s.len;
        if (i > 0) total += 1;
    }
    var out = try allocator.alloc(u8, total);
    var pos: usize = 0;
    for (segments.items, 0..) |s, i| {
        if (i > 0) {
            out[pos] = '/';
            pos += 1;
        }
        @memcpy(out[pos .. pos + s.len], s);
        pos += s.len;
    }
    return out;
}

// ── Python ───────────────────────────────────────────────────────────────────

const python_stdlib = [_][]const u8{
    "os", "sys", "re", "json", "math", "datetime", "collections", "itertools",
    "functools", "typing", "pathlib", "subprocess", "io", "time", "hashlib",
    "logging", "unittest", "abc", "enum", "dataclasses", "asyncio", "socket",
    "http", "urllib", "xml", "csv", "sqlite3", "threading", "multiprocessing",
    "argparse", "copy", "string", "random", "struct", "operator", "inspect",
};

fn resolve_python(allocator: std.mem.Allocator, import_str: []const u8, source_path: []const u8, known_files: []const []const u8) ![][]const u8 {
    // Skip stdlib
    const top_level = blk: {
        if (std.mem.indexOf(u8, import_str, ".")) |dot| break :blk import_str[0..dot];
        break :blk import_str;
    };
    for (&python_stdlib) |s| {
        if (std.mem.eql(u8, top_level, s)) return &[_][]const u8{};
    }

    _ = source_path;
    var results = std.ArrayList([]const u8){};

    // Convert dots to slashes
    var buf: [512]u8 = undefined;
    var pos: usize = 0;
    pos += copy_replacing(&buf, pos, import_str, ".", "/");

    const as_file = try std.fmt.allocPrint(allocator, "{s}.py", .{buf[0..pos]});
    defer allocator.free(as_file);
    const as_init = try std.fmt.allocPrint(allocator, "{s}/__init__.py", .{buf[0..pos]});
    defer allocator.free(as_init);

    for (known_files) |f| {
        if (std.mem.endsWith(u8, f, as_file) or std.mem.endsWith(u8, f, as_init)) {
            try results.append(allocator, f);
        }
    }

    return try results.toOwnedSlice(allocator);
}

// ── Go ───────────────────────────────────────────────────────────────────────

fn resolve_go(allocator: std.mem.Allocator, import_str: []const u8, known_files: []const []const u8) ![][]const u8 {
    // Skip stdlib (no dots in path)
    if (std.mem.indexOf(u8, import_str, ".") == null) return &[_][]const u8{};

    // For module imports like "github.com/org/repo/pkg", match files in pkg/
    var results = std.ArrayList([]const u8){};
    if (std.mem.lastIndexOf(u8, import_str, "/")) |last_slash| {
        const pkg = import_str[last_slash + 1 ..];
        for (known_files) |f| {
            if (std.mem.indexOf(u8, f, pkg) != null and std.mem.endsWith(u8, f, ".go")) {
                try results.append(allocator, f);
            }
        }
    }

    return try results.toOwnedSlice(allocator);
}

// ── C/C++ ────────────────────────────────────────────────────────────────────

fn resolve_c(allocator: std.mem.Allocator, import_str: []const u8, source_path: []const u8, known_files: []const []const u8) ![][]const u8 {
    // Skip system includes (< >)
    if (std.mem.startsWith(u8, import_str, "<")) return &[_][]const u8{};

    // Strip quotes
    var path = import_str;
    if (path.len > 2 and path[0] == '"' and path[path.len - 1] == '"') {
        path = path[1 .. path.len - 1];
    }

    const source_dir = std.fs.path.dirname(source_path) orelse ".";
    const candidate = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ source_dir, path });
    defer allocator.free(candidate);

    var results = std.ArrayList([]const u8){};
    for (known_files) |f| {
        if (std.mem.endsWith(u8, f, candidate) or std.mem.endsWith(u8, f, path)) {
            try results.append(allocator, f);
        }
    }

    return try results.toOwnedSlice(allocator);
}

// ── Helpers ──────────────────────────────────────────────────────────────────

fn copy_replacing(buf: []u8, start: usize, src: []const u8, find: []const u8, replace: []const u8) usize {
    var pos = start;
    var i: usize = 0;
    while (i < src.len) {
        if (i + find.len <= src.len and std.mem.eql(u8, src[i .. i + find.len], find)) {
            for (replace) |c| {
                if (pos < buf.len) {
                    buf[pos] = c;
                    pos += 1;
                }
            }
            i += find.len;
        } else {
            if (pos < buf.len) {
                buf[pos] = src[i];
                pos += 1;
            }
            i += 1;
        }
    }
    return pos - start;
}


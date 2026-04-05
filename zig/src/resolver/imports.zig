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
    // Skip node_modules
    if (!std.mem.startsWith(u8, import_str, ".")) return &[_][]const u8{};

    const source_dir = std.fs.path.dirname(source_path) orelse ".";
    const extensions = [_][]const u8{ ".ts", ".tsx", ".js", ".jsx", ".json", "/index.ts", "/index.tsx", "/index.js" };

    var results = std.ArrayList([]const u8){};
    for (&extensions) |ext| {
        const candidate = try std.fmt.allocPrint(allocator, "{s}/{s}{s}", .{ source_dir, import_str, ext });
        defer allocator.free(candidate);
        // Normalize .. and .
        for (known_files) |f| {
            if (std.mem.endsWith(u8, f, candidate) or pathEndsWith(f, candidate)) {
                try results.append(allocator, f);
                break;
            }
        }
    }

    return try results.toOwnedSlice(allocator);
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

fn pathEndsWith(full: []const u8, suffix: []const u8) bool {
    if (suffix.len > full.len) return false;
    // Normalize both by removing leading ./
    var s = suffix;
    while (std.mem.startsWith(u8, s, "./")) s = s[2..];
    var f = full;
    while (std.mem.startsWith(u8, f, "./")) f = f[2..];
    return std.mem.endsWith(u8, f, s);
}

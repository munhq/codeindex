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
        .rust => try resolve_rust(allocator, import_str, source_path, known_files),
        .go => try resolve_go(allocator, import_str, known_files),
        .typescript, .javascript => try resolve_ts(allocator, import_str, source_path, known_files),
        .python => try resolve_python(allocator, import_str, source_path, known_files),
        .c, .cpp => try resolve_c(allocator, import_str, source_path, known_files),
        .zig => try resolve_zig(allocator, import_str, source_path, known_files),
        .java => try resolve_by_dotted_path(allocator, import_str, known_files, ".java"),
        .kotlin => try resolve_by_dotted_path(allocator, import_str, known_files, ".kt"),
        .scala => try resolve_by_dotted_path(allocator, import_str, known_files, ".scala"),
        .lua => try resolve_by_dotted_path(allocator, import_str, known_files, ".lua"),
        .ruby => try resolve_ruby(allocator, import_str, source_path, known_files),
        .dart => try resolve_dart(allocator, import_str, source_path, known_files),
        .solidity => try resolve_solidity(allocator, import_str, source_path, known_files),
        .protobuf => try resolve_proto(allocator, import_str, source_path, known_files),
        .nix => try resolve_nix(allocator, import_str, source_path, known_files),
        .css => try resolve_relative(allocator, import_str, source_path, known_files, &.{ "", ".css" }),
        .scss => try resolve_scss(allocator, import_str, source_path, known_files),
        .bash => try resolve_relative(allocator, import_str, source_path, known_files, &.{ "", ".sh", ".bash" }),
        .make => try resolve_relative(allocator, import_str, source_path, known_files, &.{ "", ".mk" }),
        .html => try resolve_relative(allocator, import_str, source_path, known_files, &.{""}),
        .r => try resolve_relative(allocator, import_str, source_path, known_files, &.{ "", ".R", ".r" }),
        .hcl => try resolve_hcl(allocator, import_str, source_path, known_files),
        .yaml => try resolve_relative(allocator, import_str, source_path, known_files, &.{ "", ".yml", ".yaml" }),
        .jinja2 => try resolve_relative(allocator, import_str, source_path, known_files, &.{ "", ".html", ".j2", ".jinja", ".jinja2" }),
        else => &[_][]const u8{},
    };
}

// ── File-level imports (relative-path languages) ────────────────────────────────

/// Join `source_dir + rel`, normalize, then try each suffix in `exts` and return
/// the first known file matching exactly or on a '/'-boundary. Shared by CSS,
/// Bash, Make, HTML and R, whose imports are filesystem paths.
fn resolve_relative(
    allocator: std.mem.Allocator,
    import_str: []const u8,
    source_path: []const u8,
    known_files: []const []const u8,
    exts: []const []const u8,
) ![][]const u8 {
    if (import_str.len == 0) return &[_][]const u8{};
    const source_dir = std.fs.path.dirname(source_path) orelse ".";

    for (exts) |ext| {
        const joined = try std.fmt.allocPrint(allocator, "{s}/{s}{s}", .{ source_dir, import_str, ext });
        defer allocator.free(joined);
        const target = try normalize_path(allocator, joined);
        defer allocator.free(target);
        for (known_files) |f| {
            if (std.mem.eql(u8, f, target) or
                (f.len > target.len and f[f.len - target.len - 1] == '/' and std.mem.endsWith(u8, f, target)))
            {
                var results = std.ArrayList([]const u8).empty;
                try results.append(allocator, f);
                return results.toOwnedSlice(allocator);
            }
        }
    }
    return &[_][]const u8{};
}

// ── Protobuf ────────────────────────────────────────────────────────────────────

fn resolve_proto(allocator: std.mem.Allocator, import_str: []const u8, source_path: []const u8, known_files: []const []const u8) ![][]const u8 {
    if (!std.mem.endsWith(u8, import_str, ".proto")) return &[_][]const u8{};
    // Try source-relative, then package-root-relative suffix (`a/b.proto`).
    const rel = try resolve_relative(allocator, import_str, source_path, known_files, &.{""});
    if (rel.len > 0) return rel;
    var results = std.ArrayList([]const u8).empty;
    errdefer results.deinit(allocator);
    for (known_files) |f| {
        if (f.len > import_str.len and f[f.len - import_str.len - 1] == '/' and std.mem.endsWith(u8, f, import_str)) {
            try results.append(allocator, f);
            return try results.toOwnedSlice(allocator);
        }
    }
    return try results.toOwnedSlice(allocator);
}

// ── Solidity ───────────────────────────────────────────────────────────────────

fn resolve_solidity(allocator: std.mem.Allocator, import_str: []const u8, source_path: []const u8, known_files: []const []const u8) ![][]const u8 {
    if (!std.mem.endsWith(u8, import_str, ".sol")) return &[_][]const u8{};
    // Relative import: resolve against the source directory.
    if (std.mem.startsWith(u8, import_str, "."))
        return resolve_relative(allocator, import_str, source_path, known_files, &.{""});
    // Remapped/library import (`@scope/path/X.sol`). Without the remappings file
    // we can't map the prefix, so suffix-match on the basename (best-effort).
    const base = std.fs.path.basename(import_str);
    var results = std.ArrayList([]const u8).empty;
    errdefer results.deinit(allocator);
    for (known_files) |f| {
        if (f.len > base.len and f[f.len - base.len - 1] == '/' and std.mem.endsWith(u8, f, base)) {
            try results.append(allocator, f);
            return try results.toOwnedSlice(allocator);
        }
    }
    return try results.toOwnedSlice(allocator);
}

// ── Nix ──────────────────────────────────────────────────────────────────────

fn resolve_nix(allocator: std.mem.Allocator, import_str: []const u8, source_path: []const u8, known_files: []const []const u8) ![][]const u8 {
    // `import ./x.nix` → x.nix; `import ./dir` → dir/default.nix.
    if (std.mem.endsWith(u8, import_str, ".nix"))
        return resolve_relative(allocator, import_str, source_path, known_files, &.{""});
    const dir_default = try std.fmt.allocPrint(allocator, "{s}/default.nix", .{import_str});
    defer allocator.free(dir_default);
    const a = try resolve_relative(allocator, import_str, source_path, known_files, &.{".nix"});
    if (a.len > 0) return a;
    return resolve_relative(allocator, dir_default, source_path, known_files, &.{""});
}

// ── SCSS (partials use a leading underscore) ────────────────────────────────────

fn resolve_scss(allocator: std.mem.Allocator, import_str: []const u8, source_path: []const u8, known_files: []const []const u8) ![][]const u8 {
    // `@use 'a/foo'` → a/foo.scss, a/_foo.scss (partial), a/foo/_index.scss.
    const base = std.fs.path.basename(import_str);
    const parent = std.fs.path.dirname(import_str);

    const partial = if (parent) |p|
        try std.fmt.allocPrint(allocator, "{s}/_{s}", .{ p, base })
    else
        try std.fmt.allocPrint(allocator, "_{s}", .{base});
    defer allocator.free(partial);
    const index = try std.fmt.allocPrint(allocator, "{s}/_index", .{import_str});
    defer allocator.free(index);

    inline for (.{ import_str, partial, index }) |cand| {
        const r = try resolve_relative(allocator, cand, source_path, known_files, &.{".scss"});
        if (r.len > 0) return r;
    }
    return &[_][]const u8{};
}

// ── HCL/Terraform (module source is a directory) ────────────────────────────────

fn resolve_hcl(allocator: std.mem.Allocator, import_str: []const u8, source_path: []const u8, known_files: []const []const u8) ![][]const u8 {
    // `source = "./modules/vpc"` → first .tf file inside that directory.
    const source_dir = std.fs.path.dirname(source_path) orelse ".";
    const joined = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ source_dir, import_str });
    defer allocator.free(joined);
    const dir = try normalize_path(allocator, joined);
    defer allocator.free(dir);

    var results = std.ArrayList([]const u8).empty;
    for (known_files) |f| {
        if (!std.mem.endsWith(u8, f, ".tf")) continue;
        if (std.mem.indexOf(u8, f, dir)) |idx| {
            const after = idx + dir.len;
            if (after < f.len and f[after] == '/') {
                try results.append(allocator, f);
                return results.toOwnedSlice(allocator);
            }
        }
    }
    return &[_][]const u8{};
}

// ── Dotted-path languages (Java / Kotlin / Scala / Lua) ─────────────────────────

/// Resolve a dotted module path (`a.b.C` → `a/b/C{ext}`) by suffix-matching
/// against known files, progressively stripping trailing components so an
/// imported member (`a.b.C.field`) still resolves to its declaring file.
fn resolve_by_dotted_path(
    allocator: std.mem.Allocator,
    import_str: []const u8,
    known_files: []const []const u8,
    ext: []const u8,
) ![][]const u8 {
    if (import_str.len == 0) return &[_][]const u8{};
    // Wildcards (`a.b.*`, `a.b._`) name a package, not a file — skip.
    if (std.mem.endsWith(u8, import_str, ".*") or std.mem.endsWith(u8, import_str, "._"))
        return &[_][]const u8{};

    var buf: [512]u8 = undefined;
    const len = copy_replacing(&buf, 0, import_str, ".", "/");
    var prefix = buf[0..len];

    var results = std.ArrayList([]const u8).empty;
    errdefer results.deinit(allocator);

    while (prefix.len > 0) {
        const candidate = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, ext });
        defer allocator.free(candidate);
        for (known_files) |f| {
            if (std.mem.eql(u8, f, candidate) or
                (f.len > candidate.len and f[f.len - candidate.len - 1] == '/' and std.mem.endsWith(u8, f, candidate)))
            {
                try results.append(allocator, f);
                return try results.toOwnedSlice(allocator);
            }
        }
        const slash = std.mem.lastIndexOfScalar(u8, prefix, '/') orelse break;
        prefix = prefix[0..slash];
    }
    return try results.toOwnedSlice(allocator);
}

// ── Ruby ─────────────────────────────────────────────────────────────────────

fn resolve_ruby(allocator: std.mem.Allocator, import_str: []const u8, source_path: []const u8, known_files: []const []const u8) ![][]const u8 {
    var results = std.ArrayList([]const u8).empty;
    errdefer results.deinit(allocator);

    // `require_relative '../x'` and `require 'lib/x'` both reference x.rb.
    // Try source-relative first, then a load-path suffix match.
    const source_dir = std.fs.path.dirname(source_path) orelse ".";
    const rel = try std.fmt.allocPrint(allocator, "{s}/{s}.rb", .{ source_dir, import_str });
    defer allocator.free(rel);
    const rel_norm = try normalize_path(allocator, rel);
    defer allocator.free(rel_norm);

    const suffix = try std.fmt.allocPrint(allocator, "{s}.rb", .{import_str});
    defer allocator.free(suffix);

    for (known_files) |f| {
        if (std.mem.eql(u8, f, rel_norm) or
            (f.len > rel_norm.len and f[f.len - rel_norm.len - 1] == '/' and std.mem.endsWith(u8, f, rel_norm)) or
            (f.len > suffix.len and f[f.len - suffix.len - 1] == '/' and std.mem.endsWith(u8, f, suffix)))
        {
            try results.append(allocator, f);
            return try results.toOwnedSlice(allocator);
        }
    }
    return try results.toOwnedSlice(allocator);
}

// ── Dart ─────────────────────────────────────────────────────────────────────

fn resolve_dart(allocator: std.mem.Allocator, import_str: []const u8, source_path: []const u8, known_files: []const []const u8) ![][]const u8 {
    if (!std.mem.endsWith(u8, import_str, ".dart")) return &[_][]const u8{};
    // `dart:` core libs aren't files.
    if (std.mem.startsWith(u8, import_str, "dart:")) return &[_][]const u8{};

    var results = std.ArrayList([]const u8).empty;
    errdefer results.deinit(allocator);

    if (std.mem.startsWith(u8, import_str, "package:")) {
        // `package:foo/bar.dart` → match on `bar.dart`-ending path within the repo.
        const after = import_str["package:".len..];
        const rel = if (std.mem.indexOfScalar(u8, after, '/')) |s| after[s + 1 ..] else after;
        for (known_files) |f| {
            if (f.len > rel.len and f[f.len - rel.len - 1] == '/' and std.mem.endsWith(u8, f, rel)) {
                try results.append(allocator, f);
                return try results.toOwnedSlice(allocator);
            }
        }
        return try results.toOwnedSlice(allocator);
    }

    // Relative import.
    const source_dir = std.fs.path.dirname(source_path) orelse ".";
    const joined = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ source_dir, import_str });
    defer allocator.free(joined);
    const target = try normalize_path(allocator, joined);
    defer allocator.free(target);
    for (known_files) |f| {
        if (std.mem.eql(u8, f, target) or
            (f.len > target.len and f[f.len - target.len - 1] == '/' and std.mem.endsWith(u8, f, target)))
        {
            try results.append(allocator, f);
            return try results.toOwnedSlice(allocator);
        }
    }
    return try results.toOwnedSlice(allocator);
}

// ── Zig ────────────────────────────────────────────────────────────────────────

fn resolve_zig(
    allocator: std.mem.Allocator,
    import_str: []const u8,
    source_path: []const u8,
    known_files: []const []const u8,
) ![][]const u8 {
    // Only `@import("./rel/path.zig")` forms reference files. `std`, `builtin`,
    // `root` and package names don't end in `.zig` and are skipped.
    if (!std.mem.endsWith(u8, import_str, ".zig")) return &[_][]const u8{};

    const source_dir = std.fs.path.dirname(source_path) orelse ".";
    const joined = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ source_dir, import_str });
    defer allocator.free(joined);
    const target = try normalize_path(allocator, joined);
    defer allocator.free(target);

    var results = std.ArrayList([]const u8).empty;
    errdefer results.deinit(allocator);

    for (known_files) |f| {
        // Exact (relative paths) or suffix on a '/' boundary (full stored paths).
        if (std.mem.eql(u8, f, target) or
            (f.len > target.len and f[f.len - target.len - 1] == '/' and std.mem.endsWith(u8, f, target)))
        {
            try results.append(allocator, f);
            return try results.toOwnedSlice(allocator);
        }
    }
    return try results.toOwnedSlice(allocator);
}

// ── Rust ─────────────────────────────────────────────────────────────────────

fn resolve_rust(
    allocator: std.mem.Allocator,
    import_str: []const u8,
    source_path: []const u8,
    known_files: []const []const u8,
) ![][]const u8 {
    // Skip std/core/alloc crates
    if (std.mem.startsWith(u8, import_str, "std::") or
        std.mem.startsWith(u8, import_str, "core::") or
        std.mem.startsWith(u8, import_str, "alloc::"))
        return &[_][]const u8{};

    var results = std.ArrayList([]const u8).empty;
    errdefer results.deinit(allocator);

    // Case 1: bare module name (e.g. `mod estop;` → import_str = "estop").
    // Resolve relative to source_path's directory: src/security/mod.rs + "estop"
    //   → src/security/estop.rs or src/security/estop/mod.rs
    if (std.mem.indexOf(u8, import_str, "::") == null and
        !std.mem.startsWith(u8, import_str, "crate") and
        !std.mem.startsWith(u8, import_str, "super"))
    {
        const source_dir = std.fs.path.dirname(source_path) orelse ".";
        const rel_file = try std.fmt.allocPrint(allocator, "{s}/{s}.rs", .{ source_dir, import_str });
        defer allocator.free(rel_file);
        const rel_mod = try std.fmt.allocPrint(allocator, "{s}/{s}/mod.rs", .{ source_dir, import_str });
        defer allocator.free(rel_mod);
        for (known_files) |f| {
            if (std.mem.eql(u8, f, rel_file) or std.mem.eql(u8, f, rel_mod)) {
                try results.append(allocator, f);
                return try results.toOwnedSlice(allocator);
            }
        }
        // Try endsWith fallback for relative-ish path matching
        for (known_files) |f| {
            if (std.mem.endsWith(u8, f, rel_file) or std.mem.endsWith(u8, f, rel_mod)) {
                try results.append(allocator, f);
                return try results.toOwnedSlice(allocator);
            }
        }
        return try results.toOwnedSlice(allocator);
    }

    var path_part = import_str;
    if (std.mem.startsWith(u8, path_part, "crate::")) {
        path_part = path_part[7..];
    } else if (std.mem.startsWith(u8, path_part, "super::")) {
        path_part = path_part[7..];
    }

    // Convert :: to /
    var buf: [512]u8 = undefined;
    var pos: usize = 0;
    pos += copy_replacing(&buf, pos, path_part, "::", "/");
    const joined = buf[0..pos];

    // Try src/{path}.rs then src/{path}/mod.rs (treating last component as module).
    if (try try_rust_file(allocator, known_files, joined, &results)) {
        return try results.toOwnedSlice(allocator);
    }

    // Case 2: the import names an item inside a module, not a module file —
    // e.g. `crate::bar::helper` (fn) or `crate::security::EstopManager` (type).
    // `bar/helper` won't match a file, so progressively strip trailing
    // components and retry, falling back `bar/helper` → `bar` → src/bar.rs.
    // (Item case can't be relied on: items may be snake_case or PascalCase.)
    var prefix = joined;
    while (std.mem.lastIndexOfScalar(u8, prefix, '/')) |slash| {
        prefix = prefix[0..slash];
        if (prefix.len == 0) break;
        if (try try_rust_file(allocator, known_files, prefix, &results)) {
            return try results.toOwnedSlice(allocator);
        }
    }

    // No slash — single component like `crate::SymbolName` (rare; top-level
    // re-export). Point at the crate root lib.rs.
    if (std.mem.indexOfScalar(u8, joined, '/') == null and
        joined.len > 0 and std.ascii.isUpper(joined[0]))
    {
        for (known_files) |f| {
            if (std.mem.endsWith(u8, f, "src/lib.rs")) {
                try results.append(allocator, f);
                return try results.toOwnedSlice(allocator);
            }
        }
    }

    return try results.toOwnedSlice(allocator);
}

fn try_rust_file(
    allocator: std.mem.Allocator,
    known_files: []const []const u8,
    path: []const u8,
    results: *std.ArrayList([]const u8),
) !bool {
    const as_file = try std.fmt.allocPrint(allocator, "src/{s}.rs", .{path});
    defer allocator.free(as_file);
    for (known_files) |f| {
        if (std.mem.endsWith(u8, f, as_file)) {
            try results.append(allocator, f);
            return true;
        }
    }
    const as_mod = try std.fmt.allocPrint(allocator, "src/{s}/mod.rs", .{path});
    defer allocator.free(as_mod);
    for (known_files) |f| {
        if (std.mem.endsWith(u8, f, as_mod)) {
            try results.append(allocator, f);
            return true;
        }
    }
    return false;
}

// ── TypeScript/JavaScript ────────────────────────────────────────────────────

fn resolve_ts(allocator: std.mem.Allocator, import_str: []const u8, source_path: []const u8, known_files: []const []const u8) ![][]const u8 {
    // Skip bare package specifiers (node_modules). Still handle path aliases
    // like `@/foo` and `~/foo` by falling through to the suffix-match pass.
    const is_relative = std.mem.startsWith(u8, import_str, ".");
    const is_alias = std.mem.startsWith(u8, import_str, "@/") or std.mem.startsWith(u8, import_str, "~/");
    if (!is_relative and !is_alias) return &[_][]const u8{};

    const source_dir = std.fs.path.dirname(source_path) orelse ".";
    const extensions = [_][]const u8{ "", ".ts", ".tsx", ".js", ".jsx", ".json", "/index.ts", "/index.tsx", "/index.js", "/index.jsx" };

    // Modern ESM/NodeNext TypeScript writes `./x.js` but the source file is
    // `x.ts`. Strip a trailing JS-ish extension so the .ts/.tsx candidates match.
    var base = import_str;
    inline for ([_][]const u8{ ".js", ".jsx", ".mjs", ".cjs" }) |je| {
        if (std.mem.endsWith(u8, base, je)) {
            base = base[0 .. base.len - je.len];
            break;
        }
    }

    var results = std.ArrayList([]const u8).empty;

    // Build normalized candidates
    for (&extensions) |ext| {
        var candidate: []u8 = undefined;
        if (is_relative) {
            const joined = try std.fmt.allocPrint(allocator, "{s}/{s}{s}", .{ source_dir, base, ext });
            defer allocator.free(joined);
            candidate = try normalize_path(allocator, joined);
        } else {
            // Alias — strip the alias prefix, try matching anywhere in known_files
            const stripped = base[2..];
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
    var segments = std.ArrayList([]const u8).empty;
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
    var results = std.ArrayList([]const u8).empty;

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

    // A Go import path's last segment is the package, which maps to a directory
    // of that name. Match the .go files whose *containing directory* is named
    // exactly that package — not any path that happens to contain the substring
    // (that crowned `logger_test.go` as a hub). Test files aren't import targets.
    const last_slash = std.mem.lastIndexOfScalar(u8, import_str, '/') orelse return &[_][]const u8{};
    const pkg = import_str[last_slash + 1 ..];
    if (pkg.len == 0) return &[_][]const u8{};

    var results = std.ArrayList([]const u8).empty;
    errdefer results.deinit(allocator);
    for (known_files) |f| {
        if (!std.mem.endsWith(u8, f, ".go") or std.mem.endsWith(u8, f, "_test.go")) continue;
        const dir = std.fs.path.dirname(f) orelse continue;
        if (std.mem.eql(u8, std.fs.path.basename(dir), pkg)) {
            try results.append(allocator, f);
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

    var results = std.ArrayList([]const u8).empty;
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


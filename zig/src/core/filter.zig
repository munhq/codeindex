const std = @import("std");

pub const Filter = struct {
    allocator: std.mem.Allocator,
    ignore_patterns: std.ArrayList([]const u8),
    skip_hidden: bool = true,

    const builtin_skip_dirs = [_][]const u8{
        ".git", ".zig-cache", "zig-out", "node_modules", "target",
        ".mypy_cache", "__pycache__", ".tox", ".pytest_cache",
        "vendor", "dist", "build", ".next", ".nuxt",
        ".svelte-kit", ".parcel-cache", ".turbo",
        "coverage", ".nyc_output", ".cache",
    };

    const builtin_skip_extensions = [_][]const u8{
        ".exe", ".dll", ".so", ".dylib", ".o", ".a", ".lib",
        ".pyc", ".pyo", ".class", ".jar", ".war",
        ".wasm", ".min.js", ".min.css",
        ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".ico", ".svg",
        ".mp3", ".mp4", ".avi", ".mov", ".webm",
        ".zip", ".tar", ".gz", ".bz2", ".xz", ".rar", ".7z",
        ".pdf", ".doc", ".docx", ".xls", ".xlsx",
        ".sqlite", ".db", ".lock",
    };

    pub fn init(allocator: std.mem.Allocator) Filter {
        return .{
            .allocator = allocator,
            .ignore_patterns = std.ArrayList([]const u8){},
        };
    }

    pub fn deinit(self: *Filter) void {
        for (self.ignore_patterns.items) |p| self.allocator.free(p);
        self.ignore_patterns.deinit(self.allocator);
    }

    pub fn load_gitignore(self: *Filter, root: []const u8) !void {
        const gitignore_path = try std.fs.path.join(self.allocator, &.{ root, ".gitignore" });
        defer self.allocator.free(gitignore_path);

        const file = std.fs.cwd().openFile(gitignore_path, .{}) catch return;
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(content);

        var line_it = std.mem.splitScalar(u8, content, '\n');
        while (line_it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;
            var pat = trimmed;
            if (pat.len > 0 and pat[pat.len - 1] == '/') pat = pat[0 .. pat.len - 1];
            if (pat.len == 0) continue;
            try self.ignore_patterns.append(self.allocator, try self.allocator.dupe(u8, pat));
        }
    }

    pub fn should_ignore(self: *const Filter, path: []const u8) bool {
        var comp_it = std.mem.splitScalar(u8, path, '/');
        while (comp_it.next()) |component| {
            if (component.len == 0) continue;

            // Skip hidden files/dirs
            if (self.skip_hidden and component[0] == '.' and component.len > 1) {
                if (!std.mem.eql(u8, component, ".gitignore") and
                    !std.mem.eql(u8, component, ".env") and
                    !std.mem.eql(u8, component, ".env.example"))
                {
                    return true;
                }
            }

            // Builtin skip dirs
            for (&builtin_skip_dirs) |dir| {
                if (std.mem.eql(u8, component, dir)) return true;
            }
        }

        // Builtin skip extensions
        for (&builtin_skip_extensions) |ext| {
            if (std.mem.endsWith(u8, path, ext)) return true;
        }

        // Gitignore patterns
        for (self.ignore_patterns.items) |pattern| {
            if (matchPattern(path, pattern)) return true;
        }

        return false;
    }
};

fn matchPattern(path: []const u8, pattern: []const u8) bool {
    if (pattern.len == 0) return false;
    if (pattern[0] == '!') return false;

    if (pattern[0] == '/') {
        return matchGlob(path, pattern[1..]);
    }

    if (matchGlob(path, pattern)) return true;

    const basename = std.fs.path.basename(path);
    if (matchGlob(basename, pattern)) return true;

    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |component| {
        if (std.mem.eql(u8, component, pattern)) return true;
    }

    return false;
}

fn matchGlob(str: []const u8, pattern: []const u8) bool {
    var si: usize = 0;
    var pi: usize = 0;
    var star_pi: ?usize = null;
    var star_si: usize = 0;

    while (si < str.len) {
        if (pi < pattern.len and (pattern[pi] == str[si] or pattern[pi] == '?')) {
            si += 1;
            pi += 1;
        } else if (pi < pattern.len and pattern[pi] == '*') {
            star_pi = pi;
            star_si = si;
            pi += 1;
        } else if (star_pi) |sp| {
            pi = sp + 1;
            star_si += 1;
            si = star_si;
        } else {
            return false;
        }
    }

    while (pi < pattern.len and pattern[pi] == '*') pi += 1;
    return pi == pattern.len;
}

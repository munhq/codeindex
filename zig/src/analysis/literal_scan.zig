const std = @import("std");
const explorer = @import("../index/explorer.zig");

pub const Category = enum {
    url,
    ip,
    localhost,
    abs_path,
    secret_suspect,
    magic_port,
    todo_marker,

    pub fn as_str(self: Category) []const u8 {
        return switch (self) {
            .url => "url",
            .ip => "ip",
            .localhost => "localhost",
            .abs_path => "abs_path",
            .secret_suspect => "secret_suspect",
            .magic_port => "magic_port",
            .todo_marker => "todo_marker",
        };
    }
};

pub const Finding = struct {
    file: []const u8,
    line: usize,
    category: Category,
    snippet: []const u8,
};

pub const Summary = struct {
    total: usize,
    urls: usize,
    ips: usize,
    localhosts: usize,
    paths: usize,
    secrets: usize,
    ports: usize,
    todos: usize,
};

fn is_excluded_path(path: []const u8) bool {
    // Skip obvious non-source
    if (std.mem.indexOf(u8, path, "node_modules") != null) return true;
    if (std.mem.indexOf(u8, path, "/vendor/") != null) return true;
    if (std.mem.indexOf(u8, path, "/target/") != null) return true;
    if (std.mem.indexOf(u8, path, "/dist/") != null) return true;
    if (std.mem.indexOf(u8, path, "/build/") != null) return true;
    if (std.mem.indexOf(u8, path, "/.git/") != null) return true;
    // Skip tests & docs — intentional literals belong there
    if (std.mem.indexOf(u8, path, "/tests/") != null) return true;
    if (std.mem.indexOf(u8, path, "/test/") != null) return true;
    if (std.mem.indexOf(u8, path, "_test.") != null) return true;
    if (std.mem.endsWith(u8, path, ".test.ts") or std.mem.endsWith(u8, path, ".test.tsx")) return true;
    if (std.mem.endsWith(u8, path, ".spec.ts") or std.mem.endsWith(u8, path, ".spec.tsx")) return true;
    if (std.mem.endsWith(u8, path, ".md") or std.mem.endsWith(u8, path, ".markdown")) return true;
    // Migrations are supposed to hard-code names / defaults
    if (std.mem.indexOf(u8, path, "/migrations/") != null) return true;
    if (std.mem.indexOf(u8, path, "/fixtures/") != null) return true;
    return false;
}

fn line_is_comment(trimmed: []const u8, ext: []const u8) bool {
    if (std.mem.startsWith(u8, trimmed, "//")) return true;
    if (std.mem.startsWith(u8, trimmed, "/*")) return true;
    if (std.mem.startsWith(u8, trimmed, "*")) return true;
    // Shell/python/toml/yaml style
    if (std.mem.eql(u8, ext, "py") or std.mem.eql(u8, ext, "sh") or
        std.mem.eql(u8, ext, "bash") or std.mem.eql(u8, ext, "toml") or
        std.mem.eql(u8, ext, "yaml") or std.mem.eql(u8, ext, "yml"))
    {
        if (std.mem.startsWith(u8, trimmed, "#")) return true;
    }
    return false;
}

fn is_url_scheme(line: []const u8, start: usize) bool {
    // Start must be at word boundary
    if (start > 0) {
        const p = line[start - 1];
        if (std.ascii.isAlphanumeric(p) or p == '_' or p == '-') return false;
    }
    return true;
}

fn find_url(line: []const u8) ?struct { s: usize, e: usize } {
    const schemes = [_][]const u8{ "https://", "http://", "wss://", "ws://", "postgres://", "postgresql://", "mongodb://", "redis://", "amqp://", "grpc://" };
    for (schemes) |scheme| {
        if (std.mem.indexOf(u8, line, scheme)) |idx| {
            if (!is_url_scheme(line, idx)) continue;
            // Find end: whitespace or quote
            var end = idx + scheme.len;
            while (end < line.len) : (end += 1) {
                const c = line[end];
                if (c == ' ' or c == '\t' or c == '"' or c == '\'' or c == '`' or c == ')' or c == ']' or c == '>' or c == ',') break;
            }
            if (end > idx + scheme.len) return .{ .s = idx, .e = end };
        }
    }
    return null;
}

fn octet_at(line: []const u8, i: usize) ?struct { val: u16, len: usize } {
    var j: usize = i;
    var val: u16 = 0;
    while (j < line.len and std.ascii.isDigit(line[j])) : (j += 1) {
        if (j - i >= 3) return null;
        val = val * 10 + (line[j] - '0');
    }
    if (j == i) return null;
    if (val > 255) return null;
    return .{ .val = val, .len = j - i };
}

fn find_ipv4(line: []const u8) ?struct { s: usize, e: usize } {
    var i: usize = 0;
    while (i < line.len) {
        if (!std.ascii.isDigit(line[i])) {
            i += 1;
            continue;
        }
        // Must be at word boundary
        if (i > 0) {
            const p = line[i - 1];
            if (std.ascii.isAlphanumeric(p) or p == '.') {
                i += 1;
                continue;
            }
        }
        var cursor = i;
        var parts: u8 = 0;
        var ok = true;
        while (parts < 4) {
            const oc = octet_at(line, cursor) orelse {
                ok = false;
                break;
            };
            cursor += oc.len;
            parts += 1;
            if (parts < 4) {
                if (cursor >= line.len or line[cursor] != '.') {
                    ok = false;
                    break;
                }
                cursor += 1;
            }
        }
        if (ok) {
            // Must end at word boundary
            if (cursor < line.len and (std.ascii.isAlphanumeric(line[cursor]) or line[cursor] == '.')) {
                // Not a clean IP (e.g. version string 1.2.3.4.5)
                i = cursor;
                continue;
            }
            return .{ .s = i, .e = cursor };
        }
        i += 1;
    }
    return null;
}

/// Detect long alphanumeric strings inside quotes that look like keys/tokens.
fn find_secret_suspect(line: []const u8) ?struct { s: usize, e: usize } {
    // Look for quoted strings containing >= 24 chars of [A-Za-z0-9_+/=-]
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const q = line[i];
        if (q != '"' and q != '\'') continue;
        // find closing quote on same line
        var j = i + 1;
        while (j < line.len and line[j] != q) : (j += 1) {}
        if (j >= line.len) return null;
        const body = line[i + 1 .. j];
        if (body.len < 24) {
            i = j;
            continue;
        }
        // must not contain spaces or common word-sentences
        var alphanum: usize = 0;
        var spaces: usize = 0;
        var uppers: usize = 0;
        var digits: usize = 0;
        for (body) |c| {
            if (c == ' ') spaces += 1;
            if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '+' or c == '/' or c == '=') alphanum += 1;
            if (std.ascii.isUpper(c)) uppers += 1;
            if (std.ascii.isDigit(c)) digits += 1;
        }
        if (spaces > 0) {
            i = j;
            continue;
        }
        if (alphanum < body.len) {
            i = j;
            continue;
        }
        // heuristic: needs mix of upper+digit (tokens) OR very long (>40)
        const has_mix = uppers >= 2 and digits >= 2;
        if (has_mix or body.len >= 40) {
            return .{ .s = i, .e = j + 1 };
        }
        i = j;
    }
    return null;
}

fn is_kv_key(line: []const u8, idx: usize, needle: []const u8) bool {
    // does line contain needle as part of an assignment-like key?
    if (std.mem.indexOf(u8, line[0..idx], needle) == null) return false;
    return true;
}

fn looks_like_todo(trimmed: []const u8) ?struct { s: usize, e: usize } {
    const markers = [_][]const u8{ "TODO", "FIXME", "XXX", "HACK", "BUG:", "HACK:" };
    for (markers) |m| {
        if (std.mem.indexOf(u8, trimmed, m)) |idx| {
            // boundary
            if (idx > 0) {
                const p = trimmed[idx - 1];
                if (std.ascii.isAlphanumeric(p) or p == '_') continue;
            }
            // end of token
            var end = idx + m.len;
            while (end < trimmed.len) : (end += 1) {
                const c = trimmed[end];
                if (c == ' ' or c == '\t' or c == ':' or c == ',' or c == '.' or c == ')' or c == '"' or c == '\'') break;
                if (!(std.ascii.isAlphanumeric(c) or c == '_')) break;
            }
            return .{ .s = idx, .e = end };
        }
    }
    return null;
}

fn snippet(allocator: std.mem.Allocator, line: []const u8, s: usize, e: usize) ![]u8 {
    // Keep at most 80 chars centered on [s, e], escape quotes and backslashes
    const max_len: usize = 80;
    var start: usize = s;
    var end: usize = e;
    if (end - start < max_len) {
        const pad: usize = (max_len - (end - start)) / 2;
        start = if (start > pad) start - pad else 0;
        end = @min(line.len, end + pad);
    } else {
        end = @min(line.len, start + max_len);
    }
    const raw = std.mem.trim(u8, line[start..end], " \t");
    // Escape for JSON
    var out = std.ArrayList(u8){};
    errdefer out.deinit(allocator);
    for (raw) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => {},
            else => try out.append(allocator, c),
        }
    }
    return try out.toOwnedSlice(allocator);
}

pub fn scan(allocator: std.mem.Allocator, exp: *explorer.Explorer) ![]Finding {
    var findings = std.ArrayList(Finding){};
    errdefer findings.deinit(allocator);

    var it = exp.outlines.iterator();
    while (it.next()) |entry| {
        const file_id = entry.key_ptr.*;
        if (exp.deleted_files.get(file_id) != null) continue;
        const outline = entry.value_ptr.*;
        if (is_excluded_path(outline.path)) continue;

        // Only scan source-ish files. Skip pure data files.
        switch (outline.language) {
            .unknown, .json, .xml, .diff, .gitcommit, .gitignore => continue,
            else => {},
        }

        const content = exp.content_cache.get(file_id) orelse continue;
        const ext = blk: {
            const e = std.fs.path.extension(outline.path);
            if (e.len > 1) break :blk e[1..];
            break :blk "";
        };

        var line_num: usize = 0;
        var line_it = std.mem.splitScalar(u8, content, '\n');
        while (line_it.next()) |line_raw| {
            line_num += 1;
            if (line_raw.len == 0) continue;
            if (line_raw.len > 2000) continue; // skip minified / generated
            const trimmed = std.mem.trim(u8, line_raw, " \t\r");
            if (trimmed.len == 0) continue;
            if (line_is_comment(trimmed, ext)) {
                // comments can still contain TODO markers — check only that
                if (looks_like_todo(trimmed)) |_| {
                    try findings.append(allocator, .{
                        .file = outline.path,
                        .line = line_num,
                        .category = .todo_marker,
                        .snippet = try snippet(allocator, trimmed, 0, trimmed.len),
                    });
                }
                continue;
            }

            // URL
            if (find_url(line_raw)) |r| {
                // De-duplicate localhost check: prefer .localhost category if URL is localhost
                const seg = line_raw[r.s..r.e];
                const cat: Category = if (std.mem.indexOf(u8, seg, "localhost") != null or
                    std.mem.indexOf(u8, seg, "127.0.0.1") != null or
                    std.mem.indexOf(u8, seg, "0.0.0.0") != null) .localhost else .url;
                try findings.append(allocator, .{
                    .file = outline.path,
                    .line = line_num,
                    .category = cat,
                    .snippet = try snippet(allocator, line_raw, r.s, r.e),
                });
            }

            // IPv4 (even without scheme)
            if (find_ipv4(line_raw)) |r| {
                const seg = line_raw[r.s..r.e];
                // ignore version-like strings — covered by find_ipv4 boundary check already
                const is_local = std.mem.startsWith(u8, seg, "127.") or std.mem.eql(u8, seg, "0.0.0.0");
                try findings.append(allocator, .{
                    .file = outline.path,
                    .line = line_num,
                    .category = if (is_local) .localhost else .ip,
                    .snippet = try snippet(allocator, line_raw, r.s, r.e),
                });
            }

            // Secret-suspect (skip if line is a URL already flagged — they often contain tokens)
            if (find_secret_suspect(line_raw)) |r| {
                try findings.append(allocator, .{
                    .file = outline.path,
                    .line = line_num,
                    .category = .secret_suspect,
                    .snippet = try snippet(allocator, line_raw, r.s, r.e),
                });
            }

            // Absolute paths: "/home/", "/usr/", "/var/", "/opt/", "/etc/", "C:\\"
            const abs_prefixes = [_][]const u8{ "\"/home/", "\"/usr/", "\"/var/", "\"/opt/", "\"/etc/", "'/home/", "'/usr/", "'/etc/" };
            for (abs_prefixes) |pfx| {
                if (std.mem.indexOf(u8, line_raw, pfx)) |idx| {
                    try findings.append(allocator, .{
                        .file = outline.path,
                        .line = line_num,
                        .category = .abs_path,
                        .snippet = try snippet(allocator, line_raw, idx, @min(line_raw.len, idx + 40)),
                    });
                    break;
                }
            }

            // Magic ports: common DB/cache ports literally hardcoded
            const magic_ports = [_][]const u8{ ":5432", ":6379", ":3306", ":5672", ":9092", ":27017", ":4222" };
            for (magic_ports) |p| {
                if (std.mem.indexOf(u8, line_raw, p)) |idx| {
                    // skip if URL already captured (URL path includes port)
                    if (find_url(line_raw) != null) break;
                    try findings.append(allocator, .{
                        .file = outline.path,
                        .line = line_num,
                        .category = .magic_port,
                        .snippet = try snippet(allocator, line_raw, idx, @min(line_raw.len, idx + p.len + 10)),
                    });
                    break;
                }
            }

            // TODO markers in code
            if (looks_like_todo(trimmed)) |_| {
                try findings.append(allocator, .{
                    .file = outline.path,
                    .line = line_num,
                    .category = .todo_marker,
                    .snippet = try snippet(allocator, trimmed, 0, trimmed.len),
                });
            }
        }
    }

    return try findings.toOwnedSlice(allocator);
}

pub fn summarize(findings: []const Finding) Summary {
    var s = Summary{
        .total = findings.len,
        .urls = 0,
        .ips = 0,
        .localhosts = 0,
        .paths = 0,
        .secrets = 0,
        .ports = 0,
        .todos = 0,
    };
    for (findings) |f| {
        switch (f.category) {
            .url => s.urls += 1,
            .ip => s.ips += 1,
            .localhost => s.localhosts += 1,
            .abs_path => s.paths += 1,
            .secret_suspect => s.secrets += 1,
            .magic_port => s.ports += 1,
            .todo_marker => s.todos += 1,
        }
    }
    return s;
}

pub fn free_findings(allocator: std.mem.Allocator, findings: []Finding) void {
    for (findings) |f| allocator.free(f.snippet);
    allocator.free(findings);
}

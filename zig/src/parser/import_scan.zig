const std = @import("std");
const models = @import("../core/models.zig");

/// Regex-free import extractor. Appends to `imports` in-place.
/// The vendored tree-sitter tags.scm queries don't capture imports (they're ctags-style).
/// This fills that gap so the dep graph actually has edges.
pub fn extract(
    allocator: std.mem.Allocator,
    language: models.Language,
    content: []const u8,
    imports: *std.ArrayList([]const u8),
) !void {
    switch (language) {
        .rust => try extract_rust(allocator, content, imports),
        .python => try extract_python(allocator, content, imports),
        .go => try extract_go(allocator, content, imports),
        .typescript, .javascript => try extract_ts(allocator, content, imports),
        .java => try extract_java(allocator, content, imports),
        .c, .cpp => try extract_c(allocator, content, imports),
        else => {},
    }
}

fn append_unique(
    allocator: std.mem.Allocator,
    imports: *std.ArrayList([]const u8),
    s: []const u8,
) !void {
    const trimmed = std.mem.trim(u8, s, " \t\r;,");
    if (trimmed.len == 0 or trimmed.len > 256) return;
    for (imports.items) |existing| {
        if (std.mem.eql(u8, existing, trimmed)) return;
    }
    try imports.append(allocator, try allocator.dupe(u8, trimmed));
}

fn extract_rust(allocator: std.mem.Allocator, content: []const u8, imports: *std.ArrayList([]const u8)) !void {
    var line_it = std.mem.splitScalar(u8, content, '\n');
    while (line_it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        // Strip leading `pub `
        var t = trimmed;
        if (std.mem.startsWith(u8, t, "pub use ")) t = t["pub ".len..];
        if (std.mem.startsWith(u8, t, "pub(crate) use ")) t = t["pub(crate) ".len..];
        // `use foo::bar::Baz;` / `use foo::{a, b};`
        if (std.mem.startsWith(u8, t, "use ")) {
            var rest = t["use ".len..];
            // Stop at first `;` or `{` (simplification: ignore grouped imports beyond the root path)
            const semi = std.mem.indexOfScalar(u8, rest, ';');
            if (semi) |s| rest = rest[0..s];
            const brace = std.mem.indexOfScalar(u8, rest, '{');
            if (brace) |b| rest = std.mem.trim(u8, rest[0..b], " \t:");
            // Strip `as Alias`
            if (std.mem.indexOf(u8, rest, " as ")) |a| rest = rest[0..a];
            try append_unique(allocator, imports, rest);
            continue;
        }
        // `mod foo;` declarations — dependency on foo.rs / foo/mod.rs
        if (std.mem.startsWith(u8, t, "mod ") or std.mem.startsWith(u8, t, "pub mod ")) {
            var rest = t[std.mem.indexOf(u8, t, "mod ").? + 4 ..];
            const semi = std.mem.indexOfScalar(u8, rest, ';');
            const brace = std.mem.indexOfScalar(u8, rest, '{');
            if (semi) |s| rest = rest[0..s];
            if (brace) |b| rest = rest[0..b];
            rest = std.mem.trim(u8, rest, " \t");
            if (rest.len == 0) continue;
            try append_unique(allocator, imports, rest);
        }
    }
}

fn extract_python(allocator: std.mem.Allocator, content: []const u8, imports: *std.ArrayList([]const u8)) !void {
    var line_it = std.mem.splitScalar(u8, content, '\n');
    while (line_it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "from ")) {
            var rest = trimmed["from ".len..];
            if (std.mem.indexOf(u8, rest, " import")) |i| rest = rest[0..i];
            try append_unique(allocator, imports, std.mem.trim(u8, rest, " \t"));
        } else if (std.mem.startsWith(u8, trimmed, "import ")) {
            var rest = trimmed["import ".len..];
            // `import a, b` -> split
            if (std.mem.indexOf(u8, rest, " as ")) |a| rest = rest[0..a];
            var part_it = std.mem.splitScalar(u8, rest, ',');
            while (part_it.next()) |part| {
                try append_unique(allocator, imports, std.mem.trim(u8, part, " \t"));
            }
        }
    }
}

fn extract_go(allocator: std.mem.Allocator, content: []const u8, imports: *std.ArrayList([]const u8)) !void {
    var i: usize = 0;
    while (i < content.len) {
        const rest = content[i..];
        if (std.mem.startsWith(u8, rest, "import ")) {
            i += "import ".len;
            // Skip whitespace
            while (i < content.len and (content[i] == ' ' or content[i] == '\t')) : (i += 1) {}
            if (i < content.len and content[i] == '(') {
                // Multi-line block
                i += 1;
                while (i < content.len and content[i] != ')') : (i += 1) {
                    if (content[i] == '"') {
                        const start = i + 1;
                        var j = start;
                        while (j < content.len and content[j] != '"') : (j += 1) {}
                        try append_unique(allocator, imports, content[start..j]);
                        i = j;
                    }
                }
            } else if (i < content.len and content[i] == '"') {
                const start = i + 1;
                var j = start;
                while (j < content.len and content[j] != '"') : (j += 1) {}
                try append_unique(allocator, imports, content[start..j]);
                i = j;
            }
        } else {
            i += 1;
        }
    }
}

fn extract_ts(allocator: std.mem.Allocator, content: []const u8, imports: *std.ArrayList([]const u8)) !void {
    var line_it = std.mem.splitScalar(u8, content, '\n');
    while (line_it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        // `import ... from "..."` or `import "..."` or `} from "..."`
        // Also `require("...")`
        if (std.mem.indexOf(u8, trimmed, "from ")) |idx_from| {
            const after = trimmed[idx_from + 5 ..];
            if (extract_quoted(after)) |q| {
                try append_unique(allocator, imports, q);
                continue;
            }
        }
        if (std.mem.startsWith(u8, trimmed, "import ")) {
            if (extract_quoted(trimmed)) |q| {
                try append_unique(allocator, imports, q);
                continue;
            }
        }
        if (std.mem.indexOf(u8, trimmed, "require(") != null) {
            if (extract_quoted(trimmed)) |q| {
                try append_unique(allocator, imports, q);
            }
        }
    }
}

fn extract_java(allocator: std.mem.Allocator, content: []const u8, imports: *std.ArrayList([]const u8)) !void {
    var line_it = std.mem.splitScalar(u8, content, '\n');
    while (line_it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "import ")) {
            var rest = trimmed["import ".len..];
            if (std.mem.startsWith(u8, rest, "static ")) rest = rest["static ".len..];
            const semi = std.mem.indexOfScalar(u8, rest, ';');
            if (semi) |s| rest = rest[0..s];
            try append_unique(allocator, imports, std.mem.trim(u8, rest, " \t"));
        }
    }
}

fn extract_c(allocator: std.mem.Allocator, content: []const u8, imports: *std.ArrayList([]const u8)) !void {
    var line_it = std.mem.splitScalar(u8, content, '\n');
    while (line_it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "#include")) {
            var rest = trimmed["#include".len..];
            rest = std.mem.trim(u8, rest, " \t");
            if (rest.len < 2) continue;
            if (rest[0] == '<' or rest[0] == '"') {
                const close: u8 = if (rest[0] == '<') '>' else '"';
                const end = std.mem.indexOfScalar(u8, rest[1..], close) orelse continue;
                try append_unique(allocator, imports, rest[1 .. 1 + end]);
            }
        }
    }
}

fn extract_quoted(s: []const u8) ?[]const u8 {
    // return first single- or double-quoted substring
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '"' or c == '\'') {
            const start = i + 1;
            var j = start;
            while (j < s.len and s[j] != c) : (j += 1) {}
            if (j < s.len and j > start) return s[start..j];
            return null;
        }
    }
    return null;
}

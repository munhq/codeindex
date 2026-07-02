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
        .zig => try extract_zig(allocator, content, imports),
        .ruby => try extract_ruby(allocator, content, imports),
        .kotlin => try extract_line_import(allocator, content, imports),
        .scala => try extract_scala(allocator, content, imports),
        .dart => try extract_dart(allocator, content, imports),
        .lua => try extract_lua(allocator, content, imports),
        .nix => try extract_nix(allocator, content, imports),
        .css => try extract_at_import(allocator, content, imports),
        .scss => try extract_scss(allocator, content, imports),
        .bash => try extract_bash(allocator, content, imports),
        .make => try extract_make(allocator, content, imports),
        .html => try extract_html(allocator, content, imports),
        .hcl => try extract_hcl(allocator, content, imports),
        .r => try extract_r(allocator, content, imports),
        .solidity => try extract_solidity(allocator, content, imports),
        .protobuf => try extract_proto(allocator, content, imports),
        .yaml => try extract_yaml(allocator, content, imports),
        .jinja2 => try extract_jinja(allocator, content, imports),
        else => {},
    }
}

/// Ansible task/playbook file references (no-op on non-Ansible YAML, since these
/// keys don't appear there): `include_tasks: x.yml`, `import_playbook: y.yml`.
fn extract_yaml(allocator: std.mem.Allocator, content: []const u8, imports: *std.ArrayList([]const u8)) !void {
    const keys = [_][]const u8{ "include_tasks", "import_tasks", "import_playbook", "include_playbook", "include" };
    var line_it = std.mem.splitScalar(u8, content, '\n');
    while (line_it.next()) |line| {
        var t = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, t, "- ")) t = std.mem.trim(u8, t[2..], " \t");
        for (keys) |k| {
            if (t.len > k.len + 1 and std.mem.startsWith(u8, t, k) and t[k.len] == ':') {
                const val = std.mem.trim(u8, t[k.len + 1 ..], " \t\"'");
                // Inline scalar form only; skip dict form (`include_tasks:` then `file:`).
                if (val.len > 0 and std.mem.indexOfScalar(u8, val, ':') == null and
                    (std.mem.endsWith(u8, val, ".yml") or std.mem.endsWith(u8, val, ".yaml")))
                {
                    try append_unique(allocator, imports, val);
                }
                break;
            }
        }
    }
}

/// Jinja template references: `{% extends "x" %}`, `{% include "x" %}`,
/// `{% import "x" %}`, `{% from "x" import ... %}`.
fn extract_jinja(allocator: std.mem.Allocator, content: []const u8, imports: *std.ArrayList([]const u8)) !void {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, content, i, "{%")) |pos| {
        const end = std.mem.indexOfPos(u8, content, pos, "%}") orelse break;
        const seg = std.mem.trim(u8, content[pos + 2 .. end], " \t");
        if (std.mem.startsWith(u8, seg, "extends") or std.mem.startsWith(u8, seg, "include") or
            std.mem.startsWith(u8, seg, "import") or std.mem.startsWith(u8, seg, "from"))
        {
            if (extract_quoted(seg)) |q| try append_unique(allocator, imports, q);
        }
        i = end + 2;
    }
}

/// Read the path token following `import ` in Nix (e.g. `import ./lib/x.nix`).
fn extract_nix(allocator: std.mem.Allocator, content: []const u8, imports: *std.ArrayList([]const u8)) !void {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, content, i, "import ")) |pos| {
        var j = pos + "import ".len;
        while (j < content.len and (content[j] == ' ' or content[j] == '\t' or content[j] == '(')) : (j += 1) {}
        const start = j;
        while (j < content.len and content[j] != ' ' and content[j] != '\t' and content[j] != ';' and
            content[j] != ')' and content[j] != '\n' and content[j] != '}') : (j += 1)
        {}
        const tok = content[start..j];
        // Only relative/absolute path refs (skip `<nixpkgs>` and bare names).
        if (tok.len > 0 and (tok[0] == '.' or tok[0] == '/')) try append_unique(allocator, imports, tok);
        i = pos + "import ".len;
    }
}

/// `@import "x.css"` / `@import url("x.css")` — first quoted spec on the line.
fn extract_at_import(allocator: std.mem.Allocator, content: []const u8, imports: *std.ArrayList([]const u8)) !void {
    var line_it = std.mem.splitScalar(u8, content, '\n');
    while (line_it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, t, "@import")) {
            if (extract_quoted(t)) |q| try append_unique(allocator, imports, q);
        }
    }
}

/// SCSS `@use`/`@import`/`@forward 'partial'`.
fn extract_scss(allocator: std.mem.Allocator, content: []const u8, imports: *std.ArrayList([]const u8)) !void {
    var line_it = std.mem.splitScalar(u8, content, '\n');
    while (line_it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, t, "@use") or std.mem.startsWith(u8, t, "@import") or std.mem.startsWith(u8, t, "@forward")) {
            if (extract_quoted(t)) |q| try append_unique(allocator, imports, q);
        }
    }
}

/// Bash `source x.sh` and `. x.sh`.
fn extract_bash(allocator: std.mem.Allocator, content: []const u8, imports: *std.ArrayList([]const u8)) !void {
    var line_it = std.mem.splitScalar(u8, content, '\n');
    while (line_it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        var rest: ?[]const u8 = null;
        if (std.mem.startsWith(u8, t, "source ")) rest = t["source ".len..]
        else if (std.mem.startsWith(u8, t, ". ")) rest = t[". ".len..];
        if (rest) |r| {
            var tok = std.mem.trim(u8, r, " \t\"'");
            if (std.mem.indexOfAny(u8, tok, " \t")) |s| tok = tok[0..s];
            if (tok.len > 0) try append_unique(allocator, imports, tok);
        }
    }
}

/// Make `include x.mk` / `-include x.mk` (may list several).
fn extract_make(allocator: std.mem.Allocator, content: []const u8, imports: *std.ArrayList([]const u8)) !void {
    var line_it = std.mem.splitScalar(u8, content, '\n');
    while (line_it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        var rest: ?[]const u8 = null;
        if (std.mem.startsWith(u8, t, "include ")) rest = t["include ".len..]
        else if (std.mem.startsWith(u8, t, "-include ")) rest = t["-include ".len..]
        else if (std.mem.startsWith(u8, t, "sinclude ")) rest = t["sinclude ".len..];
        if (rest) |r| {
            var part_it = std.mem.splitScalar(u8, std.mem.trim(u8, r, " \t"), ' ');
            while (part_it.next()) |p| {
                const tok = std.mem.trim(u8, p, " \t");
                if (tok.len > 0) try append_unique(allocator, imports, tok);
            }
        }
    }
}

/// HTML `src="..."` and `href="..."` (scripts, stylesheets).
fn extract_html(allocator: std.mem.Allocator, content: []const u8, imports: *std.ArrayList([]const u8)) !void {
    for ([_][]const u8{ "src=", "href=" }) |attr| {
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, content, i, attr)) |pos| {
            const after = pos + attr.len;
            const win_end = @min(after + 512, content.len);
            if (extract_quoted(content[after..win_end])) |q| {
                // Only same-repo refs, not http(s):// or protocol-relative URLs.
                if (!std.mem.startsWith(u8, q, "http") and !std.mem.startsWith(u8, q, "//"))
                    try append_unique(allocator, imports, q);
            }
            i = after;
        }
    }
}

/// HCL/Terraform `source = "./modules/x"` (module references).
fn extract_hcl(allocator: std.mem.Allocator, content: []const u8, imports: *std.ArrayList([]const u8)) !void {
    var line_it = std.mem.splitScalar(u8, content, '\n');
    while (line_it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, t, "source") and std.mem.indexOfScalar(u8, t, '=') != null) {
            if (extract_quoted(t)) |q| {
                // Local module paths only (skip registry/git sources).
                if (q.len > 0 and (q[0] == '.' or q[0] == '/')) try append_unique(allocator, imports, q);
            }
        }
    }
}

/// R `source("x.R")`.
fn extract_r(allocator: std.mem.Allocator, content: []const u8, imports: *std.ArrayList([]const u8)) !void {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, content, i, "source(")) |pos| {
        const after = pos + "source(".len;
        const win_end = @min(after + 512, content.len);
        if (extract_quoted(content[after..win_end])) |q| try append_unique(allocator, imports, q);
        i = after;
    }
}

/// Protobuf: `import "foo/bar.proto";` (and `import public "..."`).
fn extract_proto(allocator: std.mem.Allocator, content: []const u8, imports: *std.ArrayList([]const u8)) !void {
    var line_it = std.mem.splitScalar(u8, content, '\n');
    while (line_it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, t, "import ")) continue;
        if (extract_quoted(t)) |q| try append_unique(allocator, imports, q);
    }
}

/// Solidity: `import "./X.sol";`, `import {A,B} from "./C.sol";`, `import * as Y
/// from "..."`. In every form the source path is the first quoted string.
fn extract_solidity(allocator: std.mem.Allocator, content: []const u8, imports: *std.ArrayList([]const u8)) !void {
    var line_it = std.mem.splitScalar(u8, content, '\n');
    while (line_it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, t, "import ")) continue;
        if (extract_quoted(t)) |q| try append_unique(allocator, imports, q);
    }
}

fn extract_ruby(allocator: std.mem.Allocator, content: []const u8, imports: *std.ArrayList([]const u8)) !void {
    var line_it = std.mem.splitScalar(u8, content, '\n');
    while (line_it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        const rest = if (std.mem.startsWith(u8, t, "require_relative "))
            t["require_relative ".len..]
        else if (std.mem.startsWith(u8, t, "require "))
            t["require ".len..]
        else
            continue;
        if (extract_quoted(rest)) |q| try append_unique(allocator, imports, q);
    }
}

/// `import a.b.C` (Kotlin/Java-ish). Captures the dotted path up to whitespace,
/// `;`, or `as`. Wildcards/aliases are kept as-is; the resolver handles them.
fn extract_line_import(allocator: std.mem.Allocator, content: []const u8, imports: *std.ArrayList([]const u8)) !void {
    var line_it = std.mem.splitScalar(u8, content, '\n');
    while (line_it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, t, "import ")) continue;
        var rest = std.mem.trim(u8, t["import ".len..], " \t");
        if (std.mem.indexOfScalar(u8, rest, ';')) |s| rest = rest[0..s];
        if (std.mem.indexOf(u8, rest, " as ")) |a| rest = rest[0..a];
        rest = std.mem.trim(u8, rest, " \t");
        try append_unique(allocator, imports, rest);
    }
}

fn extract_scala(allocator: std.mem.Allocator, content: []const u8, imports: *std.ArrayList([]const u8)) !void {
    var line_it = std.mem.splitScalar(u8, content, '\n');
    while (line_it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, t, "import ")) continue;
        var rest = std.mem.trim(u8, t["import ".len..], " \t");
        // `import a.b.{X, Y}` / `import a.b._` → keep the package root `a.b`.
        if (std.mem.indexOfScalar(u8, rest, '{')) |b| rest = std.mem.trim(u8, rest[0..b], " \t.");
        try append_unique(allocator, imports, rest);
    }
}

fn extract_dart(allocator: std.mem.Allocator, content: []const u8, imports: *std.ArrayList([]const u8)) !void {
    var line_it = std.mem.splitScalar(u8, content, '\n');
    while (line_it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, t, "import ") or
            std.mem.startsWith(u8, t, "export ") or
            std.mem.startsWith(u8, t, "part "))
        {
            if (extract_quoted(t)) |q| try append_unique(allocator, imports, q);
        }
    }
}

fn extract_lua(allocator: std.mem.Allocator, content: []const u8, imports: *std.ArrayList([]const u8)) !void {
    // `require('a.b')`, `require "a.b"`, `local m = require 'a.b'`
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, content, i, "require")) |pos| {
        const after = pos + "require".len;
        const window_end = @min(after + 256, content.len);
        if (extract_quoted(content[after..window_end])) |q| {
            try append_unique(allocator, imports, q);
        }
        i = after;
    }
}

fn extract_zig(allocator: std.mem.Allocator, content: []const u8, imports: *std.ArrayList([]const u8)) !void {
    // Capture the spec inside `@import("...")`. Non-file specs (std, builtin,
    // package names) are extracted too but the resolver ignores them.
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, content, i, "@import(")) |pos| {
        var j = pos + "@import(".len;
        while (j < content.len and (content[j] == ' ' or content[j] == '\t')) : (j += 1) {}
        if (j < content.len and content[j] == '"') {
            const start = j + 1;
            var k = start;
            while (k < content.len and content[k] != '"') : (k += 1) {}
            if (k < content.len) {
                try append_unique(allocator, imports, content[start..k]);
                i = k + 1;
                continue;
            }
        }
        i = pos + "@import(".len;
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

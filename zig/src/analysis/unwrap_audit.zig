const std = @import("std");
const explorer = @import("../index/explorer.zig");

pub const Severity = enum {
    critical,
    high,
    medium,
    info,

    pub fn as_str(self: Severity) []const u8 {
        return switch (self) {
            .critical => "critical",
            .high => "high",
            .medium => "medium",
            .info => "info",
        };
    }
};

pub const Kind = enum {
    unwrap,
    expect,
    panic,

    pub fn as_str(self: Kind) []const u8 {
        return switch (self) {
            .unwrap => "Unwrap",
            .expect => "Expect",
            .panic => "Panic",
        };
    }
};

pub const Finding = struct {
    file: []const u8,
    line: usize,
    line_text: []const u8,
    kind: Kind,
    severity: Severity,
    scope: ?[]const u8 = null,
};

const Pattern = struct {
    text: []const u8,
    kind: Kind,
};

const patterns = [_]Pattern{
    .{ .text = ".unwrap()", .kind = .unwrap },
    .{ .text = ".expect(", .kind = .expect },
    .{ .text = "panic!(", .kind = .panic },
    .{ .text = "unreachable!(", .kind = .panic },
    .{ .text = "todo!(", .kind = .panic },
};

pub fn audit(allocator: std.mem.Allocator, exp: *explorer.Explorer) ![]Finding {
    var findings = std.ArrayList(Finding).empty;

    var it = exp.outlines.iterator();
    while (it.next()) |entry| {
        const file_id = entry.key_ptr.*;
        if (exp.deleted_files.get(file_id) != null) continue;
        const outline = entry.value_ptr.*;

        // Only scan Rust files
        if (outline.language != .rust) continue;

        const content = exp.content_cache.get(file_id) orelse continue;
        const is_test_file = std.mem.indexOf(u8, outline.path, "test") != null;
        const is_main = std.mem.endsWith(u8, outline.path, "main.rs");

        var line_num: usize = 1;
        var in_test_block = false;
        var line_it = std.mem.splitScalar(u8, content, '\n');
        while (line_it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t");

            // Track #[test] / #[cfg(test)] blocks
            if (std.mem.indexOf(u8, trimmed, "#[test]") != null or
                std.mem.indexOf(u8, trimmed, "#[cfg(test)]") != null or
                std.mem.indexOf(u8, trimmed, "#[tokio::test]") != null)
            {
                in_test_block = true;
            }

            // Skip comments
            if (std.mem.startsWith(u8, trimmed, "//") or std.mem.startsWith(u8, trimmed, "/*")) {
                line_num += 1;
                continue;
            }

            for (&patterns) |pat| {
                if (std.mem.indexOf(u8, line, pat.text) != null) {
                    const severity: Severity = if (is_test_file or in_test_block)
                        .info
                    else if (is_main)
                        .info
                    else if (std.mem.indexOf(u8, outline.path, "gateway") != null or
                        std.mem.indexOf(u8, outline.path, "api") != null)
                        .critical
                    else
                        .medium;

                    // Find enclosing scope
                    const scope = blk: {
                        for (outline.symbols) |sym| {
                            // line_num counts from 1, symbol ranges are 0-based
                            // — compare in the 1-based space.
                            if (sym.contains_1(line_num)) {
                                break :blk sym.name;
                            }
                        }
                        break :blk null;
                    };

                    try findings.append(allocator, .{
                        .file = outline.path,
                        .line = line_num,
                        .line_text = trimmed,
                        .kind = pat.kind,
                        .severity = severity,
                        .scope = scope,
                    });
                }
            }
            line_num += 1;
        }
    }

    return try findings.toOwnedSlice(allocator);
}

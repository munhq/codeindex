const std = @import("std");
const explorer = @import("../index/explorer.zig");
const models = @import("../core/models.zig");

pub const Severity = enum {
    critical,
    high,
    medium,
    low,

    pub fn as_str(self: Severity) []const u8 {
        return switch (self) {
            .critical => "critical",
            .high => "high",
            .medium => "medium",
            .low => "low",
        };
    }
};

pub const Finding = struct {
    file: []const u8,
    line: usize,
    line_text: []const u8,
    rule: []const u8,
    severity: Severity,
};

pub const Summary = struct {
    total: usize = 0,
    critical: usize = 0,
    high: usize = 0,
    medium: usize = 0,
    low: usize = 0,
};

const Rule = struct {
    pattern: []const u8,
    name: []const u8,
    severity: Severity,
    case_insensitive: bool = false,
};

const rules = [_]Rule{
    .{ .pattern = "unsafe {", .name = "unsafe_block", .severity = .medium },
    .{ .pattern = "unsafe{", .name = "unsafe_block", .severity = .medium },
    .{ .pattern = "eval(", .name = "eval_usage", .severity = .high },
    .{ .pattern = "eval (", .name = "eval_usage", .severity = .high },
    .{ .pattern = "dbg!(", .name = "debug_in_prod", .severity = .low },
    .{ .pattern = "console.log(", .name = "debug_in_prod", .severity = .low },
    .{ .pattern = "cors::any()", .name = "cors_wildcard", .severity = .high },
    .{ .pattern = "Access-Control-Allow-Origin: *", .name = "cors_wildcard", .severity = .high },
    .{ .pattern = "password = \"", .name = "hardcoded_secret", .severity = .critical, .case_insensitive = true },
    .{ .pattern = "secret = \"", .name = "hardcoded_secret", .severity = .critical, .case_insensitive = true },
    .{ .pattern = "api_key = \"", .name = "hardcoded_secret", .severity = .critical, .case_insensitive = true },
    .{ .pattern = "token = \"", .name = "hardcoded_secret", .severity = .critical, .case_insensitive = true },
    .{ .pattern = "password=\"", .name = "hardcoded_secret", .severity = .critical, .case_insensitive = true },
    .{ .pattern = "secret=\"", .name = "hardcoded_secret", .severity = .critical, .case_insensitive = true },
    .{ .pattern = "exec(", .name = "command_injection", .severity = .high },
    .{ .pattern = "subprocess.call(", .name = "command_injection", .severity = .high },
    .{ .pattern = "os.system(", .name = "command_injection", .severity = .high },
    .{ .pattern = "innerHTML", .name = "xss_risk", .severity = .medium },
    .{ .pattern = "dangerouslySetInnerHTML", .name = "xss_risk", .severity = .medium },
};

pub fn scan(allocator: std.mem.Allocator, exp: *explorer.Explorer) ![]Finding {
    var findings = std.ArrayList(Finding){};

    var it = exp.outlines.iterator();
    while (it.next()) |entry| {
        const file_id = entry.key_ptr.*;
        if (exp.deleted_files.get(file_id) != null) continue;
        const outline = entry.value_ptr.*;

        // Skip test and analysis files (which contain rule patterns as string literals)
        if (std.mem.indexOf(u8, outline.path, "test") != null) continue;
        if (std.mem.indexOf(u8, outline.path, "analysis/") != null) continue;
        if (std.mem.indexOf(u8, outline.path, "analysis\\") != null) continue;

        const content = exp.content_cache.get(file_id) orelse continue;

        var line_num: usize = 1;
        var line_it = std.mem.splitScalar(u8, content, '\n');
        while (line_it.next()) |line| {
            for (&rules) |rule| {
                const found = if (rule.case_insensitive)
                    containsInsensitive(line, rule.pattern)
                else
                    std.mem.indexOf(u8, line, rule.pattern) != null;

                if (found) {
                    try findings.append(allocator, .{
                        .file = outline.path,
                        .line = line_num,
                        .line_text = line,
                        .rule = rule.name,
                        .severity = rule.severity,
                    });
                }
            }
            line_num += 1;
        }
    }

    return try findings.toOwnedSlice(allocator);
}

pub fn summarize(findings: []const Finding) Summary {
    var s = Summary{};
    s.total = findings.len;
    for (findings) |f| {
        switch (f.severity) {
            .critical => s.critical += 1,
            .high => s.high += 1,
            .medium => s.medium += 1,
            .low => s.low += 1,
        }
    }
    return s;
}

fn containsInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var match = true;
        for (0..needle.len) |j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

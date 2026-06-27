const std = @import("std");
const explorer = @import("../index/explorer.zig");
const models = @import("../core/models.zig");
const io = @import("../core/io.zig");

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
    line_text: []const u8, // borrowed into the per-file content buffer
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
    // ── Hardcoded secrets / leaked credentials (high-signal prefixes) ──────────
    .{ .pattern = "-----BEGIN", .name = "private_key_block", .severity = .critical }, // PEM keys
    .{ .pattern = "sk_live_", .name = "stripe_live_key", .severity = .critical },
    .{ .pattern = "ghp_", .name = "github_token", .severity = .high },
    .{ .pattern = "xoxb-", .name = "slack_token", .severity = .high },
    .{ .pattern = "AIza", .name = "google_api_key", .severity = .high },
    .{ .pattern = "password = \"", .name = "hardcoded_secret", .severity = .critical, .case_insensitive = true },
    .{ .pattern = "secret = \"", .name = "hardcoded_secret", .severity = .critical, .case_insensitive = true },
    .{ .pattern = "api_key = \"", .name = "hardcoded_secret", .severity = .critical, .case_insensitive = true },
    // ── Injection / unsafe execution ──────────────────────────────────────────
    .{ .pattern = "eval(", .name = "eval_usage", .severity = .high },
    .{ .pattern = "exec(", .name = "command_injection", .severity = .high },
    .{ .pattern = "os.system(", .name = "command_injection", .severity = .high },
    .{ .pattern = "subprocess.call(", .name = "command_injection", .severity = .high },
    .{ .pattern = "innerHTML", .name = "xss_risk", .severity = .medium },
    .{ .pattern = "dangerouslySetInnerHTML", .name = "xss_risk", .severity = .medium },
    .{ .pattern = "unsafe {", .name = "unsafe_block", .severity = .low },
    .{ .pattern = "cors::any()", .name = "cors_wildcard", .severity = .high },
    // ── Solidity / smart-contract specific ────────────────────────────────────
    .{ .pattern = "tx.origin", .name = "solidity_tx_origin_auth", .severity = .high },
    .{ .pattern = "selfdestruct(", .name = "solidity_selfdestruct", .severity = .high },
    .{ .pattern = "suicide(", .name = "solidity_selfdestruct", .severity = .high },
    .{ .pattern = "delegatecall(", .name = "solidity_delegatecall", .severity = .high },
    .{ .pattern = ".call{value", .name = "solidity_low_level_call", .severity = .medium },
    .{ .pattern = "blockhash(", .name = "solidity_weak_randomness", .severity = .medium },
    .{ .pattern = "block.timestamp", .name = "solidity_timestamp_dependence", .severity = .low },
    .{ .pattern = "encodePacked(", .name = "solidity_hash_collision_risk", .severity = .low, .case_insensitive = true },
};

pub fn scan(allocator: std.mem.Allocator, exp: *explorer.Explorer) ![]Finding {
    var findings = std.ArrayList(Finding).empty;
    // Findings borrow into per-file buffers; keep them alive for the report.
    // (Caller frees via free_findings.)
    var it = exp.outlines.iterator();
    while (it.next()) |entry| {
        const file_id = entry.key_ptr.*;
        if (exp.deleted_files.get(file_id) != null) continue;
        const outline = entry.value_ptr.*;

        // Skip our own analysis sources (rule patterns as literals), example/
        // sample env files (placeholders), and test files (mock secrets = noise).
        if (std.mem.indexOf(u8, outline.path, "/analysis/") != null) continue;
        if (std.mem.indexOf(u8, outline.path, ".example") != null) continue;
        if (std.mem.indexOf(u8, outline.path, ".sample") != null) continue;
        const base = std.fs.path.basename(outline.path);
        if (std.mem.startsWith(u8, base, "test") or
            std.mem.indexOf(u8, outline.path, "/test") != null or
            std.mem.indexOf(u8, outline.path, "_test.") != null or
            std.mem.indexOf(u8, outline.path, ".test.") != null or
            std.mem.indexOf(u8, outline.path, "/spec") != null) continue;

        // Prefer the in-memory indexed content (authoritative, handles unsaved
        // edits); fall back to disk for files evicted from the bounded cache so
        // coverage isn't limited to what's currently cached.
        const cached = exp.content_cache.get(file_id);
        const content = cached orelse (io.readFileAlloc(allocator, outline.path, 10 * 1024 * 1024) catch continue);
        defer if (cached == null) allocator.free(content);

        var line_num: usize = 1;
        var line_it = std.mem.splitScalar(u8, content, '\n');
        while (line_it.next()) |line| {
            for (&rules) |rule| {
                const hit = if (rule.case_insensitive)
                    containsInsensitive(line, rule.pattern)
                else
                    std.mem.indexOf(u8, line, rule.pattern) != null;
                if (hit) try findings.append(allocator, .{
                    .file = outline.path,
                    .line = line_num,
                    .line_text = try capture_line(allocator, line),
                    .rule = rule.name,
                    .severity = rule.severity,
                });
            }
            // Custom detectors that need structure, not a fixed substring.
            if (env_secret(line)) |sev| try findings.append(allocator, .{
                .file = outline.path,
                .line = line_num,
                .line_text = try capture_line(allocator, line),
                .rule = "hardcoded_secret_assignment",
                .severity = sev,
            });
            if (aws_access_key(line)) try findings.append(allocator, .{
                .file = outline.path,
                .line = line_num,
                .line_text = try capture_line(allocator, line),
                .rule = "aws_access_key",
                .severity = .critical,
            });
            line_num += 1;
        }
    }

    return try findings.toOwnedSlice(allocator);
}

/// Owned, trimmed, length-capped copy of a matched line — the finding's
/// evidence snippet. Owned (not borrowed) because the per-file content buffer
/// may be a transient disk read that's freed before the finding is emitted.
fn capture_line(allocator: std.mem.Allocator, line: []const u8) ![]const u8 {
    const t = std.mem.trim(u8, line, " \t\r");
    const n = @min(t.len, 240);
    return allocator.dupe(u8, t[0..n]);
}

/// Frees findings produced by `scan`, including each owned `line_text`.
pub fn free_findings(allocator: std.mem.Allocator, findings: []Finding) void {
    for (findings) |f| allocator.free(f.line_text);
    allocator.free(findings);
}

/// `NAME=value` / `NAME: value` where NAME names a secret and value looks real
/// (not a placeholder or an env reference). Catches the secrets that live in
/// `.env` files and config.
pub fn env_secret(line: []const u8) ?Severity {
    const t = std.mem.trim(u8, line, " \t\r");
    if (t.len == 0 or t[0] == '#' or std.mem.startsWith(u8, t, "//")) return null;
    const sep = std.mem.indexOfScalar(u8, t, '=') orelse std.mem.indexOfScalar(u8, t, ':') orelse return null;
    const name = std.mem.trim(u8, t[0..sep], " \t\"'");
    const val = std.mem.trim(u8, t[sep + 1 ..], " \t\r\"',;");
    if (name.len == 0 or name.len > 64) return null;
    // A real literal value: not empty, not an env/template reference, long enough.
    if (val.len < 8) return null;
    if (std.mem.startsWith(u8, val, "${") or std.mem.startsWith(u8, val, "$(") or
        val[0] == '<' or val[0] == '{' or std.mem.indexOfScalar(u8, val, '(') != null) return null;
    for ([_][]const u8{ "example", "your_", "your-", "changeme", "placeholder", "xxxx", "dummy", "redacted", "<", "..." }) |ph| {
        if (containsInsensitive(val, ph)) return null;
    }
    // Name must signal a secret.
    if (containsInsensitive(name, "private_key") or containsInsensitive(name, "privkey") or
        containsInsensitive(name, "mnemonic") or containsInsensitive(name, "seed_phrase") or
        containsInsensitive(name, "secret") or containsInsensitive(name, "password") or
        containsInsensitive(name, "passwd")) return .critical;
    if (containsInsensitive(name, "api_key") or containsInsensitive(name, "apikey") or
        containsInsensitive(name, "access_key") or containsInsensitive(name, "auth_token") or
        containsInsensitive(name, "credential") or std.mem.endsWith(u8, name, "_TOKEN") or
        std.mem.endsWith(u8, name, "_KEY")) return .high;
    return null;
}

/// AWS access key id: `AKIA` + 16 uppercase alphanumerics.
fn aws_access_key(line: []const u8) bool {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, line, i, "AKIA")) |pos| {
        const rest = line[pos + 4 ..];
        if (rest.len >= 16) {
            var ok = true;
            for (rest[0..16]) |c| {
                if (!(std.ascii.isUpper(c) or std.ascii.isDigit(c))) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        i = pos + 4;
    }
    return false;
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

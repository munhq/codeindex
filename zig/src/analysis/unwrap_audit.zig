const std = @import("std");
const explorer = @import("../index/explorer.zig");
const models = @import("../core/models.zig");

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

/// A file the test runner owns. `indexOf(path, "test")` also matches
/// `src/latest.rs` and `src/protest/mod.rs`, which are production code.
fn path_is_test(path: []const u8) bool {
    const basename = std.fs.path.basename(path);
    if (std.mem.indexOf(u8, basename, "_test.") != null) return true;
    if (std.mem.indexOf(u8, basename, ".test.") != null) return true;
    if (std.mem.startsWith(u8, basename, "test_")) return true;
    if (std.mem.eql(u8, basename, "tests.rs")) return true;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |component| {
        if (std.mem.eql(u8, component, "tests") or std.mem.eql(u8, component, "test")) return true;
    }
    return false;
}

fn brace_delta(line: []const u8) isize {
    var d: isize = 0;
    var in_single = false;
    var in_double = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (c == '\\') {
            i += 1;
            continue;
        }
        if (c == '\'' and !in_double) in_single = !in_single;
        if (c == '"' and !in_single) in_double = !in_double;
        if (in_single or in_double) continue;
        if (c == '{') d += 1;
        if (c == '}') d -= 1;
    }
    return d;
}

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
        const is_test_file = path_is_test(outline.path);
        const is_main = std.mem.endsWith(u8, outline.path, "main.rs");

        var line_num: usize = 1;
        // The brace depth the current test block opened at. An `#[cfg(test)]
        // mod` sits at the end of most files, so a flag that is set and never
        // cleared usually looks right — until a `#[test]` appears near the top,
        // and then every panic below it in production code reads as a test.
        var depth: isize = 0;
        var test_block_depth: ?isize = null;
        var pending_test_attr = false;
        var line_it = std.mem.splitScalar(u8, content, '\n');
        while (line_it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t");

            // The block closes when the depth returns to where it opened.
            if (test_block_depth) |opened_at| {
                if (depth <= opened_at) test_block_depth = null;
            }
            if (std.mem.indexOf(u8, trimmed, "#[test]") != null or
                std.mem.indexOf(u8, trimmed, "#[cfg(test)]") != null or
                std.mem.indexOf(u8, trimmed, "#[tokio::test]") != null or
                std.mem.indexOf(u8, trimmed, "#[rstest]") != null)
            {
                pending_test_attr = true;
            } else if (pending_test_attr and trimmed.len > 0 and trimmed[0] != '#') {
                // The item the attribute applies to starts here.
                if (test_block_depth == null) test_block_depth = depth;
                pending_test_attr = false;
            }
            const in_test_block = test_block_depth != null;
            const depth_after = depth + brace_delta(line);
            defer depth = depth_after;

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

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn one_rust_file(allocator: std.mem.Allocator, path: []const u8, src: []const u8) !models.FileOutline {
    return .{
        .path = try allocator.dupe(u8, path),
        .language = .rust,
        .line_count = std.mem.count(u8, src, "\n") + 1,
        .byte_size = src.len,
        .symbols = &[_]models.Symbol{},
        .imports = &[_][]const u8{},
    };
}

test "unwrap_audit: a test block closes at its brace" {
    const allocator = testing.allocator;
    // A `#[test] fn` near the top used to latch the flag for the whole file, so
    // the production `unwrap()` below it reported as `info`.
    const src =
        \\#[test]
        \\fn checks_parsing() {
        \\    parse("x").unwrap();
        \\}
        \\
        \\pub fn serve(req: Request) -> Response {
        \\    let cfg = load_config().unwrap();
        \\    Response::new(cfg)
        \\}
        \\
    ;
    var exp = try explorer.Explorer.init(allocator);
    defer exp.deinit();
    _ = try exp.add_file(try one_rust_file(allocator, "src/server.rs", src), src);
    exp.mark_indexing_complete();

    const findings = try audit(allocator, &exp);
    defer allocator.free(findings);
    try testing.expectEqual(@as(usize, 2), findings.len);
    try testing.expectEqual(@as(usize, 3), findings[0].line);
    try testing.expectEqual(Severity.info, findings[0].severity);
    try testing.expectEqual(@as(usize, 7), findings[1].line);
    try testing.expectEqual(Severity.medium, findings[1].severity);
}

test "unwrap_audit: a `#[cfg(test)] mod` covers everything inside it" {
    const allocator = testing.allocator;
    const src =
        \\pub fn serve() -> u32 {
        \\    load().unwrap()
        \\}
        \\
        \\#[cfg(test)]
        \\mod tests {
        \\    use super::*;
        \\
        \\    #[test]
        \\    fn one() {
        \\        assert_eq!(serve(), parse("1").unwrap());
        \\    }
        \\
        \\    #[test]
        \\    fn two() {
        \\        assert_eq!(serve(), parse("2").unwrap());
        \\    }
        \\}
        \\
    ;
    var exp = try explorer.Explorer.init(allocator);
    defer exp.deinit();
    _ = try exp.add_file(try one_rust_file(allocator, "src/server.rs", src), src);
    exp.mark_indexing_complete();

    const findings = try audit(allocator, &exp);
    defer allocator.free(findings);
    try testing.expectEqual(@as(usize, 3), findings.len);
    try testing.expectEqual(Severity.medium, findings[0].severity);
    try testing.expectEqual(Severity.info, findings[1].severity);
    try testing.expectEqual(Severity.info, findings[2].severity);
}

test "unwrap_audit: `latest.rs` is not a test file" {
    try testing.expect(!path_is_test("src/providers/latest.rs"));
    try testing.expect(!path_is_test("src/protest/mod.rs"));
    try testing.expect(path_is_test("tests/integration.rs"));
    try testing.expect(path_is_test("src/db/tests.rs"));
    try testing.expect(path_is_test("pkg/store_test.go"));
}

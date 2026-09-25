//! Panic sites in Rust, ranked by what reaches them.
//!
//! `clippy::unwrap_used` finds an `.unwrap()` from its own line, and so did this
//! analysis: 2402 sites on a 991-file repository, with a severity guessed from
//! whether the path held `gateway` or `api`. What a line cannot say is whether
//! anything runs it. The call graph can, so the rank is the evidence:
//!
//!   critical  a request handler reaches it: one bad input takes the worker down
//!   high      a loop repeats it, or a function a loop calls
//!   medium    `main` reaches it: it fails at startup or on a code path from it
//!   low       no resolved call reaches it
//!   info      a test runs it

const std = @import("std");
const explorer = @import("../index/explorer.zig");
const models = @import("../core/models.zig");
const callgraph = @import("../index/callgraph.zig");

pub const Severity = enum {
    critical,
    high,
    medium,
    low,
    info,

    pub fn as_str(self: Severity) []const u8 {
        return @tagName(self);
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
    /// What reaches the site: "request handler", "loop" or "main". Null when
    /// nothing resolved does, or for a test.
    reached_from: ?[]const u8 = null,
    /// Distinct functions that reach the enclosing function through calls.
    callers: usize = 0,
    /// The unwrapped call takes only a literal: `Regex::new(r"\d+").unwrap()`,
    /// `"8080".parse().unwrap()`. No input can make it fail; an invalid
    /// literal fails on the first run.
    constant_input: bool = false,
};

/// Whether the call that `.unwrap()` or `.expect(` at `at` unwraps takes only
/// a literal. `line[at]` is the `.` of the unwrap.
fn unwraps_a_literal(line: []const u8, at: usize) bool {
    var i = at;
    // `"8080".parse()` and `"8080".parse::<u16>()`.
    const parse_forms = [_][]const u8{ ".parse()", ".parse::<" };
    for (&parse_forms) |pf| {
        if (i >= pf.len and std.mem.endsWith(u8, line[0..i], ")") and std.mem.indexOf(u8, line[0..i], pf) != null) {
            const pos = std.mem.lastIndexOf(u8, line[0..i], pf).?;
            if (pos > 0 and line[pos - 1] == '"') return true;
        }
    }
    // `Callee(<literal>)` right before the unwrap.
    while (i > 0 and line[i - 1] == ' ') i -= 1;
    if (i == 0 or line[i - 1] != ')') return false;
    i -= 1;
    if (i > 0 and line[i - 1] == '"') {
        // A string literal, raw or not: walk back to its opening quote.
        var j = i - 1;
        while (j > 0) {
            j -= 1;
            if (line[j] == '"' and (j == 0 or line[j - 1] != '\\')) break;
        } else return false;
        i = j;
        while (i > 0 and (line[i - 1] == 'r' or line[i - 1] == '#')) i -= 1;
    } else {
        const end = i;
        while (i > 0 and std.ascii.isDigit(line[i - 1])) i -= 1;
        if (i == end) return false;
    }
    if (i == 0 or line[i - 1] != '(') return false;
    i -= 1;
    // A constructor or parser named by path: `Regex::new(`, `Url::parse(`.
    // `map.get("key")` takes a literal too, and the map's contents decide.
    const name_end = i;
    while (i > 0 and ident_char(line[i - 1])) i -= 1;
    if (i == name_end) return false;
    return i >= 2 and line[i - 1] == ':' and line[i - 2] == ':';
}

/// Lines that register a handler by naming it: `.route("/x", get(list_users))`,
/// `app.get("/x", listUsers)`, `http.HandleFunc("/x", list)`.
const route_markers = [_][]const u8{
    ".route(",      ".service(",  ".to(",        "app.get(",     "app.post(",   "app.put(",
    "app.delete(",  "app.patch(", "router.get(", "router.post(", "router.put(", "router.delete(",
    ".HandleFunc(", ".Handle(",   ".add_route(",
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

/// Why the reach sets are what they are: the roots of each.
const Reach = struct {
    handler: []bool,
    loop: []bool,
    main: []bool,

    fn deinit(self: Reach, allocator: std.mem.Allocator) void {
        allocator.free(self.handler);
        allocator.free(self.loop);
        allocator.free(self.main);
    }
};

fn ident_char(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn compute_reach(allocator: std.mem.Allocator, exp: *explorer.Explorer, g: *const callgraph.Graph) !Reach {
    var handlers = std.ArrayList(u32).empty;
    defer handlers.deinit(allocator);
    var mains = std.ArrayList(u32).empty;
    defer mains.deinit(allocator);
    var loop_seeds = std.ArrayList(u32).empty;
    defer loop_seeds.deinit(allocator);

    var by_name = std.StringHashMap(std.ArrayList(u32)).init(allocator);
    defer {
        var vit = by_name.valueIterator();
        while (vit.next()) |v| v.deinit(allocator);
        by_name.deinit();
    }
    for (g.nodes, 0..) |n, i| {
        const id: u32 = @intCast(i);
        if (n.flags.registered) try handlers.append(allocator, id);
        if (std.mem.eql(u8, n.name, "main")) try mains.append(allocator, id);
        const gop = try by_name.getOrPut(n.name);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(allocator, id);
    }

    var it = exp.outlines.iterator();
    while (it.next()) |entry| {
        const file_id = entry.key_ptr.*;
        if (exp.deleted_files.get(file_id) != null) continue;
        const outline = entry.value_ptr.*;
        // A call a loop repeats seeds the loop set.
        if (outline.loops.len > 0) {
            for (outline.calls, 0..) |c, ci| {
                const t = g.target(file_id, ci) orelse continue;
                for (outline.loops) |l| {
                    if (l.repeats(c.line, c.col)) {
                        try loop_seeds.append(allocator, t);
                        break;
                    }
                }
            }
        }
        // A handler named on a route line.
        const content = exp.content_cache.get(file_id) orelse continue;
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            var routed = false;
            for (&route_markers) |m| {
                if (std.mem.indexOf(u8, line, m) != null) routed = true;
            }
            if (!routed) continue;
            var i: usize = 0;
            while (i < line.len) {
                if (!ident_char(line[i])) {
                    i += 1;
                    continue;
                }
                const start = i;
                while (i < line.len and ident_char(line[i])) i += 1;
                const word = line[start..i];
                // A named function passed as a value, not called here.
                if (i < line.len and line[i] == '(') continue;
                const ids = by_name.get(word) orelse continue;
                for (ids.items) |id| try handlers.append(allocator, id);
            }
        }
    }

    const handler = try callgraph.reachable(allocator, g, handlers.items);
    errdefer allocator.free(handler);
    const loop = try callgraph.reachable(allocator, g, loop_seeds.items);
    errdefer allocator.free(loop);
    const main = try callgraph.reachable(allocator, g, mains.items);
    return .{ .handler = handler, .loop = loop, .main = main };
}

pub fn audit(allocator: std.mem.Allocator, exp: *explorer.Explorer) ![]Finding {
    var findings = std.ArrayList(Finding).empty;
    errdefer findings.deinit(allocator);

    var graph = try callgraph.build(allocator, exp);
    defer graph.deinit();
    const reach = try compute_reach(allocator, exp, &graph);
    defer reach.deinit(allocator);
    var callers_of = std.AutoHashMap(u32, usize).init(allocator);
    defer callers_of.deinit();

    var it = exp.outlines.iterator();
    while (it.next()) |entry| {
        const file_id = entry.key_ptr.*;
        if (exp.deleted_files.get(file_id) != null) continue;
        const outline = entry.value_ptr.*;

        // Only scan Rust files
        if (outline.language != .rust) continue;

        const content = exp.content_of(allocator, file_id) orelse continue;
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
                    const line0: u32 = @intCast(line_num - 1);
                    const node = graph.enclosing(file_id, line0);
                    const in_loop = for (outline.loops) |l| {
                        if (l.repeats(line0, @intCast(std.mem.indexOf(u8, line, pat.text).?))) break true;
                    } else false;
                    const test_site = is_test_file or in_test_block;
                    const at = std.mem.indexOf(u8, line, pat.text).?;
                    const constant_input = pat.kind != .panic and unwraps_a_literal(line, at);
                    // A panic in `main.rs` stops the process at startup, where
                    // it is the error message.
                    const reached_from: ?[]const u8 = if (test_site or is_main)
                        null
                    else if (node != null and reach.handler[node.?])
                        "request handler"
                    else if (in_loop or (node != null and reach.loop[node.?]))
                        "loop"
                    else if (node != null and reach.main[node.?])
                        "main"
                    else
                        null;
                    const severity: Severity = if (test_site or is_main)
                        .info
                    else if (reached_from == null or constant_input)
                        .low
                    else if (std.mem.eql(u8, reached_from.?, "request handler"))
                        .critical
                    else if (std.mem.eql(u8, reached_from.?, "loop"))
                        .high
                    else
                        .medium;
                    const callers: usize = if (node) |n| blk: {
                        if (callers_of.get(n)) |c| break :blk c;
                        const c = try callgraph.caller_count(allocator, &graph, n);
                        try callers_of.put(n, c);
                        break :blk c;
                    } else 0;

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
                        .reached_from = reached_from,
                        .callers = callers,
                        .constant_input = constant_input,
                    });
                }
            }
            line_num += 1;
        }
    }

    const items = try findings.toOwnedSlice(allocator);
    // Most severe first; among equals, the one more functions reach.
    std.mem.sort(Finding, items, {}, struct {
        fn less(_: void, a: Finding, b: Finding) bool {
            if (a.severity != b.severity) return @intFromEnum(a.severity) < @intFromEnum(b.severity);
            if (a.callers != b.callers) return a.callers > b.callers;
            const o = std.mem.order(u8, a.file, b.file);
            if (o != .eq) return o == .lt;
            return a.line < b.line;
        }
    }.less);
    return items;
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
    // Sorted most severe first: the production site, then the test.
    try testing.expectEqual(@as(usize, 2), findings.len);
    try testing.expectEqual(@as(usize, 7), findings[0].line);
    try testing.expectEqual(Severity.low, findings[0].severity);
    try testing.expectEqual(@as(usize, 3), findings[1].line);
    try testing.expectEqual(Severity.info, findings[1].severity);
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
    try testing.expectEqual(Severity.low, findings[0].severity);
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

test "unwrap_audit: the rank is what reaches the site" {
    const treesitter = @import("../parser/treesitter.zig");
    var exp = try explorer.Explorer.init(testing.allocator);
    defer exp.deinit();
    const files = [_][2][]const u8{
        .{
            "/ws/src/api.rs",
            \\pub fn router() -> Router {
            \\    Router::new().route("/users", get(list_users))
            \\}
            \\async fn list_users() -> Json<Vec<User>> {
            \\    Json(load_users().unwrap())
            \\}
            \\fn load_users() -> Result<Vec<User>> { Ok(vec![]) }
            \\
        },
        .{
            "/ws/src/batch.rs",
            \\pub fn run(rows: Vec<Row>) {
            \\    for r in rows {
            \\        parse_row(&r);
            \\    }
            \\}
            \\fn parse_row(r: &Row) -> u32 {
            \\    r.value.parse().unwrap()
            \\}
            \\fn orphan() -> u32 { "1".parse().unwrap() }
            \\
        },
    };
    var parser = try treesitter.Parser.init(testing.allocator);
    defer parser.deinit();
    for (files) |f| _ = try exp.add_file(try parser.parse_source(f[0], .rust, f[1]), f[1]);
    exp.mark_indexing_complete();

    const findings = try audit(testing.allocator, &exp);
    defer testing.allocator.free(findings);
    try testing.expectEqual(@as(usize, 3), findings.len);
    try testing.expectEqual(Severity.critical, findings[0].severity);
    try testing.expectEqualStrings("request handler", findings[0].reached_from.?);
    try testing.expectEqual(@as(usize, 5), findings[0].line);
    try testing.expectEqual(Severity.high, findings[1].severity);
    try testing.expectEqualStrings("loop", findings[1].reached_from.?);
    try testing.expectEqual(@as(usize, 1), findings[1].callers);
    try testing.expectEqual(Severity.low, findings[2].severity);
}

test "unwrap_audit: an unwrap of a literal cannot fail on input" {
    const lines = [_][]const u8{
        "    regex: Regex::new(r\"sk-[a-z]{20,}\").unwrap(),",
        "let re = Regex::new(\"a+b\").expect(\"valid\");",
        "let port: u16 = \"8080\".parse().unwrap();",
        "let n = NonZeroU32::new(5).unwrap();",
    };
    for (lines) |l| {
        const at = std.mem.indexOf(u8, l, ".unwrap()") orelse std.mem.indexOf(u8, l, ".expect(").?;
        try testing.expect(unwraps_a_literal(l, at));
    }
    const input = [_][]const u8{
        "let cfg = load_config().unwrap();",
        "let v: u32 = body.parse().unwrap();",
        "let re = Regex::new(&pattern).unwrap();",
        "let x = map.get(\"key\").unwrap();",
    };
    for (input) |l| {
        const at = std.mem.indexOf(u8, l, ".unwrap()").?;
        try testing.expect(!unwraps_a_literal(l, at));
    }
}

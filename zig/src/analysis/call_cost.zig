//! Round trips a loop makes per element, counted through the calls it makes.
//!
//! The N+1 shape: a loop over rows that makes a database query or an HTTP
//! request for each one. A scan of the loop's own lines sees the query only
//! when it is written there. A loop that calls a function which queries holds
//! no query on any of its lines:
//!
//!     for row in rows {
//!         import_triple(row);   // 4 round trips, one per row
//!     }
//!
//! Every function gets the round trips written in its own body. The call graph
//! sums them through every call it makes, to a fixed point, so a loop's cost is
//! the sum of what its call sites cost. The count orders the findings: a loop
//! that makes 4 round trips per element outranks one that makes 1.

const std = @import("std");
const explorer = @import("../index/explorer.zig");
const models = @import("../core/models.zig");
const callgraph = @import("../index/callgraph.zig");
const txt = @import("text.zig");

pub const RoundTrip = enum {
    query,
    http,

    pub fn as_str(self: RoundTrip) []const u8 {
        return @tagName(self);
    }
};

/// Markers that execute a statement against a database.
///
/// A bare `.execute(` matched `tool.execute(call.arguments)` and every other
/// execute-shaped method, and it fired a second time on the `.execute(&pool)`
/// continuation of a `sqlx::query(…)` already counted. The markers below name
/// the query itself.
const query_calls = [_][]const u8{
    "sqlx::query",      ".fetch_one(",     ".fetch_all(",    ".fetch_optional(",
    ".query_row(",      "cursor.execute(", "session.query(", "db.query(",
    ".find_one(",       ".findOne(",       ".findMany(",     ".findUnique(",
    "QueryRowContext(", "QueryContext(",
};

/// Markers that put a request on the wire. `reqwest::` alone is a module path:
/// `reqwest::header::HeaderName::from_bytes` builds a header and sends nothing.
const http_calls = [_][]const u8{
    ".send().await",  ".send()?",      "reqwest::get(",    "requests.get(",
    "requests.post(", "requests.put(", "requests.delete(", "axios.get(",
    "axios.post(",    "axios.put(",    "axios.delete(",    "http.Get(",
    "http.Post(",     "urlopen(",      "await fetch(",
};

pub const Site = struct {
    /// 1-based.
    line: usize,
    /// The called function, or the marker kind for a round trip written on
    /// the loop's own line.
    callee: []const u8,
    /// Where the called function is defined; empty and 0 for a marker.
    callee_file: []const u8 = "",
    callee_line: usize = 0,
    round_trips: u64,
    /// The call path to where the round trips are written: `a → b → c`.
    /// Owned; empty for a round trip on the loop's own line.
    via: []const u8,
};

pub const Finding = struct {
    file: []const u8,
    /// 1-based line of the loop.
    line: usize,
    /// The loop's first line. Owned.
    header: []const u8,
    /// Round trips per element: the sum over `sites`.
    round_trips: u64,
    /// Costliest first. Owned.
    sites: []Site,
};

pub const Report = struct {
    findings: []Finding,
    /// Functions whose calls reach at least one round trip.
    functions_with_round_trips: usize,
    graph: callgraph.Stats,

    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        for (self.findings) |f| {
            allocator.free(f.header);
            for (f.sites) |s| allocator.free(s.via);
            allocator.free(f.sites);
        }
        allocator.free(self.findings);
    }
};

fn round_trip_in(t: []const u8) ?RoundTrip {
    if (txt.contains_any(t, &query_calls)) return .query;
    if (txt.contains_any(t, &http_calls)) return .http;
    if (global_fetch(t)) return .http;
    return null;
}

/// The Fetch API called as a function: `fetch(url)`, `window.fetch(url)`.
/// `refetch(` and `store.fetch(` are other functions.
fn global_fetch(t: []const u8) bool {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, t, pos, "fetch(")) |at| {
        pos = at + 1;
        if (at == 0) return true;
        const c = t[at - 1];
        if (txt.ident_char(c)) continue;
        if (c == '.') {
            if (std.mem.endsWith(u8, t[0..at], "window.") or std.mem.endsWith(u8, t[0..at], "globalThis.")) return true;
            continue;
        }
        return true;
    }
    return false;
}

/// The identifier a marker calls: `.fetch_one(` → `fetch_one`,
/// `sqlx::query` → `query`, `await fetch(` → `fetch`.
fn marker_name(t: []const u8) ?[]const u8 {
    if (!txt.contains_any(t, &query_calls) and !txt.contains_any(t, &http_calls) and global_fetch(t)) return "fetch";
    for ([_][]const []const u8{ &query_calls, &http_calls }) |set| {
        for (set) |m| {
            if (std.mem.indexOf(u8, t, m) == null) continue;
            var end = m.len;
            while (end > 0 and !txt.ident_char(m[end - 1])) end -= 1;
            var start = end;
            while (start > 0 and txt.ident_char(m[start - 1])) start -= 1;
            return m[start..end];
        }
    }
    return null;
}

/// Whether the marker on the 0-based line calls a repository function of its
/// own name. That line's round trips are the function's: a `.fetch_one(` that
/// calls the repository's own `fetch_one` was counted once as a marker and
/// once more through the callee.
fn marker_calls_repository(outline: models.FileOutline, g: *const callgraph.Graph, file_id: u32, line: u32, t: []const u8) bool {
    const name = marker_name(t) orelse return false;
    for (outline.calls, 0..) |c, ci| {
        if (c.line != line or !std.mem.eql(u8, c.name, name)) continue;
        if (g.target(file_id, ci) != null) return true;
    }
    return false;
}

/// Per 0-based line, the round trip that line starts. A statement counts
/// once however many lines it spans:
///
///     sqlx::query_scalar(
///         "SELECT …",
///     )
///     .bind(id)
///     .fetch_optional(&mut *txn)
///     .await?;
///
/// is one round trip. The SQL between the two markers ended the statement
/// under a rule that only followed `.`-continuation lines, and the
/// `.fetch_optional` was counted a second time.
fn round_trip_lines(allocator: std.mem.Allocator, lines: []const []const u8, lang: models.Language) ![]?RoundTrip {
    const out = try allocator.alloc(?RoundTrip, lines.len);
    @memset(out, null);
    const semicolons = ends_statements_with_semicolon(lang);
    var open = false;
    var depth: isize = 0;
    for (lines, 0..) |raw, i| {
        const t = std.mem.trim(u8, raw, " \t\r");
        if (t.len == 0 or txt.is_comment(t, lang)) continue;
        if (open and semicolons and starts_statement(t)) open = false;
        if (round_trip_in(t)) |kind| {
            if (!open) {
                out[i] = kind;
                open = true;
                depth = 0;
            }
        }
        if (open) {
            if (semicolons) {
                if (std.mem.endsWith(u8, t, ";")) open = false;
            } else {
                depth += paren_delta(t);
                const next_continues = i + 1 < lines.len and std.mem.startsWith(u8, std.mem.trimStart(u8, lines[i + 1], " \t"), ".");
                if (depth <= 0 and !next_continues) open = false;
            }
        }
    }
    return out;
}

fn ends_statements_with_semicolon(lang: models.Language) bool {
    return switch (lang) {
        .rust, .typescript, .javascript, .java, .c_sharp, .php, .c, .cpp => true,
        else => false,
    };
}

/// A line that begins a statement of its own, so the one before it has ended
/// even without a `;` (a Rust block's tail expression, a JavaScript line
/// with no semicolon).
fn starts_statement(t: []const u8) bool {
    const starts = [_][]const u8{ "let ", "const ", "var ", "return", "if ", "match ", "for ", "while ", "}", "await ", "async " };
    for (&starts) |p| {
        if (std.mem.startsWith(u8, t, p)) return true;
    }
    return false;
}

fn paren_delta(t: []const u8) isize {
    var d: isize = 0;
    var quote: u8 = 0;
    for (t) |c| {
        if (quote != 0) {
            if (c == quote) quote = 0;
            continue;
        }
        switch (c) {
            '"', '\'', '`' => quote = c,
            '(', '[', '{' => d += 1,
            ')', ']', '}' => d -= 1,
            else => {},
        }
    }
    return d;
}

fn has_round_trip_markers(lang: models.Language) bool {
    return switch (lang) {
        .rust, .python, .go, .typescript, .javascript, .java, .kotlin, .ruby, .c_sharp, .php => true,
        else => false,
    };
}

/// Whether the loop walks something whose length the source fixes: an array
/// literal, or a constant named in the screaming case a constant uses.
///
/// `for table in ["tasks", "goals"]` runs twice. `for pdef in PROVIDERS` runs
/// once per declared provider. Neither is an N+1, and five of the forty-two
/// loop findings on one repository were exactly this.
pub fn iterates_a_fixed_list(t: []const u8, keyword: []const u8) bool {
    const kw = std.mem.indexOf(u8, t, keyword) orelse return false;
    const it = std.mem.trimStart(u8, t[kw + keyword.len ..], " \t&*(");
    return fixed_operand(it);
}

/// An array literal, or an identifier with no lowercase letter.
fn fixed_operand(it: []const u8) bool {
    if (it.len == 0) return false;
    if (it[0] == '[') return true;
    var end: usize = 0;
    while (end < it.len and (txt.ident_char(it[end]) or it[end] == ':')) end += 1;
    const name = it[0..end];
    if (name.len == 0) return false;
    var has_letter = false;
    for (name) |c| {
        if (std.ascii.isLower(c)) return false;
        if (std.ascii.isAlphabetic(c)) has_letter = true;
    }
    return has_letter;
}

/// An `each` loop that walks rows, told from one that counts or walks a list
/// the source fixes.
pub fn walks_rows(header: []const u8, lang: models.Language) bool {
    const t = std.mem.trim(u8, header, " \t\r");
    // A callback loop: the receiver is the collection.
    const callbacks = [_][]const u8{ ".forEach(", ".map(", ".flatMap(", ".for_each(", ".try_for_each(", ".each" };
    for (&callbacks) |cb| {
        if (std.mem.indexOf(u8, t, cb)) |at| {
            const recv = std.mem.trimEnd(u8, t[0..at], " \t");
            if (recv.len > 0 and recv[recv.len - 1] == ']') return false;
            var s = recv.len;
            while (s > 0 and (txt.ident_char(recv[s - 1]) or recv[s - 1] == '.')) s -= 1;
            return !fixed_operand(recv[s..]);
        }
    }
    switch (lang) {
        .rust => if (std.mem.indexOf(u8, t, "..") != null) return false,
        .python => if (std.mem.indexOf(u8, t, "range(") != null) return false,
        .zig => {
            if (std.mem.indexOf(u8, t, "..") != null) return false;
            if (std.mem.indexOf(u8, t, "for (")) |at| return !fixed_operand(t[at + 5 ..]);
        },
        else => {},
    }
    const keywords = [_][]const u8{ " in ", " of ", " range ", " : " };
    for (&keywords) |kw| {
        if (std.mem.indexOf(u8, t, kw) != null) return !iterates_a_fixed_list(t, kw);
    }
    return true;
}

pub fn analyze(allocator: std.mem.Allocator, exp: *explorer.Explorer) !Report {
    var graph = try callgraph.build(allocator, exp);
    defer graph.deinit();

    // Pass 1: the round trips each function writes in its own body. A line
    // belongs to its innermost function, so a nested function's queries are
    // not counted twice.
    const own = try allocator.alloc(u64, graph.nodes.len);
    defer allocator.free(own);
    @memset(own, 0);
    var it = exp.outlines.iterator();
    while (it.next()) |entry| {
        const file_id = entry.key_ptr.*;
        if (exp.deleted_files.get(file_id) != null) continue;
        const outline = entry.value_ptr.*;
        if (!has_round_trip_markers(outline.language) or txt.is_excluded_path(outline.path)) continue;
        const content = exp.content_of(allocator, file_id) orelse continue;
        const lines = try txt.split_lines(allocator, content);
        defer allocator.free(lines);
        const trips = try round_trip_lines(allocator, lines, outline.language);
        defer allocator.free(trips);
        for (trips, 0..) |rt, i| {
            if (rt == null) continue;
            const line: u32 = @intCast(i);
            const node = graph.enclosing(file_id, line) orelse continue;
            if (in_repeating_loop(outline.loops, graph.nodes[node], line)) continue;
            if (marker_calls_repository(outline, &graph, file_id, line, lines[i])) continue;
            own[node] += 1;
        }
    }

    // A call inside the function's own `while` or `loop` runs an unknown
    // number of times per call, so it adds no fixed count. Without this, a loop
    // that starts one agent per task was charged the round trips of the agent's
    // whole mailbox loop: 170 per task on one repository.
    const skip = try allocator.alloc(bool, graph.edges.len);
    defer allocator.free(skip);
    @memset(skip, false);
    for (graph.nodes, 0..) |n, ni| {
        const outline = exp.outlines.get(n.file_id) orelse continue;
        const first = graph.out_start[ni];
        for (graph.out(@intCast(ni)), 0..) |e, k| {
            skip[first + k] = e.deferred or in_repeating_loop(outline.loops, n, e.line);
        }
    }

    // Pass 2: through the calls, to a fixed point.
    const reach = try callgraph.transitive(allocator, &graph, own, skip);
    defer allocator.free(reach);
    var with_trips: usize = 0;
    for (reach) |r| {
        if (r.total > 0) with_trips += 1;
    }

    // Pass 3: each loop over rows, and what its body costs per element.
    var findings = std.ArrayList(Finding).empty;
    errdefer {
        for (findings.items) |f| {
            allocator.free(f.header);
            for (f.sites) |s| allocator.free(s.via);
            allocator.free(f.sites);
        }
        findings.deinit(allocator);
    }
    var loops = std.ArrayList(models.Loop).empty;
    defer loops.deinit(allocator);

    var it2 = exp.outlines.iterator();
    while (it2.next()) |entry| {
        const file_id = entry.key_ptr.*;
        if (exp.deleted_files.get(file_id) != null) continue;
        const outline = entry.value_ptr.*;
        if (outline.loops.len == 0 or txt.is_excluded_path(outline.path)) continue;
        const content = exp.content_of(allocator, file_id) orelse continue;
        const lines = try txt.split_lines(allocator, content);
        defer allocator.free(lines);

        loops.clearRetainingCapacity();
        for (outline.loops) |l| {
            if (l.kind != .each or l.line_start >= lines.len) continue;
            if (!walks_rows(lines[l.line_start], outline.language)) continue;
            try loops.append(allocator, l);
        }
        if (loops.items.len == 0) continue;

        // One site list per loop. A list handed to a finding is empty here.
        const sites = try allocator.alloc(std.ArrayList(Site), loops.items.len);
        for (sites) |*ls| ls.* = .empty;
        defer {
            for (sites) |*ls| {
                for (ls.items) |site| allocator.free(site.via);
                ls.deinit(allocator);
            }
            allocator.free(sites);
        }

        // Calls into functions that make round trips.
        var costly_lines = std.AutoHashMap(u32, void).init(allocator);
        defer costly_lines.deinit();
        for (outline.calls, 0..) |call, ci| {
            if (call.deferred) continue;
            const target = graph.target(file_id, ci) orelse continue;
            const cost = reach[target].total;
            if (cost == 0) continue;
            const li = innermost(loops.items, call.line, call.col) orelse continue;
            const via = try callgraph.path_string(allocator, &graph, reach, target);
            errdefer allocator.free(via);
            try sites[li].append(allocator, .{
                .line = @as(usize, call.line) + 1,
                .callee = graph.nodes[target].name,
                .callee_file = graph.nodes[target].path,
                .callee_line = @as(usize, graph.nodes[target].line_start) + 1,
                .round_trips = cost,
                .via = via,
            });
            try costly_lines.put(call.line, {});
        }
        // Round trips written on the loop's own lines. A line whose call is
        // already counted through its callee is not counted again.
        if (has_round_trip_markers(outline.language)) {
            const trips = try round_trip_lines(allocator, lines, outline.language);
            defer allocator.free(trips);
            for (trips, 0..) |rt, i| {
                const kind = rt orelse continue;
                const line: u32 = @intCast(i);
                if (costly_lines.contains(line)) continue;
                const li = innermost(loops.items, line, marker_col(lines[i])) orelse continue;
                try sites[li].append(allocator, .{
                    .line = i + 1,
                    .callee = kind.as_str(),
                    .round_trips = 1,
                    .via = try allocator.dupe(u8, ""),
                });
            }
        }

        for (loops.items, sites) |l, *ls| {
            if (ls.items.len == 0) continue;
            var total: u64 = 0;
            for (ls.items) |s| total = @min(total + s.round_trips, callgraph.max_cost);
            std.mem.sort(Site, ls.items, {}, struct {
                fn less(_: void, a: Site, b: Site) bool {
                    if (a.round_trips != b.round_trips) return a.round_trips > b.round_trips;
                    return a.line < b.line;
                }
            }.less);
            const owned_sites = try ls.toOwnedSlice(allocator);
            errdefer {
                for (owned_sites) |s| allocator.free(s.via);
                allocator.free(owned_sites);
            }
            try findings.append(allocator, .{
                .file = outline.path,
                .line = @as(usize, l.line_start) + 1,
                .header = try allocator.dupe(u8, std.mem.trim(u8, lines[l.line_start], " \t\r")),
                .round_trips = total,
                .sites = owned_sites,
            });
        }
    }

    const items = try findings.toOwnedSlice(allocator);
    std.mem.sort(Finding, items, {}, struct {
        fn less(_: void, a: Finding, b: Finding) bool {
            if (a.round_trips != b.round_trips) return a.round_trips > b.round_trips;
            const order = std.mem.order(u8, a.file, b.file);
            if (order != .eq) return order == .lt;
            return a.line < b.line;
        }
    }.less);
    return .{ .findings = items, .functions_with_round_trips = with_trips, .graph = graph.stats };
}

/// Whether the 0-based line sits in a `conditional` or `forever` loop of the
/// function `node`.
fn in_repeating_loop(loops: []const models.Loop, node: callgraph.Node, line: u32) bool {
    for (loops) |l| {
        if (l.kind == .each) continue;
        if (l.line_start < node.line_start or l.line_end > node.line_end) continue;
        if (line >= l.line_start and line <= l.line_end) return true;
    }
    return false;
}

/// The innermost loop that repeats the 0-based position. Nested loops start
/// later, so the one with the latest start wins, and a round trip counts for
/// the loop that repeats it most closely. A position in a loop's header runs
/// once and belongs to no loop.
fn innermost(loops: []const models.Loop, line: u32, col: u32) ?usize {
    var best: ?usize = null;
    for (loops, 0..) |l, i| {
        if (!l.repeats(line, col)) continue;
        if (best == null or l.line_start >= loops[best.?].line_start) best = i;
    }
    return best;
}

/// The 0-based column of the first round-trip marker on a line.
fn marker_col(raw: []const u8) u32 {
    var best: usize = raw.len;
    for ([_][]const []const u8{ &query_calls, &http_calls }) |set| {
        for (set) |m| {
            if (std.mem.indexOf(u8, raw, m)) |at| best = @min(best, at);
        }
    }
    if (std.mem.indexOf(u8, raw, "fetch(")) |at| best = @min(best, at);
    return @intCast(if (best == raw.len) 0 else best);
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;
const treesitter = @import("../parser/treesitter.zig");

fn index(exp: *explorer.Explorer, files: []const [2][]const u8) !void {
    var parser = try treesitter.Parser.init(testing.allocator);
    defer parser.deinit();
    for (files) |f| {
        const o = try parser.parse_source(f[0], models.Language.from_path(f[0]), f[1]);
        _ = try exp.add_file(o, f[1]);
    }
    exp.mark_indexing_complete();
}

test "call_cost: a loop two calls from the query carries the transitive count" {
    var exp = try explorer.Explorer.init(testing.allocator);
    defer exp.deinit();
    try index(&exp, &.{
        .{
            "/ws/src/store.rs",
            \\pub async fn insert_node(p: &Pool, n: &Node) -> Result<()> {
            \\    sqlx::query("INSERT INTO nodes VALUES ($1)")
            \\        .bind(&n.id)
            \\        .execute(p).await?;
            \\    sqlx::query("INSERT INTO edges VALUES ($1)").bind(&n.id).execute(p).await?;
            \\    Ok(())
            \\}
            \\pub async fn import_triple(p: &Pool, t: &Triple) -> Result<()> {
            \\    insert_node(p, &t.subject).await?;
            \\    insert_node(p, &t.object).await?;
            \\    Ok(())
            \\}
            \\
        },
        .{
            "/ws/src/import.rs",
            \\use crate::store::import_triple;
            \\pub async fn import_all(p: &Pool, rows: Vec<Triple>) -> Result<()> {
            \\    for row in rows {
            \\        import_triple(p, &row).await?;
            \\    }
            \\    for i in 0..3 {
            \\        import_triple(p, &rows[i]).await?;
            \\    }
            \\    Ok(())
            \\}
            \\
        },
    });
    var report = try analyze(testing.allocator, &exp);
    defer report.deinit(testing.allocator);

    // The counted loop is not a loop over rows.
    try testing.expectEqual(@as(usize, 1), report.findings.len);
    const f = report.findings[0];
    try testing.expectEqualStrings("/ws/src/import.rs", f.file);
    try testing.expectEqual(@as(usize, 3), f.line);
    // Two inserts per node, two nodes per triple.
    try testing.expectEqual(@as(u64, 4), f.round_trips);
    try testing.expectEqual(@as(usize, 1), f.sites.len);
    try testing.expectEqual(@as(usize, 4), f.sites[0].line);
    try testing.expectEqualStrings("import_triple", f.sites[0].callee);
    // The query is two calls from the loop.
    try testing.expectEqualStrings("import_triple → insert_node", f.sites[0].via);
}

test "call_cost: a query written in the loop counts once per statement" {
    var exp = try explorer.Explorer.init(testing.allocator);
    defer exp.deinit();
    try index(&exp, &.{
        .{
            "/ws/src/load.rs",
            \\pub async fn load(ids: Vec<i64>, pool: &Pool) -> Vec<Row> {
            \\    let mut out = Vec::new();
            \\    for id in ids {
            \\        let row = sqlx::query_as("SELECT * FROM t WHERE id = ?")
            \\            .bind(id)
            \\            .fetch_one(pool).await?;
            \\        out.push(row);
            \\    }
            \\    out
            \\}
            \\
        },
    });
    var report = try analyze(testing.allocator, &exp);
    defer report.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), report.findings.len);
    try testing.expectEqual(@as(u64, 1), report.findings[0].round_trips);
    try testing.expectEqual(@as(usize, 4), report.findings[0].sites[0].line);
    try testing.expectEqualStrings("query", report.findings[0].sites[0].callee);
}

test "call_cost: a statement that spans lines counts once" {
    var exp = try explorer.Explorer.init(testing.allocator);
    defer exp.deinit();
    try index(&exp, &.{
        .{
            "/ws/src/plan.rs",
            \\pub async fn plan(tasks: Vec<Task>, txn: &mut Tx) -> Result<()> {
            \\    for task in tasks {
            \\        let dup: Option<String> = sqlx::query_scalar(
            \\            "SELECT id FROM tasks WHERE title = ?",
            \\        )
            \\        .bind(&task.title)
            \\        .fetch_optional(&mut *txn)
            \\        .await?;
            \\        sqlx::query("INSERT INTO tasks VALUES (?)").bind(&task.title).execute(&mut *txn).await?
            \\    }
            \\    Ok(())
            \\}
            \\
        },
        .{ "/ws/app/sync.py", "def sync(rows):\n    for r in rows:\n        cur = session.query(\n            Row,\n        ).filter(Row.id == r).fetch_one()\n        cursor.execute('x')\n" },
    });
    var report = try analyze(testing.allocator, &exp);
    defer report.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), report.findings.len);
    for (report.findings) |f| try testing.expectEqual(@as(u64, 2), f.round_trips);
}

test "call_cost: a loop over a fixed list is not an N+1" {
    var exp = try explorer.Explorer.init(testing.allocator);
    defer exp.deinit();
    try index(&exp, &.{
        .{
            "/ws/src/counts.rs",
            \\pub async fn counts(pool: &Pool) -> Result<()> {
            \\    for table in ["tasks", "goals"] {
            \\        let n = sqlx::query_scalar("SELECT count(*) FROM x").fetch_one(pool).await?;
            \\    }
            \\    for pdef in PROVIDERS {
            \\        let r = sqlx::query("SELECT 1").fetch_optional(pool).await?;
            \\    }
            \\    Ok(())
            \\}
            \\
        },
    });
    var report = try analyze(testing.allocator, &exp);
    defer report.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), report.findings.len);
}

test "call_cost: a round trip counts for the innermost loop only" {
    var exp = try explorer.Explorer.init(testing.allocator);
    defer exp.deinit();
    try index(&exp, &.{
        .{
            "/ws/src/sync.ts",
            \\export async function sync(teams: Team[]) {
            \\  for (const team of teams) {
            \\    await notify(team);
            \\    team.members.forEach(async (m) => {
            \\      await fetch(`/api/users/${m.id}`);
            \\    });
            \\  }
            \\}
            \\async function notify(t: Team) {
            \\  await fetch("/api/notify");
            \\  await fetch("/api/audit");
            \\}
            \\
        },
    });
    var report = try analyze(testing.allocator, &exp);
    defer report.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), report.findings.len);
    // `notify` costs 2 and outranks the inner loop's 1.
    try testing.expectEqual(@as(usize, 2), report.findings[0].line);
    try testing.expectEqual(@as(u64, 2), report.findings[0].round_trips);
    try testing.expectEqual(@as(usize, 4), report.findings[1].line);
    try testing.expectEqual(@as(u64, 1), report.findings[1].round_trips);
}

test "call_cost: a marker that calls the repository's own function counts once" {
    var exp = try explorer.Explorer.init(testing.allocator);
    defer exp.deinit();
    try index(&exp, &.{
        .{ "/ws/app/db.py", "def query(sql):\n    cursor.execute(sql)\n" },
        .{ "/ws/app/sync.py", "import db\ndef sync(rows):\n    for r in rows:\n        db.query(r)\n" },
    });
    var report = try analyze(testing.allocator, &exp);
    defer report.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), report.findings.len);
    try testing.expectEqual(@as(u64, 1), report.findings[0].round_trips);
    try testing.expectEqualStrings("query", report.findings[0].sites[0].callee);
    try testing.expectEqualStrings("query", report.findings[0].sites[0].via);
}

test "call_cost: a handler a loop renders is not called per element" {
    var exp = try explorer.Explorer.init(testing.allocator);
    defer exp.deinit();
    try index(&exp, &.{
        .{ "/ws/web/api.ts", "export function request(path: string) {\n  return fetch(path);\n}\nexport function save(id: string) {\n  return request(`/save/${id}`);\n}\n" },
        .{
            "/ws/web/List.tsx",
            \\import { save, request } from "./api";
            \\export function List({ rows }: Props) {
            \\  return <ul>{rows.map((r) => <li onClick={() => save(r.id)}>{r.name}</li>)}</ul>;
            \\}
            \\export async function warm(rows: Row[]) {
            \\  for (const r of rows) {
            \\    setTimeout(() => save(r.id), 10);
            \\    await request(`/row/${r.id}`);
            \\  }
            \\}
            \\
        },
    });
    var report = try analyze(testing.allocator, &exp);
    defer report.deinit(testing.allocator);
    // Only the awaited request in `warm` runs per element.
    try testing.expectEqual(@as(usize, 1), report.findings.len);
    try testing.expectEqual(@as(usize, 6), report.findings[0].line);
    try testing.expectEqual(@as(u64, 1), report.findings[0].round_trips);
    try testing.expectEqualStrings("request", report.findings[0].sites[0].callee);
}

test "call_cost: a call in the loop header runs once" {
    var exp = try explorer.Explorer.init(testing.allocator);
    defer exp.deinit();
    try index(&exp, &.{
        .{
            "/ws/src/jobs.rs",
            \\async fn busy_jobs(db: &Db) -> Result<Vec<Job>> { sqlx::query_as("SELECT 1").fetch_all(db).await }
            \\pub async fn plan(db: &Db) -> Result<()> {
            \\    for job in busy_jobs(db).await? {
            \\        println!("{job}");
            \\    }
            \\    Ok(())
            \\}
            \\
        },
    });
    var report = try analyze(testing.allocator, &exp);
    defer report.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), report.findings.len);
}

test "call_cost: rows are told apart from counted and fixed loops" {
    try testing.expect(walks_rows("for row in rows {", .rust));
    try testing.expect(!walks_rows("for i in 0..n {", .rust));
    try testing.expect(!walks_rows("for table in [\"tasks\", \"goals\"] {", .rust));
    try testing.expect(!walks_rows("for pdef in PROVIDERS {", .rust));
    try testing.expect(walks_rows("for r in &expired {", .rust));
    try testing.expect(!walks_rows("for i in range(10):", .python));
    try testing.expect(walks_rows("users.forEach((u) => {", .typescript));
    try testing.expect(!walks_rows("[1, 2].forEach((u) => {", .typescript));
    try testing.expect(!walks_rows("STATUSES.map(async (s) => {", .typescript));
    try testing.expect(walks_rows("for _, r := range rows {", .go));
}

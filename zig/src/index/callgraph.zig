//! Which function calls which, resolved across files.
//!
//! The parser records every call site with the name it calls
//! (`FileOutline.calls`). This module turns names into definitions. A name
//! resolves when exactly one definition fits, looked for in this order: the
//! caller's own file, the files the caller imports (two hops, so a re-export
//! through `mod.rs` or an `index.ts` still reaches the definition), and, for a
//! plain call only, the whole repository. A name that fits several definitions
//! resolves to none of them. Every consumer ranks or counts by these edges, and
//! a wrong edge moves a cost onto a function that never pays it.

const std = @import("std");
const models = @import("../core/models.zig");
const explorer = @import("explorer.zig");

pub const none: u32 = std.math.maxInt(u32);

/// A function-like definition.
pub const Node = struct {
    file_id: u32,
    /// The defining file's path, borrowed from its outline.
    path: []const u8,
    name: []const u8,
    kind: models.SymbolKind,
    language: models.Language,
    flags: models.SymbolFlags = .{},
    /// 0-based, inclusive.
    line_start: u32,
    line_end: u32,
};

pub const Edge = struct {
    to: u32,
    /// 0-based line of the call site in the caller's file.
    line: u32,
    /// The call runs on an event. See `models.Call.deferred`.
    deferred: bool = false,
};

pub const Stats = struct {
    calls: usize = 0,
    resolved: usize = 0,
    ambiguous: usize = 0,
};

pub const Graph = struct {
    allocator: std.mem.Allocator,
    nodes: []Node,
    /// Outgoing edges of node `i`: `edges[out_start[i]..out_start[i + 1]]`.
    edges: []Edge,
    out_start: []u32,
    /// Incoming edges as caller node ids: `callers[in_start[i]..in_start[i + 1]]`.
    callers: []u32,
    in_start: []u32,
    /// Per file: the resolved target of each entry of `outline.calls`, or
    /// `none`. Parallel to the outline's call slice.
    targets: std.AutoHashMap(u32, []u32),
    /// Per file: its nodes, for the innermost-function lookup.
    file_nodes: std.AutoHashMap(u32, []u32),
    stats: Stats,

    pub fn deinit(self: *Graph) void {
        const a = self.allocator;
        a.free(self.nodes);
        a.free(self.edges);
        a.free(self.out_start);
        a.free(self.callers);
        a.free(self.in_start);
        var it = self.targets.valueIterator();
        while (it.next()) |v| a.free(v.*);
        self.targets.deinit();
        var fit = self.file_nodes.valueIterator();
        while (fit.next()) |v| a.free(v.*);
        self.file_nodes.deinit();
    }

    /// The innermost function in `file_id` whose body holds the 0-based line.
    pub fn enclosing(self: *const Graph, file_id: u32, line: u32) ?u32 {
        const ids = self.file_nodes.get(file_id) orelse return null;
        var best: ?u32 = null;
        for (ids) |id| {
            const n = self.nodes[id];
            if (line < n.line_start or line > n.line_end) continue;
            if (best == null or n.line_start >= self.nodes[best.?].line_start) best = id;
        }
        return best;
    }

    pub fn out(self: *const Graph, node: u32) []const Edge {
        return self.edges[self.out_start[node]..self.out_start[node + 1]];
    }

    pub fn into(self: *const Graph, node: u32) []const u32 {
        return self.callers[self.in_start[node]..self.in_start[node + 1]];
    }

    /// The resolved target of the `i`th call in `file_id`'s outline.
    pub fn target(self: *const Graph, file_id: u32, call_index: usize) ?u32 {
        const t = self.targets.get(file_id) orelse return null;
        if (call_index >= t.len or t[call_index] == none) return null;
        return t[call_index];
    }
};

fn is_function_kind(kind: models.SymbolKind) bool {
    return kind == .function or kind == .method or kind == .@"test";
}

/// A JavaScript or TypeScript binding that holds a function:
/// `const load = async (id) => { … }`.
fn binds_function(content: []const u8, sym: models.Symbol) bool {
    if (sym.kind != .variable and sym.kind != .constant) return false;
    var line_no: usize = 0;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| : (line_no += 1) {
        if (line_no < sym.line_start) continue;
        return std.mem.indexOf(u8, line, "=>") != null or std.mem.indexOf(u8, line, "function") != null;
    }
    return false;
}

pub fn build(allocator: std.mem.Allocator, exp: *explorer.Explorer) !Graph {
    var nodes = std.ArrayList(Node).empty;
    errdefer nodes.deinit(allocator);
    var file_nodes = std.AutoHashMap(u32, []u32).init(allocator);
    errdefer {
        var it = file_nodes.valueIterator();
        while (it.next()) |v| allocator.free(v.*);
        file_nodes.deinit();
    }

    // Pass 1: the nodes.
    var scratch = std.ArrayList(u32).empty;
    defer scratch.deinit(allocator);
    var oit = exp.outlines.iterator();
    while (oit.next()) |entry| {
        const file_id = entry.key_ptr.*;
        if (exp.deleted_files.get(file_id) != null) continue;
        const outline = entry.value_ptr.*;
        const js = outline.language == .typescript or outline.language == .javascript;
        const content: ?[]const u8 = if (js) exp.content_cache.get(file_id) else null;
        scratch.clearRetainingCapacity();
        for (outline.symbols) |sym| {
            const callable = is_function_kind(sym.kind) or
                (js and content != null and binds_function(content.?, sym));
            if (!callable) continue;
            try scratch.append(allocator, @intCast(nodes.items.len));
            try nodes.append(allocator, .{
                .file_id = file_id,
                .path = outline.path,
                .name = sym.name,
                .kind = sym.kind,
                .language = outline.language,
                .flags = sym.flags,
                .line_start = @intCast(sym.line_start),
                .line_end = @intCast(sym.line_end),
            });
        }
        if (scratch.items.len > 0) try file_nodes.put(file_id, try allocator.dupe(u32, scratch.items));
    }

    var by_name = std.StringHashMap(std.ArrayList(u32)).init(allocator);
    defer {
        var it = by_name.valueIterator();
        while (it.next()) |v| v.deinit(allocator);
        by_name.deinit();
    }
    for (nodes.items, 0..) |n, i| {
        const gop = try by_name.getOrPut(n.name);
        if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(u32).empty;
        try gop.value_ptr.append(allocator, @intCast(i));
    }

    // Pass 2: resolve every call.
    var graph = Graph{
        .allocator = allocator,
        .nodes = &.{},
        .edges = &.{},
        .out_start = &.{},
        .callers = &.{},
        .in_start = &.{},
        .targets = std.AutoHashMap(u32, []u32).init(allocator),
        .file_nodes = file_nodes,
        .stats = .{},
    };
    errdefer {
        var it = graph.targets.valueIterator();
        while (it.next()) |v| allocator.free(v.*);
        graph.targets.deinit();
    }
    graph.nodes = try nodes.toOwnedSlice(allocator);

    var raw = std.ArrayList(struct { from: u32, edge: Edge }).empty;
    defer raw.deinit(allocator);
    var near = std.AutoHashMap(u32, void).init(allocator);
    defer near.deinit();

    var cit = exp.outlines.iterator();
    while (cit.next()) |entry| {
        const file_id = entry.key_ptr.*;
        if (exp.deleted_files.get(file_id) != null) continue;
        const outline = entry.value_ptr.*;
        if (outline.calls.len == 0) continue;

        try imported_files(exp, file_id, &near);
        const t = try allocator.alloc(u32, outline.calls.len);
        @memset(t, none);
        try graph.targets.put(file_id, t);
        var import_lines: ?[]const u8 = null;
        defer if (import_lines) |il| allocator.free(il);

        for (outline.calls, 0..) |call, ci| {
            graph.stats.calls += 1;
            const cands = by_name.get(call.name) orelse continue;
            var res = resolve(graph.nodes, cands.items, file_id, outline.language, call, &near);
            const from = graph.enclosing(file_id, call.line);
            if (res == .found) {
                const to = res.found;
                // `use tokio::spawn;` then `spawn(…)` names the crate's
                // function. A repository function of the same name is reached
                // through the import rule or not at all.
                if (res_is_global(graph.nodes, to, file_id, &near)) {
                    if (import_lines == null) import_lines = try collect_import_lines(allocator, exp, file_id);
                    if (names_word(import_lines.?, call.name)) res = .unresolved;
                    // `update(entry)` where `update` is the caller's closure
                    // parameter bound to a repository function named `update`.
                    const content = exp.content_cache.get(file_id);
                    if (content == null or (from != null and binds_locally(content.?, graph.nodes[from.?], call))) res = .unresolved;
                }
                // `other.run()` inside `run` is another receiver's method, not
                // recursion. Recursion is spelled through `self` or by name.
                if (from != null and from.? == to and call.kind == .method and !call.self_receiver) res = .unresolved;
            }
            switch (res) {
                .found => |to| {
                    graph.stats.resolved += 1;
                    t[ci] = to;
                    // A recursive call is an edge too; the cost walk stops at it.
                    try raw.append(allocator, .{ .from = from orelse continue, .edge = .{ .to = to, .line = call.line, .deferred = call.deferred } });
                },
                .ambiguous => graph.stats.ambiguous += 1,
                .unresolved => {},
            }
        }
    }

    // CSR adjacency, both directions.
    const n = graph.nodes.len;
    graph.out_start = try allocator.alloc(u32, n + 1);
    graph.in_start = try allocator.alloc(u32, n + 1);
    @memset(graph.out_start, 0);
    @memset(graph.in_start, 0);
    for (raw.items) |r| {
        graph.out_start[r.from + 1] += 1;
        graph.in_start[r.edge.to + 1] += 1;
    }
    for (1..n + 1) |i| {
        graph.out_start[i] += graph.out_start[i - 1];
        graph.in_start[i] += graph.in_start[i - 1];
    }
    graph.edges = try allocator.alloc(Edge, raw.items.len);
    graph.callers = try allocator.alloc(u32, raw.items.len);
    const out_fill = try allocator.dupe(u32, graph.out_start[0..n]);
    defer allocator.free(out_fill);
    const in_fill = try allocator.dupe(u32, graph.in_start[0..n]);
    defer allocator.free(in_fill);
    for (raw.items) |r| {
        graph.edges[out_fill[r.from]] = r.edge;
        out_fill[r.from] += 1;
        graph.callers[in_fill[r.edge.to]] = r.from;
        in_fill[r.edge.to] += 1;
    }
    return graph;
}

/// The files `file_id` imports, and the files those import.
fn imported_files(exp: *explorer.Explorer, file_id: u32, out: *std.AutoHashMap(u32, void)) !void {
    out.clearRetainingCapacity();
    const direct = exp.depgraph.imports.get(file_id) orelse return;
    for (direct.items) |d| {
        try out.put(d, {});
        if (exp.depgraph.imports.get(d)) |second| {
            for (second.items) |s| try out.put(s, {});
        }
    }
}

/// Whether the caller binds `call.name` itself before the call: a parameter
/// in its signature, or `let name`, `const name`, `var name`, `name :=`.
fn binds_locally(content: []const u8, caller: Node, call: models.Call) bool {
    var line_no: u32 = 0;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| : (line_no += 1) {
        if (line_no < caller.line_start) continue;
        if (line_no > call.line) break;
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, line, pos, call.name)) |at| {
            pos = at + call.name.len;
            if (at > 0 and (std.ascii.isAlphanumeric(line[at - 1]) or line[at - 1] == '_')) continue;
            if (pos < line.len and (std.ascii.isAlphanumeric(line[pos]) or line[pos] == '_')) continue;
            const before = std.mem.trimEnd(u8, line[0..at], " \t");
            const after = std.mem.trimStart(u8, line[pos..], " \t");
            // A parameter or a typed binding: `update: F`, `(update)`, `, update`.
            if (line_no == caller.line_start and after.len > 0 and (after[0] == ':' or after[0] == ',' or after[0] == ')')) return true;
            if (std.mem.endsWith(u8, before, "let") or std.mem.endsWith(u8, before, "let mut") or
                std.mem.endsWith(u8, before, "const") or std.mem.endsWith(u8, before, "var")) return true;
            if (std.mem.startsWith(u8, after, ":=")) return true;
        }
    }
    return false;
}

/// Languages that call each other's definitions by name.
fn family(language: models.Language) u8 {
    return switch (language) {
        .typescript, .javascript => 1,
        .c, .cpp => 2,
        .java, .kotlin, .scala => 3,
        else => 16 + @as(u8, @intFromEnum(language)),
    };
}

/// Whether `to` was found by the whole-repository rule: it lives outside the
/// caller's file and outside everything the caller imports.
fn res_is_global(nodes: []const Node, to: u32, file_id: u32, near: *const std.AutoHashMap(u32, void)) bool {
    const f = nodes[to].file_id;
    return f != file_id and !near.contains(f);
}

/// The caller file's import statements, one per line. Group imports are
/// stored as their root path (`use tokio::{spawn, select}` as `tokio`), so the
/// names they bring in are read from the source.
fn collect_import_lines(allocator: std.mem.Allocator, exp: *explorer.Explorer, file_id: u32) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    const content = exp.content_cache.get(file_id) orelse return out.toOwnedSlice(allocator);
    var it = std.mem.splitScalar(u8, content, '\n');
    var in_group = false;
    while (it.next()) |raw| {
        const t = std.mem.trim(u8, raw, " \t\r");
        const starts = std.mem.startsWith(u8, t, "use ") or std.mem.startsWith(u8, t, "pub use ") or
            std.mem.startsWith(u8, t, "import ") or std.mem.startsWith(u8, t, "from ") or
            std.mem.indexOf(u8, t, "require(") != null or std.mem.indexOf(u8, t, "@import(") != null;
        if (starts or in_group) {
            try out.appendSlice(allocator, t);
            try out.append(allocator, '\n');
            // A group import that continues on the next lines.
            if (starts and std.mem.indexOfScalar(u8, t, '{') != null and std.mem.indexOfScalar(u8, t, '}') == null) in_group = true;
            if (in_group and std.mem.indexOfScalar(u8, t, '}') != null) in_group = false;
        }
    }
    return out.toOwnedSlice(allocator);
}

fn names_word(hay: []const u8, word: []const u8) bool {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, hay, pos, word)) |at| {
        pos = at + word.len;
        const left_ok = at == 0 or !(std.ascii.isAlphanumeric(hay[at - 1]) or hay[at - 1] == '_');
        const right_ok = pos >= hay.len or !(std.ascii.isAlphanumeric(hay[pos]) or hay[pos] == '_');
        if (left_ok and right_ok) return true;
    }
    return false;
}

const Resolution = union(enum) {
    found: u32,
    ambiguous,
    unresolved,
};

fn resolve(nodes: []const Node, cands: []const u32, file_id: u32, language: models.Language, call: models.Call, near: *const std.AutoHashMap(u32, void)) Resolution {
    const not_found: Resolution = if (cands.len > 0) .ambiguous else .unresolved;
    if (call.self_receiver) {
        if (unique(nodes, cands, language, file_id, null, call)) |r| return r;
        if (unique(nodes, cands, language, null, near, call)) |r| return r;
        return not_found;
    }
    // `crate::agent::run(…)` names the module. The caller's own file can hold
    // another `run`, and the same-file rule bound the call to it.
    if (call.qualifier.len > 0) {
        if (qualifier_is_module(language, call)) {
            if (unique_in_module(nodes, cands, language, call.qualifier)) |r| return r;
            if (unique(nodes, cands, language, null, near, call)) |r| return r;
            return not_found;
        }
        // `util.Do()`, `helpers.thing()`, `api.get()`: the qualifier can be a
        // module or a variable, and a file named after it is the evidence.
        if (call.kind == .method and qualifier_may_be_module(language)) {
            if (unique_in_module(nodes, cands, language, call.qualifier)) |r| return r;
        }
    }
    // `self.pending.write()` locks an `RwLock`. The name is the standard
    // library's, and a repository method named `write` is not evidence. A file
    // named after the qualifier, checked above, is.
    if (call.kind == .method and is_std_method(call.name)) return .unresolved;
    // The same file first: a helper beside its caller.
    if (unique(nodes, cands, language, file_id, null, call)) |r| return r;
    // Then what the caller imports. A method on another file's type is found
    // here, through the import that names the type.
    if (unique(nodes, cands, language, null, near, call)) |r| return r;
    // A plain call with a single definition anywhere: C, Python and Go call
    // across files that no import statement names.
    if (call.kind == .plain) {
        var found: ?u32 = null;
        var count: usize = 0;
        for (cands) |c| {
            if (family(nodes[c].language) != family(language)) continue;
            found = c;
            count += 1;
        }
        if (count == 1) return .{ .found = found.? };
        return if (count > 1) .ambiguous else .unresolved;
    }
    return not_found;
}

/// Method names the standard collections, locks, channels, iterators, I/O
/// and futures of the indexed languages define. A call to one on a receiver
/// other than `self` names that library method as often as a repository one.
const std_methods = [_][]const u8{
    "get",            "get_mut", "set",       "insert",   "remove",       "push",     "pop",
    "append",         "extend",  "clear",     "contains", "contains_key", "entry",    "or_insert",
    "or_insert_with", "retain",  "drain",     "sort",     "len",          "is_empty", "iter",
    "into_iter",      "map",     "filter",    "find",     "collect",      "first",    "last",
    "next",           "take",    "skip",      "join",     "split",        "parse",    "to_string",
    "clone",          "unwrap",  "expect",    "ok",       "err",          "and_then", "map_err",
    "read",           "write",   "flush",     "close",    "open",         "lock",     "try_lock",
    "send",           "recv",    "try_recv",  "load",     "store",        "wait",     "notify",
    "spawn",          "poll",    "call",      "apply",    "run",          "start",    "stop",
    "reset",          "update",  "add",       "delete",   "keys",         "values",   "has",
    "forEach",        "then",    "catch",     "finally",  "resolve",      "reject",   "emit",
    "on",             "off",     "subscribe", "publish",  "log",          "debug",    "info",
    "warn",           "error",   "trace",     "json",     "text",         "fetch",    "build",
    "finish",         "commit",  "rollback",  "begin",    "execute",      "query",    "bind",
};

fn is_std_method(name: []const u8) bool {
    for (&std_methods) |m| {
        if (std.mem.eql(u8, name, m)) return true;
    }
    return false;
}

/// A Rust path whose last segment before the name is a module: lowercase and
/// not `self`, `super` or `crate`. `Store::open` names a type instead.
fn qualifier_is_module(language: models.Language, call: models.Call) bool {
    if (call.kind != .path or language != .rust) return false;
    const q = call.qualifier;
    if (!std.ascii.isLower(q[0])) return false;
    return !std.mem.eql(u8, q, "super") and !std.mem.eql(u8, q, "crate");
}

fn qualifier_may_be_module(language: models.Language) bool {
    return switch (language) {
        .go, .python, .zig, .typescript, .javascript, .lua, .ruby => true,
        else => false,
    };
}

/// The one candidate whose file lives in a directory named `module` or is
/// named `module`: `agent` matches `src/agent/loop_.rs` and `src/agent.rs`.
fn unique_in_module(nodes: []const Node, cands: []const u32, language: models.Language, module: []const u8) ?Resolution {
    var found: ?u32 = null;
    var count: usize = 0;
    for (cands) |c| {
        if (family(nodes[c].language) != family(language)) continue;
        if (!path_names_module(nodes[c].path, module)) continue;
        found = c;
        count += 1;
    }
    if (count == 1) return .{ .found = found.? };
    if (count > 1) return .ambiguous;
    return null;
}

fn path_names_module(path: []const u8, module: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        const stem = if (std.mem.lastIndexOfScalar(u8, seg, '.')) |dot| seg[0..dot] else seg;
        if (std.mem.eql(u8, stem, module)) return true;
    }
    return false;
}

/// The one candidate in scope, `.ambiguous` when several are, null when none.
fn unique(nodes: []const Node, cands: []const u32, language: models.Language, file: ?u32, files: ?*const std.AutoHashMap(u32, void), call: models.Call) ?Resolution {
    var found: ?u32 = null;
    var count: usize = 0;
    for (cands) |c| {
        const n = nodes[c];
        if (family(n.language) != family(language)) continue;
        if (file) |f| {
            if (n.file_id != f) continue;
        }
        if (files) |fs| {
            if (!fs.contains(n.file_id)) continue;
        }
        // `receiver.name()` calls a method. Where the tags query marks
        // methods, a free function of the same name is a different definition:
        // `approvals.get(id)` in a component is not the API module's `get`.
        if (call.kind == .method and !call.self_receiver and n.kind != .method and marks_methods(n.language)) continue;
        found = c;
        count += 1;
    }
    if (count == 1) return .{ .found = found.? };
    if (count > 1) return .ambiguous;
    return null;
}

/// These languages' tags queries mark methods, and a module-qualified call is
/// spelled apart from a method call (`::` in Rust, a named import in
/// JavaScript), so a free function cannot be the target of `receiver.name()`.
/// Go, Python and Zig spell `pkg.Func()` with the same dot as a method call,
/// and there the kind rules nothing out.
fn marks_methods(language: models.Language) bool {
    return switch (language) {
        .rust, .typescript, .javascript, .java, .kotlin, .c_sharp, .cpp => true,
        else => false,
    };
}

// ── Walks ────────────────────────────────────────────────────────────────────

/// Per node, a cost summed through the calls it makes, and the call that
/// carries the largest share of it.
pub const Reach = struct {
    total: u64,
    /// Index into `Graph.edges` of the callee that contributes the most, or
    /// `none` when the node's own cost is all of it.
    via: u32,
};

/// `cost(n) = own[n] + Σ cost(callee)` over every call site in `n`, so a
/// function that calls a querying helper twice costs twice the helper. A call
/// back into a function still on the walk (recursion) adds nothing: the
/// static count of one pass is what the source states.
///
/// `skip`, when given, holds one flag per edge; a flagged edge adds nothing.
pub fn transitive(allocator: std.mem.Allocator, g: *const Graph, own: []const u64, skip: ?[]const bool) ![]Reach {
    const n = g.nodes.len;
    const reach = try allocator.alloc(Reach, n);
    errdefer allocator.free(reach);
    const state = try allocator.alloc(u8, n); // 0 new, 1 on stack, 2 done
    defer allocator.free(state);
    @memset(state, 0);

    const Frame = struct { node: u32, next: u32 };
    var stack = std.ArrayList(Frame).empty;
    defer stack.deinit(allocator);

    for (0..n) |root_usize| {
        const root: u32 = @intCast(root_usize);
        if (state[root] != 0) continue;
        state[root] = 1;
        reach[root] = .{ .total = own[root], .via = none };
        try stack.append(allocator, .{ .node = root, .next = g.out_start[root] });
        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            if (top.next < g.out_start[top.node + 1]) {
                const ei = top.next;
                top.next += 1;
                const to = g.edges[ei].to;
                if (state[to] == 0) {
                    state[to] = 1;
                    reach[to] = .{ .total = own[to], .via = none };
                    try stack.append(allocator, .{ .node = to, .next = g.out_start[to] });
                }
                continue;
            }
            // All callees done: fold them in.
            const node = top.node;
            _ = stack.pop();
            var best: u64 = 0;
            for (g.out_start[node]..g.out_start[node + 1]) |ei| {
                if (skip) |sk| {
                    if (sk[ei]) continue;
                }
                const to = g.edges[ei].to;
                if (state[to] != 2) continue; // on the stack: a cycle
                const c = reach[to].total;
                reach[node].total = @min(reach[node].total + c, max_cost);
                if (c > best) {
                    best = c;
                    reach[node].via = @intCast(ei);
                }
            }
            state[node] = 2;
        }
    }
    return reach;
}

/// `a → b → c`: the calls from `start` along the largest share of its cost.
/// Caller frees.
pub fn path_string(allocator: std.mem.Allocator, g: *const Graph, reach: []const Reach, start: u32) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, g.nodes[start].name);
    var cur = start;
    var hops: usize = 0;
    while (reach[cur].via != none and hops < 8) : (hops += 1) {
        cur = g.edges[reach[cur].via].to;
        try out.appendSlice(allocator, " → ");
        try out.appendSlice(allocator, g.nodes[cur].name);
    }
    return out.toOwnedSlice(allocator);
}

/// The node at the end of `start`'s largest-share path: where the cost it
/// carries is written.
pub fn path_end(g: *const Graph, reach: []const Reach, start: u32) u32 {
    var cur = start;
    var hops: usize = 0;
    while (reach[cur].via != none and hops < 64) : (hops += 1) cur = g.edges[reach[cur].via].to;
    return cur;
}

/// Past this a count means "unbounded" to every reader, and it keeps the sum
/// far from overflow.
pub const max_cost: u64 = 1_000_000;

/// Every node reachable from `seeds` through calls.
pub fn reachable(allocator: std.mem.Allocator, g: *const Graph, seeds: []const u32) ![]bool {
    const seen = try allocator.alloc(bool, g.nodes.len);
    errdefer allocator.free(seen);
    @memset(seen, false);
    var queue = std.ArrayList(u32).empty;
    defer queue.deinit(allocator);
    for (seeds) |s| {
        if (seen[s]) continue;
        seen[s] = true;
        try queue.append(allocator, s);
    }
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        for (g.out(queue.items[head])) |e| {
            if (seen[e.to]) continue;
            seen[e.to] = true;
            try queue.append(allocator, e.to);
        }
    }
    return seen;
}

/// How many distinct functions reach `node` through calls.
pub fn caller_count(allocator: std.mem.Allocator, g: *const Graph, node: u32) !usize {
    var seen = std.AutoHashMap(u32, void).init(allocator);
    defer seen.deinit();
    var queue = std.ArrayList(u32).empty;
    defer queue.deinit(allocator);
    try queue.append(allocator, node);
    try seen.put(node, {});
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        for (g.into(queue.items[head])) |c| {
            if (seen.contains(c)) continue;
            try seen.put(c, {});
            try queue.append(allocator, c);
        }
    }
    return seen.count() - 1;
}

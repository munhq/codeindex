const std = @import("std");
const explorer = @import("../index/explorer.zig");
const models = @import("../core/models.zig");

/// Plan-change output is rendered as markdown text in http.zig.
/// This module does the data collection and packages the pieces.
pub const DefSite = struct {
    path: []const u8,
    line_start: usize,
    line_end: usize,
    kind: models.SymbolKind,
};

pub const CallerLine = struct {
    path: []const u8,
    line_num: u32,
    context: []const u8,
    snippet: []const u8, // owned
};

pub const CallerGroup = struct {
    path: []const u8,
    count: usize,
    samples: []CallerLine, // first few hits in this file; owned snippets
};

pub const FileRole = enum {
    god_module, // high fan_in AND high fan_out
    stable_core, // high fan_in, low fan_out (contract / trait)
    driver, // low fan_in, high fan_out (entry / aggregator)
    island, // zero both
    regular,

    pub fn as_str(self: FileRole) []const u8 {
        return switch (self) {
            .god_module => "god_module",
            .stable_core => "stable_core (contract/trait)",
            .driver => "driver (entry/aggregator)",
            .island => "island (no imports in or out)",
            .regular => "regular",
        };
    }
};

pub const LiteralSummary = struct {
    urls: usize,
    localhosts: usize,
    ips: usize,
    secrets: usize,
    magic_ports: usize,
    abs_paths: usize,
    todos: usize,
};

pub const SymbolPlan = struct {
    target_name: []const u8, // borrowed from caller
    definitions: []DefSite,
    callers_total: usize,
    caller_groups: []CallerGroup, // grouped by file, owned
    primary_file: ?[]const u8, // file hosting first definition (for file context)
    file_role: FileRole,
    fan_in: usize,
    fan_out: usize,
    literals: LiteralSummary,
    direct_impact: [][]const u8,
    transitive_impact: [][]const u8,
    max_depth_reached: u32,
    indexer_missed_def: bool, // true when callers found but no outline def — signals indexer gap
};

pub const FilePlan = struct {
    target_path: []const u8,
    symbols_in_file: []models.Symbol, // borrowed from outline
    file_role: FileRole,
    fan_in: usize,
    fan_out: usize,
    literals: LiteralSummary,
    direct_impact: [][]const u8,
    transitive_impact: [][]const u8,
    max_depth_reached: u32,
};

pub fn plan_symbol(allocator: std.mem.Allocator, exp: *explorer.Explorer, target: []const u8) !SymbolPlan {
    // 1. Collect all symbol definitions with this name
    var defs = std.ArrayList(DefSite).empty;
    errdefer defs.deinit(allocator);
    var primary_file_id: ?u32 = null;

    var oit = exp.outlines.iterator();
    while (oit.next()) |entry| {
        const fid = entry.key_ptr.*;
        if (exp.deleted_files.get(fid) != null) continue;
        const outline = entry.value_ptr.*;
        for (outline.symbols) |sym| {
            if (!std.mem.eql(u8, sym.name, target)) continue;
            // Skip imports and tests as primary targets
            if (sym.kind == .import or sym.kind == .module) continue;
            try defs.append(allocator, .{
                .path = outline.path,
                .line_start = sym.start_1(),
                .line_end = sym.end_1(),
                .kind = sym.kind,
            });
            if (primary_file_id == null) primary_file_id = fid;
        }
    }

    const callers_raw = try collect_callers(allocator, exp, target);
    const callers_total = callers_raw.len;
    const groups = try group_by_file(allocator, callers_raw);
    // transfer ownership of snippets to groups; free the flat list wrapper
    allocator.free(callers_raw);
    // If the outline missed the definition but we do have callers, fall back:
    // treat the first caller file as the likely defining file for context.
    var primary_file_from_callers: ?[]const u8 = null;
    if (primary_file_id == null and groups.len > 0) {
        primary_file_from_callers = groups[0].path;
    }

    const primary_file = if (primary_file_id) |pfid| exp.file_path(pfid) else primary_file_from_callers;
    const effective_fid: ?u32 = primary_file_id orelse (if (primary_file) |pf| exp.file_map.get(pf) else null);
    const fan_in: usize = if (effective_fid) |fid|
        if (exp.depgraph.reverse_deps.get(fid)) |l| l.items.len else 0
    else
        0;
    const fan_out: usize = if (effective_fid) |fid|
        if (exp.depgraph.imports.get(fid)) |l| l.items.len else 0
    else
        0;
    const role = classify(fan_in, fan_out, primary_file);

    const lits: LiteralSummary = if (primary_file) |p| try scan_file_literals(allocator, exp, p) else std.mem.zeroes(LiteralSummary);

    const impact = if (primary_file) |p| try collect_impact(allocator, exp, p) else Impact{
        .direct = &[_][]const u8{},
        .transitive = &[_][]const u8{},
        .max_depth = 0,
    };

    return .{
        .target_name = target,
        .definitions = try defs.toOwnedSlice(allocator),
        .callers_total = callers_total,
        .caller_groups = groups,
        .primary_file = primary_file,
        .file_role = role,
        .fan_in = fan_in,
        .fan_out = fan_out,
        .literals = lits,
        .direct_impact = impact.direct,
        .transitive_impact = impact.transitive,
        .max_depth_reached = impact.max_depth,
        .indexer_missed_def = (primary_file_id == null and callers_total > 0),
    };
}

pub fn plan_file(allocator: std.mem.Allocator, exp: *explorer.Explorer, target_path: []const u8) !FilePlan {
    const file_id = exp.file_map.get(target_path) orelse return .{
        .target_path = target_path,
        .symbols_in_file = &[_]models.Symbol{},
        .file_role = .regular,
        .fan_in = 0,
        .fan_out = 0,
        .literals = std.mem.zeroes(LiteralSummary),
        .direct_impact = &[_][]const u8{},
        .transitive_impact = &[_][]const u8{},
        .max_depth_reached = 0,
    };

    const outline = exp.outlines.get(file_id) orelse return .{
        .target_path = target_path,
        .symbols_in_file = &[_]models.Symbol{},
        .file_role = .regular,
        .fan_in = 0,
        .fan_out = 0,
        .literals = std.mem.zeroes(LiteralSummary),
        .direct_impact = &[_][]const u8{},
        .transitive_impact = &[_][]const u8{},
        .max_depth_reached = 0,
    };

    const fan_in: usize = if (exp.depgraph.reverse_deps.get(file_id)) |l| l.items.len else 0;
    const fan_out: usize = if (exp.depgraph.imports.get(file_id)) |l| l.items.len else 0;
    const role = classify(fan_in, fan_out, target_path);
    const lits = try scan_file_literals(allocator, exp, target_path);
    const impact = try collect_impact(allocator, exp, target_path);

    return .{
        .target_path = target_path,
        .symbols_in_file = outline.symbols,
        .file_role = role,
        .fan_in = fan_in,
        .fan_out = fan_out,
        .literals = lits,
        .direct_impact = impact.direct,
        .transitive_impact = impact.transitive,
        .max_depth_reached = impact.max_depth,
    };
}

// ── Helpers ──────────────────────────────────────────────────────────────────

const Impact = struct {
    direct: [][]const u8,
    transitive: [][]const u8,
    max_depth: u32,
};

fn collect_impact(allocator: std.mem.Allocator, exp: *explorer.Explorer, path: []const u8) !Impact {
    const ci = exp.get_change_impact(path, 10) catch return Impact{
        .direct = &[_][]const u8{},
        .transitive = &[_][]const u8{},
        .max_depth = 0,
    };
    defer exp.allocator.free(ci.direct);
    defer exp.allocator.free(ci.transitive);

    var direct = try allocator.alloc([]const u8, ci.direct.len);
    for (ci.direct, 0..) |fid, i| {
        direct[i] = exp.file_path(fid) orelse "<unknown>";
    }

    // Transitive = all minus direct (but preserve order). ci.transitive includes direct.
    var trans_list = std.ArrayList([]const u8).empty;
    errdefer trans_list.deinit(allocator);
    outer: for (ci.transitive) |fid| {
        for (ci.direct) |dfid| if (dfid == fid) continue :outer;
        try trans_list.append(allocator, exp.file_path(fid) orelse "<unknown>");
    }

    return .{
        .direct = direct,
        .transitive = try trans_list.toOwnedSlice(allocator),
        .max_depth = ci.depth_reached,
    };
}

fn classify(fan_in: usize, fan_out: usize, path: ?[]const u8) FileRole {
    if (fan_in >= 5 and fan_out >= 10) return .god_module;
    if (fan_in >= 5 and fan_out <= 2) return .stable_core;
    if (fan_out >= 10 and fan_in <= 1) return .driver;
    if (fan_in == 0 and fan_out == 0) {
        if (path) |p| {
            if (is_entry(p)) return .regular;
        }
        return .island;
    }
    return .regular;
}

fn is_entry(p: []const u8) bool {
    if (std.mem.endsWith(u8, p, "main.rs")) return true;
    if (std.mem.endsWith(u8, p, "lib.rs")) return true;
    if (std.mem.endsWith(u8, p, "/main.go")) return true;
    if (std.mem.endsWith(u8, p, "main.zig")) return true;
    if (std.mem.endsWith(u8, p, "index.ts") or std.mem.endsWith(u8, p, "index.tsx")) return true;
    return false;
}

fn scan_file_literals(allocator: std.mem.Allocator, exp: *explorer.Explorer, path: []const u8) !LiteralSummary {
    _ = allocator;
    var out = std.mem.zeroes(LiteralSummary);
    const file_id = exp.file_map.get(path) orelse return out;
    const content = exp.content_cache.get(file_id) orelse return out;

    var line_num: usize = 0;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        line_num += 1;
        if (line.len == 0 or line.len > 2000) continue;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        // cheap inline URL detection
        if (std.mem.indexOf(u8, line, "http://") != null or std.mem.indexOf(u8, line, "https://") != null) {
            if (std.mem.indexOf(u8, line, "localhost") != null or
                std.mem.indexOf(u8, line, "127.0.0.1") != null or
                std.mem.indexOf(u8, line, "0.0.0.0") != null)
            {
                out.localhosts += 1;
            } else {
                out.urls += 1;
            }
        }
        if (std.mem.indexOf(u8, line, ":5432") != null or
            std.mem.indexOf(u8, line, ":6379") != null or
            std.mem.indexOf(u8, line, ":3306") != null or
            std.mem.indexOf(u8, line, ":27017") != null or
            std.mem.indexOf(u8, line, ":4222") != null or
            std.mem.indexOf(u8, line, ":9092") != null)
        {
            out.magic_ports += 1;
        }
        const abs_prefixes = [_][]const u8{ "\"/home/", "\"/etc/", "\"/var/", "\"/opt/", "\"/usr/" };
        for (abs_prefixes) |pfx| {
            if (std.mem.indexOf(u8, line, pfx) != null) {
                out.abs_paths += 1;
                break;
            }
        }
        if (std.mem.indexOf(u8, trimmed, "TODO") != null or
            std.mem.indexOf(u8, trimmed, "FIXME") != null or
            std.mem.indexOf(u8, trimmed, "XXX") != null)
        {
            out.todos += 1;
        }
    }
    return out;
}

fn collect_callers(allocator: std.mem.Allocator, exp: *explorer.Explorer, name: []const u8) ![]CallerLine {
    // Reuse explorer.find_callers, rewrap into CallerLine (owning snippets).
    const raw = try exp.find_callers(name, 100);
    defer {
        for (raw) |r| exp.allocator.free(r.line_text);
        exp.allocator.free(raw);
    }
    var out = try allocator.alloc(CallerLine, raw.len);
    for (raw, 0..) |r, i| {
        out[i] = .{
            .path = r.path,
            .line_num = r.line_num,
            .context = r.context,
            .snippet = try allocator.dupe(u8, r.line_text),
        };
    }
    return out;
}

fn group_by_file(allocator: std.mem.Allocator, callers: []CallerLine) ![]CallerGroup {
    if (callers.len == 0) return &[_]CallerGroup{};

    // simple O(n²) grouping — fine up to a few hundred callers
    var groups = std.ArrayList(CallerGroup).empty;
    errdefer {
        for (groups.items) |*g| {
            for (g.samples) |s| allocator.free(s.snippet);
            allocator.free(g.samples);
        }
        groups.deinit(allocator);
    }

    const per_file_cap: usize = 3;

    for (callers) |c| {
        var found: ?usize = null;
        for (groups.items, 0..) |g, i| {
            if (std.mem.eql(u8, g.path, c.path)) {
                found = i;
                break;
            }
        }
        if (found) |idx| {
            var g = &groups.items[idx];
            g.count += 1;
            if (g.samples.len < per_file_cap) {
                const new_samples = try allocator.alloc(CallerLine, g.samples.len + 1);
                @memcpy(new_samples[0..g.samples.len], g.samples);
                new_samples[g.samples.len] = .{
                    .path = c.path,
                    .line_num = c.line_num,
                    .context = c.context,
                    .snippet = c.snippet, // transfer ownership
                };
                allocator.free(g.samples);
                g.samples = new_samples;
            } else {
                // drop the extra snippet (we already have enough samples)
                allocator.free(c.snippet);
            }
        } else {
            var samples = try allocator.alloc(CallerLine, 1);
            samples[0] = .{
                .path = c.path,
                .line_num = c.line_num,
                .context = c.context,
                .snippet = c.snippet,
            };
            try groups.append(allocator, .{ .path = c.path, .count = 1, .samples = samples });
        }
    }

    const out = try groups.toOwnedSlice(allocator);
    // Sort groups by count desc
    std.mem.sort(CallerGroup, out, {}, cmp_group_desc);
    return out;
}

fn cmp_group_desc(_: void, a: CallerGroup, b: CallerGroup) bool {
    return a.count > b.count;
}

pub fn free_symbol_plan(allocator: std.mem.Allocator, p: *SymbolPlan) void {
    allocator.free(p.definitions);
    for (p.caller_groups) |*g| {
        for (g.samples) |s| allocator.free(s.snippet);
        allocator.free(g.samples);
    }
    allocator.free(p.caller_groups);
    allocator.free(p.direct_impact);
    allocator.free(p.transitive_impact);
}

pub fn free_file_plan(allocator: std.mem.Allocator, p: *FilePlan) void {
    allocator.free(p.direct_impact);
    allocator.free(p.transitive_impact);
}

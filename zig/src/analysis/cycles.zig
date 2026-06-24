const std = @import("std");
const explorer = @import("../index/explorer.zig");

pub const Cycle = struct {
    files: [][]const u8,
};

pub const Report = struct {
    cycles: []Cycle,
    total_nodes: usize,
    total_edges: usize,
};

/// Tarjan's strongly-connected-components over the forward import graph.
/// Any SCC of size > 1 is a cycle; self-loops (SCC size 1 with an edge to itself) are also reported.
pub fn analyze(allocator: std.mem.Allocator, exp: *explorer.Explorer) !Report {
    // Gather node set (file_ids currently alive)
    var nodes = std.ArrayList(u32).empty;
    defer nodes.deinit(allocator);

    var oit = exp.outlines.iterator();
    while (oit.next()) |entry| {
        const id = entry.key_ptr.*;
        if (exp.deleted_files.get(id) != null) continue;
        try nodes.append(allocator, id);
    }

    var edges: usize = 0;
    var eit = exp.depgraph.imports.iterator();
    while (eit.next()) |entry| edges += entry.value_ptr.items.len;

    // Tarjan state
    var index_map = std.AutoHashMap(u32, i32).init(allocator);
    defer index_map.deinit();
    var lowlink = std.AutoHashMap(u32, i32).init(allocator);
    defer lowlink.deinit();
    var on_stack = std.AutoHashMap(u32, void).init(allocator);
    defer on_stack.deinit();
    var stack = std.ArrayList(u32).empty;
    defer stack.deinit(allocator);

    var index_counter: i32 = 0;
    var sccs = std.ArrayList([]u32).empty;
    errdefer {
        for (sccs.items) |s| allocator.free(s);
        sccs.deinit(allocator);
    }

    for (nodes.items) |n| {
        if (index_map.get(n) != null) continue;
        try strongconnect(
            allocator,
            exp,
            n,
            &index_counter,
            &index_map,
            &lowlink,
            &on_stack,
            &stack,
            &sccs,
        );
    }

    // Filter: keep SCCs of size >= 2, or size 1 with self-loop
    var cycles = std.ArrayList(Cycle).empty;
    errdefer cycles.deinit(allocator);

    for (sccs.items) |scc_ids| {
        defer allocator.free(scc_ids);
        const is_cycle = blk: {
            if (scc_ids.len >= 2) break :blk true;
            // self-loop?
            const id = scc_ids[0];
            if (exp.depgraph.imports.get(id)) |list| {
                for (list.items) |to| {
                    if (to == id) break :blk true;
                }
            }
            break :blk false;
        };
        if (!is_cycle) continue;

        var paths = try allocator.alloc([]const u8, scc_ids.len);
        for (scc_ids, 0..) |id, i| {
            paths[i] = exp.file_path(id) orelse "<deleted>";
        }
        try cycles.append(allocator, .{ .files = paths });
    }

    sccs.deinit(allocator);

    return .{
        .cycles = try cycles.toOwnedSlice(allocator),
        .total_nodes = nodes.items.len,
        .total_edges = edges,
    };
}

fn strongconnect(
    allocator: std.mem.Allocator,
    exp: *explorer.Explorer,
    v: u32,
    index_counter: *i32,
    index_map: *std.AutoHashMap(u32, i32),
    lowlink: *std.AutoHashMap(u32, i32),
    on_stack: *std.AutoHashMap(u32, void),
    stack: *std.ArrayList(u32),
    sccs: *std.ArrayList([]u32),
) !void {
    try index_map.put(v, index_counter.*);
    try lowlink.put(v, index_counter.*);
    index_counter.* += 1;
    try stack.append(allocator, v);
    try on_stack.put(v, {});

    if (exp.depgraph.imports.get(v)) |list| {
        for (list.items) |w| {
            if (exp.deleted_files.get(w) != null) continue;
            if (index_map.get(w) == null) {
                try strongconnect(allocator, exp, w, index_counter, index_map, lowlink, on_stack, stack, sccs);
                const vl = lowlink.get(v).?;
                const wl = lowlink.get(w).?;
                try lowlink.put(v, @min(vl, wl));
            } else if (on_stack.get(w) != null) {
                const vl = lowlink.get(v).?;
                const wi = index_map.get(w).?;
                try lowlink.put(v, @min(vl, wi));
            }
        }
    }

    if (lowlink.get(v).? == index_map.get(v).?) {
        var group = std.ArrayList(u32).empty;
        errdefer group.deinit(allocator);
        while (true) {
            const w = stack.pop() orelse break;
            _ = on_stack.remove(w);
            try group.append(allocator, w);
            if (w == v) break;
        }
        try sccs.append(allocator, try group.toOwnedSlice(allocator));
    }
}

pub fn free_report(allocator: std.mem.Allocator, r: *Report) void {
    for (r.cycles) |c| allocator.free(c.files);
    allocator.free(r.cycles);
}

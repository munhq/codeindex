const std = @import("std");
const explorer = @import("../index/explorer.zig");

pub const FileMetric = struct {
    file: []const u8,
    fan_in: usize,
    fan_out: usize,
    /// Martin's instability: I = fan_out / (fan_in + fan_out). 0 = stable, 1 = unstable.
    instability: f32,
    symbol_count: usize,
    line_count: usize,
};

pub const Report = struct {
    metrics: []FileMetric,
    god_modules: []FileMetric, // high fan_in AND high fan_out
    stable_cores: []FileMetric, // high fan_in, low fan_out
    unstable_drivers: []FileMetric, // low fan_in, high fan_out
    islands: []FileMetric, // zero both (excl. test/binary entry)
    total_files: usize,
    total_edges: usize,
};

pub fn analyze(allocator: std.mem.Allocator, exp: *explorer.Explorer) !Report {
    var all = std.ArrayList(FileMetric){};
    errdefer all.deinit(allocator);

    var total_edges: usize = 0;

    var it = exp.outlines.iterator();
    while (it.next()) |entry| {
        const file_id = entry.key_ptr.*;
        if (exp.deleted_files.get(file_id) != null) continue;
        const outline = entry.value_ptr.*;

        const fan_out: usize = if (exp.depgraph.imports.get(file_id)) |l| l.items.len else 0;
        const fan_in: usize = if (exp.depgraph.reverse_deps.get(file_id)) |l| l.items.len else 0;
        total_edges += fan_out;

        const denom: f32 = @floatFromInt(fan_in + fan_out);
        const inst: f32 = if (denom == 0) 0.0 else @as(f32, @floatFromInt(fan_out)) / denom;

        try all.append(allocator, .{
            .file = outline.path,
            .fan_in = fan_in,
            .fan_out = fan_out,
            .instability = inst,
            .symbol_count = outline.symbols.len,
            .line_count = outline.line_count,
        });
    }

    const metrics = try all.toOwnedSlice(allocator);

    // (Sorted views were collected earlier; thresholds below do the filtering directly.)

    // God modules: top-20 by combined, must exceed thresholds
    var gods = std.ArrayList(FileMetric){};
    errdefer gods.deinit(allocator);
    var cores = std.ArrayList(FileMetric){};
    errdefer cores.deinit(allocator);
    var drivers = std.ArrayList(FileMetric){};
    errdefer drivers.deinit(allocator);
    var isles = std.ArrayList(FileMetric){};
    errdefer isles.deinit(allocator);

    for (metrics) |m| {
        const is_hot_in = m.fan_in >= 5;
        const is_hot_out = m.fan_out >= 10;
        const is_cold_in = m.fan_in == 0;
        const is_cold_out = m.fan_out == 0;

        if (is_hot_in and is_hot_out) try gods.append(allocator, m);
        if (is_hot_in and m.fan_out <= 2) try cores.append(allocator, m);
        if (is_hot_out and m.fan_in <= 1) try drivers.append(allocator, m);
        if (is_cold_in and is_cold_out and !is_entry_path(m.file)) try isles.append(allocator, m);
    }

    // Sort categorized slices by most interesting first
    const g = try gods.toOwnedSlice(allocator);
    std.mem.sort(FileMetric, g, {}, cmp_combined_desc);
    const c = try cores.toOwnedSlice(allocator);
    std.mem.sort(FileMetric, c, {}, cmp_fanin_desc);
    const d = try drivers.toOwnedSlice(allocator);
    std.mem.sort(FileMetric, d, {}, cmp_fanout_desc);
    const i = try isles.toOwnedSlice(allocator);

    return .{
        .metrics = metrics,
        .god_modules = g,
        .stable_cores = c,
        .unstable_drivers = d,
        .islands = i,
        .total_files = metrics.len,
        .total_edges = total_edges,
    };
}

fn cmp_fanin_desc(_: void, a: FileMetric, b: FileMetric) bool {
    return a.fan_in > b.fan_in;
}

fn cmp_fanout_desc(_: void, a: FileMetric, b: FileMetric) bool {
    return a.fan_out > b.fan_out;
}

fn cmp_combined_desc(_: void, a: FileMetric, b: FileMetric) bool {
    return (a.fan_in + a.fan_out) > (b.fan_in + b.fan_out);
}

fn is_entry_path(path: []const u8) bool {
    // Main-like entry points won't have fan_in; don't flag them as islands.
    if (std.mem.endsWith(u8, path, "main.rs")) return true;
    if (std.mem.endsWith(u8, path, "/main.go")) return true;
    if (std.mem.endsWith(u8, path, "main.py") or std.mem.endsWith(u8, path, "__main__.py")) return true;
    if (std.mem.endsWith(u8, path, "index.ts") or std.mem.endsWith(u8, path, "index.tsx")) return true;
    if (std.mem.endsWith(u8, path, "main.zig")) return true;
    if (std.mem.endsWith(u8, path, "lib.rs")) return true;
    if (std.mem.endsWith(u8, path, "mod.rs")) return true;
    // Build manifests and configs
    if (std.mem.endsWith(u8, path, "Cargo.toml")) return true;
    if (std.mem.endsWith(u8, path, "package.json")) return true;
    if (std.mem.endsWith(u8, path, "tsconfig.json")) return true;
    if (std.mem.endsWith(u8, path, ".toml")) return true;
    if (std.mem.endsWith(u8, path, ".yaml") or std.mem.endsWith(u8, path, ".yml")) return true;
    if (std.mem.endsWith(u8, path, ".sql")) return true;
    if (std.mem.endsWith(u8, path, ".md")) return true;
    // Tests
    if (std.mem.indexOf(u8, path, "/tests/") != null) return true;
    return false;
}

pub fn free_report(allocator: std.mem.Allocator, r: *Report) void {
    allocator.free(r.metrics);
    allocator.free(r.god_modules);
    allocator.free(r.stable_cores);
    allocator.free(r.unstable_drivers);
    allocator.free(r.islands);
}

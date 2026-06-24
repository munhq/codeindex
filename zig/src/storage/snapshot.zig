const std = @import("std");
const explorer_mod = @import("../index/explorer.zig");
const models = @import("../core/models.zig");
const io = @import("../core/io.zig");

const SNAPSHOT_VERSION: u32 = 2;

pub const Snapshot = struct {
    /// Save explorer state as JSON snapshot.
    pub fn save(exp: *explorer_mod.Explorer, path: []const u8) !void {
        // Write to .tmp first, then rename for atomicity
        const tmp_path = blk: {
            var buf: [512]u8 = undefined;
            const len = std.fmt.count("{s}.tmp", .{path});
            if (len > buf.len) return error.PathTooLong;
            break :blk std.fmt.bufPrint(&buf, "{s}.tmp", .{path}) catch unreachable;
        };

        const file = try io.cwd().createFile(io.io(), tmp_path, .{});
        var closed = false;
        defer if (!closed) file.close(io.io());
        errdefer io.cwd().deleteFile(io.io(), tmp_path) catch {};

        var buf: [65536]u8 = undefined;
        var bw = file.writer(io.io(), &buf);
        const w = &bw.interface;

        // Header
        try w.print("{{\"version\":{d},\"created_at\":{d},\"file_count\":{d},\"symbol_count\":{d},", .{
            SNAPSHOT_VERSION,
            io.milliTimestamp(),
            exp.file_count(),
            exp.symbol_count(),
        });

        // Files array
        try w.writeAll("\"files\":[");
        for (exp.files.items, 0..) |f, i| {
            if (i > 0) try w.writeAll(",");
            try writeJsonString(w, f);
        }
        try w.writeAll("],");

        // Outlines
        try w.writeAll("\"outlines\":{");
        var first_outline = true;
        var o_it = exp.outlines.iterator();
        while (o_it.next()) |entry| {
            const file_id = entry.key_ptr.*;
            if (exp.deleted_files.get(file_id) != null) continue;
            const o = entry.value_ptr.*;

            if (!first_outline) try w.writeAll(",");
            first_outline = false;

            try w.print("\"{d}\":{{\"lang\":{d},\"bytes\":{d},\"lines\":{d},\"symbols\":[", .{
                file_id,
                @intFromEnum(o.language),
                o.byte_size,
                o.line_count,
            });

            for (o.symbols, 0..) |s, si| {
                if (si > 0) try w.writeAll(",");
                try w.writeAll("{\"n\":");
                try writeJsonString(w, s.name);
                try w.print(",\"k\":{d},\"s\":{d},\"e\":{d}", .{
                    @intFromEnum(s.kind),
                    s.line_start,
                    s.line_end,
                });
                if (s.detail) |d| {
                    try w.writeAll(",\"d\":");
                    try writeJsonString(w, d);
                }
                try w.writeAll("}");
            }

            try w.writeAll("],\"imports\":[");
            for (o.imports, 0..) |imp, ii| {
                if (ii > 0) try w.writeAll(",");
                try writeJsonString(w, imp);
            }
            try w.writeAll("]}");
        }
        try w.writeAll("},");

        // Dependencies
        try w.writeAll("\"deps\":[");
        var first_dep = true;
        var d_it = exp.depgraph.imports.iterator();
        while (d_it.next()) |entry| {
            const from_id = entry.key_ptr.*;
            for (entry.value_ptr.items) |to_id| {
                if (!first_dep) try w.writeAll(",");
                first_dep = false;
                try w.print("[{d},{d}]", .{ from_id, to_id });
            }
        }
        try w.writeAll("]}");
        try w.flush();
        try file.sync(io.io());
        file.close(io.io());
        closed = true;

        // Rename tmp to final (atomic on POSIX)
        try io.cwd().rename(tmp_path, io.cwd(), path, io.io());
    }

    /// Load explorer state from JSON snapshot.
    pub fn load(allocator: std.mem.Allocator, path: []const u8) !explorer_mod.Explorer {
        const content = try io.readFileAlloc(allocator, path, 100 * 1024 * 1024); // 100MB max
        defer allocator.free(content);

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
        defer parsed.deinit();

        const root = parsed.value.object;

        // Check version
        const version = root.get("version") orelse return error.InvalidSnapshot;
        if (version.integer != SNAPSHOT_VERSION) return error.IncompatibleVersion;

        var exp = explorer_mod.Explorer.init(allocator);
        errdefer exp.deinit();

        // Load files
        const files_arr = (root.get("files") orelse return error.InvalidSnapshot).array;
        for (files_arr.items) |f| {
            const path_str = try allocator.dupe(u8, f.string);
            try exp.files.append(allocator, path_str);
            try exp.file_map.put(path_str, @intCast(exp.files.items.len - 1));
        }

        // Load outlines
        const outlines_obj = (root.get("outlines") orelse return error.InvalidSnapshot).object;
        var oit = outlines_obj.iterator();
        while (oit.next()) |entry| {
            const id_str = entry.key_ptr.*;
            const id = std.fmt.parseInt(u32, id_str, 10) catch continue;
            const obj = entry.value_ptr.object;

            const lang_int = (obj.get("lang") orelse continue).integer;
            const byte_size: u64 = @intCast((obj.get("bytes") orelse continue).integer);
            const line_count: usize = @intCast((obj.get("lines") orelse continue).integer);

            // Symbols
            const syms_arr = (obj.get("symbols") orelse continue).array;
            var symbols = try allocator.alloc(models.Symbol, syms_arr.items.len);
            for (syms_arr.items, 0..) |s, i| {
                const sobj = s.object;
                symbols[i] = .{
                    .name = try allocator.dupe(u8, (sobj.get("n") orelse continue).string),
                    .kind = @enumFromInt(@as(u32, @intCast((sobj.get("k") orelse continue).integer))),
                    .line_start = @intCast((sobj.get("s") orelse continue).integer),
                    .line_end = @intCast((sobj.get("e") orelse continue).integer),
                    .detail = if (sobj.get("d")) |d| try allocator.dupe(u8, d.string) else null,
                };
            }

            // Imports
            const imps_arr = (obj.get("imports") orelse continue).array;
            var imports = try allocator.alloc([]const u8, imps_arr.items.len);
            for (imps_arr.items, 0..) |imp, i| {
                imports[i] = try allocator.dupe(u8, imp.string);
            }

            try exp.outlines.put(id, .{
                .path = try allocator.dupe(u8, exp.files.items[id]),
                .language = @enumFromInt(@as(u32, @intCast(lang_int))),
                .byte_size = byte_size,
                .line_count = line_count,
                .symbols = symbols,
                .imports = imports,
            });
        }

        // Load deps
        if (root.get("deps")) |deps_val| {
            for (deps_val.array.items) |pair| {
                const arr = pair.array;
                if (arr.items.len == 2) {
                    const from: u32 = @intCast(arr.items[0].integer);
                    const to: u32 = @intCast(arr.items[1].integer);
                    try exp.depgraph.add_dependency(from, to);
                }
            }
        }

        // Rebuild the in-RAM search indexes (trigram + word) and prime the
        // bounded content cache by re-reading files from disk. The snapshot only
        // persists outlines/deps, so without this search would return nothing.
        for (exp.files.items, 0..) |fp, idx| {
            const fid: u32 = @intCast(idx);
            if (exp.outlines.get(fid) == null) continue;
            const fc = io.readFileAlloc(allocator, fp, 10 * 1024 * 1024) catch continue;
            defer allocator.free(fc);
            exp.prime_file(fid, fc) catch continue;
        }

        return exp;
    }

    /// Check if a snapshot is stale (files on disk changed since snapshot was created).
    pub fn is_stale(allocator: std.mem.Allocator, path: []const u8, workspace: []const u8) bool {
        const snap_stat = io.cwd().statFile(io.io(), path, .{}) catch return true;
        const snap_mtime = snap_stat.mtime;

        var dir = io.cwd().openDir(io.io(), workspace, .{ .iterate = true }) catch return true;
        defer dir.close(io.io());
        var walker = dir.walk(allocator) catch return true;
        defer walker.deinit();

        while (walker.next(io.io()) catch null) |entry| {
            if (entry.kind != .file) continue;
            const stat = entry.dir.statFile(io.io(), entry.basename, .{}) catch continue;
            if (stat.mtime > snap_mtime) return true;
        }
        return false;
    }
};

fn writeJsonString(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{x:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
    try writer.writeByte('"');
}

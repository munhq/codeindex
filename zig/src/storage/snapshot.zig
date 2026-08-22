const std = @import("std");
const explorer_mod = @import("../index/explorer.zig");
const models = @import("../core/models.zig");
const treesitter = @import("../parser/treesitter.zig");
const io = @import("../core/io.zig");

/// Bumped to 3 to add the `workspace` stamp and the per-file mtime/size pairs.
/// A version-2 file carries neither, so it cannot be checked for identity or
/// staleness and is rejected rather than trusted.
///
/// Bumped to 4 to store every path relative to the workspace. Version 3 stored
/// whatever form the run happened to use, so the same file was `./main.zig`
/// under the default root and `/abs/main.zig` under `--workspace /abs`. Two
/// launch modes over one project then produced two entries per file, and the
/// reconcile pass matched neither set — it re-indexed all of them and deleted
/// the others on every start. See the stamp rule in `load_into`.
const SNAPSHOT_VERSION: u32 = 4;

/// Strip the workspace prefix so a stored path names the file inside the
/// project, not on this machine. A path outside the workspace cannot be made
/// relative to it, so it is stored as it is and rejected on load.
fn to_workspace_relative(path: []const u8, workspace_abs: []const u8) []const u8 {
    if (workspace_abs.len == 0) return path;
    if (path.len > workspace_abs.len and
        std.mem.startsWith(u8, path, workspace_abs) and
        (path[workspace_abs.len] == io.key_sep or path[workspace_abs.len] == '\\'))
    {
        return path[workspace_abs.len + 1 ..];
    }
    // The default root is the cwd, which the walk joins as "./x".
    if (std.mem.startsWith(u8, path, "./")) return path[2..];
    return path;
}

/// What the snapshot recorded about each indexed file, keyed by path. The
/// reconcile pass compares these against the files on disk to find what changed
/// while the server was not running.
pub const Stamps = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMap(io.Stamp),

    pub fn init(allocator: std.mem.Allocator) Stamps {
        return .{ .allocator = allocator, .map = std.StringHashMap(io.Stamp).init(allocator) };
    }

    pub fn deinit(self: *Stamps) void {
        var it = self.map.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.map.deinit();
    }

    fn put(self: *Stamps, path: []const u8, stamp: io.Stamp) !void {
        const gop = try self.map.getOrPut(path);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, path);
        }
        gop.value_ptr.* = stamp;
    }
};

pub const Snapshot = struct {
    /// Save explorer state as JSON snapshot.
    ///
    /// `workspace_abs` is the canonical absolute path of the indexed directory.
    /// It is written into the file so a later load can tell whether the snapshot
    /// describes this project or another one; without it a snapshot is just a
    /// file sitting in a directory, and any `version`-compatible file found at
    /// the path was loaded and served as the truth.
    pub fn save(exp: *explorer_mod.Explorer, path: []const u8, workspace_abs: []const u8) !void {
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
        try w.print("\"extractor\":{d},", .{treesitter.EXTRACTION_VERSION});
        try w.writeAll("\"workspace\":");
        try writeJsonString(w, workspace_abs);
        try w.writeAll(",");

        // Files array. Position in this array IS the file id, so every slot is
        // written — including ids whose file was deleted — to keep ids aligned
        // with the outline keys below. Each entry carries the mtime and size
        // seen at save time so the next load can tell what changed since.
        //
        // A slot with no live outline gets a zero stamp. Its file is not in the
        // index, so claiming a stamp for it would tell the reconcile pass the
        // file is already indexed and up to date, and the file would never be
        // parsed again.
        try w.writeAll("\"files\":[");
        for (exp.files.items, 0..) |f, i| {
            if (i > 0) try w.writeAll(",");
            try w.writeAll("{\"p\":");
            try writeJsonString(w, to_workspace_relative(f, workspace_abs));
            const indexed = exp.outlines.get(@intCast(i)) != null and
                exp.deleted_files.get(@intCast(i)) == null;
            const stamp = if (indexed) io.stampFile(f) else null;
            try w.print(",\"m\":{d},\"b\":{d}}}", .{
                if (stamp) |s| s.mtime_ns else 0,
                if (stamp) |s| s.size else 0,
            });
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

    /// Populate an already-initialized (empty) Explorer from a JSON snapshot, in
    /// place. The MCP server holds the Explorer by pointer and keeps serving from
    /// it while a background thread runs this — so we must fill the existing value
    /// rather than bit-copy a new one over it (Explorer embeds RwLocks as fields,
    /// which a struct move would corrupt). The reprime loop at the end re-reads
    /// every file to rebuild the search indexes; it is the slow part, and running
    /// it here — off the MCP `initialize`/`tools/list` handshake path — is the
    /// whole point. The caller owns `exp` and deinits it on error.
    ///
    /// Refuses a snapshot that does not name `workspace_abs`. That check is the
    /// difference between an index and a guess: the file is found by path, and a
    /// path can hold the snapshot of a project that used to live there, or of a
    /// different project entirely when `--workspace` points elsewhere. A wrong
    /// snapshot loads cleanly and then answers every question about the wrong
    /// code, which is worse than not loading at all.
    ///
    /// Fills `stamps` with the mtime/size recorded per file, for the reconcile
    /// pass that follows.
    pub fn load_into(
        exp: *explorer_mod.Explorer,
        allocator: std.mem.Allocator,
        path: []const u8,
        workspace_abs: []const u8,
        stamps: *Stamps,
    ) !void {
        const content = try io.readFileAlloc(allocator, path, 100 * 1024 * 1024); // 100MB max
        defer allocator.free(content);

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
        defer parsed.deinit();

        const root = parsed.value.object;

        // Check version
        const version = root.get("version") orelse return error.InvalidSnapshot;
        if (version.integer != SNAPSHOT_VERSION) return error.IncompatibleVersion;

        // Check identity before reading anything else.
        const ws = root.get("workspace") orelse return error.InvalidSnapshot;
        if (ws != .string) return error.InvalidSnapshot;
        if (!std.mem.eql(u8, ws.string, workspace_abs)) return error.WorkspaceMismatch;

        // Outlines are replayed as saved, so a snapshot written by a different
        // extractor would keep serving that extractor's answers for every file
        // that has not changed since. Rescan instead.
        const extractor = if (root.get("extractor")) |e| e.integer else 0;
        if (extractor != treesitter.EXTRACTION_VERSION) return error.ExtractorMismatch;

        // Load files. Stored paths are workspace-relative (version 4), so the
        // absolute key every other component uses is rebuilt here against the
        // workspace this process resolved. The index therefore survives a moved
        // or renamed checkout, and does not depend on how the server was
        // launched.
        //
        // The raw stamps are held aside rather than inserted here: a stamp says
        // "this file is in the index and was current at save time", and that is
        // only true once the outline pass below has actually loaded an outline
        // for the slot. Stamping every slot let a file with no outline count as
        // unchanged, so the reconcile pass skipped it and it stayed missing from
        // the index for the life of the snapshot.
        const files_arr = (root.get("files") orelse return error.InvalidSnapshot).array;
        var raw_stamps = try allocator.alloc(io.Stamp, files_arr.items.len);
        defer allocator.free(raw_stamps);
        for (files_arr.items, 0..) |f, i| {
            if (f != .object) return error.InvalidSnapshot;
            const entry = f.object;
            const p = entry.get("p") orelse return error.InvalidSnapshot;
            if (p != .string) return error.InvalidSnapshot;
            const path_str = if (std.fs.path.isAbsolute(p.string))
                io.normalizeKey(try allocator.dupe(u8, p.string))
            else
                try io.joinKey(allocator, &.{ workspace_abs, p.string });
            try exp.files.append(allocator, path_str);
            try exp.file_map.put(path_str, @intCast(exp.files.items.len - 1));

            const mtime = if (entry.get("m")) |m| m.integer else 0;
            const size = if (entry.get("b")) |b| b.integer else 0;
            raw_stamps[i] = .{ .mtime_ns = mtime, .size = @intCast(@max(size, 0)) };
        }

        // Load outlines
        const outlines_obj = (root.get("outlines") orelse return error.InvalidSnapshot).object;
        var oit = outlines_obj.iterator();
        while (oit.next()) |entry| {
            const id_str = entry.key_ptr.*;
            const id = std.fmt.parseInt(u32, id_str, 10) catch continue;
            // An outline id names a slot in the files array. A truncated or
            // hand-edited snapshot can name one that is not there, and indexing
            // the array with it would abort the process rather than reject the
            // file.
            if (id >= exp.files.items.len) continue;
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
        //
        // This is also where the stamps held back above are published: a slot
        // that reached this point has an outline, so "unchanged" now means "in
        // the index and current", which is what the reconcile pass assumes.
        for (exp.files.items, 0..) |fp, idx| {
            const fid: u32 = @intCast(idx);
            if (exp.outlines.get(fid) == null) continue;
            try stamps.put(fp, raw_stamps[idx]);
            const fc = io.readFileAlloc(allocator, fp, 10 * 1024 * 1024) catch continue;
            defer allocator.free(fc);
            exp.prime_file(fid, fc) catch continue;
        }
    }

    // A whole-snapshot `is_stale` check used to live here. Nothing ever called
    // it, so a snapshot was trusted however old it was, and it answered a
    // one-bit question ("something changed") whose only useful answer was to
    // throw the index away and rescan. The per-file stamps above replace it:
    // scanner.reconcile_tree re-parses the files that actually changed and
    // leaves the rest, which is both cheaper and more precise.
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

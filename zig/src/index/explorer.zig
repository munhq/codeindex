const std = @import("std");
const models = @import("../core/models.zig");
const version_mod = @import("version.zig");
const imports_resolver = @import("../resolver/imports.zig");

pub const TrigramIndex = struct {
    allocator: std.mem.Allocator,
    map: std.AutoHashMap(u24, std.ArrayList(u64)),

    pub fn init(allocator: std.mem.Allocator) TrigramIndex {
        return .{
            .allocator = allocator,
            .map = std.AutoHashMap(u24, std.ArrayList(u64)).init(allocator),
        };
    }

    pub fn deinit(self: *TrigramIndex) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.map.deinit();
    }

    pub fn add_text(self: *TrigramIndex, file_id: u32, content: []const u8) !void {
        var line_num: u32 = 0;
        var line_it = std.mem.splitScalar(u8, content, '\n');
        while (line_it.next()) |line| {
            if (line.len < 3) {
                line_num += 1;
                continue;
            }

            for (0..line.len - 2) |i| {
                const trigram = @as(u24, line[i]) | (@as(u24, line[i + 1]) << 8) | (@as(u24, line[i + 2]) << 16);
                const gop = try self.map.getOrPut(trigram);
                if (!gop.found_existing) {
                    gop.value_ptr.* = std.ArrayList(u64){};
                }
                const entry = (@as(u64, file_id) << 32) | line_num;
                if (gop.value_ptr.items.len == 0 or gop.value_ptr.items[gop.value_ptr.items.len - 1] != entry) {
                    try gop.value_ptr.append(self.allocator, entry);
                }
            }
            line_num += 1;
        }
    }

    pub fn remove_file(self: *TrigramIndex, file_id: u32) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            var list = entry.value_ptr;
            var i: usize = 0;
            while (i < list.items.len) {
                if (@as(u32, @intCast(list.items[i] >> 32)) == file_id) {
                    _ = list.swapRemove(i);
                } else {
                    i += 1;
                }
            }
        }
    }

    pub fn query(self: *TrigramIndex, text: []const u8) ![]u64 {
        if (text.len < 3) return &[_]u64{};

        var results: ?std.ArrayList(u64) = null;
        defer if (results) |*r| r.deinit(self.allocator);

        for (0..text.len - 2) |i| {
            const trigram = @as(u24, text[i]) | (@as(u24, text[i + 1]) << 8) | (@as(u24, text[i + 2]) << 16);
            const locations = self.map.get(trigram) orelse return &[_]u64{};

            if (results == null) {
                results = try std.ArrayList(u64).initCapacity(self.allocator, locations.items.len);
                try results.?.appendSlice(self.allocator, locations.items);
            } else {
                var new_results = std.ArrayList(u64){};
                var r_idx: usize = 0;
                var l_idx: usize = 0;
                const r_items = results.?.items;
                const l_items = locations.items;

                while (r_idx < r_items.len and l_idx < l_items.len) {
                    if (r_items[r_idx] == l_items[l_idx]) {
                        try new_results.append(self.allocator, r_items[r_idx]);
                        r_idx += 1;
                        l_idx += 1;
                    } else if (r_items[r_idx] < l_items[l_idx]) {
                        r_idx += 1;
                    } else {
                        l_idx += 1;
                    }
                }
                results.?.deinit(self.allocator);
                results = new_results;
            }
            if (results.?.items.len == 0) break;
        }

        return if (results) |*r| try r.toOwnedSlice(self.allocator) else &[_]u64{};
    }
};

pub const WordIndex = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMap(std.ArrayList(u64)),

    pub fn init(allocator: std.mem.Allocator) WordIndex {
        return .{
            .allocator = allocator,
            .map = std.StringHashMap(std.ArrayList(u64)).init(allocator),
        };
    }

    pub fn deinit(self: *WordIndex) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.map.deinit();
    }

    pub fn add_text(self: *WordIndex, file_id: u32, content: []const u8) !void {
        var line_num: u32 = 0;
        var line_it = std.mem.splitScalar(u8, content, '\n');
        while (line_it.next()) |line| {
            var word_it = std.mem.tokenizeAny(u8, line, " \t\n\r(){}[];:.,\"'<>?!=+-*/&|^%~#@`");
            while (word_it.next()) |word| {
                if (word.len < 2) continue;
                const entry = (@as(u64, file_id) << 32) | line_num;

                const gop = try self.map.getOrPut(word);
                if (!gop.found_existing) {
                    gop.key_ptr.* = try self.allocator.dupe(u8, word);
                    gop.value_ptr.* = std.ArrayList(u64){};
                }

                if (gop.value_ptr.items.len == 0 or gop.value_ptr.items[gop.value_ptr.items.len - 1] != entry) {
                    try gop.value_ptr.append(self.allocator, entry);
                }
            }
            line_num += 1;
        }
    }

    pub fn remove_file(self: *WordIndex, file_id: u32) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            var list = entry.value_ptr;
            var i: usize = 0;
            while (i < list.items.len) {
                if (@as(u32, @intCast(list.items[i] >> 32)) == file_id) {
                    _ = list.swapRemove(i);
                } else {
                    i += 1;
                }
            }
        }
    }

    pub fn search(self: *const WordIndex, word: []const u8) []const u64 {
        if (self.map.get(word)) |list| {
            return list.items;
        }
        return &[_]u64{};
    }
};

pub const DepGraph = struct {
    allocator: std.mem.Allocator,
    imports: std.AutoHashMap(u32, std.ArrayList(u32)),
    reverse_deps: std.AutoHashMap(u32, std.ArrayList(u32)),

    pub fn init(allocator: std.mem.Allocator) DepGraph {
        return .{
            .allocator = allocator,
            .imports = std.AutoHashMap(u32, std.ArrayList(u32)).init(allocator),
            .reverse_deps = std.AutoHashMap(u32, std.ArrayList(u32)).init(allocator),
        };
    }

    pub fn deinit(self: *DepGraph) void {
        var it = self.imports.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit(self.allocator);
        self.imports.deinit();

        var it2 = self.reverse_deps.iterator();
        while (it2.next()) |entry| entry.value_ptr.deinit(self.allocator);
        self.reverse_deps.deinit();
    }

    pub fn add_dependency(self: *DepGraph, from: u32, to: u32) !void {
        const i_gop = try self.imports.getOrPut(from);
        if (!i_gop.found_existing) i_gop.value_ptr.* = std.ArrayList(u32){};

        for (i_gop.value_ptr.items) |id| {
            if (id == to) return;
        }
        try i_gop.value_ptr.append(self.allocator, to);

        const r_gop = try self.reverse_deps.getOrPut(to);
        if (!r_gop.found_existing) r_gop.value_ptr.* = std.ArrayList(u32){};
        try r_gop.value_ptr.append(self.allocator, from);
    }

    pub fn clear_file(self: *DepGraph, file_id: u32) void {
        if (self.imports.getPtr(file_id)) |list| {
            for (list.items) |imported_id| {
                if (self.reverse_deps.getPtr(imported_id)) |rev_list| {
                    var i: usize = 0;
                    while (i < rev_list.items.len) {
                        if (rev_list.items[i] == file_id) {
                            _ = rev_list.swapRemove(i);
                        } else {
                            i += 1;
                        }
                    }
                }
            }
            list.clearRetainingCapacity();
        }
    }
};

// ── Result types ─────────────────────────────────────────────────────────────

pub const SymbolResult = struct {
    path: []const u8,
    symbol: models.Symbol,
};

pub const WordHit = struct {
    path: []const u8,
    line_num: u32,
};

pub const ScopedSearchResult = struct {
    path: []const u8,
    line_num: u32,
    line_text: []const u8,
    scope_name: ?[]const u8 = null,
    scope_kind: ?models.SymbolKind = null,
};

pub const CallerHit = struct {
    path: []const u8,
    line_num: u32,
    line_text: []const u8,
    /// Context kind inferred from the surrounding characters:
    /// - "call": looks like foo(
    /// - "method": looks like .foo( or ->foo(
    /// - "path": looks like ::foo or Foo::foo
    /// - "other": word hit without a clear call shape (filtered out in strict mode)
    context: []const u8,
};

// ── Explorer ─────────────────────────────────────────────────────────────────

pub const Explorer = struct {
    allocator: std.mem.Allocator,
    trigrams: TrigramIndex,
    words: WordIndex,
    depgraph: DepGraph,
    files: std.ArrayList([]const u8),
    file_map: std.StringHashMap(u32),
    outlines: std.AutoHashMap(u32, models.FileOutline),
    deleted_files: std.AutoHashMap(u32, void),
    version: version_mod.VersionStore,
    indexing: bool,
    content_cache: std.AutoHashMap(u32, []const u8),
    cache_bytes: usize,
    max_cache_bytes: usize,
    cache_order: std.ArrayList(u32), // LRU order: oldest at front, newest at back

    // Per-index RwLocks for concurrent read access during writes
    trigram_lock: std.Thread.RwLock = .{},
    word_lock: std.Thread.RwLock = .{},
    outline_lock: std.Thread.RwLock = .{},
    dep_lock: std.Thread.RwLock = .{},
    content_lock: std.Thread.RwLock = .{},
    file_lock: std.Thread.RwLock = .{},

    pub fn init(allocator: std.mem.Allocator) Explorer {
        return .{
            .allocator = allocator,
            .trigrams = TrigramIndex.init(allocator),
            .words = WordIndex.init(allocator),
            .depgraph = DepGraph.init(allocator),
            .files = std.ArrayList([]const u8){},
            .file_map = std.StringHashMap(u32).init(allocator),
            .outlines = std.AutoHashMap(u32, models.FileOutline).init(allocator),
            .deleted_files = std.AutoHashMap(u32, void).init(allocator),
            .version = version_mod.VersionStore.init(allocator),
            .indexing = true,
            .content_cache = std.AutoHashMap(u32, []const u8).init(allocator),
            .cache_bytes = 0,
            .max_cache_bytes = 50 * 1024 * 1024,
            .cache_order = std.ArrayList(u32){},
        };
    }

    pub fn deinit(self: *Explorer) void {
        self.trigrams.deinit();
        self.words.deinit();
        self.depgraph.deinit();
        for (self.files.items) |f| self.allocator.free(f);
        self.files.deinit(self.allocator);
        self.file_map.deinit();
        var it = self.outlines.iterator();
        while (it.next()) |entry| {
            var o = entry.value_ptr.*;
            o.deinit(self.allocator);
        }
        self.outlines.deinit();
        self.deleted_files.deinit();
        self.version.deinit();
        var cache_it = self.content_cache.iterator();
        while (cache_it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.content_cache.deinit();
        self.cache_order.deinit(self.allocator);
    }

    /// Evict oldest cache entries until under max_cache_bytes.
    fn evict_cache(self: *Explorer) void {
        while (self.cache_bytes > self.max_cache_bytes and self.cache_order.items.len > 0) {
            const victim_id = self.cache_order.orderedRemove(0);
            if (self.content_cache.getPtr(victim_id)) |content| {
                self.cache_bytes -= content.*.len;
                self.allocator.free(content.*);
                _ = self.content_cache.remove(victim_id);
            }
        }
    }

    /// Touch a file_id in the LRU order (move to back = most recently used).
    fn cache_touch(self: *Explorer, file_id: u32) void {
        // Remove existing entry if present
        for (self.cache_order.items, 0..) |id, i| {
            if (id == file_id) {
                _ = self.cache_order.orderedRemove(i);
                break;
            }
        }
        // Add to back (most recent)
        self.cache_order.append(self.allocator, file_id) catch {};
    }

    pub fn mark_indexing_complete(self: *Explorer) void {
        self.indexing = false;
    }

    pub fn is_indexing(self: *Explorer) bool {
        return self.indexing;
    }

    // ── Mutation ──────────────────────────────────────────────────────────────

    pub fn add_file(self: *Explorer, outline: models.FileOutline, content: []const u8) !u32 {
        self.file_lock.lock();
        defer self.file_lock.unlock();
        self.trigram_lock.lock();
        defer self.trigram_lock.unlock();
        self.word_lock.lock();
        defer self.word_lock.unlock();
        self.outline_lock.lock();
        defer self.outline_lock.unlock();
        self.dep_lock.lock();
        defer self.dep_lock.unlock();
        self.content_lock.lock();
        defer self.content_lock.unlock();

        const op: models.ChangeOp = if (self.file_map.get(outline.path)) |_| .modified else .added;

        if (self.file_map.get(outline.path)) |existing_id| {
            _ = self.deleted_files.remove(existing_id);
            if (self.outlines.getPtr(existing_id)) |old_outline| {
                old_outline.deinit(self.allocator);
            }
            try self.outlines.put(existing_id, outline);

            // Clear old index entries and re-add
            self.trigrams.remove_file(existing_id);
            self.words.remove_file(existing_id);
            try self.trigrams.add_text(existing_id, content);
            try self.words.add_text(existing_id, content);

            // Update content cache
            if (self.content_cache.getPtr(existing_id)) |old_content| {
                self.cache_bytes -= old_content.*.len;
                self.allocator.free(old_content.*);
            }
            const cached = try self.allocator.dupe(u8, content);
            try self.content_cache.put(existing_id, cached);
            self.cache_bytes += cached.len;
            self.cache_touch(existing_id);
            self.evict_cache();

            self.depgraph.clear_file(existing_id);
            try self.resolve_imports(existing_id, outline.imports);

            try self.version.record(outline.path, op);
            return existing_id;
        }

        const file_id = @as(u32, @intCast(self.files.items.len));
        const path_dup = try self.allocator.dupe(u8, outline.path);
        try self.files.append(self.allocator, path_dup);
        try self.file_map.put(path_dup, file_id);

        try self.trigrams.add_text(file_id, content);
        try self.words.add_text(file_id, content);
        try self.outlines.put(file_id, outline);
        const cached_new = try self.allocator.dupe(u8, content);
        try self.content_cache.put(file_id, cached_new);
        self.cache_bytes += cached_new.len;
        self.cache_touch(file_id);
        self.evict_cache();

        try self.resolve_imports(file_id, outline.imports);

        try self.version.record(outline.path, op);
        return file_id;
    }

    pub fn remove_file(self: *Explorer, path: []const u8) !void {
        self.file_lock.lock();
        defer self.file_lock.unlock();
        self.trigram_lock.lock();
        defer self.trigram_lock.unlock();
        self.word_lock.lock();
        defer self.word_lock.unlock();
        self.outline_lock.lock();
        defer self.outline_lock.unlock();
        self.dep_lock.lock();
        defer self.dep_lock.unlock();
        self.content_lock.lock();
        defer self.content_lock.unlock();
        if (self.file_map.get(path)) |file_id| {
            // Clean up all indexes
            self.trigrams.remove_file(file_id);
            self.words.remove_file(file_id);
            self.depgraph.clear_file(file_id);

            if (self.outlines.getPtr(file_id)) |outline| {
                outline.deinit(self.allocator);
                _ = self.outlines.remove(file_id);
            }
            if (self.content_cache.getPtr(file_id)) |content| {
                self.cache_bytes -= content.*.len;
                self.allocator.free(content.*);
                _ = self.content_cache.remove(file_id);
            }
            // Remove from LRU order
            for (self.cache_order.items, 0..) |id, i| {
                if (id == file_id) {
                    _ = self.cache_order.orderedRemove(i);
                    break;
                }
            }

            try self.deleted_files.put(file_id, {});
            try self.version.record(path, .deleted);
        }
    }

    fn resolve_imports(self: *Explorer, file_id: u32, imports: [][]const u8) !void {
        const outline = self.outlines.get(file_id) orelse return;
        const source_path = outline.path;

        for (imports) |imp| {
            const resolved = imports_resolver.resolve(
                self.allocator,
                imp,
                outline.language,
                source_path,
                self.files.items,
            ) catch continue;
            defer self.allocator.free(resolved);

            for (resolved) |resolved_path| {
                if (self.file_map.get(resolved_path)) |target_id| {
                    if (target_id == file_id) continue; // never self-loop
                    try self.depgraph.add_dependency(file_id, target_id);
                }
            }

            // Fallback: if resolver found nothing and the import is long enough to be specific,
            // try a path-segment substring match. Skip short bare identifiers (too broad).
            if (resolved.len == 0 and imp.len >= 6) {
                var it = self.file_map.iterator();
                while (it.next()) |entry| {
                    if (entry.value_ptr.* == file_id) continue; // never self-loop
                    if (std.mem.indexOf(u8, entry.key_ptr.*, imp) != null) {
                        try self.depgraph.add_dependency(file_id, entry.value_ptr.*);
                    }
                }
            }
        }
    }

    // ── Queries ───────────────────────────────────────────────────────────────

    pub fn file_count(self: *Explorer) usize {
        self.outline_lock.lockShared();
        defer self.outline_lock.unlockShared();
        return self.outlines.count();
    }

    pub fn symbol_count(self: *Explorer) usize {
        self.outline_lock.lockShared();
        defer self.outline_lock.unlockShared();
        var count: usize = 0;
        var it = self.outlines.iterator();
        while (it.next()) |entry| {
            count += entry.value_ptr.symbols.len;
        }
        return count;
    }

    pub fn latest_seq(self: *Explorer) u64 {
        return self.version.latest_seq();
    }

    pub fn get_all_outlines(self: *Explorer) *std.AutoHashMap(u32, models.FileOutline) {
        self.outline_lock.lockShared();
        defer self.outline_lock.unlockShared();
        return &self.outlines;
    }

    pub fn get_outline(self: *Explorer, path: []const u8) ?models.FileOutline {
        self.outline_lock.lockShared();
        defer self.outline_lock.unlockShared();
        self.file_lock.lockShared();
        defer self.file_lock.unlockShared();
        const file_id = self.file_map.get(path) orelse return null;
        if (self.deleted_files.get(file_id) != null) return null;
        return self.outlines.get(file_id);
    }

    /// Find symbol definitions by name (substring match).
    pub fn find_symbol(self: *Explorer, name: []const u8, limit: usize) ![]SymbolResult {
        self.outline_lock.lockShared();
        defer self.outline_lock.unlockShared();
        var results = std.ArrayList(SymbolResult){};
        var it = self.outlines.iterator();
        while (it.next()) |entry| {
            const file_id = entry.key_ptr.*;
            if (self.deleted_files.get(file_id) != null) continue;
            const outline = entry.value_ptr.*;
            for (outline.symbols) |sym| {
                if (std.mem.indexOf(u8, sym.name, name) != null) {
                    try results.append(self.allocator, .{
                        .path = outline.path,
                        .symbol = sym,
                    });
                    if (results.items.len >= limit) {
                        return try results.toOwnedSlice(self.allocator);
                    }
                }
            }
        }
        return try results.toOwnedSlice(self.allocator);
    }

    /// Search file contents using trigram-accelerated search.
    pub fn search_content(self: *Explorer, query_text: []const u8, limit: usize) ![]ScopedSearchResult {
        self.trigram_lock.lockShared();
        defer self.trigram_lock.unlockShared();
        self.content_lock.lockShared();
        defer self.content_lock.unlockShared();
        self.outline_lock.lockShared();
        defer self.outline_lock.unlockShared();
        var results = std.ArrayList(ScopedSearchResult){};

        // Get candidate file+line pairs from trigram index
        const candidates = try self.trigrams.query(query_text);
        defer if (candidates.len > 0) self.allocator.free(candidates);

        // Deduplicate by file_id and do line-level verification
        var seen_files = std.AutoHashMap(u32, void).init(self.allocator);
        defer seen_files.deinit();

        for (candidates) |entry_val| {
            const file_id = @as(u32, @intCast(entry_val >> 32));
            if (self.deleted_files.get(file_id) != null) continue;
            if (seen_files.get(file_id) != null) continue;
            try seen_files.put(file_id, {});

            const content = self.content_cache.get(file_id) orelse continue;
            const outline = self.outlines.get(file_id) orelse continue;

            var line_num: u32 = 1;
            var line_it = std.mem.splitScalar(u8, content, '\n');
            while (line_it.next()) |line| {
                if (std.mem.indexOf(u8, line, query_text) != null) {
                    // Find enclosing scope
                    const scope = find_scope(outline.symbols, line_num);
                    try results.append(self.allocator, .{
                        .path = outline.path,
                        .line_num = line_num,
                        .line_text = line,
                        .scope_name = if (scope) |s| s.name else null,
                        .scope_kind = if (scope) |s| s.kind else null,
                    });
                    if (results.items.len >= limit) {
                        return try results.toOwnedSlice(self.allocator);
                    }
                }
                line_num += 1;
            }
        }
        return try results.toOwnedSlice(self.allocator);
    }

    /// Approximate callers: word-index hits for `name` where the surrounding
    /// characters suggest a call/method/path reference, excluding the defining
    /// line. This is a stand-in for a real call graph — ~80% of the value with
    /// no name resolution. False positives: shadowed names, same-name methods
    /// on different types, comments.
    pub fn find_callers(self: *Explorer, name: []const u8, limit: usize) ![]CallerHit {
        self.word_lock.lockShared();
        defer self.word_lock.unlockShared();
        self.file_lock.lockShared();
        defer self.file_lock.unlockShared();
        self.content_lock.lockShared();
        defer self.content_lock.unlockShared();
        self.outline_lock.lockShared();
        defer self.outline_lock.unlockShared();

        // Collect (file_id -> set of defining line numbers) so we can skip them.
        var def_lines = std.AutoHashMap(u64, void).init(self.allocator);
        defer def_lines.deinit();
        var oit = self.outlines.iterator();
        while (oit.next()) |entry| {
            const fid = entry.key_ptr.*;
            for (entry.value_ptr.symbols) |sym| {
                if (!std.mem.eql(u8, sym.name, name)) continue;
                // Symbol line_start/line_end and WordIndex line_num are both 0-based.
                var ln: usize = sym.line_start;
                while (ln <= sym.line_end) : (ln += 1) {
                    const key: u64 = (@as(u64, fid) << 32) | @as(u64, @intCast(ln));
                    try def_lines.put(key, {});
                }
            }
        }

        var results = std.ArrayList(CallerHit){};
        errdefer {
            for (results.items) |h| self.allocator.free(h.line_text);
            results.deinit(self.allocator);
        }

        const hits = self.words.search(name);
        for (hits) |entry_val| {
            const file_id: u32 = @intCast(entry_val >> 32);
            const line_num_0: u32 = @intCast(entry_val & 0xFFFFFFFF);
            if (self.deleted_files.get(file_id) != null) continue;
            if (file_id >= self.files.items.len) continue;

            // Skip lines that fall inside the symbol's own definition.
            if (def_lines.get(entry_val) != null) continue;

            const content = self.content_cache.get(file_id) orelse continue;
            // Scan to the requested line (0-based).
            var line_text: []const u8 = "";
            var cur_line: u32 = 0;
            var it = std.mem.splitScalar(u8, content, '\n');
            while (it.next()) |l| {
                if (cur_line == line_num_0) {
                    line_text = l;
                    break;
                }
                cur_line += 1;
            }
            if (line_text.len == 0) continue;

            // Find `name` occurrences in the line and classify context.
            var search_start: usize = 0;
            var picked: ?[]const u8 = null;
            while (std.mem.indexOfPos(u8, line_text, search_start, name)) |pos| {
                defer search_start = pos + name.len;
                // Word boundary on the left
                if (pos > 0) {
                    const p = line_text[pos - 1];
                    if (std.ascii.isAlphanumeric(p) or p == '_') continue;
                }
                const end = pos + name.len;
                if (end < line_text.len) {
                    const n = line_text[end];
                    if (std.ascii.isAlphanumeric(n) or n == '_') continue;
                }

                // Classify: call / method / path
                var ctx: []const u8 = "other";
                // Call: `name(`
                if (end < line_text.len and line_text[end] == '(') ctx = "call";
                // Method: `.name(` or `->name(`
                if (pos > 0 and line_text[pos - 1] == '.' and end < line_text.len and line_text[end] == '(') ctx = "method";
                if (pos >= 2 and line_text[pos - 2] == '-' and line_text[pos - 1] == '>' and end < line_text.len and line_text[end] == '(') ctx = "method";
                // Path reference: `::name` or `name::`
                if (pos >= 2 and line_text[pos - 2] == ':' and line_text[pos - 1] == ':') ctx = "path";
                if (end + 1 < line_text.len and line_text[end] == ':' and line_text[end + 1] == ':') ctx = "path";

                // Skip "other" to keep signal-to-noise high.
                if (!std.mem.eql(u8, ctx, "other")) {
                    picked = ctx;
                    break;
                }
            }

            if (picked) |ctx| {
                const trimmed = std.mem.trim(u8, line_text, " \t\r");
                try results.append(self.allocator, .{
                    .path = self.files.items[file_id],
                    .line_num = line_num_0 + 1, // report 1-based for user-facing display
                    .line_text = try self.allocator.dupe(u8, trimmed),
                    .context = ctx,
                });
                if (results.items.len >= limit) break;
            }
        }
        return try results.toOwnedSlice(self.allocator);
    }

    /// Look up an exact word in the inverted index.
    pub fn find_word(self: *Explorer, word: []const u8, limit: usize) ![]WordHit {
        self.word_lock.lockShared();
        defer self.word_lock.unlockShared();
        self.file_lock.lockShared();
        defer self.file_lock.unlockShared();
        var results = std.ArrayList(WordHit){};
        const hits = self.words.search(word);
        for (hits) |entry_val| {
            const file_id = @as(u32, @intCast(entry_val >> 32));
            const line_num = @as(u32, @intCast(entry_val & 0xFFFFFFFF));
            if (self.deleted_files.get(file_id) != null) continue;
            if (file_id >= self.files.items.len) continue;
            try results.append(self.allocator, .{
                .path = self.files.items[file_id],
                .line_num = line_num,
            });
            if (results.items.len >= limit) break;
        }
        return try results.toOwnedSlice(self.allocator);
    }

    /// Get forward dependencies: which files does this file import?
    pub fn get_imports(self: *Explorer, path: []const u8) []const u32 {
        self.dep_lock.lockShared();
        defer self.dep_lock.unlockShared();
        self.file_lock.lockShared();
        defer self.file_lock.unlockShared();
        const file_id = self.file_map.get(path) orelse return &[_]u32{};
        if (self.depgraph.imports.get(file_id)) |list| {
            return list.items;
        }
        return &[_]u32{};
    }

    /// Get reverse dependencies: which files import this file?
    pub fn get_imported_by(self: *Explorer, path: []const u8) []const u32 {
        self.dep_lock.lockShared();
        defer self.dep_lock.unlockShared();
        self.file_lock.lockShared();
        defer self.file_lock.unlockShared();
        const file_id = self.file_map.get(path) orelse return &[_]u32{};
        if (self.depgraph.reverse_deps.get(file_id)) |list| {
            return list.items;
        }
        return &[_]u32{};
    }

    /// Resolve file_id to path.
    pub fn file_path(self: *Explorer, file_id: u32) ?[]const u8 {
        self.file_lock.lockShared();
        defer self.file_lock.unlockShared();
        if (file_id >= self.files.items.len) return null;
        return self.files.items[file_id];
    }

    /// Get transitive change impact: all files affected if this file changes.
    /// Follows reverse dependency chain (who imports this → who imports them → ...).
    /// Returns (direct_count, transitive_ids) where transitive_ids includes direct deps.
    pub fn get_change_impact(self: *Explorer, path: []const u8, max_depth: usize) !ChangeImpact {
        self.dep_lock.lockShared();
        defer self.dep_lock.unlockShared();
        self.file_lock.lockShared();
        defer self.file_lock.unlockShared();

        const file_id = self.file_map.get(path) orelse return ChangeImpact{
            .direct = &[_]u32{},
            .transitive = &[_]u32{},
            .depth_reached = 0,
        };

        // BFS traversal of reverse dependencies
        var visited = std.AutoHashMap(u32, u32).init(self.allocator);
        defer visited.deinit();

        var queue = std.ArrayList(struct { id: u32, depth: u32 }){};
        defer queue.deinit(self.allocator);

        var direct = std.ArrayList(u32){};
        var all = std.ArrayList(u32){};
        var max_d: u32 = 0;

        // Seed with direct reverse deps
        if (self.depgraph.reverse_deps.get(file_id)) |rev| {
            for (rev.items) |rid| {
                if (self.deleted_files.get(rid) != null) continue;
                if (visited.get(rid) != null) continue;
                try visited.put(rid, 1);
                try direct.append(self.allocator, rid);
                try all.append(self.allocator, rid);
                try queue.append(self.allocator, .{ .id = rid, .depth = 1 });
            }
        }

        // BFS for transitive deps
        var qi: usize = 0;
        while (qi < queue.items.len) : (qi += 1) {
            const item = queue.items[qi];
            if (item.depth >= max_depth) continue;
            if (item.depth > max_d) max_d = item.depth;

            if (self.depgraph.reverse_deps.get(item.id)) |rev| {
                for (rev.items) |rid| {
                    if (self.deleted_files.get(rid) != null) continue;
                    if (visited.get(rid) != null) continue;
                    try visited.put(rid, item.depth + 1);
                    try all.append(self.allocator, rid);
                    try queue.append(self.allocator, .{ .id = rid, .depth = item.depth + 1 });
                }
            }
        }

        return ChangeImpact{
            .direct = try direct.toOwnedSlice(self.allocator),
            .transitive = try all.toOwnedSlice(self.allocator),
            .depth_reached = max_d,
        };
    }

    pub const ChangeImpact = struct {
        direct: []const u32,
        transitive: []const u32,
        depth_reached: u32,
    };

    /// Get recently changed files.
    pub fn get_hot_files(self: *Explorer, limit: usize) []const models.ChangeRecord {
        return self.version.hot_files(limit);
    }

    /// Get changes since a sequence number.
    pub fn changes_since(self: *Explorer, since: u64) struct { items: []const models.ChangeRecord, truncated: bool } {
        return self.version.changes_since(since);
    }

    /// Build directory tree from indexed outlines.
    pub fn get_tree(self: *Explorer) ![]models.TreeNode {
        self.outline_lock.lockShared();
        defer self.outline_lock.unlockShared();
        // Collect all paths into a tree structure
        var root_children = std.ArrayList(models.TreeNode){};

        var it = self.outlines.iterator();
        while (it.next()) |entry| {
            const file_id = entry.key_ptr.*;
            if (self.deleted_files.get(file_id) != null) continue;
            const outline = entry.value_ptr.*;

            // For simplicity, create flat file nodes (nested tree building is complex)
            try root_children.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, std.fs.path.basename(outline.path)),
                .path = try self.allocator.dupe(u8, outline.path),
                .is_dir = false,
                .children = &.{},
                .symbol_count = outline.symbols.len,
                .language = outline.language,
                .line_count = outline.line_count,
            });
        }

        return try root_children.toOwnedSlice(self.allocator);
    }

    /// Total bytes of all indexed file content.
    pub fn total_content_bytes(self: *Explorer) u64 {
        self.outline_lock.lockShared();
        defer self.outline_lock.unlockShared();
        var total: u64 = 0;
        var it = self.outlines.iterator();
        while (it.next()) |entry| {
            if (self.deleted_files.get(entry.key_ptr.*) != null) continue;
            total += entry.value_ptr.*.byte_size;
        }
        return total;
    }

    /// Total lines across all indexed files.
    pub fn total_line_count(self: *Explorer) u64 {
        self.outline_lock.lockShared();
        defer self.outline_lock.unlockShared();
        var total: u64 = 0;
        var it = self.outlines.iterator();
        while (it.next()) |entry| {
            if (self.deleted_files.get(entry.key_ptr.*) != null) continue;
            total += entry.value_ptr.*.line_count;
        }
        return total;
    }
};

// ── Helpers ──────────────────────────────────────────────────────────────────

/// Find the innermost symbol scope containing a given line.
fn find_scope(symbols: []const models.Symbol, line: u32) ?models.Symbol {
    var best: ?models.Symbol = null;
    var best_size: usize = std.math.maxInt(usize);
    for (symbols) |sym| {
        if (line >= sym.line_start and line <= sym.line_end) {
            const size = sym.line_end - sym.line_start;
            if (size < best_size) {
                best = sym;
                best_size = size;
            }
        }
    }
    return best;
}

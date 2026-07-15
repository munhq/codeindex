const std = @import("std");
const models = @import("../core/models.zig");
const version_mod = @import("version.zig");
const imports_resolver = @import("../resolver/imports.zig");
const io = @import("../core/io.zig");

/// Cap on a query-time fallback read when a candidate file is not in the
/// content cache. Matches the read caps used elsewhere in the codebase.
const max_fallback_read_bytes: usize = 10 * 1024 * 1024;

/// Insert `file_id` into a sorted, deduplicated posting list.
fn insert_sorted(allocator: std.mem.Allocator, list: *std.ArrayList(u32), file_id: u32) !void {
    var lo: usize = 0;
    var hi: usize = list.items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (list.items[mid] < file_id) lo = mid + 1 else hi = mid;
    }
    if (lo < list.items.len and list.items[lo] == file_id) return;
    try list.insert(allocator, lo, file_id);
}

/// Maps every '/'-boundary path suffix (and each full path) to the file ids
/// carrying it, so the import-resolution fallback can match a specifier to
/// indexed files in O(1) instead of substring-scanning every path. Built once
/// per full `resolve_all_imports` pass and torn down at its end.
///
/// Keys are slices into the caller's stable path storage (Explorer.files),
/// which lives for the whole pass under the file lock — so keys are not copied.
const SuffixIndex = struct {
    map: std.StringHashMap(std.ArrayList(u32)),
    allocator: std.mem.Allocator,

    fn build(allocator: std.mem.Allocator, file_map: *const std.StringHashMap(u32)) !SuffixIndex {
        var map = std.StringHashMap(std.ArrayList(u32)).init(allocator);
        errdefer {
            var vit = map.valueIterator();
            while (vit.next()) |list| list.deinit(allocator);
            map.deinit();
        }
        var it = file_map.iterator();
        while (it.next()) |entry| {
            const path = entry.key_ptr.*;
            const id = entry.value_ptr.*;
            // Register the full path, then each suffix beginning just past a '/'.
            var start: usize = 0;
            while (start < path.len) {
                const suffix = path[start..];
                const gop = try map.getOrPut(suffix);
                if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(u32).empty;
                try gop.value_ptr.append(allocator, id);
                const next_slash = std.mem.indexOfScalar(u8, suffix, '/') orelse break;
                start += next_slash + 1;
            }
        }
        return .{ .map = map, .allocator = allocator };
    }

    fn deinit(self: *SuffixIndex) void {
        var it = self.map.valueIterator();
        while (it.next()) |list| list.deinit(self.allocator);
        self.map.deinit();
    }

    /// File ids whose path equals `key` or ends with `/key` (i.e. `key` is a
    /// path-segment-aligned suffix). Null if none.
    fn lookup(self: *const SuffixIndex, key: []const u8) ?[]const u32 {
        if (self.map.get(key)) |list| return list.items;
        return null;
    }
};

/// Trigram → set of file ids. Postings hold one u32 per file that contains the
/// trigram, NOT one entry per occurrence — line numbers are recovered at query
/// time by scanning the candidate file's content, which the query paths already
/// do to verify matches. Postings are add-only; a modified file's obsolete
/// trigrams remain as false candidates (harmless: content verification is
/// authoritative) until Explorer.compact() rebuilds the maps.
pub const TrigramIndex = struct {
    /// Persistent store for postings + map buckets. When the Explorer owns this
    /// index, `store` is a page-backed arena so the whole index can be returned
    /// to the OS in one munmap on idle eviction / compaction (see Explorer).
    store: std.mem.Allocator,
    /// Transient allocator for the per-file `seen` set and query result slices —
    /// NEVER the arena, or reads/adds would grow it unbounded (arena free is a
    /// no-op) and query results would be freed by the caller with a different
    /// allocator. Query callers free the returned slice with this same allocator.
    scratch: std.mem.Allocator,
    map: std.AutoHashMap(u24, std.ArrayList(u32)),

    pub fn init(store: std.mem.Allocator, scratch: std.mem.Allocator) TrigramIndex {
        return .{
            .store = store,
            .scratch = scratch,
            .map = std.AutoHashMap(u24, std.ArrayList(u32)).init(store),
        };
    }

    pub fn deinit(self: *TrigramIndex) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.store);
        }
        self.map.deinit();
    }

    pub fn add_text(self: *TrigramIndex, file_id: u32, content: []const u8) !void {
        // Collect the file's unique trigrams first so each posting list is
        // touched once per file, not once per occurrence.
        var seen = std.AutoHashMap(u24, void).init(self.scratch);
        defer seen.deinit();

        var line_it = std.mem.splitScalar(u8, content, '\n');
        while (line_it.next()) |line| {
            if (line.len < 3) continue;
            for (0..line.len - 2) |i| {
                const trigram = @as(u24, line[i]) | (@as(u24, line[i + 1]) << 8) | (@as(u24, line[i + 2]) << 16);
                try seen.put(trigram, {});
            }
        }

        var it = seen.keyIterator();
        while (it.next()) |trigram| {
            const gop = try self.map.getOrPut(trigram.*);
            if (!gop.found_existing) {
                gop.value_ptr.* = std.ArrayList(u32).empty;
            }
            try insert_sorted(self.store, gop.value_ptr, file_id);
        }
    }

    /// Candidate file ids for `text`: the sorted intersection of the posting
    /// lists of every trigram in the query. Caller frees the returned slice.
    /// Candidates may be stale (file changed since indexing) — callers must
    /// verify against real content.
    pub fn query(self: *TrigramIndex, text: []const u8) ![]u32 {
        if (text.len < 3) return &[_]u32{};

        var results: ?std.ArrayList(u32) = null;
        defer if (results) |*r| r.deinit(self.scratch);

        for (0..text.len - 2) |i| {
            const trigram = @as(u24, text[i]) | (@as(u24, text[i + 1]) << 8) | (@as(u24, text[i + 2]) << 16);
            const posting = self.map.get(trigram) orelse return &[_]u32{};

            if (results == null) {
                results = try std.ArrayList(u32).initCapacity(self.scratch, posting.items.len);
                try results.?.appendSlice(self.scratch, posting.items);
            } else {
                var new_results = std.ArrayList(u32).empty;
                var r_idx: usize = 0;
                var l_idx: usize = 0;
                const r_items = results.?.items;
                const l_items = posting.items;

                while (r_idx < r_items.len and l_idx < l_items.len) {
                    if (r_items[r_idx] == l_items[l_idx]) {
                        try new_results.append(self.scratch, r_items[r_idx]);
                        r_idx += 1;
                        l_idx += 1;
                    } else if (r_items[r_idx] < l_items[l_idx]) {
                        r_idx += 1;
                    } else {
                        l_idx += 1;
                    }
                }
                results.?.deinit(self.scratch);
                results = new_results;
            }
            if (results.?.items.len == 0) break;
        }

        return if (results) |*r| try r.toOwnedSlice(self.scratch) else &[_]u32{};
    }
};

/// Delimiters that split a line into words. Shared by WordIndex.add_text and
/// the query-time line scans in find_word/find_callers so both sides agree on
/// what a "word" is.
pub const word_delimiters = " \t\n\r(){}[];:.,\"'<>?!=+-*/&|^%~#@`";

/// Word → set of file ids. Same design as TrigramIndex: one u32 per file, line
/// numbers recovered at query time by scanning content, add-only postings
/// compacted by Explorer.compact().
pub const WordIndex = struct {
    /// Persistent store for postings, map buckets, and duped word keys — a
    /// page-backed arena when owned by the Explorer (see TrigramIndex.store).
    store: std.mem.Allocator,
    /// Transient allocator for the per-file `seen` set (never the arena).
    scratch: std.mem.Allocator,
    map: std.StringHashMap(std.ArrayList(u32)),

    pub fn init(store: std.mem.Allocator, scratch: std.mem.Allocator) WordIndex {
        return .{
            .store = store,
            .scratch = scratch,
            .map = std.StringHashMap(std.ArrayList(u32)).init(store),
        };
    }

    pub fn deinit(self: *WordIndex) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.store.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.store);
        }
        self.map.deinit();
    }

    pub fn add_text(self: *WordIndex, file_id: u32, content: []const u8) !void {
        // Unique words first (keys borrow from `content`, valid for this call).
        var seen = std.StringHashMap(void).init(self.scratch);
        defer seen.deinit();

        var line_it = std.mem.splitScalar(u8, content, '\n');
        while (line_it.next()) |line| {
            var word_it = std.mem.tokenizeAny(u8, line, word_delimiters);
            while (word_it.next()) |word| {
                if (word.len < 2) continue;
                try seen.put(word, {});
            }
        }

        var it = seen.keyIterator();
        while (it.next()) |word| {
            const gop = try self.map.getOrPut(word.*);
            if (!gop.found_existing) {
                gop.key_ptr.* = try self.store.dupe(u8, word.*);
                gop.value_ptr.* = std.ArrayList(u32).empty;
            }
            try insert_sorted(self.store, gop.value_ptr, file_id);
        }
    }

    /// File ids that contained `word` when last indexed. May include stale
    /// entries — callers verify against real content.
    pub fn search(self: *const WordIndex, word: []const u8) []const u32 {
        if (self.map.get(word)) |list| {
            return list.items;
        }
        return &[_]u32{};
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
        if (!i_gop.found_existing) i_gop.value_ptr.* = std.ArrayList(u32).empty;

        for (i_gop.value_ptr.items) |id| {
            if (id == to) return;
        }
        try i_gop.value_ptr.append(self.allocator, to);

        const r_gop = try self.reverse_deps.getOrPut(to);
        if (!r_gop.found_existing) r_gop.value_ptr.* = std.ArrayList(u32).empty;
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

    /// Drop every edge in the graph. Used before a full re-resolution pass.
    pub fn clear_all(self: *DepGraph) void {
        var it = self.imports.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit(self.allocator);
        self.imports.clearRetainingCapacity();

        var it2 = self.reverse_deps.iterator();
        while (it2.next()) |entry| entry.value_ptr.deinit(self.allocator);
        self.reverse_deps.clearRetainingCapacity();
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
    status_message: ?[]u8 = null, // surfaced via the `status` tool (refused / capped scans)
    /// Modifies + deletes since the last compaction. Postings are add-only, so
    /// each such op leaves stale entries behind; compact() sweeps them once
    /// this crosses the threshold in needs_compaction().
    dirty_ops: usize = 0,
    /// Files larger than this get outlines/content but no trigram/word
    /// postings — a stray data dump must not dominate the index.
    max_posting_file_bytes: usize = 512 * 1024,

    // Per-index RwLocks for concurrent read access during writes
    trigram_lock: io.RwLock = .{},
    word_lock: io.RwLock = .{},
    outline_lock: io.RwLock = .{},
    dep_lock: io.RwLock = .{},
    content_lock: io.RwLock = .{},
    file_lock: io.RwLock = .{},

    /// Page-backed arena holding all trigram + word postings. Freed wholesale on
    /// compact()/evict() so the memory returns to the OS in one munmap — the
    /// process allocator (smp) never unmaps the sub-64KB posting slabs on a plain
    /// free, which is what made idle servers hold their peak RSS forever. Heap
    /// pointer (not inline) so its address is stable: ArenaAllocator.allocator()
    /// captures &arena, so a struct move would dangle every posting's allocator.
    index_arena: *std.heap.ArenaAllocator,
    /// Serializes the three posting rebuilders — compact() (watcher thread),
    /// evict() (idle-monitor thread), reprime_all() (MCP thread) — against each
    /// other. Queries never take it; they use the shared trigram/word RwLocks and
    /// are blocked only during each rebuilder's brief exclusive pointer swap.
    rebuild_mutex: io.Mutex = .{},
    /// When true, the postings are empty (arena reclaimed) and must be rebuilt
    /// before the next content/word/trigram query. Flipped only under the
    /// exclusive trigram+word locks so watcher writes observe it consistently.
    evicted: std.atomic.Value(bool) = .init(false),
    /// Wall-clock ms of the last MCP tool call; the idle-monitor evicts once the
    /// gap exceeds the configured idle window. Written by the MCP thread, read by
    /// the idle-monitor thread.
    last_activity_ms: std.atomic.Value(i64) = .init(0),

    pub fn init(allocator: std.mem.Allocator) !Explorer {
        // The posting arena is heap-allocated for a stable address (see the
        // index_arena field doc) and child-allocated from the page allocator so
        // every arena chunk is a direct mmap that deinit() returns to the OS.
        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        return .{
            .allocator = allocator,
            .index_arena = arena,
            .trigrams = TrigramIndex.init(arena.allocator(), allocator),
            .words = WordIndex.init(arena.allocator(), allocator),
            .depgraph = DepGraph.init(allocator),
            .files = std.ArrayList([]const u8).empty,
            .file_map = std.StringHashMap(u32).init(allocator),
            .outlines = std.AutoHashMap(u32, models.FileOutline).init(allocator),
            .deleted_files = std.AutoHashMap(u32, void).init(allocator),
            .version = version_mod.VersionStore.init(allocator),
            .indexing = true,
            .content_cache = std.AutoHashMap(u32, []const u8).init(allocator),
            .cache_bytes = 0,
            .max_cache_bytes = 50 * 1024 * 1024,
            .cache_order = std.ArrayList(u32).empty,
            .last_activity_ms = .init(io.milliTimestamp()),
        };
    }

    pub fn deinit(self: *Explorer) void {
        // Postings live in index_arena — free them wholesale (one munmap per
        // chunk), so we do NOT iterate trigrams/words to free them individually.
        self.index_arena.deinit();
        self.allocator.destroy(self.index_arena);
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
        if (self.status_message) |m| self.allocator.free(m);
    }

    /// Replace the status message (owns a copy of `msg`).
    pub fn set_status(self: *Explorer, msg: []const u8) void {
        if (self.status_message) |old| self.allocator.free(old);
        self.status_message = self.allocator.dupe(u8, msg) catch null;
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
        // Resolve the dependency graph in one pass now that every file is known.
        // Per-file resolution in add_file can only see files indexed *before* it,
        // so forward edges to later-indexed files would be lost without this.
        self.resolve_all_imports() catch |err| {
            std.debug.print("codeindex: dependency resolution failed: {}\n", .{err});
        };
        self.indexing = false;
    }

    /// Rebuild the entire dependency graph from scratch against the complete
    /// file set. Safe to call repeatedly; clears existing edges first.
    pub fn resolve_all_imports(self: *Explorer) !void {
        self.file_lock.lockShared();
        defer self.file_lock.unlockShared();
        self.outline_lock.lockShared();
        defer self.outline_lock.unlockShared();
        self.dep_lock.lock();
        defer self.dep_lock.unlock();

        self.depgraph.clear_all();

        // Build the suffix index once for the whole pass; the fallback below
        // then resolves each unmatched specifier in O(1) instead of scanning
        // every path (which was O(files²) on large trees).
        var suffix_index = try SuffixIndex.build(self.allocator, &self.file_map);
        defer suffix_index.deinit();

        var it = self.outlines.iterator();
        while (it.next()) |entry| {
            const file_id = entry.key_ptr.*;
            if (self.deleted_files.get(file_id) != null) continue;
            try self.resolve_imports(file_id, entry.value_ptr.imports, &suffix_index);
        }
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

            // Postings are add-only sets: new trigrams/words gain this file id,
            // obsolete ones stay behind as false candidates until compact().
            // While evicted the postings arena is empty; skip posting updates
            // (reprime_all rebuilds them from the still-warm content cache on the
            // next query) but keep the outline/content/version updates current.
            if (!self.evicted.load(.acquire) and content.len <= self.max_posting_file_bytes) {
                try self.trigrams.add_text(existing_id, content);
                try self.words.add_text(existing_id, content);
            }
            self.dirty_ops += 1;

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
            try self.resolve_imports(existing_id, outline.imports, null);

            try self.version.record(outline.path, op);
            return existing_id;
        }

        const file_id = @as(u32, @intCast(self.files.items.len));
        const path_dup = try self.allocator.dupe(u8, outline.path);
        try self.files.append(self.allocator, path_dup);
        try self.file_map.put(path_dup, file_id);

        // Skip posting updates while evicted (see the modified-branch note above).
        if (!self.evicted.load(.acquire) and content.len <= self.max_posting_file_bytes) {
            try self.trigrams.add_text(file_id, content);
            try self.words.add_text(file_id, content);
        }
        try self.outlines.put(file_id, outline);
        const cached_new = try self.allocator.dupe(u8, content);
        try self.content_cache.put(file_id, cached_new);
        self.cache_bytes += cached_new.len;
        self.cache_touch(file_id);
        self.evict_cache();

        try self.resolve_imports(file_id, outline.imports, null);

        try self.version.record(outline.path, op);
        return file_id;
    }

    /// Rebuild the search indexes (trigram + word) and prime the bounded content
    /// cache for an already-registered file. Used when restoring from a snapshot,
    /// which persists outlines/deps but not the in-RAM search indexes.
    pub fn prime_file(self: *Explorer, file_id: u32, content: []const u8) !void {
        // Defensive: prime_file runs during snapshot restore (evicted == false),
        // but honor the flag anyway so a stray call while evicted can't build a
        // partial index on top of the empty arena.
        if (!self.evicted.load(.acquire) and content.len <= self.max_posting_file_bytes) {
            try self.trigrams.add_text(file_id, content);
            try self.words.add_text(file_id, content);
        }
        const cached = try self.allocator.dupe(u8, content);
        try self.content_cache.put(file_id, cached);
        self.cache_bytes += cached.len;
        self.cache_touch(file_id);
        self.evict_cache();
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
            // Trigram/word postings stay behind (query paths filter on
            // deleted_files; compact() sweeps them). Only the dep graph needs
            // eager cleanup — its consumers don't re-verify.
            self.depgraph.clear_file(file_id);
            self.dirty_ops += 1;

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

    /// Whether enough modifies/deletes accumulated that stale postings are
    /// worth sweeping. Threshold: a quarter of the file count, floor 64 — so a
    /// busy watcher compacts amortized-O(1) per event, an idle one never does.
    /// Racy read is fine: the watcher thread is the only mutator and caller.
    pub fn needs_compaction(self: *Explorer) bool {
        return self.dirty_ops > @max(64, self.files.items.len / 4);
    }

    /// Rebuild the trigram/word indexes from live content, dropping stale
    /// postings and returning slack capacity to the allocator. Build runs under
    /// shared locks (queries keep working); only the pointer swap is exclusive.
    /// Must be called from the mutator (watcher) thread.
    pub fn compact(self: *Explorer) !void {
        self.rebuild_mutex.lock();
        defer self.rebuild_mutex.unlock();
        // Nothing to sweep while evicted: the arena is empty and reprime_all()
        // rebuilds a clean index on the next query. rebuild_mutex makes the three
        // rebuilders mutually exclusive, so `evicted` can't flip under us here.
        if (self.evicted.load(.acquire)) return;

        try self.rebuild_postings(false);
        std.debug.print("codeindex: compacted postings ({d} trigrams, {d} words)\n", .{
            self.trigrams.map.count(), self.words.map.count(),
        });
    }

    /// Build a fresh trigram+word index into a brand-new page-backed arena, then
    /// swap it in under the exclusive posting locks and munmap the old arena in
    /// one shot. The live index keeps serving queries throughout the build; only
    /// the pointer swap is exclusive. Caller MUST hold rebuild_mutex.
    ///
    /// `from_empty` skips the content-cache lookup and always reads from disk —
    /// used by reprime_all after eviction dropped the postings (the cache is
    /// still warm, but reading uniformly keeps the path simple). When false
    /// (compact) it prefers the cache and falls back to disk, as before.
    fn rebuild_postings(self: *Explorer, from_empty: bool) !void {
        const new_arena = try self.allocator.create(std.heap.ArenaAllocator);
        errdefer self.allocator.destroy(new_arena);
        new_arena.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        errdefer new_arena.deinit();
        const st = new_arena.allocator();
        var new_trigrams = TrigramIndex.init(st, self.allocator);
        var new_words = WordIndex.init(st, self.allocator);

        {
            self.file_lock.lockShared();
            defer self.file_lock.unlockShared();
            self.outline_lock.lockShared();
            defer self.outline_lock.unlockShared();
            self.content_lock.lockShared();
            defer self.content_lock.unlockShared();

            var it = self.outlines.iterator();
            while (it.next()) |entry| {
                const file_id = entry.key_ptr.*;
                if (self.deleted_files.get(file_id) != null) continue;
                const cached = if (from_empty) null else self.content_cache.get(file_id);
                const content = cached orelse
                    (io.readFileAlloc(self.allocator, entry.value_ptr.path, max_fallback_read_bytes) catch continue);
                defer if (cached == null) self.allocator.free(content);
                if (content.len > self.max_posting_file_bytes) continue;
                try new_trigrams.add_text(file_id, content);
                try new_words.add_text(file_id, content);
            }
        }

        self.trigram_lock.lock();
        self.word_lock.lock();
        const old_arena = self.index_arena;
        self.index_arena = new_arena;
        self.trigrams = new_trigrams;
        self.words = new_words;
        self.dirty_ops = 0;
        // Clear evicted in the SAME critical section as the swap so add_file's
        // evicted check (also under trigram_lock) can never see the new live
        // index while the flag still says "empty" — a file created by the watcher
        // during a reprime would otherwise miss its postings. No-op for compact
        // (already false). This is why rebuild_postings, not reprime_all, owns it.
        self.evicted.store(false, .release);
        self.word_lock.unlock();
        self.trigram_lock.unlock();

        // Old postings freed here, after the swap, so no query ever touches a
        // dangling arena. One munmap per chunk → RSS actually drops.
        old_arena.deinit();
        self.allocator.destroy(old_arena);
    }

    /// Idle-monitor entry point: drop all postings and return their arena to the
    /// OS. Structural state (outlines/file_map/deps/version) and the warm content
    /// cache are kept, so reprime_all() rebuilds quickly from RAM. Safe to call
    /// from any thread; a no-op if already evicted or still indexing.
    pub fn evict(self: *Explorer) void {
        self.rebuild_mutex.lock();
        defer self.rebuild_mutex.unlock();
        if (self.evicted.load(.acquire)) return;
        if (self.indexing) return; // never evict mid-build

        const new_arena = self.allocator.create(std.heap.ArenaAllocator) catch return;
        new_arena.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        const st = new_arena.allocator();
        const new_trigrams = TrigramIndex.init(st, self.allocator);
        const new_words = WordIndex.init(st, self.allocator);

        self.trigram_lock.lock();
        self.word_lock.lock();
        const old_arena = self.index_arena;
        self.index_arena = new_arena;
        self.trigrams = new_trigrams;
        self.words = new_words;
        self.dirty_ops = 0;
        self.evicted.store(true, .release);
        self.word_lock.unlock();
        self.trigram_lock.unlock();

        old_arena.deinit();
        self.allocator.destroy(old_arena);
        std.debug.print("codeindex: idle — evicted postings, arena returned to OS\n", .{});
    }

    /// Rebuild the postings dropped by evict(). No-op if not evicted. Called from
    /// the MCP thread before serving a query once activity resumes.
    pub fn reprime_all(self: *Explorer) !void {
        self.rebuild_mutex.lock();
        defer self.rebuild_mutex.unlock();
        if (!self.evicted.load(.acquire)) return; // already primed by a prior call

        std.debug.print("codeindex: repriming postings after idle eviction\n", .{});
        // rebuild_postings clears `evicted` atomically with the swap.
        try self.rebuild_postings(true);
    }

    /// Record MCP activity; resets the idle-eviction timer. Called per tool call.
    pub fn note_activity(self: *Explorer) void {
        self.last_activity_ms.store(io.milliTimestamp(), .release);
    }

    /// Whether the postings are currently evicted (empty, pending reprime).
    pub fn is_evicted(self: *Explorer) bool {
        return self.evicted.load(.acquire);
    }

    /// Resolve `file_id`'s imports into dependency edges. `suffix_index` enables
    /// the language-agnostic fallback used during a full pass; pass null on the
    /// incremental single-file path, where building the index per change would
    /// reintroduce O(files) work under churn. The primary per-language resolver
    /// runs either way, so real imports still resolve incrementally — only the
    /// fuzzy suffix heuristic is deferred to the next full pass.
    fn resolve_imports(self: *Explorer, file_id: u32, imports: [][]const u8, suffix_index: ?*const SuffixIndex) !void {
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

            // Fallback: resolver found nothing. If the specifier is long enough
            // to be specific, match indexed files whose path ends with it on a
            // '/' boundary (e.g. "foo/bar/baz.ts"). This is an O(1) suffix-index
            // lookup — and more precise than the old substring-anywhere scan,
            // which produced spurious infix edges. Skip short bare identifiers.
            if (resolved.len == 0 and imp.len >= 6) {
                if (suffix_index) |idx| {
                    if (idx.lookup(imp)) |target_ids| {
                        for (target_ids) |target_id| {
                            if (target_id == file_id) continue; // never self-loop
                            try self.depgraph.add_dependency(file_id, target_id);
                        }
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

    /// Map a user-supplied path to a file id. Files are stored with their full
    /// absolute path, but callers normally pass a workspace-relative path, so we
    /// fall back to a '/'-boundary suffix match (e.g. "src/foo.rs" matches the
    /// stored "/ws/src/foo.rs"). Assumes the caller holds file_lock.
    fn find_file_id(self: *Explorer, path: []const u8) ?u32 {
        if (path.len == 0) return null;
        // Exact match — caller passed the stored full path.
        if (self.file_map.get(path)) |id| {
            if (self.deleted_files.get(id) == null) return id;
        }
        // Suffix match on a path-segment boundary.
        var it = self.file_map.iterator();
        while (it.next()) |entry| {
            const stored = entry.key_ptr.*;
            const id = entry.value_ptr.*;
            if (self.deleted_files.get(id) != null) continue;
            if (stored.len > path.len and
                stored[stored.len - path.len - 1] == '/' and
                std.mem.endsWith(u8, stored, path))
            {
                return id;
            }
        }
        return null;
    }

    pub fn get_outline(self: *Explorer, path: []const u8) ?models.FileOutline {
        self.outline_lock.lockShared();
        defer self.outline_lock.unlockShared();
        self.file_lock.lockShared();
        defer self.file_lock.unlockShared();
        const file_id = self.find_file_id(path) orelse return null;
        return self.outlines.get(file_id);
    }

    /// Find symbol definitions by name (substring match).
    pub fn find_symbol(self: *Explorer, name: []const u8, limit: usize) ![]SymbolResult {
        self.outline_lock.lockShared();
        defer self.outline_lock.unlockShared();
        var results = std.ArrayList(SymbolResult).empty;
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

    /// Search file contents using trigram-accelerated search. Results own
    /// line_text (caller frees) — content may come from a transient disk read
    /// when the file isn't in the bounded cache, so slices can't be borrowed.
    pub fn search_content(self: *Explorer, query_text: []const u8, limit: usize) ![]ScopedSearchResult {
        self.trigram_lock.lockShared();
        defer self.trigram_lock.unlockShared();
        self.content_lock.lockShared();
        defer self.content_lock.unlockShared();
        self.outline_lock.lockShared();
        defer self.outline_lock.unlockShared();
        var results = std.ArrayList(ScopedSearchResult).empty;
        errdefer {
            for (results.items) |r| self.allocator.free(r.line_text);
            results.deinit(self.allocator);
        }

        // Candidate files from the trigram index (sorted, deduped, possibly
        // stale — the content scan below is the source of truth).
        const candidates = try self.trigrams.query(query_text);
        defer if (candidates.len > 0) self.allocator.free(candidates);

        outer: for (candidates) |file_id| {
            if (self.deleted_files.get(file_id) != null) continue;
            const outline = self.outlines.get(file_id) orelse continue;

            const cached = self.content_cache.get(file_id);
            const content = cached orelse
                (io.readFileAlloc(self.allocator, outline.path, max_fallback_read_bytes) catch continue);
            defer if (cached == null) self.allocator.free(content);

            var line_num: u32 = 1;
            var line_it = std.mem.splitScalar(u8, content, '\n');
            while (line_it.next()) |line| {
                if (std.mem.indexOf(u8, line, query_text) != null) {
                    // Find enclosing scope
                    const scope = find_scope(outline.symbols, line_num);
                    try results.append(self.allocator, .{
                        .path = outline.path,
                        .line_num = line_num,
                        .line_text = try self.allocator.dupe(u8, line),
                        .scope_name = if (scope) |s| s.name else null,
                        .scope_kind = if (scope) |s| s.kind else null,
                    });
                    if (results.items.len >= limit) break :outer;
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

        var results = std.ArrayList(CallerHit).empty;
        errdefer {
            for (results.items) |h| self.allocator.free(h.line_text);
            results.deinit(self.allocator);
        }

        const hit_files = self.words.search(name);
        outer: for (hit_files) |file_id| {
            if (self.deleted_files.get(file_id) != null) continue;
            if (file_id >= self.files.items.len) continue;

            const cached = self.content_cache.get(file_id);
            const content = cached orelse
                (io.readFileAlloc(self.allocator, self.files.items[file_id], max_fallback_read_bytes) catch continue);
            defer if (cached == null) self.allocator.free(content);

            var line_num_0: u32 = 0;
            var line_scan = std.mem.splitScalar(u8, content, '\n');
            scan: while (line_scan.next()) |line_text| : (line_num_0 += 1) {
                if (line_text.len == 0) continue;
                if (std.mem.indexOf(u8, line_text, name) == null) continue;

                // Skip lines that fall inside the symbol's own definition.
                const line_key: u64 = (@as(u64, file_id) << 32) | @as(u64, line_num_0);
                if (def_lines.get(line_key) != null) continue :scan;

                // Detect re-export / use-statement context for the whole line.
                const trimmed_for_ctx = std.mem.trimStart(u8, line_text, " \t");
                const is_use_line = std.mem.startsWith(u8, trimmed_for_ctx, "use ") or
                    std.mem.startsWith(u8, trimmed_for_ctx, "pub use ") or
                    std.mem.startsWith(u8, trimmed_for_ctx, "pub(crate) use ") or
                    std.mem.startsWith(u8, trimmed_for_ctx, "export ") or
                    std.mem.startsWith(u8, trimmed_for_ctx, "import ") or
                    std.mem.startsWith(u8, trimmed_for_ctx, "from ") or
                    std.mem.indexOf(u8, trimmed_for_ctx, "from \"") != null or
                    std.mem.indexOf(u8, trimmed_for_ctx, "from '") != null;
                const is_reexport_line = std.mem.startsWith(u8, trimmed_for_ctx, "pub use ") or
                    std.mem.startsWith(u8, trimmed_for_ctx, "pub(crate) use ") or
                    std.mem.startsWith(u8, trimmed_for_ctx, "export ");

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

                    // Classify: reexport (takes precedence on use/import lines) / call / method / path
                    var ctx: []const u8 = "other";
                    if (is_reexport_line) ctx = "reexport" else if (is_use_line) ctx = "import";
                    // Call: `name(`
                    if (end < line_text.len and line_text[end] == '(') ctx = "call";
                    // Method: `.name(` or `->name(`
                    if (pos > 0 and line_text[pos - 1] == '.' and end < line_text.len and line_text[end] == '(') ctx = "method";
                    if (pos >= 2 and line_text[pos - 2] == '-' and line_text[pos - 1] == '>' and end < line_text.len and line_text[end] == '(') ctx = "method";
                    // Path reference: `::name` or `name::` — only if NOT on a use/import line
                    if (!is_use_line) {
                        if (pos >= 2 and line_text[pos - 2] == ':' and line_text[pos - 1] == ':') ctx = "path";
                        if (end + 1 < line_text.len and line_text[end] == ':' and line_text[end + 1] == ':') ctx = "path";
                    }

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
                    if (results.items.len >= limit) break :outer;
                }
            }
        }
        return try results.toOwnedSlice(self.allocator);
    }

    /// Look up an exact word: files from the inverted index, line numbers
    /// recovered by scanning content (cache or transient disk read). The scan
    /// tokenizes with the same delimiters as indexing, so semantics match the
    /// old per-occurrence index: one hit per line containing the exact word.
    pub fn find_word(self: *Explorer, word: []const u8, limit: usize) ![]WordHit {
        self.word_lock.lockShared();
        defer self.word_lock.unlockShared();
        self.file_lock.lockShared();
        defer self.file_lock.unlockShared();
        self.content_lock.lockShared();
        defer self.content_lock.unlockShared();
        var results = std.ArrayList(WordHit).empty;
        const hit_files = self.words.search(word);
        outer: for (hit_files) |file_id| {
            if (self.deleted_files.get(file_id) != null) continue;
            if (file_id >= self.files.items.len) continue;

            const cached = self.content_cache.get(file_id);
            const content = cached orelse
                (io.readFileAlloc(self.allocator, self.files.items[file_id], max_fallback_read_bytes) catch continue);
            defer if (cached == null) self.allocator.free(content);

            var line_num: u32 = 0;
            var line_it = std.mem.splitScalar(u8, content, '\n');
            while (line_it.next()) |line| : (line_num += 1) {
                if (std.mem.indexOf(u8, line, word) == null) continue;
                var word_it = std.mem.tokenizeAny(u8, line, word_delimiters);
                while (word_it.next()) |token| {
                    if (std.mem.eql(u8, token, word)) {
                        try results.append(self.allocator, .{
                            .path = self.files.items[file_id],
                            .line_num = line_num,
                        });
                        if (results.items.len >= limit) break :outer;
                        break;
                    }
                }
            }
        }
        return try results.toOwnedSlice(self.allocator);
    }

    /// Get forward dependencies: which files does this file import?
    pub fn get_imports(self: *Explorer, path: []const u8) []const u32 {
        self.dep_lock.lockShared();
        defer self.dep_lock.unlockShared();
        self.file_lock.lockShared();
        defer self.file_lock.unlockShared();
        const file_id = self.find_file_id(path) orelse return &[_]u32{};
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
        const file_id = self.find_file_id(path) orelse return &[_]u32{};
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

        const file_id = self.find_file_id(path) orelse return ChangeImpact{
            .direct = &[_]u32{},
            .transitive = &[_]u32{},
            .depth_reached = 0,
        };

        // BFS traversal of reverse dependencies
        var visited = std.AutoHashMap(u32, u32).init(self.allocator);
        defer visited.deinit();

        var queue = std.ArrayList(struct { id: u32, depth: u32 }).empty;
        defer queue.deinit(self.allocator);

        var direct = std.ArrayList(u32).empty;
        var all = std.ArrayList(u32).empty;
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
        var root_children = std.ArrayList(models.TreeNode).empty;

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

//! A logic shape that costs production money.
//!
//! `sized_constant` — a fixed byte constant that should have come from a limit.
//! The fault: a SQLite `mmap_size` pinned at a flat 256 MiB with no relation to
//! the container memory limit. One pod mapped 381 MB of a 334 MB database inside
//! a 512 MiB limit, and the kernel reclaimed without pause. The constant alone
//! is not a finding — plenty of buffers are correctly fixed. The finding is a
//! fixed constant in a repository that declares a memory limit the constant
//! never reads, and the number that makes it actionable is the ratio.
//!
//! The N+1 shape that lived here as `call_in_loop` is `call_cost.zig`: it
//! counts round trips through the call graph.

const std = @import("std");
const explorer = @import("../index/explorer.zig");
const models = @import("../core/models.zig");
const txt = @import("text.zig");

pub const Kind = enum {
    sized_constant,

    pub fn as_str(self: Kind) []const u8 {
        return @tagName(self);
    }

    /// `sized_constant` is decidable: the constant either fits inside the
    /// declared limit or it does not, and both numbers are in the repository.
    pub fn confidence(self: Kind) []const u8 {
        _ = self;
        return "finding";
    }

    /// Empty when the kind is decidable from the source alone.
    pub fn runtime_check(self: Kind) []const u8 {
        _ = self;
        return "";
    }
};

pub const Finding = struct {
    file: []const u8,
    line: usize,
    kind: Kind,
    /// The knob or the call. Owned.
    subject: []const u8,
    /// What makes it a finding. Owned.
    detail: []const u8,
    /// The line itself. Owned.
    evidence: []const u8,
    /// `sized_constant`: the constant, in bytes.
    constant_bytes: ?u64 = null,
    /// `sized_constant`: percent of the smallest declared limit. A constant at
    /// or above 100% cannot fit, and one near it leaves nothing for the heap.
    percent_of_limit: ?u32 = null,
};

/// A memory limit the repository declares.
pub const Limit = struct {
    file: []const u8,
    line: usize,
    bytes: u64,
    /// The text as written: `512Mi`. Owned.
    text: []const u8,
};

pub const Report = struct {
    /// Memory limits found in the repository. A `sized_constant` finding needs
    /// at least one, because without a limit there is nothing to derive from.
    limits: []Limit = &.{},
    findings: []Finding = &.{},

    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        for (self.limits) |l| allocator.free(l.text);
        allocator.free(self.limits);
        for (self.findings) |f| {
            allocator.free(f.subject);
            allocator.free(f.detail);
            allocator.free(f.evidence);
        }
        allocator.free(self.findings);
    }
};

const is_excluded_path = txt.is_excluded_path;
const ident_char = txt.ident_char;
const contains_any = txt.contains_any;
const contains_any_ci = txt.contains_any_ci;

// ── Declared memory limits ───────────────────────────────────────────────────

/// A Kubernetes quantity in bytes: `512Mi`, `1Gi`, `350M`.
pub fn parse_quantity(text_in: []const u8) ?u64 {
    const text = std.mem.trim(u8, text_in, " \t\"'");
    if (text.len == 0 or !std.ascii.isDigit(text[0])) return null;
    var end: usize = 0;
    while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
    const n = std.fmt.parseInt(u64, text[0..end], 10) catch return null;
    const unit = text[end..];
    if (unit.len == 0) return n;
    if (std.mem.eql(u8, unit, "Ki")) return n * 1024;
    if (std.mem.eql(u8, unit, "Mi")) return n * 1024 * 1024;
    if (std.mem.eql(u8, unit, "Gi")) return n * 1024 * 1024 * 1024;
    if (std.mem.eql(u8, unit, "Ti")) return n * 1024 * 1024 * 1024 * 1024;
    if (std.mem.eql(u8, unit, "K") or std.mem.eql(u8, unit, "k")) return n * 1000;
    if (std.mem.eql(u8, unit, "M") or std.mem.eql(u8, unit, "m")) return n * 1000 * 1000;
    if (std.mem.eql(u8, unit, "G") or std.mem.eql(u8, unit, "g")) return n * 1000 * 1000 * 1000;
    return null;
}

const limit_keys = [_][]const u8{
    "memory:", "mem_limit:", "memory_limit", "memoryLimit", "--memory=", "memory =",
};

/// The memory limits declared in one file.
fn collect_limits(
    allocator: std.mem.Allocator,
    outline: models.FileOutline,
    content: []const u8,
    out: *std.ArrayList(Limit),
) !void {
    var line_no: usize = 0;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |raw| {
        line_no += 1;
        const t = std.mem.trim(u8, raw, " \t\r");
        if (t.len == 0 or std.mem.startsWith(u8, t, "#") or std.mem.startsWith(u8, t, "//")) continue;
        if (!contains_any_ci(t, &limit_keys)) continue;
        // The quantity is the first `<digits><unit>` token on the line.
        if (find_quantity(t)) |q| {
            try out.append(allocator, .{
                .file = outline.path,
                .line = line_no,
                .bytes = q.bytes,
                .text = try allocator.dupe(u8, q.text),
            });
        }
    }
}

const Quantity = struct { bytes: u64, text: []const u8 };

/// The first `<digits><Ki|Mi|Gi|Ti>` token in a line. A bare integer is not a
/// quantity here: `memory: 3` is a replica count or an index, not a limit.
fn find_quantity(line: []const u8) ?Quantity {
    var i: usize = 0;
    while (i < line.len) {
        if (!std.ascii.isDigit(line[i])) {
            i += 1;
            continue;
        }
        if (i > 0 and ident_char(line[i - 1])) {
            while (i < line.len and ident_char(line[i])) i += 1;
            continue;
        }
        var end = i;
        while (end < line.len and std.ascii.isDigit(line[end])) end += 1;
        var unit_end = end;
        while (unit_end < line.len and std.ascii.isAlphabetic(line[unit_end])) unit_end += 1;
        const token = line[i..unit_end];
        if (unit_end > end) {
            if (parse_quantity(token)) |bytes| return .{ .bytes = bytes, .text = token };
        }
        i = unit_end;
    }
    return null;
}

// ── Shape: a fixed byte constant ─────────────────────────────────────────────

/// Knobs whose value sizes a region of memory.
const sizing_keys = [_][]const u8{
    "mmap_size",          "cache_size",  "shared_buffers", "work_mem",
    "buffer_size",        "pool_size",   "heap_size",      "max_memory",
    "maxmemory",          "arena_size",  "page_cache",     "-Xmx",
    "max_old_space_size", "buffer_pool", "block_cache",    "write_buffer",
    "memtable",           "chunk_size",  "prealloc",       "reserve_bytes",
};

/// A read of the actual limit, which is what a correct sizing does.
const derives_from_limit = [_][]const u8{
    "cgroup",           "memory.max",   "memory.limit_in_bytes", "MemTotal",     "sysinfo",
    "available_memory", "total_memory", "MEMORY_LIMIT",          "MemAvailable", "env::var",
    "getenv",           "os.environ",   "process.env",           "std::env",
};

const one_mib: u64 = 1024 * 1024;

/// The largest byte-magnitude integer on the line, as written or as a product
/// of the `N * 1024 * 1024` form.
fn sizing_constant(line: []const u8) ?u64 {
    var best: ?u64 = null;
    var i: usize = 0;
    while (i < line.len) {
        if (!std.ascii.isDigit(line[i])) {
            i += 1;
            continue;
        }
        if (i > 0 and ident_char(line[i - 1])) {
            while (i < line.len and ident_char(line[i])) i += 1;
            continue;
        }
        var end = i;
        var value: u64 = 0;
        var overflow = false;
        while (end < line.len and (std.ascii.isDigit(line[end]) or line[end] == '_')) : (end += 1) {
            if (line[end] == '_') continue;
            value = std.math.mul(u64, value, 10) catch {
                overflow = true;
                break;
            };
            value = std.math.add(u64, value, line[end] - '0') catch {
                overflow = true;
                break;
            };
        }
        if (overflow) {
            i = end;
            continue;
        }
        // `64 * 1024 * 1024` — fold the products that follow.
        var j = end;
        while (j < line.len) {
            const rest = std.mem.trimStart(u8, line[j..], " \t");
            if (rest.len == 0 or rest[0] != '*') break;
            var k = (line.len - rest.len) + 1;
            while (k < line.len and (line[k] == ' ' or line[k] == '\t')) k += 1;
            if (k >= line.len or !std.ascii.isDigit(line[k])) break;
            var m = k;
            var factor: u64 = 0;
            while (m < line.len and (std.ascii.isDigit(line[m]) or line[m] == '_')) : (m += 1) {
                if (line[m] == '_') continue;
                factor = factor * 10 + (line[m] - '0');
            }
            value = std.math.mul(u64, value, factor) catch break;
            j = m;
        }
        if (value >= one_mib) {
            if (best == null or value > best.?) best = value;
        }
        i = if (j > end) j else end;
    }
    return best;
}

// ── Entry point ──────────────────────────────────────────────────────────────

pub fn analyze(allocator: std.mem.Allocator, exp: *explorer.Explorer) !Report {
    var limits = std.ArrayList(Limit).empty;
    var findings = std.ArrayList(Finding).empty;
    errdefer {
        for (limits.items) |l| allocator.free(l.text);
        limits.deinit(allocator);
        for (findings.items) |f| {
            allocator.free(f.subject);
            allocator.free(f.detail);
            allocator.free(f.evidence);
        }
        findings.deinit(allocator);
    }

    // Pass 1: what limit does this repository declare? A `sized_constant`
    // finding needs one, because without a limit there is nothing to derive
    // from and a fixed buffer is a fixed buffer.
    var it = exp.outlines.iterator();
    while (it.next()) |entry| {
        const file_id = entry.key_ptr.*;
        if (exp.deleted_files.get(file_id) != null) continue;
        const outline = entry.value_ptr.*;
        if (is_excluded_path(outline.path)) continue;
        const content = exp.content_of(allocator, file_id) orelse continue;
        try collect_limits(allocator, outline, content, &limits);
    }

    // The tightest limit is the one a constant has to fit inside. Which file
    // declares it goes into the finding, because the tightest limit in a
    // multi-service repository often belongs to another service, and the reader
    // has to see that to judge the ratio.
    var smallest: ?u64 = null;
    var smallest_at: ?usize = null;
    for (limits.items, 0..) |l, i| {
        if (smallest == null or l.bytes < smallest.?) {
            smallest = l.bytes;
            smallest_at = i;
        }
    }

    // Pass 2: the shapes.
    var it2 = exp.outlines.iterator();
    while (it2.next()) |entry| {
        const file_id = entry.key_ptr.*;
        if (exp.deleted_files.get(file_id) != null) continue;
        const outline = entry.value_ptr.*;
        if (is_excluded_path(outline.path)) continue;
        const lang = outline.language;
        const content = exp.content_of(allocator, file_id) orelse continue;
        const file_reads_limit = contains_any(content, &derives_from_limit);
        if (smallest == null or file_reads_limit) continue;

        var line_no: usize = 0;
        var line_it = std.mem.splitScalar(u8, content, '\n');
        while (line_it.next()) |raw| {
            line_no += 1;
            const t = std.mem.trim(u8, raw, " \t\r");
            if (t.len == 0 or txt.is_comment(t, lang)) continue;
            if (!contains_any_ci(t, &sizing_keys)) continue;
            const bytes = sizing_constant(t) orelse continue;
            // A fixed byte constant against a declared limit.
            const pct: u32 = @intCast(@min(@as(u64, 100_000), bytes * 100 / smallest.?));
            const tightest = limits.items[smallest_at.?];
            try findings.append(allocator, .{
                .file = outline.path,
                .line = line_no,
                .kind = .sized_constant,
                .subject = try allocator.dupe(u8, sizing_key_in(t) orelse "size"),
                .detail = try std.fmt.allocPrint(
                    allocator,
                    "{d} bytes is fixed. The tightest memory limit this repository declares is {s} at {s}:{d}, so the constant is {d}% of it. Nothing links them.",
                    .{ bytes, tightest.text, tightest.file, tightest.line, pct },
                ),
                .evidence = try allocator.dupe(u8, t),
                .constant_bytes = bytes,
                .percent_of_limit = pct,
            });
        }
    }

    const found = try findings.toOwnedSlice(allocator);
    // The tightest fit first: a constant at 90% of the limit before one at 5%.
    std.mem.sort(Finding, found, {}, struct {
        fn less(_: void, a: Finding, b: Finding) bool {
            const ap = a.percent_of_limit orelse 0;
            const bp = b.percent_of_limit orelse 0;
            if (ap != bp) return ap > bp;
            return std.mem.lessThan(u8, a.file, b.file);
        }
    }.less);

    return .{
        .limits = try limits.toOwnedSlice(allocator),
        .findings = found,
    };
}

fn sizing_key_in(line: []const u8) ?[]const u8 {
    for (&sizing_keys) |k| {
        if (std.ascii.indexOfIgnoreCase(line, k) != null) return k;
    }
    return null;
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn one_file(allocator: std.mem.Allocator, path: []const u8, lang: models.Language, src: []const u8) !models.FileOutline {
    return .{
        .path = try allocator.dupe(u8, path),
        .language = lang,
        .line_count = std.mem.count(u8, src, "\n") + 1,
        .byte_size = src.len,
        .symbols = &[_]models.Symbol{},
        .imports = &[_][]const u8{},
    };
}

test "logic_shapes: the mmap_size fault, against the declared limit" {
    const allocator = testing.allocator;
    const manifest =
        \\resources:
        \\  limits:
        \\    cpu: "500m"
        \\    memory: "512Mi"
        \\
    ;
    const code =
        \\pub async fn create_pool(path: &str) -> Result<SqlitePool> {
        \\    let options = SqliteConnectOptions::new()
        \\        .filename(path)
        \\        .pragma("temp_store", "MEMORY")
        \\        .pragma("mmap_size", "268435456")
        \\        .pragma("wal_autocheckpoint", "1000");
        \\    SqlitePool::connect_with(options).await
        \\}
        \\
    ;
    var exp = try explorer.Explorer.init(allocator);
    defer exp.deinit();
    _ = try exp.add_file(try one_file(allocator, "deploy/tenant.yaml", .yaml, manifest), manifest);
    _ = try exp.add_file(try one_file(allocator, "src/db/sqlite.rs", .rust, code), code);
    exp.mark_indexing_complete();

    var report = try analyze(allocator, &exp);
    defer report.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), report.limits.len);
    try testing.expectEqual(@as(u64, 512 * 1024 * 1024), report.limits[0].bytes);

    try testing.expectEqual(@as(usize, 1), report.findings.len);
    const f = report.findings[0];
    try testing.expectEqual(Kind.sized_constant, f.kind);
    try testing.expectEqualStrings("src/db/sqlite.rs", f.file);
    try testing.expectEqual(@as(usize, 5), f.line);
    try testing.expectEqualStrings("mmap_size", f.subject);
    try testing.expectEqual(@as(?u64, 268435456), f.constant_bytes);
    try testing.expectEqual(@as(?u32, 50), f.percent_of_limit);
}

test "logic_shapes: a constant that reads the limit is not a finding" {
    const allocator = testing.allocator;
    const manifest = "resources:\n  limits:\n    memory: \"512Mi\"\n";
    const code =
        \\pub fn mmap_size() -> u64 {
        \\    let limit = std::env::var("MEMORY_LIMIT_BYTES").ok();
        \\    limit.map(|l| l / 4).unwrap_or(268435456)
        \\}
        \\
    ;
    var exp = try explorer.Explorer.init(allocator);
    defer exp.deinit();
    _ = try exp.add_file(try one_file(allocator, "deploy/tenant.yaml", .yaml, manifest), manifest);
    _ = try exp.add_file(try one_file(allocator, "src/db/sqlite.rs", .rust, code), code);
    exp.mark_indexing_complete();

    var report = try analyze(allocator, &exp);
    defer report.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), report.findings.len);
}

test "logic_shapes: with no declared limit there is nothing to derive from" {
    const allocator = testing.allocator;
    const code = "let opts = Options::new().pragma(\"mmap_size\", \"268435456\");\n";
    var exp = try explorer.Explorer.init(allocator);
    defer exp.deinit();
    _ = try exp.add_file(try one_file(allocator, "src/db.rs", .rust, code), code);
    exp.mark_indexing_complete();

    var report = try analyze(allocator, &exp);
    defer report.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), report.limits.len);
    try testing.expectEqual(@as(usize, 0), report.findings.len);
}

test "logic_shapes: quantities parse to bytes" {
    try testing.expectEqual(@as(?u64, 512 * 1024 * 1024), parse_quantity("512Mi"));
    try testing.expectEqual(@as(?u64, 1024 * 1024 * 1024), parse_quantity("\"1Gi\""));
    try testing.expectEqual(@as(?u64, 350 * 1000 * 1000), parse_quantity("350M"));
    try testing.expectEqual(@as(?u64, null), parse_quantity("latest"));
}

test "logic_shapes: a product folds into one constant" {
    try testing.expectEqual(@as(?u64, 64 * 1024 * 1024), sizing_constant("let cache_size = 64 * 1024 * 1024;"));
    try testing.expectEqual(@as(?u64, 268435456), sizing_constant(".pragma(\"mmap_size\", \"268435456\")"));
    // Below a mebibyte is not a memory region worth reporting.
    try testing.expectEqual(@as(?u64, null), sizing_constant("let buffer_size = 4096;"));
}

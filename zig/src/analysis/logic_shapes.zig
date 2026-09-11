//! Two logic shapes that cost production money.
//!
//! `sized_constant` — a fixed byte constant that should have come from a limit.
//! The fault: a SQLite `mmap_size` pinned at a flat 256 MiB with no relation to
//! the container memory limit. One pod mapped 381 MB of a 334 MB database inside
//! a 512 MiB limit, and the kernel reclaimed without pause. The constant alone
//! is not a finding — plenty of buffers are correctly fixed. The finding is a
//! fixed constant in a repository that declares a memory limit the constant
//! never reads, and the number that makes it actionable is the ratio.
//!
//! `call_in_loop` — a database query or an HTTP call inside a loop over rows.
//! The N+1 shape: one round trip per row where one round trip would do.

const std = @import("std");
const explorer = @import("../index/explorer.zig");
const models = @import("../core/models.zig");

pub const Kind = enum {
    sized_constant,
    call_in_loop,

    pub fn as_str(self: Kind) []const u8 {
        return switch (self) {
            .sized_constant => "sized_constant",
            .call_in_loop => "call_in_loop",
        };
    }

    /// `sized_constant` is decidable: the constant either fits inside the
    /// declared limit or it does not, and both numbers are in the repository.
    /// `call_in_loop` is not: a loop over three configuration rows makes three
    /// round trips and costs nothing.
    pub fn confidence(self: Kind) []const u8 {
        return switch (self) {
            .sized_constant => "finding",
            .call_in_loop => "shape",
        };
    }

    /// Empty when the kind is decidable from the source alone.
    pub fn runtime_check(self: Kind) []const u8 {
        return switch (self) {
            .sized_constant => "",
            .call_in_loop => "the size of the collection the loop walks; a loop over three rows is not an N+1",
        };
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

// ── Scope ────────────────────────────────────────────────────────────────────

fn is_excluded_path(path: []const u8) bool {
    const dirs = [_][]const u8{
        "test",         "tests",  "spec",   "benches",  "bench",    "examples", "example",
        "node_modules", "vendor", "target", "testdata", "fixtures", "docs",
    };
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |component| {
        for (&dirs) |d| {
            if (std.mem.eql(u8, component, d)) return true;
        }
    }
    const basename = std.fs.path.basename(path);
    if (std.mem.indexOf(u8, basename, "_test.") != null) return true;
    if (std.mem.indexOf(u8, basename, ".test.") != null) return true;
    if (std.mem.indexOf(u8, basename, ".spec.") != null) return true;
    if (std.mem.startsWith(u8, basename, "test_")) return true;
    return false;
}

fn ident_char(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn contains_any_ci(hay: []const u8, needles: []const []const u8) bool {
    for (needles) |n| {
        if (std.ascii.indexOfIgnoreCase(hay, n) != null) return true;
    }
    return false;
}

fn contains_any(hay: []const u8, needles: []const []const u8) bool {
    for (needles) |n| {
        if (std.mem.indexOf(u8, hay, n) != null) return true;
    }
    return false;
}

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

// ── Shape: a call inside a loop over rows ────────────────────────────────────

/// Markers that execute a statement against a database.
///
/// A bare `.execute(` matched `tool.execute(call.arguments)` and every other
/// execute-shaped method, and it fired a second time on the `.execute(&pool)`
/// continuation of a `sqlx::query(…)` already reported. The markers below name
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
    ".send().await", ".send()?",       "reqwest::get(", "reqwest::Client::new()",
    "requests.get(", "requests.post(", "requests.put(", "requests.delete(",
    "axios.get(",    "axios.post(",    "axios.put(",    "axios.delete(",
    "http.Get(",     "http.Post(",     "urlopen(",      "await fetch(",
};

/// A loop that walks a collection. `for i in 0..n` is a counted loop and often
/// has nothing to do with rows; `for row in rows` is the N+1 shape.
fn loop_over_collection(t: []const u8, lang: models.Language) bool {
    switch (lang) {
        .rust => {
            if (!std.mem.startsWith(u8, t, "for ")) return false;
            if (std.mem.indexOf(u8, t, "..") != null) return false;
            if (std.mem.indexOf(u8, t, " in ") == null) return false;
            return !iterates_a_fixed_list(t, " in ");
        },
        .python => {
            if (!std.mem.startsWith(u8, t, "for ")) return false;
            if (std.mem.indexOf(u8, t, "range(") != null) return false;
            if (std.mem.indexOf(u8, t, " in ") == null) return false;
            return !iterates_a_fixed_list(t, " in ");
        },
        .typescript, .javascript => {
            if (std.mem.startsWith(u8, t, "for ") and std.mem.indexOf(u8, t, " of ") != null) {
                return !iterates_a_fixed_list(t, " of ");
            }
            return std.mem.indexOf(u8, t, ".forEach(") != null or
                std.mem.indexOf(u8, t, ".map(async") != null;
        },
        .go => {
            if (!std.mem.startsWith(u8, t, "for ") or std.mem.indexOf(u8, t, " range ") == null) return false;
            return !iterates_a_fixed_list(t, " range ");
        },
        else => return false,
    }
}

/// Whether the loop walks something whose length the source fixes: an array
/// literal, or a constant named in the screaming case a constant uses.
///
/// `for table in ["tasks", "goals"]` runs twice. `for pdef in PROVIDERS` runs
/// once per declared provider. Neither is an N+1, and five of the forty-two
/// findings on one repository were exactly this.
fn iterates_a_fixed_list(t: []const u8, keyword: []const u8) bool {
    const kw = std.mem.indexOf(u8, t, keyword) orelse return false;
    var it = std.mem.trimStart(u8, t[kw + keyword.len ..], " \t&*");
    if (it.len == 0) return false;
    // An inline array literal, on this line or opened at the end of it.
    if (it[0] == '[') return true;

    var end: usize = 0;
    while (end < it.len and (ident_char(it[end]) or it[end] == ':')) end += 1;
    const name = it[0..end];
    if (name.len == 0) return false;
    // A constant: no lowercase letter, and at least one letter.
    var has_letter = false;
    for (name) |c| {
        if (std.ascii.isLower(c)) return false;
        if (std.ascii.isAlphabetic(c)) has_letter = true;
    }
    return has_letter;
}

fn brace_delta(line: []const u8) isize {
    var d: isize = 0;
    var in_single = false;
    var in_double = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (c == '\\') {
            i += 1;
            continue;
        }
        if (c == '\'' and !in_double) in_single = !in_single;
        if (c == '"' and !in_single) in_double = !in_double;
        if (in_single or in_double) continue;
        if (c == '{') d += 1;
        if (c == '}') d -= 1;
    }
    return d;
}

fn indent_of(line: []const u8) usize {
    var n: usize = 0;
    while (n < line.len and (line[n] == ' ' or line[n] == '\t')) n += 1;
    return n;
}

fn is_comment(t: []const u8, lang: models.Language) bool {
    if (std.mem.startsWith(u8, t, "//")) return true;
    if (std.mem.startsWith(u8, t, "/*")) return true;
    if (std.mem.startsWith(u8, t, "*")) return true;
    if ((lang == .python or lang == .yaml or lang == .bash) and std.mem.startsWith(u8, t, "#")) return true;
    return false;
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
        const content = exp.content_cache.get(file_id) orelse continue;
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
        const content = exp.content_cache.get(file_id) orelse continue;
        const file_reads_limit = contains_any(content, &derives_from_limit);

        var line_no: usize = 0;
        var depth: isize = 0;
        var loop_depth: isize = 0;
        var loop_indent: usize = 0;
        var loop_line: usize = 0;
        var in_loop = false;
        var loop_reported = false;
        var line_it = std.mem.splitScalar(u8, content, '\n');
        while (line_it.next()) |raw| {
            line_no += 1;
            const t = std.mem.trim(u8, raw, " \t\r");
            if (t.len == 0 or is_comment(t, lang)) {
                if (lang != .python) depth += brace_delta(raw);
                continue;
            }

            // A fixed byte constant against a declared limit.
            if (smallest != null and contains_any_ci(t, &sizing_keys)) {
                if (sizing_constant(t)) |bytes| {
                    if (!file_reads_limit) {
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
            }

            // Close a loop this line left.
            if (in_loop) {
                if (lang == .python) {
                    if (indent_of(raw) <= loop_indent) in_loop = false;
                } else if (depth < loop_depth) {
                    in_loop = false;
                }
            }

            // A round trip per row. One finding per LOOP, not per line: the
            // fault is the loop, and a `sqlx::query(…)` spread over its
            // `.fetch_one(&pool)` continuation is one round trip, not two.
            if (in_loop and !loop_reported) {
                const is_query = contains_any(t, &query_calls);
                const is_http = !is_query and contains_any(t, &http_calls);
                if (is_query or is_http) {
                    loop_reported = true;
                    try findings.append(allocator, .{
                        .file = outline.path,
                        .line = line_no,
                        .kind = .call_in_loop,
                        .subject = try allocator.dupe(u8, if (is_query) "query" else "http call"),
                        .detail = try std.fmt.allocPrint(
                            allocator,
                            "the loop at line {d} walks a collection and makes one round trip per element",
                            .{loop_line},
                        ),
                        .evidence = try allocator.dupe(u8, t),
                    });
                }
            }

            if (!in_loop and loop_over_collection(t, lang)) {
                in_loop = true;
                loop_reported = false;
                loop_line = line_no;
                loop_indent = indent_of(raw);
                loop_depth = depth + brace_delta(raw);
            }
            if (lang != .python) depth += brace_delta(raw);
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

test "logic_shapes: a query inside a loop over rows" {
    const allocator = testing.allocator;
    const code =
        \\pub async fn load(ids: Vec<i64>) -> Vec<Row> {
        \\    let mut out = Vec::new();
        \\    for id in ids {
        \\        let row = sqlx::query_as("SELECT * FROM t WHERE id = ?").bind(id).fetch_one(&pool).await?;
        \\        out.push(row);
        \\    }
        \\    out
        \\}
        \\
    ;
    var exp = try explorer.Explorer.init(allocator);
    defer exp.deinit();
    _ = try exp.add_file(try one_file(allocator, "src/load.rs", .rust, code), code);
    exp.mark_indexing_complete();

    var report = try analyze(allocator, &exp);
    defer report.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), report.findings.len);
    try testing.expectEqual(Kind.call_in_loop, report.findings[0].kind);
    try testing.expectEqual(@as(usize, 4), report.findings[0].line);
    try testing.expectEqualStrings("query", report.findings[0].subject);
}

test "logic_shapes: a counted loop is not a loop over rows" {
    const allocator = testing.allocator;
    const code =
        \\pub async fn warm() {
        \\    for i in 0..8 {
        \\        pool.execute("PRAGMA optimize").await?;
        \\    }
        \\}
        \\
    ;
    var exp = try explorer.Explorer.init(allocator);
    defer exp.deinit();
    _ = try exp.add_file(try one_file(allocator, "src/warm.rs", .rust, code), code);
    exp.mark_indexing_complete();

    var report = try analyze(allocator, &exp);
    defer report.deinit(allocator);
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

test "logic_shapes: a loop over a fixed list is not an N+1" {
    const allocator = testing.allocator;
    // `for table in ["tasks", "goals"]` runs twice; `for p in PROVIDERS` runs
    // once per declared provider. Five findings on one repository were these.
    const code =
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
    ;
    var exp = try explorer.Explorer.init(allocator);
    defer exp.deinit();
    _ = try exp.add_file(try one_file(allocator, "src/counts.rs", .rust, code), code);
    exp.mark_indexing_complete();

    var report = try analyze(allocator, &exp);
    defer report.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), report.findings.len);
}

test "logic_shapes: a fixed list is told apart from a real collection" {
    try testing.expect(iterates_a_fixed_list("for table in [\"tasks\", \"goals\"] {", " in "));
    try testing.expect(iterates_a_fixed_list("for pdef in PROVIDERS {", " in "));
    try testing.expect(iterates_a_fixed_list("for (id, status) in [", " in "));
    try testing.expect(!iterates_a_fixed_list("for row in rows {", " in "));
    try testing.expect(!iterates_a_fixed_list("for r in &expired {", " in "));
    try testing.expect(!iterates_a_fixed_list("for scored in &merged {", " in "));
}

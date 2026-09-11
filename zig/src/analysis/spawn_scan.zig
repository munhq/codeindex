//! Interpreter spawns on a timer.
//!
//! The fault: a supervisor script polled a 40-byte S3 object every 15 seconds
//! with `aws s3 cp`. The AWS CLI is a Python program. Measured in the pod, one
//! read cost 0.78 s of CPU and 7.7 s of wall time; three pods with a site burned
//! 88-98m of CPU against 1m for the pod without one. The script also ran a
//! long-lived `node` server in the same container, so the machinery to hold an
//! open connection was already there.
//!
//! Two conditions make a finding: the target is an interpreter, and the spawn
//! runs on a loop or a timer. A one-shot script, a build stage and a test all
//! start interpreters, and none of them repeat.
//!
//! Shell needs a call graph. In the fault the spawn sat two hops from the loop:
//! `while true` called `sync_app`, `sync_app` called the wrapper `s3()`, and
//! `s3()` ran `aws`. A scan that only reads the lines between `do` and `done`
//! reports nothing.

const std = @import("std");
const explorer = @import("../index/explorer.zig");
const models = @import("../core/models.zig");

/// An interpreter, or a CLI written in one.
///
/// `startup_ms` ranks findings against each other. It is one measured cold start
/// on a warm page cache, not a prediction: the `aws` figure is the 780 ms from
/// the fault this detector reports. A ranking needs the ratios to be right, and
/// a Perl start really is two orders of magnitude cheaper than an AWS CLI start.
pub const Runtime = struct {
    command: []const u8,
    language: []const u8,
    startup_ms: u32,
};

const runtimes = [_]Runtime{
    // Python CLIs. The startup cost is the interpreter plus the SDK import.
    .{ .command = "aws", .language = "python", .startup_ms = 780 },
    .{ .command = "gcloud", .language = "python", .startup_ms = 900 },
    .{ .command = "gsutil", .language = "python", .startup_ms = 900 },
    .{ .command = "az", .language = "python", .startup_ms = 900 },
    .{ .command = "ansible", .language = "python", .startup_ms = 400 },
    .{ .command = "ansible-playbook", .language = "python", .startup_ms = 400 },
    .{ .command = "pip", .language = "python", .startup_ms = 300 },
    .{ .command = "pip3", .language = "python", .startup_ms = 300 },
    .{ .command = "python", .language = "python", .startup_ms = 40 },
    .{ .command = "python3", .language = "python", .startup_ms = 40 },
    // Node.
    .{ .command = "npm", .language = "node", .startup_ms = 250 },
    .{ .command = "npx", .language = "node", .startup_ms = 300 },
    .{ .command = "yarn", .language = "node", .startup_ms = 250 },
    .{ .command = "pnpm", .language = "node", .startup_ms = 200 },
    .{ .command = "ts-node", .language = "node", .startup_ms = 800 },
    .{ .command = "node", .language = "node", .startup_ms = 40 },
    // The rest.
    .{ .command = "Rscript", .language = "r", .startup_ms = 250 },
    .{ .command = "java", .language = "jvm", .startup_ms = 300 },
    .{ .command = "ruby", .language = "ruby", .startup_ms = 60 },
    .{ .command = "php", .language = "php", .startup_ms = 30 },
    .{ .command = "perl", .language = "perl", .startup_ms = 10 },
};

fn runtime_index(word: []const u8) ?usize {
    // A path prefix is common in a container: /usr/local/bin/python3.
    const base = std.fs.path.basename(word);
    for (&runtimes, 0..) |rt, i| {
        if (std.mem.eql(u8, base, rt.command)) return i;
    }
    return null;
}

pub const Finding = struct {
    file: []const u8,
    /// 1-based line of the spawn.
    line: usize,
    /// The command word at the spawn site: `aws`, or the wrapper `s3`.
    command: []const u8,
    /// The interpreter that command word runs.
    runtime: []const u8,
    language: []const u8,
    /// Seconds between spawns, when the loop states its period.
    period_secs: ?u32,
    spawns_per_hour: ?u32,
    /// `startup_ms * spawns_per_hour`. Milliseconds of CPU per hour, so a
    /// 15-second loop outranks an hourly one. Zero when the period is unknown.
    cost_score: u64,
    /// 1-based line of the loop or timer that repeats the spawn.
    loop_line: usize,
    /// Set when the command word is a shell function that runs the interpreter.
    /// Owned.
    via: ?[]const u8,
    /// A long-lived process in the same unit. This is what raises the finding
    /// from "you start an interpreter" to "you start an interpreter although a
    /// process is already running". Owned.
    long_lived_peer: ?[]const u8,
};

pub const Summary = struct {
    total: usize,
    with_known_rate: usize,
    with_long_lived_peer: usize,
};

pub fn summarize(findings: []const Finding) Summary {
    var s = Summary{ .total = findings.len, .with_known_rate = 0, .with_long_lived_peer = 0 };
    for (findings) |f| {
        if (f.period_secs != null) s.with_known_rate += 1;
        if (f.long_lived_peer != null) s.with_long_lived_peer += 1;
    }
    return s;
}

pub fn free_findings(allocator: std.mem.Allocator, findings: []Finding) void {
    for (findings) |f| {
        if (f.via) |v| allocator.free(v);
        if (f.long_lived_peer) |p| allocator.free(p);
    }
    allocator.free(findings);
}

// ── Path precision ───────────────────────────────────────────────────────────

/// A spawn in a test, a build stage or an example repeats only while that thing
/// runs, so the cost the ranking multiplies by never accrues in production.
fn is_excluded_path(path: []const u8) bool {
    const dirs = [_][]const u8{
        "test",     "tests",    "spec",         "examples", "example",
        "fixtures", "testdata", "node_modules", "vendor",   ".github",
        "docs",     "benches",  "bench",
    };
    var comp_it = std.mem.splitScalar(u8, path, '/');
    while (comp_it.next()) |component| {
        for (&dirs) |d| {
            if (std.mem.eql(u8, component, d)) return true;
        }
    }
    const basename = std.fs.path.basename(path);
    if (std.mem.startsWith(u8, basename, "test_")) return true;
    if (std.mem.indexOf(u8, basename, "_test.") != null) return true;
    if (std.mem.indexOf(u8, basename, ".test.") != null) return true;
    if (std.mem.indexOf(u8, basename, ".spec.") != null) return true;
    return false;
}

// ── Line and token helpers ───────────────────────────────────────────────────

fn split_lines(allocator: std.mem.Allocator, content: []const u8) ![][]const u8 {
    var lines = std.ArrayList([]const u8).empty;
    errdefer lines.deinit(allocator);
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |l| try lines.append(allocator, std.mem.trimEnd(u8, l, "\r"));
    return lines.toOwnedSlice(allocator);
}

fn is_word_char(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.' or c == '/';
}

/// The part of a shell line before an unquoted `#`. A `#` inside a word — a
/// fragment URL, `${x#prefix}`, `$#` — is not a comment.
fn strip_shell_comment(line: []const u8) []const u8 {
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
        if (c == '#' and !in_single and !in_double) {
            if (i == 0) return line[0..0];
            const p = line[i - 1];
            if (p == ' ' or p == '\t' or p == ';' or p == '(') return line[0..i];
        }
    }
    return line;
}

// ── Shell command words ──────────────────────────────────────────────────────

/// Prefixes that stand in front of the real command and must be stepped over.
const shell_prefix_words = [_][]const u8{
    "sudo",   "env",     "nohup",  "exec",   "command", "builtin",
    "time",   "then",    "else",   "elif",   "do",      "done",
    "if",     "while",   "until",  "for",    "in",      "fi",
    "esac",   "case",    "local",  "export", "declare", "readonly",
    "eval",   "source",  ".",      "!",      "{",       "}",
    "(",      ")",       "[",      "[[",     "&&",      "||",
    "return", "set",     "shopt",  "trap",   "wait",    "shift",
    "xargs",  "timeout", "stdbuf", "ionice", "nice",    "unbuffer",
};

fn is_prefix_word(word: []const u8) bool {
    for (&shell_prefix_words) |w| {
        if (std.mem.eql(u8, word, w)) return true;
    }
    // `VAR=value cmd …` — a leading assignment.
    if (std.mem.indexOfScalar(u8, word, '=')) |eq| {
        if (eq > 0) return true;
    }
    return false;
}

/// A command word found on a shell line, with the byte offset it started at.
const CmdWord = struct {
    word: []const u8,
    offset: usize,
};

/// Command words on one shell line.
///
/// A command word is the first real word of each segment. Segments break on
/// `;`, `|`, `&`, `&&`, `||`, and on a command substitution `$(` or a backtick,
/// which is how the fault's spawn hides: `sha="$(s3 cp … | tr -d …)"`.
fn command_words(allocator: std.mem.Allocator, line_in: []const u8, out: *std.ArrayList(CmdWord)) !void {
    const line = strip_shell_comment(line_in);
    var i: usize = 0;
    var expect_command = true;
    while (i < line.len) {
        const c = line[i];
        if (c == '\\') {
            i += 2;
            continue;
        }
        // A single-quoted run is literal: no substitution, no separators.
        if (c == '\'') {
            i += 1;
            while (i < line.len and line[i] != '\'') i += 1;
            i += 1;
            continue;
        }
        if (c == ';' or c == '|' or c == '&' or c == '(' or c == ')' or
            c == '{' or c == '}' or c == '`')
        {
            expect_command = true;
            i += 1;
            continue;
        }
        if (c == '$' and i + 1 < line.len and line[i + 1] == '(') {
            expect_command = true;
            i += 2;
            continue;
        }
        if (c == ' ' or c == '\t') {
            i += 1;
            continue;
        }

        // One shell token. Quotes and `${…}` stay inside it, so
        // `PORT="${PORT:-8080}"` is ONE token and reads as the assignment it is.
        // Before this, the scan broke at the quote and took `$APPS_ROOT` in
        // `MUNBOT_APPS_ROOT="$APPS_ROOT" … node …` for the command.
        const start = i;
        var in_double = false;
        while (i < line.len) {
            const w = line[i];
            if (w == '\\') {
                i += 2;
                continue;
            }
            if (w == '"') {
                in_double = !in_double;
                i += 1;
                continue;
            }
            if (w == '\'' and !in_double) {
                i += 1;
                while (i < line.len and line[i] != '\'') i += 1;
                i += 1;
                continue;
            }
            // A command substitution ends the token and opens a command
            // position: `sha="$(s3 cp …)"` runs `s3`.
            if (w == '$' and i + 1 < line.len and line[i + 1] == '(') break;
            // A parameter expansion is part of the token.
            if (w == '$' and i + 1 < line.len and line[i + 1] == '{') {
                var depth: usize = 0;
                while (i < line.len) : (i += 1) {
                    if (line[i] == '{') depth += 1;
                    if (line[i] == '}') {
                        depth -= 1;
                        if (depth == 0) {
                            i += 1;
                            break;
                        }
                    }
                }
                continue;
            }
            if (in_double) {
                i += 1;
                continue;
            }
            if (w == ' ' or w == '\t' or w == ';' or w == '|' or w == '&' or
                w == '`' or w == ')' or w == '(' or w == '{' or w == '}') break;
            i += 1;
        }
        const word = line[start..i];
        if (word.len == 0) {
            i += 1;
            continue;
        }
        if (!expect_command) continue;
        if (is_prefix_word(word)) continue;
        try out.append(allocator, .{ .word = word, .offset = start });
        expect_command = false;
    }
}

// ── Shell loop regions ───────────────────────────────────────────────────────

const LoopRegion = struct {
    /// 1-based header line (`while true; do`).
    header_line: usize,
    /// 1-based last line (`done`).
    end_line: usize,
    /// Index of the enclosing region, when nested.
    parent: ?usize,
    /// Seconds this loop sleeps per iteration, when it states one.
    period_secs: ?u32 = null,
    /// The header itself never ends: `while true`, `while :`, `until false`.
    unbounded_header: bool = false,
    /// This loop runs for the life of the process, so a spawn inside it repeats
    /// forever. A `for d in "$DIRS"` in a deploy script does not: it walks a
    /// list once and the script exits. Reporting those turned a one-shot deploy
    /// script into six findings, which is the case the specification excludes.
    repeats: bool = false,
};

/// `while true`, `while :`, `until false`, `for (( ; ; ))`.
fn header_is_unbounded(line: []const u8) bool {
    const forever = [_][]const u8{
        "while true", "while :", "while [ 1 ]", "until false", "for ((;;))", "for (( ; ; ))",
    };
    for (&forever) |f| {
        if (std.mem.indexOf(u8, line, f) != null) return true;
    }
    return false;
}

/// Whether the token at `idx` in `line` stands as a shell keyword rather than
/// as an argument. `echo do` must not open a loop.
fn keyword_at(line: []const u8, idx: usize, kw: []const u8) bool {
    if (idx > 0) {
        const p = line[idx - 1];
        if (is_word_char(p) or p == '$' or p == '"' or p == '\'') return false;
    }
    const after = idx + kw.len;
    if (after < line.len and is_word_char(line[after])) return false;
    // A keyword opens a command position: the line start, or after a separator.
    var j = idx;
    while (j > 0) {
        const p = line[j - 1];
        if (p == ' ' or p == '\t') {
            j -= 1;
            continue;
        }
        return p == ';' or p == '|' or p == '&' or p == '(' or p == ')';
    }
    return true;
}

fn count_keyword(line: []const u8, kw: []const u8) usize {
    var n: usize = 0;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, line, from, kw)) |idx| {
        if (keyword_at(line, idx, kw)) n += 1;
        from = idx + kw.len;
    }
    return n;
}

/// Seconds a `sleep` argument names, resolving `$VAR` and `${VAR:-N}` against
/// the assignments in the same file. Sub-second sleeps round up to 1.
fn sleep_seconds(line: []const u8, all_lines: []const []const u8) ?u32 {
    const idx = std.mem.indexOf(u8, line, "sleep") orelse return null;
    if (!keyword_at(line, idx, "sleep")) return null;
    var rest = std.mem.trim(u8, line[idx + "sleep".len ..], " \t\"'");
    if (rest.len == 0) return null;
    // Take the first argument only.
    if (std.mem.indexOfAny(u8, rest, " \t;|&")) |sp| rest = rest[0..sp];
    rest = std.mem.trim(u8, rest, " \t\"'");
    if (rest.len == 0) return null;

    if (std.ascii.isDigit(rest[0])) return parse_seconds(rest);

    // `$POLL_SECS`, `${POLL_SECS}`, `${POLL_SECS:-15}`.
    if (rest[0] != '$') return null;
    var name = rest[1..];
    if (name.len > 0 and name[0] == '{') {
        name = name[1..];
        if (std.mem.indexOfScalar(u8, name, '}')) |close| name = name[0..close];
        // An inline default is the answer without a lookup.
        if (std.mem.indexOf(u8, name, ":-")) |d| {
            const dflt = std.mem.trim(u8, name[d + 2 ..], " \t\"'");
            if (dflt.len > 0 and std.ascii.isDigit(dflt[0])) return parse_seconds(dflt);
            name = name[0..d];
        }
    }
    if (name.len == 0) return null;
    return lookup_numeric_assignment(name, all_lines);
}

fn parse_seconds(text: []const u8) ?u32 {
    var end: usize = 0;
    while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
    if (end == 0) return null;
    const whole = std.fmt.parseInt(u32, text[0..end], 10) catch return null;
    // `sleep 0.5` — round up, so a sub-second loop never scores as free.
    if (whole == 0) return 1;
    return whole;
}

/// The number in `NAME=15` or `NAME="${NAME:-15}"` anywhere in the file.
fn lookup_numeric_assignment(name: []const u8, all_lines: []const []const u8) ?u32 {
    for (all_lines) |raw| {
        const line = strip_shell_comment(raw);
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (!std.mem.startsWith(u8, trimmed, name)) continue;
        const after = trimmed[name.len..];
        if (after.len == 0 or after[0] != '=') continue;
        var value = std.mem.trim(u8, after[1..], " \t\"'");
        if (value.len == 0) continue;
        if (std.ascii.isDigit(value[0])) return parse_seconds(value);
        // `"${NAME:-15}"`
        if (std.mem.indexOf(u8, value, ":-")) |d| {
            value = std.mem.trim(u8, value[d + 2 ..], " \t\"'}");
            if (value.len > 0 and std.ascii.isDigit(value[0])) return parse_seconds(value);
        }
    }
    return null;
}

/// Loop regions in a shell file, innermost last, each carrying the period it
/// sleeps — inherited from the enclosing loop when the inner one states none.
fn shell_loops(allocator: std.mem.Allocator, lines: []const []const u8) ![]LoopRegion {
    var regions = std.ArrayList(LoopRegion).empty;
    errdefer regions.deinit(allocator);
    var open = std.ArrayList(usize).empty;
    defer open.deinit(allocator);

    for (lines, 0..) |raw, i| {
        const line = strip_shell_comment(raw);
        const line_no = i + 1;

        // `sleep` belongs to the innermost open loop.
        if (open.items.len > 0) {
            if (sleep_seconds(line, lines)) |secs| {
                const top = open.items[open.items.len - 1];
                if (regions.items[top].period_secs == null) regions.items[top].period_secs = secs;
            }
        }

        // `done` closes before `do` opens, so `done; do` on one line nests right.
        var closes = count_keyword(line, "done");
        while (closes > 0 and open.items.len > 0) : (closes -= 1) {
            const top = open.pop().?;
            regions.items[top].end_line = line_no;
        }
        var opens = count_keyword(line, "do");
        // `done` contains `do`; count_keyword already required a word boundary,
        // so `done` never counts as `do`.
        while (opens > 0) : (opens -= 1) {
            const parent: ?usize = if (open.items.len > 0) open.items[open.items.len - 1] else null;
            try regions.append(allocator, .{
                .header_line = line_no,
                .end_line = lines.len,
                .parent = parent,
                .unbounded_header = header_is_unbounded(line),
            });
            try open.append(allocator, regions.items.len - 1);
        }
    }

    // Inherit the period from the nearest enclosing loop that states one.
    for (regions.items) |*r| {
        if (r.period_secs != null) continue;
        var p = r.parent;
        while (p) |pi| {
            if (regions.items[pi].period_secs) |secs| {
                r.period_secs = secs;
                break;
            }
            p = regions.items[pi].parent;
        }
    }

    // A loop repeats forever when it says so, when it paces itself with a
    // sleep, or when an enclosing loop does either.
    for (regions.items) |*r| {
        if (r.unbounded_header or r.period_secs != null) {
            r.repeats = true;
            continue;
        }
        var p = r.parent;
        while (p) |pi| {
            const parent_region = regions.items[pi];
            if (parent_region.unbounded_header or parent_region.period_secs != null) {
                r.repeats = true;
                break;
            }
            p = parent_region.parent;
        }
    }
    return regions.toOwnedSlice(allocator);
}

/// The innermost REPEATING loop containing `line`. A bounded loop is skipped:
/// a spawn inside it runs once per script invocation, which is the one-shot
/// case that must not be reported.
fn enclosing_loop(regions: []const LoopRegion, line: usize) ?usize {
    var best: ?usize = null;
    for (regions, 0..) |r, i| {
        if (!r.repeats) continue;
        if (line < r.header_line or line > r.end_line) continue;
        if (best == null or r.header_line > regions[best.?].header_line) best = i;
    }
    return best;
}

/// The outermost loop of the nest that `idx` belongs to. The report names the
/// poll loop, which is the one that carries the sleep.
fn outermost_loop(regions: []const LoopRegion, idx: usize) usize {
    var cur = idx;
    while (regions[cur].parent) |p| cur = p;
    return cur;
}

// ── Shell functions and the call graph ───────────────────────────────────────

const ShellFn = struct {
    name: []const u8,
    /// 1-based, inclusive.
    start: usize,
    end: usize,
    /// True when the body runs an interpreter directly, which makes calling this
    /// function a spawn at the call site — the `s3() { aws … }` wrapper.
    direct_runtime: ?usize = null,
    /// Set by the walk from the loops.
    reached_from_loop: ?usize = null,

    /// A thin wrapper stands in for the interpreter it runs, so the finding
    /// belongs at the CALL site: the fault reads `supervisor.sh:139`, which is
    /// where `s3 cp` runs, not line 29 where `s3()` is defined. Reporting inside
    /// the wrapper body as well would count one spawn twice.
    fn is_wrapper(self: ShellFn) bool {
        return self.direct_runtime != null and self.end - self.start <= 2;
    }
};

fn shell_functions(allocator: std.mem.Allocator, outline: models.FileOutline) ![]ShellFn {
    var fns = std.ArrayList(ShellFn).empty;
    errdefer fns.deinit(allocator);
    for (outline.symbols) |sym| {
        if (sym.kind != .function) continue;
        try fns.append(allocator, .{
            .name = sym.name,
            .start = sym.start_1(),
            .end = sym.end_1(),
        });
    }
    return fns.toOwnedSlice(allocator);
}

fn function_at(fns: []const ShellFn, line: usize) ?usize {
    var best: ?usize = null;
    for (fns, 0..) |f, i| {
        if (line < f.start or line > f.end) continue;
        if (best == null or f.start > fns[best.?].start) best = i;
    }
    return best;
}

fn function_named(fns: []const ShellFn, name: []const u8) ?usize {
    for (fns, 0..) |f, i| {
        if (std.mem.eql(u8, f.name, name)) return i;
    }
    return null;
}

/// A background start (`cmd &`) or an `exec` of something that is not obviously
/// short-lived. This is the "a process is already running" half of the finding.
const short_lived_cmds = [_][]const u8{
    "echo", "printf", "sleep", "rm", "mkdir", "true", "false", "cat",
    "kill", "touch",  "cp",    "mv", "sync",  "wait", "trap",  "date",
};

fn is_short_lived(word: []const u8) bool {
    const base = std.fs.path.basename(word);
    for (&short_lived_cmds) |c| {
        if (std.mem.eql(u8, base, c)) return true;
    }
    return false;
}

/// True when the line ends with a single `&` — a background start, not `&&`.
fn ends_with_background(line: []const u8) bool {
    const t = std.mem.trimEnd(u8, line, " \t");
    if (t.len == 0 or t[t.len - 1] != '&') return false;
    if (t.len >= 2 and t[t.len - 2] == '&') return false;
    return true;
}

// ── Shell pass ───────────────────────────────────────────────────────────────

fn scan_shell(
    allocator: std.mem.Allocator,
    outline: models.FileOutline,
    content: []const u8,
    findings: *std.ArrayList(Finding),
) !void {
    const lines = try split_lines(allocator, content);
    defer allocator.free(lines);
    const regions = try shell_loops(allocator, lines);
    defer allocator.free(regions);
    var any_repeats = false;
    for (regions) |r| {
        if (r.repeats) any_repeats = true;
    }
    if (!any_repeats) return;

    var fns = try shell_functions(allocator, outline);
    defer allocator.free(fns);

    var words = std.ArrayList(CmdWord).empty;
    defer words.deinit(allocator);

    // Pass 1: which functions run an interpreter in their own body. A call to
    // one of those is a spawn at the CALL site, which is where the fault reads:
    // `supervisor.sh:139`, not the `s3()` definition on line 29.
    for (fns, 0..) |*f, fi| {
        _ = fi;
        var l = f.start;
        while (l <= f.end and l <= lines.len) : (l += 1) {
            words.clearRetainingCapacity();
            try command_words(allocator, lines[l - 1], &words);
            for (words.items) |cw| {
                if (runtime_index(cw.word)) |ri| {
                    if (f.direct_runtime == null) f.direct_runtime = ri;
                }
            }
        }
    }

    // Pass 2: walk out from every loop body through the call graph, so a spawn
    // that sits two calls away from `while true` is still on the timer.
    var changed = true;
    var rounds: usize = 0;
    while (changed and rounds < 16) : (rounds += 1) {
        changed = false;
        for (lines, 0..) |raw, i| {
            const line_no = i + 1;
            // Which loop repeats this line: the one enclosing it, or the one
            // that reaches the function this line sits in.
            const repeat_loop: ?usize = blk: {
                if (enclosing_loop(regions, line_no)) |r| break :blk r;
                if (function_at(fns, line_no)) |fi| break :blk fns[fi].reached_from_loop;
                break :blk null;
            };
            if (repeat_loop == null) continue;

            words.clearRetainingCapacity();
            try command_words(allocator, raw, &words);
            for (words.items) |cw| {
                const callee = function_named(fns, cw.word) orelse continue;
                if (fns[callee].reached_from_loop != null) continue;
                // A function must not mark itself through its own body.
                if (function_at(fns, line_no)) |host| {
                    if (host == callee) continue;
                }
                fns[callee].reached_from_loop = repeat_loop;
                changed = true;
            }
        }
    }

    // The long-lived process in the same unit, if there is one.
    var peer_buf: [256]u8 = undefined;
    var peer: ?[]const u8 = null;
    var peer_line: usize = 0;
    for (lines, 0..) |raw, i| {
        const line = strip_shell_comment(raw);
        if (!ends_with_background(line)) continue;
        words.clearRetainingCapacity();
        try command_words(allocator, line, &words);
        if (words.items.len == 0) continue;
        const w = words.items[0].word;
        if (is_short_lived(w)) continue;
        if (function_named(fns, w) != null) continue;
        peer = std.fmt.bufPrint(&peer_buf, "{s} runs in the background from line {d}", .{
            std.fs.path.basename(w), i + 1,
        }) catch null;
        peer_line = i + 1;
        break;
    }

    // Pass 3: report.
    for (lines, 0..) |raw, i| {
        const line_no = i + 1;
        const repeat_loop: ?usize = blk: {
            if (enclosing_loop(regions, line_no)) |r| break :blk r;
            if (function_at(fns, line_no)) |fi| break :blk fns[fi].reached_from_loop;
            break :blk null;
        };
        const loop_idx = repeat_loop orelse continue;
        // The long-lived process starting itself is not a repeated spawn. It is
        // the peer every other finding here points at, and reporting it as a
        // spawn made the script accuse itself.
        if (line_no == peer_line) continue;

        // A wrapper's own definition line is not a spawn site: the call site is.
        const host_fn = function_at(fns, line_no);
        const inside_wrapper = host_fn != null and fns[host_fn.?].is_wrapper();

        words.clearRetainingCapacity();
        try command_words(allocator, raw, &words);
        for (words.items) |cw| {
            var via: ?[]const u8 = null;
            const ri: usize = blk: {
                if (runtime_index(cw.word)) |direct| {
                    if (inside_wrapper) continue;
                    break :blk direct;
                }
                const callee = function_named(fns, cw.word) orelse continue;
                if (host_fn != null and host_fn.? == callee) continue;
                if (!fns[callee].is_wrapper()) continue;
                const wrapped = fns[callee].direct_runtime.?;
                via = try allocator.dupe(u8, fns[callee].name);
                break :blk wrapped;
            };
            errdefer if (via) |v| allocator.free(v);

            const outer = outermost_loop(regions, loop_idx);
            const period = regions[loop_idx].period_secs orelse regions[outer].period_secs;
            const per_hour: ?u32 = if (period) |p| @intCast(@max(@as(u32, 1), 3600 / p)) else null;
            const owned_peer: ?[]const u8 = if (peer) |p| try allocator.dupe(u8, p) else null;

            try findings.append(allocator, .{
                .file = outline.path,
                .line = line_no,
                .command = runtimes[ri].command,
                .runtime = runtimes[ri].command,
                .language = runtimes[ri].language,
                .period_secs = period,
                .spawns_per_hour = per_hour,
                .cost_score = if (per_hour) |ph| @as(u64, runtimes[ri].startup_ms) * ph else 0,
                .loop_line = regions[outer].header_line,
                .via = via,
                .long_lived_peer = owned_peer,
            });
        }
    }
}

// ── Dockerfile pass ──────────────────────────────────────────────────────────

/// `HEALTHCHECK --interval=30s CMD python -c …` is a timer that starts an
/// interpreter, stated in the image itself.
fn scan_dockerfile(
    allocator: std.mem.Allocator,
    outline: models.FileOutline,
    content: []const u8,
    findings: *std.ArrayList(Finding),
) !void {
    const lines = try split_lines(allocator, content);
    defer allocator.free(lines);

    var words = std.ArrayList(CmdWord).empty;
    defer words.deinit(allocator);

    // The image's own long-lived process.
    var peer_buf: [256]u8 = undefined;
    var peer: ?[]const u8 = null;
    for (lines, 0..) |raw, i| {
        const t = std.mem.trimStart(u8, raw, " \t");
        if (!std.ascii.startsWithIgnoreCase(t, "CMD ") and
            !std.ascii.startsWithIgnoreCase(t, "ENTRYPOINT ")) continue;
        peer = std.fmt.bufPrint(&peer_buf, "the image entry point on line {d} runs for the life of the container", .{i + 1}) catch null;
    }

    for (lines, 0..) |raw, i| {
        const t = std.mem.trimStart(u8, raw, " \t");
        if (!std.ascii.startsWithIgnoreCase(t, "HEALTHCHECK")) continue;
        const interval = healthcheck_interval(t);
        const cmd_at = std.mem.indexOf(u8, t, "CMD") orelse continue;
        words.clearRetainingCapacity();
        try command_words(allocator, t[cmd_at + 3 ..], &words);
        for (words.items) |cw| {
            const ri = runtime_index(cw.word) orelse continue;
            const per_hour: ?u32 = if (interval) |p| @intCast(@max(@as(u32, 1), 3600 / p)) else null;
            try findings.append(allocator, .{
                .file = outline.path,
                .line = i + 1,
                .command = runtimes[ri].command,
                .runtime = runtimes[ri].command,
                .language = runtimes[ri].language,
                .period_secs = interval,
                .spawns_per_hour = per_hour,
                .cost_score = if (per_hour) |ph| @as(u64, runtimes[ri].startup_ms) * ph else 0,
                .loop_line = i + 1,
                .via = null,
                .long_lived_peer = if (peer) |p| try allocator.dupe(u8, p) else null,
            });
            break;
        }
    }
}

/// `--interval=30s` / `--interval=5m` in seconds. Docker defaults to 30 s.
fn healthcheck_interval(line: []const u8) ?u32 {
    const key = "--interval=";
    const idx = std.mem.indexOf(u8, line, key) orelse return 30;
    var rest = line[idx + key.len ..];
    if (std.mem.indexOfAny(u8, rest, " \t")) |sp| rest = rest[0..sp];
    var digits: usize = 0;
    while (digits < rest.len and std.ascii.isDigit(rest[digits])) digits += 1;
    if (digits == 0) return 30;
    const n = std.fmt.parseInt(u32, rest[0..digits], 10) catch return 30;
    const unit = rest[digits..];
    if (std.mem.startsWith(u8, unit, "ms")) return @max(@as(u32, 1), n / 1000);
    if (std.mem.startsWith(u8, unit, "m")) return n * 60;
    if (std.mem.startsWith(u8, unit, "h")) return n * 3600;
    return @max(@as(u32, 1), n);
}

// ── Application-code pass ────────────────────────────────────────────────────

/// A process-spawn API. `program_is_next` marks a call whose first argument is
/// the program: `Command::new("python3")`, `exec.Command("aws", …)`.
const SpawnApi = struct {
    text: []const u8,
    languages: []const models.Language,
};

const rust_langs = [_]models.Language{.rust};
const web_langs = [_]models.Language{ .typescript, .javascript };
const py_langs = [_]models.Language{.python};
const go_langs = [_]models.Language{.go};

const spawn_apis = [_]SpawnApi{
    .{ .text = "Command::new(", .languages = &rust_langs },
    .{ .text = "child_process.spawn(", .languages = &web_langs },
    .{ .text = "child_process.exec(", .languages = &web_langs },
    .{ .text = "execSync(", .languages = &web_langs },
    .{ .text = "spawnSync(", .languages = &web_langs },
    .{ .text = "execFile(", .languages = &web_langs },
    .{ .text = "subprocess.run(", .languages = &py_langs },
    .{ .text = "subprocess.Popen(", .languages = &py_langs },
    .{ .text = "subprocess.call(", .languages = &py_langs },
    .{ .text = "subprocess.check_output(", .languages = &py_langs },
    .{ .text = "os.system(", .languages = &py_langs },
    .{ .text = "exec.Command(", .languages = &go_langs },
    .{ .text = "exec.CommandContext(", .languages = &go_langs },
};

fn api_applies(api: SpawnApi, lang: models.Language) bool {
    for (api.languages) |l| {
        if (l == lang) return true;
    }
    return false;
}

/// The interpreter named in the first string literal after `from`.
fn program_runtime(line: []const u8, from: usize) ?usize {
    var i = from;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (c == ')') return null;
        if (c != '"' and c != '\'' and c != '`') continue;
        const quote = c;
        const start = i + 1;
        var end = start;
        while (end < line.len and line[end] != quote) end += 1;
        if (end >= line.len) return null;
        var text = line[start..end];
        // `sh -c "aws s3 cp …"` — the interpreter is inside the script.
        if (std.mem.indexOfAny(u8, text, " \t")) |sp| {
            const head = text[0..sp];
            if (runtime_index(head)) |ri| return ri;
            var it = std.mem.tokenizeAny(u8, text, " \t");
            while (it.next()) |w| {
                if (runtime_index(w)) |ri| return ri;
            }
            return null;
        }
        text = std.mem.trim(u8, text, " \t");
        return runtime_index(text);
    }
    return null;
}

/// A timer that repeats a callback. The period, in seconds, when the call
/// states one on the same line.
fn timer_period(line: []const u8) ?u32 {
    const markers = [_][]const u8{
        "setInterval(",    "tokio::time::interval(", "time.Tick(",  "time.NewTicker(",
        "schedule.every(", "@scheduled(",            "@Scheduled(",
    };
    for (&markers) |m| {
        if (std.mem.indexOf(u8, line, m) == null) continue;
        // `setInterval(fn, 15000)` — the last integer on the line, in ms.
        if (std.mem.eql(u8, m, "setInterval(")) {
            if (last_integer(line)) |ms| return @max(@as(u32, 1), ms / 1000);
            return null;
        }
        if (std.mem.indexOf(u8, line, "from_secs(")) |s| {
            if (first_integer(line[s + "from_secs(".len ..])) |secs| return @max(@as(u32, 1), secs);
        }
        if (std.mem.indexOf(u8, line, "from_millis(")) |s| {
            if (first_integer(line[s + "from_millis(".len ..])) |ms| return @max(@as(u32, 1), ms / 1000);
        }
        return null;
    }
    return null;
}

fn first_integer(text: []const u8) ?u32 {
    var i: usize = 0;
    while (i < text.len and !std.ascii.isDigit(text[i])) : (i += 1) {}
    if (i >= text.len) return null;
    var end = i;
    while (end < text.len and (std.ascii.isDigit(text[end]) or text[end] == '_')) end += 1;
    var buf: [16]u8 = undefined;
    var n: usize = 0;
    for (text[i..end]) |c| {
        if (c == '_') continue;
        if (n >= buf.len) return null;
        buf[n] = c;
        n += 1;
    }
    return std.fmt.parseInt(u32, buf[0..n], 10) catch null;
}

fn last_integer(text: []const u8) ?u32 {
    var best: ?u32 = null;
    var i: usize = 0;
    while (i < text.len) {
        if (!std.ascii.isDigit(text[i])) {
            i += 1;
            continue;
        }
        var end = i;
        while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
        best = std.fmt.parseInt(u32, text[i..end], 10) catch best;
        i = end;
    }
    return best;
}

/// A loop in application code. Brace languages close it by depth, Python by
/// indent. The region is resolved before anything is reported, because the
/// `sleep` that states the period usually sits BELOW the spawn it paces.
const CodeLoop = struct {
    header_line: usize,
    /// 1-based, inclusive.
    end_line: usize,
    /// Brace depth the body sits at, or the indent column for Python.
    body_level: usize,
    period_secs: ?u32 = null,
    parent: ?usize = null,
};

fn line_starts_loop(trimmed: []const u8, lang: models.Language) bool {
    const common = [_][]const u8{ "while ", "for ", "while(", "for(" };
    for (&common) |k| {
        if (std.mem.startsWith(u8, trimmed, k)) return true;
    }
    if (lang == .python) return false;
    // Rust's bare `loop`.
    if (std.mem.startsWith(u8, trimmed, "loop ") or std.mem.startsWith(u8, trimmed, "loop{")) return true;
    return false;
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

/// Pass 1: every loop region in the file, with the period it sleeps.
fn code_loops(allocator: std.mem.Allocator, lines: []const []const u8, lang: models.Language) ![]CodeLoop {
    var regions = std.ArrayList(CodeLoop).empty;
    errdefer regions.deinit(allocator);
    var open = std.ArrayList(usize).empty;
    defer open.deinit(allocator);

    var depth: isize = 0;
    for (lines, 0..) |raw, i| {
        const line_no = i + 1;
        const trimmed = std.mem.trimStart(u8, raw, " \t");

        // Close the regions this line left.
        if (lang == .python) {
            if (trimmed.len > 0) {
                const ind = indent_of(raw);
                while (open.items.len > 0 and ind <= regions.items[open.items[open.items.len - 1]].body_level) {
                    const top = open.pop().?;
                    regions.items[top].end_line = line_no - 1;
                }
            }
        } else {
            while (open.items.len > 0 and depth < @as(isize, @intCast(regions.items[open.items[open.items.len - 1]].body_level))) {
                const top = open.pop().?;
                regions.items[top].end_line = line_no - 1;
            }
        }

        // A sleep belongs to the innermost open loop.
        if (open.items.len > 0) {
            if (code_sleep_seconds(raw)) |secs| {
                const top = open.items[open.items.len - 1];
                if (regions.items[top].period_secs == null) regions.items[top].period_secs = secs;
            }
        }

        if (line_starts_loop(trimmed, lang)) {
            const body_level: usize = if (lang == .python)
                indent_of(raw)
            else
                @intCast(@max(@as(isize, 0), depth + brace_delta(raw)));
            const parent: ?usize = if (open.items.len > 0) open.items[open.items.len - 1] else null;
            try regions.append(allocator, .{
                .header_line = line_no,
                .end_line = lines.len,
                .body_level = body_level,
                .parent = parent,
            });
            try open.append(allocator, regions.items.len - 1);
        }
        if (lang != .python) depth += brace_delta(raw);
    }

    // Inherit the period from the nearest enclosing loop that states one.
    for (regions.items) |*r| {
        if (r.period_secs != null) continue;
        var p = r.parent;
        while (p) |pi| {
            if (regions.items[pi].period_secs) |secs| {
                r.period_secs = secs;
                break;
            }
            p = regions.items[pi].parent;
        }
    }
    return regions.toOwnedSlice(allocator);
}

/// The innermost region containing `line`.
fn enclosing_code_loop(regions: []const CodeLoop, line: usize) ?usize {
    var best: ?usize = null;
    for (regions, 0..) |r, i| {
        if (line <= r.header_line or line > r.end_line) continue;
        if (best == null or r.header_line > regions[best.?].header_line) best = i;
    }
    return best;
}

fn scan_code(
    allocator: std.mem.Allocator,
    outline: models.FileOutline,
    content: []const u8,
    findings: *std.ArrayList(Finding),
) !void {
    const lang = outline.language;
    const lines = try split_lines(allocator, content);
    defer allocator.free(lines);

    const regions = try code_loops(allocator, lines, lang);
    defer allocator.free(regions);

    for (lines, 0..) |raw, i| {
        const line_no = i + 1;
        const in_loop = enclosing_code_loop(regions, line_no);
        const timer = timer_period(raw);
        if (in_loop == null and timer == null) continue;

        for (&spawn_apis) |api| {
            if (!api_applies(api, lang)) continue;
            const at = std.mem.indexOf(u8, raw, api.text) orelse continue;
            const ri = program_runtime(raw, at + api.text.len) orelse continue;
            const period: ?u32 = if (timer) |t| t else regions[in_loop.?].period_secs;
            const per_hour: ?u32 = if (period) |p| @intCast(@max(@as(u32, 1), 3600 / p)) else null;
            try findings.append(allocator, .{
                .file = outline.path,
                .line = line_no,
                .command = runtimes[ri].command,
                .runtime = runtimes[ri].command,
                .language = runtimes[ri].language,
                .period_secs = period,
                .spawns_per_hour = per_hour,
                .cost_score = if (per_hour) |ph| @as(u64, runtimes[ri].startup_ms) * ph else 0,
                .loop_line = if (in_loop) |li| regions[li].header_line else line_no,
                .via = null,
                .long_lived_peer = null,
            });
            break;
        }
    }
}

/// A sleep in application code, in seconds.
fn code_sleep_seconds(line: []const u8) ?u32 {
    const secs_markers = [_][]const u8{ "from_secs(", "time.Sleep(", "sleep(" };
    const ms_markers = [_][]const u8{ "from_millis(", "setTimeout(" };
    for (&ms_markers) |m| {
        if (std.mem.indexOf(u8, line, m)) |idx| {
            if (first_integer(line[idx + m.len ..])) |ms| return @max(@as(u32, 1), ms / 1000);
        }
    }
    for (&secs_markers) |m| {
        if (std.mem.indexOf(u8, line, m)) |idx| {
            if (first_integer(line[idx + m.len ..])) |s| return @max(@as(u32, 1), s);
        }
    }
    return null;
}

// ── Entry point ──────────────────────────────────────────────────────────────

pub fn scan(allocator: std.mem.Allocator, exp: *explorer.Explorer) ![]Finding {
    var findings = std.ArrayList(Finding).empty;
    errdefer {
        for (findings.items) |f| {
            if (f.via) |v| allocator.free(v);
            if (f.long_lived_peer) |p| allocator.free(p);
        }
        findings.deinit(allocator);
    }

    var it = exp.outlines.iterator();
    while (it.next()) |entry| {
        const file_id = entry.key_ptr.*;
        if (exp.deleted_files.get(file_id) != null) continue;
        const outline = entry.value_ptr.*;
        if (is_excluded_path(outline.path)) continue;
        const content = exp.content_cache.get(file_id) orelse continue;

        switch (outline.language) {
            .bash => try scan_shell(allocator, outline, content, &findings),
            .dockerfile => try scan_dockerfile(allocator, outline, content, &findings),
            .rust, .typescript, .javascript, .python, .go => try scan_code(allocator, outline, content, &findings),
            else => {},
        }
    }

    // Costliest first: startup cost times spawn rate, exactly the ranking the
    // fault needs — a 15-second loop above an hourly one.
    const items = try findings.toOwnedSlice(allocator);
    std.mem.sort(Finding, items, {}, struct {
        fn less(_: void, a: Finding, b: Finding) bool {
            if (a.cost_score != b.cost_score) return a.cost_score > b.cost_score;
            return a.line < b.line;
        }
    }.less);
    return items;
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn one_bash_file(allocator: std.mem.Allocator, path: []const u8, src: []const u8, fn_defs: []const struct {
    name: []const u8,
    start0: usize,
    end0: usize,
}) !models.FileOutline {
    var syms = try allocator.alloc(models.Symbol, fn_defs.len);
    for (fn_defs, 0..) |d, i| {
        syms[i] = .{
            .name = try allocator.dupe(u8, d.name),
            .kind = .function,
            .line_start = d.start0,
            .line_end = d.end0,
        };
    }
    return .{
        .path = try allocator.dupe(u8, path),
        .language = .bash,
        .line_count = std.mem.count(u8, src, "\n") + 1,
        .byte_size = src.len,
        .symbols = syms,
        .imports = &[_][]const u8{},
    };
}

test "spawn_scan: the supervisor.sh fault, two hops from the loop" {
    const allocator = testing.allocator;
    // Line numbers are 1-based in the comments, 0-based in the symbol ranges.
    const src =
        \\#!/usr/bin/env bash
        \\POLL_SECS="${POLL_SECS:-15}"
        \\s3() { aws --endpoint-url "$S3_ENDPOINT" s3 "$@"; }
        \\start_server() {
        \\  node "$APP_SERVER" &
        \\  SERVER_PID=$!
        \\}
        \\sync_app() {
        \\  local app="$1"
        \\  local sha; sha="$(s3 cp "${prefix%/}/DEPLOYED_SHA" - 2>/dev/null)"
        \\}
        \\start_server
        \\while true; do
        \\  for d in "$APPS_ROOT"/*/; do
        \\    sync_app "$(basename "$d")"
        \\  done
        \\  sleep "$POLL_SECS"
        \\done
        \\
    ;
    var exp = try explorer.Explorer.init(allocator);
    defer exp.deinit();
    const outline = try one_bash_file(allocator, "deploy/supervisor.sh", src, &.{
        .{ .name = "s3", .start0 = 2, .end0 = 2 },
        .{ .name = "start_server", .start0 = 3, .end0 = 6 },
        .{ .name = "sync_app", .start0 = 7, .end0 = 10 },
    });
    _ = try exp.add_file(outline, src);
    exp.mark_indexing_complete();

    const findings = try scan(allocator, &exp);
    defer free_findings(allocator, findings);

    try testing.expectEqual(@as(usize, 1), findings.len);
    const f = findings[0];
    // The call site, not the wrapper definition.
    try testing.expectEqual(@as(usize, 10), f.line);
    try testing.expectEqualStrings("aws", f.runtime);
    try testing.expectEqualStrings("python", f.language);
    try testing.expectEqual(@as(?u32, 15), f.period_secs);
    try testing.expectEqual(@as(?u32, 240), f.spawns_per_hour);
    try testing.expectEqual(@as(usize, 13), f.loop_line);
    try testing.expectEqualStrings("s3", f.via.?);
    try testing.expect(f.long_lived_peer != null);
    try testing.expect(std.mem.indexOf(u8, f.long_lived_peer.?, "node") != null);
}

test "spawn_scan: a one-shot script reports nothing" {
    const allocator = testing.allocator;
    const src =
        \\#!/usr/bin/env bash
        \\aws s3 cp s3://bucket/key -
        \\python3 build.py
        \\
    ;
    var exp = try explorer.Explorer.init(allocator);
    defer exp.deinit();
    const outline = try one_bash_file(allocator, "scripts/publish.sh", src, &.{});
    _ = try exp.add_file(outline, src);
    exp.mark_indexing_complete();

    const findings = try scan(allocator, &exp);
    defer free_findings(allocator, findings);
    try testing.expectEqual(@as(usize, 0), findings.len);
}

test "spawn_scan: ranks a 15-second loop above an hourly one" {
    const allocator = testing.allocator;
    const fast =
        \\#!/usr/bin/env bash
        \\while true; do
        \\  aws s3 ls
        \\  sleep 15
        \\done
        \\
    ;
    const slow =
        \\#!/usr/bin/env bash
        \\while true; do
        \\  aws s3 ls
        \\  sleep 3600
        \\done
        \\
    ;
    var exp = try explorer.Explorer.init(allocator);
    defer exp.deinit();
    _ = try exp.add_file(try one_bash_file(allocator, "a/hourly.sh", slow, &.{}), slow);
    _ = try exp.add_file(try one_bash_file(allocator, "a/fast.sh", fast, &.{}), fast);
    exp.mark_indexing_complete();

    const findings = try scan(allocator, &exp);
    defer free_findings(allocator, findings);
    try testing.expectEqual(@as(usize, 2), findings.len);
    try testing.expectEqualStrings("a/fast.sh", findings[0].file);
    try testing.expectEqual(@as(?u32, 15), findings[0].period_secs);
    try testing.expectEqual(@as(?u32, 3600), findings[1].period_secs);
    try testing.expect(findings[0].cost_score > findings[1].cost_score);
}

test "spawn_scan: a test script is out of scope" {
    const allocator = testing.allocator;
    const src =
        \\#!/usr/bin/env bash
        \\while true; do
        \\  python3 check.py
        \\  sleep 1
        \\done
        \\
    ;
    var exp = try explorer.Explorer.init(allocator);
    defer exp.deinit();
    _ = try exp.add_file(try one_bash_file(allocator, "tests/loop.sh", src, &.{}), src);
    exp.mark_indexing_complete();
    const findings = try scan(allocator, &exp);
    defer free_findings(allocator, findings);
    try testing.expectEqual(@as(usize, 0), findings.len);
}

test "spawn_scan: Rust Command::new inside a loop" {
    const allocator = testing.allocator;
    const src =
        \\pub async fn poll() {
        \\    loop {
        \\        let out = Command::new("aws").arg("s3").output().unwrap();
        \\        tokio::time::sleep(Duration::from_secs(30)).await;
        \\    }
        \\}
        \\
    ;
    var exp = try explorer.Explorer.init(allocator);
    defer exp.deinit();
    _ = try exp.add_file(.{
        .path = try allocator.dupe(u8, "src/poll.rs"),
        .language = .rust,
        .line_count = 6,
        .byte_size = src.len,
        .symbols = &[_]models.Symbol{},
        .imports = &[_][]const u8{},
    }, src);
    exp.mark_indexing_complete();

    const findings = try scan(allocator, &exp);
    defer free_findings(allocator, findings);
    try testing.expectEqual(@as(usize, 1), findings.len);
    try testing.expectEqual(@as(usize, 3), findings[0].line);
    try testing.expectEqualStrings("aws", findings[0].runtime);
    try testing.expectEqual(@as(?u32, 30), findings[0].period_secs);
}

test "spawn_scan: Dockerfile HEALTHCHECK on an interpreter" {
    const allocator = testing.allocator;
    const src =
        \\FROM alpine
        \\CMD ["/usr/local/bin/app-server"]
        \\HEALTHCHECK --interval=10s CMD python3 /healthcheck.py
        \\
    ;
    var exp = try explorer.Explorer.init(allocator);
    defer exp.deinit();
    _ = try exp.add_file(.{
        .path = try allocator.dupe(u8, "Dockerfile"),
        .language = .dockerfile,
        .line_count = 3,
        .byte_size = src.len,
        .symbols = &[_]models.Symbol{},
        .imports = &[_][]const u8{},
    }, src);
    exp.mark_indexing_complete();

    const findings = try scan(allocator, &exp);
    defer free_findings(allocator, findings);
    try testing.expectEqual(@as(usize, 1), findings.len);
    try testing.expectEqual(@as(?u32, 10), findings[0].period_secs);
    try testing.expectEqualStrings("python3", findings[0].runtime);
    try testing.expect(findings[0].long_lived_peer != null);
}

test "spawn_scan: sleep resolves a variable default" {
    const lines = [_][]const u8{
        "POLL_SECS=\"${POLL_SECS:-15}\"",
        "sleep \"$POLL_SECS\"",
    };
    try testing.expectEqual(@as(?u32, 15), sleep_seconds(lines[1], &lines));
    const direct = [_][]const u8{"sleep 45"};
    try testing.expectEqual(@as(?u32, 45), sleep_seconds(direct[0], &direct));
    // A sub-second sleep must not score as free.
    const sub = [_][]const u8{"sleep 0.5"};
    try testing.expectEqual(@as(?u32, 1), sleep_seconds(sub[0], &sub));
}

test "spawn_scan: a deploy script walking a list is not a timer" {
    const allocator = testing.allocator;
    // A bounded `for` in a one-shot deploy script. Six of these came back as
    // findings before the loop had to prove it repeats.
    const src =
        \\#!/usr/bin/env bash
        \\for svc in api web worker; do
        \\  python3 tools/render.py "$svc"
        \\  npm run build --workspace "$svc"
        \\done
        \\
    ;
    var exp = try explorer.Explorer.init(allocator);
    defer exp.deinit();
    _ = try exp.add_file(try one_bash_file(allocator, "scripts/deploy-local.sh", src, &.{}), src);
    exp.mark_indexing_complete();

    const findings = try scan(allocator, &exp);
    defer free_findings(allocator, findings);
    try testing.expectEqual(@as(usize, 0), findings.len);
}

test "spawn_scan: a `while true` with no sleep still repeats" {
    const allocator = testing.allocator;
    const src =
        \\#!/usr/bin/env bash
        \\while true; do
        \\  python3 poll.py
        \\done
        \\
    ;
    var exp = try explorer.Explorer.init(allocator);
    defer exp.deinit();
    _ = try exp.add_file(try one_bash_file(allocator, "bin/spin.sh", src, &.{}), src);
    exp.mark_indexing_complete();

    const findings = try scan(allocator, &exp);
    defer free_findings(allocator, findings);
    try testing.expectEqual(@as(usize, 1), findings.len);
    try testing.expectEqual(@as(?u32, null), findings[0].period_secs);
}

test "spawn_scan: a leading assignment is not the command" {
    const allocator = testing.allocator;
    var words = std.ArrayList(CmdWord).empty;
    defer words.deinit(allocator);
    try command_words(allocator, "  MUNBOT_APPS_ROOT=\"$APPS_ROOT\" PORT=\"${PORT:-8080}\" node \"$APP_SERVER\" &", &words);
    try testing.expectEqual(@as(usize, 1), words.items.len);
    try testing.expectEqualStrings("node", words.items[0].word);

    words.clearRetainingCapacity();
    try command_words(allocator, "  local sha; sha=\"$(s3 cp \"${prefix%/}/DEPLOYED_SHA\" - 2>/dev/null | tr -d x)\"", &words);
    var saw_s3 = false;
    for (words.items) |w| {
        if (std.mem.eql(u8, w.word, "s3")) saw_s3 = true;
    }
    try testing.expect(saw_s3);
}

test "spawn_scan: `echo do` does not open a loop" {
    const allocator = testing.allocator;
    const lines = [_][]const u8{
        "echo do",
        "aws s3 ls",
        "echo done",
    };
    const regions = try shell_loops(allocator, &lines);
    defer allocator.free(regions);
    try testing.expectEqual(@as(usize, 0), regions.len);
}

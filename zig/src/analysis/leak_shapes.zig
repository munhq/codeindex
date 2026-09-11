//! Shapes that a leak has. Not leaks.
//!
//! A leak is a runtime fact: memory that rises and does not come back. Static
//! analysis cannot see that. What it can see is the shape — a container that
//! only ever grows, an allocation handed to `Box::leak`, a queue with no bound —
//! and a shape with a flat memory series is a false positive.
//!
//! So every finding here carries `runtime_check`: the series that decides it.
//! Pair the shape with that series before acting. Without the pairing this
//! detector argues instead of reporting.
//!
//! `growing_container` covers two scopes. A container bound at file scope has
//! one owner and one lifetime, so one file settles it. A container declared as
//! a STRUCT FIELD is the one that leaks in production — `sessions:
//! Mutex<HashMap<String, SessionEntry>>` on an object that lives for the
//! process — and it is decidable for a different reason: the field name is
//! written at every use, so the uses can be found without resolving types. See
//! the struct-field section below for what separates a leak from a load.
//!
//! Call frequency is runtime, so a finding states that the container grows and
//! that nothing removes from it, and leaves how often to the `runtime_check`.
//! `unbounded_channel` reports the construction and names the queue-depth
//! series that settles it.

const std = @import("std");
const explorer = @import("../index/explorer.zig");
const models = @import("../core/models.zig");

pub const Shape = enum {
    /// An allocation deliberately given up: `Box::leak`, `mem::forget`.
    leaked_allocation,
    /// A container at file scope that grows and never shrinks.
    growing_container,
    /// A cache with no capacity and no expiry.
    unbounded_cache,
    /// A queue with no bound.
    unbounded_channel,
    /// A task started inside a loop whose handle nobody keeps.
    detached_spawn_in_loop,

    pub fn as_str(self: Shape) []const u8 {
        return switch (self) {
            .leaked_allocation => "leaked_allocation",
            .growing_container => "growing_container",
            .unbounded_cache => "unbounded_cache",
            .unbounded_channel => "unbounded_channel",
            .detached_spawn_in_loop => "detached_spawn_in_loop",
        };
    }

    /// The series that turns this shape into a finding or into a false positive.
    pub fn runtime_check(self: Shape) []const u8 {
        return switch (self) {
            .leaked_allocation => "resident memory per process: a rising series confirms it, a flat one does not",
            .growing_container => "resident memory per process: a rising series confirms it, a flat one does not",
            .unbounded_cache => "cache entry count over time, against the resident memory series",
            .unbounded_channel => "queue depth over time: a depth that returns to zero is a false positive",
            .detached_spawn_in_loop => "live task or thread count over time",
        };
    }
};

pub const Finding = struct {
    file: []const u8,
    line: usize,
    shape: Shape,
    /// The name the shape hangs on, when there is one. Owned.
    subject: ?[]const u8,
    /// The line that shows the shape. Owned.
    evidence: []const u8,
};

pub const Summary = struct {
    total: usize,
    leaked_allocation: usize,
    growing_container: usize,
    unbounded_cache: usize,
    unbounded_channel: usize,
    detached_spawn_in_loop: usize,
};

pub fn summarize(findings: []const Finding) Summary {
    var s = Summary{
        .total = findings.len,
        .leaked_allocation = 0,
        .growing_container = 0,
        .unbounded_cache = 0,
        .unbounded_channel = 0,
        .detached_spawn_in_loop = 0,
    };
    for (findings) |f| {
        switch (f.shape) {
            .leaked_allocation => s.leaked_allocation += 1,
            .growing_container => s.growing_container += 1,
            .unbounded_cache => s.unbounded_cache += 1,
            .unbounded_channel => s.unbounded_channel += 1,
            .detached_spawn_in_loop => s.detached_spawn_in_loop += 1,
        }
    }
    return s;
}

pub fn free_findings(allocator: std.mem.Allocator, findings: []Finding) void {
    for (findings) |f| {
        if (f.subject) |s| allocator.free(s);
        allocator.free(f.evidence);
    }
    allocator.free(findings);
}

// ── Scope ────────────────────────────────────────────────────────────────────

/// A test holds a container for the length of one test, and a benchmark leaks
/// on purpose to keep an allocation out of the measurement.
///
/// A build or report script is excluded for the same reason: a container that
/// only grows matters in a process that runs long enough for the growth to
/// matter, and a script accumulates into a list and then exits. Six such
/// accumulators in `scripts/*.py` were the whole output of a self-scan.
fn is_excluded_path(path: []const u8) bool {
    const dirs = [_][]const u8{
        "test",         "tests",  "spec",   "benches",  "bench",    "examples", "example",
        "node_modules", "vendor", "target", "testdata", "fixtures", "scripts",  "script",
        "tools",        "hack",   "ci",     "build",
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

fn trimmed_line(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t\r");
}

fn is_comment(t: []const u8, lang: models.Language) bool {
    if (std.mem.startsWith(u8, t, "//")) return true;
    if (std.mem.startsWith(u8, t, "/*")) return true;
    if (std.mem.startsWith(u8, t, "*")) return true;
    if (lang == .python and std.mem.startsWith(u8, t, "#")) return true;
    return false;
}

fn ident_char(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn contains_any(hay: []const u8, needles: []const []const u8) bool {
    for (needles) |n| {
        if (std.mem.indexOf(u8, hay, n) != null) return true;
    }
    return false;
}

fn contains_any_ci(hay: []const u8, needles: []const []const u8) bool {
    for (needles) |n| {
        if (std.ascii.indexOfIgnoreCase(hay, n) != null) return true;
    }
    return false;
}

// ── Shape: a leaked allocation ───────────────────────────────────────────────

const leak_calls = [_][]const u8{
    "Box::leak(",         "mem::forget(",       "std::mem::forget(", "Box::into_raw(",
    "CString::into_raw(", "ManuallyDrop::new(",
};

/// `Box::into_raw` is only a leak when nothing takes the pointer back.
const leak_undo = [_][]const u8{
    "from_raw(", "ManuallyDrop::drop(", "ManuallyDrop::into_inner(", "drop_in_place(",
};

// ── Shape: a container at file scope that only grows ─────────────────────────

const container_types = [_][]const u8{
    "Vec<",     "VecDeque<", "HashMap<",     "HashSet<", "BTreeMap<", "BTreeSet<", "IndexMap<",
    "new Map(", "new Set(",  "new WeakMap(",
};

const grow_ops = [_][]const u8{
    ".push(", ".insert(", ".push_back(",  ".extend(", ".append(", ".add(",
    ".set(",  ".entry(",  ".push_front(", ".put(",
};

const shrink_ops = [_][]const u8{
    ".remove(",   ".clear(", ".retain(",      ".pop(",     ".pop_front(", ".pop_back(",
    ".truncate(", ".drain(", ".delete(",      ".splice(",  ".shift(",     ".take(",
    ".evict(",    ".prune(", ".swap_remove(", ".discard(",
};

/// Markers that make a container bounded, so it cannot grow without limit.
const bound_markers = [_][]const u8{
    "ttl",         "expire",  "expiry", "evict",   "capacity",      "max_size",     "maxsize",
    "max_entries", "max_len", "lru",    "bounded", "with_capacity", "time_to_live",
};

/// A file-scope binding of a growable container: `static`, `lazy_static!`, a
/// `OnceLock`, or a module-level `const` in TypeScript.
fn file_scope_container(t: []const u8, raw: []const u8, lang: models.Language) ?[]const u8 {
    switch (lang) {
        .rust => {
            const at_scope = std.mem.startsWith(u8, raw, "static ") or
                std.mem.startsWith(u8, raw, "pub static ") or
                std.mem.startsWith(u8, raw, "pub(crate) static ") or
                std.mem.indexOf(u8, t, "lazy_static!") != null;
            if (!at_scope) return null;
            if (!contains_any(t, &container_types)) return null;
            return binding_name(t, "static ");
        },
        .typescript, .javascript => {
            // Column zero is module scope; anything indented is inside a body.
            if (raw.len == 0 or raw[0] == ' ' or raw[0] == '\t') return null;
            const at_scope = std.mem.startsWith(u8, t, "const ") or
                std.mem.startsWith(u8, t, "export const ") or
                std.mem.startsWith(u8, t, "let ");
            if (!at_scope) return null;
            if (!contains_any(t, &container_types)) return null;
            return binding_name(t, "const ");
        },
        .python => {
            if (raw.len == 0 or raw[0] == ' ' or raw[0] == '\t') return null;
            const eq = std.mem.indexOfScalar(u8, t, '=') orelse return null;
            const value = std.mem.trim(u8, t[eq + 1 ..], " \t");
            const is_container = std.mem.startsWith(u8, value, "{}") or
                std.mem.startsWith(u8, value, "[]") or
                std.mem.startsWith(u8, value, "dict(") or
                std.mem.startsWith(u8, value, "list(") or
                std.mem.startsWith(u8, value, "set(") or
                std.mem.startsWith(u8, value, "defaultdict(");
            if (!is_container) return null;
            const name = std.mem.trim(u8, t[0..eq], " \t:");
            if (name.len == 0) return null;
            for (name) |c| {
                if (!ident_char(c)) return null;
            }
            return name;
        },
        else => return null,
    }
}

/// The identifier a binding line declares.
fn binding_name(t: []const u8, keyword: []const u8) ?[]const u8 {
    const kw = std.mem.indexOf(u8, t, keyword) orelse return null;
    var rest = t[kw + keyword.len ..];
    rest = std.mem.trimStart(u8, rest, " \t");
    var end: usize = 0;
    while (end < rest.len and ident_char(rest[end])) end += 1;
    if (end == 0) return null;
    return rest[0..end];
}

/// Whether the file ever shrinks `name`. A shrink anywhere clears the shape:
/// a file-scope container has one owner, so one removal is enough to say the
/// code knows the container is not append-only.
fn file_shrinks(content: []const u8, name: []const u8) bool {
    var rebinds: usize = 0;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        const idx = std.mem.indexOf(u8, line, name) orelse continue;
        const before_ok = idx == 0 or !ident_char(line[idx - 1]);
        if (!before_ok) continue;
        const rest = line[idx + name.len ..];
        if (contains_any(rest, &shrink_ops)) return true;
        // Python: `del CACHE[k]`, `CACHE.pop(k)`.
        if (std.mem.indexOf(u8, line, "del ") != null) return true;
        // A second binding of the same file-scope name replaces the container,
        // which resets it: `nodes=set()` … `nodes=set()`.
        if (idx == 0 and rest.len > 0 and rest[0] == '=' and
            (rest.len < 2 or rest[1] != '=')) rebinds += 1;
    }
    return rebinds > 1;
}

/// Whether anything bounds `name`: a capacity, a TTL, an eviction pass.
///
/// The marker has to appear on a line that names the container. A file-wide
/// search read the word "expires" out of a doc comment about a probe window and
/// silenced every container in the file.
fn container_is_bounded(content: []const u8, name: []const u8, declaration: []const u8) bool {
    if (contains_any_ci(declaration, &bound_markers)) return true;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (is_comment(t, .rust) or std.mem.startsWith(u8, t, "#")) continue;
        const idx = std.mem.indexOf(u8, t, name) orelse continue;
        const before_ok = idx == 0 or !ident_char(t[idx - 1]);
        if (!before_ok) continue;
        if (contains_any_ci(t, &bound_markers)) return true;
    }
    return false;
}

fn file_grows(content: []const u8, name: []const u8) ?usize {
    var line_no: usize = 0;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        line_no += 1;
        const idx = std.mem.indexOf(u8, line, name) orelse continue;
        const before_ok = idx == 0 or !ident_char(line[idx - 1]);
        if (!before_ok) continue;
        const rest = line[idx + name.len ..];
        if (contains_any(rest, &grow_ops)) return line_no;
        // `MAP[key] = value` grows a Python dict and a JS object alike.
        if (rest.len > 0 and rest[0] == '[') {
            if (std.mem.indexOfScalar(u8, rest, '=') != null and
                std.mem.indexOf(u8, rest, "==") == null) return line_no;
        }
    }
    return null;
}

// ── Shape: a struct field that only grows ────────────────────────────────────
//
// The container that leaks in production is rarely a `static`. It is a field:
// `sessions: Mutex<HashMap<String, SessionEntry>>` on a struct that lives for
// the process. One repository holds about forty of them.
//
// Two things make the field decidable where a free local is not. The field name
// is written at every use — `self.sessions`, `tracker.tasks` — so the uses can
// be found without resolving types. And the field has one owner, so a single
// removal anywhere in the owner's methods settles the question.
//
// The lock guard is what a naive scan gets wrong. The dominant Rust shape is
//
//     let mut cache = self.cached_codes.lock();
//     cache.retain(|_, expiry| *expiry >= now_secs);
//
// where the removal lands on the guard, not on the field. Without the alias
// below, every `Mutex<HashMap>` field in the tree reports as growing.

/// A container declared as a field of a struct or a class.
const FieldDecl = struct {
    file_id: u32,
    /// Borrowed from the outline.
    file: []const u8,
    lang: models.Language,
    /// The struct or class that declares it. Borrowed from the content.
    owner: []const u8,
    /// The field name. Borrowed from the content.
    name: []const u8,
    /// 1-based declaration line.
    line: usize,
    /// The declaration line, for the bound check. Borrowed.
    decl: []const u8,
    /// Two structs in one file declare this name, so `self.<name>` does not say
    /// which. Skipped rather than guessed.
    ambiguous: bool = false,
};

/// The name a `struct` / `class` / `type … struct` header declares.
fn struct_header(t: []const u8, lang: models.Language) ?[]const u8 {
    const keywords: []const []const u8 = switch (lang) {
        .rust => &.{ "struct ", "pub struct ", "pub(crate) struct " },
        .go => &.{"type "},
        .typescript, .javascript => &.{ "class ", "export class ", "export default class ", "abstract class ", "export abstract class " },
        .python => &.{"class "},
        else => return null,
    };
    for (keywords) |kw| {
        if (!std.mem.startsWith(u8, t, kw)) continue;
        var rest = std.mem.trimStart(u8, t[kw.len..], " \t");
        var end: usize = 0;
        while (end < rest.len and ident_char(rest[end])) end += 1;
        if (end == 0) return null;
        const name = rest[0..end];
        switch (lang) {
            // `type Alias = …` is not a struct; `type X struct {` is.
            .go => if (std.mem.indexOf(u8, t, " struct {") == null) return null,
            // A tuple struct and a unit struct have no named fields.
            .rust => if (std.mem.indexOfScalar(u8, t, '{') == null) return null,
            .python => if (std.mem.indexOfScalar(u8, t, ':') == null) return null,
            else => {},
        }
        return name;
    }
    return null;
}

/// Container types that already carry a bound, so a field of one cannot grow
/// without limit however many inserts it sees.
const bounded_types = [_][]const u8{
    "LruCache",   "TtlCache",       "MokaCache", "Cache<", "ArrayVec", "BoundedVec",
    "RingBuffer", "CircularBuffer", "SmallVec",
};

/// The name of a container field declared on this line.
fn field_declaration(t: []const u8, lang: models.Language) ?[]const u8 {
    if (t.len == 0 or t[0] == '}' or t[0] == '#' or t[0] == '/') return null;
    if (contains_any(t, &bounded_types)) return null;

    switch (lang) {
        .rust => {
            var rest = t;
            const visibility = [_][]const u8{ "pub(crate) ", "pub(super) ", "pub ", "pub(in crate) " };
            for (&visibility) |v| {
                if (std.mem.startsWith(u8, rest, v)) {
                    rest = rest[v.len..];
                    break;
                }
            }
            const colon = std.mem.indexOfScalar(u8, rest, ':') orelse return null;
            if (colon + 1 < rest.len and rest[colon + 1] == ':') return null;
            const name = std.mem.trim(u8, rest[0..colon], " \t");
            if (!is_plain_ident(name)) return null;
            if (!contains_any(rest[colon..], &container_types)) return null;
            return name;
        },
        .go => {
            // `clients map[string]*Client` / `seen []string`
            var it = std.mem.tokenizeAny(u8, t, " \t");
            const name = it.next() orelse return null;
            if (!is_plain_ident(name)) return null;
            const rest = it.rest();
            if (std.mem.indexOf(u8, rest, "map[") == null and
                !std.mem.startsWith(u8, std.mem.trimStart(u8, rest, " \t*"), "[]")) return null;
            return name;
        },
        .typescript, .javascript => {
            var rest = t;
            const modifiers = [_][]const u8{ "private ", "public ", "protected ", "readonly ", "static " };
            var changed = true;
            while (changed) {
                changed = false;
                for (&modifiers) |m| {
                    if (std.mem.startsWith(u8, rest, m)) {
                        rest = rest[m.len..];
                        changed = true;
                    }
                }
            }
            // `new Map(` misses the common `new Map<string, Session>()`, so the
            // generic spellings are listed too.
            const ts_containers = [_][]const u8{
                "new Map", "new Set",  "new WeakMap", "Map<", "Set<",
                "Record<", "Array<",   "= []",        "= {}", "[] =",
                "[];",     "WeakMap<",
            };
            if (!contains_any(rest, &ts_containers)) return null;
            const stop = std.mem.indexOfAny(u8, rest, ":=?") orelse return null;
            const name = std.mem.trim(u8, rest[0..stop], " \t");
            if (!is_plain_ident(name)) return null;
            return name;
        },
        else => return null,
    }
}

/// `self.<name> = {}` inside a class body. Python declares its fields by
/// assigning them, so there is no field list to read.
fn python_field_declaration(t: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, t, "self.")) return null;
    const eq = std.mem.indexOfScalar(u8, t, '=') orelse return null;
    if (eq + 1 < t.len and t[eq + 1] == '=') return null;
    const value = std.mem.trim(u8, t[eq + 1 ..], " \t");
    const containers = [_][]const u8{ "{}", "[]", "dict(", "list(", "set(", "defaultdict(", "OrderedDict(" };
    var is_container = false;
    for (&containers) |c| {
        if (std.mem.startsWith(u8, value, c)) is_container = true;
    }
    if (!is_container) return null;
    const name = std.mem.trim(u8, t["self.".len..eq], " \t:");
    if (!is_plain_ident(name)) return null;
    return name;
}

fn is_plain_ident(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.ascii.isDigit(name[0])) return false;
    for (name) |c| {
        if (!ident_char(c)) return false;
    }
    return true;
}

/// Collect the container fields every struct in one file declares.
///
/// A struct inside a `#[cfg(test)] mod` is skipped: a test mock accumulates for
/// the length of one test and then goes away.
fn collect_field_decls(
    allocator: std.mem.Allocator,
    file_id: u32,
    outline: models.FileOutline,
    content: []const u8,
    out: *std.ArrayList(FieldDecl),
) !void {
    const lang = outline.language;
    const first = out.items.len;

    var depth: isize = 0;
    var owner: ?[]const u8 = null;
    var owner_depth: isize = 0;
    var owner_indent: usize = 0;
    var cfg_test_depth: ?isize = null;
    var pending_cfg_test = false;

    var line_no: usize = 0;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |raw| {
        line_no += 1;
        const t = trimmed_line(raw);
        const delta = if (lang == .python) 0 else brace_delta(raw);
        defer depth += delta;
        if (t.len == 0 or is_comment(t, lang)) continue;

        // A `#[cfg(test)]` module ends where its brace does.
        if (cfg_test_depth) |opened| {
            if (depth <= opened) cfg_test_depth = null;
        }
        if (std.mem.indexOf(u8, t, "#[cfg(test)]") != null) {
            pending_cfg_test = true;
            continue;
        }
        if (pending_cfg_test) {
            pending_cfg_test = false;
            if (cfg_test_depth == null) cfg_test_depth = depth;
        }
        if (cfg_test_depth != null) continue;

        // Close the container this line left.
        if (owner != null) {
            const left = if (lang == .python)
                (t.len > 0 and indent_of(raw) <= owner_indent)
            else
                depth <= owner_depth;
            if (left) owner = null;
        }

        if (owner == null) {
            if (struct_header(t, lang)) |name| {
                owner = name;
                owner_depth = depth;
                owner_indent = indent_of(raw);
            }
            continue;
        }

        const name = if (lang == .python)
            python_field_declaration(t)
        else
            field_declaration(t, lang);
        if (name) |n| {
            try out.append(allocator, .{
                .file_id = file_id,
                .file = outline.path,
                .lang = lang,
                .owner = owner.?,
                .name = n,
                .line = line_no,
                .decl = t,
            });
        }
    }

    // Within one file, two structs sharing a field name make `self.<name>`
    // undecidable. Mark both rather than pick one.
    var i = first;
    while (i < out.items.len) : (i += 1) {
        var j = i + 1;
        while (j < out.items.len) : (j += 1) {
            if (!std.mem.eql(u8, out.items[i].name, out.items[j].name)) continue;
            if (std.mem.eql(u8, out.items[i].owner, out.items[j].owner)) continue;
            out.items[i].ambiguous = true;
            out.items[j].ambiguous = true;
        }
    }
}

/// What a file does to one field.
const FieldUse = struct {
    grow_line: ?usize = null,
    shrinks: bool = false,
};

/// Whether a growth site sits in a method the owner exposes, or in code that
/// fills the container once while building it.
///
/// This is the difference between a leak and a load. Measured over one
/// repository, every container that really grows without limit grew inside a
/// method with a `&self` receiver — `resolve`, `record_event`, `spawn`,
/// `try_pair`, `engage`. Every false positive grew somewhere else:
///
///   - `RoleRegistry::from_config(&[…]) -> Result<Self>` fills a local registry
///     from a configuration list. It grows once per registry, not per request.
///   - `ValidationResult::merge(mut self, other) -> Self` takes `self` by value.
///     That is a builder, and the value it returns has the lifetime of a call.
///   - `Batch` accumulates inside a free `start(config, bus)` function.
///
/// So a growth counts only inside a method that borrows its receiver. A
/// constructor has no receiver. A builder consumes one.
const MethodScope = struct {
    in_signature: bool = false,
    /// `&self`, `&mut self`, `def f(self, …)`, `func (r *T) …`.
    borrows_receiver: bool = false,
    /// `fn f(mut self) -> Self` — the object ends with the call.
    consumes_receiver: bool = false,
    is_constructor: bool = false,

    fn counts(self: MethodScope) bool {
        return self.borrows_receiver and !self.consumes_receiver and !self.is_constructor;
    }
};

/// The name of the function a line starts, if it starts one.
fn fn_start(t: []const u8, lang: models.Language) ?[]const u8 {
    const keyword: []const u8 = switch (lang) {
        .rust => "fn ",
        .python => "def ",
        .go => "func ",
        .typescript, .javascript => "function ",
        else => return null,
    };
    const idx = std.mem.indexOf(u8, t, keyword) orelse {
        // A Go method reads `func (r *T) Name(`; the keyword match above covers
        // it. A TypeScript class method has no keyword at all, and TS is judged
        // by the receiver chain instead.
        return null;
    };
    if (idx > 0 and ident_char(t[idx - 1])) return null;
    var rest = std.mem.trimStart(u8, t[idx + keyword.len ..], " \t");
    // Skip a Go receiver: `func (r *T) Name(`.
    if (rest.len > 0 and rest[0] == '(') {
        const close = std.mem.indexOfScalar(u8, rest, ')') orelse return null;
        rest = std.mem.trimStart(u8, rest[close + 1 ..], " \t");
    }
    var end: usize = 0;
    while (end < rest.len and ident_char(rest[end])) end += 1;
    if (end == 0) return null;
    return rest[0..end];
}

/// The receiver on a Rust signature line, and whether the object survives the
/// call.
///
/// `&self` and `&mut self` are the common spellings, but an arbitrary self type
/// is a receiver too. `self: &Arc<Self>` is how a task tracker spawns work from
/// a shared handle, and reading only `&self` lost that finding.
fn rust_receiver(t: []const u8) ?struct { borrows: bool } {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, t, from, "self")) |idx| {
        from = idx + "self".len;
        if (idx > 0 and (ident_char(t[idx - 1]) or t[idx - 1] == '.')) continue;
        if (from < t.len and ident_char(t[from])) continue;

        // Step back over `&`, `mut` and spaces. A receiver opens the parameter
        // list or the line; anything else is an ordinary parameter.
        var k = idx;
        var saw_ref = false;
        while (k > 0) {
            const c = t[k - 1];
            if (c == ' ' or c == '\t') {
                k -= 1;
                continue;
            }
            if (c == '&') {
                saw_ref = true;
                k -= 1;
                continue;
            }
            // `mut`, as a whole word. Matching the literal "mut " fails here:
            // the space before it is already eaten, so `&mut self` never
            // matched and every `&mut self` method looked like a free function.
            if (k >= 3 and std.mem.eql(u8, t[k - 3 .. k], "mut")) {
                const before: u8 = if (k >= 4) t[k - 4] else '(';
                if (!ident_char(before)) {
                    k -= 3;
                    continue;
                }
            }
            break;
        }
        if (!(k == 0 or t[k - 1] == '(' or t[k - 1] == ',')) continue;

        // The declared type says whether the caller keeps the object.
        var end = from;
        while (end < t.len and t[end] != ',' and t[end] != ')') end += 1;
        const ty = t[from..end];
        const survives = saw_ref or
            std.mem.indexOfScalar(u8, ty, '&') != null or
            std.mem.indexOf(u8, ty, "Arc<") != null or
            std.mem.indexOf(u8, ty, "Rc<") != null or
            std.mem.indexOf(u8, ty, "Pin<") != null;
        return .{ .borrows = survives };
    }
    return null;
}

/// Update the signature flags from one line of a function signature. A Rust
/// signature often wraps, and `&self` then sits on its own line below `fn`.
fn read_signature_line(scope: *MethodScope, t: []const u8, lang: models.Language) void {
    switch (lang) {
        .rust => {
            if (rust_receiver(t)) |r| {
                scope.borrows_receiver = true;
                scope.consumes_receiver = !r.borrows;
            }
        },
        .python => {
            if (std.mem.indexOf(u8, t, "(self") != null or
                std.mem.indexOf(u8, t, ", self") != null) scope.borrows_receiver = true;
        },
        .go => {
            // `func (r *Registry) Add(` — a non-empty receiver list.
            const f = std.mem.indexOf(u8, t, "func (") orelse return;
            const rest = t[f + "func (".len ..];
            const close = std.mem.indexOfScalar(u8, rest, ')') orelse return;
            if (std.mem.trim(u8, rest[0..close], " \t").len > 0) scope.borrows_receiver = true;
        },
        else => {},
    }
}

fn signature_ends(t: []const u8, lang: models.Language) bool {
    return switch (lang) {
        .python => std.mem.indexOfScalar(u8, t, ':') != null,
        else => std.mem.indexOfScalar(u8, t, '{') != null or std.mem.endsWith(u8, t, ";"),
    };
}

fn is_constructor_name(name: []const u8) bool {
    return std.mem.eql(u8, name, "__init__") or std.mem.eql(u8, name, "constructor");
}

/// The identifier a receiver chain starts at: `self` in `self.inner.write()`.
fn chain_head(line: []const u8, at: usize) ?[]const u8 {
    var end = at;
    while (end > 0) {
        var start = end;
        while (start > 0 and ident_char(line[start - 1])) start -= 1;
        if (start == end) return null;
        if (start == 0 or line[start - 1] != '.') return line[start..end];
        // Step over the dot and any call or index that precedes it.
        var k = start - 1;
        while (k > 0) {
            const c = line[k - 1];
            if (c == ')' or c == ']') {
                var depth: usize = 0;
                while (k > 0) : (k -= 1) {
                    const d = line[k - 1];
                    if (d == ')' or d == ']') depth += 1;
                    if (d == '(' or d == '[') {
                        depth -= 1;
                        if (depth == 0) {
                            k -= 1;
                            break;
                        }
                    }
                }
                continue;
            }
            break;
        }
        end = k;
    }
    return null;
}

/// A local bound to a field, live until its block closes.
const Alias = struct {
    name: []const u8,
    depth: isize,
};

/// `let mut cache = self.cached_codes.lock();` → `cache`.
fn alias_binding(t: []const u8, field: []const u8) ?[]const u8 {
    var rest = t;
    const keywords = [_][]const u8{ "let ", "const ", "var " };
    for (&keywords) |kw| {
        if (std.mem.startsWith(u8, rest, kw)) {
            rest = rest[kw.len..];
            break;
        }
    }
    rest = std.mem.trimStart(u8, rest, " \t");
    if (std.mem.startsWith(u8, rest, "mut ")) rest = std.mem.trimStart(u8, rest[4..], " \t");
    const eq = std.mem.indexOfScalar(u8, rest, '=') orelse return null;
    if (eq + 1 < rest.len and rest[eq + 1] == '=') return null;
    if (eq > 0 and (rest[eq - 1] == '!' or rest[eq - 1] == '<' or rest[eq - 1] == '>')) return null;
    const name = std.mem.trim(u8, rest[0..eq], " \t");
    if (!is_plain_ident(name)) return null;
    // A guard usually keeps the field's own name: `let mut tasks =
    // self.tasks.write().await;`. That is still an alias — `alias_reference`
    // requires no leading dot and `field_reference` requires one, so the two
    // never read the same text. Rejecting it lost the `tasks.retain(…)` that
    // clears the map on the next line.
    if (field_reference(rest[eq + 1 ..], field) == null) return null;
    return name;
}

/// The text after `.<field>`, when the line names the field.
fn field_reference(line: []const u8, field: []const u8) ?[]const u8 {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, line, from, field)) |idx| {
        from = idx + field.len;
        if (idx == 0 or line[idx - 1] != '.') continue;
        if (from < line.len and ident_char(line[from])) continue;
        return line[from..];
    }
    return null;
}

/// The text after a bare `<alias>`.
fn alias_reference(line: []const u8, alias: []const u8) ?[]const u8 {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, line, from, alias)) |idx| {
        from = idx + alias.len;
        if (idx > 0 and (ident_char(line[idx - 1]) or line[idx - 1] == '.')) continue;
        if (from < line.len and ident_char(line[from])) continue;
        return line[from..];
    }
    return null;
}

/// Whether the text right after a container reference grows or shrinks it.
fn classify_use(t: []const u8, after: []const u8) enum { none, grow, shrink } {
    if (contains_any(after, &shrink_ops)) return .shrink;
    // `delete(m.field, k)` in Go, `del self.field[k]` in Python.
    if (std.mem.indexOf(u8, t, "delete(") != null) return .shrink;
    if (std.mem.startsWith(u8, t, "del ")) return .shrink;
    if (contains_any(after, &grow_ops)) return .grow;
    // `map[key] = value` grows a Go map, a Python dict and a JS object alike.
    if (after.len > 0 and after[0] == '[') {
        if (std.mem.indexOfScalar(u8, after, '=')) |eq| {
            const next = eq + 1;
            if (next >= after.len or after[next] != '=') return .grow;
        }
    }
    return .none;
}

/// What one file does to one field, following lock guards.
fn scan_field_uses(content: []const u8, field: []const u8, lang: models.Language, allocator: std.mem.Allocator) !FieldUse {
    var use = FieldUse{};
    var aliases = std.ArrayList(Alias).empty;
    defer aliases.deinit(allocator);

    var depth: isize = 0;
    var line_no: usize = 0;
    var scope = MethodScope{};
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |raw| {
        line_no += 1;
        const t = trimmed_line(raw);
        const delta = if (lang == .python) 0 else brace_delta(raw);
        defer depth += delta;
        if (t.len == 0 or is_comment(t, lang)) continue;

        // Track which function this line sits in.
        if (fn_start(t, lang)) |name| {
            scope = .{ .in_signature = true, .is_constructor = is_constructor_name(name) };
        }
        if (scope.in_signature) {
            read_signature_line(&scope, t, lang);
            if (signature_ends(t, lang)) scope.in_signature = false;
        }
        // A TypeScript method carries no receiver in its signature, so the
        // reference chain decides: `this.sessions` is the object's own state,
        // `local.sessions` is something being built.
        const ts_like = lang == .typescript or lang == .javascript;
        const may_grow = if (ts_like) !scope.is_constructor else scope.counts();

        // Drop the guards whose block has closed.
        while (aliases.items.len > 0 and depth < aliases.items[aliases.items.len - 1].depth) {
            _ = aliases.pop();
        }

        if (field_reference(t, field)) |after| {
            // `field_reference` guarantees a dot before the name, and
            // `chain_head` reads the identifier that ends at the index it is
            // given — so it gets the dot's index, not the field's.
            const at = t.len - after.len - field.len;
            const own = if (ts_like) blk: {
                if (at == 0) break :blk false;
                const head = chain_head(t, at - 1) orelse break :blk false;
                break :blk std.mem.eql(u8, head, "this");
            } else true;
            switch (classify_use(t, after)) {
                // A removal settles the question wherever it is written.
                .shrink => use.shrinks = true,
                .grow => if (use.grow_line == null and may_grow and own) {
                    use.grow_line = line_no;
                },
                .none => {},
            }
        }
        for (aliases.items) |a| {
            const after = alias_reference(t, a.name) orelse continue;
            switch (classify_use(t, after)) {
                .shrink => use.shrinks = true,
                .grow => if (use.grow_line == null and may_grow) {
                    use.grow_line = line_no;
                },
                .none => {},
            }
        }

        if (alias_binding(t, field)) |name| {
            try aliases.append(allocator, .{ .name = name, .depth = depth + delta });
        }
    }
    return use;
}

/// Files that can touch this field: the one that declares it, and any that
/// carries an `impl` or a subclass of the owner. A shrink in a sibling module
/// still settles the question.
fn field_scope_files(
    allocator: std.mem.Allocator,
    exp: *explorer.Explorer,
    field: FieldDecl,
    out: *std.ArrayList(u32),
) !void {
    try out.append(allocator, field.file_id);
    const hits = exp.words.search(field.owner);
    for (hits) |hit| {
        if (hit == field.file_id) continue;
        if (exp.deleted_files.get(hit) != null) continue;
        const outline = exp.outlines.get(hit) orelse continue;
        if (outline.language != field.lang) continue;
        const content = exp.content_cache.get(hit) orelse continue;
        const owns = switch (field.lang) {
            .rust => impl_of(content, field.owner),
            .typescript, .javascript => extends_of(content, field.owner),
            .go => receiver_of(content, field.owner),
            else => false,
        };
        if (owns) try out.append(allocator, hit);
    }
}

fn impl_of(content: []const u8, owner: []const u8) bool {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, content, from, "impl")) |idx| {
        from = idx + 4;
        const rest = content[from..];
        const line_end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        if (field_word_in(rest[0..line_end], owner)) return true;
    }
    return false;
}

fn extends_of(content: []const u8, owner: []const u8) bool {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, content, from, "extends ")) |idx| {
        from = idx + "extends ".len;
        const rest = content[from..];
        const line_end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        if (field_word_in(rest[0..line_end], owner)) return true;
    }
    return false;
}

/// `func (r *Registry) Add(…)` — a method on the owner.
fn receiver_of(content: []const u8, owner: []const u8) bool {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, content, from, "func (")) |idx| {
        from = idx + "func (".len;
        const rest = content[from..];
        const close = std.mem.indexOfScalar(u8, rest, ')') orelse continue;
        if (field_word_in(rest[0..close], owner)) return true;
    }
    return false;
}

fn field_word_in(text: []const u8, word: []const u8) bool {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, text, from, word)) |idx| {
        const before_ok = idx == 0 or !ident_char(text[idx - 1]);
        const after = idx + word.len;
        const after_ok = after >= text.len or !ident_char(text[after]);
        if (before_ok and after_ok) return true;
        from = idx + 1;
    }
    return false;
}

// ── Shape: an unbounded channel ──────────────────────────────────────────────

const unbounded_channels = [_][]const u8{
    "unbounded_channel(", "channel::unbounded(", "crossbeam::channel::unbounded(",
    "mpsc::unbounded(",   "flume::unbounded(",
};

// ── Shape: a detached spawn inside a loop ────────────────────────────────────

const spawn_calls = [_][]const u8{
    "tokio::spawn(", "thread::spawn(", "task::spawn(", "rayon::spawn(",
};

fn line_starts_loop(t: []const u8, lang: models.Language) bool {
    const common = [_][]const u8{ "while ", "for ", "while(", "for(" };
    for (&common) |k| {
        if (std.mem.startsWith(u8, t, k)) return true;
    }
    if (lang == .python) return false;
    return std.mem.startsWith(u8, t, "loop ") or std.mem.startsWith(u8, t, "loop{");
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

/// A spawn whose handle nobody keeps: the statement is not bound to a name and
/// nothing awaits or joins it on the same line.
fn is_detached_spawn(t: []const u8) bool {
    if (!contains_any(t, &spawn_calls)) return false;
    if (std.mem.indexOf(u8, t, ".await") != null) return false;
    if (std.mem.indexOf(u8, t, ".join(") != null) return false;
    if (std.mem.indexOf(u8, t, ".abort(") != null) return false;
    // `let handle = tokio::spawn(…)` keeps the handle; `handles.push(spawn(…))`
    // keeps it too.
    if (std.mem.startsWith(u8, t, "let ")) return false;
    if (contains_any(t, &grow_ops)) return false;
    return true;
}

// ── Entry point ──────────────────────────────────────────────────────────────

/// Every container field, across every struct, that grows and never shrinks.
fn scan_struct_fields(
    allocator: std.mem.Allocator,
    exp: *explorer.Explorer,
    findings: *std.ArrayList(Finding),
) !void {
    var fields = std.ArrayList(FieldDecl).empty;
    defer fields.deinit(allocator);

    var it = exp.outlines.iterator();
    while (it.next()) |entry| {
        const file_id = entry.key_ptr.*;
        if (exp.deleted_files.get(file_id) != null) continue;
        const outline = entry.value_ptr.*;
        if (is_excluded_path(outline.path)) continue;
        switch (outline.language) {
            .rust, .typescript, .javascript, .python, .go => {},
            else => continue,
        }
        const content = exp.content_cache.get(file_id) orelse continue;
        try collect_field_decls(allocator, file_id, outline, content, &fields);
    }

    var scope = std.ArrayList(u32).empty;
    defer scope.deinit(allocator);

    for (fields.items) |field| {
        if (field.ambiguous) continue;
        // A one- or two-letter field name collides with everything.
        if (field.name.len <= 2) continue;

        scope.clearRetainingCapacity();
        try field_scope_files(allocator, exp, field, &scope);

        var grow_line: ?usize = null;
        var grow_file: []const u8 = field.file;
        var shrinks = false;
        var bounded = false;
        for (scope.items) |sid| {
            const outline = exp.outlines.get(sid) orelse continue;
            const content = exp.content_cache.get(sid) orelse continue;
            if (container_is_bounded(content, field.name, field.decl)) bounded = true;
            const use = try scan_field_uses(content, field.name, field.lang, allocator);
            if (use.shrinks) shrinks = true;
            if (use.grow_line) |l| {
                if (grow_line == null) {
                    grow_line = l;
                    grow_file = outline.path;
                }
            }
        }
        if (shrinks or bounded) continue;
        const line = grow_line orelse continue;

        const looks_like_cache = contains_any_ci(field.name, &.{ "cache", "registry", "store", "pool", "sessions", "clients" });
        const subject = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ field.owner, field.name });
        errdefer allocator.free(subject);
        const evidence = if (std.mem.eql(u8, grow_file, field.file))
            try std.fmt.allocPrint(
                allocator,
                "{s}.{s} grows at line {d} and no method of {s} removes from it",
                .{ field.owner, field.name, line, field.owner },
            )
        else
            try std.fmt.allocPrint(
                allocator,
                "{s}.{s} grows at {s}:{d} and no method of {s} removes from it",
                .{ field.owner, field.name, grow_file, line, field.owner },
            );
        try findings.append(allocator, .{
            .file = field.file,
            .line = field.line,
            .shape = if (looks_like_cache) .unbounded_cache else .growing_container,
            .subject = subject,
            .evidence = evidence,
        });
    }
}

pub fn scan(allocator: std.mem.Allocator, exp: *explorer.Explorer) ![]Finding {
    var findings = std.ArrayList(Finding).empty;
    errdefer {
        for (findings.items) |f| {
            if (f.subject) |s| allocator.free(s);
            allocator.free(f.evidence);
        }
        findings.deinit(allocator);
    }

    try scan_struct_fields(allocator, exp, &findings);

    var it = exp.outlines.iterator();
    while (it.next()) |entry| {
        const file_id = entry.key_ptr.*;
        if (exp.deleted_files.get(file_id) != null) continue;
        const outline = entry.value_ptr.*;
        if (is_excluded_path(outline.path)) continue;
        const lang = outline.language;
        switch (lang) {
            .rust, .typescript, .javascript, .python, .go => {},
            else => continue,
        }
        const content = exp.content_cache.get(file_id) orelse continue;
        const file_undoes_leak = contains_any(content, &leak_undo);
        var reported_names = std.StringHashMap(void).init(allocator);
        defer reported_names.deinit();

        var line_no: usize = 0;
        var depth: isize = 0;
        var loop_depth: isize = -1;
        var loop_indent: usize = 0;
        var in_loop = false;
        var line_it = std.mem.splitScalar(u8, content, '\n');
        while (line_it.next()) |raw| {
            line_no += 1;
            const t = trimmed_line(raw);
            if (t.len == 0 or is_comment(t, lang)) {
                if (lang != .python) depth += brace_delta(raw);
                continue;
            }

            // Close a loop this line left.
            if (in_loop) {
                if (lang == .python) {
                    if (indent_of(raw) <= loop_indent) in_loop = false;
                } else if (depth < loop_depth) {
                    in_loop = false;
                }
            }

            // A deliberately given-up allocation.
            if (lang == .rust and !file_undoes_leak and contains_any(t, &leak_calls)) {
                try findings.append(allocator, .{
                    .file = outline.path,
                    .line = line_no,
                    .shape = .leaked_allocation,
                    .subject = null,
                    .evidence = try allocator.dupe(u8, t),
                });
            }

            // A queue with no bound.
            if (contains_any(t, &unbounded_channels)) {
                try findings.append(allocator, .{
                    .file = outline.path,
                    .line = line_no,
                    .shape = .unbounded_channel,
                    .subject = null,
                    .evidence = try allocator.dupe(u8, t),
                });
            }

            // A task started in a loop that nobody keeps.
            if (in_loop and is_detached_spawn(t)) {
                try findings.append(allocator, .{
                    .file = outline.path,
                    .line = line_no,
                    .shape = .detached_spawn_in_loop,
                    .subject = null,
                    .evidence = try allocator.dupe(u8, t),
                });
            }

            // A container at file scope that only ever grows. One report per
            // name: the same binding can appear on several lines.
            if (file_scope_container(t, raw, lang)) |name| {
                if (file_grows(content, name)) |grow_line| {
                    if (!file_shrinks(content, name) and
                        !container_is_bounded(content, name, t) and
                        !reported_names.contains(name))
                    {
                        try reported_names.put(name, {});
                        const looks_like_cache = contains_any_ci(name, &.{ "cache", "registry", "store", "pool" });
                        try findings.append(allocator, .{
                            .file = outline.path,
                            .line = line_no,
                            .shape = if (looks_like_cache) .unbounded_cache else .growing_container,
                            .subject = try allocator.dupe(u8, name),
                            .evidence = try std.fmt.allocPrint(allocator, "{s} grows at line {d} and the file never removes from it", .{ name, grow_line }),
                        });
                    }
                }
            }

            // Open a loop this line starts.
            if (line_starts_loop(t, lang)) {
                in_loop = true;
                loop_indent = indent_of(raw);
                loop_depth = depth + brace_delta(raw);
            }
            if (lang != .python) depth += brace_delta(raw);
        }
    }

    return findings.toOwnedSlice(allocator);
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

test "leak_shapes: a static map that grows and never shrinks" {
    const allocator = testing.allocator;
    const src =
        \\static SEEN: Mutex<HashMap<String, u64>> = Mutex::new(HashMap::new());
        \\
        \\pub fn record(id: String) {
        \\    SEEN.lock().unwrap().insert(id, 1);
        \\}
        \\
    ;
    var exp = try explorer.Explorer.init(allocator);
    defer exp.deinit();
    _ = try exp.add_file(try one_file(allocator, "src/seen.rs", .rust, src), src);
    exp.mark_indexing_complete();

    const findings = try scan(allocator, &exp);
    defer free_findings(allocator, findings);
    try testing.expectEqual(@as(usize, 1), findings.len);
    try testing.expectEqual(Shape.growing_container, findings[0].shape);
    try testing.expectEqualStrings("SEEN", findings[0].subject.?);
    try testing.expect(std.mem.indexOf(u8, Shape.growing_container.runtime_check(), "resident memory") != null);
}

test "leak_shapes: one removal clears the shape" {
    const allocator = testing.allocator;
    const src =
        \\static SEEN: Mutex<HashMap<String, u64>> = Mutex::new(HashMap::new());
        \\
        \\pub fn record(id: String) {
        \\    SEEN.lock().unwrap().insert(id, 1);
        \\}
        \\
        \\pub fn forget(id: &str) {
        \\    SEEN.lock().unwrap().remove(id);
        \\}
        \\
    ;
    var exp = try explorer.Explorer.init(allocator);
    defer exp.deinit();
    _ = try exp.add_file(try one_file(allocator, "src/seen.rs", .rust, src), src);
    exp.mark_indexing_complete();

    const findings = try scan(allocator, &exp);
    defer free_findings(allocator, findings);
    try testing.expectEqual(@as(usize, 0), findings.len);
}

test "leak_shapes: a bounded cache is not a finding" {
    const allocator = testing.allocator;
    const src =
        \\static CACHE: Mutex<LruCache<String, u64>> = Mutex::new(LruCache::new(1024));
        \\
        \\pub fn put(id: String) {
        \\    CACHE.lock().unwrap().insert(id, 1);
        \\}
        \\
    ;
    var exp = try explorer.Explorer.init(allocator);
    defer exp.deinit();
    _ = try exp.add_file(try one_file(allocator, "src/cache.rs", .rust, src), src);
    exp.mark_indexing_complete();

    const findings = try scan(allocator, &exp);
    defer free_findings(allocator, findings);
    try testing.expectEqual(@as(usize, 0), findings.len);
}

test "leak_shapes: a doc comment does not bound a container" {
    const allocator = testing.allocator;
    // "expires" here is prose about a probe window. A file-wide search for a
    // bound marker read it as a bound and silenced the container below it.
    const src =
        \\/// The probe blocks the traffic that would probe it, until the window expires.
        \\static SEEN: Mutex<HashMap<String, u64>> = Mutex::new(HashMap::new());
        \\
        \\pub fn record(id: String) {
        \\    SEEN.lock().unwrap().insert(id, 1);
        \\}
        \\
    ;
    var exp = try explorer.Explorer.init(allocator);
    defer exp.deinit();
    _ = try exp.add_file(try one_file(allocator, "src/probe.rs", .rust, src), src);
    exp.mark_indexing_complete();

    const findings = try scan(allocator, &exp);
    defer free_findings(allocator, findings);
    try testing.expectEqual(@as(usize, 1), findings.len);
    try testing.expectEqualStrings("SEEN", findings[0].subject.?);
}

test "leak_shapes: an unbounded cache is named as one" {
    const allocator = testing.allocator;
    const src =
        \\static CACHE: Mutex<HashMap<String, Vec<u8>>> = Mutex::new(HashMap::new());
        \\
        \\pub fn put(k: String, v: Vec<u8>) {
        \\    CACHE.lock().unwrap().insert(k, v);
        \\}
        \\
    ;
    var exp = try explorer.Explorer.init(allocator);
    defer exp.deinit();
    _ = try exp.add_file(try one_file(allocator, "src/cache.rs", .rust, src), src);
    exp.mark_indexing_complete();

    const findings = try scan(allocator, &exp);
    defer free_findings(allocator, findings);
    try testing.expectEqual(@as(usize, 1), findings.len);
    try testing.expectEqual(Shape.unbounded_cache, findings[0].shape);
}

test "leak_shapes: Box::leak, and the same file taking the pointer back" {
    const allocator = testing.allocator;
    const leaks = "pub fn hold(v: Config) -> &'static Config {\n    Box::leak(Box::new(v))\n}\n";
    const returns = "pub fn hold(v: Config) -> *mut Config {\n    let p = Box::into_raw(Box::new(v));\n    let _ = unsafe { Box::from_raw(p) };\n    p\n}\n";

    var exp = try explorer.Explorer.init(allocator);
    defer exp.deinit();
    _ = try exp.add_file(try one_file(allocator, "src/hold.rs", .rust, leaks), leaks);
    _ = try exp.add_file(try one_file(allocator, "src/roundtrip.rs", .rust, returns), returns);
    exp.mark_indexing_complete();

    const findings = try scan(allocator, &exp);
    defer free_findings(allocator, findings);
    try testing.expectEqual(@as(usize, 1), findings.len);
    try testing.expectEqual(Shape.leaked_allocation, findings[0].shape);
    try testing.expectEqualStrings("src/hold.rs", findings[0].file);
}

test "leak_shapes: a detached spawn in a loop, and a kept handle" {
    const allocator = testing.allocator;
    const src =
        \\pub async fn fan_out(jobs: Vec<Job>) {
        \\    for job in jobs {
        \\        tokio::spawn(run(job));
        \\    }
        \\}
        \\
        \\pub async fn joined(jobs: Vec<Job>) {
        \\    for job in jobs {
        \\        let handle = tokio::spawn(run(job));
        \\        handle.await.unwrap();
        \\    }
        \\}
        \\
    ;
    var exp = try explorer.Explorer.init(allocator);
    defer exp.deinit();
    _ = try exp.add_file(try one_file(allocator, "src/fan.rs", .rust, src), src);
    exp.mark_indexing_complete();

    const findings = try scan(allocator, &exp);
    defer free_findings(allocator, findings);
    try testing.expectEqual(@as(usize, 1), findings.len);
    try testing.expectEqual(Shape.detached_spawn_in_loop, findings[0].shape);
    try testing.expectEqual(@as(usize, 3), findings[0].line);
}

test "leak_shapes: an unbounded channel construction" {
    const allocator = testing.allocator;
    const src = "pub fn wire() {\n    let (tx, rx) = mpsc::unbounded_channel();\n}\n";
    var exp = try explorer.Explorer.init(allocator);
    defer exp.deinit();
    _ = try exp.add_file(try one_file(allocator, "src/wire.rs", .rust, src), src);
    exp.mark_indexing_complete();

    const findings = try scan(allocator, &exp);
    defer free_findings(allocator, findings);
    try testing.expectEqual(@as(usize, 1), findings.len);
    try testing.expectEqual(Shape.unbounded_channel, findings[0].shape);
    try testing.expect(std.mem.indexOf(u8, Shape.unbounded_channel.runtime_check(), "queue depth") != null);
}

test "leak_shapes: a test file is out of scope" {
    const allocator = testing.allocator;
    const src = "static SEEN: Vec<u32> = Vec::new();\nfn t() { SEEN.push(1); }\n";
    var exp = try explorer.Explorer.init(allocator);
    defer exp.deinit();
    _ = try exp.add_file(try one_file(allocator, "tests/seen.rs", .rust, src), src);
    exp.mark_indexing_complete();

    const findings = try scan(allocator, &exp);
    defer free_findings(allocator, findings);
    try testing.expectEqual(@as(usize, 0), findings.len);
}

test "leak_shapes: a struct field that grows and never shrinks" {
    const allocator = testing.allocator;
    const src =
        \\pub struct TaskTracker {
        \\    tasks: RwLock<HashMap<String, SpawnedTask>>,
        \\}
        \\
        \\impl TaskTracker {
        \\    pub async fn spawn(
        \\        self: &Arc<Self>,
        \\        agent_id: &str,
        \\    ) -> Result<String> {
        \\        self.tasks.write().await.insert(task_id.clone(), task);
        \\        Ok(task_id)
        \\    }
        \\}
        \\
    ;
    var exp = try explorer.Explorer.init(allocator);
    defer exp.deinit();
    _ = try exp.add_file(try one_file(allocator, "src/tracker.rs", .rust, src), src);
    exp.mark_indexing_complete();

    const findings = try scan(allocator, &exp);
    defer free_findings(allocator, findings);
    try testing.expectEqual(@as(usize, 1), findings.len);
    try testing.expectEqualStrings("TaskTracker.tasks", findings[0].subject.?);
    try testing.expectEqual(@as(usize, 2), findings[0].line);
}

test "leak_shapes: a removal through a lock guard clears the shape" {
    const allocator = testing.allocator;
    // The guard is where the removal lands. Reading only `self.<field>` reports
    // every `Mutex<HashMap>` field in a codebase.
    const src =
        \\pub struct Otp {
        \\    cached_codes: Mutex<HashMap<String, u64>>,
        \\}
        \\
        \\impl Otp {
        \\    pub fn check(&self, code: &str, now: u64) -> bool {
        \\        let mut cache = self.cached_codes.lock();
        \\        cache.retain(|_, expiry| *expiry >= now);
        \\        cache.insert(code.to_string(), now);
        \\        true
        \\    }
        \\}
        \\
    ;
    var exp = try explorer.Explorer.init(allocator);
    defer exp.deinit();
    _ = try exp.add_file(try one_file(allocator, "src/otp.rs", .rust, src), src);
    exp.mark_indexing_complete();

    const findings = try scan(allocator, &exp);
    defer free_findings(allocator, findings);
    try testing.expectEqual(@as(usize, 0), findings.len);
}

test "leak_shapes: a guard may carry the field's own name" {
    const allocator = testing.allocator;
    // `let mut tasks = self.tasks.write().await;` then `tasks.retain(…)`.
    const src =
        \\pub struct Tracker {
        \\    tasks: RwLock<HashMap<String, Task>>,
        \\}
        \\
        \\impl Tracker {
        \\    pub async fn add(&self, id: String, t: Task) {
        \\        self.tasks.write().await.insert(id, t);
        \\    }
        \\
        \\    pub async fn sweep(&self) {
        \\        let mut tasks = self.tasks.write().await;
        \\        tasks.retain(|_, t| t.is_running());
        \\    }
        \\}
        \\
    ;
    var exp = try explorer.Explorer.init(allocator);
    defer exp.deinit();
    _ = try exp.add_file(try one_file(allocator, "src/tracker.rs", .rust, src), src);
    exp.mark_indexing_complete();

    const findings = try scan(allocator, &exp);
    defer free_findings(allocator, findings);
    try testing.expectEqual(@as(usize, 0), findings.len);
}

test "leak_shapes: a constructor fills a container once" {
    const allocator = testing.allocator;
    // `from_config` builds a local registry from a configuration list. It grows
    // once per registry, not once per request.
    const src =
        \\pub struct RoleRegistry {
        \\    roles: HashMap<String, RoleDefinition>,
        \\}
        \\
        \\impl RoleRegistry {
        \\    pub fn from_config(custom: &[RoleConfig]) -> Result<Self> {
        \\        let mut registry = Self::default();
        \\        for role in custom {
        \\            registry.roles.insert(role.name.clone(), role.into());
        \\        }
        \\        Ok(registry)
        \\    }
        \\}
        \\
    ;
    var exp = try explorer.Explorer.init(allocator);
    defer exp.deinit();
    _ = try exp.add_file(try one_file(allocator, "src/roles.rs", .rust, src), src);
    exp.mark_indexing_complete();

    const findings = try scan(allocator, &exp);
    defer free_findings(allocator, findings);
    try testing.expectEqual(@as(usize, 0), findings.len);
}

test "leak_shapes: a builder taking self by value is not a holder" {
    const allocator = testing.allocator;
    const src =
        \\pub struct ValidationResult {
        \\    errors: Vec<String>,
        \\}
        \\
        \\impl ValidationResult {
        \\    pub fn with_error(mut self, e: impl Into<String>) -> Self {
        \\        self.errors.push(e.into());
        \\        self
        \\    }
        \\}
        \\
    ;
    var exp = try explorer.Explorer.init(allocator);
    defer exp.deinit();
    _ = try exp.add_file(try one_file(allocator, "src/validator.rs", .rust, src), src);
    exp.mark_indexing_complete();

    const findings = try scan(allocator, &exp);
    defer free_findings(allocator, findings);
    try testing.expectEqual(@as(usize, 0), findings.len);
}

test "leak_shapes: a removal in a sibling impl file still counts" {
    const allocator = testing.allocator;
    const decl =
        \\pub struct Sessions {
        \\    entries: Mutex<HashMap<String, Entry>>,
        \\}
        \\
        \\impl Sessions {
        \\    pub fn add(&self, k: String, e: Entry) {
        \\        self.entries.lock().insert(k, e);
        \\    }
        \\}
        \\
    ;
    const sweep =
        \\impl Sessions {
        \\    pub fn sweep(&self) {
        \\        self.entries.lock().retain(|_, e| e.alive());
        \\    }
        \\}
        \\
    ;
    var exp = try explorer.Explorer.init(allocator);
    defer exp.deinit();
    _ = try exp.add_file(try one_file(allocator, "src/sessions.rs", .rust, decl), decl);
    _ = try exp.add_file(try one_file(allocator, "src/sessions_sweep.rs", .rust, sweep), sweep);
    exp.mark_indexing_complete();

    const findings = try scan(allocator, &exp);
    defer free_findings(allocator, findings);
    try testing.expectEqual(@as(usize, 0), findings.len);
}

test "leak_shapes: two structs sharing a field name are ambiguous" {
    const allocator = testing.allocator;
    // `self.items` cannot say which struct it belongs to, so neither is judged.
    const src =
        \\pub struct A {
        \\    items: Vec<String>,
        \\}
        \\pub struct B {
        \\    items: Vec<String>,
        \\}
        \\impl A {
        \\    pub fn add(&mut self, s: String) { self.items.push(s); }
        \\}
        \\
    ;
    var exp = try explorer.Explorer.init(allocator);
    defer exp.deinit();
    _ = try exp.add_file(try one_file(allocator, "src/two.rs", .rust, src), src);
    exp.mark_indexing_complete();

    const findings = try scan(allocator, &exp);
    defer free_findings(allocator, findings);
    try testing.expectEqual(@as(usize, 0), findings.len);
}

test "leak_shapes: a `#[cfg(test)]` mock struct is out of scope" {
    const allocator = testing.allocator;
    const src =
        \\pub fn serve() {}
        \\
        \\#[cfg(test)]
        \\mod tests {
        \\    struct Recorder {
        \\        sent: Mutex<Vec<String>>,
        \\    }
        \\    impl Recorder {
        \\        fn record(&self, s: String) { self.sent.lock().unwrap().push(s); }
        \\    }
        \\}
        \\
    ;
    var exp = try explorer.Explorer.init(allocator);
    defer exp.deinit();
    _ = try exp.add_file(try one_file(allocator, "src/server.rs", .rust, src), src);
    exp.mark_indexing_complete();

    const findings = try scan(allocator, &exp);
    defer free_findings(allocator, findings);
    try testing.expectEqual(@as(usize, 0), findings.len);
}

test "leak_shapes: a TypeScript class field grows through `this`" {
    const allocator = testing.allocator;
    const src =
        \\export class SessionStore {
        \\  private sessions = new Map<string, Session>();
        \\
        \\  add(id: string, s: Session) {
        \\    this.sessions.set(id, s);
        \\  }
        \\}
        \\
    ;
    var exp = try explorer.Explorer.init(allocator);
    defer exp.deinit();
    _ = try exp.add_file(try one_file(allocator, "src/store.ts", .typescript, src), src);
    exp.mark_indexing_complete();

    const findings = try scan(allocator, &exp);
    defer free_findings(allocator, findings);
    try testing.expectEqual(@as(usize, 1), findings.len);
    try testing.expectEqualStrings("SessionStore.sessions", findings[0].subject.?);
    try testing.expectEqual(Shape.unbounded_cache, findings[0].shape);
}

test "leak_shapes: a bounded field type is not a finding" {
    const allocator = testing.allocator;
    const src =
        \\pub struct Cache {
        \\    entries: Mutex<LruCache<String, Vec<u8>>>,
        \\}
        \\impl Cache {
        \\    pub fn put(&self, k: String, v: Vec<u8>) { self.entries.lock().insert(k, v); }
        \\}
        \\
    ;
    var exp = try explorer.Explorer.init(allocator);
    defer exp.deinit();
    _ = try exp.add_file(try one_file(allocator, "src/cache.rs", .rust, src), src);
    exp.mark_indexing_complete();

    const findings = try scan(allocator, &exp);
    defer free_findings(allocator, findings);
    try testing.expectEqual(@as(usize, 0), findings.len);
}

test "leak_shapes: a Rust receiver is read in every spelling" {
    try testing.expect(rust_receiver("pub fn resolve(&self, id: &str) -> bool {").?.borrows);
    try testing.expect(rust_receiver("pub fn engage(&mut self, level: EstopLevel) -> Result<()> {").?.borrows);
    try testing.expect(rust_receiver("self: &Arc<Self>,").?.borrows);
    try testing.expect(rust_receiver("self: Arc<Self>,").?.borrows);
    // Taken by value: the object ends with the call.
    try testing.expect(!rust_receiver("pub fn merge(mut self, other: Self) -> Self {").?.borrows);
    try testing.expect(!rust_receiver("pub fn build(self) -> Config {").?.borrows);
    // No receiver at all.
    try testing.expectEqual(@as(?@TypeOf(rust_receiver("").?), null), rust_receiver("pub fn from_config(custom: &[RoleConfig]) -> Result<Self> {"));
    try testing.expectEqual(@as(?@TypeOf(rust_receiver("").?), null), rust_receiver("fn helper(selfish: u32) -> u32 {"));
}

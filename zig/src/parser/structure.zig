//! The structure the tags queries do not give: who can see a definition, what
//! reaches it without a reference, where the calls are, and which lines repeat.
//!
//! The tags queries name definitions. Every analysis that asks a whole-program
//! question needs more than that. `dead_code` needs visibility and the methods a
//! trait dispatches to. The round-trip and spawn analyses need call sites and
//! loops. Each analysis used to recover these from raw lines with its own brace
//! counter, and a call written in a string or a comment counted as a call. The
//! parser has the syntax tree in hand, so it records them once.

const std = @import("std");
const models = @import("../core/models.zig");
const ts = @import("treesitter.zig").ts;

// ── Visibility and flags ─────────────────────────────────────────────────────

pub const Classification = struct {
    visibility: models.Visibility,
    flags: models.SymbolFlags,
};

/// Visibility and flags for one definition. `def_node` is the node the tags
/// query captured as the definition, `name_node` its name.
pub fn classify(
    language: models.Language,
    kind: models.SymbolKind,
    content: []const u8,
    def_node: ts.TSNode,
    name_node: ts.TSNode,
    name: []const u8,
) Classification {
    const name_start: usize = ts.ts_node_start_byte(name_node);
    const def_start: usize = ts.ts_node_start_byte(def_node);
    // The modifiers sit on the name's own line, before the name: `pub fn x`,
    // `export const x`, `public static void x`.
    const line_begin = line_start_of(content, name_start);
    const prefix = content[line_begin..name_start];

    var flags = models.SymbolFlags{};
    const vis = visibility_of(language, kind, prefix, name);

    switch (language) {
        .rust => {
            if (in_trait_impl(def_node)) flags.implements = true;
        },
        .python => {
            if (is_dunder(name)) flags.implements = true;
            if (in_subclass(def_node)) flags.implements = true;
        },
        .java, .kotlin, .c_sharp, .typescript, .javascript, .scala, .swift, .dart => {
            if (has_token(prefix, "override")) flags.implements = true;
            if (in_subclass(def_node)) flags.implements = true;
            // A default export goes to whoever imports the module, and a
            // framework's file-based router is the usual importer.
            if (has_token(prefix, "export") and has_token(prefix, "default")) flags.registered = true;
        },
        else => {},
    }

    // Attributes and decorators stand on the lines above the definition.
    var above = attributes_above(language, content, @min(def_start, line_begin));
    while (above.next()) |attr| {
        if (implements_attribute(attr)) {
            flags.implements = true;
        } else if (!inert_attribute(attr)) {
            flags.registered = true;
        }
    }
    return .{ .visibility = vis, .flags = flags };
}

pub fn visibility_of(language: models.Language, kind: models.SymbolKind, prefix: []const u8, name: []const u8) models.Visibility {
    switch (language) {
        .rust => {
            var it = std.mem.tokenizeAny(u8, prefix, " \t");
            while (it.next()) |tok| {
                if (std.mem.eql(u8, tok, "pub")) return .public;
                if (std.mem.startsWith(u8, tok, "pub(self)")) return .private;
                if (std.mem.startsWith(u8, tok, "pub(")) return .restricted;
            }
            return .private;
        },
        .zig => {
            if (has_token(prefix, "pub") or has_token(prefix, "export")) return .public;
            return .private;
        },
        .typescript, .javascript => {
            if (name.len > 0 and name[0] == '#') return .private;
            if (has_token(prefix, "private")) return .private;
            if (has_token(prefix, "protected")) return .restricted;
            if (has_token(prefix, "export")) return .public;
            // A class member with no modifier is public; a module-level
            // binding with no `export` is visible to its own module only.
            const module_binding = has_token(prefix, "const") or has_token(prefix, "let") or
                has_token(prefix, "var") or has_token(prefix, "function");
            return switch (kind) {
                .method, .variable => if (module_binding) .private else .public,
                else => .private,
            };
        },
        .python => {
            if (is_dunder(name)) return .public;
            if (name.len > 0 and name[0] == '_') return .private;
            return .public;
        },
        .go => {
            if (name.len > 0 and std.ascii.isUpper(name[0])) return .public;
            return .private;
        },
        .java, .kotlin, .c_sharp, .scala, .swift, .dart => {
            if (has_token(prefix, "private")) return .private;
            if (has_token(prefix, "protected") or has_token(prefix, "internal")) return .restricted;
            if (has_token(prefix, "public") or has_token(prefix, "open")) return .public;
            if (language == .dart) return if (name.len > 0 and name[0] == '_') .private else .public;
            return switch (language) {
                .kotlin, .scala => .public,
                .c_sharp => .private,
                // Java's default and Swift's `internal`: the package or module.
                else => .restricted,
            };
        },
        .c, .cpp => {
            if (has_token(prefix, "static")) return .private;
            return .public;
        },
        .elixir => {
            if (has_token(prefix, "defp") or has_token(prefix, "defmacrop")) return .private;
            if (has_token(prefix, "def") or has_token(prefix, "defmacro")) return .public;
            return .unknown;
        },
        else => return .unknown,
    }
}

fn is_dunder(name: []const u8) bool {
    return name.len > 4 and std.mem.startsWith(u8, name, "__") and std.mem.endsWith(u8, name, "__");
}

fn has_token(text: []const u8, word: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, text, " \t()[]{}:;,");
    while (it.next()) |tok| {
        if (std.mem.eql(u8, tok, word)) return true;
    }
    return false;
}

fn line_start_of(content: []const u8, byte: usize) usize {
    var i = @min(byte, content.len);
    while (i > 0 and content[i - 1] != '\n') i -= 1;
    return i;
}

/// A method defined inside `impl Trait for Type` or inside a `trait`: the
/// trait dispatches to it, so no call names it.
fn in_trait_impl(def_node: ts.TSNode) bool {
    var node = ts.ts_node_parent(def_node);
    var hops: usize = 0;
    while (!ts.ts_node_is_null(node) and hops < 3) : (hops += 1) {
        const t = std.mem.span(ts.ts_node_type(node));
        if (std.mem.eql(u8, t, "trait_item")) return true;
        if (std.mem.eql(u8, t, "impl_item")) {
            const field = "trait";
            const trait_node = ts.ts_node_child_by_field_name(node, field.ptr, field.len);
            return !ts.ts_node_is_null(trait_node);
        }
        node = ts.ts_node_parent(node);
    }
    return false;
}

/// A method of a class that names a base class or an interface. The base can
/// call it by name: `BaseHTTPRequestHandler` dispatches to `do_GET`, React to
/// `render`, and neither call is in the repository. `override` is optional in
/// these languages, so the class header is the evidence.
fn in_subclass(def_node: ts.TSNode) bool {
    var node = ts.ts_node_parent(def_node);
    var hops: usize = 0;
    while (!ts.ts_node_is_null(node) and hops < 4) : (hops += 1) {
        const t = std.mem.span(ts.ts_node_type(node));
        const is_class = std.mem.eql(u8, t, "class_definition") or std.mem.eql(u8, t, "class_declaration") or
            std.mem.eql(u8, t, "class") or std.mem.eql(u8, t, "abstract_class_declaration") or
            std.mem.eql(u8, t, "object_declaration");
        if (is_class) {
            const field = "superclasses";
            const supers = ts.ts_node_child_by_field_name(node, field.ptr, field.len);
            if (!ts.ts_node_is_null(supers) and ts.ts_node_named_child_count(supers) > 0) return true;
            const n = ts.ts_node_named_child_count(node);
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                const ct = std.mem.span(ts.ts_node_type(ts.ts_node_named_child(node, i)));
                const heritage = [_][]const u8{ "class_heritage", "superclass", "super_interfaces", "base_list", "delegation_specifier", "delegation_specifiers", "extends_clause", "implements_clause" };
                for (&heritage) |h| {
                    if (std.mem.eql(u8, ct, h)) return true;
                }
            }
            return false;
        }
        // A nested function is not a method of the class around it.
        if (std.mem.indexOf(u8, t, "function") != null and hops > 0) return false;
        node = ts.ts_node_parent(node);
    }
    return false;
}

/// The attribute and decorator names directly above a definition, nearest
/// first. Doc comments between them are skipped; anything else ends the run.
const AttributeIter = struct {
    language: models.Language,
    content: []const u8,
    /// Byte offset of the start of the line below the next one to read.
    cursor: usize,
    budget: usize = 16,

    fn next(self: *AttributeIter) ?[]const u8 {
        while (self.cursor > 0 and self.budget > 0) {
            self.budget -= 1;
            const line_end = self.cursor - 1; // the '\n' ending the line above
            const begin = line_start_of(self.content, line_end);
            const line = std.mem.trim(u8, self.content[begin..line_end], " \t\r");
            self.cursor = begin;
            if (line.len == 0) return null;
            if (self.is_comment(line)) continue;
            if (attribute_name(self.language, line)) |n| return n;
            // A multi-line attribute's closing line: `)]` or `)`.
            if (line[0] == ')' or line[0] == ']' or line[0] == '}') continue;
            if (self.inside_attribute_args(line)) continue;
            return null;
        }
        return null;
    }

    fn is_comment(self: *AttributeIter, line: []const u8) bool {
        if (std.mem.startsWith(u8, line, "//") or std.mem.startsWith(u8, line, "/*") or std.mem.startsWith(u8, line, "*")) return true;
        return switch (self.language) {
            .python, .ruby, .elixir => line[0] == '#',
            else => false,
        };
    }

    /// The argument lines of a multi-line attribute: `key = "value",`.
    fn inside_attribute_args(self: *AttributeIter, line: []const u8) bool {
        _ = self;
        return std.mem.endsWith(u8, line, ",");
    }
};

fn attributes_above(language: models.Language, content: []const u8, def_line_begin: usize) AttributeIter {
    return .{ .language = language, .content = content, .cursor = line_start_of(content, def_line_begin) };
}

/// `#[tokio::main]` → `tokio::main`, `@app.route("/")` → `app.route`,
/// `[HttpGet]` → `HttpGet`. Null when the line is not an attribute.
fn attribute_name(language: models.Language, line: []const u8) ?[]const u8 {
    var rest: []const u8 = undefined;
    switch (language) {
        .rust => {
            if (std.mem.startsWith(u8, line, "#![")) {
                rest = line[3..];
            } else if (std.mem.startsWith(u8, line, "#[")) {
                rest = line[2..];
            } else return null;
        },
        .c_sharp => {
            if (line[0] != '[') return null;
            rest = line[1..];
        },
        .python, .java, .kotlin, .typescript, .javascript, .scala, .swift, .dart => {
            if (line[0] != '@') return null;
            rest = line[1..];
        },
        else => return null,
    }
    var end: usize = 0;
    while (end < rest.len and (std.ascii.isAlphanumeric(rest[end]) or rest[end] == '_' or rest[end] == ':' or rest[end] == '.')) end += 1;
    if (end == 0) return null;
    return rest[0..end];
}

/// The last segment of an attribute path: `tokio::main` → `main`.
fn attribute_base(attr: []const u8) []const u8 {
    var i = attr.len;
    while (i > 0 and attr[i - 1] != ':' and attr[i - 1] != '.') i -= 1;
    return attr[i..];
}

fn implements_attribute(attr: []const u8) bool {
    const base = attribute_base(attr);
    return std.mem.eql(u8, base, "Override") or std.mem.eql(u8, base, "override") or
        std.mem.eql(u8, base, "async_trait");
}

/// Attributes that change how a definition compiles or reads, and hand it to
/// no framework. Everything else — `#[tokio::main]`, `@app.route`,
/// `@pytest.fixture`, `#[no_mangle]`, `[HttpGet]` — means something outside the
/// source calls the definition by its attribute.
const inert_attributes = [_][]const u8{
    // Rust
    "derive",          "allow",               "warn",             "deny",           "expect",
    "inline",          "must_use",            "doc",              "cfg",            "cfg_attr",
    "deprecated",      "non_exhaustive",      "repr",             "rustfmt",        "clippy",
    "track_caller",    "cold",                "instrument",       "serde",          "automatically_derived",
    "forbid",          "macro_use",           "path",
    // Python
                "staticmethod",   "classmethod",
    "property",        "abstractmethod",      "wraps",            "lru_cache",      "cache",
    "cached_property", "dataclass",           "overload",         "contextmanager", "asynccontextmanager",
    "setter",          "getter",              "deleter",          "final",          "total_ordering",
    "unique",
    // Java, Kotlin, C#
             "Deprecated",          "SuppressWarnings", "Nullable",       "NonNull",
    "NotNull",         "FunctionalInterface", "SafeVarargs",      "JvmStatic",      "JvmOverloads",
    "Obsolete",        "Serializable",        "Transient",
};

fn inert_attribute(attr: []const u8) bool {
    const base = attribute_base(attr);
    for (&inert_attributes) |a| {
        if (std.mem.eql(u8, base, a) or std.mem.eql(u8, attr, a)) return true;
    }
    return false;
}

// ── Calls and loops ──────────────────────────────────────────────────────────

pub const Extracted = struct {
    calls: []models.Call,
    call_names: []u8,
    loops: []models.Loop,
    blocks: []models.Block,
};

/// Node types that hold a block of statements or members.
const block_types = [_][]const u8{
    "block",                  "statement_block", "compound_statement", "declaration_list",
    "field_declaration_list", "class_body",      "Block",              "ContainerDecl",
    "body_statement",         "do_block",        "interface_body",     "enum_body",
    "object_type",            "struct_type",     "switch_block",       "match_block",
};

fn is_block(t: []const u8) bool {
    for (&block_types) |b| {
        if (std.mem.eql(u8, t, b)) return true;
    }
    return false;
}

/// Walk the tree once and collect every call site and loop region.
pub fn extract(allocator: std.mem.Allocator, language: models.Language, content: []const u8, root: ts.TSNode) !Extracted {
    var calls = std.ArrayList(models.Call).empty;
    defer calls.deinit(allocator);
    // Name offsets into `names`, resolved into slices once the buffer stops
    // growing.
    var name_spans = std.ArrayList([3]u32).empty;
    defer name_spans.deinit(allocator);
    var names = std.ArrayList(u8).empty;
    defer names.deinit(allocator);
    var loops = std.ArrayList(models.Loop).empty;
    defer loops.deinit(allocator);
    var blocks = std.ArrayList(models.Block).empty;
    defer blocks.deinit(allocator);

    if (!walks_calls(language)) {
        return .{ .calls = &.{}, .call_names = &.{}, .loops = &.{}, .blocks = &.{} };
    }

    var cursor = ts.ts_tree_cursor_new(root);
    defer ts.ts_tree_cursor_delete(&cursor);

    var descending = true;
    while (true) {
        if (descending) {
            const node = ts.ts_tree_cursor_current_node(&cursor);
            // Keyword tokens are nodes too: Rust's `for` keyword has the type
            // `for`, which is Ruby's name for a whole loop.
            if (ts.ts_node_is_named(node)) {
                try visit(allocator, language, content, node, &loops, &calls, &name_spans, &names);
                if (is_block(std.mem.span(ts.ts_node_type(node)))) {
                    const a = ts.ts_node_start_point(node).row;
                    const b = ts.ts_node_end_point(node).row;
                    if (b > a) try blocks.append(allocator, .{ .line_start = a, .line_end = b });
                }
            }

            if (ts.ts_tree_cursor_goto_first_child(&cursor)) continue;
        }
        if (ts.ts_tree_cursor_goto_next_sibling(&cursor)) {
            descending = true;
            continue;
        }
        if (!ts.ts_tree_cursor_goto_parent(&cursor)) break;
        descending = false;
    }

    const owned_names = try names.toOwnedSlice(allocator);
    errdefer allocator.free(owned_names);
    const owned_calls = try calls.toOwnedSlice(allocator);
    for (owned_calls, name_spans.items) |*c, span| {
        c.name = owned_names[span[0] .. span[0] + span[1]];
        c.qualifier = owned_names[span[0] + span[1] .. span[0] + span[1] + span[2]];
    }
    errdefer allocator.free(owned_calls);
    const owned_loops = try loops.toOwnedSlice(allocator);
    errdefer allocator.free(owned_loops);
    return .{
        .calls = owned_calls,
        .call_names = owned_names,
        .loops = owned_loops,
        .blocks = try blocks.toOwnedSlice(allocator),
    };
}

/// Record `node` when it is a loop or a call.
fn visit(
    allocator: std.mem.Allocator,
    language: models.Language,
    content: []const u8,
    node: ts.TSNode,
    loops: *std.ArrayList(models.Loop),
    calls: *std.ArrayList(models.Call),
    name_spans: *std.ArrayList([3]u32),
    names: *std.ArrayList(u8),
) !void {
    const t = std.mem.span(ts.ts_node_type(node));
    if (loop_kind(language, t, node, content)) |kind| {
        const body = loop_body_start(node);
        try loops.append(allocator, .{
            .line_start = ts.ts_node_start_point(node).row,
            .line_end = ts.ts_node_end_point(node).row,
            .kind = kind,
            .body_line = body.row,
            .body_col = body.column,
        });
    }

    const args = arguments_of(language, t, node) orelse return;
    const callee = callee_before(content, ts.ts_node_start_byte(args)) orelse return;
    // The qualifier follows the name in the buffer.
    const off: u32 = @intCast(names.items.len);
    try names.appendSlice(allocator, callee.name);
    try names.appendSlice(allocator, callee.qualifier);
    try name_spans.append(allocator, .{ off, @intCast(callee.name.len), @intCast(callee.qualifier.len) });
    try calls.append(allocator, .{
        .name = &.{},
        .line = ts.ts_node_start_point(args).row,
        .col = ts.ts_node_start_point(args).column,
        .kind = callee.kind,
        .self_receiver = callee.self_receiver,
        .deferred = event_driven(language, content, node),
    });
    // `xs.forEach(x => …)`: the callback is the loop body.
    if (callback_loop(language, callee.name) and has_function_argument(args)) {
        const start = ts.ts_node_start_point(args);
        try loops.append(allocator, .{
            .line_start = start.row,
            .line_end = ts.ts_node_end_point(args).row,
            .kind = .each,
            .body_line = start.row,
            .body_col = start.column,
        });
    }
}

/// Languages whose calls feed the call graph. Data and markup formats have
/// no calls, and the shell has its own command-word scan in `spawn_scan`.
fn walks_calls(language: models.Language) bool {
    return switch (language) {
        .rust, .python, .go, .typescript, .javascript, .zig, .c, .cpp, .java, .ruby, .c_sharp, .kotlin, .lua, .scala, .swift, .dart, .php, .elixir => true,
        else => false,
    };
}

/// The argument list of a call node, or null when `node` is not a call.
fn arguments_of(language: models.Language, t: []const u8, node: ts.TSNode) ?ts.TSNode {
    // Zig has no call node: `FnCallArguments` follows the callee directly.
    if (language == .zig) {
        return if (std.mem.eql(u8, t, "FnCallArguments")) node else null;
    }
    const call_types = [_][]const u8{
        "call_expression", "call", "method_invocation", "invocation_expression", "function_call", "method_call",
    };
    var is_call = false;
    for (&call_types) |ct| {
        if (std.mem.eql(u8, t, ct)) {
            is_call = true;
            break;
        }
    }
    if (!is_call) return null;

    const field = "arguments";
    const by_field = ts.ts_node_child_by_field_name(node, field.ptr, field.len);
    if (!ts.ts_node_is_null(by_field)) return by_field;
    // Grammars that do not name the field: the first child whose type says it
    // holds arguments.
    const n = ts.ts_node_named_child_count(node);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const child = ts.ts_node_named_child(node, i);
        const ct = std.mem.span(ts.ts_node_type(child));
        if (std.mem.indexOf(u8, ct, "argument") != null or std.mem.eql(u8, ct, "call_suffix")) return child;
    }
    return null;
}

pub const Callee = struct {
    name: []const u8,
    kind: models.CallKind,
    self_receiver: bool,
    qualifier: []const u8 = "",
};

fn ident_char(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
}

/// The callee named just before the argument list at `open`: the last
/// identifier, past any generic arguments. `self.db.insert(` → `insert`,
/// method, receiver `db`. `Vec::<u8>::with_capacity(` → `with_capacity`, path.
pub fn callee_before(content: []const u8, open: usize) ?Callee {
    var i = @min(open, content.len);
    // Kotlin's `call_suffix` and some argument nodes include the parenthesis;
    // others start at it. Either way the callee ends before it.
    while (i > 0 and (content[i - 1] == ' ' or content[i - 1] == '\t')) i -= 1;
    // Generic arguments: `collect::<Vec<_>>(`, `foo<T>(`.
    if (i > 0 and content[i - 1] == '>') {
        var depth: usize = 0;
        while (i > 0) {
            i -= 1;
            if (content[i] == '>') depth += 1;
            if (content[i] == '<') {
                depth -= 1;
                if (depth == 0) break;
            }
            if (content[i] == '\n' or content[i] == ';' or content[i] == '{') return null;
        }
        if (i >= 2 and content[i - 1] == ':' and content[i - 2] == ':') i -= 2;
    }
    const end = i;
    while (i > 0 and ident_char(content[i - 1])) i -= 1;
    if (i == end) return null;
    const name = content[i..end];
    if (std.ascii.isDigit(name[0])) return null;

    var kind: models.CallKind = .plain;
    var qual_end: usize = i;
    if (i >= 1 and content[i - 1] == '.') {
        kind = .method;
        qual_end = i - 1;
        if (qual_end >= 1 and content[qual_end - 1] == '?') qual_end -= 1;
    } else if (i >= 2 and content[i - 1] == '>' and content[i - 2] == '-') {
        kind = .method;
        qual_end = i - 2;
    } else if (i >= 2 and content[i - 1] == ':' and content[i - 2] == ':') {
        kind = .path;
        qual_end = i - 2;
    }
    var self_receiver = false;
    var qual: []const u8 = "";
    if (kind != .plain) {
        var q = qual_end;
        while (q > 0 and ident_char(content[q - 1])) q -= 1;
        qual = content[q..qual_end];
        const selves = [_][]const u8{ "self", "this", "Self", "cls" };
        for (&selves) |s| {
            if (std.mem.eql(u8, qual, s)) self_receiver = true;
        }
    }
    return .{ .name = name, .kind = kind, .self_receiver = self_receiver, .qualifier = qual };
}

/// Calls whose function argument runs on an event, a timer or a render hook.
const event_calls = [_][]const u8{
    "addEventListener",      "on",        "once",        "subscribe", "setTimeout",      "setInterval",
    "requestAnimationFrame", "useEffect", "useCallback", "useMemo",   "useLayoutEffect",
};

/// Whether the call at `node` sits in a JavaScript function literal that
/// runs on an event: a JSX attribute value, or the callback of one of
/// `event_calls`. The walk stops at the nearest named function.
fn event_driven(language: models.Language, content: []const u8, node: ts.TSNode) bool {
    if (language != .typescript and language != .javascript) return false;
    var n = ts.ts_node_parent(node);
    while (!ts.ts_node_is_null(n)) : (n = ts.ts_node_parent(n)) {
        const t = std.mem.span(ts.ts_node_type(n));
        if (std.mem.eql(u8, t, "function_declaration") or std.mem.eql(u8, t, "method_definition") or
            std.mem.eql(u8, t, "program") or std.mem.eql(u8, t, "class_body")) return false;
        if (std.mem.eql(u8, t, "jsx_attribute")) return true;
        const literal = std.mem.eql(u8, t, "arrow_function") or std.mem.eql(u8, t, "function_expression") or
            std.mem.eql(u8, t, "function");
        if (!literal) continue;
        const p = ts.ts_node_parent(n);
        if (ts.ts_node_is_null(p) or !std.mem.eql(u8, std.mem.span(ts.ts_node_type(p)), "arguments")) continue;
        const callee = callee_before(content, ts.ts_node_start_byte(p)) orelse continue;
        for (&event_calls) |e| {
            if (std.mem.eql(u8, callee.name, e)) return true;
        }
    }
    return false;
}

/// Calls that run their function argument once per element.
fn callback_loop(language: models.Language, name: []const u8) bool {
    const names: []const []const u8 = switch (language) {
        .typescript, .javascript => &.{ "forEach", "map", "flatMap" },
        .rust => &.{ "for_each", "try_for_each" },
        .java, .kotlin, .scala => &.{"forEach"},
        .ruby => &.{ "each", "each_with_index", "map" },
        else => &.{},
    };
    for (names) |n| {
        if (std.mem.eql(u8, name, n)) return true;
    }
    return false;
}

fn has_function_argument(args: ts.TSNode) bool {
    const fn_types = [_][]const u8{
        "arrow_function", "function_expression", "function", "closure_expression", "lambda_expression", "lambda_literal", "lambda", "block", "do_block",
    };
    const n = ts.ts_node_named_child_count(args);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const t = std.mem.span(ts.ts_node_type(ts.ts_node_named_child(args, i)));
        for (&fn_types) |ft| {
            if (std.mem.eql(u8, t, ft)) return true;
        }
    }
    return false;
}

fn loop_kind(language: models.Language, t: []const u8, node: ts.TSNode, content: []const u8) ?models.LoopKind {
    const each_types = [_][]const u8{
        "for_expression",    "for_in_statement",         "enhanced_for_statement", "for_range_loop",
        "foreach_statement", "ForStatement",             "ForExpr",                "list_comprehension",
        "set_comprehension", "dictionary_comprehension", "generator_expression",   "for",
    };
    for (&each_types) |et| {
        if (std.mem.eql(u8, t, et)) return .each;
    }
    if (std.mem.eql(u8, t, "loop_expression")) return .forever;
    if (std.mem.eql(u8, t, "for_statement")) {
        switch (language) {
            .python, .kotlin => return .each,
            .go => {
                const n = ts.ts_node_named_child_count(node);
                var i: u32 = 0;
                var has_header = false;
                while (i < n) : (i += 1) {
                    const ct = std.mem.span(ts.ts_node_type(ts.ts_node_named_child(node, i)));
                    if (std.mem.eql(u8, ct, "range_clause")) return .each;
                    if (!std.mem.eql(u8, ct, "block")) has_header = true;
                }
                return if (has_header) .conditional else .forever;
            },
            else => return if (header_is_forever(content, node)) .forever else .conditional,
        }
    }
    const while_types = [_][]const u8{
        "while_expression", "while_statement", "do_statement", "do_while_statement", "WhileStatement", "WhileExpr", "while", "until",
    };
    for (&while_types) |wt| {
        if (std.mem.eql(u8, t, wt)) return if (header_is_forever(content, node)) .forever else .conditional;
    }
    return null;
}

/// Where a loop's repeated part begins: its `body` field, or the last named
/// child for grammars that name no field (Zig puts the block last). A
/// comprehension has no header that runs once apart from its iterable, and the
/// whole node counts.
fn loop_body_start(node: ts.TSNode) ts.TSPoint {
    const field = "body";
    const body = ts.ts_node_child_by_field_name(node, field.ptr, field.len);
    if (!ts.ts_node_is_null(body)) return ts.ts_node_start_point(body);
    const t = std.mem.span(ts.ts_node_type(node));
    if (std.mem.indexOf(u8, t, "comprehension") != null or std.mem.eql(u8, t, "generator_expression")) {
        return ts.ts_node_start_point(node);
    }
    const n = ts.ts_node_named_child_count(node);
    if (n == 0) return ts.ts_node_start_point(node);
    return ts.ts_node_start_point(ts.ts_node_named_child(node, n - 1));
}

/// `while true`, `while (true)`, `while True:`, `for (;;)`, `while (1)`.
fn header_is_forever(content: []const u8, node: ts.TSNode) bool {
    const start: usize = ts.ts_node_start_byte(node);
    var end = start;
    while (end < content.len and content[end] != '\n' and content[end] != '{' and end - start < 80) end += 1;
    var buf: [80]u8 = undefined;
    var n: usize = 0;
    for (content[start..end]) |c| {
        if (c == ' ' or c == '\t' or c == '(' or c == ')' or c == ':') continue;
        if (n < buf.len) {
            buf[n] = c;
            n += 1;
        }
    }
    const h = buf[0..n];
    const forever = [_][]const u8{ "whiletrue", "whileTrue", "while1", "for;;", "loop" };
    for (&forever) |f| {
        if (std.mem.eql(u8, h, f)) return true;
    }
    return false;
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "structure: the callee is the last identifier before the arguments" {
    const cases = [_]struct { src: []const u8, name: []const u8, kind: models.CallKind, self_recv: bool }{
        .{ .src = "foo(", .name = "foo", .kind = .plain, .self_recv = false },
        .{ .src = "self.db.insert(", .name = "insert", .kind = .method, .self_recv = false },
        .{ .src = "self.flush(", .name = "flush", .kind = .method, .self_recv = true },
        .{ .src = "sqlx::query(", .name = "query", .kind = .path, .self_recv = false },
        .{ .src = "Self::build(", .name = "build", .kind = .path, .self_recv = true },
        .{ .src = "iter.collect::<Vec<_>>(", .name = "collect", .kind = .method, .self_recv = false },
        .{ .src = "a?.b(", .name = "b", .kind = .method, .self_recv = false },
        .{ .src = "p->run (", .name = "run", .kind = .method, .self_recv = false },
    };
    for (&cases) |c| {
        const got = callee_before(c.src, c.src.len - 1) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(c.name, got.name);
        try testing.expectEqual(c.kind, got.kind);
        try testing.expectEqual(c.self_recv, got.self_receiver);
    }
    try testing.expectEqualStrings("agent", callee_before("crate::agent::run(", 17).?.qualifier);
    try testing.expectEqualStrings("db", callee_before("self.db.insert(", 14).?.qualifier);
    // `(f)(x)` and `foo()(x)` name nothing before their second parenthesis.
    try testing.expect(callee_before("foo()(", 5) == null);
}

test "structure: visibility read from the definition line" {
    try testing.expectEqual(models.Visibility.public, visibility_of(.rust, .function, "pub async fn ", "x"));
    try testing.expectEqual(models.Visibility.restricted, visibility_of(.rust, .function, "    pub(crate) fn ", "x"));
    try testing.expectEqual(models.Visibility.private, visibility_of(.rust, .method, "    fn ", "x"));
    try testing.expectEqual(models.Visibility.public, visibility_of(.zig, .function, "pub fn ", "x"));
    try testing.expectEqual(models.Visibility.private, visibility_of(.zig, .function, "fn ", "x"));
    try testing.expectEqual(models.Visibility.public, visibility_of(.typescript, .function, "export function ", "x"));
    try testing.expectEqual(models.Visibility.private, visibility_of(.typescript, .function, "function ", "x"));
    try testing.expectEqual(models.Visibility.private, visibility_of(.typescript, .variable, "const ", "x"));
    try testing.expectEqual(models.Visibility.private, visibility_of(.typescript, .method, "  private ", "x"));
    try testing.expectEqual(models.Visibility.public, visibility_of(.typescript, .method, "  ", "x"));
    try testing.expectEqual(models.Visibility.private, visibility_of(.python, .function, "def ", "_helper"));
    try testing.expectEqual(models.Visibility.public, visibility_of(.python, .function, "def ", "handler"));
    try testing.expectEqual(models.Visibility.public, visibility_of(.go, .function, "func ", "Serve"));
    try testing.expectEqual(models.Visibility.private, visibility_of(.go, .function, "func ", "serve"));
    try testing.expectEqual(models.Visibility.restricted, visibility_of(.java, .method, "  static void ", "x"));
}

test "structure: attributes above a definition" {
    const src =
        \\#[derive(Debug)]
        \\/// doc
        \\#[tokio::main]
        \\async fn main() {}
    ;
    var it = attributes_above(.rust, src, std.mem.indexOf(u8, src, "async").?);
    try testing.expectEqualStrings("tokio::main", it.next().?);
    try testing.expectEqualStrings("derive", it.next().?);
    try testing.expect(it.next() == null);
    try testing.expect(!inert_attribute("tokio::main"));
    try testing.expect(inert_attribute("derive"));
    try testing.expect(inert_attribute("serde"));
    try testing.expect(!inert_attribute("app.route"));
    try testing.expect(implements_attribute("Override"));
}

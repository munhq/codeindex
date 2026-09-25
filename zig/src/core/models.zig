const std = @import("std");

/// Programming language detected from file extension.
pub const Language = enum {
    rust,
    python,
    typescript,
    javascript,
    go,
    bash,
    c,
    cpp,
    java,
    ruby,
    php,
    swift,
    kotlin,
    c_sharp,
    lua,
    perl,
    zig,
    toml,
    json,
    yaml,
    html,
    css,
    sql,
    dockerfile,
    protobuf,
    solidity,
    nix,
    r,
    scala,
    haskell,
    ocaml,
    elixir,
    clojure,
    dart,
    hcl,
    make,
    cmake,
    markdown,
    latex,
    graphql,
    xml,
    scss,
    jinja2,
    ini,
    diff,
    gitcommit,
    gitignore,
    unknown,

    pub fn from_path(path: []const u8) Language {
        const extension = std.fs.path.extension(path);

        // Check basename first for extensionless files
        const basename = std.fs.path.basename(path);
        if (std.mem.eql(u8, basename, ".gitignore") or std.mem.eql(u8, basename, ".dockerignore")) return .gitignore;
        if (std.mem.eql(u8, basename, "Makefile") or std.mem.eql(u8, basename, "makefile")) return .make;
        if (std.mem.eql(u8, basename, "Dockerfile") or std.mem.startsWith(u8, basename, "Dockerfile.")) return .dockerfile;
        if (std.mem.eql(u8, basename, "CMakeLists.txt")) return .cmake;
        // .env, .env.local, .env.production … — KEY=value, parse as INI so they
        // get indexed (and scanned for secrets, which is where secrets live).
        if (std.mem.eql(u8, basename, ".env") or std.mem.startsWith(u8, basename, ".env.")) return .ini;

        if (extension.len == 0) return .unknown;
        // Lowercase the extension so case variants (.R, .PY, .H, .Cpp) match.
        var lower_buf: [16]u8 = undefined;
        const raw_ext = extension[1..]; // skip the dot
        const ext = if (raw_ext.len <= lower_buf.len) blk: {
            for (raw_ext, 0..) |c, i| lower_buf[i] = std.ascii.toLower(c);
            break :blk lower_buf[0..raw_ext.len];
        } else raw_ext;

        if (std.mem.eql(u8, ext, "rs")) return .rust;
        if (std.mem.eql(u8, ext, "py") or std.mem.eql(u8, ext, "pyi")) return .python;
        if (std.mem.eql(u8, ext, "ts") or std.mem.eql(u8, ext, "tsx") or std.mem.eql(u8, ext, "mts") or std.mem.eql(u8, ext, "cts")) return .typescript;
        if (std.mem.eql(u8, ext, "js") or std.mem.eql(u8, ext, "jsx") or std.mem.eql(u8, ext, "mjs") or std.mem.eql(u8, ext, "cjs")) return .javascript;
        if (std.mem.eql(u8, ext, "go")) return .go;
        if (std.mem.eql(u8, ext, "sh") or std.mem.eql(u8, ext, "bash")) return .bash;
        if (std.mem.eql(u8, ext, "c") or std.mem.eql(u8, ext, "h")) return .c;
        if (std.mem.eql(u8, ext, "cpp") or std.mem.eql(u8, ext, "cc") or std.mem.eql(u8, ext, "cxx") or
            std.mem.eql(u8, ext, "hpp") or std.mem.eql(u8, ext, "hh") or std.mem.eql(u8, ext, "hxx")) return .cpp;
        if (std.mem.eql(u8, ext, "java")) return .java;
        if (std.mem.eql(u8, ext, "rb")) return .ruby;
        if (std.mem.eql(u8, ext, "php")) return .php;
        if (std.mem.eql(u8, ext, "swift")) return .swift;
        if (std.mem.eql(u8, ext, "kt") or std.mem.eql(u8, ext, "kts")) return .kotlin;
        if (std.mem.eql(u8, ext, "cs")) return .c_sharp;
        if (std.mem.eql(u8, ext, "lua")) return .lua;
        if (std.mem.eql(u8, ext, "pl") or std.mem.eql(u8, ext, "pm")) return .perl;
        if (std.mem.eql(u8, ext, "zig")) return .zig;
        if (std.mem.eql(u8, ext, "toml")) return .toml;
        if (std.mem.eql(u8, ext, "json")) return .json;
        if (std.mem.eql(u8, ext, "yaml") or std.mem.eql(u8, ext, "yml")) return .yaml;
        if (std.mem.eql(u8, ext, "html") or std.mem.eql(u8, ext, "htm")) return .html;
        if (std.mem.eql(u8, ext, "css")) return .css;
        if (std.mem.eql(u8, ext, "sql")) return .sql;
        if (std.mem.eql(u8, ext, "dockerfile")) return .dockerfile;
        if (std.mem.eql(u8, ext, "proto")) return .protobuf;
        if (std.mem.eql(u8, ext, "sol")) return .solidity;
        if (std.mem.eql(u8, ext, "nix")) return .nix;
        if (std.mem.eql(u8, ext, "r")) return .r;
        if (std.mem.eql(u8, ext, "scala")) return .scala;
        if (std.mem.eql(u8, ext, "hs")) return .haskell;
        if (std.mem.eql(u8, ext, "ml") or std.mem.eql(u8, ext, "mli")) return .ocaml;
        if (std.mem.eql(u8, ext, "ex") or std.mem.eql(u8, ext, "exs")) return .elixir;
        if (std.mem.eql(u8, ext, "clj")) return .clojure;
        if (std.mem.eql(u8, ext, "dart")) return .dart;
        if (std.mem.eql(u8, ext, "hcl") or std.mem.eql(u8, ext, "tf") or std.mem.eql(u8, ext, "tfvars")) return .hcl;
        if (std.mem.eql(u8, ext, "make") or std.mem.eql(u8, ext, "mk") or std.mem.eql(u8, ext, "makefile")) return .make;
        if (std.mem.eql(u8, ext, "cmake")) return .cmake;
        if (std.mem.eql(u8, ext, "md") or std.mem.eql(u8, ext, "markdown")) return .markdown;
        if (std.mem.eql(u8, ext, "tex")) return .latex;
        if (std.mem.eql(u8, ext, "graphql") or std.mem.eql(u8, ext, "gql")) return .graphql;
        if (std.mem.eql(u8, ext, "scss") or std.mem.eql(u8, ext, "sass")) return .scss;
        if (std.mem.eql(u8, ext, "j2") or std.mem.eql(u8, ext, "jinja") or std.mem.eql(u8, ext, "jinja2")) return .jinja2;
        if (std.mem.eql(u8, ext, "xml") or std.mem.eql(u8, ext, "xsl") or std.mem.eql(u8, ext, "xslt") or std.mem.eql(u8, ext, "svg") or std.mem.eql(u8, ext, "plist") or std.mem.eql(u8, ext, "csproj") or std.mem.eql(u8, ext, "pom")) return .xml;
        if (std.mem.eql(u8, ext, "ini") or std.mem.eql(u8, ext, "cfg") or std.mem.eql(u8, ext, "conf") or std.mem.eql(u8, ext, "service") or std.mem.eql(u8, ext, "desktop") or std.mem.eql(u8, ext, "editorconfig")) return .ini;
        if (std.mem.eql(u8, ext, "diff") or std.mem.eql(u8, ext, "patch")) return .diff;

        return .unknown;
    }
};

/// Kind of code symbol. AST-accurate via tree-sitter.
pub const SymbolKind = enum {
    function,
    method,
    @"struct",
    @"enum",
    @"union",
    trait,
    interface,
    type_alias,
    constant,
    variable,
    import,
    module,
    macro,
    @"test",
    impl,
    class,
    comment,
    unknown,

    pub fn as_str(self: SymbolKind) []const u8 {
        return switch (self) {
            .function => "function",
            .method => "method",
            .@"struct" => "struct",
            .@"enum" => "enum",
            .@"union" => "union",
            .trait => "trait",
            .interface => "interface",
            .type_alias => "type_alias",
            .constant => "constant",
            .variable => "variable",
            .import => "import",
            .module => "module",
            .macro => "macro",
            .@"test" => "test",
            .impl => "impl",
            .class => "class",
            .comment => "comment",
            .unknown => "unknown",
        };
    }
};

/// Who can name a symbol from outside the unit that defines it, read from the
/// definition itself: `pub`, `export`, `public`, a leading capital in Go, a
/// leading underscore in Python.
pub const Visibility = enum(u8) {
    /// The language states nothing the parser reads.
    unknown,
    /// Any other module or package can name it.
    public,
    /// Visible inside its crate, package or assembly only: `pub(crate)`,
    /// `internal`, a Java member with no modifier.
    restricted,
    private,
};

/// Facts about a definition that decide whether code with no reference to it
/// can still reach it.
pub const SymbolFlags = packed struct(u8) {
    /// Satisfies an interface the language dispatches through: a method in
    /// `impl Trait for T` or in a trait, `@Override`, `override`, a Python
    /// dunder method. The caller names the interface, never this symbol.
    implements: bool = false,
    /// Carries an attribute or decorator that hands it to a framework:
    /// `#[tokio::main]`, `@app.route`, `#[no_mangle]`. The framework calls it.
    registered: bool = false,
    _pad: u6 = 0,
};

/// A code symbol extracted from a file.
///
/// `line_start` and `line_end` are 0-BASED, because tree-sitter reports node
/// rows that way and the word index keys its postings the same way; keeping one
/// base internally is what lets `find_callers` compare a symbol range against a
/// word hit directly. Every user-facing number is 1-based instead — editors,
/// `read_file` and the MCP tool output all count from 1. Convert at that
/// boundary with `start_1`/`end_1` rather than adding 1 at each call site, so a
/// reader can tell which base a given expression is in.
pub const Symbol = struct {
    name: []const u8,
    kind: SymbolKind,
    /// 0-based. See the type-level note; use `start_1()` for output.
    line_start: usize,
    /// 0-based, inclusive. See the type-level note; use `end_1()` for output.
    line_end: usize,
    detail: ?[]const u8 = null,
    visibility: Visibility = .unknown,
    flags: SymbolFlags = .{},

    /// First line, 1-based — for output and for comparing against any line
    /// number that was counted from 1 (analysis scans, `write_lines`).
    pub fn start_1(self: Symbol) usize {
        return self.line_start + 1;
    }

    /// Last line, 1-based and inclusive. Counterpart to `start_1`.
    pub fn end_1(self: Symbol) usize {
        return self.line_end + 1;
    }

    /// True when the 1-based `line` falls inside this symbol.
    pub fn contains_1(self: Symbol, line: usize) bool {
        return line >= self.start_1() and line <= self.end_1();
    }

    pub fn deinit(self: *Symbol, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.detail) |d| allocator.free(d);
    }
};

/// How a call names what it calls.
pub const CallKind = enum(u8) {
    /// `name(…)`
    plain,
    /// `receiver.name(…)` or `receiver->name(…)`
    method,
    /// `Type::name(…)`
    path,
};

/// One call site, read from the syntax tree: strings and comments that spell a
/// call are not calls.
pub const Call = struct {
    /// The called name: the last identifier before the argument list.
    name: []const u8,
    /// 0-based line and column of the argument list's opening parenthesis.
    line: u32,
    col: u32 = 0,
    kind: CallKind,
    /// The receiver or qualifier is `self`, `this`, `Self` or `cls`: the call
    /// stays inside the type that makes it.
    self_receiver: bool = false,
    /// The identifier just before the `.` or `::`: `agent` in
    /// `crate::agent::run(…)`, `util` in `util.Do()`. Empty for a plain call.
    /// A slice of `FileOutline.call_names`, like `name`.
    qualifier: []const u8 = "",
    /// The call sits in a function that runs on an event, not when the code
    /// around it runs: an `onClick={() => save()}` attribute, a `setTimeout`
    /// or `addEventListener` callback. A loop that renders a button per row
    /// does not call the button's handler per row.
    deferred: bool = false,
};

/// What a loop repeats over.
pub const LoopKind = enum(u8) {
    /// Once per element of something: `for x in xs`, `for … range`,
    /// `xs.forEach(…)`, a comprehension.
    each,
    /// Until a condition fails: `while cond`, a C-style `for (;;cond;)`.
    conditional,
    /// With no exit in its header: `loop`, `while true`, Go `for {}`.
    forever,
};

/// A loop region, read from the syntax tree.
pub const Loop = struct {
    /// 0-based, inclusive.
    line_start: u32,
    line_end: u32,
    kind: LoopKind,
    /// 0-based position where the repeated part begins. The header before it
    /// runs once: `for x in load_all().await? {` calls `load_all` once.
    body_line: u32 = 0,
    body_col: u32 = 0,

    /// True when the 1-based `line` falls inside this loop.
    pub fn contains_1(self: Loop, line: usize) bool {
        return line >= @as(usize, self.line_start) + 1 and line <= @as(usize, self.line_end) + 1;
    }

    /// True when a position at the 0-based `line` and `col` runs once per
    /// iteration.
    pub fn repeats(self: Loop, line: u32, col: u32) bool {
        if (line < self.line_start or line > self.line_end) return false;
        if (line > self.body_line) return true;
        return line == self.body_line and col >= self.body_col;
    }
};

/// A block of statements or members, read from the syntax tree: a function
/// body, a `{ … }` in Rust or TypeScript, an indented suite in Python. A value
/// bound inside it lives until its last line.
pub const Block = struct {
    /// 0-based, inclusive.
    line_start: u32,
    line_end: u32,
};

/// Structural outline of a single file: symbols, imports, calls, loops.
pub const FileOutline = struct {
    path: []const u8,
    language: Language,
    line_count: usize,
    byte_size: u64,
    symbols: []Symbol,
    imports: [][]const u8,
    /// Call sites in source order. Every `Call.name` is a slice of
    /// `call_names`, so a file's calls cost one allocation for their names.
    calls: []Call = &.{},
    call_names: []u8 = &.{},
    loops: []Loop = &.{},
    blocks: []Block = &.{},

    /// The innermost block that holds the 0-based line.
    pub fn block_at(self: FileOutline, line: u32) ?Block {
        var best: ?Block = null;
        for (self.blocks) |b| {
            if (line < b.line_start or line > b.line_end) continue;
            if (best == null or b.line_start >= best.?.line_start) best = b;
        }
        return best;
    }

    /// The last 0-based line of the block that opens on the 0-based line,
    /// the largest when several do.
    pub fn block_opened_at(self: FileOutline, line: u32) ?u32 {
        var best: ?u32 = null;
        for (self.blocks) |b| {
            if (b.line_start != line) continue;
            if (best == null or b.line_end > best.?) best = b.line_end;
        }
        return best;
    }

    pub fn deinit(self: *FileOutline, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        for (self.symbols) |*s| s.deinit(allocator);
        allocator.free(self.symbols);
        for (self.imports) |i| allocator.free(i);
        allocator.free(self.imports);
        allocator.free(self.calls);
        allocator.free(self.call_names);
        allocator.free(self.loops);
        allocator.free(self.blocks);
    }
};

/// Operation type for change tracking.
pub const ChangeOp = enum {
    added,
    modified,
    deleted,
};

/// A single change record for version tracking.
pub const ChangeRecord = struct {
    seq: u64,
    path: []const u8,
    op: ChangeOp,
    timestamp_ms: i64,

    pub fn deinit(self: *ChangeRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

/// A node in the directory tree view.
pub const TreeNode = struct {
    name: []const u8,
    path: []const u8,
    is_dir: bool,
    children: []TreeNode,
    symbol_count: ?usize = null,
    language: ?Language = null,
    line_count: ?usize = null,

    pub fn deinit(self: *TreeNode, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.path);
        for (self.children) |*c| c.deinit(allocator);
        allocator.free(self.children);
    }
};

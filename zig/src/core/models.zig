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

        if (extension.len == 0) return .unknown;
        const ext = extension[1..]; // skip the dot

        if (std.mem.eql(u8, ext, "rs")) return .rust;
        if (std.mem.eql(u8, ext, "py") or std.mem.eql(u8, ext, "pyi")) return .python;
        if (std.mem.eql(u8, ext, "ts") or std.mem.eql(u8, ext, "tsx")) return .typescript;
        if (std.mem.eql(u8, ext, "js") or std.mem.eql(u8, ext, "jsx") or std.mem.eql(u8, ext, "mjs") or std.mem.eql(u8, ext, "cjs")) return .javascript;
        if (std.mem.eql(u8, ext, "go")) return .go;
        if (std.mem.eql(u8, ext, "sh") or std.mem.eql(u8, ext, "bash")) return .bash;
        if (std.mem.eql(u8, ext, "c")) return .c;
        if (std.mem.eql(u8, ext, "cpp") or std.mem.eql(u8, ext, "cc") or std.mem.eql(u8, ext, "cxx")) return .cpp;
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
        if (std.mem.eql(u8, ext, "nix")) return .nix;
        if (std.mem.eql(u8, ext, "r")) return .r;
        if (std.mem.eql(u8, ext, "scala")) return .scala;
        if (std.mem.eql(u8, ext, "hs")) return .haskell;
        if (std.mem.eql(u8, ext, "ml") or std.mem.eql(u8, ext, "mli")) return .ocaml;
        if (std.mem.eql(u8, ext, "ex") or std.mem.eql(u8, ext, "exs")) return .elixir;
        if (std.mem.eql(u8, ext, "clj")) return .clojure;
        if (std.mem.eql(u8, ext, "dart")) return .dart;
        if (std.mem.eql(u8, ext, "hcl") or std.mem.eql(u8, ext, "tf")) return .hcl;
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
    @"trait",
    interface,
    type_alias,
    constant,
    variable,
    import,
    module,
    @"macro",
    @"test",
    @"impl",
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
            .@"trait" => "trait",
            .interface => "interface",
            .type_alias => "type_alias",
            .constant => "constant",
            .variable => "variable",
            .import => "import",
            .module => "module",
            .@"macro" => "macro",
            .@"test" => "test",
            .@"impl" => "impl",
            .class => "class",
            .comment => "comment",
            .unknown => "unknown",
        };
    }
};

/// A code symbol extracted from a file.
pub const Symbol = struct {
    name: []const u8,
    kind: SymbolKind,
    line_start: usize,
    line_end: usize,
    detail: ?[]const u8 = null,

    pub fn deinit(self: *Symbol, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.detail) |d| allocator.free(d);
    }
};

/// Structural outline of a single file: symbols, imports, metadata.
pub const FileOutline = struct {
    path: []const u8,
    language: Language,
    line_count: usize,
    byte_size: u64,
    symbols: []Symbol,
    imports: [][]const u8,

    pub fn deinit(self: *FileOutline, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        for (self.symbols) |*s| s.deinit(allocator);
        allocator.free(self.symbols);
        for (self.imports) |i| allocator.free(i);
        allocator.free(self.imports);
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

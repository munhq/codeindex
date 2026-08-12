const std = @import("std");
const models = @import("../core/models.zig");
const import_scan = @import("import_scan.zig");
const io = @import("../core/io.zig");

const ts = @cImport({
    @cInclude("tree_sitter/api.h");
});

// Extern declarations for grammars
extern fn tree_sitter_rust() *const anyopaque;
extern fn tree_sitter_python() *const anyopaque;
extern fn tree_sitter_go() *const anyopaque;
extern fn tree_sitter_typescript() *const anyopaque;
extern fn tree_sitter_tsx() *const anyopaque;
extern fn tree_sitter_zig() *const anyopaque;
extern fn tree_sitter_c() *const anyopaque;
extern fn tree_sitter_cpp() *const anyopaque;
extern fn tree_sitter_java() *const anyopaque;
extern fn tree_sitter_ruby() *const anyopaque;
extern fn tree_sitter_bash() *const anyopaque;
extern fn tree_sitter_c_sharp() *const anyopaque;
extern fn tree_sitter_kotlin() *const anyopaque;
extern fn tree_sitter_lua() *const anyopaque;
extern fn tree_sitter_scala() *const anyopaque;
extern fn tree_sitter_elixir() *const anyopaque;
extern fn tree_sitter_r() *const anyopaque;
extern fn tree_sitter_toml() *const anyopaque;
extern fn tree_sitter_json() *const anyopaque;
extern fn tree_sitter_yaml() *const anyopaque;
extern fn tree_sitter_css() *const anyopaque;
extern fn tree_sitter_html() *const anyopaque;
extern fn tree_sitter_hcl() *const anyopaque;
extern fn tree_sitter_dockerfile() *const anyopaque;
extern fn tree_sitter_sql() *const anyopaque;
extern fn tree_sitter_make() *const anyopaque;
extern fn tree_sitter_nix() *const anyopaque;
extern fn tree_sitter_scss() *const anyopaque;
extern fn tree_sitter_swift() *const anyopaque;
extern fn tree_sitter_dart() *const anyopaque;
extern fn tree_sitter_jinja2() *const anyopaque;
extern fn tree_sitter_ini() *const anyopaque;
extern fn tree_sitter_ssh_config() *const anyopaque;
extern fn tree_sitter_git_commit() *const anyopaque;
extern fn tree_sitter_gitignore() *const anyopaque;
extern fn tree_sitter_diff() *const anyopaque;
extern fn tree_sitter_regex() *const anyopaque;
// comment grammar removed (broken scanner includes)
extern fn tree_sitter_haskell() *const anyopaque;
extern fn tree_sitter_markdown() *const anyopaque;
extern fn tree_sitter_solidity() *const anyopaque;
extern fn tree_sitter_proto() *const anyopaque;

// Embed tags.scm queries (symbol extraction)
const rust_tags = @embedFile("../../vendor/grammars/rust/queries/tags.scm");
const python_tags = @embedFile("../../vendor/grammars/python/queries/tags.scm");
const go_tags = @embedFile("../../vendor/grammars/go/queries/tags.scm");
// Custom (vendored typescript tags.scm only matched ambient/.d.ts signatures).
const ts_tags = @embedFile("queries/typescript_tags.scm");
const c_tags = @embedFile("../../vendor/grammars/c/queries/tags.scm");
const cpp_tags = @embedFile("../../vendor/grammars/cpp/queries/tags.scm");
const java_tags = @embedFile("../../vendor/grammars/java/queries/tags.scm");
const ruby_tags = @embedFile("../../vendor/grammars/ruby/queries/tags.scm");
const c_sharp_tags = @embedFile("../../vendor/grammars/c_sharp/queries/tags.scm");
const kotlin_tags = @embedFile("../../vendor/grammars/kotlin/queries/tags.scm");
const lua_tags = @embedFile("../../vendor/grammars/lua/queries/tags.scm");
const scala_tags = @embedFile("../../vendor/grammars/scala/queries/tags.scm");
const elixir_tags = @embedFile("../../vendor/grammars/elixir/queries/tags.scm");
const r_tags = @embedFile("../../vendor/grammars/r/queries/tags.scm");
const swift_tags = @embedFile("../../vendor/grammars/swift/queries/tags.scm");
const nix_tags = @embedFile("queries/nix_tags.scm");

// Custom tags queries written in-tree (upstream grammars ship none). Stored
// under src/parser/queries/ so they are version-controlled and survive a
// vendor re-fetch, unlike the embeds above which come from fetched grammars.
const zig_tags = @embedFile("queries/zig_tags.scm");
const json_tags = @embedFile("queries/json_tags.scm");
const toml_tags = @embedFile("queries/toml_tags.scm");
const yaml_tags = @embedFile("queries/yaml_tags.scm");
const css_tags = @embedFile("queries/css_tags.scm");
const scss_tags = @embedFile("queries/scss_tags.scm");
const html_tags = @embedFile("queries/html_tags.scm");
const sql_tags = @embedFile("queries/sql_tags.scm");
const bash_tags = @embedFile("queries/bash_tags.scm");
const hcl_tags = @embedFile("queries/hcl_tags.scm");
const dockerfile_tags = @embedFile("queries/dockerfile_tags.scm");
const make_tags = @embedFile("queries/make_tags.scm");
const markdown_tags = @embedFile("queries/markdown_tags.scm");
const ini_tags = @embedFile("queries/ini_tags.scm");
const solidity_tags = @embedFile("queries/solidity_tags.scm");
const proto_tags = @embedFile("queries/proto_tags.scm");

pub const Parser = struct {
    allocator: std.mem.Allocator,
    parser: *ts.TSParser,

    pub fn init(allocator: std.mem.Allocator) !Parser {
        const p = ts.ts_parser_new() orelse return error.TSParserInitFailed;
        return Parser{
            .allocator = allocator,
            .parser = p,
        };
    }

    pub fn deinit(self: *Parser) void {
        ts.ts_parser_delete(self.parser);
    }

    pub fn parse_file(self: *Parser, path: []const u8, language: models.Language) !models.FileOutline {
        const content = try io.readFileAlloc(self.allocator, path, 1024 * 1024 * 10); // 10MB limit
        defer self.allocator.free(content);
        return self.parse_source(path, language, content);
    }

    /// Parse already-loaded source. Split out from parse_file so it can be
    /// tested directly with literal source (no temp files).
    pub fn parse_source(self: *Parser, path: []const u8, language: models.Language, content: []const u8) !models.FileOutline {
        const lang = try self.get_ts_language(language);
        if (!ts.ts_parser_set_language(self.parser, @ptrCast(lang))) {
            return error.TSLanguageSetFailed;
        }

        const tree = ts.ts_parser_parse_string(self.parser, null, content.ptr, @intCast(content.len)) orelse return error.TSParseFailed;
        defer ts.ts_tree_delete(tree);

        const root_node = ts.ts_tree_root_node(tree);
        const query_source = self.get_query_source(language);

        var symbols = std.ArrayList(models.Symbol).empty;
        var imports = std.ArrayList([]const u8).empty;
        errdefer {
            for (symbols.items) |*s| s.deinit(self.allocator);
            symbols.deinit(self.allocator);
            for (imports.items) |i| self.allocator.free(i);
            imports.deinit(self.allocator);
        }

        // Fill in imports via regex pre-pass — vendored tags.scm queries don't capture them.
        try import_scan.extract(self.allocator, language, content, &imports);

        if (query_source.len > 0) {
            var error_offset: u32 = 0;
            var error_type: ts.TSQueryError = ts.TSQueryErrorNone;
            const query = ts.ts_query_new(@ptrCast(lang), query_source.ptr, @intCast(query_source.len), &error_offset, &error_type) orelse {
                // A malformed query yields zero symbols silently otherwise — log
                // which language and byte offset failed so it can be fixed.
                std.debug.print(
                    "codeindex: tags query failed to compile for {s} (ts error {d} at byte {d})\n",
                    .{ @tagName(language), error_type, error_offset },
                );
                return self.create_outline(path, language, content, &symbols, &imports);
            };
            defer ts.ts_query_delete(query);

            const cursor = ts.ts_query_cursor_new() orelse return error.TSQueryCursorInitFailed;
            defer ts.ts_query_cursor_delete(cursor);

            ts.ts_query_cursor_exec(cursor, query, root_node);

            var match: ts.TSQueryMatch = undefined;
            while (ts.ts_query_cursor_next_match(cursor, &match)) {
                var current_kind: models.SymbolKind = .unknown;
                var current_name: ?[]const u8 = null;
                var name_node: ?ts.TSNode = null;
                var def_node: ?ts.TSNode = null;

                for (0..match.capture_count) |i| {
                    const capture = match.captures[i];
                    var capture_name_len: u32 = 0;
                    const capture_name_ptr = ts.ts_query_capture_name_for_id(query, capture.index, &capture_name_len);
                    const tag = capture_name_ptr[0..capture_name_len];

                    if (std.mem.eql(u8, tag, "name")) {
                        const start_byte = ts.ts_node_start_byte(capture.node);
                        const end_byte = ts.ts_node_end_byte(capture.node);
                        var nm = content[start_byte..end_byte];
                        // Strip surrounding quotes from string-based labels
                        // (HCL block labels, etc.) so symbols read cleanly.
                        if (nm.len >= 2 and nm[0] == '"' and nm[nm.len - 1] == '"') nm = nm[1 .. nm.len - 1];
                        current_name = nm;
                        name_node = capture.node;
                    } else if (std.mem.startsWith(u8, tag, "definition.")) {
                        const kind_str = tag["definition.".len..];
                        current_kind = self.map_kind(kind_str);
                        def_node = capture.node;
                    } else if (std.mem.startsWith(u8, tag, "reference.import")) {
                        const start_byte = ts.ts_node_start_byte(capture.node);
                        const end_byte = ts.ts_node_end_byte(capture.node);
                        try imports.append(self.allocator, try self.allocator.dupe(u8, content[start_byte..end_byte]));
                    }
                }

                // Only emit *definitions*. Tags queries also carry @reference.*
                // patterns (call-sites, import targets) for call-graph use; those
                // have a @name but no @definition, and must not become symbols.
                if (def_node) |node| {
                    if (current_name) |name| {
                        const line_start: usize = ts.ts_node_start_point(node).row;
                        // Dedupe: the same definition can match multiple patterns.
                        var dup = false;
                        for (symbols.items) |s| {
                            if (s.line_start == line_start and std.mem.eql(u8, s.name, name)) {
                                dup = true;
                                break;
                            }
                        }
                        if (!dup) {
                            try symbols.append(self.allocator, models.Symbol{
                                .name = try self.allocator.dupe(u8, name),
                                .kind = current_kind,
                                .line_start = line_start,
                                .line_end = ts.ts_node_end_point(node).row,
                            });
                        }
                    }
                }
            }
        }

        return self.create_outline(path, language, content, &symbols, &imports);
    }

    fn map_kind(self: *Parser, kind_str: []const u8) models.SymbolKind {
        _ = self;
        if (std.mem.eql(u8, kind_str, "function")) return .function;
        if (std.mem.eql(u8, kind_str, "method")) return .method;
        if (std.mem.eql(u8, kind_str, "class") or std.mem.eql(u8, kind_str, "interface")) return .class;
        if (std.mem.eql(u8, kind_str, "struct")) return .@"struct";
        if (std.mem.eql(u8, kind_str, "enum")) return .@"enum";
        if (std.mem.eql(u8, kind_str, "macro")) return .macro;
        if (std.mem.eql(u8, kind_str, "module")) return .module;
        if (std.mem.eql(u8, kind_str, "constant")) return .constant;
        if (std.mem.eql(u8, kind_str, "variable")) return .variable;
        if (std.mem.eql(u8, kind_str, "type")) return .type_alias;
        if (std.mem.eql(u8, kind_str, "impl") or std.mem.eql(u8, kind_str, "implementation")) return .impl;
        if (std.mem.eql(u8, kind_str, "union")) return .@"union";
        if (std.mem.eql(u8, kind_str, "trait")) return .trait;
        if (std.mem.eql(u8, kind_str, "test")) return .@"test";
        if (std.mem.eql(u8, kind_str, "import") or std.mem.eql(u8, kind_str, "use")) return .import;
        return .unknown;
    }

    fn create_outline(self: *Parser, path: []const u8, language: models.Language, content: []const u8, symbols: *std.ArrayList(models.Symbol), imports: *std.ArrayList([]const u8)) !models.FileOutline {
        return models.FileOutline{
            .path = try self.allocator.dupe(u8, path),
            .language = language,
            .line_count = std.mem.count(u8, content, "\n") + 1,
            .byte_size = content.len,
            .symbols = try symbols.toOwnedSlice(self.allocator),
            .imports = try imports.toOwnedSlice(self.allocator),
        };
    }

    fn get_ts_language(self: *Parser, language: models.Language) !*const anyopaque {
        _ = self;
        return switch (language) {
            .rust => tree_sitter_rust(),
            .python => tree_sitter_python(),
            .go => tree_sitter_go(),
            .typescript, .javascript => tree_sitter_typescript(),
            .zig => tree_sitter_zig(),
            .c => tree_sitter_c(),
            .cpp => tree_sitter_cpp(),
            .java => tree_sitter_java(),
            .ruby => tree_sitter_ruby(),
            .bash => tree_sitter_bash(),
            .c_sharp => tree_sitter_c_sharp(),
            .kotlin => tree_sitter_kotlin(),
            .lua => tree_sitter_lua(),
            .scala => tree_sitter_scala(),
            .elixir => tree_sitter_elixir(),
            .r => tree_sitter_r(),
            .toml => tree_sitter_toml(),
            .json => tree_sitter_json(),
            .yaml => tree_sitter_yaml(),
            .css => tree_sitter_css(),
            .html => tree_sitter_html(),
            .hcl => tree_sitter_hcl(),
            .dockerfile => tree_sitter_dockerfile(),
            .sql => tree_sitter_sql(),
            .make => tree_sitter_make(),
            .nix => tree_sitter_nix(),
            .scss => tree_sitter_scss(),
            .swift => tree_sitter_swift(),
            .dart => tree_sitter_dart(),
            .jinja2 => tree_sitter_jinja2(),
            .ini => tree_sitter_ini(),
            .diff => tree_sitter_diff(),
            .gitignore => tree_sitter_gitignore(),
            .haskell => tree_sitter_haskell(),
            .markdown => tree_sitter_markdown(),
            .solidity => tree_sitter_solidity(),
            .protobuf => tree_sitter_proto(),
            else => return error.UnsupportedLanguage,
        };
    }

    fn get_query_source(self: *Parser, language: models.Language) []const u8 {
        _ = self;
        return switch (language) {
            .rust => rust_tags,
            .python => python_tags,
            .go => go_tags,
            .typescript, .javascript => ts_tags,
            .c => c_tags,
            .cpp => cpp_tags,
            .java => java_tags,
            .ruby => ruby_tags,
            .c_sharp => c_sharp_tags,
            .kotlin => kotlin_tags,
            .lua => lua_tags,
            .scala => scala_tags,
            .elixir => elixir_tags,
            .r => r_tags,
            .swift => swift_tags,
            .dart => @embedFile("../../vendor/grammars/dart/queries/tags.scm"),
            .nix => nix_tags,
            // Custom in-tree queries (upstream grammars ship no tags.scm).
            .zig => zig_tags,
            .json => json_tags,
            .toml => toml_tags,
            .yaml => yaml_tags,
            .css => css_tags,
            .scss => scss_tags,
            .html => html_tags,
            .sql => sql_tags,
            .bash => bash_tags,
            .hcl => hcl_tags,
            .dockerfile => dockerfile_tags,
            .make => make_tags,
            .markdown => markdown_tags,
            .ini => ini_tags,
            .solidity => solidity_tags,
            .protobuf => proto_tags,
            // Text-only indexing (have parser but no tags.scm)
            .haskell, .jinja2, .diff, .gitignore => "",
            else => "",
        };
    }
};

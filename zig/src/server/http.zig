const std = @import("std");
const explorer = @import("../index/explorer.zig");
const models = @import("../core/models.zig");
const security_scan = @import("../analysis/security_scan.zig");
const unwrap_audit = @import("../analysis/unwrap_audit.zig");
const dead_code = @import("../analysis/dead_code.zig");
const test_coverage = @import("../analysis/test_coverage.zig");
const architecture = @import("../analysis/architecture.zig");
const crossref = @import("../analysis/crossref.zig");
const type_drift = @import("../analysis/type_drift.zig");
const db_schema = @import("../analysis/db_schema.zig");
const migration_parity = @import("../analysis/migration_parity.zig");
const manifest_compliance = @import("../analysis/manifest_compliance.zig");

const treesitter = @import("../parser/treesitter.zig");
const filter_mod = @import("../core/filter.zig");

pub const Server = struct {
    allocator: std.mem.Allocator,
    exp: *explorer.Explorer,
    parser: ?*treesitter.Parser = null,
    filter: ?*filter_mod.Filter = null,

    pub fn init(allocator: std.mem.Allocator, exp: *explorer.Explorer) Server {
        return .{ .allocator = allocator, .exp = exp };
    }

    pub fn with_parser(self: *Server, p: *treesitter.Parser, f: *filter_mod.Filter) void {
        self.parser = p;
        self.filter = f;
    }

    pub fn run_mcp(self: *Server) !void {
        const stdin_file = std.fs.File.stdin();
        const stdout_file = std.fs.File.stdout();

        var read_buf: [1024 * 1024]u8 = undefined;
        var carry = std.ArrayList(u8){};
        defer carry.deinit(self.allocator);

        while (true) {
            const n = stdin_file.read(&read_buf) catch break;
            if (n == 0) break; // EOF

            try carry.appendSlice(self.allocator, read_buf[0..n]);

            // Process complete lines
            while (std.mem.indexOf(u8, carry.items, "\n")) |nl_pos| {
                const line = carry.items[0..nl_pos];
                defer {
                    // Remove processed line + newline from carry
                    const remaining = carry.items[nl_pos + 1 ..];
                    std.mem.copyForwards(u8, carry.items[0..remaining.len], remaining);
                    carry.items.len = remaining.len;
                }

                if (line.len == 0) continue;

                const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch continue;
                defer parsed.deinit();

                const obj = parsed.value.object;
                const method_val = obj.get("method") orelse continue;
                const method = method_val.string;
                const id = obj.get("id");

                if (std.mem.eql(u8, method, "initialize")) {
                    var buf = std.ArrayList(u8){};
                    defer buf.deinit(self.allocator);
                    const bw = buf.writer(self.allocator);
                    try bw.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
                    try write_id(bw, id);
                    try bw.writeAll(",\"result\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"codeindex-zig\",\"version\":\"0.1.0\"}}}\n");
                    try stdout_file.writeAll(buf.items);
                } else if (std.mem.eql(u8, method, "notifications/initialized")) {
                    // No response needed
                } else if (std.mem.eql(u8, method, "tools/list")) {
                    try self.write_tools_list(stdout_file, id);
                } else if (std.mem.eql(u8, method, "tools/call")) {
                    const params = obj.get("params") orelse continue;
                    const tool_name = (params.object.get("name") orelse continue).string;
                    const arguments = params.object.get("arguments");
                    try self.handle_tool_call(stdout_file, id, tool_name, arguments);
                }
            }
        }
    }

    fn handle_tool_call(self: *Server, writer: anytype, id: ?std.json.Value, tool: []const u8, args: ?std.json.Value) !void {
        // Wait for indexing to complete before processing query tools
        if (!std.mem.eql(u8, tool, "status")) {
            while (self.exp.is_indexing()) {
                std.Thread.sleep(100 * std.time.ns_per_ms);
            }
        }

        var out = std.ArrayList(u8){};
        defer out.deinit(self.allocator);
        const w = out.writer(self.allocator);

        if (std.mem.eql(u8, tool, "status")) {
            // Calculate token savings stats
            // Naive approach: cat all files = total bytes / 4 (rough tokens estimate)
            // Codeindex: outline = ~10 tokens/symbol, search result = ~20 tokens/hit
            const total_bytes = self.exp.total_content_bytes();
            const total_lines = self.exp.total_line_count();
            const naive_tokens = total_bytes / 4; // ~4 chars per token estimate
            const outline_tokens = self.exp.symbol_count() * 10; // ~10 tokens per symbol in outline
            const savings_pct: u64 = if (naive_tokens > 0) 100 - (outline_tokens * 100 / naive_tokens) else 0;

            try w.print("{{\"files\":{d},\"symbols\":{d},\"indexing\":{s},\"latest_seq\":{d},\"total_lines\":{d},\"total_bytes\":{d},\"naive_tokens\":{d},\"outline_tokens\":{d},\"savings_pct\":{d},\"watcher\":true}}", .{
                self.exp.file_count(),
                self.exp.symbol_count(),
                if (self.exp.is_indexing()) "true" else "false",
                self.exp.latest_seq(),
                total_lines,
                total_bytes,
                naive_tokens,
                outline_tokens,
                savings_pct,
            });
        } else if (std.mem.eql(u8, tool, "search")) {
            const query = get_string_arg(args, "query") orelse "";
            const limit = get_int_arg(args, "limit") orelse 50;
            if (query.len == 0) {
                try w.writeAll("No query provided.");
            } else {
                const results = try self.exp.search_content(query, limit);
                defer self.allocator.free(results);
                if (results.len == 0) {
                    try w.writeAll("No results found.");
                } else {
                    for (results) |r| {
                        if (r.scope_name) |scope| {
                            try w.print("{s}:{d} [{s}:{s}] — {s}\n", .{
                                r.path, r.line_num,
                                if (r.scope_kind) |k| k.as_str() else "?", scope,
                                std.mem.trim(u8, r.line_text, " \t\r"),
                            });
                        } else {
                            try w.print("{s}:{d} — {s}\n", .{
                                r.path, r.line_num,
                                std.mem.trim(u8, r.line_text, " \t\r"),
                            });
                        }
                    }
                }
            }
        } else if (std.mem.eql(u8, tool, "find_symbol")) {
            const name = get_string_arg(args, "name") orelse "";
            const limit = get_int_arg(args, "limit") orelse 50;
            if (name.len == 0) {
                try w.writeAll("No name provided.");
            } else {
                const results = try self.exp.find_symbol(name, limit);
                defer self.allocator.free(results);
                if (results.len == 0) {
                    try w.writeAll("No symbols found.");
                } else {
                    for (results) |r| {
                        try w.print("{s}:{d}-{d} {s} {s}\n", .{
                            r.path,
                            r.symbol.line_start,
                            r.symbol.line_end,
                            r.symbol.kind.as_str(),
                            r.symbol.name,
                        });
                    }
                }
            }
        } else if (std.mem.eql(u8, tool, "find_word")) {
            const word = get_string_arg(args, "word") orelse "";
            const limit = get_int_arg(args, "limit") orelse 50;
            if (word.len == 0) {
                try w.writeAll("No word provided.");
            } else {
                const results = try self.exp.find_word(word, limit);
                defer self.allocator.free(results);
                if (results.len == 0) {
                    try w.writeAll("No occurrences found.");
                } else {
                    for (results) |r| {
                        try w.print("{s}:{d}\n", .{ r.path, r.line_num });
                    }
                }
            }
        } else if (std.mem.eql(u8, tool, "get_outline")) {
            const path = get_string_arg(args, "path") orelse "";
            if (self.exp.get_outline(path)) |outline| {
                try w.print("{{\"path\":\"{s}\",\"language\":\"{s}\",\"line_count\":{d},\"byte_size\":{d},\"symbols\":[", .{
                    outline.path,
                    @tagName(outline.language),
                    outline.line_count,
                    outline.byte_size,
                });
                for (outline.symbols, 0..) |sym, i| {
                    if (i > 0) try w.writeAll(",");
                    try w.print("{{\"name\":\"{s}\",\"kind\":\"{s}\",\"line_start\":{d},\"line_end\":{d}}}", .{
                        sym.name, sym.kind.as_str(), sym.line_start, sym.line_end,
                    });
                }
                try w.writeAll("]}");
            } else {
                try w.print("No outline found for: {s}", .{path});
            }
        } else if (std.mem.eql(u8, tool, "get_tree")) {
            const tree = try self.exp.get_tree();
            defer {
                for (tree) |*node| {
                    var n = node.*;
                    n.deinit(self.allocator);
                }
                self.allocator.free(tree);
            }
            try w.writeAll("[");
            for (tree, 0..) |node, i| {
                if (i > 0) try w.writeAll(",");
                try w.print("{{\"name\":\"{s}\",\"path\":\"{s}\",\"symbols\":{d},\"language\":\"{s}\",\"lines\":{d}}}", .{
                    node.name,
                    node.path,
                    node.symbol_count orelse 0,
                    if (node.language) |l| @tagName(l) else "unknown",
                    node.line_count orelse 0,
                });
            }
            try w.writeAll("]");
        } else if (std.mem.eql(u8, tool, "get_imports")) {
            const path = get_string_arg(args, "path") orelse "";
            const ids = self.exp.get_imports(path);
            if (ids.len == 0) {
                try w.writeAll("No imports found.");
            } else {
                for (ids) |fid| {
                    if (self.exp.file_path(fid)) |p| {
                        try w.print("{s}\n", .{p});
                    }
                }
            }
        } else if (std.mem.eql(u8, tool, "get_imported_by")) {
            const path = get_string_arg(args, "path") orelse "";
            const ids = self.exp.get_imported_by(path);
            if (ids.len == 0) {
                try w.writeAll("No reverse dependencies found.");
            } else {
                for (ids) |fid| {
                    if (self.exp.file_path(fid)) |p| {
                        try w.print("{s}\n", .{p});
                    }
                }
            }
        } else if (std.mem.eql(u8, tool, "get_change_impact")) {
            const path = get_string_arg(args, "path") orelse "";
            const max_depth = @as(usize, @intCast(get_int_arg(args, "max_depth") orelse 10));
            if (path.len == 0) {
                try w.writeAll("No path provided.");
            } else {
                const impact = try self.exp.get_change_impact(path, max_depth);
                defer {
                    self.allocator.free(impact.direct);
                    self.allocator.free(impact.transitive);
                }
                try w.print("# Change impact for {s}\n", .{path});
                try w.print("Direct dependents: {d}, Total affected: {d}, Max depth: {d}\n\n", .{
                    impact.direct.len,
                    impact.transitive.len,
                    impact.depth_reached,
                });
                if (impact.direct.len > 0) {
                    try w.writeAll("## Direct (depth 1)\n");
                    for (impact.direct) |fid| {
                        if (self.exp.file_path(fid)) |p| {
                            try w.print("  {s}\n", .{p});
                        }
                    }
                }
                if (impact.transitive.len > impact.direct.len) {
                    try w.writeAll("\n## Transitive\n");
                    for (impact.transitive) |fid| {
                        // Skip direct deps (already printed)
                        var is_direct = false;
                        for (impact.direct) |did| {
                            if (fid == did) {
                                is_direct = true;
                                break;
                            }
                        }
                        if (!is_direct) {
                            if (self.exp.file_path(fid)) |p| {
                                try w.print("  {s}\n", .{p});
                            }
                        }
                    }
                }
                if (impact.transitive.len == 0) {
                    try w.writeAll("No dependents found — this file is a leaf.");
                }
            }
        } else if (std.mem.eql(u8, tool, "get_hot_files")) {
            const limit = get_int_arg(args, "limit") orelse 20;
            const files = self.exp.get_hot_files(limit);
            if (files.len == 0) {
                try w.writeAll("No change history.");
            } else {
                // Return newest first
                var i: usize = files.len;
                while (i > 0) {
                    i -= 1;
                    try w.print("{s} — {s} (seq {d})\n", .{
                        files[i].path,
                        @tagName(files[i].op),
                        files[i].seq,
                    });
                }
            }
        } else if (std.mem.eql(u8, tool, "index_workspace")) {
            const path = get_string_arg(args, "path");
            if (path != null and self.parser != null and self.filter != null) {
                // Clear the active explorer and re-index the new path
                self.exp.deinit();
                self.exp.* = explorer.Explorer.init(self.allocator);

                var dir = std.fs.cwd().openDir(path.?, .{ .iterate = true }) catch {
                    try w.print("Directory not found: {s}", .{path.?});
                    try self.write_tool_result(writer, id, out.items, true);
                    return;
                };
                defer dir.close();
                var dir_walker = dir.walk(self.allocator) catch {
                    try w.writeAll("Failed to walk directory");
                    try self.write_tool_result(writer, id, out.items, true);
                    return;
                };
                defer dir_walker.deinit();

                var count: usize = 0;
                while (dir_walker.next() catch null) |entry| {
                    if (entry.kind != .file) continue;
                    if (self.filter.?.should_ignore(entry.path)) continue;
                    const language = models.Language.from_path(entry.path);
                    if (language == .unknown) continue;

                    const f_file = entry.dir.openFile(entry.basename, .{}) catch continue;
                    defer f_file.close();
                    const content = f_file.readToEndAlloc(self.allocator, 10 * 1024 * 1024) catch continue;
                    defer self.allocator.free(content);

                    const full_path = std.fs.path.join(self.allocator, &.{ path.?, entry.path }) catch continue;
                    defer self.allocator.free(full_path);

                    const outline = self.parser.?.parse_file(full_path, language) catch {
                        _ = self.exp.add_file(.{
                            .path = self.allocator.dupe(u8, entry.path) catch continue,
                            .language = language,
                            .line_count = std.mem.count(u8, content, "\n") + 1,
                            .byte_size = content.len,
                            .symbols = &[_]models.Symbol{},
                            .imports = &[_][]const u8{},
                        }, content) catch continue;
                        count += 1;
                        continue;
                    };
                    _ = self.exp.add_file(outline, content) catch continue;
                    count += 1;
                }
                self.exp.mark_indexing_complete();
                try w.print("Indexed {d} files — {d} symbols across {d} files", .{
                    count, self.exp.symbol_count(), self.exp.file_count(),
                });
            } else {
                try w.print("Indexed {d} files — {d} symbols", .{
                    self.exp.file_count(), self.exp.symbol_count(),
                });
            }
        } else if (std.mem.eql(u8, tool, "analyze")) {
            const analysis_type = get_string_arg(args, "analysis") orelse "";
            if (std.mem.eql(u8, analysis_type, "security")) {
                const findings = try security_scan.scan(self.allocator, self.exp);
                defer self.allocator.free(findings);
                const summary = security_scan.summarize(findings);
                try w.print("{{\"total\":{d},\"critical\":{d},\"high\":{d},\"medium\":{d},\"low\":{d},\"findings\":[", .{
                    summary.total, summary.critical, summary.high, summary.medium, summary.low,
                });
                for (findings, 0..) |f, fi| {
                    if (fi > 0) try w.writeAll(",");
                    try w.print("{{\"file\":\"{s}\",\"line\":{d},\"rule\":\"{s}\",\"severity\":\"{s}\"}}", .{
                        f.file, f.line, f.rule, f.severity.as_str(),
                    });
                }
                try w.writeAll("]}");
            } else if (std.mem.eql(u8, analysis_type, "dead_code")) {
                const symbols = try dead_code.find_dead_code(self.allocator, self.exp);
                defer self.allocator.free(symbols);
                try w.print("{{\"dead_count\":{d},\"symbols\":[", .{symbols.len});
                for (symbols, 0..) |s, si| {
                    if (si > 0) try w.writeAll(",");
                    try w.print("{{\"name\":\"{s}\",\"kind\":\"{s}\",\"file\":\"{s}\",\"line\":{d}}}", .{
                        s.name, s.kind.as_str(), s.file, s.line,
                    });
                }
                try w.writeAll("]}");
            } else if (std.mem.eql(u8, analysis_type, "unwrap_audit")) {
                const findings = try unwrap_audit.audit(self.allocator, self.exp);
                defer self.allocator.free(findings);
                try w.print("{{\"total\":{d},\"findings\":[", .{findings.len});
                for (findings, 0..) |f, fi| {
                    if (fi > 0) try w.writeAll(",");
                    try w.print("{{\"file\":\"{s}\",\"line\":{d},\"kind\":\"{s}\",\"severity\":\"{s}\"}}", .{
                        f.file, f.line, f.kind.as_str(), f.severity.as_str(),
                    });
                }
                try w.writeAll("]}");
            } else if (std.mem.eql(u8, analysis_type, "test_coverage")) {
                const modules = try test_coverage.analyze(self.allocator, self.exp);
                defer self.allocator.free(modules);
                try w.print("{{\"modules\":[", .{});
                for (modules, 0..) |m, mi| {
                    if (mi > 0) try w.writeAll(",");
                    try w.print("{{\"file\":\"{s}\",\"symbols\":{d},\"tests\":{d},\"coverage\":\"{s}\"}}", .{
                        m.file, m.total_symbols, m.test_symbols, m.coverage_level.as_str(),
                    });
                }
                try w.writeAll("]}");
            } else if (std.mem.eql(u8, analysis_type, "architecture")) {
                const violations = try architecture.analyze(self.allocator, self.exp);
                defer self.allocator.free(violations);
                try w.print("{{\"violations\":{d},\"details\":[", .{violations.len});
                for (violations, 0..) |v, vi| {
                    if (vi > 0) try w.writeAll(",");
                    try w.print("{{\"from\":\"{s}\",\"to\":\"{s}\",\"from_layer\":\"{s}\",\"to_layer\":\"{s}\"}}", .{
                        v.from_file, v.to_file, v.from_layer, v.to_layer,
                    });
                }
                try w.writeAll("]}");
            } else if (std.mem.eql(u8, analysis_type, "crossref")) {
                const report = try crossref.analyze(self.allocator, self.exp);
                defer self.allocator.free(report.wired);
                defer self.allocator.free(report.backend_only);
                defer self.allocator.free(report.frontend_only);
                try w.print("{{\"wired\":{d},\"backend_only\":{d},\"frontend_only\":{d}}}", .{
                    report.wired_count, report.backend_only_count, report.frontend_only_count,
                });
            } else if (std.mem.eql(u8, analysis_type, "type_drift")) {
                const report = try type_drift.analyze(self.allocator, self.exp);
                defer self.allocator.free(report.mismatches);
                defer self.allocator.free(report.missing_fields);
                try w.print("{{\"types_found\":{d},\"mismatches\":{d},\"missing_fields\":{d}}}", .{
                    report.types_found, report.mismatches.len, report.missing_fields.len,
                });
            } else if (std.mem.eql(u8, analysis_type, "db_schema")) {
                const report = try db_schema.analyze(self.allocator, self.exp);
                defer self.allocator.free(report.issues);
                try w.print("{{\"tables_in_migrations\":{d},\"tables_in_code\":{d},\"issues\":{d}}}", .{
                    report.tables_in_migrations, report.tables_in_code, report.issues.len,
                });
            } else if (std.mem.eql(u8, analysis_type, "migration_parity")) {
                const report = try migration_parity.analyze(self.allocator, self.exp);
                defer self.allocator.free(report.issues);
                try w.print("{{\"total_migrations\":{d},\"issues\":{d}}}", .{
                    report.total_migrations, report.issues.len,
                });
            } else if (std.mem.eql(u8, analysis_type, "manifest_compliance")) {
                const report = try manifest_compliance.analyze(self.allocator, self.exp);
                defer self.allocator.free(report.violations);
                try w.print("{{\"manifests_checked\":{d},\"violations\":{d}}}", .{
                    report.manifests_checked, report.violations.len,
                });
            } else {
                try w.print("Unknown analysis: {s}. Available: security, dead_code, unwrap_audit, test_coverage, architecture, crossref, type_drift, db_schema, migration_parity, manifest_compliance", .{analysis_type});
            }
        } else if (std.mem.eql(u8, tool, "read_file")) {
            const path = get_string_arg(args, "path") orelse "";
            if (path.len == 0) {
                try w.writeAll("No path provided.");
            } else {
                const file_id = self.exp.file_map.get(path);
                if (file_id == null) {
                    // Try matching with ./ prefix
                    var prefixed: [1024]u8 = undefined;
                    const plen = std.fmt.count("./{s}", .{path});
                    const alt = if (plen <= prefixed.len) std.fmt.bufPrint(&prefixed, "./{s}", .{path}) catch null else null;
                    const fid = if (alt) |a| self.exp.file_map.get(a) else null;
                    if (fid) |resolved_id| {
                        try self.write_file_content(w, resolved_id, args);
                    } else {
                        try w.print("File not found in index: {s}", .{path});
                    }
                } else {
                    try self.write_file_content(w, file_id.?, args);
                }
            }
        } else if (std.mem.eql(u8, tool, "read_symbol")) {
            const name = get_string_arg(args, "name") orelse "";
            const path_filter = get_string_arg(args, "path");
            const context_lines = get_int_arg(args, "context") orelse 0;
            if (name.len == 0) {
                try w.writeAll("No symbol name provided.");
            } else {
                const results = try self.exp.find_symbol(name, 10);
                defer self.allocator.free(results);
                if (results.len == 0) {
                    try w.print("Symbol not found: {s}", .{name});
                } else {
                    // Find best match — prefer exact name match, then filter by path
                    var best: ?usize = null;
                    for (results, 0..) |r, i| {
                        if (path_filter) |pf| {
                            if (std.mem.indexOf(u8, r.path, pf) == null) continue;
                        }
                        if (std.mem.eql(u8, r.symbol.name, name)) {
                            best = i;
                            break;
                        }
                        if (best == null) best = i;
                    }
                    if (best) |idx| {
                        const r = results[idx];
                        const file_id = self.exp.file_map.get(r.path);
                        if (file_id) |fid| {
                            const content = self.exp.content_cache.get(fid);
                            if (content) |c| {
                                const start = if (r.symbol.line_start > context_lines) r.symbol.line_start - context_lines else 1;
                                const end = r.symbol.line_end + context_lines;
                                try w.print("# {s} ({s}) in {s}\n", .{ r.symbol.name, r.symbol.kind.as_str(), r.path });
                                try self.write_lines(w, c, start, end);
                            } else {
                                try w.print("Content not cached for: {s}", .{r.path});
                            }
                        } else {
                            try w.print("File ID not found for: {s}", .{r.path});
                        }
                    } else {
                        try w.print("Symbol '{s}' found but not in path '{s}'", .{ name, path_filter orelse "" });
                    }
                }
            }
        } else {
            try w.print("Unknown tool: {s}", .{tool});
        }

        try self.write_tool_result(writer, id, out.items, false);
    }

    fn write_file_content(self: *Server, w: anytype, file_id: u32, args: ?std.json.Value) !void {
        const content = self.exp.content_cache.get(file_id) orelse {
            try w.writeAll("Content not cached for this file.");
            return;
        };
        const start_line = @as(usize, @intCast(get_int_arg(args, "start_line") orelse 1));
        const end_line_arg = get_int_arg(args, "end_line");
        const end_line: usize = if (end_line_arg) |e| @intCast(e) else std.math.maxInt(usize);
        try self.write_lines(w, content, start_line, end_line);
    }

    fn write_lines(_: *Server, w: anytype, content: []const u8, start: usize, end: usize) !void {
        var line_num: usize = 1;
        var line_it = std.mem.splitScalar(u8, content, '\n');
        while (line_it.next()) |line| {
            if (line_num >= start and line_num <= end) {
                try w.print("{d}\t{s}\n", .{ line_num, line });
            }
            if (line_num > end) break;
            line_num += 1;
        }
    }

    fn write_tool_result(self: *Server, file: std.fs.File, id: ?std.json.Value, text: []const u8, is_error: bool) !void {
        // Build the full response into a buffer, then write it atomically
        var buf = std.ArrayList(u8){};
        defer buf.deinit(self.allocator);
        const bw = buf.writer(self.allocator);

        try bw.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
        try write_id(bw, id);
        try bw.writeAll(",\"result\":{\"content\":[{\"type\":\"text\",\"text\":");
        try write_json_string(bw, text);
        try bw.writeAll("}],\"isError\":");
        try bw.writeAll(if (is_error) "true" else "false");
        try bw.writeAll("}}\n");

        try file.writeAll(buf.items);
    }

    fn write_response(self: *Server, file: std.fs.File, id: ?std.json.Value, result: anytype) !void {
        var buf = std.ArrayList(u8){};
        defer buf.deinit(self.allocator);
        const bw = buf.writer(self.allocator);

        try bw.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
        try write_id(bw, id);
        try bw.print(",\"result\":{f}}}\n", .{std.json.fmt(result, .{})});

        try file.writeAll(buf.items);
    }

    fn write_tools_list(self: *Server, file: std.fs.File, id: ?std.json.Value) !void {
        var buf = std.ArrayList(u8){};
        defer buf.deinit(self.allocator);
        const bw = buf.writer(self.allocator);

        try bw.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
        try write_id(bw, id);
        try bw.writeAll(",\"result\":{\"tools\":[");
        const tool_defs = [_][]const u8{
            // status — no params
            "{\"name\":\"status\",\"description\":\"Get index status: file count, symbol count, indexing state\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}",
            // search
            "{\"name\":\"search\",\"description\":\"Search file contents using trigram-accelerated full-text search\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\",\"description\":\"Search query string\"},\"limit\":{\"type\":\"integer\",\"description\":\"Max results (default 50)\"}},\"required\":[\"query\"]}}",
            // find_symbol
            "{\"name\":\"find_symbol\",\"description\":\"Find symbol definitions (functions, structs, classes, etc.) by name across all indexed files\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\",\"description\":\"Symbol name to search for\"},\"limit\":{\"type\":\"integer\",\"description\":\"Max results (default 50)\"}},\"required\":[\"name\"]}}",
            // find_word
            "{\"name\":\"find_word\",\"description\":\"Look up an exact word/identifier in the inverted word index\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"word\":{\"type\":\"string\",\"description\":\"Exact word/identifier to find\"},\"limit\":{\"type\":\"integer\",\"description\":\"Max results (default 50)\"}},\"required\":[\"word\"]}}",
            // get_outline
            "{\"name\":\"get_outline\",\"description\":\"Get the structural outline (symbols, line counts) of a specific file\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"File path relative to workspace root\"}},\"required\":[\"path\"]}}",
            // get_tree — no params
            "{\"name\":\"get_tree\",\"description\":\"Get the directory tree of the indexed workspace with file metadata\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}",
            // get_imports
            "{\"name\":\"get_imports\",\"description\":\"Get which files the given file imports/depends on\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"File path relative to workspace root\"}},\"required\":[\"path\"]}}",
            // get_imported_by
            "{\"name\":\"get_imported_by\",\"description\":\"Get which files import/depend on the given file (reverse dependencies)\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"File path relative to workspace root\"}},\"required\":[\"path\"]}}",
            // get_hot_files
            "{\"name\":\"get_hot_files\",\"description\":\"Get recently changed files sorted by recency\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"limit\":{\"type\":\"integer\",\"description\":\"Max results (default 20)\"}}}}",
            // index_workspace
            "{\"name\":\"index_workspace\",\"description\":\"Index or re-index a workspace directory\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"Directory path to index\"}},\"required\":[\"path\"]}}",
            // analyze
            "{\"name\":\"analyze\",\"description\":\"Run code analysis. Types: security, dead_code, unwrap_audit, test_coverage, architecture, crossref, type_drift, db_schema, migration_parity, manifest_compliance\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"analysis\":{\"type\":\"string\",\"description\":\"Analysis type: security, dead_code, unwrap_audit, test_coverage, architecture, crossref, type_drift, db_schema, migration_parity, manifest_compliance\"}},\"required\":[\"analysis\"]}}",
            // read_file
            "{\"name\":\"read_file\",\"description\":\"Read file contents with optional line range. Returns content with line numbers.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"File path relative to workspace root\"},\"start_line\":{\"type\":\"integer\",\"description\":\"Start line (1-based, default 1)\"},\"end_line\":{\"type\":\"integer\",\"description\":\"End line (inclusive, default: end of file)\"}},\"required\":[\"path\"]}}",
            // read_symbol
            "{\"name\":\"read_symbol\",\"description\":\"Read the source code of a specific symbol (function, struct, etc). Returns the symbol's code with line numbers.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\",\"description\":\"Symbol name to read\"},\"path\":{\"type\":\"string\",\"description\":\"File path to disambiguate (optional)\"},\"context\":{\"type\":\"integer\",\"description\":\"Extra context lines before/after (default 0)\"}},\"required\":[\"name\"]}}",
            // get_change_impact
            "{\"name\":\"get_change_impact\",\"description\":\"Show what breaks if a file changes. Follows the full reverse dependency chain transitively.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"File path to analyze impact for\"},\"max_depth\":{\"type\":\"integer\",\"description\":\"Max traversal depth (default 10)\"}},\"required\":[\"path\"]}}",
        };
        for (tool_defs, 0..) |def, i| {
            if (i > 0) try bw.writeAll(",");
            try bw.writeAll(def);
        }
        try bw.writeAll("]}}\n");

        try file.writeAll(buf.items);
    }
};

// ── Helpers ──────────────────────────────────────────────────────────────────

fn write_id(writer: anytype, id: ?std.json.Value) !void {
    if (id) |id_val| {
        switch (id_val) {
            .integer => |n| try writer.print("{d}", .{n}),
            .string => |s| try writer.print("\"{s}\"", .{s}),
            else => try writer.writeAll("null"),
        }
    } else {
        try writer.writeAll("null");
    }
}

fn get_string_arg(args: ?std.json.Value, key: []const u8) ?[]const u8 {
    const a = args orelse return null;
    const val = a.object.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

fn get_int_arg(args: ?std.json.Value, key: []const u8) ?usize {
    const a = args orelse return null;
    const val = a.object.get(key) orelse return null;
    return switch (val) {
        .integer => |n| @intCast(n),
        else => null,
    };
}

fn write_json_string(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{x:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
    try writer.writeByte('"');
}

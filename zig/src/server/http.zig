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
const literal_scan = @import("../analysis/literal_scan.zig");
const coupling = @import("../analysis/coupling.zig");
const cycles = @import("../analysis/cycles.zig");
const duplication = @import("../analysis/duplication.zig");
const clones = @import("../analysis/clones.zig");
const plan_change = @import("../analysis/plan_change.zig");

const treesitter = @import("../parser/treesitter.zig");
const filter_mod = @import("../core/filter.zig");
const scanner = @import("../index/scanner.zig");
const io = @import("../core/io.zig");
const reload = @import("../core/reload.zig");
const watcher_mod = @import("../watcher.zig");

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
        const stdout_file = io.stdout();

        // Arm SIGHUP hot-reload: re-exec this binary in place on signal, keeping
        // the client's stdio socket, so a rebuilt binary rolls out to running
        // servers without a session restart. Safe only between requests — see
        // reload.zig; the enter_wait/leave_wait bracket around read() below marks
        // the one window where an immediate re-exec can't truncate a response.
        reload.arm(self.allocator);

        // Read stdin with a direct blocking syscall on fd 0 rather than through
        // the std.Io.Threaded backend. The index build + file watcher run that
        // backend concurrently on another thread; sharing it for the MCP read
        // loop starves/deadlocks the handshake. A raw read is the correct, fully
        // decoupled primitive for a line-oriented stdio server.
        var read_buf: [1024 * 1024]u8 = undefined;
        var carry = std.ArrayList(u8).empty;
        defer carry.deinit(self.allocator);

        while (true) {
            // Apply a reload that arrived mid-request (deferred so the prior
            // response flushed intact), then mark this thread parked so a signal
            // during the blocking read re-execs immediately.
            reload.check_pending();
            reload.enter_wait();
            const n = io.readSome(io.stdin(), &read_buf) catch {
                reload.leave_wait();
                break;
            };
            reload.leave_wait();
            if (n == 0) break; // EOF

            try carry.appendSlice(self.allocator, read_buf[0..n]);

            // Process complete lines
            while (std.mem.indexOf(u8, carry.items, "\n")) |nl_pos| {
                // Trim a trailing CR. A client on Windows writing through a text
                // stream sends CRLF, and splitting on LF alone leaves the CR on
                // the end of the JSON, which the parser rejects — so every call
                // from such a client failed with no indication why. A
                // line-oriented protocol should accept either terminator.
                const line = std.mem.trimEnd(u8, carry.items[0..nl_pos], "\r");
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
                    var buf = std.Io.Writer.Allocating.init(self.allocator);
                    defer buf.deinit();
                    const bw = &buf.writer;
                    try bw.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
                    try write_id(bw, id);
                    try bw.writeAll(",\"result\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"codeindex-zig\",\"version\":\"0.1.0\"}}}\n");
                    try io.writeAll(stdout_file, buf.written());
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
        // `status` is exempt from activity tracking, the indexing wait, and the
        // reprime: it reports counts from outlines (no postings needed) and must
        // stay a cheap health check that never blocks — and a client that only
        // polls status should still be allowed to go idle so the server evicts.
        if (!std.mem.eql(u8, tool, "status")) {
            // Reset the idle-eviction timer for real queries.
            self.exp.note_activity();
            // Wait for indexing to complete before processing query tools
            while (self.exp.is_indexing()) {
                io.sleep(100 * std.time.ns_per_ms);
            }
            // A prior idle period may have evicted the postings to reclaim RAM;
            // rebuild them before serving. No-op when not evicted.
            try self.exp.reprime_all();
        }

        var out = std.Io.Writer.Allocating.init(self.allocator);
        defer out.deinit();
        const w = &out.writer;

        if (std.mem.eql(u8, tool, "status")) {
            // Calculate token savings stats
            // Naive approach: cat all files = total bytes / 4 (rough tokens estimate)
            // Codeindex: outline = ~10 tokens/symbol, search result = ~20 tokens/hit
            const total_bytes = self.exp.total_content_bytes();
            const total_lines = self.exp.total_line_count();
            const naive_tokens = total_bytes / 4; // ~4 chars per token estimate
            const outline_tokens = self.exp.symbol_count() * 10; // ~10 tokens per symbol in outline
            // (naive - outline) / naive. Compute the saved delta directly so small
            // ratios don't truncate to 0 and report a bogus 100%.
            const savings_pct: u64 = if (naive_tokens > outline_tokens)
                (naive_tokens - outline_tokens) * 100 / naive_tokens
            else
                0;

            try w.print("{{\"files\":{d},\"symbols\":{d},\"indexing\":{s},\"latest_seq\":{d},\"total_lines\":{d},\"total_bytes\":{d},\"naive_tokens\":{d},\"outline_tokens\":{d},\"savings_pct\":{d},\"watcher\":true,\"watcher_backend\":\"" ++ watcher_mod.backend ++ "\"", .{
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
            if (self.exp.status_message) |msg| {
                try w.writeAll(",\"message\":\"");
                try w.writeAll(msg);
                try w.writeAll("\"");
            }
            try w.writeAll("}");
        } else if (std.mem.eql(u8, tool, "search")) {
            const query = get_string_arg(args, "query") orelse "";
            const limit = get_int_arg(args, "limit") orelse 50;
            if (query.len == 0) {
                try w.writeAll("No query provided.");
            } else {
                const results = try self.exp.search_content(query, limit);
                defer {
                    for (results) |r| self.allocator.free(r.line_text);
                    self.allocator.free(results);
                }
                if (results.len == 0) {
                    try w.writeAll("No results found.");
                } else {
                    for (results) |r| {
                        if (r.scope_name) |scope| {
                            try w.print("{s}:{d} [{s}:{s}] — {s}\n", .{
                                r.path,                                    r.line_num,
                                if (r.scope_kind) |k| k.as_str() else "?", scope,
                                std.mem.trim(u8, r.line_text, " \t\r"),
                            });
                        } else {
                            try w.print("{s}:{d} — {s}\n", .{
                                r.path,                                 r.line_num,
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
                            r.symbol.start_1(),
                            r.symbol.end_1(),
                            r.symbol.kind.as_str(),
                            r.symbol.name,
                        });
                    }
                }
            }
        } else if (std.mem.eql(u8, tool, "plan_change")) {
            const symbol = get_string_arg(args, "symbol");
            const file = get_string_arg(args, "file");
            const fmt = get_string_arg(args, "format") orelse "";
            const want_json = std.mem.eql(u8, fmt, "json");
            if (symbol == null and file == null) {
                try w.writeAll("Provide `symbol` or `file`.");
            } else if (symbol != null and symbol.?.len > 0) {
                var plan = try plan_change.plan_symbol(self.allocator, self.exp, symbol.?);
                defer plan_change.free_symbol_plan(self.allocator, &plan);
                if (want_json) {
                    try render_symbol_plan_json(w, &plan);
                } else {
                    try render_symbol_plan(w, &plan);
                }
            } else {
                var plan = try plan_change.plan_file(self.allocator, self.exp, file.?);
                defer plan_change.free_file_plan(self.allocator, &plan);
                if (want_json) {
                    try render_file_plan_json(w, &plan);
                } else {
                    try render_file_plan(w, &plan);
                }
            }
        } else if (std.mem.eql(u8, tool, "find_callers")) {
            const name = get_string_arg(args, "name") orelse "";
            const limit = get_int_arg(args, "limit") orelse 100;
            if (name.len == 0) {
                try w.writeAll("No name provided.");
            } else {
                const results = try self.exp.find_callers(name, limit);
                defer {
                    for (results) |r| self.allocator.free(r.line_text);
                    self.allocator.free(results);
                }
                if (results.len == 0) {
                    try w.writeAll("No callers found.");
                } else {
                    for (results) |r| {
                        // line_num is 0-based (it indexes word postings); every
                        // line number leaving this server is 1-based.
                        try w.print("{s}:{d} [{s}] {s}\n", .{
                            r.path, r.line_num + 1, r.context, r.line_text,
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
                        // 0-based in the word index, 1-based on the wire.
                        try w.print("{s}:{d}\n", .{ r.path, r.line_num + 1 });
                    }
                }
            }
        } else if (std.mem.eql(u8, tool, "get_outline")) {
            const path = get_string_arg(args, "path") orelse "";
            if (self.exp.get_outline(path)) |outline| {
                try w.writeAll("{\"path\":");
                try write_json_string(w, outline.path);
                try w.print(",\"language\":\"{s}\",\"line_count\":{d},\"byte_size\":{d},\"symbols\":[", .{
                    @tagName(outline.language),
                    outline.line_count,
                    outline.byte_size,
                });
                for (outline.symbols, 0..) |sym, i| {
                    if (i > 0) try w.writeAll(",");
                    try w.writeAll("{\"name\":");
                    try write_json_string(w, sym.name);
                    try w.print(",\"kind\":\"{s}\",\"line_start\":{d},\"line_end\":{d}}}", .{
                        sym.kind.as_str(), sym.start_1(), sym.end_1(),
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
                try w.writeAll("{\"name\":");
                try write_json_string(w, node.name);
                try w.writeAll(",\"path\":");
                try write_json_string(w, node.path);
                try w.print(",\"symbols\":{d},\"language\":\"{s}\",\"lines\":{d}}}", .{
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
            if (path != null) {
                if (index_refusal_reason(self.allocator, path.?)) |reason| {
                    try w.print("Indexing refused: {s}. Pass a specific project directory.", .{reason});
                    self.exp.mark_indexing_complete();
                    try self.write_tool_result(writer, id, out.written(), true);
                    return;
                }
            }
            if (path != null and self.parser != null and self.filter != null) {
                // Clear the active explorer and re-index the new path
                self.exp.deinit();
                self.exp.* = try explorer.Explorer.init(self.allocator);

                const res = scanner.index_tree(self.allocator, self.exp, self.parser.?, self.filter.?, path.?, 10 * 1024 * 1024, .{}) catch {
                    try w.print("Failed to index: {s}", .{path.?});
                    self.exp.mark_indexing_complete();
                    try self.write_tool_result(writer, id, out.written(), true);
                    return;
                };
                if (res.capped) self.exp.set_status("Workspace too large — indexing stopped at the safety cap; results are partial.");
                self.exp.mark_indexing_complete();
                if (res.capped) {
                    try w.print("Indexed {d} files — {d} symbols (stopped at safety cap; results partial)", .{
                        res.files, self.exp.symbol_count(),
                    });
                } else {
                    try w.print("Indexed {d} files — {d} symbols across {d} files", .{
                        res.files, self.exp.symbol_count(), self.exp.file_count(),
                    });
                }
            } else {
                try w.print("Indexed {d} files — {d} symbols", .{
                    self.exp.file_count(), self.exp.symbol_count(),
                });
            }
        } else if (std.mem.eql(u8, tool, "analyze")) {
            const analysis_type = get_string_arg(args, "analysis") orelse "";
            if (std.mem.eql(u8, analysis_type, "security")) {
                const findings = try security_scan.scan(self.allocator, self.exp);
                defer security_scan.free_findings(self.allocator, findings);
                const summary = security_scan.summarize(findings);
                try w.print("{{\"total\":{d},\"critical\":{d},\"high\":{d},\"medium\":{d},\"low\":{d},\"findings\":[", .{
                    summary.total, summary.critical, summary.high, summary.medium, summary.low,
                });
                for (findings, 0..) |f, fi| {
                    if (fi > 0) try w.writeAll(",");
                    try w.print("{{\"file\":\"{s}\",\"line\":{d},\"rule\":\"{s}\",\"severity\":\"{s}\",\"line_text\":", .{
                        f.file, f.line, f.rule, f.severity.as_str(),
                    });
                    try write_json_string(w, f.line_text);
                    try w.writeAll("}");
                }
                try w.writeAll("]}");
            } else if (std.mem.eql(u8, analysis_type, "dead_code")) {
                const symbols = try dead_code.find_dead_code(self.allocator, self.exp);
                defer self.allocator.free(symbols);
                try w.print("{{\"dead_count\":{d},\"symbols\":[", .{symbols.len});
                for (symbols, 0..) |s, si| {
                    if (si > 0) try w.writeAll(",");
                    try w.writeAll("{\"name\":");
                    try write_json_string(w, s.name);
                    try w.print(",\"kind\":\"{s}\",", .{s.kind.as_str()});
                    try w.writeAll("\"file\":");
                    try write_json_string(w, s.file);
                    try w.print(",\"line\":{d},\"reason\":", .{s.line});
                    try write_json_string(w, s.reason);
                    try w.writeAll("}");
                }
                try w.writeAll("]}");
            } else if (std.mem.eql(u8, analysis_type, "unwrap_audit")) {
                const findings = try unwrap_audit.audit(self.allocator, self.exp);
                defer self.allocator.free(findings);
                try w.print("{{\"total\":{d},\"findings\":[", .{findings.len});
                for (findings, 0..) |f, fi| {
                    if (fi > 0) try w.writeAll(",");
                    try w.print("{{\"file\":\"{s}\",\"line\":{d},\"kind\":\"{s}\",\"severity\":\"{s}\",\"line_text\":", .{
                        f.file, f.line, f.kind.as_str(), f.severity.as_str(),
                    });
                    try write_json_string(w, f.line_text);
                    try w.writeAll(",\"scope\":");
                    try write_json_string(w, f.scope orelse "");
                    try w.writeAll("}");
                }
                try w.writeAll("]}");
            } else if (std.mem.eql(u8, analysis_type, "test_coverage")) {
                const modules = try test_coverage.analyze(self.allocator, self.exp);
                defer self.allocator.free(modules);
                try w.print("{{\"modules\":[", .{});
                for (modules, 0..) |m, mi| {
                    if (mi > 0) try w.writeAll(",");
                    try w.print("{{\"file\":\"{s}\",\"symbols\":{d},\"public\":{d},\"tests\":{d},\"referenced\":{d},\"coverage\":\"{s}\"}}", .{
                        m.file, m.total_symbols, m.public_symbols, m.test_symbols, m.referenced_in_tests, m.coverage_level.as_str(),
                    });
                }
                try w.writeAll("]}");
            } else if (std.mem.eql(u8, analysis_type, "architecture")) {
                const violations = try architecture.analyze(self.allocator, self.exp);
                defer self.allocator.free(violations);
                try w.print("{{\"violations\":{d},\"details\":[", .{violations.len});
                for (violations, 0..) |v, vi| {
                    if (vi > 0) try w.writeAll(",");
                    try w.print("{{\"from\":\"{s}\",\"to\":\"{s}\",\"from_layer\":\"{s}\",\"to_layer\":\"{s}\",\"description\":", .{
                        v.from_file, v.to_file, v.from_layer, v.to_layer,
                    });
                    try write_json_string(w, v.description);
                    try w.writeAll("}");
                }
                try w.writeAll("]}");
            } else if (std.mem.eql(u8, analysis_type, "crossref")) {
                const report = try crossref.analyze(self.allocator, self.exp);
                defer self.allocator.free(report.wired);
                defer self.allocator.free(report.backend_only);
                defer self.allocator.free(report.frontend_only);
                try w.print("{{\"wired\":{d},\"backend_only\":{d},\"frontend_only\":{d},\"backend_only_routes\":[", .{
                    report.wired_count, report.backend_only_count, report.frontend_only_count,
                });
                const xr_cap: usize = 200;
                const xbn = @min(report.backend_only.len, xr_cap);
                for (report.backend_only[0..xbn], 0..) |r, i| {
                    if (i > 0) try w.writeAll(",");
                    try w.writeAll("{\"path\":");
                    try write_json_string(w, r.path);
                    try w.print(",\"method\":\"{s}\",\"file\":", .{r.method});
                    try write_json_string(w, r.file);
                    try w.print(",\"line\":{d}}}", .{r.line});
                }
                try w.writeAll("],\"frontend_only_calls\":[");
                const xfn = @min(report.frontend_only.len, xr_cap);
                for (report.frontend_only[0..xfn], 0..) |c, i| {
                    if (i > 0) try w.writeAll(",");
                    try w.writeAll("{\"url\":");
                    try write_json_string(w, c.url);
                    try w.print(",\"method\":\"{s}\",\"file\":", .{c.method});
                    try write_json_string(w, c.file);
                    try w.print(",\"line\":{d}}}", .{c.line});
                }
                try w.writeAll("]}");
            } else if (std.mem.eql(u8, analysis_type, "type_drift")) {
                const report = try type_drift.analyze(self.allocator, self.exp);
                defer self.allocator.free(report.mismatches);
                defer self.allocator.free(report.missing_fields);
                try w.print("{{\"types_found\":{d},\"mismatches\":{d},\"missing_fields\":{d},\"mismatch_details\":[", .{
                    report.types_found, report.mismatches.len, report.missing_fields.len,
                });
                const td_cap: usize = 200;
                const tmn = @min(report.mismatches.len, td_cap);
                for (report.mismatches[0..tmn], 0..) |m, i| {
                    if (i > 0) try w.writeAll(",");
                    try w.writeAll("{\"type_name\":");
                    try write_json_string(w, m.type_name);
                    try w.writeAll(",\"field\":");
                    try write_json_string(w, m.field);
                    try w.writeAll(",\"lang_a\":");
                    try write_json_string(w, m.lang_a);
                    try w.writeAll(",\"type_a\":");
                    try write_json_string(w, m.type_a);
                    try w.writeAll(",\"lang_b\":");
                    try write_json_string(w, m.lang_b);
                    try w.writeAll(",\"type_b\":");
                    try write_json_string(w, m.type_b);
                    try w.writeAll("}");
                }
                try w.writeAll("],\"missing_field_details\":[");
                const tfn = @min(report.missing_fields.len, td_cap);
                for (report.missing_fields[0..tfn], 0..) |m, i| {
                    if (i > 0) try w.writeAll(",");
                    try w.writeAll("{\"type_name\":");
                    try write_json_string(w, m.type_name);
                    try w.writeAll(",\"field\":");
                    try write_json_string(w, m.field);
                    try w.writeAll(",\"present_in\":");
                    try write_json_string(w, m.present_in);
                    try w.writeAll(",\"missing_from\":");
                    try write_json_string(w, m.missing_from);
                    try w.writeAll("}");
                }
                try w.writeAll("]}");
            } else if (std.mem.eql(u8, analysis_type, "db_schema")) {
                const report = try db_schema.analyze(self.allocator, self.exp);
                defer self.allocator.free(report.issues);
                try w.print("{{\"tables_in_migrations\":{d},\"tables_in_code\":{d},\"issues\":{d},\"issue_details\":[", .{
                    report.tables_in_migrations, report.tables_in_code, report.issues.len,
                });
                const ds_cap: usize = 200;
                const dsn = @min(report.issues.len, ds_cap);
                for (report.issues[0..dsn], 0..) |iss, i| {
                    if (i > 0) try w.writeAll(",");
                    try w.writeAll("{\"table\":");
                    try write_json_string(w, iss.table);
                    try w.print(",\"issue_type\":\"{s}\",\"description\":", .{@tagName(iss.issue_type)});
                    try write_json_string(w, iss.description);
                    try w.writeAll(",\"file\":");
                    try write_json_string(w, iss.file);
                    try w.print(",\"line\":{d}}}", .{iss.line});
                }
                try w.writeAll("]}");
            } else if (std.mem.eql(u8, analysis_type, "migration_parity")) {
                const report = try migration_parity.analyze(self.allocator, self.exp);
                defer self.allocator.free(report.issues);
                try w.print("{{\"total_migrations\":{d},\"issues\":{d},\"issue_details\":[", .{
                    report.total_migrations, report.issues.len,
                });
                const mp_cap: usize = 200;
                const mpn = @min(report.issues.len, mp_cap);
                for (report.issues[0..mpn], 0..) |iss, i| {
                    if (i > 0) try w.writeAll(",");
                    try w.print("{{\"issue_type\":\"{s}\",\"description\":", .{@tagName(iss.issue_type)});
                    try write_json_string(w, iss.description);
                    try w.writeAll(",\"file\":");
                    try write_json_string(w, iss.file);
                    try w.writeAll("}");
                }
                try w.writeAll("]}");
            } else if (std.mem.eql(u8, analysis_type, "manifest_compliance")) {
                const report = try manifest_compliance.analyze(self.allocator, self.exp);
                defer self.allocator.free(report.violations);
                try w.print("{{\"manifests_checked\":{d},\"violations\":{d},\"violation_details\":[", .{
                    report.manifests_checked, report.violations.len,
                });
                const mc_cap: usize = 200;
                const mcn = @min(report.violations.len, mc_cap);
                for (report.violations[0..mcn], 0..) |v, i| {
                    if (i > 0) try w.writeAll(",");
                    try w.print("{{\"violation_type\":\"{s}\",\"file\":", .{v.violation_type.as_str()});
                    try write_json_string(w, v.file);
                    try w.print(",\"line\":{d},\"description\":", .{v.line});
                    try write_json_string(w, v.description);
                    try w.writeAll("}");
                }
                try w.writeAll("]}");
            } else if (std.mem.eql(u8, analysis_type, "literal_scan")) {
                const findings = try literal_scan.scan(self.allocator, self.exp);
                defer literal_scan.free_findings(self.allocator, findings);
                const s = literal_scan.summarize(findings);
                try w.print("{{\"total\":{d},\"urls\":{d},\"ips\":{d},\"localhosts\":{d},\"abs_paths\":{d},\"secrets\":{d},\"magic_ports\":{d},\"todos\":{d},\"findings\":[", .{
                    s.total, s.urls, s.ips, s.localhosts, s.paths, s.secrets, s.ports, s.todos,
                });
                const max_emit: usize = 200;
                const emit_n = @min(findings.len, max_emit);
                for (findings[0..emit_n], 0..) |f, fi| {
                    if (fi > 0) try w.writeAll(",");
                    try w.print("{{\"file\":\"{s}\",\"line\":{d},\"category\":\"{s}\",\"snippet\":\"{s}\"}}", .{
                        f.file, f.line, f.category.as_str(), f.snippet,
                    });
                }
                try w.print("],\"truncated\":{s}}}", .{if (findings.len > max_emit) "true" else "false"});
            } else if (std.mem.eql(u8, analysis_type, "coupling")) {
                var report = try coupling.analyze(self.allocator, self.exp);
                defer coupling.free_report(self.allocator, &report);
                try w.print("{{\"total_files\":{d},\"total_edges\":{d},\"god_modules\":[", .{
                    report.total_files, report.total_edges,
                });
                const top: usize = 15;
                const gn = @min(report.god_modules.len, top);
                for (report.god_modules[0..gn], 0..) |m, i| {
                    if (i > 0) try w.writeAll(",");
                    try w.print("{{\"file\":\"{s}\",\"fan_in\":{d},\"fan_out\":{d},\"instability\":{d:.2}}}", .{
                        m.file, m.fan_in, m.fan_out, m.instability,
                    });
                }
                try w.writeAll("],\"stable_cores\":[");
                const sn = @min(report.stable_cores.len, top);
                for (report.stable_cores[0..sn], 0..) |m, i| {
                    if (i > 0) try w.writeAll(",");
                    try w.print("{{\"file\":\"{s}\",\"fan_in\":{d},\"fan_out\":{d},\"instability\":{d:.2}}}", .{
                        m.file, m.fan_in, m.fan_out, m.instability,
                    });
                }
                try w.writeAll("],\"unstable_drivers\":[");
                const dn = @min(report.unstable_drivers.len, top);
                for (report.unstable_drivers[0..dn], 0..) |m, i| {
                    if (i > 0) try w.writeAll(",");
                    try w.print("{{\"file\":\"{s}\",\"fan_in\":{d},\"fan_out\":{d},\"instability\":{d:.2}}}", .{
                        m.file, m.fan_in, m.fan_out, m.instability,
                    });
                }
                try w.print("],\"islands_count\":{d},\"islands_sample\":[", .{report.islands.len});
                const in = @min(report.islands.len, top);
                for (report.islands[0..in], 0..) |m, i| {
                    if (i > 0) try w.writeAll(",");
                    try w.print("{{\"file\":\"{s}\",\"lines\":{d},\"symbols\":{d}}}", .{
                        m.file, m.line_count, m.symbol_count,
                    });
                }
                try w.writeAll("]}");
            } else if (std.mem.eql(u8, analysis_type, "cycles")) {
                var report = try cycles.analyze(self.allocator, self.exp);
                defer cycles.free_report(self.allocator, &report);
                try w.print("{{\"total_nodes\":{d},\"total_edges\":{d},\"cycle_count\":{d},\"cycles\":[", .{
                    report.total_nodes, report.total_edges, report.cycles.len,
                });
                const max_emit: usize = 50;
                const en = @min(report.cycles.len, max_emit);
                for (report.cycles[0..en], 0..) |c, i| {
                    if (i > 0) try w.writeAll(",");
                    try w.print("{{\"size\":{d},\"files\":[", .{c.files.len});
                    for (c.files, 0..) |f, j| {
                        if (j > 0) try w.writeAll(",");
                        try w.print("\"{s}\"", .{f});
                    }
                    try w.writeAll("]}");
                }
                try w.print("],\"truncated\":{s}}}", .{if (report.cycles.len > max_emit) "true" else "false"});
            } else if (std.mem.eql(u8, analysis_type, "duplication")) {
                var report = try duplication.analyze(self.allocator, self.exp);
                defer report.deinit(self.allocator);
                try w.print("{{\"duplicate_names\":{d},\"clusters\":[", .{report.total_clusters});
                const top: usize = 50;
                const n = @min(report.clusters.len, top);
                for (report.clusters[0..n], 0..) |c, i| {
                    if (i > 0) try w.writeAll(",");
                    try w.writeAll("{\"name\":");
                    try write_json_string(w, c.name);
                    try w.print(",\"kind\":\"{s}\",\"count\":{d},\"files\":[", .{ c.kind.as_str(), c.files.len });
                    for (c.files, 0..) |f, j| {
                        if (j >= 8) {
                            try w.writeAll(",\"...\"");
                            break;
                        }
                        if (j > 0) try w.writeAll(",");
                        try write_json_string(w, f);
                    }
                    try w.writeAll("]}");
                }
                try w.print("],\"truncated\":{s}}}", .{if (report.clusters.len > top) "true" else "false"});
            } else if (std.mem.eql(u8, analysis_type, "clones")) {
                var report = try clones.analyze(self.allocator, self.exp);
                defer report.deinit(self.allocator);
                try w.print("{{\"clone_groups\":{d},\"cloned_functions\":{d},\"groups\":[", .{
                    report.total_groups, report.total_cloned_fns,
                });
                const top: usize = 40;
                const n = @min(report.groups.len, top);
                for (report.groups[0..n], 0..) |g, i| {
                    if (i > 0) try w.writeAll(",");
                    try w.print("{{\"lines\":{d},\"count\":{d},\"functions\":[", .{ g.lines, g.members.len });
                    for (g.members, 0..) |m, j| {
                        if (j >= 8) {
                            try w.writeAll(",\"...\"");
                            break;
                        }
                        if (j > 0) try w.writeAll(",");
                        try w.writeAll("{\"name\":");
                        try write_json_string(w, m.name);
                        try w.writeAll(",\"file\":");
                        try write_json_string(w, m.file);
                        try w.print(",\"line\":{d}}}", .{m.line});
                    }
                    try w.writeAll("]}");
                }
                try w.print("],\"truncated\":{s}}}", .{if (report.groups.len > top) "true" else "false"});
            } else if (std.mem.eql(u8, analysis_type, "health")) {
                // One-call repo health: structure + risk + waste, with a verdict.
                const dead = try dead_code.find_dead_code(self.allocator, self.exp);
                defer self.allocator.free(dead);
                const unwraps = try unwrap_audit.audit(self.allocator, self.exp);
                defer self.allocator.free(unwraps);
                const sec_findings = try security_scan.scan(self.allocator, self.exp);
                defer security_scan.free_findings(self.allocator, sec_findings);
                const sec = security_scan.summarize(sec_findings);
                var cyc = try cycles.analyze(self.allocator, self.exp);
                defer cycles.free_report(self.allocator, &cyc);
                var coup = try coupling.analyze(self.allocator, self.exp);
                defer coupling.free_report(self.allocator, &coup);
                var dup = try duplication.analyze(self.allocator, self.exp);
                defer dup.deinit(self.allocator);
                var cln = try clones.analyze(self.allocator, self.exp);
                defer cln.deinit(self.allocator);

                try w.print("{{\"files\":{d},\"symbols\":{d},\"dependency_edges\":{d}," ++
                    "\"security_critical\":{d},\"security_total\":{d},\"panic_sites\":{d}," ++
                    "\"circular_deps\":{d},\"god_modules\":{d},\"dead_symbols\":{d}," ++
                    "\"duplicate_names\":{d},\"clone_groups\":{d},\"cloned_functions\":{d},", .{
                    self.exp.file_count(), self.exp.symbol_count(), coup.total_edges,
                    sec.critical,          sec.total,               unwraps.len,
                    cyc.cycles.len,        coup.god_modules.len,    dead.len,
                    dup.total_clusters,    cln.total_groups,        cln.total_cloned_fns,
                });
                // Top reinvented/duplicated definitions — the "are we reusing?" answer.
                try w.writeAll("\"top_duplication\":[");
                const dn = @min(dup.clusters.len, 8);
                for (dup.clusters[0..dn], 0..) |c, i| {
                    if (i > 0) try w.writeAll(",");
                    try w.writeAll("{\"name\":");
                    try write_json_string(w, c.name);
                    try w.print(",\"defined_in_files\":{d}}}", .{c.files.len});
                }
                // Top god-modules — the "is structure ok?" answer.
                // Biggest copy-paste clones — the "did we paste this?" answer.
                try w.writeAll("],\"top_clones\":[");
                const cn = @min(cln.groups.len, 8);
                for (cln.groups[0..cn], 0..) |g, i| {
                    if (i > 0) try w.writeAll(",");
                    try w.print("{{\"lines\":{d},\"copies\":{d},\"example\":", .{ g.lines, g.members.len });
                    try write_json_string(w, g.members[0].name);
                    try w.writeAll("}");
                }
                try w.writeAll("],\"top_god_modules\":[");
                const gn = @min(coup.god_modules.len, 8);
                for (coup.god_modules[0..gn], 0..) |m, i| {
                    if (i > 0) try w.writeAll(",");
                    try w.writeAll("{\"file\":");
                    try write_json_string(w, m.file);
                    try w.print(",\"fan_in\":{d},\"fan_out\":{d}}}", .{ m.fan_in, m.fan_out });
                }
                try w.writeAll("]}");
            } else {
                try w.print("Unknown analysis: {s}. Available: security, dead_code, unwrap_audit, test_coverage, architecture, crossref, type_drift, db_schema, migration_parity, manifest_compliance, literal_scan, coupling, cycles, duplication, clones, health", .{analysis_type});
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
                                // write_lines counts from 1, so convert the
                                // symbol's 0-based range before widening it;
                                // feeding it the raw range returned a window
                                // one line early, which cut the closing brace.
                                const first = r.symbol.start_1();
                                const start = if (first > context_lines) first - context_lines else 1;
                                const end = r.symbol.end_1() + context_lines;
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

        try self.write_tool_result(writer, id, out.written(), false);
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

    fn write_tool_result(self: *Server, file: io.File, id: ?std.json.Value, text: []const u8, is_error: bool) !void {
        // Build the full response into a buffer, then write it atomically
        var buf = std.Io.Writer.Allocating.init(self.allocator);
        defer buf.deinit();
        const bw = &buf.writer;

        try bw.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
        try write_id(bw, id);
        try bw.writeAll(",\"result\":{\"content\":[{\"type\":\"text\",\"text\":");
        try write_json_string(bw, text);
        try bw.writeAll("}],\"isError\":");
        try bw.writeAll(if (is_error) "true" else "false");
        try bw.writeAll("}}\n");

        try io.writeAll(file, buf.written());
    }

    fn write_response(self: *Server, file: io.File, id: ?std.json.Value, result: anytype) !void {
        var buf = std.Io.Writer.Allocating.init(self.allocator);
        defer buf.deinit();
        const bw = &buf.writer;

        try bw.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
        try write_id(bw, id);
        try bw.print(",\"result\":{f}}}\n", .{std.json.fmt(result, .{})});

        try io.writeAll(file, buf.written());
    }

    fn write_tools_list(self: *Server, file: io.File, id: ?std.json.Value) !void {
        var buf = std.Io.Writer.Allocating.init(self.allocator);
        defer buf.deinit();
        const bw = &buf.writer;

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
            // find_callers
            "{\"name\":\"find_callers\",\"description\":\"Approximate callers of a symbol. Finds word-index hits with call/method/path context, excluding the defining body. Heuristic — no full name resolution, may include shadowed names.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\",\"description\":\"Symbol name\"},\"limit\":{\"type\":\"integer\",\"description\":\"Max results (default 100)\"}},\"required\":[\"name\"]}}",
            // plan_change
            "{\"name\":\"plan_change\",\"description\":\"Given a symbol name or file path, produce a full edit plan: definition(s), callers, file role (god/stable-core/driver/island), hardcoded-literal heads-up, and transitive blast radius. Use before refactors.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"symbol\":{\"type\":\"string\",\"description\":\"Symbol name to plan around\"},\"file\":{\"type\":\"string\",\"description\":\"Or a file path to plan around\"}}}}",
            // get_hot_files
            "{\"name\":\"get_hot_files\",\"description\":\"Get recently changed files sorted by recency\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"limit\":{\"type\":\"integer\",\"description\":\"Max results (default 20)\"}}}}",
            // index_workspace
            "{\"name\":\"index_workspace\",\"description\":\"Index or re-index a workspace directory\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"Directory path to index\"}},\"required\":[\"path\"]}}",
            // analyze
            "{\"name\":\"analyze\",\"description\":\"Run code analysis. Types: security, dead_code, unwrap_audit, test_coverage, architecture, crossref, type_drift, db_schema, migration_parity, manifest_compliance, literal_scan, coupling, cycles, duplication, clones, health\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"analysis\":{\"type\":\"string\",\"description\":\"Analysis type: security, dead_code, unwrap_audit, test_coverage, architecture, crossref, type_drift, db_schema, migration_parity, manifest_compliance, literal_scan, coupling, cycles, duplication, clones, health\"}},\"required\":[\"analysis\"]}}",
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

        try io.writeAll(file, buf.written());
    }
};

// ── Renderers ────────────────────────────────────────────────────────────────

fn render_symbol_plan(w: anytype, plan: *plan_change.SymbolPlan) !void {
    try w.print("# Change plan: `{s}`\n\n", .{plan.target_name});

    // Definitions + ambiguity
    if (plan.definitions.len == 0) {
        try w.writeAll("## Definition\n- No matching definition found.\n\n");
    } else {
        try w.print("## Definition ({d})\n", .{plan.definitions.len});
        for (plan.definitions) |d| {
            try w.print("- {s}:{d}-{d}  [{s}]\n", .{ d.path, d.line_start, d.line_end, d.kind.as_str() });
        }
        if (plan.definitions.len > 1) {
            try w.writeAll("  ⚠ Ambiguous — multiple definitions share this name.\n");
        }
        try w.writeAll("\n");
    }

    // Callers — grouped by file
    try w.print("## Call sites: {d} total across {d} files\n", .{ plan.callers_total, plan.caller_groups.len });
    const max_files: usize = 20;
    const shown = @min(plan.caller_groups.len, max_files);
    for (plan.caller_groups[0..shown]) |g| {
        try w.print("- {s}  ({d} hit{s})\n", .{ g.path, g.count, if (g.count == 1) @as([]const u8, "") else @as([]const u8, "s") });
        for (g.samples) |s| {
            try w.print("    {d}  [{s}]  {s}\n", .{ s.line_num, s.context, s.snippet });
        }
    }
    if (plan.caller_groups.len > max_files) {
        try w.print("- ... ({d} more files omitted)\n", .{plan.caller_groups.len - max_files});
    }
    if (plan.callers_total == 0) try w.writeAll("- None found via heuristic context filter.\n");
    if (plan.indexer_missed_def) {
        try w.writeAll("  ⚠ Outline didn't capture a definition for this name, but callers exist — indexer likely missed it (known gap: tree-sitter tags.scm for TS/JS only captures .d.ts-style signatures). The first-listed file is the best guess for where it's defined.\n");
    }
    try w.writeAll("\n");

    // File context
    if (plan.primary_file) |pf| {
        try w.print("## File context: {s}\n", .{pf});
        try w.print("- Role: {s}  (fan_in={d}, fan_out={d})\n", .{ plan.file_role.as_str(), plan.fan_in, plan.fan_out });
        try render_literals(w, plan.literals);
        try w.writeAll("\n");
    }

    // Impact
    try w.print("## Blast radius (files affected if this file changes)\n", .{});
    try w.print("- Direct: {d}\n", .{plan.direct_impact.len});
    for (plan.direct_impact) |p| try w.print("  - {s}\n", .{p});
    try w.print("- Transitive: {d} (depth reached {d})\n", .{ plan.transitive_impact.len, plan.max_depth_reached });
    for (plan.transitive_impact) |p| try w.print("  - {s}\n", .{p});
    try w.writeAll("\n");

    try render_heads_up(w, plan.file_role, plan.literals);
}

fn render_file_plan(w: anytype, plan: *plan_change.FilePlan) !void {
    try w.print("# Change plan: `{s}`\n\n", .{plan.target_path});
    try w.print("## Role: {s}  (fan_in={d}, fan_out={d})\n\n", .{ plan.file_role.as_str(), plan.fan_in, plan.fan_out });

    try w.print("## Symbols in file ({d})\n", .{plan.symbols_in_file.len});
    const max_sym: usize = 40;
    const n = @min(plan.symbols_in_file.len, max_sym);
    for (plan.symbols_in_file[0..n]) |s| {
        try w.print("- {d}: [{s}] {s}\n", .{ s.start_1(), s.kind.as_str(), s.name });
    }
    if (plan.symbols_in_file.len > max_sym) try w.print("... ({d} more)\n", .{plan.symbols_in_file.len - max_sym});
    try w.writeAll("\n");

    try render_literals(w, plan.literals);
    try w.writeAll("\n");

    try w.print("## Blast radius (files affected if this file changes)\n", .{});
    try w.print("- Direct: {d}\n", .{plan.direct_impact.len});
    for (plan.direct_impact) |p| try w.print("  - {s}\n", .{p});
    try w.print("- Transitive: {d} (depth reached {d})\n", .{ plan.transitive_impact.len, plan.max_depth_reached });
    for (plan.transitive_impact) |p| try w.print("  - {s}\n", .{p});
    try w.writeAll("\n");

    try render_heads_up(w, plan.file_role, plan.literals);
}

fn render_file_plan_json(w: anytype, plan: *plan_change.FilePlan) !void {
    try w.writeAll("{\"target\":");
    try write_json_string(w, plan.target_path);
    try w.print(",\"file_role\":\"{s}\",\"fan_in\":{d},\"fan_out\":{d},\"direct\":{d},\"transitive\":{d},\"max_depth\":{d},\"direct_files\":[", .{
        @tagName(plan.file_role), plan.fan_in, plan.fan_out, plan.direct_impact.len, plan.transitive_impact.len, plan.max_depth_reached,
    });
    const cap: usize = 40;
    const dn = @min(plan.direct_impact.len, cap);
    for (plan.direct_impact[0..dn], 0..) |f, i| {
        if (i > 0) try w.writeAll(",");
        try write_json_string(w, f);
    }
    try w.writeAll("]}");
}

fn render_symbol_plan_json(w: anytype, plan: *plan_change.SymbolPlan) !void {
    try w.writeAll("{\"target\":");
    try write_json_string(w, plan.target_name);
    try w.print(",\"file_role\":\"{s}\",\"fan_in\":{d},\"fan_out\":{d},\"callers_total\":{d},\"direct\":{d},\"transitive\":{d},\"max_depth\":{d},\"primary_file\":", .{
        @tagName(plan.file_role), plan.fan_in, plan.fan_out, plan.callers_total, plan.direct_impact.len, plan.transitive_impact.len, plan.max_depth_reached,
    });
    try write_json_string(w, plan.primary_file orelse "");
    try w.writeAll("}");
}

fn render_literals(w: anytype, l: plan_change.LiteralSummary) !void {
    const total = l.urls + l.localhosts + l.ips + l.secrets + l.magic_ports + l.abs_paths + l.todos;
    if (total == 0) return;
    try w.print("- Hardcoded literals: urls={d}, localhost={d}, magic_ports={d}, abs_paths={d}, todos={d}\n", .{
        l.urls, l.localhosts, l.magic_ports, l.abs_paths, l.todos,
    });
}

fn render_heads_up(w: anytype, role: plan_change.FileRole, l: plan_change.LiteralSummary) !void {
    var any = false;
    try w.writeAll("## Heads-up\n");
    switch (role) {
        .god_module => {
            try w.writeAll("- ⚠ **God module** — many files depend on this AND it imports widely. High blast radius.\n");
            any = true;
        },
        .stable_core => {
            try w.writeAll("- Stable core (contract/trait file). Changes here likely require call-site updates in every dependent.\n");
            any = true;
        },
        .island => {
            try w.writeAll("- ⚠ Island — nothing imports this and it imports nothing. Possibly dead.\n");
            any = true;
        },
        .driver => {
            try w.writeAll("- Driver — entry point / aggregator. Few depend on it but it wires many things together.\n");
            any = true;
        },
        .regular => {},
    }
    if (l.urls > 0 or l.magic_ports > 0 or l.abs_paths > 0) {
        try w.print("- ⚠ Hardcoded configuration detected ({d} URLs, {d} ports, {d} abs paths). Consider pulling into config.\n", .{
            l.urls, l.magic_ports, l.abs_paths,
        });
        any = true;
    }
    if (l.todos > 0) {
        try w.print("- {d} TODO/FIXME markers in this file.\n", .{l.todos});
        any = true;
    }
    if (!any) try w.writeAll("- No architectural tells detected.\n");
}

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

/// Mirror of main.zig's startup workspace guard. The `index_workspace` tool
/// accepts an arbitrary path, so the home/root refusal must run here too —
/// an explicit tool-call path used to bypass the startup check and scan all
/// of $HOME at 100% CPU until the caller's timeout killed the process.
fn index_refusal_reason(allocator: std.mem.Allocator, path: []const u8) ?[]const u8 {
    const eff = io.realpathAlloc(allocator, path) catch return null;
    defer allocator.free(eff);
    if (eff.len <= 1) return "path resolves to the filesystem root";
    const home = io.getEnv(allocator, "HOME");
    defer if (home) |h| allocator.free(h);
    if (home != null and std.mem.eql(u8, eff, home.?)) return "path resolves to your home directory";
    return null;
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

pub fn write_json_string(writer: anytype, s: []const u8) !void {
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

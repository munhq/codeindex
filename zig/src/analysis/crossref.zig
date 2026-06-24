const std = @import("std");
const explorer = @import("../index/explorer.zig");
const models = @import("../core/models.zig");

pub const BackendRoute = struct {
    path: []const u8,
    method: []const u8,
    file: []const u8,
    line: usize,
};

pub const FrontendCall = struct {
    url: []const u8,
    method: []const u8,
    file: []const u8,
    line: usize,
};

pub const WiredRoute = struct {
    backend: BackendRoute,
    frontend: FrontendCall,
};

pub const Report = struct {
    wired: []WiredRoute,
    backend_only: []BackendRoute,
    frontend_only: []FrontendCall,
    wired_count: usize,
    backend_only_count: usize,
    frontend_only_count: usize,
};

const route_patterns = [_][]const u8{
    ".get(\"",   ".post(\"",  ".put(\"",   ".delete(\"", ".patch(\"",
    ".route(\"", ".GET(\"",   ".POST(\"",  ".PUT(\"",    ".DELETE(\"",
    "HandleFunc(\"",          "Handle(\"",
    "r.Get(\"",  "r.Post(\"", "r.Put(\"",  "r.Delete(\"",
};

const fetch_patterns = [_][]const u8{
    "fetch(\"",  "fetch(`",  "axios.get(",  "axios.post(", "axios.put(", "axios.delete(",
    "http.get(", "http.post(", "http.put(", "http.delete(",
};

pub fn analyze(allocator: std.mem.Allocator, exp: *explorer.Explorer) !Report {
    var backend_routes = std.ArrayList(BackendRoute).empty;
    var frontend_calls = std.ArrayList(FrontendCall).empty;

    var it = exp.outlines.iterator();
    while (it.next()) |entry| {
        const file_id = entry.key_ptr.*;
        if (exp.deleted_files.get(file_id) != null) continue;
        const outline = entry.value_ptr.*;
        const content = exp.content_cache.get(file_id) orelse continue;

        const is_frontend = outline.language == .typescript or outline.language == .javascript;
        const is_backend = outline.language == .rust or outline.language == .go or outline.language == .python;

        var line_num: usize = 1;
        var line_it = std.mem.splitScalar(u8, content, '\n');
        while (line_it.next()) |line| {
            if (is_backend) {
                for (&route_patterns) |pat| {
                    if (std.mem.indexOf(u8, line, pat)) |pos| {
                        const after = line[pos + pat.len ..];
                        const end = std.mem.indexOf(u8, after, "\"") orelse
                            std.mem.indexOf(u8, after, "`") orelse continue;
                        const route_path = after[0..end];
                        if (route_path.len == 0) continue;
                        try backend_routes.append(allocator, .{
                            .path = route_path,
                            .method = extractMethod(pat),
                            .file = outline.path,
                            .line = line_num,
                        });
                    }
                }
            }
            if (is_frontend) {
                for (&fetch_patterns) |pat| {
                    if (std.mem.indexOf(u8, line, pat)) |pos| {
                        const after = line[pos + pat.len ..];
                        const end = std.mem.indexOf(u8, after, "\"") orelse
                            std.mem.indexOf(u8, after, "`") orelse
                            std.mem.indexOf(u8, after, "'") orelse continue;
                        const url = after[0..end];
                        if (url.len == 0) continue;
                        try frontend_calls.append(allocator, .{
                            .url = url,
                            .method = extractMethod(pat),
                            .file = outline.path,
                            .line = line_num,
                        });
                    }
                }
            }
            line_num += 1;
        }
    }

    var wired = std.ArrayList(WiredRoute).empty;
    var matched_b = std.AutoHashMap(usize, void).init(allocator);
    defer matched_b.deinit();
    var matched_f = std.AutoHashMap(usize, void).init(allocator);
    defer matched_f.deinit();

    for (frontend_calls.items, 0..) |fc, fi| {
        for (backend_routes.items, 0..) |br, bi| {
            if (pathMatches(fc.url, br.path)) {
                try wired.append(allocator, .{ .backend = br, .frontend = fc });
                matched_b.put(bi, {}) catch {};
                matched_f.put(fi, {}) catch {};
            }
        }
    }

    var bo = std.ArrayList(BackendRoute).empty;
    for (backend_routes.items, 0..) |br, i| {
        if (matched_b.get(i) == null) try bo.append(allocator, br);
    }
    var fo = std.ArrayList(FrontendCall).empty;
    for (frontend_calls.items, 0..) |fc, i| {
        if (matched_f.get(i) == null) try fo.append(allocator, fc);
    }

    const w = try wired.toOwnedSlice(allocator);
    const b = try bo.toOwnedSlice(allocator);
    const f = try fo.toOwnedSlice(allocator);

    backend_routes.deinit(allocator);
    frontend_calls.deinit(allocator);

    return .{
        .wired = w,
        .backend_only = b,
        .frontend_only = f,
        .wired_count = w.len,
        .backend_only_count = b.len,
        .frontend_only_count = f.len,
    };
}

fn extractMethod(pattern: []const u8) []const u8 {
    if (std.mem.indexOf(u8, pattern, "get") != null or std.mem.indexOf(u8, pattern, "Get") != null or std.mem.indexOf(u8, pattern, "GET") != null) return "GET";
    if (std.mem.indexOf(u8, pattern, "post") != null or std.mem.indexOf(u8, pattern, "Post") != null or std.mem.indexOf(u8, pattern, "POST") != null) return "POST";
    if (std.mem.indexOf(u8, pattern, "put") != null or std.mem.indexOf(u8, pattern, "Put") != null or std.mem.indexOf(u8, pattern, "PUT") != null) return "PUT";
    if (std.mem.indexOf(u8, pattern, "delete") != null or std.mem.indexOf(u8, pattern, "Delete") != null or std.mem.indexOf(u8, pattern, "DELETE") != null) return "DELETE";
    if (std.mem.indexOf(u8, pattern, "patch") != null or std.mem.indexOf(u8, pattern, "Patch") != null) return "PATCH";
    return "UNKNOWN";
}

fn pathMatches(url: []const u8, route: []const u8) bool {
    var path = url;
    if (std.mem.indexOf(u8, path, "://")) |pos| {
        path = path[pos + 3 ..];
        if (std.mem.indexOf(u8, path, "/")) |slash| {
            path = path[slash..];
        }
    }
    if (std.mem.indexOf(u8, path, "?")) |q| {
        path = path[0..q];
    }
    return std.mem.eql(u8, path, route) or std.mem.endsWith(u8, path, route);
}

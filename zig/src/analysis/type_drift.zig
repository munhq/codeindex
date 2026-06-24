const std = @import("std");
const explorer = @import("../index/explorer.zig");
const models = @import("../core/models.zig");

pub const FieldInfo = struct {
    name: []const u8,
    type_name: []const u8,
    file: []const u8,
    line: usize,
};

pub const TypeInfo = struct {
    name: []const u8,
    language: models.Language,
    file: []const u8,
    line: usize,
    fields: []FieldInfo,
};

pub const Mismatch = struct {
    type_name: []const u8,
    field: []const u8,
    lang_a: []const u8,
    type_a: []const u8,
    lang_b: []const u8,
    type_b: []const u8,
};

pub const MissingField = struct {
    type_name: []const u8,
    field: []const u8,
    present_in: []const u8,
    missing_from: []const u8,
};

pub const Report = struct {
    mismatches: []Mismatch,
    missing_fields: []MissingField,
    types_found: usize,
};

/// Extract struct/interface types from content by looking for field patterns.
fn extract_types(allocator: std.mem.Allocator, exp: *explorer.Explorer) ![]TypeInfo {
    var types = std.ArrayList(TypeInfo).empty;

    var it = exp.outlines.iterator();
    while (it.next()) |entry| {
        const file_id = entry.key_ptr.*;
        if (exp.deleted_files.get(file_id) != null) continue;
        const outline = entry.value_ptr.*;
        const content = exp.content_cache.get(file_id) orelse continue;

        // Only look at languages that define types
        if (outline.language != .rust and outline.language != .typescript and
            outline.language != .go and outline.language != .python) continue;

        for (outline.symbols) |sym| {
            if (sym.kind != .@"struct" and sym.kind != .class and sym.kind != .interface) continue;

            var fields = std.ArrayList(FieldInfo).empty;
            var line_num: usize = 0;
            var lines_it = std.mem.splitScalar(u8, content, '\n');
            while (lines_it.next()) |line| {
                line_num += 1;
                if (line_num <= sym.line_start or line_num >= sym.line_end) continue;
                const trimmed = std.mem.trim(u8, line, " \t\r");
                if (trimmed.len == 0) continue;

                // Skip non-field lines
                if (std.mem.startsWith(u8, trimmed, "//") or
                    std.mem.startsWith(u8, trimmed, "#") or
                    std.mem.startsWith(u8, trimmed, "/*") or
                    std.mem.startsWith(u8, trimmed, "*") or
                    std.mem.startsWith(u8, trimmed, "pub fn ") or
                    std.mem.startsWith(u8, trimmed, "fn ") or
                    std.mem.startsWith(u8, trimmed, "func ") or
                    std.mem.startsWith(u8, trimmed, "def ") or
                    std.mem.startsWith(u8, trimmed, "async ") or
                    std.mem.startsWith(u8, trimmed, "impl ") or
                    std.mem.startsWith(u8, trimmed, "@") or
                    std.mem.startsWith(u8, trimmed, "#[") or
                    std.mem.eql(u8, trimmed, "{") or
                    std.mem.eql(u8, trimmed, "}") or
                    std.mem.eql(u8, trimmed, "},")){
                    continue;
                }

                const field_info = switch (outline.language) {
                    // Rust: `pub field_name: Type,` or `field_name: Type,`
                    .rust => blk: {
                        var t = trimmed;
                        if (std.mem.startsWith(u8, t, "pub ")) t = t[4..];
                        if (std.mem.startsWith(u8, t, "pub(crate) ")) t = t[11..];
                        const colon = std.mem.indexOf(u8, t, ":") orelse break :blk null;
                        // Skip if it looks like a function (has parentheses before colon)
                        if (std.mem.indexOf(u8, t[0..colon], "(") != null) break :blk null;
                        const fname = std.mem.trim(u8, t[0..colon], " \t");
                        const ftype = std.mem.trim(u8, t[colon + 1 ..], " \t,;");
                        if (fname.len == 0 or fname.len > 64 or ftype.len == 0) break :blk null;
                        break :blk FieldInfo{ .name = fname, .type_name = ftype, .file = outline.path, .line = line_num };
                    },
                    // TypeScript: `fieldName: type;` or `fieldName?: type;`
                    .typescript, .javascript => blk: {
                        var t = trimmed;
                        if (std.mem.startsWith(u8, t, "readonly ")) t = t[9..];
                        if (std.mem.startsWith(u8, t, "private ")) t = t[8..];
                        if (std.mem.startsWith(u8, t, "public ")) t = t[7..];
                        if (std.mem.startsWith(u8, t, "protected ")) t = t[10..];
                        const colon = std.mem.indexOf(u8, t, ":") orelse break :blk null;
                        if (std.mem.indexOf(u8, t[0..colon], "(") != null) break :blk null;
                        const fname = std.mem.trim(u8, t[0..colon], " \t?");
                        if (fname.len == 0 or fname.len > 64) break :blk null;
                        const ftype = std.mem.trim(u8, t[colon + 1 ..], " \t,;");
                        if (ftype.len == 0) break :blk null;
                        break :blk FieldInfo{ .name = fname, .type_name = ftype, .file = outline.path, .line = line_num };
                    },
                    // Go: `FieldName Type` or `FieldName Type `json:"..."`
                    .go => blk: {
                        // Split on first whitespace
                        var tok_it = std.mem.tokenizeAny(u8, trimmed, " \t");
                        const fname = tok_it.next() orelse break :blk null;
                        const ftype = tok_it.next() orelse break :blk null;
                        if (fname.len == 0 or fname.len > 64) break :blk null;
                        // Skip if first char is lowercase (unexported) or looks like a keyword
                        if (std.mem.eql(u8, fname, "type") or std.mem.eql(u8, fname, "func") or
                            std.mem.eql(u8, fname, "var") or std.mem.eql(u8, fname, "const"))
                            break :blk null;
                        break :blk FieldInfo{ .name = fname, .type_name = ftype, .file = outline.path, .line = line_num };
                    },
                    // Python: `field_name: type` (dataclass/TypedDict style)
                    .python => blk: {
                        const colon = std.mem.indexOf(u8, trimmed, ":") orelse break :blk null;
                        if (std.mem.indexOf(u8, trimmed[0..colon], "(") != null) break :blk null;
                        const fname = std.mem.trim(u8, trimmed[0..colon], " \t");
                        var ftype = std.mem.trim(u8, trimmed[colon + 1 ..], " \t,");
                        // Strip default value: `field: int = 0`
                        if (std.mem.indexOf(u8, ftype, "=")) |eq| ftype = std.mem.trim(u8, ftype[0..eq], " \t");
                        if (fname.len == 0 or fname.len > 64 or ftype.len == 0) break :blk null;
                        break :blk FieldInfo{ .name = fname, .type_name = ftype, .file = outline.path, .line = line_num };
                    },
                    else => null,
                };

                if (field_info) |fi| {
                    try fields.append(allocator, fi);
                }
            }

            if (fields.items.len > 0) {
                try types.append(allocator, .{
                    .name = sym.name,
                    .language = outline.language,
                    .file = outline.path,
                    .line = sym.line_start,
                    .fields = try fields.toOwnedSlice(allocator),
                });
            } else {
                fields.deinit(allocator);
            }
        }
    }

    return try types.toOwnedSlice(allocator);
}

pub fn analyze(allocator: std.mem.Allocator, exp: *explorer.Explorer) !Report {
    const types = try extract_types(allocator, exp);
    defer {
        for (types) |t| allocator.free(t.fields);
        allocator.free(types);
    }

    var mismatches = std.ArrayList(Mismatch).empty;
    var missing = std.ArrayList(MissingField).empty;

    // Compare types with the same name across languages
    for (types, 0..) |a, ai| {
        for (types[ai + 1 ..]) |b| {
            if (!std.mem.eql(u8, a.name, b.name)) continue;
            if (a.language == b.language) continue;

            // Compare fields
            for (a.fields) |fa| {
                var found = false;
                for (b.fields) |fb| {
                    if (std.mem.eql(u8, fa.name, fb.name)) {
                        found = true;
                        if (!typesCompatible(fa.type_name, fb.type_name)) {
                            try mismatches.append(allocator, .{
                                .type_name = a.name,
                                .field = fa.name,
                                .lang_a = @tagName(a.language),
                                .type_a = fa.type_name,
                                .lang_b = @tagName(b.language),
                                .type_b = fb.type_name,
                            });
                        }
                        break;
                    }
                }
                if (!found) {
                    try missing.append(allocator, .{
                        .type_name = a.name,
                        .field = fa.name,
                        .present_in = @tagName(a.language),
                        .missing_from = @tagName(b.language),
                    });
                }
            }
        }
    }

    return .{
        .mismatches = try mismatches.toOwnedSlice(allocator),
        .missing_fields = try missing.toOwnedSlice(allocator),
        .types_found = types.len,
    };
}

fn typesCompatible(a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;
    // Common equivalences
    const pairs = [_][2][]const u8{
        .{ "String", "string" },
        .{ "str", "string" },
        .{ "&str", "string" },
        .{ "i32", "number" },
        .{ "i64", "number" },
        .{ "u32", "number" },
        .{ "u64", "number" },
        .{ "f32", "number" },
        .{ "f64", "number" },
        .{ "usize", "number" },
        .{ "int", "number" },
        .{ "int", "i64" },
        .{ "bool", "boolean" },
        .{ "Vec<", "Array<" },
        .{ "Vec<", "[]" },
    };
    for (&pairs) |pair| {
        if ((std.mem.startsWith(u8, a, pair[0]) and std.mem.startsWith(u8, b, pair[1])) or
            (std.mem.startsWith(u8, a, pair[1]) and std.mem.startsWith(u8, b, pair[0])))
            return true;
    }
    return false;
}

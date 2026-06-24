const std = @import("std");
const explorer = @import("../index/explorer.zig");
const models = @import("../core/models.zig");

pub const CoverageLevel = enum {
    high,
    medium,
    low,
    none,

    pub fn as_str(self: CoverageLevel) []const u8 {
        return switch (self) {
            .high => "High",
            .medium => "Medium",
            .low => "Low",
            .none => "None",
        };
    }
};

pub const ModuleCoverage = struct {
    file: []const u8,
    total_symbols: usize,
    public_symbols: usize,
    test_symbols: usize,
    referenced_in_tests: usize,
    coverage_level: CoverageLevel,
};

pub fn analyze(allocator: std.mem.Allocator, exp: *explorer.Explorer) ![]ModuleCoverage {
    var results = std.ArrayList(ModuleCoverage).empty;

    // First pass: collect all test file word sets
    var test_words = std.StringHashMap(void).init(allocator);
    defer test_words.deinit();

    var it = exp.outlines.iterator();
    while (it.next()) |entry| {
        const file_id = entry.key_ptr.*;
        if (exp.deleted_files.get(file_id) != null) continue;
        const outline = entry.value_ptr.*;

        const is_test = std.mem.indexOf(u8, outline.path, "test") != null;
        if (!is_test) continue;

        for (outline.symbols) |sym| {
            test_words.put(sym.name, {}) catch {};
        }
    }

    // Second pass: evaluate coverage per file
    it = exp.outlines.iterator();
    while (it.next()) |entry| {
        const file_id = entry.key_ptr.*;
        if (exp.deleted_files.get(file_id) != null) continue;
        const outline = entry.value_ptr.*;

        const is_test = std.mem.indexOf(u8, outline.path, "test") != null;
        if (is_test) continue;

        var total: usize = 0;
        var public_count: usize = 0;
        var test_count: usize = 0;
        var referenced: usize = 0;

        for (outline.symbols) |sym| {
            total += 1;
            if (sym.kind == .@"test") {
                test_count += 1;
                continue;
            }

            // Check if it's "public" (heuristic: not prefixed with _)
            if (!std.mem.startsWith(u8, sym.name, "_")) {
                public_count += 1;
            }

            // Check if referenced in any test file
            if (test_words.get(sym.name) != null) {
                referenced += 1;
            }
        }

        const coverage: CoverageLevel = if (total == 0)
            .none
        else if (test_count > 0 and referenced > public_count / 2)
            .high
        else if (test_count > 0 or referenced > 0)
            .medium
        else if (referenced > 0)
            .low
        else
            .none;

        try results.append(allocator, .{
            .file = outline.path,
            .total_symbols = total,
            .public_symbols = public_count,
            .test_symbols = test_count,
            .referenced_in_tests = referenced,
            .coverage_level = coverage,
        });
    }

    return try results.toOwnedSlice(allocator);
}

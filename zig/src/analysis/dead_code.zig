const std = @import("std");
const explorer = @import("../index/explorer.zig");
const models = @import("../core/models.zig");

pub const DeadSymbol = struct {
    name: []const u8,
    kind: models.SymbolKind,
    file: []const u8,
    line: usize,
    reason: []const u8,
};

/// Skip list: symbols that are commonly used externally without explicit references.
const skip_names = [_][]const u8{
    "main",  "new",  "default",  "init",     "deinit", "drop",   "clone",     "fmt",
    "from",  "into", "try_from", "try_into", "as_ref", "as_mut", "serialize", "deserialize",
    "build", "run",  "start",    "stop",
};

fn should_skip(name: []const u8, kind: models.SymbolKind) bool {
    // Skip test functions
    if (kind == .@"test") return true;
    // Skip impl blocks
    if (kind == .impl) return true;
    // Skip imports/modules
    if (kind == .import or kind == .module) return true;
    // Skip short names (likely getters/setters)
    if (name.len <= 2) return true;
    // Skip known names
    for (&skip_names) |s| {
        if (std.mem.eql(u8, name, s)) return true;
    }
    // Skip PascalCase in tsx/jsx (React components)
    if (name.len > 0 and std.ascii.isUpper(name[0])) return false; // don't skip, but it's noted
    return false;
}

pub fn find_dead_code(allocator: std.mem.Allocator, exp: *explorer.Explorer) ![]DeadSymbol {
    var results = std.ArrayList(DeadSymbol).empty;

    var it = exp.outlines.iterator();
    while (it.next()) |entry| {
        const file_id = entry.key_ptr.*;
        if (exp.deleted_files.get(file_id) != null) continue;
        const outline = entry.value_ptr.*;

        for (outline.symbols) |sym| {
            if (should_skip(sym.name, sym.kind)) continue;

            // Check if symbol appears in word index in other files. Postings
            // are file-id sets and may be stale toward false positives (a file
            // that dropped the word keeps its entry until compaction) — for
            // dead-code detection that errs toward "used", never toward
            // falsely reporting dead.
            const hits = exp.words.search(sym.name);
            var used_externally = false;
            for (hits) |hit_file_id| {
                if (hit_file_id != file_id) {
                    used_externally = true;
                    break;
                }
            }

            if (!used_externally) {
                try results.append(allocator, .{
                    .name = sym.name,
                    .kind = sym.kind,
                    .file = outline.path,
                    .line = sym.start_1(),
                    .reason = "no references outside defining file",
                });
            }
        }
    }

    return try results.toOwnedSlice(allocator);
}

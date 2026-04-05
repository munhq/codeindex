const std = @import("std");
const explorer = @import("../index/explorer.zig");
const models = @import("../core/models.zig");

pub const Migration = struct {
    sequence: u32,
    name: []const u8,
    file: []const u8,
};

pub const Issue = struct {
    issue_type: enum { gap, duplicate, out_of_order },
    description: []const u8,
    file: []const u8,
};

pub const Report = struct {
    total_migrations: usize,
    issues: []Issue,
};

pub fn analyze(allocator: std.mem.Allocator, exp: *explorer.Explorer) !Report {
    var migrations = std.ArrayList(Migration){};
    var issues = std.ArrayList(Issue){};

    // Find migration files by path pattern
    var it = exp.outlines.iterator();
    while (it.next()) |entry| {
        const file_id = entry.key_ptr.*;
        if (exp.deleted_files.get(file_id) != null) continue;
        const outline = entry.value_ptr.*;

        if (std.mem.indexOf(u8, outline.path, "migration") == null) continue;
        if (!std.mem.endsWith(u8, outline.path, ".sql") and
            !std.mem.endsWith(u8, outline.path, ".rs") and
            !std.mem.endsWith(u8, outline.path, ".py") and
            !std.mem.endsWith(u8, outline.path, ".ts")) continue;

        // Extract sequence number from filename (e.g., 001_create_users.sql, V2__create_table.sql)
        const basename = std.fs.path.basename(outline.path);
        const seq = parseSequence(basename);
        if (seq > 0) {
            try migrations.append(allocator, .{
                .sequence = seq,
                .name = basename,
                .file = outline.path,
            });
        }
    }

    // Sort by sequence
    std.mem.sort(Migration, migrations.items, {}, struct {
        fn lessThan(_: void, a: Migration, b: Migration) bool {
            return a.sequence < b.sequence;
        }
    }.lessThan);

    // Check for gaps and duplicates
    for (migrations.items, 0..) |m, i| {
        if (i > 0) {
            const prev = migrations.items[i - 1];
            if (m.sequence == prev.sequence) {
                try issues.append(allocator, .{
                    .issue_type = .duplicate,
                    .description = "Duplicate migration sequence number",
                    .file = m.file,
                });
            } else if (m.sequence > prev.sequence + 1) {
                try issues.append(allocator, .{
                    .issue_type = .gap,
                    .description = "Gap in migration sequence",
                    .file = m.file,
                });
            }
        }
    }

    return .{
        .total_migrations = migrations.items.len,
        .issues = try issues.toOwnedSlice(allocator),
    };
}

fn parseSequence(filename: []const u8) u32 {
    // Try patterns: "001_...", "V1__...", "1_...", "20231015_..."
    var i: usize = 0;

    // Skip V prefix
    if (filename.len > 0 and (filename[0] == 'V' or filename[0] == 'v')) i = 1;

    // Read digits
    var num: u32 = 0;
    var found_digit = false;
    while (i < filename.len and std.ascii.isDigit(filename[i])) {
        num = num * 10 + @as(u32, filename[i] - '0');
        found_digit = true;
        i += 1;
    }

    if (found_digit) return num;
    return 0;
}

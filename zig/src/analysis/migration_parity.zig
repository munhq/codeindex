//! Sequence problems inside ONE migration directory.
//!
//! A repository can hold several, each with its own `migrate!()` against its own
//! database: `migrations/`, `migrations/sqlite/`, `migrations/analytics/`. Their
//! numbers are independent, and `0001_init.sql` is expected to appear in each.
//!
//! This analyzer used to flatten every migration file in the tree into one
//! sequence. On a repository with three directories it reported 107 duplicates,
//! all of them false. Acting on one is destructive: renumbering a migration
//! changes the `_sqlx_migrations` checksum in every deployed database, and the
//! pod then refuses to start. So the grouping is by directory, and a gap is only
//! reported where the directory numbers its files sequentially.

const std = @import("std");
const explorer = @import("../index/explorer.zig");
const models = @import("../core/models.zig");

pub const Migration = struct {
    sequence: u32,
    name: []const u8,
    file: []const u8,
    /// Directory the file lives in. Sequences are per directory.
    dir: []const u8,
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
    // The migration list is scratch: only `issues` is returned. Without this the
    // backing array leaked on every call.
    var migrations = std.ArrayList(Migration).empty;
    defer migrations.deinit(allocator);
    var issues = std.ArrayList(Issue).empty;
    errdefer issues.deinit(allocator);

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
                .dir = std.fs.path.dirname(outline.path) orelse "",
            });
        }
    }

    // Sort by directory first, then by sequence, so each directory forms one
    // contiguous run and the comparison never crosses a boundary.
    std.mem.sort(Migration, migrations.items, {}, struct {
        fn lessThan(_: void, a: Migration, b: Migration) bool {
            const dir_order = std.mem.order(u8, a.dir, b.dir);
            if (dir_order != .eq) return dir_order == .lt;
            return a.sequence < b.sequence;
        }
    }.lessThan);

    for (migrations.items, 0..) |m, i| {
        if (i == 0) continue;
        const prev = migrations.items[i - 1];
        // A new directory starts a new sequence.
        if (!std.mem.eql(u8, m.dir, prev.dir)) continue;

        if (m.sequence == prev.sequence) {
            try issues.append(allocator, .{
                .issue_type = .duplicate,
                .description = "Duplicate migration sequence number in this directory",
                .file = m.file,
            });
            continue;
        }
        // A timestamp-named migration (20231015_…) leaves a gap against the
        // next one by definition. Only a directory that counts 1, 2, 3 can have
        // a gap that means anything.
        if (!is_sequential(prev.sequence) or !is_sequential(m.sequence)) continue;
        if (m.sequence > prev.sequence + 1) {
            try issues.append(allocator, .{
                .issue_type = .gap,
                .description = "Gap in migration sequence",
                .file = m.file,
            });
        }
    }

    return .{
        .total_migrations = migrations.items.len,
        .issues = try issues.toOwnedSlice(allocator),
    };
}

/// A small counter, not a date or a Unix timestamp. `0042` counts; `20231015`
/// and `1697328000` are stamps, and the distance between two of them says
/// nothing about a missing file.
fn is_sequential(seq: u32) bool {
    return seq < 10_000;
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

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn migration_file(allocator: std.mem.Allocator, path: []const u8) !models.FileOutline {
    return .{
        .path = try allocator.dupe(u8, path),
        .language = .sql,
        .line_count = 1,
        .byte_size = 1,
        .symbols = &[_]models.Symbol{},
        .imports = &[_][]const u8{},
    };
}

test "migration_parity: two directories may share a sequence number" {
    const allocator = testing.allocator;
    // Each directory has its own `migrate!()` against its own database, so
    // `0001_init.sql` is expected in both. Flattening them reported 107 false
    // duplicates on one repository, and a renumber breaks every deployed
    // `_sqlx_migrations` checksum.
    var exp = try explorer.Explorer.init(allocator);
    defer exp.deinit();
    const paths = [_][]const u8{
        "migrations/0001_init.sql",
        "migrations/0002_dashboard.sql",
        "migrations/sqlite/0001_init.sql",
        "migrations/sqlite/0002_teams.sql",
    };
    for (&paths) |p| _ = try exp.add_file(try migration_file(allocator, p), "SELECT 1;");
    exp.mark_indexing_complete();

    const report = try analyze(allocator, &exp);
    defer allocator.free(report.issues);
    try testing.expectEqual(@as(usize, 4), report.total_migrations);
    try testing.expectEqual(@as(usize, 0), report.issues.len);
}

test "migration_parity: a duplicate inside one directory is still reported" {
    const allocator = testing.allocator;
    var exp = try explorer.Explorer.init(allocator);
    defer exp.deinit();
    _ = try exp.add_file(try migration_file(allocator, "migrations/0001_init.sql"), "SELECT 1;");
    _ = try exp.add_file(try migration_file(allocator, "migrations/0001_users.sql"), "SELECT 1;");
    exp.mark_indexing_complete();

    const report = try analyze(allocator, &exp);
    defer allocator.free(report.issues);
    try testing.expectEqual(@as(usize, 1), report.issues.len);
    try testing.expectEqual(@as(usize, 1), @intFromEnum(report.issues[0].issue_type));
}

test "migration_parity: a real gap inside one directory is reported" {
    const allocator = testing.allocator;
    var exp = try explorer.Explorer.init(allocator);
    defer exp.deinit();
    _ = try exp.add_file(try migration_file(allocator, "migrations/0015_a.sql"), "SELECT 1;");
    _ = try exp.add_file(try migration_file(allocator, "migrations/0017_b.sql"), "SELECT 1;");
    exp.mark_indexing_complete();

    const report = try analyze(allocator, &exp);
    defer allocator.free(report.issues);
    try testing.expectEqual(@as(usize, 1), report.issues.len);
    try testing.expectEqual(@as(usize, 0), @intFromEnum(report.issues[0].issue_type));
}

test "migration_parity: timestamp names have no gaps" {
    const allocator = testing.allocator;
    // Consecutive timestamp migrations are always far apart. Every one of them
    // used to report a gap.
    var exp = try explorer.Explorer.init(allocator);
    defer exp.deinit();
    _ = try exp.add_file(try migration_file(allocator, "migrations/20231015_a.sql"), "SELECT 1;");
    _ = try exp.add_file(try migration_file(allocator, "migrations/20231102_b.sql"), "SELECT 1;");
    _ = try exp.add_file(try migration_file(allocator, "migrations/20240301_c.sql"), "SELECT 1;");
    exp.mark_indexing_complete();

    const report = try analyze(allocator, &exp);
    defer allocator.free(report.issues);
    try testing.expectEqual(@as(usize, 3), report.total_migrations);
    try testing.expectEqual(@as(usize, 0), report.issues.len);
}

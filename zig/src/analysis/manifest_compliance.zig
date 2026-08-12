const std = @import("std");
const explorer = @import("../index/explorer.zig");
const models = @import("../core/models.zig");

pub const ViolationType = enum {
    missing_field,
    suspicious_dependency,
    version_mismatch,
    credential_in_manifest,
    unused_dependency,

    pub fn as_str(self: ViolationType) []const u8 {
        return switch (self) {
            .missing_field => "missing_field",
            .suspicious_dependency => "suspicious_dependency",
            .version_mismatch => "version_mismatch",
            .credential_in_manifest => "credential_in_manifest",
            .unused_dependency => "unused_dependency",
        };
    }
};

pub const Violation = struct {
    violation_type: ViolationType,
    file: []const u8,
    line: usize,
    description: []const u8,
};

pub const Report = struct {
    manifests_checked: usize,
    violations: []Violation,
};

const credential_patterns = [_][]const u8{
    "password",   "secret",     "api_key",    "token", "private_key",
    "access_key", "auth_token", "credential",
};

const required_fields_cargo = [_][]const u8{
    "name", "version", "edition",
};

const required_fields_package_json = [_][]const u8{
    "name", "version",
};

pub fn analyze(allocator: std.mem.Allocator, exp: *explorer.Explorer) !Report {
    var violations = std.ArrayList(Violation).empty;
    var manifests_checked: usize = 0;

    var it = exp.outlines.iterator();
    while (it.next()) |entry| {
        const file_id = entry.key_ptr.*;
        if (exp.deleted_files.get(file_id) != null) continue;
        const outline = entry.value_ptr.*;
        const content = exp.content_cache.get(file_id) orelse continue;
        const basename = std.fs.path.basename(outline.path);

        const is_cargo = std.mem.eql(u8, basename, "Cargo.toml");
        const is_package_json = std.mem.eql(u8, basename, "package.json");
        const is_go_mod = std.mem.eql(u8, basename, "go.mod");

        if (!is_cargo and !is_package_json and !is_go_mod) continue;
        manifests_checked += 1;

        // Check for credentials in manifest
        var line_num: usize = 1;
        var lines_it = std.mem.splitScalar(u8, content, '\n');
        while (lines_it.next()) |line| {
            const lower_line = line; // We'll check case-insensitively
            for (&credential_patterns) |pattern| {
                if (containsInsensitive(lower_line, pattern)) {
                    // Check if it looks like a real value (has = or : followed by a quoted string)
                    if (std.mem.indexOf(u8, line, "\"") != null and
                        (std.mem.indexOf(u8, line, "=") != null or std.mem.indexOf(u8, line, ":") != null))
                    {
                        // Skip if it's clearly a dependency name
                        if (std.mem.indexOf(u8, line, "[dependencies]") != null) continue;
                        if (std.mem.indexOf(u8, line, "\"dependencies\"") != null) continue;

                        try violations.append(allocator, .{
                            .violation_type = .credential_in_manifest,
                            .file = outline.path,
                            .line = line_num,
                            .description = "Possible credential in manifest file",
                        });
                    }
                }
            }
            line_num += 1;
        }

        // Check required fields
        if (is_cargo) {
            for (&required_fields_cargo) |field| {
                if (std.mem.indexOf(u8, content, field) == null) {
                    try violations.append(allocator, .{
                        .violation_type = .missing_field,
                        .file = outline.path,
                        .line = 1,
                        .description = field,
                    });
                }
            }
        }

        if (is_package_json) {
            for (&required_fields_package_json) |field| {
                // Check if "fieldname" appears in content
                var found = false;
                if (std.mem.indexOf(u8, content, field)) |pos| {
                    // Verify it's quoted (JSON key)
                    if (pos > 0 and content[pos - 1] == '"') found = true;
                }
                if (!found) {
                    try violations.append(allocator, .{
                        .violation_type = .missing_field,
                        .file = outline.path,
                        .line = 1,
                        .description = field,
                    });
                }
            }
        }
    }

    return .{
        .manifests_checked = manifests_checked,
        .violations = try violations.toOwnedSlice(allocator),
    };
}

fn containsInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var match = true;
        for (0..needle.len) |j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

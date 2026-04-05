const std = @import("std");
const explorer = @import("../index/explorer.zig");

pub const Violation = struct {
    from_file: []const u8,
    to_file: []const u8,
    from_layer: []const u8,
    to_layer: []const u8,
    description: []const u8,
};

/// Layer hierarchy: higher layers should not be imported by lower layers.
const layers = [_]struct { name: []const u8, dirs: []const []const u8 }{
    .{ .name = "presentation", .dirs = &.{ "gateway", "api", "routes", "handlers", "views", "pages", "components" } },
    .{ .name = "application", .dirs = &.{ "services", "controllers", "commands", "use_cases" } },
    .{ .name = "domain", .dirs = &.{ "models", "domain", "entities", "types" } },
    .{ .name = "infrastructure", .dirs = &.{ "db", "nats", "redis", "storage", "persistence", "adapters" } },
};

fn get_layer(path: []const u8) ?struct { name: []const u8, rank: usize } {
    for (layers, 0..) |layer, rank| {
        for (layer.dirs) |dir| {
            if (std.mem.indexOf(u8, path, dir) != null) {
                return .{ .name = layer.name, .rank = rank };
            }
        }
    }
    return null;
}

pub fn analyze(allocator: std.mem.Allocator, exp: *explorer.Explorer) ![]Violation {
    var violations = std.ArrayList(Violation){};

    var it = exp.depgraph.imports.iterator();
    while (it.next()) |entry| {
        const from_id = entry.key_ptr.*;
        const from_path = exp.file_path(from_id) orelse continue;
        const from_layer = get_layer(from_path) orelse continue;

        for (entry.value_ptr.items) |to_id| {
            const to_path = exp.file_path(to_id) orelse continue;
            const to_layer = get_layer(to_path) orelse continue;

            // Lower layers (higher rank) should not import from upper layers (lower rank)
            if (from_layer.rank > to_layer.rank) {
                try violations.append(allocator, .{
                    .from_file = from_path,
                    .to_file = to_path,
                    .from_layer = from_layer.name,
                    .to_layer = to_layer.name,
                    .description = "Lower layer imports from upper layer",
                });
            }
        }
    }

    return try violations.toOwnedSlice(allocator);
}

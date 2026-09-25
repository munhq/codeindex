//! Which deployed unit runs which source file.
//!
//! A limit in a manifest applies to the unit that manifest deploys, and a
//! constant in the code applies to the unit that runs the code. A repository
//! with several services holds several limits, and comparing a constant with
//! the smallest of them can pair it with a service that never runs it.
//!
//! A unit is a Kubernetes workload, a Compose service or a Helm chart. It names
//! the images it runs. An image is linked to the build context that produces
//! it by a Compose `build:`, a `docker build -t <image> <context>` line, a
//! `docker/build-push-action` step, an image named after a directory that holds
//! a Dockerfile, or the only Dockerfile in the repository. A file belongs to the
//! units whose build context holds it. A repository with one unit deploys every
//! file with it.
//!
//! Index keys use `/` on every platform, so every path here goes through the
//! POSIX path functions. `std.fs.path.join` joined with `\` on Windows, and no
//! context held any file there.

const std = @import("std");
const explorer = @import("../index/explorer.zig");
const models = @import("../core/models.zig");

pub const Located = struct {
    file: []const u8,
    /// 1-based.
    line: usize,
};

pub const Number = struct {
    value: u64,
    at: Located,
};

pub const Quantity = struct {
    bytes: u64,
    /// As written: `512Mi`.
    text: []const u8,
    at: Located,
};

pub const EnvVar = struct {
    name: []const u8,
    value: []const u8,
    at: Located,
};

pub const Unit = struct {
    name: []const u8,
    /// `Deployment`, `StatefulSet`, `compose service`, `helm chart`, …
    kind: []const u8,
    at: Located,
    images: std.ArrayList([]const u8) = .empty,
    /// Absolute directories whose files the unit runs.
    contexts: std.ArrayList([]const u8) = .empty,
    memory_limits: std.ArrayList(Quantity) = .empty,
    replicas: ?Number = null,
    /// An autoscaler's `maxReplicas`, which bounds the unit's copies.
    max_replicas: ?Number = null,
    env: std.ArrayList(EnvVar) = .empty,

    /// Copies of the unit that can run at once.
    pub fn copies(self: Unit) Number {
        if (self.max_replicas) |m| return m;
        if (self.replicas) |r| return r;
        return .{ .value = 1, .at = self.at };
    }
};

/// Something that accepts database connections, with how many.
pub const Provider = struct {
    name: []const u8,
    /// `CNPG Pooler`, `pgbouncer`, `postgres max_connections`.
    kind: []const u8,
    capacity: u64,
    at: Located,
};

pub const Units = struct {
    arena: std.heap.ArenaAllocator,
    units: std.ArrayList(Unit) = .empty,
    providers: std.ArrayList(Provider) = .empty,

    pub fn deinit(self: *Units) void {
        self.arena.deinit();
    }

    /// Indices of the units that run the file at `path`. A context nested in
    /// another is its own build: `docker/tts/` inside a root context belongs
    /// to the unit that builds `docker/tts/`, so the deepest context wins.
    pub fn units_for(self: *const Units, path: []const u8, out: *std.ArrayList(usize), allocator: std.mem.Allocator) !void {
        out.clearRetainingCapacity();
        var deepest: usize = 0;
        for (self.units.items) |u| {
            for (u.contexts.items) |ctx| {
                if (within(path, ctx) and ctx.len > deepest) deepest = ctx.len;
            }
        }
        for (self.units.items, 0..) |u, i| {
            for (u.contexts.items) |ctx| {
                if (within(path, ctx) and ctx.len == deepest) {
                    try out.append(allocator, i);
                    break;
                }
            }
        }
        if (out.items.len == 0 and self.units.items.len == 1) try out.append(allocator, 0);
    }
};

fn within(path: []const u8, dir: []const u8) bool {
    if (dir.len == 0) return true;
    if (!std.mem.startsWith(u8, path, dir)) return false;
    return path.len == dir.len or path[dir.len] == '/' or dir[dir.len - 1] == '/';
}

// ── Quantities ───────────────────────────────────────────────────────────────

/// A Kubernetes or Compose quantity in bytes: `512Mi`, `1Gi`, `350M`, `512m`.
pub fn parse_quantity(text_in: []const u8) ?u64 {
    const text = std.mem.trim(u8, text_in, " \t\"'");
    if (text.len == 0 or !std.ascii.isDigit(text[0])) return null;
    var end: usize = 0;
    while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
    const n = std.fmt.parseInt(u64, text[0..end], 10) catch return null;
    const unit = text[end..];
    if (unit.len == 0) return n;
    const table = [_]struct { u: []const u8, m: u64 }{
        .{ .u = "Ki", .m = 1024 },               .{ .u = "Mi", .m = 1024 * 1024 },
        .{ .u = "Gi", .m = 1024 * 1024 * 1024 }, .{ .u = "Ti", .m = 1024 * 1024 * 1024 * 1024 },
        .{ .u = "K", .m = 1000 },                .{ .u = "k", .m = 1000 },
        .{ .u = "M", .m = 1000 * 1000 },         .{ .u = "m", .m = 1024 * 1024 },
        .{ .u = "G", .m = 1000 * 1000 * 1000 },  .{ .u = "g", .m = 1024 * 1024 * 1024 },
        .{ .u = "b", .m = 1 },
    };
    for (&table) |t| {
        if (std.mem.eql(u8, unit, t.u)) return n * t.m;
    }
    return null;
}

fn parse_int(text_in: []const u8) ?u64 {
    const text = std.mem.trim(u8, text_in, " \t\"'");
    return std.fmt.parseInt(u64, text, 10) catch null;
}

// ── A small YAML path reader ─────────────────────────────────────────────────

/// One `key: value` line with the dotted path of keys above it. A list item
/// (`- name: x`) opens a new element of the list it sits in, and `item`
/// counts the elements so two containers or two env vars stay apart.
const YamlLine = struct {
    path: []const u8,
    key: []const u8,
    value: []const u8,
    line: usize,
    item: usize,
    anchor: ?[]const u8 = null,
};

const Frame = struct { indent: usize, key: []const u8 };

fn strip_comment(v: []const u8) []const u8 {
    var quote: u8 = 0;
    for (v, 0..) |c, i| {
        if (quote != 0) {
            if (c == quote) quote = 0;
            continue;
        }
        if (c == '"' or c == '\'') quote = c;
        if (c == '#' and (i == 0 or v[i - 1] == ' ')) return std.mem.trimEnd(u8, v[0..i], " \t");
    }
    return v;
}

fn unquote(v: []const u8) []const u8 {
    const t = std.mem.trim(u8, v, " \t");
    if (t.len >= 2 and (t[0] == '"' or t[0] == '\'') and t[t.len - 1] == t[0]) return t[1 .. t.len - 1];
    return t;
}

/// The documents of a YAML file, each as its lines with their key paths.
fn read_yaml(a: std.mem.Allocator, content: []const u8) ![]std.ArrayList(YamlLine) {
    var docs = std.ArrayList(std.ArrayList(YamlLine)).empty;
    try docs.append(a, .empty);
    var stack = std.ArrayList(Frame).empty;
    var item: usize = 0;
    var line_no: usize = 0;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |raw_line| {
        line_no += 1;
        const raw = std.mem.trimEnd(u8, raw_line, " \t\r");
        const trimmed = std.mem.trimStart(u8, raw, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        if (std.mem.startsWith(u8, trimmed, "---")) {
            try docs.append(a, .empty);
            stack.clearRetainingCapacity();
            continue;
        }
        var indent = raw.len - trimmed.len;
        var body = trimmed;
        var list_item = false;
        // `- key: value` opens a list element at the dash's column + 2.
        while (std.mem.startsWith(u8, body, "- ") or std.mem.eql(u8, body, "-")) {
            list_item = true;
            body = std.mem.trimStart(u8, body[1..], " ");
            indent += 2;
            if (body.len == 0) break;
        }
        if (list_item) item += 1;
        while (stack.items.len > 0 and stack.items[stack.items.len - 1].indent >= indent) _ = stack.pop();

        const colon = key_colon(body) orelse {
            // A plain list entry: `- KEY=value` in a Compose environment list.
            if (list_item and body.len > 0) try docs.items[docs.items.len - 1].append(a, .{
                .path = std.mem.trimEnd(u8, try join_path(a, stack.items, ""), "."),
                .key = "",
                .value = unquote(strip_comment(body)),
                .line = line_no,
                .item = item,
            });
            continue;
        };
        const key = unquote(body[0..colon]);
        var value = unquote(strip_comment(std.mem.trim(u8, body[colon + 1 ..], " \t")));
        const path = try join_path(a, stack.items, key);
        // `x-build: &build` names the mapping below it for a later `<<: *build`.
        var anchor: ?[]const u8 = null;
        if (value.len > 1 and value[0] == '&') {
            anchor = value[1..];
            value = "";
        }
        try docs.items[docs.items.len - 1].append(a, .{ .path = path, .key = key, .value = value, .line = line_no, .item = item, .anchor = anchor });
        if (value.len == 0 or std.mem.eql(u8, value, "|") or std.mem.eql(u8, value, ">") or std.mem.eql(u8, value, "|-")) {
            try stack.append(a, .{ .indent = indent, .key = key });
        }
    }
    for (docs.items) |*d| try merge_anchors(a, d);
    return docs.toOwnedSlice(a);
}

/// Resolve `<<: *name` merge keys: the anchored mapping's lines are copied
/// under the mapping that merges them. Compose files share a build block
/// between services this way.
fn merge_anchors(a: std.mem.Allocator, doc: *std.ArrayList(YamlLine)) !void {
    var added = std.ArrayList(YamlLine).empty;
    for (doc.items) |m| {
        if (!std.mem.eql(u8, m.key, "<<") or m.value.len < 2 or m.value[0] != '*') continue;
        const name = m.value[1..];
        const parent = if (std.mem.lastIndexOfScalar(u8, m.path, '.')) |dot| m.path[0..dot] else "";
        for (doc.items) |anch| {
            const an = anch.anchor orelse continue;
            if (!std.mem.eql(u8, an, name)) continue;
            const prefix = try std.fmt.allocPrint(a, "{s}.", .{anch.path});
            for (doc.items) |l| {
                if (!std.mem.startsWith(u8, l.path, prefix)) continue;
                const sub = l.path[prefix.len..];
                const path = if (parent.len == 0) sub else try std.fmt.allocPrint(a, "{s}.{s}", .{ parent, sub });
                try added.append(a, .{ .path = path, .key = l.key, .value = l.value, .line = l.line, .item = m.item });
            }
        }
    }
    try doc.appendSlice(a, added.items);
}

/// The colon that ends a mapping key, outside quotes and not in a URL.
fn key_colon(body: []const u8) ?usize {
    var quote: u8 = 0;
    for (body, 0..) |c, i| {
        if (quote != 0) {
            if (c == quote) quote = 0;
            continue;
        }
        if (c == '"' or c == '\'') {
            if (i == 0) quote = c;
            continue;
        }
        if (c == ':' and (i + 1 == body.len or body[i + 1] == ' ')) return i;
        if (c == ' ' and i == 0) return null;
    }
    return null;
}

fn join_path(a: std.mem.Allocator, frames: []const Frame, key: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    for (frames) |f| {
        try out.appendSlice(a, f.key);
        try out.append(a, '.');
    }
    try out.appendSlice(a, key);
    return out.toOwnedSlice(a);
}

fn find_value(doc: []const YamlLine, path: []const u8) ?YamlLine {
    for (doc) |l| {
        if (std.mem.eql(u8, l.path, path)) return l;
    }
    return null;
}

fn ends_with(path: []const u8, suffix: []const u8) bool {
    return std.mem.endsWith(u8, path, suffix) and (path.len == suffix.len or path[path.len - suffix.len - 1] == '.');
}

// ── Collection ───────────────────────────────────────────────────────────────

const workload_kinds = [_][]const u8{ "Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob", "ReplicaSet" };

fn is_workload(kind: []const u8) bool {
    for (&workload_kinds) |k| {
        if (std.mem.eql(u8, kind, k)) return true;
    }
    return false;
}

/// Index keys use `/` on every platform, so paths are split the POSIX way.
fn stem_posix(path: []const u8) []const u8 {
    const base = std.fs.path.basenamePosix(path);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return base;
    return if (dot == 0) base else base[0..dot];
}

fn loc(path: []const u8, line: usize) Located {
    return .{ .file = path, .line = line };
}

/// The workload fields of a pod template, wherever the kind nests it.
fn read_pod_fields(a: std.mem.Allocator, u: *Unit, doc: []const YamlLine, path: []const u8) !void {
    var env_name: ?YamlLine = null;
    for (doc) |l| {
        if (ends_with(l.path, "containers.image") or ends_with(l.path, "initContainers.image")) {
            try u.images.append(a, l.value);
        } else if (ends_with(l.path, "resources.limits.memory")) {
            if (parse_quantity(l.value)) |b| try u.memory_limits.append(a, .{ .bytes = b, .text = l.value, .at = loc(path, l.line) });
        } else if (ends_with(l.path, "env.name")) {
            env_name = l;
        } else if (ends_with(l.path, "env.value")) {
            if (env_name) |n| {
                if (n.item == l.item) try u.env.append(a, .{ .name = n.value, .value = l.value, .at = loc(path, l.line) });
            }
        }
    }
}

/// An autoscaler and the workload it scales.
const Hpa = struct { target: []const u8, max: Number };

fn collect_kubernetes(a: std.mem.Allocator, path: []const u8, docs: []std.ArrayList(YamlLine), units: *Units, hpas: *std.ArrayList(Hpa)) !void {
    for (docs) |doc_list| {
        const doc = doc_list.items;
        const kind = (find_value(doc, "kind") orelse continue).value;
        const name_line = find_value(doc, "metadata.name");
        const name = if (name_line) |n| n.value else stem_posix(path);
        const at = loc(path, if (name_line) |n| n.line else 1);
        if (is_workload(kind)) {
            var u = Unit{ .name = name, .kind = kind, .at = at };
            if (find_value(doc, "spec.replicas")) |r| {
                if (parse_int(r.value)) |v| u.replicas = .{ .value = v, .at = loc(path, r.line) };
            }
            try read_pod_fields(a, &u, doc, path);
            try units.units.append(a, u);
        } else if (std.mem.eql(u8, kind, "HorizontalPodAutoscaler")) {
            const target = find_value(doc, "spec.scaleTargetRef.name") orelse continue;
            const max = find_value(doc, "spec.maxReplicas") orelse continue;
            const v = parse_int(max.value) orelse continue;
            try hpas.append(a, .{ .target = target.value, .max = .{ .value = v, .at = loc(path, max.line) } });
        } else if (std.mem.eql(u8, kind, "Pooler")) {
            // CloudNativePG: each pgbouncer instance accepts max_client_conn.
            const conn = find_value(doc, "spec.pgbouncer.parameters.max_client_conn") orelse continue;
            const per = parse_int(conn.value) orelse continue;
            const instances = if (find_value(doc, "spec.instances")) |i| parse_int(i.value) orelse 1 else 1;
            try units.providers.append(a, .{ .name = name, .kind = "CNPG Pooler", .capacity = per * instances, .at = loc(path, conn.line) });
        } else if (std.mem.eql(u8, kind, "Cluster")) {
            const conn = find_value(doc, "spec.postgresql.parameters.max_connections") orelse continue;
            const v = parse_int(conn.value) orelse continue;
            try units.providers.append(a, .{ .name = name, .kind = "postgres max_connections", .capacity = v, .at = loc(path, conn.line) });
        }
    }
}

fn is_compose_file(base: []const u8) bool {
    return (std.mem.startsWith(u8, base, "docker-compose") or std.mem.startsWith(u8, base, "compose")) and
        (std.mem.endsWith(u8, base, ".yml") or std.mem.endsWith(u8, base, ".yaml"));
}

fn collect_compose(a: std.mem.Allocator, path: []const u8, docs: []std.ArrayList(YamlLine), units: *Units) !void {
    const dir = std.fs.path.dirnamePosix(path) orelse "";
    for (docs) |doc_list| {
        const doc = doc_list.items;
        var names = std.ArrayList([]const u8).empty;
        for (doc) |l| {
            if (std.mem.startsWith(u8, l.path, "services.") and std.mem.indexOfScalar(u8, l.path["services.".len..], '.') == null) {
                try names.append(a, l.key);
            }
        }
        for (names.items) |svc| {
            const prefix = try std.fmt.allocPrint(a, "services.{s}.", .{svc});
            const head = find_value(doc, prefix[0 .. prefix.len - 1]);
            var u = Unit{ .name = svc, .kind = "compose service", .at = loc(path, if (head) |h| h.line else 1) };
            for (doc) |l| {
                if (!std.mem.startsWith(u8, l.path, prefix)) continue;
                const sub = l.path[prefix.len..];
                if (std.mem.eql(u8, sub, "image")) {
                    try u.images.append(a, l.value);
                } else if (std.mem.eql(u8, sub, "build") and l.value.len > 0) {
                    try add_context(a, &u, try resolve_dir(a, dir, l.value));
                } else if (std.mem.eql(u8, sub, "build.context")) {
                    try add_context(a, &u, try resolve_dir(a, dir, l.value));
                } else if (std.mem.eql(u8, sub, "mem_limit") or std.mem.eql(u8, sub, "deploy.resources.limits.memory")) {
                    if (parse_quantity(l.value)) |b| try u.memory_limits.append(a, .{ .bytes = b, .text = l.value, .at = loc(path, l.line) });
                } else if (std.mem.eql(u8, sub, "deploy.replicas")) {
                    if (parse_int(l.value)) |v| u.replicas = .{ .value = v, .at = loc(path, l.line) };
                } else if (std.mem.eql(u8, sub, "environment") and l.key.len == 0) {
                    // `- KEY=value`
                    if (std.mem.indexOfScalar(u8, l.value, '=')) |eq| {
                        try u.env.append(a, .{ .name = l.value[0..eq], .value = l.value[eq + 1 ..], .at = loc(path, l.line) });
                    }
                } else if (std.mem.startsWith(u8, sub, "environment.")) {
                    try u.env.append(a, .{ .name = l.key, .value = l.value, .at = loc(path, l.line) });
                }
            }
            try units.units.append(a, u);
        }
    }
}

/// A Helm chart: `Chart.yaml` with the `values.yaml` beside it. The chart's
/// templates read these values; the values are what a deploy sets.
fn collect_helm(a: std.mem.Allocator, chart_dir: []const u8, values_path: []const u8, docs: []std.ArrayList(YamlLine), units: *Units) !void {
    if (docs.len == 0) return;
    const doc = docs[0].items;
    var u = Unit{ .name = std.fs.path.basenamePosix(chart_dir), .kind = "helm chart", .at = loc(values_path, 1) };
    for (doc) |l| {
        if (std.mem.eql(u8, l.path, "replicaCount")) {
            if (parse_int(l.value)) |v| u.replicas = .{ .value = v, .at = loc(values_path, l.line) };
        } else if (std.mem.eql(u8, l.path, "image.repository") or std.mem.eql(u8, l.path, "image")) {
            if (l.value.len > 0) try u.images.append(a, l.value);
        } else if (ends_with(l.path, "resources.limits.memory")) {
            if (parse_quantity(l.value)) |b| try u.memory_limits.append(a, .{ .bytes = b, .text = l.value, .at = loc(values_path, l.line) });
        } else if (std.mem.eql(u8, l.path, "autoscaling.maxReplicas")) {
            if (parse_int(l.value)) |v| u.max_replicas = .{ .value = v, .at = loc(values_path, l.line) };
        }
    }
    try units.units.append(a, u);
}

fn resolve_dir(a: std.mem.Allocator, base: []const u8, rel_in: []const u8) ![]const u8 {
    var rel = rel_in;
    while (std.mem.startsWith(u8, rel, "./")) rel = rel[2..];
    if (std.mem.eql(u8, rel, ".") or rel.len == 0) return a.dupe(u8, base);
    if (std.fs.path.isAbsolutePosix(rel)) return a.dupe(u8, rel);
    const joined = try std.fmt.allocPrint(a, "{s}/{s}", .{ base, rel });
    return std.fs.path.resolvePosix(a, &.{joined}) catch joined;
}

/// `ghcr.io/acme/api:1.2` → `api`.
fn image_repo(image: []const u8) []const u8 {
    var s = image;
    if (std.mem.indexOfScalar(u8, s, '@')) |at| s = s[0..at];
    const slash = std.mem.lastIndexOfScalar(u8, s, '/');
    const after_slash = if (slash) |i| s[i + 1 ..] else s;
    if (std.mem.indexOfScalar(u8, after_slash, ':')) |c| return after_slash[0..c];
    // Helm templates spell images as `{{ … }}`; strip anything after one.
    if (std.mem.indexOf(u8, after_slash, "{{")) |c| return after_slash[0..c];
    return after_slash;
}

const Build = struct { repo: []const u8, context: []const u8 };

/// `docker build -t ghcr.io/acme/api:1 -f api/Dockerfile api` →
/// (`api`, `<dir>/api`). The context is the last positional argument.
fn parse_build_command(a: std.mem.Allocator, base_dir: []const u8, line: []const u8, out: *std.ArrayList(Build)) !void {
    const at = std.mem.indexOf(u8, line, " build ") orelse return;
    const before = line[0..at];
    if (std.mem.indexOf(u8, before, "docker") == null and std.mem.indexOf(u8, before, "podman") == null) return;
    var tags = std.ArrayList([]const u8).empty;
    var context: ?[]const u8 = null;
    var dockerfile: ?[]const u8 = null;
    var it = std.mem.tokenizeAny(u8, line[at + 7 ..], " \t\\");
    while (it.next()) |tok| {
        if (std.mem.eql(u8, tok, "-t") or std.mem.eql(u8, tok, "--tag")) {
            if (it.next()) |t| try tags.append(a, unquote(t));
        } else if (std.mem.startsWith(u8, tok, "--tag=")) {
            try tags.append(a, unquote(tok[6..]));
        } else if (std.mem.eql(u8, tok, "-f") or std.mem.eql(u8, tok, "--file")) {
            dockerfile = if (it.next()) |f| unquote(f) else null;
        } else if (std.mem.eql(u8, tok, "--build-arg") or std.mem.eql(u8, tok, "--platform") or std.mem.eql(u8, tok, "--target") or std.mem.eql(u8, tok, "--cache-from")) {
            _ = it.next();
        } else if (tok[0] != '-' and tok[0] != '&' and tok[0] != '|' and tok[0] != ';') {
            context = unquote(tok);
        } else if (tok[0] == '&' or tok[0] == '|' or tok[0] == ';') break;
    }
    const ctx_rel = context orelse (if (dockerfile) |f| std.fs.path.dirnamePosix(f) orelse "." else return);
    // A context written with a variable names nothing in the tree.
    if (std.mem.indexOfAny(u8, ctx_rel, "$`{") != null) return;
    const ctx = try resolve_dir(a, base_dir, ctx_rel);
    for (tags.items) |t| try out.append(a, .{ .repo = image_repo(t), .context = ctx });
}

pub fn find(allocator: std.mem.Allocator, exp: *explorer.Explorer) !Units {
    var units = Units{ .arena = std.heap.ArenaAllocator.init(allocator) };
    errdefer units.deinit();
    const a = units.arena.allocator();

    var hpas = std.ArrayList(Hpa).empty;
    var builds = std.ArrayList(Build).empty;
    var dockerfile_dirs = std.ArrayList([]const u8).empty;
    var chart_dirs = std.StringHashMap(void).init(a);

    // Pass 1: charts and Dockerfiles, which the YAML pass needs.
    var it = exp.outlines.iterator();
    while (it.next()) |entry| {
        if (exp.deleted_files.get(entry.key_ptr.*) != null) continue;
        const path = entry.value_ptr.path;
        const base = std.fs.path.basenamePosix(path);
        const dir = std.fs.path.dirnamePosix(path) orelse "";
        if (std.mem.eql(u8, base, "Chart.yaml")) try chart_dirs.put(dir, {});
        if (std.mem.eql(u8, base, "Dockerfile") or std.mem.startsWith(u8, base, "Dockerfile.")) try dockerfile_dirs.append(a, dir);
    }

    var it2 = exp.outlines.iterator();
    while (it2.next()) |entry| {
        const file_id = entry.key_ptr.*;
        if (exp.deleted_files.get(file_id) != null) continue;
        const outline = entry.value_ptr.*;
        const path = outline.path;
        const base = std.fs.path.basenamePosix(path);
        const dir = std.fs.path.dirnamePosix(path) orelse "";
        const is_yaml = outline.language == .yaml;
        const content = exp.content_of(a, file_id) orelse continue;

        if (is_yaml) {
            // Templates hold Go template syntax, which is not YAML to read.
            if (std.mem.indexOf(u8, path, "/templates/") != null) continue;
            const docs = try read_yaml(a, content);
            if (is_compose_file(base)) {
                try collect_compose(a, path, docs, &units);
            } else if (std.mem.eql(u8, base, "values.yaml") and chart_dirs.contains(dir)) {
                try collect_helm(a, dir, path, docs, &units);
            } else {
                try collect_kubernetes(a, path, docs, &units, &hpas);
                // `docker/build-push-action`: `context:` and `tags:` in one step.
                for (docs) |d| try collect_build_steps(a, exp, d.items, &builds);
            }
        }
        if (std.mem.eql(u8, base, "pgbouncer.ini")) {
            var ln: usize = 0;
            var li = std.mem.splitScalar(u8, content, '\n');
            while (li.next()) |raw| {
                ln += 1;
                const t = std.mem.trim(u8, raw, " \t\r");
                if (!std.mem.startsWith(u8, t, "max_client_conn")) continue;
                const eq = std.mem.indexOfScalar(u8, t, '=') orelse continue;
                const v = parse_int(t[eq + 1 ..]) orelse continue;
                try units.providers.append(a, .{ .name = "pgbouncer", .kind = "pgbouncer", .capacity = v, .at = loc(path, ln) });
            }
        }
        // `docker build` lines in scripts, Makefiles and workflow steps.
        if (outline.language == .bash or outline.language == .make or is_yaml) {
            // Workflows, Make and build scripts run their commands from the
            // repository root.
            const repo_root = exp_root(exp);
            var li = std.mem.splitScalar(u8, content, '\n');
            while (li.next()) |raw| try parse_build_command(a, repo_root, raw, &builds);
        }
    }

    for (hpas.items) |h| {
        for (units.units.items) |*u| {
            if (std.mem.eql(u8, u.name, h.target)) u.max_replicas = h.max;
        }
    }

    // Link each unit's images to the contexts that build them.
    for (units.units.items) |*u| {
        for (u.images.items) |img| {
            const repo = image_repo(img);
            if (repo.len == 0) continue;
            var linked = false;
            for (builds.items) |b| {
                if (std.mem.eql(u8, b.repo, repo)) {
                    try add_context(a, u, b.context);
                    linked = true;
                }
            }
            if (linked) continue;
            // `acme-piper-tts` built from `docker/piper-tts/`: the image
            // carries a project prefix the directory drops.
            for (dockerfile_dirs.items) |d| {
                if (names_dir(repo, std.fs.path.basenamePosix(d))) {
                    try add_context(a, u, d);
                    linked = true;
                }
            }
            if (!linked and dockerfile_dirs.items.len == 1) try add_context(a, u, dockerfile_dirs.items[0]);
        }
        // A unit named after a directory that holds a Dockerfile.
        if (u.contexts.items.len == 0) {
            for (dockerfile_dirs.items) |d| {
                if (std.mem.eql(u8, std.fs.path.basenamePosix(d), u.name)) try add_context(a, u, d);
            }
        }
    }
    return units;
}

fn add_context(a: std.mem.Allocator, u: *Unit, dir: []const u8) !void {
    for (u.contexts.items) |c| {
        if (std.mem.eql(u8, c, dir)) return;
    }
    try u.contexts.append(a, dir);
}

/// `api` names `api`; `acme-api` and `acme_api` name `api` too.
fn names_dir(repo: []const u8, dir: []const u8) bool {
    if (dir.len == 0) return false;
    if (std.mem.eql(u8, repo, dir)) return true;
    if (repo.len > dir.len + 1 and std.mem.endsWith(u8, repo, dir)) {
        const sep = repo[repo.len - dir.len - 1];
        return sep == '-' or sep == '_';
    }
    return false;
}

/// The directory every indexed path shares: the workspace root.
fn exp_root(exp: *explorer.Explorer) []const u8 {
    var root: ?[]const u8 = null;
    for (exp.files.items) |f| {
        const d = std.fs.path.dirnamePosix(f) orelse continue;
        if (root == null) {
            root = d;
            continue;
        }
        var n: usize = 0;
        while (n < root.?.len and n < d.len and root.?[n] == d[n]) n += 1;
        while (n > 0 and n < root.?.len and root.?[n] != '/') n -= 1;
        root = root.?[0..n];
    }
    return root orelse "";
}

fn collect_build_steps(a: std.mem.Allocator, exp: *explorer.Explorer, doc: []const YamlLine, out: *std.ArrayList(Build)) !void {
    const root = exp_root(exp);
    for (doc) |l| {
        if (!ends_with(l.path, "with.context")) continue;
        const ctx = try resolve_dir(a, root, l.value);
        for (doc) |t| {
            if (t.item != l.item or !ends_with(t.path, "with.tags")) continue;
            var parts = std.mem.tokenizeAny(u8, t.value, ", \n");
            while (parts.next()) |tag| try out.append(a, .{ .repo = image_repo(tag), .context = ctx });
        }
    }
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn add_file(exp: *explorer.Explorer, path: []const u8, lang: models.Language, src: []const u8) !void {
    _ = try exp.add_file(.{
        .path = try testing.allocator.dupe(u8, path),
        .language = lang,
        .line_count = std.mem.count(u8, src, "\n") + 1,
        .byte_size = src.len,
        .symbols = &[_]models.Symbol{},
        .imports = &[_][]const u8{},
    }, src);
}

test "deploy_units: each service's manifest reaches the code its image builds" {
    var exp = try explorer.Explorer.init(testing.allocator);
    defer exp.deinit();
    try add_file(&exp, "/ws/deploy/api.yaml", .yaml,
        \\apiVersion: apps/v1
        \\kind: Deployment
        \\metadata:
        \\  name: api
        \\spec:
        \\  replicas: 3
        \\  template:
        \\    spec:
        \\      containers:
        \\        - name: api
        \\          image: ghcr.io/acme/api:1.4
        \\          env:
        \\            - name: DB_POOL_SIZE
        \\              value: "20"
        \\          resources:
        \\            limits:
        \\              memory: 2Gi
        \\---
        \\apiVersion: apps/v1
        \\kind: Deployment
        \\metadata:
        \\  name: worker
        \\spec:
        \\  template:
        \\    spec:
        \\      containers:
        \\        - name: worker
        \\          image: ghcr.io/acme/worker:1.4
        \\          resources:
        \\            limits:
        \\              memory: 256Mi
        \\---
        \\apiVersion: autoscaling/v2
        \\kind: HorizontalPodAutoscaler
        \\metadata:
        \\  name: api
        \\spec:
        \\  scaleTargetRef:
        \\    name: api
        \\  maxReplicas: 8
        \\
    );
    try add_file(&exp, "/ws/.github/workflows/build.yml", .yaml,
        \\jobs:
        \\  build:
        \\    steps:
        \\      - uses: docker/build-push-action@v6
        \\        with:
        \\          context: services/api
        \\          tags: ghcr.io/acme/api:latest
        \\      - run: docker build -t ghcr.io/acme/worker:latest services/worker
        \\
    );
    try add_file(&exp, "/ws/services/api/Dockerfile", .dockerfile, "FROM scratch\n");
    try add_file(&exp, "/ws/services/worker/Dockerfile", .dockerfile, "FROM scratch\n");
    try add_file(&exp, "/ws/services/api/src/db.rs", .rust, "fn x() {}\n");
    try add_file(&exp, "/ws/services/worker/src/main.rs", .rust, "fn main() {}\n");
    exp.mark_indexing_complete();

    var units = try find(testing.allocator, &exp);
    defer units.deinit();
    try testing.expectEqual(@as(usize, 2), units.units.items.len);

    var idx = std.ArrayList(usize).empty;
    defer idx.deinit(testing.allocator);
    try units.units_for("/ws/services/api/src/db.rs", &idx, testing.allocator);
    try testing.expectEqual(@as(usize, 1), idx.items.len);
    const api = units.units.items[idx.items[0]];
    try testing.expectEqualStrings("api", api.name);
    try testing.expectEqual(@as(u64, 2 * 1024 * 1024 * 1024), api.memory_limits.items[0].bytes);
    // The autoscaler bounds the copies, not `spec.replicas`.
    try testing.expectEqual(@as(u64, 8), api.copies().value);
    try testing.expectEqualStrings("DB_POOL_SIZE", api.env.items[0].name);
    try testing.expectEqualStrings("20", api.env.items[0].value);

    try units.units_for("/ws/services/worker/src/main.rs", &idx, testing.allocator);
    try testing.expectEqual(@as(usize, 1), idx.items.len);
    try testing.expectEqualStrings("worker", units.units.items[idx.items[0]].name);
}

test "deploy_units: a merge key brings an anchored build, and a prefixed image finds its directory" {
    var exp = try explorer.Explorer.init(testing.allocator);
    defer exp.deinit();
    try add_file(&exp, "/ws/docker-compose.yml", .yaml,
        \\x-app-build: &app-build
        \\  context: .
        \\  dockerfile: Dockerfile
        \\services:
        \\  app:
        \\    build:
        \\      <<: *app-build
        \\      target: release
        \\
    );
    try add_file(&exp, "/ws/deploy/tts/deployment.yaml", .yaml,
        \\kind: Deployment
        \\metadata:
        \\  name: tts
        \\spec:
        \\  template:
        \\    spec:
        \\      containers:
        \\        - image: ghcr.io/acme/acme-piper-tts:main
        \\
    );
    try add_file(&exp, "/ws/docker/piper-tts/Dockerfile", .dockerfile, "FROM scratch\n");
    try add_file(&exp, "/ws/app/Dockerfile", .dockerfile, "FROM scratch\n");
    exp.mark_indexing_complete();
    var units = try find(testing.allocator, &exp);
    defer units.deinit();
    try testing.expectEqual(@as(usize, 2), units.units.items.len);
    var idx = std.ArrayList(usize).empty;
    defer idx.deinit(testing.allocator);
    try units.units_for("/ws/docker/piper-tts/server.py", &idx, testing.allocator);
    try testing.expectEqual(@as(usize, 1), idx.items.len);
    try testing.expectEqualStrings("tts", units.units.items[idx.items[0]].name);
    for (units.units.items) |u| {
        try testing.expectEqual(@as(usize, 1), u.contexts.items.len);
        if (std.mem.eql(u8, u.name, "app")) try testing.expectEqualStrings("/ws", u.contexts.items[0]);
        if (std.mem.eql(u8, u.name, "tts")) try testing.expectEqualStrings("/ws/docker/piper-tts", u.contexts.items[0]);
    }
}

test "deploy_units: a Compose service builds its context, and a pooler states its capacity" {
    var exp = try explorer.Explorer.init(testing.allocator);
    defer exp.deinit();
    try add_file(&exp, "/ws/docker-compose.yml", .yaml,
        \\services:
        \\  web:
        \\    build: ./web
        \\    mem_limit: 512m
        \\    environment:
        \\      - POOL_SIZE=10
        \\    deploy:
        \\      replicas: 4
        \\
    );
    try add_file(&exp, "/ws/db/pooler.yaml", .yaml,
        \\apiVersion: postgresql.cnpg.io/v1
        \\kind: Pooler
        \\metadata:
        \\  name: pg-pooler-rw
        \\spec:
        \\  instances: 2
        \\  pgbouncer:
        \\    parameters:
        \\      max_client_conn: "15"
        \\
    );
    exp.mark_indexing_complete();
    var units = try find(testing.allocator, &exp);
    defer units.deinit();
    try testing.expectEqual(@as(usize, 1), units.units.items.len);
    const web = units.units.items[0];
    try testing.expectEqualStrings("/ws/web", web.contexts.items[0]);
    try testing.expectEqual(@as(u64, 4), web.copies().value);
    try testing.expectEqual(@as(u64, 512 * 1024 * 1024), web.memory_limits.items[0].bytes);
    try testing.expectEqualStrings("POOL_SIZE", web.env.items[0].name);
    try testing.expectEqual(@as(usize, 1), units.providers.items.len);
    try testing.expectEqual(@as(u64, 30), units.providers.items[0].capacity);
}

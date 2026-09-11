//! Two or more owners write one declared-state field.
//!
//! The fault: a deploy script pinned an image digest, the reconciler in the
//! application forced the spec back to `:latest` about 30 seconds later, and
//! Keel force-rolled on its own registry poll. Each fight rolled a customer pod
//! for about 60 seconds. One Deployment reached generation 785 — a new
//! ReplicaSet every 6 minutes, on a volume that forces a Recreate.
//!
//! The shape is specific enough to detect and rare enough to be worth reporting:
//! the SAME field of the SAME kind of live resource, written by paths that
//! belong to different owners. Two deploy scripts running `kubectl set image`
//! are one owner and one intent. A deploy script and a runtime reconciler are
//! two owners, and the field then has no single meaning.
//!
//! Scope is declared state — Kubernetes, Helm, kustomize and the controllers
//! that watch them. That is where the field has a live value that something
//! else keeps rewriting. A plain variable assigned in two functions is not this
//! shape: it has one writer per call, and a compiler already reasons about it.

const std = @import("std");
const explorer = @import("../index/explorer.zig");
const models = @import("../core/models.zig");

/// Who writes the field. The finding needs two DIFFERENT owners, because two
/// writes from one owner carry one intent.
pub const Owner = enum {
    /// A deploy script, a Makefile target or a CI job: `kubectl set image`,
    /// `helm upgrade`, `kustomize edit set image`.
    deploy_path,
    /// Application code that patches or reconciles the live object.
    reconciler,
    /// A controller the manifest hands the field to: Keel, Flux image
    /// automation, Argo CD Image Updater.
    external_controller,

    pub fn as_str(self: Owner) []const u8 {
        return switch (self) {
            .deploy_path => "deploy_path",
            .reconciler => "reconciler",
            .external_controller => "external_controller",
        };
    }
};

pub const Writer = struct {
    owner: Owner,
    file: []const u8,
    line: usize,
    /// The line that writes it. Owned.
    evidence: []const u8,
    /// True when this writer names a field manager, which is how server-side
    /// apply gives a field one owner.
    declares_field_manager: bool,
};

pub const Contention = struct {
    /// `image`, `replicas`, `resources`, `annotations`. Owned.
    field: []const u8,
    /// Distinct owners writing it.
    owner_count: usize,
    writers: []Writer,
};

pub const Report = struct {
    total_writers: usize = 0,
    contended: []Contention = &.{},

    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        for (self.contended) |c| {
            allocator.free(c.field);
            for (c.writers) |w| allocator.free(w.evidence);
            allocator.free(c.writers);
        }
        allocator.free(self.contended);
    }
};

// ── Scope ────────────────────────────────────────────────────────────────────

fn is_excluded_path(path: []const u8) bool {
    const dirs = [_][]const u8{
        "test",   "tests",  "spec",     "examples", "example", "node_modules",
        "vendor", "target", "testdata", "fixtures", "docs",
    };
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |component| {
        for (&dirs) |d| {
            if (std.mem.eql(u8, component, d)) return true;
        }
    }
    return false;
}

fn is_comment(t: []const u8, lang: models.Language) bool {
    if (std.mem.startsWith(u8, t, "//")) return true;
    if (std.mem.startsWith(u8, t, "/*")) return true;
    if (std.mem.startsWith(u8, t, "*")) return true;
    switch (lang) {
        .bash, .yaml, .python, .make, .dockerfile, .toml => return std.mem.startsWith(u8, t, "#"),
        else => return false,
    }
}

fn contains_any(hay: []const u8, needles: []const []const u8) bool {
    for (needles) |n| {
        if (std.mem.indexOf(u8, hay, n) != null) return true;
    }
    return false;
}

// ── The fields worth tracking ────────────────────────────────────────────────

/// A field of a live Kubernetes object whose value something keeps rewriting.
/// Each entry lists the spellings a write of it takes across shell, YAML and
/// application code.
const TrackedField = struct {
    name: []const u8,
    spellings: []const []const u8,
};

const image_spellings = [_][]const u8{ "image", "Image" };
const replicas_spellings = [_][]const u8{ "replicas", "Replicas" };
const resources_spellings = [_][]const u8{ "resources", "Resources" };

const tracked_fields = [_]TrackedField{
    .{ .name = "image", .spellings = &image_spellings },
    .{ .name = "replicas", .spellings = &replicas_spellings },
    .{ .name = "resources", .spellings = &resources_spellings },
};

fn field_on_line(line: []const u8) ?[]const u8 {
    for (&tracked_fields) |f| {
        for (f.spellings) |s| {
            if (std.mem.indexOf(u8, line, s) != null) return f.name;
        }
    }
    return null;
}

// ── Owner: a deploy path ─────────────────────────────────────────────────────

/// A shell, Makefile or CI line that writes a live object.
fn deploy_write(t: []const u8) ?[]const u8 {
    // `kubectl set image deployment/x c=img`, `kubectl scale --replicas=3`.
    if (std.mem.indexOf(u8, t, "kubectl ") != null) {
        if (std.mem.indexOf(u8, t, "set image") != null) return "image";
        if (std.mem.indexOf(u8, t, "scale") != null) return "replicas";
        if (std.mem.indexOf(u8, t, "set resources") != null) return "resources";
        if (std.mem.indexOf(u8, t, "patch") != null or std.mem.indexOf(u8, t, "apply") != null) {
            return field_on_line(t);
        }
        return null;
    }
    if (std.mem.indexOf(u8, t, "kustomize edit set image") != null) return "image";
    if (std.mem.indexOf(u8, t, "helm upgrade") != null or std.mem.indexOf(u8, t, "helm install") != null) {
        return field_on_line(t);
    }
    return null;
}

// ── Owner: an external controller ────────────────────────────────────────────

/// An annotation that hands a field to a controller that will rewrite it.
const ControllerMarker = struct {
    marker: []const u8,
    field: []const u8,
    name: []const u8,
};

const controller_markers = [_]ControllerMarker{
    .{ .marker = "keel.sh/", .field = "image", .name = "Keel" },
    .{ .marker = "fluxcd.io/automated", .field = "image", .name = "Flux image automation" },
    .{ .marker = "image.toolkit.fluxcd.io", .field = "image", .name = "Flux image automation" },
    .{ .marker = "argocd-image-updater.argoproj.io", .field = "image", .name = "Argo CD Image Updater" },
    .{ .marker = "flux.weave.works/automated", .field = "image", .name = "Flux image automation" },
    .{ .marker = "autoscaling.keda.sh", .field = "replicas", .name = "KEDA" },
    .{ .marker = "kind: HorizontalPodAutoscaler", .field = "replicas", .name = "the HorizontalPodAutoscaler" },
    .{ .marker = "kind: VerticalPodAutoscaler", .field = "resources", .name = "the VerticalPodAutoscaler" },
};

fn controller_write(t: []const u8) ?ControllerMarker {
    for (&controller_markers) |m| {
        if (std.mem.indexOf(u8, t, m.marker) != null) return m;
    }
    return null;
}

// ── Owner: a reconciler in the application ───────────────────────────────────

/// Application code that writes the live object rather than reading it.
const apply_calls = [_][]const u8{
    ".patch(",           ".replace(",           ".apply(",         ".patch_status(", ".replace_status(",
    "patch_namespaced_", "replace_namespaced_", "PatchOptions",    "Patch::Merge",   "Patch::Apply",
    "Patch::Strategic",  "server_side_apply",   "ServerSideApply", ".Update(",       ".Patch(",
    ".Create(",
};

/// The write reaches a container spec. Without this the detector fires on every
/// `.apply(` in a codebase, most of which touch nothing this cares about.
const k8s_object_markers = [_][]const u8{
    "Deployment", "StatefulSet", "DaemonSet",    "PodSpec",  "Container",
    "containers", "deployments", "statefulsets", "\"spec\"", "spec:",
};

/// The literal a field write has to sit inside for the write to reach a live
/// container. A file-level check is not enough: in one repository it took a JSON
/// Schema property named `image` in an MCP tool definition, and an HTTP response
/// body echoing `body.image`, for reconciler writes — both in files that patch
/// Deployments somewhere else.
const container_scope_markers = [_][]const u8{
    "containers",      "Container {",    "Container(",     "Container::",   "PodSpec",
    "PodTemplateSpec", "initContainers", "container_name", "containerName",
};

/// How far above a write the container-spec marker may sit. A container literal
/// is a handful of fields; a schema or a response body that happens to share the
/// key is further away than this.
const container_scope_window: usize = 15;

const field_manager_markers = [_][]const u8{
    "field_manager", "fieldManager", "FieldManager", "--field-manager",
};

// ── Entry point ──────────────────────────────────────────────────────────────

const FoundWriter = struct {
    field: []const u8,
    owner: Owner,
    file: []const u8,
    line: usize,
    evidence: []const u8,
    declares_field_manager: bool,
};

pub fn analyze(allocator: std.mem.Allocator, exp: *explorer.Explorer) !Report {
    var writers = std.ArrayList(FoundWriter).empty;
    defer {
        for (writers.items) |w| allocator.free(w.evidence);
        writers.deinit(allocator);
    }

    var it = exp.outlines.iterator();
    while (it.next()) |entry| {
        const file_id = entry.key_ptr.*;
        if (exp.deleted_files.get(file_id) != null) continue;
        const outline = entry.value_ptr.*;
        if (is_excluded_path(outline.path)) continue;
        const lang = outline.language;
        const content = exp.content_cache.get(file_id) orelse continue;

        // A reconciler is code that writes a Kubernetes object. Deciding that
        // per file, not per line, is what keeps the detector off every `.apply(`
        // in the tree.
        const is_k8s_code = switch (lang) {
            .rust, .go, .python, .typescript, .javascript, .java => contains_any(content, &k8s_object_markers),
            else => false,
        };
        const file_declares_field_manager = contains_any(content, &field_manager_markers);

        // The last line at which a container-spec literal was opened. A field
        // write counts as a reconciler write only while one is close above.
        var container_scope_line: usize = 0;
        // One writer per controller per file: `keel.sh/policy`, `/trigger`,
        // `/pollSchedule` and `/match-tag` are four lines of one hand-off.
        var seen_controllers = std.StringHashMap(void).init(allocator);
        defer seen_controllers.deinit();

        var line_no: usize = 0;
        var line_it = std.mem.splitScalar(u8, content, '\n');
        while (line_it.next()) |raw| {
            line_no += 1;
            const t = std.mem.trim(u8, raw, " \t\r");
            if (t.len == 0 or is_comment(t, lang)) continue;
            if (contains_any(t, &container_scope_markers)) container_scope_line = line_no;

            var owner: ?Owner = null;
            var field: ?[]const u8 = null;

            switch (lang) {
                .bash, .make, .yaml => {
                    if (deploy_write(t)) |f| {
                        owner = .deploy_path;
                        field = f;
                    }
                },
                else => {},
            }

            // A controller annotation, wherever it is written: a chart, a
            // manifest, or a Rust literal that renders one.
            if (owner == null) {
                if (controller_write(t)) |m| {
                    if (seen_controllers.contains(m.marker)) continue;
                    try seen_controllers.put(m.marker, {});
                    owner = .external_controller;
                    field = m.field;
                }
            }

            // A reconciler write. It has to reach a container: either the line
            // itself applies to a Kubernetes object, or a container literal is
            // open just above it.
            const in_container_scope = container_scope_line > 0 and
                line_no - container_scope_line <= container_scope_window;
            if (owner == null and is_k8s_code and contains_any(t, &apply_calls)) {
                if (field_on_line(t)) |f| {
                    owner = .reconciler;
                    field = f;
                }
            }
            if (owner == null and is_k8s_code and in_container_scope) {
                if (spec_field_write(t)) |f| {
                    owner = .reconciler;
                    field = f;
                }
            }

            if (owner == null or field == null) continue;
            try writers.append(allocator, .{
                .field = field.?,
                .owner = owner.?,
                .file = outline.path,
                .line = line_no,
                .evidence = try allocator.dupe(u8, t),
                .declares_field_manager = file_declares_field_manager,
            });
        }
    }

    // Group by field, and keep only the fields two different owners write.
    var contended = std.ArrayList(Contention).empty;
    errdefer {
        for (contended.items) |c| {
            allocator.free(c.field);
            for (c.writers) |w| allocator.free(w.evidence);
            allocator.free(c.writers);
        }
        contended.deinit(allocator);
    }

    for (&tracked_fields) |tf| {
        var owners = std.EnumSet(Owner).initEmpty();
        var count: usize = 0;
        for (writers.items) |w| {
            if (!std.mem.eql(u8, w.field, tf.name)) continue;
            owners.insert(w.owner);
            count += 1;
        }
        if (owners.count() < 2) continue;

        var group = try allocator.alloc(Writer, count);
        errdefer allocator.free(group);
        var i: usize = 0;
        for (writers.items) |w| {
            if (!std.mem.eql(u8, w.field, tf.name)) continue;
            group[i] = .{
                .owner = w.owner,
                .file = w.file,
                .line = w.line,
                .evidence = try allocator.dupe(u8, w.evidence),
                .declares_field_manager = w.declares_field_manager,
            };
            i += 1;
        }
        try contended.append(allocator, .{
            .field = try allocator.dupe(u8, tf.name),
            .owner_count = owners.count(),
            .writers = group,
        });
    }

    return .{
        .total_writers = writers.items.len,
        .contended = try contended.toOwnedSlice(allocator),
    };
}

/// A field set inside an object literal that describes a container spec:
/// `image: Some(image.to_string())`, `"image": image`, `image: img,`.
fn spec_field_write(t: []const u8) ?[]const u8 {
    for (&tracked_fields) |f| {
        for (f.spellings) |s| {
            const idx = std.mem.indexOf(u8, t, s) orelse continue;
            // The spelling must be a key: `image:` or `"image":`.
            var after = idx + s.len;
            if (after < t.len and t[after] == '"') after += 1;
            if (after >= t.len or t[after] != ':') continue;
            // A type annotation is not a write: `image: String,` in a struct.
            const value = std.mem.trim(u8, t[after + 1 ..], " \t");
            if (value.len == 0) continue;
            if (std.mem.startsWith(u8, value, "String,") or
                std.mem.startsWith(u8, value, "&str") or
                std.mem.startsWith(u8, value, "Option<") or
                std.mem.startsWith(u8, value, "string") or
                std.mem.startsWith(u8, value, "str,")) continue;
            // The key must open the line or follow a separator, so a URL path
            // or a log message cannot match.
            if (idx > 0) {
                const p = t[idx - 1];
                if (p != ' ' and p != '\t' and p != '{' and p != ',' and p != '"' and p != '(') continue;
            }
            return f.name;
        }
    }
    return null;
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn one_file(allocator: std.mem.Allocator, path: []const u8, lang: models.Language, src: []const u8) !models.FileOutline {
    return .{
        .path = try allocator.dupe(u8, path),
        .language = lang,
        .line_count = std.mem.count(u8, src, "\n") + 1,
        .byte_size = src.len,
        .symbols = &[_]models.Symbol{},
        .imports = &[_][]const u8{},
    };
}

test "field_contention: the three writers of the tenant image field" {
    const allocator = testing.allocator;
    const deploy =
        \\#!/usr/bin/env bash
        \\for d in $DEPLOYMENTS; do
        \\  kubectl --context "$KUBE_CONTEXT" set image "$d" munbot="$IMAGE_DIGEST"
        \\done
        \\
    ;
    const reconciler =
        \\pub fn tenant_deployment(image: &str) -> Deployment {
        \\    Deployment {
        \\        spec: Some(DeploymentSpec {
        \\            containers: vec![Container {
        \\                image: Some(image.to_string()),
        \\            }],
        \\        }),
        \\    }
        \\}
        \\
    ;
    const chart =
        \\apiVersion: apps/v1
        \\kind: Deployment
        \\metadata:
        \\  annotations:
        \\    keel.sh/policy: force
        \\
    ;
    var exp = try explorer.Explorer.init(allocator);
    defer exp.deinit();
    _ = try exp.add_file(try one_file(allocator, "scripts/deploy-local.sh", .bash, deploy), deploy);
    _ = try exp.add_file(try one_file(allocator, "src/platform/k8s.rs", .rust, reconciler), reconciler);
    _ = try exp.add_file(try one_file(allocator, "deploy/tenant.yaml", .yaml, chart), chart);
    exp.mark_indexing_complete();

    var report = try analyze(allocator, &exp);
    defer report.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), report.contended.len);
    const c = report.contended[0];
    try testing.expectEqualStrings("image", c.field);
    try testing.expectEqual(@as(usize, 3), c.owner_count);
    try testing.expectEqual(@as(usize, 3), c.writers.len);

    var saw_deploy = false;
    var saw_reconciler = false;
    var saw_controller = false;
    for (c.writers) |w| {
        switch (w.owner) {
            .deploy_path => saw_deploy = true,
            .reconciler => saw_reconciler = true,
            .external_controller => saw_controller = true,
        }
    }
    try testing.expect(saw_deploy and saw_reconciler and saw_controller);
}

test "field_contention: one owner writing twice is not contention" {
    const allocator = testing.allocator;
    const deploy =
        \\#!/usr/bin/env bash
        \\kubectl set image deployment/api api="$IMAGE"
        \\kubectl set image deployment/web web="$IMAGE"
        \\
    ;
    var exp = try explorer.Explorer.init(allocator);
    defer exp.deinit();
    _ = try exp.add_file(try one_file(allocator, "scripts/deploy.sh", .bash, deploy), deploy);
    exp.mark_indexing_complete();

    var report = try analyze(allocator, &exp);
    defer report.deinit(allocator);
    try testing.expectEqual(@as(usize, 2), report.total_writers);
    try testing.expectEqual(@as(usize, 0), report.contended.len);
}

test "field_contention: a struct field declaration is not a write" {
    const allocator = testing.allocator;
    const code =
        \\pub struct ContainerSpec {
        \\    pub image: String,
        \\    pub replicas: Option<i32>,
        \\}
        \\
    ;
    const deploy = "kubectl set image deployment/api api=x\n";
    var exp = try explorer.Explorer.init(allocator);
    defer exp.deinit();
    _ = try exp.add_file(try one_file(allocator, "src/types.rs", .rust, code), code);
    _ = try exp.add_file(try one_file(allocator, "scripts/deploy.sh", .bash, deploy), deploy);
    exp.mark_indexing_complete();

    var report = try analyze(allocator, &exp);
    defer report.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), report.contended.len);
}

test "field_contention: an autoscaler against a scripted scale" {
    const allocator = testing.allocator;
    const hpa = "apiVersion: autoscaling/v2\nkind: HorizontalPodAutoscaler\nspec:\n  minReplicas: 2\n";
    const deploy = "kubectl scale deployment/api --replicas=4\n";
    var exp = try explorer.Explorer.init(allocator);
    defer exp.deinit();
    _ = try exp.add_file(try one_file(allocator, "deploy/hpa.yaml", .yaml, hpa), hpa);
    _ = try exp.add_file(try one_file(allocator, "scripts/scale.sh", .bash, deploy), deploy);
    exp.mark_indexing_complete();

    var report = try analyze(allocator, &exp);
    defer report.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), report.contended.len);
    try testing.expectEqualStrings("replicas", report.contended[0].field);
    try testing.expectEqual(@as(usize, 2), report.contended[0].owner_count);
}

test "field_contention: application code with no Kubernetes object is out of scope" {
    const allocator = testing.allocator;
    const code = "let cfg = Config { image: user_image.clone() };\nrepo.apply(cfg);\n";
    const deploy = "kubectl set image deployment/api api=x\n";
    var exp = try explorer.Explorer.init(allocator);
    defer exp.deinit();
    _ = try exp.add_file(try one_file(allocator, "src/config.rs", .rust, code), code);
    _ = try exp.add_file(try one_file(allocator, "scripts/deploy.sh", .bash, deploy), deploy);
    exp.mark_indexing_complete();

    var report = try analyze(allocator, &exp);
    defer report.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), report.contended.len);
}

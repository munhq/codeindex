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

        // ── Credentials in a manifest ─────────────────────────────────────────
        //
        // This matched a credential word ANYWHERE on the line, then skipped only
        // lines containing the literal "[dependencies]" — a TOML section header,
        // which no entry beneath it ever contains. So every dependency whose
        // NAME happens to contain a credential word fired:
        //
        //   rpassword = "7.3"                                → "password"
        //   jsonwebtoken = { version = "9", features = [..] } → "token"
        //   tiktoken-rs = { version = "0.5", optional = true }→ "token"
        //   keywords = ["cli", "token", "llm"]               → "token" AND "key"
        //   description = "... access_token ..."             → "access_key"
        //
        // Measured on one user's repositories: 34 critical findings, 34 false
        // positives, zero real credentials. A critical severity that is always
        // wrong is worse than no rule, because it trains the reader to ignore
        // the category that matters most.
        //
        // Now: match the KEY, on segment boundaries, and require the VALUE to
        // look like a literal secret.
        var line_num: usize = 1;
        var section_is_deps = false;
        var lines_it = std.mem.splitScalar(u8, content, '\n');
        while (lines_it.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            defer line_num += 1;

            // TOML section tracking. Everything under a dependency or feature
            // table is keyed by a CRATE NAME, so its key can never be a
            // credential — and this is where every false positive came from.
            if (is_cargo and line.len > 2 and line[0] == '[') {
                section_is_deps = containsInsensitive(line, "dependencies")
                    or containsInsensitive(line, "[features]");
                continue;
            }
            if (section_is_deps) continue;
            if (line.len == 0 or line[0] == '#') continue;

            const sep = std.mem.indexOfAny(u8, line, "=:") orelse continue;
            const key = std.mem.trim(u8, line[0..sep], " \t\"'");
            const value = std.mem.trim(u8, line[sep + 1 ..], " \t\",';");
            if (key.len == 0) continue;
            if (isMetadataKey(key)) continue;
            if (!keyLooksLikeCredential(key)) continue;
            if (!valueLooksLikeSecret(value)) continue;

            try violations.append(allocator, .{
                .violation_type = .credential_in_manifest,
                .file = outline.path,
                .line = line_num,
                .description = "Possible credential in manifest file",
            });
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

/// Manifest fields that are prose or lists, never a credential. `keywords` is
/// the one that mattered: it contains "key", and its VALUE is a list of words
/// that routinely includes "token" or "secret" for a security-adjacent crate.
const metadata_keys = [_][]const u8{
    "name",          "version",     "edition",     "description", "keywords",
    "categories",    "documentation", "homepage",  "repository",  "authors",
    "license",       "license-file", "readme",     "exclude",     "include",
    "rust-version",  "publish",     "workspace",   "default",     "scripts",
    "dependencies",  "devDependencies", "peerDependencies",       "main",
    "module",        "types",       "files",       "engines",     "bin",
};

fn isMetadataKey(key: []const u8) bool {
    for (&metadata_keys) |m| {
        if (std.ascii.eqlIgnoreCase(key, m)) return true;
    }
    return false;
}

/// Lowercase `key` into `out`, turning every separator AND every camelCase
/// boundary into '_', so one segment rule covers `db_password`, `db-password`
/// and `dbPassword`. Returns the written slice, or null if it will not fit.
fn normalizeKey(key: []const u8, out: []u8) ?[]const u8 {
    var n: usize = 0;
    for (key, 0..) |c, i| {
        if (n + 2 > out.len) return null;
        if (c == '-' or c == '.' or c == '/' or c == ' ' or c == '_') {
            if (n > 0 and out[n - 1] != '_') { out[n] = '_'; n += 1; }
            continue;
        }
        // camelCase boundary: a capital preceded by a lowercase or digit.
        if (std.ascii.isUpper(c) and i > 0
            and (std.ascii.isLower(key[i - 1]) or std.ascii.isDigit(key[i - 1]))) {
            if (n > 0 and out[n - 1] != '_') { out[n] = '_'; n += 1; }
        }
        out[n] = std.ascii.toLower(c);
        n += 1;
    }
    return out[0..n];
}

/// Whether a credential word appears in the key ON SEGMENT BOUNDARIES.
///
/// This is the whole fix. A substring test cannot tell `db_password` (a
/// credential) from `rpassword` (a crate), or `auth_token` from
/// `jsonwebtoken`. Requiring the match to start at a segment start and end at a
/// segment end separates them with no allowlist of crate names to maintain:
///
///   password      → segment "password"            → credential
///   db_password   → segments db|password           → credential
///   dbPassword    → normalizes to db_password      → credential
///   rpassword     → segment "rpassword"            → NOT a credential
///   jsonwebtoken  → segment "jsonwebtoken"         → NOT a credential
///   tiktoken-rs   → segments tiktoken|rs           → NOT a credential
///   keywords      → "key" ends mid-segment         → NOT a credential
fn keyLooksLikeCredential(key: []const u8) bool {
    var buf: [256]u8 = undefined;
    const norm = normalizeKey(key, &buf) orelse return false;
    for (&credential_patterns) |pattern| {
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, norm, from, pattern)) |at| {
            from = at + 1;
            const starts_segment = at == 0 or norm[at - 1] == '_';
            const end = at + pattern.len;
            const ends_segment = end == norm.len or norm[end] == '_';
            if (starts_segment and ends_segment) return true;
        }
    }
    return false;
}

/// Whether the value is plausibly a literal secret rather than a version, a
/// feature reference, a placeholder or an env lookup.
///
/// A credential-named key is not enough on its own: `[features] api_key = []`
/// and `password = "${DB_PASSWORD}"` both name a credential and expose nothing.
fn valueLooksLikeSecret(value: []const u8) bool {
    if (value.len < 8) return false;                    // too short to be a live secret
    if (value[0] == '{' or value[0] == '[') return false; // inline table / list
    if (std.mem.startsWith(u8, value, "dep:")) return false;
    // Env indirection and placeholders — the point of both is that the real
    // value is NOT here.
    if (std.mem.indexOf(u8, value, "${") != null) return false;
    if (std.mem.indexOf(u8, value, "<") != null) return false;
    if (std.mem.startsWith(u8, value, "env:")) return false;
    if (std.mem.startsWith(u8, value, "process.env")) return false;
    for ([_][]const u8{ "changeme", "replace_me", "replace-me", "your_", "your-",
                        "example", "dummy", "placeholder", "xxxx", "todo" }) |p| {
        if (containsInsensitive(value, p)) return false;
    }
    // A version requirement: ^1.2, ~0.5, >=1, 1.2.3.
    const first = value[0];
    if (std.ascii.isDigit(first) or first == '^' or first == '~'
        or first == '>' or first == '<' or first == '=') return false;
    // Prose rather than a token.
    if (std.mem.indexOfScalar(u8, value, ' ') != null) return false;
    return true;
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

// ── Tests ─────────────────────────────────────────────────────────────────────
//
// The false-positive cases are the REAL lines that produced 34 critical findings
// across five repositories, every one of them wrong. They are written out
// verbatim rather than paraphrased, because the rule failed on the specific
// shape of real dependency names and a paraphrase would not have caught it.

test "keyLooksLikeCredential rejects dependency and metadata names" {
    const t = std.testing;
    // Crate/package names that merely CONTAIN a credential word. Every one of
    // these fired as a critical finding before segment matching.
    try t.expect(!keyLooksLikeCredential("rpassword"));
    try t.expect(!keyLooksLikeCredential("jsonwebtoken"));
    try t.expect(!keyLooksLikeCredential("tiktoken"));
    try t.expect(!keyLooksLikeCredential("tiktoken-rs"));
    try t.expect(!keyLooksLikeCredential("keywords"));
    try t.expect(!keyLooksLikeCredential("secretsmanager-sdk"));
    try t.expect(!keyLooksLikeCredential("tokenizer"));
    try t.expect(!keyLooksLikeCredential("passwordless-ui"));
}

test "keyLooksLikeCredential still catches real credential keys" {
    const t = std.testing;
    try t.expect(keyLooksLikeCredential("password"));
    try t.expect(keyLooksLikeCredential("db_password"));
    try t.expect(keyLooksLikeCredential("dbPassword"));
    try t.expect(keyLooksLikeCredential("DB-PASSWORD"));
    try t.expect(keyLooksLikeCredential("api_key"));
    try t.expect(keyLooksLikeCredential("apiKey"));
    try t.expect(keyLooksLikeCredential("auth_token"));
    try t.expect(keyLooksLikeCredential("authToken"));
    try t.expect(keyLooksLikeCredential("private_key"));
    try t.expect(keyLooksLikeCredential("aws_access_key"));
    try t.expect(keyLooksLikeCredential("stripe_secret"));
}

test "valueLooksLikeSecret rejects versions, placeholders and env lookups" {
    const t = std.testing;
    try t.expect(!valueLooksLikeSecret("7.3"));
    try t.expect(!valueLooksLikeSecret("^1.2.3"));
    try t.expect(!valueLooksLikeSecret(">=1.0, <2"));
    try t.expect(!valueLooksLikeSecret("dep:tiktoken-rs"));
    try t.expect(!valueLooksLikeSecret("${DB_PASSWORD}"));
    try t.expect(!valueLooksLikeSecret("env:STRIPE_SECRET"));
    try t.expect(!valueLooksLikeSecret("<your-key-here>"));
    try t.expect(!valueLooksLikeSecret("REPLACE_ME_WITH_A_KEY"));
    try t.expect(!valueLooksLikeSecret("short"));           // under the length floor
    try t.expect(!valueLooksLikeSecret("{ version = 9 }")); // inline table
    try t.expect(!valueLooksLikeSecret("the account password is rotated"));
}

test "valueLooksLikeSecret accepts something that looks like a live token" {
    const t = std.testing;
    // Shape only — deliberately not a real credential format anyone can grep for.
    try t.expect(valueLooksLikeSecret("aaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
    try t.expect(valueLooksLikeSecret("Zm9vYmFyYmF6cXV1eA1234"));
}

test "normalizeKey splits separators and camelCase alike" {
    const t = std.testing;
    var buf: [256]u8 = undefined;
    try t.expectEqualStrings("db_password", normalizeKey("dbPassword", &buf).?);
    try t.expectEqualStrings("db_password", normalizeKey("DB-PASSWORD", &buf).?);
    try t.expectEqualStrings("db_password", normalizeKey("db.password", &buf).?);
    try t.expectEqualStrings("rpassword", normalizeKey("rpassword", &buf).?);
    try t.expectEqualStrings("tiktoken_rs", normalizeKey("tiktoken-rs", &buf).?);
    // An over-long key must not overflow the buffer; it declines instead.
    var tiny: [4]u8 = undefined;
    try t.expect(normalizeKey("averylongkeyname", &tiny) == null);
}

test "isMetadataKey covers the prose fields whose values name credentials" {
    const t = std.testing;
    try t.expect(isMetadataKey("description"));
    try t.expect(isMetadataKey("keywords"));
    try t.expect(isMetadataKey("Description"));
    try t.expect(!isMetadataKey("password"));
}

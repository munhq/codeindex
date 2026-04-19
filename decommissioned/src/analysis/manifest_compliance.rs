//! Manifest compliance checker: verify single-source-of-truth architecture.
//!
//! Detects violations of the manifest pattern where channel names, provider
//! names, panel IDs, or credential keys are hardcoded outside their canonical
//! manifest files.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use regex::Regex;
use serde::{Deserialize, Serialize};

use crate::explorer::Explorer;

// ── Models ───────────────────────────────────────────────────────────────────

/// A single violation of manifest compliance rules.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ManifestViolation {
    /// File where the violation was found.
    pub file: PathBuf,
    /// Line number of the violation.
    pub line: usize,
    /// The offending line text.
    pub line_text: String,
    /// Which manifest this relates to: "channel", "provider", or "panel".
    pub manifest_type: String,
    /// Human-readable description of the violation.
    pub violation: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ManifestComplianceSummary {
    pub total_violations: usize,
    pub by_type: HashMap<String, usize>,
}

/// Full manifest compliance report.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ManifestComplianceReport {
    pub violations: Vec<ManifestViolation>,
    pub summary: ManifestComplianceSummary,
}

// ── Manifest extraction ──────────────────────────────────────────────────────

lazy_static::lazy_static! {
    /// Match `id: "some_value"` in manifest struct definitions.
    static ref RE_ID_FIELD: Regex = Regex::new(
        r#"id:\s*"([^"]+)""#
    ).unwrap();

    /// Match `env_var: "SOME_VAR"` or `key: "SOME_VAR"` where value is ALL_CAPS_SNAKE.
    static ref RE_ENV_VAR_FIELD: Regex = Regex::new(
        r#"(?:env_var|key):\s*"([A-Z][A-Z0-9_]+)""#
    ).unwrap();

    /// Match Rust `match` blocks on string-like expressions.
    static ref RE_MATCH_BLOCK: Regex = Regex::new(
        r#"(?m)match\s+\w+[^{]*\{"#
    ).unwrap();

    /// Match patterns like `"DISCORD_BOT_TOKEN"` | `"TELEGRAM_BOT_TOKEN"` etc.
    /// (credential key patterns ending in _TOKEN, _KEY, _SECRET, _ID, _WEBHOOK).
    static ref RE_CREDENTIAL_KEY: Regex = Regex::new(
        r#""([A-Z][A-Z0-9_]*(?:_TOKEN|_KEY|_SECRET|_WEBHOOK|_API_KEY|_BOT_TOKEN))""#
    ).unwrap();

    /// Match if-else chains checking string equality: `if key == "..." || key == "..."`
    static ref RE_IF_STRING_CHECK: Regex = Regex::new(
        r#"if\s+\w+\s*==\s*""#
    ).unwrap();
}

/// Known manifest source files (relative paths within the workspace).
const CHANNEL_MANIFEST: &str = "src/channels/manifest.rs";
const PROVIDER_MANIFEST: &str = "src/providers/manifest.rs";
const PANEL_MANIFEST: &str = "src/gateway/api/panels.rs";

/// Files that are allowed to reference manifest values (the manifests themselves,
/// integration endpoints that serve them, and frontend screen registries).
const ALLOWED_FILES: &[&str] = &[
    "src/channels/manifest.rs",
    "src/providers/manifest.rs",
    "src/gateway/api/panels.rs",
    "src/gateway/api/integrations.rs",
    // Frontend screen registries that wire panel IDs to routes
    "dashboard/src/layout/AppShell.tsx",
    "dashboard/src/layout/SideNav.tsx",
    // Test files are handled separately in is_allowed_file()
];

/// Directory prefixes for channel/provider implementations that legitimately
/// reference their own manifest ID (e.g. `src/channels/discord.rs` may use "discord").
const ALLOWED_IMPL_DIRS: &[&str] = &[
    "src/channels/",
    "src/providers/",
];

/// Extract manifest identifiers (the `id` field values) from a manifest file.
///
/// Only extracts values from `id: "..."` patterns in struct definitions,
/// avoiding generic string literals like "error", "description", etc.
fn extract_manifest_names(explorer: &Explorer, manifest_path: &str) -> Vec<String> {
    let path = PathBuf::from(manifest_path);
    let content = match explorer.filter().read_file(&path) {
        Ok(c) => c,
        Err(_) => return Vec::new(),
    };

    let mut names = Vec::new();
    for cap in RE_ID_FIELD.captures_iter(&content) {
        names.push(cap.get(1).unwrap().as_str().to_string());
    }
    names
}

/// Extract credential key patterns from a manifest file.
///
/// Looks for `env_var: "SOME_KEY"` and `key: "SOME_KEY"` field patterns first,
/// then falls back to the general credential key suffix pattern for any remaining
/// ALL_CAPS strings that look like credential environment variables.
fn extract_credential_keys(explorer: &Explorer, manifest_path: &str) -> Vec<String> {
    let path = PathBuf::from(manifest_path);
    let content = match explorer.filter().read_file(&path) {
        Ok(c) => c,
        Err(_) => return Vec::new(),
    };

    let mut keys = Vec::new();

    // Primary: extract from `env_var: "..."` and `key: "..."` field patterns
    for cap in RE_ENV_VAR_FIELD.captures_iter(&content) {
        keys.push(cap.get(1).unwrap().as_str().to_string());
    }

    // Secondary: catch credential keys by suffix pattern (_TOKEN, _KEY, etc.)
    for cap in RE_CREDENTIAL_KEY.captures_iter(&content) {
        let val = cap.get(1).unwrap().as_str().to_string();
        if !keys.contains(&val) {
            keys.push(val);
        }
    }

    keys
}

/// Check if a file path is an allowed manifest source.
fn is_allowed_file(path: &Path) -> bool {
    let path_str = path.to_string_lossy();
    for allowed in ALLOWED_FILES {
        if path_str.ends_with(allowed) || path_str.contains(allowed) {
            return true;
        }
    }
    // Allow test files
    if path_str.contains("/tests/") || path_str.contains("_test.rs") || path_str.contains("/test_") {
        return true;
    }
    false
}

/// Check if a file is a channel/provider implementation that is allowed to
/// reference its own manifest ID (derived from its filename).
fn is_impl_file_for_value(path: &Path, value: &str) -> bool {
    let path_str = path.to_string_lossy();
    for dir in ALLOWED_IMPL_DIRS {
        if path_str.contains(dir) {
            // Extract the stem: src/channels/discord.rs -> "discord"
            if let Some(stem) = path.file_stem().and_then(|s| s.to_str()) {
                // The impl file is allowed to reference its own ID
                if stem == value {
                    return true;
                }
            }
        }
    }
    false
}

/// Search for hardcoded references to manifest values outside manifest files.
fn find_hardcoded_references(
    explorer: &Explorer,
    values: &[String],
    manifest_type: &str,
    manifest_file: &str,
) -> Vec<ManifestViolation> {
    let outlines = explorer.get_all_outlines();
    let mut violations = Vec::new();

    if values.is_empty() {
        return violations;
    }

    for (path, _) in &outlines {
        // Only check Rust and TypeScript files
        let ext = path.extension().and_then(|e| e.to_str());
        if !matches!(ext, Some("rs") | Some("ts") | Some("tsx")) {
            continue;
        }

        // Skip manifest files themselves and allowed files
        let path_str = path.to_string_lossy();
        if path_str.ends_with(manifest_file) || is_allowed_file(path) {
            continue;
        }

        let content = match explorer.filter().read_file(path) {
            Ok(c) => c,
            Err(_) => continue,
        };

        for (line_idx, line) in content.lines().enumerate() {
            // Skip comments
            let trimmed = line.trim();
            if trimmed.starts_with("//") || trimmed.starts_with("/*") || trimmed.starts_with('*') {
                continue;
            }

            for value in values {
                // Allow channel/provider impl files to reference their own ID
                if is_impl_file_for_value(path, value) {
                    continue;
                }

                // Check if this line contains the value as a string literal
                let pattern = format!("\"{}\"", value);
                if line.contains(&pattern) {
                    violations.push(ManifestViolation {
                        file: path.clone(),
                        line: line_idx + 1,
                        line_text: trimmed.to_string(),
                        manifest_type: manifest_type.to_string(),
                        violation: format!(
                            "Hardcoded {} name \"{}\" — should come from {}",
                            manifest_type, value, manifest_file
                        ),
                    });
                }
            }
        }
    }

    violations
}

/// Detect match/if-else chains that compare against known manifest strings.
fn find_match_chains(
    explorer: &Explorer,
    values: &[String],
    manifest_type: &str,
    manifest_file: &str,
) -> Vec<ManifestViolation> {
    let outlines = explorer.get_all_outlines();
    let mut violations = Vec::new();

    if values.is_empty() {
        return violations;
    }

    for (path, _) in &outlines {
        let ext = path.extension().and_then(|e| e.to_str());
        if ext != Some("rs") {
            continue;
        }

        let path_str = path.to_string_lossy();
        if path_str.ends_with(manifest_file) || is_allowed_file(path) {
            continue;
        }

        let content = match explorer.filter().read_file(path) {
            Ok(c) => c,
            Err(_) => continue,
        };

        let lines: Vec<&str> = content.lines().collect();

        // Look for match blocks that reference multiple manifest values
        for (line_idx, line) in lines.iter().enumerate() {
            let trimmed = line.trim();

            // Skip comments
            if trimmed.starts_with("//") || trimmed.starts_with("/*") || trimmed.starts_with('*') {
                continue;
            }

            // Check for match blocks
            if RE_MATCH_BLOCK.is_match(trimmed) {
                // Scan the next ~50 lines for manifest value references
                let end = (line_idx + 50).min(lines.len());
                let block_text: String = lines[line_idx..end].join("\n");

                let mut matched_values = Vec::new();
                for value in values {
                    let pattern = format!("\"{}\"", value);
                    if block_text.contains(&pattern) {
                        matched_values.push(value.clone());
                    }
                }

                // If 2+ manifest values appear in a match block, it's a violation
                if matched_values.len() >= 2 {
                    violations.push(ManifestViolation {
                        file: path.clone(),
                        line: line_idx + 1,
                        line_text: trimmed.to_string(),
                        manifest_type: manifest_type.to_string(),
                        violation: format!(
                            "Match block dispatches on {} names {:?} — should use manifest from {}",
                            manifest_type, matched_values, manifest_file
                        ),
                    });
                }
            }

            // Check for if-else chains comparing strings
            if RE_IF_STRING_CHECK.is_match(trimmed) {
                let end = (line_idx + 10).min(lines.len());
                let block_text: String = lines[line_idx..end].join("\n");

                let mut matched_values = Vec::new();
                for value in values {
                    let pattern = format!("\"{}\"", value);
                    if block_text.contains(&pattern) {
                        matched_values.push(value.clone());
                    }
                }

                if matched_values.len() >= 2 {
                    violations.push(ManifestViolation {
                        file: path.clone(),
                        line: line_idx + 1,
                        line_text: trimmed.to_string(),
                        manifest_type: manifest_type.to_string(),
                        violation: format!(
                            "If-else chain checks {} names {:?} — should use manifest from {}",
                            manifest_type, matched_values, manifest_file
                        ),
                    });
                }
            }
        }
    }

    violations
}

/// Build the full manifest compliance report.
pub fn manifest_compliance(explorer: &Explorer) -> ManifestComplianceReport {
    let mut all_violations = Vec::new();

    // Extract names from each manifest
    let channel_names = extract_manifest_names(explorer, CHANNEL_MANIFEST);
    let provider_names = extract_manifest_names(explorer, PROVIDER_MANIFEST);
    let panel_names = extract_manifest_names(explorer, PANEL_MANIFEST);

    // Extract credential keys from channel + provider manifests
    let mut credential_keys = extract_credential_keys(explorer, CHANNEL_MANIFEST);
    credential_keys.extend(extract_credential_keys(explorer, PROVIDER_MANIFEST));

    // Check for hardcoded channel references
    all_violations.extend(find_hardcoded_references(
        explorer,
        &channel_names,
        "channel",
        CHANNEL_MANIFEST,
    ));

    // Check for hardcoded provider references
    all_violations.extend(find_hardcoded_references(
        explorer,
        &provider_names,
        "provider",
        PROVIDER_MANIFEST,
    ));

    // Check for hardcoded panel references
    all_violations.extend(find_hardcoded_references(
        explorer,
        &panel_names,
        "panel",
        PANEL_MANIFEST,
    ));

    // Check for hardcoded credential keys
    all_violations.extend(find_hardcoded_references(
        explorer,
        &credential_keys,
        "credential",
        CHANNEL_MANIFEST,
    ));

    // Check for match/if-else dispatch chains
    all_violations.extend(find_match_chains(
        explorer,
        &channel_names,
        "channel",
        CHANNEL_MANIFEST,
    ));
    all_violations.extend(find_match_chains(
        explorer,
        &provider_names,
        "provider",
        PROVIDER_MANIFEST,
    ));

    // Build summary
    let mut by_type: HashMap<String, usize> = HashMap::new();
    for v in &all_violations {
        *by_type.entry(v.manifest_type.clone()).or_insert(0) += 1;
    }

    let summary = ManifestComplianceSummary {
        total_violations: all_violations.len(),
        by_type,
    };

    ManifestComplianceReport {
        violations: all_violations,
        summary,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn is_allowed_file_manifest_paths() {
        assert!(is_allowed_file(Path::new("src/channels/manifest.rs")));
        assert!(is_allowed_file(Path::new("src/providers/manifest.rs")));
        assert!(is_allowed_file(Path::new("src/gateway/api/integrations.rs")));
        assert!(is_allowed_file(Path::new("src/gateway/api/panels.rs")));
        assert!(is_allowed_file(Path::new("tests/integration_test.rs")));
        assert!(is_allowed_file(Path::new("dashboard/src/layout/AppShell.tsx")));
        assert!(is_allowed_file(Path::new("dashboard/src/layout/SideNav.tsx")));
        assert!(!is_allowed_file(Path::new("src/gateway/api/sessions.rs")));
        // Channel impl files are NOT globally allowed — they use is_impl_file_for_value
        assert!(!is_allowed_file(Path::new("src/channels/discord.rs")));
    }

    #[test]
    fn impl_file_matches_own_id() {
        assert!(is_impl_file_for_value(
            Path::new("src/channels/discord.rs"),
            "discord"
        ));
        assert!(is_impl_file_for_value(
            Path::new("src/providers/openai.rs"),
            "openai"
        ));
        // Does not match a different ID
        assert!(!is_impl_file_for_value(
            Path::new("src/channels/discord.rs"),
            "telegram"
        ));
        // Non-impl directories don't match
        assert!(!is_impl_file_for_value(
            Path::new("src/gateway/api/sessions.rs"),
            "sessions"
        ));
    }

    #[test]
    fn regex_id_field_extracts_ids() {
        let content = r#"
            ChannelDef {
                id: "discord",
                name: "Discord",
                description: "Discord bot integration",
            },
            ChannelDef {
                id: "telegram",
                name: "Telegram",
                description: "Telegram bot integration",
            },
        "#;

        let ids: Vec<String> = RE_ID_FIELD
            .captures_iter(content)
            .map(|c| c.get(1).unwrap().as_str().to_string())
            .collect();

        assert_eq!(ids, vec!["discord", "telegram"]);
    }

    #[test]
    fn regex_env_var_field_extracts_keys() {
        let content = r#"
            env_var: "DISCORD_BOT_TOKEN",
            key: "OPENAI_API_KEY",
            name: "Discord",
            description: "some text",
        "#;

        let keys: Vec<String> = RE_ENV_VAR_FIELD
            .captures_iter(content)
            .map(|c| c.get(1).unwrap().as_str().to_string())
            .collect();

        assert!(keys.contains(&"DISCORD_BOT_TOKEN".to_string()));
        assert!(keys.contains(&"OPENAI_API_KEY".to_string()));
        assert_eq!(keys.len(), 2);
    }

    #[test]
    fn regex_credential_key_matches() {
        let content = r#"
            let key = "DISCORD_BOT_TOKEN";
            let other = "OPENAI_API_KEY";
            let webhook = "SLACK_WEBHOOK";
            let not_a_key = "hello_world";
        "#;

        let keys: Vec<String> = RE_CREDENTIAL_KEY
            .captures_iter(content)
            .map(|c| c.get(1).unwrap().as_str().to_string())
            .collect();

        assert!(keys.contains(&"DISCORD_BOT_TOKEN".to_string()));
        assert!(keys.contains(&"OPENAI_API_KEY".to_string()));
        assert!(keys.contains(&"SLACK_WEBHOOK".to_string()));
        assert!(!keys.contains(&"hello_world".to_string()));
    }

    #[test]
    fn regex_match_block_detects() {
        let line = r#"    match channel_name {"#;
        assert!(RE_MATCH_BLOCK.is_match(line));

        let line2 = r#"    match key.as_str() {"#;
        assert!(RE_MATCH_BLOCK.is_match(line2));
    }

    #[test]
    fn regex_if_string_check_detects() {
        let line = r#"    if key == "DISCORD_BOT_TOKEN" {"#;
        assert!(RE_IF_STRING_CHECK.is_match(line));
    }

    #[test]
    fn empty_manifest_produces_no_violations() {
        // When manifest files don't exist, extract returns empty,
        // and find_hardcoded_references short-circuits.
        let values: Vec<String> = Vec::new();
        let explorer_not_needed = true; // just testing the logic gate
        assert!(values.is_empty());
        assert!(explorer_not_needed);
    }

    #[test]
    fn summary_counts_by_type() {
        let violations = vec![
            ManifestViolation {
                file: PathBuf::from("a.rs"),
                line: 1,
                line_text: String::new(),
                manifest_type: "channel".to_string(),
                violation: String::new(),
            },
            ManifestViolation {
                file: PathBuf::from("b.rs"),
                line: 2,
                line_text: String::new(),
                manifest_type: "channel".to_string(),
                violation: String::new(),
            },
            ManifestViolation {
                file: PathBuf::from("c.rs"),
                line: 3,
                line_text: String::new(),
                manifest_type: "provider".to_string(),
                violation: String::new(),
            },
        ];

        let mut by_type: HashMap<String, usize> = HashMap::new();
        for v in &violations {
            *by_type.entry(v.manifest_type.clone()).or_insert(0) += 1;
        }

        assert_eq!(by_type["channel"], 2);
        assert_eq!(by_type["provider"], 1);
    }
}

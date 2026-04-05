//! Unwrap/panic audit: find `.unwrap()`, `.expect()`, `panic!()` in non-test Rust code.
//!
//! Scans all `.rs` files for potentially dangerous unwrap/expect/panic usage,
//! classifies severity based on file path and context, and reports findings
//! with enclosing function scope from the outlines.

use std::path::PathBuf;

use regex::Regex;
use serde::{Deserialize, Serialize};

use crate::explorer::Explorer;
use crate::models::SymbolKind;

// ── Models ───────────────────────────────────────────────────────────────────

/// The kind of unwrap/panic pattern found.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum UnwrapKind {
    Unwrap,
    Expect,
    Panic,
}

impl UnwrapKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            UnwrapKind::Unwrap => "unwrap",
            UnwrapKind::Expect => "expect",
            UnwrapKind::Panic => "panic",
        }
    }
}

/// Severity classification for an unwrap/panic finding.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum Severity {
    /// In gateway/, api/, or async handler code.
    Critical,
    /// In library code (everything else).
    Warning,
    /// In test files, main.rs, or CLI commands.
    Info,
}

impl Severity {
    pub fn as_str(&self) -> &'static str {
        match self {
            Severity::Critical => "critical",
            Severity::Warning => "warning",
            Severity::Info => "info",
        }
    }
}

/// A single unwrap/expect/panic finding.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UnwrapFinding {
    pub file: PathBuf,
    pub line: usize,
    pub line_text: String,
    pub kind: UnwrapKind,
    pub severity: Severity,
    pub scope_name: Option<String>,
}

/// Summary statistics for the unwrap audit.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UnwrapSummary {
    pub total: usize,
    pub critical: usize,
    pub warning: usize,
    pub info: usize,
}

/// Full unwrap audit report.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UnwrapAuditReport {
    pub findings: Vec<UnwrapFinding>,
    pub summary: UnwrapSummary,
}

// ── Severity classification ──────────────────────────────────────────────────

/// Determine severity from file path and whether the file contains async handlers.
fn classify_severity(path: &PathBuf, has_async_handlers: bool, is_test_region: bool) -> Severity {
    if is_test_region {
        return Severity::Info;
    }

    let path_str = path.to_string_lossy().to_lowercase();

    // Info: test files, main.rs, CLI/bin code
    if path_str.contains("test")
        || path_str.ends_with("main.rs")
        || path_str.contains("/bin/")
        || path_str.contains("/cli/")
        || path_str.contains("/examples/")
    {
        return Severity::Info;
    }

    // Critical: gateway, api, or files with async fn handlers
    if path_str.contains("gateway/")
        || path_str.contains("/api/")
        || path_str.contains("api/")
        || has_async_handlers
    {
        return Severity::Critical;
    }

    Severity::Warning
}

/// Check if a file contains async fn definitions (heuristic for handler code).
fn file_has_async_handlers(content: &str) -> bool {
    // Look for `async fn` patterns that suggest HTTP handlers
    content.contains("async fn")
}

// ── cfg(test) region tracking ────────────────────────────────────────────────

/// Determine which line ranges are inside `#[cfg(test)]` blocks.
///
/// Scans for `#[cfg(test)]` and tracks brace depth to find the end of
/// the test module. Returns a list of (start, end) line ranges (1-indexed).
fn find_test_regions(content: &str) -> Vec<(usize, usize)> {
    let lines: Vec<&str> = content.lines().collect();
    let mut regions = Vec::new();

    let mut i = 0;
    while i < lines.len() {
        let trimmed = lines[i].trim();
        if trimmed.starts_with("#[cfg(test)]") {
            let region_start = i + 1; // 1-indexed
            // Find the opening brace and track depth
            let mut brace_depth: i32 = 0;
            let mut found_open = false;
            let mut j = i;

            while j < lines.len() {
                for ch in lines[j].chars() {
                    if ch == '{' {
                        if !found_open {
                            found_open = true;
                        }
                        brace_depth += 1;
                    } else if ch == '}' {
                        brace_depth -= 1;
                        if found_open && brace_depth == 0 {
                            regions.push((region_start, j + 1)); // 1-indexed
                            i = j + 1;
                            break;
                        }
                    }
                }
                // If we closed the region, break the outer loop too
                if found_open && brace_depth == 0 {
                    break;
                }
                j += 1;
            }

            // If we didn't find a closing brace, treat rest of file as test region
            if found_open && brace_depth > 0 {
                regions.push((region_start, lines.len()));
                break;
            }

            // If we never found an open brace, just skip this line
            if !found_open {
                i += 1;
            }

            continue;
        }
        i += 1;
    }

    regions
}

/// Check if a line number falls inside any test region.
fn is_in_test_region(line: usize, test_regions: &[(usize, usize)]) -> bool {
    test_regions.iter().any(|(start, end)| line >= *start && line <= *end)
}

// ── Analysis ─────────────────────────────────────────────────────────────────

lazy_static::lazy_static! {
    static ref RE_UNWRAP: Regex = Regex::new(r"\.unwrap\(\)").unwrap();
    static ref RE_EXPECT: Regex = Regex::new(r"\.expect\(").unwrap();
    static ref RE_PANIC: Regex = Regex::new(r"panic!\(").unwrap();
}

/// Find the enclosing function scope for a given line in a file's outline.
///
/// Because the parser may set `line_end == line_start` (single-line span),
/// we fall back to: the enclosing scope is the closest function/method whose
/// `line_start` is at or before `line_num`, without another function starting
/// in between.
fn find_enclosing_scope(
    explorer: &Explorer,
    path: &PathBuf,
    line_num: usize,
) -> Option<String> {
    let outline = explorer.get_outline(std::path::Path::new(path))?;

    // Collect function-like symbols sorted by line_start
    let mut funcs: Vec<&crate::models::Symbol> = outline
        .symbols
        .iter()
        .filter(|s| {
            matches!(
                s.kind,
                SymbolKind::Function | SymbolKind::Method | SymbolKind::Test
            )
        })
        .collect();
    funcs.sort_by_key(|s| s.line_start);

    // First try: exact range match (if line_end > line_start, the parser tracked it)
    let mut best: Option<&crate::models::Symbol> = None;
    for symbol in &funcs {
        if symbol.line_start <= line_num && symbol.line_end >= line_num && symbol.line_end > symbol.line_start {
            if best.is_none() || symbol.line_start > best.unwrap().line_start {
                best = Some(symbol);
            }
        }
    }
    if best.is_some() {
        return best.map(|s| s.name.clone());
    }

    // Fallback: find the last function that starts at or before line_num
    // where no other function starts between it and line_num.
    let mut candidate: Option<&crate::models::Symbol> = None;
    for (i, symbol) in funcs.iter().enumerate() {
        if symbol.line_start <= line_num {
            // Check if the NEXT function starts after line_num (or this is the last)
            let next_starts_after = funcs
                .get(i + 1)
                .map(|next| next.line_start > line_num)
                .unwrap_or(true);

            if next_starts_after {
                candidate = Some(symbol);
            }
        }
    }

    candidate.map(|s| s.name.clone())
}

/// Audit all `.rs` files for `.unwrap()`, `.expect()`, and `panic!()` usage.
///
/// Classifies each finding by severity and reports the enclosing function scope.
/// Skips occurrences inside `#[cfg(test)]` blocks.
pub fn audit_unwraps(explorer: &Explorer) -> UnwrapAuditReport {
    let outlines = explorer.get_all_outlines();
    let mut findings: Vec<UnwrapFinding> = Vec::new();

    for (path, _outline) in &outlines {
        let ext = path.extension().and_then(|e| e.to_str());
        if ext != Some("rs") {
            continue;
        }

        let content = match explorer.filter().read_file(path) {
            Ok(c) => c,
            Err(_) => continue,
        };

        let test_regions = find_test_regions(&content);
        let has_async = file_has_async_handlers(&content);

        for (line_idx, line_text) in content.lines().enumerate() {
            let line_num = line_idx + 1;

            // Skip lines inside #[cfg(test)] blocks
            let in_test = is_in_test_region(line_num, &test_regions);

            // Skip comment-only lines
            let trimmed = line_text.trim();
            if trimmed.starts_with("//") || trimmed.starts_with("///") || trimmed.starts_with("*") {
                continue;
            }

            let severity = classify_severity(path, has_async, in_test);

            // Check for .unwrap()
            if RE_UNWRAP.is_match(line_text) {
                findings.push(UnwrapFinding {
                    file: path.clone(),
                    line: line_num,
                    line_text: line_text.trim().to_string(),
                    kind: UnwrapKind::Unwrap,
                    severity,
                    scope_name: find_enclosing_scope(explorer, path, line_num),
                });
            }

            // Check for .expect(
            if RE_EXPECT.is_match(line_text) {
                findings.push(UnwrapFinding {
                    file: path.clone(),
                    line: line_num,
                    line_text: line_text.trim().to_string(),
                    kind: UnwrapKind::Expect,
                    severity,
                    scope_name: find_enclosing_scope(explorer, path, line_num),
                });
            }

            // Check for panic!(
            if RE_PANIC.is_match(line_text) {
                findings.push(UnwrapFinding {
                    file: path.clone(),
                    line: line_num,
                    line_text: line_text.trim().to_string(),
                    kind: UnwrapKind::Panic,
                    severity,
                    scope_name: find_enclosing_scope(explorer, path, line_num),
                });
            }
        }
    }

    // Sort by severity (critical first), then file, then line
    findings.sort_by(|a, b| {
        fn severity_ord(s: &Severity) -> u8 {
            match s {
                Severity::Critical => 0,
                Severity::Warning => 1,
                Severity::Info => 2,
            }
        }
        severity_ord(&a.severity)
            .cmp(&severity_ord(&b.severity))
            .then(a.file.cmp(&b.file))
            .then(a.line.cmp(&b.line))
    });

    // Build summary
    let mut summary = UnwrapSummary {
        total: findings.len(),
        critical: 0,
        warning: 0,
        info: 0,
    };
    for f in &findings {
        match f.severity {
            Severity::Critical => summary.critical += 1,
            Severity::Warning => summary.warning += 1,
            Severity::Info => summary.info += 1,
        }
    }

    UnwrapAuditReport { findings, summary }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::sync::Arc;
    use tempfile::TempDir;

    use crate::config::CodeIndexerConfig;

    fn setup(tmp: &TempDir) -> Explorer {
        let config = CodeIndexerConfig {
            workspace_root: tmp.path().to_path_buf(),
            ..Default::default()
        };
        Explorer::new(Arc::new(config))
    }

    fn write_file(tmp: &TempDir, rel: &str, content: &str) -> PathBuf {
        let full = tmp.path().join(rel);
        if let Some(parent) = full.parent() {
            fs::create_dir_all(parent).unwrap();
        }
        fs::write(&full, content).unwrap();
        PathBuf::from(rel)
    }

    #[test]
    fn detects_unwrap_expect_panic() {
        let tmp = TempDir::new().unwrap();
        let explorer = setup(&tmp);

        let rel = write_file(
            &tmp,
            "lib.rs",
            r#"pub fn risky() {
    let x = Some(1).unwrap();
    let y = Some(2).expect("oops");
    panic!("oh no");
}
"#,
        );
        explorer.index_file(&rel).unwrap();

        let report = audit_unwraps(&explorer);

        assert_eq!(report.findings.len(), 3, "expected 3 findings, got {:?}", report.findings);

        let kinds: Vec<UnwrapKind> = report.findings.iter().map(|f| f.kind).collect();
        assert!(kinds.contains(&UnwrapKind::Unwrap));
        assert!(kinds.contains(&UnwrapKind::Expect));
        assert!(kinds.contains(&UnwrapKind::Panic));
    }

    #[test]
    fn skips_cfg_test_blocks() {
        let tmp = TempDir::new().unwrap();
        let explorer = setup(&tmp);

        let rel = write_file(
            &tmp,
            "checked.rs",
            r#"pub fn safe() -> Option<i32> {
    Some(42)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_safe() {
        safe().unwrap();
    }
}
"#,
        );
        explorer.index_file(&rel).unwrap();

        let report = audit_unwraps(&explorer);

        // The unwrap inside #[cfg(test)] should be classified as Info
        for f in &report.findings {
            assert_eq!(
                f.severity,
                Severity::Info,
                "unwrap in cfg(test) should be Info severity, got {:?}",
                f.severity
            );
        }
    }

    #[test]
    fn gateway_files_are_critical() {
        let tmp = TempDir::new().unwrap();
        let explorer = setup(&tmp);

        let rel = write_file(
            &tmp,
            "gateway/handler.rs",
            "pub fn handle() { let x = Some(1).unwrap(); }\n",
        );
        explorer.index_file(&rel).unwrap();

        let report = audit_unwraps(&explorer);

        assert!(!report.findings.is_empty());
        assert_eq!(report.findings[0].severity, Severity::Critical);
    }

    #[test]
    fn main_rs_is_info() {
        let tmp = TempDir::new().unwrap();
        let explorer = setup(&tmp);

        let rel = write_file(
            &tmp,
            "main.rs",
            "fn main() { let x = Some(1).unwrap(); }\n",
        );
        explorer.index_file(&rel).unwrap();

        let report = audit_unwraps(&explorer);

        assert!(!report.findings.is_empty());
        assert_eq!(report.findings[0].severity, Severity::Info);
    }

    #[test]
    fn summary_counts_match() {
        let tmp = TempDir::new().unwrap();
        let explorer = setup(&tmp);

        let rel = write_file(
            &tmp,
            "mixed.rs",
            r#"pub fn danger() {
    Some(1).unwrap();
    panic!("no");
}
"#,
        );
        explorer.index_file(&rel).unwrap();

        let report = audit_unwraps(&explorer);
        let s = &report.summary;

        assert_eq!(s.total, s.critical + s.warning + s.info);
        assert_eq!(s.total, report.findings.len());
    }

    #[test]
    fn find_test_regions_works() {
        let content = r#"pub fn foo() {}

#[cfg(test)]
mod tests {
    fn test_a() {
        something().unwrap();
    }
}

pub fn bar() {}
"#;
        let regions = find_test_regions(content);
        assert_eq!(regions.len(), 1);

        // The region should cover lines 3..9 (1-indexed)
        let (start, end) = regions[0];
        assert!(start <= 4, "region should start at or before line 4, got {start}");
        assert!(end >= 8, "region should end at or after line 8, got {end}");

        // foo() line (line 1) should NOT be in the test region
        assert!(!is_in_test_region(1, &regions));

        // The unwrap line (line 6) SHOULD be in the test region
        assert!(is_in_test_region(6, &regions));

        // bar() line (line 11) should NOT be in the test region
        assert!(!is_in_test_region(11, &regions));
    }

    #[test]
    fn skips_comments() {
        let tmp = TempDir::new().unwrap();
        let explorer = setup(&tmp);

        let rel = write_file(
            &tmp,
            "commented.rs",
            r#"pub fn safe() {
    // This calls .unwrap() but it's a comment
    /// Example: foo.unwrap()
    let x = Some(1);
}
"#,
        );
        explorer.index_file(&rel).unwrap();

        let report = audit_unwraps(&explorer);
        assert!(
            report.findings.is_empty(),
            "comments with unwrap should be skipped, got {:?}",
            report.findings
        );
    }

    #[test]
    fn includes_scope_name() {
        let tmp = TempDir::new().unwrap();
        let explorer = setup(&tmp);

        let rel = write_file(
            &tmp,
            "scoped.rs",
            r#"pub fn outer_function() {
    Some(1).unwrap();
}
"#,
        );
        explorer.index_file(&rel).unwrap();

        let report = audit_unwraps(&explorer);
        assert!(!report.findings.is_empty());
        assert_eq!(
            report.findings[0].scope_name.as_deref(),
            Some("outer_function"),
            "expected scope_name to be outer_function"
        );
    }
}

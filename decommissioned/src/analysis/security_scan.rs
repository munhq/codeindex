//! Pattern-based security issue detection.
//!
//! Scans indexed source files (.rs, .ts, .tsx, .py) for common security
//! anti-patterns: SQL injection, hardcoded secrets, unsafe blocks, eval
//! usage, CORS wildcards, and more.

use std::path::{Path, PathBuf};

use regex::Regex;
use serde::{Deserialize, Serialize};

use crate::explorer::Explorer;

// ── Models ───────────────────────────────────────────────────────────────────

/// Full security scan report.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SecurityScanReport {
    pub findings: Vec<SecurityFinding>,
    pub summary: SecuritySummary,
}

/// A single security finding tied to a file and line.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SecurityFinding {
    pub file: PathBuf,
    pub line: usize,
    pub line_text: String,
    pub rule: String,
    pub severity: SecuritySeverity,
    pub description: String,
}

/// Severity levels for security findings.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum SecuritySeverity {
    Critical,
    High,
    Medium,
    Low,
}

/// Aggregate counts by severity.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SecuritySummary {
    pub total: usize,
    pub critical: usize,
    pub high: usize,
    pub medium: usize,
    pub low: usize,
}

// ── Rules ────────────────────────────────────────────────────────────────────

lazy_static::lazy_static! {
    /// SQL injection: format!("SELECT/INSERT/UPDATE/DELETE ... {}") style interpolation.
    static ref RE_SQL_INJECTION: Regex = Regex::new(
        r#"format!\s*\(\s*"[^"]*(?:SELECT|INSERT|UPDATE|DELETE)[^"]*\{\}"#
    ).unwrap();

    /// Hardcoded secrets: password = "...", secret = "...", api_key = "...", token = "..."
    static ref RE_HARDCODED_SECRET: Regex = Regex::new(
        r#"(?i)(?:password|secret|api_key|token)\s*=\s*"[^"]+""#
    ).unwrap();

    /// Hardcoded IP addresses (not 127.0.0.1 or 0.0.0.0).
    static ref RE_HARDCODED_IP: Regex = Regex::new(
        r#"\b(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\b"#
    ).unwrap();

    /// Rust unsafe blocks.
    static ref RE_UNSAFE_BLOCK: Regex = Regex::new(
        r#"\bunsafe\s*\{"#
    ).unwrap();

    /// JS/TS eval() usage.
    static ref RE_EVAL_USAGE: Regex = Regex::new(
        r#"\beval\s*\("#
    ).unwrap();

    /// TODO/FIXME/HACK comments mentioning security/auth/token.
    static ref RE_TODO_SECURITY: Regex = Regex::new(
        r#"(?i)(?:TODO.*security|FIXME.*auth|HACK.*token)"#
    ).unwrap();

    /// CORS wildcard: Access-Control-Allow-Origin: * or cors::any().
    static ref RE_CORS_WILDCARD: Regex = Regex::new(
        r#"(?:Access-Control-Allow-Origin\s*.*\*|cors::any\(\))"#
    ).unwrap();

    /// Debug statements in non-test code: dbg!(), console.log(), println!("DEBUG...").
    static ref RE_DEBUG_IN_PROD: Regex = Regex::new(
        r#"(?:dbg!\s*\(|console\.log\s*\(|println!\s*\(\s*"DEBUG)"#
    ).unwrap();
}

/// All applicable file extensions for scanning.
const SCAN_EXTENSIONS: &[&str] = &["rs", "ts", "tsx", "py"];

/// IPs that are safe to hardcode (loopback, any).
const SAFE_IPS: &[&str] = &["127.0.0.1", "0.0.0.0"];

// ── Scanning ─────────────────────────────────────────────────────────────────

/// Run a security scan across all indexed files.
pub fn security_scan(explorer: &Explorer) -> SecurityScanReport {
    let outlines = explorer.get_all_outlines();
    let mut findings = Vec::new();

    for (path, _outline) in &outlines {
        let ext = match path.extension().and_then(|e| e.to_str()) {
            Some(e) => e,
            None => continue,
        };

        if !SCAN_EXTENSIONS.contains(&ext) {
            continue;
        }

        // Skip analysis files (they contain rule patterns as string literals)
        if let Some(p) = path.to_str() {
            if p.contains("analysis/") || p.contains("analysis\\") {
                continue;
            }
        }

        let content = match explorer.filter().read_file(path) {
            Ok(c) => c,
            Err(_) => continue,
        };

        let is_test = is_test_file(path, &content);
        let is_rust = ext == "rs";
        let is_js_ts = matches!(ext, "ts" | "tsx");

        for (line_idx, line) in content.lines().enumerate() {
            let line_num = line_idx + 1;
            let trimmed = line.trim();

            // Skip comment-only lines for secret detection
            let is_comment = trimmed.starts_with("//")
                || trimmed.starts_with('#')
                || trimmed.starts_with('*')
                || trimmed.starts_with("/*");

            // sql-injection (Rust only)
            if is_rust && RE_SQL_INJECTION.is_match(line) {
                findings.push(SecurityFinding {
                    file: path.clone(),
                    line: line_num,
                    line_text: line.to_string(),
                    rule: "sql-injection".to_string(),
                    severity: SecuritySeverity::High,
                    description: "String interpolation in SQL query — use parameterized queries instead".to_string(),
                });
            }

            // hardcoded-secret (skip test files and comments)
            if !is_test && !is_comment && RE_HARDCODED_SECRET.is_match(line) {
                findings.push(SecurityFinding {
                    file: path.clone(),
                    line: line_num,
                    line_text: line.to_string(),
                    rule: "hardcoded-secret".to_string(),
                    severity: SecuritySeverity::Critical,
                    description: "Hardcoded credential — use environment variables or a secret store".to_string(),
                });
            }

            // hardcoded-ip
            if let Some(cap) = RE_HARDCODED_IP.captures(line) {
                let ip = cap.get(1).unwrap().as_str();
                if !SAFE_IPS.contains(&ip) {
                    findings.push(SecurityFinding {
                        file: path.clone(),
                        line: line_num,
                        line_text: line.to_string(),
                        rule: "hardcoded-ip".to_string(),
                        severity: SecuritySeverity::Low,
                        description: format!("Hardcoded IP address {} — consider using configuration", ip),
                    });
                }
            }

            // unsafe-block (Rust only)
            if is_rust && RE_UNSAFE_BLOCK.is_match(line) {
                findings.push(SecurityFinding {
                    file: path.clone(),
                    line: line_num,
                    line_text: line.to_string(),
                    rule: "unsafe-block".to_string(),
                    severity: SecuritySeverity::Medium,
                    description: "Unsafe block — ensure memory safety invariants are upheld".to_string(),
                });
            }

            // eval-usage (JS/TS only)
            if is_js_ts && RE_EVAL_USAGE.is_match(line) {
                findings.push(SecurityFinding {
                    file: path.clone(),
                    line: line_num,
                    line_text: line.to_string(),
                    rule: "eval-usage".to_string(),
                    severity: SecuritySeverity::High,
                    description: "eval() usage — risk of code injection".to_string(),
                });
            }

            // todo-security
            if RE_TODO_SECURITY.is_match(line) {
                findings.push(SecurityFinding {
                    file: path.clone(),
                    line: line_num,
                    line_text: line.to_string(),
                    rule: "todo-security".to_string(),
                    severity: SecuritySeverity::Low,
                    description: "Security-related TODO/FIXME — ensure this is tracked".to_string(),
                });
            }

            // cors-wildcard
            if RE_CORS_WILDCARD.is_match(line) {
                findings.push(SecurityFinding {
                    file: path.clone(),
                    line: line_num,
                    line_text: line.to_string(),
                    rule: "cors-wildcard".to_string(),
                    severity: SecuritySeverity::Medium,
                    description: "CORS wildcard allows any origin — restrict to known domains".to_string(),
                });
            }

            // debug-in-prod (skip test files)
            if !is_test && RE_DEBUG_IN_PROD.is_match(line) {
                findings.push(SecurityFinding {
                    file: path.clone(),
                    line: line_num,
                    line_text: line.to_string(),
                    rule: "debug-in-prod".to_string(),
                    severity: SecuritySeverity::Low,
                    description: "Debug statement in non-test code — remove before production".to_string(),
                });
            }
        }
    }

    findings.sort_by(|a, b| a.file.cmp(&b.file).then(a.line.cmp(&b.line)));

    let summary = SecuritySummary {
        total: findings.len(),
        critical: findings.iter().filter(|f| f.severity == SecuritySeverity::Critical).count(),
        high: findings.iter().filter(|f| f.severity == SecuritySeverity::High).count(),
        medium: findings.iter().filter(|f| f.severity == SecuritySeverity::Medium).count(),
        low: findings.iter().filter(|f| f.severity == SecuritySeverity::Low).count(),
    };

    SecurityScanReport { findings, summary }
}

/// Heuristic: is this a test file?
fn is_test_file(path: &Path, content: &str) -> bool {
    let path_str = path.to_string_lossy();
    path_str.contains("test")
        || path_str.contains("spec")
        || path_str.ends_with("_test.rs")
        || path_str.ends_with("_test.py")
        || path_str.ends_with(".test.ts")
        || path_str.ends_with(".test.tsx")
        || path_str.ends_with(".spec.ts")
        || path_str.ends_with(".spec.tsx")
        || content.contains("#[cfg(test)]")
        || content.contains("#[test]")
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
    fn detects_sql_injection() {
        let tmp = TempDir::new().unwrap();
        let explorer = setup(&tmp);
        let rel = write_file(&tmp, "bad.rs", r#"
fn query(name: &str) {
    let q = format!("SELECT * FROM users WHERE name = {}", name);
}
"#);
        explorer.index_file(&rel).unwrap();
        let report = security_scan(&explorer);
        assert!(report.findings.iter().any(|f| f.rule == "sql-injection"));
        assert!(report.summary.high >= 1);
    }

    #[test]
    fn detects_hardcoded_secret() {
        let tmp = TempDir::new().unwrap();
        let explorer = setup(&tmp);
        let rel = write_file(&tmp, "config.rs", r#"
let password = "super_secret_123";
"#);
        explorer.index_file(&rel).unwrap();
        let report = security_scan(&explorer);
        assert!(report.findings.iter().any(|f| f.rule == "hardcoded-secret"));
        assert!(report.summary.critical >= 1);
    }

    #[test]
    fn skips_secrets_in_test_files() {
        let tmp = TempDir::new().unwrap();
        let explorer = setup(&tmp);
        let rel = write_file(&tmp, "config_test.rs", r#"
#[test]
fn test_auth() {
    let password = "test_password";
}
"#);
        explorer.index_file(&rel).unwrap();
        let report = security_scan(&explorer);
        assert!(!report.findings.iter().any(|f| f.rule == "hardcoded-secret"));
    }

    #[test]
    fn detects_unsafe_block() {
        let tmp = TempDir::new().unwrap();
        let explorer = setup(&tmp);
        let rel = write_file(&tmp, "ffi.rs", r#"
fn danger() {
    unsafe {
        std::ptr::null::<u8>().read();
    }
}
"#);
        explorer.index_file(&rel).unwrap();
        let report = security_scan(&explorer);
        assert!(report.findings.iter().any(|f| f.rule == "unsafe-block"));
    }

    #[test]
    fn detects_eval_in_ts() {
        let tmp = TempDir::new().unwrap();
        let explorer = setup(&tmp);
        let rel = write_file(&tmp, "bad.ts", r#"
function run(code: string) {
    return eval(code);
}
"#);
        explorer.index_file(&rel).unwrap();
        let report = security_scan(&explorer);
        assert!(report.findings.iter().any(|f| f.rule == "eval-usage"));
    }

    #[test]
    fn detects_hardcoded_ip() {
        let tmp = TempDir::new().unwrap();
        let explorer = setup(&tmp);
        let rel = write_file(&tmp, "net.rs", r#"
let server = "192.168.1.100";
let loopback = "127.0.0.1";
"#);
        explorer.index_file(&rel).unwrap();
        let report = security_scan(&explorer);
        let ip_findings: Vec<_> = report.findings.iter().filter(|f| f.rule == "hardcoded-ip").collect();
        // Should find 192.168.1.100 but not 127.0.0.1
        assert_eq!(ip_findings.len(), 1);
        assert!(ip_findings[0].description.contains("192.168.1.100"));
    }

    #[test]
    fn detects_cors_wildcard() {
        let tmp = TempDir::new().unwrap();
        let explorer = setup(&tmp);
        let rel = write_file(&tmp, "server.rs", r#"
let cors = cors::any();
"#);
        explorer.index_file(&rel).unwrap();
        let report = security_scan(&explorer);
        assert!(report.findings.iter().any(|f| f.rule == "cors-wildcard"));
    }

    #[test]
    fn detects_debug_in_prod() {
        let tmp = TempDir::new().unwrap();
        let explorer = setup(&tmp);
        let rel = write_file(&tmp, "handler.rs", r#"
fn handle() {
    dbg!(some_value);
}
"#);
        explorer.index_file(&rel).unwrap();
        let report = security_scan(&explorer);
        assert!(report.findings.iter().any(|f| f.rule == "debug-in-prod"));
    }

    #[test]
    fn summary_counts_correct() {
        let tmp = TempDir::new().unwrap();
        let explorer = setup(&tmp);
        write_file(&tmp, "mixed.rs", r#"
let password = "secret123";
unsafe {
    do_stuff();
}
"#);
        explorer.index_file(Path::new("mixed.rs")).unwrap();
        let report = security_scan(&explorer);
        assert_eq!(report.summary.total, report.summary.critical + report.summary.high + report.summary.medium + report.summary.low);
    }
}

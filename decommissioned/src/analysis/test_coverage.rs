//! Structural test coverage analysis.
//!
//! Determines which modules have tests and which don't by examining:
//! - How many `#[test]` functions exist in each file
//! - How many symbols from non-test files are referenced in test files
//!
//! This is a structural heuristic, not runtime coverage.

use std::collections::HashSet;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::explorer::Explorer;
use crate::models::SymbolKind;

// ── Models ───────────────────────────────────────────────────────────────────

/// Coverage level for a module, based on what fraction of its symbols
/// are referenced in test files.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum CoverageLevel {
    /// No symbols referenced in any test file.
    None,
    /// Less than 25% of public symbols referenced in tests.
    Low,
    /// 25%–74% of public symbols referenced in tests.
    Medium,
    /// 75% or more of public symbols referenced in tests.
    High,
}

/// Coverage information for a single module (file).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModuleCoverage {
    pub file: PathBuf,
    pub total_symbols: usize,
    pub public_symbols: usize,
    pub test_symbols: usize,
    pub referenced_in_tests: usize,
    pub coverage_level: CoverageLevel,
}

/// Summary statistics for the test coverage report.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TestCoverageSummary {
    pub total_modules: usize,
    pub untested: usize,
    pub low: usize,
    pub medium: usize,
    pub high: usize,
}

/// Full test coverage report.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TestCoverageReport {
    pub modules: Vec<ModuleCoverage>,
    pub summary: TestCoverageSummary,
}

// ── Helpers ──────────────────────────────────────────────────────────────────

/// Returns true if a file is considered a test file.
fn is_test_file(path: &PathBuf, test_symbol_count: usize) -> bool {
    let path_str = path.to_string_lossy().to_lowercase();

    // Go convention: files ending in _test.go
    if path_str.ends_with("_test.go") {
        return true;
    }

    // Files with "test" in the path
    if path_str.contains("test") {
        return true;
    }

    // Files that contain test symbols
    if test_symbol_count > 0 {
        return true;
    }

    false
}

/// Classify coverage level from the fraction of symbols referenced in tests.
fn classify(referenced: usize, total_checkable: usize) -> CoverageLevel {
    if total_checkable == 0 || referenced == 0 {
        return CoverageLevel::None;
    }

    let ratio = referenced as f64 / total_checkable as f64;

    if ratio >= 0.75 {
        CoverageLevel::High
    } else if ratio >= 0.25 {
        CoverageLevel::Medium
    } else {
        CoverageLevel::Low
    }
}

// ── Analysis ─────────────────────────────────────────────────────────────────

/// Analyze structural test coverage across all indexed files.
///
/// For each non-test file, checks how many of its symbols are referenced
/// in any test file via the word index.
pub fn analyze_test_coverage(explorer: &Explorer) -> TestCoverageReport {
    let outlines = explorer.get_all_outlines();

    // First pass: identify test files and collect their paths
    let mut test_file_paths: HashSet<String> = HashSet::new();
    let mut file_test_counts: Vec<(PathBuf, usize)> = Vec::new();

    for (path, outline) in &outlines {
        let test_count = outline
            .symbols
            .iter()
            .filter(|s| s.kind == SymbolKind::Test)
            .count();

        file_test_counts.push((path.clone(), test_count));

        if is_test_file(path, test_count) {
            test_file_paths.insert(path.to_string_lossy().to_string());
        }
    }

    // Second pass: for each non-test file, count how many of its symbols
    // are referenced in test files
    let mut modules: Vec<ModuleCoverage> = Vec::new();

    for (path, outline) in &outlines {
        let path_str = path.to_string_lossy().to_string();

        // Count test symbols in this file
        let test_symbols = outline
            .symbols
            .iter()
            .filter(|s| s.kind == SymbolKind::Test)
            .count();

        // Skip pure test files from the coverage report — they don't need
        // to be "tested" themselves
        if test_file_paths.contains(&path_str) && test_symbols > 0 {
            // Still include files that happen to have "test" in the path
            // but have production symbols too (e.g., test utilities)
            let non_test_symbols = outline
                .symbols
                .iter()
                .filter(|s| {
                    !matches!(
                        s.kind,
                        SymbolKind::Test | SymbolKind::Import | SymbolKind::Module
                    )
                })
                .count();

            if non_test_symbols == 0 {
                continue;
            }
        }

        let total_symbols = outline.symbols.len();

        // Count "public" symbols (functions, structs, enums, traits, etc. — not imports/modules)
        let public_symbols: Vec<&crate::models::Symbol> = outline
            .symbols
            .iter()
            .filter(|s| {
                !matches!(
                    s.kind,
                    SymbolKind::Test | SymbolKind::Import | SymbolKind::Module
                )
            })
            .collect();

        let public_count = public_symbols.len();

        // Check how many of the public symbols appear in any test file
        let mut referenced_count = 0;
        for symbol in &public_symbols {
            if symbol.name.len() < 3 {
                continue;
            }

            let hits = explorer.find_word(&symbol.name);
            let referenced_in_test = hits
                .iter()
                .any(|hit| hit.path != path_str && test_file_paths.contains(&hit.path));

            if referenced_in_test {
                referenced_count += 1;
            }
        }

        let coverage_level = classify(referenced_count, public_count);

        modules.push(ModuleCoverage {
            file: path.clone(),
            total_symbols,
            public_symbols: public_count,
            test_symbols,
            referenced_in_tests: referenced_count,
            coverage_level,
        });
    }

    // Sort by file path for stable output
    modules.sort_by(|a, b| a.file.cmp(&b.file));

    // Build summary
    let mut summary = TestCoverageSummary {
        total_modules: modules.len(),
        untested: 0,
        low: 0,
        medium: 0,
        high: 0,
    };

    for m in &modules {
        match m.coverage_level {
            CoverageLevel::None => summary.untested += 1,
            CoverageLevel::Low => summary.low += 1,
            CoverageLevel::Medium => summary.medium += 1,
            CoverageLevel::High => summary.high += 1,
        }
    }

    TestCoverageReport { modules, summary }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::Path;
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
    fn untested_module_has_none_coverage() {
        let tmp = TempDir::new().unwrap();
        let explorer = setup(&tmp);

        let rel = write_file(
            &tmp,
            "lonely.rs",
            "pub fn lonely_function() {}\npub struct LonelyStruct {}\n",
        );
        explorer.index_file(&rel).unwrap();

        let report = analyze_test_coverage(&explorer);

        assert_eq!(report.modules.len(), 1);
        assert_eq!(report.modules[0].coverage_level, CoverageLevel::None);
        assert_eq!(report.summary.untested, 1);
    }

    #[test]
    fn referenced_in_test_file_counts() {
        let tmp = TempDir::new().unwrap();
        let explorer = setup(&tmp);

        let rel_lib = write_file(
            &tmp,
            "lib.rs",
            "pub fn target_function() {}\npub fn another_function() {}\n",
        );
        let rel_test = write_file(
            &tmp,
            "test_lib.rs",
            "#[test]\nfn test_it() { target_function(); }\n",
        );

        explorer.index_file(&rel_lib).unwrap();
        explorer.index_file(&rel_test).unwrap();

        let report = analyze_test_coverage(&explorer);

        // Find the lib.rs module in the report
        let lib_mod = report
            .modules
            .iter()
            .find(|m| m.file == PathBuf::from("lib.rs"))
            .expect("lib.rs should be in the report");

        assert!(
            lib_mod.referenced_in_tests >= 1,
            "expected at least 1 symbol referenced in tests, got {}",
            lib_mod.referenced_in_tests
        );
    }

    #[test]
    fn classify_thresholds() {
        assert_eq!(classify(0, 10), CoverageLevel::None);
        assert_eq!(classify(1, 10), CoverageLevel::Low);
        assert_eq!(classify(3, 10), CoverageLevel::Medium);
        assert_eq!(classify(8, 10), CoverageLevel::High);
        assert_eq!(classify(0, 0), CoverageLevel::None);
    }

    #[test]
    fn summary_counts_are_consistent() {
        let tmp = TempDir::new().unwrap();
        let explorer = setup(&tmp);

        write_file(&tmp, "a.rs", "pub fn alpha_func() {}\n");
        write_file(&tmp, "b.rs", "pub fn beta_func() {}\n");

        explorer.index_file(Path::new("a.rs")).unwrap();
        explorer.index_file(Path::new("b.rs")).unwrap();

        let report = analyze_test_coverage(&explorer);
        let s = &report.summary;

        assert_eq!(
            s.total_modules,
            s.untested + s.low + s.medium + s.high,
            "summary counts should add up to total_modules"
        );
    }
}

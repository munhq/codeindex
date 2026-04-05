//! Dead code detection: symbols defined but never referenced elsewhere.
//!
//! For each symbol in outlines, searches the word index for that symbol's name.
//! If all hits are in the same file as the definition, it's potentially dead code.
//!
//! Skips common false positives: `main`, `new`, `default`, `test_*`, symbols in
//! `mod.rs` (re-exports), trait impls, very short names (<3 chars), and
//! SymbolKind::Test, Import, Module.

use std::collections::HashMap;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::explorer::Explorer;
use crate::models::SymbolKind;

// ── Models ───────────────────────────────────────────────────────────────────

/// A symbol that appears to be dead (unreferenced outside its defining file).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeadSymbol {
    pub name: String,
    pub kind: SymbolKind,
    pub file: PathBuf,
    pub line: usize,
    pub reason: String,
}

/// Summary statistics for the dead code report.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeadCodeSummary {
    pub total_symbols: usize,
    pub dead_count: usize,
    pub by_kind: HashMap<String, usize>,
}

/// Full dead code analysis report.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeadCodeReport {
    pub dead_symbols: Vec<DeadSymbol>,
    pub summary: DeadCodeSummary,
}

// ── Skip list ────────────────────────────────────────────────────────────────

/// Well-known function names that are entry points or trait conventions,
/// not dead code even if only referenced locally.
const FALSE_POSITIVE_NAMES: &[&str] = &[
    "main", "new", "default", "fmt", "from", "into", "drop", "clone",
    "eq", "hash", "serialize", "deserialize", "build", "run", "init",
    "deref", "as_ref", "as_str", "into_response", "as_mut",
    "try_from", "try_into", "partial_cmp", "cmp", "next",
    "poll", "index", "borrow", "borrow_mut", "display",
];

/// Attribute markers that indicate a symbol is externally referenced.
const EXTERN_ATTRS: &[&str] = &[
    "#[no_mangle]", "#[export_name", "#[wasm_bindgen", "#[pyfunction",
    "#[pyclass", "#[pymethods",
];

/// Returns true if the symbol should be skipped during dead-code analysis.
fn should_skip(name: &str, kind: SymbolKind, file: &PathBuf, file_content: Option<&str>, line: usize) -> bool {
    // Skip kinds that are never "dead" in a meaningful sense
    if matches!(kind, SymbolKind::Test | SymbolKind::Import | SymbolKind::Module) {
        return true;
    }

    // Skip very short names — too many false positives
    if name.len() < 3 {
        return true;
    }

    // Skip test functions
    if name.starts_with("test_") {
        return true;
    }

    // Skip well-known entry-point / trait-impl names
    let name_lower = name.to_lowercase();
    if FALSE_POSITIVE_NAMES.contains(&name_lower.as_str()) {
        return true;
    }

    // Skip symbols defined in mod.rs (likely re-exports)
    if let Some(file_name) = file.file_name().and_then(|f| f.to_str()) {
        if file_name == "mod.rs" || file_name == "lib.rs" || file_name == "__init__.py" {
            return true;
        }

        // Skip React component functions in .tsx files (PascalCase = JSX component)
        if (file_name.ends_with(".tsx") || file_name.ends_with(".jsx"))
            && name.len() >= 2
            && name.chars().next().map_or(false, |c| c.is_uppercase())
            && name.chars().nth(1).map_or(false, |c| c.is_lowercase())
        {
            return true;
        }
    }

    // Skip trait impl blocks
    if kind == SymbolKind::Impl {
        return true;
    }

    // Check file content for context clues around the symbol definition
    if let Some(content) = file_content {
        let lines: Vec<&str> = content.lines().collect();

        // Check nearby lines (up to 5 lines before) for #[derive(], extern attributes, export default
        let start = if line > 5 { line - 5 } else { 0 };
        let end = std::cmp::min(line + 1, lines.len());
        for k in start..end {
            if let Some(l) = lines.get(k) {
                let trimmed = l.trim();

                // Skip symbols near #[derive()] — derive macros generate trait impls
                if trimmed.starts_with("#[derive(") {
                    return true;
                }

                // Skip symbols with external-linkage attributes
                for attr in EXTERN_ATTRS {
                    if trimmed.starts_with(attr) {
                        return true;
                    }
                }

                // Skip TypeScript `export default` symbols
                if trimmed.starts_with("export default") {
                    return true;
                }
            }
        }
    }

    false
}

/// Check if a symbol is pub use re-exported somewhere in the codebase.
fn is_pub_use_reexported(name: &str, explorer: &Explorer) -> bool {
    let results = explorer.search_content("pub use");
    for result in &results {
        if result.line_text.contains(name) {
            return true;
        }
    }
    false
}

// ── Analysis ─────────────────────────────────────────────────────────────────

/// Detect potentially dead code: symbols defined but never referenced elsewhere.
///
/// Iterates all symbols in the explorer's outlines, searches the word index for
/// each symbol name, and flags symbols whose references all live in the same file
/// as the definition.
pub fn find_dead_code(explorer: &Explorer) -> DeadCodeReport {
    let outlines = explorer.get_all_outlines();
    let mut dead_symbols: Vec<DeadSymbol> = Vec::new();
    let mut total_symbols: usize = 0;

    // Pre-read content for each file to pass to should_skip for context checks.
    let mut content_cache: HashMap<PathBuf, String> = HashMap::new();
    for path in outlines.keys() {
        if let Ok(content) = explorer.filter().read_file(path) {
            content_cache.insert(path.clone(), content);
        }
    }

    for (path, outline) in &outlines {
        let file_content = content_cache.get(path).map(|s| s.as_str());

        for symbol in &outline.symbols {
            if should_skip(&symbol.name, symbol.kind, path, file_content, symbol.line_start.saturating_sub(1)) {
                continue;
            }

            total_symbols += 1;

            let hits = explorer.find_word(&symbol.name);
            let defining_file = path.to_string_lossy().to_string();

            // Check if all references are in the defining file
            let all_local = hits.iter().all(|hit| hit.path == defining_file);

            if all_local {
                // Additional check: see if symbol is pub use re-exported
                if is_pub_use_reexported(&symbol.name, explorer) {
                    continue;
                }

                dead_symbols.push(DeadSymbol {
                    name: symbol.name.clone(),
                    kind: symbol.kind,
                    file: path.clone(),
                    line: symbol.line_start,
                    reason: "no references outside defining file".to_string(),
                });
            }
        }
    }

    // Sort by file path, then by line
    dead_symbols.sort_by(|a, b| a.file.cmp(&b.file).then(a.line.cmp(&b.line)));

    // Build by_kind summary
    let mut by_kind: HashMap<String, usize> = HashMap::new();
    for ds in &dead_symbols {
        *by_kind.entry(ds.kind.as_str().to_string()).or_insert(0) += 1;
    }

    let dead_count = dead_symbols.len();

    DeadCodeReport {
        dead_symbols,
        summary: DeadCodeSummary {
            total_symbols,
            dead_count,
            by_kind,
        },
    }
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
    fn detects_unreferenced_symbol() {
        let tmp = TempDir::new().unwrap();
        let explorer = setup(&tmp);

        let rel_a = write_file(
            &tmp,
            "alpha.rs",
            "pub fn used_elsewhere() {}\npub fn lonely_function() {}\n",
        );
        let rel_b = write_file(
            &tmp,
            "beta.rs",
            "use crate::alpha;\nfn caller() { used_elsewhere(); }\n",
        );

        explorer.index_file(&rel_a).unwrap();
        explorer.index_file(&rel_b).unwrap();

        let report = find_dead_code(&explorer);

        let dead_names: Vec<&str> = report.dead_symbols.iter().map(|d| d.name.as_str()).collect();
        assert!(
            dead_names.contains(&"lonely_function"),
            "expected lonely_function to be dead, got: {dead_names:?}"
        );
        assert!(
            !dead_names.contains(&"used_elsewhere"),
            "used_elsewhere should not be dead"
        );
    }

    #[test]
    fn skips_main_and_short_names() {
        let tmp = TempDir::new().unwrap();
        let explorer = setup(&tmp);

        let rel = write_file(
            &tmp,
            "entry.rs",
            "fn main() {}\nfn ab() {}\nfn real_function() {}\n",
        );
        explorer.index_file(&rel).unwrap();

        let report = find_dead_code(&explorer);
        let dead_names: Vec<&str> = report.dead_symbols.iter().map(|d| d.name.as_str()).collect();

        assert!(!dead_names.contains(&"main"), "main should be skipped");
        assert!(!dead_names.contains(&"ab"), "short names should be skipped");
    }

    #[test]
    fn skips_test_functions() {
        let tmp = TempDir::new().unwrap();
        let explorer = setup(&tmp);

        let rel = write_file(
            &tmp,
            "tests.rs",
            "#[test]\nfn test_something() {}\npub fn orphan_helper() {}\n",
        );
        explorer.index_file(&rel).unwrap();

        let report = find_dead_code(&explorer);
        let dead_names: Vec<&str> = report.dead_symbols.iter().map(|d| d.name.as_str()).collect();

        assert!(
            !dead_names.contains(&"test_something"),
            "test_ prefixed functions should be skipped"
        );
    }

    #[test]
    fn skips_mod_rs_symbols() {
        let tmp = TempDir::new().unwrap();
        let explorer = setup(&tmp);

        let rel = write_file(
            &tmp,
            "things/mod.rs",
            "pub fn reexported_thing() {}\n",
        );
        explorer.index_file(&rel).unwrap();

        let report = find_dead_code(&explorer);
        let dead_names: Vec<&str> = report.dead_symbols.iter().map(|d| d.name.as_str()).collect();

        assert!(
            !dead_names.contains(&"reexported_thing"),
            "symbols in mod.rs should be skipped"
        );
    }

    #[test]
    fn summary_counts_match() {
        let tmp = TempDir::new().unwrap();
        let explorer = setup(&tmp);

        let rel = write_file(
            &tmp,
            "widgets.rs",
            "pub struct Widget {}\npub fn create_widget() {}\npub fn isolated_func() {}\n",
        );
        explorer.index_file(&rel).unwrap();

        let report = find_dead_code(&explorer);
        assert_eq!(report.summary.dead_count, report.dead_symbols.len());
        assert!(report.summary.total_symbols > 0);
    }

    #[test]
    fn skips_derive_adjacent_symbols() {
        let tmp = TempDir::new().unwrap();
        let explorer = setup(&tmp);

        let rel = write_file(
            &tmp,
            "derived.rs",
            "#[derive(Debug, Clone)]\npub struct MyData {\n    pub value: u32,\n}\n\npub fn lonely_fn() {}\n",
        );
        explorer.index_file(&rel).unwrap();

        let report = find_dead_code(&explorer);
        let dead_names: Vec<&str> = report.dead_symbols.iter().map(|d| d.name.as_str()).collect();
        assert!(
            !dead_names.contains(&"MyData"),
            "symbols near #[derive()] should be skipped"
        );
    }

    #[test]
    fn skips_tsx_pascal_case_components() {
        let tmp = TempDir::new().unwrap();
        let explorer = setup(&tmp);

        let rel = write_file(
            &tmp,
            "Button.tsx",
            "export function Button() {\n  return null;\n}\n",
        );
        explorer.index_file(&rel).unwrap();

        let report = find_dead_code(&explorer);
        let dead_names: Vec<&str> = report.dead_symbols.iter().map(|d| d.name.as_str()).collect();
        assert!(
            !dead_names.contains(&"Button"),
            "PascalCase components in .tsx should be skipped"
        );
    }
}

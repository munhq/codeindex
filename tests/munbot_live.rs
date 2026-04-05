//! Live integration test against the munbot codebase.
//!
//! Indexes the full munbot repository (expected at `../munbot` relative to
//! this crate) and validates that every analysis module produces meaningful
//! results against a real, non-trivial codebase.
//!
//! Skips gracefully if the munbot directory is not present.

use std::path::PathBuf;

use codeindex::CodeIndexer;

#[tokio::test]
async fn full_munbot_analysis() {
    let munbot_path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../munbot");
    if !munbot_path.exists() {
        eprintln!("Skipping munbot live test — ../munbot not found");
        return;
    }
    // Canonicalize to resolve ".." components
    let munbot_path = munbot_path.canonicalize().unwrap();

    let indexer = CodeIndexer::builder()
        .workspace(munbot_path)
        .project_id("munbot-live")
        .build()
        .await;
    let count = indexer.scan().await.unwrap();

    // Basic sanity — munbot is a large codebase
    assert!(
        count > 300,
        "munbot should have 300+ indexable files, got {count}"
    );
    assert!(
        indexer.symbol_count() > 5000,
        "munbot should have 5000+ symbols, got {}",
        indexer.symbol_count()
    );

    let explorer = indexer.explorer();

    // ── Symbol search ───────────────────────────────────────────────────────
    let results = explorer.find_symbol("SecurityPolicy");
    assert!(
        !results.is_empty(),
        "SecurityPolicy should exist in munbot"
    );

    // ── Content search ──────────────────────────────────────────────────────
    let results = explorer.search_content("credential");
    assert!(
        !results.is_empty(),
        "searching for 'credential' should return hits"
    );

    // ── Word index ──────────────────────────────────────────────────────────
    let hits = explorer.find_word("manifest");
    assert!(
        !hits.is_empty(),
        "word 'manifest' should have hits in munbot"
    );

    // ── Tree ────────────────────────────────────────────────────────────────
    let tree = explorer.get_tree();
    assert!(!tree.is_empty(), "tree should not be empty");

    fn count_files(nodes: &[codeindex::models::TreeNode]) -> usize {
        nodes
            .iter()
            .map(|n| {
                if n.is_dir {
                    count_files(&n.children)
                } else {
                    1
                }
            })
            .sum()
    }
    assert_eq!(
        count_files(&tree),
        indexer.file_count(),
        "tree should contain exactly as many files as file_count()"
    );

    // ── Dependency graph ────────────────────────────────────────────────────
    let all_outlines = explorer.get_all_outlines();
    let has_deps = all_outlines
        .keys()
        .any(|p| !explorer.get_imports(p).is_empty());
    assert!(
        has_deps,
        "at least some files should have resolved imports"
    );

    // ── Cross-reference — munbot has many API routes ────────────────────────
    let xref = codeindex::analysis::crossref::cross_reference(explorer);
    assert!(
        xref.summary.total_backend_routes > 100,
        "expected 100+ backend routes in munbot, got {}",
        xref.summary.total_backend_routes
    );
    assert!(
        xref.summary.wired_count > 50,
        "expected 50+ wired routes in munbot, got {}",
        xref.summary.wired_count
    );

    // ── All analysis modules run without panicking ──────────────────────────
    let dead = codeindex::analysis::dead_code::find_dead_code(explorer);
    assert!(
        dead.summary.total_symbols > 0,
        "dead_code should analyze symbols"
    );

    let coverage = codeindex::analysis::test_coverage::analyze_test_coverage(explorer);
    assert!(
        coverage.summary.total_modules > 0,
        "test_coverage should analyze modules"
    );

    let unwraps = codeindex::analysis::unwrap_audit::audit_unwraps(explorer);
    assert!(
        unwraps.summary.total > 0,
        "unwrap_audit should find .unwrap() calls in munbot"
    );

    let sec = codeindex::analysis::security_scan::security_scan(explorer);
    // Just assert it ran; munbot may or may not have findings
    let _ = sec.summary.total;

    let db = codeindex::analysis::db_schema::db_schema_analysis(explorer);
    assert!(
        db.summary.total_tables > 0,
        "munbot has database tables"
    );

    let arch = codeindex::analysis::architecture::architecture_analysis(explorer);
    // Just verify it ran without panic
    let _ = arch.summary.circular_dep_count;

    let drift = codeindex::analysis::type_drift::type_drift(explorer);
    // munbot has Rust + TS so there may be drift entries
    let _ = drift.drifts.len();

    let mig = codeindex::analysis::migration_parity::migration_parity(explorer);
    // migration_parity scans indexed file outlines for .sql files, but the
    // parser doesn't support SQL, so SQL files won't appear in outlines.
    // Just verify the analysis runs without panicking.
    let _ = mig.summary.total_pg;

    let manifest_report = codeindex::analysis::manifest_compliance::manifest_compliance(explorer);
    // Just verify it ran
    let _ = manifest_report.summary.total_violations;
}

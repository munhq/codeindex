//! Live analysis tests — indexes the codeindex crate's own source and runs
//! every analysis module, verifying the results make sense for this codebase.

use std::path::PathBuf;

use codeindex::analysis::architecture::architecture_analysis;
use codeindex::analysis::crossref::cross_reference;
use codeindex::analysis::db_schema::db_schema_analysis;
use codeindex::analysis::dead_code::find_dead_code;
use codeindex::analysis::manifest_compliance::manifest_compliance;
use codeindex::analysis::migration_parity::migration_parity;
use codeindex::analysis::security_scan::security_scan;
use codeindex::analysis::test_coverage::analyze_test_coverage;
use codeindex::analysis::type_drift::type_drift;
use codeindex::analysis::unwrap_audit::audit_unwraps;
use codeindex::CodeIndexer;

#[tokio::test]
async fn full_analysis_on_own_source() {
    let workspace = PathBuf::from(env!("CARGO_MANIFEST_DIR"));

    let indexer = CodeIndexer::builder()
        .workspace(workspace)
        .project_id("codeindex-self")
        .build()
        .await;
    indexer.scan().await.unwrap();

    let explorer = indexer.explorer();

    // Sanity: codeindex should have a reasonable number of files and symbols
    assert!(
        indexer.file_count() >= 15,
        "expected at least 15 files in codeindex src, got {}",
        indexer.file_count()
    );
    assert!(
        indexer.symbol_count() >= 100,
        "expected at least 100 symbols in codeindex, got {}",
        indexer.symbol_count()
    );

    // 1. Cross-reference — this is a library crate, so very few (if any)
    //    routes may be detected (false positives from test fixtures, etc.)
    let xref = cross_reference(explorer);
    assert!(
        xref.summary.total_backend_routes < 5,
        "codeindex should have very few backend routes, got {}",
        xref.summary.total_backend_routes
    );

    // 2. Dead code — should find some dead symbols but not flag everything
    let dead = find_dead_code(explorer);
    assert!(
        dead.summary.dead_count < dead.summary.total_symbols,
        "dead code analysis should not flag every symbol as dead"
    );
    assert!(
        dead.summary.total_symbols > 0,
        "should have scanned some symbols"
    );

    // 3. Test coverage — this crate has tests, so at least some modules
    //    should have high coverage
    let coverage = analyze_test_coverage(explorer);
    assert!(
        coverage.summary.total_modules > 0,
        "should have analyzed at least one module"
    );

    // 4. Unwrap audit — should find some .unwrap() calls (used in tests and
    //    non-critical paths)
    let unwraps = audit_unwraps(explorer);
    assert!(
        unwraps.summary.total > 0,
        "codeindex uses .unwrap() in places, should find some"
    );
    // Some may be flagged "critical" due to async fn presence in source files,
    // but the majority should be warning/info level
    assert!(
        unwraps.summary.critical < unwraps.summary.total,
        "not every unwrap should be critical"
    );

    // 5. Security scan — pure library, should be clean
    let sec = security_scan(explorer);
    assert_eq!(
        sec.summary.critical, 0,
        "codeindex should have 0 critical security findings"
    );

    // 6. DB schema — no SQL migrations in this crate
    let db = db_schema_analysis(explorer);
    assert_eq!(
        db.summary.total_tables, 0,
        "no DB tables expected in codeindex"
    );

    // 7. Architecture — should have no circular dependencies
    let arch = architecture_analysis(explorer);
    assert_eq!(
        arch.summary.circular_dep_count, 0,
        "codeindex should have no circular deps"
    );

    // 8. Type drift — no TS types mirroring Rust types in this crate
    let drift = type_drift(explorer);
    assert_eq!(
        drift.drifts.len(),
        0,
        "no type drift expected in pure-Rust crate"
    );

    // 9. Migration parity — no migrations directory
    let mig = migration_parity(explorer);
    assert_eq!(
        mig.pg_only.len(),
        0,
        "no PG-only migrations in codeindex"
    );
    assert_eq!(
        mig.sqlite_only.len(),
        0,
        "no SQLite-only migrations in codeindex"
    );

    // 10. Manifest compliance — no manifests to validate
    let manifest_report = manifest_compliance(explorer);
    assert_eq!(
        manifest_report.summary.total_violations, 0,
        "no manifest violations expected in codeindex"
    );
}

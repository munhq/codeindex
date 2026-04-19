//! Live file watcher integration tests.
//!
//! These tests verify that the file-system watcher detects new files,
//! modifications, and deletions, then re-indexes accordingly.
//!
//! Feature-gated behind `watcher` (default feature).

#![cfg(feature = "watcher")]

use std::path::PathBuf;
use std::time::Duration;

use tempfile::TempDir;
use tokio::time::sleep;

use codeindex::CodeIndexer;

/// Write a file into the temp workspace and return its relative path.
fn write_file(tmp: &TempDir, rel: &str, content: &str) -> PathBuf {
    let full = tmp.path().join(rel);
    if let Some(parent) = full.parent() {
        std::fs::create_dir_all(parent).unwrap();
    }
    std::fs::write(&full, content).unwrap();
    PathBuf::from(rel)
}

/// Build a CodeIndexer, scan, and start the watcher.
async fn setup_with_watcher(tmp: &TempDir) -> CodeIndexer {
    let mut indexer = CodeIndexer::builder()
        .workspace(tmp.path().to_path_buf())
        .project_id("watcher-test")
        .build()
        .await;
    indexer.scan().await.unwrap();
    indexer.start_watcher();
    // Give the watcher time to initialize
    sleep(Duration::from_millis(100)).await;
    indexer
}

#[tokio::test]
async fn watcher_detects_new_file() {
    let tmp = TempDir::new().unwrap();

    // Seed with one file so we have a valid workspace
    write_file(&tmp, "existing.rs", "pub fn existing() {}\n");

    let indexer = setup_with_watcher(&tmp).await;
    assert_eq!(indexer.file_count(), 1);

    // Write a NEW file into the workspace
    write_file(&tmp, "newcomer.rs", "pub fn newcomer_function() {}\n");

    // Wait for debounce (200ms) plus margin
    sleep(Duration::from_millis(800)).await;

    // The watcher should have picked up and indexed the new file
    assert_eq!(
        indexer.file_count(),
        2,
        "watcher should have indexed the new file"
    );

    let symbols = indexer.find_symbol("newcomer_function");
    assert!(
        !symbols.is_empty(),
        "newcomer_function should appear in symbol index after watcher pickup"
    );
}

#[tokio::test]
async fn watcher_detects_modification() {
    let tmp = TempDir::new().unwrap();

    write_file(&tmp, "mutable.rs", "pub fn old_function() {}\n");

    let indexer = setup_with_watcher(&tmp).await;

    // Verify old_function is indexed
    assert!(
        !indexer.find_symbol("old_function").is_empty(),
        "old_function should exist before modification"
    );

    // Overwrite the file with different content
    write_file(&tmp, "mutable.rs", "pub fn new_function() {}\n");

    // Wait for debounce plus margin
    sleep(Duration::from_millis(800)).await;

    // old_function should be gone, new_function should appear
    assert!(
        indexer.find_symbol("old_function").is_empty(),
        "old_function should be gone after modification"
    );
    assert!(
        !indexer.find_symbol("new_function").is_empty(),
        "new_function should appear after modification"
    );
}

#[tokio::test]
async fn watcher_detects_deletion() {
    let tmp = TempDir::new().unwrap();

    write_file(&tmp, "doomed.rs", "pub fn doomed_fn() {}\n");
    write_file(&tmp, "survivor.rs", "pub fn survivor_fn() {}\n");

    let indexer = setup_with_watcher(&tmp).await;
    assert_eq!(indexer.file_count(), 2);

    // Delete one file
    std::fs::remove_file(tmp.path().join("doomed.rs")).unwrap();

    // Wait for debounce plus margin
    sleep(Duration::from_millis(800)).await;

    assert_eq!(
        indexer.file_count(),
        1,
        "file_count should decrease after deletion"
    );
    assert!(
        indexer.find_symbol("doomed_fn").is_empty(),
        "doomed_fn should be gone after file deletion"
    );
    assert!(
        !indexer.find_symbol("survivor_fn").is_empty(),
        "survivor_fn should still be indexed"
    );
}

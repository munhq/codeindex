use std::path::{Path, PathBuf};

use tempfile::TempDir;

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

/// Build a workspace with Rust, Python, and TypeScript files.
fn populate_workspace(tmp: &TempDir) {
    write_file(
        tmp,
        "src/main.rs",
        r#"
use crate::config::Settings;

pub mod config;

fn main() {
    let settings = Settings::default();
    run_server(settings);
}

pub fn run_server(settings: Settings) {
    println!("starting on port {}", settings.port);
}
"#,
    );

    write_file(
        tmp,
        "src/config.rs",
        r#"
pub struct Settings {
    pub port: u16,
    pub host: String,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            port: 8080,
            host: "localhost".to_string(),
        }
    }
}

pub fn load_config() -> Settings {
    Settings::default()
}
"#,
    );

    write_file(
        tmp,
        "scripts/deploy.py",
        r#"
import os
import subprocess

class Deployer:
    def __init__(self, target: str):
        self.target = target

    def run(self):
        subprocess.run(["cargo", "build", "--release"])

def deploy(target: str):
    d = Deployer(target)
    d.run()
"#,
    );

    write_file(
        tmp,
        "web/app.ts",
        r#"
import { Router } from 'express';

interface AppConfig {
    apiUrl: string;
    debug: boolean;
}

export function createApp(config: AppConfig): Router {
    const router = Router();
    return router;
}

export class Application {
    constructor(private config: AppConfig) {}

    start(): void {
        console.log("starting app");
    }
}
"#,
    );
}

#[tokio::test]
async fn full_scan_and_query_workflow() {
    let tmp = TempDir::new().unwrap();
    populate_workspace(&tmp);

    let indexer = CodeIndexer::builder()
        .workspace(tmp.path().to_path_buf())
        .project_id("test-project")
        .build()
        .await;

    // Scan the workspace
    let scanned = indexer.scan().await.unwrap();
    assert!(scanned >= 4, "expected at least 4 files scanned, got {scanned}");

    // File count
    assert!(
        indexer.file_count() >= 4,
        "expected at least 4 indexed files, got {}",
        indexer.file_count()
    );

    // Symbol count
    assert!(
        indexer.symbol_count() > 0,
        "expected some symbols, got {}",
        indexer.symbol_count()
    );

    // Indexing should be complete
    assert!(!indexer.is_indexing(), "indexing should be complete after scan");
}

#[tokio::test]
async fn find_symbol_across_languages() {
    let tmp = TempDir::new().unwrap();
    populate_workspace(&tmp);

    let indexer = CodeIndexer::builder()
        .workspace(tmp.path().to_path_buf())
        .build()
        .await;
    indexer.scan().await.unwrap();

    // Rust struct
    let settings = indexer.find_symbol("Settings");
    assert!(
        !settings.is_empty(),
        "expected to find 'Settings' struct"
    );

    // Python class
    let deployer = indexer.find_symbol("Deployer");
    assert!(
        !deployer.is_empty(),
        "expected to find 'Deployer' class"
    );

    // TypeScript function
    let create_app = indexer.find_symbol("createApp");
    assert!(
        !create_app.is_empty(),
        "expected to find 'createApp' function"
    );

    // Partial match
    let app_hits = indexer.find_symbol("App");
    assert!(
        app_hits.len() >= 1,
        "expected at least 1 match for 'App'"
    );
}

#[tokio::test]
async fn search_content_returns_matching_lines() {
    let tmp = TempDir::new().unwrap();
    populate_workspace(&tmp);

    let indexer = CodeIndexer::builder()
        .workspace(tmp.path().to_path_buf())
        .build()
        .await;
    indexer.scan().await.unwrap();

    // Search for a string present in main.rs
    let results = indexer.search_content("starting on port");
    assert!(
        !results.is_empty(),
        "expected content hits for 'starting on port'"
    );

    // Search for a string in Python
    let py_results = indexer.search_content("subprocess");
    assert!(
        !py_results.is_empty(),
        "expected content hits for 'subprocess'"
    );
}

#[tokio::test]
async fn find_word_returns_identifier_hits() {
    let tmp = TempDir::new().unwrap();
    populate_workspace(&tmp);

    let indexer = CodeIndexer::builder()
        .workspace(tmp.path().to_path_buf())
        .build()
        .await;
    indexer.scan().await.unwrap();

    let hits = indexer.find_word("run_server");
    assert!(
        !hits.is_empty(),
        "expected word hits for 'run_server'"
    );

    let hits = indexer.find_word("load_config");
    assert!(
        !hits.is_empty(),
        "expected word hits for 'load_config'"
    );
}

#[tokio::test]
async fn get_tree_shows_directory_hierarchy() {
    let tmp = TempDir::new().unwrap();
    populate_workspace(&tmp);

    let indexer = CodeIndexer::builder()
        .workspace(tmp.path().to_path_buf())
        .build()
        .await;
    indexer.scan().await.unwrap();

    let tree = indexer.get_tree();
    assert!(!tree.is_empty(), "tree should not be empty");

    // Collect all node names recursively
    fn collect_names(nodes: &[codeindex::models::TreeNode]) -> Vec<String> {
        let mut names = Vec::new();
        for node in nodes {
            names.push(node.name.clone());
            names.extend(collect_names(&node.children));
        }
        names
    }

    let names = collect_names(&tree);
    assert!(names.contains(&"src".to_string()), "expected 'src' dir in tree, got {names:?}");
    assert!(
        names.contains(&"scripts".to_string()),
        "expected 'scripts' dir in tree, got {names:?}"
    );
    assert!(
        names.contains(&"web".to_string()),
        "expected 'web' dir in tree, got {names:?}"
    );
}

#[tokio::test]
async fn get_outline_per_file() {
    let tmp = TempDir::new().unwrap();
    populate_workspace(&tmp);

    let indexer = CodeIndexer::builder()
        .workspace(tmp.path().to_path_buf())
        .build()
        .await;
    indexer.scan().await.unwrap();

    // Rust outline
    let rs_outline = indexer.get_outline(Path::new("src/config.rs"));
    assert!(rs_outline.is_some(), "expected outline for src/config.rs");
    let rs = rs_outline.unwrap();
    assert_eq!(rs.language, codeindex::models::Language::Rust);
    assert!(rs.symbols.len() >= 2);

    // Python outline
    let py_outline = indexer.get_outline(Path::new("scripts/deploy.py"));
    assert!(py_outline.is_some(), "expected outline for scripts/deploy.py");
    let py = py_outline.unwrap();
    assert_eq!(py.language, codeindex::models::Language::Python);

    // TypeScript outline
    let ts_outline = indexer.get_outline(Path::new("web/app.ts"));
    assert!(ts_outline.is_some(), "expected outline for web/app.ts");
    let ts = ts_outline.unwrap();
    assert_eq!(ts.language, codeindex::models::Language::TypeScript);
}

#[tokio::test]
async fn changes_since_zero_returns_all() {
    let tmp = TempDir::new().unwrap();
    populate_workspace(&tmp);

    let indexer = CodeIndexer::builder()
        .workspace(tmp.path().to_path_buf())
        .build()
        .await;
    indexer.scan().await.unwrap();

    let (changes, truncated) = indexer.changes_since(0);
    assert!(!truncated, "should not be truncated for small set");
    assert!(
        changes.len() >= 4,
        "expected at least 4 change records (one per file), got {}",
        changes.len()
    );

    // All should be Modified (index_file records Modified)
    for change in &changes {
        assert_eq!(
            change.op,
            codeindex::models::ChangeOp::Modified,
            "scan should record Modified ops"
        );
    }
}

#[tokio::test]
async fn changes_since_with_version_tracking() {
    let tmp = TempDir::new().unwrap();
    populate_workspace(&tmp);

    let indexer = CodeIndexer::builder()
        .workspace(tmp.path().to_path_buf())
        .build()
        .await;
    indexer.scan().await.unwrap();

    // Get the last recorded seq from changes_since(0).
    // changes_since returns records with seq > the given value.
    let (all_changes, _) = indexer.changes_since(0);
    assert!(
        !all_changes.is_empty(),
        "should have change records after scan"
    );
    let last_seq = all_changes.last().unwrap().seq;

    // No changes since the last recorded seq
    let (changes, truncated) = indexer.changes_since(last_seq);
    assert!(!truncated);
    assert!(
        changes.is_empty(),
        "no changes expected since last seq ({}), got {}",
        last_seq,
        changes.len()
    );

    // Add a new file, re-index it manually via the explorer
    write_file(&tmp, "src/new_module.rs", "pub fn new_thing() {}\n");
    let explorer = indexer.explorer();
    explorer
        .index_file(Path::new("src/new_module.rs"))
        .unwrap();

    // Now changes_since the old seq should return the new record
    let (changes, _) = indexer.changes_since(last_seq);
    assert_eq!(
        changes.len(),
        1,
        "expected 1 change record for the new file"
    );
    assert_eq!(
        changes[0].path,
        PathBuf::from("src/new_module.rs"),
        "change should reference the new module"
    );

    // latest_seq should have advanced
    assert!(
        indexer.latest_seq() > last_seq,
        "latest_seq should advance after indexing a new file"
    );
}

#[tokio::test]
async fn scan_background_returns_handle_and_completes() {
    let tmp = TempDir::new().unwrap();
    populate_workspace(&tmp);

    let indexer = CodeIndexer::builder()
        .workspace(tmp.path().to_path_buf())
        .project_id("bg-test")
        .build()
        .await;

    // Start background scan
    let handle = indexer.scan_background();

    // The handle should report progress (may be 0 initially)
    let _initial_files = handle.files_indexed();
    let _initial_symbols = handle.symbols_indexed();

    // Wait for completion
    let total = handle.wait().await.unwrap();
    assert!(
        total >= 4,
        "background scan should index at least 4 files, got {total}"
    );

    // After completion, queries should work
    assert!(
        indexer.file_count() >= 4,
        "file_count should reflect background scan results"
    );
    assert!(
        indexer.symbol_count() > 0,
        "symbol_count should be > 0 after background scan"
    );

    // find_symbol should work
    let settings = indexer.find_symbol("Settings");
    assert!(
        !settings.is_empty(),
        "Settings should be findable after background scan"
    );
}

#[tokio::test]
async fn get_imports_and_imported_by() {
    let tmp = TempDir::new().unwrap();

    // Create files under src/ with crate:: import statements.
    // resolve_rust_import maps "crate::models" → "src/models.rs".
    write_file(
        &tmp,
        "src/models.rs",
        "pub struct User {\n    pub name: String,\n}\n",
    );
    write_file(
        &tmp,
        "src/service.rs",
        "use crate::models;\n\npub fn get_user() -> models::User {\n    models::User { name: \"test\".to_string() }\n}\n",
    );
    write_file(
        &tmp,
        "src/handler.rs",
        "use crate::service;\nuse crate::models;\n\npub fn handle() {\n    let _u = service::get_user();\n}\n",
    );

    let indexer = CodeIndexer::builder()
        .workspace(tmp.path().to_path_buf())
        .build()
        .await;

    // Index files in dependency order: models first (no deps), then service
    // (depends on models), then handler (depends on both).
    // resolve_import only resolves against files already in the index, so
    // ordering matters.
    let explorer = indexer.explorer();
    explorer.index_file(Path::new("src/models.rs")).unwrap();
    explorer.index_file(Path::new("src/service.rs")).unwrap();
    explorer.index_file(Path::new("src/handler.rs")).unwrap();

    // service.rs imports models (resolved as "src/models.rs")
    let service_imports = indexer.get_imports(Path::new("src/service.rs"));
    assert!(
        service_imports.iter().any(|p| p.to_string_lossy().contains("models")),
        "src/service.rs should import models, got {:?}",
        service_imports
    );

    // handler.rs imports both service and models
    let handler_imports = indexer.get_imports(Path::new("src/handler.rs"));
    assert!(
        handler_imports.iter().any(|p| p.to_string_lossy().contains("service")),
        "src/handler.rs should import service, got {:?}",
        handler_imports
    );
    assert!(
        handler_imports.iter().any(|p| p.to_string_lossy().contains("models")),
        "src/handler.rs should import models, got {:?}",
        handler_imports
    );

    // Reverse: src/models.rs is imported by service.rs and handler.rs
    let importers = indexer.get_imported_by(Path::new("src/models.rs"));
    assert!(
        importers.len() >= 2,
        "src/models.rs should be imported by at least 2 files, got {:?}",
        importers
    );
}

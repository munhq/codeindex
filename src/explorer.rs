use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use parking_lot::RwLock;

#[cfg(feature = "watcher")]
use moka::sync::Cache;

use crate::config::CodeIndexerConfig;
use crate::depgraph::DepGraph;
use crate::error::CodeIndexError;
use crate::filter::FileFilter;
use crate::index::trigram::TrigramIndex;
use crate::index::word::{WordIndex, WordHit};
use crate::models::*;
use crate::parser;
use crate::version::VersionStore;

/// Central code index with per-index RwLocks for concurrent access.
///
/// Each index (outlines, trigram, word, deps, content) has its own lock
/// so readers don't contend with each other across different query types.
pub struct Explorer {
    config: Arc<CodeIndexerConfig>,
    filter: Arc<FileFilter>,

    /// File outlines (symbols, imports, metadata).
    outlines: RwLock<HashMap<PathBuf, FileOutline>>,

    /// Trigram index for content search candidate filtering.
    trigram: RwLock<TrigramIndex>,

    /// Inverted word index for O(1) identifier lookup.
    word: RwLock<WordIndex>,

    /// Dependency graph (imports → reverse deps).
    deps: RwLock<DepGraph>,

    /// Content cache with LRU eviction (feature=watcher) or simple HashMap.
    #[cfg(feature = "watcher")]
    content: Cache<PathBuf, String>,

    #[cfg(not(feature = "watcher"))]
    content: RwLock<HashMap<PathBuf, String>>,

    /// Version tracking for change notifications.
    version: VersionStore,

    /// Whether initial indexing is complete.
    indexing: RwLock<bool>,
}

impl Explorer {
    pub fn new(config: Arc<CodeIndexerConfig>) -> Self {
        let filter = Arc::new(FileFilter::new(config.clone()));

        #[cfg(feature = "watcher")]
        let content = Cache::builder()
            .max_capacity(config.max_cache_bytes as u64)
            .weigher(|_key, value: &String| value.len() as u32)
            .build();

        Self {
            config,
            filter,
            outlines: RwLock::new(HashMap::new()),
            trigram: RwLock::new(TrigramIndex::new()),
            word: RwLock::new(WordIndex::new()),
            deps: RwLock::new(DepGraph::new()),
            content,
            version: VersionStore::new(),
            indexing: RwLock::new(true),
        }
    }

    // ── Indexing ──────────────────────────────────────────────────────────────

    /// Index a single file. Parses, updates all indexes, records version.
    pub fn index_file(&self, rel_path: &Path) -> Result<(), CodeIndexError> {
        let content = self.filter.read_file(rel_path)?;
        let outline = parser::parse_file(rel_path, &content)
            .ok_or_else(|| CodeIndexError::Parse(format!("unsupported language: {:?}", rel_path)))?;

        // Resolve imports to actual indexed file paths.
        // We read the outlines lock briefly to check which paths exist.
        let import_paths: Vec<PathBuf> = {
            let outlines = self.outlines.read();
            outline
                .imports
                .iter()
                .filter_map(|imp| {
                    resolve_import(rel_path, imp, &self.config.workspace_root, &outlines)
                })
                .collect()
        };

        // Update outlines
        self.outlines.write().insert(rel_path.to_path_buf(), outline);

        // Update trigram index
        self.trigram.write().insert(rel_path, &content);

        // Update word index
        self.word.write().insert(rel_path, &content);

        // Update dependency graph
        self.deps.write().record_imports(rel_path.to_path_buf(), import_paths);

        // Update content cache
        #[cfg(feature = "watcher")]
        self.content.insert(rel_path.to_path_buf(), content.clone());

        #[cfg(not(feature = "watcher"))]
        self.content.write().insert(rel_path.to_path_buf(), content);

        // Record version
        self.version.record(rel_path.to_path_buf(), ChangeOp::Modified);

        Ok(())
    }

    /// Remove a file from all indexes.
    pub fn remove_file(&self, rel_path: &Path) {
        self.outlines.write().remove(rel_path);
        self.trigram.write().remove(rel_path);
        self.word.write().remove(rel_path);
        self.deps.write().remove(rel_path);

        #[cfg(feature = "watcher")]
        self.content.invalidate(rel_path);

        #[cfg(not(feature = "watcher"))]
        self.content.write().remove(rel_path);

        self.version.record(rel_path.to_path_buf(), ChangeOp::Deleted);
    }

    /// Mark indexing as complete.
    pub fn mark_indexing_complete(&self) {
        *self.indexing.write() = false;
    }

    /// Check if indexing is still in progress.
    pub fn is_indexing(&self) -> bool {
        *self.indexing.read()
    }

    // ── Queries ───────────────────────────────────────────────────────────────

    /// Get the file outline (symbols, imports, metadata) for a path.
    pub fn get_outline(&self, rel_path: &Path) -> Option<FileOutline> {
        self.outlines.read().get(rel_path).cloned()
    }

    /// Get all outlines.
    pub fn get_all_outlines(&self) -> HashMap<PathBuf, FileOutline> {
        self.outlines.read().clone()
    }

    /// Find symbol definitions by name across all indexed files.
    pub fn find_symbol(&self, name: &str) -> Vec<SymbolResult> {
        let outlines = self.outlines.read();
        let mut results = Vec::new();

        for (path, outline) in outlines.iter() {
            for symbol in &outline.symbols {
                if symbol.name.contains(name) {
                    results.push(SymbolResult {
                        path: path.clone(),
                        symbol: symbol.clone(),
                    });
                }
            }
        }

        results
    }

    /// Search file contents using trigram-accelerated candidate filtering.
    /// Returns matching lines with optional symbol scope.
    pub fn search_content(&self, query: &str) -> Vec<ScopedSearchResult> {
        let candidates = self.trigram.read().search(query);
        let outlines = self.outlines.read();
        let mut results = Vec::new();

        #[cfg(not(feature = "watcher"))]
        let content_map = self.content.read();

        for path_str in &candidates {
            let path = PathBuf::from(path_str);

            // Get content
            #[cfg(feature = "watcher")]
            let content: String = match self.content.get(&path) {
                Some(c) => c,
                None => continue,
            };

            #[cfg(not(feature = "watcher"))]
            let content = match content_map.get(&path) {
                Some(c) => c.clone(),
                None => continue,
            };

            // Find matching lines
            let query_lower = query.to_lowercase();
            for (idx, line) in content.lines().enumerate() {
                if line.to_lowercase().contains(&query_lower) {
                    // Find enclosing symbol scope
                    let (scope_name, scope_kind) = find_scope(&outlines, &path, idx + 1);

                    results.push(ScopedSearchResult {
                        path: path.clone(),
                        line_num: idx + 1,
                        line_text: line.to_string(),
                        scope_name,
                        scope_kind,
                    });
                }
            }
        }

        results
    }

    /// Search for a word/identifier in the inverted index. O(1) lookup.
    pub fn find_word(&self, word: &str) -> Vec<WordHit> {
        self.word.read().search(word)
    }

    /// Get the directory tree with symbol counts.
    pub fn get_tree(&self) -> Vec<TreeNode> {
        let outlines = self.outlines.read();
        let mut nodes: HashMap<PathBuf, TreeNode> = HashMap::new();

        // Add all files
        for (path, outline) in outlines.iter() {
            let mut components = path.components();
            let name = components
                .next_back()
                .map(|c| c.as_os_str().to_string_lossy().to_string())
                .unwrap_or_default();

            nodes.insert(
                path.clone(),
                TreeNode {
                    name,
                    path: path.clone(),
                    is_dir: false,
                    children: Vec::new(),
                    symbol_count: Some(outline.symbols.len()),
                    language: Some(outline.language),
                    line_count: Some(outline.line_count),
                },
            );
        }

        // Build directory nodes
        for path in outlines.keys() {
            let mut current = PathBuf::new();
            for component in path.components() {
                current.push(component);
                if !nodes.contains_key(&current) {
                    let name = component.as_os_str().to_string_lossy().to_string();
                    nodes.insert(
                        current.clone(),
                        TreeNode {
                            name,
                            path: current.clone(),
                            is_dir: true,
                            children: Vec::new(),
                            symbol_count: None,
                            language: None,
                            line_count: None,
                        },
                    );
                }
            }
        }

        // Build hierarchy bottom-up: deepest paths first so children are
        // fully populated before being moved into their parent.
        let mut sorted_paths: Vec<_> = nodes.keys().cloned().collect();
        sorted_paths.sort();
        sorted_paths.reverse(); // deepest first

        for path in &sorted_paths {
            let parent = match path.parent() {
                Some(p) if p != Path::new("") => p.to_path_buf(),
                _ => continue, // root node, skip
            };
            if let Some(node) = nodes.remove(path) {
                if let Some(parent_node) = nodes.get_mut(&parent) {
                    parent_node.children.push(node);
                }
            }
        }

        // Sort children within each node for stable output
        fn sort_children(node: &mut TreeNode) {
            node.children.sort_by(|a, b| {
                // dirs first, then by name
                b.is_dir.cmp(&a.is_dir).then(a.name.cmp(&b.name))
            });
            for child in &mut node.children {
                sort_children(child);
            }
        }

        // Collect roots (everything still in the map)
        let mut roots: Vec<TreeNode> = nodes.drain().map(|(_, v)| v).collect();
        for root in &mut roots {
            sort_children(root);
        }
        roots.sort_by(|a, b| b.is_dir.cmp(&a.is_dir).then(a.name.cmp(&b.name)));
        roots
    }

    /// Get reverse dependencies: which files import this file?
    pub fn get_imported_by(&self, path: &Path) -> Vec<PathBuf> {
        self.deps.read().get_imported_by(path)
    }

    /// Get forward dependencies: which files does this file import?
    pub fn get_imports(&self, path: &Path) -> Vec<PathBuf> {
        self.deps.read().get_imports(path)
    }

    /// Get recently changed files, sorted by change sequence (newest first).
    pub fn get_hot_files(&self, limit: usize) -> Vec<(PathBuf, ChangeRecord)> {
        let (changes, _) = self.version.changes_since(0);
        let mut changes: Vec<_> = changes
            .into_iter()
            .filter(|c| matches!(c.op, ChangeOp::Added | ChangeOp::Modified))
            .collect();
        changes.sort_by(|a, b| b.seq.cmp(&a.seq));
        changes
            .into_iter()
            .take(limit)
            .map(|c| (c.path.clone(), c))
            .collect()
    }

    /// Get changes since a sequence number.
    pub fn changes_since(&self, seq: u64) -> (Vec<ChangeRecord>, bool) {
        self.version.changes_since(seq)
    }

    /// Get the latest sequence number.
    pub fn latest_seq(&self) -> u64 {
        self.version.latest_seq()
    }

    /// Get the number of indexed files.
    pub fn file_count(&self) -> usize {
        self.outlines.read().len()
    }

    /// Get the total symbol count across all files.
    pub fn symbol_count(&self) -> usize {
        self.outlines.read().values().map(|o| o.symbols.len()).sum()
    }

    /// Get the file filter for external use.
    pub fn filter(&self) -> &Arc<FileFilter> {
        &self.filter
    }

    /// Get the config for external use.
    pub fn config(&self) -> &Arc<CodeIndexerConfig> {
        &self.config
    }
}

/// Find the enclosing symbol scope for a given line in a file.
fn find_scope(
    outlines: &HashMap<PathBuf, FileOutline>,
    path: &Path,
    line_num: usize,
) -> (Option<String>, Option<SymbolKind>) {
    let outline = match outlines.get(path) {
        Some(o) => o,
        None => return (None, None),
    };

    let mut best: Option<&Symbol> = None;
    for symbol in &outline.symbols {
        if symbol.line_start <= line_num
            && symbol.line_end >= line_num
            && matches!(
                symbol.kind,
                SymbolKind::Function
                    | SymbolKind::Method
                    | SymbolKind::Struct
                    | SymbolKind::Enum
                    | SymbolKind::Class
                    | SymbolKind::Trait
                    | SymbolKind::Interface
                    | SymbolKind::Impl
            )
        {
            if best.is_none() || symbol.line_start > best.unwrap().line_start {
                best = Some(symbol);
            }
        }
    }

    best.map(|s| (Some(s.name.clone()), Some(s.kind)))
        .unwrap_or((None, None))
}

/// Resolve an import string to a file path relative to workspace.
///
/// Returns `Some(path)` only if the resolved path exists in the indexed files.
/// Handles Rust (`use crate::`, `use super::`, `use self::`), TypeScript
/// (`import ... from "./foo"`), Python (`from .utils import X`), and Go
/// (`"github.com/user/repo/internal/market"`).
fn resolve_import(
    source: &Path,
    import: &str,
    workspace: &Path,
    outlines: &HashMap<PathBuf, FileOutline>,
) -> Option<PathBuf> {
    let language = crate::models::Language::from_path(source);

    match language {
        crate::models::Language::Rust => {
            let candidates = resolve_rust_import(source, import);
            candidates.into_iter().find(|c| outlines.contains_key(c))
        }
        crate::models::Language::TypeScript | crate::models::Language::JavaScript => {
            let candidates = resolve_ts_import(source, import);
            candidates.into_iter().find(|c| outlines.contains_key(c))
        }
        crate::models::Language::Python => {
            let candidates = resolve_python_import(source, import);
            candidates.into_iter().find(|c| outlines.contains_key(c))
        }
        crate::models::Language::Go => {
            resolve_go_import(import, workspace, outlines)
        }
        _ => None,
    }
}

/// Resolve a Rust `use` path to candidate file paths.
fn resolve_rust_import(source: &Path, import: &str) -> Vec<PathBuf> {
    // Strip `use ` prefix if present
    let raw = import.trim_start_matches("use ");

    // Strip `::{...}` suffixes and `as ...` aliases
    let raw = if let Some(idx) = raw.find("::{") {
        &raw[..idx]
    } else {
        raw
    };
    let raw = if let Some(idx) = raw.find(" as ") {
        &raw[..idx]
    } else {
        raw
    };
    let raw = raw.trim_end_matches(';').trim();

    if raw.starts_with("crate::") {
        // use crate::channels::manifest → src/channels/manifest.rs or src/channels/manifest/mod.rs
        let module_path = raw.trim_start_matches("crate::");
        let segments = module_path.replace("::", "/");
        let base = PathBuf::from("src").join(&segments);
        vec![
            base.with_extension("rs"),
            base.join("mod.rs"),
        ]
    } else if raw.starts_with("super::") {
        // use super::traits → relative to parent of current file's directory
        let module_path = raw.trim_start_matches("super::");
        if let Some(parent) = source.parent().and_then(|p| p.parent()) {
            let segments = module_path.replace("::", "/");
            let base = parent.join(&segments);
            vec![
                base.with_extension("rs"),
                base.join("mod.rs"),
            ]
        } else {
            vec![]
        }
    } else if raw.starts_with("self::") {
        // use self::utils → relative to current file's directory
        let module_path = raw.trim_start_matches("self::");
        if let Some(parent) = source.parent() {
            let segments = module_path.replace("::", "/");
            let base = parent.join(&segments);
            vec![
                base.with_extension("rs"),
                base.join("mod.rs"),
            ]
        } else {
            vec![]
        }
    } else if raw.starts_with("std::") || raw.starts_with("core::") || raw.starts_with("alloc::") {
        // Skip standard library imports
        vec![]
    } else {
        // External crate or bare path — try src/ prefix as fallback
        let segments = raw.replace("::", "/");
        let base = PathBuf::from("src").join(&segments);
        vec![
            base.with_extension("rs"),
            base.join("mod.rs"),
            PathBuf::from(&segments).with_extension("rs"),
        ]
    }
}

/// Resolve a TypeScript/JavaScript import path to candidate file paths.
fn resolve_ts_import(source: &Path, import: &str) -> Vec<PathBuf> {
    let import = import.trim().trim_matches('"').trim_matches('\'');

    // Skip external packages (no ./ or ../ prefix, no path separators for bare specifiers)
    if !import.starts_with('.') {
        return vec![];
    }

    let parent = match source.parent() {
        Some(p) => p,
        None => return vec![],
    };

    let resolved = normalize_path(&parent.join(import));

    // Try extensions: .ts, .tsx, .js, .jsx, and /index.ts, /index.tsx
    vec![
        resolved.with_extension("ts"),
        resolved.with_extension("tsx"),
        resolved.with_extension("js"),
        resolved.with_extension("jsx"),
        resolved.join("index.ts"),
        resolved.join("index.tsx"),
        resolved.join("index.js"),
        resolved.clone(),
    ]
}

/// Resolve a Python import to candidate file paths.
fn resolve_python_import(source: &Path, import: &str) -> Vec<PathBuf> {
    // Handle "from .utils import X" format
    if import.starts_with("from ") {
        let rest = import.trim_start_matches("from ").trim();
        let module_part = rest.split(" import ").next().unwrap_or("").trim();

        if module_part.starts_with('.') {
            // Relative import
            let dots = module_part.chars().take_while(|c| *c == '.').count();
            let module_name = &module_part[dots..];

            let mut base = source.parent().unwrap_or(Path::new("")).to_path_buf();
            // Each extra dot goes up one directory (first dot = current package)
            for _ in 1..dots {
                base = base.parent().unwrap_or(Path::new("")).to_path_buf();
            }

            if module_name.is_empty() {
                return vec![base.join("__init__.py")];
            }

            let segments = module_name.replace('.', "/");
            let resolved = base.join(&segments);
            return vec![
                resolved.with_extension("py"),
                resolved.join("__init__.py"),
            ];
        }

        // Absolute import — skip if it looks like a stdlib/third-party module
        let top_module = module_part.split('.').next().unwrap_or("");
        if is_python_stdlib(top_module) {
            return vec![];
        }

        let segments = module_part.replace('.', "/");
        return vec![
            PathBuf::from(&segments).with_extension("py"),
            PathBuf::from(&segments).join("__init__.py"),
        ];
    }

    // Handle "import os" / "import foo.bar"
    let module = import.trim();
    let top_module = module.split('.').next().unwrap_or("");
    if is_python_stdlib(top_module) {
        return vec![];
    }

    let segments = module.replace('.', "/");
    vec![
        PathBuf::from(&segments).with_extension("py"),
        PathBuf::from(&segments).join("__init__.py"),
    ]
}

/// Resolve a Go import path to an indexed file.
///
/// Go imports are package paths like `"github.com/user/repo/internal/market"`.
/// If the import starts with the module path from go.mod, we strip the module
/// prefix and look for any `.go` file in the resulting directory that's already
/// indexed. Standard library imports (no `.` in the first path segment) are
/// skipped.
fn resolve_go_import(
    import: &str,
    workspace: &Path,
    outlines: &HashMap<PathBuf, FileOutline>,
) -> Option<PathBuf> {
    let import = import.trim().trim_matches('"');

    // Standard library: first segment has no dot (e.g. "fmt", "net/http", "context")
    let first_segment = import.split('/').next().unwrap_or("");
    if !first_segment.contains('.') {
        return None;
    }

    // Read go.mod to get module path (cached via lazy reading of the file)
    let go_mod_path = workspace.join("go.mod");
    let module_path = read_go_module_path(&go_mod_path)?;

    // Only resolve imports that belong to this module
    let relative = import.strip_prefix(module_path.as_str())?;
    let relative = relative.strip_prefix('/').unwrap_or(relative);

    if relative.is_empty() {
        return None;
    }

    // The relative path is a package directory — find any indexed .go file in it
    let pkg_dir = PathBuf::from(relative);
    outlines
        .keys()
        .find(|path| {
            path.extension().and_then(|e| e.to_str()) == Some("go")
                && path.parent() == Some(pkg_dir.as_path())
        })
        .cloned()
}

/// Read the `module` line from go.mod and return the module path.
fn read_go_module_path(go_mod_path: &Path) -> Option<String> {
    let content = std::fs::read_to_string(go_mod_path).ok()?;
    for line in content.lines() {
        let line = line.trim();
        if let Some(rest) = line.strip_prefix("module ") {
            return Some(rest.trim().to_string());
        }
    }
    None
}

/// Check if a module name is likely Python stdlib.
fn is_python_stdlib(name: &str) -> bool {
    const STDLIB: &[&str] = &[
        "os", "sys", "re", "io", "abc", "ast", "csv", "dis", "dis",
        "gc", "math", "json", "http", "html", "time", "uuid", "copy",
        "enum", "glob", "gzip", "heapq", "hmac", "imp", "inspect",
        "itertools", "functools", "collections", "contextlib", "dataclasses",
        "datetime", "decimal", "difflib", "email", "errno", "hashlib",
        "logging", "multiprocessing", "operator", "pathlib", "pickle",
        "platform", "pprint", "queue", "random", "shutil", "signal",
        "socket", "sqlite3", "ssl", "string", "struct", "subprocess",
        "tempfile", "textwrap", "threading", "traceback", "typing",
        "unittest", "urllib", "warnings", "weakref", "xml", "zipfile",
        "argparse", "base64", "binascii", "builtins", "codecs",
        "concurrent", "configparser", "ctypes", "importlib",
    ];
    STDLIB.contains(&name)
}

/// Normalize a path by resolving `..` and `.` components (without filesystem access).
fn normalize_path(path: &Path) -> PathBuf {
    let mut components = Vec::new();
    for component in path.components() {
        match component {
            std::path::Component::ParentDir => {
                components.pop();
            }
            std::path::Component::CurDir => {}
            other => components.push(other),
        }
    }
    components.iter().collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::Path;
    use std::sync::Arc;
    use tempfile::TempDir;

    use crate::config::CodeIndexerConfig;
    use crate::models::{ChangeOp, SymbolKind};

    /// Create an Explorer backed by a real temp directory.
    fn setup(tmp: &TempDir) -> Explorer {
        let config = CodeIndexerConfig {
            workspace_root: tmp.path().to_path_buf(),
            ..Default::default()
        };
        Explorer::new(Arc::new(config))
    }

    /// Write a file inside the temp dir and return its relative path.
    fn write_file(tmp: &TempDir, rel: &str, content: &str) -> PathBuf {
        let full = tmp.path().join(rel);
        if let Some(parent) = full.parent() {
            fs::create_dir_all(parent).unwrap();
        }
        fs::write(&full, content).unwrap();
        PathBuf::from(rel)
    }

    // ── index_file + get_outline ─────────────────────────────────────────────

    #[test]
    fn index_file_and_get_outline() {
        let tmp = TempDir::new().unwrap();
        let explorer = setup(&tmp);

        let rel = write_file(
            &tmp,
            "lib.rs",
            r#"
pub struct Config {
    pub name: String,
}

pub fn create_config() -> Config {
    Config { name: String::new() }
}
"#,
        );

        explorer.index_file(&rel).unwrap();

        let outline = explorer.get_outline(&rel).expect("outline should exist");
        assert_eq!(outline.language, crate::models::Language::Rust);
        assert!(outline.symbols.len() >= 2, "expected struct + fn, got {:?}", outline.symbols);

        let names: Vec<&str> = outline.symbols.iter().map(|s| s.name.as_str()).collect();
        assert!(names.contains(&"Config"), "missing Config in {names:?}");
        assert!(names.contains(&"create_config"), "missing create_config in {names:?}");
    }

    // ── remove_file ──────────────────────────────────────────────────────────

    #[test]
    fn remove_file_clears_all_indexes() {
        let tmp = TempDir::new().unwrap();
        let explorer = setup(&tmp);

        let rel = write_file(&tmp, "remove_me.rs", "pub fn hello() {}\n");
        explorer.index_file(&rel).unwrap();
        assert_eq!(explorer.file_count(), 1);

        explorer.remove_file(&rel);
        assert_eq!(explorer.file_count(), 0);
        assert!(explorer.get_outline(&rel).is_none());
        assert!(explorer.find_symbol("hello").is_empty());
        assert!(explorer.search_content("hello").is_empty());
    }

    // ── find_symbol ──────────────────────────────────────────────────────────

    #[test]
    fn find_symbol_matches_structs_and_functions() {
        let tmp = TempDir::new().unwrap();
        let explorer = setup(&tmp);

        write_file(
            &tmp,
            "types.rs",
            r#"
pub struct MyWidget {
    pub id: u32,
}

pub enum Color {
    Red,
    Green,
    Blue,
}

pub fn build_widget(id: u32) -> MyWidget {
    MyWidget { id }
}
"#,
        );
        explorer.index_file(Path::new("types.rs")).unwrap();

        let results = explorer.find_symbol("Widget");
        assert!(
            results.iter().any(|r| r.symbol.name == "MyWidget"),
            "expected MyWidget in find_symbol results"
        );

        // "build_widget" has lowercase 'w' — find_symbol is case-sensitive contains
        let fn_results = explorer.find_symbol("build_widget");
        assert!(
            fn_results.iter().any(|r| r.symbol.name == "build_widget"),
            "expected build_widget in find_symbol results"
        );

        let colors = explorer.find_symbol("Color");
        assert!(
            colors.iter().any(|r| r.symbol.kind == SymbolKind::Enum),
            "expected Color enum"
        );
    }

    // ── search_content ───────────────────────────────────────────────────────

    #[test]
    fn search_content_finds_matching_lines() {
        let tmp = TempDir::new().unwrap();
        let explorer = setup(&tmp);

        let rel = write_file(
            &tmp,
            "search_me.rs",
            r#"
// This module handles authentication
pub fn authenticate(token: &str) -> bool {
    token == "secret"
}
"#,
        );
        explorer.index_file(&rel).unwrap();

        let results = explorer.search_content("authentication");
        assert!(
            !results.is_empty(),
            "expected at least one hit for 'authentication'"
        );
        assert!(results[0].line_text.contains("authentication"));
    }

    // ── find_word ────────────────────────────────────────────────────────────

    #[test]
    fn find_word_looks_up_identifiers() {
        let tmp = TempDir::new().unwrap();
        let explorer = setup(&tmp);

        let rel = write_file(
            &tmp,
            "words.rs",
            r#"
pub fn calculate_checksum(data: &[u8]) -> u32 {
    let mut checksum: u32 = 0;
    for byte in data {
        checksum = checksum.wrapping_add(*byte as u32);
    }
    checksum
}
"#,
        );
        explorer.index_file(&rel).unwrap();

        let hits = explorer.find_word("calculate_checksum");
        assert!(
            !hits.is_empty(),
            "expected word index hits for 'calculate_checksum'"
        );
        assert!(hits.iter().any(|h| h.path.contains("words.rs")));
    }

    // ── get_tree ─────────────────────────────────────────────────────────────

    #[test]
    fn get_tree_builds_hierarchy() {
        let tmp = TempDir::new().unwrap();
        let explorer = setup(&tmp);

        write_file(&tmp, "src/main.rs", "fn main() {}\n");
        write_file(&tmp, "src/lib.rs", "pub mod util;\n");
        write_file(&tmp, "src/util/helpers.rs", "pub fn help() {}\n");

        explorer.index_file(Path::new("src/main.rs")).unwrap();
        explorer.index_file(Path::new("src/lib.rs")).unwrap();
        explorer.index_file(Path::new("src/util/helpers.rs")).unwrap();

        let tree = explorer.get_tree();
        assert!(!tree.is_empty(), "tree should have root nodes");

        // The root should be "src" directory
        let src_node = tree.iter().find(|n| n.name == "src");
        assert!(src_node.is_some(), "expected 'src' directory node in tree");

        let src = src_node.unwrap();
        assert!(src.is_dir);
        assert!(src.children.len() >= 2, "src should have at least main.rs, lib.rs, and util/");
    }

    // ── get_imported_by ──────────────────────────────────────────────────────

    #[test]
    fn get_imported_by_tracks_reverse_deps() {
        let tmp = TempDir::new().unwrap();
        let explorer = setup(&tmp);

        // File A imports File B via `use` statement.
        // crate::models resolves to src/models.rs
        write_file(&tmp, "src/models.rs", "pub struct Model {}\n");
        write_file(
            &tmp,
            "src/service.rs",
            "use crate::models;\npub fn serve() {}\n",
        );

        explorer.index_file(Path::new("src/models.rs")).unwrap();
        explorer.index_file(Path::new("src/service.rs")).unwrap();

        // crate::models → src/models.rs
        let importers = explorer.get_imported_by(Path::new("src/models.rs"));
        assert!(
            !importers.is_empty(),
            "service.rs should show up as importing src/models.rs, reverse deps: {:?}",
            importers
        );
    }

    // ── get_hot_files ────────────────────────────────────────────────────────

    #[test]
    fn get_hot_files_returns_recently_indexed() {
        let tmp = TempDir::new().unwrap();
        let explorer = setup(&tmp);

        write_file(&tmp, "a.rs", "pub fn a() {}\n");
        write_file(&tmp, "b.rs", "pub fn b() {}\n");

        explorer.index_file(Path::new("a.rs")).unwrap();
        explorer.index_file(Path::new("b.rs")).unwrap();

        let hot = explorer.get_hot_files(10);
        assert_eq!(hot.len(), 2);

        // Most recent first — b.rs was indexed after a.rs
        assert_eq!(hot[0].0, PathBuf::from("b.rs"));
        assert_eq!(hot[1].0, PathBuf::from("a.rs"));
    }

    // ── changes_since ────────────────────────────────────────────────────────

    #[test]
    fn changes_since_tracks_all_mutations() {
        let tmp = TempDir::new().unwrap();
        let explorer = setup(&tmp);

        write_file(&tmp, "versioned.rs", "pub fn v1() {}\n");
        explorer.index_file(Path::new("versioned.rs")).unwrap();

        // Get the seq of the first change record
        let (first_changes, _) = explorer.changes_since(0);
        assert_eq!(first_changes.len(), 1);
        let first_seq = first_changes[0].seq;

        // Modify the file
        write_file(&tmp, "versioned.rs", "pub fn v2() {}\n");
        explorer.index_file(Path::new("versioned.rs")).unwrap();

        let (changes, truncated) = explorer.changes_since(0);
        assert!(!truncated);
        assert_eq!(changes.len(), 2, "expected 2 change records");

        // All changes should be for versioned.rs
        assert!(changes.iter().all(|c| c.path == PathBuf::from("versioned.rs")));

        // Changes since the first record should only include the second
        let (recent, _) = explorer.changes_since(first_seq);
        assert_eq!(recent.len(), 1, "expected 1 change since first indexing");
    }

    // ── file_count and symbol_count ──────────────────────────────────────────

    #[test]
    fn file_count_and_symbol_count() {
        let tmp = TempDir::new().unwrap();
        let explorer = setup(&tmp);

        assert_eq!(explorer.file_count(), 0);
        assert_eq!(explorer.symbol_count(), 0);

        write_file(
            &tmp,
            "counters.rs",
            r#"
pub struct Alpha {}
pub struct Beta {}
pub fn gamma() {}
"#,
        );
        explorer.index_file(Path::new("counters.rs")).unwrap();

        assert_eq!(explorer.file_count(), 1);
        assert!(
            explorer.symbol_count() >= 3,
            "expected at least 3 symbols, got {}",
            explorer.symbol_count()
        );

        write_file(&tmp, "extra.rs", "pub fn delta() {}\n");
        explorer.index_file(Path::new("extra.rs")).unwrap();

        assert_eq!(explorer.file_count(), 2);
        assert!(explorer.symbol_count() >= 4);
    }

    // ── remove tracks deletion in version store ──────────────────────────────

    #[test]
    fn remove_records_deletion_change() {
        let tmp = TempDir::new().unwrap();
        let explorer = setup(&tmp);

        let rel = write_file(&tmp, "doomed.rs", "pub fn doomed() {}\n");
        explorer.index_file(&rel).unwrap();

        // Get the seq of the index record so we can query past it
        let (idx_changes, _) = explorer.changes_since(0);
        let idx_seq = idx_changes.last().unwrap().seq;

        explorer.remove_file(&rel);

        let (changes, _) = explorer.changes_since(idx_seq);
        assert_eq!(changes.len(), 1);
        assert_eq!(changes[0].op, ChangeOp::Deleted);
    }

    // ── Python file indexing ─────────────────────────────────────────────────

    #[test]
    fn indexes_python_file() {
        let tmp = TempDir::new().unwrap();
        let explorer = setup(&tmp);

        let rel = write_file(
            &tmp,
            "app.py",
            r#"
import os

class Server:
    def __init__(self):
        self.running = False

    def start(self):
        self.running = True

def create_server():
    return Server()
"#,
        );
        explorer.index_file(&rel).unwrap();

        let outline = explorer.get_outline(&rel).unwrap();
        assert_eq!(outline.language, crate::models::Language::Python);

        let names: Vec<&str> = outline.symbols.iter().map(|s| s.name.as_str()).collect();
        assert!(names.contains(&"Server"), "missing Server class in {names:?}");
        assert!(
            names.contains(&"create_server"),
            "missing create_server in {names:?}"
        );
    }

    // ── TypeScript file indexing ─────────────────────────────────────────────

    #[test]
    fn indexes_typescript_file() {
        let tmp = TempDir::new().unwrap();
        let explorer = setup(&tmp);

        let rel = write_file(
            &tmp,
            "service.ts",
            r#"
import { Request } from 'express';

interface Config {
    port: number;
    host: string;
}

export function startServer(config: Config): void {
    console.log(`Listening on ${config.host}:${config.port}`);
}

export class AppService {
    constructor(private config: Config) {}
}
"#,
        );
        explorer.index_file(&rel).unwrap();

        let outline = explorer.get_outline(&rel).unwrap();
        assert_eq!(outline.language, crate::models::Language::TypeScript);

        let sym_names: Vec<&str> = outline.symbols.iter().map(|s| s.name.as_str()).collect();
        assert!(
            sym_names.contains(&"startServer"),
            "missing startServer in {sym_names:?}"
        );
    }

    // ── Go import resolution ────────────────────────────────────────────────

    #[test]
    fn resolve_go_import_strips_module_prefix() {
        let tmp = TempDir::new().unwrap();
        let explorer = setup(&tmp);

        // Create go.mod
        write_file(
            &tmp,
            "go.mod",
            "module github.com/adi/myapp\n\ngo 1.21\n",
        );

        // Create a package file
        write_file(
            &tmp,
            "internal/market/client.go",
            "package market\n\nfunc NewClient() {}\n",
        );

        // Create the importing file
        write_file(
            &tmp,
            "cmd/main.go",
            r#"package main

import (
    "fmt"
    "github.com/adi/myapp/internal/market"
)

func main() {
    fmt.Println("hello")
    market.NewClient()
}
"#,
        );

        // Index both files
        explorer.index_file(Path::new("internal/market/client.go")).unwrap();
        explorer.index_file(Path::new("cmd/main.go")).unwrap();

        // Check that the dep graph links cmd/main.go -> internal/market/client.go
        let imports = explorer.get_imports(Path::new("cmd/main.go"));
        assert!(
            imports.contains(&PathBuf::from("internal/market/client.go")),
            "expected Go import resolution to link to internal/market/client.go, got: {:?}",
            imports
        );

        // Check reverse: who imports internal/market/client.go?
        let importers = explorer.get_imported_by(Path::new("internal/market/client.go"));
        assert!(
            importers.contains(&PathBuf::from("cmd/main.go")),
            "expected cmd/main.go to show up as importer, got: {:?}",
            importers
        );
    }

    #[test]
    fn resolve_go_import_skips_stdlib() {
        let tmp = TempDir::new().unwrap();
        let explorer = setup(&tmp);

        write_file(
            &tmp,
            "go.mod",
            "module github.com/adi/myapp\n\ngo 1.21\n",
        );

        write_file(
            &tmp,
            "main.go",
            r#"package main

import (
    "fmt"
    "net/http"
    "context"
)

func main() {}
"#,
        );

        explorer.index_file(Path::new("main.go")).unwrap();

        // stdlib imports should not create any deps
        let imports = explorer.get_imports(Path::new("main.go"));
        assert!(
            imports.is_empty(),
            "stdlib imports should not resolve, got: {:?}",
            imports
        );
    }
}

use std::collections::HashSet;
use std::path::{Path, PathBuf};

use ahash::AHashMap;

/// Dependency graph tracking imports between files.
///
/// Maps each file to the set of files it imports, and provides
/// reverse-lookup: "which files import this file?"
///
/// Not thread-safe — caller must hold appropriate locks.
pub struct DepGraph {
    /// path -> set of imported paths
    imports: AHashMap<PathBuf, HashSet<PathBuf>>,
    /// path -> set of files that import it (reverse index)
    imported_by: AHashMap<PathBuf, HashSet<PathBuf>>,
}

impl DepGraph {
    pub fn new() -> Self {
        Self {
            imports: AHashMap::new(),
            imported_by: AHashMap::new(),
        }
    }

    /// Record the imports for a file. Replaces any previous imports for this path.
    pub fn record_imports(&mut self, path: PathBuf, import_paths: Vec<PathBuf>) {
        // Remove old reverse entries
        if let Some(old) = self.imports.remove(&path) {
            for old_import in old {
                if let Some(importers) = self.imported_by.get_mut(&old_import) {
                    importers.remove(&path);
                    if importers.is_empty() {
                        self.imported_by.remove(&old_import);
                    }
                }
            }
        }

        // Add new entries
        for import_path in &import_paths {
            self.imported_by
                .entry(import_path.clone())
                .or_default()
                .insert(path.clone());
        }

        self.imports
            .insert(path, import_paths.into_iter().collect());
    }

    /// Get the files that a given file imports.
    pub fn get_imports(&self, path: &Path) -> Vec<PathBuf> {
        self.imports
            .get(path)
            .map(|s| s.iter().cloned().collect())
            .unwrap_or_default()
    }

    /// Get the files that import the given file (reverse dependencies).
    pub fn get_imported_by(&self, path: &Path) -> Vec<PathBuf> {
        self.imported_by
            .get(path)
            .map(|s| s.iter().cloned().collect())
            .unwrap_or_default()
    }

    /// Remove all dependency records for a file.
    pub fn remove(&mut self, path: &Path) {
        if let Some(imported) = self.imports.remove(path) {
            for import_path in imported {
                if let Some(importers) = self.imported_by.get_mut(&import_path) {
                    importers.remove(path);
                    if importers.is_empty() {
                        self.imported_by.remove(&import_path);
                    }
                }
            }
        }

        // Also remove from reverse index if other files import this one
        self.imported_by.remove(path);
    }

    /// Get the total number of tracked files.
    pub fn file_count(&self) -> usize {
        self.imports.len()
    }

    /// Get the total number of dependency edges.
    pub fn edge_count(&self) -> usize {
        self.imports.values().map(|s| s.len()).sum()
    }
}

impl Default for DepGraph {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn record_and_query_imports() {
        let mut graph = DepGraph::new();
        graph.record_imports(
            PathBuf::from("main.rs"),
            vec![PathBuf::from("utils.rs"), PathBuf::from("models.rs")],
        );

        let imports = graph.get_imports(Path::new("main.rs"));
        assert_eq!(imports.len(), 2);

        let imported_by = graph.get_imported_by(Path::new("utils.rs"));
        assert_eq!(imported_by.len(), 1);
        assert_eq!(imported_by[0], PathBuf::from("main.rs"));
    }

    #[test]
    fn reverse_deps_multiple_importers() {
        let mut graph = DepGraph::new();
        graph.record_imports(PathBuf::from("a.rs"), vec![PathBuf::from("shared.rs")]);
        graph.record_imports(PathBuf::from("b.rs"), vec![PathBuf::from("shared.rs")]);

        let imported_by = graph.get_imported_by(Path::new("shared.rs"));
        assert_eq!(imported_by.len(), 2);
    }

    #[test]
    fn replace_imports() {
        let mut graph = DepGraph::new();
        graph.record_imports(PathBuf::from("main.rs"), vec![PathBuf::from("old.rs")]);
        graph.record_imports(PathBuf::from("main.rs"), vec![PathBuf::from("new.rs")]);

        let imports = graph.get_imports(Path::new("main.rs"));
        assert_eq!(imports.len(), 1);
        assert_eq!(imports[0], PathBuf::from("new.rs"));

        // old.rs should no longer have main.rs as importer
        let imported_by = graph.get_imported_by(Path::new("old.rs"));
        assert!(imported_by.is_empty());
    }

    #[test]
    fn remove_file() {
        let mut graph = DepGraph::new();
        graph.record_imports(PathBuf::from("main.rs"), vec![PathBuf::from("utils.rs")]);

        graph.remove(Path::new("main.rs"));
        assert!(graph.get_imports(Path::new("main.rs")).is_empty());
        assert!(graph.get_imported_by(Path::new("utils.rs")).is_empty());
    }

    #[test]
    fn empty_queries() {
        let graph = DepGraph::new();
        assert!(graph.get_imports(Path::new("nonexistent.rs")).is_empty());
        assert!(graph
            .get_imported_by(Path::new("nonexistent.rs"))
            .is_empty());
    }
}

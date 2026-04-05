pub mod analysis;
pub mod config;
pub mod depgraph;
pub mod edits;
pub mod error;
pub mod explorer;
pub mod filter;
pub mod index;
pub mod locking;
pub mod models;
pub mod parser;
pub mod snapshot;
pub mod version;

#[cfg(feature = "watcher")]
pub mod watcher;

pub mod db;

#[cfg(feature = "nats")]
pub mod nats;

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use config::CodeIndexerConfig;
use edits::EditEngine;
use error::CodeIndexError;
use explorer::Explorer;
use filter::FileFilter;
use locking::LockManager;
use snapshot::Snapshot;

#[cfg(feature = "watcher")]
use watcher::FsWatcher;

#[cfg(feature = "db")]
use db::StoredFile;
use db::{IndexStore, NoOpStore};

#[cfg(feature = "nats")]
use nats::NatsSyncLayer;

/// Handle returned by `CodeIndexer::scan_background()` for monitoring progress.
///
/// While the background scan runs, queries work on whatever is indexed so far
/// (Explorer uses per-index RwLocks so readers never block writers).
pub struct ScanHandle {
    task: tokio::task::JoinHandle<Result<usize, CodeIndexError>>,
    explorer: Arc<Explorer>,
}

impl ScanHandle {
    /// Number of files indexed so far.
    pub fn files_indexed(&self) -> usize {
        self.explorer.file_count()
    }

    /// Number of symbols indexed so far.
    pub fn symbols_indexed(&self) -> usize {
        self.explorer.symbol_count()
    }

    /// Whether the background scan has finished.
    pub fn is_complete(&self) -> bool {
        self.task.is_finished()
    }

    /// Block until the scan finishes and return the total file count.
    pub async fn wait(self) -> Result<usize, CodeIndexError> {
        self.task
            .await
            .map_err(|e| CodeIndexError::Parse(e.to_string()))?
    }
}

/// Main entry point for the code indexer.
///
/// Use the builder pattern to configure and start indexing:
///
/// ```ignore
/// let indexer = CodeIndexer::builder()
///     .workspace(PathBuf::from("/path/to/repo"))
///     .build()
///     .await;
///
/// // Run initial scan
/// indexer.scan().await?;
///
/// // Query
/// let results = indexer.search("authenticate").await;
/// let symbols = indexer.find_symbol("Agent").await;
/// ```
pub struct CodeIndexer {
    explorer: Arc<Explorer>,
    store: Arc<dyn IndexStore>,
    project_id: String,
    lock_manager: Arc<LockManager>,
    #[cfg(feature = "nats")]
    nats: Option<Arc<NatsSyncLayer>>,
    #[cfg(feature = "watcher")]
    _watcher_handle: Option<watcher::WatchHandle>,
}

impl CodeIndexer {
    pub fn builder() -> CodeIndexerBuilder {
        CodeIndexerBuilder::default()
    }

    /// Run a full initial scan of the workspace.
    pub async fn scan(&self) -> Result<usize, CodeIndexError> {
        let filter = FileFilter::new(self.explorer.config().clone());
        let paths = filter.collect_paths();
        let total = paths.len();

        // Indexing flag is managed via mark_indexing_complete()

        for path in paths {
            if let Err(e) = self.explorer.index_file(&path) {
                tracing::debug!("Skipping {:?}: {}", path, e);
            }

            // Persist to DB if available
            #[cfg(feature = "db")]
            {
                if let Some(outline) = self.explorer.get_outline(&path) {
                    let content = match self.explorer.filter().read_file(&path) {
                        Ok(c) => c,
                        Err(_) => continue,
                    };
                    let _hash = ahash::AHasher::default();
                    // Simple hash — in production use a proper content hash
                    let file = StoredFile {
                        project_id: self.project_id.clone(),
                        path: path.to_string_lossy().to_string(),
                        hash: 0,
                        language: format!("{:?}", outline.language),
                        line_count: outline.line_count,
                        byte_size: outline.byte_size,
                        symbols: outline.symbols,
                        imports: outline.imports,
                        content,
                    };
                    let _ = self.store.upsert_file(&file).await;
                }
            }
        }

        self.explorer.mark_indexing_complete();

        // Publish index complete event
        #[cfg(feature = "nats")]
        if let Some(ref nats) = self.nats {
            let event = nats::CodeIndexComplete {
                file_count: self.explorer.file_count(),
                symbol_count: self.explorer.symbol_count(),
                pod_id: self.project_id.clone(),
            };
            let _ = nats.publish_index_complete(&event).await;
        }

        Ok(total)
    }

    /// Spawn the indexing scan on a background tokio task and return immediately.
    ///
    /// The returned `ScanHandle` lets you check progress (`files_indexed()`,
    /// `symbols_indexed()`, `is_complete()`) and await completion (`wait()`).
    ///
    /// Queries work while indexing is in progress — Explorer uses per-index
    /// RwLocks so readers never block writers.
    pub fn scan_background(&self) -> ScanHandle {
        let explorer = Arc::clone(&self.explorer);
        let store = Arc::clone(&self.store);
        let project_id = self.project_id.clone();
        #[cfg(feature = "nats")]
        let nats = self.nats.clone();

        let task = tokio::spawn(async move {
            let filter = FileFilter::new(explorer.config().clone());
            let paths = filter.collect_paths();
            let total = paths.len();

            for path in paths {
                if let Err(e) = explorer.index_file(&path) {
                    tracing::debug!("Skipping {:?}: {}", path, e);
                }

                // Persist to DB if available
                #[cfg(feature = "db")]
                {
                    if let Some(outline) = explorer.get_outline(&path) {
                        let content = match explorer.filter().read_file(&path) {
                            Ok(c) => c,
                            Err(_) => continue,
                        };
                        let _hash = ahash::AHasher::default();
                        let file = StoredFile {
                            project_id: project_id.clone(),
                            path: path.to_string_lossy().to_string(),
                            hash: 0,
                            language: format!("{:?}", outline.language),
                            line_count: outline.line_count,
                            byte_size: outline.byte_size,
                            symbols: outline.symbols,
                            imports: outline.imports,
                            content,
                        };
                        let _ = store.upsert_file(&file).await;
                    }
                }

                // Suppress unused-variable warnings when db feature is off
                #[cfg(not(feature = "db"))]
                let _ = (&store, &project_id);
            }

            explorer.mark_indexing_complete();

            // Publish index complete event
            #[cfg(feature = "nats")]
            if let Some(ref nats) = nats {
                let event = nats::CodeIndexComplete {
                    file_count: explorer.file_count(),
                    symbol_count: explorer.symbol_count(),
                    pod_id: project_id.clone(),
                };
                let _ = nats.publish_index_complete(&event).await;
            }

            Ok(total)
        });

        ScanHandle {
            task,
            explorer: Arc::clone(&self.explorer),
        }
    }

    /// Start the file watcher (feature=watcher).
    #[cfg(feature = "watcher")]
    pub fn start_watcher(&mut self) {
        let watcher = FsWatcher::new(self.explorer.clone());
        self._watcher_handle = Some(watcher.start());
    }

    // ── Query methods ─────────────────────────────────────────────────────────

    /// Get the file outline (symbols, imports, metadata) for a path.
    pub fn get_outline(&self, path: &std::path::Path) -> Option<models::FileOutline> {
        self.explorer.get_outline(path)
    }

    /// Find symbol definitions by name across all indexed files.
    pub fn find_symbol(&self, name: &str) -> Vec<models::SymbolResult> {
        self.explorer.find_symbol(name)
    }

    /// Search file contents using trigram-accelerated candidate filtering.
    pub fn search_content(&self, query: &str) -> Vec<models::ScopedSearchResult> {
        self.explorer.search_content(query)
    }

    /// Search for a word/identifier in the inverted index. O(1) lookup.
    pub fn find_word(&self, word: &str) -> Vec<index::word::WordHit> {
        self.explorer.find_word(word)
    }

    /// Get the directory tree with symbol counts.
    pub fn get_tree(&self) -> Vec<models::TreeNode> {
        self.explorer.get_tree()
    }

    /// Get reverse dependencies: which files import this file?
    pub fn get_imported_by(&self, path: &std::path::Path) -> Vec<PathBuf> {
        self.explorer.get_imported_by(path)
    }

    /// Get forward dependencies: which files does this file import?
    pub fn get_imports(&self, path: &std::path::Path) -> Vec<PathBuf> {
        self.explorer.get_imports(path)
    }

    /// Get recently changed files, sorted by change sequence (newest first).
    pub fn get_hot_files(&self, limit: usize) -> Vec<(PathBuf, models::ChangeRecord)> {
        self.explorer.get_hot_files(limit)
    }

    /// Get changes since a sequence number.
    pub fn changes_since(&self, seq: u64) -> (Vec<models::ChangeRecord>, bool) {
        self.explorer.changes_since(seq)
    }

    /// Get the latest sequence number.
    pub fn latest_seq(&self) -> u64 {
        self.explorer.latest_seq()
    }

    /// Get the number of indexed files.
    pub fn file_count(&self) -> usize {
        self.explorer.file_count()
    }

    /// Get the total symbol count across all files.
    pub fn symbol_count(&self) -> usize {
        self.explorer.symbol_count()
    }

    /// Check if indexing is still in progress.
    pub fn is_indexing(&self) -> bool {
        self.explorer.is_indexing()
    }

    /// Get a reference to the explorer for advanced use.
    pub fn explorer(&self) -> &Arc<Explorer> {
        &self.explorer
    }

    // ── Edit / Lock / Snapshot ────────────────────────────────────────────────

    /// Create an `EditEngine` rooted at this indexer's workspace.
    pub fn edit_engine(&self) -> EditEngine {
        EditEngine::new(self.explorer.config().workspace_root.clone())
    }

    /// Get a reference to the shared `LockManager`.
    pub fn lock_manager(&self) -> &LockManager {
        &self.lock_manager
    }

    /// Save a snapshot of the current index state to a file.
    pub fn save_snapshot(&self, path: &Path) -> Result<(), CodeIndexError> {
        Snapshot::save(&self.explorer, path)
    }

    /// Load a snapshot and restore it into this indexer's explorer.
    ///
    /// Returns the number of files restored from cache (not re-parsed).
    pub fn load_snapshot(&self, path: &Path) -> Result<usize, CodeIndexError> {
        let snap = Snapshot::load(path)?;
        let filter = FileFilter::new(self.explorer.config().clone());
        snap.restore(&self.explorer, &filter)
    }
}

/// Builder for `CodeIndexer`.
#[derive(Default)]
pub struct CodeIndexerBuilder {
    config: Option<CodeIndexerConfig>,
    project_id: String,
    #[cfg(feature = "db")]
    store: Option<Arc<dyn IndexStore>>,
    #[cfg(feature = "nats")]
    nats: Option<Arc<NatsSyncLayer>>,
}

impl CodeIndexerBuilder {
    pub fn workspace(mut self, root: PathBuf) -> Self {
        let mut config = self.config.unwrap_or_default();
        config.workspace_root = root;
        self.config = Some(config);
        self
    }

    pub fn config(mut self, config: CodeIndexerConfig) -> Self {
        self.config = Some(config);
        self
    }

    pub fn project_id(mut self, id: &str) -> Self {
        self.project_id = id.to_string();
        self
    }

    #[cfg(feature = "db")]
    pub fn store(mut self, store: Arc<dyn IndexStore>) -> Self {
        self.store = Some(store);
        self
    }

    #[cfg(feature = "nats")]
    pub fn nats(mut self, nats: Arc<NatsSyncLayer>) -> Self {
        self.nats = Some(nats);
        self
    }

    pub async fn build(self) -> CodeIndexer {
        let config = Arc::new(self.config.unwrap_or_default());
        let explorer = Arc::new(Explorer::new(config));

        #[cfg(feature = "db")]
        let store = self.store.unwrap_or_else(|| Arc::new(NoOpStore));
        #[cfg(not(feature = "db"))]
        let store = Arc::new(NoOpStore);

        let lock_manager = Arc::new(LockManager::new(Duration::from_secs(30)));

        CodeIndexer {
            explorer,
            store,
            project_id: self.project_id,
            lock_manager,
            #[cfg(feature = "nats")]
            nats: self.nats,
            #[cfg(feature = "watcher")]
            _watcher_handle: None,
        }
    }
}

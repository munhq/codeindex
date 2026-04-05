use notify::{Event, RecommendedWatcher, RecursiveMode, Watcher as NotifyWatcher};
use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;
use tokio::time::sleep;
use tracing::{debug, error, info, warn};

use crate::explorer::Explorer;
use crate::filter::FileFilter;

/// Debounce window for coalescing file system events.
const DEBOUNCE_MS: u64 = 200;

/// A file change event from the watcher.
#[derive(Debug, Clone)]
pub struct FileChangeEvent {
    pub path: PathBuf,
    pub op: crate::models::ChangeOp,
}

/// File system watcher that monitors the workspace for changes and
/// triggers re-indexing. Uses debouncing to coalesce multiple events
/// per save (write, chmod, close) into a single re-index.
pub struct FsWatcher {
    explorer: Arc<Explorer>,
    filter: Arc<FileFilter>,
    #[cfg(feature = "nats")]
    nats_tx: Option<mpsc::Sender<FileChangeEvent>>,
}

impl FsWatcher {
    pub fn new(explorer: Arc<Explorer>) -> Self {
        let filter = explorer.filter().clone();
        Self {
            explorer,
            filter,
            #[cfg(feature = "nats")]
            nats_tx: None,
        }
    }

    #[cfg(feature = "nats")]
    pub fn with_nats(mut self, tx: mpsc::Sender<FileChangeEvent>) -> Self {
        self.nats_tx = Some(tx);
        self
    }

    /// Start watching the workspace. Returns a handle to stop the watcher.
    pub fn start(self) -> WatchHandle {
        let (stop_tx, stop_rx) = tokio::sync::oneshot::channel();

        tokio::spawn(async move {
            self.run(stop_rx).await;
        });

        WatchHandle { stop_tx }
    }

    async fn run(self, mut stop_rx: tokio::sync::oneshot::Receiver<()>) {
        let (event_tx, mut event_rx) = mpsc::channel(256);

        // Set up notify watcher
        let workspace = self.explorer.config().workspace_root.clone();
        let tx_clone = event_tx.clone();
        let mut watcher = match RecommendedWatcher::new(
            move |res: Result<Event, notify::Error>| {
                if let Ok(event) = res {
                    let _ = tx_clone.blocking_send(event);
                }
            },
            notify::Config::default(),
        ) {
            Ok(w) => w,
            Err(e) => {
                error!("Failed to create file watcher: {}", e);
                return;
            }
        };

        if let Err(e) = watcher.watch(&workspace, RecursiveMode::Recursive) {
            error!("Failed to watch workspace {}: {}", workspace.display(), e);
            return;
        }

        info!("File watcher started on {}", workspace.display());

        // Debounce loop
        let mut pending: HashSet<PathBuf> = HashSet::new();
        let explorer = self.explorer;
        let filter = self.filter;

        loop {
            tokio::select! {
                biased;

                _ = &mut stop_rx => {
                    info!("File watcher stopping");
                    drop(watcher);
                    return;
                }

                event = event_rx.recv() => {
                    let Some(event) = event else { break };
                    for path in &event.paths {
                        if let Ok(rel) = path.strip_prefix(&workspace) {
                            let rel = rel.to_path_buf();
                            // Skip if not an indexable file
                            if filter.should_skip_extension(&rel) {
                                continue;
                            }
                            pending.insert(rel);
                        }
                    }
                }

                _ = sleep(Duration::from_millis(DEBOUNCE_MS)) => {
                    if pending.is_empty() {
                        continue;
                    }

                    let to_process: Vec<PathBuf> = pending.drain().collect();
                    for rel_path in to_process {
                        let full_path = workspace.join(&rel_path);

                        // Check if file still exists
                        if !full_path.exists() {
                            explorer.remove_file(&rel_path);
                            debug!("Removed from index: {:?}", rel_path);
                            #[cfg(feature = "nats")]
                            if let Some(ref tx) = self.nats_tx {
                                let _ = tx.send(FileChangeEvent {
                                    path: rel_path.clone(),
                                    op: crate::models::ChangeOp::Deleted,
                                }).await;
                            }
                            continue;
                        }

                        // Re-index
                        match explorer.index_file(&rel_path) {
                            Ok(()) => {
                                debug!("Re-indexed: {:?}", rel_path);
                                #[cfg(feature = "nats")]
                                if let Some(ref tx) = self.nats_tx {
                                    let _ = tx.send(FileChangeEvent {
                                        path: rel_path.clone(),
                                        op: crate::models::ChangeOp::Modified,
                                    }).await;
                                }
                            }
                            Err(e) => {
                                warn!("Failed to index {:?}: {}", rel_path, e);
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Handle to stop the file watcher.
pub struct WatchHandle {
    stop_tx: tokio::sync::oneshot::Sender<()>,
}

impl WatchHandle {
    /// Stop the file watcher.
    pub fn stop(self) {
        let _ = self.stop_tx.send(());
    }
}

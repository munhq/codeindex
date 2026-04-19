use std::path::PathBuf;

/// Configuration for the code indexer.
#[derive(Debug, Clone)]
pub struct CodeIndexerConfig {
    /// Root directory to index.
    pub workspace_root: PathBuf,

    /// Maximum file size to index (bytes). Default: 10 MB.
    pub max_file_size: u64,

    /// Maximum content cache size (bytes). Default: 50 MB.
    pub max_cache_bytes: usize,

    /// Additional directory names to skip beyond the built-in list.
    pub extra_skip_dirs: Vec<String>,

    /// Additional file extensions to skip beyond the built-in list.
    pub extra_skip_extensions: Vec<String>,

    /// Whether to respect .gitignore files. Default: true.
    pub respect_gitignore: bool,

    /// Whether to respect .git/info/exclude. Default: true.
    pub respect_git_exclude: bool,

    /// Whether to respect global gitignore (~/.gitignore). Default: true.
    pub respect_git_global: bool,

    /// Whether to skip hidden files/directories. Default: true.
    pub skip_hidden: bool,

    /// Whether to follow symbolic links. Default: false (never follow).
    pub follow_symlinks: bool,
}

impl Default for CodeIndexerConfig {
    fn default() -> Self {
        Self {
            workspace_root: PathBuf::from("."),
            max_file_size: 10 * 1024 * 1024,
            max_cache_bytes: 50 * 1024 * 1024,
            extra_skip_dirs: Vec::new(),
            extra_skip_extensions: Vec::new(),
            respect_gitignore: true,
            respect_git_exclude: true,
            respect_git_global: true,
            skip_hidden: true,
            follow_symlinks: false,
        }
    }
}

impl CodeIndexerConfig {
    pub fn new(workspace_root: PathBuf) -> Self {
        Self {
            workspace_root,
            ..Default::default()
        }
    }
}

use ignore::WalkBuilder;
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use crate::config::CodeIndexerConfig;

/// Built-in directories to always skip.
const SKIP_DIRS: &[&str] = &[
    ".git",
    ".hg",
    ".svn",
    ".bzr",
    "node_modules",
    ".next",
    ".nuxt",
    ".svelte-kit",
    "target",
    ".cargo",
    "__pycache__",
    ".pytest_cache",
    ".mypy_cache",
    ".ruff_cache",
    ".venv",
    "venv",
    "env",
    ".env",
    "vendor",
    ".bundle",
    "dist",
    "build",
    "out",
    ".idea",
    ".vscode",
    "coverage",
    ".nyc_output",
    ".tox",
    ".nox",
    ".terraform",
    ".cache",
    "bower_components",
    ".eggs",
    "*.egg-info",
    ".lock",
];

/// Built-in file extensions to skip (binary / non-text).
const SKIP_EXTENSIONS: &[&str] = &[
    "png", "jpg", "jpeg", "gif", "bmp", "ico", "webp", "svg", "tiff", "psd", "mp3", "mp4", "avi",
    "mov", "wmv", "flv", "mkv", "webm", "zip", "tar", "gz", "bz2", "xz", "7z", "rar", "tgz", "exe",
    "dll", "so", "dylib", "a", "lib", "o", "obj", "wasm", "class", "pyc", "pyo", "pdf", "doc",
    "docx", "xls", "xlsx", "ppt", "pptx", "woff", "woff2", "ttf", "eot", "otf", "lock", "sum",
];

/// File filter and directory walker that respects .gitignore and skips
/// binary/large/symlink-escape files.
pub struct FileFilter {
    config: Arc<CodeIndexerConfig>,
    skip_dirs: HashSet<String>,
    skip_extensions: HashSet<String>,
}

impl FileFilter {
    pub fn new(config: Arc<CodeIndexerConfig>) -> Self {
        let mut skip_dirs: HashSet<String> = SKIP_DIRS.iter().map(|s| s.to_string()).collect();
        skip_dirs.extend(config.extra_skip_dirs.iter().cloned());

        let mut skip_extensions: HashSet<String> =
            SKIP_EXTENSIONS.iter().map(|s| s.to_string()).collect();
        skip_extensions.extend(config.extra_skip_extensions.iter().cloned());

        Self {
            config,
            skip_dirs,
            skip_extensions,
        }
    }

    /// Build a `WalkBuilder` configured for the workspace root.
    /// Respects .gitignore, skips hidden files, never follows symlinks.
    pub fn walk_builder(&self) -> WalkBuilder {
        let mut builder = WalkBuilder::new(&self.config.workspace_root);
        builder
            .git_ignore(self.config.respect_gitignore)
            .git_exclude(self.config.respect_git_exclude)
            .git_global(self.config.respect_git_global)
            .hidden(self.config.skip_hidden)
            .follow_links(self.config.follow_symlinks)
            .max_filesize(Some(self.config.max_file_size));

        // Custom skip dirs via filter_entry
        let skip_dirs = self.skip_dirs.clone();
        builder.filter_entry(move |entry| {
            if entry.file_type().map_or(false, |ft| ft.is_dir()) {
                let name = entry.file_name().to_string_lossy();
                !skip_dirs.contains(name.as_ref())
            } else {
                true
            }
        });

        builder
    }

    /// Check if a file extension should be skipped.
    pub fn should_skip_extension(&self, path: &Path) -> bool {
        path.extension()
            .and_then(|e| e.to_str())
            .map(|ext| self.skip_extensions.contains(ext))
            .unwrap_or(false)
    }

    /// Detect if a file is binary by scanning for null bytes in the first 8KB.
    pub fn is_binary(path: &Path) -> bool {
        let Ok(data) = std::fs::read(path) else {
            return true;
        };
        let scan_len = data.len().min(8192);
        data[..scan_len].contains(&0)
    }

    /// Check if a resolved path escapes the workspace root.
    pub fn is_symlink_escape(path: &Path, workspace: &Path) -> bool {
        if let Ok(resolved) = path.canonicalize() {
            !resolved.starts_with(workspace)
        } else {
            false
        }
    }

    /// Collect all indexable file paths from the workspace.
    /// Returns paths relative to the workspace root.
    pub fn collect_paths(&self) -> Vec<PathBuf> {
        let workspace = &self.config.workspace_root;
        let mut paths = Vec::new();

        let walker = self.walk_builder();
        for result in walker.build() {
            let Ok(entry) = result else { continue };
            if !entry.file_type().map_or(false, |ft| ft.is_file()) {
                continue;
            }

            let path = entry.path();

            // Extension skip
            if self.should_skip_extension(path) {
                continue;
            }

            // Binary detection
            if Self::is_binary(path) {
                continue;
            }

            // Symlink escape check
            if !self.config.follow_symlinks && Self::is_symlink_escape(path, workspace) {
                continue;
            }

            // Make relative to workspace
            if let Ok(rel) = path.strip_prefix(workspace) {
                paths.push(rel.to_path_buf());
            }
        }

        paths
    }

    /// Read file contents with safety checks.
    pub fn read_file(&self, rel_path: &Path) -> Result<String, crate::error::CodeIndexError> {
        use crate::error::CodeIndexError;

        let full = self.config.workspace_root.join(rel_path);

        if !full.exists() {
            return Err(CodeIndexError::FileNotFound(rel_path.to_path_buf()));
        }

        let meta = std::fs::metadata(&full)?;
        if meta.len() > self.config.max_file_size {
            return Err(CodeIndexError::FileTooLarge(
                meta.len(),
                self.config.max_file_size,
            ));
        }

        if Self::is_binary(&full) {
            return Err(CodeIndexError::BinaryFile(rel_path.to_path_buf()));
        }

        if !self.config.follow_symlinks
            && Self::is_symlink_escape(&full, &self.config.workspace_root)
        {
            return Err(CodeIndexError::SymlinkEscape(rel_path.to_path_buf()));
        }

        std::fs::read_to_string(&full).map_err(CodeIndexError::Io)
    }
}

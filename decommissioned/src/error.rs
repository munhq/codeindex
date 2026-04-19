use std::io;
use std::path::PathBuf;

/// Errors that can occur during code indexing operations.
#[derive(Debug, thiserror::Error)]
pub enum CodeIndexError {
    #[error("workspace not found: {0}")]
    WorkspaceNotFound(PathBuf),

    #[error("file not found: {0}")]
    FileNotFound(PathBuf),

    #[error("file too large: {0} bytes (limit: {1})")]
    FileTooLarge(u64, u64),

    #[error("binary file: {0}")]
    BinaryFile(PathBuf),

    #[error("symlink escape: {0}")]
    SymlinkEscape(PathBuf),

    #[error("IO error: {0}")]
    Io(#[from] io::Error),

    #[error("parse error: {0}")]
    Parse(String),

    #[error("index not ready — still initializing")]
    IndexNotReady,

    #[cfg(feature = "db")]
    #[error("database error: {0}")]
    Database(#[from] sqlx::Error),

    #[cfg(feature = "nats")]
    #[error("sync error: {0}")]
    Sync(String),
}

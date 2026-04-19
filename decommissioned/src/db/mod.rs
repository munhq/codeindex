use crate::models::{SearchResult, Symbol};
use crate::error::CodeIndexError;

/// Trait for index persistence. When the `db` feature is off,
/// a no-op implementation is used.
#[async_trait::async_trait]
pub trait IndexStore: Send + Sync {
    async fn load_file(&self, path: &str) -> Option<StoredFile>;
    async fn upsert_file(&self, file: &StoredFile) -> Result<(), CodeIndexError>;
    async fn delete_file(&self, project_id: &str, path: &str) -> Result<(), CodeIndexError>;
    async fn load_symbols(&self, file_id: &str) -> Vec<Symbol>;
    async fn load_deps(&self, project_id: &str) -> Vec<(String, String)>;
    async fn search_content(&self, project_id: &str, query: &str, limit: usize) -> Vec<SearchResult>;
}

/// A file record for DB persistence.
#[derive(Debug, Clone)]
pub struct StoredFile {
    pub project_id: String,
    pub path: String,
    pub hash: u64,
    pub language: String,
    pub line_count: usize,
    pub byte_size: u64,
    pub symbols: Vec<Symbol>,
    pub imports: Vec<String>,
    pub content: String,
}

/// No-op store used when the `db` feature is disabled.
pub struct NoOpStore;

#[async_trait::async_trait]
impl IndexStore for NoOpStore {
    async fn load_file(&self, _path: &str) -> Option<StoredFile> { None }
    async fn upsert_file(&self, _file: &StoredFile) -> Result<(), CodeIndexError> { Ok(()) }
    async fn delete_file(&self, _project_id: &str, _path: &str) -> Result<(), CodeIndexError> { Ok(()) }
    async fn load_symbols(&self, _file_id: &str) -> Vec<Symbol> { Vec::new() }
    async fn load_deps(&self, _project_id: &str) -> Vec<(String, String)> { Vec::new() }
    async fn search_content(&self, _project_id: &str, _query: &str, _limit: usize) -> Vec<SearchResult> { Vec::new() }
}

#[cfg(feature = "db")]
mod pg;
#[cfg(feature = "db")]
pub use pg::PgIndexStore;

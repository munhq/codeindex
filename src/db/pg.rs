use async_trait::async_trait;
use sqlx::PgPool;
use std::path::PathBuf;

use crate::db::IndexStore;
use crate::error::CodeIndexError;
use crate::models::{SearchResult, Symbol, SymbolKind};

use super::StoredFile;

/// PostgreSQL-backed index store.
pub struct PgIndexStore {
    pool: PgPool,
}

impl PgIndexStore {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    /// Run migrations. Call once at startup.
    pub async fn migrate(&self) -> Result<(), sqlx::Error> {
        let statements = [
            r#"CREATE TABLE IF NOT EXISTS code_files (
                id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                project_id TEXT NOT NULL,
                path TEXT NOT NULL,
                hash BIGINT NOT NULL,
                language TEXT NOT NULL,
                line_count INT NOT NULL,
                byte_size BIGINT NOT NULL,
                indexed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                UNIQUE(project_id, path)
            )"#,
            r#"CREATE TABLE IF NOT EXISTS code_symbols (
                id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                file_id UUID REFERENCES code_files(id) ON DELETE CASCADE,
                name TEXT NOT NULL,
                kind TEXT NOT NULL,
                line_start INT NOT NULL,
                line_end INT NOT NULL,
                detail TEXT,
                UNIQUE(file_id, name, kind, line_start)
            )"#,
            "CREATE INDEX IF NOT EXISTS idx_code_symbols_name ON code_symbols(name)",
            "CREATE INDEX IF NOT EXISTS idx_code_symbols_file ON code_symbols(file_id)",
            r#"CREATE TABLE IF NOT EXISTS code_deps (
                id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                project_id TEXT NOT NULL,
                from_path TEXT NOT NULL,
                to_path TEXT NOT NULL,
                UNIQUE(project_id, from_path, to_path)
            )"#,
            "CREATE INDEX IF NOT EXISTS idx_code_deps_from ON code_deps(from_path)",
            "CREATE INDEX IF NOT EXISTS idx_code_deps_to ON code_deps(to_path)",
            r#"CREATE TABLE IF NOT EXISTS code_search (
                id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                project_id TEXT NOT NULL,
                path TEXT NOT NULL,
                fts TSVECTOR NOT NULL,
                UNIQUE(project_id, path)
            )"#,
            "CREATE INDEX IF NOT EXISTS idx_code_search_fts ON code_search USING GIN(fts)",
        ];

        for stmt in statements {
            sqlx::query(stmt).execute(&self.pool).await?;
        }

        Ok(())
    }
}

#[async_trait]
impl IndexStore for PgIndexStore {
    async fn load_file(&self, path: &str) -> Option<StoredFile> {
        let row: (String, String, i64, String, i32, i64) = sqlx::query_as(
            r#"SELECT project_id, path, hash, language, line_count, byte_size
               FROM code_files WHERE path = $1"#,
        )
        .bind(path)
        .fetch_optional(&self.pool)
        .await
        .ok()??;

        let file_id: Option<String> = sqlx::query_scalar(
            "SELECT id::text FROM code_files WHERE path = $1",
        )
        .bind(path)
        .fetch_optional(&self.pool)
        .await
        .ok()?;

        let symbols = if let Some(ref fid) = file_id {
            self.load_symbols(fid).await
        } else {
            Vec::new()
        };

        let deps: Vec<String> = sqlx::query_scalar(
            "SELECT to_path FROM code_deps WHERE from_path = $1 AND project_id = $2",
        )
        .bind(path)
        .bind(&row.0)
        .fetch_all(&self.pool)
        .await
        .unwrap_or_default();

        Some(StoredFile {
            project_id: row.0,
            path: row.1,
            hash: row.2 as u64,
            language: row.3,
            line_count: row.4 as usize,
            byte_size: row.5 as u64,
            symbols,
            imports: deps,
            content: String::new(), // Content is on disk, not in DB
        })
    }

    async fn upsert_file(&self, file: &StoredFile) -> Result<(), CodeIndexError> {
        let file_id: String = sqlx::query_scalar(
            r#"
            INSERT INTO code_files (project_id, path, hash, language, line_count, byte_size)
            VALUES ($1, $2, $3, $4, $5, $6)
            ON CONFLICT (project_id, path) DO UPDATE SET
                hash = EXCLUDED.hash,
                language = EXCLUDED.language,
                line_count = EXCLUDED.line_count,
                byte_size = EXCLUDED.byte_size,
                indexed_at = NOW()
            RETURNING id::text
            "#,
        )
        .bind(&file.project_id)
        .bind(&file.path)
        .bind(file.hash as i64)
        .bind(&file.language)
        .bind(file.line_count as i32)
        .bind(file.byte_size as i64)
        .fetch_one(&self.pool)
        .await?;

        // Upsert symbols
        for sym in &file.symbols {
            sqlx::query(
                r#"
                INSERT INTO code_symbols (file_id, name, kind, line_start, line_end, detail)
                VALUES ($1::uuid, $2, $3, $4, $5, $6)
                ON CONFLICT (file_id, name, kind, line_start) DO NOTHING
                "#,
            )
            .bind(&file_id)
            .bind(&sym.name)
            .bind(sym.kind.as_str())
            .bind(sym.line_start as i32)
            .bind(sym.line_end as i32)
            .bind(sym.detail.as_deref())
            .execute(&self.pool)
            .await?;
        }

        // Upsert deps
        for imp in &file.imports {
            sqlx::query(
                r#"
                INSERT INTO code_deps (project_id, from_path, to_path)
                VALUES ($1, $2, $3)
                ON CONFLICT (project_id, from_path, to_path) DO NOTHING
                "#,
            )
            .bind(&file.project_id)
            .bind(&file.path)
            .bind(imp)
            .execute(&self.pool)
            .await?;
        }

        // Upsert FTS
        sqlx::query(
            r#"
            INSERT INTO code_search (project_id, path, fts)
            VALUES ($1, $2, to_tsvector('english', $3))
            ON CONFLICT (project_id, path) DO UPDATE SET
                fts = to_tsvector('english', EXCLUDED.fts::text)
            "#,
        )
        .bind(&file.project_id)
        .bind(&file.path)
        .bind(&file.content)
        .execute(&self.pool)
        .await?;

        Ok(())
    }

    async fn delete_file(&self, project_id: &str, path: &str) -> Result<(), CodeIndexError> {
        sqlx::query(
            "DELETE FROM code_files WHERE project_id = $1 AND path = $2",
        )
        .bind(project_id)
        .bind(path)
        .execute(&self.pool)
        .await?;

        Ok(())
    }

    async fn load_symbols(&self, file_id: &str) -> Vec<Symbol> {
        let rows: Vec<(String, String, i32, i32, Option<String>)> = sqlx::query_as(
            "SELECT name, kind, line_start, line_end, detail FROM code_symbols WHERE file_id = $1",
        )
        .bind(file_id)
        .fetch_all(&self.pool)
        .await
        .unwrap_or_default();

        rows.into_iter()
            .filter_map(|(name, kind, ls, le, detail)| {
                let kind = match kind.as_str() {
                    "function" => SymbolKind::Function,
                    "method" => SymbolKind::Method,
                    "struct" => SymbolKind::Struct,
                    "enum" => SymbolKind::Enum,
                    "union" => SymbolKind::Union,
                    "trait" => SymbolKind::Trait,
                    "interface" => SymbolKind::Interface,
                    "type_alias" => SymbolKind::TypeAlias,
                    "constant" => SymbolKind::Constant,
                    "variable" => SymbolKind::Variable,
                    "import" => SymbolKind::Import,
                    "module" => SymbolKind::Module,
                    "macro" => SymbolKind::Macro,
                    "test" => SymbolKind::Test,
                    "impl" => SymbolKind::Impl,
                    "class" => SymbolKind::Class,
                    "comment" => SymbolKind::Comment,
                    _ => return None,
                };
                Some(Symbol {
                    name,
                    kind,
                    line_start: ls as usize,
                    line_end: le as usize,
                    detail,
                })
            })
            .collect()
    }

    async fn load_deps(&self, project_id: &str) -> Vec<(String, String)> {
        let rows: Vec<(String, String)> = sqlx::query_as(
            "SELECT from_path, to_path FROM code_deps WHERE project_id = $1",
        )
        .bind(project_id)
        .fetch_all(&self.pool)
        .await
        .unwrap_or_default();

        rows
    }

    async fn search_content(&self, project_id: &str, query: &str, limit: usize) -> Vec<SearchResult> {
        let rows: Vec<(String, i32, String)> = sqlx::query_as(
            r#"
            SELECT path, 0 as line_num, '' as line_text
            FROM code_search
            WHERE project_id = $1 AND fts @@ websearch_to_tsquery('english', $2)
            LIMIT $3
            "#,
        )
        .bind(project_id)
        .bind(query)
        .bind(limit as i64)
        .fetch_all(&self.pool)
        .await
        .unwrap_or_default();

        rows.into_iter()
            .map(|(path, line_num, line_text)| SearchResult {
                path: PathBuf::from(path),
                line_num: line_num as usize,
                line_text,
            })
            .collect()
    }
}

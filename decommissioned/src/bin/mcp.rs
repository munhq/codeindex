use std::path::PathBuf;
use std::sync::Arc;

use clap::Parser;
use rmcp::{
    ErrorData, ServerHandler, ServiceExt,
    handler::server::{router::tool::ToolRouter, wrapper::Parameters},
    model::*,
    schemars::JsonSchema,
    tool, tool_handler, tool_router,
    transport::stdio,
};
use serde::{Deserialize, Serialize};

use codeindex::CodeIndexer;
use codeindex::analysis;
use codeindex::models::SymbolKind;

// ── CLI ──────────────────────────────────────────────────────────────────────

#[derive(Parser)]
#[command(name = "codeindex-mcp", about = "Code intelligence MCP server")]
struct Cli {
    /// Workspace directory to index (can also be set via CODEINDEX_WORKSPACE env var)
    #[arg(long, env = "CODEINDEX_WORKSPACE")]
    workspace: Option<PathBuf>,

    /// Project identifier for this index
    #[arg(long, env = "CODEINDEX_PROJECT_ID", default_value = "default")]
    project_id: String,

    /// PostgreSQL connection URL (enables persistent storage)
    #[arg(long, env = "DATABASE_URL")]
    database_url: Option<String>,
}

// ── Tool parameter types ─────────────────────────────────────────────────────

#[derive(Debug, Deserialize, JsonSchema)]
struct IndexWorkspaceParams {
    /// Path to workspace directory. If omitted, uses the server's configured workspace.
    path: Option<String>,
}

#[derive(Debug, Deserialize, JsonSchema)]
struct SearchParams {
    /// Text query to search for in file contents (trigram-accelerated)
    query: String,
    /// Maximum results to return
    limit: Option<usize>,
}

#[derive(Debug, Deserialize, JsonSchema)]
struct FindSymbolParams {
    /// Symbol name to search for (substring match)
    name: String,
    /// Filter by symbol kind: function, method, struct, enum, trait, interface, class, etc.
    kind: Option<String>,
    /// Maximum results to return
    limit: Option<usize>,
}

#[derive(Debug, Deserialize, JsonSchema)]
struct FindWordParams {
    /// Exact word/identifier to look up in the inverted index
    word: String,
    /// Maximum results to return
    limit: Option<usize>,
}

#[derive(Debug, Deserialize, JsonSchema)]
struct GetOutlineParams {
    /// File path (relative to workspace root)
    path: String,
}

#[derive(Debug, Deserialize, JsonSchema)]
struct DepsParams {
    /// File path (relative to workspace root)
    path: String,
}

#[derive(Debug, Deserialize, JsonSchema)]
struct HotFilesParams {
    /// Number of recent changes to return
    limit: Option<usize>,
}

#[derive(Debug, Deserialize, JsonSchema)]
struct AnalysisParams {
    /// Analysis type: dead_code, crossref, security, unwrap_audit, test_coverage, type_drift, architecture, db_schema, migration_parity, manifest_compliance
    analysis: String,
}

// ── Server ───────────────────────────────────────────────────────────────────

#[derive(Clone)]
struct CodeIndexMcp {
    tool_router: ToolRouter<Self>,
    indexer: Arc<CodeIndexer>,
}

#[tool_router]
impl CodeIndexMcp {
    fn new(indexer: Arc<CodeIndexer>) -> Self {
        Self {
            tool_router: Self::tool_router(),
            indexer,
        }
    }

    /// Wait for the background scan to finish before answering queries.
    async fn wait_for_index(&self) {
        while self.indexer.is_indexing() {
            tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        }
    }

    /// Index or re-index a workspace directory. Scans all source files and builds symbol, trigram, word, and dependency indexes.
    #[tool(name = "index_workspace")]
    async fn index_workspace(
        &self,
        Parameters(params): Parameters<IndexWorkspaceParams>,
    ) -> Result<CallToolResult, ErrorData> {
        // If a path is given, build a fresh indexer for it; otherwise use the default
        let indexer = if let Some(path) = params.path {
            let ws = PathBuf::from(&path);
            if !ws.is_dir() {
                return Ok(CallToolResult::error(vec![Content::text(format!(
                    "Directory not found: {path}"
                ))]));
            }
            let idx = CodeIndexer::builder()
                .workspace(ws)
                .project_id("adhoc")
                .build()
                .await;
            Arc::new(idx)
        } else {
            Arc::clone(&self.indexer)
        };

        match indexer.scan().await {
            Ok(count) => {
                let msg = format!(
                    "Indexed {count} files — {} symbols across {} files",
                    indexer.symbol_count(),
                    indexer.file_count(),
                );
                Ok(CallToolResult::success(vec![Content::text(msg)]))
            }
            Err(e) => Ok(CallToolResult::error(vec![Content::text(format!(
                "Scan failed: {e}"
            ))])),
        }
    }

    /// Search file contents using trigram-accelerated full-text search. Returns matching lines with their enclosing symbol scope.
    #[tool(name = "search")]
    async fn search(
        &self,
        Parameters(params): Parameters<SearchParams>,
    ) -> Result<CallToolResult, ErrorData> {
        self.wait_for_index().await;
        let results = self.indexer.search_content(&params.query);
        let limit = params.limit.unwrap_or(50);
        let total = results.len();

        let mut out = String::new();
        for hit in results.iter().take(limit) {
            let scope = match (&hit.scope_name, &hit.scope_kind) {
                (Some(name), Some(kind)) => format!(" [{}:{}]", kind.as_str(), name),
                _ => String::new(),
            };
            out.push_str(&format!(
                "{}:{}{} — {}\n",
                hit.path.display(),
                hit.line_num,
                scope,
                hit.line_text.trim(),
            ));
        }
        if total > limit {
            out.push_str(&format!("... and {} more results\n", total - limit));
        }
        if out.is_empty() {
            out.push_str("No results found.");
        }
        Ok(CallToolResult::success(vec![Content::text(out)]))
    }

    /// Find symbol definitions (functions, structs, traits, etc.) by name across all indexed files. Supports substring matching.
    #[tool(name = "find_symbol")]
    async fn find_symbol(
        &self,
        Parameters(params): Parameters<FindSymbolParams>,
    ) -> Result<CallToolResult, ErrorData> {
        self.wait_for_index().await;
        let mut results = self.indexer.find_symbol(&params.name);

        // Optional kind filter
        if let Some(ref kind_str) = params.kind {
            let kind = parse_symbol_kind(kind_str);
            if let Some(k) = kind {
                results.retain(|r| r.symbol.kind == k);
            }
        }

        let limit = params.limit.unwrap_or(50);
        let total = results.len();

        let mut out = String::new();
        for r in results.iter().take(limit) {
            let detail = r
                .symbol
                .detail
                .as_deref()
                .map(|d| format!(" — {d}"))
                .unwrap_or_default();
            out.push_str(&format!(
                "{}:{}-{} {} {}{}\n",
                r.path.display(),
                r.symbol.line_start,
                r.symbol.line_end,
                r.symbol.kind.as_str(),
                r.symbol.name,
                detail,
            ));
        }
        if total > limit {
            out.push_str(&format!("... and {} more results\n", total - limit));
        }
        if out.is_empty() {
            out.push_str("No symbols found.");
        }
        Ok(CallToolResult::success(vec![Content::text(out)]))
    }

    /// Look up an exact word/identifier in the inverted word index. O(1) lookup — much faster than search for known identifiers.
    #[tool(name = "find_word")]
    async fn find_word(
        &self,
        Parameters(params): Parameters<FindWordParams>,
    ) -> Result<CallToolResult, ErrorData> {
        self.wait_for_index().await;
        let results = self.indexer.find_word(&params.word);
        let limit = params.limit.unwrap_or(50);
        let total = results.len();

        let mut out = String::new();
        for hit in results.iter().take(limit) {
            out.push_str(&format!("{}:{}\n", hit.path, hit.line_num));
        }
        if total > limit {
            out.push_str(&format!("... and {} more results\n", total - limit));
        }
        if out.is_empty() {
            out.push_str("No occurrences found.");
        }
        Ok(CallToolResult::success(vec![Content::text(out)]))
    }

    /// Get the structural outline of a file: all symbols, imports, language, and metadata.
    #[tool(name = "get_outline")]
    async fn get_outline(
        &self,
        Parameters(params): Parameters<GetOutlineParams>,
    ) -> Result<CallToolResult, ErrorData> {
        self.wait_for_index().await;
        let path = PathBuf::from(&params.path);
        match self.indexer.get_outline(&path) {
            Some(outline) => {
                let json = serde_json::to_string_pretty(&outline)
                    .unwrap_or_else(|e| format!("Serialization error: {e}"));
                Ok(CallToolResult::success(vec![Content::text(json)]))
            }
            None => Ok(CallToolResult::error(vec![Content::text(format!(
                "No outline found for: {} (is it indexed?)",
                params.path
            ))])),
        }
    }

    /// Get the directory tree of the indexed workspace with symbol counts per file.
    #[tool(name = "get_tree")]
    async fn get_tree(&self) -> Result<CallToolResult, ErrorData> {
        self.wait_for_index().await;
        let tree = self.indexer.get_tree();
        let json = serde_json::to_string_pretty(&tree)
            .unwrap_or_else(|e| format!("Serialization error: {e}"));
        Ok(CallToolResult::success(vec![Content::text(json)]))
    }

    /// Get which files import (depend on) the given file.
    #[tool(name = "get_imported_by")]
    async fn get_imported_by(
        &self,
        Parameters(params): Parameters<DepsParams>,
    ) -> Result<CallToolResult, ErrorData> {
        self.wait_for_index().await;
        let path = PathBuf::from(&params.path);
        let deps = self.indexer.get_imported_by(&path);
        if deps.is_empty() {
            return Ok(CallToolResult::success(vec![Content::text(
                "No reverse dependencies found.",
            )]));
        }
        let out: String = deps
            .iter()
            .map(|p| format!("{}\n", p.display()))
            .collect();
        Ok(CallToolResult::success(vec![Content::text(out)]))
    }

    /// Get which files the given file imports (forward dependencies).
    #[tool(name = "get_imports")]
    async fn get_imports(
        &self,
        Parameters(params): Parameters<DepsParams>,
    ) -> Result<CallToolResult, ErrorData> {
        self.wait_for_index().await;
        let path = PathBuf::from(&params.path);
        let imports = self.indexer.get_imports(&path);
        if imports.is_empty() {
            return Ok(CallToolResult::success(vec![Content::text(
                "No imports found.",
            )]));
        }
        let out: String = imports
            .iter()
            .map(|p| format!("{}\n", p.display()))
            .collect();
        Ok(CallToolResult::success(vec![Content::text(out)]))
    }

    /// Get recently changed files, sorted by change sequence (newest first).
    #[tool(name = "get_hot_files")]
    async fn get_hot_files(
        &self,
        Parameters(params): Parameters<HotFilesParams>,
    ) -> Result<CallToolResult, ErrorData> {
        self.wait_for_index().await;
        let limit = params.limit.unwrap_or(20);
        let files = self.indexer.get_hot_files(limit);
        if files.is_empty() {
            return Ok(CallToolResult::success(vec![Content::text(
                "No change history.",
            )]));
        }
        let mut out = String::new();
        for (path, change) in &files {
            out.push_str(&format!(
                "{} — {:?} (seq {})\n",
                path.display(),
                change.op,
                change.seq,
            ));
        }
        Ok(CallToolResult::success(vec![Content::text(out)]))
    }

    /// Get index status: file count, symbol count, indexing state.
    #[tool(name = "status")]
    async fn status(&self) -> Result<CallToolResult, ErrorData> {
        #[derive(Serialize)]
        struct Status {
            files: usize,
            symbols: usize,
            indexing: bool,
            latest_seq: u64,
        }
        let s = Status {
            files: self.indexer.file_count(),
            symbols: self.indexer.symbol_count(),
            indexing: self.indexer.is_indexing(),
            latest_seq: self.indexer.latest_seq(),
        };
        let json = serde_json::to_string_pretty(&s).unwrap();
        Ok(CallToolResult::success(vec![Content::text(json)]))
    }

    /// Run a code analysis on the indexed workspace. Available analyses: dead_code, crossref, security, unwrap_audit, test_coverage, type_drift, architecture, db_schema, migration_parity, manifest_compliance.
    #[tool(name = "analyze")]
    async fn analyze(
        &self,
        Parameters(params): Parameters<AnalysisParams>,
    ) -> Result<CallToolResult, ErrorData> {
        self.wait_for_index().await;
        let explorer = self.indexer.explorer();
        let json = match params.analysis.as_str() {
            "dead_code" => serde_json::to_string_pretty(&analysis::find_dead_code(explorer)),
            "crossref" => serde_json::to_string_pretty(&analysis::cross_reference(explorer)),
            "security" => serde_json::to_string_pretty(&analysis::security_scan(explorer)),
            "unwrap_audit" => serde_json::to_string_pretty(&analysis::audit_unwraps(explorer)),
            "test_coverage" => {
                serde_json::to_string_pretty(&analysis::analyze_test_coverage(explorer))
            }
            "type_drift" => serde_json::to_string_pretty(&analysis::type_drift(explorer)),
            "architecture" => {
                serde_json::to_string_pretty(&analysis::architecture_analysis(explorer))
            }
            "db_schema" => serde_json::to_string_pretty(&analysis::db_schema_analysis(explorer)),
            "migration_parity" => {
                serde_json::to_string_pretty(&analysis::migration_parity(explorer))
            }
            "manifest_compliance" => {
                serde_json::to_string_pretty(&analysis::manifest_compliance(explorer))
            }
            other => {
                return Ok(CallToolResult::error(vec![Content::text(format!(
                    "Unknown analysis: {other}. Available: dead_code, crossref, security, unwrap_audit, test_coverage, type_drift, architecture, db_schema, migration_parity, manifest_compliance"
                ))]));
            }
        };
        match json {
            Ok(j) => Ok(CallToolResult::success(vec![Content::text(j)])),
            Err(e) => Ok(CallToolResult::error(vec![Content::text(format!(
                "Serialization error: {e}"
            ))])),
        }
    }
}

#[tool_handler]
impl ServerHandler for CodeIndexMcp {
    fn get_info(&self) -> ServerInfo {
        ServerInfo::default()
            .with_server_info(Implementation::new("codeindex", env!("CARGO_PKG_VERSION")))
    }
}

// ── Helpers ──────────────────────────────────────────────────────────────────

fn parse_symbol_kind(s: &str) -> Option<SymbolKind> {
    match s.to_lowercase().as_str() {
        "function" | "fn" => Some(SymbolKind::Function),
        "method" => Some(SymbolKind::Method),
        "struct" => Some(SymbolKind::Struct),
        "enum" => Some(SymbolKind::Enum),
        "union" => Some(SymbolKind::Union),
        "trait" => Some(SymbolKind::Trait),
        "interface" => Some(SymbolKind::Interface),
        "type_alias" | "type" => Some(SymbolKind::TypeAlias),
        "constant" | "const" => Some(SymbolKind::Constant),
        "variable" | "var" => Some(SymbolKind::Variable),
        "import" => Some(SymbolKind::Import),
        "module" | "mod" => Some(SymbolKind::Module),
        "macro" => Some(SymbolKind::Macro),
        "test" => Some(SymbolKind::Test),
        "impl" => Some(SymbolKind::Impl),
        "class" => Some(SymbolKind::Class),
        _ => None,
    }
}

// ── Main ─────────────────────────────────────────────────────────────────────

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Logs to stderr — stdout is the MCP JSON-RPC transport
    tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("warn")),
        )
        .init();

    let cli = Cli::parse();

    let workspace = cli
        .workspace
        .unwrap_or_else(|| std::env::current_dir().expect("cannot determine working directory"));

    tracing::info!("Indexing workspace: {}", workspace.display());

    let mut builder = CodeIndexer::builder()
        .workspace(workspace.clone())
        .project_id(&cli.project_id);

    // Connect to PostgreSQL if DATABASE_URL is set
    #[cfg(feature = "db")]
    if let Some(ref db_url) = cli.database_url {
        tracing::info!("Connecting to PostgreSQL...");
        let pool = sqlx::PgPool::connect(db_url).await?;
        let store = codeindex::db::PgIndexStore::new(pool);
        store.migrate().await?;
        tracing::info!("PostgreSQL connected, migrations applied");
        builder = builder.store(std::sync::Arc::new(store));
    }

    let indexer = Arc::new(builder.build().await);

    // Scan in background so MCP server starts immediately
    let scan_indexer = Arc::clone(&indexer);
    tokio::spawn(async move {
        match scan_indexer.scan().await {
            Ok(count) => tracing::info!("Initial scan complete: {count} files indexed"),
            Err(e) => tracing::warn!("Initial scan error: {e}"),
        }
    });

    let server = CodeIndexMcp::new(indexer);
    let service = server.serve(stdio()).await?;
    service.waiting().await?;

    Ok(())
}

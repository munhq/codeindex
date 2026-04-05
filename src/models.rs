use serde::{Deserialize, Serialize};
use std::path::PathBuf;

// ── Language detection ────────────────────────────────────────────────────────

/// Programming language detected from file extension.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum Language {
    Rust,
    Python,
    TypeScript,
    JavaScript,
    Go,
    Unknown,
}

impl Language {
    pub fn from_path(path: &std::path::Path) -> Self {
        match path.extension().and_then(|e| e.to_str()) {
            Some("rs") => Language::Rust,
            Some("py") | Some("pyi") => Language::Python,
            Some("ts") | Some("tsx") => Language::TypeScript,
            Some("js") | Some("jsx") | Some("mjs") | Some("cjs") => Language::JavaScript,
            Some("go") => Language::Go,
            _ => Language::Unknown,
        }
    }

    pub fn file_extensions(&self) -> &'static [&'static str] {
        match self {
            Language::Rust => &["rs"],
            Language::Python => &["py", "pyi"],
            Language::TypeScript => &["ts", "tsx"],
            Language::JavaScript => &["js", "jsx", "mjs", "cjs"],
            Language::Go => &["go"],
            Language::Unknown => &[],
        }
    }
}

// ── Symbol kinds ──────────────────────────────────────────────────────────────

/// Kind of code symbol. Heuristic-extracted via regex — not AST-accurate.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum SymbolKind {
    Function,
    Method,
    Struct,
    Enum,
    Union,
    Trait,
    Interface,
    TypeAlias,
    Constant,
    Variable,
    Import,
    Module,
    Macro,
    Test,
    Impl,
    Class,
    Comment,
}

impl SymbolKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            SymbolKind::Function => "function",
            SymbolKind::Method => "method",
            SymbolKind::Struct => "struct",
            SymbolKind::Enum => "enum",
            SymbolKind::Union => "union",
            SymbolKind::Trait => "trait",
            SymbolKind::Interface => "interface",
            SymbolKind::TypeAlias => "type_alias",
            SymbolKind::Constant => "constant",
            SymbolKind::Variable => "variable",
            SymbolKind::Import => "import",
            SymbolKind::Module => "module",
            SymbolKind::Macro => "macro",
            SymbolKind::Test => "test",
            SymbolKind::Impl => "impl",
            SymbolKind::Class => "class",
            SymbolKind::Comment => "comment",
        }
    }
}

// ── Symbol ────────────────────────────────────────────────────────────────────

/// A code symbol extracted from a file.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Symbol {
    pub name: String,
    pub kind: SymbolKind,
    pub line_start: usize,
    pub line_end: usize,
    pub detail: Option<String>,
}

// ── FileOutline ───────────────────────────────────────────────────────────────

/// Structural outline of a single file: symbols, imports, metadata.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FileOutline {
    pub path: PathBuf,
    pub language: Language,
    pub line_count: usize,
    pub byte_size: u64,
    pub symbols: Vec<Symbol>,
    pub imports: Vec<String>,
}

// ── Search results ────────────────────────────────────────────────────────────

/// A flat search hit: path + line.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SearchResult {
    pub path: PathBuf,
    pub line_num: usize,
    pub line_text: String,
}

/// A search hit enriched with enclosing symbol scope.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScopedSearchResult {
    pub path: PathBuf,
    pub line_num: usize,
    pub line_text: String,
    pub scope_name: Option<String>,
    pub scope_kind: Option<SymbolKind>,
}

/// A symbol result: path + symbol pair.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SymbolResult {
    pub path: PathBuf,
    pub symbol: Symbol,
}

// ── Change tracking ───────────────────────────────────────────────────────────

/// Operation type for change tracking.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ChangeOp {
    Added,
    Modified,
    Deleted,
}

/// A single change record for version tracking.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChangeRecord {
    pub seq: u64,
    pub path: PathBuf,
    pub op: ChangeOp,
    pub timestamp: std::time::SystemTime,
}

// ── Tree node ─────────────────────────────────────────────────────────────────

/// A node in the directory tree view.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TreeNode {
    pub name: String,
    pub path: PathBuf,
    pub is_dir: bool,
    pub children: Vec<TreeNode>,
    pub symbol_count: Option<usize>,
    pub language: Option<Language>,
    pub line_count: Option<usize>,
}

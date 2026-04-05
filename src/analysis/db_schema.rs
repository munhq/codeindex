//! Cross-reference SQL migrations with code queries.
//!
//! Parses `CREATE TABLE` definitions from migration files and finds
//! SQL query references in Rust source code, then reports orphan tables
//! (defined but never queried) and missing tables (queried but never defined).

use std::collections::{BTreeSet, HashMap};
use std::path::{Path, PathBuf};

use regex::Regex;
use serde::{Deserialize, Serialize};

use crate::explorer::Explorer;

// ── Models ───────────────────────────────────────────────────────────────────

/// Full database schema cross-reference report.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DbSchemaReport {
    pub tables: Vec<TableDef>,
    pub query_refs: Vec<QueryRef>,
    pub orphan_tables: Vec<String>,
    pub missing_tables: Vec<String>,
    pub summary: DbSchemaSummary,
}

/// A table definition extracted from a migration file.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TableDef {
    pub name: String,
    pub columns: Vec<String>,
    pub file: PathBuf,
    pub line: usize,
}

/// A query reference found in application code.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QueryRef {
    pub table: String,
    pub operation: String,
    pub file: PathBuf,
    pub line: usize,
}

/// Summary counts.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DbSchemaSummary {
    pub total_tables: usize,
    pub total_queries: usize,
    pub orphan_count: usize,
    pub missing_count: usize,
}

// ── Regex patterns ───────────────────────────────────────────────────────────

lazy_static::lazy_static! {
    /// Matches CREATE TABLE [IF NOT EXISTS] table_name
    static ref RE_CREATE_TABLE: Regex = Regex::new(
        r#"(?i)CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(\w+)"#
    ).unwrap();

    /// Matches column definitions inside CREATE TABLE (...).
    /// Captures the column name as the first identifier on a line inside the parens.
    static ref RE_COLUMN_DEF: Regex = Regex::new(
        r#"(?m)^\s+(\w+)\s+(?:TEXT|INTEGER|INT|BIGINT|BOOLEAN|BOOL|VARCHAR|CHAR|REAL|FLOAT|DOUBLE|NUMERIC|DECIMAL|TIMESTAMP|TIMESTAMPTZ|DATE|TIME|UUID|BLOB|BYTEA|SERIAL|BIGSERIAL|SMALLINT|JSON|JSONB)"#
    ).unwrap();

    /// SELECT ... FROM table_name
    static ref RE_SELECT_FROM: Regex = Regex::new(
        r#"(?i)SELECT\s+.+?\s+FROM\s+(\w+)"#
    ).unwrap();

    /// INSERT INTO table_name
    static ref RE_INSERT_INTO: Regex = Regex::new(
        r#"(?i)INSERT\s+INTO\s+(\w+)"#
    ).unwrap();

    /// UPDATE table_name
    static ref RE_UPDATE: Regex = Regex::new(
        r#"(?i)UPDATE\s+(\w+)\s+SET"#
    ).unwrap();

    /// DELETE FROM table_name
    static ref RE_DELETE_FROM: Regex = Regex::new(
        r#"(?i)DELETE\s+FROM\s+(\w+)"#
    ).unwrap();
}

/// SQL keywords that should not be treated as table names.
const SQL_KEYWORDS: &[&str] = &[
    "select", "from", "where", "set", "values", "into", "table",
    "create", "drop", "alter", "index", "insert", "update", "delete",
    "join", "left", "right", "inner", "outer", "on", "and", "or",
    "not", "null", "true", "false", "as", "in", "is", "like",
    "order", "by", "group", "having", "limit", "offset", "distinct",
    "exists", "between", "case", "when", "then", "else", "end",
    "count", "sum", "avg", "min", "max", "coalesce",
];

// ── Analysis ─────────────────────────────────────────────────────────────────

/// Run the database schema cross-reference analysis.
pub fn db_schema_analysis(explorer: &Explorer) -> DbSchemaReport {
    let outlines = explorer.get_all_outlines();

    let tables = extract_table_defs(explorer, &outlines);
    let query_refs = extract_query_refs(explorer, &outlines);

    // Build sets for cross-referencing
    let defined_tables: BTreeSet<String> = tables.iter().map(|t| t.name.to_lowercase()).collect();
    let queried_tables: BTreeSet<String> = query_refs.iter().map(|q| q.table.to_lowercase()).collect();

    let orphan_tables: Vec<String> = defined_tables
        .difference(&queried_tables)
        .cloned()
        .collect();

    let missing_tables: Vec<String> = queried_tables
        .difference(&defined_tables)
        .cloned()
        .collect();

    let summary = DbSchemaSummary {
        total_tables: tables.len(),
        total_queries: query_refs.len(),
        orphan_count: orphan_tables.len(),
        missing_count: missing_tables.len(),
    };

    DbSchemaReport {
        tables,
        query_refs,
        orphan_tables,
        missing_tables,
        summary,
    }
}

/// Extract CREATE TABLE definitions from migration files.
fn extract_table_defs(
    explorer: &Explorer,
    outlines: &HashMap<PathBuf, crate::models::FileOutline>,
) -> Vec<TableDef> {
    let mut tables = Vec::new();

    // Check indexed files that live under a migrations/ directory
    for path in outlines.keys() {
        if !is_migration_file(path) {
            continue;
        }
        if let Ok(content) = explorer.filter().read_file(path) {
            extract_tables_from_sql(&content, path, &mut tables);
        }
    }

    // Also try reading migration files directly from workspace root
    let workspace = &explorer.config().workspace_root;
    for migrations_dir in &["migrations", "migrations/sqlite"] {
        let dir = workspace.join(migrations_dir);
        if dir.is_dir() {
            if let Ok(entries) = std::fs::read_dir(&dir) {
                for entry in entries.flatten() {
                    let full_path = entry.path();
                    if full_path.extension().and_then(|e| e.to_str()) == Some("sql") {
                        if let Ok(content) = std::fs::read_to_string(&full_path) {
                            let rel_path = full_path
                                .strip_prefix(workspace)
                                .unwrap_or(&full_path)
                                .to_path_buf();
                            extract_tables_from_sql(&content, &rel_path, &mut tables);
                        }
                    }
                }
            }
        }
    }

    // Deduplicate by table name (keep first occurrence)
    let mut seen = BTreeSet::new();
    tables.retain(|t| seen.insert(t.name.to_lowercase()));

    tables.sort_by(|a, b| a.name.cmp(&b.name));
    tables
}

/// Parse CREATE TABLE statements from a SQL string.
fn extract_tables_from_sql(content: &str, path: &Path, tables: &mut Vec<TableDef>) {
    for cap in RE_CREATE_TABLE.captures_iter(content) {
        let table_name = cap.get(1).unwrap().as_str().to_string();
        let match_start = cap.get(0).unwrap().start();
        let line_num = content[..match_start].matches('\n').count() + 1;

        // Extract columns from the CREATE TABLE block
        let columns = extract_columns(content, match_start);

        tables.push(TableDef {
            name: table_name,
            columns,
            file: path.to_path_buf(),
            line: line_num,
        });
    }
}

/// Extract column names from a CREATE TABLE statement starting at the given offset.
fn extract_columns(content: &str, start: usize) -> Vec<String> {
    let rest = &content[start..];

    // Find the opening paren and its matching close
    let open = match rest.find('(') {
        Some(i) => i,
        None => return Vec::new(),
    };

    let mut depth = 0;
    let mut close = None;
    for (i, ch) in rest[open..].char_indices() {
        match ch {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if depth == 0 {
                    close = Some(open + i);
                    break;
                }
            }
            _ => {}
        }
    }

    let body = match close {
        Some(c) => &rest[open + 1..c],
        None => &rest[open + 1..],
    };

    let mut columns = Vec::new();
    for col_cap in RE_COLUMN_DEF.captures_iter(body) {
        let col_name = col_cap.get(1).unwrap().as_str().to_string();
        if !SQL_KEYWORDS.contains(&col_name.to_lowercase().as_str()) {
            columns.push(col_name);
        }
    }

    columns
}

/// Extract SQL query references from Rust and Go source files.
fn extract_query_refs(
    explorer: &Explorer,
    outlines: &HashMap<PathBuf, crate::models::FileOutline>,
) -> Vec<QueryRef> {
    let mut refs = Vec::new();

    for (path, _outline) in outlines {
        let ext = path.extension().and_then(|e| e.to_str());
        if !matches!(ext, Some("rs") | Some("go")) {
            continue;
        }

        let content = match explorer.filter().read_file(path) {
            Ok(c) => c,
            Err(_) => continue,
        };

        // For Go files, also extract SQL from multi-line backtick strings and
        // const blocks with embedded SQL (e.g., sqlc-generated code).
        if ext == Some("go") {
            extract_go_query_refs(&content, path, &mut refs);
        }

        // Standard per-line SQL pattern matching (works for both Rust and Go
        // single-line SQL strings).
        for (line_idx, line) in content.lines().enumerate() {
            let line_num = line_idx + 1;

            // SELECT ... FROM table
            for cap in RE_SELECT_FROM.captures_iter(line) {
                if let Some(table) = extract_table_name(cap.get(1).unwrap().as_str()) {
                    refs.push(QueryRef {
                        table,
                        operation: "SELECT".to_string(),
                        file: path.clone(),
                        line: line_num,
                    });
                }
            }

            // INSERT INTO table
            for cap in RE_INSERT_INTO.captures_iter(line) {
                if let Some(table) = extract_table_name(cap.get(1).unwrap().as_str()) {
                    refs.push(QueryRef {
                        table,
                        operation: "INSERT".to_string(),
                        file: path.clone(),
                        line: line_num,
                    });
                }
            }

            // UPDATE table SET
            for cap in RE_UPDATE.captures_iter(line) {
                if let Some(table) = extract_table_name(cap.get(1).unwrap().as_str()) {
                    refs.push(QueryRef {
                        table,
                        operation: "UPDATE".to_string(),
                        file: path.clone(),
                        line: line_num,
                    });
                }
            }

            // DELETE FROM table
            for cap in RE_DELETE_FROM.captures_iter(line) {
                if let Some(table) = extract_table_name(cap.get(1).unwrap().as_str()) {
                    refs.push(QueryRef {
                        table,
                        operation: "DELETE".to_string(),
                        file: path.clone(),
                        line: line_num,
                    });
                }
            }
        }
    }

    // Deduplicate refs (Go multi-line extraction may duplicate single-line matches)
    refs.sort_by(|a, b| {
        a.table
            .cmp(&b.table)
            .then(a.file.cmp(&b.file))
            .then(a.line.cmp(&b.line))
            .then(a.operation.cmp(&b.operation))
    });
    refs.dedup_by(|a, b| a.table == b.table && a.file == b.file && a.line == b.line && a.operation == b.operation);
    refs
}

/// Extract SQL references from Go multi-line backtick strings and const blocks.
///
/// Handles patterns like:
///   db.Query(`SELECT ... FROM users WHERE ...`)
///   const selectMarket = `SELECT ... FROM markets WHERE ...`
///   tx.Exec(`INSERT INTO orders (...) VALUES (...)`)
fn extract_go_query_refs(content: &str, path: &Path, refs: &mut Vec<QueryRef>) {
    lazy_static::lazy_static! {
        // Match backtick-delimited strings that span multiple lines
        static ref RE_BACKTICK_STR: Regex = Regex::new(r"`([^`]+)`").unwrap();
    }

    for cap in RE_BACKTICK_STR.captures_iter(content) {
        let sql = cap.get(1).unwrap().as_str();
        let match_start = cap.get(0).unwrap().start();
        let line_num = content[..match_start].matches('\n').count() + 1;

        // Check if the backtick string contains SQL operations
        for sql_cap in RE_SELECT_FROM.captures_iter(sql) {
            if let Some(table) = extract_table_name(sql_cap.get(1).unwrap().as_str()) {
                refs.push(QueryRef {
                    table,
                    operation: "SELECT".to_string(),
                    file: path.to_path_buf(),
                    line: line_num,
                });
            }
        }
        for sql_cap in RE_INSERT_INTO.captures_iter(sql) {
            if let Some(table) = extract_table_name(sql_cap.get(1).unwrap().as_str()) {
                refs.push(QueryRef {
                    table,
                    operation: "INSERT".to_string(),
                    file: path.to_path_buf(),
                    line: line_num,
                });
            }
        }
        for sql_cap in RE_UPDATE.captures_iter(sql) {
            if let Some(table) = extract_table_name(sql_cap.get(1).unwrap().as_str()) {
                refs.push(QueryRef {
                    table,
                    operation: "UPDATE".to_string(),
                    file: path.to_path_buf(),
                    line: line_num,
                });
            }
        }
        for sql_cap in RE_DELETE_FROM.captures_iter(sql) {
            if let Some(table) = extract_table_name(sql_cap.get(1).unwrap().as_str()) {
                refs.push(QueryRef {
                    table,
                    operation: "DELETE".to_string(),
                    file: path.to_path_buf(),
                    line: line_num,
                });
            }
        }
    }
}

/// Validate and normalize a captured table name. Returns None for SQL keywords.
fn extract_table_name(raw: &str) -> Option<String> {
    let name = raw.trim();
    if name.is_empty() || SQL_KEYWORDS.contains(&name.to_lowercase().as_str()) {
        return None;
    }
    Some(name.to_string())
}

/// Check if a path looks like a migration file.
fn is_migration_file(path: &Path) -> bool {
    let path_str = path.to_string_lossy();
    path_str.contains("migrations") && path_str.ends_with(".sql")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::sync::Arc;
    use tempfile::TempDir;

    use crate::config::CodeIndexerConfig;

    fn setup(tmp: &TempDir) -> Explorer {
        let config = CodeIndexerConfig {
            workspace_root: tmp.path().to_path_buf(),
            ..Default::default()
        };
        Explorer::new(Arc::new(config))
    }

    fn write_file(tmp: &TempDir, rel: &str, content: &str) -> PathBuf {
        let full = tmp.path().join(rel);
        if let Some(parent) = full.parent() {
            fs::create_dir_all(parent).unwrap();
        }
        fs::write(&full, content).unwrap();
        PathBuf::from(rel)
    }

    #[test]
    fn extracts_table_defs_from_migrations() {
        let tmp = TempDir::new().unwrap();
        let explorer = setup(&tmp);

        // Write a migration file (won't be indexed by the parser since it's SQL,
        // but we read it directly from the filesystem)
        write_file(&tmp, "migrations/0001_init.sql", r#"
CREATE TABLE users (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    email TEXT UNIQUE
);

CREATE TABLE IF NOT EXISTS posts (
    id INTEGER PRIMARY KEY,
    user_id INTEGER REFERENCES users(id),
    title TEXT NOT NULL,
    body TEXT
);
"#);

        let report = db_schema_analysis(&explorer);
        let table_names: Vec<&str> = report.tables.iter().map(|t| t.name.as_str()).collect();
        assert!(table_names.contains(&"users"), "missing users in {table_names:?}");
        assert!(table_names.contains(&"posts"), "missing posts in {table_names:?}");

        // Check columns were extracted
        let users = report.tables.iter().find(|t| t.name == "users").unwrap();
        assert!(users.columns.contains(&"name".to_string()));
        assert!(users.columns.contains(&"email".to_string()));
    }

    #[test]
    fn extracts_query_refs_from_rust() {
        let tmp = TempDir::new().unwrap();
        let explorer = setup(&tmp);

        let rel = write_file(&tmp, "repo.rs", r#"
fn get_users() {
    sqlx::query!("SELECT id, name FROM users WHERE active = true");
}

fn create_post() {
    sqlx::query!("INSERT INTO posts (title, body) VALUES ($1, $2)");
}

fn update_user() {
    sqlx::query!("UPDATE users SET name = $1 WHERE id = $2");
}

fn remove_post() {
    sqlx::query!("DELETE FROM posts WHERE id = $1");
}
"#);
        explorer.index_file(&rel).unwrap();

        let report = db_schema_analysis(&explorer);
        let ops: Vec<(&str, &str)> = report.query_refs.iter().map(|q| (q.table.as_str(), q.operation.as_str())).collect();
        assert!(ops.contains(&("users", "SELECT")), "missing SELECT users in {ops:?}");
        assert!(ops.contains(&("posts", "INSERT")), "missing INSERT posts in {ops:?}");
        assert!(ops.contains(&("users", "UPDATE")), "missing UPDATE users in {ops:?}");
        assert!(ops.contains(&("posts", "DELETE")), "missing DELETE posts in {ops:?}");
    }

    #[test]
    fn reports_orphan_and_missing_tables() {
        let tmp = TempDir::new().unwrap();
        let explorer = setup(&tmp);

        // Define 'users' and 'sessions' in migrations
        write_file(&tmp, "migrations/0001_init.sql", r#"
CREATE TABLE users (id INTEGER PRIMARY KEY);
CREATE TABLE sessions (id INTEGER PRIMARY KEY);
"#);

        // Only query 'users' and 'orders' in code
        let rel = write_file(&tmp, "repo.rs", r#"
fn get_users() {
    sqlx::query!("SELECT id FROM users");
}
fn get_orders() {
    sqlx::query!("SELECT id FROM orders");
}
"#);
        explorer.index_file(&rel).unwrap();

        let report = db_schema_analysis(&explorer);

        // 'sessions' is defined but never queried → orphan
        assert!(report.orphan_tables.contains(&"sessions".to_string()),
            "expected 'sessions' in orphans: {:?}", report.orphan_tables);

        // 'orders' is queried but never defined → missing
        assert!(report.missing_tables.contains(&"orders".to_string()),
            "expected 'orders' in missing: {:?}", report.missing_tables);
    }

    #[test]
    fn extracts_query_refs_from_go() {
        let tmp = TempDir::new().unwrap();
        let explorer = setup(&tmp);

        let rel = write_file(&tmp, "repo.go", r#"package repo

import "database/sql"

func GetUsers(db *sql.DB) {
    db.Query("SELECT id, name FROM users WHERE active = true")
}

func CreateOrder(db *sql.DB) {
    db.Exec("INSERT INTO orders (user_id, total) VALUES ($1, $2)")
}

func UpdatePosition(db *sql.DB) {
    db.ExecContext(ctx, "UPDATE positions SET size = $1 WHERE id = $2")
}

func DeleteTrade(tx *sql.Tx) {
    tx.Exec("DELETE FROM trades WHERE expired = true")
}
"#);
        explorer.index_file(&rel).unwrap();

        let report = db_schema_analysis(&explorer);
        let ops: Vec<(&str, &str)> = report.query_refs.iter().map(|q| (q.table.as_str(), q.operation.as_str())).collect();
        assert!(ops.contains(&("users", "SELECT")), "missing SELECT users in {ops:?}");
        assert!(ops.contains(&("orders", "INSERT")), "missing INSERT orders in {ops:?}");
        assert!(ops.contains(&("positions", "UPDATE")), "missing UPDATE positions in {ops:?}");
        assert!(ops.contains(&("trades", "DELETE")), "missing DELETE trades in {ops:?}");
    }

    #[test]
    fn extracts_go_backtick_multiline_sql() {
        let tmp = TempDir::new().unwrap();
        let explorer = setup(&tmp);

        let rel = write_file(&tmp, "queries.go", "package repo\n\nimport \"database/sql\"\n\nfunc GetMarket(db *sql.DB) {\n\trows, err := db.Query(`\n\t\tSELECT id, slug, question\n\t\tFROM markets\n\t\tWHERE active = true\n\t`)\n}\n\nconst insertTrade = `INSERT INTO trades (market_id, amount) VALUES ($1, $2)`\n");
        explorer.index_file(&rel).unwrap();

        let report = db_schema_analysis(&explorer);
        let ops: Vec<(&str, &str)> = report.query_refs.iter().map(|q| (q.table.as_str(), q.operation.as_str())).collect();
        assert!(ops.contains(&("markets", "SELECT")), "missing SELECT markets in {ops:?}");
        assert!(ops.contains(&("trades", "INSERT")), "missing INSERT trades in {ops:?}");
    }

    #[test]
    fn summary_counts_match() {
        let tmp = TempDir::new().unwrap();
        let explorer = setup(&tmp);

        write_file(&tmp, "migrations/0001.sql", "CREATE TABLE t1 (id INTEGER);\nCREATE TABLE t2 (id INTEGER);");

        let rel = write_file(&tmp, "q.rs", r#"
fn f() { sqlx::query!("SELECT id FROM t1"); }
"#);
        explorer.index_file(&rel).unwrap();

        let report = db_schema_analysis(&explorer);
        assert_eq!(report.summary.total_tables, report.tables.len());
        assert_eq!(report.summary.total_queries, report.query_refs.len());
        assert_eq!(report.summary.orphan_count, report.orphan_tables.len());
        assert_eq!(report.summary.missing_count, report.missing_tables.len());
    }
}

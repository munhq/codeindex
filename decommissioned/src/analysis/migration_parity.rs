//! Migration parity checker: PostgreSQL vs SQLite.
//!
//! Scans `migrations/` and `migrations/sqlite/` directories for SQL migration
//! files, extracts table definitions, and reports mismatches between the two
//! database backends.

use std::collections::HashMap;
use std::path::PathBuf;

use regex::Regex;
use serde::{Deserialize, Serialize};

use crate::explorer::Explorer;

// ── Models ───────────────────────────────────────────────────────────────────

/// A single migration file parsed from disk.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MigrationDef {
    /// Migration number, e.g. "0001", "0042".
    pub number: String,
    /// Migration name derived from filename, e.g. "sessions".
    pub name: String,
    /// Path to the migration file.
    pub file: PathBuf,
    /// Tables created in this migration (`CREATE TABLE` names).
    pub tables: Vec<String>,
}

/// Schema differences within a single migration number.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SchemaDiff {
    /// The migration identifier (number + name).
    pub migration: String,
    /// Tables found in the PG version.
    pub pg_tables: Vec<String>,
    /// Tables found in the SQLite version.
    pub sqlite_tables: Vec<String>,
    /// Tables in PG but not SQLite.
    pub pg_only_tables: Vec<String>,
    /// Tables in SQLite but not PG.
    pub sqlite_only_tables: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MigrationParitySummary {
    pub total_pg: usize,
    pub total_sqlite: usize,
    pub paired_count: usize,
    pub pg_only_count: usize,
    pub sqlite_only_count: usize,
    pub schema_diff_count: usize,
    pub sequence_issue_count: usize,
}

/// Full migration parity report.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MigrationParityReport {
    /// Migrations present in PG but not SQLite.
    pub pg_only: Vec<MigrationDef>,
    /// Migrations present in SQLite but not PG.
    pub sqlite_only: Vec<MigrationDef>,
    /// Migrations present in both but with different table sets.
    pub schema_diffs: Vec<SchemaDiff>,
    /// Numbering gaps, duplicates, or ordering issues.
    pub sequence_issues: Vec<String>,
    pub summary: MigrationParitySummary,
}

// ── Extraction ───────────────────────────────────────────────────────────────

lazy_static::lazy_static! {
    /// Match filenames like `0042_sessions.sql`.
    static ref RE_MIGRATION_FILE: Regex = Regex::new(
        r#"^(\d{4})_(.+)\.sql$"#
    ).unwrap();

    /// Match `CREATE TABLE [IF NOT EXISTS] name` (case-insensitive).
    static ref RE_CREATE_TABLE: Regex = Regex::new(
        r#"(?i)CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(\w+)"#
    ).unwrap();
}

/// Parse a migration filename into (number, name), or None if it doesn't match.
fn parse_migration_filename(filename: &str) -> Option<(String, String)> {
    RE_MIGRATION_FILE.captures(filename).map(|cap| {
        let number = cap.get(1).unwrap().as_str().to_string();
        let name = cap.get(2).unwrap().as_str().to_string();
        (number, name)
    })
}

/// Extract `CREATE TABLE` names from SQL content.
fn extract_tables(sql: &str) -> Vec<String> {
    RE_CREATE_TABLE
        .captures_iter(sql)
        .map(|cap| cap.get(1).unwrap().as_str().to_string())
        .collect()
}

/// Scan migration files from the explorer's indexed files, filtering by a
/// directory prefix (e.g. "migrations/" for PG, "migrations/sqlite/" for SQLite).
fn scan_migrations(explorer: &Explorer, prefix: &str) -> Vec<MigrationDef> {
    let outlines = explorer.get_all_outlines();
    let mut migrations = Vec::new();

    for (path, _) in &outlines {
        let path_str = path.to_string_lossy();

        // Must be under the given prefix
        if !path_str.starts_with(prefix) {
            continue;
        }

        // Must be a direct child (not in a subdirectory beyond the prefix),
        // unless we're scanning the top-level migrations/ folder — in that
        // case, exclude files under migrations/sqlite/.
        if prefix == "migrations/" && path_str.starts_with("migrations/sqlite/") {
            continue;
        }

        let filename = match path.file_name().and_then(|f| f.to_str()) {
            Some(f) => f,
            None => continue,
        };

        if path.extension().and_then(|e| e.to_str()) != Some("sql") {
            continue;
        }

        let (number, name) = match parse_migration_filename(filename) {
            Some(pair) => pair,
            None => continue,
        };

        let content = match explorer.filter().read_file(path) {
            Ok(c) => c,
            Err(_) => continue,
        };

        let tables = extract_tables(&content);

        migrations.push(MigrationDef {
            number,
            name,
            file: path.clone(),
            tables,
        });
    }

    migrations.sort_by(|a, b| a.number.cmp(&b.number));
    migrations
}

/// Check for sequence issues: gaps and duplicates in migration numbers.
fn check_sequence(migrations: &[MigrationDef], label: &str) -> Vec<String> {
    let mut issues = Vec::new();

    // Check for duplicates
    let mut seen: HashMap<&str, usize> = HashMap::new();
    for m in migrations {
        *seen.entry(&m.number).or_insert(0) += 1;
    }
    for (num, count) in &seen {
        if *count > 1 {
            issues.push(format!(
                "{label}: duplicate migration number {num} ({count} files)"
            ));
        }
    }

    // Check for gaps
    if migrations.len() >= 2 {
        for window in migrations.windows(2) {
            let a: u32 = window[0].number.parse().unwrap_or(0);
            let b: u32 = window[1].number.parse().unwrap_or(0);
            if b > a + 1 {
                issues.push(format!(
                    "{label}: gap in migration sequence between {} and {}",
                    window[0].number, window[1].number
                ));
            }
        }
    }

    issues
}

/// Build the full migration parity report.
pub fn migration_parity(explorer: &Explorer) -> MigrationParityReport {
    let pg_migrations = scan_migrations(explorer, "migrations/");
    let sqlite_migrations = scan_migrations(explorer, "migrations/sqlite/");

    let total_pg = pg_migrations.len();
    let total_sqlite = sqlite_migrations.len();

    // Build lookups by migration number
    let pg_by_num: HashMap<&str, &MigrationDef> =
        pg_migrations.iter().map(|m| (m.number.as_str(), m)).collect();
    let sqlite_by_num: HashMap<&str, &MigrationDef> = sqlite_migrations
        .iter()
        .map(|m| (m.number.as_str(), m))
        .collect();

    // Find PG-only
    let pg_only: Vec<MigrationDef> = pg_migrations
        .iter()
        .filter(|m| !sqlite_by_num.contains_key(m.number.as_str()))
        .cloned()
        .collect();

    // Find SQLite-only
    let sqlite_only: Vec<MigrationDef> = sqlite_migrations
        .iter()
        .filter(|m| !pg_by_num.contains_key(m.number.as_str()))
        .cloned()
        .collect();

    // Find schema diffs in paired migrations
    let mut schema_diffs = Vec::new();
    let mut paired_count = 0;

    for pg in &pg_migrations {
        if let Some(sqlite) = sqlite_by_num.get(pg.number.as_str()) {
            paired_count += 1;

            let pg_only_tables: Vec<String> = pg
                .tables
                .iter()
                .filter(|t| !sqlite.tables.contains(t))
                .cloned()
                .collect();

            let sqlite_only_tables: Vec<String> = sqlite
                .tables
                .iter()
                .filter(|t| !pg.tables.contains(t))
                .cloned()
                .collect();

            if !pg_only_tables.is_empty() || !sqlite_only_tables.is_empty() {
                schema_diffs.push(SchemaDiff {
                    migration: format!("{}_{}", pg.number, pg.name),
                    pg_tables: pg.tables.clone(),
                    sqlite_tables: sqlite.tables.clone(),
                    pg_only_tables,
                    sqlite_only_tables,
                });
            }
        }
    }

    // Check sequence issues
    let mut sequence_issues = Vec::new();
    sequence_issues.extend(check_sequence(&pg_migrations, "PG"));
    sequence_issues.extend(check_sequence(&sqlite_migrations, "SQLite"));

    let summary = MigrationParitySummary {
        total_pg,
        total_sqlite,
        paired_count,
        pg_only_count: pg_only.len(),
        sqlite_only_count: sqlite_only.len(),
        schema_diff_count: schema_diffs.len(),
        sequence_issue_count: sequence_issues.len(),
    };

    MigrationParityReport {
        pg_only,
        sqlite_only,
        schema_diffs,
        sequence_issues,
        summary,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_migration_filename_valid() {
        let (num, name) = parse_migration_filename("0042_sessions.sql").unwrap();
        assert_eq!(num, "0042");
        assert_eq!(name, "sessions");
    }

    #[test]
    fn parse_migration_filename_multi_word() {
        let (num, name) = parse_migration_filename("0001_initial_schema.sql").unwrap();
        assert_eq!(num, "0001");
        assert_eq!(name, "initial_schema");
    }

    #[test]
    fn parse_migration_filename_invalid() {
        assert!(parse_migration_filename("readme.md").is_none());
        assert!(parse_migration_filename("42_short.sql").is_none()); // needs 4 digits
        assert!(parse_migration_filename("0042_sessions.txt").is_none());
    }

    #[test]
    fn extract_tables_basic() {
        let sql = r#"
CREATE TABLE IF NOT EXISTS sessions (
    id TEXT PRIMARY KEY,
    created_at TIMESTAMP NOT NULL
);

CREATE TABLE events (
    id SERIAL PRIMARY KEY,
    session_id TEXT REFERENCES sessions(id)
);
"#;
        let tables = extract_tables(sql);
        assert_eq!(tables, vec!["sessions", "events"]);
    }

    #[test]
    fn extract_tables_case_insensitive() {
        let sql = "create table my_table (id int);";
        let tables = extract_tables(sql);
        assert_eq!(tables, vec!["my_table"]);
    }

    #[test]
    fn check_sequence_detects_gap() {
        let migrations = vec![
            MigrationDef {
                number: "0001".into(),
                name: "init".into(),
                file: PathBuf::from("0001_init.sql"),
                tables: vec![],
            },
            MigrationDef {
                number: "0003".into(),
                name: "users".into(),
                file: PathBuf::from("0003_users.sql"),
                tables: vec![],
            },
        ];
        let issues = check_sequence(&migrations, "PG");
        assert_eq!(issues.len(), 1);
        assert!(issues[0].contains("gap"));
    }

    #[test]
    fn check_sequence_detects_duplicate() {
        let migrations = vec![
            MigrationDef {
                number: "0001".into(),
                name: "init".into(),
                file: PathBuf::from("0001_init.sql"),
                tables: vec![],
            },
            MigrationDef {
                number: "0001".into(),
                name: "init_v2".into(),
                file: PathBuf::from("0001_init_v2.sql"),
                tables: vec![],
            },
        ];
        let issues = check_sequence(&migrations, "PG");
        assert_eq!(issues.len(), 1);
        assert!(issues[0].contains("duplicate"));
    }

    #[test]
    fn check_sequence_clean() {
        let migrations = vec![
            MigrationDef {
                number: "0001".into(),
                name: "init".into(),
                file: PathBuf::from("0001_init.sql"),
                tables: vec![],
            },
            MigrationDef {
                number: "0002".into(),
                name: "users".into(),
                file: PathBuf::from("0002_users.sql"),
                tables: vec![],
            },
        ];
        let issues = check_sequence(&migrations, "PG");
        assert!(issues.is_empty());
    }
}

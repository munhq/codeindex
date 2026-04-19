//! Type drift detection: Rust response structs vs TypeScript type definitions.
//!
//! Scans Rust files for `#[derive(Serialize)]` / `#[derive(Deserialize)]` structs
//! and TypeScript files for `type` / `interface` declarations, then compares
//! field names and types across language boundaries.

use std::collections::HashMap;
use std::path::PathBuf;

use regex::Regex;
use serde::{Deserialize, Serialize};

use crate::explorer::Explorer;

// ── Models ───────────────────────────────────────────────────────────────────

/// A Rust struct extracted from source with serde derives.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RustType {
    pub name: String,
    /// (field_name, field_type)
    pub fields: Vec<(String, String)>,
    pub file: PathBuf,
    pub line: usize,
}

/// A TypeScript type or interface definition.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TsType {
    pub name: String,
    /// (field_name, field_type)
    pub fields: Vec<(String, String)>,
    pub file: PathBuf,
    pub line: usize,
}

/// A matched pair: same type exists in both Rust and TypeScript.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TypeMatch {
    pub name: String,
    pub rust: RustType,
    pub ts: TsType,
}

/// A type that exists in both languages but has field/type differences.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TypeDrift {
    pub name: String,
    pub rust_file: PathBuf,
    pub ts_file: PathBuf,
    /// Fields present in Rust but missing from TypeScript.
    pub missing_in_ts: Vec<String>,
    /// Fields present in TypeScript but missing from Rust.
    pub missing_in_rust: Vec<String>,
    /// (field_name, rust_type, ts_type) where types don't match.
    pub type_mismatches: Vec<(String, String, String)>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TypeDriftSummary {
    pub total_rust_types: usize,
    pub total_ts_types: usize,
    pub matched_count: usize,
    pub drift_count: usize,
    pub unmatched_rust_count: usize,
    pub unmatched_ts_count: usize,
}

/// Full type drift report comparing Rust and TypeScript definitions.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TypeDriftReport {
    pub matches: Vec<TypeMatch>,
    pub drifts: Vec<TypeDrift>,
    pub unmatched_rust: Vec<RustType>,
    pub unmatched_ts: Vec<TsType>,
    pub summary: TypeDriftSummary,
}

// ── Extraction ───────────────────────────────────────────────────────────────

lazy_static::lazy_static! {
    // Match derive attributes containing Serialize or Deserialize (possibly among others).
    // Captures everything up to the next `pub struct Name`.
    static ref RE_SERDE_STRUCT: Regex = Regex::new(
        r#"(?s)#\[derive\([^)]*(?:Serialize|Deserialize)[^)]*\)\]\s*(?:#\[serde[^]]*\]\s*)*pub\s+struct\s+(\w+)\s*\{([^}]*)\}"#
    ).unwrap();

    // Match a single `pub field_name: Type` inside a struct body.
    static ref RE_RUST_FIELD: Regex = Regex::new(
        r#"(?m)^\s*(?:#\[serde[^]]*\]\s*)*pub\s+(\w+)\s*:\s*([^,\n]+)"#
    ).unwrap();

    // TypeScript `type Name = { ... }` (single-level braces).
    static ref RE_TS_TYPE: Regex = Regex::new(
        r#"(?s)(?:export\s+)?type\s+(\w+)\s*=\s*\{([^}]*)\}"#
    ).unwrap();

    // TypeScript `interface Name { ... }` (single-level braces).
    static ref RE_TS_INTERFACE: Regex = Regex::new(
        r#"(?s)(?:export\s+)?interface\s+(\w+)\s*(?:extends\s+\w+\s*)?\{([^}]*)\}"#
    ).unwrap();

    // TypeScript field: `name: type;` or `name?: type;` or `name: type,`
    static ref RE_TS_FIELD: Regex = Regex::new(
        r#"(?m)^\s*(\w+)\s*\??\s*:\s*([^;,\n]+)"#
    ).unwrap();
}

/// Extract Rust types that have serde derives from indexed files.
pub fn extract_rust_types(explorer: &Explorer) -> Vec<RustType> {
    let outlines = explorer.get_all_outlines();
    let mut types = Vec::new();

    for (path, _) in &outlines {
        if path.extension().and_then(|e| e.to_str()) != Some("rs") {
            continue;
        }

        let content = match explorer.filter().read_file(path) {
            Ok(c) => c,
            Err(_) => continue,
        };

        for cap in RE_SERDE_STRUCT.captures_iter(&content) {
            let name = cap.get(1).unwrap().as_str().to_string();
            let body = cap.get(2).unwrap().as_str();
            let match_start = cap.get(0).unwrap().start();
            let line = content[..match_start].matches('\n').count() + 1;

            let fields: Vec<(String, String)> = RE_RUST_FIELD
                .captures_iter(body)
                .map(|fc| {
                    let field_name = fc.get(1).unwrap().as_str().to_string();
                    let field_type = fc.get(2).unwrap().as_str().trim().to_string();
                    // Strip trailing comma if present
                    let field_type = field_type.trim_end_matches(',').trim().to_string();
                    (field_name, field_type)
                })
                .collect();

            types.push(RustType {
                name,
                fields,
                file: path.clone(),
                line,
            });
        }
    }

    types.sort_by(|a, b| a.name.cmp(&b.name));
    types
}

/// Extract TypeScript type and interface definitions from indexed files.
pub fn extract_ts_types(explorer: &Explorer) -> Vec<TsType> {
    let outlines = explorer.get_all_outlines();
    let mut types = Vec::new();

    for (path, _) in &outlines {
        let ext = path.extension().and_then(|e| e.to_str());
        if !matches!(ext, Some("ts") | Some("tsx")) {
            continue;
        }

        let content = match explorer.filter().read_file(path) {
            Ok(c) => c,
            Err(_) => continue,
        };

        // Extract from `type Name = { ... }`
        for cap in RE_TS_TYPE.captures_iter(&content) {
            let name = cap.get(1).unwrap().as_str().to_string();
            let body = cap.get(2).unwrap().as_str();
            let match_start = cap.get(0).unwrap().start();
            let line = content[..match_start].matches('\n').count() + 1;

            let fields = extract_ts_fields(body);
            types.push(TsType {
                name,
                fields,
                file: path.clone(),
                line,
            });
        }

        // Extract from `interface Name { ... }`
        for cap in RE_TS_INTERFACE.captures_iter(&content) {
            let name = cap.get(1).unwrap().as_str().to_string();
            let body = cap.get(2).unwrap().as_str();
            let match_start = cap.get(0).unwrap().start();
            let line = content[..match_start].matches('\n').count() + 1;

            let fields = extract_ts_fields(body);
            types.push(TsType {
                name,
                fields,
                file: path.clone(),
                line,
            });
        }
    }

    types.sort_by(|a, b| a.name.cmp(&b.name));
    types
}

fn extract_ts_fields(body: &str) -> Vec<(String, String)> {
    RE_TS_FIELD
        .captures_iter(body)
        .map(|fc| {
            let field_name = fc.get(1).unwrap().as_str().to_string();
            let field_type = fc.get(2).unwrap().as_str().trim().to_string();
            let field_type = field_type.trim_end_matches(';').trim().to_string();
            (field_name, field_type)
        })
        .collect()
}

// ── Go extraction ───────────────────────────────────────────────────────────

lazy_static::lazy_static! {
    /// Match `type Name struct { ... }` in Go (captures name and body).
    static ref RE_GO_STRUCT: Regex = Regex::new(
        r#"(?s)type\s+(\w+)\s+struct\s*\{([^}]*)\}"#
    ).unwrap();

    /// Match a Go struct field with a json tag: `FieldName Type `json:"tag_name"``
    /// Also matches fields without json tags.
    static ref RE_GO_FIELD: Regex = Regex::new(
        r#"(?m)^\s+(\w+)\s+([\w.*\[\]]+(?:\[[\w.]+\][\w.*]*)?)\s*(?:`[^`]*json:"([^"]*)"[^`]*`)?"#
    ).unwrap();
}

/// Map a Go type to its TypeScript equivalent.
fn go_type_to_ts(go_type: &str) -> String {
    let t = go_type.trim();

    // Pointer *T → T | null
    if let Some(inner) = t.strip_prefix('*') {
        let inner_ts = go_type_to_ts(inner);
        return format!("{inner_ts} | null");
    }

    // Slice []T → T[]
    if let Some(inner) = t.strip_prefix("[]") {
        let inner_ts = go_type_to_ts(inner);
        return format!("{inner_ts}[]");
    }

    // map[K]V → Record<K, V>
    if let Some(rest) = t.strip_prefix("map[") {
        // Find the closing bracket for the key type
        if let Some(bracket_end) = rest.find(']') {
            let key = &rest[..bracket_end];
            let val = &rest[bracket_end + 1..];
            let k_ts = go_type_to_ts(key);
            let v_ts = go_type_to_ts(val);
            return format!("Record<{k_ts}, {v_ts}>");
        }
    }

    match t {
        "string" => "string".to_string(),
        "bool" => "boolean".to_string(),
        "int" | "int8" | "int16" | "int32" | "int64" | "uint" | "uint8" | "uint16"
        | "uint32" | "uint64" | "float32" | "float64" | "byte" | "rune" => "number".to_string(),
        "time.Time" => "string".to_string(),
        "interface{}" | "any" => "any".to_string(),
        other => other.to_string(),
    }
}

/// Convert a Go PascalCase field name to camelCase.
fn pascal_to_camel(s: &str) -> String {
    if s.is_empty() {
        return String::new();
    }
    let mut chars = s.chars();
    let first = chars.next().unwrap();
    first.to_lowercase().collect::<String>() + chars.as_str()
}

/// Extract Go struct types with their fields from indexed `.go` files.
/// Reuses the `RustType` struct since it has the same shape.
pub fn extract_go_types(explorer: &Explorer) -> Vec<RustType> {
    let outlines = explorer.get_all_outlines();
    let mut types = Vec::new();

    for (path, _) in &outlines {
        if path.extension().and_then(|e| e.to_str()) != Some("go") {
            continue;
        }

        let content = match explorer.filter().read_file(path) {
            Ok(c) => c,
            Err(_) => continue,
        };

        for cap in RE_GO_STRUCT.captures_iter(&content) {
            let name = cap.get(1).unwrap().as_str().to_string();
            let body = cap.get(2).unwrap().as_str();
            let match_start = cap.get(0).unwrap().start();
            let line = content[..match_start].matches('\n').count() + 1;

            let fields: Vec<(String, String)> = RE_GO_FIELD
                .captures_iter(body)
                .filter_map(|fc| {
                    let go_field_name = fc.get(1).unwrap().as_str();
                    let go_type = fc.get(2).unwrap().as_str();

                    // Skip embedded struct fields (single word starting uppercase, no type)
                    // These are handled by the struct name itself

                    // Determine the JSON field name: use json tag if present,
                    // otherwise convert Go field name to camelCase
                    let json_name = if let Some(tag) = fc.get(3) {
                        let tag_str = tag.as_str();
                        // json:"name,omitempty" → take "name" part
                        let name_part = tag_str.split(',').next().unwrap_or(tag_str);
                        if name_part == "-" {
                            return None; // json:"-" means skip
                        }
                        name_part.to_string()
                    } else {
                        pascal_to_camel(go_field_name)
                    };

                    let ts_type = go_type_to_ts(go_type);
                    Some((json_name, ts_type))
                })
                .collect();

            types.push(RustType {
                name,
                fields,
                file: path.clone(),
                line,
            });
        }
    }

    types.sort_by(|a, b| a.name.cmp(&b.name));
    types
}

// ── Matching & Comparison ────────────────────────────────────────────────────

/// Convert `snake_case` to `PascalCase` for name matching.
fn snake_to_pascal(s: &str) -> String {
    s.split('_')
        .map(|part| {
            let mut chars = part.chars();
            match chars.next() {
                None => String::new(),
                Some(c) => c.to_uppercase().collect::<String>() + chars.as_str(),
            }
        })
        .collect()
}

/// Convert Rust `snake_case` field name to JS `camelCase`.
fn snake_to_camel(s: &str) -> String {
    let mut result = String::new();
    let mut capitalize_next = false;
    for (i, part) in s.split('_').enumerate() {
        if i == 0 {
            result.push_str(part);
        } else if part.is_empty() {
            capitalize_next = true;
        } else {
            let mut chars = part.chars();
            if capitalize_next || i > 0 {
                if let Some(c) = chars.next() {
                    result.extend(c.to_uppercase());
                    result.push_str(chars.as_str());
                }
            } else {
                result.push_str(part);
            }
            capitalize_next = false;
        }
    }
    result
}

/// Map a Rust type string to its expected TypeScript equivalent.
fn rust_type_to_ts(rust_type: &str) -> String {
    let t = rust_type.trim();

    // Option<T> → T | null
    if let Some(inner) = t.strip_prefix("Option<").and_then(|s| s.strip_suffix('>')) {
        let inner_ts = rust_type_to_ts(inner);
        return format!("{inner_ts} | null");
    }

    // Vec<T> → T[]
    if let Some(inner) = t.strip_prefix("Vec<").and_then(|s| s.strip_suffix('>')) {
        let inner_ts = rust_type_to_ts(inner);
        return format!("{inner_ts}[]");
    }

    // HashMap<K, V> → Record<K, V>
    if let Some(inner) = t.strip_prefix("HashMap<").and_then(|s| s.strip_suffix('>')) {
        if let Some((k, v)) = inner.split_once(',') {
            let k_ts = rust_type_to_ts(k.trim());
            let v_ts = rust_type_to_ts(v.trim());
            return format!("Record<{k_ts}, {v_ts}>");
        }
    }

    // Primitive mappings
    match t {
        "String" | "&str" | "Cow<'_, str>" | "Cow<str>" => "string".to_string(),
        "bool" => "boolean".to_string(),
        "i8" | "i16" | "i32" | "i64" | "i128" | "isize" | "u8" | "u16" | "u32" | "u64"
        | "u128" | "usize" | "f32" | "f64" => "number".to_string(),
        "Value" | "serde_json::Value" | "JsonValue" => "any".to_string(),
        "()" => "void".to_string(),
        other => other.to_string(),
    }
}

/// Check if a Rust type (mapped to TS) is compatible with a TS type declaration.
fn types_compatible(rust_type: &str, ts_type: &str) -> bool {
    let mapped = rust_type_to_ts(rust_type);
    let mapped_norm = normalize_ts_type(&mapped);
    let ts_norm = normalize_ts_type(ts_type);

    if mapped_norm == ts_norm {
        return true;
    }

    // Option<T> can match `T | null`, `T | undefined`, `T?`, or just `T`
    // (since serde skip_serializing_if = "Option::is_none" is common)
    if rust_type.starts_with("Option<") {
        let inner = rust_type
            .strip_prefix("Option<")
            .and_then(|s| s.strip_suffix('>'))
            .unwrap_or(rust_type);
        let inner_mapped = normalize_ts_type(&rust_type_to_ts(inner));
        if ts_norm == inner_mapped
            || ts_norm == format!("{inner_mapped} | null")
            || ts_norm == format!("{inner_mapped} | undefined")
        {
            return true;
        }
    }

    false
}

/// Normalize a TS type string for comparison (lowercase, strip whitespace).
fn normalize_ts_type(t: &str) -> String {
    t.split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_lowercase()
}

/// Build the full type drift report.
///
/// Compares Rust and Go backend types against TypeScript frontend types.
/// Go types are included alongside Rust types (both reuse the `RustType` struct).
pub fn type_drift(explorer: &Explorer) -> TypeDriftReport {
    let mut rust_types = extract_rust_types(explorer);
    let go_types = extract_go_types(explorer);
    rust_types.extend(go_types);

    let ts_types = extract_ts_types(explorer);

    let total_rust = rust_types.len();
    let total_ts = ts_types.len();

    // Build lookup: TS type name → Vec<TsType>
    let mut ts_by_name: HashMap<String, Vec<TsType>> = HashMap::new();
    for t in &ts_types {
        ts_by_name
            .entry(t.name.clone())
            .or_default()
            .push(t.clone());
    }

    let mut matches = Vec::new();
    let mut drifts = Vec::new();
    let mut matched_rust_names: Vec<String> = Vec::new();
    let mut matched_ts_names: Vec<String> = Vec::new();

    for rt in &rust_types {
        // Try exact name match first, then snake_case→PascalCase
        let pascal = snake_to_pascal(&rt.name);
        let candidates: Vec<String> = vec![rt.name.clone(), pascal]
            .into_iter()
            .filter(|n| ts_by_name.contains_key(n.as_str()))
            .collect();

        let ts_name = match candidates.first() {
            Some(n) => n.clone(),
            None => continue,
        };

        let ts_list = match ts_by_name.get(&ts_name) {
            Some(list) => list,
            None => continue,
        };

        // Take the first matching TS type (could be refined to pick best match)
        let tt = &ts_list[0];

        matched_rust_names.push(rt.name.clone());
        matched_ts_names.push(ts_name.clone());

        // Compare fields
        let (missing_in_ts, missing_in_rust, type_mismatches) =
            compare_fields(&rt.fields, &tt.fields);

        if missing_in_ts.is_empty() && missing_in_rust.is_empty() && type_mismatches.is_empty() {
            matches.push(TypeMatch {
                name: rt.name.clone(),
                rust: rt.clone(),
                ts: tt.clone(),
            });
        } else {
            drifts.push(TypeDrift {
                name: rt.name.clone(),
                rust_file: rt.file.clone(),
                ts_file: tt.file.clone(),
                missing_in_ts,
                missing_in_rust,
                type_mismatches,
            });
        }
    }

    let unmatched_rust: Vec<RustType> = rust_types
        .into_iter()
        .filter(|rt| !matched_rust_names.contains(&rt.name))
        .collect();

    let unmatched_ts: Vec<TsType> = ts_types
        .into_iter()
        .filter(|tt| !matched_ts_names.contains(&tt.name))
        .collect();

    let summary = TypeDriftSummary {
        total_rust_types: total_rust,
        total_ts_types: total_ts,
        matched_count: matches.len(),
        drift_count: drifts.len(),
        unmatched_rust_count: unmatched_rust.len(),
        unmatched_ts_count: unmatched_ts.len(),
    };

    TypeDriftReport {
        matches,
        drifts,
        unmatched_rust,
        unmatched_ts,
        summary,
    }
}

/// Compare Rust fields against TS fields, accounting for snake_case→camelCase.
/// Returns (missing_in_ts, missing_in_rust, type_mismatches).
fn compare_fields(
    rust_fields: &[(String, String)],
    ts_fields: &[(String, String)],
) -> (Vec<String>, Vec<String>, Vec<(String, String, String)>) {
    let mut missing_in_ts = Vec::new();
    let mut missing_in_rust = Vec::new();
    let mut type_mismatches = Vec::new();

    // Build TS field lookup: both original and snake_case variants → (name, type)
    let mut ts_lookup: HashMap<String, (String, String)> = HashMap::new();
    for (name, ty) in ts_fields {
        ts_lookup.insert(name.to_lowercase(), (name.clone(), ty.clone()));
    }

    let mut matched_ts_fields: Vec<String> = Vec::new();

    for (rust_name, rust_type) in rust_fields {
        // Try matching: exact, camelCase, lowercase
        let camel = snake_to_camel(rust_name);
        let lower = rust_name.to_lowercase();
        let camel_lower = camel.to_lowercase();

        let ts_entry = ts_lookup
            .get(&lower)
            .or_else(|| ts_lookup.get(&camel_lower));

        match ts_entry {
            Some((ts_name, ts_type)) => {
                matched_ts_fields.push(ts_name.to_lowercase());
                if !types_compatible(rust_type, ts_type) {
                    type_mismatches.push((
                        rust_name.clone(),
                        rust_type.clone(),
                        ts_type.clone(),
                    ));
                }
            }
            None => {
                missing_in_ts.push(rust_name.clone());
            }
        }
    }

    // Find TS fields not matched by any Rust field
    for (name, _) in ts_fields {
        if !matched_ts_fields.contains(&name.to_lowercase()) {
            missing_in_rust.push(name.clone());
        }
    }

    (missing_in_ts, missing_in_rust, type_mismatches)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn snake_to_camel_converts() {
        assert_eq!(snake_to_camel("agent_id"), "agentId");
        assert_eq!(snake_to_camel("created_at"), "createdAt");
        assert_eq!(snake_to_camel("name"), "name");
        assert_eq!(snake_to_camel("http_status_code"), "httpStatusCode");
    }

    #[test]
    fn snake_to_pascal_converts() {
        assert_eq!(snake_to_pascal("agent_config"), "AgentConfig");
        assert_eq!(snake_to_pascal("my_struct"), "MyStruct");
    }

    #[test]
    fn rust_type_maps_to_ts() {
        assert_eq!(rust_type_to_ts("String"), "string");
        assert_eq!(rust_type_to_ts("bool"), "boolean");
        assert_eq!(rust_type_to_ts("i32"), "number");
        assert_eq!(rust_type_to_ts("u64"), "number");
        assert_eq!(rust_type_to_ts("f64"), "number");
        assert_eq!(rust_type_to_ts("Vec<String>"), "string[]");
        assert_eq!(rust_type_to_ts("Option<i32>"), "number | null");
        assert_eq!(
            rust_type_to_ts("HashMap<String, i32>"),
            "Record<string, number>"
        );
    }

    #[test]
    fn types_compatible_basic() {
        assert!(types_compatible("String", "string"));
        assert!(types_compatible("i32", "number"));
        assert!(types_compatible("bool", "boolean"));
        assert!(types_compatible("Vec<String>", "string[]"));
        assert!(types_compatible("Option<String>", "string | null"));
        // Option<T> is also compatible with just T (serde skip_serializing_if)
        assert!(types_compatible("Option<String>", "string"));
    }

    #[test]
    fn compare_fields_detects_missing_and_mismatched() {
        let rust_fields = vec![
            ("id".to_string(), "String".to_string()),
            ("agent_name".to_string(), "String".to_string()),
            ("count".to_string(), "i32".to_string()),
            ("extra_field".to_string(), "bool".to_string()),
        ];
        let ts_fields = vec![
            ("id".to_string(), "string".to_string()),
            ("agentName".to_string(), "string".to_string()),
            ("count".to_string(), "string".to_string()), // type mismatch
            ("tsOnly".to_string(), "boolean".to_string()),
        ];

        let (missing_ts, missing_rust, mismatches) = compare_fields(&rust_fields, &ts_fields);

        assert_eq!(missing_ts, vec!["extra_field"]);
        assert_eq!(missing_rust, vec!["tsOnly"]);
        assert_eq!(mismatches.len(), 1);
        assert_eq!(mismatches[0].0, "count");
    }

    #[test]
    fn extract_rust_types_parses_serde_structs() {
        let content = r#"
use serde::{Serialize, Deserialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentConfig {
    pub id: String,
    pub name: String,
    pub enabled: bool,
    pub retry_count: Option<i32>,
}

pub struct NotSerde {
    pub field: String,
}
"#;
        let mut found = Vec::new();
        for cap in RE_SERDE_STRUCT.captures_iter(content) {
            let name = cap.get(1).unwrap().as_str().to_string();
            let body = cap.get(2).unwrap().as_str();
            let fields: Vec<(String, String)> = RE_RUST_FIELD
                .captures_iter(body)
                .map(|fc| {
                    let n = fc.get(1).unwrap().as_str().to_string();
                    let t = fc.get(2).unwrap().as_str().trim().trim_end_matches(',').trim().to_string();
                    (n, t)
                })
                .collect();
            found.push((name, fields));
        }

        assert_eq!(found.len(), 1);
        assert_eq!(found[0].0, "AgentConfig");
        assert_eq!(found[0].1.len(), 4);
        assert_eq!(found[0].1[0], ("id".to_string(), "String".to_string()));
        assert_eq!(
            found[0].1[3],
            ("retry_count".to_string(), "Option<i32>".to_string())
        );
    }

    #[test]
    fn extract_ts_types_parses_interfaces() {
        let content = r#"
export interface AgentConfig {
    id: string;
    name: string;
    enabled: boolean;
    retryCount?: number;
}

export type Status = {
    code: number;
    message: string;
}
"#;
        let mut found = Vec::new();
        for cap in RE_TS_INTERFACE.captures_iter(content) {
            let name = cap.get(1).unwrap().as_str().to_string();
            let body = cap.get(2).unwrap().as_str();
            found.push((name, extract_ts_fields(body)));
        }
        for cap in RE_TS_TYPE.captures_iter(content) {
            let name = cap.get(1).unwrap().as_str().to_string();
            let body = cap.get(2).unwrap().as_str();
            found.push((name, extract_ts_fields(body)));
        }

        assert_eq!(found.len(), 2);
        let agent = found.iter().find(|(n, _)| n == "AgentConfig").unwrap();
        assert_eq!(agent.1.len(), 4);

        let status = found.iter().find(|(n, _)| n == "Status").unwrap();
        assert_eq!(status.1.len(), 2);
    }
}

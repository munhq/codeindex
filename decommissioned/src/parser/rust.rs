use regex::Regex;

use crate::models::{Symbol, SymbolKind};

lazy_static::lazy_static! {
    static ref FN_DEF: Regex = Regex::new(r#"^(?:pub(?:\([^)]*\))?\s+)?(?:async\s+)?(?:unsafe\s+)?(?:extern\s+"[^"]*"\s+)?fn\s+(\w+)\s*(?:<[^>]*>)?\s*\("#).unwrap();
    static ref STRUCT_DEF: Regex = Regex::new(r#"^(?:pub(?:\([^)]*\))?\s+)?struct\s+(\w+)"#).unwrap();
    static ref ENUM_DEF: Regex = Regex::new(r#"^(?:pub(?:\([^)]*\))?\s+)?enum\s+(\w+)"#).unwrap();
    static ref TRAIT_DEF: Regex = Regex::new(r#"^(?:pub(?:\([^)]*\))?\s+)?trait\s+(\w+)"#).unwrap();
    static ref TYPE_ALIAS: Regex = Regex::new(r#"^(?:pub(?:\([^)]*\))?\s+)?type\s+(\w+)"#).unwrap();
    static ref CONST_DEF: Regex = Regex::new(r#"^(?:pub(?:\([^)]*\))?\s+)?const\s+(\w+)"#).unwrap();
    static ref STATIC_DEF: Regex = Regex::new(r#"^(?:pub(?:\([^)]*\))?\s+)?static\s+(?:mut\s+)?(\w+)"#).unwrap();
    static ref IMPL_BLOCK: Regex = Regex::new(r#"^(?:pub\s+)?(?:unsafe\s+)?impl(?:\s+<[^>]*>)?\s+(?:\w+\s+for\s+)?(\w+)"#).unwrap();
    static ref MOD_DEF: Regex = Regex::new(r#"^(?:pub(?:\([^)]*\))?\s+)?mod\s+(\w+)"#).unwrap();
    static ref USE_STMT: Regex = Regex::new(r#"^use\s+(.+?);"#).unwrap();
    static ref TEST_ATTR: Regex = Regex::new(r#"^#\[(?:tokio::)?test"#).unwrap();
    static ref MACRO_DEF: Regex = Regex::new(r#"^macro_rules!\s+(\w+)"#).unwrap();
    static ref UNION_DEF: Regex = Regex::new(r#"^(?:pub(?:\([^)]*\))?\s+)?union\s+(\w+)"#).unwrap();
}

pub fn parse(content: &str) -> (Vec<Symbol>, Vec<String>) {
    let mut symbols = Vec::new();
    let mut imports = Vec::new();
    let lines: Vec<&str> = content.lines().collect();
    let mut i = 0;

    while i < lines.len() {
        let line = lines[i].trim_start();

        let is_test = if i + 1 < lines.len() {
            let next_line = lines[i + 1].trim_start();
            TEST_ATTR.is_match(line) && FN_DEF.is_match(next_line)
        } else {
            false
        };

        if is_test {
            if let Some(cap) = FN_DEF.captures(lines[i + 1].trim_start()) {
                let name = cap
                    .get(1)
                    .map(|m| m.as_str())
                    .unwrap_or("unknown")
                    .to_string();
                let line_start = i + 2; // 1-based, the fn line
                let line_end = find_brace_end(&lines, i + 1);
                symbols.push(Symbol {
                    name,
                    kind: SymbolKind::Test,
                    line_start,
                    line_end,
                    detail: None,
                });
                i += 2;
                continue;
            }
        }

        if line.starts_with("#[") {
            i += 1;
            continue;
        }

        if let Some(cap) = FN_DEF.captures(line) {
            let name = cap
                .get(1)
                .map(|m| m.as_str())
                .unwrap_or("unknown")
                .to_string();
            let detail = extract_detail(line);
            let line_end = find_brace_end(&lines, i);
            symbols.push(Symbol {
                name,
                kind: SymbolKind::Function,
                line_start: i + 1,
                line_end,
                detail,
            });
        } else if let Some(cap) = STRUCT_DEF.captures(line) {
            let name = cap
                .get(1)
                .map(|m| m.as_str())
                .unwrap_or("unknown")
                .to_string();
            let line_end = find_brace_end(&lines, i);
            symbols.push(Symbol {
                name,
                kind: SymbolKind::Struct,
                line_start: i + 1,
                line_end,
                detail: None,
            });
        } else if let Some(cap) = ENUM_DEF.captures(line) {
            let name = cap
                .get(1)
                .map(|m| m.as_str())
                .unwrap_or("unknown")
                .to_string();
            let line_end = find_brace_end(&lines, i);
            symbols.push(Symbol {
                name,
                kind: SymbolKind::Enum,
                line_start: i + 1,
                line_end,
                detail: None,
            });
        } else if let Some(cap) = TRAIT_DEF.captures(line) {
            let name = cap
                .get(1)
                .map(|m| m.as_str())
                .unwrap_or("unknown")
                .to_string();
            let line_end = find_brace_end(&lines, i);
            symbols.push(Symbol {
                name,
                kind: SymbolKind::Trait,
                line_start: i + 1,
                line_end,
                detail: None,
            });
        } else if let Some(cap) = TYPE_ALIAS.captures(line) {
            let name = cap
                .get(1)
                .map(|m| m.as_str())
                .unwrap_or("unknown")
                .to_string();
            symbols.push(Symbol {
                name,
                kind: SymbolKind::TypeAlias,
                line_start: i + 1,
                line_end: i + 1,
                detail: None,
            });
        } else if let Some(cap) = CONST_DEF.captures(line) {
            let name = cap
                .get(1)
                .map(|m| m.as_str())
                .unwrap_or("unknown")
                .to_string();
            symbols.push(Symbol {
                name,
                kind: SymbolKind::Constant,
                line_start: i + 1,
                line_end: i + 1,
                detail: None,
            });
        } else if let Some(cap) = STATIC_DEF.captures(line) {
            let name = cap
                .get(1)
                .map(|m| m.as_str())
                .unwrap_or("unknown")
                .to_string();
            symbols.push(Symbol {
                name,
                kind: SymbolKind::Constant,
                line_start: i + 1,
                line_end: i + 1,
                detail: None,
            });
        } else if let Some(cap) = IMPL_BLOCK.captures(line) {
            let name = cap
                .get(1)
                .map(|m| m.as_str())
                .unwrap_or("unknown")
                .to_string();
            let line_end = find_brace_end(&lines, i);
            symbols.push(Symbol {
                name,
                kind: SymbolKind::Impl,
                line_start: i + 1,
                line_end,
                detail: None,
            });
        } else if let Some(cap) = MOD_DEF.captures(line) {
            let name = cap
                .get(1)
                .map(|m| m.as_str())
                .unwrap_or("unknown")
                .to_string();
            let line_end = if line.contains('{') {
                find_brace_end(&lines, i)
            } else {
                i + 1
            };
            symbols.push(Symbol {
                name,
                kind: SymbolKind::Module,
                line_start: i + 1,
                line_end,
                detail: None,
            });
        } else if let Some(cap) = MACRO_DEF.captures(line) {
            let name = cap
                .get(1)
                .map(|m| m.as_str())
                .unwrap_or("unknown")
                .to_string();
            let line_end = find_brace_end(&lines, i);
            symbols.push(Symbol {
                name,
                kind: SymbolKind::Macro,
                line_start: i + 1,
                line_end,
                detail: None,
            });
        } else if let Some(cap) = UNION_DEF.captures(line) {
            let name = cap
                .get(1)
                .map(|m| m.as_str())
                .unwrap_or("unknown")
                .to_string();
            let line_end = find_brace_end(&lines, i);
            symbols.push(Symbol {
                name,
                kind: SymbolKind::Union,
                line_start: i + 1,
                line_end,
                detail: None,
            });
        } else if let Some(cap) = USE_STMT.captures(line) {
            let path = cap.get(1).map(|m| m.as_str()).unwrap_or("").to_string();
            imports.push(path);
        }

        i += 1;
    }

    (symbols, imports)
}

/// Find the closing brace for a block starting at `start_idx` (0-based line index).
/// Counts brace depth, skipping braces inside string literals.
/// Returns 1-based line number of the closing brace, or `start_idx + 1` if no braces found.
fn find_brace_end(lines: &[&str], start_idx: usize) -> usize {
    let mut depth: i32 = 0;
    let mut found_open = false;

    for j in start_idx..lines.len() {
        let line = lines[j];
        let mut in_string = false;
        let mut in_char = false;
        let mut prev = '\0';

        for ch in line.chars() {
            if in_string {
                if ch == '"' && prev != '\\' {
                    in_string = false;
                }
            } else if in_char {
                if ch == '\'' && prev != '\\' {
                    in_char = false;
                }
            } else {
                match ch {
                    '"' => in_string = true,
                    '\'' => in_char = true,
                    '{' => {
                        depth += 1;
                        found_open = true;
                    }
                    '}' => {
                        depth -= 1;
                        if found_open && depth == 0 {
                            return j + 1; // 1-based
                        }
                    }
                    _ => {}
                }
            }
            prev = ch;
        }
    }

    // No closing brace found — return start line (1-based)
    start_idx + 1
}

fn extract_detail(line: &str) -> Option<String> {
    let start = line.find("fn ")?;
    let rest = &line[start..];
    if let Some(pos) = rest.find('{') {
        Some(rest[..pos].trim().to_string())
    } else {
        Some(rest.trim().to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_simple_function() {
        let (symbols, _) = parse("pub fn hello() {}");
        assert_eq!(symbols.len(), 1);
        assert_eq!(symbols[0].name, "hello");
        assert_eq!(symbols[0].kind, SymbolKind::Function);
    }

    #[test]
    fn parses_async_function() {
        let (symbols, _) = parse("pub async fn fetch() {}");
        assert_eq!(symbols.len(), 1);
        assert_eq!(symbols[0].name, "fetch");
    }

    #[test]
    fn parses_struct() {
        let (symbols, _) = parse("pub struct Agent { name: String }");
        assert_eq!(symbols.len(), 1);
        assert_eq!(symbols[0].name, "Agent");
        assert_eq!(symbols[0].kind, SymbolKind::Struct);
    }

    #[test]
    fn parses_enum() {
        let (symbols, _) = parse("pub enum Message { Text(String) }");
        assert_eq!(symbols.len(), 1);
        assert_eq!(symbols[0].name, "Message");
        assert_eq!(symbols[0].kind, SymbolKind::Enum);
    }

    #[test]
    fn parses_trait() {
        let (symbols, _) = parse("pub trait Handler { fn handle(&self); }");
        assert_eq!(symbols.len(), 1);
        assert_eq!(symbols[0].name, "Handler");
        assert_eq!(symbols[0].kind, SymbolKind::Trait);
    }

    #[test]
    fn parses_impl() {
        let (symbols, _) = parse("impl Agent { pub fn new() -> Self { Self {} } }");
        assert_eq!(symbols.len(), 1);
        assert_eq!(symbols[0].name, "Agent");
        assert_eq!(symbols[0].kind, SymbolKind::Impl);
    }

    #[test]
    fn parses_test_function() {
        let (symbols, _) = parse("#[test]\nfn test_something() { assert!(true); }");
        assert_eq!(symbols.len(), 1);
        assert_eq!(symbols[0].name, "test_something");
        assert_eq!(symbols[0].kind, SymbolKind::Test);
    }

    #[test]
    fn parses_tokio_test() {
        let (symbols, _) = parse("#[tokio::test]\nasync fn test_async() {}");
        assert_eq!(symbols.len(), 1);
        assert_eq!(symbols[0].name, "test_async");
        assert_eq!(symbols[0].kind, SymbolKind::Test);
    }

    #[test]
    fn parses_use_statements() {
        let (_, imports) = parse("use std::collections::HashMap;\nuse crate::models::Agent;");
        assert_eq!(imports.len(), 2);
        assert!(imports.contains(&"std::collections::HashMap".to_string()));
    }

    #[test]
    fn parses_mod() {
        let (symbols, _) = parse("pub mod utils;");
        assert_eq!(symbols.len(), 1);
        assert_eq!(symbols[0].name, "utils");
        assert_eq!(symbols[0].kind, SymbolKind::Module);
    }

    #[test]
    fn parses_macro() {
        let (symbols, _) = parse("macro_rules! my_macro { () => {}; }");
        assert_eq!(symbols.len(), 1);
        assert_eq!(symbols[0].name, "my_macro");
        assert_eq!(symbols[0].kind, SymbolKind::Macro);
    }

    #[test]
    fn parses_pub_crate_fn() {
        let (symbols, _) = parse("pub(crate) fn internal() {}");
        assert_eq!(symbols.len(), 1);
        assert_eq!(symbols[0].name, "internal");
    }

    #[test]
    fn parses_unsafe_fn() {
        let (symbols, _) = parse("pub unsafe fn dangerous() {}");
        assert_eq!(symbols.len(), 1);
        assert_eq!(symbols[0].name, "dangerous");
    }

    #[test]
    fn parses_type_alias() {
        let (symbols, _) = parse("pub type Result<T> = std::result::Result<T, Error>;");
        assert_eq!(symbols.len(), 1);
        assert_eq!(symbols[0].name, "Result");
        assert_eq!(symbols[0].kind, SymbolKind::TypeAlias);
    }

    #[test]
    fn parses_const() {
        let (symbols, _) = parse("pub const MAX_SIZE: usize = 1024;");
        assert_eq!(symbols.len(), 1);
        assert_eq!(symbols[0].name, "MAX_SIZE");
        assert_eq!(symbols[0].kind, SymbolKind::Constant);
    }

    #[test]
    fn detail_contains_signature() {
        let (symbols, _) = parse("pub fn hello(name: &str) -> String { name.to_string() }");
        assert!(symbols[0].detail.is_some());
        let detail = symbols[0].detail.as_ref().unwrap();
        assert!(detail.contains("fn hello"));
    }
}

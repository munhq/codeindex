use regex::Regex;

use crate::models::{Symbol, SymbolKind};

lazy_static::lazy_static! {
    static ref FUNC: Regex = Regex::new(r#"^(?:export\s+)?(?:default\s+)?(?:async\s+)?function\s+(\w+)\s*(?:<[^>]*>)?\s*\("#).unwrap();
    static ref ARROW_FN: Regex = Regex::new(r#"^(?:export\s+)?(?:default\s+)?(?:const|let|var)\s+(\w+)\s*=\s*(?:async\s+)?\("#).unwrap();
    static ref CLASS: Regex = Regex::new(r#"^(?:export\s+)?(?:default\s+)?(?:abstract\s+)?class\s+(\w+)"#).unwrap();
    static ref INTERFACE: Regex = Regex::new(r#"^(?:export\s+)?(?:default\s+)?interface\s+(\w+)"#).unwrap();
    static ref TYPE: Regex = Regex::new(r#"^(?:export\s+)?(?:default\s+)?type\s+(\w+)"#).unwrap();
    static ref CONST: Regex = Regex::new(r#"^(?:export\s+)?(?:default\s+)?const\s+(\w+)\s*="#).unwrap();
    static ref IMPORT: Regex = Regex::new(r#"^(?:import\s+(?:type\s+)?(?:(?:\{[^}]*\})|(?:\*\s+as\s+\w+)|(?:\w+))\s+from\s+)?['"]([^'"]+)['"]"#).unwrap();
    static ref IMPORT_FROM: Regex = Regex::new(r#"^import\s+(?:type\s+)?(\w+(?:\.\w+)*)"#).unwrap();
    static ref ENUM: Regex = Regex::new(r#"^(?:export\s+)?(?:default\s+)?enum\s+(\w+)"#).unwrap();
}

pub fn parse(content: &str) -> (Vec<Symbol>, Vec<String>) {
    let mut symbols = Vec::new();
    let mut imports = Vec::new();
    let lines: Vec<&str> = content.lines().collect();

    for (i, line) in lines.iter().enumerate() {
        let line = line.trim();

        if line.is_empty() || line.starts_with("//") || line.starts_with("/*") {
            continue;
        }

        if let Some(cap) = FUNC.captures(line) {
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
        } else if let Some(cap) = ARROW_FN.captures(line) {
            let name = cap
                .get(1)
                .map(|m| m.as_str())
                .unwrap_or("unknown")
                .to_string();
            let line_end = find_brace_end(&lines, i);
            symbols.push(Symbol {
                name,
                kind: SymbolKind::Function,
                line_start: i + 1,
                line_end,
                detail: None,
            });
        } else if let Some(cap) = CLASS.captures(line) {
            let name = cap
                .get(1)
                .map(|m| m.as_str())
                .unwrap_or("unknown")
                .to_string();
            let line_end = find_brace_end(&lines, i);
            symbols.push(Symbol {
                name,
                kind: SymbolKind::Class,
                line_start: i + 1,
                line_end,
                detail: None,
            });
        } else if let Some(cap) = INTERFACE.captures(line) {
            let name = cap
                .get(1)
                .map(|m| m.as_str())
                .unwrap_or("unknown")
                .to_string();
            let line_end = find_brace_end(&lines, i);
            symbols.push(Symbol {
                name,
                kind: SymbolKind::Interface,
                line_start: i + 1,
                line_end,
                detail: None,
            });
        } else if let Some(cap) = TYPE.captures(line) {
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
        } else if let Some(cap) = CONST.captures(line) {
            let name = cap
                .get(1)
                .map(|m| m.as_str())
                .unwrap_or("unknown")
                .to_string();
            if !ARROW_FN.is_match(line) {
                symbols.push(Symbol {
                    name,
                    kind: SymbolKind::Constant,
                    line_start: i + 1,
                    line_end: i + 1,
                    detail: None,
                });
            }
        } else if let Some(cap) = ENUM.captures(line) {
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
        } else if let Some(cap) = IMPORT.captures(line) {
            let path = cap.get(1).map(|m| m.as_str()).unwrap_or("").to_string();
            if !path.is_empty() {
                imports.push(path);
            }
        } else if let Some(cap) = IMPORT_FROM.captures(line) {
            let module = cap.get(1).map(|m| m.as_str()).unwrap_or("").to_string();
            if !module.is_empty() {
                imports.push(module);
            }
        }
    }

    (symbols, imports)
}

/// Find the closing brace for a block starting at `start_idx` (0-based line index).
/// Returns 1-based line number of the closing brace, or `start_idx + 1` if no braces found.
fn find_brace_end(lines: &[&str], start_idx: usize) -> usize {
    let mut depth: i32 = 0;
    let mut found_open = false;

    for j in start_idx..lines.len() {
        let line = lines[j];
        let mut in_string = false;
        let mut string_char = '"';
        let mut in_template = false;
        let mut prev = '\0';

        for ch in line.chars() {
            if in_string {
                if ch == string_char && prev != '\\' {
                    in_string = false;
                }
            } else if in_template {
                if ch == '`' && prev != '\\' {
                    in_template = false;
                }
                // Note: we intentionally don't track ${} inside templates
                // because nested braces inside template literals are rare
                // in symbol definitions
            } else {
                match ch {
                    '"' | '\'' => {
                        in_string = true;
                        string_char = ch;
                    }
                    '`' => in_template = true,
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

    start_idx + 1
}

fn extract_detail(line: &str) -> Option<String> {
    let start = line.find("function ")?;
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
    fn parses_function() {
        let (symbols, _) = parse("export function hello() {}");
        assert_eq!(symbols.len(), 1);
        assert_eq!(symbols[0].name, "hello");
        assert_eq!(symbols[0].kind, SymbolKind::Function);
    }

    #[test]
    fn parses_async_function() {
        let (symbols, _) = parse("export async function fetch(url) {}");
        assert_eq!(symbols.len(), 1);
        assert_eq!(symbols[0].name, "fetch");
    }

    #[test]
    fn parses_class() {
        let (symbols, _) = parse("export default class Agent {}");
        assert_eq!(symbols.len(), 1);
        assert_eq!(symbols[0].name, "Agent");
        assert_eq!(symbols[0].kind, SymbolKind::Class);
    }

    #[test]
    fn parses_interface() {
        let (symbols, _) = parse("export interface Config { port: number; }");
        assert_eq!(symbols.len(), 1);
        assert_eq!(symbols[0].name, "Config");
        assert_eq!(symbols[0].kind, SymbolKind::Interface);
    }

    #[test]
    fn parses_type_alias() {
        let (symbols, _) = parse("export type Result<T> = T | Error;");
        assert_eq!(symbols.len(), 1);
        assert_eq!(symbols[0].name, "Result");
        assert_eq!(symbols[0].kind, SymbolKind::TypeAlias);
    }

    #[test]
    fn parses_imports() {
        let (_, imports) = parse("import { useState } from 'react';\nimport express from 'express';\nimport type { Config } from './types';");
        assert_eq!(imports.len(), 3);
    }

    #[test]
    fn parses_arrow_function() {
        let (symbols, _) = parse("const handler = (req, res) => {}");
        assert_eq!(symbols.len(), 1);
        assert_eq!(symbols[0].name, "handler");
        assert_eq!(symbols[0].kind, SymbolKind::Function);
    }

    #[test]
    fn parses_enum() {
        let (symbols, _) = parse("export enum Status { Active, Inactive }");
        assert_eq!(symbols.len(), 1);
        assert_eq!(symbols[0].name, "Status");
        assert_eq!(symbols[0].kind, SymbolKind::Enum);
    }
}

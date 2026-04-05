use regex::Regex;

use crate::models::{Symbol, SymbolKind};

lazy_static::lazy_static! {
    static ref FUNC: Regex = Regex::new(r#"^(?:async\s+)?def\s+(\w+)\s*\("#).unwrap();
    static ref CLASS: Regex = Regex::new(r#"^class\s+(\w+)"#).unwrap();
    static ref IMPORT: Regex = Regex::new(r#"^import\s+(.+)"#).unwrap();
    static ref FROM_IMPORT: Regex = Regex::new(r#"^from\s+(\S+)\s+import\s+(.+)"#).unwrap();
}

pub fn parse(content: &str) -> (Vec<Symbol>, Vec<String>) {
    let mut symbols = Vec::new();
    let mut imports = Vec::new();
    let lines: Vec<&str> = content.lines().collect();

    for (i, line) in lines.iter().enumerate() {
        let trimmed = line.trim();

        if trimmed.starts_with('@') {
            continue;
        }

        if trimmed.is_empty() || (trimmed.starts_with('#') && !trimmed.starts_with("#!")) {
            continue;
        }

        if let Some(cap) = FUNC.captures(trimmed) {
            let name = cap
                .get(1)
                .map(|m| m.as_str())
                .unwrap_or("unknown")
                .to_string();
            let kind = if name.starts_with("test_") {
                SymbolKind::Test
            } else if name.starts_with('_') && !name.starts_with("__") {
                SymbolKind::Method
            } else if name.starts_with("__") && name.ends_with("__") {
                SymbolKind::Method
            } else {
                SymbolKind::Function
            };
            let detail = extract_detail(trimmed);
            let def_indent = indent_level(line);
            let line_end = find_indent_end(&lines, i, def_indent);
            symbols.push(Symbol {
                name,
                kind,
                line_start: i + 1,
                line_end,
                detail,
            });
        } else if let Some(cap) = CLASS.captures(trimmed) {
            let name = cap
                .get(1)
                .map(|m| m.as_str())
                .unwrap_or("unknown")
                .to_string();
            let def_indent = indent_level(line);
            let line_end = find_indent_end(&lines, i, def_indent);
            symbols.push(Symbol {
                name,
                kind: SymbolKind::Class,
                line_start: i + 1,
                line_end,
                detail: None,
            });
        } else if let Some(cap) = FROM_IMPORT.captures(trimmed) {
            let module = cap.get(1).map(|m| m.as_str()).unwrap_or("");
            let names = cap.get(2).map(|m| m.as_str()).unwrap_or("");
            imports.push(format!("from {} import {}", module, names));
        } else if let Some(cap) = IMPORT.captures(trimmed) {
            let module = cap.get(1).map(|m| m.as_str()).unwrap_or("").to_string();
            imports.push(module);
        }
    }

    (symbols, imports)
}

/// Count leading spaces (tabs count as 4 spaces).
fn indent_level(line: &str) -> usize {
    let mut level = 0;
    for ch in line.chars() {
        match ch {
            ' ' => level += 1,
            '\t' => level += 4,
            _ => break,
        }
    }
    level
}

/// Find the end of an indentation-based block (def/class).
/// The block ends when we hit a non-blank line at the same or lower indentation
/// level as the def/class line, or at EOF.
/// Returns 1-based line number of the last line in the block.
fn find_indent_end(lines: &[&str], start_idx: usize, def_indent: usize) -> usize {
    let mut last_content_line = start_idx; // 0-based

    for j in (start_idx + 1)..lines.len() {
        let line = lines[j];
        let trimmed = line.trim();

        // Skip blank lines and comment-only lines
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }

        let ind = indent_level(line);
        if ind <= def_indent {
            // This line is at the same or lower indent — block ended before it
            break;
        }

        last_content_line = j;
    }

    last_content_line + 1 // 1-based
}

fn extract_detail(line: &str) -> Option<String> {
    let start = line.find("def ")?;
    let rest = &line[start..];
    if let Some(pos) = rest.find(':') {
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
        let (symbols, _) = parse("def hello():\n    pass");
        assert_eq!(symbols.len(), 1);
        assert_eq!(symbols[0].name, "hello");
        assert_eq!(symbols[0].kind, SymbolKind::Function);
    }

    #[test]
    fn parses_async_function() {
        let (symbols, _) = parse("async def fetch(url):\n    pass");
        assert_eq!(symbols.len(), 1);
        assert_eq!(symbols[0].name, "fetch");
    }

    #[test]
    fn parses_class() {
        let (symbols, _) = parse("class MyClass:\n    pass");
        assert_eq!(symbols.len(), 1);
        assert_eq!(symbols[0].name, "MyClass");
        assert_eq!(symbols[0].kind, SymbolKind::Class);
    }

    #[test]
    fn parses_imports() {
        let (_, imports) = parse("import os\nimport sys\nfrom collections import OrderedDict\nfrom typing import List, Dict");
        assert_eq!(imports.len(), 4);
    }

    #[test]
    fn parses_test_function() {
        let (symbols, _) = parse("def test_something():\n    assert True");
        assert_eq!(symbols.len(), 1);
        assert_eq!(symbols[0].kind, SymbolKind::Test);
    }

    #[test]
    fn skips_decorators() {
        let (symbols, _) = parse("@app.route(\"/\")\ndef index():\n    return \"hello\"");
        assert_eq!(symbols.len(), 1);
        assert_eq!(symbols[0].name, "index");
    }

    #[test]
    fn parses_method_with_self() {
        let (symbols, _) = parse("class Foo:\n    def bar(self, x):\n        pass");
        assert_eq!(symbols.len(), 2);
        assert_eq!(symbols[1].name, "bar");
        // Parser uses naming convention, not scope tracking — "bar" is Function
        assert_eq!(symbols[1].kind, SymbolKind::Function);
    }
}

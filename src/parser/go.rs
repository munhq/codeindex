use regex::Regex;

use crate::models::{Symbol, SymbolKind};

lazy_static::lazy_static! {
    static ref FUNC: Regex = Regex::new(r#"^func\s+(?:\([^)]*\)\s+)?(\w+)\s*\("#).unwrap();
    static ref METHOD: Regex = Regex::new(r#"^func\s+\([^)]*\)\s+(\w+)\s*\("#).unwrap();
    static ref STRUCT: Regex = Regex::new(r#"^type\s+(\w+)\s+struct"#).unwrap();
    static ref IFACE: Regex = Regex::new(r#"^type\s+(\w+)\s+interface"#).unwrap();
    static ref TYPE: Regex = Regex::new(r#"^type\s+(\w+)\s+"#).unwrap();
    static ref IMPORT_SINGLE: Regex = Regex::new(r#"^import\s+(?:"([^"]+)"|'([^']+)')"#).unwrap();
    static ref IMPORT_GROUP_START: Regex = Regex::new(r#"^import\s*\("#).unwrap();
    static ref IMPORT_LINE: Regex = Regex::new(r#""([^"]+)""#).unwrap();
    static ref CONST: Regex = Regex::new(r#"^const\s+(\w+)\s*="#).unwrap();
    static ref VAR: Regex = Regex::new(r#"^var\s+(\w+)\s*="#).unwrap();
}

pub fn parse(content: &str) -> (Vec<Symbol>, Vec<String>) {
    let mut symbols = Vec::new();
    let mut imports = Vec::new();
    let lines: Vec<&str> = content.lines().collect();
    let mut in_import_block = false;

    for (i, line) in lines.iter().enumerate() {
        let line = line.trim();

        if line.is_empty() || line.starts_with("//") {
            continue;
        }

        // Handle grouped import block: import ( ... )
        if in_import_block {
            if line == ")" {
                in_import_block = false;
                continue;
            }
            // Each line inside import block may have: "path" or alias "path"
            if let Some(cap) = IMPORT_LINE.captures(line) {
                let path = cap.get(1).map(|m| m.as_str()).unwrap_or("").to_string();
                if !path.is_empty() {
                    imports.push(path);
                }
            }
            continue;
        }

        if IMPORT_GROUP_START.is_match(line) {
            in_import_block = true;
            continue;
        }

        if let Some(cap) = METHOD.captures(line) {
            let name = cap
                .get(1)
                .map(|m| m.as_str())
                .unwrap_or("unknown")
                .to_string();
            let detail = extract_detail(line);
            let line_end = find_brace_end(&lines, i);
            symbols.push(Symbol {
                name,
                kind: SymbolKind::Method,
                line_start: i + 1,
                line_end,
                detail,
            });
        } else if let Some(cap) = FUNC.captures(line) {
            let name = cap
                .get(1)
                .map(|m| m.as_str())
                .unwrap_or("unknown")
                .to_string();
            let detail = extract_detail(line);
            let line_end = find_brace_end(&lines, i);
            // Go test functions: func TestXxx(t *testing.T)
            let kind = if name.starts_with("Test") && name.len() > 4 {
                SymbolKind::Test
            } else {
                SymbolKind::Function
            };
            symbols.push(Symbol {
                name,
                kind,
                line_start: i + 1,
                line_end,
                detail,
            });
        } else if let Some(cap) = STRUCT.captures(line) {
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
        } else if let Some(cap) = IFACE.captures(line) {
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
            symbols.push(Symbol {
                name,
                kind: SymbolKind::Constant,
                line_start: i + 1,
                line_end: i + 1,
                detail: None,
            });
        } else if let Some(cap) = VAR.captures(line) {
            let name = cap
                .get(1)
                .map(|m| m.as_str())
                .unwrap_or("unknown")
                .to_string();
            symbols.push(Symbol {
                name,
                kind: SymbolKind::Variable,
                line_start: i + 1,
                line_end: i + 1,
                detail: None,
            });
        } else if let Some(cap) = IMPORT_SINGLE.captures(line) {
            let path = cap
                .get(1)
                .or_else(|| cap.get(2))
                .map(|m| m.as_str())
                .unwrap_or("")
                .to_string();
            if !path.is_empty() {
                imports.push(path);
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
        let mut prev = '\0';

        for ch in line.chars() {
            if in_string {
                if ch == string_char && prev != '\\' {
                    in_string = false;
                }
            } else {
                match ch {
                    '"' | '\'' | '`' => {
                        in_string = true;
                        string_char = ch;
                    }
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
    let start = line.find("func ")?;
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
        let (symbols, _) = parse("func main() {}");
        assert_eq!(symbols.len(), 1);
        assert_eq!(symbols[0].name, "main");
        assert_eq!(symbols[0].kind, SymbolKind::Function);
    }

    #[test]
    fn parses_method() {
        let (symbols, _) = parse("func (s *Server) Start() {}");
        assert_eq!(symbols.len(), 1);
        assert_eq!(symbols[0].name, "Start");
        assert_eq!(symbols[0].kind, SymbolKind::Method);
    }

    #[test]
    fn parses_struct() {
        let (symbols, _) = parse("type Config struct { Port int }");
        assert_eq!(symbols.len(), 1);
        assert_eq!(symbols[0].name, "Config");
        assert_eq!(symbols[0].kind, SymbolKind::Struct);
    }

    #[test]
    fn parses_interface() {
        let (symbols, _) = parse("type Handler interface { Handle() }");
        assert_eq!(symbols.len(), 1);
        assert_eq!(symbols[0].name, "Handler");
        assert_eq!(symbols[0].kind, SymbolKind::Interface);
    }

    #[test]
    fn parses_single_imports() {
        let (_, imports) =
            parse("import \"fmt\"\nimport \"net/http\"\nimport \"github.com/gin-gonic/gin\"");
        assert_eq!(imports.len(), 3);
    }

    #[test]
    fn parses_grouped_imports() {
        let code = r#"
import (
    "context"
    "fmt"
    "net/http"

    "github.com/go-chi/chi/v5"
    "github.com/adi/myapp/internal/handlers"
)
"#;
        let (_, imports) = parse(code);
        assert_eq!(imports.len(), 5);
        assert!(imports.contains(&"context".to_string()));
        assert!(imports.contains(&"github.com/go-chi/chi/v5".to_string()));
        assert!(imports.contains(&"github.com/adi/myapp/internal/handlers".to_string()));
    }

    #[test]
    fn parses_aliased_grouped_imports() {
        let code = r#"
import (
    "fmt"
    chi "github.com/go-chi/chi/v5"
    _ "github.com/lib/pq"
)
"#;
        let (_, imports) = parse(code);
        assert_eq!(imports.len(), 3);
        assert!(imports.contains(&"github.com/go-chi/chi/v5".to_string()));
        assert!(imports.contains(&"github.com/lib/pq".to_string()));
    }

    #[test]
    fn parses_const() {
        let (symbols, _) = parse("const MaxRetries = 3");
        assert_eq!(symbols.len(), 1);
        assert_eq!(symbols[0].name, "MaxRetries");
        assert_eq!(symbols[0].kind, SymbolKind::Constant);
    }

    #[test]
    fn parses_type_alias() {
        let (symbols, _) = parse("type UserID string");
        assert_eq!(symbols.len(), 1);
        assert_eq!(symbols[0].name, "UserID");
        assert_eq!(symbols[0].kind, SymbolKind::TypeAlias);
    }
}

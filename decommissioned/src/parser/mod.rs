use std::path::Path;

use crate::models::{FileOutline, Language};

mod go;
mod python;
mod rust;
mod typescript;

/// Detect language from file path and parse into a `FileOutline`.
///
/// Returns `None` for unsupported languages.
///
/// NOTE: These are heuristic regex-based parsers, not AST-accurate.
/// They extract ~80% of symbols correctly. Edge cases (macros,
/// generated code, unusual syntax) may be missed or misclassified.
pub fn parse_file(path: &Path, content: &str) -> Option<FileOutline> {
    let language = Language::from_path(path);
    let line_count = content.lines().count();
    let byte_size = content.len() as u64;

    let (symbols, imports) = match language {
        Language::Rust => rust::parse(content),
        Language::Python => python::parse(content),
        Language::TypeScript | Language::JavaScript => typescript::parse(content),
        Language::Go => go::parse(content),
        Language::Unknown => return None,
    };

    Some(FileOutline {
        path: path.to_path_buf(),
        language,
        line_count,
        byte_size,
        symbols,
        imports,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_rust() {
        let outline = parse_file(Path::new("main.rs"), "fn main() {}").unwrap();
        assert_eq!(outline.language, Language::Rust);
    }

    #[test]
    fn detects_python() {
        let outline = parse_file(Path::new("main.py"), "def main(): pass").unwrap();
        assert_eq!(outline.language, Language::Python);
    }

    #[test]
    fn detects_typescript() {
        let outline = parse_file(Path::new("main.ts"), "function main() {}").unwrap();
        assert_eq!(outline.language, Language::TypeScript);
    }

    #[test]
    fn detects_go() {
        let outline = parse_file(Path::new("main.go"), "func main() {}").unwrap();
        assert_eq!(outline.language, Language::Go);
    }

    #[test]
    fn returns_none_for_unknown() {
        let result = parse_file(Path::new("main.xyz"), "hello");
        assert!(result.is_none());
    }
}

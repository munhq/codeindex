use std::path::Path;

use ahash::AHashMap;

/// A single hit in the word index.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct WordHit {
    pub path: String,
    pub line_num: usize,
}

/// Inverted word index for O(1) identifier lookup.
///
/// Maps each word (alphanumeric + underscore token) to a list of
/// (path, line_number) pairs. Used for fast symbol/identifier lookup
/// without scanning file contents.
///
/// Not thread-safe — caller must hold appropriate locks.
pub struct WordIndex {
    /// word -> list of hits
    index: AHashMap<String, Vec<WordHit>>,
    /// path -> set of words for efficient removal
    file_words: AHashMap<String, Vec<String>>,
}

impl WordIndex {
    pub fn new() -> Self {
        Self {
            index: AHashMap::new(),
            file_words: AHashMap::new(),
        }
    }

    /// Index all words in a file's content.
    /// Each word is associated with its line number (1-indexed).
    pub fn insert(&mut self, path: &Path, content: &str) {
        let path_key = path.to_string_lossy().to_string();
        let mut words_in_file: Vec<String> = Vec::new();

        for (line_idx, line) in content.lines().enumerate() {
            let words = tokenize(line);
            let mut seen: AHashMap<String, bool> = AHashMap::new();

            for word in words {
                if word.len() < 2 {
                    continue;
                }
                let word_lower = word.to_lowercase();

                // Deduplicate per line
                if seen.contains_key(&word_lower) {
                    continue;
                }
                seen.insert(word_lower.clone(), true);

                let hit = WordHit {
                    path: path_key.clone(),
                    line_num: line_idx + 1,
                };

                self.index.entry(word_lower.clone()).or_default().push(hit);
                words_in_file.push(word_lower);
            }
        }

        self.file_words.insert(path_key, words_in_file);
    }

    /// Remove all word entries for a file path.
    pub fn remove(&mut self, path: &Path) {
        let path_key = path.to_string_lossy().to_string();

        if let Some(words) = self.file_words.remove(&path_key) {
            for word in words {
                if let Some(hits) = self.index.get_mut(&word) {
                    hits.retain(|h| h.path != path_key);
                    if hits.is_empty() {
                        self.index.remove(&word);
                    }
                }
            }
        }
    }

    /// Find all occurrences of a word across all indexed files.
    pub fn search(&self, word: &str) -> Vec<WordHit> {
        let word = word.to_lowercase();
        self.index.get(&word).cloned().unwrap_or_default()
    }

    /// Find occurrences of a word in a specific file.
    pub fn search_in_file(&self, word: &str, path: &Path) -> Vec<WordHit> {
        let path_key = path.to_string_lossy().to_string();
        let word = word.to_lowercase();

        self.index
            .get(&word)
            .map(|hits| {
                hits.iter()
                    .filter(|h| h.path == path_key)
                    .cloned()
                    .collect()
            })
            .unwrap_or_default()
    }

    /// Check if the index is empty.
    pub fn is_empty(&self) -> bool {
        self.index.is_empty()
    }

    /// Number of unique words in the index.
    pub fn word_count(&self) -> usize {
        self.index.len()
    }
}

impl Default for WordIndex {
    fn default() -> Self {
        Self::new()
    }
}

/// Tokenize a line into alphanumeric + underscore words.
fn tokenize(line: &str) -> Vec<&str> {
    let mut tokens = Vec::new();
    let mut start = None;

    for (i, c) in line.char_indices() {
        if c.is_alphanumeric() || c == '_' {
            if start.is_none() {
                start = Some(i);
            }
        } else {
            if let Some(s) = start {
                tokens.push(&line[s..i]);
                start = None;
            }
        }
    }

    if let Some(s) = start {
        tokens.push(&line[s..]);
    }

    tokens
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn insert_and_search() {
        let mut idx = WordIndex::new();
        idx.insert(Path::new("main.rs"), "fn hello_world() { }");

        let hits = idx.search("hello_world");
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].line_num, 1);
    }

    #[test]
    fn search_is_case_insensitive() {
        let mut idx = WordIndex::new();
        idx.insert(Path::new("a.rs"), "fn HelloWorld() {}");

        let hits = idx.search("helloworld");
        assert_eq!(hits.len(), 1);
    }

    #[test]
    fn search_across_files() {
        let mut idx = WordIndex::new();
        idx.insert(Path::new("a.rs"), "struct Agent {}");
        idx.insert(Path::new("b.rs"), "fn agent() {}");
        idx.insert(Path::new("c.rs"), "let agent = Agent::new();");

        let hits = idx.search("agent");
        assert_eq!(hits.len(), 3);
    }

    #[test]
    fn remove_file() {
        let mut idx = WordIndex::new();
        idx.insert(Path::new("a.rs"), "fn hello() {}");
        idx.insert(Path::new("b.rs"), "fn hello() {}");

        assert_eq!(idx.search("hello").len(), 2);

        idx.remove(Path::new("a.rs"));
        assert_eq!(idx.search("hello").len(), 1);
    }

    #[test]
    fn deduplicates_per_line() {
        let mut idx = WordIndex::new();
        idx.insert(Path::new("a.rs"), "hello hello hello");

        let hits = idx.search("hello");
        assert_eq!(hits.len(), 1); // Only one hit per line
    }

    #[test]
    fn multi_line_file() {
        let mut idx = WordIndex::new();
        idx.insert(
            Path::new("a.rs"),
            "fn foo() {}\nfn bar() {}\nfn foo_again() {}",
        );

        let hits = idx.search("foo");
        assert_eq!(hits.len(), 1); // "foo" is an exact token match; "foo_again" is a different token
    }

    #[test]
    fn short_words_skipped() {
        let mut idx = WordIndex::new();
        idx.insert(Path::new("a.rs"), "fn a() { let b = c; }");

        let hits = idx.search("a");
        assert!(hits.is_empty()); // Single char words are skipped
    }

    #[test]
    fn search_in_file() {
        let mut idx = WordIndex::new();
        idx.insert(Path::new("a.rs"), "fn hello() {}");
        idx.insert(Path::new("b.rs"), "fn hello() {}");

        let hits = idx.search_in_file("hello", Path::new("a.rs"));
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].path, "a.rs");
    }

    #[test]
    fn tokenize_splits_correctly() {
        let tokens = tokenize("fn hello_world(arg: &str) -> Result<()>");
        assert!(tokens.contains(&"fn"));
        assert!(tokens.contains(&"hello_world"));
        assert!(tokens.contains(&"arg"));
        assert!(tokens.contains(&"str"));
        assert!(tokens.contains(&"Result"));
    }
}

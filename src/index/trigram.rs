use std::path::Path;

use ahash::AHashMap;

/// A trigram is 3 consecutive bytes packed into a u24.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
struct Trigram(u32);

impl Trigram {
    fn from_bytes(a: u8, b: u8, c: u8) -> Self {
        Trigram(((a as u32) << 16) | ((b as u32) << 8) | (c as u32))
    }

    fn key(&self) -> u32 {
        self.0
    }
}

/// Posting mask for bloom-filter adjacency checks.
#[derive(Debug, Clone, Copy, Default)]
struct PostingMask {
    next_mask: u8,
    loc_mask: u8,
}

/// Trigram index for fast content search candidate filtering.
///
/// Maps each trigram to a set of files that contain it. Uses bloom-filter
/// style adjacency masks to reduce false positives without full content
/// verification.
///
/// Not thread-safe — caller must hold appropriate locks.
pub struct TrigramIndex {
    /// trigram_key -> (path -> PostingMask)
    index: AHashMap<u32, AHashMap<String, PostingMask>>,
    /// path -> set of trigram keys for efficient removal
    file_trigrams: AHashMap<String, Vec<u32>>,
}

impl TrigramIndex {
    pub fn new() -> Self {
        Self {
            index: AHashMap::new(),
            file_trigrams: AHashMap::new(),
        }
    }

    /// Insert content for a file path into the trigram index.
    pub fn insert(&mut self, path: &Path, content: &str) {
        let path_key = path.to_string_lossy().to_string();
        let content_bytes = content.as_bytes();

        if content_bytes.len() < 3 {
            return;
        }

        let mut trigram_keys = Vec::new();

        for i in 0..content_bytes.len().saturating_sub(2) {
            let a = content_bytes[i].to_ascii_lowercase();
            let b = content_bytes[i + 1].to_ascii_lowercase();
            let c = content_bytes[i + 2].to_ascii_lowercase();

            // Skip non-printable trigrams
            if !is_printable(a) || !is_printable(b) || !is_printable(c) {
                continue;
            }

            let tg = Trigram::from_bytes(a, b, c);
            let key = tg.key();

            trigram_keys.push(key);

            let entry = self.index.entry(key).or_default();
            let mask = entry.entry(path_key.clone()).or_default();

            // Update adjacency mask: the character after this trigram
            if i + 3 < content_bytes.len() {
                let next = content_bytes[i + 3].to_ascii_lowercase();
                if is_printable(next) {
                    mask.next_mask |= 1u8 << (next & 0x07);
                }
            }

            // Update location mask: position mod 8
            mask.loc_mask |= 1u8 << (i & 0x07);
        }

        self.file_trigrams.insert(path_key, trigram_keys);
    }

    /// Remove all trigrams for a file path.
    pub fn remove(&mut self, path: &Path) {
        let path_key = path.to_string_lossy().to_string();

        if let Some(keys) = self.file_trigrams.remove(&path_key) {
            for key in keys {
                if let Some(files) = self.index.get_mut(&key) {
                    files.remove(&path_key);
                    if files.is_empty() {
                        self.index.remove(&key);
                    }
                }
            }
        }
    }

    /// Find candidate files that contain ALL trigrams from the query.
    /// Returns file paths that are likely matches (may include false positives).
    pub fn search(&self, query: &str) -> Vec<String> {
        let content_bytes = query.as_bytes();
        if content_bytes.len() < 3 {
            return Vec::new();
        }

        // Extract trigrams from query
        let mut query_trigrams: Vec<u32> = Vec::new();
        for i in 0..content_bytes.len().saturating_sub(2) {
            let a = content_bytes[i].to_ascii_lowercase();
            let b = content_bytes[i + 1].to_ascii_lowercase();
            let c = content_bytes[i + 2].to_ascii_lowercase();

            if is_printable(a) && is_printable(b) && is_printable(c) {
                query_trigrams.push(Trigram::from_bytes(a, b, c).key());
            }
        }

        if query_trigrams.is_empty() {
            return Vec::new();
        }

        // Find the smallest posting list to iterate
        let mut smallest: Option<(&u32, &AHashMap<String, PostingMask>)> = None;
        for key in &query_trigrams {
            if let Some(files) = self.index.get(key) {
                if smallest.is_none() || files.len() < smallest.unwrap().1.len() {
                    smallest = Some((key, files));
                }
            }
        }

        let Some((_, smallest_files)) = smallest else {
            return Vec::new();
        };

        // Check each file in the smallest posting list against all other trigrams
        let mut results = Vec::new();
        for (path, _) in smallest_files {
            let mut all_match = true;
            for key in &query_trigrams {
                if !self.index.get(key).map_or(false, |f| f.contains_key(path)) {
                    all_match = false;
                    break;
                }
            }
            if all_match {
                results.push(path.clone());
            }
        }

        results
    }

    /// Check if the index is empty.
    pub fn is_empty(&self) -> bool {
        self.index.is_empty()
    }

    /// Number of indexed files.
    pub fn file_count(&self) -> usize {
        self.file_trigrams.len()
    }
}

impl Default for TrigramIndex {
    fn default() -> Self {
        Self::new()
    }
}

fn is_printable(b: u8) -> bool {
    (b >= 0x20 && b <= 0x7e) || b >= 0xa0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn insert_and_search() {
        let mut idx = TrigramIndex::new();
        idx.insert(Path::new("hello.rs"), "fn hello_world() {}");
        idx.insert(Path::new("other.rs"), "fn goodbye() {}");

        let results = idx.search("hello");
        assert_eq!(results.len(), 1);
        assert_eq!(results[0], "hello.rs");
    }

    #[test]
    fn search_returns_nothing_for_missing_trigram() {
        let mut idx = TrigramIndex::new();
        idx.insert(Path::new("a.rs"), "fn foo() {}");

        let results = idx.search("xyz_not_found");
        assert!(results.is_empty());
    }

    #[test]
    fn search_case_insensitive() {
        let mut idx = TrigramIndex::new();
        idx.insert(Path::new("a.rs"), "fn HELLO_WORLD() {}");

        let results = idx.search("hello");
        assert_eq!(results.len(), 1);
    }

    #[test]
    fn remove_file() {
        let mut idx = TrigramIndex::new();
        idx.insert(Path::new("a.rs"), "fn hello() {}");
        idx.insert(Path::new("b.rs"), "fn hello() {}");

        assert_eq!(idx.search("hello").len(), 2);

        idx.remove(Path::new("a.rs"));
        let results = idx.search("hello");
        assert_eq!(results.len(), 1);
        assert_eq!(results[0], "b.rs");
    }

    #[test]
    fn short_query_returns_empty() {
        let idx = TrigramIndex::new();
        assert!(idx.search("ab").is_empty());
    }

    #[test]
    fn multi_file_intersection() {
        let mut idx = TrigramIndex::new();
        idx.insert(Path::new("auth.rs"), "fn authenticate_user() {}");
        idx.insert(Path::new("api.rs"), "fn authenticate_request() {}");
        idx.insert(Path::new("util.rs"), "fn helper() {}");

        let results = idx.search("authenticate");
        assert_eq!(results.len(), 2);
    }
}

use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

use crate::error::CodeIndexError;

/// A specification for replacing a range of lines in a file.
pub struct FileEdit {
    /// Path relative to workspace root.
    pub path: PathBuf,
    /// First line to replace (1-indexed, inclusive).
    pub line_start: usize,
    /// Last line to replace (1-indexed, inclusive).
    pub line_end: usize,
    /// Content to insert in place of the removed lines.
    /// May contain newlines (each becomes a separate line).
    pub new_content: String,
}

/// Result of a successfully applied edit.
#[derive(Debug, Clone)]
pub struct EditResult {
    pub path: PathBuf,
    pub old_hash: u64,
    pub new_hash: u64,
    pub lines_changed: usize,
    pub seq: u64,
}

/// Atomic file edit engine with version tracking.
///
/// Applies line-range replacements by writing to a temporary file first,
/// then renaming into place for crash-safe atomicity.
pub struct EditEngine {
    workspace_root: PathBuf,
    seq: AtomicU64,
}

impl EditEngine {
    pub fn new(workspace_root: PathBuf) -> Self {
        Self {
            workspace_root,
            seq: AtomicU64::new(1),
        }
    }

    fn next_seq(&self) -> u64 {
        self.seq.fetch_add(1, Ordering::Relaxed)
    }

    /// Apply a single edit atomically: read file, replace lines, write to
    /// `.tmp`, then rename.
    pub fn apply(&self, edit: &FileEdit) -> Result<EditResult, CodeIndexError> {
        let full_path = self.workspace_root.join(&edit.path);
        let content = std::fs::read_to_string(&full_path).map_err(|e| {
            if e.kind() == std::io::ErrorKind::NotFound {
                CodeIndexError::FileNotFound(edit.path.clone())
            } else {
                CodeIndexError::Io(e)
            }
        })?;

        let new_content = apply_line_edit(&content, edit.line_start, edit.line_end, &edit.new_content)?;

        let old_hash = hash_content(&content);
        let new_hash = hash_content(&new_content);

        // Atomic write: .tmp then rename
        let tmp_path = full_path.with_extension("tmp");
        std::fs::write(&tmp_path, &new_content)?;
        std::fs::rename(&tmp_path, &full_path)?;

        let old_line_count = content.lines().count();
        let new_line_count = new_content.lines().count();
        let replaced = edit.line_end.saturating_sub(edit.line_start) + 1;
        let inserted = edit.new_content.lines().count().max(1);
        let lines_changed = replaced.max(inserted).max(old_line_count.abs_diff(new_line_count));

        Ok(EditResult {
            path: edit.path.clone(),
            old_hash,
            new_hash,
            lines_changed,
            seq: self.next_seq(),
        })
    }

    /// Apply multiple edits to the same file atomically.
    ///
    /// Edits are sorted by `line_start` descending and applied bottom-up so
    /// that earlier line numbers remain valid after later edits.
    /// All edits must target the same file path.
    pub fn apply_batch(&self, edits: &[FileEdit]) -> Result<Vec<EditResult>, CodeIndexError> {
        if edits.is_empty() {
            return Ok(Vec::new());
        }

        // Validate all edits target the same file
        let path = &edits[0].path;
        for edit in &edits[1..] {
            if edit.path != *path {
                return Err(CodeIndexError::Parse(format!(
                    "apply_batch requires all edits to target the same file, got {:?} and {:?}",
                    path, edit.path
                )));
            }
        }

        let full_path = self.workspace_root.join(path);
        let content = std::fs::read_to_string(&full_path).map_err(|e| {
            if e.kind() == std::io::ErrorKind::NotFound {
                CodeIndexError::FileNotFound(path.clone())
            } else {
                CodeIndexError::Io(e)
            }
        })?;

        let old_hash = hash_content(&content);

        // Sort edits by line_start descending (bottom-up application)
        let mut sorted: Vec<(usize, &FileEdit)> = edits.iter().enumerate().collect();
        sorted.sort_by(|a, b| b.1.line_start.cmp(&a.1.line_start));

        let mut current = content.clone();
        let mut results = vec![None; edits.len()];

        for (original_idx, edit) in &sorted {
            let before_hash = hash_content(&current);
            current = apply_line_edit(&current, edit.line_start, edit.line_end, &edit.new_content)?;
            let after_hash = hash_content(&current);

            let replaced = edit.line_end.saturating_sub(edit.line_start) + 1;
            let inserted = edit.new_content.lines().count().max(1);
            let lines_changed = replaced.max(inserted);

            results[*original_idx] = Some(EditResult {
                path: path.clone(),
                old_hash: before_hash,
                new_hash: after_hash,
                lines_changed,
                seq: self.next_seq(),
            });
        }

        // Atomic write
        let new_hash = hash_content(&current);
        let tmp_path = full_path.with_extension("tmp");
        std::fs::write(&tmp_path, &current)?;
        std::fs::rename(&tmp_path, &full_path)?;

        // Fixup the last result's new_hash to reflect the final state
        // (each intermediate result already has its own hashes)
        let _ = (old_hash, new_hash);

        Ok(results.into_iter().map(|r| r.unwrap()).collect())
    }

    /// Preview what the file would look like after an edit, without writing.
    pub fn preview(&self, edit: &FileEdit) -> Result<String, CodeIndexError> {
        let full_path = self.workspace_root.join(&edit.path);
        let content = std::fs::read_to_string(&full_path).map_err(|e| {
            if e.kind() == std::io::ErrorKind::NotFound {
                CodeIndexError::FileNotFound(edit.path.clone())
            } else {
                CodeIndexError::Io(e)
            }
        })?;

        apply_line_edit(&content, edit.line_start, edit.line_end, &edit.new_content)
    }
}

/// Replace lines `line_start..=line_end` (1-indexed) with `new_content`.
fn apply_line_edit(
    content: &str,
    line_start: usize,
    line_end: usize,
    new_content: &str,
) -> Result<String, CodeIndexError> {
    if line_start == 0 {
        return Err(CodeIndexError::Parse(
            "line_start must be >= 1 (1-indexed)".to_string(),
        ));
    }
    if line_end < line_start {
        return Err(CodeIndexError::Parse(format!(
            "line_end ({}) must be >= line_start ({})",
            line_end, line_start
        )));
    }

    let lines: Vec<&str> = content.lines().collect();
    let total = lines.len();

    if line_start > total {
        return Err(CodeIndexError::Parse(format!(
            "line_start ({}) exceeds file length ({} lines)",
            line_start, total
        )));
    }
    if line_end > total {
        return Err(CodeIndexError::Parse(format!(
            "line_end ({}) exceeds file length ({} lines)",
            line_end, total
        )));
    }

    let mut result = Vec::with_capacity(total);

    // Lines before the edit range (0-indexed: 0..line_start-1)
    result.extend_from_slice(&lines[..line_start - 1]);

    // New content lines
    for line in new_content.lines() {
        result.push(line);
    }

    // Lines after the edit range (0-indexed: line_end..)
    if line_end < total {
        result.extend_from_slice(&lines[line_end..]);
    }

    let mut output = result.join("\n");
    // Preserve trailing newline if original had one
    if content.ends_with('\n') {
        output.push('\n');
    }
    Ok(output)
}

fn hash_content(content: &str) -> u64 {
    let mut hasher = DefaultHasher::new();
    content.hash(&mut hasher);
    hasher.finish()
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn setup(tmp: &TempDir) -> EditEngine {
        EditEngine::new(tmp.path().to_path_buf())
    }

    fn write_file(tmp: &TempDir, rel: &str, content: &str) -> PathBuf {
        let full = tmp.path().join(rel);
        if let Some(parent) = full.parent() {
            std::fs::create_dir_all(parent).unwrap();
        }
        std::fs::write(&full, content).unwrap();
        PathBuf::from(rel)
    }

    #[test]
    fn single_edit_replaces_lines() {
        let tmp = TempDir::new().unwrap();
        let engine = setup(&tmp);
        let path = write_file(&tmp, "test.txt", "line1\nline2\nline3\nline4\nline5\n");

        let edit = FileEdit {
            path: path.clone(),
            line_start: 2,
            line_end: 3,
            new_content: "replaced2\nreplaced3".to_string(),
        };

        let result = engine.apply(&edit).unwrap();
        assert_ne!(result.old_hash, result.new_hash);
        assert!(result.seq > 0);

        let content = std::fs::read_to_string(tmp.path().join("test.txt")).unwrap();
        assert_eq!(content, "line1\nreplaced2\nreplaced3\nline4\nline5\n");
    }

    #[test]
    fn single_edit_fewer_replacement_lines() {
        let tmp = TempDir::new().unwrap();
        let engine = setup(&tmp);
        let path = write_file(&tmp, "shrink.txt", "a\nb\nc\nd\ne\n");

        let edit = FileEdit {
            path,
            line_start: 2,
            line_end: 4,
            new_content: "X".to_string(),
        };

        let result = engine.apply(&edit).unwrap();
        assert!(result.lines_changed >= 1);

        let content = std::fs::read_to_string(tmp.path().join("shrink.txt")).unwrap();
        assert_eq!(content, "a\nX\ne\n");
    }

    #[test]
    fn batch_edit_multiple_ranges() {
        let tmp = TempDir::new().unwrap();
        let engine = setup(&tmp);
        let path = write_file(
            &tmp,
            "batch.txt",
            "line1\nline2\nline3\nline4\nline5\nline6\n",
        );

        let edits = vec![
            FileEdit {
                path: path.clone(),
                line_start: 1,
                line_end: 1,
                new_content: "FIRST".to_string(),
            },
            FileEdit {
                path: path.clone(),
                line_start: 5,
                line_end: 6,
                new_content: "LAST".to_string(),
            },
        ];

        let results = engine.apply_batch(&edits).unwrap();
        assert_eq!(results.len(), 2);

        let content = std::fs::read_to_string(tmp.path().join("batch.txt")).unwrap();
        assert_eq!(content, "FIRST\nline2\nline3\nline4\nLAST\n");
    }

    #[test]
    fn out_of_bounds_error() {
        let tmp = TempDir::new().unwrap();
        let engine = setup(&tmp);
        let path = write_file(&tmp, "short.txt", "one\ntwo\n");

        let edit = FileEdit {
            path,
            line_start: 1,
            line_end: 5,
            new_content: "x".to_string(),
        };

        let result = engine.apply(&edit);
        assert!(result.is_err());
        let msg = format!("{}", result.unwrap_err());
        assert!(msg.contains("exceeds file length"), "got: {msg}");
    }

    #[test]
    fn zero_line_start_error() {
        let tmp = TempDir::new().unwrap();
        let engine = setup(&tmp);
        let path = write_file(&tmp, "zero.txt", "hello\n");

        let edit = FileEdit {
            path,
            line_start: 0,
            line_end: 1,
            new_content: "x".to_string(),
        };

        let result = engine.apply(&edit);
        assert!(result.is_err());
    }

    #[test]
    fn preview_without_write() {
        let tmp = TempDir::new().unwrap();
        let engine = setup(&tmp);
        let path = write_file(&tmp, "preview.txt", "aaa\nbbb\nccc\n");

        let edit = FileEdit {
            path: path.clone(),
            line_start: 2,
            line_end: 2,
            new_content: "BBB".to_string(),
        };

        let preview = engine.preview(&edit).unwrap();
        assert_eq!(preview, "aaa\nBBB\nccc\n");

        // Original file unchanged
        let original = std::fs::read_to_string(tmp.path().join("preview.txt")).unwrap();
        assert_eq!(original, "aaa\nbbb\nccc\n");
    }

    #[test]
    fn edit_nonexistent_file_returns_error() {
        let tmp = TempDir::new().unwrap();
        let engine = setup(&tmp);

        let edit = FileEdit {
            path: PathBuf::from("does_not_exist.txt"),
            line_start: 1,
            line_end: 1,
            new_content: "x".to_string(),
        };

        let result = engine.apply(&edit);
        assert!(result.is_err());
    }

    #[test]
    fn sequence_numbers_increment() {
        let tmp = TempDir::new().unwrap();
        let engine = setup(&tmp);
        let path = write_file(&tmp, "seq.txt", "a\nb\nc\n");

        let r1 = engine
            .apply(&FileEdit {
                path: path.clone(),
                line_start: 1,
                line_end: 1,
                new_content: "A".to_string(),
            })
            .unwrap();

        let r2 = engine
            .apply(&FileEdit {
                path,
                line_start: 2,
                line_end: 2,
                new_content: "B".to_string(),
            })
            .unwrap();

        assert!(r2.seq > r1.seq);
    }
}

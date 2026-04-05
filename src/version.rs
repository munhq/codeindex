use std::collections::VecDeque;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::RwLock;
use std::time::SystemTime;

use crate::models::{ChangeOp, ChangeRecord};

/// Maximum number of change records to retain in the ring buffer.
const MAX_CHANGES: usize = 1000;

/// Monotonic version store for change tracking.
///
/// Every file mutation gets a globally unique, monotonically increasing
/// sequence number. Consumers can call `changes_since(seq)` to get all
/// changes since their last known version.
///
/// The ring buffer is capped at `MAX_CHANGES` entries. If a consumer
/// falls behind, `changes_since` returns `truncated: true` so the
/// consumer knows to do a full re-sync.
pub struct VersionStore {
    seq: AtomicU64,
    changes: RwLock<VecDeque<ChangeRecord>>,
}

impl VersionStore {
    pub fn new() -> Self {
        Self {
            seq: AtomicU64::new(1),
            changes: RwLock::new(VecDeque::with_capacity(MAX_CHANGES)),
        }
    }

    /// Get the next sequence number (increments atomically).
    pub fn next_seq(&self) -> u64 {
        self.seq.fetch_add(1, Ordering::Relaxed)
    }

    /// Record a change and return its sequence number.
    pub fn record(&self, path: PathBuf, op: ChangeOp) -> u64 {
        let seq = self.next_seq();
        let record = ChangeRecord {
            seq,
            path,
            op,
            timestamp: SystemTime::now(),
        };

        let mut changes = self.changes.write().unwrap();
        changes.push_back(record);

        // Cap the buffer — drop oldest entries
        while changes.len() > MAX_CHANGES {
            changes.pop_front();
        }

        seq
    }

    /// Get all changes since the given sequence number.
    ///
    /// Returns `(changes, truncated)` where `truncated` is true if the
    /// consumer's `seq` is older than the oldest retained entry, meaning
    /// some changes have been lost and a full re-sync is needed.
    pub fn changes_since(&self, seq: u64) -> (Vec<ChangeRecord>, bool) {
        let changes = self.changes.read().unwrap();

        // Check if the oldest entry is newer than the requested seq.
        // If so, we've already dropped changes the consumer needs.
        let truncated = changes.front().map_or(false, |oldest| oldest.seq > seq + 1);

        let result: Vec<ChangeRecord> = changes.iter().filter(|c| c.seq > seq).cloned().collect();

        (result, truncated)
    }

    /// Get the latest sequence number.
    pub fn latest_seq(&self) -> u64 {
        self.seq.load(Ordering::Relaxed)
    }
}

impl Default for VersionStore {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn records_are_monotonic() {
        let store = VersionStore::new();
        let s1 = store.record(PathBuf::from("a.rs"), ChangeOp::Added);
        let s2 = store.record(PathBuf::from("b.rs"), ChangeOp::Modified);
        let s3 = store.record(PathBuf::from("c.rs"), ChangeOp::Deleted);
        assert!(s1 < s2 && s2 < s3);
    }

    #[test]
    fn changes_since_returns_correct_subset() {
        let store = VersionStore::new();
        store.record(PathBuf::from("a.rs"), ChangeOp::Added);
        let s2 = store.record(PathBuf::from("b.rs"), ChangeOp::Modified);
        store.record(PathBuf::from("c.rs"), ChangeOp::Deleted);

        let (changes, truncated) = store.changes_since(s2);
        assert_eq!(changes.len(), 1);
        assert_eq!(changes[0].path, PathBuf::from("c.rs"));
        assert!(!truncated);
    }

    #[test]
    fn changes_since_zero_returns_all() {
        let store = VersionStore::new();
        store.record(PathBuf::from("a.rs"), ChangeOp::Added);
        store.record(PathBuf::from("b.rs"), ChangeOp::Modified);

        let (changes, truncated) = store.changes_since(0);
        assert_eq!(changes.len(), 2);
        assert!(!truncated);
    }

    #[test]
    fn overflow_truncation() {
        let store = VersionStore::new();
        // Fill beyond MAX_CHANGES
        for i in 0..MAX_CHANGES + 100 {
            store.record(PathBuf::from(format!("file_{i}.rs")), ChangeOp::Modified);
        }

        // Request changes from seq 0 — we've definitely overflowed
        let (changes, truncated) = store.changes_since(0);
        assert!(truncated);
        assert_eq!(changes.len(), MAX_CHANGES);
    }

    #[test]
    fn no_truncation_when_within_window() {
        let store = VersionStore::new();
        for i in 0..10 {
            store.record(PathBuf::from(format!("file_{i}.rs")), ChangeOp::Modified);
        }

        // Request from seq 5 — well within the 1000-entry window
        let (changes, truncated) = store.changes_since(5);
        assert!(!truncated);
        assert_eq!(changes.len(), 5); // seqs 6,7,8,9,10 (started at 1, 10 records = seqs 1..10)
    }
}

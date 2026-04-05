use std::collections::HashMap;
use std::fmt;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use parking_lot::RwLock;

/// An exclusive lock held by an agent on a file.
#[derive(Debug, Clone)]
pub struct AgentLock {
    pub agent_id: String,
    pub file: PathBuf,
    pub acquired_at: SystemTime,
    pub last_heartbeat: SystemTime,
}

/// Errors from lock operations.
#[derive(Debug)]
pub enum LockError {
    /// The file is already locked by a different agent.
    AlreadyLocked { agent_id: String, file: PathBuf },
    /// The file is not currently locked.
    NotLocked,
    /// The caller does not own the lock on this file.
    NotOwner,
}

impl fmt::Display for LockError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            LockError::AlreadyLocked { agent_id, file } => {
                write!(f, "file {:?} already locked by agent {:?}", file, agent_id)
            }
            LockError::NotLocked => write!(f, "file is not locked"),
            LockError::NotOwner => write!(f, "caller does not own this lock"),
        }
    }
}

impl std::error::Error for LockError {}

/// Multi-agent file lock manager with heartbeat-based stale detection.
///
/// Agents acquire exclusive locks on files before editing. Each agent must
/// periodically call `heartbeat()` to keep its locks alive. Locks that
/// haven't been refreshed within `stale_timeout` are reaped automatically
/// when `reap_stale()` is called.
pub struct LockManager {
    locks: RwLock<HashMap<PathBuf, AgentLock>>,
    stale_timeout: Duration,
}

impl LockManager {
    pub fn new(stale_timeout: Duration) -> Self {
        Self {
            locks: RwLock::new(HashMap::new()),
            stale_timeout,
        }
    }

    /// Try to acquire an exclusive lock on a file for the given agent.
    ///
    /// If the agent already holds the lock, the heartbeat is refreshed.
    /// Returns `Err(AlreadyLocked)` if a different agent holds it.
    pub fn acquire(&self, agent_id: &str, file: &Path) -> Result<(), LockError> {
        let mut locks = self.locks.write();
        let now = SystemTime::now();

        if let Some(existing) = locks.get(file) {
            if existing.agent_id == agent_id {
                // Re-acquire by same agent: refresh heartbeat
                let entry = locks.get_mut(file).unwrap();
                entry.last_heartbeat = now;
                return Ok(());
            }
            return Err(LockError::AlreadyLocked {
                agent_id: existing.agent_id.clone(),
                file: file.to_path_buf(),
            });
        }

        locks.insert(
            file.to_path_buf(),
            AgentLock {
                agent_id: agent_id.to_string(),
                file: file.to_path_buf(),
                acquired_at: now,
                last_heartbeat: now,
            },
        );

        Ok(())
    }

    /// Release a lock held by the given agent.
    ///
    /// Returns `Err(NotLocked)` if the file has no lock, or
    /// `Err(NotOwner)` if a different agent holds it.
    pub fn release(&self, agent_id: &str, file: &Path) -> Result<(), LockError> {
        let mut locks = self.locks.write();

        let existing = locks.get(file).ok_or(LockError::NotLocked)?;

        if existing.agent_id != agent_id {
            return Err(LockError::NotOwner);
        }

        locks.remove(file);
        Ok(())
    }

    /// Refresh the heartbeat timestamp for all locks held by an agent.
    pub fn heartbeat(&self, agent_id: &str) {
        let mut locks = self.locks.write();
        let now = SystemTime::now();

        for lock in locks.values_mut() {
            if lock.agent_id == agent_id {
                lock.last_heartbeat = now;
            }
        }
    }

    /// Reap locks whose last heartbeat is older than `stale_timeout`.
    ///
    /// Returns the list of removed stale locks so the caller can log or
    /// notify about them.
    pub fn reap_stale(&self) -> Vec<AgentLock> {
        let mut locks = self.locks.write();
        let now = SystemTime::now();
        let mut reaped = Vec::new();

        locks.retain(|_, lock| {
            let age = now
                .duration_since(lock.last_heartbeat)
                .unwrap_or(Duration::ZERO);
            if age > self.stale_timeout {
                reaped.push(lock.clone());
                false
            } else {
                true
            }
        });

        reaped
    }

    /// Check whether a file is locked and return the lock info.
    pub fn check(&self, file: &Path) -> Option<AgentLock> {
        self.locks.read().get(file).cloned()
    }

    /// List all locks currently held by the given agent.
    pub fn list_agent_locks(&self, agent_id: &str) -> Vec<AgentLock> {
        self.locks
            .read()
            .values()
            .filter(|l| l.agent_id == agent_id)
            .cloned()
            .collect()
    }

    /// List all active locks.
    pub fn list_all(&self) -> Vec<AgentLock> {
        self.locks.read().values().cloned().collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::thread;
    use std::time::Duration;

    fn manager() -> LockManager {
        LockManager::new(Duration::from_millis(100))
    }

    #[test]
    fn acquire_and_release() {
        let mgr = manager();
        let file = Path::new("src/main.rs");

        mgr.acquire("agent-1", file).unwrap();
        assert!(mgr.check(file).is_some());

        mgr.release("agent-1", file).unwrap();
        assert!(mgr.check(file).is_none());
    }

    #[test]
    fn contention_two_agents_same_file() {
        let mgr = manager();
        let file = Path::new("shared.rs");

        mgr.acquire("agent-1", file).unwrap();

        let result = mgr.acquire("agent-2", file);
        assert!(result.is_err());
        match result.unwrap_err() {
            LockError::AlreadyLocked { agent_id, .. } => {
                assert_eq!(agent_id, "agent-1");
            }
            other => panic!("expected AlreadyLocked, got {:?}", other),
        }
    }

    #[test]
    fn same_agent_reacquire_refreshes_heartbeat() {
        let mgr = manager();
        let file = Path::new("reacquire.rs");

        mgr.acquire("agent-1", file).unwrap();
        // Re-acquire should succeed (idempotent)
        mgr.acquire("agent-1", file).unwrap();

        assert!(mgr.check(file).is_some());
    }

    #[test]
    fn release_not_locked() {
        let mgr = manager();
        let result = mgr.release("agent-1", Path::new("nope.rs"));
        assert!(matches!(result.unwrap_err(), LockError::NotLocked));
    }

    #[test]
    fn release_not_owner() {
        let mgr = manager();
        let file = Path::new("owned.rs");

        mgr.acquire("agent-1", file).unwrap();
        let result = mgr.release("agent-2", file);
        assert!(matches!(result.unwrap_err(), LockError::NotOwner));
    }

    #[test]
    fn heartbeat_refresh() {
        let mgr = manager();
        let file = Path::new("heartbeat.rs");

        mgr.acquire("agent-1", file).unwrap();
        let t1 = mgr.check(file).unwrap().last_heartbeat;

        // Small sleep so time advances
        thread::sleep(Duration::from_millis(10));
        mgr.heartbeat("agent-1");

        let t2 = mgr.check(file).unwrap().last_heartbeat;
        assert!(t2 > t1);
    }

    #[test]
    fn stale_reaping() {
        let mgr = LockManager::new(Duration::from_millis(50));
        let file = Path::new("stale.rs");

        mgr.acquire("agent-1", file).unwrap();

        // Wait past the stale timeout
        thread::sleep(Duration::from_millis(100));

        let reaped = mgr.reap_stale();
        assert_eq!(reaped.len(), 1);
        assert_eq!(reaped[0].agent_id, "agent-1");
        assert!(mgr.check(file).is_none());
    }

    #[test]
    fn heartbeat_prevents_reaping() {
        let mgr = LockManager::new(Duration::from_millis(80));
        let file = Path::new("alive.rs");

        mgr.acquire("agent-1", file).unwrap();

        // Heartbeat before timeout
        thread::sleep(Duration::from_millis(40));
        mgr.heartbeat("agent-1");

        thread::sleep(Duration::from_millis(40));
        mgr.heartbeat("agent-1");

        let reaped = mgr.reap_stale();
        assert!(reaped.is_empty());
        assert!(mgr.check(file).is_some());
    }

    #[test]
    fn list_agent_locks() {
        let mgr = manager();

        mgr.acquire("agent-1", Path::new("a.rs")).unwrap();
        mgr.acquire("agent-1", Path::new("b.rs")).unwrap();
        mgr.acquire("agent-2", Path::new("c.rs")).unwrap();

        let locks_1 = mgr.list_agent_locks("agent-1");
        assert_eq!(locks_1.len(), 2);

        let locks_2 = mgr.list_agent_locks("agent-2");
        assert_eq!(locks_2.len(), 1);
    }

    #[test]
    fn list_all() {
        let mgr = manager();

        mgr.acquire("agent-1", Path::new("x.rs")).unwrap();
        mgr.acquire("agent-2", Path::new("y.rs")).unwrap();

        let all = mgr.list_all();
        assert_eq!(all.len(), 2);
    }

    #[test]
    fn multiple_files_different_agents() {
        let mgr = manager();

        mgr.acquire("agent-1", Path::new("file1.rs")).unwrap();
        mgr.acquire("agent-2", Path::new("file2.rs")).unwrap();

        // Each agent can work on their own file
        assert_eq!(mgr.check(Path::new("file1.rs")).unwrap().agent_id, "agent-1");
        assert_eq!(mgr.check(Path::new("file2.rs")).unwrap().agent_id, "agent-2");

        // Release all of agent-1's locks
        mgr.release("agent-1", Path::new("file1.rs")).unwrap();
        assert!(mgr.check(Path::new("file1.rs")).is_none());
        assert!(mgr.check(Path::new("file2.rs")).is_some());
    }
}

use serde::{Deserialize, Serialize};

use crate::models::ChangeOp;

/// Event published to NATS when a file changes.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CodeFileChanged {
    pub path: String,
    pub op: ChangeOp,
    pub hash: u64,
    pub pod_id: String,
}

/// Event published to NATS when initial indexing completes.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CodeIndexComplete {
    pub file_count: usize,
    pub symbol_count: usize,
    pub pod_id: String,
}

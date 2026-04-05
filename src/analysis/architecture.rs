//! Architecture sanity analysis using the dependency graph.
//!
//! Detects circular dependencies, high fan-in/fan-out modules,
//! orphan files, and layer violations based on file path conventions.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::explorer::Explorer;

// ── Models ───────────────────────────────────────────────────────────────────

/// Full architecture analysis report.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ArchitectureReport {
    pub circular_deps: Vec<Vec<PathBuf>>,
    pub high_fan_in: Vec<(PathBuf, usize)>,
    pub high_fan_out: Vec<(PathBuf, usize)>,
    pub orphan_files: Vec<PathBuf>,
    pub layer_violations: Vec<LayerViolation>,
    pub summary: ArchitectureSummary,
}

/// A dependency that violates the expected layering rules.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LayerViolation {
    pub from_file: PathBuf,
    pub to_file: PathBuf,
    pub from_layer: String,
    pub to_layer: String,
    pub description: String,
}

/// Summary counts.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ArchitectureSummary {
    pub total_files: usize,
    pub circular_dep_count: usize,
    pub orphan_count: usize,
    pub layer_violation_count: usize,
}

// ── Constants ────────────────────────────────────────────────────────────────

/// Maximum number of cycles to report (prevents explosion on large graphs).
const MAX_CYCLES: usize = 20;

/// Fan-out above this threshold suggests a "god module".
pub const HIGH_FAN_OUT_THRESHOLD: usize = 15;

/// Fan-in above this threshold suggests core infrastructure.
pub const HIGH_FAN_IN_THRESHOLD: usize = 20;

/// Number of top entries to report for fan-in/fan-out.
const TOP_N: usize = 10;

/// Files with these stems are excluded from orphan detection.
const ORPHAN_EXCLUDE_STEMS: &[&str] = &["main", "lib", "mod"];

// ── Layer rules ──────────────────────────────────────────────────────────────

/// A directional layer rule: files in `from_prefix` must not import files in
/// `to_prefix`.
struct LayerRule {
    from_prefix: &'static str,
    to_prefix: &'static str,
    description: &'static str,
}

const LAYER_RULES: &[LayerRule] = &[
    LayerRule {
        from_prefix: "gateway/",
        to_prefix: "daemon/",
        description: "gateway should not import from daemon (wrong direction)",
    },
    LayerRule {
        from_prefix: "tools/",
        to_prefix: "gateway/",
        description: "tools should not import from gateway",
    },
    LayerRule {
        from_prefix: "models/",
        to_prefix: "gateway/",
        description: "models should not import from gateway",
    },
    LayerRule {
        from_prefix: "models/",
        to_prefix: "tools/",
        description: "models should not import from tools",
    },
];

// ── Analysis ─────────────────────────────────────────────────────────────────

/// Run architecture analysis on the indexed codebase.
pub fn architecture_analysis(explorer: &Explorer) -> ArchitectureReport {
    let outlines = explorer.get_all_outlines();
    let all_files: Vec<PathBuf> = outlines.keys().cloned().collect();

    // Build adjacency list from the dep graph
    let mut imports_map: HashMap<PathBuf, Vec<PathBuf>> = HashMap::new();
    let mut imported_by_map: HashMap<PathBuf, Vec<PathBuf>> = HashMap::new();

    for file in &all_files {
        let imports = explorer.get_imports(file);
        let imported_by = explorer.get_imported_by(file);

        imports_map.insert(file.clone(), imports);
        imported_by_map.insert(file.clone(), imported_by);
    }

    // Circular dependency detection
    let circular_deps = find_cycles(&imports_map);

    // Fan-in / fan-out
    let mut fan_in: Vec<(PathBuf, usize)> = all_files
        .iter()
        .map(|f| {
            let count = imported_by_map.get(f).map(|v| v.len()).unwrap_or(0);
            (f.clone(), count)
        })
        .filter(|(_, count)| *count > 0)
        .collect();
    fan_in.sort_by(|a, b| b.1.cmp(&a.1));
    let high_fan_in: Vec<(PathBuf, usize)> = fan_in.into_iter().take(TOP_N).collect();

    let mut fan_out: Vec<(PathBuf, usize)> = all_files
        .iter()
        .map(|f| {
            let count = imports_map.get(f).map(|v| v.len()).unwrap_or(0);
            (f.clone(), count)
        })
        .filter(|(_, count)| *count > 0)
        .collect();
    fan_out.sort_by(|a, b| b.1.cmp(&a.1));
    let high_fan_out: Vec<(PathBuf, usize)> = fan_out.into_iter().take(TOP_N).collect();

    // Orphan files: no imports and no importers (excluding main/lib/mod/test files)
    let orphan_files: Vec<PathBuf> = all_files
        .iter()
        .filter(|f| {
            let imports_count = imports_map.get(*f).map(|v| v.len()).unwrap_or(0);
            let imported_by_count = imported_by_map.get(*f).map(|v| v.len()).unwrap_or(0);
            if imports_count > 0 || imported_by_count > 0 {
                return false;
            }
            // Exclude common entry/module files
            if is_excluded_from_orphan(f) {
                return false;
            }
            true
        })
        .cloned()
        .collect();

    // Layer violations
    let layer_violations = find_layer_violations(&imports_map);

    let summary = ArchitectureSummary {
        total_files: all_files.len(),
        circular_dep_count: circular_deps.len(),
        orphan_count: orphan_files.len(),
        layer_violation_count: layer_violations.len(),
    };

    ArchitectureReport {
        circular_deps,
        high_fan_in,
        high_fan_out,
        orphan_files,
        layer_violations,
        summary,
    }
}

// ── Cycle detection ──────────────────────────────────────────────────────────

/// Find cycles in the dependency graph using iterative DFS.
/// Returns up to MAX_CYCLES distinct cycles.
fn find_cycles(graph: &HashMap<PathBuf, Vec<PathBuf>>) -> Vec<Vec<PathBuf>> {
    let mut cycles: Vec<Vec<PathBuf>> = Vec::new();
    let mut visited: HashSet<PathBuf> = HashSet::new();
    let mut on_stack: HashSet<PathBuf> = HashSet::new();

    // Track the path for cycle extraction
    let all_nodes: Vec<PathBuf> = graph.keys().cloned().collect();

    for start in &all_nodes {
        if cycles.len() >= MAX_CYCLES {
            break;
        }
        if visited.contains(start) {
            continue;
        }

        // Iterative DFS with explicit stack
        // Stack entries: (node, iterator_index, is_entering)
        let mut stack: Vec<(PathBuf, usize)> = vec![(start.clone(), 0)];
        let mut path: Vec<PathBuf> = Vec::new();

        while let Some((node, idx)) = stack.last_mut() {
            if *idx == 0 {
                // First visit to this node in this DFS path
                if on_stack.contains(node) {
                    // Found a cycle — extract it
                    if let Some(cycle_start) = path.iter().position(|p| p == node) {
                        let cycle: Vec<PathBuf> = path[cycle_start..].to_vec();
                        if !cycle.is_empty() && !cycles.iter().any(|c| is_same_cycle(c, &cycle)) {
                            cycles.push(cycle);
                            if cycles.len() >= MAX_CYCLES {
                                return cycles;
                            }
                        }
                    }
                    stack.pop();
                    continue;
                }

                visited.insert(node.clone());
                on_stack.insert(node.clone());
                path.push(node.clone());
            }

            let neighbors = graph.get(&stack.last().unwrap().0).cloned().unwrap_or_default();
            let current_idx = stack.last().unwrap().1;

            if current_idx < neighbors.len() {
                let neighbor = neighbors[current_idx].clone();
                stack.last_mut().unwrap().1 += 1;

                if on_stack.contains(&neighbor) {
                    // Found a cycle
                    if let Some(cycle_start) = path.iter().position(|p| p == &neighbor) {
                        let cycle: Vec<PathBuf> = path[cycle_start..].to_vec();
                        if !cycle.is_empty() && !cycles.iter().any(|c| is_same_cycle(c, &cycle)) {
                            cycles.push(cycle);
                            if cycles.len() >= MAX_CYCLES {
                                return cycles;
                            }
                        }
                    }
                } else if !visited.contains(&neighbor) {
                    stack.push((neighbor, 0));
                }
            } else {
                // Done with all neighbors
                let (finished, _) = stack.pop().unwrap();
                on_stack.remove(&finished);
                path.pop();
            }
        }
    }

    cycles
}

/// Check if two cycles are rotations of each other.
fn is_same_cycle(a: &[PathBuf], b: &[PathBuf]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    if a.is_empty() {
        return true;
    }
    // Check if b is a rotation of a
    let first = &b[0];
    for start in 0..a.len() {
        if &a[start] == first {
            let matches = (0..a.len()).all(|i| a[(start + i) % a.len()] == b[i]);
            if matches {
                return true;
            }
        }
    }
    false
}

// ── Layer violations ─────────────────────────────────────────────────────────

/// Check all import edges against layer rules.
fn find_layer_violations(graph: &HashMap<PathBuf, Vec<PathBuf>>) -> Vec<LayerViolation> {
    let mut violations = Vec::new();

    for (from_file, imports) in graph {
        let from_str = from_file.to_string_lossy();

        for to_file in imports {
            let to_str = to_file.to_string_lossy();

            for rule in LAYER_RULES {
                if from_str.contains(rule.from_prefix) && to_str.contains(rule.to_prefix) {
                    violations.push(LayerViolation {
                        from_file: from_file.clone(),
                        to_file: to_file.clone(),
                        from_layer: rule.from_prefix.trim_end_matches('/').to_string(),
                        to_layer: rule.to_prefix.trim_end_matches('/').to_string(),
                        description: rule.description.to_string(),
                    });
                }
            }
        }
    }

    violations.sort_by(|a, b| a.from_file.cmp(&b.from_file).then(a.to_file.cmp(&b.to_file)));
    violations
}

// ── Helpers ──────────────────────────────────────────────────────────────────

/// Check if a file should be excluded from orphan detection.
fn is_excluded_from_orphan(path: &Path) -> bool {
    let path_str = path.to_string_lossy();

    // Exclude test files
    if path_str.contains("test") || path_str.contains("spec") {
        return true;
    }

    // Exclude common entry/module files by stem
    if let Some(stem) = path.file_stem().and_then(|s| s.to_str()) {
        if ORPHAN_EXCLUDE_STEMS.contains(&stem) {
            return true;
        }
    }

    false
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::sync::Arc;
    use tempfile::TempDir;

    use crate::config::CodeIndexerConfig;

    fn setup(tmp: &TempDir) -> Explorer {
        let config = CodeIndexerConfig {
            workspace_root: tmp.path().to_path_buf(),
            ..Default::default()
        };
        Explorer::new(Arc::new(config))
    }

    fn write_file(tmp: &TempDir, rel: &str, content: &str) -> PathBuf {
        let full = tmp.path().join(rel);
        if let Some(parent) = full.parent() {
            fs::create_dir_all(parent).unwrap();
        }
        fs::write(&full, content).unwrap();
        PathBuf::from(rel)
    }

    #[test]
    fn detects_circular_deps() {
        // Build a graph with a cycle: a -> b -> c -> a
        let mut graph: HashMap<PathBuf, Vec<PathBuf>> = HashMap::new();
        graph.insert(PathBuf::from("a.rs"), vec![PathBuf::from("b.rs")]);
        graph.insert(PathBuf::from("b.rs"), vec![PathBuf::from("c.rs")]);
        graph.insert(PathBuf::from("c.rs"), vec![PathBuf::from("a.rs")]);

        let cycles = find_cycles(&graph);
        assert!(!cycles.is_empty(), "expected at least one cycle");
        assert_eq!(cycles[0].len(), 3);
    }

    #[test]
    fn no_cycles_in_dag() {
        let mut graph: HashMap<PathBuf, Vec<PathBuf>> = HashMap::new();
        graph.insert(PathBuf::from("a.rs"), vec![PathBuf::from("b.rs")]);
        graph.insert(PathBuf::from("b.rs"), vec![PathBuf::from("c.rs")]);
        graph.insert(PathBuf::from("c.rs"), vec![]);

        let cycles = find_cycles(&graph);
        assert!(cycles.is_empty(), "expected no cycles in DAG");
    }

    #[test]
    fn detects_layer_violations() {
        let mut graph: HashMap<PathBuf, Vec<PathBuf>> = HashMap::new();
        graph.insert(
            PathBuf::from("src/gateway/handler.rs"),
            vec![PathBuf::from("src/daemon/worker.rs")],
        );
        graph.insert(
            PathBuf::from("src/models/user.rs"),
            vec![PathBuf::from("src/gateway/routes.rs")],
        );

        let violations = find_layer_violations(&graph);
        assert_eq!(violations.len(), 2, "expected 2 layer violations, got {:?}", violations);

        assert!(violations.iter().any(|v| v.from_layer == "gateway" && v.to_layer == "daemon"));
        assert!(violations.iter().any(|v| v.from_layer == "models" && v.to_layer == "gateway"));
    }

    #[test]
    fn identifies_orphan_files() {
        let tmp = TempDir::new().unwrap();
        let explorer = setup(&tmp);

        // Create files that don't import each other
        write_file(&tmp, "orphan.rs", "pub fn lonely() {}\n");
        write_file(&tmp, "main.rs", "fn main() {}\n");
        write_file(&tmp, "lib.rs", "pub mod things;\n");

        explorer.index_file(Path::new("orphan.rs")).unwrap();
        explorer.index_file(Path::new("main.rs")).unwrap();
        explorer.index_file(Path::new("lib.rs")).unwrap();

        let report = architecture_analysis(&explorer);

        // orphan.rs should be detected, main.rs and lib.rs should be excluded
        assert!(report.orphan_files.contains(&PathBuf::from("orphan.rs")),
            "expected orphan.rs in orphans: {:?}", report.orphan_files);
        assert!(!report.orphan_files.contains(&PathBuf::from("main.rs")),
            "main.rs should be excluded from orphans");
        assert!(!report.orphan_files.contains(&PathBuf::from("lib.rs")),
            "lib.rs should be excluded from orphans");
    }

    #[test]
    fn is_same_cycle_rotations() {
        let a = vec![PathBuf::from("a"), PathBuf::from("b"), PathBuf::from("c")];
        let b = vec![PathBuf::from("b"), PathBuf::from("c"), PathBuf::from("a")];
        let c = vec![PathBuf::from("a"), PathBuf::from("c"), PathBuf::from("b")];

        assert!(is_same_cycle(&a, &b), "rotation should match");
        assert!(!is_same_cycle(&a, &c), "different order should not match");
    }

    #[test]
    fn summary_counts_match() {
        let tmp = TempDir::new().unwrap();
        let explorer = setup(&tmp);

        write_file(&tmp, "solo.rs", "pub fn solo() {}\n");
        explorer.index_file(Path::new("solo.rs")).unwrap();

        let report = architecture_analysis(&explorer);
        assert_eq!(report.summary.total_files, explorer.file_count());
        assert_eq!(report.summary.circular_dep_count, report.circular_deps.len());
        assert_eq!(report.summary.orphan_count, report.orphan_files.len());
        assert_eq!(report.summary.layer_violation_count, report.layer_violations.len());
    }

    #[test]
    fn caps_cycles_at_max() {
        // Build a graph where many small cycles exist
        let mut graph: HashMap<PathBuf, Vec<PathBuf>> = HashMap::new();
        for i in 0..30 {
            let a = PathBuf::from(format!("a{}.rs", i));
            let b = PathBuf::from(format!("b{}.rs", i));
            graph.insert(a.clone(), vec![b.clone()]);
            graph.insert(b, vec![a]);
        }

        let cycles = find_cycles(&graph);
        assert!(cycles.len() <= MAX_CYCLES, "cycles should be capped at {MAX_CYCLES}");
    }
}

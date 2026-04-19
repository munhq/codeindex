use std::path::PathBuf;

use codeindex::CodeIndexer;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Point at this crate's own src/ directory
    let workspace = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("src");

    let indexer = CodeIndexer::builder()
        .workspace(workspace)
        .project_id("codeindex-example")
        .build()
        .await;

    // Scan the workspace
    let scanned = indexer.scan().await?;
    println!("Scanned {scanned} files");
    println!("Indexed files: {}", indexer.file_count());
    println!("Total symbols: {}", indexer.symbol_count());

    // Find a symbol by name
    println!("\n--- find_symbol(\"Explorer\") ---");
    let results = indexer.find_symbol("Explorer");
    for result in &results {
        println!(
            "  {} ({:?}) at {}:{}",
            result.symbol.name,
            result.symbol.kind,
            result.path.display(),
            result.symbol.line_start,
        );
    }

    // Search file contents
    println!("\n--- search_content(\"trigram\") ---");
    let hits = indexer.search_content("trigram");
    for hit in hits.iter().take(5) {
        println!(
            "  {}:{} | {}",
            hit.path.display(),
            hit.line_num,
            hit.line_text.trim(),
        );
    }
    if hits.len() > 5 {
        println!("  ... and {} more", hits.len() - 5);
    }

    // Show the directory tree
    println!("\n--- get_tree() ---");
    fn print_tree(nodes: &[codeindex::models::TreeNode], indent: usize) {
        for node in nodes {
            let prefix = "  ".repeat(indent);
            if node.is_dir {
                println!("{prefix}{}/", node.name);
            } else {
                let syms = node.symbol_count.unwrap_or(0);
                let lang = node
                    .language
                    .map(|l| format!("{l:?}"))
                    .unwrap_or_default();
                println!("{prefix}{} ({lang}, {syms} symbols)", node.name);
            }
            print_tree(&node.children, indent + 1);
        }
    }
    print_tree(&indexer.get_tree(), 0);

    Ok(())
}

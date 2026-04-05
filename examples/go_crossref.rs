use std::path::PathBuf;

use codeindex::analysis::crossref;
use codeindex::CodeIndexer;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let workspace = PathBuf::from("/home/adi/code/personal/poly");

    let indexer = CodeIndexer::builder()
        .workspace(workspace)
        .project_id("poly-crossref-test")
        .build()
        .await;

    let scanned = indexer.scan().await?;
    println!("Scanned {scanned} files ({} indexed)", indexer.file_count());

    let report = crossref::cross_reference(indexer.explorer());

    println!("\n=== Backend Routes Found: {} ===", report.summary.total_backend_routes);
    for route in &report.backend_only {
        println!(
            "  [{}] {} -> {:?} ({}:{})",
            route.methods.join(","),
            route.path,
            route.handlers,
            route.file.display(),
            route.line,
        );
    }
    for wired in &report.wired {
        println!(
            "  [{}] {} -> {:?} ({}:{}) -- WIRED ({} callers)",
            wired.route.methods.join(","),
            wired.route.path,
            wired.route.handlers,
            wired.route.file.display(),
            wired.route.line,
            wired.callers.len(),
        );
    }

    println!("\n=== Frontend/Client Calls: {} ===", report.summary.total_frontend_calls);
    for call in report.frontend_only.iter().take(20) {
        println!(
            "  {} {} ({}:{}) fn={:?}",
            call.method,
            call.path,
            call.file.display(),
            call.line,
            call.function_name,
        );
    }
    if report.summary.frontend_only_count > 20 {
        println!("  ... and {} more", report.summary.frontend_only_count - 20);
    }

    println!("\n=== Summary ===");
    println!("  Backend routes:  {}", report.summary.total_backend_routes);
    println!("  Frontend calls:  {}", report.summary.total_frontend_calls);
    println!("  Wired:           {}", report.summary.wired_count);
    println!("  Backend-only:    {}", report.summary.backend_only_count);
    println!("  Frontend-only:   {}", report.summary.frontend_only_count);

    Ok(())
}

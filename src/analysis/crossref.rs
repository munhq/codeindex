//! Cross-reference analysis: backend routes vs frontend API calls.
//!
//! Parses:
//! - Axum `.route("/api/...", get(handler).post(handler))` patterns from Rust files
//! - `get("/api/...")`, `post(...)`, `fetch(...)` patterns from TS/TSX files
//!
//! Produces a gap report: unused backend routes, unmatched frontend calls,
//! and fully wired routes.

use std::path::PathBuf;

use regex::Regex;
use serde::{Deserialize, Serialize};

use crate::explorer::Explorer;

// ── Models ───────────────────────────────────────────────────────────────────

/// An API route defined in backend code.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BackendRoute {
    pub path: String,
    pub methods: Vec<String>,
    pub handlers: Vec<String>,
    pub file: PathBuf,
    pub line: usize,
}

/// An API call made from frontend code.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FrontendCall {
    pub path: String,
    pub method: String,
    pub file: PathBuf,
    pub line: usize,
    pub function_name: Option<String>,
}

/// A matched route: backend definition + frontend callers.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WiredRoute {
    pub route: BackendRoute,
    pub callers: Vec<FrontendCall>,
}

/// The full cross-reference report.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CrossRefReport {
    /// Routes defined in backend AND called from frontend.
    pub wired: Vec<WiredRoute>,
    /// Routes defined in backend but never called from frontend.
    pub backend_only: Vec<BackendRoute>,
    /// API calls in frontend with no matching backend route.
    pub frontend_only: Vec<FrontendCall>,
    /// Summary counts.
    pub summary: CrossRefSummary,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CrossRefSummary {
    pub total_backend_routes: usize,
    pub total_frontend_calls: usize,
    pub wired_count: usize,
    pub backend_only_count: usize,
    pub frontend_only_count: usize,
}

// ── Extraction ───────────────────────────────────────────────────────────────

lazy_static::lazy_static! {
    // ── Rust / Axum ─────────────────────────────────────────────────────────

    // Matches .route("path", methods) across multiple lines (uses (?s) dotall mode)
    static ref RE_AXUM_ROUTE: Regex = Regex::new(
        r#"(?s)\.route\(\s*"(/api/[^"]+)"\s*,\s*((?:[^()]*|\((?:[^()]*|\([^()]*\))*\))*)\s*\)"#
    ).unwrap();

    // Matches: get(handler), post(handler), etc. within a route chain
    static ref RE_METHOD_HANDLER: Regex = Regex::new(
        r#"(get|post|put|patch|delete)\(([^)]+)\)"#
    ).unwrap();

    // ── Go routers ──────────────────────────────────────────────────────────

    // chi: r.Get("/path", handler), r.Post("/path", handler), etc.
    static ref RE_GO_CHI_METHOD: Regex = Regex::new(
        r#"\.\s*(Get|Post|Put|Delete|Patch)\s*\(\s*"([^"]+)"\s*,"#
    ).unwrap();

    // chi: r.Route("/prefix", func(...) { ... })
    static ref RE_GO_CHI_ROUTE: Regex = Regex::new(
        r#"\.\s*Route\s*\(\s*"([^"]+)"\s*,"#
    ).unwrap();

    // net/http: http.HandleFunc("/path", handler) or mux.HandleFunc("/path", handler)
    static ref RE_GO_HANDLEFUNC: Regex = Regex::new(
        r#"\.HandleFunc\s*\(\s*"([^"]+)"\s*,"#
    ).unwrap();

    // net/http: http.Handle("/path", handler) or mux.Handle("/path", handler)
    static ref RE_GO_HANDLE: Regex = Regex::new(
        r#"\.Handle\s*\(\s*"([^"]+)"\s*,"#
    ).unwrap();

    // gin: router.GET("/path", handler), router.POST("/path", handler), etc.
    static ref RE_GO_GIN: Regex = Regex::new(
        r#"\.\s*(GET|POST|PUT|DELETE|PATCH)\s*\(\s*"([^"]+)"\s*,"#
    ).unwrap();

    // gorilla/mux: router.HandleFunc("/path", handler).Methods("GET")
    static ref RE_GO_GORILLA_METHODS: Regex = Regex::new(
        r#"\.HandleFunc\s*\(\s*"([^"]+)"\s*,.*\)\.Methods\s*\(\s*"([^"]+)""#
    ).unwrap();

    // ── Go HTTP client calls ────────────────────────────────────────────────

    // http.Get("url"), http.Post("url", ...)
    static ref RE_GO_HTTP_CALL: Regex = Regex::new(
        r#"http\.(Get|Post)\s*\(\s*"([^"]+)""#
    ).unwrap();

    // client.Get("/api/..."), client.Post("/api/...", ...)
    static ref RE_GO_CLIENT_CALL: Regex = Regex::new(
        r#"\.\s*(Get|Post)\s*\(\s*"([^"]*?/api/[^"]*?)""#
    ).unwrap();

    // http.NewRequest("METHOD", "url", ...)
    static ref RE_GO_NEW_REQUEST: Regex = Regex::new(
        r#"http\.NewRequest\s*\(\s*"(GET|POST|PUT|DELETE|PATCH)"\s*,\s*"([^"]+)""#
    ).unwrap();

    // ── TypeScript / JavaScript frontend ────────────────────────────────────

    // Frontend: get("/api/..."), post("/api/..."), put(...), patch(...), del(...)
    // Handles both string literals and template literals
    static ref RE_TS_HELPER: Regex = Regex::new(
        r#"(?:^|\b)(get|post|put|patch|del)\s*[<(]\s*["`]([^"`]*?/api/[^"`]*?)["`]"#
    ).unwrap();

    // Frontend: fetch(`/api/...`) or fetch("/api/...")
    static ref RE_TS_FETCH: Regex = Regex::new(
        r#"fetch\s*\(\s*["`]([^"`]*?/api/[^"`]*?)["`]"#
    ).unwrap();

    // Frontend: fetch(`${BASE}${resolvePath("/api/...")}`)
    static ref RE_TS_FETCH_RESOLVE: Regex = Regex::new(
        r#"resolvePath\s*\(\s*["`]([^"`]*?/api/[^"`]*?)["`]\s*\)"#
    ).unwrap();

    // Frontend: function name (export function getFoo)
    static ref RE_TS_FUNC_NAME: Regex = Regex::new(
        r#"(?:export\s+)?(?:async\s+)?function\s+(\w+)"#
    ).unwrap();

    // Go function name: func handlerName(
    static ref RE_GO_FUNC_NAME: Regex = Regex::new(
        r#"func\s+(\w+)\s*\("#
    ).unwrap();
}

/// Extract backend routes from Rust and Go source files.
pub fn extract_backend_routes(explorer: &Explorer) -> Vec<BackendRoute> {
    let outlines = explorer.get_all_outlines();
    let mut routes = Vec::new();

    for (path, _outline) in &outlines {
        let ext = path.extension().and_then(|e| e.to_str());

        match ext {
            Some("rs") => extract_rust_routes(path, explorer, &mut routes),
            Some("go") => extract_go_routes(path, explorer, &mut routes),
            _ => continue,
        }
    }

    routes.sort_by(|a, b| a.path.cmp(&b.path));
    routes
}

/// Extract Axum routes from a single Rust file.
fn extract_rust_routes(path: &PathBuf, explorer: &Explorer, routes: &mut Vec<BackendRoute>) {
    let content = match explorer.filter().read_file(path) {
        Ok(c) => c,
        Err(_) => return,
    };

    for cap in RE_AXUM_ROUTE.captures_iter(&content) {
        let route_path = cap.get(1).unwrap().as_str().to_string();
        let method_chain = cap.get(2).unwrap().as_str();

        let match_start = cap.get(0).unwrap().start();
        let line_num = content[..match_start].matches('\n').count() + 1;

        let mut methods = Vec::new();
        let mut handlers = Vec::new();

        for mcap in RE_METHOD_HANDLER.captures_iter(method_chain) {
            let method = mcap.get(1).unwrap().as_str().to_uppercase();
            let handler = mcap.get(2).unwrap().as_str().trim().to_string();
            methods.push(method);
            handlers.push(handler);
        }

        if !methods.is_empty() {
            routes.push(BackendRoute {
                path: route_path,
                methods,
                handlers,
                file: path.clone(),
                line: line_num,
            });
        }
    }
}

/// Extract routes from a single Go file (chi, net/http, gin, gorilla/mux).
///
/// Tracks `r.Route("/prefix", ...)` nesting to reconstruct full paths for chi.
fn extract_go_routes(path: &PathBuf, explorer: &Explorer, routes: &mut Vec<BackendRoute>) {
    let content = match explorer.filter().read_file(path) {
        Ok(c) => c,
        Err(_) => return,
    };

    // Build a prefix stack from r.Route("/prefix", ...) nesting.
    // We track open/close braces per line to know the active prefix at each line.
    let lines: Vec<&str> = content.lines().collect();

    // First pass: build a map of line → active route prefix by tracking
    // Route() calls and brace depth.
    let mut prefix_stack: Vec<(String, usize)> = Vec::new(); // (prefix, brace_depth)
    let mut brace_depth: usize = 0;

    // Pre-compute brace depth per line and active prefix
    let mut line_prefixes: Vec<String> = Vec::with_capacity(lines.len());

    for line in &lines {
        // Check for Route() call — push prefix
        if let Some(cap) = RE_GO_CHI_ROUTE.captures(line) {
            let prefix = cap.get(1).unwrap().as_str().to_string();
            // The route body opens on this line or next — we push at current depth+1
            // (the func literal opens a new brace scope)
            let current_prefix = active_prefix(&prefix_stack);
            let full_prefix = format!("{}{}", current_prefix, prefix);
            // Count braces on this line to find where the func body starts
            let open = line.matches('{').count();
            let close = line.matches('}').count();
            brace_depth = brace_depth + open - close;
            prefix_stack.push((full_prefix, brace_depth));
            line_prefixes.push(active_prefix(&prefix_stack));
            continue;
        }

        let open = line.matches('{').count();
        let close = line.matches('}').count();
        brace_depth = brace_depth + open;
        // Pop prefixes whose scope has closed
        if close > 0 {
            brace_depth = brace_depth.saturating_sub(close);
            while let Some((_pfx, depth)) = prefix_stack.last() {
                if brace_depth < *depth {
                    prefix_stack.pop();
                } else {
                    break;
                }
            }
        }
        line_prefixes.push(active_prefix(&prefix_stack));
    }

    // Second pass: extract routes using regexes
    for (line_idx, line) in lines.iter().enumerate() {
        let prefix = &line_prefixes[line_idx];

        // chi method routes: r.Get("/path", handler)
        for cap in RE_GO_CHI_METHOD.captures_iter(line) {
            let method = cap.get(1).unwrap().as_str().to_uppercase();
            let route_path = cap.get(2).unwrap().as_str();
            let full_path = format!("{}{}", prefix, route_path);
            let handler = extract_go_handler_from_line(line);
            routes.push(BackendRoute {
                path: full_path,
                methods: vec![method],
                handlers: handler.into_iter().collect(),
                file: path.clone(),
                line: line_idx + 1,
            });
        }

        // gin routes: router.GET("/path", handler)
        for cap in RE_GO_GIN.captures_iter(line) {
            let method = cap.get(1).unwrap().as_str().to_uppercase();
            let route_path = cap.get(2).unwrap().as_str();
            let full_path = format!("{}{}", prefix, route_path);
            let handler = extract_go_handler_from_line(line);
            routes.push(BackendRoute {
                path: full_path,
                methods: vec![method],
                handlers: handler.into_iter().collect(),
                file: path.clone(),
                line: line_idx + 1,
            });
        }

        // gorilla/mux: router.HandleFunc("/path", handler).Methods("GET")
        if let Some(cap) = RE_GO_GORILLA_METHODS.captures(line) {
            let route_path = cap.get(1).unwrap().as_str();
            let method = cap.get(2).unwrap().as_str().to_uppercase();
            let full_path = format!("{}{}", prefix, route_path);
            let handler = extract_go_handler_from_line(line);
            routes.push(BackendRoute {
                path: full_path,
                methods: vec![method],
                handlers: handler.into_iter().collect(),
                file: path.clone(),
                line: line_idx + 1,
            });
            continue; // Don't also match as generic HandleFunc
        }

        // net/http HandleFunc: mux.HandleFunc("/path", handler) — handles all methods
        for cap in RE_GO_HANDLEFUNC.captures_iter(line) {
            let route_path = cap.get(1).unwrap().as_str();
            let full_path = format!("{}{}", prefix, route_path);
            let handler = extract_go_handler_from_line(line);
            routes.push(BackendRoute {
                path: full_path,
                methods: vec!["GET".to_string(), "POST".to_string()],
                handlers: handler.into_iter().collect(),
                file: path.clone(),
                line: line_idx + 1,
            });
        }

        // net/http Handle: mux.Handle("/path", handler) — handles all methods
        if RE_GO_HANDLEFUNC.is_match(line) {
            // Already matched above
            continue;
        }
        for cap in RE_GO_HANDLE.captures_iter(line) {
            let route_path = cap.get(1).unwrap().as_str();
            let full_path = format!("{}{}", prefix, route_path);
            let handler = extract_go_handler_from_line(line);
            routes.push(BackendRoute {
                path: full_path,
                methods: vec!["GET".to_string(), "POST".to_string()],
                handlers: handler.into_iter().collect(),
                file: path.clone(),
                line: line_idx + 1,
            });
        }
    }
}

/// Get the active route prefix from the prefix stack.
fn active_prefix(stack: &[(String, usize)]) -> String {
    stack.last().map(|(p, _)| p.as_str()).unwrap_or("").to_string()
}

/// Extract a handler name from a Go route line (best-effort).
/// Looks for the second argument after the path string.
fn extract_go_handler_from_line(line: &str) -> Option<String> {
    // Pattern: , handlerName) or , handler.Method)
    // Find content after the path string's closing quote + comma
    if let Some(idx) = line.rfind("\",") {
        let rest = line[idx + 2..].trim();
        // Take until ) or , — the handler reference
        let handler = rest
            .trim_start()
            .split(|c: char| c == ')' || c == ',')
            .next()
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty() && !s.starts_with("func"));
        return handler;
    }
    None
}

/// Extract frontend/client API calls from TypeScript/TSX and Go files.
pub fn extract_frontend_calls(explorer: &Explorer) -> Vec<FrontendCall> {
    let outlines = explorer.get_all_outlines();
    let mut calls = Vec::new();

    for (path, _outline) in &outlines {
        let ext = path.extension().and_then(|e| e.to_str());

        match ext {
            Some("ts") | Some("tsx") | Some("js") | Some("jsx") => {
                extract_ts_frontend_calls(path, explorer, &mut calls);
            }
            Some("go") => {
                extract_go_client_calls(path, explorer, &mut calls);
            }
            _ => continue,
        }
    }

    calls.sort_by(|a, b| a.path.cmp(&b.path));
    calls
}

/// Extract frontend API calls from a TypeScript/JS file.
fn extract_ts_frontend_calls(
    path: &PathBuf,
    explorer: &Explorer,
    calls: &mut Vec<FrontendCall>,
) {
    let content = match explorer.filter().read_file(path) {
        Ok(c) => c,
        Err(_) => return,
    };

    let mut current_func: Option<String> = None;

    for (line_idx, line) in content.lines().enumerate() {
        if let Some(cap) = RE_TS_FUNC_NAME.captures(line) {
            current_func = Some(cap.get(1).unwrap().as_str().to_string());
        }

        for cap in RE_TS_HELPER.captures_iter(line) {
            let method = normalize_method(cap.get(1).unwrap().as_str());
            let raw_path = cap.get(2).unwrap().as_str();
            let api_path = normalize_frontend_path(raw_path);

            calls.push(FrontendCall {
                path: api_path,
                method,
                file: path.clone(),
                line: line_idx + 1,
                function_name: current_func.clone(),
            });
        }

        for cap in RE_TS_FETCH.captures_iter(line) {
            let raw_path = cap.get(1).unwrap().as_str();
            let api_path = normalize_frontend_path(raw_path);
            let method = infer_fetch_method(&content, line_idx);

            calls.push(FrontendCall {
                path: api_path,
                method,
                file: path.clone(),
                line: line_idx + 1,
                function_name: current_func.clone(),
            });
        }

        for cap in RE_TS_FETCH_RESOLVE.captures_iter(line) {
            let raw_path = cap.get(1).unwrap().as_str();
            let api_path = normalize_frontend_path(raw_path);
            let method = infer_fetch_method(&content, line_idx);

            calls.push(FrontendCall {
                path: api_path,
                method,
                file: path.clone(),
                line: line_idx + 1,
                function_name: current_func.clone(),
            });
        }
    }
}

/// Extract HTTP client calls from a Go file.
fn extract_go_client_calls(
    path: &PathBuf,
    explorer: &Explorer,
    calls: &mut Vec<FrontendCall>,
) {
    let content = match explorer.filter().read_file(path) {
        Ok(c) => c,
        Err(_) => return,
    };

    let mut current_func: Option<String> = None;

    for (line_idx, line) in content.lines().enumerate() {
        // Track current function name
        if let Some(cap) = RE_GO_FUNC_NAME.captures(line) {
            current_func = Some(cap.get(1).unwrap().as_str().to_string());
        }

        // http.Get("url"), http.Post("url", ...)
        for cap in RE_GO_HTTP_CALL.captures_iter(line) {
            let method = cap.get(1).unwrap().as_str().to_uppercase();
            let url = cap.get(2).unwrap().as_str();
            if let Some(api_path) = extract_api_path_from_url(url) {
                calls.push(FrontendCall {
                    path: api_path,
                    method,
                    file: path.clone(),
                    line: line_idx + 1,
                    function_name: current_func.clone(),
                });
            }
        }

        // client.Get("/api/..."), client.Post("/api/...", ...)
        for cap in RE_GO_CLIENT_CALL.captures_iter(line) {
            let method = cap.get(1).unwrap().as_str().to_uppercase();
            let raw_path = cap.get(2).unwrap().as_str();
            calls.push(FrontendCall {
                path: raw_path.to_string(),
                method,
                file: path.clone(),
                line: line_idx + 1,
                function_name: current_func.clone(),
            });
        }

        // http.NewRequest("GET", "/api/...", ...)
        for cap in RE_GO_NEW_REQUEST.captures_iter(line) {
            let method = cap.get(1).unwrap().as_str().to_uppercase();
            let url = cap.get(2).unwrap().as_str();
            if let Some(api_path) = extract_api_path_from_url(url) {
                calls.push(FrontendCall {
                    path: api_path,
                    method,
                    file: path.clone(),
                    line: line_idx + 1,
                    function_name: current_func.clone(),
                });
            }
        }
    }
}

/// Extract an API path from a full URL or path string.
/// Returns the path portion starting from /api/ if present.
fn extract_api_path_from_url(url: &str) -> Option<String> {
    // If it's already a path starting with /
    if url.starts_with('/') {
        return Some(url.to_string());
    }
    // If it's a full URL, extract the path portion
    if let Some(idx) = url.find("/api/") {
        return Some(url[idx..].to_string());
    }
    // For full URLs without /api/, extract path after host
    if url.starts_with("http://") || url.starts_with("https://") {
        // Find the third slash (after scheme://host)
        let after_scheme = if url.starts_with("https://") { 8 } else { 7 };
        if let Some(path_start) = url[after_scheme..].find('/') {
            return Some(url[after_scheme + path_start..].to_string());
        }
    }
    None
}

/// Build the cross-reference report.
pub fn cross_reference(explorer: &Explorer) -> CrossRefReport {
    let backend_routes = extract_backend_routes(explorer);
    let frontend_calls = extract_frontend_calls(explorer);

    // Normalize backend paths for matching (replace {param} with a pattern)
    let mut wired: Vec<WiredRoute> = Vec::new();
    let mut backend_only: Vec<BackendRoute> = Vec::new();
    let mut matched_frontend: Vec<bool> = vec![false; frontend_calls.len()];

    for route in &backend_routes {
        let pattern = route_to_pattern(&route.path);
        let mut callers: Vec<FrontendCall> = Vec::new();

        for (i, call) in frontend_calls.iter().enumerate() {
            if pattern.is_match(&call.path) && route.methods.contains(&call.method) {
                callers.push(call.clone());
                matched_frontend[i] = true;
            }
        }

        if callers.is_empty() {
            backend_only.push(route.clone());
        } else {
            wired.push(WiredRoute {
                route: route.clone(),
                callers,
            });
        }
    }

    let frontend_only: Vec<FrontendCall> = frontend_calls
        .into_iter()
        .enumerate()
        .filter(|(i, _)| !matched_frontend[*i])
        .map(|(_, c)| c)
        .collect();

    let summary = CrossRefSummary {
        total_backend_routes: backend_routes.len(),
        total_frontend_calls: matched_frontend.len(),
        wired_count: wired.len(),
        backend_only_count: backend_only.len(),
        frontend_only_count: frontend_only.len(),
    };

    CrossRefReport {
        wired,
        backend_only,
        frontend_only,
        summary,
    }
}

// ── Helpers ──────────────────────────────────────────────────────────────────

/// Normalize frontend "del" to "DELETE", etc.
fn normalize_method(m: &str) -> String {
    match m {
        "del" => "DELETE".to_string(),
        other => other.to_uppercase(),
    }
}

/// Normalize a frontend path: strip template literal expressions like ${...}
/// and replace with a wildcard placeholder for matching.
fn normalize_frontend_path(raw: &str) -> String {
    // Strip ${BASE} prefix if present
    let raw = raw
        .trim_start_matches("${BASE}")
        .trim_start_matches("${base}");

    // Strip query strings for matching (before ${} replacement to handle ?${qs})
    let path = raw.split('?').next().unwrap_or(raw);

    // Replace ${...} with {param}
    let re = Regex::new(r#"\$\{[^}]+\}"#).unwrap();
    let normalized = re.replace_all(path, "{param}");

    // Strip trailing incomplete template expressions
    let normalized = normalized.trim_end_matches("${qs ");

    normalized.to_string()
}

/// Convert a backend route pattern like "/api/agents/{id}/config"
/// to a regex that matches frontend paths like "/api/agents/{param}/config".
fn route_to_pattern(route: &str) -> Regex {
    let escaped = regex::escape(route);
    // Replace escaped \{param\} with a wildcard
    let pattern = Regex::new(r#"\\\{[^}]+\\\}"#)
        .unwrap()
        .replace_all(&escaped, r#"\{[^/]+\}"#);
    Regex::new(&format!("^{}$", pattern)).unwrap_or_else(|_| Regex::new("^$").unwrap())
}

/// Infer HTTP method from a fetch() call by looking for "method:" in nearby lines.
fn infer_fetch_method(content: &str, line_idx: usize) -> String {
    let lines: Vec<&str> = content.lines().collect();
    // Look within 5 lines for a method declaration
    let start = line_idx.saturating_sub(1);
    let end = (line_idx + 5).min(lines.len());

    for i in start..end {
        let line = lines[i].to_lowercase();
        if line.contains("method:") || line.contains("\"method\"") {
            if line.contains("post") { return "POST".to_string(); }
            if line.contains("put") { return "PUT".to_string(); }
            if line.contains("patch") { return "PATCH".to_string(); }
            if line.contains("delete") { return "DELETE".to_string(); }
        }
    }

    // Default to GET if no method specified
    "GET".to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize_frontend_path_strips_template_vars() {
        assert_eq!(
            normalize_frontend_path("/api/agents/${encodeURIComponent(id)}/config"),
            "/api/agents/{param}/config"
        );
    }

    #[test]
    fn normalize_frontend_path_strips_query_string() {
        assert_eq!(
            normalize_frontend_path("/api/search?q=foo&limit=10"),
            "/api/search"
        );
    }

    #[test]
    fn route_to_pattern_matches() {
        let pat = route_to_pattern("/api/agents/{id}/config");
        assert!(pat.is_match("/api/agents/{param}/config"));
    }

    #[test]
    fn normalize_method_del() {
        assert_eq!(normalize_method("del"), "DELETE");
        assert_eq!(normalize_method("get"), "GET");
        assert_eq!(normalize_method("post"), "POST");
    }
}

# codeindex

A fast, structural code intelligence engine that runs as an **MCP server** for AI coding agents.

It indexes your codebase with tree-sitter (40+ languages), builds a trigram full-text index, an inverted word index, and a dependency graph — then exposes **19 MCP tools** your AI agent can call to understand your code without dumping entire files into context.

```
 ┌─────────────┐      MCP (stdio)       ┌──────────────┐
 │  AI Agent   │ ◄─────────────────────► │   codeindex  │
 │ (Claude,    │   19 tools, JSON-RPC    │  (Zig binary) │
 │  Cursor…)   │                         │              │
 └─────────────┘                         └──────┬───────┘
                                                │
                                   tree-sitter parse (40+ langs)
                                         trigram + word index
                                         dependency graph
                                         snapshot persistence
```

## Why

AI coding agents spend tokens reading entire files. codeindex answers structural questions — symbol outlines, definitions, callers, blast radius, dependency chains — in a few hundred tokens instead of thousands.

One `plan_change` call returns: where a symbol is defined, every call site, the file's architectural role (god module / stable core / island / driver), hardcoded literals to check, and the full transitive blast radius if the file changes.

## Quickstart

```bash
# Install (prebuilt binary or build from source)
curl -fsSL https://raw.githubusercontent.com/munhq/codeindex/main/install.sh | bash

# Or build manually:
cd zig && ./fetch-vendor.sh && zig build -Doptimize=ReleaseFast
```

Register with your AI agent:

```bash
# Claude Code
claude mcp add codeindex -- ~/.local/bin/codeindex --mcp

# Cursor / other MCP clients: add to your config
{
  "mcpServers": {
    "codeindex": {
      "command": "~/.local/bin/codeindex",
      "args": ["--mcp"]
    }
  }
}
```

The next time your agent starts, codeindex indexes your project in the background and serves structural queries.

## MCP Tools

| Tool | What it does |
|------|-------------|
| `status` | Index stats: file count, symbol count, indexing state, token savings % |
| `search` | Trigram-accelerated full-text search across all indexed files |
| `find_symbol` | Find symbol definitions (functions, structs, classes…) by name |
| `find_word` | Exact word/identifier lookup in the inverted word index |
| `find_callers` | Approximate callers of a symbol (heuristic, no full name resolution) |
| `get_outline` | Structural outline of a file (symbols, line counts) |
| `get_tree` | Directory tree with file metadata |
| `get_imports` | What files does a given file import/depend on |
| `get_imported_by` | Reverse dependencies — who imports this file |
| `get_change_impact` | Transitive blast radius: what breaks if a file changes |
| `plan_change` | Full refactor plan for a symbol or file — definitions, callers, file role, literals, blast radius |
| `get_hot_files` | Recently changed files sorted by recency |
| `read_file` | Read file contents with optional line range |
| `read_symbol` | Read just a symbol's source code (with optional context lines) |
| `index_workspace` | Index or re-index a workspace directory |
| `analyze` | Run one of 13 code analyses (see below) |

### Analyses (`analyze` tool)

| Analysis | What it finds |
|----------|--------------|
| `security` | Hardcoded secrets, SQL injection patterns, unsafe blocks, eval usage |
| `dead_code` | Unreferenced files and symbols |
| `unwrap_audit` | `.unwrap()` / panic-prone error handling (Rust) |
| `test_coverage` | Files without test coverage |
| `architecture` | Architectural smells — god modules, circular deps, islands |
| `crossref` | Cross-file symbol references |
| `type_drift` | Type signature mismatches across modules |
| `db_schema` | Database schema drift between migrations and code |
| `migration_parity` | Missing migrations for schema changes |
| `manifest_compliance` | package.json / Cargo.toml / go.mod compliance issues |
| `literal_scan` | Hardcoded URLs, IPs, ports, absolute paths, TODOs |
| `coupling` | Module coupling metrics |
| `cycles` | Circular dependency detection |

## Supported Languages

**40+ languages** via tree-sitter: Rust, Python, TypeScript/TSX, Go, Zig, C, C++, Java, Ruby, Bash, C#, Kotlin, Lua, Scala, Elixir, R, Swift, Dart, Haskell, TOML, JSON, YAML, HTML, CSS, SCSS, SQL, HCL, Dockerfile, Markdown, Nix, Make, and more.

## Configuration

```bash
codeindex --mcp                          # Run as MCP server (stdio)
codeindex --workspace ./my-project       # Index a specific directory
codeindex --project-id my-project        # Project identifier
codeindex -v                             # Print version
codeindex -h                             # Print help

# Environment variables
CODEINDEX_WORKSPACE=/path/to/project     # Same as --workspace
CODEINDEX_PROJECT_ID=my-project          # Same as --project-id
```

codeindex auto-detects the project root by walking up from the working directory looking for `.git`, `package.json`, `Cargo.toml`, `go.mod`, `build.zig`, `pyproject.toml`, etc.

It refuses to index your entire home directory or the filesystem root — pass `--workspace` to be explicit.

## Architecture

- **Parser**: tree-sitter with 40+ grammars, compiled into a single binary
- **Index**: trigram index for fuzzy text search + inverted word index for exact identifier lookup
- **Dependency graph**: file-level import resolution with forward and reverse edges
- **Version store**: tracks file changes with sequence numbers for incremental updates
- **Live watcher**: re-indexes on file create/modify/delete (background thread in MCP mode)
- **Snapshot**: persists the full index to `.codeindex.json` for instant startup on reload
- **MCP server**: JSON-RPC over stdio, implements the MCP 2024-11-05 protocol

## Building from source

Requires [Zig 0.16.0](https://ziglang.org/download/).

```bash
cd zig
./fetch-vendor.sh    # Clone tree-sitter + 40 grammar repos
zig build -Doptimize=ReleaseFast
# Binary: zig/zig-out/bin/codeindex
```

Run tests:

```bash
cd zig && zig build test
```

## How it compares

| | codeindex | ast-grep | ctags | LSIF | Sourcegraph |
|---|-----------|---------|------|------|-------------|
| **MCP-native** | Yes | No | No | No | No |
| **Token-efficient** | Yes (outlines, not full files) | No | Partial | Yes | Yes |
| **Single binary** | Yes | Yes | Yes | No | No (server) |
| **Live watcher** | Yes | No | No | No | No |
| **Dependency graph** | Yes | No | No | Yes | Yes |
| **Blast radius** | Yes (transitive) | No | No | No | Partial |
| **Refactor planner** | Yes (`plan_change`) | No | No | No | No |
| **Languages** | 40+ | 20+ | 50+ | Varies | Varies |

## License

MIT. See [LICENSE](LICENSE).
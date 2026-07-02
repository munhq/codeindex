# Contributing to codeindex

Thanks for your interest in contributing! This guide covers building, testing, and submitting changes.

## Prerequisites

- [Zig 0.16.0](https://ziglang.org/download/)
- `git` (for fetching tree-sitter grammars)
- A C compiler (system cc — needed for tree-sitter C sources)

## Build from source

```bash
git clone https://github.com/munhq/codeindex.git
cd codeindex/zig
./fetch-vendor.sh              # Clone tree-sitter + grammar repos into vendor/
zig build -Doptimize=ReleaseFast   # Release build
# Binary: zig/zig-out/bin/codeindex
```

For development (faster compile, debug allocator):

```bash
zig build                       # Debug build
zig build test                  # Run unit tests
```

## Project structure

```
zig/
  main.zig                      # Entry point: CLI parsing, indexing, MCP server startup
  build.zig                     # Build configuration (tree-sitter + 40 grammars)
  fetch-vendor.sh               # Clones tree-sitter + grammar repos into vendor/
  src/
    core/                       # Models, config, I/O, filter, locking
    parser/                     # Tree-sitter parser wrapper + import scanning
    index/                      # Explorer (trigram + word index + dep graph), scanner, version store
    resolver/                   # Import path resolution (TS path aliases, Go, Rust, Python…)
    storage/                    # Snapshot save/load
    server/                     # MCP JSON-RPC server over stdio
    analysis/                   # 13 code analyses (security, dead_code, coupling, cycles, plan_change…)
    watcher.zig                 # Filesystem watcher (poll-based, cross-platform)
    tests.zig                   # Unit tests
```

## Running the MCP server locally

```bash
# Index the current project and serve MCP over stdio
CODEINDEX_WORKSPACE=. ./zig-out/bin/codeindex --mcp

# Test with raw JSON-RPC (pipe in requests)
printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"0.1"}}}\n{"jsonrpc":"2.0","method":"notifications/initialized"}\n{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}\n' \
  | ./zig-out/bin/codeindex --mcp
```

## Testing

```bash
cd zig && zig build test
```

Tests live in `src/tests.zig`. When adding a new feature or analysis, add tests covering:
- Core data structures (trigram, word index, dep graph, version store)
- Edge cases (empty queries, missing files, unknown languages)
- Analysis output correctness

## Adding a new tree-sitter grammar

1. Add a `clone <name> <repo-url>` line to `fetch-vendor.sh`
2. Add the grammar entry to `grammars` array in `build.zig`
3. Add the language to the `Language` enum in `src/core/models.zig` with extension detection
4. Add tree-sitter query patterns to `src/parser/treesitter.zig` if the language has non-standard symbol names

## Adding a new analysis

1. Create `src/analysis/<name>.zig` with a `pub fn run(allocator, explorer) ![]const u8` entry point
2. Import it in `src/server/http.zig`
3. Add it to the `analyze` tool handler switch statement
4. Add it to the tool description string in `write_tools_list`
5. Add tests

## Adding a new MCP tool

1. Add the tool name + JSON schema to the `tool_defs` array in `write_tools_list` (`src/server/http.zig`)
2. Add an `else if (std.mem.eql(u8, tool, "your_tool"))` branch in `handle_tool_call`
3. Implement the handler — write output to the `w` writer
4. Document it in the README tools table

## Commit style

- `feat:` new features
- `fix:` bug fixes
- `chore:` maintenance, deps, cleanup
- `docs:` documentation only

## Reporting issues

Open an issue at https://github.com/munhq/codeindex/issues with:
- What you were trying to do
- The command you ran
- Expected vs actual output
- OS and architecture
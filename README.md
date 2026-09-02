<img src="docs/brand/logo.svg" alt="codeindex" width="235" height="70">

[![npm](https://img.shields.io/npm/v/%40munhq%2Fcodeindex?label=npm&color=cb3837)](https://www.npmjs.com/package/@munhq/codeindex)
[![MCP Registry](https://img.shields.io/badge/MCP%20Registry-io.github.munhq%2Fcodeindex-000)](https://registry.modelcontextprotocol.io/v0/servers?search=codeindex)
[![Smithery](https://img.shields.io/badge/Smithery-munhq%2Fcodeindex-7c3aed)](https://smithery.ai/servers/munhq/codeindex)
[![license](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

[![Install in Cursor](https://img.shields.io/badge/Install-Cursor-000?logo=cursor)](cursor://anysphere.cursor-deeplink/mcp/install?name=codeindex&config=eyJjb21tYW5kIjoibnB4IiwiYXJncyI6WyIteSIsIkBtdW5ocS9jb2RlaW5kZXgiXX0=)
[![Install in VS Code](https://img.shields.io/badge/Install-VS%20Code-007ACC?logo=visualstudiocode)](vscode:mcp/install?%7B%22name%22%3A%22codeindex%22%2C%22command%22%3A%22npx%22%2C%22args%22%3A%5B%22-y%22%2C%22%40munhq%2Fcodeindex%22%5D%7D)

A structural code intelligence engine that runs as an **MCP server** for AI coding agents.

It indexes your codebase with tree-sitter (40+ languages), builds a trigram full-text index, an inverted word index, and a dependency graph — then exposes them through **16 MCP tools**.

```
 ┌─────────────┐   MCP (stdio)   ┌───────────┐            ┌──────────────────┐
 │  AI Agent   │ ◄─────────────► │ codeindex │  socket    │ codeindex daemon │
 │ (Claude,    │ 16 tools,       │  (relay)  │ ◄────────► │  one per         │
 │  Cursor…)   │ JSON-RPC        └───────────┘            │  workspace       │
 └─────────────┘                                          └────────┬─────────┘
 ┌─────────────┐   MCP (stdio)   ┌───────────┐                     │
 │  AI Agent   │ ◄─────────────► │ codeindex │ ◄───────────────────┘
 │  (session 2)│                 │  (relay)  │   tree-sitter parse (40+ langs)
 └─────────────┘                 └───────────┘   trigram + word index
                                                 dependency graph
                                                 one file watcher
                                                 snapshot persistence
```

Every session on a repository speaks plain stdio MCP, as before. Behind that,
they share one index: the tree is parsed once, watched once and written once,
however many agents are attached. Eight sessions on one repository used to be
eight copies of the same index, eight file watchers and eight writers of the
same snapshot; measured on a 720-file project, each session went from 87 MB to
7 MB, against one shared 77 MB daemon.

## Why

AI coding agents spend tokens reading entire files. codeindex answers structural questions — symbol outlines, definitions, callers, blast radius, dependency chains — in a few hundred tokens instead of thousands.

One `plan_change` call returns: where a symbol is defined, every call site, the file's architectural role (god module / stable core / island / driver), hardcoded literals to check, and the full transitive blast radius if the file changes.

## Quickstart

The shortest path, if you have Node 18+. Nothing else to install, no key, no
config — the package is a 4 KB wrapper that fetches the binary for your platform
and verifies it against the published checksums:

```bash
claude mcp add codeindex -- npx -y @munhq/codeindex
```

No Node, or you want the skill and the hook as well:

```bash
# Prebuilt binary + skill + MCP registration, in one command
curl -fsSL https://raw.githubusercontent.com/munhq/codeindex/main/install.sh | sh

# Or build from source:
cd zig && ./fetch-vendor.sh && zig build -Doptimize=ReleaseFast
```

Docker, for hosts that install MCP servers as images. The workspace is
bind-mounted read-only; codeindex never writes to it:

```bash
docker run -i --rm -v "$PWD:/workspace:ro" munhq/codeindex
```

Register with your AI agent:

```bash
# Claude Code — the plugin is the one-step path. It ships the skill, both
# routing hooks and the MCP server together, and its launcher finds or fetches
# the binary.
claude plugin marketplace add munhq/codeindex
claude plugin install codeindex@codeindex

# Without the plugin (or for a different MCP client), register the binary
# directly. Do not do both: two registrations mean two servers, two copies of
# every tool schema, and two writers on one snapshot. install.sh detects the
# plugin and skips this step when it is present.
claude mcp add -s user codeindex -- ~/.local/bin/codeindex --mcp

# Cursor / Claude Desktop / other MCP clients: add to your config
{
  "mcpServers": {
    "codeindex": {
      "command": "npx",
      "args": ["-y", "@munhq/codeindex"]
    }
  }
}
```

Every listing points at the same server: npm `@munhq/codeindex`, the official MCP
registry as `io.github.munhq/codeindex`, and Smithery as `munhq/codeindex`.

The next time your agent starts, codeindex indexes your project in the background and serves structural queries.

## MCP Tools

| Tool | What it does |
|------|-------------|
| `status` | Index stats: file count, symbol count, indexing state, token savings %, the indexed `workspace` and whether a `watcher` is live |
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
| `analyze` | Run one of 16 code analyses (see below) |

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
| `duplication` | Reinvented free functions — the same job written twice |
| `clones` | Copy-pasted function bodies, ignoring names and whitespace |
| `health` | Roll-up of the analyses above into one index-health report |

## Supported Languages

**40+ languages** via tree-sitter: Rust, Python, TypeScript/TSX, Go, Zig, C, C++, Java, Ruby, Bash, C#, Kotlin, Lua, Scala, Elixir, R, Swift, Dart, Haskell, TOML, JSON, YAML, HTML, CSS, SCSS, SQL, HCL, Dockerfile, Markdown, Nix, Make, and more.

## Configuration

```bash
codeindex --mcp                          # Run as MCP server (stdio)
codeindex --mcp --no-daemon              # ...without sharing the workspace daemon
codeindex --daemon-idle-secs 0           # Keep the daemon resident indefinitely
codeindex --workspace ./my-project       # Index a specific directory
codeindex --project-id my-project        # Project identifier
codeindex -v                             # Print version
codeindex -h                             # Print help

# Environment variables
CODEINDEX_WORKSPACE=/path/to/project     # Same as --workspace
CODEINDEX_PROJECT_ID=my-project          # Same as --project-id
```

### Getting it used

A server that registers without telling an agent when to reach for it stays
idle, and an idle index saves nothing however cheap its calls are. The plugin
ships three things for that, in the order they act:

1. **A SessionStart brief.** About 240 tokens, once per session, in a repository
   that holds source files: codeindex is live, and here is the tool for each
   kind of code question. It lands before the agent has chosen a tool, which is
   the only moment that can change the first choice.
2. **A PreToolUse hint.** Fires on the 1st, 8th and 25th code question of a
   session, when a scan is about to answer something the index answers better,
   and names the tool for that exact question. It matches `Bash` as well as
   `Read`/`Grep`/`Glob`, because a permission mode that routes file work through
   the shell is where most scans actually happen.
3. **The skill**, which the model loads when it decides the task calls for it.

Advice loses to habit, so the narrow case where the index is strictly better is
refused rather than argued with: an identifier search that is the whole command
line, in a project that has been indexed before. It never refuses a file read —
the bytes are required before an `Edit` — never refuses a line that also builds
or tests, and stops refusing after three times in a session, so it can never be
the reason a session cannot proceed.

That is **on by default**, and it is one switch to turn off — no file to edit by
hand. It is a plugin option, so `/plugin` shows it as "Refuse a scan the index
answers better" and Claude Code passes your answer to the hook. Outside the
plugin, or for a single session, `CODEINDEX_ENFORCE=0` in the environment
overrides the option and `CODEINDEX_ENFORCE=1` restores it.

Measure the effect rather than assuming it: `python3 plugin/measure_routing.py`
counts, per session, how many code questions went to a scan and how many went to
the index, across every Claude Code home on the machine.

### Which tree gets indexed

In `--mcp` mode the working directory belongs to the client, not to you, and it
is regularly not your project: Claude Code launches a plugin's MCP server from
the plugin's own directory and a user-scope server from its config directory. So
the workspace is resolved in this order, and the first usable answer wins:

1. `--workspace` or `CODEINDEX_WORKSPACE`. An explicit answer is never overridden.
2. `CLAUDE_PROJECT_DIR`, which Claude Code sets in every MCP server it spawns.
3. The launch directory, walking up for a `.git`, `package.json`, `Cargo.toml`,
   `go.mod`, `build.zig` or `pyproject.toml` marker.
4. The client's MCP `roots`. The server asks for them at the handshake whenever
   the root above was a guess, and adopts one when the guess was refused or lands
   outside every root the client reports. `notifications/roots/list_changed` is
   honoured too, so a directory added with `--add-dir` can still rescue a session.

`status` reports the effective root as `workspace`, and whether a file watcher is
running as `watcher`. Check them when a result looks empty: an index of the wrong
tree answers every question just as confidently as the right one.

It refuses to index your entire home directory, the filesystem root, or a folder
that merely holds several independent repositories. A refused workspace answers
every query with the reason and the one call that fixes it — `index_workspace`
with the project path — rather than with "no results".

## Architecture

- **Parser**: tree-sitter with 40+ grammars, compiled into a single binary
- **Index**: trigram index for fuzzy text search + inverted word index for exact identifier lookup
- **Dependency graph**: file-level import resolution with forward and reverse edges
- **Version store**: tracks file changes with sequence numbers for incremental updates
- **Live watcher**: re-indexes on file create/modify/delete (background thread in MCP mode). inotify on Linux; a polling walk on macOS and Windows, which compares mtime and size every couple of seconds. `status` reports which backend is live as `watcher_backend`.
- **Snapshot**: persists the full index to `.codeindex.json`, so a restart loads the snapshot instead of re-indexing
- **MCP server**: JSON-RPC over stdio, implements the MCP 2024-11-05 protocol
- **Workspace daemon**: the first session on a repository starts a background
  daemon and becomes a relay onto it; later sessions just connect. A Unix-domain
  socket on Linux, macOS and Windows 10 1803+, in `$XDG_RUNTIME_DIR/codeindex`
  (or a per-user directory under `TMPDIR`), named by a hash of the workspace
  **and the binary version** — so a rebuilt binary never inherits the previous
  version's daemon. It exits after 15 minutes with no session attached. Anything
  that goes wrong falls back to indexing in-process, which is what happened
  before the daemon existed. Turn it off with `--no-daemon`.

## Platform support

Every row is built by CI and its tests are run on that platform, except where
noted. `status` reports the live watcher backend so it is never a guess.

| | binary | tests run in CI | watcher | install.sh | plugin |
|---|---|---|---|---|---|
| Linux x86_64 | Yes | Yes | inotify | Yes | Yes |
| Linux aarch64 | Yes | cross-compiled | inotify | Yes | Yes |
| macOS aarch64 | Yes | Yes | polling | Yes | Yes |
| macOS x86_64 | Yes | cross-compiled | polling | Yes | Yes |
| Windows x86_64 | Yes | Yes | polling | needs a shell | see below |
| Windows aarch64 | Yes | cross-compiled | polling | needs a shell | see below |

On Windows, `install.sh` and the plugin's launcher are shell scripts, so they
need Git Bash, MSYS2 or Cygwin — they detect it and resolve the right `.exe`
asset. The plugin registers its server through that launcher, so a native
Windows Claude Code without a shell should register the binary directly:

```
claude mcp add -s user codeindex -- C:\path\to\codeindex.exe --mcp
```

Nothing here is signed or notarized. On macOS a binary fetched with `curl` runs
without a Gatekeeper prompt; one downloaded through a browser is quarantined,
and `xattr -d com.apple.quarantine codeindex` clears it.

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
cd zig && zig build test-bin && ./zig-out/bin/test
```

`zig build test` routes results through the build runner's IPC protocol on
stdout, which the linked tree-sitter C sources corrupt via their debug printf
paths. Building the test binary and running it directly is the same tests
without that protocol in the way.

## How it compares

| | codeindex | ast-grep | ctags | LSIF | Sourcegraph |
|---|-----------|---------|------|------|-------------|
| **MCP-native** | Yes | No | No | No | No |
| **Token-efficient** | Yes (outlines, not full files) | No | Partial | Yes | Yes |
| **Single binary** | Yes | Yes | Yes | No | No (server) |
| **Live watcher** | Yes (inotify / polling) | No | No | No | No |
| **Dependency graph** | Yes | No | No | Yes | Yes |
| **Blast radius** | Yes (transitive) | No | No | No | Partial |
| **Refactor planner** | Yes (`plan_change`) | No | No | No | No |
| **Languages** | 40+ | 20+ | 50+ | Varies | Varies |

## Pairs with chat-recall

codeindex answers questions about the code in front of you. **[chat-recall](https://github.com/munhq/chat-recall)** answers questions about the work you already did — it indexes your Claude Code, Gemini CLI, Codex, OpenCode and Antigravity sessions into one searchable history and exposes that over MCP too.

Together they cover both halves of what an agent forgets: codeindex stops it re-reading files it could have outlined, and chat-recall stops it redoing work it already finished. chat-recall detects a codeindex binary on your PATH and registers four extra code-intelligence tools when it finds one — neither requires the other.

## License

MIT. See [LICENSE](LICENSE).
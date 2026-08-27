# codeindex-mcp

Structural code intelligence for AI coding agents, as an MCP server. It answers
"where is X defined", "show me this function", "what calls it" and "what breaks
if I change this file" in tens of tokens, instead of the ~1,563 a file read
costs. tree-sitter across 40+ languages, 16 MCP tools, MIT.

```
npx -y codeindex-mcp
```

No account, no API key, no configuration.

## Add it to a client

Claude Code:

```
claude mcp add codeindex -- npx -y codeindex-mcp
```

Anything that reads a JSON config (Claude Desktop, Cursor, Windsurf, Zed, Cline):

```json
{
  "mcpServers": {
    "codeindex": {
      "command": "npx",
      "args": ["-y", "codeindex-mcp"]
    }
  }
}
```

## Why this is an npm package when the server is not JavaScript

codeindex is a statically linked binary — no runtime, no node_modules, about
53 MB per platform. This package is a 4 KB wrapper: on install it resolves the
release asset for your platform, verifies it against the `SHA256SUMS` published
beside it, caches it under `~/.cache/codeindex/bin/codeindex-<version>`, and
executes it. Six platforms are covered: linux and macOS on x86_64 and arm64,
Windows on x86_64 and arm64.

The cache key carries the version on purpose. An unversioned cache silently keeps
running an old binary after an upgrade, which is a bug this project has already
paid for once.

`CODEINDEX_BIN` overrides everything, for a local build. `PATH` is deliberately
*not* searched: this package declares one version to the MCP registry, and
running whatever `codeindex` happens to be on `PATH` would make that a lie.

## What the tools cost

| tool | tokens per call |
|---|---|
| `Read` (for comparison) | 1,563 |
| `get_outline` | 113 |
| `find_symbol` | 102 |
| `search` | 79 |
| `find_word` | 41 |
| `read_symbol` | **35** |

## Everything else

Source, the other install paths (`curl \| bash`, a Claude Code plugin with the
skill, a prebuilt binary), the 16 tools and the 16 analyses:
**https://github.com/munhq/codeindex**

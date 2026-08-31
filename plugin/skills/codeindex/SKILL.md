---
name: codeindex
description: >-
  Answer code questions structurally instead of reading whole files. Use when you
  need to find where something is defined, read one function, see what calls a
  symbol, trace imports, judge what a change breaks, or orient yourself in an
  unfamiliar file or repository. Reach for this before Read, Grep or Glob on a
  code question — and equally before `grep`, `rg`, `cat`, `head`, `sed -n` or
  `find` in a shell, which is where the same question goes when a harness or
  permission mode routes file work through Bash. A grep finds a string; it
  cannot tell you what calls what. Backed by the codeindex MCP server
  (tree-sitter, 40+ languages).
---

# Answering code questions with codeindex

## Why this matters

`Read` is the single largest consumer of context in agent sessions. Measured on
real transcripts: tool results dominate conversation text, `Read` dominates the
tool-result tokens, and a single `Read` call averages **1,563 tokens**.

Most Read calls answer a question that did not need the whole file.

| tool | tokens per call |
|---|---|
| `Read` | 1,563 |
| `get_outline` | 113 |
| `find_symbol` | 102 |
| `search` | 79 |
| `find_word` | 41 |
| `read_symbol` | **35** |

The codeindex tools are named bare throughout this skill. Their live prefix
depends on the install: `mcp__codeindex__` when the server is registered
directly, `mcp__plugin_codeindex_codeindex__` when the plugin registers it. Take
the exact name from your own tool list — a name written for the other install
fails the call and sends you back to `Read`.

Some harnesses defer MCP schemas: the names are in your tool list, but calling
one before its schema loads fails validation. Load the schemas first, in one
call — `ToolSearch` with `select:find_symbol,read_symbol,get_outline,find_word`
— then call the tools. That is one extra call per session, against 1,563 tokens
for every file you would otherwise read.

A token you never put into context is never billed. A token you put in and later
compress has already been re-sent on every intervening turn, and editing it
invalidates the prompt cache. So the cheapest possible intervention is to not
read the file in the first place.

## Route the question to the right tool

Ask what the question actually is, then pick:

- **"Where is X defined?"** → `find_symbol` (name). Returns file and line, not a
  file. Do not `Grep` for a definition.
- **"Show me function X"** → `read_symbol` (name, optional `path` to
  disambiguate, `context` for extra lines). This is the big win: 35 tokens
  against 1,563 for the file that contains it.
- **"What is in this file?"** → `get_outline` (path). Symbols with line numbers.
  Read the outline first, then `read_symbol` the one you want.
- **"Where is this string/identifier used?"** → `find_word` for an exact
  identifier, `search` for free text. Both beat `Grep` on token cost.
- **"What calls X?"** → `find_callers` (`name`). Heuristic, with no full name
  resolution — treat the result as a candidate list, not proof.
- **"What breaks if I change this file?"** → `get_change_impact` (`path`,
  optional `max_depth`) for the transitive blast radius, or `plan_change` for
  the whole picture in one call (definition, call sites, file role, literals,
  blast radius).

Dependency questions: `get_imports` (`path`) for what a file needs, and
`get_imported_by` (`path`) for what needs it. Orientation: `get_tree`,
`get_hot_files`, `status`. Audits: `analyze` with one of 16 analyses
(`security`, `dead_code`, `cycles`, `architecture`, `unwrap_audit`, `clones`,
`duplication`, `health`, …).

Every file-scoped tool above takes **`path`**, relative to the workspace root.
It is never `file`. A wrong argument name costs a turn and then sends you back
to `Read`, which is the outcome this skill exists to avoid.

## When NOT to use it

Three cases where reaching for codeindex is wrong, and one is a trap:

1. **You need exact file content** — you are about to `Edit`, the whitespace
   matters, or you need lines the outline does not carry. Use `Read`. Being
   cheap is worthless if you then edit the wrong text.
2. **`read_file` is not a cheaper `Read`.** Measured at 1,109
   tokens per call against Read's 1,563 — the same job at a similar price. The
   saving comes from asking a *narrower question*, not from swapping the file
   reader. Prefer `read_symbol`.
3. **`get_outline` on a very large file can cost more than `Read`.** `Read`
   truncates long files; an outline enumerates every symbol. On a 4,000-line
   file the outline can exceed a truncated read several times over. Use the
   outline to orient in a normal file, not as a universal Read replacement.

Also skip it for non-code files, generated files, and anything the index has not
seen — check `status` if results look empty, and `index_workspace` if the
workspace is not indexed yet.

## Check the index before you believe an empty answer

An empty structural result has two very different causes, and they lead to
opposite actions:

- The symbol is not there. Trust the answer.
- The index is not pointed at this repository. The answer means nothing.

`status` separates them in one cheap call. Two fields decide it:

- `files` — 0 means nothing is indexed at all.
- `workspace` — the absolute root actually indexed. In `--mcp` mode the server's
  working directory is chosen by the client, not by you, so this can be a plugin
  directory, a config directory, or a different repository altogether. An index
  of the wrong tree answers every question just as confidently as the right one.

If either is wrong, `index_workspace` with `path` set to the absolute path of the
project fixes it for the rest of the session, watcher included. A refused
workspace also says so in every tool result, so a result that starts with
"codeindex has no index" is a configuration problem, never a code answer.

## Strategy

1. Classify the question: definition, body, usage, callers, impact, or content.
2. Only "content" justifies `Read`. Everything else has a cheaper structural
   answer above.
3. Chain narrow calls rather than one broad read: `find_symbol` → `read_symbol`
   costs about 137 tokens where reading the file costs about 1,563.
4. If a structural call returns nothing, check `status` before concluding the
   code is absent — an unindexed or wrongly indexed workspace looks identical to
   a missing symbol. See the section above for the two fields that tell them
   apart.
5. Report file and line for anything you found, so the user can jump to it.

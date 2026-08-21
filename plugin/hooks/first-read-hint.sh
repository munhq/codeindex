#!/bin/sh
# PreToolUse hook: remind the agent, once per session, that a code question has
# a cheaper structural answer than reading the file.
#
# Why a hook and not only the skill: the skill applies when the model elects to
# load it, which makes adoption probabilistic. This fires from the harness the
# first time the session reaches for Read, Grep or Glob, which is exactly the
# moment the advice is actionable.
#
# Contract (see code.claude.com/docs/en/hooks):
#   - Exit 0 with plain text on stdout → the text is added to the model's
#     context as guidance. Deliberately NOT the JSON form with
#     permissionDecision:"allow": that would suppress the permission prompt for
#     Read, Grep and Glob, which is a side effect nobody asked this hook for.
#   - stdout becomes context, so it must carry the guidance and nothing else.
#     Diagnostics go to stderr.
#
# Fires ONCE per session. A reminder on every Read would spend more context than
# the tool saves, which would make this hook self-defeating.
set -u

STATE_DIR="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/codeindex-hints"

# Pull session_id out of the hook payload on stdin without requiring jq or
# python at runtime: one field, one pattern. If it cannot be read, fall back to
# a per-day key so a failure degrades to "rarely" rather than "on every call".
payload="$(cat)"
session="$(printf '%s' "$payload" | tr -d '\n' |
    sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
if [ -z "$session" ]; then
    session="fallback-$(date -u +%Y%m%d)"
fi

# Keep the key filesystem-safe; a session id is normally a UUID, but never trust
# a value out of a payload to be free of path separators.
key="$(printf '%s' "$session" | tr -c 'A-Za-z0-9._-' '_')"
marker="$STATE_DIR/$key"

mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
if [ -e "$marker" ]; then
    exit 0
fi
: > "$marker" 2>/dev/null || exit 0

# Tools are named bare here on purpose. The live prefix depends on how the
# server was registered — `mcp__codeindex__` for a direct install,
# `mcp__plugin_codeindex_codeindex__` when the plugin registers it — and this
# hook cannot see which. Printing one form named a tool that does not exist in
# the other install, which costs the agent a failed call and sends it straight
# back to Read. The agent already has the real names in its tool list.
cat <<'HINT'
codeindex is available in this session, and most code questions have a cheaper
answer than reading the file. Match the codeindex tool by its bare name:
  - where is X defined  -> find_symbol
  - show me function X  -> read_symbol
  - what is in this file -> get_outline
  - where is X used     -> find_word (exact) / search (text)
  - what calls X        -> find_callers
  - what breaks if I change this -> get_change_impact, plan_change
Keep using Read when you need the exact bytes — before an Edit, or when
whitespace matters. Every file-scoped tool takes `path`, never `file`.
HINT
exit 0

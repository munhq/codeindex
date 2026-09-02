#!/bin/sh
# SessionStart hook: state that codeindex is available, and how to route a code
# question to it, BEFORE the session's first tool call.
#
# Why this exists as well as the skill and the PreToolUse hint:
#   - The skill applies when the model elects to load it. Measured on real
#     sessions, that election often never happens: the skill sat in the
#     available list while the agent answered a whole session of code questions
#     with grep, and nothing in the transcript shows it considered the skill.
#   - The PreToolUse hint (first-read-hint.sh) fires at the right moment, but
#     the moment is already too late to change the FIRST decision: the agent has
#     chosen grep, the permission prompt is pending, and the hint arrives as an
#     argument against a choice it has just made.
#   - This one lands before the agent has chosen anything.
#
# Cost, measured against what it replaces: about 150 tokens per session, once,
# against 1,563 tokens for a single Read call it prevents.
#
# Contract (see code.claude.com/docs/en/hooks): plain-text stdout on SessionStart
# is added to the model's context. Diagnostics go to stderr. Every failure path
# degrades to silence.
set -u

# The brief is worth its tokens in a code repository and is pure noise anywhere
# else, so it fires only where a structural answer exists to be had.
root="${CLAUDE_PROJECT_DIR:-$PWD}"
[ -d "$root" ] || exit 0

marker_found=0
for m in .git package.json Cargo.toml go.mod pyproject.toml build.zig deno.json pom.xml .hg .svn; do
    if [ -e "$root/$m" ]; then
        marker_found=1
        break
    fi
done
[ "$marker_found" = 1 ] || exit 0

# At least one source file the index can actually parse. `head -1` stops the
# walk at the first hit, so this costs nothing on a large tree.
src="$(find "$root" -maxdepth 3 \
    \( -name node_modules -o -name .git -o -name target -o -name dist \
       -o -name build -o -name vendor -o -name zig-out -o -name .venv \) -prune -o \
    -type f \( -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.jsx' \
       -o -name '*.py' -o -name '*.go' -o -name '*.rs' -o -name '*.zig' \
       -o -name '*.c' -o -name '*.h' -o -name '*.cc' -o -name '*.cpp' \
       -o -name '*.java' -o -name '*.kt' -o -name '*.rb' -o -name '*.swift' \
       -o -name '*.php' -o -name '*.cs' -o -name '*.lua' -o -name '*.ex' \
       -o -name '*.dart' -o -name '*.scala' -o -name '*.sol' -o -name '*.proto' \) \
    -print 2>/dev/null | head -1)"
[ -n "$src" ] || exit 0

# Tools are named bare. The live prefix depends on the install —
# `mcp__codeindex__` when the server is registered directly,
# `mcp__plugin_codeindex_codeindex__` when the plugin registers it — and this
# hook cannot see which. Printing one form named a tool that does not exist in
# the other install, which costs a failed call and sends the agent back to grep.
# ── One-time notice: this session is paying for npx ──────────────────────────
#
# The plugin must launch the server with `npx` — no placeholder it could use
# resolves in every MCP client, so a plugin-relative path is not available (see
# the commit that made this npx). The cost is a resident `npm exec` parent doing
# nothing for the life of the session: measured between 34 MB and 160 MB, which
# is now larger than the server it launched.
#
# Registering the binary directly removes that parent. Say so ONCE per plugin
# version, only where the advice applies, and never as a nag.
notice=""
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
    state="${XDG_STATE_HOME:-$HOME/.local/state}/codeindex"
    stamp="$state/npx-notice-${CODEINDEX_PLUGIN_VERSION:-0}"
    if [ ! -e "$stamp" ]; then
        mkdir -p "$state" 2>/dev/null && : > "$stamp" 2>/dev/null
        notice="codeindex: the plugin starts this server through npx, which keeps an idle Node parent (34-160 MB) alive for the whole session. To drop it, install the binary and register it directly, then remove the plugin (its skills come with install.sh): curl -fsSL https://raw.githubusercontent.com/munhq/codeindex/main/install.sh | sh   -- do not run both, that is two servers and two writers on one snapshot."
    fi
fi

# Plain text on stdout is the SessionStart contract and is what this hook has
# always emitted. The notice needs a second channel — `systemMessage` is what
# reaches the PERSON rather than the model — and that requires JSON, so the
# brief travels as additionalContext in the same object. The plain-text path
# below is untouched and is what runs on every session but one.
if [ -n "$notice" ]; then
    brief="$(cat <<'BRIEF'
codeindex is live in this session: a tree-sitter index of this repository.
Answer code questions with it before Read/Grep/Glob — and before `grep`, `rg`,
`cat`, `sed -n` or `find` in Bash, where the same question goes when a
permission mode routes file work through the shell.

  where is X defined        -> find_symbol
  show me function X        -> read_symbol
  what is in this file      -> get_outline
  where is X used           -> find_word (identifier) / search (text)
  what calls X              -> find_callers
  what breaks if X changes  -> get_change_impact, plan_change

Call each tool by its bare name; your tool list shows the live prefix (load
deferred MCP schemas first if it defers them). An empty result is not proof the
code is absent: call `status`, and require `files` > 0 with `workspace` set to
this repository — one `index_workspace` call with the project path fixes it.
Read the bytes when you need them exactly, before an Edit.
BRIEF
)"
    # Both strings are JSON-escaped rather than interpolated raw: the brief
    # contains quotes and newlines, and one unescaped byte makes the whole hook
    # output unparseable, which would drop the brief entirely.
    esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | awk 'BEGIN{ORS=""} {print (NR>1 ? "\\n" : "") $0}'; }
    printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"},"systemMessage":"%s"}\n' \
        "$(esc "$brief
$notice")" "$(esc "$notice")"
    exit 0
fi

cat <<'BRIEF'
codeindex is live in this session
Read the bytes when you need them exactly, before an Edit.
BRIEF
exit 0

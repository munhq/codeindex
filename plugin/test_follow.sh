#!/usr/bin/env bash
# Run plugin/hooks/follow-folder.sh as the client runs it and check the folder
# that it reports to the relay.
#
# The hook writes $XDG_RUNTIME_DIR/codeindex-follow/<pid> for the process above
# it. Here that process is this script, so each case reads the file of $$.
# zig/test/e2e.py checks the other half: the relay reads the file and moves the
# session.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hook="$here/hooks/follow-folder.sh"

if [ ! -r /proc/self/stat ]; then
    printf '>>> SKIPPED: no /proc on this system. <<<\n' >&2
    exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
runtime="$tmp/runtime"
mkdir -p "$runtime" "$tmp/work/src" "$tmp/other/src" "$tmp/other/.git"
: >"$tmp/work/src/a.ts"
: >"$tmp/other/src/b.ts"
report="$runtime/codeindex-follow/$$"

fail=0
checked=0

# run_hook <payload>: the hook as a child of this shell, as the client starts it.
run_hook() {
    printf '%s' "$1" | XDG_RUNTIME_DIR="$runtime" sh "$hook"
}

expect() {
    local name="$1" want="$2" got
    checked=$((checked + 1))
    got="$(cat "$report" 2>/dev/null)"
    if [ "$got" != "$want" ]; then
        printf 'FAIL %s: want %q, got %q\n' "$name" "$want" "$got"
        fail=1
    fi
}

run_hook "{\"tool_name\":\"Bash\",\"cwd\":\"$tmp/work\",\"tool_input\":{\"command\":\"ls\"}}"
expect "a shell call with no path reports its cwd" "$tmp/work"

run_hook "{\"tool_name\":\"Read\",\"cwd\":\"$tmp/work\",\"tool_input\":{\"file_path\":\"$tmp/other/src/b.ts\"}}"
expect "a read of another project reports the folder of the file" "$tmp/other/src"

run_hook "{\"tool_name\":\"mcp__plugin_codeindex_codeindex__find_symbol\",\"cwd\":\"$tmp/work\",\"tool_input\":{\"name\":\"b\"}}"
expect "a codeindex call with no path keeps the folder of the call before it" "$tmp/other/src"

run_hook "{\"tool_name\":\"mcp__plugin_codeindex_codeindex__get_outline\",\"cwd\":\"$tmp/other\",\"tool_input\":{\"path\":\"$tmp/work/src/a.ts\"}}"
expect "a codeindex call with a path reports the folder of the path" "$tmp/work/src"

run_hook "{\"tool_name\":\"Bash\",\"cwd\":\"$tmp/work\",\"tool_input\":{\"command\":\"cd $tmp/other && rg foo src\"}}"
expect "a shell command that names an absolute folder reports it" "$tmp/other"

run_hook "{\"tool_name\":\"Bash\",\"cwd\":\"$tmp/work\",\"tool_input\":{\"command\":\"cat /etc/hostname \\\"$tmp/other/src/b.ts\\\"\"}}"
expect "a system path is skipped and a quoted path is read" "$tmp/other/src"

run_hook "{\"tool_name\":\"Grep\",\"cwd\":\"$tmp/other\",\"tool_input\":{\"pattern\":\"foo\",\"path\":\"src\"}}"
expect "a relative path is taken from the cwd" "$tmp/other/src"

run_hook "{\"tool_name\":\"Edit\",\"cwd\":\"$tmp/other\",\"tool_input\":{\"file_path\":\"$tmp/work/src/new.ts\",\"old_string\":\"a\",\"new_string\":\"b\"}}"
expect "a write of a file that does not exist yet reports its folder" "$tmp/work/src"

# The file of a process that has ended is removed.
checked=$((checked + 1))
printf '/nowhere\n' >"$runtime/codeindex-follow/999999999"
run_hook "{\"tool_name\":\"Bash\",\"cwd\":\"$tmp/work\",\"tool_input\":{\"command\":\"ls\"}}"
if [ -e "$runtime/codeindex-follow/999999999" ]; then
    printf 'FAIL the file of an ended process stays\n'
    fail=1
fi

# A payload that cannot be read changes nothing and never fails the call.
checked=$((checked + 1))
before="$(cat "$report")"
if ! printf 'not json' | XDG_RUNTIME_DIR="$runtime" sh "$hook"; then
    printf 'FAIL a bad payload made the hook fail\n'
    fail=1
fi
[ "$(cat "$report")" = "$before" ] || { printf 'FAIL a bad payload changed the report\n'; fail=1; }

# With no XDG_RUNTIME_DIR the hook writes nothing.
checked=$((checked + 1))
printf '{"tool_name":"Bash","cwd":"/","tool_input":{"command":"ls"}}' | env -u XDG_RUNTIME_DIR sh "$hook" || { printf 'FAIL no runtime folder made the hook fail\n'; fail=1; }

if [ "$fail" = 0 ]; then
    printf 'follow-folder.sh: %d cases pass\n' "$checked"
fi
exit "$fail"

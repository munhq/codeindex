#!/usr/bin/env bash
# Run plugin/hooks/testdata/commands.tsv through the hook's shell classifier and
# through the analyser's Python classifier, and require both to agree with the
# fixture and with each other.
#
# The hook decides when to spend a session's one hint. The analyser decides what
# to count when measuring whether the hint changed anything. They are separate
# implementations — the hook must not need python at runtime, the analyser must
# not shell out per transcript line — so nothing but a test keeps them aligned.
# Without this, a measurement could report "agents stopped grepping" while the
# hook was firing on a different set of commands entirely.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hook="$here/hooks/first-read-hint.sh"
analyser="$here/measure_routing.py"
fixtures="$here/hooks/testdata/commands.tsv"

fail=0
checked=0

while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac

    cmd="$(printf '%s' "$line" | cut -f1)"
    want_kind="$(printf '%s' "$line" | cut -f2)"
    want_subject="$(printf '%s' "$line" | cut -f3)"
    checked=$((checked + 1))

    # The shell classifier prints nothing and exits 1 for "not a code question".
    if got="$(sh "$hook" --classify "$cmd" 2>/dev/null)"; then
        got_kind="$(printf '%s' "$got" | cut -f1)"
        got_subject="$(printf '%s' "$got" | cut -f2)"
    else
        got_kind=none
        got_subject=""
    fi

    py="$(python3 "$analyser" --classify "$cmd" 2>/dev/null)"
    py_kind="$(printf '%s' "$py" | cut -f1)"
    py_subject="$(printf '%s' "$py" | cut -f2)"

    if [ "$got_kind" != "$want_kind" ] || [ "$got_subject" != "$want_subject" ]; then
        printf 'FAIL sh   %-48s want %s/%s got %s/%s\n' \
            "$cmd" "$want_kind" "$want_subject" "$got_kind" "$got_subject"
        fail=$((fail + 1))
    fi
    if [ "$py_kind" != "$want_kind" ] || [ "$py_subject" != "$want_subject" ]; then
        printf 'FAIL py   %-48s want %s/%s got %s/%s\n' \
            "$cmd" "$want_kind" "$want_subject" "$py_kind" "$py_subject"
        fail=$((fail + 1))
    fi
done < "$fixtures"

# ── Payload extraction ───────────────────────────────────────────────────────
# The fixtures above hand the command to --classify already parsed, so they
# cannot see a payload the hook fails to READ. That gap hid a second bug: the
# JSON value was matched with [^"]*, so every command carrying a double quote
# was classified on the stub before the first \". These cases drive the hook the
# way the harness drives it — one JSON object on stdin — and assert the hint
# text, the once-per-session rule, and that silence spends no chance.
payloads=0
state="$(mktemp -d)"
trap 'rm -rf "$state"' EXIT

payload_expect() {   # payload_expect <want-substring|""> , payload on stdin
    want="$1"
    got="$(XDG_RUNTIME_DIR="$state" sh "$hook" 2>/dev/null)"
    payloads=$((payloads + 1))
    if [ -z "$want" ]; then
        [ -z "$got" ] && return 0
        printf 'FAIL payload  want silence, got: %s\n' \
            "$(printf '%s' "$got" | tr '\n' ' ')"
        fail=$((fail + 1))
        return 0
    fi
    case "$got" in
        *"$want"*) return 0 ;;
    esac
    printf 'FAIL payload  want %s, got: %s\n' \
        "$want" "$(printf '%s' "$got" | tr '\n' ' ')"
    fail=$((fail + 1))
}

# A double quote anywhere in the line used to truncate it to a stub.
payload_expect 'get_outline packages/cli/src/sync-client.ts' <<'JSON'
{"session_id":"pt-quoted","tool_name":"Bash","tool_input":{"command":"cd /repo; echo \"=== upload path ===\"; sed -n '690,740p' packages/cli/src/sync-client.ts"}}
JSON

# One hint per session: the second call in the same session says nothing.
payload_expect '' <<'JSON'
{"session_id":"pt-quoted","tool_name":"Bash","tool_input":{"command":"cd /repo && grep -rn requireRemote packages/"}}
JSON

payload_expect 'find_callers requireRemote' <<'JSON'
{"session_id":"pt-ident","tool_name":"Bash","tool_input":{"command":"cd /repo && grep -rn requireRemote packages/"}}
JSON

# A manifest is not a code question. Stay silent, and do NOT spend the
# session's one chance — the next call proves the chance survived.
payload_expect '' <<'JSON'
{"session_id":"pt-noise","tool_name":"Bash","tool_input":{"command":"cd /repo; cat package.json"}}
JSON
payload_expect 'get_outline packages/cli/src/mcp.ts' <<'JSON'
{"session_id":"pt-noise","tool_name":"Bash","tool_input":{"command":"cd /repo; sed -n '1,40p' packages/cli/src/mcp.ts"}}
JSON

# The dedicated tools still route, in the modes that use them.
payload_expect 'get_outline zig/src/main.zig' <<'JSON'
{"session_id":"pt-read","tool_name":"Read","tool_input":{"file_path":"zig/src/main.zig"}}
JSON

if [ "$fail" -gt 0 ]; then
    printf '\n%d failure(s) across %d fixtures and %d payloads\n' \
        "$fail" "$checked" "$payloads" >&2
    exit 1
fi
printf 'hint classifier: %d fixtures (shell and python agree), %d payloads\n' \
    "$checked" "$payloads"

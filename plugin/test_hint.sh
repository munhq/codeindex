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

# Hermetic: both enforcement switches are read from the environment, and this
# machine may well set one for real. Inheriting it made four cases assert the
# wrong thing — the ambient CODEINDEX_ENFORCE=1 overrode the plugin option the
# case was there to test. Each case sets what it needs, from nothing.
unset CODEINDEX_ENFORCE CLAUDE_PLUGIN_OPTION_ENFORCE CLAUDE_PROJECT_DIR

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

# CODEINDEX_ENFORCE=0 throughout this section: these cases assert the ADVICE the
# hook gives, and enforcement (asserted in its own section below) would answer
# some of them with a refusal instead. Pinning it here keeps each section testing
# one thing.
payload_expect() {   # payload_expect <want-substring|""> , payload on stdin
    want="$1"
    got="$(CODEINDEX_ENFORCE=0 XDG_RUNTIME_DIR="$state" sh "$hook" 2>/dev/null)"
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

# The second code question of a session says nothing: the reminders land on the
# 1st, 8th and 25th, not on every call.
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

# ── Cadence ──────────────────────────────────────────────────────────────────
# One reminder per session was too few: a session that keeps scanning has not
# taken the first one. These drive the same session repeatedly and assert where
# the reminders land — 1st, 8th, 25th — and that the later ones are the short
# form, not the full menu again.
cadence_run() {   # cadence_run <n> -> the hook's output for the nth question
    printf '{"session_id":"pt-cadence","tool_name":"Bash","tool_input":{"command":"grep -rn requireRemote src/"}}' |
        CODEINDEX_ENFORCE=0 XDG_RUNTIME_DIR="$state" sh "$hook" 2>/dev/null
}

n=1
while [ "$n" -le 26 ]; do
    got="$(cadence_run "$n")"
    payloads=$((payloads + 1))
    case "$n" in
        1)
            # The full form, which names the three tools on their own lines.
            case "$got" in
                *"what calls it"*) ;;
                *) printf 'FAIL cadence  question 1 want the full hint, got: %s\n' \
                        "$(printf '%s' "$got" | tr '\n' ' ')"
                   fail=$((fail + 1)) ;;
            esac
            ;;
        8|25)
            # The short form: one line, naming the tool for this question.
            case "$got" in
                *"in one call: find_callers"*) ;;
                *) printf 'FAIL cadence  question %d want the short hint, got: %s\n' \
                        "$n" "$(printf '%s' "$got" | tr '\n' ' ')"
                   fail=$((fail + 1)) ;;
            esac
            case "$got" in
                *"what calls it"*)
                   printf 'FAIL cadence  question %d repeated the full hint\n' "$n"
                   fail=$((fail + 1)) ;;
            esac
            ;;
        *)
            if [ -n "$got" ]; then
                printf 'FAIL cadence  question %d want silence, got: %s\n' \
                    "$n" "$(printf '%s' "$got" | tr '\n' ' ')"
                fail=$((fail + 1))
            fi
            ;;
    esac
    n=$((n + 1))
done

# Noise must not advance the count, or a session of yaml greps would spend every
# reminder before the first code question.
n=1
while [ "$n" -le 30 ]; do
    printf '{"session_id":"pt-noise-count","tool_name":"Bash","tool_input":{"command":"grep -n version package.json"}}' |
        CODEINDEX_ENFORCE=0 XDG_RUNTIME_DIR="$state" sh "$hook" >/dev/null 2>&1
    n=$((n + 1))
done
payload_expect 'find_callers requireRemote' <<'JSON'
{"session_id":"pt-noise-count","tool_name":"Bash","tool_input":{"command":"grep -rn requireRemote src/"}}
JSON

# ── Enforcement ──────────────────────────────────────────────────────────────
# The behaviour that refuses a scan instead of arguing with it. It is on by
# default, so most assertions here are about a LIMIT: what it refuses, what it
# must never refuse, that a session can never be stuck, and that one plugin
# option turns it off.
proj="$(mktemp -d)"
: > "$proj/.codeindex.json"

enforce_run() {   # enforce_run <session> <payload-json> -> hook stdout
    printf '%s' "$2" |
        CODEINDEX_ENFORCE=1 CLAUDE_PROJECT_DIR="$proj" XDG_RUNTIME_DIR="$state" \
        sh "$hook" 2>/dev/null
}

enforce_expect() {   # enforce_expect <label> <want|""> <session> <payload>
    got="$(enforce_run "$3" "$4")"
    payloads=$((payloads + 1))
    if [ -z "$2" ]; then
        case "$got" in
            *'"deny"'*)
                printf 'FAIL enforce  %s want no refusal, got: %s\n' "$1" "$got"
                fail=$((fail + 1)) ;;
        esac
        return 0
    fi
    case "$got" in
        *"$2"*) return 0 ;;
    esac
    printf 'FAIL enforce  %s want %s, got: %s\n' "$1" "$2" "$got"
    fail=$((fail + 1))
}

# An identifier search, and the scan is the whole line: refused, with the tool
# that answers it named in the reason.
enforce_expect 'grep for an identifier' '"permissionDecision":"deny"' en-1 \
    '{"session_id":"en-1","tool_name":"Bash","tool_input":{"command":"cd /repo && grep -rn requireRemote src/"}}'
enforce_expect 'reason names the subject' 'find_callers' en-1b \
    '{"session_id":"en-1b","tool_name":"Bash","tool_input":{"command":"grep -rn requireRemote src/"}}'
# The Grep tool is single-purpose, so it needs no line analysis.
enforce_expect 'the Grep tool' '"permissionDecision":"deny"' en-2 \
    '{"session_id":"en-2","tool_name":"Grep","tool_input":{"pattern":"requireRemote"}}'

# A line that also runs the test suite must not be refused for the grep on the
# end of it: refusing the scan would refuse the work.
enforce_expect 'a compound line' '' en-3 \
    '{"session_id":"en-3","tool_name":"Bash","tool_input":{"command":"cd /repo; npm test; grep -rn requireRemote src/"}}'

# A read has no structural equivalent before an Edit — the harness requires the
# exact bytes — so a file read is never refused, in any mode.
enforce_expect 'a source file read' '' en-4 \
    '{"session_id":"en-4","tool_name":"Read","tool_input":{"file_path":"src/app.ts"}}'
enforce_expect 'sed on a source file' '' en-5 \
    '{"session_id":"en-5","tool_name":"Bash","tool_input":{"command":"sed -n \"1,40p\" src/app.ts"}}'

# Text, not code: not a code question in any mode.
enforce_expect 'a phrase search' '' en-6 \
    '{"session_id":"en-6","tool_name":"Bash","tool_input":{"command":"grep -rn \"is not logged in\" src/"}}'

# The session can never be stuck: refusals stop after three.
n=1
while [ "$n" -le 3 ]; do
    enforce_run en-limit '{"session_id":"en-limit","tool_name":"Grep","tool_input":{"pattern":"requireRemote"}}' >/dev/null
    n=$((n + 1))
done
enforce_expect 'the fourth refusal' '' en-limit \
    '{"session_id":"en-limit","tool_name":"Grep","tool_input":{"pattern":"requireRemote"}}'

# No snapshot for this project means no evidence the index knows this tree, so
# there is nothing to route to and nothing is refused.
empty="$(mktemp -d)"
got="$(printf '%s' '{"session_id":"en-nosnap","tool_name":"Grep","tool_input":{"pattern":"requireRemote"}}' |
    CODEINDEX_ENFORCE=1 CLAUDE_PROJECT_DIR="$empty" XDG_RUNTIME_DIR="$state" sh "$hook" 2>/dev/null)"
payloads=$((payloads + 1))
case "$got" in
    *'"deny"'*)
        printf 'FAIL enforce  no snapshot want no refusal, got: %s\n' "$got"
        fail=$((fail + 1)) ;;
esac

# On with no configuration at all. This is the assertion that the default is a
# refusal: nothing in the environment says so.
got="$(printf '%s' '{"session_id":"en-bare","tool_name":"Grep","tool_input":{"pattern":"requireRemote"}}' |
    CLAUDE_PROJECT_DIR="$proj" XDG_RUNTIME_DIR="$state" sh "$hook" 2>/dev/null)"
payloads=$((payloads + 1))
case "$got" in
    *'"permissionDecision":"deny"'*) ;;
    *)
        printf 'FAIL enforce  unconfigured want a refusal, got: %s\n' "$got"
        fail=$((fail + 1)) ;;
esac

# The plugin option turns it off, so the same call is advised instead. Claude
# Code exports a boolean option to a hook with an unspecified spelling, so every
# negative spelling has to count.
for spelling in false 0 off no; do
    got="$(printf '%s' '{"session_id":"en-opt-'"$spelling"'","tool_name":"Grep","tool_input":{"pattern":"requireRemote"}}' |
        CLAUDE_PLUGIN_OPTION_ENFORCE="$spelling" CLAUDE_PROJECT_DIR="$proj" \
        XDG_RUNTIME_DIR="$state" sh "$hook" 2>/dev/null)"
    payloads=$((payloads + 1))
    case "$got" in
        *'"deny"'*)
            printf 'FAIL enforce  option=%s want advice, got: %s\n' "$spelling" "$got"
            fail=$((fail + 1)) ;;
        *find_callers*) ;;
        *)
            printf 'FAIL enforce  option=%s want the hint, got: %s\n' "$spelling" "$got"
            fail=$((fail + 1)) ;;
    esac
done

# The env var overrides the option, for an install with no plugin or for one
# session.
got="$(printf '%s' '{"session_id":"en-override","tool_name":"Grep","tool_input":{"pattern":"requireRemote"}}' |
    CODEINDEX_ENFORCE=0 CLAUDE_PLUGIN_OPTION_ENFORCE=true CLAUDE_PROJECT_DIR="$proj" \
    XDG_RUNTIME_DIR="$state" sh "$hook" 2>/dev/null)"
payloads=$((payloads + 1))
case "$got" in
    *'"deny"'*)
        printf 'FAIL enforce  CODEINDEX_ENFORCE=0 want advice, got: %s\n' "$got"
        fail=$((fail + 1)) ;;
esac

rm -rf "$empty" "$proj"

if [ "$fail" -gt 0 ]; then
    printf '\n%d failure(s) across %d fixtures and %d payloads\n' \
        "$fail" "$checked" "$payloads" >&2
    exit 1
fi
printf 'hint classifier: %d fixtures (shell and python agree), %d payloads\n' \
    "$checked" "$payloads"

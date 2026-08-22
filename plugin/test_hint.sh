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

if [ "$fail" -gt 0 ]; then
    printf '\n%d disagreement(s) across %d fixtures\n' "$fail" "$checked" >&2
    exit 1
fi
printf 'hint classifier: %d fixtures, shell and python agree\n' "$checked"

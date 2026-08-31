#!/usr/bin/env bash
# Check that install.sh and the plugin launcher ask for asset names the release
# actually publishes, on every platform the release builds for.
#
# They did not. The release matrix builds Zig target triples and both scripts
# derived the name from uname, which disagrees on a Mac: `uname -s` says Darwin
# where the asset says macos, and Apple Silicon says arm64 where the asset says
# aarch64. So every Mac requested codeindex-arm64-darwin, got a 404, and fell
# through to a source build behind the message "No prebuilt binary" — which
# reads as a fact about the release rather than the bug it was. Nobody on a Mac
# ever installed a prebuilt binary.
#
# The matrix in .github/workflows/release.yml is the source of truth here. Add a
# target there without teaching the scripts about it and this fails, rather than
# a stranger's install falling back to needing a Zig toolchain.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname "$here")"
workflow="$root/.github/workflows/release.yml"

# Every artifact the release publishes.
published="$(sed -n 's/^ *artifact: *\(.*\)$/\1/p' "$workflow" | tr -d '\r' | sort -u)"
if [ -z "$published" ]; then
    echo "could not read the artifact list from $workflow" >&2
    exit 1
fi

# uname pairs a real machine reports, and the artifact each must resolve to.
# Left side is what `uname -m` and `uname -s` print; nothing here is a guess
# about the asset name — the assertion is that it appears in the matrix above.
cases="
x86_64|Linux|codeindex-x86_64-linux
amd64|Linux|codeindex-x86_64-linux
aarch64|Linux|codeindex-aarch64-linux
arm64|Linux|codeindex-aarch64-linux
x86_64|Darwin|codeindex-x86_64-macos
arm64|Darwin|codeindex-aarch64-macos
aarch64|Darwin|codeindex-aarch64-macos
x86_64|MINGW64_NT-10.0-22631|codeindex-x86_64-windows.exe
x86_64|MSYS_NT-10.0-19045|codeindex-x86_64-windows.exe
x86_64|CYGWIN_NT-10.0|codeindex-x86_64-windows.exe
aarch64|MINGW64_NT-10.0|codeindex-aarch64-windows.exe
arm64|MINGW64_NT-10.0|codeindex-aarch64-windows.exe
"

fake_uname_dir() {
    d="$(mktemp -d)"
    cat >"$d/uname" <<EOF
#!/bin/sh
case "\$1" in
    -m) echo "$1" ;;
    -s) echo "$2" ;;
    *)  echo "$2" ;;
esac
EOF
    chmod +x "$d/uname"
    printf '%s\n' "$d"
}

fail=0
checked=0

while IFS='|' read -r arch os want; do
    [ -n "${arch:-}" ] || continue
    checked=$((checked + 1))

    d="$(fake_uname_dir "$arch" "$os")"
    got_launch="$(PATH="$d:$PATH" sh "$here/bin/codeindex-launch" --artifact 2>/dev/null)"
    got_install="$(PATH="$d:$PATH" bash "$root/install.sh" --print-artifact 2>/dev/null)"
    rm -rf "$d"

    for name in "launcher:$got_launch" "install.sh:$got_install"; do
        who="${name%%:*}"
        got="${name#*:}"
        if [ "$got" != "$want" ]; then
            printf 'FAIL %-11s %s %-8s -> %s (want %s)\n' "$who" "$arch" "$os" "${got:-<none>}" "$want"
            fail=$((fail + 1))
            continue
        fi
        # The name must be one the release really publishes, not merely the one
        # the scripts agree on. Two scripts can agree and both be wrong.
        if ! printf '%s\n' "$published" | grep -qx "$got"; then
            printf 'FAIL %-11s %s %-8s -> %s is not published by the release matrix\n' \
                "$who" "$arch" "$os" "$got"
            fail=$((fail + 1))
        fi
    done
done <<EOF
$(printf '%s\n' "$cases")
EOF

# Every published artifact must be reachable from some real platform. An asset
# nobody can resolve is build time spent on a download that never happens.
while IFS= read -r asset; do
    [ -n "$asset" ] || continue
    if ! printf '%s\n' "$cases" | grep -q "|$asset\$"; then
        printf 'FAIL unreachable  %s is published but no uname pair resolves to it\n' "$asset"
        fail=$((fail + 1))
    fi
done <<EOF
$published
EOF

# The npm wrapper is the THIRD place this mapping is written, and it speaks a
# different vocabulary for the same six assets: Node says darwin/win32/x64 where
# uname says Darwin/MINGW64_NT/x86_64. Two scripts agreeing proved nothing when
# both were wrong about a Mac, so the wrapper is held to the same matrix.
node_checked=0
if command -v node >/dev/null 2>&1; then
    if ! node "$root/npm/bin/selftest.js" >/dev/null 2>&1; then
        printf 'FAIL npm wrapper  bin/selftest.js failed its own assertions\n'
        fail=$((fail + 1))
    fi
    node_table="$(node "$root/npm/bin/selftest.js" 2>/dev/null)"
    if [ -z "$node_table" ]; then
        printf 'FAIL npm wrapper  bin/selftest.js produced no mapping\n'
        fail=$((fail + 1))
    fi
    while IFS="$(printf '\t')" read -r platform arch asset; do
        [ -n "${asset:-}" ] || continue
        node_checked=$((node_checked + 1))
        checked=$((checked + 1))
        if ! printf '%s\n' "$published" | grep -qx "$asset"; then
            printf 'FAIL npm wrapper  %s/%s -> %s is not published by the release matrix\n' \
                "$platform" "$arch" "$asset"
            fail=$((fail + 1))
        fi
    done <<EOF
$node_table
EOF
    # Every published asset must be reachable from Node too, or an npx install
    # silently has fewer platforms than the release does.
    while IFS= read -r asset; do
        [ -n "$asset" ] || continue
        if ! printf '%s\n' "$node_table" | grep -q "	$asset\$"; then
            printf 'FAIL npm wrapper  %s is published but the wrapper resolves no platform to it\n' "$asset"
            fail=$((fail + 1))
        fi
    done <<EOF
$published
EOF
else
    printf '>>> SKIPPED the npm wrapper check: node is not installed here. <<<\n' >&2
    printf '>>> install.sh and the launcher were checked; the wrapper was NOT. <<<\n' >&2
fi

# ── Which shell runs a shipped script ────────────────────────────────────────
# Nobody chooses the shell for an installer. The README's one-liner says
# `curl … | bash`, a user typed `| sh`, and /bin/sh is dash on most Linux: the
# script died on `${BASH_SOURCE[0]}` — a bash array subscript — with "Bad
# substitution", before installing anything, and printed nothing that named the
# cause. `&>` is worse than a syntax error there: POSIX sh reads `cmd &>/dev/null`
# as "run cmd in the background", so a `command -v` test answers wrongly and
# silently.
#
# So every script that a stranger's shell may run is checked in every shell this
# machine has. Absent shells are reported as skipped, never as passed.
shell_scripts="
install.sh
plugin/bin/codeindex-launch
plugin/hooks/first-read-hint.sh
plugin/hooks/session-brief.sh
"
shells_checked=0
for candidate in dash "busybox sh" bash; do
    # shellcheck disable=SC2086
    set -- $candidate
    command -v "$1" >/dev/null 2>&1 || {
        printf '>>> SKIPPED the %s syntax check: not installed here. <<<\n' "$candidate" >&2
        continue
    }
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        shells_checked=$((shells_checked + 1))
        if ! $candidate -n "$root/$rel" 2>/dev/null; then
            printf 'FAIL shell  %s is not valid %s — a user whose sh is %s cannot run it\n' \
                "$rel" "$candidate" "$candidate"
            fail=$((fail + 1))
        fi
    done <<EOF
$shell_scripts
EOF
done

# The two constructs that broke it, matched outside comments. A syntax check
# cannot catch `&>`: it parses, and does the wrong thing.
while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    if grep -nE '&>|\$\{[A-Za-z_]+\[[0-9]' "$root/$rel" | grep -qv '^[0-9]*:[[:space:]]*#'; then
        printf 'FAIL shell  %s uses &> or a bash array; POSIX sh mis-reads both\n' "$rel"
        fail=$((fail + 1))
    fi
done <<EOF
$shell_scripts
EOF

if [ "$fail" -gt 0 ]; then
    printf '\n%d platform failure(s) across %d case(s)\n' "$fail" "$checked" >&2
    exit 1
fi
printf 'platform mapping: %d case(s) — install.sh, launcher and npm wrapper (%d) match the release matrix\n' \
    "$checked" "$node_checked"
printf 'shell portability: %d script/shell combination(s) parse\n' "$shells_checked"

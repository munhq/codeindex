#!/bin/sh
# PreToolUse hook: tell the codeindex relay the folder of each tool call.
#
# An MCP server never learns that the agent changed folders: a find_symbol call
# carries a name and no folder, and the client sends its roots once. The relay
# reads $XDG_RUNTIME_DIR/codeindex-follow/<pid> of its nearest ancestor before a
# tools/call line and moves the session to the project of that folder
# (zig/src/server/follow.zig). This hook writes that file, for the process above
# the hook and the processes above it, up to eight.
#
# The folder of a call:
#   - a path that the call names (file_path, notebook_path, path, or an
#     absolute path in a shell command that exists): its folder;
#   - a codeindex tool with no path: nothing, so the call answers from the
#     project of the call before it;
#   - any other call: the cwd of the call.
#
# Linux only: the process tree comes from /proc. The hook never blocks a call
# and prints nothing; every failure ends in exit 0.
set -u

[ -r /proc/self/stat ] || exit 0
base="${XDG_RUNTIME_DIR:-}"
[ -n "$base" ] || exit 0

payload="$(cat)"
flat="$(printf '%s' "$payload" | tr '\n\t' '  ')"

# One string field of the payload. The value ends at the first quote that is not
# escaped (see first-read-hint.sh for the case that broke a simpler pattern).
json_field() {
    printf '%s' "$flat" |
        sed -nE 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"((\\.|[^"\\])*)".*/\1/p' |
        head -1 |
        sed -e 's/\\"/"/g' -e 's/\\\\/\\/g'
}

# The folder of a path: the path itself when it is a folder, else its parent.
# Relative paths are taken from the cwd of the call.
folder_of() {
    p="$1"
    case "$p" in
        /*) ;;
        *) [ -n "$cwd" ] || return 1; p="$cwd/$p" ;;
    esac
    if [ -d "$p" ]; then
        printf '%s' "$p"
    elif [ -e "$p" ] || [ -d "$(dirname "$p")" ]; then
        dirname "$p"
    else
        return 1
    fi
}

# The first absolute path in a shell command that exists and is not a system
# folder. Quotes around a word are removed.
command_folder() {
    # shellcheck disable=SC2086
    for word in $1; do
        word="$(printf '%s' "$word" | sed -e "s/^[\"']//" -e "s/[\"';)]*\$//")"
        case "$word" in
            /proc/*|/dev/*|/sys/*|/usr/*|/etc/*|/bin/*|/sbin/*|/lib*|/tmp|/tmp/*) continue ;;
            /*) [ -e "$word" ] || continue; folder_of "$word" && return 0 ;;
        esac
    done
    return 1
}

tool="$(json_field tool_name)"
cwd="$(json_field cwd)"

folder=""
for key in file_path notebook_path path; do
    value="$(json_field "$key")"
    if [ -n "$value" ]; then
        folder="$(folder_of "$value")" || folder=""
        [ -n "$folder" ] && break
    fi
done
if [ -z "$folder" ] && [ "$tool" = Bash ]; then
    folder="$(command_folder "$(json_field command)")" || folder=""
fi
if [ -z "$folder" ]; then
    case "$tool" in
        mcp__*codeindex*) exit 0 ;;
    esac
    folder="$cwd"
fi
case "$folder" in
    /*) ;;
    *) exit 0 ;;
esac

dir="$base/codeindex-follow"
mkdir -p "$dir" 2>/dev/null && chmod 700 "$dir" 2>/dev/null || exit 0

pid="$PPID"
depth=0
while [ "$pid" -gt 1 ] 2>/dev/null && [ "$depth" -lt 8 ]; do
    file="$dir/$pid"
    if [ "$(cat "$file" 2>/dev/null)" != "$folder" ]; then
        printf '%s\n' "$folder" >"$file.$$" 2>/dev/null && mv -f "$file.$$" "$file" 2>/dev/null
    fi
    stat="$(cat "/proc/$pid/stat" 2>/dev/null)" || break
    # The name of the process sits in parentheses and may hold spaces, so the
    # fields are counted from the last ") ": state, then the parent pid.
    rest="${stat##*) }"
    # shellcheck disable=SC2086
    set -- $rest
    pid="${2:-0}"
    depth=$((depth + 1))
done

# The file of a process that has ended can name a pid that another process
# gets later.
for file in "$dir"/*; do
    name="${file##*/}"
    case "$name" in
        *[!0-9]*|'') continue ;;
    esac
    [ -d "/proc/$name" ] || rm -f "$file"
done
exit 0

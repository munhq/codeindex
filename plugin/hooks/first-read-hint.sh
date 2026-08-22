#!/bin/sh
# PreToolUse hook: point the agent at a structural query when it is about to
# answer a code question by scanning bytes.
#
# Why a hook and not only the skill: the skill applies when the model elects to
# load it, which makes adoption probabilistic. This fires from the harness at
# the moment the advice is actionable.
#
# Why it matches Bash and not only Read/Grep/Glob: with auto mode active the
# harness tells the agent to do file work through Bash — `cat`, `sed -n`,
# `grep`, `find` — rather than the dedicated tools. The matcher used to be
# `Read|Grep|Glob`, so in exactly that mode `tool_name` was `Bash`, nothing
# matched, and no hint ever fired. The guidance guarded a channel that mode does
# not use. An agent then grepped for an identifier in a 4,000-line file and
# never learned that `find_callers` answers the same question in one call.
#
# Contract (see code.claude.com/docs/en/hooks):
#   - Exit 0 with plain text on stdout → the text is added to the model's
#     context as guidance. Deliberately NOT the JSON form with
#     permissionDecision:"allow": that would suppress the permission prompt for
#     the matched tools, which is a side effect nobody asked this hook for.
#   - stdout becomes context, so it must carry the guidance and nothing else.
#     Diagnostics go to stderr.
#   - This hook never blocks or rewrites a call. Every failure path — a payload
#     it cannot parse, a command it cannot classify — degrades to silence, never
#     to a broken tool call.
#
# Fires ONCE per session, and only for a command that a structural tool actually
# answers better. A reminder on every read would spend more context than the
# tools save, which would make this hook self-defeating.
set -u

STATE_DIR="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/codeindex-hints"

# ── What counts as a code question ────────────────────────────────────────────
# Kept deliberately narrow. A hint that fires on ordinary text work is worse
# than no hint: it costs context every session and teaches the agent to skip
# whatever this hook says.

# Tools that scan file contents for a pattern.
SEARCH_CMDS="grep egrep fgrep rg ag ack"
# Tools that print a file, or part of one.
READ_CMDS="cat head tail less more bat"

# Source files, where an outline or a single symbol beats the whole file.
SRC_EXT='\.\(ts\|tsx\|js\|jsx\|mjs\|cjs\|py\|go\|rs\|zig\|c\|h\|cc\|cpp\|hpp\|hh\|java\|kt\|kts\|rb\|swift\|dart\|scala\|ex\|exs\|erl\|php\|cs\|lua\|sol\|proto\|m\|mm\|sh\|bash\)$'

# Paths where a structural answer does not exist, so the hint would be noise.
# Config and data formats are excluded on purpose even though codeindex parses
# several of them: an agent greps a yaml or a json many times a session, and a
# reminder on each is exactly the self-defeating case described above.
NOISE='node_modules\|/\.git/\|/proc/\|/var/log\|/dist/\|/build/\|/vendor/\|/target/\|/zig-out/\|\.min\.\|\.lock$\|\.log$\|\.json$\|\.jsonl$\|\.ya\?ml$\|\.toml$\|\.ini$\|\.env\|\.csv$\|\.tsv$\|\.txt$\|\.md$\|\.pem$\|\.sum$'

# An identifier, not a phrase and not a regex. `requireRemote` is a code
# question; "is not logged in" and `TODO.*#[0-9]+` are text questions, and grep
# is the right tool for those. Three characters minimum keeps `-e`, `up` and
# other flag-shaped fragments out.
is_identifier() {
    printf '%s' "$1" | grep -q '^[A-Za-z_][A-Za-z0-9_]\{2,\}$'
}

is_source_path() {
    printf '%s' "$1" | grep -q "$SRC_EXT" && ! printf '%s' "$1" | grep -q "$NOISE"
}

# Strip one layer of surrounding quotes.
unquote() {
    printf '%s' "$1" | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"
}

# Classify a shell command. Prints "<kind>\t<subject>" and returns 0 when a
# structural tool answers it better; prints nothing and returns 1 otherwise.
#
# kind is one of:
#   ident   subject is an identifier being searched for
#   file    subject is a source file being printed
#
# Both the pattern and the target matter. Checking only the pattern fired on
# `grep -rn ERROR /var/log/syslog` and `grep -n version package.json`, because
# ERROR and version are identifier-shaped. There is no symbol to look up in a
# log or a manifest, so a hint there is pure noise.
classify_command() {
    cmd="$1"
    verb=""
    positionals=""
    has_count_flag=0
    skip_next=0

    # shellcheck disable=SC2086
    for tok in $cmd; do
        # Anything after a shell operator is a different command.
        case "$tok" in
            \||\|\||\&\&|\;|\>|\>\>|\<) break ;;
        esac

        if [ "$skip_next" = 1 ]; then
            skip_next=0
            continue
        fi

        if [ -z "$verb" ]; then
            # Leading VAR=value assignments are environment, not the command.
            case "$tok" in
                *=*) continue ;;
            esac
            base="${tok##*/}"
            case " $SEARCH_CMDS " in *" $base "*) verb=search ;; esac
            case " $READ_CMDS " in *" $base "*) verb=read ;; esac
            [ "$base" = sed ] && verb=read
            [ "$base" = git ] && verb=git
            [ -n "$verb" ] && continue
            return 1
        fi

        # `git grep` is a code question; every other git subcommand is not.
        if [ "$verb" = git ]; then
            case "$tok" in
                grep) verb=search; continue ;;
                -*) continue ;;
                *) return 1 ;;
            esac
        fi

        case "$tok" in
            # Flags that take the following token as their value. -e is the
            # exception: its value IS the pattern, so it is not skipped.
            -A|-B|-C|-m|-f|--include|--exclude|--exclude-dir)
                skip_next=1
                continue
                ;;
            -e) continue ;;
            --*) continue ;;
            -*)
                # A short-flag cluster containing c means "count matches", which
                # is a counting question, not a structural one.
                case "$tok" in *c*) has_count_flag=1 ;; esac
                continue
                ;;
        esac

        positionals="$positionals $(unquote "$tok")"
    done

    [ -n "$verb" ] || return 1

    if [ "$verb" = search ]; then
        [ "$has_count_flag" = 1 ] && return 1
        case "$cmd" in
            *"| wc"*|*"|wc"*) return 1 ;;
        esac

        # The first positional is the pattern; the rest are where to look.
        pattern=""
        targets=""
        for tok in $positionals; do
            if [ -z "$pattern" ]; then
                pattern="$tok"
            else
                targets="$targets $tok"
            fi
        done
        is_identifier "$pattern" || return 1

        # A target list that is entirely noise means there is no symbol to look
        # up. No target at all searches the tree, which is a code question.
        if [ -n "$targets" ]; then
            for tok in $targets; do
                printf '%s' "$tok" | grep -q "$NOISE" || {
                    printf 'ident\t%s\n' "$pattern"
                    return 0
                }
            done
            return 1
        fi
        printf 'ident\t%s\n' "$pattern"
        return 0
    fi

    for tok in $positionals; do
        if is_source_path "$tok"; then
            printf 'file\t%s\n' "$tok"
            return 0
        fi
    done
    return 1
}

# Exercised directly by plugin/test_hint.sh and cross-checked against the
# Python classifier in plugin/measure_routing.py, so the hint and the
# measurement never disagree about what counts as a code question.
if [ "${1:-}" = "--classify" ]; then
    classify_command "${2:-}" || exit 1
    exit 0
fi

# ── Payload ───────────────────────────────────────────────────────────────────
# Pull single fields out of the hook payload without requiring jq or python at
# runtime. Tolerant by design: a field this cannot read leaves the hint generic
# or silent, and never breaks the call being made.
payload="$(cat)"
flat="$(printf '%s' "$payload" | tr '\n\t' '  ')"

json_field() {
    printf '%s' "$flat" |
        sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" |
        head -1
}

session="$(json_field session_id)"
tool="$(json_field tool_name)"
if [ -z "$session" ]; then
    # Fall back to a per-day key so a parse failure degrades to "rarely" rather
    # than "on every call".
    session="fallback-$(date -u +%Y%m%d)"
fi

# Decide whether this call deserves a hint, and what to name in it.
kind=""
subject=""
case "$tool" in
    Bash)
        command_str="$(json_field command)"
        [ -n "$command_str" ] || exit 0
        result="$(classify_command "$command_str")" || exit 0
        kind="${result%%	*}"
        subject="${result#*	}"
        ;;
    Grep)
        pattern="$(json_field pattern)"
        if is_identifier "$pattern"; then
            kind=ident
            subject="$pattern"
        else
            kind=generic
        fi
        ;;
    Read)
        path="$(json_field file_path)"
        if is_source_path "$path"; then
            kind=file
            subject="$path"
        else
            exit 0
        fi
        ;;
    Glob|"")
        kind=generic
        ;;
    *)
        exit 0
        ;;
esac

# ── Once per session ──────────────────────────────────────────────────────────
# The marker is written only when a hint is actually printed. It used to be
# written before the decision, so a call that produced no hint still spent the
# session's one chance and the real miss later went unaddressed.
key="$(printf '%s' "$session" | tr -c 'A-Za-z0-9._-' '_')"
marker="$STATE_DIR/$key"

mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
[ -e "$marker" ] && exit 0
: > "$marker" 2>/dev/null || exit 0

# ── The hint ──────────────────────────────────────────────────────────────────
# Name the tool that answers THIS question, with the identifier or path already
# substituted. A generic menu did not change the routing decision: an agent that
# knew these tools existed still ran grep, because nothing connected the tool it
# was reaching for to the tool that answers better.
#
# Tools are named bare. The live prefix depends on the install —
# `mcp__codeindex__` when the server is registered directly,
# `mcp__plugin_codeindex_codeindex__` when the plugin registers it — and this
# hook cannot see which. Printing one form named a tool that does not exist in
# the other install, which costs a failed call and sends the agent straight back
# to the scan. The agent already has the real names in its tool list.
case "$kind" in
    ident)
        cat <<HINT
codeindex is available here, and it answers this about \`$subject\` in one call
instead of a scan:
  what calls it        -> find_callers $subject
  where it is defined  -> find_symbol $subject
  every mention of it  -> find_word $subject
Match the tool by its bare name; your tool list shows the live prefix. Keep
grep for plain text — a phrase, an error string, a config value — where it is
the right instrument.
HINT
        ;;
    file)
        cat <<HINT
codeindex is available here, and reading $subject whole is usually not the
cheapest answer:
  what is in it        -> get_outline $subject
  one function from it -> read_symbol <name>
  what breaks if it changes -> get_change_impact $subject
Match the tool by its bare name; your tool list shows the live prefix. Keep
reading the bytes when you need them exactly — before an Edit, or when
whitespace matters.
HINT
        ;;
    *)
        cat <<'HINT'
codeindex is available in this session, and most code questions have a cheaper
answer than reading the file. Match the codeindex tool by its bare name:
  - where is X defined  -> find_symbol
  - show me function X  -> read_symbol
  - what is in this file -> get_outline
  - where is X used     -> find_word (exact) / search (text)
  - what calls X        -> find_callers
  - what breaks if I change this -> get_change_impact, plan_change
Keep reading the bytes when you need them exactly — before an Edit, or when
whitespace matters. Every file-scoped tool takes `path`, never `file`.
HINT
        ;;
esac
exit 0

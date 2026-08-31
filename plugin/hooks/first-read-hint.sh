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
# Fires on the 1st, 8th and 25th code question of a session, and only for a
# command that a structural tool actually answers better. A reminder on every
# read would spend more context than the tools save, which would make this hook
# self-defeating; one reminder per session proved too few. Measured on the
# session that prompted this change: 17 code questions went to grep, the hook
# spent its single chance on the first of them, and the routing never changed.
# The 8th and 25th are one line each. An agent that has passed over three
# reminders is deciding, not forgetting, and a fourth would only cost context.
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

# Classify ONE command, already split off the line and free of shell
# operators. Prints "<kind>\t<subject>" and returns 0 when a structural tool
# answers it better; prints nothing and returns 1 otherwise.
#
# kind is one of:
#   ident   subject is an identifier being searched for
#   file    subject is a source file being printed
#
# Both the pattern and the target matter. Checking only the pattern fired on
# `grep -rn ERROR /var/log/syslog` and `grep -n version package.json`, because
# ERROR and version are identifier-shaped. There is no symbol to look up in a
# log or a manifest, so a hint there is pure noise.
classify_segment() {
    seg="$1"
    # 1 when a pipe feeds this command, so its input is a previous command's
    # output and not the source tree.
    piped="${2:-0}"
    verb=""
    positionals=""
    has_count_flag=0
    has_invert_flag=0
    skip_next=0

    # shellcheck disable=SC2086
    for tok in $seg; do
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
            --invert-match) has_invert_flag=1; continue ;;
            --*) continue ;;
            -*)
                # A short-flag cluster containing c means "count matches", which
                # is a counting question, not a structural one. One containing v
                # inverts the match: `grep -v test` excludes the identifier, so
                # it is not a question about that identifier at all.
                case "$tok" in *c*) has_count_flag=1 ;; esac
                case "$tok" in *v*) has_invert_flag=1 ;; esac
                continue
                ;;
        esac

        positionals="$positionals $(unquote "$tok")"
    done

    [ -n "$verb" ] || return 1

    if [ "$verb" = search ]; then
        [ "$has_count_flag" = 1 ] && return 1
        [ "$has_invert_flag" = 1 ] && return 1

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

        # No target at all searches the tree — but only when the input IS the
        # tree. After a pipe, grep filters what the previous command printed:
        # `grep -rn cap --include=*.ts src/ | grep -v test` matched here as a
        # search for `test`, which is noise, and noise teaches the agent to
        # skip whatever this hook says.
        [ "$piped" = 1 ] && return 1
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

# Classify a whole command LINE, which is what the payload carries. The agent
# almost never runs a bare command: with auto mode active it writes
# `cd /repo; sed -n '1,75p' src/x.ts` or `echo "=== x ==="; grep -rn foo src/`,
# because the harness asks for absolute paths and routes file work through Bash.
#
# This used to read only the first command of such a line, find `cd` or `echo`
# where it wanted a verb, and give up. Measured on the session that prompted the
# fix: 73 Bash calls, 0 hints, where 17 were owed — and the first miss was the
# session's very first tool call, so the hint was absent for the whole session.
#
# So split the line and classify each command in turn; the first hit wins.
# The split is quote-blind, exactly like the whitespace tokenizer above. A `|`
# inside a grep pattern therefore ends a segment early, which leaves a pattern
# that is no longer an identifier, so the verdict stays "none" — the same answer
# a quote-aware split gives, without a second parser to keep in step.
classify_command() {
    cmd="$1"

    # A counting question is not a structural one, wherever the pipe sits.
    case "$cmd" in
        *"| wc"*|*"|wc"*) return 1 ;;
    esac

    # Everything after a heredoc marker is data, not commands. Without this the
    # body of `cat > f.mjs <<'EOF' ... EOF` is scanned as a command line, and
    # any line of it that ends in `;` starts a command that was never run.
    head_of_line="${cmd%%<<*}"

    # `;` `&` `<` `>` and newlines all end a command. tr, not a token scan: the
    # operator is usually glued to its neighbour — `/repo;`, `2>&1`. `|` ends a
    # command too, but it is kept and split below, because what follows a pipe
    # reads stdin rather than the tree and must be told so.
    while IFS= read -r line; do
        piped=0
        while [ -n "$line" ]; do
            case "$line" in
                *"|"*) seg="${line%%|*}"; line="${line#*|}" ;;
                *)     seg="$line";       line="" ;;
            esac
            if [ -n "$seg" ]; then
                classify_segment "$seg" "$piped" && return 0
            fi
            piped=1
        done
    done <<SEGMENTS
$(printf '%s' "$head_of_line" | tr ';&<>' '\n\n\n\n')
SEGMENTS
    return 1
}

# How many real commands a line runs. Enforcement (below) refuses a scan only
# when the scan is the whole line: `cd /repo; npm test; grep -rn Foo src/` also
# runs the test suite, and refusing that would refuse the work as well as the
# scan. `cd`, `echo`, `printf` and `pwd` do not count — the agent writes those to
# frame a command, not to do anything.
count_real_segments() {
    _n=0
    while IFS= read -r _line; do
        while [ -n "$_line" ]; do
            case "$_line" in
                *"|"*) _seg="${_line%%|*}"; _line="${_line#*|}" ;;
                *)     _seg="$_line";      _line="" ;;
            esac
            for _tok in $_seg; do
                case "$_tok" in
                    *=*) continue ;;
                esac
                case "${_tok##*/}" in
                    cd|echo|printf|pwd|true|:) ;;
                    *) _n=$((_n + 1)) ;;
                esac
                break
            done
        done
    done <<SEGS
$(printf '%s' "${1%%<<*}" | tr ';&<>' '\n\n\n\n')
SEGS
    printf '%s' "$_n"
}

# Exercised directly by plugin/test_hint.sh and cross-checked against the
# Python classifier in plugin/measure_routing.py, so the hint and the
# measurement never disagree about what counts as a code question.
if [ "${1:-}" = "--classify" ]; then
    classify_command "${2:-}" || exit 1
    exit 0
fi
if [ "${1:-}" = "--segments" ]; then
    count_real_segments "${2:-}"
    printf '\n'
    exit 0
fi

# ── Payload ───────────────────────────────────────────────────────────────────
# Pull single fields out of the hook payload without requiring jq or python at
# runtime. Tolerant by design: a field this cannot read leaves the hint generic
# or silent, and never breaks the call being made.
payload="$(cat)"
flat="$(printf '%s' "$payload" | tr '\n\t' '  ')"

# A JSON string value ends at the first quote that is NOT escaped, so
# `[^"]*` is wrong. On
#   "command":"cd /repo; echo \"=== x ===\"; sed -n '1,5p' a.ts"
# it stopped at the first \" and returned `cd /repo; echo \`, so every
# command that contained a double quote was classified on a stub — a second
# reason no hint fired on real sessions, and one the --classify fixtures cannot
# see because they hand the command over already parsed. Match the escapes
# explicitly, then undo the JSON escaping the classifier must not see.
json_field() {
    printf '%s' "$flat" |
        sed -nE 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"((\\.|[^"\\])*)".*/\1/p' |
        head -1 |
        sed -e 's/\\n/ /g' -e 's/\\t/ /g' -e 's/\\"/"/g' -e 's/\\\\/\\/g'
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

# ── Enforcement ──────────────────────────────────────────────────────────────
# A reminder is advice, and advice loses to habit. Measured with
# plugin/measure_routing.py over one machine's last two days: 215 code questions
# went to a scan, 2 went to the index, and the reminder had fired in 9 of the 12
# sessions. Three reminders would have made that four. So the narrow case where
# the index is strictly better is refused rather than argued with.
#
# ON by default, and switched off in one click: `enforce` is a plugin option
# (plugin.json → userConfig), which Claude Code exports to this hook as
# CLAUDE_PLUGIN_OPTION_ENFORCE. Nobody edits a settings file by hand to get this
# behaviour, and nobody edits one to be rid of it. CODEINDEX_ENFORCE overrides
# the option, for an install without the plugin or a single session.
#
# Deliberately narrow, in three ways that keep it from ever being the reason a
# session cannot proceed:
#   1. Searches only. A pre-edit read has no structural equivalent — the harness
#      requires the exact bytes before an Edit — so `kind=file` is never refused.
#   2. Only when the scan is the whole command line, so a line that also builds
#      or tests is never refused for the grep at the end of it.
#   3. Only while a snapshot exists for THIS project, and at most three times per
#      session. After that the hook goes back to advice, so an agent can always
#      finish its work even when the index is wrong or absent.
enforce_on() {
    # The env var wins where it is set; the plugin option decides otherwise.
    # A boolean plugin option's exported spelling is not specified, so every
    # plausible negative spelling counts as off and everything else as on.
    _enforce="${CODEINDEX_ENFORCE:-}"
    [ -n "$_enforce" ] || _enforce="${CLAUDE_PLUGIN_OPTION_ENFORCE:-}"
    case "$_enforce" in
        0 | false | FALSE | False | no | NO | off | OFF) return 1 ;;
        *) return 0 ;;
    esac
}

DENY_LIMIT=3

if [ "$kind" = ident ] && enforce_on; then
    project_root="${CLAUDE_PROJECT_DIR:-$PWD}"
    if [ -f "$project_root/.codeindex.json" ]; then
        sole=1
        if [ "$tool" = Bash ]; then
            [ "$(count_real_segments "$command_str")" = 1 ] || sole=0
        fi
        if [ "$sole" = 1 ]; then
            dkey="$(printf '%s' "$session" | tr -c 'A-Za-z0-9._-' '_')"
            dmarker="$STATE_DIR/$dkey.deny"
            mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
            denied=0
            if [ -r "$dmarker" ]; then
                denied="$(cat "$dmarker" 2>/dev/null)"
                case "$denied" in
                    '' | *[!0-9]*) denied=0 ;;
                esac
            fi
            if [ "$denied" -lt "$DENY_LIMIT" ]; then
                printf '%s' "$((denied + 1))" > "$dmarker" 2>/dev/null || exit 0
                # One line of JSON, and nothing else: stdout is the decision
                # channel here, not context. The reason IS what the model reads.
                printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"codeindex answers this about %s%s"}}\n' \
                    "$subject" \
                    " in one call, and this scan was refused so it gets used: find_callers (what calls it), find_symbol (where it is defined), find_word (every mention). Call the tool by its bare name; your tool list shows the live prefix. If the result is empty, call status and check files > 0 and workspace = this repository, then index_workspace with the project path if it is not. If you truly need the raw scan, this hook stops refusing after $DENY_LIMIT refusals in a session."
                exit 0
            fi
        fi
    fi
fi

# ── Cadence ───────────────────────────────────────────────────────────────────
# The marker counts the code questions of this session, and is written only when
# a call actually carries one: a call that produced no hint must not advance the
# count, or noise would consume the reminders that matter.
HINT_ON="1 8 25"

key="$(printf '%s' "$session" | tr -c 'A-Za-z0-9._-' '_')"
marker="$STATE_DIR/$key"

mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
seen=0
if [ -r "$marker" ]; then
    seen="$(cat "$marker" 2>/dev/null)"
    # A marker from an older version of this hook is an empty file. Anything
    # that is not a number restarts the count rather than breaking arithmetic.
    case "$seen" in
        '' | *[!0-9]*) seen=0 ;;
    esac
fi
seen=$((seen + 1))
printf '%s' "$seen" > "$marker" 2>/dev/null || exit 0

due=0
for n in $HINT_ON; do
    [ "$seen" = "$n" ] && due=1
done
[ "$due" = 1 ] || exit 0

# The first reminder explains. A later one only names the tool: by then the
# agent has read the full form once, and repeating it would spend the tokens the
# hook exists to save.
if [ "$seen" != 1 ]; then
    case "$kind" in
        ident)
            printf 'codeindex answers this about `%s` in one call: find_callers / find_symbol / find_word %s. Bare name; your tool list shows the prefix.\n' "$subject" "$subject"
            ;;
        file)
            printf 'codeindex answers this about %s in one call: get_outline, then read_symbol for the one function you want.\n' "$subject"
            ;;
        *)
            printf 'codeindex is still available: find_symbol / read_symbol / get_outline / find_word / find_callers answer this more cheaply than a scan.\n'
            ;;
    esac
    exit 0
fi

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
Match the tool by its bare name; your tool list shows the live prefix. If that
list defers MCP schemas, load these first (ToolSearch) and then call. Keep
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
Match the tool by its bare name; your tool list shows the live prefix. If that
list defers MCP schemas, load these first (ToolSearch) and then call. Keep
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
If your tool list defers MCP schemas, load these first (ToolSearch) and then
call. Keep reading the bytes when you need them exactly — before an Edit, or
when whitespace matters. Every file-scoped tool takes `path`, never `file`.
HINT
        ;;
esac
exit 0

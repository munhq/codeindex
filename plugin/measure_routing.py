#!/usr/bin/env python3
"""Count how agents actually answer code questions, per session.

Every claim about whether a skill or a hook changes behaviour has been anecdote:
someone notices an agent grepped when it should have called `find_callers`, or
notices it did the right thing once. Anecdote cannot tell you whether a change
helped, and it cannot tell you when a regression started.

This reads the session transcripts already on disk and counts, per session:

  scanned   a code question answered by scanning bytes — a grep for a bare
            identifier, or a source file printed whole. This is the behaviour
            the hint exists to redirect, and it uses the SAME classification the
            hook uses (see plugin/hooks/testdata/commands.tsv).
  structural a codeindex tool call, under either registration prefix.
  hinted    whether the hook fired in this session, so the routed %\n            of hinted and unhinted sessions can be compared directly.

The ratio structural / (structural + scanned) is the number to watch. Run it
before and after a change to the skill or the hook and compare, rather than
recalling how it felt.

Counting only tool calls keeps this honest: it never reads what the agent said
about its own behaviour, only what it did.

Usage:
  measure_routing.py                      every Claude home, last 30 days
  measure_routing.py --days 7 --by-day    daily series, to see a change land
  measure_routing.py --project codeindex  one project
  measure_routing.py --sessions           worst-offending sessions first
  measure_routing.py --classify '<cmd>'   classify one command (used by tests)
"""
import argparse
import json
import os
import re
import shlex
import sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone

# ── The classifier ───────────────────────────────────────────────────────────
# Mirrors plugin/hooks/first-read-hint.sh. plugin/test_hint.sh runs both against
# plugin/hooks/testdata/commands.tsv and fails when they disagree, because a
# measurement that counted a different set of commands than the hint fires on
# would answer a question nobody asked.

SEARCH_CMDS = {"grep", "egrep", "fgrep", "rg", "ag", "ack"}
READ_CMDS = {"cat", "head", "tail", "less", "more", "bat", "sed"}

SRC_EXT = re.compile(
    r"\.(ts|tsx|js|jsx|mjs|cjs|py|go|rs|zig|c|h|cc|cpp|hpp|hh|java|kt|kts|rb|"
    r"swift|dart|scala|ex|exs|erl|php|cs|lua|sol|proto|m|mm|sh|bash)$"
)
NOISE = re.compile(
    r"node_modules|/\.git/|/proc/|/var/log|/dist/|/build/|/vendor/|/target/|"
    r"/zig-out/|\.min\.|\.lock$|\.log$|\.json$|\.jsonl$|\.ya?ml$|\.toml$|"
    r"\.ini$|\.env|\.csv$|\.tsv$|\.txt$|\.md$|\.pem$|\.sum$"
)
IDENTIFIER = re.compile(r"^[A-Za-z_][A-Za-z0-9_]{2,}$")

# Flags that consume the following token, so it is not the pattern.
VALUE_FLAGS = {"-A", "-B", "-C", "-m", "-f", "--include", "--exclude",
               "--exclude-dir"}


def is_source_path(text):
    return bool(SRC_EXT.search(text)) and not NOISE.search(text)


def classify_command(cmd):
    """Return (kind, subject): ("ident"|"file", str) or ("none", "").

    Both the pattern and the target matter. Checking only the pattern counted
    `grep -rn ERROR /var/log/syslog` and `grep -n version package.json` as code
    questions, because ERROR and version are identifier-shaped. There is no
    symbol to look up in a log or a manifest.
    """
    if not cmd:
        return ("none", "")

    if re.search(r"\|\s*wc\b", cmd):
        return ("none", "")

    try:
        tokens = shlex.split(cmd)
    except ValueError:
        return ("none", "")
    if not tokens:
        return ("none", "")

    # Stop at the first shell operator: what follows is a different command.
    for i, t in enumerate(tokens):
        if t in {"|", "||", "&&", ";", ">", "<", ">>"}:
            tokens = tokens[:i]
            break
    if not tokens:
        return ("none", "")

    # Leading VAR=value assignments are environment, not the command.
    while tokens and "=" in tokens[0] and not tokens[0].startswith("-"):
        tokens = tokens[1:]
    if not tokens:
        return ("none", "")

    verb_tok = os.path.basename(tokens[0])
    rest = tokens[1:]

    if verb_tok == "git":
        # `git grep` is a code question; every other git subcommand is not.
        positional = [t for t in rest if not t.startswith("-")]
        if not positional or positional[0] != "grep":
            return ("none", "")
        verb = "search"
        rest = [t for t in rest if t.startswith("-")] + positional[1:]
    elif verb_tok in SEARCH_CMDS:
        verb = "search"
    elif verb_tok in READ_CMDS:
        verb = "read"
    else:
        return ("none", "")

    positionals = []
    skip_next = False
    for tok in rest:
        if skip_next:
            skip_next = False
            continue
        if tok in VALUE_FLAGS:
            skip_next = True
            continue
        if tok == "-e":
            continue
        if tok.startswith("--"):
            continue
        if tok.startswith("-"):
            # A short-flag cluster containing c means "count matches", which is
            # a counting question, not a structural one.
            if verb == "search" and "c" in tok[1:]:
                return ("none", "")
            continue
        positionals.append(tok)

    if verb == "search":
        if not positionals:
            return ("none", "")
        pattern, targets = positionals[0], positionals[1:]
        if not IDENTIFIER.match(pattern):
            return ("none", "")
        # A target list that is entirely noise means there is no symbol to look
        # up. No target at all searches the tree, which is a code question.
        if targets and all(NOISE.search(t) for t in targets):
            return ("none", "")
        return ("ident", pattern)

    for tok in positionals:
        if is_source_path(tok):
            return ("file", tok)
    return ("none", "")


# ── Transcript reading ───────────────────────────────────────────────────────
# Claude Code writes one JSONL file per session under <home>/projects/<slug>/.
# Reading those directly, rather than a database, means this works on any
# machine that has run the agent, with no indexing step first.

CODEINDEX_TOOL = re.compile(r"^mcp__(?:plugin_codeindex_)?codeindex(?:_codeindex)?__(.+)$")


def claude_homes():
    home = os.path.expanduser("~")
    found = []
    env = os.environ.get("CLAUDE_CONFIG_DIR")
    if env:
        found.append(env)
    for name in sorted(os.listdir(home)):
        if not name.startswith(".claude"):
            continue
        path = os.path.join(home, name)
        # Every real Claude Code home holds .claude.json. The name alone also
        # matches ~/.claude-mem and ~/.claude-desktop, which are not.
        if os.path.isfile(os.path.join(path, ".claude.json")):
            found.append(path)
    seen, out = set(), []
    for p in found:
        real = os.path.realpath(p)
        if real not in seen:
            seen.add(real)
            out.append(real)
    return out


def iter_transcripts(homes, project=None):
    for home in homes:
        root = os.path.join(home, "projects")
        if not os.path.isdir(root):
            continue
        for slug in sorted(os.listdir(root)):
            if project and project not in slug:
                continue
            d = os.path.join(root, slug)
            if not os.path.isdir(d):
                continue
            for fn in sorted(os.listdir(d)):
                if fn.endswith(".jsonl"):
                    yield slug, os.path.join(d, fn)


def tool_calls(path):
    """Yield (timestamp, tool_name, tool_input) for every tool call."""
    try:
        with open(path, "r", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line or '"tool_use"' not in line:
                    continue
                try:
                    ev = json.loads(line)
                except Exception:
                    continue
                ts = ev.get("timestamp") or ""
                msg = ev.get("message") or {}
                content = msg.get("content")
                if not isinstance(content, list):
                    continue
                for block in content:
                    if not isinstance(block, dict):
                        continue
                    if block.get("type") != "tool_use":
                        continue
                    yield ts, block.get("name") or "", block.get("input") or {}
    except OSError:
        return


def parse_ts(ts):
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except Exception:
        return None


# The first line of every hint this hook prints. Its presence in a transcript
# means the hook fired in that session, which is what makes a before/after
# comparison self-evidencing rather than a matter of recall.
HINT_MARK = "codeindex is available"


def measure(homes, days, project):
    cutoff = datetime.now(timezone.utc) - timedelta(days=days)
    sessions = {}
    # Per-day counters are accumulated per CALL, not per session. Attributing a
    # session's whole total to the day it started put a week of work on one date
    # and made the series useless for seeing when a change landed.
    days_acc = defaultdict(lambda: [0, 0])
    for slug, path in iter_transcripts(homes, project):
        sid = os.path.basename(path)[:-6]
        rec = {
            "project": slug, "scanned": 0, "structural": 0,
            "hinted": transcript_mentions(path, HINT_MARK),
            "by_tool": defaultdict(int), "examples": [], "day": None,
        }
        for ts, name, inp in tool_calls(path):
            when = parse_ts(ts)
            if when and when < cutoff:
                continue
            day = when.date().isoformat() if when else None
            if day and rec["day"] is None:
                rec["day"] = day

            m = CODEINDEX_TOOL.match(name)
            if m:
                rec["structural"] += 1
                rec["by_tool"][m.group(1)] += 1
                if day:
                    days_acc[day][0] += 1
                continue

            kind, subject = "none", ""
            if name == "Bash":
                kind, subject = classify_command(inp.get("command") or "")
            elif name == "Grep":
                pat = inp.get("pattern") or ""
                if IDENTIFIER.match(pat):
                    kind, subject = "ident", pat
            elif name == "Read":
                fp = inp.get("file_path") or ""
                if is_source_path(fp):
                    kind, subject = "file", fp

            if kind != "none":
                rec["scanned"] += 1
                if day:
                    days_acc[day][1] += 1
                if len(rec["examples"]) < 3:
                    rec["examples"].append(f"{kind}:{subject}")

        if rec["scanned"] or rec["structural"]:
            sessions[sid] = rec
    return sessions, days_acc


def transcript_mentions(path, needle):
    try:
        with open(path, "r", errors="replace") as fh:
            for line in fh:
                if needle in line:
                    return True
    except OSError:
        pass
    return False


def ratio(structural, scanned):
    total = structural + scanned
    return (structural / total * 100) if total else 0.0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--classify", metavar="CMD",
                    help="classify one shell command and exit (used by tests)")
    ap.add_argument("--days", type=int, default=30)
    ap.add_argument("--project", help="substring of the project slug")
    ap.add_argument("--by-day", action="store_true",
                    help="daily series, to see whether a change landed")
    ap.add_argument("--sessions", action="store_true",
                    help="list sessions, least structural first")
    args = ap.parse_args()

    if args.classify is not None:
        kind, subject = classify_command(args.classify)
        print(f"{kind}\t{subject}")
        return 0

    homes = claude_homes()
    if not homes:
        print("no Claude Code home found", file=sys.stderr)
        return 1
    sessions, days_acc = measure(homes, args.days, args.project)
    if not sessions:
        print("no sessions with code questions in the window")
        return 0

    scanned = sum(s["scanned"] for s in sessions.values())
    structural = sum(s["structural"] for s in sessions.values())
    per_tool = defaultdict(int)
    for s in sessions.values():
        for k, v in s["by_tool"].items():
            per_tool[k] += v

    print(f"homes    : {len(homes)}")
    print(f"window   : last {args.days} day(s)")
    print(f"sessions : {len(sessions)} with at least one code question")
    print()
    print(f"scanned    {scanned:6d}   grep for an identifier, or a source file read whole")
    print(f"structural {structural:6d}   codeindex tool calls")
    print(f"routed     {ratio(structural, scanned):5.1f}%   structural / (structural + scanned)")

    if per_tool:
        print("\nstructural calls by tool:")
        for name, n in sorted(per_tool.items(), key=lambda kv: -kv[1]):
            print(f"  {n:5d}  {name}")

    hinted = sum(1 for s in sessions.values() if s["hinted"])
    print(f"\nhook fired in {hinted} of {len(sessions)} session(s)")
    if hinted and hinted < 20:
        # Said out loud because the split invites the wrong conclusion. The
        # first sessions to carry the hint are the ones that built and tested
        # it, where codeindex was being exercised on purpose, so their routed %
        # reflects the author's intent and not the hint's effect. This becomes
        # evidence only once the hint has run in ordinary work.
        print("  too few to compare: the earliest hinted sessions are the ones that")
        print("  developed the hook, so their routed % is intent, not effect.")
    for label, want in (("hinted", True), ("not hinted", False)):
        grp = [s for s in sessions.values() if s["hinted"] is want]
        if not grp:
            continue
        st = sum(s["structural"] for s in grp)
        sc = sum(s["scanned"] for s in grp)
        print(f"  {label:11s} {len(grp):4d} session(s)  routed {ratio(st, sc):5.1f}%"
              f"  structural={st:5d} scanned={sc:6d}")

    if args.by_day:
        print("\nby day (routed %, structural, scanned):")
        for day in sorted(days_acc):
            st, sc = days_acc[day]
            print(f"  {day}  {ratio(st, sc):5.1f}%  {st:5d}  {sc:5d}")

    if args.sessions:
        print("\nsessions, least structural first:")
        worst = sorted(sessions.items(),
                       key=lambda kv: (ratio(kv[1]["structural"], kv[1]["scanned"]),
                                       -kv[1]["scanned"]))
        for sid, s in worst[:25]:
            print(f"  {ratio(s['structural'], s['scanned']):5.1f}%  "
                  f"scanned={s['scanned']:4d} structural={s['structural']:4d}  "
                  f"{s['project'][:44]}  {sid[:8]}")
            if s["examples"]:
                print(f"           e.g. {', '.join(s['examples'])}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

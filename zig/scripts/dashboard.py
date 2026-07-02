#!/usr/bin/env python3
"""codeindex → SQLite + a comprehensive, actionable visual dashboard.

Surfaces everything codeindex produces + enriches it with git data:
 - dependency graph (package level, drill-down to files on click)
 - languages, coupling tiers, circular chains
 - security findings with locations, hardcoded literals
 - duplication, copy-paste clones, dead code
 - HOTSPOTS = git churn × cyclomatic complexity, generated files filtered,
   each with an actionable suggestion
 - AI-authorship (from git commit markers)

Usage: python3 scripts/dashboard.py <workspace> [out.html] [binary]
"""
import subprocess, json, os, sys, sqlite3, collections, html, re

WS = sys.argv[1]
OUT = sys.argv[2] if len(sys.argv) > 2 else "/tmp/codeindex_dashboard.html"
DB = os.path.splitext(OUT)[0] + ".db"
BIN = sys.argv[3] if len(sys.argv) > 3 else os.path.expanduser("~/.local/bin/codeindex")
NAME = os.path.basename(WS.rstrip("/"))
REL = lambda p: p.replace(WS.rstrip("/") + "/", "")
GENERATED = ("generated/", ".pb.go", ".gen.", "_pb2.py", "/gen/", ".g.dart", "/node_modules/", "/vendor/", ".lock")
CF_RE = re.compile(r"\b(if|for|while|switch|case|catch|elif|when|loop|&&|\|\||\?)\b|\?")


def is_generated(rel):
    return any(g in rel for g in GENERATED)


def mcp(calls, t=700):
    p = subprocess.Popen([BIN, "--mcp", "--workspace", WS], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    out, _ = p.communicate("".join(json.dumps(c) + "\n" for c in calls), timeout=t)
    res = {}
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            m = json.loads(line)
        except Exception:
            continue
        if m.get("id") and "result" in m:
            res[m["id"]] = m["result"]["content"][0]["text"]
    return res


def J(d, i, default):
    try:
        return json.loads(d.get(i, ""))
    except Exception:
        return default


ANALYSES = ["health", "security", "duplication", "clones", "literal_scan", "coupling", "cycles", "dead_code"]
print(f"[1/4] indexing {WS} + analyses …")
base = mcp(
    [{"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "index_workspace", "arguments": {"path": WS}}},
     {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "status", "arguments": {}}},
     {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "get_tree", "arguments": {}}}] +
    [{"jsonrpc": "2.0", "id": 10 + i, "method": "tools/call", "params": {"name": "analyze", "arguments": {"analysis": a}}}
     for i, a in enumerate(ANALYSES)])
st = J(base, 2, {})
tree = J(base, 3, [])
A = {a: J(base, 10 + i, {}) for i, a in enumerate(ANALYSES)}
health, sec, dup, clones, lit, coup, cyc, dead = (A[a] for a in ANALYSES)

print("[2/4] git churn + AI-authorship + complexity …")
churn = collections.Counter()
try:
    for ln in subprocess.run(["git", "-C", WS, "log", "--format=", "--name-only"], capture_output=True, text=True, timeout=90).stdout.splitlines():
        ln = ln.strip()
        if ln:
            churn[ln] += 1
except Exception:
    pass
# AI-authorship: files touched by commits carrying AI markers.
ai_files = set(); ai_commits = 0; total_commits = 0
try:
    log = subprocess.run(["git", "-C", WS, "log", "--format=%H%x00%B%x00END%x00"], capture_output=True, text=True, timeout=120).stdout
    for block in log.split("\x00END\x00"):
        if "\x00" not in block:
            continue
        h, body = block.split("\x00", 1)
        h = h.strip()
        if not h:
            continue
        total_commits += 1
        if re.search(r"co-authored-by: claude|generated with.*claude|🤖|noreply@anthropic|codex|gpt-|cursor", body, re.I):
            ai_commits += 1
            for f in subprocess.run(["git", "-C", WS, "show", "--format=", "--name-only", h], capture_output=True, text=True, timeout=20).stdout.splitlines():
                if f.strip():
                    ai_files.add(f.strip())
except Exception:
    pass

# cyclomatic-ish complexity per file (control-flow tokens)
def complexity(rel):
    try:
        with open(os.path.join(WS, rel), errors="ignore") as f:
            return 1 + len(CF_RE.findall(f.read()))
    except Exception:
        return 1

print("[3/4] dependency graph (package + file level) …")
DEPTH = 2
def pkg(path):
    parts = REL(path).split("/")
    return "/".join(parts[:DEPTH]) if len(parts) > DEPTH else (os.path.dirname(REL(path)) or REL(path))

files = [n["path"] for n in tree]
meta = {REL(n["path"]): n for n in tree}
sym_by_pkg = collections.Counter(); lang_files = collections.Counter(); lang_sym = collections.Counter()
pkg_files = collections.defaultdict(list)
for n in tree:
    r = REL(n["path"])
    sym_by_pkg[pkg(n["path"])] += n.get("symbols", 0)
    lang_files[n.get("language", "?")] += 1
    lang_sym[n.get("language", "?")] += n.get("symbols", 0)
    pkg_files[pkg(n["path"])].append(r)

imp = mcp([{"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "index_workspace", "arguments": {"path": WS}}}] +
          [{"jsonrpc": "2.0", "id": 1000 + i, "method": "tools/call", "params": {"name": "get_imports", "arguments": {"path": f}}}
           for i, f in enumerate(files)])
pkg_edges = collections.Counter(); file_edges = []
for i, f in enumerate(files):
    t = imp.get(1000 + i, "")
    if not t or "No imports" in t:
        continue
    sr = REL(f); sp = pkg(f)
    for ln in t.splitlines():
        ln = ln.strip()
        if not ln:
            continue
        dr = REL(ln)
        file_edges.append([sr, dr])
        if pkg(ln) != sp:
            pkg_edges[(sp, pkg(ln))] += 1
pkg_edges = {k: v for k, v in pkg_edges.items() if v >= 2}

# signal sets for suggestions
god = {REL(m["file"]) for m in coup.get("god_modules", [])}
clone_files = set()
for g in clones.get("groups", []):
    for x in g["functions"]:
        if isinstance(x, dict):
            clone_files.add(REL(x["file"]))
sec_by_file = collections.Counter(REL(f["file"]) for f in sec.get("findings", []))


def suggest(rel, ch, cx):
    s = []
    if is_generated(rel):
        return "Generated — exclude from review; fix the generator/template instead."
    if rel in god:
        s.append("God module: high fan-in AND fan-out — split responsibilities into smaller units.")
    if sec_by_file.get(rel):
        s.append(f"{sec_by_file[rel]} security finding(s) here — remediate (see Security tab).")
    if rel in clone_files:
        s.append("Contains duplicated blocks — extract a shared helper.")
    if ch >= 20 and cx >= 40:
        s.append("Churned + complex — add regression tests and refactor into smaller functions before the next change.")
    elif ch >= 20:
        s.append("Frequently changed — ensure strong test coverage here.")
    if rel in ai_files:
        s.append("AI-authored & high-risk — review carefully.")
    return " ".join(s) or "High churn × complexity — prioritise review/tests."


# hotspots: churn × complexity, generated excluded
hotspots = []
for n in tree:
    rel = REL(n["path"]); ch = churn.get(rel, 0)
    if ch == 0 or is_generated(rel):
        continue
    cx = complexity(rel)
    if cx <= 2:
        continue
    hotspots.append({"file": rel, "lang": n.get("language", ""), "churn": ch, "cx": cx, "sym": n.get("symbols", 0),
                     "ai": rel in ai_files, "score": ch * cx, "sugg": suggest(rel, ch, cx)})
hotspots.sort(key=lambda x: -x["score"])

# ── Synthesis: rank findings into an actionable plan / AI task list ──────────────
SEC_FIX = {
    "hardcoded_secret_assignment": "Move the secret to env/secret-manager and ROTATE the exposed credential.",
    "private_key_block": "Remove the committed private key; rotate it and load from a vault.",
    "aws_access_key": "Revoke this AWS key immediately and move to IAM roles / secrets.",
    "stripe_live_key": "Revoke the live Stripe key and load from env.",
    "github_token": "Revoke the token and use a secrets store.",
    "solidity_tx_origin_auth": "Replace tx.origin auth with msg.sender (phishing-safe).",
    "solidity_delegatecall": "Audit the delegatecall target — ensure it is trusted and immutable.",
    "solidity_low_level_call": "Check the call's return value; prefer a checked/safe wrapper.",
    "solidity_timestamp_dependence": "Don't rely on block.timestamp for critical logic.",
    "solidity_weak_randomness": "Use a secure randomness source (e.g. a VRF), not blockhash.",
    "command_injection": "Never pass untrusted input to exec/system; use safe APIs.",
    "eval_usage": "Avoid eval on dynamic input.",
}
plan = []
# 1. security (critical/high first)
by_rule = collections.defaultdict(list)
for f in sec.get("findings", []):
    by_rule[f["rule"]].append((REL(f["file"]), f["line"], f["severity"]))
for rule, hits in by_rule.items():
    sev = "critical" if any(h[2] == "critical" for h in hits) else ("high" if any(h[2] == "high" for h in hits) else "medium")
    pr = {"critical": 1, "high": 2}.get(sev, 3)
    plan.append({"pri": pr, "cat": "security", "title": f"{rule} — {len(hits)} occurrence(s)",
                 "fix": SEC_FIX.get(rule, "Review and remediate."),
                 "loc": [f"{h[0]}:{h[1]}" for h in hits[:4]], "task": f"[security] {SEC_FIX.get(rule,'Fix '+rule)} ({len(hits)} sites, e.g. {hits[0][0]}:{hits[0][1]})"})
# 2. copy-paste clones
for g in clones.get("groups", []):
    if g["count"] >= 3 or g["lines"] >= 12:
        names = sorted({x['name'] for x in g['functions'] if isinstance(x, dict)})
        locs = [REL(x['file']) for x in g['functions'] if isinstance(x, dict)][:5]
        plan.append({"pri": 2 if g["lines"] * g["count"] >= 150 else 3, "cat": "duplication",
                     "title": f"`{', '.join(names)}` copy-pasted {g['count']}× ({g['lines']} lines each)",
                     "fix": "Extract one shared implementation and replace the copies.",
                     "loc": locs, "task": f"[refactor] Extract duplicated `{names[0]}` ({g['count']} copies) into a shared helper; replace call sites in {', '.join(locs[:3])}"})
# 3. reinvented utilities
for c in dup.get("clusters", [])[:12]:
    if c["count"] >= 5:
        plan.append({"pri": 3, "cat": "reuse", "title": f"`{c['name']}` ({c['kind']}) reimplemented in {c['count']} files",
                     "fix": "Consolidate into a single shared utility/module.", "loc": [],
                     "task": f"[consolidate] Unify `{c['name']}` (defined in {c['count']} files) into one shared module"})
# 4. god modules
for m in coup.get("god_modules", [])[:5]:
    plan.append({"pri": 3, "cat": "modularity", "title": f"God module {REL(m['file'])} (fan-in {m['fan_in']}, fan-out {m['fan_out']})",
                 "fix": "Split into cohesive sub-modules; introduce interfaces to cut fan-out.", "loc": [REL(m["file"])],
                 "task": f"[modularity] Split god-module {REL(m['file'])} (fan-out {m['fan_out']}) into focused units"})
# 5. cycles
for c in cyc.get("cycles", [])[:5]:
    chain = [REL(f) for f in c["files"]]
    plan.append({"pri": 3, "cat": "architecture", "title": f"Circular dependency ({len(chain)} files)",
                 "fix": "Break the cycle: extract the shared type/interface into a separate module.", "loc": chain[:4],
                 "task": f"[architecture] Break circular dependency: {' → '.join(chain[:3])}"})
# 6. hotspots
for h in hotspots[:5]:
    plan.append({"pri": 3, "cat": "stability", "title": f"Hotspot {h['file']} ({h['churn']}× changes, complexity {h['cx']})",
                 "fix": "Add regression tests and refactor into smaller functions before the next change.", "loc": [h["file"]],
                 "task": f"[stabilize] Add tests + refactor {h['file']} (churn {h['churn']}, cx {h['cx']})"})
# 7. dead code (batch)
if dead.get("symbols"):
    names = [s["name"] for s in dead["symbols"][:6]]
    plan.append({"pri": 4, "cat": "cleanup", "title": f"{dead.get('dead_count', len(dead['symbols']))} unreferenced symbols",
                 "fix": "Remove if truly unused (verify no reflection / FFI / external API first).", "loc": [],
                 "task": f"[cleanup] Review & remove dead symbols (e.g. {', '.join(names)})"})
plan.sort(key=lambda x: x["pri"])
plan_summary = {"critical": sum(1 for p in plan if p["pri"] == 1), "high": sum(1 for p in plan if p["pri"] == 2),
                "medium": sum(1 for p in plan if p["pri"] == 3), "low": sum(1 for p in plan if p["pri"] == 4), "total": len(plan)}

print(f"[4/4] writing {DB} + {OUT} …")
if os.path.exists(DB):
    os.remove(DB)
con = sqlite3.connect(DB)
con.executescript("CREATE TABLE project(name,files,symbols,savings,edges,ai_commits,total_commits);"
                  "CREATE TABLE hotspots(file,lang,churn,cx,score,ai,suggestion);"
                  "CREATE TABLE security(file,line,rule,severity);")
con.execute("INSERT INTO project VALUES(?,?,?,?,?,?,?)", (NAME, st.get("files"), st.get("symbols"), st.get("savings_pct"), len(pkg_edges), ai_commits, total_commits))
con.executemany("INSERT INTO hotspots VALUES(?,?,?,?,?,?,?)", [(h["file"], h["lang"], h["churn"], h["cx"], h["score"], int(h["ai"]), h["sugg"]) for h in hotspots])
con.executemany("INSERT INTO security VALUES(?,?,?,?)", [(REL(f["file"]), f["line"], f["rule"], f["severity"]) for f in sec.get("findings", [])])
con.commit(); con.close()

nid = {p: i for i, p in enumerate(sorted({a for a, _ in pkg_edges} | {b for _, b in pkg_edges}))}
sev_rank = {"critical": 0, "high": 1, "medium": 2, "low": 3}
ai_touched_indexed = sum(1 for n in tree if REL(n["path"]) in ai_files)
data = {
    "name": NAME, "status": st,
    "ai": {"commits": ai_commits, "total": total_commits, "pct": round(100 * ai_commits / max(total_commits, 1), 1),
           "files": ai_touched_indexed, "filepct": round(100 * ai_touched_indexed / max(len(tree), 1), 1)},
    "languages": sorted([{"lang": l, "files": lang_files[l], "symbols": lang_sym[l]} for l in lang_files], key=lambda x: -x["symbols"]),
    "nodes": [{"id": i, "label": p.split("/")[-1], "title": f"{p} · {sym_by_pkg.get(p,0)} sym", "value": sym_by_pkg.get(p, 0) + 1, "pkg": p} for p, i in nid.items()],
    "edges": [{"from": nid[a], "to": nid[b], "value": w} for (a, b), w in pkg_edges.items()],
    "pkgFiles": {p: pkg_files[p] for p in nid}, "fileEdges": file_edges, "fileMeta": {r: {"sym": meta[r].get("symbols", 0), "lang": meta[r].get("language", "")} for r in meta},
    "health": health, "literal": {k: lit.get(k) for k in ("total", "urls", "ips", "localhosts", "secrets", "magic_ports", "todos")},
    "secSummary": {k: sec.get(k) for k in ("total", "critical", "high", "medium", "low")},
    "security": sorted([{"file": REL(f["file"]), "line": f["line"], "rule": f["rule"], "sev": f["severity"]} for f in sec.get("findings", [])], key=lambda x: sev_rank.get(x["sev"], 9))[:300],
    "literals": [{"file": REL(f["file"]), "line": f["line"], "cat": f.get("category", ""), "snip": f.get("snippet", "")[:80]} for f in lit.get("findings", [])][:150],
    "coupling": {t: [{"file": REL(m["file"]), "in": m["fan_in"], "out": m["fan_out"], "I": round(m.get("instability", 0), 2)} for m in coup.get(t, [])[:15]] for t in ("god_modules", "stable_cores", "unstable_drivers")},
    "cycles": [[REL(f) for f in c["files"]] for c in cyc.get("cycles", [])[:25]],
    "dead": [{"name": s["name"], "kind": s["kind"], "file": REL(s["file"]), "line": s["line"]} for s in dead.get("symbols", [])[:120]],
    "clones": [{"names": sorted({x['name'] for x in g['functions'] if isinstance(x, dict)}), "files": [REL(x['file']) for x in g['functions'] if isinstance(x, dict)][:6], "lines": g["lines"], "count": g["count"]} for g in clones.get("groups", [])[:40]],
    "duplication": [{"name": c["name"], "kind": c["kind"], "count": c["count"]} for c in dup.get("clusters", [])[:40]],
    "hotspots": [{"file": h["file"], "lang": h["lang"], "churn": h["churn"], "cx": h["cx"], "sym": h["sym"], "ai": h["ai"], "score": h["score"], "sugg": h["sugg"]} for h in hotspots[:30]],
    "plan": plan[:50], "planSummary": plan_summary,
}

T = open(os.path.join(os.path.dirname(__file__), "dashboard_template.html")).read()
with open(OUT, "w") as f:
    f.write(T.replace("__NAME__", html.escape(NAME)).replace("__DATA__", json.dumps(data)))
print(f"\n✓ dashboard: {OUT}\n✓ database : {DB}")
print(f"  AI: {ai_commits}/{total_commits} commits ({data['ai']['pct']}%), {ai_touched_indexed} files touched")
print(f"  hotspots: {len(hotspots)} (generated excluded), top suggestion: {hotspots[0]['sugg'][:60] if hotspots else '-'}")

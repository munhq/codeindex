#!/usr/bin/env python3
"""Render a codeindex dependency graph as Mermaid (a visual module map).

Queries the codeindex MCP binary, rolls file-level imports up to packages
(top-N directory segments), and emits a Mermaid `graph LR`.

Usage: python3 scripts/graph.py <workspace> [depth] [binary]
"""
import subprocess, json, os, sys, collections
ws = sys.argv[1]
DEPTH = int(sys.argv[2]) if len(sys.argv) > 2 else 2
MINW = int(os.environ.get('MINW','1'))
BIN = sys.argv[3] if len(sys.argv) > 3 else os.path.expanduser("~/.local/bin/codeindex")

def session(calls, t=600):
    p = subprocess.Popen([BIN,"--mcp","--workspace",ws],stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True)
    out,_ = p.communicate("".join(json.dumps(c)+"\n" for c in calls), timeout=t)
    res={}
    for line in out.splitlines():
        line=line.strip()
        if not line: continue
        try: m=json.loads(line)
        except: continue
        if m.get("id") and "result" in m: res[m["id"]]=m["result"]["content"][0]["text"]
    return res

def pkg(path):
    rel = path.replace(ws.rstrip("/")+"/","")
    parts = rel.split("/")
    return "/".join(parts[:DEPTH]) if len(parts) > DEPTH else (os.path.dirname(rel) or ".")

tree = json.loads(session([
    {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"index_workspace","arguments":{"path":ws}}},
    {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_tree","arguments":{}}}]).get(2,"[]"))
files=[n["path"] for n in tree]
symbols_per_pkg=collections.Counter()
for n in tree: symbols_per_pkg[pkg(n["path"])] += n.get("symbols",0)

# file -> imports
calls=[{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"index_workspace","arguments":{"path":ws}}}]
for i,f in enumerate(files):
    calls.append({"jsonrpc":"2.0","id":1000+i,"method":"tools/call","params":{"name":"get_imports","arguments":{"path":f}}})
r=session(calls)
edges=collections.Counter()
for i,f in enumerate(files):
    t=r.get(1000+i,"")
    if not t or "No imports" in t: continue
    src=pkg(f)
    for imp in t.splitlines():
        imp=imp.strip()
        if not imp: continue
        dst=pkg(imp)
        if dst!=src: edges[(src,dst)] += 1

def nid(p): return "P"+str(abs(hash(p))%100000)
nodes=set()
for (a,b) in edges: nodes.add(a); nodes.add(b)
print("```mermaid")
print("graph LR")
for n in sorted(nodes):
    print(f'  {nid(n)}["{n}<br/>{symbols_per_pkg.get(n,0)} sym"]')
edges = collections.Counter({k:v for k,v in edges.items() if v >= MINW})
nodes=set()
for (a,b) in edges: nodes.add(a); nodes.add(b)
for (a,b),w in sorted(edges.items(), key=lambda x:-x[1]):
    print(f"  {nid(a)} -->|{w}| {nid(b)}")
print("```")
print(f"\n<!-- {len(nodes)} packages, {len(edges)} package-edges, from {len(files)} files -->", file=sys.stderr)

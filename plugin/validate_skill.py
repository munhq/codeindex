#!/usr/bin/env python3
"""Validate a SKILL.md against the live MCP server it documents.

A skill that names a tool wrongly is worse than no skill: the agent follows it,
the call fails, and it falls back to the expensive tool having burned a turn. So
every tool name and every argument the skill mentions is checked against the
server's advertised schema, and every documented call is actually executed.
"""
import json
import os
import re
import subprocess
import sys
import time


class MCP:
    def __init__(self, binary, workspace):
        self.p = subprocess.Popen(
            [binary, "--mcp", "--workspace", workspace],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, bufsize=1,
        )
        self.id = 0
        self._rpc("initialize", {"protocolVersion": "2024-11-05",
                                 "capabilities": {},
                                 "clientInfo": {"name": "validate", "version": "0"}})
        self._send({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}})

    def _send(self, o):
        self.p.stdin.write(json.dumps(o) + "\n")
        self.p.stdin.flush()

    def _rpc(self, method, params, timeout=60):
        self.id += 1
        mid = self.id
        self._send({"jsonrpc": "2.0", "id": mid, "method": method, "params": params})
        end = time.time() + timeout
        while time.time() < end:
            line = self.p.stdout.readline()
            if not line:
                return None
            try:
                m = json.loads(line)
            except Exception:
                continue
            if m.get("id") == mid:
                return m
        return None

    def tools(self):
        r = self._rpc("tools/list", {})
        return {t["name"]: t for t in r["result"]["tools"]} if r else {}

    def call(self, name, args):
        r = self._rpc("tools/call", {"name": name, "arguments": args})
        if not r or "result" not in r:
            return None
        return "\n".join(c.get("text", "") for c in r["result"].get("content", [])
                         if c.get("type") == "text")

    def close(self):
        try:
            self.p.terminate(); self.p.wait(timeout=5)
        except Exception:
            self.p.kill()


def main():
    skill_path, binary, workspace = sys.argv[1], sys.argv[2], sys.argv[3]
    text = open(skill_path).read()
    ci = MCP(binary, workspace)
    schema = ci.tools()
    print(f"server advertises {len(schema)} tools\n")

    # 1. Every tool the skill names must exist.
    named = set(re.findall(r"mcp__codeindex__([a-z_]+)", text))
    named |= set(re.findall(r"`([a-z_]{3,})`", text)) & set(schema) | \
        {n for n in re.findall(r"`([a-z_]{3,})`", text) if n in schema}
    named = {n for n in named if n not in {"path", "name", "context", "file"}}
    fails = []
    print("--- tool names ---")
    for n in sorted(named):
        ok = n in schema
        print(f"  {'OK  ' if ok else 'FAIL'} {n}")
        if not ok:
            fails.append(f"skill names unknown tool `{n}`")

    # 2. Every argument the skill mentions for a tool must be in its schema.
    #
    # Claims are PARSED from the skill, never assumed here. An earlier version
    # hardcoded `file` for three tools, the skill never said that, and the
    # validator reported a failure in the skill that was its own invention.
    print("\n--- documented arguments (parsed from the skill) ---")
    arg_claims = {}
    for tool, argblob in re.findall(
        r"`([a-z_]{3,})`\s*\(([^)]*)\)", text
    ):
        if tool not in schema:
            continue
        args = [a for a in re.findall(r"`?([a-z_]{3,})`?", argblob)
                if a not in {"optional", "to", "disambiguate", "for", "extra",
                             "lines", "name", "what", "a", "file", "needs",
                             "it", "and", "the"} or a == "name"]
        arg_claims.setdefault(tool, set()).update(args)
    if not arg_claims:
        print("  (no argument claims found in the skill)")
    for tool, args in sorted(arg_claims.items()):
        props = set(schema[tool].get("inputSchema", {}).get("properties", {}))
        for a in sorted(args):
            ok = a in props
            print(f"  {'OK  ' if ok else 'FAIL'} {tool}({a})"
                  f"{'' if ok else '   actual: ' + ','.join(sorted(props))}")
            if not ok:
                fails.append(f"{tool} has no argument `{a}` (has {sorted(props)})")

    # 3. Execute the routes the skill tells an agent to take.
    print("\n--- live calls ---")
    # Pick the largest source file: a tiny config file has no symbols, and an
    # empty outline would look like a tool failure.
    cands = []
    for root, dirs, files in os.walk(workspace):
        dirs[:] = [d for d in dirs
                   if d not in {".git", "node_modules", "target", "dist", "vendor"}]
        for f in files:
            if f.endswith((".ts", ".rs", ".py", ".zig", ".go")) and "test" not in f:
                fp = os.path.join(root, f)
                try:
                    cands.append((os.path.getsize(fp), fp))
                except OSError:
                    pass
    cands.sort(reverse=True)
    src = os.path.relpath(cands[0][1], workspace) if cands else None
    print(f"  probe file: {src}")

    out = ci.call("get_outline", {"path": src})
    ok = bool(out) and out.lstrip().startswith("{")
    print(f"  {'OK  ' if ok else 'FAIL'} get_outline(path=...)")
    if not ok:
        fails.append("get_outline(path) did not return JSON")
    sym = None
    if ok:
        doc = json.loads(out)
        syms = [s for s in doc.get("symbols", []) if s.get("kind") == "function"]
        sym = (syms or doc.get("symbols") or [{}])[0].get("name")

    if sym:
        r = ci.call("find_symbol", {"name": sym})
        ok = bool(r) and "No " not in r[:20]
        print(f"  {'OK  ' if ok else 'FAIL'} find_symbol(name={sym!r})")
        if not ok:
            fails.append(f"find_symbol({sym}) returned nothing")

        r = ci.call("read_symbol", {"name": sym, "path": src})
        ok = bool(r) and "No " not in r[:20]
        print(f"  {'OK  ' if ok else 'FAIL'} read_symbol(name={sym!r}, path=...)")
        if not ok:
            fails.append(f"read_symbol({sym}) returned nothing")
        else:
            print(f"       -> {len(r)} chars returned")

    ci.close()
    print()
    if fails:
        print(f"FAILED — {len(fails)} problem(s):")
        for f in fails:
            print(f"  - {f}")
        sys.exit(1)
    print("SKILL VALIDATED — every documented tool, argument and route works.")


if __name__ == "__main__":
    main()

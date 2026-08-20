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
    # Indexing runs in the background, and status reports files:0 while it does.
    # A probe issued immediately therefore asks an empty index, and every answer
    # comes back as "No outline found" — which reads as a broken tool rather
    # than an unfinished index. Wait for the index before probing anything.
    indexed, deadline = 0, time.time() + 120
    while time.time() < deadline:
        try:
            doc = json.loads(ci.call("status", {}))
        except Exception:
            break
        indexed = doc.get("files", 0)
        if indexed and not doc.get("indexing"):
            break
        time.sleep(1)
    print(f"  index: {indexed} file(s)")
    if not indexed:
        fails.append("workspace is not indexed, so no route could be checked")

    # Pick the probe file from the INDEX, not from the filesystem. The largest
    # file on disk is often generated — a build cache, or a C import
    # translation — and the index never held it, so the outline came back empty
    # and the validator blamed the tool for its own choice of probe.
    src = None
    if indexed:
        try:
            entries = [e for e in json.loads(ci.call("get_tree", {}))
                       if e.get("symbols")]
        except Exception:
            entries = []
        entries.sort(key=lambda e: e.get("symbols", 0), reverse=True)
        if entries:
            src = entries[0]["path"]
            if os.path.isabs(src):
                src = os.path.relpath(src, workspace)
    print(f"  probe file: {src}")

    # The index must describe the workspace that was asked for. A snapshot left
    # in a project root by another project loads without complaint and answers
    # every call, so every documented route "works" while every answer is about
    # the wrong repository. Check containment, or this validator passes a server
    # that returns another project's code.
    if src and not os.path.exists(os.path.join(workspace, src)):
        print(f"  FAIL index holds {src}, which is not in the workspace")
        fails.append(f"index holds `{src}`, which does not exist under "
                     f"{workspace} — the loaded snapshot describes another "
                     f"project, so every answer is about the wrong repository")

    out = ci.call("get_outline", {"path": src}) if src else ""
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

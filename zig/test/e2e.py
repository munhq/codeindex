#!/usr/bin/env python3
"""End-to-end MCP stdio test.

Spawns the real codeindex binary, speaks the MCP JSON-RPC protocol over stdin/
stdout exactly as a client (Claude Code, Cursor, ...) would, and asserts that
every response is a well-formed JSON-RPC envelope with valid JSON content —
across multiple languages, including symbol names that contain quotes (the Go
`import "x/y"` case that used to emit malformed JSON).

Usage:  python3 test/e2e.py [path-to-codeindex]
Exits non-zero on any failure. Wired into the build as `zig build e2e`.
"""
import json
import os
import subprocess
import sys
import tempfile

BIN = sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/codeindex"
failures = []


def check(cond, msg):
    print(("  ok  " if cond else " FAIL ") + msg)
    if not cond:
        failures.append(msg)


def rpc(ws, calls):
    """Send a batch of JSON-RPC lines, return {id: parsed_message}."""
    p = subprocess.Popen([BIN, "--mcp", "--workspace", ws],
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, text=True)
    out, _ = p.communicate("".join(json.dumps(c) + "\n" for c in calls), timeout=60)
    msgs = {}
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        # Every emitted line MUST be valid JSON — this is the protocol contract.
        try:
            m = json.loads(line)
        except json.JSONDecodeError as e:
            failures.append(f"non-JSON line on stdout: {line[:80]!r} ({e})")
            continue
        if "id" in m:
            msgs[m["id"]] = m
    return msgs


def tool(i, name, args):
    return {"jsonrpc": "2.0", "id": i, "method": "tools/call",
            "params": {"name": name, "arguments": args}}


def text(msg):
    return msg["result"]["content"][0]["text"]


def main():
    ws = tempfile.mkdtemp(prefix="codeindex_e2e_")
    os.makedirs(f"{ws}/src", exist_ok=True)
    os.makedirs(f"{ws}/util", exist_ok=True)
    # Multi-language project. Go's import yields a quote-containing symbol name.
    files = {
        "src/lib.rs":  "pub mod helper;\npub fn run(){}\n",
        "src/helper.rs": "pub fn help(){}\n",
        "main.go":     'package main\nimport "ex.com/m/util"\nfunc Main(){ util.Do() }\n',
        "util/util.go": "package util\nfunc Do(){}\n",
        "app.py":      "from helpers import thing\ndef run():\n    pass\n",
        "helpers.py":  "def thing():\n    pass\n",
        "a.ts":        "import { b } from './b';\nexport function aa(){return b;}\n",
        "b.ts":        "export const b = 1;\n",
        "conf.toml":   "title = \"x\"\n[server]\nhost = \"h\"\n",
    }
    for rel, content in files.items():
        with open(f"{ws}/{rel}", "w") as f:
            f.write(content)

    calls = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
        tool(3, "index_workspace", {"path": ws}),
        tool(4, "get_outline", {"path": "main.go"}),     # quote-prone JSON
        tool(5, "get_imports", {"path": "main.go"}),
        tool(6, "get_outline", {"path": "src/lib.rs"}),
        tool(7, "get_imports", {"path": "app.py"}),
        tool(8, "get_outline", {"path": "a.ts"}),
        tool(9, "get_tree", {}),
    ]
    m = rpc(ws, calls)

    # Envelope checks: every response well-formed JSON-RPC.
    for i in range(1, 10):
        check(i in m, f"response {i} received")
        if i in m:
            check(m[i].get("jsonrpc") == "2.0", f"response {i} jsonrpc=2.0")

    check("result" in m.get(2, {}), "tools/list has result")
    tools = m.get(2, {}).get("result", {}).get("tools", [])
    check(len(tools) >= 16, f"tools/list advertises >=16 tools (got {len(tools)})")

    # get_outline(main.go): content text must itself be valid JSON (the bug).
    try:
        go_outline = json.loads(text(m[4]))
        check(True, "get_outline(main.go) content is valid JSON")
        names = [s["name"] for s in go_outline.get("symbols", [])]
        check("Main" in names, f"go symbol 'Main' present (got {names})")
    except Exception as e:
        check(False, f"get_outline(main.go) content valid JSON ({e})")

    check("util.go" in text(m[5]), "go import resolves to util.go")
    check("helper" in text(m[6]).lower() or "run" in text(m[6]), "rust outline has symbols")
    check("helpers.py" in text(m[7]), "python import resolves to helpers.py")
    check(json.loads(text(m[8])).get("symbols"), "ts outline has symbols")
    check(json.loads(text(m[9])), "get_tree returns valid JSON array")

    print()
    if failures:
        print(f"E2E FAILED: {len(failures)} failure(s)")
        for f in failures:
            print("  - " + f)
        sys.exit(1)
    print("E2E PASSED")


if __name__ == "__main__":
    main()

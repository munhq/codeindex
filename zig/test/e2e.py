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
import pathlib
import subprocess
import sys
import tempfile
import time

# Absolute: the workspace-recovery tests launch the server from a directory of
# their own, and the build passes this path relative to zig/.
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/codeindex")
failures = []


def check(cond, msg):
    print(("  ok  " if cond else " FAIL ") + msg)
    if not cond:
        failures.append(msg)


# A daemon outlives the session that started it — that is the point of it. A
# test must still not leave one running: on Windows the post-job cache clear
# could not unlink codeindex.exe while a daemon held it, and the job failed
# after every check had passed. One second of idle retires it.
DAEMON_IDLE_SECS = "1"


def server_env():
    env = dict(os.environ)
    env["CODEINDEX_DAEMON_IDLE_SECS"] = DAEMON_IDLE_SECS
    return env


def await_daemon_exit():
    """Give any daemon this run started time to retire."""
    time.sleep(int(DAEMON_IDLE_SECS) + 3)


def daemon_logs():
    """The daemon writes its own stderr to a log beside its socket. When a
    session hangs, that file is the only account of what the daemon did."""
    bases = []
    for var in ("LOCALAPPDATA", "TEMP", "XDG_RUNTIME_DIR", "TMPDIR"):
        v = os.environ.get(var)
        if v:
            bases += [os.path.join(v, "codeindex", "run"),
                      os.path.join(v, "codeindex-run"),
                      os.path.join(v, "codeindex")]
    out = {}
    for d in bases:
        try:
            for name in os.listdir(d):
                if not name.endswith(".log"):
                    continue
                with open(os.path.join(d, name), errors="replace") as f:
                    out[os.path.join(d, name)] = f.read()[-800:]
        except OSError:
            continue
    return out or "no daemon log found"


def rpc(ws, calls):
    """Send a batch of JSON-RPC lines, return {id: parsed_message}."""
    p = subprocess.Popen([BIN, "--mcp", "--workspace", ws],
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, text=True, env=server_env())
    try:
        out, err = p.communicate("".join(json.dumps(c) + "\n" for c in calls), timeout=60)
    except subprocess.TimeoutExpired:
        # A timeout used to abort the whole run with a traceback and no account
        # of what the server did. Kill it, keep what it managed to say, and let
        # the remaining checks report.
        p.kill()
        out, err = p.communicate()
        failures.append(
            "the server never exited\n"
            f"      stderr    : {err!r}\n"
            f"      stdout    : {out[:500]!r}\n"
            f"      daemon log: {daemon_logs()!r}")
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


def dialogue(cwd, roots, calls, env_extra=None, settle=4.0):
    """Speak MCP the way a real client does: a reader thread answers the
    server's own requests while the conversation is still open.

    communicate() cannot do this — it closes stdin before reading — and
    `roots/list` is a request the SERVER sends, so the batch form above can
    never exercise it.
    """
    import threading
    import time

    env = server_env()
    for k in ("CODEINDEX_WORKSPACE", "CLAUDE_PROJECT_DIR"):
        env.pop(k, None)
    env.update(env_extra or {})
    p = subprocess.Popen([BIN, "--mcp"], cwd=cwd, env=env,
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, text=True, bufsize=1)
    msgs, asked, lock = {}, [], threading.Lock()

    def send(obj):
        with lock:
            p.stdin.write(json.dumps(obj) + "\n")
            p.stdin.flush()

    def reader():
        for line in p.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                m = json.loads(line)
            except json.JSONDecodeError as e:
                failures.append(f"non-JSON line on stdout: {line[:80]!r} ({e})")
                continue
            if m.get("method") == "roots/list":
                asked.append(True)
                send({"jsonrpc": "2.0", "id": m["id"],
                      "result": {"roots": [{"uri": u, "name": "r"} for u in roots]}})
            elif "id" in m:
                msgs[m["id"]] = m

    t = threading.Thread(target=reader, daemon=True)
    t.start()
    caps = {"roots": {"listChanged": True}} if roots is not None else {}
    send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
          "params": {"protocolVersion": "2024-11-05", "capabilities": caps,
                     "clientInfo": {"name": "e2e", "version": "0"}}})
    send({"jsonrpc": "2.0", "method": "notifications/initialized"})
    # The handshake, the roots round trip and the index build all happen before a
    # real client's first tool call, which needs a model turn.
    time.sleep(settle)
    for c in calls:
        send(c)
    deadline = time.time() + 60
    wanted = {c["id"] for c in calls}
    while time.time() < deadline and not wanted.issubset(msgs.keys()):
        time.sleep(0.2)
    try:
        p.stdin.close()
        p.wait(timeout=10)
    except Exception:
        p.kill()
    return msgs, bool(asked)


def workspace_recovery():
    """The launch directory is not always the project, and used to be the end of
    the story: the server refused, every tool answered "No results", and the
    caller went back to grep for the rest of the session.
    """
    print("\n-- workspace recovery --")
    proj = tempfile.mkdtemp(prefix="codeindex_e2e_proj_")
    os.makedirs(f"{proj}/.git", exist_ok=True)  # the project marker
    with open(f"{proj}/app.ts", "w") as f:
        f.write("export function requireRemote(){ return 1; }\n")
    # A directory with no marker anywhere up the tree: the case a client creates
    # when it launches the server from its own config or plugin directory.
    nowhere = tempfile.mkdtemp(prefix="codeindex_e2e_nowhere_")

    # 1. No roots offered: the refusal must be stated in the tool result, with
    #    the call that fixes it, instead of looking like a negative answer.
    msgs, asked = dialogue(nowhere, None, [tool(20, "find_symbol", {"name": "requireRemote"})])
    body = text(msgs[20]) if 20 in msgs else ""
    check(msgs.get(20, {}).get("result", {}).get("isError") is True,
          "a refused workspace answers with an error, not a result")
    check("no index" in body.lower(), f"the answer says there is no index (got {body[:60]!r})")
    check("index_workspace" in body, "the answer names the call that fixes it")
    check(not asked, "a client without the roots capability is not asked for roots")

    # 2. The client answers roots/list: the server adopts the project and the
    #    same call now resolves.
    # Path.as_uri() is what a correct client sends: file:///tmp/x on POSIX and
    # file:///C:/Users/... on Windows, percent-encoded. Hand-building
    # f"file://{proj}" produced file://C:\Users\... on Windows — a malformed URI
    # that the server rightly refused, so the whole recovery path went untested
    # on the one platform whose paths differ.
    msgs, asked = dialogue(nowhere, [pathlib.Path(proj).as_uri()],
                           [tool(21, "find_symbol", {"name": "requireRemote"}),
                            tool(22, "status", {})])
    check(asked, "a refused workspace asks the client for its roots")
    body = text(msgs[21]) if 21 in msgs else ""
    check("app.ts" in body, f"the adopted workspace answers the query (got {body[:60]!r})")
    st = json.loads(text(msgs[22])) if 22 in msgs else {}
    check(st.get("files", 0) >= 1, f"status counts the adopted files (got {st.get('files')})")
    check(st.get("watcher") is True, "the adopted workspace is watched")
    check(os.path.realpath(st.get("workspace", "")) == os.path.realpath(proj),
          f"status names the adopted root (got {st.get('workspace')!r})")

    # 3. CLAUDE_PROJECT_DIR, which Claude Code sets in every MCP server it
    #    spawns, is honoured without any round trip at all.
    msgs, asked = dialogue(nowhere, None,
                           [tool(23, "find_symbol", {"name": "requireRemote"}),
                            tool(24, "status", {})],
                           env_extra={"CLAUDE_PROJECT_DIR": proj})
    body = text(msgs[23]) if 23 in msgs else ""
    # The refusal carries the reason and the workspace it settled on, and a
    # 60-character slice cut both off — the Windows failure named no cause for
    # five releases. On failure, say everything the server said.
    st = text(msgs[24]) if 24 in msgs else ""
    adopted = "app.ts" in body
    check(adopted, "CLAUDE_PROJECT_DIR names the workspace" if adopted else
          f"CLAUDE_PROJECT_DIR names the workspace\n"
          f"      asked for: {proj!r}\n"
          f"      answered : {body!r}\n"
          f"      status   : {st!r}")


def main():
    ws = tempfile.mkdtemp(prefix="codeindex_e2e_")
    os.makedirs(f"{ws}/src", exist_ok=True)
    os.makedirs(f"{ws}/util", exist_ok=True)
    os.makedirs(f"{ws}/deploy", exist_ok=True)
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
        # Fixtures for the production-cost analyses. Each one is the shape of a
        # fault measured in a real repository, reduced to the smallest source
        # that still triggers it.
        "deploy/supervisor.sh":
            "#!/usr/bin/env bash\n"
            "POLL_SECS=\"${POLL_SECS:-15}\"\n"
            "s3() { aws --endpoint-url \"$S3_ENDPOINT\" s3 \"$@\"; }\n"
            "sync_app() {\n"
            "  local sha; sha=\"$(s3 cp \"$1/DEPLOYED_SHA\" -)\"\n"
            "}\n"
            "node /srv/server.mjs &\n"
            "while true; do\n"
            "  sync_app /data\n"
            "  sleep \"$POLL_SECS\"\n"
            "done\n",
        "deploy/deploy.sh":
            "#!/usr/bin/env bash\n"
            "kubectl set image deployment/api api=\"$IMAGE_DIGEST\"\n",
        "deploy/tenant.yaml":
            "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n"
            "  annotations:\n    keel.sh/policy: force\n"
            "spec:\n  template:\n    spec:\n      containers:\n"
            "        - name: api\n          resources:\n            limits:\n"
            "              memory: \"512Mi\"\n",
        "src/k8s.rs":
            "pub fn tenant(image: &str) -> Deployment {\n"
            "    let container = Container {\n"
            "        image: Some(image.to_string()),\n"
            "    };\n"
            "    Deployment { spec: Some(DeploymentSpec { containers: vec![container] }) }\n"
            "}\n",
        "src/db.rs":
            "pub fn pool(path: &str) -> Result<SqlitePool> {\n"
            "    let o = SqliteConnectOptions::new()\n"
            "        .pragma(\"mmap_size\", \"268435456\");\n"
            "    SqlitePool::connect_with(o)\n"
            "}\n",
        "src/store.rs":
            "pub struct SessionStore {\n"
            "    sessions: Mutex<HashMap<String, Session>>,\n"
            "}\n"
            "impl SessionStore {\n"
            "    pub fn add(&self, k: String, v: Session) {\n"
            "        self.sessions.lock().unwrap().insert(k, v);\n"
            "    }\n"
            "}\n",
        "Cargo.toml":
            "[package]\nname = \"e2e\"\nversion = \"0.1.0\"\n\n"
            "[dependencies]\nserde_json = \"1\"\nnever_used_crate = \"0.1\"\n",
        "Cargo.lock":
            "[[package]]\nname = \"bitflags\"\nversion = \"1.3.2\"\n\n"
            "[[package]]\nname = \"bitflags\"\nversion = \"2.6.0\"\n",
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
        # Standard MCP methods this server does not implement. A client that
        # probes them on connect — Antigravity does — waited forever for a reply
        # that never came, because the dispatch chain fell off the end instead of
        # answering. JSON-RPC 2.0 §5: every REQUEST must be answered.
        {"jsonrpc": "2.0", "id": 10, "method": "resources/list", "params": {}},
        {"jsonrpc": "2.0", "id": 11, "method": "prompts/list", "params": {}},
        # ...and the other half of §5: a NOTIFICATION has no id and must be
        # answered with nothing at all. A fix that replies to everything would
        # pass the two checks above and still be wrong.
        {"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {}},
        # The analyses hand-write their JSON, so a bad escape ships invalid
        # content that no unit test sees. Each one is parsed back here.
        tool(20, "analyze", {"analysis": "spawn_scan"}),
        tool(21, "analyze", {"analysis": "field_contention"}),
        tool(22, "analyze", {"analysis": "logic_shapes"}),
        tool(23, "analyze", {"analysis": "leak_shapes"}),
        tool(24, "analyze", {"analysis": "deps"}),
        tool(25, "analyze", {"analysis": "health"}),
    ]
    m = rpc(ws, calls)

    # Envelope checks: every response well-formed JSON-RPC.
    for i in range(1, 12):
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

    # Unknown methods: an error, the right code, and the method named back so the
    # client's log says which call it was.
    for i, method in ((10, "resources/list"), (11, "prompts/list")):
        err = m.get(i, {}).get("error", {})
        check(err.get("code") == -32601,
              f"{method} answered with -32601 (got {err.get('code')})")
        check(method in (err.get("message") or ""),
              f"{method} error message names the method (got {err.get('message')!r})")
        check("result" not in m.get(i, {}), f"{method} did not also return a result")

    # A reply to a notification would arrive as id:null, which rpc() records
    # under the key None.
    check(None not in m, "a notification got no reply")

    # Every analysis answers with parseable JSON, and each one reports the
    # fault its fixture holds.
    parsed = {}
    for i, name in ((20, "spawn_scan"), (21, "field_contention"), (22, "logic_shapes"),
                    (23, "leak_shapes"), (24, "deps"), (25, "health")):
        check(i in m, f"analyze({name}) answered")
        try:
            parsed[name] = json.loads(text(m[i]))
            check(True, f"analyze({name}) content is valid JSON")
        except Exception as e:
            check(False, f"analyze({name}) content valid JSON ({e})")

    if "spawn_scan" in parsed:
        f = parsed["spawn_scan"].get("findings", [])
        check(any(x["runtime"] == "aws" and x["period_secs"] == 15 and x["via"] == "s3"
                  for x in f),
              f"spawn_scan finds aws every 15s through the s3 wrapper (got {f})")
        check(any(x["long_lived_peer"] for x in f),
              "spawn_scan names the long-lived process in the same script")

    if "field_contention" in parsed:
        c = parsed["field_contention"].get("contended", [])
        check(any(x["field"] == "image" and x["owner_count"] >= 3 for x in c),
              f"field_contention finds three owners of image (got {c})")

    if "logic_shapes" in parsed:
        f = parsed["logic_shapes"].get("findings", [])
        check(any(x["kind"] == "sized_constant" and x["constant_bytes"] == 268435456
                  and x["percent_of_limit"] == 50 for x in f),
              f"logic_shapes finds mmap_size at 50% of the declared 512Mi (got {f})")

    if "leak_shapes" in parsed:
        f = parsed["leak_shapes"].get("findings", [])
        check(any(x["subject"] == "SessionStore.sessions" for x in f),
              f"leak_shapes finds the growing struct field (got {f})")
        check(all(x.get("runtime_check") for x in f),
              "every leak shape names the runtime series that settles it")

    if "deps" in parsed:
        d = parsed["deps"]
        check(any(x["name"] == "bitflags" and len(x["versions"]) == 2
                  for x in d.get("duplicates", [])),
              f"deps finds bitflags in two versions (got {d.get('duplicates')})")
        check(any(x["name"] == "never_used_crate" for x in d.get("unreferenced", [])),
              f"deps finds the unreferenced crate (got {d.get('unreferenced')})")

    workspace_recovery()

    await_daemon_exit()

    print()
    if failures:
        print(f"E2E FAILED: {len(failures)} failure(s)")
        for f in failures:
            print("  - " + f)
        sys.exit(1)
    print("E2E PASSED")


if __name__ == "__main__":
    main()

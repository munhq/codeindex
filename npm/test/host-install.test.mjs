// The machine host step, run against a temporary home.
//
// A test that touched the real ~/.config/mcp-kit/host.json would change the
// machine that runs it, so each case gets its own HOME, its own XDG data folder
// and a PATH that holds only stand-ins for the two programs the step calls:
// `claude` (the client) and `systemctl` (the service manager). `--skip-sdk`
// keeps the run off the network; the SDK install is a separate concern of the
// same program.

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const program = join(dirname(fileURLToPath(import.meta.url)), "..", "bin", "host-install.mjs");

function machine() {
  const root = mkdtempSync(join(tmpdir(), "codeindex-host-test-"));
  const home = join(root, "home");
  const bin = join(root, "bin");
  const calls = join(root, "calls.log");
  mkdirSync(home, { recursive: true });
  mkdirSync(bin, { recursive: true });
  writeFileSync(calls, "");

  for (const name of ["claude", "systemctl"]) {
    const file = join(bin, name);
    writeFileSync(
      file,
      [
        "#!/bin/sh",
        `printf '%s %s\\n' "${name}" "$*" >> "${calls}"`,
        'case "$*" in',
        "  'mcp get '*) exit 1 ;;",
        "esac",
        "exit 0",
        "",
      ].join("\n"),
    );
    chmodSync(file, 0o755);
  }

  return {
    root,
    home,
    calls,
    env: {
      HOME: home,
      XDG_DATA_HOME: join(home, ".local", "share"),
      PATH: [bin, "/usr/bin", "/bin"].join(":"),
    },
    log: () => readFileSync(calls, "utf8"),
    hostDir: join(home, ".local", "share", "codeindex", "host"),
    config: join(home, ".config", "mcp-kit", "host.json"),
    unit: join(home, ".config", "systemd", "user", "mcp-kit-host.service"),
  };
}

function run(m, args) {
  const r = spawnSync(process.execPath, [program, "install", ...args, "--skip-sdk"], {
    encoding: "utf8",
    env: m.env,
  });
  assert.equal(r.status, 0, `exit ${r.status}: ${r.stderr}`);
  return r.stdout;
}

test("install puts the server in the machine file and one URL in the client", () => {
  const m = machine();
  const out = run(m, ["--command", process.execPath]);

  const config = JSON.parse(readFileSync(m.config, "utf8"));
  assert.deepEqual(config, {
    port: 7717,
    host: "127.0.0.1",
    // `cwd` keeps codeindex off the launch folder of the unit, which is the
    // home directory: it would index all of it.
    servers: [{ name: "codeindex", command: process.execPath, args: ["--mcp"], cwd: m.hostDir }],
  });

  assert.match(m.log(), /claude mcp add --scope user --transport http codeindex http:\/\/127\.0\.0\.1:7717\/codeindex/);
  assert.doesNotMatch(m.log(), /--mcp\b/);
  assert.match(out, /the host serves codeindex at http:\/\/127\.0\.0\.1:7717\/codeindex/);

  assert.ok(existsSync(m.unit), `no unit at ${m.unit}`);
  const unit = readFileSync(m.unit, "utf8");
  assert.match(unit, /ExecStart=.*codeindex\/host\/mcp-kit\/host-main\.js/);
  assert.ok(unit.includes(`"--config" "${m.config}"`), `the unit does not read ${m.config}`);
  assert.match(m.log(), /systemctl --user enable --now mcp-kit-host\.service/);
  // A host that already runs must read the new entry.
  assert.match(m.log(), /systemctl --user restart mcp-kit-host\.service/);

  // The service reads the host folder, never this package: a prune of the npm
  // cache must not stop the server.
  assert.ok(existsSync(join(m.hostDir, "mcp-kit", "host-main.js")));
  assert.ok(existsSync(join(m.hostDir, "local-host.js")));
  assert.ok(!unit.includes(join(dirname(dirname(program)), "vendor")), "the unit points at the package");
});

test("a second run changes nothing", () => {
  const m = machine();
  run(m, ["--command", process.execPath]);
  const before = readFileSync(m.config, "utf8");
  const out = run(m, ["--command", process.execPath]);

  assert.equal(readFileSync(m.config, "utf8"), before);
  assert.match(out, /kept codeindex in/);
  assert.doesNotMatch(out, /wrote /);
  assert.doesNotMatch(out, /restarted /);
});

test("--host-only writes no client entry", () => {
  const m = machine();
  run(m, ["--host-only", "--command", process.execPath]);

  assert.ok(existsSync(m.config));
  assert.ok(existsSync(m.unit));
  assert.doesNotMatch(m.log(), /claude/);
});

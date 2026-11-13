#!/usr/bin/env node
// Register codeindex as the one MCP server of this machine.
//
// A client that holds a stdio command starts its own copy of the server, so a
// machine with ten agent sessions runs ten servers and holds ten indexes. This
// program puts the server into the machine file of @munhq/mcp-kit
// (~/.config/mcp-kit/host.json), makes sure the user service mcp-kit-host runs,
// and writes one URL entry for each installed client:
//
//   http://127.0.0.1:7717/codeindex
//
// The service needs the kit's host program and @modelcontextprotocol/sdk. This
// package is public and the kit is private, so the host program is copied into
// ~/.local/share/codeindex/host with the package, and the SDK is installed
// there from npmjs.org. The service reads that folder, never this package, so a
// later prune of the package cache does not stop it.
//
//   codeindex-host install [--command <path to codeindex>] [--host-only]

import { spawnSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { addMcpServer, installedClients } from "../vendor/mcp-kit/clients.js";
import { systemHost } from "../vendor/mcp-kit/host.js";
import { addServer, configPath, hostArgv, hostStatus, installHost } from "../vendor/mcp-kit/registry.js";

const SERVER = "codeindex";
const SDK = "^1.31.0";
const USAGE = `codeindex-host install [--command <path to codeindex>] [--host-only] [--skip-sdk]

  Puts ${SERVER} into ~/.config/mcp-kit/host.json, starts the user service
  mcp-kit-host, and writes the URL entry http://127.0.0.1:7717/${SERVER} for
  each client on this machine.

  --command <path>  the program of the server; default: codeindex on PATH
  --host-only       write the machine file and the service, no client entry
  --skip-sdk        do not install @modelcontextprotocol/sdk; the caller has
                    put it in the host folder already`;

function fail(message) {
  process.stderr.write(`codeindex-host: ${message}\n`);
  process.exit(1);
}

function parseArgs(argv) {
  const options = { command: null, hostOnly: false, skipSdk: false };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "install") continue;
    else if (arg === "--command") options.command = argv[++i];
    else if (arg === "--host-only") options.hostOnly = true;
    else if (arg === "--skip-sdk") options.skipSdk = true;
    else if (arg === "--help" || arg === "-h") {
      process.stdout.write(USAGE + "\n");
      process.exit(0);
    } else fail(`unknown argument ${arg}\n\n${USAGE}`);
  }
  return options;
}

function onPath(program) {
  const found = spawnSync("sh", ["-c", `command -v ${program}`], { encoding: "utf8" });
  return found.status === 0 && found.stdout.trim() ? found.stdout.trim() : null;
}

function hostDir() {
  const base = process.env.XDG_DATA_HOME || join(homedir(), ".local", "share");
  return join(base, "codeindex", "host");
}

// Copy the host program beside a package.json of its own, so node resolves the
// SDK from a folder that stays put.
function installHostFiles(dir, { skipSdk = false } = {}) {
  const vendor = join(dirname(fileURLToPath(import.meta.url)), "..", "vendor");
  if (!existsSync(join(vendor, "mcp-kit", "host-main.js"))) {
    fail("npm/vendor is missing; run `node scripts/vendor-mcp-kit.mjs --from <mcp-kit checkout>`");
  }
  mkdirSync(dir, { recursive: true });
  cpSync(vendor, dir, { recursive: true });

  const manifest = join(dir, "package.json");
  const text = JSON.stringify(
    {
      name: "codeindex-host",
      private: true,
      type: "module",
      description: "The mcp-kit host that serves codeindex once for this machine.",
      dependencies: { "@modelcontextprotocol/sdk": SDK },
    },
    null,
    2,
  ) + "\n";
  const before = existsSync(manifest) ? readFileSync(manifest, "utf8") : null;
  writeFileSync(manifest, text);

  if (skipSdk) return dir;
  const installed = join(dir, "node_modules", "@modelcontextprotocol", "sdk", "package.json");
  if (before === text && existsSync(installed)) return dir;

  const npm = spawnSync("npm", ["install", "--omit=dev", "--ignore-scripts", "--no-audit", "--no-fund"], {
    cwd: dir,
    stdio: ["ignore", "inherit", "inherit"],
  });
  if (npm.status !== 0) fail(`npm install failed in ${dir}; the service needs @modelcontextprotocol/sdk`);
  return dir;
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const command = options.command || onPath(SERVER);
  if (!command) fail(`${SERVER} is not on PATH; pass --command <path to ${SERVER}>`);
  if (!existsSync(command)) fail(`${command} does not exist`);

  const h = systemHost();
  const dir = installHostFiles(hostDir(), { skipSdk: options.skipSdk });

  // The host starts one child and never learns the folder of a client, so the
  // child starts in the host folder: a folder with one package.json. A session
  // names its project once with `index_workspace`. The launch folder of the
  // unit is the home directory, and codeindex would index all of it.
  const added = addServer(h, { name: SERVER, command, args: ["--mcp"], cwd: dir });
  const service = installHost(h, {
    argv: hostArgv({ node: process.execPath, main: join(dir, "mcp-kit", "host-main.js"), config: configPath(h.home) }),
  });
  process.stdout.write(`codeindex-host: ${added.changed ? "added" : "kept"} ${SERVER} in ${configPath(h.home)}\n`);
  for (const file of service.written) process.stdout.write(`codeindex-host: wrote ${file}\n`);

  // A host that already runs holds the old entry until it reads the file again.
  if (added.changed && hostStatus(h) === "running") {
    h.run("systemctl", ["--user", "restart", "mcp-kit-host.service"], {});
    process.stdout.write(`codeindex-host: restarted mcp-kit-host.service\n`);
  }

  const url = `http://127.0.0.1:7717/${SERVER}`;
  if (!options.hostOnly) {
    // The machine file is written above; this call writes the client entries.
    const result = addMcpServer(h, installedClients(h), { name: SERVER, local: { server: SERVER } });
    for (const outcome of result.outcomes) {
      process.stdout.write(`codeindex-host: ${outcome.client}: ${outcome.message}\n`);
    }
  }
  process.stdout.write(`codeindex-host: the host serves ${SERVER} at ${url}\n`);
}

main();

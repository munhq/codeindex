#!/usr/bin/env node
// Copy the parts of @munhq/mcp-kit that this package needs into npm/vendor.
//
// The kit is private, on GitHub Packages. This package is public, on npmjs.org,
// and `curl … | sh` runs it on a machine that holds no token. A dependency on
// the kit would therefore break the install for every user without a token, so
// the pieces are copied in and shipped with the package.
//
//   node scripts/vendor-mcp-kit.mjs 0.23.3
//   node scripts/vendor-mcp-kit.mjs --from ../launchkit/packages/mcp-kit
//
// The first form packs the published tarball and needs NODE_AUTH_TOKEN that can
// read the package. The second form reads a checkout, which is what a machine
// without a token uses; the version comes from that checkout's package.json.
//
// What is copied, and why each file:
//
//   cli/registry.js    addServer, installHost, hostArgv, configPath
//   cli/clients.js     addMcpServer, installedClients
//   cli/host.js        systemHost, the machine this runs on
//   cli/host-main.js   the program the user service runs
//   cli/host-plain.js  the host command that host-main.js starts
//   cli/host-run.js    install, status and uninstall of the service
//   local-host.js      one session for each client, one child for each server
//   loopback.js        the port and the interface
//
// Not copied: index.js, login.js, token.js, device.js and store.js. Those are
// the sign-in of a hosted product; they import better-auth, which this package
// does not install.

import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const CLI_FILES = ["clients", "host", "host-main", "host-plain", "host-run", "registry"];
const DIST_FILES = ["local-host", "loopback"];
// local-host.js is the only copied file that imports the SDK, and the host
// folder installs the SDK itself (see npm/bin/host-install.mjs).
const ALLOWED = [/^node:/, /^\.\.?\//, /^@modelcontextprotocol\/sdk\//];

const args = process.argv.slice(2);
const fromIndex = args.indexOf("--from");
let source;
let version;

if (fromIndex !== -1) {
  source = args[fromIndex + 1];
  if (!source) throw new Error("--from needs a path to a mcp-kit package folder");
  version = JSON.parse(readFileSync(join(source, "package.json"), "utf8")).version;
} else {
  version = args[0];
  if (!version || !/^\d+\.\d+\.\d+$/.test(version)) {
    throw new Error("usage: node scripts/vendor-mcp-kit.mjs <version>\n       node scripts/vendor-mcp-kit.mjs --from <path>");
  }
}

function fromTarball() {
  const token = process.env.NODE_AUTH_TOKEN;
  if (!token) throw new Error("NODE_AUTH_TOKEN is not set, and the kit is private; use --from <path> instead");
  const work = mkdtempSync(join(tmpdir(), "vendor-mcp-kit-"));
  writeFileSync(
    join(work, ".npmrc"),
    ["@munhq:registry=https://npm.pkg.github.com", `//npm.pkg.github.com/:_authToken=${token}`, ""].join("\n"),
  );
  execFileSync("npm", ["pack", `@munhq/mcp-kit@${version}`], {
    cwd: work,
    stdio: ["ignore", "ignore", "inherit"],
    env: { ...process.env, npm_config_userconfig: join(work, ".npmrc") },
  });
  execFileSync("tar", ["xzf", `munhq-mcp-kit-${version}.tgz`], { cwd: work, stdio: "inherit" });
  return { dist: join(work, "package", "dist"), clean: () => rmSync(work, { recursive: true, force: true }) };
}

let dist;
let clean = () => {};
if (source) {
  dist = join(source, "dist");
} else {
  const packed = fromTarball();
  dist = packed.dist;
  clean = packed.clean;
}

const vendor = join(root, "npm", "vendor");
const kitDir = join(vendor, "mcp-kit");
rmSync(vendor, { recursive: true, force: true });
mkdirSync(kitDir, { recursive: true });

// The copy keeps the import graph of the kit, so clients.js still finds
// ../loopback.js and ./registry.js.
function copy(name, to, folder = "") {
  for (const ext of [".js", ".d.ts"]) {
    const src = join(dist, folder, name + ext);
    let text;
    try {
      text = readFileSync(src, "utf8");
    } catch (error) {
      if (error.code === "ENOENT" && ext === ".d.ts") continue; // not every file has types
      throw error;
    }
    if (ext === ".js") {
      for (const [, module] of text.matchAll(/from ['"]([^'"]+)['"]/g)) {
        if (!ALLOWED.some((pattern) => pattern.test(module))) {
          throw new Error(`${name}.js imports ${module}, which this package does not install`);
        }
      }
    }
    writeFileSync(join(to, name + ext), text);
  }
}

for (const name of CLI_FILES) copy(name, kitDir, "cli");
for (const name of DIST_FILES) copy(name, vendor);

// The vendor folder holds ESM inside a CommonJS package, and node decides the
// module kind from the nearest package.json. Without this marker node reads the
// copy as CommonJS and the import statements fail.
writeFileSync(join(vendor, "package.json"), JSON.stringify({ type: "module" }, null, 2) + "\n");
writeFileSync(join(kitDir, "VERSION"), `@munhq/mcp-kit ${version}\n`);

const beside = readdirSync(vendor).length - 1;
console.log(`vendored @munhq/mcp-kit ${version}: ${readdirSync(kitDir).length} files in npm/vendor/mcp-kit, ${beside} beside it`);
clean();

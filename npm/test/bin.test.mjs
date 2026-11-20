// `npx -y @munhq/codeindex` names no command. npm then runs the only command
// of the package, or the command named like the package without its scope.
// 0.6.9 had two commands, `codeindex-mcp` and `codeindex-host`, and none named
// `codeindex`: npx stopped with "could not determine executable to run", and
// the plugin, which starts the server that way, started nothing.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const pkg = JSON.parse(readFileSync(join(dirname(fileURLToPath(import.meta.url)), "..", "package.json"), "utf8"));

test("a bare npx of the package runs the MCP launcher", () => {
  const bins = Object.keys(pkg.bin);
  const unscoped = pkg.name.replace(/^@[^/]+\//, "");
  const chosen = bins.length === 1 ? pkg.bin[bins[0]] : pkg.bin[unscoped];
  assert.equal(chosen, "bin/codeindex-mcp.js", `npx would run ${chosen ?? "nothing"} (commands: ${bins.join(", ")})`);
});

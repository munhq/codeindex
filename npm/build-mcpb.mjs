#!/usr/bin/env node
// Build the .mcpb bundle: the artefact Smithery requires for a stdio release,
// and the one Claude Desktop installs with a double click.
//
// `PUT /servers/{namespace}%2F{server}/releases` refuses a stdio release without
// a `bundle` part — it answers `Missing required part: bundle`. The first listing
// was built by hand at a terminal, which is exactly the thing that rots: the next
// version ships and the listing still describes the old one. So it is a script,
// and it reads its facts from the same files the npm package and server.json do.
//
// What goes in it, and what does not: the wrapper, not the binary. Six platforms
// at ~53 MB each would make a bundle that is almost entirely dead weight for
// every user, so the bundle carries the same resolve-and-verify wrapper the npm
// package uses, and it fetches the one asset the host actually needs.
//
// Usage: node npm/build-mcpb.mjs [--card <tools.json>] [--out <file.mcpb>]
//   --card  a `tools/list` result captured from the real server, so the declared
//           tool list cannot drift from the code. Optional: without it the
//           bundle simply declares no tools.
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, copyFileSync, writeFileSync, readFileSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const pkg = JSON.parse(readFileSync(path.join(here, 'package.json'), 'utf8'));

const argv = process.argv.slice(2);
const argOf = (name) => {
  const i = argv.indexOf(name);
  return i === -1 ? null : argv[i + 1];
};
// Resolved, because zip runs with cwd set to the staging directory: a relative
// --out would be created inside a temp dir that is deleted moments later, and
// zip simply answers "Could not create output file".
const out = path.resolve(argOf('--out') || path.join(here, '..', `codeindex-${pkg.version}.mcpb`));
const cardPath = argOf('--card');

let tools = [];
if (cardPath) {
  const card = JSON.parse(readFileSync(cardPath, 'utf8'));
  const list = card.tools || card.result?.tools || [];
  tools = list.map((t) => ({ name: t.name, description: t.description || '' }));
}

const stage = mkdtempSync(path.join(tmpdir(), 'codeindex-mcpb-'));
try {
  mkdirSync(path.join(stage, 'server'));
  for (const f of ['codeindex-mcp.js', 'resolve.js']) {
    copyFileSync(path.join(here, 'bin', f), path.join(stage, 'server', f));
  }
  // resolve.js reads ../package.json for the version whose release it downloads.
  // Keeping that layout means the bundle cannot disagree with the npm package
  // about which binary it wants.
  writeFileSync(
    path.join(stage, 'package.json'),
    JSON.stringify({ name: pkg.name, version: pkg.version, private: true }, null, 2) + '\n'
  );

  const manifest = {
    manifest_version: '0.3',
    name: 'codeindex',
    display_name: 'codeindex',
    version: pkg.version,
    description: 'Structural code intelligence over MCP: symbols, callers, imports and blast radius across 40+ languages.',
    long_description:
      "Answers 'where is X defined', 'show me this function', 'what calls it' and 'what breaks if I change this file' in tens of tokens instead of the ~1,563 a file read costs. tree-sitter, 16 tools, one statically linked binary, no account or key.",
    author: { name: 'munhq', url: 'https://github.com/munhq' },
    homepage: 'https://github.com/munhq/codeindex',
    repository: { type: 'git', url: 'https://github.com/munhq/codeindex' },
    license: 'MIT',
    keywords: ['mcp', 'code-intelligence', 'tree-sitter', 'context-window'],
    // The bundle is what Claude Desktop installs, and its manifest is the only
    // place that install can get an icon from. Referenced by URL rather than
    // packed in, so the 4 KB bundle stays 4 KB.
    icons: [
      { src: 'https://raw.githubusercontent.com/munhq/codeindex/main/docs/brand/icon-128.png', size: '128x128' },
      { src: 'https://raw.githubusercontent.com/munhq/codeindex/main/docs/brand/icon-512.png', size: '512x512' },
    ],
    server: {
      type: 'node',
      entry_point: 'server/codeindex-mcp.js',
      mcp_config: { command: 'node', args: ['${__dirname}/server/codeindex-mcp.js'] },
    },
    tools,
    tools_generated: false,
    compatibility: { platforms: ['darwin', 'win32', 'linux'], runtimes: { node: '>=18.0.0' } },
  };
  writeFileSync(path.join(stage, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n');

  rmSync(out, { force: true });
  // zip, not a JS zip library: this runs on a release runner and in a terminal,
  // and both have it. A dependency here would be the only one in the package.
  execFileSync('zip', ['-qr', out, '.'], { cwd: stage });
} finally {
  rmSync(stage, { recursive: true, force: true });
}

const bytes = readFileSync(out);
process.stdout.write(
  `${path.basename(out)}  ${statSync(out).size} bytes  sha256=${createHash('sha256').update(bytes).digest('hex')}\n` +
    `  version ${pkg.version}, ${tools.length} tool(s) declared\n`
);

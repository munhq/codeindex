#!/usr/bin/env node
// Publish a Smithery stdio release: the listing, its config schema, and the full
// tool card.
//
// This exists because the first listing was published with a handful of curl
// commands, and a listing published by hand is a listing that describes an old
// version forever. Everything the API needs is derived here from the same files
// and the same binary the release ships.
//
// Three things the API requires that its error messages do not say plainly, each
// of which cost an attempt:
//   - `bundle` is required for a stdio release. Without it: 400 "Missing
//     required part: bundle".
//   - `payload` is a form field holding JSON *as a string*, not a file upload.
//   - `serverCard.serverInfo` requires BOTH name and version. Omitting version
//     returns 400 "Invalid input: expected string, received undefined", which
//     names no field at all.
//
// Usage:
//   SMITHERY_API_KEY=… node npm/publish-smithery.mjs \
//     --card card.json --bundle codeindex-0.3.3.mcpb
// Optional: --namespace (default munhq), --server (default codeindex), --dry-run.
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const pkg = JSON.parse(readFileSync(path.join(here, 'package.json'), 'utf8'));

const argv = process.argv.slice(2);
const argOf = (n, d = null) => {
  const i = argv.indexOf(n);
  return i === -1 ? d : argv[i + 1];
};
const has = (n) => argv.includes(n);

const namespace = argOf('--namespace', 'munhq');
const server = argOf('--server', 'codeindex');
const cardPath = argOf('--card');
const bundlePath = argOf('--bundle');
const dryRun = has('--dry-run');

const die = (msg) => {
  process.stderr.write(`publish-smithery: ${msg}\n`);
  process.exit(1);
};

if (!cardPath || !bundlePath) die('need --card <tools.json> and --bundle <file.mcpb>');
const key = process.env.SMITHERY_API_KEY;
if (!key && !dryRun) {
  die('SMITHERY_API_KEY is not set. It is the bearer token from smithery.ai; nothing else authenticates this API.');
}

const card = JSON.parse(readFileSync(cardPath, 'utf8'));
const tools = card.tools || card.result?.tools || [];
if (!tools.length) die(`${cardPath} declares no tools — refusing to publish a listing with an empty tool card`);

// Mirrors smithery.yaml. Nothing is required, because codeindex needs no account,
// key or configuration; the one option is for a client that starts the server
// outside the repository it should index.
const configSchema = {
  type: 'object',
  properties: {
    workspace: {
      type: 'string',
      title: 'Workspace directory',
      description:
        'Directory to index. Leave empty and codeindex uses the enclosing project root of wherever the client starts it, which is correct for every editor and agent that launches the server inside a repository.',
      default: '',
    },
  },
  required: [],
};

const payload = {
  type: 'stdio',
  runtime: 'node',
  configSchema,
  serverCard: {
    serverInfo: {
      name: 'codeindex',
      title: 'codeindex',
      version: pkg.version,
      description:
        'Structural code intelligence over MCP: symbols, callers, imports and blast radius across 40+ languages.',
      websiteUrl: 'https://github.com/munhq/codeindex',
    },
    tools,
  },
};

const qualified = `${encodeURIComponent(`${namespace}/${server}`)}`;
const url = `https://api.smithery.ai/servers/${qualified}/releases`;

if (dryRun) {
  process.stdout.write(
    `dry run: PUT ${url}\n  version ${pkg.version}, ${tools.length} tools, bundle ${path.basename(bundlePath)}\n`
  );
  process.exit(0);
}

const form = new FormData();
// A string field. Sent as a file part, the API answers "expected string,
// received undefined" and names nothing.
form.append('payload', JSON.stringify(payload));
form.append(
  'bundle',
  new Blob([readFileSync(bundlePath)], { type: 'application/zip' }),
  path.basename(bundlePath)
);

const res = await fetch(url, { method: 'PUT', headers: { authorization: `Bearer ${key}` }, body: form });
const text = await res.text();
if (!res.ok) die(`PUT ${url} -> HTTP ${res.status}: ${text}`);

let body;
try {
  body = JSON.parse(text);
} catch {
  die(`unparseable response: ${text.slice(0, 200)}`);
}
process.stdout.write(
  `published ${namespace}/${server} ${pkg.version}: status=${body.status} ` +
    `deployment=${body.deploymentId} url=${body.mcpUrl}\n` +
    `  ${tools.length} tools on the card\n`
);
for (const w of body.warnings || []) process.stderr.write(`  warning: ${w}\n`);
if (body.status && !['SUCCESS', 'QUEUED', 'WORKING'].includes(body.status)) {
  die(`release status is ${body.status}`);
}

#!/usr/bin/env node
// Capture a server's tool list by speaking MCP to it, the way a client does.
//
// The obvious version — printf three JSON-RPC lines into the binary and read
// stdout — is what this replaces, because it depends on the server tolerating
// EOF arriving before it has answered. codeindex does; distil does not, and the
// release that found this out reported "the binary advertised no tools" while the
// same binary answered a real client perfectly. A capture that works by accident
// on one server and fails on the next is not a capture.
//
// So: spawn, send, wait for each id, and only then close stdin. No sleeps.
//
// Usage:
//   node capture-card.mjs --out card.json -- <binary> [args...]
import { spawn } from 'node:child_process';
import { writeFileSync } from 'node:fs';

const argv = process.argv.slice(2);
const sep = argv.indexOf('--');
if (sep === -1) {
  process.stderr.write('usage: capture-card.mjs --out <file> -- <binary> [args...]\n');
  process.exit(2);
}
const outIdx = argv.indexOf('--out');
const out = outIdx === -1 ? 'card.json' : argv[outIdx + 1];
const [bin, ...args] = argv.slice(sep + 1);
if (!bin) {
  process.stderr.write('capture-card: no binary given\n');
  process.exit(2);
}

const child = spawn(bin, args, { stdio: ['pipe', 'pipe', 'ignore'] });
const pending = new Map();
let buf = '';

child.stdout.on('data', (chunk) => {
  buf += chunk;
  let nl;
  while ((nl = buf.indexOf('\n')) !== -1) {
    const line = buf.slice(0, nl).trim();
    buf = buf.slice(nl + 1);
    if (!line) continue;
    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      // Anything that is not JSON on stdout is a protocol violation by the
      // server, and worth saying so rather than silently skipping.
      process.stderr.write(`capture-card: non-JSON line on stdout: ${line.slice(0, 120)}\n`);
      continue;
    }
    const resolve = pending.get(msg.id);
    if (resolve) {
      pending.delete(msg.id);
      resolve(msg);
    }
  }
});

const fail = (msg) => {
  process.stderr.write(`::error::${msg}\n`);
  child.kill();
  process.exit(1);
};

const send = (obj) => child.stdin.write(JSON.stringify(obj) + '\n');

const call = (obj, what) =>
  new Promise((resolve) => {
    const timer = setTimeout(() => fail(`${what} got no reply within 60s`), 60_000);
    pending.set(obj.id, (m) => {
      clearTimeout(timer);
      resolve(m);
    });
    send(obj);
  });

child.on('error', (e) => fail(`could not run ${bin}: ${e.message}`));
child.on('exit', (code) => {
  if (pending.size) fail(`${bin} exited (${code}) before answering`);
});

const init = await call(
  {
    jsonrpc: '2.0', id: 1, method: 'initialize',
    params: {
      protocolVersion: '2024-11-05', capabilities: {},
      clientInfo: { name: 'capture-card', version: '0' },
    },
  },
  'initialize'
);
const info = init.result?.serverInfo;
if (!info?.name) fail('initialize returned no serverInfo');

send({ jsonrpc: '2.0', method: 'notifications/initialized' });

const listed = await call({ jsonrpc: '2.0', id: 2, method: 'tools/list', params: {} }, 'tools/list');
const tools = listed.result?.tools;
if (!tools?.length) fail('the server advertised no tools');

writeFileSync(out, JSON.stringify({ serverInfo: info, tools }));
process.stdout.write(`captured ${tools.length} tools from ${info.name} ${info.version}\n`);
child.stdin.end();
child.kill();
process.exit(0);

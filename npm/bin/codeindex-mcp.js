#!/usr/bin/env node
// The MCP server entry point: resolve the binary, then become it.
//
// `npx -y @munhq/codeindex` lands here. Every argument is passed straight
// through, so `--workspace`, `--mcp` and anything the server grows later work
// without this file knowing about them.
'use strict';

const { spawnSync } = require('child_process');
const { resolveBinary, log } = require('./resolve.js');

(async () => {
  let bin;
  try {
    bin = await resolveBinary();
  } catch (err) {
    log(`could not start: ${err.message}`);
    process.exit(1);
  }

  // The client speaks JSON-RPC over this process's stdio, so the child inherits
  // all three streams untouched. No pipe, no buffering, no wrapper protocol.
  const args = process.argv.slice(2);
  // `--mcp` is what the server needs to speak MCP at all. A client that
  // launches the bin with no arguments gets the CLI's help text on stdout and a
  // handshake that never completes, which reads as "the server is broken".
  if (!args.includes('--mcp')) args.unshift('--mcp');

  // Become the binary rather than supervising it.
  //
  // Once the binary is resolved this process adds nothing: stdio is already
  // inherited, and the status it relays below is the child's own. What it does
  // add is a resident Node heap for the whole life of the MCP session — one per
  // session, sitting next to a server that is a few megabytes — and on a cold
  // cache that heap is the one the download inflated. `execve` replaces this
  // process with the binary, so the heap is gone rather than merely idle, and
  // the process tree loses a level.
  //
  // `args` is the complete argv, argv[0] included. POSIX only, and Node 22.15 /
  // 23.11 and later; anywhere else the supervised child below runs exactly as
  // it always did.
  if (typeof process.execve === 'function') {
    try {
      process.execve(bin, [bin, ...args], process.env);
    } catch (err) {
      log(`could not exec ${bin} (${err.message}); supervising it instead`);
    }
  }

  const res = spawnSync(bin, args, { stdio: 'inherit' });
  if (res.error) {
    log(`failed to exec ${bin}: ${res.error.message}`);
    process.exit(1);
  }
  // Relay the child's fate exactly: a signal death must not look like exit 0.
  if (res.signal) process.kill(process.pid, res.signal);
  process.exit(res.status === null ? 1 : res.status);
})();

#!/usr/bin/env node
// Fetch the binary at install time, so the first MCP handshake does not wait for
// a 53 MB download and time out inside the client.
//
// This is allowed to fail. A CI sandbox with no network, or `npm install
// --ignore-scripts`, must still produce a working install — codeindex-mcp.js
// downloads on demand when the cache is empty. So the exit code is always 0 and
// the reason goes to stderr, where it is visible rather than swallowed.
'use strict';

const { resolveBinary, log } = require('./resolve.js');

resolveBinary()
  .then(() => process.exit(0))
  .catch((err) => {
    log(`prefetch skipped: ${err.message}`);
    log('the binary will be fetched on first run instead');
    process.exit(0);
  });

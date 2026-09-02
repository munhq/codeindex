// Resolve a codeindex binary for this platform, downloading the pinned release
// asset when the cache does not already hold it.
//
// Why an npm package at all, for a program that is not JavaScript: every MCP
// directory installs servers the way npm installs them. The official registry
// validates an npm version, Smithery runs `npx`, and mcp.so lists the same
// command. A compiled server with no npm name is invisible to all three, so this
// package is the thin shim that makes `npx -y @munhq/codeindex` work — about
// 4 KB of JavaScript that fetches the 53 MB binary the release already publishes.
//
// Write NOTHING to stdout. Stdout is the MCP JSON-RPC channel; one stray line
// there makes the server look broken with no error that explains why. Every
// diagnostic goes to stderr, which the client logs.
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const https = require('https');
const crypto = require('crypto');
const { Transform, pipeline } = require('stream');

const REPO = 'munhq/codeindex';
const { version: VERSION } = require('../package.json');

const log = (msg) => process.stderr.write(`codeindex: ${msg}\n`);

// Map Node's platform/arch onto the asset names the release actually publishes.
// The release matrix builds Zig target triples — x86_64-linux, aarch64-linux,
// x86_64-macos, aarch64-macos, x86_64-windows, aarch64-windows — and Node agrees
// with none of them: process.platform says darwin/win32, process.arch says x64.
// The shell launcher had this exact bug against uname and every Mac 404'd, so
// the mapping is spelled out rather than assembled from the raw values.
// Pure, so plugin/test_platform.sh can drive it for every platform this package
// claims to support instead of only the one the test runs on. That test already
// holds install.sh and the shell launcher to the release matrix; this is the
// third consumer of the same naming and it drifts the same way.
function assetFor(platform, arch) {
  const a = { x64: 'x86_64', arm64: 'aarch64' }[arch];
  const p = { linux: 'linux', darwin: 'macos', win32: 'windows' }[platform];
  if (!a || !p) return null;
  return `codeindex-${a}-${p}${p === 'windows' ? '.exe' : ''}`;
}

function assetName() {
  return assetFor(process.platform, process.arch);
}

function cacheDir() {
  const base = process.env.XDG_CACHE_HOME || path.join(os.homedir(), '.cache');
  return path.join(base, 'codeindex', 'bin');
}

// The cached file carries the version. The shell launcher caches an unversioned
// `codeindex`, and this repo has already been bitten by that shape: a 0.3.0
// plugin ran a 0.2.0 binary found first on PATH for days, with both halves
// reporting their own version and nobody comparing them. A version in the name
// makes an upgrade a cache miss instead of a silent downgrade.
function cachedBinary() {
  const exe = process.platform === 'win32' ? '.exe' : '';
  return path.join(cacheDir(), `codeindex-${VERSION}${exe}`);
}

function get(url, redirects = 0) {
  return new Promise((resolve, reject) => {
    if (redirects > 5) return reject(new Error(`too many redirects for ${url}`));
    https
      .get(url, { headers: { 'user-agent': `codeindex-npm/${VERSION}` } }, (res) => {
        // GitHub serves release assets as a redirect to object storage.
        if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
          res.resume();
          return resolve(get(res.headers.location, redirects + 1));
        }
        if (res.statusCode !== 200) {
          res.resume();
          return reject(new Error(`GET ${url} -> HTTP ${res.statusCode}`));
        }
        const chunks = [];
        res.on('data', (c) => chunks.push(c));
        res.on('end', () => resolve(Buffer.concat(chunks)));
        res.on('error', reject);
      })
      .on('error', reject);
  });
}

// Stream an asset to `dest`, hashing the bytes as they go past. Resolves to the
// hex digest.
//
// The binary used to be collected chunk by chunk, concatenated into one 53 MB
// Buffer, hashed, and only then written — two whole copies of it live in the
// heap at the peak. This wrapper stays resident for the entire MCP session, and
// V8 does not hand those pages back, so a session that downloaded carried about
// 175 MB for as long as it lived, to supervise a server of a few megabytes.
// Nothing here needs the file in memory: the hash is incremental and the write
// is a pipe.
function download(url, dest, redirects = 0) {
  return new Promise((resolve, reject) => {
    if (redirects > 5) return reject(new Error(`too many redirects for ${url}`));
    https
      .get(url, { headers: { 'user-agent': `codeindex-npm/${VERSION}` } }, (res) => {
        if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
          res.resume();
          return resolve(download(res.headers.location, dest, redirects + 1));
        }
        if (res.statusCode !== 200) {
          res.resume();
          return reject(new Error(`GET ${url} -> HTTP ${res.statusCode}`));
        }
        const hash = crypto.createHash('sha256');
        // The hash is a pass-through in the pipeline, not a `data` listener
        // beside it. Adding a listener puts the response into flowing mode,
        // which disables backpressure: the bytes arrive as fast as the socket
        // delivers them and queue inside the write stream, so the whole 53 MB
        // ends up buffered anyway and the fix fixes nothing. `pipeline` keeps
        // the source paused whenever the disk is behind.
        const tap = new Transform({
          transform(chunk, _enc, cb) {
            hash.update(chunk);
            cb(null, chunk);
          },
        });
        pipeline(res, tap, fs.createWriteStream(dest, { mode: 0o755 }), (err) =>
          err ? reject(err) : resolve(hash.digest('hex'))
        );
      })
      .on('error', reject);
  });
}

// The checksum published beside the binary is not proof on its own — whoever can
// replace one can replace the other. It is here to catch a truncated download
// and a mismatched tag, which are the failures that actually happen, and to make
// the pin auditable: both files come from the tag this package version names.
async function verifiedDownload(asset) {
  const base = `https://github.com/${REPO}/releases/download/v${VERSION}`;
  log(`fetching ${asset} for v${VERSION} (about 53 MB, once per version)`);

  const sums = (await get(`${base}/SHA256SUMS`)).toString('utf8');
  const line = sums.split('\n').find((l) => l.trim().endsWith(` ${asset}`));
  if (!line) throw new Error(`SHA256SUMS for v${VERSION} does not list ${asset}`);
  const want = line.trim().split(/\s+/)[0];

  const dest = cachedBinary();
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  // Download to a temp name and rename, so a killed download never leaves a
  // half file that the next run treats as installed. The name carries this
  // process's pid because several sessions can start at once on a cold cache,
  // and one shared temp name would let them write over each other.
  const tmp = `${dest}.tmp-${process.pid}`;
  const discard = () => {
    try {
      fs.unlinkSync(tmp);
    } catch {}
  };

  let got;
  try {
    got = await download(`${base}/${asset}`, tmp);
  } catch (err) {
    discard();
    throw err;
  }
  if (got !== want) {
    discard();
    throw new Error(`checksum mismatch for ${asset}: want ${want}, got ${got}`);
  }
  // A umask can clear the mode the stream was created with, and a binary that
  // is not executable fails later with a message about the wrong thing.
  fs.chmodSync(tmp, 0o755);
  fs.renameSync(tmp, dest);
  log(`installed ${dest}`);
  return dest;
}

// An explicit override wins, for a local build or an unusual layout. PATH is
// deliberately NOT consulted: this package declares one version to the registry,
// and running whatever `codeindex` happens to be on PATH would make that
// declaration a lie.
async function resolveBinary() {
  const override = process.env.CODEINDEX_BIN;
  if (override && fs.existsSync(override)) return override;

  const cached = cachedBinary();
  if (fs.existsSync(cached)) return cached;

  const asset = assetName();
  if (!asset) {
    throw new Error(
      `no release build for ${process.platform}/${process.arch}. ` +
        `Build from source: https://github.com/${REPO}#build-from-source`
    );
  }
  return verifiedDownload(asset);
}

module.exports = { resolveBinary, cachedBinary, assetName, assetFor, VERSION, log };

#!/usr/bin/env node
// Print the asset this wrapper would fetch on every platform it claims to
// support, one per line, as `platform<TAB>arch<TAB>asset`.
//
// Two consumers: `npm test`, which checks the table is complete and that the
// package version looks like a release tag, and plugin/test_platform.sh, which
// compares these names against the release matrix in
// .github/workflows/release.yml. The shell launcher and install.sh are already
// held to that matrix; this wrapper is the third place the same mapping is
// written, and the Mac 404 it caused once is the reason all three are tested.
'use strict';

const { assetFor, VERSION } = require('./resolve.js');

const SUPPORTED = [
  ['linux', 'x64'],
  ['linux', 'arm64'],
  ['darwin', 'x64'],
  ['darwin', 'arm64'],
  ['win32', 'x64'],
  ['win32', 'arm64'],
];

// Platforms with no release build must resolve to nothing rather than to a
// plausible-looking name that 404s at download time.
const UNSUPPORTED = [
  ['freebsd', 'x64'],
  ['linux', 'ia32'],
  ['sunos', 'x64'],
];

let fail = 0;

for (const [platform, arch] of SUPPORTED) {
  const asset = assetFor(platform, arch);
  if (!asset) {
    process.stderr.write(`FAIL ${platform}/${arch} resolves to nothing\n`);
    fail++;
    continue;
  }
  process.stdout.write(`${platform}\t${arch}\t${asset}\n`);
}

for (const [platform, arch] of UNSUPPORTED) {
  const asset = assetFor(platform, arch);
  if (asset) {
    process.stderr.write(`FAIL ${platform}/${arch} resolves to ${asset}, but no such build exists\n`);
    fail++;
  }
}

// The wrapper downloads from the tag named by its own version, so a version that
// is not a plain release number can never find an asset.
if (!/^\d+\.\d+\.\d+$/.test(VERSION)) {
  process.stderr.write(`FAIL version ${VERSION} is not a release version, so v${VERSION} is not a tag\n`);
  fail++;
}

if (fail) {
  process.stderr.write(`\n${fail} problem(s)\n`);
  process.exit(1);
}
process.stderr.write(`resolver: ${SUPPORTED.length} platforms, version ${VERSION}\n`);

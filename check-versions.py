#!/usr/bin/env python3
"""Assert that every manifest names one version, and optionally the tag.

A release bumps the version by hand in several files. Release 0.3.4 bumped five
of them and missed .cursor-plugin/marketplace.json, so the Cursor listing went
on advertising 0.3.3 for two releases while npm served 0.3.5. Nothing failed,
because nothing compared the files to each other.

Run it with no argument to check the manifests agree. Pass a version to also
require that they agree with it, which is what release CI does with the tag:

    python3 check-versions.py            # the manifests must agree
    python3 check-versions.py 0.3.5      # ...and must all say 0.3.5
"""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def from_json(rel, *path):
    """Read a nested key out of a JSON file, named by its path for the report."""
    data = json.loads((ROOT / rel).read_text())
    for key in path:
        data = data[key]
    return f"{rel}:{'.'.join(str(p) for p in path)}", data


def from_zig(rel, const):
    """DEFAULT_VERSION is Zig source, not JSON, so it needs its own reader."""
    text = (ROOT / rel).read_text()
    match = re.search(rf'{const}\s*=\s*"([^"]+)"', text)
    if not match:
        sys.exit(f"{rel}: no {const} — the check needs updating, not skipping")
    return f"{rel}:{const}", match.group(1)


def from_zon(rel):
    """The Zig package manifest names the version too. It sat at 0.3.2 through two
    releases because nothing read it; a stale manifest is a lie to anyone who
    depends on the package with the Zig package manager."""
    text = (ROOT / rel).read_text()
    match = re.search(r'\.version\s*=\s*"([^"]+)"', text)
    if not match:
        sys.exit(f"{rel}: no .version — the check needs updating, not skipping")
    return f"{rel}:.version", match.group(1)


def collect():
    return [
        from_json("npm/package.json", "version"),
        from_json("plugin/.claude-plugin/plugin.json", "version"),
        from_json("server.json", "version"),
        from_json("server.json", "packages", 0, "version"),
        from_json(".cursor-plugin/marketplace.json", "metadata", "version"),
        from_zig("zig/build.zig", "DEFAULT_VERSION"),
        from_zon("zig/build.zig.zon"),
    ]


def main():
    found = collect()
    want = sys.argv[1].lstrip("v") if len(sys.argv) > 1 else None

    for where, value in found:
        print(f"  {value}  {where}")

    versions = {value for _, value in found}
    if len(versions) > 1:
        print("\nThe manifests disagree:", ", ".join(sorted(versions)), file=sys.stderr)
        sys.exit(1)

    only = versions.pop()
    if want is not None and only != want:
        print(f"\nThe manifests say {only}, the tag says {want}", file=sys.stderr)
        sys.exit(1)

    print(f"\nEvery manifest names {only}." + ("" if want is None else " It matches the tag."))


if __name__ == "__main__":
    main()

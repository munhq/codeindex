#!/usr/bin/env bash
set -euo pipefail

BINARY="codeindex"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
SKILL_DIR="${SKILL_DIR:-$HOME/.claude/skills}"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="munhq/codeindex"

mkdir -p "$INSTALL_DIR"

DEST="$INSTALL_DIR/$BINARY"

# Install $1 to $DEST atomically. codeindex runs as a long-lived server, so a
# running instance may have $DEST mapped; overwriting it in place can SIGBUS
# that process when it faults in a page from the truncated file. Stage to a temp
# on the same filesystem and rename() over the target — atomic, and any running
# instance keeps the old inode until it exits (or hot-reloads via SIGHUP).
atomic_install() {
    local src="$1" tmp
    tmp="$(mktemp "$DEST.XXXXXX")"
    cat "$src" > "$tmp"
    chmod 0755 "$tmp"
    mv -f "$tmp" "$DEST"
}

ARCH="$(uname -m)"
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARTIFACT="${BINARY}-${ARCH}-${OS}"

DL_TMP="$(mktemp "$DEST.dl.XXXXXX")"
# Two faults made this download fail every time, so every install fell through
# to a source build and never said why. It asked for tag v0.1.0, which never
# existed as a release — no tag at all makes gh resolve the latest. And gh
# refuses -O onto a path that already exists, which mktemp above had just
# created, so --clobber is required rather than defensive.
if command -v gh &>/dev/null &&
   gh release download --repo "$REPO" -p "$ARTIFACT" -O "$DL_TMP" --clobber 2>/dev/null; then
    atomic_install "$DL_TMP"
    rm -f "$DL_TMP"
    echo "Installed prebuilt binary to $DEST"
else
    rm -f "$DL_TMP"
    echo "No prebuilt binary for $ARCH-$OS, building from source..."
    if ! command -v zig &>/dev/null; then
        echo "Error: zig not found. Install: https://ziglang.org/download/" >&2
        exit 1
    fi
    # A subshell, because `cd zig` used to leak into the rest of the script and
    # `claude mcp add` below registered the server against the zig
    # subdirectory instead of the user scope.
    ( cd "$SRC_DIR/zig" && ./fetch-vendor.sh && zig build -Doptimize=ReleaseFast )
    atomic_install "$SRC_DIR/zig/zig-out/bin/codeindex"
    echo "Built and installed to $DEST"
fi

# Install the Agent Skills alongside the binary.
#
# This is not optional dressing. A server that registers without telling an
# agent when to reach for it stays idle, and an idle server saves nothing
# however cheap its calls are. Measured on real sessions, the servers that ship
# skills get called and the ones that only register do not.
if [ -d "$SRC_DIR/plugin/skills" ]; then
    mkdir -p "$SKILL_DIR"
    for skill in "$SRC_DIR"/plugin/skills/*/; do
        name="$(basename "$skill")"
        rm -rf "${SKILL_DIR:?}/$name"
        cp -R "$skill" "$SKILL_DIR/$name"
        echo "Installed skill -> $SKILL_DIR/$name"
    done
else
    echo "Warning: no plugin/skills directory found; skills not installed" >&2
fi

if command -v claude &>/dev/null; then
    # -s user, because `claude mcp add` defaults to local scope and would
    # register the server for one directory only. Re-adding a name that exists
    # errors instead of replacing it, so drop any previous entry in either
    # scope first and keep the script re-runnable.
    claude mcp remove -s user codeindex 2>/dev/null || true
    claude mcp remove codeindex 2>/dev/null || true
    claude mcp add -s user codeindex -- "$INSTALL_DIR/$BINARY" --mcp
    echo "Registered with Claude Code (user scope)"
else
    echo "Claude Code not found — register manually:"
    echo "  claude mcp add -s user codeindex -- $INSTALL_DIR/$BINARY --mcp"
fi

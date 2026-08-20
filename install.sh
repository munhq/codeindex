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
if gh release download v0.1.0 --repo "$REPO" -p "$ARTIFACT" -O "$DL_TMP" 2>/dev/null; then
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
    cd zig
    ./fetch-vendor.sh
    zig build -Doptimize=ReleaseFast
    atomic_install zig-out/bin/codeindex
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
    # Re-adding the same name errors instead of replacing, so drop any previous
    # entry first and keep the script re-runnable.
    claude mcp remove codeindex 2>/dev/null || true
    claude mcp add codeindex -- "$INSTALL_DIR/$BINARY" --mcp
    echo "Registered with Claude Code"
else
    echo "Claude Code not found — register manually:"
    echo "  claude mcp add codeindex -- $INSTALL_DIR/$BINARY --mcp"
fi

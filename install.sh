#!/usr/bin/env bash
set -euo pipefail

BINARY="codeindex"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
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

if command -v claude &>/dev/null; then
    claude mcp add codeindex -- "$INSTALL_DIR/$BINARY" --mcp
    echo "Registered with Claude Code"
else
    echo "Claude Code not found — register manually:"
    echo "  claude mcp add codeindex -- $INSTALL_DIR/$BINARY --mcp"
fi

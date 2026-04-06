#!/usr/bin/env bash
set -euo pipefail

BINARY="codeindex"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
REPO="munhq/codeindex"

mkdir -p "$INSTALL_DIR"

ARCH="$(uname -m)"
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARTIFACT="${BINARY}-${ARCH}-${OS}"

if gh release download v0.1.0 --repo "$REPO" -p "$ARTIFACT" -O "$INSTALL_DIR/$BINARY" 2>/dev/null; then
    chmod +x "$INSTALL_DIR/$BINARY"
    echo "Installed prebuilt binary to $INSTALL_DIR/$BINARY"
else
    echo "No prebuilt binary for $ARCH-$OS, building from source..."
    if ! command -v zig &>/dev/null; then
        echo "Error: zig not found. Install: https://ziglang.org/download/" >&2
        exit 1
    fi
    cd zig
    ./fetch-vendor.sh
    zig build -Doptimize=ReleaseFast
    cp zig-out/bin/codeindex "$INSTALL_DIR/$BINARY"
    echo "Built and installed to $INSTALL_DIR/$BINARY"
fi

if command -v claude &>/dev/null; then
    claude mcp add codeindex -- "$INSTALL_DIR/$BINARY" --mcp
    echo "Registered with Claude Code"
else
    echo "Claude Code not found — register manually:"
    echo "  claude mcp add codeindex -- $INSTALL_DIR/$BINARY --mcp"
fi

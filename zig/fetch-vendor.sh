#!/usr/bin/env bash

# A missing repository must fail, not prompt for credentials in CI.
export GIT_TERMINAL_PROMPT=0
set -euo pipefail

VENDOR_DIR="$(cd "$(dirname "$0")" && pwd)/vendor"

# Default path: download the pinned vendor snapshot. The clone path below
# (--from-source) tracks upstream default branches, and upstream moves:
# several grammars no longer ship generated parsers on their default branch,
# and tree-sitter core changed its include layout. The snapshot is the exact
# tree the build is tested against.
SNAPSHOT_URL="https://github.com/munhq/codeindex/releases/download/grammars-20260812/vendor-snapshot-20260812.tar.gz"
SNAPSHOT_SHA256="569c6a56628a8f449f06992435010de01faf2899e5277b5927090c57d52888ed"

if [ "${1:-}" != "--from-source" ]; then
    if [ -d "$VENDOR_DIR/tree-sitter" ] && [ -d "$VENDOR_DIR/grammars" ]; then
        echo "vendor/ already present, nothing to do (use --from-source to refetch from upstream)"
        exit 0
    fi
    echo "Downloading vendor snapshot..."
    tmp="$(mktemp)"
    trap 'rm -f "$tmp"' EXIT
    curl -fsSL "$SNAPSHOT_URL" -o "$tmp"
    if command -v sha256sum >/dev/null; then
        echo "$SNAPSHOT_SHA256  $tmp" | sha256sum -c - >/dev/null
    else
        echo "$SNAPSHOT_SHA256  $tmp" | shasum -a 256 -c - >/dev/null
    fi
    tar -xzf "$tmp" -C "$(dirname "$VENDOR_DIR")"
    echo "Done. $(ls -d "$VENDOR_DIR/grammars"/*/ | wc -l) grammars unpacked."
    exit 0
fi

mkdir -p "$VENDOR_DIR/grammars"

clone() {
    # Split into separate `local` statements: bash evaluates all RHS of a
    # multi-var `local` before any assignment, so `local a=$1 b=$VENDOR/$a`
    # trips `set -u` with "a: unbound variable".
    local name="$1"
    local url="$2"
    local branch="${3:-}"
    local dir="$VENDOR_DIR/grammars/$name"
    if [ -d "$dir" ]; then
        echo "  skip $name (exists)"
        return
    fi
    echo "  fetch $name"
    if [ -n "$branch" ]; then
        git clone --depth 1 --quiet --branch "$branch" "$url" "$dir"
    else
        git clone --depth 1 --quiet "$url" "$dir"
    fi
}

echo "Fetching tree-sitter..."
if [ ! -d "$VENDOR_DIR/tree-sitter" ]; then
    git clone --depth 1 --quiet https://github.com/tree-sitter/tree-sitter "$VENDOR_DIR/tree-sitter"
else
    echo "  skip tree-sitter (exists)"
fi

echo "Fetching grammars..."

# Core languages
clone rust         https://github.com/tree-sitter/tree-sitter-rust
clone python       https://github.com/tree-sitter/tree-sitter-python
clone go           https://github.com/tree-sitter/tree-sitter-go
clone typescript   https://github.com/tree-sitter/tree-sitter-typescript
clone zig          https://github.com/maxxnino/tree-sitter-zig
clone c            https://github.com/tree-sitter/tree-sitter-c
clone cpp          https://github.com/tree-sitter/tree-sitter-cpp
clone java         https://github.com/tree-sitter/tree-sitter-java
clone ruby         https://github.com/tree-sitter/tree-sitter-ruby
clone bash         https://github.com/tree-sitter/tree-sitter-bash
clone c_sharp      https://github.com/tree-sitter/tree-sitter-c-sharp
clone kotlin       https://github.com/fwcd/tree-sitter-kotlin
clone lua          https://github.com/tree-sitter-grammars/tree-sitter-lua
clone scala        https://github.com/tree-sitter/tree-sitter-scala
clone elixir       https://github.com/elixir-lang/tree-sitter-elixir
clone r            https://github.com/r-lib/tree-sitter-r
# swift does not commit the generated parser on its default branch;
# the with-generated-files branch carries src/parser.c.
clone swift        https://github.com/alex-pinkus/tree-sitter-swift with-generated-files
clone dart         https://github.com/UserNobody14/tree-sitter-dart
clone haskell      https://github.com/tree-sitter/tree-sitter-haskell

# Config/data/infra
clone toml         https://github.com/tree-sitter/tree-sitter-toml
clone json         https://github.com/tree-sitter/tree-sitter-json
clone yaml         https://github.com/tree-sitter-grammars/tree-sitter-yaml
clone css          https://github.com/tree-sitter/tree-sitter-css
clone html         https://github.com/tree-sitter/tree-sitter-html
clone hcl          https://github.com/tree-sitter-grammars/tree-sitter-hcl
clone dockerfile   https://github.com/camdencheek/tree-sitter-dockerfile
clone markdown     https://github.com/tree-sitter-grammars/tree-sitter-markdown
# The markdown repository is a split grammar: the block parser lives in a
# tree-sitter-markdown/ subdirectory, the inline parser in
# tree-sitter-markdown-inline/. The build expects src/ at the grammar root,
# so lift the block parser up after a fresh clone.
if [ ! -d "$VENDOR_DIR/grammars/markdown/src" ] && [ -d "$VENDOR_DIR/grammars/markdown/tree-sitter-markdown/src" ]; then
    mv "$VENDOR_DIR/grammars/markdown/tree-sitter-markdown/src" "$VENDOR_DIR/grammars/markdown/src"
    if [ -d "$VENDOR_DIR/grammars/markdown/tree-sitter-markdown/queries" ]; then
        mv "$VENDOR_DIR/grammars/markdown/tree-sitter-markdown/queries" "$VENDOR_DIR/grammars/markdown/queries"
    fi
    echo "  flatten markdown (split grammar)"
fi
clone solidity     https://github.com/JoranHonig/tree-sitter-solidity
clone proto        https://github.com/coder3101/tree-sitter-proto
# sql does not commit the generated parser on its default branch;
# the gh-pages branch carries src/parser.c.
clone sql          https://github.com/DerekStride/tree-sitter-sql gh-pages
clone make         https://github.com/alemuller/tree-sitter-make
clone nix          https://github.com/nix-community/tree-sitter-nix
clone scss         https://github.com/serenadeai/tree-sitter-scss
clone jinja2       https://github.com/dbt-labs/tree-sitter-jinja2

# System/config files
clone ini          https://github.com/justinmk/tree-sitter-ini
clone ssh_config   https://github.com/tree-sitter-grammars/tree-sitter-ssh-config
clone gitcommit    https://github.com/the-mikedavis/tree-sitter-git-commit
clone gitignore    https://github.com/shunsambongi/tree-sitter-gitignore
clone diff         https://github.com/the-mikedavis/tree-sitter-diff
clone regex        https://github.com/tree-sitter/tree-sitter-regex

echo "Done. $(ls -d "$VENDOR_DIR/grammars"/*/ | wc -l) grammars fetched."

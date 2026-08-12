#!/usr/bin/env bash

# A missing repository must fail, not prompt for credentials in CI.
export GIT_TERMINAL_PROMPT=0
set -euo pipefail

VENDOR_DIR="$(cd "$(dirname "$0")" && pwd)/vendor"
mkdir -p "$VENDOR_DIR/grammars"

clone() {
    # Split into separate `local` statements: bash evaluates all RHS of a
    # multi-var `local` before any assignment, so `local a=$1 b=$VENDOR/$a`
    # trips `set -u` with "a: unbound variable".
    local name="$1"
    local url="$2"
    local dir="$VENDOR_DIR/grammars/$name"
    if [ -d "$dir" ]; then
        echo "  skip $name (exists)"
        return
    fi
    echo "  fetch $name"
    git clone --depth 1 --quiet "$url" "$dir"
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
clone swift        https://github.com/alex-pinkus/tree-sitter-swift
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
clone solidity     https://github.com/JoranHonig/tree-sitter-solidity
clone proto        https://github.com/coder3101/tree-sitter-proto
clone sql          https://github.com/DerekStride/tree-sitter-sql
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

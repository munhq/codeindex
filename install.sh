#!/usr/bin/env bash
set -euo pipefail

BINARY="codeindex"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
# Claude Code reads skills from its config directory, and that is not always
# ~/.claude: CLAUDE_CONFIG_DIR moves it, and this machine runs several accounts
# whose skills directories are separate. A fixed $HOME/.claude/skills installed
# the skill where the running account could not see it, so nothing ever routed
# an agent to this server — the exact failure the skill exists to prevent.
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="munhq/codeindex"

mkdir -p "$INSTALL_DIR"

DEST="$INSTALL_DIR/$BINARY"

MARKER=".codeindex-managed"

# Every Claude home, not only the active one.
#
# Claude Code reads skills from its config directory, and CLAUDE_CONFIG_DIR
# moves that. A machine can hold ~/.claude plus siblings such as ~/.claude-work,
# each with its own skills directory, and installing into one of them looks like
# a success in every account that cannot see the skill — the exact failure the
# skill exists to prevent. Some siblings symlink ~/.claude/skills, so resolve
# each path and drop duplicates rather than copying over the same directory
# several times. An explicit SKILL_DIR overrides all of this.
resolve_dir() {
    if [ -d "$1" ]; then (cd "$1" && pwd -P); else
        parent="$(dirname "$1")"
        [ -d "$parent" ] && printf '%s/%s\n' "$(cd "$parent" && pwd -P)" "$(basename "$1")"
    fi
}

skill_dirs() {
    if [ -n "${SKILL_DIR:-}" ]; then
        resolve_dir "$SKILL_DIR"
        return
    fi
    {
        [ -n "${CLAUDE_CONFIG_DIR:-}" ] && resolve_dir "$CLAUDE_CONFIG_DIR/skills"
        for home in "$HOME"/.claude "$HOME"/.claude-*; do
            # A name glob alone is wrong: ~/.claude-mem, ~/.claude-desktop and
            # ~/.claude-account-backups match it and are not Claude Code homes.
            # Installing there writes files nothing will ever read. Every real
            # home holds .claude.json, so require it.
            [ -f "$home/.claude.json" ] && resolve_dir "$home/skills"
        done
    } | awk 'NF && !seen[$0]++'
}

# Install one skill directory, and never clobber a skill this script did not
# write. Drop-in skills have no native versioning, so each installed directory
# carries a marker naming the version that put it there; a directory without one
# belongs to the user.
install_skill() {
    src="$1" dest_root="$2"
    name="$(basename "$src")"
    target="$dest_root/$name"
    if [ -e "$target" ] && [ ! -f "$target/$MARKER" ]; then
        # No marker, so this directory predates the marker or belongs to the
        # user. Identical content means an earlier run of this script wrote it,
        # and adopting it is a no-op that only adds the marker. Different
        # content is the user's, and overwriting it would be data loss.
        declared="$(sed -n 's/^name:[[:space:]]*//p' "$target/SKILL.md" 2>/dev/null | head -1)"
        if diff -r -q "$src" "$target" >/dev/null 2>&1; then
            echo "adopting existing identical skill at $target" >&2
        elif [ "$declared" = "$name" ]; then
            # Same content is only the unchanged case. An older version of this
            # skill shipped before markers existed and differs by exactly the
            # edits since — refusing it would strand every machine on the copy
            # it happened to install first. A SKILL.md whose frontmatter names
            # this skill is ours; anything else is left alone.
            echo "replacing an older $name skill at $target" >&2
        else
            echo "warning: $target exists, differs from the bundled skill, and" \
                 "carries no marker; left alone" >&2
            return
        fi
    fi
    mkdir -p "$dest_root"
    rm -rf "${target:?}"
    cp -R "$src" "$target"
    printf '%s %s\n' "codeindex" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$target/$MARKER"
    echo "installed skill -> $target"
}
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BINARIES=("distil-mcp:mcp" "distil-bench:bench")

mkdir -p "$INSTALL_DIR"

# Install file $1 as $INSTALL_DIR/$2 atomically. distil-mcp is a long-lived
# server, so a client can hold the target mapped while this runs. Writing it in
# place can SIGBUS that process when it faults in a page of a half-written file.
# Stage on the same filesystem and rename() over the target: the running
# instance keeps the old inode until it exits.
atomic_install() {
    local src="$1" dest="$INSTALL_DIR/$2" tmp
    tmp="$(mktemp "$dest.XXXXXX")"
    cat "$src" > "$tmp"
    chmod 0755 "$tmp"
    mv -f "$tmp" "$dest"
}

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
    targets="$(skill_dirs)"
    if [ -z "$targets" ]; then
        echo "Warning: no Claude skills directory found; skills not installed" >&2
    else
        for dest in $targets; do
            for skill in "$SRC_DIR"/plugin/skills/*/; do
                install_skill "${skill%/}" "$dest"
            done
        done
    fi
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

#!/bin/sh
# zig build on a runner of desk, with the Zig caches on the persistent folder of the runner (munhq/codeindex#10).
#   ./scripts/ci.sh <zig build arguments>
# A Zig cache is keyed by the content of its inputs, so a run on a runner that built the same grammars before takes
# them from the cache, and a run of the same tree is 0 s. The folder of the cache is DESK_RUNNER_CARGO_CACHE of the
# runner (a claim that outlives the pod). A machine with no such folder builds with the default caches.
set -eu

zig=/opt/zig-0.16/zig
if [ -z "${DESK_RUNNER_CARGO_CACHE:-}" ]; then
    exec "$zig" build "$@"
fi

root="$DESK_RUNNER_CARGO_CACHE/zig"
mkdir -p "$root"
export ZIG_GLOBAL_CACHE_DIR="$root/global"

# A Zig cache never shrinks. Above the limit, the run that holds the exclusive lock empties it; a build that runs
# holds the shared lock, so the cache is never emptied under a build.
limit_mb=6144
if command -v flock >/dev/null 2>&1; then
    exec 9>"$root/lock"
    if flock -n -x 9; then
        used=$(du -sm "$root" | cut -f1)
        if [ "$used" -gt "$limit_mb" ]; then
            echo "zig cache: $used MB is above $limit_mb MB, emptying it"
            rm -rf "$root/local" "$root/global"
        fi
        flock -u 9
    fi
    flock -s 9
fi

# exec keeps the descriptor of the lock open, so the shared lock lasts as long as the build.
exec "$zig" build "$@" --cache-dir "$root/local"

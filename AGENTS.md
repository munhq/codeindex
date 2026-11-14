# AGENTS.md

Notes for an agent that works in this repository.

## What the code is

`codeindex` gives an index of code to AI agents. The server is Zig (`zig/`). The npm package and
the plugin of the AI clients are JavaScript (`npm/`, `plugin/`).

## The desk server holds the code

The repository lives on the desk server (`"store": "server"` in `.desk/config.json`). Do not use
`git`, `jj` or `gh` for a change here.

1. Run `desk sync` before a change. Merge each `.desk-main` copy into its file, then delete the copy.
2. Change the files in the work folder.
3. Run `desk change --intent <issue>` with a message of the shape `<type>(<scope>): <summary>`.
4. Run `desk land`. The server merges the change onto `main` and runs the checks of the repository.
   Do not push to GitHub, and do not open a pull request.
5. `desk runs list` names every check with its run id and its status. `desk runs view <id>` shows one
   check.

## A test, a lint and a build run on the runners, never on the PC of the owner

The PC of the owner is not a build machine. Do not run a full test suite, a lint or a release build
there. The runners of desk do that work.

1. Use `desk try` when munhq/desk#234 lands. It runs the checks of the change on the runners.
2. Until then, run `desk pr create` to propose the last change. The server runs the checks of the
   change on the runners, on the tree of the change, and it does not merge the change.
3. A landing runs the checks with `"stage": "land"` in `.desk/config.json` on `main`. A failed check
   refuses the landing of the next change, so run `desk runs list` after a landing.

The checks of the Zig code:

| Check | Command |
| --- | --- |
| `zig:fmt` | `/opt/zig-0.16/zig fmt --check src/ main.zig build.zig tests_main.zig` |
| `root` | `sh .desk/workflows/buck-base/scripts/buck-run.sh build //:check`: the format check, the build and the tests as cached Buck2 actions of the workflow buck-zig (`BUCK`) |
| `zig:e2e` | `zig build`, then `zig build e2e` — not a check of desk yet: see #9 |

Read two points before you copy a command into a new check:

- Use `/opt/zig-0.16/zig`. The runner also holds `/opt/zig`, which is 0.13.0, and the code needs
  the version of `minimum_zig_version` in `zig/build.zig.zon`.
- Run the binary of the test yourself (`zig-out/bin/test`). The step `zig build test` corrupts the
  IPC of the build runner through the `printf` calls of the C sources of tree-sitter.

`zig/vendor/` is not in the tree. `zig/fetch-vendor.sh` downloads the pinned snapshot and checks
its SHA-256. The `setup` of each Zig check runs `./fetch-vendor.sh`, because a runner runs `setup`
in the `cwd` of the check, which is `zig`.

`.github/workflows/ci.yml` holds the same commands, for the CI of GitHub. Read it when you change a
check, so that both stay equal.

## Keep every check under one minute

The goal of the owner (munhq/desk#145): each check ends in under one minute, with the cluster as it is. These rules
come from the measurements of munhq/codeindex#10. They hold for every repository.

1. Measure before you change. Add a temporary check to `.desk/config.json` that prints the seconds of each step, run
   it with `desk try --only <check>`, and delete it before the landing. A guess cost three runs here.
2. Run one `desk try` at a time. The cluster has 40 cores that production shares. A second run at once makes both
   slower and proves nothing.
3. Keep no build cache on a runner. The vendor snapshot, the grammar archives, the build and the tests are Buck2 actions
   (`BUCK`, the workflow buck-zig of munhq/desk), so NativeLink serves their results to every runner and every
   `desk try`: a run of an unchanged tree is a hit in the cache (3 s), and a runner that never built the project is as fast
   as a warm one. The grammars are static archives (`zig build grammars` installs them, and `-Dprebuilt=<folder>` links
   them), because Zig keys its own build cache on the absolute path of the sources.
4. A change of a Zig source builds the executable and the test binary again (about 1 min each, in parallel): Zig
   compiles a module as one unit.
5. Find the slow step by a filter, not by a guess. The test filter of the test runner (`zig test --test-filter`), or one run for each
   group of tests, found the cause here in four runs: 60 s of the 150 s were the link of 47 parsers built as Debug C
   with debug information.
6. Build vendored code (the grammars) as ReleaseFast without debug information, also in a Debug build. It is not code
   that you debug, and it made the unit tests 9 times slower (36 s against 4 s).
7. Give each check its own command, so two checks run on two runners and share the cache. Do not put a build and a
   test in one command when two checks can run apart.
8. A check that lands must keep its test count. `zig:test` ends with `All 232 tests passed.`; read that line after
   a change of the build.

## Issues

A question for the owner goes into the section "Questions for the owner" of the issue:
`desk issue questions --issue <n> --body-file <f>`, then `desk questions review --issue <n>`. Do not
ask the owner in chat.

## What is still over one minute

A runner that has never built the grammars pays about 92 s for `zig:test` (measured on 2026-11-13: fetch 2 s, build 92 s, run 3 s on `desk-runner-3`, with 337 MB in the cache after it). The next run on the same runner takes 1 s to 5 s. The pool has 4 runners, so a cold run happens once on each runner after its pod restarts. The way to remove it is to bake the Zig cache of the grammars into the runner image (munhq/codeindex#10).

## Keep the pipeline inside its time budget

The goal of the owner (munhq/desk#145, #243): every check of this repository ends in under 60 s, and more work must not make it slower. A change that adds time to a check is not done.

1. Before you land, run `desk try` and read the time of each check. If your change makes a check slower, make the test or the build cheaper, or split it, before you land.
2. Run `desk runs budget --check` to see which checks are over 60 s by the median of the last 5 landings.
3. Do not raise a budget to land a change. A higher budget is a decision of the owner.
4. While a check is over its budget and the server setting `budget.mode` is `refuse`, only a change of type `perf`, `build`, `ci`, `test` or `revert` lands.
5. Put the cache first: keep a cache key to the files that a step reads, and keep a build cache on the persistent folder of the runner. The rules for a fast check are in `docs/runs.md` of munhq/desk.

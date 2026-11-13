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
| `zig:build` | `/opt/zig-0.16/zig build` |
| `zig:test` | `/opt/zig-0.16/zig build test-bin` then `./zig-out/bin/test` |
| `zig:e2e` | `/opt/zig-0.16/zig build` then `/opt/zig-0.16/zig build e2e` — not a check of desk yet: see #9 |

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

## Issues

A question for the owner goes into the section "Questions for the owner" of the issue:
`desk issue questions --issue <n> --body-file <f>`, then `desk questions review --issue <n>`. Do not
ask the owner in chat.

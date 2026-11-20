# codeindex as Buck2 targets (munhq/desk#244): the rules are the workflow buck-zig, mounted by `checkouts` of .desk/config.json.
# The vendor snapshot, the cache of the grammars, the build, the tests and the format check are cached actions on NativeLink.
load("@desk_node//:defs.bzl", "js_syntax")

load("@desk_zig//:defs.bzl", "zig_project")

zig_project(
    root = "zig",
    srcs = glob(["zig/**"], exclude = ["zig/vendor/**", "zig/zig-out/**", "zig/.zig-cache/**"]),
    vendor_script = "bash ./fetch-vendor.sh",
    vendor_srcs = ["zig/fetch-vendor.sh"],
    cache_step = "grammars",
    cache_srcs = ["zig/build.zig", "zig/build.zig.zon"],
    fmt_args = "src/ main.zig build.zig tests_main.zig",
    # The end-to-end tests drive the built binary over MCP stdio, the way a client does.
    test_step = "test-bin install",
    test_run = "./zig-out/bin/test && python3 test/e2e.py zig-out/bin/codeindex",
)

# `node --check` of the JavaScript files of npm/, as one cached action (munhq/desk#244).
js_syntax(root = "npm", name = "npm-syntax")

# The versions of the packages agree (check-versions.py), as one cached action (munhq/desk#244).
genrule(
    name = "versions",
    srcs = ["npm/package.json", "plugin/.claude-plugin/plugin.json", "server.json", ".cursor-plugin/marketplace.json", "zig/build.zig", "zig/build.zig.zon", "check-versions.py"],
    out = "versions.txt",
    cmd = "cd $SRCDIR && python3 check-versions.py && echo ok > $OUT",
)

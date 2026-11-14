# codeindex as Buck2 targets (munhq/desk#244): the rules are the workflow buck-zig, mounted by `checkouts` of .desk/config.json.
# The vendor snapshot, the cache of the grammars, the build, the tests and the format check are cached actions on NativeLink.
load("@desk_zig//:defs.bzl", "zig_project")

zig_project(
    root = "zig",
    srcs = glob(["zig/**"], exclude = ["zig/vendor/**", "zig/zig-out/**", "zig/.zig-cache/**"]),
    vendor_script = "bash ./fetch-vendor.sh",
    vendor_srcs = ["zig/fetch-vendor.sh"],
    cache_step = "grammars",
    cache_srcs = ["zig/build.zig", "zig/build.zig.zon"],
    fmt_args = "src/ main.zig build.zig tests_main.zig",
)

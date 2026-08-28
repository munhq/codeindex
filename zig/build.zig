const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const flags = &.{ "-std=c11", "-D_POSIX_C_SOURCE=200809L", "-D_GNU_SOURCE" };

    // The version the binary reports. It used to be a string literal in
    // main.zig, so cutting a tag without editing that line shipped a binary
    // naming a different version than the tag: release v0.2.0 carries a binary
    // that answers `codeindex 0.1.0`. The release workflow now passes the tag
    // here and then asserts the built binary agrees, so the two cannot drift.
    // Strip at link time rather than with a host `strip` afterwards. The release
    // ran the runner's binutils, which cannot strip an aarch64 ELF from an x86
    // machine, and the `|| true` swallowed the failure: aarch64-linux shipped
    // with debug info at 63MB against 53MB for x86_64. `zig objcopy
    // --strip-all` is unimplemented in 0.16, so the linker does it — which works
    // for every target from one runner, and needs no extra package.
    const strip = b.option(bool, "strip", "Strip the binary (default: on unless Debug)") orelse
        (optimize != .Debug);

    const version = b.option([]const u8, "version", "Version the binary reports (release CI passes the tag)") orelse DEFAULT_VERSION;
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);

    // ── Tree-sitter library ──────────────────────────────────────────
    // Zig 0.16: C sources, include paths and lib linkage live on the Module,
    // and libc/libc++ linkage are Module create-options.
    const ts_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    ts_mod.addCSourceFile(.{
        .file = b.path("vendor/tree-sitter/lib/src/lib.c"),
        .flags = flags,
    });
    ts_mod.addIncludePath(b.path("vendor/tree-sitter/lib/include"));
    ts_mod.addIncludePath(b.path("vendor/tree-sitter/lib/src"));
    const ts_lib = b.addLibrary(.{
        .name = "tree-sitter",
        .root_module = ts_mod,
    });

    // ── Grammar sources ──────────────────────────────────────────────
    const grammars = &[_]struct { name: []const u8, path: []const u8 }{
        // Core languages
        .{ .name = "rust", .path = "vendor/grammars/rust/src" },
        .{ .name = "python", .path = "vendor/grammars/python/src" },
        .{ .name = "go", .path = "vendor/grammars/go/src" },
        .{ .name = "typescript", .path = "vendor/grammars/typescript/typescript/src" },
        .{ .name = "tsx", .path = "vendor/grammars/typescript/tsx/src" },
        .{ .name = "zig", .path = "vendor/grammars/zig/src" },
        .{ .name = "c", .path = "vendor/grammars/c/src" },
        .{ .name = "cpp", .path = "vendor/grammars/cpp/src" },
        .{ .name = "java", .path = "vendor/grammars/java/src" },
        .{ .name = "ruby", .path = "vendor/grammars/ruby/src" },
        .{ .name = "bash", .path = "vendor/grammars/bash/src" },
        .{ .name = "c_sharp", .path = "vendor/grammars/c_sharp/src" },
        .{ .name = "kotlin", .path = "vendor/grammars/kotlin/src" },
        .{ .name = "lua", .path = "vendor/grammars/lua/src" },
        .{ .name = "scala", .path = "vendor/grammars/scala/src" },
        .{ .name = "elixir", .path = "vendor/grammars/elixir/src" },
        .{ .name = "r", .path = "vendor/grammars/r/src" },
        // Config/data/infra
        .{ .name = "toml", .path = "vendor/grammars/toml/src" },
        .{ .name = "json", .path = "vendor/grammars/json/src" },
        .{ .name = "yaml", .path = "vendor/grammars/yaml/src" },
        .{ .name = "css", .path = "vendor/grammars/css/src" },
        .{ .name = "html", .path = "vendor/grammars/html/src" },
        .{ .name = "hcl", .path = "vendor/grammars/hcl/src" },
        .{ .name = "dockerfile", .path = "vendor/grammars/dockerfile/src" },
        .{ .name = "haskell", .path = "vendor/grammars/haskell/src" },
        .{ .name = "markdown", .path = "vendor/grammars/markdown/src" },
        .{ .name = "sql", .path = "vendor/grammars/sql/src" },
        .{ .name = "make", .path = "vendor/grammars/make/src" },
        .{ .name = "nix", .path = "vendor/grammars/nix/src" },
        .{ .name = "scss", .path = "vendor/grammars/scss/src" },
        .{ .name = "swift", .path = "vendor/grammars/swift/src" },
        .{ .name = "dart", .path = "vendor/grammars/dart/src" },
        .{ .name = "jinja2", .path = "vendor/grammars/jinja2/src" },
        // System/config files
        .{ .name = "ini", .path = "vendor/grammars/ini/src" },
        .{ .name = "ssh_config", .path = "vendor/grammars/ssh_config/src" },
        .{ .name = "gitcommit", .path = "vendor/grammars/gitcommit/src" },
        .{ .name = "gitignore", .path = "vendor/grammars/gitignore/src" },
        .{ .name = "diff", .path = "vendor/grammars/diff/src" },
        .{ .name = "regex", .path = "vendor/grammars/regex/src" },
        .{ .name = "solidity", .path = "vendor/grammars/solidity/src" },
        .{ .name = "proto", .path = "vendor/grammars/proto/src" },
    };

    const grammar_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    grammar_mod.addIncludePath(b.path("vendor/tree-sitter/lib/include"));
    grammar_mod.addIncludePath(b.path("vendor/tree-sitter/lib/src"));
    const grammar_lib = b.addLibrary(.{
        .name = "grammars",
        .root_module = grammar_mod,
    });

    for (grammars) |g| {
        const parser_path = b.path(b.fmt("{s}/parser.c", .{g.path}));
        grammar_mod.addCSourceFile(.{
            .file = parser_path,
            .flags = flags,
        });

        // Scanners
        const sc_c = b.fmt("{s}/scanner.c", .{g.path});
        const sc_cc = b.fmt("{s}/scanner.cc", .{g.path});

        if (b.build_root.handle.access(b.graph.io, sc_c, .{})) |_| {
            grammar_mod.addCSourceFile(.{
                .file = b.path(sc_c),
                .flags = flags,
            });
        } else |_| {}

        if (b.build_root.handle.access(b.graph.io, sc_cc, .{})) |_| {
            grammar_mod.addCSourceFile(.{
                .file = b.path(sc_cc),
                .flags = &.{ "-std=c++11", "-D_POSIX_C_SOURCE=200809L", "-D_GNU_SOURCE" },
            });
        } else |_| {}
    }

    // ── Main executable ──────────────────────────────────────────────
    const mod = b.addModule("codeindex", .{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .strip = strip,
    });
    mod.addIncludePath(b.path("vendor/tree-sitter/lib/include"));
    mod.linkLibrary(ts_lib);
    mod.linkLibrary(grammar_lib);
    mod.addOptions("build_options", build_options);

    const exe = b.addExecutable(.{
        .name = "codeindex",
        .root_module = mod,
    });

    // Atomic install. The default installArtifact copies onto the destination
    // in place (open O_TRUNC + write). codeindex is a long-lived server that
    // runs straight from zig-out/bin, and overwriting a mapped executable in
    // place can SIGBUS every running instance when it faults in a page from the
    // now-truncated file. Stage to a temp on the same filesystem and rename()
    // over the target instead — atomic, and running processes keep the old inode
    // until they exit (or hot-reload). Replaces b.installArtifact(exe).
    const install_bin = b.addSystemCommand(&.{
        "sh",                "-c",
        \\set -eu
        \\src="$1"; dst="$2"
        \\mkdir -p "$(dirname "$dst")"
        \\tmp="$(mktemp "$dst.XXXXXX")"
        \\cat "$src" > "$tmp"
        \\chmod 0755 "$tmp"
        \\mv -f "$tmp" "$dst"
        ,
        "codeindex-install",
    });
    install_bin.addFileArg(exe.getEmittedBin()); // $1 = freshly built binary
    install_bin.addArg(b.getInstallPath(.bin, "codeindex")); // $2 = zig-out/bin/codeindex
    b.getInstallStep().dependOn(&install_bin.step);

    // ── Tests ────────────────────────────────────────────────────────
    const test_mod = b.addModule("tests", .{
        .root_source_file = b.path("tests_main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    test_mod.addIncludePath(b.path("vendor/tree-sitter/lib/include"));
    test_mod.linkLibrary(ts_lib);
    test_mod.linkLibrary(grammar_lib);
    // The tests assert on the version the build injects, so they need the same
    // options module the executable gets. Without it a test that checks the
    // reported version cannot be written at all, which is why three separate
    // hardcoded versions survived.
    test_mod.addOptions("build_options", build_options);

    const tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // The unit tests also install as a binary. `zig build test` runs them through
    // the build runner's IPC protocol on stdout, which the linked tree-sitter C
    // sources corrupt via their debug printf paths. Building the binary and
    // executing it directly runs the same tests without that protocol.
    const install_tests = b.addInstallArtifact(tests, .{});
    const test_bin_step = b.step("test-bin", "Build the unit-test binary into zig-out/bin");
    test_bin_step.dependOn(&install_tests.step);

    // ── End-to-end MCP stdio test ────────────────────────────────────
    // Spawns the built binary and drives the real JSON-RPC protocol.
    const e2e = b.addSystemCommand(&.{ "python3", "test/e2e.py" });
    e2e.addArtifactArg(exe); // pass the freshly built binary path
    const e2e_step = b.step("e2e", "Run end-to-end MCP stdio tests");
    e2e_step.dependOn(&e2e.step);
}

/// What a local build reports when no tag is passed. Keep it at the version
/// being worked towards, so a developer build is never mistaken for a release.
const DEFAULT_VERSION = "0.3.5";

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const flags = &.{ "-std=c11", "-D_POSIX_C_SOURCE=200809L", "-D_GNU_SOURCE" };

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
    });
    mod.addIncludePath(b.path("vendor/tree-sitter/lib/include"));
    mod.linkLibrary(ts_lib);
    mod.linkLibrary(grammar_lib);

    const exe = b.addExecutable(.{
        .name = "codeindex",
        .root_module = mod,
    });
    b.installArtifact(exe);

    // ── Tests ────────────────────────────────────────────────────────
    const test_mod = b.addModule("tests", .{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    test_mod.addIncludePath(b.path("vendor/tree-sitter/lib/include"));
    test_mod.linkLibrary(ts_lib);
    test_mod.linkLibrary(grammar_lib);

    const tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}

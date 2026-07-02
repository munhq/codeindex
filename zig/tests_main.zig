//! Test aggregator root. Lives at the project root (not under src/) so that
//! the test module's package root is the same as the main executable's. This
//! lets parser tests reach the vendored grammar `tags.scm` files embedded via
//! `@embedFile("../../vendor/...")`, which would escape a `src/`-rooted module.
comptime {
    _ = @import("src/tests.zig");
}

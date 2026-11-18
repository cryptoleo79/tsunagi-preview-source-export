// Test shim for src/archive/ modules.
// Registered in build.zig to run inline tests via `zig build test`.
comptime {
    _ = @import("archive/coverage.zig");
    _ = @import("archive/fragment_coverage.zig");
}

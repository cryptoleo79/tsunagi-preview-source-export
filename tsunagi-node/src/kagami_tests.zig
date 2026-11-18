// Test shim for src/kagami/ modules.
// Registered in build.zig to run inline tests via `zig build test`.
comptime {
    _ = @import("kagami/snapshot.zig");
}

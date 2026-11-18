// Test shim for src/guardian/ modules.
// Registered in build.zig to run inline tests via `zig build test`.
comptime {
    _ = @import("guardian/tate.zig");
    _ = @import("guardian/kura_stabilizer.zig");
}

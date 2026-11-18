// Test shim: imports propagation_server to run its inline tests.
// Needed because propagation_server.zig lives under src/net/ and uses
// relative imports (../protocols/...) that require src/ as module root.
test {
    _ = @import("net/propagation_server.zig");
    _ = @import("producer/forge_stats.zig");
}

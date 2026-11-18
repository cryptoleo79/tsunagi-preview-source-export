// Test shim for src/ledger/ modules.
// Registered in build.zig to run inline tests via `zig build test`.
//
// Uses comptime reference to compile the module and run its tests
// without triggering transitive test inclusion from dependencies.
comptime {
    _ = @import("ledger/tx_decode.zig");
    _ = @import("ledger/utxo_extract.zig");
    _ = @import("ledger/block_apply.zig");
    _ = @import("ledger/block_stream.zig");
    _ = @import("ledger/ledger_pipeline.zig");
    _ = @import("ledger/pipeline_proof_test.zig");
    _ = @import("ledger/replay_harness.zig");
}

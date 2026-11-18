// Test shim for src/net/ledger/tx_decoder and tx_summary_history modules.
// Registered in build.zig to run inline tests via `zig build test`.
//
// These modules import ../cbor/term.zig (cross-directory), so the test
// root must be at src/ level where net/cbor/ is reachable.
comptime {
    _ = @import("net/ledger/tx_decoder.zig");
    _ = @import("net/ledger/tx_summary_history.zig");
    _ = @import("net/ledger/block_decode_store.zig");
    _ = @import("net/ledger/eval_external.zig");
    _ = @import("net/ledger/forge_gate.zig");
    _ = @import("net/ledger/trust_signal.zig");
    _ = @import("net/ledger/belief_state.zig");
    _ = @import("net/ledger/trust_aggregate.zig");
    _ = @import("net/ledger/trust_score.zig");
    _ = @import("net/ledger/decision_metrics.zig");
    _ = @import("net/ledger/decision_advisory.zig");
    _ = @import("net/ledger/policy_preview.zig");
    _ = @import("net/ledger/policy_impact.zig");
    _ = @import("net/ledger/policy_apply.zig");
    _ = @import("net/ledger/decision_state.zig");
}

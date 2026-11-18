// Ledger engine test shim: UTxO, chain index, node state, data access, mempool.
comptime {
    _ = @import("net/ledger/utxo.zig");
    _ = @import("net/ledger/utxo_store.zig");
    _ = @import("net/ledger/chain_index.zig");
    _ = @import("net/ledger/node_state.zig");
    _ = @import("net/ledger/data_access.zig");
    _ = @import("net/ledger/mempool.zig");
}

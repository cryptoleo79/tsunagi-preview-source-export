pub const Protocol = enum {
    chainsync,
    blockfetch,
    txsubmission,
    keepalive,
};

pub const Message = union(Protocol) {
    chainsync: ChainSyncMsg,
    blockfetch: BlockFetchMsg,
    txsubmission: TxSubmissionMsg,
    keepalive: KeepAliveMsg,
};

pub const ChainSyncMsg = enum {
    find_intersect,
    request_next,
    rollback,
    rollforward,
};

pub const BlockFetchMsg = enum {
    request_range,
    start_batch,
    block,
    batch_done,
};

pub const TxSubmissionMsg = enum {
    msg_init,
    msg_request_tx_ids,
    msg_reply_tx_ids,
    msg_request_txs,
    msg_reply_txs,
    msg_done,
};

pub const KeepAliveMsg = enum {
    msg_keepalive,
    msg_keepalive_response,
    msg_done,
};

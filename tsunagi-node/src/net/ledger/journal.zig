const std = @import("std");
const compat = @import("compat");

fn openAppend(path: []const u8) !compat.fs.File {
    const dir = std.fs.path.dirname(path) orelse return error.InvalidPath;
    try compat.fs.cwd().makePath(dir);

    var file = compat.fs.openFileAbsolute(path, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => try compat.fs.createFileAbsolute(
            path,
            .{ .read = true, .truncate = false },
        ),
        else => return err,
    };
    try file.seekFromEnd(0);
    return file;
}

pub fn appendRollForward(
    path: []const u8,
    ts: i64,
    slot: u64,
    block_no: u64,
    tip_hash_hex: []const u8,
    header_hash_hex: []const u8,
    tx_count: u64,
    utxo_count: u64,
    utxo_consumed: u32,
    utxo_produced: u32,
) !void {
    var file = try openAppend(path);
    defer file.close();

    const delta: i64 = @as(i64, utxo_produced) - @as(i64, utxo_consumed);
    const writer = file.deprecatedWriter();
    try writer.print(
        "{{\"type\":\"roll_forward\",\"ts\":{d},\"slot\":{d},\"block_no\":{d},\"tip_hash_hex\":\"{s}\",\"header_hash_hex\":\"{s}\",\"tx_count\":{d},\"utxo_count\":{d},\"utxo_consumed\":{d},\"utxo_produced\":{d},\"utxo_delta\":{d}}}\n",
        .{ ts, slot, block_no, tip_hash_hex, header_hash_hex, tx_count, utxo_count, utxo_consumed, utxo_produced, delta },
    );
}

pub fn appendRollBackward(
    path: []const u8,
    ts: i64,
    slot: u64,
    block_no: u64,
    tip_hash_hex: []const u8,
) !void {
    var file = try openAppend(path);
    defer file.close();

    const writer = file.deprecatedWriter();
    try writer.print(
        "{{\"type\":\"roll_backward\",\"ts\":{d},\"slot\":{d},\"block_no\":{d},\"tip_hash_hex\":\"{s}\"}}\n",
        .{ ts, slot, block_no, tip_hash_hex },
    );
}

pub fn appendTxDecode(
    path: []const u8,
    slot: u64,
    block_no: u64,
    block_hash_hex: []const u8,
    tx_result: @import("tx_decoder.zig").BlockTxResult,
) !void {
    var file = try openAppend(path);
    defer file.close();
    const w = file.deprecatedWriter();
    try w.print(
        "{{\"type\":\"tx_decode\",\"slot\":{d},\"block_no\":{d},\"block_hash\":\"{s}\",\"tx_count\":{d},\"truncated\":{},\"block_total_fee_lovelace\":{d},\"block_total_output_lovelace\":{d},\"block_cert_txs\":{d},\"block_script_txs\":{d},\"block_collateral_txs\":{d},\"txs\":[",
        .{
            slot, block_no, block_hash_hex, tx_result.count, tx_result.truncated,
            tx_result.block_total_fee_lovelace, tx_result.block_total_output_lovelace,
            tx_result.block_cert_tx_count, tx_result.block_script_tx_count, tx_result.block_collateral_tx_count,
        },
    );
    var i: u32 = 0;
    while (i < tx_result.count) : (i += 1) {
        if (i > 0) try w.writeByte(',');
        const tx = tx_result.summaries[i];
        if (tx.fee) |f| {
            try w.print(
                "{{\"idx\":{d},\"in\":{d},\"out\":{d},\"fee\":{d},\"out_ada\":{d},\"meta\":{},\"cert\":{},\"script\":{},\"coll\":{},\"wdrl\":{d},\"wdrl_ada\":{d}}}",
                .{ tx.index, tx.inputs, tx.outputs, f, tx.output_lovelace, tx.has_metadata, tx.has_certificates, tx.has_scripts, tx.has_collateral, tx.withdrawal_count, tx.withdrawal_lovelace },
            );
        } else {
            try w.print(
                "{{\"idx\":{d},\"in\":{d},\"out\":{d},\"fee\":null,\"out_ada\":{d},\"meta\":{},\"cert\":{},\"script\":{},\"coll\":{},\"wdrl\":{d},\"wdrl_ada\":{d}}}",
                .{ tx.index, tx.inputs, tx.outputs, tx.output_lovelace, tx.has_metadata, tx.has_certificates, tx.has_scripts, tx.has_collateral, tx.withdrawal_count, tx.withdrawal_lovelace },
            );
        }
    }
    try w.writeAll("]}\n");
}

pub fn appendMempoolTx(
    path: []const u8,
    summary: @import("../mempool/mempool_decoder.zig").MempoolTxSummary,
) !void {
    var file = try openAppend(path);
    defer file.close();
    const w = file.deprecatedWriter();
    if (summary.fee) |f| {
        try w.print(
            "{{\"type\":\"mempool_tx\",\"txid\":\"{s}\",\"in\":{d},\"out\":{d},\"fee\":{d},\"meta\":{},\"size\":{d},\"ts\":{d}}}\n",
            .{ summary.txid_hex, summary.inputs, summary.outputs, f, summary.has_metadata, summary.size_bytes, summary.received_unix },
        );
    } else {
        try w.print(
            "{{\"type\":\"mempool_tx\",\"txid\":\"{s}\",\"in\":{d},\"out\":{d},\"fee\":null,\"meta\":{},\"size\":{d},\"ts\":{d}}}\n",
            .{ summary.txid_hex, summary.inputs, summary.outputs, summary.has_metadata, summary.size_bytes, summary.received_unix },
        );
    }
}

pub fn appendConfirmation(
    path: []const u8,
    c: @import("../mempool/confirmation_tracker.zig").ConfirmedTx,
) !void {
    var file = try openAppend(path);
    defer file.close();
    const w = file.deprecatedWriter();
    if (c.fee) |f| {
        try w.print(
            "{{\"type\":\"confirmed_tx\",\"txid\":\"{s}\",\"received\":{d},\"confirmed\":{d},\"seconds\":{d},\"block\":{d},\"slot\":{d},\"fee\":{d}}}\n",
            .{ c.txid_hex, c.received_unix, c.confirmed_unix, c.confirmation_seconds, c.block_no, c.slot, f },
        );
    } else {
        try w.print(
            "{{\"type\":\"confirmed_tx\",\"txid\":\"{s}\",\"received\":{d},\"confirmed\":{d},\"seconds\":{d},\"block\":{d},\"slot\":{d},\"fee\":null}}\n",
            .{ c.txid_hex, c.received_unix, c.confirmed_unix, c.confirmation_seconds, c.block_no, c.slot },
        );
    }
}

pub fn appendPropagation(
    path: []const u8,
    p: @import("../mempool/propagation_tracker.zig").PropagationTx,
) !void {
    var file = try openAppend(path);
    defer file.close();
    const w = file.deprecatedWriter();
    var block_obs_buf: [20]u8 = undefined;
    const block_obs_str = if (p.block_observed_unix) |v|
        std.fmt.bufPrint(&block_obs_buf, "{d}", .{v}) catch "null"
    else
        "null";
    var block_buf: [20]u8 = undefined;
    const block_str = if (p.block_no) |v|
        std.fmt.bufPrint(&block_buf, "{d}", .{v}) catch "null"
    else
        "null";
    var slot_buf: [20]u8 = undefined;
    const slot_str = if (p.slot) |v|
        std.fmt.bufPrint(&slot_buf, "{d}", .{v}) catch "null"
    else
        "null";
    var conf_buf: [20]u8 = undefined;
    const conf_str = if (p.confirmed_unix) |v|
        std.fmt.bufPrint(&conf_buf, "{d}", .{v}) catch "null"
    else
        "null";
    var secs_buf: [20]u8 = undefined;
    const secs_str = if (p.confirmation_seconds) |v|
        std.fmt.bufPrint(&secs_buf, "{d}", .{v}) catch "null"
    else
        "null";
    try w.print(
        "{{\"type\":\"propagation_tx\",\"txid\":\"{s}\",\"local_submitted\":{d},\"block_observed\":{s},\"block\":{s},\"slot\":{s},\"confirmed\":{s},\"confirmation_seconds\":{s}}}\n",
        .{ p.txid_hex, p.local_submitted_unix, block_obs_str, block_str, slot_str, conf_str, secs_str },
    );
}

pub fn appendSlotObservation(
    path: []const u8,
    obs: @import("../consensus/slot_observatory.zig").SlotObservation,
) !void {
    var file = try openAppend(path);
    defer file.close();
    const w = file.deprecatedWriter();
    var block_buf: [20]u8 = undefined;
    const block_str = if (obs.block_no) |v|
        std.fmt.bufPrint(&block_buf, "{d}", .{v}) catch "null"
    else
        "null";
    var gap_buf: [20]u8 = undefined;
    const gap_str = if (obs.gap_from_prev_block) |v|
        std.fmt.bufPrint(&gap_buf, "{d}", .{v}) catch "null"
    else
        "null";
    const kind_str = switch (obs.kind) {
        .observed_block => "observed_block",
        .empty_gap => "empty_gap",
        .local_candidate => "local_candidate",
    };
    try w.print(
        "{{\"type\":\"slot_observation\",\"slot\":{d},\"block\":{s},\"observed_unix\":{d},\"kind\":\"{s}\",\"gap_from_prev_block\":{s}}}\n",
        .{ obs.slot, block_str, obs.observed_unix, kind_str, gap_str },
    );
}

pub fn appendPeerEvent(
    path: []const u8,
    ev: @import("../network/peer_observatory.zig").PeerEvent,
    reason: ?[]const u8,
) !void {
    var file = try openAppend(path);
    defer file.close();
    const w = file.deprecatedWriter();
    const peer = ev.peerLabel();
    const event_str = switch (ev.kind) {
        .peer_connect => "peer_connect",
        .peer_disconnect => "peer_disconnect",
        .block_received => "block_received",
    };
    var slot_buf: [20]u8 = undefined;
    const slot_str = if (ev.slot) |v|
        std.fmt.bufPrint(&slot_buf, "{d}", .{v}) catch "null"
    else
        "null";
    var block_buf: [20]u8 = undefined;
    const block_str = if (ev.block_no) |v|
        std.fmt.bufPrint(&block_buf, "{d}", .{v}) catch "null"
    else
        "null";
    var lat_buf: [20]u8 = undefined;
    const lat_str = if (ev.latency_ms) |v|
        std.fmt.bufPrint(&lat_buf, "{d}", .{v}) catch "null"
    else
        "null";
    if (reason) |r| {
        try w.print(
            "{{\"type\":\"peer_event\",\"peer\":\"{s}\",\"event\":\"{s}\",\"slot\":{s},\"block\":{s},\"latency_ms\":{s},\"reason\":\"{s}\",\"ts\":{d}}}\n",
            .{ peer, event_str, slot_str, block_str, lat_str, r, ev.timestamp_unix },
        );
    } else {
        try w.print(
            "{{\"type\":\"peer_event\",\"peer\":\"{s}\",\"event\":\"{s}\",\"slot\":{s},\"block\":{s},\"latency_ms\":{s},\"reason\":null,\"ts\":{d}}}\n",
            .{ peer, event_str, slot_str, block_str, lat_str, ev.timestamp_unix },
        );
    }
}

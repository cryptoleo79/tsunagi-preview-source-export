// Wall-clock per-second producer tick driver.
//
// Rationale: producer.tick() was previously only called from the upstream
// follower on RollForward (~once every 20-50s). VRF leader checks therefore
// only ran on those wakeups, missing ~95% of slots. This thread fires
// producer.tick() once per slot (~1s on preview/preprod/mainnet) so every
// slot is evaluated. Combined with the catchup scan inside executeTick,
// this gives 100% slot coverage even if a tick is briefly delayed.
//
// Reads parent_slot/block/hash from ctx.tip_*_last (kept current by the
// follower). Idempotent: producer.tick() short-circuits when current_slot
// has already been checked.

const std = @import("std");
const compat = @import("compat");
const shutdown = @import("../ops/shutdown.zig");
const producer = @import("producer.zig");
const slot_clock = @import("slot_clock.zig");

const TICK_INTERVAL_MS: u64 = 1000;

pub fn spawnBackground(alloc: std.mem.Allocator, ctx: *producer.ProducerContext) bool {
    _ = alloc;
    const thread = std.Thread.spawn(.{}, runThread, .{ctx}) catch {
        std.debug.print("WALL_TICK_SPAWN: thread spawn failed\n", .{});
        return false;
    };
    thread.detach();
    std.debug.print("WALL_TICK_SPAWN: ready interval_ms={d}\n", .{TICK_INTERVAL_MS});
    return true;
}

fn runThread(ctx: *producer.ProducerContext) void {
    var iter: u64 = 0;
    var fired: u64 = 0;
    while (true) {
        if (shutdown.stopRequested()) return;
        iter += 1;
        // Unconditional heartbeat — proves the thread is alive and the
        // loop is iterating. Throttled to once per ~10s to avoid log spam.
        if (iter == 1 or iter % 10 == 0) {
            std.debug.print("WALL_TICK_HEARTBEAT: ctx_ptr=0x{x} iter={d} fired={d} genesis_ok={} tip_block={d} rx_block={d} last_slot_checked={d}\n", .{
                @intFromPtr(ctx), iter, fired, ctx.genesis_parse_ok,
                ctx.tip_block_last, ctx.rx_block_last, ctx.last_slot_checked,
            });
        }
        // Try to fire a tick. Use the freshest known parent across all
        // sources — primary follower writes ctx.tip_*, peer probes write
        // ctx.rx_*. Either is sufficient. This way tick() runs even when
        // only secondary probes are feeding headers.
        //
        // Snapshot rx_* and tip_* under their respective mutexes for atomic
        // (block_no, slot, hash) reads. The previous unguarded multi-field
        // reads could pick a parent_block from one source and parent_slot/
        // parent_hash from the SAME source but written in different
        // transactions — torn snapshot. Symmetric to the tip_mutex fix in
        // selectFreshestParent.
        var rx_block: u64 = 0;
        var rx_slot: u64 = 0;
        var rx_hash: [32]u8 = [_]u8{0} ** 32;
        {
            ctx.rx_mutex.lock();
            defer ctx.rx_mutex.unlock();
            rx_block = ctx.rx_block_last;
            rx_slot = ctx.rx_slot_last;
            rx_hash = ctx.rx_hash_last;
        }
        var tip_block: u64 = 0;
        var tip_slot: u64 = 0;
        var tip_hash: [32]u8 = [_]u8{0} ** 32;
        {
            ctx.tip_mutex.lock();
            defer ctx.tip_mutex.unlock();
            tip_block = ctx.tip_block_last;
            tip_slot = ctx.tip_slot_last;
            tip_hash = ctx.tip_hash_last;
        }
        const parent_block = @max(rx_block, tip_block);
        if (ctx.genesis_parse_ok and parent_block > 0) {
            const use_rx = rx_block >= tip_block;
            const parent_slot = if (use_rx) rx_slot else tip_slot;
            const parent_hash = if (use_rx) rx_hash else tip_hash;
            const now = compat.timestamp();
            const est_slot = slot_clock.estimateSlot(&ctx.clock, now);
            if (est_slot > ctx.last_slot_checked) {
                producer.tick(ctx, est_slot, now, parent_slot, parent_block, parent_hash);
                fired += 1;
            }
        }
        compat.sleep(TICK_INTERVAL_MS * std.time.ns_per_ms);
    }
}

const std = @import("std");

// TSUNAGI-native process-wide stop signal.
//
// Used by detached worker threads (leader_schedule, wall_tick,
// protocol_manager, peer_probe, acceptance_tracker pollers,
// stake_distribution bootstrap) to exit promptly when SIGTERM/SIGINT
// fires, instead of spinning until process kill.
//
// Set by follower.handleSignal. Read by every worker loop top.
//
// Lives in its own tiny module so producer-side workers can import it
// without depending on follower/chainsync (which would cycle).
pub var g_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

pub inline fn stopRequested() bool {
    return g_stop.load(.acquire);
}

pub inline fn requestStop() void {
    g_stop.store(true, .release);
}

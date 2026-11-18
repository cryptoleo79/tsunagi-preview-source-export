const std = @import("std");

pub const Network = enum { mainnet, preprod, preview, sancho };

pub const NetworkProfile = struct {
    name: []const u8,
    network_magic: u32,
    default_relay_host: []const u8,
    default_relay_port: u16,
    genesis_dir_name: []const u8,
    home_suffix: []const u8,
    is_mainnet: bool,
};

pub fn getProfile(net: Network) NetworkProfile {
    return switch (net) {
        .mainnet => .{
            .name = "mainnet",
            .network_magic = 764_824_073,
            .default_relay_host = "",
            .default_relay_port = 3001,
            .genesis_dir_name = "mainnet",
            .home_suffix = "tsunagi-home-mainnet",
            .is_mainnet = true,
        },
        .preprod => .{
            .name = "preprod",
            .network_magic = 1,
            .default_relay_host = "preprod-node.world.dev.cardano.org",
            .default_relay_port = 30000,
            .genesis_dir_name = "preprod",
            .home_suffix = "tsunagi-home-preprod",
            .is_mainnet = false,
        },
        .preview => .{
            .name = "preview",
            .network_magic = 2,
            .default_relay_host = "preview-node.world.dev.cardano.org",
            .default_relay_port = 30002,
            .genesis_dir_name = "preview",
            .home_suffix = "tsunagi-home-preview",
            .is_mainnet = false,
        },
        .sancho => .{
            .name = "sancho",
            .network_magic = 4,
            .default_relay_host = "sanchonet-node.play.dev.cardano.org",
            .default_relay_port = 3001,
            .genesis_dir_name = "sancho",
            .home_suffix = "tsunagi-home-sancho",
            .is_mainnet = false,
        },
    };
}

/// Parse network name from CLI arg. Returns null on unknown value.
pub fn parseNet(name: []const u8) ?Network {
    if (std.mem.eql(u8, name, "mainnet")) return .mainnet;
    if (std.mem.eql(u8, name, "preprod")) return .preprod;
    if (std.mem.eql(u8, name, "preview")) return .preview;
    if (std.mem.eql(u8, name, "sancho")) return .sancho;
    return null;
}

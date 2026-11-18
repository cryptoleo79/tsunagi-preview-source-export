const std = @import("std");
const compat = @import("compat");
const Blake2b256 = std.crypto.hash.blake2.Blake2b256;
const sodium_vrf = @import("sodium_vrf.zig");

pub fn main() !void {
    var stdout_file = compat.fs.File.stdout();
    const stdout = stdout_file.writer();

    if (!sodium_vrf.sodiumInit()) {
        try stdout.print("ERROR: sodium_init failed\n", .{});
        return;
    }

    var hdr_buf: [4096]u8 = undefined;
    var hdr_file = compat.fs.cwd().openFile("/home/tsunagi/tsunagi-home-preview/propagation_artifact/block_header.cbor", .{}) catch return;
    defer hdr_file.close();
    const hdr_len = try hdr_file.readAll(&hdr_buf);
    const body = hdr_buf[1..]; // skip 0x82

    const slot: u64 = if (body[0] == 0x8a and body[6] == 0x1a)
        std.mem.readInt(u32, body[7..11], .big)
    else
        0;
    try stdout.print("slot={d}\n", .{slot});

    // vrf_vkey at body[81..113]
    var vrf_vkey: [32]u8 = undefined;
    @memcpy(&vrf_vkey, body[81..113]);
    try stdout.print("vrf_vkey={x}\n", .{&vrf_vkey});

    // vrf_result at body[113]: 82 5840 <output:64> 5850 <proof:80>
    const vs = @as(usize, 113);
    var vrf_output: [64]u8 = undefined;
    @memcpy(&vrf_output, body[vs + 3 .. vs + 67]);
    var vrf_proof: [80]u8 = undefined;
    @memcpy(&vrf_proof, body[vs + 69 .. vs + 149]);

    try stdout.print("vrf_output_prefix={x}\n", .{vrf_output[0..8]});
    try stdout.print("vrf_proof_prefix={x}\n", .{vrf_proof[0..8]});

    // VRF input: blake2b256(word64BE(slot) || epoch_nonce(32))
    // Ref: Ouroboros.Consensus.Protocol.Praos.VRF mkInputVRF
    const nonce_hex = "f2819e1a3ef71e54fb751605ade627ba8655f9310be4728850a3b93d3a1ab649";
    var nonce: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&nonce, nonce_hex) catch return;

    var seed: [40]u8 = undefined;
    std.mem.writeInt(u64, seed[0..8], slot, .big);
    @memcpy(seed[8..40], &nonce);
    var vrf_msg: [32]u8 = undefined;
    Blake2b256.hash(&seed, &vrf_msg, .{});
    try stdout.print("vrf_msg={x}\n", .{&vrf_msg});

    // Verify
    const result = sodium_vrf.verify(&vrf_vkey, &vrf_proof, &vrf_msg);
    if (result) |vr| {
        try stdout.print("\nVRF_VERIFY: OK\n", .{});
        const match = std.mem.eql(u8, &vr.output, &vrf_output);
        try stdout.print("output_match={}\n", .{match});
    } else {
        try stdout.print("\nVRF_VERIFY: FAIL\n", .{});
    }

    _ = hdr_len;
}

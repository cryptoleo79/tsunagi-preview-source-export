//! TSUNAGI — Zig 0.16 compatibility shim.
//!
//! 0.16 ("Writergate" + Io overhaul) removed/renamed the std surfaces TSUNAGI
//! relied on. Rather than thread an `Io` value through 110k LOC, this module
//! provides drop-in replacements that preserve the *old* call shapes, backed by
//! 0.16 primitives (or self-contained reimplementations). The migration then
//! becomes mostly mechanical:
//!     std.heap.GeneralPurposeAllocator -> compat.DebugAllocator
//!     std.io.fixedBufferStream         -> compat.fixedBufferStream
//!     std.io.FixedBufferStream         -> compat.FixedBufferStream
//!     std.fs.File                      -> compat.File
//!     std.process.getEnvVarOwned       -> compat.getEnvVarOwned
//!     std.process.hasEnvVar            -> compat.hasEnvVar
//!     std.process.argsWithAllocator    -> compat.argsWithAllocator
//!     <arraylist>.writer()             -> compat.listWriter(&<arraylist>)
//!     std.io.GenericWriter(net.Stream) -> compat.streamWriter(stream)
//!     std.io.GenericReader(net.Stream) -> compat.streamReader(stream)
//!     std.net.Address                  -> compat.IpAddress / compat.Address
//!     std.net.tcpConnectToAddress      -> compat.tcpConnectToAddress
//!     std.net.tcpConnectToHost         -> compat.tcpConnectToHost
//!     std.net.getAddressList           -> compat.getAddressList
//!     protocol stream reads/writes     -> compat.streamProtoReader/Writer (persistent buf)
//!
//! Env access uses the libc `environ` global (every TSUNAGI target links libc).
//! Author: cryptoleo79.
const std = @import("std");
const builtin = @import("builtin");

// ── allocators ───────────────────────────────────────────────────────────────
/// 0.16 renamed GeneralPurposeAllocator -> DebugAllocator (same `.{}` config).
pub const DebugAllocator = std.heap.DebugAllocator;

// ── files ────────────────────────────────────────────────────────────────────
/// 0.16 moved std.fs.File -> std.Io.File (with .stdin()/.stdout()/.stderr()).
/// The migration target for `std.fs.File` is `compat.fs.File` (the wrapper);
/// `IoFile` is the raw 0.16 type for code that needs it directly.
pub const IoFile = std.Io.File;

// ── environment (libc-backed) ─────────────────────────────────────────────────
/// The running process environment, viewed through the libc `environ` global.
pub fn currentEnviron() std.process.Environ {
    return .{ .block = .{ .slice = std.mem.span(std.c.environ) } };
}

pub const GetEnvVarError = error{ EnvironmentVariableNotFound, OutOfMemory };

/// Drop-in for std.process.getEnvVarOwned (removed in 0.16).
pub fn getEnvVarOwned(allocator: std.mem.Allocator, key: []const u8) GetEnvVarError![]u8 {
    const v = currentEnviron().getPosix(key) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, v);
}

/// Drop-in for std.process.hasEnvVar (returns bool; old form returned !bool —
/// callers that wrote `try compat.hasEnvVar(...)` must drop the `try`).
pub fn hasEnvVar(allocator: std.mem.Allocator, key: []const u8) bool {
    _ = allocator;
    return currentEnviron().getPosix(key) != null;
}

/// Drop-in for std.posix.getenv (removed in 0.16). No allocation; valid for
/// process lifetime.
pub fn getenv(key: []const u8) ?[:0]const u8 {
    return currentEnviron().getPosix(key);
}

/// Drop-in for std.process.EnvMap / getEnvMap (removed in 0.16).
pub const EnvMap = std.process.Environ.Map;
pub fn getEnvMap(allocator: std.mem.Allocator) !EnvMap {
    return currentEnviron().createMap(allocator);
}

/// Iterator-style args. 0.16 removed argsWithAllocator AND the `std.os.argv`
/// global, leaving the raw argv vector only on the `std.process.Args` value that
/// `main` receives — which TSUNAGI does not thread through its old call shapes.
/// To preserve the old "argsAlloc anywhere" surface without changing main's
/// signature, read the kernel-provided argv from `/proc/self/cmdline` (NUL-
/// separated, libc-consistent, same source the loader uses). Returns an owned
/// slice of args including argv[0] (caller frees with the arena).
pub fn argsAlloc(arena: std.mem.Allocator) ![]const [:0]const u8 {
    var file = try fs.openFileAbsolute("/proc/self/cmdline", .{ .mode = .read_only });
    defer file.close();
    // cmdline is a sequence of NUL-terminated strings.
    //
    // procfs files (e.g. /proc/self/cmdline) report st_size = 0 and are not
    // reliably seekable/positional. 0.16's positional File.Reader path
    // (used by the regular File.readToEndAlloc) sizes/EOF-detects in a way
    // that returns an empty slice for such virtual files, which silently
    // dropped every argv entry and made the node fall through to its
    // in-memory demo for ANY subcommand. Read via the streaming reader,
    // which loops on read() until EndOfStream and does not trust st_size.
    const raw = blk: {
        var rbuf: [4096]u8 = undefined;
        var fr = std.Io.File.Reader.initStreaming(file.inner, defaultIo(), &rbuf);
        break :blk try fr.interface.allocRemaining(arena, std.Io.Limit.limited(std.math.maxInt(usize)));
    };

    var list: std.ArrayList([:0]const u8) = .empty;
    var start: usize = 0;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == 0) {
            try list.append(arena, raw[start..i :0]);
            start = i + 1;
        }
    }
    // Trailing arg without a final NUL (shouldn't happen for /proc/self/cmdline,
    // but be safe): copy it into a NUL-terminated buffer.
    if (start < raw.len) {
        const tail = try arena.allocSentinel(u8, raw.len - start, 0);
        @memcpy(tail, raw[start..]);
        try list.append(arena, tail);
    }
    return list.toOwnedSlice(arena);
}

// ── FixedBufferStream (self-contained; old API preserved) ─────────────────────
// Reimplemented directly over the backing buffer — no dependency on 0.16's Io
// vtable. Preserves the exact 0.15 FixedBufferStream surface TSUNAGI uses:
//   .writer() / .reader() / .getWritten() / .getPos() / .seekTo() / .reset()
//   writer: writeAll/writeByte/writeInt/writeByteNTimes/print/write
//   reader: read/readByte/readInt/readNoEof/readBytesNoEof/readAllAlloc/skipBytes
pub fn FixedBufferStream(comptime Buffer: type) type {
    return struct {
        buffer: Buffer,
        pos: usize = 0,

        const Self = @This();

        pub const WriteError = error{NoSpaceLeft};
        pub const ReadError = error{EndOfStream};

        pub const Writer = struct {
            ctx: *Self,
            pub const Error = WriteError;

            pub fn writeAll(self: Writer, bytes: []const u8) Error!void {
                const s = self.ctx;
                if (s.pos + bytes.len > s.buffer.len) return error.NoSpaceLeft;
                @memcpy(s.buffer[s.pos..][0..bytes.len], bytes);
                s.pos += bytes.len;
            }
            pub fn writeByte(self: Writer, b: u8) Error!void {
                return self.writeAll(&[_]u8{b});
            }
            pub fn writeByteNTimes(self: Writer, b: u8, n: usize) Error!void {
                var i: usize = 0;
                while (i < n) : (i += 1) try self.writeByte(b);
            }
            pub fn writeInt(self: Writer, comptime T: type, value: T, endian: std.builtin.Endian) Error!void {
                var tmp: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
                std.mem.writeInt(T, &tmp, value, endian);
                return self.writeAll(&tmp);
            }
            pub fn print(self: Writer, comptime fmt: []const u8, args: anytype) Error!void {
                const s = self.ctx;
                const out = std.fmt.bufPrint(s.buffer[s.pos..], fmt, args) catch return error.NoSpaceLeft;
                s.pos += out.len;
            }
            pub fn write(self: Writer, bytes: []const u8) Error!usize {
                const s = self.ctx;
                const n = @min(bytes.len, s.buffer.len - s.pos);
                @memcpy(s.buffer[s.pos..][0..n], bytes[0..n]);
                s.pos += n;
                return n;
            }
        };

        pub const Reader = struct {
            ctx: *Self,
            pub const Error = ReadError;

            pub fn read(self: Reader, dst: []u8) error{}!usize {
                const s = self.ctx;
                const n = @min(dst.len, s.buffer.len - s.pos);
                @memcpy(dst[0..n], s.buffer[s.pos..][0..n]);
                s.pos += n;
                return n;
            }
            pub fn readByte(self: Reader) Error!u8 {
                const s = self.ctx;
                if (s.pos >= s.buffer.len) return error.EndOfStream;
                const b = s.buffer[s.pos];
                s.pos += 1;
                return b;
            }
            pub fn readInt(self: Reader, comptime T: type, endian: std.builtin.Endian) Error!T {
                const n = @divExact(@typeInfo(T).int.bits, 8);
                const s = self.ctx;
                if (s.pos + n > s.buffer.len) return error.EndOfStream;
                const v = std.mem.readInt(T, s.buffer[s.pos..][0..n], endian);
                s.pos += n;
                return v;
            }
            pub fn readAll(self: Reader, dst: []u8) Error!usize {
                const s = self.ctx;
                const n = @min(dst.len, s.buffer.len - s.pos);
                @memcpy(dst[0..n], s.buffer[s.pos..][0..n]);
                s.pos += n;
                return n;
            }
            pub fn readNoEof(self: Reader, dst: []u8) Error!void {
                const s = self.ctx;
                if (s.pos + dst.len > s.buffer.len) return error.EndOfStream;
                @memcpy(dst, s.buffer[s.pos..][0..dst.len]);
                s.pos += dst.len;
            }
            pub fn readBytesNoEof(self: Reader, comptime n: usize) Error![n]u8 {
                var out: [n]u8 = undefined;
                try self.readNoEof(&out);
                return out;
            }
            pub fn readAllAlloc(self: Reader, allocator: std.mem.Allocator, max: usize) ![]u8 {
                const s = self.ctx;
                const remaining = s.buffer[s.pos..];
                if (remaining.len > max) return error.StreamTooLong;
                const out = try allocator.dupe(u8, remaining);
                s.pos = s.buffer.len;
                return out;
            }
            pub fn skipBytes(self: Reader, n: u64, comptime _: anytype) Error!void {
                const s = self.ctx;
                const want = std.math.cast(usize, n) orelse return error.EndOfStream;
                if (s.pos + want > s.buffer.len) return error.EndOfStream;
                s.pos += want;
            }
        };

        pub fn writer(self: *Self) Writer {
            return .{ .ctx = self };
        }
        pub fn reader(self: *Self) Reader {
            return .{ .ctx = self };
        }
        pub fn getWritten(self: *Self) []u8 {
            return self.buffer[0..self.pos];
        }
        pub fn getPos(self: *Self) usize {
            return self.pos;
        }
        pub fn getEndPos(self: *Self) usize {
            return self.buffer.len;
        }
        pub fn seekTo(self: *Self, p: usize) void {
            self.pos = @min(p, self.buffer.len);
        }
        pub fn seekBy(self: *Self, amt: i64) void {
            if (amt < 0) {
                self.pos -|= @intCast(-amt);
            } else {
                self.pos = @min(self.pos + @as(usize, @intCast(amt)), self.buffer.len);
            }
        }
        pub fn reset(self: *Self) void {
            self.pos = 0;
        }
    };
}

pub fn fixedBufferStream(buffer: anytype) FixedBufferStream(@TypeOf(buffer)) {
    return .{ .buffer = buffer };
}

// ── ArrayList writer adapter ──────────────────────────────────────────────────
// array_list.Managed lost `.writer()` in 0.16. This adapter restores the old
// writer surface over a *Managed(u8). Migrate `list.writer()` ->
// `compat.listWriter(&list)`.
pub const ListWriter = struct {
    list: *std.array_list.Managed(u8),
    pub const Error = std.mem.Allocator.Error;

    pub fn writeAll(self: ListWriter, bytes: []const u8) Error!void {
        try self.list.appendSlice(bytes);
    }
    pub fn writeByte(self: ListWriter, b: u8) Error!void {
        try self.list.append(b);
    }
    pub fn writeByteNTimes(self: ListWriter, b: u8, n: usize) Error!void {
        try self.list.appendNTimes(b, n);
    }
    pub fn writeInt(self: ListWriter, comptime T: type, value: T, endian: std.builtin.Endian) Error!void {
        var tmp: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
        std.mem.writeInt(T, &tmp, value, endian);
        try self.list.appendSlice(&tmp);
    }
    pub fn print(self: ListWriter, comptime fmt: []const u8, args: anytype) Error!void {
        try self.list.print(fmt, args);
    }
    pub fn write(self: ListWriter, bytes: []const u8) Error!usize {
        try self.list.appendSlice(bytes);
        return bytes.len;
    }
};

pub fn listWriter(list: *std.array_list.Managed(u8)) ListWriter {
    return .{ .list = list };
}

// ── net.Stream adapters (replace std.io.GenericWriter/GenericReader over Stream) ─
// NOTE: 0.16 moved std.net.Stream -> std.Io.net.Stream with io-threaded I/O via
// Stream.Reader/Writer. These per-call adapters keep the old write surface and
// are adequate for short request/response writes; the broader net stack (buffered
// protocol reads, connect, Address) migrates separately.
pub const NetStream = std.Io.net.Stream;

pub const StreamWriter = struct {
    stream: NetStream,
    pub const Error = anyerror;

    pub fn writeAll(self: StreamWriter, bytes: []const u8) Error!void {
        var buf: [4096]u8 = undefined;
        var sw = NetStream.Writer.init(self.stream, defaultIo(), &buf);
        try sw.interface.writeAll(bytes);
        try sw.interface.flush();
    }
    pub fn writeByte(self: StreamWriter, b: u8) Error!void {
        return self.writeAll(&[_]u8{b});
    }
    pub fn writeInt(self: StreamWriter, comptime T: type, value: T, endian: std.builtin.Endian) Error!void {
        var tmp: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
        std.mem.writeInt(T, &tmp, value, endian);
        return self.writeAll(&tmp);
    }
    pub fn print(self: StreamWriter, comptime fmt: []const u8, args: anytype) Error!void {
        var buf: [4096]u8 = undefined;
        const out = try std.fmt.bufPrint(&buf, fmt, args);
        return self.writeAll(out);
    }
    pub fn write(self: StreamWriter, bytes: []const u8) Error!usize {
        try self.writeAll(bytes);
        return bytes.len;
    }
};

pub const StreamReader = struct {
    stream: NetStream,
    pub const Error = anyerror;

    pub fn read(self: StreamReader, dst: []u8) Error!usize {
        var buf: [4096]u8 = undefined;
        var sr = NetStream.Reader.init(self.stream, defaultIo(), &buf);
        return sr.interface.readSliceShort(dst);
    }
    pub fn readByte(self: StreamReader) Error!u8 {
        var b: [1]u8 = undefined;
        const n = try self.read(&b);
        if (n == 0) return error.EndOfStream;
        return b[0];
    }
    pub fn readNoEof(self: StreamReader, dst: []u8) Error!void {
        var off: usize = 0;
        while (off < dst.len) {
            const n = try self.read(dst[off..]);
            if (n == 0) return error.EndOfStream;
            off += n;
        }
    }
    pub fn readBytesNoEof(self: StreamReader, comptime n: usize) Error![n]u8 {
        var out: [n]u8 = undefined;
        try self.readNoEof(&out);
        return out;
    }
    /// Drain the stream to EOF into a freshly allocated slice (caller owns it),
    /// up to `max` bytes (error.StreamTooLong if exceeded). Matches the old
    /// std.io.Reader.readAllAlloc semantics. Uses ONE underlying 0.16
    /// Io.Reader so buffered-but-unconsumed bytes are not discarded mid-drain
    /// (unlike the per-call `read`, which is only safe for single reads).
    pub fn readAllAlloc(self: StreamReader, allocator: std.mem.Allocator, max: usize) Error![]u8 {
        var buf: [4096]u8 = undefined;
        var sr = NetStream.Reader.init(self.stream, defaultIo(), &buf);
        return sr.interface.allocRemaining(allocator, std.Io.Limit.limited(max));
    }
};

pub fn streamWriter(stream: NetStream) StreamWriter {
    return .{ .stream = stream };
}
pub fn streamReader(stream: NetStream) StreamReader {
    return .{ .stream = stream };
}

// ── net Address / connect / resolve (replace std.net.{Address,tcpConnectTo*,…}) ─
// 0.16 replaced std.net.Address with std.Io.net.IpAddress (a tagged union of
// ip4/ip6). The byte layout the Cardano wire path emits is unaffected — Address
// values are only used to OPEN sockets, never serialized into protocol messages.
//
//   std.net.Address            -> compat.IpAddress  (= std.Io.net.IpAddress)
//   Address.parseIp(text,port) -> compat.IpAddress.parse(text, port)
//   std.net.tcpConnectToAddress(a) -> compat.tcpConnectToAddress(a)
//   std.net.tcpConnectToHost(...)  -> compat.tcpConnectToHost(alloc, host, port)
//   std.net.getAddressList(...)    -> compat.getAddressList(alloc, host, port)
pub const IpAddress = std.Io.net.IpAddress;
/// Back-compat alias for the old type name `std.net.Address`.
pub const Address = std.Io.net.IpAddress;

/// Drop-in for std.net.tcpConnectToAddress(a) -> Stream.
/// 0.16's IpAddress.connect takes `*const IpAddress`, an Io, and ConnectOptions.
/// Returns a NetStream (== std.Io.net.Stream). Mode/protocol fixed to TCP stream
/// to match the old tcpConnectToAddress semantics exactly.
pub fn tcpConnectToAddress(address: IpAddress) !NetStream {
    var addr = address;
    return addr.connect(defaultIo(), .{ .mode = .stream, .protocol = .tcp });
}

/// Drop-in for std.net.tcpConnectToHost: resolve `host` (DNS or literal) to its
/// first address and open a TCP stream. `allocator` is accepted for call-shape
/// compatibility with the old signature; resolution itself does not allocate
/// (results land in a fixed on-stack queue buffer).
pub fn tcpConnectToHost(allocator: std.mem.Allocator, host: []const u8, port: u16) !NetStream {
    _ = allocator;
    // Literal IPs short-circuit DNS (and work without /etc/resolv.conf).
    if (IpAddress.parse(host, port)) |lit| {
        return tcpConnectToAddress(lit);
    } else |_| {}
    const io = defaultIo();
    const hn = try std.Io.net.HostName.init(host);
    // lookup guarantees no-block when queue capacity >= 16, and closes the queue
    // before returning. Drain the first resolved address and connect to it.
    var qbuf: [16]std.Io.net.HostName.LookupResult = undefined;
    var q = std.Io.Queue(std.Io.net.HostName.LookupResult).init(&qbuf);
    try hn.lookup(io, &q, .{ .port = port });
    while (true) {
        const item = q.getOneUncancelable(io) catch return error.UnknownHostName;
        switch (item) {
            .address => |a| return tcpConnectToAddress(a),
            .canonical_name => continue,
        }
    }
}

/// Owned list of resolved addresses, mirroring the old std.net.AddressList shape
/// (`.addrs` slice + `.deinit()`). Backed by the caller's allocator.
pub const AddressList = struct {
    arena: std.heap.ArenaAllocator,
    addrs: []IpAddress,

    pub fn deinit(self: *AddressList) void {
        self.arena.deinit();
    }
};

/// Drop-in for std.net.getAddressList(allocator, host, port). Resolves `host`
/// (literal IP or DNS name) to a list of `IpAddress`. The returned list owns its
/// memory via an internal arena; free with `.deinit()`.
///
/// RESIDUAL NOTE: the old std.net.getAddressList also surfaced the canonical
/// name and per-address family ordering via getaddrinfo. 0.16's
/// HostName.lookup returns addresses + exactly one canonical_name through a
/// queue; this shim collects only the addresses (the only field TSUNAGI's
/// connect path consumes). If a caller needs the canonical name, use
/// std.Io.net.HostName.lookup directly.
pub fn getAddressList(allocator: std.mem.Allocator, host: []const u8, port: u16) !*AddressList {
    const result = try allocator.create(AddressList);
    errdefer allocator.destroy(result);
    result.* = .{ .arena = std.heap.ArenaAllocator.init(allocator), .addrs = &.{} };
    errdefer result.arena.deinit();
    const aa = result.arena.allocator();

    // Literal IP: single-element list, no DNS.
    if (IpAddress.parse(host, port)) |lit| {
        const one = try aa.alloc(IpAddress, 1);
        one[0] = lit;
        result.addrs = one;
        return result;
    } else |_| {}

    const io = defaultIo();
    const hn = try std.Io.net.HostName.init(host);
    var qbuf: [16]std.Io.net.HostName.LookupResult = undefined;
    var q = std.Io.Queue(std.Io.net.HostName.LookupResult).init(&qbuf);
    try hn.lookup(io, &q, .{ .port = port });

    var list: std.ArrayList(IpAddress) = .empty;
    while (true) {
        const item = q.getOneUncancelable(io) catch break; // Closed when drained
        switch (item) {
            .address => |a| try list.append(aa, a),
            .canonical_name => {},
        }
    }
    result.addrs = try list.toOwnedSlice(aa);
    return result;
}

// ── raw posix socket wrappers (replace std.posix.{socket,connect,close,getsockoptError}) ─
// 0.16 removed the std.posix wrappers for socket/connect/close/getsockoptError
// (only the constants/types — SOCK, IPPROTO, POLL, pollfd, sockaddr, socklen_t —
// and std.posix.poll remain). The non-blocking connect-with-timeout path needs
// the raw syscalls, which the high-level std.Io.net.IpAddress.connect cannot
// express (no timeout knob). These wrappers reproduce the exact 0.15 std.posix
// Linux errno->error mappings, backed by libc (every TSUNAGI target links libc,
// and the relay runs Linux only).
pub const SocketError = error{
    AccessDenied,
    AddressFamilyNotSupported,
    ProtocolFamilyNotAvailable,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    ProtocolNotSupported,
    SocketTypeNotSupported,
} || std.posix.UnexpectedError;

pub const ConnectError = error{
    AccessDenied,
    PermissionDenied,
    AddressInUse,
    AddressNotAvailable,
    AddressFamilyNotSupported,
    WouldBlock,
    ConnectionPending,
    ConnectionRefused,
    ConnectionResetByPeer,
    NetworkUnreachable,
    ConnectionTimedOut,
    FileNotFound,
    SystemResources,
} || std.posix.UnexpectedError;

/// Drop-in for std.posix.socket (Linux path). On Linux SOCK.NONBLOCK/CLOEXEC are
/// honored directly by the socket(2) syscall, so no post-open fcntl is needed.
pub fn socket(domain: u32, socket_type: u32, protocol: u32) SocketError!std.posix.socket_t {
    const rc = std.c.socket(@intCast(domain), @intCast(socket_type), @intCast(protocol));
    switch (std.posix.errno(rc)) {
        .SUCCESS => return @intCast(rc),
        .ACCES => return error.AccessDenied,
        .AFNOSUPPORT => return error.AddressFamilyNotSupported,
        .INVAL => return error.ProtocolFamilyNotAvailable,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        .NOBUFS => return error.SystemResources,
        .NOMEM => return error.SystemResources,
        .PROTONOSUPPORT => return error.ProtocolNotSupported,
        .PROTOTYPE => return error.SocketTypeNotSupported,
        else => |err| return std.posix.unexpectedErrno(err),
    }
}

/// Drop-in for std.posix.close on a socket fd (best-effort, matching the
/// EINTR/EBADF-ignoring behavior of std.posix.close).
pub fn closeSocket(fd: std.posix.socket_t) void {
    _ = std.c.close(fd);
}

/// Drop-in for std.posix.connect (Linux path), preserving the exact errno->error
/// mapping including the EINTR retry loop.
pub fn connect(sock: std.posix.socket_t, sock_addr: *const std.posix.sockaddr, len: std.posix.socklen_t) ConnectError!void {
    while (true) {
        switch (std.posix.errno(std.c.connect(sock, sock_addr, len))) {
            .SUCCESS => return,
            .ACCES => return error.AccessDenied,
            .PERM => return error.PermissionDenied,
            .ADDRINUSE => return error.AddressInUse,
            .ADDRNOTAVAIL => return error.AddressNotAvailable,
            .AFNOSUPPORT => return error.AddressFamilyNotSupported,
            .AGAIN, .INPROGRESS => return error.WouldBlock,
            .ALREADY => return error.ConnectionPending,
            .BADF => unreachable,
            .CONNREFUSED => return error.ConnectionRefused,
            .CONNRESET => return error.ConnectionResetByPeer,
            .FAULT => unreachable,
            .INTR => continue,
            .ISCONN => unreachable,
            .HOSTUNREACH => return error.NetworkUnreachable,
            .NETUNREACH => return error.NetworkUnreachable,
            .NOTSOCK => unreachable,
            .PROTOTYPE => unreachable,
            .TIMEDOUT => return error.ConnectionTimedOut,
            .NOENT => return error.FileNotFound,
            .CONNABORTED => unreachable,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}

/// Drop-in for std.posix.getsockoptError (SO_ERROR probe after async connect).
pub fn getsockoptError(sockfd: std.posix.socket_t) ConnectError!void {
    var err_code: i32 = undefined;
    var size: std.posix.socklen_t = @sizeOf(u32);
    const rc = std.c.getsockopt(sockfd, std.posix.SOL.SOCKET, std.posix.SO.ERROR, @ptrCast(&err_code), &size);
    std.debug.assert(size == 4);
    switch (std.posix.errno(rc)) {
        .SUCCESS => switch (@as(std.posix.E, @enumFromInt(err_code))) {
            .SUCCESS => return,
            .ACCES => return error.AccessDenied,
            .PERM => return error.PermissionDenied,
            .ADDRINUSE => return error.AddressInUse,
            .ADDRNOTAVAIL => return error.AddressNotAvailable,
            .AFNOSUPPORT => return error.AddressFamilyNotSupported,
            .AGAIN => return error.SystemResources,
            .ALREADY => return error.ConnectionPending,
            .BADF => unreachable,
            .CONNREFUSED => return error.ConnectionRefused,
            .FAULT => unreachable,
            .ISCONN => unreachable,
            .HOSTUNREACH => return error.NetworkUnreachable,
            .NETUNREACH => return error.NetworkUnreachable,
            .NOTSOCK => unreachable,
            .PROTOTYPE => unreachable,
            .TIMEDOUT => return error.ConnectionTimedOut,
            .CONNRESET => return error.ConnectionResetByPeer,
            else => |err| return std.posix.unexpectedErrno(err),
        },
        .BADF => unreachable,
        .FAULT => unreachable,
        .INVAL => unreachable,
        .NOPROTOOPT => unreachable,
        .NOTSOCK => unreachable,
        else => |err| return std.posix.unexpectedErrno(err),
    }
}

// ── persistent-buffer protocol Stream Reader/Writer ───────────────────────────
// The short-write `StreamWriter`/`StreamReader` adapters above spin up a fresh
// 4096-byte Io.Reader/Writer per call — fine for a single request/response, but
// WRONG for length-prefixed protocol reads: a read that pulls more bytes off the
// socket than the caller asked for would discard the surplus held in the local
// buffer. For the Cardano mux/protocol path, hold ONE reader (and one writer)
// per connection with a PERSISTENT buffer so buffered-but-unconsumed bytes
// survive across calls.
//
// Usage:
//   var rbuf: [N]u8 = undefined;            // lives as long as the connection
//   var pr = compat.streamProtoReader(stream, &rbuf);
//   try pr.readNoEof(hdr[0..8]);            // exact protocol semantics
//   ... pr.readByte(), pr.readInt(...), ...
pub const StreamProtoReader = struct {
    inner: NetStream.Reader,
    pub const Error = anyerror;

    pub fn read(self: *StreamProtoReader, dst: []u8) Error!usize {
        return self.inner.interface.readSliceShort(dst);
    }
    pub fn readByte(self: *StreamProtoReader) Error!u8 {
        return self.inner.interface.takeByte();
    }
    pub fn readNoEof(self: *StreamProtoReader, dst: []u8) Error!void {
        return self.inner.interface.readSliceAll(dst);
    }
    pub fn readBytesNoEof(self: *StreamProtoReader, comptime n: usize) Error![n]u8 {
        var out: [n]u8 = undefined;
        try self.readNoEof(&out);
        return out;
    }
    pub fn readInt(self: *StreamProtoReader, comptime T: type, endian: std.builtin.Endian) Error!T {
        var tmp: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
        try self.readNoEof(&tmp);
        return std.mem.readInt(T, &tmp, endian);
    }
};

pub const StreamProtoWriter = struct {
    inner: NetStream.Writer,
    pub const Error = anyerror;

    pub fn writeAll(self: *StreamProtoWriter, bytes: []const u8) Error!void {
        try self.inner.interface.writeAll(bytes);
    }
    pub fn writeByte(self: *StreamProtoWriter, b: u8) Error!void {
        try self.inner.interface.writeAll(&[_]u8{b});
    }
    pub fn writeInt(self: *StreamProtoWriter, comptime T: type, value: T, endian: std.builtin.Endian) Error!void {
        var tmp: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
        std.mem.writeInt(T, &tmp, value, endian);
        try self.inner.interface.writeAll(&tmp);
    }
    /// Flushes buffered bytes to the socket. Protocol writers MUST flush at
    /// message boundaries so the peer sees the bytes (the buffer is persistent).
    pub fn flush(self: *StreamProtoWriter) Error!void {
        try self.inner.interface.flush();
    }
};

/// Construct a persistent-buffer protocol reader. `buffer` MUST outlive the
/// returned reader (typically owned by the connection struct).
pub fn streamProtoReader(stream: NetStream, buffer: []u8) StreamProtoReader {
    return .{ .inner = NetStream.Reader.init(stream, defaultIo(), buffer) };
}
/// Construct a persistent-buffer protocol writer. `buffer` MUST outlive the
/// returned writer. Call `.flush()` at message boundaries.
pub fn streamProtoWriter(stream: NetStream, buffer: []u8) StreamProtoWriter {
    return .{ .inner = NetStream.Writer.init(stream, defaultIo(), buffer) };
}

// ── time / sleep (0.16 moved these into the Io clock model) ────────────────────
/// Drop-ins for std.time.* (removed in 0.16; the ns_per_* constants remain).
pub fn nanoTimestamp() i128 {
    return @as(i128, std.Io.Timestamp.now(defaultIo(), .real).nanoseconds);
}
pub fn milliTimestamp() i64 {
    return @intCast(@divTrunc(std.Io.Timestamp.now(defaultIo(), .real).nanoseconds, std.time.ns_per_ms));
}
pub fn timestamp() i64 {
    return @intCast(@divTrunc(std.Io.Timestamp.now(defaultIo(), .real).nanoseconds, std.time.ns_per_s));
}
/// Drop-in for std.Thread.sleep(ns) (removed in 0.16).
pub fn sleep(nanoseconds: u64) void {
    std.Io.sleep(defaultIo(), std.Io.Duration.fromNanoseconds(@intCast(nanoseconds)), .awake) catch {};
}

// ── child process run (0.16 moved std.process.Child.run -> std.process.run) ────
/// Drop-in for the old `std.process.Child.run(.{ .allocator, .argv,
/// .max_output_bytes })`. 0.16 moved this to `std.process.run(gpa, io, opts)`
/// and renamed `max_output_bytes` -> `stdout_limit`/`stderr_limit`. Result has
/// the same `.term`/`.stdout`/`.stderr` fields and the same ownership contract.
pub fn childRun(args: struct {
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    max_output_bytes: usize = 50 * 1024,
}) !std.process.RunResult {
    const lim = std.Io.Limit.limited(args.max_output_bytes);
    return std.process.run(args.allocator, defaultIo(), .{
        .argv = args.argv,
        .stdout_limit = lim,
        .stderr_limit = lim,
    });
}

/// Drop-in for the old `std.process.Child.init(argv, alloc); .spawnAndWait()`.
/// 0.16 removed `Child.init`; spawning now goes through `std.process.spawn(io,
/// opts)` and `Child.wait(io)`. Stdio defaults to `.inherit` in both the old and
/// new APIs, so the child's output still goes to the parent's terminal, exactly
/// like `spawnAndWait`. Returns the same `std.process.Child.Term`.
pub fn childSpawnWait(argv: []const []const u8) !std.process.Child.Term {
    const io = defaultIo();
    var child = try std.process.spawn(io, .{ .argv = argv });
    return child.wait(io);
}

// ── Mutex (0.16 moved std.Thread.Mutex -> std.Io.Mutex with io-threaded lock) ──
/// Wrapper preserving the old `var m: compat.Mutex = .{}; m.lock(); m.unlock();`
/// shape, backed by std.Io.Mutex over the global Io.
pub const Mutex = struct {
    inner: std.Io.Mutex = .init,
    pub fn lock(self: *Mutex) void {
        self.inner.lockUncancelable(defaultIo());
    }
    pub fn unlock(self: *Mutex) void {
        self.inner.unlock(defaultIo());
    }
    pub fn tryLock(self: *Mutex) bool {
        return self.inner.tryLock();
    }
};

// ── cryptographic randomness (replace std.crypto.random, removed in 0.16) ─────
// 0.16 removed the global `std.crypto.random` CSPRNG. This fills `buf` from the
// kernel CSPRNG (getrandom(2), the same secure source the old global used on
// Linux), retrying on EINTR and short reads. Behavior-preserving for callers
// that previously relied on `std.crypto.random.bytes`.
pub fn cryptoRandomBytes(buf: []u8) void {
    var filled: usize = 0;
    while (filled < buf.len) {
        const rc = std.os.linux.getrandom(buf.ptr + filled, buf.len - filled, 0);
        switch (std.posix.errno(rc)) {
            .SUCCESS => filled += @intCast(rc),
            .INTR => continue,
            else => @panic("compat.cryptoRandomBytes: getrandom failed"),
        }
    }
}

// ── raw fd write (replace std.posix.write, removed in 0.16) ───────────────────
// 0.16 kept std.posix.read but removed std.posix.write. This is a faithful
// re-implementation of the canonical posix.write loop (same INTR retry, same
// max_count clamp, same errno→error mapping as the old std.posix.write) so
// raw-fd write paths (e.g. socket writes preserving SO_*/WouldBlock semantics)
// keep identical behavior. Returns bytes written (may be short).
pub const PosixWriteError = error{
    WouldBlock,
    DiskQuota,
    FileTooBig,
    InputOutput,
    NoSpaceLeft,
    AccessDenied,
    BrokenPipe,
    ConnectionResetByPeer,
    DeviceBusy,
    Unexpected,
};
pub fn posixWrite(fd: std.posix.fd_t, bytes: []const u8) PosixWriteError!usize {
    if (bytes.len == 0) return 0;
    const max_count = switch (builtin.os.tag) {
        .linux => 0x7ffff000,
        .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => std.math.maxInt(i32),
        else => std.math.maxInt(isize),
    };
    while (true) {
        const rc = std.posix.system.write(fd, bytes.ptr, @min(bytes.len, max_count));
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .INVAL => return error.Unexpected,
            .FAULT => return error.Unexpected,
            .AGAIN => return error.WouldBlock,
            .BADF => return error.Unexpected, // use after free
            .DESTADDRREQ => return error.Unexpected, // `connect` was never called
            .DQUOT => return error.DiskQuota,
            .FBIG => return error.FileTooBig,
            .IO => return error.InputOutput,
            .NOSPC => return error.NoSpaceLeft,
            .PERM => return error.AccessDenied,
            .PIPE => return error.BrokenPipe,
            .CONNRESET => return error.ConnectionResetByPeer,
            .BUSY => return error.DeviceBusy,
            else => return error.Unexpected,
        }
    }
}

// ── filesystem (wrappers over the 0.16 global Io) ─────────────────────────────
// 0.16 removed std.fs.File/Dir/cwd and the std.posix file escape hatch; all file
// I/O now needs an `Io`. We use the process-global single-threaded Io and wrap the
// new Io.Dir/Io.File in structs that carry the OLD method API, so the tree only
// needs `std.fs.` -> `compat.fs.`. File read/write are positional + write-through
// (correctness over speed — consensus byte output must be exact).
pub inline fn defaultIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

// ── self-exe path (replace std.fs.selfExePath, removed in 0.16) ───────────────
// 0.16 removed std.fs.selfExePath. On Linux the old implementation simply did
// readlink("/proc/self/exe"); reproduce that via std.Io.Dir.readLinkAbsolute over
// the global Io, writing into the caller-provided buffer and returning the slice.
// Same syscall, same result bytes — drop-in for `std.fs.selfExePath(&buf)`.
pub fn selfExePath(out_buffer: []u8) ![]u8 {
    const n = try std.Io.Dir.readLinkAbsolute(defaultIo(), "/proc/self/exe", out_buffer);
    return out_buffer[0..n];
}

// ── subprocess (wrapper over 0.16 std.process.run) ────────────────────────────
// 0.16 removed std.process.Child.init / per-field stdout_behavior + manual
// spawn/readAll/wait. The Io-based std.process.run spawns the child, collects
// stdout+stderr, and waits — exactly the old "Pipe stdout / Ignore stderr /
// readAll / check exit" flow. This wrapper preserves the prior semantics:
//   - returns null on spawn/read/non-zero-exit, or empty stdout
//   - copies up to `out_buf.len` bytes of stdout into out_buf, returns that slice
// stderr is collected then discarded (the old code used .Ignore; the bytes the
// caller consumes are stdout only, so output to the caller is unchanged).
pub fn runCaptureStdout(alloc: std.mem.Allocator, argv: []const []const u8, out_buf: []u8) ?[]u8 {
    const io = defaultIo();
    const result = std.process.run(alloc, io, .{ .argv = argv }) catch return null;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    const n = @min(result.stdout.len, out_buf.len);
    if (n == 0) return null;
    @memcpy(out_buf[0..n], result.stdout[0..n]);
    return out_buf[0..n];
}

// Like runCaptureStdout but also surfaces the exit code and captured stderr,
// for callers that branch on the child's exit status and log stderr forensically
// (the old code did `child.spawn(); readAll(stdout); readAll(stderr); wait()`
// then inspected `result.Exited`). 0.16's std.process.run performs exactly that
// spawn+collect+wait sequence; this copies the collected bytes into the caller's
// fixed buffers so the surrounding logic is byte-for-byte unchanged. Returns
// null only when spawn/collection itself fails (old code returned an error in
// that case); a non-zero exit is reported via `exit_code`, not swallowed.
pub const CaptureResult = struct {
    /// Exit code; 0 == success. Non-`.exited` terminations map to a non-zero
    /// sentinel (255) so callers using `!= 0` see them as failures, matching the
    /// old behavior where signal/stop terminations were not `.Exited == 0`.
    exit_code: u8,
    /// stdout bytes copied into the caller's out_buf (sub-slice of out_buf).
    stdout: []u8,
    /// stderr bytes copied into the caller's err_buf (sub-slice of err_buf).
    stderr: []u8,
};
pub fn runCapture(
    alloc: std.mem.Allocator,
    argv: []const []const u8,
    out_buf: []u8,
    err_buf: []u8,
) ?CaptureResult {
    const io = defaultIo();
    const result = std.process.run(alloc, io, .{ .argv = argv }) catch return null;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    const code: u8 = switch (result.term) {
        .exited => |c| c,
        else => 255,
    };
    const on = @min(result.stdout.len, out_buf.len);
    @memcpy(out_buf[0..on], result.stdout[0..on]);
    const en = @min(result.stderr.len, err_buf.len);
    @memcpy(err_buf[0..en], result.stderr[0..en]);
    return .{ .exit_code = code, .stdout = out_buf[0..on], .stderr = err_buf[0..en] };
}

// ── process.Child shim (imperative spawn with stdin pipe) ─────────────────────
// std.process.run hardcodes stdin=.ignore, so callers that must WRITE to the
// child's stdin (then read stdout, then wait) cannot use it. 0.16 also removed
// std.process.Child.init / child.spawn(). This wrapper restores the old
// imperative shape (init -> set *_behavior -> spawn() -> stdin/stdout/stderr ->
// wait()) over std.process.spawn(io, SpawnOptions) with defaultIo(). Same argv,
// same pipe wiring, same wait — behavior and byte output preserved.
pub const Child = struct {
    pub const StdIo = enum { Inherit, Ignore, Pipe, Close };
    pub const Term = std.process.Child.Term;

    // Pipe ends exposed to the caller. Methods take by-value so the common
    // `if (child.stdin) |stdin| { stdin.writeAll(..); stdin.close(); }`
    // capture pattern (const capture) keeps working as it did pre-0.16.
    pub const PipeFile = struct {
        inner: std.Io.File,
        pub fn writeAll(self: PipeFile, bytes: []const u8) !void {
            var wbuf: [4096]u8 = undefined;
            var fw = std.Io.File.Writer.initStreaming(self.inner, defaultIo(), &wbuf);
            try fw.interface.writeAll(bytes);
            try fw.interface.flush();
        }
        pub fn read(self: PipeFile, buffer: []u8) !usize {
            var rbuf: [4096]u8 = undefined;
            var fr = std.Io.File.Reader.initStreaming(self.inner, defaultIo(), &rbuf);
            return fr.interface.readSliceShort(buffer);
        }
        /// Drain the pipe into `buffer` until EOF or `buffer` is full, matching
        /// the old std.fs.File.readAll loop semantics (returns total bytes read).
        pub fn readAll(self: PipeFile, buffer: []u8) !usize {
            var off: usize = 0;
            while (off < buffer.len) {
                const n = try self.read(buffer[off..]);
                if (n == 0) break;
                off += n;
            }
            return off;
        }
        /// Drain the pipe to EOF into a freshly allocated slice (caller owns it),
        /// matching the old std.fs.File.readToEndAlloc semantics.
        pub fn readToEndAlloc(self: PipeFile, allocator: std.mem.Allocator, max: usize) ![]u8 {
            var rbuf: [4096]u8 = undefined;
            var fr = std.Io.File.Reader.initStreaming(self.inner, defaultIo(), &rbuf);
            return fr.interface.allocRemaining(allocator, std.Io.Limit.limited(max));
        }
        pub fn close(self: PipeFile) void {
            self.inner.close(defaultIo());
        }
    };

    argv: []const []const u8,
    allocator: std.mem.Allocator,
    stdin_behavior: StdIo = .Inherit,
    stdout_behavior: StdIo = .Inherit,
    stderr_behavior: StdIo = .Inherit,
    // Old std.process.Child had a settable `env_map: ?*const EnvMap` that, when
    // non-null, replaced the child's environment. 0.16's SpawnOptions spells it
    // `environ_map`; forward it through verbatim (same replace-on-non-null
    // semantics), so the child process sees identical env bytes.
    env_map: ?*const EnvMap = null,

    stdin: ?PipeFile = null,
    stdout: ?PipeFile = null,
    stderr: ?PipeFile = null,

    proc: ?std.process.Child = null,

    pub fn init(argv: []const []const u8, allocator: std.mem.Allocator) Child {
        return .{ .argv = argv, .allocator = allocator };
    }

    fn mapStdIo(b: StdIo) std.process.SpawnOptions.StdIo {
        return switch (b) {
            .Inherit => .inherit,
            .Ignore => .ignore,
            .Pipe => .pipe,
            .Close => .close,
        };
    }

    pub fn spawn(self: *Child) !void {
        const proc = try std.process.spawn(defaultIo(), .{
            .argv = self.argv,
            .stdin = mapStdIo(self.stdin_behavior),
            .stdout = mapStdIo(self.stdout_behavior),
            .stderr = mapStdIo(self.stderr_behavior),
            .environ_map = self.env_map,
        });
        self.proc = proc;
        self.stdin = if (proc.stdin) |f| .{ .inner = f } else null;
        self.stdout = if (proc.stdout) |f| .{ .inner = f } else null;
        self.stderr = if (proc.stderr) |f| .{ .inner = f } else null;
    }

    pub fn wait(self: *Child) !Term {
        return self.proc.?.wait(defaultIo());
    }

    /// Drop-in for the old std.process.Child.spawnAndWait(): spawn the child with
    /// its configured stdio behaviors (default .Inherit) and block until it
    /// terminates, returning its Term. No pipes are drained (matching the old
    /// helper, which is only safe with inherited/ignored stdio).
    pub fn spawnAndWait(self: *Child) !Term {
        try self.spawn();
        return self.wait();
    }

    pub fn kill(self: *Child) void {
        if (self.proc) |*p| p.kill(defaultIo());
    }
};

pub const fs = struct {
    pub const path = std.fs.path;

    pub const File = struct {
        inner: std.Io.File,
        pos: u64 = 0,
        is_stream: bool = false, // stdin/stdout/stderr: stream (no pwrite/seek — pipes ESPIPE)

        pub const Handle = std.Io.File.Handle;
        pub const OpenMode = std.Io.File.OpenMode;
        pub const Mode = std.Io.File.OpenMode;
        pub const Stat = std.Io.File.Stat;
        pub const OpenError = std.Io.File.OpenError;
        pub const SeekError = std.Io.File.SeekError;

        pub fn close(self: *File) void {
            self.inner.close(defaultIo());
        }
        // 0.16 removed std.fs.File.chmod; std.Io.File.setPermissions(io, Permissions)
        // is the equivalent (on POSIX Permissions wraps mode_t via .fromMode). Same
        // fchmod syscall under the hood, so file mode bits are unchanged.
        pub fn chmod(self: *File, new_mode: std.posix.mode_t) !void {
            return self.inner.setPermissions(defaultIo(), std.Io.File.Permissions.fromMode(new_mode));
        }
        pub fn stat(self: *File) !Stat {
            return self.inner.stat(defaultIo());
        }
        pub fn sync(self: *File) !void {
            return self.inner.sync(defaultIo());
        }
        // 0.16 std.Io.File.isTty takes an Io and returns Cancelable!bool. The
        // old std.fs.File.isTty was best-effort (bool). Preserve that: swallow
        // cancellation and report false (matches prior fail-safe semantics).
        pub fn isTty(self: *File) bool {
            return self.inner.isTty(defaultIo()) catch false;
        }
        pub fn getEndPos(self: *File) !u64 {
            const st = try self.inner.stat(defaultIo());
            return st.size;
        }
        pub fn getPos(self: *File) !u64 {
            return self.pos;
        }
        pub fn seekTo(self: *File, p: u64) !void {
            self.pos = p;
        }
        pub fn seekBy(self: *File, amt: i64) !void {
            if (amt < 0) {
                self.pos -|= @intCast(-amt);
            } else self.pos += @intCast(amt);
        }
        pub fn seekFromEnd(self: *File, amt: i64) !void {
            const end = try self.getEndPos();
            if (amt < 0) {
                self.pos = end -| @as(u64, @intCast(-amt));
            } else self.pos = end + @as(u64, @intCast(amt));
        }
        pub fn read(self: *File, buffer: []u8) !usize {
            var rbuf: [4096]u8 = undefined;
            if (self.is_stream) {
                var fr = std.Io.File.Reader.initStreaming(self.inner, defaultIo(), &rbuf);
                const n = try fr.interface.readSliceShort(buffer);
                self.pos += n;
                return n;
            }
            var fr = self.inner.reader(defaultIo(), &rbuf);
            fr.seekTo(self.pos) catch {};
            const n = try fr.interface.readSliceShort(buffer);
            self.pos += n;
            return n;
        }
        pub fn readAll(self: *File, buffer: []u8) !usize {
            var off: usize = 0;
            while (off < buffer.len) {
                const n = try self.read(buffer[off..]);
                if (n == 0) break;
                off += n;
            }
            return off;
        }
        pub fn readToEndAlloc(self: *File, allocator: std.mem.Allocator, max: usize) ![]u8 {
            var rbuf: [4096]u8 = undefined;
            if (self.is_stream) {
                var fr = std.Io.File.Reader.initStreaming(self.inner, defaultIo(), &rbuf);
                return fr.interface.allocRemaining(allocator, std.Io.Limit.limited(max));
            }
            var fr = self.inner.reader(defaultIo(), &rbuf);
            fr.seekTo(self.pos) catch {};
            return fr.interface.allocRemaining(allocator, std.Io.Limit.limited(max));
        }
        pub fn writeAll(self: *File, bytes: []const u8) !void {
            var wbuf: [4096]u8 = undefined;
            if (self.is_stream) {
                var fw = std.Io.File.Writer.initStreaming(self.inner, defaultIo(), &wbuf);
                try fw.interface.writeAll(bytes);
                try fw.interface.flush();
                return;
            }
            var fw = self.inner.writer(defaultIo(), &wbuf);
            fw.pos = self.pos;
            try fw.interface.writeAll(bytes);
            try fw.interface.flush();
            self.pos += bytes.len;
        }
        pub fn write(self: *File, bytes: []const u8) !usize {
            try self.writeAll(bytes);
            return bytes.len;
        }

        // Old-style writer()/reader() — write-through / positioned, old method names.
        pub const Writer = struct {
            file: *File,
            pub const Error = anyerror;
            pub fn writeAll(w: Writer, bytes: []const u8) Error!void {
                return w.file.writeAll(bytes);
            }
            pub fn writeByte(w: Writer, b: u8) Error!void {
                return w.file.writeAll(&[_]u8{b});
            }
            pub fn writeByteNTimes(w: Writer, b: u8, n: usize) Error!void {
                var i: usize = 0;
                while (i < n) : (i += 1) try w.writeByte(b);
            }
            pub fn writeInt(w: Writer, comptime T: type, value: T, endian: std.builtin.Endian) Error!void {
                var tmp: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
                std.mem.writeInt(T, &tmp, value, endian);
                return w.file.writeAll(&tmp);
            }
            pub fn print(w: Writer, comptime fmt: []const u8, args: anytype) Error!void {
                var buf: [4096]u8 = undefined;
                const out = try std.fmt.bufPrint(&buf, fmt, args);
                return w.file.writeAll(out);
            }
            pub fn write(w: Writer, bytes: []const u8) Error!usize {
                try w.file.writeAll(bytes);
                return bytes.len;
            }
        };
        pub const ReaderA = struct {
            file: *File,
            pub const Error = anyerror;
            pub fn read(r: ReaderA, buf: []u8) Error!usize {
                return r.file.read(buf);
            }
            pub fn readAll(r: ReaderA, buf: []u8) Error!usize {
                return r.file.readAll(buf);
            }
            pub fn readByte(r: ReaderA) Error!u8 {
                var b: [1]u8 = undefined;
                const n = try r.file.read(&b);
                if (n == 0) return error.EndOfStream;
                return b[0];
            }
            pub fn readNoEof(r: ReaderA, buf: []u8) Error!void {
                const n = try r.file.readAll(buf);
                if (n != buf.len) return error.EndOfStream;
            }
            pub fn readAllAlloc(r: ReaderA, allocator: std.mem.Allocator, max: usize) Error![]u8 {
                return r.file.readToEndAlloc(allocator, max);
            }
            pub fn readUntilDelimiterOrEof(r: ReaderA, buf: []u8, delimiter: u8) Error!?[]u8 {
                var i: usize = 0;
                while (true) {
                    const byte = r.readByte() catch |err| switch (err) {
                        error.EndOfStream => {
                            if (i == 0) return null;
                            return buf[0..i];
                        },
                        else => return err,
                    };
                    if (byte == delimiter) return buf[0..i];
                    if (i >= buf.len) return error.StreamTooLong;
                    buf[i] = byte;
                    i += 1;
                }
            }
        };
        pub fn writer(self: *File) Writer {
            return .{ .file = self };
        }
        pub fn reader(self: *File) ReaderA {
            return .{ .file = self };
        }
        // 0.16 std.Io.File spells these deprecatedWriter/deprecatedReader; many
        // call sites were migrated to that name. Alias to our adapters.
        pub fn deprecatedWriter(self: *File) Writer {
            return self.writer();
        }
        pub fn deprecatedReader(self: *File) ReaderA {
            return self.reader();
        }

        pub fn stdin() File {
            return .{ .inner = std.Io.File.stdin(), .is_stream = true };
        }
        pub fn stdout() File {
            return .{ .inner = std.Io.File.stdout(), .is_stream = true };
        }
        pub fn stderr() File {
            return .{ .inner = std.Io.File.stderr(), .is_stream = true };
        }
    };

    // Addressable-free stdio writers/readers (the chained
    // `File.stdout().deprecatedWriter()` form yields a temporary that cannot bind
    // the `*File` adapter methods). These hold the File by value and stream.
    pub const StdWriter = struct {
        f: File,
        pub const Error = anyerror;
        pub fn writeAll(self: StdWriter, bytes: []const u8) Error!void {
            var ff = self.f;
            return ff.writeAll(bytes);
        }
        pub fn writeByte(self: StdWriter, b: u8) Error!void {
            var ff = self.f;
            return ff.writeAll(&[_]u8{b});
        }
        pub fn writeByteNTimes(self: StdWriter, b: u8, n: usize) Error!void {
            var i: usize = 0;
            while (i < n) : (i += 1) try self.writeByte(b);
        }
        pub fn writeInt(self: StdWriter, comptime T: type, value: T, endian: std.builtin.Endian) Error!void {
            var tmp: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
            std.mem.writeInt(T, &tmp, value, endian);
            var ff = self.f;
            return ff.writeAll(&tmp);
        }
        pub fn print(self: StdWriter, comptime fmt: []const u8, args: anytype) Error!void {
            var buf: [4096]u8 = undefined;
            const out = try std.fmt.bufPrint(&buf, fmt, args);
            var ff = self.f;
            return ff.writeAll(out);
        }
        pub fn write(self: StdWriter, bytes: []const u8) Error!usize {
            var ff = self.f;
            try ff.writeAll(bytes);
            return bytes.len;
        }
    };
    pub const StdReader = struct {
        f: File,
        pub const Error = anyerror;
        pub fn read(self: StdReader, buf: []u8) Error!usize {
            var ff = self.f;
            return ff.read(buf);
        }
        pub fn readByte(self: StdReader) Error!u8 {
            var ff = self.f;
            var b: [1]u8 = undefined;
            const n = try ff.read(&b);
            if (n == 0) return error.EndOfStream;
            return b[0];
        }
        pub fn readNoEof(self: StdReader, buf: []u8) Error!void {
            var ff = self.f;
            const n = try ff.readAll(buf);
            if (n != buf.len) return error.EndOfStream;
        }
        pub fn readAllAlloc(self: StdReader, allocator: std.mem.Allocator, max: usize) Error![]u8 {
            var ff = self.f;
            return ff.readToEndAlloc(allocator, max);
        }
        pub fn readUntilDelimiterOrEof(self: StdReader, buf: []u8, delimiter: u8) Error!?[]u8 {
            var i: usize = 0;
            while (true) {
                const byte = self.readByte() catch |err| switch (err) {
                    error.EndOfStream => {
                        if (i == 0) return null;
                        return buf[0..i];
                    },
                    else => return err,
                };
                if (byte == delimiter) return buf[0..i];
                if (i >= buf.len) return error.StreamTooLong;
                buf[i] = byte;
                i += 1;
            }
        }
    };
    pub fn stdoutWriter() StdWriter {
        return .{ .f = File.stdout() };
    }
    pub fn stderrWriter() StdWriter {
        return .{ .f = File.stderr() };
    }
    pub fn stdinReader() StdReader {
        return .{ .f = File.stdin() };
    }

    // ── PERSISTENT stdin reader (over-read-safe) ──────────────────────────────
    // CAUTION: the per-call `StdReader`/`stdinReader()` above spins up a FRESH
    // `std.Io.File.Reader` (with a fresh local buffer) on EVERY `read`/`readByte`.
    // 0.16's streaming File.Reader (`readVecStreaming`) issues a single `readv`
    // that fills the caller's bytes AND over-reads the surplus into the reader's
    // *internal* buffer (`r.interface.end += n - data_size`). With a per-call
    // reader that internal buffer is discarded the instant the call returns, so
    // any bytes the kernel handed over beyond the requested count are LOST.
    //
    // For multi-read interactive input this corrupts the stream: a 1-byte
    // `readByte` over a cooked TTY pulls the WHOLE typed line into the throwaway
    // buffer, returns the first byte, and drops the rest (including the '\n'
    // delimiter). The next `readByte` then blocks for fresh input. The net effect
    // is a line-reader that loses every byte after the first of each kernel read.
    //
    // PersistentStdinReader holds ONE `std.Io.File.Reader` with a buffer that
    // OUTLIVES individual reads, so over-read surplus is retained and consumed by
    // the next call — exactly the old (pre-0.16) buffered-reader semantics.
    //
    // Single-threaded use only (stdin is inherently a single shared resource).
    pub const PersistentStdinReader = struct {
        inner: std.Io.File.Reader,
        pub const Error = anyerror;

        pub fn read(self: *PersistentStdinReader, buf: []u8) Error!usize {
            return self.inner.interface.readSliceShort(buf);
        }
        pub fn readByte(self: *PersistentStdinReader) Error!u8 {
            return self.inner.interface.takeByte();
        }
        pub fn readNoEof(self: *PersistentStdinReader, buf: []u8) Error!void {
            return self.inner.interface.readSliceAll(buf);
        }
        /// Read bytes up to (not including) `delimiter` into `buf`. Returns the
        /// filled slice, or null at clean EOF with nothing buffered. Surplus
        /// bytes past the delimiter stay buffered for the next call (no loss).
        /// Matches the old std reader's readUntilDelimiterOrEof contract.
        pub fn readUntilDelimiterOrEof(self: *PersistentStdinReader, buf: []u8, delimiter: u8) Error!?[]const u8 {
            var i: usize = 0;
            while (true) {
                const byte = self.inner.interface.takeByte() catch |err| switch (err) {
                    error.EndOfStream => {
                        if (i == 0) return null;
                        return buf[0..i];
                    },
                    else => return err,
                };
                if (byte == delimiter) return buf[0..i];
                if (i >= buf.len) return error.StreamTooLong;
                buf[i] = byte;
                i += 1;
            }
        }
    };

    // Process-global persistent stdin reader state. The backing buffer must
    // outlive every read, so it is a module-level static. A modest buffer is
    // plenty for interactive line input and bounds the kernel over-read.
    var g_stdin_persist_buf: [4096]u8 = undefined;
    var g_stdin_persist: ?PersistentStdinReader = null;

    /// Return the process-global persistent stdin reader, initializing it on
    /// first use. All interactive line/byte consumers MUST share this single
    /// reader so over-read surplus is preserved across calls. Returns a pointer
    /// to the shared reader (do NOT copy it — copies would fork the buffer).
    pub fn persistentStdin() *PersistentStdinReader {
        if (g_stdin_persist == null) {
            g_stdin_persist = .{
                .inner = std.Io.File.Reader.initStreaming(
                    std.Io.File.stdin(),
                    defaultIo(),
                    &g_stdin_persist_buf,
                ),
            };
        }
        return &g_stdin_persist.?;
    }

    pub const Dir = struct {
        inner: std.Io.Dir,

        pub fn openFile(self: Dir, sub: []const u8, opts: std.Io.Dir.OpenFileOptions) !File {
            return .{ .inner = try self.inner.openFile(defaultIo(), sub, opts) };
        }
        pub fn createFile(self: Dir, sub: []const u8, opts: std.Io.Dir.CreateFileOptions) !File {
            return .{ .inner = try self.inner.createFile(defaultIo(), sub, opts) };
        }
        pub fn makePath(self: Dir, sub: []const u8) !void {
            return self.inner.createDirPath(defaultIo(), sub);
        }
        pub fn makeDir(self: Dir, sub: []const u8) !void {
            return self.inner.createDir(defaultIo(), sub, .default_dir);
        }
        pub fn openDir(self: Dir, sub: []const u8, opts: std.Io.Dir.OpenOptions) !Dir {
            return .{ .inner = try self.inner.openDir(defaultIo(), sub, opts) };
        }
        pub fn deleteFile(self: Dir, sub: []const u8) !void {
            return self.inner.deleteFile(defaultIo(), sub);
        }
        pub fn deleteTree(self: Dir, sub: []const u8) !void {
            return self.inner.deleteTree(defaultIo(), sub);
        }
        pub fn access(self: Dir, sub: []const u8, opts: std.Io.Dir.AccessOptions) !void {
            return self.inner.access(defaultIo(), sub, opts);
        }
        pub fn statFile(self: Dir, sub: []const u8) !std.Io.File.Stat {
            return self.inner.statFile(defaultIo(), sub, .{});
        }
        pub fn readFileAlloc(self: Dir, sub: []const u8, allocator: std.mem.Allocator, max: usize) ![]u8 {
            return self.inner.readFileAlloc(defaultIo(), sub, allocator, std.Io.Limit.limited(max));
        }
        pub fn rename(self: Dir, old_sub: []const u8, new_sub: []const u8) !void {
            return self.inner.rename(old_sub, self.inner, new_sub, defaultIo());
        }
        // 0.16's std.Io.Dir.readLink returns usize (bytes written); the old
        // std.fs.Dir.readLink returned the []u8 slice of the buffer. Restore
        // the slice-returning shape.
        pub fn readLink(self: Dir, sub: []const u8, buffer: []u8) ![]u8 {
            const n = try self.inner.readLink(defaultIo(), sub, buffer);
            return buffer[0..n];
        }
        pub fn close(self: *Dir) void {
            self.inner.close(defaultIo());
        }

        // 0.16's std.Io.Dir.iterate() returns an Iterator whose next(it, io)
        // takes an Io. The old std.fs.Dir.iterate() returned an iterator with
        // next() (no args). Wrap it so `var it = dir.iterate(); it.next()`
        // works unchanged. Entry is the 0.16 std.Io.Dir.Entry (same .name /
        // .kind fields the old API exposed).
        pub const Entry = std.Io.Dir.Entry;
        pub const Iterator = struct {
            inner: std.Io.Dir.Iterator,
            pub fn next(self: *Iterator) !?Entry {
                return self.inner.next(defaultIo());
            }
        };
        pub fn iterate(self: Dir) Iterator {
            return .{ .inner = self.inner.iterate() };
        }
    };

    pub fn cwd() Dir {
        return .{ .inner = std.Io.Dir.cwd() };
    }
    pub fn openFileAbsolute(abs: []const u8, opts: std.Io.Dir.OpenFileOptions) !File {
        return cwd().openFile(abs, opts);
    }
    pub fn createFileAbsolute(abs: []const u8, opts: std.Io.Dir.CreateFileOptions) !File {
        return cwd().createFile(abs, opts);
    }
    pub fn deleteFileAbsolute(abs: []const u8) !void {
        return cwd().deleteFile(abs);
    }
    pub fn openDirAbsolute(abs: []const u8, opts: std.Io.Dir.OpenOptions) !Dir {
        return .{ .inner = try std.Io.Dir.openDirAbsolute(defaultIo(), abs, opts) };
    }
    pub fn accessAbsolute(abs: []const u8, opts: std.Io.Dir.AccessOptions) !void {
        return std.Io.Dir.accessAbsolute(defaultIo(), abs, opts);
    }
};

// ── tests ─────────────────────────────────────────────────────────────────────
test "DebugAllocator works" {
    var gpa = DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();
    const buf = try a.alloc(u8, 8);
    defer a.free(buf);
    try std.testing.expectEqual(@as(usize, 8), buf.len);
}

test "env: read PATH, miss, has" {
    const a = std.testing.allocator;
    const path = try getEnvVarOwned(a, "PATH");
    defer a.free(path);
    try std.testing.expect(path.len > 0);
    try std.testing.expect(hasEnvVar(a, "PATH"));
    try std.testing.expect(!hasEnvVar(a, "TSUNAGI_DEFINITELY_UNSET_XYZ"));
    try std.testing.expectError(error.EnvironmentVariableNotFound, getEnvVarOwned(a, "TSUNAGI_DEFINITELY_UNSET_XYZ"));
    try std.testing.expect(getenv("PATH") != null);
    try std.testing.expect(getenv("TSUNAGI_DEFINITELY_UNSET_XYZ") == null);
    var m = try getEnvMap(a);
    defer m.deinit();
    try std.testing.expect(m.get("PATH") != null);
}

test "FixedBufferStream write path (old API)" {
    var buf: [64]u8 = undefined;
    var fbs = fixedBufferStream(&buf);
    var w = fbs.writer();
    try w.writeAll("ab");
    try w.writeByte('c');
    try w.writeInt(u16, 0x0102, .big);
    try w.print("-{d}", .{42});
    try std.testing.expectEqualStrings("abc\x01\x02-42", fbs.getWritten());
    try std.testing.expectEqual(@as(usize, 8), fbs.getPos());
}

test "FixedBufferStream read path (old API)" {
    const data = [_]u8{ 'x', 0x01, 0x02, 0x03, 0x04, 'y', 'z' };
    var fbs = fixedBufferStream(@as([]const u8, &data));
    var r = fbs.reader();
    try std.testing.expectEqual(@as(u8, 'x'), try r.readByte());
    try std.testing.expectEqual(@as(u32, 0x01020304), try r.readInt(u32, .big));
    var two: [2]u8 = undefined;
    try r.readNoEof(&two);
    try std.testing.expectEqualStrings("yz", &two);
    try std.testing.expectError(error.EndOfStream, r.readByte());
}

test "FixedBufferStream NoSpaceLeft" {
    var buf: [2]u8 = undefined;
    var fbs = fixedBufferStream(&buf);
    var w = fbs.writer();
    try w.writeAll("ab");
    try std.testing.expectError(error.NoSpaceLeft, w.writeByte('c'));
}

test "ListWriter appends" {
    var list = std.array_list.Managed(u8).init(std.testing.allocator);
    defer list.deinit();
    var w = listWriter(&list);
    try w.writeAll("he");
    try w.writeByte('l');
    try w.print("{s}", .{"lo"});
    try w.writeInt(u8, '!', .big);
    try std.testing.expectEqualStrings("hello!", list.items);
}

test "File aliases resolve" {
    _ = IoFile.stdin;
    _ = fs.File.stdin;
    _ = fs.File.stdout;
    _ = fs.File.stderr;
}

test "net surface: types + symbols semantically analyze" {
    // Force semantic analysis of the new net shims without performing real I/O.
    _ = IpAddress;
    _ = Address;
    _ = AddressList;
    _ = &tcpConnectToAddress;
    _ = &tcpConnectToHost;
    _ = &getAddressList;
    _ = &streamProtoReader;
    _ = &streamProtoWriter;
    _ = &StreamProtoReader.read;
    _ = &StreamProtoReader.readByte;
    _ = &StreamProtoReader.readNoEof;
    _ = &StreamProtoReader.readInt;
    _ = &StreamProtoWriter.writeAll;
    _ = &StreamProtoWriter.writeByte;
    _ = &StreamProtoWriter.writeInt;
    _ = &StreamProtoWriter.flush;
    // IpAddress.parse is a pure function — verify the literal path compiles+works.
    const a = try IpAddress.parse("127.0.0.1", 3001);
    try std.testing.expectEqual(@as(u16, 3001), a.getPort());
}

test "time + sleep + mutex shims" {
    const t0 = milliTimestamp();
    try std.testing.expect(t0 > 1_700_000_000_000); // after ~2023 in ms
    try std.testing.expect(timestamp() > 1_700_000_000);
    try std.testing.expect(nanoTimestamp() > 0);
    sleep(1_000); // 1us; must not crash
    var m: Mutex = .{};
    m.lock();
    m.unlock();
    try std.testing.expect(m.tryLock());
    m.unlock();
}

test "fs: makePath + create/writeAll + open/readToEnd + stat + delete" {
    const a = std.testing.allocator;
    const dir = "/tmp/tsunagi_compat_test_dir";
    const file = "/tmp/tsunagi_compat_test_dir/roundtrip.bin";
    fs.cwd().makePath(dir) catch {};
    defer fs.cwd().deleteTree(dir) catch {};

    const payload = "TSUNAGI-0.16-compat-fs-roundtrip\x00\x01\x02";
    {
        var f = try fs.createFileAbsolute(file, .{ .truncate = true });
        defer f.close();
        try f.writeAll(payload);
    }
    {
        var f = try fs.openFileAbsolute(file, .{ .mode = .read_only });
        defer f.close();
        const got = try f.readToEndAlloc(a, 1 << 16);
        defer a.free(got);
        try std.testing.expectEqualSlices(u8, payload, got);
        const end = try f.getEndPos();
        try std.testing.expectEqual(@as(u64, payload.len), end);
    }
    {
        const st = try fs.cwd().statFile(file);
        try std.testing.expectEqual(@as(u64, payload.len), st.size);
    }
    {
        // writer()/reader() adapters (write-through / positioned)
        var f = try fs.createFileAbsolute(file, .{ .truncate = true });
        var w = f.writer();
        try w.writeAll("AB");
        try w.writeByte('C');
        try w.writeInt(u16, 0x0102, .big);
        f.close();
        var rf = try fs.openFileAbsolute(file, .{ .mode = .read_only });
        defer rf.close();
        var r = rf.reader();
        try std.testing.expectEqual(@as(u8, 'A'), try r.readByte());
        var rest: [4]u8 = undefined;
        try r.readNoEof(&rest);
        try std.testing.expectEqualSlices(u8, &[_]u8{ 'B', 'C', 0x01, 0x02 }, &rest);
    }
}

test "PersistentStdinReader: over-read surplus survives across line reads" {
    // Regression: a per-call streaming File reader over-reads a line into a
    // throwaway buffer and loses bytes past the first kernel read. The
    // PersistentStdinReader wraps a SINGLE streaming `std.Io.File.Reader` whose
    // buffer outlives each call, so over-read surplus is retained for the next
    // call. Exercise the exact streaming reader path (the same one stdin uses)
    // over a temp file holding several lines and confirm every line returns
    // intact across separate readUntilDelimiterOrEof calls — no byte loss.
    const io = defaultIo();
    const path = "/tmp/tsunagi_compat_persist_stdin.txt";
    {
        var f = try fs.createFileAbsolute(path, .{ .truncate = true });
        defer f.close();
        try f.writeAll("alpha\nbravo\ncharlie\n");
    }
    defer fs.cwd().deleteFile(path) catch {};

    var f = try fs.openFileAbsolute(path, .{ .mode = .read_only });
    defer f.close();

    var rbuf: [4096]u8 = undefined;
    var reader = fs.PersistentStdinReader{
        .inner = std.Io.File.Reader.initStreaming(f.inner, io, &rbuf),
    };

    var line_buf: [64]u8 = undefined;
    const l1 = (try reader.readUntilDelimiterOrEof(&line_buf, '\n')) orelse return error.UnexpectedEof;
    try std.testing.expectEqualStrings("alpha", l1);
    const l2 = (try reader.readUntilDelimiterOrEof(&line_buf, '\n')) orelse return error.UnexpectedEof;
    try std.testing.expectEqualStrings("bravo", l2);
    const l3 = (try reader.readUntilDelimiterOrEof(&line_buf, '\n')) orelse return error.UnexpectedEof;
    try std.testing.expectEqualStrings("charlie", l3);
    // Clean EOF: nothing buffered -> null.
    const l4 = try reader.readUntilDelimiterOrEof(&line_buf, '\n');
    try std.testing.expect(l4 == null);
}

test "cryptoRandomBytes fills buffer" {
    var buf: [32]u8 = [_]u8{0} ** 32;
    cryptoRandomBytes(&buf);
    var all_zero = true;
    for (buf) |b| {
        if (b != 0) all_zero = false;
    }
    try std.testing.expect(!all_zero);
    // zero-length call must be a no-op (no crash)
    var empty: [0]u8 = undefined;
    cryptoRandomBytes(&empty);
}

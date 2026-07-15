//! `socket_io` — the portable socket-syscall seam for Zap's socket layer
//! (Phase S0 of `docs/socket-implementation-plan.md`, Decision C).
//!
//! This is the ONE place the socket layer performs I/O. It wraps the
//! fork's portable `std.Io.net` API (`IpAddress.connect`/`listen`,
//! `Stream`/`Server`, `netClose`) behind a tiny, gate-agnostic surface:
//! `connectIp4`, `listenIp4`, `closeFd`. It is `@import`ed by BOTH homes of
//! the socket runtime:
//!
//!   * gate-OFF: the always-linked `runtime.zig` `Socket` namespace calls
//!     these inline on the single OS thread (Decision D — no kernel);
//!   * gate-ON: `abi.zig`'s `zap_socket_*` bridge calls them from inside a
//!     blocking-pool trampoline (Decision D — offloaded off the core).
//!
//! Only ONE gate is active per binary, so the lazily-initialized `Io`
//! singleton below exists once per program.
//!
//! ## Why the syscalls live HERE, not in `runtime.zig`
//!
//! The runtime OS-portability gate (`runtime_os_portability_gate.zig`)
//! scans `src/runtime.zig` for raw `std.posix.`/`std.c.` calls — the
//! embedded runtime ships into every user binary, so a per-OS assumption
//! there is a per-OS assumption everywhere. This seam file is NOT the
//! embedded runtime, so it may name `std.Io.net` freely. It goes through
//! the portable `std.Io.net` API end-to-end — including the ephemeral bound
//! port (§7.3's "bind port 0 → local_address"), which the fork surfaces
//! portably as `Socket.address` after `listen`, so NO raw `getsockname` and
//! NO fork contribution is needed (Decision C, R3 resolved: portable
//! `std.Io.net` over the `runtime_os` seam over a fork change).
//!
//! ## S0 scope
//!
//! IPv4 loopback-capable `connect`, an ephemeral `listen` (so a
//! self-contained Zap program can be both ends of a loopback exchange
//! without a second thread — a TCP connect to a listening socket completes
//! via the kernel's accept queue with no `accept` call), and `close`. The
//! full Tier-1 op set (recv/send/shutdown/happy-eyeballs/DNS) is S1+.

const std = @import("std");
const builtin = @import("builtin");
const net = std.Io.net;

/// Opaque fd storage — the same `i64` as `socket_table.Fd`. Declared
/// locally (not imported) so this module has NO relative import: it must
/// register cleanly as an embedded, staged struct-source module for the
/// always-linked runtime (`zap_socket_io`), where a relative `@import`
/// would not resolve against the staging directory. `i64` is a type alias,
/// so values flow freely between this `Fd` and `socket_table.Fd`.
pub const Fd = i64;

/// A stable, gate-crossing failure reason. `abi.zig` passes `@intFromEnum`
/// across the C-ABI to `runtime.zig`, which maps each value to a matchable
/// `SocketError` reason atom (the atom table lives in the runtime, not the
/// kernel — the mapping stays in ONE place). `ok` is success.
pub const Reason = enum(i32) {
    ok = 0,
    connection_refused = 1,
    timed_out = 2,
    host_unreachable = 3,
    network_unreachable = 4,
    connection_reset = 5,
    address_in_use = 6,
    address_unavailable = 7,
    fd_quota_exceeded = 8,
    access_denied = 9,
    network_down = 10,
    out_of_memory = 11,
    other = 99,
};

/// Result of a connect: the fd on success (`reason == .ok`), else the fd is
/// meaningless and `reason` names the failure.
pub const ConnectOutcome = struct {
    reason: Reason,
    fd: Fd,
};

/// Result of a listen: the listener fd and the actual bound port (the
/// ephemeral port the kernel chose when asked for port 0) on success.
pub const ListenOutcome = struct {
    reason: Reason,
    fd: Fd,
    bound_port: u16,
};

// ---------------------------------------------------------------------------
// The process-global blocking-inline Io singleton (Decision C)
// ---------------------------------------------------------------------------

var io_mutex: std.atomic.Mutex = .unlocked;
var io_threaded: std.Io.Threaded = undefined;
var io_ready: bool = false;

/// The lazily-initialized `Io.Threaded` singleton. Its `std.Io.net`
/// operations dispatch INLINE on the calling thread (they are stateless
/// syscall wrappers — no worker thread is spawned unless an async task is
/// submitted, which the socket layer never does), so it is safe to share
/// across the blocking-pool threads gate-ON and correct for the single OS
/// thread gate-OFF. Initialized once (mutex-guarded); it also installs a
/// do-nothing SIGPIPE handler, so a write to a peer-closed socket returns
/// EPIPE rather than killing the process — the right default for a socket
/// layer.
fn io() std.Io {
    while (!io_mutex.tryLock()) std.atomic.spinLoopHint();
    defer io_mutex.unlock();
    if (!io_ready) {
        io_threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
        io_ready = true;
    }
    return io_threaded.io();
}

// ---------------------------------------------------------------------------
// fd <-> bits (portable across posix `fd_t = c_int` and windows `SOCKET`)
// ---------------------------------------------------------------------------

fn fdToBits(handle: net.Socket.Handle) Fd {
    return switch (@typeInfo(net.Socket.Handle)) {
        .int => @intCast(handle),
        .pointer => @intCast(@intFromPtr(handle)),
        else => @compileError("unsupported net.Socket.Handle representation"),
    };
}

fn fdFromBits(bits: Fd) net.Socket.Handle {
    return switch (@typeInfo(net.Socket.Handle)) {
        .int => @intCast(bits),
        .pointer => @ptrFromInt(@as(usize, @intCast(bits))),
        else => @compileError("unsupported net.Socket.Handle representation"),
    };
}

// ---------------------------------------------------------------------------
// Operations
// ---------------------------------------------------------------------------

/// Connect an IPv4 stream socket to `ip:port`. Returns the connected fd or
/// a mapped reason. This function BLOCKS on the calling thread; the caller
/// decides whether that thread is a blocking-pool worker (gate-ON) or the
/// single OS thread (gate-OFF).
///
/// `timeout_ms` (≤ 0 → no timeout) is accepted so the Tier-1 API shape is
/// in place from S0 (Decision E — per-call relative timeouts, NEVER
/// `SO_*TIMEO`). Its ENFORCEMENT is deferred to S1's poll-quantum bounding
/// (§6.1): the fork's `ConnectOptions.timeout` is a `TODO`-panic
/// (`netConnectIpPosix`), so it cannot be used, and poll-quantum connect
/// bounding is S1 scope (the campaign's v1 spans S0–S7). S0's exit gate is
/// loopback, which connects instantly, so the param is not yet load-bearing;
/// passing it through keeps the surface stable across the S1 mechanism swap.
pub fn connectIp4(ip: [4]u8, port: u16, timeout_ms: i64) ConnectOutcome {
    _ = timeout_ms; // S0: accepted for API shape; enforced by poll-quantum in S1 (§6.1).
    const address = net.IpAddress{ .ip4 = .{ .bytes = ip, .port = port } };
    const stream = address.connect(io(), .{ .mode = .stream, .timeout = .none }) catch |err|
        return .{ .reason = mapConnectError(err), .fd = 0 };
    return .{ .reason = .ok, .fd = fdToBits(stream.socket.handle) };
}

/// Bind + listen an IPv4 stream socket on `ip:port` (port 0 → an ephemeral
/// port the kernel chooses, reported as `bound_port`). `SO_REUSEADDR` is
/// set so a just-closed test port is immediately reusable. This is the S0
/// minimal listener: enough for a self-contained loopback connect (the
/// connection completes in the kernel's accept queue without an `accept`
/// call). The distinct `Socket.Listener` type + `accept` are S1/S3.
pub fn listenIp4(ip: [4]u8, port: u16, backlog: u31) ListenOutcome {
    const address = net.IpAddress{ .ip4 = .{ .bytes = ip, .port = port } };
    const server = address.listen(io(), .{
        .kernel_backlog = backlog,
        .reuse_address = true,
    }) catch |err|
        return .{ .reason = mapListenError(err), .fd = 0, .bound_port = 0 };
    // The fork surfaces the resolved (ephemeral) bound port portably in
    // `Socket.address` after `listen` — no `getsockname` needed.
    const bound_port = switch (server.socket.address) {
        .ip4 => |resolved| resolved.port,
        .ip6 => |resolved| resolved.port,
    };
    return .{ .reason = .ok, .fd = fdToBits(server.socket.handle), .bound_port = bound_port };
}

/// Close a socket fd through the portable `std.Io.net` close.
pub fn closeFd(fd: Fd) void {
    const the_io = io();
    var handle = fdFromBits(fd);
    the_io.vtable.netClose(the_io.userdata, (&handle)[0..1]);
}

// ---------------------------------------------------------------------------
// Internal
// ---------------------------------------------------------------------------

fn mapConnectError(err: net.IpAddress.ConnectError) Reason {
    return switch (err) {
        error.ConnectionRefused => .connection_refused,
        error.Timeout => .timed_out,
        error.HostUnreachable => .host_unreachable,
        error.NetworkUnreachable => .network_unreachable,
        error.ConnectionResetByPeer => .connection_reset,
        error.AddressUnavailable => .address_unavailable,
        error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => .fd_quota_exceeded,
        error.AccessDenied => .access_denied,
        error.NetworkDown => .network_down,
        error.SystemResources => .out_of_memory,
        else => .other,
    };
}

fn mapListenError(err: net.IpAddress.ListenError) Reason {
    return switch (err) {
        error.AddressInUse => .address_in_use,
        error.AddressUnavailable => .address_unavailable,
        error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => .fd_quota_exceeded,
        error.NetworkDown => .network_down,
        error.SystemResources => .out_of_memory,
        else => .other,
    };
}

// ---------------------------------------------------------------------------
// Tests — a real loopback connect/close on the host (macOS/Linux CI).
// ---------------------------------------------------------------------------

const testing = std.testing;

test "socket_io: loopback listen + connect + close round-trips on an ephemeral port" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const listener = listenIp4(.{ 127, 0, 0, 1 }, 0, 128);
    try testing.expectEqual(Reason.ok, listener.reason);
    try testing.expect(listener.bound_port != 0);
    defer closeFd(listener.fd);

    const client = connectIp4(.{ 127, 0, 0, 1 }, listener.bound_port, 5000);
    try testing.expectEqual(Reason.ok, client.reason);
    closeFd(client.fd);
}

test "socket_io: connect to a closed port fails (not .ok), never hangs" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    // Bind+close to obtain a port nothing is listening on, then connect.
    const listener = listenIp4(.{ 127, 0, 0, 1 }, 0, 1);
    try testing.expectEqual(Reason.ok, listener.reason);
    const dead_port = listener.bound_port;
    closeFd(listener.fd);

    const client = connectIp4(.{ 127, 0, 0, 1 }, dead_port, 1000);
    try testing.expect(client.reason != .ok);
}

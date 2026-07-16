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
// Poll-quantum-bounded stream I/O (Phase S1, §6.1 / Decision E)
//
// ALL v1 timeout enforcement is a `poll(2)`-with-timeout quantum loop — NEVER
// `SO_RCVTIMEO`/`SO_SNDTIMEO` (OTP documents those as unreliable under a
// nonblocking implementation). One mechanism gives three properties at once:
//   (c) the caller's `timeout_ms` (a timeout does NOT close the socket —
//       Erlang semantics; the socket stays usable);
//   (b) kill-responsiveness — the `kill_flag` (the owning process's
//       `pending_kill` atomic, captured on-core before the blocking offload)
//       is observed once per quantum, so a blocked leaf yields promptly to
//       teardown instead of pinning a pool thread until the peer speaks;
//   (a) shutdown-quiesce — a bounded quantum means an "infinite" leaf still
//       wakes every `poll_quantum_ms` to re-observe the world.
// The blocking pool keeps the fd in its default BLOCKING mode: we poll for
// readiness FIRST and only then issue the (now non-blocking-in-effect) read,
// so `netRead`'s "EAGAIN is a bug" contract is never violated.
// ---------------------------------------------------------------------------

/// The re-attach / re-observe quantum (§5, v1): each poll waits at most this
/// long before the leaf re-checks the deadline and the kill flag.
const poll_quantum_ms: i32 = 100;

/// The outcome of a `recv`: a stable, gate-crossing status plus the number of
/// bytes deposited in the caller's buffer.
///
///   * `status == 0` — a CHUNK: `bytes_filled >= 1` bytes are in the buffer.
///   * `status == -1` — CLOSED: clean EOF (`recv()==0`), the footgun the
///     `SocketRecv.Closed` constructor turns into an exhaustive-`case` arm.
///   * `status > 0` — FAILED: the value is a `Reason` code (`timed_out == 2`
///     is the idle-timeout case), which the runtime maps to a `SocketError`
///     reason atom.
pub const RecvOutcome = struct {
    status: i32,
    bytes_filled: usize,
};

const recv_status_chunk: i32 = 0;
const recv_status_closed: i32 = -1;

/// Receive into `buffer` with poll-quantum bounding. When `exact` is true the
/// leaf accumulates until `buffer.len` bytes have arrived (the `recv_exact`
/// semantics — a short read ending in EOF returns CLOSED); when false it
/// returns after the first non-empty read (next-available). `timeout_ms <= 0`
/// means "no deadline" (the leaf still wakes each quantum to honour a kill).
/// `kill_flag`, when non-null, is the owning process's `pending_kill` atomic.
///
/// BLOCKS on the calling thread (a blocking-pool worker gate-ON, the single
/// OS thread gate-OFF). Never closes the fd — a timeout leaves the socket
/// fully usable.
pub fn recv(
    fd: Fd,
    buffer: []u8,
    exact: bool,
    timeout_ms: i64,
    kill_flag: ?*std.atomic.Value(bool),
) RecvOutcome {
    if (buffer.len == 0) return .{ .status = recv_status_chunk, .bytes_filled = 0 };
    const the_io = io();
    const handle = fdFromBits(fd);
    var filled: usize = 0;
    // Elapsed time is tracked by SUMMING the quantum spent on each poll-timeout
    // iteration (each `.timeout` consumed exactly `quantum` ms) — no monotonic
    // clock is needed, which keeps this portable across the embedded std
    // (`std.time.Timer` is not in every bundled std). A `.ready` iteration
    // returns immediately, so its sub-quantum wait never needs accounting.
    var elapsed_ms: i64 = 0;
    while (true) {
        if (kill_flag) |flag| {
            if (flag.load(.acquire)) return .{ .status = recv_status_closed, .bytes_filled = filled };
        }
        var quantum: i32 = poll_quantum_ms;
        if (timeout_ms > 0) {
            const remaining = timeout_ms - elapsed_ms;
            if (remaining <= 0) return .{ .status = @intFromEnum(Reason.timed_out), .bytes_filled = filled };
            if (remaining < quantum) quantum = @intCast(remaining);
        }
        switch (waitReadable(handle, quantum)) {
            .timeout => {
                elapsed_ms += quantum; // this quantum's full wait elapsed
                continue; // re-check deadline + kill
            },
            .failed => return .{ .status = @intFromEnum(Reason.other), .bytes_filled = filled },
            .ready => {},
        }
        var iovec = [1][]u8{buffer[filled..]};
        const read_count = the_io.vtable.netRead(the_io.userdata, handle, iovec[0..]) catch |err|
            return .{ .status = @intFromEnum(mapReadError(err)), .bytes_filled = filled };
        if (read_count == 0) {
            // Clean EOF. For an exact read that already saw bytes, the stream
            // ended mid-frame — still CLOSED (the caller asked for N and the
            // peer is done); the partial `filled` is reported so a caller can
            // observe how much arrived before the close.
            return .{ .status = recv_status_closed, .bytes_filled = filled };
        }
        filled += read_count;
        if (!exact) return .{ .status = recv_status_chunk, .bytes_filled = filled };
        if (filled >= buffer.len) return .{ .status = recv_status_chunk, .bytes_filled = filled };
        // Exact but not yet full — keep pulling within the same deadline.
    }
}

/// The outcome of a `send`: `ok` on full delivery, else a mapped reason, with
/// `bytes_sent` reporting how much of the payload committed before the failure
/// (the Erlang `{timeout, RestData}` lesson — the caller learns the boundary).
pub const SendOutcome = struct {
    reason: Reason,
    bytes_sent: usize,
};

/// Send ALL of `bytes` or report the failure with the committed byte count
/// (all-or-error, `Socket.send`). Blocking writes park in the kernel, so
/// backpressure is automatic. An empty payload succeeds trivially.
pub fn send(fd: Fd, bytes: []const u8) SendOutcome {
    const the_io = io();
    const handle = fdFromBits(fd);
    var sent: usize = 0;
    while (sent < bytes.len) {
        const written = writeOnce(the_io, handle, bytes[sent..]) catch |err|
            return .{ .reason = mapWriteError(err), .bytes_sent = sent };
        if (written == 0) return .{ .reason = .connection_reset, .bytes_sent = sent };
        sent += written;
    }
    return .{ .reason = .ok, .bytes_sent = bytes.len };
}

/// Send whatever the kernel accepts in ONE write (explicit partial send —
/// `Socket.send_some`). Returns the bytes actually written (`>= 1` on success
/// for a non-empty payload); the caller decides how to handle a short write.
pub fn sendSome(fd: Fd, bytes: []const u8) SendOutcome {
    if (bytes.len == 0) return .{ .reason = .ok, .bytes_sent = 0 };
    const the_io = io();
    const handle = fdFromBits(fd);
    const written = writeOnce(the_io, handle, bytes) catch |err|
        return .{ .reason = mapWriteError(err), .bytes_sent = 0 };
    if (written == 0) return .{ .reason = .connection_reset, .bytes_sent = 0 };
    return .{ .reason = .ok, .bytes_sent = written };
}

/// Half-close (`Socket.shutdown`): `how` is `0` = read, `1` = write, `2` =
/// both. Does NOT recycle the domain slot — the handle stays valid after
/// `shutdown(:write)` so the graceful-close handshake (write EOF, keep
/// reading the peer's remaining bytes to its EOF) works.
pub fn shutdownFd(fd: Fd, how: i32) Reason {
    const the_io = io();
    const handle = fdFromBits(fd);
    const how_enum: net.ShutdownHow = switch (how) {
        0 => .recv,
        1 => .send,
        else => .both,
    };
    the_io.vtable.netShutdown(the_io.userdata, handle, how_enum) catch |err|
        return mapShutdownError(err);
    return .ok;
}

/// The outcome of an `accept`: the accepted connection's fd plus the peer's
/// IPv4 endpoint (for the accepted socket's `peer_address`), or a mapped
/// reason. Poll-quantum bounded on the listener fd, so a blocked acceptor is
/// kill-responsive (the S3 graceful-drain seam).
pub const AcceptOutcome = struct {
    reason: Reason,
    fd: Fd,
    peer: AddressV4,
};

/// Accept one connection from a listening socket, blocking (poll-quantum
/// bounded, kill-checked) until one arrives.
pub fn accept(fd: Fd, kill_flag: ?*std.atomic.Value(bool)) AcceptOutcome {
    const the_io = io();
    const listen_handle = fdFromBits(fd);
    while (true) {
        if (kill_flag) |flag| {
            if (flag.load(.acquire)) return .{ .reason = .other, .fd = 0, .peer = AddressV4.none };
        }
        switch (waitReadable(listen_handle, poll_quantum_ms)) {
            .timeout => continue,
            .failed => return .{ .reason = .other, .fd = 0, .peer = AddressV4.none },
            .ready => {},
        }
        // `net.Server.AcceptOptions` is `void` on some targets (e.g. macOS) and
        // a struct on others — pass the right default for either shape.
        const accept_options: net.Server.AcceptOptions = if (net.Server.AcceptOptions == void) {} else .{};
        const accepted = the_io.vtable.netAccept(the_io.userdata, listen_handle, accept_options) catch |err|
            return .{ .reason = mapAcceptError(err), .fd = 0, .peer = AddressV4.none };
        const peer = switch (accepted.address) {
            .ip4 => |ip4| AddressV4{ .a = ip4.bytes[0], .b = ip4.bytes[1], .c = ip4.bytes[2], .d = ip4.bytes[3], .port = ip4.port, .ok = true },
            .ip6 => AddressV4.none,
        };
        return .{ .reason = .ok, .fd = fdToBits(accepted.handle), .peer = peer };
    }
}

/// A resolved IPv4 endpoint (for `local_address`/`peer_address`). `ok` is
/// false when the socket is unbound/unconnected or bound to a non-IPv4 family
/// (S1 surfaces IPv4; the S2 datagram/IPv6 work broadens it).
pub const AddressV4 = struct {
    a: u8,
    b: u8,
    c: u8,
    d: u8,
    port: u16,
    ok: bool,

    pub const none = AddressV4{ .a = 0, .b = 0, .c = 0, .d = 0, .port = 0, .ok = false };
};

/// The local (bound) IPv4 endpoint of `fd` via `getsockname`.
pub fn localAddress(fd: Fd) AddressV4 {
    return nameAddress(fd, .local);
}

/// The remote (peer) IPv4 endpoint of `fd` via `getpeername`.
pub fn peerAddress(fd: Fd) AddressV4 {
    return nameAddress(fd, .peer);
}

// ---------------------------------------------------------------------------
// Internal
// ---------------------------------------------------------------------------

/// The tri-state of one poll-quantum wait.
const ReadyState = enum { ready, timeout, failed };

/// Wait up to `quantum_ms` for `handle` to become readable (or hang up /
/// error, which `poll` reports in `revents` unconditionally so the following
/// read observes EOF/error). On the poll-less targets (Windows/wasi — not in
/// v1's run scope; gate-ON Windows is blocked on the concurrency campaign's
/// 7.2a port, wasi rejects socket code at compile time) this reports `ready`
/// so the subsequent blocking read simply blocks — the poll-quantum timeout is
/// a documented no-op there, never a correctness break.
fn waitReadable(handle: net.Socket.Handle, quantum_ms: i32) ReadyState {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        return .ready;
    }
    var poll_fds = [1]std.posix.pollfd{.{
        .fd = handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready_count = std.posix.poll(poll_fds[0..], quantum_ms) catch return .failed;
    return if (ready_count == 0) .timeout else .ready;
}

/// One `netWrite` of `bytes` (no header, no splat). Returns bytes accepted.
fn writeOnce(the_io: std.Io, handle: net.Socket.Handle, bytes: []const u8) net.Stream.Writer.Error!usize {
    const data = [1][]const u8{bytes};
    return the_io.vtable.netWrite(the_io.userdata, handle, &.{}, data[0..], 1);
}

const NameKind = enum { local, peer };

/// Resolve the local or peer endpoint through the raw `getsockname`/
/// `getpeername` (portable across the posix targets; not scanned by the
/// runtime OS-portability gate, which covers only `src/runtime.zig`). IPv4
/// only in S1.
fn nameAddress(fd: Fd, kind: NameKind) AddressV4 {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        return AddressV4.none;
    }
    const handle: std.posix.fd_t = fdFromBits(fd);
    var storage: std.posix.sockaddr.storage = undefined;
    var address_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.storage);
    const sockaddr_ptr: *std.posix.sockaddr = @ptrCast(&storage);
    const return_code = switch (kind) {
        .local => std.posix.system.getsockname(handle, sockaddr_ptr, &address_len),
        .peer => std.posix.system.getpeername(handle, sockaddr_ptr, &address_len),
    };
    if (std.posix.errno(return_code) != .SUCCESS) return AddressV4.none;
    if (sockaddr_ptr.family != std.posix.AF.INET) return AddressV4.none;
    const in: *const std.posix.sockaddr.in = @ptrCast(@alignCast(&storage));
    const octets: [4]u8 = @bitCast(in.addr); // network byte order = a.b.c.d
    const port = std.mem.bigToNative(u16, in.port);
    return .{ .a = octets[0], .b = octets[1], .c = octets[2], .d = octets[3], .port = port, .ok = true };
}

fn mapReadError(err: net.Stream.Reader.Error) Reason {
    return switch (err) {
        error.ConnectionResetByPeer => .connection_reset,
        error.Timeout => .timed_out,
        error.SocketUnconnected => .connection_reset,
        error.AccessDenied => .access_denied,
        error.NetworkDown => .network_down,
        error.SystemResources => .out_of_memory,
        else => .other,
    };
}

fn mapWriteError(err: net.Stream.Writer.Error) Reason {
    return switch (err) {
        error.ConnectionResetByPeer => .connection_reset,
        error.ConnectionRefused => .connection_refused,
        error.NetworkUnreachable => .network_unreachable,
        error.HostUnreachable => .host_unreachable,
        error.NetworkDown => .network_down,
        error.SocketUnconnected, error.SocketNotBound => .connection_reset,
        error.SystemResources => .out_of_memory,
        else => .other,
    };
}

fn mapShutdownError(err: net.ShutdownError) Reason {
    return switch (err) {
        error.ConnectionResetByPeer, error.ConnectionAborted => .connection_reset,
        error.SocketUnconnected => .connection_reset,
        error.NetworkDown => .network_down,
        error.SystemResources => .out_of_memory,
        else => .other,
    };
}

fn mapAcceptError(err: net.Server.AcceptError) Reason {
    return switch (err) {
        error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => .fd_quota_exceeded,
        error.SocketNotListening => .connection_reset,
        error.ConnectionAborted => .connection_reset,
        error.NetworkDown => .network_down,
        error.SystemResources => .out_of_memory,
        else => .other,
    };
}

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

test "socket_io: accept + full-duplex send/recv echo, binary-safe payload, then EOF on shutdown(write)" {
    if (builtin.os.tag == .wasi or builtin.os.tag == .windows) return error.SkipZigTest;

    const listener = listenIp4(.{ 127, 0, 0, 1 }, 0, 8);
    try testing.expectEqual(Reason.ok, listener.reason);
    defer closeFd(listener.fd);

    const client = connectIp4(.{ 127, 0, 0, 1 }, listener.bound_port, 5000);
    try testing.expectEqual(Reason.ok, client.reason);
    defer closeFd(client.fd);

    const accepted = accept(listener.fd, null);
    try testing.expectEqual(Reason.ok, accepted.reason);
    defer closeFd(accepted.fd);
    try testing.expect(accepted.peer.ok);
    try testing.expectEqual(@as(u8, 127), accepted.peer.a);

    // Binary-safe payload: embedded NUL and a non-UTF-8 byte (0xFF).
    const payload = [_]u8{ 'h', 'i', 0, 0xFF, 'z' };
    const sent = send(client.fd, payload[0..]);
    try testing.expectEqual(Reason.ok, sent.reason);
    try testing.expectEqual(payload.len, sent.bytes_sent);

    var recv_buffer: [64]u8 = undefined;
    const received = recv(accepted.fd, recv_buffer[0..payload.len], true, 5000, null);
    try testing.expectEqual(@as(i32, recv_status_chunk), received.status);
    try testing.expectEqual(payload.len, received.bytes_filled);
    try testing.expectEqualSlices(u8, payload[0..], recv_buffer[0..payload.len]);

    // Server → client the other way (full duplex on one connection, no split).
    const reply = send(accepted.fd, "pong");
    try testing.expectEqual(Reason.ok, reply.reason);
    var reply_buffer: [16]u8 = undefined;
    const got_reply = recv(client.fd, reply_buffer[0..], false, 5000, null);
    try testing.expectEqual(@as(i32, recv_status_chunk), got_reply.status);
    try testing.expectEqualSlices(u8, "pong", reply_buffer[0..got_reply.bytes_filled]);

    // Half-close: client shuts down its write side; the server reads EOF
    // (CLOSED), and the client handle stays valid (graceful handshake).
    try testing.expectEqual(Reason.ok, shutdownFd(client.fd, 1));
    const eof = recv(accepted.fd, recv_buffer[0..], false, 5000, null);
    try testing.expectEqual(@as(i32, recv_status_closed), eof.status);
    try testing.expectEqual(@as(usize, 0), eof.bytes_filled);

    // The local endpoint of the accepted socket is the loopback listener port.
    const local = localAddress(accepted.fd);
    try testing.expect(local.ok);
    try testing.expectEqual(listener.bound_port, local.port);
}

test "socket_io: recv idle-timeout returns timed_out WITHOUT closing the socket" {
    if (builtin.os.tag == .wasi or builtin.os.tag == .windows) return error.SkipZigTest;

    const listener = listenIp4(.{ 127, 0, 0, 1 }, 0, 8);
    try testing.expectEqual(Reason.ok, listener.reason);
    defer closeFd(listener.fd);
    const client = connectIp4(.{ 127, 0, 0, 1 }, listener.bound_port, 5000);
    try testing.expectEqual(Reason.ok, client.reason);
    defer closeFd(client.fd);
    const accepted = accept(listener.fd, null);
    try testing.expectEqual(Reason.ok, accepted.reason);
    defer closeFd(accepted.fd);

    // Nothing was sent — the recv must time out (never hang), reporting the
    // timed_out reason, and the socket must still be usable afterwards.
    var recv_buffer: [16]u8 = undefined;
    const timed = recv(accepted.fd, recv_buffer[0..], false, 150, null);
    try testing.expectEqual(@as(i32, @intFromEnum(Reason.timed_out)), timed.status);

    // Prove the socket survived the timeout: a subsequent send/recv works.
    _ = send(client.fd, "after");
    const after = recv(accepted.fd, recv_buffer[0..], false, 5000, null);
    try testing.expectEqual(@as(i32, recv_status_chunk), after.status);
    try testing.expectEqualSlices(u8, "after", recv_buffer[0..after.bytes_filled]);
}

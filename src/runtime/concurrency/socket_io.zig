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
    /// The host name could not be resolved to any address (DNS `NXDOMAIN` /
    /// `getaddrinfo` `EAI_NONAME`), or resolution returned no usable address.
    unknown_host = 12,
    /// The supplied host name is syntactically invalid (RFC 1123) — rejected
    /// at the seam before any resolver call.
    invalid_argument = 13,
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

/// Connect an IPv4 stream socket to `ip:port`, bounded by `timeout_ms` and
/// the owning process's `kill_flag`. Returns the connected fd or a mapped
/// reason. This function BLOCKS on the calling thread; the caller decides
/// whether that thread is a blocking-pool worker (gate-ON) or the single OS
/// thread (gate-OFF).
///
/// `timeout_ms` (≤ 0 → no deadline) is a per-call RELATIVE timeout, enforced
/// by the same poll-quantum loop `recv`/`send` use — NEVER `SO_*TIMEO`
/// (Decision E, §6.1). A blocking `connect(2)` to a black-hole address blocks
/// on the OS default (~127 s) with the owning process UNKILLABLE and a pool
/// thread pinned; instead we do a NON-BLOCKING connect (set `O_NONBLOCK`,
/// `connect` → `EINPROGRESS`) and poll `POLL.OUT` in `poll_quantum_ms`
/// quanta, re-checking an ABSOLUTE monotonic deadline and the `kill_flag`
/// each quantum, then read `SO_ERROR` on wake to learn the outcome and
/// restore blocking mode. A timeout does NOT leak the fd (it is closed on the
/// error path); a live connected fd is never `0`.
///
/// The fork's portable `IpAddress.connect` cannot do this (its
/// `ConnectOptions.timeout` is a `TODO`-panic in `netConnectIpPosix`), so the
/// posix path issues the socket syscalls directly — legitimate here because
/// this file IS the socket syscall seam (per-OS calls are its whole purpose,
/// exactly like `waitReadable`/`nameAddress`). The poll-less targets
/// (Windows/wasi — not in v1 run scope) keep the blocking `IpAddress.connect`
/// with the timeout a documented no-op, the same posture `waitReadable` takes.
pub fn connectIp4(ip: [4]u8, port: u16, timeout_ms: i64, kill_flag: ?*std.atomic.Value(bool)) ConnectOutcome {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        // Poll-less targets (not in v1 run scope): blocking connect, the
        // timeout/kill a documented no-op — `timeout_ms`/`kill_flag` remain
        // "used" via the comptime-dead posix path below (no discard needed,
        // exactly like `waitReadable`'s params on these targets).
        const address = net.IpAddress{ .ip4 = .{ .bytes = ip, .port = port } };
        const stream = address.connect(io(), .{ .mode = .stream, .timeout = .none }) catch |err|
            return .{ .reason = mapConnectError(err), .fd = 0 };
        return .{ .reason = .ok, .fd = fdToBits(stream.socket.handle) };
    }
    return connectSingle(.{ .ip4 = .{ .bytes = ip, .port = port } }, timeout_ms, kill_flag);
}

/// Connect an IPv6 stream socket to `bytes:port` (`bytes` big-endian, the
/// `Ip6Address.bytes` layout), bounded by `timeout_ms` and `kill_flag`
/// EXACTLY like `connectIp4` (Option A — real IPv6 in the happy-eyeballs
/// race). `scope_id` is the link-local zone index (`0` = none) and `flow`
/// the flow label. The posix path is a raw non-blocking `socket(AF_INET6)` +
/// `connect(sockaddr_in6)` → EINPROGRESS → `POLL.OUT` quantum loop over the
/// absolute monotonic deadline, sharing the very machinery `connectIp4` uses.
pub fn connectIp6(bytes: [16]u8, port: u16, scope_id: u32, flow: u32, timeout_ms: i64, kill_flag: ?*std.atomic.Value(bool)) ConnectOutcome {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        const address = net.IpAddress{ .ip6 = .{ .bytes = bytes, .port = port, .flow = flow, .interface = .{ .index = scope_id } } };
        const stream = address.connect(io(), .{ .mode = .stream, .timeout = .none }) catch |err|
            return .{ .reason = mapConnectError(err), .fd = 0 };
        return .{ .reason = .ok, .fd = fdToBits(stream.socket.handle) };
    }
    return connectSingle(.{ .ip6 = .{ .bytes = bytes, .port = port, .flow = flow, .interface = .{ .index = scope_id } } }, timeout_ms, kill_flag);
}

/// The posix non-blocking single-address connect (behind `connectIp4`/
/// `connectIp6`). Issues the connect via the shared `startAttempt` primitive,
/// then — for an EINPROGRESS attempt — hands the fd to `awaitConnect`, which
/// polls `POLL.OUT` in deadline-and-kill-bounded quanta until `SO_ERROR`
/// reports the outcome and restores blocking mode. An immediate connect
/// (common on loopback) restores blocking and returns the live fd directly.
fn connectSingle(address: net.IpAddress, timeout_ms: i64, kill_flag: ?*std.atomic.Value(bool)) ConnectOutcome {
    const start = startAttempt(address);
    switch (start.state) {
        .failed => return .{ .reason = start.reason, .fd = 0 },
        .connected => {
            restoreBlocking(start.fd);
            return .{ .reason = .ok, .fd = fdToBits(start.fd) };
        },
        .in_progress => return awaitConnect(start.fd, timeout_ms, kill_flag),
    }
}

/// The state of one just-issued non-blocking connect (`startAttempt`).
const AttemptState = enum { connected, in_progress, failed };

/// The result of issuing one non-blocking connect: `.connected` = finished
/// synchronously, `fd` live (non-blocking; the caller restores blocking);
/// `.in_progress` = EINPROGRESS, `fd` the pending socket to poll `POLL.OUT`;
/// `.failed` = socket-create or a hard connect error, `fd` already CLOSED and
/// `reason` naming the failure.
const AttemptStart = struct { fd: net.Socket.Handle, state: AttemptState, reason: Reason };

/// Create a non-blocking stream socket for `address`'s family and ISSUE a
/// connect, returning immediately WITHOUT waiting for completion — the single
/// socket-create + connect-issue primitive shared by the single-address
/// connects (`connectSingle`) and the happy-eyeballs racing driver
/// (`raceConnectPosix`). On any create/connect-issue failure the transient fd
/// is closed here, so a `.failed` result never leaks a fd. Posix-only (the
/// non-blocking connect path); the poll-less targets use the blocking
/// `IpAddress.connect` fallback in `connectIp4`/`connectIp6`.
fn startAttempt(address: net.IpAddress) AttemptStart {
    const socket_rc = switch (address) {
        .ip4 => std.posix.system.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, std.posix.IPPROTO.TCP),
        .ip6 => std.posix.system.socket(std.posix.AF.INET6, std.posix.SOCK.STREAM, std.posix.IPPROTO.TCP),
    };
    if (std.posix.errno(socket_rc) != .SUCCESS)
        return .{ .fd = 0, .state = .failed, .reason = mapSocketCreateErrno(socket_rc) };
    const handle: net.Socket.Handle = @intCast(socket_rc);
    // Flip to non-blocking so `connect` returns EINPROGRESS instead of blocking.
    if (!setNonBlocking(handle)) {
        _ = std.posix.system.close(handle);
        return .{ .fd = 0, .state = .failed, .reason = .other };
    }
    const sa = buildSockAddr(address);
    const connect_rc = std.posix.system.connect(handle, @ptrCast(&sa.storage), sa.len);
    switch (std.posix.errno(connect_rc)) {
        // Connected immediately (common on loopback).
        .SUCCESS => return .{ .fd = handle, .state = .connected, .reason = .ok },
        // In progress — the caller polls for completion. (`EWOULDBLOCK` ==
        // `EAGAIN` on posix, so it is covered by `.AGAIN`.)
        .INPROGRESS, .INTR, .AGAIN => return .{ .fd = handle, .state = .in_progress, .reason = .ok },
        else => |connect_errno| {
            _ = std.posix.system.close(handle);
            return .{ .fd = 0, .state = .failed, .reason = mapConnectErrno(connect_errno) };
        },
    }
}

/// Await completion of an in-progress non-blocking connect on `handle` (the
/// shared completion tail of `connectSingle`). Polls `POLL.OUT` in
/// `poll_quantum_ms` quanta bounded by an ABSOLUTE monotonic deadline (HIGH-3,
/// dribble-proof) and the `kill_flag` (HIGH-2), reads `SO_ERROR` on wake for
/// the verdict, and RESTORES blocking mode on success so the returned fd is
/// compatible with the poll-then-blocking `recv`. On ANY non-success exit
/// (failure/timeout/kill/`getsockopt`-error) it CLOSES `handle` on THIS thread
/// — the transient fd never reaches the fiber continuation a kill teardown
/// would skip (HIGH-1) — and returns the reason with `fd = 0`. On success fd
/// ownership transfers to the caller.
fn awaitConnect(handle: net.Socket.Handle, timeout_ms: i64, kill_flag: ?*std.atomic.Value(bool)) ConnectOutcome {
    const has_deadline = timeout_ms > 0;
    const deadline_ms: i64 = if (has_deadline) checkedDeadline(monotonicMillis(), timeout_ms) else 0;
    while (true) {
        if (kill_flag) |flag| {
            if (flag.load(.acquire)) {
                _ = std.posix.system.close(handle);
                return .{ .reason = .other, .fd = 0 };
            }
        }
        var quantum: i32 = poll_quantum_ms;
        if (has_deadline) {
            const remaining = deadline_ms - monotonicMillis();
            if (remaining <= 0) {
                _ = std.posix.system.close(handle);
                return .{ .reason = .timed_out, .fd = 0 };
            }
            if (remaining < quantum) quantum = @intCast(remaining);
        }
        switch (waitWritable(handle, quantum)) {
            .timeout => continue, // re-check deadline + kill
            .failed => {
                _ = std.posix.system.close(handle);
                return .{ .reason = .other, .fd = 0 };
            },
            .ready => {},
        }
        // Writable (or POLLERR/POLLHUP): `SO_ERROR` carries the verdict.
        const pending = soError(handle);
        if (pending == 0) {
            // Connected — but if a kill became visible right as the connect
            // completed (the "succeeds exactly at kill" residual race, HIGH-1),
            // do NOT hand the live fd back to a tearing-down process: close the
            // transient fd here so it never reaches the skipped continuation.
            if (kill_flag) |flag| {
                if (flag.load(.acquire)) {
                    _ = std.posix.system.close(handle);
                    return .{ .reason = .other, .fd = 0 };
                }
            }
            restoreBlocking(handle);
            return .{ .reason = .ok, .fd = fdToBits(handle) };
        }
        _ = std.posix.system.close(handle);
        if (pending < 0) return .{ .reason = .other, .fd = 0 };
        return .{ .reason = mapConnectErrno(@enumFromInt(pending)), .fd = 0 };
    }
}

/// A stack-built `sockaddr` for an `IpAddress` plus its length, ready to pass
/// to `connect(2)`. `storage` (a `sockaddr.storage`) is over-aligned for any
/// family, so `@ptrCast(&storage)` to the concrete `sockaddr` is sound.
const BuiltSockAddr = struct {
    storage: std.posix.sockaddr.storage,
    len: std.posix.socklen_t,
};

/// Build the `sockaddr` for `address` (IPv4 → `sockaddr_in`, IPv6 →
/// `sockaddr_in6` carrying flow label + scope id) — the ONE place a Zap-side
/// address becomes an OS socket address, shared by every connect path.
fn buildSockAddr(address: net.IpAddress) BuiltSockAddr {
    var result: BuiltSockAddr = .{ .storage = std.mem.zeroes(std.posix.sockaddr.storage), .len = 0 };
    switch (address) {
        .ip4 => |a| {
            const in = std.mem.zeroInit(std.posix.sockaddr.in, .{
                .family = std.posix.AF.INET,
                .port = std.mem.nativeToBig(u16, a.port),
                .addr = @as(u32, @bitCast(a.bytes)), // [a,b,c,d] in memory == network byte order
            });
            @memcpy(std.mem.asBytes(&result.storage)[0..@sizeOf(std.posix.sockaddr.in)], std.mem.asBytes(&in));
            result.len = @sizeOf(std.posix.sockaddr.in);
        },
        .ip6 => |a| {
            const in6 = std.mem.zeroInit(std.posix.sockaddr.in6, .{
                .family = std.posix.AF.INET6,
                .port = std.mem.nativeToBig(u16, a.port),
                .flowinfo = a.flow,
                .addr = a.bytes, // already big-endian in `Ip6Address.bytes`
                .scope_id = a.interface.index,
            });
            @memcpy(std.mem.asBytes(&result.storage)[0..@sizeOf(std.posix.sockaddr.in6)], std.mem.asBytes(&in6));
            result.len = @sizeOf(std.posix.sockaddr.in6);
        },
    }
    return result;
}

/// Set `O_NONBLOCK` on `handle`, returning whether it succeeded (the caller
/// closes the fd on failure). Shared by every posix connect path.
fn setNonBlocking(handle: net.Socket.Handle) bool {
    const nonblock_bit: usize = @as(usize, 1) << @bitOffsetOf(std.posix.O, "NONBLOCK");
    const flags_rc = std.posix.system.fcntl(handle, std.posix.F.GETFL, @as(usize, 0));
    if (std.posix.errno(flags_rc) != .SUCCESS) return false;
    const flags: usize = @intCast(flags_rc);
    return std.posix.errno(std.posix.system.fcntl(handle, std.posix.F.SETFL, flags | nonblock_bit)) == .SUCCESS;
}

/// Clear `O_NONBLOCK` on a just-connected `handle`, so the returned fd is
/// compatible with the poll-then-blocking `recv` (which requires a BLOCKING
/// fd). A best-effort `fcntl`; a failure leaves the socket usable (poll still
/// gates every read/write).
fn restoreBlocking(handle: net.Socket.Handle) void {
    const flags_rc = std.posix.system.fcntl(handle, std.posix.F.GETFL, @as(usize, 0));
    if (std.posix.errno(flags_rc) != .SUCCESS) return;
    const flags: usize = @intCast(flags_rc);
    const nonblock_bit: usize = @as(usize, 1) << @bitOffsetOf(std.posix.O, "NONBLOCK");
    _ = std.posix.system.fcntl(handle, std.posix.F.SETFL, flags & ~nonblock_bit);
}

// ---------------------------------------------------------------------------
// Hostname connect + RFC 8305 Happy Eyeballs (Phase S1 GAP 1 — Option A: full
// IPv6, REAL connection racing). ONE offloaded state machine: `connectHost`
// resolves the name (Phase B), interleaves the addresses v6/v4/v6/v4…, caps
// the attempt list, then drives ALL N non-blocking connects with ONE `poll()`
// over the whole pollfd array (Phase C), closing every loser fd synchronously
// on this thread and returning ONLY the winner. Runs on the blocking-pool
// thread gate-ON / the single OS thread gate-OFF; a fiber parks ONCE (the
// single Pass-2a `socket_pending_fd` slot holds the winner), so real racing
// costs ONE pool thread gate-ON and zero extra threads gate-OFF.
// ---------------------------------------------------------------------------

/// The attempt-list cap (SECURITY): however many addresses a name resolves to,
/// at most this many sockets are ever created and dialed. A hostile DNS reply
/// with thousands of records can therefore neither create thousands of fds nor
/// pin the pool — enforced IN the leaf, never materialized in Zap. The fork's
/// lookup queue is independently bounded at `dns_queue_capacity`.
const max_connect_attempts: usize = 8;

/// The connect-target address type, re-exported so the resolver pool
/// (`resolver_pool.zig`) can carry resolved addresses across the two-stage
/// hostname connect (Stage 1 resolve → Stage 2 race) without depending on the
/// fork's `std.Io.net` namespace directly.
pub const IpAddress = net.IpAddress;

/// The maximum number of resolved addresses one hostname connect ever races
/// (the RFC-8305 attempt cap, `max_connect_attempts`). The hard ceiling on how
/// many sockets a single `connect_host` can ever open — re-exported so the
/// resolver-pool slot sizes its address buffer to match.
pub const max_addresses: usize = max_connect_attempts;

/// The DNS result queue capacity. The fork guarantees `HostName.lookup` does
/// not block with a queue of capacity ≥ 16; `HostName.connectMany` uses 32, so
/// this matches — a second independent bound on how many records are retained.
const dns_queue_capacity: usize = 32;

/// RFC 8305 §5 Connection Attempt Delay: a new attempt is staggered by this
/// much behind the previous one, so a fast address wins without a thundering
/// herd of simultaneous SYNs, while a slow/black-holed earlier address does not
/// gate the rest. A cohort that has fully failed does NOT wait this out (the
/// next attempt starts immediately once nothing is in flight).
const connection_attempt_delay_ms: i64 = 250;

/// Connect to `host:port` with RFC 8305 Happy Eyeballs: validate the name
/// (RFC 1123) at the seam, resolve it, interleave IPv6/IPv4, cap the attempt
/// list, and RACE the attempts, returning the first connected fd (the winner)
/// or a mapped failure reason. `timeout_ms` (≤ 0 → no deadline) is ONE absolute
/// monotonic deadline spanning BOTH resolve and race; `kill_flag` (the owning
/// process's `pending_kill`, captured on-core) is observed each poll quantum so
/// the whole operation stays kill-responsive. BLOCKS on the calling thread.
///
/// SECURITY residual (documented, inherent, NOT worked around): `getaddrinfo`
/// is uninterruptible on macOS/musl — a resolve pins the calling thread until
/// the OS resolver returns, so `timeout_ms`/`kill_flag` bound only the on-core
/// wait, not the pinned thread. Mitigated by the address-list cap and the one
/// absolute deadline across resolve+race. The real fix (a kill-responsive
/// pure-Zig resolver) is a tracked follow-up.
pub fn connectHost(host: []const u8, port: u16, timeout_ms: i64, kill_flag: ?*std.atomic.Value(bool)) ConnectOutcome {
    // Validate the host name at the seam — an invalid name never reaches the
    // resolver (SECURITY: no attacker-controlled bytes reach `getaddrinfo`
    // unvalidated, and a syntactic error is a prompt typed failure).
    net.HostName.validate(host) catch |validate_error| return .{
        .reason = switch (validate_error) {
            error.NameTooLong, error.InvalidHostName => .invalid_argument,
        },
        .fd = 0,
    };

    // ONE absolute deadline across resolve + race (bounds the total on-core
    // wait to `timeout_ms`). The resolve consumes wall time we cannot preempt
    // (the getaddrinfo residual), so the race gets whatever budget remains.
    const has_deadline = timeout_ms > 0;
    const deadline_ms: i64 = if (has_deadline) checkedDeadline(monotonicMillis(), timeout_ms) else 0;

    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        // Poll-less targets (not in v1 run scope): sequential blocking connects
        // over the resolved addresses (no racing poll loop available); the
        // timeout/kill are a documented no-op there, matching `connectIp4`.
        return connectHostBlockingFallback(host, port);
    }

    var addresses: [max_connect_attempts]net.IpAddress = undefined;
    const attempt_count = resolveInterleaved(host, port, &addresses) catch |lookup_error|
        return .{ .reason = mapLookupError(lookup_error), .fd = 0 };
    if (attempt_count == 0) return .{ .reason = .unknown_host, .fd = 0 };

    const race_timeout: i64 = if (has_deadline) blk: {
        const remaining = deadline_ms - monotonicMillis();
        if (remaining <= 0) return .{ .reason = .timed_out, .fd = 0 };
        break :blk remaining;
    } else 0;
    return raceConnectPosix(addresses[0..attempt_count], race_timeout, kill_flag);
}

/// The resolved-address batch a Stage-1 resolve produces: up to
/// `max_addresses` interleaved (RFC-8305) addresses plus the resolution
/// `reason` (`.ok` when `count > 0`). Fixed-size (no allocation) so it lives
/// entirely inside a resolver-pool slab slot.
pub const ResolvedAddresses = struct {
    addresses: [max_connect_attempts]net.IpAddress,
    count: usize,
    reason: Reason,
};

/// STAGE 1 of the two-stage hostname connect (`docs/socket-implementation-plan.md`,
/// Decision-C isolation fix): validate `host` at the seam and resolve it to an
/// interleaved address batch. This is the ONLY step that calls the
/// uninterruptible `getaddrinfo`, so the resolver pool runs it on a DEDICATED
/// resolver thread — a resolve can then only ever pin a resolver thread, never
/// an I/O (blocking-pool) thread, severing the resolve↔I/O coupling that was the
/// DoS. Produces NO fd (the race in Stage 2 does), so an abandoned resolve
/// leaks nothing. Writes the outcome into `out` (never raises). `port` is folded
/// into every resolved address so Stage 2 needs only the batch.
pub fn resolveHost(host: []const u8, port: u16, out: *ResolvedAddresses) void {
    out.count = 0;
    // Validate the host name at the seam — an invalid name never reaches the
    // resolver (SECURITY: no attacker-controlled bytes reach `getaddrinfo`
    // unvalidated; a syntactic error is a prompt typed failure).
    net.HostName.validate(host) catch |validate_error| {
        out.reason = switch (validate_error) {
            error.NameTooLong, error.InvalidHostName => .invalid_argument,
        };
        return;
    };
    const count = resolveInterleaved(host, port, &out.addresses) catch |lookup_error| {
        out.reason = mapLookupError(lookup_error);
        return;
    };
    out.count = count;
    out.reason = if (count == 0) .unknown_host else .ok;
}

/// STAGE 2 of the two-stage hostname connect: race the already-resolved
/// `addresses` (RFC-8305 Happy Eyeballs) with the existing poll-quantum driver,
/// returning the winner fd or a mapped failure. `timeout_ms` (≤ 0 → no deadline)
/// is the REMAINING budget after Stage 1's resolve consumed part of the caller's
/// absolute deadline; `kill_flag` is observed each quantum. Runs on the I/O
/// (blocking) pool exactly as `zap_socket_connect`'s single-address race does —
/// the resolve is no longer coupled to it. Posix-only (the racing poll loop);
/// the poll-less targets keep the single-offload `connectHost` path.
pub fn raceConnectAddresses(addresses: []const net.IpAddress, timeout_ms: i64, kill_flag: ?*std.atomic.Value(bool)) ConnectOutcome {
    return raceConnectPosix(addresses, timeout_ms, kill_flag);
}

/// Resolve `host` and fill `out` with up to `max_connect_attempts` addresses
/// INTERLEAVED per RFC 8305 (IPv6, IPv4, IPv6, IPv4, …) — preferring IPv6 but
/// never letting one family starve the other — returning the count written.
/// Runs the fork's `HostName.lookup` SYNCHRONOUSLY on the `Io.Threaded`
/// singleton (`netLookup` fills then closes the queue), then drains it.
/// Unspecified addresses (`0.0.0.0` / `::`) are REJECTED (SECURITY: a resolver
/// returning the wildcard must not become a connect to "any"); the count is
/// capped so thousands of records cannot become thousands of sockets.
fn resolveInterleaved(host: []const u8, port: u16, out: *[max_connect_attempts]net.IpAddress) net.HostName.LookupError!usize {
    // `host` is already `validate`d by `connectHost`, so the unchecked
    // construction is sound (the fork asserts `bytes.len <= max_len`).
    const host_name = net.HostName{ .bytes = host };
    const the_io = io();
    var lookup_buffer: [dns_queue_capacity]net.HostName.LookupResult = undefined;
    var lookup_queue: std.Io.Queue(net.HostName.LookupResult) = .init(&lookup_buffer);
    // Fills the queue and CLOSES it before returning, even on error.
    try host_name.lookup(the_io, &lookup_queue, .{ .port = port });

    // Split into per-family lists preserving resolver order (bounded by the
    // queue capacity — the cap is a hard ceiling on retained records).
    var v6: [dns_queue_capacity]net.Ip6Address = undefined;
    var v4: [dns_queue_capacity]net.Ip4Address = undefined;
    var v6_len: usize = 0;
    var v4_len: usize = 0;
    while (lookup_queue.getOneUncancelable(the_io)) |result| {
        switch (result) {
            .address => |address| switch (address) {
                .ip6 => |a| if (!isUnspecified(a.bytes[0..]) and v6_len < v6.len) {
                    v6[v6_len] = a;
                    v6_len += 1;
                },
                .ip4 => |a| if (!isUnspecified(a.bytes[0..]) and v4_len < v4.len) {
                    v4[v4_len] = a;
                    v4_len += 1;
                },
            },
            .canonical_name => {},
        }
    } else |queue_error| switch (queue_error) {
        error.Closed => {}, // drained
    }

    // Interleave v6/v4, capped at `out.len` (`max_connect_attempts`).
    var count: usize = 0;
    var idx: usize = 0;
    while (count < out.len and (idx < v6_len or idx < v4_len)) : (idx += 1) {
        if (idx < v6_len and count < out.len) {
            out[count] = .{ .ip6 = v6[idx] };
            count += 1;
        }
        if (idx < v4_len and count < out.len) {
            out[count] = .{ .ip4 = v4[idx] };
            count += 1;
        }
    }
    return count;
}

/// Whether every byte is zero — the IPv4 `0.0.0.0` / IPv6 `::` unspecified
/// (wildcard) address, which is never a valid connect target.
fn isUnspecified(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

/// The RFC 8305 racing driver (posix). Drives ALL in-flight non-blocking
/// connects with ONE `poll()` over the whole pollfd array, staggering new
/// attempts by `connection_attempt_delay_ms`, re-checking the absolute
/// deadline + `kill_flag` each quantum. The FIRST attempt whose `SO_ERROR` is
/// `0` is the winner (blocking mode restored, fd returned); EVERY other fd —
/// in-flight OR not-yet-started — is closed on THIS thread.
///
/// LOSER-CLEANUP GUARANTEE (SECURITY — no fd-exhaustion DoS): the `defer`
/// closes every fd still marked open in `fds`, on EVERY exit path (winner,
/// timeout, kill, all-attempts-failed, poll error). The winner clears its own
/// slot to `-1` before returning, so it alone escapes the sweep; every started
/// loser fd is closed EXACTLY ONCE (an in-flight loser is closed by the defer;
/// a completed loser was already closed and its slot set to `-1`). No cancelled
/// or racing attempt can leak a fd, and only the winner leaves this function.
fn raceConnectPosix(addresses: []const net.IpAddress, timeout_ms: i64, kill_flag: ?*std.atomic.Value(bool)) ConnectOutcome {
    const n = addresses.len;
    // `-1` = slot empty (not started, already closed, or claimed by the
    // winner). A real socket fd is always ≥ 0 (fds 0–2 are the std streams).
    var fds: [max_connect_attempts]std.posix.fd_t = @splat(-1);
    defer for (0..n) |i| {
        if (fds[i] >= 0) {
            _ = std.posix.system.close(fds[i]);
            fds[i] = -1;
        }
    };

    const has_deadline = timeout_ms > 0;
    const deadline_ms: i64 = if (has_deadline) checkedDeadline(monotonicMillis(), timeout_ms) else 0;

    var next_index: usize = 0; // the next address to start dialing
    var open_count: usize = 0; // attempts currently in flight (started, unresolved)
    var last_start_ms: i64 = monotonicMillis();
    var last_reason: Reason = .host_unreachable;
    var started_any = false;

    while (true) {
        if (kill_flag) |flag| {
            if (flag.load(.acquire)) return .{ .reason = .other, .fd = 0 };
        }
        const now = monotonicMillis();
        if (has_deadline and (deadline_ms - now) <= 0) return .{ .reason = .timed_out, .fd = 0 };

        // Start the next attempt when due: immediately if nothing is in flight
        // (don't wait out the stagger behind a failed cohort), else once the
        // Connection Attempt Delay since the last real start has elapsed.
        if (next_index < n and (open_count == 0 or (now - last_start_ms) >= connection_attempt_delay_ms)) {
            const start = startAttempt(addresses[next_index]);
            next_index += 1;
            switch (start.state) {
                .connected => {
                    // Immediate winner (loopback). Kill re-check (HIGH-1) before
                    // handing a live fd back, then claim + restore. The `defer`
                    // closes every loser; `start.fd` is not in `fds`, so on the
                    // kill path it is closed explicitly here.
                    if (kill_flag) |flag| {
                        if (flag.load(.acquire)) {
                            _ = std.posix.system.close(start.fd);
                            return .{ .reason = .other, .fd = 0 };
                        }
                    }
                    restoreBlocking(start.fd);
                    return .{ .reason = .ok, .fd = fdToBits(start.fd) };
                },
                .in_progress => {
                    fds[next_index - 1] = start.fd;
                    open_count += 1;
                    last_start_ms = now;
                    started_any = true;
                },
                .failed => {
                    // No fd in flight from this attempt (already closed); record
                    // the reason and loop to try the next address without delay.
                    last_reason = start.reason;
                    started_any = true;
                },
            }
            continue;
        }

        // Nothing in flight and nothing left to start → the race is over.
        if (open_count == 0 and next_index >= n) {
            return .{ .reason = if (started_any) last_reason else .unknown_host, .fd = 0 };
        }

        // Poll all in-flight fds for POLL.OUT, bounded by the smaller of the
        // kill quantum, the remaining deadline, and the time to the next
        // stagger, so kills/timeouts/new-attempts all fire promptly.
        var poll_fds: [max_connect_attempts]std.posix.pollfd = undefined;
        var poll_slot: [max_connect_attempts]usize = undefined;
        var poll_len: usize = 0;
        for (0..n) |i| {
            if (fds[i] >= 0) {
                poll_fds[poll_len] = .{ .fd = fds[i], .events = std.posix.POLL.OUT, .revents = 0 };
                poll_slot[poll_len] = i;
                poll_len += 1;
            }
        }
        var quantum: i32 = poll_quantum_ms;
        if (has_deadline) {
            const remaining = deadline_ms - now;
            if (remaining < quantum) quantum = @intCast(@max(remaining, 1));
        }
        if (next_index < n) {
            const to_stagger = (last_start_ms + connection_attempt_delay_ms) - now;
            if (to_stagger < quantum) quantum = @intCast(@max(to_stagger, 1));
        }
        const ready_count = std.posix.poll(poll_fds[0..poll_len], quantum) catch
            return .{ .reason = .other, .fd = 0 };
        if (ready_count == 0) continue; // re-check kill/deadline/stagger

        for (0..poll_len) |p| {
            if (poll_fds[p].revents == 0) continue;
            const i = poll_slot[p];
            const pending = soError(fds[i]);
            if (pending == 0) {
                // WINNER. Kill re-check (HIGH-1), then claim its fd (clear the
                // slot so the loser-cleanup defer skips it) and restore blocking.
                if (kill_flag) |flag| {
                    if (flag.load(.acquire)) return .{ .reason = .other, .fd = 0 };
                }
                restoreBlocking(fds[i]);
                const winner = fds[i];
                fds[i] = -1;
                return .{ .reason = .ok, .fd = fdToBits(winner) };
            }
            // Loser: close now, free the slot, record the reason.
            _ = std.posix.system.close(fds[i]);
            fds[i] = -1;
            open_count -= 1;
            last_reason = if (pending > 0) mapConnectErrno(@enumFromInt(pending)) else .other;
        }
    }
}

/// The poll-less (Windows/wasi) hostname-connect fallback: resolve, then try
/// each address with the blocking `IpAddress.connect` in turn, returning the
/// first success. No racing (no poll loop available there) and the timeout/kill
/// are a documented no-op — the same posture `connectIp4`/`connectIp6` take on
/// these targets. Sequential means at most one fd is open at a time, so there
/// is nothing to clean up on failure.
fn connectHostBlockingFallback(host: []const u8, port: u16) ConnectOutcome {
    const host_name = net.HostName{ .bytes = host };
    const the_io = io();
    var lookup_buffer: [dns_queue_capacity]net.HostName.LookupResult = undefined;
    var lookup_queue: std.Io.Queue(net.HostName.LookupResult) = .init(&lookup_buffer);
    host_name.lookup(the_io, &lookup_queue, .{ .port = port }) catch |lookup_error|
        return .{ .reason = mapLookupError(lookup_error), .fd = 0 };

    var last_reason: Reason = .unknown_host;
    var tried: usize = 0;
    while (lookup_queue.getOneUncancelable(the_io)) |result| {
        switch (result) {
            .address => |address| {
                switch (address) {
                    inline .ip4, .ip6 => |a| if (isUnspecified(a.bytes[0..])) continue,
                }
                if (tried >= max_connect_attempts) continue;
                tried += 1;
                const stream = address.connect(the_io, .{ .mode = .stream, .timeout = .none }) catch |connect_error| {
                    last_reason = mapConnectError(connect_error);
                    continue;
                };
                // Drain the rest of the (already-closed) queue before returning
                // so no buffered record is left dangling, then hand back the fd.
                while (lookup_queue.getOneUncancelable(the_io)) |_| {} else |_| {}
                return .{ .reason = .ok, .fd = fdToBits(stream.socket.handle) };
            },
            .canonical_name => {},
        }
    } else |queue_error| switch (queue_error) {
        error.Closed => {},
    }
    return .{ .reason = last_reason, .fd = 0 };
}

/// Map a `HostName.lookup` failure to a stable `Reason`. An unknown host / no
/// records is `unknown_host` (→ `:nxdomain`); config/DNS failures degrade to
/// `network_down`/`other`; a bind failure for the resolver socket carries its
/// own reason.
fn mapLookupError(err: net.HostName.LookupError) Reason {
    return switch (err) {
        error.UnknownHostName, error.NoAddressReturned => .unknown_host,
        error.NameServerFailure => .network_down,
        error.ResolvConfParseFailed,
        error.DetectingNetworkConfigurationFailed,
        error.InvalidDnsARecord,
        error.InvalidDnsAAAARecord,
        error.InvalidDnsCnameRecord,
        => .other,
        error.AddressInUse => .address_in_use,
        error.AddressUnavailable => .address_unavailable,
        error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => .fd_quota_exceeded,
        error.NetworkDown => .network_down,
        error.SystemResources => .out_of_memory,
        else => .other,
    };
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

/// Monotonic milliseconds from an arbitrary epoch — the timeout clock for the
/// poll-quantum loops (`recv`/`send`/`connect`). Read ONCE at entry to form an
/// absolute deadline, then re-read each quantum, so the deadline advances with
/// wall time regardless of the poll wake pattern.
///
/// This closes the slowloris idle-timeout hole (HIGH-3): the prior loop summed
/// `poll_quantum_ms` onto an elapsed counter ONLY on a full-quantum `.timeout`
/// poll, so a peer dribbling one byte every sub-quantum kept every poll
/// `.ready`, the counter never advanced, and the `timeout_ms` deadline was
/// never reached — pinning a pool thread forever. An absolute monotonic
/// deadline cannot be defeated that way.
///
/// Comptime-branched across this socket seam's three backends exactly like
/// `waitReadable`/`nameAddress` (this file IS the socket syscall seam, so
/// per-OS calls are its purpose): posix `clock_gettime(CLOCK_MONOTONIC)`,
/// Windows `QueryPerformanceCounter`/`QueryPerformanceFrequency`, wasi
/// `clock_time_get(CLOCK_MONOTONIC)`. On the poll-less targets the timeout is
/// a documented no-op (`waitReadable`/`waitWritable` return `.ready`), so the
/// clock is only load-bearing on posix, but all three compile for every
/// cross-target build.
fn monotonicMillis() i64 {
    switch (comptime builtin.os.tag) {
        .windows => {
            const kernel32 = struct {
                extern "kernel32" fn QueryPerformanceCounter(count: *i64) callconv(.winapi) i32;
                extern "kernel32" fn QueryPerformanceFrequency(frequency: *i64) callconv(.winapi) i32;
            };
            var counter: i64 = 0;
            var frequency: i64 = 0;
            _ = kernel32.QueryPerformanceCounter(&counter);
            _ = kernel32.QueryPerformanceFrequency(&frequency);
            if (frequency <= 0) return 0;
            // counter / frequency = seconds; scale to ms in 128-bit to avoid overflow.
            return @intCast(@divTrunc(@as(i128, counter) * 1000, @as(i128, frequency)));
        },
        .wasi => {
            var timestamp: std.os.wasi.timestamp_t = 0;
            _ = std.os.wasi.clock_time_get(.MONOTONIC, 1, &timestamp);
            return @intCast(timestamp / std.time.ns_per_ms);
        },
        else => {
            var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
            _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
            return @as(i64, @intCast(ts.sec)) * 1000 +
                @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
        },
    }
}

/// Compute the ABSOLUTE monotonic deadline for a `timeout_ms > 0` relative
/// timeout, SATURATING at `maxInt(i64)` instead of overflowing. Only reached
/// with `timeout_ms > 0` (the `has_deadline` guard at each call site). A
/// pathological program-supplied `timeout_ms` near `maxInt(i64)` would make
/// the naive `monotonicMillis() + timeout_ms` overflow i64 — undefined
/// behavior in ReleaseFast, a loud panic in ReleaseSafe (the checkedTimeout
/// hardening; it is program-supplied, not remote). The saturating add (`+|`)
/// clamps to `maxInt(i64)`, so a huge timeout degrades to "effectively no
/// deadline" (the deadline never elapses within the process's life) rather
/// than a crash — the same validated-narrowing posture as `checkedPort`/
/// `checkedBacklog` (MED-4), applied to the deadline arithmetic.
fn checkedDeadline(now_ms: i64, timeout_ms: i64) i64 {
    return now_ms +| timeout_ms;
}

/// The outcome of a `recv`: a stable, gate-crossing status, the buffer the
/// bytes were read into (allocated + grown from the caller's `allocator`; the
/// caller owns it), and how many of its bytes are the received chunk.
///
///   * `status == 0` — a CHUNK: `bytes_filled >= 1` bytes are in `buffer`.
///   * `status == -1` — CLOSED: clean EOF (`recv()==0`), the footgun the
///     `SocketRecv.Closed` constructor turns into an exhaustive-`case` arm.
///   * `status > 0` — FAILED: the value is a `Reason` code (`timed_out == 2`
///     is the idle-timeout case), which the runtime maps to a `SocketError`
///     reason atom.
///
/// `buffer` is exactly `bytes_filled` bytes (recv shrinks it to what actually
/// arrived on the way out — no over-allocation is handed back), so the chunk
/// is `buffer[0..bytes_filled]` and `buffer.ptr` is the chunk's backing.
pub const RecvOutcome = struct {
    status: i32,
    buffer: []u8,
    bytes_filled: usize,
};

const recv_status_chunk: i32 = 0;
const recv_status_closed: i32 = -1;

/// The initial buffer capacity for an `exact` (recv_exact) read: the buffer
/// starts here and grows GEOMETRICALLY toward the peer-supplied `exact_target`
/// only as bytes ACTUALLY arrive (MED-3). A 4-byte length prefix decoding to a
/// 4 GiB `exact_target` therefore allocates ~16 KiB up front — never the full
/// speculative target — and a peer that sends only a few KiB before stalling
/// forces only a few KiB of allocation. Sized to the next-available chunk so a
/// small frame needs no growth at all.
const recv_exact_initial_capacity: usize = 16384;

/// Receive bytes with poll-quantum bounding, allocating and GROWING the
/// destination buffer from `allocator` as bytes arrive. `exact_target > 0`
/// accumulates exactly that many bytes (`recv_exact`) — the buffer starts at
/// `recv_exact_initial_capacity` and doubles toward `exact_target` only as far
/// as the bytes RECEIVED require, so a peer's large length prefix cannot force
/// a large speculative allocation up front (MED-3). `exact_target == 0` is
/// next-available: one read into `next_available_capacity`, then the buffer is
/// SHRUNK to what arrived (no 16 KiB tail wasted). `timeout_ms <= 0` means "no
/// deadline" (the leaf still wakes each quantum to honour a kill). `kill_flag`,
/// when non-null, is the owning process's `pending_kill` atomic.
///
/// The returned `RecvOutcome.buffer` is owned by `allocator` and is exactly
/// `bytes_filled` bytes. BLOCKS on the calling thread (a blocking-pool worker
/// gate-ON, the single OS thread gate-OFF). Never closes the fd — a timeout
/// leaves the socket fully usable. Returns `error.OutOfMemory` if the buffer
/// cannot be allocated/grown (nothing is leaked — the partial buffer is freed).
pub fn recv(
    allocator: std.mem.Allocator,
    fd: Fd,
    exact_target: usize,
    next_available_capacity: usize,
    timeout_ms: i64,
    kill_flag: ?*std.atomic.Value(bool),
) error{OutOfMemory}!RecvOutcome {
    const exact = exact_target > 0;
    // Initial capacity FOLLOWS the receive shape, never the peer's speculative
    // target: an exact read starts at the growth floor (capped by the target
    // when the target is smaller); a next-available read uses the moderate
    // chunk size. `@max(_, 1)` keeps a valid non-empty allocation even for a
    // degenerate zero request.
    const initial_capacity: usize = if (exact)
        @max(@min(exact_target, recv_exact_initial_capacity), 1)
    else
        @max(next_available_capacity, 1);
    var buffer = try allocator.alloc(u8, initial_capacity);
    errdefer allocator.free(buffer);

    const the_io = io();
    const handle = fdFromBits(fd);
    var filled: usize = 0;
    // ABSOLUTE monotonic deadline (HIGH-3): read the clock once and recompute
    // `deadline - now` each quantum. The prior loop summed `quantum` onto an
    // elapsed counter ONLY on a `.timeout` poll, so a peer dribbling one byte
    // per sub-quantum kept every poll `.ready`, never advanced the counter,
    // and defeated the `timeout_ms` deadline — pinning a pool thread forever.
    // An absolute deadline cannot be dribble-defeated (a `.ready` poll no
    // longer needs accounting because `now` moves on its own).
    const has_deadline = timeout_ms > 0;
    const deadline_ms: i64 = if (has_deadline) checkedDeadline(monotonicMillis(), timeout_ms) else 0;
    while (true) {
        if (kill_flag) |flag| {
            if (flag.load(.acquire)) return try shrinkRecv(allocator, buffer, recv_status_closed, filled);
        }
        var quantum: i32 = poll_quantum_ms;
        if (has_deadline) {
            const remaining = deadline_ms - monotonicMillis();
            // On timeout the already-consumed `filled` bytes ride out on the
            // outcome (MED-1): a `recv_exact` that timed out mid-frame has
            // pulled `filled` bytes off the socket, and dropping them would
            // desync a framed stream. The caller surfaces them as
            // `SocketRecv.TimedOut(partial)` so no bytes are lost.
            if (remaining <= 0) return try shrinkRecv(allocator, buffer, @intFromEnum(Reason.timed_out), filled);
            if (remaining < quantum) quantum = @intCast(remaining);
        }
        switch (waitReadable(handle, quantum)) {
            .timeout => continue, // re-check deadline + kill (no manual accounting)
            .failed => return try shrinkRecv(allocator, buffer, @intFromEnum(Reason.other), filled),
            .ready => {},
        }
        var iovec = [1][]u8{buffer[filled..]};
        const read_count = the_io.vtable.netRead(the_io.userdata, handle, iovec[0..]) catch |err|
            return try shrinkRecv(allocator, buffer, @intFromEnum(mapReadError(err)), filled);
        if (read_count == 0) {
            // Clean EOF. For an exact read that already saw bytes, the stream
            // ended mid-frame — still CLOSED (the caller asked for N and the
            // peer is done); the partial `filled` is reported so a caller can
            // observe how much arrived before the close.
            return try shrinkRecv(allocator, buffer, recv_status_closed, filled);
        }
        filled += read_count;
        if (!exact) return try shrinkRecv(allocator, buffer, recv_status_chunk, filled);
        if (filled >= exact_target) return try shrinkRecv(allocator, buffer, recv_status_chunk, filled);
        // Exact but not yet complete. If the buffer is full, GROW it toward the
        // target — geometric doubling capped at `exact_target`, so allocation
        // tracks bytes received (MED-3), never the peer's speculative prefix.
        if (filled >= buffer.len) {
            const grown_capacity = @min(buffer.len *| 2, exact_target);
            buffer = try allocator.realloc(buffer, grown_capacity);
        }
    }
}

/// Shrink `buffer` to exactly `filled` bytes (reclaiming any grow/next-
/// available over-allocation — for an arena this resizes the tail in place;
/// for a general allocator it frees the excess) and package the recv outcome.
/// A zero-length result frees the buffer entirely and returns an empty slice.
/// The shrink is a NARROWING realloc, which cannot fail; the `catch` keeps the
/// original (larger) buffer if an allocator ever refuses, still returning a
/// correct `bytes_filled`-length chunk view.
fn shrinkRecv(allocator: std.mem.Allocator, buffer: []u8, status: i32, filled: usize) error{OutOfMemory}!RecvOutcome {
    if (filled == 0) {
        allocator.free(buffer);
        return .{ .status = status, .buffer = &.{}, .bytes_filled = 0 };
    }
    if (filled == buffer.len) return .{ .status = status, .buffer = buffer, .bytes_filled = filled };
    const shrunk = allocator.realloc(buffer, filled) catch buffer;
    return .{ .status = status, .buffer = shrunk, .bytes_filled = filled };
}

/// The outcome of a `send`: `ok` on full delivery, else a mapped reason, with
/// `bytes_sent` reporting how much of the payload committed before the failure
/// (the Erlang `{timeout, RestData}` lesson — the caller learns the boundary).
pub const SendOutcome = struct {
    reason: Reason,
    bytes_sent: usize,
};

/// Send ALL of `bytes` or report the failure with the committed byte count
/// (all-or-error, `Socket.send`), bounded by `timeout_ms` and the owning
/// process's `kill_flag`. An empty payload succeeds trivially.
///
/// A bare `while (sent < len) netWrite` loop (the prior implementation) blocks
/// FOREVER on a peer that accepts and never reads (slowloris-on-send): the OS
/// send buffer fills, `netWrite` blocks, the owning process becomes UNKILLABLE
/// and a blocking-pool thread is pinned → pool exhaustion, a runtime-wide DoS
/// (HIGH-2). This routes through the SAME poll-quantum + `kill_flag` loop
/// `recv` uses, polling `POLL.OUT`: each quantum re-checks the absolute
/// monotonic deadline and the kill flag, so a stalled send times out
/// (`timeout_ms > 0`) or yields promptly to teardown — and NEVER closes the fd
/// (Decision E — a timeout leaves the socket usable, never `SO_SNDTIMEO`).
pub fn send(fd: Fd, bytes: []const u8, timeout_ms: i64, kill_flag: ?*std.atomic.Value(bool)) SendOutcome {
    return sendImpl(fd, bytes, true, timeout_ms, kill_flag);
}

/// Send whatever the kernel accepts in ONE write (explicit partial send —
/// `Socket.send_some`), bounded by `timeout_ms` and `kill_flag` exactly like
/// `send`. Returns the bytes actually written (`>= 1` on success for a
/// non-empty payload); the caller decides how to handle a short write.
pub fn sendSome(fd: Fd, bytes: []const u8, timeout_ms: i64, kill_flag: ?*std.atomic.Value(bool)) SendOutcome {
    if (bytes.len == 0) return .{ .reason = .ok, .bytes_sent = 0 };
    return sendImpl(fd, bytes, false, timeout_ms, kill_flag);
}

/// The shared poll-quantum-bounded write loop behind `send`/`sendSome`. When
/// `all` is true it loops until every byte is written (or a deadline/kill/error
/// intervenes); when false it returns after the first accepted write (the
/// `send_some` single-write semantics).
fn sendImpl(fd: Fd, bytes: []const u8, all: bool, timeout_ms: i64, kill_flag: ?*std.atomic.Value(bool)) SendOutcome {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        // Poll-less targets (not in v1 run scope): the original blocking
        // `netWrite` loop; the timeout/kill are a documented no-op (like
        // `connect`). `timeout_ms`/`kill_flag` stay "used" via the comptime-dead
        // posix path below (no discard, like `waitWritable`'s params there).
        const the_io = io();
        const handle = fdFromBits(fd);
        var sent: usize = 0;
        while (sent < bytes.len) {
            const written = writeOnce(the_io, handle, bytes[sent..]) catch |err|
                return .{ .reason = mapWriteError(err), .bytes_sent = sent };
            if (written == 0) return .{ .reason = .connection_reset, .bytes_sent = sent };
            sent += written;
            if (!all) return .{ .reason = .ok, .bytes_sent = sent };
        }
        return .{ .reason = .ok, .bytes_sent = bytes.len };
    }
    return sendImplPosix(fd, bytes, all, timeout_ms, kill_flag);
}

/// The posix poll-quantum send loop. CRITICAL: the fd is flipped to
/// `O_NONBLOCK` for the duration (restored on exit), so each `send` places only
/// what currently fits (or returns `EAGAIN`) and returns immediately. A blocking
/// `write`/`sendmsg` of a large payload blocks until the ENTIRE payload is
/// queued — it does NOT return after merely filling the buffer (unlike `read`,
/// which returns the bytes already available). So poll-then-BLOCKING-write would
/// still pin the pool thread on a peer that accepts and never reads: `POLL.OUT`
/// only reports "≥1 byte of room", after which a blocking write of the remaining
/// megabytes blocks waiting for the peer to drain. (`MSG_DONTWAIT` alone is
/// unreliable on macOS, so `O_NONBLOCK` is the portable mechanism.) Non-blocking
/// writes make the per-quantum deadline and `kill_flag` checks always run
/// (HIGH-2). The blocking mode is RESTORED on every exit path, so `recv`'s
/// poll-then-blocking-read (safe — a read returns available bytes) is unaffected.
fn sendImplPosix(fd: Fd, bytes: []const u8, all: bool, timeout_ms: i64, kill_flag: ?*std.atomic.Value(bool)) SendOutcome {
    const handle = fdFromBits(fd);
    const flags: u32 = std.posix.MSG.NOSIGNAL; // no SIGPIPE; O_NONBLOCK gives non-blocking

    // Flip to non-blocking for the send, restore the original mode on exit.
    const nonblock_bit: usize = @as(usize, 1) << @bitOffsetOf(std.posix.O, "NONBLOCK");
    const original_flags_rc = std.posix.system.fcntl(handle, std.posix.F.GETFL, @as(usize, 0));
    if (std.posix.errno(original_flags_rc) != .SUCCESS) return .{ .reason = .other, .bytes_sent = 0 };
    const original_flags: usize = @intCast(original_flags_rc);
    if (std.posix.errno(std.posix.system.fcntl(handle, std.posix.F.SETFL, original_flags | nonblock_bit)) != .SUCCESS)
        return .{ .reason = .other, .bytes_sent = 0 };
    defer _ = std.posix.system.fcntl(handle, std.posix.F.SETFL, original_flags);

    var sent: usize = 0;
    const has_deadline = timeout_ms > 0;
    const deadline_ms: i64 = if (has_deadline) checkedDeadline(monotonicMillis(), timeout_ms) else 0;
    while (sent < bytes.len) {
        if (kill_flag) |flag| {
            // Killed mid-send: break out promptly so the pool thread returns
            // and the process tears down. `bytes_sent` reports the boundary.
            if (flag.load(.acquire)) return .{ .reason = .other, .bytes_sent = sent };
        }
        var quantum: i32 = poll_quantum_ms;
        if (has_deadline) {
            const remaining = deadline_ms - monotonicMillis();
            if (remaining <= 0) return .{ .reason = .timed_out, .bytes_sent = sent };
            if (remaining < quantum) quantum = @intCast(remaining);
        }
        switch (waitWritable(handle, quantum)) {
            .timeout => continue, // re-check deadline + kill
            .failed => return .{ .reason = .other, .bytes_sent = sent },
            .ready => {},
        }
        const chunk = bytes[sent..];
        const rc = std.posix.system.send(handle, @ptrCast(chunk.ptr), chunk.len, flags);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const written: usize = @intCast(rc);
                if (written == 0) return .{ .reason = .connection_reset, .bytes_sent = sent };
                sent += written;
                if (!all) return .{ .reason = .ok, .bytes_sent = sent }; // send_some: one write
            },
            // Buffer filled between the poll and the send, or interrupted —
            // re-poll (the deadline/kill are re-checked at the loop top).
            .AGAIN, .INTR => {},
            else => |send_errno| return .{ .reason = mapSendErrno(send_errno), .bytes_sent = sent },
        }
    }
    return .{ .reason = .ok, .bytes_sent = bytes.len };
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

/// Test-only injection seam for the deterministic post-`netAccept` kill test.
/// `accept` invokes this hook (when non-null) IMMEDIATELY after `netAccept`
/// returns a connection and BEFORE the post-accept kill re-check, so a test
/// can flip the `kill_flag` precisely inside that window — landing execution
/// in the close-on-kill branch every run, which the timing-racing test lands
/// only occasionally. Guarded by `comptime builtin.is_test`, so it and its
/// call site are DEAD CODE (fully elided) in every shipped binary — zero
/// production cost, no reachable seam.
var test_after_accept_hook: ?*const fn () void = null;

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
        // Test-only: flip the kill flag exactly inside the post-accept window
        // (comptime-dead in production — see `test_after_accept_hook`).
        if (comptime builtin.is_test) {
            if (test_after_accept_hook) |hook| hook();
        }
        // A kill that landed WHILE we were blocked accepting (between the
        // top-of-loop check and this connection arriving): close the
        // just-accepted fd HERE, on the pool thread, rather than handing a live
        // connection back to a process that is tearing down (HIGH-1). Without
        // this, a connection arriving mid-accept returns an fd regardless of a
        // pending kill; the fiber continuation that would register it into the
        // domain+ledger is then skipped by the kill teardown, orphaning the fd.
        // Closing on kill-observed is the accept twin of `recv`/`connect`'s
        // per-quantum kill-responsiveness. (The teardown-visible pending-fd
        // slot in `abi.zig` is the backstop for the residual race where the
        // kill becomes visible only AFTER this check but before re-attach.)
        if (kill_flag) |flag| {
            if (flag.load(.acquire)) {
                var accepted_handle = accepted.handle;
                the_io.vtable.netClose(the_io.userdata, (&accepted_handle)[0..1]);
                return .{ .reason = .other, .fd = 0, .peer = AddressV4.none };
            }
        }
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

/// A resolved endpoint of EITHER family — the IPv6-aware `local_address`/
/// `peer_address` result. After a happy-eyeballs connect that won over IPv6,
/// `getsockname`/`getpeername` return an `AF_INET6` address; this type surfaces
/// it HONESTLY on the runtime side instead of silently reporting "unavailable".
///
/// The Zap-visible `SocketAddress` stays IPv4-only for v1: `packEndpoint`
/// (`abi.zig`/`runtime.zig`) packs an `ip4` endpoint into the integer code and
/// maps an `ip6`/`unavailable` endpoint to `-1` (`:unavailable`), so a v6
/// endpoint never crosses the ABI into Zap — it lives only here.
pub const SocketEndpoint = struct {
    /// The endpoint family: `.unavailable` (unbound/unconnected/error),
    /// `.ip4`, or `.ip6`.
    family: Family,
    /// IPv4 octets (meaningful iff `family == .ip4`).
    v4: [4]u8,
    /// IPv6 bytes, big-endian (meaningful iff `family == .ip6`).
    v6: [16]u8,
    /// Port, native-endian.
    port: u16,
    /// IPv6 zone/scope id (meaningful iff `family == .ip6`; `0` = none).
    scope_id: u32,

    pub const Family = enum { unavailable, ip4, ip6 };

    pub const none = SocketEndpoint{
        .family = .unavailable,
        .v4 = .{ 0, 0, 0, 0 },
        .v6 = @splat(0),
        .port = 0,
        .scope_id = 0,
    };
};

/// The local (bound) endpoint of `fd` via `getsockname` (IPv4 or IPv6).
pub fn localAddress(fd: Fd) SocketEndpoint {
    return nameAddress(fd, .local);
}

/// The remote (peer) endpoint of `fd` via `getpeername` (IPv4 or IPv6).
pub fn peerAddress(fd: Fd) SocketEndpoint {
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

/// Wait up to `quantum_ms` for `handle` to become WRITABLE (send buffer has
/// room) or to report a connect/hangup/error — the `POLL.OUT` twin of
/// `waitReadable`, used by the send loop and the non-blocking connect. `poll`
/// reports `POLLERR`/`POLLHUP` in `revents` unconditionally, so a failed
/// connect or a reset peer wakes the poll as `.ready`; the caller then reads
/// `SO_ERROR` (connect) or observes the write error (send). On the poll-less
/// targets this reports `.ready` so the blocking write simply blocks — the
/// quantum timeout is a documented no-op there, never a correctness break.
fn waitWritable(handle: net.Socket.Handle, quantum_ms: i32) ReadyState {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        return .ready;
    }
    var poll_fds = [1]std.posix.pollfd{.{
        .fd = handle,
        .events = std.posix.POLL.OUT,
        .revents = 0,
    }};
    const ready_count = std.posix.poll(poll_fds[0..], quantum_ms) catch return .failed;
    return if (ready_count == 0) .timeout else .ready;
}

/// Read a connecting socket's pending `SO_ERROR` (the completed connect's
/// verdict): `0` = connected, a positive errno = the connect failure, `-1` =
/// `getsockopt` itself failed. Posix-only (the non-blocking connect path).
fn soError(handle: net.Socket.Handle) i32 {
    var pending: i32 = 0;
    var length: std.posix.socklen_t = @sizeOf(i32);
    const rc = std.posix.system.getsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.ERROR, @ptrCast(&pending), &length);
    if (std.posix.errno(rc) != .SUCCESS) return -1;
    return pending;
}

/// Map a `socket(2)` creation failure errno to a stable `Reason`.
fn mapSocketCreateErrno(rc: anytype) Reason {
    return switch (std.posix.errno(rc)) {
        .MFILE, .NFILE => .fd_quota_exceeded,
        .ACCES, .PERM => .access_denied,
        .NOMEM, .NOBUFS => .out_of_memory,
        else => .other,
    };
}

/// Map a non-blocking `send(2)` errno to a stable `Reason` (the same set
/// `mapWriteError` produces for the `netWrite` fallback path).
fn mapSendErrno(err: std.posix.E) Reason {
    return switch (err) {
        .PIPE, .CONNRESET => .connection_reset,
        .NETDOWN => .network_down,
        .NETUNREACH => .network_unreachable,
        .HOSTUNREACH => .host_unreachable,
        .ACCES => .access_denied,
        .NOBUFS, .NOMEM => .out_of_memory,
        else => .other,
    };
}

/// Map a `connect(2)` / `SO_ERROR` errno to a stable `Reason` (the same set
/// `mapConnectError` produces for the portable-connect fallback path).
fn mapConnectErrno(err: std.posix.E) Reason {
    return switch (err) {
        .CONNREFUSED => .connection_refused,
        .TIMEDOUT => .timed_out,
        .HOSTUNREACH => .host_unreachable,
        .NETUNREACH => .network_unreachable,
        .NETDOWN => .network_down,
        .CONNRESET => .connection_reset,
        .ADDRNOTAVAIL => .address_unavailable,
        .ADDRINUSE => .address_in_use,
        .ACCES, .PERM => .access_denied,
        .NOMEM, .NOBUFS => .out_of_memory,
        else => .other,
    };
}

/// One `netWrite` of `bytes` (no header, no splat). Returns bytes accepted.
fn writeOnce(the_io: std.Io, handle: net.Socket.Handle, bytes: []const u8) net.Stream.Writer.Error!usize {
    const data = [1][]const u8{bytes};
    return the_io.vtable.netWrite(the_io.userdata, handle, &.{}, data[0..], 1);
}

const NameKind = enum { local, peer };

/// Resolve the local or peer endpoint through the raw `getsockname`/
/// `getpeername` (portable across the posix targets; not scanned by the
/// runtime OS-portability gate, which covers only `src/runtime.zig`).
/// IPv6-aware: an `AF_INET6` socket (a happy-eyeballs connect that won over
/// IPv6) surfaces its real v6 bytes + scope id, not a silent "unavailable".
fn nameAddress(fd: Fd, kind: NameKind) SocketEndpoint {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        return SocketEndpoint.none;
    }
    const handle: std.posix.fd_t = fdFromBits(fd);
    var storage: std.posix.sockaddr.storage = undefined;
    var address_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.storage);
    const sockaddr_ptr: *std.posix.sockaddr = @ptrCast(&storage);
    const return_code = switch (kind) {
        .local => std.posix.system.getsockname(handle, sockaddr_ptr, &address_len),
        .peer => std.posix.system.getpeername(handle, sockaddr_ptr, &address_len),
    };
    if (std.posix.errno(return_code) != .SUCCESS) return SocketEndpoint.none;
    if (sockaddr_ptr.family == std.posix.AF.INET) {
        const in: *const std.posix.sockaddr.in = @ptrCast(@alignCast(&storage));
        const octets: [4]u8 = @bitCast(in.addr); // network byte order = a.b.c.d
        return .{
            .family = .ip4,
            .v4 = octets,
            .v6 = @splat(0),
            .port = std.mem.bigToNative(u16, in.port),
            .scope_id = 0,
        };
    }
    if (sockaddr_ptr.family == std.posix.AF.INET6) {
        const in6: *const std.posix.sockaddr.in6 = @ptrCast(@alignCast(&storage));
        return .{
            .family = .ip6,
            .v4 = .{ 0, 0, 0, 0 },
            .v6 = in6.addr, // already big-endian
            .port = std.mem.bigToNative(u16, in6.port),
            .scope_id = in6.scope_id,
        };
    }
    return SocketEndpoint.none;
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

/// Count currently-open fds in the low fd range (posix; `0` on the poll-less
/// targets, whose socket tests early-return). `fcntl(F_GETFD)` succeeds for an
/// open fd and fails with `EBADF` for a closed one, so scanning a bounded range
/// yields an EXACT open-fd count for OS-level before/after leak accounting —
/// the only way to see a fd leak that is invisible to the domain's
/// `live_count` (an fd orphaned before it ever reaches the domain). The 4096
/// bound is far above any fd a loopback socket test allocates.
fn countOpenFds() usize {
    switch (comptime builtin.os.tag) {
        .windows, .wasi => return 0,
        else => {
            var count: usize = 0;
            var fd: std.posix.fd_t = 0;
            while (fd < 4096) : (fd += 1) {
                const rc = std.posix.system.fcntl(fd, std.posix.F.GETFD, @as(usize, 0));
                if (std.posix.errno(rc) == .SUCCESS) count += 1;
            }
            return count;
        },
    }
}

test "socket_io: accept observes a pending kill at the top of the quantum and returns promptly without consuming a queued connection" {
    if (builtin.os.tag == .wasi or builtin.os.tag == .windows) return error.SkipZigTest;

    const listener = listenIp4(.{ 127, 0, 0, 1 }, 0, 8);
    try testing.expectEqual(Reason.ok, listener.reason);
    defer closeFd(listener.fd);
    // Queue a connection so `accept` COULD immediately produce an fd if it ran.
    const client = connectIp4(.{ 127, 0, 0, 1 }, listener.bound_port, 5000, null);
    try testing.expectEqual(Reason.ok, client.reason);
    defer closeFd(client.fd);

    // Kill already pending: accept must observe it at the top of the loop and
    // return WITHOUT accepting — the queued connection stays in the kernel
    // backlog (dropped when the listener closes), no new fd is created.
    var kill_flag = std.atomic.Value(bool).init(true);
    const before = countOpenFds();
    const outcome = accept(listener.fd, &kill_flag);
    const after = countOpenFds();

    try testing.expectEqual(Reason.other, outcome.reason);
    try testing.expectEqual(@as(Fd, 0), outcome.fd);
    try testing.expectEqual(before, after);
}

test "socket_io: accept never orphans a just-accepted fd under a racing kill (OS fd count stable across many cycles)" {
    if (builtin.os.tag == .wasi or builtin.os.tag == .windows) return error.SkipZigTest;

    // A background thread flips the kill shortly after `accept` begins, so the
    // flip races the connection's arrival: on some iterations the kill wins at
    // the top of the loop (no accept), on some AFTER `netAccept` (the
    // post-accept close-on-kill path), on some `accept` wins outright (returns
    // a live fd the caller closes). NO path may orphan a fd — proven by the
    // OS-level fd count returning to baseline after every cycle.
    const KillSetter = struct {
        flag: *std.atomic.Value(bool),
        fn run(setter: @This()) void {
            var ts: std.c.timespec = .{ .sec = 0, .nsec = 1 * std.time.ns_per_ms };
            _ = std.c.nanosleep(&ts, null);
            setter.flag.store(true, .release);
        }
    };

    const baseline = countOpenFds();
    var iteration: usize = 0;
    while (iteration < 64) : (iteration += 1) {
        const listener = listenIp4(.{ 127, 0, 0, 1 }, 0, 8);
        try testing.expectEqual(Reason.ok, listener.reason);
        const client = connectIp4(.{ 127, 0, 0, 1 }, listener.bound_port, 5000, null);
        try testing.expectEqual(Reason.ok, client.reason);

        var kill_flag = std.atomic.Value(bool).init(false);
        const setter = try std.Thread.spawn(.{}, KillSetter.run, .{KillSetter{ .flag = &kill_flag }});
        const outcome = accept(listener.fd, &kill_flag);
        setter.join();

        // `.ok` → accept won the race; the caller owns and closes the fd.
        // `.other` → accept closed any just-accepted fd itself (post-accept
        // kill) or never accepted (top-of-loop kill). Either way, no orphan.
        if (outcome.reason == .ok) closeFd(outcome.fd);
        closeFd(client.fd);
        closeFd(listener.fd);
    }

    // Across 64 kill-racing accept cycles the OS fd count is UNCHANGED — an
    // attacker's accept+kill loop cannot exhaust the process's fds.
    try testing.expectEqual(baseline, countOpenFds());
}

test "socket_io: accept DETERMINISTICALLY closes a just-accepted fd when a kill lands in the post-netAccept window" {
    if (builtin.os.tag == .wasi or builtin.os.tag == .windows) return error.SkipZigTest;

    // The racing test above lands in the post-`netAccept` close-on-kill branch
    // only occasionally (the window between `netAccept` returning a connection
    // and the kill re-check is tiny). This test lands there EVERY run via the
    // `test_after_accept_hook` injection seam: the kill flag starts false (so
    // the top-of-loop check passes and `netAccept` proceeds), then the hook —
    // invoked immediately after `netAccept` returns, before the post-accept
    // check — flips it true, so control enters the branch deterministically and
    // the just-accepted fd MUST be closed inside `accept`, with a non-`.ok`
    // reason and a zero fd (never handed back to a tearing-down process).
    const listener = listenIp4(.{ 127, 0, 0, 1 }, 0, 8);
    try testing.expectEqual(Reason.ok, listener.reason);
    defer closeFd(listener.fd);
    // Queue a connection so `netAccept` returns a real fd on the first poll.
    const client = connectIp4(.{ 127, 0, 0, 1 }, listener.bound_port, 5000, null);
    try testing.expectEqual(Reason.ok, client.reason);
    defer closeFd(client.fd);

    // A hook that flips the test-owned kill flag inside the post-accept window.
    const Injector = struct {
        var flag_ptr: *std.atomic.Value(bool) = undefined;
        fn flipKill() void {
            flag_ptr.store(true, .release);
        }
    };
    var kill_flag = std.atomic.Value(bool).init(false);
    Injector.flag_ptr = &kill_flag;
    test_after_accept_hook = Injector.flipKill;
    defer test_after_accept_hook = null;

    // Baseline AFTER the queued connection exists: `accept` will `netAccept`
    // (opening the server-side fd), the hook flips the kill, and the branch
    // closes that fd — so the OS fd count returns exactly to this baseline.
    const before = countOpenFds();
    const outcome = accept(listener.fd, &kill_flag);
    const after = countOpenFds();

    // The branch fired: the just-accepted fd was closed inside `accept`.
    try testing.expectEqual(Reason.other, outcome.reason);
    try testing.expectEqual(@as(Fd, 0), outcome.fd);
    try testing.expect(!outcome.peer.ok);
    // The kill flag was in fact observed as set (the hook ran).
    try testing.expect(kill_flag.load(.acquire));
    // The server-side fd `netAccept` opened was closed by the branch — no leak.
    try testing.expectEqual(before, after);
}

test "socket_io: loopback listen + connect + close round-trips on an ephemeral port" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    const listener = listenIp4(.{ 127, 0, 0, 1 }, 0, 128);
    try testing.expectEqual(Reason.ok, listener.reason);
    try testing.expect(listener.bound_port != 0);
    defer closeFd(listener.fd);

    const client = connectIp4(.{ 127, 0, 0, 1 }, listener.bound_port, 5000, null);
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

    const client = connectIp4(.{ 127, 0, 0, 1 }, dead_port, 1000, null);
    try testing.expect(client.reason != .ok);
}

test "socket_io: accept + full-duplex send/recv echo, binary-safe payload, then EOF on shutdown(write)" {
    if (builtin.os.tag == .wasi or builtin.os.tag == .windows) return error.SkipZigTest;

    const listener = listenIp4(.{ 127, 0, 0, 1 }, 0, 8);
    try testing.expectEqual(Reason.ok, listener.reason);
    defer closeFd(listener.fd);

    const client = connectIp4(.{ 127, 0, 0, 1 }, listener.bound_port, 5000, null);
    try testing.expectEqual(Reason.ok, client.reason);
    defer closeFd(client.fd);

    const accepted = accept(listener.fd, null);
    try testing.expectEqual(Reason.ok, accepted.reason);
    defer closeFd(accepted.fd);
    try testing.expect(accepted.peer.ok);
    try testing.expectEqual(@as(u8, 127), accepted.peer.a);

    // Binary-safe payload: embedded NUL and a non-UTF-8 byte (0xFF).
    const payload = [_]u8{ 'h', 'i', 0, 0xFF, 'z' };
    const sent = send(client.fd, payload[0..], 0, null);
    try testing.expectEqual(Reason.ok, sent.reason);
    try testing.expectEqual(payload.len, sent.bytes_sent);

    const received = try recv(testing.allocator, accepted.fd, payload.len, 0, 5000, null);
    defer testing.allocator.free(received.buffer);
    try testing.expectEqual(@as(i32, recv_status_chunk), received.status);
    try testing.expectEqual(payload.len, received.bytes_filled);
    try testing.expectEqualSlices(u8, payload[0..], received.buffer[0..received.bytes_filled]);

    // Server → client the other way (full duplex on one connection, no split).
    const reply = send(accepted.fd, "pong", 0, null);
    try testing.expectEqual(Reason.ok, reply.reason);
    const got_reply = try recv(testing.allocator, client.fd, 0, 16, 5000, null);
    defer testing.allocator.free(got_reply.buffer);
    try testing.expectEqual(@as(i32, recv_status_chunk), got_reply.status);
    try testing.expectEqualSlices(u8, "pong", got_reply.buffer[0..got_reply.bytes_filled]);

    // Half-close: client shuts down its write side; the server reads EOF
    // (CLOSED), and the client handle stays valid (graceful handshake).
    try testing.expectEqual(Reason.ok, shutdownFd(client.fd, 1));
    const eof = try recv(testing.allocator, accepted.fd, 0, 64, 5000, null);
    defer testing.allocator.free(eof.buffer);
    try testing.expectEqual(@as(i32, recv_status_closed), eof.status);
    try testing.expectEqual(@as(usize, 0), eof.bytes_filled);

    // The local endpoint of the accepted socket is the loopback listener port.
    const local = localAddress(accepted.fd);
    try testing.expectEqual(SocketEndpoint.Family.ip4, local.family);
    try testing.expectEqual(listener.bound_port, local.port);
}

test "socket_io: recv idle-timeout returns timed_out WITHOUT closing the socket" {
    if (builtin.os.tag == .wasi or builtin.os.tag == .windows) return error.SkipZigTest;

    const listener = listenIp4(.{ 127, 0, 0, 1 }, 0, 8);
    try testing.expectEqual(Reason.ok, listener.reason);
    defer closeFd(listener.fd);
    const client = connectIp4(.{ 127, 0, 0, 1 }, listener.bound_port, 5000, null);
    try testing.expectEqual(Reason.ok, client.reason);
    defer closeFd(client.fd);
    const accepted = accept(listener.fd, null);
    try testing.expectEqual(Reason.ok, accepted.reason);
    defer closeFd(accepted.fd);

    // Nothing was sent — the recv must time out (never hang), reporting the
    // timed_out reason, and the socket must still be usable afterwards.
    const timed = try recv(testing.allocator, accepted.fd, 0, 16, 150, null);
    defer testing.allocator.free(timed.buffer);
    try testing.expectEqual(@as(i32, @intFromEnum(Reason.timed_out)), timed.status);

    // Prove the socket survived the timeout: a subsequent send/recv works.
    _ = send(client.fd, "after", 0, null);
    const after = try recv(testing.allocator, accepted.fd, 0, 16, 5000, null);
    defer testing.allocator.free(after.buffer);
    try testing.expectEqual(@as(i32, recv_status_chunk), after.status);
    try testing.expectEqualSlices(u8, "after", after.buffer[0..after.bytes_filled]);
}

test "socket_io: send to a peer that never reads TIMES OUT (slowloris-send), never blocks forever" {
    if (builtin.os.tag == .wasi or builtin.os.tag == .windows) return error.SkipZigTest;

    const listener = listenIp4(.{ 127, 0, 0, 1 }, 0, 8);
    try testing.expectEqual(Reason.ok, listener.reason);
    defer closeFd(listener.fd);
    const client = connectIp4(.{ 127, 0, 0, 1 }, listener.bound_port, 5000, null);
    try testing.expectEqual(Reason.ok, client.reason);
    defer closeFd(client.fd);
    // The peer ACCEPTS but NEVER reads — the OS send buffer fills and a bare
    // blocking `netWrite` loop would pin this thread forever (HIGH-2).
    const accepted = accept(listener.fd, null);
    try testing.expectEqual(Reason.ok, accepted.reason);
    defer closeFd(accepted.fd);

    // A payload far larger than any socket send buffer, so it cannot drain.
    const payload = try std.heap.page_allocator.alloc(u8, 8 * 1024 * 1024);
    defer std.heap.page_allocator.free(payload);
    @memset(payload, 0);

    const before_ms = monotonicMillis();
    const outcome = send(client.fd, payload, 300, null);
    const elapsed_ms = monotonicMillis() - before_ms;

    // It TIMED OUT (never hung) with a partial byte count, promptly.
    try testing.expectEqual(Reason.timed_out, outcome.reason);
    try testing.expect(outcome.bytes_sent < payload.len);
    try testing.expect(elapsed_ms < 4000); // ~300ms deadline, never ~forever

    // A timeout does NOT close the fd — the handle stays valid (Erlang
    // semantics). Draining on the peer lets a further send proceed.
    const drained = try recv(testing.allocator, accepted.fd, 0, 65536, 1000, null);
    testing.allocator.free(drained.buffer);
    try testing.expectEqual(SocketEndpoint.Family.ip4, localAddress(client.fd).family);
}

test "socket_io: connect to a black-hole address is timeout-bounded, never the ~127s OS default" {
    if (builtin.os.tag == .wasi or builtin.os.tag == .windows) return error.SkipZigTest;

    // 192.0.2.1 is TEST-NET-1 (RFC 5737) — routable-looking but a black hole:
    // the SYN goes unanswered. A blocking connect would hang on the OS default
    // (~127s) with the process unkillable; the non-blocking + poll-quantum
    // connect must return PROMPTLY. Whether the environment black-holes the SYN
    // (→ :etimedout) or rejects it immediately (→ a prompt error), the invariant
    // is the same: an ERROR returned well under the OS default (HIGH-2).
    const before_ms = monotonicMillis();
    const outcome = connectIp4(.{ 192, 0, 2, 1 }, 80, 250, null);
    const elapsed_ms = monotonicMillis() - before_ms;

    try testing.expect(outcome.reason != .ok);
    try testing.expect(elapsed_ms < 5000); // never ~127s
}

test "socket_io: recv_exact idle-timeout holds against a dribbling peer (monotonic deadline), surfacing the partial" {
    if (builtin.os.tag == .wasi or builtin.os.tag == .windows) return error.SkipZigTest;

    const listener = listenIp4(.{ 127, 0, 0, 1 }, 0, 8);
    try testing.expectEqual(Reason.ok, listener.reason);
    defer closeFd(listener.fd);
    const client = connectIp4(.{ 127, 0, 0, 1 }, listener.bound_port, 5000, null);
    try testing.expectEqual(Reason.ok, client.reason);
    defer closeFd(client.fd);
    const accepted = accept(listener.fd, null);
    try testing.expectEqual(Reason.ok, accepted.reason);
    defer closeFd(accepted.fd);

    // A background thread dribbles ONE byte every ~20ms (< the 100ms poll
    // quantum), so EVERY poll wakes `.ready`. The old summed-quantum counter
    // only advanced on a `.timeout` poll, so it never advanced here and the
    // deadline was NEVER reached — an unbounded pin. The absolute monotonic
    // deadline fires on wall time regardless of the wake pattern.
    const Dribbler = struct {
        fd: Fd,
        stop: *std.atomic.Value(bool),
        fn run(self: @This()) void {
            var n: usize = 0;
            while (n < 400 and !self.stop.load(.acquire)) : (n += 1) {
                const one = [_]u8{'x'};
                const out = send(self.fd, one[0..], 0, null);
                if (out.reason != .ok) break;
                var ts: std.c.timespec = .{ .sec = 0, .nsec = 20 * std.time.ns_per_ms };
                _ = std.c.nanosleep(&ts, null);
            }
        }
    };
    var stop = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, Dribbler.run, .{Dribbler{ .fd = client.fd, .stop = &stop }});

    // Ask for 200 bytes with a 300ms idle deadline. New code: the deadline
    // fires at ~300ms having read far fewer than 200 (a partial); old code:
    // never times out under the continuous dribble and reads on for seconds.
    const exact_target: usize = 200;
    const before_ms = monotonicMillis();
    const outcome = try recv(testing.allocator, accepted.fd, exact_target, 0, 300, null);
    defer testing.allocator.free(outcome.buffer);
    const elapsed_ms = monotonicMillis() - before_ms;

    stop.store(true, .release);
    thread.join();

    try testing.expectEqual(@as(i32, @intFromEnum(Reason.timed_out)), outcome.status);
    try testing.expect(outcome.bytes_filled < exact_target); // a PARTIAL, not the whole frame
    try testing.expect(outcome.bytes_filled >= 1); // some dribbled bytes were consumed
    try testing.expect(elapsed_ms < 2000); // bounded by the 300ms deadline, not the dribble length

    // The partial bytes are NOT lost — they are surfaced in `bytes_filled`
    // (MED-1), so a caller can resume a framed read without desync.
    for (outcome.buffer[0..outcome.bytes_filled]) |byte| try testing.expectEqual(@as(u8, 'x'), byte);
}

test "socket_io: recv_exact allocation FOLLOWS received bytes, not the peer's speculative target (MED-3)" {
    if (builtin.os.tag == .wasi or builtin.os.tag == .windows) return error.SkipZigTest;

    const listener = listenIp4(.{ 127, 0, 0, 1 }, 0, 8);
    try testing.expectEqual(Reason.ok, listener.reason);
    defer closeFd(listener.fd);
    const client = connectIp4(.{ 127, 0, 0, 1 }, listener.bound_port, 5000, null);
    try testing.expectEqual(Reason.ok, client.reason);
    defer closeFd(client.fd);
    const accepted = accept(listener.fd, null);
    try testing.expectEqual(Reason.ok, accepted.reason);
    defer closeFd(accepted.fd);

    // The peer sends a tiny amount then EOFs, but the reader asks for a HUGE
    // exact frame (as if a 4-byte length prefix decoded to ~1 GiB). The old
    // code allocated the full `exact_target` UP FRONT — a 4-byte → 1 GiB
    // amplification. The new code grows only toward bytes RECEIVED, so it never
    // allocates more than the growth floor here. Proven by backing recv with a
    // SMALL fixed arena (64 KiB): a 1 GiB up-front allocation would fail it, so
    // success is proof the allocation stayed bounded to what actually arrived.
    var backing: [64 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(backing[0..]);

    const payload = "prefix-said-a-gig";
    try testing.expectEqual(Reason.ok, send(client.fd, payload, 0, null).reason);
    try testing.expectEqual(Reason.ok, shutdownFd(client.fd, 1)); // EOF after the few bytes

    const huge_target: usize = 1 << 30; // 1 GiB — far beyond the 64 KiB backing
    const outcome = try recv(fixed.allocator(), accepted.fd, huge_target, 0, 5000, null);
    // Mid-frame EOF (peer done before `huge_target`) → CLOSED, with the partial
    // bytes surfaced; the buffer is shrunk to exactly what arrived.
    try testing.expectEqual(@as(i32, recv_status_closed), outcome.status);
    try testing.expectEqual(payload.len, outcome.bytes_filled);
    try testing.expectEqual(payload.len, outcome.buffer.len); // no speculative slack
    try testing.expectEqualSlices(u8, payload, outcome.buffer[0..outcome.bytes_filled]);
}

test "socket_io: next-available recv SHRINKS the buffer to what arrived (no over-allocation)" {
    if (builtin.os.tag == .wasi or builtin.os.tag == .windows) return error.SkipZigTest;

    const listener = listenIp4(.{ 127, 0, 0, 1 }, 0, 8);
    try testing.expectEqual(Reason.ok, listener.reason);
    defer closeFd(listener.fd);
    const client = connectIp4(.{ 127, 0, 0, 1 }, listener.bound_port, 5000, null);
    try testing.expectEqual(Reason.ok, client.reason);
    defer closeFd(client.fd);
    const accepted = accept(listener.fd, null);
    try testing.expectEqual(Reason.ok, accepted.reason);
    defer closeFd(accepted.fd);

    // A next-available read reserves a moderate chunk (here 65536) but the peer
    // sends only a few bytes: the returned buffer is SHRUNK to exactly those
    // bytes, so the 64 KiB reservation is not handed back (and, for an arena,
    // the tail is reclaimed). The old code returned the full 16 KiB slice's
    // backing wasted into the never-reset arena.
    const payload = "tiny";
    try testing.expectEqual(Reason.ok, send(client.fd, payload, 0, null).reason);

    const outcome = try recv(testing.allocator, accepted.fd, 0, 65536, 5000, null);
    defer testing.allocator.free(outcome.buffer);
    try testing.expectEqual(@as(i32, recv_status_chunk), outcome.status);
    try testing.expectEqual(payload.len, outcome.bytes_filled);
    try testing.expectEqual(payload.len, outcome.buffer.len); // shrunk, not 65536
    try testing.expectEqualSlices(u8, payload, outcome.buffer[0..outcome.bytes_filled]);
}

// ---------------------------------------------------------------------------
// Hostname connect + Happy Eyeballs tests (GAP 1). Loopback-only, deterministic
// where possible: the racing/loser-cleanup/kill tests build the address list
// directly (no DNS dependency) and use `countOpenFds` for exact OS-level fd
// accounting; the end-to-end `connectHost` tests exercise the real resolver.
// ---------------------------------------------------------------------------

const loopback_ip6 = [16]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };

/// Test-only: bind + listen an IPv6 loopback stream socket on `::1:port`
/// (port 0 → ephemeral), returning the fd + bound port, or `null` when the
/// host has no usable IPv6 loopback (the test then skips). Raw syscalls (the
/// S1 listener is IPv4-only); test-scoped, so it never ships.
fn listenIp6ForTest(port: u16) ?struct { fd: std.posix.fd_t, port: u16 } {
    const socket_rc = std.posix.system.socket(std.posix.AF.INET6, std.posix.SOCK.STREAM, std.posix.IPPROTO.TCP);
    if (std.posix.errno(socket_rc) != .SUCCESS) return null;
    const fd: std.posix.fd_t = @intCast(socket_rc);
    var bind_addr = std.mem.zeroInit(std.posix.sockaddr.in6, .{
        .family = std.posix.AF.INET6,
        .port = std.mem.nativeToBig(u16, port),
        .addr = loopback_ip6,
    });
    if (std.posix.errno(std.posix.system.bind(fd, @ptrCast(&bind_addr), @sizeOf(std.posix.sockaddr.in6))) != .SUCCESS) {
        _ = std.posix.system.close(fd);
        return null;
    }
    if (std.posix.errno(std.posix.system.listen(fd, 8)) != .SUCCESS) {
        _ = std.posix.system.close(fd);
        return null;
    }
    var bound = std.mem.zeroes(std.posix.sockaddr.in6);
    var bound_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.in6);
    if (std.posix.errno(std.posix.system.getsockname(fd, @ptrCast(&bound), &bound_len)) != .SUCCESS) {
        _ = std.posix.system.close(fd);
        return null;
    }
    return .{ .fd = fd, .port = std.mem.bigToNative(u16, bound.port) };
}

test "socket_io: connectIp6 connects to an IPv6 loopback listener; peerAddress surfaces the real v6 endpoint" {
    if (builtin.os.tag == .wasi or builtin.os.tag == .windows) return error.SkipZigTest;

    const listener = listenIp6ForTest(0) orelse return error.SkipZigTest; // no IPv6 loopback here
    defer closeFd(listener.fd);

    const outcome = connectIp6(loopback_ip6, listener.port, 0, 0, 5000, null);
    try testing.expectEqual(Reason.ok, outcome.reason);
    defer closeFd(outcome.fd);

    // The runtime side surfaces the REAL v6 endpoint (not a silent "unavailable").
    const peer = peerAddress(outcome.fd);
    try testing.expectEqual(SocketEndpoint.Family.ip6, peer.family);
    try testing.expectEqual(listener.port, peer.port);
    try testing.expectEqualSlices(u8, loopback_ip6[0..], peer.v6[0..]);
    // The local endpoint of an IPv6 socket is also v6-aware.
    const local = localAddress(outcome.fd);
    try testing.expectEqual(SocketEndpoint.Family.ip6, local.family);
}

test "socket_io: happy-eyeballs races a dead IPv6 first, connects to the live IPv4, and leaks no loser fd" {
    if (builtin.os.tag == .wasi or builtin.os.tag == .windows) return error.SkipZigTest;

    // A live IPv4 loopback listener (the intended winner).
    const listener = listenIp4(.{ 127, 0, 0, 1 }, 0, 8);
    try testing.expectEqual(Reason.ok, listener.reason);
    defer closeFd(listener.fd);
    // Reserve a free port number nothing listens on (bind + close a v4 socket),
    // used as the DEAD IPv6 target so the v6 attempt loses.
    const reserved = listenIp4(.{ 127, 0, 0, 1 }, 0, 1);
    try testing.expectEqual(Reason.ok, reserved.reason);
    const dead_port = reserved.bound_port;
    closeFd(reserved.fd);

    const baseline = countOpenFds();
    // RFC-8305-interleaved list: IPv6 ::1 (dead) first, then IPv4 (live). REAL
    // v6+v4 racing — the v6 attempt is created, fails, and its fd is closed by
    // the loser-cleanup guarantee before the v4 winner is returned.
    var addresses = [_]net.IpAddress{
        .{ .ip6 = .{ .bytes = loopback_ip6, .port = dead_port } },
        .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = listener.bound_port } },
    };
    const outcome = raceConnectPosix(addresses[0..], 5000, null);
    try testing.expectEqual(Reason.ok, outcome.reason);

    // The winner is the LIVE IPv4 endpoint (the v6 loser did not win).
    const peer = peerAddress(outcome.fd);
    try testing.expectEqual(SocketEndpoint.Family.ip4, peer.family);
    try testing.expectEqual(listener.bound_port, peer.port);
    closeFd(outcome.fd);

    // EXACTLY-ONCE loser cleanup: the v6 attempt fd was closed by the race, so
    // the OS fd count is back to baseline — no orphaned loser fd.
    try testing.expectEqual(baseline, countOpenFds());
}

test "socket_io: happy-eyeballs closes EVERY attempt fd when all fail (no fd-exhaustion DoS), at the cap" {
    if (builtin.os.tag == .wasi or builtin.os.tag == .windows) return error.SkipZigTest;

    // Reserve `max_connect_attempts` free port numbers nothing listens on, so
    // every attempt in the race fails — proving the loser-cleanup guarantee
    // closes ALL of them (the winner's single-slot invariant never fires).
    var dead_ports: [max_connect_attempts]u16 = undefined;
    for (0..max_connect_attempts) |i| {
        const reserved = listenIp4(.{ 127, 0, 0, 1 }, 0, 1);
        try testing.expectEqual(Reason.ok, reserved.reason);
        dead_ports[i] = reserved.bound_port;
        closeFd(reserved.fd);
    }

    const baseline = countOpenFds();
    var addresses: [max_connect_attempts]net.IpAddress = undefined;
    for (0..max_connect_attempts) |i| {
        addresses[i] = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = dead_ports[i] } };
    }
    const outcome = raceConnectPosix(addresses[0..], 3000, null);
    try testing.expect(outcome.reason != .ok);
    // Every attempt fd was closed — the OS fd count never grew past baseline.
    try testing.expectEqual(baseline, countOpenFds());
}

test "socket_io: connectHost resolves localhost and connects to a live loopback listener, no per-connect fd growth" {
    if (builtin.os.tag == .wasi or builtin.os.tag == .windows) return error.SkipZigTest;

    const listener = listenIp4(.{ 127, 0, 0, 1 }, 0, 8);
    try testing.expectEqual(Reason.ok, listener.reason);
    defer closeFd(listener.fd);

    // The exact loser-cleanup guarantee is proven by the DNS-free race tests
    // above (a single call returns to baseline). Here the end-to-end resolve
    // path is exercised; the platform resolver (`getaddrinfo`) opens PERSISTENT
    // internal fds on first use, so we assert fd STEADY STATE across two
    // connects instead — the first call warms those resolver fds into the
    // count, and the second must not grow it (no per-connect fd leak).
    _ = io();
    const first = connectHost("localhost", listener.bound_port, 5000, null);
    // The sandbox resolver is environment-dependent; skip only if it can't
    // resolve localhost at all (never a false failure of the racing logic).
    if (first.reason == .unknown_host) return error.SkipZigTest;
    try testing.expectEqual(Reason.ok, first.reason);
    // Whatever families localhost resolved to, the loopback listener was
    // reached and every loser (e.g. a refused ::1) was cleaned up.
    const first_peer = peerAddress(first.fd);
    try testing.expectEqual(listener.bound_port, first_peer.port);
    closeFd(first.fd);

    const steady = countOpenFds();
    const second = connectHost("localhost", listener.bound_port, 5000, null);
    try testing.expectEqual(Reason.ok, second.reason);
    closeFd(second.fd);
    // No fd growth across a repeat connect — the racing driver reclaims every
    // loser and the winner is closed, so the count returns to steady state.
    try testing.expectEqual(steady, countOpenFds());
}

test "socket_io: connectHost rejects a syntactically invalid host name with invalid_argument, before any resolve" {
    // No network needed — validation is the first thing `connectHost` does, on
    // every target. A space is not a legal RFC-1123 host character.
    const outcome = connectHost("not a host", 80, 1000, null);
    try testing.expectEqual(Reason.invalid_argument, outcome.reason);
    try testing.expectEqual(@as(Fd, 0), outcome.fd);
}

test "socket_io: connectHost to a black-hole address is deadline-bounded and leaks no fd" {
    if (builtin.os.tag == .wasi or builtin.os.tag == .windows) return error.SkipZigTest;

    _ = io();
    const baseline = countOpenFds();
    // 192.0.2.1 is TEST-NET-1 (RFC 5737) — routable-looking but a black hole; a
    // numeric name resolves to itself, so the race dials it and must time out on
    // the deadline rather than the ~127s OS default.
    const before_ms = monotonicMillis();
    const outcome = connectHost("192.0.2.1", 80, 300, null);
    const elapsed_ms = monotonicMillis() - before_ms;
    try testing.expect(outcome.reason != .ok);
    try testing.expect(elapsed_ms < 5000);
    // The in-flight black-hole attempt fd was reclaimed by the race.
    try testing.expectEqual(baseline, countOpenFds());
}

test "socket_io: connectHost yields promptly to a kill mid-race and reclaims the in-flight attempt fd" {
    if (builtin.os.tag == .wasi or builtin.os.tag == .windows) return error.SkipZigTest;

    _ = io();
    const baseline = countOpenFds();
    var kill_flag = std.atomic.Value(bool).init(false);
    // Flip the kill shortly after the race begins (the numeric name resolves
    // instantly, so the kill lands during the black-hole race, not the resolve).
    const KillSetter = struct {
        flag: *std.atomic.Value(bool),
        fn run(setter: @This()) void {
            var ts: std.c.timespec = .{ .sec = 0, .nsec = 60 * std.time.ns_per_ms };
            _ = std.c.nanosleep(&ts, null);
            setter.flag.store(true, .release);
        }
    };
    const setter = try std.Thread.spawn(.{}, KillSetter.run, .{KillSetter{ .flag = &kill_flag }});
    // A 30s deadline the kill must pre-empt long before it elapses.
    const outcome = connectHost("192.0.2.1", 80, 30000, &kill_flag);
    setter.join();

    try testing.expectEqual(Reason.other, outcome.reason); // killed, not timed out
    try testing.expectEqual(@as(Fd, 0), outcome.fd);
    // All in-flight attempt fds reclaimed on the kill path — fd baseline holds.
    try testing.expectEqual(baseline, countOpenFds());
}

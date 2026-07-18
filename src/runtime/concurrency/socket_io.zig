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
/// across the C-ABI to `runtime.zig`, which forwards the RAW integer unchanged
/// to the Zap layer; the single code → matchable-atom decoder is
/// `SocketError.reason_from_code` (`lib/socket/error.zap`) — the atom table
/// lives in the Zap runtime library, not this kernel, so the mapping stays in
/// ONE place. `ok` is success.
///
/// COUPLING (ABI contract): because `SocketError.reason_from_code` matches
/// these integers POSITIONALLY and no source of truth spans both languages,
/// renumbering a variant would silently remap every Zap reason. The test
/// `"socket_io: Reason integer values are the pinned ABI contract …"` PINS
/// each `@intFromEnum` value below; a renumber breaks it, forcing the Zap
/// table to move in lockstep. Keep the two in sync.
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
/// each quantum, then read `SO_ERROR` on wake to learn the outcome. The fd
/// stays `O_NONBLOCK` for its whole life (the always-non-blocking discipline);
/// `recv`/`send` poll every read/write and tolerate `EAGAIN`, so there is no
/// per-connect restore. A timeout does NOT leak the fd (it is closed on the
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
/// reports the outcome. An immediate connect (common on loopback) returns the
/// live fd directly. The fd stays `O_NONBLOCK` for its whole life (set once in
/// `startAttempt`) — the always-non-blocking discipline: no per-connect restore
/// and no per-send flip, since `recv`/`send` poll every read/write and tolerate
/// `EAGAIN`.
fn connectSingle(address: net.IpAddress, timeout_ms: i64, kill_flag: ?*std.atomic.Value(bool)) ConnectOutcome {
    const start = startAttempt(address);
    switch (start.state) {
        .failed => return .{ .reason = start.reason, .fd = 0 },
        .connected => return .{ .reason = .ok, .fd = fdToBits(start.fd) },
        .in_progress => return awaitConnect(start.fd, timeout_ms, kill_flag),
    }
}

/// The state of one just-issued non-blocking connect (`startAttempt`).
const AttemptState = enum { connected, in_progress, failed };

/// The result of issuing one non-blocking connect: `.connected` = finished
/// synchronously, `fd` live (and stays `O_NONBLOCK` for its whole life — the
/// caller does NOT restore blocking); `.in_progress` = EINPROGRESS, `fd` the
/// pending socket to poll `POLL.OUT`; `.failed` = socket-create or a hard
/// connect error, `fd` already CLOSED and `reason` naming the failure.
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
    // Set non-blocking so `connect` returns EINPROGRESS instead of blocking —
    // and KEEP it for the fd's whole life (the always-non-blocking discipline;
    // `recv`/`send` poll every read/write and tolerate `EAGAIN`, so there is no
    // per-connect restore and no per-send flip).
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
/// the verdict. On success the fd stays `O_NONBLOCK` (the always-non-blocking
/// discipline — `recv`/`send` poll every read/write and tolerate `EAGAIN`, so
/// no blocking restore is needed). On ANY non-success exit
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
/// closes the fd on failure). The fd then stays non-blocking for its whole
/// life (the always-non-blocking discipline). Shared by every posix fd the
/// runtime owns for `recv`/`send`: the connect paths (`startAttempt`) and the
/// just-accepted connection (`accept`).
fn setNonBlocking(handle: net.Socket.Handle) bool {
    const nonblock_bit: usize = @as(usize, 1) << @bitOffsetOf(std.posix.O, "NONBLOCK");
    const flags_rc = std.posix.system.fcntl(handle, std.posix.F.GETFL, @as(usize, 0));
    if (std.posix.errno(flags_rc) != .SUCCESS) return false;
    const flags: usize = @intCast(flags_rc);
    return std.posix.errno(std.posix.system.fcntl(handle, std.posix.F.SETFL, flags | nonblock_bit)) == .SUCCESS;
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
/// `0` is the winner (fd returned, staying `O_NONBLOCK` for life — the
/// always-non-blocking discipline); EVERY other fd — in-flight OR
/// not-yet-started — is closed on THIS thread.
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
                    // handing a live fd back, then claim it. The `defer` closes
                    // every loser; `start.fd` is not in `fds`, so on the kill
                    // path it is closed explicitly here. The winner stays
                    // `O_NONBLOCK` for life (always-non-blocking discipline).
                    if (kill_flag) |flag| {
                        if (flag.load(.acquire)) {
                            _ = std.posix.system.close(start.fd);
                            return .{ .reason = .other, .fd = 0 };
                        }
                    }
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
                // slot so the loser-cleanup defer skips it). The winner stays
                // `O_NONBLOCK` for life (always-non-blocking discipline).
                if (kill_flag) |flag| {
                    if (flag.load(.acquire)) return .{ .reason = .other, .fd = 0 };
                }
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
/// port the kernel chooses, reported as `bound_port`) with `SO_REUSEADDR` set
/// (a just-closed port is immediately rebindable) and `SO_REUSEPORT` OFF — the
/// default listener (`Socket.listen/2`). The pre-bind-option-aware
/// `listenIp4WithOptions` is the general form; this is the byte-identical
/// default wrapper `Socket.listen/2` and every existing caller uses.
pub fn listenIp4(ip: [4]u8, port: u16, backlog: u31) ListenOutcome {
    return listenIp4WithOptions(ip, port, backlog, true, false);
}

/// Bind + listen an IPv4 stream socket on `ip:port` honoring the PRE-BIND
/// options `reuse_address` (`SO_REUSEADDR`) and `reuse_port` (`SO_REUSEPORT`)
/// — both of which the OS only respects when set BEFORE `bind` (§4, item 3).
/// The portable `IpAddress.listen` supports only `reuse_address`, so on posix
/// this issues the socket syscalls directly (`socket` → `setsockopt` the
/// pre-bind flags → `bind` → `listen` → `getsockname` for the ephemeral port),
/// legitimate here because this file IS the socket syscall seam. The poll-less
/// targets (Windows/wasi — not in v1 run scope) keep the portable
/// `IpAddress.listen`, where `reuse_port` is a documented no-op (the portable
/// `ListenOptions` has no such field), matching the connect/recv/send posture.
pub fn listenIp4WithOptions(ip: [4]u8, port: u16, backlog: u31, reuse_address: bool, reuse_port: bool) ListenOutcome {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        const address = net.IpAddress{ .ip4 = .{ .bytes = ip, .port = port } };
        const server = address.listen(io(), .{
            .kernel_backlog = backlog,
            .reuse_address = reuse_address,
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
    return listenIp4Posix(ip, port, backlog, reuse_address, reuse_port);
}

/// The posix raw-syscall listener with pre-bind options (behind
/// `listenIp4WithOptions`): `socket` → `setsockopt` the pre-bind flags → `bind`
/// → `listen` → `getsockname`. The pre-bind flags are applied to the fresh
/// socket BEFORE `bind` (the only point at which `SO_REUSEADDR`/`SO_REUSEPORT`
/// take effect); a create/setsockopt/bind/listen failure closes the transient
/// fd here so a `.failed` result never leaks a fd. The returned fd is BLOCKING
/// (the `socket(2)` default), compatible with the poll-then-blocking
/// `accept`/`recv`. Posix-only.
fn listenIp4Posix(ip: [4]u8, port: u16, backlog: u31, reuse_address: bool, reuse_port: bool) ListenOutcome {
    const socket_rc = std.posix.system.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, std.posix.IPPROTO.TCP);
    if (std.posix.errno(socket_rc) != .SUCCESS)
        return .{ .reason = mapSocketCreateErrno(socket_rc), .fd = 0, .bound_port = 0 };
    const handle: net.Socket.Handle = @intCast(socket_rc);

    // Pre-bind options (item 3): `SO_REUSEADDR`/`SO_REUSEPORT` MUST be set on
    // the fresh socket BEFORE `bind` to take effect.
    if (reuse_address and setOption(fdToBits(handle), .reuse_address, 1) != .ok) {
        _ = std.posix.system.close(handle);
        return .{ .reason = .other, .fd = 0, .bound_port = 0 };
    }
    if (reuse_port and setOption(fdToBits(handle), .reuse_port, 1) != .ok) {
        _ = std.posix.system.close(handle);
        return .{ .reason = .other, .fd = 0, .bound_port = 0 };
    }

    var bind_addr = std.mem.zeroInit(std.posix.sockaddr.in, .{
        .family = std.posix.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = @as(u32, @bitCast(ip)), // [a,b,c,d] in memory == network byte order
    });
    const bind_rc = std.posix.system.bind(handle, @ptrCast(&bind_addr), @sizeOf(std.posix.sockaddr.in));
    if (std.posix.errno(bind_rc) != .SUCCESS) {
        const reason = mapListenErrno(std.posix.errno(bind_rc));
        _ = std.posix.system.close(handle);
        return .{ .reason = reason, .fd = 0, .bound_port = 0 };
    }
    const listen_rc = std.posix.system.listen(handle, backlog);
    if (std.posix.errno(listen_rc) != .SUCCESS) {
        const reason = mapListenErrno(std.posix.errno(listen_rc));
        _ = std.posix.system.close(handle);
        return .{ .reason = reason, .fd = 0, .bound_port = 0 };
    }

    // The kernel-chosen ephemeral port (port 0 → a real port) via getsockname.
    var bound = std.mem.zeroes(std.posix.sockaddr.in);
    var bound_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.in);
    if (std.posix.errno(std.posix.system.getsockname(handle, @ptrCast(&bound), &bound_len)) != .SUCCESS) {
        _ = std.posix.system.close(handle);
        return .{ .reason = .other, .fd = 0, .bound_port = 0 };
    }
    return .{ .reason = .ok, .fd = fdToBits(handle), .bound_port = std.mem.bigToNative(u16, bound.port) };
}

/// Map a `bind(2)`/`listen(2)` errno to a stable `Reason` — the raw-syscall
/// twin of `mapListenError` (which maps the portable `ListenError`).
fn mapListenErrno(err: std.posix.E) Reason {
    return switch (err) {
        .ADDRINUSE => .address_in_use,
        .ADDRNOTAVAIL, .AFNOSUPPORT => .address_unavailable,
        .ACCES => .access_denied,
        .MFILE, .NFILE => .fd_quota_exceeded,
        .NOBUFS, .NOMEM => .out_of_memory,
        else => .other,
    };
}

// ---------------------------------------------------------------------------
// Socket options (setsockopt / getsockopt) — the curated-portable option seam
// (R3, the TCP_NODELAY fix). A curated set of options crosses the runtime↔seam
// boundary as a stable integer tag (`SocketOption`); each is mapped HERE to its
// exact (level, optname) pair and value encoding — the ONE place the per-OS
// socket-option constants live (this file IS the socket syscall seam, so per-OS
// constants are its purpose, exactly like the connect/recv/send syscalls). The
// poll-less targets (Windows/wasi — not in v1 run scope) degrade to a documented
// no-op, matching the rest of the seam: wasi has NO socket API (socket code is
// rejected at compile time via the `:network` capability), and gate-ON Windows
// is blocked on the concurrency 7.2a port, so a Windows binary never reaches a
// live socket op to configure.
// ---------------------------------------------------------------------------

/// A curated, portable socket option, crossing the C-ABI as a stable integer
/// tag. The tag values are an ABI contract with `lib/socket/options.zap`
/// (`Socket.set_options` passes the matching integer), so they are APPEND-ONLY
/// — never renumber an existing option.
pub const SocketOption = enum(i32) {
    /// `TCP_NODELAY` (IPPROTO_TCP) — disable Nagle's algorithm. Value: bool
    /// (`1` on / `0` off). The latency-first option a request/response client
    /// sets to dodge the 40 ms Nagle × delayed-ACK stall.
    nodelay = 0,
    /// `SO_KEEPALIVE` (SOL_SOCKET) — enable TCP keepalive probes. Value: bool.
    keepalive = 1,
    /// `SO_RCVBUF` (SOL_SOCKET) — receive buffer size in bytes. Value: an int
    /// byte count (the OS may round/clamp; Linux stores 2× the requested size).
    recv_buffer = 2,
    /// `SO_SNDBUF` (SOL_SOCKET) — send buffer size in bytes. Value: int bytes.
    send_buffer = 3,
    /// `SO_REUSEADDR` (SOL_SOCKET) — rebind a just-closed address. Value: bool.
    /// Only meaningful BEFORE bind (applied in the listen path pre-bind).
    reuse_address = 4,
    /// `SO_REUSEPORT` (SOL_SOCKET) — allow multiple binds to one addr/port.
    /// Value: bool. Only meaningful BEFORE bind.
    reuse_port = 5,
    /// `IPV6_V6ONLY` (IPPROTO_IPV6) — restrict an AF_INET6 socket to IPv6.
    /// Value: bool. Only valid on an IPv6 socket (`ENOPROTOOPT`/`EINVAL` on an
    /// IPv4 socket — surfaced as `.invalid_argument`).
    ip6_only = 6,
    /// `SO_LINGER` (SOL_SOCKET) — close-time linger. Value: MILLISECONDS
    /// (`< 0` = OFF / OS default; `0` = linger on with a 0 s timeout, the
    /// RST-close affordance; `> 0` = linger on, rounded UP to whole seconds
    /// because the OS `l_linger` field is second-granular).
    linger = 7,
};

/// Validate a raw option code (from `lib/socket/options.zap`) into a
/// `SocketOption`, returning `null` for an out-of-range code so the caller can
/// surface `.invalid_argument` instead of an illegal `@enumFromInt`. The codes
/// are compiler-trusted (emitted by the stdlib, never remote), but validating
/// keeps a future ABI skew a typed failure rather than undefined behavior.
pub fn optionFromCode(code: i64) ?SocketOption {
    if (code < 0) return null;
    inline for (@typeInfo(SocketOption).@"enum".fields) |field| {
        if (code == field.value) return @enumFromInt(field.value);
    }
    return null;
}

/// The (level, optname) pair for a `SocketOption`, resolved from `std.posix`
/// where the fork wires the namespace and from a per-OS literal for
/// `IPV6_V6ONLY` (the fork's `std.posix.IPV6` is not wired for the Darwin
/// family — `darwin.IPV6.V6ONLY = 27` exists but the `c.zig` dispatch omits it
/// — so the seam names the constant directly, exactly as the fork's own per-OS
/// tables do).
const OptionName = struct { level: i32, name: u32 };

fn optionName(option: SocketOption) OptionName {
    return switch (option) {
        .nodelay => .{ .level = std.posix.IPPROTO.TCP, .name = std.posix.TCP.NODELAY },
        .keepalive => .{ .level = std.posix.SOL.SOCKET, .name = std.posix.SO.KEEPALIVE },
        .recv_buffer => .{ .level = std.posix.SOL.SOCKET, .name = std.posix.SO.RCVBUF },
        .send_buffer => .{ .level = std.posix.SOL.SOCKET, .name = std.posix.SO.SNDBUF },
        .reuse_address => .{ .level = std.posix.SOL.SOCKET, .name = std.posix.SO.REUSEADDR },
        .reuse_port => .{ .level = std.posix.SOL.SOCKET, .name = std.posix.SO.REUSEPORT },
        .ip6_only => .{ .level = std.posix.IPPROTO.IPV6, .name = ipv6V6OnlyOptname() },
        .linger => .{ .level = std.posix.SOL.SOCKET, .name = std.posix.SO.LINGER },
    };
}

/// The `IPV6_V6ONLY` optname, per OS: Linux `26`, the BSD/Darwin family `27`.
/// Named directly because the fork's `std.posix.IPV6` namespace resolves to
/// `void` on the Darwin family (its `darwin.IPV6.V6ONLY = 27` is not wired into
/// the `c.zig` dispatch), so `std.posix.IPV6.V6ONLY` will not compile there.
fn ipv6V6OnlyOptname() u32 {
    return switch (comptime builtin.os.tag) {
        .linux => 26,
        else => 27, // Darwin family + the BSDs
    };
}

/// The outcome of a `getOption` read-back: `.ok` with the decoded `value`
/// (an int for the int/bool options; MILLISECONDS for `linger` — `-1` when
/// off), else a mapped failure `Reason` with `value` meaningless.
pub const OptionOutcome = struct { reason: Reason, value: i64 };

/// Encode a `SocketOption`'s Zap-side `value` into the `int`-valued
/// `setsockopt` payload (the `linger` option uses `encodeLinger` instead). The
/// bool options coerce any non-zero to `1`; the buffer sizes are a byte count
/// clamped into the `c_int` range the kernel expects.
fn encodeOptionInt(option: SocketOption, value: i64) i32 {
    return switch (option) {
        .recv_buffer, .send_buffer => @intCast(std.math.clamp(value, 0, std.math.maxInt(i32))),
        else => if (value != 0) 1 else 0,
    };
}

/// Encode a millisecond `linger` value into the OS `linger` struct: `< 0` is
/// OFF (`onoff = 0`); `0` lingers with a 0 s timeout (the RST-close affordance);
/// `> 0` lingers, rounded UP to whole seconds (the `l_linger` field is
/// second-granular), saturating at `maxInt(i32)` seconds.
fn encodeLinger(milliseconds: i64) std.posix.linger {
    if (milliseconds < 0) return .{ .onoff = 0, .linger = 0 };
    const seconds: i64 = if (milliseconds == 0) 0 else @divTrunc(milliseconds + 999, 1000);
    return .{ .onoff = 1, .linger = @intCast(std.math.clamp(seconds, 0, std.math.maxInt(i32))) };
}

/// Apply `option = value` to `fd` via `setsockopt`, returning `.ok` or a mapped
/// failure `Reason`. `value` is interpreted per the option's encoding (int bool
/// / int byte-count / `SO_LINGER` struct from a millisecond value). A
/// synchronous, non-blocking syscall — safe to call inline on any thread (no
/// offload). Poll-less targets: a documented no-op returning `.ok` (see the
/// section header).
pub fn setOption(fd: Fd, option: SocketOption, value: i64) Reason {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        return .ok; // documented no-op on the poll-less targets
    }
    const handle = fdFromBits(fd);
    const target = optionName(option);
    if (option == .linger) {
        var linger_value = encodeLinger(value);
        const rc = std.posix.system.setsockopt(handle, target.level, target.name, @ptrCast(&linger_value), @sizeOf(std.posix.linger));
        return if (std.posix.errno(rc) == .SUCCESS) .ok else mapSetOptErrno(std.posix.errno(rc));
    }
    var int_value: i32 = encodeOptionInt(option, value);
    const rc = std.posix.system.setsockopt(handle, target.level, target.name, @ptrCast(&int_value), @sizeOf(i32));
    return if (std.posix.errno(rc) == .SUCCESS) .ok else mapSetOptErrno(std.posix.errno(rc));
}

/// Read back `option` from `fd` via `getsockopt` — the deterministic proof that
/// a `setOption` actually reached the kernel (a wrong level/optname/encoding
/// would not read back). Returns the decoded value: the raw int for the int/
/// bool options; MILLISECONDS for `linger` (`-1` when off, else `l_linger`
/// seconds × 1000). Poll-less targets: a documented no-op returning `.ok` with
/// `value = 0`.
pub fn getOption(fd: Fd, option: SocketOption) OptionOutcome {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        return .{ .reason = .ok, .value = 0 }; // documented no-op
    }
    const handle = fdFromBits(fd);
    const target = optionName(option);
    if (option == .linger) {
        var linger_value: std.posix.linger = .{ .onoff = 0, .linger = 0 };
        var length: std.posix.socklen_t = @sizeOf(std.posix.linger);
        const rc = std.posix.system.getsockopt(handle, target.level, target.name, @ptrCast(&linger_value), &length);
        if (std.posix.errno(rc) != .SUCCESS) return .{ .reason = mapSetOptErrno(std.posix.errno(rc)), .value = 0 };
        const milliseconds: i64 = if (linger_value.onoff == 0) -1 else @as(i64, linger_value.linger) * 1000;
        return .{ .reason = .ok, .value = milliseconds };
    }
    var int_value: i32 = 0;
    var length: std.posix.socklen_t = @sizeOf(i32);
    const rc = std.posix.system.getsockopt(handle, target.level, target.name, @ptrCast(&int_value), &length);
    if (std.posix.errno(rc) != .SUCCESS) return .{ .reason = mapSetOptErrno(std.posix.errno(rc)), .value = 0 };
    // Normalize the BOOLEAN options to 0/1: BSD/Darwin `getsockopt` returns the
    // option's flag BIT for the SO_* booleans (e.g. `SO_KEEPALIVE` reads back
    // `0x0008`, `SO_REUSEADDR` reads back `0x0004`), so a raw pass-through would
    // leak that platform quirk. The buffer sizes are genuine byte counts and
    // pass through unchanged.
    const decoded: i64 = switch (option) {
        .nodelay, .keepalive, .reuse_address, .reuse_port, .ip6_only => if (int_value != 0) 1 else 0,
        else => int_value,
    };
    return .{ .reason = .ok, .value = decoded };
}

/// Map a `setsockopt`/`getsockopt` errno to a stable `Reason`. An unsupported
/// option or one applied to the wrong socket type (`ENOPROTOOPT`/`EINVAL` — e.g.
/// `IPV6_V6ONLY` on an IPv4 socket) is `invalid_argument`; a bad fd is `other`
/// (the ownership gate already rejects a foreign handle before the syscall).
fn mapSetOptErrno(err: std.posix.E) Reason {
    return switch (err) {
        .NOPROTOOPT, .INVAL, .OPNOTSUPP => .invalid_argument,
        .ACCES, .PERM => .access_denied,
        .NOBUFS, .NOMEM => .out_of_memory,
        else => .other,
    };
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
        // The fd is ALWAYS `O_NONBLOCK` (set once at creation — the
        // always-non-blocking discipline). On the common path the read after a
        // readable poll returns bytes immediately; but a spurious readable wake
        // or a competing reader that drained the socket first can return
        // `EAGAIN`/`EWOULDBLOCK` — which is NOT EOF and NOT an error, so re-poll
        // the quantum (the absolute deadline + `kill_flag` are re-checked at the
        // loop top). `EINTR` re-polls likewise. EVERY other outcome — clean EOF
        // (`0` → CLOSED) and every mapped error — is byte-identical to the prior
        // poll-then-blocking `netRead` path. The poll-less targets (Windows/wasi)
        // keep the fork's blocking `netRead`: their fd is blocking, so a read
        // after a readable poll simply returns the available bytes.
        const read_count: usize = if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) blk: {
            const the_io = io();
            var iovec = [1][]u8{buffer[filled..]};
            break :blk the_io.vtable.netRead(the_io.userdata, handle, iovec[0..]) catch |err|
                return try shrinkRecv(allocator, buffer, @intFromEnum(mapReadError(err)), filled);
        } else blk: {
            const dest = buffer[filled..];
            const rc = std.posix.system.recv(handle, @ptrCast(dest.ptr), dest.len, 0);
            break :blk switch (std.posix.errno(rc)) {
                .SUCCESS => @intCast(rc),
                // No data yet (spurious readable wake / competing reader) or an
                // interrupted read: re-poll — never a false EOF or error.
                .AGAIN, .INTR => continue,
                else => |recv_errno| return try shrinkRecv(allocator, buffer, @intFromEnum(mapRecvErrno(recv_errno)), filled),
            };
        };
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

/// The posix poll-quantum send loop. CRITICAL: the fd is ALWAYS `O_NONBLOCK`
/// (set once at fd creation — the always-non-blocking discipline; NO per-send
/// flip, so no `fcntl` on the send hot path), so each `send` places only what
/// currently fits (or returns `EAGAIN`) and returns immediately. A blocking
/// `write`/`sendmsg` of a large payload blocks until the ENTIRE payload is
/// queued — it does NOT return after merely filling the buffer (unlike `read`,
/// which returns the bytes already available). So poll-then-BLOCKING-write would
/// still pin the pool thread on a peer that accepts and never reads: `POLL.OUT`
/// only reports "≥1 byte of room", after which a blocking write of the remaining
/// megabytes blocks waiting for the peer to drain. (`MSG_DONTWAIT` alone is
/// unreliable on macOS, so `O_NONBLOCK` is the portable mechanism.) Non-blocking
/// writes make the per-quantum deadline and `kill_flag` checks always run
/// (HIGH-2).
fn sendImplPosix(fd: Fd, bytes: []const u8, all: bool, timeout_ms: i64, kill_flag: ?*std.atomic.Value(bool)) SendOutcome {
    const handle = fdFromBits(fd);
    const flags: u32 = std.posix.MSG.NOSIGNAL; // no SIGPIPE; the fd is already O_NONBLOCK

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
/// endpoint (for the accepted socket's `peer_address`, of any family —
/// generalized to `SocketEndpoint` in Phase S2 so an AF_UNIX accept is
/// representable), or a mapped reason. Poll-quantum bounded on the listener fd,
/// so a blocked acceptor is kill-responsive (the S3 graceful-drain seam).
pub const AcceptOutcome = struct {
    reason: Reason,
    fd: Fd,
    peer: SocketEndpoint,
};

/// Test-only injection seam for the deterministic post-accept kill test.
/// `accept`/`acceptAny` invoke this hook (when non-null) IMMEDIATELY after the
/// accept syscall returns a connection and BEFORE the post-accept kill re-check,
/// so a test can flip the `kill_flag` precisely inside that window — landing
/// execution in the close-on-kill branch every run, which the timing-racing
/// test lands only occasionally. Guarded by `comptime builtin.is_test`, so it
/// and its call sites are DEAD CODE (fully elided) in every shipped binary —
/// zero production cost, no reachable seam.
var test_after_accept_hook: ?*const fn () void = null;

/// Accept one connection from a listening socket of EITHER address family
/// (Phase S2), blocking (poll-quantum bounded, kill-checked) until one arrives.
/// The listener's family is probed once via `getsockname`: an AF_UNIX listener
/// routes to the raw-`accept(2)` `acceptAny` path (the fork's `netAccept`/
/// `net.IpAddress` cannot represent a Unix peer), while an IPv4/IPv6 listener
/// keeps the byte-identical S1 `netAccept` path (`acceptInet`) — so TCP accept
/// is unchanged and Unix-domain accept is newly supported. The accepted
/// connection is set `O_NONBLOCK` for its whole life (the always-non-blocking
/// discipline) so `recv`/`send` on it need no per-operation mode flip.
pub fn accept(fd: Fd, kill_flag: ?*std.atomic.Value(bool)) AcceptOutcome {
    return acceptTimeout(fd, kill_flag, 0);
}

/// Accept one connection, bounded by `timeout_ms` (`0` = infinite, the `accept`
/// behavior). The family-probing router `accept` delegates to: an AF_UNIX
/// listener routes to the raw-`accept(2)` `acceptAny` path, an IPv4/IPv6
/// listener to the S1 `netAccept` `acceptInet` path, and `timeout_ms` threads to
/// whichever path is chosen so BOTH honor the same absolute-monotonic deadline
/// (§6.1). A timed-out accept produced NO fd, so it leaks nothing; the accepted
/// connection (on success) is `O_NONBLOCK` for its whole life.
pub fn acceptTimeout(fd: Fd, kill_flag: ?*std.atomic.Value(bool), timeout_ms: i64) AcceptOutcome {
    if (comptime builtin.os.tag != .windows and builtin.os.tag != .wasi) {
        // One cheap, non-blocking `getsockname` (nanoseconds) before the
        // BLOCKING accept — negligible relative to the accept itself — routes a
        // Unix-domain listener to the family-agnostic raw-accept path.
        const handle = fdFromBits(fd);
        var storage: std.posix.sockaddr.storage = undefined;
        var address_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.storage);
        if (std.posix.errno(std.posix.system.getsockname(handle, @ptrCast(&storage), &address_len)) == .SUCCESS) {
            const family: *const std.posix.sockaddr = @ptrCast(&storage);
            if (family.family == std.posix.AF.UNIX) return acceptAny(fd, kill_flag, timeout_ms);
        }
    }
    return acceptInet(fd, kill_flag, timeout_ms);
}

/// The IPv4/IPv6 accept path (the byte-identical S1 `netAccept` implementation,
/// now producing a `SocketEndpoint` peer). Reached from `acceptTimeout` for a
/// non-Unix listener. `timeout_ms > 0` bounds the wait against an ABSOLUTE
/// monotonic deadline (the `awaitConnect` discipline): the poll quantum is
/// clamped so the deadline is observed within one quantum, and expiry returns
/// `.timed_out` (no fd was produced, so nothing leaks). `timeout_ms <= 0` keeps
/// the S1 infinite behavior (poll-quantum-bounded only by the kill flag).
fn acceptInet(fd: Fd, kill_flag: ?*std.atomic.Value(bool), timeout_ms: i64) AcceptOutcome {
    const the_io = io();
    const listen_handle = fdFromBits(fd);
    const has_deadline = timeout_ms > 0;
    const deadline_ms: i64 = if (has_deadline) checkedDeadline(monotonicMillis(), timeout_ms) else 0;
    while (true) {
        if (kill_flag) |flag| {
            if (flag.load(.acquire)) return .{ .reason = .other, .fd = 0, .peer = SocketEndpoint.none };
        }
        var quantum: i32 = poll_quantum_ms;
        if (has_deadline) {
            const remaining = deadline_ms - monotonicMillis();
            if (remaining <= 0) return .{ .reason = .timed_out, .fd = 0, .peer = SocketEndpoint.none };
            if (remaining < quantum) quantum = @intCast(remaining);
        }
        switch (waitReadable(listen_handle, quantum)) {
            .timeout => continue, // re-check deadline + kill
            .failed => return .{ .reason = .other, .fd = 0, .peer = SocketEndpoint.none },
            .ready => {},
        }
        // `net.Server.AcceptOptions` is `void` on some targets (e.g. macOS) and
        // a struct on others — pass the right default for either shape.
        const accept_options: net.Server.AcceptOptions = if (net.Server.AcceptOptions == void) {} else .{};
        const accepted = the_io.vtable.netAccept(the_io.userdata, listen_handle, accept_options) catch |err|
            return .{ .reason = mapAcceptError(err), .fd = 0, .peer = SocketEndpoint.none };
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
                return .{ .reason = .other, .fd = 0, .peer = SocketEndpoint.none };
            }
        }
        // Make the accepted connection `O_NONBLOCK` from birth (the
        // always-non-blocking discipline): the accepted fd does NOT inherit the
        // listener's blocking mode portably, and `recv`/`send` on it require a
        // non-blocking fd (they poll every read/write and tolerate `EAGAIN`), so
        // set it once here rather than flipping per operation. The poll-less
        // targets (Windows/wasi) keep the accepted fd blocking, matching their
        // blocking `netRead`/`netWrite`. On a set failure the just-accepted fd
        // is closed here (never leaked, never handed back unusable).
        if (comptime builtin.os.tag != .windows and builtin.os.tag != .wasi) {
            if (!setNonBlocking(accepted.handle)) {
                var accepted_handle = accepted.handle;
                the_io.vtable.netClose(the_io.userdata, (&accepted_handle)[0..1]);
                return .{ .reason = .other, .fd = 0, .peer = SocketEndpoint.none };
            }
        }
        const peer: SocketEndpoint = switch (accepted.address) {
            .ip4 => |ip4| .{ .family = .ip4, .v4 = ip4.bytes, .v6 = @splat(0), .port = ip4.port, .scope_id = 0 },
            .ip6 => |ip6| .{ .family = .ip6, .v4 = .{ 0, 0, 0, 0 }, .v6 = ip6.bytes, .port = ip6.port, .scope_id = ip6.interface.index },
        };
        return .{ .reason = .ok, .fd = fdToBits(accepted.handle), .peer = peer };
    }
}

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
    /// `.ip4`, `.ip6`, or `.unix` (an AF_UNIX endpoint — Phase S2).
    family: Family,
    /// IPv4 octets (meaningful iff `family == .ip4`).
    v4: [4]u8,
    /// IPv6 bytes, big-endian (meaningful iff `family == .ip6`).
    v6: [16]u8,
    /// Port, native-endian.
    port: u16,
    /// IPv6 zone/scope id (meaningful iff `family == .ip6`; `0` = none).
    scope_id: u32,
    /// The Unix-domain path (meaningful iff `family == .unix`), in the
    /// Zap-visible representation: a filesystem path verbatim, or a Linux
    /// abstract-namespace name with its leading NUL rendered as the `@` prefix
    /// (`SocketAddress.unix`'s convention). `unix_path_len` is its byte length;
    /// `0` marks an UNNAMED/unbound Unix endpoint (surfaced to Zap as
    /// `:unavailable`). Bounded by `max_unix_path`, so it never allocates.
    /// Defaults let the non-Unix literals (`ip4`/`ip6`/`unavailable`) omit it.
    unix_path: [max_unix_path]u8 = @splat(0),
    unix_path_len: usize = 0,

    /// The endpoint's address family. `.unix` (Phase S2) marks an AF_UNIX
    /// endpoint: a socket bound/connected over the Unix-domain. Its `unix_path`
    /// carries the socket path — decoded from the `sun_path` by `nameAddress`
    /// (stream/datagram `local_address`/`peer_address`) and `decodeSockaddr`
    /// (the datagram `recv_from` sender / a Unix `accept`ed peer) — so a bound
    /// Unix endpoint surfaces its path across the ABI (a `recv_peer_path`/
    /// `endpoint_unix_path` accessor → a Zap String → `SocketAddress.unix`), and
    /// only an UNNAMED endpoint (`unix_path_len == 0`) reports `:unavailable`.
    pub const Family = enum { unavailable, ip4, ip6, unix };

    pub const none = SocketEndpoint{
        .family = .unavailable,
        .v4 = .{ 0, 0, 0, 0 },
        .v6 = @splat(0),
        .port = 0,
        .scope_id = 0,
        .unix_path = @splat(0),
        .unix_path_len = 0,
    };

    /// A bare AF_UNIX endpoint marker (no IP address, no port) with an EMPTY
    /// path — the base an UNNAMED Unix endpoint keeps and a named one overwrites
    /// (`nameAddress`/`decodeSockaddr` decode the `sun_path` into `unix_path`).
    pub const unix_endpoint = SocketEndpoint{
        .family = .unix,
        .v4 = .{ 0, 0, 0, 0 },
        .v6 = @splat(0),
        .port = 0,
        .scope_id = 0,
        .unix_path = @splat(0),
        .unix_path_len = 0,
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
// Endpoint → ABI accessors (the IPv6-aware `local_address`/`peer_address` seam)
//
// A single `i64` STRUCTURALLY cannot carry a 16-byte IPv6 address, so the
// Zap-visible `SocketAddress` reconstructs a v6 endpoint from a small set of
// plain-integer accessors instead of one packed code. These pure extractors are
// the SINGLE SOURCE the gate-ON (`abi.zig`) and gate-OFF (`runtime.zig`)
// accessor exports both call — one byte-order contract, unit-tested here in
// isolation. The v4 packed-i64 path (`packEndpoint`) is UNTOUCHED and stays
// byte-identical; these are reached only for a non-v4 endpoint.
// ---------------------------------------------------------------------------

/// The ABI family code for a resolved endpoint: `0` unavailable, `4` IPv4,
/// `6` IPv6. The Zap decoder never needs this directly (the v4 packed code is
/// `>= 0`, and a non-v4 endpoint is disambiguated by `endpointV6Word` returning
/// `-1` for anything but v6), but it is the honest, self-describing companion
/// the seam tests assert against.
pub fn endpointFamilyCode(endpoint: SocketEndpoint) i64 {
    return switch (endpoint.family) {
        .unavailable => 0,
        .unix => 1,
        .ip4 => 4,
        .ip6 => 6,
    };
}

/// The 32-bit big-endian word at `word_index` (`0..3`) of a v6 endpoint's
/// 16-byte address, returned as a NON-NEGATIVE `i64` in `[0, 2^32)` — four
/// network-order address bytes packed `b0*2^24 + b1*2^16 + b2*2^8 + b3`.
///
/// The 128-bit address is surfaced as four 32-bit words (never the two 64-bit
/// halves) precisely so every value fits a non-negative `i64`: a 64-bit half
/// whose top bit is set would bitcast to a NEGATIVE `i64`, and Zap — which has
/// only integer division/remainder, no bitwise ops and no unsigned-64
/// arithmetic — could not then recover the bytes. With 32-bit words the Zap side
/// splits each word into its two hextets with `word / 65536` and
/// `remainder(word, 65536)`, no sign juggling and no String-byte extraction.
///
/// Returns `-1` for any non-IPv6 endpoint (IPv4, or unavailable). That is the
/// sentinel the Zap decoder relies on to distinguish a genuine v6 endpoint —
/// whose words are always `>= 0`, even `::1` whose first three words are `0` —
/// from a truly `:unavailable` one, WITHOUT a separate family round-trip.
pub fn endpointV6Word(endpoint: SocketEndpoint, word_index: usize) i64 {
    if (endpoint.family != .ip6) return -1;
    const base = word_index * 4;
    const b0: i64 = endpoint.v6[base];
    const b1: i64 = endpoint.v6[base + 1];
    const b2: i64 = endpoint.v6[base + 2];
    const b3: i64 = endpoint.v6[base + 3];
    return ((b0 * 256 + b1) * 256 + b2) * 256 + b3;
}

/// The endpoint's port as an `i64` (native-endian, `0..65535`).
pub fn endpointPortValue(endpoint: SocketEndpoint) i64 {
    return endpoint.port;
}

/// The endpoint's IPv6 zone/scope id as an `i64` (`0` = none; meaningful only
/// for a v6 endpoint — a v4 or unavailable endpoint carries `0`).
pub fn endpointScopeValue(endpoint: SocketEndpoint) i64 {
    return endpoint.scope_id;
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

/// Map a non-blocking `recv(2)` errno to a stable `Reason` — the SAME `Reason`
/// set the fork's blocking `netRead` produces (via `mapReadError`), so the
/// always-non-blocking recv is behaviorally IDENTICAL to the prior
/// poll-then-blocking read on every error path. `EAGAIN`/`EWOULDBLOCK` and
/// `EINTR` are handled by the caller's re-poll arm and never reach here.
fn mapRecvErrno(err: std.posix.E) Reason {
    return switch (err) {
        .CONNRESET => .connection_reset,
        .TIMEDOUT => .timed_out,
        .NOTCONN, .PIPE => .connection_reset,
        .NETDOWN => .network_down,
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
    // AF_UNIX (Phase S2): a bound/connected Unix-domain endpoint. Decode its
    // `sun_path` (bounded by `address_len`) into the endpoint's path, so a Unix
    // socket's `local_address`/`peer_address` surface the bound path across the
    // ABI; an unbound endpoint keeps an empty path (→ `:unavailable`).
    if (sockaddr_ptr.family == std.posix.AF.UNIX) return unixEndpoint(&storage, address_len);
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
// Phase S2 — Datagram (UDP) + Unix-domain (Decision C: no fork change; the
// domain is protocol-agnostic — a UDP/unix fd flows through `SocketDomain.open`
// UNCHANGED). Every seam op below mirrors an S1 template (bindUdp ← listenIp4;
// sendTo* ← sendImplPosix; recvFrom ← recv; connectUdp/connectUnix ←
// connectSingle; listenUnix ← listenIp4Posix) and keeps the S1 discipline:
// always-non-blocking fd, poll-quantum + absolute-monotonic-deadline + kill,
// fd never leaked on any error path, bounded buffers, no silent truncation.
// ---------------------------------------------------------------------------

/// The hard cap on a single datagram receive buffer (SECURITY, Decision E):
/// however large a caller asks, at most this many bytes are ever allocated for
/// ONE `recvFrom` — a peer/caller cannot force an unbounded allocation. 65536
/// safely exceeds the maximum UDP payload (65507 for IPv4), so a whole
/// datagram fits when the caller allows it; a larger datagram is truncated to
/// this cap and reported through the distinct truncated channel (never silent).
pub const max_datagram_bytes: usize = 65536;

/// The portable Unix-domain path cap (Decision 3): a path longer than the
/// `sockaddr.un.path` field (`[104]u8`) is rejected on EVERY OS with
/// `invalid_argument`, rather than silently truncated. Filesystem paths need a
/// trailing NUL, so their usable length is one less (`max_unix_path - 1`);
/// abstract-namespace names (Linux, `@`-prefixed → leading NUL) may use the
/// full width.
pub const max_unix_path: usize = 104;

// -- Unix-domain sockaddr ---------------------------------------------------

/// Build the AF_UNIX `sockaddr` for `path` (the `buildSockAddr` twin for the
/// Unix-domain, Phase S2). A leading `@` selects the Linux ABSTRACT namespace
/// (the `@` becomes a leading NUL `sun_path[0]`, so the name lives in an
/// abstract namespace with no filesystem entry — ideal for hermetic tests);
/// any other first byte is a FILESYSTEM path (NUL-terminated in `sun_path`).
///
/// Validation (SECURITY — a caller-supplied path never overflows `sun_path`):
///   * a filesystem path must fit with its NUL terminator (`len <=
///     max_unix_path - 1`);
///   * an abstract name must fit the full field (`len <= max_unix_path`);
///   * the abstract namespace is Linux-only — an `@`-prefixed path on any
///     other OS is `invalid_argument` (no silent reinterpretation).
/// Any violation yields `.reason = .invalid_argument` with `len = 0`.
const UnixSockAddr = struct {
    reason: Reason,
    storage: std.posix.sockaddr.storage,
    len: std.posix.socklen_t,
};

fn buildUnixSockAddr(path: []const u8) UnixSockAddr {
    var result: UnixSockAddr = .{
        .reason = .ok,
        .storage = std.mem.zeroes(std.posix.sockaddr.storage),
        .len = 0,
    };
    const abstract = path.len > 0 and path[0] == '@';
    if (abstract and comptime builtin.os.tag != .linux) {
        // The abstract namespace is a Linux extension; reject `@`-prefixed
        // paths on every other OS rather than treat the `@` as a literal byte.
        result.reason = .invalid_argument;
        return result;
    }
    if (abstract) {
        if (path.len > max_unix_path) {
            result.reason = .invalid_argument;
            return result;
        }
    } else if (path.len == 0 or path.len > max_unix_path - 1) {
        // A filesystem path must be non-empty and leave room for the NUL.
        result.reason = .invalid_argument;
        return result;
    }

    const un: *std.posix.sockaddr.un = @ptrCast(@alignCast(&result.storage));
    un.family = std.posix.AF.UNIX;
    const sun_path_offset = @offsetOf(std.posix.sockaddr.un, "path");
    if (abstract) {
        // Leading NUL selects the abstract namespace; the name is `path[1..]`.
        un.path[0] = 0;
        @memcpy(un.path[1 .. path.len], path[1..]);
        result.len = @intCast(sun_path_offset + path.len);
    } else {
        @memcpy(un.path[0..path.len], path);
        un.path[path.len] = 0; // NUL-terminate the filesystem path
        result.len = @intCast(sun_path_offset + path.len + 1);
    }
    return result;
}

/// Decode the `sun_path` of an AF_UNIX `sockaddr` (`addr_len` is the
/// `getsockname`/`getpeername`/`recvmsg` reported address length) into the
/// Zap-visible path representation written to `out_path`, returning its length.
/// The DECODE twin of `buildUnixSockAddr`: a Linux abstract-namespace name
/// (leading NUL in `sun_path`) is reconstructed with the Zap `@` prefix; a
/// filesystem path is the bytes up to the first NUL. An UNNAMED endpoint
/// (`addr_len` at/below the `sun_path` offset — an unbound Unix datagram sender,
/// or a socket with no bound path) yields `0`, which the bridges surface as
/// `:unavailable`. The write is bounded by `max_unix_path` (a foreign path
/// longer than the portable cap is clamped — a readback approximation; a Zap
/// path is always within the cap), so it never overflows `out_path`.
fn decodeUnixPath(storage: *const std.posix.sockaddr.storage, addr_len: std.posix.socklen_t, out_path: *[max_unix_path]u8) usize {
    const un: *const std.posix.sockaddr.un = @ptrCast(@alignCast(storage));
    const sun_path_offset = @offsetOf(std.posix.sockaddr.un, "path");
    const reported: usize = @intCast(addr_len);
    if (reported <= sun_path_offset) return 0; // unnamed / unbound
    const field_len: usize = @min(reported - sun_path_offset, un.path.len);
    if (field_len == 0) return 0;
    // Abstract namespace (Linux only): the leading NUL selects it and the name
    // is the remaining bytes, surfaced with the Zap `@` prefix.
    if (comptime builtin.os.tag == .linux) {
        if (un.path[0] == 0) {
            const name = un.path[1..field_len];
            const copy_len = @min(name.len, max_unix_path - 1);
            out_path[0] = '@';
            @memcpy(out_path[1 .. 1 + copy_len], name[0..copy_len]);
            return 1 + copy_len;
        }
    }
    // Filesystem path: the bytes up to the first NUL within the reported field.
    var length: usize = 0;
    while (length < field_len and length < max_unix_path and un.path[length] != 0) : (length += 1) {}
    @memcpy(out_path[0..length], un.path[0..length]);
    return length;
}

/// Build a `.unix` `SocketEndpoint` from an AF_UNIX `sockaddr` (length
/// `addr_len`), decoding its `sun_path` into the endpoint's `unix_path` — the
/// shared Unix-endpoint constructor for `nameAddress` (getsockname/getpeername)
/// and `decodeSockaddr` (the recvmsg sender / a Unix `accept`ed peer). An
/// unnamed endpoint keeps an empty path (`unix_path_len == 0`).
fn unixEndpoint(storage: *const std.posix.sockaddr.storage, addr_len: std.posix.socklen_t) SocketEndpoint {
    var endpoint = SocketEndpoint.unix_endpoint;
    endpoint.unix_path_len = decodeUnixPath(storage, addr_len, &endpoint.unix_path);
    return endpoint;
}

/// The Unix-domain path of `endpoint` as a byte slice into its `unix_path`
/// (empty for a non-Unix or UNNAMED endpoint) — the source the Unix-path ABI
/// accessors (`zap_socket_recv_peer_path`/`zap_socket_endpoint_unix_path`) copy
/// into the caller's transient recv arena before handing it to Zap as a String.
/// Takes a pointer so the returned slice views the CALLER's endpoint storage
/// (never a dangling by-value copy); the caller must copy it out before that
/// storage is reused.
pub fn endpointUnixPath(endpoint: *const SocketEndpoint) []const u8 {
    if (endpoint.family != .unix) return &.{};
    return endpoint.unix_path[0..endpoint.unix_path_len];
}

// -- UDP bind ---------------------------------------------------------------

/// Bind a UDP (`SOCK_DGRAM`) socket to `ip:port` (port 0 → an ephemeral port
/// the kernel chooses, reported as `bound_port`) — the datagram twin of
/// `listenIp4` with NO `listen(2)` (a datagram socket has no accept queue).
/// The fd is set `O_NONBLOCK` for its whole life (the always-non-blocking
/// discipline `recvFrom`/`sendTo` rely on). A create/bind failure closes the
/// transient fd here, so a `.failed` result never leaks a fd. The poll-less
/// targets (Windows/wasi — not in v1 run scope) return `.other` (a documented
/// no-op — wasi has no socket API and is rejected by the `:network` capability
/// at compile time; gate-ON Windows awaits the 7.2a port).
pub fn bindUdp(ip: [4]u8, port: u16) ListenOutcome {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        return .{ .reason = .other, .fd = 0, .bound_port = 0 };
    }
    const socket_rc = std.posix.system.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, std.posix.IPPROTO.UDP);
    if (std.posix.errno(socket_rc) != .SUCCESS)
        return .{ .reason = mapSocketCreateErrno(socket_rc), .fd = 0, .bound_port = 0 };
    const handle: net.Socket.Handle = @intCast(socket_rc);
    if (!setNonBlocking(handle)) {
        _ = std.posix.system.close(handle);
        return .{ .reason = .other, .fd = 0, .bound_port = 0 };
    }
    var bind_addr = std.mem.zeroInit(std.posix.sockaddr.in, .{
        .family = std.posix.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = @as(u32, @bitCast(ip)), // [a,b,c,d] in memory == network byte order
    });
    const bind_rc = std.posix.system.bind(handle, @ptrCast(&bind_addr), @sizeOf(std.posix.sockaddr.in));
    if (std.posix.errno(bind_rc) != .SUCCESS) {
        const reason = mapListenErrno(std.posix.errno(bind_rc));
        _ = std.posix.system.close(handle);
        return .{ .reason = reason, .fd = 0, .bound_port = 0 };
    }
    var bound = std.mem.zeroes(std.posix.sockaddr.in);
    var bound_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.in);
    if (std.posix.errno(std.posix.system.getsockname(handle, @ptrCast(&bound), &bound_len)) != .SUCCESS) {
        _ = std.posix.system.close(handle);
        return .{ .reason = .other, .fd = 0, .bound_port = 0 };
    }
    return .{ .reason = .ok, .fd = fdToBits(handle), .bound_port = std.mem.bigToNative(u16, bound.port) };
}

/// Assemble the 16-byte big-endian IPv6 address (`Ip6Address.bytes` layout,
/// network order) from the eight hextets `h0`..`h7` (each a 16-bit group,
/// most-significant first) — the EXACT inverse of `endpointV6Word`'s
/// bytes→word packing and the Zap `SocketAddress.ip6_from_words`/`ip6` decode.
/// It is the ONE place a Zap-side v6 hextet address becomes seam address bytes,
/// shared by the v6 datagram bind/connect/send bridges (`abi.zig` gate-ON,
/// `runtime.zig` gate-OFF) so the byte order is single-sourced. `h0` fills
/// bytes `[0..2]`, `h7` fills bytes `[14..16]`, so `::1` (`h0..h6 = 0`,
/// `h7 = 1`) becomes `{0,…,0,1}`.
pub fn v6BytesFromHextets(hextets: [8]u16) [16]u8 {
    var bytes: [16]u8 = undefined;
    for (hextets, 0..) |hextet, index| {
        bytes[index * 2] = @intCast(hextet >> 8);
        bytes[index * 2 + 1] = @intCast(hextet & 0xff);
    }
    return bytes;
}

/// Bind a UDP (`SOCK_DGRAM`) socket of the IPv6 family to `bytes:port` (port 0 →
/// an ephemeral port the kernel chooses, reported as `bound_port`) — the IPv6
/// twin of `bindUdp`. `bytes` is the big-endian 16-byte address
/// (`v6BytesFromHextets`), `scope_id` the link-local zone index (`0` = none),
/// `flow` the flow label (`0` for an explicitly-dialed endpoint). The fd is set
/// `O_NONBLOCK` for its whole life; a create/bind failure closes the transient
/// fd (never leaked). The poll-less targets (Windows/wasi — not in v1 run scope)
/// return `.other`, matching `bindUdp` (the posix path names `sockaddr.in6`,
/// `void` on wasi, so it is comptime-dead there).
pub fn bindUdp6(bytes: [16]u8, port: u16, scope_id: u32, flow: u32) ListenOutcome {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        return .{ .reason = .other, .fd = 0, .bound_port = 0 };
    }
    const socket_rc = std.posix.system.socket(std.posix.AF.INET6, std.posix.SOCK.DGRAM, std.posix.IPPROTO.UDP);
    if (std.posix.errno(socket_rc) != .SUCCESS)
        return .{ .reason = mapSocketCreateErrno(socket_rc), .fd = 0, .bound_port = 0 };
    const handle: net.Socket.Handle = @intCast(socket_rc);
    if (!setNonBlocking(handle)) {
        _ = std.posix.system.close(handle);
        return .{ .reason = .other, .fd = 0, .bound_port = 0 };
    }
    var bind_addr = std.mem.zeroInit(std.posix.sockaddr.in6, .{
        .family = std.posix.AF.INET6,
        .port = std.mem.nativeToBig(u16, port),
        .flowinfo = flow,
        .addr = bytes, // already big-endian
        .scope_id = scope_id,
    });
    const bind_rc = std.posix.system.bind(handle, @ptrCast(&bind_addr), @sizeOf(std.posix.sockaddr.in6));
    if (std.posix.errno(bind_rc) != .SUCCESS) {
        const reason = mapListenErrno(std.posix.errno(bind_rc));
        _ = std.posix.system.close(handle);
        return .{ .reason = reason, .fd = 0, .bound_port = 0 };
    }
    var bound = std.mem.zeroes(std.posix.sockaddr.in6);
    var bound_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.in6);
    if (std.posix.errno(std.posix.system.getsockname(handle, @ptrCast(&bound), &bound_len)) != .SUCCESS) {
        _ = std.posix.system.close(handle);
        return .{ .reason = .other, .fd = 0, .bound_port = 0 };
    }
    return .{ .reason = .ok, .fd = fdToBits(handle), .bound_port = std.mem.bigToNative(u16, bound.port) };
}

/// Bind a Unix-domain DATAGRAM (`AF_UNIX`/`SOCK_DGRAM`) socket to `path` — the
/// receiving end of a Unix datagram exchange. `path` is validated by
/// `buildUnixSockAddr` (length + abstract-namespace rules); the fd is set
/// `O_NONBLOCK`. Filesystem-path cleanup is caller-managed (Decision 4:
/// unlink-before-bind), so a stale socket file surfaces as `address_in_use`.
/// `bound_port` is always `0` (a Unix socket has no port). The transient fd is
/// closed on any failure (never leaked). Poll-less targets: `.other`.
pub fn bindUnixDatagram(path: []const u8) ListenOutcome {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        return .{ .reason = .other, .fd = 0, .bound_port = 0 };
    }
    const address = buildUnixSockAddr(path);
    if (address.reason != .ok) return .{ .reason = address.reason, .fd = 0, .bound_port = 0 };
    const socket_rc = std.posix.system.socket(std.posix.AF.UNIX, std.posix.SOCK.DGRAM, 0);
    if (std.posix.errno(socket_rc) != .SUCCESS)
        return .{ .reason = mapSocketCreateErrno(socket_rc), .fd = 0, .bound_port = 0 };
    const handle: net.Socket.Handle = @intCast(socket_rc);
    if (!setNonBlocking(handle)) {
        _ = std.posix.system.close(handle);
        return .{ .reason = .other, .fd = 0, .bound_port = 0 };
    }
    var storage = address.storage;
    const bind_rc = std.posix.system.bind(handle, @ptrCast(&storage), address.len);
    if (std.posix.errno(bind_rc) != .SUCCESS) {
        const reason = mapListenErrno(std.posix.errno(bind_rc));
        _ = std.posix.system.close(handle);
        return .{ .reason = reason, .fd = 0, .bound_port = 0 };
    }
    return .{ .reason = .ok, .fd = fdToBits(handle), .bound_port = 0 };
}

// -- Datagram send (sendto — ONE atomic datagram, never a partial loop) -----

/// Send `bytes` as ONE datagram to the IPv4 `ip:port` (`sendToIp4`) — the
/// unconnected UDP send. A datagram is ATOMIC: it is delivered whole or not at
/// all, so there is NO all-or-error byte loop (unlike stream `send`); an
/// oversize payload fails with `EMSGSIZE` → `.invalid_argument` rather than a
/// partial send. Bounded by `timeout_ms` + `kill_flag` through the same
/// poll-`POLL.OUT`-quantum machinery stream send uses (a full socket send
/// buffer yields `EAGAIN`, re-polled). On success `bytes_sent == bytes.len`.
pub fn sendToIp4(fd: Fd, ip: [4]u8, port: u16, bytes: []const u8, timeout_ms: i64, kill_flag: ?*std.atomic.Value(bool)) SendOutcome {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        // Poll-less targets (not in v1 run scope): a documented no-op. The
        // posix path below (which names `std.posix.sockaddr.in`, a type that is
        // `void` on wasi) is comptime-dead here, so it is never analyzed —
        // exactly the guard posture `connectIp4`/`bindUdp` take.
        return .{ .reason = .other, .bytes_sent = 0 };
    }
    const dest = std.mem.zeroInit(std.posix.sockaddr.in, .{
        .family = std.posix.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = @as(u32, @bitCast(ip)),
    });
    return sendToPosix(fd, bytes, @ptrCast(&dest), @sizeOf(std.posix.sockaddr.in), timeout_ms, kill_flag);
}

/// Send `bytes` as ONE datagram to the IPv6 `bytes:port` (`sendToIp6`). The
/// IPv6 twin of `sendToIp4` (`sockaddr_in6` carrying flow label + scope id).
pub fn sendToIp6(fd: Fd, addr: [16]u8, port: u16, scope_id: u32, flow: u32, bytes: []const u8, timeout_ms: i64, kill_flag: ?*std.atomic.Value(bool)) SendOutcome {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        return .{ .reason = .other, .bytes_sent = 0 }; // documented no-op (see `sendToIp4`)
    }
    const dest = std.mem.zeroInit(std.posix.sockaddr.in6, .{
        .family = std.posix.AF.INET6,
        .port = std.mem.nativeToBig(u16, port),
        .flowinfo = flow,
        .addr = addr, // already big-endian
        .scope_id = scope_id,
    });
    return sendToPosix(fd, bytes, @ptrCast(&dest), @sizeOf(std.posix.sockaddr.in6), timeout_ms, kill_flag);
}

/// Send `bytes` as ONE Unix-domain datagram to `path` (`sendToUnix`). `path` is
/// validated by `buildUnixSockAddr`; a bad path is `.invalid_argument` (never a
/// syscall on an overflowing address). Otherwise identical to `sendToIp4` (one
/// atomic `sendto`, poll-quantum bounded).
pub fn sendToUnix(fd: Fd, path: []const u8, bytes: []const u8, timeout_ms: i64, kill_flag: ?*std.atomic.Value(bool)) SendOutcome {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        // Documented no-op (see `sendToIp4`): `buildUnixSockAddr` below names
        // `std.posix.sockaddr.un`/`.storage`, `void` on wasi, so this comptime-
        // dead posix path is never analyzed on the poll-less targets.
        return .{ .reason = .other, .bytes_sent = 0 };
    }
    const address = buildUnixSockAddr(path);
    if (address.reason != .ok) return .{ .reason = address.reason, .bytes_sent = 0 };
    var storage = address.storage;
    return sendToPosix(fd, bytes, @ptrCast(&storage), address.len, timeout_ms, kill_flag);
}

/// The shared posix `sendto` datagram send behind `sendToIp4`/`Ip6`/`Unix`.
/// ONE atomic `sendto` (a datagram is all-or-nothing) bounded by the poll-
/// quantum + absolute monotonic deadline + kill loop. `EAGAIN` (a transiently
/// full send buffer) re-polls `POLL.OUT`; `EMSGSIZE` (payload exceeds the
/// datagram max) is `.invalid_argument`. On the poll-less targets a blocking
/// `sendto` runs with the timeout a documented no-op (`waitWritable` returns
/// `.ready`), matching the stream-send posture.
fn sendToPosix(fd: Fd, bytes: []const u8, dest: *const std.posix.sockaddr, dest_len: std.posix.socklen_t, timeout_ms: i64, kill_flag: ?*std.atomic.Value(bool)) SendOutcome {
    const handle = fdFromBits(fd);
    const flags: u32 = std.posix.MSG.NOSIGNAL; // the fd is already O_NONBLOCK
    const has_deadline = timeout_ms > 0;
    const deadline_ms: i64 = if (has_deadline) checkedDeadline(monotonicMillis(), timeout_ms) else 0;
    while (true) {
        if (kill_flag) |flag| {
            if (flag.load(.acquire)) return .{ .reason = .other, .bytes_sent = 0 };
        }
        var quantum: i32 = poll_quantum_ms;
        if (has_deadline) {
            const remaining = deadline_ms - monotonicMillis();
            if (remaining <= 0) return .{ .reason = .timed_out, .bytes_sent = 0 };
            if (remaining < quantum) quantum = @intCast(remaining);
        }
        switch (waitWritable(handle, quantum)) {
            .timeout => continue, // re-check deadline + kill
            .failed => return .{ .reason = .other, .bytes_sent = 0 },
            .ready => {},
        }
        const rc = std.posix.system.sendto(handle, @ptrCast(bytes.ptr), bytes.len, flags, dest, dest_len);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return .{ .reason = .ok, .bytes_sent = @intCast(rc) },
            // Send buffer transiently full, or interrupted — re-poll.
            .AGAIN, .INTR => {},
            // The datagram is larger than the datagram maximum: a typed reject,
            // NOT a partial (a datagram cannot be split).
            .MSGSIZE => return .{ .reason = .invalid_argument, .bytes_sent = 0 },
            else => |send_errno| return .{ .reason = mapSendErrno(send_errno), .bytes_sent = 0 },
        }
    }
}

// -- Datagram receive (recvmsg — MSG_TRUNC truncation detection) ------------

/// The outcome of a `recvFrom`: a stable status (same encoding as `RecvOutcome`
/// MINUS the CLOSED case — a datagram socket has no EOF), the (caller-owned)
/// buffer holding the captured bytes, the sender's endpoint, whether the
/// datagram was TRUNCATED (larger than the buffer — surfaced through the
/// distinct `Truncated` variant, never silently dropped), and the datagram's
/// true length (exact on Linux via the `MSG_TRUNC` recv flag; the captured
/// length — the floor — on macOS, where the truncated FLAG is still exact).
///
///   * `status == 0` — a DATAGRAM: `bytes_filled` bytes are in `buffer`.
///   * `status > 0` — FAILED: the value is a `Reason` code (`timed_out == 2`
///     is the idle-timeout case; the socket stays OPEN, Decision E).
/// There is NO `status < 0` (CLOSED) case for datagrams.
pub const RecvFromOutcome = struct {
    status: i32,
    buffer: []u8,
    bytes_filled: usize,
    truncated: bool,
    datagram_len: usize,
    peer: SocketEndpoint,
};

/// Receive ONE datagram into a fresh buffer allocated from `allocator`,
/// capturing the sender's endpoint and detecting truncation — the datagram
/// twin of `recv`. `max_bytes` is CLAMPED to `max_datagram_bytes` (SECURITY:
/// no unbounded allocation), and exactly ONE fixed-capacity buffer is allocated
/// (a datagram is atomic — there is no growth loop). Uses `recvmsg` so the
/// out `msg_flags & MSG_TRUNC` reports truncation on BOTH macOS and Linux;
/// additionally, on Linux the `MSG_TRUNC` recv flag makes the return value the
/// datagram's TRUE length even when truncated (macOS reports the captured
/// length — the floor). Bounded by `timeout_ms` + `kill_flag` through the same
/// poll-`POLL.IN`-quantum loop `recv` uses; a timeout leaves the socket OPEN.
/// The returned `buffer` is owned by `allocator` and is exactly `bytes_filled`
/// bytes (a zero-length datagram is valid — `status == 0`, `bytes_filled == 0`,
/// an empty buffer). Returns `error.OutOfMemory` if the buffer cannot be
/// allocated (nothing leaked).
pub fn recvFrom(
    allocator: std.mem.Allocator,
    fd: Fd,
    max_bytes: usize,
    timeout_ms: i64,
    kill_flag: ?*std.atomic.Value(bool),
) error{OutOfMemory}!RecvFromOutcome {
    const capacity: usize = @min(@max(max_bytes, 1), max_datagram_bytes);
    const buffer = try allocator.alloc(u8, capacity);
    errdefer allocator.free(buffer);
    const handle = fdFromBits(fd);

    const has_deadline = timeout_ms > 0;
    const deadline_ms: i64 = if (has_deadline) checkedDeadline(monotonicMillis(), timeout_ms) else 0;
    while (true) {
        if (kill_flag) |flag| {
            // Killed while parked: report as a benign "no datagram" (the socket
            // is about to be reclaimed by the teardown sweep anyway). Free the
            // buffer — nothing arrived.
            if (flag.load(.acquire)) return shrinkRecvFrom(allocator, buffer, @intFromEnum(Reason.other), 0, false, 0, SocketEndpoint.none);
        }
        var quantum: i32 = poll_quantum_ms;
        if (has_deadline) {
            const remaining = deadline_ms - monotonicMillis();
            if (remaining <= 0) return shrinkRecvFrom(allocator, buffer, @intFromEnum(Reason.timed_out), 0, false, 0, SocketEndpoint.none);
            if (remaining < quantum) quantum = @intCast(remaining);
        }
        switch (waitReadable(handle, quantum)) {
            .timeout => continue, // re-check deadline + kill
            .failed => return shrinkRecvFrom(allocator, buffer, @intFromEnum(Reason.other), 0, false, 0, SocketEndpoint.none),
            .ready => {},
        }
        // On the poll-less targets there is no recvmsg path in v1 run scope;
        // the socket layer is compile-rejected on wasi and gate-ON Windows is
        // blocked on the 7.2a port, so this leaf is only reached on posix.
        if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) {
            return shrinkRecvFrom(allocator, buffer, @intFromEnum(Reason.other), 0, false, 0, SocketEndpoint.none);
        }
        var peer_storage: std.posix.sockaddr.storage = std.mem.zeroes(std.posix.sockaddr.storage);
        var iov = [1]std.posix.iovec{.{ .base = buffer.ptr, .len = buffer.len }};
        var message: std.posix.msghdr = std.mem.zeroes(std.posix.msghdr);
        message.name = @ptrCast(&peer_storage);
        message.namelen = @sizeOf(std.posix.sockaddr.storage);
        message.iov = iov[0..].ptr;
        message.iovlen = 1;
        // Linux: pass MSG_TRUNC as an INPUT flag so the return value is the
        // datagram's TRUE length even when the buffer truncates it. macOS does
        // not support that input flag, so the return there is the captured
        // length (the floor) — but the OUTPUT `msg_flags & MSG_TRUNC` is exact
        // on both, so the truncated VARIANT is always correct.
        const input_flags: u32 = if (comptime builtin.os.tag == .linux) std.posix.MSG.TRUNC else 0;
        const rc = std.posix.system.recvmsg(handle, &message, input_flags);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const returned: usize = @intCast(rc);
                // `returned` is the true datagram length on Linux (MSG_TRUNC
                // input flag) and the captured length on macOS; the bytes
                // actually written are min(returned, buffer.len).
                const captured: usize = @min(returned, buffer.len);
                const truncated = (message.flags & std.posix.MSG.TRUNC) != 0;
                // datagram_len: the true length where known (Linux `returned`),
                // else the captured floor (macOS). Never less than `captured`.
                const datagram_len: usize = @max(returned, captured);
                // `msg_namelen` is updated by `recvmsg` to the sender address's
                // true length — the bound it takes to decode a Unix `sun_path`.
                const peer = decodeSockaddr(&peer_storage, @intCast(message.namelen));
                return shrinkRecvFrom(allocator, buffer, recv_status_chunk, captured, truncated, datagram_len, peer);
            },
            // Spurious readable wake / competing reader / interrupted — re-poll.
            .AGAIN, .INTR => continue,
            else => |recv_errno| return shrinkRecvFrom(allocator, buffer, @intFromEnum(mapRecvErrno(recv_errno)), 0, false, 0, SocketEndpoint.none),
        }
    }
}

/// Shrink `buffer` to exactly `filled` bytes and package the `recvFrom`
/// outcome — the datagram twin of `shrinkRecv`. A zero-length result frees the
/// buffer and returns an empty slice; a zero-length DATAGRAM (`status == 0`,
/// `filled == 0`) is legitimate and still returns an empty, non-error outcome.
fn shrinkRecvFrom(
    allocator: std.mem.Allocator,
    buffer: []u8,
    status: i32,
    filled: usize,
    truncated: bool,
    datagram_len: usize,
    peer: SocketEndpoint,
) error{OutOfMemory}!RecvFromOutcome {
    if (filled == 0) {
        allocator.free(buffer);
        return .{ .status = status, .buffer = &.{}, .bytes_filled = 0, .truncated = truncated, .datagram_len = datagram_len, .peer = peer };
    }
    if (filled == buffer.len)
        return .{ .status = status, .buffer = buffer, .bytes_filled = filled, .truncated = truncated, .datagram_len = datagram_len, .peer = peer };
    const shrunk = allocator.realloc(buffer, filled) catch buffer;
    return .{ .status = status, .buffer = shrunk, .bytes_filled = filled, .truncated = truncated, .datagram_len = datagram_len, .peer = peer };
}

/// Decode a filled `sockaddr.storage` (the sender of a received datagram, or a
/// Unix `accept`ed peer) of reported length `addr_len` into a `SocketEndpoint` —
/// the recvmsg-name twin of `nameAddress`'s decode. An AF_UNIX sender carries
/// its bound `sun_path` (decoded into the endpoint's path via `unixEndpoint`);
/// an unnamed sender (`family == AF_UNSPEC` / a zero-length name, common for an
/// UNBOUND Unix datagram sender) surfaces `.unavailable` (a bound sender's path
/// lets a Unix datagram server reply to it).
fn decodeSockaddr(storage: *const std.posix.sockaddr.storage, addr_len: std.posix.socklen_t) SocketEndpoint {
    const sockaddr_ptr: *const std.posix.sockaddr = @ptrCast(storage);
    if (sockaddr_ptr.family == std.posix.AF.INET) {
        const in: *const std.posix.sockaddr.in = @ptrCast(@alignCast(storage));
        const octets: [4]u8 = @bitCast(in.addr);
        return .{ .family = .ip4, .v4 = octets, .v6 = @splat(0), .port = std.mem.bigToNative(u16, in.port), .scope_id = 0 };
    }
    if (sockaddr_ptr.family == std.posix.AF.INET6) {
        const in6: *const std.posix.sockaddr.in6 = @ptrCast(@alignCast(storage));
        return .{ .family = .ip6, .v4 = .{ 0, 0, 0, 0 }, .v6 = in6.addr, .port = std.mem.bigToNative(u16, in6.port), .scope_id = in6.scope_id };
    }
    if (sockaddr_ptr.family == std.posix.AF.UNIX) return unixEndpoint(storage, addr_len);
    return SocketEndpoint.none;
}

// -- Connected UDP (connect(2) on SOCK_DGRAM completes immediately) ----------

/// Connect a UDP socket to the IPv4 `ip:port` (`connectUdpIp4`). Unlike a
/// stream connect, `connect(2)` on a `SOCK_DGRAM` socket completes IMMEDIATELY
/// (no handshake, no poll loop): it merely sets the default peer, after which
/// the kernel FILTERS inbound datagrams to that peer and `send`/`recv` (not
/// `sendto`/`recvfrom`) address it. The fd is `O_NONBLOCK` for life. A create/
/// connect failure closes the transient fd (never leaked). Poll-less targets:
/// `.other` (documented no-op).
pub fn connectUdpIp4(ip: [4]u8, port: u16) ConnectOutcome {
    return connectUdpPosix(.{ .ip4 = .{ .bytes = ip, .port = port } });
}

/// Connect a UDP socket to the IPv6 `bytes:port` (`connectUdpIp6`) — the IPv6
/// twin of `connectUdpIp4` (immediate, no poll loop).
pub fn connectUdpIp6(addr: [16]u8, port: u16, scope_id: u32, flow: u32) ConnectOutcome {
    return connectUdpPosix(.{ .ip6 = .{ .bytes = addr, .port = port, .flow = flow, .interface = .{ .index = scope_id } } });
}

/// The shared posix connected-UDP path: create a non-blocking `SOCK_DGRAM`
/// socket for `address`'s family and `connect(2)` it (which completes
/// synchronously for a datagram socket). The transient fd is closed on any
/// failure so a `.failed` outcome never leaks a fd.
fn connectUdpPosix(address: net.IpAddress) ConnectOutcome {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        return .{ .reason = .other, .fd = 0 };
    }
    const socket_rc = switch (address) {
        .ip4 => std.posix.system.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, std.posix.IPPROTO.UDP),
        .ip6 => std.posix.system.socket(std.posix.AF.INET6, std.posix.SOCK.DGRAM, std.posix.IPPROTO.UDP),
    };
    if (std.posix.errno(socket_rc) != .SUCCESS)
        return .{ .reason = mapSocketCreateErrno(socket_rc), .fd = 0 };
    const handle: net.Socket.Handle = @intCast(socket_rc);
    if (!setNonBlocking(handle)) {
        _ = std.posix.system.close(handle);
        return .{ .reason = .other, .fd = 0 };
    }
    const sa = buildSockAddr(address);
    const connect_rc = std.posix.system.connect(handle, @ptrCast(&sa.storage), sa.len);
    switch (std.posix.errno(connect_rc)) {
        .SUCCESS => return .{ .reason = .ok, .fd = fdToBits(handle) },
        else => |connect_errno| {
            _ = std.posix.system.close(handle);
            return .{ .reason = mapConnectErrno(connect_errno), .fd = 0 };
        },
    }
}

// -- Unix-domain stream (listen / connect) ----------------------------------

/// Bind + `listen` a Unix-domain STREAM (`AF_UNIX`/`SOCK_STREAM`) socket on
/// `path` — the Unix twin of `listenIp4Posix` (no port, no `SO_REUSEADDR`).
/// `path` is validated by `buildUnixSockAddr`. Filesystem-path cleanup is
/// caller-managed (Decision 4: unlink-before-bind — a stale socket file
/// surfaces as `address_in_use`). The returned listener fd is BLOCKING (the
/// `socket(2)` default), compatible with the poll-then-blocking `accept`. A
/// create/bind/listen failure closes the transient fd (never leaked).
/// `bound_port` is `0`. Poll-less targets: `.other`.
pub fn listenUnix(path: []const u8, backlog: u31) ListenOutcome {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        return .{ .reason = .other, .fd = 0, .bound_port = 0 };
    }
    const address = buildUnixSockAddr(path);
    if (address.reason != .ok) return .{ .reason = address.reason, .fd = 0, .bound_port = 0 };
    const socket_rc = std.posix.system.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    if (std.posix.errno(socket_rc) != .SUCCESS)
        return .{ .reason = mapSocketCreateErrno(socket_rc), .fd = 0, .bound_port = 0 };
    const handle: net.Socket.Handle = @intCast(socket_rc);
    var storage = address.storage;
    const bind_rc = std.posix.system.bind(handle, @ptrCast(&storage), address.len);
    if (std.posix.errno(bind_rc) != .SUCCESS) {
        const reason = mapListenErrno(std.posix.errno(bind_rc));
        _ = std.posix.system.close(handle);
        return .{ .reason = reason, .fd = 0, .bound_port = 0 };
    }
    const listen_rc = std.posix.system.listen(handle, backlog);
    if (std.posix.errno(listen_rc) != .SUCCESS) {
        const reason = mapListenErrno(std.posix.errno(listen_rc));
        _ = std.posix.system.close(handle);
        return .{ .reason = reason, .fd = 0, .bound_port = 0 };
    }
    return .{ .reason = .ok, .fd = fdToBits(handle), .bound_port = 0 };
}

/// Connect a Unix-domain STREAM socket to `path` — the Unix twin of
/// `connectSingle`, using a raw non-blocking `socket(AF_UNIX)` +
/// `connect(sockaddr_un)`. For a loopback Unix socket the connect completes
/// IMMEDIATELY (no network handshake); a still-in-progress connect (`EAGAIN`/
/// `EINPROGRESS`) is polled `POLL.OUT` on the shared `awaitConnect` machinery,
/// bounded by `timeout_ms` + `kill_flag`. `path` is validated by
/// `buildUnixSockAddr`. The fd stays `O_NONBLOCK` for life; the transient fd is
/// closed on any failure (never leaked). Poll-less targets: `.other`.
pub fn connectUnix(path: []const u8, timeout_ms: i64, kill_flag: ?*std.atomic.Value(bool)) ConnectOutcome {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        return .{ .reason = .other, .fd = 0 };
    }
    const address = buildUnixSockAddr(path);
    if (address.reason != .ok) return .{ .reason = address.reason, .fd = 0 };
    const socket_rc = std.posix.system.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    if (std.posix.errno(socket_rc) != .SUCCESS)
        return .{ .reason = mapSocketCreateErrno(socket_rc), .fd = 0 };
    const handle: net.Socket.Handle = @intCast(socket_rc);
    if (!setNonBlocking(handle)) {
        _ = std.posix.system.close(handle);
        return .{ .reason = .other, .fd = 0 };
    }
    var storage = address.storage;
    const connect_rc = std.posix.system.connect(handle, @ptrCast(&storage), address.len);
    switch (std.posix.errno(connect_rc)) {
        .SUCCESS => return .{ .reason = .ok, .fd = fdToBits(handle) },
        .INPROGRESS, .INTR, .AGAIN => return awaitConnect(handle, timeout_ms, kill_flag),
        else => |connect_errno| {
            _ = std.posix.system.close(handle);
            return .{ .reason = mapConnectErrno(connect_errno), .fd = 0 };
        },
    }
}

/// Accept one connection from a listening socket of EITHER family (the S2
/// generalization of `accept`): a raw non-blocking `accept(2)` over a
/// `sockaddr.storage`, poll-quantum + kill bounded exactly like `accept`, whose
/// accepted-peer decode is the family-agnostic `decodeSockaddr` (so an AF_UNIX
/// listener — which the fork's `netAccept`/`net.IpAddress` cannot represent —
/// works). The accepted fd is set `O_NONBLOCK` from birth. A kill observed at
/// the top of the loop, or in the post-`accept` window, closes any just-
/// accepted fd on THIS thread (never handed to a tearing-down process — the
/// HIGH-1 discipline). This is the seam for Unix-domain stream accept; the
/// IPv4/IPv6 path keeps the byte-identical `accept` (`netAccept`) above.
pub fn acceptAny(fd: Fd, kill_flag: ?*std.atomic.Value(bool), timeout_ms: i64) AcceptOutcome {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        return .{ .reason = .other, .fd = 0, .peer = SocketEndpoint.none };
    }
    const listen_handle = fdFromBits(fd);
    const has_deadline = timeout_ms > 0;
    const deadline_ms: i64 = if (has_deadline) checkedDeadline(monotonicMillis(), timeout_ms) else 0;
    while (true) {
        if (kill_flag) |flag| {
            if (flag.load(.acquire)) return .{ .reason = .other, .fd = 0, .peer = SocketEndpoint.none };
        }
        var quantum: i32 = poll_quantum_ms;
        if (has_deadline) {
            const remaining = deadline_ms - monotonicMillis();
            if (remaining <= 0) return .{ .reason = .timed_out, .fd = 0, .peer = SocketEndpoint.none };
            if (remaining < quantum) quantum = @intCast(remaining);
        }
        switch (waitReadable(listen_handle, quantum)) {
            .timeout => continue, // re-check deadline + kill
            .failed => return .{ .reason = .other, .fd = 0, .peer = SocketEndpoint.none },
            .ready => {},
        }
        var peer_storage: std.posix.sockaddr.storage = std.mem.zeroes(std.posix.sockaddr.storage);
        var peer_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.storage);
        const accept_rc = std.posix.system.accept(listen_handle, @ptrCast(&peer_storage), &peer_len);
        switch (std.posix.errno(accept_rc)) {
            .SUCCESS => {},
            // No connection ready after a spurious readable wake, or interrupted
            // — re-poll (the kill/quantum are re-checked at the loop top).
            .AGAIN, .INTR => continue,
            else => |accept_errno| return .{ .reason = mapAcceptErrno(accept_errno), .fd = 0, .peer = SocketEndpoint.none },
        }
        const accepted_handle: net.Socket.Handle = @intCast(accept_rc);
        if (comptime builtin.is_test) {
            if (test_after_accept_hook) |hook| hook();
        }
        // A kill that landed WHILE we were blocked accepting: close the
        // just-accepted fd HERE rather than hand a live connection to a process
        // that is tearing down (HIGH-1).
        if (kill_flag) |flag| {
            if (flag.load(.acquire)) {
                _ = std.posix.system.close(accepted_handle);
                return .{ .reason = .other, .fd = 0, .peer = SocketEndpoint.none };
            }
        }
        if (!setNonBlocking(accepted_handle)) {
            _ = std.posix.system.close(accepted_handle);
            return .{ .reason = .other, .fd = 0, .peer = SocketEndpoint.none };
        }
        return .{ .reason = .ok, .fd = fdToBits(accepted_handle), .peer = decodeSockaddr(&peer_storage, peer_len) };
    }
}

/// Map an `accept(2)` errno to a stable `Reason` — the raw-syscall twin of
/// `mapAcceptError` (which maps the portable `AcceptError`).
fn mapAcceptErrno(err: std.posix.E) Reason {
    return switch (err) {
        .MFILE, .NFILE => .fd_quota_exceeded,
        .CONNABORTED => .connection_reset,
        .INVAL => .connection_reset,
        .NOBUFS, .NOMEM => .out_of_memory,
        .PERM => .access_denied,
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

test "socket_io: Reason integer values are the pinned ABI contract mirrored by lib/socket/error.zap reason_from_code" {
    // The `@intFromEnum(Reason.*)` values are a STABLE, gate-crossing ABI
    // contract: `runtime.zig` forwards them across the C-ABI UNCHANGED, and the
    // Zap-level `SocketError.reason_from_code` (lib/socket/error.zap) decodes
    // each integer back to its matchable reason atom POSITIONALLY. No source of
    // truth spans both languages, so renumbering a variant would silently remap
    // every Zap reason. This test PINS each value; a renumber breaks the build
    // HERE, forcing the Zap table to be updated in lockstep. Any change below
    // MUST be mirrored in `SocketError.reason_from_code` and vice versa.
    try testing.expectEqual(@as(i32, 0), @intFromEnum(Reason.ok));
    try testing.expectEqual(@as(i32, 1), @intFromEnum(Reason.connection_refused));
    try testing.expectEqual(@as(i32, 2), @intFromEnum(Reason.timed_out));
    try testing.expectEqual(@as(i32, 3), @intFromEnum(Reason.host_unreachable));
    try testing.expectEqual(@as(i32, 4), @intFromEnum(Reason.network_unreachable));
    try testing.expectEqual(@as(i32, 5), @intFromEnum(Reason.connection_reset));
    try testing.expectEqual(@as(i32, 6), @intFromEnum(Reason.address_in_use));
    try testing.expectEqual(@as(i32, 7), @intFromEnum(Reason.address_unavailable));
    try testing.expectEqual(@as(i32, 8), @intFromEnum(Reason.fd_quota_exceeded));
    try testing.expectEqual(@as(i32, 9), @intFromEnum(Reason.access_denied));
    try testing.expectEqual(@as(i32, 10), @intFromEnum(Reason.network_down));
    try testing.expectEqual(@as(i32, 11), @intFromEnum(Reason.out_of_memory));
    try testing.expectEqual(@as(i32, 12), @intFromEnum(Reason.unknown_host));
    try testing.expectEqual(@as(i32, 13), @intFromEnum(Reason.invalid_argument));
    try testing.expectEqual(@as(i32, 99), @intFromEnum(Reason.other));
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
    try testing.expectEqual(SocketEndpoint.Family.unavailable, outcome.peer.family);
    // The kill flag was in fact observed as set (the hook ran).
    try testing.expect(kill_flag.load(.acquire));
    // The server-side fd `netAccept` opened was closed by the branch — no leak.
    try testing.expectEqual(before, after);
}

test "socket_io: bounded accept with NO incoming connection TIMES OUT promptly, leaking no fd" {
    if (builtin.os.tag == .wasi or builtin.os.tag == .windows) return error.SkipZigTest;

    // A listener with nothing connecting: an INFINITE accept would park forever
    // (only a kill wakes it — the trapping-acceptor problem Job 2 fixes). A
    // BOUNDED accept must return `.timed_out` at ~`timeout_ms`, and because it
    // timed out BEFORE accepting, it produced NO fd — the OS fd count is flat.
    const listener = listenIp4(.{ 127, 0, 0, 1 }, 0, 8);
    try testing.expectEqual(Reason.ok, listener.reason);
    defer closeFd(listener.fd);

    const before = countOpenFds();
    const before_ms = monotonicMillis();
    const outcome = acceptTimeout(listener.fd, null, 150);
    const elapsed_ms = monotonicMillis() - before_ms;
    const after = countOpenFds();

    // It timed out (never hung) with the dedicated reason and a zero fd.
    try testing.expectEqual(Reason.timed_out, outcome.reason);
    try testing.expectEqual(@as(Fd, 0), outcome.fd);
    try testing.expectEqual(SocketEndpoint.Family.unavailable, outcome.peer.family);
    // Bounded by the ~150ms deadline, never ~forever.
    try testing.expect(elapsed_ms < 4000);
    // No fd was ever accepted, so nothing leaked.
    try testing.expectEqual(before, after);
}

test "socket_io: bounded accept still returns a PENDING connection well before its deadline" {
    if (builtin.os.tag == .wasi or builtin.os.tag == .windows) return error.SkipZigTest;

    // A generous timeout must NOT change the happy path: a connection already in
    // the backlog is accepted immediately (peer surfaced), long before the
    // deadline — bounded accept degrades to ordinary accept when work is ready.
    const listener = listenIp4(.{ 127, 0, 0, 1 }, 0, 8);
    try testing.expectEqual(Reason.ok, listener.reason);
    defer closeFd(listener.fd);
    const client = connectIp4(.{ 127, 0, 0, 1 }, listener.bound_port, 5000, null);
    try testing.expectEqual(Reason.ok, client.reason);
    defer closeFd(client.fd);

    const before_ms = monotonicMillis();
    const outcome = acceptTimeout(listener.fd, null, 5000);
    const elapsed_ms = monotonicMillis() - before_ms;

    try testing.expectEqual(Reason.ok, outcome.reason);
    try testing.expect(outcome.fd != 0);
    try testing.expectEqual(SocketEndpoint.Family.ip4, outcome.peer.family);
    // Accepted promptly — nowhere near the 5000ms deadline.
    try testing.expect(elapsed_ms < 1000);
    closeFd(outcome.fd);
}

test "socket_io: a kill mid-bounded-accept reclaims — never orphans a just-accepted fd (OS fd count stable)" {
    if (builtin.os.tag == .wasi or builtin.os.tag == .windows) return error.SkipZigTest;

    // The bounded-accept twin of the kill-racing reclamation test: a background
    // thread flips the kill shortly after `acceptTimeout` begins, racing a queued
    // connection's arrival. On some iterations the kill wins at the top of the
    // loop, on some AFTER `netAccept` (the post-accept close-on-kill path), on
    // some the accept wins outright. The non-zero timeout exercises the SAME
    // HIGH-1 discipline as the infinite path — no path may orphan a fd, proven by
    // the OS fd count returning to baseline after every cycle.
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
        // A generous deadline so the KILL — not the timeout — is what ends the
        // wait on the no-connection iterations (isolating the reclamation path).
        const outcome = acceptTimeout(listener.fd, &kill_flag, 5000);
        setter.join();

        if (outcome.reason == .ok) closeFd(outcome.fd);
        closeFd(client.fd);
        closeFd(listener.fd);
    }

    // Across 64 kill-racing bounded-accept cycles the OS fd count is UNCHANGED.
    try testing.expectEqual(baseline, countOpenFds());
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
    try testing.expectEqual(SocketEndpoint.Family.ip4, accepted.peer.family);
    try testing.expectEqual(@as(u8, 127), accepted.peer.v4[0]);

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

test "socket_io: always-non-blocking recv round-trips a long stream of framed messages byte-exact (common-case, first-poll data)" {
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

    // 500 distinct 8-byte frames sent client→server; the server `recv_exact`s
    // each frame IN ORDER. On the always-non-blocking accepted fd the read after
    // a readable poll returns the bytes on the FIRST try (the common case — no
    // EAGAIN, so the re-poll arm adds ZERO latency here); a healthy fast peer's
    // whole stream round-trips byte-exact. This is the regression guard that the
    // always-non-blocking discipline did not change ordinary recv correctness.
    const frame_count: usize = 500;
    var seq: usize = 0;
    while (seq < frame_count) : (seq += 1) {
        var frame: [8]u8 = undefined;
        std.mem.writeInt(u64, &frame, @as(u64, seq), .little);
        try testing.expectEqual(Reason.ok, send(client.fd, frame[0..], 5000, null).reason);
        const r = try recv(testing.allocator, accepted.fd, 8, 0, 5000, null);
        defer testing.allocator.free(r.buffer);
        try testing.expectEqual(@as(i32, recv_status_chunk), r.status);
        try testing.expectEqual(@as(usize, 8), r.bytes_filled);
        try testing.expectEqualSlices(u8, frame[0..], r.buffer[0..r.bytes_filled]);
    }
}

test "socket_io: always-non-blocking recv re-polls on a competing-reader EAGAIN — no false EOF/error, every byte accounted" {
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

    // TWO reader threads poll+recv the SAME accepted fd. When a byte arrives,
    // level-triggered POLLIN wakes BOTH; one reader's recv gets the byte, the
    // other's recv returns EAGAIN because the byte was already consumed. On the
    // always-non-blocking fd that EAGAIN MUST re-poll — NEVER a false EOF
    // (`recv_status_closed`) and NEVER a mapped error (a positive status). If the
    // EAGAIN arm were missing, the losing reader would mis-map `EAGAIN` to a
    // `.other` error and short-circuit the stream. The invariant proven here:
    // across both readers EXACTLY the sent bytes are accounted, and each reader
    // terminates ONLY on the real EOF after `shutdown(write)`. Each reader uses
    // the thread-safe page allocator (never the shared testing allocator).
    const total_bytes: usize = 300;
    const Reader = struct {
        fd: Fd,
        received: usize = 0,
        saw_bad_status: bool = false,
        fn run(self: *@This()) void {
            while (true) {
                const r = recv(std.heap.page_allocator, self.fd, 0, 256, 5000, null) catch {
                    self.saw_bad_status = true; // OOM only — never expected here
                    return;
                };
                defer std.heap.page_allocator.free(r.buffer);
                if (r.status == recv_status_chunk) {
                    self.received += r.bytes_filled;
                    continue;
                }
                if (r.status == recv_status_closed) return; // the real EOF
                // A positive status is a mapped error — a missing EAGAIN re-poll
                // arm (EAGAIN → `.other`) would land here. It must not.
                self.saw_bad_status = true;
                return;
            }
        }
    };
    var reader_a = Reader{ .fd = accepted.fd };
    var reader_b = Reader{ .fd = accepted.fd };
    const thread_a = try std.Thread.spawn(.{}, Reader.run, .{&reader_a});
    const thread_b = try std.Thread.spawn(.{}, Reader.run, .{&reader_b});

    // Dribble single bytes with tiny gaps so the two readers interleave and the
    // losing reader repeatedly takes the EAGAIN re-poll path, then EOF the stream.
    var n: usize = 0;
    while (n < total_bytes) : (n += 1) {
        const one = [_]u8{@intCast(n & 0xff)};
        try testing.expectEqual(Reason.ok, send(client.fd, one[0..], 5000, null).reason);
        var ts: std.c.timespec = .{ .sec = 0, .nsec = 150_000 }; // 150µs
        _ = std.c.nanosleep(&ts, null);
    }
    try testing.expectEqual(Reason.ok, shutdownFd(client.fd, 1)); // EOF

    thread_a.join();
    thread_b.join();

    // No reader ever saw EAGAIN mis-reported as an error or a premature EOF.
    try testing.expect(!reader_a.saw_bad_status);
    try testing.expect(!reader_b.saw_bad_status);
    // Every sent byte was received EXACTLY once across the two readers — the
    // EAGAIN re-poll neither dropped a byte nor short-circuited the stream.
    try testing.expectEqual(total_bytes, reader_a.received + reader_b.received);
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

test "socket_io: endpoint v6 accessors reconstruct ::1 words + port end-to-end (the Zap decode contract)" {
    if (builtin.os.tag == .wasi or builtin.os.tag == .windows) return error.SkipZigTest;

    const listener = listenIp6ForTest(0) orelse return error.SkipZigTest; // no IPv6 loopback here
    defer closeFd(listener.fd);

    const outcome = connectIp6(loopback_ip6, listener.port, 0, 0, 5000, null);
    try testing.expectEqual(Reason.ok, outcome.reason);
    defer closeFd(outcome.fd);

    // The exact values the Zap `SocketAddress.ip6_from_words` decode receives
    // over the ABI: the four 32-bit big-endian words of ::1 are 0, 0, 0, 1;
    // family is 6; the port is the listener's; the scope id is 0.
    const peer = peerAddress(outcome.fd);
    try testing.expectEqual(@as(i64, 6), endpointFamilyCode(peer));
    try testing.expectEqual(@as(i64, 0), endpointV6Word(peer, 0));
    try testing.expectEqual(@as(i64, 0), endpointV6Word(peer, 1));
    try testing.expectEqual(@as(i64, 0), endpointV6Word(peer, 2));
    try testing.expectEqual(@as(i64, 1), endpointV6Word(peer, 3));
    try testing.expectEqual(@as(i64, listener.port), endpointPortValue(peer));
    try testing.expectEqual(@as(i64, 0), endpointScopeValue(peer));
}

test "socket_io: endpoint v6 word extractor packs an arbitrary address in network order; -1 for non-v6" {
    // A full address 2001:0db8:85a3:0000:0000:8a2e:0370:7334 (no zero-run edge
    // cases) — proves the 32-bit-word byte order the Zap hextet decode assumes.
    const full = SocketEndpoint{
        .family = .ip6,
        .v4 = .{ 0, 0, 0, 0 },
        .v6 = .{ 0x20, 0x01, 0x0d, 0xb8, 0x85, 0xa3, 0x00, 0x00, 0x00, 0x00, 0x8a, 0x2e, 0x03, 0x70, 0x73, 0x34 },
        .port = 443,
        .scope_id = 7,
    };
    try testing.expectEqual(@as(i64, 6), endpointFamilyCode(full));
    // word = b0*2^24 + b1*2^16 + b2*2^8 + b3.
    try testing.expectEqual(@as(i64, 0x2001_0db8), endpointV6Word(full, 0));
    try testing.expectEqual(@as(i64, 0x85a3_0000), endpointV6Word(full, 1));
    try testing.expectEqual(@as(i64, 0x0000_8a2e), endpointV6Word(full, 2));
    try testing.expectEqual(@as(i64, 0x0370_7334), endpointV6Word(full, 3));
    try testing.expectEqual(@as(i64, 443), endpointPortValue(full));
    try testing.expectEqual(@as(i64, 7), endpointScopeValue(full));

    // The high-bit-set word 0x85a3_0000 stays a non-negative i64 (no bitcast to
    // negative) — the whole reason the address is split into 32-bit words.
    try testing.expect(endpointV6Word(full, 1) >= 0);

    // A v4 or unavailable endpoint yields the -1 non-v6 sentinel on the word
    // accessor (family/port/scope still answer honestly).
    const v4 = SocketEndpoint{ .family = .ip4, .v4 = .{ 127, 0, 0, 1 }, .v6 = @splat(0), .port = 8080, .scope_id = 0 };
    try testing.expectEqual(@as(i64, 4), endpointFamilyCode(v4));
    try testing.expectEqual(@as(i64, -1), endpointV6Word(v4, 0));
    try testing.expectEqual(@as(i64, 0), endpointFamilyCode(SocketEndpoint.none));
    try testing.expectEqual(@as(i64, -1), endpointV6Word(SocketEndpoint.none, 0));
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

// ---------------------------------------------------------------------------
// Socket-option tests (setsockopt/getsockopt read-back) — the DETERMINISTIC
// proof that each option's (level, optname, value-encoding) actually reaches
// the kernel. A wrong optname would silently no-op or error, so a read-back of
// the value we set is the primary R3 (TCP_NODELAY) proof. Loopback-only.
// ---------------------------------------------------------------------------

test "socket_io: setOption(nodelay) actually applies — getsockopt(TCP_NODELAY) reads back 1 (the R3 proof)" {
    if (builtin.os.tag == .wasi or builtin.os.tag == .windows) return error.SkipZigTest;

    const listener = listenIp4(.{ 127, 0, 0, 1 }, 0, 8);
    try testing.expectEqual(Reason.ok, listener.reason);
    defer closeFd(listener.fd);
    const client = connectIp4(.{ 127, 0, 0, 1 }, listener.bound_port, 5000, null);
    try testing.expectEqual(Reason.ok, client.reason);
    defer closeFd(client.fd);

    // Before: a fresh TCP socket has Nagle ON — TCP_NODELAY reads back 0.
    try testing.expectEqual(@as(i64, 0), getOption(client.fd, .nodelay).value);
    // Apply, then read back: the option ACTUALLY took effect (1), not merely
    // "accepted". PRE-fix there was no seam to set it at all.
    try testing.expectEqual(Reason.ok, setOption(client.fd, .nodelay, 1));
    const read_back = getOption(client.fd, .nodelay);
    try testing.expectEqual(Reason.ok, read_back.reason);
    try testing.expectEqual(@as(i64, 1), read_back.value);
    // And it toggles back off deterministically.
    try testing.expectEqual(Reason.ok, setOption(client.fd, .nodelay, 0));
    try testing.expectEqual(@as(i64, 0), getOption(client.fd, .nodelay).value);
}

test "socket_io: setOption(keepalive/reuse_address) read back their applied bool value" {
    if (builtin.os.tag == .wasi or builtin.os.tag == .windows) return error.SkipZigTest;

    const listener = listenIp4(.{ 127, 0, 0, 1 }, 0, 8);
    try testing.expectEqual(Reason.ok, listener.reason);
    defer closeFd(listener.fd);
    const client = connectIp4(.{ 127, 0, 0, 1 }, listener.bound_port, 5000, null);
    try testing.expectEqual(Reason.ok, client.reason);
    defer closeFd(client.fd);

    try testing.expectEqual(Reason.ok, setOption(client.fd, .keepalive, 1));
    try testing.expect(getOption(client.fd, .keepalive).value != 0); // SO_KEEPALIVE on
    try testing.expectEqual(Reason.ok, setOption(client.fd, .reuse_address, 1));
    try testing.expect(getOption(client.fd, .reuse_address).value != 0); // SO_REUSEADDR on
}

test "socket_io: setOption(recv_buffer) grows the OS receive buffer (read back >= requested)" {
    if (builtin.os.tag == .wasi or builtin.os.tag == .windows) return error.SkipZigTest;

    const listener = listenIp4(.{ 127, 0, 0, 1 }, 0, 8);
    try testing.expectEqual(Reason.ok, listener.reason);
    defer closeFd(listener.fd);
    const client = connectIp4(.{ 127, 0, 0, 1 }, listener.bound_port, 5000, null);
    try testing.expectEqual(Reason.ok, client.reason);
    defer closeFd(client.fd);

    // A modest request the OS honors without clamping (Linux stores 2×, so the
    // read-back is >= requested; macOS honors small values). The proof is that
    // the applied value reached the kernel, not the exact byte count.
    const requested: i64 = 16384;
    try testing.expectEqual(Reason.ok, setOption(client.fd, .recv_buffer, requested));
    const read_back = getOption(client.fd, .recv_buffer);
    try testing.expectEqual(Reason.ok, read_back.reason);
    try testing.expect(read_back.value >= requested);
}

test "socket_io: setOption(linger) encodes SO_LINGER from milliseconds and reads back the seconds" {
    if (builtin.os.tag == .wasi or builtin.os.tag == .windows) return error.SkipZigTest;

    const listener = listenIp4(.{ 127, 0, 0, 1 }, 0, 8);
    try testing.expectEqual(Reason.ok, listener.reason);
    defer closeFd(listener.fd);
    const client = connectIp4(.{ 127, 0, 0, 1 }, listener.bound_port, 5000, null);
    try testing.expectEqual(Reason.ok, client.reason);
    defer closeFd(client.fd);

    // Off by default (no SO_LINGER override): read-back is -1.
    try testing.expectEqual(@as(i64, -1), getOption(client.fd, .linger).value);
    // 0 ms → linger ON, 0 s timeout (the RST-close affordance).
    try testing.expectEqual(Reason.ok, setOption(client.fd, .linger, 0));
    try testing.expectEqual(@as(i64, 0), getOption(client.fd, .linger).value);
    // 1500 ms → rounds UP to 2 s (l_linger is second-granular) → reads back 2000.
    try testing.expectEqual(Reason.ok, setOption(client.fd, .linger, 1500));
    try testing.expectEqual(@as(i64, 2000), getOption(client.fd, .linger).value);
}

test "socket_io: listenIp4WithOptions sets SO_REUSEPORT before bind — read back on the listener fd" {
    if (builtin.os.tag == .wasi or builtin.os.tag == .windows) return error.SkipZigTest;

    // A listener created WITH reuse_port has SO_REUSEPORT set on its fd (applied
    // pre-bind); reuse_address is on too. Read-back is deterministic (unlike a
    // timing-based bind-after-close race).
    const with_reuse = listenIp4WithOptions(.{ 127, 0, 0, 1 }, 0, 8, true, true);
    try testing.expectEqual(Reason.ok, with_reuse.reason);
    defer closeFd(with_reuse.fd);
    try testing.expect(getOption(with_reuse.fd, .reuse_port).value != 0);
    try testing.expect(getOption(with_reuse.fd, .reuse_address).value != 0);

    // A default listener (reuse_port OFF) does NOT have SO_REUSEPORT set.
    const without = listenIp4WithOptions(.{ 127, 0, 0, 1 }, 0, 8, true, false);
    try testing.expectEqual(Reason.ok, without.reason);
    defer closeFd(without.fd);
    try testing.expectEqual(@as(i64, 0), getOption(without.fd, .reuse_port).value);
    try testing.expect(getOption(without.fd, .reuse_address).value != 0); // still on
}

test "socket_io: two listeners bind the SAME port in succession with reuse_port (would EADDRINUSE without)" {
    if (builtin.os.tag == .wasi or builtin.os.tag == .windows) return error.SkipZigTest;

    // First listener on an ephemeral port WITH reuse_port; a second listener on
    // that SAME port also with reuse_port succeeds — SO_REUSEPORT permits the
    // concurrent bind. Both stay open simultaneously (the load-balancing use).
    const first = listenIp4WithOptions(.{ 127, 0, 0, 1 }, 0, 8, true, true);
    try testing.expectEqual(Reason.ok, first.reason);
    defer closeFd(first.fd);
    const shared_port = first.bound_port;

    const second = listenIp4WithOptions(.{ 127, 0, 0, 1 }, shared_port, 8, true, true);
    // macOS additionally requires matching UIDs (always true here); on both
    // Linux and macOS a second reuse_port bind to the same port succeeds.
    try testing.expectEqual(Reason.ok, second.reason);
    defer closeFd(second.fd);
    try testing.expectEqual(shared_port, second.bound_port);
}

// ---------------------------------------------------------------------------
// Phase S2 — Datagram (UDP) + Unix-domain seam tests
// ---------------------------------------------------------------------------

test "socket_io: UDP loopback roundtrip — bindUdp + sendToIp4 + recvFrom, binary-safe, peer surfaced" {
    if (builtin.os.tag == .wasi or builtin.os.tag == .windows) return error.SkipZigTest;

    // Two bound UDP sockets on loopback: `receiver` (an ephemeral port) and
    // `sender`. A datagram sent to the receiver arrives whole, and recvFrom
    // reports the SENDER's endpoint as the peer.
    const receiver = bindUdp(.{ 127, 0, 0, 1 }, 0);
    try testing.expectEqual(Reason.ok, receiver.reason);
    try testing.expect(receiver.bound_port != 0);
    defer closeFd(receiver.fd);

    const sender = bindUdp(.{ 127, 0, 0, 1 }, 0);
    try testing.expectEqual(Reason.ok, sender.reason);
    try testing.expect(sender.bound_port != 0);
    defer closeFd(sender.fd);

    // Binary-safe payload: embedded NUL + a non-UTF-8 byte.
    const payload = [_]u8{ 'd', 'g', 0, 0xFE, 'm' };
    const sent = sendToIp4(sender.fd, .{ 127, 0, 0, 1 }, receiver.bound_port, payload[0..], 5000, null);
    try testing.expectEqual(Reason.ok, sent.reason);
    try testing.expectEqual(payload.len, sent.bytes_sent);

    const got = try recvFrom(testing.allocator, receiver.fd, max_datagram_bytes, 5000, null);
    defer testing.allocator.free(got.buffer);
    try testing.expectEqual(@as(i32, recv_status_chunk), got.status);
    try testing.expect(!got.truncated);
    try testing.expectEqual(payload.len, got.bytes_filled);
    try testing.expectEqual(payload.len, got.datagram_len);
    try testing.expectEqualSlices(u8, payload[0..], got.buffer[0..got.bytes_filled]);
    // The peer is the sender's loopback endpoint.
    try testing.expectEqual(SocketEndpoint.Family.ip4, got.peer.family);
    try testing.expectEqual(@as(u8, 127), got.peer.v4[0]);
    try testing.expectEqual(sender.bound_port, got.peer.port);
}

test "socket_io: UDP truncation is DETECTED (never silent) — a big datagram into a small buffer sets truncated" {
    if (builtin.os.tag == .wasi or builtin.os.tag == .windows) return error.SkipZigTest;

    const receiver = bindUdp(.{ 127, 0, 0, 1 }, 0);
    try testing.expectEqual(Reason.ok, receiver.reason);
    defer closeFd(receiver.fd);
    const sender = bindUdp(.{ 127, 0, 0, 1 }, 0);
    try testing.expectEqual(Reason.ok, sender.reason);
    defer closeFd(sender.fd);

    // Send a 100-byte datagram; receive with a 10-byte cap. The excess MUST be
    // reported as truncated (never silently dropped), and only 10 bytes captured.
    var payload: [100]u8 = undefined;
    for (&payload, 0..) |*byte, i| byte.* = @intCast(i % 251);
    const sent = sendToIp4(sender.fd, .{ 127, 0, 0, 1 }, receiver.bound_port, payload[0..], 5000, null);
    try testing.expectEqual(Reason.ok, sent.reason);

    const got = try recvFrom(testing.allocator, receiver.fd, 10, 5000, null);
    defer testing.allocator.free(got.buffer);
    try testing.expectEqual(@as(i32, recv_status_chunk), got.status);
    try testing.expect(got.truncated); // the distinct truncation channel fired
    try testing.expectEqual(@as(usize, 10), got.bytes_filled); // captured the prefix
    // The captured 10 bytes are the datagram's PREFIX (binary-exact).
    try testing.expectEqualSlices(u8, payload[0..10], got.buffer[0..10]);
    // On Linux the true datagram length is exact (MSG_TRUNC recv flag); on
    // macOS it is the captured floor. Either way >= the captured length.
    try testing.expect(got.datagram_len >= 10);
    if (builtin.os.tag == .linux) try testing.expectEqual(@as(usize, 100), got.datagram_len);
}

test "socket_io: connected UDP — connectUdpIp4 filters datagrams to the connected peer" {
    if (builtin.os.tag == .wasi or builtin.os.tag == .windows) return error.SkipZigTest;

    // A "server" UDP socket and two senders. The server connects to sender A;
    // a connected UDP socket only delivers datagrams from its connected peer,
    // so B's datagram is filtered out by the kernel and A's is received.
    const server = bindUdp(.{ 127, 0, 0, 1 }, 0);
    try testing.expectEqual(Reason.ok, server.reason);
    defer closeFd(server.fd);
    const sender_a = bindUdp(.{ 127, 0, 0, 1 }, 0);
    try testing.expectEqual(Reason.ok, sender_a.reason);
    defer closeFd(sender_a.fd);

    // Connect the server back to A, then A can `send` (not sendto) and the
    // server receives ONLY from A.
    const connected = connectUdpIp4(.{ 127, 0, 0, 1 }, sender_a.bound_port);
    try testing.expectEqual(Reason.ok, connected.reason);
    defer closeFd(connected.fd);

    // The server's connected socket is bound to some ephemeral port; A must send
    // to THAT port. Discover it via getsockname.
    const server2_local = localAddress(connected.fd);
    try testing.expectEqual(SocketEndpoint.Family.ip4, server2_local.family);

    // A sends to the connected server socket; it arrives.
    const from_a = sendToIp4(sender_a.fd, .{ 127, 0, 0, 1 }, server2_local.port, "from-A", 5000, null);
    try testing.expectEqual(Reason.ok, from_a.reason);

    const got = try recvFrom(testing.allocator, connected.fd, max_datagram_bytes, 5000, null);
    defer testing.allocator.free(got.buffer);
    try testing.expectEqual(@as(i32, recv_status_chunk), got.status);
    try testing.expectEqualSlices(u8, "from-A", got.buffer[0..got.bytes_filled]);
    try testing.expectEqual(sender_a.bound_port, got.peer.port);
}

test "socket_io: buildUnixSockAddr rejects an over-long path and (non-Linux) an abstract path" {
    // A path longer than the portable cap is rejected on EVERY OS (never
    // silently truncated into `sun_path`).
    var too_long: [max_unix_path + 5]u8 = undefined;
    @memset(too_long[0..], 'a');
    try testing.expectEqual(Reason.invalid_argument, buildUnixSockAddr(too_long[0..]).reason);

    // A valid short filesystem path is accepted.
    try testing.expectEqual(Reason.ok, buildUnixSockAddr("/tmp/zap-unix-ok.sock").reason);

    // The abstract namespace (`@`-prefixed) is Linux-only; on any other OS it
    // is invalid_argument (no silent reinterpretation of the leading `@`).
    if (builtin.os.tag != .linux) {
        try testing.expectEqual(Reason.invalid_argument, buildUnixSockAddr("@zap-abstract").reason);
    } else {
        try testing.expectEqual(Reason.ok, buildUnixSockAddr("@zap-abstract").reason);
        // Even on Linux, an abstract name past the full field width is rejected.
        var abstract_too_long: [max_unix_path + 2]u8 = undefined;
        @memset(abstract_too_long[0..], 'a');
        abstract_too_long[0] = '@';
        try testing.expectEqual(Reason.invalid_argument, buildUnixSockAddr(abstract_too_long[0..]).reason);
    }
    // An empty path is not a valid filesystem address.
    try testing.expectEqual(Reason.invalid_argument, buildUnixSockAddr("").reason);
}

test "socket_io: Unix-domain STREAM echo — listenUnix + connectUnix + acceptAny, binary-safe" {
    if (builtin.os.tag == .wasi or builtin.os.tag == .windows) return error.SkipZigTest;

    var path_buffer: [max_unix_path]u8 = undefined;
    const path = try uniqueUnixPath(path_buffer[0..], "stream");
    defer _ = std.posix.system.unlink(path.ptr);

    const listener = listenUnix(path, 8);
    try testing.expectEqual(Reason.ok, listener.reason);
    defer closeFd(listener.fd);

    const client = connectUnix(path, 5000, null);
    try testing.expectEqual(Reason.ok, client.reason);
    defer closeFd(client.fd);

    const accepted = accept(listener.fd, null);
    try testing.expectEqual(Reason.ok, accepted.reason);
    defer closeFd(accepted.fd);
    // The accepted peer is a Unix endpoint (family marker; path not surfaced).
    try testing.expectEqual(SocketEndpoint.Family.unix, accepted.peer.family);

    const payload = [_]u8{ 'u', 'x', 0, 0xFF, 'z' };
    const sent = send(client.fd, payload[0..], 5000, null);
    try testing.expectEqual(Reason.ok, sent.reason);
    const received = try recv(testing.allocator, accepted.fd, payload.len, 0, 5000, null);
    defer testing.allocator.free(received.buffer);
    try testing.expectEqual(@as(i32, recv_status_chunk), received.status);
    try testing.expectEqualSlices(u8, payload[0..], received.buffer[0..received.bytes_filled]);

    // Echo back the other way (full duplex over the Unix stream).
    const reply = send(accepted.fd, "ok", 5000, null);
    try testing.expectEqual(Reason.ok, reply.reason);
    const echoed = try recv(testing.allocator, client.fd, 0, 64, 5000, null);
    defer testing.allocator.free(echoed.buffer);
    try testing.expectEqualSlices(u8, "ok", echoed.buffer[0..echoed.bytes_filled]);
}

test "socket_io: Unix-domain DATAGRAM roundtrip — bindUnixDatagram + sendToUnix + recvFrom" {
    if (builtin.os.tag == .wasi or builtin.os.tag == .windows) return error.SkipZigTest;

    var receiver_path_buffer: [max_unix_path]u8 = undefined;
    const receiver_path = try uniqueUnixPath(receiver_path_buffer[0..], "dgram-rx");
    defer _ = std.posix.system.unlink(receiver_path.ptr);
    var sender_path_buffer: [max_unix_path]u8 = undefined;
    const sender_path = try uniqueUnixPath(sender_path_buffer[0..], "dgram-tx");
    defer _ = std.posix.system.unlink(sender_path.ptr);

    const receiver = bindUnixDatagram(receiver_path);
    try testing.expectEqual(Reason.ok, receiver.reason);
    defer closeFd(receiver.fd);
    // The sender is bound too (so it has an address; not strictly required, but
    // exercises the bind path both ways).
    const sender = bindUnixDatagram(sender_path);
    try testing.expectEqual(Reason.ok, sender.reason);
    defer closeFd(sender.fd);

    const payload = [_]u8{ 'u', 'd', 0, 0x01, 'g' };
    const sent = sendToUnix(sender.fd, receiver_path, payload[0..], 5000, null);
    try testing.expectEqual(Reason.ok, sent.reason);
    try testing.expectEqual(payload.len, sent.bytes_sent);

    const got = try recvFrom(testing.allocator, receiver.fd, max_datagram_bytes, 5000, null);
    defer testing.allocator.free(got.buffer);
    try testing.expectEqual(@as(i32, recv_status_chunk), got.status);
    try testing.expect(!got.truncated);
    try testing.expectEqualSlices(u8, payload[0..], got.buffer[0..got.bytes_filled]);
    // A bound Unix datagram sender surfaces as the `.unix` family marker.
    try testing.expectEqual(SocketEndpoint.Family.unix, got.peer.family);
}

// -- Phase S2 follow-up (a): IPv6 UDP dialing at the datagram seam -----------

test "socket_io: v6BytesFromHextets packs hextets big-endian (::1 and 2001:db8::1)" {
    // `::1` = h0..h6 = 0, h7 = 1 → the {0,…,0,1} loopback bytes.
    try testing.expectEqualSlices(u8, loopback_ip6[0..], v6BytesFromHextets(.{ 0, 0, 0, 0, 0, 0, 0, 1 })[0..]);
    // `2001:db8::1` → 0x2001 0x0db8 … 0x0001, most-significant byte first.
    const db8 = v6BytesFromHextets(.{ 0x2001, 0x0db8, 0, 0, 0, 0, 0, 1 });
    try testing.expectEqualSlices(u8, &[16]u8{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, db8[0..]);
    // Round-trips through the readback packer: the four v6 words reconstruct it.
    const endpoint = SocketEndpoint{ .family = .ip6, .v4 = .{ 0, 0, 0, 0 }, .v6 = db8, .port = 443, .scope_id = 0 };
    try testing.expectEqual(@as(i64, 0x2001_0db8), endpointV6Word(endpoint, 0));
    try testing.expectEqual(@as(i64, 1), endpointV6Word(endpoint, 3));
}

test "socket_io: IPv6 UDP loopback roundtrip — bindUdp6 + sendToIp6 + recvFrom surfaces a :ip6 peer" {
    if (builtin.os.tag == .wasi or builtin.os.tag == .windows) return error.SkipZigTest;

    // Two bound v6 UDP sockets on ::1. A create/bind failure means the host has
    // no usable IPv6 loopback (e.g. IPv6-disabled CI) — the test then skips.
    const receiver = bindUdp6(loopback_ip6, 0, 0, 0);
    if (receiver.reason != .ok) return error.SkipZigTest;
    try testing.expect(receiver.bound_port != 0);
    defer closeFd(receiver.fd);

    const sender = bindUdp6(loopback_ip6, 0, 0, 0);
    try testing.expectEqual(Reason.ok, sender.reason);
    try testing.expect(sender.bound_port != 0);
    defer closeFd(sender.fd);

    // Binary-safe payload: embedded NUL + a non-UTF-8 byte.
    const payload = [_]u8{ 'v', '6', 0, 0xFE, 'd' };
    const sent = sendToIp6(sender.fd, loopback_ip6, receiver.bound_port, 0, 0, payload[0..], 5000, null);
    try testing.expectEqual(Reason.ok, sent.reason);
    try testing.expectEqual(payload.len, sent.bytes_sent);

    const got = try recvFrom(testing.allocator, receiver.fd, max_datagram_bytes, 5000, null);
    defer testing.allocator.free(got.buffer);
    try testing.expectEqual(@as(i32, recv_status_chunk), got.status);
    try testing.expect(!got.truncated);
    try testing.expectEqualSlices(u8, payload[0..], got.buffer[0..got.bytes_filled]);
    // The sender is surfaced as a REAL v6 peer — the ::1 bytes and the sender
    // port, NOT `.unavailable`. This is the recv v6-peer surfacing (the four-word
    // ABI readback path the datagram Zap layer reconstructs into a `:ip6`).
    try testing.expectEqual(SocketEndpoint.Family.ip6, got.peer.family);
    try testing.expectEqualSlices(u8, loopback_ip6[0..], got.peer.v6[0..]);
    try testing.expectEqual(sender.bound_port, got.peer.port);
    try testing.expectEqual(@as(i64, 0), endpointV6Word(got.peer, 0));
    try testing.expectEqual(@as(i64, 1), endpointV6Word(got.peer, 3));
}

test "socket_io: connected IPv6 UDP — connectUdpIp6 filters datagrams to the connected v6 peer" {
    if (builtin.os.tag == .wasi or builtin.os.tag == .windows) return error.SkipZigTest;

    const sender = bindUdp6(loopback_ip6, 0, 0, 0);
    if (sender.reason != .ok) return error.SkipZigTest; // no IPv6 loopback here
    defer closeFd(sender.fd);

    // Connect a v6 UDP socket back to `sender` (immediate — no handshake). Its
    // ephemeral source port is discoverable via getsockname.
    const connected = connectUdpIp6(loopback_ip6, sender.bound_port, 0, 0);
    try testing.expectEqual(Reason.ok, connected.reason);
    defer closeFd(connected.fd);
    const connected_local = localAddress(connected.fd);
    try testing.expectEqual(SocketEndpoint.Family.ip6, connected_local.family);

    const sent = sendToIp6(sender.fd, loopback_ip6, connected_local.port, 0, 0, "v6-peer", 5000, null);
    try testing.expectEqual(Reason.ok, sent.reason);
    const got = try recvFrom(testing.allocator, connected.fd, max_datagram_bytes, 5000, null);
    defer testing.allocator.free(got.buffer);
    try testing.expectEqualSlices(u8, "v6-peer", got.buffer[0..got.bytes_filled]);
    try testing.expectEqual(SocketEndpoint.Family.ip6, got.peer.family);
    try testing.expectEqual(sender.bound_port, got.peer.port);
}

// -- Phase S2 follow-up (b): Unix peer/local PATH readback ------------------

test "socket_io: Unix DATAGRAM recvFrom surfaces the BOUND sender's PATH (reply-to-sender)" {
    if (builtin.os.tag == .wasi or builtin.os.tag == .windows) return error.SkipZigTest;

    var receiver_path_buffer: [max_unix_path]u8 = undefined;
    const receiver_path = try uniqueUnixPath(receiver_path_buffer[0..], "dgpath-rx");
    defer _ = std.posix.system.unlink(receiver_path.ptr);
    var sender_path_buffer: [max_unix_path]u8 = undefined;
    const sender_path = try uniqueUnixPath(sender_path_buffer[0..], "dgpath-tx");
    defer _ = std.posix.system.unlink(sender_path.ptr);

    const receiver = bindUnixDatagram(receiver_path);
    try testing.expectEqual(Reason.ok, receiver.reason);
    defer closeFd(receiver.fd);
    const sender = bindUnixDatagram(sender_path);
    try testing.expectEqual(Reason.ok, sender.reason);
    defer closeFd(sender.fd);

    const sent = sendToUnix(sender.fd, receiver_path, "reply-me", 5000, null);
    try testing.expectEqual(Reason.ok, sent.reason);
    const got = try recvFrom(testing.allocator, receiver.fd, max_datagram_bytes, 5000, null);
    defer testing.allocator.free(got.buffer);
    try testing.expectEqualSlices(u8, "reply-me", got.buffer[0..got.bytes_filled]);
    // The peer is the SENDER's Unix path — NOT `:unavailable`. A server can now
    // reply straight back to this path.
    try testing.expectEqual(SocketEndpoint.Family.unix, got.peer.family);
    try testing.expectEqualSlices(u8, sender_path, endpointUnixPath(&got.peer));

    // Reply-to-sender: the receiver sends BACK to the surfaced path and the
    // original sender receives it (round-trip closed on the readback path).
    const reply = sendToUnix(receiver.fd, endpointUnixPath(&got.peer), "pong", 5000, null);
    try testing.expectEqual(Reason.ok, reply.reason);
    const back = try recvFrom(testing.allocator, sender.fd, max_datagram_bytes, 5000, null);
    defer testing.allocator.free(back.buffer);
    try testing.expectEqualSlices(u8, "pong", back.buffer[0..back.bytes_filled]);
    try testing.expectEqualSlices(u8, receiver_path, endpointUnixPath(&back.peer));
}

test "socket_io: Unix DATAGRAM recvFrom from an UNBOUND sender surfaces no path" {
    if (builtin.os.tag == .wasi or builtin.os.tag == .windows) return error.SkipZigTest;

    var receiver_path_buffer: [max_unix_path]u8 = undefined;
    const receiver_path = try uniqueUnixPath(receiver_path_buffer[0..], "dgpath-anon");
    defer _ = std.posix.system.unlink(receiver_path.ptr);

    const receiver = bindUnixDatagram(receiver_path);
    try testing.expectEqual(Reason.ok, receiver.reason);
    defer closeFd(receiver.fd);

    // A sender that NEVER binds has no reply address. On Linux a datagram send
    // may autobind it to an abstract name; on macOS it stays unnamed. Either way
    // the surfaced path is NOT a filesystem path the receiver bound, and an
    // unnamed sender surfaces an empty path (→ `:unavailable` in the Zap layer).
    const sender_rc = std.posix.system.socket(std.posix.AF.UNIX, std.posix.SOCK.DGRAM, 0);
    try testing.expect(std.posix.errno(sender_rc) == .SUCCESS);
    const sender_fd: Fd = @intCast(sender_rc);
    defer closeFd(sender_fd);

    const sent = sendToUnix(sender_fd, receiver_path, "anon", 5000, null);
    try testing.expectEqual(Reason.ok, sent.reason);
    const got = try recvFrom(testing.allocator, receiver.fd, max_datagram_bytes, 5000, null);
    defer testing.allocator.free(got.buffer);
    try testing.expectEqualSlices(u8, "anon", got.buffer[0..got.bytes_filled]);
    // macOS: an unnamed sender → `.unavailable`/empty path. Linux: an abstract
    // autobind name (a `@`-prefixed path) MAY appear, but never the receiver's
    // filesystem path. The invariant that matters: the peer is not a bogus
    // reply target that equals the receiver.
    if (got.peer.family == .unix) {
        try testing.expect(!std.mem.eql(u8, receiver_path, endpointUnixPath(&got.peer)));
    } else {
        try testing.expectEqual(SocketEndpoint.Family.unavailable, got.peer.family);
    }
}

test "socket_io: Unix STREAM local/peer address surface the bound PATH via getsockname/getpeername" {
    if (builtin.os.tag == .wasi or builtin.os.tag == .windows) return error.SkipZigTest;

    var path_buffer: [max_unix_path]u8 = undefined;
    const path = try uniqueUnixPath(path_buffer[0..], "streampath");
    defer _ = std.posix.system.unlink(path.ptr);

    const listener = listenUnix(path, 8);
    try testing.expectEqual(Reason.ok, listener.reason);
    defer closeFd(listener.fd);
    const client = connectUnix(path, 5000, null);
    try testing.expectEqual(Reason.ok, client.reason);
    defer closeFd(client.fd);
    const accepted = acceptAny(listener.fd, null, 0);
    try testing.expectEqual(Reason.ok, accepted.reason);
    defer closeFd(accepted.fd);

    // The listener's LOCAL address is the bound path.
    const listener_local = localAddress(listener.fd);
    try testing.expectEqual(SocketEndpoint.Family.unix, listener_local.family);
    try testing.expectEqualSlices(u8, path, endpointUnixPath(&listener_local));

    // The accepted server socket is bound to the same listen path (getsockname).
    const server_local = localAddress(accepted.fd);
    try testing.expectEqual(SocketEndpoint.Family.unix, server_local.family);
    try testing.expectEqualSlices(u8, path, endpointUnixPath(&server_local));

    // The client's PEER (getpeername) is the server's listen path.
    const client_peer = peerAddress(client.fd);
    try testing.expectEqual(SocketEndpoint.Family.unix, client_peer.family);
    try testing.expectEqualSlices(u8, path, endpointUnixPath(&client_peer));

    // The client itself never bound a path — its LOCAL address is a Unix
    // endpoint with an EMPTY path (→ `:unavailable` in the Zap layer).
    const client_local = localAddress(client.fd);
    if (client_local.family == .unix) {
        try testing.expectEqual(@as(usize, 0), client_local.unix_path_len);
    } else {
        try testing.expectEqual(SocketEndpoint.Family.unavailable, client_local.family);
    }
}

test "socket_io: decodeUnixPath reconstructs a Linux abstract name with the @ prefix" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    // Build an abstract-namespace sockaddr (`@zap-abs`) via the encode side, then
    // decode it back — the reconstructed Zap path re-adds the `@` prefix.
    const built = buildUnixSockAddr("@zap-abs");
    try testing.expectEqual(Reason.ok, built.reason);
    var storage = built.storage;
    var out: [max_unix_path]u8 = undefined;
    const decoded_len = decodeUnixPath(&storage, built.len, &out);
    try testing.expectEqualSlices(u8, "@zap-abs", out[0..decoded_len]);
}

test "socket_io: recvFrom idle-timeout returns timed_out WITHOUT closing the socket" {
    if (builtin.os.tag == .wasi or builtin.os.tag == .windows) return error.SkipZigTest;

    const receiver = bindUdp(.{ 127, 0, 0, 1 }, 0);
    try testing.expectEqual(Reason.ok, receiver.reason);
    defer closeFd(receiver.fd);
    const sender = bindUdp(.{ 127, 0, 0, 1 }, 0);
    try testing.expectEqual(Reason.ok, sender.reason);
    defer closeFd(sender.fd);

    // Nothing sent — recvFrom must TIME OUT (never hang), socket stays usable.
    const timed = try recvFrom(testing.allocator, receiver.fd, max_datagram_bytes, 150, null);
    defer testing.allocator.free(timed.buffer);
    try testing.expectEqual(@as(i32, @intFromEnum(Reason.timed_out)), timed.status);

    // Prove the socket survived: a subsequent datagram is received.
    _ = sendToIp4(sender.fd, .{ 127, 0, 0, 1 }, receiver.bound_port, "later", 5000, null);
    const after = try recvFrom(testing.allocator, receiver.fd, max_datagram_bytes, 5000, null);
    defer testing.allocator.free(after.buffer);
    try testing.expectEqual(@as(i32, recv_status_chunk), after.status);
    try testing.expectEqualSlices(u8, "later", after.buffer[0..after.bytes_filled]);
}

test "socket_io: kill mid-recvFrom reclaims no fd — OS fd count stable across many cycles" {
    if (builtin.os.tag == .wasi or builtin.os.tag == .windows) return error.SkipZigTest;

    // A recvFrom parked on an idle UDP socket is torn down by a kill flag; no
    // fd is orphaned by the kill path (the socket fd itself is closed by the
    // test's `defer`). Proven by the OS fd count returning to baseline.
    const baseline = countOpenFds();
    var iteration: usize = 0;
    while (iteration < 32) : (iteration += 1) {
        const receiver = bindUdp(.{ 127, 0, 0, 1 }, 0);
        try testing.expectEqual(Reason.ok, receiver.reason);

        var kill_flag = std.atomic.Value(bool).init(true); // already pending
        const got = try recvFrom(testing.allocator, receiver.fd, max_datagram_bytes, 5000, &kill_flag);
        testing.allocator.free(got.buffer);
        // A pending kill at the top of the loop returns promptly with no
        // datagram and does not close the socket (the caller owns it).
        try testing.expectEqual(@as(i32, @intFromEnum(Reason.other)), got.status);
        try testing.expectEqual(@as(usize, 0), got.bytes_filled);
        closeFd(receiver.fd);
    }
    try testing.expectEqual(baseline, countOpenFds());
}

/// A run-unique Unix-domain socket path under the system temp dir, written into
/// the caller's `buffer` (so two paths can be live at once — the datagram test
/// needs both endpoints). A monotonic counter plus a millisecond timestamp keep
/// concurrent test runs from colliding. Caller unlinks it.
var unique_unix_path_counter: std.atomic.Value(u32) = .init(0);

fn uniqueUnixPath(buffer: []u8, tag: []const u8) ![:0]const u8 {
    const n = unique_unix_path_counter.fetchAdd(1, .monotonic);
    const written = try std.fmt.bufPrint(buffer, "/tmp/zap-{s}-{d}-{d}.sock", .{ tag, monotonicMillis(), n });
    buffer[written.len] = 0; // NUL-terminate for the raw `unlink`
    return buffer[0..written.len :0];
}

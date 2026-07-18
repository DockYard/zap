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
// TLS (Phase S4). The client record layer and the OS trust store are pure
// `std.crypto` — no relative import, so `socket_io` stays registerable as the
// embedded, staged struct-source module. Referencing these types does NOT
// force `Client.init` codegen (that is instantiated only where it is CALLED —
// the handshake trampoline, Phase S4 Job 3); Job 1 provides only the composable
// pieces: the raw-fd `Reader`/`Writer` adapter, the lazy trust-store singleton,
// and the `InitError` → `Reason` classifier.
const tls = std.crypto.tls;
const Certificate = std.crypto.Certificate;

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
    /// TLS server-certificate verification FAILED (Phase S4): host mismatch,
    /// expired / not-yet-valid, an untrusted issuer, or a bad certificate
    /// signature. A distinct, typed reason so a verification failure is NEVER
    /// silently folded into a generic transport error — the caller can surface
    /// "the peer's certificate is not trusted" precisely. Produced by
    /// `mapTlsInitError` for every `Certificate*` / `TlsCertificateNotVerified`
    /// handshake error.
    tls_cert_invalid = 14,
    /// The TLS handshake failed for a NON-certificate reason (Phase S4): a
    /// fatal alert, an unexpected/mal-formed handshake message, a record-layer
    /// decrypt failure, insufficient entropy, or the underlying transport
    /// read/write failing mid-handshake. Everything `mapTlsInitError` does not
    /// classify as a certificate failure maps here.
    tls_handshake_failed = 15,
    /// A TLS SERVER handshake could not present a usable certificate for the
    /// client's request (Phase S5): the client's SNI names no configured
    /// certificate, or the client advertised no signature scheme the leaf key
    /// can produce. Distinct from `tls_handshake_failed` so a server operator
    /// can tell "no matching certificate for this client" from a generic
    /// protocol failure. Produced by `mapTlsServerInitError` for the fork
    /// server's `TlsHandshakeFailure`.
    tls_no_matching_cert = 16,
    /// A TLS SERVER's certificate/key configuration is itself unusable (Phase
    /// S5) — surfaced at `Tls.listen`/`Tls.upgrade` time, BEFORE any client
    /// connects: an empty/malformed certificate chain, an unparseable or
    /// unsupported private key, or a private key that does not match the leaf
    /// certificate's public key. A distinct, typed reason so a mis-configured
    /// server fails loudly at bind time rather than mysteriously at handshake
    /// time. Produced by `tlsServerConfigCreate` and by the fork server's
    /// `TlsConfigInvalid`.
    tls_config_invalid = 17,
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
// TLS foundation (Phase S4 Job 1) — the composable pieces the TLS-client
// handshake (Job 3) and the Zap `Tls` surface (Job 4) build on. THREE parts:
//
//   1. `SocketStream` — a `std.Io.Reader` + `std.Io.Writer` adapter over the
//      RAW, always-`O_NONBLOCK` fd, so `std.crypto.tls.Client.init` (which is
//      SYNCHRONOUS and drives the handshake inline over caller-supplied
//      Reader/Writer) can run as ONE blocking-offload job. Every fill/drain is
//      poll-quantum bounded and re-checks a SINGLE absolute-monotonic deadline
//      + the owning process's `kill_flag`, so a slowloris handshake times out
//      and stays killable (§8 DoS — the HIGH-2/HIGH-3 discipline).
//   2. `trustStore` — the lazy, process-global OS trust-store singleton
//      (`Certificate.Bundle.rescan`), populated ONCE and shared across
//      concurrent handshakes under an `Io.RwLock`. MANDATORY verification is a
//      Job-3/4 policy; this just supplies the CA bundle.
//   3. `mapTlsInitError` — classify a `Client.InitError` into a stable
//      `Reason`: certificate failures → `tls_cert_invalid`, everything else →
//      `tls_handshake_failed`, so a verification failure is always distinct and
//      typed, never silently generic.
//
// SEAM LEGITIMACY: the raw `recv(2)`/`send(2)`/`poll(2)` here are the SAME
// always-non-blocking syscalls the S1 `recv`/`send` already issue in this file
// (this module IS the socket-syscall seam; the runtime OS-portability gate
// scans only `src/runtime.zig`). The poll-less targets (Windows/wasi — not in
// v1 run scope) degrade to the fork's blocking `netRead`/`netWrite`, the same
// posture the rest of the seam takes.
// ---------------------------------------------------------------------------

/// The mandatory minimum buffer capacity for every TLS I/O buffer:
/// `std.crypto.tls.Client.init` ASSERTS the input reader's buffer is at least
/// this large (one whole ciphertext record + header, `16645` bytes), and the
/// client's `drain`/`flush` demand the same contiguous room from the output
/// writer. Sizing all four TLS buffers (encrypted-in, encrypted-out, and the
/// two plaintext scratch buffers in `tls_session.zig`) to this constant keeps
/// the record layer within its documented bounds.
pub const tls_min_buffer_len: usize = tls.max_ciphertext_record_len;

/// A `std.Io.Reader` + `std.Io.Writer` pair over ONE raw, always-`O_NONBLOCK`
/// socket fd — the transport `std.crypto.tls.Client` reads encrypted records
/// FROM (`inputReader`) and writes encrypted records TO (`outputWriter`). It
/// deliberately does NOT reuse the fork's `net.Stream.Reader`/`Writer`: those
/// call the fork's BLOCKING `netRead`/`netWrite`, which hit `EAGAIN` on the
/// always-non-blocking fd. Instead each fill/drain runs the exact poll-quantum
/// loop the S1 `recv`/`send` use, re-checking a single absolute deadline + the
/// kill flag every quantum.
///
/// LIFETIME: the vtable callbacks recover `*SocketStream` from the embedded
/// interface via `@fieldParentPtr`, so a `SocketStream` MUST live at a stable
/// address for as long as the `Client` (or any reader/writer) holds a pointer
/// into it — the `TlsSession` heap-box (`tls_session.zig`) provides that
/// stability in production; a stack `var` provides it in a unit test.
///
/// DEADLINE: `deadline_ms` is ONE ABSOLUTE monotonic deadline computed at
/// `init` from the caller's relative `timeout_ms`. Because the whole handshake
/// shares this single deadline (rather than each fill/drain restarting a
/// relative timer), a peer that dribbles one byte per quantum still hits the
/// deadline — the slowloris-handshake bound (HIGH-3).
///
/// FAILURE STASH: on a kill/timeout/transport error the vtable returns the
/// std `error.ReadFailed`/`error.WriteFailed` (all `Client.init` propagates),
/// and the classified `Reason` is stashed OUT-OF-BAND in `read_reason`/
/// `write_reason` (the connect-path last-error pattern) so the offload
/// trampoline can recover WHY after the error unwinds.
pub const SocketStream = struct {
    /// The raw socket fd (always `O_NONBLOCK` for its whole life).
    handle: Fd,
    /// The ABSOLUTE monotonic deadline (ms) for the WHOLE session's I/O; `0`
    /// means no deadline (the leaf still wakes each quantum to honour a kill).
    deadline_ms: i64,
    /// The owning process's `pending_kill` atomic (captured on-core before the
    /// offload), observed once per poll quantum; `null` = not kill-bounded.
    kill_flag: ?*std.atomic.Value(bool),
    /// The encrypted-from-server reader interface handed to `Client.init` as
    /// `input`. Its buffer MUST be `>= tls_min_buffer_len`.
    reader_interface: std.Io.Reader,
    /// The encrypted-to-server writer interface handed to `Client.init` as
    /// `output`. Its buffer MUST be `>= tls_min_buffer_len`.
    writer_interface: std.Io.Writer,
    /// Out-of-band classification of the LAST reader failure (kill → `other`,
    /// deadline → `timed_out`, else the mapped `recv(2)` reason).
    read_reason: Reason = .ok,
    /// Out-of-band classification of the LAST writer failure.
    write_reason: Reason = .ok,

    /// Build a `SocketStream` over `handle` (which must already be
    /// `O_NONBLOCK`). `timeout_ms` is a RELATIVE budget for the whole session's
    /// I/O (`<= 0` → no deadline), converted ONCE to an absolute monotonic
    /// deadline so every subsequent fill/drain shares it. `read_buffer` is the
    /// encrypted-from-server buffer (`Client.init` asserts `>= tls_min_buffer_len`)
    /// and `write_buffer` the encrypted-to-server buffer (the client's drain
    /// asserts the same); both are borrowed, never owned.
    pub fn init(
        handle: Fd,
        timeout_ms: i64,
        kill_flag: ?*std.atomic.Value(bool),
        read_buffer: []u8,
        write_buffer: []u8,
    ) SocketStream {
        return .{
            .handle = handle,
            .deadline_ms = if (timeout_ms > 0) checkedDeadline(monotonicMillis(), timeout_ms) else 0,
            .kill_flag = kill_flag,
            .reader_interface = .{
                .buffer = read_buffer,
                .vtable = &.{
                    .stream = readerStream,
                    .readVec = readerReadVec,
                },
                .seek = 0,
                .end = 0,
            },
            .writer_interface = .{
                .buffer = write_buffer,
                .vtable = &.{
                    .drain = writerDrain,
                    .flush = writerFlush,
                },
            },
        };
    }

    /// The encrypted-from-server `Reader` to pass as `Client.init`'s `input`.
    pub fn inputReader(self: *SocketStream) *std.Io.Reader {
        return &self.reader_interface;
    }

    /// The encrypted-to-server `Writer` to pass as `Client.init`'s `output`.
    pub fn outputWriter(self: *SocketStream) *std.Io.Writer {
        return &self.writer_interface;
    }

    /// Re-arm this PERSISTENT adapter for a fresh operation: recompute the
    /// single absolute monotonic deadline from a new RELATIVE `timeout_ms`
    /// (`<= 0` → no deadline), install the CURRENT owner's `kill_flag`, and
    /// clear the out-of-band failure reasons. A `TlsSession`'s adapter outlives
    /// the handshake (it also carries every later recv/send), so each op must
    /// re-arm before driving I/O: the deadline is that op's budget, and the
    /// kill flag must point at the CURRENT owner's `pending_kill` — after a
    /// cross-process move the owner (hence the kill flag) changes, and the
    /// handshake-era flag would dangle. Clearing `read_reason`/`write_reason`
    /// lets the caller distinguish a TRANSPORT failure (reason set by the
    /// vtable) from a TLS record-layer failure (reason left `.ok`).
    pub fn rearm(self: *SocketStream, timeout_ms: i64, kill_flag: ?*std.atomic.Value(bool)) void {
        self.deadline_ms = if (timeout_ms > 0) checkedDeadline(monotonicMillis(), timeout_ms) else 0;
        self.kill_flag = kill_flag;
        self.read_reason = .ok;
        self.write_reason = .ok;
    }

    /// POLL-QUANTUM-bounded, deadline+kill-checked NON-BLOCKING `recv(2)` into
    /// `dest` (`dest.len >= 1`). Returns the bytes read (`>= 1`), `EndOfStream`
    /// on a clean EOF (`recv() == 0`), or `ReadFailed` on kill/timeout/error —
    /// stashing the classified `Reason` in `read_reason` first. Tolerates
    /// `EAGAIN`/`EWOULDBLOCK`/`EINTR` by re-polling (the always-non-blocking fd
    /// can wake spuriously readable), re-checking the absolute deadline + kill
    /// each quantum. Poll-less targets fall back to the fork's blocking
    /// `netRead` (timeout/kill a documented no-op there).
    fn recvInto(self: *SocketStream, dest: []u8) std.Io.Reader.Error!usize {
        if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) {
            const the_io = io();
            const handle = fdFromBits(self.handle);
            var iovec = [1][]u8{dest};
            const n = the_io.vtable.netRead(the_io.userdata, handle, iovec[0..]) catch |err| {
                self.read_reason = mapReadError(err);
                return error.ReadFailed;
            };
            if (n == 0) return error.EndOfStream;
            return n;
        }
        const handle = fdFromBits(self.handle);
        const has_deadline = self.deadline_ms > 0;
        while (true) {
            if (self.kill_flag) |flag| {
                if (flag.load(.acquire)) {
                    self.read_reason = .other;
                    return error.ReadFailed;
                }
            }
            var quantum: i32 = poll_quantum_ms;
            if (has_deadline) {
                const remaining = self.deadline_ms - monotonicMillis();
                if (remaining <= 0) {
                    self.read_reason = .timed_out;
                    return error.ReadFailed;
                }
                if (remaining < quantum) quantum = @intCast(remaining);
            }
            switch (waitReadable(handle, quantum)) {
                .timeout => continue, // re-check deadline + kill
                .failed => {
                    self.read_reason = .other;
                    return error.ReadFailed;
                },
                .ready => {},
            }
            const rc = std.posix.system.recv(handle, @ptrCast(dest.ptr), dest.len, 0);
            switch (std.posix.errno(rc)) {
                .SUCCESS => {
                    const n: usize = @intCast(rc);
                    if (n == 0) return error.EndOfStream; // clean EOF
                    return n;
                },
                // Spurious readable wake / competing reader / interrupted — NOT
                // EOF and NOT an error: re-poll (deadline + kill re-checked at
                // the loop top).
                .AGAIN, .INTR => continue,
                else => |recv_errno| {
                    self.read_reason = mapRecvErrno(recv_errno);
                    return error.ReadFailed;
                },
            }
        }
    }

    /// `Reader.VTable.stream`: fill `w` (up to `limit`) with one bounded recv.
    /// The record layer never calls this (it drives `input` via `peek`/`take`,
    /// which route through `readVec`), but a fully-formed adapter honours the
    /// whole vtable so `discard`/copy loops behave.
    fn readerStream(io_r: *std.Io.Reader, io_w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *SocketStream = @alignCast(@fieldParentPtr("reader_interface", io_r));
        const dest = limit.slice(try io_w.writableSliceGreedy(1));
        const n = try self.recvInto(dest);
        io_w.advance(n);
        return n;
    }

    /// `Reader.VTable.readVec`: the buffer-fill path the record layer actually
    /// uses. `peek`/`take` → `fill` → `rebase` (which guarantees room) → here
    /// with `data[0]` EMPTY, per the vtable contract ("`data[0]` may have zero
    /// length, in which case the implementation must write to `Reader.buffer`").
    /// We recv straight into `buffer[end..]`, advance `end`, and return `0`.
    /// When (only via a non-`fill` caller) the buffer has no room, we fall back
    /// to the first caller vector so the adapter stays contract-correct.
    fn readerReadVec(io_r: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
        const self: *SocketStream = @alignCast(@fieldParentPtr("reader_interface", io_r));
        const r = &self.reader_interface;
        const buffer_tail = r.buffer[r.end..];
        if (buffer_tail.len != 0) {
            const n = try self.recvInto(buffer_tail);
            r.end += n;
            return 0;
        }
        // No room in the reader buffer (never taken on the `fill` path, which
        // rebases first): honour the caller vector instead of spinning.
        if (data.len == 0 or data[0].len == 0) return 0;
        return self.recvInto(data[0]);
    }

    /// `Writer.VTable.drain`: send `buffered()` first, then every slice of
    /// `data` (the last repeated `splat` times), each fully through the
    /// poll-quantum send loop. Returns `consume(total)` — the count consumed
    /// from `data`, resetting the buffer. A stalled/killed send surfaces
    /// `WriteFailed` with the reason stashed in `write_reason`.
    fn writerDrain(io_w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *SocketStream = @alignCast(@fieldParentPtr("writer_interface", io_w));
        var total: usize = 0;
        const buffered = io_w.buffered();
        if (buffered.len != 0) {
            try self.sendAll(buffered);
            total += buffered.len;
        }
        if (data.len != 0) {
            for (data[0 .. data.len - 1]) |chunk| {
                if (chunk.len != 0) {
                    try self.sendAll(chunk);
                    total += chunk.len;
                }
            }
            const last = data[data.len - 1];
            if (last.len != 0) {
                var repeat: usize = 0;
                while (repeat < splat) : (repeat += 1) {
                    try self.sendAll(last);
                    total += last.len;
                }
            }
        }
        return io_w.consume(total);
    }

    /// `Writer.VTable.flush`: push every buffered byte to the socket and reset
    /// the buffer. THE ADAPTER HALF OF THE DOUBLE-FLUSH: `Client.flush`
    /// ENCRYPTS plaintext into THIS writer's buffer (via `writableSliceGreedy`
    /// + `advance`) but does NOT drain it, so the TLS send leaf (Job 3) must
    /// call `client.writer.flush()` (encrypt) THEN `client.output.flush()`
    /// (this — actually push the ciphertext) or the peer hangs on ciphertext
    /// stuck in the buffer.
    fn writerFlush(io_w: *std.Io.Writer) std.Io.Writer.Error!void {
        const self: *SocketStream = @alignCast(@fieldParentPtr("writer_interface", io_w));
        const buffered = io_w.buffered();
        if (buffered.len != 0) {
            try self.sendAll(buffered);
            io_w.end = 0;
        }
    }

    /// Send ALL of `bytes` through the poll-quantum + deadline + kill send loop
    /// (the `send`/`sendImplPosix` discipline), or fail with `WriteFailed` and
    /// the classified `Reason` stashed in `write_reason`. The fd is always
    /// `O_NONBLOCK`, so each `send(2)` places only what currently fits and the
    /// per-quantum deadline/kill checks always run (HIGH-2). Poll-less targets
    /// use the fork's blocking `netWrite`.
    fn sendAll(self: *SocketStream, bytes: []const u8) std.Io.Writer.Error!void {
        if (bytes.len == 0) return;
        if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) {
            const the_io = io();
            const handle = fdFromBits(self.handle);
            var sent: usize = 0;
            while (sent < bytes.len) {
                const written = writeOnce(the_io, handle, bytes[sent..]) catch |err| {
                    self.write_reason = mapWriteError(err);
                    return error.WriteFailed;
                };
                if (written == 0) {
                    self.write_reason = .connection_reset;
                    return error.WriteFailed;
                }
                sent += written;
            }
            return;
        }
        const handle = fdFromBits(self.handle);
        const flags: u32 = std.posix.MSG.NOSIGNAL; // fd already O_NONBLOCK
        const has_deadline = self.deadline_ms > 0;
        var sent: usize = 0;
        while (sent < bytes.len) {
            if (self.kill_flag) |flag| {
                if (flag.load(.acquire)) {
                    self.write_reason = .other;
                    return error.WriteFailed;
                }
            }
            var quantum: i32 = poll_quantum_ms;
            if (has_deadline) {
                const remaining = self.deadline_ms - monotonicMillis();
                if (remaining <= 0) {
                    self.write_reason = .timed_out;
                    return error.WriteFailed;
                }
                if (remaining < quantum) quantum = @intCast(remaining);
            }
            switch (waitWritable(handle, quantum)) {
                .timeout => continue, // re-check deadline + kill
                .failed => {
                    self.write_reason = .other;
                    return error.WriteFailed;
                },
                .ready => {},
            }
            const chunk = bytes[sent..];
            const rc = std.posix.system.send(handle, @ptrCast(chunk.ptr), chunk.len, flags);
            switch (std.posix.errno(rc)) {
                .SUCCESS => {
                    const written: usize = @intCast(rc);
                    if (written == 0) {
                        self.write_reason = .connection_reset;
                        return error.WriteFailed;
                    }
                    sent += written;
                },
                // Buffer filled between poll and send, or interrupted — re-poll.
                .AGAIN, .INTR => {},
                else => |send_errno| {
                    self.write_reason = mapSendErrno(send_errno);
                    return error.WriteFailed;
                },
            }
        }
    }
};

/// Classify a `std.crypto.tls.Client.InitError` into a stable, gate-crossing
/// `Reason` (Phase S4). SECURITY: every CERTIFICATE-verification failure — a
/// host mismatch, an expired / not-yet-valid certificate, an untrusted issuer,
/// a bad certificate signature, or the umbrella `TlsCertificateNotVerified` —
/// maps to `tls_cert_invalid`, so a verification failure is ALWAYS a distinct,
/// typed outcome the caller can surface as "the peer is not trusted" and is
/// NEVER silently folded into a generic transport error. Everything else — a
/// fatal alert, an unexpected/mal-formed handshake message, a record-layer
/// decrypt failure, insufficient entropy, or the transport read/write failing
/// mid-handshake — is `tls_handshake_failed` (the design's "cert-* →
/// tls_cert_invalid, else → tls_handshake_failed", exhaustive by construction).
pub fn mapTlsInitError(err: tls.Client.InitError) Reason {
    return switch (err) {
        error.CertificateFieldHasInvalidLength,
        error.CertificateHostMismatch,
        error.CertificatePublicKeyInvalid,
        error.CertificateExpired,
        error.CertificateFieldHasWrongDataType,
        error.CertificateIssuerMismatch,
        error.CertificateNotYetValid,
        error.CertificateSignatureAlgorithmMismatch,
        error.CertificateSignatureAlgorithmUnsupported,
        error.CertificateSignatureInvalid,
        error.CertificateSignatureInvalidLength,
        error.CertificateSignatureNamedCurveUnsupported,
        error.CertificateSignatureUnsupportedBitCount,
        error.TlsCertificateNotVerified,
        error.UnsupportedCertificateVersion,
        error.CertificateTimeInvalid,
        error.CertificateHasUnrecognizedObjectId,
        error.CertificateHasInvalidBitString,
        => .tls_cert_invalid,
        else => .tls_handshake_failed,
    };
}

// ---------------------------------------------------------------------------
// The lazy, process-global OS trust-store singleton (Phase S4, LOCKED
// decision 1). Mirrors the `io()` singleton: a `Certificate.Bundle` populated
// ONCE from the host OS trust store (`Certificate.Bundle.rescan` — macOS
// Security framework / Linux `/etc/ssl` / Windows / BSD) on first use, then
// SHARED read-only across every concurrent handshake under an `Io.RwLock`
// (which `Client.init`'s `Options.ca.bundle.lock` takes while it walks the
// chain). Population runs blocking file/keychain I/O, so it happens on the
// handshake job (Job 3), never on-core.
// ---------------------------------------------------------------------------

/// Guards the ONE-TIME population of `trust_bundle` (the same spinlock posture
/// as `io_mutex` — populated once, then only read).
var trust_init_mutex: std.atomic.Mutex = .unlocked;

/// The OS trust store, populated once by `trustStore`. `.empty` until then.
var trust_bundle: Certificate.Bundle = .empty;

/// Whether `trust_bundle` has been populated (success OR failure — a failed
/// rescan is NOT retried, so a broken trust store fails fast and identically
/// every time rather than re-scanning the filesystem on every connect).
var trust_ready: bool = false;

/// The outcome of the one-time rescan: `.ok` on success, else the failure
/// (`out_of_memory` / `other`) every subsequent caller also observes.
var trust_reason: Reason = .ok;

/// The reader/writer lock `Client.init` takes over `trust_bundle` while it
/// verifies a chain. Concurrent handshakes hold it as READERS; it exists so a
/// future trust-store refresh could take it as a writer without racing an
/// in-flight verification. Shared (one lock for the one shared bundle).
var trust_rwlock: std.Io.RwLock = .init;

/// The populated trust store plus everything `Client.init`'s
/// `Options.ca.bundle` needs (`gpa`, `io`, `lock`, `bundle`) — handed back so
/// the handshake (Job 3) wires it straight into the client options.
pub const TrustBundle = struct {
    bundle: *Certificate.Bundle,
    lock: *std.Io.RwLock,
    gpa: std.mem.Allocator,
    io: std.Io,
};

/// The result of `trustStore`: the shared CA bundle, or the rescan `Reason`.
pub const TrustOutcome = union(enum) {
    ready: TrustBundle,
    failed: Reason,
};

/// The lazily-initialized OS trust-store singleton. On the FIRST call it scans
/// the host OS standard trust-store locations (`Certificate.Bundle.rescan`,
/// blocking file/keychain I/O — safe on the handshake job, never on-core) and
/// caches the result; every later call returns the cached bundle with NO
/// rescan. Mutex-guarded population (one-time), then shared read-only across
/// concurrent handshakes under `trust_rwlock`. A rescan failure is cached and
/// returned identically thereafter (fail-fast, never a per-connect re-scan).
pub fn trustStore() TrustOutcome {
    const the_io = io();
    while (!trust_init_mutex.tryLock()) std.atomic.spinLoopHint();
    defer trust_init_mutex.unlock();
    if (!trust_ready) {
        const now = std.Io.Clock.now(.real, the_io);
        if (Certificate.Bundle.rescan(&trust_bundle, std.heap.page_allocator, the_io, now)) |_| {
            trust_reason = .ok;
        } else |rescan_error| {
            trust_reason = mapRescanError(rescan_error);
        }
        trust_ready = true;
    }
    if (trust_reason != .ok) return .{ .failed = trust_reason };
    return .{ .ready = .{
        .bundle = &trust_bundle,
        .lock = &trust_rwlock,
        .gpa = std.heap.page_allocator,
        .io = the_io,
    } };
}

/// Map a `Certificate.Bundle.rescan` failure to a stable `Reason`. Allocation
/// failure is `out_of_memory`; every filesystem/parse/OS failure degrades to
/// `other` (the trust store could not be read — a handshake then cannot verify
/// and fails closed).
fn mapRescanError(err: Certificate.Bundle.RescanError) Reason {
    return switch (err) {
        error.OutOfMemory => .out_of_memory,
        else => .other,
    };
}

// ---------------------------------------------------------------------------
// TLS client drivers (Phase S4 Jobs 2+3) — the offloadable leaves the bridge
// (`abi.zig` gate-ON, `SocketRuntime` gate-OFF) runs on the blocking pool /
// inline over an opaque `*TlsSession`. Kept HERE (this file already owns the
// `SocketStream` adapter + trust store + `mapTlsInitError`) so both the
// gate-ON and gate-OFF worlds reach them through their OWN `socket_io`
// instance, dealing across the C-ABI in only `fd` / `Reason` code / opaque
// pointer — the bridges never name `SocketStream`/`Client`/`TlsSession`. The
// `TlsSession` type is imported LAZILY inside each function (function-local
// `@import`) so the file-level `tls_session.zig ↔ socket_io.zig` reference
// stays a one-directional module dependency at container-analysis time.
//
// SECURITY POSTURE: verification is MANDATORY and wired ON here — the
// handshake always passes the OS trust bundle as `ca.bundle` and the server
// host as `host.explicit` (NEVER a `no_verification` variant; the loud
// insecure opt-in is a Job-4 surface concern). Handshake entropy comes from
// the OS CSPRNG (`secureRandomBytes`) and is scrubbed after use; a session
// with no secure entropy source FAILS CLOSED. Every teardown scrubs + frees
// the session (`tlsFreeSession`).
// ---------------------------------------------------------------------------

/// Fill `buffer` with cryptographically-secure random bytes from the OS
/// CSPRNG, returning false when no secure source is available on this target
/// (the handshake then FAILS CLOSED rather than proceed with weak entropy — a
/// predictable ClientHello random / key share is a critical TLS flaw). Linux
/// uses the raw `getrandom(2)` syscall (no libc dependency, blocks only until
/// the pool is first seeded); macOS/BSD/etc. use `arc4random_buf` (the kernel
/// CSPRNG via libc, always present on those targets). This file is the socket
/// syscall seam, so the raw entropy syscall is legitimate here.
fn secureRandomBytes(buffer: []u8) bool {
    if (comptime builtin.os.tag == .linux) {
        var filled: usize = 0;
        while (filled < buffer.len) {
            const rc = std.os.linux.getrandom(buffer[filled..].ptr, buffer.len - filled, 0);
            const signed: isize = @bitCast(rc);
            if (signed < 0) {
                // `getrandom` with flags=0 blocks until seeded, so the only
                // expected transient is EINTR; retry it, fail on anything else.
                if (std.posix.errno(rc) == .INTR) continue;
                return false;
            }
            filled += @intCast(signed);
        }
        return true;
    }
    if (comptime @TypeOf(std.c.arc4random_buf) != void) {
        std.c.arc4random_buf(buffer.ptr, buffer.len);
        return true;
    }
    return false;
}

/// The mandatory minimum size of each of a `TlsSession`'s four TLS buffers
/// (encrypted-in, encrypted-out, plaintext-in, plaintext-out): one whole
/// ciphertext record + header. `std.crypto.tls.Client.init` asserts the
/// transport reader buffer is at least this large, and `drain`/`flush` demand
/// the same room from the writer; sizing all four alike keeps the record layer
/// in its documented bounds.
pub const tls_session_buffer_len: usize = tls_min_buffer_len;

/// A single established TLS-client session: the record-layer `Client`, the raw
/// `SocketStream` transport adapter, and the four record-layer buffers, ALL in
/// ONE heap-stable allocation whose address never moves.
///
/// ## Why a heap-stable box
///
/// `std.crypto.tls.Client` embeds its plaintext `reader`/`writer` interfaces and
/// holds raw pointers to the transport `input`/`output` (this adapter's
/// reader/writer). Those interfaces recover their parent via `@fieldParentPtr`,
/// so the `Client` AND the `SocketStream` MUST stay at a fixed address for the
/// session's whole life — a `TlsSession` is allocated ONCE (`create`) and only
/// ever referenced through the returned pointer, never copied by value.
///
/// ## Ownership boundary
///
/// The domain slot stores the session as an opaque `?*anyopaque` it NEVER
/// dereferences; only the bridge (`abi.zig` gate-ON / `SocketRuntime` gate-OFF,
/// via the `tls*` drivers below) casts it back to `*TlsSession`. It lives in
/// THIS self-contained file (not a separate one) so the staged gate-OFF
/// `zap_socket_io` module — which cannot resolve cross-file relative imports —
/// gets the whole TLS surface from its own `socket_io` instance.
///
/// SECURITY: `deinit` `secureZero`s the entire established endpoint (the
/// negotiated `application_cipher` keys + sequence numbers, whichever role) AND
/// every buffer BEFORE freeing them, so no key or plaintext residue survives in
/// the freed pages.
///
/// The record-layer endpoint behind a `TlsSession`: a `tls.Client` (Phase S4
/// outbound) or a `tls.Server` (Phase S5 inbound), or `.unestablished` before
/// the handshake completes. Both established arms expose the identical
/// record-layer surface — `.reader` (decrypted inbound), `.writer` (encrypt
/// outbound), and `.end` (`close_notify`) — so `tlsRecv`/`tlsSend`/`tlsFreeSession`
/// are role-symmetric and switch only to pick the arm.
pub const TlsSessionRole = union(enum) {
    /// Before the handshake populates an arm. Zero-size payload, so the
    /// `TlsSession` box is safe to allocate and `secureZero`/free even if the
    /// handshake never runs.
    unestablished: void,
    /// An outbound (client) session — `Tls.connect`/`connect_host`/`upgrade`.
    client: tls.Client,
    /// An inbound (server) session — `Tls.accept`/`Tls.upgrade` (STARTTLS).
    server: tls.Server,
};

pub const TlsSession = struct {
    const Role = TlsSessionRole;

    /// The record-layer endpoint — a CLIENT (`Tls.connect`, Phase S4) or a
    /// SERVER (`Tls.accept`/`Tls.upgrade`, Phase S5) session over the SAME
    /// heap-stable box + adapter. `.unestablished` until the handshake succeeds
    /// (`tlsHandshake` populates `.client`, `tlsServerHandshake` populates
    /// `.server`). The established-session data path (`tlsRecv`/`tlsSend`) and
    /// teardown (`tlsFreeSession`/`zeroizeSecrets`) switch on the arm; both
    /// `tls.Client` and `tls.Server` expose the SAME record-layer surface
    /// (`.reader`/`.writer`/`.end`), so the data path is role-symmetric. The
    /// arm's `@fieldParentPtr` recovery (each embeds a `reader`/`writer` whose
    /// vtable recovers the parent) stays valid because the box never moves — the
    /// active arm lives at a stable address inside it, exactly as the bare
    /// `client` field did.
    role: Role,

    /// The raw-fd transport adapter (`input`/`output` for `Client.init`). Lives
    /// INSIDE the box so its embedded reader/writer keep a stable address for
    /// the `Client`'s `@fieldParentPtr` recovery, and it PERSISTS past the
    /// handshake to carry every later recv/send (re-armed per op).
    stream: SocketStream,

    /// Encrypted-from-server bytes (the adapter reader's buffer).
    encrypted_in: []u8,
    /// Encrypted-to-server bytes (the adapter writer's buffer).
    encrypted_out: []u8,
    /// Decrypted plaintext from the server (the `Client.reader`'s buffer).
    plaintext_in: []u8,
    /// Plaintext to encrypt to the server (the `Client.writer`'s buffer).
    plaintext_out: []u8,

    /// The allocator the box + buffers came from (production: page allocator;
    /// a unit test: the testing allocator, so a leak is caught).
    allocator: std.mem.Allocator,

    /// Whether the handshake has populated an endpoint arm (`role` is `.client`
    /// or `.server`). `deinit` scrubs regardless; this gates `close_notify` on
    /// teardown and lets the recv/send drivers assert a usable session.
    handshake_complete: bool = false,

    /// Allocate a heap-stable `TlsSession` and wire its four record-layer
    /// buffers + the `SocketStream` adapter over `handle` (already `O_NONBLOCK`).
    /// `timeout_ms`/`kill_flag` seed the adapter (re-armed per op). On ANY
    /// allocation failure everything already allocated is freed (no leak).
    pub fn create(
        allocator: std.mem.Allocator,
        handle: Fd,
        timeout_ms: i64,
        kill_flag: ?*std.atomic.Value(bool),
    ) std.mem.Allocator.Error!*TlsSession {
        const session = try allocator.create(TlsSession);
        errdefer allocator.destroy(session);

        const encrypted_in = try allocator.alloc(u8, tls_session_buffer_len);
        errdefer allocator.free(encrypted_in);
        const encrypted_out = try allocator.alloc(u8, tls_session_buffer_len);
        errdefer allocator.free(encrypted_out);
        const plaintext_in = try allocator.alloc(u8, tls_session_buffer_len);
        errdefer allocator.free(plaintext_in);
        const plaintext_out = try allocator.alloc(u8, tls_session_buffer_len);
        errdefer allocator.free(plaintext_out);

        session.* = .{
            .role = .unestablished,
            .stream = SocketStream.init(handle, timeout_ms, kill_flag, encrypted_in, encrypted_out),
            .encrypted_in = encrypted_in,
            .encrypted_out = encrypted_out,
            .plaintext_in = plaintext_in,
            .plaintext_out = plaintext_out,
            .allocator = allocator,
            .handshake_complete = false,
        };
        return session;
    }

    /// The decrypted-inbound `Reader` of the established endpoint (client OR
    /// server arm) — the role-symmetric read surface `tlsRecv` drives. Callable
    /// ONLY after a successful handshake (`handshake_complete`); an
    /// `.unestablished` session has no reader.
    pub fn establishedReader(session: *TlsSession) *std.Io.Reader {
        return switch (session.role) {
            .client => |*client_endpoint| &client_endpoint.reader,
            .server => |*server_endpoint| &server_endpoint.reader,
            .unestablished => unreachable,
        };
    }

    /// The encrypt-outbound `Writer` of the established endpoint (client OR
    /// server arm) — the role-symmetric write surface `tlsSend` drives. Callable
    /// ONLY after a successful handshake.
    pub fn establishedWriter(session: *TlsSession) *std.Io.Writer {
        return switch (session.role) {
            .client => |*client_endpoint| &client_endpoint.writer,
            .server => |*server_endpoint| &server_endpoint.writer,
            .unestablished => unreachable,
        };
    }

    /// Best-effort graceful `close_notify` over the established endpoint (client
    /// OR server arm) — `client.end()` / `server.end()` both flush buffered
    /// plaintext and append the alert into the adapter's output buffer. A no-op
    /// on an `.unestablished` session. The caller flushes the adapter afterward.
    fn endEstablished(session: *TlsSession) void {
        switch (session.role) {
            .client => |*client_endpoint| client_endpoint.end() catch {},
            .server => |*server_endpoint| server_endpoint.end() catch {},
            .unestablished => {},
        }
    }

    /// SECURITY: overwrite every byte of key-bearing memory with zeroes — the
    /// whole `Client` (negotiated keys + sequence numbers) plus all four buffers
    /// (plaintext/ciphertext residue). `std.crypto.secureZero` is not elided.
    /// Split out so a unit test can assert the region is zeroed while it is
    /// still readable (before the free).
    pub fn zeroizeSecrets(session: *TlsSession) void {
        // Scrub the WHOLE role union storage (its size is the larger of the
        // client/server arms), so whichever endpoint's negotiated keys +
        // sequence numbers are resident are overwritten regardless of the active
        // arm — and an `.unestablished` session scrubs harmlessly.
        std.crypto.secureZero(u8, std.mem.asBytes(&session.role));
        std.crypto.secureZero(u8, session.encrypted_in);
        std.crypto.secureZero(u8, session.encrypted_out);
        std.crypto.secureZero(u8, session.plaintext_in);
        std.crypto.secureZero(u8, session.plaintext_out);
    }

    /// Scrub the key material (`zeroizeSecrets`) then FREE the box + its four
    /// buffers. Called on EVERY session-drop path, so a dropped connection never
    /// leaves key residue in freed pages. Must be called exactly once for the
    /// free (a double scrub is harmless).
    pub fn deinit(session: *TlsSession) void {
        session.zeroizeSecrets();
        const allocator = session.allocator;
        allocator.free(session.encrypted_in);
        allocator.free(session.encrypted_out);
        allocator.free(session.plaintext_in);
        allocator.free(session.plaintext_out);
        allocator.destroy(session);
    }
};

/// Best-effort budget (ms) for the graceful `close_notify` write on teardown.
/// A single small alert record almost always leaves in the first non-blocking
/// `send(2)` (the OS send buffer has room), so this bounds only the rare
/// full-window case — it must NEVER hang a teardown, so `tlsFreeSession`
/// re-arms this tight deadline with NO kill flag (the handshake-era flag may
/// dangle after a move) and the fd is closed immediately after regardless.
const close_notify_budget_ms: i64 = 250;

/// Allocate a heap-stable `TlsSession` over `fd` (already `O_NONBLOCK`) from
/// the page allocator (the kernel-memory convention), returning it ERASED to
/// `*anyopaque` (the domain slot stores it opaquely) or null on OOM. The
/// `Client` is left un-populated; `tlsHandshake` runs the handshake. `fd` is
/// the raw connected socket; `timeout_ms`/`kill_flag` seed the adapter but are
/// re-armed per op, so any value is fine here.
pub fn tlsSessionCreate(fd: Fd, timeout_ms: i64, kill_flag: ?*std.atomic.Value(bool)) ?*anyopaque {
    const session = TlsSession.create(std.heap.page_allocator, fd, timeout_ms, kill_flag) catch return null;
    return @ptrCast(session);
}

/// Run the SYNCHRONOUS TLS client handshake over `session_opaque`'s adapter
/// with verification MANDATORY (`host.explicit` + the OS `ca.bundle`), bounded
/// by ONE absolute deadline (`timeout_ms`, re-armed here) and the owning
/// process's `kill_flag` — a slowloris handshake times out and stays killable
/// (§8 DoS). On success the session's `Client` is populated,
/// `handshake_complete` is set, and `.ok` is returned. On failure returns a
/// mapped `Reason`: a certificate-verification failure → `tls_cert_invalid`
/// (NEVER folded into a generic error), a transport timeout/kill → the stashed
/// transport reason, everything else TLS → `tls_handshake_failed`; the session
/// is NOT freed here (the caller frees it — it still holds the fd). The 240
/// entropy bytes come from the OS CSPRNG and are scrubbed on the way out.
///
/// `insecure` (⚠ testing-only): when `true`, BOTH hostname and CA verification
/// are disabled (`.host = .no_verification`, `.ca = .no_verification`) — an
/// UNAUTHENTICATED tunnel that a MITM can trivially impersonate. It is a
/// SEPARATE branch that shares nothing with the verified path above, reached
/// only through the loudly-named `Tls.*_insecure` surface + its own abi export,
/// so the default `false` is byte-for-byte the mandatory-verified handshake.
pub fn tlsHandshake(
    session_opaque: *anyopaque,
    host: []const u8,
    timeout_ms: i64,
    kill_flag: ?*std.atomic.Value(bool),
    insecure: bool,
) Reason {
    const session: *TlsSession = @ptrCast(@alignCast(session_opaque));
    session.stream.rearm(timeout_ms, kill_flag);

    var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
    // Scrub the entropy no matter how we exit — it seeds the ClientHello random
    // and the ephemeral key share.
    defer std.crypto.secureZero(u8, &entropy);
    if (!secureRandomBytes(&entropy)) return .tls_handshake_failed;

    if (insecure) {
        // ⚠ DANGER — verification is FULLY DISABLED (both hostname AND CA
        // chain-of-trust). This establishes an UNAUTHENTICATED tunnel: a
        // man-in-the-middle presenting ANY certificate is accepted. Reached
        // ONLY via the explicitly-named, loudly-documented `Tls.*_insecure`
        // Zap surface + its own SEPARATE abi export — never on the default
        // verified path (this branch touches NO trust store and shares NOTHING
        // with the verified `Options` below, so it cannot regress it). The
        // owning process's kill flag + the single absolute deadline still bound
        // the handshake, so even an insecure handshake stays DoS-safe.
        const insecure_now = std.Io.Clock.now(.real, io());
        const insecure_client = tls.Client.init(session.stream.inputReader(), session.stream.outputWriter(), .{
            .host = .no_verification,
            .ca = .no_verification,
            .write_buffer = session.plaintext_out,
            .read_buffer = session.plaintext_in,
            .entropy = &entropy,
            .realtime_now = insecure_now,
        }) catch |err| return switch (err) {
            error.ReadFailed => if (session.stream.read_reason != .ok) session.stream.read_reason else .tls_handshake_failed,
            error.WriteFailed => if (session.stream.write_reason != .ok) session.stream.write_reason else .tls_handshake_failed,
            else => mapTlsInitError(err),
        };
        session.role = .{ .client = insecure_client };
        session.handshake_complete = true;
        return .ok;
    }

    const trust = switch (trustStore()) {
        .ready => |bundle| bundle,
        .failed => |reason| return reason,
    };

    const now = std.Io.Clock.now(.real, trust.io);
    const client = tls.Client.init(session.stream.inputReader(), session.stream.outputWriter(), .{
        // MANDATORY host + CA verification — the whole point of a TLS client.
        .host = .{ .explicit = host },
        .ca = .{ .bundle = .{
            .gpa = trust.gpa,
            .io = trust.io,
            .lock = trust.lock,
            .bundle = trust.bundle,
        } },
        .write_buffer = session.plaintext_out,
        .read_buffer = session.plaintext_in,
        .entropy = &entropy,
        .realtime_now = now,
    }) catch |err| return switch (err) {
        // A transport read/write that failed mid-handshake stashed the precise
        // reason out-of-band (deadline → timed_out, kill → other, reset, …);
        // prefer it so a slowloris handshake surfaces `timed_out`, not a
        // generic handshake failure.
        error.ReadFailed => if (session.stream.read_reason != .ok) session.stream.read_reason else .tls_handshake_failed,
        error.WriteFailed => if (session.stream.write_reason != .ok) session.stream.write_reason else .tls_handshake_failed,
        else => mapTlsInitError(err),
    };

    session.role = .{ .client = client };
    session.handshake_complete = true;
    return .ok;
}

/// Receive decrypted application bytes from an established TLS session into a
/// FRESH buffer grown from `allocator` (the caller's recv arena) — the leaf
/// drives `session.client.reader`, which pulls ciphertext through the adapter
/// (poll-quantum, deadline + kill bounded, re-armed here) and decrypts into the
/// session's OWN plaintext buffer; we then COPY the plaintext into the arena
/// allocation and return THAT. The session's buffers are NEVER handed to the
/// Zap layer, so the recv-arena watermark reset can never free Client-referenced
/// bytes (UAF-safe). `exact_target > 0` accumulates exactly that many bytes
/// (spanning records, growing geometrically — MED-3); `0` returns the first
/// record's plaintext (next-available). Mirrors `recv`'s outcome contract:
/// `status == 0` chunk, `-1` clean close (`close_notify`/EOF), `> 0` a `Reason`
/// code (transport timeout/kill, or a TLS record-layer failure →
/// `tls_handshake_failed`). Returns `error.OutOfMemory` (nothing leaked).
pub fn tlsRecv(
    session_opaque: *anyopaque,
    allocator: std.mem.Allocator,
    exact_target: usize,
    next_available_capacity: usize,
    timeout_ms: i64,
    kill_flag: ?*std.atomic.Value(bool),
) error{OutOfMemory}!RecvOutcome {
    const session: *TlsSession = @ptrCast(@alignCast(session_opaque));
    session.stream.rearm(timeout_ms, kill_flag);
    const reader: *std.Io.Reader = session.establishedReader();

    const exact = exact_target > 0;
    const initial_capacity: usize = if (exact)
        @max(@min(exact_target, recv_exact_initial_capacity), 1)
    else
        @max(next_available_capacity, 1);
    var buffer = try allocator.alloc(u8, initial_capacity);
    errdefer allocator.free(buffer);

    var filled: usize = 0;
    while (true) {
        if (exact and filled >= exact_target) break;
        // Ensure at least one decrypted byte is buffered — this DRIVES the
        // adapter recv + record decrypt, bounded by the re-armed deadline/kill.
        const available = reader.peekGreedy(1) catch |err| switch (err) {
            // Clean close (`close_notify`) or an allowed truncation EOF: CLOSED,
            // carrying any partial an exact read already accumulated (mirrors
            // the raw recv's mid-frame-EOF contract).
            error.EndOfStream => return try shrinkRecv(allocator, buffer, recv_status_closed, filled),
            error.ReadFailed => {
                // A TRANSPORT failure stashed its reason in the adapter; a TLS
                // record-layer failure (bad MAC, fatal alert, malformed record)
                // left it `.ok` (the Client stashed detail in `client.read_err`).
                const reason: Reason = if (session.stream.read_reason != .ok)
                    session.stream.read_reason
                else
                    .tls_handshake_failed;
                return try shrinkRecv(allocator, buffer, @intFromEnum(reason), filled);
            },
        };

        var take_len = available.len;
        if (exact) {
            take_len = @min(take_len, exact_target - filled);
            const need = filled + take_len;
            if (need > buffer.len) {
                const grown = @max(need, @min(buffer.len *| 2, exact_target));
                buffer = try allocator.realloc(buffer, grown);
            }
        } else {
            // Next-available: never exceed the moderate chunk buffer; any
            // remainder stays buffered in the reader for the next call.
            take_len = @min(take_len, buffer.len);
        }

        @memcpy(buffer[filled..][0..take_len], available[0..take_len]);
        reader.toss(take_len);
        filled += take_len;

        if (!exact) return try shrinkRecv(allocator, buffer, recv_status_chunk, filled);
    }
    return try shrinkRecv(allocator, buffer, recv_status_chunk, filled);
}

/// Return the failure `Reason` for a TLS write: the transport reason the
/// adapter stashed (timeout/kill/reset), or `tls_handshake_failed` for a
/// record-layer encrypt failure that never reached the transport.
fn tlsWriteReason(session: *TlsSession) Reason {
    return if (session.stream.write_reason != .ok) session.stream.write_reason else .tls_handshake_failed;
}

/// Encrypt and send `bytes` over an established TLS session, bounded by the
/// re-armed deadline + kill. THE DOUBLE-FLUSH (the flush-composition gotcha):
/// (1) write the plaintext into `client.writer` (encrypting whole records into
/// the adapter's output buffer as it fills), (2) `client.writer.flush()`
/// encrypts the trailing partial record into the adapter's output buffer, and
/// (3) `session.stream.outputWriter().flush()` actually PUSHES that ciphertext
/// to the wire — WITHOUT step (3) the ciphertext is stuck in the buffer and the
/// peer hangs. Returns `.ok` + `bytes.len` on full delivery, else the mapped
/// reason with `bytes_sent == 0` (a TLS record is atomic — there is no
/// meaningful partial-plaintext boundary to report mid-record).
pub fn tlsSend(
    session_opaque: *anyopaque,
    bytes: []const u8,
    timeout_ms: i64,
    kill_flag: ?*std.atomic.Value(bool),
) SendOutcome {
    const session: *TlsSession = @ptrCast(@alignCast(session_opaque));
    session.stream.rearm(timeout_ms, kill_flag);
    const writer: *std.Io.Writer = session.establishedWriter();

    writer.writeAll(bytes) catch return .{ .reason = tlsWriteReason(session), .bytes_sent = 0 };
    // (2) encrypt the buffered plaintext, then (3) push the ciphertext.
    writer.flush() catch return .{ .reason = tlsWriteReason(session), .bytes_sent = 0 };
    session.stream.outputWriter().flush() catch return .{ .reason = tlsWriteReason(session), .bytes_sent = 0 };
    return .{ .reason = .ok, .bytes_sent = bytes.len };
}

/// SECURITY: free a TLS session on ANY teardown path (explicit close, kill/
/// crash sweep, handoff-undo, dead-letter reclaim). Best-effort graceful
/// `close_notify` FIRST (only if the handshake completed) — re-armed with a
/// tight deadline and NO kill flag so it can NEVER hang teardown and never
/// dereferences a possibly-dangling handshake-era kill flag — then scrub the
/// key material and free (`TlsSession.deinit` → `secureZero` + free). Called
/// EXACTLY ONCE per session because the fd is closed exactly once (the
/// single-owner invariant), so the session is freed exactly once.
pub fn tlsFreeSession(session_opaque: *anyopaque) void {
    const session: *TlsSession = @ptrCast(@alignCast(session_opaque));
    if (session.handshake_complete) {
        session.stream.rearm(close_notify_budget_ms, null);
        // `client.end`/`server.end` flush buffered plaintext + append the
        // `close_notify` alert into the adapter's output buffer; the adapter
        // flush pushes it to the wire (the same double-flush). Best-effort —
        // ignore any failure (a torn-down peer, a dangling move, etc.).
        session.endEstablished();
        session.stream.outputWriter().flush() catch {};
    }
    session.deinit();
}

// ---------------------------------------------------------------------------
// TLS SERVER surface (Phase S5) — the per-listener certificate/key store and
// the server-handshake trampoline. Mirrors the client path with the roles
// swapped: a listener carries a `TlsServerConfig` (its long-lived cert chain +
// private key + ALPN list, parsed ONCE at listen time); each accepted
// connection runs `tls.Server.init` over the SAME poll-quantum adapter as the
// client, offloaded under the SAME single-absolute-deadline + per-quantum
// kill-flag discipline, then attaches the established `.server` session to the
// accepted handle.
//
// SECURITY: the long-lived private key lives ONLY in the per-listener
// `TlsServerConfig` and is NEVER copied into a session — a `TlsSession` holds
// only the ephemeral/derived secrets (scrubbed by `zeroizeSecrets`). The config
// itself scrubs the private key on free.
// ---------------------------------------------------------------------------

/// Classify a `tls.Server.InitError` into a stable, gate-crossing `Reason`
/// (Phase S5). `TlsConfigInvalid` and every server-certificate-parse failure
/// mean the SERVER's OWN certificate/key configuration is unusable →
/// `tls_config_invalid` (pre-validated at listen time, so a handshake-time
/// occurrence is a belt-and-suspenders map). `TlsHandshakeFailure` — no
/// mutually-supported cipher / key-exchange group / SIGNATURE SCHEME — is the
/// fork's "could not present a usable certificate for this client" outcome
/// (for a TLS-1.3-only server every client supports AES-128-GCM + x25519, so in
/// practice this is a signature-scheme/cert mismatch): → `tls_no_matching_cert`.
/// `InsufficientEntropy` and everything else (a fatal alert, an unexpected /
/// mal-formed / truncated ClientHello, a record-layer decrypt failure, the
/// transport failing mid-handshake, a signing failure) → `tls_handshake_failed`.
pub fn mapTlsServerInitError(err: tls.Server.InitError) Reason {
    return switch (err) {
        error.TlsConfigInvalid,
        error.CertificateFieldHasInvalidLength,
        error.CertificateFieldHasWrongDataType,
        error.CertificateHasUnrecognizedObjectId,
        error.CertificateHasInvalidBitString,
        error.UnsupportedCertificateVersion,
        error.CertificateTimeInvalid,
        => .tls_config_invalid,
        error.TlsHandshakeFailure => .tls_no_matching_cert,
        else => .tls_handshake_failed,
    };
}

/// A single-cert TLS server's per-listener configuration: the certificate chain
/// (leaf first) + the leaf private key + the ALPN preference list, parsed ONCE
/// at `Tls.listen` time and stored addressable from the accept path (bound to
/// the listener slot's opaque `tls_state`, `SocketKind.tls_listener`). Heap-box,
/// referenced only through the erased pointer; the socket domain treats it as
/// opaque exactly like a `TlsSession`, and every listener-close path frees it
/// through `tlsFreeServerConfig`.
///
/// SECURITY: `private_key` is the LONG-LIVED secret. It is held ONLY here and
/// NEVER copied into a per-connection `TlsSession` (`tls.Server.init` reads it
/// to sign the CertificateVerify in place and emits only the signature bytes;
/// the session keeps only the ephemeral/derived traffic secrets). It is scrubbed
/// on free.
pub const TlsServerConfig = struct {
    /// Concatenated DER bytes of the certificate chain (leaf first). Owned; the
    /// `cert_chain` `Certificate`s index INTO this buffer.
    cert_bytes: []u8,
    /// The chain as `Certificate`s (leaf first), each `.buffer = cert_bytes`
    /// with its own `.index`. `tls.Server.init` reads only the leaf in this
    /// phase but the whole chain is sent in the Certificate message.
    cert_chain: []Certificate,
    /// The leaf private key. The long-lived secret — scrubbed on free, NEVER
    /// copied into a session.
    private_key: tls.Server.PrivateKey,
    /// Owned backing storage the `alpn_protocols` slices point into (the
    /// newline-joined wire the Zap surface passed, copied).
    alpn_storage: []u8,
    /// The server's ALPN protocol list in preference order, pointing into
    /// `alpn_storage`; empty when the listener configured no ALPN.
    alpn_protocols: [][]const u8,
    /// The allocator the box + all owned slices came from.
    allocator: std.mem.Allocator,

    /// Scrub the private key (`secureZero`) then FREE the box + every owned
    /// slice. Called on EVERY listener-close path so the long-lived key never
    /// survives in freed pages and nothing leaks. Called exactly once per config
    /// (the listener fd is closed exactly once).
    pub fn deinit(config: *TlsServerConfig) void {
        std.crypto.secureZero(u8, std.mem.asBytes(&config.private_key));
        const allocator = config.allocator;
        allocator.free(config.cert_bytes);
        allocator.free(config.cert_chain);
        allocator.free(config.alpn_storage);
        allocator.free(config.alpn_protocols);
        allocator.destroy(config);
    }
};

/// The outcome of `tlsServerConfigCreate`: the erased `*TlsServerConfig` on
/// success (`reason == .ok`), else the classified failure with a null config.
pub const ServerConfigOutcome = struct {
    reason: Reason,
    config: ?*anyopaque,
};

/// Decode every `-----BEGIN CERTIFICATE-----`/`-----END CERTIFICATE-----` block
/// of `cert_pem` (leaf first) into one contiguous owned DER buffer and build the
/// `[]Certificate` chain indexing into it. The decoded DER is always smaller
/// than its base64 PEM, so the buffer is sized to `cert_pem.len` then shrunk to
/// the exact decoded length. Returns `error.MalformedCertPem` when no complete
/// block is present, propagates `error.OutOfMemory`.
fn decodeCertChain(
    allocator: std.mem.Allocator,
    cert_pem: []const u8,
) error{ OutOfMemory, MalformedCertPem }!struct { bytes: []u8, chain: []Certificate } {
    const begin_marker = "-----BEGIN CERTIFICATE-----";
    const end_marker = "-----END CERTIFICATE-----";
    const decoder = std.base64.standard.decoderWithIgnore(" \t\r\n");

    // Pass 1: count complete blocks so the chain array is sized exactly.
    var block_count: usize = 0;
    {
        var scan: usize = 0;
        while (std.mem.indexOfPos(u8, cert_pem, scan, begin_marker)) |begin_start| {
            const body_start = begin_start + begin_marker.len;
            const body_end = std.mem.indexOfPos(u8, cert_pem, body_start, end_marker) orelse break;
            block_count += 1;
            scan = body_end + end_marker.len;
        }
    }
    if (block_count == 0) return error.MalformedCertPem;

    var bytes = try allocator.alloc(u8, cert_pem.len);
    errdefer allocator.free(bytes);
    const chain = try allocator.alloc(Certificate, block_count);
    errdefer allocator.free(chain);

    // Pass 2: decode each block into `bytes`, recording the start offset.
    var written: usize = 0;
    var chain_index: usize = 0;
    var scan: usize = 0;
    while (std.mem.indexOfPos(u8, cert_pem, scan, begin_marker)) |begin_start| {
        const body_start = begin_start + begin_marker.len;
        const body_end = std.mem.indexOfPos(u8, cert_pem, body_start, end_marker) orelse break;
        const encoded = std.mem.trim(u8, cert_pem[body_start..body_end], " \t\r\n");
        const decoded_start = written;
        const decoded_len = decoder.decode(bytes[written..], encoded) catch return error.MalformedCertPem;
        written += decoded_len;
        chain[chain_index] = .{ .buffer = bytes[0..written], .index = @intCast(decoded_start) };
        chain_index += 1;
        scan = body_end + end_marker.len;
    }

    // Shrink the DER buffer to the exact decoded length; re-point every chain
    // entry's `buffer` at the resized (possibly moved) allocation.
    if (written != bytes.len) bytes = try allocator.realloc(bytes, written);
    for (chain) |*cert| cert.buffer = bytes;
    return .{ .bytes = bytes, .chain = chain };
}

/// Split the newline-joined ALPN wire `alpn_wire` (the format the Zap surface
/// builds with `String.join(protocols, "\n")`) into an owned `[][]const u8`
/// preference list, skipping empty segments. The slices point into an owned copy
/// of the wire so they outlive the caller's buffer. An empty/whitespace wire
/// yields an empty list (no ALPN).
fn parseAlpnList(
    allocator: std.mem.Allocator,
    alpn_wire: []const u8,
) error{OutOfMemory}!struct { storage: []u8, protocols: [][]const u8 } {
    const storage = try allocator.dupe(u8, alpn_wire);
    errdefer allocator.free(storage);

    var count: usize = 0;
    var counter = std.mem.splitScalar(u8, storage, '\n');
    while (counter.next()) |segment| {
        if (segment.len != 0) count += 1;
    }

    const protocols = try allocator.alloc([]const u8, count);
    errdefer allocator.free(protocols);
    var index: usize = 0;
    var splitter = std.mem.splitScalar(u8, storage, '\n');
    while (splitter.next()) |segment| {
        if (segment.len != 0) {
            protocols[index] = segment;
            index += 1;
        }
    }
    return .{ .storage = storage, .protocols = protocols };
}

/// Parse a TLS server's certificate chain (`cert_pem`, PEM, leaf first), leaf
/// private key (`key_pem`, PEM — SEC1 `EC PRIVATE KEY`, PKCS#8 `PRIVATE KEY`, or
/// PKCS#1 `RSA PRIVATE KEY`), and newline-joined ALPN list (`alpn_wire`) into a
/// heap-stable `TlsServerConfig` ERASED to `*anyopaque`. Validates the key
/// matches the leaf certificate's public key up front, so a mis-configuration is
/// caught at `Tls.listen` time (→ `tls_config_invalid`), NEVER surfacing
/// mysteriously mid-handshake. On ANY parse/validation failure everything
/// already allocated is freed (no leak) and `reason` is set with a null config.
/// The page allocator (kernel-memory convention) is used in production.
pub fn tlsServerConfigCreate(
    cert_pem: []const u8,
    key_pem: []const u8,
    alpn_wire: []const u8,
) ServerConfigOutcome {
    return tlsServerConfigCreateAlloc(std.heap.page_allocator, cert_pem, key_pem, alpn_wire);
}

/// The allocator-explicit body of `tlsServerConfigCreate` (a unit test passes
/// the testing allocator so a leak is caught). Wraps the error-union builder and
/// maps its failure to a `Reason` — `OutOfMemory` → `out_of_memory`, every
/// parse/validation failure → `tls_config_invalid`.
pub fn tlsServerConfigCreateAlloc(
    allocator: std.mem.Allocator,
    cert_pem: []const u8,
    key_pem: []const u8,
    alpn_wire: []const u8,
) ServerConfigOutcome {
    const config = buildServerConfig(allocator, cert_pem, key_pem, alpn_wire) catch |err| return .{
        .reason = switch (err) {
            error.OutOfMemory => .out_of_memory,
            else => .tls_config_invalid,
        },
        .config = null,
    };
    return .{ .reason = .ok, .config = @ptrCast(config) };
}

/// Build the heap-stable `TlsServerConfig` or return a typed error. An
/// error-union return so `errdefer` cleanly reclaims every partially-built slice
/// (and scrubs the parsed private key) on ANY failure — the correct pattern for
/// fallible multi-step construction, no manual cleanup ladder.
fn buildServerConfig(
    allocator: std.mem.Allocator,
    cert_pem: []const u8,
    key_pem: []const u8,
    alpn_wire: []const u8,
) error{ OutOfMemory, TlsConfigInvalid }!*TlsServerConfig {
    const decoded = decodeCertChain(allocator, cert_pem) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.MalformedCertPem => return error.TlsConfigInvalid,
    };
    errdefer allocator.free(decoded.bytes);
    errdefer allocator.free(decoded.chain);

    // The leaf must parse and its public key must match the private key — the
    // whole `tls.Server.init` config precondition, checked HERE so a bad pairing
    // fails at listen, not at the first accept.
    const leaf_parsed = decoded.chain[0].parse() catch return error.TlsConfigInvalid;
    var private_key = tls.Server.PrivateKey.fromPem(key_pem) catch return error.TlsConfigInvalid;
    // Scrub the stack copy of the private key on EVERY exit (on success it has
    // already been copied into the heap box; on failure it never reached one).
    defer std.crypto.secureZero(u8, std.mem.asBytes(&private_key));
    if (!private_key.matchesCertificatePublicKey(leaf_parsed)) return error.TlsConfigInvalid;

    const alpn = try parseAlpnList(allocator, alpn_wire);
    errdefer allocator.free(alpn.storage);
    errdefer allocator.free(alpn.protocols);

    const config = try allocator.create(TlsServerConfig);
    config.* = .{
        .cert_bytes = decoded.bytes,
        .cert_chain = decoded.chain,
        .private_key = private_key,
        .alpn_storage = alpn.storage,
        .alpn_protocols = alpn.protocols,
        .allocator = allocator,
    };
    return config;
}

/// SECURITY: scrub the private key + free a `TlsServerConfig` on ANY
/// listener-close path (explicit close, kill/crash sweep, handoff-undo). The
/// listener-slot twin of `tlsFreeSession`; the socket domain hands the opaque
/// config pointer back on close (`SocketKind.tls_listener`), and the bridge
/// routes it here so the long-lived key is scrubbed exactly once.
pub fn tlsFreeServerConfig(config_opaque: *anyopaque) void {
    const config: *TlsServerConfig = @ptrCast(@alignCast(config_opaque));
    config.deinit();
}

/// Run the SYNCHRONOUS TLS SERVER handshake over `session_opaque`'s adapter
/// using `config_opaque`'s certificate chain + private key + ALPN list, bounded
/// by ONE absolute deadline (`timeout_ms`, re-armed here) and the owning
/// process's `kill_flag` — a slowloris handshake times out and stays killable
/// (§8 DoS), exactly like the client path. On success the session's `.server`
/// arm is populated, `handshake_complete` is set, and `.ok` is returned. On
/// failure returns a mapped `Reason`: a transport timeout/kill → the stashed
/// transport reason; no usable cert/sig for the client → `tls_no_matching_cert`;
/// a bad server config that slipped past listen-time validation →
/// `tls_config_invalid`; everything else TLS → `tls_handshake_failed`. The
/// session is NOT freed here (the caller frees it — it still holds the fd).
///
/// The 240 handshake-entropy bytes come from the OS CSPRNG and are scrubbed on
/// the way out; a session with no secure entropy source FAILS CLOSED. RSA PSS
/// salt + signing blinding are drawn from a ChaCha DRBG SEEDED from the OS
/// CSPRNG (also fail-closed) — a sound, non-failing randomness source for the
/// in-place CertificateVerify signing — and the DRBG state is scrubbed too. The
/// long-lived private key is read from the config to sign in place; only the
/// signature bytes leave, never the key.
pub fn tlsServerHandshake(
    session_opaque: *anyopaque,
    config_opaque: *anyopaque,
    timeout_ms: i64,
    kill_flag: ?*std.atomic.Value(bool),
) Reason {
    const session: *TlsSession = @ptrCast(@alignCast(session_opaque));
    const config: *TlsServerConfig = @ptrCast(@alignCast(config_opaque));
    session.stream.rearm(timeout_ms, kill_flag);

    var entropy: [tls.Server.Options.entropy_len]u8 = undefined;
    // Scrub the entropy no matter how we exit — it seeds the ServerHello random,
    // the ephemeral key share, and the ML-KEM encapsulation.
    defer std.crypto.secureZero(u8, &entropy);
    if (!secureRandomBytes(&entropy)) return .tls_handshake_failed;

    // A ChaCha DRBG seeded from the OS CSPRNG backs the RSA PSS salt + signing
    // blinding (`Options.random`). Seeding fail-closed keeps RSA signing off a
    // weak source; the DRBG itself never fails mid-signing, so PSS can never be
    // fed predictable/zero salt. Scrub the seed AND the DRBG state on exit.
    var csprng_seed: [std.Random.DefaultCsprng.secret_seed_length]u8 = undefined;
    defer std.crypto.secureZero(u8, &csprng_seed);
    if (!secureRandomBytes(&csprng_seed)) return .tls_handshake_failed;
    var csprng = std.Random.DefaultCsprng.init(csprng_seed);
    defer std.crypto.secureZero(u8, std.mem.asBytes(&csprng));

    const now = std.Io.Clock.now(.real, io());
    const server = tls.Server.init(session.stream.inputReader(), session.stream.outputWriter(), .{
        .cert_chain = config.cert_chain,
        .private_key = config.private_key,
        .alpn_protocols = config.alpn_protocols,
        .write_buffer = session.plaintext_out,
        .read_buffer = session.plaintext_in,
        .entropy = &entropy,
        .random = csprng.random(),
        .realtime_now = now,
    }) catch |err| return switch (err) {
        // A transport read/write that failed mid-handshake stashed the precise
        // reason out-of-band (deadline → timed_out, kill → other, reset, …);
        // prefer it so a slowloris handshake surfaces `timed_out`.
        error.ReadFailed => if (session.stream.read_reason != .ok) session.stream.read_reason else .tls_handshake_failed,
        error.WriteFailed => if (session.stream.write_reason != .ok) session.stream.write_reason else .tls_handshake_failed,
        else => mapTlsServerInitError(err),
    };

    session.role = .{ .server = server };
    session.handshake_complete = true;
    return .ok;
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

// The S5 TLS-server fixtures: a self-signed P-256 ECDSA leaf for `localhost`
// (SAN DNS:localhost, IP:127.0.0.1) + its SEC1 private key, plus a SECOND,
// UNRELATED EC key that does NOT match the cert (the mismatch negative). These
// are the exact bytes of `test/fixtures/tls/ec_cert.pem` / `ec_key.pem` /
// `ec_key_other.pem`, embedded so the config parser is proven with no file I/O.
const test_ec_cert_pem =
    \\-----BEGIN CERTIFICATE-----
    \\MIIBmjCCAT+gAwIBAgIUMMaoyKUPtk7DddXMceDO4Ct8JHkwCgYIKoZIzj0EAwIw
    \\FDESMBAGA1UEAwwJbG9jYWxob3N0MB4XDTI2MDcxODE5Mjc0MFoXDTM2MDcxNTE5
    \\Mjc0MFowFDESMBAGA1UEAwwJbG9jYWxob3N0MFkwEwYHKoZIzj0CAQYIKoZIzj0D
    \\AQcDQgAEB2lsyvra4RAWZq/DqY2o0mxFVhRTYqCNHQepl87hKcH+FvAKtYvMBaeT
    \\vEdS1EHOoOmcVGvIPFV3JIf4K4+gTqNvMG0wHQYDVR0OBBYEFLyBFnPNF3GlffBT
    \\AixjsBkC5VSvMB8GA1UdIwQYMBaAFLyBFnPNF3GlffBTAixjsBkC5VSvMA8GA1Ud
    \\EwEB/wQFMAMBAf8wGgYDVR0RBBMwEYIJbG9jYWxob3N0hwR/AAABMAoGCCqGSM49
    \\BAMCA0kAMEYCIQDQKSD7MMuxS+Vr1sRd0xlrZR8QSNSEne+zFc+MVdALoAIhAJQN
    \\kxKtmLXPi6qM6KTlgO9hDglv/Qhl4YFCte+fZJAM
    \\-----END CERTIFICATE-----
;
const test_ec_key_pem =
    \\-----BEGIN EC PRIVATE KEY-----
    \\MHcCAQEEILFOeSNPKzUGGtZB1xBhwiKdj5ofWZ8eqpouy+3I/h60oAoGCCqGSM49
    \\AwEHoUQDQgAEB2lsyvra4RAWZq/DqY2o0mxFVhRTYqCNHQepl87hKcH+FvAKtYvM
    \\BaeTvEdS1EHOoOmcVGvIPFV3JIf4K4+gTg==
    \\-----END EC PRIVATE KEY-----
;
const test_ec_key_other_pem =
    \\-----BEGIN EC PRIVATE KEY-----
    \\MHcCAQEEIP5hU4QR/m6RPjPegL1e87Te38LT+GSOvoPcwhhLD/DuoAoGCCqGSM49
    \\AwEHoUQDQgAEvgTzXp1tN6aYf29oz9lGCjsojHy5pBnWctWDyAPOvOTpuXDMTaZw
    \\rOgtpYZ3KbQJH9OlhFYdB/7C2V8vl2OCBQ==
    \\-----END EC PRIVATE KEY-----
;

test "socket_io: tlsServerConfigCreateAlloc parses a valid ECDSA cert+key+ALPN and frees leak-exact" {
    const outcome = tlsServerConfigCreateAlloc(testing.allocator, test_ec_cert_pem, test_ec_key_pem, "h2\nhttp/1.1");
    try testing.expectEqual(Reason.ok, outcome.reason);
    const config: *TlsServerConfig = @ptrCast(@alignCast(outcome.config.?));
    // One leaf certificate, indexed at 0, parseable.
    try testing.expectEqual(@as(usize, 1), config.cert_chain.len);
    _ = try config.cert_chain[0].parse();
    // The ALPN preference list decoded from the newline wire, in order.
    try testing.expectEqual(@as(usize, 2), config.alpn_protocols.len);
    try testing.expectEqualStrings("h2", config.alpn_protocols[0]);
    try testing.expectEqualStrings("http/1.1", config.alpn_protocols[1]);
    // The testing allocator asserts no leak across the scrub-and-free.
    tlsFreeServerConfig(@ptrCast(config));
}

test "socket_io: tlsServerConfigCreateAlloc accepts an empty ALPN list (no ALPN)" {
    const outcome = tlsServerConfigCreateAlloc(testing.allocator, test_ec_cert_pem, test_ec_key_pem, "");
    try testing.expectEqual(Reason.ok, outcome.reason);
    const config: *TlsServerConfig = @ptrCast(@alignCast(outcome.config.?));
    try testing.expectEqual(@as(usize, 0), config.alpn_protocols.len);
    tlsFreeServerConfig(@ptrCast(config));
}

test "socket_io: tlsServerConfigCreateAlloc rejects a malformed cert PEM with tls_config_invalid, no config, leak-exact" {
    const outcome = tlsServerConfigCreateAlloc(testing.allocator, "not a certificate", test_ec_key_pem, "");
    try testing.expectEqual(Reason.tls_config_invalid, outcome.reason);
    try testing.expectEqual(@as(?*anyopaque, null), outcome.config);
}

test "socket_io: tlsServerConfigCreateAlloc rejects a malformed private key with tls_config_invalid, leak-exact" {
    const outcome = tlsServerConfigCreateAlloc(testing.allocator, test_ec_cert_pem, "not a key", "");
    try testing.expectEqual(Reason.tls_config_invalid, outcome.reason);
    try testing.expectEqual(@as(?*anyopaque, null), outcome.config);
}

test "socket_io: tlsServerConfigCreateAlloc rejects a key that does not match the leaf cert with tls_config_invalid, leak-exact" {
    const outcome = tlsServerConfigCreateAlloc(testing.allocator, test_ec_cert_pem, test_ec_key_other_pem, "");
    try testing.expectEqual(Reason.tls_config_invalid, outcome.reason);
    try testing.expectEqual(@as(?*anyopaque, null), outcome.config);
}

test "socket_io/tls: SERVER handshake completes against an in-process insecure client over a socketpair, app data both ways (S5)" {
    const pair = try testSocketpairNonblocking();

    const config_outcome = tlsServerConfigCreateAlloc(testing.allocator, test_ec_cert_pem, test_ec_key_pem, "");
    try testing.expectEqual(Reason.ok, config_outcome.reason);
    const config = config_outcome.config.?;
    defer tlsFreeServerConfig(config);

    const server_session = try TlsSession.create(testing.allocator, pair.a, 5000, null);
    defer server_session.deinit();
    defer closeFd(pair.a);
    const client_session = try TlsSession.create(testing.allocator, pair.b, 5000, null);
    defer client_session.deinit();
    defer closeFd(pair.b);

    // The handshake is a synchronous request/response, so drive the two ends on
    // two threads: the insecure client (proven S4 path) drives one fd, the
    // server the other. Both must return `.ok`.
    const ServerCtx = struct {
        session: *TlsSession,
        config: *anyopaque,
        reason: Reason = .other,
        fn run(ctx: *@This()) void {
            ctx.reason = tlsServerHandshake(ctx.session, ctx.config, 5000, null);
        }
    };
    const ClientCtx = struct {
        session: *TlsSession,
        reason: Reason = .other,
        fn run(ctx: *@This()) void {
            ctx.reason = tlsHandshake(ctx.session, "localhost", 5000, null, true);
        }
    };
    var server_ctx = ServerCtx{ .session = server_session, .config = config };
    var client_ctx = ClientCtx{ .session = client_session };
    const server_thread = try std.Thread.spawn(.{}, ServerCtx.run, .{&server_ctx});
    const client_thread = try std.Thread.spawn(.{}, ClientCtx.run, .{&client_ctx});
    server_thread.join();
    client_thread.join();

    try testing.expectEqual(Reason.ok, client_ctx.reason);
    try testing.expectEqual(Reason.ok, server_ctx.reason);
    try testing.expect(server_session.role == .server);
    try testing.expect(client_session.role == .client);

    // App data both ways over the established sessions (single-threaded now — the
    // socket buffers hold each record until the peer reads it): client -> server,
    // server echoes -> client, byte-exact through the record layer.
    const message = "hello over tls 1.3 server";
    const send_out = tlsSend(client_session, message, 5000, null);
    try testing.expectEqual(Reason.ok, send_out.reason);

    const server_recv = try tlsRecv(server_session, testing.allocator, message.len, tls_session_buffer_len, 5000, null);
    defer testing.allocator.free(server_recv.buffer);
    try testing.expectEqual(recv_status_chunk, server_recv.status);
    try testing.expectEqualStrings(message, server_recv.buffer[0..server_recv.bytes_filled]);

    const echo_out = tlsSend(server_session, server_recv.buffer[0..server_recv.bytes_filled], 5000, null);
    try testing.expectEqual(Reason.ok, echo_out.reason);

    const client_recv = try tlsRecv(client_session, testing.allocator, message.len, tls_session_buffer_len, 5000, null);
    defer testing.allocator.free(client_recv.buffer);
    try testing.expectEqual(recv_status_chunk, client_recv.status);
    try testing.expectEqualStrings(message, client_recv.buffer[0..client_recv.bytes_filled]);
}

test "socket_io: a fresh TlsSession is .unestablished and frees leak-exact without a handshake" {
    const pair = try testSocketpairNonblocking();
    defer closeFd(pair.a);
    defer closeFd(pair.b);
    const session = try TlsSession.create(testing.allocator, pair.a, 100, null);
    // No handshake ran: the role is the zero-payload `.unestablished` arm, so
    // `zeroizeSecrets`/`deinit` are safe and leak-exact.
    try testing.expect(session.role == .unestablished);
    try testing.expect(!session.handshake_complete);
    session.zeroizeSecrets(); // proves scrubbing an unestablished union is safe
    session.deinit();
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
    // Phase S4 (TLS): APPEND-ONLY additions — pinned so a renumber breaks the
    // build here and forces `lib/socket/error.zap`'s `reason_from_code` to move
    // in lockstep (the atoms `:tls_cert_invalid` / `:tls_handshake_failed` land
    // with the Zap surface in Job 4).
    try testing.expectEqual(@as(i32, 14), @intFromEnum(Reason.tls_cert_invalid));
    try testing.expectEqual(@as(i32, 15), @intFromEnum(Reason.tls_handshake_failed));
    // Phase S5 (TLS server): APPEND-ONLY additions — same lockstep contract.
    // A renumber breaks the build here and forces `lib/socket/error.zap`'s
    // `reason_from_code` to move in lockstep (`:tls_no_matching_cert` /
    // `:tls_config_invalid`).
    try testing.expectEqual(@as(i32, 16), @intFromEnum(Reason.tls_no_matching_cert));
    try testing.expectEqual(@as(i32, 17), @intFromEnum(Reason.tls_config_invalid));
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

// ---------------------------------------------------------------------------
// TLS foundation tests (Phase S4 Job 1) — HERMETIC (no network). The transport
// is an in-process `socketpair(2)`: one end drives the `SocketStream` adapter,
// the peer end is driven with raw `send`/`recv` so a full round-trip, a kill
// mid-read, a deadline expiry, and the flush half of the double-flush are all
// proven WITHOUT a live server or the record layer.
// ---------------------------------------------------------------------------

/// A connected, bidirectional, NON-BLOCKING `socketpair(2)` (AF_UNIX / STREAM):
/// `fds[0]` for the adapter under test, `fds[1]` the peer. Both ends are set
/// `O_NONBLOCK` to match the always-non-blocking discipline the adapter assumes.
fn testSocketpairNonblocking() !struct { a: Fd, b: Fd } {
    var fds: [2]std.posix.fd_t = undefined;
    const rc = std.posix.system.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    if (std.posix.errno(rc) != .SUCCESS) return error.SkipZigTest;
    if (!setNonBlocking(fds[0]) or !setNonBlocking(fds[1])) {
        _ = std.posix.system.close(fds[0]);
        _ = std.posix.system.close(fds[1]);
        return error.SkipZigTest;
    }
    return .{ .a = fdToBits(fds[0]), .b = fdToBits(fds[1]) };
}

test "socket_io/tls: SocketStream reader fills from the raw fd and writer drains to it (round-trip)" {
    if (builtin.os.tag == .wasi or builtin.os.tag == .windows) return error.SkipZigTest;
    const pair = try testSocketpairNonblocking();
    defer closeFd(pair.a);
    defer closeFd(pair.b);

    var read_buffer: [tls_min_buffer_len]u8 = undefined;
    var write_buffer: [tls_min_buffer_len]u8 = undefined;
    var stream = SocketStream.init(pair.a, 5000, null, &read_buffer, &write_buffer);

    // Peer writes bytes → the adapter's reader must surface them via `peek`/`take`.
    const payload = "the quick brown fox\x00\xff\x01jumps";
    const peer_handle = fdFromBits(pair.b);
    const sent = std.posix.system.send(peer_handle, payload.ptr, payload.len, 0);
    try testing.expectEqual(@as(usize, payload.len), @as(usize, @intCast(sent)));

    const got = try stream.inputReader().take(payload.len);
    try testing.expectEqualStrings(payload, got);

    // The adapter's writer must deliver buffered bytes to the peer on flush.
    const reply = "adapter-writer-round-trip";
    var w = stream.outputWriter();
    try w.writeAll(reply);
    try w.flush();

    var recv_buffer: [64]u8 = undefined;
    // The peer is non-blocking; poll until the bytes arrive (bounded).
    var received: usize = 0;
    var spins: usize = 0;
    while (received < reply.len and spins < 1000) : (spins += 1) {
        const rc = std.posix.system.recv(peer_handle, recv_buffer[received..].ptr, recv_buffer.len - received, 0);
        switch (std.posix.errno(rc)) {
            .SUCCESS => received += @intCast(rc),
            .AGAIN, .INTR => {
                var ts: std.c.timespec = .{ .sec = 0, .nsec = 1 * std.time.ns_per_ms };
                _ = std.c.nanosleep(&ts, null);
            },
            else => return error.TestUnexpectedRecvError,
        }
    }
    try testing.expectEqualStrings(reply, recv_buffer[0..received]);
}

test "socket_io/tls: SocketStream reader deadline expiry returns ReadFailed with a typed timed_out reason (slowloris-handshake bound)" {
    if (builtin.os.tag == .wasi or builtin.os.tag == .windows) return error.SkipZigTest;
    const pair = try testSocketpairNonblocking();
    defer closeFd(pair.a);
    defer closeFd(pair.b);

    var read_buffer: [tls_min_buffer_len]u8 = undefined;
    var write_buffer: [tls_min_buffer_len]u8 = undefined;
    // A short (100 ms) absolute deadline; the peer never writes, so the reader
    // must hit the deadline and fail — proving a slowloris handshake is bounded.
    var stream = SocketStream.init(pair.a, 100, null, &read_buffer, &write_buffer);

    const before = monotonicMillis();
    try testing.expectError(error.ReadFailed, stream.inputReader().takeByte());
    const elapsed = monotonicMillis() - before;

    // The failure is a DEADLINE, classified out-of-band as `timed_out`.
    try testing.expectEqual(Reason.timed_out, stream.read_reason);
    // And it fired near the deadline, never blocking indefinitely.
    try testing.expect(elapsed >= 90);
    try testing.expect(elapsed < 5000);
}

test "socket_io/tls: a kill mid-read makes the SocketStream reader fail promptly with the kill reason stashed" {
    if (builtin.os.tag == .wasi or builtin.os.tag == .windows) return error.SkipZigTest;
    const pair = try testSocketpairNonblocking();
    defer closeFd(pair.a);
    defer closeFd(pair.b);

    var read_buffer: [tls_min_buffer_len]u8 = undefined;
    var write_buffer: [tls_min_buffer_len]u8 = undefined;
    // No deadline (0): only a kill can end the wait — proving kill-responsiveness.
    var kill_flag = std.atomic.Value(bool).init(false);
    var stream = SocketStream.init(pair.a, 0, &kill_flag, &read_buffer, &write_buffer);

    // A background thread flips the kill shortly after the read parks (the peer
    // never writes, so the reader is blocked polling).
    const Killer = struct {
        flag: *std.atomic.Value(bool),
        fn run(self: @This()) void {
            var ts: std.c.timespec = .{ .sec = 0, .nsec = 20 * std.time.ns_per_ms };
            _ = std.c.nanosleep(&ts, null);
            self.flag.store(true, .release);
        }
    };
    var thread = try std.Thread.spawn(.{}, Killer.run, .{Killer{ .flag = &kill_flag }});
    defer thread.join();

    try testing.expectError(error.ReadFailed, stream.inputReader().takeByte());
    // A kill classifies out-of-band as `other` (the connect/recv kill posture).
    try testing.expectEqual(Reason.other, stream.read_reason);
}

test "socket_io/tls: SocketStream writer flush is the adapter half of the double-flush — buffered ciphertext reaches the peer" {
    if (builtin.os.tag == .wasi or builtin.os.tag == .windows) return error.SkipZigTest;
    const pair = try testSocketpairNonblocking();
    defer closeFd(pair.a);
    defer closeFd(pair.b);

    var read_buffer: [tls_min_buffer_len]u8 = undefined;
    var write_buffer: [tls_min_buffer_len]u8 = undefined;
    var stream = SocketStream.init(pair.a, 5000, null, &read_buffer, &write_buffer);
    var w = stream.outputWriter();

    // Simulate `Client.flush` staging ciphertext into the output buffer WITHOUT
    // draining it (the gotcha): write into the buffer via the greedy-slice +
    // advance path the client uses, and confirm the peer sees NOTHING yet.
    const record = "encrypted-record-bytes";
    const slice = try w.writableSliceGreedy(record.len);
    @memcpy(slice[0..record.len], record);
    w.advance(record.len);

    var probe: [64]u8 = undefined;
    const peer_handle = fdFromBits(pair.b);
    const early = std.posix.system.recv(peer_handle, &probe, probe.len, 0);
    try testing.expectEqual(std.posix.E.AGAIN, std.posix.errno(early)); // nothing drained yet

    // The adapter's flush is the second half of the double-flush: it PUSHES the
    // staged ciphertext to the socket.
    try w.flush();
    try testing.expectEqual(@as(usize, 0), w.end); // buffer reset

    var received: usize = 0;
    var spins: usize = 0;
    while (received < record.len and spins < 1000) : (spins += 1) {
        const rc = std.posix.system.recv(peer_handle, probe[received..].ptr, probe.len - received, 0);
        switch (std.posix.errno(rc)) {
            .SUCCESS => received += @intCast(rc),
            .AGAIN, .INTR => {
                var ts: std.c.timespec = .{ .sec = 0, .nsec = 1 * std.time.ns_per_ms };
                _ = std.c.nanosleep(&ts, null);
            },
            else => return error.TestUnexpectedRecvError,
        }
    }
    try testing.expectEqualStrings(record, probe[0..received]);
}

test "socket_io/tls: mapTlsInitError maps every certificate failure to tls_cert_invalid and every other handshake failure to tls_handshake_failed" {
    // CERTIFICATE-verification failures — the security-critical class — MUST be
    // distinct and typed so a bad-cert connect is never a generic error.
    const cert_errors = [_]tls.Client.InitError{
        error.CertificateFieldHasInvalidLength,
        error.CertificateHostMismatch,
        error.CertificatePublicKeyInvalid,
        error.CertificateExpired,
        error.CertificateFieldHasWrongDataType,
        error.CertificateIssuerMismatch,
        error.CertificateNotYetValid,
        error.CertificateSignatureAlgorithmMismatch,
        error.CertificateSignatureAlgorithmUnsupported,
        error.CertificateSignatureInvalid,
        error.CertificateSignatureInvalidLength,
        error.CertificateSignatureNamedCurveUnsupported,
        error.CertificateSignatureUnsupportedBitCount,
        error.TlsCertificateNotVerified,
        error.UnsupportedCertificateVersion,
        error.CertificateTimeInvalid,
        error.CertificateHasUnrecognizedObjectId,
        error.CertificateHasInvalidBitString,
    };
    for (cert_errors) |err| {
        try testing.expectEqual(Reason.tls_cert_invalid, mapTlsInitError(err));
    }

    // Every NON-certificate handshake failure → tls_handshake_failed.
    const handshake_errors = [_]tls.Client.InitError{
        error.InsufficientEntropy,
        error.TlsAlert,
        error.TlsUnexpectedMessage,
        error.TlsIllegalParameter,
        error.TlsDecryptFailure,
        error.TlsRecordOverflow,
        error.TlsBadRecordMac,
        error.TlsConnectionTruncated,
        error.TlsDecodeError,
        error.TlsBadSignatureScheme,
        error.SignatureVerificationFailed,
        error.WriteFailed,
        error.ReadFailed,
    };
    for (handshake_errors) |err| {
        try testing.expectEqual(Reason.tls_handshake_failed, mapTlsInitError(err));
    }
}

test "socket_io/tls: the lazy OS trust store rescans a NON-EMPTY certificate bundle on this host" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest; // wasi has no OS trust store
    switch (trustStore()) {
        .ready => |trust| {
            // The host OS trust store must yield real CA certificates (macOS
            // Security framework / Linux `/etc/ssl` / …) — a non-empty bundle
            // is the "157 macOS certs" path, the precondition for verification.
            try testing.expect(trust.bundle.bytes.items.len > 0);
            try testing.expect(trust.bundle.map.count() > 0);
        },
        .failed => |reason| {
            // A host with no trust store at all (unusual in CI) is not a Job-1
            // failure, but any OTHER failure reason is a real problem.
            try testing.expect(reason == .other);
            return error.SkipZigTest;
        },
    }
}

// ---------------------------------------------------------------------------
// TLS client driver tests (Phase S4 Jobs 2+3). A full handshake that SUCCEEDS
// needs a peer that also completes the key exchange + Finished, which requires
// the S5 server (`std.crypto.tls.Server` does not exist in the fork yet), so
// the handshake-SUCCESS / byte-exact decrypt→arena / double-flush-to-wire
// proofs DEFER to the S5 hermetic client↔server suite. What IS provable
// hermetically here (no network — a `socketpair(2)` + canned server bytes): the
// CSPRNG entropy source, the handshake DoS bound + kill-responsiveness against
// a silent peer (the security-critical §8 properties), the no-leak/no-key-
// residue teardown, the trust-store wiring, the cert-error classification
// (Job-1), and — crucially — the OVER-THE-WIRE proof that a bad (wrong-host)
// certificate is REJECTED: in TLS 1.2 the server Certificate message is
// cleartext (sent before the key exchange), so a canned ServerHello+Certificate
// flight drives `Client.init` straight into `verifyHostName`, which fails
// CLOSED with `error.CertificateHostMismatch` → `tls_cert_invalid` (never
// success, never a generic `tls_handshake_failed`).
// ---------------------------------------------------------------------------

test "socket_io/tls: secureRandomBytes fills from a CSPRNG (non-zero, non-repeating) — the mandatory handshake entropy" {
    if (builtin.os.tag == .wasi or builtin.os.tag == .windows) return error.SkipZigTest;
    var a: [tls.Client.Options.entropy_len]u8 = undefined;
    var b: [tls.Client.Options.entropy_len]u8 = undefined;
    @memset(&a, 0);
    @memset(&b, 0);
    try testing.expect(secureRandomBytes(&a));
    try testing.expect(secureRandomBytes(&b));
    // A CSPRNG never returns all-zero over 240 bytes (probability 2^-1920), and
    // two draws never collide — a predictable/repeating source would be a
    // critical TLS flaw (the ClientHello random + key share seed).
    var a_all_zero = true;
    for (a) |byte| {
        if (byte != 0) a_all_zero = false;
    }
    try testing.expect(!a_all_zero);
    try testing.expect(!std.mem.eql(u8, &a, &b));
}

test "socket_io/tls: tlsHandshake against a SILENT peer is DoS-bounded — times out near the deadline, never the ~127s default, session freed leak-exactly" {
    if (builtin.os.tag == .wasi or builtin.os.tag == .windows) return error.SkipZigTest;
    // A trust store is a precondition (the handshake fetches it first); a host
    // with none cannot exercise the verification path — skip rather than false-fail.
    switch (trustStore()) {
        .ready => {},
        .failed => return error.SkipZigTest,
    }
    const pair = try testSocketpairNonblocking();
    defer closeFd(pair.a);
    defer closeFd(pair.b); // the silent peer end — never writes a ServerHello

    // The testing allocator makes the no-leak / no-key-residue claim enforceable:
    // a leaked session box or buffer fails the test at teardown.
    const session = try TlsSession.create(testing.allocator, pair.a, 200, null);
    defer session.deinit();

    const before = monotonicMillis();
    const reason = tlsHandshake(@ptrCast(session), "example.com", 200, null, false);
    const elapsed = monotonicMillis() - before;

    // Bounded: the silent peer stalls the ServerHello read, so the single
    // absolute deadline fires — a slowloris handshake cannot pin the thread.
    try testing.expect(reason != .ok);
    try testing.expectEqual(Reason.timed_out, reason);
    try testing.expect(elapsed >= 150);
    try testing.expect(elapsed < 5000);
}

test "socket_io/tls: tlsHandshake yields PROMPTLY to a kill mid-handshake and frees the session (no leak, no key residue)" {
    if (builtin.os.tag == .wasi or builtin.os.tag == .windows) return error.SkipZigTest;
    switch (trustStore()) {
        .ready => {},
        .failed => return error.SkipZigTest,
    }
    const pair = try testSocketpairNonblocking();
    defer closeFd(pair.a);
    defer closeFd(pair.b);

    var kill_flag = std.atomic.Value(bool).init(false);
    // No deadline (0): ONLY the kill can end the ServerHello wait — proving the
    // handshake is kill-responsive (a process can be torn down mid-handshake).
    const session = try TlsSession.create(testing.allocator, pair.a, 0, &kill_flag);
    defer session.deinit();

    const Killer = struct {
        flag: *std.atomic.Value(bool),
        fn run(self: @This()) void {
            var ts: std.c.timespec = .{ .sec = 0, .nsec = 30 * std.time.ns_per_ms };
            _ = std.c.nanosleep(&ts, null);
            self.flag.store(true, .release);
        }
    };
    var thread = try std.Thread.spawn(.{}, Killer.run, .{Killer{ .flag = &kill_flag }});
    defer thread.join();

    const before = monotonicMillis();
    const reason = tlsHandshake(@ptrCast(session), "example.com", 0, &kill_flag, false);
    const elapsed = monotonicMillis() - before;

    // A kill classifies as `other` (the connect/recv kill posture) and returns
    // promptly (well under a second — nowhere near the OS default).
    try testing.expect(reason != .ok);
    try testing.expect(elapsed < 5000);
    // `session.deinit` (deferred) scrubs + frees; the testing allocator asserts
    // no leak. The session was never handshake-complete, so no `close_notify`.
    try testing.expect(!session.handshake_complete);
}

test "socket_io/tls: tlsFreeSession scrubs + frees a failed-handshake session on the teardown path (no leak)" {
    if (builtin.os.tag == .wasi or builtin.os.tag == .windows) return error.SkipZigTest;
    switch (trustStore()) {
        .ready => {},
        .failed => return error.SkipZigTest,
    }
    const pair = try testSocketpairNonblocking();
    defer closeFd(pair.a);
    defer closeFd(pair.b);

    // Mirror the bridge's failure path: create → handshake (times out) → the
    // trampoline frees via `tlsFreeSession`. The testing allocator proves the
    // whole box + four buffers are reclaimed exactly once, no residue leaked.
    const session = try TlsSession.create(testing.allocator, pair.a, 150, null);
    const reason = tlsHandshake(@ptrCast(session), "example.com", 150, null, false);
    try testing.expect(reason != .ok);
    tlsFreeSession(@ptrCast(session)); // scrub + free (no close_notify — not complete)
    // No `defer deinit` — `tlsFreeSession` already freed it; a double free would
    // trip the testing allocator.
}

// ---------------------------------------------------------------------------
// TLS bad-certificate REJECTION proof (Phase S4) — the over-the-wire evidence
// that mandatory verification actually FAILS CLOSED, not merely that it is
// wired on by inspection. In TLS 1.2 the server's `Certificate` message is
// CLEARTEXT and arrives right after `ServerHello`, BEFORE the key exchange and
// the Finished MAC — so a canned `ServerHello`(TLS 1.2)+`Certificate` byte
// flight carrying a certificate whose SAN/CN does not match the requested host
// drives `std.crypto.tls.Client.init` straight into `Certificate.Parsed.
// verifyHostName`, which returns `error.CertificateHostMismatch` WITHOUT any
// matching server crypto. Wrong-hostname is the cheapest deterministic
// rejection: `verifyHostName` runs on the first certificate BEFORE the trust
// bundle / date checks, so it fails identically regardless of the OS trust
// store contents or the wall clock — fully hermetic.
// ---------------------------------------------------------------------------

/// A real, self-signed X.509 certificate (DER, secp256r1) whose ONLY names —
/// both the Subject CN and the SAN dNSName — are `s4-tls-fixture.example`. It
/// parses cleanly through the fork's `Certificate.parse`, so a handshake that
/// presents it reaches `verifyHostName`; presenting it for ANY other host is a
/// deterministic `CertificateHostMismatch`. (Generated once with
/// `openssl req -x509 -newkey ec`; dates are UTCTime, valid until 2048, though
/// the host check fails first regardless of validity.)
const s4_bad_cert_der = [_]u8{
    0x30, 0x82, 0x01, 0xb9, 0x30, 0x82, 0x01, 0x60, 0xa0, 0x03, 0x02, 0x01,
    0x02, 0x02, 0x14, 0x6e, 0x2b, 0x9f, 0xfb, 0x4e, 0x68, 0x2a, 0x4d, 0x80,
    0xee, 0x03, 0x8d, 0xa5, 0x49, 0x26, 0x84, 0x1c, 0x45, 0xfd, 0xe6, 0x30,
    0x0a, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02, 0x30,
    0x21, 0x31, 0x1f, 0x30, 0x1d, 0x06, 0x03, 0x55, 0x04, 0x03, 0x0c, 0x16,
    0x73, 0x34, 0x2d, 0x74, 0x6c, 0x73, 0x2d, 0x66, 0x69, 0x78, 0x74, 0x75,
    0x72, 0x65, 0x2e, 0x65, 0x78, 0x61, 0x6d, 0x70, 0x6c, 0x65, 0x30, 0x1e,
    0x17, 0x0d, 0x32, 0x36, 0x30, 0x37, 0x31, 0x38, 0x31, 0x30, 0x33, 0x33,
    0x33, 0x33, 0x5a, 0x17, 0x0d, 0x34, 0x38, 0x30, 0x36, 0x31, 0x32, 0x31,
    0x30, 0x33, 0x33, 0x33, 0x33, 0x5a, 0x30, 0x21, 0x31, 0x1f, 0x30, 0x1d,
    0x06, 0x03, 0x55, 0x04, 0x03, 0x0c, 0x16, 0x73, 0x34, 0x2d, 0x74, 0x6c,
    0x73, 0x2d, 0x66, 0x69, 0x78, 0x74, 0x75, 0x72, 0x65, 0x2e, 0x65, 0x78,
    0x61, 0x6d, 0x70, 0x6c, 0x65, 0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a,
    0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce,
    0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00, 0x04, 0xf2, 0x57, 0xdf, 0x98,
    0x10, 0xa1, 0x1e, 0xf8, 0x2d, 0x6c, 0xa1, 0xd6, 0xf0, 0xe9, 0x8b, 0xbd,
    0x82, 0x72, 0x75, 0x14, 0xec, 0xcd, 0x4c, 0x6f, 0x74, 0x88, 0x0e, 0x83,
    0x74, 0x98, 0xb9, 0x71, 0x6e, 0xdb, 0x9c, 0xb7, 0xd9, 0x32, 0x12, 0xd3,
    0xda, 0x3e, 0x6f, 0x80, 0x80, 0x46, 0xc7, 0xbe, 0xe0, 0x1c, 0x35, 0x3f,
    0x4d, 0xcc, 0xb2, 0xa0, 0x31, 0x24, 0x83, 0xf7, 0xa8, 0x3d, 0x11, 0x09,
    0xa3, 0x76, 0x30, 0x74, 0x30, 0x1d, 0x06, 0x03, 0x55, 0x1d, 0x0e, 0x04,
    0x16, 0x04, 0x14, 0xa7, 0x81, 0xe1, 0x4f, 0x65, 0xa8, 0xc3, 0xa5, 0xf8,
    0x66, 0x0f, 0x6d, 0xb2, 0x0c, 0x6b, 0xe6, 0x05, 0x7a, 0x64, 0x67, 0x30,
    0x1f, 0x06, 0x03, 0x55, 0x1d, 0x23, 0x04, 0x18, 0x30, 0x16, 0x80, 0x14,
    0xa7, 0x81, 0xe1, 0x4f, 0x65, 0xa8, 0xc3, 0xa5, 0xf8, 0x66, 0x0f, 0x6d,
    0xb2, 0x0c, 0x6b, 0xe6, 0x05, 0x7a, 0x64, 0x67, 0x30, 0x0f, 0x06, 0x03,
    0x55, 0x1d, 0x13, 0x01, 0x01, 0xff, 0x04, 0x05, 0x30, 0x03, 0x01, 0x01,
    0xff, 0x30, 0x21, 0x06, 0x03, 0x55, 0x1d, 0x11, 0x04, 0x1a, 0x30, 0x18,
    0x82, 0x16, 0x73, 0x34, 0x2d, 0x74, 0x6c, 0x73, 0x2d, 0x66, 0x69, 0x78,
    0x74, 0x75, 0x72, 0x65, 0x2e, 0x65, 0x78, 0x61, 0x6d, 0x70, 0x6c, 0x65,
    0x30, 0x0a, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02,
    0x03, 0x47, 0x00, 0x30, 0x44, 0x02, 0x20, 0x7a, 0x22, 0xf4, 0x59, 0x34,
    0x5b, 0xbb, 0xe4, 0x0f, 0x18, 0x8b, 0x05, 0x9c, 0x3d, 0x03, 0xba, 0xfb,
    0x3b, 0x60, 0xb4, 0x72, 0x33, 0x73, 0x0e, 0x51, 0xd5, 0x6c, 0xd4, 0x78,
    0x0f, 0x94, 0x36, 0x02, 0x20, 0x2f, 0xfe, 0x80, 0x52, 0xa7, 0x96, 0x80,
    0xb3, 0xd1, 0x9e, 0xf1, 0x0e, 0x75, 0x01, 0xa1, 0x0f, 0xf2, 0x17, 0xf6,
    0x17, 0x85, 0x57, 0xe8, 0xd2, 0xc2, 0x7b, 0x14, 0x55, 0x9b, 0x17, 0xec,
    0xfe,
};

/// The host we ask for — deliberately NOT a name in `s4_bad_cert_der`, so the
/// certificate is a wrong-hostname mismatch. `.invalid` is the RFC 6761
/// reserved TLD (never resolvable), underscoring that this is purely a
/// verification fixture and never a live endpoint.
const s4_mismatch_host = "definitely-not-the-cert-host.invalid";

/// Big-endian two-byte length (a TLS record length / handshake sub-length).
fn tlsTestBe16(comptime value: u16) [2]u8 {
    return .{ @truncate(value >> 8), @truncate(value) };
}

/// Big-endian three-byte length (a TLS handshake-message / cert-list length).
fn tlsTestBe24(comptime value: u24) [3]u8 {
    return .{ @truncate(value >> 16), @truncate(value >> 8), @truncate(value) };
}

/// The canned server-side TLS 1.2 handshake flight the bad-cert proof feeds to
/// `Client.init`: a valid `ServerHello` selecting TLS 1.2 with an ECDHE_RSA
/// cipher suite, immediately followed by a `Certificate` message carrying the
/// single wrong-hostname certificate above. All lengths are derived from the
/// payloads (never hand-patched), so the flight stays well-formed. This is
/// enough to reach `verifyHostName`; the handshake fails there, before any key
/// exchange or Finished MAC — so no matching server crypto is needed.
const s4_bad_cert_server_flight = build: {
    const server_random = [_]u8{0xa5} ** 32; // not the HelloRetryRequest / DOWNGRD sentinel
    const server_hello_body =
        [_]u8{ 0x03, 0x03 } ++ // legacy_version = tls_1_2
        server_random ++
        [_]u8{0x00} ++ // legacy_session_id echo (length 0)
        [_]u8{ 0xc0, 0x2f } ++ // ECDHE_RSA_WITH_AES_128_GCM_SHA256 (0xC02F)
        [_]u8{0x00}; // legacy_compression_method = null (no extensions → TLS 1.2)
    const server_hello =
        [_]u8{@intFromEnum(tls.HandshakeType.server_hello)} ++
        tlsTestBe24(server_hello_body.len) ++
        server_hello_body;
    const server_hello_record =
        [_]u8{ @intFromEnum(tls.ContentType.handshake), 0x03, 0x03 } ++
        tlsTestBe16(server_hello.len) ++
        server_hello;

    const cert_entry = tlsTestBe24(s4_bad_cert_der.len) ++ s4_bad_cert_der;
    const cert_list = tlsTestBe24(cert_entry.len) ++ cert_entry;
    const certificate =
        [_]u8{@intFromEnum(tls.HandshakeType.certificate)} ++
        tlsTestBe24(cert_list.len) ++
        cert_list;
    const certificate_record =
        [_]u8{ @intFromEnum(tls.ContentType.handshake), 0x03, 0x03 } ++
        tlsTestBe16(certificate.len) ++
        certificate;

    break :build server_hello_record ++ certificate_record;
};

/// Push every byte of `bytes` out the peer fd `peer` (non-blocking) so it is
/// readable on the adapter end BEFORE the handshake starts. Bounded-spin on
/// `EAGAIN` (the flight is < 1 KiB, well within the socketpair buffer).
fn tlsTestWriteFlightToPeer(peer: Fd, bytes: []const u8) !void {
    const peer_handle = fdFromBits(peer);
    var sent: usize = 0;
    var spins: usize = 0;
    while (sent < bytes.len and spins < 100_000) : (spins += 1) {
        const rc = std.posix.system.send(peer_handle, bytes[sent..].ptr, bytes.len - sent, 0);
        switch (std.posix.errno(rc)) {
            .SUCCESS => sent += @intCast(rc),
            .AGAIN, .INTR => {
                var ts: std.c.timespec = .{ .sec = 0, .nsec = 1 * std.time.ns_per_ms };
                _ = std.c.nanosleep(&ts, null);
            },
            else => return error.TestUnexpectedSendError,
        }
    }
    if (sent < bytes.len) return error.TestPeerWriteIncomplete;
}

test "socket_io/tls: an over-the-wire wrong-hostname certificate is REJECTED — Client.init fails CLOSED with CertificateHostMismatch, mapped to tls_cert_invalid" {
    if (builtin.os.tag == .wasi or builtin.os.tag == .windows) return error.SkipZigTest;
    // The OS trust bundle is a precondition for wiring `Client.init`'s ca option
    // the way production does (a host with none cannot exercise the path); the
    // host check itself fails BEFORE the bundle is consulted, so its contents do
    // not affect the outcome — only that it is present.
    const trust = switch (trustStore()) {
        .ready => |bundle| bundle,
        .failed => return error.SkipZigTest,
    };

    // ---- Path A: drive `Client.init` DIRECTLY over the SocketStream adapter ----
    // (the real transport the production handshake uses), capturing the EXACT
    // error so we can prove it is a certificate error AND that the production
    // mapping classifies it as tls_cert_invalid.
    {
        const pair = try testSocketpairNonblocking();
        defer closeFd(pair.a);
        defer closeFd(pair.b);
        // The peer speaks the canned bad-cert flight; the adapter on `a` reads it
        // as the "server". Pre-loaded before the handshake so it is waiting when
        // `Client.init` reads the ServerHello.
        try tlsTestWriteFlightToPeer(pair.b, &s4_bad_cert_server_flight);

        var encrypted_in: [tls_min_buffer_len]u8 = undefined;
        var encrypted_out: [tls_min_buffer_len]u8 = undefined;
        var stream = SocketStream.init(pair.a, 5000, null, &encrypted_in, &encrypted_out);

        var plaintext_in: [tls_min_buffer_len]u8 = undefined;
        var plaintext_out: [tls_min_buffer_len]u8 = undefined;
        var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
        defer std.crypto.secureZero(u8, &entropy);
        try testing.expect(secureRandomBytes(&entropy));
        const now = std.Io.Clock.now(.real, trust.io);

        // SAME options as the production `tlsHandshake`: explicit host + the OS
        // trust bundle, NO `no_verification` — verification is mandatory.
        const result = tls.Client.init(stream.inputReader(), stream.outputWriter(), .{
            .host = .{ .explicit = s4_mismatch_host },
            .ca = .{ .bundle = .{
                .gpa = trust.gpa,
                .io = trust.io,
                .lock = trust.lock,
                .bundle = trust.bundle,
            } },
            .write_buffer = &plaintext_out,
            .read_buffer = &plaintext_in,
            .entropy = &entropy,
            .realtime_now = now,
        });

        if (result) |_| {
            // A successful handshake against a wrong-hostname cert would be a
            // catastrophic verification BYPASS — never acceptable.
            return error.TestCertificateRejectionBypassed;
        } else |init_error| {
            // The over-the-wire proof: the wrong-hostname cert fails CLOSED with a
            // typed CERTIFICATE error at `verifyHostName` — not success, not a
            // generic transport/handshake error.
            try testing.expectEqual(error.CertificateHostMismatch, init_error);
            // …and the production classifier maps that Certificate* error to the
            // DISTINCT `tls_cert_invalid` reason (never `tls_handshake_failed`),
            // so a caller can always tell "the peer is not trusted" apart from a
            // generic handshake failure.
            try testing.expectEqual(Reason.tls_cert_invalid, mapTlsInitError(init_error));
        }
    }

    // ---- Path B: the full production entry point end-to-end ----
    // The SAME canned bad-cert flight through `tlsHandshake` (create → handshake
    // → mapped Reason) must surface `tls_cert_invalid` over the wire, proving the
    // whole production path — not just `Client.init` in isolation — rejects it.
    {
        const pair = try testSocketpairNonblocking();
        defer closeFd(pair.a);
        defer closeFd(pair.b);
        try tlsTestWriteFlightToPeer(pair.b, &s4_bad_cert_server_flight);

        const session = try TlsSession.create(testing.allocator, pair.a, 5000, null);
        defer session.deinit(); // testing allocator asserts no leak / no key residue

        const reason = tlsHandshake(@ptrCast(session), s4_mismatch_host, 5000, null, false);
        try testing.expectEqual(Reason.tls_cert_invalid, reason);
        // A rejected handshake never completes — no session keys, no close_notify.
        try testing.expect(!session.handshake_complete);
    }
}

test "socket_io/tls: the INSECURE handshake genuinely SKIPS verification — the same wrong-hostname flight the verified path rejects as tls_cert_invalid is NOT a cert rejection when insecure (the loud opt-in is real)" {
    if (builtin.os.tag == .wasi or builtin.os.tag == .windows) return error.SkipZigTest;
    // The insecure branch consults NO trust store, but the verified control leg
    // below does — require the bundle so the two legs differ ONLY by the
    // verification toggle, isolating exactly what `insecure` changes.
    switch (trustStore()) {
        .ready => {},
        .failed => return error.SkipZigTest,
    }

    // ---- Control leg: VERIFIED (insecure = false) ----
    // The canned wrong-hostname flight fails CLOSED at certificate verification →
    // `tls_cert_invalid` (the committed mandatory-verification proof), fast.
    {
        const pair = try testSocketpairNonblocking();
        defer closeFd(pair.a);
        defer closeFd(pair.b);
        try tlsTestWriteFlightToPeer(pair.b, &s4_bad_cert_server_flight);
        const session = try TlsSession.create(testing.allocator, pair.a, 5000, null);
        defer session.deinit();
        const reason = tlsHandshake(@ptrCast(session), s4_mismatch_host, 5000, null, false);
        try testing.expectEqual(Reason.tls_cert_invalid, reason);
        try testing.expect(!session.handshake_complete);
    }

    // ---- Opt-in leg: INSECURE (insecure = true) ----
    // ⚠ The SAME wrong-hostname flight — with verification disabled it does NOT
    // fail as a certificate rejection: it SKIPS `verifyHostName` and proceeds
    // PAST the Certificate message (the truncated flight then carries no
    // ServerKeyExchange, so the handshake fails LATER for a non-cert reason,
    // bounded by the short deadline). The security-meaningful invariant is that
    // `insecure` genuinely bypassed cert verification (`reason != tls_cert_invalid`)
    // — proving the loud opt-in is a REAL toggle, not a no-op that silently keeps
    // verifying — while a truncated flight still never yields a usable session.
    {
        const pair = try testSocketpairNonblocking();
        defer closeFd(pair.a);
        defer closeFd(pair.b);
        try tlsTestWriteFlightToPeer(pair.b, &s4_bad_cert_server_flight);
        const session = try TlsSession.create(testing.allocator, pair.a, 300, null);
        defer session.deinit();
        const reason = tlsHandshake(@ptrCast(session), s4_mismatch_host, 300, null, true);
        try testing.expect(reason != .tls_cert_invalid);
        try testing.expect(!session.handshake_complete);
    }
}

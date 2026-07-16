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
    return connectIp4Posix(ip, port, timeout_ms, kill_flag);
}

/// The posix non-blocking connect (see `connectIp4`). Creates the socket,
/// flips it to `O_NONBLOCK`, issues the connect, and polls `POLL.OUT` in
/// deadline-and-kill-bounded quanta until `SO_ERROR` reports the outcome,
/// then restores blocking mode so the returned fd is compatible with the
/// poll-then-read `recv`/`send` (which keep the fd blocking).
fn connectIp4Posix(ip: [4]u8, port: u16, timeout_ms: i64, kill_flag: ?*std.atomic.Value(bool)) ConnectOutcome {
    const socket_rc = std.posix.system.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, std.posix.IPPROTO.TCP);
    if (std.posix.errno(socket_rc) != .SUCCESS) return .{ .reason = mapSocketCreateErrno(socket_rc), .fd = 0 };
    const handle: net.Socket.Handle = @intCast(socket_rc);
    var connected = false;
    defer if (!connected) {
        _ = std.posix.system.close(handle);
    };

    // Flip to non-blocking so `connect` returns EINPROGRESS instead of
    // blocking the pool thread on the OS connect timeout.
    const nonblock_bit: usize = @as(usize, 1) << @bitOffsetOf(std.posix.O, "NONBLOCK");
    const original_flags_rc = std.posix.system.fcntl(handle, std.posix.F.GETFL, @as(usize, 0));
    if (std.posix.errno(original_flags_rc) != .SUCCESS) return .{ .reason = .other, .fd = 0 };
    const original_flags: usize = @intCast(original_flags_rc);
    if (std.posix.errno(std.posix.system.fcntl(handle, std.posix.F.SETFL, original_flags | nonblock_bit)) != .SUCCESS)
        return .{ .reason = .other, .fd = 0 };

    var address = std.mem.zeroInit(std.posix.sockaddr.in, .{
        .family = std.posix.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = @as(u32, @bitCast(ip)), // [a,b,c,d] in memory == network byte order
    });
    const address_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.in);
    const connect_rc = std.posix.system.connect(handle, @ptrCast(&address), address_len);
    switch (std.posix.errno(connect_rc)) {
        .SUCCESS => {
            // Connected immediately (common on loopback). Restore blocking.
            _ = std.posix.system.fcntl(handle, std.posix.F.SETFL, original_flags);
            connected = true;
            return .{ .reason = .ok, .fd = fdToBits(handle) };
        },
        // In progress — poll for completion below. (`EWOULDBLOCK` == `EAGAIN`
        // on posix, so it is covered by `.AGAIN`.)
        .INPROGRESS, .INTR, .AGAIN => {},
        else => |connect_errno| return .{ .reason = mapConnectErrno(connect_errno), .fd = 0 },
    }

    // Absolute monotonic deadline (HIGH-3): read once, recompute `deadline -
    // now` each quantum so the timeout holds regardless of poll wake pattern.
    const has_deadline = timeout_ms > 0;
    const deadline_ms: i64 = if (has_deadline) monotonicMillis() + timeout_ms else 0;
    while (true) {
        if (kill_flag) |flag| {
            if (flag.load(.acquire)) return .{ .reason = .other, .fd = 0 };
        }
        var quantum: i32 = poll_quantum_ms;
        if (has_deadline) {
            const remaining = deadline_ms - monotonicMillis();
            if (remaining <= 0) return .{ .reason = .timed_out, .fd = 0 };
            if (remaining < quantum) quantum = @intCast(remaining);
        }
        switch (waitWritable(handle, quantum)) {
            .timeout => continue, // re-check deadline + kill
            .failed => return .{ .reason = .other, .fd = 0 },
            .ready => {},
        }
        // Writable (or POLLERR/POLLHUP): `SO_ERROR` carries the verdict.
        const pending = soError(handle);
        if (pending == 0) {
            // Connected — but if a kill became visible right as the connect
            // completed (the "succeeds exactly at kill" residual race, HIGH-1),
            // do NOT hand the live fd back to a tearing-down process. Leaving
            // `connected` false makes the `defer` close the transient fd here on
            // the pool thread, so it never reaches the fiber continuation (which
            // the kill teardown would skip, orphaning the fd). The pending-fd
            // teardown slot in `abi.zig` remains the backstop for a kill that
            // becomes visible only after this check but before re-attach.
            if (kill_flag) |flag| {
                if (flag.load(.acquire)) return .{ .reason = .other, .fd = 0 };
            }
            _ = std.posix.system.fcntl(handle, std.posix.F.SETFL, original_flags);
            connected = true;
            return .{ .reason = .ok, .fd = fdToBits(handle) };
        }
        if (pending < 0) return .{ .reason = .other, .fd = 0 };
        return .{ .reason = mapConnectErrno(@enumFromInt(pending)), .fd = 0 };
    }
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
    // ABSOLUTE monotonic deadline (HIGH-3): read the clock once and recompute
    // `deadline - now` each quantum. The prior loop summed `quantum` onto an
    // elapsed counter ONLY on a `.timeout` poll, so a peer dribbling one byte
    // per sub-quantum kept every poll `.ready`, never advanced the counter,
    // and defeated the `timeout_ms` deadline — pinning a pool thread forever.
    // An absolute deadline cannot be dribble-defeated (a `.ready` poll no
    // longer needs accounting because `now` moves on its own).
    const has_deadline = timeout_ms > 0;
    const deadline_ms: i64 = if (has_deadline) monotonicMillis() + timeout_ms else 0;
    while (true) {
        if (kill_flag) |flag| {
            if (flag.load(.acquire)) return .{ .status = recv_status_closed, .bytes_filled = filled };
        }
        var quantum: i32 = poll_quantum_ms;
        if (has_deadline) {
            const remaining = deadline_ms - monotonicMillis();
            // On timeout the already-consumed `filled` bytes ride out on the
            // outcome (MED-1): a `recv_exact` that timed out mid-frame has
            // pulled `filled` bytes off the socket, and dropping them would
            // desync a framed stream. The caller surfaces them as
            // `SocketRecv.TimedOut(partial)` so no bytes are lost.
            if (remaining <= 0) return .{ .status = @intFromEnum(Reason.timed_out), .bytes_filled = filled };
            if (remaining < quantum) quantum = @intCast(remaining);
        }
        switch (waitReadable(handle, quantum)) {
            .timeout => continue, // re-check deadline + kill (no manual accounting)
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
    const deadline_ms: i64 = if (has_deadline) monotonicMillis() + timeout_ms else 0;
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

    var recv_buffer: [64]u8 = undefined;
    const received = recv(accepted.fd, recv_buffer[0..payload.len], true, 5000, null);
    try testing.expectEqual(@as(i32, recv_status_chunk), received.status);
    try testing.expectEqual(payload.len, received.bytes_filled);
    try testing.expectEqualSlices(u8, payload[0..], recv_buffer[0..payload.len]);

    // Server → client the other way (full duplex on one connection, no split).
    const reply = send(accepted.fd, "pong", 0, null);
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
    const client = connectIp4(.{ 127, 0, 0, 1 }, listener.bound_port, 5000, null);
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
    _ = send(client.fd, "after", 0, null);
    const after = recv(accepted.fd, recv_buffer[0..], false, 5000, null);
    try testing.expectEqual(@as(i32, recv_status_chunk), after.status);
    try testing.expectEqualSlices(u8, "after", recv_buffer[0..after.bytes_filled]);
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
    var drain: [65536]u8 = undefined;
    _ = recv(accepted.fd, drain[0..], false, 1000, null);
    try testing.expect(localAddress(client.fd).ok);
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
    var buffer: [200]u8 = undefined;
    const before_ms = monotonicMillis();
    const outcome = recv(accepted.fd, buffer[0..], true, 300, null);
    const elapsed_ms = monotonicMillis() - before_ms;

    stop.store(true, .release);
    thread.join();

    try testing.expectEqual(@as(i32, @intFromEnum(Reason.timed_out)), outcome.status);
    try testing.expect(outcome.bytes_filled < buffer.len); // a PARTIAL, not the whole frame
    try testing.expect(outcome.bytes_filled >= 1); // some dribbled bytes were consumed
    try testing.expect(elapsed_ms < 2000); // bounded by the 300ms deadline, not the dribble length

    // The partial bytes are NOT lost — they are surfaced in `bytes_filled`
    // (MED-1), so a caller can resume a framed read without desync.
    for (buffer[0..outcome.bytes_filled]) |byte| try testing.expectEqual(@as(u8, 'x'), byte);
}

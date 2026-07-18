//! `tls_session` — the heap-stable owner of ONE established TLS-client session
//! (Phase S4, `docs/socket-implementation-plan.md`). It bundles everything a
//! live `std.crypto.tls.Client` needs into a SINGLE heap allocation whose
//! address never moves, and guarantees the key material is scrubbed before the
//! memory is returned.
//!
//! ## Why a heap-stable box
//!
//! `std.crypto.tls.Client` embeds its plaintext `reader`/`writer` interfaces
//! and holds raw pointers to the transport `input`/`output` (the `SocketStream`
//! adapter's reader/writer). Those interfaces recover the parent via
//! `@fieldParentPtr`, so the `Client` AND the `SocketStream` MUST stay at a
//! fixed address for the session's whole life. A `TlsSession` is therefore
//! allocated ONCE (`create`) and only ever referenced through the returned
//! pointer — never copied by value.
//!
//! ## Ownership boundary
//!
//! This module is imported by the gate-ON/gate-OFF socket BRIDGE (the handshake
//! trampoline + the recv/send kind-branch, Job 3), NOT by the pure
//! `socket_table.zig` — the domain slot stores the session as an opaque
//! `?*anyopaque` it never dereferences, so the table's purity (it manages only
//! generational handles) is preserved.
//!
//! ## Job-1 scope
//!
//! This file defines the STRUCT and its lifecycle — `create` (allocate the box
//! + wire the four buffers + the `SocketStream` adapter) and `deinit` (scrub
//! the key material with `std.crypto.secureZero`, then free). The handshake
//! that POPULATES the `Client` (`Client.init` over the adapter) is Job 3; here
//! the `Client` is reserved but unpopulated, and `deinit` scrubs unconditionally
//! so no path can ever leak key residue.

const std = @import("std");
const socket_io = @import("socket_io.zig");

const Fd = socket_io.Fd;

/// The mandatory minimum size of each of the four TLS buffers (encrypted-in,
/// encrypted-out, plaintext-in, plaintext-out): one whole ciphertext record +
/// header. `std.crypto.tls.Client.init` asserts the transport reader buffer is
/// at least this large, and the client's `drain`/`flush` demand the same room
/// from the transport writer; sizing all four alike keeps the record layer in
/// its documented bounds. Sourced from `socket_io` so the two never drift.
pub const buffer_len: usize = socket_io.tls_min_buffer_len;

/// A single established TLS-client session: the record-layer `Client`, the raw
/// `SocketStream` transport adapter, and the four record-layer buffers, all in
/// ONE heap-stable allocation.
///
/// SECURITY: `deinit` `secureZero`s the entire `Client` (which contains the
/// negotiated `application_cipher` keys) AND every buffer BEFORE freeing them,
/// so no key or plaintext residue survives in the freed pages.
pub const TlsSession = struct {
    /// The record-layer client. RESERVED in Job 1 (populated by the handshake
    /// in Job 3 via `Client.init` over `stream`'s reader/writer); `deinit`
    /// scrubs it unconditionally, so an un-populated session is still safe.
    client: std.crypto.tls.Client,

    /// The raw-fd transport adapter (`input`/`output` for `Client.init`). Lives
    /// INSIDE the box so its embedded reader/writer interfaces keep a stable
    /// address for the `Client`'s `@fieldParentPtr` recovery.
    stream: socket_io.SocketStream,

    /// Encrypted-from-server bytes (the `SocketStream` reader's buffer).
    encrypted_in: []u8,
    /// Encrypted-to-server bytes (the `SocketStream` writer's buffer).
    encrypted_out: []u8,
    /// Decrypted plaintext from the server (the `Client.reader`'s buffer).
    plaintext_in: []u8,
    /// Plaintext to encrypt to the server (the `Client.writer`'s buffer).
    plaintext_out: []u8,

    /// The allocator the box + its buffers came from. Production passes
    /// `std.heap.page_allocator` (the kernel-memory convention); a test passes
    /// the testing allocator so a leak is caught.
    allocator: std.mem.Allocator,

    /// Whether the handshake has populated `client` (set by Job 3). `deinit`
    /// scrubs regardless — this only lets the recv/send bridge (Job 3) assert a
    /// session is usable before routing plaintext through it.
    handshake_complete: bool = false,

    /// Allocate a heap-stable `TlsSession` and wire its four record-layer
    /// buffers + the `SocketStream` transport adapter over `handle` (which must
    /// already be `O_NONBLOCK`). `timeout_ms` is the RELATIVE budget for the
    /// whole handshake, converted once to an absolute deadline inside the
    /// adapter (`<= 0` → no deadline). The `Client` is left un-populated (Job 3
    /// runs the handshake). On ANY allocation failure everything already
    /// allocated is freed, so a failed `create` leaks nothing. Production
    /// callers pass `std.heap.page_allocator`.
    pub fn create(
        allocator: std.mem.Allocator,
        handle: Fd,
        timeout_ms: i64,
        kill_flag: ?*std.atomic.Value(bool),
    ) std.mem.Allocator.Error!*TlsSession {
        const session = try allocator.create(TlsSession);
        errdefer allocator.destroy(session);

        const encrypted_in = try allocator.alloc(u8, buffer_len);
        errdefer allocator.free(encrypted_in);
        const encrypted_out = try allocator.alloc(u8, buffer_len);
        errdefer allocator.free(encrypted_out);
        const plaintext_in = try allocator.alloc(u8, buffer_len);
        errdefer allocator.free(plaintext_in);
        const plaintext_out = try allocator.alloc(u8, buffer_len);
        errdefer allocator.free(plaintext_out);

        session.* = .{
            .client = undefined,
            .stream = socket_io.SocketStream.init(handle, timeout_ms, kill_flag, encrypted_in, encrypted_out),
            .encrypted_in = encrypted_in,
            .encrypted_out = encrypted_out,
            .plaintext_in = plaintext_in,
            .plaintext_out = plaintext_out,
            .allocator = allocator,
            .handshake_complete = false,
        };
        return session;
    }

    /// SECURITY: overwrite every byte of key-bearing memory with zeroes — the
    /// whole `Client` (which holds the negotiated `application_cipher` keys and
    /// sequence numbers) plus all four buffers (which may hold plaintext or
    /// ciphertext). `std.crypto.secureZero` is not elided by the optimizer.
    /// Split out from `deinit` so a unit test can assert the region is zeroed
    /// while it is still readable (before the free).
    pub fn zeroizeSecrets(session: *TlsSession) void {
        std.crypto.secureZero(u8, std.mem.asBytes(&session.client));
        std.crypto.secureZero(u8, session.encrypted_in);
        std.crypto.secureZero(u8, session.encrypted_out);
        std.crypto.secureZero(u8, session.plaintext_in);
        std.crypto.secureZero(u8, session.plaintext_out);
    }

    /// Scrub the key material (`zeroizeSecrets`) and then FREE the box and its
    /// four buffers. Called on EVERY session-drop path (sweep destructor, close,
    /// kill, crash, handoff-undo — Job 3), so a dropped connection never leaves
    /// key residue in freed pages. Idempotent w.r.t. scrubbing (a double scrub
    /// is harmless); must be called exactly once for the free.
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

// ---------------------------------------------------------------------------
// Tests (Phase S4 Job 1) — the struct's alloc/free/scrub lifecycle. The
// handshake that POPULATES the client is Job 3, so these prove ONLY that the
// box is heap-stable, leak-free (testing allocator), and scrubs all
// key-bearing memory before free.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "tls_session: create allocates a heap-stable, leak-free session and deinit frees it" {
    const gpa = testing.allocator;
    const session = try TlsSession.create(gpa, 7, 5000, null);
    // Heap-stable: the embedded adapter interfaces are addressable through the
    // box and stay put (the `Client`'s `@fieldParentPtr` recovery depends on it).
    try testing.expectEqual(&session.stream.reader_interface, session.stream.inputReader());
    try testing.expectEqual(&session.stream.writer_interface, session.stream.outputWriter());
    // The four buffers are each at least one whole ciphertext record.
    try testing.expect(session.encrypted_in.len >= socket_io.tls_min_buffer_len);
    try testing.expect(session.encrypted_out.len >= socket_io.tls_min_buffer_len);
    try testing.expect(session.plaintext_in.len >= socket_io.tls_min_buffer_len);
    try testing.expect(session.plaintext_out.len >= socket_io.tls_min_buffer_len);
    // The adapter wraps the given fd and its buffers back the interfaces.
    try testing.expectEqual(@as(Fd, 7), session.stream.handle);
    try testing.expectEqual(session.encrypted_in.ptr, session.stream.reader_interface.buffer.ptr);
    try testing.expectEqual(session.encrypted_out.ptr, session.stream.writer_interface.buffer.ptr);
    session.deinit(); // testing.allocator asserts no leak at test end
}

test "tls_session: zeroizeSecrets scrubs the whole client + every buffer before free (no key residue)" {
    const gpa = testing.allocator;
    const session = try TlsSession.create(gpa, 3, 5000, null);
    defer session.deinit(); // frees (a second scrub in deinit is harmless)

    // Simulate a populated session: stamp every key-bearing region with a
    // recognizable non-zero pattern (as if the handshake had written keys and
    // the buffers held cipher/plaintext).
    @memset(std.mem.asBytes(&session.client), 0xAA);
    @memset(session.encrypted_in, 0xAA);
    @memset(session.encrypted_out, 0xAA);
    @memset(session.plaintext_in, 0xAA);
    @memset(session.plaintext_out, 0xAA);

    session.zeroizeSecrets();

    // PROVE no residue survives while the memory is still readable (pre-free).
    for (std.mem.asBytes(&session.client)) |byte| try testing.expectEqual(@as(u8, 0), byte);
    for (session.encrypted_in) |byte| try testing.expectEqual(@as(u8, 0), byte);
    for (session.encrypted_out) |byte| try testing.expectEqual(@as(u8, 0), byte);
    for (session.plaintext_in) |byte| try testing.expectEqual(@as(u8, 0), byte);
    for (session.plaintext_out) |byte| try testing.expectEqual(@as(u8, 0), byte);
}

test "tls_session: a create that fails partway leaks nothing (failing allocator)" {
    // Drive `create` through each allocation-failure point; the errdefers must
    // unwind every prior allocation, so the testing allocator sees no leak.
    var fail_index: usize = 0;
    while (fail_index < 5) : (fail_index += 1) {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        const result = TlsSession.create(failing.allocator(), 1, 1000, null);
        try testing.expectError(error.OutOfMemory, result);
    }
}

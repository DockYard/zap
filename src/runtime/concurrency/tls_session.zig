//! `tls_session` — a thin RE-EXPORT of `socket_io.TlsSession` (Phase S4).
//!
//! The `TlsSession` heap box and its lifecycle ORIGINALLY lived here (Job 1),
//! but the gate-OFF socket runtime stages `socket_io.zig` as a self-contained
//! `zap_socket_io` module, and a staged struct-source cannot resolve a
//! cross-file relative `@import` (its siblings are not co-located in the
//! staging directory under their import names). Because `socket_io.zig`'s TLS
//! drivers need `TlsSession`, its DEFINITION had to move INTO `socket_io.zig`
//! (which stays std-only self-contained and therefore stages cleanly). This
//! file survives as a re-export so the gate-ON world (`concurrency.zig`) and
//! any code that referenced `concurrency.tls_session.TlsSession` keep working,
//! and so the Job-1 lifecycle tests keep running in the host test suite. It is
//! imported ONLY relatively (never staged), so its relative `socket_io.zig`
//! import always resolves.

const std = @import("std");
const socket_io = @import("socket_io.zig");

const Fd = socket_io.Fd;

/// The mandatory minimum size of each of the four TLS buffers — re-exported
/// from `socket_io` so the two never drift.
pub const buffer_len: usize = socket_io.tls_session_buffer_len;

/// The heap-stable owner of ONE established TLS-client session. Defined in
/// `socket_io.zig` (see the module header for why); re-exported here.
pub const TlsSession = socket_io.TlsSession;

// ---------------------------------------------------------------------------
// Tests (Phase S4) — the struct's alloc/free/scrub lifecycle, exercised through
// the re-export. The handshake that POPULATES the client is covered by the
// `socket_io` TLS-driver tests; these prove ONLY that the box is heap-stable,
// leak-free (testing allocator), and scrubs all key-bearing memory before free.
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

test "tls_session: zeroizeSecrets scrubs the whole role union + every buffer before free (no key residue)" {
    const gpa = testing.allocator;
    const session = try TlsSession.create(gpa, 3, 5000, null);
    defer session.deinit(); // frees (a second scrub in deinit is harmless)

    // Simulate a populated session: stamp every key-bearing region with a
    // recognizable non-zero pattern (as if the handshake had written the
    // negotiated keys into the endpoint arm and the buffers held cipher/
    // plaintext). The role is a client/server tagged union (Phase S5), so its
    // WHOLE storage — whichever arm is resident — is the key-bearing region.
    @memset(std.mem.asBytes(&session.role), 0xAA);
    @memset(session.encrypted_in, 0xAA);
    @memset(session.encrypted_out, 0xAA);
    @memset(session.plaintext_in, 0xAA);
    @memset(session.plaintext_out, 0xAA);

    session.zeroizeSecrets();

    // PROVE no residue survives while the memory is still readable (pre-free).
    for (std.mem.asBytes(&session.role)) |byte| try testing.expectEqual(@as(u8, 0), byte);
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

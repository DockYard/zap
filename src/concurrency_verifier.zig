const std = @import("std");
const ir = @import("ir.zig");

// ============================================================
// Concurrency send-boundary verifier (P2-J7, plan item 2.6).
//
// A compiler-internal invariant verifier for the process-send
// boundary, modeled on `src/arc_verifier.zig`: it walks the IR of
// every function, finds each SEND site, and reasons — GENERICALLY,
// over ownership classes and value modes — about whether the value
// crossing the process boundary does so soundly. On a violation it
// emits a Swift-OSSA-style diagnostic via `std.debug.print` and
// returns `error.ConcurrencyInvariantViolation`, which the compiler
// propagates as a hard build error (any pass that produces
// verifier-rejected IR has a bug to fix — the arc_verifier doctrine:
// "fix the upstream pass, don't disable the rule").
//
// ------------------------------------------------------------
// THE PRIME DIRECTIVE — no hardcoded Zap struct names
// ------------------------------------------------------------
//
// A verifier is genuine compiler mechanics. It must NOT know about
// the Zap `Process` library struct (`lib/process.zap`) by name. It
// identifies a send by the LOWERED RUNTIME PRIMITIVE it becomes.
//
// `Process.send(pid, msg)` desugars to `:zig.ProcessRuntime.send_message`
// (see `lib/process.zap` and `src/runtime.zig`'s `ProcessRuntime`
// namespace), and the HIR `:zig.Struct.func` lowering (`src/hir.zig`)
// turns that into a `.call_builtin` whose `name` is the qualified
// runtime-primitive identifier `"ProcessRuntime.send_message"`.
// `ProcessRuntime` is the compiler's own `:zig.` intrinsic BRIDGE
// namespace (a `pub const … = struct` in `src/runtime.zig`), NOT a
// Zap library struct. Recognizing it is exactly analogous to
// `arc_liveness.ownedMutatingBuiltinSlot` recognizing the runtime's
// `"Map.put"` / `"List.push"` builtin ABI, and to `zir_builder.zig`
// recognizing the `"ProcessRuntime.receive_message"` intrinsic: the
// compiler reasoning about its OWN lowered primitive vocabulary. The
// single name literal lives in one classifier (`classifySendPrimitive`)
// so the passes below stay name-free and reason only over the send
// KIND, the message's `OwnershipClass`, and the argument `ValueMode`.
//
// ------------------------------------------------------------
// What P2-J5's send actually does — the reality this verifier
// matches (no hazard theater)
// ------------------------------------------------------------
//
// P2-J5's `Process.send` is a DEEP-COPY send (plan items 2.4/2.5,
// `src/runtime.zig` `serializeMessage`/`send_message`): the sender
// serializes the message's value graph into a flat NEUTRAL BLOB —
// reading its own data only, never mutating a refcount — and the
// receiver reconstructs a fresh, independent rc=1 copy it solely
// owns. The send BORROWS its message: the sender's original stays
// valid, its refcounts are untouched, and the sender's own end-of-
// scope Perceus release still frees it (verified by a gate-ON test
// that reuses the value after send). Constraint 3 (scheduler-local
// refcounts) therefore holds BY CONSTRUCTION — the in-flight blob
// carries ZERO live refcounts.
//
// This reality is decisive for what has teeth NOW versus what is a
// Phase-3 (move-seam) concern. Under COPY semantics, sending is
// universally sound for any walker-sendable value REGARDLESS of its
// ownership: reading a value to deep-copy it is exactly what a borrow
// permits; the receiver gets an independent copy; nothing is aliased
// across the boundary. That is the whole point of copy-by-default —
// it sidesteps every ownership hazard. Consequently:
//
//   * "No borrowed value reaches a send" (research §6.11 pass 1) is
//     NOT a Phase-2 rule. The copy-send's message parameter is itself
//     inherently `.borrowed` (it reads to copy), so at the send-
//     primitive boundary the message is ALWAYS borrowed — a Phase-2
//     "reject borrowed at send" would reject EVERY send. Borrowed-at-
//     send becomes unsound only under a Phase-3 MOVE-send, where
//     sending transfers a +1 the sender does not hold. → SCAFFOLDED.
//
//   * "No shared value crosses a process boundary" (pass 2) — the
//     deep-COPY path copies, so a shared/aliased value crosses safely.
//     The move-guard (reject a non-unique value MOVE-sent) is Phase-3.
//     What Phase 2 DOES need is the COPY-PATH INVARIANT that keeps the
//     copy sound: the message must reach the copy-send by a NON-
//     CONSUMING convention, so no +1 is transferred into an argument
//     the copy-send never releases. → ENFORCED (invariant C1 below);
//     move-guard SCAFFOLDED.
//
//   * "Use-after-move across send" (pass 4) — the copy-send does not
//     consume its argument, so reusing a value after sending it is
//     sound and supported today. Teeth land in Phase 3's move path,
//     extending the existing move / use-after-move machinery
//     (`src/types.zig` `ensureBindingAvailable`; `arc_ownership`'s
//     `isLastUseAt`) to treat a move-send as a consuming last use.
//     → SCAFFOLDED.
//
// ------------------------------------------------------------
// The invariants
// ------------------------------------------------------------
//
//   C1. (ENFORCED — Phase-2 copy-path invariant.) At every COPY-send
//       primitive, an ARC-managed message argument (ownership class
//       `.owned` or `.borrowed`, i.e. non-`.trivial`) MUST NOT be
//       moved/consumed into the send: neither the argument's
//       `ValueMode` at the call may be `.move`, nor may the argument
//       local be produced by a `.move_value`. The deep-copy send
//       reads-and-copies the message and never takes ownership; a
//       moved-in ARC value transfers a `+1` the send never releases —
//       leaking the cell, or (paired with the sender's own scope-exit
//       release) double-freeing it. This is the invariant the copy
//       path requires for Constraint 3, and it fills a real gap: the
//       ARC verifier's V7 (caller/callee convention agreement) does
//       NOT check `.call_builtin` sites, so nothing else guards the
//       send primitive's message slot. Currently vacuously satisfied
//       (the copy-send's message is a `.borrowed` param passed by
//       `.borrow`), so it accepts all shipping IR while catching any
//       future pass — or the Phase-3 move lowering wired to the wrong
//       primitive — that moves an ARC value into a copy-send.
//       `.trivial` scalars are bit-copied; a `.move` mode on a scalar
//       is a harmless copy and is not an invariant.
//
//   C2. (SCAFFOLDED — Phase-3 borrowed-at-move-send.) At a MOVE-send
//       primitive, a `.borrowed` message MUST be rejected: the sender
//       is caller-retained and does not hold the `+1` to transfer, so
//       moving it across the boundary would alias/transfer a value the
//       caller still believes it owns. The send-boundary analogue of
//       ARC V6 ("`.move_value` source must be `.owned`"). Inactive in
//       Phase 2 because `classifySendPrimitive` recognizes only the
//       COPY primitive; Phase 3's move-send job teaches the classifier
//       the move primitive and this pass activates automatically.
//
//   C3. (SCAFFOLDED — Phase-3 use-after-move-across-send.) At a
//       MOVE-send primitive, the moved source is consumed; a later use
//       is a use-after-move, exactly as caught elsewhere — extended to
//       the send boundary. Inactive in Phase 2 (the copy-send borrows,
//       never consumes). The seam (`recordMoveSendConsumes`) is where
//       Phase 3 marks the moved source so the existing use-after-move
//       machinery rejects reuse.
//
// ------------------------------------------------------------
// Pipeline placement + zero cost
// ------------------------------------------------------------
//
// Registered in `src/compiler.zig` (`runConcurrencyVerifier`), invoked
// right after the ARC verifier once ownership is materialized, so
// `local_ownership` and call `arg_modes` are settled. It is zero-cost
// for any program that never sends: `verify` runs a cheap pre-scan
// (`hasSendPrimitive`) and returns immediately when the function
// contains no send primitive — the natural `runtime_concurrency`-OFF
// case, since a gate-off build cannot contain a send builtin at all
// (calling `Process.send` is a compile error before IR). The check is
// otherwise per-instruction and O(1) against `function.local_ownership`
// and the call's `arg_modes`; the only backward walk is the bounded
// same-stream producer scan for C1, mirroring the ARC verifier's V7.
// ============================================================

/// Errors `verify` can return.
///
/// `ConcurrencyInvariantViolation` indicates the IR violated a send-
/// boundary invariant. The offending site is reported via
/// `std.debug.print` before the error is returned, with enough context
/// to localise the bug to a specific pass and send site.
pub const VerifyError = error{
    OutOfMemory,
    ConcurrencyInvariantViolation,
};

/// The kind of send a recognized primitive performs. Phase 2 ships
/// only `.copy`; `.move` is the Phase-3 seam.
pub const SendKind = enum {
    /// Deep-COPY send (P2-J5): reads-and-copies the message into a
    /// neutral blob; BORROWS its argument. Invariant C1 governs it.
    copy,
    /// MOVE send (Phase 3): transfers ownership of the message graph
    /// across the boundary. Invariants C2/C3 govern it. No primitive
    /// classifies as `.move` in Phase 2.
    move,
};

/// A recognized send-primitive call site, produced by
/// `classifySendPrimitive`. Name-free by construction: the passes read
/// only `kind` and `message_slot`.
pub const SendPrimitive = struct {
    kind: SendKind,
    /// Index into the call's `args` slice holding the MESSAGE value —
    /// the value that crosses the process boundary. For
    /// `send_message(target_pid_bits, message)` this is slot 1 (slot 0
    /// is the destination pid bits, a plain `u64` that never carries an
    /// ARC cell).
    message_slot: usize,
};

/// The COPY-send runtime primitive's lowered `.call_builtin` name. The
/// `:zig.ProcessRuntime.send_message` intrinsic bridge (see the module
/// doc / `src/runtime.zig`) — a compiler runtime primitive, NOT the
/// Zap `Process` struct. This single literal is the one place the
/// concurrency verifier names the send primitive.
const COPY_SEND_PRIMITIVE_BUILTIN_NAME = "ProcessRuntime.send_message";

/// The MOVE-send runtime primitive's lowered `.call_builtin` name.
/// RESERVED for Phase 3: the move-send job (plan Phase 3, item 3.3 —
/// the O(1) region-move send) lands a distinct move primitive and adds
/// it here, at which point C2/C3 activate with zero further wiring. No
/// such primitive exists in Phase 2, so this name never matches today.
const MOVE_SEND_PRIMITIVE_BUILTIN_NAME = "ProcessRuntime.send_message_moved";

/// Classify a `.call_builtin` name as a send primitive, or `null` if it
/// is not a send. The verifier's ONLY point of contact with the
/// primitive's identity; everything downstream reasons over the
/// returned `SendKind` / `message_slot`, never the name.
pub fn classifySendPrimitive(name: []const u8) ?SendPrimitive {
    if (std.mem.eql(u8, name, COPY_SEND_PRIMITIVE_BUILTIN_NAME)) {
        return .{ .kind = .copy, .message_slot = 1 };
    }
    // Phase-3 seam: the move-send primitive is unrecognized in Phase 2
    // (no lowering produces it), so this branch is dead until Phase 3
    // introduces the move send. Present so the classifier — the single
    // Phase-2/Phase-3 boundary — already routes a `.move` kind to the
    // scaffolded C2/C3 passes.
    if (std.mem.eql(u8, name, MOVE_SEND_PRIMITIVE_BUILTIN_NAME)) {
        return .{ .kind = .move, .message_slot = 1 };
    }
    return null;
}

/// Test-mode flag suppressing diagnostic output. Negative tests expect
/// a violation and don't need the verifier to spam the test runner's
/// stderr. Production paths leave it `false` so user-facing compiler
/// errors surface via `std.debug.print` (the same channel the ARC
/// verifier uses — `std.log.err` would make the Zig test runner treat
/// the expected-error path as a failure).
threadlocal var suppress_diagnostics: bool = false;

/// Per-verification context. Threads `program` for parity with the ARC
/// verifier and for the Phase-3 callee-convention lookups C2 will need;
/// storing it keeps the field live without an unused-parameter shim.
const VerifyContext = struct {
    allocator: std.mem.Allocator,
    function: *const ir.Function,
    program: *const ir.Program,
};

/// Verify send-boundary invariants on `function`. Zero-cost when the
/// function contains no send primitive. Walks every instruction stream
/// (top-level body and every nested sub-stream) and applies the send-
/// site checks. Returns `error.ConcurrencyInvariantViolation` on the
/// first violation.
pub fn verify(
    allocator: std.mem.Allocator,
    function: *const ir.Function,
    program: *const ir.Program,
) VerifyError!void {
    // Fast path: a function with no send primitive has nothing to
    // check. This is the zero-cost gate — a `runtime_concurrency`-OFF
    // build cannot contain a send builtin, and most functions in a
    // gated-on build still never send.
    if (!try hasSendPrimitive(allocator, function)) return;

    var ctx = VerifyContext{ .allocator = allocator, .function = function, .program = program };
    for (function.body) |block| {
        try verifyStream(&ctx, block.instructions);
    }
}

/// Quick per-function pre-check: does the function contain ANY send
/// primitive (in its body or any nested stream)? Mirrors the ARC
/// verifier's `hasUncheckedCallSite` fast path.
fn hasSendPrimitive(
    allocator: std.mem.Allocator,
    function: *const ir.Function,
) std.mem.Allocator.Error!bool {
    var scanner = SendPrimitiveScanner{};
    try ir.forEachInstruction(allocator, function, &scanner, SendPrimitiveScanner.visit);
    return scanner.found;
}

const SendPrimitiveScanner = struct {
    found: bool = false,

    fn visit(self: *@This(), instr: *const ir.Instruction) void {
        if (self.found) return;
        switch (instr.*) {
            .call_builtin => |cb| {
                if (classifySendPrimitive(cb.name) != null) self.found = true;
            },
            else => {},
        }
    }
};

/// Visit every instruction in `stream` (and recursively every nested
/// sub-stream). The recursion mirrors `arc_verifier.verifyStream` /
/// `arc_liveness.flattenChildren`: all IR traversals must agree on
/// which streams contain checkable instructions, so a send buried in an
/// `if_expr` / `switch_literal` arm is not silently skipped.
fn verifyStream(
    ctx: *VerifyContext,
    stream: []const ir.Instruction,
) VerifyError!void {
    for (stream, 0..) |*instr, index| {
        try verifyInstruction(ctx, stream, index, instr);
        try verifyChildren(ctx, instr);
    }
}

/// Recurse into every nested instruction stream owned by `instr`, via
/// the canonical `ir.forEachChildStream` enumerator (so catch-all arms
/// like `union_switch.else_instrs` are covered — the same audit finding
/// the ARC verifier's `verifyChildren` addresses).
fn verifyChildren(
    ctx: *VerifyContext,
    instr: *const ir.Instruction,
) VerifyError!void {
    const Ctx = struct {
        ctx: *VerifyContext,
        err: ?VerifyError = null,
        fn onStream(self_ctx: *@This(), child: ir.ChildStream) void {
            if (self_ctx.err != null) return;
            verifyStream(self_ctx.ctx, child.stream) catch |e| {
                self_ctx.err = e;
            };
        }
    };
    var local = Ctx{ .ctx = ctx };
    ir.forEachChildStream(instr, &local, Ctx.onStream);
    if (local.err) |e| return e;
}

/// Per-instruction dispatch: a send is a `.call_builtin` whose name the
/// classifier recognizes. Everything else is not a send boundary and is
/// ignored.
fn verifyInstruction(
    ctx: *VerifyContext,
    stream: []const ir.Instruction,
    index: usize,
    instr: *const ir.Instruction,
) VerifyError!void {
    switch (instr.*) {
        .call_builtin => |cb| {
            const send = classifySendPrimitive(cb.name) orelse return;
            try checkSendSite(ctx, stream, index, cb, send);
        },
        else => {},
    }
}

/// Apply the send-boundary invariants (C1 enforced; C2/C3 scaffolded)
/// to one recognized send site.
fn checkSendSite(
    ctx: *VerifyContext,
    stream: []const ir.Instruction,
    call_index: usize,
    cb: ir.CallBuiltin,
    send: SendPrimitive,
) VerifyError!void {
    // A malformed send (fewer args than the message slot) is not this
    // pass's concern — earlier stages reject it. Guard the index so the
    // verifier can never read past `args`.
    if (send.message_slot >= cb.args.len) return;
    const message = cb.args[send.message_slot];
    const message_class = ownershipOf(ctx.function, message);

    switch (send.kind) {
        // -------- COPY send: invariant C1 (ENFORCED) --------
        .copy => {
            // Scoped to ARC-managed messages: a `.trivial` scalar is
            // bit-copied and a `.move` mode on it is a harmless copy.
            if (message_class == .trivial) return;

            const moved_by_mode = send.message_slot < cb.arg_modes.len and
                cb.arg_modes[send.message_slot] == .move;
            const moved_by_producer = producedByMoveValue(stream, call_index, message);
            if (moved_by_mode or moved_by_producer) {
                emitCopySafetyDiagnostic(ctx.function, call_index, cb.name, message, message_class);
                return error.ConcurrencyInvariantViolation;
            }
        },

        // -------- MOVE send: invariants C2/C3 (SCAFFOLDED) --------
        //
        // Unreachable in Phase 2 — `classifySendPrimitive` never yields
        // `.move` for any lowering that exists today. Phase 3's move-
        // send job activates this arm by teaching the classifier the
        // move primitive. The logic is written and tested (via directly
        // synthesized `.move` sites) so Phase 3 wires the move lowering
        // into a ready verifier rather than building it from scratch.
        .move => {
            // C2: a borrowed value has no `+1` to transfer across the
            // boundary — the sender is only borrowing it from its own
            // caller. The send-boundary analogue of ARC V6.
            if (message_class == .borrowed) {
                emitBorrowedAtMoveSendDiagnostic(ctx.function, call_index, cb.name, message);
                return error.ConcurrencyInvariantViolation;
            }

            // C3: the moved source is consumed at the send; a later use
            // is a use-after-move. The seam records the consumption so
            // the existing use-after-move machinery (extended to the
            // send boundary in Phase 3) rejects reuse.
            recordMoveSendConsumes(ctx, message);
        },
    }
}

/// C1 producer probe: is `arg_local` produced by a `.move_value` in the
/// same stream at or before `call_index`? Mirrors the ARC verifier's
/// `findArgProducerKind` backward scan (bounded by the stream length).
/// The `.move_value` realization is checked in addition to the call's
/// `ValueMode` so the invariant catches a consuming transfer regardless
/// of which signal a lowering used.
fn producedByMoveValue(
    stream: []const ir.Instruction,
    call_index: usize,
    arg_local: ir.LocalId,
) bool {
    var probe: usize = call_index;
    while (probe > 0) {
        probe -= 1;
        switch (stream[probe]) {
            .move_value => |mv| if (mv.dest == arg_local) return true,
            // Any other producer of this local ends the search: the
            // nearest definition decides how the value reached the send.
            .share_value => |sv| if (sv.dest == arg_local) return false,
            .copy_value => |cv| if (cv.dest == arg_local) return false,
            .borrow_value => |bv| if (bv.dest == arg_local) return false,
            .local_get => |lg| if (lg.dest == arg_local) return false,
            .local_set => |ls| if (ls.dest == arg_local) return false,
            .param_get => |pg| if (pg.dest == arg_local) return false,
            else => {},
        }
    }
    return false;
}

/// The Phase-3 seam for C3 (use-after-move-across-send). In Phase 2
/// this is never reached (no `.move` send exists). Phase 3 replaces the
/// body with the real recording: mark `message`'s binding consumed so
/// the existing use-after-move checker (`src/types.zig`
/// `ensureBindingAvailable`, or the IR-level `arc_ownership`
/// `isLastUseAt` last-use tracking) rejects a subsequent use, exactly
/// as it does for an ordinary `.move_value` consume.
fn recordMoveSendConsumes(ctx: *VerifyContext, message: ir.LocalId) void {
    // Reference the inputs so the seam's signature is stable for Phase 3
    // without an unused-parameter shim; no state is recorded in Phase 2.
    _ = ctx;
    _ = message;
}

/// Look up `local_id`'s ownership class. Returns `.trivial` for any id
/// past the table (defensive: a misnumbered LocalId yields a clean
/// classification instead of an out-of-bounds read), matching
/// `arc_verifier.ownershipOf`.
fn ownershipOf(
    function: *const ir.Function,
    local_id: ir.LocalId,
) ir.OwnershipClass {
    if (local_id >= function.local_ownership.len) return .trivial;
    return function.local_ownership[local_id];
}

// ------------------------------------------------------------
// Diagnostics — Swift-OSSA-style, matching the ARC verifier's surface.
// ------------------------------------------------------------

fn emitCopySafetyDiagnostic(
    function: *const ir.Function,
    call_index: usize,
    primitive_name: []const u8,
    message: ir.LocalId,
    message_class: ir.OwnershipClass,
) void {
    if (suppress_diagnostics) return;
    std.debug.print(
        "concurrency_verifier: function '{s}' violates send invariant C1:\n" ++
            "  send site at instruction {d} (copy-send primitive '{s}')\n" ++
            "  message local %{d} (ownership .{s}) is MOVED into the deep-copy send\n" ++
            "  the copy-send reads-and-copies its message and never takes ownership;\n" ++
            "  moving an ARC value in transfers a +1 the send never releases (leak, or\n" ++
            "  double-free against the sender's own scope-exit release)\n" ++
            "  fix: pass the message by borrow/share — the copy-send does not consume it\n",
        .{ function.name, call_index, primitive_name, message, @tagName(message_class) },
    );
}

fn emitBorrowedAtMoveSendDiagnostic(
    function: *const ir.Function,
    call_index: usize,
    primitive_name: []const u8,
    message: ir.LocalId,
) void {
    if (suppress_diagnostics) return;
    std.debug.print(
        "concurrency_verifier: function '{s}' violates send invariant C2:\n" ++
            "  send site at instruction {d} (move-send primitive '{s}')\n" ++
            "  message local %{d} is .borrowed — the sender does not own the +1 to transfer\n" ++
            "  moving a borrowed value across a process boundary aliases a value the\n" ++
            "  caller still owns\n" ++
            "  fix: send an owned/uniquely-owned value, or use the copy-send\n",
        .{ function.name, call_index, primitive_name, message },
    );
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

/// RAII guard that suppresses verifier diagnostics for the duration of
/// a negative test, restoring the previous setting on scope exit.
const SuppressDiagnostics = struct {
    prev: bool,

    fn init() SuppressDiagnostics {
        const prev = suppress_diagnostics;
        suppress_diagnostics = true;
        return .{ .prev = prev };
    }

    fn deinit(self: *SuppressDiagnostics) void {
        suppress_diagnostics = self.prev;
    }
};

/// Build a minimal `ir.Function` for hand-crafted verifier tests.
/// Caller owns the returned slices (use an arena). Mirrors
/// `arc_verifier.buildTestFunction`.
fn buildTestFunction(
    allocator: std.mem.Allocator,
    name: []const u8,
    instructions: []const ir.Instruction,
    local_ownership: []const ir.OwnershipClass,
) !ir.Function {
    const blocks = try allocator.alloc(ir.Block, 1);
    blocks[0] = .{
        .label = 0,
        .instructions = try allocator.dupe(ir.Instruction, instructions),
    };
    const ownership_copy = try allocator.dupe(ir.OwnershipClass, local_ownership);
    return ir.Function{
        .id = 0,
        .name = name,
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = @intCast(local_ownership.len),
        .param_conventions = &.{},
        .local_ownership = ownership_copy,
        .result_convention = .trivial,
    };
}

/// Standalone adapter: wrap `function` in a minimal `Program` and run
/// the public `verify`.
fn verifyFunctionStandalone(
    allocator: std.mem.Allocator,
    function: *const ir.Function,
) VerifyError!void {
    const functions = [_]ir.Function{function.*};
    const program = ir.Program{
        .functions = &functions,
        .type_defs = &.{},
        .entry = null,
    };
    return verify(allocator, function, &program);
}

/// Build a copy-send call site: `send_message(pid_bits, message)` with
/// the message passed by `message_mode`.
fn buildCopySend(
    arena: std.mem.Allocator,
    pid_local: ir.LocalId,
    message_local: ir.LocalId,
    message_mode: ir.ValueMode,
    dest: ir.LocalId,
) !ir.Instruction {
    const args = try arena.alloc(ir.LocalId, 2);
    args[0] = pid_local;
    args[1] = message_local;
    const arg_modes = try arena.alloc(ir.ValueMode, 2);
    arg_modes[0] = .move; // pid bits are a trivial u64 — mode is irrelevant
    arg_modes[1] = message_mode;
    return .{ .call_builtin = .{
        .dest = dest,
        .name = COPY_SEND_PRIMITIVE_BUILTIN_NAME,
        .args = args,
        .arg_modes = arg_modes,
    } };
}

test "classifySendPrimitive recognizes the copy-send runtime primitive by name" {
    const copy = classifySendPrimitive(COPY_SEND_PRIMITIVE_BUILTIN_NAME) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(SendKind.copy, copy.kind);
    try testing.expectEqual(@as(usize, 1), copy.message_slot);

    // Not a send: an ordinary runtime builtin must classify as null so
    // the verifier stays inert on non-send code.
    try testing.expectEqual(@as(?SendPrimitive, null), classifySendPrimitive("Map.put"));
    try testing.expectEqual(@as(?SendPrimitive, null), classifySendPrimitive("List.push"));
}

test "verify is zero-cost on a function with no send primitive" {
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // A lone non-send builtin: the pre-scan finds no send and returns.
    const args = try arena.alloc(ir.LocalId, 1);
    args[0] = 0;
    const arg_modes = try arena.alloc(ir.ValueMode, 1);
    arg_modes[0] = .borrow;
    const stream = [_]ir.Instruction{.{ .call_builtin = .{
        .dest = 1,
        .name = "List.length",
        .args = args,
        .arg_modes = arg_modes,
    } }};
    const ownership = [_]ir.OwnershipClass{ .owned, .trivial };
    var function = try buildTestFunction(arena, "no_send", &stream, &ownership);
    try verifyFunctionStandalone(testing.allocator, &function);
}

test "C1 accepts a borrowed message passed to the copy-send by borrow (shipping shape)" {
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // %0 = pid bits (trivial), %1 = borrowed message (String/List), %2 = send result.
    // This is the shape P2-J5 actually emits: the message is `Process.send`'s
    // `.borrowed` param, passed by `.borrow`.
    const send = try buildCopySend(arena, 0, 1, .borrow, 2);
    const stream = [_]ir.Instruction{send};
    const ownership = [_]ir.OwnershipClass{ .trivial, .borrowed, .trivial };
    var function = try buildTestFunction(arena, "borrowed_copy_send_ok", &stream, &ownership);
    try verifyFunctionStandalone(testing.allocator, &function);
}

test "C1 accepts an owned message passed to the copy-send by share" {
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const send = try buildCopySend(arena, 0, 1, .share, 2);
    const stream = [_]ir.Instruction{send};
    const ownership = [_]ir.OwnershipClass{ .trivial, .owned, .trivial };
    var function = try buildTestFunction(arena, "owned_copy_send_share_ok", &stream, &ownership);
    try verifyFunctionStandalone(testing.allocator, &function);
}

test "C1 ignores a trivial scalar message even when passed by move" {
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // A scalar (i64/Atom) message: `.trivial`. `.move` mode is a
    // harmless bit-copy — C1 must NOT fire.
    const send = try buildCopySend(arena, 0, 1, .move, 2);
    const stream = [_]ir.Instruction{send};
    const ownership = [_]ir.OwnershipClass{ .trivial, .trivial, .trivial };
    var function = try buildTestFunction(arena, "scalar_move_send_ok", &stream, &ownership);
    try verifyFunctionStandalone(testing.allocator, &function);
}

test "C1 rejects an ARC message moved into the copy-send by ValueMode" {
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // Regression guard: a future pass moves an owned ARC value into the
    // copy-send. The copy-send never releases it → leak/double-free.
    const send = try buildCopySend(arena, 0, 1, .move, 2);
    const stream = [_]ir.Instruction{send};
    const ownership = [_]ir.OwnershipClass{ .trivial, .owned, .trivial };
    var function = try buildTestFunction(arena, "arc_move_send_bad", &stream, &ownership);

    var guard = SuppressDiagnostics.init();
    defer guard.deinit();
    try testing.expectError(
        error.ConcurrencyInvariantViolation,
        verifyFunctionStandalone(testing.allocator, &function),
    );
}

test "C1 rejects an ARC message produced by move_value even if the arg mode is borrow" {
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // %1 is produced by a `.move_value` (consuming %0's +1) then handed
    // to the copy-send with a `.borrow` mode. The realized move is the
    // violation regardless of the declared mode.
    const send = try buildCopySend(arena, 3, 1, .borrow, 2);
    const stream = [_]ir.Instruction{
        .{ .move_value = .{ .dest = 1, .source = 0 } },
        send,
    };
    const ownership = [_]ir.OwnershipClass{ .owned, .owned, .trivial, .trivial };
    var function = try buildTestFunction(arena, "arc_move_value_send_bad", &stream, &ownership);

    var guard = SuppressDiagnostics.init();
    defer guard.deinit();
    try testing.expectError(
        error.ConcurrencyInvariantViolation,
        verifyFunctionStandalone(testing.allocator, &function),
    );
}

test "C1 checks a send nested inside an if_expr arm" {
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // The send lives in the then-arm of an if_expr: the recursive walk
    // must descend into arm streams (parity with the ARC verifier).
    const send = try buildCopySend(arena, 0, 1, .move, 2);
    const then_instrs = try arena.dupe(ir.Instruction, &[_]ir.Instruction{send});
    const stream = [_]ir.Instruction{.{ .if_expr = .{
        .dest = 4,
        .condition = 3,
        .then_instrs = then_instrs,
        .then_result = 2,
        .else_instrs = &.{},
        .else_result = null,
    } }};
    const ownership = [_]ir.OwnershipClass{ .trivial, .owned, .trivial, .trivial, .trivial };
    var function = try buildTestFunction(arena, "nested_send_bad", &stream, &ownership);

    var guard = SuppressDiagnostics.init();
    defer guard.deinit();
    try testing.expectError(
        error.ConcurrencyInvariantViolation,
        verifyFunctionStandalone(testing.allocator, &function),
    );
}

// ---- Phase-3-activated scaffold tests -------------------------------
//
// These exercise the SCAFFOLDED C2/C3 passes by directly synthesizing a
// `.move` send site (no lowering produces one in Phase 2). They lock in
// the scaffold's behavior so Phase 3's move-send job — which only needs
// to teach `classifySendPrimitive` the move primitive — activates a
// verified pass. They also DOCUMENT the Phase-2 soundness: under the
// copy-send, a borrowed message is accepted (it is the normal case).

test "Phase 2: no lowering classifies as a move-send (C2/C3 dormant)" {
    // The seam that keeps C2/C3 inactive in Phase 2 is the classifier:
    // the only send primitive that exists lowers to `.copy`.
    const copy = classifySendPrimitive(COPY_SEND_PRIMITIVE_BUILTIN_NAME).?;
    try testing.expectEqual(SendKind.copy, copy.kind);
}

test "C2 (Phase-3 scaffold): a borrowed message MOVE-sent is rejected" {
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // Synthesize a move-send by name so the classifier yields `.move`.
    const args = try arena.alloc(ir.LocalId, 2);
    args[0] = 0;
    args[1] = 1;
    const arg_modes = try arena.alloc(ir.ValueMode, 2);
    arg_modes[0] = .move;
    arg_modes[1] = .move;
    const stream = [_]ir.Instruction{.{ .call_builtin = .{
        .dest = 2,
        .name = MOVE_SEND_PRIMITIVE_BUILTIN_NAME,
        .args = args,
        .arg_modes = arg_modes,
    } }};
    const ownership = [_]ir.OwnershipClass{ .trivial, .borrowed, .trivial };
    var function = try buildTestFunction(arena, "borrowed_move_send_bad", &stream, &ownership);

    var guard = SuppressDiagnostics.init();
    defer guard.deinit();
    try testing.expectError(
        error.ConcurrencyInvariantViolation,
        verifyFunctionStandalone(testing.allocator, &function),
    );
}

test "C2 (Phase-3 scaffold): an owned message MOVE-sent is accepted" {
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const args = try arena.alloc(ir.LocalId, 2);
    args[0] = 0;
    args[1] = 1;
    const arg_modes = try arena.alloc(ir.ValueMode, 2);
    arg_modes[0] = .move;
    arg_modes[1] = .move;
    const stream = [_]ir.Instruction{.{ .call_builtin = .{
        .dest = 2,
        .name = MOVE_SEND_PRIMITIVE_BUILTIN_NAME,
        .args = args,
        .arg_modes = arg_modes,
    } }};
    // An owned, uniquely-owned message is exactly what a move-send may
    // transfer. (Full region-closure — no external in-pointers — is the
    // Phase-3 uniqueness prover's job; C2 governs the borrowed rejection.)
    const ownership = [_]ir.OwnershipClass{ .trivial, .owned, .trivial };
    var function = try buildTestFunction(arena, "owned_move_send_ok", &stream, &ownership);
    try verifyFunctionStandalone(testing.allocator, &function);
}

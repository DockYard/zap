# =====================================================================
# Phase-3-activated compile-fail FIXTURE for P2-J7's scaffolded send
# verifier passes (`src/concurrency_verifier.zig`, invariants C2 + C3).
#
# WRITTEN, NOT RUN. This file lives under `phase3_move_send_fixtures/`
# and is named `*_fixture.zap`, so the `test/concurrency/**/*_test.zap`
# runner glob NEVER compiles or runs it. It is a reference fixture that
# captures the exact source shapes Phase 3 will reject, so Phase 3's
# move-send job (plan item 3.3 — the O(1) region-move send) wires them
# into `src/zir_integration_tests.zig` rather than authoring them fresh.
#
# WHY IT COMPILES CLEANLY TODAY (and is therefore not yet a compile-fail
# test): under the Phase-2 deep-COPY send, every send below is SOUND —
# the copy-send BORROWS its message (reads it to serialize a fresh,
# independent copy for the receiver; the sender's original is untouched
# and freed by its own end-of-scope release). Borrowed-at-send and
# use-after-send are only hazards under a MOVE-send, which does not
# exist in Phase 2. `classifySendPrimitive` recognizes only the `.copy`
# primitive, so invariants C2/C3 are dormant.
#
# HOW PHASE 3 ACTIVATES THE REJECTIONS: the move-send job lands a MOVE
# send primitive and teaches `classifySendPrimitive` its lowered builtin
# name (the reserved `MOVE_SEND_PRIMITIVE_BUILTIN_NAME` seam). At that
# point the verifier classifies a move-send as `.move` and:
#
#   * C2 ("no borrowed value reaches a move-send") rejects
#     `forward_by_move` below: `values` is a borrowed parameter — the
#     sender does not own the `+1` to transfer across the boundary.
#     Expected diagnostic substring:
#         "violates send invariant C2"
#         "message local %N is .borrowed — the sender does not own the +1 to transfer"
#
#   * C3 ("use-after-move across send") rejects `reuse_after_move` below:
#     an owned value MOVE-sent is consumed, so the subsequent
#     `List.length(payload)` is a use-after-move — exactly as the
#     existing move checker (`src/types.zig` `ensureBindingAvailable`)
#     catches elsewhere, extended to the send boundary.
#     Expected diagnostic substring (via the extended move checker):
#         "was already moved"  /  "used after move"
#
# WIRING (Phase 3): for each case add, in `src/zir_integration_tests.zig`,
#   try expectGatedCompileFailsWithDiagnostic(<source>, <substring>);
# using the gate-ON helper (these require `runtime_concurrency: true`).
#
# The bodies below deliberately mirror the VALIDATED positive test
# `send_ownership_test.zap::forward_and_measure`, so this fixture stays
# syntactically sound even though no build target compiles it.
# =====================================================================

pub struct Concurrency.Phase3MoveSendFixture {
  # C2 case — a BORROWED parameter forwarded into a send. Sound under
  # the Phase-2 copy-send (accepted by `send_ownership_test.zap`);
  # rejected by C2 once `Process.send` of a last-use value lowers to the
  # Phase-3 move-send, because a borrow carries no ownership unit to move.
  pub fn forward_by_move(values :: [i64]) -> i64 {
    self_pid = (Pid.of(Process.self()) :: Pid([i64]))
    _sent = Process.send(self_pid, values)
    _drained = receive [i64] {
      got -> got
    }
    List.length(values)
  }

  # C3 case — reuse of an OWNED value after sending it. Sound under the
  # Phase-2 copy-send (the copy borrows; the original survives — see
  # `send_ownership_test.zap`); rejected by the use-after-move checker
  # once the send MOVES the owned last-use value in Phase 3.
  pub fn reuse_after_move() -> i64 {
    payload = [1, 2, 3]
    self_pid = (Pid.of(Process.self()) :: Pid([i64]))
    _sent = Process.send(self_pid, payload)
    _drained = receive [i64] {
      got -> got
    }
    List.length(payload)
  }
}

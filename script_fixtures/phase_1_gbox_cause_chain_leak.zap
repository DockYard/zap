# G3 leak verification for the G-box box-in-container ARC glue.
#
# Each `pub error` auto-injects `cause :: Option(Error) = Option.None`,
# which lowers to a `union(enum){Some: ProtocolBox, None}` field. A
# present cause holds a heap-allocated, ARC-managed inner error boxed as
# a `ProtocolBox`. When the outer error is dropped at scope exit, the
# runtime's generic ARC deep-walk must:
#
#   1. walk the `cause` union to its active variant,
#   2. recognise the `ProtocolBox` payload,
#   3. dispatch the box's vtable `__box_header__.drop`, which releases
#      the concrete inner error,
#   4. recurse if that inner error itself carries a cause.
#
# Before the G-box fix this `@compileError`d (a `ProtocolBox` reaching
# the generic `retainAny`/`releaseAny` dispatchers, which only accept
# single-item pointers). The fix adds the `ProtocolBoxVTableHeader` ABI +
# by-value-aggregate + union-variant routing in the runtime deep-walk so
# the box's vtable `__drop__` runs the inner's release. Under the
# production default `Memory.ARC` manager this runs clean end-to-end (the
# struct's scope-exit release deep-walks `cause` -> box -> `__drop__`,
# balanced — no crash, no double-free; the V1-V11 ARC verifiers pass).
#
# NOTE on `Memory.Tracking`: Tracking declares ZERO capabilities, so the
# Phase 6 codegen elision (spec 8.5) statically removes EVERY plain
# scope-exit `.release` (the box-in-struct deep-walk trigger) — this is
# the same elision that removes Map/List releases. Consequently a
# container-owned box's `allocAny` inner is not `core.deallocate`d under
# Tracking and shows as a `LEAK:`. This is a Phase-6-elision-vs-lifecycle-
# pairing interaction (not a G-box ABI defect) deferred to the Phase 4
# leak/cycle subsystem; the box's OWN scope-exit drop (call-arg / local
# box) bypasses elision via `protocol_box_drop` and IS Tracking-clean.
#
# Three shapes:
#   * `solo`  — a None-cause error (no box; the trivial baseline).
#   * `pair`  — outer -> Some(inner), one box.
#   * `triple`— outer -> Some(middle) -> Some(inner), two nested boxes.
#
# Each binding goes out of scope at the end of `main/1`, so the runtime
# tears all three down deterministically.

pub error Leaf {}

pub error Mid {}

pub error Top {}

fn main(_args :: [String]) -> u8 {
  solo = %Leaf{}

  pair = %Top{cause: Option.Some(%Leaf{})}

  triple = %Top{cause: Option.Some(%Mid{cause: Option.Some(%Leaf{})})}

  IO.puts(Atom.to_string(Error.kind(solo)))
  IO.puts(Atom.to_string(Error.kind(pair)))
  IO.puts(Atom.to_string(Error.kind(triple)))
  0
}

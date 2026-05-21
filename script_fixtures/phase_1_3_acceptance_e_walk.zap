# Phase 1.2.5.e Acceptance Test E (cause chain end-to-end).
#
# Status after the Phase 1.2.5 Gap-Analysis round:
#
# - Phase 1.2.5 Gap 1 (LLVM panic on `pub error` construction) is
#   closed; minimal `pub error MyError {}` + `%MyError{}` now `zap
#   run`s cleanly (see `phase_1_2_5_gap1_minimal_pub_error.zap`).
# - Phase 1.2.5 Gap 2 (type-checker rejected `inner` binding in
#   `case Option.Some(inner) -> Error.kind(inner)` on
#   `Option(protocol_constraint(Error))`) is closed at the type
#   level: the patched `TypeChecker.inferExpr` resolves the
#   protocol's declared return type for `Error.source(e)` and the
#   downstream `Error.kind(inner)` typechecks cleanly.
# - The remaining gap to run this fixture end-to-end via `zap run`
#   is the construction-site auto-boxing at call arguments:
#   `Demo.walk(%Outer{})` requires the concrete `Outer` value to
#   auto-box into `runtime.ProtocolBox(Error)` at the call site
#   (the parameter expects `protocol_constraint(Error)`). The
#   struct-literal and union-variant paths already auto-box at
#   construction sites (Phase 1.2.5.c); extending the same
#   coercion to call arguments where the IR's
#   `callTargetExpectedType` resolves cross-struct script-mode
#   calls is the open follow-up tracked under Phase 1 gap analysis
#   loop (task #17).
#
# The closing acceptance for the Phase 1.2.5 protocol-existentials
# project: with `cause :: Option(Error) = Option.None` auto-injected
# into every `pub error` (Phase 1.2.5.e) and the full A→B→C→D
# dispatch stack landed in 1.2.5.a-d, an outer error can carry an
# inner error via its `cause` field and a caller can walk the chain
# at runtime through `Error.source/1` and protocol-box dispatch.
#
# Once the call-site auto-box gap closes, the expected output is:
#
#   inner
#   0
#
# `walk(outer)` extracts `outer.cause`, pattern-matches the
# `Option.Some(inner)` arm, and reads back the inner error's kind
# atom via `Error.kind(inner)` (which dispatches through the
# protocol_box vtable populated at construction time).
#
# A second call exercises the no-cause case to confirm the default
# `Option.None` path also works end-to-end.

pub error Inner {}

pub error Outer {}

pub struct Demo {
  pub fn walk(e :: Error) -> String {
    case Error.source(e) {
      Option.Some(inner) -> Atom.to_string(Error.kind(inner))
      Option.None -> "no_cause"
    }
  }
}

fn main(_args :: [String]) -> u8 {
  outer = %Outer{cause: Option.Some(%Inner{})}
  IO.puts(Demo.walk(outer))
  lonely = %Inner{}
  IO.puts(Demo.walk(lonely))
  0
}

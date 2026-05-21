# Phase 1.2.5.e Acceptance Test E (cause chain end-to-end).
#
# The closing acceptance for the Phase 1.2.5 protocol-existentials
# project: with `cause :: Option(Error) = Option.None` auto-injected
# into every `pub error` (Phase 1.2.5.e) and the full A→B→C→D
# dispatch stack landed in 1.2.5.a-d, an outer error can carry an
# inner error via its `cause` field and a caller can walk the chain
# at runtime through `Error.source/1` and protocol-box dispatch.
#
# The expected output is:
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

# Phase 4.c box-in-struct fix — double-free / regression stress.
#
# Exercises the ownership-transfer edge the box-in-struct deep-release fix
# must not break: a box that is BOTH used as a separate value AND consumed
# into a container, plus a box passed as a borrowed call argument, plus a
# used cause-chain. Under `Memory.Tracking` every owned allocation must be
# freed exactly once — no leak, no double-free (a double-free trips the
# canary `INVALID FREE` / `USE-AFTER-FREE` path or aborts).
#
# Expected under -Dmemory=Memory.Tracking: prints the three lines, ZERO
# leaks, no canary fault, exit 0.

@code Z9201
pub error Inner {}

@code Z9202
pub error Outer {}

pub struct Demo {
  pub fn kind_of(e :: Error) -> String {
    Atom.to_string(Error.kind(e))
  }

  pub fn walk(e :: Error) -> String {
    case Error.source(e) {
      Option.Some(inner) -> Atom.to_string(Error.kind(inner))
      Option.None -> "no_cause"
    }
  }
}

fn main(_args :: [String]) -> u8 {
  # Box as a borrowed call argument (the box-as-call-arg path:
  # unconditional .protocol_box_drop, no container).
  IO.puts(Demo.kind_of(%Inner{}))

  # Box consumed into a container, and the container is then walked
  # (the box-in-struct deep-release path the fix targets).
  outer = %Outer{cause: Option.Some(%Inner{})}
  IO.puts(Demo.walk(outer))

  # A second container with no cause (the Option.None box path).
  bare = %Outer{}
  IO.puts(Demo.walk(bare))
  0
}

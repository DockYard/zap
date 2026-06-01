# Phase 2 acceptance — an UNKNOWN capability atom in `@available_on` is a
# precise compile error at the attribute, on EVERY target (it is malformed
# regardless of the build target), never a crash and never silent acceptance.
# `:telepathy` is not a known capability.
#
# Expected: fails to compile on every target with "unknown capability
# `:telepathy`" listing the valid capabilities.

pub struct Widget {
  @available_on(:telepathy)

  pub fn ping() -> String { "pong" }
}

fn main(args :: [String]) -> u8 {
  IO.puts(Widget.ping())
  0
}

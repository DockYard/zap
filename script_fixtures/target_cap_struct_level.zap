# Phase 2 acceptance — a STRUCT-level `@available_on` gates EVERY member, even
# a method with no attribute of its own. `Tty` is gated `@available_on(:terminal)`
# at the struct level; `Tty.read_key/0` carries no own gate but inherits the
# struct's. On wasi any member reference is the capability diagnostic; on native
# it compiles + runs.
#
# Expected: native prints "tty-ok"; wasm32-wasi FAILS naming `Tty.read_key/0`.

pub struct Tty {
  @available_on(:terminal)

  pub fn read_key() -> String { "tty-ok" }
  pub fn write_key(s :: String) -> Nil { nil }
}

fn main(args :: [String]) -> u8 {
  IO.puts(Tty.read_key())
  0
}

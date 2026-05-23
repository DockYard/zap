# Phase 4.c acceptance — a clean program that allocates and frees with no
# survivors. Under `Memory.Tracking` the leak report must be EMPTY and the
# process must exit 0 (no `--leaks-fatal` escalation, no `LEAK:` lines, no
# unified leak diagnostic).
#
# The program does only stack-resident integer arithmetic plus `IO.puts`
# (whose buffers are freed on the stdout-flush atexit path), so no
# heap-resident user value survives to `core.deinit`.

pub struct Adder {
  pub fn sum(a :: i64, b :: i64) -> i64 {
    a + b
  }
}

fn main(_args :: [String]) -> u8 {
  total = Adder.sum(2, 3)
  IO.puts("clean")
  0
}

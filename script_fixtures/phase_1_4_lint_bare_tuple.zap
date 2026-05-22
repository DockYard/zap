# Phase 1.4 lint (warn-only): bare `{:ok, _}` / `{:error, _}` tuple
# patterns.
#
# `classify/1` pattern-matches on the legacy `{:ok, _}` / `{:error, _}`
# tuple idiom. The compiler emits WARNINGS suggesting a migration to
# `Result(t, e)` (via `Result.tuple_to_result/1`), but the program still
# compiles and runs.
#
# Expected: two `warning:` lines (one per bare tuple pattern); the
# program then runs and prints `ok:42`.

pub struct Demo {
  pub fn classify(t :: {Atom, i64}) -> String {
    case t {
      {:ok, v} -> "ok:" <> Integer.to_string(v)
      {:error, e} -> "err:" <> Integer.to_string(e)
    }
  }
}

fn main(_args :: [String]) -> u8 {
  IO.puts(Demo.classify({:ok, 42}))
  0
}

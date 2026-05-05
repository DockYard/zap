## Computer Language Benchmarks Game — binary-trees.
##
## Exercises the recursive-struct codegen path:
##   * `Tree | nil` field storage gets `FieldStorage.indirect` so
##     the layout cycle compiles.
##   * Construction at every depth runs through the runtime
##     allocator (`ArcRuntime.allocAny`) — a stack alloc would
##     dangle once `make` returns.
##   * Every read of a child field auto-derefs `?*const Tree → ?Tree`,
##     and the multi-clause `check(nil) / check(t :: Tree)` shape
##     unifies the dispatch parameter to `?Tree`.
##
## Standard CLBG output: stretch tree at max_depth + 1, table of
## trees per depth, then the long-lived tree.

pub struct BinaryTrees {
  pub struct Tree {
    left :: Tree | nil
    right :: Tree | nil
  }

  pub fn make(0 :: i64) -> Tree {
    %Tree{left: nil, right: nil}
  }

  pub fn make(d :: i64) -> Tree {
    %Tree{left: BinaryTrees.make(d - 1), right: BinaryTrees.make(d - 1)}
  }

  pub fn check(nil) -> i64 {
    0 :: i64
  }

  pub fn check(t :: Tree) -> i64 {
    one = 1 :: i64
    one + BinaryTrees.check(t.left) + BinaryTrees.check(t.right)
  }

  pub fn iter(0 :: i64, _depth :: i64, acc :: i64) -> i64 {
    acc
  }

  pub fn iter(remaining :: i64, depth :: i64, acc :: i64) -> i64 {
    BinaryTrees.iter(remaining - 1, depth, acc + BinaryTrees.check(BinaryTrees.make(depth)))
  }

  ## Print the per-depth row in the canonical CLBG format.
  pub fn print_row(count :: i64, depth :: i64, check_sum :: i64) -> String {
    msg = Integer.to_string(count) <> "\t trees of depth " <> Integer.to_string(depth) <> "\t check: " <> Integer.to_string(check_sum)
    IO.puts(msg)
  }

  pub fn run_depth(depth :: i64, max_depth :: i64) -> String {
    iterations = BinaryTrees.iterations_for(depth, max_depth)
    check_sum = BinaryTrees.iter(iterations, depth, 0 :: i64)
    BinaryTrees.print_row(iterations, depth, check_sum)
  }

  pub fn iterations_for(depth :: i64, max_depth :: i64) -> i64 {
    BinaryTrees.shift_left(1 :: i64, max_depth - depth + 4)
  }

  pub fn shift_left(value :: i64, 0 :: i64) -> i64 {
    value
  }

  pub fn shift_left(value :: i64, bits :: i64) -> i64 {
    BinaryTrees.shift_left(value * 2, bits - 1)
  }

  pub fn loop_depths(depth :: i64, max_depth :: i64) -> i64 {
    if depth > max_depth {
      0 :: i64
    } else {
      _row = BinaryTrees.run_depth(depth, max_depth)
      BinaryTrees.loop_depths(depth + 2, max_depth)
    }
  }

  pub fn main(_args :: [String]) -> String {
    max_depth = BinaryTrees.depth_from_env()
    min_depth = 4 :: i64
    stretch_depth = max_depth + 1

    stretch_check = BinaryTrees.check(BinaryTrees.make(stretch_depth))
    IO.puts("stretch tree of depth " <> Integer.to_string(stretch_depth) <> "\t check: " <> Integer.to_string(stretch_check))

    long_lived = BinaryTrees.make(max_depth)

    _ = BinaryTrees.loop_depths(min_depth, max_depth)

    long_check = BinaryTrees.check(long_lived)
    IO.puts("long lived tree of depth " <> Integer.to_string(max_depth) <> "\t check: " <> Integer.to_string(long_check))
  }

  ## Read depth from `BENCH_DEPTH` — the harness convention used
  ## by every peer implementation. Default 14 keeps `zap run`-style
  ## smoke checks sub-second.
  pub fn depth_from_env() -> i64 {
    raw = System.get_env("BENCH_DEPTH")
    if raw == "" {
      14 :: i64
    } else {
      Integer.parse(raw)
    }
  }
}

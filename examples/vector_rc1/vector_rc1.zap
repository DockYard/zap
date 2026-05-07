@doc = """
  Phase 2 sanity: stress Vector's rc-1 fast path.

  Allocates a uniquely-owned `VectorI64` and runs a tight `set` loop
  on it. Each successive `set` should hit the rc-1 branch in
  `runtime.Vector(i64).set` and rewrite the live buffer in place
  (returning the same pointer). After the loop the vector contains
  twice the index `0..n-1`. We sum them back through `get` and
  print one line so a build that compiles without exercising the
  function body still fails its byte-exact comparison.

  Run with `ZAP_ARC_STATS=1` to see the rc-1 fast-path hit rate:

      ZAP_ARC_STATS=1 ./zap-out/bin/vector_rc1
      total=9900
      [zap-arc-stats] vector_mut_calls_total=100 vector_rc1_fast_path_total=100
  """

pub struct VectorRc1 {
  fn fill_in_place(v :: VectorI64, i :: i64, n :: i64) -> VectorI64 {
    case i < n {
      true -> fill_in_place(VectorI64.set(v, i, i * 2), i + 1, n)
      false -> v
    }
  }

  fn sum_get(v :: VectorI64, i :: i64, n :: i64, acc :: i64) -> i64 {
    case i < n {
      true -> sum_get(v, i + 1, n, acc + VectorI64.get(v, i))
      false -> acc
    }
  }

  pub fn main(_args :: [String]) -> String {
    n = 100 :: i64
    v = VectorI64.new_filled(n, 0 :: i64)
    v = fill_in_place(v, 0, n)
    total = sum_get(v, 0, n, 0)
    "total=#{total}" |> IO.puts()
  }
}

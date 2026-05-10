@doc = """
  Stress List's rc-1 fast path.

  Allocates a uniquely-owned `List(i64)` and runs a tight `set` loop
  on it. Each successive `set` should hit the rc-1 branch in the
  runtime and rewrite the live buffer in place. After the loop the
  list contains twice the index `0..n-1`; the sum is printed so the
  generated binary has a byte-exact observable result.

  Run with `ZAP_ARC_STATS=1` to see the rc-1 fast-path hit rate:

      ZAP_ARC_STATS=1 ./zap-out/bin/list_rc1
      total=9900
      [zap-arc-stats] list_mut_calls_total=100 list_rc1_fast_path_total=100
  """

pub struct ListRc1 {
  fn fill_in_place(values :: List(i64), index :: i64, limit :: i64) -> List(i64) {
    case index < limit {
      true -> fill_in_place(List.set(values, index, index * 2), index + 1, limit)
      false -> values
    }
  }

  fn sum_get(values :: List(i64), index :: i64, limit :: i64, accumulator :: i64) -> i64 {
    case index < limit {
      true -> sum_get(values, index + 1, limit, accumulator + List.get(values, index))
      false -> accumulator
    }
  }

  pub fn main(_args :: [String]) -> String {
    limit = 100 :: i64
    values = List.new_filled(limit, 0 :: i64)
    values = fill_in_place(values, 0, limit)
    total = sum_get(values, 0, limit, 0)
    "total=#{total}" |> IO.puts()
  }
}

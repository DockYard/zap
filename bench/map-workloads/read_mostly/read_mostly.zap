@doc = """
  Phase B1.3 — read-mostly micro-benchmark.

  Builds a small Map then performs many size queries on the final
  map. The build phase is a working-dict pattern (no parking) and
  the read phase fires no mutations. The classifier reports zero
  post-share mutations and no class-V instances; the final map's
  `gets` field grows as `Map.size` is queried hundreds of times per
  lineage (visible via the `ZAP_INSTRUMENT_DETAIL=1` JSONL output).
  """

pub struct ReadMostly {
  fn step(map :: %{Atom => i64}, remaining :: i64, accumulated :: i64) -> i64 {
    s = Map.size(map)
    read_loop(map, remaining - 1, accumulated + s)
  }

  fn read_loop(map :: %{Atom => i64}, remaining :: i64, accumulated :: i64) -> i64 {
    case remaining {
      0 -> accumulated
      _ -> step(map, remaining, accumulated)
    }
  }

  fn build_then_read() -> i64 {
    m0 = %{counter: 0}
    m1 = Map.put(m0, :a, 1)
    m2 = Map.put(m1, :b, 2)
    m3 = Map.put(m2, :c, 3)
    m4 = Map.put(m3, :d, 4)
    m5 = Map.put(m4, :e, 5)
    m6 = Map.put(m5, :f, 6)
    m7 = Map.put(m6, :g, 7)
    m8 = Map.put(m7, :h, 8)
    read_loop(m8, 200, 0)
  }

  fn run_many(remaining :: i64, accumulated :: i64) -> i64 {
    case remaining {
      0 -> accumulated
      _ -> run_many(remaining - 1, accumulated + build_then_read())
    }
  }

  pub fn main(_args :: [String]) -> u8 {
    total = run_many(20, 0)
    "total=#{total}" |> IO.puts()
    0
  }
}

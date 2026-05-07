@doc = """
  Phase B1.1 — pure working-dict micro-benchmark.

  Allocates a Map literal and grows it via `Map.put` in a tight chain.
  Each derived map immediately replaces its predecessor in the only
  binding that holds it; nothing parks an older version in a list,
  struct, or other container, so no cell ever has more than one
  long-lived owner. The classifier reports every instance as class S
  (`had_share_event=false`) and every lineage as class W (a single
  monotonically-evolving working dictionary).
  """

pub struct WorkingDict {
  fn build_one() -> i64 {
    m0 = %{counter: 0}
    m1 = Map.put(m0, :a, 1)
    m2 = Map.put(m1, :b, 2)
    m3 = Map.put(m2, :c, 3)
    m4 = Map.put(m3, :d, 4)
    m5 = Map.put(m4, :e, 5)
    m6 = Map.put(m5, :f, 6)
    m7 = Map.put(m6, :g, 7)
    m8 = Map.put(m7, :h, 8)
    Map.size(m8)
  }

  fn run_many(remaining :: i64, accumulated :: i64) -> i64 {
    case remaining {
      0 -> accumulated
      _ -> run_many(remaining - 1, accumulated + build_one())
    }
  }

  pub fn main(_args :: [String]) -> String {
    total = run_many(60, 0)
    "total=#{total}" |> IO.puts()
  }
}

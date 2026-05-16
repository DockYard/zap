@doc = """
  Phase B1.2 — persistent-versioned micro-benchmark.

  A `Snapshot` struct holds a Map field, parking a long-lived owner
  next to the local that derives new versions. The struct field
  retain runs through `retainAnyPersistent`, so each parked map is
  observed at strong_count >= 2 at the moment of any subsequent
  `Map.put` against it. The classifier records the resulting
  sharing-then-mutation pattern as class V. Each lineage parks
  several intermediate versions in their own snapshots before a put
  fires on them, producing many class-V instances per lineage.
  """

pub struct Snapshot {
  parked :: %{Atom => i64}
}

pub struct Versioned {
  fn step(parked :: %{Atom => i64}, snap :: Snapshot, remaining :: i64, accumulated :: i64) -> i64 {
    derived_from_local = Map.put(parked, :version, remaining)
    derived_from_snap = Map.put(snap.parked, :alt, remaining)
    new_snap = %Snapshot{parked: derived_from_local}
    fork_versions(derived_from_snap, new_snap, remaining - 1, accumulated + Map.size(derived_from_local) + Map.size(derived_from_snap))
  }

  fn fork_versions(parked :: %{Atom => i64}, snap :: Snapshot, remaining :: i64, accumulated :: i64) -> i64 {
    case remaining {
      0 -> accumulated + Map.size(snap.parked) + Map.size(parked)
      _ -> step(parked, snap, remaining, accumulated)
    }
  }

  fn one_lineage() -> i64 {
    seed = %{counter: 0, version: 0}
    snap = %Snapshot{parked: seed}
    fork_versions(seed, snap, 5, 0)
  }

  fn run_many(remaining :: i64, accumulated :: i64) -> i64 {
    case remaining {
      0 -> accumulated
      _ -> run_many(remaining - 1, accumulated + one_lineage())
    }
  }

  pub fn main(_args :: [String]) -> u8 {
    total = run_many(40, 0)
    "total=#{total}" |> IO.puts()
    0
  }
}

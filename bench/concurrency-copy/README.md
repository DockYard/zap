# Bench: E6 copy crossover — message-copy latency vs payload size

Phase-2 exit-gate job **P2-J9** of the concurrency campaign
(`docs/concurrency-implementation-plan.md`, plan item **2.8**
"copy-p99-vs-size harness"; the reserved **E6** section of
`docs/concurrency-bench-results.md`). It measures the cost of the deep-copy
message send the P2-J5 walker realizes as *serialize-to-blob* — the plan's
**two copies** (sender serialize + receiver reconstruct) — as a function of
payload size from **64 B to 1 MB**, to find the **crossover**: the size at
which copy cost stops being negligible against the ~44 ns same-scheduler RTT
floor (E1, P1-J6) and starts to dominate. That number drives the Phase-3
prioritization of the `Blob` tier + the O(1) region-move path (risks R4/R5):
an early crossover makes them urgent, a late one lets them be deferred. It
directly quantifies the 2-copy cost the P2-J5 **R4 note** flagged
(`docs/concurrency-implementation-plan.md`, item 2.4 "serialize-to-blob").

## What it measures — the REAL walker, not a synthetic memcpy

The harness links `src/runtime.zig` (the real runtime) against the real
production **ARC manager** (`src/memory/arc/manager.zig`, whose
`zap_memory_section` linker symbol the runtime's weak extern binds), so the
values it copies are real refcounted `List` / `Map` / `String` ARC cells
(`refcount_v1_active == true`) and the two copies are the exact walker passes
`Process.send` / `receive` run (`serializeMessage` / `deserializeMessage`):

| Copy | Where | What |
|---|---|---|
| **A serialize** | `serializeMessage` (sender) | walk source graph, `c_allocator` blob, `writeValue` bytes in |
| **C reconstruct** | `deserializeMessage` (receiver) | allocate FRESH rc=1 ARC cells, copy bytes back out |

Per size it reports the **round-trip** (Copy A + Copy C = the plan's two-copy
cost, the E6 metric) as **median / min / p99**, plus the **serialize-vs-
reconstruct split** (the attribution). The `clock` mode additionally
characterizes the two size-dependent costs the walker bench deliberately
excludes, so the ledger states the full send→receive picture honestly:

* the harness per-op **clock-read floor** (`CLOCK_UPTIME_RAW` quantizes to
  ~42 ns on Apple Silicon — E9), so sub-tick small-size costs are read off the
  clock-overhead-free floor, not the sampled median;
* a bare **`@memcpy`** of the blob — the kernel transport copy (**Copy B**: the
  size-proportional `@memcpy` `zap_proc_send` does into the mailbox ledger,
  `src/runtime/concurrency/abi.zig`) — the third size-dependent memcpy a full
  send→receive pays on top of the two walker copies, on top of the
  payload-independent ~44 ns mailbox RTT E1 already measured.

## Message shapes and sizing to bytes

Three realistic walker-supported shapes; each row is sized so the serialized
blob is as close to the byte target as the grammar allows (the printed
`blob_bytes` is the exact size):

| Shape | Blob layout | elems for target `B` | Stresses |
|---|---|---|---|
| `list` `List(i64)` | `u32` count + `n`·8 | `(B-4)/8` | flat scalars — cheapest (pure memcpy) |
| `map` `Map(i64,i64)` | `u32` count + `n`·16 | `(B-4)/16` | hash-table rebuild on reconstruct |
| `string` `List(String)` | `u32` count + `n`·(4+16) | `(B-4)/20` | one arena allocation per element on reconstruct |

`list` and `map` sweep the full 64 B–1 MB range; `string` is capped at 64 KB
(its reconstruct allocates one arena string per element, so the sweep stays
bounded — the scalar/map sweeps carry the full crossover).

## Build

MUST be compiled with the Zap Zig fork (ledger convention for the concurrency
series; the fork provides the `std.process.Init.Minimal` entry). This bench
uses **no fibers**, so the fork's x30-clobber fix (E9) is not itself required
here — but the fork is what the whole series pins.

The runtime links the real ARC manager for a production-representative
reconstruct substrate; the manager's `zap_memory_section` is force-referenced
from `bench.zig` so its linker symbol is emitted and the runtime's weak extern
binds it.

```sh
~/projects/zig/zig-out/bin/zig build-exe -OReleaseFast --name bench \
  --dep zapruntime --dep zaparcmanager \
  -Mmain=bench.zig \
  --dep zap_active_manager \
  -Mzapruntime=../../src/runtime.zig \
  --dep zap_active_manager \
  -Mzaparcmanager=../../src/memory/arc/manager.zig \
  -Mzap_active_manager=../../src/zap_active_manager_stub.zig
```

## Run

One measurement at a time, foreground; `uptime` recorded immediately before
every invocation (ledger convention). `run-copy-bench.sh` builds then runs all
modes with uptime stamps:

```sh
./run-copy-bench.sh [reps]        # default reps = 7
```

Or individually:

```sh
uptime && ./bench <list|map|string|clock|all> [reps]
```

Defaults: 7 repetitions (≥5 per the ledger; the per-rep median buffer is fixed
at compile time, so `reps` is clamped to 1..=7). Per size: an unrecorded
warmup, then `reps` timed repetitions each collecting a per-op latency sample;
samples are **pooled across reps** and reported as median / min / p99. A
separate **clock-overhead-free floor** (`rt_floor_ns`) times the round trip in
small sub-batches and keeps the MIN per-op across every group and rep — the
un-preempted group is the true cost with neither the ~42 ns per-op clock tick
nor load in it (the load-robust floor the ledger prescribes, and the number
the sub-tick small sizes need).

Timing uses `CLOCK_UPTIME_RAW` directly in the harness, never through the
walker under test. Anti-elision: every reconstructed value's element count is
asserted (forces the copy to run), a checksum of touched bytes is
`doNotOptimizeAway`n and printed, and the `c_allocator` blob and ARC copy are
freed/released each op so the allocations are real.

### `RESULT` line fields

```
RESULT shape=list target=<B> blob_bytes=<n> elems=<n> samples=<reps>x<n>
  rt_median_ns=.. rt_min_ns=.. rt_p99_ns=.. rt_p999_ns=.. rt_max_ns=..
  rt_repmed_ns=<lo>..<hi>   # per-rep median spread (run-to-run stability)
  rt_floor_ns=..            # clock-overhead-free min-of-sub-batches floor
  ser_median_ns=.. ser_min_ns=.. ser_p99_ns=..   # Copy A (serialize)
  de_median_ns=..  de_min_ns=..  de_p99_ns=..     # Copy C (reconstruct)
```

## Substrate honesty note

This is the Phase-2 reality: ONE binary-wide ARC instance (plan item 3.1 makes
managers per-process). The reconstruct path allocates through the production
ARC slab pool, so the cell-allocation cost is representative; `String`
reconstruction lands in the shared `runtime_arena`, which the harness resets
per op (untimed) to keep it bounded.

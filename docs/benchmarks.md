# Benchmarks — Concurrency System

Curated headline results for Zap's concurrency runtime. Every number here is
taken verbatim from the raw measurement ledger,
[docs/concurrency-bench-results.md](concurrency-bench-results.md), which
records the full methodology, build pins, load conditions, and per-run data
for each measurement. This page is the summary; the ledger is the record.

## Measurement conditions (read first)

- **Machine:** MacBook Air (`Mac16,13`), Apple M4, 10 cores, 32 GB RAM,
  macOS 26.2 — the same machine for the whole series.
- **Builds:** `-OReleaseFast` via the fork compiler; timing via
  `CLOCK_UPTIME_RAW`, never through the code under test; warmup then ≥5 timed
  repetitions per measurement.
- **Load discipline:** most sessions ran with other workloads active
  (1-minute load averages are recorded per run in the ledger). Medians carry
  that load; **minima are the load-robust floor**. Paired/interleaved runs are
  used wherever a delta is claimed, so shared load cancels.

## Process kernel: spawn and message round trips

Kernel micro-benchmarks (`bench/concurrency-kernel/`), real scheduler paths —
pid acquisition, PCB init, pooled stacks, real Vyukov mailboxes, futex wake
seam. Spawn rows use the Phase-1 test manager (a cheap per-process manager
init; the ledger's honest caveat).

| Metric | Median (ns) | Min (ns) | Context |
|---|---:|---:|---|
| Spawn, admission only | **11.1** | 10.4 | per spawn; pool-hit steady state, zero pool misses |
| Spawn, full lifecycle (spawn→run→exit→teardown) | **43.0** | 41.7 | serial, per op |
| Spawn, amortized batch lifecycle | 35.1 | 33.4 | batches of 256 |
| Same-scheduler ping-pong RTT | **44.4** | 44.2 | quiet-run converged best case; ~50–90 ns medians under session load (re-adjudicated, ledger P1-R3) |
| Communicating pair on a 2-core M:N pool | 88.2 / 85.5 | 73.2 / 77.9 | two paired runs (P4-J4); **135.6 / 98.1** in the campaign-close re-run under heavier session load (P6-J1) |
| Parked cross-core wake → receive returns | 5,125 / 5,084 | 1,791 / 1,958 | two paired runs; the genuine cross-core premium |

Honest reading of the pool row: the M:N scheduler **collocates** a chatty pair
onto one core by LIFO wake locality (~96% of round trips never cross a core;
15–23 futex parks over 500,000 round trips), so the pool RTT ≈ the
same-scheduler hot path — it is *not* a sustained cross-core figure. The
genuine cross-core cost is the separately measured parked wake (min
**1.79 µs**); a sustained forced-cross RTT is analytically bounded at two
parked wakes ≈ **3.6 µs floor**, not directly measured.

Substrate floors for scale (ledger E9): one-way fiber context switch 3.20 ns,
pooled-stack spawn floor 8.99 ns, Darwin futex parked wake ~917 ns median
(original E9 session; the 7.1a rebuilt-fork re-measurement reproduced the
same floor — 3.31 ns median one-way, 8.40 ns spawn minimum).

## O(1) large-payload moves

A large uniquely-owned flat `List`/`Map` sent with `Process.send_move` moves
its backing region in O(1) — detach from the sender's heap, adopt into the
receiver's — instead of being copied. Manager-level cost: **1–2 ns,
independent of payload size (4 KiB–1 MiB), pointer identity preserved**
(ledger E5). End-to-end, full round trip (two sends + two receives, real
processes and mailboxes, paired run; ledger P6-J1):

| Shape | Size | MOVE RTT (ns, med/min) | COPY RTT (ns, med/min) | Move speedup |
|---|---|---:|---:|---:|
| `Map(i64,i64)` 1,023 entries | 16 KB | 288 / 279 | 87,223 / 86,784 | ~303× |
| `Map(i64,i64)` 4,095 entries | 64 KB | 242 / 241 | 316,192 / 315,472 | ~1,307× |
| `Map(i64,i64)` 16,383 entries | 256 KB | 244 / 242 | 1,257,969 / 1,248,333 | ~5,155× |
| `Map(i64,i64)` 65,535 entries | 1 MB | **255 / 250** | **5,236,423 / 5,214,636** | **~20,535×** |
| `List(i64)` 2,047 elems | 16 KB | 222 / 210 | 11,202 / 10,928 | ~50× |
| `List(i64)` 131,071 elems | 1 MB | 217 / 211 | 341,028 / 337,122 | ~1,572× |
| `Map` 15 entries (slab-backed) | 244 B | 3,809 (degrades to copy) | — | honest fallback |

The move is flat across three orders of magnitude of payload size (a
second, move-only run measured the same rows at 105–119 ns — run-to-run
core-placement variance at this scale; the size-independence and the
orders-of-magnitude gap are the load-robust claims). Small slab-backed values
degrade transparently to the copy path, which is the cheap side of the
crossover. Nested graphs copy, as designed.

Copy-path crossover (ledger E6, gate-ON walker on real ARC cells): flat
`List(i64)` copies stay at or below the ~44 ns RTT floor up to ~256 B and
cross ~2× the floor at ~1 KB; `Map` copies crossed immediately (~256 B) with a
1 MB map send costing 2.19 ms (reconstruct-dominated, 150× a bare `memcpy` of
the same bytes) — the catastrophe the O(1) move above eliminated for
page-backed flat containers.

## Large strings: automatic Blob promotion

A sent `String` at or above **65,536 bytes** (`string_blob_promotion_threshold`)
is automatically promoted to the shared immutable blob tier — one copy, the
last of its cross-process life (ledger P6-J3). One-shot promotion crosses over
against the honest copy substrate between 32 KiB and 64 KiB; the threshold is
the smallest power of two where promotion wins outright, so no one-shot send
regresses at any size. The compounding win: re-sending an already-backed
string is **~42 ns flat at every size** — 165× the copy at 64 KiB, ~2,400× at
1 MB. Locally-constructed strings never touch the tier.

## Safepoint cost when the gate is ON — and zero cost when OFF

Cooperative safepoints are emitted only in gate-on builds. Interleaved paired
runs of gate-off vs gate-on CLBG binaries, same compiler, ARC,
`-Doptimize=ReleaseFast` (ledger E2 + P6-J5 mitigation; medians, 15 reps):

| Benchmark (args) | gate-OFF | gate-ON | Δ |
|---|---:|---:|---|
| **n-body** (5,000,000) | 0.1044 s | 0.1022 s | **−2.1%** (noise) |
| **spectral-norm** (2500) | 0.1638 s | 0.1606 s | **−2.0%** (noise) |
| mandelbrot (4000) | 0.5399 s | 0.5412 s | +0.2% |
| fannkuch-redux (10) | 0.2344 s | 0.2510 s | +7.1% |
| binary-trees (16) | 0.1359 s | 0.1626 s | +19.6% (pre-existing threadlocal-counter cost; plan item 6.6a) |
| k-nucleotide (stdin) | 0.3094 s | 0.3274 s | +5.8% (pre-existing, same cause) |

The E2 kill criterion (>2–3% regression on the n-body/spectral-norm CLBG
wins) is not tripped: the kill-criterion pair is within measurement noise.

**Gate-OFF byte identity (the zero-cost proof).** The CLBG suite runs
gate-off, and gate-off emission is unchanged by the entire campaign: all six
gate-off CLBG binaries have **byte-identical `__TEXT,__text` sections**
(SHA-256 via `segedit`) across pre/post-campaign compilers, and a gate-off
binary carries **zero** `zap_proc_*`/`reduction`/`safepoint` symbols and zero
poll call sites (verified by `nm` and full-disassembly sweep). Zap's CLBG
standing — including the n-body and spectral-norm wins in the cross-language
context run recorded in the ledger — is untouched with the gate off.

## Observability cost

Message-flow tracing (`runtime_tracing: true` / `-Druntime-tracing=on`) costs
**~10–15 ns per trace event** (~20–29 ns per message: its send + receive
events), measured as 40–58 ns added per kernel ping-pong RTT (ledger P6-J6).
The ring is 4096 × 40 B = 160 KiB of BSS, present only in trace-on kernels.
Trace-off kernels contain zero trace instructions (comptime-eliminated;
symbol-absence and byte-identity proven in the ledger).

## Exit-gate verdicts

The campaign's measurement gates, one line each (full method and data in the
ledger):

| Gate | Question | Verdict |
|---|---|---|
| E1 (spawn/RTT) | BEAM-class spawn + send targets (sub-µs–3 µs) | **PASS** — 11.1 ns admission, 44.4 ns RTT; orders of magnitude inside |
| E1 (cross-scheduler) | Cross-scheduler RTT bounded | **PASS** — pair collocates by design; forced-cross bounded ≈3.6 µs floor |
| E2 (safepoints) | >2–3% CLBG regression on n-body/spectral-norm? | **PASS** — −2% (noise) on both |
| E3 (races, both halves) | TSan copy matrix + sender-dies + refcount rule | **PASS** — zero findings across ~20,000 adversarial rounds and 100,000 cross-thread ARC messages |
| E4 (code size) | Manager monomorphization within binary-size budget | **PASS** — post-ICF growth sub-KB on the probe subgraph |
| E5 (region move) | Truly O(1) and leak-free? | **PASS** — 1–2 ns detach+adopt, size-independent, leak-exact |
| E6 (copy crossover) | Crossover documented; ping-pong within target with move on | **Documented + met** — ~1 KB flat / ~256 B map; map catastrophe fixed by the O(1) move |
| E7 (manager-call blocking) | Do manager calls need automatic dirty-scheduler handoff? | **PASS** — no; bounded calls are ~200× under the tick; explicit `Process.blocking` is the mechanism |
| E8 (conservative stack scan) | Can per-process mark-sweep ship? | **PASS** — bounded ~1 µs/KiB, 0/480 false retentions; `Memory.GC` ships, ORC recommended for cycles |
| E10 (alloc dispatch) | Vtable dispatch on the alloc hot path? | **Decision** — +13.8% worst case; hot paths monomorphized, vtable kept for cold paths |

## Honest scope notes

- Spawn numbers were measured with the Phase-1 test manager on the kernel
  path; the real per-spawn manager ABI adds manager-dependent cost (the
  published-context resolution measured at +0.7–2.2% over the ceiling, ledger
  OQ1).
- ORC's user-visible cycle collection is dormant until mutation primitives
  land (Zap surface immutability cannot construct a cycle today); it is proven
  at the manager level and behaves like ARC in the meantime.
- Gate-on Linux is compile-validated (`x86_64-linux-gnu` kernel object +
  final link); gate-on execution on a Linux host awaits the Linux CI leg.
  Windows gate-on is rejected with the scoped port list (plan item 7.2a);
  wasm gate-on is rejected pending a wasm stack-switching substrate.
- Absolute sub-µs numbers on a loaded machine drift; the ledger records load
  per run and the minima are the floor. Re-measure with the committed
  harnesses (`bench/concurrency-kernel/`, `bench/concurrency-copy/`) on a
  quiet machine before comparing against other systems.

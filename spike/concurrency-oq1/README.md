# spike/concurrency-oq1 — A.4 OQ1 current-process resolution (P3-J1)

Throwaway spike (E10 methodology) pricing how the per-process allocation hot
path should resolve the CURRENT-PROCESS private manager context, now that
P3-J1's per-process ARC manager instances make that lookup hot. Appendix A.4
open question 1, re-pointed to Phase 3 by P2-R1/D3.

The identical few-instruction bump allocation is reached through three
context-resolution mechanisms (the allocation body is byte-identical and
inlined in all three, so only the resolution differs):

- `register`  — resolved once (per scheduling quantum) and carried in a
  register/local across the loop. The ceiling the J2 monomorphization /
  parameter-threading arm targets (x18 is Darwin-reserved, so a globally
  reserved register is unavailable; this stands in for "resolved once,
  parameter-threaded").
- `published` — read from a scheduler-published global on every allocation
  (the P3-J1 ship: `zap_proc_active_arc_context`, `src/runtime/concurrency/
  process.zig`; the runtime reads it in `ArcRuntime.currentManagerContext`).
  Modelled as an atomic-monotonic load (aarch64 `LDR`, non-hoisted).
- `ambient`   — a `zap_proc_current()`-style out-of-line C-ABI call per
  allocation (the Phase-2 shape).

## Build + run (fork compiler, ReleaseFast — E10 protocol)

```sh
~/projects/zig/zig-out/bin/zig build-exe --zig-lib-dir ~/projects/zig/lib \
    -OReleaseFast -femit-asm=resolve.s resolve.zig
# one measurement at a time, foreground, quiet machine:
./resolve <pure|mix> <register|published|ambient> [ops] [reps] [manager]
```

`ops` default 100,000,000; `reps` default 5; `manager` default 0 (the real
context; 1 selects the decoy — never in recorded runs, `decoy_allocs=0`
proves it). The build emits `resolve.s` for the asm evidence below (neither
the binary nor `resolve.s` is committed).

## Result (2026-07-07, Apple M4, ReleaseFast, 100 M allocs × 5 reps)

| Shape | Variant | Median ns | Min ns | vs register (median) |
|---|---|---:|---:|---:|
| A pure | register | 1.615 | 1.605 | — |
| A pure | **published** | 1.651 | 1.632 | **+2.2%** |
| A pure | ambient | 1.757 | 1.734 | **+8.8%** |
| B mix | register | 2.004 | 1.957 | — |
| B mix | **published** | 2.019 | 1.984 | **+0.7%** |
| B mix | ambient | 2.067 | 2.050 | **+3.1%** |

Published beats ambient by +6.4% (pure) / +2.4% (mix): a load beats a call,
consistent with E10 (a call cost +6.2% direct / +13.8% vtable there).

## Asm evidence (`resolve.s`)

- `runPurePublished` loop: a per-iteration `ldr x10, [x8, __MergedGlobals…]`
  of `published_context` (the atomic-monotonic load lowered to a plain,
  non-hoisted `LDR`).
- `runPureAmbient` loop: a per-iteration `bl _resolve.ambientCurrentContext`
  (the out-of-line call).
- `runPureRegister` loop: NO per-iteration resolution — the `bl` to resolve
  is hoisted once before the loop.

## Decision

**A.4 OQ1 resolves to the published-per-quantum global.** Published costs
+2.2% (pure) / +0.7% (mix) over the register/parameter ceiling — inside the
E2 kill criterion — while ambient costs +8.8% / +3.1%. P3-J1 ships published;
ambient is rejected. The register/parameter ceiling is the J2 monomorphization
arm's target (recovers the residual +2.2%, worth it only on pure-alloc tight
loops). Full write-up: `docs/concurrency-bench-results.md` § OQ1; plan
amendment: `docs/concurrency-implementation-plan.md` § A.4 OQ1.

# Spike: E10 — vtable dispatch vs monomorphized alloc call

**THROWAWAY SPIKE CODE.** Job S0.4 (experiment E10) of the concurrency
campaign (`docs/concurrency-implementation-plan.md`, Phase 0). This directory
is not product code and is not wired into any build. It is retained as a
substrate-floor reference workload until the Phase 1 kernel implementation
lands (its dispatch-cost floors calibrate the monomorphization hybrid's
hot-path acceptance bar, A.3/3.2); it is deleted after that. Results are
recorded in the E10 section of `docs/concurrency-bench-results.md`.

## What it measures

The manager-monomorphization hybrid (`zap-concurrency-research.md` §2.3)
splits allocation call sites: **hot allocating paths must be monomorphized**
(no dispatch of any kind), while **cold spawn-reachable paths may dispatch
through the process's manager vtable** ("resolve once at spawn, then
indirect-call" — the vtable pointer lives on the process control block). E10
quantifies what that split actually buys/costs: the same few-instruction bump
allocation function (limit check with reset-on-exhaustion over a pre-reserved
1 MiB buffer that never grows during timing) reached through three call
mechanisms:

| Variant | Call mechanism | Models |
|---|---|---|
| `inlined` | comptime-known allocator, callee inlined at the site | today's-Zap monomorphized hot path |
| `direct` | same function behind `noinline`, direct `bl` | call overhead isolated from inlining loss |
| `vtable` | threadlocal `current_process` → `Process.manager_vtable` → fn ptr → `blr` | the §2.3 cold-path dispatch shape |

across two workload shapes:

- **Shape A `pure`** — tight loop of 16-byte allocations, nothing else
  (worst case, maximally dispatch-sensitive; each returned pointer is sunk
  through an empty register-constraint asm so nothing is elided).
- **Shape B `mix`** — allocate 32-byte nodes, write 3 fields each
  (`next`/`value`/`tag`), build 8-node lists, traverse them into a checksum,
  discard (dispatch diluted by real work; checksum sunk via
  `doNotOptimizeAway`).

A decoy second manager (different alloc function, second vtable, selectable
only at runtime via argv; never selected in recorded runs — the RESULT line
prints `decoy_allocs=0` as proof) keeps the vtable and fn-pointer loads
non-constant so LLVM cannot devirtualize the benchmarked indirect call.
Each rep additionally asserts, outside the timed region, that the bump buffer
wrapped (reset_count advanced) — i.e. allocations really executed.

## Build

Compiled with the **fixed fork compiler** from S0.3 (fork `~/projects/zig` @
`74c0b87fe5f2191cef674be63222d90689881648`, the clobber-translation fix,
clean tree):

```sh
~/projects/zig/zig-out/bin/zig build-exe --zig-lib-dir ~/projects/zig/lib \
    -OReleaseFast -femit-asm=dispatch.s dispatch.zig
```

## Run

One measurement at a time, foreground, `uptime` recorded immediately before
each run:

```sh
./dispatch <pure|mix> <inlined|direct|vtable> [ops] [reps] [manager(0|1)]
```

Defaults: 100,000,000 allocations, 5 reps, one unrecorded warmup pass at
ops/10, manager 0 (the real bump manager; manager 1 is the devirtualization
decoy, used only to prove the runtime path is live).

## Asm evidence (aarch64-macos, ReleaseFast, from `dispatch.s`)

Each shape × variant timed loop lives under its own `noinline` symbol
(`_dispatch.runPureInlined` etc.) so the emitted asm is directly attributable.
Verified 2026-07-04 on the build measured in the ledger:

1. **`runPureInlined` — inlining confirmed.** The hot loop contains **no
   call instructions** (the only `bl`s in the function are the two
   `clock_gettime` timer reads outside the loop). Loop body ≈ 10
   instructions: `ldp x13, x12, [x8]` (capacity+offset), `add`/`cmp`/`b.ls`
   limit check, `str` new offset, `ldr` buffer base, `add` result pointer,
   empty-asm sink, `subs`/`b` back-edge; the reset path
   (`ldr`/`add`/`str` of `reset_count`) is inline in the cold arm. The
   allocator state stays memory-resident (load+store per alloc), matching a
   real global/per-process manager.
2. **`runPureDirect` — genuine out-of-line direct call.** Loop =
   `mov w0, #16; bl _dispatch.bumpAllocOutlined; <asm sink>; subs; b.ne`.
   (LLVM interprocedurally const-propagated the `&bump_state` argument away —
   the callee addresses the state globals directly; the callee body is the
   same limit-check/bump/return sequence as the inlined loop.)
3. **`runPureVtable` — double indirection confirmed, per allocation.** Loop
   body: `mov x0, x21; blr x24` (Darwin TLV thunk call for the
   `current_process` threadlocal — descriptor address and thunk pointer are
   hoisted, the thunk **call** executes every iteration), then
   `ldr x8, [x0]` (load the `Process` pointer from the TLS slot),
   `ldp x0, x9, [x8]` (load `manager_context` + `manager_vtable`),
   `ldr x8, [x9]` (load the alloc fn pointer from the vtable),
   `mov w1, #16; blr x8` (indirect call). Two `blr`s per allocation on
   Darwin — the process→vtable→fn-pointer double indirection is present and
   **not devirtualized**.
4. **`runMixInlined`** — the timed loops contain no calls (only the timer
   reads and the cold checksum-zero panic outside).
5. **`runMixDirect`** — the 8-node inner loop is unrolled into 8 direct
   `bl _dispatch.bumpAllocOutlined` calls.
6. **`runMixVtable`** — the TLV thunk call is hoisted to once per 8-alloc
   list iteration, but every allocation still reloads the full dispatch
   chain — `ldr x8, [x22]` (process from the TLS slot; the opaque indirect
   call clobbers memory, so LLVM must reload), `ldp x0, x9, [x8]`
   (context+vtable), `ldr x8, [x9]` (fn ptr), `blr x8` — 8 indirect calls
   per list.

Darwin note: threadlocal access compiles to a call through the TLV thunk
(`_tlv_get_addr`), so part of the measured vtable-variant cost is the
`current_process()` TLS lookup itself, not just the vtable loads — a real
scheduler pays the same unless it keeps the current-process pointer in a
reserved register.

## Result summary

Full tables and the DECISION paragraph live in the E10 section of
`docs/concurrency-bench-results.md`. Headline (median per-alloc ns, Apple M4,
load ~2.0–2.3): pure 1.60 / 1.70 / 1.83 (inlined/direct/vtable) —
vtable = **+13.8%** over inlined; mix 1.89 / 1.94 / 1.98 — vtable = **+4.7%**.

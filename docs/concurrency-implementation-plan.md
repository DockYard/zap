# Zap Concurrency Implementation Plan

**Status: APPROVED — in execution.** (Ratified by the 2026-07-04 implementation directive;
Phase 0 completed 2026-07-05 — see Appendix A and the gap-analysis record in the ledger.)

**Lineage:** `research.md` (round-1 survey) → `research-round-2.md` (round-2 evidence) →
`zap-concurrency-research.md` rev 2 (design positions, all resolved). This document turns those
positions into a phased, testable implementation program. Design rationale is *not* repeated
here — each section cites the position it implements.

**Date basis:** 2026-07-03. Zig substrate facts verified against our fork at `~/projects/zig`
(last local commit 2026-06-16) and the upstream devlog (`ziglang.org/devlog/2026`).

---

## 1. Zig substrate assessment (0.16 fork + 2026 upstream)

What our fork already provides (verified):

| Capability | Where | State |
|---|---|---|
| Stackful fibers (context switch asm) | `lib/std/Io/fiber.zig` | aarch64/x86_64/riscv64; **no wasm** (call stack architecturally inaccessible) |
| `Io.Evented` | `lib/std/Io.zig:31` | macOS/iOS→**Dispatch (GCD)**, Linux→**Uring**, BSDs→**Kqueue**; **Windows→void** |
| Typed futures | `Io.Future(Result)` (`Io.zig:1176`) | await/cancel |
| Union-typed select | `Io.Select(comptime U)` (`Io.zig:1367`) | async/concurrent arms, await/awaitMany/cancel — **the natural lowering target for `receive`/`after`** |
| Task groups | `Io.Group` (`Io.zig:1218`) | async/concurrent/await/cancel — substrate for supervisors |
| MPMC queue | `Io.Queue(Elem)` (`Io.zig:2184`) | plus `QueueClosedError` |
| Structured cancellation | `Io.Cancelable` error set, `io.cancel()` | the kill/shutdown signal |
| Clocks/timeouts | `Io.Clock`, `Timeout`, `sleep`, `operateTimeout` | the `after` substrate |
| Batched I/O ops | `Io.operate`/`Batch` | I/O suspension points |

What the 2026 devlog changes about our plan:

1. **Feb 13, 2026 — io_uring + GCD `std.Io` backends landed, fiber-based, explicitly
   experimental** (error handling, perf diagnostics, coverage gaps). Consequence: our fork has
   the right substrate but we must expect churn; upstream fixes (notably the known io_uring perf
   regression) are cherry-picked continuously rather than waiting for releases.
2. **Upstream is 0.17.0-dev; our fork sits on exactly the 0.16.0 release commit** (merge-base
   `24fdd5b7` = "Release 0.16.0", 2026-04-13, our 66 commits on top; upstream has added 1,262
   commits since, including an **LLVM 21→22 toolchain bump**). A measured July-2026 diff shows
   the surfaces this plan builds on are **nearly frozen** upstream: `Io/fiber.zig` byte-
   identical, the `Evented` backend switch unchanged (still no Windows/IOCP, no wasm fibers),
   `Future`/`Select`/`Queue`/`Cancelable`/`async`/`concurrent` unchanged; the vtable delta is
   one function (`netRead`) folded into the `Operation` union plus two option-type renames.
   Consequence: **build on the 0.16.0-based fork now; do not rebase first.** `std.Io` contact
   stays behind one seam file (`runtime_io.zig`, §4) and the vtable implementation is
   `operate`-centric (§3), so the small upstream drift is absorbed cheaply. The **full rebase
   is a decoupled campaign** — sized Large for reasons unrelated to concurrency (LLVM-22
   bootstrap rebuild; codegen/linker/ZIR-internal churn) — targeting the 0.17.0 release
   (~Q4 2026 on current cadence) at whatever phase boundary is nearest when it ships; it never
   blocks concurrency work.
3. **Jan 31, 2026 — zig libc**: libc functions becoming Zig wrappers, with the stated goal of
   letting `read`/`write` participate in an io_uring event loop. Consequence: long-term, even
   libc-using FFI can suspend cooperatively instead of blocking a scheduler. Near-term the
   dirty/blocking pool (Phase 4) is still required; this devlog item is the eventual path to
   shrinking its use.
4. **Incremental compilation maturity** (`zig build test --watch -fincremental`, 200–300 ms
   incremental links): adopt for the campaign's inner loop where our fork supports it.
5. **Windows:** `Io.Evented` is `void` on Windows in 0.16. v1 posture: Windows processes run on
   `Io.Threaded` (real OS threads, 1:1) as an honest capability-matrix fallback — per-process
   heaps and non-atomic ARC still hold (refcounts stay process-local; only envelope handoff is
   atomic). Fiber+IOCP on Windows is fork work, deferred (Phase 7 stretch).

## 2. Locked design decisions (implemented by this plan)

From `zap-concurrency-research.md` rev 2 §6 — restated as one line each:

1. Manager comptime-resolved at the spawn site (language rule) — **Decision Gate 0, needs
   explicit sign-off with plan approval**. *[Ratified with plan approval, 2026-07-04.]*
2. Monomorphization hybrid: hot allocating paths specialized per reclamation model (≤4); cold
   closure/existential paths dispatch via the process's manager vtable; post-ICF kill criterion.
3. Cross-model traffic: same-model O(1) move ▸ Blob/immutable ▸ lazy per-reachable-pair copy
   stubs; cross-model `move` degrades to copy.
4. Pid invariant: model bits are a function of {slot, generation}; dead-letter on mismatch.
5. Model roster: ARC default; ORC-over-ARC recommended cyclic model (shares REFCOUNTED
   specialization — hypothesis verified in Phase 3); conservative mark-sweep contingent on E8.
6. Safepoints: alloc piggyback + mandatory bare back-edge polls in alloc-free/call-free loops +
   flag-only watchdog; documented latency bound.
7. Receive: exhaustive surface form over the per-process message union + internal
   correlation-token skip under `call`/`Future(T)`; dead-letter unexpected runtime messages.
8. Blob-backed strings: copy-out slices, ~15 B SSO, 64 B promotion threshold, rc==1 in-place
   append, opt-in aliasing view.
9. Wasm/feasibility: comptime capability matrix + runtime spawn error; no Asyncify.
10. Fork posture: extend `Io.Evented` in `~/projects/zig`; no vendored scheduler.
    *[Superseded by Appendix A (S0.5): the kernel is a bespoke run-queue scheduler on `fiber.zig`; the Evented backends are demoted to event-source references (A.2.6).]*
11. Testing: seeded deterministic scheduler; verona-rt-style seed sweeps; failing test prints
    its seed.

Explicit non-goals (v1): priority messages, bounded mailboxes by default, ETS-style shared
mutable tables, hot code loading, distribution (design-for only: pid node bits, copy-walker
reusable as serializer), BoC multi-cown scheduling, wasm fibers.

## 3. Architecture overview

**A process is:** a fiber (fixed guard-paged lazy-commit stack reservation) + a manager context
(vtable+state pointer in the process control block) + a Vyukov MPSC mailbox + a preemption
budget + a drop-list of external resources + a pid table slot `{slot, generation, model bits,
node bits}`.

**The scheduler is:** per-core scheduler threads (M:N), per-core run queues with LIFO slot +
global overflow queue + work stealing, parking/wakeup integrated with the `Io.Evented` event
loop, a per-scheduler hierarchical timing wheel, a per-scheduler flag-only watchdog timer, and
a seedable single-threaded deterministic mode. *[Superseded by Appendix A (S0.5): parking is
the OS futex on our own run queues per A.2.2/A.3, not Evented event-loop integration.]* The Zap scheduler **implements the `std.Io`
vtable**, so any Zap-runtime or FFI code doing I/O through `Io` suspends the calling process
correctly instead of blocking the scheduler thread. Two upstream-informed design rules: the
implementation is **`operate`-centric** (route I/O dispatch through one `operate` switch over
the `Operation` union — upstream is migrating per-function vtable entries into it, so this
absorbs future drift for free), and task admission exploits the **newly-legalized lazy-start
semantics** of `async`/`groupAsync` (upstream `56265d6f99` deleted the "concurrency assigned
before return" guarantee — a run-queue scheduler may defer fiber assignment until
`await`/`cancel`, which is exactly the BEAM-style admission shape).

**A send is:** copy into a detachable fragment from the shared envelope page pool (owned by the
message system; abandon/reclaim on sender death) → one atomic exchange onto the receiver's
mailbox → wakeup. **A receive is:** `Io.Select` over {mailbox, timer, exit-signal} arms →
adopt fragment into own manager → pattern match (exhaustive over the message union).

**Memory ops** compile against the process's reclamation model: monomorphized on hot paths,
manager-vtable on cold paths. Non-spawning binaries compile exactly as today (no polls, no TLS
current-process, global manager) — the zero-cost gate.

## 4. Division of labor (CLAUDE.md: Zap is a language)

**Zig — genuine primitives only:**

- Runtime kernel: scheduler, fibers, run queues, mailbox queue, envelope pool, pid table,
  timing wheel, watchdog, blocking pool, registry table, copy/adopt machinery, crash teardown.
  Lives as a self-contained runtime source unit (`src/runtime_concurrency.zig` + a thin
  `src/runtime_io.zig` seam over `std.Io`), compiled per target via
  `zap_fork_compile_zig_to_object` exactly like manager sources — never text codegen.
- Compiler: spawn/send/receive/link/monitor lowering in `src/zir_builder.zig`; safepoint
  emission; message-union inference; monomorphization hybrid in `src/monomorphize.zig`;
  verifier passes (`src/concurrency_verifier.zig`, modeled on `src/arc_verifier.zig`); driver
  multi-manager resolution (`src/memory/driver.zig`); capability matrix.
- Fork (`~/projects/zig`): ZIR C-ABI additions for the new intrinsics; `Io.Evented` gap fixes;
  (later) work-stealing/IOCP contributions.

**Zap — everything else (`lib/*.zap`, all with `@doc`):**

- `lib/process.zap` — `Process.spawn/spawn_link/spawn_monitor/self/exit/sleep/send`,
  `trap_exit`, thin wrappers over `:zig` intrinsics.
- `lib/task.zap` — `Task.async`/`Task.await` returning `Future(T)`; the typed-call idiom
  (correlation token internal).
- `lib/supervisor.zap` — strategies `one_for_one`/`rest_for_one`/`one_for_all`, intensity 1 /
  period 5 s defaults, shutdown protocols; built on `Group` semantics via intrinsics.
- `lib/process/dead_letter.zap`, `lib/process/registry.zap` (via-style layer over the runtime
  registry), credit-based flow control (stdlib, later).
- Zest concurrency helpers (`lib/zest/…`): seeded-scheduler test wrappers.

The `receive` construct itself is language surface (parser → HIR → ZIR lowering onto
`Io.Select`); everything above it is Zap code.

## 5. Phases

Effort sizing: S (~days), M (~1–2 weeks), L (~weeks), XL (multi-week+fork work). Every phase:
tests written first (Zest under `test/` for language/stdlib semantics; `zir-test` additions only
for harness concerns — flags, cache layout, cross-target, compile-fail diagnostics); full suite
green before the phase closes; frequent commits.

### Phase 0 — Substrate spikes + experiment harness (M)

Goal: retire the highest-uncertainty questions with throwaway-marked spikes (`spike/` dirs,
same convention as `spike/manager_v1`) before any production code.

- **S0.0** Fork hygiene: purge the accidentally-committed build artifacts from the fork tree
  (`libzir_builder.a`, `zir_api.o`, `zir_builder.o`, `zir_ref_dump`) so the eventual rebase
  campaign starts from a clean commit stack.
- **S0.1** Benchmark harness: spawn cost, ping-pong RTT (same/cross scheduler), copy p99 vs
  size; CLBG baseline snapshot for E2 comparison. Baselines table from
  `research-round-2.md` Q10.
  *[Plan amendment (Phase 0 review): two S0.1 deliverables moved rather than delivered here.
  The "copy p99 vs size" harness construction moved to Phase 2 (item 2.8) — the deep-copy
  walker E6 must measure is built in Phase 2 item 2.4, so a Phase-0 harness could only have
  measured raw memcpy. The "same/cross scheduler" RTT decomposition moved to Phase 4 —
  cross-scheduler RTT requires the M:N scheduler; Phase 0's E9 wake-cost measurements bound
  it analytically (two parked wakes ≈ 1.8 µs).]*
- **S0.2 (E1)** Fiber spawn + ping-pong on the fork's `Io.Evented` (Dispatch on this machine)
  vs `Io.Threaded`. Targets: sub-µs–3 µs spawn, RTT within 2–3× BEAM/Go.
- **S0.3 (E9)** Dispatch vs Kqueue on Darwin: fiber-switch + wakeup latency → picks the
  tier-1 default backend (note: upstream's Evented switch picks Dispatch for macOS; validate
  or override in-fork).
  *[Superseded by Appendix A (S0.5): E9 was reframed to fiber-floor + wake-mechanism measurement and chose the os_sync futex for run-queue parking with EVFILT_USER reserved for the I/O-poller split.]*
- **S0.4 (E10)** Vtable-dispatch vs monomorphized alloc call microbenchmark → confirms the
  hybrid's hot/cold split empirically.
- **S0.5** Scheduler architecture decision memo: drive processes through `Io.async`/
  `concurrent`/`Select` as-is vs own run-queue scheduler on `fiber.zig` implementing the `Io`
  vtable. E1/E9 numbers decide; the plan assumes the latter (full control over budgets, LIFO
  slot, stealing, determinism) unless the spike shows Evented-as-is suffices for Phase 1–2.
  **Decided — see Appendix A** (bespoke run-queue scheduler on `fiber.zig`).

Exit gate: E1/E9/E10 numbers recorded in the plan doc; scheduler decision made. **Met
2026-07-04** — ledger sections E1 (incl. post-fix re-measurement), E9, E10; Appendix A.

### Phase 1 — Runtime kernel, single scheduler, single model (L)

Goal: processes exist; ARC-only (manifest manager); no language surface yet — kernel exercised
from Zig tests and a minimal intrinsic set.

- **1.1** Process control block: fiber + stack reservation (guard page, lazy commit) + manager
  context (per-process instance of the manifest manager) + mailbox + budget + drop-list.
- **1.2** Pid table: generational indices; model/node bit fields reserved and validated
  (dead-letter path stubbed); scalable iteration (OTP-28-style) from day one.
- **1.3** Vyukov MPSC mailbox (envelope-intrusive; null-next-nonempty case handled); envelope
  page pool with abandon/reclaim (mimalloc-style) for sender-death.
- **1.4** Spawn/exit/teardown: pool-only hot path (pid slot + manager init + lazy stack +
  enqueue); wholesale arena/slab free on exit; drop-list destructor run; `io.cancel()` wiring.
  *[`io.cancel()` wiring re-scoped out of Phase 1: it lands with the phase where the kernel
  implements the `std.Io` vtable (§3 architecture; `receive`-on-`Io.Select` is Phase 2 item
  2.3) — until then external-resource cancellation rides the landed drop-list seam (scheduler
  teardown runs drop-list destructors on every exit path). Two-way citation:
  `src/runtime/concurrency/scheduler.zig`'s crash-teardown module doc records the same
  deferral and points back here.]*
- **1.5** Deterministic mode: single-threaded seeded scheduler; all nondeterminism (scheduling,
  timers, sender interleaving) funneled through the seam; seed printed on failure.
- **1.6** Observability skeleton (non-negotiable): process list iterator, mailbox depth, heap
  bytes, state, crash reports with native stack traces.
- **1.7** Darwin teardown test (mimalloc-#164 class): thousands of spawn/die cycles under
  Tracking/Leak managers, clean teardown asserted.
  *[As landed: "Tracking/Leak managers" was substituted with `std.testing.allocator`-backed
  leak checking plus byte-accounting per-process test managers — functionally equivalent for
  the kernel-owned resources this test guards (stacks, envelopes, pid slots, PCB records:
  every pool balances exactly to pre-spawn counts and the testing allocator fails on any
  leaked byte), since Phase 1 payloads are opaque and no real manager exists yet to track.
  The real manifest-manager binding that Tracking/Leak would exercise lands in Phase 2 item
  2.4.]*

Exit gate: E3's same-model half (ARC→ARC copy under TSan, adversarial send/receive, zero
refcount races); E1 re-measured on the real kernel. **Met 2026-07-06 (P1-J6)** — ledger
sections "E3 — same-model race validation (Phase 1 half)" (TSan available on the fork;
zero findings across the kernel suite + ~20k adversarial rounds; scope note: Phase 1
payloads are opaque, so the copy-walker half of the TSan matrix moves with the walker to
E3's Phase 3 full run) and E1 "Phase 1 kernel re-measurement" (spawn 11 ns admission /
43 ns full lifecycle, RTT 44 ns, parked wake 5.0 µs median — PASS with orders-of-magnitude
margin; test-manager caveat noted, Phase 3 re-measures per manager).

### Phase 2 — Language surface + copy-path send/receive (XL)

Goal: `spawn`/`send`/`receive`/`after` work in Zap programs; single model; safepoints in.

*[Phase 2 opened — P2-J1 (runtime packaging + intrinsic ABI bridge) landed `8ac3cb3`,
2026-07-06. The kernel is linkable into user binaries behind the comptime
`runtime_concurrency` gate (default OFF = byte-for-byte today's world: no kernel object, no
`zap_proc_*` symbol — verified by `nm` + an nbody spot-check at the S0.1 baseline;
`Zap.Manifest.runtime_concurrency` / `-Druntime-concurrency=on|off`, folded into every
artifact/snapshot/script cache key). Gate ON compiles the kernel unit per target through
`zap_fork_compile_zig_to_object` rooted at `src/runtime/concurrency/abi.zig` — the primitive
already supports multi-file roots (its root `Package.Module` is the source file's directory),
so NO fork extension was needed — content-addresses the object
(`src/concurrency_driver.zig`), and splices it into the link via
`zir_compilation_add_link_object_file`. The minimal C-ABI intrinsic surface
(`zap_proc_runtime_init/deinit`, `zap_proc_run_until_quiescent`, `zap_proc_spawn`,
`zap_proc_self`, `zap_proc_send` — opaque payload bytes until the 2.4/P2-J5 deep-copy
walker —, `zap_proc_receive_park`, `zap_proc_envelope_free`, `zap_proc_exit`,
`zap_proc_yield_check`) is defined in `abi.zig` with a signature-mirrored extern set in
`src/runtime.zig`; gated-on binaries initialize the runtime before user main and deinit via
LIFO atexit (kernel teardown precedes manager shutdown). Until 2.3/2.7 land the Zap surface,
E2E validation is the kernel-suite round-trip test plus the documented
`ZAP_CONCURRENCY_SMOKE=1` runtime hook, which drives
init → spawn → send → receive → exit through the real link seam in a gated-on binary.]*

*[Known pre-existing corpus issue — NOT caused by the concurrency campaign (verified 2026-07-06,
A/B against parent `cb1bee0` with the fork compiler + repo build flags + per-side isolated caches).
The gate-off `zap test` corpus does not fully compile on `main` and did not before Phase 2. At
`f941a10` (P2-J2) the corpus aborts at `ClosureTest.catch_basin_handler_preserves_parked_alias`
(`test/closure_test.zap`, the uniqueness--03 catch-basin runtime guard added in `10571ed`) with
`arc_verifier` invariant **V11**: `local %4 appears as source of `.copy_value` but `local_ownership`
classifies it as .trivial`. This is a pre-existing ARC classification/seeding gap in the `~>`
catch-basin (`try_call_named`) lowering — it involves no closures and none of the P2-J2 changes
(the `arc_ownership.zig` box→`.owned` `move_value`, the `desugar.zig` unique eta-wrapper names, the
`macro.zig` single-segment alias resolution, or the general `macro_eval`/`zir_builder`/`zir_backend`
edits). Proof: the parent `cb1bee0` (which contains NONE of those changes) aborts EARLIER at
`EnumTest.test_enum_struct_sum_range_step_1_matches_walk` with invariant **V7** — precisely the bug
P2-J2's `arc_ownership.zig` fix repairs — which MASKS ClosureTest in the full corpus. Compiling
`test/closure_test.zap` in isolation (EnumTest excluded) reproduces the IDENTICAL ClosureTest V11 at
BOTH `cb1bee0` and `f941a10`, on byte-identical source (`test/closure_test.zap` is unchanged across
the two commits). So P2-J2 did not introduce V11; its EnumTest-V7 fix merely UNMASKED the pre-existing
V11 by advancing the compile past the earlier abort. Out of concurrency scope; left untouched here.]*

- **2.1** Typed pids: `Pid(M)` as the primary handle (Gleam-`Subject` analogue); `send`
  type-checks against `M`; untyped `Pid` exists for registry/dynamic use behind a
  `catch_all`-required receive.
- **2.2** Message-union: explicit annotation first (`process … receives M`), inference from
  receive patterns second; exhaustiveness verifier; out-of-union send = send-site compile
  error.
  - *[Shipped vs deferred (P2-R1/D4). **Shipped:** the per-receive `<M>` message-type token —
    each `receive M { … }` names its own message type M (scalar, `String`, `List`/`Map` of
    sendable elements, a by-value struct of those, or a payload-free union), with the
    payload-free-union exhaustiveness verifier (`checkReceiveMessageUnion`, `src/types.zig`)
    and out-of-union send as a send-site compile error against the typed `Pid(M)`. **Deferred
    to Phase 3+:** the two ergonomic forms that let a process fix ONE message type across all
    of its receives — (a) inference of M from the union of a process's receive patterns, and
    (b) the `process … receives M` block-annotation spelling. Phase 2 requires the type at
    each `receive` instead; neither deferred form changes the sendability/exhaustiveness rules,
    only where M is written.]*
- **2.3** `receive`/`after` lowering onto `Io.Select` (mailbox arm, timer-wheel arm,
  exit-signal arm); `after 0` = poll; suspension at arbitrary call depth (stackful fibers).
- **2.4** Deep-copy send: sender copies into detachable fragment (closures: share code pointer,
  deep-copy environment); receiver adopts (rc=1 init). ZIR-emitted copy walker written for
  reuse as a serializer later. This item includes binding the real manifest (ARC) manager ABI
  for receiver-side adoption — replacing the Phase 1 kernel test-manager vtable (not layering
  over it) per the no-fallbacks rule; `src/runtime/concurrency/process.zig`'s "Manager
  binding" module doc cites this item back.
  - **Realized as serialize-to-blob (2 copies), NOT copy-into-fragment + O(1)-adopt — and this
    is a first-class finding, not an expedient.** A Zap ARC `List(T)`/`Map(K,V)` cell is a
    SINGLE CONTIGUOUS allocation obtained through `c_allocator`/libc `malloc`
    (`src/runtime.zig`, the `List`/`Map` cell `bufferAlloc` — "Layout (single contiguous
    allocation through `c_allocator`)"). A live ARC cell therefore CANNOT be relocated
    byte-for-byte into a neutral envelope-pool fragment and still be freed through the normal
    ARC release path (release recomputes the buffer address from the cell pointer and hands it
    back to `c_allocator`; a cell sitting in a pool fragment has no such `c_allocator` block).
    So Phase 2 serializes the value graph into a flat neutral blob on the sender and
    RECONSTRUCTS fresh rc=1 cells on the receiver (`serializeMessage`/`deserializeMessage` in
    `src/runtime.zig`) — two full copies (serialize + reconstruct). `String`s are copied by
    value into the blob for the same reason (their backing is arena memory that becomes
    per-process in Phase 3; aliasing a sender slice would dangle — see §5.4 copy-out slices).
    The 2-copy cost is exactly what item **2.8**'s copy-p99-vs-size harness feeds into the E6
    crossover measurement.
- **2.5** Safepoints, all three layers, comptime-gated (`runtime_concurrency` off → zero
  emission): alloc piggyback; bare back-edge polls only in alloc-free/call-free loops;
  per-scheduler flag-only watchdog.
  - **Landed (P2-J6, 2026-07-07).** ZIR-builder emission wired to the kernel via
    `abi.zap_proc_safepoint_slow` → `ProcessContext.reductionSafepoint` (shared slow path:
    yields on kill / watchdog / a co-runnable peer, else returns switch-free so a sole CLBG
    hot loop pays no fiber switch). Layer 2 = a loop-local reduction counter LLVM promotes to
    a register (`subs`/`cbz` per iteration) at every LOOPIFIED back-edge, plus the shared
    global counter (`procReductionTick`) at every MUSTTAIL back-edge (a TCO-safe frame has no
    promotable slot). Layer 1 rides `procReductionTick` in `allocAny`/`bufferAlloc`. Layer 3
    (watchdog flag) honored in the slow path. **Correction to the revision-1 emphasis:** the
    poll is emitted at EVERY loopified/musttail back-edge, not "only in alloc-free/call-free
    loops." Rationale, measured: (a) an IR-level "no call" test is unusable — Zap lowers even
    `a - b` and `Math.sqrt` to `call_named` pre-inline, so it disqualifies essentially every
    loop; (b) Zap `list_cons`/map growth allocate through an amortized `bufferAlloc`, so an
    allocating loop excluded from layer 2 and left to the layer-1 piggyback is polled only
    O(log n) times — unsound. The register poll is cheap enough (2 instructions, hidden in
    FP-heavy bodies) to ride every loop. **E2 PASS** (kill criterion not tripped): nbody −2%,
    spectral-norm −2% (within noise; beats Go's 7.8%); non-gating tight-loop regressions
    fannkuch +10–11%, mandelbrot +3% reported honestly with unrolling / force-loopify-musttail
    as documented follow-up mitigations (see Phase 6 item 6.6). Zero-cost-OFF proven DURABLE at
    HEAD (`ecb9113`): a gate-OFF nbody carries zero `zap_proc_*`/`safepoint` symbols (`nm`) and
    zero safepoint-poll call sites (`__text` disasm); a byte-identical `__text` SHA is kept only
    as a point-in-time checkpoint (the J6 anchor no longer reproduces once J7/J9's always-linked
    objects shifted `__text` — hence the durable proof is symbol/instruction-level).
    Numbers: `docs/concurrency-bench-results.md` § E2. Latency bound (`scheduler.zig` module
    doc): ≤ one reduction budget of the slowest polled loop — all Zap loops are tail-recursive
    and now polled; the residual un-polled code is bounded straight-line / non-tail chains.
- **2.6** Verifier passes v1: no-borrowed-at-send, no-shared-at-send, use-after-move-across-
  send (extends the existing move checker). Compile-fail diagnostics via `zir-test` until Zest
  supports compile-fail.
- **2.7** Zap stdlib: `lib/process.zap` minimal surface; Zest concurrent tests (seeded) —
  ping-pong, ordering (pairwise FIFO), crash-teardown, timeout semantics.
- **2.8** Copy-p99-vs-size harness (moved from S0.1): message-copy latency over 64 B–1 MB
  payloads, built on the 2.4 deep-copy walker (the component whose absence moved this out of
  Phase 0); feeds the E6 crossover measurement below.
  - **Landed + measured (P2-J9, 2026-07-07).** `bench/concurrency-copy/` times the REAL
    `serializeMessage`/`deserializeMessage` walker on real refcounted `List`/`Map`/`String`
    ARC cells (runtime linked against the production ARC manager), median/min/p99 per size,
    with the serialize-vs-reconstruct split. **E6 first crossover:** flat `List(i64)` copy is
    ≤ the ~44 ns RTT floor to ~256 B and crosses (≥2× floor) at ~1 KB, dominant (~16×) at
    ~16 KB, ~46 µs at 1 MB — LATE, deferrable for small flat messages. `Map` crosses
    IMMEDIATELY (~256 B) and reaches **2.19 ms at 1 MB (150× a bare memcpy)** because the
    reconstruct rebuilds the hash table — the receiver-side reconstruct (Copy C) is the
    dominant half everywhere (2.6× serialize for lists, 95× for maps). This makes the R4/R5
    O(1)-move / bulk-adopt path (item 3.3) **urgent for maps and large payloads, deferrable
    for small flat messages** — the win is in eliminating the reconstruct. Full table +
    verdict: `docs/concurrency-bench-results.md` § E6; quantifies the item-2.4 R4 note.
- **2.9** E2 gate execution precondition: quiet-machine interleaved re-baseline — paired
  baseline-vs-safepoint runs of the same binaries in the same session, compared on paired
  medians/minima per the S0.1 ledger's gating protocol (the archival S0.1 table is drift
  context, not the gate).

Exit gates: **E2** (CLBG with concurrency ON: alloc-piggyback ≈ 0 on allocating loops;
back-edge poll ≤2–3% on nbody/spectral-norm, else loop-unroll mitigation before proceeding);
**E6** first crossover measurement.

### Phase 3 — Per-spawn managers (XL; the centerpiece)

Goal: `spawn(f, .{ .manager = … })` with comptime-resolved manager binding (Decision Gate 0).

- **3.1** Driver: resolve/validate every spawn-site manager + manifest default; per-manager
  symbol families replacing the `zap_active_manager` singleton; runtime manager registry.
  - **Scheduler-local refcount invariant on the WIRED send path (Constraint 3) — Phase-2
    guarantee + Phase-3 TSan seam.** The deep-copy send is now wired (`send_message` serializes,
    `receiveMessage` reconstructs). The invariant holds BY CONSTRUCTION and more strongly than
    the fragment-adopt design: the in-flight message is a flat neutral BLOB carrying ZERO live
    refcounts (the serializer reads the sender's cells and copies their DATA; it never moves a
    refcounted cell into the envelope), so there is no refcount any second scheduler could ever
    touch — cross-thread refcount races are impossible, not merely avoided. The sender's
    original cells stay in the sender's heap (refcounts untouched by anyone else — the
    borrow-probe test confirms the sender retains its value across the send); the receiver's
    reconstructed cells are rc=1 in the receiver's heap, touched only by the receiver. A real
    MULTI-THREAD ThreadSanitizer run of the send path is NOT yet possible in-tree: host
    `zig build test` and the Phase-2 single scheduler bind ONE binary-wide ARC instance, so
    there is no second-thread manager to race against. TSan coverage of concurrent send/receive
    is therefore the Phase-3 seam (this item's per-process private ARC instances) — the
    by-construction zero-live-refcount argument is the Phase-2 guarantee until then. (No TSan
    run is claimed here.)
  - **LANDED (P3-J1, 2026-07-07).** Per-process manager INSTANCES ship: each process (the root
    included) mints its OWN private ARC context from the bound manifest manager's core vtable at
    spawn (`abi.zig` `ManifestManagerBinding.createProcessContext`), and the adapter's `teardown`
    is now a REAL per-process wholesale free via the vtable's `deinit` (the Phase-2 no-op is
    replaced, not layered — no-fallbacks). The runtime routes every hot-path allocation to the
    running process's context via the scheduler-published `zap_proc_active_arc_context`
    (`process.zig`; A.4 OQ1 resolved to this published-per-quantum read — see the OQ1 ledger
    section), including List/Map container buffers (previously `c_allocator`-backed) and the
    walker's adopted cells, so a process's whole heap — and every message it adopts — is
    wholesale-freed with it (large allocations tracked per-context in `arc/manager.zig` so
    `arcDeinit` reclaims them too; a killed process leaks nothing). The **TSan seam is now
    CLOSED**: `src/memory/arc/cross_thread_stress.zig` runs a real multi-thread send/adopt over
    real per-process ARC instances under ThreadSanitizer — **zero findings across 100 k
    cross-thread ARC messages** (E3 full-half ledger section). The scheduler-local-refcount
    invariant is proven by measurement, not just by construction. Kernel/manager/runtime
    validated: `zig build test` green, `test-kernel` green (per-process-instance + crash-teardown
    leak-exact kernel tests), gate-ON `:test_concurrency` 49/0. Remaining for J2/J3: the
    monomorphization hybrid (item 3.2) and the multi-manager driver/registry (this item's
    per-manager symbol families — J1 ships the single-model ARC foundation).
- **3.2** Monomorphization hybrid in `src/monomorphize.zig`: specialize spawn-reachable hot
  paths per model (elision decisions per specialization via `src/memory/elision.zig`); cold
  closure/existential paths through the control-block vtable; ICF-unfoldable specializations
  surfaced as verifier red flags.
  - **LANDED (P3-J2, 2026-07-07).** The COMPILER-SIDE mechanism ships and is unit-tested.
    (1) **Axis:** `monomorphize.specializeSpawnManagers(plan)` clones the spawn-reachable
    subgraph per reclamation MODEL (≤4, keyed on Axis A — Arena/NoOp/Leak share BULK_OR_NEVER),
    tags each clone (`FunctionGroup.reclamation_model`), and redirects intra-subgraph
    direct/named/dispatch calls to the same-model clones (`current_model_call_redirect`, reusing
    the type-arg clone path). The reachability walk STOPS at indirect (`.closure`) edges — the
    precise hot/cold boundary — and flags them (`saw_cold_edge`). Run as a SEPARATE pass after
    the type-arg axis (concrete functions), so the type-arg machine is untouched. (2)
    **Per-specialization elision:** `elision.canonicalCaps(model)` + `ir.Function.reclamation_model`
    (propagated from HIR in `buildFunctionGroup`) + `ZirDriver.effectiveDeclaredCaps` install the
    model's caps as the function's active `declared_caps` at `emitFunction`, so every elision
    predicate decodes per-model — a REFCOUNTED specialization emits retain/release, a
    BULK_OR_NEVER one elides them (unit-proven). (3) **Decision Gate 0** is enforced structurally:
    a spec carries a resolved `ReclamationModel` enum, so a non-comptime `.manager` cannot enter a
    plan (J3 diagnoses it at the surface). (4) **ICF red flag:** `modelCloneStructurallyFoldable`
    verifies each clone is structurally identical to its source modulo header ops — a compile-time,
    target-independent substitute for "did ICF fold?" (Darwin's self-hosted Mach-O linker has no
    ICF yet; a fork follow-up). (5) **E4 PASS** — ledger § E4: per-model `__text` delta +1.65%
    whole-binary / 536 B on the isolated subgraph, allocating functions byte-identical (ICF-foldable
    to ×1), 4-model ≈ 2-model (non-refcounted models fold together). **Zero-cost off:** the tag
    fields default null, the pass is not yet wired into the driver pipeline, and every untagged
    function keeps `base_declared_caps`, so all current builds are byte-identical (proven: `zig
    build test` green, no behavior change). **Remaining for J3:** the driver resolves the
    `spawn(f, .{ .manager = X })` surface into the plan `specializeSpawnManagers` consumes, rewires
    spawn sites via the returned `entry_specializations`, and completes the runtime per-process
    retain/release model dispatch (the registry — item 3.1/3.3) so cold paths dispatch fully at
    runtime, not just for allocate.
  - **LANDED (P3-J3, runtime mechanism + compiler pass) — 2026-07-07.** The per-spawn manager
    machinery ships and is validated end-to-end on the single-manager path. (1) **Kernel registry**
    (`src/runtime/concurrency/abi.zig`): the single manifest binding is replaced by a manager
    REGISTRY indexed by id — `zap_proc_register_manager(index, core)` + `zap_proc_spawn_at(entry,
    arg, index)`; a spawn mints a FRESH private per-process context from the SELECTED registry
    slot's core and stamps the pid's 2-bit reclamation-model field from that manager's
    `declared_caps` (`reclamationModelForCaps`, name-for-name equivalent to
    `elision.reclamationModel`, asserted by a kernel test). `zap_proc_spawn`/`zap_proc_bind_manager`
    are the slot-0 conveniences. (2) **Per-process dispatch** (`src/runtime.zig`): each process
    carries a `ProcessManagerBinding {core, context}` (published per quantum); the raw
    allocate/deallocate hot path dispatches through the RUNNING process's own core
    (`currentManagerCore`) under the comptime `multi_manager_active` gate, so an ARC process and an
    Arena process each allocate from their own manager — a single-manager binary keeps the
    comptime-bound `active_manager` direct calls (zero-cost). (3) **Capability matrix (item 3.5):**
    `managerModelSoundOnTarget` makes an impossible manager×target combo (TRACED on Windows/wasm) a
    RUNTIME spawn error while the backend stays LINKABLE (driver `gate_target_support = false` for
    spawn managers — the cross-compile requirement); the build-time driver applies the same
    predicate to the manifest default. (4) **Spawn-manager pass**
    (`monomorphize.collectAndSpecializeSpawnManagers`): recognizes the
    `ProcessRuntime.spawn_process_managed` intrinsic (the `lib/process.zap` `spawn/2` macro's
    lowering), resolves each comptime manager → model + registry index via an injected resolver
    (Decision Gate 0: a non-comptime manager is a compile error at the site), runs
    `specializeSpawnManagers`, and rewires each site IN PLACE to `spawn_process_at(clone, index)`;
    wired into the pipeline (`compiler.zig` `runMonomorphize`), surfacing J2's ICF red flags as
    build diagnostics. **Validated:** kernel `test-kernel` 134/134 (registry + spawn_at model-bit +
    caps→model correspondence tests); host `zig build test` green; `monomorphize` 1641/1641 (pass
    unit tests: rewire+specialize, no-op, Decision Gate 0 diagnostic); fresh (cache-nuked) gate-ON
    `:test_concurrency` 49/0 (the per-process binding-unwrap keeps the single-manager path
    unchanged). Cross-model SEND stays J4.
  - **LANDED (P3-J3-FINISH, the running 2-manager proof) — 2026-07-07.** The build-orchestration
    last mile is closed and the RUNNING 2-manager binary is the acceptance test. (1) **Resolver
    injection** (`src/main.zig` `SpawnManagerAccumulator`): a driver-backed
    `monomorphize.SpawnManagerResolver` threaded into `CompileOptions.spawn_manager_resolver`
    (`Pipeline.init`). It resolves each `spawn(entry, Memory.X)` site's manager the SAME way the
    manifest default does — scope-graph adapter resolution
    (`builder.evaluateMemoryManagerAdapterFromSources`) → `memory_driver.resolve`
    (`gate_target_support = false`, so an unsound target×model combo stays LINKABLE) → `declared_caps`
    → `memory_elision.reclamationModel` — and accumulates the DISTINCT non-manifest managers into a
    dense registry (index 0 = manifest default, 1.. = spawn managers). (2) **Surface** (`lib/process.zap`):
    `Process.spawn(entry, manager)` passes the manager type DIRECTLY (a first-class `Type` value —
    Zap has no anonymous-struct literal, so the reserved `.{ .manager = X }` options shape does not
    parse); `extractManagerTypeName` accepts the bare `Type` value (and still the options-struct
    shape). (3) **Registry generation** (`src/zir_backend.zig` `generateManagerRegistrySource`): each
    spawn manager backend is registered as a `zap_spawn_manager_<index>` sibling module and a
    generated `zap_manager_registry` module exposes `entries` = `{index, core}` pairs the runtime
    bootstrap feeds to `zap_proc_register_manager` under `multi_manager_active` (rewritten ON by a new
    `RuntimeSourceControls.multi_manager` stage). (4) **N managers coexist**: the mandatory
    `zap_memory_section` linker symbol is now emitted only when the manager compiles as a standalone
    `.Obj` (`builtin.output_mode == .Obj` — the driver's validation object + object-linked hosts, the
    only readers of the symbol); compiler-driven `.Exe`/`.Lib` sibling modules bind via their module
    DECL (`RUNTIME_ACTIVE_MANAGER_SOURCE_DEFAULT` is always rewritten true), so NONE emits the
    colliding symbol. (5) **ICF verifier fix**: `modelCloneStructurallyFoldable` now tolerates the
    redirect's legitimate `.named` → `.direct` call-variant rewrite
    (`redirectCallTargetForModel`) — the synthetic unit tests only exercised `.direct` calls, so this
    fired on every real spawn-reachable stdlib function (`Enum`/`List`/`Range`). (6) **Daemon**: the
    incremental manifest daemon recreates its persistent context bound to the discovered manager
    family via a `SpawnManagerSetChanged` → retry in `establishIncrementalWatchState`
    (single-manager builds never call the resolver → byte-identical). **Acceptance test**
    (`test_concurrency/two_manager_proof_test.zap`): spawns an ARC process (manifest, slot 0) AND an
    Arena process (`Memory.Arena`, slot 1) in ONE binary; asserts their pid reclamation-model bits
    DIFFER (refcounted 0 vs bulk_or_never 1 — the kernel dispatched them to different managers) and
    that each allocates a 1000-cell `List` on its OWN process heap and reports back — the Arena
    child proving the BULK_OR_NEVER monomorphization elides retain/release (else Arena, which
    services no REFCOUNT_V1, would panic on refcount dispatch). **Validated:** gate-ON
    `:test_concurrency` **50/0** (49 baseline + the proof) via BOTH the default daemon path and the
    direct path; host `zig build test` green; `zig fmt` clean.
- **3.3** Model-tagged pids live; per-reachable-pair copy stubs (lazy generation); adoption
  semantics per model (rc=1 / bulk splice / range registration / free-at-last-use) — **manager
  ABI minor bump** (detach/adopt entry points + envelope-domain semantics) per spec §2.3,
  spec doc updated in the same commits.
  - **R4 (region re-parent / O(1) move) is directly threatened by the Phase-2 finding in 2.4,
    confirmed by inspection.** The O(1) "move" path (research.md §6.4 / risk R4 at
    research.md:237; zap-concurrency-research.md §2.4) re-parents a unique, region-closed value
    graph into the receiver's manager WITHOUT moving bytes — the receiver's manager adopts the
    sender's slab set. But because Phase-2 ARC `List`/`Map` backing is a single `c_allocator`
    block per cell (2.4), there is no relocatable region to hand over: an O(1) detach/adopt has
    no `c_allocator`-owned span it can re-parent, so today's cross-process move DEGRADES TO THE
    2-copy serialize path. Making the O(1) move real requires either (a) relocatable/arena-
    backed container buffers carved from a detachable region the receiver's manager can adopt
    wholesale, or (b) a different move mechanism entirely (page-splice for BULK_OR_NEVER, range
    registration for TRACED). The `detach`/`adopt` ABI entry points added here MUST encode which
    models can O(1)-adopt and which fall back to copy (zap-concurrency-research.md §2.4: "the
    verifier and docs must say so"); P2-J9/item **2.8**'s E6 measurement quantifies the 2-copy
    cost this fallback pays until then.
  - **R4 RESOLVED (P3-J5, the same-model O(1) region-move send). The mechanism is
    option (a) refined for the P3-J1 slab reality.** Under the gate a `List`/`String`
    container buffer routes through the process's own ARC core: SLAB-backed
    (≤4096 B) buffers are interleaved in shared 64 KiB slabs and are NOT
    relocatable per-cell (degrade to copy — small, cheap); LARGE (>4096 B →
    `page_allocator` mmap) buffers are standalone blocks tracked only by intrusive
    membership in the per-context `large_head` list, so they CAN be re-parented in
    O(1): `detachRegion` unlinks the `LargeHeader` from the sender's `large_head`,
    `adoptRegion` relinks it into the receiver's — both scheduler-local, the
    refcount untouched (rc==1 ⇒ sole reference; no cross-thread refcount touch, the
    invariant holds by construction), `munmap` process-global. An undelivered
    move's orphan is reclaimed context-free by `freeDetachedRegion`. Delivered as
    ABI **v1.2** on the REFCOUNT_V1 capability (`detach_region`/`adopt_region`/
    `free_detached_region`; ARC/ORC only). Transport reuses the copy-free kernel
    `context.send` with a `Fragment.moved_reclaim` discriminator + leak-safe
    reclaim in `zap_proc_envelope_free` and the teardown drain. Surface:
    `Process.send_move` (consumes its message via the `sideChannelStashBuiltinArg`
    consume-sink recognition, so the region-closure verifier's C2/C3 engage). **E5
    PASS:** detach+adopt is 1–2 ns INDEPENDENT of payload size (4 KiB…1 MiB),
    pointer-identity preserved (O(1)), leak-exact; vs copy's O(size) (48 µs memcpy
    at 1 MB, 2.19 ms `Map` reconstruct) — `docs/concurrency-bench-results.md` § E5.
    **P3-J5-VERIFY (2026-07-08):** gate-ON `:test_concurrency` runs **56/0** (110
    assertions, exit 0) via `zap run test_concurrency`, including
    `move_send_test.zap`'s 3 `Process.send_move` cases; and the by-construction
    scheduler-local-refcount invariant is now ALSO proven BY MEASUREMENT — the
    cross-thread detach/adopt move path (`cross_thread_stress.zig`
    `runMoveSendArcStress`, the one shape where a real heap cell crosses threads)
    is ThreadSanitizer-clean at 8k + a 20k-cell soak, leak-exact (§ E5).
    **R4 residual:** `Map` still uses `c_allocator` (not the large path), so a `Map`
    send degrades to copy until `Map.bufferAlloc`/`bufferFreeShallow` migrate to
    `containerBufferAlloc`/`Free` (the exact gate-branch `List` already carries);
    the O(1) map-send fix is that one-call-site migration + extending
    `movableFlatListCell` to maps. Nested graphs (interior ARC children in separate
    cells) also copy.
- **3.4** ORC manager: `src/memory/orc/manager.zig` + stdlib adapter; verify the
  shares-REFCOUNTED-specialization hypothesis (cycle-root buffering entirely inside `release`);
  cycle-collection at yield points only. **DONE (P3-J6, 2026-07-08)** — `Memory.ORC`
  (`lib/memory/orc.zap` + `src/memory/orc/manager.zig`) is a Bacon–Rajan
  trial-deletion collector over ARC's refcount ABI; the cycle-root buffering lives
  entirely in `release`/`release_sized` (`noteDecrement` → `possibleRoot`). Hypothesis
  **CONFIRMED**: ORC declares `declared_caps == 0x1` (REFCOUNTED, byte-identical to ARC)
  → shares ARC's `.refcounted` monomorphization specialization, zero additional codegen;
  cycle collection is one new `CYCL` capability descriptor, never a new Axis-A model.
  Proven at the elision layer, the stdlib-manager matrix, and end-to-end
  (`test_concurrency/orc_test.zap` — an ARC child and an ORC child coexist in one binary,
  both `refcounted`). Cycle-collection correctness + leak-exactness proven in the manager's
  unit tests (build a cycle, drop it, collect it; acyclic reclaimed promptly; a negative
  control confirms ARC alone leaks the cycle). See ledger § E8's companion.
- **3.5** Capability matrix (comptime table + runtime spawn error); wasm32 and Windows entries;
  compile-time warnings for statically-known-impossible combos.

Exit gates: **E4** (post-ICF text growth at 1/2/4 models on an existential-heavy program);
**E3** full matrix (reachable pairs, TSan, sender-dies abandon/reclaim); **E8** (fiber-stack
conservative scan cost + false retention → mark-sweep ships or slips per rev 2 §2.5).

### Phase 4 — Multicore + blocking (L)

- **4.1** M:N work-stealing scheduler (schedulers = cores), per-core queues + LIFO slot +
  global overflow; parking via Evented wakeups (userspace flag when awake; eventfd/`MSG_RING`/
  kqueue-user/GCD source when parked — measure, R7).
  *[Superseded by Appendix A (S0.5): closed by A.3 — Darwin run-queue parking = OS futex, poller = EVFILT_USER; R7 narrows to the Linux poller primitive (eventfd vs `MSG_RING`).]*
- **4.2** Hierarchical timing wheel per scheduler, feeding the `after` Select arm. Include
  `Condition.waitTimeout`/`Semaphore.waitTimeout` in the primitive set: implement on 0.16's
  existing `futexWaitTimeout` vtable entry, or cherry-pick the three small std-only upstream
  commits (`d821446cf9`, `a43973b336`, `c0763b5e25`).
- **4.3** Blocking pool (dirty-scheduler equivalent): `Process.blocking` intrinsic; documented
  FFI contract; zig-libc devlog path noted as the long-term shrink.
- **4.4** Deterministic mode extended: seeded multi-scheduler interleaving sweeps
  (verona-rt-style `--seed`/seed-range).

Exit gates: **E7** (fiber blocking inside a manager call — GC pause in `allocate`, lazy-commit
fault — co-scheduled fibers not delayed beyond watchdog tick, else mandatory handoff for
blockable manager calls); E1 cross-scheduler numbers, including the same-vs-cross-scheduler
ping-pong RTT decomposition moved here from S0.1 (measurable only once the M:N scheduler
exists; until then bounded analytically by E9's parked-wake cost — two wakes ≈ 1.8 µs).
The parked-wake re-measurement in that re-run must be re-baselined under the quiet-machine
paired-run discipline (mirroring item 2.9: paired runs in the same session, compared on
paired medians/minima, load recorded per run), because the Phase 1 wake numbers carry
session load; acceptance is wake median under recorded load ≤ ~2× min, or the
cross-scheduler budget explicitly re-derived from the loaded numbers.

### Phase 5 — Signals, supervision, typed calls (L)

- **5.1** Links (bidirectional, one-per-pair), monitors (unidirectional, stackable, `DOWN`
  with `noproc`), `trap_exit`, exit-signal ordering merged with pairwise FIFO; `kill`
  untrappable → `killed`. Exit signals as a distinct Select arm.
- **5.2** Runtime local registry (atomic register/lookup, register-then-crash race handled).
- **5.3** Pure-Zap stdlib: `lib/supervisor.zap` (strategies, defaults, shutdown protocols,
  start left→right/terminate right→left), `lib/task.zap` (`Task.async` → `Future(T)`,
  `call` with internal correlation-token skip — the ref-trick receive mark lands here),
  dead-letter sink + telemetry.
- **5.4** `spawn_link`/`spawn_monitor`; `Process` module completed; `@doc` everywhere.

Exit gate: supervision-tree Zest suite (restart intensity, rest_for_one ordering, brutal_kill
timing) under seeded determinism; R8 selective-receive benchmark (10⁶-deep mailbox, O(1)
correlated replies).

### Phase 6 — Performance tier (L)

- **6.1** Same-model O(1) region move: region-closure verifier constraint over
  `src/region_solver.zig` + escape lattice + uniqueness facts; slab detach/adopt (**E5**:
  truly O(1) and leak-free, else copy-on-move stays, documented).
- **6.2** `Blob` (atomically-refcounted immutable byte buffer; naming folds into the pending
  V8→dense rename sweep): the one sanctioned share tier; global immutable registry
  (`persistent_term` analogue).
- **6.3** Blob-backed String per rev 2 §5.4: copy-out slices, SSO, 64 B promotion (tuned by
  measurement), rc==1 in-place append via the uniqueness prover, opt-in aliasing view.
- **6.4** Arena auto-reset at the receive back-edge for solver-proven loop-closed processes;
  `hibernate` intrinsic (arena reset + stack shrink).
- **6.5** Full observability: send/receive trace points (compile-time-optional), scheduler
  utilization, run-queue depth, deadlock ("all waiting, none runnable") and starvation
  detection.
- **6.6** Gate-ON tight-loop safepoint mitigation (E2 follow-up; owner for the deferred
  mitigation flagged in item 2.5 and `docs/concurrency-bench-results.md` § E2). Amortize the
  cooperative safepoint poll on the tight non-FP loops that regressed gate-ON — fannkuch-redux
  `reverse_range`/`count_flips` (+10–11%) and mandelbrot `iter`/`row_loop` (+3%). Two
  Go-precedented levers: (a) loop-unroll to amortize the 2-instruction register poll over K
  iterations; (b) force loopification of `musttail` self-recursion gate-ON so mandelbrot's poll
  becomes register-local instead of riding the global reduction counter's per-iteration
  load/store. NOT a kill-criterion item (E2 already passed with the poll on every loop) — this
  is a perf-tier refinement that gives the deferred mitigation an explicit owner.

Exit gate: E6 re-run — crossover documented; ping-pong within target with move path on.

### Phase 7 — Hardening + portability (M)

- **7.1** Wasm: capability-matrix entries verified (spawn error clean, Threaded fallback where
  host threads exist); cross-compile smoke per the existing `runtime_os` gate.
- **7.2** Windows: Threaded-backend 1:1 fallback validated end-to-end; IOCP+fiber fork work
  scoped as a follow-on (stretch).
- **7.3** Docs: user-facing concurrency guide; FFI safety contract; message-versioning posture
  (never crash on unknown dynamic message); latency bound documentation incl. the one
  unbounded case.
- **7.4** README/CHANGELOG; benchmark suite results published in-repo.

## 6. Experiment gates → phases

| Gate | Phase | Kill criterion / decision |
|---|---|---|
| E1 spawn/ping-pong | 0, re-run 1, 4 | ≥1–3 µs spawn or RTT >3× BEAM/Go → escalate scheduler design |
| E9 Dispatch vs Kqueue | 0 | picks Darwin default backend *[Superseded: E9 was reframed to fiber-floor + wake-mechanism measurement; outcome — os_sync futex parking + EVFILT_USER poller split, per Appendix A.]* |
| E10 dispatch vs mono alloc | 0 | confirms hybrid hot/cold split |
| E2 CLBG safepoints | 2 | >2–3% on nbody/spectral-norm → unrolling mitigation first |
| E6 copy crossover | 2, re-run 6 | early crossover → pull Blob/move forward |
| E3 TSan copy matrix + sender-dies | 1 (same-model), 3 (full) | any cross-scheduler refcount race → stop-ship |
| E4 post-ICF code size | 3 | exceeds CLBG size budget → shift more paths to vtable dispatch |
| E8 fiber-stack scan | 3 | unbounded cost / high false retention → mark-sweep out of v1, ORC only. **PASS (P3-J6, 2026-07-08)**: ~1 µs/KiB bounded scan, 0.00000% coincidental false-retention, complete root coverage on Darwin/aarch64 → `Memory.GC` (TRACED) ships as a per-process option; ORC remains the recommended cyclic model (no stale-pointer hazard). See ledger § E8. |
| E7 manager-call blocking | 4 | stalls beyond watchdog tick → mandatory handoff |

## 7. Risks (top 5; full list in rev 2 §8)

1. Fiber-stack conservative scan (E8) — mark-sweep may slip; ORC is the designed fallback.
2. Existential reachability inflating monomorphization (E4) — vtable arm + ICF are the designed
   caps; red-flag verifier catches semantic leaks.
3. Safepoint cost on CLBG wins (E2) — highest-visibility perf risk; unrolling mitigation
   staged before concurrency-on ships.
4. Upstream 0.17 churn — **measured (2026-07) to be minimal on every surface we implement**;
   contained by the `runtime_io.zig` seam, the `operate`-centric vtable, and deliberate
   cherry-picks. The real cost sits in the **decoupled rebase campaign (sized L)**: LLVM-22
   bootstrap rebuild; a severe both-sides rewrite of `src/codegen/x86_64/CodeGen.zig`; the
   upstream `Coff.zig` rewrite vs our fix; and ZIR-internal drift (`@cImport` removed,
   `errdefer`-capture removed, `std.builtin`→`std.lang`, `@typeInfo`/`@bitCast` changes)
   requiring revalidation of our 13.5k-line `zir_api.zig`/`zir_builder.zig`.
5. Darwin teardown ordering — dedicated Phase-1 test, not discovered in production.

## 8. What approval covers

Approving this plan locks in: the **stay-on-0.16 sequencing** (no rebase before concurrency
work; the full 0.17 rebase is a decoupled campaign timed to the 0.17.0 release); the phase
ordering and exit gates above; **Decision Gate 0** (a
spawn site's manager binding is comptime-resolvable — the language rule everything in Phase 3
stands on); the scheduler-owns-`Io`-vtable architecture (pending only S0.5's confirmation); the
Windows-Threaded and wasm-capability-error v1 postures; and the division of labor in §4.
Anything the experiment gates overturn comes back as a plan amendment, not a silent change.

Approval occurred via the implementation directive of 2026-07-04, which directed full
phase-by-phase execution of this plan.

---

## Appendix A — S0.5 scheduler architecture decision (Phase 0 exit)

**Decided 2026-07-04.** Evidence basis: E1 (including the post-clobber-fix re-measurement),
E9, and E10, all recorded in `docs/concurrency-bench-results.md`. This memo is the Phase 0
exit artifact; Phase 1 implements it. It confirms the architecture §8 held pending S0.5.

### A.1 The decision

**Zap's scheduler is a bespoke M:N run-queue scheduler built directly on the fork's
`lib/std/Io/fiber.zig` context-switch primitive, and it implements the `std.Io` vtable
itself** (operate-centric, per §3). Neither fork `std.Io` backend is used as the scheduling
substrate. The rejected alternative — driving processes through `Io.Evented`/`Io.Threaded`
as-is via `Io.async`/`concurrent`/`Select` — is rejected on three grounds, each quantified:

1. **Spawn architecture.** The target is sub-µs spawn (ARC default; 1–3 µs acceptable for
   heavy-init managers). Post-fix, `Io.Evented` (Dispatch) spawn sits at **19.1 µs windowed /
   19.8 µs serial / 24.7 µs group** per task — 6–25× outside the band — and the cost is
   structural, not a bug: ~60 MiB address-space reservation per fiber
   (`Io/Dispatch.zig` `Fiber.min_stack_size`), a fresh stack mmap per spawn (E9 prices that
   alone at **1.65 µs**), and a µs-scale GCD enqueue per task. Fixing the miscompilation did
   not move it (windowed spawn went 30 µs → 19 µs on a much quieter session; the shape is
   unchanged). Fixing the *architecture* means rewriting the backend's fiber/stack/admission
   layer — i.e. building the bespoke scheduler anyway, inside GCD's constraints. E9 shows the
   substrate floor we build on instead: **3.20 ns** one-way switch, **8.99 ns** spawn on a
   pooled stack — roughly two orders of magnitude of headroom under sub-µs for pid-slot,
   manager-init, run-queue, and safepoint bookkeeping.
2. **Scheduling control.** The plan requires preemption budgets (reduction accounting fed by
   the three-layer safepoint design), a LIFO slot for message-driven wakeup locality, work
   stealing, a per-scheduler timing wheel, a flag-only watchdog, a per-process manager
   context resolved at spawn, and — non-negotiably (§2 decision 11, Phase 1.5) — a **seeded
   deterministic mode**. Dispatch delegates scheduling to opaque GCD queues: no run-queue we
   own, no admission control, no determinism, no budget hook. `Io.Threaded` posts fine
   micro-numbers post-fix (1.38 µs windowed spawn, 1.79 µs RTT) but is 1:1 — every
   receive-suspended process holds an OS thread, so BEAM-scale process counts (10⁵–10⁶) are
   architecturally unreachable. No amount of backend fixing yields these properties; owning
   the run queue does, and E9's mechanism data (below) prices every piece we must build.
3. **Reliability posture.** Post-fix, Dispatch still exhibits an **intermittent, race-like
   `spawn-serial` SIGSEGV** (3 of 5 full-workload runs) plus the `deinit` compile error, and
   upstream labels these backends explicitly experimental. Not load-bearing for the decision
   — grounds 1–2 suffice — but it confirms the runtime cannot be hostage to backend
   scheduling internals we do not control.

**The decision survives the clobber-fix reinterpretation of E1 — stated explicitly for the
record.** The E9 fork fix (`74c0b87fe5`) eliminated both deterministic E1 segfaults, and the
re-measured Dispatch ping-pong RTT is **1.01 µs median / 0.95 µs min** — *inside* the
2–3×-BEAM target band and better than Threaded's 1.79 µs. E1's original claim that a fixed
Dispatch "cannot reach BEAM-class spawn/send" is therefore **corrected to spawn only**: the
send path is vindicated, and the rejection rests on the spawn architecture, on scheduling
control, and on the residual instability — none of which the fix touched. The escalation
called by E1's kill criterion stands on the post-fix numbers.

**Why still implement the `std.Io` vtable:** any Zap-runtime or FFI code doing I/O through
`Io` must suspend the calling *process*, not block the scheduler thread (§3). The
implementation is `operate`-centric (upstream is folding per-function entries into the
`Operation` union — measured drift since 0.16.0 is one function folded plus renames), and
task admission uses the newly-legalized lazy-start semantics of `async`/`groupAsync`
(upstream `56265d6f99`): defer fiber assignment until first suspension/await — the
BEAM-style admission shape.

### A.2 Binding design consequences for Phase 1

Each is a design commitment, not a suggestion; each cites its evidence.

1. **Pooled, fixed-reservation, guard-paged, lazy-commit stacks — pooling is mandatory.**
   E9: fresh stack (mmap + guard mprotect + first-page fault + munmap) costs **1,646 ns**
   vs **8.99 ns** spawn on a pooled stack — a 183× penalty that alone consumes the entire
   sub-µs spawn budget. The spawn hot path never calls mmap; stacks come from a
   per-scheduler pool with a high-watermark bound, and fresh mapping happens only on pool
   growth.
2. **Darwin park/wake = the OS futex; EVFILT_USER only for the I/O poller.** E9: all four
   kernel mechanisms land within ~20% (792–958 ns median), so semantics decide —
   `os_sync_wait_on_address`/`os_sync_wake_by_address_any` (with `__ulock_wait2`/`__ulock_wake`
   as the pre-14.4 fallback, gated exactly as the fork's `Io.Threaded` does) atomically
   couples parking with a run-queue state word, needs no per-thread kernel object, and wakes
   as a no-op when nobody is parked. The kqueue `EVFILT_USER` path is reserved for the one
   thread parked inside the kqueue I/O poller, where the unified wait point is worth its
   +40 ns.
3. **Spin-then-park, threshold 1–2 µs.** E9: a spinning thread observes a handoff in ~83 ns;
   a parked wake costs ~900 ns median end-to-end. Crossover ≈ one park cost → spin a few
   hundred `spinLoopHint` iterations (1–2 µs on M4) before parking. This keeps
   same-scheduler RTT in the tens of ns (6.4 ns switch pair + 8.7–16 ns queue floor, E1/E9)
   and bounds cross-scheduler RTT by two parked wakes ≈ 1.8 µs — inside the ≤2–3 µs band.
4. **`current_process` is resolved once per scheduling quantum** and carried in a register or
   parameter across the runtime hot path — never re-resolved per dispatch site. E10: on
   Darwin the threadlocal read is a call through the TLV thunk, and LLVM's hoisting is
   unreliable (per-alloc in the pure shape, per-list in the mix shape). The scheduler writes
   the process pointer at quantum entry; runtime kernel code receives it, not the TLS slot.
5. **Alloc hot path is monomorphized *and inlined*; the PCB manager vtable serves cold paths
   only.** E10: vtable dispatch costs **+13.8%** on the pure-alloc shape (≈5× the E2 kill
   criterion) and even a direct non-inlined call costs +6.2%, so the hot-path rule is
   inlined specialization, not "direct call per model". The cold-path arm is empirically
   sound: +4.7% relative on the realistic mix, +0.09–0.22 ns absolute.
6. **Role of the remaining fork backends.** `Io.Threaded` is the Windows (and
   wasm-with-host-threads) capability-matrix fallback (§1 item 5, Phase 7) — real 1:1
   threads, documented semantics differences; it is not a performance tier. The Evented
   backends are retained as *event-source references*: their kqueue/io_uring/GCD-source
   integration informs our poller (Phase 4), but their fiber scheduling, stack policy, and
   admission are not used. Remaining Dispatch defects (residual `spawn-serial` race, `deinit`
   compile error, 60 MiB `min_stack_size`) stay on the fork-hygiene track, off the
   campaign's critical path.

### A.3 Phase-1 kernel work-item deltas

- **1.1 (PCB)** — "fiber + stack reservation" is now concrete: fork `fiber.zig` `Context` +
  a **per-scheduler stack pool** (fixed reservation, guard page, lazy commit,
  high-watermark-bounded free list). The stack pool is a named deliverable of 1.1, with the
  E9 9 ns pooled-spawn floor as its pool-hit reference.
- **1.4 (spawn/exit)** — "pool-only hot path" now has a budget: spawn ≤ 1 µs = 9 ns
  floor + pid slot + manager init + enqueue; the path provably performs no mmap/munmap.
  Phase 1's E1 re-run gates against the **post-fix** E1 ledger rows.
- **1.4/1.5 (new sub-item: idle park/wake)** — the single scheduler parks on the decided
  futex primitive when the run queue is empty and is woken by timer/cross-thread test
  senders. This pulls the *mechanism* half of Phase 4.1 forward; **4.1's open question
  ("parking via Evented wakeups … measure, R7") is closed for Darwin** — run-queue parking
  = OS futex, poller = EVFILT_USER. R7 narrows to the Linux poller counterpart
  (eventfd vs io_uring `MSG_RING`), measured in Phase 4.
- **1.5 (deterministic mode)** — unchanged in scope, but S0.5 is its precondition: it exists
  *because* we own the run queue; Evented-as-is could never have provided it.
- **1.6 (observability) / PCB ABI** — the per-quantum `current_process` discipline (A.2.4)
  is part of the scheduler↔kernel ABI from day one; every kernel entry point that can
  allocate takes the process pointer, and only quantum entry touches the TLS slot.
- **3.2 (monomorphization hybrid)** — unchanged, with E10 sharpening the acceptance bar: a
  "specialized" hot path whose alloc fast path is not inlined has already paid half the
  vtable penalty (+6.2%); the verifier red-flag for ICF-unfoldable specializations gains a
  companion check that hot-path specializations actually inline the alloc fast path.

### A.4 Open questions deliberately deferred

1. **Register vs parameter for the current-process pointer on aarch64.** x18 is reserved by
   the Darwin platform ABI, so a globally reserved register is likely unavailable there;
   Phase 2 decides between parameter-threading and a per-quantum TLS write with measured
   numbers (E10 gives the per-site cost either choice must beat). *[Amended from "Phase 1
   decides": the landed Phase 1 kernel is fully parameter-threaded internally (the mechanism
   is in), but the choice only becomes measurable once compiled Zap code exists to exercise
   per-site cost — the `scheduler.zig` module doc records the same Phase 2 deferral.]*
   *[Re-pointed again to Phase 3 (P2-R1/D3): the cost this decision must beat — the alloc-path
   current-process lookup on the hot path — does not exist until per-process memory managers
   land (item 3.1); until then there is no per-site alloc cost to measure. Phase 2's emitted
   code reaches the current process through the ambient `zap_proc_current()` runtime lookup
   (`src/runtime.zig` ~4448), not a threaded parameter or reserved register, so the
   register-vs-parameter tradeoff is genuinely a Phase-3 measurement once managers make the
   lookup hot.]*
   *[RESOLVED (P3-J1, 2026-07-07): per-process managers landed (item 3.1), making the
   alloc-path lookup hot and measurable. Measured with the E10 methodology (OQ1 section of
   `docs/concurrency-bench-results.md`): the **published-per-quantum global**
   (`zap_proc_active_arc_context`, one `LDR` — the scheduler writes the running process's
   private context at quantum entry, the runtime reads it in `currentManagerContext`) costs
   **+2.2% pure / +0.7% mix** over the register/parameter ceiling — inside the E2 budget —
   while the Phase-2 ambient `zap_proc_current()` per-alloc CALL costs **+8.8% / +3.1%** (a
   load beats a call, consistent with E10). **DECISION: P3-J1 ships the published-per-quantum
   global; ambient is rejected.** The register/parameter ceiling (the standing lean) is the
   J2 monomorphization arm's target (item 3.2) — it recovers the residual +2.2%, which only
   matters on a pure-alloc tight loop, and requires compiler frame-threading of the context
   through emitted code. OQ1 is resolved: published now, register/parameter as the J2
   refinement.]*
2. **Linux poller wakeup primitive** — eventfd vs io_uring `MSG_RING` (E9 was Darwin-only);
   measured when the Phase 4 poller lands.
3. **Stack-pool sizing/watermark policy and its interaction with Darwin teardown** — decided
   empirically by Phase 1.7's spawn/die-cycle test. *[Update (Phase 1 close): 1.7 landed as the
   measuring instrument (the teardown-stress harness + soak knob); the sizing decision itself —
   including whether cached stacks get `madvise(MADV_FREE)`-style RSS decay — re-points to when
   real managers land (Phase 2 item 2.4 / Phase 3 items 3.x), measured with that harness. The
   Phase 1 constants remain the documented ARC-slab-mirror initial policy.]*
4. **Root cause of the residual Dispatch `spawn-serial` race** — fork-hygiene track.
   **Triaged (job G2, 2026-07-05): classified Dispatch-specific**, evidence in
   `spike/concurrency-e1/triage/` (6 lldb crash captures) and the E1 †-note in
   `docs/concurrency-bench-results.md`. The fault is a fiber-lifetime race in
   `lib/std/Io/Dispatch.zig` — `await`'s fast path `Fiber.destroy`s the fiber
   allocation upon seeing `Fiber.finished` while the finishing task is still on
   that fiber's stack in `yield(.nothing)` (cap-06 caught the awaiter mid-`munmap`
   of the exact fiber address held by the crashing worker) — **not** the shared
   `Io/fiber.zig` context-switch machinery (same-binary pingpong controls pushed
   millions of switches through the same asm crash-free; every fault consumed
   freed/recycled Dispatch-owned memory) and not libdispatch (its frames were
   parked/idle in every capture). **Not a Phase 1 entry blocker.** Phase 1 must
   carry the design invariant this bug violates: a finished fiber's stack may not
   be freed or recycled until the finishing fiber has provably left it —
   completion publication happens off-stack, or destruction defers through the
   scheduler. The Dispatch-side fix itself stays on the fork-hygiene track for
   the fork's own I/O story.
5. **Windows budget/watchdog semantics on the 1:1 Threaded fallback** — documented capability
   difference, scoped in Phase 7.2.

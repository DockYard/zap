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
    and out-of-union send as a send-site compile error against the typed `Pid(M)`. **Deferred:**
    the two ergonomic forms that let a process fix ONE message type across all
    of its receives — now item **2.2a** below. Phase 2 requires the type at
    each `receive` instead; neither deferred form changes the sendability/exhaustiveness rules,
    only where M is written.]*
  - **2.2a (DEFERRED — post-v1 ergonomics; decision recorded P6-R1).** The numbered owner for
    the two deferred spellings: (a) inference of M from the union of a process's receive
    patterns, and (b) the `process … receives M` block-annotation form. Explicitly OUT of v1:
    the per-receive `<M>` token is fully expressive, neither form changes the
    sendability/exhaustiveness rules (only where M is written), and both are pure
    front-end sugar over the shipped checker. Picked up post-v1 on user-demand evidence,
    not on a phase trigger.
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
    **P3-J5-VERIFY (2026-07-08):** gate-ON `:test_concurrency` runs **59/0** (117
    assertions, exit 0) at HEAD via `zap run test_concurrency` (**56/0** as of
    P3-J5; +1 P3-J6 `orc_test.zap`, +2 P3-R1a per-process-dispatch tests),
    including `move_send_test.zap`'s 3 `Process.send_move` cases; and the by-construction
    scheduler-local-refcount invariant is now ALSO proven BY MEASUREMENT — the
    cross-thread detach/adopt move path (`cross_thread_stress.zig`
    `runMoveSendArcStress`, the one shape where a real heap cell crosses threads)
    is ThreadSanitizer-clean at 8k + a 20k-cell soak, leak-exact (§ E5).
    **R4 residual:** `Map` still uses `c_allocator` (not the large path), so a `Map`
    send degrades to copy until `Map.bufferAlloc`/`bufferFreeShallow` migrate to
    `containerBufferAlloc`/`Free` (the exact gate-branch `List` already carries);
    the O(1) map-send fix is that one-call-site migration + extending
    `movableFlatListCell` to maps. Nested graphs (interior ARC children in separate
    cells) also copy. *[RESOLVED by item 6.1a (P6-J1, 2026-07-10): the migration and
    `movableFlatMapCell` landed; a large uniquely-owned flat `Map` now moves O(1) —
    see 6.1a's DONE record and the E6 re-run. Nested graphs still copy, as designed.]*
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
  - **ORC status — honest record (P3-R1a, 2026-07-08).** ORC's cycle collection is proven at
    the **manager-unit level**: the manager's 10 Zig unit tests build real cycles
    (self-referential, two-node, three-node, and a join-node) through the ORC ABI, drop them,
    and collect them leak-exact, with a **negative control** (collector off ⇒ the cycle leaks)
    and an externally-reachable-cycle-NOT-collected control. The per-process **dispatch is
    wired** and proven gate-ON: an ORC process's release reaches ORC's own machinery on its own
    ORC context (`test_concurrency/per_process_refcount_dispatch_test.zap`, checksum 240). What
    is NOT proven — and is currently INFEASIBLE — is a **surface-level end-to-end** test: a Zap
    program that builds a reference cycle and observes it collected. Two reasons: (1) Zap is
    **immutable**, so no `A → B → A` back-edge is expressible at the language surface (an ARC
    reference cycle cannot be constructed in Zap code); (2) ORC's `CYCL` per-type trace
    auto-registration (`register_cell_type`) is not yet wired to the runtime container types.
    So **ORC-as-a-correct-per-spawn-manager is DONE**, while ORC's user-visible cycle-collection
    VALUE is **DORMANT-UNTIL-MUTATION** — it unlocks with opportunistic-mutation / mutable-closure
    primitives (future work). This item is manager-level-proven + dispatch-wired, NOT
    "surface end-to-end proven." Follow-ons: (i) wire `CYCL` `register_cell_type` auto-registration
    to the runtime container types; (ii) the `Map` O(1)-move migration (item 6.1a) *[DONE —
    P6-J1, 2026-07-10: ORC's v1.2 relocate slots are also now REAL — detach/adopt wired through
    the production SlabHeap `large_head` (mirroring ARC), `free_detached_region` context-free via
    the shared `LargeHeader` ABI, guarded by `collectorStateBlocksMove` (a buffered/non-black cell
    declines the move; a flat move-eligible cell is provably never buffered — `noteDecrement`
    skips `possibleRoot` for `deep_walk == null` and unregistered types). Cross-manager moves
    (ARC↔ORC, both `.refcounted`) ride the byte-identical mirrored `LargeHeader` contract, proven
    end-to-end in `test_concurrency/orc_move_test.zap` (ORC→ARC, ARC→ORC, ORC→ORC). Test builds
    (DebugAllocator heap) decline detach, honestly — the SlabHeap path is unit-proven +
    gate-ON-proven.]*; (iii) mutation
    primitives that make reference cycles constructible at the surface.
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
  **DONE (P5-J1, 2026-07-09, `538adbb`)** — the kernel signal runtime (`signal.zig`:
  link/monitor sets, reason categories, `trap_exit`, teardown propagation) + the
  `zap_proc_link/monitor/exit_signal/kill/set_trap_exit/await_signal` intrinsics
  (`abi.zig`) + the `lib/process.zap` wrappers with the reason-atom identities
  registered FROM Zap (`register_reason_atoms` — never hardcoded in the compiler);
  exit-signal ordering merged with pairwise FIFO; `kill` untrappable → `killed`
  (`test_concurrency/signal_test.zap`). "Distinct Select arm" was reframed: there
  is no Select surface — signals ride the one mailbox as signal-kind envelopes.
- **5.2** Runtime local registry (atomic register/lookup, register-then-crash race handled).
  **DONE (P5-J2, 2026-07-09, `308e1b0`)** — `registry.zig` (atomic name→pid table,
  generation-validated liveness so a dead registrant is a lookup MISS) +
  `Process.register/unregister/whereis`, send-by-name, and atomic
  `spawn_link`/`spawn_monitor` (`test_concurrency/registry_test.zap`).
- **5.3** Pure-Zap stdlib: `lib/supervisor.zap` (strategies, defaults, shutdown protocols,
  start left→right/terminate right→left), `lib/task.zap` (`Task.async` → `Future(T)`,
  `call` with internal correlation-token skip — the ref-trick receive mark lands here),
  dead-letter sink + telemetry.
  **DONE (P5-J3, 2026-07-09, `b0e3306`)** — `lib/supervisor.zap` in PURE ZAP over the
  J1/J2 intrinsics: all four strategies, restart types, restart-intensity breaker,
  left→right start / right→left terminate, the three shutdown protocols, nested
  supervision trees; inverted-control loop (library owns policy as data transforms,
  user module owns the tiny start loop) so no function value crosses a struct
  boundary (`test_concurrency/supervisor_test.zap`). The `lib/task.zap` half landed
  in P5-J4 (below); the keep-alive dead-letter SINK remains open — today's
  dead-letter path is the non-crashing per-process termination + pid-table
  telemetry, not a sink process.
- **5.4** `spawn_link`/`spawn_monitor`; `Process` module completed; `@doc` everywhere.

  **P5-J4 (2026-07-09):** `Task.async`/`Task.await` (`lib/task.zap`) + the typed synchronous
  `Process.call`/`Process.reply` over a parametric `Call(request_type)` envelope
  (`lib/process.zap`) landed PURE ZAP over the new internal correlated receive — research
  §6.2's ref-trick receive-mark, resolved internal-only per rev-2 §5.2 / decision 7 (never
  surface syntax; the steady-state exhaustive `receive` is untouched). Elixir-aligned failure
  surface: `await`/`call` EXIT the caller on worker/server crash (with the dead process's
  reason — a dead server errors immediately via the monitor's `noproc` `DOWN`, never the
  timeout), on `:timeout`, and (await) on `:not_owner`; every return path demonitors WITH
  FLUSH (`Process.demonitor(ref, [:flush])` semantics) so a late `DOWN` can never poison a
  later receive. Kernel (the ONE sanctioned deviation from pop-head-and-dispatch,
  `mailbox.zig` module doc): mark prepare-before-mint/bind-after, correlated scan+extract
  that leaves every skipped message queued in order, and an any-push wake flag armed
  race-free by a release-sequence no-op CAS on `producer_tail` (zero new fences on the push
  hot path); `scheduler.zig` adds `receiveCorrelated`/`awaitCorrelated` (reply stashed
  per-process for the two-call typed decode), `signalDemonitorFlush` (three-case
  teardown-race analysis; the in-flight-`DOWN` case awaits it via the mark — still O(1)),
  and teardown reclaim of a stashed reply. Compiler: applied parametric structs are
  walker-sendable (`types.zig`), `take_correlated_message` type-directed decode intercept
  (`zir_builder.zig`), the monomorphizer sees through macro-expansion blocks
  (`monomorphize.zig` `effectiveExprType`), and macro-cloned anonymous functions get
  desugar-unique names (`desugar.zig` — a macro quote's `__anon_fn_N` was cloned into every
  expansion and the ZIR name-keyed dedup silently fused all Task workers into one).
  **R8 MEASURED**: a correlated call over a 10k-message backlog examines **2 envelopes**
  (kernel unit proof asserts exactly 2 vs 10_002 for a head scan; the gate-ON test asserts
  `Process.correlated_receive_visits()` delta < 10 and drains the backlog in order — no
  loss, no reorder). Gate-ON `:test_concurrency` **112/0** (251 assertions; 99 baseline + 7
  Task + 6 call); kernel tests 209/209 both modes; `-fsanitize-thread` clean (204 pass / 5
  skip / 0 fail).

  **P5-R1 (2026-07-09):** the Phase-5 gap-resolution batch — every finding of the P5
  review resolved or formally deferred with a numbered owner.
  - **S1 (BLOCKING — the supervisor stray-signal hang).** `reap_exit`/`wait_exit`
    popped signals destructively and DISCARDED any not from the awaited pid, so a
    sibling crashing during a shutdown sweep produced (a) a FOREVER-blocked reap
    when the sweep later reached the already-dead sibling (one_for_all: kill C, A
    crashes inside B's `:timeout` window → hang), and (b) a silently-lost permanent
    child under `rest_for_one` (an out-of-scope crash discarded → stale `live_pids`
    slot, never restarted). Fixed in PURE ZAP (`lib/supervisor.zap`): every signal a
    wait pops that is not the awaited exit is COLLECTED (`SupervisorStrays` — bounded
    by child count + the parent's one order) and folded back into supervisor state
    after the sweep: a collected child death is handled as a fresh exit (restart
    type, intensity charge, strategy scope whose own sweep is SEEDED with the
    unresolved strays so an already-collected pid is never re-reaped, and whose
    restart queue MERGES in spec order), a zeroed-slot stray is ignored (OTP's
    exit-from-unknown-pid rule — no double intensity charge), and a non-child stray
    (the parent terminating the supervisor mid-sweep) is honored as a shutdown
    order. **D4 rode along**: `wait_exit` now waits on an ABSOLUTE
    `monotonic_millis` deadline — strays consumed while waiting never restart the
    child's grace period. Both review-specified acceptance tests are seeded in
    `supervisor_test.zap` ("stray signals during teardown"): the one_for_all
    stray-during-`:timeout`-shutdown case (no hang, all three restarted) and the
    rest_for_one out-of-scope crash (the permanent child IS restarted).
  - **S2 (signals × the typed receive — SAFE SUBSET landed, tuple-decode deferred
    as item 5.5).** The abort semantics are GONE from every user-reachable path:
    `await_signal` no longer panics on a user-message head — it extracts the OLDEST
    signal envelope and leaves user messages queued in order (`mailbox.zig` gains
    ref-less class-match kinds `signal_any`/`user_any` on the P5-J4 scan-extract
    machinery); the steady-state typed `receive` (`zap_proc_receive_park`) is the
    mirror image — it takes the oldest USER envelope and leaves signal envelopes
    queued for `await_signal`, so a trapped `{'EXIT', …}` reaching a `receive Atom`
    is never mis-decoded as the message type (Erlang: an unmatched trapped exit
    sits in the mailbox); and the `receive … after` wait (`receiveWaitTimeout`) is
    signal-aware via a non-consuming `scanForMatch` probe + the correlated-receive
    any-push-wake park protocol, so a signal-only mailbox times out instead of
    parking the receive past its deadline. New kernel intrinsic
    `zap_proc_await_signal_timeout` (the timed signal wait `wait_exit` stands on).
    Gate-ON proofs in `signal_test.zap` ("typed receive and signals") and
    `supervisor_test.zap` (a registered supervisor sent a stray user message skips
    it — S2×S1). The R8 visit counter now counts REF-correlated scans only, so the
    class scans cannot pollute the O(1)-from-mark telemetry.
  - **S3/S4/S5 + N3 (Erlang `exit/2` fidelity, `lib/process.zap`).**
    `exit_signal(pid, :kill)` routes to the UNTRAPPABLE kill path — a trapping
    target dies `:killed` (only exit/2's literal `:kill`; a link-cascaded `:kill`
    from `exit_with(:kill)` stays trappable, correct Erlang). `exit_signal(self(),
    :normal)` from a NON-trapping process terminates the caller `:normal`
    (erlang.org exit/2's self-normal special case). `spawn_link`/`spawn_monitor`
    call `ensure_reason_atoms_registered` BEFORE the link/monitor exists, so a
    first-op `spawn_monitor` `DOWN` carries `:normal` — proven in a FRESH gate-ON
    binary by the `zir_integration_tests.zig` first-op test (in-suite it is
    unobservable: an earlier test always registers the atoms). N3's missing direct
    test added: a trapping process linked to a KILLED process receives
    `{'EXIT', _, :killed}` as a message.
  - Gate-ON `:test_concurrency` **121/0** (278 assertions; 112 baseline + 6 signal
    + 3 supervisor), order-robust across shuffle seeds; kernel tests green both
    modes (+5 mailbox class-scan/probe unit tests).
- **5.5** Typed signal-decode in `receive` (the S2 deferral, formally owned here).
  Today a trapping process OBSERVES signals only through the `await_signal` surface;
  the typed `receive` skips signal envelopes entirely (they stay queued). This item
  wires the receive lowering to decode a signal envelope — via the existing
  `zap_proc_envelope_signal_*` accessors — into `{'EXIT', from, reason}` /
  `{'DOWN', ref, pid, reason}` tuples and match them against the arms, so a receive
  whose message union includes the exit-tuple type handles signals in stream order
  with user messages (research §6.7 "a trapping process sees exits as ordinary
  messages", fully). Depends on the message-union work (item 2.2): the scrutinee
  must be a union of the message type and the signal-tuple shapes, and
  exhaustiveness must reason over both. Until then the contract is the S2 safe
  subset documented on `Process.await_signal`.
- **5.6** `simple_one_for_one` DYNAMIC child management (the D2 deferral):
  `start_child`/`terminate_child` at runtime over ONE template spec — today the
  strategy is implemented as one-for-one restart scope over a STATIC homogeneous
  child list (each instance pre-declared). Needs a supervisor-state API for
  appending/removing instances and pid-keyed (not spec-index) accounting.
- **5.7** Named `Process.call` (the D5 deferral): `Process.call(name :: Atom,
  request)` resolving through `whereis` with the dead-name `:noproc` exit surface
  (Elixir `GenServer.call(name, …)` parity). Today `call` requires a typed pid;
  send-by-name exists but the correlated call surface does not.
- **5.9** Supervisor parent-vs-unknown-pid signal policy (round-2 finding; the
  round-1 D3 fidelity nuance): today ANY trapped signal from a non-child pid is
  treated as the parent's shutdown order and tears the tree down; OTP terminates
  only on the REAL parent's exit and IGNORES unknown-pid EXITs. Corollary: a live
  child explicitly `exit_signal`-ing its trapping supervisor is misclassified as
  that child's death. Fix: record the actual parent pid at supervisor start and
  classify strays three ways (child / parent / unknown-ignore). Behavior is
  documented in `lib/supervisor.zap`; requires user code signaling the supervisor
  directly to trigger. Related note folded into 5.5's scope: a supervisor never
  CONSUMES skipped user messages (they stay queued indefinitely — OTP
  logs-and-drops unknown messages); the drain/dead-letter behavior should land
  with 5.5's typed signal-decode so both unknown-message classes get one policy.
- **5.8** Gate-ON Zest suite under `ZAP_SCHED_SEED` (the D8 owner): under the
  seeded deterministic scheduler exactly the two `SafepointTest` preemption-ORDERING
  tests fail (verified 2026-07-09: `ZAP_SCHED_SEED=7` → 121 tests, 2 failures — the
  "quick process replies before the CPU-bound one" P2 assertions), because the
  simulator's seeded schedule is under no obligation to interleave the co-runnable
  quick process before the slow one finishes; preemption CORRECTNESS is asserted,
  ordering is not guaranteed. Fix the two tests' ordering assumption under the
  simulator (assert progress/preemption without demanding arrival order — e.g.
  reply-set equality or a reduction-count bound instead of arrival order). Until
  then the Phase-5 seeded-determinism exit gate is SCOPED to kernel-level
  determinism (below); everything else in the gate-ON suite — including the whole
  supervision suite and the P5-R1 stray tests — is verified seed-clean.
  (P6-J5 note: the count is now THREE — the new "CPU-bound tight unrolled loop is
  still preempted" test is the same ordering shape and inherits the same
  under-simulator caveat; same fix applies.)

Exit gate: supervision-tree Zest suite (restart intensity, rest_for_one ordering, brutal_kill
timing) under seeded determinism; R8 selective-receive benchmark (10⁶-deep mailbox, O(1)
correlated replies). *[R8 discharged at 10⁴ depth by the P5-J4 operation-count proof above —
visits are independent of backlog depth by construction (the scan starts at the mark), so the
10⁶ variant is a constant-factor rerun if ever wanted.]* *[Seeded-determinism scope (P5-R1,
D8): the gate holds at KERNEL level (the `deterministic_mn.zig` seeded suites) and for the
supervision tests, which pass under `ZAP_SCHED_SEED`; the full gate-ON Zest suite is
seed-clean except the two pre-existing `SafepointTest` ordering assertions, owned by item
5.8 — not a Phase-5 signals/supervision regression.]*

### Phase 6 — Performance tier (L)

- **6.1** Same-model O(1) region move: region-closure verifier constraint over
  `src/region_solver.zig` + escape lattice + uniqueness facts; slab detach/adopt (**E5**:
  truly O(1) and leak-free, else copy-on-move stays, documented).
  **DONE — absorbed (annotation added P6-R1).** The substance closed elsewhere: **E5** +
  P3-J5 landed the same-model O(1) move for flat `List` (detach/adopt of the cell's
  page-backed large-block backing through the REFC v1.2 relocate slots — truly O(1) and
  leak-free, so copy-on-move did NOT stay for the eligible shapes), and item 6.1a below
  (P6-J1, `d14731c`) extended it to flat `Map`. Eligibility is proven by the comptime
  shape predicates (`movableFlatListCell`/`movableFlatMapCell`) plus the runtime
  rc==1/same-model/relocatable gates, with `send_move`'s consuming convention
  type-checked at the send site — the originally-sketched region-solver/escape-lattice
  verifier constraint was not needed for these shapes. Slab-backed (small) cells and
  nested graphs still copy, documented at 6.1a.
- **6.1a** `Map` O(1)-move migration — the numbered owner for the R4 residual
  recorded under item 3.4. Today `Map` backing buffers allocate through
  `c_allocator`, NOT the sending process's ARC core large-block path, so every
  `Map` send degrades to the cross-model copy path. Per **E6** that copy is
  catastrophic for maps specifically: `Map` reconstruct hits **2.19 ms at 1 MB**
  (95× the serialize half, versus `List`'s 2.6×) because the receiver rebuilds
  the hash table from scratch rather than re-parenting a page. The fix is the
  one-call-site migration already carried by `List`: route `Map.bufferAlloc`/
  `bufferFreeShallow` through `containerBufferAlloc`/`containerBufferFree` (the
  exact gate-branch `List` uses, item 3.3 R4) and extend `movableFlatListCell`
  to a `movableFlatMapCell`, so a large uniquely-owned `Map` re-parents in O(1)
  through the same REFC **v1.2** relocate slots (`detach_region`/`adopt_region`/
  `free_detached_region`, spec §8.6) instead of copying. Nested graphs (interior
  ARC children in separate cells) still copy. Exit: an E6 `Map`-crossover re-run
  shows the move path replacing the 2.19 ms/MB rebuild for large uniquely-owned
  maps. `docs/concurrency-bench-results.md` § E6.
  **DONE (P6-J1, 2026-07-10, `d14731c`)** — the one-call-site migration landed:
  `Map.bufferAlloc`/`bufferFreeShallow` carry the exact gate-branch `List` uses
  (gate-ON → `containerBufferAlloc`/`containerBufferFree`, the running process's
  private manager heap — a killed process's map cells now also reclaim wholesale;
  gate-OFF → `c_allocator` byte-identical to before, plus the previously-missing
  layer-1 `procReductionTick` alloc piggyback, comptime-elided gate-OFF), and
  `movableFlatMapCell` extends the move predicate to flat `Map(scalar, scalar)`.
  The layout-survival argument is documented at the predicate: the cell is one
  contiguous `[Self | buckets | entries]` block with NO interior pointers —
  buckets reference entries BY INDEX, the hash seed travels inside the cell, and
  section addresses are recomputed from the cell pointer per access — so the
  adopted map is usable IMMEDIATELY (no rebuild, no fix-up; pointer identity
  preserved, E5 mechanism). Alongside: the v1.2 relocate slots now dispatch
  per-process under `multi_manager_active` (`currentRefcountCapability`, closing
  the same type-confusion hazard P3-R1a closed for retain/release), and ORC's
  relocate slots are wired through its production SlabHeap large path with a
  collector-state guard (see 3.4 follow-on (ii) — done). Exit met: the E6
  re-run shows the flat-`Map` move RTT flat at ~0.24–0.29 µs (0.11 µs on a
  second run — sub-µs core-placement variance), SIZE-INDEPENDENT 16 KB→1 MB,
  vs the paired-run 5.2 ms 1 MB copy round trip (≈20,500×) — § E6 "P6-J1
  Map-move re-run". Nested graphs (interior ARC children) still copy,
  documented.
- **6.2** `Blob` (atomically-refcounted immutable byte buffer; naming folds into the pending
  V8→dense rename sweep): the one sanctioned share tier; global immutable registry
  (`persistent_term` analogue).
  **DONE (P6-J2, 2026-07-10, `0b5631c`)** — the share tier landed end to end. The blob domain
  (`src/runtime/concurrency/blob.zig`) is its own allocation domain (page-backed
  `[header | bytes]` payloads owned by NEITHER manager — the envelope-pool third-domain
  discipline): a segmented, type-stable generational slot table whose packed per-slot
  `{share_count, generation}` word is the one SHARED (cross-thread) atomic refcount in the
  system — per-process ARC/ORC refcounts also use atomic instructions (per the manager ABI)
  but stay thread-confined; only the blob count is ever CONTENDED across threads — (the
  freeing 1→0 CAS bumps the generation in the same word, so stale/forged handles can never
  resurrect or fault — every validate/mutate touches only stable slot memory; Constraint 3
  atomicity confined to this module + the two cold-path spinlocks). Handles are
  `{slot, generation}` `u64`s carried by the Zap-level `Blob` struct (`lib/blob.zap`)
  whose reserved `zap_blob_handle` field the runtime recognizes STRUCTURALLY (field shape,
  never struct name) — top-level messages only in v1: `isWalkerSendable` rejects nested
  blobs (an interior flight reference would leak through dead-letter/teardown; the
  serialized-payload cleanup walker is the documented follow-on — item 6.2a), mirrored in the checker
  (`typeIsWalkerSendable`'s depth-gated blob arm) and locked in the N10 vocabulary test.
  A send is ownership-gated (per-process `BlobLedger`, a PCB field drained at teardown
  step 4b — the drop-list discipline) + one atomic flight retain riding the EXISTING
  moved-envelope transport (`zap_proc_send_moved` with a `zap_blob_flight_release`
  reclaim hook), so dead-letter undo and receiver-teardown drain are leak-exact for free;
  the receiver adopts the flight reference into its own ledger — zero bytes copied,
  same-model AND cross-model (the model-independent payload). Slices/`to_string` COPY OUT
  (the anti-pin rule; no sub-blob aliasing). The persistent-term registry is
  runtime-owned: `put` replaces under a write lock (old value released after publication,
  dying with its last outside reader); `get` is a LOCK-FREE seqlock read + gen-validated
  retain CAS (a racing replace fails the CAS cleanly and the probe retries) — no hazard
  pointers or thread-progress machinery needed, the type-stable table is what Erlang
  lacks. Leak-exactness oracles: `Blob.live_count` baselines in every Zap test +
  `BlobDomain.deinit`'s zero-live assert at `zap_proc_runtime_deinit`. Proofs: kernel
  cross-thread retain/release/registry stress TSan-clean Debug+ReleaseFast; abi-level
  sender-dies-receiver-survives (same payload address across the sender's death, count
  exactly 1 after its ledger drain), queued-blob teardown reclaim, dead-letter undo,
  registry-survives-publisher-death; Zap-level `test_concurrency/blob_test.zap` (15
  tests: create/read/slice-independence, zero-copy identity witness across the boundary,
  cross-model Arena share, send_move relinquish, dead-letter, sender-dies, registry
  put/get/replace + 4 concurrent readers racing 25 replacing puts on the M:N pool, and a
  200-blob send storm returning the domain to baseline; gate-ON suite 144/0, 361
  assertions). Blob is gate-ON-only by design (it exists to be shared across processes;
  gate-OFF binaries carry zero blob code — `BlobRuntime` is unreferenced and elided).
  Blob correlated replies (`Task`) and blob-inside-containers are documented v1
  exclusions (collected under item 6.2a); 6.3's String work builds on the
  header-recoverable payload layout (`BlobHeader.fromPayloadPointer`).
  **Follow-on — FIXED (zap 9a36e6f, fork 6ba5c3e632): the `Option(<user
  struct>)` gate-ON miscompile/ICE discovered and bisected by P6-J2.** Three stacked
  root causes, none specific to the concurrency gate (the gate only changed which
  module set exposed them):
  1. **Wrong code (Zap `src/ir.zig`):** a parametric-union specialization's synthetic
     Zig module (Step 3.6, e.g. `Option_Marker.zig`) rendered a user-struct payload as
     a BARE identifier (`Some: Marker,`) with no import — unresolvable in the file-IS-
     struct module layout, so the file fails AstGen ("use of undeclared identifier").
     Nominal payloads are now rendered as `@import` expressions
     (`zigTypeToImportableStr`: struct `@import("Marker")`, union/enum
     `@import("Color").Color`, dotted `@import("Owner").Leaf`), which resolve in any
     synthetic module via the fork's bidirectional module-dep wiring. Also applied to
     concrete-union payloads and the union-dispatch `_Union` synthesis.
  2. **Error swallowing → the cold ICE (fork `src/zir_builder.zig`):** Zap-injected ZIR
     published an EMPTY `Zir.ExtraIndex.imports` table, so `computeAliveFiles` never
     crawled past the injected roots — the failed synthetic file was never "alive",
     its AstGen error was dropped from reporting, `anyErrors()` stayed false, and
     flush proceeded to LLVM emission where the failed decl's unpopulated `lowerNavRef`
     placeholder global panicked `Builder.toBitcode getConstantIndex` (".?" on a
     null `getIndex`). The fork's ZIR builder now scans emitted `.import` instructions
     at `finalize()` and publishes the deduplicated imports table, restoring the
     upstream invariant: reachable-file AstGen failures gate analysis
     (`skip_analysis_this_update`) and surface as ordinary compile errors.
  3. **Warm spurious gate-OFF (fork `src/zir_api.zig`):** every compilation context
     wrote its struct sources to ONE shared path
     (`.zap-cache/zap_structs/<name>.zig`) — a sibling gate-OFF target (e.g. `zap run
     doc`, the gate-OFF `test` target) clobbers the gate-ON daemon's rewritten
     `zap_runtime.zig` (`RUNTIME_CONCURRENCY_DEFAULT` flips to false on disk;
     demonstrated live), and the persistent daemon re-AstGens the foreign content at
     its next update — the whole suite then fails with 86× "Process operations
     require the concurrency runtime". Struct sources now live under a per-context
     scope directory (`zap_structs/<scope>/<name>.zig`), preserving in-place update
     semantics within one context while making cross-context clobbering impossible.
  Regression tests: `test_concurrency/option_struct_test.zap` (Option(user-struct)
  construction, Some round-trip, predicates — gate-ON), IR unit tests
  (`zigTypeToImportableStr`, importable-payload rendering), fork unit tests (imports
  table population + dedup, per-context struct-source scoping). Consequence resolved:
  `Blob.fetch_global/1 -> Option(Blob)` now ships alongside the Elixir-canonical
  `Blob.get_global(key, default)` (which stays the primary), with a gate-ON
  leak-exact registry test.
- **6.2a (DEFERRED — the Blob/String v1-exclusion cluster; one numbered owner, P6-R1).**
  Collects every documented v1 exclusion of the share tier so none of them lives only in
  prose: (i) **nested blobs** — blob handles inside `List`/`Map`/struct payloads
  (`isWalkerSendable`/`typeIsWalkerSendable` reject the shape; N10-locked). Unlocking them
  needs the serialized-payload CLEANUP WALKER mirroring the measure/write grammar, so an
  interior flight reference can be released on dead-letter/teardown-drain instead of
  leaking. (ii) **Blob correlated replies** — `call`/`Task` replies ride
  `zap_proc_send_correlated`, which is bytes-only (no moved-envelope/flight-reclaim hook on
  the correlated transport). (iii) **the 6.3 mirrored String exclusions** — strings nested
  in containers keep the walker byte-copy, and correlated string replies keep the walker
  copy; both are the SAME two mechanisms as (i)/(ii) applied to the string tier. All are
  deliberate v1 scope decisions, not defects; landing (i)'s cleanup walker plus a
  moved-capable correlated transport clears the whole cluster for Blob and String at once.
- **6.3** Blob-backed String per rev 2 §5.4: copy-out slices, SSO, 64 B promotion (tuned by
  measurement), rc==1 in-place append via the uniqueness prover, opt-in aliasing view.
  **DONE at the send-path scope (P6-J3, 2026-07-10, `8b34f70`)** — large strings ride the P6-J2 share
  tier; the String VALUE representation (`[]const u8`) is untouched, which is the honest
  scope decision (see the 6.3a deferral). Mechanism (`blob.zig` + the `zap_blob_string_*`
  ABI in `abi.zig`) vs policy (`src/runtime.zig`, the threshold + send/receive/concat
  integration):
  - **Recognition by layout, not by type.** A Zap `String` has no room for a handle, so a
    blob-backed string is recognized from its POINTER: every blob payload sits at exactly
    `header_byte_length` (24) bytes past a page boundary, so `resolveWholePayloadView`
    rejects any other page offset without touching memory, reads the same-page preceding
    `BlobHeader` otherwise, and accepts only when the header's handle round-trips through
    the slot table back to that exact payload address — a false positive is structurally
    impossible, a garbage probe can never fault, and the formal-race surface (probing a
    candidate that names a live FOREIGN slot mid-churn) is closed by making the two probed
    slot words (`header_address`, `byte_length`) atomic loads/stores (cold paths; TSan-clean
    by construction, verified under `-fsanitize-thread`).
  - **Copy-out slices, airtight cross-process.** Only the WHOLE-payload view
    (`length == byte_length`) ever resolves — a prefix/interior slice re-copies at every
    process boundary (sub-threshold → walker bytes; ≥ threshold → a fresh blob), so a small
    view can never pin a large payload in another process: the Erlang sub-binary /
    JDK-4513622 / SE-0163 pin pathology is defeated by construction. WITHIN a process,
    `String.slice` remains the aliasing view it always was — harmless because a blob-backed
    string's blob is ledger-pinned for the process's life (exactly the process-lifetime
    backing arena strings already have), so a local slice adds ZERO pinning.
  - **Send-boundary promotion, measured threshold.** A top-level `Process.send` of a string
    ≥ `string_blob_promotion_threshold` (65536 — measured, NOT Erlang's 64-byte instinct,
    which assumes a fitted binary allocator; the blob domain is mmap-backed at ~1.5 µs a
    create) promotes with ONE copy (`zap_blob_string_create_flight`; the single reference
    IS the flight reference) or, when already blob-backed, shares with ZERO copies
    (`zap_blob_string_flight_retain`); the envelope carries the payload pointer + STRING
    length and the P6-J2 `blobFlightReclaim` hook, so dead-letter undo and teardown drain
    are leak-exact for free. The receiver's string IS the payload view (`zap_blob_adopt`
    into its ledger — the same process-lifetime discipline P3-J4 gave adopted walker
    strings). Crossover measured substrate-honestly (the gate-ON walker's receiver copy is
    itself page-backed above the P3-J5 slab boundary): between 32 KiB and 64 KiB one-shot;
    a re-send/forward of a backed string is ~42 ns FLAT (165× at 64 KiB, ~2,400× at 1 MB).
    Ledger § "P6-J3 string-blob crossover" (harness
    `bench/concurrency-copy/run-string-blob-bench.sh`, kept for retuning).
  - **rc==1 in-place append** (`zap_blob_string_concat` behind `String.concat`): when the
    blob's atomic count is EXACTLY 1 and the caller owns that reference (ledger-gated), no
    other holder exists anywhere — no process, envelope, or registry entry — so appending
    at the frontier (only at `byte_length`; a stale shorter view is refused so it can never
    clobber a longer same-process alias) mutates nothing any other holder can observe:
    immutability is OBSERVATIONALLY absolute for every holder that is not the sole owner,
    and later shares are ordered behind the append by the flight-retain CAS edge. Once
    shared, the payload is frozen forever from the appender's side — the append copies into
    a geometrically-grown fresh blob (capacity ≥ 2×, page-slack included; the base blob's
    ledger reference is deliberately KEPT so same-process aliases stay readable, the
    bump-arena lifetime discipline). Every payload is page-rounded with the slack recorded
    as capacity, so promoted/received strings carry natural append room.
  - **Local-only strings untouched.** No construction-time promotion: concat's blob leg
    engages only for an already-backed base (two inline pre-filters — length ≥ threshold
    and the page-offset mask — answer ~every call without a C-ABI crossing); arena concat,
    interpolation, and every `String.*` builder are byte-for-byte pre-P6-J3, gate-ON and
    gate-OFF (the gate-OFF binary contains none of this — comptime-elided; CLBG unaffected).
  - **v1 exclusions** (mirroring Blob's — collected under item 6.2a): strings nested in
    `List`/`Map`/struct payloads keep the walker byte-copy (interior flight references
    would leak through dead-letter/teardown — same follow-on as blob-in-containers);
    correlated `call`/`Task` replies keep the walker copy (`zap_proc_send_correlated` is
    bytes-only — same exclusion as Blob correlated replies).
  - **Proofs:** kernel `blob.zig` (7 new tests: page-offset/capacity invariants,
    `createFromParts`, frontier/shared/capacity append rules, whole-view-only + stale-header
    probe rejection, and a 6-thread append-chain + adversarial fake-header probe stress —
    TSan-clean); abi-level string-tier lifecycle tests (promote/adopt, in-place vs
    freeze-on-share append, ownership/decline gates, promoted-send
    sender-dies-receiver-survives at the SAME address with a receiver in-place append);
    Zap-level `test_concurrency/string_blob_test.zap` (12 tests: threshold gating,
    local-only untouched, promote-exactly-one-blob + zero-copy adopt identity, zero-copy
    forward (ARC→ARC and ARC→Arena→ARC cross-model), sender-dies, small-slice pin
    avoidance + large-slice copy-out, rc==1 in-place vs copy-on-shared vs 40-append
    growth chains, 50-send storm leak-exactness — all `Blob.live_count`-baselined);
    `String.identity` (diagnostic, `lib/string.zap`) is the Zap-level pointer-identity
    witness.
  - **6.3a (DEFERRED — full String representation: SSO + owned string cells).** The ~15-byte
    SSO and any refcounted/handle-carrying String value require replacing `[]const u8` as
    the runtime String representation across the compiler (ZIR string ABI), every runtime
    string function, and FFI — a representation overhaul, not a send-path feature. Deferred
    with the §5.4 design intact (SSO inline capacity to be tuned to the final struct size);
    the send-path tier above neither blocks nor prejudges it.
  - **6.3b (DEFERRED — explicit opt-in aliasing view, `String.share`/`Blob.view`).** A
    zero-copy `Blob→String` aliasing view is the §5.4 resolution-4 capability (the
    `bytes::Bytes` trade), but with strings as bare slices the view would dangle after an
    explicit `Blob.release` — Zap has no borrow tracking to make "documented as pinning"
    enforceable, so it does not fit v1 cleanly. Ships with 6.3a's owned representation
    (the view can then hold a counted reference), documented as pinning.
- **6.4** Arena auto-reset at the receive back-edge for solver-proven loop-closed processes;
  `hibernate` intrinsic (arena reset + stack shrink).
  **DONE (P6-J4, 2026-07-10, `30ac6a8`)** — research.md §6.5's "single most promising Zap-specific
  optimization" landed end to end; the §2.4 arena-server growth warning is CLOSED.
  - **The mechanism (manager ABI, additive per spec §2.3/§7.2):** two new DESCRIPTOR-ONLY
    capabilities on the `CYCL` pattern (spec §8.8; `declared_caps` untouched — the reserved
    §7.1 bits stay clear): `ARSR` (`ZapArenaResetCapabilityV1`: `watermark` +
    `reset_to_watermark` — O(chunks-since) bulk free back to a captured position; the
    geometric growth schedule is deliberately kept, policy not position) and `STAT`
    (`ZapStatsCapabilityV1.heap_byte_count` — atomic reserved-bytes accounting, closing the
    P1-J5 `heapByteCount == 0` gap). `Memory.Arena` implements both; the kernel's
    per-process binding probes both tags once per spawn (`createProcessBinding`) and routes
    `ManagerVTable.iterationHeapReset`/`heapByteCount` through them. Per-model semantics:
    Arena captures the iteration watermark at the process's FIRST proven receive and
    bulk-frees back to it at every later one; ARC/ORC no-op (drops already reclaimed each
    iteration deterministically); Tracking frees at last use; Leak/NoOp never reclaim by
    design. Zap surface: `Process.heap_bytes()` (self-inspection, BEAM
    `process_info(self(), :memory)` analogue).
  - **The soundness proof gate (`src/receive_reset.zig`, run after drop materialization +
    both verifiers):** the compiler emits `ProcessRuntime.receive_iteration_reset`
    immediately before a receive primitive ONLY at sites passing the conservative
    iteration-closure proof — (1) the containing function is a RESET CONTEXT (whole-program
    monotone fixpoint over the reference graph: sanctioned spawn-entry `make_closure`
    references reached through alias chains ending at a spawn primitive's entry argument,
    self tail-call back-edges, and calls from established reset contexts at heap-clean call
    sites; dispatch-table/`__try`/escaping-closure references disqualify; name-based
    references match under a SUPERSET predicate so a reference can be over-attributed but
    never missed), (2) shape-eligible (non-closure, capture-free, scalar params, forward-only
    control flow), and (3) NO heap-possible local's [first-def, last-use] linearized interval
    strictly contains the receive (def-site classification: constants/arithmetic/checks/
    static string literals safe, alias moves propagate, calls safe only on provably-scalar
    returns, everything unknown heap-possible and — with no attributable def — live from
    entry). Where any condition fails the site is left alone (no reset — a wrong reset is a
    use-after-free; conservative always). The decision is PER RECEIVE SITE, never per
    process. WHAT IT REJECTS TODAY (the numbered deferrals): (i) the plain
    `Process.spawn(&f/0)` library-function path (entry closure escapes into a call argument;
    the managed `spawn(f, Memory.X)` macro path — the one that matters for Arena — is
    covered), (ii) name-resolution precision (dispatch groups, `__try` variants, mutual
    recursion between loop functions), (iii) accumulating-state precision (a loop retaining
    state is rejected wholesale; a region-solver split of per-iteration vs retained regions
    over the back-edge could reset the per-iteration region only).
  - **`hibernate`:** `Process.hibernate()` → `zap_proc_hibernate` →
    `ProcessContext.hibernate` (the deadline-less sibling of `receiveWaitTimeout`'s
    non-consuming `.user_any` park; signals never satisfy it) with the new `.hibernating`
    yield reason, whose dispatch releases the fiber's committed stack pages below the saved
    SP (`stack_pool.decommitBelowStackPointer`; one cushion page below the SP page preserved
    for the red zone) STRICTLY BEFORE `commitPark` publishes the park — after the publish a
    reviver may run the fiber concurrently. Pages recommit by fault on wake. Arena heap is
    NOT bulk-reset at hibernate (unlike BEAM's M:F(A) restart, Zap's hibernate RETURNS — live
    locals must survive; no proof covers an arbitrary call site): an Arena server that
    hibernates between messages composes the proven receive-site reset with the stack shrink,
    which together are BEAM hibernation. ARC empty-slab-cache release-to-OS at hibernate is
    deferral (iv). Observability: `hibernate_park_total` + `hibernate_stack_bytes_released`
    per scheduler, aggregated by the pool and `introspection.kernelCounters`.
  - **The A.4.3 decision (stack RSS decay), recorded:** hibernate DOES decommit (Darwin
    `MADV_FREE_REUSABLE` with `MADV_FREE` fallback — plain `MADV_FREE`'s reclaim is
    pressure-lazy and invisible in `phys_footprint`; `FREE_REUSABLE` drops the ledger
    immediately and a re-dirtying fault takes the page back out of the reusable set, the
    bmalloc/jemalloc purge protocol, with the `FREE_REUSE` re-accounting pairing consciously
    omitted since a fault-recommitted dead-stack page may harmlessly under-report; Linux
    `MADV_DONTNEED` — immediate, deterministic zero-fill recommit; other targets no-op,
    Windows `VirtualFree(MEM_DECOMMIT)` is deferral (v)). Pool release-to-cache does NOT
    decommit — the acquire/release fast path stays syscall-free (the E9 9 ns floor) and
    spawn/die storms reuse pages immediately; idle-cache decay rides hibernate (per-process,
    demand-signaled). Measured (kernel test, 32 MiB touched stack): decommit drops
    `phys_footprint` by ≥ released/2 with the real delta ≈ the full range.
  - **Proofs:** arena unit tests (watermark/reset/steady-state accounting, descriptor
    discovery); `receive_reset.zig` unit fixtures (proven flat loop instruments BEFORE the
    receive; heap-live-across rejects; heap param rejects; no-spawn-ref rejects; unknown
    caller rejects; entry→loop chain proves; per-SITE split in one function; share_value
    alias chain sanctioned; escaping closure rejected; no-receive program untouched);
    kernel abi tests (ARSR/STAT discovery + watermark semantics through the binding,
    no-capability no-op, hibernate park/shrink/wake + deep-stack recommit integrity +
    teardown-while-hibernated); stack-pool decommit geometry/integrity + Darwin
    footprint measurement; gate-ON Zap suite `test_concurrency/arena_server_test.zap`
    (the HEADLINE: a flat `Memory.Arena` server holds Process.heap_bytes EXACTLY equal
    across a 10,000-message storm; the accumulating server's retained 1,000-element state
    survives intact — the gate held; the mixed process proves per-site decisions) and
    `test_concurrency/hibernate_test.zap` (wake semantics, 50-round hibernate loop,
    deep-stack recommit checksum, pre-queued immediate return, 16-hibernator M:N fleet).
  - **Numbers (2026-07-10, aarch64-macos):** WITHOUT the reset the headline flat Arena
    server's reserved bytes grew 196,608 → 16,711,680 across the 10,000-message storm
    (85×, linear — the §2.4 pathology reproduced live); WITH it the two samples are
    EXACTLY EQUAL (the watermark reset restores the chunk set every iteration — the
    test asserts equality, not a fuzzy bound). Hibernate stack shrink: the kernel
    measurement over a 32 MiB fully-touched stack shows `phys_footprint` dropping by
    ≥ released/2 immediately (`MADV_FREE_REUSABLE`'s ledger removal), with the abi-level
    round trip recommitting a 64-frame excursion to an identical checksum after wake.
    Gates: gate-ON `:test_concurrency` **168/0 (434 assertions)** from a clean build
    (the +8 over P6-J3's 160 are this item's 3 arena-server + 5 hibernate tests);
    `zig build test` 0; `zig build test-kernel` 0 under the fork compiler (Debug 244/3
    skip + ReleaseFast 247, per-binary suites); kernel TSan-clean `halt_on_error=1`
    Debug 242/0 + ReleaseFast 239/0; gate-OFF **byte-identity**: a script-mode gate-OFF
    binary's `__TEXT,__text` SHA-256 (`c0bec391…4e1426`) is IDENTICAL under the HEAD
    compiler and the P6-J4 compiler, and carries zero
    `zap_proc_*`/`receive_iteration`/`hibernate` symbols (the E2 durable proof; the
    only deliberate gate-OFF byte change is confined to `Memory.Arena`-manifest
    binaries, whose manager gained the STAT counter on its cold chunk-refill path).
  - **6.4a (fork-hygiene follow-on) — the manifest incremental-daemon spurious relink.**
    Observed during P6-J4 validation (pre-existing, not that item's): the manifest
    incremental DAEMON intermittently fails an incremental relink with a spurious
    `duplicate symbol _zap_runtime_atomic_add_u32_acq_rel` (kernel object vs zcu
    object) even though `nm` shows the on-disk kernel object contains no such global —
    stale incremental link state in the fork's zir_api, the P6-J2 daemon-state bug
    class. Fresh (non-incremental) builds are deterministic and green; the numbered
    work is root-causing the fork's incremental linker state.
- **6.5** Full observability: send/receive trace points (compile-time-optional), scheduler
  utilization, run-queue depth, deadlock ("all waiting, none runnable") and starvation
  detection.
  - **DONE (P6-J6, 2026-07-10, `ed51b26`).** Ledger § "P6-J6 — full observability" has the method +
    measurements. (1) **Trace points**: spawn/exit/send/receive/signal-delivery events into a
    bounded lock-free in-memory ring (4096 newest; the honest v1 sink — readable from Zap, no
    callback re-entrancy on hot paths), comptime-gated behind a NEW `runtime_tracing`
    manifest field / `-Druntime-tracing=on` following the P2-J1 marker-rewrite pattern
    applied to the kernel unit (`trace.zig`'s `RUNTIME_TRACE_DEFAULT`, rewritten in a STAGED
    copy by `concurrency_driver.zig` — the tree is never touched; the flag joins the kernel
    object's content-address key). OFF ⇒ zero trace instructions and zero ring storage
    (verified: no `trace.global_ring_storage` symbol; gate-OFF binaries byte-identical
    pre/post job); ON ⇒ ~40–58 ns per ping-pong RTT (4 events) ≈ 10–15 ns/event, measured.
    (2) **Scheduler utilization**: per-core busy/parked wall-time split from monotonic
    timestamps at the park/unpark boundaries (spin counts busy — the BEAM "active" notion);
    thread-safe atomic snapshot composition. (3) **Run-queue depth**: per-core (locked FIFO +
    atomic LIFO slot) + global-queue depth, coherent thread-safe reads. (4) **Deadlock
    detection**: the pool's last-idle-core consistent scan (idle-exit-epoch bracket +
    steal-sweep seqlock + per-core atomic wake/reattach/timer reads + blocking-pool
    queued/in-flight under its lock) — provably no false positives under M:N; pending
    `receive … after` timers and in-flight blocking work correctly suppress it; the
    standalone scheduler's single-threaded predicate is exact. v1 action: report once
    (hook or stderr diagnostic naming every waiting process with mailbox depth/heap
    bytes/suspend pc) then CONTINUE parked by default (BEAM-compatible-plus-diagnostic);
    `ZAP_DEADLOCK_ACTION=stop|panic` opts into fail-fast (sound: a detected deadlock is
    permanent — no external wake source exists). (5) **Starvation detection**: head-tenure
    watermark on the pick path (consecutive passed-over picks at a core's FIFO head) —
    structurally silent under production FIFO + the 61-tick runnext fairness (verified by
    a threshold=1 test), fires with a naming diagnostic under a synthetic never-pick-the-head
    `Decisions` policy. (6) **Zap surface**: `lib/runtime_info.zap` (`RuntimeInfo`) —
    process listing (pids/states/mailbox depths/heap bytes), per-core utilization +
    queue depths, and the trace-ring read API; total in both trace modes.
- **6.6** Gate-ON tight-loop safepoint mitigation (E2 follow-up; owner for the deferred
  mitigation flagged in item 2.5 and `docs/concurrency-bench-results.md` § E2). Amortize the
  cooperative safepoint poll on the tight non-FP loops that regressed gate-ON — fannkuch-redux
  `reverse_range`/`count_flips` (+10–11%) and mandelbrot `iter`/`row_loop` (+3%). Two
  Go-precedented levers: (a) loop-unroll to amortize the 2-instruction register poll over K
  iterations; (b) force loopification of `musttail` self-recursion gate-ON so mandelbrot's poll
  becomes register-local instead of riding the global reduction counter's per-iteration
  load/store. NOT a kill-criterion item (E2 already passed with the poll on every loop) — this
  is a perf-tier refinement that gives the deferred mitigation an explicit owner.
  - **DONE (P6-J5, 2026-07-10, `6d1bd1e`).** Both levers landed; ledger § E2 "P6-J5 mitigation" has the
    full method + table. Honest re-baseline first: P4-J1's threadlocal counters had silently
    inflated the gate-ON regressions past the figures above (mandelbrot +34%, fannkuch ~+23%
    at HEAD-`30ac6a8` — every budget access became a Darwin TLV-getter call). Lever (b):
    gate-ON, TCO-safe self-recursion WITH params is force-loopified through the existing
    loopify machinery (zero-param/closure/entry recursion keeps musttail+`procReductionTick`)
    → mandelbrot **+34% → +0.2% (noise)**. Lever (a): tight (IR weight ≤ 48), non-FP,
    iterating-path-alloc-free, leaf-callee-only loopified bodies are K = 8-unrolled with ONE
    seedless `procReductionTickAmortized(8)` at the back-edge (the per-entry TLV seed
    dominated short-span loops; sub-K entries pay zero) → fannkuch **~+23% → +7.1%**.
    Kill-criterion pair untouched (nbody −2.1%, spectral-norm −2.0%);
    binarytrees/k-nucleotide unchanged (their +20%/+6% gate-ON penalties are the
    PRE-EXISTING P4-J1 layer-1 TLV cost — item **6.6a**, the
    register/parameter-threading ceiling). Two measured dead ends documented and kept off
    (unrolling weight-96 multi-call bodies: +55%; unrolling loops calling looping/heavy
    callees: k-nucleotide +6% → +18%). Latency bound re-stated (K-granularity addendum,
    `scheduler.zig` module doc): budget exhaustion observable ≤ K−1 tight iterations late —
    tens of ns vs the 1 ms watchdog tick; the amortized form's preemption is proven
    deterministically by the new `safepoint_test.zap` ordering test. Zero-cost-OFF re-proven:
    all six gate-OFF CLBG `__TEXT,__text` sections byte-identical pre/post-P6-J5. Gates:
    gate-ON `:test_concurrency` 171/0 (451 assertions), `zig build test` 0, `zig build
    test-kernel` (Debug + ReleaseFast, fork compiler) 0.
- **6.6a (DEFERRED — gate-ON reduction-budget register/parameter threading, the TLV
  elimination).** The numbered owner for the pre-existing P4-J1 layer-1 cost 6.6's levers
  deliberately left unchanged. P4-J1's M:N-correct THREADLOCAL budget counters turned
  every layer-1 alloc-piggyback tick (and every per-entry loop seed) into a Darwin
  TLV-getter CALL; the measured residue at P6-J5 close is **binarytrees +19.6%** and
  **k-nucleotide +5.8%** gate-ON (ledger § E2 "P6-J5 mitigation" — the before/after table
  marks both "pre-existing, unchanged"; entry evidence for this item). The fix direction
  is the ceiling A.4 OQ1 already measured against: thread the reduction budget through a
  register/parameter across the emitted-code hot path instead of re-reading TLS — the
  same published-vs-register/parameter analysis that resolved the current-process pointer
  (OQ1: the published-per-quantum global costs +2.2% pure / +0.7% mix OVER that ceiling;
  ledger § OQ1 is the design input), extended from the manager context to the budget
  counters, riding the compiler frame-threading the J2 monomorphization arm (item 3.2)
  already owns. Exit: binarytrees/k-nucleotide gate-ON penalties re-measured at or under
  the E2 band without regressing the kill-criterion pair.

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
- **7.5** Signal-delivery OOM posture (the P5-R1 D1 hook). `pushSignalMessage`
  DROPS a signal when the payload/envelope allocation fails ("best-effort under
  memory pressure"), while the runtime's general OOM posture is panic — and a
  dropped `{'EXIT', …}` is not merely lossy telemetry: a supervisor's
  `reap_exit`/`await_signal` then waits FOREVER for an exit that was never
  enqueued (the same hang class S1 fixed for discarded strays, resurrected by
  OOM), and `demonitorFlush`'s in-flight-`DOWN` wait is likewise unbounded.
  Resolve toward CONSISTENCY: panic on signal-delivery OOM (matching the
  allocator posture everywhere else — a kernel that cannot deliver exit signals
  has lost supervision soundness), or, if best-effort survives, every unbounded
  signal wait needs an OOM-aware bound. Preference recorded: panic-on-OOM.
- **7.6** Deadlock-bracket re-adjudication for any NEW wake source (the P6-J6
  closed-world hook). The deadlock detector's no-false-positive proof
  (`scheduler_pool.zig` `maybeDetectDeadlock`) stands on a CLOSED producer
  inventory — work is created only by scheduler cores and blocking-pool
  workers, and every producer's publish is ordered before an idle-visible
  transition the consistent scan reads. Landing ANY new producer — the I/O
  poller thread (kqueue `EVFILT_USER` / the A.4.2 Linux primitive), a
  foreign-thread (FFI) send entry point, an OS signal handler that enqueues —
  MUST re-adjudicate that bracket before it ships: either order the new
  source's publishes into the existing idle-count/epoch discipline, or add a
  "source idle" leg to the predicate (the blocking-pool treatment). The code
  carries the matching invariant note at the predicate.
- **7.7** Toolchain build-path sensitivity (the P6-J6 environmental footnote,
  ledger § P6-J6): a compiler built from IDENTICAL source at a DIFFERENT
  absolute path emits marginally different user-binary text (3 std-debug/io
  symbols flip in/out; the `__MergedGlobals` count shifts), isolated by a 2×2
  compiler×stdlib swap. Same-path builds are deterministic — every
  byte-identity gate compares same-path builds, so the campaign's proofs are
  unaffected — but path-independent reproducibility is the durable posture:
  root-cause the absolute-path leak into emitted text on the fork-hygiene
  track.

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
| E7 manager-call blocking | 4 | stalls beyond watchdog tick → mandatory handoff. **PASS (P4-J3, 2026-07-09)**: bounded manager calls (lazy-commit fault ~5 µs co-scheduled delay in ReleaseFast, ~200× under the 1 ms tick; ARC/ORC/Arena allocate has no collection pause) do NOT stall a co-scheduled fiber beyond the tick → NO auto-handoff for manager calls (that would be pure hot-path dispatch overhead, cf. E10). The ONE unbounded manager call — a `Memory.GC` stop-the-world collect — crosses the tick at ~1 MB of live heap (E8-confirmed ~1 µs/KiB scan) and is itself a `Process.blocking` client. Only explicit `Process.blocking` FFI (+ GC collect) uses the handoff. See ledger § E7. |

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
   refinement. The reduction-BUDGET counters are the sibling case of the same ceiling —
   item **6.6a** owns extending this analysis to them (the P4-J1 TLV cost).]*
2. **Linux poller wakeup primitive** — eventfd vs io_uring `MSG_RING` (E9 was Darwin-only);
   measured when the Phase 4 poller lands. *[Trigger lapsed — re-pointed (P6-R1): Phase 4
   landed multicore + the blocking pool WITHOUT an fd/I-O poller thread (no poller exists at
   Phase-6 close; file/network I/O runs through `Process.blocking`), so the measurement
   re-points to whenever the I/O poller lands. When it does, item 7.6's deadlock-bracket
   re-adjudication applies to the same thread — the poller is a new wake producer.]*
3. **Stack-pool sizing/watermark policy and its interaction with Darwin teardown** — decided
   empirically by Phase 1.7's spawn/die-cycle test. *[Update (Phase 1 close): 1.7 landed as the
   measuring instrument (the teardown-stress harness + soak knob); the sizing decision itself —
   including whether cached stacks get `madvise(MADV_FREE)`-style RSS decay — re-points to when
   real managers land (Phase 2 item 2.4 / Phase 3 items 3.x), measured with that harness. The
   Phase 1 constants remain the documented ARC-slab-mirror initial policy.]*
   *[RESOLVED (P6-J4, 2026-07-10): the RSS-decay half is DECIDED and recorded at item 6.4
   ("The A.4.3 decision (stack RSS decay), recorded") — hibernate DOES decommit (Darwin
   `MADV_FREE_REUSABLE` with `MADV_FREE` fallback; Linux `MADV_DONTNEED`); pool
   release-to-cache does NOT decommit (the acquire/release fast path stays syscall-free at
   the E9 9 ns floor); idle-cache decay rides hibernate, per-process and demand-signaled.
   The Phase-1 pool constants remain the sizing policy, now measured-good under the
   spawn/die and hibernate-fleet workloads.]*
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

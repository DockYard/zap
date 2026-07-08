# Zap Concurrency: Per-Spawn Memory Managers — Findings and Design Amendments

**Status:** design-position document, revision 2. Companion to `research.md` (the round-1
state-of-the-art survey) and `research-round-2.md` (round-2 evidence gathered against this
document's open questions). Revision 2 integrates the round-2 evidence: two open questions are
now **resolved** (receive forms §5.2, Blob/String §5.4), two of revision 1's positions are
**corrected** (per-process GC "already the correct shape" §2.5, safepoint piggyback sufficiency
§5.1), and the central position — manager-monomorphization for per-spawn managers — is
**adopted with a hybrid modification** (§2.3). The design anchor is unchanged: **a Zap process
is spawned with its own memory manager, chosen by the developer at the spawn site.**

## TL;DR

- **Manager-monomorphization is adopted, hybridized.** Specialize the spawn-reachable call
  graph per reclamation *model* (≤4) for hot/allocating paths — shipped precedent: Nim's
  per-`--mm` codegen, MMTk plan specialization, Verona per-region strategies. For cold
  closure/existential paths, fall back to dispatch through the process's manager vtable
  (already in the ABI and the control block) — the static-key/"resolve once at spawn" pattern —
  to cap the code-size explosion when `Callable` existentials inflate the spawn-reachable set.
  Linker ICF is the code-size backstop; the E4 kill criterion is stated **post-ICF**.
- **ORC-over-ARC becomes the recommended cyclic model**, with a Zap-specific advantage the
  round-2 evidence implies but does not state: because Zap's refcount ops are manager ABI entry
  points (not inlined like Nim's), the Bacon–Rajan cycle-root buffering can live entirely
  inside the manager's `release` implementation — so an ORC manager plausibly **shares the
  REFCOUNTED codegen specialization exactly**, costing zero additional monomorphized code,
  unlike TRACED. Conservative mark-sweep stays available as `Memory.GC` for FFI-heavy heaps,
  but revision 1's claim that it is "already the correct per-process shape" is withdrawn:
  conservative scanning of a *fiber's* stack (saved register context at the suspend point +
  private stack + guard pages) is unsolved work, and experiment E8 decides its fate.
- **Cross-model copies are the fallback of last resort, not the primary mechanism.** Verona —
  the closest shipped analogue to per-spawn models — never deep-copies across differently-
  managed regions; it moves whole regions O(1) and shares immutable data. Zap's priority order
  is therefore: same-model O(1) region move first, `Zap.Blob`/immutable payloads second,
  cross-model copy stubs last — generated lazily per *reachable* model pair, not all 16.
- **Safepoints are a three-layer design.** Alloc-path piggyback (primary, near-zero cost on
  allocating loops) **plus mandatory bare back-edge polls in allocation-free/call-free loops**
  (Go #10958 proves such loops starve — revision 1 undersold this) **plus a flag-only
  per-scheduler watchdog** (the cooperative analogue of Go 1.14's SIGURG, and wasm-compatible
  where signals are not).
- **Both remaining open questions are resolved**: receive ships as an exhaustive surface form
  over the inferred per-process message union with the ref-trick correlation skip hidden under
  `call`/`Future(T)` (every shipped statically-typed actor language made this exact choice);
  String ships Blob-backed with **copy-out slices** (the Java 7u6 / Swift SE-0163 convergence),
  ~15-byte small-string optimization, rc==1 in-place append, and an explicit opt-in aliasing
  view for networking.

## 1. Verified premises (checked 2026-07-03)

Everything `research.md` assumes about Zap's infrastructure was verified to exist:

| Claim in `research.md` | Verified against |
|---|---|
| Uniqueness/ownership prover | `src/arc_ownership.zig`, `src/perceus.zig` |
| `.borrowed` parameter convention (needed by the "no borrowed value reaches a send" verifier) | `src/arc_param_convention.zig` |
| Verifier-pass precedent for new concurrency passes | `src/arc_verifier.zig` |
| Region machinery for the move path | `src/region_solver.zig` (see §4) |
| Escape analysis for region closure | `src/escape_lattice.zig`, `src/generalized_escape.zig` |
| Context-based, multi-instance-capable manager ABI | `src/memory/abi.zig`, `docs/memory-manager-abi.md`, backends under `src/memory/{arc,arena,gc,no_op,tracking,leak}/` |
| `runtime_os` portability seam (deterministic-scheduler seam) | `src/runtime_os/`, `src/runtime_os_portability_gate.zig` |
| Zig fork green-thread substrate | `~/projects/zig/lib/std/Io.zig:31` (`Io.Evented`), `lib/std/Io/fiber.zig` |

## 2. The central decision: a process owns its manager, chosen at spawn

### 2.1 The standing decision

Recorded 2026-05-30 and reaffirmed here as the design anchor:

> Developers pick the memory manager per process when they `spawn` it — more flexible than stock
> BEAM (which uses one GC shape for all processes).

Two consequences were established with the decision:

1. **Cross-compile requirement.** Every manager backend must be present and linkable in every
   target binary, because any process might spawn with any of them. Managers cannot be
   compile-time-gated out of a target. Genuinely impossible manager×target combinations (e.g.
   `Memory.GC` on wasm32 — conservative stack scanning needs a native stack) become **runtime
   spawn errors**, not compile-time exclusions (see §5.5 for the capability-matrix mechanism).
2. **Tension with comptime elision.** The capability-driven memory model
   (`src/memory/abi.zig`, `src/memory/elision.zig`) bakes one reclamation model per binary at
   comptime and shapes memory-op codegen to match: ARC emits retain/release; Arena/NoOp/Leak
   elide all individual frees; Tracking uses static free-at-last-use. Per-process runtime manager
   choice breaks the "one model per binary" premise.

Round-2 evidence confirms the decision itself is well-precedented: **Verona** offers exactly
this choice one level finer (per *region*: arena / non-atomic refcounting / tracing GC, chosen
at region creation, each region thread-exclusive so "reference count manipulations do not need
atomic instructions, tracing GC does not need barriers" — the same rationale as Zap's
non-atomic per-process heaps). Erlang's `spawn_opt` heap options are the per-process
*parameter* precedent (`min_heap_size`, `max_heap_size`) though not a *model* choice.

### 2.2 Where `research.md` went wrong

Survey §6.6 ("Can different processes use different allocation strategies?") framed three options:

- **(a)** one reclamation model binary-wide, only allocation *strategy* (bump/arena/GPA
  parameters) varying per process — **its recommendation**;
- **(b)** compile the runtime multi-model and dispatch dynamically on every allocation —
  rejected, correctly, as a direct regression to Zap's few-instruction alloc path;
- **(c)** restrict per-process choice to parameters — the conservative fallback.

Option (a) contradicts the spawn-time decision outright. Option (b) is rightly dead for the hot
path — and Odin's `context.allocator` experience is the field report: pervasive allocator
dispatch not only costs, it *invites bugs* (Odin's own creator reports the generic interface
encouraged "a very very lazy habit of not actually passing around allocators properly", causing
more allocation bugs, not fewer). The survey never considered the option Zap's architecture
makes natural:

- **(d) Manager-monomorphization.** Specialize the spawn-reachable call graph per chosen
  reclamation model, exactly like the existing raising/pure and owned/borrowed per-call-path
  splits. Each specialization's memory-op codegen is gated by that manager's `declared_caps`
  (the existing `src/memory/elision.zig` decode — `reclamationModel` /
  `shouldEmitRefcountOps` — applied per specialization instead of once per binary). Comptime
  elision survives *per copy*; the cost is code size, not per-allocation dispatch.

**Decision: adopt (d), with the §2.3 hybrid.** Round-2 evidence supplies the shipped precedent
revision 1 lacked: **Nim** compiles different code per `--mm` mode ("`--mm:orc` also produces
more machine code than `--mm:arc`" — reclamation policy as a codegen axis whose price is code
size, validated in a production AOT compiler), and **MMTk** specializes barrier/alloc fast
paths per collector plan via conditional compilation. Zap generalizes Nim's per-binary choice
to per-spawn-subgraph, bounded by the number of models actually used.

### 2.3 The hybrid: monomorphize hot paths, vtable-dispatch cold ones

Revision 1 proposed all-or-nothing monomorphization. Round-2 evidence motivates a strict
improvement:

1. **The 4-model bound is only real for a static call graph.** Through indirect calls —
   `Callable` existentials (closure fat pointers), protocol dispatch — the spawn-reachable set
   inflates toward the whole program (the same wall Rust hits with `dyn Trait`). Closures
   captured across a spawn boundary may need model-specific vtable copies when hot.
2. **Hot allocating paths must be monomorphized — no dispatch of any kind.** Go's back-edge
   preemption data is the yardstick: a *single extra instruction, no branches, no register
   pressure* still produced a 7.8% geomean slowdown. The few-instruction alloc budget forbids
   even cheap dispatch on that path.
3. **Cold, rarely-allocating spawn-reachable functions may dispatch through the process's
   manager vtable.** Zap needs no literal ifunc/static-key machinery: the manager ABI already
   defines the vtable, and the green-thread control block already carries the manager
   context+vtable pointer (survey §6.6's design). "Resolve once at spawn, then indirect-call"
   is the Linux `static_call` pattern realized with infrastructure Zap already has. This caps
   the code-size blow-up from closures/existentials: hot closure bodies get model-specialized
   copies; cold ones fall through to the vtable.
4. **Linker ICF is the code-size backstop, and a verifier signal.** The model specializations
   are mostly identical, differing in header-emission ops — exactly what lld/gold ICF and LLVM
   `mergefunc` fold. Expected post-ICF growth ≈ (spawn-reachable text) × 1 + per-model
   header-emission deltas. **If ICF cannot fold two model specializations of the same function,
   they differ in more than header ops — surface that as a verifier red flag**, because it
   means model semantics leaked somewhere they shouldn't.
5. **Specialization is by reclamation *model*, not manager identity.** Four models (REFCOUNTED,
   BULK_OR_NEVER, INDIVIDUAL_NO_REFCOUNT, TRACED — `declared_caps` Axis A). Managers sharing a
   model (Arena/NoOp/Leak are all BULK_OR_NEVER) share code and differ only in the
   vtable/context handed to them. The compiler reads capability axes, never the manager's
   name — the ABI's own principle.
6. **The manager must be statically known at the spawn site** — a language rule, not a
   heuristic. `spawn(f, .{ .manager = Memory.Arena, ... })` with a comptime-resolvable manager
   binding selects the specialization the new process enters. This rule also defends against
   the Odin bug class (§2.2): the manager cannot be silently mis-propagated because it is not a
   threaded runtime value. A fully-runtime manager choice can be revisited later as an explicit
   opt-in with documented vtable-dispatch cost.
7. **Zero-cost guarantees hold.** A binary that only spawns ARC processes carries one
   specialization — identical to today. A binary with no spawns compiles exactly as today
   (Constraint 4 of `research.md`).
8. **Driver/runtime changes.** Today `src/memory/driver.zig` resolves **one** manifest-selected
   manager and registers it as the singleton `zap_active_manager` symbol set (see
   `src/zap_active_manager_stub.zig`). Per-spawn managers need: (i) the driver to resolve and
   validate *every* manager referenced by any spawn site plus the manifest default, (ii) a
   per-manager symbol family or registration table in the runtime, and (iii) each process's
   control block carrying its manager context+vtable, selected once at spawn.

### 2.4 Cross-model message traffic: move first, Blob second, copy last

Revision 1 identified that per-spawn managers make every cross-process send a potential
cross-*model* copy (ARC cells carry refcount headers; arena/tracking cells do not) and proposed
model-tagged pids + per-model-pair copy stubs. Round-2 evidence reorders the priorities:

**Verona — the closest analogue — sidesteps cross-model copying entirely.** It never
deep-copies object graphs between differently-managed regions; it moves whole regions in O(1)
by reassigning the single external bridge pointer (Reggio design goal G4, "Zero-Copy Ownership
Transfer") and pushes sharing onto immutable (frozen) data. It can do this because it forbids
interior cross-region pointers (references form a forest). Zap allows richer message shapes, so
Zap needs the copy path Verona lacks — but Verona's philosophy transfers: **make cross-model
deep copies rare rather than fast.**

Priority order for message payloads:

1. **Same-model O(1) region move** (§4) — the protobuf-arena precedent maps exactly: same-arena
   move is O(fields) "without making copies"; cross-arena is a deep copy. Same-model steal,
   cross-model copy.
2. **`Zap.Blob` / immutable payloads** — Blob's atomic refcount is model-independent, making it
   the one payload that never touches the stub matrix. Route bulk data (large strings — §5.4 —
   config tables, binaries) through Blob by default. A Verona-style *freeze* tier (deep
   immutability via one-refcount-per-SCC, ISMM 2024) is the v2 candidate for making arbitrary
   structured data cross-model-free, not just byte buffers.
3. **Cross-model copy stubs — last resort.** Generated **lazily, only for (sender-model ×
   receiver-model) pairs actually reachable in the program**, not all 16. The graph walk is
   shared; only per-cell header emission differs per pair. Written so a serializing backend can
   reuse the walker (distribution, survey §6.10).

**Adoption semantics per receiver model** (the part revision 1 left implicit, now explicit):

- **REFCOUNTED**: the sender stub initializes adopted cells with rc=1 — the receiver is sole
  owner post-adoption.
- **BULK_OR_NEVER**: adoption splices the fragment's pages into the bump/slab bulk set,
  reclaimed only at bulk reset or death. Consequence: a long-lived arena server accumulates
  adopted fragments until its reset point — the survey §6.5 compiler-proven arena auto-reset at
  the receive back-edge is *more* important under per-spawn arenas, not less.
- **TRACED**: adoption registers the fragment range with the per-process collector — Boehm-style
  root/heap-block distinction applies (page alignment; a range registered as roots-only is
  scanned but never collected; a range not registered at all is collected while live). In-flight
  fragments that are reachable but not yet adopted must be pinned/rooted for the duration of any
  collection.
- **INDIVIDUAL_NO_REFCOUNT**: adopted cells enter the static free-at-last-use discipline; the
  stub emits no headers and the tracking metadata treats adoption as the allocation event.

**Pid invariant (sharpened from revision 1):** pids are `{slot, generation}` with model bits and
reserved node bits. The invariant is **model bits are a function of {slot, generation} and are
immutable for the life of that generation**. Slot reuse by a different-model process bumps the
generation; a sender must read model bits and generation *together*, and the copy stub must
**dead-letter on generation mismatch** rather than emit cells in a stale layout. This subsumes
the stale-model-bit hazard entirely — precedent: BEAM creation tags, ECS generational handles
with type bits.

**Sender-dies-with-in-flight-message:** mimalloc's abandoned-segment reclamation is the shipped
mechanism for exactly this (a dead thread's pages are abandoned, later reclaimed by whoever
frees into them); Zap's shared page pool for in-flight envelopes should adopt the same
abandon/reclaim shape. mimalloc's macOS issue #164 (thread-locals destroyed before heap
teardown) is a concrete warning that **per-process heap teardown ordering on Darwin — our
tier-1 platform — is error-prone and needs a dedicated test** (spawn/kill thousands of
mixed-model processes under the tracking/leak manager; assert clean teardown).

**Cross-model `move` degrades to copy** — unchanged from revision 1. An O(1) re-parent is only
possible when the receiver's model can maintain the adopted slabs; the verifier and docs must
say so.

**Implementation status (P3-J4, landed).** The cross-model copy stubs + model-tagged pid
dispatch are implemented (`docs/memory-manager-abi.md` §10.6). The neutral-blob sender
serialize (P2-J5, `serializeMessage`) is model-agnostic and reused unchanged; the variance is
receiver-side: `deserializeMessage` reads the receiving process's model at runtime
(`ArcRuntime.currentReclamationModel`, decoding its manager core's `declared_caps`) and threads
it through the walk to pick the adoption discipline per receiver model (REFCOUNTED rc=1 cells;
BULK_OR_NEVER/TRACED wholesale-reclaimed cells with an error path that elides the per-cell free;
INDIVIDUAL_NO_REFCOUNT tracked cells). Every cell — and every adopted `String` — is allocated
into the RECEIVER's own private heap (the per-process routing of §10.5), so the copy is an
independent graph reclaimed by the receiver's model, and the sender's original is never touched
(the blob carries zero live refcounts — the scheduler-local-refcount invariant holds by
construction and is TSan-proven). The conceptual 16-cell (sender × receiver) matrix collapses to
the four receiver-model disciplines because the blob is neutral; only the models a binary spawns
are reachable. No ABI minor bump was needed — the receiver's existing `core.allocate` IS the
adoption primitive for the copy path (detach/adopt entry points are reserved for the future
same-model O(1) move). The pid `{model, generation}` invariant is enforced by `pid_table.lookup`
(validated as one atomic word, generation first), so a stale cross-model pid dead-letters.

### 2.5 The model roster: ORC-over-ARC in, mark-sweep demoted (revision-1 correction)

Revision 1 claimed the existing conservative mark-sweep collector
(`src/memory/gc/manager.zig`) is "already the correct per-process shape." Round-2 evidence
shows that is **half-true and the claim is withdrawn**:

- The *architecture* is right: per-instance collectors over private heaps, collecting only at
  the owner's yield points with no global stop-the-world, are well-precedented (Lua per-state,
  QuickJS per-runtime, V8/Wasmtime isolate-per-store).
- The *unsolved piece* is **conservative scanning of a fiber's stack**: the saved register
  context at the suspend point, the private (guard-paged, lazily-committed) stack, and pointer
  identification into a private heap. Boehm-with-green-threads is documented as fragile exactly
  here, and Go abandoned conservative scanning for precise stack maps partly for these hazards.
  Experiment E8 (scan cost per KB + false-retention rate on Darwin/aarch64 fibers) decides
  whether conservative mark-sweep ships as a v1 spawn option or slips.

**New recommendation: build ORC-over-ARC as the primary cyclic model.** Nim's ORC (Bacon–Rajan
trial-deletion atop ARC) is the shipped proof that "ARC + cycle collector" is the minimal delta
over what Zap already has (`src/perceus.zig`, ARC headers, drop insertion): it needs **no stack
scanning** (it works on the refcount graph), and preserves determinism far better than
mark-sweep. Zap has a structural advantage Nim lacks: Nim inlines refcount ops, so ORC changes
Nim's generated code ("produces more machine code than arc"). **Zap's refcount ops are manager
ABI entry points** (`retain`/`release`/`retain_sized`/`release_sized`, ABI v1.1), so the
cycle-root candidate buffering on a non-zero decrement can live *entirely inside the ORC
manager's `release` implementation*. If that holds, an ORC manager:

- presents as **REFCOUNTED on Axis A** (bit 0 set) — cycle collection is manager-internal, or at
  most a new capability *descriptor*, never a new Axis-A model;
- **shares the REFCOUNTED codegen specialization exactly** — zero additional monomorphized code,
  unlike TRACED, which needs its own specialization.

This is a design hypothesis, not a verified fact — it depends on the ARC optimizer's
elision/borrow inference not assuming anything about `release` internals that root-buffering
would violate. Verify as part of E8's decision (see §7).

Roster after this correction:

| Spawn option | Axis A model | Codegen specialization | Status |
|---|---|---|---|
| `Memory.ARC` (default) | REFCOUNTED | REFCOUNTED | v1 |
| ORC-over-ARC (cyclic) | REFCOUNTED | shared with ARC (hypothesis) | v1, recommended cyclic model |
| `Memory.Arena` / NoOp / Leak | BULK_OR_NEVER | BULK_OR_NEVER | v1 |
| `Memory.Tracking` | INDIVIDUAL_NO_REFCOUNT | INDIVIDUAL_NO_REFCOUNT | v1 (test/debug) |
| `Memory.GC` (conservative mark-sweep) | TRACED | TRACED | contingent on E8; kept for FFI-heavy/opaque heaps |

### 2.6 What this changes in the staged plan

Amendments to `research.md`'s Stage 1 (everything else in the plan stands):

- Stage 1 gains: manager-monomorphization of spawn-reachable call graphs (hot paths) + manager-
  vtable dispatch for cold existential paths; driver multi-manager resolution + runtime manager
  registry; model bits in the pid with the {slot, generation} invariant; lazily-generated copy
  stubs for reachable model pairs; spawn-time manager×target capability check (§5.5); the
  flag-only watchdog timer (§5.1); the abandon/reclaim pool for orphaned in-flight fragments.
- Stage 1 spawn options become `spawn(f, .{ .manager = ..., .initial_heap = ..., .max_heap =
  ... })` — the survey's Open Decision #4 answer extends from "strategy parameters" to "manager
  binding," with the manager comptime-resolved at the spawn site.
- Survey Open Decision #6 is re-answered (revised from revision 1): tracing GC is a valid
  per-process model, but ORC-over-ARC is the *recommended* cyclic model; conservative
  mark-sweep ships only if E8 passes, and is positioned for FFI-heavy/opaque heaps.
- Stage 2/3 gain: the freeze/immutable-share tier prototype (model-independent structured
  payloads beyond Blob); verona-rt-style seed-swept scheduler-interleaving testing folded into
  the deterministic-Zest plan.

## 3. The Zig fork substrate is further along than the survey says

Verified in `~/projects/zig` (our 0.16 fork):

- `lib/std/Io.zig:31` — `pub const Evented = if (fiber.supported) switch (builtin.os.tag) ...`
- `lib/std/Io/fiber.zig` — stackful-coroutine context switching with hand-written assembly for
  **aarch64, x86_64, riscv64** (`fiber.supported` is arch-gated; wasm is excluded — see §5.5).
- Backends present: `Dispatch.zig` (GCD — Darwin), `Kqueue.zig`, `Uring.zig`, `Threaded.zig`.
- The `Io` vtable already carries async/concurrent/await/cancel, `Group`
  (`groupWait`/`groupCancel`), `Queue`, and `netLookup`.

Consequences:

- **Darwin is tier-1 from Stage 0.** Development and the test suite run on Apple Silicon macOS;
  the substrate for it exists in-fork today. Two Darwin backends exist (Dispatch and Kqueue) —
  experiment E9 measures fiber-switch + wakeup latency on each to pick the default.
- **Do not vendor `zio`.** We own the fork and have standing permission to change it; the
  correct posture under the no-fallbacks rule is to **extend `Io.Evented` in the fork**
  (work-stealing M:N, wakeup integration, stack-reservation policy) using `zio` purely as a
  design reference. Gaps found during Stage 0 are fixed in `~/projects/zig`.

## 4. The Stage-3 move path is mostly already built — and Verona endorses it

`src/region_solver.zig` ("Region-Based Lifetime Solver, Research Plan Phase 4") already
implements: dominator-tree CFG construction, constraint generation from IR, non-lexical
lifetime solving via LCA, MLKit-inspired multiplicity inference, MLKit-inspired storage-mode
analysis, and region→allocation-strategy mapping.

- The survey's Stage-3 **region-closure verifier** (SE-0414 / Pony-`iso` style: no external
  in-pointers, no escaping out-pointers, refcount == 1) is a new *constraint* layered on this
  existing solver plus `src/escape_lattice.zig` / `src/generalized_escape.zig` and the
  uniqueness facts from `src/arc_ownership.zig` — not a from-scratch analysis.
- The survey's **arena auto-reset** for proven loop-closed server loops (§6.5) is essentially
  the solver's storage-mode/multiplicity analysis applied at the `receive` back-edge — and
  §2.4 makes it load-bearing for arena processes that adopt message fragments.
- **Verona validates the mechanism**: whole-region O(1) transfer by bridge-pointer reassignment
  is its design goal G4, and BoC's benchmark result (beating Pony on 17/22 Savina benchmarks,
  with profiling attributing Pony's overhead to tracing/remembered-sets on send) confirms that
  **tracing-on-send is the performance trap to avoid** — Zap's copy-into-detachable-fragment +
  adopt, and the O(1) move, are both on the cheap side of that line.
- Restriction from §2.4 stands: O(1) re-parenting is same-model only; cross-model `move`
  degrades to copy.

## 5. Resolved and revised positions

### 5.1 Safepoints: three layers (revision-1 correction)

Revision 1 proposed alloc-path piggyback with back-edge polls as a concession for alloc-free
loops. Round-2 evidence corrects the emphasis — **the piggyback is necessary but insufficient**,
and the design is three mandatory layers:

1. **Alloc-path piggyback (primary).** Every allocating loop already calls the manager; the
   preemption-budget decrement rides that call at near-zero cost. Precedent: BEAM reduction
   accounting counts allocations and calls; HotSpot checks at TLAB allocation.
2. **Bare back-edge polls in allocation-free, call-free loops — mandatory, not optional.**
   Go #10958 is the canonical evidence: a tight loop with no calls or allocation "arbitrarily
   delays preemption … arbitrarily long pause times." nbody's exact shape. HotSpot polls at
   back-edges *despite* allocation checks for precisely this reason. E2 measures the cost on
   nbody/spectral-norm with concurrency compiled on; Go's 7.8% geomean for back-edge checks is
   the number to beat, and loop unrolling to amortize the poll is the documented mitigation if
   E2 fails.
3. **Flag-only per-scheduler watchdog.** A timer that only *sets a flag*; the fiber checks the
   flag at its next poll. The cooperative-safe analogue of Go 1.14's SIGURG — without needing
   pointer maps, async-safe-point metadata, or signals (which are impossible on wasm anyway,
   per Go #36365).

**Advertised latency bound:** preemption latency ≤ max(one back-edge iteration of the longest
un-polled loop, watchdog tick). The one unbounded case — an un-splittable leaf numeric kernel
with no poll — is documented honestly, exactly as Go documents its equivalent.

**New hazard (E7):** a fiber can block *inside a manager call itself* — a GC pause inside
`allocate`, a page fault under lazy commit. Blockable manager calls must either be bounded or
hand off the scheduler thread (the dirty-scheduler/syscall-handoff pattern). E7 measures
whether co-scheduled fibers stall beyond the watchdog tick.

### 5.2 Receive: RESOLVED — exhaustive surface form + internal correlation skip

The round-2 evidence is one-directional: **no statically-typed actor language ships
Erlang-fidelity selective receive.** Akka Typed uses an explicit bounded `StashBuffer`; Gleam
replaces it with typed `Subject`s + `Selector` and deliberately keeps selective receive
non-first-class; Pony has no receive at all (behaviours are the union); Swift actors reply via
continuations; Ractor uses typed reply ports. Zap's resolution:

1. **Primary surface form: exhaustive steady-state `receive`** over the compiler-inferred
   per-process message union. A message outside the union is a **compile error at the send
   site**; a union member unhandled in a receive is a **non-exhaustive-match compile error**.
   Stricter and safer than Erlang's silent mailbox growth, and the Gleam experience ("your
   actors will almost never panic as a result of receiving a message") is the ergonomic
   validation.
2. **Internal correlation-token receive** — the Erlang ref-trick O(1) skip (`recv_mark`
   analogue) — used **only** by the `call`/`Future(T)` machinery, never surface syntax. Typed
   reply paths make user-visible selective receive unnecessary.
3. **Dead-letter, not defer, for genuinely unexpected runtime messages** (monitor-DOWN races,
   late replies after timeout): route to a dead-letter sink with telemetry rather than growing
   the mailbox. This kills the O(N²) mailbox-scan pathology by construction.
4. **North star, not v1:** mailbox types (de'Liguoro & Padovani ECOOP 2018; Fowler et al.'s
   Pat, ICFP 2023) — typing the mailbox as a commutative regular expression to catch protocol
   violations and self-deadlock statically — is the research-frontier treatment of Zap's
   message-union inference, worth tracking for the verifier's evolution.

### 5.3 Copy-path ABI work items

The detachable-fragment discipline requires, concretely:

- a third allocation domain (in-flight envelopes owned by neither manager, from a shared page
  pool) — runtime-owned, with **mimalloc-style abandon/reclaim** for the sender-dies case
  (§2.4);
- detach/adopt entry points on the manager ABI — an ABI **minor** bump per
  `docs/memory-manager-abi.md` §2.3, with adopt semantics defined per reclamation model as
  specified in §2.4;
- the lazily-generated per-reachable-pair copy stubs (§2.4), sharing one graph walker.

### 5.4 Blob/String: RESOLVED — copy-out slices, SSO, rc==1 append, opt-in aliasing

The industry converged on copy-out slices, with two canonical reversals as proof: **Java**
shared substring backing arrays until the pin pathology (JDK-4513622; a 20-char session id
pinning a 10 KB array; one cited deployment dropped ~60 GB → ~24 MB) forced the 7u6 change to
copy; **Swift's** `String`/`Substring` split (SE-0163) enforces copy-out at the type level and
cites the Java change as justification. Rust's `bytes::Bytes` shows the opposite trade
(O(1) aliasing slices, accepted pin pathology) is viable *as an opt-in for networking*, not as
the default. Erlang's refc-binary sub-binary pinning is the original cautionary tale. Zap's
resolution:

1. **Blob-backed large strings with copy-out slices.** Slicing produces a new string by copying
   out, never a sub-Blob alias — the pin pathology is defeated by construction.
2. **Small-string optimization ~15 bytes inline** (Swift's number; tune to Zap's String struct
   size). Heap→Blob promotion threshold starts at 64 bytes (Erlang's instinct), tuned by
   measurement.
3. **rc==1 in-place append**: when a Blob's refcount is 1, append mutates in place (Erlang
   writable-binary precedent); otherwise copy. Falls straight out of Zap's uniqueness/ARC
   machinery.
4. **Explicit opt-in aliasing view** (`String.share` / Blob view) for zero-copy networking,
   documented as pinning — the `Bytes` capability without making its trade-off the default.
5. **Blob is the cross-model-free payload** (§2.4): large strings sent between
   differently-managed processes never touch the copy-stub path. Route bulk data through Blob;
   this is also Verona's strategy (share immutable, move regions, never deep-copy).

### 5.5 Wasm and the capability matrix

One mechanism answers both manager×target and backend×target feasibility: a **comptime
capability table + runtime spawn-time capability error**. The common impossible combos
(conservative-scan GC on wasm32 — no native stack access; fibers on wasm — `fiber.supported`
excludes it because the wasm call stack is architecturally inaccessible) are **warned at
compile time** from the comptime matrix; only genuinely dynamic cases defer to the runtime
spawn error. This refines revision 1's "runtime spawn errors, not compile-time exclusions" —
the runtime error remains the enforcement point (the manager is a spawn parameter), but the
matrix gives early diagnostics.

Wasm posture for v1: **spawn → runtime capability error on wasm32 by default**, with an
optional Threaded-backend fallback (wasm threads + shared memory) where the host allows. **No
Asyncify** — its binary-size and speed tax is incompatible with Zap's CLBG performance culture.
Revisit when the stack-switching proposal ships in a major runtime (Wasmtime has a prototype;
no browser has shipped it; JSPI is suspension-only and not a fiber substrate). Go faces the
same wall (no async preemption on js/wasm, #36365) — deferring true fibers on wasm is
good company.

Darwin notes: fixed stack reservation + lazy commit behaves well (large virtual reservations
are cheap on 64-bit); the overcommit caveat applies to Linux-no-overcommit deployments —
document, don't design around. The mimalloc #164 teardown-ordering hazard (§2.4) is the Darwin
item that needs a dedicated test.

## 6. Decisions (updated)

1. **Manager statically known at `spawn`** — yes, as a language rule (comptime-resolved
   binding). Gates §2.3; defends against the Odin mis-propagation bug class.
2. **Specialization key** — reclamation model (≤4), not manager identity; **hybrid**: hot
   allocating paths monomorphized, cold closure/existential paths dispatch through the
   process's manager vtable. ICF as backstop; ICF-unfoldable specializations are a verifier
   red flag.
3. **Cross-model traffic priority** — same-model O(1) move ▸ Blob/immutable payloads ▸
   lazily-generated per-reachable-pair copy stubs. Cross-model `move` degrades to copy;
   verifier and docs say so.
4. **Pid invariant** — model bits are a function of {slot, generation}; stubs dead-letter on
   generation mismatch.
5. **Model roster** — ORC-over-ARC is the recommended cyclic model (hypothesis: shares the
   REFCOUNTED specialization because root-buffering lives inside the manager's `release`);
   conservative mark-sweep contingent on E8, positioned for FFI-heavy heaps.
6. **Safepoints** — three layers: alloc piggyback + mandatory bare back-edge polls in
   alloc-free/call-free loops + flag-only watchdog. Advertised bound documented, including the
   one unbounded case.
7. **Receive** — exhaustive surface form over the inferred union + internal correlation-token
   skip under `call`/`Future(T)`; dead-letter unexpected runtime messages.
8. **Blob/String** — copy-out slices, ~15-byte SSO, 64-byte promotion threshold (tunable),
   rc==1 in-place append, explicit opt-in aliasing view.
9. **Wasm/feasibility** — comptime capability matrix + runtime spawn error; optional Threaded
   fallback; no Asyncify.
10. **Fork posture** — extend `Io.Evented` in `~/projects/zig`; no vendored scheduler; E9 picks
    the default Darwin backend.
11. **Testing** — adopt verona-rt's seed-swept deterministic scheduler-interleaving harness
    (single seed reproduces; seed range sweeps) within the survey's deterministic-Zest plan.

## 7. Experiments

Baseline yardstick for E1 (order-of-magnitude, to be replaced by Zap's own harness):

| System | Spawn/task creation | Message RTT |
|---|---|---|
| Tokio task | ~10 ns | mpsc low-ns |
| Go goroutine | low hundreds of ns | channel low-µs |
| BEAM process | sub-µs | same-scheduler sub-µs |
| GCD `dispatch_async` | ~µs enqueue | — |

- **E1 — spawn + ping-pong on the fork's `Io.Evented`** (Dispatch/Kqueue, Apple Silicon).
  Targets revised per round 2: **sub-µs spawn for the ARC/default case** once heap pre-sizing
  is cheap; 1–3 µs acceptable only for GC/arena managers with heavier init; **report per
  manager** — spawn cost is now manager-dependent. Ping-pong: same-scheduler RTT within 2–3× of
  BEAM/Go for v1.
- **E2 — safepoint overhead on CLBG** with concurrency compiled on: alloc-piggyback variant
  (expect near-zero on allocating loops) and bare back-edge polls measured specifically on
  nbody/spectral-norm. Go's 7.8% is the number to beat; kill criterion >2–3% → loop unrolling
  to amortize the poll before shipping concurrency-on.
- **E3 — detachable-fragment copy under ThreadSanitizer**, adversarial send/receive, scoped to
  *reachable* model pairs, **plus** the mimalloc-style "sender dies with in-flight fragment"
  abandon/reclaim test, **plus** the Darwin teardown-ordering test (thousands of mixed-model
  spawn/kill cycles under tracking/leak managers).
- **E4 — monomorphization code size** at 1/2/4 models, on a program with spawn-reachable
  `Callable` existentials across ≥2 models. **Kill criterion is post-ICF text growth**,
  calibrated against Nim's arc→orc delta. Early kill signal: ICF cannot fold model
  specializations (they differ in more than header ops — verifier red flag).
- **E5 — region detach/adopt in the slab allocator**, same-model pairs; confirm O(1) and
  leak-free.
- **E6 — copy p99 vs message size** (64 B → 1 MB) per model pair; the crossover decides when to
  accelerate Blob and the move path.
- **E7 (new) — manager-call blocking**: force a GC pause / lazy-commit page fault inside
  `allocate`; assert co-scheduled fibers are not delayed beyond the watchdog tick; failure →
  mandate dirty-scheduler handoff for blockable manager calls.
- **E8 (new) — conservative fiber-stack scan** on Darwin/aarch64: scan a suspended fiber's saved
  register context + private stack; measure cost/KB and false-retention. This experiment
  decides whether mark-sweep ships in v1 — and its counterpart verifies the ORC hypothesis
  (cycle-root buffering entirely inside the manager's `release`, sharing the REFCOUNTED
  specialization). Kill signal for mark-sweep: unbounded scan cost or false retention keeping
  demonstrably-dead cyclic graphs alive → ship ORC-over-ARC only.
- **E9 (new) — Dispatch (GCD) vs raw Kqueue on Darwin**: fiber-switch + wakeup latency; picks
  the default tier-1 backend.
- **E10 (new) — vtable dispatch vs monomorphized alloc call**: measure the hot-path cost of the
  §2.3 hybrid's dispatch arm directly, confirming it stays confined to cold paths.

## 8. Risks (ranked; each with a falsifiable early test)

1. **Fiber-stack conservative scan harder than assumed (HIGH).** Revision 1 underestimated
   this; if it fails on Darwin/aarch64, mark-sweep slips out of v1. *Test: E8.*
2. **Closure/existential reachability inflates "spawn-reachable" toward the whole program
   (HIGH).** *Test: E4 with existential-heavy input; kill signal: ICF cannot fold.* Mitigation
   already designed: the §2.3 vtable-dispatch arm for cold paths.
3. **Alloc-piggyback alone leaves nbody-shaped loops unpreemptible (MEDIUM-HIGH; mitigation
   designed).** *Test: E2 — verify watchdog flag + back-edge poll bounds latency with no CLBG
   regression.*
4. **Copy stubs / adoption corrupt allocator invariants (MEDIUM)** — especially TRACED range
   registration and REFCOUNTED rc=1 init. *Test: E3.*
5. **Darwin per-process-heap teardown ordering (MEDIUM)** — mimalloc #164 precedent. *Test: E3's
   teardown component.*
6. **Manager-call blocking freezes a scheduler (MEDIUM).** *Test: E7.*
7. **Stale model-bit pid reuse mis-emits layout (LOW-MEDIUM; §2.4 invariant closes it).**
   *Test: aggressively recycle a slot across ARC→Arena processes; assert stale senders hit
   generation mismatch and dead-letter.*

## 9. Document lineage

- `research.md` — round-1 state-of-the-art survey (BEAM-class concurrency for AOT-native Zap).
- `zap-concurrency-research.md` (this document) — design positions; revision 1 established the
  per-spawn-manager anchor and the monomorphization proposal; revision 2 integrates round-2
  evidence.
- `research-round-2.md` — round-2 evidence: precedents (Nim, MMTk, Verona/Reggio/BoC/Freeze,
  protobuf arenas, mimalloc, Odin), resolutions (receive, Blob/String), corrections (GC shape,
  safepoint sufficiency), and the E7–E10 experiment additions.

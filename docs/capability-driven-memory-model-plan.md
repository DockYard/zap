# Capability-Driven, Manager-Agnostic Memory Codegen — Implementation Plan

Status: **proposed, awaiting approval.** Branch `feat/error-system-deflate`.

## Principle (non-negotiable)

Memory management in Zap is **pluggable**: `Memory.ARC`, `Memory.Tracking`, `Memory.Arena`,
`Memory.NoOp`, `Memory.Leak`, and arbitrary **custom** managers (`impl Memory.Manager for X`).
The compiler must run a **manager-agnostic** ownership/lifetime analysis and gate every memory
operation on **adapter-declared capabilities** — **never** on a manager name and **never** by
hardcoding one manager's strategy. (CLAUDE.md: "implement features in Zap code; never hardcode
behavior in the compiler.")

## The bug this fixes

The compiler's capability model is a **coarse binary** — `REFCOUNT_V1` (declared only by ARC)
vs. nothing — funnelled through `src/memory/elision.zig` `shouldEmitRefcountOps(caps)`. But
`no-REFCOUNT_V1` lumps **three incompatible free-models**:

- **Tracking** — individual free, no refcount (sharing → double-free hazard).
- **Arena** — bulk free (individual frees are no-ops; reclaim at program exit).
- **NoOp / Leak** — never free individually.

Several codegen sites (`emit_share_under_no_refcount`, `emit_deep_walk_under_no_refcount`, the
runtime `shareAnyPersistent`/eager-deep-walk, the recent clone-on-share commits) gate on
*absence of `REFCOUNT_V1`* and therefore impose **Tracking's individual-free + clone-on-share
strategy on Arena/NoOp/Leak** — exactly the hardcoding the principle forbids. Today Arena/NoOp
**panic on first refcount dispatch** (the planned "Phase 6" elision is unbuilt).

## Capability model (the missing axis)

Adapters declare a structured `u64` `declared_caps` (`src/memory/abi.zig`
`ZapMemoryManagerMetaV1`, offset 16; only bit 0 = `REFCOUNT_V1` defined; bits 1–9 reserved).
Add:

**Axis A — reclamation model** (mutually exclusive; proposed bits 1–2):

| Value | Managers | Codegen |
|---|---|---|
| `REFCOUNTED` | ARC | retain/release dispatch, free-at-0, inline `ArcHeader` |
| `BULK_OR_NEVER` | Arena, NoOp, Leak | **elide** retain/release **and** individual free; no `ArcHeader` |
| `INDIVIDUAL_NO_REFCOUNT` | Tracking | elide refcount; **static free-at-last-use**; declared sharing strategy; no `ArcHeader` |
| `TRACED` | GC (conservative, in scope) | **codegen ≡ `BULK_OR_NEVER`** (elide retain/release/free, no `ArcHeader`); the manager reclaims via tracing collection. **Immutability ⇒ no write barriers, ever.** A **conservative** collector (scan stack/registers/globals) needs **no compiler root-map/safepoint codegen** → the work is the manager backend. (Precise/generational GC adds compiler stack-maps + safepoints later — still no barriers.) |

**Axis B — sharing strategy** (only when Axis A = `INDIVIDUAL_NO_REFCOUNT`; proposed bit 3):

| Value | Meaning |
|---|---|
| `CLONE_ON_SHARE` | a persistent second owner gets an independent deep clone (Tracking default) |
| `MOVE_ONLY` | sharing forbidden; ownership strictly moves (relies on move-analysis completeness) — deferred |

`REFCOUNT_V1` (bit 0) implies Axis A = `REFCOUNTED` (validated at build; inconsistent combos
rejected, mirroring `driver.zig`'s existing cap-mismatch rejection). Layout stays a **2-way**
decision (header iff `REFCOUNTED`) — both non-refcounted models want no inline refcount header,
so the ABI/offset surface only ever has two shapes.

Mapping incl. custom: a custom manager **selects the axis values whose codegen contract it
satisfies**; the compiler reads the bits, never the name. A tracing **GC** needs a new Axis-A
value (`TRACED`) **plus write-barrier/root codegen that does not exist** → reserve the value,
reject at build until built (forward-compat per ABI §4.2.4).

## Adapter declaration mechanism (grounded in the done resolution path)

Manager **resolution** is already done (zero-method `Memory.Manager` marker; backend resolved
from the adapter's source file by package convention — `builder.zig`
`resolveMemoryManagerBackendFromSourceGraph`). Capabilities are declared by the
**convention-resolved backend `.zig`** (not the `.zap` marker — keeps "no manager names in the
compiler"): each `src/memory/<x>/manager.zig` sets `declared_caps` in its `.zapmem` metadata.
The value flows `driver.zig` (parse + validate) → `CompileOptions.declared_caps` →
`ZirDriver.declared_caps` → the runtime-source rewrite (`RUNTIME_DECLARED_CAPS_DEFAULT`).
Add the queries to `src/memory/elision.zig` (the single source of truth): keep
`shouldEmitRefcountOps` (now = Axis A == REFCOUNTED), add `reclamationModel(caps)` and
`sharingStrategy(caps)`. Replace `driver.zig`'s blanket `reserved_mask = 0x3FE` rejection with
axis-aware validation (accept defined Axis A/B bits; reject still-unknown bits; reject
inconsistent combos).

## Codegen-gating inventory (every decision site → capability-driven)

- **`src/arc_materialize.zig` `materializeAnalysisArcOps` (the master switch)** — three-way:
  `refcounted` → retain/release/reuse (today); `bulk_or_never` → emit none; `individual_no_refcount`
  → static **free-at-last-use** (no retain, no reuse token).
- **`src/zir_builder.zig`** — `shouldSkipArc`/`shouldEmitRefcountOps` (split three-way); retain
  emission guard; `emit_share_under_no_refcount` (re-gate → `individual_no_refcount && clone_on_share`);
  `emit_deep_walk_under_no_refcount` (re-gate → `individual_no_refcount`); protocol-box-drop
  under no-refcount (three-way); the runtime-branch source emission.
- **`src/arc_drop_insertion.zig`** — `.protocol_box_share` vs `.protocol_box_retain` (split so
  clone is `individual_no_refcount && clone_on_share`, `bulk_or_never` neither).
- **`src/arc_verifier.zig`** — accept all three models; do not flag elided ops as missing under
  `bulk_or_never`.
- **`src/runtime.zig`** — conditional layout (`ArcHeader`, keep 2-way); `shareAnyPersistent`/
  `cloneInnerForShare` (three-way: refcount-bump / clone / identity-no-op); the eager deep-walk
  (`releaseAndPoisonEagerChildren`/`releaseChildrenAny`/`freeAny`) three-way; introduce a comptime
  `reclamation_model` from `runtime_declared_caps`.

## Conditional layout + ABI

Layout is already conditional and **stays 2-way** (header iff `REFCOUNTED`; `ArcHeaderEmpty` is
0 bytes, so any non-refcounted manager already drops the header). No three-way layout, no fork
C-ABI change (the `u64` `declared_caps` has room). New exercise: header-less **individual free**
under Tracking — verify `freeAny`/`core.deallocate` size matches the header-less cell.

## Static ownership + sharing (for `INDIVIDUAL_NO_REFCOUNT`)

`arc_liveness.zig` already produces manager-agnostic, path-sensitive `last_use_sites` /
`last_use_map` / `consume_share_sites` (CFG-aware transfer at calls/returns), and
`arc_ownership.shouldMoveIntoOwnedConsume`. Under `refcounted` these drive *release-elision*;
under `individual_no_refcount`, **invert the consumer**: at the proven last use of an owning
local not transferred onward, emit a **free** (Perceus-without-refcount). Shared ownership is
resolved by the declared Axis-B strategy: `CLONE_ON_SHARE` (deep clone the second owner —
exactly the reverted commits' behavior, re-gated) or `MOVE_ONLY` (compile error on an
unprovable share — deferred).

## Revert + rebuild

1. **Revert** `4a27388`, `bf91c8d`, `5be0101` (the mis-gated clone-on-share; reverse order).
   ARC stays green (they touched only no-refcount paths); Tracking's recursive-struct double-free
   SEGFAULT reappears transiently — accepted.
2. **Keep** `cd7c85e` (erased-opaque-pointer type-classification guard — model-agnostic,
   comptime-dead under ARC). **Re-gate** `bcd739c` (its no-refcount individual-free path is
   Tracking semantics → move under `individual_no_refcount`).
3. **Rebuild** clone-on-share + eager-deep-walk-free as `individual_no_refcount [&& clone_on_share]`
   at the same sites, now reading the Axis queries (won't fire under Arena/NoOp/Leak).

## Phased plan (each phase independently green; ARC green throughout)

- **Phase 0 — capability model + queries (no behavior change).** Axis A/B bit constants
  (`abi.zig`), `elision.zig` queries, axis-aware `driver.zig` validation, the 5 backends'
  `declared_caps`, the `builder.zig` matrix + test helper. `shouldEmitRefcountOps` numerically
  identical for ARC. Verify `zig build test` green + per-manager axis-mapping tests.
- **Phase 1 — revert the 3 clone-on-share commits.** ARC green; Tracking SEGFAULT transiently back.
- **Phase 2 — `bulk_or_never` = pure elision.** Re-gate all conflated sites so Arena/NoOp/Leak
  elide retain/release AND individual free; runtime helpers no-op under it. Verify: Arena/NoOp/Leak
  no longer panic; **zero retain/release in the ZIR** for an Arena build; ARC green.
- **Phase 3 — `individual_no_refcount` = static free-at-last-use + clone-on-share (Tracking).**
  New `arc_materialize` branch (free-at-last-use from `arc_liveness`); clone-on-share re-gated;
  `bcd739c` free path re-gated; verifier accepts the model. Verify: recursive-struct fixture green
  under Tracking; Tracking leak-detection green over the corpus; ARC green.

  **Phase 3 STATUS (checkpoint — primary goals met, two bounded gaps remain):**
  - **DONE: clone-on-share re-gated on the CAPABILITY** (`reclamation_model ==
    individual_no_refcount && sharing_strategy == clone_on_share`, runtime
    `clone_on_share_active`), not `!REFCOUNT_V1`. Fires ONLY for Tracking; never for
    Arena/NoOp/Leak. `shareAnyPersistent`/`cloneEagerChildValue` (runtime),
    `emit_share_under_clone_on_share` (zir_builder `.retain` → `shareAnyPersistent` +
    rebind), `extractRetainKind` (ir), V10 verifier entry. ARC byte-for-byte unchanged
    (clone branch comptime-dead under refcounted).
  - **DONE: consumed-vs-standalone owner model.** A `.persistent` retain that emits a real
    `shareAnyPersistent` clone REMOVES its dest from `arc_share_skipped`
    (`unmarkShareSkippedForClone`, gated on `clone_on_share_active`), so a standalone clone's
    release fires (no leak) while a clone consumed into a container is freed by the container's
    deep-walk (drop-insertion already omits its release) and a transient borrow
    (`.normal`/`protocol_box_retain`, no clone) keeps its suppression (no double-free).
  - **GREEN: recursive-struct double-free SEGFAULT eliminated** (chain_sum / LinkedNode /
    `head=%LinkedNode{next:tail}`+tail-live); deep multi-frame chains; two-binding shared
    ownership; **zero `invalid free`** (was many); **ARC 942/0 byte-identical; golden 14/14;
    host `zig build test` exit 0.** Tracking corpus: 942 tests, 10 failures (down from a
    whole-corpus SEGFAULT) — 0 crashes, 0 invalid-frees, no program-exit leaks.
  - **GAP A — free-at-last-use placement (RESOLVED for the free-at-last-use cases; 7 of 9).**
    The boxed-closure `assert_no_leaks` fixtures sample `live_allocation_count()` MID-SCOPE; a
    box `protocol_box_drop` (or a list-of-boxes `.release`) parked at function scope-exit is
    counted as a live "leak" though it is reclaimed at exit. **Fix (commit `74ce510`):** new pass
    `arc_drop_insertion.relocateOwnedDropsToLastUse`, run after `rewriteProtocolBoxReleases`,
    gated on `reclamationModel == individual_no_refcount` (ARC byte-identical). It relocates each
    scope-exit drop to immediately after the proven last use of the dropped local's FORWARD ALIAS
    CLOSURE (copy/borrow/move/local_get/share-derived — necessary because a box parked in `add5`
    is read only by a `copy_value` feeding a transient `protocol_box_retain` borrow that the
    dispatch call consumes, so `last_use_map[add5]` alone would free the box before the borrow's
    use). Count-preserving timing move (inverts the refcounted release-elision over the same
    `arc_liveness` use facts). **Safety guards:** `protocol_box_drop` relocates always (each owner
    holds an independent box); a plain `.release` relocates only when the pre-drop region is
    straight-line AND the local is not embedded into an aggregate or persistently shared
    (`streamRegionIsStraightLine` + `localIsEmbeddedOrShared`), avoiding the recursive-struct /
    `Zest` case-dispatcher `shareAnyPersistent` deep-clone hazard (a relocated drop ahead of a
    deep-clone read would UAF). All 7 `closure_boxed_test.zap` boxed-closure fixtures now green.
    **REMAINING (2 of 9 — `combinator_boxed_test.zap` `Enum.filter`/`Enum.reject`):** NOT a
    free-at-last-use case. The user predicate is a 0-capture closure lowered to a BARE FN-PTR; it
    is auto-boxed into a `Callable` existential (an 8-byte `__closure_N`) lazily at the
    bare-fn→`Callable` coercion inside the devirtualized `Enum.filter`/`filter_next` recursion,
    where the `Callable` predicate param is classified `.trivial` and threaded through every
    recursion as non-owning — so the coercion box has NO owner and NO scope-exit drop anywhere
    (it is not even in `protocol_box_locals`). This is a distinct **boxed-`Callable` combinator
    coercion-ownership** bug (param-convention `.trivial`-misclassification + auto-box coercion
    ownership), not a misplaced/relocatable drop. Its proper fix changes `arc_param_convention`
    for boxed-`Callable` params and the coercion-box ownership — a broad cascade that must keep
    ARC byte-identical — so it is deferred to the verification-matrix / combinator-bridge phase
    (the `combinator_boxed_test.zap` header already flags boxed-`Callable` combinator handling as
    a separate effort).
  - **GAP B — List/Map COW under `clone_on_share` (RESOLVED for Tracking; the BULK_OR_NEVER/TRACED
    corner CLOSED in Phase 6).** `mutationMayMoveInPlace` originally returned `true` unconditionally
    under `!refcount_v1_active` (always mutate in place), but the pre-existing clone-on-share
    DELIBERATELY aliased inline-header List/Map cell buffers ("never eagerly freed" bulk-free-era
    reasoning). So an aliased list (`original_alias = values`) shared the buffer and an in-place
    `List.set` / push-grow `bufferFreeShallow` corrupted/freed it out from under the alias
    (`generic_list_test.zap` "copy-on-write preserves aliased original string list" read a garbage
    length — a use-after-free). **Tracking fix (commit `cc23e97`):** extend clone-on-share to
    inline-header cells — every share hands the new owner an INDEPENDENT deep clone of the buffer
    via new `List.cloneForShare` / `Map.cloneForShare`, wired into every share site
    (`shareAnyPersistent`, `cloneEagerChildValue`, `cloneFieldChildInPlace`, `List.ownElement`,
    `Map.ownEntryKey`/`ownEntryValue`) through the new comptime predicate
    `valuePointsToInlineHeaderCell` + `cloneInlineHeaderCellForShare` dispatch. Each owner uniquely
    owns its buffer, in-place mutation stays sound, and an aliased original is never corrupted.
    Gated strictly on `clone_on_share_active` (INDIVIDUAL_NO_REFCOUNT only). **BULK_OR_NEVER/TRACED
    corner — CLOSED in Phase 6 (capability-aware `mutationMayMoveInPlace`).** Because clone-on-share
    is comptime-dead under BULK_OR_NEVER (Arena/NoOp/Leak) and TRACED (GC), the `true`-always gate
    still corrupted aliases there: with no refcount and no clone-on-share, an aliased list genuinely
    shares one buffer, so an in-place `List.set` was a wrong answer / use-after-free (the corpus's
    single 942/1 failure under Arena/GC). The fix rewrites `mutationMayMoveInPlace` to switch on
    `reclamation_model`: `.refcounted → header.count()==1`, `.individual_no_refcount → true`
    (clone-on-share guarantees a unique buffer), `.bulk_or_never, .traced → false`. The `false`
    branch takes the value-semantic clone (`cloneBufferRetainingChildren`, retain elided → shared
    children, fine since children aren't freed individually) and never frees the old buffer (frees
    elided) — the alias stays valid; the manager reclaims in bulk / by tracing. Statically-proven-
    unique sites stay O(1): the optimize-mode unchecked-uniqueness rewrite emits
    `set/push/pop_owned_unchecked` at Release, which bypass this gate. The COW test now passes under
    ALL six managers at BOTH Debug and Release (corpus 942/0 under Arena/GC, was 942/1); the Release
    run is the soundness proof that the rewrite leaves the aliased site checked → copy. **Per-drop
    buffer free on release (step 3) is NOT yet adopted** (commit `0a995ea` documents why): not every
    aliasing site routes through `cloneForShare` (`List.append`'s `retain(a)` pass-through, the
    Range/`Enum.take_next` element flows), so a per-drop `List/Map.release` buffer free double-frees
    an aliased buffer (verified: trace/breakpoint trap). Buffers stay reclaimed at process teardown —
    the documented Tracking allocation model — pending the full no-refcount static-ownership model
    that guarantees a unique owner per buffer.
- **Phase 4 — per-manager corpus + custom-manager test. DONE.** Lock in the verification matrix.

  **Phase 4 STATUS (COMPLETE):**
  - **DONE: custom-manager caps-driven-codegen proof (the adapter-bounded acceptance test).**
    Two TEST-FIXTURE custom managers — neither a stdlib manager, both names unknown to the
    compiler — declare the same `declared_caps` as their stdlib peers and get byte-identical
    codegen purely from the caps bits:
    `script_fixtures/custom_manager_proof/src/custom/bulk_arena/manager.zig` (`Custom.BulkArena`,
    BULK_OR_NEVER, `declared_caps == 0x0`, a bespoke chunked-bump allocator ≠ the stdlib Arena);
    `.../tracking_pool/manager.zig` (`Custom.TrackingPool`, INDIVIDUAL_NO_REFCOUNT | CLONE_ON_SHARE,
    `declared_caps == 0x2`, an individual-free allocator with a live counter + deinit leak gate).
    Each backend's refcount slots are `@panic` stubs, so a wrongly-emitted refcount op (the failure
    mode if codegen special-cased an unrecognised name and fell back to refcounted codegen) aborts
    the run; running to completion with the expected output proves the elision (BULK_OR_NEVER) /
    static-free (INDIVIDUAL_NO_REFCOUNT) codegen was selected from the caps alone. Verified: the
    custom BULK_OR_NEVER program produces output IDENTICAL to `Memory.Arena`; the custom
    INDIVIDUAL_NO_REFCOUNT program produces output IDENTICAL to `Memory.Tracking` with no leak
    survivor. The `.zapmem` section bytes confirm `declared_caps == 0x0`/`0x2` (== Arena/Tracking).
  - **DONE: no-name-special-casing-in-codegen audit.** `src/arc_materialize.zig`,
    `arc_drop_insertion.zig`, `arc_verifier.zig`, `arc_liveness.zig`, `memory/elision.zig` contain
    ZERO manager-name string compares; every memory-codegen gate keys off
    `elision.reclamationModel(caps)` / `sharingStrategy(caps)` / `shouldEmitRefcountOps(caps)`.
    Resolution-by-name (`builder.zig`) and the script-mode stdlib allowlist (`main.zig`
    `SCRIPT_MEMORY_MANAGERS`, the 5 stdlib names — single-file mode has no dependency graph) are
    the convention, NOT codegen. `memory/elision.zig` carries a unit test proving the custom caps
    (0x0/0x2) map identically through the projection functions to the stdlib peers.
  - **DONE: verification matrix.** `script_fixtures/run_custom_manager_proof.sh` asserts all 6
    managers' contracts and PASSES: ARC (representative run; corpus 942/0 + V8 verifier asserted by
    `zap test` / `zig build test`); Arena/NoOp/Leak (BULK_OR_NEVER — run, no refcount panic; NoOp
    allocating → documented OOM, not a refcount panic); Tracking (INDIVIDUAL_NO_REFCOUNT — runs,
    leak-gated clean); custom BulkArena == Arena and custom TrackingPool == Tracking. The
    `zir-test` step adds build+run integration tests for both custom managers.
  - **CHARACTERIZED + TRACKED: recursive-struct Tracking leak (gap #302).** Under `Memory.Tracking`
    a recursive indirect-storage struct (`LinkedNode.next`) double-walked by two self-recursive
    `.borrowed`-param functions leaks 6 `%LinkedNode{}` deinit survivors (part of the corpus's
    stable 12-alloc / 336-byte total). EVERY corpus assertion still PASSES (942/0) and ARC is
    byte-clean — the leak is a deinit-time survivor, not an assertion failure. ROOT CAUSE: `src/ir.zig`
    `extractRetainKind` classifies every non-list/map aggregate extraction (`node.next`) as
    `RetainKind.persistent`, which under clone-on-share DEEP-CLONES the recursive struct even when
    the extracted value flows only into a `.borrowed` (non-owning) recursive call and is released at
    its last use (a transient borrow). The spurious per-recursion-level clones and the outer clone's
    deep-walk-free do not reconcile, orphaning cells. The decision is made at IR-BUILD time from the
    extracted TYPE alone, with no knowledge of the downstream consumer's ownership convention; a
    SOUND fix must defer/refine it with post-`arc_liveness` escape + consumer-convention analysis
    (downgrade `.persistent` → borrow when the extract feeds ONLY borrowing consumers, ARC
    byte-identical) — the consumed-vs-standalone owner model of **task #302**, a broad cascade with
    high ARC-regression risk, NOT a localized Phase-3 patch. Forcing `.normal` unconditionally would
    double-free the shapes that genuinely need the clone (a child extracted and STORED as a true
    co-owner). Surfaced + tracked by
    `script_fixtures/run_recursive_struct_leak_characterization.sh` (asserts corpus 942/0 + the
    12-alloc deinit leak present; a future fix that removes the leak FAILS the harness — the signal
    to retire the characterization and flip the corpus to leak-free) and documented inline at the
    leaking tests in `test/struct_test.zap`.
- **Phase 5 — `TRACED` conservative GC manager (in scope).** Add `lib/memory/gc.zap` (zero-method
  marker) + `src/memory/gc/manager.zig` (conservative stop-the-world mark-sweep: managed heap;
  on threshold/OOM, conservatively scan stack + registers + globals for word-aligned heap
  pointers, mark reachable, sweep unmarked; interior-pointer-aware; single-/stop-the-world). It
  declares Axis A = `TRACED`, whose **codegen reuses Phase-2 `BULK_OR_NEVER` elision** (no
  retain/release/free, no `ArcHeader`, alloc routes through the manager) — so the COMPILER needs
  no new emission (immutability ⇒ no barriers; conservative ⇒ no root maps/safepoints). Verify: a
  GC build runs to completion reclaiming garbage (a loop allocating-and-dropping stays bounded in
  RSS, unlike NoOp/Leak); the corpus runs under GC; ARC green. (Precise GC = future.)

  **Phase 5 STATUS (COMPLETE — single-platform v1: darwin/aarch64 + linux/x86_64):**
  - **DONE: driver accepts TRACED.** `src/memory/driver.zig` `validateDeclaredCaps` accepts the
    Axis-A TRACED code (`0b10`, `declared_caps == 0x4`); only `0b11` stays reserved. The
    `abi.zig`/`elision.zig`/`driver.zig` comments no longer say "reserved until GC" — they now
    record that the conservative collector backend has shipped. No new compiler emission: TRACED
    reuses the BULK_OR_NEVER codegen verbatim (`elision.reclamationModel(0x4) == .traced`, gated
    identically to `.bulk_or_never` at every memory-op site).
  - **DONE: `lib/memory/gc.zap`** — zero-method `Memory.GC` + `Memory.Manager` impl marker; resolves
    by package convention to `src/memory/gc/manager.zig`; the compiler reads the TRACED caps, never
    the name.
  - **DONE: `src/memory/gc/manager.zig`** — production conservative stop-the-world mark-sweep
    collector (`declared_caps == 0x4`). Size-segregated 64 KiB `mmap` slabs (18 classes 16..8192 B)
    + dedicated large-object regions above 8 KiB, all `page_allocator`-backed so sweep `munmap`s
    pages back to the OS. Base-sorted `ObjectRecord` table → O(log n) binary-search interior-pointer
    resolution (an interior address pins the whole object). 2× multiplicative growth threshold
    (`MIN_HEAP_BYTES` floor). Collection: clear marks + sort; `flushRegisters` (inline-asm GPR spill,
    aarch64 `stp x0..x29` / x86_64 `mov rax..r15`) into a 32-word stack buffer; scan registers +
    live stack span `[currentStackPointer, stack_bottom)` + writable globals; transitive mark via
    explicit worklist (no native recursion); sweep frees unmarked cells / unmaps large objects.
    `stack_bottom` captured at `gcInit` via an inline-asm SP read (NOT `@frameAddress` — unsafe under
    frame-pointer elision in `ReleaseFast`). Globals: Mach-O walks `_mh_execute_header` load commands
    for WRITE-`initprot` segments (ASLR slide from `__TEXT`); ELF scans `[__data_start, _end)`.
    `deallocate` + every refcount slot is a no-op/`@panic` stub (codegen elides them under TRACED).
  - **DONE: selection wiring.** `main.zig` `SCRIPT_MEMORY_MANAGERS` + diagnostic list `Memory.GC`;
    `builder.zig`'s stdlib resolution matrix includes it; `-Dmemory=Memory.GC` works in script mode.
  - **PROVEN: bounded-RSS reclamation** (`script_fixtures/gc_bounded_rss_loop.zap`, 2 M iterations ×
    a 4-node chain = 8 M transient allocations, program-binary RSS isolated from the compiler):
    **`Memory.GC` peak RSS ≈ 2.8 MiB (bounded — the collector reclaims)** vs **`Memory.Leak` ≈
    5.9 GiB (unbounded — never reclaims)**, a ≈2000× difference, with byte-identical correct output
    (`20000000`). This is the proof the collector reclaims garbage.
  - **PROVEN: no premature free** (`script_fixtures/gc_live_graph_stress.zap`, a live 500-node chain
    held across 200 k churn iterations each dropping a fresh 500-node garbage chain = 100 M transient
    nodes): the exact final sum **125250** (= 500·501/2), deterministic across runs, proves the mark
    worklist + interior `next` tracing keeps every live node and reclaims only garbage.
  - **RESOLVED (Phase 6): corpus under GC == corpus under Arena == 942 tests / 0 failures.**
    Previously CHARACTERIZED as 942/1 — `zap test -Dmemory=Memory.GC` reported the same single
    failure as `Memory.Arena`/`Leak` (`generic_list_test.zap` "copy-on-write preserves aliased
    original string list"), a GAP-B BULK_OR_NEVER property (the clone-on-share COW fix `cc23e97` is
    comptime-dead under BULK_OR_NEVER/TRACED, so `List.set`/`List.push` mutated the shared buffer in
    place and corrupted the alias — proven not a GC free because `Memory.Arena`, which cannot free a
    live object mid-run, corrupted the alias identically). **Phase 6 closes this** by making
    `mutationMayMoveInPlace` capability-aware (`.bulk_or_never, .traced → false`): the runtime gate
    now takes the value-semantic clone for the not-statically-proven aliased mutation, so the alias
    survives. The collector / Arena bulk-free reclaim the extra garbage. Now `zap test
    -Dmemory=Memory.GC` and `-Dmemory=Memory.Arena` are both 942/0 at BOTH Debug and Release; the
    `script_fixtures/run_custom_manager_proof.sh` GC-corpus-parity row asserts the COW test PASSES
    under both and GC failure count == Arena failure count == 0.
  - **NO REGRESSION:** host `zig build test` exit 0; ARC `zap test` 942/0 + V8 verifier; Tracking
    942/0; Arena/NoOp/Leak/GC `zap test` 942/0 (Debug + Release); golden 14/14; FCC; the full matrix
    harness PASSES all 6 managers. (The ARC `-Doptimize=ReleaseFast` `arc_verifier` V11 diagnostic on a
    combinator/boxed-`Callable` function that surfaced here was a separate, pre-existing combinator
    ARC-optimizer shape unrelated to `mutationMayMoveInPlace` — since RESOLVED by the Perceus
    owned-scrutinee gate `6f06685`; see the Phase 6 STATUS note below.)
  - **FUTURE (out of v1 scope):** precise/generational collection (compiler stack-maps +
    safepoints on the same TRACED capability — still no write barriers, since Zap is immutable);
    additional platforms (the register flush + global-segment bounds are arch/OS-specific; an
    unsupported target soundly falls back to the stack-only scan).
  - **EXPLICIT NON-GOAL — multi-threaded shared-heap collection.** Zap's concurrency direction is a
    BEAM-style per-process model: each process owns its heap AND its memory manager and collects
    independently (one collector instance per process over a private heap; messages copy between
    heaps, which fits immutability), so cross-thread root scanning / global stop-the-world is not
    planned. The existing single-threaded collector is the correct shape for per-process collection,
    and the capability axis is the natural per-process manager knob (a short-lived process can use
    Arena → bulk-free at process death → zero collection; a long-lived one uses GC or ARC).
- **Phase 6 — capability-aware in-place mutation (immutability under BULK_OR_NEVER/TRACED). DONE.**
  Closes the last hole in the capability-driven memory model: Zap's immutability guarantee
  (`List.set`/`push`/`pop` return a NEW list, leaving the original intact) was violated under
  BULK_OR_NEVER (Arena/NoOp/Leak) and TRACED (GC). The single corruption site was
  `List.mutationMayMoveInPlace` (`src/runtime.zig`), which gated the in-place fast path on the
  coarse `!refcount_v1_active` and returned `true` (always mutate in place) for all three
  non-refcounted models — sound ONLY under INDIVIDUAL_NO_REFCOUNT (clone-on-share already hands
  each owner a unique buffer). Under BULK_OR_NEVER/TRACED clone-on-share is comptime-dead, so an
  aliased list shared one buffer and an in-place mutation corrupted the alias (a wrong answer /
  use-after-free, the corpus's single 942/1 failure).

  **Fix:** rewrite the gate to switch on `reclamation_model` (the comptime constant already
  mirrored from `elision.reclamationModel`): `.refcounted → header.count()==1` (classic ARC COW,
  unchanged), `.individual_no_refcount → true` (clone-on-share guarantees a unique buffer,
  unchanged), `.bulk_or_never, .traced → false` (no runtime uniqueness signal → value-semantic
  copy). The `false` branch clones the buffer (retain elided → shared children, fine since children
  aren't freed individually) and never frees the old buffer (frees elided) — the alias stays valid;
  the manager reclaims in bulk / by tracing. **Optimal static behaviour preserved:** the
  optimize-mode unchecked-uniqueness rewrite (`arc_ownership.rewriteUncheckedUniquenessSites`, gated
  by `policy.rewrite_unchecked_uniqueness` — ON at Release, OFF at Debug) emits
  `set/push/pop_owned_unchecked`, which mutate in place unconditionally and bypass this gate. So at
  Release proven-unique mutations stay O(1) in-place and only the not-statically-proven remainder
  copies; at Debug everything copies. `List.append`/`concat`/`cons` and `Map.put`/`delete`/`merge`
  are untouched — they gate on raw `header.count()==1`, which is `0==1`=false under non-refcounted
  (`ArcHeaderEmpty.count()` returns 0), so they already took the clone path soundly.

  **Phase 6 STATUS (COMPLETE):**
  - **DONE: the fix** (`src/runtime.zig` `List.mutationMayMoveInPlace`; ARC + Tracking arms
    byte-identical to before; only bulk_or_never/traced flip `true`→`false`).
  - **PROVEN: corpus 942/0 under ALL six managers at BOTH Debug and Release.** ARC/Tracking/Arena/
    Leak/GC `zap test` 942/0 at Debug and at `-Doptimize=ReleaseFast` (NoOp can't allocate → OOM,
    unchanged). The Release runs are the soundness proof that the unchecked-uniqueness rewrite is
    sound under BULK_OR_NEVER/TRACED: it leaves the aliased `List.set` checked (→ copy) while the
    non-aliased pushes may be unchecked.
  - **PROVEN: the COW test** (`generic_list_test.zap` "copy-on-write preserves aliased original
    string list") passes under ARC/Tracking/Arena/Leak/GC at both modes (was the 942/1 failure).
  - **NO REGRESSION:** host `zig build test` (ARC + V8 verifier) exit 0; GC bounded-RSS (≈2.8 MiB
    vs Leak ≈4.3 GiB) and no-premature-free (125250) still hold; golden 14/14; custom-manager
    matrix PASSES (GC corpus == Arena corpus == 942/0).
  - **RESOLVED (`6f06685`, task #320):** ARC at `-Doptimize=ReleaseFast` previously tripped an
    `arc_verifier` V11 diagnostic on the combinator/boxed-`Callable` function (`CombinatorMapBoxedTest`).
    Root cause (a false-positive, not a real leak): the Perceus reuse pass emitted a spurious `.reset`
    on the by-value tuple returned by `List.next` (a `.trivial` local, not a heap ARC cell). Fix:
    `src/perceus.zig` `scrutineeReuseEligible` gates reuse-pair generation on an `.owned` scrutinee
    (excludes `.trivial`/`.borrowed`). ARC-Release corpus now 942/0; ARC-Debug byte-identical.

## Verification matrix

| Manager | Axis A / B | Assert | How |
|---|---|---|---|
| ARC | REFCOUNTED | byte-identical to today; corpus green | host + Zest, every phase |
| Arena | BULK_OR_NEVER | runs, no panic; **zero retain/release ZIR ops**; bulk-free at exit | run + ZIR inspection |
| NoOp | BULK_OR_NEVER | runs to first alloc → documented OOM; no refcount dispatch | NoOp build |
| Leak | BULK_OR_NEVER | runs; no retain/release vtable refs | Leak build + symbol/ZIR check |
| Tracking | INDIVIDUAL_NO_REFCOUNT / CLONE_ON_SHARE | corpus green under canary; no LEAK/INVALID-FREE/UAF; recursive-struct no double-free | Zest corpus under Tracking |
| **custom** (test fixture) | declares own A/B | compiler reads caps, no name special-casing; codegen matches the declared axes | a custom backend declaring e.g. BULK_OR_NEVER → same codegen as Arena |

## Risks

ARC no-regression (highest — Axis A==REFCOUNTED must be byte-identical; host default keeps
`REFCOUNT_V1`); move-analysis inversion (free-insertion + join-point correctness in the new
`arc_materialize` branch — medium); custom-manager extensibility (axis enum must suffice; GC
reserved-and-rejected); layout/ABI (low — stays 2-way); fork-touch (low — `u64` has room,
ZIR-only). `zig build test` + `zap test` (ARC) green at every phase. NEVER `zig build zir-test`.

## Decisions (defaults proposed; confirm before Phase 0)

1. **Axis encoding** — Axis A (`REFCOUNTED`/`BULK_OR_NEVER`/`INDIVIDUAL_NO_REFCOUNT`) in bits 1–2,
   Axis B (`CLONE_ON_SHARE`/`MOVE_ONLY`) in bit 3; shrink `reserved_mask`. Raw bits (not a FourCC
   descriptor) — simpler, compiler reads static data only.
2. **Tracking sharing default** = `CLONE_ON_SHARE` (matches the reverted behavior); `MOVE_ONLY` deferred.
3. **GC/tracing** — **IN SCOPE** (user decision). Implemented as a **conservative stop-the-world
   mark-sweep** manager: immutability ⇒ no write barriers; conservative root scan ⇒ no compiler
   root-map/safepoint codegen; codegen reuses the `BULK_OR_NEVER` elision. The deliverable is a
   `lib/memory/gc.zap` adapter + a conservative mark-sweep backend (`src/memory/gc/manager.zig`)
   declaring `TRACED`. Precise/generational GC (compiler stack-maps + safepoints, still no
   barriers) is a future enhancement on the same `TRACED` capability — out of scope for v1.
4. **Conditional layout** — stays the existing 2-way header/no-header split; no per-type specialization.
5. **`bcd739c`** — re-gate in the rebuild; **`cd7c85e`** untouched.

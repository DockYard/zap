# Zap: k-nucleotide RSS gap — implementation plan

> **Companion to** `docs/k-nucleotide-rss-gap-research-brief.md`. Read
> the brief first if unfamiliar with Zap, the Zig fork, the Map ARC
> substrate, or the failure mode this plan addresses. This document is
> the execution plan.

---

## 0. North star

The compiler must learn ownership transfer for ARC-managed values.
Today it doesn't, and `Map(K,V)` cannot be safely added to the set of
ARC-managed types because the codegen emits drops on locals whose
ownership has been moved into a call or sourced into a return. The
fix is a **first-class Perceus-style ownership pass** in Zap's IR
layer that:

1. Computes last-use sites for every ARC-managed local via CFG-aware
   backward liveness analysis.
2. Lowers a last-use call argument as **consume** (transfer
   ownership) rather than retain-and-drop.
3. Elides the scope-exit drop for any local sourced directly into a
   `ret` instruction.
4. Only after 1-3 are correct: extends `IrBuilder.isArcManagedType`
   to recognize `.map`.

The pass is **generic** — it applies uniformly to every ARC-managed
type, not just Map. Once it lands, retain/release ping-pong vanishes
from List, String, MArrayI64, MArrayF64, Range, and DynClosure as
well, even though those types currently work because their
allocation patterns don't accumulate path-copy spines.

Success means k-nucleotide drops from 7.36 GiB peak RSS to a
projected 50-200 MiB and from 3.6 s runtime to a projected ≤ 1 s,
while the existing 681/681 unit + 99/99 zir-test sweep stays green
and all three CLBG benchmark ports remain byte-exact.

---

## 1. Design principles (non-negotiable)

These principles flow from the research and from `CLAUDE.md`. Every
decision in this plan must be reconcilable with them.

**1.1 Ownership is explicit in IR.** Whether a `share_value`
instruction retains or consumes is a property carried on the
instruction itself, not inferred from instruction shape, surrounding
context, or string-name conventions. The previous reverted attempt
matched a trailing `call_named + releases + ret` pattern in a
post-hoc rewrite; that approach failed because IR shape alone is not
a reliable proxy for semantic ownership. Encode the semantics
directly.

**1.2 Escape elision and consume elision are different categories
and stay separated.** The existing `arc_share_skipped` set captures
"this share's retain was skipped because the source is
stack-eligible per the escape lattice." That is a low-level physical
optimization. Consume-at-last-use is a semantic transfer of
ownership at the IR level. Both result in skipped retains, but for
different reasons; conflating them obscures both. Introduce a
parallel set `arc_consumed_locals` (and a `arc_returned_locals`
set) that the new pass populates.

**1.3 The pass is generic, not Map-specific.** No special cases for
`Map.put` or any other API in the pass. The pass operates over the
abstract category of ARC-managed locals as defined by
`isArcManagedType`. When the flag flips, Map joins the existing set
naturally.

**1.4 Land in small commits.** The previous attempt failed in part
because it tried to do a 158-line transformation in one pass. This
plan splits the work into seven phases, each with its own
verification gate, each individually safe to ship. Phases 1-2 add
analysis without altering generated code; phase 3 adds the new IR
shape with default behavior preserved; phases 4-5 enable the
optimization; phase 6 flips the flag; phase 7 hardens.

**1.5 No workarounds.** No "use a flat-array hash set in
k-nucleotide instead of Map." No "mark Map.put as a special
consuming function with a hardcoded name match." No "add a `move`
keyword to the user-facing language so users opt in." If the design
needs to change a foundational pass, it changes that pass.

**1.6 No new ZIR opcodes in the Zig fork.** Everything must lower
through standard Zig calls + ordinary releases + ordinary
retains. The fork is allowed to grow C-ABI surface area for existing
ZIR opcodes, but Zap-side consume semantics must compile down to
sequences Zig already understands. A consume is just "don't emit
the retain, don't emit the release"; that's pure absence, no new
primitive.

**1.7 TDD with failing tests at every phase boundary.** Each phase
introduces one or more tests that fail before the phase's
implementation lands and pass after. The test suite is the gate
between phases.

---

## 2. Architecture

### 2.1 New IR additions

**`Instruction.share_value` gains a `mode` field:**

```zig
pub const ShareMode = enum {
    /// Default. Emits assign + retain. Caller's local stays live;
    /// callee's slot gets an independent ownership reference.
    /// Pairs with a release at scope exit (unless suppressed by
    /// arc_share_skipped from the escape lattice).
    retain,
    /// Caller transfers ownership. Emits assign only — no retain.
    /// The source local is marked in arc_consumed_locals so its
    /// scope-exit release is also suppressed. Net effect: zero
    /// refcount operations, ownership moves from source to dest.
    consume,
};
```

Default value is `.retain` so all existing IR sites retain current
behavior unless the new pass explicitly upgrades them.

**Two new tracking sets in `ZirDriver` / `IrBuilder`:**

```zig
/// Locals whose `share_value` retain was skipped because the source
/// was at its last use (Perceus-style ownership transfer).
/// Their scope-exit release is also suppressed.
arc_consumed_locals: std.AutoHashMapUnmanaged(LocalId, void) = .empty,

/// Locals that are the source of a `ret` instruction. The ownership
/// flows from this local into the caller's return slot, so the
/// callee's scope-exit release on this local is suppressed.
arc_returned_locals: std.AutoHashMapUnmanaged(LocalId, void) = .empty,
```

**Note on naming.** The existing `arc_share_skipped` set is for
escape-lattice skips; do not rename or repurpose it. The names of
the three sets should make their distinct purposes obvious in the
code.

### 2.2 Pipeline placement

The new pass runs **after** monomorphization and **before**
`zir_builder` lowers to ZIR. Conceptually it lives alongside
`src/perceus.zig` and `src/escape_lattice.zig`, both of which
already operate on monomorphized IR.

```
HIR
  └─ src/monomorphize.zig
       └─ Specialized IR (per-clause, per-instantiation)
             └─ src/perceus.zig            (existing — read first)
                  └─ src/arc_liveness.zig  (NEW — ownership pass)
                       └─ src/escape_lattice.zig
                            └─ src/zir_builder.zig
                                 └─ standard Zig ZIR
                                      └─ libzap_compiler.a
                                           └─ Native binary
```

The decision to put it before `escape_lattice` is deliberate:
escape elision is a strict optimization on top of an already-correct
ARC discipline. If the new pass produces wrong consume decisions,
escape lattice has no information to recover from. Conversely,
putting the new pass before escape lattice means escape lattice can
still elide retains we didn't elide via consume, on a separate
codepath.

### 2.3 The pass: `computeArcOwnership`

A single pass computes both consume sites and return sources. It
does **not** modify the IR; it produces a side table that the
`share_value` lowering and the function epilogue drop emission both
consult.

```zig
pub const ArcOwnership = struct {
    /// Locals whose `share_value` to a call-arg slot is a last-use
    /// transfer. Indexed by share_value instruction id.
    consume_share_sites: std.AutoHashMapUnmanaged(InstructionId, void),

    /// Locals that are the immediate source of a `ret` instruction.
    /// At function epilogue drop emission, locals in this set are
    /// excluded from the drop list.
    return_source_locals: std.AutoHashMapUnmanaged(LocalId, void),

    /// For diagnostics — every ARC-managed local's last-use
    /// instruction id. Used by debug counters and pretty printers.
    last_use_map: std.AutoHashMapUnmanaged(LocalId, InstructionId),
};

pub fn computeArcOwnership(
    allocator: std.mem.Allocator,
    function: *const Function,
    type_store: *const TypeStore,
) !ArcOwnership;
```

**Algorithm.** Standard backward dataflow.

1. Filter to ARC-managed locals only (cheap — there are typically
   far fewer Arc locals than total locals in a function).
2. Build CFG. Zap IR's actual control-flow representation needs
   verification during phase 2 implementation; in the worst case
   we synthesize a CFG from the structural representation.
3. Compute `live_out[block]` and `live_in[block]` over ARC locals
   via the standard fixpoint:
   - `live_out[B] = ⋃ live_in[succ] for succ ∈ successors(B)`
   - `live_in[B] = use[B] ∪ (live_out[B] \ def[B])`
4. For each instruction in each block (walking forward), maintain
   `live_after` and check each ARC local read by the instruction:
   if the local is in `live_before` but not in `live_after`, this
   is a last use.
5. Apply the two specialization rules:
   - **Last use is a `share_value` whose `dest` is a call-argument
     slot** → mark this share-instruction id in
     `consume_share_sites`.
   - **Last use is the value of a `ret` instruction** → mark the
     local in `return_source_locals`.

**Per-block vs CFG-wide.** The research notes that block-local
last-use is often sufficient when drops are emitted at function
exit, since drop placement is global. We do CFG-wide because (a)
it's cheap (bitset dataflow over a small set of locals), (b)
basic-block-local fails the moment the IR has loops or branching
returns, both of which `count_kmers_loop` and many other realistic
patterns hit, and (c) Perceus-style consume needs to know "is this
the *function-wide* last use" not "is this the last use in this
block." A local last-used in block B is *not* a transfer site if it's
also live in block C (B's successor on some path).

**Duplicate-arg ordering.** When a call has the same local as
multiple arguments — `f(x, x)` — only the *last evaluated* occurrence
is a consume site. Earlier occurrences must remain `.retain` (the
caller still holds the local, so each non-last arg gets its own
refcount). The "last evaluated" ordering must match `zir_builder`'s
actual emission order, which is ordinarily left-to-right (verify
during phase 2). The pass walks args in evaluation order; only the
final occurrence of a given local is a candidate for consume, and
only if the local is not used again after the call.

**Soundness contract.** For every ARC local L:
- If L is in `consume_share_sites` (via some site S) AND L is in
  `return_source_locals`, that's a bug — it would double-transfer.
  Assert during pass construction.
- If L is in `consume_share_sites`, L must NOT appear in any
  instruction after S along any CFG path. Assert.
- If L is in `return_source_locals`, L must NOT appear after the
  `ret` instruction. (Trivially true since `ret` is a terminator.)

These assertions become runtime checks in debug builds and become
silent in release builds. They catch the most common
misimplementation bugs.

### 2.4 Where the side table is consulted

**zir_builder share_value lowering** (`src/zir_builder.zig:4063+`)
checks if the current `share_value`'s instruction id is in
`consume_share_sites`. If yes, emits the assign without the retain
and adds the source local to `arc_consumed_locals`. If no, falls
through to existing retain-emission logic (which itself may skip
via `arc_share_skipped`).

**Function epilogue drop emission** (search for the drop list builder
in `src/ir.zig` and / or `src/zir_builder.zig` — phase 2 will pin
the exact site) filters the drop list against three sets:
1. `arc_share_skipped` (existing — escape)
2. `arc_consumed_locals` (new — ownership transferred to call)
3. `arc_returned_locals`, populated from `return_source_locals`
   (new — ownership returned to caller)

A local in any of those three sets does not get a release at scope
exit.

---

## 3. Phased delivery

Each phase:
- Has a single landing commit (or a tight series — no orphan WIP).
- Adds failing tests *before* the implementation lands in the same
  commit.
- Runs the full verification matrix at the gate.
- Is individually shippable: if work stops mid-roadmap, the codebase
  is in a coherent state.

Phases 1-3 are pure plumbing — no behavior change. Phases 4-5 enable
ownership transfer for *existing* ARC-managed types
(opaque_type only). Phase 6 flips the flag for `.map`. Phase 7 is
hardening.

### Phase 1 — Instrumentation and reproducer harness

**Goal.** Make the leak observable in the test suite at fast speeds
so phase 2-6 progress is measurable per-commit, not per-CLBG-run.

**Files touched.**
- `src/runtime.zig` — add counters
- `src/zir_integration_tests.zig` — new microbench test
- `~/projects/lang-benches/k-nucleotide/` — automated RSS check
- (New) `src/test_reductions/persistent_map_tail_loop.zap` — minimal reproducer

**Concrete changes.**

1. Add per-thread counters in `runtime.zig`:
   ```zig
   pub var arc_retains_total: u64 = 0;
   pub var arc_releases_total: u64 = 0;
   pub var arc_consumes_total: u64 = 0;       // updated when consume_share fires
   pub var arc_return_elisions_total: u64 = 0; // updated when ret-source elision fires
   ```
   Increment in `ArcRuntime.retainAny`, `ArcRuntime.releaseAny`,
   and the new consume/return paths.

2. Add a `dumpArcStats(writer)` function that prints all counters
   plus per-pool high-water marks. Per-pool high-water-mark needs
   a small change to `ArcPool(T)`: track maximum live count.

3. Honor an environment variable `ZAP_ARC_STATS=1` in the runtime's
   `atexit` handler to dump counters.

4. Add a tail-recursive `Map.put` microbench under
   `src/test_reductions/persistent_map_tail_loop.zap`:
   ```
   pub struct Probe {
     pub fn loop(m :: %{i64 => i64}, i :: i64, n :: i64) -> %{i64 => i64} {
       if i >= n { m }
       else {
         next = Map.put(m, i, i)
         Probe.loop(next, i + (1 :: i64), n)
       }
     }

     pub fn main() -> u8 {
       seed = %{-1 :: i64 => 0 :: i64}
       cleared = Map.delete(seed, -1 :: i64)
       result = Probe.loop(cleared, 0 :: i64, 100000 :: i64)
       Kernel.inspect(Map.get(result, 50000 :: i64, -1 :: i64))
       0
     }
   }
   ```

5. Add a zir-test that runs the microbench and asserts:
   - Output is `50000`
   - With `ZAP_ARC_STATS=1`, before phase 6 lands: per-pool
     high-water-mark is `O(N)`; after phase 6: bounded (under 1024
     cells).

6. Add a CI wrapper script that runs k-nucleotide under
   `/usr/bin/time -l` and asserts peak RSS. Initial threshold is
   permissive (10 GiB); tightened in each phase.

**Verification gate.**
- `zig build test` — 681/681 still green.
- `zig build zir-test -Dzap-compiler-lib=...` — 100/100 now
  (one new microbench test added).
- Manual run of microbench shows the leak slope.

**Effort.** 1-2 days.

**Rollback.** Revert the single commit. Counters are additive;
nothing else changes. Microbench test would also revert cleanly.

### Phase 2 — ARC-local numbering and CFG-aware liveness

**Goal.** Implement `computeArcOwnership` as a side-table-only pass.
No IR mutations. No behavior changes.

**Files touched.**
- (New) `src/arc_liveness.zig` — the new pass module
- `src/ir.zig` — expose helpers needed by the pass (CFG access,
  ARC-local enumeration, ARC-managed type predicate)
- `src/zir_integration_tests.zig` — new tests for the pass

**Concrete changes.**

1. Pin Zap IR's actual control-flow representation. Read all of
   `src/ir.zig`'s `Instruction` enum and identify control-flow
   shapes. Document the findings in the pass module's header comment.
   Likely shapes:
   - Linear instruction lists per scope.
   - `if_value` / `case_value` / similar for branching.
   - Nested function-group blocks for clauses.
   - `ret` and `tail_call` as terminators.
   If structural (no explicit basic blocks), the pass synthesizes
   a CFG by walking the structural shape; this is well-trodden
   territory in compilers and not difficult.

2. Implement a backward dataflow:
   ```zig
   pub fn computeArcOwnership(
       allocator: Allocator,
       function: *const Function,
       type_store: *const TypeStore,
       arc_managed: fn(TypeId) bool,
   ) !ArcOwnership;
   ```

   Use bitsets indexed by ARC-local-id (assign each ARC local a
   small dense id). The set of ARC locals is typically small (< 32
   in most functions), so a `u64` bitset is sufficient for many
   functions; fall back to `std.DynamicBitSet` for larger ones.

3. Add a `dumpOwnership(writer, ownership)` debug printer that
   shows per-instruction live-after sets and the consume / return
   classifications.

4. Add zir-tests that build small specific functions, run the pass,
   and assert specific consume/return classifications. Test cases:
   - Linear: `let x = ...; f(x)` — `x` is consumed at the call.
   - Branching: `if cond { f(x) } else { g(x) }` — `x` is consumed
     in both arms; no scope-exit drop after the `if`.
   - Loop / tail recursion: the k-nucleotide pattern. `m` consumed
     at recursive call (in the `else` arm); `m` is return-source
     in the `then` arm (`if i + k > n { m }`).
   - Duplicate args: `f(x, x)` — first `x` is `.retain`, second
     `x` (last evaluated) is `.consume`.
   - Function returns local: `pub fn f(...) -> T { x = ...; x }` —
     `x` is `return_source`.
   - Function returns call: `pub fn f(...) -> T { g(x) }` — `x`
     consumed at the call; the call's return is the function's
     return (no extra elision needed since the local is gone).
   - Multi-clause function with different ownership shapes per clause.

**Verification gate.**
- All phase-1 gates plus:
- New pass tests pass (count tbd, ~10-15 cases).
- Pass produces empty `consume_share_sites` and empty
  `return_source_locals` when fed any function whose only ARC
  locals are *not* yet flagged in `isArcManagedType` — i.e. it does
  no work today, by construction.

**Effort.** 4-5 days. The hardest part is pinning Zap IR's CFG
representation; the dataflow itself is standard.

**Rollback.** The pass is dead code at this phase (no caller); the
new tests are additive. Revert the commit cleanly.

### Phase 3 — `share_value.mode` and `arc_consumed_locals`

**Goal.** Add the new IR shape with default behavior unchanged.

**Files touched.**
- `src/ir.zig` — `ShareMode` enum, `share_value.mode` field,
  default value
- `src/zir_builder.zig` — add `arc_consumed_locals` set, lower
  `.consume` shares as assign-only, suppress matching scope-exit
  release
- `src/perceus.zig` (if it exists and emits share_value) — set mode
  to `.retain` explicitly
- `src/zir_integration_tests.zig` — add tests that hand-construct
  IR with `.consume` and verify behavior

**Concrete changes.**

1. Add the `ShareMode` enum alongside the `Instruction` definitions.
2. Add `mode: ShareMode = .retain` to `share_value` payload. The
   default ensures every existing emit site is unchanged at the
   bytecode level.
3. In `zir_builder.zig` `emitShareValue` (or equivalent — exact
   function name confirmed in implementation), branch on mode:
   - `.retain`: existing path (emit assign + retain, modulo
     `arc_share_skipped`).
   - `.consume`: emit assign only, add `source` to
     `arc_consumed_locals`, increment `arc_consumes_total`.
4. In the function-epilogue drop emission, filter against
   `arc_consumed_locals` exactly the way it currently filters
   against `arc_share_skipped`.
5. Add tests that:
   - Hand-construct a function with a single `share_value(.consume)`,
     run through zir_builder, and verify the generated ZIR has no
     retain call.
   - Verify `arc_consumed_locals` contains the source local.
   - Verify the matching scope-exit release is not emitted.

**Verification gate.**
- All phase-1, phase-2 gates.
- New unit tests for `.consume` lowering pass.
- 681/681 + 100/100 still green — default `.retain` preserves all
  existing behavior.
- Microbench RSS slope unchanged from phase 1 (no consume sites are
  populated yet).

**Effort.** 2 days.

**Rollback.** Single commit. Revert removes the `mode` field
(default = `.retain` so no other code touched the enum); `arc_consumed_locals`
goes away.

### Phase 4 — Wire ownership pass to set consume modes

**Goal.** Connect `computeArcOwnership` output to the IR's
`share_value` instructions before zir_builder runs.

**Files touched.**
- `src/ir.zig` — call `computeArcOwnership` during IR finalization,
  walk `share_value` instructions, set mode based on
  `consume_share_sites`
- `src/zir_integration_tests.zig` — end-to-end tests

**Concrete changes.**

1. After monomorphization completes, before passing IR to zir_builder
   or escape_lattice:
   ```zig
   const ownership = try computeArcOwnership(allocator, function, type_store, isArcManagedType);
   defer ownership.deinit();

   for (function.instructions) |*instr, instr_id| {
       if (instr.* == .share_value) {
           if (ownership.consume_share_sites.contains(instr_id)) {
               instr.share_value.mode = .consume;
           }
       }
   }
   ```
2. Stash the `ownership` table on the function so phase 5's drop
   emission can read `return_source_locals`.

3. Add zir-tests that compile the microbench from phase 1 and
   verify counters: `arc_consumes_total > 0`, `arc_retains_total`
   reduced from baseline.

**Verification gate.**
- All phase-1 through phase-3 gates.
- Microbench shows nonzero `arc_consumes_total`.
- Microbench RSS *still* leaks (since `.map` not yet flagged), but
  for `.opaque_type` types (e.g., List in a tail-recursive
  accumulator) RSS now stays bounded.
- Test the List-tail-loop case explicitly: a similar microbench
  using `List.append` instead of `Map.put` should now show O(1)
  pool high-water-mark, not O(N).

**Effort.** 2 days.

**Rollback.** Revert the call to `computeArcOwnership` and the
write-back loop. Phase 3's IR shape stays in place but produces no
`.consume` sites.

### Phase 5 — Return-source drop elision

**Goal.** When a function returns a `local_ref(L)` where L is an Arc
local, exclude L from the function-epilogue drop list.

**Files touched.**
- `src/ir.zig` (or `src/zir_builder.zig`) — function-epilogue drop
  emission filtering
- `src/zir_integration_tests.zig` — return-elision tests

**Concrete changes.**

1. Pin the function-epilogue drop emission site. Search for the
   point where the IR or zir_builder enumerates "all Arc locals
   live at scope exit" and emits releases. Likely candidates:
   - `IrBuilder.finalizeFunction` or similar
   - `ZirDriver.emitFunctionEpilogue`
2. Filter the drop list against `ownership.return_source_locals`
   in addition to the existing filters.
3. Update the runtime counter `arc_return_elisions_total` when an
   elision fires.
4. Add tests:
   - A function that returns its Arc parameter directly:
     `pub fn id(x :: List) -> List { x }` — no release of `x` at
     epilogue.
   - A function with a branching return where one arm returns a
     local and the other returns a call's result. Each branch's
     epilogue handles its own elision correctly.
   - The k-nucleotide-shaped pattern: `if cond { m }` arm returns
     `m` directly; `else` arm tail-calls with `next_map`. Both `m`
     and `next_map` end up consumed/elided correctly.

**Verification gate.**
- All prior gates.
- Microbench return-source elision counter > 0.
- The k-nucleotide-shaped microbench (running with `.opaque_type`
  Arc — say a `List` analogue — even though Map isn't yet flagged)
  shows bounded pool growth.

**Effort.** 2 days.

**Rollback.** Single commit. Revert restores the unfiltered drop list.

### Phase 6 — Flip `.map` in `isArcManagedType` and audit

**Goal.** Make `Map(K,V)` an ARC-managed type from the IR's
perspective. With phases 4-5 in place, this should "just work."

**Files touched.**
- `src/ir.zig` — extend `isArcManagedType`
- `src/ir.zig` and `src/zir_builder.zig` — audit every existing
  `.opaque_type`-checking site to ensure `.map` is also covered or
  explicitly excluded
- `src/types.zig` — verify `.map` types have all the metadata the
  pass needs (notably: K and V types accessible)
- `src/runtime.zig` — verify `releaseFieldChildAny` covers `.map`-typed
  fields by routing through the inline-ArcHeader path

**Concrete changes.**

1. `IrBuilder.isArcManagedType` (`src/ir.zig:4537`) becomes:
   ```zig
   fn isArcManagedType(self: *const IrBuilder, type_id: hir_mod.TypeId) bool {
       const store = self.type_store orelse return false;
       const t = store.getType(type_id);
       return switch (t) {
           .opaque_type, .map => true,
           else => false,
       };
   }
   ```

2. Audit every `.opaque_type` mention across `src/ir.zig` and
   `src/zir_builder.zig`. For each, decide:
   - Should `.map` also be handled here? (Most cases: yes.)
   - Or is this code intentionally type-specific? (Few cases.)
   Update each site explicitly. **This is the high-risk audit step.**
   Expect ~15-30 sites; each gets a one-line change or a justification
   comment.

3. Verify `releaseFieldChildAny` (`src/runtime.zig:454`) correctly
   handles `.map`-typed struct fields. Since Map cells now carry
   inline `ArcHeader`, the existing `hasInlineArcHeader` path should
   fire automatically when a struct has a Map-typed field, but
   verify with a unit test: a struct with a Map field, allocated and
   dropped, should fully release the Map.

4. Add the k-nucleotide microbench test as a hard assertion: run
   the 100k tail-recursive Map.put loop, check pool high-water-mark
   stays under (say) 4096 cells.

5. Run the full lang-benches harness; capture k-nucleotide RSS and
   runtime numbers.

**Verification gate.**
- All prior gates.
- 681/681 unit + 100/100 zir-test still green.
- Microbench: `arc_consumes_total` matches `arc_releases_total`
  reasonably well (tail recursion → per-iteration consume + release
  symmetric); pool high-water-mark bounded.
- Three CLBG benchmarks byte-exact:
  - `fannkuch-redux 10` → `expected_n10.txt`
  - `spectral-norm 5500` → `expected_n5500.txt`
  - `k-nucleotide < input.fasta` → `expected.txt`
- k-nucleotide peak RSS < 500 MiB (target < 200 MiB).
- k-nucleotide runtime ≤ 1 s (target — measured, not asserted; if
  significantly worse, that's a phase-7 task).
- spectral-norm runtime within 5% of pre-flip baseline (no
  regression).

**Effort.** 3-4 days. Most of the time is the audit; the flip
itself is one line.

**Rollback.** Single commit reverting the flag. The audit changes
are pre-flip cleanup; even if the flip reverts, the audit changes
stay (they're correctness improvements regardless).

### Phase 7 — Hardening

**Goal.** Close the long-tail edge cases the previous attempt hit
(CTFE doc generation hang) and any others that surface during phase
6 testing.

**Files touched.**
- Bug fixes wherever surfaces
- `src/test_reductions/` — new reproducers for any bugs found
- `src/zir_integration_tests.zig` — regression tests

**Concrete changes.**

1. **CTFE / `zap run doc` audit.** The previous attempt hung on this
   path. Compile a minimal `Probe.zap` that exercises:
   - Macros that take Arc-typed arguments
   - CTFE evaluation of functions returning Arc values
   - Doc-generator code paths
   For each, verify ownership pass produces expected results and
   that the resulting binary terminates in bounded time. Add a
   timeout-protected doc-generation test if one doesn't exist.

2. **Closure capture audit.** A closure that captures an Arc-typed
   binding has its own ownership semantics. The closure either:
   - Borrows the captured value (caller still owns) — in which case
     the closure must `retain` on capture and `release` on closure
     drop.
   - Consumes the captured value (caller transferred) — in which
     case the closure becomes the owner.
   Pin which model Zap uses today. Audit `src/monomorphize.zig`
   closure-conversion code for capture-list emission. Likely the
   pass needs to recognize "closure captures local L" as a USE
   site for liveness purposes.

3. **Error pipe `<<-` and try-variants.** Functions that include
   error pipes have try-variant emission paths. Verify the
   ownership pass treats error-pipe `unwrap` as a normal use of
   the underlying Arc value. Add a test for `<-` over Arc returns.

4. **Recursive struct types.** `pub struct Tree { left: Tree, ...}`
   — Tree is recursively boxed. Verify Map of recursive struct keys
   or values releases correctly through `releaseFieldChildAny`.

5. **Compile-time overhead measurement.** Run the full `zig build
   test` and `zig build zir-test` sweeps with timing. Compare
   pre-phase-2 to post-phase-7 wall-clock build time. Target: under
   5% increase. The pass is bitset dataflow over Arc locals only,
   so should be cheap; this is a sanity check.

6. **Diagnostics.** Add a `--show-arc-ownership` build flag (or
   equivalent) that dumps the ownership analysis output for a given
   function. Useful for future bug investigation.

**Verification gate.**
- All prior gates.
- Doc generation completes in bounded time on every existing
  `lib/*.zap` file.
- Closure-capture-of-Arc tests pass.
- Compile-time overhead < 5% on the existing test sweeps.
- All three CLBG benchmarks still byte-exact.

**Effort.** 3-5 days, depending on how many edge-case bugs surface.

**Rollback.** Each fix is independently revertible; the phase's
infrastructure additions (diagnostics flag, regression tests) stay.

---

## 4. Verification matrix

A consolidated table of "what must be true after each phase":

| Phase | 681 unit | 99 zir | New tests | Microbench RSS | k-nucleotide RSS | k-nucleotide runtime | byte-exact (3 benches) | doc gen |
|-------|---------:|-------:|----------:|---------------:|-----------------:|---------------------:|------------------------|---------|
| 1     | green | 100 (added 1) | new microbench passes byte-exact | unchanged baseline | unchanged | unchanged | yes | yes |
| 2     | green | 100..115 | new pass tests pass | unchanged | unchanged | unchanged | yes | yes |
| 3     | green | 116..120 | `.consume` IR tests pass | unchanged | unchanged | unchanged | yes | yes |
| 4     | green | 121..125 | List tail-loop bounded | List slope flat | unchanged (Map still leaks) | unchanged | yes | yes |
| 5     | green | 126..132 | return-elision tests pass | List bounded | unchanged | unchanged | yes | yes |
| 6     | green | 133..135 | Map tail-loop bounded | **Map slope flat** | **< 500 MiB** | **≤ 1 s (target)** | yes | yes |
| 7     | green | 136..140 | edge-case regressions | bounded | bounded | tuned | yes | **hardened** |

Phase 6 is the milestone for the project's primary goal; phase 7 is
hardening so this stays correct under expansion.

---

## 5. Risk register

| Risk | Likelihood | Impact | Mitigation |
|------|-----------:|-------:|------------|
| CFG synthesis from structural IR is harder than expected | Medium | High (blocks phase 2) | Start phase 2 with a survey commit that *only* documents Zap IR's CFG shape and identifies gaps. If gaps are large, scope phase 2 to do basic-block-local liveness first and CFG-wide later. The k-nucleotide pattern is single-block per arm so even basic-block-local gets us most of the way. |
| Audit phase 6 surfaces an `.opaque_type` site that *needs* type-specific handling | Medium | Medium | Each site gets explicit handling. If type-specific behavior is needed, encode it via a dispatch (e.g., a switch on the runtime type tag) rather than letting the unaudited code path silently misbehave. |
| Closure capture interacts badly with consume — captured local's last use is at closure-creation time, but the closure may be invoked later | Medium | Medium | Phase 7 explicitly audits this. The conservative behavior is: closure captures are USE sites for liveness, but never CONSUME sites — captured values get retained at capture and released at closure drop. Measure overhead; if real, optimize separately. |
| Last-use analysis miscompiles a control-flow shape we didn't anticipate (silent miscompile, double-free or use-after-free) | Low-medium | Critical | (a) Soundness assertions in debug builds — see §2.3. (b) Microbench tests and CLBG benchmarks under the new pass run with `-Doptimize=Debug` first. (c) If a miscompile lands, it surfaces as either a segfault or an output mismatch in the byte-exact diff — neither is silent. |
| Compile-time overhead is too large (e.g., 30% slower) | Low | Medium | Bitset dataflow is O(arc_locals × cfg_blocks). Profile with `zig build test --release-fast`. If hot, optimize with sparse maps or per-function caching. |
| `Map.put`'s internal `release` of the old root spine *plus* the IR's new `release` of the local creates a double-release | Low | High | The Map runtime substrate documentation explicitly says `Map.put` consumes its first arg internally. With consume-mode, the IR also doesn't emit a release. Net: zero releases, which is correct. With *retain* mode, the IR emits a release on the source local, and `Map.put` emits its own release on the same value (transferred via the call). That's a double-release. **Action:** verify Map.put's internal release semantics in phase 6. If it consumes, the only path to correctness is consume-mode at every call site. The flag flip in phase 6 is therefore *coupled* to phase 4's consume infrastructure. Don't flip without consume working. |
| RSS doesn't drop to projected 50-200 MiB after phase 6; ends up at, say, 500 MiB | Medium | Medium (not blocking, just disappointing) | Pool high-water-mark = working-set max. If working set is genuinely 500 MiB (~2M live cells × 50 bytes × overhead) that's correct and the projection was optimistic. Phase 7 considers (optional) phase-8 runtime work: transient builder, CHAMP, or arena-per-statement. |
| The previous failing attempt's hang on `zap run doc` returns | Medium | High | Phase 7 dedicated to CTFE / doc-gen. Tested at every gate from phase 6 onward. If it hangs at phase 6, fix before declaring phase 6 complete. |

---

## 6. Concrete file-level change list

A consolidated cross-reference. Each file's changes are scoped per
phase.

| File | Phase 1 | Phase 2 | Phase 3 | Phase 4 | Phase 5 | Phase 6 | Phase 7 |
|------|---------|---------|---------|---------|---------|---------|---------|
| `src/runtime.zig` | counters + per-pool high-water | — | — | — | — | verify `releaseFieldChildAny` covers `.map` | — |
| `src/ir.zig` | — | expose CFG/ARC enumeration | `ShareMode` enum, mode field | call ownership pass after monomorphization, write back consume modes | drop list filter against return_source | flip `isArcManagedType`, audit all `.opaque_type` sites | edge cases |
| `src/zir_builder.zig` | — | — | lower `.consume` (no retain), populate `arc_consumed_locals`, suppress matching release | — | drop list filter | audit `.opaque_type` sites | diagnostics flag |
| `src/perceus.zig` | — | possibly extend if existing pass overlaps | set mode `.retain` explicitly at any emit site | — | — | — | — |
| `src/types.zig` | — | — | — | — | — | verify `.map` metadata exposes K/V | — |
| `src/escape_lattice.zig` | — | — | — | — | — | review interaction with ownership pass | — |
| `src/monomorphize.zig` | — | — | — | — | — | — | closure-capture audit |
| (new) `src/arc_liveness.zig` | — | created | — | — | — | — | extend with edge cases |
| (new) `src/test_reductions/persistent_map_tail_loop.zap` | created | — | — | — | — | — | — |
| `src/zir_integration_tests.zig` | +1 microbench test | +10-15 pass tests | +5 share-mode tests | +5 consume tests | +7 return-elision tests | +Map microbench, +RSS assertion | +closure / CTFE / error-pipe |
| `~/projects/lang-benches/k-nucleotide/` | RSS check script | — | — | — | — | re-run, capture timing | — |

The Zig fork (`~/projects/zig`) does **not** need any changes for
this work. Consume semantics are pure absence of retain/release; no
new ZIR opcodes required.

---

## 7. What is explicitly out of scope

- **Reuse analysis** (Lean 4 / Perceus phase-2). Optional optimization
  on top of consume/return elision; not needed for the RSS gap.
- **Borrow inference** (Morphic-style). Bigger type-system commitment
  than this plan; revisit after phase 7 if k-nucleotide isn't
  competitive.
- **CHAMP / canonical-layout HAMT** in the runtime. Possibly worth a
  phase 8 if RSS doesn't hit the 50-200 MiB target after phase 6.
- **Transient / mutable-builder Map**. Same — phase-8 candidate.
- **`MMap` mutable-map primitive**. Explicitly forbidden by `CLAUDE.md`'s
  no-workarounds rule. Persistent Map with correct Perceus-style
  ownership is the production design.
- **Concurrent / atomic ARC**. Zap is single-threaded today. The
  existing `ArcHeader` already uses atomics ("just in case"); this
  plan doesn't change that.
- **GC / cycle collection**. Persistent immutable Maps cannot form
  cycles by construction. No cycle collector needed.

---

## 8. Open questions to resolve during implementation

These are not blockers — they get answered in flight by reading the
relevant code:

1. **What is Zap IR's actual control-flow representation?** Pinned
   in phase 2. Affects CFG synthesis cost.
2. **Does `src/perceus.zig` already do partial last-use analysis?**
   Pinned in phase 2. If it does, extend rather than duplicate.
3. **How does `escape_lattice` interact with consume-mode?** Pinned
   in phase 4. Most likely orthogonal — consume runs before, escape
   runs after, and escape elides retains we didn't already elide.
4. **`Map.put`'s internal release semantics** — does it consume the
   first arg? Pinned by reading `src/runtime.zig:3025-3700` in
   phase 6 prep. The substrate's design intent suggests yes; verify.
5. **Duplicate-arg evaluation order** in `zir_builder` — is it
   left-to-right? Pinned by reading the call-emission code in
   phase 2. If not strictly left-to-right, the consume-site
   selection adapts.
6. **Will the projected 50-200 MiB RSS hold?** Pinned in phase 6
   measurements. If not, decide on phase-8 runtime work.

Each is resolved by code-reading, not research. None blocks the
plan; all become part of the relevant phase's survey commit.

---

## 9. Effort and timeline

A single competent compiler engineer, working focused, lands phases
1-7 in **17-27 engineer-days**:

| Phase | Effort (days) |
|-------|--------------:|
| 1. Instrumentation & microbench | 1-2 |
| 2. ARC liveness pass | 4-5 |
| 3. share_value mode + arc_consumed_locals | 2 |
| 4. Wire ownership pass | 2 |
| 5. Return-source elision | 2 |
| 6. Flag flip + audit | 3-4 |
| 7. Hardening (CTFE, edges, compile-time) | 3-5 |
| **Total** | **17-24** |

Add 20-30% buffer for the discovered surface area (phase 7 in
particular). Realistic delivery for the first stable landing of
phases 1-6: **3-4 weeks of one engineer's focused time**, with
phase 7 stretching the project to 5-6 weeks for full hardening.

The previous reverted attempt failed to converge in ~3 hours of
agent time because it tried to do everything at once. The phased
plan above explicitly trades agent-friendliness for human-driven
implementation: each phase is small enough that a code review in
under an hour catches problems, the tests gate each phase, and the
work compounds rather than thrashes.

---

## 10. Final landing criteria

This plan is complete when:

1. `git log` shows seven (or more, if a phase needed sub-commits)
   commits implementing phases 1-7, each with passing tests.
2. `zig build test --summary all` reports `681/681 tests passed`.
3. `zig build zir-test --summary all -Dzap-compiler-lib=...`
   reports `~140/140 tests passed` (current 99 + ~40 added).
4. `cd ~/projects/lang-benches/k-nucleotide && diff <(./zap-out/bin/k_nucleotide < input.fasta) expected.txt`
   reports no diff.
5. `/usr/bin/time -l ./zap-out/bin/k_nucleotide < input.fasta > /dev/null`
   reports peak RSS < 500 MiB (target < 200 MiB).
6. fannkuch-redux and spectral-norm byte-exact + within 5% of
   their pre-flip runtimes.
7. `zap run doc` over the full stdlib completes in bounded time
   (no hang).
8. `docs/k-nucleotide-rss-gap-research-brief.md` and
   `docs/k-nucleotide-rss-gap-implementation-plan.md` get a
   "completed" note appended pointing at the relevant commits.

The persistent-Map perf path is then fundamentally correct, and any
future Zap code that uses Map in a tail-recursive accumulator
pattern will work without leaking. The pass is generic, so List,
String, MArrayI64/F64, Range, and DynClosure also benefit from
consume / return-source elision, removing retain/release ping-pong
across the language's standard idioms.

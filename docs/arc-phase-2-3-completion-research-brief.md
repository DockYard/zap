# Zap ARC IR-Source-of-Truth: Phase 2/3 Completion Research Brief

> **Audience.** A deep-research AI agent with zero prior context on Zap, the
> Zap fork of the Zig compiler, ARC (atomic reference counting), or the
> ongoing refactor of Zap's compiler ARC-emission architecture. Read
> top-to-bottom — the technical detail in §10+ only makes sense after
> §1–§9.
>
> **Goal.** Produce a concrete, file-and-line-grained implementation plan
> for completing Phase 2 and Phase 3 of the ARC IR-source-of-truth
> refactor. The schema and architectural foundations are already in place
> (see §8); the remaining work is mechanical migration plus careful
> validation. The plan must specify exact code changes for each remaining
> task and address the design questions in §13.
>
> **Prior briefs.**
> - `docs/arc-indirect-storage-research-brief.md` — the original
>   research brief that motivated the recursive-struct boxing ABI.
>   Background only; the work it described has shipped.
> - `docs/arc-emission-architecture-research-brief.md` — the foundational
>   brief for the IR-source-of-truth refactor. Read this first to
>   understand the broader architecture; this brief assumes its
>   terminology.

---

## Table of contents

1. [What is Zap?](#1-what-is-zap)
2. [Project layout & toolchain](#2-project-layout--toolchain)
3. [Compilation pipeline](#3-compilation-pipeline)
4. [The Zig fork and the C-ABI boundary](#4-the-zig-fork-and-the-c-abi-boundary)
5. [The ARC runtime](#5-the-arc-runtime)
6. [The IR-level ARC pipeline](#6-the-ir-level-arc-pipeline)
7. [The IR-source-of-truth refactor: architectural invariant](#7-the-ir-source-of-truth-refactor-architectural-invariant)
8. [What has shipped: prior progress](#8-what-has-shipped-prior-progress)
9. [The InsertionPoint synthetic-encoding discovery](#9-the-insertionpoint-synthetic-encoding-discovery)
10. [Phase 2/3 remaining work](#10-phase-23-remaining-work)
11. [The Phase 3 synthetic LocalId problem](#11-the-phase-3-synthetic-localid-problem)
12. [Concrete implementation tasks](#12-concrete-implementation-tasks)
13. [Design questions](#13-design-questions)
14. [Investigation hooks — file & line index](#14-investigation-hooks--file--line-index)
15. [Validation strategy](#15-validation-strategy)
16. [Design constraints](#16-design-constraints)
17. [Research questions](#17-research-questions)
18. [Appendix A — V10 audit catalogue (current state)](#18-appendix-a--v10-audit-catalogue-current-state)
19. [Appendix B — commit history of the refactor](#19-appendix-b--commit-history-of-the-refactor)

---

## 1. What is Zap?

Zap is a general-purpose functional programming language that compiles to
native binaries. The surface ergonomics borrow heavily from Elixir
(immutable values, pattern matching, multi-clause function dispatch with
guards, pipe operator, macros over an AST), but the runtime is native:
there is no VM, no interpreter, and no tracing GC. Zap source compiles
through Zig's intermediate representation (ZIR) into LLVM, and the
produced binary is statically-linked machine code.

**Project tagline.** "Elixir's developer experience without the runtime
overhead."

**Core design rules** (from `~/projects/zap/CLAUDE.md`):

* **Features are implemented in Zap code**, not hardcoded into the
  compiler. The compiler is a general-purpose tool that doesn't know
  about specific Zap structs (`IO`, `String`, `Map`, the ARC runtime).
  Standard library functions, macros, the test framework, and DSLs all
  live in `lib/*.zap`.
* **The compiler only handles language primitives**: parsing, the type
  system, ZIR emission, and a tiny set of runtime primitives that
  cannot be expressed in Zap (stdout, raw allocation, OS argv, the
  ARC machinery).
* **No workarounds or hacks.** Every solution must be the correct,
  production-grade, long-term fix. If the proper fix requires changes
  to the Zig fork, that's the fix. If it requires re-architecting an
  IR pass, that's the fix. Cost and time are not concerns —
  correctness and quality are.

**Surface syntax** — minimal example:

```zap
pub struct Greeter {
  pub fn hello(name :: String) -> String {
    "Hello, " <> name <> "!"
  }

  pub fn main(_args :: [String]) -> String {
    Greeter.hello("World") |> IO.puts()
  }
}
```

**Recursive struct + multi-clause dispatch** — the shape that motivated
the original ARC work and the running example for this brief:

```zap
pub struct Tree {
  left  :: Tree | nil
  right :: Tree | nil
}

pub struct Binarytrees {
  pub fn make(0 :: i64) -> Tree {
    %Tree{left: nil, right: nil}
  }

  pub fn make(d :: i64) -> Tree {
    %Tree{left: Binarytrees.make(d - 1), right: Binarytrees.make(d - 1)}
  }

  pub fn check(nil) -> i64 {
    0 :: i64
  }

  pub fn check(t :: Tree) -> i64 {
    1 :: i64 + Binarytrees.check(t.left) + Binarytrees.check(t.right)
  }
}
```

---

## 2. Project layout & toolchain

Three coordinated repositories on the local filesystem.

```
~/projects/zap/        — the Zap compiler & language itself
~/projects/zig/        — the Zap fork of Zig 0.16.0
                          (branch: zap-zir-library-0.16)
~/projects/lang-benches/ — the cross-language benchmark harness
                            (uses hyperfine; reports vs C/Rust/
                             Zig/Go/OCaml/Elixir)
```

### `~/projects/zap` — directory layout (parts relevant to this brief)

```
src/                                  — compiler source
  parse.zig                           — lexer + parser → AST
  ast.zig, ast_data.zig               — AST data types
  collector.zig                       — scope graph / decl collection
  hir.zig                             — High-level IR
  desugar.zig                         — desugaring rules
  types.zig                           — TypeStore + TypeChecker
  ir.zig                              — Mid-level IR; IrBuilder; .retain/
                                         .release/.reset/.reuse_alloc
                                         instruction definitions
  zir_builder.zig                     — IR → ZIR lowering (calls into
                                         the fork); the ZirDriver state
                                         machine; canonical
                                         .retain/.release/.reset handlers
                                         plus the still-to-be-deleted
                                         emitAnalysisArcOps,
                                         emitDropSpecializationsForCurrentInstr,
                                         emitPerceusResetForCase helpers
  zir_backend.zig                     — drives the fork's compile pipeline
  runtime.zig                         — Zap runtime: ARC, atom table,
                                         IO, List, Map, Vector, Tuple
  arc_liveness.zig                    — ARC live-set; arc_managed_locals;
                                         InstructionId numbering
  arc_ownership.zig                   — share_value mode classifier;
                                         .local_get → {.borrow_value |
                                         .copy_value | .share_value}
                                         rewrite; .copy_value paired with
                                         explicit .retain { kind:
                                         .persistent } IR (Phase 1 Class A)
  arc_drop_insertion.zig              — scope-exit .release IR insertion;
                                         optional_dispatch arm-end payload
                                         release synthesis (Phase 1
                                         follow-up); StreamRebuilder
                                         (which arc_materialize will
                                         eventually mirror)
  arc_param_convention.zig            — borrowed → owned promotion for
                                         self-recursive callees
  arc_optimizer.zig                   — redundant retain/release
                                         elimination; ALSO populates
                                         actx.arc_ops with retain/release
                                         records that emitAnalysisArcOps
                                         will eventually be replaced for
  arc_verifier.zig                    — invariant checks V1-V11; V10
                                         static audit; V11 ownership-class
                                         consistency; V8 forward retain→
                                         release reachability; V9 backward
                                         release→retain
  arc_materialize.zig                 — Phase 2 materialization scaffold
                                         (handles top-level arc_ops and
                                         drop_specializations; nested-
                                         stream cases bounds-check-deferred)
  escape_lattice.zig                  — AnalysisContext; ArcOperation;
                                         DropSpecialization; ReusePair;
                                         ResetOp; ReuseAllocOp;
                                         InsertionPoint; new StreamStep
                                         and ChildSlot
  generalized_escape.zig              — escape analysis worklist
  region_solver.zig                   — region inference
  interprocedural.zig                 — call-graph + alias analysis
  perceus.zig                         — Perceus reuse analysis;
                                         DeconstructionSite (now with
                                         .path); ConstructionSite (path
                                         field present but not yet
                                         populated); reuse_pairs with
                                         synthetic LocalIds for reset
                                         tokens (the Phase 3 blocker)
  ctfe.zig                            — comptime function evaluator
  compiler.zig                        — top-level pipeline driver;
                                         runArcDropInsertion;
                                         materializeAnalysisArcOps call
                                         site
  main.zig                            — CLI entry point

lib/                                  — Zap stdlib, all in Zap source

docs/                                 — design notes & briefs
  arc-indirect-storage-research-brief.md   — original recursive-struct
                                              brief
  arc-emission-architecture-research-brief.md — foundational refactor brief
  arc-phase-2-3-completion-research-brief.md — THIS DOCUMENT

zig-out/bin/zap                       — built compiler binary
build.zig, build.zig.zon              — build script (uses libzap_compiler.a)
```

### `~/projects/zig` (fork)

```
src/zir_builder.zig                   — Zap-facing ZIR builder API
                                         (Zap's additions on top of
                                         upstream Zig)
src/zir_api.zig                       — C-ABI exports consumed by Zap
                                         via extern "c" fn declarations
build.zig                             — `zig build lib` → libzap_compiler.a
```

The fork's branch is `zap-zir-library-0.16`. Build with:

```sh
cd ~/projects/zig
/path/to/zig build lib \
  --search-prefix /path/to/zig-bootstrap/out/aarch64-macos-none-baseline \
  -Dstatic-llvm \
  -Doptimize=ReleaseSafe \
  -Dtarget=aarch64-macos-none \
  -Dcpu=baseline \
  -Dversion-string=0.16.0
```

Then rebuild Zap pointing at the new fork artifact:

```sh
cd ~/projects/zap
zig build \
  -Dzap-compiler-lib=$HOME/projects/zig/zig-out/lib/libzap_compiler.a \
  -Dllvm-lib-path=/path/to/zig-bootstrap/out/aarch64-macos-none-baseline/lib
```

### Toolchain

* **Host Zig**: 0.16.0. The fork builds against this.
* **macOS / aarch64** (Apple Silicon). Some details are AArch64-specific
  but the underlying design generalizes.
* **8 MB thread stack ceiling** on macOS. Solutions that work only by
  raising this ceiling on Linux are not acceptable.

### Running the test suite

```sh
cd ~/projects/zap
zig build test               # Zig-side unit tests (compiler internals)
./zig-out/bin/zap test       # Zap-side test suite
```

Important: there is a separate `zig build zir-test` target that runs
end-to-end ZIR generation tests. **Do not run that target** during
research — it is extremely slow and the user runs it manually when
needed. The brief uses `zig build test` exclusively for validation.

### Baseline validation

The current baseline state, validated at every checkpoint of this
session's work:

- `zig build test` → 985/985 tests pass
- All 6 CLBG benchmarks (`~/projects/lang-benches/{nbody,mandelbrot,
  binarytrees,fannkuch-redux,spectral-norm,k-nucleotide}`) compile via
  `~/projects/zap/zig-out/bin/zap build` and produce output
  byte-identical to the C reference binary (`./{bench}-c $N`).
- `binarytrees` N=21: RSS 203 MB, wall time ~6s, output correct.
  (Pre-refactor: 12 GB RSS, OOM-killed at ~45s.)

Any change you make MUST preserve these properties. Validate after each
non-trivial change.

---

## 3. Compilation pipeline

```
.zap source files
  ↓ parse.zig
AST (ast.zig)
  ↓ collector.zig          (scope graph, decl resolution)
  ↓ desugar.zig            (desugaring rules)
  ↓ macro expansion
HIR (hir.zig)
  ↓ types.zig              (type checking; populates TypeStore)
  ↓ generic monomorphisation
  ↓ ir.zig                 (lower HIR → IR; tail-call rewrite;
                              loopification flag; emitArcRetainOnAggregate
                              Extract for ARC-managed extractions)
IR (mid-level IR)
  ↓ analysis passes:
    arc_param_convention   (borrowed → owned promotion)
    arc_ownership          (.local_get → {.borrow_value | .copy_value |
                              .share_value} ; .copy_value paired with
                              explicit .retain { kind: .persistent } IR)
    arc_liveness           (live-before-ret analysis;
                              arc_managed_locals seed walk)
    perceus                (deconstruction-site discovery; ReusePair
                              generation; arc_ops/drop_specializations
                              records; uses synthetic LocalIds for reset
                              tokens — the Phase 3 blocker)
    arc_optimizer          (consumes arc_ops; redundant retain/release
                              elimination)
    arc_drop_insertion     (insert .release IR for ARC-managed locals
                              at every ret-equivalent terminator;
                              optional_dispatch arm-end .release for
                              .owned-scrutinee params)
    arc_materialize        (Phase 2 scaffold — currently handles top-
                              level arc_ops / drop_specializations only;
                              nested-stream cases bounds-check-deferred)
    arc_verifier           (V1-V7 in pre-drop verifier;
                              V11 in pre-drop verifier (fail-mode);
                              V8 + V9 in post-drop verifier
                              (opt-in warning via ZAP_DEBUG_V8/V9);
                              V10 static audit (fail-mode at zig build test))
  ↓ zir_builder.zig        (lower IR → ZIR by calling into the fork's
                              C-ABI builder; canonical .retain/.release/
                              .reset handlers, plus still-extant
                              emitAnalysisArcOps,
                              emitDropSpecializationsForCurrentInstr,
                              emitPerceusResetForCase helpers handling
                              the records arc_materialize hasn't
                              materialized yet)
ZIR
  ↓ libzap_compiler.a      (Sema + AIR + LLVM codegen)
LLVM IR  →  machine code  →  native binary
```

---

## 4. The Zig fork and the C-ABI boundary

Zap doesn't fork the entire Zig compiler — it adds a thin "ZIR builder"
library on top of upstream Zig 0.16.0 and exports a stable C-ABI for Zap
to call into.

The C-ABI (`~/projects/zig/src/zir_api.zig`) has ~200 `pub export fn
zir_builder_emit_*` functions. Each returns either a `Zir.Inst.Ref`
(encoded as `u32`) or `0xFFFFFFFF` on failure. Zap-side bindings live
at the top of `~/projects/zap/src/zir_builder.zig` as `extern "c" fn
zir_builder_emit_*` declarations.

For this brief's scope, the fork itself does not change. All work is in
the Zap-side compiler.

---

## 5. The ARC runtime

`src/runtime.zig` (~11k lines) hosts every runtime primitive the
compiled Zap program calls into.

### `ArcHeader`

Every ARC-wrapped allocation has a refcount header in front of the
user-visible value:

```zig
pub const ArcHeader = extern struct {
    ref_count: std.atomic.Value(u32),
    pub fn retain(self: *ArcHeader) void { … }
    pub fn release(self: *ArcHeader) bool { … return true on zero-transition; }
    pub fn count(self: *const ArcHeader) u32 { … }
};
```

Two header strategies: **wrapped** (separate `Arc(T).Inner` allocation,
user holds `*T` pointing to the value, header recovered via
`@fieldParentPtr`) and **inline** (`T` itself contains the header as
first field — used for `List(T)`, `Map(K, V)`, `Vector(T)`, `Tuple`).

### Public ARC entry points

The runtime exposes these helpers (called by ZIR-lowered `.retain` /
`.release` / `.reset` / `.reuse_alloc` IR instructions plus the
still-extant analysis-record-consuming helpers):

- `ArcRuntime.retainAny(ptr)` — increment refcount; lowering of
  `.retain { kind: .normal, value }` IR.
- `ArcRuntime.retainAnyPersistent(ptr)` — long-lived owner retain
  (Map workload share-event tracking); lowering of `.retain { kind:
  .persistent, value }`.
- `ArcRuntime.retainAnyOpt(ptr)` — through `?*const T`; LEGACY — no
  longer emitted from ZIR (Phase 1 Class A removed all sites);
  preserved in runtime for use by `releaseChildrenAny`.
- `ArcRuntime.releaseAny(allocator, ptr)` — release; deep-walk children
  on zero-transition. Lowering of `.release { kind: .release, value }`.
- `ArcRuntime.freeAny(allocator, ptr)` — shallow free (refcount must be
  1); lowering of `.release { kind: .free, value }`.
- `ArcRuntime.resetAny(allocator, ptr)` — Perceus reset; if rc=1 yield
  reusable storage, else release and yield BOX/null. Lowering of
  `.reset { dest, source }`.
- `ArcRuntime.reuseAllocByType(allocator, T, token, ...)` — Perceus
  reuse: if token non-null, reuse storage; else fresh alloc. Lowering
  of `.reuse_alloc { dest, token, constructor_tag, ... }`.

### `arc_retains_total` / `arc_releases_total` counters

When `ZAP_ARC_STATS=1` is set on a compiled Zap binary, an `atexit`
hook prints global counters to stderr:

```
[zap-arc-stats] retains_total=N releases_total=N consumes_total=N return_elisions_total=N
[zap-arc-stats] dense_map_mut_calls_total=N dense_map_rc1_fast_path_total=N dense_map_unchecked_total=N
[zap-arc-stats] list_mut_calls_total=N list_rc1_fast_path_total=N list_unchecked_total=N
[zap-arc-stats] pool=Arc(T) live=N high_water=N
```

For a leak-free program, `retains_total ≈ releases_total` (delta = 0
modulo a small noise term from atexit ordering). Any persistent
positive delta is leaked retains.

---

## 6. The IR-level ARC pipeline

### Canonical ARC IR instructions (`src/ir.zig`)

```zig
pub const RetainKind = enum { normal, persistent };
pub const Retain = struct {
    value: LocalId,
    kind: RetainKind = .normal,
};

pub const ReleaseKind = enum { release, free };
pub const Release = struct {
    value: LocalId,
    kind: ReleaseKind = .release,
};

pub const Reset = struct {
    dest: LocalId,   // reuse token destination
    source: LocalId, // value being deconstructed
};

pub const ReuseAlloc = struct {
    dest: LocalId,         // newly allocated value
    token: ?LocalId,       // reuse token from Reset (null = fresh alloc)
    constructor_tag: u32,
    dest_type: ZigType = .any,
};
```

The other ARC-touching IR opcodes (`.share_value`, `.copy_value`,
`.move_value`, `.borrow_value`) are *aliases* — pure dataflow under
Phase 1 Class A. They no longer carry implicit retain semantics; any
retain at those sites is emitted as an explicit paired `.retain` IR
instruction.

### Analysis pipeline (lives in `src/analysis_pipeline.zig`)

The order from `runAnalysisPipeline` (paraphrased):

1. **Generalized escape analysis** (`generalized_escape.zig`)
2. **Interprocedural analysis** (`interprocedural.zig`)
3. **Region solver** (`region_solver.zig`)
4. **Lambda sets** (`lambda_sets.zig`)
5. **Perceus** (`perceus.zig`) — discovers deconstruction sites, finds
   compatible constructions, generates `actx.reuse_pairs`,
   `actx.arc_ops` (with `.reset` and `.reuse_alloc` kinds), and
   `actx.drop_specializations`.
6. **ARC optimizer** (`arc_optimizer.zig`) — consumes `actx.arc_ops`,
   optimizes (removes redundant retain/release pairs), reappends final
   set to `actx.arc_ops`.

### Pre-drop verifier + drop insertion + post-drop verifier

In `src/compiler.zig`'s `runArcDropInsertion`:

```zig
// Pre-drop V1-V7 + V11 verifier
arc_verifier.verifyWithFixpoint(...) // compiler.zig:2268

// Insert .release IR at scope-exit terminators
arc_drop_insertion.insertScopeExitDrops(...) // compiler.zig:2290

// Phase 2 materialization (NEW)
arc_materialize.materializeAnalysisArcOps(...) // compiler.zig:~2090
                                                 // — only invoked in
                                                 // compileStructByStruct
                                                 // path, not the
                                                 // whole-program path

// Post-drop V1-V7 + V11 verifier again
arc_verifier.verifyWithFixpoint(...) // compiler.zig:2307

// Post-drop V8 + V9 (opt-in via ZAP_DEBUG_V8 / ZAP_DEBUG_V9)
arc_verifier.verifyPostDropInsertion(...) // compiler.zig:2313
```

After this pipeline, ZIR emission consumes the IR plus any remaining
analysis-context records (whatever arc_materialize didn't materialize).

---

## 7. The IR-source-of-truth refactor: architectural invariant

> **Every retain and release operation that the compiled Zap program
> executes at runtime corresponds 1:1 to a `.retain` or `.release` IR
> instruction in its lowered IR.**

The ZIR backend's role is purely mechanical: it lowers `.retain` and
`.release` IR instructions into runtime calls. Higher-level IR ops are
pure dataflow.

**Why this matters**: when ARC operations live below the IR level — emitted
by the ZIR backend in response to ad-hoc compiler logic that the
IR-level passes don't see — the IR-level passes are blind to them.
They cannot verify retain/release balance, eliminate redundant pairs,
insert matching scope-exit releases, or reason about ownership.

The original binary-trees benchmark leak (12 GB RSS) was the canary
symptom: `.field_get` of an indirect-recursive struct field emitted
`retainAnyOpt` at ZIR level without a corresponding `.retain` IR,
`arc_drop_insertion` never saw the local, and no matching release
fired. ~610M tree nodes leaked.

### V10 static audit

`src/arc_verifier.zig` carries a static audit test (V10) that scans
`src/zir_builder.zig` source via `@embedFile` for forbidden ARC
runtime-call patterns (`retainAny`, `retainAnyPersistent`,
`retainAnyOpt`, `retainChildrenAny`, `releaseAny`,
`releaseChildrenAny`, `freeAny`, `resetAny`, `reuseAllocByType`).
Outside the canonical `.retain`/`.release`/`.reset` IR-instruction
handlers, every match is a violation.

The current `v10_expected_total = 14`. The catalogue (in
`src/arc_verifier.zig` doc-comments) enumerates which sites are
canonical (3) and which are remaining violations (11). The remaining
work in this brief is to reduce the violation count to zero.

---

## 8. What has shipped: prior progress

The following commits represent the work done so far. Each is on the
`main` branch as of this brief's writing:

1. **`122bf73`** — `fix(arc): close binarytrees-class leak via explicit
   IR-level retain on field_get`. Field-get of indirect-storage
   recursive types now emits `.retain` IR via `local_hir_types`
   population in IR builder. Call-arg `share_value` falls back on
   local hir type. Binarytrees RSS 12 GB → 305 M leaked retains.

2. **`14b3ac0`** — `fix(arc): close binarytrees leak completely via
   optional_dispatch arm-end release`. `arc_drop_insertion` synthesizes
   end-of-struct-arm `.release { value: payload_local }` for
   `.owned`-convention optional_dispatch shapes. RSS 12 GB → 203 MB,
   pool live=0.

3. **`3b80e2e`** — `feat(arc_verifier): V10 — static audit for
   ZIR-direct ARC emissions`. Phase 0 static audit pinning the
   invariant.

4. **`ce5e715`** — `fix(arc): close binarytrees-class leak in
   emitMapBindings`. Same fix shape as binarytrees for map bindings.

5. **`dbd080a`** — `feat(arc): Phase 1 Class A items 1+2 — explicit
   .retain IR for .copy_value and .share_value`. `RetainKind` enum
   added with `.normal` and `.persistent`. Canonical `.retain` handler
   dispatches on kind. `.copy_value` and `.share_value` lowerings
   become pure dataflow.

6. **`380707f`** — `feat(arc_verifier): V11 — every ARC-IR-affecting
   local must be ARC-managed`. Phase 0 dynamic invariant in fail-mode
   that catches the binarytrees-class seeding gap at compile time.

7. **`57fc546`** — `feat(arc_verifier): V8 — forward retain→release
   reachability dataflow`. Opt-in warning via `ZAP_DEBUG_V8`.

8. **`648ed69`** — `feat(arc_verifier): V9 — backward release→retain
   reachability check`. Opt-in warning via `ZAP_DEBUG_V9`.

9. **`abc21a2`** — `fix(arc): close binarytrees-class leaks in
   extract_map decision-tree paths`. Same fix shape for case/dispatch
   tree extract_map.

10. **`4532428`** — `feat(arc): Phase 2 — analysis-record materialization
    pass scaffold`. New file `src/arc_materialize.zig`. `ReleaseKind`
    enum added. `Release` struct gains `kind` field. The `.release`
    ZIR handler dispatches on kind. `materializeAnalysisArcOps` walks
    `actx.arc_ops` and `actx.drop_specializations` and inserts `.retain`
    / `.release` IR for top-level positions. Wired into
    `compiler.zig:~2090` in `compileStructByStruct` flow.

11. **`ca96b4b`** — `fix(arc_materialize): bounds-check synthetic
    insertion indices`. Empirically: perceus's `instr_index` synthetic
    encoding produces values that, when matched against a top-level
    block's `instructions.len`, would silently mis-place insertions.
    Added bounds check (`instr_index > block_len → defer`) so out-of-
    range records fall through to the existing ZIR helpers cleanly.

12. **`83002dc`** — `feat(arc): InsertionPoint StreamStep schema
    groundwork`. Added `StreamStep`, `ChildSlot`, and `path: []const
    StreamStep` field to `InsertionPoint`. Same field on
    `DeconstructionSite` and `ConstructionSite`. Default `&.{}`
    preserves backward compatibility.

13. **`3e6055e`** — `feat(perceus): path-based nested-stream addressing
    for DeconstructionSite`. `perceus.scanNestedInstructions` now
    threads a path-builder through its recursion. Each descent pushes
    a `StreamStep`; leaf-level `DeconstructionSite` construction
    snapshots and `allocator.dupe`s the current path. Per-function
    cleanup frees each site's path. Recursive-in-recursive descent is
    also fixed (the previous implementation only descended one level).
    The synthetic `parent_index +| (idx) +| 1` encoding for
    `instr_index` is gone from `scanNestedInstructions` — replaced by
    `path` + index-within-innermost-stream.

### Validated empirical state after this work

- `zig build test` → 985/985 tests pass
- All 6 CLBG benchmarks output byte-identical to C
- `binarytrees` N=21: 203 MB RSS, 6s wall, correct output
- V10 audit currently expects 14 sites (3 canonical + 11 remaining
  violations). All 14 documented in the `v10_expected_total` catalogue
  comment in `src/arc_verifier.zig`.

---

## 9. The InsertionPoint synthetic-encoding discovery

This section is the load-bearing finding from this session's
investigation. Understand it before designing the rest of the work.

### The encoding (history)

Perceus's `scanInstructionForConstructions` (still present in
`src/perceus.zig:669`) and the now-replaced `scanNestedInstructions`
historically used saturating-add formulas to encode nested-stream
navigation into a single `u32` `instr_index`:

```zig
// Original scanNestedInstructions (pre commit 3e6055e):
.case_block => |cb| {
    for (cb.arms) |arm| {
        for (arm.body_instrs, 0..) |nested, idx| {
            try self.checkInstructionForDeconstruction(
                &nested, function_id, block_label,
                parent_index +| @as(u32, @intCast(idx)) +| 1,  // synthetic!
            );
        }
    }
    ...
}

// scanInstructionForConstructions (still uses this — see §10):
.case_block => |cb| {
    for (cb.arms, 0..) |arm, arm_idx| {
        for (arm.body_instrs, 0..) |nested, idx| {
            try self.scanInstructionForConstructions(
                nested, decon, function_id, block_label,
                instr_index +| @as(u32, @intCast(arm_idx * 100 + idx)) +| 1,
                results,
            );
        }
    }
    ...
}
```

`+|` is Zig's saturating-add operator (saturates to `u32`'s max value
on overflow). The encoding scheme assigns numeric ranges to nested
arm/case positions:

- `arm_idx * 100 + idx + 1` for case_block arm bodies
- `idx + 1` for if_expr.then_instrs
- `idx + 100` for if_expr.else_instrs (with formula variations)
- `idx + 900` for default arms

These synthetic numbers are stored in `InsertionPoint.instr_index`,
which originally was intended to identify positions for the
ZIR-time emit helpers (`emitAnalysisArcOps`,
`emitDropSpecializationsForCurrentInstr`,
`emitPerceusResetForCase`).

### The discovery: position-matching never fired for nested records

`zir_builder.zig` updates its `current_instr_index` tracker only in
the **top-level block walk**:

```zig
// zir_builder.zig:3415-3431
for (func.body) |block| {
    self.current_block_label = block.label;
    self.current_block_instructions = block.instructions;
    for (block.instructions, 0..) |instr, instr_idx| {
        self.current_instr_index = @intCast(instr_idx);  // ← only updated here
        try self.emitAnalysisArcOps(true);
        self.emitInstruction(instr) catch ...;
        try self.emitAnalysisArcOps(false);
    }
}
```

`current_instr_index` is set only at line 3420, with the top-level
`instr_idx`. During nested-stream emission (recursing into `case_block`
arms, `if_expr` then/else, etc.), `current_instr_index` retains the
stale top-level value.

The emit helpers check:

```zig
// zir_builder.zig:3895-3898 (emitAnalysisArcOps):
if (op.insertion_point.function != self.current_function_id) continue;
if (op.insertion_point.block != self.current_block_label) continue;
if (op.insertion_point.instr_index != self.current_instr_index) continue;
if ((op.insertion_point.position == .before) != before) continue;
```

For records with **synthetic-encoded** `instr_index` values (like 631
for arm 6 instr 30), this check NEVER succeeds because
`current_instr_index` is the top-level block instruction index (small
values like 0-20 for typical functions).

**Consequence**: every Perceus reuse and drop-specialization
optimization that targeted a nested-stream position has been silently
dropped on the floor. The optimization opportunity was never captured
in production.

### The exception: source-local matching

`emitPerceusResetForCase` uses a DIFFERENT matching mechanism — it
matches `pair.reset.source == cb.dest` (a LocalId equality check):

```zig
// zir_builder.zig:3974-3993 (emitPerceusResetForCase):
fn emitPerceusResetForCase(self: *ZirDriver, cb: ir.CaseBlock) !void {
    if (self.analysis_context) |actx| {
        for (actx.reuse_pairs.items) |pair| {
            if (pair.reset.source == cb.dest) {
                // emit resetAny(allocator, source) ← FIRES even for
                // nested case_blocks because cb.dest is a real LocalId
                ...
            }
        }
    }
}
```

This fires for nested case_blocks because `cb.dest` is a real LocalId
independent of position. Perceus's nested-stream deconstruction-site
discovery DOES contribute usefully through this path.

**The lesson**: any refactor of the position-matching path must
preserve the local-id-matching path (or replicate its semantics
through the new path-based machinery). Removing the synthetic
encoding without preserving the local-id-matching path breaks the
`nested pattern matching finds inner reuse` test in
`src/perceus.zig:2358`.

### The schema now in place

Commit `83002dc` added `StreamStep`/`ChildSlot`/`path` to
`InsertionPoint`, `DeconstructionSite`, and `ConstructionSite`.
Commit `3e6055e` populated `DeconstructionSite.path` correctly for
nested cases. The remaining work (this brief's focus) is to thread
paths through the rest of the data flow and use them at the
consumer side.

---

## 10. Phase 2/3 remaining work

There are five concrete remaining tasks. They're listed here in a
recommended order; each is testable independently.

### Task 10.1 — Thread paths through ConstructionSite

**Files**: `src/perceus.zig`

`scanInstructionForConstructions` (~line 669) still uses the synthetic
encoding for nested-stream descent. Its sibling function
`scanInstructionsForConstructions` (~line 648, plural-s)
calls it with synthetic indices encoded via formulas like
`branch_offset *| 1000 +| @as(u32, @intCast(idx))`.

The migration shape is the same as `scanNestedInstructions` in commit
`3e6055e`:

1. Add a `path_builder: *std.ArrayListUnmanaged(lattice.StreamStep)`
   parameter to `scanInstructionForConstructions` and
   `scanInstructionsForConstructions`.
2. At each recursive descent into a nested stream, push the
   appropriate `StreamStep` (with the parent's index within its
   parent stream, and the right `ChildSlot` variant).
3. At the leaf where `ConstructionSite` is appended to `results`, set
   `path = try self.allocator.dupe(lattice.StreamStep, path_builder.items)`.
4. Pop the step after the loop completes (`_ = path_builder.pop();`).
5. Free each ConstructionSite's path when the slice is consumed
   (`generateReusePair` either copies the path into `InsertionPoint`
   or frees it).

The control-flow shapes scanInstructionForConstructions descends into:

- `guard_block`
- `if_expr` (then_instrs, else_instrs)
- `case_block` (pre_instrs, arms[i].body_instrs, default_instrs)
- `switch_literal` (cases[i].body_instrs, default_instrs)
- `switch_return` (cases[i].body_instrs, default_instrs)
- `union_switch_return` (cases[i].body_instrs)

Each has a corresponding `ChildSlot` variant already defined in
`escape_lattice.zig` (commit `83002dc`).

### Task 10.2 — Populate InsertionPoint.path in generateReusePair and generateDropSpecialization

**Files**: `src/perceus.zig`

After Task 10.1, both `DeconstructionSite` and `ConstructionSite`
carry valid paths. `generateReusePair` (~line 756) and
`generateDropSpecialization` (~line 829) construct `InsertionPoint`
records for `actx.arc_ops` and `actx.drop_specializations`. Each
construction site needs to copy the relevant path:

```zig
// Example for the .reset arc_op in generateReusePair (current code at
// perceus.zig:717-722):
try self.arc_ops.append(self.allocator, .{
    .kind = .reset,
    .value = decon.scrutinee,
    .insertion_point = .{
        .function = function_id,
        .block = decon.block,
        .path = try self.allocator.dupe(lattice.StreamStep, decon.path),  // ← new
        .instr_index = decon.instr_index,
        .position = .before,
    },
    .reason = .perceus_reuse,
});
```

Each cloned path needs a matching free in `AnalysisContext.deinit`
(or wherever `arc_ops` / `drop_specializations` records are cleaned up).
Check `src/escape_lattice.zig` `AnalysisContext.deinit` and
`src/perceus.zig` `AnalysisResult.deinit`.

### Task 10.3 — Extend arc_materialize.zig to walk paths

**Files**: `src/arc_materialize.zig`

Currently, `materializeArcOps` and `materializeDropSpecializations`
look up the top-level block by label, then bounds-check
`instr_index` against `block.instructions.len`. If `instr_index >
block_len`, the record is deferred to the ZIR helpers (`continue` /
`ops_remaining.append`).

After Task 10.2, records carry an explicit `path` describing the
nested-stream navigation. The materialization pass should:

1. Find the top-level block by label.
2. Walk the path: for each `StreamStep`, descend into the parent
   instruction's nested stream by `ChildSlot` variant.
3. The final stream identified by the path is where `instr_index`
   indexes.
4. Insert the new IR instruction at the target position.

The walk is the inverse of `scanNestedInstructions`'s recursion.
Mirror the structure of `arc_drop_insertion.zig`'s `rebuildChildren`
function (`~line 1322`), which already handles every nested-stream
shape.

**Important**: the inserted IR must update the instruction's nested
stream slice. The current `applyInsertionsToBlock` function in
`arc_materialize.zig` allocates a fresh slice and assigns
`block_ptr.instructions = new_slice`. For nested streams, the same
pattern applies: build a new nested slice and assign via the parent
instruction's field. Because `Instruction` is a tagged union, you'll
need to `@constCast` the parent instruction and overwrite the
specific field (e.g., `ie.then_instrs = new_slice` for if_expr).

### Task 10.4 — Phase 3: real-local allocation for reuse_pairs

**Files**: `src/arc_materialize.zig`, `src/perceus.zig`,
`src/escape_lattice.zig`

This addresses the synthetic-LocalId blocker described in §11.

`perceus.zig:766` allocates a synthetic LocalId for the reset token:

```zig
const token_local: ir.LocalId = 10000 + decon.match_site_id;
```

This works at ZIR-emit time because `emitPerceusResetForCase` stores
the actual ZIR ref in `local_refs[token_local]`. But IR-level passes
(arc_liveness, arc_drop_insertion, arc_verifier) would index
`function.local_ownership[token_local]` and access out-of-bounds
memory if exposed to these synthetic IDs.

**The fix**: real-local allocation in `arc_materialize`:

1. When materializing a `ReusePair`, increment `function.local_count`
   and reallocate `function.local_ownership` (and
   `function.local_hir_types` if needed) to accommodate the new
   real local.
2. Set `local_ownership[new_local] = .owned` (the reset token is a
   fresh ARC owner).
3. Emit `.reset { dest: new_real_local, source: pair.reset.source }`
   IR at the deconstruction site.
4. Emit `.reuse_alloc { dest: pair.reuse.dest, token: new_real_local,
   constructor_tag, dest_type }` IR at the construction site.
5. Update `local_hir_types[new_local]` to a sentinel type that
   downstream passes understand (the reset token is a tag, not a
   typed pointer — confirm with the runtime's `resetAny` return type).

The detailed implementation plan was produced by an earlier
gap-analysis agent and recommended this as the agent's
"Option A — real-local allocation in materialization pass." See §11
for the alternatives evaluated and why Option A is the recommended
choice.

### Task 10.5 — Delete the now-unused ZIR helpers

**Files**: `src/zir_builder.zig`, `src/arc_verifier.zig`

Once Tasks 10.1-10.4 are complete and `arc_materialize` covers all
records produced by perceus and arc_optimizer, the following ZIR
helpers become dead code and should be deleted:

- `emitAnalysisArcOps` at `zir_builder.zig:~3892`
- `emitDropSpecializationsForCurrentInstr` at `zir_builder.zig:~3934`
- `emitPerceusResetForCase` at `zir_builder.zig:~3974`

Plus the call sites in `emitFunction` and `emitCaseBlock` that
invoke them.

Plus the four `reuseAllocByType` emissions in `.struct_init` and
`.union_init` ZIR handlers (`zir_builder.zig:5336, 5573, 5917, 6804`).
These are direct `reuseAllocByType` calls that should be replaced
by lowering of `.reuse_alloc` IR instructions emitted by
`arc_materialize` (Task 10.4).

After the deletions, V10's expected_total drops from 14 to 4 (the
canonical handlers only). Update the catalogue comment in
`src/arc_verifier.zig`.

---

## 11. The Phase 3 synthetic LocalId problem

Phase 3 (Task 10.4) requires resolving the synthetic LocalId issue
in `perceus.zig:766`. An earlier gap-analysis agent evaluated three
options:

### Option A — Real-local allocation in materialization pass (RECOMMENDED)

Allocate real LocalIds in `arc_materialize.zig` when materializing
each ReusePair. Increment `function.local_count`, reallocate
`function.local_ownership` to accommodate, and use the real LocalId
in the inserted `.reset` and `.reuse_alloc` IR.

**Pros**: Clean separation — analyses remain read-only, materialization
is a dedicated IR-mutating pass. Local_ownership grows in a
controlled, observable way.

**Cons**: Reallocating `function.local_ownership` post-IR-construction
breaks the (implicit) IR builder's assumption that locals grow
monotonically only during the build. Need to verify all consumers of
`local_ownership` are robust to post-build growth.

**Effort**: ~150-200 lines in `arc_materialize.zig`, plus ~50-80 lines
of test coverage. The agent estimated 3 days.

### Option B — Real-local allocation in perceus itself

Mutate `ir.Function` during analysis. `perceus.zig:766` would
allocate via `function.local_count` directly.

**Pros**: Removes the synthetic-ID hack at the source.

**Cons**: Breaks the analysis-pipeline contract that analyses are
read-only. Makes the pass harder to debug, replay, and parallelize.
Couples perceus to IR mutation.

### Option C — Synthetic-ID handling layer

Keep the synthetic IDs but add a bounds-check helper for
`local_ownership` accesses that treats out-of-bounds reads as
`.owned`.

**Pros**: Minimal blast radius.

**Cons**: Leaves the hack in place. Risks future bugs from missed
audits. Soft V11 invariant (synthetic IDs are "understood" as
special). Violates the "no workarounds, no hacks" project rule.

### Recommendation: Option A

Option A is the only choice consistent with the project's "no
workarounds, no hacks" rule. The complexity is bounded (one place
allocates locals post-build; all current consumers of
`local_ownership` are already array-indexed and will handle the
new entries naturally).

The agent's full Phase 3 implementation plan recommended this
approach. Implementation steps:

1. In `arc_materialize.zig`, add a helper:
   ```zig
   fn allocateRealLocal(
       allocator: Allocator,
       function: *ir.Function,
       ownership_class: ir.OwnershipClass,
       hir_type: ?hir_mod.TypeId,
   ) !ir.LocalId {
       const new_local = function.local_count;
       function.local_count += 1;
       // Grow local_ownership
       const new_ownership = try allocator.alloc(ir.OwnershipClass,
                                                  function.local_count);
       @memcpy(new_ownership[0..function.local_ownership.len],
               function.local_ownership);
       new_ownership[new_local] = ownership_class;
       allocator.free(function.local_ownership);
       function.local_ownership = new_ownership;
       // Optionally also update local_hir_types
       ...
       return new_local;
   }
   ```

2. In `materializeReusePairs` (new function), iterate `actx.reuse_pairs`,
   allocate real locals for reset tokens, emit `.reset` and
   `.reuse_alloc` IR at the appropriate positions (walking the path
   from Task 10.3).

3. Clear `actx.reuse_pairs` after materialization (or set a flag so
   `emitPerceusResetForCase` becomes a no-op).

4. Validate: `binarytrees` N=21 RSS unchanged (the optimization was
   firing partially via the source-local matching; now it should fire
   on every nested case too).

---

## 12. Concrete implementation tasks

Here is a step-by-step plan with files, line numbers, and
checkpoints. Each step should leave the test suite green.

### Step 12.1 — Thread paths through ConstructionSite scanner (Task 10.1)

**Goal**: Same shape as commit `3e6055e` but for the construction-site
discovery path.

**Files modified**: `src/perceus.zig`

**Changes**:
1. Add `path_builder: *std.ArrayListUnmanaged(lattice.StreamStep)`
   parameter to:
   - `scanInstructionsForConstructions` (plural, line 648)
   - `scanInstructionForConstructions` (singular, line 669)
2. At each callsite that currently uses the synthetic encoding
   (lines 663, 697, 702, 705, 710, 714, 718, 724, 728, 734, 738,
   744), replace the synthetic computation with a `path_builder`
   push + recursive call + pop.
3. At the leaf where `results.append(...ConstructionSite...)` happens
   (line 683), add `.path = try self.allocator.dupe(lattice.StreamStep,
   path_builder.items)`.
4. Update `findCompatibleConstructionsForMatch` (line 530) to
   instantiate the `path_builder` and pass it to scanners.
5. Add path-cleanup to the appropriate deinit / per-function cleanup
   paths (mirror commit `3e6055e`'s cleanup).

**Validation**: `zig build test` 985/985 + all 6 benchmarks
byte-identical to C.

### Step 12.2 — Populate InsertionPoint.path in generators (Task 10.2)

**Goal**: Pass paths from DeconstructionSite/ConstructionSite into
the InsertionPoints in `actx.arc_ops` and `actx.drop_specializations`.

**Files modified**: `src/perceus.zig`, possibly `src/escape_lattice.zig`
(for cleanup).

**Changes**:
1. In `generateReusePair` (line 756), copy `decon.path` and
   `con.path` into the InsertionPoints for the reset and reuse_alloc
   arc_ops. The same applies for `ReusePair.reset.insertion_point`
   (if one is added; currently `ResetOp` has no insertion_point —
   investigate whether to add one or rely on the reset op being
   placed by other means).
2. In `generateDropSpecialization` (line 829), copy `decon.path` into
   the `DropSpecialization.insertion_point.path`.
3. Update `AnalysisContext.deinit` in `src/escape_lattice.zig` to
   free each `InsertionPoint.path` slice in the cleanup loop. Same
   for `drop_specializations` and `reuse_pairs`.
4. Update `PerceusAnalyzer.deinit` similarly if it owns the
   intermediate state.

**Validation**: 985/985 + benchmarks. Optionally instrument
arc_materialize to log how many records now have non-empty `path`
fields — this should be the count of records that previously
fell through to the ZIR helpers.

### Step 12.3 — Extend arc_materialize to walk paths (Task 10.3)

**Goal**: Materialize records whose paths are non-empty by walking
into nested IR streams.

**Files modified**: `src/arc_materialize.zig`

**Changes**:
1. Replace the bounds-check guard (`if (op.insertion_point.instr_index
   > block_len) { ops_remaining.append; continue; }`) with a path
   walk:
   ```zig
   const target_stream = try walkPath(function, op.insertion_point);
   const gop = try schedule_by_stream.getOrPut(allocator, target_stream);
   ...
   ```
2. Implement `walkPath` that, given an InsertionPoint, returns a
   pointer or reference to the target instruction stream
   (`[]const ir.Instruction`). Use the path's StreamSteps to
   descend through `case_block.arms[i].body_instrs`, etc.
3. Implement insertion into a nested stream: allocate a new slice
   with the inserted instruction, then `@constCast` the parent
   instruction and overwrite the nested stream field (mirroring
   `arc_drop_insertion.zig`'s `rebuildChildren` slice replacement
   pattern).
4. Schedule key: `(top_level_block_index, path_signature, instr_index)`.
   Insertions at the same key are batched and applied in sort order
   to avoid index shifting.

**Validation**: 985/985 + benchmarks. After this step, the
materialization pass should materialize records that previously fell
through to `emitAnalysisArcOps` / `emitDropSpecializationsForCurrentInstr`.
Instrument with debug-counter env vars to verify the materialization
rate is now close to 100% for arc_ops and drop_specializations.

### Step 12.4 — Real-local allocation for reset tokens (Task 10.4)

**Goal**: Materialize `actx.reuse_pairs` into `.reset` and
`.reuse_alloc` IR. Allocate real LocalIds in arc_materialize.

**Files modified**: `src/arc_materialize.zig`, `src/perceus.zig`

**Changes**:
1. In `arc_materialize.zig`, add `materializeReusePairs` function:
   ```zig
   pub fn materializeReusePairs(
       allocator: std.mem.Allocator,
       function: *ir.Function,
       analysis_context: *escape_lattice.AnalysisContext,
   ) !void {
       for (analysis_context.reuse_pairs.items) |pair| {
           if (pair.reset.source's owner is not this function) continue;
           const real_token_local = try allocateRealLocal(allocator, function,
                                                          .owned, null);
           // Insert .reset { dest: real_token_local, source: pair.reset.source }
           // at the deconstruction site (via path walking)
           // Insert .reuse_alloc { dest: pair.reuse.dest, token: real_token_local,
           //   constructor_tag: pair.reuse.constructor_tag, dest_type: ... }
           // at the construction site (via path walking)
       }
       analysis_context.reuse_pairs.clearRetainingCapacity();
   }
   ```

2. Wire into `materializeAnalysisArcOps`:
   ```zig
   pub fn materializeAnalysisArcOps(...) !void {
       try materializeArcOps(allocator, function, analysis_context);
       try materializeDropSpecializations(allocator, function, analysis_context);
       try materializeReusePairs(allocator, function, analysis_context);  // ← new
   }
   ```

3. Verify the runtime semantics of `resetAny` and `reuseAllocByType`
   are correctly captured by the IR-level `.reset` and `.reuse_alloc`
   opcodes — confirm that the existing ZIR handlers at
   `zir_builder.zig:6779` and `6791` do the right thing when fed
   IR-level reset/reuse instructions.

**Validation**: 985/985 + benchmarks. Use `ZAP_ARC_STATS=1` to
verify reset/reuse counters fire correctly (the binarytrees benchmark
might show different stats — reuse might fire more now that nested
cases work).

### Step 12.5 — Delete the helpers and audit Class C (Task 10.5)

**Goal**: Once all records are materialized, delete the now-dead
helpers and the four `reuseAllocByType` emissions.

**Files modified**: `src/zir_builder.zig`, `src/arc_verifier.zig`

**Changes**:
1. Delete `emitAnalysisArcOps` (zir_builder.zig:3892), its callers in
   `emitFunction` (3421, 3429).
2. Delete `emitDropSpecializationsForCurrentInstr` (zir_builder.zig:3934)
   and its 8 callers (lines 7473, 7524, 7655, 7744, 7806, 7851, 8127,
   and one more).
3. Delete `emitPerceusResetForCase` (zir_builder.zig:3974) and its 2
   callers (lines 7406, 7615).
4. Audit the `reuseAllocByType` emissions at lines 5336, 5573, 5917,
   6804 — these are in `.struct_init`/`.union_init` lowering and
   consume `actx.reuse_pairs` data. If `materializeReusePairs`
   correctly inserts `.reuse_alloc` IR at the construction sites,
   the lowering should consume the IR directly and these direct
   `reuseAllocByType` emissions become dead. Delete them.
5. Update V10's `v10_expected_total` in `arc_verifier.zig` to 4 (the
   four canonical handler emissions: retainAny, retainAnyPersistent,
   releaseAny, freeAny, resetAny — five, not four, depending on how
   the kind dispatch is counted). Update the catalogue comment.

**Validation**: 985/985 + benchmarks. V10 audit passes with the new
expected total.

---

## 13. Design questions

### Q1. Should `ResetOp.insertion_point` exist?

Currently `ResetOp` (`src/escape_lattice.zig:784`) has no
`insertion_point` field. The reset is placed via the matching
deconstruction site's position. But for materialization, we need an
explicit insertion point for the `.reset` IR.

Should `ResetOp` gain an `insertion_point` field, OR should
materializeReusePairs use the DeconstructionSite (via `match_site` ID
lookup) to find the position?

### Q2. Path lifetime

Paths are `[]const StreamStep` — heap slices. Currently each
DeconstructionSite owns its path, freed at per-function cleanup.

For InsertionPoint records held by `actx.arc_ops` and
`actx.drop_specializations`, paths need a similar lifetime. Should
each InsertionPoint own its slice (allocated/freed independently),
or should an arena allocator be introduced for path storage?

### Q3. arc_materialize wiring in the non-compileStructByStruct path

Currently `materializeAnalysisArcOps` is called only in
`compileStructByStruct` (compiler.zig:~2090). The
`runIrLowering` path (compiler.zig:997) calls runArcDropInsertion
without invoking arc_materialize. Should arc_materialize also be
invoked in `runIrLowering`? When would `AnalysisContext` be
available there?

### Q4. Test fixture sensitivity

`src/perceus.zig` has tests asserting reuse_pair counts and
DeconstructionSite paths (line 2358 specifically). When paths
are populated for nested cases, the tests may need updates if
they assert on InsertionPoint structure directly.

Should the tests be updated to assert paths explicitly, or kept
asserting only on counts/IDs?

### Q5. ConstructionSite scanner: nested-in-nested

Commit `3e6055e` for DeconstructionSite added recursive-in-recursive
descent (e.g., `case_block` inside `if_expr.then_instrs`'s nested
streams). The current `scanInstructionForConstructions` already
handles deeper nesting via its recursive structure. Verify the path
threading correctly handles arbitrary nesting depth.

### Q6. Empty-path optimization

For the common case where path is empty (top-level position), the
materialization can short-circuit to the existing top-level fast
path. Worth optimizing now or premature?

### Q7. What happens to perceus.zig's `findNestedInstruction`?

`findNestedInstruction` (perceus.zig:607) is the local-id-matching
fallback used by `findCompatibleConstructionsForMatch`. After paths
are populated, does this fallback still serve a purpose?

### Q8. Memory ownership of reallocated local_ownership

After arc_materialize grows `function.local_ownership`, what frees
the old slice? Is the IR builder's allocator an arena
(automatic cleanup) or does it need explicit `allocator.free()`?
The Phase 3 implementation must handle this correctly to avoid
leaks.

### Q9. Coordination with arc_drop_insertion

`arc_drop_insertion` runs BEFORE `arc_materialize` in the pipeline.
If arc_materialize allocates new locals for reset tokens,
arc_drop_insertion's already-computed `arc_managed_locals` won't
include them. Verify this doesn't cause subsequent passes to miss
the new locals.

Alternative: run arc_materialize BEFORE arc_drop_insertion. This
might require restructuring (drop_insertion needs the IR shape to
be stable for its InstructionId numbering).

---

## 14. Investigation hooks — file & line index

All paths relative to `~/projects/zap/`.

### IR ARC instruction definitions (src/ir.zig)

| concept | line |
|---|---|
| `RetainKind` enum | ~1086 |
| `Retain` struct | ~1108 |
| `ReleaseKind` enum | ~1126 |
| `Release` struct | ~1150 |
| `Reset` struct | ~1170 |
| `ReuseAlloc` struct | ~1182 |
| `emitArcRetainOnAggregateExtract` helper | ~6133 |
| `.field_get` arm in IR builder | ~7197 |

### AnalysisContext (src/escape_lattice.zig)

| concept | line |
|---|---|
| `InsertionPoint` struct (with `path` field) | 76 (post commit 83002dc) |
| `StreamStep` struct | ~39 |
| `ChildSlot` union | ~57 |
| `ArcOperation` struct | ~792 |
| `ArcOpKind` enum | ~798 |
| `ResetOp` struct | ~838 |
| `ReuseAllocOp` struct | ~847 |
| `ReusePair` struct | ~862 |
| `DropSpecialization` struct | ~901 |
| `FieldDrop` struct | ~883 |
| `AnalysisContext` struct | ~1003 |

### Perceus (src/perceus.zig)

| concept | line |
|---|---|
| `DeconstructionSite` (with `path` field) | 52 |
| `ConstructionSite` (with `path` field) | 76 |
| `PerceusAnalyzer.deinit` (with path-cleanup) | 193 |
| `analyzeFunction` (clears decon sites + paths) | ~228 |
| `scanBlockForDeconstructionSites` | 288 |
| `checkInstructionForDeconstruction` (path-aware) | 307 |
| `scanNestedInstructions` (path-aware, commit 3e6055e) | 403 |
| `findCompatibleConstructionsForMatch` | 530 |
| `findNestedInstruction` | 607 |
| `scanInstructionsForConstructions` (plural, NEEDS path threading) | 648 |
| `scanInstructionForConstructions` (singular, NEEDS path threading) | 669 |
| `generateReusePair` (NEEDS path copy) | 756 |
| `synthetic LocalId allocation` | 766 (`10000 + match_site_id`) |
| `generateDropSpecialization` (NEEDS path copy) | ~829 |
| `nested pattern matching finds inner reuse` test | 2358 |

### Materialization (src/arc_materialize.zig)

| concept | line |
|---|---|
| `materializeAnalysisArcOps` entry | ~78 |
| `materializeArcOps` | ~84 |
| `materializeDropSpecializations` | ~151 |
| `ScheduledInsertion` struct | ~238 |
| `findBlockByLabel` helper | ~243 |
| `applyInsertionsToBlock` (handles top-level) | ~258 |
| `scheduledInsertionLessThan` ordering | ~302 |
| Bounds check (commit ca96b4b) for synthetic indices | various |

### Pipeline wiring (src/compiler.zig)

| concept | line |
|---|---|
| `runIrLowering` (per-struct, calls runArcDropInsertion) | 934 |
| `runArcDropInsertion` | 2282 |
| `runArcDropInsertion` call (per-struct path) | 997 |
| `runArcDropInsertion` call (compileStructByStruct path) | 2076 |
| `arc_materialize.materializeAnalysisArcOps` call (only in compileStructByStruct) | ~2090 |
| Pre-drop verifier (`arc_verifier.verifyWithFixpoint`) | 2268 |
| Post-drop verifier (`arc_verifier.verifyWithFixpoint`) | 2307 |
| Post-drop V8/V9 (`arc_verifier.verifyPostDropInsertion`) | 2313 |

### ZIR helpers to be deleted (src/zir_builder.zig)

| concept | line |
|---|---|
| `emitAnalysisArcOps` (Phase 2 target) | 3892 |
| `emitDropSpecializationsForCurrentInstr` (Phase 2 target) | 3934 |
| `emitPerceusResetForCase` (Phase 2 target) | 3974 |
| Canonical `.retain` handler (kept) | 6711 |
| Canonical `.release` handler (kept) | 6727 |
| Canonical `.reset` handler (kept) | 6779 |
| Canonical `.reuse_alloc` handler (kept) | 6791 (TBD — verify) |
| `current_instr_index` top-level set | 3420 |
| `.struct_init` reuseAllocByType (Phase 3 Class C target) | 5573 |
| `.union_init` reuseAllocByType (Phase 3 Class C target) | 5917 |
| Early `.struct_init` reuse path (Phase 3 Class C target) | 5336 |
| Additional reuseAllocByType (Phase 3 Class C target) | 6804 |

### Verifier (src/arc_verifier.zig)

| concept | line |
|---|---|
| `v10_expected_total` (UPDATE after deletions) | ~2790 |
| V10 catalogue comment | ~2700-2780 |
| `verifyPostDropInsertion` entry | ~3105 |
| V8 implementation | ~2840-3100 |
| V9 implementation | ~3200-3500 |
| V11 implementation | ~750-800 |

### Drop insertion (src/arc_drop_insertion.zig)

| concept | line |
|---|---|
| `insertScopeExitDrops` entry | ~1180 |
| `StreamRebuilder` (mirror for arc_materialize's path walking) | ~1199 |
| `rebuildChildren` (the canonical nested-stream descent pattern) | ~1322 |
| `optionalDispatchPayloadRelease` (Phase 1 follow-up) | ~1862 |

---

## 15. Validation strategy

### After each step

Run:
```sh
cd ~/projects/zap
zig build 2>&1 | tail -3                              # build succeeds
zig build test --summary all 2>&1 | grep "tests passed"  # 985/985
```

Plus benchmarks:
```sh
cd ~/projects/lang-benches
for bench in nbody mandelbrot binarytrees fannkuch-redux spectral-norm k-nucleotide; do
  cd ~/projects/lang-benches/$bench
  rm -rf .zap-cache zap-out
  ~/projects/zap/zig-out/bin/zap build 2>&1 > /dev/null
  binary="./zap-out/bin/$bench"
  [[ -x ./zap-out/bin/${bench//-/_} ]] && binary="./zap-out/bin/${bench//-/_}"
  case $bench in
    nbody) N=5000000 ;;
    mandelbrot) N=8000 ;;
    binarytrees) N=10 ;;
    fannkuch-redux) N=10 ;;
    spectral-norm) N=2500 ;;
    k-nucleotide) N="" ;;
  esac
  if [[ "$bench" == "k-nucleotide" ]]; then
    diff <($binary < input.fasta) <(./${bench}-c < input.fasta) > /dev/null && echo "$bench: MATCH"
  else
    diff <($binary $N) <(./${bench}-c $N) > /dev/null && echo "$bench: MATCH"
  fi
done
```

Plus binarytrees N=21 stress:
```sh
cd ~/projects/lang-benches/binarytrees
/usr/bin/time -l ./zap-out/bin/binarytrees 21 > /tmp/bt-out.txt 2>/tmp/bt-time.txt
diff <(./binarytrees-c 21) /tmp/bt-out.txt  # output match
grep "maximum resident" /tmp/bt-time.txt    # should be < 500 MB
```

### After Phase 2/3 completion

Run with `ZAP_DEBUG_V8=1 ZAP_DEBUG_V9=1` to surface warning-mode
diagnostics; investigate any new ones (V8/V9 may catch more cases
now that paths are populated and materialization is comprehensive).

Run with `ZAP_ARC_STATS=1` on each benchmark and confirm
`retains_total ≈ releases_total` (delta < 1000 modulo atexit
ordering).

### Test corpus to monitor

The 985-test corpus includes specific perceus tests that assert on
counts:
- `nested pattern matching finds inner reuse` (perceus.zig:2358)
- Other perceus tests for reuse-pair generation
- Other perceus tests for drop-specialization counts

Plus zir_integration_tests (zir-test target — DO NOT RUN; user runs
manually):
- Multiple ARC counter assertion tests using parseArcStatCounter
- Phase 5 return-elision tests

If any of these fail after a refactor step, investigate carefully —
the assertions may need updating to reflect the new path-based
structure, or there may be a real semantic regression.

---

## 16. Design constraints

Hard rules. Violations are not acceptable.

* **No workarounds or hacks.** Every solution must be the correct,
  production-grade, long-term fix. Option C from §11 is explicitly
  ruled out by this constraint.

* **Features in Zap, not in the compiler.** The compiler must remain
  a general-purpose tool. ARC primitives in `src/runtime.zig` are an
  exception because they require Zig-only constructs.

* **Tests must stay green.** 985/985 tests in `zig build test`. All 6
  CLBG benchmarks must continue to output byte-identical to C.
  Binarytrees N=21 RSS must remain bounded (~200 MB).

* **macOS thread-stack ceiling is 8 MB.** Solutions that work only on
  Linux are not acceptable.

* **Backwards-compatibility hacks are forbidden.** When refactoring,
  fully commit to the new approach. Remove old code entirely.

* **All public Zap functions need `@fndoc`.** If you add Zap-side
  functions in `lib/*.zap`, document them.

* **Don't hardcode struct names in the compiler.**

* **Cost and time are not concerns.** Correctness is.

* **Always TDD.** Failing test first when possible (paths are mostly
  refactoring, where regression tests are the primary guarantee),
  implement minimum code to pass, run `zig build test` locally.

* **Never run `zig build zir-test`.** It's slow; the user runs it
  manually. Use `zig build test` exclusively.

---

## 17. Research questions

The agent must produce, for each of these, a concrete recommendation
with file paths, line numbers, and proposed code shape.

1. **Q1 — ResetOp.insertion_point**: Does `ResetOp` gain an
   `insertion_point` field, or does materializeReusePairs derive
   the position from the matching DeconstructionSite via
   `match_site_id` lookup? (§13 Q1)

2. **Q2 — Path lifetime / arena**: Should an arena allocator be
   introduced for InsertionPoint paths, or is per-slice ownership
   sufficient? (§13 Q2)

3. **Q3 — arc_materialize wiring**: Should arc_materialize be
   invoked in the `runIrLowering` per-struct path as well as the
   `compileStructByStruct` post-merge path? Where is AnalysisContext
   available in `runIrLowering`'s flow? (§13 Q3)

4. **Q4 — Test fixture updates**: What test assertions need updating
   after path population? Specifically, does the `nested pattern
   matching finds inner reuse` test need restructuring to assert on
   path structure? (§13 Q4)

5. **Q5 — Pipeline ordering**: Should arc_materialize run BEFORE
   arc_drop_insertion or AFTER? What constraints does each ordering
   impose? Specifically, can arc_drop_insertion's InstructionId
   numbering accommodate arc_materialize inserting IR before it
   runs? (§13 Q9)

6. **Q6 — Real-local allocation contract**: When arc_materialize
   grows `function.local_count` and reallocates
   `function.local_ownership`, what other state needs updating?
   Specifically: `function.local_hir_types`, the IR builder's
   `next_local` (already finalized by this point), and any other
   per-function arrays. (§13 Q8)

7. **Q7 — `.reuse_alloc` IR opcode validation**: Verify that the
   existing `.reuse_alloc` IR opcode and its ZIR handler work
   correctly end-to-end when fed inputs from arc_materialize
   (rather than from the current ZIR-time emission paths in
   `.struct_init`/`.union_init` handlers). Are all fields populated
   correctly? Does the runtime's `reuseAllocByType` handle the
   resulting calls?

8. **Q8 — emitPerceusResetForCase replacement**: The current
   `emitPerceusResetForCase` matches `pair.reset.source == cb.dest`
   for nested case_blocks (independent of InsertionPoint position).
   When deleting this helper, ensure that `materializeReusePairs`
   captures the SAME match — i.e., for every case_block whose dest
   is the source of any ReusePair, a `.reset` IR is inserted at the
   appropriate position. Verify the equivalence.

9. **Q9 — V10 catalogue update**: After all deletions, what's the
   final V10 expected_total? Enumerate the canonical handlers that
   remain. (Note: the canonical `.retain` handler dispatches on
   kind so it emits both `"retainAny"` and `"retainAnyPersistent"`
   string literals — both count in V10's static text scan.)

10. **Q10 — Migration path verification**: Without modifying
    `function.local_ownership`'s reallocation, ALL of arc_liveness's
    cached tables (`live_before_ret`, `owned_at_ret`, `arc_managed_locals`)
    have InstructionId values keyed on the pre-materialization IR
    shape. After materialization mutates the IR (inserts
    `.retain`/`.release`/`.reset`/`.reuse_alloc` instructions), do
    those cached tables remain valid? If not, do they need to be
    invalidated or re-computed?

11. **Q11 — Iterative gap analysis at each step**: After each step
    of the implementation plan (12.1 - 12.5), the agent should run
    a gap-analysis pass to identify:
    - Any new false-positives in V8/V9 caused by the materialization
      changes.
    - Any new V11 violations caused by allocating real locals (e.g.,
      arc_managed_locals not seeded for the new locals).
    - Any test assertions that need updating to match the new IR
      shape.

12. **Q12 — Documentation update**: After Phase 2/3 completes, the
    `docs/arc-emission-architecture-research-brief.md` should be
    updated to reflect the new state (V10 violation count, the
    deleted helpers, the materialization pass as the canonical
    consumer). What other docs need updating?

---

## 18. Appendix A — V10 audit catalogue (current state)

Per `src/arc_verifier.zig`'s `v10_expected_total = 14` catalogue:

**Canonical IR-handler sites — these MUST be in the count**:
1. `.retain` IR handler, kind=.normal → `"retainAny"`
2. `.retain` IR handler, kind=.persistent → `"retainAnyPersistent"`
3. `.release` IR handler, kind=.release → `"releaseAny"`
4. `.release` IR handler, kind=.free → `"freeAny"` (added Phase 2 scaffold)
5. `.reset` IR handler → `"resetAny"`

**Phase 2 Class B violations (to be deleted in Step 12.5)**:
6. `emitAnalysisArcOps` retain branch → `"retainAny"` (zir_builder.zig:3907)
7. `emitAnalysisArcOps` release branch → `"releaseAny"` (zir_builder.zig:3922)
8. `emitDropSpecializationsForCurrentInstr` deep arm → `"releaseAny"` (zir_builder.zig:3962)
9. `emitDropSpecializationsForCurrentInstr` shallow arm → `"freeAny"` (zir_builder.zig:3963)
10. `emitPerceusResetForCase` → `"resetAny"` (zir_builder.zig:3984)

**Phase 3 Class C violations (to be deleted in Step 12.5)**:
11. Early `.struct_init` reuse path → `"reuseAllocByType"` (zir_builder.zig:5336)
12. `.struct_init` reuse-pair → `"reuseAllocByType"` (zir_builder.zig:5573)
13. `.union_init` reuse-pair → `"reuseAllocByType"` (zir_builder.zig:5917)
14. Additional `reuseAllocByType` emission (zir_builder.zig:6804)

After Phase 2/3 completion, `v10_expected_total` should drop to 5
(only the canonical handlers remain). Plus 1 for the canonical
`.reuse_alloc` handler → `"reuseAllocByType"` once it's verified to
exist (it may need to be added if currently absent).

Final target: `v10_expected_total = 6` (5 canonical + 1 reuse_alloc canonical).

---

## 19. Appendix B — commit history of the refactor

In chronological order on `main`:

```
122bf73  fix(arc): close binarytrees-class leak via explicit IR-level retain on field_get
14b3ac0  fix(arc): close binarytrees leak completely via optional_dispatch arm-end release
3b80e2e  feat(arc_verifier): V10 — static audit for ZIR-direct ARC emissions
ce5e715  fix(arc): close binarytrees-class leak in emitMapBindings
dbd080a  feat(arc): Phase 1 Class A items 1+2 — explicit .retain IR for .copy_value and .share_value
380707f  feat(arc_verifier): V11 — every ARC-IR-affecting local must be ARC-managed
57fc546  feat(arc_verifier): V8 — forward retain→release reachability dataflow
648ed69  feat(arc_verifier): V9 — backward release→retain reachability check
abc21a2  fix(arc): close binarytrees-class leaks in extract_map decision-tree paths
4532428  feat(arc): Phase 2 — analysis-record materialization pass scaffold
ca96b4b  fix(arc_materialize): bounds-check synthetic insertion indices
83002dc  feat(arc): InsertionPoint StreamStep schema groundwork
3e6055e  feat(perceus): path-based nested-stream addressing for DeconstructionSite
```

Each commit's message contains detailed background; reading them
linearly is a useful supplement to this brief.

---

## Closing note

The work to complete Phase 2/3 is **mechanical** in shape now that
the schema groundwork (commits `83002dc` and `3e6055e`) is in place.
Each remaining task mirrors patterns already established in the
codebase (commit `3e6055e` for path threading; commit `4532428` for
the materialization-pass scaffold; commit `14b3ac0` for end-of-arm
synthesized release). The novel piece is the real-local allocation
in Phase 3, evaluated and recommended as Option A in §11.

The single biggest empirical risk is that fully enabling
nested-stream materialization may surface previously-dropped
optimization opportunities — and Perceus reuse, while semantics-
preserving, may shift refcount timing in ways that exercise
previously-untested ARC code paths. The benchmark validation
(byte-identical output to C) is the primary guarantee against
correctness regressions; the V8/V9/V11 verifiers should catch
ownership-class drift; and `ZAP_ARC_STATS=1` counter checks remain
the empirical evidence that nothing is leaked at runtime.

The hand-off to a deep-research agent is: take these tasks in order,
validate at each checkpoint, and resolve gap-analysis findings as
they arise. The architectural foundations are sound; the remaining
work is iteration with a clear pattern.

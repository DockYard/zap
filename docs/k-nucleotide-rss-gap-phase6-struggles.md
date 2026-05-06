# Zap: Phase 6 struggles — research brief

> **Audience.** A deep-research AI agent with zero prior context on Zap,
> the Zap fork of the Zig compiler, the ARC memory model, the
> k-nucleotide benchmark, or the multi-week effort to fix the
> persistent-Map RSS gap. Read top-to-bottom — §1–§9 establish the
> world model and prior work; §10 enumerates the 8 Phase 6 attempts
> chronologically with what each fixed, surfaced, and reverted; §11
> describes the current still-broken state and the precise pattern
> of segfaults; §12–§14 are constraints, suspects, and questions to
> answer. The intended deliverable is a definitive root-cause
> analysis of why flipping `.map` to ARC-managed still segfaults
> after 11 substrate commits, plus a recommended fix or a
> definitive "this requires a deeper architectural redesign — here
> is the redesign" verdict.

---

## Table of contents

1. [What is Zap?](#1-what-is-zap)
2. [Project layout & toolchain](#2-project-layout--toolchain)
3. [Compilation pipeline](#3-compilation-pipeline)
4. [The Zig fork and the C-ABI boundary](#4-the-zig-fork-and-the-c-abi-boundary)
5. [Memory model — pools + ARC](#5-memory-model--pools--arc)
6. [`@native_type` and stdlib bridging](#6-native_type-and-stdlib-bridging)
7. [The Map runtime](#7-the-map-runtime)
8. [The k-nucleotide benchmark and original RSS gap](#8-the-k-nucleotide-benchmark-and-original-rss-gap)
9. [The Phase 6 plan and the IR-pass design](#9-the-phase-6-plan-and-the-ir-pass-design)
10. [The 8 Phase 6 attempts — chronological narrative](#10-the-8-phase-6-attempts--chronological-narrative)
11. [Current state and remaining segfault](#11-current-state-and-remaining-segfault)
12. [Specific suspects identified by the latest agent](#12-specific-suspects-identified-by-the-latest-agent)
13. [Constraints (non-negotiable)](#13-constraints-non-negotiable)
14. [Research questions for the next investigator](#14-research-questions-for-the-next-investigator)
15. [Appendix A — file & line index](#15-appendix-a--file--line-index)
16. [Appendix B — full Phase 6 commit list](#16-appendix-b--full-phase-6-commit-list)
17. [Appendix C — relevant code excerpts](#17-appendix-c--relevant-code-excerpts)

---

## 1. What is Zap?

Zap is a general-purpose functional programming language that compiles
to native binaries. The surface borrows from Elixir (immutable values,
pattern matching, multi-clause function dispatch with guards, the
pipe operator `|>`, macros over an AST, atom literals, persistent
data structures), but the runtime is native: no VM, no interpreter,
no tracing GC. Zap source compiles through Zig's intermediate
representation (ZIR) into LLVM, just like ordinary Zig code. The
produced binary is statically-linked machine code linking libc.

**Tagline.** "Elixir's developer experience without the runtime overhead."

**Core design rules** (from `~/projects/zap/CLAUDE.md`):

* **Features are implemented in Zap code**, not hardcoded into the
  compiler. The compiler is general-purpose. It does not know about
  `IO`, `String`, `Kernel`, `Map`, etc. as named entities — those
  live in `lib/*.zap` and dispatch through `:zig.X.method(...)` calls
  into a small set of runtime primitives.
* **No workarounds, hacks, or shortcuts.** Every fix must be the
  correct, production-grade, long-term solution regardless of cost or
  time. If a proper fix requires deep architectural changes across
  multiple files, that is the fix. If it requires changes to the Zig
  fork, those are made.
* **Code generation always lowers to ZIR via `src/zir_builder.zig`,
  which calls C-ABI helpers in the Zig fork.** There is no text
  codegen.

**Type system.** Hindley-Milner-flavored with subtyping for atoms and
union types. Concrete primitives include `i8..i64`, `u8..u64`,
`f32`/`f64`, `Bool`, `Atom`, `String`, `List`, `Map`, `Range`,
tuples, and user-defined `struct`/`enum`. Generic functions are
parameterised at the type level and monomorphised per call signature.

**Concurrency.** None yet. Single-threaded today.

---

## 2. Project layout & toolchain

Three repos cooperate:

```
~/projects/zap/                 — language, compiler, stdlib
~/projects/zig/                 — fork of Zig 0.16.0 (branch zap-zir-library-0.16)
~/projects/lang-benches/        — CLBG benchmark suite, polyglot
```

**`~/projects/zap/` layout:**

```
src/
  main.zig                      — CLI entry
  lexer.zig parser.zig          — text → AST
  collector.zig scope.zig       — name resolution
  hir.zig                       — high-level IR (typed)
  monomorphize.zig              — generic specialization
  ir.zig                        — main IR layer (~7500 lines)
  perceus.zig                   — Perceus-style ownership pass (existing,
                                  does reuse analysis, NOT last-use)
  arc_liveness.zig              — NEW (Phase 2): ARC last-use analysis
  arc_drop_insertion.zig        — NEW (Phase 6.2b): scope-exit release insertion
  escape_lattice.zig            — escape analysis
  zir_builder.zig               — IR → ZIR (~8500 lines)
  runtime.zig                   — Zig runtime primitives, ARC, HAMT, MArray
  zir_integration_tests.zig     — end-to-end integration test harness
  test_reductions/              — minimal reproducers
lib/                            — Zap stdlib
  list.zap map.zap                          (@native_type-bridged)
  marray_i64.zap marray_f64.zap             (@native_type-bridged)
  enum.zap                                  (protocol over List/Map/Range)
docs/                           — design docs and research briefs
```

**Toolchain.**

* `zig build` — compile the `zap` CLI binary (linking the fork lib).
* `zig build test` — Zig-side unit tests (724 today).
* `zig build zir-test -Dzap-compiler-lib=$HOME/projects/zig/zig-out/lib/libzap_compiler.a`
  — end-to-end integration tests (104 today).
* `./zig-out/bin/zap build <target>` — Zap user-facing CLI.

**Always rebuild the fork lib first** if changes touched `~/projects/zig/src/zir_api.zig`:

```sh
cd ~/projects/zig
zig build lib \
  --search-prefix /Users/bcardarella/zig-bootstrap-0.16.0/out/aarch64-macos-none-baseline \
  -Dstatic-llvm \
  -Doptimize=ReleaseSafe \
  -Dtarget=aarch64-macos-none \
  -Dcpu=baseline \
  -Dversion-string=0.16.0
```

Pass `-Dzap-compiler-lib=$HOME/projects/zig/zig-out/lib/libzap_compiler.a`
to every Zap-side `zig build` invocation when developing the fork.

---

## 3. Compilation pipeline

```
Zap source (.zap)
     │  src/lexer.zig + src/parser.zig
     ▼
AST (Zap-flavored)
     │  src/collector.zig + src/scope.zig + src/discovery.zig
     ▼
Resolved AST + scope graph
     │  src/hir.zig (lowering: types, generics resolved per-clause)
     ▼
HIR (typed)
     │  src/monomorphize.zig (generic specialization, closure capture)
     ▼
Specialized HIR
     │  src/ir.zig (instructions, locals, control flow)
     ▼
IR
     │  src/perceus.zig (existing — reuse-at-deconstruction analysis)
     │  src/arc_liveness.zig (NEW — last-use analysis)
     │  src/arc_drop_insertion.zig (NEW — scope-exit release insertion)
     │  src/escape_lattice.zig (escape analysis)
     ▼
IR with ARC pseudo-instructions
     │  src/zir_builder.zig (IR → ZIR via fork C-ABI)
     ▼
ZIR
     │  Zig fork (Sema, AIR, codegen, LLVM)
     ▼
Native binary
```

The fork lib `libzap_compiler.a` exposes a C-ABI surface
(`~/projects/zig/src/zir_api.zig`) that lets `zir_builder.zig` build
ZIR programmatically. The fork is otherwise stock Zig 0.16.0.

---

## 4. The Zig fork and the C-ABI boundary

The fork adds C-ABI helpers around Zig's existing ZIR opcodes. It does
NOT add new IR opcodes. Anything Zap can emit must lower to standard
Zig. Recent fork commits:

```
zir_builder: add ?T param helpers for optional dispatch
zir_builder: add single-const ptr_type emission
zir_builder: streaming per-field-body API for root struct fields
zir_builder: body-track struct_init_field_type instructions
feat: expose ZIR inline type body helpers
```

For the Map ARC work, no fork changes were required — every retain,
release, and refcount operation lowers to ordinary Zig calls into
`runtime.zig` exports.

---

## 5. Memory model — pools + ARC

**5.1 Per-type `MemoryPool`s.** Stdlib container types
(`List(T)`, `Map(K,V)`, `MArrayI64`, `MArrayF64`, `String`,
`DynClosure`) each allocate cells from a `std.heap.MemoryPool(Inner)`
specialized per type. Threadlocal. Variable-length payloads come
from `page_allocator` directly.

**5.2 Per-cell `ArcHeader`.** Every pooled cell starts with an
`ArcHeader = struct { count: u32 }`. On allocation, count = 1.

```zig
pub const ArcHeader = struct {
    count: std.atomic.Value(u32),
    pub fn init() ArcHeader { ... }
    pub fn retain(self: *ArcHeader) void { ... }
    pub fn release(self: *ArcHeader) bool { ... }
};
```

**5.3 The `ArcRuntime` namespace** (`src/runtime.zig:303-509`):

* `retainAny(ptr: anytype)` — type-erased retain; uses
  `hasInlineArcHeader` to detect "first field is ArcHeader" pattern.
* `releaseAny(allocator, ptr)` — type-erased release.
* `releaseFieldChildAny(FieldType, allocator, value)` — recursively
  releases struct fields containing Arc'd children.
* `ArcPool(T)` — per-type MemoryPool wrapper.

**5.4 `hasInlineArcHeader(T)`** at line 383 detects whether `T`'s
first field is `ArcHeader`. List, String, Map, MArrayI64, MArrayF64,
DynClosure all use this pattern.

**5.5 `IrBuilder.isArcManagedType` / `isArcManagedTypeId`**
(`src/ir.zig:4641` and `:1012`) decide whether the IR emits
retain/release for a type. **Currently flagged: `.opaque_type` ONLY.**
The Phase 6 milestone is to extend this to `.map`. (Eventually `.list`,
`.string_type`, `.marray_type` — but those types' bridge functions
already manage their own internal refcounts and don't trigger the
same pathology as Map.)

**5.6 Existing `share_value` and `release` IR instructions.**

Today the IR has ONE retain/release pair pattern: at every call site,
emit `share_value{dest, source}` (which lowers to assign + retain)
and a post-call `release{value=dest}` (which lowers to a
type-erased release). Net: zero refcount change per call (caller
retains, callee borrows, caller releases). NO scope-exit drops
existed pre-Phase-6.

---

## 6. `@native_type` and stdlib bridging

Stdlib types like `Map` are declared in Zap (`lib/map.zap`):

```zap
@native_type = "map"

pub struct Map {
  pub fn put(map :: %{K => V}, key :: K, value :: V) -> %{K => V} {
    :zig.Map.put(map, key, value)
  }
  pub fn get(map :: %{K => V}, key :: K, default :: V) -> V {
    :zig.Map.get(map, key, default)
  }
  ...
}
```

`@native_type = "map"` registers the Zap struct as the user-visible
spelling of the runtime kind `map`. The `NativeTypeKind` enum at
`src/scope.zig:468` enumerates kinds: `list, map, range, string,
marray_i64, marray_f64`. The HIR pass collapses references to e.g.
`Map` to the canonical TypeId for that kind.

`:zig.Map.put(map, key, value)` is a syntactic escape into the
runtime. Runtime function names follow `<TypeName>_<Method>_<Arity>`
after generic instantiation.

---

## 7. The Map runtime

After commit `07f56c7 runtime: rebuild Map(K, V) as Arc-headered,
pool-allocated cells`, `Map(K, V)` is:

```zig
pub fn Map(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();
        header: ArcHeader,                        // <-- inline Arc, layout-stable
        total_count: u32,
        repr_tag: u8,                             // 0 = flat, 1 = trie
        flat_entries: [*]const MapEntry,
        flat_count: u32,
        trie_root: ?*const HamtNode,

        const FLAT_THRESHOLD = 8;
        const BITS_PER_LEVEL = 5;
        const BRANCHING_FACTOR = 32;
        const MAX_DEPTH = 7;

        pub const MapEntry = struct { key: K, value: V };

        const HamtNode = struct {
            header: ArcHeader,                    // <-- inline Arc again
            bitmap: u32,
            children_entries: [*]const MapEntry,
            children_nodes: [*]const ?*const HamtNode,
            child_count: u6,
            is_collision: bool = false,
        };

        // ... hamtPut, hamtDelete, hamtGet
    };
}
```

**`Map.put` is BORROWING** (`src/runtime.zig:4010-4085`): success
paths return a fresh cell with refcount=1. The OLD map's refcount is
NOT decremented. The unchanged-return paths call
`retainNode_or_self_for_unchanged_return(map)` which retains the
input. **`Map.delete`, `Map.merge`, `Map.get`, `Map.has_key` all
borrow** — none of them release input.

**Path-copy `put`**: `hamtPut` walks the trie, allocating new nodes
along the spine. Each retained sibling-subtree pointer gets a
`retain()` so the new spine owns its own refcount. The OLD spine
keeps its refcount; release responsibility lies with the caller.

**Deep release.** When `Map.release` drops the cell to count 0, walks
`trie_root`, recursively releases every `HamtNode` child, frees the
arrays and the cell.

---

## 8. The k-nucleotide benchmark and original RSS gap

CLBG `k-nucleotide`: read FASTA, find `>THREE` block, count k-mer
frequencies via a `Map<i64, i64>` keyed on encoded 2-bits-per-base
k-mers. Output 3 sections with byte-exact format.

**Pre-Phase-6 measurements** (250k char input, before any of this work):
- C: 57 ms / 27 MiB
- Rust: 79 ms / 15 MiB
- Zig: 77 ms / 11 MiB
- Zap: **3.6 s / 7.36 GiB**

Zap's 7.36 GiB peak RSS is the bug. Cause: the IR emits NO ARC
operations for Map values today (`.map` not in `isArcManagedType`).
Every `Map.put` allocates a new cell from the per-(K,V) pool and the
old cell's refcount is never decremented. Pool grows linearly. Peak
RSS = pool high-water-mark = O(N) for an N-iteration loop.

The hot loop in `~/projects/lang-benches/k-nucleotide/k_nucleotide.zap:185-197`:

```
pub fn count_kmers_loop(seq :: String, n :: i64, k :: i64, i :: i64,
                        m :: %{i64 => i64}) -> %{i64 => i64} {
  if i + k > n {
    m
  } else {
    one = 1 :: i64
    zero = 0 :: i64
    key = KNucleotide.encode_at(seq, i, k, zero)
    previous = Map.get(m, key, zero)
    next_count = previous + one
    next_map = Map.put(m, key, next_count)
    KNucleotide.count_kmers_loop(seq, n, k, i + one, next_map)
  }
}
```

---

## 9. The Phase 6 plan and the IR-pass design

The plan (in `docs/k-nucleotide-rss-gap-implementation-plan.md`)
prescribed 7 phases:

1. **Instrumentation**: ARC counters, microbench, `ZAP_ARC_STATS=1`.
2. **ARC liveness pass**: backward CFG dataflow over ARC-managed locals.
3. **`share_value.mode` + `arc_consumed_locals`**: IR shape with default `.retain`.
4. **Wire ownership pass**: populate consume modes from analysis.
5. **Return-source elision**: arc_returned_locals filter.
6. **Flip `.map` flag + audit**: the milestone.
7. **Hardening**: CTFE, edge cases, compile-time overhead.

Phases 1-5 landed cleanly. The plan estimated Phase 6 at 3-4 days.
What actually happened with Phase 6 is the subject of this brief.

**Design intent.** Borrow + retain mode is the existing pre-Phase-6
semantics. Phase 4's consume-mode optimization was supposed to skip
retain/release pairs at "last use" sites — Perceus-style. Phase 5's
return-source elision was supposed to skip the function-epilogue
release for return values. With Phase 6.2b's IR-time scope-exit
release insertion, the model becomes: every ARC binding has a
matching scope-exit release, except where consume / return-source
elision optimizes it away.

The final flip in Phase 6 was supposed to be one line:
`.opaque_type, .map => true` instead of `.opaque_type => true`.

---

## 10. The 8 Phase 6 attempts — chronological narrative

The flip never landed. Each attempt below ran an autonomous agent
that diagnosed at least one new bug, fixed some subset, and then
either reverted the flip due to remaining segfaults or stopped at
the architectural complexity. The substrate accumulated 11 commits.

### Attempt 6.0 — pure flag flip (no commits)

Just flipped `.map`. Result: immediate segfault at `0xaaaaaaaaaaaaaa…`
(Zig debug-fill pattern for freed memory) on the trivial identity
function `pub fn id(m :: Map) -> Map { m }`.

**Diagnosis**: the IR has NO scope-exit release machinery for ARC
bindings — only post-call releases. The pre-existing model leaked
silently for `.opaque_type` (which is rarely used) but explodes for
`.map` (heavily used by k-nucleotide). Need to add scope-exit
release infrastructure. Reverted.

### Attempt 6.2a — landed: expose per-terminator live-before sets

Commit `405483d feat(arc_liveness): expose per-terminator
live-before sets`. Added `ArcOwnership.live_before_ret:
AutoHashMapUnmanaged(InstructionId, ArcLocalSet)` populated by the
existing dataflow. Foundation for scope-exit drop insertion.

### Attempt 6.2b — landed: IR-time scope-exit release insertion

Commit `0873fc5 feat(ir): IR-time scope-exit release insertion via
arc_drop_insertion pass`. New file `src/arc_drop_insertion.zig` with
~977 lines. Walks the IR after `arc_liveness` and inserts
`.release{value=L}` instructions before each ret-equivalent
terminator for L in `live_before_ret[term]`. Wired into `compiler.zig`
between `runProgramArcOwnership` and zir_builder consumption.

Handles ret-equivalent terminators: `.ret`, `.cond_return`, the
implicit returns at the end of `switch_return.cases[].body_instrs`
and `switch_return.default_instrs`, same for `union_switch_return`.
Does NOT recurse into `optional_dispatch` (the analyzer skips it,
its instructions don't have IDs).

### Attempt 6.2c — landed: retain-on-ret discipline

Commit `1a8ce40 feat(ir): retain-on-ret discipline for ARC return
values`. Extends `arc_drop_insertion` to insert
`.retain{value=L}` before each ret-equivalent terminator, when L is
ARC-managed and NOT in `arc_returned_locals` (return-source
elision). The retain ensures the caller receives a fresh refcount
unit.

**Finding from this commit**: arc_liveness's dataflow already
correctly excludes consumed locals from `live_before_ret`, so no
"dual-mark consume" hack was needed.

### Attempt 6.3 — flag flip (no commit)

After 6.2a-c landed, retried the flag flip. Still segfaults
k-nucleotide at the FIRST Map.put. Diagnosed: the post-call
`release(shared_local)` decrements the cell to 0 because `Map.put`
doesn't release input — caller's `result` aliases the input cell
which gets freed before use.

The substantive root cause: **`Map.put` is borrowing, but the IR's
consume mode (Phase 3) suppressed BOTH the retain and the post-call
release**, leaving the cell's refcount stuck. Pre-Phase-6 the model
wasn't broken because no real ARC type was flagged. Reverted.

### Attempt 6.4 — landed: consume mode skips retain only

Commit `11f7e4e fix(zir_builder): consume mode skips retain only,
post-call release still fires`. Phase 3's consume design suppressed
both retain AND post-call release. The correct semantics for
borrowing callees: skip retain only; post-call release decrements
the cell. Removed the `arc_consumed_locals` set and `markConsumed`
helper.

After this commit and a flag-flip retry: k-nucleotide RSS dropped
from 9 GiB to 240 MiB but STILL segfaulted at scale. The crash
boundary was at 21536 lines of input (worked at 21535, crashed at
21536). Diagnosed as either escape-analysis unsoundness or
tail-call rewriter masking. Reverted the flag flip (Commit 2
unshipped).

### Attempt 6.5 — landed: 3 fixes

- Commit `fcab310 fix(escape): ARC-managed types are never
  stack-eligible regardless of escape state`. Added
  `arc_managed_locals` to `ArcOwnership`; `shouldSkipArc` now
  refuses to mark ARC-managed-typed locals as stack-eligible. The
  escape lattice's `.no_escape` / `.function_local` classifications
  describe pointer flow, not allocation site — for ARC types, the
  cell is heap-allocated regardless and skipping ARC operations
  would leak.

- Commit `f2c4a47 fix(ir): tail-call rewriter walks past trailing
  release/retain when matching call + ret`. Phase 6.2b's drop
  insertion broke `count_kmers_loop`'s tail-call optimization by
  inserting `.release` between `call_named` and `ret`. The rewriter
  now walks past trailing release/retain when matching the pattern.

- Commit `d72af0b fix(arc_liveness): refuse consume_share_sites for
  aliased source locals`. Aliased shares — `local_get(d, source=m)
  ; share_value(s, source=d)` — were being marked as consume sites.
  But d is just an alias of m, not its own ownership unit;
  multiple shares of the same named local through aliases caused
  refcount underflow.

After these landed, retried the flag flip. STILL segfaults — even
with consume disabled on aliased shares. Reverted Commit 4 (flag
flip). The agent diagnosed: "There's at least one more gap (likely
retain/release imbalance across the alias chain when both shares run
as `.retain` mode); diagnosing it requires more depth than the time
budget allows."

### Attempt 6.7 — landed: local_get of ARC type retains source cell

Commit `5f55679 fix(ir): local_get of ARC-managed type retains
source cell for independent ownership`. Each `local_get(d,
source=m)` for an ARC-managed type now emits a `.retain{value=d}`
after. d becomes an independent ownership unit with its own
scope-exit release.

Edge case verified: local_get-retain followed by share-consume +
post-call release leaves cell at -1 net (a +1 from local_get's
retain, -1 from post-call release suppressed in consume mode, +1
new owner) — but Phase 6.4's "consume skips retain only, post-call
release still fires" makes this consistent.

After this commit, flag-flip RETRIED. Tests stayed green at small
scale. k-nucleotide STILL segfaulted. Diagnosed: 4 OTHER `local_get`
emission sites in `src/ir.zig` (3675, 3806, 4065, 4579) that handle
case/match pattern-binding extract scrutinee/element values
WITHOUT retaining. K-nucleotide does heavy `case` dispatch on Maps,
hitting these sites. Reverted Commit 2 (flag flip).

### Attempt 6.8 — landed: all local_get sites retain

Commit `4a206b9 fix(ir): all local_get sites retain source cell for
ARC-managed types`. Added `local_hir_types` side table to
`IrBuilder`, populated at every site that defines a local. New
`emitLocalGet(dest, source)` helper consults it and emits the
retain. Refactored all 5 `local_get` emission sites to use the
helper.

After this commit, flag-flip RETRIED. Still segfaults k-nucleotide
at scale (small workloads work, N≥50000 segfaults). The agent
observed: `releases_total ≈ 3 × retains_total` for any Map workload.

**Diagnosis**: `Map.put` and `Map.delete` are BORROWING (don't
release input). The arc_liveness analyser still marks last-use
shares as `.consume`. With consume mode + borrowing callee + post-
Phase-6.7 local_get retain: the cell ends up with one too many
releases at scale once the trie internal node reuse paths kick in.
Reverted Commit 2 (flag flip).

### Attempt 6.9 — landed: gate consume_share_sites entirely

Commit `dd985e5 fix(arc_liveness): gate consume_share_sites on
per-callee borrow/consume convention`. Per the diagnosis: today no
runtime function consumes its input. Until per-callee borrow/consume
metadata exists, the safe ABI is "every share retains, every
scope-exit release fires." Disabled consume_share_sites entirely
(every share is `.retain`).

After this commit, flag-flip RETRIED. **STILL segfaults.** This is
significant: even with consume mode entirely off, even with the
local_get retain helper covering all 5 sites, even with all the
escape-analysis and tail-call fixes in place — the simplest Map
workload segfaults under the flip.

The agent identified this as a new layer of bug independent of
consume mode, with three specific suspects (see §12). Reverted
Commit 2 (flag flip).

### Attempt 6.10 — interrupted

Final attempt with explicit printf-trace methodology to identify the
exact retain/release sequence. The agent was making progress on a
trace-based diagnosis but the user interrupted to request this
research brief.

The agent's last visible work: investigating how the IR emits a
`release` whose `value` field is an Optional that isn't matching
expected semantics. Specifically: "Zig allows that comparison and
returns true when optional is non-null and equal. So `r.value == 0`
with r.value=0 returns true. Should skip."

This was inside the `arc_drop_insertion` pass's release-suppression
filter. Possibly a bug: the optional comparison is incorrectly
matching some release that should not be suppressed (or vice versa).

---

## 11. Current state and remaining segfault

**Repository state on `main`**: `dd985e5 fix(arc_liveness): gate
consume_share_sites on per-callee borrow/consume convention`.

- 724/724 unit tests pass
- 104/104 zir-tests pass
- All 3 CLBG benchmark ports byte-exact
- Without the flag flip: k-nucleotide RSS = 7.57 GiB, runtime = 4.31 s
- With the flag flip applied (NOT committed): k-nucleotide segfaults
  with SIGSEGV (exit 139), no output produced. The doc-runner
  zir-test also segfaults.

**Phase 6 substrate landed (11 commits in `main`):**

```
dd985e5 fix(arc_liveness): gate consume_share_sites on per-callee borrow/consume
4a206b9 fix(ir): all local_get sites retain source cell for ARC-managed types
5f55679 fix(ir): local_get of ARC-managed type retains source cell for ind ownership
d72af0b fix(arc_liveness): refuse consume_share_sites for aliased source locals
f2c4a47 fix(ir): tail-call rewriter walks past trailing release/retain
fcab310 fix(escape): ARC-managed types are never stack-eligible
11f7e4e fix(zir_builder): consume mode skips retain only, post-call release still fires
1a8ce40 feat(ir): retain-on-ret discipline for ARC return values
0873fc5 feat(ir): IR-time scope-exit release insertion via arc_drop_insertion pass
405483d feat(arc_liveness): expose per-terminator live-before sets
a71142a fix(zir_builder): consume-mode keying matches sv.dest, not sv.source
```

(Plus earlier Phase 1-5 commits: 0947f96 reproducers, dfd80ef
instrumentation, 83a1a03 + 164490e arc_liveness pass, 3bb6705
share_value mode, 402a9c4 wire ownership, 9f9bec4 return elision.)

**The exact failing reproducer** (after applying the flag flip
locally without committing):

```zap
pub struct Probe {
  pub fn main() -> String {
    m = %{0 :: i64 => 0 :: i64}
    Kernel.inspect(Map.has_key(m, 0 :: i64))
    "done"
  }
}
```

This is the simplest possible Map workload: literal + 1 read. It
segfaults at the FIRST Map operation under the flag flip.

A more aggressive reproducer that segfaults at scale:

```zap
pub struct Probe {
  pub fn main() -> String {
    m = %{0 :: i64 => 0 :: i64}
    cleared = Map.delete(m, 0 :: i64)
    a = Map.get(cleared, 1 :: i64, -1 :: i64)
    b = Map.get(cleared, 2 :: i64, -1 :: i64)
    Kernel.inspect(a + b)
    "done"
  }
}
```

Two aliased shares of `cleared` cause refcount underflow.

---

## 12. Specific suspects identified by the latest agent

After 8 attempts and 11 substrate commits, the remaining segfault is
not in any of:

- consume mode (gated entirely off in 6.9)
- escape lattice for ARC types (fixed in 6.5 fcab310)
- tail-call rewriter (fixed in 6.5 f2c4a47)
- alias-share consume marking (gated in 6.5 d72af0b)
- local_get retain across all 5 sites (fixed in 6.8 4a206b9)
- consume keying (fixed in 6.4 11f7e4e)
- post-call release suppression (corrected in 6.4)

The most credible remaining suspects, per the latest agent's
diagnosis:

**(a) `releaseFieldChildAny` for `.map`-typed struct fields.**
`src/runtime.zig:454+` recursively releases struct fields containing
Arc'd children. Map cells now carry inline ArcHeader, and
`hasInlineArcHeader` should fire automatically — but maybe doesn't
for all Map field shapes. Specifically, Map cells contain HAMT
internal nodes which are also Arc-headered; the deep-release walk
must traverse those. Worth a unit test: a struct with a Map field,
allocate, drop, verify the Map's children all get released.

**(b) `propagateReturnSourcesThroughAggregates`** (in
`src/arc_liveness.zig`) may now elide a release that is genuinely
needed for a Map local that flows through both a return-source path
and a borrow path. The analyzer sees the local as a return-source
(elide release) but a sibling instruction also reads the local
post-return-source-binding. This double-categorization could leak or
double-decrement.

**(c) The `init`-allocated cell-with-refcount-1 from `Map.put` /
`Map.delete` returns may not be having its post-call release counted
symmetrically.** When `Map.put` returns a freshly-allocated cell
(refcount=1), the caller's IR pattern is:
- assign `next = call_result` (no retain because it's a fresh value)
- ... use `next` ...
- post-call release on `shared_local` — but `shared_local` was the
  INPUT to the call, not the call's RESULT.

If the assignment of `next = call_result` doesn't bump refcount, and
the value's eventual scope-exit release does decrement, the
allocation is balanced. But if the IR's emission pattern doesn't
distinguish "return value of a call" from "regular local_get
source", the call_result might trigger the local_get retain helper
spuriously, leading to imbalance.

**(d) The `arc_drop_insertion` pass's filter logic.** The latest
agent (6.10, interrupted) was inspecting an optional comparison
inside the release-suppression filter. The IR may have a release
whose `value` field is an Optional and the comparison logic is
matching a release that should not be matched, or vice versa.

**(e) The `optional_dispatch` instruction.** Phase 6.2b's drop
insertion explicitly does NOT recurse into optional_dispatch's
nested instruction streams. This may be wrong — if Map operations
flow through optional_dispatch (which generic functions often do),
their scope-exit drops might be missed.

---

## 13. Constraints (non-negotiable)

From `~/projects/zap/CLAUDE.md`:

- **No workarounds.** No "use a flat hash set instead of Map" or
  similar. The persistent-Map perf path must be fundamentally correct.
- **Zap is a language.** Fixes belong in the compiler / IR / runtime,
  not in user-facing Zap code. No "@consume" annotation in user code
  unless the design demands it.
- **No new ZIR opcodes in the Zig fork.** Lower through standard Zig.
- **TDD.** Failing tests must drive every commit.
- **Don't regress.** 724/724 unit, 104/104 zir-test, all 3
  benchmarks byte-exact must remain green.

From observation (Phase 6 saga):

- **`.opaque_type` is essentially unused** in stdlib user-facing code.
  The Phase 4-5 consume / return-elision work was never end-to-end
  exercised on a real workload. This is why the flag flip surfaces
  layered bugs.
- **`Map.put` / `Map.delete` / etc. are BORROWING.** They do not
  release input. They do not transfer ownership. They allocate a
  new cell and return it.
- **`zap run doc` repeatedly hangs** during Phase 6 attempts. The
  doc generator does CTFE evaluation that hits IR paths different
  from the runtime test suite. Several Phase 6 attempts saw
  doc-gen segfault or hang for hours.
- **lldb in batch mode hangs.** Multiple attempts spent 30+ minutes
  on hung lldb processes. Use printf-style instrumentation only.

---

## 14. Research questions for the next investigator

The deliverable is a definitive root-cause analysis answering:

### 14.1 Why does the flip still segfault?

After 11 substrate commits eliminating every previously-identified
bug, why does `m = %{0 :: i64 => 0 :: i64}; Kernel.inspect(Map.has_key(m, 0 :: i64))`
still fail under the flag flip?

Specifically:
- Trace EVERY retain and release operation on the cell allocated by
  `%{0 :: i64 => 0 :: i64}`. Print cell pointer, refcount before/after,
  caller (IR instruction id, source line in `src/runtime.zig`).
- Identify the exact operation that decrements past 0, or that
  reads a freed cell.
- Cross-reference against the IR dump for the function. Print the
  IR after `arc_liveness` and after `arc_drop_insertion`.

### 14.2 Is suspect (a) — `releaseFieldChildAny` for Map fields — the cause?

Read `src/runtime.zig:454-509` (the entire `ArcRuntime` namespace).
Trace through `releaseFieldChildAny` for a struct field of type
`?*const Map(K, V)`. Does `hasInlineArcHeader(Map(K, V))` return
true? Does the `Optional` → `Pointer` → `releaseArcAny` chain reach
`Map.release`? Does `Map.release`'s deep-release walk correctly
recurse into HamtNode children?

Test: write a `pub struct Foo { m: %{i64 => i64} }`, allocate, drop.
Verify the Map cell and all HamtNode descendants are freed.

### 14.3 Is suspect (b) — return-source aggregate propagation — the cause?

Read `src/arc_liveness.zig:propagateReturnSourcesThroughAggregates`
and trace the simple case: `pub fn id(m :: %{i64 => i64}) -> %{i64 => i64} { m }`.
Does `m` correctly land in `arc_returned_locals`? Is the matching
scope-exit release from `arc_drop_insertion` correctly suppressed?
Is the function-epilogue retain (Phase 6.2c) correctly suppressed?
Is the OUTGOING refcount equal to the INCOMING refcount?

### 14.4 Is suspect (c) — call-return cell handling — the cause?

When `Map.put` returns a freshly-allocated cell at refcount=1, what
happens at the caller's bind site? Does the IR emit a `local_get`
that incorrectly retains the call_result?

Read `src/ir.zig:5021-5054` (the lowerExpr `local_get` arm) and
identify how call results are bound to locals. Trace whether the
retain-on-local-get fires for fresh call returns.

### 14.5 Is suspect (d) — drop-insertion filter — the cause?

Read `src/arc_drop_insertion.zig`'s release-suppression logic.
Identify any place where an Optional comparison is used to decide
whether to skip a release. Verify the comparison semantics: is
`r.value == 0` matching a release whose `value` is the LocalId 0,
or is it matching the absence of a value?

### 14.6 Is suspect (e) — optional_dispatch — the cause?

`arc_drop_insertion` explicitly does not recurse into
`optional_dispatch.nil_instrs` / `struct_instrs`. Does this mean
ARC locals defined inside those nested streams never get scope-exit
drops? If so, what Map operations flow through optional_dispatch?

### 14.7 Is the design fundamentally sound?

After 8 attempts, is "borrow + retain mode + scope-exit drops" the
right ABI for persistent Map operations? Or does the design need to
change to:
- Consuming Map.put / Map.delete (release input internally)
- Per-callee borrow/consume metadata (allowlist)
- Linear ownership / move semantics
- Something else entirely

Consider what Koka, Lean 4, Roc, and Swift do for similar persistent
data structures. The brief at
`docs/k-nucleotide-rss-gap-research-brief.md` has a literature
section.

### 14.8 Is the testing methodology adequate?

Every Phase 6 attempt has run agents in batch mode. Several agents
have hung on lldb or `zap run doc`. Should the investigation switch
to interactive debugging (run lldb manually, step through), or
extensive printf instrumentation, or differential analysis (compile
with and without the flip, diff the ZIR / AIR / LLVM IR output)?

---

## 15. Appendix A — file & line index

Run all paths from `/Users/bcardarella/projects/zap/`.

| Path | Purpose |
|------|---------|
| `CLAUDE.md` | Project rules. Read first. |
| `docs/k-nucleotide-rss-gap-research-brief.md` | Original brief with literature & lit. |
| `docs/k-nucleotide-rss-gap-implementation-plan.md` | The plan. |
| `docs/k-nucleotide-rss-gap-phase6-struggles.md` | This file. |
| `src/runtime.zig:214-248` | `ArcHeader` |
| `src/runtime.zig:303-509` | `ArcRuntime` namespace |
| `src/runtime.zig:317-331` | `ArcPool(T)` |
| `src/runtime.zig:383` | `hasInlineArcHeader(T)` |
| `src/runtime.zig:454` | `releaseFieldChildAny` (suspect a) |
| `src/runtime.zig:528` | `retainAny` |
| `src/runtime.zig:602+` | `MArrayOf(T)` runtime |
| `src/runtime.zig:2951-3700` | Map(K, V) impl |
| `src/runtime.zig:4010-4085` | `Map.put` (BORROWING — does not release input) |
| `src/runtime.zig:4087+` | `Map.delete` (BORROWING) |
| `src/scope.zig:468` | `NativeTypeKind` enum |
| `src/types.zig` | `.map`, `.list`, `.opaque_type` variants |
| `src/hir.zig` | HIR layer |
| `src/monomorphize.zig` | Generic specialization |
| `src/perceus.zig` | Existing reuse-at-deconstruction pass (NOT last-use) |
| `src/arc_liveness.zig` | NEW — backward dataflow ARC last-use |
| `src/arc_liveness.zig:propagateReturnSourcesThroughAggregates` | (suspect b) |
| `src/arc_drop_insertion.zig` | NEW — IR-time scope-exit release insertion |
| `src/escape_lattice.zig` | Escape analysis |
| `src/ir.zig:1012` | `isArcManagedTypeId` (the flip target) |
| `src/ir.zig:4641` | `IrBuilder.isArcManagedType` (the flip target) |
| `src/ir.zig:1129+` | `local_hir_types` side table (Phase 6.8) |
| `src/ir.zig:4779-4827` | `isArcManagedLocal`, `emitLocalGet` helpers |
| `src/ir.zig:3686-3690, 3819-3822, 4080-4083, 4598-4602, 5034-5043` | The 5 local_get emission sites |
| `src/ir.zig:5336` | The ONLY post-call `.release` emit site |
| `src/zir_builder.zig:498-504` | `arc_share_skipped` (escape lattice) |
| `src/zir_builder.zig:4151-4176` | consume-mode share_value lowering |
| `src/zir_builder.zig:6443-6447` | release-suppression filter |
| `src/zir_integration_tests.zig` | end-to-end test harness |
| `src/test_reductions/persistent_map_tail_loop.zap` | Phase 1 microbench |
| `~/projects/lang-benches/k-nucleotide/k_nucleotide.zap` | The benchmark |
| `~/projects/lang-benches/k-nucleotide/expected.txt` | Byte-exact target |
| `~/projects/lang-benches/k-nucleotide/input.fasta` | Standard 250k-char input |
| `~/projects/zig/src/zir_api.zig` | Zig fork C-ABI surface |

---

## 16. Appendix B — full Phase 6 commit list

In chronological order (from first commit on `main` for Phase 6):

| SHA | Subject |
|-----|---------|
| `405483d` | feat(arc_liveness): expose per-terminator live-before sets |
| `0873fc5` | feat(ir): IR-time scope-exit release insertion via arc_drop_insertion pass |
| `1a8ce40` | feat(ir): retain-on-ret discipline for ARC return values |
| `a71142a` | fix(zir_builder): consume-mode keying matches sv.dest, not sv.source |
| `11f7e4e` | fix(zir_builder): consume mode skips retain only, post-call release still fires |
| `fcab310` | fix(escape): ARC-managed types are never stack-eligible regardless of escape state |
| `f2c4a47` | fix(ir): tail-call rewriter walks past trailing release/retain when matching call + ret |
| `d72af0b` | fix(arc_liveness): refuse consume_share_sites for aliased source locals |
| `5f55679` | fix(ir): local_get of ARC-managed type retains source cell for independent ownership |
| `4a206b9` | fix(ir): all local_get sites retain source cell for ARC-managed types |
| `dd985e5` | fix(arc_liveness): gate consume_share_sites on per-callee borrow/consume convention |

Plus prior Phase 1-5:

| SHA | Subject |
|-----|---------|
| `0947f96` | test: add reduced reproducers for CLBG-blocker bugs |
| `dfd80ef` | feat(runtime): ARC instrumentation counters and persistent-map microbench |
| `83a1a03` | feat(ir): ARC-local last-use analysis (computeArcOwnership) |
| `164490e` | fix(arc_liveness): handle optional_dispatch instruction in collectUses |
| `3bb6705` | feat(ir): add ShareMode and consume-mode lowering for share_value |
| `402a9c4` | feat(ir): wire computeArcOwnership consume sites into share_value modes |
| `9f9bec4` | feat(ir): return-source drop elision via arc_returned_locals filter |

And the initial Map ARC substrate from before this session:

| SHA | Subject |
|-----|---------|
| `07f56c7` | runtime: rebuild Map(K, V) as Arc-headered, pool-allocated cells |

Total: **19 commits** of Map-ARC-related work, none of which is
sufficient to unblock the flag flip.

---

## 17. Appendix C — relevant code excerpts

### 17.1 The flip target

`src/ir.zig:1012-1015`:

```zig
pub fn isArcManagedTypeId(type_store: *const types_mod.TypeStore, type_id: types_mod.TypeId) bool {
    if (type_id >= type_store.types.items.len) return false;
    return type_store.getType(type_id) == .opaque_type;
}
```

`src/ir.zig:4641-4644`:

```zig
fn isArcManagedType(self: *const IrBuilder, type_id: hir_mod.TypeId) bool {
    const store = self.type_store orelse return false;
    return store.getType(type_id) == .opaque_type;
}
```

The intended flip:

```zig
const t = type_store.getType(type_id);
return t == .opaque_type or t == .map;
```

### 17.2 `Map.put`'s borrowing semantics

`src/runtime.zig:4010-4085`:

```zig
pub fn put(map: ?*const Self, key: K, value: V) ?*const Self {
    if (map == null) {
        const entries = allocEntries(1) orelse return null;
        entries[0] = .{ .key = key, .value = value };
        return makeFlatMap(entries, 1);
    }

    const m = map.?;

    if (m.repr_tag == 0) {
        // Currently flat — copy and update / append
        const old_count: usize = @intCast(m.flat_count);
        // ... allocate new entries, return makeFlatMap or makeTrieMap
    }

    // Trie mode
    if (m.trie_root) |root| {
        const hash = hashKey(key);
        const new_root = hamtPut(root, key, value, hash, 0) orelse {
            retainNode_or_self_for_unchanged_return(map);
            return map;
        };
        return makeTrieMap(new_root, new_total);
    }
    // ...
}
```

Note: the success paths return a fresh cell. The OLD map's refcount
is unchanged. Caller is expected to release the old map.

### 17.3 The current consume-mode lowering (post-Phase-6.9)

`src/zir_builder.zig:4151-4176` (after Commit 1 of 6.4 keying fix
and Commit 1 of 6.9 gating):

```zig
.consume => {
    // Phase 6.4: skip retain only (post-call release still fires for borrowing callees).
    // Phase 6.9: consume mode is gated entirely off in arc_liveness — share_value never gets
    // .consume mode emitted today. This branch is dead code until per-callee borrow/consume
    // metadata exists.
    // ... lowering logic ...
}
```

### 17.4 The drop-insertion filter

In `src/zir_builder.zig` release lowering — `isReleaseSuppressed`
checks:

- `arc_share_skipped` (escape lattice — local is stack-eligible, no ARC ops needed)
- `arc_returned_locals` (Phase 5 elision — local is the source of `ret`)

These are populated per function during compilation.

### 17.5 The arc_drop_insertion pass

`src/arc_drop_insertion.zig` walks the function body. For each
ret-equivalent terminator at instruction id `id`:

```zig
// Look up live_before_ret[id] from ArcOwnership.
// For each ARC local L in that set, prepend `.release{value=L}` to the body.
// If terminator carries a return value V that is ARC-managed and NOT in
//   return_source_locals, prepend `.retain{value=V}` after the releases.
// Then the terminator itself.
```

The pass does NOT recurse into `optional_dispatch.nil_instrs` /
`struct_instrs`.

### 17.6 The hot loop in user code

`~/projects/lang-benches/k-nucleotide/k_nucleotide.zap:185-197`:

```
pub fn count_kmers_loop(seq :: String, n :: i64, k :: i64, i :: i64,
                        m :: %{i64 => i64}) -> %{i64 => i64} {
  if i + k > n {
    m
  } else {
    one = 1 :: i64
    zero = 0 :: i64
    key = KNucleotide.encode_at(seq, i, k, zero)
    previous = Map.get(m, key, zero)
    next_count = previous + one
    next_map = Map.put(m, key, next_count)
    KNucleotide.count_kmers_loop(seq, n, k, i + one, next_map)
  }
}
```

### 17.7 Reproducer that segfaults under the flip

```zap
pub struct Probe {
  pub fn main() -> String {
    m = %{0 :: i64 => 0 :: i64}
    Kernel.inspect(Map.has_key(m, 0 :: i64))
    "done"
  }
}
```

This is the simplest possible Map workload that fails under the
flag flip. Identifying the exact operation that decrements the cell
to 0 (or reads a freed cell) is the key diagnostic step.

---

## End of brief

Suggested next session structure:

1. **Reproduce locally** with the flag flip applied as a working-tree change (don't commit).
2. **Add printf instrumentation** in `Map.retain`, `Map.release`, `makeFlatMap`, `makeTrieMap`, plus stderr prints for every IR-emitted retain/release at zir_builder time. Trace EVERY operation on EVERY cell address.
3. **Run the simplest reproducer** under the instrumentation.
4. **Identify the exact decrement that drops a cell to refcount 0 (or below) before its last legitimate use.** Cross-reference against the IR dump.
5. **Decide**: is this fixable with a focused commit, or does it require an architectural change (per-callee borrow/consume metadata, consuming Map.put internals, linear ownership, etc.)?
6. **If fixable**: land the fix + flag flip. Verify against the verification matrix in §15 of the implementation plan.
7. **If architectural**: write a fresh design memo. The CLAUDE.md "no compromises" rule applies — if the design needs to change, change it.

The agents in the prior 8 attempts were disciplined about not
shipping broken code (per CLAUDE.md). They succeeded at ELIMINATING
the previously-identified bugs but always discovered ONE MORE bug
when the flag flipped. After 11 substrate commits, the next bug is
the deepest one yet — and the previous diagnosis points at specific
suspects (a) through (e) listed in §12 above.

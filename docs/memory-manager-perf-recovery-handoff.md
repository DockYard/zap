# Memory Manager Perf-Recovery — Handoff

This document hands off the in-flight memory-manager perf-recovery effort so a fresh agent session can pick up cleanly. As of this writing, **Phases 1–7b are complete and committed**; the remaining gap is documented below.

---

## TL;DR

- **Problem**: binarytrees ARC regressed from ~2.6s (pre-Phase-4 of the pluggable-memory-manager rollout) to 9.75s after the rollout. Root cause: vtable indirection + cross-TU calls preventing LLVM inlining on Mach-O (LTO is not available on Mach-O — `hasLldSupport(.macho) = false`).
- **Choice made**: Option 2 — source-level inlining for built-in managers. Built-in managers' sources are registered as a sibling Zig module (`zap_active_manager`) in every user-binary build; runtime dispatchers do `if (comptime ACTIVE_MANAGER_TAG == ...)` branching to call the manager directly, bypassing the vtable for first-party builds. Third-party managers keep the v1.0 ABI vtable path unchanged.
- **Status**: source-level inlining is **structurally complete and verified working** — disassembly confirms `ACTIVE_MANAGER_TAG = .arc` in cache, zero `blr` indirect calls in the Tree allocation hot path, all 1173 tests green.
- **Perf state**: binarytrees ARC **9.75s → 5.85s** (40% absolute reduction, ~55% of regression recovered). Target was 2.6s; gap remains 3.25s.
- **Why the gap remains**: it's NOT a dispatch problem anymore. Profiling attributes the remaining 3.25s as **~75% atomic-refcount cost** (`ldaddal`/`ldsetal` per retain/release — inherent to ARC) and **~25% residual non-inlinable per-call work**.

---

## Commits landed (chronological, all on `main` of `/Users/bcardarella/projects/zap`)

| Commit | Phase | What |
|---|---|---|
| `2c6a214` | Phase 1 | Introduce `BuiltinManagerTag` enum + thread through pipeline |
| `cbae918` | Phase 1 followup | Gap resolution (doc fixes, integration tag pins, exhaustiveness guard) |
| `7d1b0e9` | Phase 2 | `@embedFile` first-party manager sources into the compiler |
| `0dcff01` | Phase 2 followup | Gap resolution (rename `manager_source_unit_name` → `managerSourceUnitName`, broader on-disk pin) |
| `738e32e` | Phase 3 | Per-user-binary active-manager source emission + `@import("zap_active_manager")` surface |
| `54e864f` | Phase 3 followup | Gap resolution (extract `src/zap_active_manager_stub.zig` as single source of truth, ordinal tripwire) |
| `cba8ca9` | Phase 4 | Comptime dispatch in runtime hot paths |
| `cb355b7` | Phase 4 followup | Gap resolution (host-build comptime typecheck of `active_manager.*` signatures, `refCountAny` exemption documented) |
| `60955ad` | Phase 5 | Skip manager `.o` compile + link for first-party (`builtin_tag != .third_party`) |
| `3de80fd` | Phase 6 | Consolidate dispatcher globals into `ActiveManagerState`; gate ARC counter stores by `collect_arc_stats` comptime flag |
| `025332c` | Phase 6 followup | Inline `allocAny`/`freeAny`; refresh stale comments to reference `active_manager_state.*` |
| `1a1e8cf` | Phase 7b | Comptime-fold dispatcher null-checks for first-party builds (`activeManagerCorePresent`, `activeManagerRefcountCapabilityPresent`, `managerHasSizedExtension`) |

**lang-benches repo (`/Users/bcardarella/projects/lang-benches`):**
- `3f7b3af` — Refresh Zap bench numbers after Phase 7b; HTML report regenerated (path `results/index.html`).

---

## Architecture summary

### How user binaries are built

For every Zap user binary:

1. `src/main.zig:buildTarget` reads `build.zap`'s manifest, gets `config.memory_manager` (e.g. `"Zap.Memory.ARC"`).
2. `src/memory/driver.zig:resolve()` classifies via `classifyBuiltinManager(name)` → `BuiltinManagerTag` ∈ `{.arc, .arena, .no_op, .leak, .tracking, .third_party}`.
3. **First-party (`builtin_tag != .third_party`)**: short-circuits source discovery / external compile / `.zapmem` parse. Returns `ResolvedManager` with `object_path = null`, `declared_caps` from `builtinManagerDeclaredCaps(tag)` comptime table, `abi_minor = 1`.
4. **Third-party**: existing flow — discover source via `@memory_manager_source` attr, compile via `zap_fork_compile_zig_to_object`, parse `.zapmem`, validate. `object_path` is populated.
5. `src/main.zig` passes `resolved_manager.builtin_tag` to `zir_backend.CompileOptions` and calls `compiler.getActiveManagerSourceBytes(tag)` to get the manager's Zig source bytes.
6. For first-party: bytes are `@embedFile`'d in `compiler.zig` (e.g. `arc_manager_source = @embedFile("memory/arc/manager.zig")`).
7. For third-party: bytes are the stub at `src/zap_active_manager_stub.zig` (panic-only fns; the runtime's `.third_party` comptime branch never calls them).
8. `zir_backend.createContext` calls `zir_compilation_add_struct_source(ctx, "zap_runtime", runtime_source.ptr, len)` AND `zir_compilation_add_struct_source(ctx, "zap_active_manager", active_manager_source.ptr, len)`. Both become siblings of the user-binary root in the Zig fork's compilation tree.
9. `compiler.getRuntimeSource(declared_caps, builtin_tag)` rewrites the embedded `runtime.zig` source per build with TWO markers:
   - `RUNTIME_DECLARED_CAPS_DEFAULT: u64 = 0x1;` (or 0x0 for non-REFCOUNT managers)
   - `RUNTIME_ACTIVE_MANAGER_TAG_DEFAULT: ActiveManagerTag = .arc;` (or whichever tag)
10. The runtime declares `pub const ACTIVE_MANAGER_TAG: ActiveManagerTag = RUNTIME_ACTIVE_MANAGER_TAG_DEFAULT;` and dispatchers branch on it via `if (comptime ACTIVE_MANAGER_TAG == .third_party) { ... } else if (comptime managerHasRefcountV1(ACTIVE_MANAGER_TAG)) { active_manager.<fn>(...) } else { @panic(...) }`.

### Key invariants

- `BuiltinManagerTag` in `src/memory/driver.zig:184-191` and `ActiveManagerTag` in `src/runtime.zig:722-729` are mirrored enums with the SAME case names AND SAME explicit `u8` ordinals (`arc=0, arena=1, no_op=2, leak=3, tracking=4, third_party=5`). Comptime ordinal-pair tripwire at `src/compiler.zig:3520-3538` fires `@compileError` on drift.
- Each first-party manager.zig file has a `comptime { ... }` block at the bottom that pins all 11 uniform-interface aliases against the canonical `AbiV1` slot types — catches alias-impl drift at manager-build time.
- A host-build test at `src/runtime.zig` (search for `"active_manager uniform interface signatures match"`) pins every `active_manager.<fn>` symbol against `AbiV1.ZapMemoryManagerCoreV1`/`ZapRefcountCapabilityV1` slot types so a typo in the runtime's first-party comptime branches is caught at host-test time (otherwise dead-code-eliminated under `.third_party`).
- The `Zap.Memory.{ARC,Arena,NoOp,Leak,Tracking}` set is the canonical first-party list. Adding a 6th first-party manager requires landing in ONE commit: (a) new `lib/zap/memory/<name>.zap`, (b) new `BuiltinManagerTag` case, (c) new `classifyBuiltinManager` arm, (d) new `src/memory/<name>/manager.zig`, (e) updated `getBuiltinManagerSource` + `managerSourceUnitName` switches in `src/compiler.zig`, (f) updated `ActiveManagerTag` in `src/runtime.zig` + `managerHasRefcountV1`/`managerHasSizedExtension`/`activeManagerCorePresent`/`activeManagerRefcountCapabilityPresent` if applicable.

### What each manager actually provides

| Manager | declared_caps | Implements REFCOUNT_V1 | ABI minor |
|---|---|---|---|
| `Zap.Memory.ARC` | `0x1` (REFCOUNT_V1_BIT) | yes (real impls) | 1 |
| `Zap.Memory.Arena` | `0` | no (panic stubs for refcount fns) | 1 |
| `Zap.Memory.NoOp` | `0` | no (panic stubs) | 1 |
| `Zap.Memory.Leak` | `0` | no (panic stubs) | 1 |
| `Zap.Memory.Tracking` | `0` | no (panic stubs) | 1 |

The `comptime managerHasRefcountV1(tag)` helper in `src/runtime.zig` (search for the name) returns `true` ONLY for `.arc`. Earlier in this effort I incorrectly assumed Leak and Tracking implemented REFCOUNT_V1 — a Phase 4 subagent correctly verified by reading the source and set them to `false`. Don't repeat my mistake.

---

## Bench matrix (post-Phase-7b)

`/Users/bcardarella/projects/lang-benches/results/` — raw per-manager text + JSON. HTML at `results/index.html`.

| Benchmark | ARC wall | ARC peak RSS | Arena wall | Arena peak RSS |
|---|---|---|---|---|
| nbody | 0.10s | 1.3 MiB | 0.10s | 1.3 MiB |
| mandelbrot | 2.00s | 1.3 MiB | 2.02s | 1.3 MiB |
| **binarytrees** | **5.85s** | 162 MiB | **4.34s** | 6.15 GiB |
| fannkuch-redux | 1.97s | 1.4 MiB | 1.67s | 1.3 MiB |
| spectral-norm | 0.16s | 1.4 MiB | 0.16s | 1.4 MiB |
| k-nucleotide | 0.30s | 20 MiB | 0.29s | 25 MiB |

Pre-recovery binarytrees ARC was 9.75s (peak regression). No regressions in any other benchmark across the 13 commits.

**Note**: the HTML's per-bench bar charts read from `results/*.json` files which are only refreshed by `scripts/run-all.sh` (the full cross-language matrix). That script takes hours and was not re-run; the HTML's visual bars for Zap rows still reflect pre-Phase-7b measurements even though the new SHA/timestamp are shown. If a full HTML refresh is needed, run `scripts/run-all.sh --memory` (warning: hours-long).

---

## Why we stopped where we did

After Phase 7b's 12% recovery, the next phase candidates have **diminishing returns** and the dominant remaining bottleneck is **out of Option 2's scope**.

### Diagnostic evidence

1. **Comptime dispatch IS firing for ARC builds.** Cache file `/Users/bcardarella/projects/lang-benches/binarytrees/.zap-cache/zap_structs/zap_runtime.zig` line ~805 contains `const RUNTIME_ACTIVE_MANAGER_TAG_DEFAULT: ActiveManagerTag = .arc;` (rewritten from `.third_party`).
2. **LLVM is inlining the manager into the runtime TU.** `nm` shows zero standalone `arcRetain*`/`arcRelease*`/`arcAllocate*` symbols — they're all merged into `_main`.
3. **Zero `blr` indirect calls in the Tree allocation hot path.** All 237 `blr` instances in the binary are in cold paths (panic handlers, IO/fmt, std lib, pthread). Zig reference binarytrees has 569; Zap's 237 is competitive.
4. **The remaining bottleneck is atomic RC.** Disassembly shows the Tree.release fast path emits `ldaddal w9, w8, [x8]` (atomic decrement) per node. At ~6-8 cycles per atomic × ~50M nodes for depth-21 = ~300M cycles ≈ 1.5s — plus the same on the retain side. Per-iteration instruction count is reasonable; per-iteration atomic cost is the dominant factor.

### Estimated value of further dispatcher work

| Candidate | Estimated recovery | Effort | In Option 2 scope? |
|---|---|---|---|
| Per-T slab class specialization | 5-10% (0.3-0.6s) | 2-3 days, requires codegen integration | Arguably yes — built-in manager specialization extending the comptime dispatch idea |
| Hoist `ensureMemoryStartup` out of per-call path | 2-3% (0.1-0.2s) | 1 day | Yes — pure dispatcher cleanup |
| Perceus refcount elision in `arc_optimizer.zig` / `arc_drop_insertion.zig` | 20-40% (1-2s) | Multi-week | NO — separate optimization pass |
| Biased / deferred refcounting | Unbounded but big | Multi-month, ABI-impacting | NO — different memory-management approach |

---

## Concrete next-step candidates

### Phase 7d — Per-T slab class specialization (PRIMARY candidate)

**Goal**: when the codegen knows `T` at compile time at the allocation site, emit a comptime-specialized call that hardcodes the slab class index, eliminating the runtime class lookup inside `arcAllocateRefcounted`.

**Why it might help**: `arcAllocate` at disasm offset ~0x3540-0x3578 contains a runtime size→class-index lookup. For `Tree` (size=16, align=8), the class is always `0`. Eliminating the lookup saves ~6 instructions per allocation; with ~50M allocations for depth-21 binarytrees that's ~300M instructions saved.

**Sketch of the work**:

1. **Add a comptime-class variant to each manager** that declares REFCOUNT_V1:
   ```zig
   // In src/memory/arc/manager.zig:
   pub inline fn allocateRefcountedClass(
       ctx: *anyopaque,
       comptime class_index: u32,
       alignment: u32,
   ) ?[*]u8 {
       const cls = &slab_pool.classes[class_index];
       const slot_size = comptime SLAB_CLASS_SIZES[class_index];
       // ... existing fast-path code with `class_index` and `slot_size` as constants ...
   }
   pub const allocateRefcountedClassAlias = allocateRefcountedClass;
   ```
   
   The existing `arcAllocateRefcounted` stays for the vtable + non-comptime path. The new variant only exists for first-party calls where the codegen passes a comptime class.

2. **Add a runtime dispatcher entry**:
   ```zig
   pub inline fn allocAnyKnown(
       comptime T: type,
       _: usize, // size kept for symmetry; ignored
       _: u32,   // alignment kept for symmetry; ignored
   ) ?[*]u8 {
       const class_index = comptime lookupSlabClass(@sizeOf(T), @alignOf(T));
       const alignment_bytes = @alignOf(T);
       
       if (comptime ACTIVE_MANAGER_TAG == .third_party) {
           // Fallback: dynamic alloc through vtable.
           return allocAny(@sizeOf(T), alignment_bytes);
       } else if (comptime managerHasRefcountV1(ACTIVE_MANAGER_TAG)) {
           return active_manager.allocateRefcountedClass(
               active_manager_state.context.?, class_index, alignment_bytes,
           );
       } else {
           return active_manager.allocateClass(active_manager_state.context.?, class_index, alignment_bytes);
       }
   }
   ```

3. **Codegen change in `src/zir_builder.zig`** (or wherever alloc calls are emitted): when emitting `allocAny(size, alignment)` for a struct allocation where `T` is known, emit `allocAnyKnown(T)` instead. This is the riskiest piece — requires understanding how the codegen tracks per-allocation types.

4. **Stub the new functions in `src/zap_active_manager_stub.zig`** (third-party stub) with panic bodies — they're never called in third-party builds.

5. **Add comptime tests** to pin the new uniform-interface symbols.

**Risk**: codegen changes. Test thoroughly. The runtime's `allocAny` (untyped) path must remain a valid fallback for codegen sites where `T` is not statically known.

### Phase 7e — Hoist startup check out of per-call path (smaller win)

**Goal**: `ensureMemoryStartup()` is called from `allocAny`/`freeAny`/etc. on every alloc/free. The body checks `active_manager_state.started`, returns early if true. But the global load + branch + function call boundary defeats LLVM's CSE.

**Sketch**:
- Add `active_manager_state.started` initialization to a global constructor that runs at program startup (before `main`), so `started == true` is guaranteed inside any user function.
- Remove the per-call check entirely.
- For first-party builds, this is safe — the startup must complete before any allocation.
- For third-party builds, ensure the global constructor is still called.

**Risk**: global-constructor ordering can be fragile. Need to confirm Zig's `comptime { @export(... .init_array)` mechanism (or equivalent) reliably runs before any code in the user binary.

### Phase 8 — Perceus refcount elision (LARGEST candidate, biggest scope)

**Goal**: eliminate redundant retain/release pairs around borrowed references. For Tree.make's `t.left = makeRecursive(...)`, the recursive call's return is moved into `t.left` — no retain needed. For Tree.release's recursive walk, each `t.left`/`t.right` reference is consumed — release pairs cancel.

**Where the work lives**: `src/arc_optimizer.zig` (existing ARC ownership pass) and `src/arc_drop_insertion.zig` (existing drop-insertion pass). These are part of the original ARC pipeline.

**Risk**: significant. The escape/ownership analysis is delicate. Wrong elision = use-after-free in production. This is multi-week work and warrants a separate design phase.

**Recommendation**: do NOT start Phase 8 without explicit user direction. The implementation cost is large and the perf upside is unclear until profiling work confirms the atomic-RC overhead is structural.

---

## How this work was operated

The user requested an autonomous-loop pattern with these invariants:

1. **One job at a time** — each phase dispatched to a fresh subagent.
2. **Gap analysis after every implementation** — dispatched to a separate subagent to maintain an independent perspective.
3. **Resolve gaps iteratively** — followup commits per phase until clean.
4. **Repeat until no gaps remain** — then move to next phase.

The pattern that worked:

```
TaskCreate(Phase N) → TaskUpdate(in_progress)
  → Agent(implementation prompt with strict TDD requirements)
  → Agent(gap-analysis prompt, read-only, requires SECTION A/B/C report)
  → Agent(gap-resolution prompt, single follow-up commit)
  → Agent(second-pass gap analysis, read-only)
  → (if gaps remain: another resolution round)
  → TaskUpdate(completed)
  → next phase
```

**Subagent prompting**: brief like a smart colleague who just walked into the room. Provide architectural context, hard rules, file paths, commit hashes, acceptance criteria, AND what NOT to do. The most common subagent failure mode was scope creep — explicit "do NOT touch X, Y, Z" lists prevented this.

**Verification commands** (use these in every gap-analysis or smoke-test pass):

```bash
# Always-on rule: NEVER run `zig build zir-test` — it's slow and banned.

# Run the host test suite:
cd /Users/bcardarella/projects/zap && zig build test 2>&1 | tail -10
# Expect: 1173/1173 (or higher if you've added tests)

# Rebuild Zap CLI:
cd /Users/bcardarella/projects/zap && zig build install

# Rebuild + run binarytrees ARC:
cd /Users/bcardarella/projects/lang-benches/binarytrees
rm -rf .zap-cache zap-out zap.lock
cp build.zap build.zap.bak
python3 -c "
import re
text = open('build.zap').read()
if re.search(r'^\s*memory:', text, flags=re.MULTILINE):
    text = re.sub(r'memory:\s*[^,\n]+,?', 'memory: \"Zap.Memory.ARC\",', text, count=1)
else:
    text = re.sub(r'(\s+)(paths:)', r'\1memory: \"Zap.Memory.ARC\",\1\2', text, count=1)
open('build.zap', 'w').write(text)
"
/Users/bcardarella/projects/zap/zig-out/bin/zap build binarytrees
echo '--- run 1 ---' && /usr/bin/time -l ./zap-out/bin/binarytrees 21 2>&1 | tail -3
echo '--- run 2 ---' && /usr/bin/time -l ./zap-out/bin/binarytrees 21 2>&1 | tail -3
echo '--- run 3 ---' && /usr/bin/time -l ./zap-out/bin/binarytrees 21 2>&1 | tail -3
mv build.zap.bak build.zap

# Disassemble + count indirect calls:
otool -tV /Users/bcardarella/projects/lang-benches/binarytrees/zap-out/bin/binarytrees > /tmp/disasm.txt
wc -l /tmp/disasm.txt    # instruction count
grep -c "blr" /tmp/disasm.txt   # indirect call count (most are cold)
grep -c "adrp" /tmp/disasm.txt  # global address loads (lower = less dispatcher overhead)

# Verify the runtime source rewrite actually fired:
grep "RUNTIME_ACTIVE_MANAGER_TAG_DEFAULT" /Users/bcardarella/projects/lang-benches/binarytrees/.zap-cache/zap_structs/zap_runtime.zig
# Expect: const RUNTIME_ACTIVE_MANAGER_TAG_DEFAULT: ActiveManagerTag = .arc;

# Verify only one zap_memory_section in the binary (Phase 5 invariant):
nm /Users/bcardarella/projects/lang-benches/binarytrees/zap-out/bin/binarytrees | grep zap_memory_section
# Expect: exactly one line

# Refresh bench matrix (Zap-only, ~3-5 minutes):
cd /Users/bcardarella/projects/lang-benches && bash scripts/bench-zap-managers.sh
# Then: python3 scripts/render-html.py
```

---

## Hard rules (`/Users/bcardarella/projects/zap/CLAUDE.md`)

- **No workarounds, hacks, shortcuts.** Production-grade fixes only.
- **No hardcoded Zap struct names in the Zig compiler** beyond the canonical first-party manager set. The canonical first-party list lives in ONE place (`classifyBuiltinManager` in `src/memory/driver.zig`) and is mirrored consistently in 6 places via tripwires.
- **TDD strictly.** Write failing tests first. Verify they fail. Then implement. Run `zig build test` and confirm green.
- **NEVER run `zig build zir-test`** — banned by user memory. Slow, user runs it themselves.
- **All public Zap functions need `@fndoc` attributes.** All public Zig types/functions in shared modules need clear doc comments. Comments explain WHY, not WHAT.
- **Commit frequently.** Commit after each phase. Use HEREDOC for commit messages.
- **Descriptive names everywhere.** No cryptic short names.

---

## Key file paths

### Source

- `src/memory/driver.zig` — `BuiltinManagerTag` enum, `classifyBuiltinManager`, `builtinManagerDeclaredCaps`/`AbiMinor` tables, `ResolvedManager.builtin_tag`, the first-party short-circuit in `resolve()`.
- `src/compiler.zig` — `runtime_source = @embedFile("runtime.zig")`, the 5 manager `@embedFile`s, `getBuiltinManagerSource`, `getActiveManagerSourceBytes`, `managerSourceUnitName`, `getRuntimeSource(declared_caps, builtin_tag)`, the 3-stage `rewriteRuntimeSource` (instrumentation marker, caps marker, tag marker), `activeManagerTagName`, the ordinal tripwire.
- `src/runtime.zig` — `ActiveManagerTag` enum, `ACTIVE_MANAGER_TAG` pub const, `active_manager_state` global struct, the `managerHasRefcountV1`/`managerHasSizedExtension`/`activeManagerCorePresent`/`activeManagerRefcountCapabilityPresent` comptime classifiers, all dispatcher functions (`allocAny`/`freeAny`/`retainAny`/`releaseAny`/`headerRetain`/`headerRelease`/`refCountAny`/`retainAnyPersistent`), the `@import("zap_active_manager")` at the top, the host-build comptime type-pin test.
- `src/zir_backend.zig` — `CompileOptions.active_manager_source` + `builtin_tag`, the `zir_compilation_add_struct_source("zap_active_manager", ...)` call.
- `src/main.zig` — `buildTarget` + `IncrementalWatchState` — both pass `resolved_manager.builtin_tag` and `compiler.getActiveManagerSourceBytes(tag)` to the ZIR backend.
- `src/zap_active_manager_stub.zig` — third-party stub registered as `zap_active_manager` for `.third_party` builds AND for the host test suite (which always builds with `.third_party`).
- `src/memory/{arc,arena,no_op,leak,tracking}/manager.zig` — each has 11 `pub const X = Y;` aliases at the bottom (uniform interface) + a `comptime { ... }` block pinning aliases against `AbiV1` slot types.
- `build.zig` — registers `src/zap_active_manager_stub.zig` as `zap_active_manager` for the host test build.

### Bench harness (`/Users/bcardarella/projects/lang-benches`)

- `scripts/bench-zap-managers.sh` — dual-manager Zap-only bench script.
- `scripts/run-all.sh` — full cross-language matrix; do NOT run unless you have hours.
- `scripts/measure-rss.sh` — RSS measurement helper used by `run-all.sh`.
- `scripts/render-html.py` — regenerates `results/index.html`.
- `results/zap-managers-Zap_Memory_ARC.txt`, `results/zap-managers-Zap_Memory_Arena.txt` — raw Zap timings + RSS per manager.
- `binarytrees/build.zap` — currently has `memory: "Zap.Memory.ARC"` set (pre-existing local-uncommitted state; left alone).

### Cache (regenerated per build, useful for debugging)

- `/Users/bcardarella/projects/lang-benches/<bench>/.zap-cache/zap_structs/zap_runtime.zig` — the rewritten runtime source for that bench's last build. Inspect to verify `RUNTIME_ACTIVE_MANAGER_TAG_DEFAULT` was rewritten.
- `/Users/bcardarella/projects/lang-benches/<bench>/.zap-cache/zap_structs/zap_active_manager.zig` — the active manager source registered for that build (either a real manager.zig copy or the stub).

### Documentation

- `docs/memory-manager-abi.md` — normative ABI v1.0 spec.
- `docs/pluggable-memory-management-research-brief.md` — original design research (untracked locally).
- `docs/memory-manager-perf-recovery-handoff.md` — **this file**.

---

## Zig fork notes

The fork lives at `/Users/bcardarella/projects/zig`. Build command:

```bash
cd /Users/bcardarella/projects/zig && zig build lib -Doptimize=ReleaseSafe -Denable-llvm=true -Dconfig_h=/Users/bcardarella/zig-bootstrap-0.16.0/out/build-zig-host/config.h
```

The resulting lib lands at `~/projects/zig/zig-out/lib/libzap_compiler.a` (~446 MB with LLVM enabled). Deploy via:

```bash
cp /Users/bcardarella/projects/zig/zig-out/lib/libzap_compiler.a /Users/bcardarella/projects/zap/zap-deps/aarch64-macos-none/libzap_compiler.a
cd /Users/bcardarella/projects/zap && zig build install
```

**LTO is unavailable on Mach-O.** `~/projects/zig/src/target.zig:257` — `hasLldSupport(.macho)` returns false. Don't attempt to re-enable LTO via `Compilation.Config.resolve` — it will fail with `LtoRequiresLld`. LTO IS available on Linux ELF and Windows COFF if Zap ever targets those for perf-critical CI.

The fork's key entrypoints for this work (in `src/zir_api.zig`):
- `zir_compilation_add_struct_source` (~line 292) — registers an in-memory Zig source as a sibling module.
- `addStructSourceImpl` (~line 1383) — writes the source to `<cache>/zap_structs/<name>.zig` and calls `addStructImpl`.
- `addStructImpl` (~line 1275) — registers the file as a `Package.Module` with `parent = ctx.root_mod`. **All registered modules share the same Zcu and the same LLVM IR module**, so LLVM CAN inline across them (this is what makes Option 2 work — confirmed by disassembly).

---

## What this handoff is NOT

- **NOT a perf-recovery plan.** The dispatcher work is mostly tapped out; remaining perf is in atomic-RC / per-T-slab / Perceus domains.
- **NOT an implementation guide for Phase 7d/7e/8.** Sketches are provided; rigorous design + TDD belong to whoever picks it up.
- **NOT a substitute for reading the actual code.** Always read the source before changing it. The commit log is precise; the file paths above are authoritative.

A fresh agent picking up this work should:

1. Read this file in full.
2. Read `CLAUDE.md`, `docs/memory-manager-abi.md`.
3. Run the verification commands above to confirm baseline.
4. Decide whether to start Phase 7d/7e/8 or report back to the user that the current state is acceptable.
5. If continuing, follow the dispatch-implement-gap-analyze-resolve pattern.

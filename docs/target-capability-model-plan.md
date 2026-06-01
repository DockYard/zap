# Language-Level Target-Capability Model — Implementation Plan

Status: **COMPLETE — campaign done, model ENFORCED.** Branch `main`. This document began as
**Phase 0 (design)** of an approved campaign to make **target-conditionality fundamental at the Zap
LANGUAGE level**, not just the Zig implementation. All four phases have landed (see the per-phase
status banners below). Zap now exposes the compilation target to source as comptime atoms (`@target`),
gates declarations on **capabilities** (`@available_on(:cap)`) with a clean compile-time
`target_capability` diagnostic and a comptime-`@target` escape hatch, and the target-sensitive stdlib
surface is swept. The model is **locked in** by two CI tests wired into `zig build test`: the
capability-not-OS-name audit (`src/target_capability_audit.zig`) FAILS the build if any
`@available_on` in `lib/**/*.zap` names an OS instead of a capability (or if the compiler's
gate-decision smuggles an OS-name literal), and the single-source invariant
(`src/target_caps.zig`) pins every runtime-primitive cap (`:signals`/`:terminal`/`:backtrace`) to the
`RuntimeOs.caps` truth for every supported target, so the Zig-codegen caps and the Zap-comptime caps
can never drift. The consolidated verification matrix
(`script_fixtures/run_target_capability_matrix.sh`, `zig build target-capability-matrix`) orchestrates
the audit + single-source + the Phase 1/2/3 acceptance harnesses across native / `wasm32-wasi` /
`x86_64-windows-gnu` as the campaign's standing gate. Native (darwin/aarch64 + linux/x86_64) is the
regression anchor and stays green throughout.

## Principle (non-negotiable)

A Zap feature that does not make sense for a compilation target must fail at **COMPILE TIME, not at
runtime**. Today (verified, file:line below) target-conditionality lives **entirely Zig-side**: the
comptime `runtime_os` seam (`src/runtime_os/{posix,windows,wasi}.zig`, keyed on `builtin.os.tag`) and
the memory capability model (`declared_caps` in `src/memory/abi.zig`). The **Zap language has zero
target awareness** — there is no `@target`/`@os`/`@arch` in Zap source, no capability guard in
`lib/*.zap`, and the stdlib funnels every OS operation straight through `:zig.` primitives
(`lib/system.zap`, `lib/file.zap`). The consequence is exactly the bug this campaign fixes: a feature
unavailable on a target traps at **runtime**, not at the compiler.

Two coupled mechanisms fix it:

1. **Comptime target introspection in Zap** — expose the compilation target (os/arch/abi) to Zap
   source as comptime-known **atoms**, the language analog of Zig's `builtin.os.tag`. Stdlib AND user
   code branch at comptime on the target.
2. **Target-capability gating of declarations** — mark a `def`/`struct`/`macro`/module with the
   target capability it requires, so that on a target lacking it, **referencing the feature is a
   clean COMPILE-TIME error** ("`System.spawn/2` is unavailable on `wasm32-wasi`: this target has no
   process model; it needs `:processes`"), and the stdlib conditionally exposes only target-appropriate
   APIs — instead of a runtime trap.

**THE central design principle (mirrors the memory capability model): gate on CAPABILITIES, not OS
names** — require `:filesystem`/`:processes`/`:signals`/`:network`/`:threads`/`:terminal`, never
`os == :wasi`. A new target works automatically if it has the capability, and diagnostics are
meaningful. **The capability vocabulary is ONE shared set surfaced at BOTH layers**: the `runtime_os`
`caps` that Zig codegen already selects on, AND the new Zap-comptime gating — derived from / unified
with the runtime_os caps, not a parallel vocabulary.

This is consistent with CLAUDE.md: the language feature is implemented in **Zap code** (`@target` is a
comptime intrinsic surfaced to `lib/*.zap`; the gating lives in stdlib `@available_on` attributes and
in the type-checker diagnostic path). The compiler gains exactly one new comptime intrinsic and one
new attribute-semantics pass; it does **not** learn any Zap struct/function name.

## Current state (verified findings, file:line)

### A. The comptime / CTFE machinery (the engine the intrinsic hooks)

- **CTFE is a real, wired IR interpreter.** `src/ctfe.zig` `Interpreter` (init at `:1277`+) executes
  `ir.Program` instructions; `function_by_name: StringHashMap(FunctionId)` supports both `call_direct`
  (by id) and `call_named` (by string). It has **full `if_expr`/`case_block` execution**
  (`execIfExpr`/`execCaseBlock` dispatched at `src/ctfe.zig:1849-1850`), with `bool_val` produced by
  every comparison op. **So comptime-`if` branching on a target-derived atom needs NO new machinery —
  only the `@target` value as a `CtValue`.**
- **Atoms are first-class comptime values.** `CtValue.atom: []const u8` (`src/ctfe.zig:77`) and
  `ConstValue.atom` (`:329`), with `const_atom` IR (`:805`). So `@target.os` returning `:darwin`/
  `:wasi` is directly representable.
- **CTFE attribute evaluation is the per-decl comptime hook.** `evaluateComputedAttributes`
  (`src/ctfe.zig:4505`) / `evaluateStructAttributesInOrder` (`:4575`) walk
  `graph.structs[].attributes` and `graph.families[].attributes`, calling `tryEvalAttribute`
  (`:4731`) → `evaluateConstExpr` which runs the attribute's `value` `Expr` through the `Interpreter`.
  This is where `@available_on(...)` / a `@target`-using attribute is evaluated.
- **Invoked from the main build path with the compile options in hand.** `Pipeline.runCtfeAttributes`
  (`src/compiler.zig:4210`) calls those, threading `self.options` (`cache_dir`,
  `ctfeCompileOptionsHash(self.options)`). The target string is already available here.
- **There is NO existing `@target`/`@os`/`@arch` intrinsic** anywhere in `src/parser.zig`,
  `src/desugar.zig`, `src/hir.zig`, `src/ir.zig`, or `src/ctfe.zig` (confirmed — the only `os`/`arch`
  tokens are the Zig-side `os_tag`/`arch_tag` target-triple parsing). The prior grep is confirmed: no
  intrinsic surfaces compiler/target/build state to Zap source today.

### B. The attribute mechanism (the vehicle for the gate)

- **Parsing.** `Parser.parseAttributeDecl` (`src/parser.zig:2270`) produces an
  `ast.AttributeDecl` = `{meta, name: StringId, type_expr: ?*TypeExpr, value: ?*Expr}` (`src/ast.zig:655`).
  Four forms exist: typed `@name :: Type = value`, valued `@name = value`, the scoped bareword
  `@code Z3041` (`:2331`, the only special-cased name), and marker `@name` (null value). An
  attribute taking an **atom value** — `@available_on(:filesystem)` desugared to `@available_on = :filesystem`
  or a call form — is fully supported by the valued path.
- **Storage.** `scope.Attribute` (`src/scope.zig:414`) = `{name, value: ?*Expr, computed_value:
  ?ConstValue, accumulate}`. Both `StructEntry` (struct-level, `:428`) and function families (`:450`)
  and `macro_families` carry `attributes: ArrayListUnmanaged(Attribute)`. Zap can even append
  attributes itself (`Struct.put_attribute`/`register_attribute`, `src/scope.zig:1073`+).
- **`@native` is the existing "decl present, body elsewhere" precedent.** `@native` marks a bodyless
  `def` whose implementation is a named runtime binding (parser.zig bodyless path; resolver.zig:196;
  types.zig). It proves a decl can be **present in the scope graph and resolve specially** — the same
  shape a capability-gated decl needs (present, but unavailable on this target).
- **CRITICAL COLLISION:** **`@requires` was a real attribute and is now explicitly REJECTED on
  macros** (`src/collector.zig:483-498`): "`@requires` is no longer supported — compile-time
  capabilities are inferred from the macro body's call graph (see `capability_inference.zig`)." That
  was the **CTFE-capability** annotation (which CTFE side-effects a macro may perform), unrelated to
  *target* capabilities. The new attribute MUST NOT reuse the bare name `@requires` for macros. The
  design uses **`@available_on(...)`** as the primary spelling (see Decisions).

### C. The type-checker / name-resolution error path (where the clean error lands)

- **Unqualified call resolution failure** is at `src/types.zig:8812-8842`: when no family matches,
  it collects visible names, runs `similarity.findBestMatch`, and emits
  `"I cannot find a function named `{name}/{arity}`"` + `"did you mean `X/d`?"`.
- **Struct-qualified call** (`IO.puts(...)`, `System.spawn(...)`) is the `.field_access` callee branch
  at `src/types.zig:8846`+ (handles `:zig.` bridge calls via `isZigBridgeCall`, etc.).
- Spelling-suggestion diagnostics for undefined names live alongside (`:9524`, `:9556`, `:7324` for
  variables; the auto-fix note at `:12297`). The canonical diagnostic record is `diagnostics.Diagnostic`
  generalized into the `src/error_ir.zig` schema (`Domain`/`Applicability`/`FixIt`/related-spans).
- **The gating insight:** a capability-gated-out decl must be **present** in the scope graph (so the
  resolver can tell "gated out for this target" from "misspelled") but flagged unavailable, so the
  resolver emits the *capability* diagnostic instead of "not found." This is a new arm in the
  resolution path, NOT a change to the "not found" arm.

### D. Stdlib conditional exposure (the surface that must gate)

- `lib/system.zap` and `lib/file.zap` funnel **every** OS op unconditionally through `:zig.` bridge
  calls (`System.arg_count → :zig.System.arg_count()` at `lib/system.zap:21`; `File.read →
  :zig.File.read(path)` at `lib/file.zap:26`; etc.). **No `comptime`, no `@target`, no capability
  guard anywhere in `lib/*.zap`.** Confirmed.
- The module/struct system supports `pub fn` members inside `pub struct` with `@doc` (and other
  attributes) immediately preceding. A `@available_on(:processes)` attribute on a `def` is the
  natural per-API gate; a comptime-`if` inside a `def` body is the natural per-implementation branch.
- The source-graph resolver (`src/builder.zig`) and collector already process these per-struct, so a
  gated decl is visible to the attribute evaluator at the right point.

### E. The capability vocabulary (the ground truth to unify with)

- **`runtime_os` caps** (the Zig-layer ground truth of what a target's *embedded runtime* supports),
  per backend `caps` struct:
  - `src/runtime_os/posix.zig:41-60`: `supports_signals=true`, `supports_termios=true`,
    `supports_backtrace = std.debug.SelfInfo != void`, `console_handle = std.posix.fd_t`; plus
    `supports_fault_handlers` (`:389`).
  - `src/runtime_os/wasi.zig:26-46`: `supports_signals=false`, `supports_termios=false`,
    `supports_backtrace`, `console_handle = std.os.wasi.fd_t`; `supports_fault_handlers=false` (`:356`).
  - `src/runtime_os/windows.zig:31-56`: `supports_signals=true` (VEH), `supports_termios=false`,
    `console_handle = std.os.windows.HANDLE`; `supports_fault_handlers=true` (`:776`).
- **Memory `declared_caps`** (`src/memory/abi.zig`): the precedent for capability-gating-done-right —
  a `u64` bitmask the backend declares, the compiler reads the bits never the name
  (`elision.reclamationModel(caps)`), validated at build (`driver.zig`).
- **CTFE `CapabilitySet`** (`src/ctfe.zig:430-463`): the model shape — `{flags: u8}` with
  `has()`/`with()`/`isSubsetOf()` (caller→callee attenuation) and `capabilityFromAtomName` mapping an
  atom name → a `Capability` enum (`pure`/`read_file`/`read_env`/`reflect_struct`/`reflect_source`).
  This gates *what a CTFE evaluation may do*; the new model reuses this **exact shape** for *what the
  target supports*.

### F. How the TARGET reaches the frontend (the threading path)

- CLI `-Dtarget=<triple>` → `parseBuildOverrides` (`src/main.zig:1086`) → `applyBuildOverrides`
  (`:1175` sets `config.target`) → `builder.BuildConfig.target` (`src/builder.zig:39`) → the shared
  `compileAndLink` tail → `CompileOptions.target` (`src/zir_backend.zig:313`, a `?[]const u8` triple
  string) → `zir_compilation_create_cross` to the fork. Host default = `builtin.target`
  (`src/main.zig:604`).
- **The triple is parsed into os/arch/abi enums** by `src/memory/driver.zig:1272`
  `parseTargetTriple → ZapForkTarget{arch_tag, os_tag, abi_tag}` (`:45`), using
  `std.Target.{Cpu.Arch,Os.Tag,Abi}` and `defaultAbiForTriple` (`:1310`). This is the reusable
  triple→atom mapping.
- **The compile target ALREADY reaches the CTFE layer's options.** `CompileOptions`
  (`src/compiler.zig:280`) carries `ctfe_target: ?[]const u8` (`:304`), set on the **main project
  build path** from `inputs.target_name` (`src/main.zig:5637`, where `target_name` is
  `inputs.target_name` at `:5356`, ultimately the `buildTarget(..., target, …)` argument
  `parsed.target orelse "default"`). It is fed to `ctfeCompileOptionsHash →
  ctfe.hashCompileOptions(ctfe_target, ...)` (`src/ctfe.zig:710`) for cache-keying. So a
  `@target`-dependent CTFE result is **already correctly cache-keyed per target**
  (`CTFE_SCHEMA_VERSION`-versioned), and the value carried is the **requested** target. It is used
  only for hashing today — not yet surfaced as a value.
- **Native ("default"/`""`) must be resolved to the host triple.** On a native build `ctfe_target`
  is `"default"`/`""` (and `CompileOptions.target` at `zir_backend.zig:313` is null = native), so
  Phase 1 must resolve that to the actual host triple via `builtin.target` *before* mapping to atoms
  — otherwise `@target.os` is unresolvable on the native path (the regression anchor). The cross path
  carries a real triple that `parseTargetTriple` resolves directly.
- **The strongest precedent: `%Zap.Env` already surfaces os/arch as atoms to CTFE.**
  `src/builder.zig:311-322` constructs `%Zap_Env{target: :triple, os: :os, arch: :arch}` (atoms!) and
  passes it to the build-manifest function `Project.Builder.project(env)` via `interp.evalAndExport`.
  **BUT** os/arch use the **HOST** `builtin.os.tag`/`builtin.cpu.arch` (`:312-313`), NOT the requested
  cross-compile target — a latent bug, and the exact precedent the `@target` intrinsic generalizes and
  corrects (it must report the *requested* target).

**Summary of the hook:** the target string already reaches `CompileOptions.ctfe_target`; the work is
(1) parse it into os/arch/abi atoms (reuse `parseTargetTriple`'s `std.Target` mapping), (2) thread
those into `evaluateComputedAttributes`/the `Interpreter` so `@target` is a `CtValue`, (3) derive the
target capability set from the os/arch (the runtime_os-caps unification), and (4) add the gating pass +
the type-checker diagnostic arm. No fork C-ABI change is needed.

## The unified capability vocabulary

One shared set, surfaced at both layers. **Ground truth = the target's runtime_os caps + the
target's `std.Target` facts** (process model, networking, threads). The Zap-level capability atom maps
to a comptime predicate over (os, arch, abi) derived from the runtime_os cap table and `std.Target`:

| Zap capability atom | Meaning (what the target supports) | Derived from (ground truth) | posix | windows | wasi(p1) |
|---|---|---|---|---|---|
| `:filesystem` | open/read/write/stat paths | `std.fs` works (Phase-B portable file I/O); wasi gated behind preopens but present | yes | yes | yes (preopen) |
| `:processes` | spawn/fork/exec a child process | a process model exists (POSIX fork/exec, Win32 CreateProcess); **wasi preview1 has none** | yes | yes | **no** |
| `:signals` | hardware-fault / async signal handling | `runtime_os` `caps.supports_signals` (posix sigaction, windows VEH, wasi none) | yes | yes (VEH) | **no** |
| `:terminal` | raw-mode TTY / termios | `runtime_os` `caps.supports_termios` (posix termios; windows console-mode partial; wasi none) | yes | partial | **no** |
| `:network` | sockets / TCP / UDP | a socket layer exists (POSIX/Winsock); **wasi preview1 has no sockets** (preview2 differs) | yes | yes | **no** |
| `:threads` | OS threads / shared-memory concurrency | threads exist (pthreads/Win32); **wasm32 single-threaded without the `atomics`+`bulk-memory` features / wasi-threads** | yes | yes | **no (v1)** |
| `:backtrace` | symbolized stack traces | `runtime_os` `caps.supports_backtrace` (`std.debug.SelfInfo != void`) | target-dep | target-dep | target-dep |

**Two tiers, derived not duplicated:**
- **Runtime-primitive caps** (`:signals`, `:terminal`, `:backtrace`) map **directly** to the
  `runtime_os` `caps` booleans — the SAME constant the Zig codegen seam already selects on. There is
  no second source of truth: the Zap-level `:signals` is defined as the comptime value of
  `RuntimeOs.caps.supports_signals` for the resolved target.
- **Language-domain caps** (`:filesystem`, `:processes`, `:network`, `:threads`) are derived from
  `std.Target` facts about the os/arch (process model, socket layer, thread model) — the same facts
  the fork's `std.Target` already encodes. For the three targets the runtime already supports
  (posix/windows/wasi) the table above is the authoritative mapping; a new target's row is computed
  from its `std.Target` os/arch, so **a target gains a capability automatically when its `std.Target`
  facts say it has it** — never by editing an OS-name allowlist.

This mirrors the memory model exactly: a `u64`/bitset of capability bits, the compiler reads the bits,
the diagnostic names the missing capability (`:processes`), never the OS.

**Forward-compat with the per-process concurrency model.** `:threads` and `:processes` are the knobs
the planned BEAM-style per-process model will read (a short-lived process can be `Arena`-backed; the
target's `:threads`/`:processes` capability decides whether the runtime can host OS-thread-backed or
process-backed schedulers). Reserving these atoms now keeps the vocabulary stable when concurrency
lands; nothing in v1 *requires* them beyond gating (e.g. a future `System.spawn` gates on `:processes`).

## The surface syntax / semantics (Zap-native)

### 1. Comptime `@target` introspection

`@target` is a **comptime intrinsic** evaluating to a struct of atoms `{os, arch, abi}` (the language
analog of `builtin.os.tag`). It is usable anywhere CTFE runs — attribute values and comptime-`if`:

```zap
@doc = """
  Returns the current working directory.
  """

pub fn cwd() -> String {
  if @target.os == :wasi {
    # WASI has no canonical cwd; degrade at COMPILE TIME (this branch
    # is the only one compiled on wasi — the :zig. branch is elided).
    ""
  } else {
    :zig.System.cwd()
  }
}
```

`@target.os`/`@target.arch`/`@target.abi` return atoms (`:darwin`, `:wasi`, `:windows`; `:aarch64`,
`:x86_64`, `:wasm32`; `:gnu`, `:musl`, `:none`). Because CTFE already executes `if_expr` over
`bool_val`, the `if` folds at compile time: the dead branch's body (including any `:zig.` call that
would not link on the target) is never lowered. This is the **comptime branching** the stdlib uses to
adapt an implementation per target without runtime cost.

A convenience macro in `lib/kernel.zap` may wrap the common shape (mirroring how `if`/`unless` are
Kernel macros), e.g. `target_case`, but the primitive is `@target` + the existing `if`.

### 2. `@available_on(...)` capability gating of declarations

A `def`/`struct`/`macro` is marked with the **capability** it needs. On a target lacking it, the decl
is **absent from the usable surface** and *referencing* it is a clean compile error:

```zap
pub struct System {
  @doc = """
    Spawns a child process running `command` with `args`.
    """
  @available_on(:processes)

  pub fn spawn(command :: String, args :: List(String)) -> Result(i64, Error) {
    :zig.System.spawn(command, args)
  }
}
```

Semantics:
- `@available_on(:processes)` (one or more capability atoms) on a declaration means "this declaration
  exists only on targets that have ALL listed capabilities." On a target with the capability it
  behaves exactly as today (zero cost — the attribute is comptime-resolved and erased). On a target
  lacking it, the decl is **gated out**: present in the scope graph as a sentinel "unavailable here"
  entry, so a reference produces the capability diagnostic.
- A `struct`-level `@available_on(:filesystem)` gates the whole module (every member inherits the
  requirement) — the natural way to gate `IO.File` wholesale.
- The attribute value is an atom (or list of atoms), evaluated by the existing CTFE attribute
  evaluator; an unknown capability atom is a precise compile error at the attribute's span (mirroring
  `CapabilitySet.capabilityFromAtomName` returning null → diagnostic).

**Why `@available_on` and not `@requires`:** `@requires` is a retired attribute that the collector
**actively rejects on macros** (`src/collector.zig:490`, the CTFE-capability annotation now inferred
from the call graph). Reusing the bare name would resurrect a rejected spelling and conflate
target-capabilities with CTFE-eval-capabilities. `@available_on` reads naturally ("available on
targets with `:processes`") and is unambiguous.

## The compile-error gating design

The deep part. A reference to a capability-gated-out decl must be a **clean COMPILE error**, distinct
from "undefined name."

**Mechanism (decl present-but-unavailable, mirroring `@native`):**
1. **Collect + evaluate the gate.** During CTFE attribute evaluation (`evaluateComputedAttributes`,
   now target-aware), each decl carrying `@available_on(:cap, …)` has its required-capability set
   computed. The compiler intersects it with the **target's capability set** (derived per §"unified
   vocabulary"). If the target has all required caps → the decl is fully available (attribute erased,
   zero cost). If not → the decl's scope-graph family/struct entry is marked
   `gated_out = .{ .missing = :cap, .target = <triple> }` (a new optional field on the scope entry,
   alongside the existing attribute storage).
2. **Resolution emits the capability diagnostic.** In the type-checker resolution path
   (`src/types.zig:8812` unqualified, `:8846` struct-qualified), **before** the "I cannot find a
   function named X/d" arm, check whether a family with that name+arity exists but is `gated_out`. If
   so, emit:

   ```
   error: `System.spawn/2` is unavailable on `wasm32-wasi`
     --> app.zap:12:3
      |
   12 |   System.spawn("ls", [])
      |   ^^^^^^^^^^^^^^^^^^^^^^^ this target has no process model
      |
      = note: `System.spawn/2` requires the `:processes` capability
      = help: guard the call with `if @target.os != :wasi { … }`, or build for a target with a process model
   ```

   This is a distinct diagnostic (`Domain` = a new `target_capability` domain in `error_ir.zig`),
   **not** the spelling-suggestion path — the name resolved, so there is no "did you mean?".
3. **It differs from "undefined" precisely because the decl IS defined** — it is present in the graph
   with a `gated_out` marker. "Undefined" stays for genuinely-misspelled/absent names. The two arms
   are mutually exclusive (gated-out short-circuits before the not-found collection).

**Comptime-`if`-guarded references are NOT errors.** If the reference is inside a comptime-`if` branch
that is dead on this target (`if @target.os != :wasi { System.spawn(…) }` built for wasi), the branch
is elided **before** ZIR lowering, so the gated-out reference never reaches the resolver's live path —
no error. This is the escape hatch: a gate is a compile error only on a **live** reference. (Stdlib
that internally guards a `:zig.` call with `@target` therefore compiles cleanly on every target.)

## Integration

- **CTFE / comptime.** `@target` is a new IR/CtValue intrinsic: the frontend lowers `@target.os` to a
  `const_atom` whose value is the resolved target's os tag (threaded from `CompileOptions.ctfe_target`
  via `parseTargetTriple` into the `Interpreter`). The existing `if_expr`/`case_block` execution folds
  the branch. Cache-keying is already correct (`hashCompileOptions` includes the target).
- **The attribute system.** `@available_on` is parsed by the existing `parseAttributeDecl` (valued/
  call form), stored on the existing `scope.Attribute` list, and evaluated by the existing CTFE
  attribute evaluator — no new parser surface beyond accepting the attribute name; the
  capability-atom → bit mapping mirrors `CapabilitySet.capabilityFromAtomName`.
- **The type checker.** One new resolution arm (`gated_out` short-circuit) + one new diagnostic
  domain. The scope entry gains one optional `gated_out` field. No change to the not-found path.
- **The stdlib.** `lib/system.zap`/`lib/file.zap` gain `@available_on` attributes on target-sensitive
  APIs and/or comptime-`if` inside bodies; `lib/kernel.zap` may gain a `@target`-wrapping convenience
  macro. The `:zig.` bridges stay; they are simply only reached on capable targets.
- **runtime_os unification.** The Zap `:signals`/`:terminal`/`:backtrace` atoms are *defined as* the
  comptime value of the corresponding `RuntimeOs.caps` boolean for the resolved target — a single
  source of truth shared with the codegen seam. A new helper (`src/target_caps.zig`) maps a
  `ZapForkTarget`/`std.Target` → the capability bitset, consulting the runtime_os cap table for the
  runtime-primitive caps and `std.Target` for the language-domain caps.
- **Forward-compat with per-process concurrency.** `:threads`/`:processes` reserved now; the
  per-process scheduler reads them to decide what runtime hosting a target permits.

## Phase breakdown (ordered; each independently verifiable; native-green throughout)

Native (darwin/aarch64 + linux/x86_64) has **every** capability, so every gate is satisfied and the
native corpus is the regression anchor at each phase. Verification **never** uses `zig build zir-test`
(the user runs it). "Foreign build" = cross-build a fixture, `file` the artifact, run under
`wasmtime` where a runner exists (the existing Phase-A..D portability harness pattern).

### Phase 1 — comptime `@target` introspection
**Status: COMPLETE.** `@target.os`/`.arch`/`.abi` are comptime atoms surfaced to Zap source
(`src/target_triple.zig` resolves the requested triple — or the native sentinel → host triple — to
`{os, arch, abi}` atom names; `src/hir.zig` / `src/target_fold.zig` fold `@target.<field>` over them so
a `case`/`if` collapses at compile time and the dead branch is elided before ZIR lowering). The
requested target is threaded into the comptime layer across all build paths, and the latent
`%Zap.Env` host-vs-target bug (`src/builder.zig`) is fixed (the build-manifest env now reports the
*requested* target, not the host). Verified by `script_fixtures/run_target_comptime_acceptance.sh`:
native folds the host branch; `wasm32-wasi` cross-builds + runs under `wasmtime` printing the wasi
branch (proving the value is the requested target); `x86_64-windows-gnu` links `PE32+`; the dead-branch
`:zig.` elision and `%Zap.Env` requested-target reporting both hold. Native green throughout.

**Goal:** `@target.os`/`.arch`/`.abi` are comptime atoms usable in `if`, folding per target.
- Add the `@target` intrinsic: parser/desugar recognition → an IR form the CTFE interpreter resolves
  to a `const_atom` from the threaded target. Thread `CompileOptions.ctfe_target` (parsed via
  `parseTargetTriple`, reusing `src/memory/driver.zig`'s `std.Target` mapping) into
  `evaluateComputedAttributes`/`Interpreter`. **Fix the `%Zap.Env` host-vs-target bug**
  (`src/builder.zig:312-313`) to report the requested target as part of this.
- **Done =** native green (`zig build test` + `zap test` corpus + golden); a fixture
  `if @target.os == :darwin { … } else { … }` evaluates the correct branch natively; the same fixture
  cross-built for `wasm32-wasi` folds the wasi branch and **runs** under `wasmtime` (proving the
  comptime value is the *requested* target, not the host). **Verify WITHOUT `zir-test`:** `zap run`
  the fixture natively; cross-build + `wasmtime` for wasi.

### Phase 2 — `@available_on` attribute + compile-error gating + gate ONE real API
**Status: COMPLETE.** `src/target_caps.zig` is the unified capability vocabulary
(`ZapForkTarget`/`std.Target` → capability bitset; runtime-primitive caps single-sourced from the
`runtime_os` backends, language-domain caps derived from `std.Target` facts). The gate is applied
AST-first, before type-checking (`compiler.zig`'s `applyTargetCapabilityGate` → `ctfe.zig`'s
`gateAvailableOn`), marking each `@available_on`-gated decl `gated_out` on a target lacking a required
capability; name resolution then emits the distinct `target_capability` diagnostic (a new
`error_ir.zig` domain) on a live reference — naming the API, the target, the missing capability, and the
`@target` guard hint — never the "undefined" path. The comptime-`@target` escape hatch elides a dead
guarded reference pre-lowering, so it does not error. `@available_on` on a macro is a rejected category
error. `IO.get_char/0` (and the `IO.mode` cluster) gate on `:terminal`. Verified by
`script_fixtures/run_target_capability_acceptance.sh` (gated-out compile error on wasi AND windows —
capability-keyed, not OS-keyed; escape hatch compiles + runs under `wasmtime`; native zero-impact;
genuine-undefined unaffected; unknown-cap + macro-gate errors; arity broadcast; struct-level gate).
Native green.

**Goal:** `@available_on(:cap)` on a `def` produces a clean compile error when referenced on a lacking
target; prove it by gating `System.spawn` (or, until a spawn exists, a purpose-built stdlib API) on
`:processes`.
- Add `src/target_caps.zig` (the unified vocabulary: `ZapForkTarget`/`std.Target` → capability
  bitset, runtime-primitive caps from `RuntimeOs.caps`, language-domain caps from `std.Target`).
- Wire the gate evaluation into the CTFE attribute pass; add the `gated_out` scope-entry field; add
  the type-checker resolution arm + the `target_capability` diagnostic domain in `error_ir.zig`.
- Gate one real target-sensitive stdlib API on `:processes` (and add the API if none exists yet — a
  spawn primitive is the canonical motivating case).
- **Done =** native green (the gated API works natively); a fixture that references the gated API
  **fails to compile** for `wasm32-wasi` with the exact `:processes` diagnostic (asserted by an
  expected-compile-error harness, e.g. a `zap run --target=wasm32-wasi` that must exit non-zero with
  the diagnostic text); the SAME reference inside `if @target.os != :wasi { … }` **compiles** for wasi
  (the comptime-guard escape hatch). **Verify WITHOUT `zir-test`:** expected-error harness + the
  guarded-compiles fixture.

### Phase 3 — sweep the target-sensitive stdlib surface
**Status: COMPLETE.** The target-divergent stdlib surface is swept: the IO raw-mode terminal-input
cluster (`IO.mode/1`, `IO.mode/2`, `IO.get_char/0`, `IO.try_get_char/0` in `lib/io.zap`) is gated on
`:terminal`, with the gate broadcast across arities by the collector so a caller cannot bypass via an
un-annotated arity. The remaining stdlib OS surface (`lib/file.zap` File I/O) is `:filesystem`, which is
present on every supported target (wasi via preopens), so it is correctly NOT gated — proven by the
over-gating guard. Verified by `script_fixtures/run_target_capability_phase3_acceptance.sh`: each swept
API is a compile error on wasi AND windows (capability-keyed); the escape hatch compiles + runs under
`wasmtime`; a wasi-CAPABLE program (File/String/List/IO.puts) cross-builds + runs under `wasmtime` (no
over-gating); native zero-impact across the whole cluster. Native green.

**Goal:** every target-divergent stdlib API in `lib/*.zap` is correctly gated or comptime-branched, so
the stdlib exposes only target-appropriate APIs and no `:zig.` bridge can be reached on a target whose
runtime would trap.
- Audit `lib/system.zap`, `lib/file.zap` (and any networking/terminal surface) against the capability
  table; apply `@available_on` (struct- or def-level) and/or comptime-`if` per API. `IO.File` gates on
  `:filesystem`; termios/raw-mode IO on `:terminal`; any signal-dependent API on `:signals`.
- **Done =** native green (full corpus); a `wasm32-wasi` build of a program using only
  capability-appropriate stdlib APIs cross-builds + runs under `wasmtime`; a program using a gated-out
  API fails to compile with the capability diagnostic. **Verify WITHOUT `zir-test`:** the corpus + the
  foreign-build harness + an expected-error fixture per gated domain.

### Phase 4 — lock-in: capability-not-name audit + verification matrix
**Status: COMPLETE.** The model is ENFORCED. (1) The capability-not-OS-name audit
(`src/target_capability_audit.zig`, wired into `zig build test` + the standalone
`zig build target-capability-audit`) scans EVERY stdlib source (`lib/**/*.zap` — enumerated from the
tree by `build.zig` and embedded via a generated manifest, so a new lib file is audited automatically
with no hand-maintained list) and FAILS the build if any `@available_on(:atom)` names something that is
not a capability — an OS name (`:wasi`/`:windows`/`:linux`/…) or a typo — judged against the SAME
`target_caps.capabilityFromAtomName` single source of truth the compiler gate uses; it also scans the
`@available_on` gate-DECISION region of `src/ctfe.zig` (delimited by `ZAP_TARGET_GATE_DECISION_BEGIN`/
`END`) and FAILS on a smuggled OS-name string literal, since the gate must decide via the capability
bitset (`firstMissingFrom`), never an OS-name comparison. *Proven:* planting `@available_on(:wasi)` in
`lib/io.zap` makes the audit FAIL naming `lib/io.zap:204: names an OS, not a capability`; reverting
PASSES. (2) The single-source invariant (`src/target_caps.zig`) pins every runtime-primitive cap
(`:signals`/`:terminal`/`:backtrace`) to the `RuntimeOs.caps` truth for every supported target
(linux/macos/windows/wasi). `:backtrace` is pinned two ways — to the governing backend's
`supports_backtrace` const for the host row, and to an independent recomputation of the same
`std.Target.ObjectFormat.default` → `SelfInfo` selection for every row — so a desync of
`targetSupportsBacktrace` is a compile-time test failure (proven by a plant→fail→revert). (3) The
consolidated matrix (`script_fixtures/run_target_capability_matrix.sh`,
`zig build target-capability-matrix`) orchestrates the audit + single-source + the Phase 1/2/3
acceptance harnesses across native / `wasm32-wasi` / `x86_64-windows-gnu` and is all-PASS (5/5). The
campaign is sealed. **No fork C-ABI change was needed.**

**Goal:** prove the gating keys off capabilities, never OS names, and lock the matrix.
- Audit: no Zap struct/function name and no bare OS-name comparison drives the gate in `src/*.zig` —
  every gate reads `target_caps` bits (mirroring the memory-model `no-name-special-casing` audit).
  A custom/hypothetical new target with a given capability profile gets the right gating purely from
  its `std.Target`/runtime_os caps.
- Add a CI assertion (a Zig test, like `src/runtime_os_portability_gate.zig`) that the capability
  vocabulary is single-sourced (the Zap `:signals`/`:terminal`/`:backtrace` atoms equal the
  `RuntimeOs.caps` booleans for each target).
- **Done =** native green; the matrix harness asserts: native (all caps, every gate satisfied);
  `wasm32-wasi` (gated-out `:processes`/`:signals`/`:network`/`:terminal`, available `:filesystem`);
  `x86_64-windows-gnu` (`:signals` via VEH, no `:terminal`) — each via cross-build + (where possible)
  run. **Verify WITHOUT `zir-test`.**

## Decisions (defaults proposed; confirm before Phase 1)

1. **`@target` shape** — a comptime struct `{os, arch, abi}` of atoms, accessed `@target.os` etc.
   (analog of `builtin.os.tag`). Atoms, not strings, so they compare cleanly in `if`/`case`. Confirm
   vs. three separate intrinsics `@os`/`@arch`/`@abi` (the struct is tidier and extensible).
2. **Gate attribute name = `@available_on(:cap, …)`** — NOT `@requires` (retired + rejected on macros
   for CTFE capabilities, `src/collector.zig:490`). Confirm the spelling. (Alternatives considered:
   `@requires_capability` — verbose; `@cfg`/`@target_only` — non-Zap-native, OS-name-flavored,
   rejected.)
3. **Capability-not-OS, single-sourced.** Runtime-primitive caps (`:signals`/`:terminal`/`:backtrace`)
   are DEFINED as the `RuntimeOs.caps` booleans (no second source); language-domain caps
   (`:filesystem`/`:processes`/`:network`/`:threads`) derived from `std.Target` os/arch facts.
   `src/target_caps.zig` is the single mapping. Confirm the initial vocabulary set.
4. **Gated-out decls are present-but-unavailable** (mirroring `@native`): a `gated_out` scope marker,
   resolved to the capability diagnostic — distinct from "undefined." The comptime-`if`-guarded dead
   reference is elided pre-lowering and never errors (the escape hatch). Confirm.
5. **Native is the regression anchor.** Native has every capability; every gate satisfied; full
   `zig build test` + `zap test` green at every phase. Confirm.
6. **No fork C-ABI change.** The target already reaches `CompileOptions.ctfe_target`; the triple→atom
   mapping reuses `parseTargetTriple`'s `std.Target` enums; no new fork primitive. Confirm (a fork
   touch would only be needed if `std.Target` lacked a fact we need, which it does not).

## Risks

- **The type-checker + comptime integration is the deep part** (highest). Threading the resolved
  target into the CTFE interpreter as `@target`, and adding the `gated_out` resolution arm without
  perturbing the existing not-found / suggestion path, is the core surgery. *Mitigation:* the target
  already reaches `CompileOptions.ctfe_target` and the CTFE `if_expr` execution already exists, so the
  comptime value is a small addition; the gating arm short-circuits *before* the not-found arm, so the
  existing diagnostics are untouched; full native corpus gates every phase.
- **Getting the diagnostic right** (medium). It must name the capability (`:processes`), the target,
  and the guard hint — and must NOT fire on comptime-`if`-guarded dead references. *Mitigation:* dead
  branches are elided pre-resolution (the `@target` `if` folds in CTFE), so only live references reach
  the gate; the diagnostic is a distinct `error_ir.zig` domain with a fixed shape.
- **`@requires` collision** (low but sharp). The retired macro-`@requires` rejection
  (`src/collector.zig:490`) means the new attribute must not reuse the name. *Mitigation:*
  `@available_on` is the chosen distinct spelling; Phase 2 adds a test that `@available_on` on a macro
  is accepted (target gating) while bare `@requires` stays rejected (CTFE-capability).
- **Not breaking native** (low but unacceptable if it happens). Native has every capability, so every
  gate is a no-op and every comptime-`if` target branch picks the native arm. *Mitigation:* the
  attribute is comptime-erased when satisfied; native corpus is byte-for-byte the regression anchor.
- **Capability vocabulary completeness** (low-medium). The initial set
  (`filesystem`/`processes`/`signals`/`network`/`threads`/`terminal`/`backtrace`) must cover the
  real divergences without over-fragmenting. *Mitigation:* it is derived from the runtime_os caps +
  `std.Target` facts that already exist; new atoms can be added (the bitset has room), and a custom
  target gains caps automatically from its `std.Target`.
- **The `%Zap.Env` latent host-vs-target bug** (low, but must be fixed in Phase 1). The build-manifest
  env currently reports the HOST os/arch (`src/builder.zig:312-313`); fixing it is part of making
  `@target` report the requested target consistently.

## Effort estimate (per phase)

Rough, assuming the native-green-at-every-phase discipline and the full corpus gate.

- **Phase 1 (`@target` intrinsic + CTFE threading + `%Zap.Env` fix):** medium — small additions
  riding existing CTFE `if`/atom machinery, but touches parser/desugar/ir/ctfe + the build-env wiring.
  ~2-3 focused days.
- **Phase 2 (`@available_on` + gating + diagnostic + one real API):** large — the deep type-checker
  arm, the new `src/target_caps.zig` vocabulary, the diagnostic domain, the gated-out scope marker,
  the expected-error harness, plus the motivating spawn API. ~4-6 days.
- **Phase 3 (stdlib sweep):** medium — mechanical per-API once the machinery exists, but a careful
  audit of every target-divergent surface + per-domain foreign-build verification. ~2-4 days.
- **Phase 4 (lock-in audit + matrix):** small-medium — the capability-not-name audit, the
  single-sourcing CI test, the matrix harness. ~1-2 days.

Total: ~9-15 focused days, Phase 2 the dominant and deepest.

## Verification matrix (per phase)

| Target | Build | Capability profile | Run check |
|---|---|---|---|
| darwin/aarch64 (native) | `zig build test` + `zap test` corpus + golden | all caps | full corpus green, **every phase** |
| linux/x86_64 (native) | `zig build test` + `zap test` | all caps | corpus green |
| wasm32-wasi | cross-build a fixture | `:filesystem` only; no `:processes`/`:signals`/`:network`/`:terminal`/`:threads` | `wasmtime` runs a capable fixture; a gated-out reference **fails to compile** with the `:cap` diagnostic; a comptime-guarded reference compiles |
| x86_64-windows-gnu | cross-build a fixture | `:signals`(VEH), `:filesystem`, `:processes`, `:network`; no `:terminal` | `file` → `PE32+`; gated-out reference fails to compile; run under wine if available |

**Never `zig build zir-test`** (the user runs it). Validate through the ZIR path (the only codegen
path) and the expected-compile-error harness — not generated-source strings.

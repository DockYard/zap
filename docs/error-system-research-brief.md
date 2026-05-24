# Research Brief: A First-Class, Production-Grade Error System for the Zap Programming Language

**Audience:** A deep-research agent or new contributor with **zero prior context** on Zap, its
compiler, or its Zig fork.
**Goal:** Drive design and implementation of a production-grade error system covering compilation
errors, runtime errors, stack traces, and memory leaks — with comprehensive, descriptive, useful
messages and consistent tooling.

This revision incorporates two completed deep-research passes; the architectural decisions in
Part VII are now defended with primary sources rather than presented as open questions.

---

## 0. How to use this document

Read Part I to understand the language and toolchain from nothing. Part II states the problem and
what "production-grade" means here. Part III is the evidence-based current state (with `file:line`
pointers). Part IV is the unifying thesis. Part V sketches the design per domain. Part VI lists
the project invariants **and** cross-cutting non-negotiables any solution must respect. Part VII
gives the defended position on each major design fork with primary-source citations. Part VIII is
the phased roadmap (with an explicit "highest-leverage first step"). Part IX lists what still
needs validation. Part X is the bibliography. Appendices A–B are the file map and glossary.

The four problem domains in scope:

1. **Runtime errors** (raising/handling, exception values, recoverable vs. unrecoverable).
2. **Compilation errors** (diagnostics quality, recovery, structured output, explainability).
3. **Stack traces** (debug info, runtime backtrace capture, symbolication, crash reports).
4. **Memory leaks** (attribution, reporting, test-time enforcement). ARC reference cycles are out
   of scope — Zap's immutable surface cannot construct one (see Decision 3).

---

# PART I — BACKGROUND (assume zero context)

## 1. What Zap is

Zap is an **early-stage, statically typed, natively compiled, functional programming language**,
heavily influenced by **Elixir/Erlang** in surface syntax and semantics, but with native compilation,
a static type system, and explicit resource semantics rather than a BEAM VM.

Salient properties:

- **Native binaries. No VM, no interpreter, no bytecode.**
- **Struct-centered.** Code is organized around `pub struct`/`pub union`/`pub protocol`. A struct is
  the unit of code organization; there is no separate namespace/module construct.
- **Pattern-matched, multi-clause functions** with typed overload resolution and guards:
  ```zap
  pub fn factorial(0 :: i64) -> i64 { 1 }
  pub fn factorial(n :: i64) -> i64 { n * factorial(n - 1) }
  ```
- **Static type system**: signed/unsigned ints (`i8..i128`, `u8..u128`), floats (`f16..f128`),
  `Bool`, `String`, `Atom`, `Nil`, a bottom type `Never`, tuples, lists, maps, ranges, structs,
  unions. Explicit types at boundaries; exact-first numeric overload resolution.
- **Protocols + impls** for compile-time dispatch (`Enumerable`, `Stringable`, `Comparator`, …).
- **Macros are Zap code** that return quoted Zap AST. Core control flow (`if`, `unless`, `and`, `or`,
  `|>`, sigils) is *implemented as macros in `lib/kernel.zap`*, not hardcoded in the compiler.
- **Build manifest is Zap code** (`build.zap`) evaluated at compile time.
- **Test framework (Zest)** with compile-time test discovery; doc generation from `@doc`.
- **Algebraic effects system** (see §4) — Zap already has a working effects implementation.

Elixir-inherited error idioms currently present *by convention only*:

- `{:ok, value}` / `{:error, reason}` tuples returned from fallible functions.
- A pipe `|>` and a **catch-basin operator `~>`** that handles an unmatched piped value and skips
  remaining pipe steps:
  ```zap
  input |> parse_number() |> format_number() ~> { _ -> "unrecognized" }
  ```

There is **no** exception type, **no** `try`/`rescue`/`after`, **no** `Result` type, **no** error
propagation operator, and **no** typed error sets today. `raise/1` exists but is a hard process
abort (Part III).

## 2. The compilation pipeline

Source → native binary, in order:

1. Parse source files (`src/parser.zig`, `src/lexer.zig`, `src/ast.zig`).
2. Collect declarations into a **source graph** and **scope graph**.
3. Stage and expand **macros**.
4. Desugar high-level syntax.
5. **Type-check**, resolve overloads/protocols/generics.
6. Lower to **HIR**.
7. **Monomorphize** generic functions.
8. Lower to **IR**.
9. Analysis passes: escape, lambda-set, **Perceus** reuse, ARC ownership/liveness.
10. Emit per-struct **ZIR** through the Zig-fork **C-ABI** (`src/zir_backend.zig`,
    `src/zir_builder.zig`).
11. The Zig fork runs **Sema** + LLVM to produce the native artifact.

`src/diagnostics.zig` is the cross-cutting compiler diagnostic engine. `src/runtime.zig` is the
embedded Zap runtime (intrinsics reachable from Zap as `:zig.Struct.fn(...)`), including the
panic / `raise` paths and ARC machinery.

**Hard rule (project policy):** Zap *only* lowers to ZIR via `src/zir_builder.zig` → fork C-ABI.
`src/codegen.zig` is **legacy dead code**; there is no text-codegen backend. If a feature cannot be
expressed through ZIR, the correct fix is to add a C-ABI function to the fork — never to text-generate.

## 3. The Zig fork

Zap does **not** target standard Zig. It links against a **maintained fork of the Zig compiler** (the
0.16 line), kept at `~/projects/zig`. The fork exposes Zig's normally-internal **ZIR** (Zig
Intermediate Representation) as a stable **C-ABI library** (`libzap_compiler.a`), defined in
`~/projects/zig/src/zir_api.zig`.

- Zap calls ~176 exported `zir_*` builder functions to construct ZIR directly (no Zig source text),
  then calls a compilation/update entry that runs Sema + codegen + LLVM.
- The fork therefore *is* the backend: it owns Sema, error bundles, DWARF/debug-info emission, LLVM,
  linking, and the `std.debug` machinery (stack walking, DWARF symbolization).
- **We are explicitly permitted and expected to modify the fork** when a primitive is genuinely
  needed there. The same code-quality bar applies to the fork as to Zap.

Critically for this brief: **the fork already has the hard parts of debug info and stack walking**.
It exports `zir_builder_emit_dbg_stmt` (at `~/projects/zig/src/zir_api.zig:3115`). Zap's
`src/zir_builder.zig` **does not currently call it** — see Part III §3.

## 4. The effects system (pivotal context)

Zap has a working **hybrid algebraic-effects system**:

- ≈90% of effect usage is resolved by **static monomorphization** (zero-cost specialization).
- ≈10% falls back to **defunctionalized CPS** (continuation-passing) for dynamic cases.
- v1 constraints: effects are **opt-in**; **no multi-shot resumptions**; **lexical handler scope**;
  **nominal effect declarations**; static resolution prioritized.
- Effect sets are carried on `Type.FunctionType` only; a `null` effect set means **effect-polymorphic**.

The **no-multi-shot-resumption** constraint is the precise precondition that makes
*one-shot abortive* effects (i.e. exceptions) compilable directly to error-unions instead of CPS —
Leijen's "selective CPS" theorem (POPL 2017). This is the formal justification for the unwinding
choice in Part VII.

## 5. Memory model

- **Atomic Reference Counting (ARC)** is the default. **No tracing GC.**
- ARC retain/release is compiler-driven via **Perceus**-style precise reference counting with reuse
  (Reinking, Xie, de Moura, Leijen, PLDI 2021).
- The memory manager is a **first-class, build-time-selected type** chosen in the manifest
  (`Zap.Manifest.memory :: Type`, default `Memory.ARC`). Built-in managers: `Memory.ARC`,
  `Memory.Arena`, `Memory.NoOp`, `Memory.Leak`, `Memory.Tracking`; third parties can implement the
  zero-method `Memory.Manager` marker. Exactly one manager per binary.
- **Pure Perceus is garbage-free only for cycle-free programs** (PLDI 2021 §1) — and **every Zap
  program is cycle-free by construction.** The fully-immutable surface (no field mutation, no
  `Ref`/`Cell`/`Atom`) means a value can only reference strictly-older values, so the points-to
  graph is always a DAG that pure reference counting reclaims completely. Zap therefore needs no
  cycle collector and no `weak`/`unowned` references — not as a deferred gap, but as a language
  guarantee (see Decision 3).

---

# PART II — THE PROBLEM

We want a **first-class, production-grade error system** for Zap with **comprehensive, descriptive,
useful messages**, spanning runtime errors, compilation errors, stack traces, and memory leaks.

"Production-grade" concretely means, at minimum:

- **Correct and principled** — no workarounds; integrated with the type system and effects system,
  not bolted on. (Project policy forbids hacks; the *correct* fix is required regardless of cost.)
- **Comprehensive** — full lifecycle: a wrong program is caught at compile time with a great message;
  a failing program at runtime produces a precise, sourced, actionable report; a leaking program is
  told exactly what leaked and where.
- **Descriptive & useful** — messages name the thing, show the source with context, explain *why*,
  and suggest a fix. The bar is Rust/Elm-class diagnostics and Elixir-class runtime reports.
- **Consistent** — one visual/text language and one structured-output schema across all four domains
  so it *feels* like one system, and so tooling (LSP, CI, debugger, profiler) consumes one format.
- **Toolable** — structured (JSON) output; debugger/profiler interop; test-time enforcement.

Out of scope to *decide* here (but in scope to *inform*): the eventual process/concurrency model.
Zap is Elixir-influenced and will likely gain processes/supervision; the error system should be
designed so "let it crash" + per-process crash reports are a natural later addition, not a redesign.

A useful operational rule (consistent with Rust/Zig/Go/Erlang patterns):

> If callers are expected to branch on the failure, use a typed error value.
> If the program has violated an invariant, panic (abandonment).
> If the failure should be isolated and restarted, let a supervisor/task boundary handle it.

---

# PART III — CURRENT STATE (evidence)

### 1. Runtime errors — minimal, non-recoverable

- `lib/kernel.zap:357` — `pub fn raise(message :: String) -> Never { :zig.Kernel.raise(message) }`.
- `src/runtime.zig:7041` — `pub fn raise(message: []const u8) noreturn` writes
  `** (RuntimeError) <message>\n` to stderr and calls `std.process.exit(1)`.
- `src/runtime.zig:6804` — `pub fn panic(message)` is the same with `** (NilError) `.
- Consequence: **no exception value, no exception type/struct, no metadata, no source location, no
  stack trace, and no way to catch or recover.** `raise` returns `Never` (the bottom type).
- Recoverable errors are an **ad-hoc convention**: bare `{:ok,_}` / `{:error,_}` tuples + the `~>`
  catch-basin operator. There is no `Result` type, no `try`/`rescue`/`after`, no `with`, no
  `?`-style propagation, no typed error sets.
- The `~>` operator is real and lowered: HIR `buildErrorPipe` flattens the pipe chain; IR
  `lowerErrorPipeChain` emits nested `UnionSwitch`; `try_call_named` calls a `__try` function
  variant returning an error union; `match_error_return` emits an *error return* instead of a panic
  so a pattern-match failure in a `__try` propagates as `error.NoMatchingClause` (catchable) rather
  than aborting; `Call.Flags` **bit 4 `pop_error_return_trace`** must be set on error-returning
  calls or Sema mishandles the error-return-trace stack.
- **Landmine:** the IR assumes Result-like Ok/Error with *empty field bindings* — payload-sensitive
  handler semantics are not represented yet. (Mitigation: see Part V — `TryProject` IR node.)

### 2. Compilation errors — strong renderer, systemic gaps

`src/diagnostics.zig` (`DiagnosticEngine`) is already high quality at *rendering*:

- `Severity` = `{error, warning, note, help}`.
- `Diagnostic` carries `severity, message, span, notes[], label, secondary_spans[], help, suggestion,
  code`. `Suggestion` includes a machine-applicable `replacement` + `description`.
- Caret (`^^^`) primary + tilde (`~~~`) secondary underlines, box-drawing gutter (`│`, `└─`), one
  line of context above, color with `NO_COLOR`, `max_errors` cap with overflow message,
  `line_offset` correction, multi-source via `span.source_id`. Tested in-file.
- Specialized constructors: `typeError`, `undefinedVariable`, `undefinedFunction`,
  `ambiguousOverload`, `nonExhaustiveMatch`, `unreachableClause`. Parser produces conversational
  "I was expecting…" messages with `label`/`help`. `TypeProvenance` (type_id + source span) exists
  in `src/scope.zig`. Fuzzy "did you mean?" is fed by `collectVisibleBindingNames` +
  `src/similarity.zig`.

Systemic gaps (not cosmetic):

- **Parser bails on the first error.** No error-tolerant AST / poisoned sentinel nodes;
  `synchronize()` exists but is **unwired**. You get one diagnostic per compile.
- **Internal compiler failures escape unstructured.** Compiler/linker OOM surfaces as
  `zir_api: update failed: OutOfMemory` with **zero error-bundle diagnostics**. There is no
  "internal compiler error / please report" diagnostic class.
- **No stable error-code catalog**, no `zap explain Zxxxx`, no minimal-repro+fix registry.
- **No structured (JSON) diagnostic output** for LSP/CI/`zap fix`.
- **No macro-expansion backtrace** in diagnostics; spans don't carry expansion provenance.
- `TypeProvenance` exists but is not systematically used to show both sides of a type mismatch.
- Diagnostic ordering is insertion order from possibly-parallel passes (mutex-appended); not a stable
  deterministic sort.

### 3. Stack traces — effectively absent

- The fork **exports `zir_builder_emit_dbg_stmt`** (`~/projects/zig/src/zir_api.zig:3115`) and owns
  full DWARF emission + `std.debug` stack walking/symbolization (it is the Zig compiler).
- **Zap's `src/zir_builder.zig` never calls `zir_builder_emit_dbg_stmt`** (verified: no `dbg_stmt`
  emission site). Therefore Zap binaries carry **no source-location debug info mapped to Zap
  source**.
- No runtime backtrace capture, no symbolizer mapping mangled Zig symbols → Zap symbols, no wired
  error-return traces (only the `pop_error_return_trace` Call flag hook exists), no formatted crash
  report.
- Optimize modes: `Debug / ReleaseSafe / ReleaseFast / ReleaseSmall`. Debug-info strip differs by
  build path (`root_strip` is `false` on one path, `true` on another in the fork) — needs a
  deliberate per-mode policy.
- Net: every crash today is a single unsourced line (`** (RuntimeError) <msg>`), with no Zap
  file:line even though the underlying toolchain is fully capable of DWARF.

### 4. Memory leaks — primitive

- `lib/memory/{leak,tracking}.zap` are zero-method `Memory.Manager` conformance markers; the real
  logic is the Zig backends `src/memory/{leak,tracking}/manager.zig`.
- `Memory.Tracking` detects three classes and prints raw stderr lines:
  - leaks: `LEAK: ptr=0x..., size=N, alignment=A`
  - invalid frees: `INVALID FREE: ptr=0x... not allocated by this manager`
  - UAF/OOB: 16-byte `0xCC` canaries → `USE-AFTER-FREE or OOB: canary corrupted at ptr=0x...`
- **No allocation site, no Zap type name, no backtrace, no diagnostic-engine rendering, no summary,
  no deterministic ordering, no CI fail mode integration.**
- ARC is default and reclaims everything a Zap program can build: reference **cycles are not
  constructible** from the immutable surface (see Decision 3), so there is nothing for a cycle
  detector or `weak`/`unowned` to fix. Plain **leaks** (a live allocation simply never released)
  remain real and are the leak subsystem's concern.
- Two known live issues this tooling would directly illuminate: (a) an **intentional** leak —
  `FieldStorage.indirect` heap slots are allocated but not released on struct drop (deliberately
  preferred over a use-after-free, pending full ARC integration with indirect storage); (b) an
  **open defect** — the full ~86-module `zap test` binary deterministically SIGTRAPs at startup in
  libc malloc due to a fixed-capacity static registration table whose compiler-emitted bounds check
  covers only the first sub-table while the store writes into a second merged-globals region,
  corrupting libc freelist metadata.

---

# PART IV — ANALYSIS & UNIFYING THESIS

A first-class system is **one model with four surfaces and one renderer**, not four bolt-ons:

1. **Type surface: effect-typed; codegen: error-unions.** Recoverable errors appear in signatures as
   an *error effect row* layered on Zap's existing effects system, **and are lowered to Zig-style
   tagged error unions with an attached error-return trace (ERT)**. This is *not* "errors as full
   algebraic-effect handlers" — there is no continuation reify, no CPS for the exception effect.
   The formal justification is Leijen's selective-CPS theorem (POPL 2017): one-shot abortive
   handlers admit direct lowering. Zap's v1 effects constraint (no multi-shot resumptions) is the
   precise precondition that keeps this sound. Practical benefits: zero happy-path cost (Kelley's
   "secret first-parameter pointer in a register" — Zig ERT), effect-polymorphism for generic
   combinators (`Enum.map` propagates a callback's error effect for free without monomorphization),
   exhaustiveness checking, statically flagged unhandled errors. The existing
   `~>`/`match_error_return`/`try_call_named`/`pop_error_return_trace` infrastructure is already
   ~60% of this mechanism.

2. **Recoverable vs. unrecoverable is explicit and separate** (Midori's two-pronged model — Duffy
   2016 — and Rust's `Result`/`panic!` split): `Result(t,e)` + `?`-propagation + `with` for the 99%
   value path; `raise` + exception structs for *defects* with a rich formatted crash report.
   Bugs are not recoverable errors. Bridges are type-checked (`Foo` vs `Foo!` convention).

3. **One backtrace subsystem** in the fork's C-ABI, reusing the fork's mature DWARF/`std.debug`
   symbolizer — consumed by panics, error-return traces, **leak attribution**, and later
   process-crash/profiler integration. Stack traces are *foundational infrastructure*; leak
   attribution is a consumer of it. Build it first.

4. **One canonical Error IR + one renderer.** A single schema — `domain, code, severity,
   message_template, primary_span, related_spans, notes, help, fixits, cause_chain, trace_policy,
   machine_data, visibility` — feeds the CLI renderer, JSON output, and (later) LSP. Compile
   errors, runtime panics, ERT traces, and leak reports all use it. Consistency *is* the
   production-grade feeling and the tooling-integration story. The schema is a projection of the
   LSP `Diagnostic` shape plus rustc-style `code`/`explain`/`MachineApplicable` fields, not a
   parallel invention.

5. **Everything in Zap that can be.** Per project policy: exception structs, the `Error` protocol,
   stdlib exception types, `try`/`rescue`/`with` macros, `Result`, report *formatting*, Zest leak
   assertions → `lib/*.zap`. Only genuine primitives → fork/runtime: `dbg_stmt` wiring,
   `zap_capture_backtrace`/`zap_symbolize` C-ABI, error-union/ERT ZIR lowering, a reversible
   name-mangling side-table, and an allocation-site hook in the memory ABI.

---

# PART V — DESIGN PER DOMAIN

### Runtime errors

- **`pub error` declaration form** — the canonical way to declare an exception type.
  **Front-end-only desugar** (`src/desugar.zig`) to `pub struct X + pub impl Error for X`. After
  HIR, the rest of the pipeline sees a normal struct and a normal protocol impl; no downstream
  stage knows about errors specifically. Project policy satisfied: surface sugar over existing
  machinery, the same mechanism class as `use Struct` or `quote { … }`.

  ```zap
  @code Z3041

  pub error ParseError {
    message :: String = "parse error"
    line :: u32
    column :: u32
  }
  ```

- **Auto-injected fields** (synthesized into the desugared struct only if the user did not declare
  them — user declarations always win):
  - `message :: String = "<TypeName>"` — every error has a presentable message; default is the
    type's display name.
  - `cause :: ?Error = nil` — the source/causal chain (Rust `Error::source` analog). Delivers
    non-negotiable #1 uniformly without per-type discipline.

- **Field defaults are a general `pub struct` feature** introduced alongside `pub error`:
  `field :: Type = expr`. The default is evaluated at construction time when the field is omitted
  in a struct literal. `pub error` uses this same mechanism — no error-specific machinery.

- **Auto-generated `Error` impl** for every `pub error`:
  - `message/1` returns `self.message`
  - `kind/1` returns the snake-cased type name as an atom (e.g. `:parse_error`)
  - `source/1` returns `self.cause`
  - `code/1` returns the value of the optional `@code` attribute, else `nil`

  **Inline methods inside the `pub error` body override the auto-generated default.** This is the
  escape hatch for computed messages and custom protocol behavior — e.g. a `KeyError` whose
  `message/1` is computed from `key`/`map` fields rather than carried as a string.

- **Visibility is the `pub` keyword.** `pub error X` = matchable API surface (part of the API
  contract; callers may `rescue` on the type). Bare `error X` = renderable-only/private (used for
  internal-compiler errors and library internals; the renderer can print its message but callers
  cannot pattern-match on it). Delivers non-negotiable #10 with no new mechanism — same `pub`
  convention as the rest of Zap.

- **`@code Zxxxx` attribute** — stable numeric code for diagnostic identity. Optional in the
  declaration; CI-linted as required on any `pub error` reaching a `pub` API surface. Codes are
  public API; never reuse a retired code.

- **`raise "string"` shorthand** — sugar for `raise %RuntimeError{message: "string"}`. Kept for
  ergonomic scripting and test code; CI-linted on `pub` API surfaces to push production code
  toward named errors. `RuntimeError` is itself defined as `pub error RuntimeError {}` in stdlib —
  the auto-injected `message` field and default carry the shorthand's payload.

- **Polymorphic `raise`**: `raise %SomeError{…}` raises a struct value implementing `Error`;
  `raise "string"` invokes the shorthand. Captures a backtrace into the ERT side-channel (not the
  struct value), preserving zero-cost happy path for `Result`-returned errors.

- **Stdlib `pub error` types**: `RuntimeError`, `ArgumentError`, `ArithmeticError`, `KeyError`,
  `MatchError`, `IndexError`, `OutOfMemoryError`. All in `lib/`.

- **Parametric errors**: `pub error DeserializeError(T) { … }` — same parametric syntax as
  `pub struct`.

- **`try { } rescue { pat -> … } after { }`** as typed, exhaustiveness-checked effect handlers.
  `after` is finally-semantics and must be ARC-correct on the unwinding path — it interacts with
  drop insertion and the restricted retain/release emission sites.

- **No `defer` / `errdefer`** (rejected as misaligned). Imperative Zig/Go-style scope-cleanup
  statements are unnecessary in an immutable functional language: deterministic resource release is
  handled by ARC (drop glue at refcount-zero, including on the unwinding path), and explicit cleanup
  that must run on every exit is `after` (try/rescue/after, finally-semantics). An earlier iteration
  shipped `defer`/`errdefer` as ARC-integrated cleanup primitives; they were removed once `after` +
  ARC were recognised as covering the space without a second, imperative mechanism.

- **`Result(t,e)`** as the canonical recoverable type (`union { Ok(t), Error(e) }`). Bare tuple
  sugar retained for Elixir familiarity, with a `tuple_to_result/1` stdlib shim for migration.

- **No `?`-propagation operator** (rejected as redundant). Rust/Swift/Zig-style `expr?` postfix
  early-return was misaligned with Elixir-aligned Zap: multi-step `Result` composition is `with`,
  and abortive propagation is `raise`/`raises`. An earlier iteration shipped `?`; it was removed
  because `with` (happy-path binding + an `else` for the `Error` branch) and the
  `raise`/`raises`/`rescue` surface already cover every case `?` did, without a third propagation
  spelling. The tail-call ERT concern (a propagating return must stay a tail call) is preserved for
  cross-function `raise` propagation: ERT recording is a **guarded out-of-line call** (Zig's choice —
  Kelley 2018).

- **`with` macro** (Elixir-style multi-step `Result`/`Option` composition) — the canonical idiom for
  chaining fallible steps: `with Ok(a) <- step1(), Ok(b) <- step2(a) { … } else { Error(e) -> … }`.
  Each `<-` binds the happy-path value or diverts the first non-matching value to the `else` arm.

- **Effect-row typing**: `fn parse(...) -> i64 raises ParseError` declares the row.
  **Inferred-by-default, optional-but-checked when written.** A function whose body `raise`s (or calls
  a `raises` callee whose error it does not rescue) infers the appropriate `raises` row. Stdlib leaf
  functions get explicit rows from day one to anchor inference.

- **The `~>` catch-basin** recovers a call-site *dispatch failure* and binds the recovered value to
  a handler arm. It keeps its bespoke `error_pipe` lowering. (An earlier iteration added a
  `TryProject(value, ok_var, err_var)` IR node as a payload-aware generalization shared with the
  `?` operator; it was removed together with `?` in the deflation pass — with `?` gone there is no
  second consumer to share the node, and `~>` is sound on its own lowering.)

- **`raise` as defect / `Result` as recoverable.** Unrescued `raise` → formatted crash report +
  nonzero exit now, → per-process termination once a process model lands (same renderer either way).
  Bugs are not recoverable errors (Midori).

### Compilation errors

Generalize `DiagnosticEngine` into the shared report core (Part IV §4). Add:

- **Error-tolerant parsing + poisoned `Error` AST node** so type-checking continues and *all* errors
  surface per compile (highest-leverage compile investment; required for a good LSP).
- **Stable code catalog + `zap explain Zxxxx`** with minimal-repro + fix. **Numeric codes are public
  API from day one — never reuse a retired code.**
- **ICE diagnostic class** (failing pass + "compiler bug, please report" with stable internal
  code) — nothing internal ever escapes unstructured.
- **Two-sided type errors** via `TypeProvenance` + `secondary_spans` ("expected i64 from here ↓,
  got String from this literal ↑").
- **`--error-format=json`** with a stable schema (LSP-projectable; Part IV §4).
- Deterministic sort/dedup ordering.
- **Macro-expansion backtraces** (spans gain `expanded_from: ?*SourceSpan`).
- **Error-effect diagnostic class** ("unhandled `ParseError` — add `rescue` or declare `raises`")
  with `MachineApplicable` suggestion that LSP can project as a code action.
- **Suggestion applicability tags**: `MachineApplicable | MaybeIncorrect | HasPlaceholders |
  Unspecified` (rustc).

### Stack traces

- **Phase 0 (foundational): wire `zir_builder_emit_dbg_stmt`/`dbg_var`** at statement boundaries
  carrying the Zap `SourceSpan`, plus a reversible mangled-name ↔ Zap-symbol side-table section.
  This yields **real DWARF keyed to Zap source for free** — lldb/gdb/perf/samply/the fork's panic
  handler immediately show Zap file:line.
- **Per-mode debug-info policy table:** keep `root_strip=false` for Debug/ReleaseSafe; allow strip
  for ReleaseFast/ReleaseSmall with an `-Ddebug-info` override. Keep frame pointers in ReleaseSafe
  (unlocks all sampling profilers; ~1-3% perf cost). Ship split-debug
  (`.dwo`/`.dSYM`/`debuginfod`-keyed by build ID) for stripped releases.
- **Backtrace C-ABI in the fork**: `zap_capture_backtrace(buf, max) -> n`,
  `zap_symbolize(addr) -> {name, file, line}`. Reuse the fork's `std.debug` DWARF reader; do not
  reinvent.
- **Error-return traces** for the value-error path: reuse the fork's machinery; flip
  `pop_error_return_trace` on the relevant calls. Zig's signature feature — nearly free here.
- **Crash-report renderer** shares the diagnostic visual language (exception + caret'd Zap source
  line at the raise site + symbolized Zap backtrace + error-return trace), honors a
  `ZAP_BACKTRACE=full|short|0` convention and `NO_COLOR`/TTY.
- **`zap-addr2line` tool**: a thin CLI reusing the fork's DWARF reader for cross-compilation
  post-mortem from stripped releases + a build-ID-keyed symbol service.

### Memory leaks

- **`Memory.Tracking` records a captured backtrace + Zap type + size + refcount per allocation.**
  At `deinit`, survivors are reported **through the shared renderer**:
  > Leaked 1 `%User{}` (48 B), allocated at lib/app.zap:88, refcount 2
  with a deterministic summary table and `--leaks-fatal` for CI.
- **`@expect_leak` test attribute** — handles the intentional `FieldStorage.indirect` leak: Zest
  reads the attribute and subtracts those allocations from the live set before asserting empty.
- **Zest leak assertion** (`assert_no_leaks`) makes "no leaks in this block" a first-class test
  primitive.
- **No ARC cycle detector and no `weak`/`unowned`.** A reference cycle is not constructible from
  Zap's immutable surface (see Decision 3), so there is nothing for a cycle collector to reclaim or
  for `weak`/`unowned` to break. This is a language guarantee, not a gap.
- Existing canary UAF/double-free reports upgrade to the same attributed, symbolized, rendered
  format — directly tooling the open SIGTRAP defect.

---

# PART VI — CONSTRAINTS, INVARIANTS, AND CROSS-CUTTING NON-NEGOTIABLES

## VI.A — Project invariants (any proposal must respect)

1. **Zap-first.** Behavior belongs in `lib/*.zap`. The compiler must stay general-purpose — no
   hardcoded Zap struct/function names in Zig. Only true primitives go in `src/*.zig` or the fork.
2. **No workarounds/hacks.** The correct, long-term fix is required regardless of cost or scope,
   including deep changes to the fork or core data structures.
3. **ZIR-only codegen.** The single codegen path is `src/zir_builder.zig` → fork C-ABI. No text
   codegen. Missing capabilities → add a C-ABI function to the fork.
4. **Fork changes are allowed** and held to the same quality bar.
5. **Effects-system v1 limits:** opt-in, no multi-shot resumptions, lexical handler scope, nominal
   effect declarations, static resolution prioritized. Exceptions are one-shot abortive (compatible).
6. **ARC, no GC.** Reference cycles are not constructible from the immutable surface (see
   Decision 3), so there is no cycle garbage to reclaim and no cycle collector. Any future
   collector (only relevant if mutation is ever added) must not impose unconditional production
   cost without opt-in.
7. **Performance:** happy path stays zero-cost; error-path cost is acceptable.
8. **Determinism:** diagnostics and reports must be deterministically ordered (CI, golden tests).
9. **Known landmines:** intentional `FieldStorage.indirect` leak; open startup SIGTRAP defect;
   restricted ARC retain/release emission sites; payload-insensitive `~>` IR; `@debug`-annotated
   functions are erased in release and must be `T -> T` pass-through.
10. **`@doc` on every `pub` declaration** is mandatory for any new Zap stdlib surface.

## VI.B — Cross-cutting non-negotiables (must be designed in from day one)

These are decisions that, if deferred, will require painful retrofits later. Both research passes
flag each independently.

| # | Non-negotiable | Why now |
|---|---|---|
| 1 | **`cause :: ?Error` auto-injected into every `pub error`** | Rust `Error::source` precedent; the keyword guarantees uniform causal-chain support from day one without per-type discipline. Manual `impl Error for SomeStruct` (the escape hatch) must declare the field explicitly. |
| 2 | **Stable numeric error codes from day one** | Codes are API surface (rustc precedent); never reuse a retired code. Force every diagnostic to declare a code so the catalog grows monotonically. |
| 3 | **OOM under ARC = abandonment, not recoverable** | Infallible allocation by default in `Memory.ARC`; an explicit `try_alloc` builder for fallible code (CI runners, embedded). Aligns with Midori; both Roc and Koka punt on this and pay later. |
| 4 | **Async-signal-safe crash printer** | Must be reachable from a SIGTRAP/SIGSEGV handler. **No `malloc`, only `write`/`_exit`** and other POSIX async-signal-safe calls. Reuse the fork's `std.debug` paths which are already signal-aware. Required to reach the known startup SIGTRAP defect from its signal handler. |
| 5 | **Panic-during-unwind / double-fault containment** | A second panic during unwind (e.g. inside an `after` cleanup or drop glue) → immediate `abort` with a distinct exit code (e.g. `137 + double-fault marker`), no further user code. Rust precedent. |
| 6 | ~~**Three-tier contracts** — `assert` (always-on), `debug_assert` (debug-only), `precondition` (release-elided)~~ **REMOVED in deflation pass.** Originally drawn from Eiffel/Ada/SPARK/Swift precedent, but misaligned with an Elixir-influenced functional language: Elixir has no language-level `assert` (assertions are a test-framework concern). Zest (`assert`/`reject`) is the assertion surface; production invariants use `raise` or a failing `case`. |
| 7 | **Per-optimize-mode arithmetic overflow / bounds policy** | Trap in Debug/ReleaseSafe; wrap in ReleaseFast (Zig's model). Document explicitly that traps `raise %ArithmeticError`. |
| 8 | **Tail-call + propagating-`raise` interaction** | ERT recording is a guarded out-of-line call so a propagating `raise` in tail position (`tail-return foo()` where `foo` propagates) stays a tail call. Kelley 2018. |
| 9 | **Diagnostic security tiers** — developer-local / CI-internal / user-safe | Strip absolute paths in release reports; never include heap contents in the default report; emit ASLR-relative offsets when symbolication is unavailable. Sanitizer runtimes are **never** linked into production builds. |
| 10 | **Public-vs-private error visibility via the `pub` keyword** | `pub error X` = matchable API surface; bare `error X` = renderable-only/private. Same `pub` convention as the rest of Zap — no new mechanism. Go wrapping precedent. |
| 11 | **Deterministic diagnostic snapshots** | Golden-test the renderer (rustc UI-test pattern). All four surfaces — compile, runtime, ERT, leak — produce snapshot-stable output. |
| 12 | **Restricted ARC retain/release emission sites are an enforced allow-list** | Every lowering primitive that can move ownership (`rescue` handler entry, `after` cleanup — including the re-raise splice, propagating `raise`) registers in the allow-list or fails CI. |
| 13 | **Split-debug + frame-pointer per-mode policy** | Debug/ReleaseSafe: full DWARF, FP on. ReleaseFast/Small: split-debug shipped separately, FP off optionally. Build-ID keyed symbol service for CI/crash analysis. |

---

# PART VII — DEFENDED DECISIONS

### Decision 1 — Unwinding mechanism: **hybrid (effect-typed surface, error-union codegen)**

**Defense.** Leijen's "selective CPS" theorem (POPL 2017, *Type Directed Compilation of Row-Typed
Algebraic Effects*, §6) establishes that *one-shot abortive* effect handlers — i.e. exceptions —
admit direct lowering to early-return / error-union instead of full continuation reify. Sivaramakrishnan
et al. (PLDI 2021, *Retrofitting Effect Handlers onto OCaml*) measured 1% mean overhead for effect
handlers in production OCaml, conditional on DWARF cooperation — feasible for Zap but unnecessary
work for the *exception* effect specifically. Kelley's ERT design (2018) provides the codegen
template the fork already implements ("secret first-parameter pointer kept in a register…
practically free"). Duffy's Midori retrospective (2016) is the strongest industrial precedent for a
*two-pronged* checked-recoverable + abandonment model.

Why not pure algebraic-effects/CPS: Zap's effects-v1 forbids multi-shot resumption — building CPS
plumbing for a use case that resolves to one-shot abortive is overkill, and Koka/OCaml 5 numbers
are good but not better than error-unions plus ERT.

Why not setjmp / DWARF-personality: setjmp pollutes every protected scope; DWARF unwinding
requires async-signal-unsafe table walks and is the source of much C++ trouble. Midori chose
checked exceptions only after substantial codegen work — work Zap would have to redo.

### Decision 2 — Typed-error strictness: **inferred + optional-but-checked `raises`**

**Defense.** Swift SE-0413 (Gregor et al., accepted Dec 2023, shipped Swift 6.0) explicitly retains
untyped `throws` as the recommended default: "Errors are usually propagated or rendered, but not
exhaustively handled, so even with the addition of typed throws to Swift, untyped throws is better
for most scenarios" (proposal text). The closure type-inference component of SE-0413 was *removed*
from Swift 6.0 because it could not ship — a direct caution against mandatory typed errors as v1.
Koka uses inferred effect rows by default with optional explicit annotations; OCaml 5 is the same
pattern. Elixir-classic untyped is incompatible with Zap's static-type charter.

Inference-by-default is also the only path that permits effect-polymorphic generics without
monomorphization blow-up: generics that don't annotate stay effect-polymorphic and do not
monomorphize per error type. Cost is paid only by code that opts in.

### Decision 3 — ARC cycles: **none are constructible, so no collector is needed**

**Defense.** Perceus (Reinking, Xie, de Moura, Leijen, PLDI 2021) is "garbage-free" only for
*cycle-free* programs. The decisive observation is that **Zap programs are always cycle-free by
construction.** Zap's surface is fully immutable: a functional update `%R{r | f: v}` produces a NEW
value, there is no field-mutation operator, and there is no `Ref`/`Cell`/`Atom` mutable primitive.
A value-level reference can therefore only point at a value that *already exists* — every
`%Node{next: Some(other)}` requires `other` to have been built first. Allocations only ever point
at strictly-older allocations, so the points-to graph is a DAG and the loop that would close a
cycle can never form. Pure reference counting reclaims a DAG completely.

Consequently there is **no cycle detector and no cycle collector** — not as a deferred gap, but
because the language guarantees the thing they would detect cannot occur. (An earlier iteration
shipped a Bacon–Rajan trial-deletion *detector* as preemptive infrastructure; it was removed once
the immutability guarantee was recognised as total. It detected something structurally impossible
and was dead surface.) This is distinct from **leaks**, which *are* real under immutable + ARC (a
live allocation that is simply never released — e.g. the intentional `FieldStorage.indirect` one)
and which the Phase 4.c leak subsystem attributes and reports.

If a future phase ever introduces mutation or a mutable cell that can form a back-edge, a cycle
collector becomes relevant again — and only then. It is not owed today.

### Decision 4 — Scope/sequencing: **approve and iterate phase-by-phase**

The design surface (effect-typed errors, ERT plumbing, diagnostic-engine generalization, leak
reports) is too large to land atomically without freezing the language. Phase boundaries also align
with what can be *measured*: each phase has a concrete acceptance test (Part VIII). (Several
originally-planned surfaces — three-tier contracts, the `?` operator, `defer`/`errdefer`, and the
ARC cycle detector — were built then removed in a later deflation pass as misaligned with immutable,
Elixir-aligned Zap; see Part II and decisions #3 and #6.)

---

# PART VIII — PHASED ROADMAP

### Phase 0 — DWARF foundation *(direction settled)*

- Wire `zir_builder_emit_dbg_stmt` + `dbg_var` at statement boundaries carrying Zap `SourceSpan`.
- Reversible mangled-name ↔ Zap-symbol side-table section.
- Per-mode debug-info policy table; FP-on in ReleaseSafe; split-debug for ReleaseFast/Small.
- **Acceptance:** lldb/gdb/perf/samply show Zap file:line at every existing crash site. The fork's
  panic handler prints Zap symbols.

### Phase 1 *(highest-leverage first step)* — `Result(t,e)` + inferred `raises` + `pub error`

> *(As originally sequenced this phase also shipped the `?` operator and its `TryProject` IR node;
> both were removed in the later deflation pass — `with` is the `Result` composition idiom. See the
> surface list in Part II.)*

- **`pub error` declaration form** (front-end-only desugar to `pub struct + pub impl Error`) with
  auto-injected `message :: String = "<TypeName>"` and `cause :: ?Error = nil` fields, optional
  `@code Zxxxx` attribute, and inline method override.
- **Field defaults** (`field :: Type = expr`) as a general `pub struct` feature, used uniformly by
  `pub error`.
- **`Error` protocol** with `message/1`, `kind/1`, `source/1`, `code/1` methods. Auto-implemented
  for every `pub error`; manual `impl Error for SomeStruct` is the escape hatch.
- **`raise "string"` shorthand** kept; desugars to `raise %RuntimeError{message: "string"}` via the
  stdlib's `pub error RuntimeError {}`. CI lint flags string-`raise` on `pub` API surfaces.
- Stdlib `Result(t,e) = union { Ok(t), Error(e) }`.
- ~~`?` operator desugar to `match` with early return (via the additive `TryProject` IR node).~~
  **Removed in the deflation pass** — `with` is the `Result` composition idiom; the `TryProject`
  node went with it.
- `~>` rewritten as a macro over `match` on `Result` so the payload-insensitive IR landmine is
  retired in place. (`~>` is kept; it later moved to its own bespoke `error_pipe` lowering.)
- `raises` annotation parsed; inferred by default; checked when written. Stdlib leaf functions
  annotate explicitly.
- `tuple_to_result/1` migration shim for `{:ok,_}`/`{:error,_}` users; deprecation lint window.
- Numeric error codes mandatory on every new diagnostic; `@code` attribute lints on `pub error`
  reaching public surfaces.
- Per-optimize-mode arithmetic overflow / bounds policy lands here (it produces typed errors).
- **Acceptance:** every existing convention-based error path compiles; Zest produces diagnostics
  for unhandled `Result`; `~>` is a thin macro; `TryProject` is wired and tested; `pub error`
  desugar produces well-typed structs and protocol impls across the test corpus.

### Phase 2 — Unrecoverable model + crash reports

- Stdlib `pub error` types in `lib/`: `RuntimeError`, `ArgumentError`, `ArithmeticError`, `KeyError`,
  `MatchError`, `IndexError`, `OutOfMemoryError`. Each gets a `@code Zxxxx` so the
  catalog seeds with stable codes from day one.
- `raise` accepts any value whose type implements `Error` (uniformly produced by `pub error`).
  Captures a backtrace via the Phase-0 DWARF + a new `zap_capture_backtrace` C-ABI in the fork.
- Crash printer: **async-signal-safe**, reuses fork's `std.debug.dumpStackTraceFromBase`, prints
  exception + caret'd Zap source line at raise site + symbolized stack trace + ERT.
- Panic-during-unwind / double-fault: a second panic during unwinding (inside an `after` cleanup or
  drop glue) → distinct exit code + immediate abort, no further user code.
- ~~Three-tier contracts: `assert` (always-on), `debug_assert` (debug-only), `precondition`
  (release-elided).~~ **REMOVED in deflation pass** (see decision #6 above). Assertions are a
  test-framework concern: Zest provides `assert`/`reject`; production invariants use `raise` or a
  failing `case`. No language-level contract macros and no `AssertionError` type remain.
- ~~`defer` / `errdefer` lowering wired into the ARC retain/release allow-list.~~ **REMOVED in
  deflation pass** (see the surface list above). Deterministic release is ARC's job; explicit
  always-run cleanup is `after`. No imperative scope-cleanup statement remains.
- `ZAP_BACKTRACE=full|short|0` convention.
- **Acceptance:** the known startup SIGTRAP defect produces a symbolicated report; a double-fault
  is contained; release builds strip per the per-mode policy and `zap-addr2line` symbolizes from
  the split-debug artifact.

### Phase 3 — Effect-row surface, `rescue` as handler, `with` macro

- Wire the `raises` row into the existing effects system as a *nominal* effect.
- `rescue` is the effect handler that handles that effect abortively (exhaustiveness-checked
  pattern matching on `Error` values).
- `try { } rescue { } after { }` surface syntax.
- `with` macro: Elixir-style sequencing of fallible `<-` bindings with an `else` arm — the canonical
  multi-step `Result`/`Option` composition idiom (no `?` operator; `with` is the spelling).
- Migrate `~>` to a `rescue` macro (the Phase-1 `match` desugar is intermediate).
- Effect inference handles higher-order combinators (`map`, `fold`, `pipe`) effect-polymorphically
  without monomorphization blow-up.
- Public-vs-private error visibility enforced via the `pub` keyword on `pub error` (already enforced
  at Phase 1; here `rescue` patterns honor it — bare `error` types are rejected as `rescue` match
  patterns at the type-check stage).
- **Acceptance:** round-tripping Elixir-shaped pipelines is identical to today; effect-polymorphic
  combinators compose without explicit annotation; mandatory-`raises` lint mode passes on `lib/*`.

> **Phase 3.c implementation note (the `~>`→`rescue` migration is intentionally deferred).**
> Phase 3.c delivered the `with` macro (Elixir-style multi-step `Result` composition, desugared to
> nested `case` — see `ast.WithExpr` and `src/macro.zig:withToNestedCase`). The companion goal,
> "migrate `~>` to a `rescue` macro," was **deferred** after a rigorous reconciliation that found the
> two constructs are **not semantically equivalent**, so a migration cannot preserve `~>`'s exact
> behavior (the overriding acceptance criterion above: "round-tripping … is identical to today").
>
> The mismatch is in the *failure model*:
>
> - **`~>` (the catch-basin) is a call-site _dispatch-failure_ recovery.** A pipe step that is a
>   multi-clause function is compiled to a `__try` variant returning `error{NoMatchingClause}!T`
>   (`src/ir.zig` `lowerErrorPipeTryStep` / `try_call_named` / `error_catch` / `match_error_return`).
>   On a clause-match failure the catch basin runs the handler **with the original input value
>   bound** — and the handler may pattern-match that value's domain (e.g. `"fail" -> …`, `val -> …`).
>   The handler never sees an `Error` struct; no `raise` occurs.
>
> - **`try`/`rescue` (Phase 3.a) is a _raised-Error_ effect handler.** It catches a `raise %E{}`
>   (an error-union/ERT return carrying the boxed `Error` via the thread-local side-channel) and the
>   `rescue` arms pattern-match the **`Error` value** (`e :: IOError`, `%KeyError{…}`).
>
> Empirically (verified at the Phase 3.c tip): a multi-clause **dispatch failure is _unrecoverable_**
> — `T.parse("nope")` aborts with `** (match_error) no matching clause` (the Phase 2 crash path) and
> is **not** caught by an enclosing `try`/`rescue`. So `~>` cannot be expressed as `try`/`rescue`
> without (a) making every dispatch failure a *recoverable* `raise %MatchError{value}` — a
> program-wide behavior change well outside this phase — and (b) having `rescue` expose the *input
> value* (not the `Error`) to handler patterns matching the input's domain. Both are observable
> behavior changes that would break the byte-identical guarantee. The brief's "the Phase-1 `match`
> desugar is intermediate" framing assumed the two models would converge; they do not.
>
> **Decision:** keep `~>` on its proven bespoke lowering (byte-identical, zero regression — every
> existing consumer verified: `script_fixtures/phase_1_4_error_pipe.zap`,
> `examples/error_pipe/error_pipe.zap`, `test/catch_basin_test.zap`, and the 7 catch-basin
> integration tests in `src/zir_integration_tests.zig`). The `try_call_named`/`error_catch`/
> `match_error_return` infrastructure is **retained, not retired** (it is not replaced). A true
> unification belongs in the Phase 3 gap loop (#179) and would require first deciding whether
> dispatch failures should become recoverable raises — a language-semantics question, not a
> mechanical macro rewrite.

> **Phase 3.d implementation note (acceptance + effect-polymorphism e2e + ERT-display gap).**
> Phase 3.d closed the Phase 3.b effect-polymorphism gaps and root-caused a fork-level
> error-union limitation. Delivered:
>
> - **GAP 2a — function-ref → callable closure (eta-expansion).** A named function reference
>   (`&Struct.fn/n` / bare `&fn/n`) in **argument position** is a callable value, not the reflective
>   first-class `Function` struct (`{struct, name, arity}` from `lib/function.zap`). The desugar pass
>   (`src/desugar.zig` `etaExpandFunctionRefArg`) now rewrites it into a forwarding anonymous function
>   `fn(a..) { Struct.fn(a..) }`, copying the referenced clause's declared param/return type
>   annotations resolved through the scope graph the desugarer holds. The synthetic closure
>   type-checks against a `(a -> b)` callback parameter and lowers through the proven anonymous-
>   function/`closure_create` path; a `raises` row on the referenced function flows through the
>   forwarded call. Reflective uses (a reference returned where `Function` is expected) are not call
>   arguments and keep the struct shape. `Enum.map([1,2,3], &Doubler.double/1)` now type-checks and
>   runs (`test/fixtures/raise_cross_fn/funcref_combinator.zap`).
>
> - **Monomorphizer `try_rescue` call-site rewrite.** `MonomorphContext.rewriteExpr` was missing a
>   `.try_rescue` arm (and the destructuring-projection / `ret_raise` arms) that the scan and clone
>   passes already traversed, so a generic call inside a `try`/`rescue` body kept its generic
>   `call_named` target and the ZIR backend referenced an unmangled symbol (`Enum__map__2`) that was
>   never emitted. `rewriteExpr` now mirrors the scan/clone traversal.
>
> - **Fork: error-union return composes with complex payloads.** `FuncBody.setErrorUnionReturnType`
>   (`~/projects/zig/src/zir_builder.zig`) snapshotted only the scalar `ret_type` Ref (and cleared
>   state first), so `error{ZapRaise}!T` silently dropped a complex payload return type
>   (`List`/`Map`/struct/union/tuple/optional). A raising function declared `-> [T] raises E` emitted
>   `error{ZapRaise}!<default>`. It now resolves the established payload to a single Ref (reusing the
>   payload's own ret_ty body instructions) and re-expresses `error_union_type{anyerror, payload}`
>   through the general custom-return-type body. The Zap ZIR driver reorders the error-union wrap
>   AFTER `emitComplexReturnType`. This unblocked **GAP 2b** (effect-polymorphism through the
>   for-comprehension iteration combinator: a `for x <- xs { raising(x) }` body propagates the
>   callee's `raises` row through the lifted `__for_N` helper — which returns
>   `error{ZapRaise}![mapped]` — and is caught by an enclosing `try`/`rescue`;
>   `test/fixtures/raise_cross_fn/effect_poly.zap`, `raises_complex_return.zap`). A pure body leaves
>   the helper pure.
>
> **GAP 3 — ERT chain in the unhandled-raise crash report (root-caused; deferred).** The goal:
> surface `@errorReturnTrace()` so a 3-deep unhandled `a→b→c` raise shows the propagation chain, not
> just the `Kernel.abort_recoverable_raise` terminus the fresh abort-site backtrace captures. The
> display path is fully designed and was prototyped (a fork `zir_builder_emit_error_return_trace`
> C-ABI emitting the `error_return_trace` extended instruction; a `zap_stash_error_return_trace`
> runtime thread-local sink emitted at the unhandled-recoverable-raise catch site; an
> `emitErrorReturnTraceSection` in `runtime.zig`'s crash printer reusing `crashReportFrame`). The
> **blocker is upstream of display:** the ERT is never populated. `@errorReturnTrace()` returns a
> real cap-20 buffer but with `index == 0`. Root cause: Zap's `FuncBody.addReturnError` emits a plain
> `error_value` + `ret_node` for `return error.ZapRaise`, whereas Zig's `return error.X` emits
> `ret_err_value` — the only return form whose Sema/codegen records an error-return-trace frame.
> Switching to `ret_err_value` is correct but **still left `index == 0`**: the per-frame push also
> needs the AIR/codegen error-trace-frame recording to fire on the injected-ZIR path (the
> function-entry `restore_err_ret_index_unconditional` prologue is emitted, but frames do not
> accumulate). The prototype was reverted to avoid shipping an always-empty `raised, propagated
> through:` section. **What's needed:** verify the script Compilation actually enables error tracing
> for the injected ZIR (the `error_tracing`/`any_error_tracing` module flags), switch
> `addReturnError` to `ret_err_value`, and confirm the fork's self-hosted/LLVM backend emits the
> error-return-trace frame push for `ret_err_value` AIR — then the already-designed display path
> drops in. This is a fork backend/codegen task, tracked for the Phase 4 unified-renderer work (which
> generalizes the renderer across compile/runtime/**ERT**/leak anyway).
>
> **Remaining effect-polymorphism sub-layer (documented): `Enum.map` with a raising *closure*.**
> GAP 2b demonstrates effect-polymorphism through the for-comprehension (whose `__for_N` helper
> invokes the raising callee via a **direct** call, which the existing direct-call propagation
> handles). The literal `Enum.map(list, &raising/1)` routes the callback through `map_next`'s
> `call_closure` (the callback is a polymorphic parameter — a runtime closure value). The closure
> correctly emits `error{ZapRaise}!T`, but `ir.CallClosure` / `ir.ZigType` have **no error-union
> representation**, so the combinator neither propagates nor unwraps the closure result
> (`expected i64, found anyerror!i64`). Closing this needs the closure's effect modeled through the
> IR: an effect bit on `Type.FunctionType` threaded by the monomorphizer onto the concrete callback
> param, an error-union-aware `call_closure.return_type`, and a propagating unwrap at the
> `call_closure` site (mark the combinator specialization raising). This is a deeper IR-type-system
> change than the stated 2a/2b and is the natural next increment.

### Phase 4 — Unified diagnostic renderer + leak subsystem

- Generalize `src/diagnostics.zig` into the canonical Error IR (Part IV §4) — one renderer for
  compile errors, runtime panics, ERT, leak reports.
- Single LSP-projectable JSON schema; single TTY/`NO_COLOR` policy; deterministic sort/dedup.
- **Compile-error systemics now:** error-tolerant parsing + poisoned `Error` AST node;
  multi-error per compile; ICE diagnostic class; `zap explain Zxxxx` long-form catalog;
  macro-expansion backtraces; two-sided `TypeProvenance` rendering; suggestion applicability tags.
- `Memory.Tracking` records allocation-site backtrace + Zap type per alloc; reports surviving
  leaks at teardown. (No cycle detector — reference cycles are not constructible from Zap's
  immutable surface; see Decision 3.)
- Zest: `assert_no_leaks`; `@expect_leak` attribute (handles the intentional
  `FieldStorage.indirect` leak).
- Diagnostic security tiers (developer-local / CI-internal / user-safe) enforced in the renderer.
- **Zap-native golden diagnostic corpus** becomes a first-class project artifact (the primary
  benchmark; external suites are secondary).
- **Acceptance:** every diagnostic emitted by Zap (compile, runtime, ERT, leak) round-trips through
  one JSON schema and one renderer; the golden corpus is the authoritative regression suite.

### Phase 5 *(deferred)* — `weak`/`unowned`, LSP code-actions, OTel hooks, WASM unwinding

- LSP `CodeAction` projection of `MachineApplicable` suggestions; pull-based diagnostics with
  result IDs (LSP 3.17).
- Optional `on_panic(report)` hook for OpenTelemetry/Sentry-style crash upload.
- WASM exception-handling integration when the upstream proposal stabilizes.

#### ARC reference cycles — not constructible, so no collector is owed

**A reference cycle CANNOT be constructed from Zap's fully-immutable surface.** There is no
field-mutation operator, no `Ref`/`Cell`/`Atom` mutable primitive, and functional update
(`%R{r | f: v}`) always creates a NEW value — so every `%Node{next: Some(other)}` requires `other`
to already exist, and allocations only ever point at strictly-older allocations. The back-edge that
would close a loop can never be formed, so the points-to graph is always a DAG and pure reference
counting reclaims it completely. (The `CycleA`/`CycleB` types in `test/struct_test.zap` are a
*type-level* mutually-referencing SCC, constructed acyclically with `back: nil`; they are a layout
test, not a runtime cycle.)

This is a **language guarantee, not a gap.** Zap therefore ships **no cycle detector and no cycle
collector**, and needs no `weak`/`unowned` annotations to break cycles. (An earlier iteration
shipped a Bacon–Rajan trial-deletion detector as preemptive infrastructure; it was removed once the
guarantee was recognised as total — it detected something structurally impossible.) Plain **leaks**
(a live allocation simply never released) are a separate, real concern handled by the Phase 4.c
leak subsystem.

The only thing that would reopen this is a future capability that can form a back-edge — mutation,
a mutable cell, or a recursive binding primitive. A cycle collector becomes relevant if and only if
such a capability is ever introduced, and is owed only then.

### Must-not-skip-for-production

Error-source chaining; numeric error codes from day one; async-signal-safe crash printer;
per-optimize-mode overflow/bounds policy; split-debug for release; deterministic diagnostic
snapshots; `@expect_leak` for `FieldStorage.indirect`; double-fault containment; restricted ARC
emission allow-list.

### Defer-safely

i18n; OTel/Sentry; full LSP code-actions; WASM exception-handling;
OOM-as-recoverable (keep infallible-by-default with opt-in `try_alloc`).

---

# PART IX — REMAINING VALIDATION ASK

The big design questions are settled. The following items remain *empirical* and should be
validated by experiment, measurement, or implementation spike — not by further survey.

1. **`TryProject` IR node feasibility.** Prototype against the current `~>` IR and confirm the
   existing lowering becomes a strict refinement. Specifically verify the interaction with
   `match_error_return` and `pop_error_return_trace` on `__try` variants.
2. **Async-signal-safety audit of the crash-printer prototype.** Static analysis or audit pass:
   no `malloc`, only POSIX async-signal-safe calls; reaches the known SIGTRAP defect from its
   signal handler.
3. **OOM-under-ARC trade-offs in practice.** Measure: does `infallible default + try_alloc` blow up
   the surface area of `:zig.` allocator calls in `lib/*.zap`? Identify the few sites that need to
   become fallible (CI runners, large parsers).
4. **Migration cost across `lib/*.zap`.** Survey existing `{:ok,_}`/`{:error,_}` sites: count,
   group, identify the ones that should annotate `raises` explicitly vs. let it infer. Confirm the
   `tuple_to_result/1` shim covers them.
5. **DWARF size & build-time impact.** Measure binary-size and build-time deltas for ReleaseSafe
   with full DWARF and split-debug; confirm the per-mode policy stays within budget.
6. **Frame-pointer cost in ReleaseSafe.** Measure on representative benchmarks; confirm the
   ~1-3% number holds for Zap workloads.
7. **`AddressSanitizer` / `LeakSanitizer` numbers from the original Serebryany et al. paper** —
   verify primary citations before publication (one of the reports flagged this as
   citation-from-memory rather than freshly verified).

Items genuinely deferred to v2 design rounds: WASM unwinding, full LSP code-action ergonomics,
i18n/localization, telemetry hook contract, process-model integration ("let it crash" at task
boundaries).

---

# PART X — BIBLIOGRAPHY (primary sources, ★ = load-bearing)

★ **Armstrong, Joe.** *Making Reliable Distributed Systems in the Presence of Software Errors.* PhD
thesis, Royal Institute of Technology (KTH), Stockholm, December 2003. — The "let it crash"
foundation; processes, not functions, are the error boundary.

★ **Bacon, David F. and V. T. Rajan.** "Concurrent Cycle Collection in Reference Counted Systems."
*ECOOP 2001 — Object-Oriented Programming,* LNCS 2072, pp. 207–235. Springer. — The canonical
trial-deletion cycle detector. Evaluated by Decision 3 and ultimately found unnecessary: Zap's
immutable surface cannot construct a cycle, so there is nothing to detect.

★ **Clebsch, Sylvan, Juliana Franco, Sophia Drossopoulou, Albert Mingkun Yang, Tobias Wrigstad, Jan
Vitek.** "Orca: GC and Type System Co-Design for Actor Languages." *Proc. ACM Program. Lang.* 1,
OOPSLA, Article 72 (October 2017). — Strongest precedent for RC + type-system co-design eliminating
cycles structurally.

★ **Czaplicki, Evan.** "Compilers as Assistants." elm-lang.org/blog, November 2015. — Cultural
primary source for empathetic diagnostics (the "teacher, not judge" discipline).

★ **Duffy, Joe.** "The Error Model." joeduffyblog.com, February 7, 2016. — The Midori retrospective:
two-pronged abandonment + statically checked exceptions; the six design criteria scorecard.

★ **Gregor, Doug et al.** *Swift Evolution Proposal SE-0413: Typed throws.* Accepted Dec 7, 2023;
shipped Swift 6.0. — Defends Decision 2; the closure-inference removal is the cautionary data point
against mandatory typed throws.

★ **Kelley, Andrew.** "Zig: January 2018 in Review." andrewkelley.me, January 2018. — Error-return
trace cost model: "secret first-parameter pointer kept in a register… practically free."

★ **Leijen, Daan.** "Type Directed Compilation of Row-Typed Algebraic Effects." *Proceedings of
POPL 2017,* pp. 486–499. ACM. — Defends Decision 1; the selective-CPS theorem proves abortive
handlers admit direct lowering.

★ **Lindley, Sam, Conor McBride, Craig McLaughlin.** "Do Be Do Be Do." *POPL 2017.* — Frank
calculus; effect-typing foundations.

★ **McMurray, Scott.** *Rust RFC 3058: try_trait_v2.* Accepted. rust-lang.github.io/rfcs. — `Try`/
`FromResidual` split with distinct residual types; precedent for the `TryProject` IR node.

★ **Reinking, Alex, Ningning Xie, Leonardo de Moura, Daan Leijen.** "Perceus: Garbage Free
Reference Counting with Reuse." *PLDI 2021* (Distinguished Paper). Extended TR MSR-TR-2020-42. —
The algorithm Zap already uses; explicit about garbage-free *for cycle-free programs*.

★ **Sivaramakrishnan, KC, Stephen Dolan, Leo White, Tom Kelly, Sadiq Jaffer, Anil Madhavapeddy.**
"Retrofitting Effect Handlers onto OCaml." *PLDI 2021,* arXiv:2104.00250. — 1% production overhead
for effect handlers; effects + DWARF coexistence.

★ **van Oortmerssen, Wouter.** *Compile Time Reference Counting & Lifetime Analysis in Lobster.*
strlen.com/lobster, 2020. — Cycle detection at exit as a *diagnostic* mechanism, not a collector;
the precedent Decision 3 considered. Not adopted by Zap — Zap's cycles are structurally
impossible, so even a diagnostic detector has nothing to report.

★ **Serebryany, Konstantin, Derek Bruening, Alexander Potapenko, Dmitriy Vyukov.** "AddressSanitizer:
A Fast Address Sanity Checker." *USENIX ATC 2012.* — The leak-detector design template for
`Memory.Tracking`. (Citation flagged for primary-source re-verification before publication.)

**Secondary sources referenced:**

- DWARF 5 specification (dwarfstd.org).
- Language Server Protocol 3.17 (Microsoft).
- rustc-dev-guide, chapters on diagnostics and `--error-format=json`.
- Rust RFCs 243 (`?`), 1236 (cleaner panic), 1513 (panic-strategy), 1644 (JSON diagnostics), 1859
  (first `Try` trait), 2603 (v0 symbol mangling).
- Go `errors` package, `errors.Is`/`As`/`Join`, Go 1.13/1.20 release notes.
- Zig Language Reference: error sets, error unions, `errdefer`, error-return traces.
- Eiffel Design by Contract (Bertrand Meyer); Ada/SPARK reference manual.
- Clang command-line reference (frame pointers, split-debug); GDB separate debug files; `debuginfod`;
  Linux `perf`.

---

# APPENDIX A — Key file map

| Path | Role |
|---|---|
| `lib/kernel.zap` | Core macros/builtins; `raise/1` (currently a hard abort) |
| `lib/memory/{arc,arena,leak,tracking,no_op,manager}.zap` | Memory-manager marker types |
| `src/diagnostics.zig` | Compiler `DiagnosticEngine`; to be generalized into the shared report core |
| `src/runtime.zig` | Embedded runtime; `raise`/`panic` (~7041 / ~6804), ARC machinery |
| `src/parser.zig`, `src/lexer.zig`, `src/ast.zig` | Front end; spans/`SourceSpan`; parser bails first error |
| `src/scope.zig` | Scopes; `TypeProvenance`; visible-name collection for suggestions |
| `src/hir.zig` / `src/ir.zig` | Lowering; `buildErrorPipe` / `lowerErrorPipeChain` / `match_error_return` / `try_call_named` (`~>`) |
| `src/zir_backend.zig` / `src/zir_builder.zig` | The only codegen path; **no `dbg_stmt` emission today** |
| `src/memory/{leak,tracking}/manager.zig` | Zig leak/tracking backends (raw stderr reports) |
| `src/monomorphize.zig`, `src/perceus.zig`, `src/arc_*.zig` | Monomorphization, Perceus reuse, ARC ownership/liveness |
| `~/projects/zig` | The Zig fork. `src/zir_api.zig` = C-ABI; exports `zir_builder_emit_dbg_stmt` (~:3115); owns Sema, DWARF, LLVM, `std.debug` |

# APPENDIX B — Glossary

- **`pub error`** — Zap declaration form for exception types. **Front-end-only desugar**
  (`src/desugar.zig`) to `pub struct X + pub impl Error for X`. Auto-injects `message :: String =
  "<TypeName>"` and `cause :: ?Error = nil` fields if the user did not declare them. Auto-generates
  `message/1`, `kind/1`, `source/1`, `code/1` methods on the `Error` protocol. Inline methods inside
  the body override the auto-generated defaults. `pub` makes the type matchable as API surface;
  bare `error` (no `pub`) is renderable-only/private.
- **Field default** — general `pub struct` syntax for declaring a default value on a field:
  `field :: Type = expr`. Evaluated at construction time when the field is omitted in a struct
  literal. Introduced alongside `pub error` but applies to any `pub struct`.
- **Auto-injected field** — a field synthesized by a desugar pass (currently only `pub error`'s
  desugar). `pub error` injects `message :: String = "<TypeName>"` and `cause :: ?Error = nil` only
  when the user has not declared them; user declarations always win.
- **`@code Zxxxx`** — optional attribute on a `pub error` declaration specifying a stable numeric
  error code. CI lint requires it on any `pub error` reaching a `pub` API surface. Codes are public
  API; never reuse a retired code.
- **`raise "string"` shorthand** — sugar for `raise %RuntimeError{message: "string"}`. `RuntimeError`
  is the stdlib's `pub error RuntimeError {}`; the auto-injected `message` field carries the
  shorthand payload. CI lint flags string-`raise` on `pub` API surfaces.
- **ZIR** — Zig Intermediate Representation. Zap emits ZIR directly via the fork's C-ABI; the fork
  runs Sema + LLVM on it. There is no Zig source-text codegen.
- **Sema** — the Zig compiler's semantic-analysis stage (type checking, comptime) inside the fork.
- **HIR / IR** — Zap's high-level and lower intermediate representations before ZIR.
- **Monomorphization** — specializing generic functions per concrete type (zero-cost generics).
- **ARC** — Atomic Reference Counting; Zap's default memory management. No tracing GC. Reference
  cycles are not constructible from the immutable surface, so ARC reclaims everything a Zap program
  can build (see Decision 3).
- **Perceus** — compile-time reference-counting + reuse analysis (PLDI 2021). Zap uses Perceus to
  insert drops/reuses precisely. Garbage-free for cycle-free programs only — and every Zap program
  is cycle-free by construction.
- **Bacon–Rajan** — synchronous trial-deletion cycle detector (ECOOP 2001). Evaluated by Decision 3
  and not adopted: Zap's immutable surface makes reference cycles structurally impossible, so there
  is nothing for a detector to find.
- **Effect / effect row / handler** — algebraic-effects terms. Zap has a hybrid effects system
  (monomorphization + defunctionalized CPS). The error effect is *one-shot abortive* — admits
  direct lowering per Leijen 2017's selective-CPS theorem.
- **One-shot abortive handler** — an effect handler that never resumes its continuation. The
  subset of algebraic-effect handlers compilable to error-unions without CPS plumbing.
- **Selective CPS** — Leijen's compilation strategy: translate only effectful parts to CPS, leaving
  the pure happy path direct-style.
- **Catch-basin (`~>`)** — Zap operator: handle an unmatched piped value and skip remaining pipe
  steps. Today's `~>` IR is payload-insensitive (a known landmine).
- **`TryProject(value, ok_var, err_var)`** — additive IR node, shipped then **removed in the
  deflation pass** together with the `?` operator that consumed it. `~>` keeps its own bespoke
  `error_pipe` lowering; with `?` gone there was no second consumer to justify the shared node.
- **ERT / error-return trace** — Zig feature: a trace of where an error value was first returned
  and each propagation point. Distinct from a call stack. The fork supports it; Zap currently only
  has the `pop_error_return_trace` Call-flag hook wired.
- **`errdefer`** — Zig's error-only cleanup (prior art): runs only when the enclosing function
  returns an error; distinct from Zig's `defer`, which always runs. Zap shipped `defer`/`errdefer`
  then **rejected them in the deflation pass** — ARC handles deterministic release and `after` is
  the explicit always-run cleanup, so an imperative scope-cleanup statement is redundant.
- **Infallible allocation** — allocator API contract that allocation either succeeds or the program
  is abandoned (vs. fallible allocation that returns an error). Zap's `Memory.ARC` is infallible
  by default; `try_alloc` opts into fallible code paths.
- **Abandonment** — fail-fast for bugs / impossible states; *not* a recoverable error. Midori's
  term for what `raise`/`panic` does to defects.
- **`Never`** — Zap's bottom/uninhabited type; `raise/1` currently returns `Never`.
- **`Memory.Tracking` / `Memory.Leak`** — diagnostic build-time memory managers; CI tools, not
  production. Currently emit raw stderr lines with no Zap-level attribution.
- **`zap explain Zxxxx`** — *proposed* (does not exist): `rustc --explain`-style long-form
  documentation keyed by stable numeric error code.
- **`MachineApplicable` / `MaybeIncorrect`** — rustc's suggestion-applicability taxonomy; controls
  whether an automated tool may apply the suggested fix.
- **Split-debug** — debug info shipped separately from the stripped release binary, keyed by build
  ID (`.dwo`/`.dSYM`/`debuginfod`). Lets release binaries stay lean while still being symbolicable.
- **`:zig.Struct.fn(...)`** — Zap syntax to call an embedded-runtime/Zig primitive from Zap code.

*End of brief.*

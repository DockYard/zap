# AI-Optimized Language Design Plan

> "AI-optimized" should mean auditable by default, not just easy to emit.

This plan defines how Zap evolves toward a language optimized not just for AI
code generation, but for AI (and human) code *verification*. The guiding
principle: intent and constraints must live *in the artifact*, not alongside it.

## Design Philosophy

Most "AI-friendly" language discussions focus on the generation side — making it
easy for an LLM to produce syntactically valid code. But the harder and more
valuable problem is: can a human or AI *audit* what the code does without
reading every implementation body?

Three properties make code auditable:

1. **Strict types** — function signatures are machine-checkable contracts
2. **Explicit effects** — what a function *does* (IO, failure, state) is visible
   at the boundary, not hidden in the body
3. **Clean dependency graphs** — modules declare what they depend on; no global
   state, no implicit imports, no action-at-a-distance

Zap already delivers (1) and (3). This plan adds (2) through algebraic effects.

## Current Strengths

### Ownership in the type system

```zap
def transfer(data :: unique String) :: shared String do
  ...
end
```

The `unique`/`shared`/`borrowed` qualifiers are compiler-enforced. A reader
knows from the signature alone what ownership transitions occur. Constraints
live in the artifact.

### Strict types with no implicit coercion

Return type inference was removed. Every function boundary is a
machine-checkable contract. No silent numeric widening, no coercion.

### Mandatory module scoping

The `defmodule` requirement means no ambient global namespace. Every function
has a module home. Cross-module references are explicit (`Module.function()`).

### Immutable-by-default semantics

Persistent data structures (List, Map) and immutable bindings mean values don't
change in place. The absence of mutation is itself an effect guarantee.

### Static memory behavior

The escape analysis lattice, Perceus reuse analysis, and ARC optimizer mean
memory behavior is statically determined. No runtime profiler needed to
understand allocation patterns.

## What's Missing: Effects

Zap currently sits in the Elixir camp — any function can do IO or side effects
with no indication in the signature. A function that reads from disk looks
identical to a pure computation. This is the gap.

---

## Algebraic Effects

### What they are

An algebraic effect splits a function into two parts: **performing** an
operation and **handling** it. The function that performs an effect doesn't know
how it's implemented. A handler, somewhere up the call stack, provides the
implementation.

The key mechanism: performing an effect suspends the function, gives control to
the handler, and the handler can **resume** execution with a value.

```zap
# Effect declaration — interface only, no implementation
effect FileSystem do
  read(path :: String) :: String
  write(path :: String, data :: String) :: nil
end

# This function PERFORMS the effect — doesn't know how it's fulfilled
def process_config() with FileSystem :: String do
  data = FileSystem.read("/etc/config")
  parse(data)
end
```

Different handlers provide different implementations:

```zap
# Production — hits disk
handle process_config() with
  FileSystem.read(path, resume) -> resume.(File.read!(path))
  FileSystem.write(path, data, resume) -> resume.(File.write!(path, data))
end

# Test — pure, in-memory, deterministic
handle process_config() with
  FileSystem.read(_, resume) -> resume.("test_key=42")
  FileSystem.write(_, _, resume) -> resume.(nil)
end
```

### Why algebraic (not just tracked)

A regular effect system just *labels* what a function does. The implementation
is baked in. Algebraic effects decouple the operation from its implementation:

| Feature | Regular effects | Algebraic effects |
|---|---|---|
| Track what functions do | Yes | Yes |
| Swap implementations | No | Yes (handlers) |
| Dependency injection | Needs framework | Built into the language |
| Testability | Mock libraries | Just provide a test handler |
| Composability | Manual | Handlers compose independently |

### One mechanism replaces many

Each of these is a specific pattern of perform + handle:

| Feature | As an algebraic effect |
|---|---|
| Exceptions | Perform effect, handler doesn't resume |
| Async/await | Perform `suspend`, scheduler handler resumes later |
| Generators | Perform `yield`, consumer handler resumes for next |
| State | Perform `get`/`set`, handler carries state between resumptions |
| Nondeterminism | Perform `choose`, handler resumes multiple times |
| Logging | Perform `log`, handler decides destination |

Without algebraic effects, each is a separate language feature. With them, one
mechanism.

### Natural fit with functional programming

Effects solve the central tension in FP: pure functions and immutable data are
the ideal, but real programs do things. Effects let Zap keep the ergonomic
surface while recovering the reasoning power that makes functional programming
valuable:

- **Ownership qualifiers** already constrain *what a function does with its arguments*
- **Effect annotations** extend this to *what a function does to the world*
- Together: complete picture of a function's behavior from its signature alone

### Natural fit with Zap's syntax

Effect handlers are pattern matches on operations — something Zap's
multi-clause dispatch model already supports:

```zap
# Handler clauses are pattern-matched function clauses over effect operations
handle result with
  Logger.log(msg, resume) ->
    IO.puts(msg)
    resume.(nil)

  FileSystem.read(path, resume) ->
    resume.(File.read!(path))
end
```

Modules become natural effect boundaries — the module defines the effect
interface, the caller provides the handler.

---

## Implementation Strategy: Hybrid

### Decision

Use **static effect resolution** (monomorphization) when the handler is known
at compile time, and **CPS transformation** when the handler is dynamic. The
compiler picks the strategy automatically.

### Rationale

- ~90% of real usage has statically known handlers → zero runtime cost
- ~10% edge cases need dynamic dispatch → CPS with defunctionalized continuations
- The developer never sees the difference

### Path 1: Static Resolution (the common case)

When the handler is statically known, the compiler inlines it directly at the
perform site. Effects are completely erased — ZIR sees normal function calls.

```zap
# Source
def process() with FileSystem :: String do
  FileSystem.read("/config")
end

handle process() with RealFileSystem

# After monomorphization — no effects, no continuations
def process__RealFileSystem() :: String do
  RealFileSystem__read("/config")   # direct call
end
```

**Properties:**
- Zero runtime cost
- No continuations, no closures, no overhead
- Tail call optimization fully preserved
- ZIR emission is trivial — just normal function calls

### Path 2: CPS Transformation (the dynamic case)

When the handler is not statically known, transform effectful functions so the
continuation ("what happens after this point") becomes an explicit closure
parameter. This transformation happens in Zap's IR, *above* ZIR — Zig never
needs to know about continuations.

```zap
# Source
def deep_function() with FileSystem :: String do
  x = compute_something()
  data = FileSystem.read("/config")
  transform(x, data)
end

# Compiler-generated CPS form (internal representation)
def deep_function(handler, k) do
  x = compute_something()
  handler.read("/config", fn(data) ->
    k.(transform(x, data))
  end)
end
```

The continuation is just a closure. Zig knows closures.

**Properties:**
- Works entirely within Zap's compilation pipeline — no Zig/LLVM changes
- Continuation closures are defunctionalized via lambda sets (existing infrastructure)
- Escape analysis determines allocation strategy for continuations
- Perceus reuse analysis handles linear-use continuations

### Tail Call Optimization

TCO behavior depends on the path and handler shape:

| Scenario | TCO preserved? |
|---|---|
| Static resolution | Always |
| CPS + tail-resumptive handler (`resume` in tail position) | Yes |
| CPS + non-tail-resumptive handler (work after `resume`) | No — inherent to the handler's semantics |

**Tail-resumptive handlers** are handlers where `resume` is the last operation
in every clause. The compiler detects this and compiles them as direct-style
loops — no continuation allocation at all.

Most real handlers are tail-resumptive (logging, IO, state, file system). The
compiler warns when a non-tail-resumptive handler is used in a recursive
context.

---

## Debug Effects: Erased Diagnostics

### Problem

If `inspect` carries an IO effect, adding it for debugging changes a pure
function's effect signature — forcing signature updates up the call chain just
to print a value.

### Solution

Debug/diagnostic functions are a special effect class that the compiler
**erases in release builds** and **ignores for effect checking**.

```zap
defmodule Kernel do
  @debug
  def inspect(value :: T) :: T do
    :zig.inspect(value)
  end
end
```

**Behavior:**
- `inspect` does not count toward a function's effect signature
- The function remains pure for analysis, optimization, and caller requirements
- Calls are kept in debug builds, stripped in release builds
- The pass-through semantics (`T -> T`) are preserved — pipelines work
  identically with or without inspect

The `@debug` annotation marks a function as semantically transparent. The
compiler can verify this: the function's return type must equal its input type,
and removing the call must not change the program's result.

### Categories

| Category | Effect tracking | Release behavior | Example |
|---|---|---|---|
| Semantic effects | Tracked, must be handled | Preserved | IO, FileSystem, Database |
| Diagnostic effects | Ignored by checker | Erased | inspect, trace, debug_assert |

---

## Existing Infrastructure That Enables This

### Lambda set defunctionalization

`src/lambda_sets.zig` (~800 lines). 0-CFA closure flow analysis. Per-call-site
lambda sets, contification detection. **Directly applicable** to CPS
continuations — the compiler knows all possible continuations at each point and
represents them as tagged unions instead of heap-allocated closures.

### Escape analysis

`src/escape_lattice.zig` + `src/generalized_escape.zig`. 6-element lattice,
field-sensitive tracking, virtual objects. **Determines whether continuation
closures escape their handler scope.** In the common case (handler resumes
exactly once), the continuation is stack-allocated or eliminated.

### Perceus reuse analysis

`src/perceus.zig` (~900 lines). Pairs drops with allocations for in-place
mutation. **If a continuation is allocated and used exactly once** (linear use),
Perceus reuses the memory.

### Interprocedural analysis

`src/interprocedural.zig` (~1000 lines). Bottom-up summary computation over
call graph SCCs. **Extended to propagate effect summaries** — which effects a
function performs, transitively through the call graph.

### ARC optimizer

`src/arc_optimizer.zig`. Skip ARC for stack-allocated values, eliminate
redundant retain/release pairs, hoist loop-invariant ops. **Applies directly to
continuation closures** in the CPS path.

### Region solver

`src/region_solver.zig` (~1100 lines). Non-lexical lifetime solving, storage
mode analysis. **Determines optimal allocation region for continuation
closures** when they can't be stack-allocated.

---

## Implementation Phases

### Phase 1: Effect Declarations and Annotations

**Goal:** Syntax and type-checking for effects. No runtime behavior change.

- Add `effect` declaration syntax to parser
- Add `with EffectName` clause to function signatures
- Add effect set to `QualifiedType` in `src/types.zig`
- TypeChecker validates that performed effects are declared in the signature
- TypeChecker propagates effects through the call graph
- Error on performing an undeclared effect

**Deliverable:** Effect annotations compile and type-check. Performing an
undeclared effect is a compile error. No code generation changes — effects are
erased before HIR.

### Phase 2: Static Effect Resolution

**Goal:** Monomorphize effects when handlers are statically known.

- Add `handle ... with` expression syntax to parser
- Resolve handler at compile time when the handler is a known module/function
- Generate monomorphized function variants per handler
- Lower to HIR/IR as direct function calls — no special codegen needed
- Extend interprocedural analysis to track effect summaries

**Deliverable:** Effects with static handlers compile to native binaries with
zero overhead. The common case works end-to-end.

### Phase 3: CPS Transformation

**Goal:** Support dynamic handlers via continuation-passing.

- Implement CPS transform in IR lowering for effectful functions
- Detect tail-resumptive handlers and optimize to direct-style loops
- Integrate with lambda set defunctionalization for continuations
- Integrate with escape analysis to determine continuation allocation strategy
- Integrate with Perceus for linear-use continuation reuse
- Integrate with ARC optimizer for continuation lifetime management

**Deliverable:** Dynamic handlers work. Tail-resumptive handlers have no stack
growth. Continuations are defunctionalized and escape-analyzed.

### Phase 4: Debug Effect Erasure

**Goal:** `@debug`-annotated functions bypass effect checking and are erased in
release builds.

- Add `@debug` function annotation to parser
- TypeChecker skips effect propagation for `@debug` functions
- Verify semantic transparency: return type equals input type
- IR lowering strips `@debug` calls when optimization level is release
- Apply to `Kernel.inspect` in stdlib

**Deliverable:** `inspect` works in pipelines without affecting effect
signatures. Release builds have zero debug overhead.

### Phase 5: Standard Effect Library

**Goal:** Ship built-in effects for common operations.

- `IO` — print, read, file operations
- `Failure` — recoverable errors (replaces exceptions pattern)
- `State` — thread state through computation
- `Async` — concurrent operations (future work, post-multi-file)

**Deliverable:** Idiomatic Zap programs use effects for IO and error handling.
The stdlib demonstrates the pattern.

---

## Syntax Summary

### Effect declaration

```zap
effect FileSystem do
  read(path :: String) :: String
  write(path :: String, data :: String) :: nil
end
```

### Performing effects

```zap
def load_config() with FileSystem :: Config do
  raw = FileSystem.read("/etc/app.conf")
  Config.parse(raw)
end
```

### Handling effects

```zap
handle load_config() with
  FileSystem.read(path, resume) ->
    resume.(File.read!(path))
  FileSystem.write(path, data, resume) ->
    File.write!(path, data)
    resume.(nil)
end
```

### Multiple effects

```zap
def process() with FileSystem, Logger :: Result do
  Logger.info("starting")
  data = FileSystem.read("/input")
  Logger.info("loaded")
  transform(data)
end
```

### Effect composition in modules

```zap
defmodule App do
  effect Database do
    query(sql :: String) :: Rows
    execute(sql :: String) :: i64
  end

  def get_users() with Database :: List(User) do
    Database.query("SELECT * FROM users")
    |> Rows.map(&User.from_row/1)
  end
end
```

### Debug-annotated functions

```zap
defmodule Kernel do
  @debug
  def inspect(value :: T) :: T do
    :zig.inspect(value)
  end
end

# Usage — no effect signature impact
def pure_function(x :: i64) :: i64 do
  x * 2
  |> inspect()    # erased in release, invisible to effect checker
  |> add_one()
end
```

---

## Design Constraints

1. **Effects must not break existing code.** Functions without `with` clauses
   are implicitly effect-polymorphic (they may perform any effect). Existing
   Zap programs continue to compile and run without modification. Effect
   annotations are opt-in — the system becomes stricter as you add them.

2. **Static resolution is the priority.** The CPS path exists for completeness,
   but the language should guide users toward statically resolvable patterns.
   Most real programs should never hit the CPS path.

3. **No multi-shot resumptions in v1.** Handlers that resume more than once
   (nondeterminism, backtracking) require continuation copying, which is
   expensive and complex. Defer to a future version. Single-shot resumptions
   cover exceptions, IO, state, async, generators.

4. **Handler scope is lexical.** A `handle` block establishes a handler for its
   body. Handlers don't leak across module boundaries. This keeps dependency
   graphs clean.

5. **Effect declarations are nominal.** Two effects with identical operations
   are distinct types. This prevents accidental handler mismatches.

6. **The `@debug` annotation is restricted.** Only functions with pass-through
   semantics (`T -> T`) may be annotated `@debug`. The compiler verifies this.

---

## Success Criteria

When this plan is complete, a Zap function signature tells you:

- **What data it takes** — parameter types
- **What it owns** — ownership qualifiers (`unique`, `shared`, `borrowed`)
- **What it returns** — return type
- **What it does** — effect set (`with FileSystem, Logger`)

The artifact is the source of truth. Intent and constraints live in the code,
not outside it. Software becomes not just easy for AI to produce, but possible
for AI to *trust*.

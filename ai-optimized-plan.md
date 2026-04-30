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
3. **Clean dependency graphs** — structs declare what they depend on; no global
   state, no implicit imports, no action-at-a-distance

Zap delivers (1) and (3). This plan adds (2) through compiler-derived effect
analysis exposed via the MCP server.

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

### One struct per file, name equals path

Every `.zap` file contains exactly one `struct`. The struct name maps
directly to the file path: `Config.Parser` lives in `lib/config/parser.zap`.
The compiler enforces this — a mismatch is a compile error.

This means:
- The file system IS the struct dependency graph
- `ls -R lib/` shows every struct in the project
- An agent can navigate the codebase by struct name without any tooling
- Cross-struct references are explicit and traceable to a specific file

### Import-driven compilation

The compiler starts from the entry point and follows struct references to
discover which files to compile. No globs, no manifests listing source files.
If a file isn't reachable from the entry point, it isn't compiled.

This gives the compiler a precise dependency graph — it knows exactly which
files depend on which, enabling incremental recompilation and parallel
compilation of independent branches.

### Mandatory struct scoping

The `struct` requirement means no ambient global namespace. Every function
has a struct home. Cross-struct references are explicit (`Struct.function()`).

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

## Compiler-Derived Effects

### The insight

The compiler already knows which functions perform side effects. The
interprocedural analysis traces the call graph transitively. It knows which
leaf functions are `:zig.*` intrinsics (IO, file operations, system calls).
It knows which functions call those intrinsics, and which functions call those
functions.

Effect information is a derived property of the call graph — not something the
programmer needs to write in the source.

### How it works

The compiler's interprocedural analysis (`src/interprocedural.zig`) already
computes bottom-up summaries over call graph SCCs. Extending `FunctionSummary`
with an effect set is a natural addition:

1. Leaf functions that call `:zig.*` intrinsics are tagged with their effect
   (IO, FileSystem, System, etc.)
2. The interprocedural fixpoint propagates effects upward through the call graph
3. Every function ends up with a complete effect set — the transitive closure
   of all effects performed by it and everything it calls

No new syntax. No new parser constructs. No `with` clauses. The compiler
computes it automatically from the code that already exists.

### Exposure via MCP

The `zap mcp` server exposes an `effects` tool that returns the derived effects
for any function:

```json
{
  "function": "Config.load",
  "effects": ["FileSystem.read"],
  "transitive": true,
  "call_chain": [
    { "function": "Config.load", "calls": "IO.read_file", "line": 5 },
    { "function": "IO.read_file", "calls": ":zig.read", "line": 3 }
  ]
}
```

An AI agent (or human via tooling) can query any function's effects without
reading its body or tracing the call graph manually. The compiler did the work.

### Why not syntax-level effects

Earlier iterations of this plan proposed algebraic effects with explicit syntax:
`effect` declarations, `with` clauses on function signatures, `handle` blocks.
This was reconsidered for several reasons:

1. **The compiler already has the information.** The call graph + interprocedural
   analysis already tells you what every function does. Adding syntax just makes
   the programmer manually write what the compiler can derive.

2. **Per-file compilation makes it natural.** With one-struct-per-file and
   import-driven compilation, the compiler builds a precise struct dependency
   graph. Effect propagation is a straightforward extension of this graph.

3. **The MCP server is the right interface.** The goal is auditability — knowing
   what a function does. The MCP server delivers this as a queryable tool. An
   agent asks `effects("Config.load")` and gets the answer. Syntax annotations
   would serve the same purpose but with more programmer burden.

4. **No new concepts to learn.** Algebraic effects are powerful but complex.
   Handlers, resumptions, CPS transformations — all necessary for a full effect
   system but unnecessary if the goal is just knowing what functions do.

5. **Opt-in strictness is still possible.** A future `@pure` annotation could
   let programmers assert that a function has no effects. The compiler verifies
   this against its derived analysis. This is simpler than a full effect system
   and achieves the same auditing goal.

### What algebraic effects would have added (and what we lose)

Algebraic effects aren't just about tracking effects — they decouple performing
an operation from handling it. This enables:

- **Swappable implementations** — test handler vs production handler
- **Built-in dependency injection** — no framework needed
- **Exceptions, async, generators** — as library patterns, not language features

These are genuinely valuable. But they're also complex to implement (CPS
transformation, handler resolution, continuation management) and orthogonal to
the auditability goal. If Zap needs them later, they can be added. The
compiler-derived effect tracking doesn't preclude them.

---

## Debug Effects: Erased Diagnostics

### Problem

`inspect` performs IO. If the compiler tracks effects, adding `inspect` for
debugging would make a pure function appear effectful — potentially confusing
both the programmer and the agent.

### Solution

Debug/diagnostic functions are annotated with `@debug`. The compiler:

- Excludes `@debug` calls from effect derivation
- Erases them in release builds
- Verifies pass-through semantics (`T -> T`)

```zap
# lib/kernel.zap
struct Kernel do
  @debug
  def inspect(value :: T) :: T do
    :zig.inspect(value)
  end
end
```

**Behavior:**
- `inspect` does not appear in a function's derived effect set
- The function remains pure for analysis, optimization, and MCP queries
- Calls are kept in debug builds, stripped in release builds
- The pass-through semantics are preserved — pipelines work identically
  with or without inspect

### Categories

| Category | Effect tracking | Release behavior | Example |
|---|---|---|---|
| Semantic effects | Derived, queryable via MCP | Preserved | IO, FileSystem, System |
| Diagnostic effects | Excluded from derivation | Erased | inspect, trace, debug_assert |

---

## Existing Infrastructure That Enables This

### Interprocedural analysis

`src/interprocedural.zig` (~1000 lines). Bottom-up summary computation over
call graph SCCs. **The foundation for effect derivation.** Extend
`FunctionSummary` with an `effect_set` field and propagate through the fixpoint.

### Lambda set defunctionalization

`src/lambda_sets.zig` (~800 lines). 0-CFA closure flow analysis. Per-call-site
lambda sets, contification detection. Ensures the call graph is precise —
closure calls are resolved to concrete targets, so effect propagation follows
actual control flow, not conservative approximations.

### Escape analysis

`src/escape_lattice.zig` + `src/generalized_escape.zig`. 6-element lattice,
field-sensitive tracking. Complements effect analysis — together they describe
what a function does to memory (escape analysis) and what it does to the world
(effect analysis).

### Per-file compilation

The two-pass compilation architecture (collect globally, compile per-file,
merge IR) means the interprocedural analysis sees the complete call graph
across all files and dependencies. Effect derivation is whole-program.

---

## Implementation Phases

### Phase 1: Effect derivation in interprocedural analysis

**Goal:** The compiler knows every function's effects.

- Classify `:zig.*` intrinsics by effect category (IO, FileSystem, System, etc.)
- Add `effect_set` field to `FunctionSummary`
- Propagate effects through the interprocedural fixpoint
- Store results in `AnalysisContext`

**Deliverable:** After compilation, `AnalysisContext` contains the derived
effect set for every function. No syntax changes, no user-visible behavior
change yet.

### Phase 2: MCP `effects` tool

**Goal:** Agents can query any function's effects.

- Add `effects` tool to `zap mcp`
- Returns effect set, call chain showing how effects propagate
- Integrates with `call_graph` tool for combined queries

**Deliverable:** An agent calls `effects("Config.load")` and gets back
`["FileSystem.read"]` with the call chain explaining why.

### Phase 3: `@debug` annotation

**Goal:** Debug functions are excluded from effect derivation.

- Add `@debug` function annotation to parser
- Compiler skips `@debug` calls during effect propagation
- Verify semantic transparency: return type equals input type
- IR lowering strips `@debug` calls in release builds
- Apply to `Kernel.inspect` in stdlib

**Deliverable:** `inspect` works in pipelines without affecting derived effects.
Release builds have zero debug overhead.

### Phase 4: `@pure` assertion (optional)

**Goal:** Programmers can assert purity and the compiler verifies it.

- Add `@pure` function annotation
- Compiler checks that the derived effect set is empty
- Compile error if a `@pure` function transitively performs effects

**Deliverable:** Critical functions can be marked `@pure` with compiler
enforcement. This is opt-in strictness, not mandatory annotation.

---

## Success Criteria

When this plan is complete, a Zap function's full behavior is knowable from:

- **What data it takes** — parameter types (in the source)
- **What it owns** — ownership qualifiers (in the source)
- **What it returns** — return type (in the source)
- **What it does** — derived effects (queryable via MCP)
- **Where it lives** — file path = struct name (in the file system)
- **What it depends on** — struct references (in the import graph)

The source code tells you types, ownership, and structure. The compiler tells
you effects, memory behavior, and dependencies. Together, the artifact is the
complete source of truth. Software becomes not just easy for AI to produce, but
possible for AI to *trust*.

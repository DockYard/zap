# Protocol Dispatch Problem: Full Context for Deep Research

## What is Zap?

Zap is a compiled functional programming language inspired by Elixir. It has pattern matching, pipe operators, algebraic types, protocols, and structs. Zap compiles to native binaries — no VM, no garbage collector.

## How Zap Compiles

Zap does **not** compile to Zig source text. It compiles to **ZIR** (Zig Intermediate Representation) via C-ABI calls to a forked Zig compiler. The pipeline:

```
Zap source (.zap files)
  → Parse (AST)
  → Collect (scope graph, type surface)
  → Macro expand (Kernel macros: if, unless, and, or, |>)
  → Desugar (pipes, for comprehensions, string interpolation)
  → Re-collect
  → HIR (High-level IR per module, type checking)
  → Monomorphization (whole-program generic specialization)
  → IR (flat instruction-based representation)
  → ZIR emission (C-ABI calls to Zig fork)
  → Zig compiler (Sema → codegen → link → native binary)
```

### The Zig Fork

Zap depends on a fork of Zig 0.16.0 at `~/projects/zig`. The fork adds two files:

- `src/zir_api.zig` — C-ABI exports for creating compilations, injecting ZIR, and running the compiler pipeline
- `src/zir_builder.zig` — A builder API for constructing ZIR instruction sequences (functions, params, calls, struct types, etc.)

The fork is compiled into `libzap_compiler.a` which Zap links against. Zap calls C-ABI functions like `zir_builder_begin_func`, `zir_builder_emit_call`, `zir_builder_emit_import`, `zir_builder_inject_struct`, etc.

### Each Zap Struct = One Zig ZIR Module

This is the critical architectural fact. Each Zap struct (e.g., `Math`, `IO`, `Range`, `Test.BoolTest`) becomes its own Zig ZIR "module" — a separate compilation unit with its own namespace. The ZIR builder emits functions into each module separately via:

1. `zir_compilation_add_struct_source(ctx, "ModuleName", stub_source)` — registers a module
2. `zir_builder_create()` — creates a new ZIR builder handle
3. Emit functions into it via `zir_builder_begin_func`, `zir_builder_emit_*`, etc.
4. `zir_builder_inject_struct(builder, ctx, "ModuleName")` — injects the built ZIR into that module

Cross-module references use `@import("OtherModule")` in ZIR. When module `Test.BoolTest` calls `Math.square(5)`, the ZIR emits `@import("Math").square(5)`.

### Cross-Module Struct Type Identity Problem

When a struct type (e.g., `Range` with fields `start`, `end`, `step`) is defined in its own ZIR module, and another module creates an instance of that struct, the types don't match across module boundaries. Each module creates its own local anonymous struct type via `struct_init_anon`, and Zig's type system considers these to be different types even if the fields are identical. This is the **fundamental unsolved problem** blocking protocol dispatch.

## What Are Protocols in Zap?

Protocols are Zap's equivalent of Elixir protocols / Rust traits / Haskell typeclasses. They define an interface that multiple types can implement.

### Current Zap Protocol Syntax

```zap
# lib/enumerable.zap — Protocol definition
pub protocol Enumerable {
  fn next(state) -> {Atom, i64, any}
}

# lib/list/enumerable.zap — Implementation for List
pub impl Enumerable for List {
  pub fn next(list :: [member]) -> {Atom, member, [member]} {
    :zig.List.next(list)
  }
}

# lib/range/enumerable.zap — Implementation for Range
pub impl Enumerable for Range {
  pub fn next(range :: Range) -> {Atom, i64, Range} {
    :zig.Range.next(range)
  }
}
```

The protocol defines that `Enumerable` types must have a `next/1` function. The `next` function takes iteration state and returns a 3-tuple: `{:cont, value, next_state}` to yield a value, or `{:done, 0, nil}` when done.

### Where Protocols Are Used: `for` Comprehensions

The primary consumer of the Enumerable protocol is `for` comprehensions:

```zap
for x <- 1..5 {
  x * 2
}
# => [2, 4, 6, 8, 10]
```

This should dispatch through `Enumerable.next` — the `for` desugarer should generate code that calls the appropriate `next` implementation based on the iterable's type.

## The Problem: Protocol Dispatch is Completely Disabled

In `src/compiler.zig` at line 1103:

```zig
if (false) { // Reserved for future dynamic protocol dispatch
    // ... protocol dispatch synthesis code ...
}
```

The entire protocol dispatch system is gated behind `if (false)`. This means:

1. **Protocol definitions compile but are never enforced.** The `Enumerable` protocol says `next/1` is required, but nothing checks that impls actually provide it.
2. **Impl conformance is never validated.** `lib/map/enumerable.zap` defines `reduce` instead of `next`, violating the protocol. No error is raised.
3. **No dispatch happens through protocols.** The `for` comprehension desugarer bypasses the protocol entirely.

### How `for` Comprehensions Work Now (Broken Shortcut)

Instead of dispatching through the Enumerable protocol, the desugarer in `src/desugar.zig` hardcodes which runtime function to call based on the iterable's AST type:

```zig
// In desugarForExpr (line 910):
if (fe.iterable.* == .range) {
    return self.desugarForEnumerable(fe, "Range");  // hardcoded "Range"
}
```

The `desugarForEnumerable` function generates:
```
fn __for_N(__state) -> [i64] {
  case :zig.Range.next(__state) {     // <-- hardcoded :zig.Range.next
    {:done, _, _} -> []
    {:cont, x, __next_state} -> [body | __for_N(__next_state)]
  }
}
```

This is a `:zig.Range.next()` bridge call — it calls the Zig runtime function directly. It does NOT go through any protocol dispatch. The module name "Range" is hardcoded in the desugarer.

For lists, it doesn't even use `desugarForEnumerable` — it uses a completely separate recursive head/tail pattern (lines 927-1005) that doesn't call `next` at all.

### What This Means

- Only Range `for` comprehensions use the `next` pattern, and only by hardcoding `:zig.Range.next`
- List `for` comprehensions use a completely different code path (head/tail recursion)
- Map `for` comprehensions don't exist at all
- User-defined types cannot implement Enumerable and use `for` — the desugarer doesn't know about them
- The protocol system is pure decoration — it compiles to dead code

## What Was Attempted (and Why It Failed)

### Attempt: Synthesized Dispatch Modules

The `if (false)` block in `compiler.zig` (lines 1103-1180) contains code that tried to:

1. Collect all `impl Enumerable for X` declarations
2. For each protocol, synthesize a dispatch module that merges all impl clauses into a single multi-clause function
3. The dispatch function would use pattern matching on the argument type to route to the correct implementation

**Why it failed:**

1. **68 duplicate modules.** Per-module HIR compilation creates duplicates of every protocol and impl. The synthesis code tried to create 68 dispatch modules instead of the expected few. Fixed with deduplication, but this was a symptom of a deeper problem.

2. **Cross-scope clause merging produces invalid ZIR.** Each impl's `next` function is compiled in the scope of its own module. When you merge clauses from `List.Enumerable.next` and `Range.Enumerable.next` into a single synthesized `Enumerable.next` function, the clauses reference variables, types, and imports from their original modules. The merged function can't resolve these cross-module references in a single ZIR module.

3. **Cross-module struct type identity.** Even if you could merge the clauses, the struct types don't match. A `Range` struct created in the `Range` module has a different type identity than a `Range` parameter in the `Enumerable` dispatch module. Zig's type system treats anonymous structs from different modules as distinct types, so pattern matching on struct types fails.

4. **`isGenericHirGroup` misclassified dispatch groups.** The synthesized dispatch function groups were classified as generic (because they had multiple clauses with different parameter types), causing them to be skipped during IR lowering. This produced 0 IR functions for the dispatch module.

### Why the Cross-Module Struct Type Problem Is Fundamental

When Zap emits a struct initialization in ZIR:

```zig
// In module "Range":
const range = Range{ .start = 1, .end = 10, .step = 1 };
```

This uses `struct_init_typed` with a `decl_val("Range")` type ref — the Range type declared in the current module.

But when another module creates a Range:

```zig
// In module "Test.RangeTest":
const range = Range{ .start = 1, .end = 10, .step = 1 };
```

If `findStructDef("Range")` fails (because Range is defined in a different ZIR module), the code falls back to `struct_init_anon` — which creates an anonymous struct `struct { start: i64, end: i64, step: i64 }`. This is a DIFFERENT TYPE from `Range`. Zig's type checker considers them incompatible.

An attempt was made to fix this by emitting `@import("Range").Range` to get the cross-module type, but this produced codegen crashes in Zig's aarch64 backend. That fix was reverted.

## What a Correct Solution Requires

The protocol dispatch problem requires solving these sub-problems:

### 1. Protocol Conformance Checking
The compiler must validate that every `impl Enumerable for X` provides all functions declared in `protocol Enumerable`. Currently `Map.Enumerable` has `reduce` instead of `next` and no error is raised.

### 2. Static Dispatch at the Call Site
When the compiler knows the concrete type at compile time (which is almost always, since Zap is statically typed), it should resolve which impl to use and generate a direct call. For `for x <- some_range { ... }`, the compiler knows `some_range` is a `Range`, so it should call `Range.Enumerable.next` directly.

The desugarer currently does a crude version of this (hardcoding `:zig.Range.next`), but it:
- Only works for Range (the AST type is `.range`)
- Doesn't check the protocol system at all
- Doesn't work for variables whose type is known from type inference but not from AST inspection

### 3. Cross-Module Type Resolution for Dynamic Dispatch (Future)
If Zap ever needs dynamic dispatch (runtime resolution of which impl to call), it needs a way to match struct types across ZIR module boundaries. This is the hardest problem and may require changes to the Zig fork.

### 4. The `for` Desugarer Must Go Through the Protocol
Instead of hardcoding runtime module names, the desugarer (or a later pass) should:
1. Determine the iterable's type
2. Look up which `impl Enumerable for <Type>` exists
3. Generate a call to that impl's `next` function
4. If no impl exists, emit a compile error

This means protocol resolution must happen BEFORE or DURING IR lowering, not as a separate synthesis phase that creates new modules.

## Key Files

| File | Role |
|------|------|
| `src/compiler.zig` | Pipeline orchestration. Contains disabled dispatch synthesis at line 1103. |
| `src/desugar.zig` | Desugars `for` comprehensions. `desugarForEnumerable` hardcodes runtime module names. |
| `src/hir.zig` | HIR builder. Compiles protocol/impl declarations. Contains `ProtocolInfo` and `ImplInfo` types. |
| `src/ir.zig` | IR builder. Lowers HIR to flat instructions. |
| `src/zir_builder.zig` | ZIR emission. Each module gets its own ZIR. `buildProgram` groups functions by module. Cross-module calls use `@import`. |
| `src/types.zig` | Type store. Type checking and resolution. |
| `src/monomorphize.zig` | Whole-program generic specialization. Passes through protocol/impl info. |
| `lib/enumerable.zap` | Protocol definition: `fn next(state) -> {Atom, i64, any}` |
| `lib/list/enumerable.zap` | List impl: calls `:zig.List.next` |
| `lib/range/enumerable.zap` | Range impl: calls `:zig.Range.next` |
| `lib/map/enumerable.zap` | Map impl: **BROKEN** — defines `reduce` instead of `next` |
| `src/runtime.zig` | Zig runtime functions. Contains `Range.next`, `ListOf(T).next`. |
| `~/projects/zig/src/zir_api.zig` | Fork C-ABI surface. |
| `~/projects/zig/src/zir_builder.zig` | Fork ZIR builder. |

## Constraints

1. **No hacks or workarounds.** Every solution must be the correct production-grade fix.
2. **Features belong in Zap code, not hardcoded in the compiler.** The compiler must not know about specific modules like Range, List, Map. It must use the protocol system to resolve dispatch generically.
3. **Zap compiles to ZIR.** The only code generation path is through C-ABI calls to the Zig fork. No Zig source text generation.
4. **Each Zap struct is a separate ZIR module.** This is fundamental to the architecture and cannot be changed without redesigning the entire emission pipeline.
5. **The Zig fork can be modified.** If the solution requires new C-ABI exports or changes to how the fork handles struct types, those changes are acceptable.

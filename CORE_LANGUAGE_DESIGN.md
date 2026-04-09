# Core Language Design For Zap

## Purpose

This document proposes the next set of **core language** features Zap should add, in priority order, without expanding the standard library. The goal is to answer a narrower question than "what should the project build next?":

What language features would most improve Zap as a serious general-purpose programming language?

This document is intentionally about:

- syntax and semantics
- type system features
- control flow features
- abstraction mechanisms
- ownership/effects/concurrency primitives

This document is intentionally not about:

- growing the standard library
- adding more built-in modules
- package ecosystem work
- formatter/LSP/IDE tooling

Those matter, but they are downstream of the core language.

## Current Zap Baseline

Zap already has a meaningful language core:

- modules and visibility
- pattern matching and multi-clause function dispatch
- guards
- `if`, `case`, `cond`, `for`
- macros and `use`
- structs and unions
- imports, aliases, and attributes
- explicit types at boundaries
- ownership syntax in parameters: `shared`, `unique`, `borrowed`

Evidence in the current repo:

- `README.md`
- `src/token.zig`
- `src/parser.zig`
- `src/ast.zig`
- `src/types.zig`
- `test/*.zap`

That means Zap is **not** missing a language identity. It already looks like an Elixir-influenced, native-compiled, typed, macro-capable language with stronger resource semantics than a typical BEAM-style language.

What it lacks is the next layer of features that make such a language scale from "interesting functional core" to "practical general-purpose language".

## Design Goals

The recommendations below assume Zap should optimize for:

1. Native performance without requiring users to think at assembly level.
2. Strong static reasoning where it materially improves correctness.
3. Direct-style ergonomics over monadic ceremony.
4. Functional defaults with explicit escape hatches.
5. A small number of orthogonal core concepts instead of many overlapping ones.
6. Features that can compose cleanly with macros, pattern matching, and ownership.

## What Other Languages Teach Us

This document draws on several mature language designs:

- **Rust**
  - closures capture environment and interact with ownership in a principled way
  - traits provide constrained polymorphism and default methods
  - `Result` plus `?` creates a coherent recoverable error model
  - exhaustive `match` makes algebraic data types practical
  - Sources:
    - <https://doc.rust-lang.org/book/ch13-01-closures.html>
    - <https://doc.rust-lang.org/book/ch10-02-traits.html>
    - <https://doc.rust-lang.org/book/ch06-02-match.html>
    - <https://doc.rust-lang.org/book/ch09-02-recoverable-errors-with-result.html>

- **Haskell / GHC**
  - typeclasses show the design space for ad hoc polymorphism
  - advanced class systems become powerful but can grow complex quickly
  - Source:
    - <https://ghc.gitlab.haskell.org/ghc/doc/users_guide/exts/typeclasses.html>

- **OCaml 5**
  - effect handlers can express concurrency, coroutines, inversion of control, and resumable workflows
  - effect systems are powerful, but the design space is subtle and easy to overshoot
  - Source:
    - <https://ocaml.org/manual/effects.html>

- **Kotlin**
  - `suspend` plus structured concurrency is a successful pragmatic async model
  - coroutines work well because lifecycle and cancellation are part of the design
  - Source:
    - <https://kotlinlang.org/docs/coroutines-overview.html>

- **Elixir**
  - protocols are a practical dispatch mechanism for polymorphic APIs
  - processes plus message passing create a clear concurrency story
  - "let it crash" works because the process model and supervision model are first-class
  - Sources:
    - <https://hexdocs.pm/elixir/Protocol.html>
    - <https://hexdocs.pm/elixir/processes.html>

The central lesson is that successful languages do not merely add features; they choose a small number of **deeply coherent mechanisms**. Zap should do the same.

## Priority Order

Recommended priority order for core language work:

1. Anonymous functions and closures
2. Protocols or traits for constrained polymorphism
3. A principled recoverable error model
4. Complete generics with constraints
5. Exhaustiveness and match analysis
6. First-class ownership semantics for user code
7. Concurrency or effect primitives
8. Secondary refinements: partial application, local functions, derivation, row-like record polymorphism

The first four are the most important. They unlock most of the language's future shape.

## 1. Anonymous Functions And Closures

### Recommendation

Add anonymous functions with lexical capture.

Suggested surface forms to evaluate:

```zap
add = fn(x, y) { x + y }
inc = fn(x) { x + 1 }

pub fn apply_twice(x, f) {
  f(f(x))
}
```

Or, if Zap wants a more expression-focused syntax:

```zap
inc = x -> x + 1
pair = (x, y) -> {x, y}
```

### Why This Is First

Closures are the missing foundation for:

- higher-order programming
- callback APIs
- deferred computation
- async/task spawning later
- iterator and sequence abstractions later
- user-defined control operators that do not require macros

Zap currently has macros, but macros do not replace closures. Macros operate at syntax-expansion time; closures operate at runtime and are essential for ordinary abstraction.

### Design Questions

Zap should settle these semantics explicitly:

1. **Capture model**
   - immutable borrow by default?
   - explicit `move` capture?
   - ownership inferred from use, Rust-style?

2. **Callability model**
   - are closures a single function type?
   - or are there distinct callable capabilities analogous to `Fn`, `FnMut`, `FnOnce`?

3. **Environment representation**
   - closure conversion in the compiler
   - interaction with ARC and ownership
   - whether non-capturing closures can lower to plain function refs

4. **Typing model**
   - full parameter annotations required?
   - inferred parameter types in local contexts?

### Recommendation Details

Zap should start with a **minimal closure model**:

- anonymous functions are expressions
- lexical capture is allowed
- non-capturing closures and function references share a common callable story
- closures are immutable by default
- mutation or consuming captures should be deferred until the ownership model is clearer

That is enough to unlock the language without prematurely committing to the full Rust closure trait lattice.

### Why Not Delay This

If Zap adds protocols, async, or effects before closures, those features will immediately feel incomplete. Closures are the enabling layer for almost every other abstraction feature.

## 2. Protocols Or Traits For Constrained Polymorphism

### Recommendation

Add a single, explicit ad hoc polymorphism mechanism.

The two strongest candidates are:

- **protocols**, closer to Elixir/Swift-style surface ergonomics
- **traits**, closer to Rust-style semantics and constraints

### Why Zap Needs This

Today Zap has:

- functions
- modules
- pattern matching
- macros

That is enough for small programs, but not for scalable abstraction. A serious language needs a way to say:

- this type can be compared
- this type can be formatted
- this type can be iterated
- this type can be serialized
- this generic algorithm only works on values with a specific capability

### Recommendation

Favor a **trait/protocol hybrid with trait-style constraints**.

Concretely:

- declaration syntax should feel lightweight like protocols
- generic constraints should feel explicit and static like traits/typeclasses
- default method implementations should be supported
- coherence rules should be defined early

Possible sketch:

```zap
pub protocol Eq(T) {
  pub fn eq(left :: T, right :: T) -> Bool
}

pub impl Eq(i64) {
  pub fn eq(left :: i64, right :: i64) -> Bool {
    left == right
  }
}
```

Or more Rust-like:

```zap
pub trait Eq(T) {
  pub fn eq(left :: T, right :: T) -> Bool
}
```

### Why Not Full Haskell-Typeclass Power First

Haskell's typeclass ecosystem is very powerful, but the full design space includes:

- multi-parameter classes
- functional dependencies
- associated type families
- overlapping and orphan-instance concerns

This is too much for Zap initially.

Zap should begin with:

- single-parameter protocols/traits
- explicit implementations
- default methods
- no overlap
- coherence rules that avoid ambiguity

### Coherence Matters

Rust's orphan/coherence restrictions are not accidental. They prevent a language from becoming impossible to reason about once many packages exist. Zap should define early whether implementations must live with:

- the protocol
- the type
- or both

The simplest safe rule is Rust-like coherence: an implementation is allowed only when the protocol or the type is local.

## 3. A Principled Recoverable Error Model

### Recommendation

Add a first-class recoverable error model based on explicit result values, with ergonomic propagation syntax.

Suggested direction:

- make recoverable failure explicit in types
- add a propagation operator analogous to Rust's `?`
- reserve `panic` for invariants and unrecoverable failures

### Why Zap Needs This

Zap currently has useful pieces:

- pattern matching
- tuples and unions
- `panic`
- catch basin `~>`

But those pieces do not yet define one canonical answer to ordinary recoverable failure.

Without a clear error model, users will split into incompatible styles:

- `panic`
- tagged tuples like `{:ok, value}` and `{:error, reason}`
- custom unions
- catch-basin pipelines

That fragmentation hurts readability and library design.

### Recommended Shape

Add one standard error-aware sum type at the language level, or at least privileged syntax around it:

```zap
Result(T, E)
```

And propagation syntax:

```zap
pub fn load_config(path :: String) -> Result(Config, IOError) {
  contents = File.read(path)?
  parse_config(contents)?
}
```

### Why Explicit Results Over Exceptions

Rust demonstrates that explicit `Result` plus propagation keeps recoverable failure visible in APIs while remaining ergonomic. Exceptions are convenient, but they obscure control flow unless the language also has a strong checked-effects story.

For Zap, explicit results fit the current language better because Zap already emphasizes:

- pattern matching
- algebraic dispatch
- explicit types
- predictable control flow

### What To Do With Catch Basin

`~>` is interesting, but it should not become Zap's primary recoverable error story. It is better treated as a specialized pipeline recovery construct than as the main model for all failures.

In other words:

- `Result` handles ordinary fallible computation
- `panic` handles invariant violation
- `~>` remains a pipe-chain recovery feature, not the foundation of the language's error model

## 4. Complete Generics With Constraints

### Recommendation

Finish the user-facing generics story after protocols/traits exist.

Zap already has type parameters in the parser and AST. What is missing is a complete story users can rely on.

### The Goal

Users should be able to write:

```zap
pub fn identity(T)(value :: T) -> T {
  value
}

pub struct Box(T) {
  value :: T
}
```

And then constrain generic code with traits/protocols:

```zap
pub fn equals(T: Eq)(left :: T, right :: T) -> Bool {
  Eq.eq(left, right)
}
```

### Why This Comes After Traits/Protocols

Unconstrained generics are useful, but limited. Real languages become powerful when generics compose with capability constraints.

Without constraints, generic code quickly becomes either:

- too weak to express interesting algorithms
- or too dependent on compiler magic and ad hoc built-ins

### Design Questions

Zap should decide:

1. **Instantiation strategy**
   - monomorphization
   - dictionary passing
   - hybrid strategy

2. **Inference model**
   - explicit type args always available
   - inferred where unambiguous

3. **Generic functions and generic data types**
   - both should exist

4. **Associated types or not**
   - not required in v1 of the design

### Recommendation Details

Start small:

- first-order generic functions
- generic structs/unions/types
- trait-constrained type parameters
- no higher-kinded types
- no advanced associated-type machinery yet

That gives Zap most of the practical value without importing the hardest parts of modern type theory.

## 5. Exhaustiveness And Match Analysis

### Recommendation

Strengthen compile-time checking around pattern matching.

Zap should make `case` and multi-clause dispatch a flagship capability, not just a parsing feature.

### Must-Haves

- exhaustiveness checks for `case`
- exhaustiveness checks for unions/tagged unions
- unreachable clause detection
- redundant pattern detection
- guard-aware diagnostics where feasible

### Why This Matters

Rust's `match` is valuable not because pattern syntax exists, but because the compiler proves coverage. That transforms pattern matching from convenience into correctness machinery.

Zap already leans heavily on:

- multi-clause functions
- pattern-matching parameters
- `case`
- union-like constructs

Therefore, stronger analysis here is high leverage.

### Recommendation Details

For Zap, the first level should be:

- literal and union-variant coverage
- tuple/list/map structural coverage when finite and obvious
- a diagnostic when guards prevent a coverage proof

The language does not need to solve every theoretical pattern-analysis case immediately. It does need to be obviously strong on the common cases.

## 6. First-Class Ownership Semantics For User Code

### Recommendation

Decide whether ownership is:

- a user-visible language feature
- or an internal optimization and lowering concern

Current evidence suggests Zap wants it to be user-visible. If so, it must be made coherent.

### Why This Matters

Zap already exposes:

- `shared`
- `unique`
- `borrowed`

in syntax and type structures. That is a strong claim. Once users can write these annotations, the language owes them predictable semantics.

### Minimum Ownership Questions Zap Must Answer

1. When does a value move?
2. What exactly can be borrowed, and for how long?
3. Can closures capture unique or borrowed values?
4. What happens when pattern matching destructures owned values?
5. Are returns and fields ownership-qualified?
6. Are collections homogeneous in ownership or only in element type?

### Recommendation

Do not expand ownership syntax further until the model is stabilized.

The next step should be a clear semantic document and diagnostics policy around the existing model, especially for:

- parameter passing
- returns
- assignment
- pattern destructuring
- closure capture
- multi-clause dispatch

### Why This Is Not Higher Priority

Ownership is strategically important, but user-visible ownership without closures, protocols, and a stable error model will create more complexity than value. Zap should first establish its abstraction model, then tighten ownership around it.

## 7. Concurrency Or Effect Primitives

### Recommendation

Do not add both `async/await` and algebraic effects at the same time. Choose one direction.

### The Two Plausible Paths

#### Path A: Structured Concurrency

This would look more like Kotlin or Swift:

- `async`
- `await`
- task spawning
- cancellation
- structured lifetimes for child tasks

Benefits:

- familiar to users
- easier to explain
- enough for most practical concurrency use cases

Risks:

- can become bolted-on if it does not integrate with ownership and error propagation

#### Path B: Algebraic Effects And Handlers

This would look more like OCaml 5 or Koka:

- operations/effects declared in the language
- handlers define semantics
- concurrency, coroutines, generators, and inversion-of-control may all emerge from one mechanism

Benefits:

- very expressive
- could become Zap's most distinctive feature
- fits a macro-capable, direct-style language well

Risks:

- design complexity is much higher
- effect typing quickly becomes difficult
- implementation complexity is substantial

### Recommendation

Zap should not attempt full algebraic effects until the language already has:

- closures
- explicit recoverable errors
- stable ownership semantics
- generic constraints

Before that point, effects are likely to destabilize the language.

If Zap wants something practical sooner, choose **structured concurrency first**.

If Zap wants a long-term differentiator and is willing to absorb design risk, document an **effects roadmap** now but delay the implementation.

## 8. Secondary Refinements

These features are worth considering after the higher-priority items above.

### 8.1 Local Functions That Fully Work End-To-End

Nested named functions are a natural fit for Zap's style and should become reliable. They are less important than closures, but still valuable for readability and local recursion.

### 8.2 Partial Application

Once first-class functions exist, partial application may be worth adding:

```zap
add_one = add(1, _)
```

But this should come after a clear callable-function model exists.

### 8.3 Deriving

If Zap adds protocols/traits, it will eventually want language-level deriving for common capabilities:

- equality
- ordering
- display/inspect
- serialization hooks

This should be layered on top of protocols, not invented first.

### 8.4 Better Record Or Row Polymorphism

If maps and structs are central to Zap's style, row-polymorphic records may eventually become compelling. But this is advanced and should wait until the core generics and protocol story is settled.

## Features Zap Should Avoid For Now

These are not bad ideas. They are just too expensive or destabilizing too early.

### 1. Full Haskell-Style Typeclass Complexity

Avoid early support for:

- multi-parameter classes
- functional dependencies
- associated type families
- overlap rules

Zap should earn its way into that complexity only if real use cases demand it.

### 2. Full Algebraic Effect Typing Before Basic Language Maturity

Unhandled or loosely typed effects can make a language harder to reason about than exceptions. Effect systems are powerful, but the language must be ready for them.

### 3. Too Many Callable Kinds Up Front

Rust's `Fn`, `FnMut`, and `FnOnce` distinctions are elegant, but they are only worth exposing if Zap truly needs them for ownership correctness. Do not front-load that complexity into the first closure design.

### 4. Inheritance-Centric OO Features

Zap already has better foundations: pattern matching, modules, macros, and likely future protocols. It should not drift toward class hierarchies as a primary abstraction mechanism.

## Suggested Implementation Sequence

This sequence is intended to minimize design rework.

### Phase 1: Functional Completeness

1. Anonymous functions
2. Closure capture semantics
3. First-class function values
4. Reliable local functions

### Phase 2: Reusable Abstraction

1. Protocol or trait declarations
2. Implementation syntax
3. Generic constraints
4. Default methods
5. Coherence rules

### Phase 3: Reliable Failure Semantics

1. Canonical recoverable error type
2. Propagation operator
3. `panic` boundary clarified
4. interaction with pipes and `~>` clarified

### Phase 4: Type-System Strengthening

1. Generic data types and functions stabilized
2. Exhaustiveness and redundancy checking
3. ownership diagnostics improved

### Phase 5: Differentiation

1. concurrency model or effect model
2. deriving
3. partial application
4. advanced type features only if justified

## The Most Important Design Choice

If Zap only makes one big language decision in the near term, it should be this:

**Will Zap's abstraction model center on closures plus protocols/traits?**

If the answer is yes, most of the roadmap becomes clearer:

- closures enable higher-order APIs
- protocols/traits enable constrained generic code
- explicit results integrate with pattern matching
- ownership semantics become meaningful in closure capture and protocol-constrained APIs
- concurrency can later build on ordinary callable values

That combination gives Zap a strong and modern language center.

## Final Recommendation

Zap should prioritize the following four core language additions above all others:

1. **Anonymous functions and closures**
2. **Protocols or traits with coherence**
3. **A canonical recoverable error model with propagation syntax**
4. **Complete generics with constraints**

If Zap gets those four right, the language will gain:

- local and reusable abstraction
- scalable generic programming
- explicit and ergonomic failure handling
- a stable foundation for future ownership and concurrency work

Those features are the highest-leverage additions available to Zap from a language-design perspective.

Everything else should be sequenced around them.

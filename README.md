# Zap

A statically typed, functional programming language that compiles to native code through Zig.

Zap is a new language — not a dialect, not a transpiler shim. It has its own type system, its own dispatch model, and its own compiler pipeline. It lowers through Zig for native code generation.

## Features

- **Static typing with inference** — Types are declared at function boundaries and inferred within bodies. No separate spec or annotation layer.
- **Pattern matching** — First-class structural pattern matching in function heads, `case`, `with`, and assignments.
- **Function overloading** — Multiple clauses of the same name and arity form overload families, resolved by argument type and specificity.
- **Scope-prioritized dispatch** — Inner scopes get first right of refusal. If a local function family doesn't match, dispatch falls through to enclosing scopes, module scope, imports, and prelude — not shadowing, but fallback.
- **Refinement predicates** — Guard-like `if` clauses in function headers that participate in dispatch and clause selection.
- **Hygienic macros** — AST-to-AST transforms via `defmacro`, `quote`, and `unquote`. Macros expand before type checking.
- **Tagged unions** — Algebraic data types built on tagged tuples: `type Result(a, e) = {:ok, a} | {:error, e}`
- **Native compilation** — Compiles to Zig source, then to native machine code. No VM, no runtime interpreter.

## Quick Start

### Requirements

- [Zig](https://ziglang.org/download/) 0.15.2 or later

### Build

```sh
zig build
```

### Run

```sh
# Compile and summarize
zig build run -- examples/hello.zap

# Emit generated Zig source
zig build run -- --emit-zig examples/hello.zap
```

### Test

```sh
zig build test
```

## Language Overview

### Hello World

```
def main() do
  IO.puts("Hello, world!")
end
```

### Functions and Pattern Matching

```
def factorial(0 :: i64) :: i64 do
  1
end

def factorial(n :: i64) :: i64 do
  n * factorial(n - 1)
end
```

### Modules and Types

```
defmodule Geometry do
  type Shape = {:circle, f64} | {:rectangle, f64, f64}

  def area({:circle, radius} :: Shape) :: f64 do
    3.14159 * radius * radius
  end

  def area({:rectangle, w, h} :: Shape) :: f64 do
    w * h
  end
end
```

### Pipe Operator

```
def main() do
  5
  |> double()
  |> add_one()
end
```

### Refinement Predicates

```
def abs(x :: i64) :: i64 if x < 0 do
  -x
end

def abs(x :: i64) :: i64 do
  x
end
```

### Local Functions and Closures

```
def outer(x :: i64) :: String do
  def inner(s :: String) :: String do
    s <> "!"
  end

  inner("ok")
end
```

## Type System

Zap supports:

| Category | Types |
|----------|-------|
| Signed integers | `i8`, `i16`, `i32`, `i64` |
| Unsigned integers | `u8`, `u16`, `u32`, `u64` |
| Floats | `f16`, `f32`, `f64` |
| Platform-sized | `usize`, `isize` |
| Primitives | `Bool`, `String`, `Atom`, `Nil` |
| Bottom | `Never` |
| Compound | tuples, lists, maps, structs |
| Algebraic | tagged unions, opaque types |
| Higher-order | function types, parametric types |

No implicit numeric coercion — all conversions must be explicit.

Type aliases and opaque types:

```
type Result(a, e) = {:ok, a} | {:error, e}
type Pair(a, b) = {a, b}
opaque UserId = i64
```

## Compiler Pipeline

Zap compiles through a multi-phase pipeline:

1. **Lexing** — Tokenization with significant whitespace (`INDENT`/`DEDENT`/`NEWLINE`)
2. **Parsing** — Surface AST construction
3. **Declaration collection** — Module and function registration
4. **Macro expansion** — AST-to-AST transforms to fixed point
5. **Type checking** — Overload resolution, type inference, exhaustiveness checking
6. **HIR lowering** — High-level intermediate representation
7. **IR lowering** — Lower-level intermediate representation
8. **Code generation** — Emit Zig source code

The compiler is written entirely in Zig.

## Project Structure

```
src/
├── main.zig          # CLI entry point
├── root.zig          # Public module exports
├── lexer.zig         # Tokenizer
├── token.zig         # Token definitions
├── parser.zig        # Parser
├── ast.zig           # AST node types
├── scope.zig         # Scope management
├── collector.zig     # Declaration collection
├── macro.zig         # Macro expansion engine
├── desugar.zig       # Desugaring pass
├── resolver.zig      # Name resolution
├── types.zig         # Type system and checking
├── dispatch.zig      # Overload and fallback dispatch
├── hir.zig           # High-level IR
├── ir.zig            # Intermediate representation
├── codegen.zig       # Zig code generation
├── runtime.zig       # Runtime support
└── diagnostics.zig   # Error reporting
examples/             # Example .zap programs
```

## License

[MIT](LICENSE)

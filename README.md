# Zap

Zap is a statically typed, functional programming language that compiles to native code through Zig. It is its own language with its own type system, its own dispatch model, and its own compiler pipeline. Zig is the compilation target, not the identity.

If you've written Elixir you'll feel at home with the syntax. If you've written Zig you'll appreciate what comes out the other end. The goal is to take the developer experience that makes functional languages productive and remove the runtime overhead that typically comes along for the ride. No VM, no garbage collector, no interpreter. Your Zap code becomes Zig source, and Zig gives you a native binary.

The project is still early. Not everything works yet, and some of the features described below are partially implemented. But the core pipeline is real, the examples compile and run, and the foundation is solid enough to build on.

## Getting Started

You need [Zig](https://ziglang.org/download/) 0.15.2 or later.

```sh
# Build the compiler
zig build

# Compile a Zap program to a native binary
zig build run -- examples/hello.zap

# See the generated Zig source
zig build run -- --emit-zig examples/hello.zap

# Run the tests
zig build test
```

## What the Language Looks Like

The best way to understand Zap is to read some code.

### Hello World

```
defmodule Runner do
  def hello(word :: String) :: String do
    "Hello" <> " " <> word
  end
end

def main() :: String do
  Runner.hello("World!")
  |> IO.puts()
end
```

Functions declare their parameter types and return types at the boundary. The body is inferred. Modules group related functions. The pipe operator works like you'd expect.

### Pattern Matching and Dispatch

Multiple function clauses with the same name form an overload group. The compiler resolves which clause to call based on the argument values and types.

```
def factorial(0 :: i64) :: i64 do
  1
end

def factorial(n :: i64) :: i64 do
  n * factorial(n - 1)
end
```

This works with atoms, integers, tuples, and wildcards. You can pattern match on structure, not just values:

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

The tuple patterns destructure and bind in a single step. The tag atom (`:circle`, `:rectangle`) selects the clause, and the remaining elements bind to local variables inside the body.

### Refinement Predicates

Function clauses can carry guard conditions that participate in dispatch:

```
def classify(n :: i64) :: String if n > 0 do
  "positive"
end

def classify(n :: i64) :: String if n < 0 do
  "negative"
end

def classify(_ :: i64) :: String do
  "zero"
end
```

The `if` clause runs after the type check passes. If the predicate fails, dispatch continues to the next clause.

### Case Expressions

Pattern matching also works inside function bodies:

```
def check(result) :: String do
  case result do
    {:ok, v} ->
      v
    {:error, e} ->
      e
    _ ->
      "unknown"
  end
end
```

### If/Else

```
def abs(x :: i64) :: i64 do
  if x < 0 do
    -x
  else
    x
  end
end
```

If/else is an expression. It produces a value.

## Type System

Types are declared at function boundaries. The language does not do implicit numeric coercion, all conversions must be explicit.

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

Type aliases and opaque types let you give meaningful names to structures:

```
type Result(a, e) = {:ok, a} | {:error, e}
type Pair(a, b) = {a, b}
opaque UserId = i64
```

## How the Compiler Works

Zap compiles through several phases. The source text goes in, Zig source comes out, and then Zig takes it the rest of the way to a native binary.

1. **Lexing** with significant whitespace (indent/dedent tracking)
2. **Parsing** into a surface AST
3. **Declaration collection** to register modules and functions
4. **Macro expansion** (AST-to-AST transforms to fixed point)
5. **Type checking** with overload resolution and inference
6. **HIR lowering** into a typed intermediate representation
7. **IR lowering** into a lower-level representation closer to Zig's semantics
8. **Code generation** that emits Zig source

The entire compiler is written in Zig.

## Project Layout

```
src/
  main.zig           # CLI entry point
  lexer.zig          # Tokenizer
  token.zig          # Token definitions
  parser.zig         # Parser
  ast.zig            # AST node types
  scope.zig          # Scope management
  collector.zig      # Declaration collection
  macro.zig          # Macro expansion
  desugar.zig        # Desugaring pass
  resolver.zig       # Name resolution
  types.zig          # Type system
  dispatch.zig       # Overload dispatch
  hir.zig            # High-level IR
  ir.zig             # Intermediate representation
  codegen.zig        # Zig code generation
  runtime.zig        # Runtime support
  diagnostics.zig    # Error reporting
examples/            # Example .zap programs
```

## License

[MIT](LICENSE)

<p align="center">
  <br>
  <br>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/trycog/zap/main/.github/zap-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/trycog/zap/main/.github/zap-light.svg">
    <img alt="Zap" width="140">
  </picture>
  <br>
  <br>
</p>

<h3 align="center">A functional language that compiles to native code through Zig.</h3>

<p align="center">
  Pattern matching &nbsp;·&nbsp; Type safety &nbsp;·&nbsp; No runtime &nbsp;·&nbsp; Native binaries
</p>

---

Zap takes the developer experience of functional programming — pattern matching, pipe operators, algebraic types — and strips away the overhead. No VM, no garbage collector, no interpreter. Your code compiles to Zig, and Zig compiles to a native binary.

> **Early stage.** The core pipeline works and examples compile and run, but not everything described here is fully implemented yet.

---

## Quick Start

### Prerequisites

Install [Zig](https://ziglang.org/download/) **0.15.2** or later.

Verify your installation:

```sh
zig version
```

### Step 1 — Build the Zap compiler

Clone the repository and build:

```sh
git clone https://github.com/trycog/zap.git
cd zap
zig build
```

This produces the compiler binary at `zig-out/bin/zap`.

### Step 2 — Write a Zap program

Create a file called `hello.zap`:

```elixir
defmodule Greeter do
  def hello(name :: String) :: String do
    "Hello, " <> name <> "!"
  end
end

def main() :: String do
  Greeter.hello("World")
  |> IO.puts()
end
```

Every Zap program needs a `main` function — that's your entry point. Functions declare their parameter types and return types at the boundary. The body is type-inferred.

### Step 3 — Compile and run

```sh
./zig-out/bin/zap hello.zap
```

Zap compiles your code to Zig, then invokes the Zig compiler to produce a native binary. The output lands in `zap-out/bin/`:

```sh
./zap-out/bin/hello
# => Hello, World!
```

That's it. Source code in, native binary out.

### See the generated Zig

If you're curious what Zap produces under the hood:

```sh
./zig-out/bin/zap --emit-zig hello.zap
```

This prints the generated Zig source to stdout instead of compiling it.

---

## The Language

### Modules and Functions

Modules group related functions. Functions declare types at the boundary and infer everything inside.

```elixir
defmodule Math do
  def square(x :: i64) :: i64 do
    x * x
  end

  def double(x :: i64) :: i64 do
    x * 2
  end
end
```

### Pipe Operator

Chain function calls, passing the result of each step as the first argument to the next:

```elixir
def double(x :: i64) :: i64 do
  x * 2
end

def add_one(x :: i64) :: i64 do
  x + 1
end

def main() do
  5
  |> double()
  |> add_one()
end
```

### Pattern Matching

Multiple function clauses with the same name form an overload group. The compiler resolves which clause to call based on argument values and types.

```elixir
def factorial(0 :: i64) :: i64 do
  1
end

def factorial(n :: i64) :: i64 do
  n * factorial(n - 1)
end
```

This works with atoms, integers, tuples, and wildcards:

```elixir
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

Tuple patterns destructure and bind in a single step. The tag atom selects the clause, the remaining elements bind to local variables.

### Guards

Function clauses can carry guard conditions that participate in dispatch:

```elixir
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

Pattern matching inside function bodies:

```elixir
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

### If / Else

If/else is an expression — it produces a value:

```elixir
def abs(x :: i64) :: i64 do
  if x < 0 do
    -x
  else
    x
  end
end
```

---

## Type System

Types are declared at function boundaries. No implicit numeric coercion — all conversions are explicit.

| Category | Types |
|---|---|
| Signed integers | `i8` `i16` `i32` `i64` |
| Unsigned integers | `u8` `u16` `u32` `u64` |
| Floats | `f16` `f32` `f64` |
| Platform-sized | `usize` `isize` |
| Primitives | `Bool` `String` `Atom` `Nil` |
| Bottom | `Never` |
| Compound | tuples, lists, maps, structs |
| Algebraic | tagged unions, opaque types |
| Higher-order | function types, parametric types |

Type aliases and opaque types:

```elixir
type Result(a, e) = {:ok, a} | {:error, e}
type Pair(a, b) = {a, b}
opaque UserId = i64
```

---

## Compiler Pipeline

Source text goes in, Zig source comes out, Zig takes it the rest of the way to a native binary.

```
  .zap source
      │
      ▼
   Lexer ─────────── tokenize with indent/dedent tracking
      │
      ▼
   Parser ────────── surface AST
      │
      ▼
   Collector ─────── register modules and functions
      │
      ▼
   Macro Expansion ─ AST→AST transforms to fixed point
      │
      ▼
   Type Checker ──── overload resolution + inference
      │
      ▼
   HIR Lowering ──── typed intermediate representation
      │
      ▼
   IR Lowering ───── lower-level IR closer to Zig semantics
      │
      ▼
   Code Gen ──────── emit Zig source
      │
      ▼
   Zig Compiler ──── native binary
```

The entire compiler is written in Zig.

---

## CLI Reference

```
zap [flags] <file.zap> [zig-flags...]
```

| Flag | Description |
|---|---|
| `--emit-zig` | Print generated Zig source to stdout instead of compiling |
| `--lib` | Compile as a library instead of an executable |

Any additional flags after the `.zap` file are forwarded to the Zig build system.

---

## Development

```sh
# Run the full test suite
zig build test

# Compile and run an example
zig build run -- examples/factorial.zap

# See generated Zig for an example
zig build run -- --emit-zig examples/hello.zap
```

---

## License

[MIT](LICENSE)

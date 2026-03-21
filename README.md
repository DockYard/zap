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

<h3 align="center">A functional language that compiles to native code.</h3>

<p align="center">
  Pattern matching &nbsp;·&nbsp; Type safety &nbsp;·&nbsp; Native binaries
</p>

---

Zap takes the developer experience of functional programming — pattern matching, pipe operators, algebraic types — and strips away the overhead. No VM, no garbage collector, no interpreter. Your code compiles directly to a native binary.

> **Early stage.** The core pipeline works and examples compile and run, but not everything described here is fully implemented yet.

---

## Quick Start

### Install from release

Download the latest release tarball for your platform. Extract it — the archive contains `bin/zap` and `lib/zig/` (the Zig standard library). Add `bin/` to your PATH. No separate Zig installation is required.

### Build from source

Building from source requires Zig 0.15.2, LLVM 20, and the Zap Zig compiler fork.

```sh
# 1. Build the Zig compiler library
cd ~/projects/zig
zig build lib -Denable-llvm -Dconfig_h=build/config.h

# 2. Clone and build Zap
git clone https://github.com/trycog/zap.git
cd zap
zig build -Dllvm-lib-path=$HOME/llvm-20-native/lib
```

This produces the compiler binary at `zig-out/bin/zap`.

### Write a Zap program

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

### Compile and run

```sh
# Compile a Zap program
zap hello.zap
# Binary produced at zap-out/bin/hello

# Compile and run in one step
zap run hello.zap
```

```sh
./zap-out/bin/hello
# => Hello, World!
```

That's it. Source code in, native binary out.

### Debug: emit generated Zig

If you're curious what Zap produces under the hood:

```sh
zap --emit-zig hello.zap
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
| Compound | tuples, structs, enums |

### Structs

Structs are top-level data definitions with named, typed fields:

```elixir
defstruct User do
  name :: String
  email :: String
  age :: i64
end

user = %{name: "Alice", email: "alice@example.com", age: 30} :: User
```

Structs support inheritance via `extends`, which copies fields from a parent:

```elixir
defstruct Shape do
  color :: String = "black"
end

defstruct Circle extends Shape do
  radius :: f64
end

# Circle has: color, radius
```

### Enums

Closed sets of named tags:

```elixir
defenum Direction do
  North
  South
  East
  West
end
```

### Lists

Lists are homogeneous — all elements must be the same type:

```elixir
numbers = [1, 2, 3]         # valid: [i64]
names = ["alice", "bob"]     # valid: [String]
```

Mixed-type collections use tuples instead:

```elixir
mixed = {1, "two", :three}  # valid: {i64, String, Atom}
```

---

## Architecture

Zap includes a fork of the Zig compiler as a static library. The compiler lowers Zap IR to ZIR (Zig Intermediate Representation), then Zig's semantic analysis, code generation, and linker produce native binaries. No intermediate Zig source code is generated during normal compilation.

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
   Desugar ────────── simplify syntax before type checking
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
   ZIR Emit ──────── emit Zig Intermediate Representation
      │
      ▼
   Sema ──────────── Zig semantic analysis
      │
      ▼
   Codegen ────────── native binary
```

The entire compiler is written in Zig. The binary includes the full Zig compiler toolchain — no separate Zig installation is needed at runtime.

---

## CLI Reference

```
zap [run] [flags] <file.zap>
```

| Command / Flag | Description |
|---|---|
| `run` | Compile and execute the program in one step |
| `--emit-zig` | Print generated Zig source to stdout instead of compiling |
| `--lib` | Compile as a library instead of an executable |
| `--strict-types` | Treat type warnings as errors |

---

## Development

```sh
# Run the full test suite
zig build test

# Compile and run an example
zap run examples/factorial.zap

# See generated Zig for an example
zap --emit-zig examples/hello.zap
```

---

## License

[MIT](LICENSE)

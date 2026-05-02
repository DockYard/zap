# Zap

Zap is an early-stage functional programming language that compiles to native
code through Zig's ZIR pipeline. It is built around structs, pattern matching,
macros written in Zap, protocols, algebraic data, and a small standard library.

The compiler is still moving quickly. The codebase is usable for examples,
stdlib development, documentation generation, and the current test suite, but
the language is not stable yet.

## Highlights

- Native binaries with no VM and no interpreter.
- Struct-centered code organization with no separate namespace construct.
- Pattern-matched multi-clause functions with typed overload resolution.
- Protocols and impls for extensible dispatch.
- First-class functions and capturing anonymous functions.
- Compile-time macros written in Zap.
- Build manifests written in Zap and evaluated at compile time.
- Zest test framework with compile-time test discovery.
- Documentation generation from `@doc` attributes.
- Direct ZIR emission through the Zap Zig fork.

## Quick Start

### Build From Source

Zap links against `libzap_compiler.a` from the Zap Zig fork. For the normal
source build, first download the prebuilt dependency bundle for your platform:

```sh
git clone git@github.com:DockYard/zap.git
cd zap
zig build setup
zig build
```

This builds the compiler at:

```sh
zig-out/bin/zap
```

If you already have a local build of the Zig fork, pass the dependency paths
explicitly:

```sh
zig build \
  -Dzap-compiler-lib=/path/to/libzap_compiler.a \
  -Dllvm-lib-path=/path/to/llvm-libs
```

### Create a Project

```sh
mkdir my_app
cd my_app
zap init
```

`zap init` creates a minimal project:

```text
my_app/
  README.md
  build.zap
  lib/my_app.zap
  test/my_app_test.zap
```

### Build, Run, Test, Document

```sh
zap build
zap run
zap test
zap doc
```

Targets default to `:default` for `build` and `run`, and to `:test` for
`test`. You can name a target explicitly:

```sh
zap build my_app
zap run my_app -- arg1 arg2
zap test --seed 12345
zap doc --no-deps
```

## CLI Reference

```text
zap init                       Scaffold a new project in the current directory
zap build [target]             Build a target from build.zap
zap run [target] [-- args]     Build and run a bin target
zap test [options]             Build and run the :test target
zap doc [target] [options]     Generate documentation from a doc target
zap deps update                Re-resolve all dependencies
zap deps update <name>         Re-resolve one dependency
```

Common options:

```text
-Dkey=value                    Pass a build option to build.zap
--build-file <path>            Use a build file other than build.zap
--watch, -w                    Rebuild on changes
--target <triple>              Cross-compile for a Zig target triple
--seed <integer>               Use deterministic test ordering
-- <args...>                   Pass runtime args to zap run
```

## Build Manifest

Every project is driven by `build.zap`. The manifest is ordinary Zap code:

```zap
pub struct MyApp.Builder {
  pub fn manifest(env :: Zap.Env) -> Zap.Manifest {
    case env.target {
      :my_app -> my_app(env)
      :test -> test(env)
      :doc -> docs(env)
      _default -> my_app(env)
    }
  }

  fn my_app(_env :: Zap.Env) -> Zap.Manifest {
    %Zap.Manifest{
      name: "my_app",
      version: "0.1.0",
      kind: :bin,
      root: "MyApp.main/1",
      paths: ["lib/**/*.zap"],
      optimize: :release_safe
    }
  }

  fn test(_env :: Zap.Env) -> Zap.Manifest {
    %Zap.Manifest{
      name: "my_app_test",
      version: "0.1.0",
      kind: :bin,
      root: "TestRunner.main/1",
      paths: ["lib/**/*.zap", "test/**/*.zap"],
      optimize: :debug
    }
  }

  fn docs(_env :: Zap.Env) -> Zap.Manifest {
    %Zap.Manifest{
      name: "my_app",
      version: "0.1.0",
      kind: :doc,
      paths: ["lib/**/*.zap"],
      source_url: "https://github.com/example/my_app",
      landing_page: "README.md"
    }
  }
}
```

Manifest fields:

| Field | Description |
|---|---|
| `name` | Output artifact name |
| `version` | Project version string |
| `kind` | `:bin`, `:lib`, `:obj`, or `:doc` |
| `root` | Entry point, formatted as `"Struct.function/arity"` |
| `paths` | Source glob patterns, relative to the project root |
| `deps` | Dependency declarations |
| `optimize` | `:debug`, `:release_safe`, `:release_fast`, or `:release_small` |
| `test_timeout` | Test timeout in milliseconds |
| `source_url` | Base source URL for generated documentation |
| `landing_page` | Markdown landing page for generated documentation |
| `doc_groups` | Extra documentation page groups |

If `paths` is present, those globs define the source graph input. If `paths` is
omitted for a binary target, Zap can discover sources from the `root` entry
point and struct references.

### Dependencies

Dependencies can point at local paths or Git repositories:

```zap
%Zap.Manifest{
  name: "my_app",
  version: "0.1.0",
  kind: :bin,
  root: "MyApp.main/1",
  deps: [
    {:shared_utils, {:path, "../shared_utils"}},
    {:parser, {:git, "https://github.com/example/parser.git", tag: "v1.0.0"}}
  ]
}
```

Zap writes `zap.lock` to record resolved dependency state. Use:

```sh
zap deps update
zap deps update parser
```

## Language

### Structs, Protocols, Unions, and Files

Zap code is organized around top-level declarations:

```zap
@doc = "A two-dimensional point."
pub struct Point {
  x :: i64
  y :: i64
}

@doc = "Possible directions."
pub union Direction {
  North,
  South,
  East,
  West
}

@doc = "Values that can be converted to a string."
pub protocol Stringable {
  fn to_string(value) -> String
}
```

A file may contain more than one top-level declaration. Public declarations are
visible outside their dependency; private declarations are local to the
dependency.

Use `@doc` immediately before the declaration it documents. Documentation is
generated from those attributes for structs, protocols, unions, impls,
functions, and macros.

### Entry Points

Binary targets name a root function in the manifest:

```zap
pub struct MyApp {
  pub fn main(_args :: [String]) {
    IO.puts("Hello from Zap")
  }
}
```

### Functions and Pattern Matching

Functions can have multiple clauses. Dispatch prefers exact typed matches
before considering numeric widening:

```zap
pub struct Factorial {
  pub fn factorial(0 :: i64) -> i64 {
    1
  }

  pub fn factorial(n :: i64) -> i64 {
    n * factorial(n - 1)
  }
}
```

Guards participate in clause dispatch:

```zap
pub fn classify(n :: i64) -> String if n > 0 {
  "positive"
}

pub fn classify(n :: i64) -> String if n < 0 {
  "negative"
}

pub fn classify(_ :: i64) -> String {
  "zero"
}
```

Case expressions match inside function bodies:

```zap
pub fn unwrap(result :: {Atom, String}) -> String {
  case result {
    {:ok, value} -> value
    {:error, reason} -> reason
  }
}
```

### Types

Zap supports typed function parameters, typed locals, and typed patterns.

| Category | Types |
|---|---|
| Signed integers | `i8` `i16` `i32` `i64` `i128` |
| Unsigned integers | `u8` `u16` `u32` `u64` `u128` |
| Floats | `f16` `f32` `f64` `f80` `f128` |
| Platform-sized integers | `usize` `isize` |
| Primitives | `Bool` `String` `Atom` `Nil` |
| Bottom | `Never` |
| Compound | tuples, lists, maps, ranges, structs, unions |

Integer literals default to `i64`. Float literals default to `f64`.

Numeric overload resolution is exact-first. If no exact clause exists, Zap may
widen within the same numeric family:

```text
i8 -> i16 -> i32 -> i64 -> i128
u8 -> u16 -> u32 -> u64 -> u128
f16 -> f32 -> f64 -> f80 -> f128
```

Signed integers do not implicitly widen to unsigned integers. Unsigned integers
do not implicitly widen to signed integers. Integer-to-float conversion is not
implicit.

### Collections

Lists:

```zap
pub fn sum([] :: [i64]) -> i64 {
  0
}

pub fn sum([head | tail] :: [i64]) -> i64 {
  head + sum(tail)
}
```

Maps:

```zap
user = %{name: "Alice", age: 30}
updated = %{user | name: "Bob"}
```

Ranges:

```zap
1..10
1..10:2
10..1
```

Ranges are direction-aware. `10..1` iterates downward.

Keyword lists are syntax for lists of atom-keyed tuples:

```zap
opts = [name: "Brian", age: 42]
# equivalent to: [{:name, "Brian"}, {:age, 42}]
```

### Protocols

Protocols provide compile-time dispatch across different data types:

```zap
pub protocol Enumerable(element) {
  fn next(state) -> {Atom, element, any}
}

pub impl Enumerable(i64) for Range {
  pub fn next(range :: Range) -> {Atom, i64, Range} {
    :zig.Range.next(range)
  }
}
```

Protocol names are matched exactly as declared. `Enumerable` and `enumerable`
are different names; using the wrong casing is a compile error.

The standard library uses protocols for `Enumerable`, `Stringable`,
`Arithmetic`, `Comparator`, `Concatenable`, `Membership`, and `Updatable`.

### Functions as Values

Named functions and anonymous functions can be passed as values. Anonymous
functions may capture local variables:

```zap
multiplier = 3
Enum.map([1, 2, 3], fn(value :: i64) -> i64 {
  value * multiplier
})
```

Function type annotations use arrow syntax:

```zap
callback :: (i64 -> i64)
reducer :: (i64, i64 -> i64)
```

### Pipes and Catch Basin

The pipe operator passes the left side as the first argument to the next call:

```zap
5
|> Integer.to_string()
|> String.reverse()
```

The catch basin operator handles unmatched pipe values and skips the remaining
pipe steps:

```zap
input
|> parse_number()
|> format_number()
~> {
  _ -> "unrecognized"
}
```

### For Comprehensions

For comprehensions work with values that implement `Enumerable`:

```zap
doubled = for value <- [1, 2, 3] {
  value * 2
}

evens = for value <- 1..10, Integer.remainder(value, 2) == 0 {
  value
}
```

### Binary Pattern Matching

Binary patterns match and extract bytes and strings:

```zap
fn after_get(data :: String) -> String {
  case data {
    <<"GET "::String, path::String>> -> path
    _ -> ""
  }
}
```

### Macros

Macros are Zap code. They return quoted Zap AST:

```zap
pub struct Unless {
  pub macro unless(condition :: Expr, body :: Expr) -> Expr {
    quote {
      if not unquote(condition) {
        unquote(body)
      }
    }
  }
}
```

`use Struct` imports a struct and calls `Struct.__using__/1` indirectly when it
exists:

```zap
pub struct Greeter {
  pub macro __using__(_opts :: Expr) -> Expr {
    quote {
      pub fn hello() -> String {
        "Hello from Greeter"
      }
    }
  }
}

pub struct MyApp {
  use Greeter
}
```

Macros can call Zap functions that have already been compiled for compile-time
execution. This is how library features such as `Zest.Runner` use
`Path.glob/1`, `SourceGraph.structs/1`, and reflection helpers without compiler
special-casing standard-library struct names.

## Testing With Zest

Use `Zest.Case` for the test DSL and assertions:

```zap
pub struct MathTest {
  use Zest.Case

  describe("addition") {
    test("adds two integers") {
      assert(1 + 1 == 2)
    }

    test("rejects false conditions") {
      reject(1 + 1 == 3)
    }
  }
}
```

Use `Zest.Runner` to generate a `main/1` test entry point at compile time:

```zap
pub struct TestRunner {
  use Zest.Runner, pattern: "test/**/*_test.zap"
}
```

`pattern` and `patterns` are project-root-relative glob patterns. The runner
discovers matching source files, finds structs with `run/0`, invokes them, and
prints the final summary. If no pattern is given, the default is
`test/**/*_test.zap`.

Run tests with:

```sh
zap test
zap test --seed 12345
zap test -- --timeout 5000
```

## Documentation

Documentation comes from `@doc` attributes placed immediately before the thing
being documented:

```zap
@doc = "Functions for working with points."
pub struct Point {
  @doc = "Builds a point from x and y coordinates."
  pub fn new(x :: i64, y :: i64) -> Point {
    %Point{x: x, y: y}
  }
}
```

Generate documentation with:

```sh
zap doc
zap doc --no-deps
```

Documentation targets use `kind: :doc` in `build.zap`. Generated output is
written to `docs/`.

## Standard Library

The standard library lives in `lib/`. Important public structs and protocols:

| Declaration | Purpose |
|---|---|
| `Kernel` | Core macros and operators |
| `Integer` | Integer conversion, arithmetic helpers, bit operations |
| `Float` | Float conversion and numeric helpers |
| `Math` | Numeric math functions for integer and float widths |
| `Bool`, `Atom`, `String` | Primitive helpers |
| `List`, `Map`, `Range` | Collection types and helpers |
| `Enum` | Higher-order operations over `Enumerable` values |
| `Path`, `File`, `System`, `IO` | Filesystem, process, and I/O helpers |
| `Struct`, `SourceGraph` | Compile-time reflection helpers |
| `Zest`, `Zest.Case`, `Zest.Runner` | Test framework |
| `Enumerable`, `Stringable`, `Arithmetic` | Core protocols |

`Enum` works through the `Enumerable` protocol, so functions such as
`Enum.map/2`, `Enum.reduce/3`, `Enum.filter/2`, `Enum.take/2`, and
`Enum.empty?/1` work for lists, maps, ranges, strings, and user-defined
enumerables.

## Native Runtime Bindings

Zap standard-library code can call primitive Zig runtime functions through
`:zig.Struct.function(...)`:

```zap
pub struct IO {
  pub fn puts(message :: String) -> String {
    :zig.IO.println(message)
    message
  }
}
```

These bindings are declared in Zap source files. The compiler should remain a
general-purpose language compiler; standard-library behavior belongs in Zap
unless it is a true parser, type-system, ZIR, or runtime primitive.

## Architecture

Zap lowers to ZIR. The active backend is the ZIR builder path, not legacy Zig
source text generation.

Compilation pipeline:

1. Parse source files.
2. Collect declarations into the source graph and scope graph.
3. Stage and expand macros.
4. Desugar high-level syntax.
5. Type check and resolve overloads, protocols, and generics.
6. Lower to HIR.
7. Monomorphize generic functions.
8. Lower to IR.
9. Run analysis passes such as escape analysis, lambda-set analysis, and
   Perceus reuse analysis.
10. Emit per-struct ZIR through the Zig fork C ABI.
11. Let Zig and LLVM produce the final native artifact.

Each Zap struct emits as a Zig ZIR struct. Cross-struct calls are emitted as
imports between those structs. Direct `:zig.*` calls target the embedded Zap
runtime.

## Development

Common development commands:

```sh
zig build setup
zig build
zig build test
./zig-out/bin/zap test
./zig-out/bin/zap test --seed 123
./zig-out/bin/zap doc --no-deps
```

When changing the Zig fork, rebuild `libzap_compiler.a` and point Zap at it:

```sh
cd ~/projects/zig
/path/to/zig build lib \
  --search-prefix /path/to/zig-bootstrap/out/aarch64-macos-none-baseline \
  -Dstatic-llvm \
  -Doptimize=ReleaseSafe \
  -Dtarget=aarch64-macos-none \
  -Dcpu=baseline \
  -Dversion-string=0.16.0

cd ~/projects/zap
zig build \
  -Dzap-compiler-lib=$HOME/projects/zig/zig-out/lib/libzap_compiler.a \
  -Dllvm-lib-path=/path/to/zig-bootstrap/out/aarch64-macos-none-baseline/lib
```

The exact target triple and bootstrap path depend on your platform.

## License

[MIT](LICENSE)

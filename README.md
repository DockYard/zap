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
  Pattern matching &nbsp;&middot;&nbsp; Type safety &nbsp;&middot;&nbsp; Native binaries
</p>

---

Zap takes the developer experience of functional programming — pattern matching, pipe operators, algebraic types — and strips away the overhead. No VM, no garbage collector, no interpreter. Your code compiles directly to a native binary.

> **Early stage.** The core pipeline works and examples compile and run, but not everything described here is fully implemented yet.

---

## Quick Start

### Install from release

Download the latest release tarball for your platform. Extract it — the archive contains `bin/zap` and `lib/zig/` (the Zig standard library). Add `bin/` to your PATH. No separate Zig installation is required.

### Build from source

Zap links against a fork of the Zig compiler (`libzap_compiler.a`) with LLVM enabled. Building from source requires:

- **Zig 0.16.0** (install via [asdf](https://asdf-vm.com/), [zigup](https://github.com/marler8/zigup), or [ziglang.org](https://ziglang.org/download/))

```sh
git clone https://github.com/DockYard/zap.git
cd zap
zig build setup    # Downloads pre-built deps for your platform
zig build          # Builds the zap binary
```

This produces the compiler binary at `zig-out/bin/zap`.

`zig build setup` automatically downloads the correct `zap-deps` tarball for your platform (macOS Apple Silicon, Linux arm64, or Linux x86_64) from the [Zig fork releases](https://github.com/DockYard/zig/releases/tag/v0.16.0-zap.1). You can also pass custom paths if you have your own build of the Zig fork:

```sh
zig build \
  -Dzap-compiler-lib=path/to/libzap_compiler.a \
  -Dllvm-lib-path=path/to/llvm-libs
```

To build `libzap_compiler.a` and the LLVM libraries yourself from scratch, see [Building the Zig Fork](#building-the-zig-fork) below.

### Create a project

```sh
mkdir my_app && cd my_app
zap init
```

This creates:

```
my_app/
  build.zap       # Build manifest
  lib/my_app.zap  # Main source file
  test/my_app_test.zap
```

### Build and run

```sh
zap build           # Compile (uses default target)
zap run             # Compile and run
zap run test        # Compile and run test target
```

You can also specify a target explicitly: `zap build my_app`. The binary is output to `zap-out/bin/my_app`.

---

## The Language

### Modules and Files

Every `.zap` file contains exactly one module. The module name maps to the file path:

| Module name | File path |
|---|---|
| `App` | `lib/app.zap` |
| `Config.Parser` | `lib/config/parser.zap` |
| `JsonParser` | `lib/json_parser.zap` |

The compiler enforces this — a mismatch is a compile error. The compiler discovers files by following module references from the entry point. No glob patterns or file manifests needed.

```zap
# lib/math.zap
pub module Math {
  pub fn square(x :: i64) -> i64 {
    x * x
  }

  pub fn double(x :: i64) -> i64 {
    x * 2
  }
}
```

### Visibility

- `pub fn` / `pub macro` — public function/macro
- `fn` / `macro` — private to the module (file)
- `pub module` — public module
- `module` — private module (visible within the dep, invisible outside)

### Entry Point

Every program needs a `main` function inside a module. The `build.zap` manifest specifies the entry point:

```zap
pub module MyApp {
  pub fn main(_args :: [String]) {
    IO.puts("Hello!")
  }
}
```

### Pipe Operator

Chain function calls, passing the result of each step as the first argument to the next:

```zap
pub module Pipes {
  pub fn double(x :: i64) -> i64 {
    x * 2
  }

  pub fn add_one(x :: i64) -> i64 {
    x + 1
  }

  pub fn main() {
    5
    |> Pipes.double()
    |> Pipes.add_one()
  }
}
```

### Pattern Matching

Multiple function clauses with the same name form an overload group. The compiler resolves which clause to call based on argument values and types.

```zap
pub module Factorial {
  pub fn factorial(0 :: i64) -> i64 {
    1
  }

  pub fn factorial(n :: i64) -> i64 {
    n * factorial(n - 1)
  }
}
```

### Guards

Function clauses can carry guard conditions that participate in dispatch:

```zap
pub module Guards {
  pub fn classify(n :: i64) -> String if n > 0 {
    "positive"
  }

  pub fn classify(n :: i64) -> String if n < 0 {
    "negative"
  }

  pub fn classify(_ :: i64) -> String {
    "zero"
  }
}
```

### Case Expressions

Pattern matching inside function bodies:

```zap
pub module CaseExpr {
  pub fn check(result) -> String {
    case result {
      {:ok, v} ->
        v
      {:error, e} ->
        e
      _ ->
        "unknown"
    }
  }
}
```

### If / Else

If/else is an expression — it produces a value:

```zap
pub module Math {
  pub fn abs(x :: i64) -> i64 {
    if x < 0 {
      -x
    } else {
      x
    }
  }
}
```

### Strings

String interpolation with `#{}`, escape sequences, and concatenation with `<>`:

```zap
name = "World"
IO.puts("Hello, #{name}!")           # Hello, World!
IO.puts("count: #{42}")              # count: 42 (auto to_string)
IO.puts("line1\nline2")              # escape sequences: \n \t \\ \"
IO.puts("hello" <> " " <> "world")  # concatenation
```

### Maps

Create maps with `%{}` and update with `%{map | key: value}`:

```zap
m = %{name: "Alice", age: 30}
m2 = %{m | name: "Bob"}        # update — creates modified copy
```

Map pattern matching in functions:

```zap
pub fn greet(%{name: n, greeting: g} :: %{Atom -> String}) -> String {
  g <> ", " <> n <> "!"
}
```

### Keyword Lists

Shorthand for lists of `{atom, value}` tuples:

```zap
opts = [name: "Brian", age: 42]
# equivalent to: [{:name, "Brian"}, {:age, 42}]

case opts {
  [name: n, age: a] -> IO.puts("#{n} is #{a}")
}
```

### Lists

Lists support pattern matching with cons (`[h | t]`), recursive processing, and for comprehensions:

```zap
pub fn sum([] :: [i64]) -> i64 { 0 }
pub fn sum([h | t] :: [i64]) -> i64 { h + sum(t) }

sum([1, 2, 3])  # 6
```

### Binary Pattern Matching

Match and extract data from binary/string data using `<<>>` patterns:

```zap
fn first_byte(data :: String) -> i64 {
  case data {
    <<a, _>> -> a
    _ -> 0
  }
}

fn after_prefix(data :: String) -> String {
  case data {
    <<"GET "::String, path::String>> -> path
    _ -> "no match"
  }
}
```

### For Comprehensions

Transform and filter lists:

```zap
doubled = for x <- [1, 2, 3] {
  x * 2
}
# [2, 4, 6]

evens = for x <- [1, 2, 3, 4, 5, 6], x rem 2 == 0 {
  x
}
# [2, 4, 6]
```

### Catch Basin (`~>`)

Catch unmatched values in pipe chains. When a multi-clause function doesn't match, the handler runs and remaining pipe steps are skipped:

```zap
pub fn process(input :: String) -> String {
  input
  |> parse_number()
  |> format_result()
  ~> {
    _ -> "Error: unrecognized"
  }
}
```

### Use

`use Module` imports a module and calls its `__using__/1` callback if defined. This enables library DSLs:

```zap
pub module Greeter {
  pub macro __using__(_opts :: Expr) -> Expr {
    quote {
      pub fn hello() -> String {
        "Hello from Greeter!"
      }
    }
  }
}

pub module MyApp {
  use Greeter     # imports + injects hello/0 via __using__

  pub fn main() {
    IO.puts(hello())
  }
}
```

### Testing with Zest

Zest is Zap's built-in test framework. Use `Zest.Case` for assertions and describe/test DSL:

```zap
pub module Test.MathTest {
  use Zest.Case

  describe("math") {
    test("addition") {
      assert(1 + 1 == 2)
    }

    test("negative check") {
      reject(5 < 0)
    }
  }
}
```

Test output shows green dots for passing tests and red F for failures, with a summary:

```
.....................................

37 tests, 0 failures
43 assertions, 0 failures
```

Failed assertions don't kill the process — the test records the failure and continues to the next test.

### Tail Call Optimization

Recursive functions in tail position are guaranteed to use constant stack space via LLVM's `musttail`:

```zap
pub fn countdown(0 :: i64) -> i64 { 0 }
pub fn countdown(n :: i64) -> i64 { countdown(n - 1) }

countdown(100_000_000)  # runs in constant stack space
```

---

## Build Manifest

Every Zap project has a `build.zap` that defines build targets:

```zap
pub module MyApp.Builder {
  pub fn manifest(env :: Zap.Env) -> Zap.Manifest {
    case env.target {
      :my_app ->
        %Zap.Manifest{
          name: "my_app",
          version: "0.1.0",
          kind: :bin,
          root: "MyApp.main/0"
        }
      _ ->
        panic("Unknown target")
    }
  }
}
```

When `root` is specified and `paths` is omitted, the compiler uses import-driven discovery — it starts from the entry module and follows module references to find all source files automatically.

| Field | Description |
|---|---|
| `name` | Output binary name |
| `version` | Project version |
| `kind` | `:bin`, `:lib`, or `:obj` |
| `root` | Entry point as `"Module.function/arity"` |
| `deps` | List of dependency tuples |
| `optimize` | `:debug`, `:release_safe`, `:release_fast`, or `:release_small` |

### Dependencies

Dependencies are declared in the manifest as tuples:

```zap
%Zap.Manifest{
  name: "my_app",
  version: "0.1.0",
  kind: :bin,
  root: "App.main/0",
  deps: [
    {:shared_utils, {:path, "../shared_utils"}},
    {:json_parser, {:git, "https://github.com/someone/json_parser.zap", "v1.0.0"}}
  ]
}
```

| Source type | Format | Description |
|---|---|---|
| Path | `{:name, {:path, "dir"}}` | Local Zap library |
| Git | `{:name, {:git, "url", "ref"}}` | Remote Zap library |

Zap dependencies are first-class — their modules are available directly (`JsonParser.parse(data)`). The compiler discovers dep modules the same way it discovers project modules.

A `zap.lock` lockfile is generated automatically on first build and records resolved versions for reproducible builds.

```sh
zap deps update         # Re-resolve all dependencies
zap deps update <name>  # Re-resolve a single dependency
```

---

## Type System

Types are declared at function boundaries. Narrower numeric types are implicitly widened at call sites (e.g., `i8` to `i64`), but no lossy conversions are implicit.

| Category | Types |
|---|---|
| Signed integers | `i8` `i16` `i32` `i64` |
| Unsigned integers | `u8` `u16` `u32` `u64` |
| Floats | `f16` `f32` `f64` |
| Platform-sized | `usize` `isize` |
| Primitives | `Bool` `String` `Atom` `Nil` |
| Bottom | `Never` |
| Compound | tuples, lists, maps, structs, unions |

### Structs

```zap
pub struct User {
  name :: String,
  email :: String,
  age :: i64,
}

pub struct Circle extends Shape {
  radius :: f64,
}
```

### Unions

Tagged unions represent values that can be one of several variants:

```zap
pub union Direction {
  North,
  South,
  East,
  West,
}
```

---

## Standard Library

Zap includes a standard library of modules for working with primitive types and collections:

| Module | Functions |
|---|---|
| `Integer` | `to_string`, `abs`, `max`, `min`, `parse`, `remainder`, `pow`, `clamp`, `digits`, `to_float` |
| `Float` | `to_string`, `abs`, `max`, `min`, `parse`, `round`, `floor`, `ceil`, `truncate`, `to_integer`, `clamp` |
| `Bool` | `to_string`, `negate` |
| `String` | `length`, `slice`, `contains`, `starts_with`, `ends_with`, `trim`, `upcase`, `downcase`, `reverse`, `replace`, `index_of`, `pad_leading`, `pad_trailing`, `repeat`, `to_integer`, `to_float` |
| `Atom` | `to_string` |
| `List` | `empty?`, `length`, `head`, `tail`, `at`, `last`, `contains?`, `reverse`, `prepend`, `append`, `concat`, `take`, `drop`, `uniq` |
| `Enum` | `map`, `filter`, `reject`, `reduce`, `each`, `find`, `any?`, `all?`, `count`, `sum`, `product`, `max`, `min`, `sort`, `flat_map` |

### Higher-Order Functions

Functions are first-class values. Pass named functions or anonymous functions as arguments:

```zap
# Named function as callback
Enum.map([1, 2, 3], double)

# Anonymous function with type annotations
Enum.map([1, 2, 3], fn(x :: i64) -> i64 { x * 2 })

# Filter with predicate
Enum.filter([1, 2, 3, 4, 5], fn(x :: i64) -> Bool { x > 3 })

# Reduce with accumulator
Enum.reduce([1, 2, 3, 4], 0, fn(acc :: i64, x :: i64) -> i64 { acc + x })

# Sort with comparator
Enum.sort([3, 1, 2], fn(a :: i64, b :: i64) -> Bool { a < b })
```

Function type annotations use the arrow syntax: `callback :: (i64 -> i64)`, `predicate :: (i64 -> Bool)`.

### Implicit Numeric Widening

Narrower numeric types are automatically widened to wider types at function call sites:

```zap
fn process(value :: i64) -> i64 { value * 2 }

small :: i8 = 42
process(small)  # i8 automatically widened to i64
```

Widening rules: `i8` -> `i16` -> `i32` -> `i64`, `u8` -> `u16` -> `u32` -> `u64`, `f16` -> `f32` -> `f64`. No lossy conversions (signed-to-unsigned, wider-to-narrower, integer-to-float) are implicit.

---

## Native Function Bindings (`@native`)

Zap library functions that need Zig runtime implementations (I/O, string operations, atom tables, etc.) use `@native` attributes instead of hardcoded compiler knowledge:

```zap
pub module IO {
  @native = "Prelude.println"
  pub fn puts(_message :: String) -> String
}

pub module Zest.Runtime {
  @native = "ZestRuntime.reset"
  pub fn reset() -> String

  @native = "ZestRuntime.fail"
  pub fn fail(_message :: String) -> String
}
```

The `@native = "Module.function"` annotation tells the compiler to route calls to `@import("zap_runtime").Module.function(args)` in the generated ZIR. No function body is needed — the annotation IS the implementation binding. The compiler has zero knowledge of specific library modules; all bindings are declared in `.zap` source files.

---

## Architecture

Zap uses a per-module compilation architecture with per-module ZIR emission:

1. **Discovery** — start from the entry point, follow module references to find files
2. **Pass 1** — parse all files, collect declarations into a shared scope graph
3. **Pass 2** — compile each file: macro expand, desugar, type check, HIR
4. **Pass 3** — monomorphize generic functions, lower to IR
5. **Pass 4** — run analysis pipeline (escape analysis, interprocedural summaries, region solving, lambda sets, Perceus reuse)
6. **Pass 5** — emit per-module ZIR, inject into Zig compilation, codegen

Each Zap module becomes its own Zig ZIR module. Cross-module calls use `@import("Module").function(args)` chains. Namespace re-export modules are generated for hierarchical module names (e.g., `Zest` re-exports `Runtime`, `Case`, `Runner`). `@native` functions skip ZIR emission — their calls route directly to `@import("zap_runtime")`.

```
  .zap source files
      |
      v
   Discovery -------- follow module references from entry point
      |
      v
   Parse ------------ per-file ASTs
      |
      v
   Collect ---------- shared scope graph + type store
      |
      v
   Macro Expansion -- AST->AST transforms (Kernel macros: if, and, or, |>)
      |
      v
   Desugar ---------- simplify syntax
      |
      v
   Type Check ------- overload resolution + inference
      |
      v
   HIR Lowering ----- typed intermediate representation
      |
      v
   Monomorphize ---- specialize generic functions for concrete types
      |
      v
   IR Lowering ------ lower-level IR (arity-suffixed function names)
      |
      v
   Analysis --------- escape, regions, lambda sets, Perceus
      |
      v
   Per-Module ZIR --- each Zap module -> its own Zig ZIR module
      |                cross-module calls -> @import chains
      |                @native functions -> @import("zap_runtime")
      v
   Codegen ---------- native binary (via LLVM)
```

---

## CLI Reference

```
zap init                     Create a new project in the current directory
zap build [target]           Compile a target defined in build.zap (defaults to :default)
zap run [target] [-- args]   Compile and run a target (defaults to :default)
zap test                     Run the test suite (alias for `zap run test`)
zap deps update [name]       Re-resolve dependencies and rewrite zap.lock
```

---

## Development

```sh
# Download pre-built deps (first time only)
zig build setup

# Build the zap compiler
zig build

# Run Zig-level unit tests
zig build test

# Run Zap test suite (323 tests across 28 modules)
zap test

# Build and run an example
cd examples/hello
zap run hello
```

---

## Building the Zig Fork

Zap depends on a fork of the Zig compiler (`libzig_compiler.a`) with LLVM enabled. The fork adds a C-ABI surface (`zir_api.zig`) that allows Zap to inject ZIR directly into Zig's compilation pipeline.

The build follows the same process as the official [zig-bootstrap](https://codeberg.org/ziglang/zig-bootstrap):

### Prerequisites

- C/C++ compiler (Xcode command line tools on macOS, GCC on Linux)
- CMake 3.19+
- Ninja
- Zig 0.16.0 (only needed if skipping the bootstrap)

### Step 1: Clone zig-bootstrap 0.16.0

```sh
git clone --depth 1 --branch 0.16.0 \
  https://codeberg.org/ziglang/zig-bootstrap.git \
  ~/zig-bootstrap-0.16.0
```

### Step 2: Build LLVM, Clang, LLD from source (host)

```sh
cd ~/zig-bootstrap-0.16.0
mkdir -p out/build-llvm-host && cd out/build-llvm-host
cmake ../../llvm \
  -DCMAKE_INSTALL_PREFIX="$HOME/zig-bootstrap-0.16.0/out/host" \
  -DCMAKE_PREFIX_PATH="$HOME/zig-bootstrap-0.16.0/out/host" \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLVM_ENABLE_PROJECTS="lld;clang" \
  -DLLVM_ENABLE_BINDINGS=OFF \
  -DLLVM_ENABLE_LIBEDIT=OFF \
  -DLLVM_ENABLE_LIBPFM=OFF \
  -DLLVM_ENABLE_LIBXML2=OFF \
  -DLLVM_ENABLE_OCAMLDOC=OFF \
  -DLLVM_ENABLE_PLUGINS=OFF \
  -DLLVM_ENABLE_Z3_SOLVER=OFF \
  -DLLVM_ENABLE_ZSTD=OFF \
  -DLLVM_INCLUDE_UTILS=OFF \
  -DLLVM_INCLUDE_TESTS=OFF \
  -DLLVM_INCLUDE_EXAMPLES=OFF \
  -DLLVM_INCLUDE_BENCHMARKS=OFF \
  -DLLVM_INCLUDE_DOCS=OFF \
  -DCLANG_BUILD_TOOLS=OFF \
  -DCLANG_INCLUDE_DOCS=OFF \
  -DCLANG_INCLUDE_TESTS=OFF \
  -GNinja
cmake --build . --target install
```

This takes ~20 minutes.

### Step 3: Build host Zig via CMake

```sh
cd ~/zig-bootstrap-0.16.0
mkdir -p out/build-zig-host && cd out/build-zig-host
cmake ../../zig \
  -DCMAKE_INSTALL_PREFIX="$HOME/zig-bootstrap-0.16.0/out/host" \
  -DCMAKE_PREFIX_PATH="$HOME/zig-bootstrap-0.16.0/out/host" \
  -DCMAKE_BUILD_TYPE=Release \
  -DZIG_VERSION="0.16.0" \
  -GNinja
cmake --build . --target install
```

This bootstraps through wasm2c -> zig1 -> zig2 -> stage3. Takes ~15 minutes.

### Step 4: Rebuild LLVM with Zig as the compiler

```sh
cd ~/zig-bootstrap-0.16.0
ROOTDIR="$(pwd)"
TARGET="aarch64-macos-none"  # or x86_64-linux-gnu, etc.
MCPU="baseline"
ZIG="$ROOTDIR/out/host/bin/zig"

# Build zlib
mkdir -p out/build-zlib-$TARGET-$MCPU && cd out/build-zlib-$TARGET-$MCPU
cmake "$ROOTDIR/zlib" \
  -DCMAKE_INSTALL_PREFIX="$ROOTDIR/out/$TARGET-$MCPU" \
  -DCMAKE_PREFIX_PATH="$ROOTDIR/out/$TARGET-$MCPU" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CROSSCOMPILING=True \
  -DCMAKE_SYSTEM_NAME="Darwin" \
  -DCMAKE_C_COMPILER="$ZIG;cc;-fno-sanitize=all;-s;-target;$TARGET;-mcpu=$MCPU" \
  -DCMAKE_CXX_COMPILER="$ZIG;c++;-fno-sanitize=all;-s;-target;$TARGET;-mcpu=$MCPU" \
  -DCMAKE_ASM_COMPILER="$ZIG;cc;-fno-sanitize=all;-s;-target;$TARGET;-mcpu=$MCPU" \
  -DCMAKE_AR="$ROOTDIR/out/host/bin/llvm-ar" \
  -DCMAKE_RANLIB="$ROOTDIR/out/host/bin/llvm-ranlib" \
  -GNinja
cmake --build . --target install

# Build zstd
mkdir -p "$ROOTDIR/out/$TARGET-$MCPU/lib"
cp "$ROOTDIR/zstd/lib/zstd.h" "$ROOTDIR/out/$TARGET-$MCPU/include/zstd.h"
cd "$ROOTDIR/out/$TARGET-$MCPU/lib"
$ZIG build-lib --name zstd -target $TARGET -mcpu=$MCPU -fstrip -OReleaseFast -lc \
  "$ROOTDIR/zstd/lib/decompress/zstd_ddict.c" \
  "$ROOTDIR/zstd/lib/decompress/zstd_decompress.c" \
  "$ROOTDIR/zstd/lib/decompress/huf_decompress.c" \
  "$ROOTDIR/zstd/lib/decompress/huf_decompress_amd64.S" \
  "$ROOTDIR/zstd/lib/decompress/zstd_decompress_block.c" \
  "$ROOTDIR/zstd/lib/compress/zstdmt_compress.c" \
  "$ROOTDIR/zstd/lib/compress/zstd_opt.c" \
  "$ROOTDIR/zstd/lib/compress/hist.c" \
  "$ROOTDIR/zstd/lib/compress/zstd_ldm.c" \
  "$ROOTDIR/zstd/lib/compress/zstd_fast.c" \
  "$ROOTDIR/zstd/lib/compress/zstd_compress_literals.c" \
  "$ROOTDIR/zstd/lib/compress/zstd_double_fast.c" \
  "$ROOTDIR/zstd/lib/compress/huf_compress.c" \
  "$ROOTDIR/zstd/lib/compress/fse_compress.c" \
  "$ROOTDIR/zstd/lib/compress/zstd_lazy.c" \
  "$ROOTDIR/zstd/lib/compress/zstd_compress.c" \
  "$ROOTDIR/zstd/lib/compress/zstd_compress_sequences.c" \
  "$ROOTDIR/zstd/lib/compress/zstd_compress_superblock.c" \
  "$ROOTDIR/zstd/lib/deprecated/zbuff_compress.c" \
  "$ROOTDIR/zstd/lib/deprecated/zbuff_decompress.c" \
  "$ROOTDIR/zstd/lib/deprecated/zbuff_common.c" \
  "$ROOTDIR/zstd/lib/common/entropy_common.c" \
  "$ROOTDIR/zstd/lib/common/pool.c" \
  "$ROOTDIR/zstd/lib/common/threading.c" \
  "$ROOTDIR/zstd/lib/common/zstd_common.c" \
  "$ROOTDIR/zstd/lib/common/xxhash.c" \
  "$ROOTDIR/zstd/lib/common/debug.c" \
  "$ROOTDIR/zstd/lib/common/fse_decompress.c" \
  "$ROOTDIR/zstd/lib/common/error_private.c" \
  "$ROOTDIR/zstd/lib/dictBuilder/zdict.c" \
  "$ROOTDIR/zstd/lib/dictBuilder/divsufsort.c" \
  "$ROOTDIR/zstd/lib/dictBuilder/fastcover.c" \
  "$ROOTDIR/zstd/lib/dictBuilder/cover.c"

# Rebuild LLVM with Zig
mkdir -p "$ROOTDIR/out/build-llvm-$TARGET-$MCPU" && cd "$ROOTDIR/out/build-llvm-$TARGET-$MCPU"
cmake "$ROOTDIR/llvm" \
  -DCMAKE_INSTALL_PREFIX="$ROOTDIR/out/$TARGET-$MCPU" \
  -DCMAKE_PREFIX_PATH="$ROOTDIR/out/$TARGET-$MCPU" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CROSSCOMPILING=True \
  -DCMAKE_SYSTEM_NAME="Darwin" \
  -DCMAKE_C_COMPILER="$ZIG;cc;-fno-sanitize=all;-s;-target;$TARGET;-mcpu=$MCPU" \
  -DCMAKE_CXX_COMPILER="$ZIG;c++;-fno-sanitize=all;-s;-target;$TARGET;-mcpu=$MCPU" \
  -DCMAKE_ASM_COMPILER="$ZIG;cc;-fno-sanitize=all;-s;-target;$TARGET;-mcpu=$MCPU" \
  -DCMAKE_AR="$ROOTDIR/out/host/bin/llvm-ar" \
  -DCMAKE_RANLIB="$ROOTDIR/out/host/bin/llvm-ranlib" \
  -DLLVM_ENABLE_PROJECTS="lld;clang" \
  -DLLVM_ENABLE_ZLIB=FORCE_ON \
  -DLLVM_ENABLE_ZSTD=FORCE_ON \
  -DLLVM_USE_STATIC_ZSTD=ON \
  -DLLVM_BUILD_STATIC=ON \
  -DLLVM_BUILD_TOOLS=OFF \
  -DLLVM_BUILD_UTILS=OFF \
  -DLLVM_INCLUDE_TESTS=OFF \
  -DLLVM_INCLUDE_EXAMPLES=OFF \
  -DLLVM_INCLUDE_BENCHMARKS=OFF \
  -DLLVM_INCLUDE_DOCS=OFF \
  -DLLVM_TABLEGEN="$ROOTDIR/out/host/bin/llvm-tblgen" \
  -DCLANG_TABLEGEN="$ROOTDIR/out/build-llvm-host/bin/clang-tblgen" \
  -DCLANG_BUILD_TOOLS=OFF \
  -DCLANG_INCLUDE_TESTS=OFF \
  -DCLANG_INCLUDE_DOCS=OFF \
  -DLLD_BUILD_TOOLS=OFF \
  -GNinja
cmake --build . --target install
```

This takes ~30 minutes. The output at `out/aarch64-macos-none-baseline/lib/` contains all the LLVM static libraries.

### Step 5: Build `libzig_compiler.a` for Zap

```sh
cd ~/projects/zig   # the Zap Zig fork
ROOTDIR="$HOME/zig-bootstrap-0.16.0"
TARGET="aarch64-macos-none"
MCPU="baseline"
ZIG="$ROOTDIR/out/host/bin/zig"

$ZIG build lib \
  --search-prefix "$ROOTDIR/out/$TARGET-$MCPU" \
  -Dstatic-llvm \
  -Doptimize=ReleaseSafe \
  -Dtarget="$TARGET" \
  -Dcpu="$MCPU" \
  -Dversion-string="0.16.0"
```

Output: `zig-out/lib/libzig_compiler.a`

### Step 6: Build Zap

```sh
cd ~/projects/zap
zig build -Dllvm-lib-path="$HOME/zig-bootstrap-0.16.0/out/aarch64-macos-none-baseline/lib"
```

Output: `zig-out/bin/zap`

---

## License

[MIT](LICENSE)

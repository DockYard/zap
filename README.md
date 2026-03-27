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

- **Zig 0.15.2** (install via [asdf](https://asdf-vm.com/), [zigup](https://github.com/marler8/zigup), or [ziglang.org](https://ziglang.org/download/))
- **Pre-built Zap compiler deps** for your platform (from the [Zig fork releases](https://github.com/DockYard/zig/releases))

#### 1. Download the deps

Download the `zap-deps` tarball for your platform from [DockYard/zig releases](https://github.com/DockYard/zig/releases/tag/v0.15.2-zap.1):

| Platform | File |
|---|---|
| macOS Apple Silicon | `zap-deps-aarch64-macos-none.tar.xz` |
| Linux arm64 | `zap-deps-aarch64-linux-gnu.tar.xz` |
| Linux x86_64 | `zap-deps-x86_64-linux-gnu.tar.xz` |

```sh
# Example for macOS Apple Silicon
curl -LO https://github.com/DockYard/zig/releases/download/v0.15.2-zap.1/zap-deps-aarch64-macos-none.tar.xz
tar xJf zap-deps-aarch64-macos-none.tar.xz
```

#### 2. Clone and build Zap

```sh
git clone https://github.com/DockYard/zap.git
cd zap
zig build \
  -Dzap-compiler-lib=../aarch64-macos-none/libzap_compiler.a \
  -Dllvm-lib-path=../aarch64-macos-none/llvm-libs
```

This produces the compiler binary at `zig-out/bin/zap`.

#### Building the Zig fork from scratch

If you want to build `libzap_compiler.a` and the LLVM libraries yourself instead of using the pre-built deps, see [Building the Zig Fork](#building-the-zig-fork) below.

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
zap build my_app    # Compile
zap run my_app      # Compile and run
```

The binary is output to `zap-out/bin/my_app`.

---

## The Language

### Modules and Functions

All functions must be defined inside a module. Modules group related functions. Functions declare types at the boundary and infer everything inside.

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

### Entry Point

Every program needs a `main` function inside a module. The `build.zap` manifest specifies the entry point:

```elixir
defmodule MyApp do
  def main(_args :: [String]) do
    IO.puts("Hello!")
  end
end
```

### Pipe Operator

Chain function calls, passing the result of each step as the first argument to the next:

```elixir
defmodule Pipes do
  def double(x :: i64) :: i64 do
    x * 2
  end

  def add_one(x :: i64) :: i64 do
    x + 1
  end

  def main() do
    5
    |> Pipes.double()
    |> Pipes.add_one()
  end
end
```

### Pattern Matching

Multiple function clauses with the same name form an overload group. The compiler resolves which clause to call based on argument values and types.

```elixir
defmodule Factorial do
  def factorial(0 :: i64) :: i64 do
    1
  end

  def factorial(n :: i64) :: i64 do
    n * factorial(n - 1)
  end
end
```

### Guards

Function clauses can carry guard conditions that participate in dispatch:

```elixir
defmodule Guards do
  def classify(n :: i64) :: String if n > 0 do
    "positive"
  end

  def classify(n :: i64) :: String if n < 0 do
    "negative"
  end

  def classify(_ :: i64) :: String do
    "zero"
  end
end
```

### Case Expressions

Pattern matching inside function bodies:

```elixir
defmodule CaseExpr do
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
end
```

### If / Else

If/else is an expression — it produces a value:

```elixir
defmodule Math do
  def abs(x :: i64) :: i64 do
    if x < 0 do
      -x
    else
      x
    end
  end
end
```

---

## Build Manifest

Every Zap project has a `build.zap` that defines build targets:

```elixir
defmodule MyApp.Builder do
  def manifest(env :: Zap.Env) :: Zap.Manifest do
    case env.target do
      :my_app ->
        %Zap.Manifest{
          name: "my_app",
          version: "0.1.0",
          kind: :bin,
          root: "MyApp.main/1",
          paths: ["lib/**/*.zap"],
          # :debug | :release_safe | :release_fast | :release_small
          optimize: :release_safe
        }
      _ ->
        panic("Unknown target")
    end
  end
end
```

| Field | Description |
|---|---|
| `name` | Output binary name |
| `version` | Project version |
| `kind` | `:bin`, `:lib`, or `:obj` |
| `root` | Entry point as `"Module.function/arity"` |
| `paths` | Glob patterns for source files (relative to `build.zap`) |
| `optimize` | `:debug`, `:release_safe`, `:release_fast`, or `:release_small` |

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

```elixir
defstruct User do
  name :: String
  email :: String
  age :: i64
end

defstruct Circle extends Shape do
  radius :: f64
end
```

### Enums

```elixir
defenum Direction do
  North
  South
  East
  West
end
```

---

## Architecture

Zap includes a fork of the Zig compiler as a static library. The compiler lowers Zap IR to ZIR (Zig Intermediate Representation), then Zig's semantic analysis, LLVM code generation, and linker produce native binaries. No intermediate Zig source code is generated during normal compilation.

```
  .zap source
      |
      v
   Lexer ----------- tokenize with indent/dedent tracking
      |
      v
   Parser ---------- surface AST
      |
      v
   Collector ------- register modules and functions
      |
      v
   Macro Expansion - AST->AST transforms to fixed point
      |
      v
   Desugar --------- simplify syntax before type checking
      |
      v
   Type Checker ---- overload resolution + inference
      |
      v
   HIR Lowering ---- typed intermediate representation
      |
      v
   IR Lowering ----- lower-level IR closer to Zig semantics
      |
      v
   ZIR Emit -------- emit Zig Intermediate Representation
      |
      v
   Sema ------------ Zig semantic analysis (via LLVM)
      |
      v
   Codegen --------- native binary
```

---

## CLI Reference

```
zap init                    Create a new project in the current directory
zap build <target>          Compile a target defined in build.zap
zap run <target> [-- args]  Compile and run a target
```

---

## Development

```sh
# Run the full test suite
zig build test

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
- Zig 0.15.2 (only needed if skipping the bootstrap)

### Step 1: Clone zig-bootstrap 0.15.2

```sh
git clone --depth 1 --branch 0.15.2 \
  https://codeberg.org/ziglang/zig-bootstrap.git \
  ~/zig-bootstrap-0.15.2
```

### Step 2: Build LLVM, Clang, LLD from source (host)

```sh
cd ~/zig-bootstrap-0.15.2
mkdir -p out/build-llvm-host && cd out/build-llvm-host
cmake ../../llvm \
  -DCMAKE_INSTALL_PREFIX="$HOME/zig-bootstrap-0.15.2/out/host" \
  -DCMAKE_PREFIX_PATH="$HOME/zig-bootstrap-0.15.2/out/host" \
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
cd ~/zig-bootstrap-0.15.2
mkdir -p out/build-zig-host && cd out/build-zig-host
cmake ../../zig \
  -DCMAKE_INSTALL_PREFIX="$HOME/zig-bootstrap-0.15.2/out/host" \
  -DCMAKE_PREFIX_PATH="$HOME/zig-bootstrap-0.15.2/out/host" \
  -DCMAKE_BUILD_TYPE=Release \
  -DZIG_VERSION="0.15.2" \
  -GNinja
cmake --build . --target install
```

This bootstraps through wasm2c -> zig1 -> zig2 -> stage3. Takes ~15 minutes.

### Step 4: Rebuild LLVM with Zig as the compiler

```sh
cd ~/zig-bootstrap-0.15.2
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
ROOTDIR="$HOME/zig-bootstrap-0.15.2"
TARGET="aarch64-macos-none"
MCPU="baseline"
ZIG="$ROOTDIR/out/host/bin/zig"

$ZIG build lib \
  --search-prefix "$ROOTDIR/out/$TARGET-$MCPU" \
  -Dstatic-llvm \
  -Doptimize=ReleaseSafe \
  -Dtarget="$TARGET" \
  -Dcpu="$MCPU" \
  -Dversion-string="0.15.2"
```

Output: `zig-out/lib/libzig_compiler.a`

### Step 6: Build Zap

```sh
cd ~/projects/zap
zig build -Dllvm-lib-path="$HOME/zig-bootstrap-0.15.2/out/aarch64-macos-none-baseline/lib"
```

Output: `zig-out/bin/zap`

---

## License

[MIT](LICENSE)

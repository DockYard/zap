# Zap GPU Computing — Research Brief

> This document provides complete context for a deep research agent investigating how the Zap programming language should support GPU-accelerated numerical computing. The reader is assumed to have zero prior knowledge of Zap.

---

## Table of Contents

1. [What Is Zap](#1-what-is-zap)
2. [Language Syntax and Semantics](#2-language-syntax-and-semantics)
3. [Compilation Pipeline](#3-compilation-pipeline)
4. [The Zig Fork and C-ABI Boundary](#4-the-zig-fork-and-c-abi-boundary)
5. [Runtime Architecture](#5-runtime-architecture)
6. [The `use` / `__using__` Pattern](#6-the-use--__using__-pattern)
7. [Protocol System](#7-protocol-system)
8. [Dependency System](#8-dependency-system)
9. [Existing Standard Library](#9-existing-standard-library)
10. [GPU Computing Design](#10-gpu-computing-design)
11. [Research Questions](#11-research-questions)

---

## 1. What Is Zap

Zap is a general-purpose functional programming language that compiles to native binaries. It takes the developer experience of Elixir — pattern matching, pipe operators, algebraic types, macros — and strips away the runtime overhead. No VM, no garbage collector, no interpreter. Zap code compiles directly to machine code via LLVM.

**Core philosophy:**

- **Features are implemented in Zap code**, not hardcoded in the compiler. The compiler is a general-purpose tool that knows nothing about specific Zap structs (IO, String, Math, etc.). Standard library functions, macros, test frameworks, and DSLs are all written in `.zap` source files.
- **The compiler only handles language primitives**: parsing, type system, ZIR emission, and a small set of runtime primitives that physically cannot be expressed in Zap (stdout, memory allocation, OS argv).
- **No workarounds or hacks.** Every solution must be the correct, production-grade, long-term fix.

**Technical identity:**

- Functional language with immutable data structures
- Atomic Reference Counting (ARC) — no garbage collector
- Pattern matching with multiple function clauses and guards
- Macro system with `quote`/`unquote` for AST transformation
- Protocols (trait-like interfaces) with implementations
- Compiles through Zig's ZIR (Zig Intermediate Representation) into LLVM
- Single native binary output (~341MB self-contained, statically linking LLVM 20)
- Built on a fork of Zig 0.16.0 maintained by DockYard

**Current state:** Early stage. The core pipeline works and examples compile and run, but not everything is fully implemented yet. The standard library covers IO, String, Integer, Float, Bool, Atom, List, Map, Enum, Math, File, Path, System, and the Zest test framework.

---

## 2. Language Syntax and Semantics

### Structs and Files

Every `.zap` file contains exactly one struct. The struct name maps to the file path:

| Struct name      | File path              |
|------------------|------------------------|
| `App`            | `lib/app.zap`          |
| `Config.Parser`  | `lib/config/parser.zap`|
| `Math`           | `lib/math.zap`         |

```zap
# lib/math.zap
pub struct Math {
  pub fn square(x :: i64) -> i64 {
    x * x
  }

  pub fn double(x :: i64) -> i64 {
    x * 2
  }
}
```

### Type System

Types are declared at function boundaries using `::` annotations:

| Category         | Types                                          |
|------------------|------------------------------------------------|
| Signed integers  | `i8` `i16` `i32` `i64`                        |
| Unsigned integers| `u8` `u16` `u32` `u64`                        |
| Floats           | `f16` `f32` `f64`                              |
| Platform-sized   | `usize` `isize`                                |
| Primitives       | `Bool` `String` `Atom` `Nil`                   |
| Bottom           | `Never`                                        |
| Compound         | tuples, lists, maps, structs, unions           |

Narrower numeric types are implicitly widened at call sites (e.g., `i8` to `i64`), but no lossy conversions are implicit.

### Structs and Unions

```zap
pub struct User {
  name :: String,
  email :: String,
  age :: i64,
}

pub union Direction {
  North,
  South,
  East,
  West,
}
```

### Pattern Matching

Multiple function clauses with the same name form an overload group:

```zap
pub fn factorial(0 :: i64) -> i64 { 1 }
pub fn factorial(n :: i64) -> i64 { n * factorial(n - 1) }
```

Guard conditions participate in dispatch:

```zap
pub fn classify(n :: i64) -> String if n > 0 { "positive" }
pub fn classify(n :: i64) -> String if n < 0 { "negative" }
pub fn classify(_ :: i64) -> String { "zero" }
```

### Pipe Operator

```zap
5
|> double()
|> add_one()
# equivalent to: add_one(double(5))
```

The pipe operator is itself a Zap macro defined in `lib/kernel.zap`:

```zap
pub macro |>(left :: Expr, right :: Expr) -> Expr {
  _name = elem(right, 0)
  _meta = elem(right, 1)
  _args = elem(right, 2)
  _new_args = prepend(_args, left)
  tuple(_name, _meta, _new_args)
}
```

### Higher-Order Functions

Functions are first-class values:

```zap
Enum.map([1, 2, 3], fn(x :: i64) -> i64 { x * 2 })
Enum.filter([1, 2, 3, 4], fn(x :: i64) -> Bool { x > 2 })
Enum.reduce([1, 2, 3], 0, fn(acc :: i64, x :: i64) -> i64 { acc + x })
```

Function type syntax: `callback :: (i64 -> i64)`, `predicate :: (i64 -> Bool)`.

### Case Expressions

```zap
case result {
  {:ok, value} -> value
  {:error, reason} -> handle_error(reason)
  _ -> "unknown"
}
```

### String Interpolation and Concatenation

```zap
name = "World"
IO.puts("Hello, #{name}!")       # interpolation
IO.puts("hello" <> " " <> "world")  # concatenation
```

### For Comprehensions

```zap
doubled = for x <- [1, 2, 3] { x * 2 }
# [2, 4, 6]

evens = for x <- [1, 2, 3, 4, 5, 6], x rem 2 == 0 { x }
# [2, 4, 6]
```

### Heredoc Strings

Multi-line strings use triple-quote `"""`:

```zap
@doc = """
  This is a multi-line documentation string.
  Used for struct and function documentation.
  """
```

---

## 3. Compilation Pipeline

Zap uses a multi-pass compilation architecture:

```
  .zap source files
      |
      v
   Discovery -------- follow struct references from entry point
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
   Desugar ---------- simplify syntax sugar
      |
      v
   Type Check ------- overload resolution + type inference
      |
      v
   HIR Lowering ----- typed intermediate representation
      |
      v
   Monomorphize ---- specialize generic functions for concrete types
      |
      v
   IR Lowering ------ lower-level IR (explicit control flow, locals, ARC ops)
      |
      v
   Analysis --------- escape analysis, regions, lambda sets, Perceus
      |
      v
   Per-Struct ZIR --- each Zap struct -> its own Zig ZIR struct
      |                cross-struct calls -> @import chains
      |                :zig. functions -> @import("zap_runtime")
      v
   Codegen ---------- native binary (via Zig compiler -> LLVM)
```

### Three-Pass Frontend

**Pass 1 (`collectAll`):** Parse all files, collect declarations into a shared scope graph and type store. Returns a `CompilationContext`.

**Pass 2 (`compileFile`, per-struct):** Macro expand → desugar → type check → HIR → IR. Each struct is compiled against the shared context.

**Pass 3 (`mergeAndFinalize`):** Merge IR programs from all structs, run the full analysis pipeline (escape analysis, interprocedural summaries, region inference, lambda sets, Perceus/ARC optimization).

### ZIR Emission

After analysis, each Zap struct is emitted as its own Zig ZIR struct. The ZIR builder (`src/zir_builder.zig`) translates Zap IR instructions into ZIR instruction sequences by calling C-ABI functions exported by the Zig fork.

Cross-struct calls become `@import("Struct").function(args)` chains in ZIR. Native runtime calls (`:zig.Struct.function()`) become `@import("zap_runtime").RuntimeStruct.function()` chains.

### Key Property: AOT Compilation

Zap is fully ahead-of-time compiled. There is no JIT, no runtime compilation, no interpreter. The entire program — including all generic specializations — is resolved at compile time. The output is a single native binary.

---

## 4. The Zig Fork and C-ABI Boundary

### What the Fork Is

Zap depends on a fork of Zig 0.16.0, maintained by DockYard at `~/projects/zig`. The fork adds a C-ABI surface (`src/zir_api.zig`) that allows Zap's compiler to inject ZIR directly into Zig's compilation pipeline.

The fork is compiled into a static library `libzap_compiler.a` which is linked into the Zap binary at build time. The result is a single ~341MB self-contained binary that statically links the Zig compiler, LLVM 20, Clang, and LLD. No external Zig installation is required.

### Pre-built Dependencies

`zig build setup` downloads pre-built `zap-deps` tarballs (version `v0.16.0-zap.1`) from GitHub releases. These contain `libzap_compiler.a` and all LLVM static libraries for the host platform. Alternatively, users can build the fork from scratch using the zig-bootstrap process (takes ~45 minutes).

### The C-ABI Surface

The Zig fork exports C-ABI functions that the Zap compiler calls to build ZIR programs. These are declared as `extern "c"` in `src/zir_builder.zig`. The key categories:

**Lifecycle:**
- `zir_builder_create()` → opaque builder handle
- `zir_builder_destroy(handle)` → cleanup
- `zir_compilation_create(zig_lib_dir, cache_dirs, output_path, root_name, output_mode, optimize_mode, ...)` → compilation context
- `zir_compilation_update(ctx)` → run Sema + codegen
- `zir_compilation_add_struct_source(ctx, name, source_ptr, source_len)` → inject Zig source as a struct
- `zir_builder_inject(builder, compilation)` → finalize and inject ZIR into compilation

**Constants and Primitives:**
- `zir_builder_emit_int(value: i64)` → integer literal
- `zir_builder_emit_float(value: f64)` → float literal
- `zir_builder_emit_str(ptr, len)` → string literal
- `zir_builder_emit_bool(value)` → boolean literal
- `zir_builder_emit_void()` → void value
- `zir_builder_emit_enum_literal(name_ptr, name_len)` → enum/atom literal

**Functions and Calls:**
- `zir_builder_begin_func(name, ret_type)` / `zir_builder_end_func()` — function definition
- `zir_builder_emit_param(name, type_ref)` → parameter declaration
- `zir_builder_emit_call(name, args)` → named function call
- `zir_builder_emit_call_ref(callee, args)` → indirect call (closures, function values)
- `zir_builder_emit_ret(operand)` / `zir_builder_emit_ret_void()` — return

**Control Flow:**
- `zir_builder_emit_if_else(cond, then, else)` → conditional
- `zir_builder_emit_if_else_bodies(cond, then_insts, then_result, else_insts, else_result)` → conditional with instruction bodies
- `zir_builder_emit_loop(body_ptr, body_len)` → loop
- `zir_builder_emit_repeat()` → loop continue
- `zir_builder_emit_bool_br_and(lhs, rhs_body, rhs_result)` → short-circuit AND
- `zir_builder_emit_bool_br_or(lhs, rhs_body, rhs_result)` → short-circuit OR

**Type Construction (Zig 0.16 reification builtins):**
- `zir_builder_emit_reify_struct(layout, backing_ty, field_names, field_types, field_attrs)` → struct type
- `zir_builder_emit_reify_enum(tag_ty, mode, field_names, field_values)` → enum type
- `zir_builder_emit_reify_union(layout, arg_ty, field_names, field_types, field_attrs)` → union type
- `zir_builder_emit_reify_pointer(size, attrs, elem_ty, sentinel)` → pointer type
- `zir_builder_emit_reify_tuple(field_types)` → tuple type
- `zir_builder_add_struct_type(name, fields...)` → named struct type
- `zir_builder_add_enum_type(name, variants...)` → named enum type

**Aggregates:**
- `zir_builder_emit_struct_init_anon(names, values)` → anonymous struct init
- `zir_builder_emit_struct_init_typed(struct_type, names, values)` → typed struct init
- `zir_builder_emit_union_init(union_type, field_name, init_value)` → union init
- `zir_builder_emit_array_init_anon(values)` → array init

**Memory and References:**
- `zir_builder_emit_field_val(object, field_name)` → read struct field
- `zir_builder_emit_field_ptr(object, field_name)` → address of struct field
- `zir_builder_emit_store(ptr, value)` → store to pointer
- `zir_builder_emit_load(ptr)` → load from pointer
- `zir_builder_emit_alloc(type_ref)` / `zir_builder_emit_alloc_mut(type_ref)` → stack allocation
- `zir_builder_emit_import(name)` → `@import` statement

**Arithmetic and Bitwise:**
- `zir_builder_emit_binop(tag, lhs, rhs)` → binary operation (add, sub, mul, div, mod, shift, bitwise, comparison)
- `zir_builder_emit_negate(operand)` → arithmetic negation
- `zir_builder_emit_bool_not(operand)` → logical not
- Saturating and overflow-checked variants available

**Math Builtins:**
- `zir_builder_emit_sqrt`, `zir_builder_emit_sin`, `zir_builder_emit_cos`, `zir_builder_emit_exp`, `zir_builder_emit_exp2`, `zir_builder_emit_log`, `zir_builder_emit_log2`, `zir_builder_emit_log10`, `zir_builder_emit_abs`, `zir_builder_emit_floor`, `zir_builder_emit_ceil`, `zir_builder_emit_round`, `zir_builder_emit_trunc_float`

**SIMD/Vector (relevant for GPU):**
- `zir_builder_emit_vector_type(len, elem_type)` → `@Vector(len, T)`
- `zir_builder_emit_splat(scalar, len)` → broadcast scalar to vector
- `zir_builder_emit_shuffle(a, b, mask)` → vector shuffle
- `zir_builder_emit_reduce(operand, operation)` → vector reduction

**Type Introspection:**
- `zir_builder_emit_size_of`, `zir_builder_emit_align_of`, `zir_builder_emit_bit_size_of`, `zir_builder_emit_offset_of`, `zir_builder_emit_tag_name`, `zir_builder_emit_type_name`, `zir_builder_emit_has_decl`, `zir_builder_emit_has_field`, `zir_builder_emit_typeof`, `zir_builder_emit_type_info`

**Optional/Error Handling:**
- `zir_builder_emit_optional_type`, `zir_builder_emit_is_non_null`, `zir_builder_emit_optional_payload`, `zir_builder_emit_orelse`
- `zir_builder_emit_try`, `zir_builder_emit_catch`, `zir_builder_emit_error_union_type`, `zir_builder_emit_ret_error`

All instruction-emitting functions return a `u32` reference (ZIR instruction index). The error sentinel is `0xFFFFFFFF`.

### How Native Calls Are Routed

When Zap code calls `:zig.Struct.function(args)`, the ZIR builder:

1. Emits `@import("zap_runtime")` → gets the runtime struct reference
2. Maps the Zap struct name to a runtime struct name (e.g., `IO` → `Prelude`, `Math` → `Prelude`, `List` → `List`)
3. Emits `.RuntimeStruct` field access → gets the struct reference
4. Emits `.function` field access → gets the function reference
5. Emits a call with the resolved function and argument references

The result in ZIR is equivalent to: `@import("zap_runtime").Prelude.println(message)`.

### What the Fork Contains

The Zig fork is based on Zig 0.16.0 with surgical patches:

- `src/zir_api.zig` — the C-ABI surface (53+ functions for ZIR instruction building)
- Patches to `zig_clang_driver.cpp`, `zig_clang_cc1_main.cpp`, `zig_clang_cc1as_main.cpp`, `zig_llvm-ar.cpp` — adapting entry points
- Build configuration to produce `libzap_compiler.a` as a static library

The fork links mandatory LLVM targets including: AArch64, **AMDGPU**, ARM, **NVPTX**, **SPIRV**, X86, WebAssembly, and others. All three GPU backends are compiled into every Zap distribution.

---

## 5. Runtime Architecture

### Embedded Runtime

`src/runtime.zig` is embedded into the compiler via `@embedFile("runtime.zig")` and injected as an in-memory Zig struct during compilation via `zir_compilation_add_struct_source()`. This means runtime functions are compiled alongside user code — no separate runtime library.

### Core Runtime Types

**ARC (Atomic Reference Counting):**
```zig
pub const ArcHeader = struct {
    ref_count: std.atomic.Value(u32),
    pub fn retain(self: *ArcHeader) void { ... }
    pub fn release(self: *ArcHeader) bool { ... }
};

pub fn Arc(comptime T: type) type { ... }
// Generic wrapper: { header: ArcHeader, value: T }
// Thread-safe lock-free reference semantics
```

**Atom (Interned values):**
```zig
pub const Atom = struct {
    id: u32,
    // Pre-defined: nil=0, true=1, false=2, ok=3, error=4
};
// Global atom table with intern/lookup
```

**Closure (Function values):**
```zig
pub fn Closure(comptime Args: type, comptime Ret: type) type { ... }
// Fat pointer: (function pointer, environment)

pub const DynClosure = struct {
    call_fn: *const anyopaque,    // Type-erased function pointer
    env: ?*anyopaque,             // Captured environment
    env_release: ?*const fn (*anyopaque) void,
};
// Used when function values cross runtime boundaries
```

**PersistentList (Immutable singly-linked list):**
```zig
pub fn PersistentList(comptime T: type) type { ... }
// Cons-cell based, structural sharing
// Operations: cons, hd, tl, length, toSlice, fromSlice
```

**ZapMap (Persistent sorted-array map):**
```zig
pub fn ZapMap(comptime K: type, comptime V: type) type { ... }
// Copy-on-write sorted array
// Operations: get, put, delete, keys, values, size
```

**TaggedValue (Runtime tagged union):**
```zig
pub const TaggedValue = union(enum) {
    int: i64, float: f64, bool_val: bool, atom: Atom,
    string: []const u8, nil: void, tuple: []const TaggedValue,
    list: *const PersistentList(TaggedValue), closure: DynClosure,
};
```

**Memory model:** Arena-based allocation backed by page allocator. All persistent data structures are immutable — mutations return new copies with structural sharing.

---

## 6. The `use` / `__using__` Pattern

This is a central mechanism in Zap, directly inspired by Elixir's `use` macro. It enables struct composition and DSL creation.

### How It Works

When you write `use SomeStruct` inside a struct body, the compiler:

1. Imports `SomeStruct`
2. Calls `SomeStruct.__using__/1` (a macro) with any options provided
3. Injects the returned AST into the calling struct

### Existing Example: Zest Test Framework

The test framework uses this pattern:

```zap
# lib/zest/case.zap
pub struct Zest.Case {
  pub macro __using__(_opts :: Expr) -> Expr {
    quote {
      import Zest.Case
    }
  }

  pub macro describe(_name :: Expr, body :: Expr) -> Expr {
    _setup_body = find_setup(body)
    _teardown_body = find_teardown(body)
    build_test_fns(_name, body, _setup_body, _teardown_body)
  }

  pub macro test(_name :: Expr, body :: Expr) -> Expr {
    build_test_fn(_name, body)
  }

  pub fn assert(value :: Bool) -> String { ... }
  pub fn reject(value :: Bool) -> String { ... }
}
```

Used in test structs:

```zap
# test/closure_test.zap
pub struct Test.ClosureTest {
  use Zest.Case

  describe("closures") {
    test("apply doubles value") {
      assert(apply(21, doubler) == 42)
    }
  }
}
```

### Key Properties

- `__using__` is a **macro** — it runs at compile time during macro expansion
- It receives options as an AST expression (e.g., `backend: Math.CUDA`)
- It returns an AST expression that gets injected into the calling struct
- This is all Zap code — the compiler has no special knowledge of `__using__` beyond knowing to call it during `use` expansion
- `__using__` can inject imports, function definitions, struct attributes, or any other valid AST

### How Options Work

The `use` statement can pass options:

```zap
use Greeter                          # No options → __using__ receives empty opts
use Zest.Case                        # No options
use Math, backend: Math.CUDA         # Keyword option → __using__ receives keyword list
```

The `__using__` macro receives these options as an AST expression and can inspect them at compile time to determine what to inject.

---

## 7. Protocol System

Zap has a protocol system similar to Elixir protocols or Rust traits. It enables polymorphic dispatch.

### Protocol Declaration

```zap
# lib/enumerable.zap
pub protocol Enumerable {
  fn reduce(collection, accumulator, callback :: (accumulator, member -> {Atom, accumulator})) -> {Atom, accumulator}
}
```

This declares a contract: any type that implements `Enumerable` must provide a `reduce` function with this signature.

### Implementation

```zap
impl Enumerable for List {
  pub fn reduce(list, accumulator, callback) {
    # ... implementation for lists
  }
}
```

### AST Representation

Protocols and implementations are first-class AST nodes:

```zig
// src/ast.zig
pub const ProtocolDecl = struct {
    meta: NodeMeta,
    name: StructName,
    functions: []const ProtocolFunctionSig,
    is_private: bool,
};

pub const ImplDecl = struct {
    meta: NodeMeta,
    protocol_name: StructName,
    target_type: StructName,
    functions: []const *const FunctionDecl,
    is_private: bool,
};
```

Both `protocol` and `impl` are variants in the `TopItem` union, meaning they're first-class struct-level declarations.

---

## 8. Dependency System

### Build Manifest

Every Zap project has a `build.zap` that defines build targets:

```zap
pub struct MyApp.Builder {
  pub fn manifest(env :: Zap.Env) -> Zap.Manifest {
    case env.target {
      :my_app ->
        %Zap.Manifest{
          name: "my_app",
          version: "0.1.0",
          kind: :bin,
          root: "MyApp.main/0",
          deps: [
            {:math_webgpu, {:git, "https://github.com/zaplang/math_webgpu.zap", "v0.1.0"}}
          ]
        }
    }
  }
}
```

### Dependency Sources

| Source type | Format                             | Description            |
|------------|-------------------------------------|------------------------|
| Path       | `{:name, {:path, "dir"}}`          | Local Zap library      |
| Git        | `{:name, {:git, "url", "ref"}}`    | Remote Zap library     |

Dependencies are first-class — their structs are available directly. The compiler discovers dependency structs the same way it discovers project structs (by following imports from the entry point).

A `zap.lock` lockfile records resolved versions for reproducible builds.

### Zig-Level Dependencies

Since Zap compiles through Zig, backend packages that include Zig runtime code also need entries in `build.zig.zon` (Zig's package manifest). This means GPU backend packages are both Zap dependencies (for the `.zap` struct files) and Zig dependencies (for the `.zig` runtime files).

Current `build.zig.zon` has no dependencies — it's a blank slate:

```zon
.{
    .name = .zap,
    .version = "0.0.0",
    .minimum_zig_version = "0.16.0",
    .dependencies = .{},
}
```

---

## 9. Existing Standard Library

### Current Math Struct

The existing `Math` struct is a thin wrapper around Zig's hardware-accelerated builtins:

```zap
# lib/math.zap
pub struct Math {
  @doc = """
    Mathematical functions for floating-point computation.
    Provides trigonometric, exponential, logarithmic, and other
    mathematical operations on f64 values.
    """

  pub fn pi() -> f64 { 3.141592653589793 }
  pub fn e() -> f64 { 2.718281828459045 }
  pub fn sqrt(value :: f64) -> f64 { :zig.Math.sqrt_f64(value) }
  pub fn sin(value :: f64) -> f64 { :zig.Math.sin_f64(value) }
  pub fn cos(value :: f64) -> f64 { :zig.Math.cos_f64(value) }
  pub fn tan(value :: f64) -> f64 { :zig.Math.tan_f64(value) }
  pub fn exp(value :: f64) -> f64 { :zig.Math.exp_f64(value) }
  pub fn exp2(value :: f64) -> f64 { :zig.Math.exp2_f64(value) }
  pub fn log(value :: f64) -> f64 { :zig.Math.log_f64(value) }
  pub fn log2(value :: f64) -> f64 { :zig.Math.log2_f64(value) }
  pub fn log10(value :: f64) -> f64 { :zig.Math.log10_f64(value) }
}
```

Every function delegates to `:zig.Math.*` which routes to `@import("zap_runtime").Prelude.*` at the ZIR level. The `Prelude` struct in `runtime.zig` provides the actual Zig implementations calling `@sqrt`, `@sin`, `@cos`, etc.

### Other Standard Library Structs

| Struct     | Purpose                                                    |
|------------|------------------------------------------------------------|
| `Kernel`   | Core macros: `if`, `unless`, `and`, `or`, `\|>`, sigils, `fn`, `struct`, `union`, `raise`, `sleep` |
| `IO`       | Console I/O: `puts`, `gets`, `write`, `mode`               |
| `String`   | String operations: `length`, `slice`, `contains`, `trim`, `upcase`, `downcase`, `reverse`, `replace`, etc. |
| `Integer`  | Integer operations: `to_string`, `abs`, `max`, `min`, `parse`, `pow`, `clamp`, `digits`, etc. |
| `Float`    | Float operations: `to_string`, `abs`, `round`, `floor`, `ceil`, `truncate`, etc. |
| `Bool`     | `to_string`, `negate`                                      |
| `Atom`     | `to_string`                                                |
| `List`     | List operations: `empty?`, `length`, `head`, `tail`, `at`, `reverse`, `prepend`, `append`, `concat`, etc. |
| `Map`      | Map operations via `%{}` syntax                            |
| `Enum`     | Higher-order functions: `map`, `filter`, `reject`, `reduce`, `each`, `find`, `any?`, `all?`, `sort`, `flat_map`, etc. |
| `File`     | File system operations                                     |
| `Path`     | Path manipulation                                          |
| `System`   | OS-level operations (args, env, exit)                      |
| `Zest`     | Test framework: `assert`, `reject`                         |
| `Zest.Case`| Test DSL: `describe`, `test`, `setup`, `teardown`          |
| `Zest.Runner` | Test runner with summary output                         |
| `Function` | Function utilities                                         |
| `Enumerable` | Protocol for enumerable collections                     |

### How Library Functions Call Into Zig

Every standard library function that needs hardware access uses the `:zig.Struct.function()` pattern:

```zap
# In Zap code:
:zig.IO.println(message)

# Becomes in ZIR:
@import("zap_runtime").Prelude.println(message)
```

The ZIR builder maps struct names to runtime struct names:
- `IO`, `Math`, `Integer`, `Float`, `Bool`, `Atom`, `File`, `System`, `Path` → all map to `Prelude`
- `List` → `List`
- `Map` → `MapAtomInt` (or variant-specific based on key/value types)
- `String` → `String`
- `Zest` → `Zest`
- `Kernel` → `Kernel`

---

## 10. GPU Computing Design

### Design Goals

1. **Numerical library with the same depth as Nx and PyTorch** — tensor operations, linear algebra, neural network primitives, autograd, FFT, sparse operations (~150-200 operations total)
2. **Backend adapter pattern via `use Math, backend: Struct`** — the `Math` struct defines the API, backends provide the implementation
3. **Backends are external dependencies, not built into the core** — the core ships `Math` + `Math.Backend` protocol + `Math.CPU` default; GPU backends are separate packages users opt into
4. **Everything possible is Zap code** — the compiler knows nothing about tensors, GPU, or numerical computing

### Architecture Overview

```
Core (ships with Zap stdlib):
  Math           — public API, __using__ macro, Tensor type
  Math.Backend   — protocol defining the contract
  Math.CPU       — default backend, zero external dependencies

Separate packages (user opts in via deps):
  math_cuda      — Math.CUDA backend wrapping cuBLAS/cuDNN
  math_webgpu    — Math.WebGPU backend via wgpu-native/Dawn
  math_vulkan    — Math.Vulkan backend via Vulkan compute + SPIR-V
  math_xla       — Math.XLA backend via PJRT/OpenXLA
  math_metal     — Math.Metal backend for Apple Silicon
```

### The `use Math, backend: Struct` Pattern

```zap
pub struct Math {
  @doc """
  Numerical computing library with pluggable backends.
  """

  pub macro __using__(opts :: Expr) -> Expr {
    _backend = Keyword.get(opts, :backend, Math.CPU)
    quote {
      import Math
      @math_backend unquote(_backend)
    }
  }

  # Every public function dispatches to the configured backend
  pub fn add(left :: Tensor, right :: Tensor) -> Tensor {
    @math_backend.add(left, right)
  }

  pub fn matmul(left :: Tensor, right :: Tensor) -> Tensor {
    @math_backend.matmul(left, right)
  }

  pub fn relu(tensor :: Tensor) -> Tensor {
    @math_backend.relu(tensor)
  }

  # ... all operations delegate to @math_backend
}
```

### The Backend Protocol

```zap
pub protocol Math.Backend {
  # Tensor creation
  fn tensor(data, shape, dtype) -> Tensor
  fn zeros(shape, dtype) -> Tensor
  fn ones(shape, dtype) -> Tensor
  fn random_uniform(shape, dtype) -> Tensor
  fn random_normal(shape, dtype) -> Tensor

  # Element-wise arithmetic
  fn add(left :: Tensor, right :: Tensor) -> Tensor
  fn subtract(left :: Tensor, right :: Tensor) -> Tensor
  fn multiply(left :: Tensor, right :: Tensor) -> Tensor
  fn divide(left :: Tensor, right :: Tensor) -> Tensor
  fn negate(tensor :: Tensor) -> Tensor

  # Element-wise math
  fn exp(tensor :: Tensor) -> Tensor
  fn log(tensor :: Tensor) -> Tensor
  fn sqrt(tensor :: Tensor) -> Tensor
  fn tanh(tensor :: Tensor) -> Tensor
  fn sigmoid(tensor :: Tensor) -> Tensor
  fn relu(tensor :: Tensor) -> Tensor

  # Reductions
  fn sum(tensor :: Tensor, axes) -> Tensor
  fn mean(tensor :: Tensor, axes) -> Tensor
  fn max(tensor :: Tensor, axes) -> Tensor
  fn argmax(tensor :: Tensor, axis) -> Tensor

  # Linear algebra
  fn dot(left :: Tensor, right :: Tensor) -> Tensor
  fn matmul(left :: Tensor, right :: Tensor) -> Tensor
  fn transpose(tensor :: Tensor, axes) -> Tensor

  # Shape operations
  fn reshape(tensor :: Tensor, shape) -> Tensor
  fn broadcast(tensor :: Tensor, shape) -> Tensor
  fn concatenate(tensors, axis) -> Tensor
  fn slice(tensor :: Tensor, starts, lengths) -> Tensor

  # Device management
  fn to_device(tensor :: Tensor, device) -> Tensor
  fn to_host(tensor :: Tensor) -> Tensor
}
```

### Backend Implementation Example

```zap
# In the math_webgpu package:
pub struct Math.WebGPU {
  impl Math.Backend {
    pub fn add(left :: Tensor, right :: Tensor) -> Tensor {
      :zig.WebGPU.elementwise_add(left, right)
    }

    pub fn matmul(left :: Tensor, right :: Tensor) -> Tensor {
      :zig.WebGPU.matmul(left, right)
    }

    pub fn relu(tensor :: Tensor) -> Tensor {
      :zig.WebGPU.elementwise_relu(tensor)
    }

    # ... each operation delegates to Zig runtime code that
    # manages WebGPU compute pipelines and dispatch
  }
}
```

### User Experience

```zap
pub struct ImageClassifier {
  use Math, backend: Math.WebGPU

  pub fn forward(params, image :: Tensor) -> Tensor {
    image
    |> Math.conv2d(params.conv1_weights, padding: :same)
    |> Math.relu()
    |> Math.max_pool({2, 2}, {2, 2})
    |> Math.conv2d(params.conv2_weights, padding: :same)
    |> Math.relu()
    |> Math.reshape({-1})
    |> Math.matmul(params.fc_weights)
    |> Math.add(params.fc_bias)
    |> Math.softmax(axis: -1)
  end
}
```

Swap `Math.WebGPU` for `Math.CUDA` or `Math.CPU` — same code, different hardware.

### Backend Tiers

A backend can implement a subset and still be useful:

**Tier 1 — Core (~40 ops, minimum viable backend):**
Creation, element-wise arithmetic, element-wise math, basic reductions, matmul/dot/transpose, reshape/broadcast/slice, device management.

**Tier 2 — Full numerical library (~60 more ops):**
Full trig/hyperbolic/rounding, comparison/clamp/where, full linear algebra (solve, det, inv, SVD, eig, Cholesky, QR, norm), advanced shape ops (stack, split, gather, scatter, pad), sorting, FFT.

**Tier 3 — Neural network / advanced (~40 more ops):**
Convolution (1d/2d/3d), pooling, normalization (batch/layer/group), attention, autograd (grad, value_and_grad), sparse operations.

### The Zig Runtime Layer

Each backend package includes Zig runtime code that handles the actual hardware interface. The `:zig.` calls in the Zap backend struct land in these Zig functions.

| Backend        | Zig runtime wraps                        |
|----------------|------------------------------------------|
| `Math.CPU`     | SIMD vectorized loops, BLAS (OpenBLAS/Accelerate) |
| `Math.CUDA`    | cuBLAS, cuDNN, cuFFT, custom PTX kernels |
| `Math.WebGPU`  | wgpu-native or Dawn (WebGPU implementation) |
| `Math.Vulkan`  | Vulkan compute pipelines, SPIR-V shaders |
| `Math.XLA`     | PJRT / OpenXLA runtime                   |
| `Math.Metal`   | Metal Performance Shaders                |

For example, `Math.WebGPU`'s Zig runtime would:
1. Manage a `wgpu.Device` and compute queue
2. Maintain a cache of compiled compute pipelines (WGSL shaders → pipeline state objects)
3. Handle buffer allocation on GPU, data transfers, and synchronization
4. Dispatch compute shaders for each Math operation

WGSL compute shaders ship inside the backend package's Zig code.

### Key Design Properties

**Compile-time dispatch:** Because `@math_backend` is resolved during macro expansion, the backend is known at compile time. The compiler can inline and optimize away the dispatch entirely. There is no runtime overhead from the adapter pattern.

**No compiler changes needed:** The entire Math system — Tensor type, protocol, backends, `__using__` macro — is Zap and Zig code. The compiler remains a general-purpose tool with no knowledge of numerical computing.

**Cross-vendor from day one:** The backend abstraction means the same user code runs on any GPU vendor. The `Math.WebGPU` backend covers NVIDIA, AMD, Intel, and Apple Silicon through a single package.

---

## 11. Research Questions

The following questions need deep investigation:

### Tensor Type Design

1. **What should the `Tensor` type look like at the Zig runtime level?** It needs: multi-dimensional shape, strides, dtype (f16/f32/f64/i32/i64/bool), device tag (CPU/GPU), and a data pointer. How should this be represented for zero-copy device transfers?

2. **How should Tensor memory management work with Zap's ARC?** Tensors on GPU memory can't use the normal ARC header (which lives in CPU memory). Should GPU tensors use a separate reference counting scheme? How do other systems handle this?

3. **What dtypes should be supported?** Minimum: f16, f32, f64, i32, i64, bool. Desirable: bf16, i8, u8, complex64, complex128. What does PyTorch support that we should match?

### WebGPU Backend

4. **What is the best WebGPU implementation to use from Zig?** Options include zgpu (zig-gamedev, built on Dawn), wgpu-native bindings, or direct Vulkan. What are the tradeoffs for a compute-focused use case (not graphics)?

5. **How should compute shaders be organized?** One WGSL shader per operation? Fused shaders for common patterns? How do we handle dtype polymorphism in WGSL (f32 vs f64 vs i32)?

6. **What are WebGPU's limitations for numerical computing?** Max buffer sizes, workgroup limits, lack of f64 support in some implementations, no dynamic shared memory. How do these constrain the design?

7. **Can WebGPU achieve competitive performance with CUDA for common operations?** What benchmarks exist? Where are the gaps?

### CUDA Backend

8. **What is the best way to call cuBLAS/cuDNN from Zig?** The zCUDA project provides bindings. Are they production quality? What's the alternative?

9. **Should we use CUDA runtime API or driver API?** Driver API is more flexible but more complex. What do production systems use?

10. **How should we handle kernel fusion?** Calling cuBLAS then cuDNN means separate kernel launches with memory round-trips. How do PyTorch, JAX, and TVM handle fusion? Is there a library we can leverage?

### XLA/PJRT Backend

11. **How does PJRT work and can it be called from Zig?** ZML (a Zig-based AI inference stack) already uses PJRT. How does their integration work? Can we reuse their approach?

12. **What does XLA give us that individual library calls don't?** Automatic kernel fusion, memory planning, cross-device support. How significant are the performance gains?

### Cross-Cutting Concerns

13. **How should data transfer between CPU and GPU work?** Explicit (user calls `to_device`/`to_host`), implicit (backend handles it), or tracked in the type system (separate `GPUTensor` vs `Tensor` types)?

14. **How should device selection work?** Per-struct via `use Math, backend: Math.WebGPU`? Per-call? Global default with override? What about multi-GPU?

15. **Is kernel fusion possible at the Zap compiler level?** Since Zap sees the entire function at compile time (AOT), could the compiler detect chains of tensor operations and fuse them into a single GPU kernel? This is what makes XLA and TVM competitive. Could Zap do this without an external runtime?

16. **How should autograd work?** Tape-based (PyTorch), source-to-source transformation (JAX), or expression graph (Nx)? Which approach fits Zap's AOT, functional nature best?

17. **What does the Tensor creation API look like in Zap?** How do users specify shape, dtype, and initial values using Zap's syntax (lists, tuples, maps)?

18. **How does Zig's native SPIR-V compilation fit into this?** Zig can compile `.zig` directly to SPIR-V bytecode. Could Zap GPU kernels be written as Zap functions that compile to SPIR-V via the existing pipeline? This would be the "Zap-native GPU kernel" story for advanced users.

### Competitive Analysis

19. **What does Elixir Nx's operation coverage look like in detail?** Full operation list, signatures, and behavior. This is the depth we want to match.

20. **What does PyTorch's `torch` struct cover that Nx doesn't?** Sparse operations, quantization, distributed, custom autograd functions. Which of these matter for Zap?

21. **How do Mojo and Julia approach the same problem?** Both are LLVM-based languages with GPU support. What can we learn from their architecture without copying their design?

---

## Appendix: Zig GPU Capabilities

Zig already has native GPU compilation targets built into the compiler:

- **SPIR-V** (Vulkan/OpenCL) — most mature path. Self-hosted backend passes ~50% Vulkan / ~75% OpenCL behavior tests. Default backend (not LLVM).
- **NVPTX** (NVIDIA PTX) — Tier 4 support via LLVM. Basic kernel compilation works but special register intrinsics need workarounds.
- **AMDGCN** (AMD GPUs) — works via LLVM for AMD GCN machine code usable with ROCm.

Zig has `callconv(.kernel)` for GPU entry points and `std.gpu` with compute primitives (`workgroup_id`, `global_invocation_id`, etc.).

**SPIR-V is becoming the universal GPU interchange format** — Microsoft announced DirectX will adopt SPIR-V for Shader Model 7+, meaning it will cover Vulkan, OpenCL, and DirectX. Zig's long-term plan is to drop LLVM entirely in favor of self-hosted backends, and SPIR-V is already on that path.

**Key Zig GPU projects:**
- **ZML** (zml.ai) — production AI inference stack, 92.7% Zig, uses MLIR/OpenXLA/PJRT. Claims 2x faster than TensorRT-LLM on H100.
- **zgpu** (zig-gamedev) — cross-platform graphics/compute on Dawn/WebGPU
- **zCUDA** — type-safe Zig bindings for CUDA driver API, cuBLAS, cuDNN, cuFFT, plus a kernel DSL that compiles Zig to PTX
- **Mach Engine** — game engine with compile-time WebGPU interface
- **opencl-zig** — hand-written OpenCL bindings for Zig

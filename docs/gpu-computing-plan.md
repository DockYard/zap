# Zap GPU Computing — Comprehensive Plan

> This document captures every design decision, architectural rationale, and implementation detail for GPU-accelerated numerical computing in Zap. It is the authoritative reference for all GPU work.

---

## Table of Contents

1. [Background and Motivation](#1-background-and-motivation)
2. [Zap Architecture Context](#2-zap-architecture-context)
3. [Design Principles](#3-design-principles)
4. [Design Decisions](#4-design-decisions)
5. [Architecture Overview](#5-architecture-overview)
6. [Tensor Type](#6-tensor-type)
7. [The Math API](#7-the-math-api)
8. [The Backend Protocol](#8-the-backend-protocol)
9. [Backend Packages](#9-backend-packages)
10. [Backend-Specific APIs](#10-backend-specific-apis)
11. [Device Functions (`dfn`)](#11-device-functions-dfn)
12. [Autograd — Functional Trace-and-Replay](#12-autograd--functional-trace-and-replay)
13. [Interaction with Perceus and ARC](#13-interaction-with-perceus-and-arc)
14. [Fusion Strategy](#14-fusion-strategy)
15. [Device Placement and Data Transfer](#15-device-placement-and-data-transfer)
16. [Execution Model](#16-execution-model)
17. [Operation Coverage](#17-operation-coverage)
18. [Testing Strategy](#18-testing-strategy)
19. [Tooling and Profiling](#19-tooling-and-profiling)
20. [Packaging and Distribution](#20-packaging-and-distribution)
21. [Phased Roadmap](#21-phased-roadmap)
22. [What This Preserves](#22-what-this-preserves)

---

## 1. Background and Motivation

Zap is a general-purpose functional programming language that compiles to native binaries via LLVM. It takes the developer experience of Elixir — pattern matching, pipe operators, algebraic types, macros — and strips away the runtime overhead. No VM, no garbage collector, no interpreter.

GPU-accelerated numerical computing is a natural extension for Zap. The goal is to provide a numerical computing library with the same depth as Elixir's Nx and PyTorch, while maintaining Zap's core identity: features implemented in Zap code, not hardcoded in the compiler.

### Why not copy Nx?

Elixir's Nx uses a global default backend model and a `defn` macro that traces tensor operations into a computation graph at runtime. Zap's approach differs in three ways:

1. **Per-module backend selection via `use Math, backend: Module`** — the backend is a compile-time property of the module, not a global runtime setting. This gives zero-overhead dispatch.
2. **Backends as external dependencies** — the core Zap stdlib ships only `Math`, `Math.Backend`, and `Math.CPU`. GPU backends are separate packages users opt into.
3. **Functional trace-and-replay for autograd** — Zap's purity and immutability mean the execution trace IS the computation graph. No mutable tape, no special tracing mode.

### Why not wrap CUDA directly?

Wrapping CUDA alone locks Zap to NVIDIA hardware and prevents kernel fusion (separate library calls mean separate kernel launches with memory round-trips between them). Instead, Zap uses a **backend adapter pattern** where each GPU vendor gets its own optimized backend, and a portable WebGPU backend provides cross-vendor coverage.

---

## 2. Zap Architecture Context

Understanding how GPU support fits into Zap requires understanding Zap's compilation pipeline and runtime model.

### Compilation Pipeline

```
.zap source files
    → Discovery (follow module references from entry point)
    → Parse (per-file ASTs)
    → Collect (shared scope graph + type store)
    → Macro Expansion (AST → AST transforms via Kernel macros)
    → Desugar (simplify syntax sugar)
    → Type Check (overload resolution + type inference)
    → HIR Lowering (typed intermediate representation)
    → Monomorphize (specialize generics for concrete types)
    → IR Lowering (explicit control flow, locals, ARC ops)
    → Analysis (escape analysis, regions, lambda sets, Perceus)
    → Per-Module ZIR Emission (each Zap module → Zig ZIR module)
    → Codegen (Zig compiler → LLVM → native binary)
```

Key properties:
- **AOT compiled** — no JIT, no interpreter, no runtime compilation
- **Per-module ZIR emission** — each Zap module becomes its own Zig ZIR module
- **Cross-module calls** use `@import("Module").function(args)` chains in ZIR
- **Native runtime calls** (`:zig.Module.function()`) become `@import("zap_runtime").RuntimeModule.function()` chains

### The Zig Fork

Zap depends on a fork of Zig 0.16.0 maintained by DockYard. The fork adds a C-ABI surface (`src/zir_api.zig`) with 80+ functions for building ZIR programs. The fork is compiled into a static library `libzap_compiler.a` (~341MB with LLVM 20) that is linked into the Zap binary.

The fork's LLVM build includes mandatory GPU-relevant targets: **NVPTX** (NVIDIA PTX), **AMDGPU** (AMD GCN), and **SPIRV** (SPIR-V). These are already compiled into every Zap distribution.

### Runtime Model

- **Atomic Reference Counting (ARC)** — no garbage collector. `ArcHeader` with atomic `u32` refcount.
- **Perceus optimization** — the analysis pipeline detects when refcounts are 1 and enables in-place memory reuse. This is a key performance optimization.
- **Persistent data structures** — `PersistentList` (cons-cell, structural sharing), `ZapMap` (copy-on-write sorted array). All immutable.
- **Arena allocation** — bump allocator backed by page allocator.
- **Embedded runtime** — `src/runtime.zig` is embedded via `@embedFile` and injected as an in-memory Zig module during compilation.

### The `use` / `__using__` Pattern

When you write `use SomeModule` inside a module body:
1. The compiler imports `SomeModule`
2. Calls `SomeModule.__using__/1` (a macro) with any options
3. Injects the returned AST into the calling module

This is already used by `Zest.Case` (the test framework). It is the mechanism through which GPU backends wire themselves into user modules.

### Protocol System

Zap has protocols (like Elixir protocols or Rust traits):

```zap
pub protocol Enumerable {
  fn reduce(collection, accumulator, callback) -> {Atom, accumulator}
}
```

Protocols are first-class AST nodes (`ProtocolDecl`, `ImplDecl`). They enable polymorphic dispatch across types.

### Dependency System

Zap dependencies are declared in `build.zap`:

```zap
deps: [
  {:math_webgpu, {:git, "https://github.com/zaplang/math_webgpu.zap", "v0.1.0"}}
]
```

Dependencies that include Zig runtime code also need entries in `build.zig.zon` (Zig's package manifest). GPU backend packages are both Zap dependencies (for `.zap` module files) and Zig dependencies (for `.zig` runtime files).

---

## 3. Design Principles

These principles guided every decision in this plan:

1. **Features in Zap code, not the compiler.** The compiler knows nothing about Math, tensors, GPU, or numerical computing. Everything is implemented as Zap modules, protocols, macros, and Zig runtime primitives.

2. **No hardcoded module names in the compiler.** The compiler is a general-purpose tool. Backend packages are regular Zap dependencies.

3. **No workarounds, hacks, or shortcuts.** Every backend is the correct, production-grade implementation for its hardware. No lowest-common-denominator abstractions that sacrifice performance.

4. **Backends as dependencies, not built-in.** The core ships `Math.CPU`. GPU backends are opt-in packages. This controls maintenance burden, isolates licensing/SDK concerns, and lets backends evolve independently.

5. **Compile-time backend resolution.** Because `@math_backend` is set during macro expansion, the backend is known at compile time. Dispatch is inlined away — zero runtime overhead from the adapter pattern.

6. **Explicit over implicit.** Device placement is explicit (`to_device`/`to_host`). No transparent unified memory. No silent data transfers. Predictable performance.

7. **Leverage functional purity.** Zap's immutability and referential transparency make the execution trace a correct computation graph by construction. Autograd, time-travel debugging, and profiling all fall out naturally.

---

## 4. Design Decisions

Eight decisions were evaluated against Zap's architecture, deep research findings, and the principles above.

### Decision 1: Dawn (not wgpu-native) for WebGPU

**Choice:** Use Google's Dawn as the WebGPU implementation.

**Rationale:** Dawn implements `webgpu.h` as a C API — clean FFI from Zig with no Rust toolchain dependency. It maps to D3D12 (Windows), Metal (macOS), Vulkan (Linux), and OpenGL. zgpu (zig-gamedev) already proves Dawn packaging works for Zig across all three desktop platforms. wgpu-native (Rust's wgpu exposed via C API) would require a Rust build toolchain in the dependency chain.

### Decision 2: Fusion lives in backend packages, not the compiler

**Choice:** Each backend owns its own optimization and fusion strategy. The compiler sees normal function calls.

**Rationale:** The WebGPU backend needs to fuse elementwise chains to overcome dispatch overhead (research shows WebGPU reaches only 11-12% of CUDA throughput on fine-grained workloads). The CUDA backend needs to route matmul to cuBLAS but fuse surrounding elementwise ops. These are fundamentally different strategies. Putting fusion in the compiler would mean the compiler knows about GPU optimization — violating "features in Zap code, not the compiler." Each backend implements fusion in its Zig runtime code.

### Decision 3: Synchronous execution first; async waits on Zap's concurrency story

**Choice:** All GPU operations are synchronous in Phase 1-3. Async execution (streams, queues, overlapping compute/transfer) will be designed around Zap's own concurrency primitives once they exist.

**Rationale:** Zap currently has no async primitives — no processes, no futures, no async/await. Designing a GPU-specific async model risks conflicting with Zap's eventual concurrency story. Better to ship synchronous first and add async when the language has its own concurrency foundation.

### Decision 4: `dfn` (device function) via backend-provided macro

**Choice:** `dfn` is a macro injected by the backend's `__using__` macro. It is not compiler syntax.

**Rationale:** A device function needs to know its target — PTX for CUDA, WGSL for WebGPU, SPIR-V for Vulkan. If `dfn` were compiler syntax, the compiler would need to know which backend is active — violating "the compiler knows nothing about specific modules." Instead, each backend provides its own `dfn` macro that handles lowering to the appropriate target. `Math.CUDA`'s `dfn` compiles to PTX. `Math.WebGPU`'s `dfn` emits WGSL. No compiler changes needed.

**Why `dfn` and not `pub device fn` or `@device`:** The name `dfn` stands for "device function." It was chosen over `pub device fn` (which would be a decorator on `fn` requiring the compiler to know about devices) and `@device` (which would also require compiler knowledge). Since `dfn` is just a macro name provided by the backend, it needs no language-level support at all.

**Why not other `d` variants:** Only `dfn` is needed. `dmacro` makes no sense (macros are compile-time, they don't run on devices). `dprotocol` makes no sense (protocols require dynamic dispatch, which is incompatible with GPU execution). `dstruct` is unnecessary — regular Zap structs with device-compatible fields already work inside `dfn`; the backend's macro validates compatibility at the usage site.

### Decision 5: Include a Vulkan backend for maximum portability

**Choice:** Ship a `math_vulkan` backend alongside `math_webgpu`.

**Rationale:** Users with existing Vulkan compute pipelines or SPIR-V shaders shouldn't have to port to WebGPU to use Zap's Math. A Vulkan backend provides direct Vulkan compute access, SPIR-V shader loading, and interop with existing Vulkan codebases. This gives Zap the widest possible hardware coverage and removes a reason for potential users to choose against adopting Zap.

### Decision 6: ROCm as its own backend, separate from CUDA

**Choice:** `math_rocm` is a separate package from `math_cuda`.

**Rationale:** HIP is intentionally close to CUDA at the API level, but the library ecosystems differ: rocBLAS vs cuBLAS, MIOpen vs cuDNN, different graph API maturity, different autotuning strategies. Hiding these behind a single backend would create a lowest-common-denominator trap where neither NVIDIA nor AMD hardware is used optimally. Separate packages let each backend optimize fully for its hardware. The shared contract is the `Math.Backend` protocol at the Zap level.

### Decision 7: Autograd via functional trace-and-replay

**Choice:** Autograd records operations as an immutable event log during the forward pass, then walks the log backward applying the chain rule via registered VJP (vector-Jacobian product) rules.

**Rationale:** This decision was driven by a key insight about functional programming. In Elm, the time-travel debugger works because every state transition is a pure function applied to an immutable value — you can record the inputs and replay the computation deterministically. Zap shares these properties: purity, immutability, no unmanaged side effects. This means the execution trace of a numerical computation IS the computation graph that reverse-mode automatic differentiation needs. You don't need to build a separate "tape" (like PyTorch) or trace through abstract values (like JAX) — the call trace IS the tape, and it's correct by construction because the language guarantees referential transparency. The trace is just an immutable list of `{operation, inputs, output}` tuples. The VJP rules are defined in Zap library code. No compiler changes, no mutable state.

**Comparison with alternatives:**

| Approach | How it works | Fits Zap? |
|----------|-------------|-----------|
| **Tape-based (PyTorch)** | Mutable tape built via side effects during forward pass. In-place ops can invalidate tape. | No — mutation conflicts with Zap's immutability |
| **Tracing (JAX)** | Pass abstract tracer values through pure functions to extract computation graph. | Possible but unnecessary — Zap already has the graph via its call trace |
| **Source-to-source (Zygote/Swift)** | Compiler transforms function IR to generate backward pass at compile time. | Possible but requires compiler changes |
| **Functional trace-and-replay** | Record pure function calls as immutable event log. Walk backward with chain rule. | Natural fit — exploits Zap's existing purity and immutability |

### Decision 8: Explicit device placement

**Choice:** Users control when data moves between CPU and GPU via explicit `Math.to_device` and `Math.to_host` calls. Operations on tensors from different devices without explicit transfer produce errors, not silent copies.

**Rationale:** Transparent unified memory (CUDA Unified Memory) makes performance unpredictable — silent page faults in GPU kernels can tank throughput with no user visibility. Explicit placement is what WebGPU's adapter/device model expects, what HIP's runtime model expects, and what production ML frameworks (PyTorch, JAX) converged on after experimenting with implicit approaches. The research reinforces this direction.

---

## 5. Architecture Overview

### Three Layers

```
Layer 1: Zap API (lib/*.zap — pure Zap code)
  Math module          — public API, __using__ macro
  Math.Backend         — protocol contract
  Tensor type          — shape, dtype, device, data handle
  Math.CPU             — default backend, zero external dependencies
  Math.VJP             — autograd backward rules

Layer 2: Backend Packages (separate deps — Zap + Zig code)
  math_webgpu          — Dawn/webgpu.h, WGSL compute shaders
  math_vulkan          — Vulkan compute, SPIR-V shaders
  math_cuda            — cuBLAS, cuDNN, CUDA Graphs, custom PTX
  math_rocm            — rocBLAS, MIOpen, HIP Graphs
  math_metal           — MPS, MPSGraph
  math_xla             — PJRT/OpenXLA (optional graph compiler interop)

Layer 3: Backend Runtimes (Zig code in backend packages)
  Device management, buffer allocation, kernel dispatch,
  compute pipeline caching, data transfer, synchronization,
  fusion planning, library call routing
```

### Lowering Pipeline

```
Zap Math API
    │
    ├─── Library calls (matmul, conv, etc.)
    │        │
    │        ├── Math.CPU      → Zig SIMD + BLAS
    │        ├── Math.WebGPU   → webgpu.h compute pipelines (Dawn)
    │        ├── Math.Vulkan   → Vulkan compute pipelines + SPIR-V
    │        ├── Math.CUDA     → cuBLAS / cuDNN / CUDA Graphs
    │        ├── Math.ROCm     → rocBLAS / MIOpen / HIP Graphs
    │        ├── Math.Metal    → MPS / MPSGraph
    │        └── Math.XLA      → PJRT / OpenXLA
    │
    └─── Custom kernels (dfn)
             │
             ├── Math.CPU      → normal Zig function (loop)
             ├── Math.WebGPU   → WGSL emission → Dawn pipeline
             ├── Math.Vulkan   → SPIR-V emission → Vulkan pipeline
             ├── Math.CUDA     → ZIR → LLVM NVPTX → PTX → CUDA driver
             ├── Math.ROCm     → ZIR → LLVM AMDGPU → HSACO → HIP loader
             └── Math.Metal    → MSL emission → Metal pipeline
```

The **planner** in each backend decides whether an operation should use a tuned library call or a fused custom kernel. Dense matmul, convolution, attention, and FFT should prefer library paths. Elementwise chains, broadcasts, simple reductions, and layout conversions are candidates for fusion into custom kernels.

---

## 6. Tensor Type

### Zig Runtime Representation

```zig
pub const Tensor = struct {
    shape: []const usize,         // dimensions — e.g., [32, 784] for a batch of 784-dim vectors
    strides: []const usize,       // memory layout — enables views without copying
    dtype: DType,                 // element type
    device: Device,               // where the data lives
    storage: *Storage,            // ARC-managed buffer handle
    offset: usize,                // byte offset into storage — enables slices/views
};

pub const DType = enum {
    f16, bf16, f32, f64,          // floating point
    i8, i16, i32, i64,            // signed integer
    u8,                           // unsigned byte
    bool_type,                    // boolean
};

pub const Device = union(enum) {
    cpu: void,
    cuda: u8,                     // device index (0, 1, ...)
    webgpu: u8,
    vulkan: u8,
    rocm: u8,
    metal: u8,
};

pub const Storage = struct {
    header: ArcHeader,            // Zap's existing ARC for host-side refcounting
    data: StorageData,            // actual data pointer
    len: usize,                   // total bytes
    release_fn: ?*const fn (*anyopaque) void,  // backend-specific cleanup
};

pub const StorageData = union(enum) {
    cpu: [*]u8,                   // host memory pointer
    gpu_handle: *anyopaque,       // backend-specific (CUDA devptr, wgpu buffer, etc.)
};
```

### Memory Management

**CPU tensors:** Use Zap's existing ARC. When the refcount drops to zero, the storage is freed via the arena allocator.

**GPU tensors:** Use ARC for the host-side `Storage` wrapper. The actual device memory (CUDA device pointer, WebGPU buffer, etc.) is managed by the backend runtime. When ARC refcount hits zero, `release_fn` calls the backend's device-memory cleanup function. This means GPU memory is released deterministically — no GC, no finalization delays.

**Views and slices:** The `offset` and `strides` fields enable creating views into existing tensors without copying data. A view shares the same `Storage` (incrementing the ARC refcount) but has its own shape, strides, and offset. When the last view is released, the underlying storage is freed.

### Dtypes

**Phase 1:** `f16`, `bf16`, `f32`, `f64`, `i8`, `i16`, `i32`, `i64`, `u8`, `bool`

This matches PyTorch's core dtype set. `bf16` (bfloat16) is included because it is the standard training dtype for modern ML workloads.

**Phase 5:** `complex64`, `complex128` for FFT and scientific computing.

**Note on WebGPU dtype limitations:** Many WebGPU implementations have limited or no `f64` support. The `Math.WebGPU` backend should document which dtypes are fully supported and which fall back to CPU. `f32` is the practical default for WebGPU compute.

---

## 7. The Math API

### The `use Math, backend: Module` Pattern

```zap
pub module Math {
  @moduledoc """
  Numerical computing library with pluggable backends.

  Use `use Math, backend: BackendModule` to configure which
  compute backend handles operations. Defaults to Math.CPU.

  ## Examples

      pub module MyModel {
        use Math, backend: Math.WebGPU

        pub fn predict(weights :: Tensor, input :: Tensor) -> Tensor {
          input
          |> Math.to_device(:gpu0)
          |> Math.matmul(weights)
          |> Math.relu()
        end
      }
  """

  pub macro __using__(opts :: Expr) -> Expr {
    _backend = Keyword.get(opts, :backend, Math.CPU)
    quote {
      import Math
      @math_backend unquote(_backend)
    }
  }
```

When a user writes `use Math, backend: Math.CUDA`:
1. The `__using__` macro fires during macro expansion
2. It sets `@math_backend` to `Math.CUDA` in the calling module
3. Every `Math.*` call dispatches to `Math.CUDA.*` at compile time
4. The compiler inlines the dispatch — zero runtime overhead

### Full API Surface

```zap
  # ──── Tensor Creation ────

  pub fn tensor(data, shape, dtype) -> Tensor { @math_backend.tensor(data, shape, dtype) }
  pub fn zeros(shape, dtype) -> Tensor { @math_backend.zeros(shape, dtype) }
  pub fn ones(shape, dtype) -> Tensor { @math_backend.ones(shape, dtype) }
  pub fn full(shape, value, dtype) -> Tensor { @math_backend.full(shape, value, dtype) }
  pub fn arange(start, stop, step, dtype) -> Tensor { @math_backend.arange(start, stop, step, dtype) }
  pub fn linspace(start, stop, count, dtype) -> Tensor { @math_backend.linspace(start, stop, count, dtype) }
  pub fn eye(size, dtype) -> Tensor { @math_backend.eye(size, dtype) }
  pub fn random_uniform(shape, dtype) -> Tensor { @math_backend.random_uniform(shape, dtype) }
  pub fn random_normal(shape, dtype) -> Tensor { @math_backend.random_normal(shape, dtype) }
  pub fn zeros_like(tensor :: Tensor) -> Tensor { @math_backend.zeros_like(tensor) }
  pub fn ones_like(tensor :: Tensor) -> Tensor { @math_backend.ones_like(tensor) }

  # ──── Element-wise Arithmetic ────

  pub fn add(a :: Tensor, b :: Tensor) -> Tensor { @math_backend.add(a, b) }
  pub fn subtract(a :: Tensor, b :: Tensor) -> Tensor { @math_backend.subtract(a, b) }
  pub fn multiply(a :: Tensor, b :: Tensor) -> Tensor { @math_backend.multiply(a, b) }
  pub fn divide(a :: Tensor, b :: Tensor) -> Tensor { @math_backend.divide(a, b) }
  pub fn power(base :: Tensor, exponent :: Tensor) -> Tensor { @math_backend.power(base, exponent) }
  pub fn negate(tensor :: Tensor) -> Tensor { @math_backend.negate(tensor) }

  # ──── Element-wise Math ────

  pub fn exp(tensor :: Tensor) -> Tensor { @math_backend.exp(tensor) }
  pub fn log(tensor :: Tensor) -> Tensor { @math_backend.log(tensor) }
  pub fn sqrt(tensor :: Tensor) -> Tensor { @math_backend.sqrt(tensor) }
  pub fn abs(tensor :: Tensor) -> Tensor { @math_backend.abs(tensor) }
  pub fn sin(tensor :: Tensor) -> Tensor { @math_backend.sin(tensor) }
  pub fn cos(tensor :: Tensor) -> Tensor { @math_backend.cos(tensor) }
  pub fn tanh(tensor :: Tensor) -> Tensor { @math_backend.tanh(tensor) }
  pub fn sigmoid(tensor :: Tensor) -> Tensor { @math_backend.sigmoid(tensor) }
  pub fn relu(tensor :: Tensor) -> Tensor { @math_backend.relu(tensor) }
  pub fn gelu(tensor :: Tensor) -> Tensor { @math_backend.gelu(tensor) }
  pub fn softmax(tensor :: Tensor, axis) -> Tensor { @math_backend.softmax(tensor, axis) }

  # ──── Reductions ────

  pub fn sum(tensor :: Tensor, axes) -> Tensor { @math_backend.sum(tensor, axes) }
  pub fn mean(tensor :: Tensor, axes) -> Tensor { @math_backend.mean(tensor, axes) }
  pub fn max(tensor :: Tensor, axes) -> Tensor { @math_backend.max(tensor, axes) }
  pub fn min(tensor :: Tensor, axes) -> Tensor { @math_backend.min(tensor, axes) }
  pub fn argmax(tensor :: Tensor, axis) -> Tensor { @math_backend.argmax(tensor, axis) }
  pub fn argmin(tensor :: Tensor, axis) -> Tensor { @math_backend.argmin(tensor, axis) }
  pub fn prod(tensor :: Tensor, axes) -> Tensor { @math_backend.prod(tensor, axes) }
  pub fn variance(tensor :: Tensor, axes) -> Tensor { @math_backend.variance(tensor, axes) }

  # ──── Linear Algebra ────

  pub fn dot(a :: Tensor, b :: Tensor) -> Tensor { @math_backend.dot(a, b) }
  pub fn matmul(a :: Tensor, b :: Tensor) -> Tensor { @math_backend.matmul(a, b) }
  pub fn transpose(tensor :: Tensor, axes) -> Tensor { @math_backend.transpose(tensor, axes) }

  # ──── Shape Operations ────

  pub fn reshape(tensor :: Tensor, shape) -> Tensor { @math_backend.reshape(tensor, shape) }
  pub fn broadcast(tensor :: Tensor, shape) -> Tensor { @math_backend.broadcast(tensor, shape) }
  pub fn concatenate(tensors, axis) -> Tensor { @math_backend.concatenate(tensors, axis) }
  pub fn slice(tensor :: Tensor, starts, lengths) -> Tensor { @math_backend.slice(tensor, starts, lengths) }
  pub fn squeeze(tensor :: Tensor, axes) -> Tensor { @math_backend.squeeze(tensor, axes) }
  pub fn unsqueeze(tensor :: Tensor, axis) -> Tensor { @math_backend.unsqueeze(tensor, axis) }

  # ──── Comparison ────

  pub fn equal(a :: Tensor, b :: Tensor) -> Tensor { @math_backend.equal(a, b) }
  pub fn greater(a :: Tensor, b :: Tensor) -> Tensor { @math_backend.greater(a, b) }
  pub fn less(a :: Tensor, b :: Tensor) -> Tensor { @math_backend.less(a, b) }
  pub fn where_cond(condition :: Tensor, a :: Tensor, b :: Tensor) -> Tensor { @math_backend.where_cond(condition, a, b) }
  pub fn clamp(tensor :: Tensor, min_val, max_val) -> Tensor { @math_backend.clamp(tensor, min_val, max_val) }

  # ──── Device Placement ────

  pub fn to_device(tensor :: Tensor, device) -> Tensor { @math_backend.to_device(tensor, device) }
  pub fn to_host(tensor :: Tensor) -> Tensor { @math_backend.to_host(tensor) }

  # ──── Trace and Autograd ────

  pub fn trace(computation) -> {Tensor, Trace} { @math_backend.trace(computation) }
  pub fn grad(trace :: Trace, wrt :: Tensor) -> Tensor { @math_backend.grad(trace, wrt) }
  pub fn grad(computation, wrt :: Tensor) -> Tensor {
    {_result, the_trace} = Math.trace(computation)
    Math.grad(the_trace, wrt)
  }

  # ──── Device Function Launch ────

  pub fn launch(device_fn, grid_dims, args...) { @math_backend.launch(device_fn, grid_dims, args) }
}
```

---

## 8. The Backend Protocol

```zap
pub protocol Math.Backend {
  # ──── Tier 1: Core (~45 ops, minimum viable backend) ────

  # Creation
  fn tensor(data, shape, dtype) -> Tensor
  fn zeros(shape, dtype) -> Tensor
  fn ones(shape, dtype) -> Tensor
  fn full(shape, value, dtype) -> Tensor
  fn arange(start, stop, step, dtype) -> Tensor
  fn linspace(start, stop, count, dtype) -> Tensor
  fn eye(size, dtype) -> Tensor
  fn random_uniform(shape, dtype) -> Tensor
  fn random_normal(shape, dtype) -> Tensor
  fn zeros_like(tensor :: Tensor) -> Tensor
  fn ones_like(tensor :: Tensor) -> Tensor

  # Element-wise arithmetic
  fn add(a :: Tensor, b :: Tensor) -> Tensor
  fn subtract(a :: Tensor, b :: Tensor) -> Tensor
  fn multiply(a :: Tensor, b :: Tensor) -> Tensor
  fn divide(a :: Tensor, b :: Tensor) -> Tensor
  fn power(base :: Tensor, exponent :: Tensor) -> Tensor
  fn negate(tensor :: Tensor) -> Tensor

  # Element-wise math
  fn exp(tensor :: Tensor) -> Tensor
  fn log(tensor :: Tensor) -> Tensor
  fn sqrt(tensor :: Tensor) -> Tensor
  fn abs(tensor :: Tensor) -> Tensor
  fn sin(tensor :: Tensor) -> Tensor
  fn cos(tensor :: Tensor) -> Tensor
  fn tanh(tensor :: Tensor) -> Tensor
  fn sigmoid(tensor :: Tensor) -> Tensor
  fn relu(tensor :: Tensor) -> Tensor
  fn gelu(tensor :: Tensor) -> Tensor
  fn softmax(tensor :: Tensor, axis) -> Tensor

  # Reductions
  fn sum(tensor :: Tensor, axes) -> Tensor
  fn mean(tensor :: Tensor, axes) -> Tensor
  fn max(tensor :: Tensor, axes) -> Tensor
  fn min(tensor :: Tensor, axes) -> Tensor
  fn argmax(tensor :: Tensor, axis) -> Tensor
  fn argmin(tensor :: Tensor, axis) -> Tensor
  fn prod(tensor :: Tensor, axes) -> Tensor
  fn variance(tensor :: Tensor, axes) -> Tensor

  # Linear algebra
  fn dot(a :: Tensor, b :: Tensor) -> Tensor
  fn matmul(a :: Tensor, b :: Tensor) -> Tensor
  fn transpose(tensor :: Tensor, axes) -> Tensor

  # Shape operations
  fn reshape(tensor :: Tensor, shape) -> Tensor
  fn broadcast(tensor :: Tensor, shape) -> Tensor
  fn concatenate(tensors, axis) -> Tensor
  fn slice(tensor :: Tensor, starts, lengths) -> Tensor
  fn squeeze(tensor :: Tensor, axes) -> Tensor
  fn unsqueeze(tensor :: Tensor, axis) -> Tensor

  # Comparison
  fn equal(a :: Tensor, b :: Tensor) -> Tensor
  fn greater(a :: Tensor, b :: Tensor) -> Tensor
  fn less(a :: Tensor, b :: Tensor) -> Tensor
  fn where_cond(condition :: Tensor, a :: Tensor, b :: Tensor) -> Tensor
  fn clamp(tensor :: Tensor, min_val, max_val) -> Tensor

  # Device placement
  fn to_device(tensor :: Tensor, device) -> Tensor
  fn to_host(tensor :: Tensor) -> Tensor

  # Trace and autograd
  fn trace(computation) -> {Tensor, Trace}
  fn grad(trace :: Trace, wrt :: Tensor) -> Tensor

  # Device function launch
  fn launch(device_fn, grid_dims, args) -> Tensor

  # ──── Tier 2: Full Numerical Library (~60 more ops, Phase 5) ────
  # Full trig/hyperbolic, rounding, floor, ceil, round, trunc
  # Full linalg: solve, det, inv, SVD, eig, Cholesky, QR, norm
  # Advanced shape: stack, split, gather, scatter, pad, tile
  # Sorting: sort, argsort, topk, unique
  # FFT: fft, ifft, rfft, irfft

  # ──── Tier 3: Neural Network / Advanced (~40 more ops, Phase 5) ────
  # Conv: conv1d, conv2d, conv3d
  # Pooling: max_pool, avg_pool, adaptive_pool
  # Normalization: batch_norm, layer_norm, group_norm
  # Attention: scaled_dot_product_attention
  # Sparse: sparse_tensor, sparse_matmul
}
```

A backend that implements only Tier 1 is fully functional for data science and basic ML. Tier 2 and 3 operations can have default implementations that compose Tier 1 ops (slower but correct), which backends override with optimized versions.

---

## 9. Backend Packages

### Backend Lineup

| Package | Module | Hardware | Zig Runtime Wraps | Lowering for `dfn` |
|---------|--------|----------|-------------------|-------------------|
| (core) | `Math.CPU` | All platforms | Zig SIMD, optionally OpenBLAS/Accelerate | Normal Zig function (loop) |
| `math_webgpu` | `Math.WebGPU` | All GPUs via Dawn | `webgpu.h` C API (Dawn) | WGSL emission |
| `math_vulkan` | `Math.Vulkan` | Vulkan-capable GPUs | Vulkan compute API | SPIR-V emission |
| `math_cuda` | `Math.CUDA` | NVIDIA GPUs | cuBLAS, cuDNN, CUDA Driver API | ZIR → LLVM NVPTX → PTX |
| `math_rocm` | `Math.ROCm` | AMD GPUs | rocBLAS, MIOpen, HIP Runtime | ZIR → LLVM AMDGPU → HSACO |
| `math_metal` | `Math.Metal` | Apple Silicon | MPS, MPSGraph, Metal compute | MSL emission |
| `math_xla` | `Math.XLA` | Multi-device | PJRT / OpenXLA | StableHLO export |

### Package Structure

Each backend package contains:

```
math_webgpu/
  build.zap              # Zap package manifest
  build.zig.zon          # Zig package manifest (for Dawn dependency)
  lib/
    math/
      webgpu.zap         # Math.WebGPU module (impl Math.Backend)
  src/
    webgpu_runtime.zig   # Zig runtime: device mgmt, buffer ops, dispatch
    shaders/
      elementwise.wgsl   # WGSL compute shader templates
      reduction.wgsl
      matmul.wgsl
      ...
```

### SDK and License Isolation

GPU backend packages do **not** redistribute vendor SDKs:

- `math_cuda` links against the user's installed CUDA toolkit. No CUDA libraries are bundled.
- `math_rocm` links against the user's installed ROCm stack.
- `math_metal` uses system-provided Metal framework.
- `math_webgpu` ships prebuilt Dawn libraries (permissive open-source license).
- `math_vulkan` links against the system Vulkan loader; ships SPIRV-Tools for validation.

This isolates licensing concerns — especially CUDA's redistributable restrictions — from Zap's core.

---

## 10. Backend-Specific APIs

### The Problem

Not every GPU capability can be abstracted through the common `Math.Backend` protocol. Each vendor provides hardware features that have no equivalent on other platforms:

| Capability | CUDA | ROCm | Metal | WebGPU | Vulkan |
|-----------|------|------|-------|--------|--------|
| Tensor Cores (mixed-precision matmul) | Yes (WMMA) | Yes (rocWMMA) | Yes (Simdgroup matrix) | No | No |
| Warp/wave-level primitives | 32-wide warps | 64-wide wavefronts | 32-wide simdgroups | No | Subgroups (variable width) |
| Dynamic parallelism (kernels launching kernels) | Yes | Yes | No | No | No |
| Cooperative groups | Yes | Partial | No | No | No |
| Async memory copy (global ↔ shared) | Yes (cp.async) | Yes | No | No | No |
| Neural Engine | No | No | Yes | No | No |
| Algorithm selection (Winograd vs FFT conv) | cuDNN API | MIOpen API | MPSGraph | No | No |
| Multi-GPU communication | NCCL | RCCL | No | No | No |
| Push constants | No | No | No | No | Yes |
| True unified CPU/GPU memory | No | No | Yes (Apple Silicon) | No | No |
| Fused bias + activation kernels | cuDNN | MIOpen | MPS | No | No |

Forcing these through the common protocol would mean either losing them entirely or creating a lowest-common-denominator abstraction that sacrifices the performance advantages of each platform.

### The Solution: Direct Backend Module Access

Each backend module is just a module. The `Math.Backend` protocol defines the portable surface. But each backend can expose additional public functions beyond the protocol that provide access to hardware-specific capabilities.

Since the user already declared their backend with `use Math, backend: Math.CUDA`, they have direct access to the backend module and can call its specific functions alongside the portable `Math.*` API.

### Portable Code vs Optimized Code

```zap
pub module MyModel {
  use Math, backend: Math.CUDA

  pub fn forward(x :: Tensor, weights :: Tensor, bias :: Tensor) -> Tensor {
    # Portable — works on any backend
    x
    |> Math.matmul(weights)
    |> Math.add(bias)
    |> Math.relu()
  end

  pub fn forward_optimized(x :: Tensor, weights :: Tensor, bias :: Tensor) -> Tensor {
    # CUDA-specific — uses Tensor Cores with TF32 precision
    # and a fused bias+ReLU kernel to avoid extra memory round-trips
    x
    |> Math.CUDA.tensor_core_matmul(weights, precision: :tf32)
    |> Math.CUDA.fused_bias_relu(bias)
  end
end
```

### Backend-Specific Examples

**CUDA — Tensor Cores and NCCL:**

```zap
pub module DistributedTraining {
  use Math, backend: Math.CUDA

  pub fn all_reduce_gradients(gradients :: Tensor) -> Tensor {
    # NCCL multi-GPU all-reduce — CUDA-specific
    Math.CUDA.nccl_all_reduce(gradients, op: :sum)
  end

  pub fn mixed_precision_matmul(x :: Tensor, weights :: Tensor) -> Tensor {
    # Tensor Core matmul with FP16 inputs, FP32 accumulation
    Math.CUDA.tensor_core_matmul(x, weights, precision: :tf32)
  end

  pub fn optimized_attention(q :: Tensor, k :: Tensor, v :: Tensor) -> Tensor {
    # cuDNN Flash Attention — specific algorithm selection
    Math.CUDA.flash_attention(q, k, v, causal: true)
  end
end
```

**Metal — Neural Engine and Unified Memory:**

```zap
pub module AppleModel {
  use Math, backend: Math.Metal

  pub fn predict(x :: Tensor) -> Tensor {
    # Run inference on Apple's Neural Engine instead of GPU
    Math.Metal.neural_engine(fn() -> Tensor {
      x
      |> Math.matmul(weights)
      |> Math.relu()
      |> Math.softmax(axis: -1)
    })
  end

  pub fn shared_memory_matmul(x :: Tensor, weights :: Tensor) -> Tensor {
    # Exploit Apple Silicon unified memory — zero-copy between CPU and GPU
    Math.Metal.unified_memory_matmul(x, weights)
  end
end
```

**ROCm — Wave-Level Primitives:**

```zap
pub module AMDOptimized {
  use Math, backend: Math.ROCm

  pub fn wave_reduce(x :: Tensor) -> Tensor {
    # AMD-specific 64-wide wavefront reduction
    Math.ROCm.wave_reduce_sum(x)
  end

  pub fn tuned_conv(input :: Tensor, kernel :: Tensor) -> Tensor {
    # MIOpen with autotuning enabled — finds best algorithm for this shape
    Math.ROCm.miopen_conv(input, kernel, autotune: true)
  end
end
```

**Vulkan — Push Constants and Pipeline Control:**

```zap
pub module VulkanCompute {
  use Math, backend: Math.Vulkan

  pub fn parameterized_kernel(x :: Tensor, alpha :: f32, beta :: f32) -> Tensor {
    # Vulkan push constants — small values sent directly to shader without buffer
    Math.Vulkan.with_push_constants(%{alpha: alpha, beta: beta}, fn() -> Tensor {
      Math.multiply(x, alpha) |> Math.add(beta)
    })
  end
end
```

### Portability Boundary Is Visible

The key design property: **the portability boundary is visible in the code.**

- `Math.matmul(a, b)` — portable across all backends
- `Math.CUDA.tensor_core_matmul(a, b, precision: :tf32)` — CUDA only

If a user switches from `Math.CUDA` to `Math.WebGPU`, all `Math.*` calls continue to work. All `Math.CUDA.*` calls become compile errors — the module doesn't exist in the WebGPU context. This is intentional. The user sees exactly where they've tied themselves to a specific backend and can decide whether to use the portable path or the optimized path.

No special escape hatch API is needed. No `Math.backend_call` or `Math.raw`. The backend is just a module with its own public functions. The protocol functions are the portable subset. Everything else on the module is backend-specific.

---

## 11. Device Functions (`dfn`)

### Mechanism

`dfn` is a macro injected by the backend's `__using__`. When a module does `use Math, backend: Math.CUDA`, the `Math.CUDA.__using__` macro injects a `dfn` macro alongside the `@math_backend` attribute. This `dfn` macro knows how to compile device code for CUDA's target (NVPTX/PTX).

No compiler changes are needed. Each backend provides its own `dfn` implementation.

### Syntax

```zap
pub module MyKernels {
  use Math, backend: Math.CUDA

  # Device function — compiled to PTX by Math.CUDA's dfn macro
  pub dfn saxpy(alpha :: f32, x :: TensorView(f32), y :: TensorView(f32), out :: TensorView(f32)) {
    index = gpu.global_id(0)

    if index < x.dim(0) {
      out[index] = alpha * x[index] + y[index]
    }
  }

  # Host function — launches the device function
  pub fn run_saxpy(alpha :: f32, x :: Tensor, y :: Tensor) -> Tensor {
    out = Math.zeros_like(y)
    Math.launch(saxpy, {x.dim(0)}, alpha, x, y, out)
    out
  }
}
```

### More Examples

**2D operation:**
```zap
pub dfn matrix_relu(input :: TensorView(f32), output :: TensorView(f32)) {
  row = gpu.global_id(0)
  col = gpu.global_id(1)

  if row < input.dim(0) and col < input.dim(1) {
    value = input[row, col]
    output[row, col] = if value > 0.0 { value } else { 0.0 }
  }
}
```

**Reduction with shared memory:**
```zap
pub dfn sum_reduce(input :: TensorView(f32), output :: TensorView(f32)) {
  local_id = gpu.local_id(0)
  group_id = gpu.workgroup_id(0)
  group_size = gpu.workgroup_size(0)
  global_id = gpu.global_id(0)

  shared buffer :: [256]f32

  buffer[local_id] = if global_id < input.dim(0) { input[global_id] } else { 0.0 }

  gpu.barrier()

  stride = group_size / 2
  while stride > 0 {
    if local_id < stride {
      buffer[local_id] = buffer[local_id] + buffer[local_id + stride]
    }
    gpu.barrier()
    stride = stride / 2
  }

  if local_id == 0 {
    output[group_id] = buffer[0]
  }
}
```

**Using structs in device code:**
```zap
pub struct Particle {
  x :: f32,
  y :: f32,
  velocity :: f32,
}

pub dfn update_particles(particles :: TensorView(Particle), dt :: f32) {
  index = gpu.global_id(0)
  if index < particles.dim(0) {
    p = particles[index]
    particles[index] = %Particle{p | x: p.x + p.velocity * dt}
  }
}
```

### Restricted Subset

Inside `dfn`, only device-compatible constructs are allowed. The backend's `dfn` macro validates this.

**Allowed:**
- Scalar types: `i8`, `i16`, `i32`, `i64`, `u8`, `u16`, `u32`, `u64`, `f16`, `f32`, `f64`, `bool`
- `TensorView(dtype)` — lightweight view (pointer + shape + strides), no ARC overhead
- Structs with only device-compatible fields (no ARC fields, no closures, no lists/maps)
- Simple control flow: `if`/`else`, `case`, `while` loops
- Local variables (stack-allocated)
- Shared memory declarations: `shared name :: [size]dtype`
- GPU intrinsics: `gpu.global_id(dim)`, `gpu.local_id(dim)`, `gpu.workgroup_id(dim)`, `gpu.workgroup_size(dim)`, `gpu.barrier()`
- Arithmetic, comparison, and math functions (sin, cos, exp, sqrt, etc.)
- Other `dfn` functions (composition within device code)

**Forbidden:**
- Closures and function values
- ARC-managed objects (no retain/release on device)
- Persistent lists, maps, strings (heap-allocated, ARC-managed)
- Protocol dispatch (requires dynamic dispatch / vtable)
- Dynamic heap allocation
- Atoms (interned in host-side table)
- IO, File, System, or any side-effecting module
- `raise` or exception handling

### Per-Backend Lowering

| Backend | `dfn` lowers to | Runtime loading |
|---------|-----------------|-----------------|
| `Math.CPU` | Normal Zig function body (loop over elements) | Direct call |
| `Math.WebGPU` | WGSL compute shader source string | `wgpuDeviceCreateComputePipeline` |
| `Math.Vulkan` | SPIR-V bytecode | `vkCreateComputePipelines` |
| `Math.CUDA` | ZIR → LLVM NVPTX → PTX text | `cuModuleLoadData` + `cuLaunchKernel` |
| `Math.ROCm` | ZIR → LLVM AMDGPU → HSACO binary | `hipModuleLoadData` + `hipLaunchKernel` |
| `Math.Metal` | Metal Shading Language source string | `MTLDevice.makeComputePipelineState` |

---

## 12. Autograd — Functional Trace-and-Replay

### The Functional Insight

In Elm, the time-travel debugger works because every state transition is a pure function applied to immutable data. You record every input, and you can replay the entire computation deterministically. Redux borrowed this pattern for JavaScript.

Zap shares these fundamental properties:

1. **Purity** — every function, given the same inputs, returns the same outputs
2. **Immutability** — values cannot be modified after creation, so recorded inputs stay valid forever
3. **No unmanaged side effects** — the execution trace captures everything needed

These properties mean the execution trace of a numerical computation IS the computation graph that reverse-mode automatic differentiation needs. In imperative languages (Python/PyTorch), building this graph requires careful mutation tracking, in-place operation detection, and explicit `save_for_backward` calls. In Zap, the graph is correct by construction.

### How It Works

**The Trace:** An immutable list of `{operation, inputs, output}` tuples.

```
[
  {:matmul,    [input, params],      prediction},
  {:subtract,  [prediction, target], error},
  {:power,     [error, 2],           squared},
  {:mean,      [squared],            result}
]
```

Every entry is immutable. The inputs at trace time are the same values forever (guaranteed by Zap's language semantics). No entry can be invalidated by later operations.

**Forward pass:** Execute the computation normally via `Math.trace`. Each `Math.*` operation records itself and its inputs/outputs into the trace. The trace is an immutable accumulation — each operation adds to the list.

**Backward pass:** Walk the trace in reverse via `Math.grad`. At each step:
1. Look up the operation's VJP (vector-Jacobian product) rule
2. Apply the chain rule to propagate the upstream gradient through the operation
3. Accumulate gradients for each input tensor

### User API

```zap
pub module Training {
  use Math, backend: Math.CUDA

  pub fn loss(params :: Tensor, input :: Tensor, target :: Tensor) -> Tensor {
    prediction = Math.matmul(input, params)
    error = Math.subtract(prediction, target)
    squared = Math.power(error, 2)
    Math.mean(squared)
  }

  # One-liner: compute gradients of loss with respect to params
  pub fn train_step(params :: Tensor, input :: Tensor, target :: Tensor, learning_rate :: f64) -> Tensor {
    gradients = Math.grad(fn() -> Tensor { loss(params, input, target) }, wrt: params)
    Math.subtract(params, Math.multiply(gradients, learning_rate))
  }

  # Or explicitly, with access to the trace for debugging:
  pub fn train_step_verbose(params :: Tensor, input :: Tensor, target :: Tensor, learning_rate :: f64) -> Tensor {
    {result, trace} = Math.trace(fn() -> Tensor { loss(params, input, target) })
    gradients = Math.grad(trace, wrt: params)
    Math.subtract(params, Math.multiply(gradients, learning_rate))
  }
}
```

### VJP Rules

Defined in Zap library code. Each primitive Math operation has a registered backward rule:

```zap
pub module Math.VJP {
  @moduledoc """
  Vector-Jacobian Product rules for automatic differentiation.
  Each function takes the upstream gradient and the original inputs,
  and returns the gradient with respect to each input.
  """

  pub fn add(upstream, a, b) -> {Tensor, Tensor} {
    {upstream, upstream}
  }

  pub fn subtract(upstream, a, b) -> {Tensor, Tensor} {
    {upstream, Math.negate(upstream)}
  }

  pub fn multiply(upstream, a, b) -> {Tensor, Tensor} {
    {Math.multiply(upstream, b), Math.multiply(upstream, a)}
  }

  pub fn divide(upstream, a, b) -> {Tensor, Tensor} {
    {Math.divide(upstream, b),
     Math.negate(Math.divide(Math.multiply(upstream, a), Math.power(b, 2)))}
  }

  pub fn matmul(upstream, a, b) -> {Tensor, Tensor} {
    {Math.matmul(upstream, Math.transpose(b)),
     Math.matmul(Math.transpose(a), upstream)}
  }

  pub fn relu(upstream, x) -> Tensor {
    Math.multiply(upstream, Math.greater(x, 0))
  }

  pub fn sigmoid(upstream, x) -> Tensor {
    s = Math.sigmoid(x)
    Math.multiply(upstream, Math.multiply(s, Math.subtract(Math.ones_like(s), s)))
  }

  pub fn tanh(upstream, x) -> Tensor {
    t = Math.tanh(x)
    Math.multiply(upstream, Math.subtract(Math.ones_like(t), Math.power(t, 2)))
  }

  pub fn exp(upstream, x) -> Tensor {
    Math.multiply(upstream, Math.exp(x))
  }

  pub fn log(upstream, x) -> Tensor {
    Math.divide(upstream, x)
  }

  pub fn sqrt(upstream, x) -> Tensor {
    Math.divide(upstream, Math.multiply(2.0, Math.sqrt(x)))
  }

  pub fn power(upstream, base, exponent) -> {Tensor, Tensor} {
    {Math.multiply(upstream, Math.multiply(exponent, Math.power(base, Math.subtract(exponent, 1)))),
     Math.multiply(upstream, Math.multiply(Math.log(base), Math.power(base, exponent)))}
  }

  pub fn sum(upstream, x, axes) -> Tensor {
    Math.broadcast(upstream, Math.shape(x))
  }

  pub fn mean(upstream, x, axes) -> Tensor {
    Math.divide(Math.broadcast(upstream, Math.shape(x)), Math.prod(Math.shape(x)))
  }

  pub fn transpose(upstream, x, axes) -> Tensor {
    Math.transpose(upstream, invert_permutation(axes))
  }

  pub fn reshape(upstream, x, shape) -> Tensor {
    Math.reshape(upstream, Math.shape(x))
  }

  pub fn softmax(upstream, x, axis) -> Tensor {
    s = Math.softmax(x, axis)
    Math.multiply(s, Math.subtract(upstream, Math.sum(Math.multiply(upstream, s), axis)))
  }

  # ... remaining primitives
}
```

### Composability

Because `Math.grad` returns a pure function (or a tensor result from applying one), higher-order differentiation works naturally:

```zap
# Second derivative
second_grad = Math.grad(fn() { Math.grad(fn() { f(x) }, wrt: x) }, wrt: x)

# Gradient of a pipeline
gradients = Math.grad(fn() -> Tensor {
  x
  |> Math.matmul(w1)
  |> Math.relu()
  |> Math.matmul(w2)
  |> Math.softmax(axis: -1)
  |> cross_entropy(labels)
}, wrt: w1)
```

### Beyond Autograd

The trace mechanism is a general-purpose capability, not autograd-specific:

| Consumer | What it does with the trace |
|----------|----------------------------|
| **Autograd** | Walk backward with chain rule to compute gradients |
| **Time-travel debugging** | Inspect any intermediate tensor value in a computation |
| **Profiling** | Measure wall time and memory per operation |
| **Graph optimization** | Analyze the trace, fuse operations, reorder for efficiency |
| **Reproducibility** | Serialize a trace, replay it on different hardware or backends |

---

## 13. Interaction with Perceus and ARC

### The Problem

Zap's Perceus optimization detects when a value's ARC refcount is 1 and enables in-place memory reuse. This is a key performance optimization for normal Zap code. But it creates a conflict with autograd:

```zap
a = Math.tensor(...)
b = Math.relu(a)        # If a's refcount is 1, Perceus reuses a's memory for b
c = Math.multiply(b, 2) # If b's refcount is 1, Perceus reuses b's memory for c
```

After this chain, `a`'s and `b`'s original data may have been overwritten. But the autograd trace recorded `{:relu, [a], b}` — and the VJP for `relu` needs to know which elements of `a` were positive. If `a`'s memory was reused for `b`, that data is gone.

### The Solution

The trace holds ARC references to every intermediate value it records. This naturally prevents Perceus from reusing their memory.

```
Outside Math.trace:
  a (refcount 1) → relu → Perceus reuses a's memory for b ✓ (fast)

Inside Math.trace:
  a (refcount 2: user code + trace) → relu → b gets fresh allocation
  because a's refcount > 1, Perceus cannot reuse it
```

No special compiler support is needed. No changes to Perceus. The trace is just another value holding references — standard ARC semantics prevent reuse of referenced values.

### Performance Characteristics

| Context | Memory behavior | Performance |
|---------|----------------|-------------|
| Normal code (no trace) | Perceus reuses aggressively | Optimal — minimal allocation |
| Inside `Math.trace` | All intermediates retained by trace | Higher memory usage during forward + backward |
| After trace is released | Intermediate refcounts drop, memory freed | Memory recovered deterministically |

This is the same tradeoff PyTorch makes — autograd retains intermediate tensors for the backward pass, then frees them after `.backward()` completes. The difference is Zap gets this from its existing ARC semantics rather than a separate autograd-specific retention mechanism.

### Future Optimization: Gradient Checkpointing

For very deep computations where retaining all intermediates would exhaust GPU memory, a future optimization is gradient checkpointing: retain only every Nth intermediate value and recompute the others from checkpoints during the backward pass. This trades compute for memory. It would be implemented as a variant of `Math.trace` — e.g., `Math.trace(computation, checkpoint_every: 10)` — and is a Phase 5 optimization.

---

## 14. Fusion Strategy

Each backend owns its fusion logic. The Zap compiler sees normal function calls — it has no knowledge of fusion, kernels, or GPU dispatch.

### Why Fusion Matters

A chain of tensor operations like `Math.add(a, b) |> Math.relu() |> Math.multiply(c)` naively requires three separate GPU kernel launches, each reading from and writing to global memory. A fused version executes all three operations in a single kernel launch with a single memory pass — often 3-10x faster.

The 2026 WebGPU dispatch-overhead study found that WebGPU reached only 11-12% of CUDA throughput on fine-grained (unfused) workloads. Fusion is essential for WebGPU to be usable, and beneficial for all backends.

### WebGPU Fusion

The `Math.WebGPU` backend's Zig runtime detects chains of elementwise ops on tensors of the same shape. It generates a single fused WGSL shader via string concatenation of the operation chain, compiles it via Dawn's pipeline API, caches the compiled pipeline, and dispatches once.

Example: `add → relu → multiply` becomes one WGSL shader:

```wgsl
@compute @workgroup_size(256)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let i = gid.x;
    if (i < arrayLength(&output)) {
        var tmp = input_a[i] + input_b[i];  // add
        tmp = max(tmp, 0.0);                 // relu
        output[i] = tmp * input_c[i];        // multiply
    }
}
```

Debug builds validate generated WGSL through Naga before compilation.

### Vulkan Fusion

Similar to WebGPU but emits fused SPIR-V shaders. SPIRV-Tools validates and optimizes the generated SPIR-V in debug builds.

### CUDA Fusion

Route heavy operations to tuned libraries:
- matmul → cuBLAS
- convolution → cuDNN
- attention → cuDNN (Flash Attention)
- FFT → cuFFT

Fuse the "glue" between library calls — elementwise ops, broadcast chains, simple reductions, layout conversions — into custom PTX kernels generated at runtime. Use CUDA Graphs for repeated workloads to amortize launch overhead.

### ROCm Fusion

Same strategy as CUDA with AMD equivalents:
- matmul → rocBLAS
- convolution → MIOpen
- FFT → rocFFT

Custom AMDGCN kernels for elementwise fusion. HIP Graphs for repeated workloads.

### Metal Fusion

MPSGraph handles graph-level fusion and optimization natively. For operations not covered by MPSGraph, Metal compute pipelines with fused MSL shaders.

### CPU Fusion

Loop fusion via Zig's comptime and SIMD vectorization. A chain of elementwise ops on the same shape becomes a single pass over the data with `@Vector` SIMD instructions.

---

## 15. Device Placement and Data Transfer

### Explicit Placement

Data does not move between CPU and GPU unless the user says so:

```zap
# Create on CPU (default)
x = Math.tensor(data, {1000, 1000}, :f32)

# Explicit transfer to GPU
x_gpu = Math.to_device(x, :gpu0)

# Compute on GPU (all tensors must be on the same device)
result = Math.matmul(x_gpu, weights_gpu)

# Explicit transfer back to CPU
result_cpu = Math.to_host(result)
```

### Error on Cross-Device Operations

If a user tries to operate on tensors from different devices without explicit transfer, the backend produces a clear error:

```
Error: Device mismatch in Math.matmul
  Left operand:  Tensor on :cpu
  Right operand: Tensor on {:cuda, 0}
  Hint: Use Math.to_device(tensor, {:cuda, 0}) to move data to the GPU
```

No silent copies. No transparent unified memory. The user always knows where data lives and when it moves.

### Device Selection

```zap
# Atom shorthand for default device of that type
Math.to_device(tensor, :gpu0)
Math.to_device(tensor, :cpu)

# Tuple for specific device index
Math.to_device(tensor, {:cuda, 0})
Math.to_device(tensor, {:cuda, 1})

# Create directly on a device
Math.zeros({1000, 1000}, :f32, device: :gpu0)
Math.random_normal({64, 784}, :f32, device: {:cuda, 0})
```

### Multi-GPU

Phase 3 introduces explicit multi-GPU placement:

```zap
# Data parallel: same model on two GPUs, different data
input_gpu0 = Math.to_device(batch_a, {:cuda, 0})
input_gpu1 = Math.to_device(batch_b, {:cuda, 1})

result_a = Math.matmul(input_gpu0, weights_gpu0)
result_b = Math.matmul(input_gpu1, weights_gpu1)
```

Start with explicit placement and `Math.replicate`, `Math.scatter`, `Math.gather`. Automatic sharding deferred until the design is validated.

---

## 16. Execution Model

### Synchronous First

All GPU operations in Phase 1-3 are synchronous. A `Math.matmul` call blocks until the result is computed and available. This is simple, predictable, and easy to debug.

### Async Deferred to Zap's Concurrency Story

Zap currently has no async primitives. Rather than designing a GPU-specific async model that might conflict with Zap's eventual concurrency primitives, async GPU execution (streams, queues, overlapping compute and transfer) will be designed later around Zap's own concurrency foundation.

When Zap's concurrency story is implemented, the GPU async model should integrate naturally:

```zap
# Future API shape (depends on Zap concurrency design):
# stream = Math.stream({:cuda, 0})
# result = Math.with_stream(stream, fn() { Math.matmul(a, b) })
# Math.await(result)
```

### Graph Capture for Repeated Workloads

Phase 3 introduces graph capture for reducing launch overhead on repeated computations (e.g., inference loops, training steps):

```zap
graph = Math.capture(fn() -> Tensor {
  input
  |> Math.matmul(weights)
  |> Math.add(bias)
  |> Math.relu()
})

# Replay with near-zero launch overhead
result = Math.replay(graph, input: new_input)
```

This maps to CUDA Graphs on NVIDIA, HIP Graphs on AMD, and MPSGraph compilation on Apple. The capture/replay API is defined in `Math` (Zap code), but the implementation is backend-specific.

---

## 17. Operation Coverage

### Tier 1 — Core (~45 ops, Phase 1)

The minimum viable set for a functional backend:

| Category | Operations |
|----------|-----------|
| Creation | `tensor`, `zeros`, `ones`, `full`, `arange`, `linspace`, `eye`, `random_uniform`, `random_normal`, `zeros_like`, `ones_like` |
| Arithmetic | `add`, `subtract`, `multiply`, `divide`, `power`, `negate` |
| Math | `exp`, `log`, `sqrt`, `abs`, `sin`, `cos`, `tanh`, `sigmoid`, `relu`, `gelu`, `softmax` |
| Reduction | `sum`, `mean`, `max`, `min`, `argmax`, `argmin`, `prod`, `variance` |
| Linalg | `dot`, `matmul`, `transpose` |
| Shape | `reshape`, `broadcast`, `concatenate`, `slice`, `squeeze`, `unsqueeze` |
| Comparison | `equal`, `greater`, `less`, `where_cond`, `clamp` |
| Device | `to_device`, `to_host` |
| Autograd | `trace`, `grad` |
| Launch | `launch` (for `dfn`) |

### Tier 2 — Full Numerical Library (~60 more ops, Phase 5)

| Category | Operations |
|----------|-----------|
| Trig/Hyperbolic | `tan`, `asin`, `acos`, `atan`, `atan2`, `sinh`, `cosh`, `asinh`, `acosh`, `atanh` |
| Rounding | `floor`, `ceil`, `round`, `trunc`, `fmod`, `remainder` |
| Linalg | `solve`, `det`, `inv`, `svd`, `eig`, `cholesky`, `qr`, `lu`, `norm`, `matrix_rank`, `pinverse`, `cross`, `outer` |
| Shape | `stack`, `split`, `chunk`, `gather`, `scatter`, `pad`, `tile`, `repeat`, `flip`, `roll`, `narrow` |
| Sorting | `sort`, `argsort`, `topk`, `unique`, `searchsorted` |
| FFT | `fft`, `ifft`, `rfft`, `irfft`, `fft2`, `ifft2` |
| Comparison | `greater_equal`, `less_equal`, `not_equal`, `isnan`, `isinf`, `isfinite` |
| Logical | `logical_and`, `logical_or`, `logical_not`, `logical_xor` |

### Tier 3 — Neural Network / Advanced (~40 more ops, Phase 5)

| Category | Operations |
|----------|-----------|
| Convolution | `conv1d`, `conv2d`, `conv3d`, `conv_transpose1d`, `conv_transpose2d` |
| Pooling | `max_pool1d`, `max_pool2d`, `avg_pool1d`, `avg_pool2d`, `adaptive_avg_pool2d` |
| Normalization | `batch_norm`, `layer_norm`, `group_norm`, `instance_norm` |
| Attention | `scaled_dot_product_attention`, `multi_head_attention` |
| Dropout | `dropout` (inference-mode masking) |
| Embedding | `embedding`, `one_hot` |
| Loss | `cross_entropy`, `mse_loss`, `l1_loss`, `binary_cross_entropy` |
| Sparse | `sparse_tensor`, `sparse_matmul`, `to_sparse`, `to_dense` |
| Complex | `complex`, `real`, `imag`, `conj`, `angle` (requires complex dtypes) |

---

## 18. Testing Strategy

### Five Concentric Rings

**Ring 1 — CPU Reference Correctness:**
Pure CPU golden-value tests for every operation. These are the ground truth. Test against known mathematical identities, edge cases (empty tensors, single elements, very large values, NaN, inf), and dtype behavior (overflow, precision).

**Ring 2 — GPU Differential Testing:**
For each GPU backend, run the same operations on GPU and compare results against CPU reference with per-dtype tolerances (f32 has ~1e-6 relative tolerance, f16 has ~1e-3). This catches GPU-specific numerical issues.

**Ring 3 — Kernel Validity:**
Validate generated shader/kernel code before dispatch:
- WGSL → Naga parser/validator
- SPIR-V → SPIRV-Tools validator
- PTX → CUDA driver load-and-verify
- HSACO → HIP module load-and-verify
- MSL → Metal compiler feedback

**Ring 4 — Graph Partitioning and Fallback:**
Test that unsupported operations produce clear error messages or fall back to CPU with diagnostics. Test that cross-device operations error correctly. Test that the fallback diagnostics are actionable.

**Ring 5 — Performance Regression:**
Benchmark suite tracking kernel quality and dispatch overhead separately:
- Launch overhead (empty kernel)
- Elementwise chains (with and without fusion)
- Bandwidth tests (memory-bound operations)
- GEMM across small/medium/large shapes
- Convolution
- LayerNorm, Softmax
- Attention (scaled dot product)
- End-to-end: MLP, CNN, transformer block

### CI Requirements

GPU tests require self-hosted runners with actual hardware — GitHub-hosted generic runners do not have GPUs. Each backend needs its own CI runner:
- CUDA: NVIDIA GPU runner
- ROCm: AMD GPU runner
- Metal: macOS runner with Apple Silicon
- WebGPU/Vulkan: any GPU runner (Dawn/Vulkan work on all vendors)

### Autograd Testing

Numerical gradient checking for every VJP rule: compute the analytical gradient via autograd, compute a numerical gradient via finite differences, verify they match within tolerance. This catches incorrect backward rules.

---

## 19. Tooling and Profiling

### Backend-Specific Profiling

| Backend | Profiling Integration |
|---------|----------------------|
| CUDA | Nsight Systems and Nsight Compute compatible kernel naming |
| ROCm | rocprof/rocprofiler compatible instrumentation |
| Metal | Xcode GPU frame capture and Metal profiling |
| WebGPU/Vulkan | RenderDoc compatible where supported |

### Debug Mode

In debug builds:
- WGSL shaders validated through Naga before compilation
- SPIR-V validated through SPIRV-Tools
- Bounds checks inserted in `dfn` device code
- Device assertions enabled (check for NaN, inf, out-of-bounds)
- Fusion disabled (one-op-per-dispatch for easier debugging)
- Full error messages with tensor shapes, dtypes, and device info

### Release Mode

- Validation skipped
- Bounds checks removed
- Assertions removed
- Fusion enabled
- Kernel cache used

### Profiling Hooks

All backends expose:
- Kernel names (human-readable, matching the Zap function name)
- Dispatch counts
- Per-kernel timing
- Memory allocation tracking
- Data transfer timing and bytes

---

## 20. Packaging and Distribution

### Core (Ships with Zap Stdlib)

- `lib/math.zap` — Math module
- `lib/math/backend.zap` — Math.Backend protocol
- `lib/math/cpu.zap` — Math.CPU backend
- `lib/math/vjp.zap` — VJP rules for autograd
- `src/runtime.zig` additions — Tensor, DType, Device, Storage types

No external dependencies. Works everywhere Zap works.

### Backend Packages

Each backend is its own repository with its own `build.zap` and `build.zig.zon`.

Users add a backend as a dependency:

```zap
# In build.zap:
deps: [
  {:math_webgpu, {:git, "https://github.com/zaplang/math_webgpu.zap", "v0.1.0"}}
]
```

Backend packages that include native libraries (Dawn, Vulkan loader) need a setup step to download prebuilt binaries, following the same pattern as Zap's own `zig build setup`:

```sh
cd math_webgpu
zap deps setup    # Downloads prebuilt Dawn for the host platform
```

### SDK Requirements

| Backend | User Must Install |
|---------|-------------------|
| `Math.CPU` | Nothing |
| `Math.WebGPU` | Nothing (Dawn bundled as prebuilt) |
| `Math.Vulkan` | Vulkan SDK / driver |
| `Math.CUDA` | CUDA Toolkit 12.x+ |
| `Math.ROCm` | ROCm 6.x+ |
| `Math.Metal` | Xcode (macOS only) |
| `Math.XLA` | PJRT runtime |

---

## 21. Phased Roadmap

### Phase 1 — Foundation

**Goal:** Tensor type, Math API, CPU backend, correctness test harness.

**Delivers:**
- Tensor type in Zig runtime (shape, strides, dtype, device, ARC-managed storage)
- `Math.Backend` protocol
- `Math` module with `__using__` macro and ~45 Tier 1 operations
- `Math.CPU` backend via Zig SIMD + optionally BLAS
- CPU reference correctness test suite
- `Math.VJP` module with backward rules (runs on CPU first)

**Effort:** Low-medium

**Compiler changes:** None

**Risks:** Locking in wrong tensor layout or stride convention. Mitigate by studying PyTorch and NumPy conventions.

### Phase 2 — Portable GPU

**Goal:** Cross-vendor GPU compute via WebGPU and Vulkan.

**Delivers:**
- `math_webgpu` package — `Math.WebGPU` backend via Dawn + `webgpu.h`
- `math_vulkan` package — `Math.Vulkan` backend via Vulkan compute + SPIR-V
- WGSL and SPIR-V compute shaders for all Tier 1 operations
- Elementwise fusion in both backends
- CPU fallback for unsupported ops with clear diagnostics
- Naga validation (WGSL) and SPIRV-Tools validation (SPIR-V) in debug builds
- Profiling hooks (kernel names, dispatch counts, timing)
- Prebuilt Dawn libraries per platform

**Effort:** Medium

**Compiler changes:** None

**Risks:** Dawn packaging across platforms; fusion generating invalid shaders; performance if fusion isn't aggressive enough.

### Phase 3 — Native Acceleration

**Goal:** Best-in-class performance on NVIDIA, AMD, and Apple hardware.

**Delivers (three independent packages):**

`math_cuda`:
- cuBLAS for BLAS operations
- cuDNN for convolution, attention, normalization
- CUDA Graphs for repeated workload optimization
- Pooled device memory allocator (arena-style)
- Custom PTX kernels for elementwise fusion
- Multi-GPU placement via `device: {:cuda, 0}`, `device: {:cuda, 1}`
- Nsight-compatible kernel naming

`math_rocm`:
- rocBLAS for BLAS
- MIOpen for deep learning primitives
- HIP Graphs for launch overhead reduction
- Custom AMDGCN kernels for fusion
- rocprof-compatible instrumentation

`math_metal`:
- Metal Performance Shaders for optimized primitives
- MPSGraph for graph-level execution and fusion
- Metal compute pipelines for custom operations
- Apple Silicon unified memory optimization

Also delivers:
- `Math.capture` / `Math.replay` API for graph capture
- Multi-GPU explicit placement API

**Effort:** Medium-high per backend (fully parallelizable — different teams can work on each)

**Compiler changes:** None

**Risks:** SDK version skew; vendor library API changes; requires hardware-specific CI runners.

### Phase 4 — Device Functions and Custom Kernels

**Goal:** Let users write GPU kernels in Zap via `dfn`.

**Delivers:**
- `dfn` macro in each backend's `__using__`
- Restricted subset validation in each backend's macro
- Per-backend lowering:
  - CUDA: `dfn` → ZIR → LLVM NVPTX → PTX → CUDA driver loading
  - ROCm: `dfn` → ZIR → LLVM AMDGPU → HSACO → HIP module loading
  - WebGPU: `dfn` → WGSL emission → Dawn pipeline compilation
  - Vulkan: `dfn` → SPIR-V emission → Vulkan pipeline compilation
  - Metal: `dfn` → MSL emission → Metal pipeline compilation
  - CPU: `dfn` → normal Zig function (loop)
- Kernel cache (compiled kernels cached on disk)
- GPU intrinsics namespace (`gpu.global_id`, `gpu.barrier`, etc.)
- Shared memory declarations (`shared buffer :: [256]f32`)
- `TensorView(dtype)` type for device-side tensor access
- `Math.launch` for dispatching device functions from host code

**Effort:** High

**Compiler changes:** None — `dfn` is a macro provided by backend packages

**Risks:** ZIR-to-device-code path maturity in the Zig fork; debugging device-side crashes; initial kernel performance won't match hand-tuned vendor code.

### Phase 5 — Advanced

**Goal:** Autograd, comprehensive operation coverage, and optional graph compiler interop.

**Delivers (each sub-feature independently shippable):**

- **Autograd:** Functional trace-and-replay with VJP rules, `Math.trace`, `Math.grad`
- **Time-travel debugging:** Inspect any intermediate tensor via the trace
- **Gradient checkpointing:** `Math.trace(computation, checkpoint_every: N)` for memory-constrained deep computations
- **Tier 2 operations:** Full linalg, advanced shape ops, sorting, FFT
- **Tier 3 operations:** Conv 1d/2d/3d, pooling, normalization, attention, loss functions
- **Complex dtypes:** `complex64`, `complex128`
- **Sparse tensors:** `sparse_tensor`, `sparse_matmul`, `to_sparse`, `to_dense`
- **`math_xla` package:** StableHLO export/import, PJRT execution for advanced graph optimization
- **Graph partitioning:** Clear diagnostics when ops fall back to CPU, strict mode that errors instead

**Effort:** High (but each component ships independently)

**Compiler changes:** None

**Risks:** Scope creep; autograd correctness (mitigate with numerical gradient checking); StableHLO/PJRT build complexity.

### Parallelism

```
Phase 1 ──────────────────────────────────►
                 Phase 2 ─────────────────────────────────►
                 Phase 3a (CUDA) ─────────────────────────►
                 Phase 3b (ROCm) ─────────────────────────►
                 Phase 3c (Metal) ────────────────────────►
                          Phase 4 (prototype) ────────────►
                                    Phase 5a (autograd) ──►
                                    Phase 5b (Tier 2 ops) ►
                                    Phase 5c (Tier 3 ops) ►
                                    Phase 5d (XLA interop) ►
```

- Phases 2 and 3 run in parallel with Phase 1
- Within Phase 3, all three backends are fully independent
- Phase 4 prototyping can begin once any one GPU backend exists
- Phase 5 components are independently shippable

---

## 22. What This Preserves

### "Features in Zap code, not the compiler"

Math, Tensor, Math.Backend, Math.CPU, Math.VJP, autograd, `dfn`, and all backend packages are Zap modules and Zig runtime code. The Zap compiler knows nothing about numerical computing, tensors, GPU, device functions, or differentiation. Zero compiler changes across all five phases.

### No hardcoded module names

The compiler has no special knowledge of Math, Tensor, or any backend. Backend packages are regular Zap dependencies discovered through normal module import resolution.

### No workarounds or hacks

Each backend is the correct, production-grade implementation for its hardware:
- CUDA backend uses cuBLAS/cuDNN — the gold standard for NVIDIA
- ROCm backend uses rocBLAS/MIOpen — the gold standard for AMD
- Metal backend uses MPS/MPSGraph — Apple's optimized path
- WebGPU backend uses Dawn — Google's production implementation
- Vulkan backend uses direct Vulkan compute — maximum control

### Zap's functional identity

Immutability, purity, and the pipe operator make tensor code readable and composable. Autograd exploits purity rather than fighting mutation — the trace is correct by construction because the language guarantees it. Perceus and ARC integrate naturally with the trace mechanism through standard reference counting. The `dfn` macro enables device code while keeping it clearly separated from host code through the restricted subset.

### Explicit over implicit

Device placement is explicit. Data transfer is explicit. Backend selection is explicit (compile-time, per-module). Fallback diagnostics are explicit. The user always knows where their data lives, which backend is executing, and what operations are running on which device.

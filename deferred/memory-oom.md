# OutOfMemory During ZIR Compilation Linking Phase

## What We're Trying to Do

Zap compiles `.zap` source files to native binaries by:

1. Parsing Zap source through the Zap frontend (parse → collect → macro →
   desugar → type check → HIR → IR)
2. Lowering the IR to Zig's ZIR (Zig Intermediate Representation)
3. Injecting the ZIR into a Zig `Compilation` via the forked Zig compiler
   at `~/projects/zig`
4. Running Zig's Sema (semantic analysis) + codegen + linker to produce
   a native binary

This pipeline works through C-ABI functions exported from
`libzig_compiler.a`:
- `zir_compilation_create` — creates a Zig compilation context
- `zir_compilation_add_zir` / `zir_builder_inject` — injects ZIR
- `zir_compilation_update` — runs Sema + codegen + link
- The output is a native MachO binary on macOS aarch64

## Where The OOM Occurs

The OOM happens inside `Compilation.update()` during the **linking phase**,
after codegen has completed successfully.

The call chain:
```
zir_compilation_update (zir_api.zig)
  → ctx.compilation.update(prog_node) (Compilation.zig:2894)
    → performAllTheWork()  ← codegen happens here (succeeds)
    → flush()              ← linker runs here
      → llvm_object.emit() ← LLVM emits .o file
      → lf.flush()         ← MachO linker links .o → binary
        → classifying input file libSystem.tbd  ← OOM HERE
```

## What We Know

### The compilation DOES succeed through codegen

Debug output confirms Zap code is compiled:
```
debug(wip-mir):   %3 = call(... (function 'println__anon_2285')>, [<*const [6:0]u8, "Howdy!">])
debug(tracking): $1 <- <*const [6:0]u8, "Howdy!">
debug(codegen): generateSymbol: val = "Howdy!".*
```

The Zap program's `IO.puts("Howdy!")` call is compiled to native code.
The LLVM backend processes it successfully. Symbol generation works.

### The OOM happens during MachO linking

After codegen, the linker starts:
```
debug(link): classifying input file /Applications/Xcode.app/.../libSystem.tbd
zir_api: update failed: OutOfMemory
```

The MachO linker is parsing `libSystem.tbd` (Apple's text-based
definition file for the system library) when OOM occurs.

### The system has plenty of RAM

```
Pages free: 108262 (× 16384 = ~1.7GB free)
```

The OOM is NOT from actual memory exhaustion. It's a spurious OOM from
some code path that returns `error.OutOfMemory` for a non-memory reason.

### Error details

- `Compilation.update()` throws `error.OutOfMemory`
- `getAllErrorsAlloc()` returns an error bundle with 0 messages
- No link diagnostic flags are set (no `no_entry_point_found`, etc.)
- No link diagnostic messages exist
- `@errorReturnTrace()` returns null (no stack trace available)

## What We've Already Fixed

### Phase 1: 9 Sema errors from page_allocator

The Zap runtime (`runtime.zig`) originally used `std.heap.page_allocator`
for string concat, arg parsing, and env var access. The ZIR builder
emitted `std.heap.page_allocator` references in the generated code.

The Zig self-hosted backend couldn't handle operations used by
`page_allocator`, `std.ArrayList`, and `std.math`:
- `mul_with_overflow` — used by std.math
- `ptr_slice_len_ptr` — used by ArrayList (5 occurrences)
- `ptr_slice_ptr_ptr` — used by ArrayList (4 occurrences)
- `cmpxchg_strong` — used by PageAllocator

**Fix applied:** Replaced all `page_allocator` usage with:
- Static bump allocator (`bumpAlloc`) for string operations
- `ZapString.concatBump` — no allocator parameter
- `std.os.argv` directly instead of `std.process.argsAlloc`
- `std.c.getenv` instead of `std.process.getEnvVarOwned`
- `std.fmt.bufPrint` instead of `std.fmt.allocPrint`
- Fixed-size arrays for the atom table instead of `std.StringHashMap`

All 9 errors eliminated. Codegen now completes successfully.

### Phase 2: Error visibility

The 9 errors were originally invisible because:
- `ErrorBundle.renderToStdErr` produced no output
- `renderToWriter` uses `std.debug.lockStderrWriter` which conflicted
  with the debug logging

**Fix applied:** Added `dumpErrorBundle` function that uses
`deprecatedWriter()` and manually iterates the error bundle via
`eb.getMessages()` / `eb.getErrorMessage()` / `eb.nullTerminatedString()`.

### Phase 3: Allocator and threading tuning

- Replaced `std.heap.page_allocator` with `std.heap.c_allocator` in
  `zir_api.zig`'s `createImpl` — `page_allocator` creates one mmap per
  allocation, hitting the kernel's per-process VM map entry limit before
  physical memory runs out (documented in Zig Issue #18775)
- Capped thread pool at 4 threads (was CPU count) to reduce concurrent
  memory pressure from MIR codegen
- Set `root_strip = true` to reduce codegen work

None of these fixed the OOM. The error persists regardless of allocator
choice or thread count.

## What We Haven't Investigated

### TBD file parsing

The OOM occurs during `classifying input file libSystem.tbd`. Apple's
TBD (text-based definition) files are YAML-like files that describe
dynamic library symbols. The MachO linker parses them to resolve symbol
references. This parsing might have a bug that causes OOM.

Location in code: `src/link/MachO.zig` in the `flush` function, during
the input file classification and loading phase (lines 362-488).

The TBD parser lives in `src/link/LdScript.zig` or Apple-specific parsing
code within `src/link/MachO/`.

### Whether `link_libc = false` avoids the OOM

If the TBD parsing is the source, disabling libc linking might bypass it.
The Zap runtime doesn't technically need libc for basic operations (the
bump allocator and direct syscalls could work). But `IO.puts` relies on
`std.fs.File.stdout().deprecatedWriter()` which may need libc.

### Whether `skip_linker_dependencies = true` with LLVM helps

Currently: `.skip_linker_dependencies = !build_options.have_llvm`
Since `have_llvm = true`, this is `false`, meaning linker dependencies
ARE included. Setting it to `true` might skip the libc linking that
triggers the OOM, but could produce an incomplete binary.

### Whether this is a known Zig MachO linker issue

The Zig MachO linker has several known issues on macOS:
- Issue #25420: No unwind information emitted
- Issue #21719: Invalid DWARF emitted on x86_64-macos
- Issue #24080: SymbolNotFound when loading dynamic libraries
- Issue #21778: Data races in MachO linker (fixed in 0.14.0)
- PR #24124: MIR backpressure mechanism added because codegen workers
  could produce GBs of MIR faster than the linker consumed it

### Whether the OOM is actually from LLVM

The `llvm_object.emit()` call at Compilation.zig:3337 can return
`OutOfMemory`. If LLVM's internal C++ allocator fails (via `new` or
`malloc`), this gets translated to Zig's `error.OutOfMemory`. LLVM
processing of complex functions (like `defaultPanic.unwrapError`) with
many branches could trigger this.

### Whether running with our fork's lib directory changes anything

The compilation currently uses the SYSTEM Zig's standard library
(`/Users/bcardarella/.asdf/installs/zig/0.15.2/lib/`) not our fork's
(`/Users/bcardarella/projects/zig/lib/`). Our fork has modifications to:
- `lib/std/start.zig` — builder runtime support
- `src/link/MachO.zig` — segment ordering fix

Setting `ZAP_ZIG_LIB_DIR=/Users/bcardarella/projects/zig/lib` uses
the fork's lib, but the OOM still occurs.

## Architecture Context

### The Zig fork

Location: `~/projects/zig` (branch `zap-zir-library`)
Based on Zig 0.15.2 (commit `e4cbd752`)

Key modifications:
- `src/zir_api.zig` — C-ABI surface for ZIR compilation
- `src/zir_builder.zig` — ZIR instruction builder
- `lib/std/start.zig` — builder runtime for `zap_builder_entry`
- `src/link/MachO.zig` — segment re-sort after section attachment

Build: `zig build lib` produces `zig-out/lib/libzig_compiler.a`

### The Zap compiler

Location: `~/projects/zap`

Links against `libzig_compiler.a`. The `zap` binary is built with the
SYSTEM Zig compiler (0.15.2) but links our fork's library.

Key files:
- `src/zir_builder.zig` — Zap IR → ZIR instruction emission
- `src/zir_backend.zig` — C-ABI wrapper for compilation
- `src/runtime.zig` — embedded runtime (string ops, atom table, I/O)
- `src/main.zig` — CLI and build pipeline
- `src/builder.zig` — build.zap AST extraction
- `src/compiler.zig` — reusable frontend pipeline

### How the binary is produced

1. Zap frontend produces `ir.Program` (list of functions with instructions)
2. `zir_builder.zig` walks each function and emits ZIR instructions via
   C-ABI calls to the forked Zig's builder
3. `zir_builder_inject` replaces the root module's ZIR with the emitted
   instructions
4. `zir_compilation_update` runs Zig's Sema on the injected ZIR, then
   LLVM codegen, then MachO linking
5. The output is written to disk at the specified path

The ZIR injection replaces a "stub" source file (`"pub fn main() void {}"`)
with Zap's generated functions. The stub exists so the Zig compilation has
a valid root module before injection.

## Specific Findings from Research

### Zig Issue #18775 (spurious OOM from page_allocator)

`GeneralPurposeAllocator` wrapping `page_allocator` returns
`error.OutOfMemory` when the process hits the kernel's per-process VM
map entry limit, NOT when physical memory is exhausted. Each `mmap` call
creates a new VM map entry. Thousands of small allocations from
`page_allocator` exhaust the entry limit while using minimal actual RAM.

We switched to `c_allocator` (libc malloc) which doesn't have this
issue. The OOM persists, so this isn't the cause.

### Zig PR #24124 (MIR backpressure)

The threaded codegen rework added backpressure because unlucky scheduling
caused GBs of MIR to accumulate in queues. The main thread now pauses
until functions in flight are processed. This is relevant because our
compilation creates a thread pool with up to 4 threads.

We capped threads at 4. The OOM persists.

### Compilation.update() error flow

From Compilation.zig:
1. `update()` calls `performAllTheWork()` — runs Sema + codegen
2. If errors exist, `update()` returns early before `flush()`
3. `flush()` calls `llvm_object.emit()` then `lf.flush()` (MachO linker)
4. `lf.flush()` does: parse inputs → resolve symbols → allocate sections
   → write sections → write linkedit → write header

The OOM occurs at step 4 during input parsing. The file is pre-created
with `.truncate = true` during `Compilation.create()`, so it exists but
is empty (all zeros) if `flush()` fails.

## What To Try Next

1. **Set `link_libc = false`** and see if the OOM disappears. If it does,
   the TBD parsing is the culprit. The runtime would need to be adapted
   to work without libc.

2. **Set `skip_linker_dependencies = true`** even with LLVM available.
   This skips automatic libc linking but may produce a broken binary.

3. **Add logging inside `MachO.flush()`** in the fork to pinpoint exactly
   which allocation fails. The `flush` function has ~250 lines of linking
   logic — one of those allocations returns OOM.

4. **Try compiling a minimal Zig program** (not through ZIR injection)
   with the same Compilation API to see if the OOM is specific to ZIR
   injection or affects all compilations. If a regular Zig program also
   OOMs, the issue is in the Compilation API itself.

5. **Check if LLVM's emit() is the OOM source** by adding a log after
   `llvm_object.emit()` and before `lf.flush()` in `Compilation.flush()`.

6. **Try on a Linux machine** to rule out macOS-specific MachO linker
   issues. If ELF linking works, the problem is macOS-specific.

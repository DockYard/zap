# Zig 0.16 Refactoring Analysis for Zap

Deep analysis of Zig 0.16 features against the entire Zap codebase (compiler + fork).

## Priority 1: Critical / High Impact

### 1. Upgrade to full `std.process.Init` (main.zig:13-21)
**Current:** `pub fn main(init: std.process.Init.Minimal) !void` with manual allocator/Io setup.
**Change:** Switch to `std.process.Init` which provides `.gpa`, `.io`, `.arena` — eliminating 8 lines of boilerplate.
**Impact:** Cleaner entry point, consistent with 0.16 idioms.

### 2. Replace `std.Thread.spawn` with `Io.Group` (lockfile.zig:310-331)
**Current:** Raw `std.Thread.spawn()` per git dependency, unbounded concurrency.
**Change:** Use `Io.Group` for structured concurrency with bounded parallelism.
**Impact:** Better resource management, cleaner error handling, consistent with 0.16 concurrency model.

### 3. Parallel file parsing via `Io.Group` (compiler.zig:268-288)
**Current:** Sequential `for` loop parsing each source unit one at a time.
**Change:** Spawn parse tasks via `Io.Group` — each parser operates on isolated source with shared `StringInterner`.
**Impact:** 2-8x speedup for multi-file projects. Parsing is embarrassingly parallel.

### 4. Parallel struct compilation via `Io.Group` (compiler.zig:837-861)
**Current:** Sequential `for (struct_order)` compiling each struct one at a time.
**Change:** Build dependency graph, compile independent structs in parallel via `Io.Group`, synchronize at dependency boundaries.
**Impact:** 2-4x speedup for projects with many independent structs.

### 5. Atomic cache writes (main.zig:987-991)
**Current:** Direct `createFile` + `writeStreamingAll` for `.zap-cache/{target}.hash` — crash between create and close corrupts cache.
**Change:** Write to `.tmp` file then atomic `rename()`.
**Impact:** Prevents cache corruption on crash/interrupt.

### 6. Replace C `gettimeofday()` with `std.time` (runtime.zig:1329-1339)
**Current:** `std.c.gettimeofday(&tv, null)` with manual C struct initialization.
**Change:** Use `std.time.nanoTimestamp()` — pure Zig, no C FFI, WASI-compatible.
**Impact:** Eliminates C dependency, better portability (especially WASM targets).

---

## Priority 2: Medium Impact

### 7. Incremental compilation in fork (zir_api.zig:752, `.cache_mode = .none`)
**Current:** Creates fresh `Compilation` every invocation, no caching.
**Change:** Set `.cache_mode` to enable Zig's incremental compilation, reuse `Compilation` state.
**Impact:** 10-50x speedup for iterative development (e.g., `--watch` mode).

### 8. In-memory stubs instead of disk writes (zir_api.zig:707-713)
**Current:** Writes `pub fn main() void {}\n` stub to `.zap-cache/{name}.zig` on every compilation.
**Change:** Use in-memory buffer instead of disk I/O for the stub source.
**Impact:** ~5-10% speedup per compilation, eliminates unnecessary disk writes.

### 9. `Batch` for concurrent source file reads (main.zig:773-838)
**Current:** Sequential `for` loop reading/validating each source file.
**Change:** Use `Io.Batch` to issue concurrent file opens, mmaps, and validations.
**Impact:** 2-8x speedup for file I/O phase on large projects.

### 10. Build cancelation in watch mode (main.zig:1091-1143)
**Current:** `watchAndRebuild()` waits for full build to complete before checking for new changes.
**Change:** Run build in cancelable `Io.Group` task, cancel on new file change detection.
**Impact:** Instant feedback in `--watch` mode when files change during compilation.

### 11. `Queue(T)` for ZIR struct batching (zir_api.zig:142-149)
**Current:** `zir_compilation_add_zir()` and `zir_compilation_update()` are synchronous.
**Change:** Queue ZIR injections, then run single Sema pass on all queued structs.
**Impact:** Reduces N Sema passes to 1 for N structs.

### 12. ArenaAllocator `resetRetainingCapacity()` (runtime.zig:69-74)
**Current:** `resetAllocator()` calls `a.deinit()` then sets to `null`, forcing full reallocation.
**Change:** Use `a.resetRetainingCapacity()` to reuse memory pools.
**Impact:** Faster arena resets, less allocation pressure.

### 13. Test timeouts in build.zig (build.zig:40, 261)
**Current:** No timeout configuration on test steps.
**Change:** Add `.test_timeout` to prevent CI hangs (especially ZIR integration tests).
**Impact:** CI reliability.

---

## Priority 3: Polish / Optimization

### 14. Accept `Io` from caller in fork (zir_api.zig:599-614)
**Current:** Fork creates its own `Io.Threaded` per `ZirContext`.
**Change:** Add `zir_compilation_create_with_io()` that accepts an external `Io` instance.
**Impact:** Resource pooling when creating multiple `ZirContext` instances.

### 15. `Io.Group` for parallel Sema in fork (zir_api.zig:153-157)
**Current:** `zir_compilation_update()` runs Sema sequentially.
**Change:** Use `Io.Group` to parallelize Sema analysis across multiple ZIR structs.
**Impact:** 2-4x speedup for multi-struct compilations.

### 16. `@Struct()/@Union()/@Enum()` for ZIR type emission (zir_builder.zig:1070-1114)
**Current:** Manual field-by-field marshaling via C-ABI arrays for union/struct return types.
**Change:** Generate ZIR that uses the new `@Union()`, `@Struct()`, `@Enum()` builtins directly.
**Impact:** Simpler code, better type safety, eliminates manual field packing.

### 17. `std.mem.cut()` for string operations (runtime.zig:752-1131)
**Current:** Manual index-based slicing for string operations.
**Change:** Use `std.mem.cut()` where applicable for cleaner split/extract patterns.
**Impact:** Code clarity.

### 18. PerThread.Id pooling (zir_api.zig:610)
**Current:** Allocates `PerThread.Id` per context creation.
**Change:** Check for existing global pool, reuse across multiple `ZirContext` instances.
**Impact:** Allocation savings for multiple compilations.

### 19. Deflate compression for cache artifacts (main.zig:843-876)
**Current:** Uncompressed cache files in `.zap-cache/`.
**Change:** Use `std.compress.deflate` to compress cached merged sources.
**Impact:** Smaller cache directory, especially for large projects.

### 20. `Io.Batch` for discovery file reads (discovery.zig:144)
**Current:** Sequential `readFileAlloc` in struct discovery loop.
**Change:** Batch all file reads for discovered structs simultaneously.
**Impact:** 2-4x speedup for struct discovery phase.

---

## Already Correct / No Changes Needed

- **std.Io.Dir/File APIs** — Already migrated throughout codebase
- **std.process.spawn/run** — Already using 0.16 signatures
- **File.MemoryMap** — compiler.zig MappedFile implementation is correct
- **build.zig Io usage** — Already uses `b.graph.io` correctly
- **Error set handling** — Using abstract error sets that auto-adapt
- **@cImport** — Not used anywhere
- **Float builtins** — Already using `@intFromFloat`/`@floatFromInt` correctly

---

## Implementation Plan

| Phase | Items | Files | Estimated Impact |
|-------|-------|-------|-----------------|
| **Phase 1: Foundation** | #1 Process.Init, #5 Atomic writes, #6 std.time, #12 Arena reset, #13 Test timeouts | main.zig, runtime.zig, build.zig | Code quality + correctness |
| **Phase 2: Parallelism** | #2 Io.Group deps, #3 Parallel parsing, #4 Parallel structs, #9 Batch file reads | lockfile.zig, compiler.zig, main.zig | 2-8x compilation speedup |
| **Phase 3: Fork** | #7 Incremental compilation, #8 In-memory stubs, #11 Queue batching, #14 Io passthrough | zir_api.zig | 5-50x iterative speedup |
| **Phase 4: Advanced** | #10 Build cancelation, #15 Parallel Sema, #16 @Struct builtins, #20 Batch discovery | main.zig, zir_api.zig, zir_builder.zig | Architecture improvements |

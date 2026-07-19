# Zig 0.16 Deferred Items — Deep Implementation Research

## 1. Parallel File Parsing (Io.Group + StringInterner)

**Recommended approach: Per-parser local interners with post-parse merge.**

The `StringInterner` is a `StringHashMap` + `ArrayList` that every parser writes to during `intern()` (17 call sites per parse). Making it thread-safe via mutex would create heavy contention.

**Implementation:**
1. Each parser creates its own local `StringInterner` via `Parser.init` (not `initWithSharedInterner`)
2. Parse all files in parallel with `std.Thread.spawn` (no Io needed) or `Io.Group`
3. After all threads join, merge interners:
   - Create fresh global interner
   - For each local interner, build a `remap: []StringId` table (old local ID → new global ID)
   - Walk each parsed AST and remap all StringId fields

**Key insight:** Zero changes to `parser.zig` or `ast.zig`. The only new code is:
- `buildInternerRemap()` — O(total unique strings)
- `remapProgram()` — walks AST nodes replacing StringId fields

**Risk:** The AST remap must cover every node type containing StringId (StructName.parts, FunctionDecl.name, VarRef, StringLiteral, AtomLiteral, Attribute, etc.). This is mechanical but must be thorough.

**Files:** `src/compiler.zig` lines 267-288

---

## 2. Parallel Struct Compilation (Io.Group + Dependency Levels)

**Approach: Level-by-level parallel compilation using topological sort depth.**

The current `compileStructByStruct` iterates structs sequentially. Structs at the same dependency depth are independent and can compile in parallel.

**Shared state hazards identified:**
- `TypeChecker` writes `graph.bindings.items[id].type_id` (types.zig:1002,1011) — each struct writes to non-overlapping indices, but needs isolation for safety
- `DiagnosticEngine` — not thread-safe, needs per-struct collection
- `ctx.interner` and `ctx.collector.graph` — read-only during compilation, safe for concurrent access
- CTFE may write computed values — safe within a dependency level (no cross-deps)

**Implementation:**
1. Modify `discovery.zig` topologicalSort to output `level_boundaries` (where each depth level starts)
2. Create `PerStructResult` struct with per-struct IR, diagnostics, errors
3. Process level-by-level: `Io.Group` for structs at same depth, sequential between levels
4. Merge IR results after each level completes
5. Thread `Io` through the compilation pipeline (main.zig → compiler.zig)

**Expected speedup:** For N structs across M levels, time reduces from O(N) to O(M). A 20-struct project with 4 levels → ~4-5x speedup.

**Files:** `src/compiler.zig` lines 822-872, `src/discovery.zig` lines 372-436

---

## 3. File.MemoryMap Replacement

**Confirmed: `std.Io.File.MemoryMap` exists as a public API in Zig 0.16.**

Location: `std/Io/File/MemoryMap.zig`, accessed via `std.Io.File.MemoryMap`

**Key API:**
- `file.createMemoryMap(io, .{ .len = size, .protection = .{ .read = true, .write = false } })`
- `mm.destroy(io)` for cleanup
- `mm.memory` — the mapped `[]align(page_size_min) u8`

**Cross-platform:** POSIX uses `mmap(MAP.SHARED)`, Windows uses `NtCreateSection+NtMapViewOfSection`, fallback uses `rawAlloc+read`

**Caveats:**
- Empty files (len=0) must be handled by caller — mmap rejects zero-length
- `deinit` requires `Io` parameter (signature change from current `MappedFile.deinit()`)
- Uses `MAP.SHARED` vs current `MAP.PRIVATE` — identical for read-only access
- File handle must stay open for mapping lifetime

**Impact:** Replaces ~80 lines of manual platform detection + posix.mmap + munmap with ~40 lines using stdlib.

**Files:** `src/compiler.zig` lines 135-221

---

## 4. Fork c_allocator/threadlocal Crashes — Root Cause

**Root cause: ABI mismatch from `-Dtarget=aarch64-macos-none`.**

The fork library is cross-compiled with the `none` ABI, then linked into a native macOS binary. This ABI boundary causes two specific failures:

**c_allocator crash:** The `c_allocator` implementation checks `c.max_align_t` to decide between `malloc` and `posix_memalign`. The `none` ABI defines different `max_align_t` than the native macOS ABI, causing wrong alignment decisions and corrupted allocations. `page_allocator` works because `mmap` is ABI-stable.

**threadlocal crash:** macOS implements `threadlocal` via TLV (Thread Local Variable) descriptors in Mach-O sections. The `none` ABI emits TLS relocations that don't match what the native macOS `dyld` expects, causing crashes on first access. Plain `var` globals work because they live in `.bss`/`.data` sections with no special linker requirements.

**Safe fix for capture state:** Move the capture fields into the `Builder` struct in `zir_builder.zig`:
```zig
pub const Builder = struct {
    // ... existing fields ...
    capture_bufs: [16]std.ArrayListUnmanaged(u32) = ...,
    capture_saved_tracking: [16]bool = ...,
    capture_saved_non_body: [16]?*std.ArrayListUnmanaged(u32) = ...,
    capture_depth: u32 = 0,
};
```
Then update `begin_capture`/`end_capture` in `zir_api.zig` to use `b.capture_bufs` instead of globals. This is naturally thread-safe (each Builder owns its state) with no TLS or mutex needed.

**Files:** `~/projects/zig/src/zir_api.zig` lines 1555-1613, `~/projects/zig/src/zir_builder.zig`

---

## 5. Incremental ZirContext for Watch Mode

**Confirmed: `Compilation.update()` is designed for multiple calls.** It calls `clearMiscFailures()`, resets cache state, and increments the generation counter.

**Key findings:**
- `CacheMode.incremental` enables persistent artifact dirs and linker patching
- ZIR re-injection works — `addZirImpl` frees old ZIR before injecting new (line 858)
- InternPool persists across updates (only freed in `Zcu.deinit()`)
- Struct registrations are idempotent (`import_table.getOrPut`)

**Critical gap: `prev_zir` for injected files.** Normal files save `file.zir` → `file.prev_zir` during AstGen, enabling `updateZirRefs` to diff old vs new ZIR. For `zir_injected` files, this never happens (AstGen is skipped at PerThread.zig:371). Without `prev_zir`, the compiler can't determine what changed.

**Proposed new C-ABI functions:**
1. `zir_compilation_create_incremental(...)` — creates context with `.cache_mode = .incremental`
2. `zir_compilation_prepare_update(ctx)` — saves `file.zir` → `file.prev_zir` for all injected files
3. `zir_compilation_invalidate_file(ctx, name)` — marks a struct for re-analysis

**Proposed watch mode flow:**
```
Initial:  create_incremental → add_structs → build_zir → inject → update → run
On change: prepare_update → re-parse changed files → re-inject ZIR → update → run
Shutdown: destroy
```

**Zap-side changes:**
- Split `zir_backend.compile()` into `createContext()` + `updateContext()`
- `watchAndRebuild` creates ZirContext once, reuses across rebuilds
- Track which files changed, only re-parse/re-lower those

**Files:** `~/projects/zig/src/zir_api.zig`, `src/zir_backend.zig`, `src/main.zig`

---

## Implementation Priority

| Item | Complexity | Impact | Dependencies |
|------|-----------|--------|-------------|
| Move capture state to Builder | Low | Correctness | None |
| File.MemoryMap replacement | Low | Code quality | None |
| Parallel file parsing | Medium | 2-8x parse speedup | AST remap function |
| Parallel struct compilation | High | 2-5x compile speedup | Discovery level boundaries, Io threading |
| Incremental ZirContext | High | 10-50x watch speedup | Fork changes + rebuild |

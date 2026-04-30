# Zig 0.16 Feature Integration Plan

## Implementation Order (dependency-aware)

### Phase 1: Foundation (enables everything else)
1. ~~**Lock-free Arena Allocator**~~ ✅ Done — Using `.retain_capacity` in runtime.zig
2. ~~**Parallel Compilation**~~ ✅ Done — `Io.Group` in compiler.zig + analysis_pipeline.zig
3. ~~**Incremental Build Watch**~~ ✅ Done — IncrementalWatchState with prepareUpdate/invalidateFile

### Phase 2: Data Structures & Performance
4. **HAMT for Zap Maps** — Persistent hash array mapped trie replacing linear arrays
5. **Lazy Type Emission** — Collapse 3-layer type pipeline to 2 layers (Zig 0.16 lazy field analysis helps)
6. ~~**Memory-Mapped Source Reading**~~ ✅ Done — `std.Io.File.MemoryMap` in compiler.zig

### Phase 3: Test Framework Completion
7. **Struct.functions/1** — Compile-time reflection for function discovery
8. ~~**Seed-Based Test Ordering**~~ ✅ Done — TestTracker with Io.Timestamp seed

### Phase 4: Advanced Features
9. **@Struct/@Union/@Enum Builtins** — Dynamic type construction in ZIR (fork exports ready)
10. ~~**Parallel Dependency Fetching**~~ ✅ Done — `Io.Group` in lockfile.zig
11. **WebAssembly Target** — WASM backend support

### Phase 5: Standard Library Expansion (NEW — Zig 0.16 builtins)
12. ~~**Math Struct**~~ ✅ Done — sqrt, sin, cos, tan, exp, log via Zig 0.16 builtins
13. ~~**Integer Bit Operations**~~ ✅ Done — clz, ctz, popcount, byte_swap, bit_reverse
14. ~~**Saturating Arithmetic**~~ ✅ Done — add_sat, sub_sat, mul_sat
15. ~~**Float-to-Integer Conversions**~~ ✅ Done — floor_to_integer, ceil_to_integer, round_to_integer
16. **std.c.getenv Migration** — Replace with std.posix.getenv for WASM portability
17. **SIMD/Vector Types** — First-class vector operations (fork C-ABI exports ready)
18. **Type Introspection** — @size_of, @has_field, @type_name macros
19. **Io.Select Watch Mode** — Use Io.Select + cancelation for instant rebuild feedback

## Critical Files Per Feature

| Feature | Primary Files | Fork Changes? | Status |
|---------|--------------|---------------|--------|
| Arena Allocator | src/runtime.zig | No | ✅ Done |
| Parallel Compilation | src/compiler.zig, src/main.zig | No | ✅ Done |
| Incremental Watch | src/main.zig, build.zig | No | ✅ Done |
| HAMT Maps | src/runtime.zig, lib/map.zap | No | Pending |
| Lazy Type Emission | src/ir.zig, src/zir_builder.zig | Possibly | Pending |
| MemoryMap Sources | src/compiler.zig | No | ✅ Done |
| Struct.functions | src/hir.zig, lib/struct.zap | No | Pending |
| Seed Test Ordering | lib/zest/runner.zap, src/runtime.zig | No | ✅ Done |
| @Struct/@Union/@Enum | src/zir_builder.zig (fork) | Yes | Pending |
| Parallel Deps | src/main.zig, src/lockfile.zig | No | ✅ Done |
| WASM Target | build.zig, src/runtime.zig | Possibly | Pending |
| Math Struct | lib/math.zap, src/runtime.zig | No | ✅ Done |
| Integer Bit Ops | lib/integer.zap, src/runtime.zig | No | ✅ Done |
| Saturating Arithmetic | lib/integer.zap, src/runtime.zig | No | ✅ Done |
| Float Conversions | lib/float.zap, src/runtime.zig | No | ✅ Done |
| getenv Migration | src/*.zig | No | In Progress |
| SIMD/Vector | lib/vector.zap, src/zir_builder.zig | No | Pending |
| Type Introspection | lib/kernel.zap, src/runtime.zig | No | Pending |
| Io.Select Watch | src/main.zig | No | Pending |

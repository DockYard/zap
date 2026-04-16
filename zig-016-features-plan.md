# Zig 0.16 Feature Integration Plan

## Implementation Order (dependency-aware)

### Phase 1: Foundation (enables everything else)
1. **Lock-free Arena Allocator** — Replace runtime bump allocator, enables parallel phases
2. **Parallel Compilation** — `Io.Group` for parsing, per-module type checking
3. **Incremental Build Watch** — `zap build --watch` leveraging `-fincremental`

### Phase 2: Data Structures & Performance
4. **HAMT for Zap Maps** — Persistent hash array mapped trie replacing linear arrays
5. **Lazy Type Emission** — Collapse 3-layer type pipeline to 2 layers
6. **Memory-Mapped Source Reading** — `File.MemoryMap` for source files

### Phase 3: Test Framework Completion
7. **Module.functions/1** — Compile-time reflection for function discovery
8. **Seed-Based Test Ordering** — Deterministic shuffled test execution

### Phase 4: Advanced Features
9. **@Struct/@Union/@Enum Builtins** — Dynamic type construction in ZIR
10. **Parallel Dependency Fetching** — `Io.Group` for git dep fetches
11. **WebAssembly Target** — WASM backend support

## Critical Files Per Feature

| Feature | Primary Files | Fork Changes? |
|---------|--------------|---------------|
| Arena Allocator | src/runtime.zig | No |
| Parallel Compilation | src/compiler.zig, src/main.zig | No |
| Incremental Watch | src/main.zig, build.zig | No |
| HAMT Maps | src/runtime.zig, lib/map.zap | No |
| Lazy Type Emission | src/ir.zig, src/zir_builder.zig | Possibly |
| MemoryMap Sources | src/compiler.zig | No |
| Module.functions | src/hir.zig, lib/module.zap | No |
| Seed Test Ordering | lib/zest/runner.zap, src/runtime.zig | No |
| @Struct/@Union/@Enum | src/zir_builder.zig (fork) | Yes |
| Parallel Deps | src/main.zig, src/lockfile.zig | No |
| WASM Target | build.zig, src/runtime.zig | Possibly |

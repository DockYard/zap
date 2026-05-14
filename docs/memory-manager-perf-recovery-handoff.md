# Memory Manager Adapter Handoff

This note records the current memory-manager integration model after the
adapter migration. The older perf-recovery handoff described a manager-specific
compiler table and a separate path for built-in managers; that model is retired.
The normative ABI and resolver documentation now lives in
`docs/memory-manager-abi.md`.

## Current Model

Zap selects the active memory manager from `Zap.Manifest.memory`:

```zap
pub struct Zap.Manifest {
  name :: String
  version :: String
  kind :: Atom
  memory :: Memory.Manager = Memory.ARC
}
```

The selected value is an implementation of the `Memory.Manager` protocol. The
compiler evaluates the adapter methods during manifest CTFE:

- `name/1` returns the public manager name used in diagnostics.
- `primitive_source_path/1` returns the source reference for the primitive Zig
  implementation.
- `capability_mask/1` returns the manager's declared ABI capability mask.
- `refcount_v1?/1` reports whether the refcount v1 extension is intentionally
  provided by the adapter.

First-party and third-party managers use the same path. A first-party adapter
returns a `zap:` source reference; a project adapter returns a `project:`
reference; dependency adapters return `dep:<name>:` references. See
`docs/memory-manager-abi.md` for the exact resolution rules.

## Build Pipeline

For every user binary:

1. `src/builder.zig` evaluates `build.zap` with CTFE and extracts the selected
   `Memory.Manager` adapter metadata through protocol calls.
2. `src/memory/driver.zig` resolves `primitive_source_path/1` using the generic
   source-reference resolver.
3. The selected primitive source is compiled through the validation pipeline
   for every manager, including Zap stdlib managers.
4. The `.zapmem` section is parsed and validated against the adapter metadata.
5. `src/zir_backend.zig` registers the selected source as the
   `zap_active_manager` Zig module for the user binary.
6. `src/runtime.zig` imports `zap_active_manager` and dispatches through generic
   capability markers, not manager names.

The runtime still keeps the hot-path source-level import that recovered the
previous dispatch regression, but selection is no longer based on a compiler
table. Any third-party manager that implements `Memory.Manager`, supplies a
valid source reference, and exports a valid `.zapmem` section can take the same
integration path.

## Invariants

- The compiler must not encode Zap memory-manager struct names.
- The adapter protocol is the source of truth for public manager name,
  primitive source location, and declared capabilities.
- Every selected manager source is validated through the same object/section
  path before it is registered as `zap_active_manager`.
- The adapter value shape keeps the future API open for per-process overrides,
  for example `Process.spawn(memory: Memory.GC)`, without adding process support
  now.
- Runtime capability dispatch is based on validated capability bits and generic
  source availability markers.

## Files To Inspect

- `lib/memory/manager.zap` — `Memory.Manager` protocol.
- `lib/memory/*.zap` — stdlib adapter implementations.
- `src/builder.zig` — manifest CTFE and adapter metadata extraction.
- `src/memory/driver.zig` — source-reference resolution and `.zapmem`
  validation.
- `src/zir_backend.zig` — registration of the selected primitive source as
  `zap_active_manager`.
- `src/runtime.zig` — generic runtime import and capability dispatch.
- `docs/memory-manager-abi.md` — normative ABI and adapter model.

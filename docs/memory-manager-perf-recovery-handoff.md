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
  memory :: Type = Memory.ARC
}
```

The selected value is a first-class type reference. The compiler instantiates
that type as an adapter value and validates that it implements the
`Memory.Manager` protocol, then evaluates one adapter method during manifest
CTFE:

- `backend/1` delegates to `:zig.Memory.backend(manager)`.

First-party and third-party managers use the same path. The adapter does not
return a public manager name, source path, or capability mask. The build driver
resolves the backend source from the adapter method's package-relative source
file (`lib/foo/bar.zap` -> `src/foo/bar/manager.zig`), then reads the
capability mask from the validated `.zapmem` section.

## Build Pipeline

For every user binary:

1. `src/builder.zig` evaluates `build.zap` with CTFE and extracts the selected
   `Memory.Manager` backend binding through `backend/1`.
2. `src/memory/driver.zig` resolves the backend source from the adapter
   method's package source location.
3. The selected backend source is compiled through the validation pipeline
   for every manager, including Zap stdlib managers.
4. The `.zapmem` section is parsed and validated as the source of truth for
   ABI capabilities.
5. `src/zir_backend.zig` registers the selected source as the
   `zap_active_manager` Zig module for the user binary.
6. `src/runtime.zig` imports `zap_active_manager` and dispatches through generic
   capability markers, not manager names.

The runtime still keeps the hot-path source-level import that recovered the
previous dispatch regression, but selection is no longer based on a compiler
table. Any third-party manager that implements `Memory.Manager`, follows the
backend source convention, and exports a valid `.zapmem` section can take the
same integration path.

## Invariants

- The compiler must not encode Zap memory-manager struct names.
- The adapter protocol exposes only the backend binding call.
- The validated `.zapmem` section is the source of truth for declared
  capabilities.
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
- `src/builder.zig` — manifest CTFE and backend binding extraction.
- `src/memory/driver.zig` — adapter-source backend resolution and `.zapmem`
  validation.
- `src/zir_backend.zig` — registration of the selected backend source as
  `zap_active_manager`.
- `src/runtime.zig` — generic runtime import and capability dispatch.
- `docs/memory-manager-abi.md` — normative ABI and adapter model.

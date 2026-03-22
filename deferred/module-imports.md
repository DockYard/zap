# Deferred: File-Based Module Import Resolution

## Status: Blocked

## What It Is

Zap needs a way for one `.zap` file to import modules defined in another
`.zap` file by name. For example, `build.zap` should be able to write
`import Zap.Env` and have the compiler resolve that to a file like
`lib/zap/env.zap`, parse it, and include its definitions.

## Why It Matters

The build system plan specifies `Zap.Env`, `Zap.Manifest`, and
`Zap.BuildOpts` as stdlib types defined in Zap source files. For the
compiled builder (Phase 3), `build.zap` must import these types to
construct structs like `%Zap.Manifest{...}` at runtime with type checking.

Without imports, these types can only be made available by:
- Prepending source text (current stdlib approach)
- Concatenating all sources into one compilation unit

Neither approach scales to a proper module system.

## Current State

The parser recognizes `import` declarations:

```zap
defmodule MyModule do
  import Logger
  import Math, only: [sqrt/1, cos/1]
end
```

The AST has `ImportDecl`:

```zig
pub const ImportDecl = struct {
    meta: NodeMeta,
    module: ModuleName,
    only: ?[]const ImportSelector,
    except: ?[]const ImportSelector,
};
```

But there is NO resolution mechanism. The compiler does not:
1. Map a module name (`Zap.Env`) to a file path (`lib/zap/env.zap`)
2. Search any directories for the file
3. Parse imported files and add them to the compilation unit
4. Track import dependencies to prevent cycles

The current stdlib (`stdlib.zig`) works by prepending raw Zap source text
before the user's source. This is a flat concatenation, not an import.

Multi-file projects (`project.zig`) discover sibling `.zap` files and
concatenate them in dependency order. This is also concatenation, not
imports.

## What Needs to Be Built

### 1. Module Name → File Path Resolution

Convention: `Zap.Env` → `lib/zap/env.zap` (or a configurable search path).
Rules:
- Split module name on `.` → path segments
- Lowercase each segment (PascalCase `Env` → `env`)
- Join with `/` and append `.zap`
- Search in a list of root directories (e.g., `["lib"]` from the manifest)

### 2. Import Processing During Compilation

During the `Collect` phase (or a new pre-collect phase):
- Walk all `import` declarations in all parsed modules
- For each unresolved import, resolve the module name to a file path
- Parse the imported file
- Add its modules/types/functions to the scope graph
- Track which files have been imported to prevent double-processing

### 3. Cycle Detection

If `A` imports `B` and `B` imports `A`, the compiler must detect and
report this clearly. The existing `DependencyGraph` in `project.zig`
already does topological sort with cycle detection — this logic can be
reused.

### 4. Search Path Configuration

The import resolver needs to know where to look for files. This comes from:
- The manifest's `paths` field (for target compilation)
- A built-in stdlib path (for `Zap.*` modules)
- The builder phase has its own search context (stdlib only, no project sources)

## Dependencies

- None — this is foundational infrastructure that other features depend on.

## Blocks

- Phase 2 (stdlib build types as importable modules)
- Phase 3 (compiled builder — needs to import Zap.Env and Zap.Manifest)
- General multi-file Zap projects with explicit imports

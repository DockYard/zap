# Deferred: Stdlib Build Types (Phase 2)

## Status: Blocked by module-imports.md

## What It Is

Define `Zap.Env`, `Zap.Manifest`, and `Zap.BuildOpts` as real Zap source
files that ship with the compiler and can be imported by `build.zap`.

## Why It Matters

The compiled builder (Phase 3) needs to construct `%Zap.Env{...}` and
`%Zap.Manifest{...}` as typed structs at runtime. Without these types
defined in importable source, the builder binary cannot type-check or
construct them.

The v1 bridge (AST extraction) sidesteps this by recognizing struct names
structurally — it looks for `%Manifest{...}` or `%Zap.Manifest{...}` in
the AST by name, not by type. This works for static extraction but not
for compiled execution.

## Planned Types

### Zap.Env

```zap
defmodule Zap do
  defstruct Env do
    target :: Atom
    os :: Atom
    arch :: Atom
    build_opts :: %{Atom => String}
  end
end
```

### Zap.Manifest

```zap
defmodule Zap do
  defstruct Manifest do
    name :: String
    version :: String
    kind :: Atom
    root :: String = ""
    asset_name :: String = ""
    paths :: [String] = []
    build_opts :: %{Atom => String | i64 | Bool | [String | i64 | Bool]} = %{}
  end
end
```

### Zap.BuildOpts

```zap
defmodule Zap.BuildOpts do
  def get_string(opts :: %{Atom => String}, key :: Atom, default :: String) :: String do
    # lookup key in opts map, return default if not found
  end

  def get_atom(opts :: %{Atom => String}, key :: Atom, default :: Atom) :: Atom do
    # parse string value as atom
  end

  def get_bool(opts :: %{Atom => String}, key :: Atom, default :: Bool) :: Bool do
    # parse "true"/"false" string
  end
end
```

## Where They Live

Planned location: embedded in the compiler binary, similar to how
`runtime.zig` is embedded via `@embedFile`. Options:

1. **Embed as Zap source text** — `@embedFile("lib/zap/env.zap")` etc.,
   prepended during builder compilation (like stdlib)
2. **Ship as files** — installed alongside the compiler, found via search path
3. **Register via C-ABI** — `zir_compilation_add_module_source` with the
   Zap source text for each type

Option 1 is simplest for v1 — embed the source and prepend it during
builder compilation. This avoids needing file-based import resolution
for the build types specifically.

Option 2 requires the full import system from `module-imports.md`.

## Current State

These types do not exist as Zap source files. The v1 bridge recognizes
`Zap.Manifest` by struct name in the AST, not by type definition.

The Zap type system supports `defstruct` with typed fields and defaults.
The ZIR backend handles `struct_init` (line 853 in zir_builder.zig).
So if these types were available, struct construction would compile.

## What Needs to Be Built

### Without Import System (Embed Approach)

1. Write the `.zap` source files for Zap.Env, Zap.Manifest, Zap.BuildOpts
2. Embed them in the compiler binary via `@embedFile`
3. During builder compilation, prepend them to the build.zap source
   (same mechanism as stdlib prepend)
4. The builder binary then has access to these types for construction
   and type checking

### With Import System

1. Write the `.zap` source files
2. Place them in a stdlib directory that the import resolver searches
3. `build.zap` uses `import Zap.Env` to bring them into scope
4. The import resolver finds and includes them automatically

## Dependencies

- **Without imports**: None — can be done by embedding source text
- **With imports**: Requires `module-imports.md`

## Blocks

- Phase 3 (compiled builder needs typed Zap.Env and Zap.Manifest)

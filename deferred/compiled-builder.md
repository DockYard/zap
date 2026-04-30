# Deferred: Compiled Builder Execution (Phase 3 Full)

## Status: Blocked by runtime capabilities

## What It Is

Compile `build.zap` as a real Zap program into a native binary, execute it,
pass `Zap.Env` as command-line arguments, and capture the returned
`Zap.Manifest` as structured output on stdout.

This replaces the v1 bridge (AST extraction) which statically reads
manifest data from the AST without executing any code.

## Why It Matters

The AST extraction bridge handles static manifests — struct literals with
string/atom/list values and case expressions matching atom patterns. It
cannot handle:

- **Computed values**: `version: read_file("VERSION")`
- **Environment-dependent logic**: `if env("CI") do ... end`
- **Helper function calls**: `deps: shared_deps() ++ extra_deps()`
- **Complex conditionals**: nested case/if with non-trivial logic
- **File reads**: reading config files to influence the manifest

For simple projects the bridge is sufficient. For real-world projects with
dynamic configuration, the compiled builder is necessary.

## Current State

### What Works (ZIR Backend Coverage)

The ZIR backend already handles all IR instructions needed for `build.zap`:

| Feature | IR Instruction | ZIR Handler | Status |
|---|---|---|---|
| Struct construction | `struct_init` | Line 853 | Handled |
| Field access | `field_get` | Line 879 | Handled |
| Case expressions | `case_block` | Line 648 | Handled |
| Atom matching | `match_atom` | Line 930 | Handled |
| Map construction | `map_init` | Line 803 | Handled |
| List construction | `list_init` | Line 776 | Handled |
| String concat | `binary_op` (.concat) | Line 431 | Handled |
| Named calls | `call_named` | Line 492 | Handled |
| If/else | `if_expr` | Line 641 | Handled |

The language constructs compile through ZIR.

### What's Resolved

**Input mechanism**: `main/1` with `[String]` is implemented. The builder
binary receives env data as command-line arguments. The `zap` CLI spawns:

```
.zap-cache/builder foo_bar macos aarch64 -Doptimize=release_fast
```

The wrapper main parses `args` to construct `Zap.Env`.

### What's Missing

## Blocker 1: No Struct-to-String Serialization

The builder binary needs to output `Zap.Manifest` fields as text to stdout
so the `zap` CLI can parse them.

**Current state**: Zap has:
- `IO.puts(string)` — prints a string to stdout
- `<>` operator — concatenates two strings

Zap does NOT have:
- Integer-to-string conversion (`to_string(42)` → `"42"`)
- Atom-to-string conversion (`to_string(:bin)` → `"bin"`)
- Any form of string interpolation
- Struct field iteration

**What's needed**: Runtime functions for type conversion:
```zig
pub fn atom_to_string(atom: EnumLiteral) []const u8 { ... }
pub fn int_to_string(value: i64) []const u8 { ... }
```

Or a higher-level approach: a Zig runtime function `serialize_manifest`
that takes the raw struct fields and outputs key=value lines. The generated
wrapper main would call this directly rather than having Zap code do
serialization.

**Simplest path**: A Zig runtime function that receives the manifest struct
via comptime field iteration and prints key=value lines to stdout. The
wrapper main calls this after `manifest(env)` returns.

## Blocker 2: Stdlib Build Types

`Zap.Env` and `Zap.Manifest` must be defined as Zap structs available
during builder compilation. See `stdlib-build-types.md`.

The embed approach (prepending Zap source text, like the existing stdlib)
can work without a full import system.

## Blocker 3: Wrapper Main Code Generation

The `zap` CLI needs to generate Zap source code for a synthetic `main/1`
function that:
1. Parses `args :: [String]` into target name, OS, arch, and `-D` flags
2. Constructs `%Zap.Env{target: ..., os: ..., arch: ..., build_opts: ...}`
3. Calls `<BuilderStruct>.manifest(env)`
4. Serializes the returned `%Zap.Manifest{...}` to stdout

**Approach**: Generate Zap source text and prepend it to `build.zap` before
compilation (same mechanism as `stdlib.prependStdlib`). The generated source
references the discovered builder struct name (from AST scanning in
`builder.zig`).

**Example generated wrapper** (conceptual):
```zap
def main(args :: [String]) do
  env = %Zap.Env{
    target: Zap.Args.get_atom(args, 0),
    os: Zap.Args.get_atom(args, 1),
    arch: Zap.Args.get_atom(args, 2),
    build_opts: Zap.Args.parse_d_flags(args)
  }
  manifest = FooBar.Builder.manifest(env)
  Zap.Manifest.serialize(manifest)
end
```

This depends on:
- Blocker 1 (serialization — `Zap.Manifest.serialize`)
- Blocker 2 (stdlib types — `Zap.Env`, `Zap.Manifest`)
- String-to-atom conversion in the runtime (for parsing args)
- Variable binding and struct construction working in generated code

## Implementation Path

### Option A: Full Zap-side serialization
1. Add `atom_to_string`, `int_to_string` to runtime
2. Write `Zap.Manifest.serialize/1` in Zap using string concat chains
3. Write `Zap.Args` helpers for parsing CLI args
4. Generate wrapper main in Zap source
5. Prepend stdlib + build types + wrapper to build.zap
6. Compile and execute

### Option B: Zig runtime bridge (simpler)
1. Add a Zig runtime function `__builder_serialize_manifest` that takes
   an anonymous struct (the manifest), iterates its fields via comptime,
   and prints key=value lines to stdout
2. Add a Zig runtime function `__builder_parse_args` that takes the raw
   args slice and returns a struct with target/os/arch/build_opts fields
3. Generate a minimal wrapper main that calls these two functions
4. This avoids needing string formatting in Zap entirely

Option B is significantly simpler because the serialization/deserialization
logic stays in Zig where it's trivial to implement.

## Dependencies

- `stdlib-build-types.md` — need Zap.Env and Zap.Manifest definitions
- Runtime function additions (struct serialization)
- String-to-atom conversion (for parsing args to atoms)

## Blocks

- `toml-manifest.md` — no TOML to emit without a running builder
- Dynamic build configuration (computed versions, env-conditional logic)

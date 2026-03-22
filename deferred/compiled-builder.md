# Deferred: Compiled Builder Execution (Phase 3 Full)

## Status: Blocked by runtime capabilities

## What It Is

Compile `build.zap` as a real Zap program into a native binary, execute it,
pass `Zap.Env` as input, and capture the returned `Zap.Manifest` as
structured output on stdout.

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
- **Runtime env var reads**: `System.get_env("DATABASE_URL")`
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

This means `build.zap` CAN be compiled through the ZIR pipeline. The
language constructs work.

### What's Missing

Three runtime capabilities are needed for the builder binary to communicate
with the `zap` CLI:

## Blocker 1: No Stdin Reading

The builder binary needs to receive `Zap.Env` data from the `zap` CLI.

**Current state**: The Zap runtime (`runtime.zig`) has:
- `Prelude.println` — write string to stdout
- `Prelude.panic` — crash with message
- `ZapString.concat` — concatenate strings
- `BinaryHelpers.*` — binary pattern matching

There is NO function to read from stdin.

**What's needed**: A runtime function callable from Zap:
```zig
// In runtime.zig
pub fn read_stdin(allocator: Allocator) ![]const u8 {
    return std.io.getStdIn().reader().readAllAlloc(allocator, 1024 * 1024);
}
```

Exposed to Zap via the runtime module, callable as
`Zap.Runtime.read_stdin()` or similar.

**Alternative**: Instead of stdin, pass env data as command-line arguments
to the builder binary. The binary's `main` would receive args directly.
This requires `main/1` with `[String]` support (see `main-args.md`).

## Blocker 2: No Struct-to-String Serialization

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

Or a higher-level approach: a `Zap.Manifest.serialize/1` function written
in Zap (or in the runtime) that outputs the manifest in the expected format.

**Simplest path**: A Zig runtime function `serialize_manifest` that takes
the raw struct fields and outputs key=value lines. The generated wrapper
main would call this directly rather than having Zap code do serialization.

## Blocker 3: Wrapper Main Code Generation

The `zap` CLI needs to generate Zap source code for a synthetic `main`
function that:
1. Receives env data (via stdin, args, or hardcoded values)
2. Constructs `%Zap.Env{...}` from the input
3. Calls `<BuilderModule>.manifest(env)`
4. Serializes the returned `%Zap.Manifest{...}` to stdout

**Approach**: Generate Zap source text (like `stdlib.prependStdlib`) and
prepend it to `build.zap` before compilation. The generated source
references the discovered builder module name (from AST scanning in
`builder.zig`).

**Example generated wrapper** (conceptual):
```zap
def main() do
  target = Zap.Runtime.get_arg(0)
  os = Zap.Runtime.get_arg(1)
  arch = Zap.Runtime.get_arg(2)
  env = %Zap.Env{target: target, os: os, arch: arch, build_opts: %{}}
  manifest = FooBar.Builder.manifest(env)
  Zap.Runtime.serialize_manifest(manifest)
end
```

This depends on:
- Blockers 1 and 2 (input and output)
- `Zap.Env` being a defined type (from `stdlib-build-types.md`)
- Variable binding working in the generated code
- Struct construction at runtime

## Implementation Path

### Option A: Full Zap-side serialization
1. Add `read_stdin` to runtime
2. Add `atom_to_string`, `int_to_string` to runtime
3. Write `Zap.Manifest.serialize/1` in Zap (requires string interpolation or concat chains)
4. Generate wrapper main in Zap source
5. Prepend stdlib + build types + wrapper to build.zap
6. Compile and execute

### Option B: Zig runtime bridge (simpler)
1. Add a Zig runtime function `__builder_serialize_manifest` that takes
   an anonymous struct (the manifest), iterates its fields via comptime,
   and prints key=value lines to stdout
2. Add a Zig runtime function `__builder_parse_env` that takes argc/argv
   and returns a Zap.Env-compatible struct
3. Generate a minimal wrapper main that calls these two functions
4. This avoids needing string formatting in Zap entirely

Option B is significantly simpler because the serialization/deserialization
logic stays in Zig where it's trivial to implement.

## Dependencies

- `stdlib-build-types.md` — need Zap.Env and Zap.Manifest definitions
- `main-args.md` — if using CLI args instead of stdin for env input
- Runtime function additions (stdin reading OR arg parsing)
- Runtime function additions (struct serialization)

## Blocks

- `toml-manifest.md` — no TOML to emit without a running builder
- Dynamic build configuration (computed versions, env-conditional logic)

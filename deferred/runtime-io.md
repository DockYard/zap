# Deferred: Runtime Type Conversion Functions

## Status: Not started

## What It Is

The Zap runtime (`src/runtime.zig`) needs type conversion functions to
support the compiled builder and general-purpose Zap programs.

## Why It Matters

The compiled builder needs to serialize `Zap.Manifest` fields to stdout.
This requires converting atoms and integers to strings. General Zap
programs also need these conversions for any meaningful string output
beyond hardcoded literals.

## Current Runtime Functions

From `src/runtime.zig`:

### Prelude
- `println(msg: []const u8)` — write string + newline to stdout
- `panic(msg: []const u8)` — write to stderr and abort
- `print_i64(val: i64)` — print integer to stdout
- `print_f64(val: f64)` — print float to stdout

### ZapString
- `concat(allocator, a, b) -> []const u8` — concatenate two strings

### BinaryHelpers
- `matchPrefix`, `readIntU8`, `readIntI16Big`, etc. — binary pattern matching

## Missing Functions

### Type Conversion (needed for compiled builder)

```zig
/// Convert an integer to its string representation.
pub fn int_to_string(allocator: Allocator, value: i64) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{d}", .{value});
}

/// Convert a float to its string representation.
pub fn float_to_string(allocator: Allocator, value: f64) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{d}", .{value});
}
```

### Atom-to-String (hardest problem)

Atoms (`:bin`, `:release_safe`) are emitted as Zig enum literals via
`zir_builder_emit_enum_literal`. At runtime, enum literals are comptime
values — their string names aren't available unless preserved explicitly.

Options:
1. **Preserve atom names as strings**: When the ZIR builder emits an atom,
   also emit a string constant with its name. Store both in a tuple.
   Changes the runtime representation of atoms.
2. **Use @tagName**: Works if the atom is part of a known enum type. But
   Zap atoms are ad-hoc, not part of a fixed enum.
3. **Atoms are strings**: Represent atoms as strings at runtime (like
   Erlang). Simplest long-term but changes how atoms flow through the
   entire pipeline.

This design decision affects the compiled builder (needs to serialize
atom fields like `kind: :bin` to text) and any Zap program that needs
to convert atoms to strings.

### Environment Variable Access

```zig
/// Read an environment variable. Returns null if not set.
pub fn get_env(allocator: Allocator, name: []const u8) ?[]const u8 {
    return std.process.getEnvVarOwned(allocator, name) catch null;
}
```

The plan specifies that builder code may read environment variables.
This requires a runtime function exposed to Zap.

### String-to-Atom Conversion (needed for builder args parsing)

The wrapper main receives CLI args as strings and needs to convert them
to atoms for `Zap.Env.target`, `Zap.Env.os`, `Zap.Env.arch`. This is
the reverse of atom-to-string and has the same representation challenge.

## How Runtime Functions Are Exposed to Zap

Existing pattern:
1. Functions defined in `src/runtime.zig`
2. Runtime compiled as `zap_runtime.zig`, registered as a Zig struct
3. Zap calls via `@import("zap_runtime").Struct.function`
4. ZIR builder maps Zap names to runtime names (e.g., `IO.puts` →
   `Prelude.println`)

New functions follow the same pattern.

## Dependencies

- Atom representation design decision (affects atom_to_string and
  string_to_atom)

## Blocks

- `compiled-builder.md` — needs type conversion for manifest serialization
- General-purpose Zap programs needing type conversion or env var access

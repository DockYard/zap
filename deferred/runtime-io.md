# Deferred: Runtime I/O Functions (stdin, type conversion)

## Status: Not started

## What It Is

The Zap runtime (`src/runtime.zig`) needs additional I/O and type
conversion functions to support the compiled builder and general-purpose
Zap programs.

## Why It Matters

The compiled builder needs to:
1. Read input (env data from the `zap` CLI)
2. Write structured output (manifest fields to stdout)

General Zap programs need:
1. Read user input from stdin
2. Convert values to strings for output
3. Basic string formatting

## Current Runtime Functions

From `src/runtime.zig`, the Zap runtime currently provides:

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

### Category 1: Input

```zig
/// Read all of stdin as a string.
pub fn read_stdin(allocator: Allocator) ![]const u8 {
    const stdin = std.io.getStdIn();
    return stdin.reader().readAllAlloc(allocator, 1024 * 1024);
}

/// Read one line from stdin (strips trailing newline).
pub fn read_line(allocator: Allocator) ![]const u8 {
    const stdin = std.io.getStdIn();
    return stdin.reader().readUntilDelimiterAlloc(allocator, '\n', 4096);
}
```

### Category 2: Type Conversion

```zig
/// Convert an integer to its string representation.
pub fn int_to_string(allocator: Allocator, value: i64) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{d}", .{value});
}

/// Convert a float to its string representation.
pub fn float_to_string(allocator: Allocator, value: f64) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{d}", .{value});
}

/// Convert an enum literal (atom) to its string name.
/// This is complex because Zig enum literals are comptime —
/// at runtime they're just integers. The name would need to be
/// preserved by the ZIR builder during emission.
pub fn atom_to_string(allocator: Allocator, atom: anytype) ![]const u8 {
    // Requires the ZIR builder to emit the atom name as a string
    // alongside the enum literal value
    return @tagName(atom);
}
```

### Category 3: Environment

```zig
/// Read an environment variable. Returns null if not set.
pub fn get_env(allocator: Allocator, name: []const u8) ?[]const u8 {
    return std.process.getEnvVarOwned(allocator, name) catch null;
}
```

### Category 4: Command-Line Arguments

```zig
/// Get command-line arguments as a list of strings.
pub fn get_args(allocator: Allocator) ![]const []const u8 {
    return std.process.argsAlloc(allocator);
}
```

## How Runtime Functions Are Exposed to Zap

Looking at how existing functions work:

1. Runtime functions are defined in `src/runtime.zig`
2. The runtime is compiled to `zap_runtime.zig` and registered as a
   Zig module via `zir_compilation_add_module_source`
3. Zap calls them via `@import("zap_runtime").Module.function`
4. The ZIR builder translates `IO.puts("hello")` to
   `@import("zap_runtime").Prelude.println("hello")`

New functions would follow the same pattern:
- Add them to `runtime.zig` under appropriate modules
- The ZIR builder maps Zap function names to runtime function names

For builder-specific functions (stdin, serialization), they could go in
a `Builder` module within the runtime:
```zig
pub const Builder = struct {
    pub fn read_stdin(allocator: Allocator) ![]const u8 { ... }
    pub fn serialize_manifest(manifest: anytype) void { ... }
};
```

## Atom-to-String Challenge

The hardest function to implement is `atom_to_string`. In Zap, atoms are
`:foo_bar`. In ZIR, they're emitted as Zig enum literals via
`zir_builder_emit_enum_literal`. At runtime, enum literals are comptime
values — their string names aren't available unless preserved explicitly.

Options:
1. **Preserve atom names as strings**: When the ZIR builder emits an atom,
   also emit a string constant with its name. Store both in a tuple.
   This changes the runtime representation of atoms.
2. **Use @tagName**: If the atom is part of a known enum type, Zig's
   `@tagName` works at comptime. But Zap atoms are ad-hoc, not part of
   a fixed enum.
3. **Atoms are strings**: Change the Zap runtime to represent atoms as
   strings (like Erlang does for atoms in BEAM). This is a larger change
   but simplifies everything.

Option 3 is the cleanest long-term approach but is a significant change
to how atoms flow through the compilation pipeline.

## Dependencies

- None for basic functions (stdin, int/float_to_string, get_env)
- Atom representation design decision for atom_to_string

## Blocks

- `compiled-builder.md` — needs stdin reading and output serialization
- General-purpose Zap programs needing I/O and type conversion

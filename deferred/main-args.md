# Deferred: `main/1` with `[String]` Arguments

## Status: Blocked by ZIR entry point handling

## What It Is

Change the Zap program entry point convention from `main/0` (no arguments)
to `main/1` taking `[String]` (list of command-line argument strings).

Currently:
```zap
def main() do
  IO.puts("Hello")
end
```

Target:
```zap
def main(args :: [String]) do
  IO.puts("Hello")
end
```

## Why It Matters

The build system plan specifies that `:bin` target entry points have
arity 1 with a `[String]` argument type. This allows programs to receive
command-line arguments, which is essential for any non-trivial CLI tool.

The compiled builder also benefits — `main/1` receiving args is a natural
way to pass `Zap.Env` data to the builder binary without needing stdin.

## Current State

### Zig Fork (`zir_api.zig`)

The `createImpl` function writes a stub source file that the Zig compiler
uses as the root module:

```zig
const stub_source = if (output_mode_enum == .Exe)
    "pub fn main() void {}\n"
else
    "comptime {}\n";
```

This stub declares `main` as `void -> void`. The ZIR injection replaces
the stub's AstGen output with Zap's ZIR, but the Zig linker still expects
the `main` symbol to match the declared signature.

### ZIR Builder (`zir_builder.zig`)

`emitFunction` handles `main` specially:

```zig
const is_main = std.mem.eql(u8, func.name, "main");
const ret_type = if (is_main)
    mapMainReturnType(func.return_type)
else
    mapReturnType(func.return_type);
```

`main` is emitted as a ZIR function with void return (or u8 for exit codes).
Parameters are NOT passed to main — it's always emitted as arity 0 on the
Zig side.

### Runtime

The Zig standard library's `_start` calls `main()` with no arguments on
most platforms. To get OS arguments, Zig code calls
`std.process.argsAlloc()` inside main. There's no automatic arg passing.

## What Needs to Change

### 1. Stub Source (`zir_api.zig`)

Change the exe stub from:
```zig
"pub fn main() void {}\n"
```
to:
```zig
"pub fn main() void {\n    // entry point\n}\n"
```

No change needed here actually — the stub is replaced by ZIR injection.
The stub just needs to parse as valid Zig for error reporting. The actual
function signature comes from the injected ZIR.

### 2. ZIR Function Emission (`zir_builder.zig`)

When emitting `main`, the ZIR builder currently emits it as a function
with zero parameters. For `main/1`, it needs to:

1. Emit `main` with one parameter of type `[][:0]const u8` (Zig's argv)
2. OR: emit `main` with zero parameters but inject code at the top that
   calls `std.process.argsAlloc()` and builds the `[String]` list

Option 2 is simpler — `main` stays as `void -> void` on the Zig side,
but the first thing it does is read `os_argv` and construct the argument
list. This avoids changing the linker contract.

### 3. Argument Conversion

Convert Zig's `[][:0]const u8` (null-terminated C strings) to Zap's
`[String]` (list of Zap strings). This requires:

```zig
// Pseudocode for the injected ZIR:
const args = std.process.argsAlloc(allocator);
// Convert args to Zap list representation
// Pass as first argument to the Zap-side main function
```

The ZIR builder would need to emit this conversion code at the beginning
of `main` when the Zap function has arity 1.

### 4. Breaking Change

All existing examples, tests, and scaffolded code that define `def main()`
must be updated to `def main(args :: [String])` or `def main(_args :: [String])`.

The compiler could support both `main/0` and `main/1` for backwards
compatibility — if the program defines `main/0`, don't inject arg parsing;
if it defines `main/1`, inject it. This avoids a hard break.

## Dependencies

- None — this is a self-contained change to `zir_builder.zig` and
  `zir_api.zig`

## Blocks

- `compiled-builder.md` — if using CLI args for env input, the builder
  binary needs `main/1`
- Programs that need command-line arguments

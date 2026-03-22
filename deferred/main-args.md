# Deferred: `main/1` with `[String]` Arguments

## Status: Blocked by ZIR entry point handling

## What It Is

The plan specifies that `:bin` target entry points have arity 1 with a
`[String]` argument type. The `root` field in `Zap.Manifest` is a
symbolic function reference like `"FooBar.main/1"`. The referenced
function must:
- Resolve to a single function family
- Have arity 1
- Accept `[String]` as the single argument type

This is about the compiled program's entry point — the binary that
`zap run <target>` executes. It has nothing to do with the builder's
input mechanism.

## Current State

### ZIR Backend Stub (`zir_api.zig`)

The stub source for `:bin` targets is:

```zig
"pub fn main() void {}\n"
```

This declares `main` as `void -> void`. The ZIR injection replaces the
AstGen output, but the Zig linker expects `main` to match this signature.

### ZIR Builder (`zir_builder.zig`)

`emitFunction` emits `main` as a zero-parameter function. No mechanism
exists to inject argument parsing at the entry point.

### Scaffolded Code

The `zap init` scaffold currently generates:

```zap
def main() do
  IO.puts("Howdy!")
end
```

The plan specifies this should be:

```zap
def main(_args :: [String]) do
  IO.puts("Howdy!")
end
```

## What Needs to Change

### 1. Stub Source

Change the exe stub to declare `main` with an args parameter that Zig
can populate from `os_argv`:

```zig
"pub fn main() void {}\n"
```

The stub stays as-is because ZIR injection replaces it. The actual
function signature comes from the injected ZIR.

### 2. ZIR Builder: `main` with One Parameter

When emitting `main/1`, the ZIR builder needs to:
1. Emit a parameter of the appropriate type (Zig's `[][:0]const u8` or
   a Zap-compatible list representation)
2. At the function entry, inject code to call `std.process.argsAlloc`
   and convert the result to Zap's `[String]` list format
3. Pass this as the first argument to the Zap-side `main` body

### 3. Backwards Compatibility

Support both `main/0` and `main/1`:
- If the program defines `main/0`, emit it as a zero-parameter function
  (current behavior)
- If the program defines `main/1`, inject arg parsing and pass the list
- The manifest's `root` field specifies the arity, so the compiler knows
  which case to handle

### 4. Update Scaffolding

Change `zap init` to generate `main/1` once the ZIR backend supports it.
Until then, `main/0` works for programs that don't need arguments.

## Dependencies

- None — self-contained change to `zir_builder.zig` and `zir_api.zig`

## Blocks

- Programs that need command-line arguments
- The scaffolded `build.zap` specifying `root: "FooBar.main/1"` (currently
  uses `main/0` as a workaround)

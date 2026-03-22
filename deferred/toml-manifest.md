# Deferred: TOML Manifest Serialization (Phase 4 Full)

## Status: Blocked by compiled-builder.md

## What It Is

The plan specifies that the boundary between builder execution and project
compilation is a TOML manifest file stored under `.zap-cache`. The builder
binary writes the manifest as TOML, and the `zap` CLI reads it.

## Why It Matters

TOML provides:
- Human-readable cache files (debuggable)
- Stable serialization format (cacheable across invocations)
- Clear boundary between builder and compiler phases
- Content-addressable storage for cache invalidation

## Current State

The v1 bridge bypasses TOML entirely. `builder.zig` extracts manifest data
directly from the AST into a Zig `BuildConfig` struct. No file is written
or read.

The `main.zig` caching uses a simple Wyhash of source contents stored in
`.zap-cache/<target>.hash`. This works but doesn't produce inspectable
manifest files.

## What Needs to Be Built

### Two Separate TOML Components

**1. TOML Serializer (Zap runtime side)**

Runs inside the compiled builder binary. Takes a `Zap.Manifest` struct
and writes TOML to stdout.

This is blocked by `compiled-builder.md` — without a running builder,
there's nothing to serialize.

If using Option B from `compiled-builder.md` (Zig runtime bridge), the
serializer would be a Zig function in `runtime.zig` that receives the
manifest struct and formats TOML via comptime field iteration.

Example output:
```toml
name = "foo_bar"
version = "0.1.0"
kind = "bin"
root = "FooBar.main/1"
paths = ["lib", "test"]

[build_opts]
optimize = "release_safe"
```

**2. TOML Parser (Zig CLI side)**

Runs in the `zap` CLI (Zig code). Reads `.zap-cache/<hash>.toml` and
produces a `BuildConfig` struct.

This is straightforward to implement or vendor. Required TOML subset:
- Bare keys: `name = "value"`
- String values: `"hello"`
- Integer values: `42`
- Boolean values: `true`, `false`
- Arrays: `["lib", "test"]`
- Tables: `[build_opts]`

NOT needed for v1:
- Datetime
- Inline tables
- Multiline strings
- Dotted keys
- Array of tables

A minimal TOML parser in Zig is ~200-300 lines for this subset.

### Cache File Structure

Manifest files stored at `.zap-cache/<hash>.toml` where `<hash>` is
computed from:
- `build.zap` file contents
- Target name
- CLI `-D` flags
- (Future: env vars read, files read by builder)

On cache hit: read the TOML file, parse to `BuildConfig`, skip builder
execution entirely.

On cache miss: execute builder, capture TOML output, write to cache,
parse for current build.

## Alternative: Skip TOML, Use Binary Format

The plan specifies TOML, but the v1 bridge already uses `BuildConfig`
directly. An alternative to TOML is the key=value line format already
defined in `builder.zig`:

```
name=foo_bar
version=0.1.0
kind=bin
root=FooBar.main/1
paths=lib
paths=test
build_opts.optimize=release_safe
```

This is simpler to implement on both sides (no TOML parser needed) but
less human-readable for debugging.

## Dependencies

- `compiled-builder.md` — need a running builder to produce output
- Zig TOML parser implementation (independent, can be built anytime)

## Blocks

- Nothing directly — caching is a performance optimization. The build
  system works without it (just slower on repeat builds).

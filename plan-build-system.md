# Plan: Zap Project Build System (`build.zap`)

## Overview

Zap uses a project-based build system driven by `build.zap`.

The build file is not interpreted by a restricted AST evaluator. It is
compiled as a real Zap program in its own builder phase, executed in a
read-only environment, and asked to return a `Zap.Manifest` for the requested
target.

The high-level flow is:

1. `zap build <target>` or `zap run <target>` selects a build file
2. Zap compiles `build.zap` and its stdlib imports as a separate builder
   compilation unit
3. Zap executes the builder and calls `manifest(env)`
4. The returned `Zap.Manifest` is serialized to TOML under `.zap-cache`
5. Zap uses only that manifest to compile the requested target
6. `zap run <target>` executes the resulting binary after cache validation

The builder is never part of the final built artifact.

## Core Design Decisions

### Project model

- Direct file compilation is removed
- `zap` with no subcommand prints the same command-oriented help as
  `zap --help`
- `zap build` and `zap run` are target-based only
- Target names are required; missing targets fail fast with a clear error
- There is no separate `zap test`; tests are just targets
- There are no aliases in v1; tasks are modeled as targets

### Build file model

- Default build file is `build.zap`
- `zap build` and `zap run` may optionally accept an override path to another
  build file
- The containing directory of the selected build file is the project root for
  that invocation
- The builder lives in normal Zap module space under the project namespace,
  such as `MyApp.Builder`
- Builder code may import/use full Zap stdlib modules
- Builder code may not depend on project source modules being built
- Builder compilation uses the normal compiler pipeline, not a special parser or
  evaluator

### Builder API

- The entrypoint is `manifest/1`, not `project/1`
- The return type is `Zap.Manifest`, not `Zap.Project`
- Target selection happens by pattern matching on `env.target` in the
  `manifest/1` function header/body
- The emitted manifest contains only the selected target's concrete build data
- A missing target fails fast with a clear explanation

### Builder runtime constraints

- Builder execution is read-only in v1
- Builder code may read environment variables
- Builder code may read files
- Builder code may not write files directly
- Builder code may not spawn subprocesses
- Normal compiler diagnostics are shown directly when builder compilation or
  execution fails

### Manifest boundary

- The boundary between builder execution and project compilation is a TOML
  manifest written under `.zap-cache`
- Manifest entries are keyed by content/invocation hash, not by stable target
  filenames
- There is no separate "latest manifest" pointer
- If cache validity is broken, Zap performs a full rebuild
- Partial cache entries are removed on failure

## Public Types

These types belong in Zap stdlib/build support, not as evaluator-only magic.

- `Zap.Env`
- `Zap.Manifest`
- `Zap.BuildOpts`
- supporting helper modules/functions under `lib/zap/...`

The earlier `Zap.Target` / `Zap.Project` model is removed from this plan.

## `Zap.Env`

`Zap.Env` is the effective invocation context passed into `manifest/1`.

It includes:

- the requested target name
- the effective host/target OS and architecture
- effective build overrides from CLI flags
- any other build-relevant invocation settings Zap chooses to expose

Important behavior:

- if no target/platform override is provided, values default to the current
  machine
- target settings may override host defaults
- CLI flags override target defaults
- `manifest(env)` receives the effective values after overrides are applied

This keeps target-conditional builder logic aligned with the actual build.

## `Zap.Manifest`

`Zap.Manifest` represents the fully resolved build description for one selected
target.

Planned shape:

```zap
defstruct Zap.Manifest do
  name :: String
  version :: String
  kind :: Atom
  root :: String = ""
  asset_name :: String = ""
  paths :: [String] = []
  build_opts :: %{Atom => String | i64 | Bool | [String | i64 | Bool]} = %{}
end
```

Notes:

- `name` and `version` stay on the manifest
- `kind` is the selected target kind (`:bin`, `:lib`, `:obj`)
- `root` is a symbolic function reference encoded as a single string such as
  `"MyApp.main/1"`
- `paths` is top-level because it describes the target's source graph, not just
  tuning options
- `build_opts` is a generic key/value map that mirrors Zig-style build options
- keys are ergonomic Zap atoms in source and serialized as TOML strings
- values are TOML-friendly scalars/lists only

For `:bin` targets:

- `root` is required
- the referenced function must resolve to a single function family
- that function family must have arity 1
- the single argument type is `[String]`

For `:lib` and `:obj` targets:

- there is no entry point
- `root` is ignored/empty

## Build Options

`build_opts` captures Zig compilation options as generic key/value data.

Examples:

- `:optimize`
- `:target`
- `:output_dir`
- any other Zig-style build options Zap elects to support

Behavior:

- target defaults may set option values
- CLI `-D...` flags may override those values
- builder logic sees the effective values through `env`
- output directories are supported because Zig's own build model supports them
- paths written into the manifest are normalized relative to the project root

## Symbolic Root Resolution

Builder code may use function-ref syntax such as `MyApp.main/1`, but the builder
phase preserves it symbolically rather than trying to execute or import project
code during builder execution.

The manifest stores this symbol as a single string.

During target compilation:

- Zap builds the explicit file graph for the selected target
- Zap resolves the symbolic root against that graph
- if the root cannot be resolved, the build fails fast
- multiple clauses in the same function family are valid and handled by normal
  dispatch/pattern matching

## File Graph Construction

The current implicit sibling-directory discovery logic is replaced.

For a selected target:

- Zap uses the manifest's explicit `paths` list
- Zap scans those source roots to form one target-specific project file graph
- graph construction is explicit, not heuristic
- duplicate modules are illegal per the language specification and remain a hard
  compiler failure
- compiler failure at any phase stops the build immediately

Although the manifest contains only one target's specifics, that target may
still reference multiple source directories.

## CLI Surface

### Commands

```text
zap                         # same as zap --help
zap --help                  # list all available commands
zap init                    # scaffold a project in the current directory
zap build <target>          # build the selected target
zap run <target>            # build if needed, then run a bin target
```

### Build file selection

Both `zap build` and `zap run` support an optional override path for the build
file. If omitted, Zap uses `build.zap` in the project root.

### Command semantics

- `zap build <target>` builds only; it does not run the artifact
- `zap run <target>` checks cache validity, rebuilds only if necessary, then
  executes the built binary
- `zap run <target>` fails if the selected target is not `:bin`
- developers may execute built binaries directly if they prefer

### Legacy CLI removal

These are removed from the CLI model:

- direct file compilation like `zap hello.zap`
- direct file run mode like `zap run hello.zap`
- old top-level flags such as `--emit-zig`, `--lib`, and `--strict-types`

One-off overrides should instead flow through Zig-like `-D...` options.

## Builder Phase

### Compilation unit

The builder phase compiles:

- the selected `build.zap`
- any imported/used stdlib modules

It does not compile project source roots from the target being built.

### Invocation

Zap compiles the builder as its own compilation unit, executes it in the
builder runtime, and obtains the result of `manifest(env)`.

That returned value is serialized to TOML under `.zap-cache`.

### Why this replaces the restricted evaluator

The earlier restricted evaluator idea required a mini interpreter for a subset
of Zap just for build files. That approach is removed because:

- it duplicates language execution semantics
- it drifts from real Zap behavior over time
- it complicates imports, helper functions, and symbolic references
- it is a worse match for a Zig-style build model

The compiled builder phase is the authoritative replacement.

## Cache Invalidation

Zap decides whether recompilation is necessary from its cache invalidation
strategy.

The cache must include the full dependency graph of the selected build file,
including:

- the build file contents
- imported stdlib/build modules used by the builder
- exact build command inputs
- effective CLI overrides
- environment variables read by the builder
- files read by the builder
- emitted manifest contents

If anything in that chain changes, the cache is invalid and Zap performs a full
rebuild.

There is no separate builder-cache vs target-cache namespace in this plan.

## `zap init`

`zap init` scaffolds a new project in the current working directory.

Behavior:

- it fails if the directory is not empty
- it derives the project name from the current directory, similar to `zig init`
- it creates a skeleton project rooted in the new build system
- it does not create `build.zig` or `build.zig.zon`

For a directory named `foo_bar/`, generate:

```text
foo_bar/
  .gitignore
  README.md
  build.zap
  lib/
    foo_bar.zap
  test/
    foo_bar_test.zap
```

### Generated `lib/foo_bar.zap`

```zap
defmodule FooBar do
  def main(_args :: [String]) :: String do
    IO.puts("Howdy!")
  end
end
```

### Generated `test/foo_bar_test.zap`

```zap
defmodule FooBarTest do
  def main(_args :: [String]) :: String do
    IO.puts("Test Suite TBD")
  end
end
```

### Generated `build.zap`

The generated builder uses `manifest/1` with:

- one clause for the app target named after the current directory
- one clause for the `test` target
- one fallback clause that fails clearly for unknown targets

The app target is a `:bin` rooted at `FooBar.main/1`.
The test target is a `:bin` rooted at `FooBarTest.main/1`.

### Generated `.gitignore`

At minimum:

- `.zap-cache/`
- `zap-out/`

Include any other obvious generated/build cache patterns that should not be
committed.

### Generated `README.md`

Include basic instructions for:

- building the project
- running the main target
- running the test target

## Implementation Phases

### Phase 1: Replace the CLI model

- remove direct file compilation entrypoints from `src/main.zig`
- make bare `zap` print command help
- introduce target-based `build` and `run` command parsing
- support build-file override paths

### Phase 2: Add stdlib build types

- add `Zap.Env`
- add `Zap.Manifest`
- add `Zap.BuildOpts`
- add supporting build helpers under `lib/zap/...`

### Phase 3: Builder compilation/execution

- compile `build.zap` as a separate builder compilation unit
- allow stdlib imports/use inside the builder
- execute `manifest(env)` in the read-only builder runtime
- surface normal compiler diagnostics on failure

### Phase 4: TOML manifest emission

- serialize the returned `Zap.Manifest` to TOML
- normalize paths relative to project root
- store the manifest under hashed `.zap-cache` entries
- remove partial entries on failure

### Phase 5: Target file graph resolution

- replace implicit sibling-file discovery
- construct explicit per-target file graphs from manifest `paths`
- resolve symbolic roots like `MyApp.main/1`
- fail fast on unresolved roots

### Phase 6: Actual project build

- consume only the emitted manifest
- map `build_opts` onto Zig compilation settings
- build the selected target artifact
- ensure `zap run` reads artifact location from the manifest/build result

### Phase 7: `zap init`

- scaffold project structure
- derive project/module names from the current directory
- generate `.gitignore`, `README.md`, `build.zap`, `lib/`, and `test/`

## Verification

1. `zig build test`
2. `zap` prints command help
3. `zap build <target>` fails clearly when `<target>` is omitted
4. `zap run <target>` fails clearly when the target is not `:bin`
5. changing `build.zap` invalidates cache and forces rebuild
6. changing a stdlib module imported by the builder invalidates cache
7. reading an env var in the builder invalidates cache when that env var changes
8. reading a file in the builder invalidates cache when that file changes
9. `manifest(env)` pattern matching selects the correct target
10. unresolved symbolic roots fail fast during target build
11. explicit multi-path target graphs build correctly
12. `zap init` in an empty directory produces a working skeleton project
13. `zap init` in a non-empty directory fails

## Removed From The Old Plan

The following earlier ideas are explicitly removed:

- restricted AST evaluator for `build.zap`
- `project/1` returning `Zap.Project`
- `Zap.Target` as the primary selected-target model
- aliases/task system for v1
- direct `.zap` file compilation
- implicit single-directory project guessing as the long-term build model
- `++`-style merge examples in build code

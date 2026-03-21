# Implementation Epic: Zap Project Build System

Reference: `plan-build-system.md`

## Phase 1: Replace the CLI Model

**Goal:** Strip old direct-file compilation, make `zap` command-oriented.

**Files:** `src/main.zig`

### Tasks

1.1. Remove the single-file compilation path (the entire pipeline from parse
through ZIR in `main()`).

1.2. Remove `compileMultiFile`, `generateBuildZig`, `splitAndWritePerFile`,
`invalidateCacheIfCompilerChanged`, `writeIfChanged`, and related helpers.

1.3. Remove all legacy flags: `--emit-zig`, `--lib`, `--strict-types`,
`--explain`, and their associated variables.

1.4. Remove the compilation caching logic (`.zap-cache/*.hash`, Wyhash).

1.5. Implement new argument parser:
- `zap` / `zap --help` → print command help listing `build`, `run`, `init`
- `zap build <target> [-Dkey=value...] [--build-file <path>]`
- `zap run <target> [-Dkey=value...] [--build-file <path>] [-- program-args...]`
- `zap init`
- Missing `<target>` on `build`/`run` → error:
  `Error: zap build requires a target name`

1.6. Implement build file discovery:
- If `--build-file <path>` provided, use that file; error if not found
- Otherwise look for `build.zap` in cwd; error if not found:
  `Error: no build.zap found in current directory`
- Set project root to the containing directory of the selected build file

1.7. Parse `-Dkey=value` flags into a `StringHashMap([]const u8)` for later
injection into `Zap.Env.build_opts`.

### Exit criteria

- `zap` prints command help
- `zap build app` finds `build.zap`, errors: `builder not yet implemented`
- `zap run app` same
- `zap hello.zap` errors: `unknown command: hello.zap`
- `zap build` (no target) errors clearly
- `zig build test` passes (existing unit tests unbroken)

---

## Phase 2: Stdlib Build Types and Module Infrastructure

**Goal:** Define `Zap.Env`, `Zap.Manifest`, and build helpers as importable
Zap source. Solve the module availability problem so `build.zap` can use them.

**Files:** New `.zap` files under `lib/zap/`, `src/stdlib.zig` (modify)

### Tasks

2.1. Determine how stdlib Zap source becomes available during compilation.
Today the stdlib is prepended as text via `stdlib.prependStdlib`. This must
evolve to support named module imports (`import Zap.Env`). Options:
- Extend the prepend mechanism to include build-type source files
- Register build modules via `zir_compilation_add_module_source` alongside
  the runtime module
- Embed build-type source as additional `@embedFile` data

2.2. Define `Zap.Env` as a Zap struct in `lib/zap/env.zap`:
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
`build_opts` values are always strings from `-Dkey=value`. The builder code
parses/interprets them as needed.

2.3. Define `Zap.Manifest` as a Zap struct in `lib/zap/manifest.zap`:
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

2.4. Define `Zap.BuildOpts` as a helper module in `lib/zap/build_opts.zap`
providing convenience functions for reading typed values from the string map:
```zap
defmodule Zap.BuildOpts do
  def get_string(opts, key, default) ...
  def get_atom(opts, key, default) ...
  def get_bool(opts, key, default) ...
end
```
This is the utility layer that sits between raw `-D` strings and typed
manifest values.

2.5. Verify these modules parse and type-check through the normal Zap pipeline
by writing a test that compiles a file importing them.

### Exit criteria

- A `.zap` file that constructs `%Zap.Env{...}` and `%Zap.Manifest{...}`
  compiles through the full frontend pipeline without errors
- `Zap.BuildOpts` helper functions are available

---

## Phase 3: Builder Compilation and Execution

**Goal:** Compile `build.zap` as a separate binary, execute it, capture the
returned `Zap.Manifest` as TOML on stdout.

**Files:** `src/main.zig`, `src/builder.zig` (new)

### Design decisions

**Builder module discovery:** The builder module is user-named (e.g.,
`MyApp.Builder`). The `zap` CLI cannot hardcode the module name. Resolution:
scan the parsed AST of `build.zap` for any module that defines a public
`manifest/1` function. Error if zero or more than one module matches:
- `Error: build.zap must contain exactly one module defining manifest/1`

**Env serialization format:** The builder binary receives `Zap.Env` as input.
`Zap.Env` contains a map (`build_opts`), which is non-trivial to pass as CLI
args. Resolution: serialize `Zap.Env` as TOML on stdin. The generated wrapper
main reads stdin, deserializes to `Zap.Env`, calls `manifest(env)`.

**Manifest output:** The builder binary writes the `Zap.Manifest` as TOML to
stdout. The `zap` CLI captures stdout and writes it to
`.zap-cache/<hash>.toml`. The builder does not write files directly.

**`-D` flag merging:** CLI `-D` flags are injected into `Zap.Env.build_opts`
before the builder runs. The builder sees the effective values and may copy
them into `Zap.Manifest.build_opts` or use them to compute manifest values.
There is no automatic merging — the builder is responsible for reading `env`
and populating the manifest.

### Sub-phase 3a: TOML Serde in the Zap Runtime

The builder binary needs to deserialize `Zap.Env` from stdin and serialize
`Zap.Manifest` to stdout. This code runs inside the compiled Zap program,
not in the `zap` CLI. This is a separate concern from the Zig-side TOML
parser in Phase 4.

**Approach:** Expose TOML serde as Zig runtime functions callable from Zap,
similar to how `IO.puts` is already implemented. The runtime module
(`runtime.zig`) gains:
- `zap_runtime_toml_parse(input :: String) :: Map` — parse TOML string to
  a Zap map value
- `zap_runtime_toml_serialize(value :: Map) :: String` — serialize a Zap
  map/struct value to TOML string
- `zap_runtime_read_stdin() :: String` — read all of stdin

These are internal runtime functions, not user-facing stdlib. The generated
wrapper main calls them directly.

Alternatively, if exposing runtime functions is too complex for v1, the IPC
format can be simplified:
- Env input: command-line arguments in a flat format
  (`--target=app --os=macos --arch=aarch64 -Dkey=value`)
- Manifest output: a simple line-oriented format that the Zig-side can parse
  without a full TOML parser in the Zap runtime

The trade-off is: TOML is clean but requires runtime serde; flat args are
hacky but avoid the dependency. Decide during implementation.

### Tasks

3.1. Implement builder AST scanning:
- Parse `build.zap` through the Zap parser
- Walk module declarations looking for a public function named `manifest`
  with arity 1
- Extract the module name
- Error if not found or ambiguous

3.2. Implement wrapper main generation:
- Generate Zap source text (like `stdlib.prependStdlib`) for a synthetic
  `main/1` function
- The generated source references the discovered builder module by name
  from step 3.1
- The wrapper:
  1. Reads env from stdin (or CLI args — see sub-phase 3a)
  2. Constructs `%Zap.Env{...}` from the parsed input
  3. Calls `<BuilderModule>.manifest(env)`
  4. Serializes the returned `%Zap.Manifest{...}` to stdout
- Prepend this generated source to `build.zap` before compilation

3.3. Implement builder compilation:
- Prepend stdlib + build-type sources + generated wrapper main to `build.zap`
- Compile through the full pipeline: parse → collect → macro → desugar →
  type check → HIR → IR → ZIR → native binary
- Output the builder binary to `.zap-cache/builder`

3.4. Implement builder execution:
- Construct `Zap.Env` from CLI context:
  - `target`: from the `<target>` CLI argument, as an atom
  - `os`: from native target (`builtin.os.tag`), mapped to atom
  - `arch`: from native target (`builtin.cpu.arch`), mapped to atom
  - `build_opts`: from parsed `-Dkey=value` flags
- Serialize env (TOML or flat format per sub-phase 3a decision)
- Spawn `.zap-cache/builder` as a subprocess
- Pipe env to stdin (or pass as CLI args)
- Capture stdout (manifest output)
- Capture stderr (diagnostics)
- If exit code != 0, print stderr and fail

3.5. Handle error cases:
- `build.zap` parse/type-check failure → show normal Zap diagnostics
- `manifest/1` not defined → clear error message
- Builder runtime crash → show stderr
- `manifest/1` returns wrong type → builder type-checker catches this at
  compile time (return type is `:: Zap.Manifest`)

### Exit criteria

- `zap build app` compiles `build.zap`, executes the builder, prints the
  captured manifest for debugging
- Builder parse/compile errors show Zap diagnostics
- Missing `manifest/1` fails with a clear message
- `-Doptimize=release_fast` flows through to the builder

---

## Phase 4: Manifest Parsing and Caching

**Goal:** Parse the manifest output from the builder into a Zig-side
`BuildConfig`, implement cache storage.

**Files:** `src/manifest.zig` (new), `src/toml.zig` (new or vendored, if
TOML is the IPC format)

### Tasks

4.1. Implement a parser for the builder's output format. If TOML: implement
or vendor a minimal TOML parser in Zig (strings, integers, booleans, arrays,
tables). If flat format: implement a line-oriented parser matching the
chosen format from sub-phase 3a.

4.2. Define the Zig-side `BuildConfig` struct:
```zig
const BuildConfig = struct {
    name: []const u8,
    version: []const u8,
    kind: enum { bin, lib, obj },
    root: ?[]const u8 = null,       // e.g., "MyApp.main/1"
    asset_name: ?[]const u8 = null, // output filename; falls back to name
    paths: []const []const u8,
    build_opts: std.StringHashMapUnmanaged(BuildOptValue),
};

const BuildOptValue = union(enum) {
    string: []const u8,
    integer: i64,
    boolean: bool,
    string_list: []const []const u8,
};
```

4.3. Parse the captured output into `BuildConfig`:
- Validate required fields: `name`, `version`, `kind`
- Validate `kind` is one of `bin`, `lib`, `obj`
- Validate `:bin` targets have non-empty `root`
- Map `kind` string to enum
- Parse `build_opts` into the typed union

4.4. Implement manifest cache:
- Hash inputs: build.zap file contents + `-D` flags + target name
- Check `.zap-cache/<hash>.toml` — if exists and hash matches, read cached
  manifest instead of re-executing builder
- On successful builder execution, write `.zap-cache/<hash>.toml`
- On builder failure, remove any partial `.zap-cache/<hash>.toml`

4.5. Cache invalidation scope (v1 vs future):
- v1: hash only build file contents + CLI inputs (target name, -D flags)
- Future: track env vars read and files read by the builder via runtime
  instrumentation, include them in the cache hash
- Document this limitation

### Exit criteria

- Builder output is parsed into a `BuildConfig` struct
- Subsequent identical invocations read from cache
- Cache is invalidated when `build.zap` or `-D` flags change

---

## Phase 5: Target File Graph Resolution

**Goal:** From the manifest `paths`, build the explicit source file graph and
resolve the symbolic root.

**Files:** `src/project.zig` (modify), `src/manifest.zig`

### Tasks

5.1. Read `paths` from `BuildConfig`. Resolve each path relative to the
project root (the directory containing the build file). Scan each resolved
directory for `.zap` files. Error if a path does not exist.

5.2. Replace the implicit sibling-file discovery in `project.zig`. The
existing `discoverZapFiles` function currently guesses siblings based on the
input file's directory. Replace this with explicit path-based scanning driven
by the manifest. Keep `analyzeProgram` and `DependencyGraph` — they still
work, they just receive files from explicit paths instead of guessed paths.

5.3. Build the per-target file graph:
- Parse all discovered `.zap` files
- Analyze type/module dependencies via `analyzeProgram`
- Build `DependencyGraph`, topologically sort, detect cycles
- Error on duplicate module definitions across files

5.4. Resolve the symbolic root string (e.g., `"MyApp.main/1"`):
- Parse the root string: split on `.` and `/` to extract module name,
  function name, arity
- After building the file graph, verify the module exists in the parsed
  sources
- Verify the function exists with the expected arity
- Error if unresolved:
  `Error: root "MyApp.main/1" not found in paths ["lib"]`

5.5. Validate target kind vs root:
- `:bin` requires a non-empty, resolvable root
- `:lib` and `:obj` skip root resolution (root field is ignored)

### Exit criteria

- `zap build foo_bar` resolves `"FooBar.main/1"` against `lib/foo_bar.zap`
- Missing roots fail: `Error: root "Missing.main/1" not found in paths ["lib"]`
- Multiple source directories work: `paths: ["lib", "lib/support"]`
- Circular dependencies detected and reported

---

## Phase 6: Project Build

**Goal:** Consume the manifest and file graph to compile the target artifact
through the ZIR backend.

**Files:** `src/main.zig`, `src/zir_backend.zig`

### Tasks

6.1. Map `build_opts` to C-ABI compilation parameters:
- `:optimize` → `optimize_mode`:
  - `"debug"` → 0
  - `"release_safe"` → 1 (default if absent)
  - `"release_fast"` → 2
  - `"release_small"` → 3
- `:output_dir` → output directory path (defaults: `zap-out/bin/`,
  `zap-out/lib/`, `zap-out/obj/` based on `kind`)
- `kind` → `output_mode`: `bin`=0, `lib`=1, `obj`=2
- `link_libc` → from build_opts or default `true`

6.2. Determine output filename:
- Use `asset_name` from manifest if non-empty
- Fall back to `name`
- For `:lib`, append `.a` (static) or `.dylib`/`.so` (dynamic)
- For `:obj`, append `.o`
- Full output path: `<output_dir>/<filename>`

6.3. Compile the target:
- Merge/concatenate sources from the file graph in dependency order
- Run full Zap frontend: parse → collect → macro → desugar → type check →
  HIR → IR
- Create ZIR compilation context via `zir_compilation_create` with settings
  from the manifest
- Register system libraries from `build_opts` via
  `zir_compilation_add_link_lib` if present
- Build ZIR and inject via `buildAndInject` with `lib_mode` set from
  `kind == :lib`
- Run `zir_compilation_update`
- Output artifact to the resolved path

6.4. Target artifact caching:
- After building the file graph, hash all source file contents + manifest
  contents + resolved build_opts
- Check if the output artifact exists and the hash matches a stored
  `.zap-cache/<artifact-hash>.built` marker
- If cache hit, skip compilation entirely (print `[cached]`)
- If cache miss, compile and write the marker on success
- This is separate from manifest caching (Phase 4) — manifest caching
  skips the builder; artifact caching skips the compiler

6.5. Implement `zap run <target>`:
- After successful build (or cache hit), verify `kind == :bin`; error if not:
  `Error: target "core" is a :lib, not a :bin — cannot run`
- Execute the binary from the output path
- Pass program args (everything after `--`) to the binary
- Forward exit code

6.6. Wire the root function as the entry point:
- For `:bin` targets, the resolved root function (e.g., `FooBar.main/1`) is
  the program entry point
- This is the function that Zig's linker looks for as `main`
- The ZIR backend must emit this function as the entry point, not skip it
  (unlike lib_mode which skips main)
- The existing `main/0` convention changes to `main/1` taking `[String]` —
  this is a breaking change to existing examples. Update examples and tests
  to use `main/1`.

6.7. Decide `main/1` return type:
- The plan's generated templates show `:: String` which is wrong for an
  entry point — the Zig linker expects `main` to return `void` or `u8`
- Options:
  a. `main/1` returns void (no explicit return type annotation)
  b. `main/1` returns `i64` mapped to exit code
  c. `main/1` returns `Atom` (`:ok` → exit 0, anything else → exit 1)
- Decide and update all generated templates and examples accordingly
- Update the ZIR backend to handle the chosen return type mapping

### Exit criteria

- `zap build foo_bar` produces `zap-out/bin/foo_bar`
- `zap run foo_bar` builds and executes, printing "Howdy!"
- `zap build foo_bar -Doptimize=release_fast` produces an optimized binary
- `zap build foo_bar -Doutput_dir=dist/bin` writes to `dist/bin/foo_bar`
- `zap run foo_bar -- arg1 arg2` passes args to the binary
- `:lib` targets produce `.a` files in `zap-out/lib/`
- `:lib` targets cannot be `zap run`
- Unchanged source files skip recompilation

---

## Phase 7: `zap init`

**Goal:** Scaffold a new project.

**Files:** `src/main.zig` or `src/init.zig` (new)

### Tasks

7.1. Implement `zap init`:
- Fail if cwd is not empty (any files/directories present)
- Derive project name from directory name:
  - `foo_bar/` → project name `foo_bar`, module name `FooBar`
  - `my-app/` → project name `my_app`, module name `MyApp`
  - Convert kebab-case to snake_case for project name
  - Convert snake_case to PascalCase for module name

7.2. Generate files:

**`.gitignore`:**
```
.zap-cache/
zap-out/
```

**`README.md`:**
```markdown
# <project_name>

## Build

    zap build <project_name>

## Run

    zap run <project_name>

## Test

    zap run test
```

**`build.zap`:**
```zap
defmodule <ModuleName>.Builder do
  def manifest(env :: Zap.Env) :: Zap.Manifest do
    case env.target do
      :<project_name> ->
        %Zap.Manifest{
          name: "<project_name>",
          version: "0.1.0",
          kind: :bin,
          root: "<ModuleName>.main/1",
          paths: ["lib"]
        }
      :test ->
        %Zap.Manifest{
          name: "<project_name>_test",
          version: "0.1.0",
          kind: :bin,
          root: "<ModuleName>Test.main/1",
          paths: ["lib", "test"]
        }
      _ ->
        panic("Unknown target: use '<project_name>' or 'test'")
    end
  end
end
```
The wildcard clause provides a clear error for unknown targets instead of a
bare runtime crash.

**`lib/<project_name>.zap`:**
```zap
defmodule <ModuleName> do
  def main(_args :: [String]) do
    IO.puts("Howdy!")
  end
end
```

**`test/<project_name>_test.zap`:**
```zap
defmodule <ModuleName>Test do
  def main(_args :: [String]) do
    IO.puts("Test Suite TBD")
  end
end
```

Note: `main/1` has no return type annotation — it returns void. This matches
the Zig linker's expectation that `main` returns `void` or `u8`. The return
type decision from Phase 6.7 may change this template.

7.3. End-to-end verification:
- `mkdir foo_bar && cd foo_bar && zap init`
- `zap build foo_bar` → produces `zap-out/bin/foo_bar`
- `zap run foo_bar` → prints "Howdy!"
- `zap run test` → prints "Test Suite TBD"

### Exit criteria

- `zap init` in an empty directory produces all files
- `zap init` in a non-empty directory fails:
  `Error: directory is not empty`
- The generated project compiles and runs end-to-end

---

## Dependency Chain

```
Phase 1 (CLI)
  ↓
Phase 2 (stdlib types) ← must solve module import infrastructure
  ↓
Phase 3 (builder compile/execute) ← hardest phase
  ├── Sub-phase 3a: TOML/IPC serde in runtime (or simplify IPC format)
  ├── 3.1-3.2: AST scanning + wrapper main source generation
  └── 3.3-3.5: compile + execute + error handling
  ↓
Phase 4 (manifest parsing + cache)
  ↓
Phase 5 (file graph resolution)
  ↓
Phase 6 (project build)
  ├── 6.4: target artifact caching
  ├── 6.6: main/1 breaking change
  └── 6.7: main/1 return type decision
  ↓
Phase 7 (zap init)
```

## Open Decisions (resolve during implementation)

1. **IPC format between CLI and builder binary:** TOML (clean, requires
   runtime serde) vs flat args/line-oriented (hacky, no runtime dependency).
   Sub-phase 3a explores both and picks one.

2. **`main/1` return type:** void, `i64` exit code, or `Atom`. Phase 6.7
   decides. Affects generated templates in Phase 7.

## Breaking Changes

- `main/0` → `main/1` taking `[String]`. All existing examples and tests
  that define `def main() do` must be updated to
  `def main(_args :: [String]) do`. This happens in Phase 6.
- Direct file compilation (`zap hello.zap`) is removed in Phase 1.
- `--emit-zig`, `--lib`, `--strict-types` flags removed in Phase 1.
- `src/` convention replaced by `lib/` in scaffolding (Phase 7), though
  `paths` in the manifest can point anywhere.

## Deferred to Post-v1

- Builder runtime sandboxing (enforcing read-only at the OS level)
- Full cache invalidation tracking (env var reads, file reads)
- Dependency resolution / package registry / `zap deps.get`
- `Zap.BuildOpts` convenience functions beyond basic string parsing
- Cross-compilation target overrides
- Dynamic library support (`:lib` with `dynamic: true`)

## Verification

1. `zig build test` — existing unit tests pass
2. `zap` prints command help
3. `zap build` with no target → clear error
4. `zap run <target>` with non-`:bin` target → clear error
5. Changing `build.zap` invalidates manifest cache and forces rebuild
6. Changing source files invalidates artifact cache and forces recompilation
7. `manifest/1` pattern matching selects the correct target
8. Unknown target name → clear error from wildcard clause
9. Unresolved symbolic roots fail fast during target build
10. Explicit multi-path target graphs build correctly
11. `zap init` in an empty directory → working skeleton project
12. `zap init` in a non-empty directory → fails
13. `zap run foo_bar` → "Howdy!"
14. `zap run test` → "Test Suite TBD"
15. `zap build foo_bar -Doptimize=release_fast` → optimized binary
16. Unchanged source + manifest → `[cached]`, no recompilation

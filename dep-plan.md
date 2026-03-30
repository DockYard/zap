# Zap Dependency System Plan

> One module per file. One file per module. The file system is the module graph.

## Architecture

### Module system rules

1. **One module per file.** Each `.zap` file contains exactly one `defmodule`.
   The compiler rejects files with zero or multiple `defmodule` declarations.

2. **Module name maps to file path.** `Config.Parser` must live at
   `lib/config/parser.zap`. The compiler enforces this — a mismatch is a
   compile error.

3. **Import-driven discovery.** The compiler starts from the entry point and
   follows module references to discover files. No globs, no file manifests.

4. **No circular dependencies.** If module A imports B and B imports A, the
   compiler rejects it. The module graph is a DAG.

5. **Visibility:**
   - `def` / `defmacro` — public function/macro
   - `defp` / `defmacrop` — private to the module (file)
   - `defmodule` — public module (visible everywhere)
   - `defmodulep` — private module (visible within the dep, invisible outside)

### Visibility rules

| | Within the module | Within the dep/project | Outside the dep |
|---|---|---|---|
| `defmodule` + `def` | yes | yes | yes |
| `defmodule` + `defp` | yes | no | no |
| `defmodulep` + `def` | yes | yes | no |
| `defmodulep` + `defp` | yes | no | no |

Within a project (no dep boundary), all modules see all other modules
regardless of `defmodule` vs `defmodulep`. The distinction only matters when
code is consumed as a dependency.

### Compilation pipeline

```
Discovery
  Start from entry point (e.g., App.main/0)
  Resolve App → lib/app.zap
  Parse, find module references (Config.load → lib/config.zap)
  Follow references transitively, build file dependency DAG
  Enforce: no cycles, name matches path, one module per file

Pass 1: Global collection (fast, all discovered files)
  Parse each file → per-file ASTs
  Collect declarations into shared CompilationContext:
    scope graph, type store, string interner
  Enforce: defmodulep visibility at dep boundaries

Pass 2: Per-file compilation (parallelizable)
  For each file, against the shared CompilationContext:
    Macro expand → Desugar → Type check → HIR → IR
  Enforce: defp/defmacrop visibility, defmodulep at dep boundaries
  Files with no dependency compile in parallel

Pass 3: Merge + backend
  Merge per-file IR programs into one
  Analysis pipeline: escape, interprocedural + effect derivation,
    regions, lambda sets, Perceus, ARC optimization
  Contification rewrite
  ZIR backend → native binary
```

### Incremental recompilation

When a file changes:
1. Re-parse, re-collect its declarations
2. Diff: did the public interface change? (`def` signatures, types)
3. Interface unchanged → recompile only that file
4. Interface changed → recompile that file + transitive dependents
5. Re-run pass 3 merge + analysis

The DAG ensures changes propagate in one direction only.

---

## Dependency manifest

Dependencies are declared in `build.zap`:

```zap
defmodule MyApp.Builder do
  def manifest(env :: Zap.Env) :: Zap.Manifest do
    case env.target do
      :my_app ->
        %Zap.Manifest{
          name: "my_app",
          version: "0.1.0",
          kind: :bin,
          root: "App.main/0",
          deps: [
            {:json_parser, {:git, "https://github.com/someone/json_parser.zap", tag: "v0.3.1"}},
            {:shared_utils, {:path, "../shared_utils"}},
            {:zig_toml, {:zig, "https://github.com/someone/zig-toml", tag: "v1.2.0"}},
            {:curl, {:system, "curl", headers: ["curl/curl.h"], link: :static}}
          ]
        }
    end
  end
end
```

### Dep tuple format

`{name, source}` where name is always an atom.

| Source type | Example | Description |
|---|---|---|
| `{:path, dir}` | `{:shared_utils, {:path, "../shared_utils"}}` | Local Zap library |
| `{:git, url, opts}` | `{:json_parser, {:git, "...", tag: "v1.0"}}` | Remote Zap library |
| `{:zig, url, opts}` | `{:zig_toml, {:zig, "...", tag: "v1.0"}}` | Zig library |
| `{:system, lib, opts}` | `{:curl, {:system, "curl", link: :static}}` | C system library |

Git/zig options: `tag`, `branch`, `rev`.
System options: `headers`, `link` (`:static` or `:dynamic`).

### Dep resolution

Zap deps: the compiler looks for modules in the dep's `lib/` directory using
the same name-to-path convention. When the compiler encounters
`JsonParser.parse()` and can't find `lib/json_parser.zap` locally, it checks
declared deps. The `:json_parser` dep's directory is searched.

Foreign deps (`:zig`, `:system`): accessed via `:dep_name.function()` syntax.
The compiler emits foreign calls with automatic type marshaling.

### Lockfile

`zap.lock` records resolved versions for reproducible builds:

```
# zap.lock — auto-generated, do not edit
json_parser git https://github.com/someone/json_parser.zap v0.3.1 a1b2c3d4 sha256-abcdef
shared_utils path ../shared_utils - - -
```

- First compile: resolve deps, write lockfile
- Subsequent compiles: use lockfile
- `zap deps update`: re-resolve all
- Path deps: not locked

---

## Implementation

### Step 1: `defmacrop` keyword and `defmodulep` keyword

Add `defmacrop` and `defmodulep` to the lexer, parser, and AST. `defp` already
exists.

**Token changes** (`src/token.zig`):
- Add `keyword_defmacrop` to Tag enum
- Add `keyword_defmodulep` to Tag enum
- Add `"defmacrop"` to keywords map
- Add `"defmodulep"` to keywords map

**AST changes** (`src/ast.zig`):
- Add `priv_macro: *const FunctionDecl` variant to `ModuleItem`
- Add `priv_module: *const ModuleDecl` variant to `TopItem`
- Add `is_private: bool = false` field to `ModuleDecl`

**Parser changes** (`src/parser.zig`):
- In `parseModuleItem`: handle `keyword_defmacrop` → parse as macro with
  `visibility: .private`
- In `parseTopLevel`: handle `keyword_defmodulep` → parse as module with
  `is_private: true`
- In `parseModuleDecl`: accept both `keyword_defmodule` and
  `keyword_defmodulep`, set `is_private` accordingly

**Collector changes** (`src/collector.zig`):
- In `collectModule`: store `is_private` flag in module registration
- In `collectFunction`: handle `priv_macro` variant same as `macro` but
  with private visibility

**Tests:**
- Parse `defmacrop` inside a module, verify AST has private visibility
- Parse `defmodulep` at top level, verify AST has `is_private: true`
- Verify `defmacrop` outside a module is a parse error
- Verify `defmodulep` with nested modules works

### Step 2: One-module-per-file validation

Add compiler validation that each file contains exactly one `defmodule` (or
`defmodulep`) and the module name matches the file path.

**Compiler changes** (`src/compiler.zig`):
- After parsing, count top-level module declarations in the AST
- If count != 1: emit error "File must contain exactly one module, found {n}"
- Convert module name to expected path: `Config.Parser` → `config/parser.zap`
- Compare with actual file path (relative to `lib/` root)
- If mismatch: emit error "Module name Config.Parser does not match file path
  {actual} — expected lib/config/parser.zap"

**Stdlib exemption:**
- Stdlib files are exempt from one-module-per-file validation (they're
  internal and may contain multiple modules like `Kernel` with macros)
- Track which files are stdlib vs user code

**Example migration:**
- Update `examples/multifile/` — each module in its own file
- Update `examples/types/` — split structs/enums into separate files if they
  define separate modules
- Verify all existing examples comply

**Tests:**
- File with zero modules → compile error
- File with two modules → compile error
- Module name doesn't match path → compile error
- Module name matches path → success
- Stdlib files exempt from validation

### Step 3: Import-driven file discovery

Replace glob-based file collection with import-driven discovery starting from
the entry point.

**New file: `src/discovery.zig`**

Module discovery state machine:
```
FileGraph {
  module_to_file: StringHashMap([]const u8)
  imports: StringHashMap(ArrayList([]const u8))
  imported_by: StringHashMap(ArrayList([]const u8))
  discovery_order: ArrayList([]const u8)
}

pub fn discover(
  alloc: Allocator,
  entry_module: []const u8,
  lib_root: []const u8,
  dep_roots: []const DepRoot,
) !FileGraph
```

Algorithm:
1. Convert entry module name to path: `App` → `lib/app.zap`
2. Parse the file (fast parse — only need to find module references)
3. Extract all capitalized identifiers used in qualified calls
   (`Config.load` → needs module `Config`)
4. For each unresolved module reference:
   a. Convert to path: `Config` → `lib/config.zap`
   b. If not found in project, check dep roots
   c. If found, add to discovery queue
   d. If not found anywhere, record as unresolved (error later)
5. Repeat until queue is empty
6. Check for cycles in the dependency graph (Kahn's algorithm or DFS)
7. Return FileGraph with topological ordering

**Module reference extraction:**
- During parsing (or a lightweight scan), collect all `Module.function()`
  patterns — the `Module` part is a capitalized identifier that references
  another module
- Also collect explicit `ModuleName` references in types: `:: Config.Result`
- Also collect pattern match module references: `%Config{...}`

**Cycle detection:**
- Run topological sort on the FileGraph
- If sort fails (cycle detected), emit error: "Circular dependency:
  Config → Parser → Config"

**Changes to `src/main.zig`:**
- In `buildTarget`: replace `globCollectFiles` + concatenation with
  `discovery.discover()` + per-file reading
- Pass `FileGraph` to the compilation pipeline

**Tests:**
- Entry point with no module references → discovers one file
- Entry point references one module → discovers two files
- Transitive references → discovers full chain
- Module not found → compile error with helpful message
- Circular dependency → compile error showing the cycle
- Module in a dep root → discovered correctly

### Step 4: Two-pass per-file compilation

Split `compileFrontend` into the three-pass architecture.

**New struct: `CompilationContext`** (in `src/compiler.zig`):
```
pub const CompilationContext = struct {
    interner: StringInterner,
    scope_graph: ScopeGraph,
    type_store: TypeStore,
    file_graph: FileGraph,
    dep_boundaries: StringHashMap([]const u8), // file → dep name
};
```

**New struct: `CompilationUnit`** (in `src/compiler.zig`):
```
pub const CompilationUnit = struct {
    file_path: []const u8,
    module_name: []const u8,
    source: []const u8,
    ast: ?ast.Program = null,
    ir_program: ?ir.Program = null,
    diagnostics: ArrayList(Diagnostic),
    dep: ?[]const u8 = null,
};
```

**New function: `collectAll`**
- For each file in discovery order:
  - Parse (with stdlib prepended for the first file, or handled separately)
  - Run collector to populate shared scope graph
- Return CompilationContext

**New function: `compileFile`**
- Takes CompilationContext + CompilationUnit
- Runs macro expansion, desugaring, type checking, HIR, IR
- Uses the shared scope graph and type store for cross-module resolution
- Stores per-file IR in the CompilationUnit
- Enforces visibility: defp/defmacrop within module, defmodulep at dep
  boundaries

**New function: `mergeAndFinalize`**
- Concatenate all per-file IR programs' functions and type_defs
- Reassign global function IDs
- Set entry point
- Run analysis pipeline
- Return CompileResult (same as today)

**Stdlib handling:**
- Stdlib files are compiled first as a set of CompilationUnits
- Their declarations go into the shared CompilationContext
- All user files can reference stdlib modules

**Changes to `src/main.zig`:**
- Replace single `compileFrontend` call with:
  1. `discovery.discover()` → FileGraph
  2. Read all discovered files
  3. `collectAll()` → CompilationContext
  4. For each file: `compileFile()` → per-file IR
  5. `mergeAndFinalize()` → CompileResult
- Rest of pipeline unchanged (ZIR backend, etc.)

**Tests:**
- All existing integration tests pass (same observable behavior)
- Multifile example compiles with per-file pipeline
- Type errors in one file don't prevent other files from compiling
- Cross-module function calls resolve correctly
- Cross-module type references resolve correctly
- defp functions not visible from other modules → compile error

### Step 5: Dep support (path deps)

Add `deps` field to the manifest and support `{:path, "..."}` deps.

**Manifest changes** (`src/builder.zig`):
- Add `deps` field to `BuildConfig`:
  ```
  deps: []const Dep = &.{},
  pub const Dep = struct {
      name: []const u8,
      source: DepSource,
  };
  pub const DepSource = union(enum) {
      path: []const u8,
      // git, zig, system added later
  };
  ```
- In `extractFieldsFromStruct`: parse `deps` field from AST
  - Expect a list of tuples
  - First element: atom → dep name
  - Second element: tagged tuple → dep source
  - For `{:path, "..."}`: extract path string

**Zap.Manifest struct changes** (`lib/zap/manifest.zap`):
- Add `deps` field: `deps :: List({Atom, {Atom, String}}) = []`

**Discovery changes** (`src/discovery.zig`):
- `discover()` accepts `dep_roots: []const DepRoot` where
  `DepRoot = struct { name: []const u8, lib_dir: []const u8 }`
- When a module can't be found in the project's `lib/`, check each dep's
  `lib/` directory
- Track which files belong to which dep (for defmodulep enforcement)

**Dep boundary enforcement:**
- During type checking (pass 2): when resolving a module reference, check if
  the target module is `defmodulep` and the referencing file is in a different
  dep → compile error: "Module JsonParser.Lexer is private to dep :json_parser"

**Integration test:**
- Create `examples/deps/` with:
  ```
  examples/deps/
    build.zap
    lib/app.zap                    # calls MathLib.add(1, 2)
    deps/math_lib/
      build.zap
      lib/math_lib.zap             # defmodule MathLib, def add
      lib/math_lib/helpers.zap     # defmodulep MathLib.Helpers
  ```
- `App.main` calls `MathLib.add(1, 2)`, binary outputs `3`
- `App.main` calling `MathLib.Helpers.internal()` → compile error
- Add to test suite that runs via `zig build test`

### Step 6: Git deps and lockfile

Fetch remote Zap deps and generate `zap.lock`.

**Git fetching:**
- Shell out to `git clone --depth 1 --branch <tag> <url>` into
  `~/.cache/zap/deps/<hash>/`
- Hash = SHA-256 of `url + resolved_ref`
- If cached directory exists and hash matches, skip fetch

**Lockfile generation** (`src/lockfile.zig`):
- On first compile: resolve all deps, write `zap.lock`
- Format: one line per dep, tab-separated:
  `name\ttype\turl\tresolved\tcommit\tintegrity`
- On subsequent compiles: read lockfile, use recorded commits
- If manifest changed (new dep, removed dep, changed version): re-resolve
  affected deps, update lockfile

**Lockfile reading:**
- Parse `zap.lock` on startup
- For each git dep: check if `~/.cache/zap/deps/<hash>/` exists
- If missing: fetch using lockfile's recorded commit

**CLI commands:**
- `zap deps update` — re-resolve all deps, rewrite lockfile
- `zap deps update <name>` — re-resolve one dep

**Tests:**
- First compile generates `zap.lock`
- Second compile uses lockfile (no git operations)
- Adding a dep updates lockfile
- Removing a dep updates lockfile
- `zap deps update` re-resolves

### Future: Zig deps

- Resolve `{:zig, url, opts}` deps
- Invoke Zig build system on dep's `build.zig`
- Wire `:dep_name.function()` syntax into parser
- Generate ZIR calls into compiled Zig library

### Future: System (C) deps

- Resolve `{:system, lib_name, opts}` deps
- Verify library exists via pkg-config
- Parse headers via `@cImport`
- Generate automatic type marshaling
- Opaque handle wrapping for pointers
- Static/dynamic linking via `link:` option

### Future: Transitive dep resolution

- Walk dep graph transitively (dep's build.zap has its own deps)
- Version conflict detection
- Diamond dependency resolution
- Lock transitive deps in `zap.lock`

### Future: Foreign function interface

Automatic type marshaling at the boundary for `:zig` and `:system` deps:

| C type | Zap type | Boundary behavior |
|---|---|---|
| Integer types | `i64` | Compiler narrows/widens |
| `float`, `double` | `f64` | Compiler narrows if needed |
| `bool` | `Bool` | Direct map |
| `const char*` | `String` | Copy in |
| `char*` (output) | `String` | Copy out |
| `void` | `nil` | Direct map |
| `T*` (opaque) | Opaque handle | Wrapped, not dereferenceable |
| `struct { fields }` | `%{fields}` | Field-by-field conversion |
| `enum { variants }` | Atoms | Variant-to-atom mapping |

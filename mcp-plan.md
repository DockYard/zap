# Zap MCP Server Plan

> The compiler is the oracle. The agent asks, the compiler answers.

## Vision

Today's AI coding agents work by reading source text, guessing what the code
does, generating edits, shelling out to a compiler, parsing error strings, and
guessing again. Every interaction with the compiler is lossy — the agent sees
rendered error messages, not the structured analysis the compiler computed
internally.

Zap's compiler already produces rich analysis artifacts: resolved types for
every expression, a 6-level escape lattice for every allocation, region
assignments, lambda set specialization decisions, Perceus reuse pairs,
interprocedural call graph summaries with per-parameter escape/return/read-only
flags, ownership transitions, and derived effect sets. Today, all of this is
thrown away after codegen.

`zap mcp` keeps the compiler's internal state alive and exposes it as
structured, queryable MCP tools. An AI agent connects to this server and gets
access to everything the compiler knows — not just errors, but the full
semantic understanding of the program. The agent reasons from compiler-verified
facts, not from text pattern matching.

### Why this matters

Research evidence is unambiguous:

- A 4B parameter model with compiler access outperformed a 70B model without it
  (Kjellberg et al. 2025)
- Type-level semantic constraints are 8-12x more effective than syntax-only
  constraints at reducing errors (Mundler et al., PLDI 2025)
- Type + effect information solved all 19 synthesis benchmarks where types alone
  timed out on 10 of 12 (RbSyn, PLDI 2021)
- LSP-grounded planning yields 27% fewer hallucinated APIs and 33% fewer
  mislocalized edits (2026 study)

The deeper the semantic information available to the agent, the better the
results. Zap's analysis pipeline is unusually deep. No compiler today exposes
this level of analysis as a queryable MCP service.

---

## Architecture

### Server identity

The MCP `initialize` response declares:

```json
{
  "name": "zap",
  "version": "<from build.zig.zon>",
  "capabilities": {
    "tools": {},
    "resources": {}
  }
}
```

### Startup

```
zap mcp [--project-dir <path>]
```

Starts an MCP server over stdio (the standard MCP transport). The server:

1. Reads `build.zap` to understand the project structure and dependencies
2. Performs an initial compilation of the project
3. Holds all per-file compilation state in memory
4. Listens for MCP tool calls

The server process is long-lived. It persists between tool calls, maintaining
the full compilation state. When the agent edits a file and recompiles, the
server incrementally updates only the affected files and their dependents.

### Tool naming

Tools use short, unprefixed names (`compile`, `types`, `escape`) rather than
the MCP convention of service-prefixed names (`zap_compile`, `zap_types`).
This is a deliberate choice: the `zap` MCP server is a single-service server
and the server name itself provides the namespace. MCP clients disambiguate by
server when multiple servers are connected. Unprefixed names are cleaner in
tool descriptions and agent prompts.

### Compilation model

Zap uses per-file compilation with a two-pass architecture:

**Pass 1: Global collection** (fast, all files)
- Start from the entry point, follow struct references to discover files
- Parse each file independently
- Collect all declarations into a shared scope graph and type store

**Pass 2: Per-file compilation** (parallelizable)
- For each reachable file: macro expand, desugar, type check, HIR, IR
- Each file compiles against the shared scope graph from pass 1
- Produces per-file IR programs

**Pass 3: Merge and backend** (single pass)
- Merge per-file IR programs into one
- Run analysis pipeline (escape, interprocedural, regions, lambda sets, Perceus)
- Effect derivation from the interprocedural call graph
- ZIR backend produces native binary

Struct discovery is import-driven: the compiler starts from the entry point and
follows `Struct.function()` references to find files. Each struct name maps to
a file path by convention (`Config.Parser` -> `lib/config/parser.zap`). One
struct per file, enforced by the compiler.

### State management

The server holds these artifacts in memory after compilation:

| Artifact | Source | Granularity | Contents |
|---|---|---|---|
| `file_graph` | Discovery | Global | Struct dependency graph (which files import which) |
| `compilation_context` | Pass 1 | Global | Shared scope graph, type store, string interner |
| `file_asts` | Pass 1 | Per-file | AST with spans for each source file |
| `file_irs` | Pass 2 | Per-file | IR program for each source file |
| `merged_ir` | Pass 3 | Global | Combined IR program |
| `analysis_context` | Pass 3 | Global | Escape states, regions, lambda sets, Perceus, summaries, effects |
| `diagnostics` | All phases | Per-file + global | Errors and warnings keyed by source file |

On incremental recompilation, only affected artifacts are replaced. The server
tracks which files changed and which files depend on them, rerunning only the
necessary passes.

### Error model

Tool results follow MCP protocol conventions. On success, the tool returns
`content` with structured JSON. On failure, the tool returns `isError: true`
with diagnostics in the content:

```json
{
  "content": [
    {
      "type": "text",
      "text": "{\"success\":false,\"phase\":\"typecheck\",\"diagnostics\":[...]}"
    }
  ],
  "isError": true
}
```

The diagnostics payload is always structured JSON with these fields:

```json
{
  "severity": "error",
  "message": "Type mismatch: expected i64, got String",
  "file": "lib/app.zap",
  "line": 12,
  "column": 5,
  "end_line": 12,
  "end_column": 18,
  "label": "this expression has type String",
  "help": "Consider converting with String.to_integer()",
  "secondary_spans": [
    {
      "file": "lib/app.zap",
      "line": 10,
      "column": 3,
      "label": "expected i64 because of this annotation"
    }
  ]
}
```

Diagnostics are structured objects, never rendered strings. The agent gets
severity, message, precise location, contextual labels, help text, secondary
spans, and (when available) suggested fixes with replacement text. This maps
directly to the existing `diagnostics.Diagnostic` struct.

### Pagination

Tools that return lists (`function_list`, `structs`, `escape`, `regions`,
`reuse`) support pagination:

**Parameters** (on applicable tools):
- `limit` (optional, int) — max items to return, default 50
- `offset` (optional, int) — items to skip, default 0

**Response metadata** (on applicable tools):
```json
{
  "total": 150,
  "count": 50,
  "offset": 0,
  "has_more": true,
  "next_offset": 50,
  "items": [...]
}
```

---

## MCP Tools

### Tool annotations reference

Every tool declares MCP annotations:

| Tool | readOnlyHint | destructiveHint | idempotentHint | openWorldHint |
|---|---|---|---|---|
| `compile` | false | false | true | false |
| `build` | false | false | true | false |
| `run` | true | false | false | true |
| `test` | true | false | false | true |
| `diagnostics` | true | false | true | false |
| `source` | true | false | true | false |
| `types` | true | false | true | false |
| `type_at` | true | false | true | false |
| `scope` | true | false | true | false |
| `structs` | true | false | true | false |
| `function_list` | true | false | true | false |
| `deps` | true | false | true | false |
| `call_graph` | true | false | true | false |
| `summary` | true | false | true | false |
| `effects` | true | false | true | false |
| `escape` | true | false | true | false |
| `regions` | true | false | true | false |
| `ownership` | true | false | true | false |
| `reuse` | true | false | true | false |
| `lambda_sets` | true | false | true | false |
| `ir` | true | false | true | false |

`compile` and `build` are not read-only because they mutate the server's
in-memory compilation state (and `build` writes a binary to disk). `run` and
`test` are read-only from the server's perspective but `openWorldHint: true`
since they execute external processes. All query tools are read-only,
non-destructive, idempotent, and closed-world (they only read compiler state).

### Build and run

#### `compile`

Compile the project through the per-file compilation pipeline.

**Parameters:**
- `file` (optional, string) — single file to recompile incrementally. If
  omitted, runs a full compilation from the entry point.
- `strict_types` (optional, bool) — treat type warnings as errors.

**Returns:**
- `success` — whether compilation completed without errors
- `phase` — the last phase that ran successfully
- `files_compiled` — number of files compiled (less than total on incremental)
- `files_total` — total files in the project
- `diagnostics[]` — all errors and warnings from all phases
- `functions[]` — list of compiled functions with name, arity, struct
- `types[]` — list of type definitions (structs, enums, unions)
- `entry` — the entry point function, if any

**Behavior:**
When `file` is omitted, runs the full pipeline: discover files from entry
point, pass 1 (collect), pass 2 (compile per-file), pass 3 (merge + analyze).
Updates all in-memory state.

When `file` is provided, runs an incremental compilation: re-runs pass 1 for
the changed file, determines which dependents need recompilation, re-runs
pass 2 for affected files, re-runs pass 3 merge + analysis. Only the
changed file and its transitive dependents are recompiled.

Does not emit a binary (that's `build`).

#### `build`

Compile and link a native binary.

**Parameters:**
- `target` (optional, string) — build target from `build.zap`
- `optimize` (optional, enum) — `debug`, `release_safe`, `release_fast`,
  `release_small`

**Returns:**
- `success` — whether the build completed
- `binary_path` — path to the output binary
- `diagnostics[]` — all errors and warnings

**Behavior:**
Calls `compile` internally (updating in-memory state), then runs the ZIR
backend to produce a native binary. The binary path is returned so `run`
can execute it.

#### `run`

Execute a compiled binary.

**Parameters:**
- `args` (optional, string[]) — command-line arguments to pass

**Returns:**
- `exit_code` — process exit code
- `stdout` — captured standard output
- `stderr` — captured standard error

**Behavior:**
Runs the binary from the most recent `build`. If no binary exists, returns
an error suggesting `build` first.

#### `test`

Run the project's test suite.

**Parameters:**
- `filter` (optional, string) — run only tests matching this pattern

**Returns:**
- `passed` — number of tests passed
- `failed` — number of tests failed
- `results[]` — per-test results with name, status, output, and duration
- `diagnostics[]` — compilation errors if tests failed to compile

### Diagnostics and source

#### `diagnostics`

Get the current diagnostics from the most recent compilation without
recompiling.

**Parameters:**
- `file` (optional, string) — restrict to diagnostics from a specific file

**Returns:**
- `diagnostics[]` — all errors and warnings from the last compilation
- `phase` — the last phase that completed
- `has_errors` — whether there are any errors

**Behavior:**
Returns the cached diagnostics from the most recent `compile` or `build` call.
When `file` is specified, returns only diagnostics from that file. Useful when
the agent wants to re-read errors without triggering a recompilation.

#### `source`

Read a project source file, optionally annotated with type information.
Accepts either a file path or a struct name.

**Parameters:**
- `file` (optional, string) — source file path relative to project root
- `struct` (optional, string) — struct name (resolved to file path via
  convention: `Config.Parser` -> `lib/config/parser.zap`)
- `annotated` (optional, bool) — include inline type annotations, default false

**Returns:**
```json
{
  "file": "lib/config.zap",
  "struct": "Config",
  "content": "struct Config do\n  ...\nend",
  "lines": 42,
  "annotations": [
    { "line": 3, "column": 5, "type": "String", "ownership": "shared" }
  ]
}
```

**Behavior:**
Reads the source file from disk. Struct names are resolved to file paths via
the naming convention. When `annotated: true`, overlays the TypeChecker's
resolved types at binding sites.

### Struct dependency queries

#### `deps`

Get the struct dependency graph.

**Parameters:**
- `struct` (optional, string) — show deps for a specific struct. If omitted,
  returns the full project dependency graph.
- `direction` (optional, enum) — `imports` (default), `imported_by`, or `both`
- `depth` (optional, int) — transitive depth, default 1, max 10

**Returns:**
```json
{
  "struct": "App",
  "file": "lib/app.zap",
  "imports": [
    { "struct": "Config", "file": "lib/config.zap" },
    { "struct": "IO", "file": "lib/io.zap" }
  ],
  "imported_by": []
}
```

When no struct is specified, returns the full graph:
```json
{
  "structs": [
    {
      "struct": "App",
      "file": "lib/app.zap",
      "imports": ["Config", "IO"]
    },
    {
      "struct": "Config",
      "file": "lib/config.zap",
      "imports": ["Config.Parser"]
    }
  ]
}
```

**Behavior:**
Reads from the file dependency graph built during import-driven discovery.
The agent can see the entire struct structure of the project and understand
what depends on what — without reading any source files.

#### `structs`

List all structs in the compiled program.

**Parameters:**
- `limit` (optional, int) — max structs to return, default 50
- `offset` (optional, int) — structs to skip, default 0

**Returns:**
```json
{
  "total": 5,
  "count": 5,
  "offset": 0,
  "has_more": false,
  "structs": [
    {
      "name": "Config",
      "functions": ["load/1", "parse/1", "validate/2"],
      "types": ["ParseError"],
      "file": "lib/config.zap",
      "line": 1
    }
  ]
}
```

**Behavior:**
With one-struct-per-file and name=path convention, the struct list can be
derived from the file system (`lib/` tree) for discovery, enriched with type
information from the compilation state.

### Type system queries

#### `types`

Get type information for a function.

**Parameters:**
- `function` (string) — fully qualified function name (e.g., `Config.load`)

**Returns:**
```json
{
  "name": "Config.load",
  "struct": "Config",
  "file": "lib/config.zap",
  "arity": 1,
  "params": [
    {
      "name": "path",
      "type": "String",
      "ownership": "shared"
    }
  ],
  "return_type": "Map(String, String)",
  "return_ownership": "shared"
}
```

#### `type_at`

Get the resolved type for any expression at a source location.

**Parameters:**
- `file` (string) — source file path
- `line` (int) — line number
- `column` (int) — column number

**Returns:**
```json
{
  "type": "String",
  "ownership": "unique",
  "source": "IO.read_file(path)"
}
```

**Behavior:**
Uses the TypeChecker's expression-to-type mapping to look up the type at the
given span. Returns the resolved type, ownership qualifier, and the source
expression text.

#### `scope`

Get what's visible in a given scope.

**Parameters:**
- `struct` (string) — struct name
- `function` (optional, string) — function name within the struct

**Returns:**
```json
{
  "bindings": [
    { "name": "path", "type": "String", "kind": "parameter" },
    { "name": "raw", "type": "String", "kind": "local" }
  ],
  "functions": [
    { "name": "parse", "arity": 1, "visibility": "public" },
    { "name": "validate", "arity": 2, "visibility": "private" }
  ],
  "imports": ["IO", "Kernel"],
  "types": ["Config", "ParseError"]
}
```

**Behavior:**
Reads from the scope graph. If only `struct` is given, returns the struct-level
scope. If `function` is also given, returns the function's scope (parameters,
locals, captures) plus everything visible from the enclosing struct scope.

### Call graph and effect queries

#### `call_graph`

Get the call graph for a function.

**Parameters:**
- `function` (string) — fully qualified function name
- `direction` (optional, enum) — `callees` (default), `callers`, or `both`
- `depth` (optional, int) — transitive depth, default 1, max 10

**Returns:**
```json
{
  "function": "Config.load",
  "file": "lib/config.zap",
  "callees": [
    {
      "name": "IO.read_file",
      "struct": "IO",
      "file": "lib/io.zap",
      "call_sites": [{ "line": 3, "column": 9 }]
    },
    {
      "name": "Config.parse",
      "struct": "Config",
      "file": "lib/config.zap",
      "call_sites": [{ "line": 4, "column": 3 }]
    }
  ]
}
```

**Behavior:**
Reads from the interprocedural analysis call graph. Depth > 1 follows the graph
transitively. The agent can ask "what does this function call?" or "who calls
this function?" without reading source.

#### `summary`

Get the interprocedural summary for a function.

**Parameters:**
- `function` (string) — fully qualified function name

**Returns:**
```json
{
  "function": "Config.load",
  "file": "lib/config.zap",
  "params": [
    {
      "name": "path",
      "escapes_to_heap": false,
      "returned": false,
      "passed_to_unknown": false,
      "read_only": true
    }
  ],
  "return": {
    "from_param": null,
    "fresh_allocation": true
  },
  "may_diverge": false
}
```

**Behavior:**
Reads from `AnalysisContext.function_summaries`. This tells the agent exactly
how a function uses its parameters — without reading the function body.

#### `effects`

Get the compiler-derived effects for a function.

**Parameters:**
- `function` (string) — fully qualified function name

**Returns:**
```json
{
  "function": "Config.load",
  "file": "lib/config.zap",
  "effects": ["FileSystem.read"],
  "pure": false,
  "call_chain": [
    { "function": "Config.load", "calls": "IO.read_file", "line": 5 },
    { "function": "IO.read_file", "calls": ":zig.read", "line": 3 }
  ]
}
```

**Behavior:**
Reads from the interprocedural analysis effect summaries. The compiler derives
effects by tracing the call graph transitively — leaf functions that call
`:zig.*` intrinsics are tagged with their effect category, and effects
propagate upward through the call graph. Functions annotated `@debug` are
excluded from effect derivation.

The agent can query any function's side effects without reading its body or
tracing the call graph manually.

### Escape and memory queries

#### `escape`

Get escape analysis results for a function.

**Parameters:**
- `function` (string) — fully qualified function name
- `limit` (optional, int) — max values to return, default 50
- `offset` (optional, int) — values to skip, default 0

**Returns:**
```json
{
  "function": "Config.load",
  "file": "lib/config.zap",
  "total": 3,
  "count": 3,
  "offset": 0,
  "has_more": false,
  "values": [
    {
      "name": "path",
      "local_id": 0,
      "escape_state": "no_escape",
      "allocation_strategy": "stack_function"
    },
    {
      "name": "raw",
      "local_id": 1,
      "escape_state": "global_escape",
      "allocation_strategy": "heap_arc"
    },
    {
      "name": "<tuple at line 5>",
      "local_id": 3,
      "escape_state": "bottom",
      "allocation_strategy": "eliminated"
    }
  ]
}
```

**Behavior:**
Reads from `AnalysisContext.escape_states` and
`AnalysisContext.allocation_strategies`. Each value gets its escape lattice state
(bottom/no_escape/block_local/function_local/arg_escape_safe/global_escape) and
the resulting allocation strategy
(eliminated/scalar_replaced/stack_block/stack_function/caller_region/heap_arc).

The agent can see exactly where memory is allocated and why. If it's writing
performance-sensitive code, this is direct feedback on whether its approach
causes heap allocations.

#### `regions`

Get region assignments for a function.

**Parameters:**
- `function` (string) — fully qualified function name
- `limit` (optional, int) — max assignments to return, default 50
- `offset` (optional, int) — assignments to skip, default 0

**Returns:**
```json
{
  "function": "Config.load",
  "file": "lib/config.zap",
  "total": 3,
  "count": 3,
  "offset": 0,
  "has_more": false,
  "assignments": [
    { "local_id": 0, "region": "function_frame", "multiplicity": "one" },
    { "local_id": 1, "region": "heap", "multiplicity": "many" },
    { "local_id": 3, "region": "block_2", "multiplicity": "zero" }
  ]
}
```

**Behavior:**
Reads from `AnalysisContext.region_assignments`. Shows which memory region each
value lives in and its MLKit multiplicity (zero/one/many), which determines
storage mode.

#### `ownership`

Get ownership flow through a function.

**Parameters:**
- `function` (string) — fully qualified function name

**Returns:**
```json
{
  "function": "Config.load",
  "file": "lib/config.zap",
  "transitions": [
    {
      "from": { "name": "data", "ownership": "unique" },
      "to": { "name": "result", "ownership": "shared" },
      "kind": "share",
      "line": 7
    }
  ]
}
```

**Behavior:**
Traces ownership qualifiers (unique/shared/borrowed) through the function body,
showing where transitions occur. Reads from the TypeChecker's ownership
bindings and the IR's move_value/share_value instructions.

### Closure and specialization queries

#### `lambda_sets`

Get lambda set analysis results for a function.

**Parameters:**
- `function` (string) — fully qualified function name

**Returns:**
```json
{
  "function": "App.main",
  "file": "lib/app.zap",
  "call_sites": [
    {
      "line": 10,
      "callee_local": 5,
      "decision": "direct_call",
      "targets": ["Formatter.format"]
    },
    {
      "line": 15,
      "callee_local": 8,
      "decision": "switch_dispatch",
      "targets": ["Handler.process", "Handler.skip"]
    }
  ]
}
```

**Behavior:**
Reads from `AnalysisContext.call_site_decisions`. Shows the compiler's
specialization decision for each closure call site — whether it was resolved to
a direct call, a switch dispatch over a small set, or left as dynamic dispatch.

#### `reuse`

Get Perceus reuse analysis results for a function.

**Parameters:**
- `function` (string) — fully qualified function name
- `limit` (optional, int) — max reuse pairs to return, default 50
- `offset` (optional, int) — pairs to skip, default 0

**Returns:**
```json
{
  "function": "List.map",
  "file": "lib/list.zap",
  "total": 1,
  "count": 1,
  "offset": 0,
  "has_more": false,
  "reuse_pairs": [
    {
      "deconstruct": { "line": 3, "type": "List(T)", "kind": "list" },
      "construct": { "line": 5, "type": "List(U)", "kind": "list" },
      "fields_reused": 1,
      "fields_total": 2
    }
  ],
  "arc_ops": {
    "retains": 2,
    "releases": 3,
    "optimized_away": 1
  }
}
```

**Behavior:**
Reads from `AnalysisContext.reuse_pairs` and `AnalysisContext.arc_ops`. Shows
where the compiler matched a pattern deconstruction with a constructor
allocation for in-place mutation (Perceus FBIP pattern). Also summarizes ARC
operations and how many were optimized away.

### Program structure queries

#### `function_list`

List all functions matching a pattern.

**Parameters:**
- `pattern` (optional, string) — glob pattern on function name
- `struct` (optional, string) — restrict to a struct
- `limit` (optional, int) — max functions to return, default 50
- `offset` (optional, int) — functions to skip, default 0

**Returns:**
```json
{
  "total": 12,
  "count": 12,
  "offset": 0,
  "has_more": false,
  "functions": [
    {
      "name": "Config.load",
      "arity": 1,
      "params": ["path :: String"],
      "return_type": "Map(String, String)",
      "visibility": "public",
      "is_closure": false,
      "file": "lib/config.zap",
      "line": 5
    }
  ]
}
```

#### `ir`

Get the IR representation of a function. This is the lowest-level view before
codegen — explicit control flow, SSA locals, typed instructions.

**Parameters:**
- `function` (string) — fully qualified function name

**Returns:**
```json
{
  "function": "Config.load",
  "file": "lib/config.zap",
  "params": [{ "name": "path", "type": "String", "id": 0 }],
  "return_type": "Map(String, String)",
  "blocks": [
    {
      "label": 0,
      "instructions": [
        { "kind": "param_get", "dest": 0, "param_index": 0 },
        { "kind": "call_direct", "dest": 1, "callee": "IO.read_file", "args": [0] },
        { "kind": "call_direct", "dest": 2, "callee": "Config.parse", "args": [1] },
        { "kind": "ret", "value": 2 }
      ]
    }
  ]
}
```

**Behavior:**
Serializes the IR function directly. This gives the agent a view of the code as
the compiler sees it — after desugaring, dispatch resolution, pattern match
compilation, and lowering. Useful for understanding exactly what the compiler
will generate.

---

## MCP Resources

In addition to tools, the server exposes read-only resources via MCP's resource
protocol. Resources are for data the agent reads by URI without parameters.

#### `zap://diagnostics`

Current diagnostics from the most recent compilation. Subscribable — the server
sends a notification when diagnostics change after recompilation.

#### `zap://source/{file}`

Source file content. Example: `zap://source/lib/config.zap`.

#### `zap://struct/{name}`

Source file for a struct, resolved via the naming convention.
Example: `zap://struct/Config.Parser` resolves to `lib/config/parser.zap`.

#### `zap://deps`

The full struct dependency graph. Subscribable — updated on recompilation.

Resources complement tools: the agent uses tools for parameterized queries
(`escape("Config.load")`) and resources for ambient state it wants to
subscribe to (`zap://diagnostics`, `zap://deps`).

---

## Agent workflow

### The compile-query-edit loop

The canonical agent workflow with `zap mcp`:

```
+---------------------------------------------+
|  1. Agent writes/edits a source file        |
|  2. Agent calls compile(file: "lib/app.zap")|
|     +-- incremental: only recompiles app.zap|
|     |   and its dependents                  |
|     +-- success -> query tools reflect      |
|     |              updated state            |
|     +-- failure -> structured diagnostics   |
|                    for the affected files    |
|  3. Agent queries analysis tools:           |
|     - types, type_at for types              |
|     - call_graph, deps for dependencies     |
|     - escape for memory behavior            |
|     - effects for side effects              |
|     - summary for function contracts        |
|  4. Agent uses compiler-verified facts      |
|     to decide its next edit                 |
|  5. Goto 1                                  |
|                                             |
|  When ready:                                |
|  6. Agent calls build                       |
|  7. Agent calls run or test                 |
+---------------------------------------------+
```

### Example: agent fixes a type error

1. Agent calls `compile(file: "lib/app.zap")` after editing it
2. Response: `success: false, phase: "typecheck", files_compiled: 1` with
   diagnostic for `lib/app.zap`
3. Agent reads the help text, edits line 12
4. Agent calls `compile(file: "lib/app.zap")` again
5. Response: `success: true, files_compiled: 1` — only `app.zap` recompiled

### Example: agent checks memory behavior

1. Agent calls `escape("HotPath.process")`
2. Response shows `data` has `escape_state: global_escape`,
   `allocation_strategy: heap_arc`
3. Agent restructures the code to keep `data` function-local
4. Agent calls `compile(file: "lib/hot_path.zap")`, then
   `escape("HotPath.process")` again
5. Response shows `data` now has `escape_state: function_local`,
   `allocation_strategy: stack_function`

### Example: agent understands a function without reading its body

1. Agent needs to call `Config.load` but hasn't read its source
2. Agent calls `types("Config.load")` — gets parameter types, return type,
   ownership, and the file path `lib/config.zap`
3. Agent calls `summary("Config.load")` — learns that `path` is read-only
   and doesn't escape, return value is a fresh allocation
4. Agent calls `effects("Config.load")` — learns it performs
   `FileSystem.read` with the full call chain
5. Agent calls `deps(struct: "Config")` — sees it imports `Config.Parser`
   and `IO`
6. Agent has a complete understanding of the function's contract,
   dependencies, and side effects from four MCP calls, zero source reads

---

## Implementation

### Phase 1: Server skeleton and compilation tools

Build the MCP server infrastructure and the core compilation tools.

**Deliverables:**
- `src/mcp_server.zig` — MCP stdio transport, JSON-RPC message handling,
  tool dispatch, resource serving
- `zap mcp` subcommand in CLI
- `compile` tool — runs compilation, holds state, returns structured
  diagnostics, supports incremental recompilation via `file` parameter
- `build` tool — runs `compileToNative`, returns binary path
- `run` tool — executes binary, captures output
- `test` tool — builds and runs tests, returns structured results
- `diagnostics` tool — returns cached diagnostics, filterable by file
- `source` tool — reads source files by path or struct name, with optional
  type annotations
- `zap://diagnostics` resource

**Implementation notes:**
- The server wraps the two-pass compilation pipeline and keeps per-file
  `CompilationUnit`s plus a shared `CompilationContext` alive between calls
- `CompilationContext` holds the shared scope graph, type store, and interner
- Each `CompilationUnit` holds a file's AST and IR
- For incremental recompilation, the server tracks the file dependency graph.
  When a file changes, it re-runs pass 1 for that file, diffs the scope graph,
  and re-runs pass 2 for affected files.
- Diagnostics are per-file, stored keyed by file path
- Log to stderr, never stdout (stdio transport requirement)

### Phase 2: Struct dependency and type queries

Expose the file dependency graph, type checker, and scope graph.

**Deliverables:**
- `deps` tool
- `structs` tool (with pagination)
- `types` tool
- `type_at` tool
- `scope` tool
- `function_list` tool (with pagination)
- `zap://struct/{name}` resource
- `zap://deps` resource

**Implementation notes:**
- `deps` reads from the file dependency graph built during import-driven
  discovery. Struct names resolve to files via the naming convention.
- `structs` can be derived from the file system (`lib/` tree) for discovery,
  enriched with type information from compilation state
- `types` reads function signatures from the per-file IR programs and enriches
  with ownership from the scope graph
- `type_at` requires a span-to-type lookup per file
- `source` resolves struct names to file paths via the naming convention

### Phase 3: Call graph, effects, and interprocedural queries

Expose the call graph, function summaries, and derived effects.

**Deliverables:**
- `call_graph` tool
- `summary` tool
- `effects` tool

**Implementation notes:**
- The interprocedural analyzer builds a `CallGraph` with `callees` and
  `callers` maps keyed by `FunctionId`. With per-file IR, function IDs are
  global (assigned during pass 3 merge).
- `effects` reads from the effect derivation results in the interprocedural
  analysis. Effects propagate upward from `:zig.*` intrinsic leaf calls.
- All responses include `file` fields since struct names map to files

### Phase 4: Escape analysis and memory queries

Expose the analysis pipeline results.

**Deliverables:**
- `escape` tool (with pagination)
- `regions` tool (with pagination)
- `ownership` tool
- `reuse` tool (with pagination)

**Implementation notes:**
- `AnalysisContext` stores escape states in
  `AutoArrayHashMap(ValueKey, EscapeState)` where
  `ValueKey = { function: FunctionId, local: LocalId }`. Filter by function,
  map `LocalId` back to names using the IR function's params and local
  variable names.
- Region assignments similarly keyed by `ValueKey`
- Perceus reuse pairs stored as `ArrayList(ReusePair)`. Filter by function.
- ARC ops stored as `ArrayList(ArcOperation)`. Summarize per function.

### Phase 5: Closure and IR queries

Expose lambda sets and raw IR.

**Deliverables:**
- `lambda_sets` tool
- `ir` tool

**Implementation notes:**
- Lambda set results are in `AnalysisContext.call_site_decisions` (per-call-site
  specialization decisions) and `AnalysisContext.lambda_sets` (per-local lambda
  set memberships). Serialize per function.
- `ir` serializes `ir.Function` directly. Map instruction variants to JSON
  objects. Start with the most common instruction types and add the rest
  incrementally.

---

## Design decisions

### Why MCP over LSP

LSP is designed for IDE interactions — hover, completion, go-to-definition. It's
request-response over a predefined set of capabilities. You can't add custom
queries like "what's the escape state of this value?" without non-standard
extensions that no client understands.

MCP is designed for tool use by AI agents. Each tool has a name, typed
parameters, and a structured response. Adding a new query is adding a new tool.
The agent discovers tools dynamically. The protocol is built for exactly this
use case.

### Why not just better error messages

Error messages are one-directional: the compiler tells you what's wrong. Query
tools are bidirectional: the agent asks what it wants to know. An agent
debugging a performance issue doesn't need error messages — it needs escape
analysis results. An agent planning a refactor needs the call graph. An agent
understanding unfamiliar code needs type information and function summaries.
Errors are one tool. The compiler's full analysis is dozens.

### Why in-memory over disk artifacts

1. **Speed** — queries are hashmap lookups and JSON serialization, not file I/O
   and parsing
2. **Consistency** — incremental recompilation atomically updates affected
   artifacts. No stale data.
3. **Granularity** — the server controls what to expose at what level of detail.
   Raw analysis dumps would overwhelm an agent. Targeted query responses give
   exactly the right information.
4. **Incremental by default** — the server knows the file dependency graph and
   tracks what changed. Recompilation is precise.

### Why the compiler owns the MCP server (not a separate process)

The MCP server is part of the `zap` binary, not a separate wrapper. It links
against the same compiler code, calls the same functions, and holds the same
data structures. No serialization boundary between the compiler and the server
except at the MCP JSON-RPC layer. This means:

- Zero overhead for queries — direct struct access
- No data duplication
- New compiler features automatically available to the server
- One binary to distribute

### Why tools over resources for queries

MCP offers both tools (parameterized, agent-invoked) and resources (URI-based,
subscribable). Query tools like `escape`, `types`, and `call_graph` could be
modeled as either. We chose tools because:

- Queries need parameters (function name, depth, direction, pagination)
- Resources are better for ambient state the agent subscribes to
- Tools give agents explicit control over what they query and when

Resources are used for state that changes on recompilation and benefits from
push notifications: `zap://diagnostics`, `zap://deps`,
`zap://struct/{name}`, `zap://source/{file}`.

---

## Future work

### Watch mode

`zap mcp` could watch source files and automatically recompile on change.
Since the server already tracks the file dependency graph and supports
incremental recompilation, watch mode is a thin layer on top: file watcher
detects change, server recompiles affected files, pushes updated diagnostics
via resource subscriptions. The agent wouldn't need to call `compile`
explicitly.

### Compiler-guided generation

Instead of the agent generating code and then checking it, the server could
expose tools that help *during* generation:

- `completions(file, line, col)` — what's valid here? Types in scope,
  functions callable, bindings available
- `expected_type(file, line, col)` — what type does the context expect at
  this position?
- `validate_partial(source)` — run the parser/typechecker on incomplete
  source and report what's valid so far

This moves from "compile, get errors, fix" to "ask the compiler what's valid
before writing it."

### Integration with Cog

The Zap MCP server could be registered as a Cog MCP provider, giving Cog's
memory and debugging infrastructure direct access to Zap's compilation analysis.
Cog's `code_query` and `code_explore` tools would be backed by the compiler's
own understanding of the program rather than a SCIP index built from source
text.

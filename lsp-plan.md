# Zap LSP - Comprehensive Implementation Plan

## Context

Zap is an Elixir-like language compiled to native binaries via Zig's compiler infrastructure. The codebase has strong LSP prerequisites: `SourceSpan` on every AST node, a `DiagnosticEngine` with rich error reporting (severity, labels, help text, suggestions, error codes), a `ScopeGraph` with scope-chain lookup (`resolveBinding`, `resolveFamily`, `collectVisibleBindingNames`), and a `TypeChecker` with expression-to-type mapping (`expr_types`). The compiler pipeline has clean phase separation (parse -> collect -> macro -> desugar -> typecheck -> HIR -> IR).

The LSP will be built as a `zap lsp` subcommand in the existing binary. It only needs the frontend pipeline (through type checking) -- HIR, IR, escape analysis, ZIR, and LLVM are never invoked.

---

## Architecture

### Transport
- JSON-RPC 2.0 over stdin/stdout with `Content-Length` headers
- Single-threaded event loop: read request -> dispatch -> respond
- Logging to stderr (stdout is the protocol channel)

### State Model
```
LspServer
  ├── documents: HashMap(URI -> DocumentState)
  ├── stdin / stdout (buffered)
  └── initialized: bool

DocumentState
  ├── uri, source, version
  └── analysis: ?AnalysisResult (owned arena)

AnalysisResult (all allocated in one ArenaAllocator)
  ├── program: ast.Program
  ├── interner: StringInterner
  ├── scope_graph: ScopeGraph
  ├── type_checker: TypeChecker
  ├── diagnostics: []Diagnostic
  └── position_mapper: PositionMapper
```

On every re-analysis: create new arena, run pipeline, swap result, destroy old arena.

### Position Mapping (Cross-cutting)
Stdlib is prepended to user source. `PositionMapper` converts between:
- **LSP positions** (0-based line, 0-based UTF-16 character) in the user's file
- **Internal positions** (`SourceSpan` with 1-based line/col in combined source)

Uses `stdlib_line_count` (already tracked by `prependStdlib()` and `TypeChecker.stdlib_line_count`). Filters out diagnostics whose spans fall within the stdlib region.

---

## Phase 1: Diagnostics on Save

### LSP Methods
| Method | Direction | Purpose |
|--------|-----------|---------|
| `initialize` | C->S | Negotiate capabilities |
| `initialized` | C->S | No-op ack |
| `shutdown` / `exit` | C->S | Lifecycle |
| `textDocument/didOpen` | C->S | Store text, analyze, publish diagnostics |
| `textDocument/didSave` | C->S | Re-analyze, publish diagnostics |
| `textDocument/didClose` | C->S | Remove document state |
| `textDocument/publishDiagnostics` | S->C | Push diagnostics |

### New Files
| File | Purpose | ~Lines |
|------|---------|--------|
| `src/lsp/Server.zig` | `LspServer` struct, main loop, request dispatch, analysis pipeline | 500 |
| `src/lsp/transport.zig` | `readMessage`, `writeMessage`, Content-Length framing | 200 |
| `src/lsp/json_writer.zig` | Minimal JSON serializer (beginObject/field/string/int/endObject) | 200 |
| `src/lsp/types.zig` | LSP protocol type definitions (Position, Range, Diagnostic, etc.) | 150 |
| `src/lsp.zig` | Namespace re-export for `src/lsp/*.zig` | 10 |

### Modified Files
| File | Change |
|------|--------|
| `src/main.zig` | Add `"lsp"` command branch, `cmdLsp()` function |
| `src/root.zig` | Add `pub const lsp = @import("lsp.zig");` |

### Analysis Pipeline (LSP-specific `analyzeFrontend`)
A stripped-down `compileFrontend` that:
1. `stdlib.prependStdlib()` -> combined source + line count
2. `Parser.init()` + `parseProgram()` -- collect errors, continue on failure
3. `Collector.init()` + `collectProgram()` -- collect errors
4. `MacroEngine.init()` + `expandProgram()` -- collect errors
5. `Desugarer.init()` + `desugarProgram()` -- collect errors
6. `TypeChecker.init()` + `checkProgram()` + `checkUnusedBindings()`
7. **Stop here.** No HIR, IR, or backend.

Each phase catches errors and continues to the next -- produce as much analysis as possible.

### Diagnostic Mapping
- `Severity`: `.@"error"` -> 1, `.warning` -> 2, `.note` -> 3, `.help` -> 4
- `SourceSpan` -> LSP `Range` via PositionMapper
- `Diagnostic.code` -> LSP `Diagnostic.code`
- `Diagnostic.suggestion` -> saved for Phase 4 code actions
- Source: always `"zap"`
- Filter: skip diagnostics where `span.line <= stdlib_line_count`

### Initialize Response Capabilities
```json
{
  "capabilities": {
    "textDocumentSync": {
      "openClose": true,
      "save": { "includeText": true },
      "change": 1
    }
  },
  "serverInfo": { "name": "zap-lsp", "version": "0.1.0" }
}
```

### Key Reuse
- `compiler.zig`: Pattern for `compileFrontend` pipeline orchestration
- `diagnostics.zig`: `DiagnosticEngine`, `Diagnostic`, `Severity`, `Suggestion`
- `stdlib.zig`: `prependStdlib()` for source preparation
- All frontend structs via `root.zig` re-exports

---

## Phase 2: Navigation (Hover, Go-to-Definition, Completion)

### LSP Methods
| Method | Purpose |
|--------|---------|
| `textDocument/hover` | Show type at cursor |
| `textDocument/definition` | Jump to symbol definition |
| `textDocument/completion` | Suggest visible names |

### New File
| File | Purpose | ~Lines |
|------|---------|--------|
| `src/lsp/analysis.zig` | `PositionMapper`, `findNodeAtOffset()`, `findScopeAtOffset()`, cursor-to-scope resolution | 400 |

### Core Algorithm: `findNodeAtOffset(program, byte_offset) -> ?NodeInfo`
Recursive AST descent checking `span.start <= offset <= span.end`, returning the tightest enclosing node. Leverages `Expr.getMeta()` (ast.zig:322-356) which returns span for any expression variant.

### Hover
1. Find AST node at cursor via `findNodeAtOffset`
2. If `var_ref`: `ScopeGraph.resolveBinding(scope_id, name)` -> get binding, look up type in `TypeChecker.expr_types` or `binding.type_id`
3. If `call`: `ScopeGraph.resolveFamily(scope_id, name, arity)` -> show function signature
4. If any expr: look up in `TypeChecker.expr_types` (keyed by `@intFromPtr(expr)`)
5. Format as markdown: `` ```zap\nx :: i64\n``` ``

### Go-to-Definition
1. Find AST node at cursor
2. If `var_ref`: `resolveBinding()` -> return `binding.span`
3. If `call`: `resolveFamily()` -> return `family.clauses[0].decl.meta.span`
4. If `struct_ref`: look up in `scope_graph.structs` -> return struct decl span
5. If definition is in stdlib (line <= stdlib_line_count): return null

### Completion
1. Find scope at cursor via `node_scope_map` (ScopeGraph maps `span.start -> ScopeId`)
2. `ScopeGraph.collectVisibleBindingNames(scope_id)` -> variable completions (kind: 6)
3. `ScopeGraph.collectVisibleFunctionNames(scope_id)` -> function completions (kind: 3)
4. Struct names from `scope_graph.structs` -> struct completions (kind: 9)
5. Type names from `scope_graph.types` -> type completions (kind: 7)
6. Keyword completions based on context (inside struct: `def`, `defp`, `defstruct`, etc.)
7. Trigger character: `.` (for struct-qualified access)

### Updated Capabilities
```json
"hoverProvider": true,
"definitionProvider": true,
"completionProvider": { "triggerCharacters": ["."] }
```

---

## Phase 3: Error-Tolerant Parsing

### Goal
Parser produces partial ASTs for incomplete/broken code, enabling diagnostics and navigation while typing.

### Current State
Parser already has `synchronize()` (parser.zig:162-190) that skips to `def`/`defp`/`struct`/`end` boundaries. `parseProgram()` catches errors per top-level item and calls `synchronize()`. This is a foundation to extend.

### AST Change
Add `error_expr: NodeMeta` variant to `ast.Expr` union (ast.zig:266). Add matching case in `Expr.getMeta()`. This represents a parse failure at a specific source location.

### Parser Changes (`src/parser.zig`)
1. Add `error_tolerant: bool = false` field to Parser struct
2. When `error_tolerant`:
   - `parseProgram()` never returns `error.ParseError` -- always returns partial `ast.Program`
   - Expression parsing wraps failures in `error_expr` nodes
   - Statement parsing catches errors and skips to next statement boundary (newline + valid start token)
   - Block parsing handles missing `end` at EOF/dedent
3. Add `synchronizeStatement()` -- finer-grained than `synchronize()`, stops at newline + expression-start tokens

### Downstream Pass Hardening
Each pass adds a skip case for `error_expr`:
- **Collector** (`src/collector.zig`): skip in `collectExprScopes`
- **MacroEngine** (`src/macro.zig`): pass through unchanged
- **Desugarer** (`src/desugar.zig`): pass through unchanged
- **TypeChecker** (`src/types.zig`): assign `TypeStore.ERROR` type, continue

### LSP Change
Enable `textDocument/didChange` with analysis (still `Full` sync, kind 1). Add simple debounce: if another `didChange` is already queued for the same URI, skip analysis for the earlier version.

---

## Phase 4: Symbols, References, Rename, Code Actions

### LSP Methods
| Method | Purpose |
|--------|---------|
| `textDocument/documentSymbol` | Document outline |
| `textDocument/references` | Find all references |
| `textDocument/rename` | Rename symbol |
| `textDocument/prepareRename` | Validate rename |
| `textDocument/codeAction` | Quick fixes from `Suggestion` |
| `textDocument/signatureHelp` | Function signature while typing args |

### New File
| File | Purpose | ~Lines |
|------|---------|--------|
| `src/lsp/references.zig` | `ReferenceIndex`, `buildReferenceIndex()` from AST walk | 300 |

### Document Symbols
Walk `program.structs` and `program.top_items` producing hierarchy:
- `StructDecl` -> Struct (2)
  - `FunctionDecl` -> Function (12), name includes arity
  - `StructDecl` -> Struct (23), with Field children
  - `EnumDecl` -> Enum (10), with EnumMember children
  - `TypeDecl` -> TypeParameter (26)

### Reference Index
Post-analysis AST walk builds:
```
binding_refs: HashMap(BindingId -> []SourceSpan)
family_refs: HashMap(FunctionFamilyId -> []SourceSpan)
```
Walk all `var_ref` nodes -> resolve binding, record span. Walk all `call` nodes -> resolve family, record span.

### Rename
`prepareRename`: verify cursor is on a renameable symbol (not stdlib, not keyword). `rename`: collect all refs + definition, produce `WorkspaceEdit` with `TextEdit` per location.

### Code Actions
Map `Diagnostic.suggestion` -> CodeAction (kind: `quickfix`):
- `suggestion.span` -> TextEdit range
- `suggestion.replacement` -> TextEdit new text
- `suggestion.description` -> CodeAction title

### Signature Help
Trigger on `(` and `,`. Detect enclosing call expression, look up function family, return parameter info. Uses `ScopeGraph.resolveFamily()` + `TypeChecker.FunctionSignature`.

---

## Phase 5: Multi-File and Incremental

### Architecture
```
ProjectState
  ├── project_root, manifest (from build.zap)
  ├── files: HashMap(path -> FileState)
  ├── struct_index: HashMap(struct_name -> {file, scope_id})
  └── stdlib_state (parsed once, shared)
```

### Key Changes
1. **Parse stdlib once** at startup. Freeze its AST/scope graph/types. Share across all file analyses.
2. **Per-file analysis**: Each file parsed independently. Collector starts with pre-populated stdlib scopes.
3. **Dependency tracking**: Record import relationships. Re-analyze dependents when a file changes.
4. **Project discovery**: On `initialize`, find `build.zap`, extract source paths, watch for changes.
5. **Cross-file go-to-definition**: Look up struct in `struct_index`, navigate to its file.

### New LSP Methods
- `workspace/didChangeWatchedFiles` (file creation/deletion)
- Incremental text sync (kind 2) -- optional, full re-parse per file is fast enough

### New File
| File | Purpose | ~Lines |
|------|---------|--------|
| `src/lsp/project.zig` | `ProjectState`, manifest parsing, dependency tracking, file discovery | 500 |

### Compiler Changes
Refactor `compileFrontend()` or create new entry point that accepts a pre-built stdlib scope graph and merges per-file scopes.

---

## Implementation Order

Phase 2 depends on Phase 1. Phase 3 is independent of Phase 2 (can parallelize). Phase 4 depends on Phase 2. Phase 5 depends on all.

**Recommended**: Phase 1 -> Phase 2 -> Phase 3 -> Phase 4 -> Phase 5

## File Summary

### New Files (all phases)
| File | Phase | Purpose |
|------|-------|---------|
| `src/lsp.zig` | 1 | Namespace re-export |
| `src/lsp/Server.zig` | 1 | Main server, event loop, dispatch |
| `src/lsp/transport.zig` | 1 | JSON-RPC framing |
| `src/lsp/json_writer.zig` | 1 | JSON serialization |
| `src/lsp/types.zig` | 1 | LSP protocol types |
| `src/lsp/analysis.zig` | 2 | Position mapping, cursor resolution |
| `src/lsp/references.zig` | 4 | Reference index |
| `src/lsp/project.zig` | 5 | Multi-file project state |

### Modified Files (all phases)
| File | Phase | Change |
|------|-------|--------|
| `src/main.zig` | 1 | Add `lsp` command |
| `src/root.zig` | 1 | Re-export lsp struct |
| `src/ast.zig` | 3 | Add `error_expr` variant |
| `src/parser.zig` | 3 | `error_tolerant` mode, improved recovery |
| `src/collector.zig` | 3 | Skip `error_expr` |
| `src/macro.zig` | 3 | Skip `error_expr` |
| `src/desugar.zig` | 3 | Skip `error_expr` |
| `src/types.zig` | 3 | Handle `error_expr`, (4) reference tracking |
| `src/compiler.zig` | 5 | New entry point for pre-built stdlib |

## Verification

### Phase 1
1. `zig build test` -- all existing tests pass
2. `zap lsp` starts, responds to `initialize`
3. Open a `.zap` file in VS Code/Neovim -> red squiggles appear for errors
4. Save a file with errors -> diagnostics update

### Phase 2
1. Hover over a variable -> type shown
2. Ctrl-click a function call -> jumps to definition
3. Type partial name -> completion list appears

### Phase 3
1. Type incomplete code (e.g., `x +`) -> partial diagnostics, not full-file error
2. Other functions in the same file still show diagnostics correctly

### Phase 4
1. Outline view shows struct/function/type hierarchy
2. Find References on a variable -> all usages highlighted
3. Rename a variable -> all references updated

### Phase 5
1. Cross-file go-to-definition works
2. Edit a struct in one file -> diagnostics update in files that import it

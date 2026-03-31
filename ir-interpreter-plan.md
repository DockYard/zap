# IR Interpreter Plan

> Execute compiled functions at compile time. Modules compile in dependency
> order. Each module's functions are callable by later modules during their
> compilation step.

## Architecture

### How it fits in the compilation pipeline

```
Pass 1: Discovery + Collection (all files)
  Discover files from entry point
  Parse each file
  Collect all declarations into shared scope graph + type store

Pass 2: Compile each module in dependency order
  For each module (topological order):
    a. Evaluate attribute expressions
       - Literal values: store directly
       - Computed values: call IR interpreter to execute the expression
       - The interpreter can call functions from already-compiled modules
    b. Substitute attribute values into function bodies
    c. Macro expand → Desugar → Type check → HIR → IR
    d. Register this module's compiled IR with the interpreter
       (now available for later modules' compile-time calls)

Pass 3: Merge + backend
  Merge all per-module IR programs
  Run analysis pipeline
  ZIR backend → native binary
```

The key step is **2d**: after a module compiles, its IR is registered with
the interpreter. When the next module's attribute expressions call functions
from the just-compiled module, the interpreter executes them.

### The interpreter

The interpreter is a Zig module (`src/ir_interpreter.zig`) that:

- Accepts an `ir.Program` (or individual `ir.Function`s) to register
- Executes a function by name, given argument values
- Returns a compile-time `Value` (integer, float, string, atom, bool, nil,
  list, tuple, map, struct)
- Walks IR instructions sequentially within basic blocks
- Maintains a call stack of frames, each with a local value array
- Has a configurable step counter to abort infinite loops

### Value representation

The interpreter operates on a tagged union of compile-time values:

```zig
pub const Value = union(enum) {
    int: i64,
    float: f64,
    string: []const u8,
    atom: []const u8,
    bool_val: bool,
    nil_val: void,
    list: []const Value,
    tuple: []const Value,
    map: []const MapEntry,
    struct_val: StructValue,
};

pub const MapEntry = struct {
    key: Value,
    value: Value,
};

pub const StructValue = struct {
    name: []const u8,
    fields: []const StructFieldValue,
};

pub const StructFieldValue = struct {
    name: []const u8,
    value: Value,
};
```

All values are arena-allocated per compile-time evaluation. No garbage
collection needed — the arena is freed after each module's compilation step.

### Stack frames

```zig
pub const Frame = struct {
    function: *const ir.Function,
    locals: []Value,           // indexed by LocalId
    prev_block: ?ir.LabelId,  // for phi resolution
    return_dest: ?ir.LocalId, // where to store the return value in caller
};
```

The interpreter maintains a stack of frames (`ArrayList(Frame)`). On
`call_direct`, push a new frame. On `ret`, pop and write the return value
to the caller's `return_dest` local.

---

## Phases

### Phase A: Interpreter skeleton + constants + arithmetic

**Goal:** Evaluate simple constant expressions like `@timeout :: i64 = 5000 * 2`.

**New file: `src/ir_interpreter.zig`**

Create the interpreter with:
- `Value` tagged union (all variants)
- `Frame` struct
- `Interpreter` struct with:
  - `registered_functions: StringHashMap(*const ir.Function)` — functions
    available for compile-time calls
  - `call_stack: ArrayList(Frame)`
  - `step_count: u64` and `step_limit: u64`
  - `allocator: Allocator` (arena)

**Instruction support:**
- `const_int` → `Value{ .int = value }`
- `const_float` → `Value{ .float = value }`
- `const_string` → `Value{ .string = value }`
- `const_bool` → `Value{ .bool_val = value }`
- `const_atom` → `Value{ .atom = value }`
- `const_nil` → `Value{ .nil_val = {} }`
- `local_set` → write value to `locals[dest]`
- `local_get` → read from `locals[src]`
- `ret` → return value from current frame

**Binary operations** (on int and float values):
- `add`, `sub`, `mul`, `div` → arithmetic on `Value.int` or `Value.float`
- `eq`, `neq`, `lt`, `gt`, `lte`, `gte` → comparison, return `Value.bool_val`
- `concat` → string concatenation, return `Value.string`

**Unary operations:**
- `negate` → negate int or float
- `not_op` → boolean not

**Public API:**
```zig
pub fn init(alloc: Allocator) Interpreter
pub fn registerFunction(self: *Interpreter, name: []const u8, func: *const ir.Function) !void
pub fn call(self: *Interpreter, name: []const u8, args: []const Value) !Value
pub fn evalExpr(self: *Interpreter, func: *const ir.Function) !Value  // for no-arg functions
```

**Tests:**
- Evaluate `const_int 42` → returns `Value{ .int = 42 }`
- Evaluate `5 + 3` (const_int 5, const_int 3, add) → returns `Value{ .int = 8 }`
- Evaluate `"hello" <> " world"` → returns `Value{ .string = "hello world" }`
- Evaluate `10 * 2 + 1` → returns `Value{ .int = 21 }`
- Step limit exceeded → returns error

**Estimated size:** ~500 lines

---

### Phase B: Function calls

**Goal:** Evaluate `@value :: i64 = MathLib.compute()` where `compute` is
a function in an already-compiled module.

**New instruction support:**
- `call_direct` → look up function by name in `registered_functions`, push
  new frame, map arguments to params, execute
- `call_named` → same but with module-qualified name
  (`Module__function` mangling)
- `param_get` → read from `locals[param_index]` (params are the first N locals)

**Frame management:**
- On `call_direct(dest, callee_name, args)`:
  1. Evaluate each argument expression to get `Value`s
  2. Look up `callee_name` in `registered_functions`
  3. Create new `Frame` with `locals` sized to the callee's local count
  4. Copy argument values into `locals[0..args.len]`
  5. Push frame onto call stack
  6. Execute callee's body
  7. Pop frame, write return value to caller's `locals[dest]`

- On `ret(value)`:
  1. Read the return value from `locals[value]`
  2. Pop current frame
  3. Write return value to caller frame's `locals[return_dest]`
  4. Resume execution in caller

**Recursion:** Supported naturally through the call stack. The step counter
prevents infinite recursion.

**Tests:**
- Call a zero-arg function that returns a constant
- Call a function with arguments: `add(3, 4)` → 7
- Call a function that calls another function (transitive)
- Recursive function: `factorial(5)` → 120
- Step limit on infinite recursion → error

**Estimated size:** ~400 lines

---

### Phase C: Control flow

**Goal:** Execute functions with if/else, case, and pattern matching.

**New instruction support:**
- `branch` → evaluate condition, jump to then or else block
- `jump` → unconditional jump to a label
- `phi` → select value based on previous block
  (iterate PhiSources, find the one whose `from_block` matches `prev_block`)
- `switch_return` / `union_switch_return` → multi-way branch on value

**Block execution:**
- The interpreter processes blocks sequentially by label
- `branch(cond, then_label, else_label)`:
  1. Read `cond` from locals
  2. If true: set `current_block = then_label`, set `prev_block`
  3. If false: set `current_block = else_label`, set `prev_block`
- Blocks are found by scanning `function.body` for matching `label`

**Tests:**
- If/else: function returns different values based on condition
- Pattern matching via switch_return
- Phi nodes: value depends on which branch was taken
- Nested control flow

**Estimated size:** ~400 lines

---

### Phase D: Data structures

**Goal:** Create and manipulate lists, tuples, maps, and structs at
compile time.

**New instruction support:**
- `tuple_init` → collect element values into `Value{ .tuple = ... }`
- `list_init` → collect element values into `Value{ .list = ... }`
- `map_init` → collect key-value pairs into `Value{ .map = ... }`
- `struct_init` → collect field values into `Value{ .struct_val = ... }`
- `field_get` → extract field from struct or tuple by name/index
- `field_set` → create new struct/map with updated field
- `enum_literal` → `Value{ .atom = variant_name }`

**Value operations:**
- List indexing: `List.at(list, index)` → extract element
- Map lookup: `Map.get(map, key)` → extract value
- String operations: length, slice, concatenation

**Tests:**
- Create a tuple `{1, "hello"}` and extract elements
- Create a list `[1, 2, 3]` and index into it
- Create a map `%{key: "value"}` and look up a key
- Create a struct and read a field
- Nested data structures

**Estimated size:** ~500 lines

---

### Phase E: I/O intrinsics

**Goal:** Enable compile-time file reads and environment variable access.

**Special-cased function calls:**
When the interpreter encounters a call to certain known functions, it
executes Zig code directly instead of interpreting IR:

- `File.read(path)` → `std.fs.cwd().readFileAlloc(alloc, path, max_size)`
  Returns `Value{ .string = contents }`
- `File.exists(path)` → `std.fs.cwd().access(path, .{})`
  Returns `Value{ .bool_val = true/false }`
- `System.get_env(name)` → `std.posix.getenv(name)`
  Returns `Value{ .string = value }` or `Value{ .nil_val = {} }`

**Resource tracking:**
The interpreter records which external resources were accessed during
compile-time evaluation:
- File paths read
- Environment variables accessed

This list is stored per-module and used for incremental recompilation: if
a tracked resource changes, the module must be recompiled.

```zig
pub const AccessedResource = union(enum) {
    file: []const u8,       // file path that was read
    env_var: []const u8,    // environment variable that was accessed
};

// On the Interpreter:
accessed_resources: ArrayList(AccessedResource),
```

**Tests:**
- Read a file at compile time, verify contents
- Read a nonexistent file → compile error
- Access environment variable
- Resource tracking records accessed files

**Estimated size:** ~200 lines

---

### Phase F: Wire into compilation pipeline

**Goal:** Connect the interpreter to the actual compilation pipeline so
modules compile in dependency order with compile-time execution.

**Changes to `src/compiler.zig`:**

Modify the per-file compilation pipeline (`compileFiles` / `compilePerFile`):

1. After pass 1 (collection), create an `Interpreter` instance
2. Determine compilation order (topological sort from FileGraph)
3. For each module in order:
   a. Evaluate attribute value expressions:
      - Literal values: convert directly to compile-time `Value`
      - Function calls: execute via the interpreter
      - Validate result against declared type
      - Store result for substitution
   b. Run attribute substitution (replace `@name` with values)
   c. Compile the module through macro expand → desugar → typecheck → HIR → IR
   d. Register the module's compiled IR functions with the interpreter

**Changes to `src/main.zig`:**

Thread the interpreter through the build pipeline. The interpreter persists
across module compilations within a single build.

**Changes to attribute substitution (`src/attr_substitute.zig`):**

Currently substitution only handles attributes with literal values (the
value is already an AST Expr node). With the interpreter, computed attribute
values are `Value`s that need to be converted to AST Expr nodes for
substitution:

```zig
fn valueToExpr(alloc: Allocator, value: Value) !*const ast.Expr {
    return switch (value) {
        .int => |v| create int_literal with v,
        .float => |v| create float_literal with v,
        .string => |v| create string_literal with v,
        .bool_val => |v| create bool_literal with v,
        .atom => |v| create atom_literal with v,
        .nil_val => create nil_literal,
        .list => |items| create list with recursive valueToExpr on items,
        .tuple => |items| create tuple with recursive valueToExpr on items,
        .map => |entries| create map with recursive valueToExpr on entries,
        .struct_val => |sv| create struct_expr with recursive valueToExpr on fields,
    };
}
```

**Tests:**
- Module A defines `compute() :: i64`, Module B uses
  `@value :: i64 = A.compute()` — verify B's attribute has the computed value
- Module A defines `generate_list() :: List(i64)`, Module B uses
  `@data :: List(i64) = A.generate_list()` — verify list substitution
- Module with no computed attributes compiles normally (no interpreter overhead)
- Compilation order respects dependencies

**Estimated size:** ~400 lines of pipeline changes

---

### Phase G: @debug erasure

**Goal:** Skip `@debug` function calls in release builds.

**Changes to `src/compiler.zig` / `src/hir.zig`:**

1. Add `optimize: Optimize` to `CompileOptions` and thread through to the
   HIR builder

2. In the HIR builder's call expression handling (`buildExpr` for `.call`),
   when resolving a module-qualified call:
   a. Look up the function family in the scope graph
   b. Check if it has a `@debug` attribute
   c. If yes AND optimize != debug:
      - Don't emit the call
      - Emit just the first argument as the result
      - The pass-through semantics (`T -> T`) guarantee correctness

3. The type checker already validates `@debug` functions have arity 1 and
   a return type. This phase adds the actual erasure.

**Changes to interprocedural analysis (`src/interprocedural.zig`):**

When propagating effects through the call graph, skip calls to functions
that have the `@debug` attribute. This means `@debug` functions don't make
their callers appear effectful.

The interprocedural analyzer needs access to function attributes. Thread
the scope graph through to the analyzer, or pre-compute a set of debug
function names.

**Tests:**
- In debug mode: `@debug` function call is emitted normally
- In release mode: `@debug` function call is skipped, argument passes through
- Effect analysis: calling a `@debug` function doesn't add effects to the caller
- Pipeline integration: `Kernel.inspect` with `@debug` works end-to-end

**Estimated size:** ~200 lines

---

### Phase H: Module intrinsics

**Goal:** Implement `Module.functions`, `Module.get_attribute`, etc. as
functions the IR interpreter handles specially.

**Approach:** `Module` is a stdlib module at `lib/module.zap` with bodyless
function declarations (signatures only). The IR interpreter recognizes calls
to `Module.*` and provides implementations by reading the scope graph.

**`lib/module.zap`:**
```zap
defmodule Module do
  @moduledoc :: String = "Compile-time module introspection."

  def name(module :: Atom) :: Atom
  def functions(module :: Atom) :: List({Atom, i64})
  def macros(module :: Atom) :: List({Atom, i64})
  def types(module :: Atom) :: List(Atom)
  def file(module :: Atom) :: String
  def is_private(module :: Atom) :: Bool
  def has_function(module :: Atom, name :: Atom, arity :: i64) :: Bool
  def get_attribute(module :: Atom, attr :: Atom) :: any
  def get_attribute(module :: Atom, attr :: Atom, function :: Atom, arity :: i64) :: any
  def has_attribute(module :: Atom, attr :: Atom) :: Bool
  def attributes(module :: Atom) :: List({Atom, any})
  def function_attributes(module :: Atom, function :: Atom, arity :: i64) :: List({Atom, any})
end
```

**Parser changes:** Support bodyless function declarations — `def name(params) :: Type`
without a `do ... end` block. These are valid only in modules whose functions
are interpreter-provided.

**Interpreter changes:**

In the `call` method, before looking up the function in `registered_functions`,
check if the call is to `Module.*`. If so, dispatch to a Zig function that
reads the scope graph:

```zig
if (std.mem.startsWith(u8, callee_name, "Module__")) {
    return self.handleModuleIntrinsic(callee_name, args);
}
```

`handleModuleIntrinsic` implementations:
- `Module__name(atom)` → return the atom itself
- `Module__functions(atom)` → find the module in scope graph, iterate
  function families, build `List({Atom, i64})`
- `Module__get_attribute(atom, attr_name)` → find module entry, look up
  attribute by name, return its value
- Etc.

**`__MODULE__` support:**

`__MODULE__` is a special form in the parser that expands to the current
module's atom literal during parsing. No interpreter involvement needed.

**Tests:**
- `Module.name(:Config)` → `:Config`
- `Module.functions(:Config)` → `[{:load, 1}, {:load_from_env, 0}]`
- `Module.get_attribute(:Config, :moduledoc)` → `"Configuration module."`
- `Module.has_function(:Config, :load, 1)` → `true`
- `Module.is_private(:InternalMod)` → `true` (for defmodulep)
- Calling `Module.*` outside compile-time context → error

**Estimated size:** ~400 lines (interpreter intrinsics + scope graph queries)

---

## Implementation order

```
Phase A: Interpreter skeleton + constants + arithmetic     ~500 lines
Phase B: Function calls                                    ~400 lines
Phase C: Control flow                                      ~400 lines
Phase D: Data structures                                   ~500 lines
Phase E: I/O intrinsics                                    ~200 lines
Phase F: Wire into compilation pipeline                    ~400 lines
Phase G: @debug erasure                                    ~200 lines
Phase H: Module intrinsics                                 ~400 lines
                                                    Total: ~3,000 lines
```

Each phase is independently compilable and testable. Phases A-E build the
interpreter. Phase F connects it to the compiler. Phases G-H use the
interpreter for specific features.

---

## Tradeoffs

### Compilation speed

Modules compile in strict dependency order. Parallel compilation is limited
to modules at the same DAG level. Most modules don't use compile-time
evaluation — only modules with computed attributes force serialization.

### Interpreter performance

The interpreter is ~10-100x slower than native execution. For typical
compile-time workloads (small computations, file reads, config parsing),
this is imperceptible. For heavy computation (generating large lookup
tables), it may add seconds to the build.

### Step counter

Default limit: 10 million operations. Configurable per-build. Prevents
infinite loops from hanging the compiler. When exceeded:
```
error: compile-time evaluation exceeded step limit (10000000 operations)
  possible infinite loop in MathLib.generate() called from @sbox
```

### Memory

Compile-time values are arena-allocated per module compilation step. The
arena is freed after each module completes. Memory usage is bounded by the
largest single compile-time evaluation, not cumulative across modules.

### I/O non-determinism

Compile-time file reads and env var access make builds dependent on external
state. The resource tracker records all accessed resources for incremental
recompilation: if a file changes, modules that read it at compile time are
recompiled.

### FFI restriction

Only Zap functions can be called at compile time. `:zig.*` intrinsics that
the interpreter knows about (println, inspect) are special-cased. C
libraries and external Zig functions cannot be called at compile time.

### Cross-compilation

Compile-time code runs on the host machine. File paths, environment
variables, and integer behavior reflect the host, not the target. In
practice this is acceptable — Zig and Elixir both operate this way.

### Bodyless functions

`Module` uses bodyless function declarations (`def name(params) :: Type`
without `do...end`). This is a new parser feature. Bodyless functions are
only valid in modules whose functions are interpreter-provided. The compiler
rejects bodyless functions in regular modules.

---

## Testing strategy

Each phase has its own unit tests in the interpreter module. Integration
tests verify the full pipeline.

**Unit tests (in `src/ir_interpreter.zig`):**
- Phase A: constant evaluation, arithmetic, string concat, step limit
- Phase B: function calls, recursion, argument passing
- Phase C: if/else, case, phi nodes
- Phase D: list/tuple/map/struct creation and access
- Phase E: file read, env var access, resource tracking

**Integration tests (in `src/integration_tests.zig`):**
- Computed attribute value from another module
- Module with only compile-time usage is dead-code-eliminated
- @debug erasure in release mode
- Module.functions returns correct data
- Compile error on step limit exceeded
- Compile error on calling not-yet-compiled module

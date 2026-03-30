# Module Attributes Plan

> Modules are compile-time atoms. Attributes are typed compile-time metadata.
> Compiled modules are callable at compile time.

## Design

### Modules as compile-time atoms

Modules in Zap are atoms that exist only at compile time. Inside macros and
attribute expressions, modules are first-class values — you can pass them
around, inspect them, read their attributes, and call their functions. At
runtime, modules don't exist — all calls are direct, all dispatch is
resolved, all metadata is erased.

```zap
# At compile time (inside a macro): modules are atoms
defmacro describe(module) do
  name = Module.name(module)
  funcs = Module.functions(module)
  # ... generate code using compile-time module info
end

# At runtime: modules are gone, calls are direct
Config.load(path)  # compiles to Config__load(path)
```

### Compilation model: dependency-ordered with compile-time execution

Modules compile in dependency order (topological sort of the DAG). When the
compiler reaches module B (which depends on A), A is **fully compiled** —
its functions are available for compile-time execution.

This means:
- Attribute values can be computed by calling functions from already-compiled
  modules
- Macros can call any function from already-compiled modules
- The result of compile-time execution is a constant that gets substituted
  into the module being compiled
- Modules used only at compile time are eliminated from the binary by LLVM's
  dead code elimination

```zap
# MathTables compiles first (no dependencies)
defmodule MathTables do
  def generate_sbox() :: List(i64) do
    Enum.map(0..255, fn i -> compute_sbox(i) end)
  end

  defp compute_sbox(i :: i64) :: i64 do
    # expensive computation
  end
end

# Crypto compiles second — MathTables is fully compiled
defmodule Crypto do
  @sbox :: List(i64) = MathTables.generate_sbox()

  def encrypt(byte :: i64) :: i64 do
    List.at(@sbox, byte)
  end
end
```

At runtime, `Crypto.encrypt` indexes into a static array. `MathTables` is
dead code — LLVM strips it from the binary entirely.

### Compile-time execution rules

Attribute values and macro bodies are **compile-time contexts**. Within
these contexts:

1. **Calls to functions in already-compiled modules execute at compile
   time.** The result must be a value representable as a constant (integer,
   float, string, atom, bool, nil, list, tuple, map, struct).

2. **Calls to functions in the current module or not-yet-compiled modules
   are compile errors.** The dependency order is strict — you can only call
   backward in the DAG.

3. **`Module.*` intrinsics are available.** These query the compiler's scope
   graph for module metadata.

4. **I/O is permitted.** File reads, environment variable access, and other
   side effects are allowed at compile time. This enables reading config
   files, embedding templates, and loading external data during compilation.

5. **The result is substituted as a constant.** When
   `@value :: i64 = Foo.compute()` evaluates to `42`, the attribute stores
   `42`. Function bodies that reference `@value` get `42` substituted inline.

```zap
# Compile-time file I/O
defmodule Templates do
  @index_html :: String = File.read("templates/index.html")

  def index() :: String do
    @index_html
  end
end

# Compile-time configuration
defmodule App do
  @config :: Map(String, any) = Jason.parse(File.read("config/app.json"))
  @port :: i64 = @config.port

  def port() :: i64 do
    @port
  end
end
```

### Compile-time evaluation engine

The compiler includes an **IR interpreter** that can execute compiled
functions at compile time. This interpreter:

- Walks IR instructions (the same SSA-style IR the compiler already produces)
- Maintains a stack of values and a call stack
- Handles function calls, control flow, arithmetic, data structure operations
- Returns the result as a compile-time constant value
- Has a step counter to detect infinite loops (aborts after N operations)
- Runs on the host architecture (for cross-compilation, compile-time code
  runs on the build machine, not the target)

The interpreter is not a full runtime — it doesn't need garbage collection
(values are arena-allocated per compile-time evaluation), doesn't support
concurrency, and doesn't need the ZIR backend. It operates on the IR that
the compiler already produces.

### Dead code elimination

Modules and functions used only at compile time contribute **zero bytes** to
the final binary. LLVM's dead code elimination removes any function that has
no runtime call sites.

```zap
# This entire module exists only at compile time
defmodule SchemaCompiler do
  def compile(path :: String) :: List({String, String}) do
    schema = File.read(path)
    parse_schema(schema)
  end

  defp parse_schema(raw :: String) :: List({String, String}) do
    # complex parsing logic
  end
end

# Only the result survives into the binary
defmodule Validator do
  @rules :: List({String, String}) = SchemaCompiler.compile("schemas/user.json")

  def validate(data :: Map(String, String)) :: Bool do
    # @rules is a static list — SchemaCompiler is dead code
  end
end
```

---

## Module attributes

### Syntax

Every attribute has a type annotation. Two forms:

```
@name :: Type = value    # typed attribute with value
@name                    # marker attribute (no type, no value)
```

No untyped values. `@doc "hello"` is a compile error — it must be
`@doc :: String = "hello"`.

### Examples

```zap
defmodule Config do
  @moduledoc :: String = "Configuration loading and parsing."

  @doc :: String = "Loads configuration from the given file path."
  @deprecated :: String = "Use Config.load_from_env/0 instead."
  def load(path :: String) :: Map(String, String) do
    # ...
  end

  @doc :: String = "Loads configuration from environment variables."
  def load_from_env() :: Map(String, String) do
    # ...
  end
end
```

Markers:

```zap
defmodule Kernel do
  @debug
  def inspect(value :: T) :: T do
    :zig.inspect(value)
  end
end
```

Constants:

```zap
defmodule App do
  @timeout :: i64 = 5000
  @max_retries :: i64 = 3
  @base_url :: String = "https://api.example.com"
  @users_url :: String = @base_url <> "/users"

  def timeout() :: i64 do
    @timeout
  end
end
```

Computed values:

```zap
defmodule Crypto do
  @sbox :: List(i64) = MathTables.generate_sbox()
  @template :: String = File.read("templates/index.html")
  @config :: Map(String, String) = Jason.parse(File.read("config.json"))
end
```

User-defined attributes for macros:

```zap
defmodule UsersController do
  @route :: String = "/users"
  @method :: Atom = :get
  def index(conn :: Conn) :: Conn do ... end

  @route :: String = "/users"
  @method :: Atom = :post
  def create(conn :: Conn) :: Conn do ... end
end
```

### Attribute values

Attribute values are compile-time expressions. They are evaluated during
compilation and the **result** is stored as a typed constant.

The compiler validates that the evaluated result matches the declared type:

```zap
@timeout :: i64 = "five"         # compile error: expected i64, got String
@name :: String = 42             # compile error: expected String, got i64
@doc :: String = File.read("x")  # OK if File.read returns String
@sbox :: List(i64) = generate()  # OK if generate() returns List(i64)
```

Attributes can reference other attributes defined above in the same module:

```zap
@base :: String = "https://api.example.com"
@endpoint :: String = @base <> "/v2"
```

### Type checking

The type checker validates every attribute value against its declared type.
This happens after compile-time evaluation — the evaluated result is checked,
not the source expression.

For computed attributes (`@sbox :: List(i64) = MathTables.generate_sbox()`),
the compiler:
1. Evaluates `MathTables.generate_sbox()` via the IR interpreter
2. Gets the result (e.g., `[23, 107, 55, ...]`)
3. Checks that the result is a `List(i64)`
4. Stores the typed result

If the function returns a wrong type, the error points to the attribute:
```
error: @sbox declared as List(i64), but MathTables.generate_sbox() returned List(String)
  |
5 |   @sbox :: List(i64) = MathTables.generate_sbox()
  |                         ^^^^^^^^^^^^^^^^^^^^^^^^^^
```

### Substitution in function bodies

When `@name` appears in a function body, the stored constant is substituted.
The type checker sees the literal with its known type:

```zap
@timeout :: i64 = 5000

def connect() :: i64 do
  @timeout    # type checker sees 5000 :: i64
end
```

Calling methods or dispatching on a substituted value is NOT allowed:

```zap
@handler :: Atom = :Config
def process(data :: String) :: String do
  @handler.parse(data)   # compile error: cannot call methods on attribute value
end
```

Attributes hold constants. They are not callable references.

### Reserved attributes (defined in Kernel)

| Attribute | Form | Attaches to | Purpose |
|---|---|---|---|
| `@moduledoc :: String = "..."` | Typed | Module | Module-level documentation |
| `@doc :: String = "..."` | Typed | Next function/macro/type | Declaration documentation |
| `@deprecated :: String = "..."` | Typed | Next function/macro | Deprecation warning with message |
| `@debug` | Marker | Next function | Erased in release, excluded from effects |
| `@spec` | Type expression | Next function | Type specification (future) |

Reserved attributes may have their type annotation relaxed in a future
version (e.g., `@doc "hello"` as sugar for `@doc :: String = "hello"`).
The explicit form is the canonical base.

### Attribute attachment

Attributes attach to the **next declaration** in the module body:

```zap
@doc :: String = "This attaches to load/1"
def load(path :: String) :: String do ... end

@doc :: String = "This attaches to save/2"
def save(path :: String, data :: String) :: nil do ... end
```

Multiple attributes stack on the same declaration:

```zap
@doc :: String = "Loads config."
@deprecated :: String = "Use load_from_env/0 instead."
def load(path :: String) :: String do ... end
```

Module-level attributes don't attach to a declaration — they describe the
module itself:

```zap
defmodule Config do
  @moduledoc :: String = "Configuration module."
  @author :: String = "Jane Doe"
  @version :: String = "1.2.0"
end
```

The distinction: `@moduledoc` and attributes placed before any function
declaration are module-level. `@doc`, `@deprecated`, `@debug` placed
immediately before a `def`/`defp`/`defmacro`/`defmacrop` are function-level.

---

## The Module module

`Module` is a compile-time-only module. Its functions are compiler intrinsics
that query the scope graph during compilation. They can only be called in
compile-time contexts (macros, attribute expressions).

### Module introspection

```zap
Module.name(module) :: Atom
```
Returns the module's name as an atom.

```zap
Module.functions(module) :: List({Atom, i64})
```
Returns all public functions as `{name, arity}` tuples.

```zap
Module.macros(module) :: List({Atom, i64})
```
Returns all public macros as `{name, arity}` tuples.

```zap
Module.types(module) :: List(Atom)
```
Returns all type definitions (structs, enums) in the module.

```zap
Module.file(module) :: String
```
Returns the source file path for the module.

```zap
Module.is_private(module) :: Bool
```
Returns true if the module was declared with `defmodulep`.

```zap
Module.has_function(module, name :: Atom, arity :: i64) :: Bool
```
Checks if a public function exists.

```zap
Module.function_visibility(module, name :: Atom, arity :: i64) :: Atom
```
Returns `:public` or `:private`.

### Attribute access

```zap
Module.get_attribute(module, name :: Atom) :: any
```
Returns the module-level attribute value, or nil if not set.

```zap
Module.get_attribute(module, name :: Atom, function :: Atom, arity :: i64) :: any
```
Returns the attribute value attached to a specific function.

```zap
Module.has_attribute(module, name :: Atom) :: Bool
```
Checks if a module-level attribute is set.

```zap
Module.put_attribute(name :: Atom, type :: Type, value) :: nil
```
Sets a typed attribute on the current module being compiled.

```zap
Module.attributes(module) :: List({Atom, any})
```
Returns all module-level attributes.

```zap
Module.function_attributes(module, function :: Atom, arity :: i64) :: List({Atom, any})
```
Returns all attributes attached to a specific function.

### Current module

```zap
__MODULE__
```
Expands to the current module's atom during compilation. Only valid inside
a `defmodule`/`defmodulep` body.

---

## Compiler enforcement

### Compile-time only

`Module.*` calls and compile-time function execution are valid inside:
- `defmacro` / `defmacrop` bodies
- Attribute value expressions (`@name :: Type = expr`)
- The compiler/MCP server internals

They are invalid inside:
- `def` / `defp` function bodies (except `@name` substitution)
- Runtime expressions

### Dependency order enforcement

A module can only call functions at compile time from modules that appear
earlier in the dependency order:

```zap
defmodule A do
  def compute() :: i64 do 42 end
end

defmodule B do
  @value :: i64 = A.compute()       # OK — A is fully compiled
  @other :: i64 = C.something()     # ERROR — C is not yet compiled
end

defmodule C do
  @from_b :: i64 = B.get_value()    # OK — B is fully compiled
end
```

### Step counter

The IR interpreter aborts after a configurable step limit (default: 10
million operations):

```zap
defmodule Bad do
  @value :: i64 = Helpers.infinite()
  # compile error: compile-time evaluation exceeded step limit
end
```

---

## @debug attribute

```zap
defmodule Kernel do
  @debug
  def inspect(value :: T) :: T do
    :zig.inspect(value)
  end
end
```

Behavior:
- Excluded from effect derivation (callers don't appear effectful)
- Erased in release builds (`:release_small`, `:release_fast`)
- Compiler verifies pass-through semantics: return type equals input type
- `@debug` is a marker attribute (no value, no type)

---

## MCP integration

### `types` tool — includes attributes

```json
{
  "name": "Config.load",
  "module": "Config",
  "arity": 1,
  "params": [{"name": "path", "type": "String", "ownership": "shared"}],
  "return_type": "Map(String, String)",
  "attributes": {
    "doc": {"type": "String", "value": "Loads configuration from the given file path."},
    "deprecated": {"type": "String", "value": "Use Config.load_from_env/0 instead."}
  }
}
```

### `modules` tool — includes module attributes

```json
{
  "name": "Config",
  "file": "lib/config.zap",
  "attributes": {
    "moduledoc": {"type": "String", "value": "Configuration loading and parsing."}
  },
  "functions": ["load/1", "load_from_env/0"]
}
```

### New tool: `docs`

```json
{
  "module": "Config",
  "moduledoc": "Configuration loading and parsing.",
  "functions": [
    {
      "name": "load",
      "arity": 1,
      "doc": "Loads configuration from the given file path.",
      "deprecated": "Use Config.load_from_env/0 instead.",
      "signature": "def load(path :: String) :: Map(String, String)"
    },
    {
      "name": "load_from_env",
      "arity": 0,
      "doc": "Loads configuration from environment variables.",
      "signature": "def load_from_env() :: Map(String, String)"
    }
  ]
}
```

---

## Implementation

### Phase 1: Attribute syntax and storage

**Step 1: Parser — `@name :: Type = value` syntax**
- Parse `@` inside module body as attribute
- Two forms:
  - `@name :: TypeExpr = Expr` — typed attribute with value
  - `@name` — marker attribute
- New AST node: `AttributeDecl { name: StringId, type_expr: ?*TypeExpr, value: ?*Expr }`
- New `ModuleItem` variant: `attribute`
- Parse error on `@name value` without type annotation

**Step 2: Collector — attribute storage**
- Add `attributes: ArrayList(Attribute)` to `ModuleEntry` and
  `FunctionFamily` in scope graph
- `Attribute = struct { name: StringId, type_expr: ?*TypeExpr, value: ?*Expr, evaluated: ?Value }`
- Track pending attributes, attach to next declaration
- Module-level vs function-level distinction

**Step 3: Attribute substitution**
- New pass before type checking: replace `@name` references in function
  bodies with the stored constant value AST node
- For literal attributes: substitute directly
- For computed attributes: substitute after compile-time evaluation (Phase 3)

**Step 4: Type checking**
- Validate every attribute value against its declared type
- Marker attributes (`@debug`): verify no type or value
- Error on type mismatch with clear diagnostic pointing to the attribute

### Phase 2: Module intrinsics

**Step 5: Module module**
- Implement `Module.*` as compiler intrinsics in the macro engine
- Intrinsics query the scope graph for module/function/attribute data
- Return compile-time values usable in macros and attribute expressions

**Step 6: `__MODULE__`**
- Special form that expands to the current module atom

### Phase 3: Compile-time execution

**Step 7: IR interpreter**
- Interpreter that walks IR instructions
- Supports: function calls, control flow, arithmetic, data structures,
  string operations
- Step counter with configurable limit
- Arena allocation for compile-time values

**Step 8: Dependency-ordered compilation with compile-time calls**
- After a module's IR is generated, register its functions with the
  interpreter
- Attribute value expressions can call functions from already-compiled
  modules
- Macro bodies can call functions from already-compiled modules
- Results are typed constants substituted into the current module
- Type check the result against the attribute's declared type

**Step 9: Compile-time I/O**
- File reads, environment variable access in the interpreter
- Compiler tracks accessed external resources for incremental recompilation

### Phase 4: @debug and effects

**Step 10: @debug erasure**
- IR lowering: skip `@debug` calls in release builds
- Type checker: verify `T -> T` pass-through semantics

**Step 11: Effect analysis exclusion**
- Interprocedural analysis: skip `@debug` functions during effect propagation

### Phase 5: MCP integration

**Step 12: MCP attribute tools**
- `types` tool: include typed attributes in responses
- `modules` tool: include module attributes with types
- New `docs` tool: formatted documentation
- `effects` tool: `@debug` functions excluded

---

## Attribute lifecycle

```
Source code          @sbox :: List(i64) = MathTables.generate_sbox()
                     def encrypt(byte :: i64) :: i64 do
                       List.at(@sbox, byte)
                     end
    |
    v
Parser               AttributeDecl {
                       name: "sbox",
                       type_expr: List(i64),
                       value: CallExpr(MathTables.generate_sbox)
                     }
    |
    v
Collector             Module has pending attribute "sbox"
                      type: List(i64), value: unevaluated expression
    |
    v
Compile-time eval     MathTables is already compiled
                      → call generate_sbox() via IR interpreter
                      → returns [23, 107, 55, ...]
    |
    v
Type check            Verify [23, 107, 55, ...] :: List(i64) ✓
                      Store typed result
    |
    v
Substitution          Replace @sbox in function body with [23, 107, 55, ...]
    |
    v
Type checker          Sees List.at([23, 107, 55, ...], byte) — checks normally
    |
    v
HIR / IR              Compiles with the constant list embedded
    |
    v
Analysis              MathTables.generate_sbox has no runtime callers → dead
    |
    v
Binary                Crypto.encrypt with embedded lookup table
                      MathTables stripped — zero bytes
```

---

## Trade-offs

### Compilation speed

Modules must compile in strict dependency order for compile-time execution.
Parallel compilation is limited to modules at the same DAG level. Deep
dependency chains serialize compilation. Most modules don't use compile-time
evaluation — only modules with computed attributes force serialization.

### Incremental recompilation

If B calls `A.compute()` at compile time and A's body changes, B must
recompile even if A's API didn't change. Compile-time call dependencies are
tracked separately from runtime dependencies.

### Build reproducibility

Compile-time I/O makes builds non-deterministic. The compiler tracks external
resources for caching — if a template file changes, modules that read it at
compile time are recompiled.

### Error handling

Compile-time evaluation failures (panics, infinite loops, OOM) produce
compiler errors. The step counter prevents infinite loops. Panics include
the compile-time call stack.

### Cross-compilation

Compile-time code runs on the host. Runtime code runs on the target.
Platform-specific behavior may differ. In practice this is rarely an issue.

### Attribute verbosity

Every attribute requires a type annotation: `@doc :: String = "..."` instead
of `@doc "..."`. This is deliberate — explicit types over implicit
convenience. The type annotation can be relaxed for reserved attributes in a
future version if the verbosity proves costly.

### No polymorphic attributes

An attribute has one type. `@cache` cannot be both `i64` and `Atom` depending
on context. Use separate attribute names (`@cache_ttl :: i64`, `@cache_mode
:: Atom`) or a union type if one is defined.

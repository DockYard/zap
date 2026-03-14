# Complete Specification: Zip — Typed Functional Elixir-Syntax Language Lowering to Zig

## 1. Purpose

This language is a new statically typed, functional, macro-capable language with Elixir-like syntax and a native backend strategy built around lowering through a Zig-oriented compiler pipeline.

It is:

* Elixir-shaped at the surface
* statically typed
* functionally oriented
* macro-capable
* indentation-significant
* block-only
* overload-aware
* locally scoped with fallback dispatch across scopes
* compiled natively
* not BEAM-based
* not Gleam
* not Zig syntax

This document is the canonical single specification for the language, compiler architecture, runtime model, and implementation plan.

---

# 2. Core language commitments

## 2.1 Surface identity

The language preserves these visible Elixir-family forms:

* `defmodule`
* `def`
* `defmacro`
* `type`
* `opaque`
* `do ... end`
* tuples
* tagged tuples
* `if`
* `case`
* `with`
* `cond`
* `quote`
* `unquote`

It does not preserve all Elixir semantics. It uses Elixir-like syntax for a new typed functional language.

## 2.2 Types are part of the grammar

Types are declared inline in function headers and in standalone type declarations.

There is no primary `@spec` or `@type` metadata model.

## 2.3 One structural style

The language forbids shorthand body forms like `, do:`.

All body-bearing forms use blocks.

## 2.4 Significant whitespace

Indentation is part of the grammar.

Formatting is not merely style. Layout participates in parsing.

## 2.5 `def` and `defp` are the function forms

Functions are declared with `def` (public) or `defp` (module-private) at module scope, and with `def` at local scope inside other functions.

There is no separate core anonymous function syntax required by the design.

## 2.6 Function values use normal call syntax

Any function-valued expression is called with ordinary parentheses:

```elixir
f(2)
```

There is no `f.(2)` form.

## 2.7 Dispatch is local-first with outer fallback

A local function family is tried first.

If it does not match, dispatch continues outward to enclosing scopes, including module scope.

This is not ordinary lexical shadowing.

## 2.8 Functional semantics

The language is functionally oriented:

* immutable bindings by default
* pure functions by default
* structural pattern matching
* persistent data structures
* explicit effect boundaries

---

# 3. Source language

## 3.1 Top-level declarations

The language supports:

* `defmodule`
* `type`
* `opaque`
* `def`
* `defp`
* `defstruct`
* `defmacro`
* `alias`
* `import`

## 3.2 Block-only syntax

The following is invalid:

```elixir
def foo(x :: Int) :: Int, do: x
```

The following is valid:

```elixir
def foo(x :: Int) :: Int do
  x
end
```

This applies uniformly to:

* functions
* macros
* `if`
* `case`
* `with`
* `cond`

## 3.3 Significant whitespace rules

Whitespace is significant.

The lexer emits:

* `NEWLINE`
* `INDENT`
* `DEDENT`

Rules:

* tabs and spaces may not be mixed for indentation
* inconsistent dedentation is a syntax error
* indentation that does not match an open block is a syntax error
* misaligned `end` is a syntax error

`do` and `end` remain mandatory even though layout is significant.

That means structure is enforced by both:

* indentation
* explicit delimiters

---

# 4. Type system

## 4.1 Supported type categories

The language supports:

* numeric types:
  * signed integers: `i8`, `i16`, `i32`, `i64`
  * unsigned integers: `u8`, `u16`, `u32`, `u64`
  * floats: `f16`, `f32`, `f64`
  * platform-sized: `usize`, `isize`
* other primitives: `Bool`, `String`, `Atom`, `Nil`
* bottom type: `Never` (the type of expressions that never produce a value)
* tuple types
* tagged tuple types
* list types
* map types
* struct types
* union types
* function types
* parametric types
* opaque types
* named type aliases

## 4.2 Type declarations

Type aliases are declared with `type`:

```elixir
type Result(a, e) = {:ok, a} | {:error, e}
type Pair(a, b) = {a, b}
type Mapper(a, b) = (a -> b)
type Byte = u8
```

Opaque types are declared with `opaque`:

```elixir
opaque UserId = i64
```

## 4.3 Tagged unions

Tagged tuples are the primary algebraic-data representation.

Example:

```elixir
type Expr =
  {:int, i64}
  | {:add, Expr, Expr}
  | {:var, String}
```

## 4.4 Numeric type rules

All Zig numeric types are exposed directly. There is no implicit coercion or promotion between numeric types. Developers must explicitly convert:

```elixir
# OK: same types
def add(x :: i64, y :: i64) :: i64 do
  x + y
end

# Compile error: no overload for +(i32, i64)
def bad(x :: i32, y :: i64) :: i64 do
  x + y
end

# Correct: explicit conversion
def good(x :: i32, y :: i64) :: i64 do
  i32_to_i64(x) + y
end
```

Arithmetic, comparison, and all numeric operators require both operands to be the same numeric type.

## 4.5 Function boundary types

Functions declare parameter and return types inline.

Example:

```elixir
def add(x :: i64, y :: i64) :: i64 do
  x + y
end
```

Parameter and return annotations are hard contracts.

## 4.6 Local type inference

Types inside function bodies may be inferred.

Function boundaries are explicit and authoritative.

## 4.7 Pattern typing

Pattern annotations refine both shape and bindings.

Example:

```elixir
def unwrap({:ok, x} :: Result(i64, e)) :: i64 do
  x
end
```

Inside the body, `x` is known to be `i64`.

## 4.8 Generics

Generic type variables are supported in type and function declarations.

Example:

```elixir
def map(value :: Result(a, e), f :: (a -> b)) :: Result(b, e) do
  case value do
    {:ok, x} ->
      {:ok, f(x)}

    {:error, err} ->
      {:error, err}
  end
end
```

---

# 5. Function declarations

## 5.1 Canonical function form

The canonical function form is:

```elixir
def name(params...) :: ReturnType do
  ...
end
```

With optional refinement:

```elixir
def name(params...) :: ReturnType if predicate do
  ...
end
```

## 5.2 Parameter syntax

Parameters use patterns with optional type annotations:

```elixir
param := pattern [ "::" type_expr ]
```

Examples:

```elixir
def id(x :: i64) :: i64 do
  x
end
```

```elixir
def unwrap({:ok, x} :: Result(i64, e)) :: i64 do
  x
end
```

## 5.3 Return type syntax

Return annotations appear after the parameter list:

```elixir
def foo(x :: i64) :: String do
  int_to_string(x)
end
```

## 5.4 Return type semantics

Return annotations are hard contracts.

A function body that can produce a non-conforming value is rejected.

---

# 6. Refinement predicates

## 6.1 Header refinement form

Refinements are written with `if` in the function header.

Example:

```elixir
def abs(x :: i64) :: i64 if x < 0 do
  -x
end

def abs(x :: i64) :: i64 do
  x
end
```

## 6.2 Refinement semantics

A refinement predicate is part of clause applicability.

A clause matches only if:

* its type constraints are applicable
* its pattern matches
* its refinement evaluates to `true`

## 6.3 Allowed refinement expression subset

Refinement predicates must be:

* pure
* side-effect free
* non-mutating
* deterministic
* runtime-safe for dispatch filtering

Refinements cannot do:

* IO
* mutation
* arbitrary side effects

## 6.4 Generalized refinement usage

Refinements are allowed anywhere clause-like syntax exists, including:

* function clauses
* local function clauses
* `case` branches
* `with` else branches

---

# 7. Functions as values

## 7.1 Ordinary call syntax

Any expression of function type can be called with normal parentheses.

Examples:

```elixir
f(2)
```

```elixir
make_adder(1)(2)
```

## 7.2 No `.(...)` syntax

The language does not use a distinct anonymous-function call syntax.

## 7.3 Semantic call resolution

The parser treats all applications uniformly.

The type checker determines whether a call is:

* direct function-value application
* named function-family dispatch

---

# 8. Local functions

## 8.1 Local `def`

A function can be declared inside another function body using `def`.

Example:

```elixir
def outer(x :: i64) :: String do
  def inner(s :: String) :: String do
    s <> "!"
  end

  inner("ok")
end
```

## 8.2 Local functions are real functions

A local function is not mere syntax sugar for variable-bound lambda syntax.

It is a real function declaration with:

* scope
* overload family membership
* clause matching
* capture analysis
* possible recursion
* possible mutual recursion

## 8.3 Hoisting rule

Local function declarations are hoisted within their lexical block group.

That means:

* all local defs in a block are collected before body checking
* recursion is supported
* mutual recursion among sibling local defs is supported
* overload families can be formed before type checking bodies

This is the required rule.

## 8.4 Captures

A local function may capture bindings from outer lexical scopes.

Captured values become closure environment state in lowering.

---

# 9. Overloading

## 9.1 Ad hoc overloading is supported

Functions of the same name and arity in the same lexical scope form an overload family.

## 9.2 Overload key

Overload resolution uses:

* name
* arity
* argument types

Return type does not participate in overload selection.

## 9.3 Specificity

If multiple overloads are applicable, the compiler chooses the uniquely most specific one.

If no uniquely most specific candidate exists, the program is rejected as ambiguous.

## 9.4 Generics and overloading

Concrete overloads outrank generic overloads when one is strictly more specific.

Ambiguous generic applicability is an error.

## 9.5 Patterns and overloading

Overload resolution happens before intra-family clause matching.

That means:

1. find applicable overload candidates by type
2. choose most specific
3. perform clause matching and refinement filtering inside that family

---

# 10. Scope-prioritized fallback dispatch

This is one of the defining language features.

## 10.1 Rule

For an unqualified call `b(args...)` inside a nested scope:

1. try the innermost scope’s `b/arity` family
2. if no family exists, continue outward
3. if a family exists, attempt overload resolution
4. if no overload is applicable, continue outward
5. if overload resolution is ambiguous, compilation fails
6. if an overload family is applicable, attempt clause matching
7. if no clause matches, continue outward
8. if a clause matches, dispatch succeeds
9. try enclosing local scopes (repeat 1-8 outward)
10. try the current module scope
11. try the import scope (all imported function families, unified)
12. try the prelude scope (auto-imported `Kernel` functions)
13. if no scope matches, report a no-match error

For a qualified call `Module.f(args...)`:

1. resolve `Module` (expand aliases if needed)
2. look up `f/arity` directly in the target module’s public scope
3. apply overload resolution within that module
4. no fallback — qualified calls are direct

## 10.2 This is not normal shadowing

Inner scopes do not completely shadow outer scopes.

Instead, inner scopes have first right of refusal.

Outer scopes remain valid fallback targets.

## 10.3 Example

```elixir
defmodule Foo do
  def b(s :: String) :: String do
    s <> "foo"
  end

  def a(x :: i64) :: String do
    def b(n :: i64) :: String do
      int_to_string(n)
    end

    b("other")
  end
end
```

Dispatch for `b("other")` inside `a`:

* local `b(i64)` family exists
* argument type `String` is not applicable
* local scope fails
* module scope is tried
* module `b(String)` matches
* module function is used

## 10.4 Example with refinement fallback

```elixir
defmodule Foo do
  def b(s :: String) :: String do
    s <> "foo"
  end

  def a(x :: i64) :: String do
    def b(s :: String) :: String if string_length(s) < 5 do
      s <> "bar"
    end

    b("other")
  end
end
```

Dispatch for `b("other")` inside `a`:

* local `b(String)` is applicable
* refinement is checked
* if refinement passes, local function is used
* if refinement fails, fallback continues
* module `b(String)` is tried
* module function is used if it matches

## 10.5 Return type coherence

If a call can resolve through multiple fallback layers, all reachable successful resolution paths must produce a coherent type.

Otherwise the call is rejected.

---

# 11. Pattern matching

## 11.1 Pattern matching is a primary semantic feature

Pattern matching is used in:

* function parameters
* local functions
* `case`
* `with`
* assignment destructuring if supported

## 11.2 Pattern categories

Supported patterns:

* wildcard
* bind
* literal
* tuple
* list
* map
* struct
* pin
* parenthesized pattern

## 11.3 Matching semantics

Pattern matching performs:

* structural tests
* variable bindings
* type refinements
* optional refinement predicate evaluation

## 11.4 Exhaustiveness

The compiler should perform exhaustiveness checking where practical, especially for:

* `case`
* union-typed matches
* tagged union matches

---

# 12. Macros

## 12.1 Macro model

Macros are AST-to-AST transforms.

A macro:

* receives AST
* returns AST
* expands before full body type checking

## 12.2 Macro declarations

Macros use `defmacro`:

```elixir
defmacro unless(expr :: AST, body :: AST) :: AST do
  quote do
    if not unquote(expr) do
      unquote(body)
    end
  end
end
```

## 12.3 Macro phases

Compilation phases involving macros:

1. parse source into surface AST
2. collect declarations and macro availability
3. expand macros to a fixed point
4. desugar expanded AST
5. continue into resolution and typing

## 12.4 Hygiene

Macro-generated bindings carry hidden identity information, not just textual names.

Hygienic identity includes:

* name
* generation context
* generation counter

Generated names do not capture user names accidentally.

## 12.5 Lexical environment

Macros expand in a lexical environment with access to:

* current module
* local aliases/imports/requirements if supported
* caller metadata
* quoted/unquoted context

## 12.6 Macro restrictions for initial implementation

Initial macro support excludes:

* parser-changing macros
* syntax-extension macros
* post-typecheck AST mutation
* unrestricted side-effectful compile-time execution

---

# 13. Grammar

## 13.1 Lexical grammar

```ebnf
letter           = "A"…"Z" | "a"…"z" | "_" ;
digit            = "0"…"9" ;

ident            = letter , { letter | digit | "!" | "?" } ;
module_ident     = ident , { "." , ident } ;
type_ident       = ident ;

int_lit          = digit , { digit } ;
float_lit        = digit , { digit } , "." , digit , { digit } ;
string_lit       = "\"" , { string_part } , "\"" ;
string_part      = string_char | string_interp ;
string_char      = (* any character except `"` and `#` followed by `{` *) ;
string_interp    = "#" , "{" , expr , "}" ;

atom_lit         = ":" , ident ;
bool_lit         = "true" | "false" ;
nil_lit          = "nil" ;

numeric_type     = "i8" | "i16" | "i32" | "i64"
                 | "u8" | "u16" | "u32" | "u64"
                 | "f16" | "f32" | "f64"
                 | "usize" | "isize" ;
```

## 13.2 Program structure

```ebnf
program          = { top_decl | newline } ;

top_decl         = module_decl
                 | type_decl
                 | opaque_decl
                 | fun_decl
                 | priv_fun_decl
                 | macro_decl ;
```

## 13.3 Modules

```ebnf
module_decl      = "defmodule" , module_ident , "do" , newline ,
                   indent ,
                   { module_body_item | newline } ,
                   dedent ,
                   "end" ;

module_body_item = type_decl
                 | opaque_decl
                 | struct_decl
                 | fun_decl
                 | priv_fun_decl
                 | macro_decl
                 | alias_decl
                 | import_decl ;
```

## 13.4 Types

```ebnf
type_decl        = "type" , type_name , [ type_params ] , "=" , type_expr ;
opaque_decl      = "opaque" , type_name , [ type_params ] , "=" , type_expr ;

type_name        = type_ident ;
type_params      = "(" , type_param , { "," , type_param } , ")" ;
type_param       = type_ident ;
```

## 13.5 Struct declarations

```ebnf
struct_decl      = "defstruct" , "do" , newline ,
                   indent ,
                   { struct_field_decl | newline } ,
                   dedent , "end" ;

struct_field_decl= ident , "::" , type_expr , [ "=" , expr ] ;
```

## 13.6 Functions and macros

```ebnf
fun_decl         = "def" , fun_name , param_clause , [ return_annot ] ,
                   [ refine_clause ] , "do" , newline ,
                   indent , block , dedent , "end" ;

priv_fun_decl    = "defp" , fun_name , param_clause , [ return_annot ] ,
                   [ refine_clause ] , "do" , newline ,
                   indent , block , dedent , "end" ;

macro_decl       = "defmacro" , fun_name , param_clause , [ return_annot ] ,
                   [ refine_clause ] , "do" , newline ,
                   indent , block , dedent , "end" ;

fun_name         = ident ;

param_clause     = "(" , [ param_list ] , ")" ;
param_list       = param , { "," , param } ;
param            = pattern , [ "::" , type_expr ] ;

return_annot     = "::" , type_expr ;
refine_clause    = "if" , expr ;
```

## 13.7 Module system directives

```ebnf
alias_decl       = "alias" , module_path , [ "," , "as:" , module_ident ] ;

import_decl      = "import" , module_path , [ "," , import_filter ] ;
import_filter    = "only:" , "[" , import_entry_list , "]"
                 | "except:" , "[" , import_entry_list , "]" ;
import_entry_list= import_entry , { "," , import_entry } ;
import_entry     = fun_name , ":" , int_lit
                 | "type:" , type_ident ;

module_path      = module_ident
                 | module_ident , ".{" , module_ident_list , "}" ;
module_ident_list= module_ident , { "," , module_ident } ;
```

## 13.8 Statements and blocks

```ebnf
block            = { stmt | newline } ;

stmt             = local_fun_decl
                 | local_macro_decl
                 | local_import_decl
                 | assign_stmt
                 | expr_stmt ;

local_fun_decl   = fun_decl ;
local_macro_decl = macro_decl ;
local_import_decl= import_decl ;

assign_stmt      = pattern , "=" , expr ;
expr_stmt        = expr ;
```

## 13.9 Expressions

```ebnf
expr             = logic_or_expr ;

logic_or_expr    = logic_and_expr , { "or" , logic_and_expr } ;
logic_and_expr   = compare_expr , { "and" , compare_expr } ;
compare_expr     = pipe_expr ,
                   { ("==" | "!=" | "<" | ">" | "<=" | ">=") , pipe_expr } ;

pipe_expr        = add_expr , { "|>" , add_expr } ;

add_expr         = mul_expr , { ("+" | "-" | "<>") , mul_expr } ;
mul_expr         = unary_expr , { ("*" | "/" | "rem") , unary_expr } ;

unary_expr       = [ "-" | "not" ] , postfix_expr ;

postfix_expr     = call_expr , [ "!" ] ;
```

## 13.10 Calls and access

```ebnf
call_expr        = primary_expr , { call_suffix | access_suffix } ;

call_suffix      = "(" , [ arg_list ] , ")" ;
arg_list         = expr , { "," , expr } ;

access_suffix    = "." , ident ;
```

## 13.11 Primary expressions

```ebnf
primary_expr     = literal
                 | var_ref
                 | tuple_expr
                 | list_expr
                 | map_expr
                 | struct_expr
                 | paren_expr
                 | if_expr
                 | case_expr
                 | with_expr
                 | cond_expr
                 | quote_expr
                 | unquote_expr
                 | panic_expr ;

panic_expr       = "panic" , "(" , expr , ")" ;

literal          = int_lit
                 | float_lit
                 | string_lit
                 | atom_lit
                 | bool_lit
                 | nil_lit ;

var_ref          = ident ;
paren_expr       = "(" , expr , ")" ;
```

## 13.12 Compound literals

```ebnf
tuple_expr       = "{" , [ expr_list ] , "}" ;
expr_list        = expr , { "," , expr } ;

list_expr        = "[" , [ expr_list ] , "]" ;

map_expr         = "%{" , [ map_field_list ] , "}" ;
map_field_list   = map_field , { "," , map_field } ;
map_field        = expr , "=>" , expr ;

struct_expr      = "%" , module_ident , "{" ,
                   [ struct_update_source , "|" ] ,
                   [ struct_field_list ] , "}" ;
struct_update_source = expr ;
struct_field_list= struct_field , { "," , struct_field } ;
struct_field     = ident , ":" , expr ;
```

## 13.13 Control forms

```ebnf
if_expr          = "if" , expr , "do" , newline ,
                   indent , block , dedent ,
                   [ "else" , newline , indent , block , dedent ] ,
                   "end" ;

case_expr        = "case" , expr , "do" , newline ,
                   indent , case_clause , { newline , case_clause } ,
                   dedent , "end" ;

case_clause      = pattern , [ "::" , type_expr ] ,
                   [ "if" , expr ] , "->" , newline ,
                   indent , block , dedent ;

with_expr        = "with" , with_item , { "," , with_item } ,
                   "do" , newline ,
                   indent , block , dedent ,
                   [ "else" , newline , indent , with_else_clause ,
                     { newline , with_else_clause } , dedent ] ,
                   "end" ;

with_item        = pattern , "<-" , expr
                 | expr ;

with_else_clause = pattern , [ "::" , type_expr ] ,
                   [ "if" , expr ] , "->" , newline ,
                   indent , block , dedent ;

cond_expr        = "cond" , "do" , newline ,
                   indent , cond_clause , { newline , cond_clause } ,
                   dedent , "end" ;

cond_clause      = expr , "->" , newline , indent , block , dedent ;
```

## 13.14 Quote and unquote

```ebnf
quote_expr       = "quote" , "do" , newline ,
                   indent , block , dedent , "end" ;

unquote_expr     = "unquote" , "(" , expr , ")" ;
```

## 13.15 Patterns

```ebnf
pattern          = wildcard_pattern
                 | bind_pattern
                 | literal_pattern
                 | tuple_pattern
                 | list_pattern
                 | map_pattern
                 | struct_pattern
                 | pin_pattern
                 | paren_pattern ;

wildcard_pattern = "_" ;
bind_pattern     = ident ;
literal_pattern  = literal ;

tuple_pattern    = "{" , [ pattern_list ] , "}" ;
pattern_list     = pattern , { "," , pattern } ;

list_pattern     = "[" , [ pattern_list ] , "]" ;

map_pattern      = "%{" , [ map_pattern_field_list ] , "}" ;
map_pattern_field_list
                 = map_pattern_field , { "," , map_pattern_field } ;
map_pattern_field= expr , "=>" , pattern ;

struct_pattern   = "%" , module_ident , "{" ,
                   [ struct_pattern_field_list ] , "}" ;
struct_pattern_field_list
                 = struct_pattern_field , { "," , struct_pattern_field } ;
struct_pattern_field
                 = ident , ":" , pattern ;

pin_pattern      = "^" , ident ;
paren_pattern    = "(" , pattern , ")" ;
```

## 13.16 Types

```ebnf
type_expr        = type_union ;

type_union       = type_term , { "|" , type_term } ;

type_term        = type_fun
                 | type_tuple
                 | type_list
                 | type_map
                 | type_struct
                 | type_app
                 | type_atom
                 | type_literal
                 | type_numeric
                 | type_never
                 | type_var
                 | "(" , type_expr , ")" ;

type_numeric     = numeric_type ;
type_never       = "Never" ;

type_fun         = "(" , [ type_expr_list ] , "->" , type_expr , ")" ;
type_expr_list   = type_expr , { "," , type_expr } ;

type_tuple       = "{" , [ type_expr_list ] , "}" ;
type_list        = "[" , type_expr , "]" ;

type_map         = "%{" , [ type_map_field_list ] , "}" ;
type_map_field_list
                 = type_map_field , { "," , type_map_field } ;
type_map_field   = type_expr , "=>" , type_expr ;

type_struct      = "%" , module_ident , "{" ,
                   [ type_struct_field_list ] , "}" ;
type_struct_field_list
                 = type_struct_field , { "," , type_struct_field } ;
type_struct_field= ident , ":" , type_expr ;

type_app         = type_ident , [ "(" , type_expr_list , ")" ] ;

type_atom        = atom_lit ;
type_literal     = int_lit | string_lit | bool_lit | nil_lit ;
type_var         = type_ident ;
```

---

# 14. AST and HIR schema

## 14.1 Shared metadata

```text
NodeMeta {
  span: SourceSpan
  scope_id: ScopeId
}

TypedMeta {
  span: SourceSpan
  scope_id: ScopeId
  ty: TypeId
}
```

## 14.2 Program structure

```text
Program {
  modules: [ModuleDecl]
  items: [TopItem]
}

ModuleDecl {
  meta: NodeMeta
  name: ModuleName
  items: [ModuleItem]
}

ModuleItem =
  | TypeDecl
  | OpaqueTypeDecl
  | FunctionGroupDecl
  | MacroGroupDecl
```

## 14.3 Type declarations

```text
TypeDecl {
  meta: NodeMeta
  name: SymbolId
  params: [TypeParam]
  body: TypeExpr
}

OpaqueTypeDecl {
  meta: NodeMeta
  name: SymbolId
  params: [TypeParam]
  body: TypeExpr
}

TypeParam {
  meta: NodeMeta
  name: SymbolId
}
```

## 14.4 Function groups

```text
FunctionGroupDecl {
  meta: NodeMeta
  name: SymbolId
  arity: Int
  clauses: [FunctionClause]
  scope_level: ScopeLevel
}

MacroGroupDecl {
  meta: NodeMeta
  name: SymbolId
  arity: Int
  clauses: [MacroClause]
  scope_level: ScopeLevel
}
```

## 14.5 Function clauses

```text
FunctionClause {
  meta: NodeMeta
  params: [TypedPattern]
  return_type: TypeExpr?
  refinement: Expr?
  body: BlockExpr
  captures: [CaptureId]
  effect: EffectInfo
}

MacroClause {
  meta: NodeMeta
  params: [TypedPattern]
  return_type: TypeExpr?
  refinement: Expr?
  body: BlockExpr
}
```

## 14.6 Patterns

```text
TypedPattern {
  meta: NodeMeta
  pattern: Pattern
  annotation: TypeExpr?
}

Pattern =
  | WildcardPattern
  | BindPattern
  | LiteralPattern
  | TuplePattern
  | ListPattern
  | MapPattern
  | StructPattern
  | PinPattern
```

Pattern nodes:

```text
WildcardPattern { meta: NodeMeta }

BindPattern {
  meta: NodeMeta
  symbol: SymbolId
}

LiteralPattern {
  meta: NodeMeta
  value: Literal
}

TuplePattern {
  meta: NodeMeta
  items: [Pattern]
}

ListPattern {
  meta: NodeMeta
  items: [Pattern]
}

MapPattern {
  meta: NodeMeta
  fields: [MapPatternField]
}

StructPattern {
  meta: NodeMeta
  module: ModuleName
  fields: [StructPatternField]
}

PinPattern {
  meta: NodeMeta
  symbol: SymbolId
}
```

## 14.7 Expressions

```text
Expr =
  | BlockExpr
  | AssignExpr
  | VarExpr
  | LiteralExpr
  | CallExpr
  | TupleExpr
  | ListExpr
  | MapExpr
  | StructExpr
  | FieldAccessExpr
  | IfExpr
  | CaseExpr
  | WithExpr
  | CondExpr
  | QuoteExpr
  | UnquoteExpr
```

### Block

```text
BlockExpr {
  meta: TypedMeta
  statements: [Expr]
  result: Expr?
}
```

### Assignment

```text
AssignExpr {
  meta: TypedMeta
  lhs: Pattern
  rhs: Expr
}
```

### Variable reference

```text
VarExpr {
  meta: TypedMeta
  symbol: SymbolId
  resolution: VarResolution
}
```

`VarResolution` distinguishes:

* local binding
* local function family
* outer function family
* module function family
* type name
* macro name

### Calls

```text
CallExpr {
  meta: TypedMeta
  callee: Expr
  args: [Expr]
  dispatch: CallDispatch
}
```

`CallDispatch`:

```text
CallDispatch =
  | DirectFunctionValueCall {
      callee_type: TypeId
    }
  | ScopedFunctionDispatch {
      name: SymbolId
      tried_scopes: [ScopeDispatchAttempt]
      resolved_clause: ResolvedFunctionClauseId
    }
```

`ScopeDispatchAttempt`:

```text
ScopeDispatchAttempt {
  scope_id: ScopeId
  family_id: FunctionFamilyId?
  result: ScopeDispatchResult
}

ScopeDispatchResult =
  | NoFamily
  | NoApplicableOverload
  | NoMatchingClause
  | AmbiguousOverload
  | MatchedClause(ResolvedFunctionClauseId)
```

### Control nodes

```text
IfExpr {
  meta: TypedMeta
  condition: Expr
  then_block: BlockExpr
  else_block: BlockExpr?
}

CaseExpr {
  meta: TypedMeta
  scrutinee: Expr
  clauses: [CaseClause]
}

CaseClause {
  meta: TypedMeta
  pattern: Pattern
  annotation: TypeExpr?
  refinement: Expr?
  body: BlockExpr
}

WithExpr {
  meta: TypedMeta
  items: [WithItem]
  body: BlockExpr
  else_clauses: [WithElseClause]
}

WithItem =
  | WithBind {
      meta: TypedMeta
      pattern: Pattern
      source: Expr
    }
  | WithExprItem {
      meta: TypedMeta
      expr: Expr
    }

WithElseClause {
  meta: TypedMeta
  pattern: Pattern
  annotation: TypeExpr?
  refinement: Expr?
  body: BlockExpr
}

CondExpr {
  meta: TypedMeta
  clauses: [CondClause]
}

CondClause {
  meta: TypedMeta
  condition: Expr
  body: BlockExpr
}

QuoteExpr {
  meta: TypedMeta
  body: BlockExpr
}

UnquoteExpr {
  meta: TypedMeta
  expr: Expr
}
```

## 14.8 Type AST

```text
TypeExpr =
  | TypeNameExpr
  | TypeVarExpr
  | TypeTupleExpr
  | TypeListExpr
  | TypeMapExpr
  | TypeStructExpr
  | TypeUnionExpr
  | TypeFunExpr
  | TypeLiteralExpr
```

Nodes:

```text
TypeNameExpr {
  meta: NodeMeta
  name: SymbolId
  args: [TypeExpr]
}

TypeVarExpr {
  meta: NodeMeta
  name: SymbolId
}

TypeTupleExpr {
  meta: NodeMeta
  items: [TypeExpr]
}

TypeListExpr {
  meta: NodeMeta
  item: TypeExpr
}

TypeMapExpr {
  meta: NodeMeta
  fields: [TypeMapField]
}

TypeStructExpr {
  meta: NodeMeta
  module: ModuleName
  fields: [TypeStructField]
}

TypeUnionExpr {
  meta: NodeMeta
  members: [TypeExpr]
}

TypeFunExpr {
  meta: NodeMeta
  params: [TypeExpr]
  return_type: TypeExpr
}

TypeLiteralExpr {
  meta: NodeMeta
  value: Literal
}
```

---

# 15. Scope and symbol model

## 15.1 Scope table

```text
Scope {
  id: ScopeId
  parent: ScopeId?
  kind: ScopeKind
  bindings: Map<SymbolId, BindingId>
  function_families: Map<(SymbolId, Arity), FunctionFamilyId>
  macros: Map<(SymbolId, Arity), MacroFamilyId>
  imports: [ImportedScope]
  aliases: Map<ModuleName, ModuleName>
}

ImportedScope {
  source_module: ModuleName
  filter: ImportFilter
  imported_families: Map<(SymbolId, Arity), FunctionFamilyId>
  imported_types: Map<SymbolId, TypeId>
}

ImportFilter =
  | ImportAll
  | ImportOnly([(SymbolId, Arity?)])
  | ImportExcept([(SymbolId, Arity?)])

ScopeKind =
  | ModuleScope
  | FunctionScope
  | BlockScope
  | CaseClauseScope
  | MacroExpansionScope
  | ImportScope
  | PreludeScope
```

## 15.2 Function families

```text
FunctionFamily {
  id: FunctionFamilyId
  scope_id: ScopeId
  name: SymbolId
  arity: Int
  clauses: [ResolvedFunctionClause]
}

ResolvedFunctionClause {
  id: ResolvedFunctionClauseId
  source_clause: FunctionClauseId
  param_types: [TypeId]
  return_type: TypeId
  refinement_typechecked: Bool
  specificity_rank: SpecificityRank
}
```

## 15.3 HIR function groups

To encode fallback chains explicitly:

```text
HIRFunctionGroup {
  id: HIRFunctionGroupId
  scope_id: ScopeId
  name: SymbolId
  arity: Int
  clauses: [HIRFunctionClause]
  fallback_parent: HIRFunctionGroupId?
}
```

---

# 16. Type checking rules

## 16.1 Function clause checking

For each function clause:

1. build the clause environment from typed patterns
2. refine variable types from pattern structure
3. typecheck the refinement predicate as `Bool`
4. typecheck the body
5. ensure the body result conforms to the declared return type

## 16.2 Pattern refinement

Patterns refine types branch-locally.

Example:

```elixir
case value do
  {:ok, x} ->
    x

  {:error, e} ->
    handle(e)
end
```

If `value : {:ok, i64} | {:error, String}` then:

* first branch binds `x : i64`
* second branch binds `e : String`

## 16.3 Call typing

### Direct function-value call

If the callee has function type, check arguments against its parameter types and use its return type.

### Scoped named-family call

Run scope-prioritized fallback dispatch and assign the resulting coherent return type.

## 16.4 Ambiguity

If overload resolution is ambiguous at a scope layer, compilation fails immediately.

Ambiguity never falls through to outer scopes.

## 16.5 Refinement typing

Refinements must:

* typecheck to `Bool`
* use only the permitted pure subset
* reference only visible bindings

---

# 17. Match compilation

Pattern matching, clause applicability, and fallback dispatch should compile through one unified matcher subsystem.

## 17.1 Matcher primitives

The matcher compiles to primitives such as:

* literal equality test
* tuple arity test
* list shape test
* struct identity test
* field extraction
* variable bind
* refinement predicate test
* success continuation
* failure continuation

## 17.2 Unified usage

The same matcher subsystem powers:

* function clauses
* local functions
* `case`
* `with`
* destructuring assignment

## 17.3 Fallback integration

Function dispatch uses matcher failure to continue to the next outer scope family.

That is how scope-prioritized fallback becomes explicit in lowered form.

---

# 18. Compiler pipeline

Use this pipeline:

```text
source
  -> lexer
  -> layout-sensitive parser
  -> surface AST
  -> declaration collection
  -> macro expansion
  -> desugaring
  -> name resolution
  -> type checking
  -> typed HIR
  -> dispatch/match IR
  -> Zig-shaped IR
  -> backend
```

## 18.1 Lexer

Responsibilities:

* tokenize
* compute indentation
* emit `NEWLINE`, `INDENT`, `DEDENT`
* attach spans

## 18.2 Parser

Responsibilities:

* parse layout-sensitive syntax
* enforce block-only forms
* build source-faithful surface AST

## 18.3 Declaration collection

Responsibilities:

* collect types and struct declarations
* collect functions (def and defp)
* collect macros
* process alias and import declarations
* build lexical scopes with import and prelude layers
* hoist local defs within block groups
* form function families

## 18.4 Macro expansion

Responsibilities:

* resolve visible macros
* expand hygienically
* repeat to fixed point
* preserve source mappings

## 18.5 Desugaring

Responsibilities:

* desugar string interpolation into `to_string` calls + `<>` concatenation
* desugar pipe `|>` into first-argument insertion
* desugar `!` into pattern match + panic
* normalize operators if desired
* normalize branch forms
* normalize local def groups
* reduce surface variety before typing

## 18.6 Name resolution

Responsibilities:

* resolve symbols
* resolve types
* resolve macro references
* resolve scope-visible function families

## 18.7 Type checking

Responsibilities:

* assign types
* infer local types
* resolve calls
* refine pattern branches
* validate refinements
* compute captures
* compute effects metadata

## 18.8 Dispatch/match IR

Responsibilities:

* turn high-level clauses into explicit decision trees / continuations
* encode fallback chains

## 18.9 Zig-shaped IR

Responsibilities:

* represent explicit control flow
* explicit locals
* calls
* closure environments
* ownership/ARC operations
* runtime object operations

---

# 19. Zig-shaped IR

Do not lower directly from AST/HIR to Zig internals.

First lower into an IR you own.

## 19.1 Goals

The IR should represent:

* constants
* locals
* params
* blocks
* branches
* aggregate init
* field access
* direct calls
* closure calls
* function group dispatch
* closure environment loads
* retain/release
* allocation
* returns

## 19.2 Suggested instruction families

```text
Const
LocalGet
LocalSet
ParamGet
AggregateInit
FieldGet
FieldSet
CallDirect
CallClosure
Branch
CondBranch
SwitchTag
SwitchLiteral
MatchFail
Phi
Return
AllocOwned
Retain
Release
MakeClosure
CaptureGet
```

## 19.3 Result

This IR is the stable internal lowering contract.

Zig integration sits beneath it.

---

# 20. Closures and lowering of local functions

## 20.1 Why closures are required

Local `def` can capture outer locals.

That requires closure support.

## 20.2 Closure representation

A closure consists of:

* code pointer
* environment pointer
* optional environment metadata

## 20.3 Environment generation

When a local function captures outer bindings:

* generate an environment struct
* populate it at function construction/use site
* pass it to the lowered function

If there are no captures:

* lower to a plain private function

## 20.4 Mangling

Each local function group becomes a unique internal symbol.

Example:

* module path
* enclosing function path
* local family name
* lexical block ID

---

# 21. Runtime and memory management

## 21.1 No default tracing GC

The language does not default to a global tracing garbage collector.

## 21.2 Hybrid memory model

Use three tiers.

### Tier A: plain native values

For:

* ints
* floats
* bools
* enums
* small tuples
* many tagged unions
* stack-local structs

No GC or ARC needed.

### Tier B: owned heap values

For:

* strings
* binaries
* vectors
* maps
* larger runtime records

Managed by explicit ownership and deterministic destruction.

### Tier C: shared graph values

For:

* closures
* shared persistent collection nodes
* shared boxed runtime values if needed

Managed with ARC.

## 21.3 Why ARC

ARC fits:

* closures
* persistent immutable structures
* shared values

without forcing a tracing collector onto all code.

## 21.4 Cycles

Initial implementation assumes acyclic main-path runtime structures.

If needed later:

* add narrow cycle handling
* or explicit weak/reference-breaking tools

Do not burden v1 with full tracing GC.

## 21.5 Compiler memory model

The compiler itself should use:

* arenas
* symbol interning
* bulk free per phase

Compiler memory management and runtime memory management are separate concerns.

---

# 22. Backend strategy

## 22.1 Stage 1: Zig-source backend

First emit canonical Zig source.

Reasons:

* correctness oracle
* simpler debugging
* fast bring-up
* inspectable output

## 22.2 Stage 2: deeper Zig integration

After stabilization, add a backend that lowers your IR through a pinned Zig integration layer.

Do not expose Zig internals as your public compiler contract.

## 22.3 Stage 3: incremental compilation

Real build performance gains come from architecture.

Implement:

* module signatures
* HIR caches
* macro expansion caches
* codegen-unit reuse
* dependency invalidation
* fallback-chain invalidation

---

# 23. Diagnostics and tooling

## 23.1 Diagnostics must explain

* type errors
* overload ambiguity
* fallback dispatch attempts
* failed pattern matches
* failed refinements
* macro expansion errors
* unreachable clauses
* non-exhaustive matches
* capture-related issues

## 23.2 Dispatch diagnostics

A failed call should show the actual resolution path.

Example shape:

```text
No matching function for b/1

Tried local scope:
  found family b/1
  overload b(Int) not applicable to String

Tried module scope:
  found family b/1
  refinement failed: string_length(s) < 5

No outer scopes remaining
```

## 23.3 Formatter

Because whitespace is significant, the formatter should emit one canonical style.

## 23.4 Language server

The LSP should support:

* type hover
* go to definition
* overload inspection
* fallback dispatch trace
* macro expansion preview
* capture inspection

---

# 24. Canonical example

```elixir
defmodule Foo do
  type Result(a, e) = {:ok, a} | {:error, e}

  def b(s :: String) :: String do
    s <> "foo"
  end

  def a(x :: i64) :: String do
    def b(n :: i64) :: String do
      int_to_string(n)
    end

    def b(s :: String) :: String if string_length(s) < 5 do
      s <> "bar"
    end

    b("other")
  end
end
```

Resolution of `b("other")` inside `a`:

1. inner `b(i64)` exists, not applicable
2. inner `b(String)` is applicable
3. refinement is evaluated
4. if refinement passes, local function is used
5. if refinement fails, fallback continues
6. module `b(String)` is tried
7. if it matches, module function is used
8. otherwise the call fails

That example captures:

* inline types
* local `def`
* overloading
* refinement predicates
* local-first fallback dispatch

---

# 25. Module system

## 25.1 File-to-module mapping

One file defines one module. The module name is derived from the file path relative to the project source root.

```
lib/my_app/accounts/user.zip  →  MyApp.Accounts.User
lib/my_app.zip                →  MyApp
```

## 25.2 Project structure

```
my_project/
  zip.toml                      # project manifest
  lib/
    my_project.zip              # root module
    my_project/
      accounts.zip              # MyProject.Accounts
      accounts/
        user.zip                # MyProject.Accounts.User
  test/
    my_project/
      accounts/
        user_test.zip           # MyProject.Accounts.UserTest
  build/                        # compiler output
```

## 25.3 Visibility

* `def` declares a public function
* `defp` declares a module-private function
* `type` declares a public type (name and representation visible)
* `opaque` declares a public type name with hidden representation

```elixir
defmodule MyApp.Accounts.User do
  opaque HashedPassword = String

  def hash(plain :: String) :: HashedPassword do
    do_hash(plain)
  end

  defp do_hash(plain :: String) :: String do
    plain <> "_hashed"
  end
end
```

## 25.4 Qualified access

Qualified calls always work without import. They resolve directly within the target module's public scope with no fallback.

```elixir
user = MyApp.Accounts.User.hash("secret")
```

## 25.5 `alias`

Creates a short name for a fully-qualified module path. Does not bring functions into scope. Purely syntactic convenience.

```elixir
defmodule MyApp.Main do
  alias MyApp.Accounts.User
  alias MyApp.Accounts.Session, as: S

  # Multi-alias:
  alias MyApp.Accounts.{User, Session, Token}

  def run() :: String do
    User.hash("secret")
  end
end
```

Aliases are lexically scoped from declaration to end of enclosing block.

## 25.6 `import`

Brings a module's public functions and types into the current scope for unqualified access. Imported functions participate in fallback dispatch at the import layer.

```elixir
defmodule MyApp.Display do
  import Formatters.Int, only: [format: 1]
  import Formatters.Float, only: [format: 1]

  def show(x :: i64) :: String do
    format(x)    # resolves to Formatters.Int.format
  end
end
```

Import forms:

```elixir
import Module                            # all public names
import Module, only: [foo: 1, bar: 2]    # selective
import Module, except: [debug: 1]        # exclusion
import Module, only: [type: MyType]      # type import
```

Imports are lexically scoped. An `import` inside a function body is visible only within that function.

If two imports bring conflicting overloads of the same name/arity with the same parameter types, it is an ambiguity error.

## 25.7 Dispatch chain with imports

For an unqualified call:

1. innermost local scope
2. enclosing local scopes (fallback outward)
3. current module scope
4. import scope (all imported families unified)
5. prelude scope (auto-imported `Kernel`)
6. no-match error

## 25.8 Compilation model

* The compiler builds a module dependency graph from `import` and `alias` declarations
* Modules are compiled in topological order
* Circular dependencies between modules are a compile error
* Module signatures (public types and function signatures) are cached after compilation
* Cross-module type checking uses cached signatures

## 25.9 No `require`

Macro ordering is resolved automatically by the dependency graph. No explicit `require` is needed.

## 25.10 `use` (deferred)

`use` will be supported as macro-powered module injection when the macro system is stable. It is not part of v1.

---

# 26. Struct declarations

## 26.1 `defstruct` syntax

Structs are declared inside a module using `defstruct` with a `do...end` block:

```elixir
defmodule User do
  defstruct do
    name :: String
    age :: i64
    role :: String = "user"
  end
end
```

## 26.2 Struct-module relationship

* Every struct belongs to a module
* The module name is the struct type name
* One struct per module

## 26.3 Field defaults and required fields

* Fields without a default value are required at construction
* Fields with `= expr` have a default and are optional at construction

```elixir
%User{name: "Alice", age: 30}            # role defaults to "user"
%User{name: "Alice", age: 30, role: "admin"}  # override default
%User{age: 30}                            # COMPILE ERROR: missing required field 'name'
```

## 26.4 Struct update syntax

Immutable update creates a new struct with selected fields overridden:

```elixir
older = %User{user | age: 31}
renamed = %User{user | name: "Bob", role: "admin"}
```

The expression before `|` must have the struct type being constructed. Override fields must exist and have compatible types.

## 26.5 Field access

Dot notation for field access:

```elixir
user.name    # => "Alice"
user.age     # => 30
```

Compiles to a direct field read. Accessing a nonexistent field is a compile error.

## 26.6 Struct type annotations

Use `%Module{}` in type position:

```elixir
def greet(user :: %User{}) :: String do
  "Hello, " <> user.name
end
```

---

# 27. String interpolation

## 27.1 Syntax

String interpolation uses `#{}` inside double-quoted strings:

```elixir
name = "world"
age :: i64 = 42
"Hello #{name}, you are #{age} years old"
```

## 27.2 Desugaring

String interpolation desugars to `to_string()` calls concatenated with `<>`:

```elixir
# "Hello #{name}, you are #{age}"
# desugars to:
"Hello " <> to_string(name) <> ", you are " <> to_string(age)
```

This desugaring happens in the desugaring phase (before type checking).

## 27.3 `to_string` overload family

The prelude (`Kernel`) provides `to_string/1` overloads for all primitive and numeric types:

```elixir
def to_string(s :: String) :: String       # identity
def to_string(n :: i64) :: String
def to_string(f :: f64) :: String
def to_string(b :: Bool) :: String
def to_string(a :: Atom) :: String
def to_string(n :: Nil) :: String
# ... overloads for all numeric types
```

Users define `to_string` overloads for custom types in their modules. Fallback dispatch finds them:

```elixir
defmodule Point do
  defstruct do
    x :: f64
    y :: f64
  end

  def to_string(p :: %Point{}) :: String do
    "(#{p.x}, #{p.y})"
  end
end
```

If no `to_string` overload exists for an interpolated type, the compiler emits a standard "no matching function" error.

---

# 28. Error handling

## 28.1 Two-level error model

* **Expected failures**: Represented by tagged tuples like `{:ok, a} | {:error, e}`. These are values. They flow through normal control flow and are pattern-matched.
* **Unrecoverable panics**: Represented by program termination via `panic`. For violated invariants and programming errors. Maps to Zig's `@panic`.

## 28.2 `with` pass-through

A `with` expression without an `else` clause propagates non-matching values directly as the result of the `with` expression:

```elixir
def process(input :: String) :: {:ok, Output} | {:error, ParseError} do
  with {:ok, parsed} <- parse(input),
       {:ok, validated} <- validate(parsed) do
    {:ok, validated}
  end
  # No else: if any step returns {:error, e}, it becomes the result.
  # Compiler verifies non-matching types are compatible with the return type.
end
```

## 28.3 The `!` operator (unwrap or panic)

The `!` postfix operator unwraps a `{:ok, v}` value or panics on `{:error, e}`:

```elixir
def load_config() :: Config do
  parsed = parse(read_file("config.zip"))!
  transform(parsed)
end
```

Type rule: if `expr :: {:ok, a} | {:error, e}` then `expr! :: a`.

If the value is `{:error, e}`, the program panics with a message including the error value and source location.

## 28.4 `panic`

`panic` terminates the program immediately with a message:

```elixir
def divide(a :: i64, b :: i64) :: i64 do
  if b == 0 do
    panic("division by zero")
  else
    a / b
  end
end
```

* `panic(message :: String) :: Never`
* `Never` is the bottom type — it is a subtype of all types
* Maps directly to Zig's `@panic`
* Automatically includes source location in output

## 28.5 No `?` early return (v1)

Early return via `?` is not part of v1. `with` covers the chaining case. Can be added later.

## 28.6 No `try`/`rescue`

There is no exception handling. Recoverable errors use tagged tuples. Unrecoverable errors use `panic`.

---

# 29. Operator semantics

## 29.1 Arithmetic operators

All arithmetic operators require both operands to be the same numeric type. No implicit coercion.

| Operator | Allowed types | Return type |
|---|---|---|
| `+` | `(T, T)` where T is any numeric type | `T` |
| `-` | `(T, T)` where T is any numeric type | `T` |
| `*` | `(T, T)` where T is any numeric type | `T` |
| `/` | `(T, T)` where T is any integer type | `T` (integer division) |
| `/` | `(T, T)` where T is any float type | `T` (float division) |
| `rem` | `(T, T)` where T is any integer type | `T` |
| unary `-` | any numeric type | same type |

## 29.2 String concatenation

`<>` works on `(String, String) -> String` only.

## 29.3 Equality

`==` and `!=` perform structural equality. Both operands must be the same type.

```elixir
42 == 42           # true
42 == "hello"      # COMPILE ERROR: cannot compare i64 with String
```

## 29.4 Comparison

`<`, `>`, `<=`, `>=` require same-type operands. Supported for all numeric types and `String` (lexicographic).

## 29.5 Boolean operators

`and`, `or`, `not` are `Bool` only. No truthiness. Short-circuit evaluation for `and` and `or`.

## 29.6 Pipe operator

First-argument insertion, desugared before type checking:

```elixir
x |> f(a, b)       # => f(x, a, b)
x |> f()           # => f(x)
x |> f             # => f(x)
x |> M.f(a)        # => M.f(x, a)
```

Left-associative. Desugared in the desugaring phase.

## 29.7 No user-defined operator overloading (v1)

Operators work only on built-in types. Internally, operators desugar to function calls so that a future protocol/typeclass system can extend them.

## 29.8 No implicit numeric coercion

All numeric type conversions must be explicit. `i32 + i64` is a compile error. Use conversion functions from the prelude.

---

# 30. Builtins and standard library

## 30.1 Compiler intrinsics

A small fixed set of operations that cannot be expressed as normal functions. Prefixed with `@`:

* `@size_of(type)` — compile-time type size
* `@type_name(value)` — compile-time type name as string
* `@unreachable()` — optimization hint / crash
* `@compile_error("msg")` — compile-time error from macros

## 30.2 Prelude (`Kernel`)

Auto-imported into every module. Occupies the outermost dispatch layer before "not found".

Contents include:

```elixir
# Type conversions (explicit, for all numeric types)
def i32_to_i64(n :: i32) :: i64
def i64_to_f64(n :: i64) :: f64
def f64_to_i64(f :: f64) :: i64
def i64_to_string(n :: i64) :: String
def f64_to_string(f :: f64) :: String
def string_to_i64(s :: String) :: {:ok, i64} | {:error, String}
def string_to_f64(s :: String) :: {:ok, f64} | {:error, String}
# ... conversion functions for all numeric type pairs

# Arithmetic
def abs(x :: i64) :: i64
def abs(x :: f64) :: f64
def max(a :: i64, b :: i64) :: i64
def min(a :: i64, b :: i64) :: i64
def div(a :: i64, b :: i64) :: i64

# String
def string_length(s :: String) :: i64

# to_string overloads (for string interpolation)
def to_string(s :: String) :: String
def to_string(n :: i64) :: String
def to_string(f :: f64) :: String
def to_string(b :: Bool) :: String
def to_string(a :: Atom) :: String
def to_string(n :: Nil) :: String
# ... overloads for all numeric types

# List
def length(list :: [a]) :: i64
def hd(list :: [a]) :: a
def tl(list :: [a]) :: [a]

# IO
def println(s :: String) :: Nil
def print(s :: String) :: Nil
def inspect(value :: a) :: String
```

## 30.3 Standard library modules

Require explicit `import` or qualified access:

* `List` — map, filter, foldl, reverse, sort, zip, flat_map, etc.
* `Map` — get, put, delete, keys, values, size, merge, etc.
* `String` — slice, contains?, starts_with?, ends_with?, trim, split, replace, upcase, downcase, etc.
* `Enum` — generic enumeration functions
* `Math` — sqrt, pow, ceil, floor, etc.
* `IO` — file operations, stdin/stdout

---

# 31. Zig code generation

## 31.1 Stage 1: Zig source emission

The first backend emits canonical Zig source files.

## 31.2 Tagged unions

Zip tagged tuples map to Zig's native `union(enum)`:

```zig
// Zip: type Expr = {:int, i64} | {:add, Expr, Expr} | {:none}
const Expr = union(enum) {
    int: i64,
    add: struct { *const Expr, *const Expr },
    none: void,
};
```

Atoms with no payload become `void` variants.

## 31.3 Closures

Closures use a fat-pointer representation: function pointer + environment pointer.

```zig
const Closure_i64_i64 = struct {
    call_fn: *const fn (*anyopaque, i64) i64,
    env: *anyopaque,

    pub fn invoke(self: @This(), arg: i64) i64 {
        return self.call_fn(self.env, arg);
    }
};
```

Environment structs are heap-allocated and ARC-managed. One closure type is monomorphized per distinct function signature.

* `CallDirect` — used for statically-known function calls
* `CallClosure` — used when calling through a closure value

## 31.4 ARC implementation

Reference counting uses atomic operations:

* **Retain**: `fetchAdd(1, .monotonic)`
* **Release**: `fetchSub(1, .release)` + `fence(.acquire)` when count reaches zero

```zig
pub const ArcHeader = struct {
    ref_count: std.atomic.Value(u32),

    pub fn init() ArcHeader {
        return .{ .ref_count = std.atomic.Value(u32).init(1) };
    }
};
```

The compiler generates type-specific destructors for recursive release chains.

## 31.5 Generics

Zip generic types emit as Zig `comptime` type functions:

```zig
// Zip: type Result(a, e) = {:ok, a} | {:error, e}
pub fn Result(comptime A: type, comptime E: type) type {
    return union(enum) {
        ok: A,
        err: E,
    };
}
```

## 31.6 IR-to-Zig instruction mapping

| IR Instruction | Emitted Zig |
|---|---|
| `Const(42)` | `const _v0: i64 = 42;` |
| `LocalGet(x)` | `x` |
| `LocalSet(x, val)` | `const x = <val>;` |
| `AggregateInit(:ok, v)` | `.{ .ok = v }` |
| `FieldGet(x, field)` | `x.field` or via `switch` capture |
| `CallDirect(f, args)` | `f(arg0, arg1)` |
| `CallClosure(c, args)` | `c.invoke(arg0)` |
| `Branch(cond, then, else)` | `if (cond) { ... } else { ... }` |
| `SwitchTag(val, cases)` | `switch (val) { .tag => \|v\| { ... } }` |
| `Return(val)` | `return val;` |
| `AllocOwned(T, val)` | `try Arc(T).init(allocator, val)` |
| `Retain(x)` | `x.retain()` |
| `Release(x)` | `x.release(allocator)` |
| `MakeClosure(body, captures)` | allocate env struct, fill captures, construct pair |
| `CaptureGet(idx)` | `env.field_name` |

## 31.7 Runtime support module

A `zip_runtime.zig` module provides:

* `Arc(T)` — generic ARC wrapper
* `ArcHeader` — embedded reference count
* `ZipAllocator` — allocator plumbing
* Persistent data structure implementations (vectors via RRB-trees, maps via HAMTs)

---

# 32. AST additions

## 32.1 String interpolation

```text
StringInterpolationExpr {
  meta: TypedMeta
  parts: [StringPart]
}

StringPart =
  | StringLiteralPart { value: String }
  | StringInterpolatedPart { expr: Expr }
```

Desugared to `<>` concatenation with `to_string` calls before type checking.

## 32.2 Unwrap expression

```text
UnwrapExpr {
  meta: TypedMeta
  expr: Expr
  # expr must be {:ok, a} | {:error, e} type; result type is a
}
```

## 32.3 Panic expression

```text
PanicExpr {
  meta: TypedMeta
  message: Expr
  # message must be String type; result type is Never
}
```

## 32.4 Struct declaration

```text
StructDecl {
  meta: NodeMeta
  fields: [StructFieldDecl]
}

StructFieldDecl {
  meta: NodeMeta
  name: SymbolId
  type: TypeExpr
  default: Expr?
}
```

## 32.5 Private function declaration

```text
PrivFunctionGroupDecl {
  meta: NodeMeta
  name: SymbolId
  arity: Int
  clauses: [FunctionClause]
  scope_level: ScopeLevel
  visibility: Private
}
```

## 32.6 Import and alias declarations

```text
AliasDecl {
  meta: NodeMeta
  module_path: ModuleName
  as_name: ModuleName?
}

ImportDecl {
  meta: NodeMeta
  module_path: ModuleName
  filter: ImportFilter?
}
```

---

# 33. Implementation roadmap

## Phase 0: freeze the spec

Write and freeze:

* grammar
* type grammar
* numeric type set
* dispatch rules
* macro rules
* memory model
* runtime object model
* module system rules

## Phase 1: lexer and parser

Implement:

* indentation-sensitive lexer
* layout-aware parser
* string interpolation in lexer
* source spans
* parse tests
* formatter skeleton

## Phase 2: declaration collector and scope builder

Implement:

* module/type/def/defp/defstruct collection
* lexical scope graph with import and prelude layers
* local-def hoisting
* family grouping
* alias resolution

## Phase 3: macro engine

Implement:

* quote/unquote
* hygienic symbol generation
* lexical macro environment
* fixed-point expansion

## Phase 4: resolution and typing

Implement:

* symbol resolution
* type declarations with all numeric types
* boundary type contracts
* local inference
* generic instantiation
* pattern refinement typing
* `Never` type as bottom type

## Phase 5: dispatch engine

Implement:

* overload applicability
* specificity comparison
* ambiguity detection
* scope fallback dispatch (local → module → import → prelude)
* clause matching
* refinement evaluation

## Phase 6: typed HIR and matcher

Implement:

* typed HIR
* unified match compilation
* failure continuations
* fallback-parent encoding

## Phase 7: interpreter or verification backend

Implement either:

* typed-core interpreter
* or lowered-IR verifier

This isolates frontend correctness from backend issues.

## Phase 8: Zig-source backend

Implement:

* canonical Zig emission
* tagged union generation
* closure fat-pointer generation
* ARC retain/release insertion
* generic monomorphization via comptime
* `zip_runtime.zig` support module

## Phase 9: runtime

Implement:

* closures and environment structs
* ARC with atomic operations
* owned containers
* persistent data structures (RRB-tree vectors, HAMT maps)
* runtime context / allocator plumbing

## Phase 10: deeper Zig integration

Implement the pinned Zig integration backend.

## Phase 11: incremental compilation

Implement:

* module signature caches
* HIR caches
* macro expansion caches
* codegen-unit reuse
* dependency invalidation
* fallback-chain invalidation

## Phase 12: advanced features

After the above:

* derive macros
* protocols/typeclasses (enables user-defined operator overloading)
* effect typing if desired
* `?` early-return operator
* `use` directive
* stronger optimizations

---

# 34. Remaining explicit open decisions

## 34.1 Protocol / typeclass system

Will polymorphism later include:

* protocols
* typeclasses
* trait-like derivation
* none initially

## 34.2 Effect system

Will effects remain:

* implicit purity-by-default only
* annotation-based
* formalized in types

## 34.3 Persistent collections

Will persistent collections be:

* language-defined
* runtime-defined
* standard-library-defined

## 34.4 Script mode

Will non-module files be first-class or just sugar for an implicit module

---

# 35. Final definition

This language (Zip) is defined by these hard commitments:

* Elixir-like syntax
* all Zig numeric types exposed directly, no implicit coercion
* inline function-header typing
* no `@spec` / `@type` primary typing model
* block-only forms
* significant whitespace
* `def` / `defp` for module functions, `def` for local functions
* `defstruct` for struct declarations within modules
* ordinary function-value call syntax
* ad hoc overloading
* local-first fallback across scopes with import and prelude layers
* pattern matching as a core semantic mechanism
* hygienic macros
* string interpolation via `to_string` overloads
* `!` unwrap-or-panic, `panic` for unrecoverable errors, `Never` bottom type
* one file per module, `alias` and `import` for module system
* functional semantics
* native runtime orientation
* hybrid ownership + ARC memory strategy
* compiler-owned IR before Zig integration
* Zig-oriented backend without making Zig internals the language definition

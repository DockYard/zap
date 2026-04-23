# Proper Zap Code

## Purpose

This document is a repo-grounded guide for writing valid, idiomatic Zap code in this codebase.

It is not a language wish list.
It is not generic functional-programming advice.
It is a practical skill document based on:

- `README.md`
- `lib/*.zap`
- `test/*.zap`
- parser and type-checker constraints in `src/*.zig`

Use this document when writing new Zap code, reviewing Zap code, or deciding whether something belongs in Zap source or the compiler.

## Core Rule

Write Zap code that matches the language the repo actually supports today.

Prefer the current source tree over assumptions.
If the README, tests, and compiler disagree, trust the compiler and existing passing code.

## Top-Level Structure

### One File, One Module

Every `.zap` file should define one module whose name matches its path.

Examples:

- `lib/io.zap` -> `pub struct IO { ... }`
- `lib/zest/case.zap` -> `pub struct Zest.Case { ... }`
- `test/function_test.zap` -> `pub struct Test.FunctionTest { ... }`

### Put Functions Inside Modules

Do not write top-level functions outside a module.

Write:

```zap
pub struct Math {
  pub fn square(x :: i64) -> i64 {
    x * x
  }
}
```

Do not write:

```zap
pub fn square(x :: i64) -> i64 {
  x * x
}
```

### Use Braces

This repo writes Zap blocks with `{ ... }`, not `do ... end`.

Write:

```zap
if x > 0 {
  "positive"
} else {
  "non-positive"
}
```

## Naming

### Use Descriptive Names

Use descriptive names for functions, parameters, local variables, and helpers. Short names like `x`, `n`, or `s` are acceptable when the scope is tiny and the meaning is obvious from context — for example, a math function parameter or a single-line lambda. For anything beyond that, prefer explicit names.

Write:

```zap
pub fn greet(person_name :: String) -> String {
  "Hello, " <> person_name <> "!"
}
```

Short names are fine here:

```zap
fn square(x :: i64) -> i64 {
  x * x
}

fn add_one(n :: i64) -> i64 {
  n + 1
}
```

Avoid cryptic names when the scope is not trivially small:

```zap
# Bad — what is n? what is g?
pub fn process(n :: String, g :: String) -> String {
  g <> ", " <> n <> "!"
}
```

### Struct And Function Naming

- Structs use `PascalCase`
- Namespaced modules use dotted `PascalCase`: `Zest.Case`, `Test.FunctionTest`
- Functions use `snake_case`

Examples from the repo:

- `String.length`
- `IO.print_str`
- `Test.FunctionTest.run`

## Variables And Immutability

Zap variables are immutable. Assignment creates a const binding. Reassigning the same name creates a new const binding that shadows the previous one — the original value is never mutated.

```zap
x = 123
x = x + 5   # x is now 128, but the original 123 was never changed
```

Under the hood, the compiler produces something like:

```
x_0 = 123
x_1 = x_0 + 5
```

This is the same rebinding semantics as Elixir.

## Atoms

Atoms are constants whose name is their value. They are prefixed with `:`.

```zap
:ok
:error
:some_status
```

Atoms are commonly used in tagged tuples for return values and pattern matching:

```zap
fn status(:ok :: Atom) -> String {
  "success"
}

fn status(:error :: Atom) -> String {
  "failure"
}
```

## String Interpolation

Use `#{}` inside double-quoted strings to interpolate expressions:

```zap
name = "world"
greeting = "Hello, #{name}!"
```

The expression inside `#{}` is evaluated and converted to a string. In heredoc documentation strings, escape as `\#{}` to prevent interpolation.

## Function Syntax

### Always Type Annotate Parameters

In user-written Zap code, function parameters must have type annotations.

Write:

```zap
pub fn double(value :: i64) -> i64 {
  value * 2
}
```

Do not write:

```zap
pub fn double(value) -> i64 {
  value * 2
}
```

### Always Declare Return Types

User-written functions should declare return types.

Write:

```zap
pub fn greet(person_name :: String) -> String {
  "Hello, " <> person_name <> "!"
}
```

Do not omit the return type.

### Use Expression-Oriented Bodies

Zap returns the last expression in a block.
Do not write explicit `return` statements — `return` is not a keyword in Zap.

Write:

```zap
pub fn abs(value :: i64) -> i64 {
  if value < 0 {
    -value
  } else {
    value
  }
}
```

## Multi-Clause Functions And Pattern Matching

This repo strongly favors multi-clause function definitions and `case` over deeply imperative logic.

Write:

```zap
fn classify(0 :: i64) -> String {
  "zero"
}

fn classify(1 :: i64) -> String {
  "one"
}

fn classify(_ :: i64) -> String {
  "other"
}
```

Use this style for:

- literal dispatch
- tagged values like `:ok` and `:error`
- tuples and list shapes
- union variants

## Guards

Use guards on function clauses for value refinements.

Write:

```zap
fn classify(number :: i64) -> String if number > 0 {
  "positive"
}

fn classify(number :: i64) -> String if number < 0 {
  "negative"
}

fn classify(_ :: i64) -> String {
  "zero"
}
```

Prefer this over a single function with nested `if` chains when dispatch-by-condition is the real shape of the logic.

## Case Expressions

Use `case` inside function bodies for structured matching.

Write:

```zap
pub fn describe(result_value :: {Atom, String}) -> String {
  case result_value {
    {:ok, value} -> value
    {:error, reason} -> reason
    _ -> "unknown"
  }
}
```

Use `case` when the branching is about value shape or tag.

## Control Flow Macros

The repo uses macro-backed control flow from `Kernel`.

### If / Else

`if` is an expression. It returns the value of the executed branch.

```zap
result = if score > 0 {
  "positive"
} else {
  "non-positive"
}
```

A single-branch `if` returns `nil` when the condition is false:

```zap
x = if false {
  "yes"
}
# x is nil
```

### Unless

`unless` is the negated form of `if`. It executes the body when the condition is false.

```zap
unless done {
  IO.puts("still working...")
}
```

### Cond

Use `cond` for ordered condition branches.

```zap
cond {
  score > 90 -> "A"
  score > 80 -> "B"
  true -> "C"
}
```

### And / Or

Use `and` and `or`, not `&&` and `||`.

Both are short-circuiting:

```zap
valid and process()    # process() only called if valid is true
fallback or default()  # default() only called if fallback is false
```

### Concatenation

Use `<>`, not `++`, for strings.

## Pipe Operator

The pipe operator `|>` passes the left-hand value as the first argument to the function call on the right.

```zap
5 |> add_one()              # => add_one(5)
"hello" |> String.length()  # => String.length("hello")
```

Pipes chain naturally for data transformation pipelines:

```zap
5 |> add_one() |> add_one()  # => add_one(add_one(5)) => 7
```

The right-hand side must be a function call with parentheses. The piped value becomes the first argument, with any explicit arguments shifted after it:

```zap
"hello" |> shout()  # => shout("hello")
```

## Catch Basin Operator `~>`

The catch basin operator `~>` handles unmatched values from multi-clause function pipes. When a piped value does not match any clause in the preceding function, instead of crashing, `~>` catches it and routes it to a handler.

### Block handler with pattern matching

```zap
fn parse("one" :: String) -> String {
  "1"
}

fn parse("two" :: String) -> String {
  "2"
}

fn try_parse(input :: String) -> String {
  input
  |> parse()
  ~> {
    val -> "unmatched: " <> val
  }
}

try_parse("one")   # => "1"
try_parse("nope")  # => "unmatched: nope"
```

The block after `~>` works like a `case` — you can pattern match on the unmatched value:

```zap
input
|> parse()
~> {
  "bad" -> "got bad"
  other -> "unknown: " <> other
}
```

### Function handler

Instead of a block, you can pass a function. The unmatched value is injected as the first argument:

```zap
fn handle_error(val :: String) -> String {
  "error: " <> val
}

fn try_parse(input :: String) -> String {
  input
  |> parse()
  ~> handle_error()
}
```

Function handlers can take extra arguments — the unmatched value is prepended:

```zap
fn fallback(val :: String, prefix :: String) -> String {
  prefix <> val
}

fn try_parse(input :: String) -> String {
  input
  |> parse()
  ~> fallback("fallback: ")
}

try_parse("nope")  # => "fallback: nope"
```

### Multi-step pipes with catch basin

The `~>` catches failures from the entire pipe chain, not just the last step:

```zap
fn validate("good" :: String) -> String {
  "valid"
}

fn format_result(value :: String) -> String {
  "formatted: " <> value
}

fn try_pipeline(input :: String) -> String {
  input
  |> validate()
  |> format_result()
  ~> {
    val -> "rejected: " <> val
  }
}

try_pipeline("good")  # => "formatted: valid"
try_pipeline("bad")   # => "rejected: bad"
```

## For Comprehensions

Use `for` to iterate over a collection and produce a new list:

```zap
doubled = for x <- [1, 2, 3] {
  x * 2
}
# doubled is [2, 4, 6]
```

## Sigils

Sigils are shorthand notations prefixed with `~` followed by a character and a string. They desugar to function calls (`sigil_x("content", [])`) and their implementations live in `Kernel` as macros.

Single-character sigils are reserved for the language. Multi-character sigils can be defined by libraries.

### Built-in sigils

`~s` — String with interpolation (identity, same as a regular string):

```zap
~s"hello"  # => "hello"
```

`~S` — Raw string without interpolation:

```zap
~S"no #{interp}"  # => "no #{interp}" (literal)
```

`~w` — Word list with interpolation — splits on whitespace:

```zap
~w"foo bar baz"  # => ["foo", "bar", "baz"]
```

`~W` — Word list without interpolation:

```zap
~W"foo bar baz"  # => ["foo", "bar", "baz"]
```

## Imports And Use

### import

Use `import ModuleName` when you want unqualified access to functions or macros.

```zap
import Test.MultiModuleHelper

double(3)
```

### use

Use `use ModuleName` for DSL-style modules that define a `__using__` macro.

Examples in the repo:

- `use Zest.Case`
- `use Zest.Runner`

If a module does not provide a `__using__` macro, prefer `import` or qualified calls instead.

## Closures And Function References

### Prefer Explicit Function References

When you want a named callable value, prefer:

```zap
&local_function/1
&ModuleName.function_name/2
```

This is clearer and more reliable than relying on bare function names as values.

### Anonymous Closures

Anonymous closures are supported, but they must be fully annotated.

Write:

```zap
fn(input_value :: i64) -> i64 {
  input_value + 1
}
```

Do not write:

```zap
fn(input_value) -> i64 {
  input_value + 1
}
```

Do not write:

```zap
fn(input_value :: i64) {
  input_value + 1
}
```

### Closure Capture And Ownership

The compiler infers ownership (`shared`, `unique`, `borrowed`) automatically based on types and escape analysis. You do not annotate ownership in Zap source code.

If a closure captures a value that the compiler determines is borrowed, it cannot escape the enclosing scope. The compiler enforces this — you do not need to think about it when writing Zap code.

## Structs, Unions, Maps, Lists, Tuples

### Structs

Use named fields on separate lines.

```zap
pub struct Manifest {
  name :: String
  version :: String
}
```

### Unions

Use bare variant names.

```zap
pub union Color {
  Red
  Green
  Blue
}
```

### Maps

Remember that `%{...}` is a map literal, not automatically a struct.

If you want a struct literal, provide an actual struct context.

### Tuples And Lists

Use tuples and lists heavily with pattern matching.

Examples:

```zap
{left_value, right_value}
[head | tail]
```

## Default Parameters

Default parameters are valid and used in the repo.

```zap
fn greet(person_name :: String, greeting_text :: String = "Hello") -> String {
  greeting_text <> ", " <> person_name <> "!"
}
```

Keep default values simple and obvious.

## Stdlib Code Style

Public stdlib code in `lib/*.zap` should be:

- small
- documented
- typed
- composable
- Zap-first, with `:zig.` calls only for true primitives

Thin wrapper style is normal:

```zap
pub fn length(text_value :: String) -> i64 {
  :zig.ZapString.length(text_value)
}
```

Do not move stdlib behavior into Zig just because it is easier.

## Documentation Style In lib/

Every public function and macro in `lib/*.zap` must have `@fndoc`.
Every public struct should have `@structdoc`.

Use heredocs:

```zap
@fndoc = """
  Returns the byte length of a string.
  """

pub fn length(text_value :: String) -> i64 {
  :zig.ZapString.length(text_value)
}
```

Rules:

- `@structdoc` goes immediately inside the struct body
- `@fndoc` goes immediately before the documented declaration
- leave a blank line after the closing `"""`
- escape `#{` as `\#{` in doc examples

## Testing Style

Follow the repo's Zest pattern.

Write tests like this:

```zap
pub struct Test.MyFeatureTest {
  use Zest.Case

  pub fn run() -> String {
    describe("my feature") {
      test("it works") {
        assert(1 + 1 == 2)
      }
    }

    "MyFeatureTest: passed"
  }
}
```

Rules:

- test modules live under `Test.*`
- use `Zest.Case`
- expose `run() -> String`
- group checks with `describe`
- write simple `test` blocks
- return a trailing `"...: passed"` string from `run/0`

## What Not To Do

### Do Not Write Speculative Zap

Do not assume a feature works just because it looks plausible.
If there is no passing example in the repo and no compiler support for it, verify first.

### Do Not Assume README Examples Are Fully Implemented

The README explicitly says the project is early and not everything described there is fully implemented.

### Do Not Use Bare Function Values When Arity Matters

Prefer `&name/arity` over relying on ambiguous bare names.

### Do Not Omit Types On User-Written Functions Or Anonymous Closures

This repo expects explicit annotations.

## Footguns

These are easy mistakes in the current implementation.

### `%{...}` Is Not Automatically A Struct

It is usually a map unless you provide struct context.

### Ownership Is Implicit

Do not annotate parameters with `borrowed`, `unique`, or `shared`. The compiler infers ownership from types and escape analysis.

### Some Higher-Order Patterns Are Still Maturing

Prefer simple, source-backed callable patterns that already exist in tests and compiler support.

## Writing Checklist

Before finalizing new Zap code, check all of these:

1. Is everything inside a module?
2. Do file path and module name match?
3. Are all parameter types annotated?
4. Are return types explicit?
5. Are names descriptive (or scope is trivially small)?
6. Are you using multi-clause functions or `case` where they fit better than imperative branching?
7. If this is in `lib/`, does every public declaration have docs?
8. Are you using `&name/arity` for explicit function values?
9. Does the code resemble existing passing Zap code in `lib/` or `test/`?

If the answer to any of those is no, fix the code before trusting it.

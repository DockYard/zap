# Kernel

## Functions

### is_integer?/1

```zap
pub fn is_integer?(value :: any) -> Bool
```

Returns true if the value is an integer type (i8, i16, i32, i64, i128, u8, u16, u32, u64, u128).

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/kernel.zap#L269)

---

### is_float?/1

```zap
pub fn is_float?(value :: any) -> Bool
```

Returns true if the value is a float type (f16, f32, f64, f80, f128).

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/kernel.zap#L277)

---

### is_number?/1

```zap
pub fn is_number?(value :: any) -> Bool
```

Returns true if the value is a number (integer or float).

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/kernel.zap#L285)

---

### is_boolean?/1

```zap
pub fn is_boolean?(value :: any) -> Bool
```

Returns true if the value is a boolean.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/kernel.zap#L293)

---

### is_string?/1

```zap
pub fn is_string?(value :: any) -> Bool
```

Returns true if the value is a string.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/kernel.zap#L301)

---

### is_atom?/1

```zap
pub fn is_atom?(value :: any) -> Bool
```

Returns true if the value is an atom.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/kernel.zap#L309)

---

### is_nil?/1

```zap
pub fn is_nil?(value :: any) -> Bool
```

Returns true if the value is nil.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/kernel.zap#L317)

---

### is_list?/1

```zap
pub fn is_list?(value :: any) -> Bool
```

Returns true if the value is a list.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/kernel.zap#L325)

---

### is_tuple?/1

```zap
pub fn is_tuple?(value :: any) -> Bool
```

Returns true if the value is a tuple.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/kernel.zap#L333)

---

### is_map?/1

```zap
pub fn is_map?(value :: any) -> Bool
```

Returns true if the value is a map.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/kernel.zap#L341)

---

### is_struct?/1

```zap
pub fn is_struct?(value :: any) -> Bool
```

Returns true if the value is a struct.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/kernel.zap#L349)

---

### raise/1

```zap
pub fn raise(message :: String) -> ?
```

Raises a runtime error with the provided message.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/kernel.zap#L357)

---

### sleep/1

```zap
pub fn sleep(milliseconds :: i64) -> i64
```

Suspends the current process for the given number of milliseconds.

Returns the number of milliseconds slept. Useful for game loops,
rate limiting, and timed delays.

## Examples

    sleep(100)    # pause for 100ms
    sleep(1000)   # pause for 1 second

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/kernel.zap#L373)

---

### to_string/1

```zap
pub fn to_string(value :: any) -> String
```

Converts any value to its string representation.

Used by string interpolation to convert interpolated expressions
to strings. Handles all Zap types: integers, floats, booleans,
atoms, strings, and structs.

## Examples

    to_string(42)       # => "42"
    to_string(true)     # => "true"
    to_string(:hello)   # => "hello"

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/kernel.zap#L391)

---

### inspect/1

```zap
pub fn inspect(value :: any) -> String
```

Print a value's string representation to stdout, followed by a newline.

Equivalent to `IO.puts(Kernel.to_string(value))`. Useful for quick
debugging or examples that need a value rendered.

## Examples

    Kernel.inspect(42)       # prints "42\n"
    Kernel.inspect(true)     # prints "true\n"
    Kernel.inspect(:hello)   # prints "hello\n"

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/kernel.zap#L408)

---

## Macros

### if/2

```zap
pub macro if(condition :: Expr, then_body :: Expr) -> Nil
```

Conditional expression with a single branch.

Evaluates `condition` and executes `then_body` if truthy.
Returns `nil` if the condition is false.

## Examples

    if x > 0 {
      "positive"
    }

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/kernel.zap#L27)

---

### if/3

```zap
pub macro if(condition :: Expr, then_body :: Expr, else_body :: Expr) -> Nil
```

Conditional expression with both branches.

Evaluates `condition` and executes `then_body` if truthy,
`else_body` if falsy.

## Examples

    if x > 0 {
      "positive"
    } else {
      "non-positive"
    }

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/kernel.zap#L51)

---

### unless/2

```zap
pub macro unless(condition :: Expr, body :: Expr) -> Nil
```

Negated conditional. Executes the body when the condition is false.

## Examples

    unless done {
      IO.puts("still working...")
    }

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/kernel.zap#L70)

---

### and/2

```zap
pub macro and(left :: Expr, right :: Expr) -> Expr
```

Short-circuit logical AND.

Returns `false` immediately if the left operand is false.
Otherwise evaluates and returns the right operand.

## Examples

    true and true    # => true
    true and false   # => false
    false and expr   # => false (expr not evaluated)

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/kernel.zap#L91)

---

### or/2

```zap
pub macro or(left :: Expr, right :: Expr) -> Expr
```

Short-circuit logical OR.

Returns the left operand immediately if it is truthy.
Otherwise evaluates and returns the right operand.

## Examples

    false or true   # => true
    false or false  # => false
    true or expr    # => true (expr not evaluated)

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/kernel.zap#L113)

---

### fn/1

```zap
pub macro fn(decl :: Expr) -> Expr
```

Declaration macro for function definitions.

Receives the full function declaration AST and returns it.
Identity transform — provides a hook point for future
customization such as validation, instrumentation, or
compile-time checks.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/kernel.zap#L131)

---

### struct/1

```zap
pub macro struct(decl :: Expr) -> Expr
```

Declaration macro for struct definitions.

Receives the full struct declaration AST and returns it.
Identity transform — hook point for future customization.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/kernel.zap#L142)

---

### union/1

```zap
pub macro union(decl :: Expr) -> Expr
```

Declaration macro for union/enum definitions.

Receives the full union declaration AST and returns it.
Identity transform — hook point for future customization.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/kernel.zap#L153)

---

### sigil_s/2

```zap
pub macro sigil_s(content :: Expr, _opts :: Expr) -> Expr
```

String sigil with interpolation support.

`~s"hello \#{name}"` is equivalent to `"hello \#{name}"`.
Lowercase sigils allow `\#{}` interpolation.

## Examples

    ~s"hello"         # => "hello"
    ~s"count: \#{42}" # => "count: 42"

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/kernel.zap#L171)

---

### sigil_S/2

```zap
pub macro sigil_S(content :: Expr, _opts :: Expr) -> Expr
```

Raw string sigil without interpolation.

`~S"hello \#{name}"` keeps `\#{name}` as literal characters.
Uppercase sigils suppress interpolation.

## Examples

    ~S"hello"          # => "hello"
    ~S"no \#{interp}"   # => "no \#{interp}" (literal)

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/kernel.zap#L187)

---

### sigil_w/2

```zap
pub macro sigil_w(content :: Expr, _opts :: Expr) -> Expr
```

Word list sigil with interpolation support.

Splits the string on a single space and returns a list of strings.
Lowercase allows `\#{}` interpolation before splitting.

## Examples

    ~w"foo bar baz"  # => ["foo", "bar", "baz"]
    ~w"hello world"  # => ["hello", "world"]

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/kernel.zap#L203)

---

### sigil_W/2

```zap
pub macro sigil_W(content :: Expr, _opts :: Expr) -> Expr
```

Word list sigil without interpolation.

Splits the string on a single space and returns a list of strings.
Uppercase suppresses `\#{}` interpolation.

## Examples

    ~W"foo bar baz"  # => ["foo", "bar", "baz"]

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/kernel.zap#L220)

---

### |>/2

```zap
pub macro |>(left :: Expr, right :: Expr) -> Expr
```

Pipe operator. Passes the left value as the first argument
to the function call on the right.

`x |> f(y)` becomes `f(x, y)`.

## Examples

    5 |> add_one()              # => add_one(5)
    "hello" |> String.length()  # => String.length("hello")
    x |> f() |> g()            # => g(f(x))

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/kernel.zap#L239)

---

### <>/2

```zap
pub macro <>(left :: Expr, right :: Expr) -> Expr
```

Concatenation operator. Dispatches through the `Concatenable`
protocol — any type implementing `Concatenable.concat/2` (built-in:
`String`, `List`, `Map`) supports `<>`. A local `pub fn <>` (or
`pub macro <>`) in the call-site struct still shadows this default,
so users can override `<>` for their own types directly.

## Examples

    "hello, " <> "world"   # String
    [1, 2] <> [3, 4]       # List
    %{a: 1} <> %{b: 2}     # Map

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/kernel.zap#L261)

---


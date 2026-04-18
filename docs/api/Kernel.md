# Kernel

The default module imported into every Zap module.

Kernel provides the fundamental language constructs implemented
as macros: control flow (`if`, `unless`), boolean operators
(`and`, `or`), the pipe operator (`|>`), sigils (`~s`, `~S`,
`~w`, `~W`), and declaration macros (`fn`, `struct`, `union`).

You don't need to `import Kernel` — its macros are available
everywhere automatically.

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

Splits the string on whitespace and returns a list of strings.
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

Splits the string on whitespace and returns a list of strings.
Uppercase suppresses `\#{}` interpolation.

## Examples

    ~W"foo bar baz"  # => ["foo", "bar", "baz"]

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/kernel.zap#L218)

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

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/kernel.zap#L235)

---


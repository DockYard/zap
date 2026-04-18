# Function

Utilities for working with first-class function values.

Zap function values can come from explicit function references such as
`&Module.name/arity` or from anonymous closures written with
`fn(...) -> ... { ... }`.

This module currently exposes the smallest Elixir-inspired function
helper that Zap can support cleanly today without runtime metadata or
broader higher-order standard-library infrastructure.

Zap already has direct invocation syntax for callable values, so this
module does not try to wrap ordinary function calls. It also does not
provide Elixir-style introspection helpers such as `info/1` yet because
Zap does not currently expose stable runtime metadata for function values.

## Macros

### identity/1

```zap
pub macro identity(value_expression :: Expr) -> Expr
```

Returns the value unchanged.

Useful as the default callback when an API accepts a function but no
transformation is needed.

## Examples

    Function.identity(42)      # => 42
    Function.identity("zap")   # => "zap"

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/function.zap#L31)

---


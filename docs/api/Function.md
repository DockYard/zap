# Function

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


# Bool

Functions for working with boolean values.

Zap has two boolean values: `true` and `false`. Booleans are
used in conditionals, guards, and logical expressions.

The Kernel struct provides `and`, `or`, and `not` macros for
use in expressions. This struct provides functional equivalents
that can be passed as values or used in pipes.

## Functions

### to_string/1

```zap
fn to_string(value :: Bool) -> String
```

Converts a boolean to its string representation.

## Examples

    Bool.to_string(true)   # => "true"
    Bool.to_string(false)  # => "false"

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/bool.zap#L22)

---

### negate/1

```zap
fn negate(value :: Bool) -> Bool
```

Returns the logical negation of a boolean.

## Examples

    Bool.negate(true)   # => false
    Bool.negate(false)  # => true

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/bool.zap#L35)

---


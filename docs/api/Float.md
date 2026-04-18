# Float

Functions for working with floating-point numbers.

## Float Types

Zap supports the following floating-point types:

| Type  | Bits | Precision        |
|-------|------|------------------|
| `f16` | 16   | Half precision   |
| `f32` | 32   | Single precision |
| `f64` | 64   | Double precision |

The default float type for literals is `f64`.

## Implicit Widening

Zap automatically widens narrower float types to wider ones at
function call sites: `f16` \u{2192} `f32` \u{2192} `f64`. This is
lossless and zero-cost — the compiler inserts the conversion
automatically.

Integer-to-float conversion is **not** implicit because large
integers cannot be represented exactly in floating-point. Use
`Integer.to_float/1` when needed.

## Functions

### to_string/1

```zap
pub fn to_string(value :: f64) -> String
```

Converts a floating-point number to its string representation.

## Examples

    Float.to_string(3.14)   # => "3.14"
    Float.to_string(-0.5)   # => "-0.5"

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/float.zap#L38)

---

### abs/1

```zap
pub fn abs(value :: f64) -> f64
```

Returns the absolute value of a float.

## Examples

    Float.abs(-3.14)  # => 3.14
    Float.abs(2.5)    # => 2.5
    Float.abs(0.0)    # => 0.0

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/float.zap#L52)

---

### max/2

```zap
pub fn max(first :: f64, second :: f64) -> f64
```

Returns the larger of two floats.

## Examples

    Float.max(3.0, 7.0)    # => 7.0
    Float.max(10.5, 2.3)   # => 10.5

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/float.zap#L65)

---

### min/2

```zap
pub fn min(first :: f64, second :: f64) -> f64
```

Returns the smaller of two floats.

## Examples

    Float.min(3.0, 7.0)    # => 3.0
    Float.min(10.5, 2.3)   # => 2.3

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/float.zap#L78)

---

### parse/1

```zap
pub fn parse(input :: String) -> f64
```

Parses a string into a float. Returns 0.0 if the string
is not a valid float representation.

## Examples

    Float.parse("3.14")    # => 3.14
    Float.parse("-0.5")    # => -0.5
    Float.parse("hello")   # => 0.0

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/float.zap#L93)

---

### round/1

```zap
pub fn round(value :: f64) -> f64
```

Rounds a float to the nearest integer value, returned as a float.
Rounds half-values away from zero.

## Examples

    Float.round(3.2)   # => 3.0
    Float.round(3.7)   # => 4.0
    Float.round(-2.5)  # => -3.0

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/float.zap#L108)

---

### floor/1

```zap
pub fn floor(value :: f64) -> f64
```

Returns the largest integer value less than or equal to the
given float, returned as a float.

## Examples

    Float.floor(3.7)   # => 3.0
    Float.floor(3.0)   # => 3.0
    Float.floor(-2.3)  # => -3.0

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/float.zap#L123)

---

### ceil/1

```zap
pub fn ceil(value :: f64) -> f64
```

Returns the smallest integer value greater than or equal to
the given float, returned as a float.

## Examples

    Float.ceil(3.2)   # => 4.0
    Float.ceil(3.0)   # => 3.0
    Float.ceil(-2.7)  # => -2.0

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/float.zap#L138)

---

### truncate/1

```zap
pub fn truncate(value :: f64) -> f64
```

Truncates a float toward zero, removing the fractional part.
Returned as a float.

## Examples

    Float.truncate(3.7)   # => 3.0
    Float.truncate(-2.9)  # => -2.0
    Float.truncate(5.0)   # => 5.0

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/float.zap#L153)

---

### to_integer/1

```zap
pub fn to_integer(value :: f64) -> i64
```

Converts a float to an integer by truncating toward zero.

## Examples

    Float.to_integer(3.7)   # => 3
    Float.to_integer(-2.9)  # => -2
    Float.to_integer(5.0)   # => 5

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/float.zap#L167)

---

### clamp/3

```zap
pub fn clamp(value :: f64, lower :: f64, upper :: f64) -> f64
```

Clamps a float to be within the given range.

## Examples

    Float.clamp(15.0, 0.0, 10.0)  # => 10.0
    Float.clamp(-5.0, 0.0, 10.0)  # => 0.0
    Float.clamp(5.0, 0.0, 10.0)   # => 5.0

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/float.zap#L181)

---

### floor_to_integer/1

```zap
pub fn floor_to_integer(value :: f64) -> i64
```

Floors a float and converts directly to an integer in one step.
More efficient than `Float.to_integer(Float.floor(x))`.
Uses Zig 0.16's direct float-to-integer conversion builtins.

## Examples

    Float.floor_to_integer(3.7)   # => 3
    Float.floor_to_integer(-2.3)  # => -3
    Float.floor_to_integer(5.0)   # => 5

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/float.zap#L197)

---

### ceil_to_integer/1

```zap
pub fn ceil_to_integer(value :: f64) -> i64
```

Ceils a float and converts directly to an integer in one step.
More efficient than `Float.to_integer(Float.ceil(x))`.
Uses Zig 0.16's direct float-to-integer conversion builtins.

## Examples

    Float.ceil_to_integer(3.2)   # => 4
    Float.ceil_to_integer(-2.7)  # => -2
    Float.ceil_to_integer(5.0)   # => 5

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/float.zap#L213)

---

### round_to_integer/1

```zap
pub fn round_to_integer(value :: f64) -> i64
```

Rounds a float and converts directly to an integer in one step.
More efficient than `Float.to_integer(Float.round(x))`.
Uses Zig 0.16's direct float-to-integer conversion builtins.

## Examples

    Float.round_to_integer(3.2)   # => 3
    Float.round_to_integer(3.7)   # => 4
    Float.round_to_integer(-2.5)  # => -3

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/float.zap#L229)

---


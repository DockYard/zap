# Float

Functions for working with floating-point numbers.

## Float Types

Zap supports the following floating-point types:

| Type  | Bits | Precision        |
|-------|------|------------------|
| `f16` | 16   | Half precision   |
| `f32` | 32   | Single precision |
| `f64` | 64   | Double precision |
| `f80` | 80   | Extended precision |
| `f128` | 128 | Quad precision   |

The default float type for literals is `f64`.

## Call Resolution

Zap first looks for an exact typed function clause. If no exact
clause exists, it may widen within the float family:

`f16` -> `f32` -> `f64` -> `f80` -> `f128`

Integer-to-float conversion is not implicit because large integers
cannot always be represented exactly in floating-point. Use
`Integer.to_float/1` when needed.

## Functions

### to_string/1

```zap
fn to_string(value :: f16) -> String
fn to_string(value :: f32) -> String
fn to_string(value :: f64) -> String
fn to_string(value :: f80) -> String
fn to_string(value :: f128) -> String
```

Converts a floating-point number to its string representation.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/float.zap#L33)

---

### abs/1

```zap
fn abs(value :: f16) -> f16
fn abs(value :: f32) -> f32
fn abs(value :: f64) -> f64
fn abs(value :: f80) -> f80
fn abs(value :: f128) -> f128
```

Returns the absolute value of a float.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/float.zap#L41)

---

### max/2

```zap
fn max(first :: f16, second :: f16) -> f16
fn max(first :: f32, second :: f32) -> f32
fn max(first :: f64, second :: f64) -> f64
fn max(first :: f80, second :: f80) -> f80
fn max(first :: f128, second :: f128) -> f128
```

Returns the larger of two floats.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/float.zap#L49)

---

### min/2

```zap
fn min(first :: f16, second :: f16) -> f16
fn min(first :: f32, second :: f32) -> f32
fn min(first :: f64, second :: f64) -> f64
fn min(first :: f80, second :: f80) -> f80
fn min(first :: f128, second :: f128) -> f128
```

Returns the smaller of two floats.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/float.zap#L57)

---

### parse/1

```zap
fn parse(input :: String) -> f64
```

Parses a string into a float. Returns 0.0 if the string is not
a valid float representation.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/float.zap#L68)

---

### round/1

```zap
fn round(value :: f16) -> f16
fn round(value :: f32) -> f32
fn round(value :: f64) -> f64
fn round(value :: f80) -> f80
fn round(value :: f128) -> f128
```

Rounds a float to the nearest integer value, returned as a float.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/float.zap#L74)

---

### floor/1

```zap
fn floor(value :: f16) -> f16
fn floor(value :: f32) -> f32
fn floor(value :: f64) -> f64
fn floor(value :: f80) -> f80
fn floor(value :: f128) -> f128
```

Returns the largest integer value less than or equal to the given float.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/float.zap#L82)

---

### ceil/1

```zap
fn ceil(value :: f16) -> f16
fn ceil(value :: f32) -> f32
fn ceil(value :: f64) -> f64
fn ceil(value :: f80) -> f80
fn ceil(value :: f128) -> f128
```

Returns the smallest integer value greater than or equal to the given float.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/float.zap#L90)

---

### truncate/1

```zap
fn truncate(value :: f16) -> f16
fn truncate(value :: f32) -> f32
fn truncate(value :: f64) -> f64
fn truncate(value :: f80) -> f80
fn truncate(value :: f128) -> f128
```

Truncates a float toward zero, removing the fractional part.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/float.zap#L98)

---

### to_integer/1

```zap
fn to_integer(value :: f16) -> i64
fn to_integer(value :: f32) -> i64
fn to_integer(value :: f64) -> i64
fn to_integer(value :: f80) -> i64
fn to_integer(value :: f128) -> i64
```

Converts a float to an integer by truncating toward zero.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/float.zap#L106)

---

### clamp/3

```zap
fn clamp(value :: f16, lower :: f16, upper :: f16) -> f16
fn clamp(value :: f32, lower :: f32, upper :: f32) -> f32
fn clamp(value :: f64, lower :: f64, upper :: f64) -> f64
fn clamp(value :: f80, lower :: f80, upper :: f80) -> f80
fn clamp(value :: f128, lower :: f128, upper :: f128) -> f128
```

Clamps a float to be within the given range.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/float.zap#L114)

---

### floor_to_integer/1

```zap
fn floor_to_integer(value :: f16) -> i64
fn floor_to_integer(value :: f32) -> i64
fn floor_to_integer(value :: f64) -> i64
fn floor_to_integer(value :: f80) -> i64
fn floor_to_integer(value :: f128) -> i64
```

Floors a float and converts directly to an integer in one step.
More efficient than `Float.to_integer(Float.floor(x))`.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/float.zap#L125)

---

### ceil_to_integer/1

```zap
fn ceil_to_integer(value :: f16) -> i64
fn ceil_to_integer(value :: f32) -> i64
fn ceil_to_integer(value :: f64) -> i64
fn ceil_to_integer(value :: f80) -> i64
fn ceil_to_integer(value :: f128) -> i64
```

Ceils a float and converts directly to an integer in one step.
More efficient than `Float.to_integer(Float.ceil(x))`.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/float.zap#L136)

---

### round_to_integer/1

```zap
fn round_to_integer(value :: f16) -> i64
fn round_to_integer(value :: f32) -> i64
fn round_to_integer(value :: f64) -> i64
fn round_to_integer(value :: f80) -> i64
fn round_to_integer(value :: f128) -> i64
```

Rounds a float and converts directly to an integer in one step.
More efficient than `Float.to_integer(Float.round(x))`.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/float.zap#L147)

---


# Float

## Functions

### to_string/1

```zap
pub fn to_string(value :: f16) -> String
pub fn to_string(value :: f32) -> String
pub fn to_string(value :: f64) -> String
pub fn to_string(value :: f80) -> String
pub fn to_string(value :: f128) -> String
```

Converts a floating-point number to its string representation.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/float.zap#L33)

---

### abs/1

```zap
pub fn abs(value :: f16) -> f16
pub fn abs(value :: f32) -> f32
pub fn abs(value :: f64) -> f64
pub fn abs(value :: f80) -> f80
pub fn abs(value :: f128) -> f128
```

Returns the absolute value of a float.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/float.zap#L41)

---

### max/2

```zap
pub fn max(first :: f16, second :: f16) -> f16
pub fn max(first :: f32, second :: f32) -> f32
pub fn max(first :: f64, second :: f64) -> f64
pub fn max(first :: f80, second :: f80) -> f80
pub fn max(first :: f128, second :: f128) -> f128
```

Returns the larger of two floats.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/float.zap#L49)

---

### min/2

```zap
pub fn min(first :: f16, second :: f16) -> f16
pub fn min(first :: f32, second :: f32) -> f32
pub fn min(first :: f64, second :: f64) -> f64
pub fn min(first :: f80, second :: f80) -> f80
pub fn min(first :: f128, second :: f128) -> f128
```

Returns the smaller of two floats.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/float.zap#L57)

---

### parse/1

```zap
pub fn parse(input :: String) -> f64
```

Parses a string into a float. Returns 0.0 if the string is not
a valid float representation.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/float.zap#L68)

---

### round/1

```zap
pub fn round(value :: f16) -> f16
pub fn round(value :: f32) -> f32
pub fn round(value :: f64) -> f64
pub fn round(value :: f80) -> f80
pub fn round(value :: f128) -> f128
```

Rounds a float to the nearest integer value, returned as a float.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/float.zap#L74)

---

### floor/1

```zap
pub fn floor(value :: f16) -> f16
pub fn floor(value :: f32) -> f32
pub fn floor(value :: f64) -> f64
pub fn floor(value :: f80) -> f80
pub fn floor(value :: f128) -> f128
```

Returns the largest integer value less than or equal to the given float.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/float.zap#L82)

---

### ceil/1

```zap
pub fn ceil(value :: f16) -> f16
pub fn ceil(value :: f32) -> f32
pub fn ceil(value :: f64) -> f64
pub fn ceil(value :: f80) -> f80
pub fn ceil(value :: f128) -> f128
```

Returns the smallest integer value greater than or equal to the given float.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/float.zap#L90)

---

### truncate/1

```zap
pub fn truncate(value :: f16) -> f16
pub fn truncate(value :: f32) -> f32
pub fn truncate(value :: f64) -> f64
pub fn truncate(value :: f80) -> f80
pub fn truncate(value :: f128) -> f128
```

Truncates a float toward zero, removing the fractional part.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/float.zap#L98)

---

### to_integer/1

```zap
pub fn to_integer(value :: f16) -> i64
pub fn to_integer(value :: f32) -> i64
pub fn to_integer(value :: f64) -> i64
pub fn to_integer(value :: f80) -> i64
pub fn to_integer(value :: f128) -> i64
```

Converts a float to an integer by truncating toward zero.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/float.zap#L106)

---

### clamp/3

```zap
pub fn clamp(value :: f16, lower :: f16, upper :: f16) -> f16
pub fn clamp(value :: f32, lower :: f32, upper :: f32) -> f32
pub fn clamp(value :: f64, lower :: f64, upper :: f64) -> f64
pub fn clamp(value :: f80, lower :: f80, upper :: f80) -> f80
pub fn clamp(value :: f128, lower :: f128, upper :: f128) -> f128
```

Clamps a float to be within the given range.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/float.zap#L114)

---

### floor_to_integer/1

```zap
pub fn floor_to_integer(value :: f16) -> i64
pub fn floor_to_integer(value :: f32) -> i64
pub fn floor_to_integer(value :: f64) -> i64
pub fn floor_to_integer(value :: f80) -> i64
pub fn floor_to_integer(value :: f128) -> i64
```

Floors a float and converts directly to an integer in one step.
More efficient than `Float.to_integer(Float.floor(x))`.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/float.zap#L125)

---

### ceil_to_integer/1

```zap
pub fn ceil_to_integer(value :: f16) -> i64
pub fn ceil_to_integer(value :: f32) -> i64
pub fn ceil_to_integer(value :: f64) -> i64
pub fn ceil_to_integer(value :: f80) -> i64
pub fn ceil_to_integer(value :: f128) -> i64
```

Ceils a float and converts directly to an integer in one step.
More efficient than `Float.to_integer(Float.ceil(x))`.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/float.zap#L136)

---

### round_to_integer/1

```zap
pub fn round_to_integer(value :: f16) -> i64
pub fn round_to_integer(value :: f32) -> i64
pub fn round_to_integer(value :: f64) -> i64
pub fn round_to_integer(value :: f80) -> i64
pub fn round_to_integer(value :: f128) -> i64
```

Rounds a float and converts directly to an integer in one step.
More efficient than `Float.to_integer(Float.round(x))`.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/float.zap#L147)

---


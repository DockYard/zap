# Math

Mathematical functions for numeric computation.

Provides trigonometric, exponential, logarithmic, and other
mathematical operations on numeric values. Functions with numeric
arguments define exact clauses for `i8`, `i16`, `i32`, `i64`,
`i128`, `u8`, `u16`, `u32`, `u64`, `u128`, `f16`, `f32`, `f64`,
`f80`, and `f128` instead of relying on widening.

Float inputs preserve the caller's concrete float type. Integer
inputs return `f64`, except `i128` and `u128` inputs which return
`f128` to avoid forcing 128-bit values through a narrower result
type.

## Constants

Use `Math.pi()` and `Math.e()` for the standard mathematical
constants.

## Examples

    Math.sqrt(9.0)      # => 3.0
    Math.sin(Math.pi()) # => ~0.0
    Math.log(Math.e())  # => 1.0

## Functions

### pi/0

```zap
fn pi() -> f64
```

Returns the ratio of a circle's circumference to its diameter.

## Examples

    Math.pi()  # => 3.141592653589793

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/math.zap#L36)

---

### e/0

```zap
fn e() -> f64
```

Returns Euler's number, the base of natural logarithms.

## Examples

    Math.e()  # => 2.718281828459045

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/math.zap#L48)

---

### sqrt/1

```zap
fn sqrt(value :: f64) -> f64
fn sqrt(value :: i8) -> f64
fn sqrt(value :: i16) -> f64
fn sqrt(value :: i32) -> f64
fn sqrt(value :: i64) -> f64
fn sqrt(value :: i128) -> f128
fn sqrt(value :: u8) -> f64
fn sqrt(value :: u16) -> f64
fn sqrt(value :: u32) -> f64
fn sqrt(value :: u64) -> f64
fn sqrt(value :: u128) -> f128
fn sqrt(value :: f16) -> f16
fn sqrt(value :: f32) -> f32
fn sqrt(value :: f80) -> f80
fn sqrt(value :: f128) -> f128
```

Returns the square root of a number.

## Examples

    Math.sqrt(9.0)   # => 3.0
    Math.sqrt(2.0)   # => 1.4142135623730951
    Math.sqrt(0.0)   # => 0.0

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/math.zap#L62)

---

### sin/1

```zap
fn sin(value :: f64) -> f64
fn sin(value :: i8) -> f64
fn sin(value :: i16) -> f64
fn sin(value :: i32) -> f64
fn sin(value :: i64) -> f64
fn sin(value :: i128) -> f128
fn sin(value :: u8) -> f64
fn sin(value :: u16) -> f64
fn sin(value :: u32) -> f64
fn sin(value :: u64) -> f64
fn sin(value :: u128) -> f128
fn sin(value :: f16) -> f16
fn sin(value :: f32) -> f32
fn sin(value :: f80) -> f80
fn sin(value :: f128) -> f128
```

Returns the sine of an angle in radians.

## Examples

    Math.sin(0.0)          # => 0.0
    Math.sin(Math.pi())    # => ~0.0

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/math.zap#L90)

---

### cos/1

```zap
fn cos(value :: f64) -> f64
fn cos(value :: i8) -> f64
fn cos(value :: i16) -> f64
fn cos(value :: i32) -> f64
fn cos(value :: i64) -> f64
fn cos(value :: i128) -> f128
fn cos(value :: u8) -> f64
fn cos(value :: u16) -> f64
fn cos(value :: u32) -> f64
fn cos(value :: u64) -> f64
fn cos(value :: u128) -> f128
fn cos(value :: f16) -> f16
fn cos(value :: f32) -> f32
fn cos(value :: f80) -> f80
fn cos(value :: f128) -> f128
```

Returns the cosine of an angle in radians.

## Examples

    Math.cos(0.0)          # => 1.0
    Math.cos(Math.pi())    # => -1.0

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/math.zap#L118)

---

### tan/1

```zap
fn tan(value :: f64) -> f64
fn tan(value :: i8) -> f64
fn tan(value :: i16) -> f64
fn tan(value :: i32) -> f64
fn tan(value :: i64) -> f64
fn tan(value :: i128) -> f128
fn tan(value :: u8) -> f64
fn tan(value :: u16) -> f64
fn tan(value :: u32) -> f64
fn tan(value :: u64) -> f64
fn tan(value :: u128) -> f128
fn tan(value :: f16) -> f16
fn tan(value :: f32) -> f32
fn tan(value :: f80) -> f80
fn tan(value :: f128) -> f128
```

Returns the tangent of an angle in radians.

## Examples

    Math.tan(0.0)   # => 0.0

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/math.zap#L145)

---

### exp/1

```zap
fn exp(value :: f64) -> f64
fn exp(value :: i8) -> f64
fn exp(value :: i16) -> f64
fn exp(value :: i32) -> f64
fn exp(value :: i64) -> f64
fn exp(value :: i128) -> f128
fn exp(value :: u8) -> f64
fn exp(value :: u16) -> f64
fn exp(value :: u32) -> f64
fn exp(value :: u64) -> f64
fn exp(value :: u128) -> f128
fn exp(value :: f16) -> f16
fn exp(value :: f32) -> f32
fn exp(value :: f80) -> f80
fn exp(value :: f128) -> f128
```

Returns e raised to the given power.

## Examples

    Math.exp(0.0)   # => 1.0
    Math.exp(1.0)   # => 2.718281828459045

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/math.zap#L173)

---

### exp2/1

```zap
fn exp2(value :: f64) -> f64
fn exp2(value :: i8) -> f64
fn exp2(value :: i16) -> f64
fn exp2(value :: i32) -> f64
fn exp2(value :: i64) -> f64
fn exp2(value :: i128) -> f128
fn exp2(value :: u8) -> f64
fn exp2(value :: u16) -> f64
fn exp2(value :: u32) -> f64
fn exp2(value :: u64) -> f64
fn exp2(value :: u128) -> f128
fn exp2(value :: f16) -> f16
fn exp2(value :: f32) -> f32
fn exp2(value :: f80) -> f80
fn exp2(value :: f128) -> f128
```

Returns 2 raised to the given power.

## Examples

    Math.exp2(3.0)   # => 8.0
    Math.exp2(0.0)   # => 1.0

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/math.zap#L201)

---

### log/1

```zap
fn log(value :: f64) -> f64
fn log(value :: i8) -> f64
fn log(value :: i16) -> f64
fn log(value :: i32) -> f64
fn log(value :: i64) -> f64
fn log(value :: i128) -> f128
fn log(value :: u8) -> f64
fn log(value :: u16) -> f64
fn log(value :: u32) -> f64
fn log(value :: u64) -> f64
fn log(value :: u128) -> f128
fn log(value :: f16) -> f16
fn log(value :: f32) -> f32
fn log(value :: f80) -> f80
fn log(value :: f128) -> f128
```

Returns the natural logarithm (base e) of a number.

## Examples

    Math.log(1.0)         # => 0.0
    Math.log(Math.e())    # => 1.0

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/math.zap#L229)

---

### log2/1

```zap
fn log2(value :: f64) -> f64
fn log2(value :: i8) -> f64
fn log2(value :: i16) -> f64
fn log2(value :: i32) -> f64
fn log2(value :: i64) -> f64
fn log2(value :: i128) -> f128
fn log2(value :: u8) -> f64
fn log2(value :: u16) -> f64
fn log2(value :: u32) -> f64
fn log2(value :: u64) -> f64
fn log2(value :: u128) -> f128
fn log2(value :: f16) -> f16
fn log2(value :: f32) -> f32
fn log2(value :: f80) -> f80
fn log2(value :: f128) -> f128
```

Returns the base-2 logarithm of a number.

## Examples

    Math.log2(8.0)   # => 3.0
    Math.log2(1.0)   # => 0.0

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/math.zap#L257)

---

### log10/1

```zap
fn log10(value :: f64) -> f64
fn log10(value :: i8) -> f64
fn log10(value :: i16) -> f64
fn log10(value :: i32) -> f64
fn log10(value :: i64) -> f64
fn log10(value :: i128) -> f128
fn log10(value :: u8) -> f64
fn log10(value :: u16) -> f64
fn log10(value :: u32) -> f64
fn log10(value :: u64) -> f64
fn log10(value :: u128) -> f128
fn log10(value :: f16) -> f16
fn log10(value :: f32) -> f32
fn log10(value :: f80) -> f80
fn log10(value :: f128) -> f128
```

Returns the base-10 logarithm of a number.

## Examples

    Math.log10(1000.0)   # => 3.0
    Math.log10(1.0)      # => 0.0

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/math.zap#L285)

---


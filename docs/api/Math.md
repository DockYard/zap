# Math

Mathematical functions for floating-point computation.

Provides trigonometric, exponential, logarithmic, and other
mathematical operations on `f64` values. All functions delegate
to Zig's hardware-accelerated builtins for optimal performance.

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
pub fn pi() -> f64
```

Returns the ratio of a circle's circumference to its diameter.

## Examples

    Math.pi()  # => 3.141592653589793

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/math.zap#L29)

---

### e/0

```zap
pub fn e() -> f64
```

Returns Euler's number, the base of natural logarithms.

## Examples

    Math.e()  # => 2.718281828459045

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/math.zap#L41)

---

### sqrt/1

```zap
pub fn sqrt(value :: f64) -> f64
```

Returns the square root of a number.

## Examples

    Math.sqrt(9.0)   # => 3.0
    Math.sqrt(2.0)   # => 1.4142135623730951
    Math.sqrt(0.0)   # => 0.0

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/math.zap#L55)

---

### sin/1

```zap
pub fn sin(value :: f64) -> f64
```

Returns the sine of an angle in radians.

## Examples

    Math.sin(0.0)          # => 0.0
    Math.sin(Math.pi())    # => ~0.0

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/math.zap#L68)

---

### cos/1

```zap
pub fn cos(value :: f64) -> f64
```

Returns the cosine of an angle in radians.

## Examples

    Math.cos(0.0)          # => 1.0
    Math.cos(Math.pi())    # => -1.0

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/math.zap#L81)

---

### tan/1

```zap
pub fn tan(value :: f64) -> f64
```

Returns the tangent of an angle in radians.

## Examples

    Math.tan(0.0)   # => 0.0

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/math.zap#L93)

---

### exp/1

```zap
pub fn exp(value :: f64) -> f64
```

Returns e raised to the given power.

## Examples

    Math.exp(0.0)   # => 1.0
    Math.exp(1.0)   # => 2.718281828459045

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/math.zap#L106)

---

### exp2/1

```zap
pub fn exp2(value :: f64) -> f64
```

Returns 2 raised to the given power.

## Examples

    Math.exp2(3.0)   # => 8.0
    Math.exp2(0.0)   # => 1.0

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/math.zap#L119)

---

### log/1

```zap
pub fn log(value :: f64) -> f64
```

Returns the natural logarithm (base e) of a number.

## Examples

    Math.log(1.0)         # => 0.0
    Math.log(Math.e())    # => 1.0

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/math.zap#L132)

---

### log2/1

```zap
pub fn log2(value :: f64) -> f64
```

Returns the base-2 logarithm of a number.

## Examples

    Math.log2(8.0)   # => 3.0
    Math.log2(1.0)   # => 0.0

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/math.zap#L145)

---

### log10/1

```zap
pub fn log10(value :: f64) -> f64
```

Returns the base-10 logarithm of a number.

## Examples

    Math.log10(1000.0)   # => 3.0
    Math.log10(1.0)      # => 0.0

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/math.zap#L158)

---


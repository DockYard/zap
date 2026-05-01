# Integer

## Functions

### to_string/1

```zap
pub fn to_string(value :: i8) -> String
pub fn to_string(value :: i16) -> String
pub fn to_string(value :: i32) -> String
pub fn to_string(value :: i64) -> String
pub fn to_string(value :: i128) -> String
pub fn to_string(value :: u8) -> String
pub fn to_string(value :: u16) -> String
pub fn to_string(value :: u32) -> String
pub fn to_string(value :: u64) -> String
pub fn to_string(value :: u128) -> String
```

Converts an integer to its string representation.

## Examples

    Integer.to_string(42)    # => "42"
    Integer.to_string(-7)    # => "-7"
    Integer.to_string(0)     # => "0"

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/integer.zap#L41)

---

### abs/1

```zap
pub fn abs(value :: i8) -> i8
pub fn abs(value :: i16) -> i16
pub fn abs(value :: i32) -> i32
pub fn abs(value :: i64) -> i64
pub fn abs(value :: i128) -> i128
pub fn abs(value :: u8) -> u8
pub fn abs(value :: u16) -> u16
pub fn abs(value :: u32) -> u32
pub fn abs(value :: u64) -> u64
pub fn abs(value :: u128) -> u128
```

Returns the absolute value of an integer.

Unsigned integers are already non-negative, so their absolute
value is the original value.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/integer.zap#L59)

---

### max/2

```zap
pub fn max(first :: i8, second :: i8) -> i8
pub fn max(first :: i16, second :: i16) -> i16
pub fn max(first :: i32, second :: i32) -> i32
pub fn max(first :: i64, second :: i64) -> i64
pub fn max(first :: i128, second :: i128) -> i128
pub fn max(first :: u8, second :: u8) -> u8
pub fn max(first :: u16, second :: u16) -> u16
pub fn max(first :: u32, second :: u32) -> u32
pub fn max(first :: u64, second :: u64) -> u64
pub fn max(first :: u128, second :: u128) -> u128
```

Returns the larger of two integers.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/integer.zap#L72)

---

### min/2

```zap
pub fn min(first :: i8, second :: i8) -> i8
pub fn min(first :: i16, second :: i16) -> i16
pub fn min(first :: i32, second :: i32) -> i32
pub fn min(first :: i64, second :: i64) -> i64
pub fn min(first :: i128, second :: i128) -> i128
pub fn min(first :: u8, second :: u8) -> u8
pub fn min(first :: u16, second :: u16) -> u16
pub fn min(first :: u32, second :: u32) -> u32
pub fn min(first :: u64, second :: u64) -> u64
pub fn min(first :: u128, second :: u128) -> u128
```

Returns the smaller of two integers.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/integer.zap#L85)

---

### parse/1

```zap
pub fn parse(input :: String) -> i64
```

Parses a string into an integer. Returns 0 if the string is not
a valid integer representation.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/integer.zap#L101)

---

### remainder/2

```zap
pub fn remainder(dividend :: i8, divisor :: i8) -> i8
pub fn remainder(dividend :: i16, divisor :: i16) -> i16
pub fn remainder(dividend :: i32, divisor :: i32) -> i32
pub fn remainder(dividend :: i64, divisor :: i64) -> i64
pub fn remainder(dividend :: i128, divisor :: i128) -> i128
pub fn remainder(dividend :: u8, divisor :: u8) -> u8
pub fn remainder(dividend :: u16, divisor :: u16) -> u16
pub fn remainder(dividend :: u32, divisor :: u32) -> u32
pub fn remainder(dividend :: u64, divisor :: u64) -> u64
pub fn remainder(dividend :: u128, divisor :: u128) -> u128
```

Computes the remainder of integer division.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/integer.zap#L107)

---

### pow/2

```zap
pub fn pow(base :: i8, exponent :: i8) -> i8
pub fn pow(base :: i16, exponent :: i16) -> i16
pub fn pow(base :: i32, exponent :: i32) -> i32
pub fn pow(base :: i64, exponent :: i64) -> i64
pub fn pow(base :: i128, exponent :: i128) -> i128
pub fn pow(base :: u8, exponent :: u8) -> u8
pub fn pow(base :: u16, exponent :: u16) -> u16
pub fn pow(base :: u32, exponent :: u32) -> u32
pub fn pow(base :: u64, exponent :: u64) -> u64
pub fn pow(base :: u128, exponent :: u128) -> u128
```

Raises `base` to the power of `exponent`.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/integer.zap#L120)

---

### clamp/3

```zap
pub fn clamp(value :: i8, lower :: i8, upper :: i8) -> i8
pub fn clamp(value :: i16, lower :: i16, upper :: i16) -> i16
pub fn clamp(value :: i32, lower :: i32, upper :: i32) -> i32
pub fn clamp(value :: i64, lower :: i64, upper :: i64) -> i64
pub fn clamp(value :: i128, lower :: i128, upper :: i128) -> i128
pub fn clamp(value :: u8, lower :: u8, upper :: u8) -> u8
pub fn clamp(value :: u16, lower :: u16, upper :: u16) -> u16
pub fn clamp(value :: u32, lower :: u32, upper :: u32) -> u32
pub fn clamp(value :: u64, lower :: u64, upper :: u64) -> u64
pub fn clamp(value :: u128, lower :: u128, upper :: u128) -> u128
```

Clamps a value to be within the given range.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/integer.zap#L133)

---

### digits/1

```zap
pub fn digits(value :: i8) -> i64
pub fn digits(value :: i16) -> i64
pub fn digits(value :: i32) -> i64
pub fn digits(value :: i64) -> i64
pub fn digits(value :: i128) -> i64
pub fn digits(value :: u8) -> i64
pub fn digits(value :: u16) -> i64
pub fn digits(value :: u32) -> i64
pub fn digits(value :: u64) -> i64
pub fn digits(value :: u128) -> i64
```

Returns the number of decimal digits in an integer.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/integer.zap#L146)

---

### count_digits/1

```zap
pub fn count_digits(value :: i8) -> i64
pub fn count_digits(value :: i16) -> i64
pub fn count_digits(value :: i32) -> i64
pub fn count_digits(value :: i64) -> i64
pub fn count_digits(value :: i128) -> i64
pub fn count_digits(value :: u8) -> i64
pub fn count_digits(value :: u16) -> i64
pub fn count_digits(value :: u32) -> i64
pub fn count_digits(value :: u64) -> i64
pub fn count_digits(value :: u128) -> i64
```

Counts decimal digits in an integer value.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/integer.zap#L159)

---

### to_float/1

```zap
pub fn to_float(value :: i8) -> f64
pub fn to_float(value :: i16) -> f64
pub fn to_float(value :: i32) -> f64
pub fn to_float(value :: i64) -> f64
pub fn to_float(value :: i128) -> f64
pub fn to_float(value :: u8) -> f64
pub fn to_float(value :: u16) -> f64
pub fn to_float(value :: u32) -> f64
pub fn to_float(value :: u64) -> f64
pub fn to_float(value :: u128) -> f64
```

Converts an integer to a 64-bit floating-point number.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/integer.zap#L172)

---

### count_leading_zeros/1

```zap
pub fn count_leading_zeros(value :: i8) -> i64
pub fn count_leading_zeros(value :: i16) -> i64
pub fn count_leading_zeros(value :: i32) -> i64
pub fn count_leading_zeros(value :: i64) -> i64
pub fn count_leading_zeros(value :: i128) -> i64
pub fn count_leading_zeros(value :: u8) -> i64
pub fn count_leading_zeros(value :: u16) -> i64
pub fn count_leading_zeros(value :: u32) -> i64
pub fn count_leading_zeros(value :: u64) -> i64
pub fn count_leading_zeros(value :: u128) -> i64
```

Returns the number of leading zeros in the binary representation.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/integer.zap#L185)

---

### count_trailing_zeros/1

```zap
pub fn count_trailing_zeros(value :: i8) -> i64
pub fn count_trailing_zeros(value :: i16) -> i64
pub fn count_trailing_zeros(value :: i32) -> i64
pub fn count_trailing_zeros(value :: i64) -> i64
pub fn count_trailing_zeros(value :: i128) -> i64
pub fn count_trailing_zeros(value :: u8) -> i64
pub fn count_trailing_zeros(value :: u16) -> i64
pub fn count_trailing_zeros(value :: u32) -> i64
pub fn count_trailing_zeros(value :: u64) -> i64
pub fn count_trailing_zeros(value :: u128) -> i64
```

Returns the number of trailing zeros in the binary representation.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/integer.zap#L198)

---

### popcount/1

```zap
pub fn popcount(value :: i8) -> i64
pub fn popcount(value :: i16) -> i64
pub fn popcount(value :: i32) -> i64
pub fn popcount(value :: i64) -> i64
pub fn popcount(value :: i128) -> i64
pub fn popcount(value :: u8) -> i64
pub fn popcount(value :: u16) -> i64
pub fn popcount(value :: u32) -> i64
pub fn popcount(value :: u64) -> i64
pub fn popcount(value :: u128) -> i64
```

Returns the number of set bits in the binary representation.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/integer.zap#L211)

---

### byte_swap/1

```zap
pub fn byte_swap(value :: i8) -> i8
pub fn byte_swap(value :: i16) -> i16
pub fn byte_swap(value :: i32) -> i32
pub fn byte_swap(value :: i64) -> i64
pub fn byte_swap(value :: i128) -> i128
pub fn byte_swap(value :: u8) -> u8
pub fn byte_swap(value :: u16) -> u16
pub fn byte_swap(value :: u32) -> u32
pub fn byte_swap(value :: u64) -> u64
pub fn byte_swap(value :: u128) -> u128
```

Reverses the byte order of an integer.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/integer.zap#L224)

---

### bit_reverse/1

```zap
pub fn bit_reverse(value :: i8) -> i8
pub fn bit_reverse(value :: i16) -> i16
pub fn bit_reverse(value :: i32) -> i32
pub fn bit_reverse(value :: i64) -> i64
pub fn bit_reverse(value :: i128) -> i128
pub fn bit_reverse(value :: u8) -> u8
pub fn bit_reverse(value :: u16) -> u16
pub fn bit_reverse(value :: u32) -> u32
pub fn bit_reverse(value :: u64) -> u64
pub fn bit_reverse(value :: u128) -> u128
```

Reverses all bits in the binary representation.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/integer.zap#L237)

---

### add_sat/2

```zap
pub fn add_sat(first :: i8, second :: i8) -> i8
pub fn add_sat(first :: i16, second :: i16) -> i16
pub fn add_sat(first :: i32, second :: i32) -> i32
pub fn add_sat(first :: i64, second :: i64) -> i64
pub fn add_sat(first :: i128, second :: i128) -> i128
pub fn add_sat(first :: u8, second :: u8) -> u8
pub fn add_sat(first :: u16, second :: u16) -> u16
pub fn add_sat(first :: u32, second :: u32) -> u32
pub fn add_sat(first :: u64, second :: u64) -> u64
pub fn add_sat(first :: u128, second :: u128) -> u128
```

Adds two integers with saturation.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/integer.zap#L250)

---

### sub_sat/2

```zap
pub fn sub_sat(first :: i8, second :: i8) -> i8
pub fn sub_sat(first :: i16, second :: i16) -> i16
pub fn sub_sat(first :: i32, second :: i32) -> i32
pub fn sub_sat(first :: i64, second :: i64) -> i64
pub fn sub_sat(first :: i128, second :: i128) -> i128
pub fn sub_sat(first :: u8, second :: u8) -> u8
pub fn sub_sat(first :: u16, second :: u16) -> u16
pub fn sub_sat(first :: u32, second :: u32) -> u32
pub fn sub_sat(first :: u64, second :: u64) -> u64
pub fn sub_sat(first :: u128, second :: u128) -> u128
```

Subtracts two integers with saturation.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/integer.zap#L263)

---

### mul_sat/2

```zap
pub fn mul_sat(first :: i8, second :: i8) -> i8
pub fn mul_sat(first :: i16, second :: i16) -> i16
pub fn mul_sat(first :: i32, second :: i32) -> i32
pub fn mul_sat(first :: i64, second :: i64) -> i64
pub fn mul_sat(first :: i128, second :: i128) -> i128
pub fn mul_sat(first :: u8, second :: u8) -> u8
pub fn mul_sat(first :: u16, second :: u16) -> u16
pub fn mul_sat(first :: u32, second :: u32) -> u32
pub fn mul_sat(first :: u64, second :: u64) -> u64
pub fn mul_sat(first :: u128, second :: u128) -> u128
```

Multiplies two integers with saturation.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/integer.zap#L276)

---

### band/2

```zap
pub fn band(first :: i8, second :: i8) -> i8
pub fn band(first :: i16, second :: i16) -> i16
pub fn band(first :: i32, second :: i32) -> i32
pub fn band(first :: i64, second :: i64) -> i64
pub fn band(first :: i128, second :: i128) -> i128
pub fn band(first :: u8, second :: u8) -> u8
pub fn band(first :: u16, second :: u16) -> u16
pub fn band(first :: u32, second :: u32) -> u32
pub fn band(first :: u64, second :: u64) -> u64
pub fn band(first :: u128, second :: u128) -> u128
```

Bitwise AND of two integers.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/integer.zap#L289)

---

### bor/2

```zap
pub fn bor(first :: i8, second :: i8) -> i8
pub fn bor(first :: i16, second :: i16) -> i16
pub fn bor(first :: i32, second :: i32) -> i32
pub fn bor(first :: i64, second :: i64) -> i64
pub fn bor(first :: i128, second :: i128) -> i128
pub fn bor(first :: u8, second :: u8) -> u8
pub fn bor(first :: u16, second :: u16) -> u16
pub fn bor(first :: u32, second :: u32) -> u32
pub fn bor(first :: u64, second :: u64) -> u64
pub fn bor(first :: u128, second :: u128) -> u128
```

Bitwise OR of two integers.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/integer.zap#L302)

---

### bxor/2

```zap
pub fn bxor(first :: i8, second :: i8) -> i8
pub fn bxor(first :: i16, second :: i16) -> i16
pub fn bxor(first :: i32, second :: i32) -> i32
pub fn bxor(first :: i64, second :: i64) -> i64
pub fn bxor(first :: i128, second :: i128) -> i128
pub fn bxor(first :: u8, second :: u8) -> u8
pub fn bxor(first :: u16, second :: u16) -> u16
pub fn bxor(first :: u32, second :: u32) -> u32
pub fn bxor(first :: u64, second :: u64) -> u64
pub fn bxor(first :: u128, second :: u128) -> u128
```

Bitwise XOR of two integers.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/integer.zap#L315)

---

### bnot/1

```zap
pub fn bnot(value :: i8) -> i8
pub fn bnot(value :: i16) -> i16
pub fn bnot(value :: i32) -> i32
pub fn bnot(value :: i64) -> i64
pub fn bnot(value :: i128) -> i128
pub fn bnot(value :: u8) -> u8
pub fn bnot(value :: u16) -> u16
pub fn bnot(value :: u32) -> u32
pub fn bnot(value :: u64) -> u64
pub fn bnot(value :: u128) -> u128
```

Bitwise NOT of an integer.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/integer.zap#L328)

---

### bsl/2

```zap
pub fn bsl(value :: i8, amount :: i8) -> i8
pub fn bsl(value :: i16, amount :: i16) -> i16
pub fn bsl(value :: i32, amount :: i32) -> i32
pub fn bsl(value :: i64, amount :: i64) -> i64
pub fn bsl(value :: i128, amount :: i128) -> i128
pub fn bsl(value :: u8, amount :: u8) -> u8
pub fn bsl(value :: u16, amount :: u16) -> u16
pub fn bsl(value :: u32, amount :: u32) -> u32
pub fn bsl(value :: u64, amount :: u64) -> u64
pub fn bsl(value :: u128, amount :: u128) -> u128
```

Bitwise shift left.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/integer.zap#L341)

---

### bsr/2

```zap
pub fn bsr(value :: i8, amount :: i8) -> i8
pub fn bsr(value :: i16, amount :: i16) -> i16
pub fn bsr(value :: i32, amount :: i32) -> i32
pub fn bsr(value :: i64, amount :: i64) -> i64
pub fn bsr(value :: i128, amount :: i128) -> i128
pub fn bsr(value :: u8, amount :: u8) -> u8
pub fn bsr(value :: u16, amount :: u16) -> u16
pub fn bsr(value :: u32, amount :: u32) -> u32
pub fn bsr(value :: u64, amount :: u64) -> u64
pub fn bsr(value :: u128, amount :: u128) -> u128
```

Bitwise shift right.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/integer.zap#L354)

---

### sign/1

```zap
pub fn sign(value :: i8) -> i8
pub fn sign(value :: i16) -> i16
pub fn sign(value :: i32) -> i32
pub fn sign(value :: i64) -> i64
pub fn sign(value :: i128) -> i128
pub fn sign(value :: u8) -> u8
pub fn sign(value :: u16) -> u16
pub fn sign(value :: u32) -> u32
pub fn sign(value :: u64) -> u64
pub fn sign(value :: u128) -> u128
```

Returns the sign of an integer.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/integer.zap#L367)

---

### even?/1

```zap
pub fn even?(value :: i8) -> Bool
pub fn even?(value :: i16) -> Bool
pub fn even?(value :: i32) -> Bool
pub fn even?(value :: i64) -> Bool
pub fn even?(value :: i128) -> Bool
pub fn even?(value :: u8) -> Bool
pub fn even?(value :: u16) -> Bool
pub fn even?(value :: u32) -> Bool
pub fn even?(value :: u64) -> Bool
pub fn even?(value :: u128) -> Bool
```

Returns true if the integer is even.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/integer.zap#L380)

---

### odd?/1

```zap
pub fn odd?(value :: i8) -> Bool
pub fn odd?(value :: i16) -> Bool
pub fn odd?(value :: i32) -> Bool
pub fn odd?(value :: i64) -> Bool
pub fn odd?(value :: i128) -> Bool
pub fn odd?(value :: u8) -> Bool
pub fn odd?(value :: u16) -> Bool
pub fn odd?(value :: u32) -> Bool
pub fn odd?(value :: u64) -> Bool
pub fn odd?(value :: u128) -> Bool
```

Returns true if the integer is odd.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/integer.zap#L393)

---

### gcd/2

```zap
pub fn gcd(first :: i8, second :: i8) -> i8
pub fn gcd(first :: i16, second :: i16) -> i16
pub fn gcd(first :: i32, second :: i32) -> i32
pub fn gcd(first :: i64, second :: i64) -> i64
pub fn gcd(first :: i128, second :: i128) -> i128
pub fn gcd(first :: u8, second :: u8) -> u8
pub fn gcd(first :: u16, second :: u16) -> u16
pub fn gcd(first :: u32, second :: u32) -> u32
pub fn gcd(first :: u64, second :: u64) -> u64
pub fn gcd(first :: u128, second :: u128) -> u128
```

Computes the greatest common divisor of two integers.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/integer.zap#L406)

---

### lcm/2

```zap
pub fn lcm(first :: i8, second :: i8) -> i8
pub fn lcm(first :: i16, second :: i16) -> i16
pub fn lcm(first :: i32, second :: i32) -> i32
pub fn lcm(first :: i64, second :: i64) -> i64
pub fn lcm(first :: i128, second :: i128) -> i128
pub fn lcm(first :: u8, second :: u8) -> u8
pub fn lcm(first :: u16, second :: u16) -> u16
pub fn lcm(first :: u32, second :: u32) -> u32
pub fn lcm(first :: u64, second :: u64) -> u64
pub fn lcm(first :: u128, second :: u128) -> u128
```

Computes the least common multiple of two integers.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/integer.zap#L419)

---


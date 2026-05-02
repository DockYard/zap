# Integer

Zap has more than one integer type. `Integer` is the module that gives you
the operations — conversion, arithmetic helpers, bit operations — that work
across the integer family.

## Which integer am I getting?

Integer literals default to `i64`:

```zap
x = 42         # x :: i64
```

When you write a typed parameter, the type sticks:

```zap
pub fn id_u8(n :: u8) -> u8 {
  n
}
```

Zap supports the full power-of-two family (`i8` `i16` `i32` `i64` `i128`,
plus `u8` `u16` `u32` `u64` `u128`) and the platform-sized `usize`/`isize`.

## Numeric overload resolution

When a function has multiple clauses for different integer types, Zap
resolves the call by:

1. Trying each clause's exact type for an exact match.
2. If no exact match, widening within the same family
   (`i8 -> i16 -> i32 -> i64 -> i128`, same for unsigned, same for floats).
3. If no widening works, the call is a compile error.

Integers don't implicitly widen across signedness. `i32` will not silently
become `u32`. Floats and ints don't mix — convert explicitly with
`Integer.to_float/1` or `Float.to_integer/1`.

## Common arithmetic

```zap
Integer.abs(-5)              # => 5
Integer.max(3, 7)            # => 7
Integer.min(3, 7)            # => 3
Integer.clamp(15, 0, 10)     # => 10
Integer.remainder(7, 3)      # => 1
Integer.pow(2, 10)           # => 1024
Integer.gcd(12, 18)          # => 6
Integer.lcm(4, 6)            # => 12
```

## Predicates

```zap
Integer.even?(4)             # => true
Integer.odd?(7)              # => true
Integer.sign(-3)             # => -1
Integer.sign(0)              # => 0
Integer.sign(5)              # => 1
```

## Conversion

```zap
Integer.to_string(42)        # => "42"
Integer.parse("42")          # => 42
Integer.to_float(42)         # => 42.0
```

`parse/1` raises on invalid input. If you can't trust the source, validate
the shape first or wrap the call in a recovery branch.

## Bit operations

For low-level work, `Integer` exposes the standard bitwise toolkit:

```zap
Integer.band(0b1100, 0b1010)    # => 0b1000
Integer.bor(0b1100, 0b1010)     # => 0b1110
Integer.bxor(0b1100, 0b1010)    # => 0b0110
Integer.bnot(0b1100)            # => bitwise complement
Integer.bsl(1, 4)               # => 16   (1 << 4)
Integer.bsr(16, 2)              # => 4    (16 >> 2)
```

Plus the population/bit-counting family:

```zap
Integer.popcount(0b10110100)             # => 4
Integer.count_leading_zeros(0b00001000)  # depends on the integer width
Integer.count_trailing_zeros(0b00010000) # => 4
Integer.bit_reverse(0b0001)              # reverses all bits in the type
Integer.byte_swap(0x1234)                # => 0x3412 (in u16)
```

## Saturating arithmetic

When you don't want overflow to wrap, the saturating ops clamp at the
limits of the integer type:

```zap
Integer.add_sat(250 :: u8, 10)    # => 255 (not 4)
Integer.sub_sat(10 :: u8, 20)     # => 0  (not 246)
Integer.mul_sat(100 :: u8, 100)   # => 255
```

Use these when your value represents something that has natural physical
bounds (a sensor reading, a percent, a pixel intensity).

## See also

- `Float` — the floating-point counterpart
- `Math` — transcendental functions and constants
- `Range` — sequences of integers as a first-class value

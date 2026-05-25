# Phase 0 (first-class-closures prerequisite): a simple `type` alias of a
# builtin must resolve to the builtin's TypeId when used as a function
# parameter type AND a return type.
#
# `type Celsius = i64` then `fn freeze(c :: Celsius) -> Celsius`. Before
# the alias resolver, `Celsius` resolved to void/UNKNOWN and the program
# failed with "expected type 'i64', found 'void'". After: it is exactly
# `i64`, so arithmetic and the return work.
#
# Expected output:
#   0

type Celsius = i64

pub struct Thermo {
  pub fn freeze(c :: Celsius) -> Celsius {
    c - 32
  }
}

fn main(_args :: [String]) -> u8 {
  result = Thermo.freeze(32)
  IO.puts(Integer.to_string(result))
  0
}

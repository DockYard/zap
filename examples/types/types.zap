# Type system examples
#
# Demonstrates supported types: scalars, compound types,
# structs, enums, and module inheritance.

pub module Types {
  pub fn main(_args :: [String]) :: String {
    IO.puts("=== Scalars ===")
    IO.puts(Integer.to_string(Scalars.int()))
    IO.puts(Integer.to_string(Scalars.negative()))
    IO.puts(Float.to_string(Scalars.float()))
    IO.puts(Scalars.string())
    IO.puts(Integer.to_string(Scalars.hex()))
    IO.puts("=== Inheritance ===")
    IO.puts(Dog.speak())
    IO.puts(Dog.breathe())
  }
}

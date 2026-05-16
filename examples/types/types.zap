@doc = """
  Type system tour.

  Demonstrates each kind of value Zap surfaces today:
  scalar primitives via `Scalars`, and struct field inheritance via
  the `Animal` → `Dog` pair where `Dog extends Animal` picks up the
  parent's fields and layers its own on top.

      zap run types
  """

pub struct Types {
  pub fn main(_args :: [String]) -> u8 {
    IO.puts("=== Scalars ===")
    IO.puts(Integer.to_string(Scalars.int()))
    IO.puts(Integer.to_string(Scalars.negative()))
    IO.puts(Float.to_string(Scalars.float()))
    IO.puts(Scalars.string())
    IO.puts(Integer.to_string(Scalars.hex()))
    IO.puts("=== Field inheritance ===")
    rex = %Dog{species: "Canis familiaris", legs: 4, name: "Rex"}
    IO.puts("species: " <> rex.species)
    IO.puts("legs: " <> Integer.to_string(rex.legs))
    IO.puts("name: " <> rex.name)
    IO.puts("good boy: " <> Bool.to_string(rex.good_boy))
    0
  }
}

@doc = """
  Demonstrates defining a small user-level struct (`Scalar`) with a
  handful of integer functions, plus mixing it with the stdlib's
  built-in `Math` struct (`sqrt`, `pi`, ...). Run with:

      zap run math_struct
  """

pub struct MathStruct {
  pub fn main(_args :: [String]) -> String {
    IO.puts("square(5) = " <> Integer.to_string(Scalar.square(5)))
    IO.puts("cube(3) = " <> Integer.to_string(Scalar.cube(3)))
    IO.puts("abs(-7) = " <> Integer.to_string(Scalar.abs(-7)))
    IO.puts("Math.pi = " <> Float.to_string(Math.pi()))
  }
}

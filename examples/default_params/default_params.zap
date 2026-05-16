# Function calls and string operations
#
# Run with:
#   zap run default_params

pub struct DefaultParams {
  pub fn main(_args :: [String]) -> u8 {
    IO.puts(Http.get("https://example.com"))
    IO.puts(Http.post("https://example.com"))
    IO.puts(Greeter.greet("Alice"))
    0
  }
}

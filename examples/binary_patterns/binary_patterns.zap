# Binary patterns example
#
# Demonstrates string operations.
#
# Run with:
#   zap run binary_patterns

pub struct BinaryPatterns {
  pub fn main(_args :: [String]) -> String {
    MarkupParser.greet("Zap")
    |> IO.puts()
  }
}

# Computed attributes
#
# Attributes hold constant values that are substituted at compile time.
# Each @attr must be placed immediately before the function that uses it.
#
# Run with:
#   zap run computed_attributes

pub module ComputedAttributes {
  pub fn main(_args :: [String]) :: String {
    IO.puts("Effective timeout: " <> Integer.to_string(Limits.effective_timeout()))
    IO.puts("Max payload: " <> Integer.to_string(Limits.max_payload()))
  }
}

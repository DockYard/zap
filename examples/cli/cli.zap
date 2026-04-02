# CLI argument handling
#
# main(args) receives CLI arguments as a list of strings.
# Uses arg_count and arg_at to process arguments.
#
# Run with:
#   zap run cli

pub module Cli {
  pub fn main(_args :: [String]) -> String {
    IO.puts("Hello from CLI!")
    IO.puts("Arg count: " <> Integer.to_string(System.arg_count()))
  }
}

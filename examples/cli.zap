# CLI argument pattern matching
#
# main(args) receives CLI arguments as a list of strings.
# Multi-clause dispatch matches on the argument list.
#
# Run with:
#   zap run cli.zap -- greet Alice
#   zap run cli.zap -- version
#   zap run cli.zap

def main(["greet", name]) do
  IO.puts("Hello, " <> name <> "!")
end

def main(["version"]) do
  IO.puts("zap-cli v0.1.0")
end

def main(_) do
  IO.puts("Usage:")
  IO.puts("  cli greet <name>")
  IO.puts("  cli version")
end

# CLI input handling
#
# main(args) receives CLI arguments as a list of strings.
#
# Run with:
#   zap run cli.zap -- hello world

def main(args) do
  Kernel.inspect(args)
end

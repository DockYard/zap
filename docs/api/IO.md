# IO

Functions for standard input/output operations.

`IO` provides the basic building blocks for printing to stdout.
All functions return their input, making them composable in
pipe chains.

## Examples

    IO.puts("Hello, world!")
    "result" |> IO.puts()

## Functions

### puts/1

```zap
pub fn puts(message :: String) -> String
```

    Prints a value to standard output followed by a newline.

    The value is converted to its string representation and written
    to stdout. Returns the original message, making it suitable for
    use in pipe chains.

    ## Examples

        IO.puts("Hello, world!")
        # => prints "Hello, world!
" to stdout

        "result" |> IO.puts()
        # => prints "result
", returns "result"

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/io.zap#L31)

---

### print_str/1

```zap
pub fn print_str(message :: String) -> String
```

Prints a value to standard output without a trailing newline.

Useful for building output incrementally, such as progress
indicators or prompts.

## Examples

    IO.print_str("loading...")
    # => prints "loading..." without newline

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/io.zap#L48)

---


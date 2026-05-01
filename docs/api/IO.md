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

### gets/0

```zap
pub fn gets() -> String
```

Reads a line from standard input.

Returns the line without the trailing newline.
Returns an empty string on EOF.

## Examples

    name = IO.gets()
    IO.puts("Hello, " <> name)

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/io.zap#L65)

---

### warn/1

```zap
pub fn warn(message :: String) -> String
```

Prints a message to standard error followed by a newline.

Useful for logging and error messages that should not
mix with normal output.

## Examples

    IO.warn("something went wrong")

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/io.zap#L80)

---

### mode/1

```zap
pub fn mode(mode_value :: IO.Mode) -> IO.Mode
```

Switches the terminal input mode.

## Examples

    IO.mode(IO.Mode.Raw)      # keypress-at-a-time, no echo
    key = IO.get_char()
    IO.mode(IO.Mode.Normal)   # restore line-buffered mode

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/io.zap#L95)

---

### mode/2

```zap
pub fn mode(mode_value :: IO.Mode, callback :: () -> result) -> result
```

Switches terminal mode, runs the callback, then restores
normal mode automatically.

## Examples

    IO.mode(IO.Mode.Raw, fn() -> i64 {
      key = IO.get_char()
      IO.puts("You pressed: " <> key)
      0
    })

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/io.zap#L113)

---

### get_char/0

```zap
pub fn get_char() -> String
```

Reads a single character from standard input.

In raw mode, returns immediately after one keypress.
In normal mode, blocks until Enter then returns the first character.

Returns a single-character string, or empty string on EOF.

## Examples

    IO.mode(1)
    key = IO.get_char()
    IO.mode(0)

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/io.zap#L135)

---

### try_get_char/0

```zap
pub fn try_get_char() -> String
```

Non-blocking read of a single character from standard input.

Returns a single-character string if a key is available, or
an empty string if no input is waiting. Must be in raw mode
for meaningful use.

## Examples

    IO.mode(IO.Mode.Raw)
    key = IO.try_get_char()
    if key == "" {
      IO.puts("no key pressed")
    }

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/io.zap#L155)

---


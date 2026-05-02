# IO

`IO` is the bridge between your Zap program and the world outside it. It
covers the three streams every program inherits — `stdout`, `stderr`,
`stdin` — and the terminal modes that make interactive programs possible.

There is intentionally no buffered, structured "logger" or "file handle"
here. `File` covers files; `IO` covers the program's standard streams.

## Writing to stdout

```zap
IO.puts("hello")            # writes "hello\n"
IO.print_str("no newline")  # writes "no newline"
```

`puts/1` is the right default for human-readable output. Use `print_str/1`
when you're composing fragments that would otherwise produce stray newlines.

For diagnostic output, prefer `warn/1`:

```zap
IO.warn("ignoring malformed line")   # writes to stderr with newline
```

Sending diagnostics to `stderr` keeps them out of any pipeline that consumes
your program's `stdout`.

## Reading from stdin

```zap
line = IO.gets()    # blocks until a newline is read
```

`gets/0` returns the line including the trailing newline. Use `String.trim/1`
if you want it stripped:

```zap
IO.print_str("name: ")
name = String.trim(IO.gets())
IO.puts("hello, \#{name}")
```

Single-character reads are explicit:

```zap
ch = IO.get_char()        # blocking, one byte
maybe = IO.try_get_char() # non-blocking; returns "" if no input is ready
```

`try_get_char/0` is the building block for event loops that can't afford to
block while waiting for a key.

## Terminal modes

Standard "cooked" terminal mode buffers input until you press Enter and
echoes characters back. Interactive programs usually need raw mode — every
key arrives immediately, there is no echo, and signal characters like
Ctrl+C don't get special treatment.

The two-arity form is the safe way to use raw mode:

```zap
IO.mode(:raw, fn() {
  case IO.get_char() {
    "q" -> :quit
    other -> other
  }
})
```

`IO.mode/2` switches into the requested mode, runs your callback, and always
restores the previous mode — even if the callback raises. You don't have to
remember to flip the terminal back; if you forgot, your shell would be stuck
in raw mode after the program exited.

The single-arity form is escape hatch for cases where you genuinely want to
manage the lifetime yourself:

```zap
IO.mode(:raw)
# ... do work ...
IO.mode(:cooked)
```

## A small example: a key-driven menu

```zap
pub fn run() {
  IO.mode(:raw, fn() {
    IO.puts("Press: (q)uit, (r)eload, (h)elp")
    case IO.get_char() {
      "q" -> :quit
      "r" -> reload()
      "h" -> help()
      _   -> :unknown
    }
  })
}
```

The callback returns its value out of `IO.mode/2`, so the result of the
menu propagates normally.

## See also

- `File` — reading and writing files
- `System` — environment variables, command-line arguments, process info
- `IO.Mode` — the union of supported terminal modes

# String

`String` in Zap is a UTF-8 byte sequence. There is no separate "char" type
and no separate "byte string" type. A string is a string.

Most of what you'll do with strings — compare, search, split, slice, format —
goes through the `String` module. The `<>` operator concatenates via the
`Concatenable` protocol, and `Enum` works against strings as a sequence of
single-byte strings when you need to iterate.

## Construction and interpolation

The `~s"..."` sigil (and the equivalent `"..."` literal in most positions)
produce a `String`. Interpolation uses `\#{expr}`:

```zap
name = "world"
greeting = "hello, \#{name}!"        # => "hello, world!"
```

For a raw string with no interpolation, use `~S"..."`. For a list of words,
`~w[foo bar baz]` produces `["foo", "bar", "baz"]`.

## Comparing and searching

```zap
String.starts_with?("filename.zap", "file")    # => true
String.ends_with?("filename.zap", ".zap")      # => true
String.contains?("a long sentence", "long")    # => true
String.index_of("hello", "ll")                 # => 2
String.index_of("hello", "zz")                 # => -1
```

`index_of/2` returns `-1` for "not found" rather than wrapping the result in
an option. Same convention as `Enum.find/3` — Zap prefers a cheap sentinel
over allocating a wrapper.

## Slicing and trimming

```zap
String.slice("hello world", 0, 5)    # => "hello"
String.slice("hello world", 6, 11)   # => "world"
String.trim("  hi  ")                # => "hi"
```

Indices are byte offsets. For ASCII text this is the same as character
offsets; for multi-byte UTF-8 you need to think in bytes (or split before
slicing).

## Splitting and joining

```zap
String.split("a,b,c", ",")           # => ["a", "b", "c"]
String.join(["a", "b", "c"], ", ")   # => "a, b, c"
```

`split/2` always returns a list. If you only want the first part, take it:

```zap
"name: Alice"
|> String.split(": ")
|> List.head()                        # => "name"
```

## Casing and padding

```zap
String.upcase("zap")                       # => "ZAP"
String.downcase("ZAP")                     # => "zap"
String.capitalize("hello world")           # => "Hello world"
String.pad_leading("42", 5, "0")           # => "00042"
String.pad_trailing("zap", 6, ".")         # => "zap..."
```

## Converting to and from numbers

```zap
String.to_integer("42")    # => 42
String.to_float("3.14")    # => 3.14

Integer.to_string(42)      # => "42"
Float.to_string(3.14)      # => "3.14"
```

These functions raise on a malformed input. If you can't trust the source,
validate before converting.

## Strings as enumerables

Because `String` implements `Enumerable`, every `Enum` function works on it:

```zap
Enum.count("hello", fn(c) { c == "l" })          # => 2
Enum.map("abc", fn(c) { String.upcase(c) })      # => ["A", "B", "C"]
```

The element type is `String` (a single-byte string), not a code point. If
you need code-point handling, work in the byte domain explicitly.

## Concatenation via `<>`

The `<>` operator is concatenation through the `Concatenable` protocol:

```zap
"hello" <> ", " <> "world"   # => "hello, world"
```

For larger assemblies, prefer `String.join/2` — it allocates once instead of
once per pair.

## See also

- `Concatenable` protocol — `<>` operator behavior
- `Enum` — generic operations that also work on strings
- `Path` — string operations that understand path separators

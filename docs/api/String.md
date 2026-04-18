# String

Functions for working with UTF-8 encoded strings.

Strings in Zap are immutable byte sequences (`[]const u8` in the
underlying Zig representation). All operations return new strings
rather than modifying in place.

## Examples

    String.length("hello")              # => 5
    String.contains("hello world", "o") # => true
    String.slice("hello", 0, 3)         # => "hel"

## Functions

### length/1

```zap
pub fn length(s :: String) -> i64
```

Returns the byte length of a string.

This returns the number of bytes, not the number of Unicode
codepoints. For ASCII strings, bytes and characters are the same.

## Examples

    String.length("hello")  # => 5
    String.length("")       # => 0

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/string.zap#L28)

---

### byte_at/2

```zap
pub fn byte_at(s :: String, index :: i64) -> String
```

Returns the byte at the given index as a single-character string.

Index is zero-based. Returns an empty string if the index is
out of bounds.

## Examples

    String.byte_at("hello", 0)  # => "h"
    String.byte_at("hello", 4)  # => "o"
    String.byte_at("hello", 99) # => ""

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/string.zap#L45)

---

### contains/2

```zap
pub fn contains(haystack :: String, needle :: String) -> Bool
```

Returns `true` if `haystack` contains `needle` as a substring.

## Examples

    String.contains("hello world", "world")  # => true
    String.contains("hello world", "xyz")    # => false
    String.contains("hello", "")             # => true

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/string.zap#L59)

---

### starts_with/2

```zap
pub fn starts_with(s :: String, prefix :: String) -> Bool
```

Returns `true` if the string starts with the given prefix.

## Examples

    String.starts_with("hello", "hel")   # => true
    String.starts_with("hello", "world") # => false

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/string.zap#L72)

---

### ends_with/2

```zap
pub fn ends_with(s :: String, suffix :: String) -> Bool
```

Returns `true` if the string ends with the given suffix.

## Examples

    String.ends_with("hello", "llo")    # => true
    String.ends_with("hello", "world")  # => false

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/string.zap#L85)

---

### trim/1

```zap
pub fn trim(s :: String) -> String
```

Removes leading and trailing whitespace from a string.

Strips spaces, tabs, newlines, and carriage returns.

## Examples

    String.trim("  hello  ")   # => "hello"

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/string.zap#L99)

---

### slice/3

```zap
pub fn slice(s :: String, start :: i64, end :: i64) -> String
```

Returns a substring from `start` (inclusive) to `end` (exclusive).

Indices are byte-based and zero-indexed. Out-of-bounds indices
are clamped to the string length.

## Examples

    String.slice("hello world", 0, 5)   # => "hello"
    String.slice("hello world", 6, 11)  # => "world"

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/string.zap#L115)

---

### to_atom/1

```zap
pub fn to_atom(name :: String) -> Atom
```

Converts a string to an atom, creating it if it doesn't exist.

Atoms are interned — each unique string maps to a single atom ID.

## Examples

    String.to_atom("ok")    # => :ok
    String.to_atom("error") # => :error

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/string.zap#L130)

---

### to_existing_atom/1

```zap
pub fn to_existing_atom(name :: String) -> Atom
```

Converts a string to an existing atom.

Unlike `to_atom/1`, this does not create new atoms. Returns a
sentinel value if the atom has not been previously interned.

## Examples

    String.to_existing_atom("ok")  # => :ok (if :ok exists)

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/string.zap#L145)

---

### upcase/1

```zap
pub fn upcase(s :: String) -> String
```

Converts all characters to uppercase.

Only affects ASCII letters (a-z).

## Examples

    String.upcase("hello")      # => "HELLO"
    String.upcase("Hello World") # => "HELLO WORLD"
    String.upcase("123")        # => "123"

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/string.zap#L161)

---

### downcase/1

```zap
pub fn downcase(s :: String) -> String
```

Converts all characters to lowercase.

Only affects ASCII letters (A-Z).

## Examples

    String.downcase("HELLO")      # => "hello"
    String.downcase("Hello World") # => "hello world"
    String.downcase("123")        # => "123"

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/string.zap#L177)

---

### reverse/1

```zap
pub fn reverse(s :: String) -> String
```

Reverses the bytes of a string.

## Examples

    String.reverse("hello")  # => "olleh"
    String.reverse("abc")    # => "cba"
    String.reverse("")       # => ""

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/string.zap#L191)

---

### replace/3

```zap
pub fn replace(s :: String, pattern :: String, replacement :: String) -> String
```

Replaces all occurrences of `pattern` with `replacement`.

## Examples

    String.replace("hello world", "world", "zap")  # => "hello zap"
    String.replace("aaa", "a", "bb")                # => "bbbbbb"
    String.replace("hello", "xyz", "abc")           # => "hello"

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/string.zap#L205)

---

### index_of/2

```zap
pub fn index_of(haystack :: String, needle :: String) -> i64
```

Returns the index of the first occurrence of `needle` in the
string, or -1 if not found.

## Examples

    String.index_of("hello world", "world")  # => 6
    String.index_of("hello", "xyz")           # => -1
    String.index_of("hello", "")              # => 0

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/string.zap#L220)

---

### pad_leading/3

```zap
pub fn pad_leading(s :: String, total_length :: i64, pad_char :: String) -> String
```

Pads the string on the left to reach the target length using
the given padding character.

## Examples

    String.pad_leading("42", 5, "0")   # => "00042"
    String.pad_leading("hello", 3, " ") # => "hello"

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/string.zap#L234)

---

### pad_trailing/3

```zap
pub fn pad_trailing(s :: String, total_length :: i64, pad_char :: String) -> String
```

Pads the string on the right to reach the target length using
the given padding character.

## Examples

    String.pad_trailing("hi", 5, ".")   # => "hi..."
    String.pad_trailing("hello", 3, " ") # => "hello"

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/string.zap#L248)

---

### repeat/2

```zap
pub fn repeat(s :: String, count :: i64) -> String
```

Repeats a string the given number of times.

## Examples

    String.repeat("ab", 3)  # => "ababab"
    String.repeat("x", 5)   # => "xxxxx"
    String.repeat("hi", 0)  # => ""

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/string.zap#L262)

---

### to_integer/1

```zap
pub fn to_integer(s :: String) -> i64
```

Parses a string into an integer. Returns 0 if the string
is not a valid integer.

Delegates to `Integer.parse/1`.

## Examples

    String.to_integer("42")    # => 42
    String.to_integer("hello") # => 0

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/string.zap#L278)

---

### to_float/1

```zap
pub fn to_float(s :: String) -> f64
```

Parses a string into a float. Returns 0.0 if the string
is not a valid float.

Delegates to `Float.parse/1`.

## Examples

    String.to_float("3.14")    # => 3.14
    String.to_float("hello")   # => 0.0

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/string.zap#L294)

---

### capitalize/1

```zap
pub fn capitalize(s :: String) -> String
```

Capitalizes the first character and lowercases the rest.

Only affects ASCII letters.

## Examples

    String.capitalize("hello")   # => "Hello"
    String.capitalize("HELLO")   # => "Hello"
    String.capitalize("")        # => ""

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/string.zap#L310)

---

### trim_leading/1

```zap
pub fn trim_leading(s :: String) -> String
```

Removes leading whitespace from a string.

Strips spaces, tabs, newlines, and carriage returns from
the beginning only.

## Examples

    String.trim_leading("  hello  ")  # => "hello  "
    String.trim_leading("hello")       # => "hello"

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/string.zap#L326)

---

### trim_trailing/1

```zap
pub fn trim_trailing(s :: String) -> String
```

Removes trailing whitespace from a string.

Strips spaces, tabs, newlines, and carriage returns from
the end only.

## Examples

    String.trim_trailing("  hello  ")  # => "  hello"
    String.trim_trailing("hello")       # => "hello"

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/string.zap#L342)

---

### count/2

```zap
pub fn count(haystack :: String, needle :: String) -> i64
```

Counts non-overlapping occurrences of a substring.

## Examples

    String.count("hello world hello", "hello")  # => 2
    String.count("aaa", "aa")                     # => 1
    String.count("hello", "xyz")                  # => 0

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/string.zap#L356)

---


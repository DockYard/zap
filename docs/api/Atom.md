# Atom

Functions for working with atoms.

Atoms are constants whose name is their value. They are
interned — each unique name maps to a single atom ID,
making equality comparison constant-time.

Atoms are written with a leading colon: `:ok`, `:error`,
`:my_atom`.

## Examples

    :ok == :ok        # => true
    :ok == :error     # => false
    Atom.to_string(:hello)  # => "hello"

## Functions

### to_string/1

```zap
fn to_string(atom :: Atom) -> String
```

Converts an atom to its string representation (the name
without the leading colon).

## Examples

    Atom.to_string(:hello)  # => "hello"
    Atom.to_string(:ok)     # => "ok"

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/atom.zap#L29)

---


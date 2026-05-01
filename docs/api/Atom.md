# Atom

## Functions

### to_string/1

```zap
pub fn to_string(atom :: Atom) -> String
```

Converts an atom to its string representation (the name
without the leading colon).

## Examples

    Atom.to_string(:hello)  # => "hello"
    Atom.to_string(:ok)     # => "ok"

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/atom.zap#L29)

---


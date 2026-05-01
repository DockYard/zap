# Path

Functions for manipulating file system paths.

Most functions are pure string manipulation. `Path.glob/1` reads
the file system and returns matching paths in deterministic sorted
order.

## Examples

    Path.join("src", "main.zap")  # => "src/main.zap"
    Path.basename("/usr/bin/zap")  # => "zap"
    Path.dirname("/usr/bin/zap")   # => "/usr/bin"
    Path.extname("main.zap")       # => ".zap"
    Path.glob("lib/**/*.zap")      # => ["lib/path.zap", ...]

## Functions

### join/2

```zap
pub fn join(left :: String, right :: String) -> String
```

Joins two path segments with a separator.

## Examples

    Path.join("src", "main.zap")  # => "src/main.zap"
    Path.join("src/", "main.zap") # => "src/main.zap"

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/path.zap#L27)

---

### basename/1

```zap
pub fn basename(path :: String) -> String
```

Returns the last component of a path.

## Examples

    Path.basename("/usr/bin/zap")  # => "zap"
    Path.basename("main.zap")      # => "main.zap"

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/path.zap#L40)

---

### dirname/1

```zap
pub fn dirname(path :: String) -> String
```

Returns the directory component of a path.

## Examples

    Path.dirname("/usr/bin/zap")  # => "/usr/bin"
    Path.dirname("main.zap")      # => "."

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/path.zap#L53)

---

### extname/1

```zap
pub fn extname(path :: String) -> String
```

Returns the file extension including the dot.

## Examples

    Path.extname("main.zap")   # => ".zap"
    Path.extname("Makefile")   # => ""

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/path.zap#L66)

---

### glob/1

```zap
pub fn glob(pattern :: String) -> [String]
```

Returns paths matching a glob pattern as a sorted list of strings.

Supports `*`, `?`, and recursive `**` wildcards. Relative patterns
return relative paths. If no paths match, returns an empty list.

## Examples

    Path.glob("lib/*.zap")    # => ["lib/atom.zap", ...]
    Path.glob("lib/**/*.zap") # => ["lib/list/enumerable.zap", ...]
    Path.glob("missing/*")    # => []

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/path.zap#L83)

---


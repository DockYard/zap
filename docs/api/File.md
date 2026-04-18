# File

Functions for reading and writing files.

All paths are relative to the current working directory.
File operations return empty strings or false on failure.

## Examples

    content = File.read("config.txt")
    File.write("output.txt", "Hello, world!")
    File.exists?("config.txt")  # => true

## Functions

### read/1

```zap
pub fn read(path :: String) -> String
```

Reads the entire contents of a file as a string.
Returns an empty string if the file cannot be read.

## Examples

    File.read("hello.txt")  # => "Hello, world!"
    File.read("missing.txt")  # => ""

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/file.zap#L25)

---

### write/2

```zap
pub fn write(path :: String, content :: String) -> Bool
```

Writes a string to a file, creating it if it doesn't exist
and overwriting if it does. Returns true on success.

## Examples

    File.write("output.txt", "Hello!")  # => true

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/file.zap#L38)

---

### exists?/1

```zap
pub fn exists?(path :: String) -> Bool
```

Returns true if the file exists at the given path.

## Examples

    File.exists?("build.zap")   # => true
    File.exists?("missing.txt")  # => false

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/file.zap#L51)

---


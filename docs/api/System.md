# System

Functions for interacting with the operating system.

Provides access to command-line arguments, environment variables,
and build-time configuration options.

## Functions

### arg_count/0

```zap
fn arg_count() -> i64
```

Returns the number of command-line arguments passed to the program.

Does not count the program name itself.

## Examples

    # Running: zap run my_app -- foo bar
    System.arg_count()  # => 2

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/system.zap#L20)

---

### arg_at/1

```zap
fn arg_at(index :: i64) -> String
```

Returns the command-line argument at the given index.

Index is zero-based, starting from the first user argument
(the program name is not included). Returns an empty string
if the index is out of bounds.

## Examples

    # Running: zap run my_app -- hello world
    System.arg_at(0)  # => "hello"
    System.arg_at(1)  # => "world"

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/system.zap#L38)

---

### get_env/1

```zap
fn get_env(name :: String) -> String
```

Reads an environment variable by name.

Returns the value of the environment variable, or an empty
string if it is not set.

## Examples

    System.get_env("HOME")      # => "/Users/alice"
    System.get_env("UNDEFINED") # => ""

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/system.zap#L54)

---

### get_build_opt/1

```zap
fn get_build_opt(name :: String) -> String
```

Reads a build-time option by name.

Build options are passed via `-Dkey=value` on the command line.
Returns an empty string if the option is not set.

## Examples

    # Building: zap build my_app -Doptimize=release_fast
    System.get_build_opt("optimize")  # => "release_fast"

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/system.zap#L70)

---

### cwd/0

```zap
fn cwd() -> String
```

Returns the current working directory.

## Examples

    System.cwd()  # => "/Users/dev/project"

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/system.zap#L82)

---


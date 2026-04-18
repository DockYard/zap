# Zest

Zest test framework.

For test cases: `use Zest.Case` (provides assert/reject + describe/test DSL).
For test runner: `use Zest.Runner` (provides summary).

This module provides standalone assert and reject functions
with non-fatal test tracking via `:zig.TestTracker`. Failed
assertions mark the current test as failed and return "F"
but do not stop execution.

## Functions

### assert/1

```zap
pub fn assert(value :: Bool) -> String
```

Asserts that a boolean value is `true`.

On success, increments the assertion pass counter and
returns ".". On failure, increments the assertion fail
counter and returns "F". Execution continues (non-fatal).

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/zest.zap#L22)

---

### assert/2

```zap
pub fn assert(value :: Bool, message :: String) -> String
```

Asserts that a boolean value is `true` with a custom message.

On success, increments the assertion pass counter and
returns ".". On failure, increments the assertion fail
counter and returns "F". Execution continues (non-fatal).

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/zest.zap#L34)

---

### reject/1

```zap
pub fn reject(value :: Bool) -> String
```

Asserts that a boolean value is `false`.

On success, increments the assertion pass counter and
returns ".". On failure, increments the assertion fail
counter and returns "F". Execution continues (non-fatal).

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/zest.zap#L46)

---

### reject/2

```zap
pub fn reject(value :: Bool, message :: String) -> String
```

Asserts that a boolean value is `false` with a custom message.

On success, increments the assertion pass counter and
returns ".". On failure, increments the assertion fail
counter and returns "F". Execution continues (non-fatal).

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/zest.zap#L58)

---


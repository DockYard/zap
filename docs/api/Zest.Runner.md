# Zest.Runner

## Functions

### configure/0

```zap
pub fn configure() -> Atom
```

Parses `--seed` and `--timeout` from CLI arguments and applies
them to the test tracker. If `--seed <integer>` is present,
sets the seed explicitly for reproducible ordering. Otherwise
the tracker generates a seed from the system clock.

If `--timeout <milliseconds>` is present, sets a per-test
timeout. Tests exceeding the timeout are marked as failed
with a yellow "T" indicator.

Call this before running any tests to ensure the seed and
timeout are set.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/zest/runner.zap#L89)

---

### run/0

```zap
pub fn run() -> String
```

Prints the test summary with counts and exits with a
failure code if any tests failed.

Call this as the last line of the test runner's `main`
function. It invokes `:zig.Zest.summary()` which
outputs the final report to stdout, including the seed
used for test ordering.

## Examples

    pub fn main(_args :: [String]) -> String {
      Zest.Runner.configure()
      Test.MyTest.run()
      Zest.Runner.run()
    }

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/zest/runner.zap#L111)

---

### parse_cli_args/2

```zap
pub fn parse_cli_args(index :: i64, count :: i64) -> Atom
```

Recursively scans CLI arguments for `--seed <value>` and
`--timeout <milliseconds>`, applying each to the test tracker.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/zest/runner.zap#L121)

---

## Macros

### options/1

```zap
pub macro options(opts :: Expr) -> Expr
```

Normalizes runner options to a list.

`nil` and `[]` become an empty list, an existing option list is returned
as-is, and a single non-list option is wrapped in a one-element list.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/zest/runner.zap#L59)

---

### patterns/1

```zap
pub macro patterns(options :: Expr) -> Expr
```

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/zest/runner.zap#L147)

---

### option_patterns/1

```zap
pub macro option_patterns(option :: Expr) -> Expr
```

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/zest/runner.zap#L160)

---

### pattern_values/1

```zap
pub macro pattern_values(value :: Expr) -> Expr
```

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/zest/runner.zap#L172)

---


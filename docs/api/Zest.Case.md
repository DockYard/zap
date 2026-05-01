# Zest.Case

Test case DSL for the Zest test framework.

Provides `describe`, `test`, `assert`, `reject`, `setup`, and
`teardown` for writing structured test cases with test tracking.

Setup runs fresh before EACH test that requests context.
Teardown runs after each test. Assertions are non-fatal.

The `describe` and `test` macros expand into function declarations
so that each test becomes a named pub function (test_*) that is
called at struct level.

## Examples

    pub struct Test.MyTest {
      use Zest.Case

      describe("my feature") {
        setup() {
          42
        }

        test("uses context", ctx) {
          assert(ctx == 42)
        }

        test("no context needed") {
          assert(true)
        }

        teardown() {
          IO.puts("cleanup")
        }
      }
    }

## Functions

### begin_test/0

```zap
pub fn begin_test() -> Atom
```

Wraps `begin_test` for explicit use.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/zest/case.zap#L133)

---

### end_test/0

```zap
pub fn end_test() -> Atom
```

Wraps `end_test` for explicit use.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/zest/case.zap#L142)

---

### print_result/0

```zap
pub fn print_result() -> Atom
```

Wraps `print_result` for explicit use.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/zest/case.zap#L151)

---

### assert/1

```zap
pub fn assert(value :: Bool) -> String
```

Asserts that a boolean value is `true`.

Non-fatal: returns :fail on failure, does not stop execution.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/zest/case.zap#L162)

---

### reject/1

```zap
pub fn reject(value :: Bool) -> String
```

Asserts that a boolean value is `false`.

Non-fatal: returns "F" on failure, does not stop execution.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/zest/case.zap#L178)

---

## Macros

### describe/2

```zap
pub macro describe(_name :: Expr, body :: Expr) -> Expr
```

Groups related tests under a descriptive label.

Scans the body for `setup` and `teardown` blocks, then
transforms each `test` call into a pub function declaration
with begin_test/end_test/print_result tracking calls injected.

## Examples

    describe("math") {
      setup() { 42 }

      test("addition", ctx) {
        assert(ctx == 42)
      }
    }

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/zest/case.zap#L68)

---

### test/2

```zap
pub macro test(_name :: Expr, body :: Expr) -> Expr
```

Defines a test case without context.

Expands into a pub function declaration named test_<slugified_name>
with begin_test/end_test/print_result tracking calls wrapping the body.

## Examples

    test("true is true") {
      assert(true == true)
    }

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/zest/case.zap#L111)

---

### setup/1

```zap
pub macro setup(body :: Expr) -> Expr
```

Declares setup code that runs before each test with context.

Place inside a `describe` block. The return value is bound
to `ctx` in each `test/3` call. Runs fresh for every test.

## Examples

    setup() {
      connect_db()
    }

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/zest/case.zap#L201)

---

### teardown/1

```zap
pub macro teardown(body :: Expr) -> Expr
```

Declares teardown code that runs after each test.

Place inside a `describe` block. Runs after every test body,
even if assertions fail (non-fatal assertions).

## Examples

    teardown() {
      disconnect_db()
    }

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/zest/case.zap#L218)

---


# Zest.Case

## Functions

### begin_test/0

```zap
pub fn begin_test() -> Atom
```

Wraps `begin_test` for explicit use.

---

### end_test/0

```zap
pub fn end_test() -> Atom
```

Wraps `end_test` for explicit use.

---

### print_result/0

```zap
pub fn print_result() -> Atom
```

Wraps `print_result` for explicit use.

---

### assert/1

```zap
pub fn assert(value :: Bool) -> String
```

Asserts that a boolean value is `true`.

Non-fatal: returns :fail on failure, does not stop execution.

---

### reject/1

```zap
pub fn reject(value :: Bool) -> String
```

Asserts that a boolean value is `false`.

Non-fatal: returns "F" on failure, does not stop execution.

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

---


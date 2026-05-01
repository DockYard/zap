# Arithmetic

Protocol for types that support arithmetic operations.

Any type implementing `Arithmetic` participates in `+`, `-`, `*`,
`/`, and `rem`. The compiler dispatches each operator to the
matching impl based on the left operand's type at compile time.

Built-in implementations exist for `Integer` (i64) and `Float` (f64).
Define `impl Arithmetic for MyType { ... }` to add support for
user-defined numeric types.

## Required Functions

```zap
fn +(left, right) -> any
```

```zap
fn -(left, right) -> any
```

```zap
fn *(left, right) -> any
```

```zap
fn /(left, right) -> any
```

```zap
fn rem(left, right) -> any
```


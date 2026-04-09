# Closures And Function References

Zap supports first-class callable values through both explicit function references and anonymous closures.

## Function References

You can reference an existing function value with `&name/arity` or `&Module.name/arity`.

Local function reference:

```zap
pub module Demo {
  pub fn double(x :: i64) -> i64 {
    x * 2
  }

  pub fn run() -> i64 {
    f = &double/1
    f(21)
  }
}
```

Module-qualified function reference:

```zap
pub module Demo {
  pub fn apply(x :: i64, f :: (i64 -> i64)) -> i64 {
    f(x)
  }

  pub fn run() -> i64 {
    apply(21, &Demo.double/1)
  }

  pub fn double(x :: i64) -> i64 {
    x * 2
  }
}
```

## Anonymous Closures

Anonymous closures use `fn(...) -> ReturnType { ... }`.

```zap
pub module Demo {
  pub fn run() -> i64 {
    add_one = fn(x :: i64) -> i64 {
      x + 1
    }

    add_one(41)
  }
}
```

Anonymous closures can capture surrounding bindings:

```zap
pub module Demo {
  pub fn run() -> i64 {
    offset = 10

    add_offset = fn(x :: i64) -> i64 {
      x + offset
    }

    add_offset(32)
  }
}
```

## Higher-Order Functions

Function values use ordinary function types.

```zap
pub module Demo {
  pub fn apply(x :: i64, f :: (i64 -> i64)) -> i64 {
    f(x)
  }

  pub fn run() -> i64 {
    apply(41, fn(x :: i64) -> i64 {
      x + 1
    })
  }
}
```

## Required Annotations

Anonymous closures currently require:

- type annotations on every parameter
- an explicit return type

Valid:

```zap
fn(x :: i64) -> i64 {
  x + 1
}
```

Invalid:

```zap
fn(x) -> i64 {
  x + 1
}
```

Invalid:

```zap
fn(x :: i64) {
  x + 1
}
```

## Borrow Safety

Closures that capture borrowed values cannot escape their borrow scope by being stored or returned.

Invalid:

```zap
pub module Demo {
  pub fn run(x :: borrowed String) -> Nil {
    f = fn() -> String {
      x
    }

    nil
  }
}
```

Invalid:

```zap
pub module Demo {
  pub fn run(x :: borrowed String) -> (String -> String) {
    fn(y :: String) -> String {
      x <> y
    }
  }
}
```

When a closure captures a borrowed binding, call it locally instead of returning or storing it.

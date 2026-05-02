# Struct

Compile-time helpers for reflected struct declarations.

Functions in this struct accept references returned by `SourceGraph`
reflection APIs.

## Macros

### functions/1

```zap
macro functions(struct_ref :: Expr) -> Expr
```

Returns the public functions declared on a reflected struct.

Each result is a compile-time map with `:name`, `:arity`, and
`:visibility` entries.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/struct.zap#L18)

---

### has_function?/3

```zap
macro has_function?(struct_ref :: Expr, function_name :: Expr, function_arity :: Expr) -> Expr
```

Returns true when a reflected struct exposes a public function with
the given name and arity.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/struct.zap#L31)

---


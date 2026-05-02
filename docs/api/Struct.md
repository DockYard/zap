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

Each result is a compile-time map with `:name`, `:arity`,
`:visibility`, and `:doc` entries. The `:doc` value is the
function's `@doc` attribute string (heredoc indentation stripped),
or an empty string when no `@doc` is attached.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/struct.zap#L20)

---

### macros/1

```zap
macro macros(struct_ref :: Expr) -> Expr
```

Returns the public macros declared on a reflected struct, with the
same map shape as `functions/1`. Language hooks like `__using__`
and `__before_compile__` are excluded — they are not part of the
public API surface.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/struct.zap#L33)

---

### info/1

```zap
macro info(struct_ref :: Expr) -> Expr
```

Returns struct-level metadata for a reflected struct as a compile-time
map: `:name`, `:source_file` (project-relative path), `:is_private`,
and `:doc` (the struct's `@doc` attribute, heredoc-stripped, or
empty when missing).

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/struct.zap#L46)

---

### has_function?/3

```zap
macro has_function?(struct_ref :: Expr, function_name :: Expr, function_arity :: Expr) -> Expr
```

Returns true when a reflected struct exposes a public function with
the given name and arity.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/struct.zap#L59)

---


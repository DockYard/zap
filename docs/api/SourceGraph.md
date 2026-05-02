# SourceGraph

Compile-time access to source-level declarations.

Source graph functions are intended for macros and other compile-time
code that need to inspect declarations from known source paths.

## Macros

### structs/1

```zap
macro structs(paths :: Expr) -> Expr
```

Returns struct references declared in the exact source paths provided.

Each returned reference can be unquoted into generated code as a
qualified struct name. Pass a string path or a list of string paths.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/source_graph.zap#L18)

---

### protocols/1

```zap
macro protocols(paths :: Expr) -> Expr
```

Returns protocol references declared in the exact source paths
provided. Each ref carries the protocol's qualified name in the
same `__aliases__` AST shape as `structs/1` results. Combine with
`Struct.info/1` to retrieve protocol-level metadata.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/source_graph.zap#L31)

---

### unions/1

```zap
macro unions(paths :: Expr) -> Expr
```

Returns union references declared in the exact source paths
provided. Top-level dotted unions (e.g. `pub union IO.Mode`) keep
their fully qualified name; nested unions declared inside a struct
appear with their local name here — qualify them with the parent
struct yourself when rendering.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/source_graph.zap#L45)

---

### impls/1

```zap
macro impls(paths :: Expr) -> Expr
```

Returns public protocol-impl entries declared in the supplied
source paths. Each entry is a compile-time map with `:protocol`
(qualified name), `:target` (qualified type name), `:source_file`,
and `:is_private`. Doc generation reads this list to render the
per-type "Implements" row.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/source_graph.zap#L59)

---


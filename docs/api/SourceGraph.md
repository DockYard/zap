# SourceGraph

## Macros

### structs/1

```zap
pub macro structs(paths :: Expr) -> Expr
```

Returns struct references declared in the exact source paths provided.

Each returned reference can be unquoted into generated code as a
qualified struct name. Pass a string path or a list of string paths.

[Source](https://github.com/DockYard/zap/blob/v0.1.0/./lib/source_graph.zap#L18)

---


@doc = """
  Protocol for types that support functional update via `%{coll | key: value}`.

  Map literals like `%{m | k: v}` desugar to `Updatable.update/3`. Built-in
  implementations cover `Map`. User types can implement it the same way to
  expose a uniform "with one key replaced" operation.

  ## Examples

      %{m | k: v}             # Map with k set to v
  """

pub protocol Updatable {
  fn update(collection, key, value) -> any
}

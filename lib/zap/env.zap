@doc = """
  Build environment passed to `Zap.Builder.manifest/1`.

  All three fields describe the **requested compilation target** (the
  `-Dtarget=<triple>` override, or the host triple for a native build) —
  not the host the manifest evaluator runs on. `target` is the triple
  atom (e.g. `:wasm32-wasi`); `os` and `arch` are the resolved
  `std.Target` os/arch atoms (e.g. `:wasi`, `:wasm32`). Branching a
  manifest on `env.os`/`env.arch` therefore reflects the cross target.
  """

pub struct Zap.Env {
  target :: Atom
  os :: Atom
  arch :: Atom
}

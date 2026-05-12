@doc = """
  Project manifest returned by `Zap.Builder.manifest/1`.

  The manifest controls build output, entry points, source paths,
  dependencies, build options, and documentation settings.

  ## `memory:` field

  Selects the memory manager for the binary. The value is a struct
  reference (e.g. `Zap.Memory.ARC`, `Zap.Memory.Arena`,
  `Zap.Memory.NoOp`, or any third-party manager struct that carries a
  `@memory_manager_source` attribute).

  When omitted, the manifest defaults to `Zap.Memory.ARC`. The Zap-side
  driver short-circuits the built-in ARC default — no external manager
  `.o` is compiled — so existing projects continue to work without any
  manifest change.

  See `docs/memory-manager-abi.md` for the Memory Manager ABI v1.0
  contract every manager must conform to.
  """

pub struct Zap.Manifest {
  name :: String
  version :: String
  kind :: Atom
  root :: String = ""
  asset_name :: String = ""
  optimize :: Atom = :release_safe
  paths :: [String] = []
  deps :: [Zap.Dep] = []
  memory :: Zap.Memory.ARC = Zap.Memory.ARC
  build_opts :: [{String, String}] = []
  test_timeout :: i64 = 0
  error_style :: String = ""
  multiline_errors :: Bool = false
  source_url :: String = ""
  landing_page :: String = ""
  doc_groups :: [{String, [String]}] = []
}

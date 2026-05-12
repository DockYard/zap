@doc = """
  Project manifest returned by `Zap.Builder.manifest/1`.

  The manifest controls build output, entry points, source paths,
  dependencies, build options, and documentation settings.

  ## `memory:` field

  Selects the memory manager for the binary. The value is a string
  holding the fully-qualified manager struct name (e.g.
  `"Zap.Memory.ARC"`, `"Zap.Memory.Arena"`, `"Zap.Memory.NoOp"`, or any
  third-party manager struct that carries a `@memory_manager_source`
  attribute). String syntax is required because Zap's CTFE does not
  currently support struct-type references as values.

  When omitted (or set to `""`), the manifest defaults to
  `Zap.Memory.ARC`. See `docs/memory-manager-abi.md` for the Memory
  Manager ABI v1.0 contract every manager must conform to.
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
  memory :: String = ""
  build_opts :: [{String, String}] = []
  test_timeout :: i64 = 0
  error_style :: String = ""
  multiline_errors :: Bool = false
  source_url :: String = ""
  landing_page :: String = ""
  doc_groups :: [{String, [String]}] = []
}

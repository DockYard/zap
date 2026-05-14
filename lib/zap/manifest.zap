@doc = """
  Project manifest returned by `Zap.Builder.manifest/1`.

  The manifest controls build output, entry points, source paths,
  dependencies, build options, and documentation settings.

  ## `root:` field

  Selects the binary entry point with a first-class `Function`
  reference, such as `&App.main/1`. When omitted, the backend keeps
  its default entry-point behavior.

  ## `memory:` field

  Selects the memory manager type for the binary. The value is a
  first-class `Type` such as `Memory.ARC`, `Memory.Arena`,
  `Memory.NoOp`, or any third-party type that implements
  `Memory.Manager`.

  When omitted, the manifest defaults to `Memory.ARC`. See
  `docs/memory-manager-abi.md` for the Memory Manager ABI v1.0
  contract every manager must conform to.
  """

pub struct Zap.Manifest {
  name :: String
  version :: String
  kind :: Atom
  root :: Function | Nil = nil
  asset_name :: String = ""
  optimize :: Atom = :release_safe
  paths :: [String] = []
  deps :: [Zap.Dep] = []
  memory :: Type = Memory.ARC
  build_opts :: [{String, String}] = []
  test_timeout :: i64 = 0
  error_style :: String = ""
  multiline_errors :: Bool = false
  source_url :: String = ""
  landing_page :: String = ""
  doc_groups :: [{String, [String]}] = []
}

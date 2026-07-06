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

  ## `target:` field

  Selects the compilation target as a Zig target-triple atom such
  as `:"aarch64-linux-gnu"` or `:"wasm32-wasi"`. When omitted (the
  `:native` default), the build targets the host natively. The CLI
  `-Dtarget=<triple>` flag overrides this per-field — the command
  line is the ultimate source of truth.

  ## `cpu:` field

  Selects the target CPU model/feature set as a Zig CPU atom such
  as `:baseline` or `:apple_m1`. When omitted (the `:native`
  default), the target's default CPU is used. The CLI `-Dcpu=<cpu>`
  flag overrides this per-field.

  ## `runtime_concurrency:` field

  Comptime gate over the concurrency runtime kernel. When `false`
  (the default), the binary compiles exactly as before the kernel
  existed: no scheduler code is compiled or linked, no `zap_proc_*`
  intrinsic symbol exists in the artifact, and no startup cost is
  paid. When `true`, the per-target kernel object is linked into the
  binary and the runtime initializes the scheduler before `main` and
  shuts it down after. The CLI `-Druntime-concurrency=on|off` flag
  overrides this per-field.

  Phase 2 posture: the gate exposes the kernel's C-ABI intrinsic
  bridge only; the `spawn`/`send`/`receive` language surface lands in
  later Phase 2 jobs of `docs/concurrency-implementation-plan.md`.

  ## `pipeline:` field

  Overrides the command pipeline for this manifest. When omitted, Zap
  compiles the current artifact only. A pipeline can opt into explicit
  compile and run steps while reusing the same artifact build path.
  """

pub struct Zap.Manifest {
  name :: String
  version :: String
  kind :: Atom
  root :: Function | Nil = nil
  asset_name :: String = ""
  optimize :: Atom = :release_safe
  target :: Atom = :native
  cpu :: Atom = :native
  paths :: [String] = []
  deps :: [Zap.Dep] = []
  memory :: Type = Memory.ARC
  runtime_concurrency :: Bool = false
  build_opts :: [{String, String}] = []
  test_timeout :: i64 = 0
  error_style :: String = ""
  multiline_errors :: Bool = false
  source_url :: String = ""
  landing_page :: String = ""
  doc_groups :: [{String, [String]}] = []
  pipeline :: Zap.Build.Pipeline | Nil = nil
}

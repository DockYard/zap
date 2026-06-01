## Build manifest probe for the `%Zap.Env` host-vs-target fix (Phase 1).
##
## The manifest derives the project `name` from `env.os`. Before the fix
## `env.os`/`env.arch` reported the HOST (the machine running the manifest
## evaluator) regardless of `-Dtarget=`; after the fix they report the
## REQUESTED compilation target. `run_target_env_probe.sh` builds this for
## several targets and asserts the artifact `name` (visible in the build
## output / on-disk path) reflects the target os — e.g.
## `-Dtarget=wasm32-wasi` yields name `env-os-wasi`, NOT the host `macos`.
##
## A full-string `case` (no `<>` concat) keeps the name a comptime-known
## literal the manifest CTFE evaluator can fold.
pub struct EnvProbe.Builder {
  pub fn manifest(env :: Zap.Env) -> Zap.Manifest {
    %Zap.Manifest{
      name: project_name(env.os),
      version: "0.1.0",
      kind: :bin,
      root: &EnvProbe.main/1,
      paths: ["lib/**/*.zap"]
    }
  }

  fn project_name(os :: Atom) -> String {
    case os {
      :macos -> "env-os-macos"
      :linux -> "env-os-linux"
      :windows -> "env-os-windows"
      :wasi -> "env-os-wasi"
      _ -> "env-os-unknown"
    }
  }
}

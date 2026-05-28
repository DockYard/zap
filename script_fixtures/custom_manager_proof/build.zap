## Build manifest for the custom-manager capability-driven-codegen proof.
##
## This project ships TWO custom memory managers — `Custom.BulkArena`
## (declares BULK_OR_NEVER, declared_caps=0x0, identical to Memory.Arena) and
## `Custom.TrackingPool` (declares INDIVIDUAL_NO_REFCOUNT | CLONE_ON_SHARE,
## declared_caps=0x2, identical to Memory.Tracking). Neither is a stdlib
## manager; both names are unknown to the compiler.
##
## The `memory:` field selects the manager per target. `run_custom_manager_proof.sh`
## drives the proof by overriding it with `-Dmemory=Custom.BulkArena` /
## `-Dmemory=Custom.TrackingPool` and asserting that each program gets the
## codegen contract its declared caps imply — purely from the caps bits, with
## no manager-name special-casing anywhere in the compiler.
pub struct Proof.Builder {
  pub fn manifest(env :: Zap.Env) -> Zap.Manifest {
    case env.target {
      :bulk ->
        %Zap.Manifest{
          name: "proof_bulk",
          version: "0.1.0",
          kind: :bin,
          root: &Proof.main/1,
          paths: ["lib/**/*.zap"],
          memory: Custom.BulkArena
        }
      :tracking ->
        %Zap.Manifest{
          name: "proof_tracking",
          version: "0.1.0",
          kind: :bin,
          root: &Proof.main/1,
          paths: ["lib/**/*.zap"],
          memory: Custom.TrackingPool
        }
      _ ->
        panic("Unknown target: use ':bulk' or ':tracking'")
    }
  }
}

## Entry point for the `%Zap.Env` host-vs-target probe project. The
## interesting signal is the project NAME the manifest derives from
## `env.os`/`env.arch` (asserted by the harness from the build output);
## this `main` just needs to produce a runnable binary.
pub struct EnvProbe {
  pub fn main(args :: [String]) -> u8 {
    IO.puts("env-probe ran")
    0
  }
}

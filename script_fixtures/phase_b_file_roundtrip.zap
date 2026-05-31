## Phase B (Domain C file I/O) cross-target roundtrip fixture.
##
## Exercises the migrated `File.*` primitives — which now route through the
## fork's portable `std.Io.Dir`/`std.Io.File` API (posix `*at` syscalls,
## Windows `Nt*File`, WASI preview1 `path_open`/`fd_*`) — end to end:
## `write` a file, confirm `exists?`, `read` it back, print the content,
## then `rm` it and confirm it is gone.
##
## On a foreign target the run proves the per-OS std backend actually works:
##   * wasm32-wasi: built and run under `wasmtime --dir=<dir>` (WASI is
##     capability-based — the host must grant a preopened directory, and
##     `std.Io.Dir.cwd()` resolves to the first preopen). Without the dir
##     grant `path_open` is denied and the roundtrip fails closed.
##   * x86_64-windows-gnu: links as a PE32+; runs under wine where present.
##
## Expected stdout (exactly):
##
##     roundtrip: phase-b file io works
##     exists-before-rm: true
##     exists-after-rm: false

fn main(_args :: [String]) -> u8 {
  path = "_phase_b_roundtrip.txt"
  payload = "roundtrip: phase-b file io works"

  File.write(path, payload)

  content = File.read(path)
  IO.puts(content)

  before = File.exists?(path)
  IO.puts("exists-before-rm: " <> Bool.to_string(before))

  File.rm(path)

  after = File.exists?(path)
  IO.puts("exists-after-rm: " <> Bool.to_string(after))

  0
}

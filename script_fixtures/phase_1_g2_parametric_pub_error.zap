# G2: parametric `pub error` / `pub struct` run in single-file `zap run`
# (script) mode, matching their Zest/test-mode behaviour.
#
# Root cause (round 2): `TypeStore.typeToStructName` had no `.applied`
# arm, so a concrete parametric instantiation `DeserializeError(Atom)`
# (an `.applied{base, args}` TypeId) resolved to `null`. The
# protocol-dispatch satisfaction check
# (`TypeChecker.implTargetForProtocolArgument`) then could not match the
# value against the parametric `impl Error for DeserializeError(t)` whose
# registered impl target is the bare `DeserializeError`, and rejected the
# value with "first argument to protocol `Error` does not satisfy
# `Error`". Resolving `.applied` to its base name closes the type-check
# half of the script-mode divergence; construction + field access then
# lower and run end-to-end exactly as in project/test mode.
#
# Expected output:
#   bad
#   42

pub error DeserializeError(t) {
  got :: t
}

pub struct Box(t) {
  value :: t
}

fn main(_args :: [String]) -> u8 {
  e = %DeserializeError(Atom){got: :bad}
  IO.puts(Atom.to_string(e.got))

  b = %Box(i64){value: 42}
  IO.puts(Kernel.inspect(b.value))
  0
}

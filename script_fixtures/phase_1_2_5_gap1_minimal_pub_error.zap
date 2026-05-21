# Phase 1.2.5 Gap 1 acceptance: minimal `pub error MyError {}`
# construction + `Error.message/1` dispatch via `zap run`.
#
# Until Gap 1 closed, the minimal repro panicked in LLVM bitcode
# emission (`Builder.toBitcode -> getConstantIndex "attempt to use
# null value"`) the moment Sema reached the synthetic `Option_Error`
# union specialization whose `Some` variant payload referenced
# `zap_runtime.ProtocolBox` without an `@import("zap_runtime")` in
# the per-instantiation synthetic source file.
#
# The fix lives in `src/zir_builder.zig`:
# `renderSpecializationSourceFileBody` emits the missing import
# when any variant payload type references the runtime namespace.
# The `src/hir.zig` `appendStructDefaults` companion push-pops the
# field's declared type onto `expected_type_stack` before lowering
# the default expression so `cause :: Option(Error) = Option.None`
# lowers as the right parametric variant construction rather than
# a bare `enum_literal`. The `src/ir.zig`
# `astTypeExprToZigTypeForProtocol` companion mangles parametric
# AST type names (e.g. `Option(Error)` -> `Option_Error`) so
# vtable adapter return types resolve correctly.
#
# Expected output:
#
#     MyError

pub error MyError {}

fn main(_args :: [String]) -> u8 {
  e = %MyError{}
  IO.puts(Error.message(e))
  0
}

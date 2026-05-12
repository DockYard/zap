@memory_manager_source = "src/memory/no_op/manager.zig"

pub struct Zap.Memory.NoOp {
  @structdoc = """
  No-op memory manager. Used as the primary integration test target
  for the external-manager pipeline: allocation fails immediately,
  deallocation does nothing, no capabilities are declared.

  Programs built against this manager terminate as soon as they
  attempt to allocate. The purpose is to validate that the build
  pipeline accepts a minimal manager, that the `.zapmem` section
  round-trips through the section parser, and that capability-
  elision removes all retain/release calls.
  """
}

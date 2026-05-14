pub struct Memory.ManagerTest {
  use Zest.Case

  describe("Memory.Manager adapters") {
    test("ARC exposes refcount metadata from a bare adapter value") {
      adapter = Memory.ARC

      assert(Memory.Manager.name(adapter) == "Memory.ARC")
      assert(Memory.Manager.primitive_source_path(adapter) == "src/memory/arc/manager.zig")
      assert(Memory.Manager.capability_mask(adapter) == 1)
      assert(Memory.Manager.refcount_v1?(adapter))
    }

    test("Arena exposes zero capability metadata from a struct literal") {
      adapter = %Memory.Arena{}

      assert(Memory.Manager.name(adapter) == "Memory.Arena")
      assert(Memory.Manager.primitive_source_path(adapter) == "src/memory/arena/manager.zig")
      assert(Memory.Manager.capability_mask(adapter) == 0)
      reject(Memory.Manager.refcount_v1?(adapter))
    }

    test("diagnostic managers expose primitive source paths") {
      leak = %Memory.Leak{}
      tracking = %Memory.Tracking{}
      no_op = %Memory.NoOp{}

      assert(Memory.Manager.primitive_source_path(leak) == "src/memory/leak/manager.zig")
      assert(Memory.Manager.primitive_source_path(tracking) == "src/memory/tracking/manager.zig")
      assert(Memory.Manager.primitive_source_path(no_op) == "src/memory/no_op/manager.zig")
      reject(Memory.Manager.refcount_v1?(leak))
      reject(Memory.Manager.refcount_v1?(tracking))
      reject(Memory.Manager.refcount_v1?(no_op))
    }
  }
}

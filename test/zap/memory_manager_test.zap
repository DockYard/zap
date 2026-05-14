pub struct Memory.ManagerTest {
  use Zest.Case

  describe("Memory.Manager adapters") {
    test("ARC binds through the single backend primitive from a bare adapter value") {
      adapter = Memory.ARC

      assert(Memory.Manager.backend(adapter))
    }

    test("Arena binds through the single backend primitive from a struct literal") {
      adapter = %Memory.Arena{}

      assert(Memory.Manager.backend(adapter))
    }

    test("diagnostic managers bind through the same backend primitive") {
      leak = %Memory.Leak{}
      tracking = %Memory.Tracking{}
      no_op = %Memory.NoOp{}

      assert(Memory.Manager.backend(leak))
      assert(Memory.Manager.backend(tracking))
      assert(Memory.Manager.backend(no_op))
    }
  }
}

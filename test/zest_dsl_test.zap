pub struct ZestDslTest {
  use Zest.Case

  test("test/case DSL") {
    setup() {
      40
    }

    case("runs the first case with setup context", ctx) {
      assert(ctx + 2 == 42)
    }

    case("runs another case with fresh setup context", ctx) {
      assert(ctx == 40)
      reject(ctx == 41)
    }

    case("runs a case without setup context") {
      assert(true)
    }

    teardown() {
      :ok
    }
  }
}

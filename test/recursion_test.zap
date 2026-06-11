pub struct RecursionTest {
  use Zest.Case

  describe("recursion") {
    test("factorial of 0") {
      assert(factorial(0) == 1)
    }

    test("factorial of 1") {
      assert(factorial(1) == 1)
    }

    test("factorial of 5") {
      assert(factorial(5) == 120)
    }

    test("factorial of 10") {
      assert(factorial(10) == 3628800)
    }

    test("fibonacci of 0") {
      assert(fib(0) == 0)
    }

    test("fibonacci of 1") {
      assert(fib(1) == 1)
    }

    test("fibonacci of 6") {
      assert(fib(6) == 8)
    }

    test("sum of 0") {
      assert(sum(0) == 0)
    }

    test("sum of 5") {
      assert(sum(5) == 15)
    }

    test("tail recursive countdown reaches zero") {
      assert(countdown(10) == 0)
    }
  }

  pub struct LoopState {
    a :: f64
    b :: f64
  }

  describe("byref tail-call loopification") {
    test("recurses 10000 deep without blowing the stack") {
      ## Without IR-level loopification, by-ref state recursion
      ## can't use LLVM `musttail` (rejected for fastcc-bound argument
      ## shapes) and the call uses a real frame per iteration. At a
      ## depth that overflows the 8 MB macOS thread stack the program
      ## segfaults. With loopification the recursion compiles to a
      ## stack-slot loop and runs in bounded stack regardless of
      ## depth.
      s0 = %LoopState{a: 0.0, b: 0.0}
      sN = RecursionTest.byref_step(s0, 10000 :: i64)
      assert(sN.a == 10000.0)
      assert(sN.b == 20000.0)
    }
  }

  pub fn byref_step(s :: LoopState, 0 :: i64) -> LoopState {
    s
  }

  pub fn byref_step(s :: LoopState, n :: i64) -> LoopState {
    next = %LoopState{a: s.a + 1.0, b: s.b + 2.0}
    RecursionTest.byref_step(next, n - 1)
  }

  fn factorial(0 :: i64) -> i64 {
    1
  }

  fn factorial(n :: i64) -> i64 {
    n * factorial(n - 1)
  }

  fn fib(0 :: i64) -> i64 {
    0
  }

  fn fib(1 :: i64) -> i64 {
    1
  }

  fn fib(n :: i64) -> i64 {
    fib(n - 1) + fib(n - 2)
  }

  fn sum(0 :: i64) -> i64 {
    0
  }

  fn sum(n :: i64) -> i64 {
    n + sum(n - 1)
  }

  fn countdown(0 :: i64) -> i64 {
    0
  }

  fn countdown(n :: i64) -> i64 {
    countdown(n - 1)
  }
}

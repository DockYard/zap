pub struct ResultTest {
  use Zest.Case

  describe("Result(t, e) — construction") {
    test("Result(i64, String).Ok(42) constructs without crashing") {
      _ = Result(i64, String).Ok(42)
      assert(true)
    }

    test("Result(i64, String).Error reason constructs without crashing") {
      _ = Result(i64, String).Error("boom")
      assert(true)
    }
  }

  describe("Result — predicates") {
    test("is_ok?/1 returns true for Ok") {
      ok = ResultHelper.ok(42)
      assert(Result.is_ok?(ok) == true)
    }

    test("is_ok?/1 returns false for Error") {
      err = ResultHelper.err("boom")
      assert(Result.is_ok?(err) == false)
    }

    test("is_error?/1 returns true for Error") {
      err = ResultHelper.err("boom")
      assert(Result.is_error?(err) == true)
    }

    test("is_error?/1 returns false for Ok") {
      ok = ResultHelper.ok(42)
      assert(Result.is_error?(ok) == false)
    }
  }

  describe("Result — unwrap_or/2") {
    test("returns the payload of Ok") {
      ok = ResultHelper.ok(42)
      assert(Result.unwrap_or(ok, 0) == 42)
    }

    test("returns the default for Error") {
      err = ResultHelper.err("boom")
      assert(Result.unwrap_or(err, 7) == 7)
    }
  }

  describe("Result(t, e) — case-arm destructuring") {
    test("Result.Ok(v) -> v extracts the i64 payload") {
      assert(ResultHelper.ok_value(ResultHelper.ok(42)) == 42)
    }

    test("Result.Error(reason) -> reason extracts the error payload") {
      assert(ResultHelper.error_reason(ResultHelper.err("boom")) == "boom")
    }
  }

  describe("Result — map/2") {
    test("transforms Ok payload") {
      ok = ResultHelper.ok(2)
      mapped = Result.map(ok, fn(v :: i64) -> i64 { v * v })
      assert(ResultHelper.ok_value(mapped) == 4)
    }

    test("passes Error through unchanged") {
      err = ResultHelper.err("boom")
      mapped = Result.map(err, fn(v :: i64) -> i64 { v + 1 })
      assert(ResultHelper.error_reason(mapped) == "boom")
    }
  }

  describe("Result — map_error/2") {
    test("transforms Error payload") {
      err = ResultHelper.err("boom")
      mapped = Result.map_error(err, fn(e :: String) -> String { e <> "!" })
      assert(ResultHelper.error_reason(mapped) == "boom!")
    }

    test("passes Ok through unchanged") {
      ok = ResultHelper.ok(42)
      mapped = Result.map_error(ok, fn(e :: String) -> String { e <> "!" })
      assert(ResultHelper.ok_value(mapped) == 42)
    }
  }

}

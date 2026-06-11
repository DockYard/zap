pub struct WithTest {
  use Zest.Case

  describe("with") {
    test("all steps match and run the body") {
      assert(result_message(add("ten", "twenty")) == "ok: 30")
    }

    test("first mismatch routes to else clause") {
      assert(result_message(add("nope", "twenty")) == "error: wrapped: not ten")
    }

    test("else-less form returns the non-matching value verbatim") {
      assert(result_message(add_without_else("ten", "nope")) == "error: not twenty")
    }

    test("single-step else-less mismatch yields the value") {
      assert(result_message(run_single("zzz")) == "error: nomatch")
    }

    test("composes parse then validate chain") {
      assert(registration_message(register("30")) == "ok: age 30")
      assert(registration_message(register("200")) == "error: rejected: out of range")
    }
  }

  fn parse_ten(raw :: String) -> Result(i64, String) {
    case raw {
      "ten" -> Result(i64, String).Ok(10)
      _ -> Result(i64, String).Error("not ten")
    }
  }

  fn parse_twenty(raw :: String) -> Result(i64, String) {
    case raw {
      "twenty" -> Result(i64, String).Ok(20)
      _ -> Result(i64, String).Error("not twenty")
    }
  }

  fn add(left :: String, right :: String) -> Result(i64, String) {
    with Result.Ok(x) <- parse_ten(left),
         Result.Ok(y) <- parse_twenty(right) {
      Result(i64, String).Ok(x + y)
    } else {
      Result.Error(reason) -> Result(i64, String).Error("wrapped: " <> reason)
    }
  }

  fn add_without_else(left :: String, right :: String) -> Result(i64, String) {
    with Result.Ok(x) <- parse_ten(left),
         Result.Ok(y) <- parse_twenty(right) {
      Result(i64, String).Ok(x + y)
    }
  }

  fn parse_x(raw :: String) -> Result(i64, String) {
    case raw {
      "x" -> Result(i64, String).Ok(7)
      _ -> Result(i64, String).Error("nomatch")
    }
  }

  fn run_single(raw :: String) -> Result(i64, String) {
    with Result.Ok(value) <- parse_x(raw) {
      Result(i64, String).Ok(value * 100)
    }
  }

  fn parse_age(raw :: String) -> Result(i64, String) {
    case raw {
      "30" -> Result(i64, String).Ok(30)
      "200" -> Result(i64, String).Ok(200)
      _ -> Result(i64, String).Error("not a number")
    }
  }

  fn check_range(age :: i64) -> Result(i64, String) {
    case age < 150 {
      true -> Result(i64, String).Ok(age)
      false -> Result(i64, String).Error("out of range")
    }
  }

  fn register(raw :: String) -> Result(String, String) {
    with Result.Ok(age) <- parse_age(raw),
         Result.Ok(ok_age) <- check_range(age) {
      Result(String, String).Ok("age " <> Integer.to_string(ok_age))
    } else {
      Result.Error(reason) -> Result(String, String).Error("rejected: " <> reason)
    }
  }

  fn result_message(result :: Result(i64, String)) -> String {
    case result {
      Result.Ok(value) -> "ok: " <> Integer.to_string(value)
      Result.Error(reason) -> "error: " <> reason
    }
  }

  fn registration_message(result :: Result(String, String)) -> String {
    case result {
      Result.Ok(value) -> "ok: " <> value
      Result.Error(reason) -> "error: " <> reason
    }
  }
}

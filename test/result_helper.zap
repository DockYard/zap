pub struct ResultHelper {
  pub fn ok(value :: i64) -> Result(i64, String) {
    Result(i64, String).Ok(value)
  }

  pub fn err(reason :: String) -> Result(i64, String) {
    Result(i64, String).Error(reason)
  }

  pub fn ok_value(r :: Result(i64, String)) -> i64 {
    case r {
      Result.Ok(v) -> v
      Result.Error(_) -> 0
    }
  }

  pub fn error_reason(r :: Result(i64, String)) -> String {
    case r {
      Result.Ok(_) -> "no"
      Result.Error(e) -> e
    }
  }
}

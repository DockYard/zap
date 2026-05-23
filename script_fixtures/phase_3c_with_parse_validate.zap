# Phase 3.c: `with` macro composing a real parse-then-validate chain of
# `Result`-returning functions — the canonical Elixir-style use case.
#
# `register/2` sequences three fallible steps with `with`:
#   1. parse the age string into an integer,
#   2. validate the age is in range,
#   3. validate the name is non-empty.
# On the first failing step, the `else` clause turns the error into a
# user-facing message. When all steps pass, the `do` body builds the
# success string.
#
# Two calls: one that succeeds, one whose validation step fails.
#
# Expected output:
#   ok: Ada (30)
#   rejected: age out of range

pub struct Registration {
  pub fn parse_age(raw :: String) -> Result(i64, String) {
    case raw {
      "30" -> Result(i64, String).Ok(30)
      "200" -> Result(i64, String).Ok(200)
      _ -> Result(i64, String).Error("age not a number")
    }
  }

  pub fn check_range(age :: i64) -> Result(i64, String) {
    case age < 150 {
      true -> Result(i64, String).Ok(age)
      false -> Result(i64, String).Error("age out of range")
    }
  }

  pub fn check_name(name :: String) -> Result(String, String) {
    case String.length(name) > 0 {
      true -> Result(String, String).Ok(name)
      false -> Result(String, String).Error("name is empty")
    }
  }

  pub fn register(name :: String, raw_age :: String) -> Result(String, String) {
    with Result.Ok(age) <- parse_age(raw_age),
         Result.Ok(valid_age) <- check_range(age),
         Result.Ok(valid_name) <- check_name(name) {
      Result(String, String).Ok("ok: " <> valid_name <> " (" <> Integer.to_string(valid_age) <> ")")
    } else {
      Result.Error(reason) -> Result(String, String).Error("rejected: " <> reason)
    }
  }
}

fn main(_args :: [String]) -> u8 {
  case Registration.register("Ada", "30") {
    Result.Ok(message) -> IO.puts(message)
    Result.Error(reason) -> IO.puts(reason)
  }
  case Registration.register("Babbage", "200") {
    Result.Ok(message) -> IO.puts(message)
    Result.Error(reason) -> IO.puts(reason)
  }
  0
}

# Case expression with atom matching
#
# Demonstrates case/switch on atom values.

pub struct CaseExpr {
  pub fn describe(x :: i64) -> String {
    case x {
      0 ->
        "zero"
      1 ->
        "one"
      _ ->
        "other"
    }
  }

  pub fn main(_args :: [String]) -> String {
    CaseExpr.describe(0)
    |> IO.puts()

    CaseExpr.describe(1)
    |> IO.puts()

    CaseExpr.describe(42)
    |> IO.puts()
  }
}

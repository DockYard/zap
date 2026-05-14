pub struct PatternMatch {
  pub fn describe(_ :: Atom) -> String {
    "HEY YO!"
  }

  pub fn describe(0) -> String {
    "zero"
  }

  pub fn describe(:ok) -> String {
    "success"
  }

  pub fn describe(:error) -> String {
    "failure"
  }

  pub fn describe(n :: i64) -> String {
    if n > 0 {
      "positive"
    } else {
      "negative"
    }
  }
}

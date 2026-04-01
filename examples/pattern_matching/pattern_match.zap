pub module PatternMatch {
  pub fn describe(_ :: Atom) :: String {
    "HEY YO!"
  }

  pub fn describe(0 :: i64) :: String {
    "zero"
  }

  pub fn describe(:ok :: Atom) :: String {
    "success"
  }

  pub fn describe(:error :: Atom) :: String {
    "failure"
  }

  pub fn describe(n :: i64) :: String {
    if n > 0 {
      "positive"
    } else {
      "negative"
    }
  }
}

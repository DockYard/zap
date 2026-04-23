# String concatenation and function calls

pub struct Http {
  pub fn get(url :: String) -> String {
    "GET " <> url
  }

  pub fn post(url :: String) -> String {
    "POST " <> url
  }
}

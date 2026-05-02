@doc = "Doc generator scaffold."

pub struct Zap.Doc {
  pub fn page_title(name :: String) -> String {
    "<h1 class=\"page-title\">" <> name <> "</h1>\n"
  }
}

pub struct Zap.Manifest {
  name :: String
  version :: String
  kind :: Atom
  root :: String = ""
  asset_name :: String = ""
  optimize :: Atom = :release_safe
  paths :: [String] = []
  deps :: [Zap.Dep] = []
  build_opts :: [{String, String}] = []
  test_timeout :: i64 = 0
  error_style :: String = ""
  multiline_errors :: Bool = false
  source_url :: String = ""
  landing_page :: String = ""
  doc_groups :: [{String, [String]}] = []
}

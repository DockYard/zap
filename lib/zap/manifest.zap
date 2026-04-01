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
}

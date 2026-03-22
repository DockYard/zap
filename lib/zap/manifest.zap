defstruct Manifest do
  name :: String
  version :: String
  kind :: Atom
  root :: String = ""
  asset_name :: String = ""
end

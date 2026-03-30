defstruct Zap.Manifest do
  name :: String
  version :: String
  kind :: Atom
  root :: String = ""
  asset_name :: String = ""
  deps :: List({Atom, {Atom, String}}) = []
end

defstruct Zap.Dep do
  name :: String
  path :: String = ""
  git_url :: String = ""
  git_tag :: String = ""
  git_branch :: String = ""
  git_rev :: String = ""
end

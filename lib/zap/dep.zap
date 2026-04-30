@doc = """
  Dependency declaration used by `Zap.Manifest`.

  A dependency can point to a local path or a Git source with a tag,
  branch, revision, or local override.
  """

pub struct Zap.Dep {
  name :: String
  path :: String = ""
  git_url :: String = ""
  git_tag :: String = ""
  git_branch :: String = ""
  git_rev :: String = ""
  local_override :: String = ""
}

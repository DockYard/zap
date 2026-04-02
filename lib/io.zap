pub module IO {
  pub fn puts(_message :: String) -> String {
    :zig.println(_message)
  }
}

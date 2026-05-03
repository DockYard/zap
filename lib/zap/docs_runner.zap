@doc = """
  Top-level entry point for `zap doc` against Zap's own stdlib.

  `Zap.DocsRunner` reflects on every `.zap` file under `lib/` at
  compile time via `Zap.Doc.Builder`, bakes the manifest data
  needed to render reference pages, and writes the output to
  `docs/` when its `main/1` is invoked. The `zap doc` CLI command
  builds and runs this struct, so the entire doc pipeline lives
  in Zap source — the Zig compiler only handles parsing, macro
  expansion, codegen, and link.

  Downstream user projects define their own equivalent struct in
  their build path and point `:doc` at it via the `root` field of
  their `build.zap` manifest.
  """

pub struct Zap.DocsRunner {
  use Zap.Doc.Builder, paths: ["lib/**/*.zap"]

  @doc = "Render every reflected module to `docs/<name>.html` and write `style.css` + `app.js`."

  pub fn main(_args :: [String]) -> String {
    _ = File.mkdir("docs")
    _count = write_docs_to("docs")
    "Documentation generated in docs/"
  }
}

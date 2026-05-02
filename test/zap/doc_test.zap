pub struct Zap.DocTest {
  use Zest.Case

  describe("Zap.Doc.page_title") {
    test("renders an h1 with the module name") {
      assert(Zap.Doc.page_title("Enum") == "<h1 class=\"page-title\">Enum</h1>\n")
    }
  }
}

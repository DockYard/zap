pub module Test.BinaryPatternTest {
  use Zest.Case

  describe("binary pattern byte extraction") {
    test("extract first byte from AB") {
      assert(first_byte("AB") == 65)
    }

    test("extract first byte from hello") {
      assert(first_byte("hello") == 104)
    }

    test("default case for empty string") {
      assert(first_byte("") == 0)
    }
  }

  describe("binary pattern string rest") {
    test("skip first byte") {
      assert(skip_first("Hello") == "ello")
    }

    test("skip first byte of short string") {
      assert(skip_first("AB") == "B")
    }
  }

  describe("binary pattern string prefix") {
    test("match string prefix") {
      assert(after_prefix("GET /index") == "/index")
      assert(after_prefix("POST /data") == "no match")
    }
  }

  fn first_byte(data :: String) -> i64 {
    case data {
      <<a, _>> -> a
      _ -> 0
    }
  }

  fn skip_first(data :: String) -> String {
    case data {
      <<_, rest::String>> -> rest
      _ -> ""
    }
  }

  fn after_prefix(data :: String) -> String {
    case data {
      <<"GET "::String, path::String>> -> path
      _ -> "no match"
    }
  }
}

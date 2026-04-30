pub struct BinaryPatternTest {
  use Zest.Case

  describe("binary pattern matching") {
    test("extract first byte from AB") {
      assert(first_byte("AB") == 65)
    }

    test("extract first byte from hello") {
      assert(first_byte("hello") == 104)
    }

    test("default case for empty string") {
      assert(first_byte("") == 0)
    }

    test("skip first byte") {
      assert(skip_first("Hello") == "ello")
    }

    test("skip first byte of short string") {
      assert(skip_first("AB") == "B")
    }

    test("match GET prefix") {
      assert(after_prefix("GET /index") == "/index")
    }

    test("no match for POST") {
      assert(after_prefix("POST /data") == "no match")
    }

    test("parse tag name from simple element") {
      assert(parse_tag_name("<foo>Hello</foo>") == "foo")
    }

    test("parse tag name with attributes") {
      assert(parse_tag_name("<foo bar=\"test\">Hello!</foo>") == "foo")
    }

    test("parse text content") {
      assert(parse_content("<foo>Hello!</foo>") == "Hello!")
    }

    test("parse attribute value") {
      assert(parse_attr_value("<foo bar=\"test\">Hello!</foo>") == "test")
    }
  }

  # --- Binary pattern helpers ---

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

  # --- Markup parser ---
  # Uses binary patterns for prefix matching + String functions for scanning

  fn char_at(input :: String, pos :: i64) -> String {
    String.byte_at(input, pos)
  }

  fn parse_tag_name(input :: String) -> String {
    case input {
      <<"<"::String, rest::String>> -> scan_name(rest, 0)
      _ -> ""
    }
  }

  fn scan_name(input :: String, pos :: i64) -> String {
    ch = char_at(input, pos)
    if ch == "" {
      String.slice(input, 0, pos)
    } else {
      if ch == " " {
        String.slice(input, 0, pos)
      } else {
        if ch == ">" {
          String.slice(input, 0, pos)
        } else {
          scan_name(input, pos + 1)
        }
      }
    }
  }

  fn parse_content(input :: String) -> String {
    case input {
      <<"<"::String, rest::String>> -> find_close(rest, 0)
      _ -> ""
    }
  }

  fn find_close(input :: String, pos :: i64) -> String {
    ch = char_at(input, pos)
    if ch == "" {
      ""
    } else {
      if ch == ">" {
        grab_text(input, pos + 1, pos + 1)
      } else {
        find_close(input, pos + 1)
      }
    }
  }

  fn grab_text(input :: String, start :: i64, pos :: i64) -> String {
    ch = char_at(input, pos)
    if ch == "" {
      String.slice(input, start, pos)
    } else {
      if ch == "<" {
        String.slice(input, start, pos)
      } else {
        grab_text(input, start, pos + 1)
      }
    }
  }

  fn parse_attr_value(input :: String) -> String {
    case input {
      <<"<"::String, rest::String>> -> find_eq(rest, 0)
      _ -> ""
    }
  }

  fn find_eq(input :: String, pos :: i64) -> String {
    ch = char_at(input, pos)
    if ch == "" {
      ""
    } else {
      if ch == "=" {
        grab_quoted(input, pos + 2, pos + 2)
      } else {
        if ch == ">" {
          ""
        } else {
          find_eq(input, pos + 1)
        }
      }
    }
  }

  fn grab_quoted(input :: String, start :: i64, pos :: i64) -> String {
    ch = char_at(input, pos)
    if ch == "" {
      ""
    } else {
      if ch == "\"" {
        String.slice(input, start, pos)
      } else {
        grab_quoted(input, start, pos + 1)
      }
    }
  }
}

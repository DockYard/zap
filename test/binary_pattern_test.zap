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

  describe("binary pattern offset advancement") {
    # ir-1--01 / ir-2--02: every segment after the first variable-size
    # segment must read from the correctly-advanced offset. Pre-fix the
    # offset stops advancing once a dynamic segment is seen, so `a` and
    # `b` below alias the same byte (both read the byte right after body).
    test("fixed bytes after a variable-size segment read distinct offsets") {
      # len=2, body="XY", then a=0x41('A'), b=0x42('B')
      assert(after_var("\x02XYAB") == 0x4142)
    }

    test("two fixed bytes after variable segment are not aliased") {
      # len=1, body="Z", a=0x31('1'), b=0x39('9') => distinct
      assert(after_var("\x01Z19") == 0x3139)
    }

    # A second variable-size segment must add its own length too.
    test("second variable-size segment advances past the first") {
      # m=1, first="P", n=2, second="QR", tail="!" (rest)
      assert(two_vars("\x01P\x02QR!") == "!")
    }
  }

  describe("binary pattern zero-length slice") {
    # ir-1--03: an explicit zero-length slice must bind "" (empty), NOT
    # the entire rest of the buffer. Pre-fix length 0 is the "rest"
    # sentinel so body captures everything after the length byte.
    test("size(0) binds an empty slice, not the rest") {
      assert(zero_body("\x00ABC") == "")
    }

    test("zero-length body via length variable binds empty") {
      # len=0 => body is "", rest captures "ABC"
      assert(zero_len_rest("\x00ABC") == "ABC")
    }
  }

  describe("binary pattern match failure") {
    # ir-1--02: a function-head binary clause whose length/prefix check
    # FAILS must fall through to the next clause, never bind zeroed/garbage
    # values. Pre-fix the single-clause path discards the checks and binds
    # zeros, so a too-short / wrong-prefix input still "matches".
    test("too-short input falls through to the catch-all clause") {
      # head needs >= 3 bytes; "A" is too short => fallback clause
      assert(need_three("A") == -1)
    }

    test("sufficient input matches the binary clause") {
      assert(need_three("ABC") == 0x41)
    }

    test("wrong prefix falls through, correct prefix matches") {
      assert(http_method("PUT /x") == "other")
      assert(http_method("GET /x") == "get")
    }
  }

  describe("binary pattern bit then byte-aligned reads") {
    # ir-1--01: float/string reads after a sub-byte segment must flush the
    # pending bit offset to the next byte boundary before reading. Pre-fix
    # only the integer arm flushes, so a String after a u4/u4 byte reads
    # from the wrong (un-flushed) offset.
    test("string after two nibbles reads from the flushed byte boundary") {
      # byte0 = 0x12 => hi nibble 1, lo nibble 2; rest = "ok"
      assert(nibbles_then_rest("\x12ok") == "ok")
    }

    test("sized string after a bit flag reads the correct bytes") {
      # byte0 flags (1 bit used) flushes to byte 1; then 2-byte slice "hi"
      assert(flag_then_str("\x80hi!") == "hi")
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

  # --- Offset-advancement helpers (ir-1--01 / ir-2--02) ---

  # <<len, body::String-size(len), a, b>>: a and b must read distinct
  # bytes immediately after the variable-size body, returning a*256 + b.
  # Pre-fix the offset stops advancing after `body`, so `a` and `b` alias
  # the same byte (both read the byte right after `body`).
  fn after_var(data :: String) -> i64 {
    case data {
      <<len::u8, _body::String-size(len), a::u8, b::u8>> -> a * 256 + b
      _ -> -1
    }
  }

  # Two variable-size segments in sequence, followed by a rest segment.
  # The rest must start AFTER both variable segments.
  fn two_vars(data :: String) -> String {
    case data {
      <<m::u8, _first::String-size(m), n::u8, _second::String-size(n), tail::String>> -> tail
      _ -> "no match"
    }
  }

  # --- Zero-length slice helpers (ir-1--03) ---

  # Explicit size(0): body must be "" regardless of trailing bytes.
  # Pre-fix length 0 is the "rest" sentinel so body captures everything.
  fn zero_body(data :: String) -> String {
    case data {
      <<_pad::u8, body::String-size(0)>> -> body
      _ -> "no match"
    }
  }

  # Variable length 0: body is empty, rest captures everything after.
  fn zero_len_rest(data :: String) -> String {
    case data {
      <<len::u8, _body::String-size(len), rest::String>> -> rest
      _ -> "no match"
    }
  }

  # --- Match-failure helpers (ir-1--02) ---

  # A binary case arm requiring >= 3 bytes. A shorter input must fall
  # through to the `_` arm, not bind a zeroed first byte.
  fn need_three(data :: String) -> i64 {
    case data {
      <<a::u8, _b::u8, _c::u8>> -> a
      _ -> -1
    }
  }

  # Prefix case arm. A non-"GET " input must fall through to `_`.
  fn http_method(data :: String) -> String {
    case data {
      <<"GET "::String, _path::String>> -> "get"
      _ -> "other"
    }
  }

  # --- Bit-flush helpers (ir-1--01) ---

  # Two nibbles consume one byte; the following String must read from
  # byte 1 (the flushed boundary), not from a stale sub-byte offset.
  fn nibbles_then_rest(data :: String) -> String {
    case data {
      <<_hi::u4, _lo::u4, rest::String>> -> rest
      _ -> "no match"
    }
  }

  # A single bit flag occupies byte 0; the sized String must read from
  # byte 1 after the bit offset is flushed.
  fn flag_then_str(data :: String) -> String {
    case data {
      <<_flag::u1, _pad::u7, s::String-size(2)>> -> s
      _ -> "no match"
    }
  }
}

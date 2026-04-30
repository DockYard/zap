pub struct Zap.StringTest {
  use Zest.Case

  describe("String struct") {
    test("string concatenation") {
      assert(("Hello" <> ", " <> "world!") == "Hello, world!")
    }

    test("length returns byte count") {
      assert(String.length("hello") == 5)
    }

    test("length of empty string") {
      assert(String.length("") == 0)
    }

    test("byte_at returns character") {
      assert(String.byte_at("hello", 0) == "h")
    }

    test("byte_at last character") {
      assert(String.byte_at("hello", 4) == "o")
    }

    test("byte_at out of bounds") {
      assert(String.byte_at("hello", 99) == "")
    }

    test("contains finds substring") {
      assert(String.contains?("hello world", "world"))
    }

    test("contains misses substring") {
      reject(String.contains?("hello world", "xyz"))
    }

    test("contains empty needle") {
      assert(String.contains?("hello", ""))
    }

    test("starts_with match") {
      assert(String.starts_with?("hello", "hel"))
    }

    test("starts_with mismatch") {
      reject(String.starts_with?("hello", "world"))
    }

    test("ends_with match") {
      assert(String.ends_with?("hello", "llo"))
    }

    test("ends_with mismatch") {
      reject(String.ends_with?("hello", "world"))
    }

    test("trim whitespace") {
      assert(String.trim("  hello  ") == "hello")
    }

    test("slice substring") {
      assert(String.slice("hello world", 0, 5) == "hello")
    }

    test("slice second word") {
      assert(String.slice("hello world", 6, 11) == "world")
    }

    test("upcase converts lowercase") {
      assert(String.upcase("hello") == "HELLO")
    }

    test("upcase preserves non-alpha") {
      assert(String.upcase("hello 123") == "HELLO 123")
    }

    test("upcase mixed case") {
      assert(String.upcase("Hello World") == "HELLO WORLD")
    }

    test("downcase converts uppercase") {
      assert(String.downcase("HELLO") == "hello")
    }

    test("downcase preserves non-alpha") {
      assert(String.downcase("HELLO 123") == "hello 123")
    }

    test("downcase mixed case") {
      assert(String.downcase("Hello World") == "hello world")
    }

    test("reverse string") {
      assert(String.reverse("hello") == "olleh")
    }

    test("reverse short string") {
      assert(String.reverse("ab") == "ba")
    }

    test("reverse empty string") {
      assert(String.reverse("") == "")
    }

    test("replace single occurrence") {
      assert(String.replace("hello world", "world", "zap") == "hello zap")
    }

    test("replace multiple occurrences") {
      assert(String.replace("aaa", "a", "bb") == "bbbbbb")
    }

    test("replace no match") {
      assert(String.replace("hello", "xyz", "abc") == "hello")
    }

    test("index_of finds substring") {
      assert(String.index_of("hello world", "world") == 6)
    }

    test("index_of not found") {
      assert(String.index_of("hello", "xyz") == -1)
    }

    test("index_of empty needle") {
      assert(String.index_of("hello", "") == 0)
    }

    test("pad_leading adds padding") {
      assert(String.pad_leading("42", 5, "0") == "00042")
    }

    test("pad_leading no padding needed") {
      assert(String.pad_leading("hello", 3, " ") == "hello")
    }

    test("pad_trailing adds padding") {
      assert(String.pad_trailing("hi", 5, ".") == "hi...")
    }

    test("pad_trailing no padding needed") {
      assert(String.pad_trailing("hello", 3, " ") == "hello")
    }

    test("repeat string") {
      assert(String.repeat("ab", 3) == "ababab")
    }

    test("repeat single char") {
      assert(String.repeat("x", 5) == "xxxxx")
    }

    test("repeat zero times") {
      assert(String.repeat("hi", 0) == "")
    }

    test("to_integer valid") {
      assert(String.to_integer("42") == 42)
    }

    test("to_integer invalid") {
      assert(String.to_integer("hello") == 0)
    }

    test("to_float valid") {
      assert(String.to_float("3.14") == 3.14)
    }

    test("to_float invalid") {
      assert(String.to_float("hello") == 0.0)
    }

    # capitalize

    test("capitalize lowercase") {
      assert(String.capitalize("hello") == "Hello")
    }

    test("capitalize uppercase") {
      assert(String.capitalize("HELLO") == "Hello")
    }

    test("capitalize empty") {
      assert(String.capitalize("") == "")
    }

    # trim_leading / trim_trailing

    test("trim_leading removes leading spaces") {
      assert(String.trim_leading("  hello  ") == "hello  ")
    }

    test("trim_trailing removes trailing spaces") {
      assert(String.trim_trailing("  hello  ") == "  hello")
    }

    test("trim_leading no whitespace") {
      assert(String.trim_leading("hello") == "hello")
    }

    test("trim_trailing no whitespace") {
      assert(String.trim_trailing("hello") == "hello")
    }

    # count

    test("count occurrences") {
      assert(String.count("hello world hello", "hello") == 2)
    }

    test("count no match") {
      assert(String.count("hello", "xyz") == 0)
    }

    test("count non-overlapping") {
      assert(String.count("aaa", "aa") == 1)
    }
  }

  describe("String.join") {
    test("join with comma") {
      assert(String.join(["a", "b", "c"], ", ") == "a, b, c")
    }

    test("join single element") {
      assert(String.join(["hello"], "-") == "hello")
    }

    test("join with empty separator") {
      assert(String.join(["a", "b", "c"], "") == "abc")
    }
  }

  describe("String.split") {
    test("split by comma") {
      parts = String.split("a,b,c", ",")
      assert(List.length(parts) == 3)
      assert(List.head(parts) == "a")
      assert(List.last(parts) == "c")
    }

    test("split no delimiter found") {
      parts = String.split("hello", ",")
      assert(List.length(parts) == 1)
      assert(List.head(parts) == "hello")
    }

    test("split by space") {
      parts = String.split("hello world zap", " ")
      assert(List.length(parts) == 3)
      assert(List.head(parts) == "hello")
    }

    test("split empty delimiter returns whole string") {
      parts = String.split("hello", "")
      assert(List.length(parts) == 1)
      assert(List.head(parts) == "hello")
    }

    test("split with trailing delimiter") {
      parts = String.split("a,b,", ",")
      assert(List.length(parts) == 3)
      assert(List.last(parts) == "")
    }
  }

  describe("Interpolation inside compound expressions") {
    test("interpolation inside list literal") {
      name = "world"
      greetings = ["hello #{name}", "bye #{name}"]
      assert(List.head(greetings) == "hello world")
    }

    test("interpolation inside nested list literal") {
      n = 42
      items = [["count: #{n}", "ok"]]
      first = List.head(items)
      assert(List.head(first) == "count: 42")
    }
  }

  describe("Word list sigils") {
    test("~w splits on space") {
      words = ~w"foo bar baz"
      assert(List.length(words) == 3)
      assert(List.head(words) == "foo")
    }

    test("~W splits on space without interpolation") {
      words = ~W"alpha beta"
      assert(List.length(words) == 2)
      assert(List.head(words) == "alpha")
    }
  }
}

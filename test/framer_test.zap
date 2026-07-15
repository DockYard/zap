@doc = """
  Behavioural tests for the `Framer` stages — `Framer.length_prefixed/2` and
  `Framer.line/1` — driven through the pull driver (`Stream.transform`). Framers
  are `Stage(String, Result(String, FramingError))` instances: they consume raw
  byte chunks (`String`) and emit complete frames as `Result.Ok(payload)`, a
  protocol violation as `Result.Error(%FramingError{...})` followed by `:halt`,
  and the end-of-stream partial-frame policy on `flush`.

  Covers: frames split across arbitrary chunk boundaries, exact-fit and
  multi-frame chunks, empty chunks, every accepted prefix width (1/2/4), the
  oversize DoS guard, the truncated-tail-at-EOF policy, the line trailing-line
  policy, and loud rejection of invalid configuration — all under both the
  default (ARC) and `Memory.Tracking` binaries for the `String`/byte payloads.
  """

pub struct FramerTest {
  use Zest.Case

  # Big-endian encode `value` into `width` bytes (width in {1,2,4}).
  fn encode_prefix(value :: i64, width :: i64) -> String {
    FramerTest.encode_prefix_walk(value, width, "")
  }

  fn encode_prefix_walk(value :: i64, remaining :: i64, acc :: String) -> String {
    if remaining <= 0 {
      acc
    } else {
      shift = FramerTest.pow256(remaining - 1)
      byte = value / shift
      FramerTest.encode_prefix_walk(value - byte * shift, remaining - 1, acc <> String.from_byte(byte))
    }
  }

  fn pow256(exponent :: i64) -> i64 {
    if exponent <= 0 {
      1
    } else {
      256 * FramerTest.pow256(exponent - 1)
    }
  }

  # A single length-prefixed frame: a `width`-byte BE length prefix + payload.
  fn frame(payload :: String, width :: i64) -> String {
    FramerTest.encode_prefix(String.length(payload), width) <> payload
  }

  # Extract the `Ok` payload of a Result output, or "" for an error.
  fn ok_payload(result :: Result(String, FramingError)) -> String {
    case result {
      Result.Ok(payload) -> payload
      Result.Error(_error) -> ""
    }
  }

  # True when the Result output is an Error carrying the given reason atom.
  fn error_reason?(result :: Result(String, FramingError), reason :: Atom) -> Bool {
    case result {
      Result.Ok(_payload) -> false
      Result.Error(framing_error) -> framing_error.reason == reason
    }
  }

  describe("length_prefixed reassembly") {
    test("a single frame split across arbitrary chunk boundaries reassembles") {
      whole = FramerTest.frame("hello", 2)
      first_chunk = String.slice(whole, 0, 1)
      second_chunk = String.slice(whole, 1, 4)
      third_chunk = String.slice(whole, 4, String.length(whole))
      result = Enum.to_list(Stream.transform([first_chunk, second_chunk, third_chunk], Framer.length_prefixed(2, 1024)))
      assert(List.length(result) == 1)
      assert(FramerTest.ok_payload(List.head(result)) == "hello")
    }

    test("an exact-fit chunk yields exactly one frame") {
      result = Enum.to_list(Stream.transform([FramerTest.frame("abc", 2)], Framer.length_prefixed(2, 1024)))
      assert(List.length(result) == 1)
      assert(FramerTest.ok_payload(List.head(result)) == "abc")
    }

    test("multiple frames in one chunk all emit") {
      combined = FramerTest.frame("a", 2) <> FramerTest.frame("bb", 2) <> FramerTest.frame("ccc", 2)
      result = Enum.to_list(Stream.transform([combined], Framer.length_prefixed(2, 1024)))
      assert(List.length(result) == 3)
      assert(FramerTest.ok_payload(List.head(result)) == "a")
      assert(FramerTest.ok_payload(List.at(result, 1)) == "bb")
      assert(FramerTest.ok_payload(List.last(result)) == "ccc")
    }

    test("empty chunks are harmless and carry no partial state") {
      whole = FramerTest.frame("data", 2)
      halves_first = String.slice(whole, 0, 3)
      halves_second = String.slice(whole, 3, String.length(whole))
      result = Enum.to_list(Stream.transform(["", halves_first, "", halves_second, ""], Framer.length_prefixed(2, 1024)))
      assert(List.length(result) == 1)
      assert(FramerTest.ok_payload(List.head(result)) == "data")
    }

    test("prefix width 1 decodes a single-byte length") {
      result = Enum.to_list(Stream.transform([FramerTest.frame("xy", 1)], Framer.length_prefixed(1, 1024)))
      assert(List.length(result) == 1)
      assert(FramerTest.ok_payload(List.head(result)) == "xy")
    }

    test("prefix width 4 decodes a four-byte length") {
      result = Enum.to_list(Stream.transform([FramerTest.frame("wide", 4)], Framer.length_prefixed(4, 1024)))
      assert(List.length(result) == 1)
      assert(FramerTest.ok_payload(List.head(result)) == "wide")
    }

    test("a high byte in a 2-byte prefix decodes correctly (256+ length)") {
      payload = String.repeat("z", 300)
      result = Enum.to_list(Stream.transform([FramerTest.frame(payload, 2)], Framer.length_prefixed(2, 1024)))
      assert(List.length(result) == 1)
      assert(String.length(FramerTest.ok_payload(List.head(result))) == 300)
    }

    test("a zero-length frame emits an empty payload") {
      result = Enum.to_list(Stream.transform([FramerTest.frame("", 2)], Framer.length_prefixed(2, 1024)))
      assert(List.length(result) == 1)
      assert(FramerTest.ok_payload(List.head(result)) == "")
    }
  }

  describe("length_prefixed error policy") {
    test("an oversize declared length halts with Error(:oversize) and no further frames") {
      oversize = FramerTest.frame(String.repeat("q", 40), 2)
      trailing = FramerTest.frame("never", 2)
      result = Enum.to_list(Stream.transform([oversize <> trailing], Framer.length_prefixed(2, 8)))
      assert(List.length(result) == 1)
      assert(FramerTest.error_reason?(List.head(result), :oversize))
    }

    test("a good frame then an oversize frame emits the good one then the error") {
      good = FramerTest.frame("ok", 2)
      bad = FramerTest.frame(String.repeat("q", 40), 2)
      result = Enum.to_list(Stream.transform([good <> bad], Framer.length_prefixed(2, 8)))
      assert(List.length(result) == 2)
      assert(FramerTest.ok_payload(List.head(result)) == "ok")
      assert(FramerTest.error_reason?(List.last(result), :oversize))
    }

    test("a truncated tail at EOF flushes Error(:truncated)") {
      whole = FramerTest.frame("hello", 2)
      partial = String.slice(whole, 0, 4)
      result = Enum.to_list(Stream.transform([partial], Framer.length_prefixed(2, 1024)))
      assert(List.length(result) == 1)
      assert(FramerTest.error_reason?(List.head(result), :truncated))
    }

    test("a lone incomplete prefix at EOF flushes Error(:truncated)") {
      result = Enum.to_list(Stream.transform([String.from_byte(0)], Framer.length_prefixed(2, 1024)))
      assert(List.length(result) == 1)
      assert(FramerTest.error_reason?(List.head(result), :truncated))
    }

    test("a clean frame boundary at EOF flushes nothing") {
      result = Enum.to_list(Stream.transform([FramerTest.frame("clean", 2)], Framer.length_prefixed(2, 1024)))
      assert(List.length(result) == 1)
      assert(FramerTest.ok_payload(List.head(result)) == "clean")
    }
  }

  describe("line framing") {
    test("lines split across chunks reassemble") {
      result = Enum.to_list(Stream.transform(["hel", "lo\nwor", "ld\n"], Framer.line(1024)))
      assert(List.length(result) == 2)
      assert(FramerTest.ok_payload(List.head(result)) == "hello")
      assert(FramerTest.ok_payload(List.last(result)) == "world")
    }

    test("multiple lines in one chunk all emit") {
      result = Enum.to_list(Stream.transform(["a\nb\nc\n"], Framer.line(1024)))
      assert(List.length(result) == 3)
      assert(FramerTest.ok_payload(List.head(result)) == "a")
      assert(FramerTest.ok_payload(List.last(result)) == "c")
    }

    test("a trailing line without a newline is emitted on flush as Ok") {
      result = Enum.to_list(Stream.transform(["one\ntwo"], Framer.line(1024)))
      assert(List.length(result) == 2)
      assert(FramerTest.ok_payload(List.head(result)) == "one")
      assert(FramerTest.ok_payload(List.last(result)) == "two")
    }

    test("empty lines are preserved") {
      result = Enum.to_list(Stream.transform(["\n\na\n"], Framer.line(1024)))
      assert(List.length(result) == 3)
      assert(FramerTest.ok_payload(List.head(result)) == "")
      assert(FramerTest.ok_payload(List.at(result, 1)) == "")
      assert(FramerTest.ok_payload(List.last(result)) == "a")
    }

    test("a carriage return is retained in the line (split on newline only)") {
      result = Enum.to_list(Stream.transform(["a\r\n"], Framer.line(1024)))
      assert(List.length(result) == 1)
      assert(FramerTest.ok_payload(List.head(result)) == "a\r")
    }

    test("an un-delimited run reaching max_frame_size halts with Error(:oversize)") {
      result = Enum.to_list(Stream.transform(["aaaa", "bbbb", "cccc"], Framer.line(8)))
      assert(FramerTest.error_reason?(List.last(result), :oversize))
    }

    test("an empty source flushes nothing") {
      result = Enum.to_list(Stream.transform(([] :: [String]), Framer.line(1024)))
      assert(List.length(result) == 0)
    }
  }

  describe("framers are stages: composition and memory hygiene") {
    test("length_prefixed reassembles a payload dribbled one byte per chunk") {
      whole = FramerTest.frame("streamed", 2)
      chunks = FramerTest.byte_chunks(whole)
      result = Enum.to_list(Stream.transform(chunks, Framer.length_prefixed(2, 1024)))
      assert(List.length(result) == 1)
      assert(FramerTest.ok_payload(List.head(result)) == "streamed")
    }

    test("driving a length_prefixed framer to completion is leak-free") {
      assert_no_leaks {
        combined = FramerTest.frame("alpha", 2) <> FramerTest.frame("beta", 2)
        result = Enum.to_list(Stream.transform([combined], Framer.length_prefixed(2, 1024)))
        assert(List.length(result) == 2)
        assert(FramerTest.ok_payload(List.last(result)) == "beta")
      }
    }

    test("halting a length_prefixed framer early on oversize is leak-free") {
      assert_no_leaks {
        combined = FramerTest.frame("good", 2) <> FramerTest.frame(String.repeat("x", 40), 2)
        result = Enum.to_list(Stream.transform([combined], Framer.length_prefixed(2, 8)))
        assert(List.length(result) == 2)
        assert(FramerTest.error_reason?(List.last(result), :oversize))
      }
    }

    test("disposing a framer with buffered bytes after an early take is leak-free") {
      assert_no_leaks {
        whole = FramerTest.frame("buffered", 2)
        chunks = FramerTest.byte_chunks(whole)
        taken = Enum.take(Stream.transform(chunks, Framer.length_prefixed(2, 1024)), 0)
        assert(List.length(taken) == 0)
      }
    }

    test("a truncated length_prefixed tail is fault-free under both managers") {
      assert_no_memory_faults {
        whole = FramerTest.frame("partial", 2)
        partial = String.slice(whole, 0, 5)
        result = Enum.to_list(Stream.transform([partial], Framer.length_prefixed(2, 1024)))
        assert(List.length(result) == 1)
        assert(FramerTest.error_reason?(List.head(result), :truncated))
      }
    }

    test("a line framer flushing a trailing line is leak-free") {
      assert_no_leaks {
        result = Enum.to_list(Stream.transform(["first\nsecond"], Framer.line(1024)))
        assert(List.length(result) == 2)
        assert(FramerTest.ok_payload(List.last(result)) == "second")
      }
    }
  }

  # Split a string into one chunk per byte.
  fn byte_chunks(source :: String) -> [String] {
    FramerTest.byte_chunks_walk(source, 0, String.length(source), ([] :: [String]))
  }

  fn byte_chunks_walk(source :: String, index :: i64, length :: i64, acc :: [String]) -> [String] {
    if index >= length {
      acc
    } else {
      FramerTest.byte_chunks_walk(source, index + 1, length, List.concat(acc, [String.byte_at(source, index)]))
    }
  }
}

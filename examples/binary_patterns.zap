# Markup Parser — binary pattern matching with recursion
#
# Parses a subset of HTML/XML markup into a string representation
# of a tree structure using binary prefix matching and recursive descent.
#
# Input:  <div id=top><h1>Hello, Zap!</h1></div>
# Output: {"div", {"id", "top"}, [{"h1", {}, "Hello, Zap!"}]}

defmodule MarkupParser do
  # ── Tag name extraction ────────────────────────────────────
  #
  # Collects characters until space (attrs follow) or > (tag ends).
  # Uses multi-clause binary prefix dispatch.

  def take_tag(<<">"::String, _rest::String>>) :: String do
    ""
  end

  def take_tag(<<" "::String, _rest::String>>) :: String do
    ""
  end

  def take_tag(<<ch::String-size(1), rest::String>>) :: String do
    ch <> take_tag(rest)
  end

  def take_tag(_) :: String do
    ""
  end

  # ── Skip to content after '>' ──────────────────────────────

  def after_gt(<<">"::String, rest::String>>) :: String do
    rest
  end

  def after_gt(<<_ch::String-size(1), rest::String>>) :: String do
    after_gt(rest)
  end

  def after_gt(_) :: String do
    ""
  end

  # ── Text extraction (stops at '<') ─────────────────────────

  def take_text(<<"<"::String, _rest::String>>) :: String do
    ""
  end

  def take_text(<<ch::String-size(1), rest::String>>) :: String do
    ch <> take_text(rest)
  end

  def take_text(_) :: String do
    ""
  end

  # ── Attribute parsing ──────────────────────────────────────
  #
  # Scans past the tag name, then extracts key=value pairs.
  # Uses unquoted attribute values for simplicity (key=value).

  def take_until_eq(<<"="::String, _rest::String>>) :: String do
    ""
  end

  def take_until_eq(<<ch::String-size(1), rest::String>>) :: String do
    ch <> take_until_eq(rest)
  end

  def take_until_eq(_) :: String do
    ""
  end

  def take_val(<<">"::String, _rest::String>>) :: String do
    ""
  end

  def take_val(<<" "::String, _rest::String>>) :: String do
    ""
  end

  def take_val(<<ch::String-size(1), rest::String>>) :: String do
    ch <> take_val(rest)
  end

  def take_val(_) :: String do
    ""
  end

  def after_eq(<<"="::String, rest::String>>) :: String do
    rest
  end

  def after_eq(<<_ch::String-size(1), rest::String>>) :: String do
    after_eq(rest)
  end

  def after_eq(_) :: String do
    ""
  end

  # parse_attrs: dispatches on what follows the tag name

  def parse_attrs(<<">"::String, _rest::String>>) :: String do
    "{}"
  end

  def parse_attrs(<<" "::String, rest::String>>) :: String do
    "{\"" <> take_until_eq(rest) <> "\", \"" <> take_val(after_eq(rest)) <> "\"}"
  end

  def parse_attrs(<<_ch::String-size(1), rest::String>>) :: String do
    parse_attrs(rest)
  end

  def parse_attrs(_) :: String do
    "{}"
  end

  # ── Recursive descent parser ───────────────────────────────
  #
  # parse(input) — entry point, dispatches on first bytes:
  #   <<"</"::String, ...>> → closing tag, stop recursion
  #   <<"<"::String, ...>>  → opening tag, build element node
  #   other                 → empty (shouldn't happen at top level)
  #
  # parse_children(input) — after '>', inspects what follows:
  #   <<"</"::String, ...>> → no children (closing tag next)
  #   <<"<"::String, ...>>  → nested child element (recurse)
  #   text content          → collect text until '<'

  def parse(<<"</"::String, _rest::String>>) :: String do
    ""
  end

  def parse(<<"<"::String, rest::String>>) :: String do
    "{\"" <> take_tag(rest) <> "\", " <> parse_attrs(rest) <> ", " <> parse_children(after_gt(rest)) <> "}"
  end

  def parse(_) :: String do
    ""
  end

  def parse_children(<<"</"::String, _rest::String>>) :: String do
    "\"\""
  end

  def parse_children(<<"<"::String, rest::String>>) :: String do
    "[{\"" <> take_tag(rest) <> "\", " <> parse_attrs(rest) <> ", " <> parse_children(after_gt(rest)) <> "}]"
  end

  def parse_children(input) :: String do
    "\"" <> take_text(input) <> "\""
  end
end

def main() do
  IO.puts("Input:  <div id=top><h1>Hello, Zap!</h1></div>")
  IO.puts("Output:")

  MarkupParser.parse("<div id=top><h1>Hello, Zap!</h1></div>")
  |> IO.puts()
end

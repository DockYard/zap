# Markup Parser — binary pattern matching with recursion
#
# Parses a subset of HTML/XML markup into actual data structures
# using binary prefix matching and recursive descent.
#
# Input:  <div id=top><h1>Hello, Zap!</h1></div>
# Output: {"div", {"id", "top"}, {"h1", {"", ""}, "Hello, Zap!"}}

defmodule MarkupParser do
  # ── Tag name extraction ────────────────────────────────────
  #
  # Collects characters until space (attrs follow) or > (tag ends).

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
  # Scans past the tag name looking for ' key=value'.
  # Returns {key, value} as a tuple of strings.

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

  def parse_attr(<<">"::String, _rest::String>>) :: {String, String} do
    {"", ""}
  end

  def parse_attr(<<" "::String, rest::String>>) :: {String, String} do
    {take_until_eq(rest), take_val(after_eq(rest))}
  end

  def parse_attr(<<_ch::String-size(1), rest::String>>) :: {String, String} do
    parse_attr(rest)
  end

  def parse_attr(_) :: {String, String} do
    {"", ""}
  end

  # ── Recursive descent parser ───────────────────────────────
  #
  # parse_leaf: parses <tag>text</tag> into {tag, attrs, text}
  # parse_node: parses <tag><child>...</child></tag> into {tag, attrs, child}
  #
  # Binary prefix matching dispatches on '<' to enter tag parsing.
  # Recursion occurs when parse_node calls parse_leaf for the child.

  def parse_leaf(<<"<"::String, rest::String>>) :: {String, {String, String}, String} do
    {take_tag(rest), parse_attr(rest), take_text(after_gt(rest))}
  end

  def parse_leaf(_) :: {String, {String, String}, String} do
    {"", {"", ""}, ""}
  end

  def parse_node(<<"<"::String, rest::String>>) :: {String, {String, String}, {String, {String, String}, String}} do
    {take_tag(rest), parse_attr(rest), parse_leaf(after_gt(rest))}
  end

  def parse_node(_) :: {String, {String, String}, {String, {String, String}, String}} do
    {"", {"", ""}, {"", {"", ""}, ""}}
  end
end

def main() do
  [MarkupParser.parse_node("<div id=top><h1>Hello, Zap!</h1></div>")]
  |> Kernel.inspect()
end

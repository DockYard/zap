@doc = """
  Zap-side documentation generator. Renders module reference pages
  from reflection results into HTML strings. Built up from small,
  individually-testable functions; each returns a `String` so it can
  be tested with plain string equality against the existing
  reference HTML.
  """

pub struct Zap.Doc {
  @doc = "Render the page title — the `<h1 class=\"page-title\">` element."
  pub fn page_title(name :: String) -> String {
    "<h1 class=\"page-title\">" <> escape_html(name) <> "</h1>\n"
  }

  @doc = """
    Render the breadcrumb above a module title. The first segment is
    the kind category label (`Structs`, `Protocols`, `Unions`); the
    second is the module's qualified name.
    """
  pub fn breadcrumb(kind :: Atom, name :: String) -> String {
    open_tag = "<nav class=\"breadcrumb\" aria-label=\"Breadcrumb\">\n"
    category = "<span>" <> kind_category_label(kind) <> "</span>\n"
    separator = "<span>/</span>\n"
    current = "<span class=\"breadcrumb-current\">" <> escape_html(name) <> "</span>\n"
    open_tag <> category <> separator <> current <> "</nav>\n"
  }

  @doc = "Map a kind atom to its sidebar group label."
  pub fn kind_category_label(kind :: Atom) -> String {
    if kind == :struct {
      "Structs"
    } else {
      kind_category_label_protocol(kind)
    }
  }

  pub fn kind_category_label_protocol(kind :: Atom) -> String {
    if kind == :protocol {
      "Protocols"
    } else {
      kind_category_label_union(kind)
    }
  }

  pub fn kind_category_label_union(kind :: Atom) -> String {
    if kind == :union {
      "Unions"
    } else {
      "Declarations"
    }
  }

  @doc = """
    Render an italic-serif tagline below the title from the first
    sentence of a module's `@doc` body. Empty input renders nothing
    so the caller can splice unconditionally.
    """
  pub fn tagline(text :: String) -> String {
    if String.length(text) == 0 {
      ""
    } else {
      "<p class=\"tagline\">" <> escape_html(text) <> "</p>\n"
    }
  }

  @doc = """
    Render the "Implements" row when a type satisfies one or more
    protocols. Each protocol becomes an accent-bordered link pill
    pointing at its reference page. Returns the empty string for an
    empty list so the caller can splice unconditionally.
    """
  @doc = """
    Render one accent-bordered "Implements" link pill for a single
    protocol. The eventual `implements_row/1` builder will fold over
    a list of protocol names, splicing each link into the row body —
    parked while a list-element type-inference snag in the recursive
    fold path is sorted out in a follow-up commit.
    """
  pub fn implements_link(name :: String) -> String {
    safe = escape_html(name)
    "<a class=\"implements-link\" href=\"../structs/" <> safe <> ".html\">" <> safe <> "</a>\n"
  }

  pub fn escape_html(text :: String) -> String {
    escape_chars(text, 0, String.length(text), "")
  }

  pub fn escape_chars(text :: String, index :: i64, end_index :: i64, acc :: String) -> String {
    if index >= end_index {
      acc
    } else {
      escape_chars(text, index + 1, end_index, acc <> escape_one(String.byte_at(text, index)))
    }
  }

  pub fn escape_one(ch :: String) -> String {
    if ch == "&" {
      "&amp;"
    } else {
      escape_one_lt(ch)
    }
  }

  pub fn escape_one_lt(ch :: String) -> String {
    if ch == "<" {
      "&lt;"
    } else {
      escape_one_gt(ch)
    }
  }

  pub fn escape_one_gt(ch :: String) -> String {
    if ch == ">" {
      "&gt;"
    } else {
      escape_one_quote(ch)
    }
  }

  pub fn escape_one_quote(ch :: String) -> String {
    if ch == "\"" {
      "&quot;"
    } else {
      ch
    }
  }
}

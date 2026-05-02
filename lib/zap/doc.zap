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
  @doc = """
    Build the anchor id for a function or macro entry. The convention is
    `<name>-<arity>`; the renderer uses this both for the `id="..."`
    attribute on a function detail block and for the `href="#..."` of
    in-page links (right rail, summary table, "see also" rows).
    """
  pub fn anchor_id(name :: String, arity :: i64) -> String {
    name <> "-" <> Integer.to_string(arity)
  }

  @doc = """
    Render the header row at the top of a function or macro detail
    block: an `<h3>` with the qualified name and a muted `/arity`
    span, a small kind badge (`fn` for functions, `macro` for
    macros), a flex-spacer, and a `#`-prefixed anchor link that
    deep-links back to this entry.
    """
  @doc = """
    Render a single row in the per-struct summary table — name+arity
    cell on the left, doc-summary cell on the right. The first sentence
    of the function's `@doc` is its summary; passing the empty string
    for `summary` produces an empty doc cell, matching the doc
    generator's behavior for undocumented functions.
    """
  pub fn summary_row(name :: String, arity :: i64, summary :: String) -> String {
    anchor = anchor_id(name, arity)
    name_cell = "<tr><td class=\"summary-name\"><a href=\"#" <> anchor <> "\">" <> escape_html(name) <> "/" <> Integer.to_string(arity) <> "</a></td>"
    doc_cell = "<td class=\"summary-doc\">" <> escape_html(summary) <> "</td></tr>\n"
    name_cell <> doc_cell
  }

  @doc = """
    Render a single signature block — the bordered code panel that
    holds the typed call form (`name(p :: T, ...) -> R [if guard]`).
    Signature strings are produced by `Struct.functions/1` reflection;
    this function wraps them in the panel without further parsing,
    matching the in-tree Zig generator's plain `<code>` rendering for
    signatures the rich pill renderer can't parse.
    """
  pub fn signature_block(signature :: String) -> String {
    "<div class=\"signature\"><code>" <> escape_html(signature) <> "</code></div>\n"
  }

  @doc = """
    Render a complete per-function detail block — the section that
    appears under "Function Details" on each module page. Composes
    the header, all clause signatures, and the doc body (already
    rendered to HTML by `Markdown.to_html/1`).

    `signatures` is a list of pre-rendered Zap-syntax signature
    strings, one per clause (multi-clause functions get multiple
    panels stacked). `doc_html` is the markdown-rendered prose;
    callers pass `Markdown.to_html(func.doc)`.
    """
  @doc = """
    Render one `<li>` row in a sidebar group's struct list. The active
    module gets `class="active"` so CSS can highlight its row with the
    accent left-border + accent-soft fill from the design tokens.
    """
  pub fn sidebar_item(name :: String, active? :: Bool, base :: String) -> String {
    li_open = if active? { "<li class=\"active\">" } else { "<li>" }
    li_open <> "<a href=\"" <> base <> "structs/" <> escape_html(name) <> ".html\">" <> escape_html(name) <> "</a></li>\n"
  }

  @doc = """
    Render one collapsible sidebar group — the chevron-button header
    plus the `<ul>` of struct items. `members` is the list of member
    qualified names, `current` is the active page's name (use the
    empty string when no module is active, e.g. on the landing page).
    `base` is the relative path prefix (`""` from the landing page,
    `"../"` from a struct page).
    """
  pub fn sidebar_group(title :: String, members :: [String], current :: String, base :: String) -> String {
    items = render_sidebar_items(members, current, base, "")
    open_div = "<div class=\"sidebar-group\" data-group=\"" <> escape_html(title) <> "\">\n"
    button = "<button class=\"sidebar-group-header\" type=\"button\" aria-label=\"Toggle group\"><span class=\"chevron\" aria-hidden=\"true\">\u{25b8}</span><h4>" <> escape_html(title) <> "</h4></button>\n"
    open_div <> button <> "<ul>\n" <> items <> "</ul>\n</div>\n"
  }

  pub fn render_sidebar_items(members :: [String], current :: String, base :: String, acc :: String) -> String {
    if List.empty?(members) {
      acc
    } else {
      head = List.head(members)
      tail = List.tail(members)
      render_sidebar_items(tail, current, base, acc <> sidebar_item(head, head == current, base))
    }
  }

  pub fn function_detail(name :: String, arity :: i64, is_macro :: Bool, signatures :: [String], doc_html :: String) -> String {
    sig_blocks = for sig <- signatures {
      signature_block(sig)
    }
    sigs = String.join(sig_blocks, "")
    open_div = "<div class=\"function-detail\" id=\"" <> anchor_id(name, arity) <> "\">\n"
    header = function_header(name, arity, is_macro)
    body = if String.length(doc_html) == 0 {
      ""
    } else {
      "<div class=\"function-doc\">\n" <> doc_html <> "</div>\n"
    }
    open_div <> header <> sigs <> body <> "</div>\n"
  }

  pub fn function_header(name :: String, arity :: i64, is_macro :: Bool) -> String {
    badge = if is_macro { "macro" } else { "fn" }
    anchor = anchor_id(name, arity)
    open_div = "<div class=\"function-header\">\n"
    h3 = "<h3>" <> escape_html(name) <> "<span class=\"arity\">/" <> Integer.to_string(arity) <> "</span></h3>\n"
    badge_span = "<span class=\"badge\">" <> badge <> "</span>\n"
    spacer = "<div style=\"flex:1\"></div>\n"
    anchor_link = "<a href=\"#" <> anchor <> "\" class=\"anchor-link\">#</a>\n"
    open_div <> h3 <> badge_span <> spacer <> anchor_link <> "</div>\n"
  }

  pub fn implements_link(name :: String) -> String {
    safe = escape_html(name)
    "<a class=\"implements-link\" href=\"../structs/" <> safe <> ".html\">" <> safe <> "</a>\n"
  }

  @doc = """
    Render the "Implements" row when a type satisfies one or more
    protocols. Each protocol becomes an accent-bordered link pill
    pointing at its reference page. Returns the empty string for an
    empty list so the caller can splice unconditionally.

    Implementation note: builds the body via a `for` comprehension
    that produces `[String]`, then folds with `Enum.reduce` to a
    single string. The recursive multi-clause form
    (`render_links([] :: [String]) | [head|tail]`) currently provokes
    a closure-codegen issue elsewhere in the test suite — the
    comprehension path avoids it.
    """
  pub fn implements_row(protocols :: [String]) -> String {
    if List.empty?(protocols) {
      ""
    } else {
      links_list = for name <- protocols {
        implements_link(name)
      }
      links = String.join(links_list, "")
      "<div class=\"implements\">\n<span class=\"implements-label\">Implements</span>\n" <> links <> "</div>\n"
    }
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

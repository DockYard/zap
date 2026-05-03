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

  @doc = """
    Wrap a sequence of pre-rendered summary rows in the
    `<h2>` + `<table class="summary">` shell. Returns the empty
    string for an empty body so callers can splice unconditionally.
    """
  pub fn summary_table(heading :: String, anchor :: String, rows :: String) -> String {
    if String.length(rows) == 0 {
      ""
    } else {
      "<h2 id=\"" <> anchor <> "\">" <> escape_html(heading) <> "</h2>\n<table class=\"summary\">\n" <> rows <> "</table>\n"
    }
  }

  @doc = """
    Wrap a sequence of pre-rendered function detail blocks under a
    `<h2>` heading (`Function Details` / `Macro Details`). Returns
    the empty string for an empty body.
    """
  pub fn function_details_section(heading :: String, blocks :: String) -> String {
    if String.length(blocks) == 0 {
      ""
    } else {
      "<h2>" <> escape_html(heading) <> "</h2>\n" <> blocks
    }
  }

  @doc = """
    Render a single anchor in the right-rail "On this page" list. Each
    item is a `name/arity` link styled with a left-bordered tick that
    highlights the active section as the page scrolls.
    """
  pub fn toc_item(name :: String, arity :: i64) -> String {
    anchor = anchor_id(name, arity)
    "<li><a href=\"#" <> anchor <> "\">" <> escape_html(name) <> "/" <> Integer.to_string(arity) <> "</a></li>\n"
  }

  @doc = """
    Wrap pre-rendered TOC items in the right-rail aside, returning the
    empty string when the page has no anchorable entries (data-only
    structs like `Range`). Section labels (`Functions`, `Macros`) are
    handled by the caller stitching `<li class="toc-section">...</li>`
    into the items body.
    """
  pub fn right_rail(items :: String) -> String {
    if String.length(items) == 0 {
      ""
    } else {
      "<aside class=\"toc\">\n<h3>On This Page</h3>\n<ul>\n" <> items <> "</ul>\n</aside>\n"
    }
  }

  @doc = """
    Build the `<li class="toc-section">Label</li>` divider used inside
    the right-rail to group items under "Functions" and "Macros"
    headings.
    """
  pub fn toc_section_label(text :: String) -> String {
    "<li class=\"toc-section\">" <> escape_html(text) <> "</li>\n"
  }

  @doc = """
    Render the sticky top-bar — brand cluster on the left, command-K
    search trigger in the center, theme toggle + GitHub link cluster
    on the right. Same markup the existing Zig generator emits so the
    in-page JS (theme toggle, palette) keeps working unchanged.

    `project_name` and `version` populate the brand text. `base` is
    the path prefix from the current page back to the docs root
    (`""` from index.html, `"../"` from a struct page). `source_url`
    is the GitHub repo URL for the project — pass empty string to
    omit the GitHub icon.
    """
  pub fn topbar(project_name :: String, version :: String, base :: String, source_url :: String) -> String {
    open = "<header class=\"topbar\">\n"
    left = topbar_left(project_name, version, base)
    center = topbar_center()
    right = topbar_right(source_url)
    open <> left <> center <> right <> "</header>\n"
  }

  pub fn topbar_left(project_name :: String, version :: String, base :: String) -> String {
    z_mark = "<svg class=\"zap-mark\" width=\"22\" height=\"22\" viewBox=\"0 0 22 22\" fill=\"none\">\n<rect x=\"0.5\" y=\"0.5\" width=\"21\" height=\"21\" rx=\"3\" stroke=\"var(--border-strong)\"/>\n<path d=\"M6 6 L15 6 L8 13 L16 13 L16 16 L6 16 L13 9 L6 9 Z\" fill=\"var(--accent)\"/>\n</svg>\n"
    title = "<a href=\"" <> base <> "index.html\" class=\"topbar-title\">" <> escape_html(project_name) <> "</a>\n"
    version_pill = "<span class=\"topbar-version\">v" <> escape_html(version) <> "</span>\n"
    docs_label = "<span class=\"docs-label\">docs</span>\n"
    "<div class=\"topbar-left\">\n" <> z_mark <> title <> version_pill <> docs_label <> "</div>\n"
  }

  pub fn topbar_center() -> String {
    icon = "<svg width=\"14\" height=\"14\" viewBox=\"0 0 16 16\" fill=\"none\">\n<circle cx=\"7\" cy=\"7\" r=\"5\" stroke=\"var(--fg-muted)\" stroke-width=\"1.3\"/>\n<line x1=\"10.6\" y1=\"10.6\" x2=\"14\" y2=\"14\" stroke=\"var(--fg-muted)\" stroke-width=\"1.3\" stroke-linecap=\"round\"/>\n</svg>\n"
    label = "<span>Search structs, functions, guides...</span>\n"
    kbd = "<kbd>\u{2318}</kbd><kbd>K</kbd>\n"
    button = "<button class=\"topbar-search-trigger\" id=\"search-trigger\">\n" <> icon <> label <> kbd <> "</button>\n"
    "<div class=\"topbar-center\">\n" <> button <> "</div>\n"
  }

  pub fn topbar_right(source_url :: String) -> String {
    theme = "<button id=\"theme-toggle\" aria-label=\"Toggle dark mode\" title=\"Toggle dark mode\">\n<span class=\"theme-icon-light\">\u{2600}</span>\n<span class=\"theme-icon-dark\">\u{263e}</span>\n</button>\n"
    divider = "<div class=\"topbar-divider\"></div>\n"
    github = if String.length(source_url) == 0 {
      ""
    } else {
      gh_icon = "<svg width=\"18\" height=\"18\" viewBox=\"0 0 16 16\" fill=\"currentColor\">\n<path d=\"M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z\"/>\n</svg>\n"
      "<a href=\"" <> escape_html(source_url) <> "\" class=\"topbar-github\" aria-label=\"GitHub repository\" title=\"GitHub\">\n" <> gh_icon <> "</a>\n"
    }
    "<div class=\"topbar-right\">\n" <> theme <> divider <> github <> "</div>\n"
  }

  @doc = """
    Open the HTML document — `<!DOCTYPE>`, `<html>`, `<head>` (CSS
    link, title, base-path meta), and `<body>`. Matches the existing
    Zig generator's wrapper exactly so the in-page JS (which reads
    `meta[name=\"zap-docs-base\"]`) continues to work.
    """
  pub fn page_open(title :: String, project_name :: String, base :: String) -> String {
    head_open = "<!DOCTYPE html>\n<html lang=\"en\" data-theme=\"dark\">\n<head>\n"
    meta = "<meta charset=\"UTF-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">\n"
    title_tag = "<title>" <> escape_html(title) <> " \u{2014} " <> escape_html(project_name) <> "</title>\n"
    css = "<link rel=\"stylesheet\" href=\"" <> base <> "style.css\">\n"
    base_meta = "<meta name=\"zap-docs-base\" content=\"" <> base <> "\">\n"
    head_open <> meta <> title_tag <> css <> base_meta <> "</head>\n<body>\n"
  }

  @doc = """
    Close the document — search modal, `app.js` script tag, `</body>`,
    `</html>`. Mirrors the existing Zig generator's footer so the
    in-page palette + theme toggle pick up the right asset paths.
    """
  pub fn page_close(base :: String) -> String {
    modal = search_modal()
    script = "<script src=\"" <> base <> "app.js\"></script>\n"
    modal <> script <> "</body>\n</html>\n"
  }

  @doc = """
    Render the entire left sidebar — three potential groups
    (`Structs`, `Protocols`, `Unions`), each only emitted when its
    members list is non-empty. `current` is the active module's name
    (`""` from non-module pages); `base` is the path prefix to the
    docs root.
    """
  @doc = """
    Wrap the page chrome around a fully-composed main column. The
    layout is a CSS grid with `<nav class="sidebar">` on the left,
    `<main class="content">` in the middle, and an optional
    `<aside class="toc">` (the right rail) on the right. When the
    page has no anchorable entries, pass `""` for the rail and the
    `layout-no-toc` modifier collapses the grid to two columns so
    the content fills the freed space.
    """
  @doc = """
    Compose the main column of a module's reference page from its
    pre-rendered child strings:

    - `kind` and `name` drive the breadcrumb and `<h1>` title.
    - `implements` is the list of protocol names this type satisfies.
    - `tagline_text` is the first sentence of the module's `@doc`
      attribute (already extracted by the caller).
    - `structdoc_html` is the markdown-rendered prose.
    - `functions_rows` / `macros_rows` are pre-rendered summary
      table rows; pass `""` to suppress the section.
    - `functions_details` / `macros_details` are pre-rendered
      function detail blocks; pass `""` to suppress.
    """
  pub fn module_main_content(kind :: Atom, name :: String, implements :: [String], tagline_text :: String, structdoc_html :: String, functions_rows :: String, macros_rows :: String, functions_details :: String, macros_details :: String) -> String {
    head = breadcrumb(kind, name) <> page_title(name) <> implements_row(implements) <> tagline(tagline_text)
    structdoc = if String.length(structdoc_html) == 0 {
      ""
    } else {
      "<div class=\"structdoc\">\n" <> structdoc_html <> "</div>\n"
    }
    summaries = summary_table("Functions", "functions", functions_rows) <> summary_table("Macros", "macros", macros_rows)
    details = function_details_section("Function Details", functions_details) <> function_details_section("Macro Details", macros_details)
    head <> structdoc <> summaries <> details
  }

  @doc = """
    Compose a complete struct/protocol/union reference page from its
    parts. Wraps the chrome (`page_open`, `topbar`, `layout`,
    `page_close`) around a pre-rendered sidebar HTML, main content,
    and optional right-rail HTML.

    `title` populates the `<title>` element; pass the module's name.
    `base` is the path prefix from this page to the docs root
    (`"../"` from a struct page, `""` from the index).
    `source_url` is the GitHub repo URL (`""` to omit the GH icon).
    """
  @doc = """
    Render summary table rows from a list of `{name, arity, summary}`
    triples. Used by the runtime walker to build the body of a
    summary table from reflection results.
    """
  pub fn render_summary_rows(items :: [{String, i64, String}], acc :: String) -> String {
    if List.empty?(items) {
      acc
    } else {
      head = List.head(items)
      tail = List.tail(items)
      case head {
        {name, arity, summary} -> render_summary_rows(tail, acc <> summary_row(name, arity, summary))
      }
    }
  }

  @doc = """
    Extract the first sentence of a doc body for the summary table
    cell. Splits on the first `.` (followed by whitespace or end of
    string), or returns the whole text when no period is found —
    matching the in-tree Zig `extractFirstSentence` heuristic.
    """
  pub fn first_sentence(text :: String) -> String {
    if String.length(text) == 0 {
      ""
    } else {
      first_sentence_walk(text, 0, String.length(text))
    }
  }

  pub fn first_sentence_walk(text :: String, index :: i64, end :: i64) -> String {
    if index >= end {
      text
    } else {
      ch = String.byte_at(text, index)
      if ch == "." {
        # End of sentence if next char is whitespace or end.
        if index + 1 >= end {
          String.slice(text, 0, index + 1)
        } else {
          next_ch = String.byte_at(text, index + 1)
          if next_ch == " " or next_ch == "\n" or next_ch == "\t" {
            String.slice(text, 0, index + 1)
          } else {
            first_sentence_walk(text, index + 1, end)
          }
        }
      } else {
        first_sentence_walk(text, index + 1, end)
      }
    }
  }

  pub fn struct_page(project_name :: String, project_version :: String, title :: String, base :: String, source_url :: String, sidebar_html :: String, content_html :: String, rail_html :: String) -> String {
    head = page_open(title, project_name, base)
    bar = topbar(project_name, project_version, base, source_url)
    body = layout(sidebar_html, content_html, rail_html)
    tail = page_close(base)
    head <> bar <> body <> tail
  }

  pub fn layout(sidebar_html :: String, content_html :: String, rail_html :: String) -> String {
    has_rail = String.length(rail_html) > 0
    open_div = if has_rail {
      "<div class=\"layout\">\n"
    } else {
      "<div class=\"layout layout-no-toc\">\n"
    }
    main_html = "<main class=\"content\">\n" <> content_html <> "</main>\n"
    open_div <> sidebar_html <> main_html <> rail_html <> "</div>\n"
  }

  pub fn sidebar(structs :: [String], protocols :: [String], unions :: [String], current :: String, base :: String) -> String {
    structs_group = if List.empty?(structs) {
      ""
    } else {
      sidebar_group("Structs", structs, current, base)
    }
    protocols_group = if List.empty?(protocols) {
      ""
    } else {
      sidebar_group("Protocols", protocols, current, base)
    }
    unions_group = if List.empty?(unions) {
      ""
    } else {
      sidebar_group("Unions", unions, current, base)
    }
    open_nav = "<nav class=\"sidebar\">\n"
    header = "<div class=\"sidebar-header\"><a href=\"" <> base <> "index.html\" class=\"sidebar-title\"></a> <span class=\"sidebar-version\"></span></div>\n"
    search_input = "<div class=\"sidebar-search\"><input type=\"text\" id=\"search-input\" placeholder=\"Search (Cmd+K)\" aria-label=\"Search documentation\"></div>\n"
    open_nav <> header <> search_input <> structs_group <> protocols_group <> unions_group <> "</nav>\n"
  }

  pub fn search_modal() -> String {
    open = "<div id=\"search-modal\" class=\"search-modal\" hidden>\n<div class=\"search-backdrop\"></div>\n<div class=\"search-dialog\">\n"
    icon = "<svg width=\"15\" height=\"15\" viewBox=\"0 0 16 16\" fill=\"none\" aria-hidden=\"true\">\n<circle cx=\"7\" cy=\"7\" r=\"5\" stroke=\"currentColor\" stroke-width=\"1.3\"/>\n<line x1=\"10.6\" y1=\"10.6\" x2=\"14\" y2=\"14\" stroke=\"currentColor\" stroke-width=\"1.3\" stroke-linecap=\"round\"/>\n</svg>\n"
    header = "<div class=\"search-header\">\n" <> icon <> "<input type=\"text\" id=\"search-modal-input\" placeholder=\"Search Zap docs\u{2026}\" aria-label=\"Search\">\n<kbd>ESC</kbd>\n</div>\n"
    results = "<ul id=\"search-results\" class=\"search-results\"></ul>\n"
    footer_top = "<div class=\"search-footer\">\n<span class=\"search-footer-item\"><kbd>\u{2191}</kbd><kbd>\u{2193}</kbd> navigate</span>\n<span class=\"search-footer-item\"><kbd>\u{21b5}</kbd> open</span>\n<span class=\"spacer\"></span>\n<span class=\"search-footer-item\"><kbd>ESC</kbd> close</span>\n</div>\n"
    open <> header <> results <> footer_top <> "</div>\n</div>\n"
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

  @doc = """
    Compose a complete HTML page for a single module summary.

    `summary` is a `%{Atom => Term}` map produced by
    `Zap.Doc.Builder` — it carries `:name`, `:doc`, and
    kind-specific fields. `structs`, `protocols`, and `unions` are
    the sidebar name lists (typically the corresponding `manifest_*`
    accessors). The returned HTML embeds the struct's name as the
    page heading and its `@doc` text as the lead paragraph; the
    sidebar highlights the current module.
    """
  pub fn render_summary_page(summary :: %{Atom => Term}, kind :: Atom, structs :: [String], protocols :: [String], unions :: [String], all_functions :: [%{Atom => Term}], all_macros :: [%{Atom => Term}], all_impls :: [%{Atom => Term}], all_variants :: [%{Atom => Term}], all_required :: [%{Atom => Term}]) -> String {
    name = Map.get(summary, :name, "")
    doc = Map.get(summary, :doc, "")
    structdoc_html = Markdown.to_html(doc)
    functions_rows = render_module_member_rows(all_functions, name, "")
    macros_rows = render_module_member_rows(all_macros, name, "")
    functions_details = render_module_member_details(all_functions, name, false, "")
    macros_details = render_module_member_details(all_macros, name, true, "")
    implements = collect_implemented_protocols(all_impls, name, [] :: [String])
    body_html = module_main_content(kind, name, implements, first_sentence(doc), structdoc_html, functions_rows, macros_rows, functions_details, macros_details)
    extras = render_kind_extras(kind, name, all_variants, all_required)
    content = body_html <> extras
    sidebar_html = sidebar(structs, protocols, unions, name, "")
    struct_page("Zap", "0.0.0", name, "", "", sidebar_html, content, "")
  }

  @doc = """
    Walk the flat function or macro manifest, filter by `:module` to
    keep only entries belonging to `module_name`, and emit a
    `<div class="function-detail">` block per match — header with
    name/arity/anchor + Markdown-rendered doc body. Returns the
    concatenation of all matching detail blocks; the caller passes
    the result to `module_main_content`'s `functions_details` or
    `macros_details` slot.
    """
  pub fn render_module_member_details(members :: [%{Atom => Term}], module_name :: String, is_macro :: Bool, acc :: String) -> String {
    if List.empty?(members) {
      acc
    } else {
      render_module_member_details(List.tail(members), module_name, is_macro, acc <> member_detail_for_module(List.head(members), module_name, is_macro))
    }
  }

  pub fn member_detail_for_module(member :: %{Atom => Term}, module_name :: String, is_macro :: Bool) -> String {
    if Map.get(member, :module, "") == module_name {
      compose_member_detail(Map.get(member, :name, ""), Map.get(member, :arity, 0), is_macro, Map.get(member, :doc, ""))
    } else {
      ""
    }
  }

  pub fn compose_member_detail(name :: String, arity :: i64, is_macro :: Bool, doc :: String) -> String {
    doc_html = Markdown.to_html(doc)
    open_div = "<div class=\"function-detail\" id=\"" <> anchor_id(name, arity) <> "\">\n"
    header = function_header(name, arity, is_macro)
    body = if String.length(doc_html) == 0 {
      ""
    } else {
      "<div class=\"function-doc\">\n" <> doc_html <> "</div>\n"
    }
    open_div <> header <> body <> "</div>\n"
  }

  @doc = """
    Render kind-specific summary tables that don't fit
    `module_main_content`'s hardcoded Functions/Macros slots.

    Unions get a "Variants" table from `all_variants` filtered by
    `:module`. Protocols get a "Required Functions" table from
    `all_required`. Other kinds emit nothing. Each section uses
    `summary_table` so an empty filter result collapses the whole
    block.
    """
  pub fn render_kind_extras(kind :: Atom, name :: String, all_variants :: [%{Atom => Term}], all_required :: [%{Atom => Term}]) -> String {
    if kind == :union {
      summary_table("Variants", "variants", render_variant_rows(all_variants, name, ""))
    } else {
      if kind == :protocol {
        summary_table("Required Functions", "required-functions", render_required_rows(all_required, name, ""))
      } else {
        ""
      }
    }
  }

  pub fn render_variant_rows(variants :: [%{Atom => Term}], module_name :: String, acc :: String) -> String {
    if List.empty?(variants) {
      acc
    } else {
      head = List.head(variants)
      tail = List.tail(variants)
      row = if Map.get(head, :module, "") == module_name {
        summary_row(Map.get(head, :name, ""), 0, Map.get(head, :signature, ""))
      } else {
        ""
      }
      render_variant_rows(tail, module_name, acc <> row)
    }
  }

  pub fn render_required_rows(required :: [%{Atom => Term}], module_name :: String, acc :: String) -> String {
    if List.empty?(required) {
      acc
    } else {
      head = List.head(required)
      tail = List.tail(required)
      row = if Map.get(head, :module, "") == module_name {
        summary_row(Map.get(head, :name, ""), 0, Map.get(head, :signature, ""))
      } else {
        ""
      }
      render_required_rows(tail, module_name, acc <> row)
    }
  }

  @doc = """
    Walk the flat impl manifest and collect protocol names whose
    `:target` matches `module_name`. Returns the collected list so
    `module_main_content` can populate the "Implements" row above the
    title without further filtering.
    """
  pub fn collect_implemented_protocols(impls :: [%{Atom => Term}], module_name :: String, acc :: [String]) -> [String] {
    if List.empty?(impls) {
      acc
    } else {
      head = List.head(impls)
      tail = List.tail(impls)
      target = Map.get(head, :target, "")
      if target == module_name {
        proto_name = Map.get(head, :proto_name, "")
        collect_implemented_protocols(tail, module_name, List.append(acc, proto_name))
      } else {
        collect_implemented_protocols(tail, module_name, acc)
      }
    }
  }

  @doc = """
    Render summary rows for the subset of `members` whose `:module`
    field equals `module_name`. Used to project the flat global
    function/macro list onto a single module's reference page.
    Returns the empty string when no member matches so
    `summary_table` collapses the whole section.
    """
  pub fn render_module_member_rows(members :: [%{Atom => Term}], module_name :: String, acc :: String) -> String {
    if List.empty?(members) {
      acc
    } else {
      render_module_member_rows(List.tail(members), module_name, acc <> member_row_for_module(List.head(members), module_name))
    }
  }

  @doc = """
    Render a single `summary_row` for `member` if `member[:module]`
    equals `module_name`, otherwise return the empty string. Splits
    out of `render_module_member_rows` so the outer recursion stays a
    single tail call regardless of whether the member matches.
    """
  pub fn member_row_for_module(member :: %{Atom => Term}, module_name :: String) -> String {
    if Map.get(member, :module, "") == module_name {
      summary_row(Map.get(member, :name, ""), Map.get(member, :arity, 0), first_sentence(Map.get(member, :doc, "")))
    } else {
      ""
    }
  }

  @doc = """
    Render every summary list to disk under `out_dir` and return the
    total number of pages written. Each summary becomes
    `<out_dir>/<name>.html`. The sidebar shows all three name lists so
    cross-links between structs, protocols, and unions resolve from
    every page.

    Typically called from a project's `main/1` after invoking
    `use Zap.Doc.Builder`.
    """
  pub fn write_pages_to(out_dir :: String, struct_summaries :: [%{Atom => Term}], protocol_summaries :: [%{Atom => Term}], union_summaries :: [%{Atom => Term}], function_summaries :: [%{Atom => Term}], macro_summaries :: [%{Atom => Term}], impl_summaries :: [%{Atom => Term}], variant_summaries :: [%{Atom => Term}], required_summaries :: [%{Atom => Term}]) -> i64 {
    structs = manifest_names(struct_summaries, [])
    protocols = manifest_names(protocol_summaries, [])
    unions = manifest_names(union_summaries, [])
    written_structs = write_summary_pages(out_dir, struct_summaries, :struct, structs, protocols, unions, function_summaries, macro_summaries, impl_summaries, variant_summaries, required_summaries, 0)
    written_protocols = write_summary_pages(out_dir, protocol_summaries, :protocol, structs, protocols, unions, function_summaries, macro_summaries, impl_summaries, variant_summaries, required_summaries, 0)
    written_unions = write_summary_pages(out_dir, union_summaries, :union, structs, protocols, unions, function_summaries, macro_summaries, impl_summaries, variant_summaries, required_summaries, 0)
    index_html = render_index_page(structs, protocols, unions)
    _ = File.write(out_dir <> "/index.html", index_html)
    written_structs + written_protocols + written_unions
  }

  @doc = """
    Compose the docs landing page. Lists every module name from the
    three sidebar lists under category headings. Linked entries point
    at `<name>.html`. The page reuses the same chrome (`page_open`,
    `topbar`, `sidebar`, `page_close`) as the per-module pages so the
    layout is consistent.
    """
  pub fn render_index_page(structs :: [String], protocols :: [String], unions :: [String]) -> String {
    structs_section = render_index_section("Structs", structs, "")
    protocols_section = render_index_section("Protocols", protocols, "")
    unions_section = render_index_section("Unions", unions, "")
    content = "<h1 class=\"page-title\">Reference</h1>\n" <> structs_section <> protocols_section <> unions_section
    sidebar_html = sidebar(structs, protocols, unions, "", "")
    struct_page("Zap", "0.0.0", "Reference", "", "", sidebar_html, content, "")
  }

  @doc = """
    Render one section of the index page: a heading plus a `<ul>` of
    links, one per name. Returns the empty string when the name list
    is empty so the caller can emit all three section calls
    unconditionally and let the renderer drop empty kinds.
    """
  pub fn render_index_section(heading :: String, names :: [String], _unused :: String) -> String {
    if List.empty?(names) {
      ""
    } else {
      "<h2>" <> escape_html(heading) <> "</h2>\n<ul class=\"index-list\">\n" <> render_index_links(names, "") <> "</ul>\n"
    }
  }

  pub fn render_index_links(names :: [String], acc :: String) -> String {
    if List.empty?(names) {
      acc
    } else {
      head = List.head(names)
      tail = List.tail(names)
      link = "<li><a href=\"" <> escape_html(head) <> ".html\">" <> escape_html(head) <> "</a></li>\n"
      render_index_links(tail, acc <> link)
    }
  }

  @doc = """
    Recursively pull `:name` from each summary, accumulating into a
    list of strings. Used to build the sidebar name lists from a
    single-pass walk so callers don't have to maintain three parallel
    arrays of names alongside their summaries.
    """
  pub fn manifest_names(summaries :: [%{Atom => Term}], acc :: [String]) -> [String] {
    if List.empty?(summaries) {
      acc
    } else {
      head = List.head(summaries)
      tail = List.tail(summaries)
      manifest_names(tail, List.append(acc, Map.get(head, :name, "")))
    }
  }

  @doc = """
    Iterate `summaries`, render each as a full HTML page, and write
    `<out_dir>/<name>.html`. Returns the number of pages written.
    Files that fail to write are skipped without raising — `File.write`
    surfaces a Bool, which we count toward the total only when true so
    a partial failure doesn't lie about how much output landed.
    """
  pub fn write_summary_pages(out_dir :: String, summaries :: [%{Atom => Term}], kind :: Atom, structs :: [String], protocols :: [String], unions :: [String], all_functions :: [%{Atom => Term}], all_macros :: [%{Atom => Term}], all_impls :: [%{Atom => Term}], all_variants :: [%{Atom => Term}], all_required :: [%{Atom => Term}], acc :: i64) -> i64 {
    if List.empty?(summaries) {
      acc
    } else {
      head = List.head(summaries)
      tail = List.tail(summaries)
      name = Map.get(head, :name, "")
      html = render_summary_page(head, kind, structs, protocols, unions, all_functions, all_macros, all_impls, all_variants, all_required)
      path = out_dir <> "/" <> name <> ".html"
      ok = File.write(path, html)
      if ok {
        write_summary_pages(out_dir, tail, kind, structs, protocols, unions, all_functions, all_macros, all_impls, all_variants, all_required, acc + 1)
      } else {
        write_summary_pages(out_dir, tail, kind, structs, protocols, unions, all_functions, all_macros, all_impls, all_variants, all_required, acc)
      }
    }
  }
}

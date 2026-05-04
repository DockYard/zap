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
    topbar_with_tabs(project_name, version, base, source_url, :none, "", "")
  }

  @doc = """
    Render the topbar with an optional Reference/Guide tab switch in
    the right cluster. `tab_state` is `:reference` on a struct page
    that has a matching guide, `:guide` on the corresponding guide
    page, or `:none` when no tabs apply. `ref_url` and `guide_url`
    are the relative URLs the tab anchors point at; both must be
    populated whenever `tab_state` is not `:none`. Mirrors the
    `TopbarTabs` struct the legacy Zig generator passed to
    `appendPageHeader`.
    """
  pub fn topbar_with_tabs(project_name :: String, version :: String, base :: String, source_url :: String, tab_state :: Atom, ref_url :: String, guide_url :: String) -> String {
    open = "<header class=\"topbar\">\n"
    left = topbar_left(project_name, version, base)
    center = topbar_center()
    right = topbar_right_with_tabs(source_url, tab_state, ref_url, guide_url)
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
    topbar_right_with_tabs(source_url, :none, "", "")
  }

  pub fn topbar_right_with_tabs(source_url :: String, tab_state :: Atom, ref_url :: String, guide_url :: String) -> String {
    tabs_html = render_topbar_tabs(tab_state, ref_url, guide_url)
    theme = "<button id=\"theme-toggle\" aria-label=\"Toggle dark mode\" title=\"Toggle dark mode\">\n<span class=\"theme-icon-light\">\u{2600}</span>\n<span class=\"theme-icon-dark\">\u{263e}</span>\n</button>\n"
    divider = "<div class=\"topbar-divider\"></div>\n"
    github = if String.length(source_url) == 0 {
      ""
    } else {
      gh_icon = "<svg width=\"18\" height=\"18\" viewBox=\"0 0 16 16\" fill=\"currentColor\">\n<path d=\"M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z\"/>\n</svg>\n"
      "<a href=\"" <> escape_html(source_url) <> "\" class=\"topbar-github\" aria-label=\"GitHub repository\" title=\"GitHub\">\n" <> gh_icon <> "</a>\n"
    }
    "<div class=\"topbar-right\">\n" <> tabs_html <> theme <> divider <> github <> "</div>\n"
  }

  @doc = """
    Render the `<div class="topbar-tabs">` Reference/Guide switch
    that appears in the topbar's right cluster on pages where a
    struct has a matching guide. `tab_state` selects which tab gets
    the `active` class; `:none` returns the empty string so callers
    can splice unconditionally.
    """
  pub fn render_topbar_tabs(tab_state :: Atom, ref_url :: String, guide_url :: String) -> String {
    if tab_state == :none {
      ""
    } else {
      compose_topbar_tabs(tab_state, ref_url, guide_url)
    }
  }

  pub fn compose_topbar_tabs(tab_state :: Atom, ref_url :: String, guide_url :: String) -> String {
    ref_class = if tab_state == :reference { "topbar-tab active" } else { "topbar-tab" }
    guide_class = if tab_state == :guide { "topbar-tab active" } else { "topbar-tab" }
    "<div class=\"topbar-tabs\" role=\"tablist\">\n<a class=\"" <> ref_class <> "\" href=\"" <> escape_html(ref_url) <> "\" role=\"tab\">Reference</a>\n<a class=\"" <> guide_class <> "\" href=\"" <> escape_html(guide_url) <> "\" role=\"tab\">Guide</a>\n</div>\n<div class=\"topbar-divider\"></div>\n"
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
    struct_page_with_tabs(project_name, project_version, title, base, source_url, sidebar_html, content_html, rail_html, :none, "", "")
  }

  @doc = """
    Compose a full struct/guide/index page with an optional
    Reference/Guide topbar tab switch. `tab_state` is `:reference`,
    `:guide`, or `:none`; the matching urls populate the tab anchors
    when state isn't `:none`. Mirrors the `TopbarTabs` argument the
    legacy generator threaded through `appendPageHeader`.
    """
  pub fn struct_page_with_tabs(project_name :: String, project_version :: String, title :: String, base :: String, source_url :: String, sidebar_html :: String, content_html :: String, rail_html :: String, tab_state :: Atom, ref_url :: String, guide_url :: String) -> String {
    head = page_open(title, project_name, base)
    bar = topbar_with_tabs(project_name, project_version, base, source_url, tab_state, ref_url, guide_url)
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

  pub fn sidebar(structs :: [String], protocols :: [String], unions :: [String], guides :: [String], current :: String, base :: String, project_name :: String, project_version :: String) -> String {
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
    guides_group = if List.empty?(guides) {
      ""
    } else {
      guides_sidebar_group(guides, current, base)
    }
    open_nav = "<nav class=\"sidebar\">\n"
    header = "<div class=\"sidebar-header\"><a href=\"" <> base <> "index.html\" class=\"sidebar-title\">" <> escape_html(project_name) <> "</a> <span class=\"sidebar-version\">v" <> escape_html(project_version) <> "</span></div>\n"
    search_input = "<div class=\"sidebar-search\"><input type=\"text\" id=\"search-input\" placeholder=\"Search (Cmd+K)\" aria-label=\"Search documentation\"></div>\n"
    open_nav <> header <> search_input <> structs_group <> protocols_group <> unions_group <> guides_group <> "</nav>\n"
  }

  @doc = """
    Render the sidebar `Guides` group — pinned to the bottom of the
    sidebar. Each entry links to `<base>guides/<slug>.html` and
    title-cases the slug for display so a `guides/integer.md` file
    surfaces as `Integer` in the panel. When `current` matches one of
    the slugs, that entry gets the `active` class.
    """
  pub fn guides_sidebar_group(slugs :: [String], current :: String, base :: String) -> String {
    items = render_guide_sidebar_items(slugs, current, base, "")
    open_div = "<div class=\"sidebar-group\" data-group=\"Guides\">\n"
    button = "<button class=\"sidebar-group-header\" type=\"button\" aria-label=\"Toggle group\"><span class=\"chevron\" aria-hidden=\"true\">\u{25b8}</span><h4>Guides</h4></button>\n"
    open_div <> button <> "<ul>\n" <> items <> "</ul>\n</div>\n"
  }

  pub fn render_guide_sidebar_items(slugs :: [String], current :: String, base :: String, acc :: String) -> String {
    if List.empty?(slugs) {
      acc
    } else {
      head = List.head(slugs)
      tail = List.tail(slugs)
      render_guide_sidebar_items(tail, current, base, acc <> guide_sidebar_item(head, head == current, base))
    }
  }

  pub fn guide_sidebar_item(slug :: String, active? :: Bool, base :: String) -> String {
    li_open = if active? { "<li class=\"active\">" } else { "<li>" }
    li_open <> "<a href=\"" <> base <> "guides/" <> escape_html(slug) <> ".html\">" <> escape_html(title_case(slug)) <> "</a></li>\n"
  }

  @doc = """
    Title-case a guide slug for sidebar display: `integer` → `Integer`,
    `getting_started` → `Getting Started`. Walks byte-by-byte so the
    first character of each word is uppercased and underscores collapse
    to spaces.
    """
  pub fn title_case(slug :: String) -> String {
    title_case_walk(slug, 0, String.length(slug), true, "")
  }

  pub fn title_case_walk(slug :: String, index :: i64, end_index :: i64, capitalise_next :: Bool, acc :: String) -> String {
    if index >= end_index {
      acc
    } else {
      ch = String.byte_at(slug, index)
      if ch == "_" or ch == "-" {
        title_case_walk(slug, index + 1, end_index, true, acc <> " ")
      } else {
        emitted = if capitalise_next { upcase_byte(ch) } else { ch }
        title_case_walk(slug, index + 1, end_index, false, acc <> emitted)
      }
    }
  }

  pub fn upcase_byte(ch :: String) -> String {
    if ch >= "a" and ch <= "z" {
      String.byte_at("ABCDEFGHIJKLMNOPQRSTUVWXYZ", upcase_index(ch))
    } else {
      ch
    }
  }

  pub fn upcase_index(ch :: String) -> i64 {
    upcase_index_walk(ch, 0)
  }

  pub fn upcase_index_walk(ch :: String, idx :: i64) -> i64 {
    if idx >= 26 {
      0
    } else {
      if String.byte_at("abcdefghijklmnopqrstuvwxyz", idx) == ch {
        idx
      } else {
        upcase_index_walk(ch, idx + 1)
      }
    }
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
  pub fn render_summary_page(summary :: %{Atom => Term}, kind :: Atom, project_name :: String, project_version :: String, source_url :: String, structs :: [String], protocols :: [String], unions :: [String], guide_slugs :: [String], all_functions :: [%{Atom => Term}], all_macros :: [%{Atom => Term}], all_impls :: [%{Atom => Term}], all_variants :: [%{Atom => Term}], all_required :: [%{Atom => Term}]) -> String {
    name = Map.get(summary, :name, "")
    doc = Map.get(summary, :doc, "")
    structdoc_html = Markdown.to_html(doc)
    implements = collect_implemented_protocols(all_impls, name, [] :: [String])
    sorted_functions = sort_members_by_source_line(filter_members_by_module(all_functions, name))
    sorted_macros = sort_members_by_source_line(filter_members_by_module(all_macros, name))
    functions_rows = render_summary_rows_from_members(sorted_functions, "")
    macros_rows = render_summary_rows_from_members(sorted_macros, "")
    functions_details = render_member_details_sorted(sorted_functions, false, source_url, project_version, "")
    macros_details = render_member_details_sorted(sorted_macros, true, source_url, project_version, "")
    body_html = module_main_content(kind, name, implements, first_sentence(doc), structdoc_html, functions_rows, macros_rows, functions_details, macros_details)
    extras = render_kind_extras(kind, name, all_variants, all_required)
    content = body_html <> extras
    sidebar_html = sidebar(structs, protocols, unions, guide_slugs, name, "../", project_name, project_version)
    rail_html = render_right_rail(sorted_functions, sorted_macros)
    # When the struct has a matching guide (slug = lowercased last
    # segment of the qualified name), the topbar shows a
    # Reference/Guide tab switch with Reference active. Without a
    # match, `:none` collapses the tabs and the topbar lays out the
    # theme/github cluster as before.
    slug = slug_for_struct_name(name)
    has_guide = list_contains?(guide_slugs, slug)
    tab_state = if has_guide { :reference } else { :none }
    ref_url = if has_guide { "../structs/" <> name <> ".html" } else { "" }
    guide_url = if has_guide { "../guides/" <> slug <> ".html" } else { "" }
    struct_page_with_tabs(project_name, project_version, name, "../", source_url, sidebar_html, content, rail_html, tab_state, ref_url, guide_url)
  }

  @doc = """
    Render the right-rail "On this page" TOC from the sorted function
    and macro lists. Each non-empty kind contributes a
    `<li class="toc-section">` divider followed by one `toc_item` per
    member. Returns the empty string when both lists are empty so
    `layout` collapses to `layout-no-toc` and the content fills the
    freed column.
    """
  pub fn render_right_rail(functions :: [%{Atom => Term}], macros :: [%{Atom => Term}]) -> String {
    fn_section = if List.empty?(functions) { "" } else { toc_section_label("Functions") <> render_toc_items(functions, "") }
    macro_section = if List.empty?(macros) { "" } else { toc_section_label("Macros") <> render_toc_items(macros, "") }
    right_rail(fn_section <> macro_section)
  }

  pub fn render_toc_items(members :: [%{Atom => Term}], acc :: String) -> String {
    if List.empty?(members) {
      acc
    } else {
      head = List.head(members)
      tail = List.tail(members)
      render_toc_items(tail, acc <> toc_item(Map.get(head, :name, ""), Map.get(head, :arity, 0)))
    }
  }

  @doc = """
    Filter a flat function/macro manifest down to only the entries
    whose `:module` field equals `module_name`. Used by
    `render_summary_page` so the per-module sort and render passes
    don't have to re-check the module name on every iteration.
    """
  pub fn filter_members_by_module(members :: [%{Atom => Term}], module_name :: String) -> [%{Atom => Term}] {
    filter_members_walk(members, module_name, [] :: [%{Atom => Term}])
  }

  pub fn filter_members_walk(members :: [%{Atom => Term}], module_name :: String, acc :: [%{Atom => Term}]) -> [%{Atom => Term}] {
    if List.empty?(members) {
      acc
    } else {
      head = List.head(members)
      tail = List.tail(members)
      if Map.get(head, :module, "") == module_name {
        filter_members_walk(tail, module_name, List.append(acc, head))
      } else {
        filter_members_walk(tail, module_name, acc)
      }
    }
  }

  @doc = """
    Sort a list of member maps by `:source_line` ascending. Insertion
    sort: predictable, stable on equal keys, and avoids the recursive
    splitting Zap's lambda surface still has rough edges around. Each
    member is read once and inserted into the accumulator in
    source-line order, so the output preserves the source-file
    layout the legacy generator emitted — the same order an
    `@doc`-driven reader expects when scanning a module's reference page.
    """
  pub fn sort_members_by_source_line(members :: [%{Atom => Term}]) -> [%{Atom => Term}] {
    sort_members_walk(members, [] :: [%{Atom => Term}])
  }

  pub fn sort_members_walk(remaining :: [%{Atom => Term}], sorted :: [%{Atom => Term}]) -> [%{Atom => Term}] {
    if List.empty?(remaining) {
      sorted
    } else {
      head = List.head(remaining)
      tail = List.tail(remaining)
      sort_members_walk(tail, insert_member_by_line(sorted, head))
    }
  }

  pub fn insert_member_by_line(sorted :: [%{Atom => Term}], item :: %{Atom => Term}) -> [%{Atom => Term}] {
    insert_member_walk(sorted, item, [] :: [%{Atom => Term}])
  }

  pub fn insert_member_walk(sorted :: [%{Atom => Term}], item :: %{Atom => Term}, prefix :: [%{Atom => Term}]) -> [%{Atom => Term}] {
    if List.empty?(sorted) {
      List.append(prefix, item)
    } else {
      head = List.head(sorted)
      tail = List.tail(sorted)
      if member_lt?(item, head) {
        list_concat_two(List.append(prefix, item), sorted)
      } else {
        insert_member_walk(tail, item, List.append(prefix, head))
      }
    }
  }

  @doc = """
    Order two member maps for the per-page table sort. Compare on
    `:source_file` first so functions from the struct's own source group
    together, then on `:source_line` within a file so the order matches
    the legacy generator's source-driven layout. Falls back to `:name`
    when the location fields are identical (e.g. macro-generated
    siblings) so the order remains stable across runs.
    """
  pub fn member_lt?(a :: %{Atom => Term}, b :: %{Atom => Term}) -> Bool {
    file_lt_or_eq?(Map.get(a, :source_file, ""), Map.get(b, :source_file, ""), a, b)
  }

  pub fn file_lt_or_eq?(a_file :: String, b_file :: String, a :: %{Atom => Term}, b :: %{Atom => Term}) -> Bool {
    if string_lt?(a_file, b_file) {
      true
    } else {
      file_eq_or_gt?(string_eq?(a_file, b_file), a, b)
    }
  }

  pub fn file_eq_or_gt?(file_eq :: Bool, a :: %{Atom => Term}, b :: %{Atom => Term}) -> Bool {
    if file_eq {
      line_lt_or_eq?(Map.get(a, :source_line, 0), Map.get(b, :source_line, 0), a, b)
    } else {
      false
    }
  }

  pub fn line_lt_or_eq?(a_line :: i64, b_line :: i64, a :: %{Atom => Term}, b :: %{Atom => Term}) -> Bool {
    if a_line < b_line {
      true
    } else {
      line_eq_or_gt?(a_line == b_line, a, b)
    }
  }

  pub fn line_eq_or_gt?(line_eq :: Bool, a :: %{Atom => Term}, b :: %{Atom => Term}) -> Bool {
    if line_eq {
      string_lt?(Map.get(a, :name, ""), Map.get(b, :name, ""))
    } else {
      false
    }
  }

  @doc = """
    True when `left` sorts strictly before `right` lexicographically by
    byte order. Implemented in Zap to keep the doc generator
    self-contained — `String` doesn't yet expose a public compare
    primitive.
    """
  pub fn string_lt?(left :: String, right :: String) -> Bool {
    string_lt_walk?(left, right, 0, String.length(left), String.length(right))
  }

  pub fn string_lt_walk?(left :: String, right :: String, index :: i64, left_len :: i64, right_len :: i64) -> Bool {
    if index >= left_len {
      index < right_len
    } else {
      if index >= right_len {
        false
      } else {
        l = String.byte_at(left, index)
        r = String.byte_at(right, index)
        if l == r {
          string_lt_walk?(left, right, index + 1, left_len, right_len)
        } else {
          l < r
        }
      }
    }
  }

  @doc = "True when two strings are byte-equal."
  pub fn string_eq?(left :: String, right :: String) -> Bool {
    if String.length(left) == String.length(right) {
      string_eq_walk?(left, right, 0, String.length(left))
    } else {
      false
    }
  }

  pub fn string_eq_walk?(left :: String, right :: String, index :: i64, end_index :: i64) -> Bool {
    if index >= end_index {
      true
    } else {
      if String.byte_at(left, index) == String.byte_at(right, index) {
        string_eq_walk?(left, right, index + 1, end_index)
      } else {
        false
      }
    }
  }

  pub fn list_concat_two(left :: [%{Atom => Term}], right :: [%{Atom => Term}]) -> [%{Atom => Term}] {
    if List.empty?(right) {
      left
    } else {
      list_concat_two(List.append(left, List.head(right)), List.tail(right))
    }
  }

  @doc = """
    Render summary table rows from a list of member maps already
    filtered to one module's entries. Each row uses the member's
    `:name`, `:arity`, and the first sentence of `:doc`.
    """
  pub fn render_summary_rows_from_members(members :: [%{Atom => Term}], acc :: String) -> String {
    if List.empty?(members) {
      acc
    } else {
      head = List.head(members)
      tail = List.tail(members)
      row = summary_row(Map.get(head, :name, ""), Map.get(head, :arity, 0), first_sentence(Map.get(head, :doc, "")))
      render_summary_rows_from_members(tail, acc <> row)
    }
  }

  @doc = """
    Render function detail blocks from a list of member maps already
    filtered+sorted to one module's entries. Mirrors
    `render_module_member_details` but skips the per-iteration module
    filter — the caller has done that work.
    """
  pub fn render_member_details_sorted(members :: [%{Atom => Term}], is_macro :: Bool, source_url :: String, project_version :: String, acc :: String) -> String {
    if List.empty?(members) {
      acc
    } else {
      head = List.head(members)
      tail = List.tail(members)
      block = compose_member_detail(Map.get(head, :name, ""), Map.get(head, :arity, 0), is_macro, Map.get(head, :doc, ""), Map.get(head, :source_file, ""), Map.get(head, :source_line, 0), Map.get(head, :signatures_joined, ""), source_url, project_version)
      render_member_details_sorted(tail, is_macro, source_url, project_version, acc <> block)
    }
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
  pub fn render_module_member_details(members :: [%{Atom => Term}], module_name :: String, is_macro :: Bool, source_url :: String, project_version :: String, acc :: String) -> String {
    if List.empty?(members) {
      acc
    } else {
      render_module_member_details(List.tail(members), module_name, is_macro, source_url, project_version, acc <> member_detail_for_module(List.head(members), module_name, is_macro, source_url, project_version))
    }
  }

  pub fn member_detail_for_module(member :: %{Atom => Term}, module_name :: String, is_macro :: Bool, source_url :: String, project_version :: String) -> String {
    if Map.get(member, :module, "") == module_name {
      compose_member_detail(Map.get(member, :name, ""), Map.get(member, :arity, 0), is_macro, Map.get(member, :doc, ""), Map.get(member, :source_file, ""), Map.get(member, :source_line, 0), Map.get(member, :signatures_joined, ""), source_url, project_version)
    } else {
      ""
    }
  }

  pub fn compose_member_detail(name :: String, arity :: i64, is_macro :: Bool, doc :: String, source_file :: String, source_line :: i64, signatures_joined :: String, source_url :: String, project_version :: String) -> String {
    doc_html = Markdown.to_html(doc)
    open_div = "<div class=\"function-detail\" id=\"" <> anchor_id(name, arity) <> "\">\n"
    header = function_header(name, arity, is_macro)
    sigs_html = render_signatures(signatures_joined)
    body = if String.length(doc_html) == 0 {
      ""
    } else {
      "<div class=\"function-doc\">\n" <> doc_html <> "</div>\n"
    }
    source = source_link(source_file, source_line, source_url, project_version)
    open_div <> header <> sigs_html <> body <> source <> "</div>\n"
  }

  @doc = """
    Split a newline-joined block of bare signature strings (the
    `:signatures_joined` value baked at compile time by
    `Zap.Doc.Builder`) and render each one through the rich-signature
    renderer. Empty input returns the empty string so callers can
    splice unconditionally.
    """
  pub fn render_signatures(signatures_joined :: String) -> String {
    if String.length(signatures_joined) == 0 {
      ""
    } else {
      render_signatures_walk(String.split(signatures_joined, "\n"), "")
    }
  }

  pub fn render_signatures_walk(sigs :: [String], acc :: String) -> String {
    if List.empty?(sigs) {
      acc
    } else {
      head = List.head(sigs)
      tail = List.tail(sigs)
      if String.length(head) == 0 {
        render_signatures_walk(tail, acc)
      } else {
        render_signatures_walk(tail, acc <> rich_signature_block(head))
      }
    }
  }

  @doc = """
    Render one signature string as the structured `<div class="signature">`
    block the legacy generator emitted: `<span class="sig-name">`,
    `<span class="sig-paren">(</span>`, typed-param pills, the
    arrow `<span class="sig-arrow">→</span>`, and the return-type pill.
    Falls back to the plain `<code>` form when the signature shape
    can't be parsed.
    """
  pub fn rich_signature_block(signature :: String) -> String {
    paren_open = String.index_of(signature, "(")
    if paren_open < 0 {
      "<div class=\"signature\"><code>" <> escape_html(signature) <> "</code></div>\n"
    } else {
      rich_signature_with_open(signature, paren_open)
    }
  }

  pub fn rich_signature_with_open(signature :: String, paren_open :: i64) -> String {
    paren_close = matching_close_paren(signature, paren_open + 1, 1, String.length(signature))
    if paren_close < 0 {
      "<div class=\"signature\"><code>" <> escape_html(signature) <> "</code></div>\n"
    } else {
      rich_signature_assemble(signature, paren_open, paren_close)
    }
  }

  pub fn rich_signature_assemble(signature :: String, paren_open :: i64, paren_close :: i64) -> String {
    sig_name = String.slice(signature, 0, paren_open)
    params = String.slice(signature, paren_open + 1, paren_close)
    rest = String.slice(signature, paren_close + 1, String.length(signature))
    params_html = render_signature_params(params)
    return_html = render_signature_return(rest)
    body = "<span class=\"sig-name\">" <> escape_html(sig_name) <> "</span><span class=\"sig-paren\">(</span>" <> params_html <> "<span class=\"sig-paren\">)</span>" <> return_html
    "<div class=\"signature\"><code>" <> body <> "</code></div>\n"
  }

  @doc = """
    Walk a signature string from `index` looking for the close paren
    that matches the open paren the caller already consumed. Tracks
    nesting so function-typed parameters with their own parens
    (`(T) -> R`) don't trip the scanner. Returns -1 if no match is
    found before `end_index`.
    """
  pub fn matching_close_paren(text :: String, index :: i64, depth :: i64, end_index :: i64) -> i64 {
    if index >= end_index {
      -1
    } else {
      ch = String.byte_at(text, index)
      if ch == "(" {
        matching_close_paren(text, index + 1, depth + 1, end_index)
      } else {
        if ch == ")" {
          if depth == 1 {
            index
          } else {
            matching_close_paren(text, index + 1, depth - 1, end_index)
          }
        } else {
          matching_close_paren(text, index + 1, depth, end_index)
        }
      }
    }
  }

  @doc = """
    Render the parameter list of a signature. Splits on top-level
    commas (so a function-typed parameter with its own commas inside
    parens stays grouped), then renders each parameter as either
    `name<sep>::<sep><pill>type</pill>` or — if the parameter has no
    `::` — bare HTML-escaped text.
    """
  pub fn render_signature_params(params :: String) -> String {
    if String.length(String.trim(params)) == 0 {
      ""
    } else {
      render_signature_params_walk(split_top_level_commas(params), 0, "")
    }
  }

  pub fn render_signature_params_walk(parts :: [String], index :: i64, acc :: String) -> String {
    if List.empty?(parts) {
      acc
    } else {
      head = String.trim(List.head(parts))
      tail = List.tail(parts)
      if String.length(head) == 0 {
        render_signature_params_walk(tail, index, acc)
      } else {
        sep = if index == 0 { "" } else { "<span class=\"sig-paren\">, </span>" }
        render_signature_params_walk(tail, index + 1, acc <> sep <> render_one_param(head))
      }
    }
  }

  pub fn render_one_param(param :: String) -> String {
    sep_idx = String.index_of(param, " :: ")
    if sep_idx < 0 {
      escape_html(param)
    } else {
      render_typed_param(param, sep_idx)
    }
  }

  pub fn render_typed_param(param :: String, sep_idx :: i64) -> String {
    param_name = String.slice(param, 0, sep_idx)
    param_type = String.slice(param, sep_idx + 4, String.length(param))
    escape_html(param_name) <> "<span class=\"sig-separator\">::</span><span class=\"sig-type-pill\">" <> escape_html(param_type) <> "</span>"
  }

  @doc = """
    Render the trailing portion of a signature after the close paren:
    the `-> ReturnType [if guard]` segment. Empty/missing portions
    return the empty string.
    """
  pub fn render_signature_return(rest :: String) -> String {
    trimmed = String.trim(rest)
    if String.length(trimmed) == 0 {
      ""
    } else {
      render_signature_return_trimmed(trimmed)
    }
  }

  pub fn render_signature_return_trimmed(trimmed :: String) -> String {
    if String.starts_with?(trimmed, "-> ") {
      render_arrow_segment(String.trim(String.slice(trimmed, 3, String.length(trimmed))))
    } else {
      if String.starts_with?(trimmed, "if ") {
        render_signature_guard(String.trim(String.slice(trimmed, 3, String.length(trimmed))))
      } else {
        ""
      }
    }
  }

  pub fn render_arrow_segment(after_arrow :: String) -> String {
    guard_idx = index_of_top_level_guard(after_arrow)
    if guard_idx < 0 {
      render_return_type(after_arrow)
    } else {
      render_arrow_with_guard(after_arrow, guard_idx)
    }
  }

  pub fn render_arrow_with_guard(after_arrow :: String, guard_idx :: i64) -> String {
    ret_type = String.trim(String.slice(after_arrow, 0, guard_idx))
    guard = String.trim(String.slice(after_arrow, guard_idx + 4, String.length(after_arrow)))
    render_return_type(ret_type) <> render_signature_guard(guard)
  }

  pub fn render_return_type(ret :: String) -> String {
    if String.length(ret) == 0 {
      ""
    } else {
      "<span class=\"sig-arrow\">\u{2192}</span><span class=\"sig-ret-pill\">" <> escape_html(ret) <> "</span>"
    }
  }

  pub fn render_signature_guard(guard :: String) -> String {
    if String.length(guard) == 0 {
      ""
    } else {
      "<span class=\"sig-guard-keyword\">if</span><span class=\"sig-guard\">" <> escape_html(guard) <> "</span>"
    }
  }

  @doc = """
    Split a comma-separated string at top-level commas, respecting
    paren/bracket/brace depth. Parameters like `f :: (i64, i64) -> i64`
    stay grouped because the comma inside the function type sits at
    depth > 0.
    """
  pub fn split_top_level_commas(text :: String) -> [String] {
    split_top_level_walk(text, 0, 0, 0, String.length(text), [] :: [String])
  }

  pub fn split_top_level_walk(text :: String, start :: i64, index :: i64, depth :: i64, end_index :: i64, acc :: [String]) -> [String] {
    if index >= end_index {
      List.append(acc, String.slice(text, start, end_index))
    } else {
      ch = String.byte_at(text, index)
      if ch == "(" or ch == "[" or ch == "{" {
        split_top_level_walk(text, start, index + 1, depth + 1, end_index, acc)
      } else {
        if ch == ")" or ch == "]" or ch == "}" {
          split_top_level_walk(text, start, index + 1, depth - 1, end_index, acc)
        } else {
          if ch == "," and depth == 0 {
            split_top_level_walk(text, index + 1, index + 1, depth, end_index, List.append(acc, String.slice(text, start, index)))
          } else {
            split_top_level_walk(text, start, index + 1, depth, end_index, acc)
          }
        }
      }
    }
  }

  @doc = """
    Locate the top-level ` if ` token that introduces a clause guard,
    skipping nested-paren occurrences so a function-type parameter
    `(T) -> R if pred` doesn't confuse the scanner. Returns -1 when no
    top-level ` if ` is present.
    """
  pub fn index_of_top_level_guard(text :: String) -> i64 {
    scan_top_level_if(text, 0, 0, String.length(text))
  }

  pub fn scan_top_level_if(text :: String, index :: i64, depth :: i64, end_index :: i64) -> i64 {
    if index + 4 > end_index {
      -1
    } else {
      ch = String.byte_at(text, index)
      if ch == "(" or ch == "[" or ch == "{" {
        scan_top_level_if(text, index + 1, depth + 1, end_index)
      } else {
        if ch == ")" or ch == "]" or ch == "}" {
          scan_top_level_if(text, index + 1, depth - 1, end_index)
        } else {
          if depth == 0 and is_if_at?(text, index, end_index) {
            index
          } else {
            scan_top_level_if(text, index + 1, depth, end_index)
          }
        }
      }
    }
  }

  pub fn is_if_at?(text :: String, index :: i64, end_index :: i64) -> Bool {
    if index + 4 > end_index {
      false
    } else {
      String.byte_at(text, index) == " " and String.byte_at(text, index + 1) == "i" and String.byte_at(text, index + 2) == "f" and String.byte_at(text, index + 3) == " "
    }
  }

  @doc = """
    Render a `[Source]` link pointing at the function's declaration
    in the project's repository. Returns the empty string when any
    of the inputs is missing — `source_url == ""` (the project hasn't
    declared a repo URL), `source_file == ""` (reflection didn't
    capture a source location), or `source_line <= 0`. Format
    matches the historical Zig generator: `<url>/blob/v<version>/<file>#L<line>`.
    """
  pub fn source_link(source_file :: String, source_line :: i64, source_url :: String, project_version :: String) -> String {
    if String.length(source_url) == 0 {
      ""
    } else {
      if String.length(source_file) == 0 {
        ""
      } else {
        if source_line <= 0 {
          ""
        } else {
          href = source_url <> "/blob/v" <> project_version <> "/" <> strip_dot_slash(source_file) <> "#L" <> Integer.to_string(source_line)
          "<a class=\"source-link\" href=\"" <> escape_html(href) <> "\">Source</a>\n"
        }
      }
    }
  }

  @doc = """
    Strip a leading `./` prefix that the macro-eval source-id resolver
    sometimes attaches to relative paths. The repo URLs the
    `[Source]` link points at don't tolerate the redundant segment.
    """
  pub fn strip_dot_slash(path :: String) -> String {
    if String.starts_with?(path, "./") {
      String.slice(path, 2, String.length(path))
    } else {
      path
    }
  }

  @doc = """
    Escape a string for safe inclusion as a JSON string literal.
    Replaces backslash, double-quote, and newline with their JSON
    escape sequences. Other control characters are rare in stdlib
    `@doc` text.
    """
  pub fn json_escape(text :: String) -> String {
    step1 = String.replace(text, "\\", "\\\\")
    step2 = String.replace(step1, "\"", "\\\"")
    String.replace(step2, "\n", "\\n")
  }

  @doc = "Render one struct/protocol/union summary as a JSON entry."
  pub fn struct_search_entry(summary :: %{Atom => Term}, kind_label :: String) -> String {
    name = Map.get(summary, :name, "")
    doc_text = Map.get(summary, :doc, "")
    "{\"struct\":\"" <> json_escape(name) <> "\",\"type\":\"" <> kind_label <> "\",\"name\":\"" <> json_escape(name) <> "\",\"summary\":\"" <> json_escape(first_sentence(doc_text)) <> "\",\"url\":\"structs/" <> json_escape(name) <> ".html\"},\n"
  }

  @doc = "Walk a list of struct/protocol/union summaries, accumulating JSON search entries."
  pub fn render_struct_search_entries(summaries :: [%{Atom => Term}], kind_label :: String, acc :: String) -> String {
    if List.empty?(summaries) {
      acc
    } else {
      head = List.head(summaries)
      tail = List.tail(summaries)
      entry_text = struct_search_entry(head, kind_label)
      render_struct_search_entries(tail, kind_label, acc <> entry_text)
    }
  }

  @doc = """
    Compose one function/macro JSON search-index entry from already-typed
    fields. `function_search_entry` does the `Map.get` extraction at the
    call boundary so the `i64`/`String` parameters here are concretely
    typed — Zap dispatches `Integer.to_string` and `<>`/`Concatenable.concat`
    against the concrete types without going through Term unboxing inside
    the body. Mirrors the `compose_member_detail` pattern used elsewhere
    in this struct.
    """
  pub fn compose_function_search_entry(module_name :: String, fn_name :: String, arity :: i64, doc_text :: String, kind_label :: String) -> String {
    arity_str = Integer.to_string(arity)
    "{\"struct\":\"" <> json_escape(module_name) <> "\",\"type\":\"" <> kind_label <> "\",\"name\":\"" <> json_escape(fn_name) <> "/" <> arity_str <> "\",\"summary\":\"" <> json_escape(first_sentence(doc_text)) <> "\",\"url\":\"structs/" <> json_escape(module_name) <> ".html#" <> json_escape(fn_name) <> "-" <> arity_str <> "\"},\n"
  }

  @doc = "Render a `:module` + `:name` + `:arity` flat-summary entry as a JSON search entry. Used for functions and macros."
  pub fn function_search_entry(entry :: %{Atom => Term}, kind_label :: String) -> String {
    compose_function_search_entry(Map.get(entry, :module, ""), Map.get(entry, :name, ""), Map.get(entry, :arity, 0), Map.get(entry, :doc, ""), kind_label)
  }

  @doc = "Walk a list of function/macro flat-summaries, accumulating JSON search entries."
  pub fn render_function_search_entries(items :: [%{Atom => Term}], kind_label :: String, acc :: String) -> String {
    if List.empty?(items) {
      acc
    } else {
      head = List.head(items)
      tail = List.tail(items)
      entry_text = function_search_entry(head, kind_label)
      render_function_search_entries(tail, kind_label, acc <> entry_text)
    }
  }

  @doc = """
    Strip the trailing `,\\n` separator left on each per-entry
    string by `*_search_entry`. Recursive walkers keep their bodies
    branch-free (every entry adds the same suffix); the array
    closer here drops the last separator before the `]`.
    """
  pub fn strip_trailing_comma_newline(body :: String) -> String {
    n = String.length(body)
    if n < 2 {
      body
    } else {
      String.slice(body, 0, n - 2)
    }
  }

  @doc = """
    Compose the full search-index JSON document. Each struct,
    protocol, union, function, and macro becomes one JSON entry
    matching the legacy Zig-side search index shape so the bundled
    `app.js` can index and render results without changes.
    """
  pub fn render_search_index(struct_summaries :: [%{Atom => Term}], protocol_summaries :: [%{Atom => Term}], union_summaries :: [%{Atom => Term}], function_summaries :: [%{Atom => Term}], macro_summaries :: [%{Atom => Term}]) -> String {
    structs_json = render_struct_search_entries(struct_summaries, "struct", "")
    protocols_json = render_struct_search_entries(protocol_summaries, "protocol", "")
    unions_json = render_struct_search_entries(union_summaries, "union", "")
    functions_json = render_function_search_entries(function_summaries, "function", "")
    macros_json = render_function_search_entries(macro_summaries, "macro", "")
    body = structs_json <> protocols_json <> unions_json <> functions_json <> macros_json
    "[\n" <> strip_trailing_comma_newline(body) <> "\n]\n"
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
        if list_contains?(acc, proto_name) {
          collect_implemented_protocols(tail, module_name, acc)
        } else {
          collect_implemented_protocols(tail, module_name, List.append(acc, proto_name))
        }
      } else {
        collect_implemented_protocols(tail, module_name, acc)
      }
    }
  }

  @doc = """
    Return true when `needle` appears in `items`. Tail-recursive so the
    `Implements` deduplication walk doesn't depend on a richer
    list-membership protocol.
    """
  pub fn list_contains?(items :: [String], needle :: String) -> Bool {
    if List.empty?(items) {
      false
    } else {
      head = List.head(items)
      if head == needle {
        true
      } else {
        list_contains?(List.tail(items), needle)
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
  pub fn write_pages_to(out_dir :: String, project_name :: String, project_version :: String, source_url :: String, landing_md :: String, struct_summaries :: [%{Atom => Term}], protocol_summaries :: [%{Atom => Term}], union_summaries :: [%{Atom => Term}], function_summaries :: [%{Atom => Term}], macro_summaries :: [%{Atom => Term}], impl_summaries :: [%{Atom => Term}], variant_summaries :: [%{Atom => Term}], required_summaries :: [%{Atom => Term}], guide_summaries :: [%{Atom => Term}], js_content :: String) -> i64 {
    _ = File.mkdir(out_dir <> "/structs")
    structs = sort_names_alpha(manifest_names(struct_summaries, []))
    protocols = sort_names_alpha(manifest_names(protocol_summaries, []))
    unions = sort_names_alpha(manifest_names(union_summaries, []))
    guide_slugs = sort_names_alpha(collect_guide_slugs(guide_summaries, [] :: [String]))
    written_structs = write_summary_pages(out_dir, struct_summaries, :struct, project_name, project_version, source_url, structs, protocols, unions, guide_slugs, function_summaries, macro_summaries, impl_summaries, variant_summaries, required_summaries, 0)
    written_protocols = write_summary_pages(out_dir, protocol_summaries, :protocol, project_name, project_version, source_url, structs, protocols, unions, guide_slugs, function_summaries, macro_summaries, impl_summaries, variant_summaries, required_summaries, 0)
    written_unions = write_summary_pages(out_dir, union_summaries, :union, project_name, project_version, source_url, structs, protocols, unions, guide_slugs, function_summaries, macro_summaries, impl_summaries, variant_summaries, required_summaries, 0)
    written_guides = write_guide_pages(out_dir, guide_summaries, project_name, project_version, source_url, structs, protocols, unions, guide_slugs, 0)
    index_html = render_index_page(structs, protocols, unions, guide_slugs, struct_summaries, project_name, project_version, source_url, landing_md)
    _ = File.write(out_dir <> "/index.html", index_html)
    search_json = render_search_index(struct_summaries, protocol_summaries, union_summaries, function_summaries, macro_summaries)
    _ = File.write(out_dir <> "/search-index.json", search_json)
    # The bundled app.js reads its search corpus from a `ZAP_SEARCH_DATA`
    # global declared at the top of the file. Inline the rendered
    # `search-index.json` ahead of the static JS so the file:// fallback
    # works without a fetch — matching the legacy generator's
    # `generateScriptWithIndex` shape.
    _ = File.write(out_dir <> "/app.js", "var ZAP_SEARCH_DATA = " <> search_json <> ";\n" <> js_content)
    written_structs + written_protocols + written_unions + written_guides
  }

  @doc = """
    Walk the guide manifest and pull each entry's slug out of the
    `:source_path` field. Slug = filename stem (basename minus the
    `.md` extension); `guides/integer.md` becomes `integer`.
    """
  pub fn collect_guide_slugs(guides :: [%{Atom => Term}], acc :: [String]) -> [String] {
    if List.empty?(guides) {
      acc
    } else {
      head = List.head(guides)
      tail = List.tail(guides)
      slug = guide_slug_from_source(Map.get(head, :source_path, ""))
      if String.length(slug) == 0 {
        collect_guide_slugs(tail, acc)
      } else {
        collect_guide_slugs(tail, List.append(acc, slug))
      }
    }
  }

  @doc = """
    Strip the directory prefix and `.md` suffix from a guide source
    path: `guides/integer.md` -> `integer`. Empty input yields the
    empty string so the caller can filter out entries that lost their
    path during reflection.
    """
  pub fn guide_slug_from_source(source_path :: String) -> String {
    base = Path.basename(source_path)
    if String.ends_with?(base, ".md") {
      String.slice(base, 0, String.length(base) - 3)
    } else {
      base
    }
  }

  @doc = """
    Render every entry in the guide manifest to
    `<out_dir>/guides/<slug>.html`. Each guide is loaded at runtime
    via `File.read/1`, rendered through `Markdown.to_html/1`, and
    framed by the same chrome (topbar / sidebar / structdoc body)
    used on per-struct pages so the look is consistent. Returns the
    number of pages successfully written.
    """
  pub fn write_guide_pages(out_dir :: String, guides :: [%{Atom => Term}], project_name :: String, project_version :: String, source_url :: String, structs :: [String], protocols :: [String], unions :: [String], guide_slugs :: [String], acc :: i64) -> i64 {
    if List.empty?(guides) {
      acc
    } else {
      _ = File.mkdir(out_dir <> "/guides")
      head = List.head(guides)
      tail = List.tail(guides)
      slug = guide_slug_from_source(Map.get(head, :source_path, ""))
      next_acc = if String.length(slug) == 0 {
        acc
      } else {
        write_one_guide_page(out_dir, head, slug, project_name, project_version, source_url, structs, protocols, unions, guide_slugs, acc)
      }
      write_guide_pages(out_dir, tail, project_name, project_version, source_url, structs, protocols, unions, guide_slugs, next_acc)
    }
  }

  pub fn write_one_guide_page(out_dir :: String, guide :: %{Atom => Term}, slug :: String, project_name :: String, project_version :: String, source_url :: String, structs :: [String], protocols :: [String], unions :: [String], guide_slugs :: [String], acc :: i64) -> i64 {
    source_path = Map.get(guide, :source_path, "")
    markdown_text = File.read(source_path)
    if String.length(markdown_text) == 0 {
      acc
    } else {
      page_html = render_guide_page(slug, markdown_text, project_name, project_version, source_url, structs, protocols, unions, guide_slugs)
      ok = File.write(out_dir <> "/guides/" <> slug <> ".html", page_html)
      if ok { acc + 1 } else { acc }
    }
  }

  @doc = """
    Compose the full HTML for one guide page. Mirrors the legacy
    `generateModuleGuidePage` shape: standard topbar/sidebar/footer
    chrome with the rendered markdown body wrapped in
    `<article class="guide-article structdoc">`.
    """
  pub fn render_guide_page(slug :: String, markdown_text :: String, project_name :: String, project_version :: String, source_url :: String, structs :: [String], protocols :: [String], unions :: [String], guide_slugs :: [String]) -> String {
    title = title_case(slug)
    body_html = Markdown.to_html(markdown_text)
    article = "<article class=\"guide-article structdoc\">\n" <> body_html <> "</article>\n"
    sidebar_html = sidebar(structs, protocols, unions, guide_slugs, slug, "../", project_name, project_version)
    # Find the struct (if any) whose lowercased last-segment matches
    # this guide's slug. When matched, the topbar shows a
    # Reference/Guide switch with Guide active and the Reference tab
    # linking back to the struct page.
    struct_name = struct_name_for_guide_slug(structs, slug)
    has_struct = String.length(struct_name) > 0
    tab_state = if has_struct { :guide } else { :none }
    ref_url = if has_struct { "../structs/" <> struct_name <> ".html" } else { "" }
    guide_url = if has_struct { "../guides/" <> slug <> ".html" } else { "" }
    struct_page_with_tabs(project_name, project_version, title, "../", source_url, sidebar_html, article, "", tab_state, ref_url, guide_url)
  }

  @doc = """
    Find the qualified struct name whose lowercased last-segment
    matches `slug`. Returns the empty string when no struct matches —
    that signal collapses the topbar tab switch on the corresponding
    guide page (no Reference target to link at).
    """
  pub fn struct_name_for_guide_slug(structs :: [String], slug :: String) -> String {
    if List.empty?(structs) {
      ""
    } else {
      head = List.head(structs)
      tail = List.tail(structs)
      if slug_for_struct_name(head) == slug {
        head
      } else {
        struct_name_for_guide_slug(tail, slug)
      }
    }
  }

  @doc = """
    Derive the guide slug for a struct by lowercasing the last
    dotted segment of its qualified name: `Integer` -> `integer`,
    `Zap.Doc.Builder` -> `builder`. The lowercase walk only touches
    ASCII A-Z; non-ASCII bytes pass through unchanged so the slug
    matches the file-naming convention `guides/<slug>.md`.
    """
  pub fn slug_for_struct_name(name :: String) -> String {
    last_segment = last_dotted_segment(name)
    downcase_ascii(last_segment)
  }

  pub fn last_dotted_segment(name :: String) -> String {
    last_dotted_walk(name, String.length(name) - 1, String.length(name))
  }

  pub fn last_dotted_walk(name :: String, index :: i64, end_index :: i64) -> String {
    if index < 0 {
      name
    } else {
      if String.byte_at(name, index) == "." {
        String.slice(name, index + 1, end_index)
      } else {
        last_dotted_walk(name, index - 1, end_index)
      }
    }
  }

  pub fn downcase_ascii(text :: String) -> String {
    downcase_walk(text, 0, String.length(text), "")
  }

  pub fn downcase_walk(text :: String, index :: i64, end_index :: i64, acc :: String) -> String {
    if index >= end_index {
      acc
    } else {
      ch = String.byte_at(text, index)
      downcase_walk(text, index + 1, end_index, acc <> downcase_byte(ch))
    }
  }

  pub fn downcase_byte(ch :: String) -> String {
    if ch >= "A" and ch <= "Z" {
      String.byte_at("abcdefghijklmnopqrstuvwxyz", downcase_index(ch))
    } else {
      ch
    }
  }

  pub fn downcase_index(ch :: String) -> i64 {
    downcase_index_walk(ch, 0)
  }

  pub fn downcase_index_walk(ch :: String, idx :: i64) -> i64 {
    if idx >= 26 {
      0
    } else {
      if String.byte_at("ABCDEFGHIJKLMNOPQRSTUVWXYZ", idx) == ch {
        idx
      } else {
        downcase_index_walk(ch, idx + 1)
      }
    }
  }

  @doc = """
    Compose the docs landing page. When `landing_md` is non-empty it
    is rendered through `Markdown.to_html` and used as the main
    column body — the legacy generator fed the project's
    `README.md` here. When `landing_md` is empty the renderer falls
    back to a struct-card grid with the project name, version pill,
    and one card per declared struct (legacy `appendDefaultLanding`).
    """
  pub fn render_index_page(structs :: [String], protocols :: [String], unions :: [String], guide_slugs :: [String], struct_summaries :: [%{Atom => Term}], project_name :: String, project_version :: String, source_url :: String, landing_md :: String) -> String {
    content = if String.length(landing_md) == 0 {
      render_default_landing(structs, struct_summaries, project_name, project_version)
    } else {
      "<div class=\"structdoc\">\n" <> Markdown.to_html(landing_md) <> "</div>\n"
    }
    sidebar_html = sidebar(structs, protocols, unions, guide_slugs, "", "", project_name, project_version)
    struct_page(project_name, project_version, project_name, "", source_url, sidebar_html, content, "")
  }

  @doc = """
    Default landing-page body used when no `landing_md` is supplied.
    Renders the project name as `<h1>`, an optional version pill, and
    a grid of struct cards — one per public struct, each with the
    first sentence of its `@doc` as the lead summary. Mirrors the
    legacy `appendDefaultLanding` Zig helper.
    """
  pub fn render_default_landing(structs :: [String], struct_summaries :: [%{Atom => Term}], project_name :: String, project_version :: String) -> String {
    title = "<h1>" <> escape_html(project_name) <> "</h1>\n"
    version_pill = if String.length(project_version) == 0 {
      ""
    } else {
      "<p class=\"version\">v" <> escape_html(project_version) <> "</p>\n"
    }
    cards_open = "<h2>Declarations</h2>\n<div class=\"struct-list\">\n"
    cards = render_struct_cards(struct_summaries, "")
    title <> version_pill <> cards_open <> cards <> "</div>\n"
  }

  pub fn render_struct_cards(summaries :: [%{Atom => Term}], acc :: String) -> String {
    if List.empty?(summaries) {
      acc
    } else {
      render_struct_cards(List.tail(summaries), acc <> render_struct_card(List.head(summaries)))
    }
  }

  pub fn render_struct_card(entry :: %{Atom => Term}) -> String {
    name = Map.get(entry, :name, "")
    summary_p = render_struct_card_summary(first_sentence(Map.get(entry, :doc, "")))
    "<div class=\"struct-card\">\n<h3><a href=\"structs/" <> escape_html(name) <> ".html\">" <> escape_html(name) <> "</a></h3>\n" <> summary_p <> "</div>\n"
  }

  pub fn render_struct_card_summary(summary :: String) -> String {
    if String.length(summary) == 0 {
      ""
    } else {
      "<p>" <> escape_html(summary) <> "</p>\n"
    }
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
      link = "<li><a href=\"structs/" <> escape_html(head) <> ".html\">" <> escape_html(head) <> "</a></li>\n"
      render_index_links(tail, acc <> link)
    }
  }

  @doc = """
    Recursively pull `:name` from each summary, accumulating into a
    list of strings. Used to build the sidebar name lists from a
    single-pass walk so callers don't have to maintain three parallel
    arrays of names alongside their summaries.
    """
  @doc = """
    Insertion-sort a list of qualified-name strings into ascending
    alphabetical order. Used so the sidebar groups (`Structs`,
    `Protocols`, `Unions`) and the index page list members in a
    predictable order regardless of reflection iteration order.
    """
  pub fn sort_names_alpha(names :: [String]) -> [String] {
    sort_names_walk(names, [] :: [String])
  }

  pub fn sort_names_walk(remaining :: [String], sorted :: [String]) -> [String] {
    if List.empty?(remaining) {
      sorted
    } else {
      head = List.head(remaining)
      tail = List.tail(remaining)
      sort_names_walk(tail, insert_name_alpha(sorted, head, [] :: [String]))
    }
  }

  pub fn insert_name_alpha(sorted :: [String], item :: String, prefix :: [String]) -> [String] {
    if List.empty?(sorted) {
      List.append(prefix, item)
    } else {
      head = List.head(sorted)
      tail = List.tail(sorted)
      if string_lt?(item, head) {
        list_concat_strings(List.append(prefix, item), sorted)
      } else {
        insert_name_alpha(tail, item, List.append(prefix, head))
      }
    }
  }

  pub fn list_concat_strings(left :: [String], right :: [String]) -> [String] {
    if List.empty?(right) {
      left
    } else {
      list_concat_strings(List.append(left, List.head(right)), List.tail(right))
    }
  }

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
  pub fn write_summary_pages(out_dir :: String, summaries :: [%{Atom => Term}], kind :: Atom, project_name :: String, project_version :: String, source_url :: String, structs :: [String], protocols :: [String], unions :: [String], guide_slugs :: [String], all_functions :: [%{Atom => Term}], all_macros :: [%{Atom => Term}], all_impls :: [%{Atom => Term}], all_variants :: [%{Atom => Term}], all_required :: [%{Atom => Term}], acc :: i64) -> i64 {
    if List.empty?(summaries) {
      acc
    } else {
      head = List.head(summaries)
      tail = List.tail(summaries)
      name = Map.get(head, :name, "")
      html = render_summary_page(head, kind, project_name, project_version, source_url, structs, protocols, unions, guide_slugs, all_functions, all_macros, all_impls, all_variants, all_required)
      path = out_dir <> "/structs/" <> name <> ".html"
      ok = File.write(path, html)
      if ok {
        write_summary_pages(out_dir, tail, kind, project_name, project_version, source_url, structs, protocols, unions, guide_slugs, all_functions, all_macros, all_impls, all_variants, all_required, acc + 1)
      } else {
        write_summary_pages(out_dir, tail, kind, project_name, project_version, source_url, structs, protocols, unions, guide_slugs, all_functions, all_macros, all_impls, all_variants, all_required, acc)
      }
    }
  }

}

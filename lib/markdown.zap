@doc = """
  Render the subset of Markdown the Zap documentation generator emits
  into HTML strings. Supports paragraphs, ATX headings (`##`, `###`,
  `####`), unordered lists (`- item` or `* item`), fenced code blocks
  with optional language tags, inline `code spans`, and HTML escaping
  of body text.

  The renderer is a small block-then-inline state machine. Block parsing
  walks the input line by line, tracking which block construct is open
  (`:start`, `:paragraph`, `:list`, `:code`) and emitting close/open
  tags as the line shape changes. Inline rendering escapes HTML special
  characters and recognizes backtick-delimited code spans.
  """

pub struct Markdown {
  @doc = """
    Render `markdown` as HTML. Returns the empty string for empty input.
    """

  pub fn to_html(markdown :: String) -> String {
    if String.length(markdown) == 0 {
      ""
    } else {
      render_lines(String.split(markdown, "\n"), :start, "", "")
    }
  }

  @doc = """
    Walk the input line by line, tracking which block construct is
    currently open and emitting the right close/open tags as the line
    shape changes. `mode` is one of `:start`, `:paragraph`, `:list`,
    or `:code`. `code_lang` carries the language tag for an open code
    block; it's the empty string in any other mode.
    """

  pub fn render_lines(lines :: [String], mode :: Atom, code_lang :: String, acc :: String) -> String {
    case lines {
      [] -> close_block(mode, acc)
      [line | rest] -> render_line(line, rest, mode, code_lang, acc)
    }
  }

  pub fn render_line(line :: String, rest :: [String], mode :: Atom, code_lang :: String, acc :: String) -> String {
    if mode == :code_open {
      if String.starts_with?(String.trim(line), "```") {
        render_lines(rest, :start, "", acc <> "</code></pre>\n")
      } else {
        render_lines(rest, :code, code_lang, acc <> render_code_line(line, code_lang))
      }
    } else {
      if mode == :code {
        if String.starts_with?(String.trim(line), "```") {
          render_lines(rest, :start, "", acc <> "</code></pre>\n")
        } else {
          render_lines(rest, :code, code_lang, acc <> "\n" <> render_code_line(line, code_lang))
        }
      } else {
        classify_line(line, rest, mode, acc)
      }
    }
  }

  @doc = """
    Render a single line of code, applying Zap syntax highlighting
    when the surrounding fenced block is tagged `language-zap`,
    `zap`, `elixir`, or has no tag (the doc generator's default).
    Other languages emit only HTML-escaped text so the surrounding
    `<pre><code>` reflects the source verbatim.
    """
  pub fn render_code_line(line :: String, code_lang :: String) -> String {
    if zap_lang?(code_lang) {
      highlight_zap_line(line)
    } else {
      escape_html(line)
    }
  }

  pub fn zap_lang?(code_lang :: String) -> Bool {
    code_lang == "zap" or code_lang == "elixir"
  }

  @doc = """
    Recognize the line's block kind for non-code modes and dispatch.
    Order matters: code-fence opens before headings, headings before
    list items, list items before paragraphs.
    """

  pub fn classify_line(line :: String, rest :: [String], mode :: Atom, acc :: String) -> String {
    if is_blank_line?(line) {
      render_lines(rest, :start, "", close_block(mode, acc))
    } else {
      if String.starts_with?(String.trim(line), "```") {
        open_code_block(line, rest, mode, acc)
      } else {
        if mode == :indent_code {
          if is_indented_code_line?(line) {
            render_lines(rest, :indent_code, "", acc <> "\n" <> highlight_zap_line(strip_indent4(line)))
          } else {
            classify_after_close(line, rest, :start, close_block(:indent_code, acc))
          }
        } else {
          if mode == :start and is_indented_code_line?(line) {
            render_lines(rest, :indent_code, "zap", acc <> "<pre><code class=\"language-zap\">" <> highlight_zap_line(strip_indent4(line)))
          } else {
            classify_after_close(line, rest, mode, acc)
          }
        }
      }
    }
  }

  @doc = """
    Continue line classification after a code-block close. Identical to the
    inner heading/list/table/paragraph cascade in `classify_line` but without
    the `is_indented_code_line?` re-check, since the caller has already
    decided this line ended the indented code run.
    """
  pub fn classify_after_close(line :: String, rest :: [String], mode :: Atom, acc :: String) -> String {
    if String.starts_with?(line, "#### ") {
      render_lines(rest, :start, "", close_block(mode, acc) <> render_heading("h4", String.slice(line, 5, String.length(line))))
    } else {
      if String.starts_with?(line, "### ") {
        render_lines(rest, :start, "", close_block(mode, acc) <> render_heading("h3", String.slice(line, 4, String.length(line))))
      } else {
        if String.starts_with?(line, "## ") {
          render_lines(rest, :start, "", close_block(mode, acc) <> render_heading("h2", String.slice(line, 3, String.length(line))))
        } else {
          if is_list_item?(line) {
            render_list_item(line, rest, mode, acc)
          } else {
            if is_table_header?(line, rest) {
              open_table(line, rest, mode, acc)
            } else {
              if mode == :table {
                if is_pipe_row?(line) {
                  render_lines(rest, :table, "", acc <> render_table_row(line, "td"))
                } else {
                  render_paragraph_line(line, rest, :start, close_block(:table, acc))
                }
              } else {
                render_paragraph_line(line, rest, mode, acc)
              }
            }
          }
        }
      }
    }
  }

  @doc = """
    A line qualifies as part of an indented code block when its first
    four characters are spaces (or a tab). Mirrors the CommonMark
    rule used to render `@doc` Example blocks as `<pre><code>`.
    """
  pub fn is_indented_code_line?(line :: String) -> Bool {
    if String.length(line) < 4 {
      false
    } else {
      String.starts_with?(line, "    ") or String.starts_with?(line, "\t")
    }
  }

  pub fn strip_indent4(line :: String) -> String {
    if String.starts_with?(line, "    ") {
      String.slice(line, 4, String.length(line))
    } else {
      if String.starts_with?(line, "\t") {
        String.slice(line, 1, String.length(line))
      } else {
        line
      }
    }
  }

  @doc = """
    A pipe-table header is detected by the next line being a separator
    row (`| --- | --- |`). Matching the GFM-flavored shape the doc
    generator emits.
    """

  pub fn is_table_header?(line :: String, rest :: [String]) -> Bool {
    if is_pipe_row?(line) {
      case rest {
        [] -> false
        [next | _] -> is_table_separator?(next)
      }
    } else {
      false
    }
  }

  pub fn is_pipe_row?(line :: String) -> Bool {
    String.starts_with?(String.trim(line), "|")
  }

  pub fn is_table_separator?(line :: String) -> Bool {
    trimmed = String.trim(line)
    String.starts_with?(trimmed, "|") and String.contains?(trimmed, "---")
  }

  pub fn open_table(line :: String, rest :: [String], mode :: Atom, acc :: String) -> String {
    closed = close_block(mode, acc)
    head = "<table class=\"markdown-table\">\n<thead>\n" <> render_table_row(line, "th") <> "</thead>\n<tbody>\n"
    case rest {
      [] -> close_block(:table, closed <> head)
      [_separator | body_lines] -> render_lines(body_lines, :table, "", closed <> head)
    }
  }

  pub fn render_table_row(line :: String, cell_tag :: String) -> String {
    cells = parse_pipe_cells(line)
    "<tr>" <> render_table_cells(cells, cell_tag, "") <> "</tr>\n"
  }

  pub fn render_table_cells(cells :: [String], cell_tag :: String, acc :: String) -> String {
    case cells {
      [] -> acc
      [cell | rest] -> render_table_cells(rest, cell_tag, acc <> "<" <> cell_tag <> ">" <> render_inline(cell) <> "</" <> cell_tag <> ">")
    }
  }

  @doc = """
    Split a pipe-row into its cells, dropping the leading and trailing
    pipe characters. Whitespace inside each cell is trimmed so
    `| Field | Description |` produces `["Field", "Description"]`.
    """

  pub fn parse_pipe_cells(line :: String) -> [String] {
    trimmed = String.trim(line)
    inner = strip_pipes(trimmed)
    parts = String.split(inner, "|")
    trim_each(parts, [])
  }

  pub fn strip_pipes(line :: String) -> String {
    a = if String.starts_with?(line, "|") {
      String.slice(line, 1, String.length(line))
    } else {
      line
    }
    if String.ends_with?(a, "|") {
      String.slice(a, 0, String.length(a) - 1)
    } else {
      a
    }
  }

  pub fn trim_each(parts :: [String], acc :: [String]) -> [String] {
    case parts {
      [] -> List.reverse(acc)
      [head | tail] -> trim_each(tail, [String.trim(head) | acc])
    }
  }

  pub fn open_code_block(line :: String, rest :: [String], mode :: Atom, acc :: String) -> String {
    trimmed = String.trim(line)
    lang = String.slice(trimmed, 3, String.length(trimmed))
    closed = close_block(mode, acc)
    if String.length(lang) == 0 {
      render_lines(rest, :code_open, "", closed <> "<pre><code>")
    } else {
      render_lines(rest, :code_open, lang, closed <> "<pre><code class=\"language-" <> lang <> "\">")
    }
  }

  pub fn render_list_item(line :: String, rest :: [String], mode :: Atom, acc :: String) -> String {
    text = list_item_text(line)
    if mode == :list {
      render_lines(rest, :list, "", acc <> "</li>\n<li>" <> render_inline(text))
    } else {
      render_lines(rest, :list, "", close_block(mode, acc) <> "<ul>\n<li>" <> render_inline(text))
    }
  }

  pub fn render_paragraph_line(line :: String, rest :: [String], mode :: Atom, acc :: String) -> String {
    if mode == :paragraph {
      render_lines(rest, :paragraph, "", acc <> "\n" <> render_inline(line))
    } else {
      render_lines(rest, :paragraph, "", close_block(mode, acc) <> "<p>" <> render_inline(line))
    }
  }

  pub fn close_block(mode :: Atom, acc :: String) -> String {
    if mode == :paragraph {
      acc <> "</p>\n"
    } else {
      if mode == :list {
        acc <> "</li>\n</ul>\n"
      } else {
        if mode == :table {
          acc <> "</tbody>\n</table>\n"
        } else {
          if mode == :indent_code {
            acc <> "</code></pre>\n"
          } else {
            acc
          }
        }
      }
    }
  }

  pub fn render_heading(tag :: String, text :: String) -> String {
    "<" <> tag <> ">" <> render_inline(text) <> "</" <> tag <> ">\n"
  }

  pub fn is_blank_line?(line :: String) -> Bool {
    String.length(String.trim(line)) == 0
  }

  pub fn is_list_item?(line :: String) -> Bool {
    String.starts_with?(line, "- ") or String.starts_with?(line, "* ")
  }

  pub fn list_item_text(line :: String) -> String {
    String.slice(line, 2, String.length(line))
  }

  @doc = """
    Render a single inline run: HTML-escape body text, but recognize
    backtick-delimited code spans and wrap them as `<code>`. Backticks
    nest one level — content between matching pairs is escaped but
    not further parsed for inline syntax.
    """

  pub fn render_inline(text :: String) -> String {
    inline_walk(text, 0, String.length(text), false, "")
  }

  pub fn inline_walk(text :: String, index :: i64, end :: i64, in_code :: Bool, acc :: String) -> String {
    if index >= end {
      acc
    } else {
      ch = String.byte_at(text, index)
      if ch == "`" {
        if in_code {
          inline_walk(text, index + 1, end, false, acc <> "</code>")
        } else {
          inline_walk(text, index + 1, end, true, acc <> "<code>")
        }
      } else {
        inline_walk(text, index + 1, end, in_code, acc <> escape_one(ch))
      }
    }
  }

  pub fn escape_html(text :: String) -> String {
    escape_chars(text, 0, String.length(text), "")
  }

  pub fn escape_chars(text :: String, index :: i64, end :: i64, acc :: String) -> String {
    if index >= end {
      acc
    } else {
      ch = String.byte_at(text, index)
      escape_chars(text, index + 1, end, acc <> escape_one(ch))
    }
  }

  pub fn escape_one(ch :: String) -> String {
    if ch == "&" {
      "&amp;"
    } else {
      if ch == "<" {
        "&lt;"
      } else {
        if ch == ">" {
          "&gt;"
        } else {
          if ch == "\"" {
            "&quot;"
          } else {
            ch
          }
        }
      }
    }
  }

  @doc = """
    Highlight one line of Zap source as HTML, wrapping classified
    tokens in `<span class="hl-...">` so the bundled stylesheet can
    color them. Recognises `#`-line comments, double-quoted strings
    (including triple-quoted heredoc fragments), `:atom` literals,
    numeric literals, the canonical keyword set, and the operator
    set the legacy generator highlighted (`->`, `::`, `|>`, `~>`,
    `<>`, `<-`, `==`, `!=`, `>=`, `<=`, `=`, `+`, `-`, `*`, `/`,
    `>`, `<`, `|`). Unrecognised text passes through HTML-escaped
    so non-Zap fragments still render correctly.
    """
  pub fn highlight_zap_line(line :: String) -> String {
    highlight_walk(line, 0, String.length(line), "")
  }

  pub fn highlight_walk(line :: String, index :: i64, end_index :: i64, acc :: String) -> String {
    if index >= end_index {
      acc
    } else {
      ch = String.byte_at(line, index)
      if ch == "#" {
        rest_of_line = String.slice(line, index, end_index)
        acc <> "<span class=\"hl-comment\">" <> escape_html(rest_of_line) <> "</span>"
      } else {
        if ch == "\"" {
          highlight_string(line, index, end_index, acc)
        } else {
          if ch == ":" and index + 1 < end_index and is_atom_start_byte?(String.byte_at(line, index + 1)) {
            highlight_atom(line, index, end_index, acc)
          } else {
            highlight_after_atom_check(line, index, end_index, acc, ch)
          }
        }
      }
    }
  }

  pub fn highlight_after_atom_check(line :: String, index :: i64, end_index :: i64, acc :: String, ch :: String) -> String {
    if is_digit_byte?(ch) {
      highlight_number(line, index, end_index, acc)
    } else {
      if is_alpha_byte?(ch) or ch == "_" {
        highlight_word(line, index, end_index, acc)
      } else {
        highlight_op_or_passthrough(line, index, end_index, acc)
      }
    }
  }

  pub fn highlight_op_or_passthrough(line :: String, index :: i64, end_index :: i64, acc :: String) -> String {
    if index + 1 < end_index and two_char_op?(String.byte_at(line, index), String.byte_at(line, index + 1)) {
      op_chars = String.slice(line, index, index + 2)
      highlight_walk(line, index + 2, end_index, acc <> "<span class=\"hl-op\">" <> escape_html(op_chars) <> "</span>")
    } else {
      ch = String.byte_at(line, index)
      if single_char_op?(ch) {
        highlight_walk(line, index + 1, end_index, acc <> "<span class=\"hl-op\">" <> escape_one(ch) <> "</span>")
      } else {
        highlight_walk(line, index + 1, end_index, acc <> escape_one(ch))
      }
    }
  }

  pub fn highlight_string(line :: String, index :: i64, end_index :: i64, acc :: String) -> String {
    string_end = find_string_end(line, index + 1, end_index)
    chunk = String.slice(line, index, string_end)
    highlight_walk(line, string_end, end_index, acc <> "<span class=\"hl-string\">" <> escape_html(chunk) <> "</span>")
  }

  pub fn find_string_end(line :: String, index :: i64, end_index :: i64) -> i64 {
    if index >= end_index {
      end_index
    } else {
      ch = String.byte_at(line, index)
      if ch == "\"" {
        index + 1
      } else {
        if ch == "\\" and index + 1 < end_index {
          find_string_end(line, index + 2, end_index)
        } else {
          find_string_end(line, index + 1, end_index)
        }
      }
    }
  }

  pub fn highlight_atom(line :: String, index :: i64, end_index :: i64, acc :: String) -> String {
    atom_end = scan_atom_end(line, index + 1, end_index)
    chunk = String.slice(line, index, atom_end)
    highlight_walk(line, atom_end, end_index, acc <> "<span class=\"hl-atom\">" <> escape_html(chunk) <> "</span>")
  }

  pub fn scan_atom_end(line :: String, index :: i64, end_index :: i64) -> i64 {
    if index >= end_index {
      end_index
    } else {
      ch = String.byte_at(line, index)
      if is_ident_continue?(ch) or ch == "?" or ch == "!" {
        scan_atom_end(line, index + 1, end_index)
      } else {
        index
      }
    }
  }

  pub fn highlight_number(line :: String, index :: i64, end_index :: i64, acc :: String) -> String {
    num_end = scan_number_end(line, index + 1, end_index)
    chunk = String.slice(line, index, num_end)
    highlight_walk(line, num_end, end_index, acc <> "<span class=\"hl-number\">" <> escape_html(chunk) <> "</span>")
  }

  pub fn scan_number_end(line :: String, index :: i64, end_index :: i64) -> i64 {
    if index >= end_index {
      end_index
    } else {
      ch = String.byte_at(line, index)
      if is_digit_byte?(ch) or ch == "." or ch == "_" {
        scan_number_end(line, index + 1, end_index)
      } else {
        index
      }
    }
  }

  pub fn highlight_word(line :: String, index :: i64, end_index :: i64, acc :: String) -> String {
    word_end = scan_word_end(line, index, end_index)
    word = String.slice(line, index, word_end)
    if is_zap_keyword?(word) {
      highlight_walk(line, word_end, end_index, acc <> "<span class=\"hl-keyword\">" <> escape_html(word) <> "</span>")
    } else {
      highlight_walk(line, word_end, end_index, acc <> escape_html(word))
    }
  }

  pub fn scan_word_end(line :: String, index :: i64, end_index :: i64) -> i64 {
    if index >= end_index {
      end_index
    } else {
      ch = String.byte_at(line, index)
      if is_ident_continue?(ch) or ch == "?" or ch == "!" {
        scan_word_end(line, index + 1, end_index)
      } else {
        index
      }
    }
  }

  pub fn is_digit_byte?(ch :: String) -> Bool {
    ch == "0" or ch == "1" or ch == "2" or ch == "3" or ch == "4" or ch == "5" or ch == "6" or ch == "7" or ch == "8" or ch == "9"
  }

  pub fn is_atom_start_byte?(ch :: String) -> Bool {
    is_lower_byte?(ch) or ch == "_"
  }

  pub fn is_lower_byte?(ch :: String) -> Bool {
    ch >= "a" and ch <= "z"
  }

  pub fn is_upper_byte?(ch :: String) -> Bool {
    ch >= "A" and ch <= "Z"
  }

  pub fn is_alpha_byte?(ch :: String) -> Bool {
    is_lower_byte?(ch) or is_upper_byte?(ch)
  }

  pub fn is_ident_continue?(ch :: String) -> Bool {
    is_alpha_byte?(ch) or is_digit_byte?(ch) or ch == "_"
  }

  pub fn two_char_op?(c1 :: String, c2 :: String) -> Bool {
    if c1 == "-" and c2 == ">" {
      true
    } else {
      if c1 == ":" and c2 == ":" {
        true
      } else {
        if c1 == "|" and c2 == ">" {
          true
        } else {
          two_char_op_more?(c1, c2)
        }
      }
    }
  }

  pub fn two_char_op_more?(c1 :: String, c2 :: String) -> Bool {
    if c1 == "~" and c2 == ">" {
      true
    } else {
      if c1 == "<" and c2 == ">" {
        true
      } else {
        if c1 == "<" and c2 == "-" {
          true
        } else {
          two_char_op_compare?(c1, c2)
        }
      }
    }
  }

  pub fn two_char_op_compare?(c1 :: String, c2 :: String) -> Bool {
    if c1 == "=" and c2 == "=" {
      true
    } else {
      if c1 == "!" and c2 == "=" {
        true
      } else {
        if c1 == ">" and c2 == "=" {
          true
        } else {
          if c1 == "<" and c2 == "=" {
            true
          } else {
            false
          }
        }
      }
    }
  }

  pub fn single_char_op?(ch :: String) -> Bool {
    ch == "=" or ch == "+" or ch == "*" or ch == "/" or ch == ">" or ch == "<" or ch == "|"
  }

  pub fn is_zap_keyword?(word :: String) -> Bool {
    if word == "pub" or word == "fn" or word == "macro" or word == "struct" or word == "case" {
      true
    } else {
      if word == "if" or word == "else" or word == "use" or word == "union" or word == "when" {
        true
      } else {
        is_zap_keyword_more?(word)
      }
    }
  }

  pub fn is_zap_keyword_more?(word :: String) -> Bool {
    if word == "for" or word == "in" or word == "cond" or word == "do" or word == "end" {
      true
    } else {
      if word == "unless" or word == "and" or word == "or" or word == "not" or word == "import" {
        true
      } else {
        is_zap_keyword_misc?(word)
      }
    }
  }

  pub fn is_zap_keyword_misc?(word :: String) -> Bool {
    if word == "alias" or word == "quote" or word == "unquote" or word == "panic" or word == "extends" {
      true
    } else {
      if word == "describe" or word == "test" or word == "assert" or word == "reject" or word == "impl" {
        true
      } else {
        false
      }
    }
  }
}

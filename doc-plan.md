# `zap doc` Implementation Plan

## Overview

`zap doc` generates a static HTML documentation site and Markdown files from `@fndoc` and `@structdoc` attributes in `.zap` source files. It reuses the existing parser and collector pipeline — no new parsing logic needed. The output is a self-contained `docs/` directory.

## Command

```sh
zap doc                    # Generate docs for :doc target
zap doc --no-deps          # Skip dependency documentation
zap doc --format markdown  # Markdown only (no HTML)
```

## Configuration

All doc config lives in `build.zap` as a `:doc` target:

```zap
pub struct Zap.Builder {
  pub fn manifest(env :: Zap.Env) -> Zap.Manifest {
    case env.target {
      :doc ->
        %Zap.Manifest{
          name: "zap_stdlib",
          version: "0.1.0",
          kind: :doc,
          source_url: "https://github.com/trycog/zap",
          landing_page: "README.md",
          doc_groups: [
            {"Getting Started", ["guides/installation.md", "guides/first-project.md"]},
            {"Advanced", ["guides/macros.md"]}
          ],
          deps: [{:zap_stdlib, {:path, "lib"}}]
        }
      :test ->
        %Zap.Manifest{
          name: "zap_test",
          version: "0.1.0",
          kind: :bin,
          root: "Test.TestRunner.main/1",
          deps: [{:zap_stdlib, {:path, "lib"}}]
        }
    }
  }
}
```

### New Manifest Fields

| Field | Type | Default | Purpose |
|-------|------|---------|---------|
| `source_url` | String | `""` | Base URL for source links (e.g., `https://github.com/user/repo`) |
| `landing_page` | String | `""` | Path to Markdown file used as index page (e.g., `README.md`) |
| `doc_groups` | [{String, [String]}] | `[]` | Additional documentation pages grouped by section |

### New Manifest Kind

`kind: :doc` — signals that this target produces documentation, not a binary or library. The build pipeline skips compilation and runs doc generation instead.

## Architecture

### Pipeline

```
zap doc
  │
  ├── 1. Parse CLI args (reuse parseTargetArgs)
  ├── 2. Discover build.zap, evaluate manifest with target :doc (CTFE)
  ├── 3. Discover source files (reuse import-driven discovery)
  ├── 4. Parse all .zap files (reuse parser)
  ├── 5. Collect modules/functions/attributes (reuse collector)
  │
  ├── 6. Extract documentation data from scope graph:
  │      ├── ModuleEntry → @structdoc, module name
  │      ├── FunctionFamily → @fndoc, name, arity, params, types, visibility
  │      ├── MacroFamily → @fndoc, name, arity, params
  │      └── TypeEntry → struct/union definitions
  │
  ├── 7. Build DocModule tree (intermediate representation)
  │
  ├── 8. Render outputs:
  │      ├── HTML: static site with index, module pages, search, dark mode
  │      └── Markdown: one .md file per module
  │
  └── 9. Write to docs/ directory
```

### No New Parsing

The existing pipeline (parser → collector → scope graph) already:
- Parses `@fndoc` and `@structdoc` as `AttributeDecl` AST nodes
- Associates `@fndoc` with the next `FunctionFamily` or `MacroFamily`
- Associates `@structdoc` with the `ModuleEntry`
- Stores attribute values (string heredocs) accessible via `Attribute.value`
- Tracks function signatures with parameter names, types, and return types

The doc generator only needs to **read** the scope graph after collection. It does not run type checking, HIR, IR, or ZIR.

### New Files

| File | Purpose |
|------|---------|
| `src/doc_generator.zig` | Core doc generation: extract data from scope graph, build doc model, render HTML and Markdown |
| `src/markdown.zig` | Zig wrapper around md4c C library for Markdown → HTML |
| `vendor/md4c/md4c.c` | md4c CommonMark parser (vendored, MIT license) |
| `vendor/md4c/md4c.h` | md4c header |
| `vendor/md4c/md4c-html.c` | md4c HTML renderer |
| `vendor/md4c/md4c-html.h` | md4c HTML renderer header |

### Modified Files

| File | Change |
|------|--------|
| `src/main.zig` | Add `cmdDoc()` command, add `"doc"` to command dispatch and usage |
| `lib/zap/manifest.zap` | Add `source_url`, `landing_page`, `doc_groups` fields |
| `build.zap` | Add `:doc` target |
| `build.zig` | Add md4c C sources to build |

## Doc Data Model

The intermediate representation between scope graph and rendering:

```
DocProject
  name: String
  version: String
  source_url: String
  landing_page_html: String          # rendered from landing_page markdown
  groups: []DocGroup                  # additional doc pages
  modules: []DocModule

DocGroup
  name: String
  pages: []DocPage

DocPage
  title: String
  path: String
  html: String                        # rendered from markdown file

DocModule
  name: String                        # e.g., "String", "Zest.Case"
  moduledoc: String                   # rendered HTML from @structdoc
  source_file: String                 # e.g., "lib/string.zap"
  functions: []DocFunction
  macros: []DocFunction               # same shape as functions
  types: []DocType

DocFunction
  name: String                        # e.g., "length"
  arity: u32                          # e.g., 1
  signature: String                   # e.g., "length(string :: String) -> i64"
  doc: String                         # rendered HTML from @fndoc
  summary: String                     # first sentence of @fndoc (for summary table)
  source_line: u32                    # line number in source file
  visibility: enum { pub, private }
  group: ?String                      # from @fndoc group: "..." attribute

DocType
  name: String
  fields: []DocField
  doc: String

DocField
  name: String
  type_name: String
  default: ?String
```

## HTML Output Structure

```
docs/
  index.html                 # landing page (from README.md or generated)
  search-index.json          # client-side search data
  style.css                  # all styles
  app.js                     # search + dark mode toggle
  modules/
    String.html
    Integer.html
    Enum.html
    List.html
    Map.html
    ...
  guides/                    # from doc_groups
    installation.html
    first-project.html
    macros.html
  api/                       # markdown output
    String.md
    Integer.md
    ...
```

## HTML Page Design

### Layout

Three-panel layout (left sidebar, content, right TOC):

- **Top bar**: Project name, version, search (Cmd+K), dark/light toggle
- **Left sidebar**: Doc group pages (if any), then all modules listed alphabetically. Current page highlighted. On mobile: hamburger drawer.
- **Content area**: Module page content (max-width 768px)
- **Right sidebar**: "On this page" TOC from h2/h3 headings with scroll-spy. Hidden on mobile.

### Module Page Sections

1. **Module name** as h1
2. **Source file** link (e.g., "lib/string.zap")
3. **@structdoc** rendered as HTML
4. **Summary table** — compact list: `name/arity` | first sentence of `@fndoc`
   - Functions and macros in separate tables
5. **Function details** — for each pub function:
   - `### name(param1, param2)` as anchor heading
   - Signature with types: `(string :: String) -> i64`
   - Full `@fndoc` rendered as HTML
   - `[source]` link → `{source_url}/blob/v{version}/{source_file}#L{line}`
6. **Macro details** — same format
7. **Types** — struct/union definitions with field docs

### CSS

Embedded in a single `style.css`. Features:
- System font stack for prose, monospace for code
- Light and dark themes via CSS custom properties and `data-theme` attribute
- Syntax highlighting for Zap code blocks (built-in, no JS highlighter)
- Responsive breakpoints: 3-panel > 1024px, 2-panel > 768px, 1-panel below
- Aside blocks for `> Note:`, `> Warning:`, `> Tip:` blockquotes

### JavaScript

Minimal `app.js` (~100-200 lines). Features:
- **Cmd+K search**: modal overlay, fuzzy search over `search-index.json`, keyboard navigation
- **Dark mode toggle**: respects `prefers-color-scheme`, persists in localStorage
- **Scroll-spy**: highlights current section in right TOC
- **Copy button**: appears on code blocks

No framework, no build step, no npm. Plain JS.

### Search Index

Generated at build time as `search-index.json`:

```json
[
  {
    "module": "String",
    "type": "module",
    "name": "String",
    "summary": "Functions for working with UTF-8 encoded strings.",
    "url": "modules/String.html"
  },
  {
    "module": "String",
    "type": "function",
    "name": "length/1",
    "summary": "Returns the number of bytes in the given string.",
    "url": "modules/String.html#length/1"
  }
]
```

### Auto-Linking

In rendered `@fndoc` and `@structdoc` Markdown, backtick references to known symbols are auto-linked:

- `` `String.length/1` `` → `<a href="modules/String.html#length/1">String.length/1</a>`
- `` `Enum` `` → `<a href="modules/Enum.html">Enum</a>`
- `` `Map.get/3` `` → `<a href="modules/Map.html#get/3">Map.get/3</a>`

Resolution happens after Markdown rendering, as a post-processing pass over the HTML.

### Source Links

Each function/macro detail section includes a `[source]` link:

```
https://github.com/trycog/zap/blob/v0.1.0/lib/string.zap#L42
```

Format: `{source_url}/blob/v{version}/{source_file}#L{source_line}`

If `source_url` is empty, source links are omitted.

## Markdown Rendering

### md4c (vendored C library)

md4c is a fast, spec-compliant CommonMark parser in C (~4000 lines). MIT licensed.

Supports: paragraphs, headings, code blocks, inline code, bold/italic, links, lists, blockquotes, tables (GFM extension), horizontal rules, images.

Integration:
- Vendor 4 files into `vendor/md4c/`
- Add C sources to `build.zig`
- Create `src/markdown.zig` as a thin Zig wrapper exposing `renderToHtml(markdown: []const u8) -> []const u8`

### Zap Syntax Highlighting

For code blocks tagged as `zap` or with no language tag, apply basic syntax highlighting:

- Keywords: `pub`, `fn`, `macro`, `module`, `case`, `if`, `else`, `use`, `struct`, `true`, `false`, `nil`
- Strings: `"..."`, `"""..."""`
- Comments: `#`
- Atoms: `:name`
- Numbers: integer and float literals
- Operators: `->`, `::`, `|>`, `==`, `!=`, `+`, `-`, etc.

Implemented as a post-processing pass over `<code class="language-zap">` blocks, wrapping tokens in `<span class="kw">`, `<span class="str">`, etc.

## Markdown Output

One `.md` file per module in `docs/api/`:

```markdown
# String

Functions for working with UTF-8 encoded strings.

...full @structdoc...

## Functions

### length/1

```zap
pub fn length(string :: String) -> i64
```

Returns the number of bytes in the given string.

...full @fndoc...

---

### slice/3

...
```

## Implementation Order

### Phase 1: Manifest & Command (small)
1. Add `source_url`, `landing_page`, `doc_groups` fields to `lib/zap/manifest.zap`
2. Add `:doc` target to `build.zap`
3. Add `cmdDoc()` to `src/main.zig` with command dispatch
4. Wire up manifest evaluation (reuse `buildTarget` flow, stop before compilation)

### Phase 2: Doc Extraction (medium)
5. Create `src/doc_generator.zig`
6. Implement scope graph walking: iterate modules, function families, macro families
7. Extract @fndoc/@structdoc string values from attributes
8. Build `DocProject` / `DocModule` / `DocFunction` data model
9. Extract function signatures from AST (param names, types, return type)

### Phase 3: Markdown Rendering (small)
10. Vendor md4c into `vendor/md4c/`
11. Add md4c to `build.zig`
12. Create `src/markdown.zig` wrapper

### Phase 4: HTML Generation (large)
13. HTML templates as comptime strings in `doc_generator.zig`
14. Module page rendering
15. Index/landing page rendering
16. Summary table generation
17. Source link generation
18. Search index generation (`search-index.json`)
19. Auto-linking pass (resolve backtick references to URLs)
20. Zap syntax highlighting pass

### Phase 5: CSS & JS (medium)
21. `style.css` — full stylesheet with light/dark themes, responsive layout
22. `app.js` — search modal, dark mode toggle, scroll-spy, copy buttons

### Phase 6: Extras (small)
23. Doc group page rendering (additional markdown files)
24. Markdown output (`.md` files per module)
25. `--no-deps` flag

### Phase 7: Polish
26. Module auto-grouping in sidebar (by prefix)
27. Mobile responsive testing
28. Accessibility (ARIA labels, keyboard nav, skip links)

## Non-Goals (Initial Version)

- Interactive tutorials (DocC-style)
- Runnable examples / playground
- Doctests (testable examples)
- Version selector
- Type-based search
- ePub output
- Custom themes

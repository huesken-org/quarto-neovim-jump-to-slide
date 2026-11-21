# quarto-jump

Jump from a Quarto preview in the browser (revealjs slides or HTML/website pages)
to the corresponding source in Neovim, and let the browser follow the Neovim cursor.

| In the browser | Effect |
|---|---|
| `Alt+J` | Neovim jumps to the current slide / the section at the top of the viewport |
| `Alt+click` | Neovim jumps to the clicked paragraph, list item, code line, … |
| *(move cursor in Neovim)* | browser goes to the matching slide / scrolls to the element |

You start `quarto preview` yourself, as usual.

## How it works

```
browser (quarto preview)                         Neovim
 quarto-jump.js ── POST /jump {sourceFile,text} ──▶ vim.uv HTTP server (127.0.0.1:7878)
                ◀── SSE "goto" {file,heading,text} ─ CursorMoved (debounced)
```

**Finding the source line (browser → Neovim):**

1. The browser sends the text of the clicked element (or the slide heading) and a
   `sourceFile`: the nearest `data-source-file` attribute, falling back to the
   page's input file (added by the extension's filter).
2. Neovim looks for the text in `sourceFile`. If it isn't found there (e.g. the
   text comes from an `{{< include >}}`), it searches **all** `.qmd/.md/.Rmd` files
   of the project: `git ls-files` (so gitignored generated files are skipped), or a
   directory walk outside git.
3. Matching: both sides drop markup (attributes `{…}`, shortcodes, link targets,
   html tags), get lowercased and split into words. The best match is the longest
   run of consecutive words. Several equally good matches → quickfix list.

**Following the cursor (Neovim → browser):** Neovim sends the file, the nearest
heading above the cursor and the words of the current line. The page searches
elements belonging to that file (all elements if none do) for the line text,
then the heading, then falls back to the n-th heading of the file.
On website pages it navigates to the page of the file if it exists.

## Installation

### Neovim (≥ 0.11)

lazy.nvim:

```lua
{
  dir = "~/projects/huesken-consulting/training/quarto-neovim-jump-to-slide",
  ft = { "quarto", "markdown" },
  opts = {
    -- port = 7878,
    -- sync = true,            -- browser follows cursor
    -- autostart = true,       -- start server when a file in a Quarto project is opened
    -- root = function() return vim.fn.getcwd() end,
    -- on_jump = function(result) end,  -- e.g. raise the terminal window
  },
}
```

Commands: `:QuartoJumpStart [port]`, `:QuartoJumpStop`, `:QuartoJumpStatus`,
`:QuartoJumpSync [on|off|toggle]`, `:QuartoJumpShow` (push the cursor position now).

Only one Neovim can own the port. The others warn on autostart; use
`:QuartoJumpStop` in one and `:QuartoJumpStart` in the other to switch.

### Quarto extension

Copy `_extensions/quarto-jump` into the project's `_extensions/` folder (Quarto does
**not** follow symlinked extensions) and add the filter:

```yaml
filters:
  - quarto-jump
```

The script only becomes active on pages served from `localhost`, so it's safe to
leave in for published builds. Disable it with `quarto-jump: false`; options:

```yaml
quarto-jump:
  port: 7878
  key: j        # Alt+J
```

`data-source-file` attributes are optional. They make the search more precise when
one rendered document is assembled from many files. Put them on headings or on any
ancestor element, e.g. with a pre-render script that wraps each part in
`::: {.heading-attributes source-file="path/part.qmd"}` plus a filter that copies
the attribute onto the headings.

### WSL

The server binds to `127.0.0.1` inside WSL. A browser on Windows reaches it through
WSL's localhost forwarding, the same way it reaches `quarto preview`.

## Tests

```sh
test/run.sh [path/to/quarto-project]
```

Runs the Neovim server/search integration test (headless Neovim + curl) and the
browser-side matching test (jsdom) against real rendered HTML.

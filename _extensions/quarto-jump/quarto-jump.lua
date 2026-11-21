-- quarto-jump: inject the browser side of the Neovim jump/sync plugin.
--
-- Adds quarto-jump.js to every HTML page (html, revealjs, websites) and
-- tells it the port of the Neovim server and the page's input file (fallback
-- for elements without a data-source-file attribute).
--
-- Options (document or _quarto.yml):
--   quarto-jump: false            # disable
--   quarto-jump:
--     port: 7878
--     key: j                      # Alt+<key> jumps to the current slide/section

local function relative(path)
  local dir = quarto.project and quarto.project.directory
  if dir and dir ~= "" then
    dir = dir:gsub("/+$", "")
    if path:sub(1, #dir + 1) == dir .. "/" then
      return path:sub(#dir + 2)
    end
  end
  return path
end

function Meta(meta)
  if not quarto.doc.is_format("html:js") then return nil end

  local opts = meta["quarto-jump"]
  if opts == false then return nil end
  local cfg = { port = 7878, key = "j" }
  if type(opts) == "table" then
    if opts.port then cfg.port = tonumber(pandoc.utils.stringify(opts.port)) or cfg.port end
    if opts.key then cfg.key = pandoc.utils.stringify(opts.key) end
  end
  if quarto.doc.input_file then
    cfg.source = relative(quarto.doc.input_file)
  end

  quarto.doc.add_html_dependency({
    name = "quarto-jump",
    version = "0.1.0",
    scripts = { "quarto-jump.js" },
  })
  quarto.doc.include_text("in-header",
    "<script>window.QUARTO_JUMP = " .. pandoc.json.encode(cfg) .. ";</script>")
  return nil
end

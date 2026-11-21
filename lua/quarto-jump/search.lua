-- Find the source location of a piece of rendered text.
--
-- Strategy (deliberately simple):
--   1. If the browser sent a sourceFile, look for the text in that file only.
--   2. Otherwise (or if not found there) search all source files of the project.
-- Matching = longest run of consecutive words shared by query and file.
local text = require("quarto-jump.text")
local uv = vim.uv

local M = {}

M.config = {
  extensions = { "qmd", "md", "Rmd" },
  -- directories skipped when the project is not a git repo
  skip_dirs = { "^%.", "^_site", "^_freeze$", "^_book$", "^node_modules$", "^site_libs$" },
  max_query_words = 60,
}

local cache = {} -- path -> { mtime = ..., words = {}, lines = {}, index = {} }

local function build(lines)
  local words, wlines, index = {}, {}, {}
  for lnum, line in ipairs(lines) do
    for _, w in ipairs(text.split(text.strip_markup(line))) do
      local n = #words + 1
      words[n], wlines[n] = w, lnum
      local ps = index[w]
      if ps then ps[#ps + 1] = n else index[w] = { n } end
    end
  end
  return { words = words, lines = wlines, index = index }
end

--- Word index of a file; uses the buffer content if the file is loaded.
local function load(path)
  local bufnr = vim.fn.bufnr(path)
  if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    return build(vim.split(vim.fn.tolower(table.concat(lines, "\n")), "\n", { plain = true }))
  end
  local stat = uv.fs_stat(path)
  if not stat then return nil end
  local mtime = stat.mtime.sec * 1e9 + stat.mtime.nsec
  local c = cache[path]
  if c and c.mtime == mtime then return c end
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  c = build(vim.split(vim.fn.tolower(content), "\n", { plain = true }))
  c.mtime = mtime
  cache[path] = c
  return c
end

--- Longest run of consecutive query words found in the file.
---@return integer score, integer? lnum
local function best_run(q, f)
  local best, best_pos = 0, nil
  for i = 1, #q do
    if #q - i + 1 <= best then break end
    local ps = f.index[q[i]]
    if ps then
      for _, p in ipairs(ps) do
        local k = 1
        while q[i + k] and f.words[p + k] == q[i + k] do
          k = k + 1
        end
        if k > best then best, best_pos = k, p end
      end
    end
  end
  return best, best_pos and f.lines[best_pos]
end

--- All source files of the project (absolute paths).
function M.project_files(root)
  local exts = {}
  for _, e in ipairs(M.config.extensions) do exts[e] = true end
  local files = {}

  local pathspec = {}
  for _, e in ipairs(M.config.extensions) do pathspec[#pathspec + 1] = "*." .. e end
  local res = vim.system(
    vim.list_extend({ "git", "ls-files", "--cached", "--others", "--exclude-standard", "-z", "--" }, pathspec),
    { cwd = root, text = true }
  ):wait()
  if res.code == 0 then
    for rel in res.stdout:gmatch("[^%z]+") do
      local abs = vim.fs.joinpath(root, rel)
      if uv.fs_stat(abs) then files[#files + 1] = abs end
    end
    return files
  end

  for name, type in vim.fs.dir(root, {
    depth = 20,
    skip = function(dir)
      local base = vim.fs.basename(dir)
      for _, pat in ipairs(M.config.skip_dirs) do
        if base:match(pat) then return false end
      end
      return true
    end,
  }) do
    if type == "file" and exts[name:match("%.([^.]+)$") or ""] then
      files[#files + 1] = vim.fs.joinpath(root, name)
    end
  end
  return files
end

function M.resolve(root, file)
  if not file or file == "" then return nil end
  local path = file:sub(1, 1) == "/" and file or vim.fs.joinpath(root, file)
  path = vim.fs.normalize(path)
  return uv.fs_stat(path) and path or nil
end

---@class quarto_jump.Request
---@field sourceFile string?
---@field text string?

---@class quarto_jump.Result
---@field file string absolute path
---@field lnum integer
---@field score integer

--- Find the source location(s) for a browser request.
---@param root string
---@param req quarto_jump.Request
---@return quarto_jump.Result[]
function M.find(root, req)
  local q = text.words(req.text or "")
  if #q > M.config.max_query_words then
    q = vim.list_slice(q, 1, M.config.max_query_words)
  end
  local required = math.min(#q, 3)

  local source = M.resolve(root, req.sourceFile)
  if source then
    if #q == 0 then return { { file = source, lnum = 1, score = 0 } } end
    local f = load(source)
    if f then
      local score, lnum = best_run(q, f)
      if score >= required and lnum then
        return { { file = source, lnum = lnum, score = score } }
      end
    end
  end

  if #q == 0 then return {} end

  local results, best = {}, required
  for _, path in ipairs(M.project_files(root)) do
    local f = load(path)
    if f then
      local score, lnum = best_run(q, f)
      if score > best then
        best, results = score, {}
      end
      if score == best and lnum then
        results[#results + 1] = { file = path, lnum = lnum, score = score }
      end
    end
  end
  return results
end

return M

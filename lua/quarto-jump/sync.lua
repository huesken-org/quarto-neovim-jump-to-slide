-- Neovim -> browser: tell connected pages where the cursor is.
local server = require("quarto-jump.server")
local text = require("quarto-jump.text")
local uv = vim.uv

local M = {}

M.enabled = true
M.debounce_ms = 300
local timer = uv.new_timer()
local last = nil
local suppress_until = 0

--- Do not sync for `ms` milliseconds (used after a browser-initiated jump).
function M.suppress(ms)
  suppress_until = uv.now() + ms
end

--- Nearest heading above the cursor and its ordinal number in the file.
local function heading_at(lines, lnum)
  local in_fence, fence, in_yaml = false, nil, lines[1] == "---"
  local heading, index = nil, 0
  for i = 1, lnum do
    local l = lines[i]
    if in_yaml then
      if i > 1 and (l == "---" or l == "...") then in_yaml = false end
    else
      local f = l:match("^%s*(```+)") or l:match("^%s*(~~~+)")
      if f then
        if not in_fence then
          in_fence, fence = true, f
        elseif f:sub(1, 1) == fence:sub(1, 1) and #f >= #fence then
          in_fence = false
        end
      elseif not in_fence then
        local h = l:match("^#+%s+(.*)$")
        if h then heading, index = h, index + 1 end
      end
    end
  end
  return heading, index
end

--- Payload describing the cursor position, or nil if not in a project file.
function M.payload(root)
  local buf = vim.api.nvim_get_current_buf()
  if vim.bo[buf].buftype ~= "" then return nil end
  local path = vim.api.nvim_buf_get_name(buf)
  local ext = path:match("%.([^.]+)$")
  if not ext or not vim.tbl_contains(require("quarto-jump.search").config.extensions, ext) then
    return nil
  end
  local rel = vim.fs.relpath(root, path) or path
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local lines = vim.api.nvim_buf_get_lines(buf, 0, lnum, false)
  local heading, index = heading_at(lines, lnum)
  local line_words = text.words(lines[lnum] or "", true)
  return {
    file = rel,
    html = rel:gsub("%.[^.]+$", ".html"),
    heading = heading and text.norm(heading, true) or "",
    index = index,
    text = #line_words >= 2 and table.concat(line_words, " ") or "",
    lnum = lnum,
  }
end

function M.send(root, force)
  if not server.running() or server.client_count() == 0 then return end
  local p = M.payload(root)
  if not p then return end
  local key = p.file .. "\0" .. p.heading .. "\0" .. p.index .. "\0" .. p.text
  if not force and key == last then return end
  last = key
  server.broadcast("goto", p)
end

function M.schedule(root_fn)
  if not M.enabled or uv.now() < suppress_until then return end
  if server.client_count() == 0 then return end
  timer:stop()
  timer:start(M.debounce_ms, 0, vim.schedule_wrap(function()
    if uv.now() < suppress_until then return end
    M.send(root_fn())
  end))
end

return M

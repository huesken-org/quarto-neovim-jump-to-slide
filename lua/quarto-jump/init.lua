-- quarto-jump: jump from a Quarto preview in the browser to the source in
-- Neovim, and let the browser follow the cursor.
local server = require("quarto-jump.server")
local search = require("quarto-jump.search")
local sync = require("quarto-jump.sync")

local M = {}

M.config = {
  host = "127.0.0.1",
  port = 7878,
  -- start the server when a quarto/markdown buffer inside a Quarto project is opened
  autostart = true,
  -- browser follows the cursor
  sync = true,
  -- project root; default: nearest dir with _quarto.yml above cwd, else cwd
  root = nil, ---@type (fun(): string)?
  -- called after a jump, e.g. to raise the terminal window
  on_jump = nil, ---@type (fun(result: table))?
  extensions = { "qmd", "md", "Rmd" },
  -- also append the debug log (:QuartoJumpLog) to this file, e.g.
  -- vim.fn.stdpath("log") .. "/quarto-jump.log"
  log_file = nil, ---@type string?
}

local ns = vim.api.nvim_create_namespace("quarto-jump")

function M.root()
  if M.config.root then return M.config.root() end
  local cwd = vim.fn.getcwd()
  return vim.fs.root(cwd, "_quarto.yml") or cwd
end

local function target_window()
  local cur = vim.api.nvim_get_current_win()
  if vim.bo[vim.api.nvim_win_get_buf(cur)].buftype == "" then return cur end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.bo[vim.api.nvim_win_get_buf(win)].buftype == "" then return win end
  end
  return cur
end

local function flash(buf, lnum)
  local id = vim.api.nvim_buf_set_extmark(buf, ns, lnum - 1, 0, { line_hl_group = "IncSearch" })
  vim.defer_fn(function()
    pcall(vim.api.nvim_buf_del_extmark, buf, ns, id)
  end, 700)
end

local function open(file, lnum)
  vim.api.nvim_set_current_win(target_window())
  file = vim.fs.normalize(file)
  if vim.fs.normalize(vim.api.nvim_buf_get_name(0)) ~= file then
    vim.cmd.edit(vim.fn.fnameescape(file))
  end
  lnum = math.min(lnum, vim.api.nvim_buf_line_count(0))
  vim.api.nvim_win_set_cursor(0, { lnum, 0 })
  vim.cmd("normal! zz")
  flash(0, lnum)
end

--- Handle a jump request from the browser.
---@param req quarto_jump.Request
function M.jump(req)
  local root = M.root()
  local results = search.find(root, req)
  if #results == 0 then
    local msg = "no match for: " .. (req.text or ""):sub(1, 60)
    vim.notify("quarto-jump: " .. msg, vim.log.levels.WARN)
    return { ok = false, error = msg }
  end

  sync.suppress(1500)
  local first = results[1]
  open(first.file, first.lnum)

  local rel = vim.fs.relpath(root, first.file) or first.file
  if #results > 1 then
    vim.fn.setqflist({}, " ", {
      title = "quarto-jump: " .. (req.text or ""):sub(1, 40),
      items = vim.tbl_map(function(r)
        return { filename = r.file, lnum = r.lnum, text = ("matched %d words"):format(r.score) }
      end, results),
    })
    vim.cmd("botright copen")
    vim.cmd("wincmd p")
    vim.notify(("quarto-jump: %d matches, see quickfix"):format(#results), vim.log.levels.INFO)
  end

  if M.config.on_jump then pcall(M.config.on_jump, first) end
  vim.cmd("redraw")
  return { ok = true, file = rel, lnum = first.lnum, matches = #results }
end

function M.start(port)
  port = port or M.config.port
  if server.running() then
    vim.notify("quarto-jump: already running on port " .. server.port)
    return true
  end
  local ok, err = server.start(M.config.host, port)
  if not ok then
    vim.notify(("quarto-jump: cannot listen on %s:%d (%s)"):format(M.config.host, port, err),
      vim.log.levels.WARN)
    return false
  end
  return true
end

function M.stop() server.stop() end

function M.status()
  if server.running() then
    local peers = server.client_peers()
    vim.notify(("quarto-jump: listening on %s:%d, %d browser(s) connected%s, sync %s, root %s"):format(
      M.config.host, server.port, #peers, #peers > 0 and (" [" .. table.concat(peers, ", ") .. "]") or "",
      sync.enabled and "on" or "off", M.root()))
  else
    vim.notify("quarto-jump: not running (see :QuartoJumpLog)")
  end
end

--- Show the debug log in a scratch buffer.
function M.show_log()
  local lines = server.get_log()
  if #lines == 0 then lines = { "(empty)" } end
  vim.cmd("botright new")
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_name(buf, "quarto-jump://log")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.cmd("normal! G")
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  search.config.extensions = M.config.extensions
  sync.enabled = M.config.sync
  server.on_jump = M.jump
  server.log_file = M.config.log_file

  vim.api.nvim_create_user_command("QuartoJumpStart", function(a)
    M.start(tonumber(a.args))
  end, { nargs = "?", desc = "Start the quarto-jump server" })
  vim.api.nvim_create_user_command("QuartoJumpStop", M.stop, { desc = "Stop the quarto-jump server" })
  vim.api.nvim_create_user_command("QuartoJumpStatus", M.status, { desc = "quarto-jump status" })
  vim.api.nvim_create_user_command("QuartoJumpLog", M.show_log, { desc = "Show the quarto-jump debug log" })
  vim.api.nvim_create_user_command("QuartoJumpSync", function(a)
    if a.args == "on" then sync.enabled = true
    elseif a.args == "off" then sync.enabled = false
    else sync.enabled = not sync.enabled end
    vim.notify("quarto-jump: sync " .. (sync.enabled and "on" or "off"))
  end, { nargs = "?", complete = function() return { "on", "off", "toggle" } end,
         desc = "Toggle browser following the cursor" })
  vim.api.nvim_create_user_command("QuartoJumpShow", function()
    if not server.running() then M.start() end
    sync.send(M.root(), true)
  end, { desc = "Show the cursor position in the browser" })

  local group = vim.api.nvim_create_augroup("quarto-jump", { clear = true })
  local patterns = vim.tbl_map(function(e) return "*." .. e end, M.config.extensions)

  vim.api.nvim_create_autocmd({ "CursorMoved", "BufEnter" }, {
    group = group,
    pattern = patterns,
    callback = function() sync.schedule(M.root) end,
  })

  if M.config.autostart then
    local tried = false
    vim.api.nvim_create_autocmd("BufEnter", {
      group = group,
      pattern = patterns,
      callback = function(ev)
        if tried or server.running() then return true end
        if vim.fs.root(ev.buf, "_quarto.yml") then
          tried = true
          server.log("autostart triggered by %s (pid %d)", vim.api.nvim_buf_get_name(ev.buf), vim.fn.getpid())
          M.start()
          return true
        end
      end,
    })
  end
end

return M

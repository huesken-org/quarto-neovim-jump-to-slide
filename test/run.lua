-- Integration test: starts the server in a headless Neovim, talks to it with curl.
--   nvim --headless -u NONE -l test/run.lua <quarto-project-dir>
local plugin_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(plugin_dir)

local project = assert(_G.arg[1], "usage: nvim --headless -u NONE -l test/run.lua <project>")
vim.cmd.cd(project)

local PORT = 17878
local qj = require("quarto-jump")
qj.setup({ port = PORT, autostart = false })
assert(qj.start(), "server did not start")

local failures = 0
local function check(name, cond, info)
  print((cond and "ok   " or "FAIL ") .. name .. (cond and "" or ("  -- " .. vim.inspect(info))))
  if not cond then failures = failures + 1 end
end

local function curl(args)
  local done, out
  vim.system(vim.list_extend({ "curl", "-s", "--max-time", "3" }, args), { text = true }, function(r)
    out, done = r, true
  end)
  vim.wait(5000, function() return done end, 10)
  return out
end

local function jump(payload, headers)
  local args = { "-X", "POST", "-H", "Content-Type: text/plain", "--data", vim.json.encode(payload) }
  for _, h in ipairs(headers or {}) do vim.list_extend(args, { "-H", h }) end
  args[#args + 1] = ("http://127.0.0.1:%d/jump"):format(PORT)
  local r = curl(args)
  local ok, res = pcall(vim.json.decode, r.stdout)
  return ok and res or { raw = r.stdout }
end

local function line_of(file, needle)
  for i, l in ipairs(vim.fn.readfile(file)) do
    if l:find(needle, 1, true) then return i end
  end
end

local define = "slides/04_mocking/01_interfaces/01_define.qmd"

-- 1. sourceFile + text
local res = jump({ sourceFile = define, text = "Nur Methodensignaturen, keine Daten, keine Implementierung" })
check("sourceFile + paragraph", res.ok and res.file == define and res.lnum == line_of(define, "Nur Methodensignaturen"), res)
check("buffer opened at line", vim.fn.expand("%:.") == define and vim.fn.line(".") == res.lnum,
  { vim.fn.expand("%:."), vim.fn.line(".") })

-- 2. text only: search all files (generated copies are gitignored)
res = jump({ text = "Nur Methodensignaturen, keine Daten, keine Implementierung" })
check("text only -> same file", res.ok and res.file == define and res.matches == 1, res)

-- 3. heading (rendered text vs `# Interface erfüllen {duration=...}`)
local satisfy = "slides/04_mocking/01_interfaces/02_satisfy.qmd"
res = jump({ sourceFile = satisfy, text = "Interface erfüllen" })
check("heading with attributes + umlaut", res.ok and res.lnum == line_of(satisfy, "# Interface erfüllen"), res)

-- 4. code line
res = jump({ text = "    Write(p []byte) (n int, err error)" , sourceFile = define })
check("code line", res.ok and res.lnum == line_of(define, "Write(p []byte)"), res)

-- 5. sourceFile given but text lives elsewhere -> falls back to global search
res = jump({ sourceFile = satisfy, text = "Nur Methodensignaturen, keine Daten, keine Implementierung" })
check("fallback to global search", res.ok and res.file == define, res)

-- 6. rendered text with smart punctuation / extra words around it
res = jump({ sourceFile = define, text = "Konvention: eine Methode, Name auf -er (Reader, Writer, Stringer)" })
check("inline code + punctuation", res.ok and res.lnum == line_of(define, "Konvention: eine Methode"), res)

-- 7. no match
res = jump({ text = "zzqx completely unrelated wording here" })
check("no match", res.ok == false, res)

-- 8. security
local r = curl({ "-o", "/dev/null", "-w", "%{http_code}", "-H", "Origin: https://evil.example",
  ("http://127.0.0.1:%d/ping"):format(PORT) })
check("foreign origin rejected", r.stdout == "403", r.stdout)
r = curl({ "-o", "/dev/null", "-w", "%{http_code}", "-H", "Host: evil.example",
  ("http://127.0.0.1:%d/ping"):format(PORT) })
check("foreign host rejected", r.stdout == "403", r.stdout)
r = curl({ "-i", "-H", "Origin: http://localhost:4321", ("http://127.0.0.1:%d/ping"):format(PORT) })
check("local origin + CORS header", r.stdout:find("Access-Control-Allow-Origin: http://localhost:4321", 1, true) ~= nil, r.stdout)

-- 9. SSE: cursor position is pushed to connected browsers
local sse_done, sse_out
vim.system({ "curl", "-s", "-N", "--max-time", "1.5", "-H", "Origin: http://localhost:4321",
  ("http://127.0.0.1:%d/events"):format(PORT) }, { text = true }, function(o)
  sse_out, sse_done = o.stdout, true
end)
vim.wait(1000, function() return require("quarto-jump.server").client_count() > 0 end, 10)
check("SSE client connected", require("quarto-jump.server").client_count() == 1)
vim.cmd.edit(define)
vim.api.nvim_win_set_cursor(0, { line_of(define, "Nur Methodensignaturen"), 0 })
require("quarto-jump.sync").send(qj.root(), true)
vim.wait(3000, function() return sse_done end, 10)
local data = sse_out and sse_out:match("event: goto\ndata: ([^\n]+)")
local ev = data and vim.json.decode(data)
check("SSE goto event", ev and ev.file == define and ev.heading == "interface definieren"
  and ev.text == "nur methodensignaturen keine daten keine implementierung", sse_out)

qj.stop()
print(failures == 0 and "\nall tests passed" or ("\n" .. failures .. " test(s) failed"))
vim.cmd(failures == 0 and "qa!" or "cq!")

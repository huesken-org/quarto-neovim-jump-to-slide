-- Minimal HTTP + Server-Sent-Events server on top of vim.uv.
--
-- Routes:
--   GET  /ping    -> {"ok":true,"name":"quarto-jump"}
--   POST /jump    -> body: JSON request from the browser, handled by on_jump
--   GET  /events  -> SSE stream, Neovim pushes "goto" events to the browser
--
-- Security: only requests from local origins (localhost / 127.0.0.1 / [::1])
-- are accepted, and the Host header must be local too (DNS rebinding).
local uv = vim.uv

local M = {}

local server ---@type uv.uv_tcp_t?
local clients = {} ---@type table<uv.uv_tcp_t, true>
local heartbeat ---@type uv.uv_timer_t?
M.port = nil
M.on_jump = function(_) return { ok = false, error = "no handler" } end

local function is_local_host(h)
  if not h then return false end
  h = h:lower():gsub(":%d+$", "")
  return h == "localhost" or h == "127.0.0.1" or h == "[::1]"
end

local function origin_ok(origin)
  if not origin or origin == "null" then return origin == nil end
  local host = origin:match("^https?://([^/]+)/?$")
  return is_local_host(host)
end

local function close(client)
  clients[client] = nil
  if not client:is_closing() then client:close() end
end

local function cors(origin)
  return {
    ["Access-Control-Allow-Origin"] = origin or "*",
    ["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS",
    ["Access-Control-Allow-Headers"] = "Content-Type",
    ["Access-Control-Allow-Private-Network"] = "true",
    ["Vary"] = "Origin",
  }
end

local function respond(client, status, headers, body)
  body = body or ""
  local out = { "HTTP/1.1 " .. status }
  headers["Content-Length"] = tostring(#body)
  headers["Connection"] = "close"
  for k, v in pairs(headers) do
    out[#out + 1] = k .. ": " .. v
  end
  client:write(table.concat(out, "\r\n") .. "\r\n\r\n" .. body, function()
    if not client:is_closing() then
      client:shutdown(function() close(client) end)
    end
  end)
end

local function json(client, status, origin, tbl)
  local h = cors(origin)
  h["Content-Type"] = "application/json"
  respond(client, status, h, vim.json.encode(tbl))
end

local function handle(client, req)
  local origin = req.headers["origin"]
  if not is_local_host(req.headers["host"]) or not origin_ok(origin) then
    return respond(client, "403 Forbidden", {}, "forbidden")
  end

  if req.method == "OPTIONS" then
    return respond(client, "204 No Content", cors(origin), "")
  end

  if req.method == "GET" and req.path == "/ping" then
    return json(client, "200 OK", origin, { ok = true, name = "quarto-jump" })
  end

  if req.method == "GET" and req.path == "/events" then
    local h = cors(origin)
    local out = {
      "HTTP/1.1 200 OK",
      "Content-Type: text/event-stream",
      "Cache-Control: no-cache",
      "Connection: keep-alive",
    }
    for k, v in pairs(h) do out[#out + 1] = k .. ": " .. v end
    client:write(table.concat(out, "\r\n") .. "\r\n\r\nretry: 3000\n: connected\n\n")
    clients[client] = true
    return
  end

  if req.method == "POST" and req.path == "/jump" then
    local ok, payload = pcall(vim.json.decode, req.body ~= "" and req.body or "{}")
    if not ok or type(payload) ~= "table" then
      return json(client, "400 Bad Request", origin, { ok = false, error = "invalid json" })
    end
    vim.schedule(function()
      local ok2, result = pcall(M.on_jump, payload)
      if not ok2 then result = { ok = false, error = tostring(result) } end
      json(client, "200 OK", origin, result)
    end)
    return
  end

  respond(client, "404 Not Found", cors(origin), "not found")
end

local function on_connection(err)
  if err or not server then return end
  local client = uv.new_tcp()
  server:accept(client)
  local buf, req = "", nil
  client:read_start(function(rerr, chunk)
    if rerr or not chunk then return close(client) end
    if clients[client] then return end -- SSE client: ignore anything it sends
    buf = buf .. chunk
    if not req then
      local head_end = buf:find("\r\n\r\n", 1, true)
      if not head_end then
        if #buf > 65536 then close(client) end
        return
      end
      local head = buf:sub(1, head_end - 1)
      buf = buf:sub(head_end + 4)
      local lines = vim.split(head, "\r\n", { plain = true })
      local method, target = lines[1]:match("^(%u+)%s+(%S+)")
      if not method then return close(client) end
      req = { method = method, path = target:gsub("%?.*$", ""), headers = {} }
      for i = 2, #lines do
        local k, v = lines[i]:match("^([^:]+):%s*(.*)$")
        if k then req.headers[k:lower()] = v end
      end
      req.length = tonumber(req.headers["content-length"]) or 0
    end
    if #buf >= req.length then
      req.body = buf:sub(1, req.length)
      local r = req
      req, buf = nil, ""
      local ok, herr = pcall(handle, client, r)
      if not ok then
        pcall(respond, client, "500 Internal Server Error", {}, tostring(herr))
      end
    end
  end)
end

---@return boolean ok, string? err
function M.start(host, port)
  if server then return true end
  local s = uv.new_tcp()
  local ok, err = s:bind(host, port)
  if ok then ok, err = s:listen(64, on_connection) end
  if not ok then
    s:close()
    return false, err
  end
  server, M.port = s, port
  heartbeat = uv.new_timer()
  heartbeat:start(15000, 15000, function() M.broadcast_raw(": ping\n\n") end)
  return true
end

function M.stop()
  for client in pairs(clients) do close(client) end
  if heartbeat then heartbeat:stop(); heartbeat:close(); heartbeat = nil end
  if server then server:close(); server = nil end
  M.port = nil
end

function M.running() return server ~= nil end

function M.client_count()
  local n = 0
  for _ in pairs(clients) do n = n + 1 end
  return n
end

function M.broadcast_raw(data)
  for client in pairs(clients) do
    if client:is_closing() then
      clients[client] = nil
    else
      client:write(data, function(err)
        if err then close(client) end
      end)
    end
  end
end

---@param event string
---@param data table
function M.broadcast(event, data)
  M.broadcast_raw("event: " .. event .. "\ndata: " .. vim.json.encode(data) .. "\n\n")
end

return M

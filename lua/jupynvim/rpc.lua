-- msgpack-rpc client over a child's stdio.
-- Uses vim.uv (libuv) directly so we get raw byte streams (jobstart's line
-- splitting destroys binary msgpack data).

local mpack = vim.mpack
local log = require("jupynvim.log")
local uv = vim.uv

local M = {}

local Client = {}
Client.__index = Client

-- Lightweight per-method RPC counters for diagnosing what crosses the link.
-- Always on (a table increment per call is free); :JupynvimRpcStats prints and
-- resets. lsp_send / lsp_message are broken out by the inner JSON-RPC method so
-- a flood shows up as e.g. "lsp_send:textDocument/documentHighlight".
M.stats = { out = {}, inc = {} }
local function bump(t, k) t[k] = (t[k] or 0) + 1 end
local function stat_out(method, params)
  if method == "lsp_send" and type(params) == "table" and type(params.message) == "table" then
    bump(M.stats.out, "lsp_send:" .. tostring(params.message.method or "<response>"))
  else
    bump(M.stats.out, method)
  end
end
function M.reset_stats() M.stats = { out = {}, inc = {} } end

function M.spawn(opts)
  local stdin = uv.new_pipe(false)
  local stdout = uv.new_pipe(false)
  local stderr = uv.new_pipe(false)

  local c = setmetatable({
    stdin = stdin, stdout = stdout, stderr = stderr,
    handle = nil, pid = nil,
    next_id = 1,
    pending = {},
    handlers = {},
    buf = "",
    on_exit = opts.on_exit,
    job = nil, -- compat
  }, Client)

  local cmd = opts.cmd[1]
  local args = {}
  for i = 2, #opts.cmd do args[i - 1] = opts.cmd[i] end
  local env_list = nil
  if opts.env then
    env_list = {}
    for k, v in pairs(opts.env) do
      table.insert(env_list, k .. "=" .. tostring(v))
    end
  end

  local handle, pid = uv.spawn(cmd, {
    args = args,
    stdio = { stdin, stdout, stderr },
    cwd = opts.cwd,
    env = env_list,
  }, function(code, signal)
    log.warn("jupynvim-core exited code=" .. tostring(code) .. " signal=" .. tostring(signal))
    c.dead = true
    c.job = nil
    -- Fail every in-flight call NOW. Without this, a backend that dies on
    -- spawn (e.g. ssh BatchMode refused because no auth master is up yet)
    -- leaves callers hanging until their own timeouts (the explorer waited
    -- 35s on a process that exited in 200ms).
    vim.schedule(function()
      local pending = c.pending
      c.pending = {}
      for _, cb in pairs(pending) do
        pcall(cb, "backend exited (code=" .. tostring(code) .. ") - not connected? :JupynvimConnect", nil)
      end
      if c.on_exit then c.on_exit(code) end
    end)
    pcall(function() if not stdin:is_closing() then stdin:close() end end)
    pcall(function() if not stdout:is_closing() then stdout:close() end end)
    pcall(function() if not stderr:is_closing() then stderr:close() end end)
    pcall(function() if not handle:is_closing() then handle:close() end end)
  end)
  if not handle then
    error("jupynvim: spawn failed: " .. (pid or "?"))
  end
  c.handle, c.pid = handle, pid
  c.job = pid -- compat alias used elsewhere as a truthiness check

  stdout:read_start(function(err, chunk)
    if err then log.error("stdout read: " .. err); return end
    if not chunk then return end -- EOF
    c.buf = c.buf .. chunk
    c:_drain()
  end)
  stderr:read_start(function(err, chunk)
    if err then log.error("stderr read: " .. err); return end
    if not chunk then return end
    -- Pass-through to log
    for line in chunk:gmatch("[^\n]+") do log.warn("core stderr: " .. line) end
  end)

  log.info("jupynvim-core started, pid=" .. pid)
  return c
end

function Client:stop()
  if self.handle and not self.handle:is_closing() then
    self.handle:kill("sigterm")
  end
end

function Client:_drain()
  while #self.buf >= 4 do
    local b1, b2, b3, b4 = string.byte(self.buf, 1, 4)
    local len = b1 * 0x1000000 + b2 * 0x10000 + b3 * 0x100 + b4
    if #self.buf < 4 + len then return end
    local payload = self.buf:sub(5, 4 + len)
    self.buf = self.buf:sub(5 + len)
    local ok, val = pcall(mpack.decode, payload)
    if ok and val then
      self:_dispatch(val)
    else
      log.warn("decode failed: " .. tostring(val))
    end
  end
end

local function denil(v)
  if v == vim.NIL then return nil end
  if type(v) == "table" then
    -- shallow normalize for arrays/maps
    for k, x in pairs(v) do
      if x == vim.NIL then v[k] = nil end
    end
  end
  return v
end

function Client:_dispatch(val)
  if type(val) ~= "table" or #val < 3 then
    log.warn("invalid rpc msg: " .. vim.inspect(val):sub(1, 200))
    return
  end
  local kind = val[1]
  if kind == 1 then
    bump(M.stats.inc, "<response>")
    local msgid, err, result = val[2], val[3], val[4]
    err = denil(err)
    result = denil(result)
    local cb = self.pending[msgid]
    self.pending[msgid] = nil
    if cb then vim.schedule(function() cb(err, result) end) end
  elseif kind == 2 then
    local method, params = val[2], val[3]
    if method == "lsp_message" then
      local e = (type(params) == "table" and (params[1] or params)) or {}
      local m = type(e) == "table" and type(e.message) == "table" and e.message.method
      bump(M.stats.inc, "lsp_message:" .. tostring(m or "<response>"))
    else
      bump(M.stats.inc, method)
    end
    local h = self.handlers[method]
    if h then
      vim.schedule(function() h(params) end)
    else
      log.debug("unhandled notification: " .. tostring(method))
    end
  elseif kind == 0 then
    log.warn("unexpected request from core")
  end
end

function Client:_write(payload)
  if not self.stdin or self.stdin:is_closing() then return end
  -- 4-byte BE length prefix
  local n = #payload
  local hdr = string.char(
    bit.band(bit.rshift(n, 24), 0xff),
    bit.band(bit.rshift(n, 16), 0xff),
    bit.band(bit.rshift(n,  8), 0xff),
    bit.band(n, 0xff)
  )
  self.stdin:write(hdr .. payload)
end

function Client:call(method, params, cb)
  cb = cb or function() end
  stat_out(method, params)
  if self.dead then
    -- Dead transport: fail immediately instead of queueing forever.
    vim.schedule(function()
      cb("backend not running - :JupynvimConnect first", nil)
    end)
    return
  end
  local id = self.next_id
  self.next_id = self.next_id + 1
  self.pending[id] = cb
  local payload = mpack.encode({ 0, id, method, { params or vim.empty_dict() } })
  self:_write(payload)
end

function Client:call_sync(method, params, timeout_ms)
  timeout_ms = timeout_ms or 5000
  local done, err_out, result_out = false, nil, nil
  self:call(method, params, function(err, result)
    err_out, result_out = err, result
    done = true
  end)
  vim.wait(timeout_ms, function() return done end, 5)
  if not done then return "timeout", nil end
  return err_out, result_out
end

function Client:notify(method, params)
  stat_out(method, params)
  local payload = mpack.encode({ 2, method, { params or vim.empty_dict() } })
  self:_write(payload)
end

function Client:on(method, handler)
  self.handlers[method] = handler
end

return M

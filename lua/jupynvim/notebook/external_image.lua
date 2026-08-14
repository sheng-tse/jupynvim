-- Resolve external Markdown/HTML image references without changing cell source.
-- HTTP requests run locally through vim.system; relative files are read by the
-- notebook's existing backend so remote notebooks keep remote filesystem semantics.

local M = {}

local resolved = {}
local failed = {}
local inflight = {}

local function finish(key, err, value)
  if value then resolved[key] = value else failed[key] = err or "image load failed" end
  local callbacks = inflight[key] or {}
  inflight[key] = nil
  vim.schedule(function()
    for _, callback in ipairs(callbacks) do callback(err, value) end
  end)
end

function M.classify(src)
  if type(src) ~= "string" then return nil end
  src = vim.trim(src)
  if src:match("^https?://") then return "http" end
  if src ~= "" and not src:match("^[%a][%w+.-]*:") and src:sub(1, 1) ~= "/" then
    return "relative"
  end
  return nil
end

function M.detect_mime(bytes)
  if type(bytes) ~= "string" then return nil end
  if bytes:sub(1, 8) == "\137PNG\r\n\26\n" then return "image/png" end
  if bytes:sub(1, 3) == "\255\216\255" then return "image/jpeg" end
  return nil
end

function M.resolve_path(notebook_path, src)
  if type(notebook_path) ~= "string" or notebook_path == "" then return nil end
  local dir = vim.fs.dirname(notebook_path)
  if not dir then return nil end
  return vim.fs.normalize(vim.fs.joinpath(dir, vim.trim(src)))
end

local function resolve_http(src, key, opts)
  local system = opts.system or vim.system
  system({ "curl", "--location", "--fail", "--silent", "--show-error", src },
    { text = false }, function(result)
      if result.code ~= 0 then
        finish(key, result.stderr or ("HTTP fetch failed: " .. result.code), nil)
        return
      end
      local mime = M.detect_mime(result.stdout)
      if not mime then
        finish(key, "unsupported or invalid image", nil)
        return
      end
      finish(key, nil, { b64 = vim.base64.encode(result.stdout), mime = mime })
    end)
end

local function resolve_relative(src, key, opts)
  local path = M.resolve_path(opts.notebook_path, src)
  if not path then
    finish(key, "notebook path unavailable", nil)
    return
  end
  if not opts.client or type(opts.client.call) ~= "function" then
    finish(key, "notebook backend unavailable", nil)
    return
  end
  opts.client:call("fs_read", { path = path }, function(err, result)
    if err or not result or type(result.content_b64) ~= "string" then
      finish(key, err or "fs_read returned no image data", nil)
      return
    end
    local ok, bytes = pcall(vim.base64.decode, result.content_b64)
    local mime = ok and M.detect_mime(bytes) or nil
    if not mime then
      finish(key, "unsupported or invalid image", nil)
      return
    end
    finish(key, nil, { b64 = result.content_b64, mime = mime })
  end)
end

-- callback(err, { b64, mime }). Concurrent callers for one source share work.
function M.resolve(src, opts, callback)
  opts = opts or {}
  local kind = M.classify(src)
  if not kind then
    vim.schedule(function() callback("unsupported image source", nil) end)
    return
  end
  src = vim.trim(src)
  local key = kind == "http" and src or M.resolve_path(opts.notebook_path, src)
  if not key then
    vim.schedule(function() callback("notebook path unavailable", nil) end)
    return
  end
  if resolved[key] then
    local value = resolved[key]
    vim.schedule(function() callback(nil, value) end)
    return
  end
  if failed[key] then
    local err = failed[key]
    vim.schedule(function() callback(err, nil) end)
    return
  end
  if inflight[key] then
    table.insert(inflight[key], callback)
    return
  end
  inflight[key] = { callback }
  if kind == "http" then
    resolve_http(src, key, opts)
  else
    resolve_relative(src, key, opts)
  end
end

function M.clear_cache()
  resolved = {}
  failed = {}
  inflight = {}
end

return M

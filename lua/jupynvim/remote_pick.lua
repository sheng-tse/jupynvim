-- Remote file/grep pickers backed by the backend (find_files / search RPCs),
-- so <leader>ff / <leader>/ etc. operate on the REMOTE when SSH-connected.
--
-- Prefers snacks.picker (the LazyVim default) for a native fuzzy UI; falls
-- back to vim.ui.select (files) / quickfix (grep) for other setups. Picked
-- items open as jupynvim://<alias>/<path> URIs, routed to the remote backend.

local M = {}

local function uri(alias, abspath)
  -- abspath is absolute on the remote; jupynvim://<alias><abspath>
  return "jupynvim://" .. alias .. abspath
end

local function has_snacks()
  return pcall(require, "snacks") and package.loaded["snacks"] and Snacks and Snacks.picker
end

-- Resolve the search root: explicit arg, else the explorer's current root, else ~.
local function resolve_root(alias, root)
  if root and root ~= "" then return root end
  local ok, r = pcall(function() return require("jupynvim.remote_explorer").current_root(alias) end)
  if ok and r then return r end
  return "~"
end

-- ── find files ──────────────────────────────────────────────────────────
function M.files(alias, root)
  root = resolve_root(alias, root)
  local client = require("jupynvim").client_for(alias)
  local err, res = client:call_sync("find_files", { path = root, max = 20000 }, 30000)
  if err or not res then
    vim.notify("jupynvim: find_files failed: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  local base = res.root or root
  local files = res.files or {}
  if #files == 0 then
    vim.notify("jupynvim: no files under " .. base, vim.log.levels.INFO)
    return
  end
  local title = "Find Files (" .. alias .. ":" .. base .. ")"
    .. (res.truncated and " [truncated]" or "")

  if has_snacks() then
    local items = {}
    for i, rel in ipairs(files) do
      items[i] = { text = rel, file = uri(alias, base .. "/" .. rel) }
    end
    Snacks.picker.pick({ items = items, format = "file", title = title })
    return
  end
  -- fallback: vim.ui.select
  vim.ui.select(files, { prompt = title }, function(choice)
    if choice then vim.cmd("edit " .. vim.fn.fnameescape(uri(alias, base .. "/" .. choice))) end
  end)
end

-- ── grep ───────────────────────────────────────────────────────────────
function M.grep(alias, root, pattern)
  root = resolve_root(alias, root)
  local function run(pat)
    if not pat or pat == "" then return end
    local client = require("jupynvim").client_for(alias)
    local err, res = client:call_sync("search", { path = root, pattern = pat, max = 2000 }, 30000)
    if err or not res then
      vim.notify("jupynvim: search failed: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    local matches = res.matches or {}
    if #matches == 0 then
      vim.notify("jupynvim: no matches for " .. pat, vim.log.levels.INFO)
      return
    end
    local title = "Grep '" .. pat .. "' (" .. alias .. ")" .. (res.truncated and " [truncated]" or "")
    if has_snacks() then
      local items = {}
      for i, m in ipairs(matches) do
        items[i] = {
          text = m.path .. ":" .. m.line .. ": " .. (m.text or ""),
          file = uri(alias, m.path),
          pos = { tonumber(m.line) or 1, (tonumber(m.col) or 1) - 1 },
        }
      end
      Snacks.picker.pick({ items = items, format = "file", title = title })
      return
    end
    -- fallback: quickfix
    local qf = {}
    for _, m in ipairs(matches) do
      qf[#qf + 1] = { filename = uri(alias, m.path), lnum = m.line, col = m.col, text = m.text }
    end
    vim.fn.setqflist({}, " ", { title = title, items = qf })
    vim.cmd("copen")
  end

  if pattern then run(pattern)
  else vim.ui.input({ prompt = "Grep " .. alias .. ": " }, run) end
end

return M

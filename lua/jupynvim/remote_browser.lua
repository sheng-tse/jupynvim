-- Remote file browser for jupynvim:// directories.
--
-- Triggered when a buffer's URI ends in `/`. Populates the buffer with
-- a one-entry-per-line listing of the directory. Keybinds inside the
-- buffer drive navigation and file operations through fs_* RPCs.
--
-- This is a netrw-style browser (keybinds for actions) rather than a
-- full oil.nvim-style editable buffer. Simpler, more discoverable for
-- people not already in the oil.nvim ecosystem. Editable-buffer mode
-- can land later as an opt-in.
--
-- Buffer-local state:
--   b:jupynvim_alias        — remote profile alias
--   b:jupynvim_remote_path  — current directory path (no trailing /)
--   b:jupynvim_browser      — true (lets other code detect)

local M = {}

-- Highlight groups (best-effort; respects user colorscheme)
vim.api.nvim_set_hl(0, "JupynvimBrowserDir",  { default = true, link = "Directory" })
vim.api.nvim_set_hl(0, "JupynvimBrowserLink", { default = true, link = "Special" })
vim.api.nvim_set_hl(0, "JupynvimBrowserPath", { default = true, link = "Title" })
local NS = vim.api.nvim_create_namespace("jupynvim.browser")

-- Build display line for one entry. Returns the text + which highlight to use.
local function fmt(entry)
  if entry.kind == "dir" then
    return entry.name .. "/", "JupynvimBrowserDir"
  elseif entry.kind == "link" then
    return entry.name .. "@", "JupynvimBrowserLink"
  else
    return entry.name, nil
  end
end

local function parent_path(path)
  if path == "/" or path == "" then return "/" end
  local p = path:match("^(.+)/[^/]+$")
  return (p == nil or p == "") and "/" or p
end

local function join_path(base, name)
  if base == "/" then return "/" .. name end
  return base .. "/" .. name
end

local function uri_for(alias, path, trailing_slash)
  local s = "jupynvim://" .. alias .. path
  if trailing_slash and s:sub(-1) ~= "/" then s = s .. "/" end
  return s
end

-- (Re)populate `buf` with a fresh listing of `dir_path` on `alias`'s backend.
function M.populate(buf, alias, dir_path, client)
  client = client or require("jupynvim").client_for(alias)
  -- Show a spinner-ish placeholder while the RPC runs
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "loading " .. dir_path .. "..." })
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "jupynvim-browser"
  -- Auto-wipe browser buffers when hidden so navigating into a new dir
  -- doesn't pile up :ls entries / bufferline tabs for every directory.
  vim.bo[buf].bufhidden = "wipe"
  -- Hide from bufferline plugins (lualine, bufferline.nvim) that check buflisted
  vim.bo[buf].buflisted = false
  vim.b[buf].jupynvim_alias = alias
  vim.b[buf].jupynvim_remote_path = dir_path
  vim.b[buf].jupynvim_browser = true

  -- First call after backend spawn can take 30+s (SSH + srun attach +
  -- jupynvim-core startup). 60s gives PSC headroom on busy nights.
  local err, res = client:call_sync("fs_list", { path = dir_path }, 60000)
  if err then
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "[" .. alias .. "] " .. dir_path,
      "",
      "Error: " .. tostring(err),
      "",
      "Common causes:",
      "  • backend not yet installed on remote (~/.local/bin/jupynvim-core)",
      "  • slurm job ID stale; export PSC_JOBID=<new> and retry",
      "  • SSH ControlMaster dead; :JupynvimDisconnect " .. alias .. " then reconnect",
    })
    vim.bo[buf].modifiable = false
    return
  end

  -- Header line shows the absolute resolved path
  local lines = {}
  local hl = {}  -- {row -> { name, group }}
  table.insert(lines, "[" .. alias .. "] " .. (res.path or dir_path))
  hl[1] = { fmt = nil, group = "JupynvimBrowserPath" }
  table.insert(lines, "")  -- blank
  -- Parent link unless we're at root
  if dir_path ~= "/" then
    table.insert(lines, "../")
    hl[#lines] = { fmt = nil, group = "JupynvimBrowserDir" }
  end
  -- Entries (server sorts dirs-first)
  local entries = res.entries or {}
  vim.b[buf].jupynvim_entries = entries
  for _, e in ipairs(entries) do
    local text, group = fmt(e)
    table.insert(lines, text)
    if group then hl[#lines] = { group = group } end
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  for row, h in pairs(hl) do
    vim.api.nvim_buf_add_highlight(buf, NS, h.group, row - 1, 0, -1)
  end

  M._bind_keys(buf)
  M._setup_watcher(buf, alias, dir_path, client)
end

-- Per-client (shared across buffers) state: which alias's client has had
-- the fs_event handler hooked, and the active watcher per browser buffer.
local watch_state = {}

-- Start an fs_watch on dir_path; debounced refresh on events.
function M._setup_watcher(buf, alias, dir_path, client)
  -- Stop any prior watcher for this buffer first
  local prior = vim.b[buf].jupynvim_watcher_id
  if prior then
    pcall(function() client:call("fs_unwatch", { watcher_id = prior }, function() end) end)
  end
  -- Start a new one (non-recursive — we only show one dir level)
  client:call("fs_watch", { path = dir_path, recursive = false }, function(err, res)
    if err or not res or not res.watcher_id then return end
    vim.b[buf].jupynvim_watcher_id = res.watcher_id
    watch_state[res.watcher_id] = { buf = buf, alias = alias, dir_path = dir_path }
  end)
  -- Hook the client's fs_event handler once
  if not client._fs_event_hooked then
    client._fs_event_hooked = true
    client:on("fs_event", function(args)
      local e = args[1] or args
      local entry = watch_state[e.watcher_id]
      if not entry then return end
      -- Debounce: only one reload pending per buffer at a time
      if entry.pending then return end
      entry.pending = true
      vim.defer_fn(function()
        entry.pending = false
        if vim.api.nvim_buf_is_valid(entry.buf) then
          M.populate(entry.buf, entry.alias, entry.dir_path)
        end
      end, 150)
    end)
  end
  -- Clean up on buffer wipeout
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      local wid = vim.b[buf].jupynvim_watcher_id
      if wid then
        watch_state[wid] = nil
        pcall(function() client:call("fs_unwatch", { watcher_id = wid }, function() end) end)
      end
    end,
  })
end

-- Resolve the entry under the cursor. Returns {name, kind, is_parent} or nil.
local function entry_under_cursor(buf)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
  if not line or line == "" then return nil end
  -- Header / parent / regular entries
  if line:match("^%[") then return nil end  -- header line
  if line == "../" then return { is_parent = true } end
  -- Strip trailing kind suffix
  local name = line
  local kind = "file"
  if name:sub(-1) == "/" then kind = "dir"; name = name:sub(1, -2)
  elseif name:sub(-1) == "@" then kind = "link"; name = name:sub(1, -2) end
  return { name = name, kind = kind }
end

local function open_at_cursor(buf)
  local e = entry_under_cursor(buf)
  if not e then return end
  local alias = vim.b[buf].jupynvim_alias
  local cur = vim.b[buf].jupynvim_remote_path
  if e.is_parent then
    vim.cmd("edit " .. uri_for(alias, parent_path(cur), true))
    return
  end
  local target = join_path(cur, e.name)
  if e.kind == "dir" then
    vim.cmd("edit " .. uri_for(alias, target, true))
  elseif e.name:sub(-6) == ".ipynb" then
    -- Notebook: route through jupynvim's notebook flow directly. Skips
    -- the URI scheme so we don't end up with an orphan URI buffer
    -- alongside the real notebook buffer.
    local J = require("jupynvim")
    J.use_remote(alias)
    J.open(target, { alias = alias })
  else
    vim.cmd("edit " .. uri_for(alias, target, false))
  end
end

local function go_up(buf)
  local alias = vim.b[buf].jupynvim_alias
  local cur = vim.b[buf].jupynvim_remote_path
  vim.cmd("edit " .. uri_for(alias, parent_path(cur), true))
end

local function reload(buf)
  local alias = vim.b[buf].jupynvim_alias
  local cur = vim.b[buf].jupynvim_remote_path
  M.populate(buf, alias, cur)
end

local function delete_entry(buf)
  local e = entry_under_cursor(buf)
  if not e or e.is_parent then return end
  local alias = vim.b[buf].jupynvim_alias
  local cur = vim.b[buf].jupynvim_remote_path
  local target = join_path(cur, e.name)
  local prompt = string.format("Delete %s '%s'? [y/N] ", e.kind, target)
  vim.ui.input({ prompt = prompt }, function(answer)
    if not answer or answer:lower() ~= "y" then return end
    local client = require("jupynvim").client_for(alias)
    local err = client:call_sync("fs_rm",
      { path = target, recursive = (e.kind == "dir") }, 30000)
    if err then
      vim.notify("jupynvim: rm failed: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    vim.notify("removed " .. target)
    reload(buf)
  end)
end

local function rename_entry(buf)
  local e = entry_under_cursor(buf)
  if not e or e.is_parent then return end
  local alias = vim.b[buf].jupynvim_alias
  local cur = vim.b[buf].jupynvim_remote_path
  local old_path = join_path(cur, e.name)
  vim.ui.input({ prompt = "Rename to: ", default = e.name }, function(new_name)
    if not new_name or new_name == "" or new_name == e.name then return end
    local new_path = join_path(cur, new_name)
    local client = require("jupynvim").client_for(alias)
    local err = client:call_sync("fs_rename",
      { src = old_path, dst = new_path }, 30000)
    if err then
      vim.notify("jupynvim: rename failed: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    reload(buf)
  end)
end

local function create_entry(buf)
  local alias = vim.b[buf].jupynvim_alias
  local cur = vim.b[buf].jupynvim_remote_path
  vim.ui.input({ prompt = "New (trailing / = dir): " }, function(name)
    if not name or name == "" then return end
    local is_dir = name:sub(-1) == "/"
    if is_dir then name = name:sub(1, -2) end
    local target = join_path(cur, name)
    local client = require("jupynvim").client_for(alias)
    local err
    if is_dir then
      err = client:call_sync("fs_mkdir", { path = target, parents = true }, 30000)
    else
      err = client:call_sync("fs_write", { path = target, content_b64 = "" }, 30000)
    end
    if err then
      vim.notify("jupynvim: create failed: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    reload(buf)
  end)
end

function M._bind_keys(buf)
  local map = function(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
  end
  map("<CR>",  function() open_at_cursor(buf) end, "jupynvim: open file or descend into dir")
  map("-",     function() go_up(buf) end,         "jupynvim: parent directory")
  map("R",     function() reload(buf) end,         "jupynvim: reload listing")
  map("D",     function() delete_entry(buf) end,   "jupynvim: delete entry")
  map("r",     function() rename_entry(buf) end,   "jupynvim: rename entry")
  map("c",     function() create_entry(buf) end,   "jupynvim: create file/dir")
  map("q",     "<cmd>bd<cr>",                       "jupynvim: close browser")
end

return M

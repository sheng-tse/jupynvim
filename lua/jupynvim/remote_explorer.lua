-- Tree-style remote file explorer for jupynvim SSH sessions.
--
-- A LazyVim/snacks-looking sidebar (icons + indented tree + expand/collapse)
-- that lists files on the remote backend via async fs_list RPCs. Unlike a
-- monkey-patch of snacks-explorer, this is async-native: expanding a directory
-- fires an fs_list and re-renders on response, so a slow SSH/srun link never
-- blocks the UI. Replaces the old netrw-style remote_browser.lua.
--
-- One instance per alias, keyed in `states`. Tree/expand state survives the
-- window being closed (:q) and reopened, so <leader>e toggling stays put.

local log = require("jupynvim.log")
local M = {}

-- ── icons (mini.icons if present, else nerd-font fallbacks) ──
local has_mini, MiniIcons = pcall(require, "mini.icons")
local function file_icon(name)
  if has_mini then
    local i, h = MiniIcons.get("file", name)
    return i or "", h
  end
  return "", nil
end
local function dir_icon(name)
  if has_mini then
    local i, h = MiniIcons.get("directory", name)
    return i or "", h
  end
  return "", "Directory"
end
local CHEV_CLOSED, CHEV_OPEN = "", ""  -- nf-fa-chevron_right / chevron_down

vim.api.nvim_set_hl(0, "JupynvimExplorerHeader", { default = true, link = "Title" })
vim.api.nvim_set_hl(0, "JupynvimExplorerDir",    { default = true, link = "Directory" })
vim.api.nvim_set_hl(0, "JupynvimExplorerLink",   { default = true, link = "Special" })
vim.api.nvim_set_hl(0, "JupynvimExplorerChevron",{ default = true, link = "Comment" })
local ns = vim.api.nvim_create_namespace("jupynvim.remote_explorer")

-- per-alias state:
--   { alias, root, buf, win,
--     expanded = { [dirpath]=true },
--     kids     = { [dirpath]={ loaded=bool, items={ {path,name,kind}, ... } } },
--     line_nodes = { [lnum]=node },
--     watchers = { [dirpath]=watcher_id }, _refresh_pending=bool }
local states = {}
-- watcher_id (namespaced by alias) -> { state, path }
local watch_registry = {}
local hooked_clients = setmetatable({}, { __mode = "k" })

local function client(alias)
  return require("jupynvim").client_for(alias)
end

local function join(dir, name)
  if dir == "/" then return "/" .. name end
  return dir .. "/" .. name
end

local function parent_of(path)
  return path:match("(.+)/[^/]+$")
end

-- ── data loading ──
local function items_from_entries(dir, entries)
  local items = {}
  for _, e in ipairs(entries or {}) do
    table.insert(items, { path = join(dir, e.name), name = e.name, kind = e.kind })
  end
  return items
end

local render  -- fwd decl

local function load_dir(state, dir, cb)
  client(state.alias):call("fs_list", { path = dir }, function(err, res)
    if err or not res then
      log.warn("explorer fs_list " .. dir .. ": " .. tostring(err))
      state.kids[dir] = { loaded = true, items = {} }
    else
      state.kids[dir] = { loaded = true, items = items_from_entries(res.path or dir, res.entries) }
    end
    if cb then cb() end
  end)
end

-- ── fs-watch (auto-refresh expanded dirs) ──
local function hook_fs_event(state)
  local cl = client(state.alias)
  if hooked_clients[cl] then return end
  hooked_clients[cl] = true
  local alias = state.alias
  cl:on("fs_event", function(args)
    local e = args[1] or args
    local reg = watch_registry[alias .. ":" .. tostring(e.watcher_id)]
    if not reg then return end
    local st = reg.state
    if st._refresh_pending then return end
    st._refresh_pending = true
    vim.defer_fn(function()
      st._refresh_pending = false
      if not (st.buf and vim.api.nvim_buf_is_valid(st.buf)) then return end
      if st.kids[reg.path] and st.kids[reg.path].loaded then
        load_dir(st, reg.path, function() render(st) end)
      end
    end, 200)
  end)
end

local function start_watch(state, dir)
  if state.watchers[dir] then return end
  hook_fs_event(state)
  client(state.alias):call("fs_watch", { path = dir, recursive = false }, function(err, res)
    if err or not res or not res.watcher_id then return end
    state.watchers[dir] = res.watcher_id
    watch_registry[state.alias .. ":" .. tostring(res.watcher_id)] = { state = state, path = dir }
  end)
end

-- ── rendering ──
render = function(state)
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then return end
  local lines = { "  " .. state.alias .. ":" .. (state.root or "") }
  local hls = { { 0, 0, -1, "JupynvimExplorerHeader" } }
  local line_nodes = {}

  local function walk(dir, depth)
    local entry = state.kids[dir]
    if not (entry and entry.loaded) then return end
    for _, node in ipairs(entry.items) do
      -- Hidden files (dotfiles) are hidden by default; toggle with `H`.
      if (not state.show_hidden) and node.name:sub(1, 1) == "." then
        goto continue
      end
      local indent = string.rep("  ", depth)
      local chev, icon, ihl, namehl, suffix
      if node.kind == "dir" then
        chev = state.expanded[node.path] and CHEV_OPEN or CHEV_CLOSED
        icon, ihl = dir_icon(node.name)
        namehl, suffix = "JupynvimExplorerDir", "/"
      else
        chev = " "
        icon, ihl = file_icon(node.name)
        namehl = (node.kind == "link") and "JupynvimExplorerLink" or nil
        suffix = (node.kind == "link") and "@" or ""
      end
      local prefix = " " .. indent .. chev .. " "
      local text = prefix .. icon .. " " .. node.name .. suffix
      table.insert(lines, text)
      local lnum = #lines
      line_nodes[lnum] = node
      local chev_col = 1 + #indent
      table.insert(hls, { lnum - 1, chev_col, chev_col + #chev, "JupynvimExplorerChevron" })
      local icon_col = #prefix
      if ihl then table.insert(hls, { lnum - 1, icon_col, icon_col + #icon, ihl }) end
      if namehl then table.insert(hls, { lnum - 1, icon_col + #icon + 1, -1, namehl }) end
      if node.kind == "dir" and state.expanded[node.path] then
        walk(node.path, depth + 1)
      end
      ::continue::
    end
  end
  walk(state.root, 0)

  state.line_nodes = line_nodes
  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false
  vim.bo[state.buf].modified = false
  vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
  for _, h in ipairs(hls) do
    pcall(vim.api.nvim_buf_add_highlight, state.buf, ns, h[4], h[1], h[2], h[3])
  end
end

-- ── cursor / nodes ──
local function node_at_cursor(state)
  if not (state.win and vim.api.nvim_win_is_valid(state.win)) then return nil end
  local lnum = vim.api.nvim_win_get_cursor(state.win)[1]
  return state.line_nodes[lnum], lnum
end

local function dir_context(state)
  local node = node_at_cursor(state)
  if not node then return state.root end
  if node.kind == "dir" then return node.path end
  return parent_of(node.path) or state.root
end

-- find a non-explorer, non-floating window to open files into
local function main_editor_win(state)
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if w ~= state.win and vim.api.nvim_win_get_config(w).relative == "" then
      local b = vim.api.nvim_win_get_buf(w)
      if not vim.b[b].jupynvim_explorer then return w end
    end
  end
  return nil
end

local function open_node(state, node)
  local J = require("jupynvim")
  local target = main_editor_win(state)
  if not target then
    vim.api.nvim_set_current_win(state.win)
    vim.cmd("rightbelow vsplit")
    target = vim.api.nvim_get_current_win()
  end
  vim.api.nvim_set_current_win(target)
  if node.name:sub(-6) == ".ipynb" then
    J.use_remote(state.alias)
    J.open(node.path, { alias = state.alias })
  else
    vim.cmd("edit jupynvim://" .. state.alias .. node.path)
  end
end

local function set_expanded(state, node, want)
  state.expanded[node.path] = want or nil
  if want and not (state.kids[node.path] and state.kids[node.path].loaded) then
    load_dir(state, node.path, function() render(state); start_watch(state, node.path) end)
  else
    render(state)
  end
end

-- ── actions ──
local function act_cr(state)
  local node = node_at_cursor(state)
  if not node then return end
  if node.kind == "dir" then
    set_expanded(state, node, not state.expanded[node.path])
  else
    open_node(state, node)
  end
end

local function act_collapse(state)
  local node, lnum = node_at_cursor(state)
  if not node then return end
  if node.kind == "dir" and state.expanded[node.path] then
    state.expanded[node.path] = nil
    render(state)
    return
  end
  local parent = parent_of(node.path)
  if parent and state.expanded[parent] then
    state.expanded[parent] = nil
    render(state)
    for i, n in pairs(state.line_nodes) do
      if n.path == parent then pcall(vim.api.nvim_win_set_cursor, state.win, { i, 0 }); break end
    end
  end
  local _ = lnum
end

local function reload_dir(state, dir)
  if state.kids[dir] and state.kids[dir].loaded then
    load_dir(state, dir, function() render(state) end)
  end
end

local function act_create(state)
  local dir = dir_context(state)
  vim.ui.input({ prompt = "New (end with / for dir): " }, function(name)
    if not name or name == "" then return end
    local is_dir = name:sub(-1) == "/"
    if is_dir then name = name:sub(1, -2) end
    local target = join(dir, name)
    local method = is_dir and "fs_mkdir" or "fs_write"
    local args = is_dir and { path = target, parents = true } or { path = target, content_b64 = "" }
    client(state.alias):call(method, args, function(err)
      if err then vim.notify("create failed: " .. tostring(err), vim.log.levels.ERROR); return end
      reload_dir(state, dir)
    end)
  end)
end

local function act_delete(state)
  local node = node_at_cursor(state)
  if not node then return end
  vim.ui.input({ prompt = ("Delete %s '%s'? [y/N] "):format(node.kind, node.name) }, function(ans)
    if not ans or ans:lower() ~= "y" then return end
    client(state.alias):call("fs_rm", { path = node.path, recursive = (node.kind == "dir") }, function(err)
      if err then vim.notify("delete failed: " .. tostring(err), vim.log.levels.ERROR); return end
      reload_dir(state, parent_of(node.path) or state.root)
    end)
  end)
end

local function act_rename(state)
  local node = node_at_cursor(state)
  if not node then return end
  vim.ui.input({ prompt = "Rename to: ", default = node.name }, function(newname)
    if not newname or newname == "" or newname == node.name then return end
    local dir = parent_of(node.path) or state.root
    client(state.alias):call("fs_rename", { src = node.path, dst = join(dir, newname) }, function(err)
      if err then vim.notify("rename failed: " .. tostring(err), vim.log.levels.ERROR); return end
      reload_dir(state, dir)
    end)
  end)
end

function M.refresh(alias)
  local state = states[alias]
  if not state then return end
  local dirs = {}
  for p, e in pairs(state.kids) do if e.loaded then table.insert(dirs, p) end end
  local pending = #dirs
  if pending == 0 then return end
  for _, p in ipairs(dirs) do
    load_dir(state, p, function()
      pending = pending - 1
      if pending == 0 then render(state) end
    end)
  end
end

-- ── window / buffer setup ──
local function set_win_opts(win)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
  vim.wo[win].winfixwidth = true
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].statuscolumn = ""
end

local function bind_keys(state)
  local buf = state.buf
  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
  end
  map("<CR>", function() act_cr(state) end)
  map("l", function() act_cr(state) end)
  map("o", function() act_cr(state) end)
  map("<2-LeftMouse>", function() act_cr(state) end)
  map("h", function() act_collapse(state) end)
  map("H", function() state.show_hidden = not state.show_hidden; render(state) end)
  map("R", function() M.refresh(state.alias) end)
  map("a", function() act_create(state) end)
  map("d", function() act_delete(state) end)
  map("r", function() act_rename(state) end)
  map("q", function() if state.win and vim.api.nvim_win_is_valid(state.win) then pcall(vim.api.nvim_win_close, state.win, true) end end)
end

-- Close any local file explorer so ours takes the sidebar slot. Narrow match
-- so we do NOT close the snacks dashboard (snacks_dashboard).
local function close_local_explorers()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local b = vim.api.nvim_win_get_buf(w)
    local ft = vim.bo[b].filetype or ""
    if ft:match("^snacks_picker") or ft == "snacks_explorer"
       or ft == "neo-tree" or ft == "NvimTree" or ft == "oil" or ft == "minifiles" then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
end

-- Replace a local startup dashboard (snacks/alpha/etc) or empty [No Name] in
-- the main pane with a blank scratch, so while SSH-connected the user doesn't
-- see the LOCAL dashboard's "Find File / Recent" (which act locally) next to
-- a remote tree. The blank pane is where tree-opened files land.
local function neutralize_dashboard()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative == "" then
      local b = vim.api.nvim_win_get_buf(w)
      local ft = vim.bo[b].filetype or ""
      local empty = vim.api.nvim_buf_get_name(b) == ""
        and #vim.api.nvim_buf_get_lines(b, 0, -1, false) <= 1
        and (vim.api.nvim_buf_get_lines(b, 0, 1, false)[1] or "") == ""
      if ft == "snacks_dashboard" or ft == "dashboard" or ft == "alpha"
         or ft == "starter" or ft == "ministarter" or (empty and not vim.b[b].jupynvim_explorer) then
        local scratch = vim.api.nvim_create_buf(true, false)
        pcall(vim.api.nvim_win_set_buf, w, scratch)
      end
    end
  end
end

local function make_sidebar_for(state)
  close_local_explorers()
  neutralize_dashboard()
  vim.cmd("topleft 36vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, state.buf)
  state.win = win
  set_win_opts(win)
end

-- The window currently showing this alias's explorer buffer, or nil.
function M.visible_win(alias)
  local state = states[alias]
  if not (state and state.buf and vim.api.nvim_buf_is_valid(state.buf)) then return nil end
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(w) == state.buf then return w end
  end
  return nil
end

-- Open (or focus) the remote explorer for `alias`, rooted at `root_path`
-- (defaults to remote $HOME via "~"). Tree/expand state persists across
-- close+reopen.
function M.open(alias, root_path)
  local state = states[alias]

  -- Reuse existing instance + tree state if its buffer is still alive.
  if state and state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(w) == state.buf then
        vim.api.nvim_set_current_win(w)
        return state.buf, w
      end
    end
    make_sidebar_for(state)
    render(state)
    return state.buf, state.win
  end

  -- Fresh instance.
  state = state or { alias = alias }
  state.expanded = state.expanded or {}
  state.kids = {}
  state.line_nodes = {}
  state.watchers = {}
  states[alias] = state

  local buf = vim.api.nvim_create_buf(false, true)
  state.buf = buf
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].buflisted = false
  vim.bo[buf].filetype = "jupynvim-explorer"
  vim.b[buf].jupynvim_explorer = true
  vim.b[buf].jupynvim_alias = alias
  make_sidebar_for(state)
  bind_keys(state)

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "  loading " .. (root_path or "~") .. " ..." })
  vim.bo[buf].modifiable = false

  client(alias):call("fs_list", { path = root_path or "~" }, function(err, res)
    if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then return end
    if err or not res then
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
        "  [" .. alias .. "] error", "", "  " .. tostring(err),
        "", "  • backend installed at remote core_path?",
        "  • :JupynvimUseJob " .. alias .. " <jobid> stale?",
      })
      vim.bo[buf].modifiable = false
      return
    end
    state.root = res.path or root_path
    state.kids[state.root] = { loaded = true, items = items_from_entries(state.root, res.entries) }
    render(state)
    start_watch(state, state.root)
  end)

  return buf, state.win
end

-- Drop cached state for an alias (called on disconnect so a reconnect
-- re-lists fresh).
function M.reset(alias)
  states[alias] = nil
end

return M

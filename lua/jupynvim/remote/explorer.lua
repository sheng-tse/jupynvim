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

-- When snacks.picker is available, the explorer is the picker-based
-- implementation (identical to the local snacks explorer: permanent input
-- box, live tree filtering). This buffer-tree version remains the fallback
-- for non-snacks setups, keeping the feature general for all users.
local function picker_impl()
  local ok = pcall(require, "snacks")
  if ok and package.loaded["snacks"] and Snacks and Snacks.picker then
    return require("jupynvim.remote.explorer_picker")
  end
  return nil
end

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
vim.api.nvim_set_hl(0, "JupynvimExplorerIgnored",{ default = true, link = "Comment" })
vim.api.nvim_set_hl(0, "JupynvimExplorerRootIcon",{ default = true, link = "Directory" })
local ns = vim.api.nvim_create_namespace("jupynvim.remote.explorer")

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
    table.insert(items, { path = join(dir, e.name), name = e.name, kind = e.kind, ignored = e.ignored })
  end
  return items
end

local render     -- fwd decl
local load_root  -- fwd decl

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
  -- Root header: open-folder icon + basename (not the full path), like snacks.
  local root = state.root or ""
  local base = root:match("[^/]+$") or root
  if base == "" then base = "/" end
  local root_icon = vim.fn.nr2char(0xF07C)  -- open folder
  local header = " " .. root_icon .. " " .. base
  local lines = { header }
  local hls = {
    { 0, 1, 1 + #root_icon, "JupynvimExplorerRootIcon" },
    { 0, 1 + #root_icon, -1, "JupynvimExplorerHeader" },
  }
  local line_nodes = {}

  local function walk(dir, depth)
    local entry = state.kids[dir]
    if not (entry and entry.loaded) then return end
    for _, node in ipairs(entry.items) do
      -- Dotfiles hidden by default (toggle `H`); gitignored hidden by default
      -- (toggle `I`). Matches snacks/LazyVim.
      if (not state.show_hidden) and node.name:sub(1, 1) == "." then
        goto continue
      end
      if (not state.show_ignored) and node.ignored then
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
      -- Dim gitignored entries when revealed (like snacks).
      if node.ignored then namehl = "JupynvimExplorerIgnored"; ihl = "JupynvimExplorerIgnored" end
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
    -- col1 = -1 means "to end of line", which extmarks spell as the next row
    -- at col 0. Passing end_col = -1 errors and the pcall would eat it.
    local o = { hl_group = h[4], end_col = h[3] }
    if h[3] < 0 then o.end_row, o.end_col = h[1] + 1, 0 end
    pcall(vim.api.nvim_buf_set_extmark, state.buf, ns, h[1], h[2], o)
  end
end
M._render = render         -- exposed for tests

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

-- find a non-explorer, non-floating, non-terminal window to open files into.
-- Skipping terminals matters with the bottom/right remote terminals open: a
-- file must land in the main editor area, never hijack a terminal window.
local function main_editor_win(state)
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if w ~= state.win and vim.api.nvim_win_get_config(w).relative == "" then
      local b = vim.api.nvim_win_get_buf(w)
      -- Skip the explorer and the remote terminals. The remote terminals are
      -- `nofile` buffers (nvim_open_term) marked with jupynvim_term_alias, NOT
      -- buftype="terminal", so check that marker. A file must land in the main
      -- editor area, never hijack a terminal window.
      if not vim.b[b].jupynvim_explorer and not vim.b[b].jupynvim_term_alias then
        return w
      end
    end
  end
  return nil
end
M._main_editor_win = main_editor_win   -- exposed for tests

local function open_node(state, node)
  local J = require("jupynvim")
  local target = main_editor_win(state)
  local relocated_slot  -- set when a terminal was pushed below the new file
  if not target then
    -- No editor window: the main area is a terminal (e.g. right after closing
    -- the dashboard). Put the file ON TOP of that terminal and push the
    -- terminal below it (its C-/ home), instead of splitting off the explorer,
    -- which dumped the file at the far left.
    local termwin, tslot
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      local b = vim.api.nvim_win_get_buf(w)
      if w ~= state.win and vim.api.nvim_win_get_config(w).relative == ""
         and vim.b[b].jupynvim_term_alias then
        termwin = w
        tslot = vim.b[b].jupynvim_term_slot or "below"
        break
      end
    end
    if termwin then
      vim.api.nvim_set_current_win(termwin)
      -- "below" terminal fills the main area -> file on top (horizontal).
      -- "right"/"left" column terminal stays a column -> file beside it.
      if tslot == "below" then
        vim.cmd("aboveleft split")
      elseif tslot == "left" then
        vim.cmd("belowright vsplit")
      else
        vim.cmd("aboveleft vsplit")
      end
      target = vim.api.nvim_get_current_win()
      relocated_slot = tslot
    else
      vim.api.nvim_set_current_win(state.win)
      vim.cmd("rightbelow vsplit")
      target = vim.api.nvim_get_current_win()
    end
  end
  vim.api.nvim_set_current_win(target)
  if node.name:sub(-6) == ".ipynb" then
    J.use_remote(state.alias)
    J.open(node.path, { alias = state.alias })
  else
    local uri = "jupynvim://" .. state.alias .. node.path
    vim.cmd("edit " .. uri)
    -- Force the file into the INTENDED target window. LazyVim/neo-tree/snacks
    -- can auto-split on :edit and move focus to a stray window (the file showed
    -- up at the far left); keying off the focused window would then close the
    -- real target. Resolve the buffer by URI (focus may have moved), set it in
    -- target, and close every OTHER window showing it. The scheduled repeat
    -- catches DEFERRED plugin auto-splits that happen on the next tick.
    local function force_into_target()
      if not (target and vim.api.nvim_win_is_valid(target)) then return end
      local b = vim.fn.bufnr(uri)
      if b == -1 then return end
      pcall(vim.api.nvim_win_set_buf, target, b)
      for _, w in ipairs(vim.fn.win_findbuf(b)) do
        if w ~= target then pcall(vim.api.nvim_win_close, w, true) end
      end
      pcall(vim.api.nvim_set_current_win, target)
    end
    force_into_target()
    vim.schedule(force_into_target)
  end
  -- The relocated terminal had expanded to fill the main area; shrink it back
  -- to its compact slot size. MUST run AFTER opening the file: resizing before
  -- the :edit/render gets undone when the file loads. The scheduled backstop
  -- covers async (notebook image) renders that resize on a later tick.
  if relocated_slot then
    local rt = require("jupynvim.remote.term")
    pcall(rt.restore_size, state.alias, relocated_slot)
    vim.schedule(function() pcall(rt.restore_size, state.alias, relocated_slot) end)
  end
end
M._open_node = open_node   -- exposed for tests
M._states = states         -- exposed for tests

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
-- Use nvim_set_option_value with scope="local": `vim.wo[win].x = v` on the
-- CURRENT window leaks window-local options like 'number' to the GLOBAL value
-- (Neovim quirk), which turned line numbers off everywhere after opening the
-- explorer. scope="local" sets only this window.
local function setlocalwin(win, name, val)
  pcall(vim.api.nvim_set_option_value, name, val, { scope = "local", win = win })
end
local function set_win_opts(win)
  setlocalwin(win, "number", false)
  setlocalwin(win, "relativenumber", false)
  setlocalwin(win, "signcolumn", "no")
  setlocalwin(win, "wrap", false)
  setlocalwin(win, "cursorline", true)
  setlocalwin(win, "winfixwidth", true)
  setlocalwin(win, "foldcolumn", "0")
  setlocalwin(win, "statuscolumn", "")
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
  map("I", function() state.show_ignored = not state.show_ignored; render(state) end)
  map("R", function() M.refresh(state.alias) end)
  -- Re-root: `-` go up one level (reach /ocean/... from home), `.` jump to a
  -- path. Lets you browse anywhere on the remote, not just $HOME.
  -- Re-rooting here is BROWSING, not a cd: it must not move where <leader>e
  -- and <leader>E take you back to. Only :JupynvimRemoteCd designates that.
  map("-", function()
    local up = parent_of(state.root)
    if up then load_root(state, up) end
  end)
  map(".", function()
    vim.ui.input({ prompt = "Set explorer root: ", default = state.root .. "/" }, function(p)
      if p and p ~= "" then load_root(state, (p:gsub("/+$", ""):gsub("^$", "/"))) end
    end)
  end)
  -- `/` fuzzy-find files under the current root (remote), like snacks explorer.
  -- Same layout as the snacks explorer search (sidebar preset: bordered input
  -- with title on top, list below, left strip) instead of a centered popup.
  -- (Grep file contents is on the global <leader>/ / <leader>sg dispatch.)
  map("/", function()
    require("jupynvim.remote.pick").files(state.alias, state.root, {
      layout = { preset = "sidebar", preview = false },
    })
  end)
  map("a", function() act_create(state) end)
  map("d", function() act_delete(state) end)
  map("r", function() act_rename(state) end)
  map("q", function() if state.win and vim.api.nvim_win_is_valid(state.win) then pcall(vim.api.nvim_win_close, state.win, true) end end)
  -- The buffer is nomodifiable; neutralize the reflexive insert/edit keys so
  -- pressing i/A/o/c/p/x/etc doesn't throw E21 ("Cannot make changes").
  for _, k in ipairs({ "i", "A", "O", "c", "C", "s", "S", "x", "X", "p", "P", "D", "u", "<C-r>" }) do
    map(k, function() end)
  end
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

-- Replace a startup dashboard (local snacks/alpha, or our own jupynvim
-- dashboard) in any non-explorer main pane with the jupynvim remote dashboard
-- (logo + actions), built to that window's width. So while SSH-connected the
-- user sees a jupynvim landing screen, not the LOCAL dashboard whose
-- Find File / Recent act locally.
local function place_dashboard(state)
  local RD = require("jupynvim.remote.dashboard")
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if w ~= state.win and vim.api.nvim_win_get_config(w).relative == "" then
      local ft = vim.bo[vim.api.nvim_win_get_buf(w)].filetype or ""
      if ft == "snacks_dashboard" or ft == "dashboard" or ft == "alpha"
         or ft == "starter" or ft == "ministarter" or ft == "jupynvim-dashboard" then
        local dbuf = RD.build(state.alias, state.root or "~", w)
        pcall(vim.api.nvim_win_set_buf, w, dbuf)
      end
    end
  end
  -- Re-center once the split layout has fully settled (the first build can run
  -- before the window reaches its final size, which made the logo position
  -- jump between first-open and later toggles). The deferred refresh pins it.
  vim.schedule(function() RD.refresh_layout() end)
end

-- Close any window already showing a jupynvim explorer (any alias / orphaned),
-- so opening never stacks a second sidebar. Never closes the last window.
local function close_existing_explorer_windows()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(w)
       and vim.b[vim.api.nvim_win_get_buf(w)].jupynvim_explorer
       and #vim.api.nvim_list_wins() > 1 then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
end

-- Close leftover empty [No Name] windows (e.g. the buffer `vim .` or a prior
-- split leaves behind) so the layout is just: explorer sidebar + main pane.
-- Never closes explorer/dashboard windows, real files, or the last window.
local function close_empty_windows(keep_win)
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if w ~= keep_win and vim.api.nvim_win_is_valid(w)
       and vim.api.nvim_win_get_config(w).relative == ""
       and #vim.api.nvim_list_wins() > 1 then
      local b = vim.api.nvim_win_get_buf(w)
      local nameless = vim.api.nvim_buf_get_name(b) == ""
      local oneline = #vim.api.nvim_buf_get_lines(b, 0, -1, false) <= 1
        and (vim.api.nvim_buf_get_lines(b, 0, 1, false)[1] or "") == ""
      local plain = (vim.bo[b].buftype == "" or vim.bo[b].buftype == "nofile")
      if nameless and oneline and plain
         and not vim.b[b].jupynvim_explorer and not vim.b[b].jupynvim_dashboard then
        pcall(vim.api.nvim_win_close, w, false)
      end
    end
  end
end

local function make_sidebar_for(state)
  close_local_explorers()
  vim.cmd("topleft 36vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, state.buf)
  state.win = win
  set_win_opts(win)
  place_dashboard(state)
  close_empty_windows(win)
end

-- The explorer's current root dir for an alias (where the user has browsed /
-- remote-cd'd to), or nil. Used so a new remote terminal opens there.
function M.current_root(alias)
  local pi = picker_impl()
  if pi then
    local r = pi.current_root(alias)
    if r then return r end
  end
  local st = states[alias]
  return st and st.root or nil
end

-- The window currently showing this alias's explorer, or nil.
function M.visible_win(alias)
  local pi = picker_impl()
  if pi then return pi.visible_win(alias) end
  local state = states[alias]
  if not (state and state.buf and vim.api.nvim_buf_is_valid(state.buf)) then return nil end
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(w) == state.buf then return w end
  end
  return nil
end

-- Hide the explorer (used by the <leader>e toggle).
function M.close(alias)
  local pi = picker_impl()
  if pi then return pi.close(alias) end
  local win = M.visible_win(alias)
  if win and #vim.api.nvim_list_wins() > 1 then
    pcall(vim.api.nvim_win_close, win, false)
  end
end

-- Open (or focus) the remote explorer for `alias`, rooted at `root_path`
-- (defaults to remote $HOME via "~"). Tree/expand state persists across
-- close+reopen.
function M.open(alias, root_path, opts)
  local pi = picker_impl()
  if pi then return pi.open(alias, root_path, opts) end
  -- Already visible for this alias → just focus it (no new window).
  local shown = M.visible_win(alias)
  if shown then
    vim.api.nvim_set_current_win(shown)
    return states[alias].buf, shown
  end

  -- Not visible: close any stray/other explorer windows so we don't stack.
  close_existing_explorer_windows()

  local state = states[alias]
  -- Reuse existing instance + tree state if its buffer is still alive.
  if state and state.buf and vim.api.nvim_buf_is_valid(state.buf) then
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

  load_root(state, root_path or "~")
  return buf, state.win
end

-- (Re)list `root_path` as the explorer's new root: clears the tree, fs_lists,
-- renders, starts a watch. Used on open and on re-rooting (-, ., :JupynvimRemoteCd).
load_root = function(state, root_path)
  local buf = state.buf
  state.kids = {}
  state.expanded = {}
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "  loading " .. (root_path or "~") .. " ..." })
  vim.bo[buf].modifiable = false
  -- Loading-timeout guard: if the backend never answers (dead node / hung
  -- spawn), don't sit on "loading..." forever — show an escapable error so
  -- `q` works. `done` is flipped by whichever (callback or timeout) fires first.
  local done = false
  vim.defer_fn(function()
    if done or not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then return end
    if not state.root then
      done = true
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
        "  [" .. state.alias .. "] timed out", "",
        "  the remote backend did not respond.", "",
        "  • node/job may be down — :JupynvimUseJob " .. state.alias .. " <new jobid>",
        "  • or :JupynvimDisconnect " .. state.alias .. " then reconnect",
        "", "  press q to close",
      })
      vim.bo[buf].modifiable = false
    end
  end, 35000)
  client(state.alias):call("fs_list", { path = root_path or "~" }, function(err, res)
    if done or not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then return end
    done = true
    if err or not res then
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
        "  [" .. state.alias .. "] error", "", "  " .. tostring(err),
        "", "  • backend installed at remote core_path?",
        "  • :JupynvimUseJob " .. state.alias .. " <jobid> stale?",
      })
      vim.bo[buf].modifiable = false
      return
    end
    state.root = res.path or root_path
    state.kids[state.root] = { loaded = true, items = items_from_entries(state.root, res.entries) }
    render(state)
    start_watch(state, state.root)
    place_dashboard(state)
  end)
end

-- Change the explorer root for an alias (used by re-root keys + :JupynvimRemoteCd).
function M.set_root(alias, path)
  local pi = picker_impl()
  if pi then return pi.set_root(alias, path) end
  local state = states[alias]
  if not state then return M.open(alias, path) end
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then return M.open(alias, path) end
  -- Focus the explorer window if it isn't current.
  local win = M.visible_win(alias)
  if win then vim.api.nvim_set_current_win(win) end
  load_root(state, path)
end

-- Drop cached state for an alias (called on disconnect / job-switch so a
-- reconnect re-lists fresh). Wipes the old buffer too, which also closes any
-- window still showing it (prevents orphaned/stacked sidebars).
function M.reset(alias)
  local pi = picker_impl()
  if pi then pi.reset(alias) end
  local st = states[alias]
  if st and st.buf and vim.api.nvim_buf_is_valid(st.buf) then
    pcall(vim.api.nvim_buf_delete, st.buf, { force = true })
  end
  states[alias] = nil
end

return M

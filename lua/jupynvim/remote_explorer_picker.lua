-- Remote explorer as a REAL snacks picker, mirroring the local snacks
-- explorer 1:1: permanent bordered "Explorer" input on top, tree below with
-- icons + indent guides, and live filtering that shows matches as a tree with
-- their parent dirs (matcher keep_parents). Data comes from the jupynvim
-- backend over msgpack-RPC (fs_list for browsing, find_files for filtering),
-- so it works on any SSH remote.
--
-- remote_explorer.lua delegates here when snacks.picker is available and
-- keeps the plain tree buffer as the fallback for non-snacks setups.

local M = {}

-- alias -> { alias, root, expanded, kids, files_cache, picker }
local states = {}
M._states = states  -- exposed for tests/debugging

local function J() return require("jupynvim") end
local function client(alias) return J().client_for(alias) end

-- The explorer is a snacks SIDEBAR split: opening/closing it narrows/widens
-- the notebook window. Re-render notebook frames via the shared helper
-- (synchronous rebuild + a scheduled backstop, both before the redraw, so
-- no stale-frame flash). Used here for the q/close-key path that the
-- <leader>e dispatcher doesn't go through.
local function refresh_notebooks()
  pcall(function() require("jupynvim")._refresh_notebooks_soon() end)
end
local function uri(alias, p) return "jupynvim://" .. alias .. p end

local function join(dir, name)
  if dir == "/" then return "/" .. name end
  return dir .. "/" .. name
end

local function excludes_for(alias)
  local rp = require("jupynvim.remote_pick")
  local ex = vim.deepcopy(rp.DEFAULT_EXCLUDES)
  local prof = (J().config.remote or {})[alias] or {}
  for _, e in ipairs(prof.find_excludes or {}) do table.insert(ex, e) end
  return ex
end

-- ── data fetch ─────────────────────────────────────────────────────────────

local function fetch_dir(state, dir, cb)
  client(state.alias):call("fs_list", { path = dir }, function(err, res)
    if err or not res then
      vim.notify("jupynvim: fs_list failed: " .. tostring(err), vim.log.levels.WARN)
      return cb(false)
    end
    local resolved = res.path or dir
    if dir == state.root then state.root = resolved end  -- "~" -> absolute
    local items = {}
    for _, e in ipairs(res.entries or {}) do
      table.insert(items, { name = e.name, dir = e.kind == "dir", ignored = e.ignored and true or nil })
    end
    table.sort(items, function(a, b)
      if (a.dir or false) ~= (b.dir or false) then return a.dir or false end
      return a.name < b.name
    end)
    state.kids[resolved] = items
    cb(true)
  end)
end

local function fetch_files(state, hidden, cb)
  client(state.alias):call("find_files", {
    path = state.root, max = 20000, hidden = hidden and true or false,
    excludes = excludes_for(state.alias),
  }, function(err, res)
    if err or not res then
      vim.notify("jupynvim: find_files failed: " .. tostring(err), vim.log.levels.WARN)
      return cb(false)
    end
    state.root = res.root or state.root
    state.files_cache = res.files or {}
    -- Pruned dirs (miniconda3, node_modules, ...): not scanned, but shown in
    -- the filter as navigable dirs so you can still reach them.
    state.pruned_cache = res.pruned_dirs or {}
    cb(true)
  end)
end

-- ── item building (snacks tree contract: parent / last / sort) ─────────────

local function root_item(state)
  return {
    file = uri(state.alias, state.root),
    text = state.root,
    dir = true, open = true, last = true, sort = "",
    jv_path = state.root,
  }
end

local function browse_items(state, opts, picker)
  local items = {}
  local root = root_item(state)
  table.insert(items, root)
  state._lazy = state._lazy or {}
  local function lazy_fetch(path)
    if state._lazy[path] then return end
    state._lazy[path] = true
    fetch_dir(state, path, function(ok)
      state._lazy[path] = nil
      if ok and picker and not picker.closed then picker:find() end
    end)
  end
  local function walk(dir, parent)
    local sibs = {}
    for _, k in ipairs(state.kids[dir] or {}) do
      local hidden = k.name:sub(1, 1) == "."
      if (opts.hidden or not hidden) and (opts.ignored or not k.ignored) then
        table.insert(sibs, k)
      end
    end
    for i, k in ipairs(sibs) do
      local path = join(dir, k.name)
      local item = {
        file = uri(state.alias, path),
        text = path,
        dir = k.dir or nil,
        open = (k.dir and state.expanded[path]) or nil,
        parent = parent,
        last = i == #sibs,
        hidden = k.name:sub(1, 1) == "." or nil,
        ignored = k.ignored,
        sort = parent.sort .. (k.dir and "!" or "#") .. k.name .. " ",
        jv_path = path,
      }
      table.insert(items, item)
      if k.dir and state.expanded[path] then
        if state.kids[path] then walk(path, item)
        else lazy_fetch(path) end  -- expanded but not yet listed: fill in async
      end
    end
  end
  walk(state.root, root)
  return items
end

-- Filter mode: the full recursive file list rendered as a tree (intermediate
-- dirs synthesized, like snacks explorer's fd search). `last` goes to the
-- max-sort child per parent, matching snacks' computation under sorting.
local function search_items(state)
  local items = {}
  local root = root_item(state)
  table.insert(items, root)
  local dirs = { [state.root] = root }
  local last = {}
  local function dir_item(abs, rel)
    if dirs[abs] then return dirs[abs] end
    local parent_abs = abs:match("^(.*)/[^/]+$")
    local parent = (parent_abs and parent_abs ~= "" and parent_abs:sub(1, #state.root) == state.root)
      and dir_item(parent_abs, rel:match("^(.*)/[^/]+$") or "") or root
    local item = {
      file = uri(state.alias, abs),
      text = rel,
      dir = true, open = true, internal = true,
      parent = parent,
      sort = parent.sort .. "!" .. (abs:match("[^/]+$") or abs) .. " ",
      jv_path = abs,
    }
    if not last[parent] or last[parent].sort < item.sort then
      if last[parent] then last[parent].last = false end
      item.last = true
      last[parent] = item
    end
    dirs[abs] = item
    table.insert(items, item)
    return item
  end
  for _, rel in ipairs(state.files_cache or {}) do
    local abs = join(state.root, rel)
    local reldir = rel:match("^(.*)/[^/]+$")
    local parent = reldir and dir_item(join(state.root, reldir), reldir) or root
    local item = {
      file = uri(state.alias, abs),
      text = rel,
      parent = parent,
      sort = parent.sort .. "#" .. (rel:match("[^/]+$") or rel) .. " ",
      jv_path = abs,
    }
    if not last[parent] or last[parent].sort < item.sort then
      if last[parent] then last[parent].last = false end
      item.last = true
      last[parent] = item
    end
    table.insert(items, item)
  end
  -- Pruned dirs (not scanned): show as navigable dir leaves. Confirming one
  -- re-roots the explorer into it (its contents weren't scanned).
  for _, rel in ipairs(state.pruned_cache or {}) do
    local abs = join(state.root, rel)
    local reldir = rel:match("^(.*)/[^/]+$")
    local parent = reldir and dir_item(join(state.root, reldir), reldir) or root
    table.insert(items, {
      file = uri(state.alias, abs),
      text = rel,
      dir = true,
      parent = parent,
      sort = parent.sort .. "!" .. (rel:match("[^/]+$") or rel) .. " ",
      jv_path = abs,
      jv_pruned = true,
    })
  end
  return items
end

-- ── finder ─────────────────────────────────────────────────────────────────

local function finder(_opts, ctx)
  local alias = ctx.picker.opts.jupynvim_alias
  local state = states[alias]
  if not state then return {} end
  ctx.picker.matcher.opts.keep_parents = false
  if not ctx.filter:is_empty() then
    ctx.picker.matcher.opts.keep_parents = true
    if state.files_cache then return search_items(state) end
    -- Fetch in the background, re-find when it lands. Return the root item
    -- so the picker has content and stays open meanwhile.
    if not state._fetching_files then
      state._fetching_files = true
      fetch_files(state, ctx.picker.opts.hidden, function(ok)
        state._fetching_files = nil
        if ok and not ctx.picker.closed then ctx.picker:find() end
      end)
    end
    return { root_item(state) }
  end
  if not state.kids[state.root] then
    if not state._fetching_dir then
      state._fetching_dir = true
      fetch_dir(state, state.root, function(ok)
        state._fetching_dir = nil
        if ok and not ctx.picker.closed then ctx.picker:find() end
      end)
    end
    return { root_item(state) }
  end
  return browse_items(state, ctx.picker.opts, ctx.picker)
end

-- ── actions ────────────────────────────────────────────────────────────────

local function state_of(picker) return states[picker.opts.jupynvim_alias] end

-- Remember the current list position before a re-find so the cursor stays on
-- the same item after the tree rebuilds (snacks re-targets on set_target()).
-- Without this every expand/collapse jumped the cursor back to the root.
local function refind(picker)
  pcall(function() picker.list:set_target() end)
  picker:find()
end

-- Directory context for create/delete/rename: the item's dir, or its parent.
local function dir_of(state, item)
  if not item or not item.jv_path then return state.root end
  if item.dir then return item.jv_path end
  return item.jv_path:match("^(.*)/[^/]+$") or state.root
end

local function reload_dir(state, picker, dir)
  pcall(function() picker.list:set_target() end)
  state.kids[dir] = nil
  state.files_cache = nil
  fetch_dir(state, dir, function(ok)
    if ok and not picker.closed then picker:find() end
  end)
end

local ACTIONS = {
  confirm = function(picker, item, action)
    local state = state_of(picker)
    if not (state and item) then return end
    if picker.input.filter.meta.searching then
      if item.dir then
        -- navigate into a dir match (e.g. a pruned dir like miniconda3 whose
        -- contents weren't scanned): re-root there and clear the filter.
        M.set_root(state.alias, item.jv_path)
      else
        require("jupynvim.remote_pick").open_in_editor(item.file)  -- editor, not a term
      end
      return
    end
    if item.dir then
      local p = item.jv_path
      if p == state.root then return end
      pcall(function() picker.list:set_target() end)  -- keep cursor on this dir
      if state.expanded[p] then
        state.expanded[p] = nil
        picker:find()
      else
        state.expanded[p] = true
        if state.kids[p] then picker:find()
        else
          fetch_dir(state, p, function(ok)
            if ok and not picker.closed then picker:find() end
          end)
        end
      end
    else
      require("jupynvim.remote_pick").open_in_editor(item.file)  -- editor, not a term
    end
  end,
  jv_close_dir = function(picker, item)
    local state = state_of(picker)
    if not (state and item) then return end
    if item.dir and state.expanded[item.jv_path] then
      state.expanded[item.jv_path] = nil
      refind(picker)
    elseif item.parent and item.parent.jv_path and item.parent.jv_path ~= state.root then
      state.expanded[item.parent.jv_path] = nil
      refind(picker)
    end
  end,
  jv_up = function(picker)
    local state = state_of(picker)
    if not state then return end
    local up = state.root:match("^(.*)/[^/]+$")
    if up == "" then up = "/" end
    if up and up ~= state.root then M.set_root(state.alias, up) end
  end,
  jv_set_root = function(picker)
    local state = state_of(picker)
    if not state then return end
    vim.ui.input({ prompt = "Explorer root: ", default = state.root .. "/" }, function(p)
      if p and p ~= "" then M.set_root(state.alias, (p:gsub("/+$", ""))) end
    end)
  end,
  jv_refresh = function(picker)
    local state = state_of(picker)
    if not state then return end
    state.kids = {}
    state.files_cache = nil
    reload_dir(state, picker, state.root)
  end,
  jv_toggle_hidden = function(picker)
    picker.opts.hidden = not picker.opts.hidden
    local state = state_of(picker)
    if state then state.files_cache = nil end  -- hidden affects find_files too
    refind(picker)
  end,
  jv_toggle_ignored = function(picker)
    picker.opts.ignored = not picker.opts.ignored
    refind(picker)
  end,
  jv_add = function(picker, item)
    local state = state_of(picker)
    if not state then return end
    local base = dir_of(state, item)
    vim.ui.input({ prompt = "New (end with / for dir): " .. base .. "/" }, function(name)
      if not name or name == "" then return end
      local is_dir = name:sub(-1) == "/"
      local path = join(base, (name:gsub("/+$", "")))
      local cl = client(state.alias)
      local function done(err)
        if err then return vim.notify("jupynvim: create failed: " .. tostring(err), vim.log.levels.ERROR) end
        if is_dir then state.expanded[path] = nil end
        reload_dir(state, picker, base)
      end
      if is_dir then
        cl:call("fs_mkdir", { path = path, parents = true }, function(err) done(err) end)
      else
        cl:call("fs_write", { path = path, content_b64 = vim.base64.encode("") }, function(err) done(err) end)
      end
    end)
  end,
  jv_del = function(picker, item)
    local state = state_of(picker)
    if not (state and item and item.jv_path) or item.jv_path == state.root then return end
    local base = item.jv_path:match("^(.*)/[^/]+$") or state.root
    if vim.fn.confirm("Delete " .. item.jv_path .. "?", "&Yes\n&No", 2) ~= 1 then return end
    client(state.alias):call("fs_rm", { path = item.jv_path, recursive = true }, function(err)
      if err then return vim.notify("jupynvim: delete failed: " .. tostring(err), vim.log.levels.ERROR) end
      state.expanded[item.jv_path] = nil
      reload_dir(state, picker, base)
    end)
  end,
  jv_rename = function(picker, item)
    local state = state_of(picker)
    if not (state and item and item.jv_path) or item.jv_path == state.root then return end
    local base = item.jv_path:match("^(.*)/[^/]+$") or state.root
    local old_name = item.jv_path:match("[^/]+$")
    vim.ui.input({ prompt = "Rename: ", default = old_name }, function(name)
      if not name or name == "" or name == old_name then return end
      client(state.alias):call("fs_rename", { src = item.jv_path, dst = join(base, name) }, function(err)
        if err then return vim.notify("jupynvim: rename failed: " .. tostring(err), vim.log.levels.ERROR) end
        reload_dir(state, picker, base)
      end)
    end)
  end,
  jv_grep = function(picker)
    local state = state_of(picker)
    if not state then return end
    require("jupynvim.remote_pick").grep(state.alias, state.root)
  end,
  jv_terminal = function(picker)
    local state = state_of(picker)
    if not state then return end
    require("jupynvim.remote_term").toggle(state.alias)
  end,
}

-- ── public API (same shape remote_explorer delegates to) ───────────────────

function M.open(alias, root)
  local state = states[alias]
  if not state then
    state = { alias = alias, expanded = {}, kids = {} }
    states[alias] = state
  end
  if root and root ~= state.root then
    state.root = root
    state.kids = {}
    state.files_cache = nil
    state.expanded = {}
  end
  state.root = state.root or root or "~"

  if state.picker and not state.picker.closed then
    state.picker:focus()
    return
  end

  -- Close any LOCAL snacks explorer so there's one explorer sidebar.
  pcall(function()
    for _, p in ipairs(Snacks.picker.get({ source = "explorer" })) do p:close() end
  end)

  local searching = false
  state.picker = Snacks.picker.pick({
    jupynvim_alias = alias,
    finder = finder,
    format = "file",
    tree = true,
    sort = { fields = { "sort" } },
    matcher = { sort_empty = false, fuzzy = false },
    filter = {
      -- Re-run the finder when the pattern toggles empty <-> non-empty
      -- (browse tree vs full-list filter mode), like snacks explorer.
      transform = function(_picker, filter)
        local s = not filter:is_empty()
        if searching ~= s then
          searching = s
          filter.meta.searching = s
          return true
        end
      end,
    },
    title = "Explorer " .. alias,
    layout = { preset = "sidebar", preview = false },
    show_empty = true,  -- async finder: zero items while a fetch is in flight
    auto_close = false,
    jump = { close = false },
    focus = "list",
    hidden = false,
    ignored = false,
    formatters = { file = { filename_only = true } },
    actions = ACTIONS,
    win = {
      list = {
        keys = {
          ["l"] = "confirm",
          ["h"] = "jv_close_dir",
          ["a"] = "jv_add",
          ["d"] = "jv_del",
          ["r"] = "jv_rename",
          ["R"] = "jv_refresh",
          ["H"] = "jv_toggle_hidden",
          ["I"] = "jv_toggle_ignored",
          ["-"] = "jv_up",
          ["<BS>"] = "jv_up",
          ["."] = "jv_set_root",
          ["/"] = "toggle_focus",
          ["g/"] = "jv_grep",
          ["<c-t>"] = "jv_terminal",
          ["q"] = "close",
        },
      },
    },
    on_close = function()
      local st = states[alias]
      if st then st.picker = nil end
      refresh_notebooks()  -- notebook reclaimed the sidebar width
    end,
  })
  refresh_notebooks()  -- notebook narrowed for the new sidebar

  -- Swap any startup dashboard in the main pane for the jupynvim one.
  -- NOTE: do NOT close "empty" windows here. The picker treats one regular
  -- window as its MAIN window (often an empty [No Name] pane); closing it
  -- makes snacks close the whole picker silently. The stray auth-split
  -- window is fixed at its source in connect's on-exit instead.
  vim.schedule(function()
    pcall(function() require("jupynvim.remote_dashboard").place(alias, state.root) end)
  end)
end

function M.visible_win(alias)
  local state = states[alias]
  local p = state and state.picker
  if p and not p.closed then
    local ok, win = pcall(function() return p.list.win.win end)
    if ok and win and vim.api.nvim_win_is_valid(win) then return win end
  end
  return nil
end

function M.close(alias)
  local state = states[alias]
  if state and state.picker and not state.picker.closed then
    state.picker:close()
  end
end

function M.set_root(alias, path)
  local state = states[alias]
  if not state or not (state.picker and not state.picker.closed) then
    return M.open(alias, path)
  end
  state.root = path
  state.kids = {}
  state.files_cache = nil
  state.expanded = {}
  state.picker:find()
end

function M.current_root(alias)
  local state = states[alias]
  return state and state.root or nil
end

function M.reset(alias)
  M.close(alias)
  states[alias] = nil
end

return M

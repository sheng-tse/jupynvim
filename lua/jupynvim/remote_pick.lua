-- Remote file/grep pickers backed by the backend (find_files / search RPCs),
-- so <leader>ff / <leader>/ etc. operate on the REMOTE when SSH-connected.
--
-- Fully async: the RPC runs in the background and the picker opens when
-- results arrive, so the UI never freezes (the walk of a big remote tree over
-- NFS can take seconds). Prefers snacks.picker (the LazyVim default) with a
-- clean relative-path display + icons and an async remote preview; falls back
-- to vim.ui.select (files) / quickfix (grep) for non-snacks setups. Picked
-- items open as jupynvim://<alias>/<path> URIs, routed to the remote backend.

local M = {}

-- Pruned from remote scans (dir/file names). These are bulk junk that would
-- otherwise dominate a $HOME scan (conda installs are hundreds of thousands
-- of files). Extend/override per profile: remote.<alias>.find_excludes.
M.DEFAULT_EXCLUDES = {
  ".git", "__pycache__", "node_modules", ".ipynb_checkpoints",
  ".mypy_cache", ".ruff_cache", ".pytest_cache", ".tox",
  "miniconda3", "anaconda3", "miniforge3", "mambaforge", "micromamba",
}

local function uri(alias, abspath)
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

local function excludes_for(alias)
  local profile = (require("jupynvim").config.remote or {})[alias] or {}
  local ex = vim.deepcopy(M.DEFAULT_EXCLUDES)
  for _, e in ipairs(profile.find_excludes or {}) do table.insert(ex, e) end
  return ex
end

-- ── async remote preview ───────────────────────────────────────────────────
-- Reads the file via fs_read in the background and fills the preview pane
-- when it arrives. Avoids bufload(): that would fire the full BufReadCmd
-- (blocking fs_read + LSP attach) for EVERY item the cursor touches.
local preview_cache = {}   -- uri -> lines
local preview_order = {}   -- FIFO for eviction
local preview_token = 0
local PREVIEW_MAX_LINES = 2000

local function cache_put(key, lines)
  if preview_cache[key] == nil then
    table.insert(preview_order, key)
    if #preview_order > 40 then
      preview_cache[table.remove(preview_order, 1)] = nil
    end
  end
  preview_cache[key] = lines
end

local function apply_preview(ctx, path, lines)
  pcall(function()
    ctx.preview:set_lines(lines)
    ctx.preview:highlight({ file = path })
    ctx.preview:set_title(vim.fn.fnamemodify(path, ":t"))
  end)
end

function M.preview(ctx)
  local item = ctx.item
  if not (item and item.file) then
    pcall(function() ctx.preview:notify("no file", "warn") end)
    return
  end
  local alias, path = item.file:match("^jupynvim://([^/]+)(/.*)$")
  if not alias then
    pcall(function() ctx.preview:notify("not a remote file", "warn") end)
    return
  end
  pcall(function() ctx.preview:reset() end)
  local cached = preview_cache[item.file]
  if cached then
    apply_preview(ctx, path, cached)
    return
  end
  pcall(function() ctx.preview:set_lines({ "  loading " .. vim.fn.fnamemodify(path, ":t") .. " ..." }) end)
  preview_token = preview_token + 1
  local tok = preview_token
  local ok, client = pcall(function() return require("jupynvim").client_for(alias) end)
  if not ok then return end
  client:call("fs_read", { path = path }, function(err, res)
    if tok ~= preview_token then return end  -- superseded by a newer selection
    if err or not res then
      pcall(function() ctx.preview:notify(tostring(err), "warn") end)
      return
    end
    local content = vim.base64.decode(res.content_b64 or "")
    local lines = vim.split(content, "\n", { plain = true })
    if #lines > PREVIEW_MAX_LINES then
      local head = {}
      for i = 1, PREVIEW_MAX_LINES do head[i] = lines[i] end
      head[#head + 1] = ("... (%d more lines)"):format(#lines - PREVIEW_MAX_LINES)
      lines = head
    end
    cache_put(item.file, lines)
    apply_preview(ctx, path, lines)
  end)
end

-- ── formatting: icon + relative path (not the raw jupynvim:// URI) ─────────
local function format_item(item, _picker)
  local ret = {}
  local label = item.rel or item.text
  local icon, hl = " ", "SnacksPickerFile"
  pcall(function()
    local i, h = Snacks.util.icon(vim.fn.fnamemodify(label, ":t"), "file")
    if i then icon, hl = i, h end
  end)
  ret[#ret + 1] = { icon .. " ", hl, virtual = true }
  ret[#ret + 1] = { label, "SnacksPickerFile" }
  if item.line_text then
    ret[#ret + 1] = { ":" .. item.lnum .. ": ", "SnacksPickerComment" }
    ret[#ret + 1] = { item.line_text, "SnacksPickerComment" }
  end
  return ret
end

-- ── find files ──────────────────────────────────────────────────────────
-- opts.layout: snacks layout override (the explorer `/` passes the sidebar
-- preset so it looks like the snacks explorer search box).
function M.files(alias, root, opts)
  opts = opts or {}
  root = resolve_root(alias, root)
  local ok, client = pcall(function() return require("jupynvim").client_for(alias) end)
  if not ok then
    vim.notify("jupynvim: " .. tostring(client), vim.log.levels.ERROR)
    return
  end
  vim.notify("jupynvim: scanning " .. alias .. ":" .. root .. " ...", vim.log.levels.INFO)
  client:call("find_files", { path = root, max = 20000, excludes = excludes_for(alias) }, function(err, res)
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
    local title = " " .. alias .. ":" .. vim.fn.fnamemodify(base, ":t")
      .. (res.truncated and " (truncated) " or " ")

    if has_snacks() then
      local items = {}
      for i, rel in ipairs(files) do
        items[i] = { text = rel, rel = rel, file = uri(alias, base .. "/" .. rel) }
      end
      Snacks.picker.pick(vim.tbl_extend("force", {
        items = items,
        format = format_item,
        preview = M.preview,
        title = title,
      }, opts.layout and { layout = opts.layout } or {}))
      return
    end
    vim.ui.select(files, { prompt = title }, function(choice)
      if choice then vim.cmd("edit " .. vim.fn.fnameescape(uri(alias, base .. "/" .. choice))) end
    end)
  end)
end

-- ── grep ───────────────────────────────────────────────────────────────
function M.grep(alias, root, pattern, opts)
  opts = opts or {}
  root = resolve_root(alias, root)
  local function run(pat)
    if not pat or pat == "" then return end
    local ok, client = pcall(function() return require("jupynvim").client_for(alias) end)
    if not ok then
      vim.notify("jupynvim: " .. tostring(client), vim.log.levels.ERROR)
      return
    end
    vim.notify("jupynvim: grepping " .. alias .. ":" .. root .. " ...", vim.log.levels.INFO)
    client:call("search", { path = root, pattern = pat, max = 2000 }, function(err, res)
      if err or not res then
        vim.notify("jupynvim: search failed: " .. tostring(err), vim.log.levels.ERROR)
        return
      end
      local matches = res.matches or {}
      if #matches == 0 then
        vim.notify("jupynvim: no matches for " .. pat, vim.log.levels.INFO)
        return
      end
      local title = " grep '" .. pat .. "' (" .. alias .. ")" .. (res.truncated and " (truncated) " or " ")
      if has_snacks() then
        local items = {}
        local prefix = root:gsub("/+$", "") .. "/"
        for i, m in ipairs(matches) do
          local rel = m.path
          if rel:sub(1, #prefix) == prefix then rel = rel:sub(#prefix + 1) end
          items[i] = {
            text = rel .. ":" .. m.line .. ": " .. (m.text or ""),
            rel = rel,
            lnum = m.line,
            line_text = (m.text or ""):gsub("^%s+", ""),
            file = uri(alias, m.path),
            pos = { tonumber(m.line) or 1, (tonumber(m.col) or 1) - 1 },
          }
        end
        Snacks.picker.pick(vim.tbl_extend("force", {
          items = items,
          format = format_item,
          preview = M.preview,
          title = title,
        }, opts.layout and { layout = opts.layout } or {}))
        return
      end
      local qf = {}
      for _, m in ipairs(matches) do
        qf[#qf + 1] = { filename = uri(alias, m.path), lnum = m.line, col = m.col, text = m.text }
      end
      vim.fn.setqflist({}, " ", { title = title, items = qf })
      vim.cmd("copen")
    end)
  end

  if pattern then run(pattern)
  else vim.ui.input({ prompt = "Grep " .. alias .. ": " }, run) end
end

return M

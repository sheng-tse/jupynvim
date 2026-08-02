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

-- The main editor window: a normal (non-floating) window that is NOT a
-- jupynvim terminal or the explorer/picker. The dashboard or a real-file
-- window qualifies. Largest preferred.
function M.editor_win()
  local best, best_area
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative == "" then
      local b = vim.api.nvim_win_get_buf(w)
      local ft = vim.bo[b].filetype or ""
      if not vim.b[b].jupynvim_term_alias and not vim.b[b].jupynvim_explorer
         and not ft:match("^snacks") then
        local a = vim.api.nvim_win_get_width(w) * vim.api.nvim_win_get_height(w)
        if not best_area or a > best_area then best, best_area = w, a end
      end
    end
  end
  return best
end

-- After opening a file, an empty unnamed scratch buffer can linger in the
-- bufferline (the [No Name] LazyVim/snacks leaves behind when `leader-bd`
-- closes the last file). Wipe such buffers once nothing displays them, so they
-- don't show as a redundant tab. Never touches named, modified, special, or
-- VISIBLE buffers (the snacks picker's main [No Name] is visible, so it's safe).
local function wipe_stray_noname()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b)
       and vim.bo[b].buflisted
       and vim.bo[b].buftype == ""
       and not vim.bo[b].modified
       and vim.api.nvim_buf_get_name(b) == ""
       and #vim.fn.win_findbuf(b) == 0
       and vim.api.nvim_buf_line_count(b) <= 1
       and (vim.api.nvim_buf_get_lines(b, 0, 1, false)[1] or "") == "" then
      pcall(vim.api.nvim_buf_delete, b, { force = false })
    end
  end
end

-- Open `file` (a jupynvim:// URI) in the editor window, never replacing a
-- terminal/explorer buffer. `pos` = {line, col0} to jump to (grep results).
function M.open_in_editor(file, pos)
  local w = M.editor_win()
  local relocated_slot, term_alias
  if w and vim.api.nvim_win_is_valid(w) then
    vim.api.nvim_set_current_win(w)
  else
    -- No editor window: the main area is a terminal (e.g. right after closing
    -- the dashboard with `q`, leaving [explorer | terminal]). Put the file ON
    -- TOP of that terminal and push the terminal below it (its C-/ home),
    -- instead of `topleft vsplit`, which dumped the file at the far left and
    -- shoved the explorer sidebar into the middle.
    local termwin
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local b = vim.api.nvim_win_get_buf(win)
      if vim.api.nvim_win_get_config(win).relative == "" and vim.b[b].jupynvim_term_alias then
        termwin = win
        term_alias = vim.b[b].jupynvim_term_alias
        relocated_slot = vim.b[b].jupynvim_term_slot or "below"
        break
      end
    end
    if termwin then
      vim.api.nvim_set_current_win(termwin)
      -- Split direction depends on the terminal's slot: a "below" terminal
      -- fills the main area, so the file goes ON TOP (horizontal). A "right"
      -- (or "left") column terminal stays a column, so the file goes BESIDE it
      -- in the main area (vertical), never cramped on top of the narrow column.
      if relocated_slot == "below" then
        vim.cmd("aboveleft split")
      elseif relocated_slot == "left" then
        vim.cmd("belowright vsplit")  -- file to the right of a left column
      else                            -- "right" and default: file to the left
        vim.cmd("aboveleft vsplit")
      end
    else
      -- No terminal either: only the explorer remains (it goes full-width after
      -- a `q`). Put the file to the RIGHT of it (the main area); the sidebar
      -- re-pin below shrinks the explorer back to its left column. `topleft`
      -- dropped the file on the far LEFT and left the explorer stuck on the right.
      pcall(vim.cmd, "botright vsplit")
    end
  end
  local target = vim.api.nvim_get_current_win()
  local nb_alias, nb_path = file:match("^jupynvim://([^/]+)(/.*)$")
  if nb_alias and nb_path and nb_path:sub(-6) == ".ipynb" then
    -- Notebooks go through the notebook opener (renders, names + lists the
    -- buffer, manages its own window). A plain :edit of the URI builds a SECOND
    -- [No Name] buffer (the URI handler calls M.open for the real notebook),
    -- and the force-into-target logic below would clobber the rendered notebook
    -- with that empty buffer / drop the terminal.
    local J = require("jupynvim")
    J.use_remote(nb_alias)
    J.open(nb_path, { alias = nb_alias })
  else
    vim.cmd("edit " .. vim.fn.fnameescape(file))
    -- A plugin (LazyVim/neo-tree) can auto-split the :edit into a stray window;
    -- force the file into the intended target and close any OTHER window showing
    -- it. (Only ever closes windows displaying this file buffer, never the
    -- picker/explorer, which show their own buffers.)
    local b = vim.fn.bufnr(file)
    if b ~= -1 and vim.api.nvim_win_is_valid(target) then
      pcall(vim.api.nvim_win_set_buf, target, b)
      for _, win in ipairs(vim.fn.win_findbuf(b)) do
        if win ~= target then pcall(vim.api.nvim_win_close, win, true) end
      end
      pcall(vim.api.nvim_set_current_win, target)
    end
    if pos then pcall(vim.api.nvim_win_set_cursor, 0, { pos[1], pos[2] or 0 }) end
  end
  -- Shrink the relocated terminal back to its compact slot size, AFTER the file
  -- loads (resizing before the load gets undone). Scheduled backstop covers
  -- async (notebook image) renders that resize on a later tick.
  if relocated_slot and term_alias then
    local rt = require("jupynvim.remote_term")
    pcall(rt.restore_size, term_alias, relocated_slot)
    vim.schedule(function() pcall(rt.restore_size, term_alias, relocated_slot) end)
  end
  -- Re-pin the snacks sidebar: the relocation vsplit + the file load can squish
  -- it off its sidebar width. No-op when the snacks picker isn't the explorer.
  pcall(function()
    local rep = require("jupynvim.remote_explorer_picker")
    rep.repin_sidebar()
    vim.schedule(rep.repin_sidebar)
  end)
  -- Drop the redundant empty [No Name] tab that lingered from a prior leader-bd.
  vim.schedule(wipe_stray_noname)
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
        confirm = function(picker, item)
          picker:close()
          if item and item.file then M.open_in_editor(item.file) end
        end,
      }, opts.layout and { layout = opts.layout } or {}))
      return
    end
    vim.ui.select(files, { prompt = title }, function(choice)
      if choice then M.open_in_editor(uri(alias, base .. "/" .. choice)) end
    end)
  end)
end

-- ── grep ───────────────────────────────────────────────────────────────
function M.grep(alias, root, pattern, opts)
  opts = opts or {}
  root = resolve_root(alias, root)
  local ok, client = pcall(function() return require("jupynvim").client_for(alias) end)
  if not ok then
    vim.notify("jupynvim: " .. tostring(client), vim.log.levels.ERROR)
    return
  end

  local prefix = root:gsub("/+$", "") .. "/"
  local function build_items(matches)
    local items = {}
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
    return items
  end

  local function build_one(m)
    local rel = m.path
    if rel:sub(1, #prefix) == prefix then rel = rel:sub(#prefix + 1) end
    return {
      text = rel .. ":" .. m.line .. ": " .. (m.text or ""),
      rel = rel,
      lnum = m.line,
      line_text = (m.text or ""):gsub("^%s+", ""),
      file = uri(alias, m.path),
      pos = { tonumber(m.line) or 1, (tonumber(m.col) or 1) - 1 },
    }
  end

  if has_snacks() and not pattern then
    -- LIVE grep with STREAMING results (parity with local <leader>/): each
    -- keystroke starts a search_stream on the remote; matches arrive as
    -- search_event batches and are fed to the picker as they land, so hits in
    -- nearby dirs show within milliseconds even when the full walk of a big
    -- NFS tree takes much longer (snacks' busy spinner shows meanwhile). A
    -- new keystroke supersedes the previous search (backend epoch + sid).
    local seq = math.floor(vim.uv.hrtime() % 1e9)
    local current = { sid = nil, push = nil }
    if not client._search_event_hooked then
      client._search_event_hooked = true
      client:on("search_event", function(args)
        local e = args[1] or args
        if current.push and e.sid == current.sid then current.push(e) end
      end)
    end
    local function live_finder(_opts, ctx)
      local pat = ctx.filter.search or ""
      if #pat < 2 then return {} end  -- 1-char patterns: too broad to walk for
      return function(cb)
        local Async = require("snacks.picker.util.async")
        local task = Async.running()
        -- Debounce INSIDE the async task: if another key arrives during this
        -- sleep, snacks aborts this task and no remote search ever fires for
        -- the intermediate pattern. Without this, every keystroke launched a
        -- full remote walk and the pile-up saturated NFS ("first search fast,
        -- then nothing returns").
        Async.sleep(250)
        seq = seq + 1
        local sid = seq
        local queue, done = {}, false
        current.sid = sid
        current.push = function(e)
          for _, m in ipairs(e.matches or {}) do queue[#queue + 1] = m end
          if e.done then done = true end
          if task then pcall(function() task:resume() end) end
        end
        client:call("search_stream", {
          path = root, pattern = pat, max = 1000,
          excludes = excludes_for(alias), sid = sid,
        }, function(err)
          if err then
            done = true
            vim.notify("jupynvim: search failed: " .. tostring(err), vim.log.levels.ERROR)
            if task then pcall(function() task:resume() end) end
          end
        end)
        while true do
          while #queue > 0 do
            cb(build_one(table.remove(queue, 1)))
          end
          if done then break end
          task:suspend()
        end
        if current.sid == sid then current.push = nil end
      end
    end
    Snacks.picker.pick(vim.tbl_extend("force", {
      finder = live_finder,
      live = true,
      supports_live = true,
      show_empty = true,
      format = format_item,
      preview = M.preview,
      title = " grep " .. alias .. ":" .. vim.fn.fnamemodify(root, ":t") .. " ",
      confirm = function(picker, item)
        picker:close()
        if item and item.file then M.open_in_editor(item.file, item.pos) end
      end,
    }, opts.layout and { layout = opts.layout } or {}))
    return
  end

  -- one-shot path (explicit pattern, or no snacks -> quickfix)
  local function run(pat)
    if not pat or pat == "" then return end
    client:call("search", { path = root, pattern = pat, max = 2000, excludes = excludes_for(alias) },
      function(err, res)
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
          Snacks.picker.pick({
            items = build_items(matches),
            format = format_item,
            preview = M.preview,
            title = title,
            confirm = function(picker, item)
              picker:close()
              if item and item.file then M.open_in_editor(item.file, item.pos) end
            end,
          })
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

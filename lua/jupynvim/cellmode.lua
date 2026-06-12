-- VSCode-style cell interaction model.
--
-- A notebook buffer is always in one of two modes:
--
--   COMMAND (default)  j/k select whole cells (thick gutter bar, like
--                      VSCode's blue selection bar; the text cursor is
--                      hidden). The buffer is non-modifiable so stray keys
--                      can't edit text. Enter (or i) dives into the
--                      selected cell, restoring the cursor where you last
--                      left it in that cell. a/b add cells, dd deletes,
--                      yy/p copy/paste cells, gg/G first/last.
--
--   EDIT               normal vim INSIDE the cell: motions are confined to
--                      the cell (G/gg go to the cell's last/first line and
--                      anything that strays is clamped back). Esc returns
--                      to COMMAND.
--
-- The statuscolumn IS the left side of each cell's frame: per-cell line
-- numbers (absolute in command mode, relative-to-cursor inside the edited
-- cell), the selection bar, and the box's left border. Virtual rows
-- (headers, outputs, execution bars) and markdown cells get a blank
-- gutter, exactly like VSCode. Keeping the border out of the text area
-- also means the insert cursor aligns correctly on empty lines.

local M = {}

local Notebook = require("jupynvim.notebook")

local ns = vim.api.nvim_create_namespace("jupynvim.cellmode")

-- Gutter geometry: [bar 1][num 3][sp 1][border 1][sp 1] = 7 cells.
M.GUTTER = 7

-- buf -> { mode = "command"|"edit", edit_idx = n, pos = {idx -> {l, c}} }
local state = {}

-- ── cell ranges (cached by changedtick) ────────────────────────────────────
local _range_cache = {}  -- buf -> { tick, ranges }

-- Ranges are 0-based [start, stop) over buffer lines; sep lines excluded.
function M.ranges(buf)
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local c = _range_cache[buf]
  if c and c.tick == tick then return c.ranges end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local ranges = {}
  local cur = 0
  for i, line in ipairs(lines) do
    if line == Notebook.CELL_SEP then
      table.insert(ranges, { start = cur, stop = i - 1 })
      cur = i
    end
  end
  table.insert(ranges, { start = cur, stop = #lines })
  _range_cache[buf] = { tick = tick, ranges = ranges }
  return ranges
end

-- Cell index (1-based) containing 1-based line `lnum`; sep lines belong to
-- the cell ABOVE them (feels right when scanning down).
function M.cell_idx_at(buf, lnum)
  local ranges = M.ranges(buf)
  for i, r in ipairs(ranges) do
    if lnum - 1 < r.stop or i == #ranges then return i, r end
    local next_start = ranges[i + 1] and ranges[i + 1].start or r.stop
    if lnum - 1 < next_start then return i, r end  -- on the separator below cell i
  end
  return #ranges, ranges[#ranges]
end

function M.mode(buf) return (state[buf] or {}).mode or "edit" end
function M.is_command(buf) return M.mode(buf) == "command" end

function M.selected_idx(buf)
  local win = vim.fn.bufwinid(buf)
  if win == -1 then return 1 end
  local lnum = vim.api.nvim_win_get_cursor(win)[1]
  local idx = M.cell_idx_at(buf, lnum)
  return idx
end

-- ── statuscolumn ───────────────────────────────────────────────────────────
-- Per-cell gutter. Every branch renders exactly M.GUTTER display cells so
-- the text area never shifts between lines. The cell's left border IS the
-- selection indicator: heavy + colored on the current cell (blue in
-- command mode, green while editing), like VSCode's bar; no second bar.
function M.statuscol()
  return M._statuscol_for(vim.api.nvim_get_current_buf(), vim.v.lnum, vim.v.virtnum, vim.v.relnum)
end

-- Pure form (testable): gutter content for (buf, lnum, virtnum, relnum).
function M._statuscol_for(buf, lnum, virtnum, _relnum)
  local nb = Notebook.get(buf)
  if not nb then return "" end
  if virtnum < 0 then
    return ""  -- virtual rows (header/outputs/exec bar): blank gutter
  end
  local ranges = M.ranges(buf)
  local line0 = lnum - 1
  local r, idx
  for i, range in ipairs(ranges) do
    if line0 >= range.start and line0 < range.stop then
      r, idx = range, i
      break
    end
  end
  if not r then return string.rep(" ", M.GUTTER) end  -- separator line
  local sel = M.selected_idx(buf)
  local cell = nb.cells[idx]
  local editing = (not M.is_command(buf)) and idx == sel
  local boxed = (cell and cell.cell_type == "code") or editing
  local hl = "JupynvimBorder"
  local ch = "│"
  if idx == sel then
    ch = "┃"
    hl = "JupynvimBorderSel"
  end
  if not boxed then
    -- rendered markdown: selection bar at the FAR LEFT (VSCode), no
    -- numbers, no box edge
    if idx == sel then
      return "%#JupynvimBorderSel#▌%*" .. string.rep(" ", M.GUTTER - 1)
    end
    return string.rep(" ", M.GUTTER)
  end
  local edge = "%#" .. hl .. "#" .. ch .. "%* "
  if virtnum > 0 then
    return "     " .. edge  -- wrap continuation rows carry no number
  end
  -- per-cell ABSOLUTE numbering, both modes
  return " %#LineNr#" .. string.format("%3d", line0 - r.start + 1) .. "%* " .. edge
end

-- ── selection / cursor visibility ──────────────────────────────────────────
local _saved_guicursor = nil

local function hide_cursor()
  if _saved_guicursor == nil then
    _saved_guicursor = vim.go.guicursor
  end
  vim.go.guicursor = "a:JupynvimHiddenCursor"
end

local function show_cursor()
  if _saved_guicursor ~= nil then
    vim.go.guicursor = _saved_guicursor
    _saved_guicursor = nil
  end
end

local function refresh_render(buf)
  local nb = Notebook.get(buf)
  if nb then
    require("jupynvim.render").refresh(nb, vim.fn.bufwinid(buf))
  end
end

-- ── mode switching ─────────────────────────────────────────────────────────
local function with_modifiable(buf, fn)
  local was = vim.bo[buf].modifiable
  vim.bo[buf].modifiable = true
  local ok, err = pcall(fn)
  vim.bo[buf].modifiable = was
  if not ok then error(err) end
end
M.with_modifiable = with_modifiable

function M.enter_command(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  state[buf] = state[buf] or { pos = {} }
  local win = vim.fn.bufwinid(buf)
  if state[buf].mode ~= "command" then
    -- remember where the cursor was inside the cell we're leaving
    if win ~= -1 and state[buf].edit_idx then
      state[buf].pos[state[buf].edit_idx] = vim.api.nvim_win_get_cursor(win)
    end
  end
  state[buf].mode = "command"
  state[buf].edit_idx = nil
  vim.bo[buf].modifiable = false
  if win ~= -1 and vim.api.nvim_get_current_buf() == buf then
    hide_cursor()
  end
  refresh_render(buf)
  vim.cmd("redraw")
end

function M.enter_edit(buf, keys)
  buf = buf or vim.api.nvim_get_current_buf()
  state[buf] = state[buf] or { pos = {} }
  state[buf].mode = "edit"
  vim.bo[buf].modifiable = true
  show_cursor()
  local win = vim.fn.bufwinid(buf)
  local idx = M.selected_idx(buf)
  state[buf].edit_idx = idx
  -- restore the cursor to where it last was in THIS cell
  local saved = state[buf].pos[idx]
  local r = M.ranges(buf)[idx]
  if win ~= -1 and r then
    if saved and saved[1] - 1 >= r.start and saved[1] - 1 < r.stop then
      pcall(vim.api.nvim_win_set_cursor, win, saved)
    end
  end
  refresh_render(buf)
  -- editing the FIRST cell: its new top border is a virt line above buffer
  -- line 1; pull it into view
  if idx == 1 and win ~= -1 then
    vim.schedule(function()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_call(win, function()
          local v = vim.fn.winsaveview()
          if v.topline == 1 then
            pcall(vim.fn.winrestview, { topline = 1, topfill = 5, lnum = v.lnum, col = v.col })
          end
        end)
      end
    end)
  end
  if keys then
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "n", false)
  end
  vim.cmd("redraw")
end

-- ── command-mode actions ───────────────────────────────────────────────────
local function select_cell(buf, idx)
  local ranges = M.ranges(buf)
  idx = math.max(1, math.min(idx, #ranges))
  local r = ranges[idx]
  local win = vim.fn.bufwinid(buf)
  if win ~= -1 and r then
    pcall(vim.api.nvim_win_set_cursor, win, { r.start + 1, 0 })
  end
end

function M.move_selection(buf, delta)
  select_cell(buf, M.selected_idx(buf) + delta)
end

function M.select_first(buf) select_cell(buf, 1) end
function M.select_last(buf) select_cell(buf, #M.ranges(buf)) end

-- whole-cell clipboard (source lines + type), VSCode yy/p semantics
local _clip = nil

function M.yank_cell(buf)
  local nb = Notebook.get(buf)
  if not nb then return end
  local idx = M.selected_idx(buf)
  local r = M.ranges(buf)[idx]
  if not r then return end
  local lines = vim.api.nvim_buf_get_lines(buf, r.start, r.stop, false)
  local cell = nb.cells[idx]
  _clip = { lines = lines, cell_type = cell and cell.cell_type or "code" }
  vim.fn.setreg('"', table.concat(lines, "\n"))
  vim.notify("jupynvim: cell " .. idx .. " yanked", vim.log.levels.INFO)
end

function M.paste_cell(buf, api)
  if not _clip then
    vim.notify("jupynvim: no yanked cell", vim.log.levels.INFO)
    return
  end
  local clip = _clip
  with_modifiable(buf, function()
    api.add_cell(buf, "below")
  end)
  vim.schedule(function()
    with_modifiable(buf, function()
      local idx = M.selected_idx(buf)
      local r = M.ranges(buf)[idx]
      if r then
        vim.api.nvim_buf_set_lines(buf, r.start, r.stop, false, clip.lines)
      end
      if clip.cell_type == "markdown" then
        api.set_cell_type(buf, "markdown")
      end
    end)
  end)
end

-- ── edit-mode confinement ──────────────────────────────────────────────────
-- VSCode can't move focus out of a cell editor with plain motions: clamp
-- the cursor back into the edited cell whenever it strays (covers G, gg,
-- }, searches, everything).
local function clamp_to_cell(buf)
  local st = state[buf]
  if not st or st.mode ~= "edit" or not st.edit_idx then return end
  local win = vim.fn.bufwinid(buf)
  if win == -1 or vim.api.nvim_get_current_buf() ~= buf then return end
  local r = M.ranges(buf)[st.edit_idx]
  if not r then return end
  local cur = vim.api.nvim_win_get_cursor(win)
  local lnum = cur[1]
  if lnum - 1 < r.start then
    pcall(vim.api.nvim_win_set_cursor, win, { r.start + 1, cur[2] })
  elseif lnum - 1 >= r.stop then
    pcall(vim.api.nvim_win_set_cursor, win, { math.max(r.stop, r.start + 1), cur[2] })
  end
end

-- ── attach ─────────────────────────────────────────────────────────────────
function M.attach(buf, api)
  state[buf] = { mode = "edit", pos = {} }

  local function map(mode, lhs, fn, desc)
    vim.keymap.set(mode, lhs, fn, { buffer = buf, silent = true, nowait = true, desc = desc })
  end

  -- command-mode key, falling through to a custom edit-mode behavior
  local function cmdmap(lhs, fn, desc, edit_fn)
    map("n", lhs, function()
      if M.is_command(buf) then
        fn()
      elseif edit_fn then
        edit_fn()
      else
        vim.api.nvim_feedkeys(
          vim.api.nvim_replace_termcodes(lhs, true, false, true), "n", false)
      end
    end, desc)
  end

  local function edit_cell_range()
    local st = state[buf]
    local idx = (st and st.edit_idx) or M.selected_idx(buf)
    return M.ranges(buf)[idx]
  end

  -- j/k in edit mode stop at the cell's edges (VSCode editors don't bleed
  -- into the next cell)
  local function edit_down()
    local r = edit_cell_range()
    local l = vim.api.nvim_win_get_cursor(0)[1]
    if r and l < r.stop then
      vim.api.nvim_feedkeys("j", "n", false)
    end
  end
  local function edit_up()
    local r = edit_cell_range()
    local l = vim.api.nvim_win_get_cursor(0)[1]
    if r and l - 1 > r.start then
      vim.api.nvim_feedkeys("k", "n", false)
    end
  end
  cmdmap("j", function() M.move_selection(buf, 1) end, "jupynvim: next cell", edit_down)
  cmdmap("k", function() M.move_selection(buf, -1) end, "jupynvim: prev cell", edit_up)
  cmdmap("<Down>", function() M.move_selection(buf, 1) end, "jupynvim: next cell", edit_down)
  cmdmap("<Up>", function() M.move_selection(buf, -1) end, "jupynvim: prev cell", edit_up)
  -- gg/G: first/last cell in command mode, first/last line OF THE CELL in
  -- edit mode (motions never leave the cell editor)
  cmdmap("gg", function() M.select_first(buf) end, "jupynvim: first cell", function()
    local r = edit_cell_range()
    if r then pcall(vim.api.nvim_win_set_cursor, 0, { r.start + 1, 0 }) end
  end)
  cmdmap("G", function() M.select_last(buf) end, "jupynvim: last cell", function()
    local r = edit_cell_range()
    if r then pcall(vim.api.nvim_win_set_cursor, 0, { math.max(r.stop, r.start + 1), 0 }) end
  end)
  cmdmap("dd", function()
    with_modifiable(buf, function() api.delete_cell(buf) end)
  end, "jupynvim: delete cell")
  cmdmap("yy", function() M.yank_cell(buf) end, "jupynvim: yank cell")
  cmdmap("p", function() M.paste_cell(buf, api) end, "jupynvim: paste cell below")
  cmdmap("a", function()
    with_modifiable(buf, function() api.add_cell(buf, "above") end)
  end, "jupynvim: add cell above")
  cmdmap("b", function()
    with_modifiable(buf, function() api.add_cell(buf, "below") end)
  end, "jupynvim: add cell below")

  -- Enter edit mode. Enter = plain focus; i/o/O carry their editing intent.
  map("n", "<CR>", function()
    if M.is_command(buf) then
      M.enter_edit(buf)
    else
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "n", false)
    end
  end, "jupynvim: edit cell")
  cmdmap("i", function() M.enter_edit(buf) end, "jupynvim: edit cell")
  cmdmap("I", function() M.enter_edit(buf, "I") end, "jupynvim: edit cell")
  cmdmap("A", function() M.enter_edit(buf, "A") end, "jupynvim: edit cell")
  cmdmap("o", function() M.enter_edit(buf, "o") end, "jupynvim: edit cell")
  cmdmap("O", function() M.enter_edit(buf, "O") end, "jupynvim: edit cell")

  -- Esc: edit -> command (VSCode). In command mode it clears search
  -- highlight so the global Esc habit still works.
  map("n", "<Esc>", function()
    if M.is_command(buf) then
      vim.cmd("nohlsearch")
    else
      M.enter_command(buf)
    end
  end, "jupynvim: cell command mode")

  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    buffer = buf,
    callback = function()
      if M.is_command(buf) then
        -- the box borders are extmarks: re-render when the selection moves
        -- so the highlighted frame follows it (not just the gutter)
        local s = M.selected_idx(buf)
        if state[buf] and state[buf].last_sel ~= s then
          state[buf].last_sel = s
          refresh_render(buf)
        end
        vim.cmd("redrawstatus")
      else
        clamp_to_cell(buf)
      end
    end,
  })
  -- cursor visibility follows window focus: hidden only while the notebook
  -- window is current AND in command mode
  vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
    buffer = buf,
    callback = function()
      if M.is_command(buf) then hide_cursor() end
    end,
  })
  vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, {
    buffer = buf,
    callback = function() show_cursor() end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    callback = function()
      show_cursor()
      state[buf] = nil
      _range_cache[buf] = nil
    end,
  })
  -- frames span the window width: re-render when it changes (explorer or
  -- terminal toggles, window resizes)
  vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    buffer = buf,
    callback = function() refresh_render(buf) end,
  })

  M.enter_command(buf)
  -- the first cell's top border is a virt line ABOVE buffer line 1: pull
  -- it into view on open
  vim.schedule(function()
    local win = vim.fn.bufwinid(buf)
    if win ~= -1 and vim.api.nvim_win_get_cursor(win)[1] <= 3 then
      vim.api.nvim_win_call(win, function()
        pcall(vim.fn.winrestview, { topline = 1, topfill = 5 })
      end)
    end
  end)
end

function M.setup_hl()
  local hl = vim.api.nvim_set_hl
  hl(0, "JupynvimBorderEdit", { fg = "#9ece6a", bold = true })
  hl(0, "JupynvimHiddenCursor", { blend = 100, nocombine = true })
end

return M

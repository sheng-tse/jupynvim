-- VSCode-style cell interaction model.
--
-- A notebook buffer is always in one of two modes:
--
--   COMMAND (default)  j/k select whole cells (bar + background highlight,
--                      like VSCode's blue selection bar). The buffer is
--                      non-modifiable so stray keys can't edit text.
--                      Enter (or i) dives into the selected cell.
--                      a/b add cells, dd deletes, yy/p copy/paste cells,
--                      gg/G first/last cell.
--
--   EDIT               normal vim inside the cell text. Esc (from normal
--                      mode) returns to COMMAND.
--
-- The statuscolumn renders PER-CELL line numbers (each cell counts from 1,
-- separator lines blank) plus the selection bar, mirroring how VSCode gives
-- every cell its own little editor with its own gutter.

local M = {}

local Notebook = require("jupynvim.notebook")

local ns = vim.api.nvim_create_namespace("jupynvim.cellmode")

-- buf -> { mode = "command"|"edit" }
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
-- Per-cell line numbers: each cell's gutter counts from 1. The selected
-- cell (command mode) gets the VSCode-style bar; in edit mode the bar turns
-- green on the active cell.
function M.statuscol()
  local buf = vim.api.nvim_get_current_buf()
  if not Notebook.get(buf) then return "" end
  local lnum = vim.v.lnum
  local ranges = M.ranges(buf)
  local line0 = lnum - 1
  local in_cell, rel
  local sel = M.selected_idx(buf)
  local cur_idx
  for i, r in ipairs(ranges) do
    if line0 >= r.start and line0 < r.stop then
      in_cell, rel, cur_idx = true, line0 - r.start + 1, i
      break
    end
  end
  if not in_cell then
    return "      "  -- separator line: blank gutter
  end
  local bar = " "
  if cur_idx == sel then
    if M.is_command(buf) then
      bar = "%#JupynvimBarSel#▎%*"
    else
      bar = "%#JupynvimBarEdit#▎%*"
    end
  end
  return bar .. "%=%#LineNr#" .. string.format("%3d", rel) .. " %*"
end

-- ── selection highlight ────────────────────────────────────────────────────
local function redraw_selection(buf)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  if not M.is_command(buf) then return end
  local idx = M.selected_idx(buf)
  local r = M.ranges(buf)[idx]
  if not r then return end
  local total = vim.api.nvim_buf_line_count(buf)
  for ln = r.start, math.min(r.stop - 1, total - 1) do
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, ln, 0, {
      line_hl_group = "JupynvimCellSelectedBg",
      priority = 5,
    })
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
  state[buf] = state[buf] or {}
  if state[buf].mode == "command" then
    redraw_selection(buf)
    return
  end
  state[buf].mode = "command"
  vim.bo[buf].modifiable = false
  -- park the cursor at the start of the selected cell, like VSCode focusing
  -- the cell rather than a character position
  local win = vim.fn.bufwinid(buf)
  if win ~= -1 then
    local lnum = vim.api.nvim_win_get_cursor(win)[1]
    local _, r = M.cell_idx_at(buf, lnum)
    if r then pcall(vim.api.nvim_win_set_cursor, win, { r.start + 1, 0 }) end
  end
  redraw_selection(buf)
  vim.cmd("redraw")
end

function M.enter_edit(buf, keys)
  buf = buf or vim.api.nvim_get_current_buf()
  state[buf] = state[buf] or {}
  state[buf].mode = "edit"
  vim.bo[buf].modifiable = true
  redraw_selection(buf)
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
  redraw_selection(buf)
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
  -- the new empty cell is now selected/below; fill it in
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
    redraw_selection(buf)
  end)
end

-- ── attach ─────────────────────────────────────────────────────────────────
-- Buffer-local keymaps + autocmds implementing the two-mode model.
function M.attach(buf, api)
  state[buf] = { mode = "edit" }  -- enter_command below flips it (and guards)

  local function map(mode, lhs, fn, desc)
    vim.keymap.set(mode, lhs, fn, { buffer = buf, silent = true, nowait = true, desc = desc })
  end

  -- command-mode navigation. The guard pattern: in edit mode the same key
  -- falls through to its native behavior.
  local function cmdmap(lhs, fn, desc, fallthrough)
    map("n", lhs, function()
      if M.is_command(buf) then
        fn()
      else
        vim.api.nvim_feedkeys(
          vim.api.nvim_replace_termcodes(fallthrough or lhs, true, false, true), "n", false)
      end
    end, desc)
  end

  cmdmap("j", function() M.move_selection(buf, 1) end, "jupynvim: next cell")
  cmdmap("k", function() M.move_selection(buf, -1) end, "jupynvim: prev cell")
  cmdmap("<Down>", function() M.move_selection(buf, 1) end, "jupynvim: next cell", "<Down>")
  cmdmap("<Up>", function() M.move_selection(buf, -1) end, "jupynvim: prev cell", "<Up>")
  cmdmap("gg", function() M.select_first(buf) end, "jupynvim: first cell")
  cmdmap("G", function() M.select_last(buf) end, "jupynvim: last cell")
  cmdmap("dd", function()
    with_modifiable(buf, function() api.delete_cell(buf) end)
    redraw_selection(buf)
  end, "jupynvim: delete cell")
  cmdmap("yy", function() M.yank_cell(buf) end, "jupynvim: yank cell")
  cmdmap("p", function() M.paste_cell(buf, api) end, "jupynvim: paste cell below")
  cmdmap("a", function()
    with_modifiable(buf, function() api.add_cell(buf, "above") end)
    vim.schedule(function() redraw_selection(buf) end)
  end, "jupynvim: add cell above", "a")
  cmdmap("b", function()
    with_modifiable(buf, function() api.add_cell(buf, "below") end)
    vim.schedule(function() redraw_selection(buf) end)
  end, "jupynvim: add cell below", "b")

  -- Enter edit mode. Enter = plain focus; i/o/O carry their editing intent.
  map("n", "<CR>", function()
    if M.is_command(buf) then
      M.enter_edit(buf)
    else
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "n", false)
    end
  end, "jupynvim: edit cell")
  cmdmap("i", function() M.enter_edit(buf) end, "jupynvim: edit cell", "i")
  cmdmap("I", function() M.enter_edit(buf, "I") end, "jupynvim: edit cell", "I")
  cmdmap("A", function() M.enter_edit(buf, "A") end, "jupynvim: edit cell", "A")
  cmdmap("o", function() M.enter_edit(buf, "o") end, "jupynvim: edit cell", "o")
  cmdmap("O", function() M.enter_edit(buf, "O") end, "jupynvim: edit cell", "O")

  -- Esc: edit -> command (VSCode). In command mode it stays put (and clears
  -- search highlight so the global Esc habit still works).
  map("n", "<Esc>", function()
    if M.is_command(buf) then
      vim.cmd("nohlsearch")
    else
      M.enter_command(buf)
    end
  end, "jupynvim: cell command mode")

  -- keep the selection bar in sync with any cursor movement (]c, S-CR
  -- advance, mouse clicks, searches)
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = buf,
    callback = function()
      if M.is_command(buf) then redraw_selection(buf) end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    callback = function()
      state[buf] = nil
      _range_cache[buf] = nil
    end,
  })

  M.enter_command(buf)
end

function M.setup_hl()
  local hl = vim.api.nvim_set_hl
  hl(0, "JupynvimBarSel",  { fg = "#7aa2f7", bold = true })
  hl(0, "JupynvimBarEdit", { fg = "#9ece6a", bold = true })
  hl(0, "JupynvimCellSelectedBg", { bg = "#1f2335" })
end

return M

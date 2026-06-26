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
-- numbers (relative distances anchored on the line the cursor last sat
-- on; the anchor line keeps its in-cell absolute number, highlighted),
-- the selection bar, and the box's left border. Markdown cells and
-- output rows get bar-only gutters, exactly like VSCode. Keeping the
-- border out of the text area also means the insert cursor aligns
-- correctly on empty lines.

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
  local cur, out_sep = 0, nil
  for i, line in ipairs(lines) do
    if line == Notebook.CELL_SEP then
      table.insert(ranges, {
        start = cur,
        stop = out_sep or (i - 1),          -- SOURCE end (exclusive)
        out_sep = out_sep,                   -- 0-based OUT_SEP line, if any
        out_stop = out_sep and (i - 1) or nil, -- output end (exclusive)
      })
      cur, out_sep = i, nil
    elseif line == Notebook.OUT_SEP and not out_sep then
      out_sep = i - 1
    end
  end
  table.insert(ranges, {
    start = cur,
    stop = out_sep or #lines,
    out_sep = out_sep,
    out_stop = out_sep and #lines or nil,
  })
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

-- Per-cell remembered cursor positions (idx -> {line, col}), for the
-- cursor-persistence module to save and restore across reopen.
function M.get_positions(buf)
  return (state[buf] or {}).pos or {}
end

function M.set_position(buf, idx, line, col)
  state[buf] = state[buf] or { pos = {} }
  state[buf].pos = state[buf].pos or {}
  state[buf].pos[idx] = { line, col or 0 }
end

-- ── statuscolumn ───────────────────────────────────────────────────────────
-- Per-cell gutter. Every branch renders exactly M.GUTTER display cells so
-- the text area never shifts between lines.
--
-- `buf` is baked into each window's option string: the expression can be
-- evaluated while a DIFFERENT window is current (file explorer focused,
-- for example), so resolving "the current buffer" here used to blank the
-- whole gutter and visually break every frame's left side.
function M.statuscol(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    buf = vim.api.nvim_get_current_buf()
  end
  return M._statuscol_for(buf, vim.v.lnum, vim.v.virtnum)
end

-- Pure form (testable): gutter content for (buf, lnum, virtnum).
function M._statuscol_for(buf, lnum, virtnum)
  local nb = Notebook.get(buf)
  if not nb then return "" end
  local ranges = M.ranges(buf)
  local line0 = lnum - 1
  local r, idx
  for i, range in ipairs(ranges) do
    if line0 >= range.start and line0 < (range.out_stop or range.stop) then
      r, idx = range, i
      break
    end
  end
  if not r then return string.rep(" ", M.GUTTER) end  -- separator line
  local sel = M.selected_idx(buf)
  local st = state[buf]
  local cell = nb.cells[idx]
  local command = M.is_command(buf)
  local editing = (not command) and idx == ((st and st.edit_idx) or sel)
  local boxed = (cell and cell.cell_type == "code") or editing
  -- selection indicator: far-left bar (VSCode), same for every cell type;
  -- frames themselves stay calm and identical. Virtual rows (images,
  -- spacers, table borders) and output rows keep the bar so it runs the
  -- cell's full height without gaps.
  local bar = (idx == sel) and "%#JupynvimBarSel#▌%*" or " "
  local in_src = line0 < r.stop
  if virtnum < 0 or not in_src or not boxed then
    return bar .. string.rep(" ", M.GUTTER - 1)
  end
  local cbusy = cell and nb.cell_state and nb.cell_state[cell.id]
    and nb.cell_state[cell.id].exec_state == "busy"
  local edge = "%#" .. (cbusy and "JupynvimBusy" or "JupynvimBorder") .. "#│%* "
  if virtnum > 0 then
    return bar .. "    " .. edge  -- wrap continuation rows carry no number
  end
  -- RELATIVE numbering in EVERY cell, anchored on the cell's "current line",
  -- which is ALWAYS highlighted ORANGE. The current line is, in order: the live
  -- cursor while you're editing this cell; else the line you last sat on once
  -- you've edited it (remembered across Esc and across moving away); else, by
  -- default, the cell's FIRST line. So a cell you've never entered still shows
  -- its first line as the current line in orange, like VSCode. Other lines show
  -- their distance to it. In command mode the orange is a stable per-cell marker
  -- (first/remembered): j/k moves the selection bar, not the orange; only the
  -- live cursor while editing moves it.
  local n, num_hl = line0 - r.start + 1, "LineNr"
  local anchor = r.start + 1
  local saved = st and st.pos and st.pos[idx]
  if saved and saved[1] - 1 >= r.start and saved[1] - 1 < r.stop then
    anchor = saved[1]
  end
  if not command then
    local win = vim.fn.bufwinid(buf)
    if win ~= -1 then
      local cl = vim.api.nvim_win_get_cursor(win)[1]
      if cl - 1 >= r.start and cl - 1 < r.stop then anchor = cl end
    end
  end
  if lnum == anchor then
    num_hl = "CursorLineNr"                      -- the current line, in orange
  else
    n = math.abs(lnum - anchor)                  -- distance to the current line
  end
  return bar .. "%#" .. num_hl .. "#" .. string.format("%3d", n) .. "%* " .. edge
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

local function refresh_render(buf, opts)
  local nb = Notebook.get(buf)
  if nb then
    require("jupynvim.render").refresh(nb, vim.fn.bufwinid(buf), opts)
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
    -- remember where the cursor was inside the cell we're leaving (source
    -- positions only: the anchor and Enter-restore both live in the source)
    if win ~= -1 and state[buf].edit_idx then
      local cur = vim.api.nvim_win_get_cursor(win)
      local r = M.ranges(buf)[state[buf].edit_idx]
      if r and cur[1] - 1 >= r.start and cur[1] - 1 < r.stop then
        state[buf].pos[state[buf].edit_idx] = cur
      end
    end
  end
  state[buf].mode = "command"
  state[buf].edit_idx = nil
  vim.bo[buf].modifiable = false
  if win ~= -1 and vim.api.nvim_get_current_buf() == buf then
    hide_cursor()
  end
  -- The hidden command-mode cursor must not paint a line: with the user's
  -- 'cursorline' on, Neovim would light up the parked cursor's first line (its
  -- number in CursorLineNr + the CursorLine background), competing with the
  -- per-cell orange anchor, which is the SOLE current-line indicator here.
  -- j/k select whole cells; the cursor's exact line is irrelevant in command
  -- mode, so it must not be highlighted. Restored on edit (see enter_edit).
  if win ~= -1 then pcall(function() vim.wo[win].cursorline = false end) end
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
  -- active-line highlight for editing (like VSCode): the visible cursor and the
  -- orange anchor are on the same line, so cursorline agrees with it. Turned off
  -- again on Esc (enter_command), so the hidden command cursor never paints a line.
  if win ~= -1 then pcall(function() vim.wo[win].cursorline = true end) end
  local idx = M.selected_idx(buf)
  state[buf].edit_idx = idx
  state[buf].region = "src"
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
  if win == -1 or not r then return end
  -- Just move the cursor. NO extmark re-render (bars are statuscolumn-only,
  -- redrawn live with the cursor) and NO reveal-scroll: forcing a layout
  -- pass via line("w$") + normal! <C-e> on every j/k thrashed redraws
  -- (badly, against the gif's continuous frame writes) and made cell
  -- navigation laggy. nvim's own scrolloff keeps the cell in view.
  pcall(vim.api.nvim_win_set_cursor, win, { r.start + 1, 0 })
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
-- }, searches, everything). The clamp is REGION-aware: while the cursor
-- is in the cell's output region, motions clamp to the OUTPUT's bounds
-- (G goes to the output's last line, not back into the source).
local function clamp_to_cell(buf)
  local st = state[buf]
  if not st or st.mode ~= "edit" or not st.edit_idx then return end
  local win = vim.fn.bufwinid(buf)
  if win == -1 or vim.api.nvim_get_current_buf() ~= buf then return end
  local r = M.ranges(buf)[st.edit_idx]
  if not r then return end
  local cur = vim.api.nvim_win_get_cursor(win)
  local lnum = cur[1]
  local in_src = lnum - 1 >= r.start and lnum - 1 < r.stop
  local in_out = r.out_sep and lnum - 1 > r.out_sep and r.out_stop and lnum - 1 < r.out_stop
  if in_src then
    st.region = "src"
  elseif in_out then
    st.region = "out"
  else
    local lo, hi
    if st.region == "out" and r.out_sep and r.out_stop then
      lo, hi = r.out_sep + 2, math.max(r.out_stop, r.out_sep + 2)
    else
      lo, hi = r.start + 1, math.max(r.stop, r.start + 1)
    end
    pcall(vim.api.nvim_win_set_cursor, win, { lnum < lo and lo or hi, cur[2] })
  end
  -- live anchor for the gutter's hybrid numbers + Enter's cursor memory
  -- (source positions only; output hops shouldn't move the anchor)
  local now = vim.api.nvim_win_get_cursor(win)
  if now[1] - 1 >= r.start and now[1] - 1 < r.stop then
    st.pos[st.edit_idx] = now
  end
end
M.clamp_to_cell = clamp_to_cell

-- C-j/C-k inside a cell: hop between the source editor and its output
-- region (both are real buffer lines).
function M.focus_output(buf)
  local st = state[buf]
  local idx = (st and st.edit_idx) or M.selected_idx(buf)
  local r = M.ranges(buf)[idx]
  local win = vim.fn.bufwinid(buf)
  if not (r and r.out_sep and win ~= -1) then
    vim.notify("jupynvim: this cell has no output", vim.log.levels.INFO)
    return
  end
  if st then st.region = "out" end
  pcall(vim.api.nvim_win_set_cursor, win, { math.min(r.out_sep + 2, r.out_stop), 2 })
end

function M.focus_source(buf)
  local st = state[buf]
  local idx = (st and st.edit_idx) or M.selected_idx(buf)
  local r = M.ranges(buf)[idx]
  local win = vim.fn.bufwinid(buf)
  if not (r and win ~= -1) then return end
  if st then st.region = "src" end
  pcall(vim.api.nvim_win_set_cursor, win, { math.max(r.stop, r.start + 1), 0 })
end

-- ── attach ─────────────────────────────────────────────────────────────────
function M.attach(buf, api)
  state[buf] = { mode = "edit", pos = {}, region = "src" }

  -- Notebook navigation should be instant (one-shot cell-to-cell), not the
  -- smooth-scroll "dragging" animation. snacks.scroll (a LazyVim default) runs
  -- in the LOCAL frontend and animates every scroll; over a remote backend that
  -- per-frame animation competes with the gif's main-loop frame writes and
  -- feels laggy, while a bare nvim (no snacks.scroll) felt snappy. Disable it
  -- for the notebook buffer unless the user opts back in with smooth_scroll=true.
  if not (api and api.config and api.config.smooth_scroll) then
    vim.b[buf].snacks_scroll = false
  end

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
    if not r then return end
    local l = vim.api.nvim_win_get_cursor(0)[1]
    local in_out = r.out_sep and l - 1 > r.out_sep
    local limit = in_out and (r.out_stop or r.stop) or r.stop
    if l < limit then
      vim.api.nvim_feedkeys("j", "n", false)
    end
  end
  local function edit_up()
    local r = edit_cell_range()
    if not r then return end
    local l = vim.api.nvim_win_get_cursor(0)[1]
    local in_out = r.out_sep and l - 1 > r.out_sep
    local floor = in_out and (r.out_sep + 2) or (r.start + 1)
    if l > floor then
      vim.api.nvim_feedkeys("k", "n", false)
    end
  end
  cmdmap("j", function() M.move_selection(buf, 1) end, "jupynvim: next cell", edit_down)
  cmdmap("k", function() M.move_selection(buf, -1) end, "jupynvim: prev cell", edit_up)
  cmdmap("<Down>", function() M.move_selection(buf, 1) end, "jupynvim: next cell", edit_down)
  cmdmap("<Up>", function() M.move_selection(buf, -1) end, "jupynvim: prev cell", edit_up)
  -- gg/G: first/last cell in command mode, first/last line OF THE REGION
  -- the cursor is in while editing (source editor or output region)
  cmdmap("gg", function() M.select_first(buf) end, "jupynvim: first cell", function()
    local r = edit_cell_range()
    if not r then return end
    local st = state[buf]
    if st and st.region == "out" and r.out_sep and r.out_stop then
      pcall(vim.api.nvim_win_set_cursor, 0, { r.out_sep + 2, 0 })
    else
      pcall(vim.api.nvim_win_set_cursor, 0, { r.start + 1, 0 })
    end
  end)
  cmdmap("G", function() M.select_last(buf) end, "jupynvim: last cell", function()
    local r = edit_cell_range()
    if not r then return end
    local st = state[buf]
    if st and st.region == "out" and r.out_sep and r.out_stop then
      pcall(vim.api.nvim_win_set_cursor, 0, { math.max(r.out_stop, r.out_sep + 2), 0 })
    else
      pcall(vim.api.nvim_win_set_cursor, 0, { math.max(r.stop, r.start + 1), 0 })
    end
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

  -- Mouse: a single click on a rendered markdown link opens it. Rendered
  -- markdown isn't cursor-addressable in command mode (j/k jump whole
  -- cells), so the mouse is how links get followed, like VSCode's
  -- rendered view. Falls through to the normal click everywhere else.
  vim.keymap.set("n", "<LeftRelease>", function()
    if M.is_command(buf) and api.click_link and api.click_link(buf) then
      return "<Ignore>"
    end
    return "<LeftRelease>"
  end, { buffer = buf, expr = true, silent = true, desc = "jupynvim: open link under mouse" })

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
      if not M.is_command(buf) then
        clamp_to_cell(buf)
      end
      -- command-mode selection needs no re-render: extmarks are
      -- selection-independent and the statuscolumn bar follows the
      -- cursor on the same redraw
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
  -- Any layout change (opening/closing the explorer or a terminal, a manual
  -- :vsplit, GUI resize) does TWO bad things to the notebook window:
  --   1. if the width changed, the full-width frame strings are stale, and
  --   2. closing a terminal/float does only a PARTIAL screen repaint, so the
  --      notebook's cells show stale pixels even when the frame data is fine
  --      (verified via :JupynvimDebugFrames — the extmarks are correct; the
  --      SCREEN isn't repainted).
  -- These are GLOBAL events (a buffer-local autocmd never fires for them) and
  -- this handler fires regardless of how a key like <C-/> is routed (snacks
  -- may swallow it inside its own terminal, bypassing our dispatcher). So:
  -- re-render (fixes width) AND force a redraw (flushes the stale screen).
  -- The redraw is what actually repairs the "broken after C-/" case.
  local resize_pending = false
  local function resize_refresh()
    if not vim.api.nvim_buf_is_valid(buf) then return end
    if vim.fn.bufwinid(buf) == -1 then return end
    -- Skip while the cmdline is open. Typing ":" pops a completion float, which
    -- fires WinNew/WinClosed; re-rendering the frames then (with the cmdline
    -- popup as the active window) drew them off-shape until Esc.
    if vim.fn.getcmdtype() ~= "" then return end
    if resize_pending then return end  -- coalesce bursts into one redraw
    resize_pending = true
    refresh_render(buf)
    vim.schedule(function()
      resize_pending = false
      local win = vim.fn.bufwinid(buf)
      if vim.api.nvim_buf_is_valid(buf) and win ~= -1 then
        pcall(vim.cmd, "redraw")
        -- the left frame is the statuscolumn, which a plain redraw leaves stale
        -- on undirtied source lines; force it to re-evaluate too
        pcall(vim.api.nvim__redraw, { win = win, statuscolumn = true, valid = false })
      end
    end)
  end
  local resize_group = vim.api.nvim_create_augroup("jupynvim_resize_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd(
    { "WinResized", "VimResized", "WinNew", "WinClosed" },
    { group = resize_group, callback = resize_refresh }
  )

  -- Anything that overlaps or relayouts around the notebook (notify popups, the
  -- <leader>n history, the <leader><leader> picker, a <C-/> terminal split, the
  -- explorer) leaves the frame's virt_line borders visually broken. A plain
  -- redraw does NOT repaint stale virt_lines (verified: the user's working fix
  -- is i/a, which goes through enter_edit -> refresh_render, a real re-render).
  -- So when focus lands back on the notebook, rebuild the borders. Crucially we
  -- pass no_image=true: this rebuilds the frame extmarks (fixing the screen)
  -- WITHOUT re-asserting kitty placements, which is what made an earlier
  -- re-render-on-WinEnter rework disturb images. Border rebuild is cheap and
  -- debounced, so doing it on every focus-return is fine.
  vim.api.nvim_create_autocmd("WinEnter", {
    group = resize_group,
    callback = function()
      if vim.fn.getcmdtype() ~= "" then return end
      if vim.api.nvim_get_current_buf() ~= buf then return end
      local win = vim.fn.bufwinid(buf)
      if win == -1 then return end
      local nb = Notebook.get(buf)
      if not nb then return end
      -- SYNCHRONOUS rebuild (not the debounced refresh, which gets dropped when
      -- another refresh is already pending — that is the "sometimes it fixes,
      -- sometimes it doesn't"). Rebuilds the virt_line borders AND the output
      -- virt_lines (where the stale selection bar lived). no_image so kitty
      -- placements are untouched.
      pcall(require("jupynvim.render").refresh_sync, nb, win, { no_image = true })
      -- Force a full window repaint: the left frame is the statuscolumn, which a
      -- plain redraw leaves stale on undirtied lines (real AND output-virtline),
      -- so invalidate the whole window and re-evaluate its statuscolumn.
      pcall(vim.api.nvim__redraw, { win = win, valid = false, statuscolumn = true })
    end,
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
  hl(0, "JupynvimBarSel", { default = true, link = "DiagnosticInfo" })
  hl(0, "JupynvimHiddenCursor", { default = true, blend = 100, nocombine = true })
end

return M

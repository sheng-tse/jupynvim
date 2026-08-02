-- Headless verification of the VSCode-style cell UI.
local here = debug.getinfo(1, "S").source:sub(2)
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(here, ":p:h:h"))

local J = require("jupynvim")
J.setup({})
local Notebook = require("jupynvim.notebook")
local Render = require("jupynvim.notebook.render")
local CellMode = require("jupynvim.notebook.cellmode")

local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(buf)
local snapshot = { cells = {
  { id = "c1", cell_type = "markdown", source = "# Title\nSome **bold** text" },
  { id = "c2", cell_type = "code", source = "print(1)\nprint(2)", execution_count = 1,
    outputs = { { output_type = "stream", name = "stdout", text = string.rep("x\n", 40) } } },
  { id = "c3", cell_type = "code", source = "1+1", outputs = {} },
} }
local nb = Notebook.create(buf, "/tmp/t.ipynb", "sess", snapshot)
J._populate_buffer(nb)
CellMode.attach(buf, J)
local win = vim.api.nvim_get_current_win()

local function feed(keys, m)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), m or "mx", false)
end

-- Buffer layout: 1:# Title 2:Some.. 3:SEP 4:print(1) 5:print(2) 6:SEP 7:1+1

-- A. command mode by default, buffer locked, gutter installed with the
--    buffer number BAKED IN (the expression can evaluate while another
--    window is current, e.g. the file explorer has focus)
assert(CellMode.is_command(buf), "not in command mode after attach")
assert(vim.bo[buf].modifiable == false, "buffer modifiable in command mode")
assert(vim.wo[win].statuscolumn:find("statuscol(" .. buf .. ")", 1, true),
  "statuscolumn must bake in the bufnr: " .. vim.wo[win].statuscolumn)
print("A. command mode + lock + statuscolumn(buf) ok")

-- B. gutter semantics
vim.api.nvim_win_set_cursor(win, { 1, 0 })  -- select markdown cell 1
local function sc(lnum, virtnum)
  return CellMode._statuscol_for(buf, lnum, virtnum or 0)
end
-- code cells are numbered even when not selected. Each cell's "current line"
-- is highlighted orange: by default its FIRST line (a cell never entered), so
-- cell 2's first line reads "1" in CursorLineNr; line 2 reads its distance "1".
assert(sc(4):find("CursorLineNr", 1, true) and sc(4):find("  1", 1, true)
  and sc(4):find("│", 1, true),
  "unvisited cell's first line is the orange current line: " .. sc(4))
assert(sc(5):find("%d"), "code lines are numbered: " .. sc(5))
assert(not sc(3):find("%d"), "separator must have blank gutter")
assert(not sc(1):find("%d"), "markdown lines must have NO numbers: " .. sc(1))
assert(sc(1):find("▌", 1, true), "selected markdown cell must show the bar")
assert(sc(4, -1) == string.rep(" ", 7),
  "virt rows of UNselected cells: blank gutter: [" .. sc(4, -1) .. "]")
assert(sc(1, -1):find("▌", 1, true),
  "virt rows of the SELECTED cell carry the bar (continuous bar)")
assert(not sc(4, 2):find("%d"), "wrap rows carry no number")
assert(sc(4, 2):find("│", 1, true), "wrap rows keep the left border")
print("B. gutter: per-cell numbers, md/sep blanks, bar continuity ok")

-- C. j/k moves cell selection (cell3 sits after cell2's output region)
local R = CellMode.ranges(buf)
feed("j")
assert(vim.api.nvim_win_get_cursor(win)[1] == R[2].start + 1, "j did not select cell2")
feed("j")
assert(vim.api.nvim_win_get_cursor(win)[1] == R[3].start + 1, "j did not select cell3")
feed("j")
assert(vim.api.nvim_win_get_cursor(win)[1] == R[3].start + 1, "selection should clamp at last cell")
feed("k")
assert(vim.api.nvim_win_get_cursor(win)[1] == R[2].start + 1, "k did not select cell2")
-- output-region rows have a blank gutter
assert(not sc(R[2].out_sep + 2):find("%d"), "output rows must not be numbered")
print("C. j/k cell selection ok")

-- D. Enter -> edit; motions confined to the cell; Esc -> command;
--    cursor position remembered per cell
feed("<CR>")
assert(not CellMode.is_command(buf), "Enter did not enter edit mode")
assert(vim.bo[buf].modifiable == true, "edit mode should be modifiable")
feed("G")
assert(vim.api.nvim_win_get_cursor(win)[1] == 5, "G must go to the CELL's last line")
feed("gg")
assert(vim.api.nvim_win_get_cursor(win)[1] == 4, "gg must go to the CELL's first line")
feed("j"); feed("j")  -- would leave the cell; clamp must hold it
assert(vim.api.nvim_win_get_cursor(win)[1] == 5, "motion escaped the cell: line "
  .. vim.api.nvim_win_get_cursor(win)[1])
-- hybrid numbers: cursor on line 5 (cell line 2): the anchor shows its
-- in-cell ABSOLUTE number highlighted, neighbours show DISTANCES
assert(sc(5):find("CursorLineNr", 1, true) and sc(5):find("  2", 1, true),
  "anchor line must show highlighted in-cell absolute: " .. sc(5))
assert(sc(4):find("  1", 1, true) and not sc(4):find("CursorLineNr"),
  "neighbour must show distance: " .. sc(4))
feed("k")  -- cursor to line 4: line 5 must now read 1 (distance), not 2
assert(sc(4):find("CursorLineNr", 1, true), "anchor must follow the cursor: " .. sc(4))
assert(sc(5):find("  1", 1, true) and not sc(5):find("  2", 1, true),
  "numbers must be RELATIVE to the cursor line: " .. sc(5))
feed("j")  -- back to line 5
feed("<Esc>")
assert(CellMode.is_command(buf), "Esc did not return to command mode")
assert(vim.bo[buf].modifiable == false, "command mode should re-lock")
-- after Esc the numbers KEEP the last cursor line as their anchor
assert(sc(5):find("CursorLineNr", 1, true) and sc(5):find("  2", 1, true),
  "after Esc the anchor must stay on the last cursor line: " .. sc(5))
assert(sc(4):find("  1", 1, true), "after Esc distances stay relative: " .. sc(4))
-- inactive cells also show their current line (first line by default) in orange
local R3 = CellMode.ranges(buf)[3]
assert(sc(R3.start + 1):find("CursorLineNr", 1, true) and sc(R3.start + 1):find("  1", 1, true),
  "inactive cell's first line is the orange current line: " .. sc(R3.start + 1))
feed("<CR>")  -- re-enter: cursor restored to line 5
assert(vim.api.nvim_win_get_cursor(win)[1] == 5, "cursor position not remembered")
feed("<Esc>")
print("D. edit confinement + hybrid numbers + cursor memory ok")

-- E. render: leftcol frames, heavy selected border, exec bar, clamp,
--    frameless markdown
vim.api.nvim_win_set_cursor(win, { 4, 0 })  -- select code cell 2
Render.refresh(nb, win)
vim.wait(300)
local marks = vim.api.nvim_buf_get_extmarks(buf, nb.border_ns, 0, -1, { details = true })
local all_text = {}
for _, m in ipairs(marks) do
  local d = m[4]
  for _, vl in ipairs(d.virt_lines or {}) do
    local row = ""
    for _, chunk in ipairs(vl) do row = row .. chunk[1] end
    table.insert(all_text, row)
  end
end
local blob = table.concat(all_text, "\n")
assert(blob:find("╭", 1, true), "cell header missing")
assert(blob:find("─ Python ─", 1, true), "language label must sit in the footer (VSCode bottom-right)")
assert(not blob:find("╭─ Python", 1, true), "label must NOT be in the header anymore")
assert(not blob:find("┏", 1, true), "frames must stay uniform (no heavy variant)")
assert(blob:find("#2", 1, true), "cell number badge missing")
assert(blob:find("✓", 1, true), "exec check missing")
local xcount = 0
for _, row in ipairs(all_text) do if row:find("x%s*$") then xcount = xcount + 1 end end
assert(xcount == 0, "text outputs must be REAL lines, not virtual rows")
assert(not blob:find("Markdown", 1, true), "markdown cell should be frameless when not edited")
-- code cells no longer get a background fill: the VSCode-style dark fill read
-- as gray bands on a transparent theme (and smeared onto output rows on
-- scroll). Borders mark the cell instead.
local has_bg = false
for _, m in ipairs(marks) do
  if m[4].line_hl_group == "JupynvimCellBg" then has_bg = true end
end
assert(not has_bg, "code cells must NOT get a background fill")
for _, m in ipairs(marks) do
  local d = m[4]
  if d.virt_text_pos == "right_align" and m[2] <= 1 then
    error("markdown cell has a right border while not edited")
  end
end
-- output regions are masked to plain text (no treesitter code colors)
local plain = false
for _, m in ipairs(marks) do
  if m[4].hl_group == "JupynvimOutputText" then plain = true end
end
assert(plain, "output regions must be masked to plain text")
print("E. render: frames, exec, frameless md, plain outputs ok")

-- E2. editing a markdown cell draws the source editor box
vim.api.nvim_win_set_cursor(win, { 1, 0 })
feed("<CR>")  -- edit markdown cell
Render.refresh(nb, win)
vim.wait(300)
marks = vim.api.nvim_buf_get_extmarks(buf, nb.border_ns, 0, -1, { details = true })
local md_blob = ""
for _, m in ipairs(marks) do
  for _, vl in ipairs((m[4]).virt_lines or {}) do
    for _, chunk in ipairs(vl) do md_blob = md_blob .. chunk[1] end
    md_blob = md_blob .. "\n"
  end
end
assert(md_blob:find("Markdown", 1, true), "edited markdown cell must show its editor box")
feed("<Esc>")
print("E2. markdown edit box ok")

-- F. execution timing
nb:apply_cell_event("c3", { kind = "execute_input", execution_count = 2 })
local st = nb.cell_state["c3"]
assert(st.exec_state == "busy" and st.started_ns, "busy stopwatch not started")
vim.wait(30)
nb:apply_cell_event("c3", { kind = "status", state = "idle" })
st = nb.cell_state["c3"]
assert(st.duration_ns and st.duration_ns > 0, "duration not stamped")
local chunks = Render._exec_status_chunks(nb.cells[3], st)
local s = ""
for _, c in ipairs(chunks) do s = s .. c[1] end
assert(s:find("✓ "), "done bar should show check + duration: " .. s)
nb:apply_cell_event("c2", { kind = "execute_input", execution_count = 3 })
nb:apply_cell_event("c2", { kind = "error", ename = "E", evalue = "boom", traceback = {} })
nb:apply_cell_event("c2", { kind = "status", state = "idle" })
chunks = Render._exec_status_chunks(nb.cells[2], nb.cell_state["c2"])
s = ""
for _, c in ipairs(chunks) do s = s .. c[1] end
assert(s:find("✗"), "error bar should show cross: " .. s)
print("F. execution timing ok: " .. s)

-- F3. a RUNNING cell paints the WHOLE frame in the busy color, not only the
-- top: footer dashes thread border_hl and the statuscolumn left edge flips to
-- JupynvimBusy. Previously only the top border reacted.
nb:apply_cell_event("c3", { kind = "execute_input", execution_count = 4 })
assert(nb.cell_state["c3"].exec_state == "busy", "c3 should be busy")
local bc3 = { bl = "╰", h = "─", br = "╯" }
local fbusy = Render._footer_chunks(80, 7, bc3, "Python", nb.cells[3], nb.cell_state["c3"], "JupynvimBusy")
-- check the corner + tail (pure border; the exec badge is busy-colored anyway,
-- so "find any JupynvimBusy" would pass even without the fix).
assert(fbusy[1][2] == "JupynvimBusy" and fbusy[#fbusy][2] == "JupynvimBusy",
  "footer corner/tail dashes must use the busy border color while running")
local r3 = CellMode.ranges(buf)[3]
local sc3 = CellMode._statuscol_for(buf, r3.start + 1, 0)
assert(sc3:find("JupynvimBusy", 1, true), "left edge must be JupynvimBusy while running: " .. sc3)
nb:apply_cell_event("c3", { kind = "status", state = "idle" })
local sc3i = CellMode._statuscol_for(buf, r3.start + 1, 0)
assert(sc3i:find("JupynvimBorder", 1, true), "left edge returns to JupynvimBorder when idle: " .. sc3i)
print("F3. running cell paints the whole frame busy ok")

-- F2. duration survives save + reopen: restored from jupyter-standard
--     timing metadata (metadata.execution stamps)
local ns2 = Notebook.saved_duration_ns({ execution = {
  ["iopub.execute_input"] = "2026-06-12T21:38:05.100Z",
  ["shell.execute_reply"] = "2026-06-12T21:38:05.400Z",
} })
assert(ns2 and math.abs(ns2 - 0.3e9) < 0.05e9,
  "saved duration parse wrong: " .. tostring(ns2))
local buf2 = vim.api.nvim_create_buf(true, false)
local nb2 = Notebook.create(buf2, "/tmp/t2.ipynb", "s2", { cells = {
  { id = "z1", cell_type = "code", source = "1", execution_count = 4,
    outputs = {},
    metadata = { execution = {
      ["iopub.execute_input"] = "2026-06-12T21:38:05.100Z",
      ["shell.execute_reply"] = "2026-06-12T21:38:06.600Z",
    } } },
} })
local zst = nb2.cell_state["z1"]
assert(zst and zst.duration_ns and zst.exec_state == "idle",
  "duration not restored from metadata on open")
local zs = ""
for _, c in ipairs(Render._exec_status_chunks(nb2.cells[1], zst)) do zs = zs .. c[1] end
assert(zs:find("✓ 1.5s", 1, true), "restored bar must show check + duration: " .. zs)
print("F2. saved timing restored on open ok")

-- G. outputs are REAL buffer lines: C-j enters them, motions/yank work
local CMr = CellMode.ranges(buf)
assert(CMr[2].out_sep, "cell2 must have an output region")
local sep_text = vim.api.nvim_buf_get_lines(buf, CMr[2].out_sep, CMr[2].out_sep + 1, false)[1]
assert(sep_text == Notebook.OUT_SEP, "OUT_SEP marker missing")
local first_out = vim.api.nvim_buf_get_lines(buf, CMr[2].out_sep + 1, CMr[2].out_sep + 2, false)[1]
assert(first_out == "  x", "output text not in buffer: " .. tostring(first_out))
-- sync_from_buffer must NOT absorb output lines into the source
nb:sync_from_buffer()
assert(nb.cells[2].source == "print(1)\nprint(2)", "outputs leaked into source: " .. nb.cells[2].source)
-- command mode: C-j is window navigation (no-op in a single window)
assert(CellMode.is_command(buf), "expected command mode")
J.enter_output(buf, "down")
assert(vim.api.nvim_get_current_buf() == buf, "command-mode C-j must stay put")
-- edit mode: C-j focuses the output region, C-k returns to the source
vim.api.nvim_win_set_cursor(win, { 4, 0 })
feed("<CR>")
J.enter_output(buf, "down")
local l = vim.api.nvim_win_get_cursor(win)[1]
assert(l - 1 > CMr[2].out_sep and l - 1 < CMr[2].out_stop, "C-j did not land in the output region: " .. l)
feed("yy")
assert(vim.fn.getreg('"'):find("x"), "yank in output region failed")
feed("j")  -- moves within the region
assert(vim.api.nvim_win_get_cursor(win)[1] == l + 1, "j inside output should move")
-- region-aware G/gg: inside the output they go to the OUTPUT's bounds,
-- not back to the source editor
feed("G")
assert(vim.api.nvim_win_get_cursor(win)[1] == CMr[2].out_stop,
  "G inside the output must land on the output's LAST line, got "
  .. vim.api.nvim_win_get_cursor(win)[1])
feed("gg")
assert(vim.api.nvim_win_get_cursor(win)[1] == CMr[2].out_sep + 2,
  "gg inside the output must land on the output's FIRST line, got "
  .. vim.api.nvim_win_get_cursor(win)[1])
J.enter_output(buf, "up")
assert(vim.api.nvim_win_get_cursor(win)[1] == 5, "C-k did not return to the source")
feed("G")
assert(vim.api.nvim_win_get_cursor(win)[1] == 5,
  "G back in the source must clamp to the SOURCE's last line")
feed("<Esc>")
-- kernel events rewrite the region in place
nb:apply_cell_event("c3", { kind = "execute_input", execution_count = 9 })
nb:apply_cell_event("c3", { kind = "stream", name = "stdout", text = "fresh\n" })
nb:apply_cell_event("c3", { kind = "status", state = "idle" })
J._queue_output_sync(buf, nb, "c3")
vim.wait(400)
local found = false
for _, bl in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
  if bl == "  fresh" then found = true end
end
assert(found, "output sync did not write the new region")
assert(vim.bo[buf].modifiable == false, "command mode lock lost after sync")
print("G. real output regions ok")

-- H. the gutter renders no matter which window/buffer is CURRENT: a
--    focused file explorer must not blank the notebook's numbers/borders
local scratch = vim.api.nvim_create_buf(false, true)
vim.cmd("vsplit")
vim.api.nvim_set_current_buf(scratch)
assert(vim.api.nvim_get_current_buf() ~= buf, "setup: scratch not current")
local g = CellMode._statuscol_for(buf, 4, 0)
assert(g:find("│", 1, true) and g:find("%d"),
  "gutter must render with another buffer current: [" .. g .. "]")
vim.cmd("close")
print("H. gutter independent of focused window ok")

-- I. selection bars live ONLY in the statuscolumn. Extmark rows must
--    never carry one (extmark bars wait on a re-render, so they lag j/k
--    and linger over gif/image rows), and the gutter bar must follow the
--    selection immediately, with no extmark re-render involved.
vim.api.nvim_win_set_cursor(win, { 1, 0 })       -- select md cell 1
CellMode.move_selection(buf, 1)                  -- -> cell 2
vim.wait(200)
local Rng = CellMode.ranges(buf)
for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, nb.border_ns, 0, -1, { details = true })) do
  for _, vl in ipairs(m[4].virt_lines or {}) do
    assert(vl[1][1] ~= "▌", "extmark rows must never carry the selection bar")
  end
end
assert(sc(Rng[2].start + 1):find("▌", 1, true), "gutter bar must be on the new selection")
assert(not sc(1):find("▌", 1, true), "gutter bar must leave the previous cell")
print("I. statuscolumn-only selection bar ok")

-- J. a source ending in "\n" must NOT create a phantom trailing empty
--    line (it showed a stray gutter number above the next cell)
local pbuf = vim.api.nvim_create_buf(true, false)
local pnb = Notebook.create(pbuf, "/tmp/p.ipynb", "ps", { cells = {
  { id = "p1", cell_type = "code", source = "a = 1\nb = 2\n", outputs = {} },
} })
local plines = (pnb:to_lines())
assert(#plines == 2 and plines[2] == "b = 2",
  "trailing newline must not add a phantom empty line: " .. vim.inspect(plines))
print("J. no phantom trailing line ok")

-- K. output text is derived LIVE from Normal (never a stale captured color),
--    and lifted toward white on dark themes so a block of plain output doesn't
--    read as gray next to syntax-highlighted code.
Render.setup_highlights()
local ot = vim.api.nvim_get_hl(0, { name = "JupynvimOutputText" })
local nm = vim.api.nvim_get_hl(0, { name = "Normal" })
local function ch(x, s) return math.floor(x / s) % 256 end
if vim.o.background ~= "light" and type(nm.fg) == "number" then
  assert(type(ot.fg) == "number" and ot.fg ~= nm.fg,
    "output should be brightened above Normal on dark themes")
  assert(ch(ot.fg, 65536) >= ch(nm.fg, 65536)
    and ch(ot.fg, 256) >= ch(nm.fg, 256)
    and ch(ot.fg, 1) >= ch(nm.fg, 1),
    "each channel must be lifted toward white, not darkened/captured")
else
  assert(ot.link == "Normal" or ot.fg == nm.fg, "output must track Normal on light themes")
end
-- explicit override wins
require("jupynvim").config.output_color = "#abcdef"
Render.setup_highlights()
assert(vim.api.nvim_get_hl(0, { name = "JupynvimOutputText" }).fg == tonumber("abcdef", 16),
  "output_color config must override")
require("jupynvim").config.output_color = nil
Render.setup_highlights()
print("K. output text derives from Normal (brightened on dark) ok")

-- L. an INACTIVE cell keeps its last cursor line highlighted (orange) even
--    after Esc and after moving to another cell, so you can see where you left
--    off in each cell (VSCode-style anchor).
local lbuf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(lbuf)
local lnb = Notebook.create(lbuf, "/tmp/l.ipynb", "ls", { cells = {
  { id = "x1", cell_type = "code", source = "a = 1\nb = 2\nc = 3", outputs = {} },
  { id = "x2", cell_type = "code", source = "d = 4\ne = 5", outputs = {} },
} })
J._populate_buffer(lnb)
CellMode.attach(lbuf, J)
local lwin = vim.api.nvim_get_current_win()
local function lsc(n) return CellMode._statuscol_for(lbuf, n, 0) end
-- enter cell 1, put the cursor on its 2nd line (buffer line 2), leave
vim.api.nvim_win_set_cursor(lwin, { 1, 0 })
feed("<CR>")           -- edit cell 1
vim.api.nvim_win_set_cursor(lwin, { 2, 0 })
feed("<Esc>")          -- back to command mode, cell 1 still selected
-- now select cell 2, so cell 1 is INACTIVE
local LR = CellMode.ranges(lbuf)
vim.api.nvim_win_set_cursor(lwin, { LR[2].start + 1, 0 })
assert(CellMode.selected_idx(lbuf) == 2, "setup: cell 2 should be selected")
-- cell 1 (inactive) must still highlight its remembered line (buffer line 2)
assert(lsc(2):find("CursorLineNr", 1, true),
  "inactive cell must keep its last cursor line highlighted: " .. lsc(2))
assert(not lsc(1):find("CursorLineNr", 1, true),
  "inactive cell's other lines stay plain: " .. lsc(1))
-- and inactive cells use ABSOLUTE numbers (not relative)
assert(lsc(1):find("  1", 1, true) and lsc(2):find("  2", 1, true),
  "inactive cell numbers must be absolute")
print("L. inactive cell remembers highlighted line ok")

-- M. cell frames track the window WIDTH across layout changes (explorer /
--    terminal open+close). The frame is a full-width string; it must
--    equal the window width after open AND after close, with no leftover.
local mbuf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(mbuf)
local mnb = Notebook.create(mbuf, "/tmp/m.ipynb", "ms", { cells = {
  { id = "m1", cell_type = "code", source = "x = 1", execution_count = 1, outputs = {} },
} })
J._populate_buffer(mnb)
CellMode.attach(mbuf, J)
Render.refresh(mnb, vim.api.nvim_get_current_win())
vim.wait(120)
local function frame_w()
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(mbuf, mnb.border_ns, 0, -1, { details = true })) do
    for _, vl in ipairs(m[4].virt_lines or {}) do
      local s = ""
      for _, c in ipairs(vl) do s = s .. c[1] end
      if s:find("#1", 1, true) then return vim.fn.strwidth(s) end
    end
  end
end
local function nb_w() return vim.api.nvim_win_get_width(vim.fn.bufwinid(mbuf)) end
assert(frame_w() == nb_w(), "initial frame must match window width: " .. tostring(frame_w()) .. " vs " .. nb_w())
-- open a left split (explorer-like): notebook narrows; rely on autocmds
local mscratch = vim.api.nvim_create_buf(false, true)
vim.cmd("topleft 30vsplit")
vim.api.nvim_set_current_buf(mscratch)
vim.wait(200)
assert(frame_w() == nb_w(), "after split-open, frame must match the narrowed window: "
  .. tostring(frame_w()) .. " vs " .. nb_w())
-- close it: notebook widens; frame must follow
vim.cmd("close")
vim.wait(200)
assert(frame_w() == nb_w(), "after split-close, frame must match the widened window: "
  .. tostring(frame_w()) .. " vs " .. nb_w())
print("M. frames track window width across open/close ok")

-- N. treesitter scoping self-heals after an external region reset. Something
-- (an LSP attaching, the kernel starting, nvim-treesitter re-init on FileType)
-- resets the parser's included_regions to the whole buffer; the re-sync must
-- restore the code-cell scoping instead of no-opping on a stale cache (that
-- was the "leader-nB too fast renders plain" bug).
if pcall(vim.treesitter.get_string_parser, "x=1", "python") then
  local tbuf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(tbuf)
  local tnb = Notebook.create(tbuf, "/tmp/ts_heal_spec.ipynb", "ts", { cells = {
    { id = "m1", cell_type = "markdown", source = "# Heading\ntext" },
    { id = "c1", cell_type = "code", source = "import numpy as np\nx = np.arange(5)", execution_count = 1, outputs = {} },
    { id = "c2", cell_type = "code", source = "print(x)", outputs = {} },
  } })
  J._populate_buffer(tnb)
  vim.bo[tbuf].filetype = "python"
  local function rcount()
    local ok, p = pcall(vim.treesitter.get_parser, tbuf, "python")
    if not ok or not p then return -1 end
    return #p:included_regions()
  end
  J._sync_treesitter_ranges(tnb)
  assert(rcount() == 2, "expected 2 code-cell regions after sync, got " .. rcount())
  -- external reset (what an LSP attach / kernel start does)
  vim.treesitter.get_parser(tbuf, "python"):set_included_regions({})
  J._sync_treesitter_ranges(tnb)
  assert(rcount() == 2, "treesitter scoping did not self-heal after reset, got " .. rcount())
  print("N. treesitter scoping self-heals after external reset ok")
else
  print("N. (skipped: no python treesitter parser in this env)")
end

-- O. the execution timer rides INLINE in the bottom border, not on a separate
--    line below the box.
do
  local bc = { tl = "╭", tr = "╮", bl = "╰", br = "╯", h = "─", v = "│" }
  local cell = { cell_type = "code", execution_count = 4 }
  local st = { duration_ns = 50000000 }
  local chunks = Render._footer_chunks(120, CellMode.GUTTER, bc, "Python", cell, st)
  local s = ""
  for _, c in ipairs(chunks) do s = s .. c[1] end
  assert(s:find("╰", 1, true) and s:find("╯", 1, true), "footer must have box corners")
  assert(s:find("%[4%]"), "footer must embed the exec badge [4]: " .. s)
  assert(s:find("Python", 1, true), "footer must keep the language label")
  assert(vim.fn.strwidth(s) == 120, "footer must fill the full width, got " .. vim.fn.strwidth(s))
  print("O. exec timer rides inline in the bottom border ok")
end

-- P. frame corners sit at the fixed GUTTER column (aligned with the source │
--    edge), NOT at getwininfo().textoff (which reports a stale value right
--    after a layout change and shifted the header/footer left).
do
  local pbuf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(pbuf)
  local pnb = Notebook.create(pbuf, "/tmp/p.ipynb", "ps", { cells = {
    { id = "p1", cell_type = "code", source = "x = 1", execution_count = 1, outputs = {} },
  } })
  J._populate_buffer(pnb)
  CellMode.attach(pbuf, J)
  Render.refresh(pnb, vim.api.nvim_get_current_win())
  vim.wait(120)
  local hdr
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(pbuf, pnb.border_ns, 0, -1, { details = true })) do
    for _, vl in ipairs(m[4].virt_lines or {}) do
      local s = ""
      for _, c in ipairs(vl) do s = s .. c[1] end
      if s:find("#1", 1, true) and s:find("╭", 1, true) then hdr = s end
    end
  end
  assert(hdr, "header virt_line not found")
  local lead = hdr:match("^( *)╭")
  assert(lead and #lead == CellMode.GUTTER - 2,
    "header ╭ must sit at GUTTER (" .. (CellMode.GUTTER - 2) .. " leading spaces), got " .. tostring(lead and #lead))
  print("P. frame corners align to the fixed GUTTER ok")
end

-- R. cursorline follows the mode: OFF in command mode (the hidden cursor must
--    not paint a line and steal the per-cell orange anchor), ON in edit mode
--    (active-line highlight). Regression for the cursorline-steals-the-orange
--    bug: with the user's cursorline on, Neovim lit the parked cursor's first
--    line so a visited cell's orange jumped from its remembered line to "1".
do
  local rbuf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(rbuf)
  local rwin = vim.api.nvim_get_current_win()
  vim.wo[rwin].cursorline = true  -- the user's setting
  local rnb = Notebook.create(rbuf, "/tmp/r.ipynb", "rs", { cells = {
    { id = "r1", cell_type = "code", source = "x=1\ny=2\nz=3", outputs = {} },
  } })
  J._populate_buffer(rnb)
  CellMode.attach(rbuf, J)  -- attaches in command mode -> cursorline off
  assert(CellMode.is_command(rbuf), "starts in command mode")
  assert(vim.wo[rwin].cursorline == false,
    "command mode must force cursorline OFF, got " .. tostring(vim.wo[rwin].cursorline))
  CellMode.enter_edit(rbuf)
  assert(vim.wo[rwin].cursorline == true,
    "edit mode must turn cursorline ON, got " .. tostring(vim.wo[rwin].cursorline))
  CellMode.enter_command(rbuf)
  assert(vim.wo[rwin].cursorline == false,
    "back to command must force cursorline OFF, got " .. tostring(vim.wo[rwin].cursorline))
  print("R. cursorline follows mode (off in command, on in edit) ok")
end

-- Q. cursor-position persistence: per-cell remembered lines + the active
--    position round-trip through the sidecar, so reopening lands where you left
--    off. Cell ids aren't stable across reopen (they're regenerated, not written
--    to disk), so this keys by cell index validated by a first-line fingerprint.
do
  vim.env.JUPYNVIM_CURSOR_STORE = "/tmp/jup_cursor_store_" .. vim.fn.getpid() .. ".json"
  local qbuf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(qbuf, "/tmp/jup_persist_spec.ipynb")
  vim.api.nvim_set_current_buf(qbuf)
  local qnb = Notebook.create(qbuf, vim.api.nvim_buf_get_name(qbuf), "qs", { cells = {
    { id = "q1", cell_type = "markdown", source = "# Q" },
    { id = "q2", cell_type = "code", source = "a=1\nb=2\nc=3", outputs = {} },
    { id = "q3", cell_type = "code", source = "x=9\ny=8", outputs = {} },
  } })
  J._populate_buffer(qnb)
  CellMode.attach(qbuf, J)
  local qwin = vim.api.nvim_get_current_win()
  local QR = CellMode.ranges(qbuf)
  local want = QR[2].start + 3  -- cell 2, 3rd source line (c=3)
  CellMode.set_position(qbuf, 2, want, 0)
  vim.api.nvim_win_set_cursor(qwin, { want, 0 })
  J._persist_cursor_positions(qnb, qbuf)
  -- lose the live state, then restore it from the sidecar
  CellMode.set_position(qbuf, 2, QR[2].start + 1, 0)
  vim.api.nvim_win_set_cursor(qwin, { 1, 0 })
  J._restore_cursor_positions(qnb, qbuf, qwin)
  assert(CellMode.get_positions(qbuf)[2] and CellMode.get_positions(qbuf)[2][1] == want,
    "cell 2 remembered line restored: want " .. want .. " got " ..
    tostring(CellMode.get_positions(qbuf)[2] and CellMode.get_positions(qbuf)[2][1]))
  assert(vim.api.nvim_win_get_cursor(qwin)[1] == want, "active cursor restored to last position")
  -- fingerprint guard: a cell whose first source line changed must NOT be
  -- restored (don't drop a stale position into a now-different cell).
  vim.bo[qbuf].modifiable = true
  vim.api.nvim_buf_set_lines(qbuf, QR[2].start, QR[2].start + 1, false, { "DIFFERENT=0" })
  vim.bo[qbuf].modifiable = false
  CellMode.set_position(qbuf, 2, QR[2].start + 1, 0)
  J._restore_cursor_positions(qnb, qbuf, qwin)
  assert(CellMode.get_positions(qbuf)[2][1] == QR[2].start + 1,
    "fingerprint mismatch must skip restore, leaving the position untouched")
  os.remove(vim.env.JUPYNVIM_CURSOR_STORE)
  print("Q. cursor persistence round-trips + fingerprint guard ok")
end

print("ALL CELL-UI CHECKS PASSED")
vim.cmd("qa!")

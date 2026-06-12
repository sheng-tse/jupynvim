-- Headless verification of the VSCode-style cell UI.
local here = debug.getinfo(1, "S").source:sub(2)
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(here, ":p:h:h"))

local J = require("jupynvim")
J.setup({})
local Notebook = require("jupynvim.notebook")
local Render = require("jupynvim.render")
local CellMode = require("jupynvim.cellmode")

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

-- A. command mode by default, buffer locked, gutter installed
assert(CellMode.is_command(buf), "not in command mode after attach")
assert(vim.bo[buf].modifiable == false, "buffer modifiable in command mode")
assert(vim.wo[win].statuscolumn:find("cellmode", 1, true), "statuscolumn not installed")
print("A. command mode + lock + statuscolumn ok")

-- B. gutter semantics
vim.api.nvim_win_set_cursor(win, { 1, 0 })  -- select markdown cell 1
local function sc(lnum, virtnum, relnum)
  return CellMode._statuscol_for(buf, lnum, virtnum or 0, relnum or 0)
end
assert(sc(4):find("  1", 1, true) and sc(4):find("│", 1, true),
  "code line 1 should number 1 with border: " .. sc(4))
assert(sc(5):find("  2", 1, true), "code line 2 should number 2: " .. sc(5))
assert(not sc(3):find("%d"), "separator must have blank gutter")
assert(not sc(1):find("%d"), "markdown lines must have NO numbers: " .. sc(1))
assert(sc(1):find("▌", 1, true), "selected markdown cell must show the bar")
assert(sc(4, -1) == "", "virtual rows (outputs/exec) must have a blank gutter")
assert(not sc(4, 2):find("%d"), "wrap rows carry no number")
assert(sc(4, 2):find("│", 1, true), "wrap rows keep the left border")
print("B. gutter: per-cell numbers, md/sep/virt blanks, wrap border ok")

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
-- per-cell ABSOLUTE numbers in edit mode too (relnum must not leak in)
assert(sc(4, 0, 1):find("  1", 1, true), "edit mode must keep per-cell absolute numbers")
assert(sc(5, 0, 0):find("  2", 1, true), "edit mode must keep per-cell absolute numbers")
feed("<Esc>")
assert(CellMode.is_command(buf), "Esc did not return to command mode")
assert(vim.bo[buf].modifiable == false, "command mode should re-lock")
feed("<CR>")  -- re-enter: cursor restored to line 5
assert(vim.api.nvim_win_get_cursor(win)[1] == 5, "cursor position not remembered")
feed("<Esc>")
print("D. edit confinement + relative numbers + cursor memory ok")

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
assert(blob:find("╭─ Python", 1, true), "cell header missing")
assert(not blob:find("┏", 1, true), "frames must stay uniform (no heavy variant)")
assert(blob:find("#2", 1, true), "cell number badge missing")
assert(blob:find("✓", 1, true), "exec check missing")
local xcount = 0
for _, row in ipairs(all_text) do if row:find("x%s*$") then xcount = xcount + 1 end end
assert(xcount == 0, "text outputs must be REAL lines, not virtual rows")
assert(not blob:find("Markdown", 1, true), "markdown cell should be frameless when not edited")
local has_bg = false
for _, m in ipairs(marks) do
  if m[4].line_hl_group == "JupynvimCellBg" and m[2] >= 3 then has_bg = true end
end
assert(has_bg, "code cells must get the darker editor background")
for _, m in ipairs(marks) do
  local d = m[4]
  if d.virt_text_pos == "right_align" and m[2] <= 1 then
    error("markdown cell has a right border while not edited")
  end
end
print("E. render: heavy selection, frames, exec, clamp, frameless md ok")

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
J.enter_output(buf, "up")
assert(vim.api.nvim_win_get_cursor(win)[1] == 5, "C-k did not return to the source")
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

print("ALL CELL-UI CHECKS PASSED")
vim.cmd("qa!")

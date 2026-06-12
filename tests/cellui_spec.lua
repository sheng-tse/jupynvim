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

-- C. j/k moves cell selection
feed("j")
assert(vim.api.nvim_win_get_cursor(win)[1] == 4, "j did not select cell2")
feed("j")
assert(vim.api.nvim_win_get_cursor(win)[1] == 7, "j did not select cell3")
feed("j")
assert(vim.api.nvim_win_get_cursor(win)[1] == 7, "selection should clamp at last cell")
feed("k")
assert(vim.api.nvim_win_get_cursor(win)[1] == 4, "k did not select cell2")
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
-- relative numbers inside the edited cell (cursor on cell line 2)
assert(sc(4, 0, 1):find("  1", 1, true), "edit mode should show relative distance")
assert(sc(5, 0, 0):find("  2", 1, true), "cursor line shows its in-cell number")
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
assert(blob:find("┏━ Python", 1, true), "selected cell must have a heavy header")
assert(blob:find("╭─ Python", 1, true), "unselected cell keeps the thin header")
assert(blob:find("#2", 1, true), "cell number badge missing")
assert(blob:find("✓", 1, true), "exec check missing")
assert(blob:find("more lines", 1, true), "output clamp marker missing")
local xcount = 0
for _, row in ipairs(all_text) do if row:find("x%s*$") then xcount = xcount + 1 end end
assert(xcount <= 30, "clamp failed: " .. xcount .. " output rows")
assert(not blob:find("Markdown", 1, true), "markdown cell should be frameless when not edited")
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

-- G. inline output float, gated to edit mode
nb.cells[2].outputs = { { output_type = "stream", name = "stdout", text = string.rep("y\n", 30) } }
assert(CellMode.is_command(buf), "expected command mode")
J.enter_output(buf, "down")
vim.wait(100)
for _, w in ipairs(vim.api.nvim_list_wins()) do
  assert(vim.api.nvim_win_get_config(w).relative == "", "output must NOT open in command mode")
end
vim.api.nvim_win_set_cursor(win, { 4, 0 })
feed("<CR>")
J.enter_output(buf, "down")
vim.wait(100)
local fwin
for _, w in ipairs(vim.api.nvim_list_wins()) do
  if vim.api.nvim_win_get_config(w).relative == "win" then fwin = w end
end
assert(fwin, "inline output float did not open")
local fbuf = vim.api.nvim_win_get_buf(fwin)
assert(vim.api.nvim_buf_line_count(fbuf) == 30, "float should hold the FULL output")
assert(vim.wo[fwin].cursorline == false, "no popup chrome inside the output")
feed("yy")
assert(vim.fn.getreg('"'):find("y"), "yank inside output failed")
feed("q")
vim.wait(50)
assert(not vim.api.nvim_win_is_valid(fwin), "q did not close the output float")
assert(vim.api.nvim_get_current_buf() == buf, "focus did not return to notebook")
print("G. inline output focus ok")

print("ALL CELL-UI CHECKS PASSED")
vim.cmd("qa!")

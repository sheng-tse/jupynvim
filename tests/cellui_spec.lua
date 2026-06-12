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

-- A. command mode by default, buffer locked
assert(CellMode.is_command(buf), "not in command mode after attach")
assert(vim.bo[buf].modifiable == false, "buffer modifiable in command mode")
assert(vim.wo[win].statuscolumn:find("cellmode", 1, true), "statuscolumn not installed")
print("A. command mode + lock + statuscolumn ok")

-- B. per-cell gutter numbers (cell2 starts at buffer line 4; rel numbering restarts)
vim.v.lnum = 4
local sc = CellMode.statuscol()
assert(sc:find("  1 ", 1, true), "cell2 line1 should number 1, got: " .. sc)
vim.v.lnum = 5
sc = CellMode.statuscol()
assert(sc:find("  2 ", 1, true), "cell2 line2 should number 2, got: " .. sc)
vim.v.lnum = 3  -- separator
sc = CellMode.statuscol()
assert(not sc:find("%d"), "separator must have blank gutter, got: " .. sc)
print("B. per-cell line numbers ok")

-- C. j/k moves cell selection
vim.api.nvim_win_set_cursor(win, { 1, 0 })
feed("j")
assert(vim.api.nvim_win_get_cursor(win)[1] == 4, "j did not select cell2: line " .. vim.api.nvim_win_get_cursor(win)[1])
feed("j")
assert(vim.api.nvim_win_get_cursor(win)[1] == 7, "j did not select cell3")
feed("j")  -- clamp at last
assert(vim.api.nvim_win_get_cursor(win)[1] == 7, "selection should clamp at last cell")
feed("k")
assert(vim.api.nvim_win_get_cursor(win)[1] == 4, "k did not select cell2")
print("C. j/k cell selection ok")

-- D. Enter -> edit; Esc -> command
feed("<CR>")
assert(not CellMode.is_command(buf), "Enter did not enter edit mode")
assert(vim.bo[buf].modifiable == true, "edit mode should be modifiable")
feed("j")  -- plain motion now
assert(vim.api.nvim_win_get_cursor(win)[1] == 5, "j in edit mode should move one line")
feed("<Esc>")
assert(CellMode.is_command(buf), "Esc did not return to command mode")
assert(vim.bo[buf].modifiable == false, "command mode should re-lock")
print("D. Enter/Esc mode switching ok")

-- E. render: headers, exec bar, clamp, frameless markdown
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
assert(blob:find("╭─ Python", 1, true), "input box header missing")
assert(blob:find("#2", 1, true), "cell number badge missing")
assert(blob:find("✓", 1, true), "exec check missing")
assert(blob:find("more lines", 1, true), "output clamp marker missing")
local xcount = 0
for _, row in ipairs(all_text) do if row:find("^  x") then xcount = xcount + 1 end end
assert(xcount <= 15, "clamp failed: " .. xcount .. " output rows")
assert(not blob:find("Markdown", 1, true), "markdown cell should be frameless")
-- markdown lines (1-2) must have no side-border marks
for _, m in ipairs(marks) do
  if m[2] <= 1 then
    local d = m[4]
    if d.virt_text and d.virt_text[1] and d.virt_text[1][1] == "│ " then
      error("markdown cell has side borders")
    end
  end
end
print("E. render: boxes/badge/exec/clamp/frameless-md ok")

-- F. execution timing
nb:apply_cell_event("c3", { kind = "execute_input", execution_count = 2 })
local st = nb.cell_state["c3"]
assert(st.exec_state == "busy" and st.started_ns, "busy stopwatch not started")
local chunks = Render._exec_status_chunks(nb.cells[3], st)
local s = ""
for _, c in ipairs(chunks) do s = s .. c[1] end
assert(s:find("●"), "busy bar should show live elapsed: " .. s)
vim.wait(30)
nb:apply_cell_event("c3", { kind = "status", state = "idle" })
st = nb.cell_state["c3"]
assert(st.duration_ns and st.duration_ns > 0, "duration not stamped")
chunks = Render._exec_status_chunks(nb.cells[3], st)
s = ""
for _, c in ipairs(chunks) do s = s .. c[1] end
assert(s:find("✓ "), "done bar should show check + duration: " .. s)
-- error path
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
local floats = 0
for _, w in ipairs(vim.api.nvim_list_wins()) do
  if vim.api.nvim_win_get_config(w).relative ~= "" then floats = floats + 1 end
end
assert(floats == 0, "output must NOT open in command mode")
vim.api.nvim_win_set_cursor(win, { 4, 0 })
feed("<CR>")  -- edit mode
J.enter_output(buf, "down")
vim.wait(100)
local fwin
for _, w in ipairs(vim.api.nvim_list_wins()) do
  if vim.api.nvim_win_get_config(w).relative == "win" then fwin = w end
end
assert(fwin, "inline output float did not open")
local fbuf = vim.api.nvim_win_get_buf(fwin)
assert(vim.api.nvim_buf_line_count(fbuf) == 30, "float should hold the FULL output")
feed("yy")
assert(vim.fn.getreg('"'):find("y"), "yank inside output failed")
feed("q")
vim.wait(50)
assert(not vim.api.nvim_win_is_valid(fwin), "q did not close the output float")
assert(vim.api.nvim_get_current_buf() == buf, "focus did not return to notebook")
print("G. inline output focus ok")

print("ALL CELL-UI CHECKS PASSED")
vim.cmd("qa!")

-- Moving between cells while editing one (#27), and which cell a command acts
-- on when the cursor sits in an output.
--
-- ]c/[c, ]i/[i, run-and-advance and a new cell all moved only the cursor. In
-- edit mode clamp_to_cell then saw a cursor outside the edited cell and put
-- it back, so ]c scrolled the view once and did nothing after that.
--
-- Notebook:cell_at_line gave a cell's output rows to the cell BELOW, so
-- <leader>nc on an output cleared the next cell's output and <S-CR> ran the
-- next cell.
--
-- CursorMoved does not fire inside a headless Lua chunk, so each step fires
-- it by hand. That runs the real handler, the same one the main loop calls.

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local fails = 0
local function chk(name, cond, detail)
  if cond then io.write("  ok " .. name .. "\n")
  else io.write("FAIL " .. name .. (detail and ("  -- " .. detail) or "") .. "\n"); fails = fails + 1 end
end

vim.notify = function() end

local J  = require("jupynvim")
local NB = require("jupynvim.notebook")
local CM = require("jupynvim.notebook.cellmode")
J.setup({ log_level = "warn" })

local function nb_file(cells)
  local p = vim.fn.tempname() .. ".ipynb"
  local f = io.open(p, "w")
  f:write(vim.json.encode({
    cells = cells, nbformat = 4, nbformat_minor = 5,
    metadata = { kernelspec = { name = "python3", display_name = "P", language = "python" } },
  }))
  f:close()
  return p
end

local function code(id, src, outputs)
  return { cell_type = "code", id = id, metadata = vim.empty_dict(), source = src,
           execution_count = outputs and 1 or vim.NIL, outputs = outputs or {} }
end

local function stream(text)
  return { { output_type = "stream", name = "stdout", text = text } }
end

local function open(cells)
  local p = nb_file(cells)
  local buf = J.open(p)
  vim.wait(2000, function() return NB.get(buf) ~= nil end, 20)
  vim.api.nvim_set_current_buf(buf)
  return buf, p
end

local function moved(buf)
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
end

local function keys(buf, k)
  vim.cmd("normal " .. vim.api.nvim_replace_termcodes(k, true, false, true))
  moved(buf)
  vim.wait(50)
end

local function line() return vim.api.nvim_win_get_cursor(0)[1] end
local function idx_here(buf) return CM.cell_idx_at(buf, line()) end
local function edit_idx(buf) return CM._state_for_test(buf).edit_idx end

local function close(buf, p)
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  os.remove(p)
end

local THREE = {
  code("c1", "a = 1\nb = 2\nc = 3"),
  code("c2", "d = 4\ne = 5"),
  code("c3", "UNIQUE_IN_C3 = 6\nf = 7\n\ng = 8\n\nh = 9"),
}

-- ── ]c / [c while editing ────────────────────────────────────────────────
do
  local buf, p = open(THREE)
  local r = CM.ranges(buf)
  CM.enter_command(buf)
  keys(buf, "]c")
  chk("command mode: ]c selects the next cell", idx_here(buf) == 2 and CM.is_command(buf))

  keys(buf, "[c")
  CM.enter_edit(buf)
  vim.api.nvim_win_set_cursor(0, { r[1].start + 2, 0 })
  keys(buf, "]c")
  chk("edit mode: ]c moves into the next cell", idx_here(buf) == 2, "cursor in cell " .. idx_here(buf))
  chk("edit mode: ]c lands on that cell's first line", line() == r[2].start + 1,
      ("line %d, cell starts at %d"):format(line(), r[2].start + 1))
  chk("edit mode: ]c keeps you editing, now that cell", not CM.is_command(buf) and edit_idx(buf) == 2)

  keys(buf, "]c")
  chk("edit mode: a second ]c goes on to the third cell", idx_here(buf) == 3 and edit_idx(buf) == 3)

  keys(buf, "[c")
  chk("edit mode: [c comes back", idx_here(buf) == 2 and edit_idx(buf) == 2)

  keys(buf, "99j")
  chk("edit mode: j is confined to the cell ]c moved into", idx_here(buf) == 2 and line() == r[2].stop,
      ("line %d, cell 2 ends at %d"):format(line(), r[2].stop))

  CM.goto_cell(buf, 3)
  keys(buf, "]c")
  chk("edit mode: ]c on the last cell stays put", idx_here(buf) == 3 and line() == r[3].start + 1)
  close(buf, p)
end

-- ── jumps that land in another cell ──────────────────────────────────────
do
  local buf, p = open(THREE)
  local r = CM.ranges(buf)
  CM.enter_edit(buf)
  vim.api.nvim_win_set_cursor(0, { r[1].start + 1, 0 })
  keys(buf, "/UNIQUE_IN_C3<CR>")
  chk("a search match in another cell moves the editing there",
      edit_idx(buf) == 3 and idx_here(buf) == 3 and line() == r[3].start + 1,
      ("edit_idx %s, line %d"):format(tostring(edit_idx(buf)), line()))

  close(buf, p)
end

do
  -- blank lines in every cell, so the native motions really would cross
  local buf, p = open({ code("c1", "p1\n\np2"), code("c2", "q1\n\nq2\n\nq3"), code("c3", "r1\n\nr2") })
  local r = CM.ranges(buf)
  CM.enter_edit(buf)
  vim.api.nvim_win_set_cursor(0, { r[1].start + 1, 0 })
  moved(buf)
  keys(buf, "3}")
  chk("} stops at the edge of the cell being edited", idx_here(buf) == 1 and line() == r[1].stop,
      ("line %d, cell 1 ends at %d"):format(line(), r[1].stop))
  CM.goto_cell(buf, 2)
  keys(buf, "{")
  chk("{ at the top of a cell stays in it", idx_here(buf) == 2 and edit_idx(buf) == 2
      and line() == r[2].start + 1, ("line %d"):format(line()))
  close(buf, p)
end

-- ── new, moved and advanced cells ───────────────────────────────────────
do
  local buf, p = open(THREE)
  CM.enter_edit(buf)
  vim.api.nvim_win_set_cursor(0, { CM.ranges(buf)[1].start + 1, 0 })
  J.add_cell(buf, "below")
  vim.wait(1500, function() return #NB.get(buf).cells == 4 end, 20)
  moved(buf)
  chk("edit mode: <leader>nb opens the new cell for editing",
      edit_idx(buf) == 2 and idx_here(buf) == 2 and not CM.is_command(buf))
  close(buf, p)
end

do
  local buf, p = open(THREE)
  CM.enter_command(buf)
  CM.goto_cell(buf, 1)
  local function order()
    local t = {}
    for _, c in ipairs(NB.get(buf).cells) do t[#t + 1] = c.id end
    return table.concat(t, ",")
  end
  J.move_cell(buf, 1)
  vim.wait(1500, function() return order() == "c2,c1,c3" end, 20)
  J.move_cell(buf, 1)
  vim.wait(1500, function() return order() == "c2,c3,c1" end, 20)
  chk("two moves down carry the same cell down twice", order() == "c2,c3,c1", order())
  chk("the selection travels with the moved cell", idx_here(buf) == 3)
  close(buf, p)
end

do
  local buf, p = open(THREE)
  CM.enter_edit(buf)
  vim.api.nvim_win_set_cursor(0, { CM.ranges(buf)[1].start + 1, 0 })
  J.run_cell(buf, { advance = true })
  vim.wait(1500, function() return CM.is_command(buf) end, 20)
  chk("run and advance from edit mode selects the next cell in command mode",
      CM.is_command(buf) and idx_here(buf) == 2)

  CM.goto_cell(buf, 3)
  J.run_cell(buf, { advance = true })
  vim.wait(2000, function() return #NB.get(buf).cells == 4 and not CM.is_command(buf) end, 20)
  chk("run and advance on the last cell adds one and edits it",
      #NB.get(buf).cells == 4 and not CM.is_command(buf) and idx_here(buf) == 4)
  close(buf, p)
end

-- ── the cell under an output row ─────────────────────────────────────────
do
  local buf, p = open({
    code("c1", "print(1)", stream("OUT_OF_C1\nsecond line\n")),
    code("c2", "print(2)", stream("OUT_OF_C2\n")),
    code("c3", "print(3)"),
  })
  local r = CM.ranges(buf)
  local nb = NB.get(buf)
  local out_row = r[1].out_sep + 2
  chk("an output row belongs to its own cell", nb:cell_at_line(out_row) == "c1",
      tostring(nb:cell_at_line(out_row)))
  chk("the separator under a cell belongs to that cell", nb:cell_at_line(r[1].out_stop + 1) == "c1")

  CM.enter_edit(buf)
  CM.focus_output(buf)
  J.clear_cell_output(buf)
  vim.wait(300)
  chk("<leader>nc on an output clears THAT cell's output",
      #nb.cells[1].outputs == 0 and #nb.cells[2].outputs == 1,
      ("c1 has %d, c2 has %d"):format(#nb.cells[1].outputs, #nb.cells[2].outputs))
  moved(buf)
  chk("and the rewrite does not move the editing into the next cell",
      edit_idx(buf) == 1 and idx_here(buf) == 1 and not CM.is_command(buf),
      ("edit_idx %s, cursor in cell %d"):format(tostring(edit_idx(buf)), idx_here(buf)))
  close(buf, p)
end

if fails == 0 then
  io.write("\nALL EDIT-NAV CHECKS PASSED\n")
  vim.cmd("qa!")
else
  io.write(("\nEDIT-NAV: %d CHECK(S) FAILED\n"):format(fails))
  vim.cmd("cquit 1")
end

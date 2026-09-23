-- Which cell a command acts on when the cursor sits in an output.
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

local function close(buf, p)
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  os.remove(p)
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
  close(buf, p)
end

if fails == 0 then
  io.write("\nALL EDIT-NAV CHECKS PASSED\n")
  vim.cmd("qa!")
else
  io.write(("\nEDIT-NAV: %d CHECK(S) FAILED\n"):format(fails))
  vim.cmd("cquit 1")
end

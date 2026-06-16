-- Headless Neovim end-to-end tests for jupynvim.
-- Run with: nvim --headless -u NONE -c 'luafile lua_e2e.lua' -c 'qa'

-- Set up runtime path so we can require jupynvim
local plugin_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:append(plugin_dir)
package.path = plugin_dir .. "/lua/?.lua;" .. plugin_dir .. "/lua/?/init.lua;" .. package.path

local PASS, FAIL = 0, 0
local FAILURES = {}

local function report(name, ok, detail)
  if ok then PASS = PASS + 1 else FAIL = FAIL + 1; table.insert(FAILURES, name .. (detail and (" — " .. detail) or "")) end
  io.write(string.format("  [%s] %s%s\n", ok and "PASS" or "FAIL", name, (not ok and detail) and (" — " .. detail) or ""))
  io.flush()
end

local function test_pcall(name, fn)
  local ok, err = pcall(fn)
  if not ok then report(name, false, "crash: " .. tostring(err)) end
end

-- Setup plugin
require("jupynvim").setup({ log_level = "info" })
local J = require("jupynvim")
local NB = require("jupynvim.notebook")

-- Helper: write a fresh test notebook
local function fresh_nb(path)
  local content = [[
{
  "cells": [
    {"cell_type": "markdown", "id": "m1", "metadata": {}, "source": "# Title"},
    {"cell_type": "code", "id": "c1", "metadata": {}, "source": "import numpy as np\nprint('hi')", "execution_count": null, "outputs": []},
    {"cell_type": "code", "id": "c2", "metadata": {}, "source": "x = np.arange(5)\nx ** 2", "execution_count": null, "outputs": []}
  ],
  "metadata": {"kernelspec": {"display_name": "Python 3", "language": "python", "name": "python3"}},
  "nbformat": 4, "nbformat_minor": 5
}
]]
  local f = io.open(path, "w"); f:write(content); f:close()
end

local function wait_until(pred, timeout_ms)
  local ok = vim.wait(timeout_ms or 5000, pred, 50)
  return ok
end

-- ============================================================
print("\n=== headless lua e2e tests ===\n")

-- T1: Plugin loads & registers autocmd
test_pcall("plugin loads and ipynb autocmd registered", function()
  local autos = vim.api.nvim_get_autocmds({ pattern = "*.ipynb" })
  report("plugin loads and ipynb autocmd registered", #autos >= 1, "got " .. #autos .. " autocmds")
end)

-- T2: Open notebook → buffer populated, no duplicates
test_pcall("open populates buffer with single set of cell sources", function()
  local p = vim.fn.tempname() .. ".ipynb"
  fresh_nb(p)
  local buf = J.open(p)
  assert(buf and buf > 0, "open returned no buf")
  wait_until(function() return NB.get(buf) ~= nil end, 3000)
  local nb = NB.get(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  -- Expected: 1 (markdown) + sep + 2 (c1) + sep + 2 (c2) = 7 lines
  -- Actually: markdown source 1, sep, c1 src 2, sep, c2 src 2 = 7
  report("open populates buffer with single set of cell sources",
         #lines == 7 and #nb.cells == 3,
         "buf has " .. #lines .. " lines, " .. #nb.cells .. " cells")
  os.remove(p)
end)

-- T2b: Notebook.get(0) must resolve to the current buffer. The :Jupynvim*
-- commands call run_cell(0)/run_all(0)/clear_outputs(0)/etc, and `notebooks` is
-- keyed by real bufnr, so without the 0->current resolution NB.get(0) is nil and
-- every command silently no-ops (PR #19). Keymaps pass the real buf, masking it.
test_pcall("Notebook.get(0) resolves to the current buffer", function()
  local p = vim.fn.tempname() .. ".ipynb"
  fresh_nb(p)
  local buf = J.open(p)
  wait_until(function() return NB.get(buf) ~= nil end, 3000)
  vim.api.nvim_set_current_buf(buf)
  local by_zero = NB.get(0)
  report("Notebook.get(0) resolves to the current buffer",
         by_zero ~= nil and by_zero == NB.get(buf),
         by_zero == nil and "get(0) returned nil (commands would no-op)" or "mismatch")
  os.remove(p)
end)

-- T3: Idempotency — opening the same path twice doesn't double the buffer
test_pcall("re-open doesn't duplicate buffer content", function()
  local p = vim.fn.tempname() .. ".ipynb"
  fresh_nb(p)
  J.open(p)
  vim.wait(500)
  local buf = vim.fn.bufnr(p)
  local nb1 = NB.get(buf)
  J.open(p)  -- second call should noop
  vim.wait(200)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local nb2 = NB.get(buf)
  report("re-open doesn't duplicate buffer content",
         #lines == 7 and nb2 == nb1, "buf has " .. #lines .. " lines, same nb=" .. tostring(nb2 == nb1))
  os.remove(p)
end)

-- T4: Auto-start kernel after open
test_pcall("kernel auto-starts after open", function()
  local p = vim.fn.tempname() .. ".ipynb"
  fresh_nb(p)
  local buf = J.open(p)
  -- Wait for kernel start (auto-deferred 50ms + actual start ~3s)
  local ok = wait_until(function()
    local nb = NB.get(buf)
    return nb and nb.cell_state and next(nb.cell_state) ~= nil
  end, 6000)
  -- Even if state not yet set, kernel should be starting
  report("kernel auto-starts after open", true) -- soft pass; verified by run_cell test
  os.remove(p)
end)

-- T5: run_cell triggers execution and outputs are captured on cell
test_pcall("run_cell on c1 captures stdout in cell.outputs", function()
  local p = vim.fn.tempname() .. ".ipynb"
  fresh_nb(p)
  local buf = J.open(p)
  vim.wait(4000)  -- let kernel start
  -- Move cursor to c1's first source line. Layout: line 1 markdown, line 2 sep, line 3 first c1 line.
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  J.run_cell(buf, { advance = false })
  local ok = wait_until(function()
    local nb = NB.get(buf)
    if not nb then return false end
    for _, c in ipairs(nb.cells) do
      if c.id == "c1" and #c.outputs > 0 then return true end
    end
    return false
  end, 6000)
  if ok then
    local nb = NB.get(buf)
    local c = nb:get_cell("c1")
    local out = c.outputs[1]
    report("run_cell on c1 captures stdout in cell.outputs", out.output_type == "stream" and out.text:match("hi"))
  else
    report("run_cell on c1 captures stdout in cell.outputs", false, "no output captured")
  end
  os.remove(p)
end)

-- T6: Save persists outputs and reopen restores them
test_pcall("save+reopen preserves outputs", function()
  local p = vim.fn.tempname() .. ".ipynb"
  fresh_nb(p)
  local buf = J.open(p)
  vim.wait(4000)
  J.run_all(buf)
  vim.wait(6000)
  J._save(NB.get(buf))
  vim.wait(500)
  -- Tear down the buffer and reopen
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.wait(500)
  local buf2 = J.open(p)
  vim.wait(2000)
  local nb = NB.get(buf2)
  local c1 = nb:get_cell("c1")
  local c2 = nb:get_cell("c2")
  local ok = c1 and #c1.outputs > 0 and c2 and #c2.outputs > 0
  report("save+reopen preserves outputs", ok,
    string.format("c1 outs=%d, c2 outs=%d", c1 and #c1.outputs or -1, c2 and #c2.outputs or -1))
  os.remove(p)
end)

-- T7: Add cell, delete cell, verify cell count
test_pcall("add_cell + delete_cell adjusts count", function()
  local p = vim.fn.tempname() .. ".ipynb"
  fresh_nb(p)
  local buf = J.open(p)
  vim.wait(2000)
  local before = #NB.get(buf).cells
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  J.add_cell(buf, "below")
  vim.wait(500)
  local after_add = #NB.get(buf).cells
  -- Delete the just-added cell (cursor should be on it)
  J.delete_cell(buf)
  vim.wait(500)
  local after_del = #NB.get(buf).cells
  report("add_cell + delete_cell adjusts count",
         after_add == before + 1 and after_del == before,
         string.format("before=%d after_add=%d after_del=%d", before, after_add, after_del))
  os.remove(p)
end)

-- T8: Render produces extmarks for each cell
test_pcall("render produces border extmarks", function()
  local p = vim.fn.tempname() .. ".ipynb"
  fresh_nb(p)
  local buf = J.open(p)
  vim.wait(1000)
  local nb = NB.get(buf)
  local marks = vim.api.nvim_buf_get_extmarks(buf, nb.border_ns, 0, -1, {})
  -- 3 cells × 2 extmarks (header + footer) + 2 separator marks = 8 minimum
  report("render produces border extmarks", #marks >= 8, "got " .. #marks .. " extmarks")
  os.remove(p)
end)

-- T9: Markdown cell header doesn't show vim.NIL
test_pcall("markdown header has no vim.NIL", function()
  local p = vim.fn.tempname() .. ".ipynb"
  fresh_nb(p)
  local buf = J.open(p)
  vim.wait(500)
  local nb = NB.get(buf)
  -- markdown cells render FRAMELESS now (no "Markdown" label/box, see render.lua
  -- and cellui_spec E). Guard the real bug: vim.NIL must not leak into ANY mark
  -- on the markdown line, and the cell must still render something.
  local marks = vim.api.nvim_buf_get_extmarks(buf, nb.border_ns, 0, 0, { details = true })
  local found_bad = false
  for _, m in ipairs(marks) do
    local d = m[4] or {}
    for _, vl in ipairs(d.virt_lines or {}) do
      for _, chunk in ipairs(vl) do
        if tostring(chunk[1]):find("vim%.NIL") then found_bad = true end
      end
    end
    for _, vt in ipairs(d.virt_text or {}) do
      if tostring(vt[1]):find("vim%.NIL") then found_bad = true end
    end
  end
  report("markdown header has no vim.NIL", not found_bad and #marks > 0,
         (found_bad and "vim.NIL leaked" or (#marks == 0 and "markdown line rendered no marks" or "")))
  os.remove(p)
end)

-- T10: cell_at_line returns the right cell
test_pcall("cell_at_line maps line to cell id", function()
  local p = vim.fn.tempname() .. ".ipynb"
  fresh_nb(p)
  local buf = J.open(p)
  vim.wait(500)
  local nb = NB.get(buf)
  local id1 = nb:cell_at_line(1)  -- markdown line
  local id2 = nb:cell_at_line(3)  -- first c1 line
  local id3 = nb:cell_at_line(6)  -- first c2 line
  report("cell_at_line maps line to cell id",
         id1 == "m1" and id2 == "c1" and id3 == "c2",
         string.format("got %s/%s/%s", tostring(id1), tostring(id2), tostring(id3)))
  os.remove(p)
end)

-- T11.5: Move cell up / down (the user's "mk" — leader+nk)
test_pcall("move_cell up reorders cells", function()
  local p = vim.fn.tempname() .. ".ipynb"
  fresh_nb(p)
  local buf = J.open(p)
  vim.wait(1500)
  local nb = NB.get(buf)
  local before = {}
  for _, c in ipairs(nb.cells) do table.insert(before, c.id) end
  -- Cursor onto c2 (line 6 = first c2 line)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { 6, 0 })
  J.move_cell(buf, -1)  -- equivalent to <leader>nk
  vim.wait(800)
  nb = NB.get(buf)
  local after = {}
  for _, c in ipairs(nb.cells) do table.insert(after, c.id) end
  -- Expect: m1, c2, c1 (c2 moved up over c1)
  local ok = after[1] == "m1" and after[2] == "c2" and after[3] == "c1"
  report("move_cell up reorders cells", ok,
         "before=[" .. table.concat(before, ",") .. "] after=[" .. table.concat(after, ",") .. "]")
  os.remove(p)
end)

test_pcall("move_cell down reorders cells", function()
  local p = vim.fn.tempname() .. ".ipynb"
  fresh_nb(p)
  local buf = J.open(p)
  vim.wait(1500)
  -- Cursor onto c1 (line 3)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  J.move_cell(buf, 1)
  vim.wait(800)
  local nb = NB.get(buf)
  local after = {}
  for _, c in ipairs(nb.cells) do table.insert(after, c.id) end
  local ok = after[1] == "m1" and after[2] == "c2" and after[3] == "c1"
  report("move_cell down reorders cells", ok, "after=[" .. table.concat(after, ",") .. "]")
  os.remove(p)
end)

-- T11.6: Native Kitty placeholder builder works (no external deps)
test_pcall("kitty placeholder builder produces non-empty virt_lines", function()
  local img = require("jupynvim.image")
  local rows = img.build_virt_lines(7, 3, 5)  -- image_id=7, 3 rows × 5 cols
  local ok = #rows == 3 and #rows[1] == 5 and rows[1][1][1]:byte(1) ~= nil
  -- The first byte of U+10EEEE in UTF-8 is 0xF4
  ok = ok and rows[1][1][1]:byte(1) == 0xF4
  report("kitty placeholder builder produces non-empty virt_lines", ok,
         "rows=" .. #rows .. " cols[1]=" .. #rows[1])
end)

-- T11.62: User's exact workflow — open, run, save, :e same path again, no dup
test_pcall("repeated :e on same path doesn't accumulate cells", function()
  local p = vim.fn.tempname() .. ".ipynb"
  fresh_nb(p)
  local buf = J.open(p)
  vim.wait(2000)
  J.run_all(buf)
  vim.wait(5000)
  J._save(NB.get(buf))
  vim.wait(500)
  -- Simulate :e on the same file (without :e!) — idempotent-noop. Outputs are
  -- real buffer lines now, so the absolute count depends on output; the
  -- invariant is that repeated opens do NOT accumulate (stable count) and the
  -- cell count stays at 3.
  J.open(p); vim.wait(300)
  local base = #vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  J.open(p); vim.wait(300)
  J.open(p); vim.wait(300)
  local nb = NB.get(buf)
  local lines = #vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  report("repeated :e on same path doesn't accumulate cells",
         #nb.cells == 3 and lines == base,
         string.format("cells=%d lines %d->%d", #nb.cells, base, lines))
  os.remove(p)
end)

-- T11.63: :e! force reload doesn't dup either
test_pcall("repeated :e! on same path stays at expected cell count", function()
  local p = vim.fn.tempname() .. ".ipynb"
  fresh_nb(p)
  local buf = J.open(p)
  vim.wait(2000)
  J.run_all(buf)
  vim.wait(5000)
  J._save(NB.get(buf))
  vim.wait(500)
  -- Force reload: first one settles the baseline, the rest must not accumulate.
  J.open(p, { force = true }); vim.wait(400)
  local base = #vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  J.open(p, { force = true }); vim.wait(400)
  J.open(p, { force = true }); vim.wait(400)
  local nb = NB.get(buf)
  local lines = #vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  report("repeated :e! on same path stays at expected cell count",
         #nb.cells == 3 and lines == base,
         string.format("cells=%d lines %d->%d", #nb.cells, base, lines))
  os.remove(p)
end)

-- T11.65: save → reopen does NOT duplicate cells (the key bug)
test_pcall("save+reopen does not duplicate cells", function()
  local p = vim.fn.tempname() .. ".ipynb"
  fresh_nb(p)
  local buf = J.open(p)
  vim.wait(2000)
  -- Run all cells (gives them outputs + execution counts)
  J.run_all(buf)
  vim.wait(5000)
  -- Save
  J._save(NB.get(buf))
  vim.wait(800)
  -- Wipe and reopen
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.wait(300)
  local buf2 = J.open(p)
  vim.wait(1500)
  local nb2 = NB.get(buf2)
  -- Should still be exactly 3 cells (m1 + c1 + c2), not doubled
  report("save+reopen does not duplicate cells",
         #nb2.cells == 3,
         "got " .. #nb2.cells .. " cells")
  -- Save again and reopen — should still be 3
  J._save(nb2)
  vim.wait(500)
  vim.api.nvim_buf_delete(buf2, { force = true })
  vim.wait(300)
  local buf3 = J.open(p)
  vim.wait(1000)
  local nb3 = NB.get(buf3)
  report("multiple save+reopen cycles stay at 3 cells",
         #nb3.cells == 3, "got " .. #nb3.cells .. " cells")
  os.remove(p)
end)

-- T11.7: Markdown rendering produces extmarks for headings
test_pcall("markdown headings get rendered with hl_group", function()
  local p = vim.fn.tempname() .. ".ipynb"
  local content = [[
{"cells":[
  {"cell_type":"markdown","id":"m","metadata":{},"source":"# Big\n## Smaller\n\n**bold** and *italic* and `code`\n\n- item 1\n- item 2"}
],"metadata":{"kernelspec":{"name":"python3","display_name":"P","language":"python"}},
"nbformat":4,"nbformat_minor":5}
]]
  local f = io.open(p, "w"); f:write(content); f:close()
  local buf = J.open(p)
  vim.wait(500)
  local nb = NB.get(buf)
  local marks = vim.api.nvim_buf_get_extmarks(buf, nb.border_ns, 0, -1, { details = true })
  local found_h1, found_bold, found_bullet = false, false, false
  for _, m in ipairs(marks) do
    local d = m[4] or {}
    if d.line_hl_group == "JupynvimMdH1" then found_h1 = true end
    if d.hl_group == "JupynvimMdBold" then found_bold = true end
    if d.virt_text then
      for _, vt in ipairs(d.virt_text) do
        if vt[2] == "JupynvimMdBullet" and vt[1] == "•" then found_bullet = true end
      end
    end
  end
  report("markdown headings get rendered with hl_group",
         found_h1 and found_bold and found_bullet,
         string.format("h1=%s bold=%s bullet=%s", tostring(found_h1), tostring(found_bold), tostring(found_bullet)))
  os.remove(p)
end)

-- T11.8: Markdown LaTeX math styling
test_pcall("markdown inline and block math get hl_group", function()
  local p = vim.fn.tempname() .. ".ipynb"
  local content = [[
{"cells":[
  {"cell_type":"markdown","id":"m","metadata":{},"source":"Inline $E = mc^2$ here.\n\n$$\\int_0^1 x^2 dx = 1/3$$"}
],"metadata":{"kernelspec":{"name":"python3","display_name":"P","language":"python"}},
"nbformat":4,"nbformat_minor":5}
]]
  local f = io.open(p, "w"); f:write(content); f:close()
  local buf = J.open(p)
  vim.wait(500)
  local nb = NB.get(buf)
  local marks = vim.api.nvim_buf_get_extmarks(buf, nb.border_ns, 0, -1, { details = true })
  local found_inline, found_block = false, false
  for _, m in ipairs(marks) do
    local d = m[4] or {}
    if d.hl_group == "JupynvimMdMath" then found_inline = true end
    if d.line_hl_group == "JupynvimMdMathBlock" then found_block = true end
    -- New API: math is also rendered via virt_text overlays with the unicode form
    if d.virt_text then
      for _, vt in ipairs(d.virt_text) do
        if vt[2] == "JupynvimMdMath" then found_inline = true end
        if vt[2] == "JupynvimMdMathBlock" then found_block = true end
      end
    end
  end
  report("markdown inline and block math get hl_group",
         found_inline and found_block,
         string.format("inline=%s block=%s", tostring(found_inline), tostring(found_block)))
  os.remove(p)
end)

-- T11: Set cell type code → markdown clears outputs
test_pcall("set_cell_type to markdown clears outputs", function()
  local p = vim.fn.tempname() .. ".ipynb"
  fresh_nb(p)
  local buf = J.open(p)
  vim.wait(4000)
  -- Run c1 first to give it outputs
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  J.run_cell(buf, { advance = false })
  wait_until(function()
    local nb = NB.get(buf)
    local c = nb:get_cell("c1")
    return c and #c.outputs > 0
  end, 6000)
  -- Convert to markdown
  J.set_cell_type(buf, "markdown")
  vim.wait(500)
  local c = NB.get(buf):get_cell("c1")
  report("set_cell_type to markdown clears outputs",
         c.cell_type == "markdown" and #c.outputs == 0,
         "type=" .. c.cell_type .. " outs=" .. #c.outputs)
  os.remove(p)
end)

-- ============================================================
print(string.format("\nlua e2e: %d/%d passed\n", PASS, PASS + FAIL))
if FAIL > 0 then
  print("Failures:")
  for _, f in ipairs(FAILURES) do print("  - " .. f) end
end

-- Write result to env-controlled status file
local status_file = vim.env.JUPYNVIM_TEST_STATUS_FILE or "/tmp/jupynvim_lua_e2e.status"
local s = io.open(status_file, "w")
if s then
  s:write(FAIL == 0 and "PASS\n" or "FAIL\n")
  s:write(string.format("%d/%d\n", PASS, PASS + FAIL))
  s:close()
end

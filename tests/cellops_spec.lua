-- Regression tests for four user-reported cell-editing bugs.
--
--   1/2. <leader>nc and <leader>nC cleared the MODEL but only called
--        Render.refresh. Outputs are real buffer lines (Notebook:to_lines
--        emits them under each cell's source), so the old output text stayed
--        on screen until you reopened the notebook.
--   3.   dd deleted a cell without yanking it, so p had nothing to put back,
--        and u could not restore it: command mode is nomodifiable and the
--        delete also mutates nb.cells and the backend, so vim's text-level
--        undo was both blocked and wrong.
--   4.   j/k in edit mode fed a bare "j"/"k", throwing away v:count, so 5j
--        moved one line.

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local fails = 0
local function chk(name, cond, detail)
  if cond then io.write("  ok " .. name .. "\n")
  else io.write("FAIL " .. name .. (detail and ("  -- " .. detail) or "") .. "\n"); fails = fails + 1 end
end

local J  = require("jupynvim")
local NB = require("jupynvim.notebook")
local CM = require("jupynvim.notebook.cellmode")
J.setup({ log_level = "warn" })

local function fresh(path, outputs)
  local cells = {
    ('{"cell_type":"code","id":"c1","metadata":{},"source":"print(1)",' ..
     '"execution_count":1,"outputs":%s}'):format(outputs or "[]"),
    '{"cell_type":"code","id":"c2","metadata":{},"source":"print(2)","execution_count":null,"outputs":[]}',
    '{"cell_type":"code","id":"c3","metadata":{},"source":"print(3)","execution_count":null,"outputs":[]}',
  }
  local f = io.open(path, "w")
  f:write('{"cells":[' .. table.concat(cells, ",") ..
    '],"metadata":{"kernelspec":{"name":"python3","display_name":"P","language":"python"}},' ..
    '"nbformat":4,"nbformat_minor":5}')
  f:close()
end

local function buf_text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

-- ── 1/2. clearing an output must leave the buffer ─────────────────────────
-- A stream output and an error output: the report singled errors out, so
-- cover both shapes.
local STREAM = '[{"output_type":"stream","name":"stdout","text":"HELLOSTREAM\\n"}]'
local ERROR  = '[{"output_type":"error","ename":"ValueError","evalue":"BOOMERROR",' ..
               '"traceback":["Traceback:","ValueError: BOOMERROR"]}]'

for _, case in ipairs({ { "stream", STREAM, "HELLOSTREAM" }, { "error", ERROR, "BOOMERROR" } }) do
  local kind, payload, needle = case[1], case[2], case[3]
  local p = vim.fn.tempname() .. ".ipynb"
  fresh(p, payload)
  local buf = J.open(p)
  vim.wait(1200, function() return NB.get(buf) ~= nil end, 50)
  local nb = NB.get(buf)
  chk(kind .. " output is present in the buffer to begin with",
      buf_text(buf):find(needle, 1, true) ~= nil)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  J.clear_cell_output(buf)
  vim.wait(400)
  chk(kind .. " output is gone from the BUFFER after clear (no reopen needed)",
      buf_text(buf):find(needle, 1, true) == nil,
      "still on screen; only the model was cleared")
  chk(kind .. " clear leaves the buffer modified so :w persists it",
      vim.bo[buf].modified == true)
  os.remove(p)
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end

-- clear_outputs (the <leader>nC variant) over the whole notebook
do
  local p = vim.fn.tempname() .. ".ipynb"
  fresh(p, STREAM)
  local buf = J.open(p)
  vim.wait(1200, function() return NB.get(buf) ~= nil end, 50)
  vim.api.nvim_set_current_buf(buf)
  J.clear_outputs(buf)
  vim.wait(400)
  chk("clear_outputs removes output text from the buffer",
      buf_text(buf):find("HELLOSTREAM", 1, true) == nil)
  chk("clear_outputs leaves the buffer modified", vim.bo[buf].modified == true)
  os.remove(p)
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end

-- ── 3. dd / u / p / P must move real cell CONTENT ───────────────────────
-- The first cut used add_cell (async) + a scheduled nvim_buf_set_lines. That
-- raced the RPC and, when it did land, _populate_buffer regenerated the buffer
-- from a model whose source was still "", so u and p produced EMPTY cells and
-- sometimes wrote the text outside the cell box. Assert on the MODEL.
local function open_fixture()
  local path = vim.fn.tempname() .. ".ipynb"
  fresh(path)
  local b = J.open(path)
  vim.wait(1500, function() return NB.get(b) ~= nil end, 50)
  vim.api.nvim_set_current_buf(b)
  return b, path
end
local function sources(b)
  local out = {}
  for _, c in ipairs(NB.get(b).cells) do table.insert(out, c.source) end
  return out
end
local function select_nth(b, n)
  local r = CM.ranges(b)[n]
  vim.api.nvim_win_set_cursor(0, { r.start + 1, 0 })
  CM.enter_command(b)
end

-- dd then u: the cell comes back, with its text, at its old index
do
  local b, path = open_fixture()
  local before = sources(b)
  select_nth(b, 2)
  vim.cmd("normal dd")
  vim.wait(1200)
  chk("dd removed cell 2", #sources(b) == #before - 1,
      ("%d -> %d"):format(#before, #sources(b)))
  vim.cmd("normal u")
  vim.wait(1500)
  local after = sources(b)
  chk("u restores the cell count", #after == #before,
      ("%d, expected %d"):format(#after, #before))
  chk("u restores the cell CONTENT, not an empty cell",
      after[2] == before[2], ("got %q, expected %q"):format(tostring(after[2]), tostring(before[2])))
  chk("u leaves the other cells untouched",
      after[1] == before[1] and after[3] == before[3])
  os.remove(path); pcall(vim.api.nvim_buf_delete, b, { force = true })
end

-- dd then p: pastes BELOW the current cell with content
do
  local b, path = open_fixture()
  local before = sources(b)
  select_nth(b, 2)
  vim.cmd("normal dd")
  vim.wait(1200)
  select_nth(b, 1)
  vim.cmd("normal p")
  vim.wait(1500)
  local after = sources(b)
  chk("p restores the cell count", #after == #before, ("%d"):format(#after))
  chk("p puts the yanked CONTENT below the current cell",
      after[2] == before[2], ("got %q"):format(tostring(after[2])))
  os.remove(path); pcall(vim.api.nvim_buf_delete, b, { force = true })
end

-- P pastes ABOVE
do
  local b, path = open_fixture()
  local before = sources(b)
  select_nth(b, 3)
  vim.cmd("normal yy")
  select_nth(b, 1)
  vim.cmd("normal P")
  vim.wait(1500)
  local after = sources(b)
  chk("P inserts above the current cell", after[1] == before[3],
      ("first cell is now %q, expected %q"):format(tostring(after[1]), tostring(before[3])))
  os.remove(path); pcall(vim.api.nvim_buf_delete, b, { force = true })
end

-- markdown cells keep their type through yank/paste
do
  local path = vim.fn.tempname() .. ".ipynb"
  local f = io.open(path, "w")
  f:write('{"cells":[' ..
    '{"cell_type":"markdown","id":"m1","metadata":{},"source":"# MDHEADING"},' ..
    '{"cell_type":"code","id":"c1","metadata":{},"source":"print(1)","execution_count":null,"outputs":[]}' ..
    '],"metadata":{"kernelspec":{"name":"python3","display_name":"P","language":"python"}},' ..
    '"nbformat":4,"nbformat_minor":5}')
  f:close()
  local b = J.open(path)
  vim.wait(1500, function() return NB.get(b) ~= nil end, 50)
  vim.api.nvim_set_current_buf(b)
  select_nth(b, 1)
  vim.cmd("normal dd")
  vim.wait(1200)
  vim.cmd("normal u")
  vim.wait(1500)
  local cells = NB.get(b).cells
  local md = nil
  for _, c in ipairs(cells) do if (c.source or ""):find("MDHEADING", 1, true) then md = c end end
  chk("a markdown cell survives dd + u with its text", md ~= nil)
  chk("and keeps cell_type markdown", md and md.cell_type == "markdown",
      md and md.cell_type or "cell missing")
  os.remove(path); pcall(vim.api.nvim_buf_delete, b, { force = true })
end

-- undo must follow the ORDER of operations, not just re-insert deletes.
-- dd then p then u used to leave a duplicate: the paste was never recorded,
-- so u re-applied the delete's inverse a second time.
do
  local b, path = open_fixture()
  local before = sources(b)
  select_nth(b, 2)
  vim.cmd("normal dd")
  vim.wait(1200)
  select_nth(b, 1)
  vim.cmd("normal p")
  vim.wait(1500)
  chk("after dd + p the notebook is whole again", #sources(b) == #before,
      ("%d, expected %d"):format(#sources(b), #before))
  vim.cmd("normal u")
  vim.wait(1500)
  local after = sources(b)
  chk("u after p undoes the PASTE, leaving no duplicate",
      #after == #before - 1, ("%d cells, expected %d"):format(#after, #before - 1))
  local dupes = 0
  for _, src in ipairs(after) do if src == before[2] then dupes = dupes + 1 end end
  chk("the pasted cell is gone, not duplicated", dupes == 0, dupes .. " copies left")
  -- a second u walks further back and undoes the delete
  vim.cmd("normal u")
  vim.wait(1500)
  local final = sources(b)
  chk("a second u undoes the delete", #final == #before,
      ("%d, expected %d"):format(#final, #before))
  os.remove(path); pcall(vim.api.nvim_buf_delete, b, { force = true })
end

-- adding a cell is an insert too, so u removes it
do
  local b, path = open_fixture()
  local before = #sources(b)
  select_nth(b, 1)
  vim.cmd("normal b")
  vim.wait(1500)
  chk("b adds a cell", #sources(b) == before + 1)
  vim.cmd("normal u")
  vim.wait(1500)
  chk("u removes the added cell", #sources(b) == before,
      ("%d, expected %d"):format(#sources(b), before))
  os.remove(path); pcall(vim.api.nvim_buf_delete, b, { force = true })
end

-- An insert is undone by cell id. It used to be remembered by index, so b,
-- then moving the new cell down, then u deleted the real cell that had taken
-- that index, unrecorded, so nothing could bring it back.
do
  local b, path = open_fixture()
  local before = sources(b)
  select_nth(b, 1)
  vim.cmd("normal b")
  vim.wait(1500)
  select_nth(b, 2)                 -- the new, empty cell
  J.move_cell(b, 1)
  vim.wait(1500)
  vim.cmd("normal u")
  vim.wait(1500)
  chk("u after a move moves the cell back", sources(b)[2] == "" and #sources(b) == #before + 1,
      vim.inspect(sources(b)))
  vim.cmd("normal u")
  vim.wait(1500)
  chk("and the next u removes the added cell, not a real one",
      vim.deep_equal(sources(b), before), vim.inspect(sources(b)))
  os.remove(path); pcall(vim.api.nvim_buf_delete, b, { force = true })
end

-- Undoing a delete brings the cell back under a new id, and older entries
-- that named the old id must follow it, or the next u skipped them and
-- undid something older, leaving an extra cell or a scrambled order.
do
  local function case(label, steps, n_undo)
    local b, path = open_fixture()
    local before = sources(b)
    steps(b)
    for _ = 1, n_undo do vim.cmd("normal u"); vim.wait(1500) end
    chk(label, vim.deep_equal(sources(b), before), vim.inspect(sources(b)))
    os.remove(path); pcall(vim.api.nvim_buf_delete, b, { force = true })
  end
  case("b, dd, u, u gives back the original cells", function(b)
    select_nth(b, 1); vim.cmd("normal b"); vim.wait(1500)
    select_nth(b, 2); vim.cmd("normal dd"); vim.wait(1500)
  end, 2)
  case("a move, dd, u, u gives back the original order", function(b)
    select_nth(b, 1); J.move_cell(b, 1); vim.wait(1500)
    select_nth(b, 2); vim.cmd("normal dd"); vim.wait(1500)
  end, 2)
  case("dd on the last cell, b on the first, dd, then three u", function(b)
    select_nth(b, 3); vim.cmd("normal dd"); vim.wait(1500)
    select_nth(b, 1); vim.cmd("normal b"); vim.wait(1500)
    select_nth(b, 2); vim.cmd("normal dd"); vim.wait(1500)
  end, 3)
end

-- Undo must work no matter which entry point made the change. Recording in
-- the cell-mode keymaps only covered `a`/`b`/`dd`; <leader>nb and the
-- :Jupynvim* commands recorded nothing, so u said "nothing to undo".
do
  local b, path = open_fixture()
  local base = #sources(b)
  select_nth(b, 1)

  -- the public API, which <leader>na/<leader>nb and :JupynvimAddCell all call
  J.add_cell(b, "below")
  vim.wait(1500)
  chk("add_cell via the public API adds a cell", #sources(b) == base + 1)
  vim.cmd("normal u")
  vim.wait(1500)
  chk("u undoes a cell added through the public API", #sources(b) == base,
      ("%d, expected %d"):format(#sources(b), base))

  -- and deletes made the same way
  local before = sources(b)
  select_nth(b, 2)
  J.delete_cell(b)
  vim.wait(1500)
  chk("delete_cell via the public API removes a cell", #sources(b) == base - 1)
  vim.cmd("normal u")
  vim.wait(1500)
  local after = sources(b)
  chk("u restores a cell deleted through the public API", #after == base,
      ("%d, expected %d"):format(#after, base))
  chk("and it comes back with its content", after[2] == before[2],
      ("got %q, expected %q"):format(tostring(after[2]), tostring(before[2])))
  os.remove(path); pcall(vim.api.nvim_buf_delete, b, { force = true })
end

-- ── 4. counts in edit mode ───────────────────────────────────────────────
do
  local p = vim.fn.tempname() .. ".ipynb"
  local f = io.open(p, "w")
  f:write('{"cells":[{"cell_type":"code","id":"c1","metadata":{},' ..
    '"source":"a1\\na2\\na3\\na4\\na5\\na6\\na7\\na8","execution_count":null,"outputs":[]}],' ..
    '"metadata":{"kernelspec":{"name":"python3","display_name":"P","language":"python"}},' ..
    '"nbformat":4,"nbformat_minor":5}')
  f:close()
  local buf = J.open(p)
  vim.wait(1200, function() return NB.get(buf) ~= nil end, 50)
  vim.api.nvim_set_current_buf(buf)
  local r = CM.ranges(buf)[1]
  CM.enter_edit(buf)
  vim.api.nvim_win_set_cursor(0, { r.start + 1, 0 })
  local start = vim.api.nvim_win_get_cursor(0)[1]
  vim.cmd("normal 5j")
  local moved = vim.api.nvim_win_get_cursor(0)[1] - start
  chk("5j moves five lines inside a cell", moved == 5, "moved " .. moved)
  -- and the clamp still holds: a huge count stops at the cell's last line
  vim.api.nvim_win_set_cursor(0, { r.start + 1, 0 })
  vim.cmd("normal 99j")
  local last = vim.api.nvim_win_get_cursor(0)[1]
  chk("a huge count still stops at the cell edge", last <= r.stop,
      ("landed on %d, cell ends at %d"):format(last, r.stop))
  os.remove(p)
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end

-- ── cell boundaries survive edits that would break them ─────────────────
-- Separators are real lines, and sync_from_buffer pairs cells with the text
-- between them by position. Backspace at the start of a cell glued its first
-- line onto the separator, and :w then dropped a cell. tests/boundary_screen.sh
-- drives the real keys; this pins the guard itself.
do
  local b, path = open_fixture()
  local nb = NB.get(b)
  local function lines() return vim.api.nvim_buf_get_lines(b, 0, -1, false) end
  local r2 = CM.ranges(b)[2]
  vim.bo[b].modifiable = true
  -- what <BS> at the start of cell 2 does: join its first line onto the separator
  local sep = r2.start - 1
  vim.api.nvim_buf_set_lines(b, sep, sep + 2, false, { NB.CELL_SEP .. "print(2)" })
  J._guard_boundaries(nb)
  local l = lines()
  chk("a separator glued to a cell's first line is split back",
      l[sep + 1] == NB.CELL_SEP and l[sep + 2] == "print(2)", vim.inspect(l))
  nb:sync_from_buffer()
  chk("and every cell keeps its own source", sources(b)[2] == "print(2)" and #sources(b) == 3,
      vim.inspect(sources(b)))

  -- what dj from cell 1's last line does: delete it and the separator below
  local before = lines()
  local r1 = CM.ranges(b)[1]
  vim.api.nvim_buf_set_lines(b, r1.stop - 1, r1.stop + 1, false, {})
  local notes = {}
  local real = vim.notify
  vim.notify = function(m) notes[#notes + 1] = m end
  local reverted = J._guard_boundaries(nb)
  vim.notify = real
  chk("a deleted separator is reverted", reverted and vim.deep_equal(lines(), before),
      vim.inspect(lines()))
  chk("with a message saying why", #notes == 1 and notes[1]:find("merged or split", 1, true) ~= nil)

  -- the check runs on every keystroke, so it has to stay cheap on a big notebook
  local big = {}
  for i = 1, 400 do
    for j = 1, 10 do big[#big + 1] = ("x%d_%d = %d"):format(i, j, j) end
    if i < 400 then big[#big + 1] = NB.CELL_SEP end
  end
  vim.api.nvim_buf_set_lines(b, 0, -1, false, big)
  nb._good = nil   -- take the big buffer as the new baseline
  J._guard_boundaries(nb)
  local t0 = vim.uv.hrtime()
  for _ = 1, 50 do J._guard_boundaries(nb) end
  local ms = (vim.uv.hrtime() - t0) / 1e6 / 50
  chk("the boundary check on a 4400-line notebook costs under 2ms", ms < 2, ("%.2f ms"):format(ms))
  os.remove(path); pcall(vim.api.nvim_buf_delete, b, { force = true })
end

-- A source line that reads exactly like a separator was one: opening and
-- saving such a notebook split the cell in two and moved every later cell's
-- source onto the next id.
do
  local path = vim.fn.tempname() .. ".ipynb"
  local src1 = "a = 1\n" .. NB.CELL_SEP .. "\nb = 2\n" .. NB.OUT_SEP .. "  "
  local f = io.open(path, "w")
  f:write(vim.json.encode({ cells = {
    { cell_type = "code", id = "c1", metadata = vim.empty_dict(), source = src1, execution_count = vim.NIL, outputs = {} },
    { cell_type = "code", id = "c2", metadata = vim.empty_dict(), source = "x = 2", execution_count = vim.NIL, outputs = {} },
  }, metadata = { kernelspec = { name = "python3", display_name = "P", language = "python" } },
    nbformat = 4, nbformat_minor = 5 }))
  f:close()
  local b = J.open(path)
  vim.wait(1500, function() return NB.get(b) ~= nil end, 50)
  vim.api.nvim_set_current_buf(b)
  vim.cmd("w")
  local saved = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
  local got = {}
  for _, c in ipairs(saved.cells) do
    got[#got + 1] = c.id .. "=" .. (type(c.source) == "table" and table.concat(c.source) or c.source)
  end
  chk("a source line that reads like a separator stays in its cell through open and :w",
      vim.deep_equal(got, { "c1=" .. src1, "c2=x = 2" }), vim.inspect(got))
  os.remove(path); pcall(vim.api.nvim_buf_delete, b, { force = true })
end

-- ── 5. notebook keymaps must survive a later buffer-local binder ─────────
-- We attach during BufReadCmd; plugins that map the same keys buffer-locally
-- on FileType land afterwards and win. LazyVim's treesitter-textobjects takes
-- ]c and [c that way, so the documented next/prev-cell motions silently did
-- nothing in the most common setup.
do
  local b, path = open_fixture()
  -- stand in for treesitter-textobjects binding on FileType, right after us
  vim.keymap.set("n", "]c", function() end,
    { buffer = b, desc = "IMPOSTOR Next Class Start" })
  vim.keymap.set("n", "[c", function() end,
    { buffer = b, desc = "IMPOSTOR Prev Class Start" })
  vim.wait(700)   -- let the deferred re-bind run
  local function desc_of(lhs)
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(b, "n")) do
      if m.lhs == lhs then return m.desc end
    end
  end
  chk("]c is jupynvim's after a later binder takes it",
      desc_of("]c") == "Next cell", tostring(desc_of("]c")))
  chk("[c is jupynvim's after a later binder takes it",
      desc_of("[c") == "Prev cell", tostring(desc_of("[c")))
  -- and it really moves between cells
  local r2 = CM.ranges(b)[2]
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd("normal ]c")
  vim.wait(300)
  chk("]c jumps into the next cell",
      vim.api.nvim_win_get_cursor(0)[1] >= r2.start + 1,
      ("landed on %d, cell 2 starts at %d"):format(
        vim.api.nvim_win_get_cursor(0)[1], r2.start + 1))
  os.remove(path); pcall(vim.api.nvim_buf_delete, b, { force = true })
end

-- ── 6. output cap and render memo ────────────────────────────────────────
-- A notebook storing a 420KB `!tree` dump made Notebook:to_lines cost 27ms,
-- and the LSP diagnostic/didChange paths call it dozens of times per keystroke.
-- Measured on the user's notebook before this: 2535 calls in 74s of IDLE time,
-- 97% of wall clock, nvim pegged at 99.4% CPU with the cmdline input-dead.
do
  local big = {}
  for i = 1, 20000 do big[i] = "\27[38;5;33mline " .. i .. "\27[0m" end
  local cell = { id = "big", cell_type = "code",
                 outputs = { { output_type = "stream", text = table.concat(big, "\n") } } }

  CM = CM  -- keep luacheck quiet
  local NBm = require("jupynvim.notebook")
  NBm.max_output_lines = 500
  NBm._output_expanded = {}

  local l = NBm.output_lines(cell)
  chk("output is capped to exactly max_output_lines", #l == 500, tostring(#l))
  local marks = 0
  for _, x in ipairs(l) do if x:find("hidden", 1, true) then marks = marks + 1 end end
  chk("exactly one truncation marker (no double-truncation)", marks == 1, marks .. " markers")
  chk("the head is kept", l[1]:find("line 1", 1, true) ~= nil, l[1])
  chk("the TAIL is kept (a training log's last epochs are the point)",
      l[#l]:find("line 20000", 1, true) ~= nil, l[#l])
  chk("ANSI escapes are stripped from what is shown",
      l[1]:find("\27", 1, true) == nil, vim.inspect(l[1]))

  -- The cap must apply BEFORE the expensive passes. A FRESH cell table each
  -- iteration so the memo cannot serve it - this measures the build itself,
  -- which is what runs on every real edit.
  local t0 = vim.uv.hrtime()
  for _ = 1, 5 do
    NBm.output_lines({ id = "big", cell_type = "code",
      outputs = { { output_type = "stream", text = cell.outputs[1].text } } })
  end
  local build = (vim.uv.hrtime() - t0) / 1e6 / 5
  chk("uncached render is cheap: cap applied BEFORE the ANSI/CR passes",
      build < 15, ("%.1f ms per build (was ~27ms when capped after)"):format(build))

  -- memo: repeat calls must not redo the work, and must invalidate on change
  local first = NBm.output_lines(cell)
  chk("repeat render is served from cache", NBm.output_lines(cell) == first)
  cell.outputs[1].text = cell.outputs[1].text .. "\nline 20001"
  local after = NBm.output_lines(cell)
  chk("cache invalidates when a stream output grows", after ~= first)
  chk("and the new tail is visible",
      after[#after]:find("line 20001", 1, true) ~= nil, after[#after])

  -- expanding shows everything
  NBm.toggle_output_expanded("big")
  chk("expand shows the full output", #NBm.output_lines(cell) > 20000,
      tostring(#NBm.output_lines(cell)))
  NBm.toggle_output_expanded("big")
  chk("collapse returns to the cap", #NBm.output_lines(cell) == 500)

  -- 0 disables the cap entirely
  NBm.max_output_lines = 0
  chk("max_output_lines = 0 disables the cap", #NBm.output_lines(cell) > 20000)
  NBm.max_output_lines = 500
end

if fails == 0 then
  io.write("\nALL CELL-OPS CHECKS PASSED\n")
else
  io.write(("\nCELL-OPS: %d CHECK(S) FAILED\n"):format(fails))
  vim.cmd("cquit 1")
end

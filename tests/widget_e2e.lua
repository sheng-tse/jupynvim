-- The widget protocol on a real ipywidgets 8 kernel. Each cell runs with <C-CR> as
-- stale_output_e2e does. The checks read the rows the user sees (the cell's output
-- region), not the mirror, and compare them with rows derived from the text form's
-- rules: a slider track of 20 cells whose knob sits at floor(fraction * 19 + 0.5),
-- and a progress bar of 25 cells (full blocks and one partial block).
--   tq    tqdm.notebook runs live: at least three percentages between 0 and 100
--         are seen while it runs; it ends at 100% with a full bar, a success
--         extmark over the bar, and 60/60. Two latencies are checked against
--         320 ms and printed: the 100% row, from the widget_event that carries
--         100% (during a stream an earlier update's sync may draw it, so this
--         figure is how stale the buffer is), and the success bar, from the last
--         widget_event of tqdm's close (bar_style success) to the buffer showing it.
--         Both figures are the wait for one redraw: each comes out at the 150 ms
--         debounce, plus the poll.
--   au    tqdm.auto ends at 100% with a full bar and 10/10.
--   out   an Output widget shows its output in the view; the cell's own stream
--         holds only 'outside'.
--   sl    a slider shows its value; a frontend change shows within 400 ms and,
--         as a lone update, within 300 ms, before the kernel answers; the kernel
--         then sees the new value; a value past the maximum ends at the kernel's
--         clamp, 10. The lone update's own path is what the 300 ms figure pins.
--   btn   a click (W.custom) reaches the kernel and prints into the button's cell.
--   ia    interact's slider and its Output widget: after the run the rows are
--         '  x [track] 5' and '  x=5 ...'. After a W.set of x to 7 the new print
--         replaces the old one in place (interact clears with wait=True): the
--         region shows '  x=7 ...' and no other '  x=' row, and a buffer that
--         was clean stays clean.
--   save  a save leaves the buffer unmodified, and a W.set after it leaves the
--         buffer unmodified too; the saved file holds the widget state (the
--         slider at 10, the Output widget's output); reopened with no kernel,
--         the tq, sl and out rows are the rows before the close.
-- Requires a built backend and Python with ipykernel, tqdm and ipywidgets 8 (the
-- notebook's python3 kernelspec, as the run's test environment gives it).
-- Optional override: JUPYNVIM_TEST_CORE=/path/to/jupynvim-core
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local J = require("jupynvim")
local NB = require("jupynvim.notebook")
local CM = require("jupynvim.notebook.cellmode")
-- Pcall: on a tree without the widget mirror the checks fail with the rows the
-- region shows, not with a module error.
local okW, W = pcall(require, "jupynvim.notebook.widgets")
local VIEW_MIME = "application/vnd.jupyter.widget-view+json"
local STATE_MIME = "application/vnd.jupyter.widget-state+json"
local clock = vim.uv or vim.loop
local tmp = vim.fn.tempname() .. ".ipynb"
local nb, buf, client, sid
local failures = {}
local function chk(name, ok, detail)
  io.write((ok and "  ok " or "FAIL ") .. name .. (not ok and detail and (" -- " .. detail) or "") .. "\n")
  if not ok then failures[#failures + 1] = name end
end

-- The rows the text form must produce, written from its rules and not from the
-- renderer: a slider track of 20 cells whose knob is at floor(frac * 19 + 0.5),
-- and a full progress bar of 25 blocks.
local function track(p) return ("━"):rep(p) .. "●" .. ("─"):rep(19 - p) end
local FULL = ("█"):rep(25)

-- The output rows of the cell at idx, with the two-space indent they have.
local function region(idx)
  local r = CM.ranges(buf)[idx]
  if not r or not r.out_sep then return {} end
  return vim.api.nvim_buf_get_lines(buf, r.out_sep + 1, r.out_stop, false)
end
local function find_row(lines, pat)
  for i, l in ipairs(lines) do
    if l:match(pat) then return i, l end
  end
  return nil
end
local function has_line(lines, exact)
  for _, l in ipairs(lines) do
    if l == exact then return true end
  end
  return false
end
local function show(lines) return "[" .. table.concat(lines, " | ") .. "]" end

-- The model id of the widget view in the cell's outputs, or nil.
local function view_id(idx)
  for _, o in ipairs(nb.cells[idx].outputs or {}) do
    local v = type(o.data) == "table" and o.data[VIEW_MIME]
    if type(v) == "table" and type(v.model_id) == "string" then return v.model_id end
  end
  return nil
end

-- Runs the cell at idx with <C-CR> and waits until the kernel is idle again.
-- poll, when given, runs about every 20 ms meanwhile.
local function run(idx, poll, timeout)
  local cell = nb.cells[idx]
  local before = tonumber(cell.execution_count) or 0
  vim.api.nvim_win_set_cursor(0, { CM.ranges(buf)[idx].start + 1, 0 })
  vim.cmd("normal " .. vim.api.nvim_replace_termcodes("<C-CR>", true, false, true))
  return vim.wait(timeout or 10000, function()
    if poll then poll() end
    local state = nb.cell_state[cell.id]
    return (tonumber(cell.execution_count) or 0) > before and state ~= nil and state.exec_state == "idle"
  end, 20)
end

-- Waits until the cell at idx shows a row matching pat.
local function wait_row(idx, pat, timeout)
  return vim.wait(timeout or 5000, function() return find_row(region(idx), pat) ~= nil end, 20)
end

-- The success extmark over the bar of the row matching pat in the cell at idx:
-- it starts where the bar's first block is and covers all of its blocks.
local function bar_marked(idx, pat, group)
  local lines = region(idx)
  local i, l = find_row(lines, pat)
  if not i then return false, "no row " .. pat end
  local r = CM.ranges(buf)[idx]
  local row0 = r.out_sep + i
  local col = l:find("█", 1, true) - 1
  local marks = vim.api.nvim_buf_get_extmarks(buf, nb.border_ns, { row0, 0 }, { row0 + 1, 0 },
    { details = true })
  for _, m in ipairs(marks) do
    local d = m[4]
    if m[2] == row0 and m[3] == col and d.hl_group == group and d.end_col == col + #FULL then
      return true
    end
  end
  return false, "no " .. group .. " extmark over the bar at column " .. col .. " of row " .. row0
end

-- Latency, two figures. The wrapper records when the mirror has handled an
-- update: t_100 for the first one whose value holds "100%" (tqdm's label is the
-- HTML child with that value), and t_success_event for the last one that sets
-- bar_style 'success' (the signal tqdm's close sends last). The polls record
-- when the buffer shows the 100% row (t_seen) and the success bar (t_done).
-- The 100% figure is the buffer's staleness during the stream: an earlier
-- update's pending sync may draw the 100% state before this update's own sync.
-- The success figure runs from the close's last event to the buffer, through the
-- same debounced redraw, so it is the wait for that redraw, not the path of one
-- event alone (the lone slider update, sl, is the check of one update's path).
local t_100, t_success_event
if okW and W then
  local handle = W.handle_event
  W.handle_event = function(p)
    handle(p)
    local ev = type(p) == "table" and p.event
    if type(ev) == "table" and ev.kind == "update" and type(ev.state) == "table" then
      if t_100 == nil and type(ev.state.value) == "string" and ev.state.value:find("100%", 1, true) then
        t_100 = clock.hrtime()
      end
      if ev.state.bar_style == "success" then
        t_success_event = clock.hrtime()
      end
    end
  end
end

local ok, err = xpcall(function()
  J.setup({ core_path = vim.env.JUPYNVIM_TEST_CORE, auto_install = false, log_level = "warn" })
  chk("the widget mirror module loads", okW and W ~= nil, tostring(W))
  local function code(id, source)
    return { id = id, cell_type = "code", source = source, metadata = vim.empty_dict(),
      execution_count = vim.NIL, outputs = {} }
  end
  local cells = {
    code("tq", "from tqdm.notebook import tqdm\nimport time\n"
      .. "for _ in tqdm(range(60), desc='work'):\n    time.sleep(0.05)"),
    code("au", "from tqdm.auto import tqdm as ta\nimport time\nbar = ta(total=10, desc='auto')\n"
      .. "for _ in range(10):\n    time.sleep(0.05)\n    bar.update(1)\nbar.close()"),
    code("out", "import ipywidgets as w\nfrom IPython.display import display\nout = w.Output()\n"
      .. "display(out)\nwith out:\n    print('inside the widget')\nprint('outside')"),
    code("sl", "import ipywidgets as w\ns = w.IntSlider(value=2, max=10, description='n')\ns"),
    code("chk", "print('kernel sees', s.value)"),
    code("btn", "import ipywidgets as w\nb = w.Button(description='press')\n"
      .. "b.on_click(lambda _: print('pressed'))\nb"),
    code("ia", "from ipywidgets import interact\ndef f(x):\n    print('x=%d ...' % x)\n"
      .. "_ = interact(f, x=(0, 10))"),
  }
  local file = assert(io.open(tmp, "w"))
  file:write(vim.json.encode({ nbformat = 4, nbformat_minor = 5, cells = cells,
    metadata = { kernelspec = { name = "python3", display_name = "Python 3", language = "python" } } }))
  file:close()
  client = J._ensure_client()
  local open_err, result = client:call_sync("open", { path = tmp })
  assert(not open_err, tostring(open_err))
  sid = result.session_id
  buf = vim.api.nvim_create_buf(false, true)
  -- A notebook buffer is acwrite, as M.open makes it. A scratch buffer is
  -- nofile, and Neovim never sets 'modified' on one, so the save checks below
  -- could not fail.
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].swapfile = false
  vim.api.nvim_set_current_buf(buf)
  nb = NB.create(buf, tmp, sid, result.snapshot)
  J._populate_buffer(nb)
  require("jupynvim.notebook.keymaps").attach(buf, J)
  local start_err = client:call_sync("start_kernel", { session_id = sid }, 30000)
  assert(not start_err, "start_kernel: " .. tostring(start_err))

  -- tq: the bar is live, and it ends at 100%.
  local pcts, t_seen, t_done = {}, nil, nil
  local FINAL_TQ = "^  work: 100%% " .. FULL .. "%s+60/60 %["
  local function poll_tq()
    if not t_seen then
      for _, l in ipairs(region(1)) do
        local p = l:match("^  work:%s+(%d+)%%")
        if p then
          local n = tonumber(p)
          if n > 0 and n < 100 then pcts[n] = true end
          if n == 100 then t_seen = clock.hrtime() end
          break
        end
      end
    end
    if not t_done and t_success_event and bar_marked(1, FINAL_TQ, "JupynvimWidgetBarSuccess") then
      t_done = clock.hrtime()
    end
  end
  local tq_ran = run(1, poll_tq, 30000)
  chk("tq ran to idle", tq_ran, show(region(1)))
  vim.wait(3000, function() poll_tq(); return t_done ~= nil end, 20)
  local live = 0
  for _ in pairs(pcts) do live = live + 1 end
  chk("tq: at least 3 live percentages strictly between 0 and 100", live >= 3,
    "seen " .. live .. " " .. show(region(1)))
  chk("tq: ends at 'work: 100%' with a full bar and 60/60", find_row(region(1), FINAL_TQ) ~= nil,
    show(region(1)))
  local marked, why = bar_marked(1, FINAL_TQ, "JupynvimWidgetBarSuccess")
  chk("tq: the full bar carries JupynvimWidgetBarSuccess", marked, why)
  local lat = (t_seen and t_100) and (t_seen - t_100) / 1e6 or nil
  chk("tq: the 100% row shows within 320 ms of the widget_event that carries 100%", lat ~= nil and lat <= 320,
    "latency " .. tostring(lat) .. " ms")
  if lat then io.write(string.format("  latency widget_event (100%%) to the 100%% row, stream staleness: %.1f ms\n", lat)) end
  local lat_done = (t_done and t_success_event) and (t_done - t_success_event) / 1e6 or nil
  chk("tq: the success bar shows within 320 ms of the last widget_event of tqdm's close",
    lat_done ~= nil and lat_done <= 320, "latency " .. tostring(lat_done) .. " ms")
  if lat_done then
    io.write(string.format("  latency last widget_event of tq's close to its success bar: %.1f ms\n", lat_done))
  end

  -- au: tqdm.auto ends at 100% with a full bar and 10/10.
  local au_ran = run(2, nil, 15000)
  chk("au ran to idle", au_ran, show(region(2)))
  local FINAL_AU = "^  auto: 100%% " .. FULL .. "%s+10/10 %["
  wait_row(2, FINAL_AU, 5000)
  chk("au: ends at 'auto: 100%' with a full bar and 10/10", find_row(region(2), FINAL_AU) ~= nil,
    show(region(2)))

  -- out: the Output widget's text is in the view; the cell keeps only 'outside'.
  run(3, nil, 15000)
  vim.wait(5000, function()
    local r = region(3)
    return has_line(r, "  inside the widget") and has_line(r, "  outside")
  end, 20)
  local r3 = region(3)
  chk("out: rows '  inside the widget' and '  outside'",
    has_line(r3, "  inside the widget") and has_line(r3, "  outside"), show(r3))
  local streams = {}
  for _, o in ipairs(nb.cells[3].outputs or {}) do
    if o.output_type == "stream" then streams[#streams + 1] = o.text end
  end
  chk("out: the cell model holds only 'outside'", table.concat(streams) == "outside\n",
    vim.inspect(streams))

  -- sl: the value, an optimistic change, the kernel's view of it, and the clamp.
  run(4, nil, 15000)
  local sl_shown = vim.wait(5000, function() return has_line(region(4), "  n " .. track(4) .. " 2") end, 20)
  chk("sl: shows '  n ' track(4) ' 2'", sl_shown, show(region(4)))
  local sl_id = view_id(4)
  chk("sl: the cell shows a widget view", sl_id ~= nil)
  -- A lone update: nothing else is pending, so the figure is the redraw's own
  -- path (the debounce of 150 ms and a poll). t_sl is taken inside the wait, when
  -- the row first shows, so the figure has no return overhead in it.
  local t0 = clock.hrtime()
  W.set(nb, sl_id, { value = 7 })
  local t_sl
  local optimistic = vim.wait(400, function()
    if not t_sl and has_line(region(4), "  n " .. track(13) .. " 7") then t_sl = clock.hrtime() end
    return t_sl ~= nil
  end, 20)
  chk("sl: a change to 7 shows within 400 ms, before any kernel reply", optimistic, show(region(4)))
  local sl_ms = t_sl and (t_sl - t0) / 1e6 or nil
  chk("sl: a change to 7 shows within 300 ms (the widget budget for a buffer update)",
    sl_ms ~= nil and sl_ms <= 300, "shown after " .. tostring(sl_ms) .. " ms")
  io.write(string.format("  sl change to 7 shown after %s ms (a lone update)\n", tostring(sl_ms and string.format("%.1f", sl_ms))))
  run(5, nil, 15000)
  -- The output is written by the debounced sync, a moment after the kernel is idle.
  local seen7 = vim.wait(5000, function() return has_line(region(5), "  kernel sees 7") end, 20)
  chk("chk: the kernel sees 7", seen7, show(region(5)))
  W.set(nb, sl_id, { value = 42 })
  local clamped = vim.wait(5000, function()
    return has_line(region(4), "  n " .. track(19) .. " 10")
  end, 20)
  chk("sl: a value past the maximum ends at 10", clamped, show(region(4)))

  -- btn: a click reaches the kernel and prints into the button's cell.
  run(6, nil, 15000)
  local btn_id = view_id(6)
  chk("btn: the cell shows a button view", btn_id ~= nil)
  -- A click is made on the button the user sees, so the test waits for its row:
  -- the cell takes the callback's output only once the view has been drawn.
  local drawn = vim.wait(5000, function() return has_line(region(6), "  [ press ]") end, 20)
  chk("btn: the button's row is drawn", drawn, show(region(6)))
  chk("btn: W.custom sends the click", W.custom(nb, btn_id, { event = "click" }) == true)
  local clicked = vim.wait(5000, function() return has_line(region(6), "  pressed") end, 20)
  chk("btn: the click adds 'pressed' to the button's cell", clicked, show(region(6)))

  -- ia: interact's slider and its Output widget are one view. The callback prints
  -- into the Output widget after clear_output(wait=True), so a change replaces the
  -- print in place.
  run(7, nil, 15000)
  local ia_rows = vim.wait(5000, function()
    return has_line(region(7), "  x " .. track(10) .. " 5") and has_line(region(7), "  x=5 ...")
  end, 20)
  chk("ia: the rows '  x [track] 5' and '  x=5 ...' show after the run", ia_rows, show(region(7)))
  local x_id = nil
  for _, m in ipairs(W.export(sid)) do
    if m.model_name == "IntSliderModel" and type(m.state) == "table" and m.state.description == "x" then
      x_id = m.model_id
    end
  end
  chk("ia: the cell shows the interact view and its slider is in the store",
    view_id(7) ~= nil and x_id ~= nil, "view " .. tostring(view_id(7)) .. " slider " .. tostring(x_id))
  -- The buffer is clean before the change: the run's output rows are saved first.
  J._save(nb)
  chk("ia: the buffer is clean before the change", vim.bo[buf].modified == false)
  W.set(nb, x_id, { value = 7 })
  local ia_new = vim.wait(5000, function() return has_line(region(7), "  x=7 ...") end, 20)
  chk("ia: after a W.set to 7 the print shows '  x=7 ...'", ia_new, show(region(7)))
  chk("ia: the slider row moves to 7", has_line(region(7), "  x " .. track(13) .. " 7"), show(region(7)))
  local stray = 0
  for _, l in ipairs(region(7)) do
    if l:match("^  x=") then stray = stray + 1 end
  end
  chk("ia: the old print is replaced in place, with no stray '  x=' row",
    not has_line(region(7), "  x=5 ...") and stray == 1, show(region(7)))
  chk("ia: a clean buffer stays clean after the change", vim.bo[buf].modified == false)

  -- save: the buffer stays unmodified, and the file holds the widget state.
  J._save(nb)
  chk("save: the buffer is unmodified after J._save", vim.bo[buf].modified == false)
  -- A W.set to 3 changes the slider's row (10 is the value it shows already, so the
  -- row would not move). The row shows once the debounced redraw has run, so the
  -- buffer is read after that redraw, not before it.
  W.set(nb, sl_id, { value = 3 })
  local redrawn = vim.wait(3000, function()
    return has_line(region(4), "  n " .. track(6) .. " 3")
  end, 20)
  chk("save: a W.set after the save shows the slider at 3", redrawn, show(region(4)))
  chk("save: a W.set after the save leaves the buffer unmodified", vim.bo[buf].modified == false)
  -- Back to 10, the value the file holds: the reopen below compares with these rows.
  W.set(nb, sl_id, { value = 10 })
  vim.wait(3000, function() return has_line(region(4), "  n " .. track(19) .. " 10") end, 20)
  local saved = vim.json.decode(table.concat(vim.fn.readfile(tmp), "\n"))
  local wblock = (saved.metadata or {}).widgets and saved.metadata.widgets[STATE_MIME]
  local models = wblock and wblock.state or {}
  local slider_at_10, output_has_text = false, false
  for _, m in pairs(models) do
    if type(m) == "table" and m.model_name == "IntSliderModel" and type(m.state) == "table"
        and m.state.value == 10 then
      slider_at_10 = true
    end
    if type(m) == "table" and m.model_name == "OutputModel"
        and vim.json.encode(m.state or {}):find("inside the widget", 1, true) then
      output_has_text = true
    end
  end
  chk("save: metadata.widgets holds the slider at 10", slider_at_10, vim.inspect(models))
  chk("save: metadata.widgets holds the Output widget's 'inside the widget'", output_has_text)

  -- Reopened with no kernel: the same rows, from the saved state.
  local before = { tq = region(1), sl = region(4), out = region(3) }
  client:call_sync("close", { session_id = sid }, 5000)
  NB.remove(buf)
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  local open_err2, result2 = client:call_sync("open", { path = tmp })
  assert(not open_err2, tostring(open_err2))
  sid = result2.session_id
  buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].swapfile = false
  vim.api.nvim_set_current_buf(buf)
  nb = NB.create(buf, tmp, sid, result2.snapshot)
  J._populate_buffer(nb)
  require("jupynvim.notebook.keymaps").attach(buf, J)
  vim.wait(3000, function()
    return vim.deep_equal(region(1), before.tq) and vim.deep_equal(region(4), before.sl)
      and vim.deep_equal(region(3), before.out)
  end, 20)
  chk("reopened with no kernel: the tq rows equal those before the close",
    vim.deep_equal(region(1), before.tq), show(region(1)) .. " vs " .. show(before.tq))
  chk("reopened with no kernel: the sl rows equal those before the close",
    vim.deep_equal(region(4), before.sl), show(region(4)) .. " vs " .. show(before.sl))
  chk("reopened with no kernel: the out rows equal those before the close",
    vim.deep_equal(region(3), before.out), show(region(3)) .. " vs " .. show(before.out))
  local entry = W.get(sid, sl_id)
  chk("reopened with no kernel: the slider is not connected", entry ~= nil and entry.live == false)
end, debug.traceback)
if not ok then chk("end-to-end test completed", false, err) end

if client and sid then client:call_sync("close", { session_id = sid }, 5000) end
if buf then NB.remove(buf); pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
if client then client:stop() end
os.remove(tmp)
if #failures > 0 then
  io.write(#failures .. " WIDGET E2E CHECKS FAILED\n")
  vim.cmd("cquit 1")
else
  io.write("ALL WIDGET E2E CHECKS PASSED\n")
  vim.cmd("qa!")
end

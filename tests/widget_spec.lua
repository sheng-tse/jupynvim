-- The widget mirror in Neovim: the state the Lua side keeps for each session, and
-- the redraws a widget event asks for.
--
-- Section A has no backend. Events go into the mirror and the entries come out:
-- a saved state loaded with base64 and hex buffers at their paths (0-based list
-- indices become 1-based Lua indices), vim.NIL kept in a state, an open, an
-- update with a buffer, and a plain value that drops the buffer's path, an
-- Output widget's streams (coalesced), clear_first, clear_output and
-- update_display_data, the export that puts the buffers back as base64, a close
-- as a tombstone, a reset to dead models, and a set on a dead model refused.
--
-- Section A2 (no backend, client stubbed) checks the sends to a live model: a
-- set with a binary value sends null in that slot of state and the bytes once
-- in buffers, leaves the caller's own table alone, and keeps the bytes in the
-- mirror; an empty state and custom content go out as msgpack maps; the cell
-- id defaults to the cell that shows the model; a send to a dead model is
-- refused. It also checks that W.begin drops a cell's dependency and that
-- NB.remove drops the session's mirror.
--
-- The V checks in A2 pin the redraws that the other checks leave open: a close
-- and an Output widget's output event bump the cell that shows the model and
-- keep the buffer clean; a reset kills the models and redraws no cell (the text
-- form does not read their live flag); a W.set bumps its cell before any reply;
-- a widget redraw and a plain sync in one window end modified in either order,
-- and after a plain sync a redraw keeps a clean buffer clean; a keep-clean sync
-- conceals the output marker of every region it rewrites, also when a region
-- above it grows; an execute_result sets the execution count; W.load normalizes
-- an Output widget's image and redraws the cells that show a loaded model; a
-- cell that left its notebook is not redrawn.
--
-- Section B runs the real backend with no kernel. A notebook carries a saved
-- widget state (a slider with its layout and style), and one cell shows the
-- slider. After the open, the populate and a save, an update to the slider
-- redraws that cell (its _widget_rev goes to 1) and leaves the buffer clean with
-- its saved hash still equal to the text. An update to the layout the slider
-- uses redraws it again, so the dependency reaches the models the view refers
-- to. A stream on the other cell does make the buffer modified (the control),
-- and the widget cell keeps its revision. A set on the dead slider is refused
-- with "not connected to a kernel".
--
-- Section C runs the saved gallery (tests/fixtures/widgets_gallery_saved.ipynb,
-- copied to a temp file) through the real backend with no kernel. Every tagged
-- cell shows its rows of the text form, the bar spans are the table's (and no
-- other bar span exists), and the custom bar colour is a highlight group.
--
-- Section D checks the rules through synthetic states: an unknown model and a
-- third-party model fall back to text/plain at the root (and show as a name
-- inside a box), an unknown @jupyter-widgets model shows its name, a closed
-- model and a hidden layout show nothing, a closed child leaves its siblings,
-- a shorter block is padded, cycles and depths beyond 32 show nothing, the
-- html_to_text, the highlight groups (the bar groups from the palette's tokens, with a
-- stand-in palette and with the real one, and without a palette), the bar spans through the cut of a
-- long output (a head row keeps its row, a tail row moves, a hidden output has
-- none), and the budgets (an update, a tqdm render, a cache hit, and a W.set on
-- a live model). A readout precision of three digits is clamped as the frontend's
-- d3-format clamps it, and a state the text form cannot read falls back to
-- text/plain (logged once) without breaking the notebook, on a saved open, a live
-- update, or an Output widget's nested images. An ipywidgets 7 Tab and Accordion
-- keep their titles in _titles. The rules no earlier check pinned: the closing
-- block tags of HTML are line ends, a range whose ends are not in order moves its
-- second end, a time shows its seconds, and a cycle with a leaf shows the leaf once.
-- It also pins the cut of a long Output widget capture: a 20,000-line capture
-- rebuilds in under 8 ms, as the same text as a cell's stream does, with the same
-- rows; a capture cut inside a box shows the rows it shows alone, marker included;
-- a closed model's tombstone goes once no cell shows it; a reset drops the dead
-- models the core pruned. The cut reaches the cell (cut flag, marker row and count)
-- alone, in a VBox, side by side in an HBox (its markers stand for the rows they hide
-- once, on one row or on different rows) and in an open Accordion. Side by side, a data
-- URI row is the marker before the box lines its columns up, a row wider than the column
-- bound is cut to it with the cut mark (a bar's span with it), and the rows stay a few
-- KB. A tombstone of a model no cell showed goes with the next output sync, unless a
-- cell that sync builds shows it.
--
-- Section E checks the nested images of an Output widget: one image, keyed by
-- the Output model and its output 2, none when the output is hidden.
--
-- Requires a built backend. Optional overrides: JUPYNVIM_TEST_CORE=/path/to/jupynvim-core
package.path = "./lua/?.lua;./lua/?/init.lua;./tests/?.lua;" .. package.path

local J = require("jupynvim")
local NB = require("jupynvim.notebook")
local okw, W = pcall(require, "jupynvim.notebook.widgets")

local failures = {}
local function chk(name, ok, detail)
  io.write((ok and "  ok " or "FAIL ") .. name .. (not ok and detail and (" -- " .. detail) or "") .. "\n")
  if not ok then failures[#failures + 1] = name end
end
-- A check body returns true or false and a detail. An error inside it fails
-- the check with its message, so a missing module shows as a failed check.
local function check(name, body)
  local ok, pass, detail = pcall(body)
  if not ok then return chk(name, false, tostring(pass)) end
  chk(name, pass == true, detail)
end
if not okw then
  chk("the widgets module loads", false, tostring(W))
  W = nil
end

local BYTES = "\0\1\2\255\254 first"
local NEW = "\9\8\7\0\200 second"
local VIEW = "application/vnd.jupyter.widget-view+json"
local STATE = "application/vnd.jupyter.widget-state+json"

-- The text form's bars, written out. S(p): p heavy cells, a dot, then 19 - p light
-- cells (a slider track, 20 cells). R(p1, p2): the range track, 20 cells. P(full,
-- partial): full blocks, one partial block, then spaces (a progress bar, 25 cells).
-- The values behind each name are in section C.
local S0 = "●───────────────────"
local S1 = "━●──────────────────"
local S6 = "━━━━━━●─────────────"
local S10 = "━━━━━━━━━━●─────────"
local S13 = "━━━━━━━━━━━━━●──────"
local S14 = "━━━━━━━━━━━━━━●─────"
local R10_13 = "──────────●━━●──────"
local R10_14 = "──────────●━━━●─────"
local R4_11 = "────●━━━━━━●────────"
local R3_14 = "───●━━━━━━━━━━●─────"
local P033 = "████████▎                "
local P05 = "████████████▌            "
local P06 = "███████████████          "
local P065 = "████████████████▎        "
local P07 = "█████████████████▌       "
local P08 = "████████████████████     "
local P095 = "███████████████████████▊ "
local P10 = "█████████████████████████"

local function hex(s)
  return (s:gsub(".", function(c) return ("%02x"):format(c:byte()) end))
end
-- vim.NIL is truthy in Lua, so a read of a state value goes through nn: it turns
-- vim.NIL into nil.
local function nn(v)
  if v == vim.NIL then return nil end
  return v
end
-- Runs fn with vim.notify captured. Returns fn's result and the messages.
local function notify_capture(fn)
  local msgs, saved = {}, vim.notify
  vim.notify = function(m) msgs[#msgs + 1] = tostring(m) end
  local ok, res = pcall(fn)
  vim.notify = saved
  if not ok then error(res, 0) end
  return res, msgs
end

-- ── A. the mirror, no backend ───────────────────────────
io.write("A. the mirror (no backend)\n")
local SID = "widget-spec-a"
local function send(sid, event, buffers)
  W.handle_event({ session_id = sid, event = event, buffers = buffers or {} })
end

check("load: a base64 buffer sits at its path and the entry is dead", function()
  W.load(SID, {
    { model_id = "img", model_name = "ImageModel", model_module = "@jupyter-widgets/controls",
      model_module_version = "2.0.0", state = { format = "png" }, live = false,
      buffers = { { encoding = "base64", path = { "value" }, data = vim.base64.encode(BYTES) } } },
    { model_id = "lst", model_name = "SelectMultipleModel", model_module = "@jupyter-widgets/controls",
      model_module_version = "2.0.0", state = { items = { vim.NIL, vim.NIL } }, live = false,
      buffers = { { encoding = "hex", path = { "items", 1 }, data = hex(BYTES) } } },
  })
  local e = W.get(SID, "img")
  return e ~= nil and e.state.value == BYTES and e.state.format == "png" and e.live == false,
    "entry " .. vim.inspect(e)
end)

check("load: a hex buffer at 0-based index 1 lands at Lua index 2, the null slot kept", function()
  local items = W.get(SID, "lst").state.items
  return items[2] == BYTES and items[1] == vim.NIL, "items " .. vim.inspect(items)
end)

check("export: buffers back as base64 at 0-based paths, the state without them", function()
  local entry
  for _, m in ipairs(W.export(SID)) do
    if m.model_id == "lst" then entry = m end
  end
  if not entry then return false, "no lst entry in the export" end
  local b = entry.buffers[1]
  local ok = b ~= nil and b.encoding == "base64" and vim.base64.decode(b.data) == BYTES
    and b.path[1] == "items" and b.path[2] == 1
    and entry.state.items[2] == vim.NIL and entry.state.items[1] == vim.NIL
  -- the mirror keeps its bytes: the export works on a copy
  ok = ok and W.get(SID, "lst").state.items[2] == BYTES
  return ok, "export " .. vim.inspect(entry)
end)

check("open: an Output widget comes in live, with vim.NIL kept", function()
  send(SID, { kind = "open", model_id = "out", model_name = "OutputModel",
    model_module = "@jupyter-widgets/output", model_module_version = "1.0.0",
    state = { msg_id = "", outputs = {}, description = vim.NIL }, buffer_paths = {}, live = true })
  local e = W.get(SID, "out")
  return e ~= nil and e.live == true and e.name == "OutputModel"
    and e.module == "@jupyter-widgets/output" and e.state.description == vim.NIL,
    "entry " .. vim.inspect(e)
end)

check("update: a new buffer replaces the one at its path, its path kept once", function()
  local before = W.get(SID, "img").rev or 0
  send(SID, { kind = "update", model_id = "img", state = { format = "jpeg" },
    buffer_paths = { { "value" } } }, { NEW })
  local e = W.get(SID, "img")
  return e.state.value == NEW and e.state.format == "jpeg" and #e.buffer_paths == 1
    and e.buffer_paths[1][1] == "value" and e.rev == before + 1,
    "value " .. tostring(nn(e.state.value)) .. " paths " .. #e.buffer_paths .. " rev " .. tostring(e.rev)
end)

check("update: a plain value replaces the buffer and drops its path", function()
  send(SID, { kind = "update", model_id = "img", state = { value = 1 }, buffer_paths = {} })
  local e = W.get(SID, "img")
  return e.state.value == 1 and #e.buffer_paths == 0,
    "value " .. tostring(nn(e.state.value)) .. " paths " .. #e.buffer_paths
end)

check("update: vim.NIL is kept in the state and reads as nil", function()
  send(SID, { kind = "update", model_id = "img", state = { description = vim.NIL }, buffer_paths = {} })
  local raw = W.get(SID, "img").state.description
  return raw == vim.NIL and nn(raw) == nil, "raw " .. tostring(raw)
end)

local function out_event(event)
  send(SID, { kind = "output", model_id = "out", event = event })
end

check("output: streams of one name coalesce into one output", function()
  out_event({ kind = "stream", name = "stdout", text = "a" })
  out_event({ kind = "stream", name = "stdout", text = "b" })
  local outs = W.get(SID, "out").state.outputs
  return #outs == 1 and outs[1].output_type == "stream" and outs[1].text == "ab",
    "outputs " .. vim.inspect(outs)
end)

check("output: clear_first starts a new list", function()
  out_event({ kind = "stream", name = "stderr", text = "err", clear_first = true })
  local outs = W.get(SID, "out").state.outputs
  return #outs == 1 and outs[1].name == "stderr" and outs[1].text == "err", "outputs " .. vim.inspect(outs)
end)

check("output: clear_output empties, display_data and update_display_data replace", function()
  out_event({ kind = "clear_output", wait = false })
  local empty = #W.get(SID, "out").state.outputs == 0
  out_event({ kind = "display_data", data = { ["text/plain"] = "one" }, metadata = vim.empty_dict(),
    transient = { display_id = "d1" } })
  out_event({ kind = "update_display_data", display_id = "d1", data = { ["text/plain"] = "two" },
    metadata = vim.empty_dict() })
  local outs = W.get(SID, "out").state.outputs
  return empty and #outs == 1 and outs[1].data["text/plain"] == "two" and (outs[1]._rev or 0) == 1,
    "outputs " .. vim.inspect(outs)
end)

check("custom: counted as an event and changes no state", function()
  local before = W.stats.events
  local state_before = vim.inspect(W.get(SID, "out").state)
  send(SID, { kind = "custom", model_id = "out", content = { event = "click" } })
  return W.stats.events == before + 1 and vim.inspect(W.get(SID, "out").state) == state_before
    and W.get(SID, "out").live == true, "events " .. tostring(W.stats.events)
end)

check("events of a session with no notebook are dropped, no mirror made", function()
  send("widget-spec-nobody", { kind = "update", model_id = "m", state = { x = 1 }, buffer_paths = {} })
  return W.get("widget-spec-nobody", "m") == nil, "entry " .. vim.inspect(W.get("widget-spec-nobody", "m"))
end)

check("close: a tombstone, and the state is freed", function()
  send(SID, { kind = "close", model_id = "img" })
  local e = W.get(SID, "img")
  return e ~= nil and e.closed == true and e.state == nil and not e.live, "entry " .. vim.inspect(e)
end)

check("reset: every model is dead and keeps its state; a tombstone nothing shows goes", function()
  send(SID, { kind = "reset" })
  local o, l = W.get(SID, "out"), W.get(SID, "lst")
  -- no cell shows the closed model "img" here, so its tombstone goes with the restart
  return o ~= nil and o.live == false and o.state ~= nil and l ~= nil and l.live == false
    and l.state ~= nil and W.get(SID, "img") == nil,
    "out " .. vim.inspect(o and o.live) .. " lst " .. vim.inspect(l and l.live) .. " img " .. vim.inspect(W.get(SID, "img"))
end)

check("set: a dead model and a tombstone are refused with a warning", function()
  local nb = { session_id = SID, cells = {} }
  local res, msgs = notify_capture(function() return W.set(nb, "out", { value = 1 }) end)
  local res2 = notify_capture(function() return W.set(nb, "img", { value = 1 }) end)
  local said = msgs[1] ~= nil and msgs[1]:find("not connected to a kernel", 1, true) ~= nil
  return res == false and res2 == false and said,
    "results " .. tostring(res) .. " " .. tostring(res2) .. " msgs " .. vim.inspect(msgs)
end)

-- ── A2. sends to a live model, the dependency index, the notebook's lifecycle ──
io.write("A2. sends to a live model, dependencies and the notebook's lifecycle (no backend)\n")
local LIVE, UP, DEAD = "widget-spec-live", "up-model", "dead-model"
local DEPSID, DEP = "widget-spec-dep", "dep-model"
local sent = {}
-- Runs fn with the client stubbed: every call is recorded in sent, nothing is sent.
local function with_client(fn)
  local saved = J._nb_client
  sent = {}
  J._nb_client = function()
    return { call = function(_, method, params) sent[#sent + 1] = { method = method, params = params } end }
  end
  local ok, res = pcall(fn)
  J._nb_client = saved
  if not ok then error(res, 0) end
  return res
end
local function model_entry(id, name, state, live)
  return { model_id = id, model_name = name, model_module = "@jupyter-widgets/controls",
    model_module_version = "2.0.0", state = state, buffers = {}, live = live }
end
-- A cell of a notebook that shows the live upload model, for the default cell id.
local cellA = { id = "cellA", cell_type = "code", source = "", outputs = {} }
local nbL = { session_id = LIVE, cells = { cellA } }

local function a2_run()
  W.load(LIVE, {
    { model_id = UP, model_name = "FileUploadModel", model_module = "@jupyter-widgets/controls",
      model_module_version = "2.0.0", state = { data = { vim.NIL } }, live = true, buffers = {} },
    model_entry(DEAD, "LabelModel", { value = "gone" }, false),
  })
  W.view_block(nbL, cellA, { data = { [VIEW] = { model_id = UP, version_major = 2, version_minor = 0 } } })

  -- the caller's state holds vim.NIL in the slot the bytes go to, as a JSON null does
  local caller = { data = { vim.NIL } }
  local before = vim.inspect(caller)
  local res
  check("set on a live model is accepted and sent once, its binary slot null in state", function()
    res = with_client(function()
      return W.set(nbL, UP, caller, { buffer_paths = { { "data", 0 } }, buffers = { BYTES } })
    end)
    local c = sent[1]
    return res == true and #sent == 1 and c.method == "widget_update"
      and rawequal(c.params.state.data[1], vim.NIL) and #c.params.buffers == 1 and c.params.buffers[1] == BYTES
      and c.params.buffer_paths[1][1] == "data" and c.params.buffer_paths[1][2] == 0
      and c.params.session_id == LIVE and c.params.model_id == UP,
      "res " .. tostring(res) .. " sent " .. vim.inspect(sent)
  end)

  check("set on a live model leaves the caller's own table unchanged", function()
    return vim.inspect(caller) == before and rawequal(caller.data[1], vim.NIL),
      "caller " .. vim.inspect(caller)
  end)

  check("set on a live model keeps the bytes at the buffer path in the mirror", function()
    local e = W.get(LIVE, UP)
    return e ~= nil and e.state.data[1] == BYTES and #e.buffer_paths == 1 and e.buffer_paths[1][2] == 0,
      "mirror " .. vim.inspect(e and e.state)
  end)

  check("set with an empty state sends an empty map, to the cell that shows the model", function()
    local r = with_client(function() return W.set(nbL, UP, {}) end)
    local c = sent[1]
    return r == true and c ~= nil and vim.mpack.encode(c.params.state) == "\128" and c.params.cell_id == "cellA",
      "res " .. tostring(r) .. " sent " .. vim.inspect(sent)
  end)

  check("custom on a live model sends content and buffers, the cell id defaults, no state change", function()
    local state_before = vim.inspect(W.get(LIVE, UP).state)
    local r = with_client(function() return W.custom(nbL, UP, { event = "click" }, { buffers = { BYTES } }) end)
    local c = sent[1]
    return r == true and c ~= nil and c.method == "widget_custom" and c.params.model_id == UP
      and c.params.content.event == "click" and c.params.buffers[1] == BYTES and c.params.cell_id == "cellA"
      and vim.inspect(W.get(LIVE, UP).state) == state_before,
      "res " .. tostring(r) .. " sent " .. vim.inspect(sent)
  end)

  check("custom with no content sends an empty map", function()
    local r = with_client(function() return W.custom(nbL, UP, nil) end)
    local c = sent[1]
    return r == true and c ~= nil and vim.mpack.encode(c.params.content) == "\128",
      "res " .. tostring(r) .. " sent " .. vim.inspect(sent)
  end)

  check("set and custom on a dead or unknown model send nothing and warn", function()
    local rs, ms = notify_capture(function()
      return with_client(function()
        return { W.set(nbL, DEAD, { value = "x" }), W.custom(nbL, DEAD, {}), W.set(nbL, "no-such-model", {}) }
      end)
    end)
    return rs[1] == false and rs[2] == false and rs[3] == false and #sent == 0 and #ms == 3
      and ms[1]:find("not connected to a kernel", 1, true) ~= nil,
      "results " .. vim.inspect(rs) .. " sent " .. #sent .. " msgs " .. #ms
  end)

  -- Hashes and ticks of the notebook buffer. A redraw's sync runs on a 150 ms
  -- timer; every buffer write advances changedtick (a no-op write too), so a later
  -- tick is the sync having run.
  local function a2_hash(b)
    return vim.fn.sha256(table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n"))
  end
  local function a2_rev(cell) return cell._widget_rev or 0 end

  -- a real notebook (no backend) whose cells show models, for the dependency index.
  -- cellD shows DEP; cellO a view of an Output widget (OUTM); cellS a live slider
  -- (SLM); cellL a live label (LBL); cellP a plain code cell; cellX a view of CLS,
  -- the last cell, which the V6 check removes through the notebook's own sync.
  local nbuf = vim.api.nvim_create_buf(false, true)
  vim.bo[nbuf].buftype = "acwrite"
  vim.bo[nbuf].swapfile = false
  vim.api.nvim_set_current_buf(nbuf)
  local OUTM, SLM, LBL, CLS = "a2-output", "a2-slider", "a2-label", "a2-cls"
  local function a2_view(id, mid, text)
    return { id = id, cell_type = "code", source = id, metadata = vim.empty_dict(), execution_count = 1,
      outputs = { { output_type = "execute_result", execution_count = 1, metadata = vim.empty_dict(),
        data = { ["text/plain"] = text, [VIEW] = { model_id = mid, version_major = 2, version_minor = 0 } } } } }
  end
  local nbD = NB.create(nbuf, "widget-spec-dep.ipynb", DEPSID, {
    cells = { { id = "cellD", cell_type = "code", source = "1 + 1", metadata = vim.empty_dict(),
      execution_count = 1, outputs = { { output_type = "execute_result", execution_count = 1,
        metadata = vim.empty_dict(), data = { ["text/plain"] = "Label(value='a')",
          [VIEW] = { model_id = DEP, version_major = 2, version_minor = 0 } } } } },
      a2_view("cellO", OUTM, "Output()"),
      a2_view("cellS", SLM, "IntSlider(value=3)"),
      a2_view("cellL", LBL, "Label(value='a')"),
      { id = "cellP", cell_type = "code", source = "x = 1", metadata = vim.empty_dict(),
        execution_count = vim.NIL, outputs = {} },
      a2_view("cellX", CLS, "Label(value='x')") },
    widgets = {
      model_entry(DEP, "LabelModel", { value = "a" }, true),
      { model_id = OUTM, model_name = "OutputModel", model_module = "@jupyter-widgets/output",
        model_module_version = "1.0.0", state = { msg_id = "", outputs = {} }, buffers = {}, live = true },
      model_entry(SLM, "IntSliderModel", { value = 3, min = 0, max = 10, step = 1, description = "Level" }, true),
      model_entry(LBL, "LabelModel", { value = "a" }, true),
      model_entry(CLS, "LabelModel", { value = "x" }, true),
    },
  })
  J._populate_buffer(nbD)
  -- the save baseline J.open sets after the populate
  nbD.saved_hash = a2_hash(nbuf)
  vim.bo[nbuf].modified = false
  local function clean_now()
    return not vim.bo[nbuf].modified and nbD.saved_hash == a2_hash(nbuf)
  end
  local function baseline()
    nbD.saved_hash = a2_hash(nbuf)
    vim.bo[nbuf].modified = false
  end
  local cellD, cellO, cellS, cellL, cellP, cellX = nbD.cells[1], nbD.cells[2], nbD.cells[3],
    nbD.cells[4], nbD.cells[5], nbD.cells[6]

  check("dependency: an update to the model a cell shows redraws that cell", function()
    W.handle_event({ session_id = DEPSID, event = { kind = "update", model_id = DEP,
      state = { value = "b" }, buffer_paths = {} }, buffers = {} })
    vim.wait(3000, function() return (cellD._widget_rev or 0) == 1 end)
    return (cellD._widget_rev or 0) == 1, "rev " .. tostring(cellD._widget_rev)
  end)

  check("W.begin drops the dependency: the next update leaves the cell alone", function()
    W.begin(cellD)
    W.handle_event({ session_id = DEPSID, event = { kind = "update", model_id = DEP,
      state = { value = "c" }, buffer_paths = {} }, buffers = {} })
    vim.wait(400)
    return cellD._widget_rev == 1, "rev " .. tostring(cellD._widget_rev)
  end)

  -- V1: a widget redraw and a plain sync of another cell in one window end modified,
  -- in both orders (the queue keeps a buffer clean only while every request asks)
  check("V1: a widget update, then a plain sync of another cell in one window, ends modified", function()
    baseline()
    local t0, r0 = vim.api.nvim_buf_get_changedtick(nbuf), a2_rev(cellL)
    send(DEPSID, { kind = "update", model_id = LBL, state = { value = "v1a" }, buffer_paths = {} })
    J._queue_output_sync(nbuf, nbD, cellP.id)
    vim.wait(3000, function() return vim.api.nvim_buf_get_changedtick(nbuf) > t0 end)
    return a2_rev(cellL) == r0 + 1 and vim.bo[nbuf].modified == true,
      "rev " .. a2_rev(cellL) .. " modified " .. tostring(vim.bo[nbuf].modified)
  end)

  check("V1: a plain sync of another cell, then a widget update, in one window, ends modified", function()
    baseline()
    local t0, r0 = vim.api.nvim_buf_get_changedtick(nbuf), a2_rev(cellL)
    J._queue_output_sync(nbuf, nbD, cellP.id)
    send(DEPSID, { kind = "update", model_id = LBL, state = { value = "v1b" }, buffer_paths = {} })
    vim.wait(3000, function() return vim.api.nvim_buf_get_changedtick(nbuf) > t0 end)
    return a2_rev(cellL) == r0 + 1 and vim.bo[nbuf].modified == true,
      "rev " .. a2_rev(cellL) .. " modified " .. tostring(vim.bo[nbuf].modified)
  end)

  -- V2: once a plain sync has run, the queue is back to keeping a clean buffer clean
  check("V2: after a plain sync has run, a widget update keeps a clean buffer clean", function()
    baseline()
    local t0 = vim.api.nvim_buf_get_changedtick(nbuf)
    J._queue_output_sync(nbuf, nbD, cellP.id)
    vim.wait(3000, function() return vim.api.nvim_buf_get_changedtick(nbuf) > t0 end)
    baseline()
    local t1, r0 = vim.api.nvim_buf_get_changedtick(nbuf), a2_rev(cellL)
    send(DEPSID, { kind = "update", model_id = LBL, state = { value = "v2" }, buffer_paths = {} })
    vim.wait(3000, function()
      return vim.api.nvim_buf_get_changedtick(nbuf) > t1 and a2_rev(cellL) == r0 + 1
    end)
    return a2_rev(cellL) == r0 + 1 and clean_now(),
      "rev " .. a2_rev(cellL) .. " modified " .. tostring(vim.bo[nbuf].modified)
  end)

  -- V5: a W.set on a live model shown by a cell bumps the cell before the call's reply
  -- (the stub client never answers, so the bump is all that can have happened)
  check("V5: W.set on a live model bumps its cell's revision before any reply", function()
    baseline()
    local t0, r0 = vim.api.nvim_buf_get_changedtick(nbuf), a2_rev(cellS)
    local res = with_client(function() return W.set(nbD, SLM, { value = 7 }) end)
    local bumped = a2_rev(cellS) == r0 + 1
    local one_send = #sent == 1 and sent[1].method == "widget_update" and sent[1].params.cell_id == "cellS"
    vim.wait(3000, function() return vim.api.nvim_buf_get_changedtick(nbuf) > t0 end)
    return res == true and bumped and one_send and clean_now(),
      "res " .. tostring(res) .. " rev " .. a2_rev(cellS) .. " sent " .. vim.inspect(sent)
  end)

  -- V4: a close bumps the cell that shows the model, leaves a tombstone, keeps the buffer clean
  check("V4: a close event bumps the cell that shows the model, leaves a tombstone, buffer clean", function()
    baseline()
    local t0, r0 = vim.api.nvim_buf_get_changedtick(nbuf), a2_rev(cellS)
    send(DEPSID, { kind = "close", model_id = SLM })
    vim.wait(3000, function()
      return vim.api.nvim_buf_get_changedtick(nbuf) > t0 and a2_rev(cellS) == r0 + 1
    end)
    local e = W.get(DEPSID, SLM)
    return a2_rev(cellS) == r0 + 1 and e ~= nil and e.closed == true and clean_now(),
      "rev " .. a2_rev(cellS) .. " entry " .. vim.inspect(e)
  end)

  -- V8: an output event of an Output widget bumps the cell that shows it, buffer clean
  check("V8: an output event of an Output widget bumps the cell that shows it, buffer clean", function()
    baseline()
    local t0, r0 = vim.api.nvim_buf_get_changedtick(nbuf), a2_rev(cellO)
    send(DEPSID, { kind = "output", model_id = OUTM,
      event = { kind = "stream", name = "stdout", text = "v8\n" } })
    vim.wait(3000, function()
      return vim.api.nvim_buf_get_changedtick(nbuf) > t0 and a2_rev(cellO) == r0 + 1
    end)
    local outs = W.get(DEPSID, OUTM).state.outputs
    return a2_rev(cellO) == r0 + 1 and #outs == 1 and outs[1].text == "v8\n" and clean_now(),
      "rev " .. a2_rev(cellO) .. " outputs " .. vim.inspect(outs)
  end)

  -- V10: an execute_result event sets the cell's execution count
  check("V10: an execute_result event sets the cell's execution_count", function()
    nbD:apply_cell_event(cellP.id, { kind = "execute_result", execution_count = 7,
      data = { ["text/plain"] = "1" } })
    return cellP.execution_count == 7, "execution_count " .. tostring(cellP.execution_count)
  end)

  -- V9: a keep-clean sync conceals the output marker of the rows it rewrites. Populate
  -- conceals every marker already, so the namespace is cleared first: only the
  -- sync's own conceal can satisfy the check.
  -- Two cells in one sync (a reset, or a model shown by several cells, redraws many
  -- cells at once): each rewritten region's marker must be concealed, not only the first.
  check("V9: a keep-clean sync conceals the output marker of every row it rewrites, also one that moves", function()
    baseline()
    vim.api.nvim_buf_clear_namespace(nbuf, nbD.border_ns, 0, -1)
    -- cellO's region grows by a row first (a second stream in its Output widget), so
    -- cellL's marker moves down in the sync: the conceal must use the rows after the
    -- rewrite, not the rows read before it.
    send(DEPSID, { kind = "output", model_id = OUTM,
      event = { kind = "stream", name = "stderr", text = "v9\n" } })
    local before = require("jupynvim.notebook.cellmode").ranges(nbuf)
    J._sync_keep_clean(nbD, { [cellO.id] = true, [cellL.id] = true })
    local ranges = require("jupynvim.notebook.cellmode").ranges(nbuf)
    local _, iL = nbD:get_cell(cellL.id)
    local moved = (before[iL] ~= nil and ranges[iL] ~= nil and before[iL].out_sep ~= ranges[iL].out_sep) or false
    local function concealed_at(c)
      local _, i = nbD:get_cell(c.id)
      local r = i and ranges[i]
      if not (r and r.out_sep) then return false end
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(nbuf, nbD.border_ns, { r.out_sep, 0 },
          { r.out_sep, -1 }, { details = true })) do
        if m[4] and m[4].conceal == "" then return true end
      end
      return false
    end
    local o, l = concealed_at(cellO), concealed_at(cellL)
    -- the sync that the output event queued runs too: wait for it, so later checks start settled
    local t1 = vim.api.nvim_buf_get_changedtick(nbuf)
    vim.wait(3000, function() return vim.api.nvim_buf_get_changedtick(nbuf) > t1 end)
    return o and l and moved and clean_now(),
      "cellO " .. tostring(o) .. " cellL " .. tostring(l) .. " moved " .. tostring(moved)
  end)

  -- V3: a reset kills the models and leaves the views alone. The text form does not
  -- read the live flag, so no cell is redrawn: no revision moves, the buffer is not
  -- written and no view is rendered.
  check("V3: a reset event kills the models and redraws no cell, the buffer is untouched", function()
    baseline()
    local t0, r0, renders0 = vim.api.nvim_buf_get_changedtick(nbuf), a2_rev(cellO), W.stats.renders
    send(DEPSID, { kind = "reset" })
    vim.wait(600)
    local e = W.get(DEPSID, OUTM)
    return a2_rev(cellO) == r0 and vim.api.nvim_buf_get_changedtick(nbuf) == t0
        and W.stats.renders == renders0 and e ~= nil and e.live == false and clean_now(),
      "rev " .. a2_rev(cellO) .. " (was " .. r0 .. ") renders " .. W.stats.renders .. " (was " .. renders0
        .. ") live " .. tostring(e and e.live)
  end)

  -- V7: W.load of an Output model whose image has line breaks holds the normalized value
  check("V7: W.load of an Output model whose image/png has line breaks gives the normalized value", function()
    baseline()
    local t0 = vim.api.nvim_buf_get_changedtick(nbuf)
    local raw = "iVBO\nRw0K\r\n"
    W.load(DEPSID, { { model_id = OUTM, model_name = "OutputModel", model_module = "@jupyter-widgets/output",
      model_module_version = "1.0.0", live = false, buffers = {},
      state = { msg_id = "", outputs = { { output_type = "display_data", metadata = vim.empty_dict(),
        data = { ["image/png"] = raw, ["text/plain"] = "<Figure>" } } } } } })
    vim.wait(3000, function() return vim.api.nvim_buf_get_changedtick(nbuf) > t0 end)
    local want = { ["image/png"] = raw }
    NB.normalize_output_data(want)
    local got = W.get(DEPSID, OUTM).state.outputs[1].data["image/png"]
    return got == want["image/png"] and got == "iVBORw0K", "got " .. vim.inspect(got)
      .. " want " .. vim.inspect(want["image/png"])
  end)

  -- V11: a W.load into the session again bumps the cells that already show a loaded model
  check("V11: W.load again bumps the cells that already show a loaded model, buffer clean", function()
    baseline()
    local t0, r0 = vim.api.nvim_buf_get_changedtick(nbuf), a2_rev(cellO)
    W.load(DEPSID, {
      { model_id = OUTM, model_name = "OutputModel", model_module = "@jupyter-widgets/output",
        model_module_version = "1.0.0", live = true, buffers = {}, state = { msg_id = "", outputs = {} } },
      model_entry(LBL, "LabelModel", { value = "a" }, true),
      model_entry(CLS, "LabelModel", { value = "x" }, true),
    })
    vim.wait(3000, function()
      return vim.api.nvim_buf_get_changedtick(nbuf) > t0 and a2_rev(cellO) == r0 + 1
    end)
    return a2_rev(cellO) == r0 + 1 and clean_now(), "rev " .. a2_rev(cellO) .. " modified "
      .. tostring(vim.bo[nbuf].modified)
  end)

  -- V6: cellX leaves the notebook through the notebook's own sync from its buffer lines:
  -- the buffer without its last cell is read back, which drops that cell from nb.cells.
  -- The buffer is then populated again from the cells that remain.
  do
    local lines = nbD:to_lines()
    local cut
    for i = #lines, 1, -1 do
      if lines[i] == NB.CELL_SEP then cut = i; break end
    end
    nbD:sync_from_buffer(vim.list_slice(lines, 1, cut - 1))
    J._populate_buffer(nbD)
    baseline()
  end
  -- a negative check: the event must not redraw the removed cell, and must not raise
  check("V6: an event of a model shown by a removed cell does not bump that cell, no error", function()
    local before = a2_rev(cellX)
    local t0 = vim.api.nvim_buf_get_changedtick(nbuf)
    local ok, err = pcall(send, DEPSID, { kind = "update", model_id = CLS, state = { value = "gone" },
      buffer_paths = {} })
    vim.wait(400)
    return ok and a2_rev(cellX) == before and vim.api.nvim_buf_get_changedtick(nbuf) == t0
      and nbD:get_cell(cellX.id) == nil,
      "ok " .. tostring(ok) .. " " .. tostring(err) .. " rev " .. a2_rev(cellX) .. " cells " .. #nbD.cells
  end)

  -- It reads OUTM, which the mirror holds here (V11 loaded it), and requires it there
  -- before the remove: V7 and V11 replace the session's models, so DEP has already
  -- left the mirror when this check runs, and checking DEP alone would pass without
  -- the remove dropping anything.
  check("NB.remove drops the session's mirror", function()
    local had = W.get(DEPSID, OUTM) ~= nil
    NB.remove(nbuf)
    pcall(vim.api.nvim_buf_delete, nbuf, { force = true })
    return had and W.get(DEPSID, OUTM) == nil,
      "had " .. tostring(had) .. " entry " .. vim.inspect(W.get(DEPSID, OUTM))
  end)
end

local ok2, err2 = xpcall(a2_run, debug.traceback)
if not ok2 then chk("section A2 ran to the end", false, err2) end

-- ── B. the real backend, no kernel ──────────────────────
io.write("B. the mirror on the real backend, no kernel\n")
local SLIDER = "5a1d0f3c2b4e4a6f8c9d0e1f2a3b4c5d"
local LAYOUT = "6b2e1a4d3c5f4b7a9d0e1f2a3b4c5d6e"
local STYLE = "7c3f2b5e4d6a4c8b0e1f2a3b4c5d6e7f"
local tmp = vim.fn.tempname() .. ".ipynb"
local client, sid, buf, nb

local function cell(id, source, outputs)
  return { id = id, cell_type = "code", source = source, metadata = vim.empty_dict(),
    execution_count = #outputs > 0 and 1 or vim.NIL, outputs = outputs }
end

local function text_hash(b)
  return vim.fn.sha256(table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n"))
end

local function b_run()
  J.setup({ core_path = vim.env.JUPYNVIM_TEST_CORE, auto_install = false, log_level = "warn" })
  local nbjson = {
    nbformat = 4, nbformat_minor = 5,
    metadata = {
      kernelspec = { name = "python3", display_name = "Python 3", language = "python" },
      widgets = { [STATE] = { version_major = 2, version_minor = 0, state = {
        [LAYOUT] = { model_name = "LayoutModel", model_module = "@jupyter-widgets/base",
          model_module_version = "2.0.0", state = {
            _model_name = "LayoutModel", _model_module = "@jupyter-widgets/base",
            _model_module_version = "2.0.0", _view_name = "LayoutView",
            _view_module = "@jupyter-widgets/base", _view_module_version = "2.0.0",
            visibility = vim.NIL, width = vim.NIL } },
        [STYLE] = { model_name = "SliderStyleModel", model_module = "@jupyter-widgets/controls",
          model_module_version = "2.0.0", state = {
            _model_name = "SliderStyleModel", _model_module = "@jupyter-widgets/controls",
            _model_module_version = "2.0.0", _view_name = "StyleView",
            _view_module = "@jupyter-widgets/base", _view_module_version = "2.0.0",
            description_width = "", handle_color = vim.NIL } },
        [SLIDER] = { model_name = "IntSliderModel", model_module = "@jupyter-widgets/controls",
          model_module_version = "2.0.0", state = {
            _model_name = "IntSliderModel", _model_module = "@jupyter-widgets/controls",
            _model_module_version = "2.0.0", _view_name = "IntSliderView",
            _view_module = "@jupyter-widgets/controls", _view_module_version = "2.0.0",
            value = 3, min = 0, max = 10, step = 1, description = "Level", disabled = false,
            orientation = "horizontal", readout = true, readout_format = "d",
            continuous_update = true, layout = "IPY_MODEL_" .. LAYOUT, style = "IPY_MODEL_" .. STYLE } },
      } } },
    },
    cells = {
      cell("show", "slider", { { output_type = "execute_result", execution_count = 1,
        metadata = vim.empty_dict(),
        data = { ["text/plain"] = "IntSlider(value=3, description='Level', max=10)",
          [VIEW] = { model_id = SLIDER, version_major = 2, version_minor = 0 } } } }),
      cell("other", "print(1)", {}),
    },
  }
  local f = assert(io.open(tmp, "w"))
  f:write(vim.json.encode(nbjson))
  f:close()

  client = J._ensure_client()
  local open_err, result = client:call_sync("open", { path = tmp })
  assert(not open_err, tostring(open_err))
  sid = result.session_id
  buf = vim.api.nvim_create_buf(false, true)
  -- A notebook buffer is acwrite, as M.open makes it. A scratch buffer is
  -- nofile, and Neovim keeps no modified flag on one, so the control would
  -- prove nothing.
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].swapfile = false
  vim.api.nvim_set_current_buf(buf)
  nb = NB.create(buf, tmp, sid, result.snapshot)
  J._populate_buffer(nb)
  J._save(nb)

  local show, other = nb.cells[1], nb.cells[2]

  check("B: the saved state loads as a dead slider with its saved value", function()
    local e = W.get(sid, SLIDER)
    return e ~= nil and e.live == false and e.state.value == 3 and e.name == "IntSliderModel",
      "entry " .. vim.inspect(e)
  end)

  check("B: the saved buffer is clean and its hash is the text's", function()
    return not vim.bo[buf].modified and nb.saved_hash == text_hash(buf),
      "modified " .. tostring(vim.bo[buf].modified)
  end)

  check("B: the widget cell starts with no redraw", function()
    return (show._widget_rev or 0) == 0, "rev " .. tostring(show._widget_rev)
  end)

  check("B: a slider update redraws its cell and leaves the buffer clean", function()
    local renders = W.stats.renders
    W.handle_event({ session_id = sid, event = { kind = "update", model_id = SLIDER,
      state = { value = 5 }, buffer_paths = {} }, buffers = {} })
    -- the checked conditions, waited for: the redraw's sync rebuilds the cell
    vim.wait(3000, function()
      return W.get(sid, SLIDER).state.value == 5 and show._widget_rev == 1 and W.stats.renders > renders
        and not vim.bo[buf].modified and nb.saved_hash == text_hash(buf)
    end)
    local value_ok = W.get(sid, SLIDER).state.value == 5
    local rev_ok = show._widget_rev == 1
    -- the cell's output was built again, not served from the cache
    local rebuilt_ok = W.stats.renders > renders
    local clean_ok = not vim.bo[buf].modified and nb.saved_hash == text_hash(buf)
    return value_ok and rev_ok and rebuilt_ok and clean_ok,
      "value " .. tostring(W.get(sid, SLIDER).state.value) .. " rev " .. tostring(show._widget_rev)
      .. " rebuilt " .. tostring(rebuilt_ok) .. " modified " .. tostring(vim.bo[buf].modified)
  end)

  check("B: the widget cell shows its text form after the redraw (value 5 of 0..10)", function()
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    return text:find("Level " .. S10 .. " 5", 1, true) ~= nil, "buffer has no widget text"
  end)

  check("B: a layout update redraws the cell too (the view reaches its layout)", function()
    local renders = W.stats.renders
    W.handle_event({ session_id = sid, event = { kind = "update", model_id = LAYOUT,
      state = { visibility = "hidden" }, buffer_paths = {} }, buffers = {} })
    vim.wait(3000, function()
      return show._widget_rev == 2 and W.stats.renders > renders and not vim.bo[buf].modified
        and nb.saved_hash == text_hash(buf)
    end)
    return show._widget_rev == 2 and not vim.bo[buf].modified and nb.saved_hash == text_hash(buf),
      "rev " .. tostring(show._widget_rev) .. " modified " .. tostring(vim.bo[buf].modified)
  end)

  check("B: a stream on the other cell makes the buffer modified, the widget cell keeps its revision", function()
    local tick0 = vim.api.nvim_buf_get_changedtick(buf)
    J._handle_cell_event({ session_id = sid, cell_id = other.id,
      event = { kind = "stream", name = "stdout", text = "hi\n" } })
    vim.wait(3000, function()
      return vim.bo[buf].modified == true and show._widget_rev == 2
        and vim.api.nvim_buf_get_changedtick(buf) > tick0
    end)
    return vim.bo[buf].modified == true and show._widget_rev == 2,
      "modified " .. tostring(vim.bo[buf].modified) .. " rev " .. tostring(show._widget_rev)
  end)

  check("B: set on the dead slider is refused: not connected to a kernel", function()
    local res, msgs = notify_capture(function() return W.set(nb, SLIDER, { value = 7 }) end)
    local said = msgs[1] ~= nil and msgs[1]:find("not connected to a kernel", 1, true) ~= nil
    return res == false and said and W.get(sid, SLIDER).state.value == 5,
      "result " .. tostring(res) .. " msgs " .. vim.inspect(msgs)
  end)
end

local ok, err = xpcall(b_run, debug.traceback)
if not ok then chk("section B ran to the end", false, err) end

-- ── C. the saved gallery, no kernel ──────────────────────
io.write("C. the saved gallery shows its widgets as text, with no kernel\n")
local here = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or "tests"
local GALLERY = here .. "/fixtures/widgets_gallery_saved.ipynb"
local CELLMODE = require("jupynvim.notebook.cellmode")
local RENDER = require("jupynvim.notebook.render")
-- Every row below is worked out from the text form rules and the saved states
-- of tests/fixtures/widgets_gallery_saved.ipynb, by hand. A slider's track
-- position p is floor(frac * 19 + 0.5) with frac = (value - min) / (max - min),
-- each as saved; a progress bar has frac * 25 full cells and a partial one.
-- Two that are easy to get wrong: the label's FloatSlider keeps the default
-- max 100, so frac is 0.01 and p is 0; the accordion's and disabled slider's
-- values are 0 and 4 of 0..100 (p = 0 and p = 1).
local GALLERY_ROWS = {
  intslider = { "IntSlider " .. S13 .. " 7" },
  floatslider = { "FloatSlider " .. S14 .. " 7.5" },
  floatlogslider = { "FloatLogSlider " .. S10 .. " 10" },
  intrangeslider = { "IntRange " .. R10_13 .. " 5 - 7" },
  floatrangeslider = { "FloatRange " .. R10_14 .. " 5.0 - 7.5" },
  verticalslider = { "Vertical " .. S6 .. " 3 VRange " .. R4_11 .. " 2.00 - 6.00" },
  selectionslider = { "I like my eggs " .. S6 .. " sunny side up" },
  selectionrangeslider = { "Months " .. R3_14 .. " Mar 2026 - Aug 2026" },
  intprogress = { "default " .. P07, "success " .. P07, "info " .. P07, "warning " .. P07, "danger " .. P07 },
  floatprogress = { "default " .. P033, "success " .. P05, "info " .. P065, "warning " .. P08,
    "danger " .. P095, "vertical " .. P06 },
  boundedinttext = { "BoundedInt [7]" },
  boundedfloattext = { "BoundedFloat [7.5]" },
  inttext = { "IntText [7]" },
  floattext = { "FloatText [7.5]" },
  togglebutton = { "[ ] Toggle off [x] Toggle on" },
  checkbox = { "[ ] Checkbox off", "[x] Checkbox on", "[x] Checkbox indent=False" },
  valid = { "Valid True ✓", "Valid False ✗ Bad input" },
  dropdown = { "Dropdown [2 v]" },
  radiobuttons = { "Pizza topping ( ) pepperoni  (*) pineapple  ( ) anchovies" },
  select = { "Select OS [macOS]" },
  selectmultiple = { "Fruits [Oranges, Pears]" },
  togglebuttons = { "Speed [ Slow ] [*Regular*] [ Fast ]" },
  text = { "Text [Hello World]" },
  textarea = { "Textarea Line one", "         Line two", "         Line three" },
  combobox = { "Combobox [Choose Someone]" },
  password = { "Password [********]" },
  label = { "Label: The $m$ in $E=mc^2$: m " .. S0 .. " 1.00" },
  html = { "HTML Hello World italic red" },
  htmlmath = { "HTMLMath Some math and HTML: \\(x^2\\) and $$\\frac{x+1}{x-1}$$" },
  image = { "[image png 726 bytes]" },
  button = { "[ default ] [ primary ] [ success ] [ info ] [ warning ] [ danger ]" },
  play = { "Press play > 50 " .. S10 .. " 50" },
  datepicker = { "Pick a Date [2026-10-22]" },
  timepicker = { "Time [14:30]" },
  datetimepicker = { "Datetime [2026-10-22 14:30]", "Naive [2026-10-22 14:30]" },
  colorpicker = { "Pick a color blue", "Concise #ff8800" },
  tagsinput = { "[pizza, fries]" },
  colorsinput = { "[red, #2f6d30, cornflowerblue]" },
  intsinput = { "[1, 4, 3243]", "[1.30, 4.56, 78.90]" },
  fileupload = { "[ Upload ]" },
  controller = { "Controller 0" },
  box = { "Box: [ A ] [ B ]" },
  hbox = { "0 1 2 3" },
  vbox = { "0", "1", "2", "3" },
  gridbox = { "[ cell 0 ]", "[ cell 1 ]", "[ cell 2 ]", "[ cell 3 ]",
    "[ cell 4 ]", "[ cell 5 ]", "[ cell 6 ]", "[ cell 7 ]" },
  accordion = { "▾ Slider", "  inside " .. S0 .. " 0", "▸ Text" },
  tab = { "[Tab 0] | Tab 1 | Tab 2", "Name [tab 0]" },
  stack = { "Stack shows [button v]", "[ click here ]" },
  applayout = { "[ Header ]", "[ Footer ]", "[ Left ]", "[ Right ]", "[ Center ]" },
  gridspeclayout = { "[ top row ]", "[ left col ]", "[ big ]" },
  output = { "printed inside an Output widget" },
  interact = { "x " .. S10 .. " 5", "color [green v]", "x=5 squared=25 color=green" },
  tqdm = {
    "tqdm.notebook done: 100% " .. P10 .. "  40/40 [00:00<00:00, 72.12it/s]",
    "tqdm.auto partial:  60% " .. P06 .. "  60/100 [00:00<00:00, 10094.59it/s]",
  },
  disabled = { "slider " .. S1 .. " 4", "text [disabled text]", "[ button ]", "dropdown [a v]",
    "[x] checkbox", "toggles [*x*] [ y ]", "progress " .. P05 },
  customstyle = { "Wide description width " .. S1 .. " 5", "[ Custom color ]",
    "Styled [60% wide, dashed border]", "Bar color " .. P07, "HTML with style", "[*a*] [ b ] [ c ]" },
}

-- The bar cells of the gallery: output row, the text before the bar, the bar
-- itself, and the highlight group of its span.
local GALLERY_BARS = {
  intprogress = {
    { 1, "default ", P07, "JupynvimWidgetBar" }, { 2, "success ", P07, "JupynvimWidgetBarSuccess" },
    { 3, "info ", P07, "JupynvimWidgetBarInfo" }, { 4, "warning ", P07, "JupynvimWidgetBarWarning" },
    { 5, "danger ", P07, "JupynvimWidgetBarDanger" },
  },
  floatprogress = {
    { 1, "default ", P033, "JupynvimWidgetBar" }, { 2, "success ", P05, "JupynvimWidgetBarSuccess" },
    { 3, "info ", P065, "JupynvimWidgetBarInfo" }, { 4, "warning ", P08, "JupynvimWidgetBarWarning" },
    { 5, "danger ", P095, "JupynvimWidgetBarDanger" }, { 6, "vertical ", P06, "JupynvimWidgetBar" },
  },
  tqdm = {
    { 1, "tqdm.notebook done: 100% ", P10, "JupynvimWidgetBarSuccess" },
    { 2, "tqdm.auto partial:  60% ", P06, "JupynvimWidgetBar" },
  },
  disabled = { { 7, "progress ", P05, "JupynvimWidgetBar" } },
  customstyle = { { 4, "Bar color ", P07, "JupynvimWidgetBar_e91e63" } },
}

local function copy_to_temp(src)
  local f = assert(io.open(src, "rb"))
  local bytes = f:read("*a")
  f:close()
  local path = vim.fn.tempname() .. ".ipynb"
  local o = assert(io.open(path, "wb"))
  o:write(bytes)
  o:close()
  return path
end

-- A notebook opened from the backend with no kernel, rendered as a window shows it.
local function open_saved(path)
  local err, res = client:call_sync("open", { path = path }, 20000)
  assert(not err, tostring(err))
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].buftype = "acwrite"
  vim.bo[b].swapfile = false
  vim.api.nvim_set_current_buf(b)
  local n = NB.create(b, path, res.session_id, res.snapshot)
  J._populate_buffer(n)
  RENDER.refresh_sync(n, vim.fn.bufwinid(b))
  return n, b, res.session_id
end

local function tag_of(cell)
  return (cell.source or ""):match("^# W:(%S+)")
end

-- The buffer rows under cell i's output (the rows, not the header), and its range.
local function output_rows(b, i)
  local r = CELLMODE.ranges(b)[i]
  if not (r and r.out_sep) then return {}, nil end
  return vim.api.nvim_buf_get_lines(b, r.out_sep + 1, r.out_stop, false), r
end

local function indented(rows)
  local out = {}
  for k, l in ipairs(rows) do out[k] = "  " .. l end
  return out
end

-- Every bar span in the render namespace: row, byte column, end column, group.
local function bar_spans(b, nbx)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(b, nbx.border_ns, 0, -1, { details = true })) do
    local hl = m[4].hl_group
    if type(hl) == "string" and hl:find("^JupynvimWidgetBar") then
      out[#out + 1] = { row = m[2], col = m[3], end_col = m[4].end_col, group = hl }
    end
  end
  return out
end

local function span_key(s)
  return s.row .. ":" .. s.col .. ":" .. s.end_col .. ":" .. s.group
end

local function c_run()
  local gpath = copy_to_temp(GALLERY)
  local gn, gb, gsid = open_saved(gpath)
  os.remove(gpath)

  local by_tag, tags = {}, {}
  for i, c in ipairs(gn.cells) do
    local t = tag_of(c)
    if t then
      by_tag[t] = i
      tags[#tags + 1] = t
    end
  end
  table.sort(tags)

  local want_count = 0
  for _ in pairs(GALLERY_ROWS) do want_count = want_count + 1 end
  local shown_count = 0
  for _, t in ipairs(tags) do
    if GALLERY_ROWS[t] then shown_count = shown_count + 1 end
  end
  chk("C: the gallery has every widget cell the table names, and no other",
    shown_count == want_count and #tags == want_count + 2,
    ("tagged %d, named %d, table %d"):format(#tags, shown_count, want_count))

  -- No row of any cell holds a line break: the buffer would refuse it.
  local breaks = {}
  for i, c in ipairs(gn.cells) do
    for _, row in ipairs(NB.output_lines(c)) do
      if row:find("\n", 1, true) then breaks[#breaks + 1] = i .. ": " .. vim.inspect(row) end
    end
  end
  chk("C: no output row of the gallery holds a line break", #breaks == 0, table.concat(breaks, "; "))

  for _, t in ipairs(tags) do
    if GALLERY_ROWS[t] then
      local rows = output_rows(gb, by_tag[t])
      local want = indented(GALLERY_ROWS[t])
      chk("C: " .. t .. " shows its saved view as text, with no kernel",
        vim.deep_equal(rows, want),
        "got " .. vim.inspect(rows) .. " want " .. vim.inspect(want))
    end
  end

  -- The bar spans: each bar of the table is one span over exactly its bar, in
  -- its output row, and the namespace holds no other bar span.
  local want_spans = {}
  for t, list in pairs(GALLERY_BARS) do
    local rows, r = output_rows(gb, by_tag[t])
    for _, s in ipairs(list) do
      local k, prefix, bar, group = s[1], s[2], s[3], s[4]
      local col = 2 + #prefix
      local line = rows[k] or ""
      -- the bar's own bytes sit at the column; a tqdm row has more text after them
      chk("C: " .. t .. " row " .. k .. " holds its bar text",
        line:sub(col + 1, col + #bar) == bar, "row " .. vim.inspect(line))
      want_spans[#want_spans + 1] = { row = r.out_sep + k, col = col, end_col = col + #bar,
        group = group }
    end
  end
  local got = bar_spans(gb, gn)
  local want_keys, got_keys = {}, {}
  for _, s in ipairs(want_spans) do want_keys[#want_keys + 1] = span_key(s) end
  for _, s in ipairs(got) do got_keys[#got_keys + 1] = span_key(s) end
  table.sort(want_keys)
  table.sort(got_keys)
  chk("C: the bar spans are the table's, one per bar, none outside an output region",
    vim.deep_equal(want_keys, got_keys),
    "want " .. vim.inspect(want_keys) .. " got " .. vim.inspect(got_keys))

  local hl = vim.api.nvim_get_hl(0, { name = "JupynvimWidgetBar_e91e63", link = false })
  chk("C: the custom bar colour is a highlight group with its colour", hl.fg == 0xe91e63,
    "fg " .. tostring(hl.fg))

  -- The render guard: a bar's span is set only where its buffer row still reads as
  -- the model's row (an undo can leave the region behind the model). The row
  -- changed here loses its span and the other bars keep theirs; the row's own
  -- text brings its span back.
  local _, rt = output_rows(gb, by_tag.tqdm)
  local lnum = rt.out_sep + 1
  local orig = vim.api.nvim_buf_get_lines(gb, lnum, lnum + 1, false)[1]
  -- the same byte length, so the bar's columns still exist: only the guard can stop its span
  vim.api.nvim_buf_set_lines(gb, lnum, lnum + 1, false, { ("x"):rep(#orig) })
  RENDER.refresh_sync(gn, vim.fn.bufwinid(gb))
  local gap, expect_gap = {}, {}
  for _, s in ipairs(bar_spans(gb, gn)) do gap[#gap + 1] = span_key(s) end
  for _, s in ipairs(want_spans) do
    if s.row ~= lnum then expect_gap[#expect_gap + 1] = span_key(s) end
  end
  table.sort(gap)
  table.sort(expect_gap)
  chk("C: a bar on a row that no longer reads as the model's row gets no span, the others keep theirs",
    vim.deep_equal(gap, expect_gap), "got " .. vim.inspect(gap) .. " want " .. vim.inspect(expect_gap))
  vim.api.nvim_buf_set_lines(gb, lnum, lnum + 1, false, { orig })
  RENDER.refresh_sync(gn, vim.fn.bufwinid(gb))
  local back = {}
  for _, s in ipairs(bar_spans(gb, gn)) do back[#back + 1] = span_key(s) end
  table.sort(back)
  chk("C: the row's own text is back, and so is its span", vim.deep_equal(back, want_keys),
    "got " .. vim.inspect(back))

  -- ── E. nested images (the same saved gallery) ─────────────────────────
  io.write("E. the images of an Output widget are the cell's images\n")
  local out_cell = gn.cells[by_tag.output]
  local outid = out_cell.outputs[1].data[VIEW].model_id
  local imgs = RENDER._image_outputs(gn, out_cell)
  local want_key = "w" .. outid .. ".2"
  chk("E: the output cell has exactly one image, the Output widget's plot",
    #imgs == 1, "images " .. #imgs)
  if #imgs == 1 then
    chk("E: its key ends with the Output model id and output 2", imgs[1].key:sub(-#want_key) == want_key,
      "key " .. tostring(imgs[1].key))
    chk("E: it is a png", imgs[1].mime == "image/png" and #imgs[1].b64 > 0,
      "mime " .. tostring(imgs[1].mime))
  end
  local inter = gn.cells[by_tag.interact]
  chk("E: an Output widget with no image adds none", #RENDER._image_outputs(gn, inter) == 0)
  out_cell._output_hidden = true
  chk("E: a hidden output shows no nested image", #RENDER._image_outputs(gn, out_cell) == 0)
  out_cell._output_hidden = nil

  client:call_sync("close", { session_id = gsid }, 5000)
  NB.remove(gb)
  pcall(vim.api.nvim_buf_delete, gb, { force = true })
end

local okc, errc = xpcall(c_run, debug.traceback)
if not okc then chk("section C ran to the end", false, errc) end

-- ── D. rules, fallbacks and budgets, synthetic states (no kernel) ──────
io.write("D. the text form: rules, fallbacks, and budgets (no kernel)\n")
local SYNTH = 0
-- A notebook whose cells are given with their outputs, and whose widget
-- models come from a snapshot (the mirror is loaded in NB.create).
local function d_nb(cells, widgets)
  SYNTH = SYNTH + 1
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].buftype = "acwrite"
  vim.bo[b].swapfile = false
  vim.api.nvim_set_current_buf(b)
  local sid_d = "widget-spec-d-" .. SYNTH
  local n = NB.create(b, "widget-spec-d-" .. SYNTH .. ".ipynb", sid_d,
    { cells = cells, widgets = widgets or {} })
  J._populate_buffer(n)
  return n, b, sid_d
end
local function dcell(id, outputs)
  return { id = id, cell_type = "code", source = id, metadata = vim.empty_dict(),
    execution_count = 1, outputs = outputs }
end
-- A view output whose text/plain is text (the fallback when the view is nil).
local function vout(mid, text)
  return { output_type = "execute_result", execution_count = 1, metadata = vim.empty_dict(),
    data = { ["text/plain"] = text, [VIEW] = { model_id = mid, version_major = 2, version_minor = 0 } } }
end
local function wm(id, name, state, opts)
  opts = opts or {}
  return { model_id = id, model_name = name, model_module = opts.module or "@jupyter-widgets/controls",
    model_module_version = "2.0.0", state = state, buffers = {}, live = opts.live ~= false }
end
local function refs(...)
  local t = {}
  for k, id in ipairs({ ... }) do t[k] = "IPY_MODEL_" .. id end
  return t
end
local function rows_for(n, cell_id)
  for _, c in ipairs(n.cells) do
    if c.id == cell_id then return NB.output_lines(c) end
  end
  return nil
end
local OUTPUT_MOD = "@jupyter-widgets/output"
-- An error whose message has a line break, as a raised exception's can (the
-- traceback's last entry carries it too). Its rows, indented as the cell shows them.
local ERR_TB = { "Traceback (most recent call last):", "  File \"<stdin>\", line 1",
  "ValueError: first line\nsecond line" }
local ERR_ROWS = { "  ValueError: first line", "  second line", "  Traceback (most recent call last):",
  "    File \"<stdin>\", line 1", "  ValueError: first line", "  second line" }
-- An execute_result of an Output widget that shows the view mid as its nested view.
local function nested_out(mid, text)
  return { output_type = "execute_result", execution_count = 1, metadata = vim.empty_dict(),
    data = { ["text/plain"] = text, [VIEW] = { model_id = mid, version_major = 2, version_minor = 0 } } }
end

check("D: an unknown model at the root shows the output's text/plain", function()
  local n = d_nb({ dcell("u1", { vout("no-such-model", "fallback text") }) }, {})
  local rows = rows_for(n, "u1")
  return vim.deep_equal(rows, { "  fallback text" }), "rows " .. vim.inspect(rows)
end)

check("D: a third-party model at the root shows the output's text/plain", function()
  local n = d_nb({ dcell("tp1", { vout("tp", "Figure text") }) },
    { wm("tp", "FigureModel", {}, { module = "jupyter-matplotlib" }) })
  local rows = rows_for(n, "tp1")
  return vim.deep_equal(rows, { "  Figure text" }), "rows " .. vim.inspect(rows)
end)

check("D: a third-party model inside a box shows as its bracketed model name", function()
  local n = d_nb({ dcell("tp2", { vout("vb", "unused") }) }, {
    wm("vb", "VBoxModel", { children = refs("lab", "tp") }),
    wm("lab", "LabelModel", { value = "a" }),
    wm("tp", "FigureModel", {}, { module = "jupyter-matplotlib" }),
  })
  local rows = rows_for(n, "tp2")
  return vim.deep_equal(rows, { "  a", "  [FigureModel]" }), "rows " .. vim.inspect(rows)
end)

check("D: an unknown @jupyter-widgets model shows its name without Model in brackets", function()
  local n = d_nb({ dcell("fw1", { vout("fw", "x") }) },
    { wm("fw", "FancyWidgetModel", { description = "Title" }) })
  local rows = rows_for(n, "fw1")
  return vim.deep_equal(rows, { "  Title [FancyWidget]" }), "rows " .. vim.inspect(rows)
end)

check("D: a closed model shows nothing, not its text/plain", function()
  local n, _, sid_d = d_nb({ dcell("gone1", { vout("gone", "IntSlider(value=3)") }) }, {
    wm("gone", "IntSliderModel", { value = 3, min = 0, max = 10, description = "Level",
      readout_format = "d", readout = true }),
  })
  local before = rows_for(n, "gone1")
  W.handle_event({ session_id = sid_d, event = { kind = "close", model_id = "gone" }, buffers = {} })
  local after = NB.output_lines(n.cells[1])
  return #before == 1 and vim.deep_equal(after, {}),
    "before " .. vim.inspect(before) .. " after " .. vim.inspect(after)
end)

check("D: a hidden layout shows nothing", function()
  local n = d_nb({ dcell("hid1", { vout("hid", "hidden text") }) }, {
    wm("hid", "LabelModel", { value = "hidden label", layout = "IPY_MODEL_lay" }),
    wm("lay", "LayoutModel", { visibility = "hidden" }, { module = "@jupyter-widgets/base" }),
  })
  local rows = rows_for(n, "hid1")
  return vim.deep_equal(rows, {}), "rows " .. vim.inspect(rows)
end)

check("D: a closed child inside a box leaves the others in place", function()
  local n, _, sid_d = d_nb({ dcell("cc1", { vout("cb", "unused") }) }, {
    wm("cb", "VBoxModel", { children = refs("ca", "cx", "cz") }),
    wm("ca", "LabelModel", { value = "a" }),
    wm("cx", "LabelModel", { value = "closed" }),
    wm("cz", "LabelModel", { value = "b" }),
  })
  W.handle_event({ session_id = sid_d, event = { kind = "close", model_id = "cx" }, buffers = {} })
  local rows = NB.output_lines(n.cells[1])
  return vim.deep_equal(rows, { "  a", "  b" }), "rows " .. vim.inspect(rows)
end)

check("D: a missing model inside a box shows nothing for that child, the rest stays", function()
  local n = d_nb({ dcell("mg1", { vout("mgb", "unused") }) }, {
    wm("mgb", "VBoxModel", { children = refs("mga", "nope", "mgz") }),
    wm("mga", "LabelModel", { value = "a" }),
    wm("mgz", "LabelModel", { value = "z" }),
  })
  local rows = rows_for(n, "mg1")
  return vim.deep_equal(rows, { "  a", "  z" }), "rows " .. vim.inspect(rows)
end)

check("D: a shorter block in a row is padded with blank rows to its width", function()
  -- HBox [VBox(one, two), X]: row 2 holds "two" then X's blank row. Nothing follows
  -- the blank row, so the row ends with "two": padding that nothing follows is dropped.
  local n = d_nb({ dcell("pad1", { vout("hb", "unused") }), dcell("pad2", { vout("hb2", "unused") }) }, {
    wm("hb", "HBoxModel", { children = refs("vb", "x") }),
    wm("vb", "VBoxModel", { children = refs("l1", "l2") }),
    wm("l1", "LabelModel", { value = "one" }),
    wm("l2", "LabelModel", { value = "two" }),
    wm("x", "LabelModel", { value = "X" }),
    -- HBox [X, VBox(one, two)]: X's blank row 2 is padded to X's width, so "two" lines
    -- up under "one"
    wm("hb2", "HBoxModel", { children = refs("x", "vb") }),
  })
  local rows, rows2 = rows_for(n, "pad1"), rows_for(n, "pad2")
  return vim.deep_equal(rows, { "  one X", "  two" }) and vim.deep_equal(rows2, { "  X one", "    two" }),
    "rows " .. vim.inspect(rows) .. ", reversed " .. vim.inspect(rows2)
end)

check("D: a cycle of boxes shows nothing and does not loop", function()
  local n = d_nb({ dcell("cy1", { vout("cya", "unused") }) }, {
    wm("cya", "VBoxModel", { children = refs("cyb") }),
    wm("cyb", "VBoxModel", { children = refs("cya") }),
  })
  local rows = rows_for(n, "cy1")
  return vim.deep_equal(rows, {}), "rows " .. vim.inspect(rows)
end)

check("D: a chain of boxes shows its leaf up to depth 32 and no deeper", function()
  local function chain(prefix, depth)
    local ws = {}
    for k = 0, depth - 1 do
      ws[#ws + 1] = wm(prefix .. k, "VBoxModel", { children = refs(prefix .. (k + 1)) })
    end
    ws[#ws + 1] = wm(prefix .. depth, "LabelModel", { value = "deep" })
    return ws
  end
  local shallow = d_nb({ dcell("sh1", { vout("sh0", "unused") }) }, chain("sh", 10))
  local deep = d_nb({ dcell("dp1", { vout("dp0", "unused") }) }, chain("dp", 40))
  local a, b = rows_for(shallow, "sh1"), rows_for(deep, "dp1")
  return vim.deep_equal(a, { "  deep" }) and vim.deep_equal(b, {}),
    "shallow " .. vim.inspect(a) .. " deep " .. vim.inspect(b)
end)

check("D: bar spans survive the cut of a long output: a head row keeps its row, a tail row moves", function()
  local big = {}
  for k = 1, 600 do big[k] = "line " .. k end
  local stream = { output_type = "stream", name = "stdout", text = table.concat(big, "\n") .. "\n" }
  local bar_info = wm("cutbar", "FloatProgressModel", { value = 5, min = 0, max = 10,
    bar_style = "info", description = "" })
  -- tail: the bar comes after the stream, so the cut keeps it in the last rows
  local n = d_nb({ dcell("cut1", { stream, vout("cutbar", "unused") }),
    dcell("cut2", { vout("cuthead", "unused"), stream }) }, {
    bar_info,
    wm("cuthead", "FloatProgressModel", { value = 5, min = 0, max = 10, bar_style = "success",
      description = "" }),
  })
  local tail_cell, head_cell = n.cells[1], n.cells[2]
  local rows = NB.output_lines(tail_cell)
  local spans = NB.output_spans(tail_cell)
  local last = #rows
  local ok_tail = last == 506 and vim.deep_equal(spans[last], { { 2, 2 + #P05, "JupynvimWidgetBarInfo" } })
  local hrows = NB.output_lines(head_cell)
  local hspans = NB.output_spans(head_cell)
  local ok_head = #hrows == 506 and vim.deep_equal(hspans[1], { { 2, 2 + #P05, "JupynvimWidgetBarSuccess" } })
  -- a hidden output shows nothing, so it has no spans either
  tail_cell._output_hidden = true
  local ok_hidden = next(NB.output_spans(tail_cell)) == nil
  tail_cell._output_hidden = nil
  return ok_tail and ok_head and ok_hidden,
    "tail rows " .. last .. " spans " .. vim.inspect(spans[last]) .. " head rows " .. #hrows
    .. " spans " .. vim.inspect(hspans[1]) .. " hidden " .. tostring(ok_hidden)
end)

check("D: html_to_text of the tqdm values, and the entities", function()
  local a = W._html_to_text("t:\226\128\135100%")
  local b = W._html_to_text("\226\128\135" .. "5/5" .. "\226\128\135" .. "[00:00&lt;00:00,"
    .. "\226\128\135\226\128\135" .. "6.51it/s]")
  local c = W._html_to_text("a<br>b")
  local d = W._html_to_text("x &amp; &lt;y&gt; &#65;&#x42;")
  return a == "t: 100%" and b == " 5/5 [00:00<00:00,  6.51it/s]" and c == "a\nb" and d == "x & <y> AB",
    "a " .. vim.inspect(a) .. " b " .. vim.inspect(b) .. " c " .. vim.inspect(c) .. " d " .. vim.inspect(d)
end)

check("D: an Output widget's error with a line break shows one row per line, then its traceback", function()
  local n = d_nb({ dcell("oe1", { vout("oerr", "unused") }) }, {
    wm("oerr", "OutputModel", { outputs = { { output_type = "error", ename = "ValueError",
      evalue = "first line\nsecond line", traceback = ERR_TB } } }, { module = OUTPUT_MOD }),
  })
  local rows = rows_for(n, "oe1")
  return vim.deep_equal(rows, ERR_ROWS), "rows " .. vim.inspect(rows)
end)

check("D: a saved notebook whose Output widget holds a multi-line error opens and shows its rows", function()
  local OUTID = "oerrsaved"
  local path = vim.fn.tempname() .. ".ipynb"
  local f = assert(io.open(path, "w"))
  local err_out = { output_type = "error", ename = "ValueError", evalue = "first line\nsecond line",
    traceback = ERR_TB }
  local out_model = { _model_name = "OutputModel", _model_module = OUTPUT_MOD, outputs = { err_out } }
  local saved_widgets = { [STATE] = { version_major = 2, version_minor = 0, state = {
    [OUTID] = { model_name = "OutputModel", model_module = OUTPUT_MOD, model_module_version = "1.0.0",
      state = out_model },
  } } }
  f:write(vim.json.encode({
    nbformat = 4, nbformat_minor = 5,
    metadata = {
      kernelspec = { name = "python3", display_name = "Python 3", language = "python" },
      widgets = saved_widgets,
    },
    cells = { cell("show", "raise", { nested_out(OUTID, "unused") }) },
  }))
  f:close()
  local gn, gb, gsid = open_saved(path)
  os.remove(path)
  local rows = output_rows(gb, 1)
  client:call_sync("close", { session_id = gsid }, 5000)
  NB.remove(gb)
  pcall(vim.api.nvim_buf_delete, gb, { force = true })
  return vim.deep_equal(rows, ERR_ROWS), "buffer rows " .. vim.inspect(rows)
end)

check("D: a live error with a line break reaches the buffer, and the buffer keeps its modified flag", function()
  local n, b, sid_d = d_nb({ dcell("lv1", { vout("lv", "unused") }) }, {
    wm("lv", "OutputModel", { outputs = {} }, { module = OUTPUT_MOD }),
  })
  -- The saved baseline J.open takes after the populate (init.lua), so the buffer
  -- is clean as an opened notebook is; the sync keeps it so.
  n.saved_hash = vim.fn.sha256(table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n"))
  vim.bo[b].modified = false
  local was = vim.bo[b].modified
  W.handle_event({ session_id = sid_d, event = { kind = "output", model_id = "lv", event = {
    kind = "error", ename = "ValueError", evalue = "first line\nsecond line", traceback = ERR_TB } },
    buffers = {} })
  local got
  vim.wait(1000, function()
    got = output_rows(b, 1)
    return vim.deep_equal(got, ERR_ROWS)
  end, 20)
  return vim.deep_equal(got, ERR_ROWS) and vim.bo[b].modified == was,
    "buffer rows " .. vim.inspect(got) .. " modified " .. tostring(vim.bo[b].modified) .. " before " .. tostring(was)
end)

check("D: no row of a widget view holds a line break, whichever widget carries it", function()
  local n = d_nb({ dcell("nl1", { vout("nlbox", "unused") }) }, {
    wm("nlbox", "VBoxModel", { children = refs("nl_lab", "nl_html", "nl_ta", "nl_btn", "nl_tog",
      "nl_rad", "nl_dd", "nl_tab", "nl_acc", "nl_out", "nl_val") }),
    wm("nl_lab", "LabelModel", { value = "label\none" }),
    wm("nl_html", "HTMLModel", { value = "<p>para one</p>\n<p>para two</p>" }),
    wm("nl_ta", "TextareaModel", { value = "ta one\nta two", description = "T\nd" }),
    wm("nl_btn", "ButtonModel", { description = "but\nton" }),
    wm("nl_tog", "ToggleButtonsModel", { _options_labels = { "o\n1", "o2" }, index = 0, description = "tb\nx" }),
    wm("nl_rad", "RadioButtonsModel", { _options_labels = { "r\n1", "r2" }, index = 1 }),
    wm("nl_dd", "DropdownModel", { _options_labels = { "d\n1" }, index = 0 }),
    wm("nl_tab", "TabModel", { children = refs("nl_lab"), titles = { "t\n1" }, selected_index = 0 }),
    wm("nl_acc", "AccordionModel", { children = refs("nl_lab"), titles = { "a\n1" }, selected_index = 0 }),
    wm("nl_out", "OutputModel", { outputs = {
      { output_type = "stream", name = "stdout", text = "s1\ns2\n" },
      { output_type = "execute_result", execution_count = 1, metadata = vim.empty_dict(),
        data = { ["text/plain"] = "r1\nr2" } },
      { output_type = "error", ename = "E", evalue = "e1\ne2", traceback = { "t1\nt2" } },
    } }, { module = OUTPUT_MOD }),
    wm("nl_val", "ValidModel", { value = false, readout = "bad\ninput", description = "v\nd" }),
  })
  local rows = rows_for(n, "nl1") or {}
  local bad = {}
  for _, r in ipairs(rows) do
    if r:find("\n", 1, true) then bad[#bad + 1] = vim.inspect(r) end
  end
  return #rows > 0 and #bad == 0, "rows " .. vim.inspect(rows) .. " with a break " .. table.concat(bad, " ")
end)

check("D: a valid widget with an empty readout shows the readout as given", function()
  local n = d_nb({ dcell("vv1", { vout("vv", "unused") }) }, {
    wm("vv", "ValidModel", { value = false, readout = "", description = "Ok" }),
  })
  local rows = rows_for(n, "vv1")
  return vim.deep_equal(rows, { "  Ok ✗ " }), "rows " .. vim.inspect(rows)
end)

check("D: a textarea with LF, CRLF or CR line ends shows the same rows, with no carriage return", function()
  local want = { "  Notes one", "        two" }
  local got, ok = {}, true
  for k, v in ipairs({ "one\ntwo", "one\r\ntwo", "one\rtwo" }) do
    local n = d_nb({ dcell("ta" .. k, { vout("tav" .. k, "unused") }) }, {
      wm("tav" .. k, "TextareaModel", { value = v, description = "Notes" }),
    })
    got[k] = rows_for(n, "ta" .. k)
    ok = ok and vim.deep_equal(got[k], want)
  end
  return ok, "rows " .. vim.inspect(got)
end)

check("D: a third-party view nested in an Output widget shows its bracketed model name", function()
  local n = d_nb({ dcell("tpo1", { vout("tpo", "unused") }) }, {
    wm("tpo", "OutputModel", { outputs = { nested_out("tpn", "Figure repr") } }, { module = OUTPUT_MOD }),
    wm("tpn", "FigureModel", {}, { module = "jupyter-matplotlib" }),
  })
  local rows = rows_for(n, "tpo1")
  return vim.deep_equal(rows, { "  [FigureModel]" }), "rows " .. vim.inspect(rows)
end)

check("D: a missing view nested in an Output widget shows its output's text/plain", function()
  local n = d_nb({ dcell("mno1", { vout("mno", "unused") }) }, {
    wm("mno", "OutputModel", { outputs = { nested_out("no-such", "Missing repr") } }, { module = OUTPUT_MOD }),
  })
  local rows = rows_for(n, "mno1")
  return vim.deep_equal(rows, { "  Missing repr" }), "rows " .. vim.inspect(rows)
end)

-- A readout precision of three digits. The frontend formats with d3-format, which
-- clamps the precision (0..20 for f, e and %, 1..21 for g): ".005f" is 5 and
-- ".100f" is 20. Before the clamp the text form threw on both.
check("D: a readout precision of three digits shows as d3 clamps it", function()
  local _, b = d_nb({ dcell("rf1", { vout("rfv", "VBox()") }) }, {
    wm("rfv", "VBoxModel", { children = refs("rf_a", "rf_b") }),
    wm("rf_a", "FloatSliderModel", { value = 7, min = 0, max = 10, readout = true,
      readout_format = ".005f", description = "a" }),
    wm("rf_b", "FloatSliderModel", { value = 7, min = 0, max = 10, readout = true,
      readout_format = ".100f", description = "b" }),
  })
  local rows = output_rows(b, 1)
  local want = { "  a " .. S13 .. " 7.00000", "  b " .. S13 .. " 7." .. ("0"):rep(20) }
  return vim.deep_equal(rows, want), "rows " .. vim.inspect(rows) .. " want " .. vim.inspect(want)
end)

-- The percent form: ".005%" is five digits, and ".100%" is clamped to 20 as d3-format
-- clamps it. The value 7 reads 700%.
check("D: a percent readout precision shows as d3 clamps it", function()
  local _, b = d_nb({ dcell("pc1", { vout("pcv", "VBox()") }) }, {
    wm("pcv", "VBoxModel", { children = refs("pc_a", "pc_b") }),
    wm("pc_a", "FloatSliderModel", { value = 7, min = 0, max = 10, readout = true,
      readout_format = ".005%", description = "a" }),
    wm("pc_b", "FloatSliderModel", { value = 7, min = 0, max = 10, readout = true,
      readout_format = ".100%", description = "b" }),
  })
  local rows = output_rows(b, 1)
  local want = { "  a " .. S13 .. " 700.00000%", "  b " .. S13 .. " 700." .. ("0"):rep(20) .. "%" }
  return vim.deep_equal(rows, want), "rows " .. vim.inspect(rows) .. " want " .. vim.inspect(want)
end)

-- A saved notebook with that slider opens through the real open path and shows it.
check("D: a saved notebook with a three-digit readout precision opens and shows the slider", function()
  local SL = "5a1d2b3c4d5e4f60a1b2c3d4e5f60719"
  local path = vim.fn.tempname() .. ".ipynb"
  local f = assert(io.open(path, "w"))
  f:write(vim.json.encode({
    nbformat = 4, nbformat_minor = 5,
    metadata = {
      kernelspec = { name = "python3", display_name = "Python 3", language = "python" },
      widgets = { [STATE] = { version_major = 2, version_minor = 0, state = {
        [SL] = { model_name = "FloatSliderModel", model_module = "@jupyter-widgets/controls",
          model_module_version = "2.0.0", state = {
            _model_name = "FloatSliderModel", _model_module = "@jupyter-widgets/controls",
            _model_module_version = "2.0.0", value = 7, min = 0, max = 10, readout = true,
            readout_format = ".005f", description = "a" } } } } },
    },
    cells = { cell("show", "slider", { nested_out(SL, "FloatSlider(value=7.0)") }) },
  }))
  f:close()
  local ok, res = pcall(J.open, path)
  os.remove(path)
  local rows, nbk = {}, nil
  if ok and type(res) == "number" then
    rows = output_rows(res, 1)
    nbk = NB.get(res)
  end
  if nbk then pcall(function() J._ensure_client():call_sync("close", { session_id = nbk.session_id }, 5000) end) end
  if ok and type(res) == "number" then
    NB.remove(res)
    pcall(vim.api.nvim_buf_delete, res, { force = true })
  end
  return ok and vim.deep_equal(rows, { "  a " .. S13 .. " 7.00000" }),
    "open " .. tostring(ok) .. " " .. tostring(res) .. " rows " .. vim.inspect(rows)
end)

-- A live update of that slider redraws the cell with the clamped precision, and the
-- buffer stays clean (the redraw is a keep-clean sync, as for any widget).
check("D: a live update of a slider with a three-digit readout precision redraws the cell", function()
  local n, b, sid_d = d_nb({ dcell("lf1", { vout("lf", "unused") }) }, {
    wm("lf", "FloatSliderModel", { value = 7, min = 0, max = 10, readout = true,
      readout_format = ".005f", description = "a" }),
  })
  -- the saved baseline J.open takes after the populate, so the buffer starts clean
  n.saved_hash = vim.fn.sha256(table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n"))
  vim.bo[b].modified = false
  W.handle_event({ session_id = sid_d, event = { kind = "update", model_id = "lf",
    state = { value = 3 }, buffer_paths = {} }, buffers = {} })
  local want = { "  a " .. S6 .. " 3.00000" }
  local got
  vim.wait(3000, function()
    got = output_rows(b, 1)
    return vim.deep_equal(got, want)
  end, 20)
  return vim.deep_equal(got, want) and not vim.bo[b].modified,
    "rows " .. vim.inspect(got) .. " modified " .. tostring(vim.bo[b].modified)
end)

-- A state the text form cannot read: a TagsInput value with a nested null, and an
-- Output widget whose error has a nested list as its evalue. Each cell shows its
-- output's text/plain, and the notebook's other cells show as usual.
check("D: a widget state the text form cannot read shows its text/plain, the rest of the notebook shows", function()
  local n = d_nb({
    dcell("bad1", { vout("badtags", "TagsInput(value=[['a', None]])") }),
    dcell("bad2", { vout("badout", "Output()") }),
    dcell("good", { { output_type = "stream", name = "stdout", text = "fine\n" } }),
  }, {
    wm("badtags", "TagsInputModel", { value = { { "a", vim.NIL } } }),
    wm("badout", "OutputModel", { outputs = { { output_type = "error", ename = "E",
      evalue = { "x", { "y" } } } } }, { module = OUTPUT_MOD }),
  })
  local r1, r2, r3 = rows_for(n, "bad1"), rows_for(n, "bad2"), rows_for(n, "good")
  return vim.deep_equal(r1, { "  TagsInput(value=[['a', None]])" }) and vim.deep_equal(r2, { "  Output()" })
      and vim.deep_equal(r3, { "  fine" }),
    "rows " .. vim.inspect(r1) .. " " .. vim.inspect(r2) .. " " .. vim.inspect(r3)
end)

-- The log file belongs to the run, and another run of this spec in the same run dir
-- would find the first run's lines. So a check counts only the lines written after
-- the size the file had before its renders (the notebook's populate renders too).
local function log_size()
  local f = io.open(require("jupynvim.log").path(), "r")
  if not f then return 0 end
  local size = f:seek("end")
  f:close()
  return size
end
local function log_after(from)
  local f = io.open(require("jupynvim.log").path(), "r")
  if not f then return "" end
  f:seek("set", from)
  local text = f:read("*a") or ""
  f:close()
  return text
end

-- A view that cannot be read is logged once, not at every render, and it shows its
-- text/plain each time.
check("D: a view that cannot be read logs once and shows its text/plain each time", function()
  local MARK = "lgonce7f3a"
  -- the size before the notebook is built: building it (the populate) renders the view
  local from = log_size()
  local n, b = d_nb({ dcell("lg1", { vout(MARK, "TagsInput(value=[['a', None]])") }) }, {
    wm(MARK, "TagsInputModel", { value = { { "a", vim.NIL } } }),
  })
  local cell = n.cells[1]
  local o = cell.outputs[1]
  for _ = 1, 3 do
    if W.view_block(n, cell, o) ~= nil then return false, "a block came back for a view that cannot be read" end
  end
  local function count_plain(s, needle)
    local c, from = 0, 1
    while true do
      local _, j = s:find(needle, from, true)
      if not j then return c end
      c, from = c + 1, j + 1
    end
  end
  local text = log_after(from)
  local logged = count_plain(text, "widget view " .. MARK .. " shows")
  local rows = output_rows(b, 1)
  return logged == 1 and vim.deep_equal(rows, { "  TagsInput(value=[['a', None]])" }),
    "log lines " .. logged .. " rows " .. vim.inspect(rows)
end)

-- A walk that throws still records the models it read before the throw. The cell
-- depends on them, so a fix to one redraws the cell: the view comes back without a
-- reopen. The model that breaks is a TagsInput whose value holds a null.
check("D: a view whose walk threw is redrawn when the model it read before the throw is fixed", function()
  local n, b, sid = d_nb({ dcell("tr1", { vout("tr_tags", "TagsInput(bad)") }) }, {
    wm("tr_tags", "TagsInputModel", { value = { { "a", vim.NIL } } }),
  })
  n.saved_hash = vim.fn.sha256(table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n"))
  vim.bo[b].modified = false
  local shown = output_rows(b, 1)
  send(sid, { kind = "update", model_id = "tr_tags", state = { value = { "a", "b" } }, buffer_paths = {} })
  local want = { "  [a, b]" }
  local got
  vim.wait(3000, function()
    got = output_rows(b, 1)
    return vim.deep_equal(got, want)
  end, 20)
  return vim.deep_equal(shown, { "  TagsInput(bad)" }) and vim.deep_equal(got, want) and not vim.bo[b].modified,
    "before " .. vim.inspect(shown) .. " after " .. vim.inspect(got) .. " modified " .. tostring(vim.bo[b].modified)
end)

-- The same through a parent: a VBox shows its text/plain while one child throws, and
-- when that child is fixed the VBox redraws with both children's rows.
check("D: a parent whose child threw redraws when the child is fixed (reads before the throw count)", function()
  local n, b, sid = d_nb({ dcell("tr2", { vout("tr_box", "VBox(...)") }) }, {
    wm("tr_box", "VBoxModel", { children = refs("tr_lab", "tr_chip") }),
    wm("tr_lab", "LabelModel", { value = "lab" }),
    wm("tr_chip", "TagsInputModel", { value = { "x" } }),
  })
  n.saved_hash = vim.fn.sha256(table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n"))
  vim.bo[b].modified = false
  send(sid, { kind = "update", model_id = "tr_chip", state = { value = { { "x", vim.NIL } } }, buffer_paths = {} })
  local broken
  vim.wait(3000, function()
    broken = output_rows(b, 1)
    return vim.deep_equal(broken, { "  VBox(...)" })
  end, 20)
  send(sid, { kind = "update", model_id = "tr_chip", state = { value = { "y" } }, buffer_paths = {} })
  local want = { "  lab", "  [y]" }
  local got
  vim.wait(3000, function()
    got = output_rows(b, 1)
    return vim.deep_equal(got, want)
  end, 20)
  return vim.deep_equal(broken, { "  VBox(...)" }) and vim.deep_equal(got, want) and not vim.bo[b].modified,
    "broken " .. vim.inspect(broken) .. " fixed " .. vim.inspect(got) .. " modified " .. tostring(vim.bo[b].modified)
end)

-- An Output widget that cannot be read gives its cell no nested images (not the
-- one read before the error), and the cell shows its text/plain.
check("D: an Output widget that cannot be read gives its cell no nested images", function()
  local png = vim.base64.encode("\137PNG\r\n\26\n")
  local n, b = d_nb({ dcell("oi1", { vout("oiout", "Output()") }) }, {
    wm("oiout", "OutputModel", { outputs = {
      { output_type = "execute_result", execution_count = 1, metadata = vim.empty_dict(),
        data = { ["image/png"] = png, ["text/plain"] = "<Figure>" } },
      { output_type = "error", ename = "E", evalue = { "x", { "y" } } },
    } }, { module = OUTPUT_MOD }),
  })
  local imgs = RENDER._image_outputs(n, n.cells[1])
  local rows = output_rows(b, 1)
  return #imgs == 0 and vim.deep_equal(rows, { "  Output()" }),
    "images " .. #imgs .. " rows " .. vim.inspect(rows)
end)

-- ipywidgets 7 saves a Tab's and an Accordion's titles in _titles (keys "0", "1", ...),
-- not in a titles list. They show their titles like the ipywidgets 8 ones do.
check("D: an ipywidgets 7 Tab and Accordion keep their titles in _titles and show them", function()
  local n = d_nb({ dcell("t7", { vout("t7v", "unused") }), dcell("a7", { vout("a7v", "unused") }) }, {
    wm("t7v", "TabModel", { children = refs("t7a", "t7b"), _titles = { ["0"] = "First", ["1"] = "Second" },
      selected_index = 1 }),
    wm("t7a", "LabelModel", { value = "one" }),
    wm("t7b", "LabelModel", { value = "two" }),
    wm("a7v", "AccordionModel", { children = refs("a7a", "a7b"), _titles = { ["0"] = "Slider", ["1"] = "Text" },
      selected_index = 0 }),
    wm("a7a", "LabelModel", { value = "inside" }),
    wm("a7b", "LabelModel", { value = "other" }),
  })
  local tab_rows, acc_rows = rows_for(n, "t7"), rows_for(n, "a7")
  local want_tab = { "  First | [Second]", "  two" }
  local want_acc = { "  ▾ Slider", "    inside", "  ▸ Text" }
  return vim.deep_equal(tab_rows, want_tab) and vim.deep_equal(acc_rows, want_acc),
    "tab " .. vim.inspect(tab_rows) .. " accordion " .. vim.inspect(acc_rows)
end)

-- The rules of the text form that had no check of their own.
check("D: the closing block tags of HTML are line ends", function()
  local a = W._html_to_text("<p>a</p><div>b</div>")
  local b = W._html_to_text("<h3>Title</h3><p>para one</p><ul><li>item</li></ul><div>end</div>")
  return a == "a\nb" and b == "Title\npara one\nitem\nend", "a " .. vim.inspect(a) .. " b " .. vim.inspect(b)
end)

check("D: a range whose second end is not past the first moves it to the cell after", function()
  local n = d_nb({ dcell("rg1", { vout("rgs", "unused") }) }, {
    wm("rgs", "IntRangeSliderModel", { value = { 10, 10 }, min = 0, max = 10, readout = true,
      readout_format = "d" }),
  })
  local rows = rows_for(n, "rg1")
  local same = W._R(19, 19) == W._R(18, 19)
  return same and vim.deep_equal(rows, { "  " .. ("─"):rep(18) .. "●●" .. " 10 - 10" }),
    "same " .. tostring(same) .. " rows " .. vim.inspect(rows)
end)

check("D: a time shows its seconds when they are set, and milliseconds alone show zero seconds", function()
  local n = d_nb({ dcell("tm1", { vout("tmv", "unused") }) }, {
    wm("tmv", "VBoxModel", { children = refs("tma", "tmb") }),
    wm("tma", "TimeModel", { value = { hours = 9, minutes = 5, seconds = 7, milliseconds = 0 } }),
    wm("tmb", "TimeModel", { value = { hours = 9, minutes = 5, seconds = 0, milliseconds = 300 } }),
  })
  local rows = rows_for(n, "tm1")
  return vim.deep_equal(rows, { "  [09:05:07]", "  [09:05:00]" }), "rows " .. vim.inspect(rows)
end)

check("D: a cycle of boxes that holds a leaf shows the leaf once", function()
  local n = d_nb({ dcell("cl1", { vout("cla", "unused") }) }, {
    wm("cla", "VBoxModel", { children = refs("clx", "clb") }),
    wm("clb", "VBoxModel", { children = refs("cla") }),
    wm("clx", "LabelModel", { value = "x" }),
  })
  local rows = rows_for(n, "cl1")
  return vim.deep_equal(rows, { "  x" }), "rows " .. vim.inspect(rows)
end)

-- The budgets: averages over a loop, on a monotonic clock in ns.
local hr = (vim.uv or vim.loop).hrtime

check("D: a widget update takes under 0.1 ms on average over 1,000 (one dependent cell)", function()
  local _, _, sid_d = d_nb({ dcell("bud1", { vout("bud", "0") }) }, {
    wm("bud", "LabelModel", { value = "0" }),
  })
  local t0 = hr()
  for i = 1, 1000 do
    W.handle_event({ session_id = sid_d, event = { kind = "update", model_id = "bud",
      state = { value = tostring(i) }, buffer_paths = {} }, buffers = {} })
  end
  local avg_ms = (hr() - t0) / 1e6 / 1000
  return avg_ms < 0.1, ("average %.4f ms"):format(avg_ms)
end)

check("D: one text render of a tqdm view takes under 0.1 ms on average over 1,000", function()
  local n = d_nb({ dcell("tq1", { vout("tq", "plain") }) }, {
    wm("tq", "HBoxModel", { children = refs("h1", "fp", "h2") }),
    wm("h1", "HTMLModel", { value = "tqdm.notebook\226\128\135done:\226\128\135100%" }),
    wm("fp", "FloatProgressModel", { value = 40, min = 0, max = 40, bar_style = "success",
      style = "IPY_MODEL_ps" }),
    wm("ps", "ProgressStyleModel", { bar_color = vim.NIL }),
    wm("h2", "HTMLModel", { value = "\226\128\13540/40\226\128\135[00:00&lt;00:00,\226\128\13572.12it/s]" }),
  })
  local cell = n.cells[1]
  local o = cell.outputs[1]
  local t0 = hr()
  for _ = 1, 1000 do W.view_block(n, cell, o) end
  local avg_ms = (hr() - t0) / 1e6 / 1000
  return avg_ms < 0.1, ("average %.4f ms"):format(avg_ms)
end)

check("D: a cache hit renders nothing: 1,000 output_lines calls leave the renders unchanged", function()
  local n = d_nb({ dcell("hit1", { vout("hit", "unused") }) }, {
    wm("hit", "LabelModel", { value = "cached" }),
  })
  local cell = n.cells[1]
  NB.output_lines(cell)
  local before = W.stats.renders
  for _ = 1, 1000 do NB.output_lines(cell) end
  return W.stats.renders == before, "renders " .. before .. " -> " .. W.stats.renders
end)

check("D: W.set on a live model takes under 0.2 ms on average over 1,000 calls", function()
  local n, b = d_nb({ dcell("wsb1", { vout("wsb", "5") }) }, {
    wm("wsb", "IntSliderModel", { value = 5, min = 0, max = 10, step = 1, description = "Level" }),
  })
  -- the stub records each call (method and params): the count, the order, the values
  -- and the ids are checked as well as the time
  local recorded = {}
  local saved = J._nb_client
  J._nb_client = function()
    return { call = function(_, method, params)
      recorded[#recorded + 1] = { method = method, params = params }
    end }
  end
  local ok, avg_ms = pcall(function()
    local t0 = hr()
    for i = 1, 1000 do W.set(n, "wsb", { value = i }) end
    return (hr() - t0) / 1e6 / 1000
  end)
  J._nb_client = saved
  -- the redraw the calls queued runs on a timer: let it finish inside this check
  local tick0 = vim.api.nvim_buf_get_changedtick(b)
  vim.wait(3000, function() return vim.api.nvim_buf_get_changedtick(b) > tick0 end)
  if not ok then return false, tostring(avg_ms) end
  local bad = nil
  for i, c in ipairs(recorded) do
    local p = c.params
    if c.method ~= "widget_update" or p.model_id ~= "wsb" or p.cell_id ~= "wsb1"
      or p.session_id ~= n.session_id or p.state.value ~= i then
      bad = i
      break
    end
  end
  -- the measured figure, printed whatever the outcome (the check's detail shows only on a failure)
  io.write(("  measured: W.set average %.4f ms over %d calls\n"):format(avg_ms, #recorded))
  return avg_ms < 0.2 and #recorded == 1000 and bad == nil,
    ("average %.4f ms over %d calls, first wrong call %s"):format(avg_ms, #recorded, tostring(bad))
end)

-- An Output widget's capture is a long stream, as a `with out:` block logs it. It
-- must cost what the same text costs as a cell's stream: the cell cuts a long stream
-- to its head and tail rows before it processes the text (add_stream), and the
-- widget must do the same. Each rebuild is a rev bump (what a captured stream
-- message does) and the images of the view (view_images, after the rows).
check("D: a 20,000-line Output widget capture rebuilds in under 8 ms, as its cell stream does", function()
  local lines = {}
  for i = 1, 20000 do lines[i] = ("row %06d of the captured log, a line of ordinary width"):format(i) end
  local text = table.concat(lines, "\n") .. "\n"
  local n = d_nb({
    dcell("ow20", { vout("ob20", "unused") }),
    dcell("cs20", { { output_type = "stream", name = "stdout", text = text } }),
  }, {
    wm("ob20", "OutputModel", { msg_id = "", outputs = { { output_type = "stream", name = "stdout", text = text } } },
      { module = OUTPUT_MOD }),
  })
  local widget_cell, stream_cell = n.cells[1], n.cells[2]
  local view = widget_cell.outputs[1]
  -- median of nine rebuilds of each: one rebuild is output_lines after a rev bump,
  -- plus view_images for the widget's view
  local function median_ms(cell, o)
    local times = {}
    for k = 1, 9 do
      cell._widget_rev = (cell._widget_rev or 0) + 1
      local t0 = hr()
      NB.output_lines(cell)
      if o then W.view_images(n, cell, o) end
      times[k] = (hr() - t0) / 1e6
    end
    table.sort(times)
    return times[5]
  end
  local widget_ms = median_ms(widget_cell, view)
  local stream_ms = median_ms(stream_cell, nil)
  io.write(("  measured: 20,000-line rebuild, Output widget %.2f ms, cell stream %.2f ms\n"):format(widget_ms, stream_ms))
  local same = vim.deep_equal(rows_for(n, "ow20"), rows_for(n, "cs20"))
  return widget_ms < 8 and same,
    ("widget %.2f ms (limit 8), cell stream %.2f ms, rows equal %s"):format(widget_ms, stream_ms, tostring(same))
end)

-- The cut of a capture carries its marker through the boxes that hold the Output widget:
-- the rows of a box holding it are the rows of the widget alone.
check("D: a cut capture inside a box shows the rows it shows alone, marker included", function()
  local lines = {}
  for i = 1, 3000 do lines[i] = ("boxed row %05d"):format(i) end
  local text = table.concat(lines, "\n") .. "\n"
  local out_state = { msg_id = "", outputs = { { output_type = "stream", name = "stdout", text = text } } }
  local n = d_nb({
    dcell("bx1", { vout("bxv", "unused") }),
    dcell("bx2", { vout("bxo", "unused") }),
  }, {
    wm("bxv", "VBoxModel", { children = refs("bxh") }),
    wm("bxh", "HBoxModel", { children = refs("bxo") }),
    wm("bxo", "OutputModel", out_state, { module = OUTPUT_MOD }),
  })
  -- a box pads each row to its widest line, so the trailing spaces are the box's; the
  -- text and the marker are what is compared
  local function trimmed(rows)
    local t = {}
    for k, l in ipairs(rows) do t[k] = l:gsub("%s+$", "") end
    return t
  end
  local boxed, alone = trimmed(rows_for(n, "bx1")), trimmed(rows_for(n, "bx2"))
  local marker = false
  for _, l in ipairs(alone) do
    if l:find("lines hidden (3000 total)", 1, true) then marker = true end
  end
  return vim.deep_equal(boxed, alone) and marker and #alone < 3000,
    ("boxed %d rows, alone %d rows, marker %s"):format(#boxed, #alone, tostring(marker))
end)

check("D: a closed model's tombstone goes once no cell shows it", function()
  local n, _, sid = d_nb({ dcell("mt1", { vout("mtq", "plain") }) }, {
    wm("mtq", "HBoxModel", { children = refs("mh") }),
    wm("mh", "HTMLModel", { value = "x" }),
  })
  local cell = n.cells[1]
  NB.output_lines(cell)
  W.handle_event({ session_id = sid, event = { kind = "close", model_id = "mtq" }, buffers = {} })
  NB.output_lines(cell)
  -- the cell still shows the closed model: its tombstone stays, so the view is empty
  local kept = W.get(sid, "mtq")
  local kept_ok = kept ~= nil and kept.closed == true
  -- the cell is rebuilt without the view: no cell depends on the tombstone any more
  cell.outputs = { { output_type = "stream", name = "stdout", text = "done\n" } }
  NB.output_lines(cell)
  return kept_ok and W.get(sid, "mtq") == nil,
    ("kept while shown %s, gone after the rebuild %s"):format(tostring(kept_ok), tostring(W.get(sid, "mtq") == nil))
end)

check("D: a reset drops the dead models the core pruned, and keeps the others dead", function()
  local _, _, sid = d_nb({ dcell("rp1", { vout("rpk", "plain") }) }, {
    wm("rpk", "LabelModel", { value = "kept" }),
    wm("rpd", "LabelModel", { value = "dropped" }),
  })
  W.handle_event({ session_id = sid, event = { kind = "reset", pruned = { "rpd" } }, buffers = {} })
  local kept = W.get(sid, "rpk")
  return W.get(sid, "rpd") == nil and kept ~= nil and kept.live == false,
    "dropped gone " .. tostring(W.get(sid, "rpd") == nil) .. ", kept dead " .. tostring(kept ~= nil and kept.live == false)
end)

-- A data URI in an Output widget's text is a line a cell's stream shows as the marker
-- (add_text). The widget's rows get the same guard when the view is copied into the cell.
check("D: a data URI in an Output widget's rows shows the marker, as a cell's stream does", function()
  local text = "before the image\ndata:image/png;base64,iVBORw0KGgo=\nafter the image\n"
  local n = d_nb({
    dcell("du_w", { vout("duo", "unused") }),
    dcell("du_s", { { output_type = "stream", name = "stdout", text = text } }),
  }, {
    wm("duo", "OutputModel", { msg_id = "", outputs = { { output_type = "stream", name = "stdout", text = text } } },
      { module = OUTPUT_MOD }),
  })
  local widget_rows, stream_rows = rows_for(n, "du_w"), rows_for(n, "du_s")
  local marked, raw = false, false
  for _, l in ipairs(widget_rows) do
    if l == "  [embedded image data]" then marked = true end
    if l:find("base64,", 1, true) then raw = true end
  end
  return vim.deep_equal(widget_rows, stream_rows) and marked and not raw,
    "widget rows " .. vim.inspect(widget_rows) .. ", stream rows " .. vim.inspect(stream_rows)
end)

-- A JSON null in an Output widget's outputs decodes to vim.NIL. It is skipped, and it
-- must not turn the view into its text/plain when a long stream comes before it.
check("D: a JSON null after a long stream in an Output widget keeps the cut rows, no fallback", function()
  local lines = {}
  for i = 1, 2000 do lines[i] = ("null row %04d"):format(i) end
  local text = table.concat(lines, "\n") .. "\n"
  local n = d_nb({
    dcell("nl_n", { vout("nln", "fallback") }),
    dcell("nl_p", { vout("nlp", "fallback") }),
  }, {
    wm("nln", "OutputModel", { msg_id = "",
      outputs = { { output_type = "stream", name = "stdout", text = text }, vim.NIL } }, { module = OUTPUT_MOD }),
    wm("nlp", "OutputModel", { msg_id = "",
      outputs = { { output_type = "stream", name = "stdout", text = text } } }, { module = OUTPUT_MOD }),
  })
  local with_nil, without = rows_for(n, "nl_n"), rows_for(n, "nl_p")
  -- the rows are the capture's cut rows, not the text/plain both cells would fall back to
  return vim.deep_equal(with_nil, without) and #with_nil < 2000 and #without > 1
      and without[1] == "  null row 0001",
    "rows with a null entry " .. #with_nil .. " (first " .. tostring(with_nil[1]) .. "), without " .. #without
      .. " (first " .. tostring(without[1]) .. ")"
end)

-- Side by side, an Output widget's data URI row is the marker before the box lines its
-- columns up: the leaf takes the row rule, so the box neither pads every row to the
-- URI's width nor loses the Label that shares the URI's row. Before, the box padded the
-- 21 rows to the 200 KB row and the cell's guard then replaced only that row: 4 MB.
check("D: a data URI in an Output widget beside a Label shows the marker and the Label, in a few KB", function()
  local uri = "data:image/png;base64," .. string.rep("A", 200000)
  local logs = {}
  for i = 1, 20 do logs[i] = ("log row %02d"):format(i) end
  local first = uri .. "\n" .. table.concat(logs, "\n") .. "\n"
  local last = table.concat(logs, "\n") .. "\n" .. uri .. "\n"
  local function out(id, text)
    return wm(id, "OutputModel", { msg_id = "", outputs = { { output_type = "stream", name = "stdout", text = text } } },
      { module = OUTPUT_MOD })
  end
  local n = d_nb({ dcell("hu_f", { vout("huf", "unused") }), dcell("hu_l", { vout("hul", "unused") }),
    dcell("hu_p", { vout("hup", "unused") }) }, {
    wm("huf", "HBoxModel", { children = refs("huo1", "hul1") }),
    out("huo1", first),
    wm("hul1", "LabelModel", { value = "status ok" }),
    wm("hul", "HBoxModel", { children = refs("huo2", "hul2") }),
    out("huo2", last),
    wm("hul2", "LabelModel", { value = "status ok" }),
    -- a progress bar whose description is the URI: its one row is the marker, with no bar
    wm("hup", "HBoxModel", { children = refs("hupb", "hul2") }),
    wm("hupb", "FloatProgressModel", { value = 50, min = 0, max = 100, description = uri }),
  })
  local function bytes(rows)
    local k = 0
    for _, l in ipairs(rows) do k = k + #l end
    return k
  end
  local f, l = rows_for(n, "hu_f"), rows_for(n, "hu_l")
  -- the column is as wide as its widest row, the marker (21 cells)
  local want_f = { "  [embedded image data] status ok" }
  for i = 1, 20 do want_f[#want_f + 1] = ("  log row %02d"):format(i) end
  local want_l = { ("  %-21s status ok"):format("log row 01") }
  for i = 2, 20 do want_l[#want_l + 1] = ("  log row %02d"):format(i) end
  want_l[#want_l + 1] = "  [embedded image data]"
  local p = rows_for(n, "hu_p")
  local p_spans = NB.output_spans(n.cells[3]) or {}
  local p_ok = vim.deep_equal(p, { "  [embedded image data] status ok" }) and next(p_spans) == nil
  return vim.deep_equal(f, want_f) and vim.deep_equal(l, want_l) and bytes(f) < 8192 and bytes(l) < 8192
      and p_ok,
    ("URI first: %d rows, %d bytes, row 1 %q; URI last: %d rows, %d bytes, row 1 %q; bar: rows %s, spans %s"):format(
      #f, bytes(f), (f[1] or ""):sub(1, 60), #l, bytes(l), (l[1] or ""):sub(1, 60),
      vim.inspect(vim.tbl_map(function(r) return r:sub(1, 60) end, p)), vim.inspect(p_spans))
end)

-- A box with one child has no neighbour to line up with: it shows the child's rows as
-- they are, a long row whole, as the child alone and its cell stream do.
check("D: a box with one child shows the child's rows as they are, a long row whole", function()
  local rows = {}
  for i = 1, 20 do rows[i] = ("one %02d "):format(i) .. (i == 1 and ("y"):rep(20000) or "") end
  local text = table.concat(rows, "\n") .. "\n"
  local function out(id)
    return wm(id, "OutputModel", { msg_id = "", outputs = { { output_type = "stream", name = "stdout", text = text } } },
      { module = OUTPUT_MOD })
  end
  local n = d_nb({ dcell("ob_b", { vout("obb", "unused") }), dcell("ob_a", { vout("oba", "unused") }) }, {
    wm("obb", "HBoxModel", { children = refs("obo") }),
    out("obo"),
    out("oba"),
  })
  local boxed, alone = rows_for(n, "ob_b"), rows_for(n, "ob_a")
  return vim.deep_equal(boxed, alone) and #boxed == 20 and #boxed[1] == 2 + 7 + 20000,
    ("boxed %d rows (row 1 %d bytes, row 2 %q), alone %d rows (row 1 %d bytes)"):format(#boxed,
      #(boxed[1] or ""), boxed[2] or "", #alone, #(alone[1] or ""))
end)

-- A row wider than the column bound is cut to it, with the cut mark, when it sits beside
-- another column, whichever column it is in: the neighbours stay in view, and no row of
-- the box takes the long row's width. The cut counts display cells (a wide character is
-- two) and never splits a character. Widths are measured as the layout measures them,
-- with strwidth: strdisplaywidth adds the window's line break settings to a long row.
check("D: a 20,000-character line beside a Label is cut to the column bound, in a few KB", function()
  -- the bound the text form exports; without one, the widths below are still measured
  local MAX = W.COLUMN_MAX
  local function text(ch)
    local rows = {}
    for i = 1, 20 do rows[i] = ("row %02d "):format(i) .. (i == 1 and ch:rep(20000) or "") end
    return table.concat(rows, "\n") .. "\n"
  end
  local function out(id, t)
    return wm(id, "OutputModel", { msg_id = "", outputs = { { output_type = "stream", name = "stdout", text = t } } },
      { module = OUTPUT_MOD })
  end
  local n = d_nb({
    dcell("lc_a", { vout("lca", "unused") }),
    dcell("lc_b", { vout("lcb", "unused") }),
    dcell("lc_c", { vout("lcc", "unused") }),
  }, {
    wm("lca", "HBoxModel", { children = refs("lco1", "lcl") }),
    wm("lcb", "HBoxModel", { children = refs("lcl", "lco2") }),
    wm("lcc", "HBoxModel", { children = refs("lco3", "lcl") }),
    out("lco1", text("x")),
    out("lco2", text("x")),
    out("lco3", text("界")),
    wm("lcl", "LabelModel", { value = "status ok" }),
  })
  local bound = 2 + (MAX or 0) + 1 + vim.api.nvim_strwidth("status ok")
  local detail = { "bound " .. tostring(MAX) }
  local ok = MAX ~= nil
  for _, id in ipairs({ "lc_a", "lc_b", "lc_c" }) do
    local rows = rows_for(n, id)
    local bytes, widest = 0, 0
    for _, r in ipairs(rows) do
      bytes = bytes + #r
      widest = math.max(widest, vim.api.nvim_strwidth(r))
    end
    local first = rows[1] or ""
    -- the cut part of row 1: the row without its indent and the Label's column
    local cut = id == "lc_b" and first:match("^  status ok (.*)$") or first:match("^  (.*) status ok$")
    local whole = id == "lc_c" and "界…" or "x…"
    local good = MAX ~= nil and #rows == 20 and widest <= bound and bytes < 8192 and cut ~= nil
      and vim.api.nvim_strwidth(cut) <= MAX and vim.api.nvim_strwidth(cut) >= MAX - 1
      and cut:sub(-#whole) == whole
    ok = ok and good
    detail[#detail + 1] = ("%s: %d rows, widest %d (bound %d), %d bytes, cut part width %s"):format(
      id, #rows, widest, bound, bytes, cut and tostring(vim.api.nvim_strwidth(cut)) or "none")
  end
  return ok, table.concat(detail, "; ")
end)

-- A bar cut by the column bound keeps its span on the bar cells the row still shows,
-- and a bar cut off whole has no span.
check("D: a bar cut by the column bound keeps its span on the bar cells it still shows", function()
  local function bar(id, desc)
    return wm(id, "FloatProgressModel", { value = 50, min = 0, max = 100, description = desc, bar_style = "" })
  end
  local n = d_nb({ dcell("sc_a", { vout("sca", "unused") }), dcell("sc_b", { vout("scb", "unused") }) }, {
    wm("sca", "HBoxModel", { children = refs("scp1", "sct") }),
    wm("scb", "HBoxModel", { children = refs("scp2", "sct") }),
    bar("scp1", ("d"):rep(100)),
    bar("scp2", ("d"):rep(300)),
    wm("sct", "LabelModel", { value = "tail" }),
  })
  local a, b = n.cells[1], n.cells[2]
  local row = NB.output_lines(a)[1] or ""
  local list = (NB.output_spans(a) or {})[1] or {}
  local mark = row:find("…", 1, true)
  local sp = list[1]
  local covered = sp and row:sub(sp[1] + 1, sp[2]) or ""
  -- the span starts after the description and its space, and ends where the cut mark starts
  local a_ok = #list == 1 and mark ~= nil and sp[1] == 2 + 101 and sp[2] == mark - 1
    and covered ~= "" and covered:gsub("█", ""):gsub("▌", "") == (" "):rep(5)
    and row:sub(-#" tail") == " tail"
  local b_ok = (NB.output_spans(b) or {})[1] == nil and (NB.output_lines(b)[1] or ""):find("…", 1, true) ~= nil
  return a_ok and b_ok, ("row %q, spans %s; cut off whole: spans %s"):format(
    row, vim.inspect(list), vim.inspect((NB.output_spans(b) or {})[1]))
end)

-- The cut of a capture reaches the cell as a cell's stream's cut does: the cut flag, the
-- marker row and the line count. Built alone, in a VBox, and two side by side in an HBox.
do
  local CUT_N = 3000
  local function capture(prefix)
    local lines = {}
    for i = 1, CUT_N do lines[i] = ("%s row %05d"):format(prefix, i) end
    return table.concat(lines, "\n") .. "\n"
  end
  local function widget_out(id, text)
    return wm(id, "OutputModel", { msg_id = "", outputs = { { output_type = "stream", name = "stdout", text = text } } },
      { module = OUTPUT_MOD })
  end
  local function cut_rows(marks)
    local k = 0
    for _, v in pairs(marks) do if v == "cut" then k = k + 1 end end
    return k
  end

  check("D: a cut capture of an Output widget reports its cut as a cell's stream does", function()
    local text = capture("alone")
    local n = d_nb({
      dcell("ca_w", { vout("caw", "unused") }),
      dcell("ca_s", { { output_type = "stream", name = "stdout", text = text } }),
    }, { widget_out("caw", text) })
    local w, s = n.cells[1], n.cells[2]
    local same_marks = vim.deep_equal(NB.output_marks(w), NB.output_marks(s))
    local ok = NB.output_cut(w) and same_marks and cut_rows(NB.output_marks(w)) == 1
      and NB.output_count(w) == CUT_N and NB.output_count(w) == NB.output_count(s)
    w._output_expanded = true
    local every = #NB.output_lines(w) == CUT_N
    w._output_expanded = nil
    return ok and every, ("cut %s, marks %s, count %d (stream %d), expanded rows %d"):format(
      tostring(NB.output_cut(w)), vim.inspect(NB.output_marks(w)), NB.output_count(w),
      NB.output_count(s), #NB.output_lines(w))
  end)

  check("D: a cut capture inside a VBox keeps its cut, marks and count", function()
    local text = capture("boxed")
    local n = d_nb({
      dcell("cv_b", { vout("cvb", "unused") }),
      dcell("cv_s", { { output_type = "stream", name = "stdout", text = text } }),
    }, {
      wm("cvb", "VBoxModel", { children = refs("cvo") }),
      widget_out("cvo", text),
    })
    local boxed, s = n.cells[1], n.cells[2]
    local ok = NB.output_cut(boxed) and vim.deep_equal(NB.output_marks(boxed), NB.output_marks(s))
      and cut_rows(NB.output_marks(boxed)) == 1 and NB.output_count(boxed) == CUT_N
    boxed._output_expanded = true
    local every = #NB.output_lines(boxed) == CUT_N
    boxed._output_expanded = nil
    return ok and every, ("cut %s, marks %s, count %d, expanded rows %d"):format(
      tostring(NB.output_cut(boxed)), vim.inspect(NB.output_marks(boxed)), NB.output_count(boxed),
      #NB.output_lines(boxed))
  end)

  check("D: two cut captures side by side keep their cut on one marker row, and expand to every line", function()
    local n = d_nb({ dcell("ch_b", { vout("chb", "unused") }) }, {
      wm("chb", "HBoxModel", { children = refs("chl", "chr") }),
      widget_out("chl", capture("left")),
      widget_out("chr", capture("right")),
    })
    local cell = n.cells[1]
    local marks = NB.output_marks(cell)
    local marked_row
    for row, v in pairs(marks) do if v == "cut" then marked_row = row end end
    local marker = marked_row and NB.output_lines(cell)[marked_row] or ""
    -- the marker row stands for the rows it hides once, not once per column
    local shown = NB.output_cut(cell) and cut_rows(marks) == 1
      and marker:find("(3000 total)", 1, true) ~= nil and NB.output_count(cell) == CUT_N
    cell._output_expanded = true
    local rows = NB.output_lines(cell)
    local every = #rows == CUT_N
      and rows[1]:find("left row 00001", 1, true) ~= nil and rows[1]:find("right row 00001", 1, true) ~= nil
      and rows[CUT_N]:find("left row 03000", 1, true) ~= nil and rows[CUT_N]:find("right row 03000", 1, true) ~= nil
    cell._output_expanded = nil
    return shown and every, ("cut %s, marker row %s, marker %q, count %d, expanded rows %d"):format(
      tostring(NB.output_cut(cell)), tostring(marked_row), marker, NB.output_count(cell), #rows)
  end)

  -- Side by side, the markers can sit on different rows (here a title above one
  -- capture). The cell's count is still the rows the output expands to, the longer
  -- column's: 3,001.
  check("D: side by side, captures whose markers sit on different rows count the rows they expand to", function()
    local n = d_nb({ dcell("cd_b", { vout("cdb", "unused") }) }, {
      wm("cdb", "HBoxModel", { children = refs("cdv", "cdr") }),
      wm("cdv", "VBoxModel", { children = refs("cdt", "cdl") }),
      wm("cdt", "LabelModel", { value = "title" }),
      widget_out("cdl", capture("left")),
      widget_out("cdr", capture("right")),
    })
    local cell = n.cells[1]
    local count = NB.output_count(cell)
    cell._output_expanded = true
    local rows = #NB.output_lines(cell)
    cell._output_expanded = nil
    return NB.output_cut(cell) and count == CUT_N + 1 and rows == CUT_N + 1,
      ("cut %s, count %d, expanded rows %d"):format(tostring(NB.output_cut(cell)), count, rows)
  end)

  -- An open Accordion shows its child indented under the title row; the capture's marker
  -- goes with it, so the count is the title row plus the capture's 3,000.
  check("D: a cut capture inside an open Accordion keeps its marker and count", function()
    local n = d_nb({ dcell("ac_b", { vout("acb", "unused") }) }, {
      wm("acb", "AccordionModel", { children = refs("aco"), titles = { "log" }, selected_index = 0 }),
      widget_out("aco", capture("accordion")),
    })
    local cell = n.cells[1]
    local marker = ""
    for _, l in ipairs(NB.output_lines(cell)) do
      if l:find("lines hidden", 1, true) then marker = l end
    end
    local count = NB.output_count(cell)
    cell._output_expanded = true
    local rows = #NB.output_lines(cell)
    cell._output_expanded = nil
    return NB.output_cut(cell) and count == CUT_N + 1 and marker:find("(3001 total)", 1, true) ~= nil
        and rows == CUT_N + 1,
      ("cut %s, count %d, marker %q, expanded rows %d"):format(tostring(NB.output_cut(cell)), count, marker, rows)
  end)
end

-- A model closed while no cell shows it keeps its tombstone only until the notebook's
-- next output sync has built its cells: that sync may build a cell whose view shows the
-- model (its view arrived just before the close), and that view must stay empty, not
-- show its text/plain. After the sync, a tombstone no cell shows is gone and one a cell
-- shows stays. A one-cell rewrite (as <leader>no makes) while a sync still waits takes
-- nothing: the cell that will show the model is not built yet.
check("D: a closed model no cell shows keeps its tombstone until the next output sync, then only a shown one stays", function()
  local n, b, sid = d_nb({ dcell("ts_s", {}), dcell("ts_o", { { output_type = "stream", name = "stdout",
    text = "other\n" } }) }, {})
  local function open(id)
    W.handle_event({ session_id = sid, event = { kind = "open", model_id = id, model_name = "IntSliderModel",
      model_module = "@jupyter-widgets/controls", model_module_version = "2.0.0", state = { value = 1 } },
      buffers = {} })
  end
  local function close(id)
    W.handle_event({ session_id = sid, event = { kind = "close", model_id = id }, buffers = {} })
  end
  open("tsa")
  open("tsb")
  open("tsc")
  -- no sync waits: the tombstone stays for now (a view of it may still be on its way)
  close("tsc")
  local c_kept = W.get(sid, "tsc") ~= nil and W.get(sid, "tsc").closed == true
  -- the view of tsa arrives in the first cell; its sync is queued, not run yet
  n.cells[1].outputs = { vout("tsa", "fallback a") }
  J._queue_output_sync(b, n, n.cells[1].id)
  close("tsa")
  close("tsb")
  J._sync_keep_clean(n, { [n.cells[2].id] = true })
  local mid = W.get(sid, "tsa") ~= nil and W.get(sid, "tsb") ~= nil and W.get(sid, "tsc") ~= nil
  vim.wait(3000, function() return W.get(sid, "tsb") == nil end, 20)
  local a = W.get(sid, "tsa")
  local rows = NB.output_lines(n.cells[1])
  return c_kept and mid and W.get(sid, "tsb") == nil and W.get(sid, "tsc") == nil and a ~= nil
      and a.closed == true and vim.deep_equal(rows, {}),
    ("tsc kept at its close %s; all kept through the one-cell rewrite %s; after the sync: tsb %s, tsc %s, tsa %s, rows %s"):format(
      tostring(c_kept), tostring(mid), vim.inspect(W.get(sid, "tsb")), vim.inspect(W.get(sid, "tsc")),
      vim.inspect(a), vim.inspect(rows))
end)

-- The bar groups and the palette. A stub stands in for jupynvim.palette while a
-- check needs a palette of its own (tokens or none); the real module is put back
-- after each one. The last check reads the real palette, which the bars drawn so
-- far asked for (the library loads in this run).
local BAR_TOKENS = {
  JupynvimWidgetBar = "accent", JupynvimWidgetBarSuccess = "ok", JupynvimWidgetBarInfo = "info",
  JupynvimWidgetBarWarning = "warn", JupynvimWidgetBarDanger = "error",
}
local function hl_of(name)
  return vim.api.nvim_get_hl(0, { name = name, link = false, create = false })
end
local function num_of(c) return tonumber(c:sub(2), 16) end
-- A stand-in palette: info().state is "ok" with tokens, "waiting" without;
-- get() and when_ready are counted.
local function palette_stub(tokens)
  local st = { gets = 0, asks = 0, tokens = tokens }
  st.mod = {
    info = function() return { state = st.tokens and "ok" or "waiting" } end,
    get = function() st.gets = st.gets + 1; return st.tokens end,
    when_ready = function(cb) st.asks = st.asks + 1; st.cb = cb end,
    setup = function() end,
  }
  return st
end
local function with_palette(stub, body)
  local real = package.loaded["jupynvim.palette"]
  package.loaded["jupynvim.palette"] = stub and stub.mod or nil
  local ok, a, b = pcall(body)
  package.loaded["jupynvim.palette"] = real
  pcall(W.setup_hl)
  if not ok then error(a, 0) end
  return a, b
end
-- Each bar group's fg and bg against what want(group) gives ({ fg, bg }).
local function bars_are(want)
  local ok_all, detail = true, ""
  for group in pairs(BAR_TOKENS) do
    local h = hl_of(group)
    local w = want(group)
    if h.fg ~= w[1] or h.bg ~= w[2] then
      ok_all = false
      detail = detail .. (" %s fg %s bg %s (want %s %s)"):format(group, tostring(h.fg), tostring(h.bg),
        tostring(w[1]), tostring(w[2]))
    end
  end
  return ok_all, detail
end
local STUB_TOKENS = { accent = "#5ab0f6", ok = "#7ee787", info = "#56d4dd", warn = "#e3b341",
  error = "#ff7b72", track = "#30363d" }

check("D: the bar groups exist, with the track colour as background (no palette)", function()
  return with_palette(palette_stub(nil), function()
    RENDER.setup_highlights()
    local function num(name, fallback) return hl_of(name).fg or fallback end
    local track = num("LineNr", 0x3b4261)
    local src = {
      JupynvimWidgetBar = { "Function", 0x2196f3 },
      JupynvimWidgetBarSuccess = { "DiagnosticOk", 0x4caf50 },
      JupynvimWidgetBarInfo = { "DiagnosticInfo", 0x00bcd4 },
      JupynvimWidgetBarWarning = { "DiagnosticWarn", 0xff9800 },
      JupynvimWidgetBarDanger = { "DiagnosticError", 0xf44336 },
    }
    local ok_all, detail = bars_are(function(g) return { num(src[g][1], src[g][2]), track } end)
    return ok_all, "track " .. track .. detail
  end)
end)

check("D: with a palette the bar groups take accent, ok, info, warn and error on the track token", function()
  local stub = palette_stub(vim.deepcopy(STUB_TOKENS))
  return with_palette(stub, function()
    RENDER.setup_highlights()
    local ok_all, detail = bars_are(function(g) return { num_of(STUB_TOKENS[BAR_TOKENS[g]]), num_of(STUB_TOKENS.track) } end)
    local c = hl_of("JupynvimWidgetBar_e91e63")
    local ok_c = c.fg == 0xe91e63 and c.bg == num_of(STUB_TOKENS.track)
    return ok_all and ok_c and stub.asks == 0,
      detail .. (" custom fg %s bg %s; when_ready calls %d"):format(tostring(c.fg), tostring(c.bg), stub.asks)
  end)
end)

check("D: a palette that changes without :hi clear moves the bar groups, a user's own group stays", function()
  local stub = palette_stub(vim.deepcopy(STUB_TOKENS))
  return with_palette(stub, function()
    RENDER.setup_highlights()
    -- the user's own definition of one group, made after jupynvim's
    vim.cmd("highlight JupynvimWidgetBarDanger guifg=#010203 guibg=#040506")
    local moved = vim.tbl_extend("force", vim.deepcopy(STUB_TOKENS), { ok = "#a5d6ff", track = "#21262d" })
    stub.tokens = moved
    W.setup_hl()
    local ok_all, detail = bars_are(function(g)
      if g == "JupynvimWidgetBarDanger" then return { 0x010203, 0x040506 } end
      return { num_of(moved[BAR_TOKENS[g]]), num_of(moved.track) }
    end)
    local c = hl_of("JupynvimWidgetBar_e91e63")
    vim.cmd("highlight clear JupynvimWidgetBarDanger")
    return ok_all and c.fg == 0xe91e63 and c.bg == num_of(moved.track),
      detail .. (" custom fg %s bg %s"):format(tostring(c.fg), tostring(c.bg))
  end)
end)

check("D: a colourscheme's own bar group stays, and after :hi clear the palette's come back", function()
  local stub = palette_stub(vim.deepcopy(STUB_TOKENS))
  return with_palette(stub, function()
    vim.cmd("highlight clear")
    vim.cmd("highlight JupynvimWidgetBarInfo guifg=#0a0b0c")
    RENDER.setup_highlights()
    local kept = hl_of("JupynvimWidgetBarInfo")
    local ok_kept = kept.fg == 0x0a0b0c and kept.bg == nil
    vim.cmd("highlight clear")
    RENDER.setup_highlights()
    local ok_all, detail = bars_are(function(g) return { num_of(STUB_TOKENS[BAR_TOKENS[g]]), num_of(STUB_TOKENS.track) } end)
    return ok_kept and ok_all, ("kept fg %s bg %s;%s"):format(tostring(kept.fg), tostring(kept.bg), detail)
  end)
end)

check("D: setup_hl never starts the palette: no get() while nothing is derived", function()
  local stub = palette_stub(nil)
  return with_palette(stub, function()
    RENDER.setup_highlights()
    W.setup_hl()
    return stub.gets == 0 and stub.asks == 0, ("get() %d, when_ready %d"):format(stub.gets, stub.asks)
  end)
end)

check("D: the first bar asks for the palette once, from the next tick, and its answer sets the groups", function()
  local stub = palette_stub(nil)
  return with_palette(stub, function()
    W._palette_unasked()
    local n = d_nb({ dcell("pal1", { vout("palb", "plain") }) }, {
      wm("palb", "FloatProgressModel", { value = 3, min = 0, max = 4, bar_style = "info" }),
    })
    local cell = n.cells[1]
    W.view_block(n, cell, cell.outputs[1])
    local at_draw = stub.asks
    vim.wait(1000, function() return stub.asks > 0 end, 5)
    W.view_block(n, cell, cell.outputs[1])
    local n2 = d_nb({ dcell("pal2", { vout("palc", "plain") }) }, {
      wm("palc", "IntProgressModel", { value = 1, min = 0, max = 4 }),
    })
    W.view_block(n2, n2.cells[1], n2.cells[1].outputs[1])
    -- callbacks run in the order they were scheduled: once this one ran, so did any
    -- the two later draws scheduled
    local drained = false
    vim.schedule(function() drained = true end)
    vim.wait(1000, function() return drained end, 5)
    local asks = stub.asks
    local ev = #vim.api.nvim_get_autocmds({ group = "jupynvim_widget_palette", event = "User", pattern = "JupynvimPalette" })
    -- the palette answers: tokens now, and the groups follow
    stub.tokens = vim.deepcopy(STUB_TOKENS)
    if stub.cb then stub.cb(stub.tokens, { state = "ok" }) end
    local ok_all, detail = bars_are(function(g) return { num_of(STUB_TOKENS[BAR_TOKENS[g]]), num_of(STUB_TOKENS.track) } end)
    -- and the event of a later palette moves them again
    local later = vim.tbl_extend("force", vim.deepcopy(STUB_TOKENS), { info = "#79c0ff" })
    stub.tokens = later
    vim.api.nvim_exec_autocmds("User", { pattern = "JupynvimPalette", modeline = false, data = { theme_id = "x", generation = 9 } })
    local info = hl_of("JupynvimWidgetBarInfo").fg
    return at_draw == 0 and asks == 1 and ev == 1 and ok_all and info == 0x79c0ff,
      ("asks at the draw %d, after %d; User autocmds %d; info fg %s;%s"):format(at_draw, asks, ev, tostring(info), detail)
  end)
end)

check("D: the real palette, asked by the bars drawn so far, sets the bar groups from its tokens", function()
  local P = require("jupynvim.palette")
  vim.wait(15000, function() return P.info().state ~= "waiting" end, 10)
  local info = P.info()
  local t = info.state == "ok" and P.get() or nil
  if not t then
    -- without the library the groups keep their sources: say so, but this run builds it
    return false, "the palette has no tokens: " .. tostring(info.state) .. " " .. tostring(info.reason)
  end
  RENDER.setup_highlights()
  local ok_all, detail = bars_are(function(g) return { num_of(t[BAR_TOKENS[g]]), num_of(t.track) } end)
  return ok_all, "theme " .. tostring(info.theme_id) .. detail
end)

-- ── E2. the nested images follow the Output widget's outputs ─────────────
io.write("E2. a change to an Output widget changes the cell's nested images\n")
check("E2: a plot arriving in, then cleared from, an Output widget changes the cell's images", function()
  local n, b_e2, sid_n = d_nb({ dcell("ni1", { vout("niout", "unused") }) }, {
    wm("niout", "OutputModel", { outputs = {} }, { module = OUTPUT_MOD }),
  })
  local cell_n = n.cells[1]
  local function keys()
    local out = {}
    for k, img in ipairs(RENDER._image_outputs(n, cell_n)) do out[k] = img.key end
    return out
  end
  -- The event, then a wait for the image list to hold want entries and for the
  -- redraw's sync (on a timer) to have rewritten the cell's rows.
  local function event(ev, want)
    local tick0 = vim.api.nvim_buf_get_changedtick(b_e2)
    W.handle_event({ session_id = sid_n, event = { kind = "output", model_id = "niout", event = ev },
      buffers = {} })
    vim.wait(3000, function()
      return #keys() == want and vim.api.nvim_buf_get_changedtick(b_e2) > tick0
    end)
  end
  local png = vim.base64.encode("\137PNG\r\n\26\n")
  local plot = { kind = "display_data", data = { ["image/png"] = png, ["text/plain"] = "<Figure>" },
    metadata = vim.empty_dict() }
  local k0 = keys()
  event(plot, 1)
  local k1 = keys()
  event(plot, 2)
  local k2 = keys()
  event({ kind = "clear_output", wait = false }, 0)
  local k3 = keys()
  local function ends(k, s) return k ~= nil and k:sub(-#s) == s end
  local w1, w2 = "w" .. "niout" .. ".1", "w" .. "niout" .. ".2"
  return #k0 == 0 and #k1 == 1 and #k2 == 2 and #k3 == 0 and ends(k1[1], w1) and ends(k2[1], w1)
      and ends(k2[2], w2),
    ("images %d, %d, %d, %d"):format(#k0, #k1, #k2, #k3)
end)

if client and sid then client:call_sync("close", { session_id = sid }, 5000) end
if buf then NB.remove(buf); pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
if client then client:stop() end
os.remove(tmp)
if #failures > 0 then
  io.write(#failures .. " WIDGET SPEC CHECKS FAILED\n")
  vim.cmd("cquit 1")
else
  io.write("ALL WIDGET SPEC CHECKS PASSED\n")
  vim.cmd("qa!")
end

-- The widget mirror: what the Lua side knows about the widget models of each
-- session, kept in step with the core's store by the widget_event
-- notifications, and the redraws a change asks for.
--
-- The core owns the models: its store holds each model's state, buffers and
-- echo bookkeeping. The mirror holds what a view needs. Per model it keeps a
-- name, module, version, state (binary values placed at their paths), the
-- buffer paths, live (connected to the current kernel) and rev (moves on every
-- change). A closed model is a tombstone, so its state is freed at once.
--
-- A cell whose output shows a widget view depends on the view's model and on
-- every model it reaches (children, style, layout, what an Output widget
-- shows). views[id] holds the cells that depend on model id (weak keys), and
-- deps[cell] holds what the cell depends on, so a rebuild can drop it first
-- (W.begin). A change to a model bumps cell._widget_rev of each dependent cell
-- and queues an output sync that keeps the buffer clean: the notebook did not
-- change, only a view of it did.
--
-- A buffer is a Lua string of raw bytes, stored at its path in the state. A
-- path's 0-based list index n is the Lua index n + 1. vim.NIL (a JSON null, as
-- a list slot or a value) is kept as it arrives, and a read goes through nn, which
-- reads it as nil: vim.NIL is truthy in Lua.
--
-- This module requires jupynvim.notebook and jupynvim lazily: both require it
-- at load time.

local log = require("jupynvim.log")

local W = {}

W.VIEW_MIME = "application/vnd.jupyter.widget-view+json"
-- Counters for the budget checks: renders (one per view build), events (one per
-- widget_event handled).
W.stats = { renders = 0, events = 0 }

local REF = "IPY_MODEL_"
local OUTPUT_MODEL = "OutputModel"
local NOT_CONNECTED = "jupynvim: this widget is not connected to a kernel"

-- session_id -> { models = { id -> entry }, views = { id -> weak set of cells },
-- orphans = { id -> true } }. orphans are the models closed while no cell depended
-- on them; their tombstones wait for the next output sync (W.sweep).
local sessions = {}
-- cell -> { sid = session_id, ids = { model id -> true } }. The value holds no
-- reference to the cell, so the weak key can go with the cell.
local deps = setmetatable({}, { __mode = "k" })

local function nn(v)
  if v == vim.NIL then return nil end
  return v
end

local function text(v)
  if type(v) == "string" then return v end
  return ""
end

local function session(sid)
  local s = sessions[sid]
  if not s then
    s = { models = {}, views = {}, orphans = {} }
    sessions[sid] = s
  end
  return s
end

local function bump(entry)
  entry.rev = (entry.rev or 0) + 1
end

-- The Lua key of a path segment: a dict key is kept, a 0-based list index
-- becomes one more.
local function slot(seg)
  if type(seg) == "number" then return seg + 1 end
  return seg
end

-- The value at path[1..n] inside state (n = 0 gives state itself), or nil.
local function walk(state, path, n)
  local cur = state
  for i = 1, n do
    if type(cur) ~= "table" then return nil end
    cur = cur[slot(path[i])]
  end
  return cur
end

-- Puts value at path inside state. False when the path's parent is missing.
local function place(state, path, value)
  if type(path[1]) ~= "string" or #path == 0 then return false end
  local parent = walk(state, path, #path - 1)
  if type(parent) ~= "table" then return false end
  parent[slot(path[#path])] = value
  return true
end

-- Empties the slot a binary value sat in: a dict key goes, a list slot is null.
local function clear_at(state, path)
  local parent = walk(state, path, #path - 1)
  if type(parent) ~= "table" then return end
  local last = path[#path]
  if type(last) == "number" then
    parent[slot(last)] = vim.NIL
  else
    parent[last] = nil
  end
end

local function hex_decode(s)
  if #s % 2 ~= 0 or s:find("[^%x]") then return nil end
  return (s:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end))
end

-- A buffer of a saved or exported state: base64 (what the core writes) or hex.
local function decode_buffer(b)
  if type(b.data) ~= "string" then return nil end
  if b.encoding == "hex" then return hex_decode(b.data) end
  local ok, bytes = pcall(vim.base64.decode, b.data)
  if ok then return bytes end
  return nil
end

local function notebook()
  return require("jupynvim.notebook")
end

-- Applies a change the way the core merges an update: each touched key takes
-- the update's value, or is removed when the update lacks it. A touched key is
-- a key of the state or the first element of a buffer path. The buffers under
-- a touched key are dropped, and the new buffers are placed at their paths.
local function merge(entry, state, paths, bufs)
  local touched, seen = {}, {}
  for key in pairs(state) do
    if type(key) == "string" and not seen[key] then
      seen[key] = true
      touched[#touched + 1] = key
    end
  end
  for _, p in ipairs(paths) do
    local head = p[1]
    if type(head) == "string" and not seen[head] then
      seen[head] = true
      touched[#touched + 1] = head
    end
  end
  for _, key in ipairs(touched) do
    entry.state[key] = state[key]
  end
  local kept = {}
  for _, p in ipairs(entry.buffer_paths) do
    if not seen[p[1]] then kept[#kept + 1] = p end
  end
  for i, p in ipairs(paths) do
    local bytes = bufs[i]
    if bytes ~= nil and place(entry.state, p, bytes) then kept[#kept + 1] = p end
  end
  entry.buffer_paths = kept
end

-- Redraws one dependent cell: its revision moves on, and its output rows are
-- rewritten in the next sync without marking the buffer modified.
local function redraw(sid, cell)
  local nb = notebook().owner_of(cell)
  if not nb or nb.session_id ~= sid then return end
  cell._widget_rev = (cell._widget_rev or 0) + 1
  require("jupynvim")._queue_output_sync(nb.buf, nb, cell.id, { keep_clean = true })
end

-- Every cell that depends on one of ids is redrawn, once each.
local function touch(sid, sess, ids)
  local seen = {}
  for _, id in ipairs(ids) do
    local set = sess.views[id]
    if set then
      for cell in pairs(set) do
        if not seen[cell] then
          seen[cell] = true
          redraw(sid, cell)
        end
      end
    end
  end
end

-- Applies an output event of an Output widget to its outputs.
local function output_event(entry, ev)
  local outs = nn(entry.state.outputs)
  if type(outs) ~= "table" then outs = {} end
  entry.state.outputs = notebook().apply_output_event(outs, ev)
end

-- Outputs that arrive whole (the kernel's own update of an Output widget, or a
-- saved state) get the same cleanup as a cell's output on entry: the base64
-- image data is cleaned once, here, not on every render.
local function normalize_outputs(entry)
  if entry.name ~= OUTPUT_MODEL then return end
  local outs = nn(entry.state.outputs)
  if type(outs) ~= "table" then return end
  for _, o in ipairs(outs) do
    if type(o) == "table" then notebook().normalize_output_data(o.data) end
  end
end

-- The widget_event notification (params {session_id, event, buffers}).
function W.handle_event(p)
  if type(p) ~= "table" or type(p.session_id) ~= "string" or type(p.event) ~= "table" then return end
  local sid, ev = p.session_id, p.event
  local bufs = p.buffers or {}
  -- An event of a session with no mirror (its notebook is closed) is dropped:
  -- a mirror made here would never be dropped again. A notebook gets its
  -- mirror in create, before the backend can send it anything.
  local sess = sessions[sid]
  if not sess then
    log.debug("widget event for session " .. sid .. " with no open notebook dropped")
    return
  end
  W.stats.events = W.stats.events + 1
  local ids = {}
  local kind = ev.kind
  if kind == "open" then
    local old = sess.models[ev.model_id]
    local entry = {
      name = text(ev.model_name), module = text(ev.model_module), version = text(ev.model_module_version),
      state = {}, buffer_paths = {}, live = true, closed = false, rev = old and old.rev or 0,
    }
    merge(entry, type(ev.state) == "table" and ev.state or {}, ev.buffer_paths or {}, bufs)
    normalize_outputs(entry)
    bump(entry)
    sess.models[ev.model_id] = entry
    ids = { ev.model_id }
  elseif kind == "update" then
    local entry = sess.models[ev.model_id]
    if not entry then
      entry = { name = "", module = "", version = "", state = {}, buffer_paths = {},
        live = true, closed = false, rev = 0 }
      sess.models[ev.model_id] = entry
    end
    if entry.closed then
      log.debug("widget update for a closed model " .. tostring(ev.model_id) .. " dropped")
    else
      local update = type(ev.state) == "table" and ev.state or {}
      merge(entry, update, ev.buffer_paths or {}, bufs)
      if update.outputs ~= nil then normalize_outputs(entry) end
      bump(entry)
      ids = { ev.model_id }
    end
  elseif kind == "output" then
    local entry = sess.models[ev.model_id]
    if entry and not entry.closed and type(entry.state) == "table" and type(ev.event) == "table" then
      output_event(entry, ev.event)
      bump(entry)
      ids = { ev.model_id }
    end
  elseif kind == "close" then
    local old = sess.models[ev.model_id]
    sess.models[ev.model_id] = { closed = true, rev = old and (old.rev or 0) + 1 or 1 }
    ids = { ev.model_id }
    -- With no cell depending on it, the tombstone is needed only until the next output
    -- sync: a view of the model may have arrived just before the close, in a cell that
    -- sync builds, and that view must show nothing (W.sweep).
    local set = sess.views[ev.model_id]
    if not set or next(set) == nil then sess.orphans[ev.model_id] = true end
  elseif kind == "reset" then
    -- The core drops the dead models no cell shows (ev.pruned); their entries go too.
    for _, id in ipairs(type(ev.pruned) == "table" and ev.pruned or {}) do
      sess.models[id] = nil
      sess.views[id] = nil
    end
    -- Every model the core kept is disconnected. No view is redrawn: the text form
    -- does not read the live flag, so a redraw would write the same rows again on
    -- every kernel start. A renderer that does read live must redraw the cells that
    -- show each model here, when it lands.
    for _, entry in pairs(sess.models) do
      if not entry.closed then
        entry.live = false
        bump(entry)
      end
    end
    -- Dependents sets nothing holds any more (a deleted cell's), and the tombstones
    -- nothing shows, go with the restart.
    for id, set in pairs(sess.views) do
      if next(set) == nil then sess.views[id] = nil end
    end
    for id, entry in pairs(sess.models) do
      if entry.closed and not sess.views[id] then sess.models[id] = nil end
    end
    sess.orphans = {}
  elseif kind == "custom" then
    log.debug("widget custom message from " .. tostring(ev.model_id) .. " has no mirror change")
  else
    log.debug("widget event " .. tostring(kind) .. " is not handled by the mirror")
  end
  if #ids > 0 then touch(sid, sess, ids) end
end

-- The entry of a model: { name, module, version, state, buffer_paths, live,
-- closed, rev }. A closed model is { closed = true, rev = n }. nil when unknown.
function W.get(sid, model_id)
  local sess = sessions[sid]
  return sess and sess.models[model_id] or nil
end

-- A saved or exported state (the list of snapshot.widgets: models_json shape,
-- buffers base64) becomes the session's models, dead unless the model says it
-- is live. The views of the session are kept: the cells that show them stay
-- subscribed. It writes the decoded bytes into the list it is given (no copy;
-- callers pass a fresh decode). Export again before sending a list that was loaded.
function W.load(sid, list)
  local sess = session(sid)
  sess.models = {}
  sess.orphans = {}
  if type(list) ~= "table" then return 0 end
  local n = 0
  for _, m in ipairs(list) do
    if type(m) == "table" and type(m.model_id) == "string" then
      local entry = {
        name = text(m.model_name), module = text(m.model_module), version = text(m.model_module_version),
        state = {}, buffer_paths = {}, live = m.live == true, closed = false, rev = 0,
      }
      local paths, bufs = {}, {}
      for _, b in ipairs(type(m.buffers) == "table" and m.buffers or {}) do
        local bytes = type(b) == "table" and type(b.path) == "table" and decode_buffer(b)
        if bytes then
          paths[#paths + 1] = b.path
          bufs[#bufs + 1] = bytes
        else
          log.warn("saved widget buffer of " .. m.model_id .. " skipped (encoding or data)")
        end
      end
      merge(entry, type(m.state) == "table" and m.state or {}, paths, bufs)
      normalize_outputs(entry)
      sess.models[m.model_id] = entry
      n = n + 1
    end
  end
  -- A cell already subscribed to a model redraws against the loaded one.
  local ids = {}
  for id in pairs(sess.views) do ids[#ids + 1] = id end
  if #ids > 0 then touch(sid, sess, ids) end
  return n
end

-- The session's mirror is dropped (the notebook closed, or its state moved).
function W.drop(sid)
  sessions[sid] = nil
end

-- A cell is about to be built: what it depended on is dropped from the dependents
-- sets, and the build records it again. The models it read before are kept for
-- W.settle, which decides what they lose.
function W.begin(cell)
  local d = deps[cell]
  if not d then return end
  local sess = sessions[d.sid]
  if sess then
    for id in pairs(d.ids) do
      local set = sess.views[id]
      if set then set[cell] = nil end
    end
  end
  d.prev = d.ids
  d.ids = {}
end

-- A model with no dependent left: its empty dependents set goes, and a tombstone (a
-- closed model) goes with it. A tombstone is kept while a cell shows the closed
-- model, so the view stays empty; once no cell shows it, nothing needs it.
local function forget_unused(sess, id)
  local set = sess.views[id]
  if set and next(set) == nil then
    sess.views[id] = nil
    set = nil
  end
  local entry = sess.models[id]
  if entry and entry.closed and not set then sess.models[id] = nil end
end

-- A build of a cell is done: each model it read before and does not read now has lost
-- a dependent, and is forgotten if nothing else depends on it.
function W.settle(cell)
  local d = deps[cell]
  if not d or not d.prev then return end
  local prev = d.prev
  d.prev = nil
  local sess = sessions[d.sid]
  if not sess then return end
  for id in pairs(prev) do
    if not d.ids[id] then forget_unused(sess, id) end
  end
end

-- An output sync of the session's notebook has built its cells (jupynvim's
-- _apply_output_sync calls this). A tombstone of a model closed while no cell depended
-- on it goes now, unless a cell built since depends on it (then W.settle forgets it
-- once that cell stops showing it). pending says another sync still waits: a cell it
-- builds may show the closed model, so nothing goes until that one has run.
function W.sweep(sid, pending)
  local sess = sessions[sid]
  if pending or not sess or next(sess.orphans) == nil then return end
  for id in pairs(sess.orphans) do forget_unused(sess, id) end
  sess.orphans = {}
end

-- ── The text form ────────────────────────────────────────────────────────
-- A view is a block: lines of text and the highlight spans of its bars. A
-- block's rows are 1-based, span columns are 0-based byte offsets, and the
-- end column is exclusive. Containers join their children's blocks; every
-- model the walk reads is recorded as a dependency of the cell (record).

local HEAVY, DOT, LIGHT, FULL = "━", "●", "─", "█"
local PARTIAL = { "▏", "▎", "▍", "▌", "▋", "▊", "▉" }
local MAX_DEPTH = 32
-- The widest a column of a side-by-side box shows, in display cells (hcat). A fixed
-- bound, not the window's width: the output rows are the buffer's text, which must not
-- change with the window (an undo file reads back only onto the text it was written
-- from), and the bound caps what one long row costs a box.
W.COLUMN_MAX = 120
-- The last cell of a row cut to that bound.
local CUT_MARK = "…"
-- Where a model sits in a walk (render_model). A root view, or a view nested in
-- an Output widget, shows the output's text/plain when its model is missing or
-- unknown; a child of a container shows nothing for it. A model from another
-- module shows as "[name]" below the root, and the root shows its text/plain.
local AT_ROOT, AT_OUTPUT, AT_CHILD = "root", "output", "child"
local TRACK_FALLBACK = "#3b4261"
-- The five bar groups, their bar_style, the palette token they take (the track
-- token is the background), and without a palette the group they take the
-- foreground from and the colour they take when that group has none.
local BAR_GROUPS = { "JupynvimWidgetBar", "JupynvimWidgetBarSuccess", "JupynvimWidgetBarInfo",
  "JupynvimWidgetBarWarning", "JupynvimWidgetBarDanger" }
local BAR_TOKEN = { "accent", "ok", "info", "warn", "error" }
local BAR_SOURCE = { "Function", "DiagnosticOk", "DiagnosticInfo", "DiagnosticWarn", "DiagnosticError" }
local BAR_FALLBACK = { "#2196f3", "#4caf50", "#00bcd4", "#ff9800", "#f44336" }
local BAR_STYLE = { [""] = 1, success = 2, info = 3, warning = 4, danger = 5 }
local CSS = { black = "000000", white = "ffffff", red = "ff0000", green = "008000", blue = "0000ff",
  yellow = "ffff00", orange = "ffa500", purple = "800080", gray = "808080", grey = "808080",
  cyan = "00ffff", magenta = "ff00ff", pink = "ffc0cb", brown = "a52a2a", lime = "00ff00",
  navy = "000080", teal = "008080", olive = "808000", maroon = "800000", silver = "c0c0c0",
  gold = "ffd700", lightgreen = "90ee90" }
local IMAGE_MIMES = { "image/gif", "image/png", "image/jpeg" }
local BLOCK_CLOSE = { p = true, div = true, li = true, tr = true, h1 = true, h2 = true, h3 = true,
  h4 = true, h5 = true, h6 = true }
local ENTITY = { lt = "<", gt = ">", amp = "&", quot = '"', apos = "'", nbsp = "\194\160" }

-- custom bar groups made so far: group name -> "#rrggbb"
local CUSTOM = {}
-- what set_bar_hl last gave each bar group: name -> { fg, bg } (numbers)
local GIVEN = {}
-- the images of an output, per output table (weak keys), for the render path
local image_cache = setmetatable({}, { __mode = "k" })

local function clamp(x, lo, hi)
  if x < lo then return lo end
  if x > hi then return hi end
  return x
end

-- A block with no rows, and one line of text.
local function empty() return { lines = {}, spans = {} } end
-- A block from text lines. A line with a line break in it becomes one row per
-- part, so no row of a block ever holds a newline (nvim_buf_set_lines refuses
-- one). A row that holds a data URI becomes the cell's marker for it (init.lua
-- _text_row) here, at the leaf, so no box ever lines its columns up to the URI's
-- width. Every block of text is made here, so none can slip one through (a
-- progress bar's one row takes the same rule).
local function lines_block(lines)
  local text_row = notebook()._text_row
  local rows = {}
  for _, l in ipairs(lines) do
    if l:find("\n", 1, true) then
      for _, part in ipairs(vim.split(l, "\n", { plain = true })) do rows[#rows + 1] = (text_row(part)) end
    else
      rows[#rows + 1] = (text_row(l))
    end
  end
  return { lines = rows, spans = {} }
end
local function leaf(s) return lines_block({ s }) end

local function as_str(v)
  if type(v) == "table" then return table.concat(v, "") end
  if type(v) == "string" then return v end
  return ""
end

-- A row cut to at most max display cells: its longest start that leaves one cell, then
-- the cut mark. The walk goes one character at a time from the start, so it costs the
-- cells shown, not the row. A character is measured alone, which is never less than
-- its width inside the row (a composing character alone is one cell), so the cut never
-- shows more than max cells; a byte that is not UTF-8 is a character of its own.
-- Returns the row, its width and how many bytes of the text it keeps.
local function cut_row(line, max)
  local room, used, pos, n = max - 1, 0, 1, #line
  while pos <= n do
    local last = pos + vim.str_utf_end(line, pos)
    local w = vim.api.nvim_strwidth(line:sub(pos, last))
    if used + w > room then break end
    used = used + w
    pos = last + 1
  end
  local row = line:sub(1, pos - 1) .. CUT_MARK
  return row, vim.api.nvim_strwidth(row), pos - 1
end

-- Blocks side by side, one space apart. A shorter block gets blank rows, and every
-- block but the last is padded to its width, so the next one lines up; a row ends
-- where its last text ends (padding that nothing follows is dropped). A row wider than
-- W.COLUMN_MAX is cut to it (cut_row): a column takes its widest row's width on every
-- row, so one long row would make every row of the box that long, and push the next
-- column out of view. One block alone has no neighbour, and comes back as it is.
-- Spans move with their text, and a span past a cut is cut with it.
-- The cut markers (hides) of a row stand for the rows they hide once, not once per
-- column, and the box's markers stand for as many lines as its longest column expands
-- to: that is what the cell counts (init.lua build), and what <leader>no shows.
local function hcat(parts)
  local kept = {}
  for _, b in ipairs(parts) do
    if #b.lines > 0 then kept[#kept + 1] = b end
  end
  if #kept == 0 then return empty() end
  if #kept == 1 then return kept[1] end
  local max = W.COLUMN_MAX
  -- per block: its rows cut to the bound, their widths and the bytes a cut kept, its
  -- width, its spans by row and its markers
  local cols, rows, full = {}, 0, 0
  for k, b in ipairs(kept) do
    local lines, widths, cut_at, w = {}, {}, {}, 0
    for r, l in ipairs(b.lines) do
      local lw = vim.api.nvim_strwidth(l)
      if lw > max then l, lw, cut_at[r] = cut_row(l, max) end
      lines[r], widths[r] = l, lw
      if lw > w then w = lw end
    end
    local by_row = {}
    for _, sp in ipairs(b.spans) do
      local list = by_row[sp[1]]
      if not list then
        list = {}
        by_row[sp[1]] = list
      end
      list[#list + 1] = sp
    end
    -- the lines the block expands to: a row each, and a marker row every line it hides
    local hides, n = b.hides or {}, #lines
    for _, h in pairs(hides) do n = n + h - 1 end
    if n > full then full = n end
    if #lines > rows then rows = #lines end
    cols[k] = { lines = lines, widths = widths, cut_at = cut_at, width = w, spans = by_row, hides = hides }
  end
  local lines, spans, hides = {}, {}, {}
  for r = 1, rows do
    local pieces, len, stop = {}, 0, 0
    for k, c in ipairs(cols) do
      if k > 1 then
        pieces[#pieces + 1] = " "
        len = len + 1
      end
      local text = c.lines[r] or ""
      local list = c.spans[r]
      if list then
        local limit = c.cut_at[r]
        for _, sp in ipairs(list) do
          local e = limit and math.min(sp[3], limit) or sp[3]
          if sp[2] < e then spans[#spans + 1] = { r, sp[2] + len, e + len, sp[4] } end
        end
      end
      local h = c.hides[r]
      if h then hides[r] = math.max(hides[r] or 0, h) end
      pieces[#pieces + 1] = text
      len = len + #text
      if text ~= "" then stop = len end
      local gap = k < #cols and c.width - (c.widths[r] or 0) or 0
      if gap > 0 then
        pieces[#pieces + 1] = (" "):rep(gap)
        len = len + gap
      end
    end
    lines[r] = table.concat(pieces):sub(1, stop)
  end
  -- Markers on different rows each stand for their own column's hidden lines, which
  -- add up past the lines the box expands to; the later ones then stand for fewer.
  local over = rows - full
  for _, h in pairs(hides) do over = over + h - 1 end
  if over > 0 then
    local marked = vim.tbl_keys(hides)
    table.sort(marked, function(a, b) return a > b end)
    for _, r in ipairs(marked) do
      local d = math.min(hides[r] - 1, over)
      hides[r] = hides[r] - d
      over = over - d
      if over == 0 then break end
    end
  end
  return { lines = lines, spans = spans, hides = hides }
end

-- Blocks stacked, each after the last row of the one before.
local function vcat(parts)
  local lines, spans, hides = {}, {}, {}
  for _, b in ipairs(parts) do
    local off = #lines
    for _, l in ipairs(b.lines) do lines[#lines + 1] = l end
    for _, sp in ipairs(b.spans) do
      spans[#spans + 1] = { sp[1] + off, sp[2], sp[3], sp[4] }
    end
    for row, k in pairs(b.hides or {}) do hides[row + off] = k end
  end
  return { lines = lines, spans = spans, hides = hides }
end

-- A block with every line moved right by n spaces.
local function indent(b, n)
  local pre = (" "):rep(n)
  local lines, spans, hides = {}, {}, {}
  for k, l in ipairs(b.lines) do lines[k] = pre .. l end
  for k, sp in ipairs(b.spans) do spans[k] = { sp[1], sp[2] + n, sp[3] + n, sp[4] } end
  for row, k in pairs(b.hides or {}) do hides[row] = k end
  return { lines = lines, spans = spans, hides = hides }
end

-- A slider track of 20 cells: p heavy cells, the dot, then the light ones.
local function slider_track(p)
  p = clamp(p, 0, 19)
  return HEAVY:rep(p) .. DOT .. LIGHT:rep(19 - p)
end

-- A range track of 20 cells between two positions. When the second is not past
-- the first, it becomes the cell after it (and the first moves back from 19).
local function range_track(p1, p2)
  p1, p2 = clamp(p1, 0, 19), clamp(p2, 0, 19)
  if p2 <= p1 then
    if p1 >= 19 then p1 = 18 end
    p2 = p1 + 1
  end
  return LIGHT:rep(p1) .. DOT .. HEAVY:rep(p2 - p1 - 1) .. DOT .. LIGHT:rep(19 - p2)
end

-- A progress bar of 25 cells: full blocks, one partial block at eighths, spaces.
local function progress_bar(frac)
  frac = clamp(frac, 0, 1)
  local exact = frac * 25
  local full = math.floor(exact)
  local idx = math.floor((exact - full) * 8 + 0.5)
  if idx == 8 then
    full = full + 1
    idx = 0
  end
  local partial = idx > 0 and PARTIAL[idx] or ""
  return FULL:rep(full) .. partial .. (" "):rep(25 - full - (idx > 0 and 1 or 0))
end

-- Track position of a fraction, 0..19.
local function cell_pos(frac)
  return math.floor(clamp(frac, 0, 1) * 19 + 0.5)
end

local function frac_of(v, lo, hi)
  if hi == lo then return 0 end
  return clamp((v - lo) / (hi - lo), 0, 1)
end

-- A value as its readout format says: "d" rounds to an integer, ".Nf", ".Ng",
-- ".Ne" and ".N%" as printf, anything else %.15g. The precision N is clamped the
-- way d3-format clamps it (the frontend formats with it): 0..20 for f, e and %,
-- 1..21 for g, so ".005f" is 5 and ".100f" is 20. printf takes no more digits.
local function fmt(v, spec)
  if type(v) ~= "number" then return as_str(v) end
  if spec == "d" then return string.format("%d", math.floor(v + 0.5)) end
  if type(spec) == "string" then
    local n, c = spec:match("^%.(%d+)([fge])$")
    if n then
      local lo, hi = 0, 20
      if c == "g" then lo, hi = 1, 21 end
      return string.format("%." .. clamp(tonumber(n), lo, hi) .. c, v)
    end
    n = spec:match("^%.(%d+)%%$")
    if n then return string.format("%." .. clamp(tonumber(n), 0, 20) .. "f", v * 100) .. "%" end
  end
  return string.format("%.15g", v)
end

local function utf8char(n)
  if n < 0x80 then return string.char(n) end
  if n < 0x800 then return string.char(0xC0 + math.floor(n / 64), 0x80 + n % 64) end
  if n < 0x10000 then
    return string.char(0xE0 + math.floor(n / 4096), 0x80 + math.floor(n / 64) % 64, 0x80 + n % 64)
  end
  if n <= 0x10FFFF then
    return string.char(0xF0 + math.floor(n / 262144), 0x80 + math.floor(n / 4096) % 64,
      0x80 + math.floor(n / 64) % 64, 0x80 + n % 64)
  end
  return nil
end

local function decode_entities(s)
  return (s:gsub("&(#?[%w]+);", function(name)
    if name:sub(1, 1) == "#" then
      local hex = name:sub(2, 2) == "x" or name:sub(2, 2) == "X"
      local n = tonumber(hex and name:sub(3) or name:sub(2), hex and 16 or 10)
      return n and utf8char(n) or nil
    end
    return ENTITY[name]
  end))
end

-- The text of an HTML value: whitespace runs are one space, <br> and the
-- closing block tags are line ends, other tags go, and the entities are
-- decoded. U+2007 and U+00A0 show as spaces (as the widgets' tqdm does).
local function html_to_text(s)
  if type(s) ~= "string" then return "" end
  s = s:gsub("%s+", " ")
  s = s:gsub("<br%s*/?>", "\n")
  s = s:gsub("</(%w+)>", function(t) if BLOCK_CLOSE[t] then return "\n" end return nil end)
  s = s:gsub("<[^>]*>", "")
  local lines = vim.split(s, "\n", { plain = true })
  for k, l in ipairs(lines) do
    l = l:gsub("^ +", ""):gsub(" +$", "")
    l = decode_entities(l)
    l = l:gsub("\226\128\135", " "):gsub("\194\160", " ")
    lines[k] = l
  end
  if lines[1] == "" then table.remove(lines, 1) end
  if #lines > 0 and lines[#lines] == "" then table.remove(lines) end
  return table.concat(lines, "\n")
end

-- Text with each line break replaced by a space, so it fits on one row.
local function oneline(s)
  return (s:gsub("[\r\n]", " "))
end

local function trim(s)
  return ((s:gsub("^%s+", "")):gsub("%s+$", ""))
end

-- A colour of a bar_color: #rgb, #rrggbb or a CSS name, as six lowercase hex digits.
local function parse_color(v)
  if type(v) ~= "string" then return nil end
  local s = v:lower()
  local r, g, b = s:match("^#(%x)(%x)(%x)$")
  if r then return r .. r .. g .. g .. b .. b end
  local six = s:match("^#(%x%x%x%x%x%x)$")
  if six then return six end
  return CSS[s]
end

local function fg_of(name)
  local ok, h = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  if ok and h.fg then return h.fg end
  return nil
end

-- The palette's tokens when it has derived them, else nil. It never starts a
-- derivation: setup_hl runs at setup() and on every ColorScheme, where nothing
-- may load (want_palette asks, once a bar is drawn).
local function palette_tokens()
  local P = package.loaded["jupynvim.palette"]
  if type(P) ~= "table" or type(P.info) ~= "function" or type(P.get) ~= "function" then return nil end
  local ok, info = pcall(P.info)
  if not ok or type(info) ~= "table" or info.state ~= "ok" then return nil end
  local okg, t = pcall(P.get)
  if okg and type(t) == "table" then return t end
  return nil
end

local function color_num(c)
  if type(c) == "number" then return c end
  if type(c) == "string" and c:match("^#%x%x%x%x%x%x$") then return tonumber(c:sub(2), 16) end
  return nil
end

local function track_color(tokens)
  return color_num(tokens and tokens.track) or fg_of("LineNr") or color_num(TRACK_FALLBACK)
end

-- Sets a bar group to fg on bg when the group is empty (never defined, or
-- cleared by a colourscheme's :hi clear) or still holds what this module last
-- gave it; a definition someone else made (a colourscheme, the user, a link)
-- is left alone, as default = true leaves it. default = true alone would also
-- keep our own earlier colours when the palette changes without a :hi clear
-- (the terminal's background, a token override), hence force.
local function set_bar_hl(name, fg, bg)
  local cur = vim.api.nvim_get_hl(0, { name = name, create = false })
  local last = GIVEN[name]
  local ours = last ~= nil and vim.deep_equal(cur, { fg = last.fg, bg = last.bg, default = true })
  if next(cur) ~= nil and not ours then return end
  vim.api.nvim_set_hl(0, name, { default = true, force = true, fg = fg, bg = bg })
  GIVEN[name] = { fg = fg, bg = bg }
end

-- Defines a custom bar group the first time a view shows its colour.
local function custom_group(hex)
  local name = "JupynvimWidgetBar_" .. hex
  if not CUSTOM[name] then
    CUSTOM[name] = "#" .. hex
    set_bar_hl(name, tonumber(hex, 16), track_color(palette_tokens()))
  end
  return name
end

-- The first bar drawn asks for the palette (it loads the library, away from
-- the UI thread), once per process, from the next tick: a draw runs inside a
-- buffer rewrite, and the palette may write its question to the terminal.
-- The bar groups follow every palette from then on (User JupynvimPalette).
local palette_asked = false
local function want_palette()
  if palette_asked then return end
  palette_asked = true
  vim.schedule(function()
    local okp, P = pcall(require, "jupynvim.palette")
    if not okp or type(P) ~= "table" or type(P.when_ready) ~= "function" then return end
    pcall(vim.api.nvim_create_autocmd, "User", {
      group = vim.api.nvim_create_augroup("jupynvim_widget_palette", { clear = true }),
      pattern = "JupynvimPalette",
      callback = function() pcall(W.setup_hl) end,
    })
    local okw, err = pcall(P.when_ready, function(tokens)
      if tokens then pcall(W.setup_hl) end
    end)
    if not okw then log.warn("widgets: the palette could not be asked: " .. tostring(err)) end
  end)
end

local function nn_num(v, default)
  v = nn(v)
  if type(v) == "number" then return v end
  return default
end

local function list_of(v)
  v = nn(v)
  if type(v) ~= "table" then return {} end
  return v
end

-- The text items of a list: strings as they are, numbers through %.15g.
local function texts(v)
  local out = {}
  for k, x in ipairs(list_of(v)) do
    if type(x) == "string" then
      out[k] = x
    elseif type(x) == "number" then
      out[k] = fmt(x)
    else
      out[k] = ""
    end
  end
  return out
end

local function index_of(s, key)
  return nn_num(s[key], nil)
end

-- The titles of a Tab or an Accordion, one per child (count of them): the titles
-- list of ipywidgets 8, or, when the list is absent, the _titles dict of
-- ipywidgets 7, whose keys are the child indices as strings ("0", "1", ...).
local function titles_of(s, count)
  if nn(s.titles) ~= nil then return texts(s.titles) end
  local dict = nn(s._titles)
  local out = {}
  for k = 1, count do
    out[k] = type(dict) == "table" and text(nn(dict[tostring(k - 1)])) or ""
  end
  return out
end

-- A label's description, tags removed when the widget allows HTML.
local function label_of(e)
  local d = nn(e.state.description)
  if type(d) ~= "string" then return "" end
  if nn(e.state.description_allow_html) == true then d = d:gsub("<[^>]*>", "") end
  return oneline(d)
end

-- The description as a prefix: its text and one space, or nothing.
local function desc_of(e)
  local d = label_of(e)
  if d == "" then return "" end
  return d .. " "
end

-- The text that follows a description's first line, indented to its width on
-- later lines.
local function with_desc(desc, lines)
  local out = {}
  local cont = (" "):rep(vim.api.nvim_strwidth(desc))
  for k, l in ipairs(lines) do out[k] = (k == 1 and desc or cont) .. l end
  return out
end

-- The readout of a slider: nil when readout is false.
local function readout_of(s, default)
  if nn(s.readout) == false then return nil end
  local rf = nn(s.readout_format)
  if type(rf) ~= "string" then rf = default end
  return rf
end

local function slider(e, default_fmt)
  local s = e.state
  local lo, hi = nn_num(s.min, 0), nn_num(s.max, 100)
  local v = nn_num(s.value, lo)
  local line = desc_of(e) .. slider_track(cell_pos(frac_of(v, lo, hi)))
  local rf = readout_of(s, default_fmt)
  if rf then line = line .. " " .. fmt(v, rf) end
  return leaf(line)
end

local function log_slider(e)
  local s = e.state
  local base = nn_num(s.base, 10)
  local lo, hi = nn_num(s.min, -10), nn_num(s.max, 10)
  local v = nn_num(s.value, 1)
  local lb = math.log(base)
  if lb == 0 then lb = 1 end
  local lv = v > 0 and math.log(v) / lb or lo
  local line = desc_of(e) .. slider_track(cell_pos(frac_of(lv, lo, hi)))
  local rf = readout_of(s, ".3g")
  if rf then line = line .. " " .. fmt(v, rf) end
  return leaf(line)
end

local function range_slider(e, default_fmt)
  local s = e.state
  local lo, hi = nn_num(s.min, 0), nn_num(s.max, 100)
  local a, b = lo, hi
  local v = nn(s.value)
  if type(v) == "table" then
    a, b = nn_num(v[1], lo), nn_num(v[2], hi)
  end
  local track = range_track(cell_pos(frac_of(a, lo, hi)), cell_pos(frac_of(b, lo, hi)))
  local line = desc_of(e) .. track
  local rf = readout_of(s, default_fmt)
  if rf then line = line .. " " .. fmt(a, rf) .. " - " .. fmt(b, rf) end
  return leaf(line)
end

-- The label of option k (1-based) of a list, or "".
local function label_at(labels, k)
  return labels[k + 1] or ""
end

local function selection_slider(e)
  local s = e.state
  local labels = texts(s._options_labels)
  local idx = index_of(s, "index") or 0
  local n = #labels
  local frac = n > 1 and idx / (n - 1) or 0
  return leaf(desc_of(e) .. slider_track(cell_pos(frac)) .. " " .. trim(label_at(labels, idx)))
end

local function selection_range(e)
  local s = e.state
  local labels = texts(s._options_labels)
  local ix = list_of(s.index)
  local n = #labels
  local i1, i2 = nn_num(ix[1], 0), nn_num(ix[2], math.max(n - 1, 0))
  local frac = function(i) return n > 1 and i / (n - 1) or 0 end
  return leaf(desc_of(e) .. range_track(cell_pos(frac(i1)), cell_pos(frac(i2))) .. " "
    .. trim(label_at(labels, i1)) .. " - " .. trim(label_at(labels, i2)))
end

local function check(e)
  return leaf((nn(e.state.value) == true and "[x] " or "[ ] ") .. label_of(e))
end

local function valid(e)
  local s = e.state
  if nn(s.value) == true then return leaf(desc_of(e) .. "✓") end
  -- the readout as the state carries it (its default is "Invalid")
  return leaf(desc_of(e) .. "✗ " .. as_str(nn(s.readout)))
end

local function button(e)
  return leaf("[ " .. label_of(e) .. " ]")
end

local function dropdown(e)
  local labels = texts(e.state._options_labels)
  return leaf(desc_of(e) .. "[" .. label_at(labels, index_of(e.state, "index") or -1) .. " v]")
end

local function select_one(e)
  local labels = texts(e.state._options_labels)
  return leaf(desc_of(e) .. "[" .. label_at(labels, index_of(e.state, "index") or -1) .. "]")
end

local function select_multiple(e)
  local labels = texts(e.state._options_labels)
  local shown = {}
  for _, i in ipairs(list_of(e.state.index)) do
    if type(i) == "number" then shown[#shown + 1] = label_at(labels, i) end
  end
  return leaf(desc_of(e) .. "[" .. table.concat(shown, ", ") .. "]")
end

local function radio(e)
  local labels = texts(e.state._options_labels)
  local sel = index_of(e.state, "index")
  local opts = {}
  for k, l in ipairs(labels) do
    opts[k] = ((k - 1 == sel) and "(*) " or "( ) ") .. l
  end
  return leaf(desc_of(e) .. table.concat(opts, "  "))
end

local function toggle_buttons(e)
  local labels = texts(e.state._options_labels)
  local sel = index_of(e.state, "index")
  local opts = {}
  for k, l in ipairs(labels) do
    opts[k] = (k - 1 == sel) and ("[*" .. l .. "*]") or ("[ " .. l .. " ]")
  end
  return leaf(desc_of(e) .. table.concat(opts, " "))
end

-- A value shown in brackets: the value, or the placeholder when it is "".
local function text_value(e)
  local v = nn(e.state.value)
  local shown
  if type(v) == "number" then
    shown = fmt(v)
  elseif type(v) == "string" and v ~= "" then
    shown = oneline(v)
  else
    shown = oneline(as_str(nn(e.state.placeholder)))
  end
  return leaf(desc_of(e) .. "[" .. shown .. "]")
end

local function utf8_len(s)
  return #s - select(2, s:gsub("[\128-\191]", ""))
end

local function password(e)
  local v = as_str(nn(e.state.value))
  return leaf(desc_of(e) .. "[" .. ("*"):rep(utf8_len(v)) .. "]")
end

local function textarea(e)
  -- A textarea's value has its line ends as LF (a browser reads CR and CRLF as
  -- one line end), so a carriage return never reaches a row.
  local v = as_str(nn(e.state.value)):gsub("\r\n?", "\n")
  return lines_block(with_desc(desc_of(e), vim.split(v, "\n", { plain = true })))
end

local function color_picker(e)
  return leaf(desc_of(e) .. oneline(as_str(nn(e.state.value))))
end

-- YYYY-MM-DD from a picker value (its month counts from 0).
local function date_text(v)
  if type(v) ~= "table" then return "" end
  return string.format("%04d-%02d-%02d", nn_num(v.year, 0), nn_num(v.month, 0) + 1, nn_num(v.date, 0))
end

local function time_text(v)
  if type(v) ~= "table" then return "" end
  local h, m = nn_num(v.hours, 0), nn_num(v.minutes, 0)
  if nn_num(v.seconds, 0) ~= 0 or nn_num(v.milliseconds, 0) ~= 0 then
    return string.format("%02d:%02d:%02d", h, m, nn_num(v.seconds, 0))
  end
  return string.format("%02d:%02d", h, m)
end

local function date_picker(e)
  return leaf(desc_of(e) .. "[" .. date_text(nn(e.state.value)) .. "]")
end

local function time_picker(e)
  return leaf(desc_of(e) .. "[" .. time_text(nn(e.state.value)) .. "]")
end

local function datetime(e)
  local v = nn(e.state.value)
  local hm = type(v) == "table" and string.format("%02d:%02d", nn_num(v.hours, 0), nn_num(v.minutes, 0)) or ""
  return leaf(desc_of(e) .. "[" .. date_text(v) .. " " .. hm .. "]")
end

-- A list of tags, colours, ints or floats: numbers through the widget's format.
local function list_inputs(e)
  local s = e.state
  local out = {}
  for k, x in ipairs(list_of(s.value)) do
    if type(x) == "number" then
      out[k] = fmt(x, nn(s.format))
    else
      out[k] = as_str(x)
    end
  end
  return leaf(desc_of(e) .. "[" .. table.concat(out, ", ") .. "]")
end

local function file_upload(e)
  local n = #list_of(e.state.value)
  local more = n > 0 and (" (" .. n .. ")") or ""
  return leaf("[ " .. label_of(e) .. more .. " ]")
end

local function play(e)
  return leaf(desc_of(e) .. "> " .. fmt(nn_num(e.state.value, 0)))
end

local function controller(e)
  return leaf("Controller " .. fmt(nn_num(e.state.index, 0)))
end

local function media(kind)
  return function(e)
    local s = e.state
    local bytes = type(nn(s.value)) == "string" and #s.value or 0
    return leaf("[" .. kind .. " " .. as_str(nn(s.format)) .. " " .. bytes .. " bytes]")
  end
end

local function label(e)
  return leaf(desc_of(e) .. oneline(as_str(nn(e.state.value))))
end

local function html(e)
  local lines = vim.split(html_to_text(nn(e.state.value)), "\n", { plain = true })
  return lines_block(with_desc(desc_of(e), lines))
end

-- A progress bar: its text and one span over the bar, group by bar_style, or the
-- style's bar_color when that parses.
local function progress(e, style)
  local s = e.state
  local lo, hi = nn_num(s.min, 0), nn_num(s.max, 100)
  local bar = progress_bar(frac_of(nn_num(s.value, lo), lo, hi))
  local desc = desc_of(e)
  local bc = style and style.state and parse_color(nn(style.state.bar_color))
  want_palette()
  local group
  if bc then
    group = custom_group(bc)
  else
    group = BAR_GROUPS[BAR_STYLE[as_str(nn(s.bar_style))] or 1]
  end
  local line = desc .. bar
  -- a description holding a data URI makes the row the marker (lines_block), with no bar
  if select(2, notebook()._text_row(line)) then return leaf(line) end
  return { lines = { line }, spans = { { 1, #desc, #line, group } } }
end

-- The ids of a container's children, in order (its refs).
local function children_refs(e)
  local out = {}
  for _, r in ipairs(list_of(e.state.children)) do out[#out + 1] = r end
  return out
end

local function ref_id(v)
  v = nn(v)
  if type(v) == "string" and v:sub(1, #REF) == REF then return v:sub(#REF + 1) end
  return nil
end

local function flex_column(layout)
  if not (layout and layout.state) then return false end
  local f = nn(layout.state.flex_flow)
  if type(f) == "table" then
    for _, x in ipairs(f) do
      if x == "column" then return true end
    end
    return false
  end
  return type(f) == "string" and f:find("column", 1, true) ~= nil
end

local function hidden(layout)
  if not (layout and layout.state) then return false end
  local s = layout.state
  return nn(s.display) == "none" or nn(s.visibility) == "hidden"
end

-- The model ids a view reads, recorded as the cell's dependencies. ctx holds the
-- walk's state: reads (id -> true), stack (ids being rendered, the cycle guard),
-- and images when the walk collects an Output widget's images.
local function new_ctx(sid, sess, images)
  return { sid = sid, sess = sess, reads = {}, stack = {}, images = images }
end

local function read(ctx, id)
  if type(id) ~= "string" or id == "" then return nil end
  ctx.reads[id] = true
  return ctx.sess.models[id]
end

local render_model

local function render_child(ctx, ref, depth)
  local cid = ref_id(ref)
  if not cid then return empty() end
  return render_model(ctx, cid, depth, AT_CHILD)
end

local function collect_images(ctx, id, j, o)
  local data = o.data
  if type(data) ~= "table" then return end
  for _, m in ipairs(IMAGE_MIMES) do
    local v = data[m]
    if type(v) == "table" then v = table.concat(v, "") end
    if type(v) == "string" and v ~= "" then
      ctx.images[#ctx.images + 1] = { suffix = id .. "." .. j, b64 = v, mime = m }
      return
    end
  end
end

local function output_block(ctx, id, e, depth)
  local outs = nn(e.state.outputs)
  if type(outs) ~= "table" then return empty() end
  local nbm = notebook()
  local parts = {}
  for j, o in ipairs(outs) do
    if type(o) == "table" then
      local kind = o.output_type
      -- An images-only walk (view_images) processes no text: the streams and errors
      -- are skipped, and a result shows only what its nested views hold.
      if kind == "stream" and not ctx.images_only then
        -- cut the way a cell's stream is cut, before the text passes (init.lua
        -- _stream_rows): the marker row carries its hidden count to the cell's count
        local rows, mark, hidden = nbm._stream_rows(as_str(o.text), ctx.cap,
          function() return nbm._more_after(outs, j) end)
        if not (#rows == 1 and rows[1] == "" and not mark) then
          local part = lines_block(rows)
          if mark then part.hides = { [mark] = hidden } end
          parts[#parts + 1] = part
        end
      elseif kind == "execute_result" or kind == "display_data" then
        local data = type(o.data) == "table" and o.data or {}
        local view = data[W.VIEW_MIME]
        local vid = type(view) == "table" and nn(view.model_id) or nil
        local nested = type(vid) == "string" and render_model(ctx, vid, depth + 1, AT_OUTPUT) or nil
        if nested then
          parts[#parts + 1] = nested
        elseif not ctx.images_only then
          local txt = nbm._result_text(o)
          if txt ~= "" then parts[#parts + 1] = lines_block(vim.split(txt, "\n", { plain = true })) end
        end
        if ctx.images then collect_images(ctx, id, j, o) end
      elseif kind == "error" and not ctx.images_only then
        local lines = {}
        -- an evalue may span lines: lines_block gives each line its own row
        local msg = as_str(o.ename) .. ": " .. as_str(o.evalue)
        if msg ~= ": " then lines[#lines + 1] = msg end
        for _, tb in ipairs(list_of(o.traceback)) do
          for _, l in ipairs(vim.split(nbm._strip_ansi(as_str(tb)), "\n", { plain = true })) do
            lines[#lines + 1] = l
          end
        end
        if #lines > 0 then parts[#parts + 1] = lines_block(lines) end
      end
    end
  end
  return vcat(parts)
end

local function box(vertical)
  return function(ctx, _, e, depth, layout)
    local parts = {}
    for _, r in ipairs(children_refs(e)) do
      local b = render_child(ctx, r, depth + 1)
      if #b.lines > 0 then parts[#parts + 1] = b end
    end
    if vertical or flex_column(layout) then return vcat(parts) end
    return hcat(parts)
  end
end

local function accordion(ctx, _, e, depth)
  local refs = children_refs(e)
  local titles = titles_of(e.state, #refs)
  local sel = index_of(e.state, "selected_index")
  local parts = {}
  for k, r in ipairs(refs) do
    local open = sel == k - 1
    parts[#parts + 1] = leaf((open and "▾ " or "▸ ") .. (titles[k] or ""))
    if open then parts[#parts + 1] = indent(render_child(ctx, r, depth + 1), 2) end
  end
  return vcat(parts)
end

local function tab(ctx, _, e, depth)
  local refs = children_refs(e)
  if #refs == 0 then return empty() end
  local titles = titles_of(e.state, #refs)
  local sel = index_of(e.state, "selected_index")
  local hdr = {}
  for k = 1, #refs do
    local t = titles[k] or ""
    hdr[k] = (sel == k - 1) and ("[" .. t .. "]") or t
  end
  local parts = { leaf(table.concat(hdr, " | ")) }
  if sel and refs[sel + 1] then parts[2] = render_child(ctx, refs[sel + 1], depth + 1) end
  return vcat(parts)
end

local function stack(ctx, _, e, depth)
  local refs = children_refs(e)
  local sel = index_of(e.state, "selected_index")
  if sel and refs[sel + 1] then return render_child(ctx, refs[sel + 1], depth + 1) end
  return empty()
end

local MEDIA_IMAGE, MEDIA_AUDIO, MEDIA_VIDEO = media("image"), media("audio"), media("video")

-- The handler of each widget class by model name. A model of another class
-- from @jupyter-widgets gets "[name]" with its description (see dispatch).
local HANDLERS = {
  IntSliderModel = function(_, _, e) return slider(e, "d") end,
  FloatSliderModel = function(_, _, e) return slider(e, ".2f") end,
  FloatLogSliderModel = function(_, _, e) return log_slider(e) end,
  IntRangeSliderModel = function(_, _, e) return range_slider(e, "d") end,
  FloatRangeSliderModel = function(_, _, e) return range_slider(e, ".2f") end,
  SelectionSliderModel = function(_, _, e) return selection_slider(e) end,
  SelectionRangeSliderModel = function(_, _, e) return selection_range(e) end,
  CheckboxModel = function(_, _, e) return check(e) end,
  ToggleButtonModel = function(_, _, e) return check(e) end,
  ValidModel = function(_, _, e) return valid(e) end,
  ButtonModel = function(_, _, e) return button(e) end,
  DropdownModel = function(_, _, e) return dropdown(e) end,
  SelectModel = function(_, _, e) return select_one(e) end,
  SelectMultipleModel = function(_, _, e) return select_multiple(e) end,
  RadioButtonsModel = function(_, _, e) return radio(e) end,
  ToggleButtonsModel = function(_, _, e) return toggle_buttons(e) end,
  TextModel = function(_, _, e) return text_value(e) end,
  IntTextModel = function(_, _, e) return text_value(e) end,
  FloatTextModel = function(_, _, e) return text_value(e) end,
  BoundedIntTextModel = function(_, _, e) return text_value(e) end,
  BoundedFloatTextModel = function(_, _, e) return text_value(e) end,
  ComboboxModel = function(_, _, e) return text_value(e) end,
  PasswordModel = function(_, _, e) return password(e) end,
  TextareaModel = function(_, _, e) return textarea(e) end,
  ColorPickerModel = function(_, _, e) return color_picker(e) end,
  DatePickerModel = function(_, _, e) return date_picker(e) end,
  TimePickerModel = function(_, _, e) return time_picker(e) end,
  TimeModel = function(_, _, e) return time_picker(e) end,
  DatetimeModel = function(_, _, e) return datetime(e) end,
  NaiveDatetimeModel = function(_, _, e) return datetime(e) end,
  TagsInputModel = function(_, _, e) return list_inputs(e) end,
  ColorsInputModel = function(_, _, e) return list_inputs(e) end,
  IntsInputModel = function(_, _, e) return list_inputs(e) end,
  FloatsInputModel = function(_, _, e) return list_inputs(e) end,
  FileUploadModel = function(_, _, e) return file_upload(e) end,
  PlayModel = function(_, _, e) return play(e) end,
  ControllerModel = function(_, _, e) return controller(e) end,
  ImageModel = function(_, _, e) return MEDIA_IMAGE(e) end,
  AudioModel = function(_, _, e) return MEDIA_AUDIO(e) end,
  VideoModel = function(_, _, e) return MEDIA_VIDEO(e) end,
  LabelModel = function(_, _, e) return label(e) end,
  HTMLModel = function(_, _, e) return html(e) end,
  HTMLMathModel = function(_, _, e) return html(e) end,
  HBoxModel = box(false),
  BoxModel = box(false),
  VBoxModel = box(true),
  GridBoxModel = box(true),
  AccordionModel = accordion,
  TabModel = tab,
  StackModel = stack,
  OutputModel = output_block,
  IntProgressModel = function(_, _, e, _, _, style) return progress(e, style) end,
  FloatProgressModel = function(_, _, e, _, _, style) return progress(e, style) end,
}

local function is_widget_module(m)
  return type(m) == "string" and m:find("^@jupyter%-widgets/") ~= nil
end

-- What a missing or unknown model shows: nothing for a child, nil (the output's
-- text/plain) elsewhere.
local function none_or_empty(at)
  if at == AT_CHILD then return empty() end
  return nil
end

-- A dispatch for a model of the widget library, by class. A class the table
-- does not name shows its name without "Model" in brackets, with its description.
local function dispatch(ctx, id, e, depth, layout, style)
  local h = HANDLERS[e.name]
  if h then return h(ctx, id, e, depth, layout, style) end
  local short = e.name:gsub("Model$", "")
  return leaf(desc_of(e) .. "[" .. short .. "]")
end

-- The block of a model at position at (AT_ROOT, AT_OUTPUT or AT_CHILD). A missing
-- or unknown model gives none_or_empty; a model from another module gives nil at
-- the root and "[name]" elsewhere. Anything else gives a block, empty when the
-- model is closed, hidden, cyclic or too deep.
render_model = function(ctx, id, depth, at)
  if id == "" or depth > MAX_DEPTH then return empty() end
  local e = read(ctx, id)
  if not e then return none_or_empty(at) end
  if e.closed or type(e.state) ~= "table" then return empty() end
  if ctx.stack[id] then return empty() end
  local st = e.state
  local layout = read(ctx, ref_id(st.layout))
  local style = read(ctx, ref_id(st.style))
  if hidden(layout) then return empty() end
  if e.name == "" then return none_or_empty(at) end
  if not is_widget_module(e.module) then
    if at == AT_ROOT then return nil end
    return leaf("[" .. e.name .. "]")
  end
  ctx.stack[id] = true
  local block = dispatch(ctx, id, e, depth, layout, style)
  ctx.stack[id] = nil
  return block
end

-- Records the models a cell's view read, so a change to any of them redraws it.
local function record(sid, cell, reads)
  local sess = sessions[sid]
  -- a build of a notebook that was closed records nothing (its mirror is gone)
  if not sess then return end
  local d = deps[cell]
  if not d or d.sid ~= sid then
    d = { sid = sid, ids = {} }
    deps[cell] = d
  end
  for id in pairs(reads) do
    local set = sess.views[id]
    if not set then
      set = setmetatable({}, { __mode = "k" })
      sess.views[id] = set
    end
    set[cell] = true
    d.ids[id] = true
  end
end

-- The root model id of a view output, or nil.
local function view_root(o)
  local data = type(o) == "table" and o.data or nil
  local view = type(data) == "table" and data[W.VIEW_MIME] or nil
  if type(view) ~= "table" then return nil end
  local root = nn(view.model_id)
  if type(root) ~= "string" then return nil end
  return root
end

-- A walk that throws is a state the text form cannot read (a value of the wrong
-- type). The error is logged once per model and message, not at every render.
local logged = {}
local function log_render_error(root, err)
  local key = root .. "\0" .. tostring(err)
  if logged[key] then return end
  logged[key] = true
  log.warn("widget view " .. root .. " shows its text/plain: " .. tostring(err))
end

-- The block a view shows, or nil when the output's text/plain should show (an
-- unknown or third-party root, or a walk that threw). cap is the cell's cut of its
-- streams (see output_block), nil when every line shows. Counted in W.stats.renders.
-- The cell depends on every model the walk reads, including the reads made before a
-- throw, so a fix to any of them redraws the cell. The walk collects the view's
-- Output widget images as well, cached under the cell's revision for view_images, so
-- the images cost no second walk.
function W.view_block(nb, cell, o, cap)
  W.stats.renders = W.stats.renders + 1
  local root = view_root(o)
  if not root then return nil end
  local sess = sessions[nb.session_id]
  if not sess then return nil end
  local ctx = new_ctx(nb.session_id, sess, {})
  ctx.cap = cap
  local ok, block = pcall(render_model, ctx, root, 0, AT_ROOT)
  record(nb.session_id, cell, ctx.reads)
  -- a walk that threw has no images (its partial list is dropped)
  image_cache[o] = { rev = cell._widget_rev or 0, sid = nb.session_id, imgs = ok and ctx.images or {} }
  if not ok then
    log_render_error(root, block)
    return nil
  end
  return block
end

-- The Output widget images under a view output, in order: { suffix, b64, mime }
-- (suffix is the model id and the 1-based index in its outputs). Cached per output
-- table and widget revision of the cell: view_block fills the cache when the cell is
-- built, and a walk of the images alone (no text) answers any other revision asked
-- for. A walk that throws has no images.
function W.view_images(nb, cell, o)
  local root = view_root(o)
  if not root then return {} end
  local sess = sessions[nb.session_id]
  if not sess then return {} end
  local rev = cell._widget_rev or 0
  local hit = image_cache[o]
  if hit and hit.rev == rev and hit.sid == nb.session_id then return hit.imgs end
  local ctx = new_ctx(nb.session_id, sess, {})
  ctx.images_only = true
  local ok, err = pcall(render_model, ctx, root, 0, AT_ROOT)
  local imgs = {}
  if ok then
    imgs = ctx.images
  else
    log_render_error(root, err)
  end
  image_cache[o] = { rev = rev, sid = nb.session_id, imgs = imgs }
  return imgs
end

-- ── highlight groups ─────────────────────────────────────────────────────
-- With a palette the bar groups take their token (accent, ok, info, warn,
-- error) as foreground and the track token as background. Without one (no
-- library, nothing derived yet) they take the foreground of their source group,
-- or the fallback colour, on the track colour (LineNr's foreground). Every
-- custom group made so far is rebuilt on the same track. A colourscheme's or
-- the user's own definition wins (set_bar_hl).
function W.setup_hl()
  local tokens = palette_tokens()
  local track = track_color(tokens)
  for k, group in ipairs(BAR_GROUPS) do
    local fg = color_num(tokens and tokens[BAR_TOKEN[k]]) or fg_of(BAR_SOURCE[k]) or color_num(BAR_FALLBACK[k])
    set_bar_hl(group, fg, track)
  end
  for name, fg in pairs(CUSTOM) do
    set_bar_hl(name, color_num(fg), track)
  end
end

-- Exposed for the spec.
function W._palette_unasked() palette_asked = false end
W._S = slider_track
W._R = range_track
W._P = progress_bar
W._fmt = fmt
W._html_to_text = html_to_text

-- The state of a model without its binary values, as a copy.
local function state_without_buffers(entry)
  local state = vim.deepcopy(entry.state)
  for _, p in ipairs(entry.buffer_paths) do
    if type(walk(entry.state, p, #p)) == "string" then clear_at(state, p) end
  end
  return state
end

-- The saved-state shape of the session's models (not the tombstones), in model
-- id order: the list that W.load reads back. Buffers are base64 at their paths.
-- Every model comes back dead: a restored session starts with no kernel.
function W.export(sid)
  local out = {}
  local sess = sessions[sid]
  if not sess then return out end
  local ids = {}
  for id, entry in pairs(sess.models) do
    -- A model the mirror knows only from an update has no class name, and a
    -- saved state needs one to restore the model.
    if not entry.closed and entry.name ~= "" then ids[#ids + 1] = id end
  end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local entry = sess.models[id]
    local bufs = {}
    for _, p in ipairs(entry.buffer_paths) do
      local bytes = walk(entry.state, p, #p)
      if type(bytes) == "string" then
        bufs[#bufs + 1] = { encoding = "base64", path = p, data = vim.base64.encode(bytes) }
      end
    end
    local state = state_without_buffers(entry)
    out[#out + 1] = {
      model_id = id, model_name = entry.name, model_module = entry.module,
      model_module_version = entry.version,
      state = next(state) ~= nil and state or vim.empty_dict(),
      buffers = bufs, live = false,
    }
  end
  return out
end

-- The connection check and the message for a send to a model that is not live.
local function live_entry(nb, model_id)
  local sess = sessions[nb.session_id]
  local entry = sess and sess.models[model_id]
  if not entry or entry.closed or not entry.live then return nil end
  return entry, sess
end

-- The first cell of nb that shows the model: where a callback's output goes.
local function first_cell(nb, sess, model_id)
  local set = sess.views[model_id]
  if not set then return nil end
  for _, cell in ipairs(nb.cells) do
    if set[cell] then return cell.id end
  end
  return nil
end

local function send_failed(err)
  vim.notify("jupynvim: widget message failed: " .. tostring(err), vim.log.levels.WARN)
end

-- A frontend change to a model. It is applied at once, as an update event
-- would apply it, so the views that show the model redraw; then it is sent.
-- opts.buffer_paths and opts.buffers carry binary values; opts.cell_id picks
-- the cell whose output takes a callback's output. False, with a warning,
-- when the model is unknown, closed or not connected to a kernel.
function W.set(nb, model_id, state, opts)
  opts = opts or {}
  local entry, sess = live_entry(nb, model_id)
  if not entry then
    vim.notify(NOT_CONNECTED, vim.log.levels.WARN)
    return false
  end
  state = state or {}
  local paths, bufs = opts.buffer_paths or {}, opts.buffers or {}
  -- The mirror takes a copy: place() writes the bytes into the state it merges
  -- into, and that state must not be the caller's table or the one sent, which
  -- carry null in those slots (the bytes travel once, in buffers).
  merge(entry, vim.deepcopy(state), paths, bufs)
  bump(entry)
  touch(nb.session_id, sess, { model_id })
  local cell_id = opts.cell_id or first_cell(nb, sess, model_id)
  require("jupynvim")._nb_client(nb):call("widget_update", {
    session_id = nb.session_id,
    model_id = model_id,
    state = next(state) ~= nil and state or vim.empty_dict(),
    buffer_paths = paths,
    buffers = bufs,
    cell_id = cell_id,
  }, function(err)
    if err then send_failed(err) end
  end)
  return true
end

-- A custom message from a widget view (a button click). It changes no state.
-- opts.buffers carries binary values; opts.cell_id as for W.set. False, with a
-- warning, when the model is not connected.
function W.custom(nb, model_id, content, opts)
  opts = opts or {}
  local entry, sess = live_entry(nb, model_id)
  if not entry then
    vim.notify(NOT_CONNECTED, vim.log.levels.WARN)
    return false
  end
  if content == nil or (type(content) == "table" and next(content) == nil) then
    content = vim.empty_dict()
  end
  local cell_id = opts.cell_id or first_cell(nb, sess, model_id)
  require("jupynvim")._nb_client(nb):call("widget_custom", {
    session_id = nb.session_id,
    model_id = model_id,
    content = content,
    buffers = opts.buffers or {},
    cell_id = cell_id,
  }, function(err)
    if err then send_failed(err) end
  end)
  return true
end


return W

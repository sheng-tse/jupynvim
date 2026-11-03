-- Per-buffer notebook state.
--
-- A notebook is bound to one buffer. We track:
--   • backend session_id
--   • ordered cell list  (id, type, source, exec_count, outputs)
--   • for each cell: line ranges in buffer, extmark ids for header/footer/outputs
--
-- The buffer text is the concatenation of cell sources separated by single
-- "marker" lines (CELL_SEP). Cell ids are NOT stored in the buffer text — we
-- recover them by walking marker positions in order against our `cells` list.

local HtmlTable = require("jupynvim.notebook.html_table")

local M = {}

-- The widget mirror (notebook/widgets.lua). That module requires this one only
-- when it is called, so this require at load time is safe.
local Widgets = require("jupynvim.notebook.widgets")

-- Cell table -> buffer of its notebook. A buffer number, not the notebook:
-- LuaJIT's weak keys do not let go of a key that a value refers to, so a
-- notebook held here would keep its cells alive after its buffer closed.
-- M.owner_of resolves it, and checks that the cell is still in the notebook.
M._owner = setmetatable({}, { __mode = "k" })

-- Cell separator: a string very unlikely to appear in real source code.
-- (Plain `# %%` collides with jupytext-formatted notebooks.)
M.CELL_SEP = "# %%[jupynvim:cell-sep]"
-- Output-region marker: lines between OUT_SEP and the next CELL_SEP are
-- the cell's rendered output as REAL buffer text (navigable/yankable with
-- plain vim motions), excluded from the cell source on sync/save.
M.OUT_SEP = "# %%[jupynvim:out]"
M.OUT_TRUNC_MARK = "\u{22EF}"   -- midline ellipsis, marks a capped output

-- A source line that is a marker, followed by any number of spaces, goes
-- into the buffer with one more space and comes back without it. A line
-- reading exactly like a marker was a boundary: opening and saving a
-- notebook that had one split its cell in two and moved every later cell's
-- source onto the next id. A zero-width space showed as <200b>.
local function marker_ish(l)
  for _, m in ipairs({ M.CELL_SEP, M.OUT_SEP }) do
    if #l >= #m and l:byte(1) == 35 and l:sub(1, #m) == m and l:find("^ *$", #m + 1) then
      return true
    end
  end
  return false
end
M._marker_ish = marker_ish

-- Plain-text lines for a cell's outputs (the buffer representation).
local function _as_str(v)
  if type(v) == "table" then return table.concat(v, "") end
  if type(v) == "string" then return v end
  return ""
end

local function _strip_ansi(s)
  s = s:gsub("\27%[[?]?[%d;]*[a-zA-Z]", "")
  s = s:gsub("\27%][^\27]*\27\\", "")
  s = s:gsub("\27.", "")
  return s
end

local function _process_cr(s)
  s = s:gsub("\r\n", "\n")
  local out = {}
  for chunk in (s .. "\n"):gmatch("([^\n]*)\n") do
    local segments = {}
    for seg in (chunk .. "\r"):gmatch("([^\r]*)\r") do
      table.insert(segments, seg)
    end
    table.insert(out, segments[#segments] or "")
  end
  if out[#out] == "" then table.remove(out) end
  return table.concat(out, "\n")
end

-- Rendered-output cap. A single `!tree` of a dataset directory can store 24k
-- lines in a notebook, and every one of them becomes a real buffer line that
-- treesitter and every FileType plugin then parses. VS Code caps the same way
-- (notebook.output.textLineLimit, default 30).
--
-- DISPLAY ONLY: sync_from_buffer skips the output region entirely and saves
-- read cell.outputs from the model, so nothing is lost from the .ipynb.
M.max_output_lines = 500
-- A cut output shows its first lines and this many of its last, as VS Code
-- cuts one, so the end of a log or a closing error stays in view.
M.OUTPUT_TAIL = 5

-- How a cell shows its outputs is kept on the cell table, so each notebook has
-- its own even when two hold the same cell ids, as a copied .ipynb does. A
-- save sends only ids, types and sources, so none of it reaches the file.
--   cell._output_expanded  shows all of an output the cap cuts, <leader>no
--   cell._output_hidden    shows one line for the whole output, <leader>nO
--   cell._output_limit     how many first lines show, for this cell, <leader>nl
-- Render puts the key to press after a marker line instead of in its text, so
-- the buffer, and the undo file written from it, stay the same when keymaps
-- change.

-- Per-cell render cache. output_lines is called from to_lines, which the LSP
-- diagnostic and didChange paths hit dozens of times per keystroke; on a
-- notebook storing a 420KB `!tree` dump that was 27ms EVERY time and pegged the
-- editor at ~97% of wall clock with the main loop starved.
--
-- Weak keys so the entry dies with the cell.
local _ol_cache = setmetatable({}, { __mode = "k" })

-- Cheap, content-derived key: O(#outputs) length lookups, no string scanning.
-- Within one output list, streams append text, new outputs change the count,
-- and display-handle updates bump _rev. The cache also checks the list's
-- identity, since a rerun can replace it with different text of the same
-- length.
local function _out_key(cell)
  -- _widget_rev moves when a widget the cell shows changes (widgets.lua)
  local p = { "w" .. (cell._widget_rev or 0), M.max_output_lines, cell._output_limit or 0,
              cell._output_expanded and 1 or 0, cell._output_hidden and 1 or 0 }
  for _, o in ipairs(cell.outputs or {}) do
    local t, d = o.text, o.data
    p[#p + 1] = (o.output_type or "?") .. (o._rev or "")
    p[#p + 1] = (type(t) == "string" and #t) or (type(t) == "table" and #t) or 0
    if d then
      local tp, th = d["text/plain"], d["text/html"]
      p[#p + 1] = (type(tp) == "string" and #tp) or (type(tp) == "table" and #tp) or 0
      p[#p + 1] = (type(th) == "string" and #th) or (type(th) == "table" and #th) or 0
      p[#p + 1] = (d["image/png"] or d["image/gif"] or d["image/jpeg"]) and 1 or 0
    end
    if o.traceback then p[#p + 1] = "t" .. #o.traceback end
  end
  return table.concat(p, ",")
end

-- The marker line in place of the lines a cap hides, as its text (no indent) and
-- as an output row (indented like the output rows).
local function trunc_text(hidden, total)
  return string.format("%s %d lines hidden (%d total)", M.OUT_TRUNC_MARK, hidden, total)
end
local function trunc_marker(hidden, total)
  return "  " .. trunc_text(hidden, total)
end

-- The text of an output's HTML table, read once per output: a cell is drawn,
-- the cursor moves and the Output widget asks again for the same output, and a
-- table of a megabyte or more takes milliseconds to read. The memo is keyed by
-- the output's data table and holds the HTML it was made from, so a data table
-- that changes in place is read again; false stands for "no table".
local table_memo = setmetatable({}, { __mode = "k" })
local function html_table_text(data, html)
  local m = table_memo[data]
  if m and m.src == html then return m.text or nil end
  local text = HtmlTable.to_text(_as_str(html))
  table_memo[data] = { src = html, text = text or false }
  return text
end

-- The text an execute_result or display_data shows. A figure's repr stays
-- hidden behind its image. The Output widget's text uses it too (widgets.lua).
local function result_text(o)
  local data = o.data or {}
  local text = _as_str(data["text/plain"])
  if (data["image/png"] or data["image/gif"] or data["image/jpeg"])
      and (text == "" or text:match("^<[Ff]igure ")
           or text:match("^<[%w._]+ object>$")
           or text:match("^<[%w._]+ object at 0x[%x]+>$")) then
    return ""
  end
  -- A bare repr like "<pandas.io.formats.style.Styler at 0x...>" says nothing
  -- when the same output carries an HTML table: show the table instead (a
  -- table with no text, an empty DataFrame's Styler, shows nothing).
  local html = data["text/html"]
  if html and (text == "" or text:match("^<[%w._]+ at 0x[%x]+>$")
                or text:match("^<[%w._]+ object at 0x[%x]+>$")) then
    local tbl = html_table_text(data, html)
    if tbl then return tbl end
  end
  return text
end
M._result_text = result_text
M._strip_ansi = _strip_ansi
M._process_cr = _process_cr

-- A row of output text that holds a data URI shows a marker in its place: base64 in
-- the buffer lags the editor even off screen. Returns the row and
-- whether it is the marker. A cell's text rows take it, and so does every row a
-- widget view's leaf makes (widgets.lua lines_block), before a box lines its columns
-- up: a box pads its rows to the widest one, so the URI must be gone by then.
M.EMBEDDED_ROW = "[embedded image data]"
function M._text_row(l)
  if l:find("data:image/%w+;base64,") then return M.EMBEDDED_ROW, true end
  return l, false
end

-- Does any output after the i-th of outputs show more than blank lines? Blank rows at
-- the very end are dropped, so without one a stream's trailing blank lines never show,
-- and its marker must not count them.
function M._more_after(outputs, i)
  for j = i + 1, #outputs do
    local o, t = outputs[j], ""
    -- a JSON null in an Output widget's outputs is vim.NIL: it shows nothing, and
    -- indexing it is an error
    if type(o) ~= "table" then
      t = ""
    elseif o.output_type == "stream" then
      t = _as_str(o.text)
    elseif o.output_type == "execute_result" or o.output_type == "display_data" then
      t = result_text(o)
    elseif o.output_type == "error" then
      t = _as_str(o.ename) .. _as_str(o.evalue) .. table.concat(vim.tbl_map(_as_str, o.traceback or {}))
    end
    if t:find("%S") and (not t:find("\27", 1, true) or _strip_ansi(t):find("%S")) then return true end
  end
  return false
end

-- The rows a stream's text shows under a cap, through _process_cr and _strip_ansi, with
-- no indent. cap is nil (every line shows) or { head, tail, fit }: a stream longer than
-- fit shows its first head rows, a marker row and its last tail rows. Returns the rows,
-- the index of the marker row (nil when nothing is cut) and the lines it hides. more()
-- tells whether a later output shows text (_more_after). The text is split first and
-- only the rows that show are processed: _process_cr and _strip_ansi walk the whole
-- string, which cost 17 ms of 23 ms on a 420 KB stream. Neither changes the line count.
-- A cell's stream and an Output widget's text both take this cut.
function M._stream_rows(text, cap, more)
  local function whole()
    return vim.split(_strip_ansi(_process_cr(text)), "\n", { plain = true })
  end
  if not cap then return whole(), nil, 0 end
  local head, tail, fit = cap.head, cap.tail, cap.fit
  local raw = vim.split(text, "\n", { plain = true })
  local function row_text(i) return _strip_ansi(_process_cr((raw[i]:gsub("\r$", "")))) end
  -- The newline that ends the last line starts no line of its own. Counted as one, a
  -- 1000-line print read "1001 total", took a row of the tail and hid one line more
  -- than it said.
  if #raw > 1 and raw[#raw] == "" then raw[#raw] = nil end
  if #raw > fit and not more() then
    while #raw > 0 and row_text(#raw) == "" do raw[#raw] = nil end
  end
  if #raw <= fit then return whole(), nil, 0 end
  local rows = {}
  for i = 1, head do rows[#rows + 1] = row_text(i) end
  local hidden = #raw - head - tail
  rows[#rows + 1] = trunc_text(hidden, #raw)
  local mark = #rows
  for i = #raw - tail + 1, #raw do rows[#rows + 1] = row_text(i) end
  return rows, mark, hidden
end

-- The rows a cell's outputs show, which of them are markers, whether the cap
-- cut any lines, and how many lines the outputs have in all. `expanded`
-- shows every line.
local function build(cell, expanded)
  -- what this cell depended on is recorded again by the walk below
  Widgets.begin(cell)
  local cap = not expanded and (cell._output_limit or M.max_output_lines) or nil
  local head, tail, fit
  if cap and cap > 0 then
    head = math.floor(cap)
    tail = M.OUTPUT_TAIL
    fit = head + tail + 1   -- past this a cut hides 2 lines or more, never 1
  end

  -- the cap as the stream and view rows take it (nil: every line shows)
  local cap_rows = fit and { head = head, tail = tail, fit = fit } or nil
  local outputs = cell.outputs or {}
  local lines = {}
  local hides = {}   -- row of a stream's marker -> the lines it hides
  -- row -> the bar spans of a widget view on that row, { scol, ecol, hl }
  local spans = {}
  local function more_after(i) return M._more_after(outputs, i) end
  -- A row of text as the cell shows it: a data URI is a marker, not its bytes. Returns
  -- the row and whether it is that marker.
  local function text_row(l)
    local row, marker = M._text_row(l)
    return "  " .. row, marker
  end
  local function add_text(text)
    for _, l in ipairs(vim.split(text, "\n", { plain = true })) do
      table.insert(lines, (text_row(l)))
    end
  end
  -- A stream is cut to the rows the cap shows before any text pass (_stream_rows):
  -- the same cut an Output widget's text gets (widgets.lua output_block).
  local function add_stream(text, at)
    local rows, mark, hidden = M._stream_rows(text, cap_rows, function() return more_after(at) end)
    for k, row in ipairs(rows) do
      if k == mark then
        table.insert(lines, "  " .. row)
        hides[#lines] = hidden
      else
        add_text(row)
      end
    end
  end

  for i, o in ipairs(outputs) do
    if o.output_type == "stream" then
      add_stream(_as_str(o.text), i)
    elseif o.output_type == "execute_result" or o.output_type == "display_data" then
      -- A widget view makes the cell depend on the widget. view_block gives
      -- the block the view draws, or nil, and then the text shows as before.
      -- M._owner and M.get, not owner_of: owner_of scans the cells, and this runs for
      -- every view output of every build. A cell that left its notebook only gets a
      -- dependency record that nothing reads, so the direct read is safe here.
      local owner = o.data and o.data[Widgets.VIEW_MIME] and M._owner[cell]
      local nb = owner and M.get(owner)
      local block = nb and Widgets.view_block(nb, cell, o, cap_rows)
      if block then
        -- the block's rows, with the same row rule as the output's text (a data URI is
        -- a marker); its spans move with them, and a row that became a marker has none.
        -- The leaves already took the rule (widgets.lua lines_block); this is the
        -- backstop for a row no leaf made.
        local base = #lines
        local replaced = {}
        for k, l in ipairs(block.lines) do
          local row, marker = text_row(l)
          lines[#lines + 1] = row
          if marker then replaced[k] = true end
        end
        for _, sp in ipairs(block.spans) do
          if not replaced[sp[1]] then
            local row = base + sp[1]
            spans[row] = spans[row] or {}
            table.insert(spans[row], { sp[2] + 2, sp[3] + 2, sp[4] })
          end
        end
        -- the cut markers of the block (a stream the cap cut), at their rows
        for row, k in pairs(block.hides or {}) do hides[base + row] = k end
      else
        local text = result_text(o)
        if text ~= "" then add_text(text) end
      end
    elseif o.output_type == "error" then
      local msg = _as_str(o.ename) .. ": " .. _as_str(o.evalue)
      if msg ~= ": " then add_text(msg) end
      for _, tb in ipairs(o.traceback or {}) do
        add_text(_strip_ansi(_as_str(tb)))
      end
    end
  end
  Widgets.settle(cell)
  while lines[#lines] == "  " or lines[#lines] == "" do table.remove(lines) end
  for row in pairs(spans) do if row > #lines then spans[row] = nil end end

  -- How many lines rows a..b stand for. A row is one line, and a stream's
  -- marker is every line it hides. Counted as rows, a marker that hid most
  -- of a stream was one line.
  local function count(a, b)
    local n = math.max(0, b - a + 1)
    for row, k in pairs(hides) do
      if row >= a and row <= b then n = n + k - 1 end
    end
    return n
  end
  local total = count(1, #lines)
  local marks = {}
  for row in pairs(hides) do marks[row] = true end

  -- Anything still over the cap (many outputs, or non-stream) is trimmed here
  -- the same way, the first lines and the last few.
  if fit and #lines > fit then
    local shown = {}
    for k = 1, head do shown[#shown + 1] = lines[k] end
    shown[#shown + 1] = trunc_marker(count(head + 1, #lines - tail), total)
    for k = #lines - tail + 1, #lines do shown[#shown + 1] = lines[k] end
    -- a stream's marker sits in what was dropped, unless trailing blank lines
    -- were cut from under it
    local drop = #lines - tail - head - 1
    local kept = { [head + 1] = true }
    for row in pairs(hides) do
      if row > #lines - tail then kept[row - drop] = true end
    end
    -- the spans of the shown head and tail move as the marks do
    local moved = {}
    for row, list in pairs(spans) do
      if row <= head then moved[row] = list
      elseif row > #lines - tail then moved[row - drop] = list end
    end
    lines, marks, spans = shown, kept, moved
  end
  return lines, marks, next(marks) ~= nil, total, spans
end

-- A hidden output shows one line in its place saying what it holds, or
-- nothing when the outputs show nothing anyway.
local function stand_in(cell)
  local _, _, _, n = build(cell, false)
  local imgs = 0
  for _, o in ipairs(cell.outputs or {}) do
    local d = (o.output_type == "execute_result" or o.output_type == "display_data") and o.data
    if d and (d["image/png"] or d["image/gif"] or d["image/jpeg"]) then imgs = imgs + 1 end
  end
  local what = {}
  if imgs > 0 then what[#what + 1] = imgs .. (imgs == 1 and " image" or " images") end
  if n > 0 then what[#what + 1] = n .. (n == 1 and " line" or " lines") end
  if #what == 0 then return {} end
  return { string.format("  %s output hidden (%s)", M.OUT_TRUNC_MARK, table.concat(what, ", ")) }
end

local function cached(cell)
  local key = _out_key(cell)
  local hit = _ol_cache[cell]
  -- A fast run can clear and refill outputs before the debounced render
  -- observes the empty list. Lengths alone then match the previous run and
  -- would keep displaying its result even though the kernel returned a new one.
  if hit and hit.outputs == cell.outputs and hit.key == key then return hit end
  local e = { key = key, outputs = cell.outputs }
  if cell._output_hidden then
    e.lines = stand_in(cell)
    e.marks = #e.lines > 0 and { [1] = "hidden" } or {}
    e.spans = {}
  else
    local marks
    e.lines, marks, e.cut, _, e.spans = build(cell, cell._output_expanded)
    e.marks = {}
    for row in pairs(marks) do e.marks[row] = "cut" end
  end
  _ol_cache[cell] = e
  return e
end

function M.output_lines(cell)
  return cached(cell).lines
end

-- The bar spans of the rows of output_lines(cell): row -> list of { scol, ecol, hl }.
function M.output_spans(cell)
  return cached(cell).spans
end

-- The rows of output_lines(cell) that stand for something not shown, as
-- row -> "cut" for lines the cap hides or "hidden" for a hidden output.
function M.output_marks(cell)
  return cached(cell).marks
end

-- Does the cap cut this cell's output when it is not expanded? Then
-- <leader>no has lines to show, or to cut again.
function M.output_cut(cell)
  if not (cell._output_expanded or cell._output_hidden) then return cached(cell).cut end
  local _, _, cut = build(cell, false)
  return cut
end

-- How many lines the cell's outputs have in all, shown or not.
function M.output_count(cell)
  local _, _, _, n = build(cell, false)
  return n
end

-- Does the cell show anything for its outputs, a line or an image? Then
-- <leader>nO has something to hide.
function M.output_shows(cell)
  return cell.cell_type == "code" and #stand_in(cell) > 0
end

-- "2026-06-12T21:38:05.123Z" -> epoch seconds (fractional). Both stamps
-- come from the same clock and format, so timezone handling cancels out
-- in the subtraction.
local function _iso_to_epoch(s)
  if type(s) ~= "string" then return nil end
  local y, mo, d, h, mi, sec, frac =
    s:match("(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)%.?(%d*)")
  if not y then return nil end
  local t = os.time({
    year = tonumber(y), month = tonumber(mo), day = tonumber(d),
    hour = tonumber(h), min = tonumber(mi), sec = tonumber(sec),
  })
  if not t then return nil end
  return t + (tonumber("0." .. (frac ~= "" and frac or "0")) or 0)
end

-- Saved execution duration in ns from Jupyter-standard timing metadata
-- (metadata.execution stamps written on run; survive save + reopen).
function M.saved_duration_ns(meta)
  local ex = type(meta) == "table" and meta.execution
  if type(ex) ~= "table" then return nil end
  local a = _iso_to_epoch(ex["iopub.execute_input"])
  local b = _iso_to_epoch(ex["shell.execute_reply"])
  if not (a and b) or b < a then return nil end
  return (b - a) * 1e9
end

-- Clean base64 image data once, when an output enters the model, so render
-- (which runs per keystroke) never rescans or rejoins it. The backend keeps
-- its own copy of every output for saving, so the .ipynb is untouched.
local B64_IMAGE = { "image/png", "image/jpeg", "image/gif" }
function M.normalize_output_data(data)
  if type(data) ~= "table" then return end
  local clean = require("jupynvim.notebook.image").clean_b64
  for _, mime in ipairs(B64_IMAGE) do
    if data[mime] ~= nil then data[mime] = clean(data[mime]) end
  end
end

-- Every output that shows display_id takes the new data. The count tells the
-- caller whether any did.
local function replace_display(outputs, ev)
  local n = 0
  for _, o in ipairs(outputs) do
    if o.transient and o.transient.display_id == ev.display_id then
      o.data, o.metadata = ev.data, ev.metadata or {}
      -- the rev bumps the output memo, which keys on lengths and would miss
      -- a same-length update
      o._rev = (o._rev or 0) + 1
      n = n + 1
    end
  end
  return n
end

-- One kernel output event applied to an output list, which is returned (a new
-- list when clear_first or a clear starts one). Shared by a cell's outputs and
-- an Output widget's outputs, so both read the same way: a stream of the same
-- name joins the last output, clear_output without wait empties the list, and
-- update_display_data replaces the outputs it names.
function M.apply_output_event(outputs, ev)
  M.normalize_output_data(ev.data)
  -- the deferred half of clear_output(wait=True), decided by the backend
  if ev.clear_first then outputs = {} end
  local kind = ev.kind
  if kind == "stream" then
    local last = outputs[#outputs]
    if last and last.output_type == "stream" and last.name == ev.name then
      last.text = (last.text or "") .. ev.text
    else
      table.insert(outputs, { output_type = "stream", name = ev.name, text = ev.text })
    end
  elseif kind == "execute_result" then
    table.insert(outputs, {
      output_type = "execute_result",
      execution_count = ev.execution_count,
      data = ev.data,
      metadata = ev.metadata or {},
    })
  elseif kind == "display_data" then
    table.insert(outputs, {
      output_type = "display_data",
      data = ev.data,
      metadata = ev.metadata or {},
      -- display_id lives here in memory only, for update_display_data
      transient = (type(ev.transient) == "table" and ev.transient.display_id) and ev.transient or nil,
    })
  elseif kind == "error" then
    table.insert(outputs, {
      output_type = "error",
      ename = ev.ename, evalue = ev.evalue, traceback = ev.traceback,
    })
  elseif kind == "clear_output" then
    if not ev.wait then outputs = {} end
  elseif kind == "update_display_data" then
    replace_display(outputs, ev)
  end
  return outputs
end

local notebooks = {}   -- buf -> Notebook

local Notebook = {}
Notebook.__index = Notebook

function M.create(buf, path, session_id, snapshot)
  local Embedded = require("jupynvim.notebook.embedded")
  local nb = setmetatable({
    buf = buf,
    path = path,
    session_id = session_id,
    cells = {},
    cell_state = {},
    border_ns = vim.api.nvim_create_namespace("jupynvim.border:" .. buf),
    output_ns = vim.api.nvim_create_namespace("jupynvim.output:" .. buf),
    image_ns = vim.api.nvim_create_namespace("jupynvim.image:" .. buf),
    pending_image_ids = {},
    next_image_id = 1000 + buf,
  }, Notebook)
  notebooks[buf] = nb
  -- the widget models the backend holds for this session (dead until a kernel)
  Widgets.load(session_id, snapshot.widgets or {})
  for _, c in ipairs(snapshot.cells) do
    local source = c.source
    -- Markdown: replace huge data:image/...;base64,XXX URIs with short
    -- placeholders. Original is restored on save. Keeps buffer small → fast.
    if c.cell_type == "markdown" then
      source = Embedded.preprocess(c.id, source)
    end
    for _, o in ipairs(c.outputs or {}) do M.normalize_output_data(o.data) end
    table.insert(nb.cells, {
      id = c.id,
      cell_type = c.cell_type,
      source = source,
      execution_count = c.execution_count,
      outputs = c.outputs or {},
    })
    -- restore the execution bar's duration from saved timing metadata,
    -- so "[n] ✓ 0.3s" survives :wq + reopen like VSCode
    local dur = M.saved_duration_ns(c.metadata)
    if dur and c.cell_type == "code" and c.execution_count then
      local failed = false
      for _, o in ipairs(c.outputs or {}) do
        if o.output_type == "error" then failed = true end
      end
      nb.cell_state[c.id] = { exec_state = "idle", duration_ns = dur, failed = failed }
    end
  end
  if #nb.cells == 0 then
    table.insert(nb.cells, { id = "tmp_" .. tostring(buf), cell_type = "code", source = "", outputs = {} })
  end
  for _, c in ipairs(nb.cells) do M._owner[c] = buf end
  return nb
end

function M.get(buf)
  -- 0 means the current buffer (the :Jupynvim* commands pass 0); the table is
  -- keyed by real bufnr, so resolve 0 before the lookup.
  if buf == 0 then buf = vim.api.nvim_get_current_buf() end
  return notebooks[buf]
end

-- The notebook a cell table is in, or nil once the cell has left it.
function M.owner_of(cell)
  local buf = M._owner[cell]
  local nb = buf and notebooks[buf]
  if nb and nb:get_cell(cell.id) == cell then return nb end
  return nil
end

function M.remove(buf)
  local nb = notebooks[buf]
  -- the widget models go with the session (the backend closes it too)
  if nb then Widgets.drop(nb.session_id) end
  notebooks[buf] = nil
end

function M.all() return notebooks end

-- Convert cells -> buffer lines.
-- Returns the lines and a parallel list of {cell_id, start_line (0-based), end_line (0-based exclusive)}.
function Notebook:to_lines()
  local out = {}
  local ranges = {}
  for i, c in ipairs(self.cells) do
    M._owner[c] = self.buf
    local start = #out
    -- split source into lines (preserve empty cells as one empty line).
    -- Strip exactly ONE trailing newline first: nbformat sources commonly
    -- end with "\n" (it's the line terminator, not a blank line), and
    -- keeping it would add a phantom empty last line to the cell that
    -- shows a stray gutter number above the next cell (like VSCode, the
    -- terminating newline is not its own editable line).
    local src = c.source or ""
    if src:sub(-1) == "\n" then src = src:sub(1, -2) end
    if src == "" then
      table.insert(out, "")
    else
      for line in (src .. "\n"):gmatch("([^\n]*)\n") do
        table.insert(out, marker_ish(line) and (line .. " ") or line)
      end
    end
    local stop = #out
    table.insert(ranges, { id = c.id, start = start, stop = stop, type = c.cell_type })
    -- outputs ride along as real (sync-excluded) text under the source
    if c.cell_type == "code" and #(c.outputs or {}) > 0 then
      local out_lines = M.output_lines(c)
      if #out_lines > 0 then
        table.insert(out, M.OUT_SEP)
        for _, l in ipairs(out_lines) do table.insert(out, l) end
      end
    end
    if i < #self.cells then
      table.insert(out, M.CELL_SEP)
    end
  end
  return out, ranges
end

-- Re-derive cell sources from current buffer contents.
-- Updates self.cells[i].source in place. Cell count must match separator count + 1;
-- if it doesn't, we rebuild the cell list (assigning new ids from existing where positionally aligned).
function Notebook:sync_from_buffer(lines)
  lines = lines or vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
  local sources = { {} }
  local in_out = false
  for _, l in ipairs(lines) do
    if l == M.CELL_SEP then
      table.insert(sources, {})
      in_out = false
    elseif l == M.OUT_SEP then
      in_out = true  -- output region: not part of the source
    elseif not in_out then
      -- a source line that reads like a marker, escaped by to_lines
      if #l > #M.OUT_SEP and l:byte(-1) == 32 and marker_ish(l) then l = l:sub(1, -2) end
      table.insert(sources[#sources], l)
    end
  end
  -- Build cell sources
  local new_sources = {}
  for _, lns in ipairs(sources) do
    table.insert(new_sources, table.concat(lns, "\n"))
  end
  -- Match counts: if buffer has more/less cells than self.cells, reconcile.
  local n_buf = #new_sources
  local n_state = #self.cells
  if n_buf == n_state then
    for i = 1, n_buf do
      self.cells[i].source = new_sources[i]
    end
  elseif n_buf > n_state then
    -- New cells added; assign placeholder ids (real ids set by backend insert_cell calls)
    for i = 1, n_state do
      self.cells[i].source = new_sources[i]
    end
    for i = n_state + 1, n_buf do
      table.insert(self.cells, {
        id = "new_" .. tostring(vim.uv.hrtime()) .. "_" .. i,
        cell_type = "code",
        source = new_sources[i],
        outputs = {},
      })
    end
  else
    -- Cells removed
    for i = 1, n_buf do
      self.cells[i].source = new_sources[i]
    end
    for i = n_state, n_buf + 1, -1 do
      table.remove(self.cells, i)
    end
  end
end

-- The cell that owns 1-based line `lnum`: its source, its output region and
-- the separator below it, the same rule as CellMode.cell_idx_at. Output rows
-- used to count as "between cells" and resolve to the NEXT cell, so running,
-- clearing or saving from a cell's output acted on the cell after it.
-- The layout comes from the buffer, not from to_lines. After :undo N or g-
-- an output can still show as it was until the next edit puts it right.
-- Laid out from the cells, every line below it named another cell, and a
-- key acted on the wrong one.
-- Returns id, range, index.
function Notebook:cell_at_line(lnum)
  if vim.api.nvim_buf_is_valid(self.buf) then
    local i, r = require("jupynvim.notebook.cellmode").cell_idx_at(self.buf, lnum)
    if self.cells[i] then return self.cells[i].id, r, i end
  end
  local _, ranges = self:to_lines()
  for i = #ranges, 1, -1 do
    if lnum - 1 >= ranges[i].start then return ranges[i].id, ranges[i], i end
  end
  if ranges[1] then return ranges[1].id, ranges[1], 1 end
  return nil
end

function Notebook:get_cell(cell_id)
  for i, c in ipairs(self.cells) do
    if c.id == cell_id then return c, i end
  end
end

-- Execution states follow JupyterLab's cell model: idle -> queued
-- (JupyterLab: "scheduled") -> busy (JupyterLab: "running") -> idle. A run
-- marks its cells queued the moment they are submitted, so the cells still
-- waiting behind a long one read as waiting instead of keeping their old
-- "[n] ✓ 0.1s" badge. The badge's other fields (duration, failed) stay, so a
-- queued cell the kernel never runs (interrupt, restart) gets its old badge
-- back when it is unqueued.
--
-- A cell can be submitted again before an earlier run of it started or
-- ended (Run all twice, Shift-Enter on a running cell), so it counts its
-- runs that have not started (`pending`): one more per submission, one less
-- when the kernel takes one. A run opens with its status busy (every
-- request gets one, an aborted one too) or, should that be missed, its
-- execute_input, and closes with its idle (`run`: nil, "busy" once the busy
-- came, "input" once the execute_input came; a second execute_input or a
-- busy after it is the next run, its idle missed). A run that ends while
-- another is still waiting leaves the cell queued, not done. `epoch` is the
-- notebook's kernel epoch the cell was last submitted in (see retire).
function Notebook:mark_queued(cell_id)
  local st = self.cell_state[cell_id] or {}
  st.pending = (st.pending or 0) + 1
  st.epoch = self.epoch or 0
  if st.exec_state ~= "busy" then st.exec_state = "queued" end
  self.cell_state[cell_id] = st
end

-- A submission that never reached the kernel (refused, or the run stopped
-- before it). Returns true when the cell's badge changed.
function Notebook:unqueue(cell_id)
  local st = self.cell_state[cell_id]
  if not st or (st.pending or 0) == 0 then return false end
  st.pending = st.pending - 1
  if st.pending == 0 and st.exec_state == "queued" then st.exec_state = "idle"; return true end
  return false
end

-- The kernel took one of the cell's submissions: `how` is "busy" or "input".
local function take_run(st, how)
  if st.run == nil or st.run == "input" then
    local n = st.pending or 0
    st.pending = n > 0 and n - 1 or 0
  end
  st.run = how
end

-- The kernel is going away (stop, restart, a death) or its backend did:
-- release every queued cell and finish the running one as failed, stopwatch
-- stopped now, since nothing will send its idle any more. Returns true when
-- any cell changed.
function Notebook:release_pending()
  local any = false
  for _, c in ipairs(self.cells) do
    local st = self.cell_state[c.id]
    if st then
      if (st.pending or 0) > 0 then st.pending = 0 end
      st.run = nil
      if st.exec_state == "queued" then
        st.exec_state = "idle"
        any = true
      elseif st.exec_state == "busy" then
        if st.started_ns and not st.duration_ns then st.duration_ns = vim.uv.hrtime() - st.started_ns end
        st.exec_state, st.failed = "idle", true
        any = true
      end
    end
  end
  return any
end

-- A stop or a restart is asked for: the kernel's executions are released
-- now, and until the backend answers (`retired(epoch)`) the state events of
-- the cells submitted before it are not applied. They come from the kernel
-- being stopped, read by the backend before it got the request: a status
-- busy or execute_input of the next cell would take that cell back to busy
-- with a stopwatch nothing stops. The backend sends no such event once it
-- answered. Outputs still apply. Returns true when any cell changed.
function Notebook:retire()
  self.epoch = (self.epoch or 0) + 1
  self.retiring = self.epoch
  return self:release_pending()
end

function Notebook:retired(epoch)
  if self.retiring == epoch then self.retiring = nil end
end

-- The backends this notebook's runs went through: a backend that exits
-- releases the notebooks it ran. Normally one; two when a run was sent in
-- the moments between :JupynvimUseJob or a reconnect and the old backend's
-- exit, which then releases the notebook too rather than leave its old
-- runs waiting for good.
function Notebook:ran_through(client)
  self.exec_clients = self.exec_clients or {}
  self.exec_clients[client] = true
end

-- What a clear of the cell's outputs does to its badge: the last run's time
-- and failure go, a run still on stays (a running cell keeps its stopwatch,
-- a waiting one its queued mark).
function Notebook:clear_badge(cell_id)
  local st = self.cell_state[cell_id]
  if not st then return end
  if st.exec_state == "busy" or st.exec_state == "queued" or (st.pending or 0) > 0 then
    st.duration_ns, st.failed = nil, nil
    if st.exec_state ~= "busy" then st.started_ns = nil end
  else
    self.cell_state[cell_id] = nil
  end
end

-- Returns the ids of the cells whose outputs changed, when that is not just
-- `cell_id` (a display update can reach into any cell).
function Notebook:apply_cell_event(cell_id, ev)
  local kind = ev.kind
  if kind == "update_display_data" then
    -- h = display(x, display_id=True); h.update(y): replace every output
    -- showing that display, wherever it is.
    M.normalize_output_data(ev.data)
    local changed = {}
    for _, cell in ipairs(self.cells) do
      if replace_display(cell.outputs or {}, ev) > 0 then
        changed[#changed + 1] = cell.id
      end
    end
    return changed
  end
  local c = self:get_cell(cell_id)
  if not c then return end
  M._owner[c] = self.buf
  -- a state event of a kernel being stopped (see retire)
  local stale = false
  if self.retiring and (kind == "execute_input" or kind == "status") then
    local st = self.cell_state[cell_id]
    stale = ((st and st.epoch) or -1) < self.retiring
  end
  if kind == "execute_input" then
    c.execution_count = ev.execution_count
    c.outputs = {}
    -- A new run is a new output, cut again. Kept on, expanding one long
    -- print let the next run fill the buffer with whatever it printed. A
    -- hidden output stays hidden, as JupyterLab keeps it collapsed.
    c._output_expanded = nil
    -- start the execution stopwatch (drives the VSCode-style "[1] ✓ 0.1s"
    -- bar; live elapsed while busy, frozen duration once idle)
    if not stale then
      local st = self.cell_state[cell_id] or {}
      take_run(st, "input")
      st.exec_state, st.started_ns, st.duration_ns, st.failed = "busy", vim.uv.hrtime(), nil, nil
      self.cell_state[cell_id] = st
    end
  elseif kind == "stream" or kind == "execute_result" or kind == "display_data"
      or kind == "error" or kind == "clear_output" then
    c.outputs = M.apply_output_event(c.outputs, ev)
    if kind == "execute_result" then
      c.execution_count = ev.execution_count
    elseif kind == "error" then
      local st = self.cell_state[cell_id]
      if st then st.failed = true end
    end
  elseif kind == "status" and not stale then
    -- preserve the stopwatch fields; stamp the duration when leaving busy
    local st = self.cell_state[cell_id] or {}
    if st.exec_state == "busy" and ev.state ~= "busy" and st.started_ns and not st.duration_ns then
      st.duration_ns = vim.uv.hrtime() - st.started_ns
    end
    if ev.state == "busy" then
      take_run(st, "busy")
      st.exec_state = "busy"
    elseif ev.state == "idle" then
      -- the run is over; another one still waiting keeps the cell queued
      st.run = nil
      st.exec_state = (st.pending or 0) > 0 and "queued" or "idle"
    else
      st.exec_state = ev.state
    end
    self.cell_state[cell_id] = st
  elseif kind == "execute_reply" then
    -- A run whose cell was cleared while it ran ends with its count, as
    -- JupyterLab sets it from the reply (an aborted reply has none). The
    -- backend's model does the same.
    local ec = c.execution_count
    if (ec == nil or ec == vim.NIL) and type(ev.execution_count) == "number" and ev.execution_count > 0 then
      c.execution_count = ev.execution_count
    end
    -- Nothing else changes. In particular a queued cell is NOT released here:
    -- the reply rides the shell channel and can land after the iopub idle
    -- that already finished the cell, i.e. after the cell was queued again
    -- for its next run. Should a kernel abort a queued request (this
    -- backend sends stop_on_error=false, so ipykernel does not), the
    -- busy/idle statuses it publishes on iopub take that submission off
    -- the cell's count.
  end
end

return M

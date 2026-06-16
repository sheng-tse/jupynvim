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

local M = {}

-- Cell separator: a string very unlikely to appear in real source code.
-- (Plain `# %%` collides with jupytext-formatted notebooks.)
M.CELL_SEP = "# %%[jupynvim:cell-sep]"
-- Output-region marker: lines between OUT_SEP and the next CELL_SEP are
-- the cell's rendered output as REAL buffer text (navigable/yankable with
-- plain vim motions), excluded from the cell source on sync/save.
M.OUT_SEP = "# %%[jupynvim:out]"

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

function M.output_lines(cell)
  local lines = {}
  local function add_text(text)
    for _, l in ipairs(vim.split(text, "\n", { plain = true })) do
      if l:find("data:image/%w+;base64,") then
        table.insert(lines, "  [embedded image data]")
      else
        table.insert(lines, "  " .. l)
      end
    end
  end
  for _, o in ipairs(cell.outputs or {}) do
    if o.output_type == "stream" then
      add_text(_strip_ansi(_process_cr(_as_str(o.text))))
    elseif o.output_type == "execute_result" or o.output_type == "display_data" then
      local data = o.data or {}
      local has_img = data["image/png"] or data["image/gif"] or data["image/jpeg"]
      local text = _as_str(data["text/plain"])
      if has_img and (text == "" or text:match("^<[Ff]igure ")
          or text:match("^<[%w._]+ object>$")
          or text:match("^<[%w._]+ object at 0x[%x]+>$")) then
        text = ""
      end
      if text ~= "" then add_text(text) end
    elseif o.output_type == "error" then
      local msg = _as_str(o.ename) .. ": " .. _as_str(o.evalue)
      if msg ~= ": " then add_text(msg) end
      for _, tb in ipairs(o.traceback or {}) do
        add_text(_strip_ansi(_as_str(tb)))
      end
    end
  end
  while lines[#lines] == "  " or lines[#lines] == "" do table.remove(lines) end
  return lines
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

local notebooks = {}   -- buf -> Notebook

local Notebook = {}
Notebook.__index = Notebook

function M.create(buf, path, session_id, snapshot)
  local Embedded = require("jupynvim.embedded")
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
  for _, c in ipairs(snapshot.cells) do
    local source = c.source
    -- Markdown: replace huge data:image/...;base64,XXX URIs with short
    -- placeholders. Original is restored on save. Keeps buffer small → fast.
    if c.cell_type == "markdown" then
      source = Embedded.preprocess(c.id, source)
    end
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
  return nb
end

function M.get(buf)
  -- 0 means the current buffer (the :Jupynvim* commands pass 0); the table is
  -- keyed by real bufnr, so resolve 0 before the lookup.
  if buf == 0 then buf = vim.api.nvim_get_current_buf() end
  return notebooks[buf]
end

function M.remove(buf)
  notebooks[buf] = nil
end

function M.all() return notebooks end

-- Convert cells -> buffer lines.
-- Returns the lines and a parallel list of {cell_id, start_line (0-based), end_line (0-based exclusive)}.
function Notebook:to_lines()
  local out = {}
  local ranges = {}
  for i, c in ipairs(self.cells) do
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
        table.insert(out, line)
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
function Notebook:sync_from_buffer()
  local lines = vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
  local sources = { {} }
  local in_out = false
  for _, l in ipairs(lines) do
    if l == M.CELL_SEP then
      table.insert(sources, {})
      in_out = false
    elseif l == M.OUT_SEP then
      in_out = true  -- output region: not part of the source
    elseif not in_out then
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
        id = "new_" .. tostring(vim.loop.hrtime()) .. "_" .. i,
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

-- Find cell id at the given 1-based line number in the current buffer.
function Notebook:cell_at_line(lnum)
  local _, ranges = self:to_lines()
  for _, r in ipairs(ranges) do
    if (lnum - 1) >= r.start and (lnum - 1) < r.stop then
      return r.id, r
    end
  end
  -- between cells (on a separator line) → return next cell
  for i, r in ipairs(ranges) do
    if (lnum - 1) < r.start then return r.id, r, i end
  end
  if #ranges > 0 then return ranges[#ranges].id, ranges[#ranges] end
  return nil
end

function Notebook:get_cell(cell_id)
  for i, c in ipairs(self.cells) do
    if c.id == cell_id then return c, i end
  end
end

function Notebook:apply_cell_event(cell_id, ev)
  local c = self:get_cell(cell_id)
  if not c then return end
  local kind = ev.kind
  if kind == "execute_input" then
    c.execution_count = ev.execution_count
    c.outputs = {}
    -- start the execution stopwatch (drives the VSCode-style "[1] ✓ 0.1s"
    -- bar; live elapsed while busy, frozen duration once idle)
    self.cell_state[cell_id] = { exec_state = "busy", started_ns = vim.uv.hrtime() }
  elseif kind == "stream" then
    -- coalesce
    local last = c.outputs[#c.outputs]
    if last and last.output_type == "stream" and last.name == ev.name then
      last.text = (last.text or "") .. ev.text
    else
      table.insert(c.outputs, { output_type = "stream", name = ev.name, text = ev.text })
    end
  elseif kind == "execute_result" then
    table.insert(c.outputs, {
      output_type = "execute_result",
      execution_count = ev.execution_count,
      data = ev.data,
      metadata = ev.metadata or {},
    })
    c.execution_count = ev.execution_count
  elseif kind == "display_data" then
    table.insert(c.outputs, {
      output_type = "display_data",
      data = ev.data,
      metadata = ev.metadata or {},
    })
  elseif kind == "error" then
    table.insert(c.outputs, {
      output_type = "error",
      ename = ev.ename, evalue = ev.evalue, traceback = ev.traceback,
    })
    local st = self.cell_state[cell_id]
    if st then st.failed = true end
  elseif kind == "status" then
    -- preserve the stopwatch fields; stamp the duration when leaving busy
    local st = self.cell_state[cell_id] or {}
    if st.exec_state == "busy" and ev.state ~= "busy" and st.started_ns and not st.duration_ns then
      st.duration_ns = vim.uv.hrtime() - st.started_ns
    end
    st.exec_state = ev.state
    self.cell_state[cell_id] = st
  elseif kind == "execute_reply" then
    -- nothing to mutate
  elseif kind == "clear_output" then
    if not ev.wait then c.outputs = {} end
  end
end

return M

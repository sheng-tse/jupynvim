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
  end
  if #nb.cells == 0 then
    table.insert(nb.cells, { id = "tmp_" .. tostring(buf), cell_type = "code", source = "", outputs = {} })
  end
  return nb
end

function M.get(buf) return notebooks[buf] end

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
    -- split source into lines (preserve empty cells as one empty line)
    local src = c.source or ""
    if src == "" then
      table.insert(out, "")
    else
      for line in (src .. "\n"):gmatch("([^\n]*)\n") do
        table.insert(out, line)
      end
      -- if source didn't end with \n, the last empty token is dropped already
    end
    local stop = #out
    table.insert(ranges, { id = c.id, start = start, stop = stop, type = c.cell_type })
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
  for _, l in ipairs(lines) do
    if l == M.CELL_SEP then
      table.insert(sources, {})
    else
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

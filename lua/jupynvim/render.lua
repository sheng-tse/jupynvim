-- Render a Notebook into its buffer using extmarks, VSCode-notebook style.
--
-- Visual layout per CODE cell:
--   ╭─ Python ────────────────── #3 ─╮     input editor box (rounded)
--   │ <cell source line 1>           │     (statuscolumn numbers each cell
--   │ <cell source line 2>           │      from 1, like a private gutter)
--   ╰────────────────────────────────╯
--     [1] ✓ 0.1s                           execution bar (live while busy)
--     <output lines, frameless,            outputs are a linked chunk under
--      clamped at output_max_lines>         the editor, not boxed
--
-- MARKDOWN cells render frameless: just the styled text/images flowing like
-- a document (VSCode never frames rendered markdown).
--
-- Implementation:
--   • One extmark per cell on its first line: virt_lines_above = header
--   • One extmark on the last line: footer box edge + exec bar + outputs
--   • Side bars via virt_text marks per source line (code cells only)
--   • Output images via Kitty graphics protocol (image.lua)

local Notebook = require("jupynvim.notebook")
local image = require("jupynvim.image")
local log = require("jupynvim.log")

local M = {}

-- Highlight groups (defined in setup_highlights)
local HL_BORDER     = "JupynvimBorder"
local HL_BORDER_SEL = "JupynvimBorderSel"
local HL_HEADER     = "JupynvimCellHeader"
local HL_BUSY       = "JupynvimBusy"
local HL_OUTPUT     = "JupynvimOutput"
local HL_ERROR      = "JupynvimError"
local HL_STREAM     = "JupynvimStream"
local HL_RESULT     = "JupynvimResult"
local HL_OK         = "JupynvimExecOk"
local HL_MORE       = "JupynvimOutputMore"

local function repeat_char(ch, n)
  if n <= 0 then return "" end
  return string.rep(ch, n)
end

local function dw(s) return vim.fn.strdisplaywidth(s) end

-- Input-box edges. The box's LEFT side lives in the statuscolumn (drawn by
-- cellmode.statuscol); header/footer are full-window virt lines
-- (virt_lines_leftcol) prefixed so the corners line up with that gutter
-- border column. The selected cell gets HEAVY box glyphs.
local function box_chars(sel)
  if sel then
    return { tl = "┏", tr = "┓", bl = "┗", br = "┛", h = "━", v = "┃" }
  end
  return { tl = "╭", tr = "╮", bl = "╰", br = "╯", h = "─", v = "│" }
end

local function header_line(total_w, gut, label, cellno, busy, bc)
  local prefix = repeat_char(" ", math.max(gut - 2, 0))
  local main = prefix .. bc.tl .. bc.h .. " " .. label .. (busy and " (running) " or " ")
  local tail = bc.h .. " #" .. cellno .. " " .. bc.h .. bc.tr
  local pad = total_w - dw(main) - dw(tail)
  return main .. repeat_char(bc.h, math.max(pad, 0)) .. tail
end

local function footer_line(total_w, gut, bc)
  local prefix = repeat_char(" ", math.max(gut - 2, 0))
  return prefix .. bc.bl .. repeat_char(bc.h, math.max(total_w - dw(prefix) - 2, 0)) .. bc.br
end

-- Wrap a single line to `width` DISPLAY COLUMNS, breaking at space
-- boundaries when possible so words don't split mid-character. Falls back
-- to a hard char break for runs longer than `width` with no whitespace.
-- Uses display widths (not byte lengths) so multi-byte UTF-8 stays intact.
local function wrap(line, width)
  if width <= 0 then return { line } end
  if vim.fn.strdisplaywidth(line) <= width then return { line } end
  local out = {}
  local n = vim.fn.strchars(line)
  local pos = 0
  while pos < n do
    local start = pos
    local cur_w = 0
    local last_space = -1
    while pos < n do
      local ch = vim.fn.strcharpart(line, pos, 1)
      local cw = vim.fn.strdisplaywidth(ch)
      if cur_w + cw > width then break end
      if ch == " " then last_space = pos end
      cur_w = cur_w + cw
      pos = pos + 1
    end
    if pos < n and last_space > start then
      table.insert(out, vim.fn.strcharpart(line, start, last_space - start))
      pos = last_space + 1
    else
      if pos == start then pos = pos + 1 end
      table.insert(out, vim.fn.strcharpart(line, start, pos - start))
    end
  end
  return out
end

-- nbformat stores text fields as either a single string or an array of
-- strings (lines). Normalize to one string.
local function as_str(v)
  if type(v) == "table" then return table.concat(v, "") end
  if type(v) == "string" then return v end
  return ""
end

-- Strip ANSI escape sequences (SGR colors, cursor moves, etc.).
local function strip_ansi(s)
  s = s:gsub("\27%[[?]?[%d;]*[a-zA-Z]", "")
  s = s:gsub("\27%][^\27]*\27\\", "")
  s = s:gsub("\27.", "")
  return s
end

-- Expand tabs to spaces so wrap computes the same width that virt_text
-- actually renders (virt_text doesn't honour tabstop).
local function expand_tabs(s, tabstop)
  tabstop = tabstop or 8
  local out, col = {}, 0
  local i = 1
  while i <= #s do
    local c = s:sub(i, i)
    if c == "\t" then
      local pad = tabstop - (col % tabstop)
      table.insert(out, string.rep(" ", pad))
      col = col + pad
    elseif c == "\n" then
      table.insert(out, c)
      col = 0
    else
      table.insert(out, c)
      col = col + 1
    end
    i = i + 1
  end
  return table.concat(out)
end

-- Apply tqdm/progress-bar carriage-return semantics: \r OVERWRITES the
-- current line. Each \r-terminated chunk is replaced; only the LAST chunk
-- per logical line is kept. Then split by real newlines.
--
-- Normalize CRLF → LF first: shell output (e.g. IPython's `!cmd`) sends
-- `\r\n` as a regular line ending. Without the normalize the bare-\r path
-- below treats the \r as a tqdm overwrite, takes the empty segment after
-- it, and the entire output renders as blank.
local function process_cr(s)
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

-- Compact a tqdm progress bar: shorten the long block-char run while
-- preserving the actual progress fraction.
local PARTIAL_BLOCKS = { "▏", "▎", "▍", "▌", "▋", "▊", "▉" }

local function compact_tqdm(line)
  local prefix, bar, rest = line:match("^(%s*%d+%%)|(.-)|(.*)$")
  if not prefix or not bar then return line end
  if not bar:match("[█▏▎▍▌▋▊▉ ]") then return line end

  local total = 15
  local frac
  local n, m = rest:match("(%d+)/(%d+)")
  if n and m then
    local nm = tonumber(m)
    if nm and nm > 0 then
      frac = tonumber(n) / nm
    end
  end
  if not frac then
    frac = (tonumber(prefix:match("(%d+)")) or 0) / 100
  end
  if frac < 0 then frac = 0 end
  if frac > 1 then frac = 1 end

  local exact = frac * total
  local full = math.floor(exact)
  local rem = exact - full
  local idx = math.floor(rem * 8 + 0.5)
  local short
  if idx >= 8 then
    full = math.min(full + 1, total)
    short = string.rep("█", full) .. string.rep(" ", total - full)
  elseif idx > 0 and full < total then
    short = string.rep("█", full) .. PARTIAL_BLOCKS[idx]
      .. string.rep(" ", total - full - 1)
  else
    short = string.rep("█", full) .. string.rep(" ", total - full)
  end
  return prefix .. "|" .. short .. "|" .. rest
end

-- Indent every output row slightly so outputs read as the linked chunk
-- under the input editor (VSCode's output gutter).
local OUT_INDENT = "  "

-- Build the (frameless) virt_lines for a cell's outputs, clamped to
-- config.output_max_lines like VSCode's max output height. Images bypass
-- the clamp (their row count is fixed and bounded). `lead` prefixes every
-- row (gutter blanks: these rows render with virt_lines_leftcol).
local function build_output_virt_lines(cell, width, nb, lead)
  lead = (lead or "") .. OUT_INDENT
  local rows = {}
  local clamp = (require("jupynvim").config or {}).output_max_lines or 30
  local truncated = 0
  local function push(text, hl)
    if #rows < clamp then
      table.insert(rows, { { lead .. text, hl } })
    else
      truncated = truncated + 1
    end
  end
  local inner_w = width - dw(OUT_INDENT)

  for _, o in ipairs(cell.outputs or {}) do
    if o.output_type == "stream" then
      -- stderr renders subdued gray (tqdm/wandb noise), stdout green-ish
      local hl = (o.name == "stderr") and HL_OUTPUT or HL_STREAM
      local text = expand_tabs(strip_ansi(process_cr(as_str(o.text))))
      for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
        line = compact_tqdm(line)
        if line:find("data:image/%w+;base64,") then
          -- a printed data-URI is thousands of useless characters; the
          -- image itself renders separately
          push("[embedded image data]", HL_MORE)
        else
          for _, w in ipairs(wrap(line, inner_w)) do
            push(w, hl)
          end
        end
      end
    elseif o.output_type == "execute_result" or o.output_type == "display_data" then
      local data = o.data or {}
      local has_img = (data["image/png"] ~= nil) or (data["image/gif"] ~= nil) or (data["image/jpeg"] ~= nil)
      local text = as_str(data["text/plain"])
      -- Hide the boring repr when the actual image is rendered alongside.
      if has_img and (text == ""
          or text:match("^<[Ff]igure ")
          or text:match("^<[%w._]+ object>$")
          or text:match("^<[%w._]+ object at 0x[%x]+>$")) then
        text = ""
      end
      -- If text/plain is just the boring object repr, try extracting visible
      -- text from text/html (used by wandb, tqdm widgets, etc.)
      if text == "" or text:match("^<[A-Za-z._]+ object>$") then
        local html = as_str(data["text/html"])
        if html ~= "" then
          local plain = html
            :gsub("<a[^>]*href=\"([^\"]*)\"[^>]*>(.-)</a>", "%2 (%1)")
            :gsub("<br%s*/?>", "\n")
            :gsub("</p>", "\n")
            :gsub("<[^>]+>", "")
            :gsub("&nbsp;", " ")
            :gsub("&amp;", "&")
            :gsub("&lt;", "<")
            :gsub("&gt;", ">")
            :gsub("&#x?%w+;", "")
            :gsub("\n\n+", "\n")
          text = plain:gsub("^%s+", ""):gsub("%s+$", "")
        end
      end
      if text ~= "" then
        text = expand_tabs(text)
        for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
          if line:find("data:image/%w+;base64,") then
            push("[embedded image data]", HL_MORE)
          else
            for _, w in ipairs(wrap(line, inner_w)) do
              push(w, HL_RESULT)
            end
          end
        end
      end
      local b64
      for _, m in ipairs({ "image/gif", "image/png", "image/jpeg" }) do
        local v = data[m]
        if type(v) == "table" then v = table.concat(v, "") end
        if type(v) == "string" and v ~= "" then b64 = v; break end
      end
      if b64 then
        local ph = image.placeholder_virt_lines(cell.id)
        if ph then
          for _, line in ipairs(ph) do
            table.insert(rows, { { lead, "Normal" }, { line[1][1], line[1][2] } })
          end
        else
          local ascii = image.ascii_lines_for(cell.id)
          if ascii then
            for _, line in ipairs(ascii) do
              table.insert(rows, { { lead .. line, "Normal" } })
            end
          elseif image.supported() then
            for _ = 1, 14 do
              table.insert(rows, { { lead, HL_OUTPUT } })
            end
          end
        end
      end
    elseif o.output_type == "error" then
      local msg = as_str(o.ename) .. ": " .. as_str(o.evalue)
      if msg == ": " then msg = "Error" end
      for _, w in ipairs(wrap(msg, inner_w)) do
        push(w, HL_ERROR)
      end
      for _, tb in ipairs(o.traceback or {}) do
        local plain = expand_tabs(as_str(tb):gsub("\27%[[%d;]*m", ""))
        for _, line in ipairs(vim.split(plain, "\n", { plain = true })) do
          for _, w in ipairs(wrap(line, inner_w)) do
            push(w, HL_ERROR)
          end
        end
      end
    end
  end
  if truncated > 0 then
    table.insert(rows, { {
      lead .. "⋯ " .. truncated .. " more lines · <C-j> to read",
      HL_MORE,
    } })
  end
  return rows
end
M._build_output_virt_lines = build_output_virt_lines

-- VSCode's execution bar: "[1] ✓ 0.1s" under the input box. Live elapsed
-- time with a spinner glyph while running; ✗ on error.
local function fmt_duration(ns)
  local s = ns / 1e9
  if s < 10 then return string.format("%.1fs", s) end
  if s < 60 then return string.format("%.0fs", s) end
  return string.format("%dm %ds", math.floor(s / 60), math.floor(s % 60))
end
M._fmt_duration = fmt_duration

local function exec_status_chunks(cell, st)
  local ec = cell.execution_count
  if ec == vim.NIL then ec = nil end
  st = st or {}
  if st.exec_state == "busy" then
    local el = st.started_ns and (vim.uv.hrtime() - st.started_ns) or 0
    return { { " [*] ", HL_BUSY }, { "● " .. fmt_duration(el), HL_BUSY } }
  end
  local badge = " [" .. (ec or " ") .. "] "
  if st.failed then
    return { { badge, HL_HEADER },
             { "✗" .. (st.duration_ns and (" " .. fmt_duration(st.duration_ns)) or ""), HL_ERROR } }
  end
  if st.duration_ns then
    return { { badge, HL_HEADER }, { "✓ " .. fmt_duration(st.duration_ns), HL_OK } }
  end
  if ec then
    return { { badge, HL_HEADER }, { "✓", HL_OK } }
  end
  return { { " [ ]", HL_HEADER } }
end
M._exec_status_chunks = exec_status_chunks

-- Render a single cell. `geom` = { gut, width, total_w }: statuscolumn
-- width, text-area width, full window width. `editing` = this cell is the
-- one being edited (markdown cells get a source-editor box while edited,
-- like VSCode's markdown edit view).
local function render_cell(nb, cell, range, geom, win, cellno, selected, editing)
  local buf = nb.buf
  local st = nb.cell_state[cell.id]
  local busy = st and st.exec_state == "busy"
  local total = vim.api.nvim_buf_line_count(buf)
  if range.start >= total then return end

  local gut, width, total_w = geom.gut, geom.width, geom.total_w
  local lead = repeat_char(" ", gut)
  local boxed = cell.cell_type == "code" or editing

  -- ── markdown / raw, not being edited: frameless document flow ──
  if not boxed then
    local lines_below = {}
    if cell.cell_type == "markdown" then
      local Embedded = require("jupynvim.embedded")
      local src = cell.source or ""
      for _, img in ipairs(Embedded.list_images(cell.id) or {}) do
        if src:find("jupynvim%-img:" .. img.idx, 1, false) then
          local key = cell.id .. "_md_" .. img.idx
          local ph = image.placeholder_virt_lines(key)
          if ph then
            for _, line in ipairs(ph) do
              table.insert(lines_below, { { lead, "Normal" }, { line[1][1], line[1][2] } })
            end
          else
            local ascii = image.ascii_lines_for(key)
            if ascii then
              for _, line in ipairs(ascii) do
                table.insert(lines_below, { { lead .. line, "Normal" } })
              end
            end
          end
        end
      end
    end
    -- breathing room between a markdown cell and whatever follows
    table.insert(lines_below, { { " ", "Normal" } })
    local last = math.max(range.stop - 1, range.start)
    if last >= total then last = total - 1 end
    if last >= 0 then
      vim.api.nvim_buf_set_extmark(buf, nb.border_ns, last, 0, {
        virt_lines = lines_below,
        virt_lines_leftcol = true,
      })
    end
    if cell.cell_type == "markdown" then
      require("jupynvim.markdown").render(buf, nb.border_ns,
        range.start, math.min(range.stop - 1, total - 1), width)
      local Embedded = require("jupynvim.embedded")
      local imgs = Embedded.list_images(cell.id)
      if imgs and #imgs > 0 then
        nb.image_ids = nb.image_ids or {}
        for _, img in ipairs(imgs) do
          local key = cell.id .. "_md_" .. img.idx
          local renderer = (require("jupynvim").config.image_renderer) or "chafa"
          if not nb.image_ids[key] then
            image.ensure_transmitted(key, img.b64, function(id)
              if id then
                nb.image_ids[key] = id
                vim.schedule(function() M.refresh(nb, win) end)
              end
            end, { renderer = renderer, mime = img.mime })
          end
        end
      end
    end
    return
  end

  -- ── boxed editor: code cells always; markdown while being edited ──
  local bc = box_chars(selected)
  local border_hl = selected and HL_BORDER_SEL or HL_BORDER
  local label = cell.cell_type == "code" and "Python" or "Markdown"
  local hdr = header_line(total_w, gut, label, cellno, busy, bc)
  vim.api.nvim_buf_set_extmark(buf, nb.border_ns, range.start, 0, {
    virt_lines = { { { hdr, busy and HL_BUSY or border_hl } } },
    virt_lines_above = true,
    virt_lines_leftcol = true,
  })

  local lines_below = {}
  table.insert(lines_below, { { footer_line(total_w, gut, bc), border_hl } })
  if cell.cell_type == "code" then
    local ex = { { lead, "Normal" } }
    vim.list_extend(ex, exec_status_chunks(cell, st))
    table.insert(lines_below, ex)
    if #(cell.outputs or {}) > 0 then
      for _, l in ipairs(build_output_virt_lines(cell, width, nb, lead)) do
        table.insert(lines_below, l)
      end
    end
  end
  -- spacer so the next cell's top border doesn't glue to our outputs
  table.insert(lines_below, { { " ", "Normal" } })

  local last = math.max(range.stop - 1, range.start)
  if last >= total then last = total - 1 end
  if last < 0 then return end
  vim.api.nvim_buf_set_extmark(buf, nb.border_ns, last, 0, {
    virt_lines = lines_below,
    virt_lines_leftcol = true,
  })

  -- RIGHT border on each source line; the LEFT border is part of the
  -- statuscolumn (so the insert cursor aligns even on empty lines).
  -- Repeats on wrapped rows via virt_text_repeat_linebreak. Each source
  -- line also gets the darker editor background, like VSCode's cells.
  for ln = range.start, math.min(range.stop - 1, total - 1) do
    pcall(vim.api.nvim_buf_set_extmark, buf, nb.border_ns, ln, 0, {
      virt_text = { { bc.v, border_hl } },
      virt_text_pos = "right_align",
      virt_text_repeat_linebreak = true,
      hl_mode = "combine",
      priority = 100,
    })
    pcall(vim.api.nvim_buf_set_extmark, buf, nb.border_ns, ln, 0, {
      line_hl_group = "JupynvimCellBg",
      priority = 1,
    })
  end

  -- Schedule image placements for image outputs
  if cell.cell_type == "code" and image.supported() then
    M.place_images(nb, cell, range, win, gut)
  end
end

-- For each image in a cell's outputs, register the image_id and place it
-- directly at the correct screen row using Kitty's a=T (transmit-and-place).
function M.place_images(nb, cell, range, win, gut)
  nb.image_ids = nb.image_ids or {}
  local b64, mime
  for _, o in ipairs(cell.outputs or {}) do
    if (o.output_type == "execute_result" or o.output_type == "display_data") then
      local d = o.data or {}
      for _, m in ipairs({ "image/gif", "image/png", "image/jpeg" }) do
        local v = d[m]
        if type(v) == "table" then v = table.concat(v, "") end
        if type(v) == "string" and v ~= "" then b64 = v; mime = m; break end
      end
      if b64 then break end
    end
  end
  if not b64 then
    image.clear_for_cell(cell.id)
    nb.image_ids[cell.id] = nil
    return
  end
  local renderer = (require("jupynvim").config.image_renderer) or "chafa"
  local was_cached = (image._placements and image._placements[cell.id]
    and image._placements[cell.id].renderer == renderer)
  image.ensure_transmitted(cell.id, b64, function(id)
    if not id then return end
    nb.image_ids[cell.id] = id
    if renderer == "kitty" then
      vim.schedule(function()
        if not win or not vim.api.nvim_win_is_valid(win) then
          win = vim.fn.bufwinid(nb.buf)
        end
        if not win or win == -1 then return end
        local anchor_lnum = math.min(range.stop, vim.api.nvim_buf_line_count(nb.buf))
        local pos = vim.fn.screenpos(win, anchor_lnum, 1)
        if pos and pos.row and pos.row > 0 then
          local img_row = pos.row + 2
          local img_col = (gut or 7) + 3
          local cfg = require("jupynvim").config or {}
          image.place_at_screen_row(cell.id, img_row, img_col,
            cfg.image_rows or 10, cfg.image_cols or 44)
        end
      end)
    end
    if not was_cached then
      vim.schedule(function() M.refresh(nb, win) end)
    end
  end, { renderer = renderer, mime = mime })
end

local function clear_separators(nb, ranges)
  local buf = nb.buf
  local total = vim.api.nvim_buf_line_count(buf)
  for i = 1, #ranges - 1 do
    local sep_line = ranges[i].stop
    if sep_line < total then
      local line_text = vim.api.nvim_buf_get_lines(buf, sep_line, sep_line + 1, false)[1] or ""
      vim.api.nvim_buf_set_extmark(buf, nb.border_ns, sep_line, 0, {
        end_col = #line_text,
        conceal = "",
        priority = 200,
      })
    end
  end
end

-- While any cell is busy, refresh ~2×/s so the execution bar's elapsed
-- time ticks like VSCode's.
local function manage_busy_ticker(nb)
  local any_busy = false
  for _, c in ipairs(nb.cells) do
    local st = nb.cell_state[c.id]
    if st and st.exec_state == "busy" then any_busy = true; break end
  end
  if any_busy and not nb._tick_timer then
    nb._tick_timer = vim.uv.new_timer()
    nb._tick_timer:start(500, 500, vim.schedule_wrap(function()
      if not vim.api.nvim_buf_is_valid(nb.buf) then
        if nb._tick_timer then nb._tick_timer:stop(); nb._tick_timer:close(); nb._tick_timer = nil end
        return
      end
      M.refresh(nb, vim.fn.bufwinid(nb.buf))
    end))
  elseif not any_busy and nb._tick_timer then
    nb._tick_timer:stop()
    nb._tick_timer:close()
    nb._tick_timer = nil
  end
end

-- Refresh is debounced and serialized to avoid concurrent renders racing
-- (which produces stacked phantom extmarks).
local _refresh_pending = {}  -- buf -> true
function M.refresh(nb, win)
  local buf = nb.buf
  if not vim.api.nvim_buf_is_valid(buf) then return end
  if _refresh_pending[buf] then return end
  _refresh_pending[buf] = true
  vim.schedule(function()
    _refresh_pending[buf] = nil
    if not vim.api.nvim_buf_is_valid(buf) then return end

    vim.api.nvim_buf_clear_namespace(buf, nb.border_ns, 0, -1)

    -- Compute cell ranges DIRECTLY from buffer text — so newly typed lines
    -- are picked up immediately without waiting for sync_from_buffer.
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local ranges = {}
    local cur_start = 0
    local cell_idx = 1
    for i, line in ipairs(lines) do
      if line == Notebook.CELL_SEP then
        table.insert(ranges, { start = cur_start, stop = i - 1, idx = cell_idx })
        cell_idx = cell_idx + 1
        cur_start = i
      end
    end
    table.insert(ranges, { start = cur_start, stop = #lines, idx = cell_idx })

    if not win or not vim.api.nvim_win_is_valid(win) then
      local wins = vim.fn.win_findbuf(buf)
      win = (wins and wins[1]) or vim.api.nvim_get_current_win()
    end
    -- Geometry straight from the window: textoff = the statuscolumn gutter
    -- (which carries the cells' left borders), width = text area.
    local CellMode = require("jupynvim.cellmode")
    local geom = { gut = CellMode.GUTTER, width = 80, total_w = 87 }
    if win and vim.api.nvim_win_is_valid(win) then
      local info = vim.fn.getwininfo(win)[1]
      if info then
        geom.gut = info.textoff or CellMode.GUTTER
        geom.total_w = info.width
        geom.width = math.max(info.width - geom.gut, 30)
      end
    end

    local sel_idx = CellMode.selected_idx(buf)
    local edit_idx = (not CellMode.is_command(buf)) and sel_idx or nil

    for i, r in ipairs(ranges) do
      local cell = nb.cells[i]
      if cell then
        local ok, err = pcall(render_cell, nb, cell, r, geom, win, i,
          i == sel_idx, i == edit_idx)
        if not ok then
          require("jupynvim.log").warn("render_cell failed for cell " .. tostring(i) .. ": " .. tostring(err))
        end
      end
    end
    clear_separators(nb, ranges)
    manage_busy_ticker(nb)
  end)
end

function M.setup_highlights()
  local hl = vim.api.nvim_set_hl
  -- Visible borders; the selected cell's border goes bright + heavy glyphs.
  hl(0, HL_BORDER,     { fg = "#7aa2f7" })
  hl(0, HL_BORDER_SEL, { fg = "#7dcfff", bold = true })
  hl(0, HL_HEADER,     { fg = "#565f89" })
  hl(0, HL_BUSY,       { fg = "#e0af68", bold = true })
  hl(0, HL_OUTPUT,     { fg = "#a9b1d6" })
  hl(0, HL_ERROR,      { fg = "#f7768e", bold = true })
  hl(0, HL_STREAM,     { fg = "#c0caf5" })
  hl(0, HL_RESULT,     { fg = "#bb9af7" })
  hl(0, HL_OK,         { fg = "#9ece6a" })
  hl(0, HL_MORE,       { fg = "#565f89", italic = true })
  hl(0, "JupynvimCellBg", { bg = "#16161e" })
  hl(0, "JupynvimSeparator", { fg = "#414868" })
  pcall(vim.fn.sign_define, "JupynvimBar", { text = "│", texthl = HL_BORDER })
  require("jupynvim.markdown").setup_hl()
  require("jupynvim.cellmode").setup_hl()
end

return M

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
local image = require("jupynvim.notebook.image")
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
local HL_SEPARATOR  = "JupynvimSeparator"

local function repeat_char(ch, n)
  if n <= 0 then return "" end
  return string.rep(ch, n)
end

-- Display width for frame/layout math. Use strwidth, NOT strdisplaywidth:
-- strdisplaywidth expands tabs and, in practice, returned an inflated and
-- UNSTABLE width for box-drawing strings (e.g. 86-88 for an 80-cell line,
-- varying by call), which made the header/footer fill overshoot the window
-- and the frame wrap into a broken border. strwidth is the true cell width
-- (tabs are pre-expanded via expand_tabs before any wrapping).
local function dw(s) return vim.fn.strwidth(s) end

-- Input-box edges. The box's LEFT side lives in the statuscolumn (drawn by
-- cellmode.statuscol); header/footer are full-window virt lines
-- (virt_lines_leftcol) prefixed so the corners line up with that gutter
-- border column. Selection is shown by the far-left gutter bar, NOT the
-- frame: every box stays the same calm thin style.
local function box_chars(_)
  return { tl = "╭", tr = "╮", bl = "╰", br = "╯", h = "─", v = "│" }
end

-- VSCode layout: the top edge carries only the cell number badge; the
-- language label sits at the BOTTOM-RIGHT of the cell (see VSCode's
-- notebook editor), right above the "[n] ✓ 0.1s" execution bar.
local function header_line(total_w, gut, cellno, busy, bc)
  local prefix = repeat_char(" ", math.max(gut - 2, 0))
  local main = prefix .. bc.tl .. (busy and (bc.h .. " (running) ") or "")
  local tail = bc.h .. " #" .. cellno .. " " .. bc.h .. bc.tr
  local pad = total_w - dw(main) - dw(tail)
  return main .. repeat_char(bc.h, math.max(pad, 0)) .. tail
end

local function footer_line(total_w, gut, bc, label)
  local prefix = repeat_char(" ", math.max(gut - 2, 0))
  local main = prefix .. bc.bl
  local tail = label and (bc.h .. " " .. label .. " " .. bc.h .. bc.br) or bc.br
  local pad = total_w - dw(main) - dw(tail)
  return main .. repeat_char(bc.h, math.max(pad, 0)) .. tail
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

-- Output IMAGES as virt rows. Text outputs are REAL buffer lines now (the
-- OUT_SEP region emitted by Notebook:to_lines), so only kitty/ascii image
-- rows remain virtual. `lead` prefixes every row (these rows render with
-- virt_lines_leftcol).
local function build_image_virt_lines(cell, width, nb, lead)
  lead = (lead or "") .. OUT_INDENT
  local rows = {}
  local b64
  for _, o in ipairs(cell.outputs or {}) do
    if o.output_type == "execute_result" or o.output_type == "display_data" then
      local data = o.data or {}
      for _, m in ipairs({ "image/gif", "image/png", "image/jpeg" }) do
        local v = data[m]
        if type(v) == "table" then v = table.concat(v, "") end
        if type(v) == "string" and v ~= "" then b64 = v; break end
      end
      if b64 then break end
    end
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
        local rrows = (require("jupynvim").config or {}).image_rows or 16
        for _ = 1, rrows do
          table.insert(rows, { { lead, HL_OUTPUT } })
        end
      end
    end
  end
  return rows
end
M._build_image_virt_lines = build_image_virt_lines

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

-- Bottom border WITH the execution status embedded inline on the left, so the
-- "[n] ✓ 0.1s" badge rides in the frame instead of floating on its own line
-- below the box. Returns a virt_line chunk array (the exec badge keeps its own
-- highlights; the dashes/corners use HL_BORDER). Layout:
--   ╰─ [n] ✓ 0.1s ───────────────────────────────────── Python ─╯
local function footer_chunks(total_w, gut, bc, label, cell, st, border_hl)
  border_hl = border_hl or HL_BORDER   -- busy cells pass HL_BUSY for a full-frame running color
  local prefix = repeat_char(" ", math.max(gut - 2, 0))
  local left = prefix .. bc.bl                                   -- "     ╰"
  local tail = label and (bc.h .. " " .. label .. " " .. bc.h .. bc.br) or bc.br
  local chunks = { { left, border_hl } }
  local mid_w = 0
  if cell and cell.cell_type == "code" then
    local exec = exec_status_chunks(cell, st)   -- {{" [n] ", hl}, {"✓ 0.1s", hl}}
    local lead = bc.h                            -- "─" (exec badge already starts with a space)
    chunks[#chunks + 1] = { lead, border_hl }
    mid_w = mid_w + dw(lead)
    for _, c in ipairs(exec) do
      chunks[#chunks + 1] = c
      mid_w = mid_w + dw(c[1])
    end
    local sep = " " .. bc.h                       -- " ─" after the badge
    chunks[#chunks + 1] = { sep, border_hl }
    mid_w = mid_w + dw(sep)
  end
  local pad = total_w - dw(left) - mid_w - dw(tail)
  chunks[#chunks + 1] = { repeat_char(bc.h, math.max(pad, 0)), border_hl }
  chunks[#chunks + 1] = { tail, border_hl }
  return chunks
end
M._footer_chunks = footer_chunks

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
  local boxed = cell.cell_type == "code" or editing

  -- ── markdown / raw, not being edited: frameless document flow ──
  if not boxed then
    -- NOTE: no selection bar in any extmark row. Bars are drawn ONLY by
    -- the statuscolumn (live per redraw), so selection changes never wait
    -- on an extmark re-render and can never linger over the gif/image.
    local md_lead = repeat_char(" ", gut)
    local lines_below = {}
    local external_refs = {}
    local function append_markdown_image(key)
      local ph = image.placeholder_virt_lines(key)
      if ph then
        for _, line in ipairs(ph) do
          table.insert(lines_below, { { md_lead, "Normal" }, { line[1][1], line[1][2] } })
        end
      else
        local ascii = image.ascii_lines_for(key)
        if ascii then
          for _, line in ipairs(ascii) do
            table.insert(lines_below, { { md_lead .. line, "Normal" } })
          end
        end
      end
    end
    if cell.cell_type == "markdown" then
      local Embedded = require("jupynvim.notebook.embedded")
      local External = require("jupynvim.notebook.external_image")
      local Markdown = require("jupynvim.notebook.markdown")
      local src = cell.source or ""
      for _, img in ipairs(Embedded.list_images(cell.id) or {}) do
        if src:find("jupynvim%-img:" .. img.idx, 1, false) then
          append_markdown_image(cell.id .. "_md_" .. img.idx)
        end
      end
      for _, ref in ipairs(Markdown.find_images(src)) do
        if External.classify(ref.src) then
          table.insert(external_refs, ref)
          append_markdown_image(tostring(nb.buf) .. "_" .. cell.id .. "_external_" .. #external_refs)
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
      require("jupynvim.notebook.markdown").render(buf, nb.border_ns,
        range.start, math.min(range.stop - 1, total - 1), width)
      local Embedded = require("jupynvim.notebook.embedded")
      local imgs = Embedded.list_images(cell.id)
      nb.image_ids = nb.image_ids or {}
      if imgs and #imgs > 0 then
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
      if #external_refs > 0 then
        local External = require("jupynvim.notebook.external_image")
        local J = require("jupynvim")
        nb.pending_external_images = nb.pending_external_images or {}
        local renderer = (J.config.image_renderer) or "chafa"
        for idx, ref in ipairs(external_refs) do
          local key = tostring(nb.buf) .. "_" .. cell.id .. "_external_" .. idx
          if not nb.image_ids[key] and not nb.pending_external_images[key] then
            nb.pending_external_images[key] = true
            local client = External.classify(ref.src) == "relative" and J._nb_client(nb) or nil
            External.resolve(ref.src, { notebook_path = nb.path, client = client }, function(err, resolved)
              if err or not resolved then
                nb.pending_external_images[key] = nil
                return
              end
              if require("jupynvim.notebook").get(nb.buf) ~= nb then return end
              image.ensure_transmitted(key, resolved.b64, function(id)
                nb.pending_external_images[key] = nil
                if id then
                  nb.image_ids[key] = id
                  vim.schedule(function() M.refresh(nb, win) end)
                end
              end, { renderer = renderer, mime = resolved.mime })
            end)
          end
        end
      end
    end
    return
  end

  -- ── boxed editor: code cells always; markdown while being edited ──
  local bc = box_chars(selected)
  local border_hl = busy and HL_BUSY or HL_BORDER   -- whole frame runs the busy color while executing
  local label = cell.cell_type == "code" and "Python" or "Markdown"
  local hdr = header_line(total_w, gut, cellno, busy, bc)
  vim.api.nvim_buf_set_extmark(buf, nb.border_ns, range.start, 0, {
    virt_lines = { { { hdr, border_hl } } },
    virt_lines_above = true,
    virt_lines_leftcol = true,
  })

  -- one leftcol extmark for everything under the source: row order inside
  -- a single extmark is guaranteed (footer, exec bar, images, spacer).
  -- No selection bars here: bars are statuscolumn-only (live), so these
  -- rows are selection-independent and never re-render on j/k.
  local lines_below = {}
  -- Bottom border carries the exec status inline (see footer_chunks); no
  -- separate "[n] ✓ 0.1s" line below the box anymore.
  table.insert(lines_below, footer_chunks(total_w, gut, bc, label, cell, st, border_hl))
  local sub_lead = repeat_char(" ", gut)
  if cell.cell_type == "code" then
    if #(cell.outputs or {}) > 0 then
      for _, l in ipairs(build_image_virt_lines(cell, width, nb, sub_lead)) do
        table.insert(lines_below, l)
      end
    end
  end
  -- spacer so the next cell's top border doesn't glue to our outputs;
  -- when the cell has a real output region it goes after THOSE lines
  if range.out_sep and range.out_stop then
    local last_out = math.min(range.out_stop, total) - 1
    if last_out >= 0 then
      pcall(vim.api.nvim_buf_set_extmark, buf, nb.border_ns, last_out, 0, {
        virt_lines = { { { " ", "Normal" } } },
        virt_lines_leftcol = true,
      })
    end
  else
    table.insert(lines_below, { { " ", "Normal" } })
  end

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
    -- No cell-background fill. The VSCode-style dark fill reads as gray bands
    -- on a transparent colorscheme (and stale paint smears it onto output rows
    -- on scroll); the borders alone mark the cell. Dropping it also saves one
    -- extmark per source line. Reintroduce as a configurable color later.
  end

  -- Output regions are real buffer lines in a python-filetype buffer, so
  -- treesitter/semantic tokens would paint them like code. Mask the whole
  -- region with a high-priority plain foreground: outputs read as TEXT.
  if range.out_sep and range.out_stop then
    local out_last = math.min(range.out_stop, total) - 1
    if out_last > range.out_sep then
      local ltxt = vim.api.nvim_buf_get_lines(buf, out_last, out_last + 1, false)[1] or ""
      pcall(vim.api.nvim_buf_set_extmark, buf, nb.border_ns, range.out_sep, 0, {
        end_row = out_last,
        end_col = #ltxt,
        hl_group = "JupynvimOutputText",
        -- REPLACE, not combine: Vim's regex syntax (when active alongside
        -- treesitter) colors any output line starting with "#" as
        -- pythonComment, which bled through a combine mask and made printed
        -- output like `# transpose` render gray. replace ignores the
        -- underlying syntax/treesitter entirely so output is pure plain text.
        hl_mode = "replace",
        -- Win over treesitter (100), LSP semantic tokens (125) and anything
        -- else. 250 was not always enough in real configs.
        priority = 5000,
      })
    end
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
    local sep_line = ranges[i].out_stop or ranges[i].stop
    if sep_line < total then
      local line_text = vim.api.nvim_buf_get_lines(buf, sep_line, sep_line + 1, false)[1] or ""
      vim.api.nvim_buf_set_extmark(buf, nb.border_ns, sep_line, 0, {
        end_col = #line_text,
        conceal = "",
        priority = 200,
      })
    end
  end
  -- conceal every OUT_SEP marker line as well
  for _, r in ipairs(ranges) do
    if r.out_sep and r.out_sep < total then
      local t = vim.api.nvim_buf_get_lines(buf, r.out_sep, r.out_sep + 1, false)[1] or ""
      pcall(vim.api.nvim_buf_set_extmark, buf, nb.border_ns, r.out_sep, 0, {
        end_col = #t,
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
      M.refresh(nb, vim.fn.bufwinid(nb.buf), { exec_tick = true })
    end))
  elseif not any_busy and nb._tick_timer then
    nb._tick_timer:stop()
    nb._tick_timer:close()
    nb._tick_timer = nil
  end
end

-- The actual render: clear the frame extmarks and rebuild them at the
-- window's CURRENT width. Synchronous, so callers can run it before a
-- redraw (no flash). Idempotent: it always reads live geometry.
local function do_render(nb, win, opts)
  local buf = nb.buf
  if not vim.api.nvim_buf_is_valid(buf) then return end
  M._render_n = (M._render_n or 0) + 1

  -- Geometry must come from a window CURRENTLY showing this buffer (not a
  -- float, and not a stale handle captured while a transient split briefly
  -- showed it). textoff = the statuscolumn gutter; width = full window.
  local CellMode = require("jupynvim.notebook.cellmode")
  local function is_float(w)
    local ok, cfg = pcall(vim.api.nvim_win_get_config, w)
    return ok and cfg.relative ~= nil and cfg.relative ~= ""
  end
  local function shows_buf(w)
    return vim.api.nvim_win_is_valid(w) and not is_float(w)
      and vim.api.nvim_win_get_buf(w) == buf
  end
  if not (win and shows_buf(win)) then
    win = nil
    for _, w in ipairs(vim.fn.win_findbuf(buf)) do
      if not is_float(w) then win = w; break end
    end
    win = win or vim.api.nvim_get_current_win()
  end
  -- gut = the statuscolumn (left frame) width. jupynvim FIXES this at
  -- CellMode.GUTTER and forces signcolumn=no for notebook windows, so the
  -- gutter is always exactly GUTTER cells. Do NOT read info.textoff: right
  -- after a layout change (terminal split, explorer, popup) it transiently
  -- reports the bare numberwidth before the statuscolumn is re-evaluated, which
  -- drew the header/footer ~3 columns too far left and left them misaligned
  -- with the source rows' │ edge (reproduced via a terminal-split capture).
  -- GUTTER is the true, stable width and never moves under us.
  local geom = { gut = CellMode.GUTTER, width = 80, total_w = 87 }
  if win and vim.api.nvim_win_is_valid(win) then
    local info = vim.fn.getwininfo(win)[1]
    if info then
      geom.total_w = info.width
      geom.width = math.max(info.width - geom.gut, 30)
    end
  end

  local ranges = CellMode.ranges(buf)
  local sel_idx = CellMode.selected_idx(buf)
  local edit_idx = (not CellMode.is_command(buf)) and sel_idx or nil

  -- Clear + rebuild in one synchronous pass so no half-state is ever shown.
  vim.api.nvim_buf_clear_namespace(buf, nb.border_ns, 0, -1)
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
  -- heal any static image whose virtual placement the terminal lost. Skip on
  -- the busy-ticker tick: that fires every 500ms only to advance the live
  -- "[*] 0.3s" timer, and re-asserting placements that often visibly flashes
  -- the image. Placements only get lost on layout changes, which refresh
  -- through the normal (non-tick) path.
  if not (opts and (opts.exec_tick or opts.no_image)) then
    local image_keys = {}
    for key in pairs(nb.image_ids or {}) do image_keys[key] = true end
    pcall(image.reassert_virtual_placements, image_keys)
  end
end

-- Debounced/serialized refresh: coalesces bursts and runs on vim.schedule
-- (after the current change settles, before the next redraw). Use for
-- content changes (output, edits, selection) where a tick of latency is
-- fine.
local _refresh_pending = {}  -- buf -> true
function M.refresh(nb, win, opts)
  local buf = nb.buf
  if not vim.api.nvim_buf_is_valid(buf) then return end
  if _refresh_pending[buf] then return end
  _refresh_pending[buf] = true
  vim.schedule(function()
    _refresh_pending[buf] = nil
    do_render(nb, win, opts)
  end)
end

-- SYNCHRONOUS refresh: rebuilds frames right now. Use when the layout has
-- just changed and the caller wants the correct frames on the very next
-- redraw with no intermediate stale frame (the explorer/terminal toggles).
function M.refresh_sync(nb, win, opts)
  pcall(do_render, nb, win, opts)
end

function M.setup_highlights()
  local hl = vim.api.nvim_set_hl
  -- Visible borders; the selected cell's border goes bright + heavy glyphs.
  hl(0, HL_BORDER,     { default = true, link = "FloatBorder" })
  hl(0, HL_BORDER_SEL, { default = true, link = "DiagnosticInfo" })   --unused
  hl(0, HL_HEADER,     { default = true, link = "Comment" })
  hl(0, HL_BUSY,       { default = true, link = "DiagnosticWarn" })
  hl(0, HL_OUTPUT,     { default = true, link = "NonText" })
  hl(0, HL_ERROR,      { default = true, link = "DiagnosticError" })
  hl(0, HL_STREAM,     { default = true, link = "Normal" })           --unused
  hl(0, HL_RESULT,     { default = true, link = "Constant" })         --unused
  hl(0, HL_OK,         { default = true, link = "DiagnosticOk" })
  hl(0, HL_MORE,       { default = true, link = "Comment" })          --unused
  hl(0, HL_SEPARATOR,  { default = true, link = "WinSeparator" })     --unused
  -- Output regions render as plain TEXT (mask treesitter/LSP code colors).
  -- A whole block of output drawn in the theme's plain Normal can read as
  -- "gray" sitting next to syntax-highlighted code. So by default lift the
  -- color a bit above Normal toward white on dark themes (kept theme-adaptive
  -- by deriving from the live Normal, and recomputed on ColorScheme). On light
  -- themes, or when the user sets `output_color`, use the explicit value.
  -- setup({ output_color = "#rrggbb" }) overrides entirely. This runs again on
  -- ColorScheme, so it always reflects the active Normal, never a stale snap.
  local out_color = (require("jupynvim").config or {}).output_color
  if type(out_color) == "string" and out_color ~= "" then
    -- explicit user config: a hard set so it always overrides, no `default`.
    hl(0, "JupynvimOutputText", { fg = out_color })
  else
    local nrm = vim.api.nvim_get_hl(0, { name = "Normal" })
    if vim.o.background ~= "light" and type(nrm.fg) == "number" then
      local r = math.floor(nrm.fg / 65536) % 256
      local g = math.floor(nrm.fg / 256) % 256
      local b = nrm.fg % 256
      local function lift(c) return math.floor(c + (255 - c) * 0.45) end
      hl(0, "JupynvimOutputText",
        { default = true, fg = string.format("#%02x%02x%02x", lift(r), lift(g), lift(b)) })
    else
      hl(0, "JupynvimOutputText", { default = true, link = "Normal" })
    end
  end
  pcall(vim.fn.sign_define, "JupynvimBar", { text = "│", texthl = HL_BORDER })
  require("jupynvim.notebook.markdown").setup_hl()
  require("jupynvim.notebook.cellmode").setup_hl()
end

return M

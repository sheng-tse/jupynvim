-- Strip embedded data:image/...;base64,XXX URIs from markdown source.
-- The original source (with full base64) is preserved in a side-table per
-- cell so we can:
--   - keep the buffer SHORT (huge base64 strings make Neovim laggy)
--   - render the actual image inline via the image pipeline
--   - restore the original source on save (the .ipynb file keeps the data: URI)

local M = {}

-- per_cell[cell_id] = { images = { { idx, alt, b64, mime } }, replacements = N }
local per_cell = {}

-- Pattern: ![alt](data:<mime>;base64,<payload>) — accepts ANY image/*.
local function find_data_uri(s, init)
  init = init or 1
  local bs = s:find("!%[", init)
  if not bs then return nil end
  local alt_end = s:find("]", bs + 2, true)
  if not alt_end then return nil end
  if s:sub(alt_end + 1, alt_end + 1) ~= "(" then return nil end
  local url_start = alt_end + 2
  if s:sub(url_start, url_start + 4) ~= "data:" then return nil end
  local b64_marker = s:find(";base64,", url_start, true)
  if not b64_marker then return nil end
  local mime = s:sub(url_start + 5, b64_marker - 1)
  -- Accept any image/* (png, gif, jpeg, svg+xml, webp, etc.)
  if not mime:match("^image/") then return nil end
  local url_end = s:find(")", b64_marker, true)
  if not url_end then return nil end
  local alt = s:sub(bs + 2, alt_end - 1)
  local b64 = s:sub(b64_marker + 8, url_end - 1)
  return {
    match_start = bs,
    match_end = url_end,
    alt = alt, mime = mime, b64 = b64,
  }
end

-- Scan markdown source for embedded data:image/* URIs. Records each image's
-- byte range within the source so render.lua can:
--   1. conceal the long base64 from view (but keep editable)
--   2. transmit the image to the terminal
-- The buffer text stays IDENTICAL to the original — fully editable.
function M.scan(cell_id, source)
  per_cell[cell_id] = { images = {} }
  if type(source) ~= "string" or source == "" then return end
  local pos = 1
  local idx = 0
  while true do
    local found = find_data_uri(source, pos)
    if not found then break end
    idx = idx + 1
    -- Compute the line within source where this match starts and column offset.
    -- Caller (render.lua) needs (lnum_within_cell, col, end_col) to place conceal extmarks.
    local before = source:sub(1, found.match_start - 1)
    local lnum = 0
    for _ in before:gmatch("\n") do lnum = lnum + 1 end
    local last_nl = before:find("\n[^\n]*$") or 0
    local col = found.match_start - last_nl - 1
    if last_nl == 0 then col = found.match_start - 1 end
    -- The match may span multiple lines if the source has \n inside the URI
    -- (rare but possible). Compute end position similarly.
    local match_text = source:sub(found.match_start, found.match_end)
    local nl_in_match = 0
    for _ in match_text:gmatch("\n") do nl_in_match = nl_in_match + 1 end
    local end_lnum = lnum + nl_in_match
    local end_col
    if nl_in_match == 0 then
      end_col = col + #match_text
    else
      local last_seg = match_text:match("\n([^\n]*)$") or ""
      end_col = #last_seg
    end
    table.insert(per_cell[cell_id].images, {
      idx = idx, alt = found.alt, mime = found.mime, b64 = found.b64,
      lnum = lnum, col = col,
      end_lnum = end_lnum, end_col = end_col,
    })
    pos = found.match_end + 1
  end
end

-- Replace each `![alt](data:image/...;base64,XXX)` in source with a SHORT
-- placeholder `![alt](jupynvim-img:N)` so the buffer stays small (huge base64
-- in buffer = laggy scrolling/typing, even when concealed).
-- Originals are saved so postprocess() can restore them on save.
function M.preprocess(cell_id, source)
  per_cell[cell_id] = { images = {}, originals = {} }
  if type(source) ~= "string" or source == "" then return source end
  local out = {}
  local pos = 1
  local idx = 0
  while true do
    local found = find_data_uri(source, pos)
    if not found then
      table.insert(out, source:sub(pos))
      break
    end
    table.insert(out, source:sub(pos, found.match_start - 1))
    idx = idx + 1
    table.insert(out, string.format("![%s](jupynvim-img:%d)", found.alt, idx))
    table.insert(per_cell[cell_id].images, {
      idx = idx, alt = found.alt, mime = found.mime, b64 = found.b64,
    })
    table.insert(per_cell[cell_id].originals, source:sub(found.match_start, found.match_end))
    pos = found.match_end + 1
  end
  return table.concat(out)
end

-- Restore: replace each `![alt](jupynvim-img:N)` with the saved original.
function M.postprocess(cell_id, processed_source)
  local entry = per_cell[cell_id]
  if not entry or not entry.originals or #entry.originals == 0 then
    return processed_source
  end
  -- Iterate by image entry (not by parallel originals index) so we tolerate
  -- length mismatches between the two arrays. Use the image's `idx` field
  -- as the placeholder identity, not the array position.
  local out = processed_source
  for i, img in ipairs(entry.images) do
    local original = entry.originals[i]
    if img and original then
      local pat = "%!%[[^%]]*%]%(jupynvim%-img:" .. img.idx .. "%)"
      out = out:gsub(pat, function() return original end, 1)
    end
  end
  return out
end

-- Like preprocess(), but additive: keeps existing entries / placeholders in
-- the cell's source intact and only converts NEW data:image URIs (the ones
-- the user just pasted) into placeholders. Indices for new entries continue
-- where the existing ones leave off, so old `jupynvim-img:N` references stay
-- bound to their original base64.
function M.preprocess_incremental(cell_id, source)
  if type(source) ~= "string" or source == "" then return source end
  if not source:find("data:image", 1, true) then return source end
  local entry = per_cell[cell_id]
  if not entry then
    return M.preprocess(cell_id, source)
  end
  local max_idx = 0
  for _, img in ipairs(entry.images) do
    if img.idx > max_idx then max_idx = img.idx end
  end
  local out = {}
  local pos = 1
  while true do
    local found = find_data_uri(source, pos)
    if not found then
      table.insert(out, source:sub(pos))
      break
    end
    table.insert(out, source:sub(pos, found.match_start - 1))
    max_idx = max_idx + 1
    table.insert(out, string.format("![%s](jupynvim-img:%d)", found.alt, max_idx))
    table.insert(entry.images, {
      idx = max_idx, alt = found.alt, mime = found.mime, b64 = found.b64,
    })
    table.insert(entry.originals, source:sub(found.match_start, found.match_end))
    pos = found.match_end + 1
  end
  return table.concat(out)
end

function M.get_image(cell_id, idx)
  local entry = per_cell[cell_id]
  if not entry then return nil end
  for _, img in ipairs(entry.images) do
    if img.idx == idx then return img end
  end
  return nil
end

function M.list_images(cell_id)
  local entry = per_cell[cell_id]
  if not entry then return {} end
  return entry.images
end

function M.clear(cell_id)
  per_cell[cell_id] = nil
end

function M.clear_all()
  per_cell = {}
end

return M

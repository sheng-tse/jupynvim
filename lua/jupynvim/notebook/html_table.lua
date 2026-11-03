-- Text rendering for an HTML <table> output.
--
-- Some outputs carry their content only as HTML. A pandas Styler is the common
-- one: its text/plain is "<pandas.io.formats.style.Styler at 0x...>", so the
-- formatted table (thousands separators, percents, renamed columns) never
-- showed. This turns the first <table> into aligned text rows. It is a small
-- pattern-based reader for the tables pandas and similar libraries emit, not a
-- general HTML parser: nested tables, rowspan and inline styling are ignored.

local M = {}

local ENTITIES = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " " }

local function unescape(s)
  s = s:gsub("&#[xX](%x+);", function(h) return vim.fn.nr2char(tonumber(h, 16)) end)
  s = s:gsub("&#(%d+);", function(d) return vim.fn.nr2char(tonumber(d)) end)
  s = s:gsub("&(%a+);", function(n) return ENTITIES[n:lower()] end)
  return s
end

local function cell_text(inner)
  local s = inner:gsub("<[Bb][Rr]%s*/?>", " "):gsub("<[^>]*>", "")
  s = unescape(s):gsub("%s+", " ")
  return vim.trim(s)
end

-- Numbers and percents read best right-aligned. Both "1,234.5" and the
-- "1.234,5" many locales use count.
local function numeric(s)
  return s:match("^%(?[-+]?%d[%d.,]*%%?%)?$") ~= nil
end

-- Rows of cell strings for the first table, or nil when there is none.
function M.rows(html)
  if type(html) ~= "string" then return nil end
  local lower = html:lower()
  local s = lower:find("<table", 1, true)
  if not s then return nil end
  local e = lower:find("</table>", s, true)
  local body = html:sub(s, e and (e + #"</table>" - 1) or #html)

  local rows = {}
  for tr in body:gmatch("<[Tt][Rr][^>]*>(.-)</[Tt][Rr]>") do
    local row, any = {}, false
    for attrs, inner in tr:gmatch("<[Tt][HhDd]([^>]*)>(.-)</[Tt][HhDd]>") do
      local text = cell_text(inner)
      if text ~= "" then any = true end
      table.insert(row, text)
      local span = tonumber(attrs:match("[Cc][Oo][Ll][Ss][Pp][Aa][Nn]%s*=%s*[\"']?(%d+)"))
      for _ = 2, math.min(span or 1, 64) do table.insert(row, "") end
    end
    if any then table.insert(rows, row) end
  end
  return #rows > 0 and rows or nil
end

-- Aligned text for the first table in `html`, or nil when there is none.
function M.to_text(html)
  local rows = M.rows(html)
  if not rows then return nil end
  local ncol, widths, num = 0, {}, {}
  for _, row in ipairs(rows) do ncol = math.max(ncol, #row) end
  for c = 1, ncol do
    widths[c], num[c] = 0, true
    for r, row in ipairs(rows) do
      local v = row[c] or ""
      widths[c] = math.max(widths[c], vim.fn.strdisplaywidth(v))
      -- The header row is text; let the body decide how a column aligns.
      if r > 1 and v ~= "" and not numeric(v) then num[c] = false end
    end
  end
  local out = {}
  for _, row in ipairs(rows) do
    local parts = {}
    for c = 1, ncol do
      local v = row[c] or ""
      local pad = string.rep(" ", widths[c] - vim.fn.strdisplaywidth(v))
      parts[c] = num[c] and (pad .. v) or (v .. pad)
    end
    table.insert(out, (table.concat(parts, "  "):gsub("%s+$", "")))
  end
  return table.concat(out, "\n")
end

return M

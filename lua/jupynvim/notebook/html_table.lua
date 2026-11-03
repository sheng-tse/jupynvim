-- Text rendering for an HTML <table> output.
--
-- Some outputs carry their content only as HTML. A pandas Styler is the common
-- one: its text/plain is "<pandas.io.formats.style.Styler at 0x...>", so the
-- formatted table (thousands separators, percents, renamed columns) never
-- showed. This turns the first <table> into aligned text rows. It is a small
-- reader for the tables pandas and similar libraries emit, not a general HTML
-- parser: a table that holds another table is left alone (nil), and inline
-- styling is dropped. A table with no text (an empty DataFrame's Styler) reads
-- as an empty text, so the bare repr does not show in its place.
--
-- The layout follows VS Code's DataFrame output: every cell is right-aligned;
-- when the columns have two or more levels (a MultiIndex), the header rows above
-- the last one are left-aligned, as pandas' CSS does (a row that names only the
-- index levels is not a level of the columns); columns are two spaces apart; a
-- caption is centered over the table on a line of its own, under the table when
-- its style says caption-side: bottom.
--
-- It is built to read a table of any size in one pass: plain finds on a lowered
-- copy of the HTML (no pattern is run over the markup), every search kept as a
-- cursor that only moves forward so a document without the thing searched for
-- is scanned once, and a cell's text is cleaned only when it holds a tag, an
-- entity or whitespace.

local M = {}

-- How many tables have been read. The notebook keeps one conversion per output
-- (notebook/init.lua), and its spec counts them here.
M.conversions = 0

local find, sub, byte, lower_, rep, gsub, match =
  string.find, string.sub, string.byte, string.lower, string.rep, string.gsub, string.match
-- Character classes are spelled out, never %s, %a or %w: those follow the C
-- library's locale, which may count bytes of UTF-8 text as letters or space.
-- HTML's white space is tab, line feed, form feed, carriage return and space.
local NBSP = "\194\160" -- U+00A0, a no-break space
local concat = table.concat
local strwidth = vim.api.nvim_strwidth

-- colspan and rowspan are read up to this, like a browser does
local MAX_SPAN = 1000
-- Cells a table may hold, spans included. A hostile table (a hundred thousand
-- cells that each span a thousand columns) would otherwise need a hundred
-- million; the rest of such a table is not read.
local MAX_CELLS = 4000000

local function utf8char(cp)
  if not cp or cp ~= cp or cp <= 0 or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF) then
    return "\239\191\189"
  end
  if cp < 0x80 then return string.char(cp) end
  if cp < 0x800 then return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40) end
  if cp < 0x10000 then
    return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
  end
  return string.char(0xF0 + math.floor(cp / 0x40000), 0x80 + math.floor(cp / 0x1000) % 0x40,
    0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

-- Named entities: the XML five, the no-break space, and the ones data tables
-- use. Names are case sensitive, as in HTML; the upper case forms are the
-- legacy ones HTML defines.
local ENTITIES = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = NBSP,
                   AMP = "&", LT = "<", GT = ">", QUOT = '"' }
for name, cp in pairs({
  COPY = 0xA9, REG = 0xAE,
  copy = 0xA9, reg = 0xAE, deg = 0xB0, plusmn = 0xB1, micro = 0xB5, middot = 0xB7, times = 0xD7,
  divide = 0xF7, laquo = 0xAB, raquo = 0xBB, cent = 0xA2, pound = 0xA3, yen = 0xA5, sect = 0xA7,
  para = 0xB6, euro = 0x20AC, hellip = 0x2026, bull = 0x2022, ndash = 0x2013, mdash = 0x2014,
  lsquo = 0x2018, rsquo = 0x2019, ldquo = 0x201C, rdquo = 0x201D, larr = 0x2190, uarr = 0x2191,
  rarr = 0x2192, darr = 0x2193, minus = 0x2212, ne = 0x2260, le = 0x2264, ge = 0x2265, infin = 0x221E,
}) do
  ENTITIES[name] = utf8char(cp)
end

-- Decoded in one pass, so "&amp;lt;" stays "&lt;". An entity this does not
-- know is kept as it is.
local function entity(n)
  if byte(n, 1) == 35 then
    local x = match(n, "^#[xX](%x+)$")
    if x then return utf8char(tonumber(x, 16)) end
    local d = match(n, "^#(%d+)$")
    if d then return utf8char(tonumber(d)) end
    return nil
  end
  return ENTITIES[n]
end

-- HTML's white space
local WS = { [9] = true, [10] = true, [12] = true, [13] = true, [32] = true }

-- Where the start (or end) tag at `pos` ends, read the way an HTML tokenizer
-- reads its attributes: `nlen` is the length of "<" and the name, and the
-- ">" that ends the tag is the first one outside a quoted value. An attribute
-- name may start with "=" and may hold quotes (both parse errors a browser
-- reads through); an unquoted value ends at white space or ">". nil when the
-- tag never ends (an unclosed quote runs to the end, as in a browser).
local function tag_end_exact(s, pos, nlen)
  local i, n = pos + nlen, #s
  while i <= n do
    local c = byte(s, i)
    if c == 62 then return i end
    if WS[c] or c == 47 then
      i = i + 1
    else
      local j = find(s, "[\t\n\f\r />=]", i + 1)
      if not j then return nil end
      local k = find(s, "[^\t\n\f\r ]", j)
      if not k then return nil end
      if byte(s, k) == 61 then
        local v = find(s, "[^\t\n\f\r ]", k + 1)
        if not v then return nil end
        local q = byte(s, v)
        if q == 34 or q == 39 then
          local close = find(s, q == 34 and '"' or "'", v + 1, true)
          if not close then return nil end
          i = close + 1
        elseif q == 62 then
          return v
        else
          local e = find(s, "[\t\n\f\r >]", v + 1)
          if not e then return nil end
          i = e
        end
      else
        i = k
      end
    end
  end
  return nil
end

-- The tags of a cell's inner HTML dropped one by one, each ended where the
-- tokenizer ends it: a quoted attribute value may hold ">" (a title, a
-- formatter's markup) and a comment ends only at "-->". <br> is a space. The
-- text after a tag that never ends is dropped, as a browser shows nothing of it.
local function strip_tags(s)
  local out, no, p = {}, 0, 1
  while true do
    local lt = find(s, "<[A-Za-z/!?]", p)
    no = no + 1
    if not lt then out[no] = sub(s, p); break end
    out[no] = sub(s, p, lt - 1)
    local c, e = byte(s, lt + 1), nil
    if c == 33 and sub(s, lt, lt + 3) == "<!--" then
      local _, ce = find(s, "-->", lt + 4, true)
      e = ce
    elseif c == 33 or c == 63 then
      -- <!...> and <?...> are bogus comments: they end at the first ">"
      e = find(s, ">", lt + 2, true)
    else
      local ne = find(s, "[\t\n\f\r />]", lt + 2)
      e = ne and tag_end_exact(s, lt, ne - lt)
      if e and ne - lt == 3 and lower_(sub(s, lt + 1, lt + 2)) == "br" then
        no = no + 1; out[no] = " "
      end
    end
    if not e then break end
    p = e + 1
  end
  return concat(out, "", 1, no)
end

-- A cell's inner HTML as one line of plain text: tags dropped (<br> is a
-- space), entities decoded, white space folded and trimmed, no-break spaces
-- kept as they are. Each pass runs only when the text has a tag, an entity,
-- white space or a no-break space to deal with.
local function cell_text(inner)
  local s = inner
  if find(s, "[<& \t\n\f\r\194]") then
    if find(s, "<", 1, true) then
      -- A tag opens only at "<" and a letter, "/", "!" or "?", as an HTML
      -- tokenizer reads it. Any other "<" is text: "x < 5", "a <> b", "<18".
      if find(s, "[\"']") or find(s, "<!--", 1, true) then
        -- a tag here may hold ">" inside a quoted value, a comment ">"
        s = strip_tags(s)
      else
        s = gsub(s, "<[Bb][Rr]%f[ \t\n\f\r/>][^>]*>", " ")
        s = gsub(s, "<[A-Za-z/!?][^>]*>", "")
      end
    end
    if find(s, "&", 1, true) then s = gsub(s, "&(#?[A-Za-z0-9]+);", entity) end
    if find(s, "[ \t\n\f\r]") then
      s = gsub(s, "[ \t\n\f\r]+", " ")
      if byte(s, 1) == 32 then s = sub(s, 2) end
      if byte(s, -1) == 32 then s = sub(s, 1, -2) end
    end
    -- A no-break space is not folded (a run of them shows as written) and
    -- shows as a space; a cell of nothing else is empty, like pandas' blank
    -- header cells (&nbsp;).
    if find(s, NBSP, 1, true) then
      s = gsub(s, NBSP, " ")
      if not find(s, "[^ ]") then s = "" end
    end
  end
  return s
end

-- The last caption-side declared in `text`, or nil.
local function last_side(text)
  local side, p = nil, 1
  while true do
    local _, b = find(text, "caption-side", p, true)
    if not b then return side end
    local v = match(text, "^[ \t\n\f\r]*:[ \t\n\f\r]*([a-z-]+)", b + 1)
    if v then side = v end
    p = b + 1
  end
end

-- The value of attribute `name` in a lowered start tag, or nil.
local function attr_of(tag, name)
  local pre = "[ \t\n\f\r/]" .. name .. "[ \t\n\f\r]*=[ \t\n\f\r]*"
  return match(tag, pre .. '"([^"]*)"') or match(tag, pre .. "'([^']*)'")
    or match(tag, pre .. "([^ \t\n\f\r>\"'=<`]+)")
end

-- Does the last compound of a selector, `last` (it starts with "caption"),
-- pick this caption? Its classes and id are checked against the caption's
-- own; attribute selectors and pseudo-classes are taken as matching, and so
-- are the selector's ancestors (a Styler writes "#T_<its table id> caption").
local function picks_caption(last, cid, classes)
  for kind, name in last:gmatch("([.#])([^.#%[:]+)") do
    if kind == "#" then
      if name ~= cid then return false end
    elseif not classes[name] then
      return false
    end
  end
  return true
end

-- The last caption-side of the <style> rules in `pre` whose selector picks
-- the caption (`ctag`, its lowered start tag): the last compound of one of
-- its selectors is a caption element with no class or id the caption lacks
-- ("caption", "#T_x caption", "table > caption.c"), or nil. Rules inside an
-- at-rule (@media) count as written.
local function caption_rule_side(pre, ctag)
  local cid = attr_of(ctag, "id")
  local classes = {}
  for c in (attr_of(ctag, "class") or ""):gmatch("[^ \t\n\f\r]+") do classes[c] = true end
  local side, p = nil, 1
  while true do
    local st = find(pre, "<style", p, true)
    if not st then return side end
    local open = find(pre, ">", st, true)
    if not open then return side end
    local close = find(pre, "</style", open, true) or (#pre + 1)
    local css = gsub(sub(pre, open + 1, close - 1), "/%*.-%*/", " ")
    -- each "selector { declarations }"; an at-rule's own "{" just opens its rules
    local q = 1
    while true do
      local b = find(css, "[{}]", q)
      if not b then break end
      if byte(css, b) == 125 then
        q = b + 1
      else
        local sel = match(sub(css, q, b - 1), "^[ \t\n\f\r]*(.-)[ \t\n\f\r]*$")
        if byte(sel, 1) == 64 then
          q = b + 1
        else
          local e = find(css, "}", b + 1, true) or (#css + 1)
          for part in (sel .. ","):gmatch("([^,]*),") do
            local last = match(part, "([^ \t\n\f\r>+~]+)[ \t\n\f\r]*$")
            if last and match(last, "^caption%f[^a-z0-9_-]") and picks_caption(last, cid, classes) then
              side = last_side(sub(css, b + 1, e - 1)) or side
              break
            end
          end
          q = e + 1
        end
      end
    end
    p = close + 1
  end
end

-- Is the caption put under the table? caption-side is inherited, so what the
-- caption declares itself wins: its style attribute, then the <style> rules
-- that pick the caption (a Styler's set_table_styles with selector
-- "caption"). Only when neither says anything does what the table inherits
-- count: the last caption-side written before the caption (a rule for the
-- table, the table's style attribute).
local function caption_bottom(lower, cs, cgt)
  local tag = sub(lower, cs, cgt)
  if find(tag, "caption-side", 1, true) then
    local attr = attr_of(tag, "style")
    local own = attr and last_side(attr)
    if own then return own == "bottom" end
  end
  local pre = sub(lower, 1, cs - 1)
  if not find(pre, "caption-side", 1, true) then return false end
  local rule = caption_rule_side(pre, tag)
  if rule then return rule == "bottom" end
  return last_side(pre) == "bottom"
end

-- the characters that may follow a tag name: ">", whitespace or "/"
local BOUND = { [62] = true, [32] = true, [9] = true, [10] = true, [12] = true, [13] = true, [47] = true }

-- A search for `needle` in `lower` that only moves forward: it returns the first
-- match at or after `pos` (and, when strict, followed by a tag boundary) and
-- remembers it, so asking again from an earlier place is answered at once and a
-- needle that is not there is looked for once for the whole document. Callers
-- always ask from a place at or after where they last asked.
local function cursor(lower, needle, strict)
  local n, cached = #needle, 0
  return function(pos)
    while true do
      if cached == false then return nil end
      if cached < pos then
        cached = find(lower, needle, pos, true) or false
        if cached == false then return nil end
      end
      if not strict then return cached end
      local b = byte(lower, cached + n)
      if b and BOUND[b] then return cached end
      pos = cached + n
    end
  end
end

local SP = setmetatable({}, { __index = function(t, n)
  local s = rep(" ", n)
  t[n] = s
  return s
end })

-- Reads the first table. Returns nil when there is none (or it holds another
-- table), else a table with: rows (cell text per row, a covered or spanned
-- column a "" and trailing ones missing), wid (the display width of each of
-- those cells), spans (per row, column -> colspan for cells that span), n (the
-- row count, 0 for a table with no text), ncol, header (row -> true for rows in
-- the <thead>), left_upto (header rows above it are left-aligned), widths (per
-- column), caption and caption_last (the caption goes under the table).
local function read(html)
  if type(html) ~= "string" then return nil end
  M.conversions = M.conversions + 1
  local lower = lower_(html)
  local tablec = cursor(lower, "<table", true)
  local s = tablec(1)
  if not s then return nil end
  local e = find(lower, "</table", s, true) or (#lower + 1)
  local inner = tablec(s + 6)
  if inner and inner < e then return nil end

  local trc = cursor(lower, "<tr", true)
  local trclose = cursor(lower, "</tr", true)
  local tc = cursor(lower, "<t", false)
  local tdclose = cursor(lower, "</td", true)
  local thclose = cursor(lower, "</th", true)
  local spanc = cursor(lower, "span", false)
  -- The ">" that ends the start tag at `pos` (`nlen`: "<" and the name), the
  -- first one outside a quoted value ('<td title="a > b">' ends after the
  -- title, as pandas' set_tooltips(as_title_attribute=True) writes it). The
  -- next '"', "'" and "=" are kept (nd, ns, ne; false once there is none) and
  -- only looked for again once passed, so each is found once for the whole
  -- document. A tag whose every quote before its first ">" opens a value
  -- right after "=" and a name (no other "=" since the last value), or closes
  -- one, ends there; any other (an unclosed quote, a quote in a name or an
  -- unquoted value, white space around "=") is read by the tokenizer's rules,
  -- tag_end_exact.
  local nd, ns, ne = 0, 0, 0
  local function tagend(pos, nlen)
    local p = pos + nlen
    local gt = find(lower, ">", p, true)
    if not gt then return nil end
    while true do
      if nd and nd < p then nd = find(lower, '"', p, true) or false end
      if ns and ns < p then ns = find(lower, "'", p, true) or false end
      local o = nd
      if ns and (not o or ns < o) then o = ns end
      if not o or o > gt then return gt end
      if ne and ne < p then ne = find(lower, "=", p, true) or false end
      if ne ~= o - 1 or ne - 1 < p then return tag_end_exact(lower, pos, nlen) end
      local b = byte(lower, ne - 1)
      if WS[b] or b == 47 then return tag_end_exact(lower, pos, nlen) end
      local close
      if o == nd then
        nd = find(lower, '"', o + 1, true) or false
        close = nd
      else
        ns = find(lower, "'", o + 1, true) or false
        close = ns
      end
      if not close then return nil end
      p = close + 1
      if close > gt then
        gt = find(lower, ">", p, true)
        if not gt then return nil end
      end
    end
  end

  -- the first <td or <th at or after pos
  local function nextcell(pos)
    local p = tc(pos)
    while p do
      local k = byte(lower, p + 2)
      if k == 100 or k == 104 then
        local b = byte(lower, p + 3)
        if b and BOUND[b] then return p end
      end
      p = tc(p + 2)
    end
  end

  local a = trc(s)
  if a and a >= e then a = nil end

  -- Before the first row (in a table with no rows, the whole table): the
  -- caption (the first one) and the <thead>, whose rows are the header rows.
  local head = sub(lower, s, (a or e) - 1)
  local caption, caption_last
  local cs = find(head, "<caption", 1, true)
  if cs then
    local b = byte(head, cs + 8)
    cs = s + cs - 1
    local cgt = b and BOUND[b] and tagend(cs, 8)
    if cgt and cgt < (a or e) then
      local cend = find(lower, "</caption", cgt, true)
      if not cend or cend > e then cend = e end
      local text = cell_text(sub(html, cgt + 1, cend - 1))
      if text ~= "" then
        caption = text
        caption_last = caption_bottom(lower, cs, cgt)
      end
    end
  end
  local hs, he = find(head, "<thead", 1, true), nil
  if hs then
    local b = byte(head, hs + 6)
    if b and BOUND[b] then
      hs = s + hs - 1
      he = find(lower, "</thead", hs, true) or find(lower, "<tbody", hs, true) or e
      if he > e then he = e end
    else
      hs = nil
    end
  end

  local rows, wid, spans, header = {}, {}, {}, {}
  local widths, wspans = {}, {}
  local n, ncol, last_header, budget = 0, 0, 0, MAX_CELLS
  -- hend[r]: the last column a text cell of header row r reaches; nidx: the
  -- index columns, the leading <th> cells of the first body row
  local hend, nidx = {}, nil
  -- cover[col]: how many rows below are still covered by a rowspan in col
  local cover, ncover = {}, 0

  while a and a < e and budget > 0 do
    local gt = tagend(a, 3)
    if not gt then break end
    -- a row ends at its </tr>, else where the next row starts, else with the table
    local z = trclose(gt)
    local na = trc(gt)
    if na and (not z or na < z) then z = na end
    if not z or z > e then z = e end

    local row, rwid, rspan, newcover = {}, {}, nil, nil
    local len, col, any = 0, 1, false
    local inhead = hs and a > hs and a < he
    local leading, lead, tend = not inhead and not nidx, 0, 0
    local ca = nextcell(gt + 1)
    while ca and ca < z do
      local cgt = tagend(ca, 3)
      if not cgt or cgt >= z then break end
      local nc = nextcell(cgt + 1)
      local cl, isth
      if byte(lower, ca + 2) == 100 then cl = tdclose(cgt) else cl, isth = thclose(cgt), true end
      local cend = z
      if cl and cl < cend then cend = cl end
      if nc and nc < cend then cend = nc end

      local colspan, rowspan = 1, 1
      local sp = spanc(ca)
      if sp and sp < cgt then
        local attrs = sub(lower, ca + 3, cgt - 1)
        local v = match(attrs, "colspan[ \t\n\f\r]*=[ \t\n\f\r]*[\"']?(%d+)")
        if v then
          v = tonumber(v)
          colspan = v > MAX_SPAN and MAX_SPAN or (v < 1 and 1 or v)
        end
        v = match(attrs, "rowspan[ \t\n\f\r]*=[ \t\n\f\r]*[\"']?(%d+)")
        if v then
          v = tonumber(v)
          rowspan = v > MAX_SPAN and MAX_SPAN or (v < 1 and MAX_SPAN or v)
        end
      end

      -- columns a rowspan above still covers are skipped
      if ncover > 0 then
        while cover[col] do col = col + 1 end
      end

      budget = budget - (col - len) - (rowspan > 1 and colspan or 0)
      if budget < 0 then break end
      if leading then
        if isth then lead = col + colspan - 1 else leading = false end
      end
      local text = cell_text(sub(html, cgt + 1, cend - 1))
      for k = len + 1, col - 1 do row[k], rwid[k] = "", 0 end
      row[col] = text
      len = col
      if text ~= "" then
        any = true
        if col + colspan - 1 > tend then tend = col + colspan - 1 end
        local w = strwidth(text)
        rwid[col] = w
        if colspan == 1 then
          local cw = widths[col]
          if not cw or w > cw then widths[col] = w end
        else
          wspans[#wspans + 1] = { col, colspan, w }
        end
      else
        rwid[col] = 0
      end
      if colspan > 1 then
        rspan = rspan or {}
        rspan[col] = colspan
      end
      if rowspan > 1 then
        newcover = newcover or {}
        newcover[#newcover + 1] = { col, colspan, rowspan - 1 }
      end
      col = col + colspan
      if col - 1 > ncol then ncol = col - 1 end
      ca = nc
    end

    -- Every rowspan still running covers one row less, whether or not this row
    -- shows; the ones this row starts begin to count from the next. The count
    -- of running ones is charged to the budget, so a table cannot make every
    -- row walk thousands of them.
    if ncover > 0 then
      budget = budget - ncover
      for k, v in pairs(cover) do
        if v <= 1 then
          cover[k] = nil
          ncover = ncover - 1
        else
          cover[k] = v - 1
        end
      end
    end
    if newcover then
      for _, nco in ipairs(newcover) do
        for k = nco[1], nco[1] + nco[2] - 1 do
          if not cover[k] then ncover = ncover + 1 end
          cover[k] = nco[3]
        end
      end
    end

    if any then
      n = n + 1
      rows[n], wid[n], spans[n] = row, rwid, rspan
      if inhead then
        header[n] = true
        last_header = n
        hend[n] = tend
      elseif not nidx then
        nidx = lead
      end
    end
    a = trc(z)
  end

  -- The levels of the columns: header rows with text past the index columns.
  -- A row of index names has text only in them. Header rows above the last one
  -- are left-aligned only when there are two or more levels (pandas' CSS
  -- left-aligns header rows only for MultiIndex columns).
  local levels = 0
  for r = 1, last_header do
    if header[r] and hend[r] > (nidx or 0) then levels = levels + 1 end
  end

  for c = 1, ncol do widths[c] = widths[c] or 0 end
  -- a cell wider than the columns it spans widens the last of them
  for _, sp in ipairs(wspans) do
    local col, span, w = sp[1], sp[2], sp[3]
    local have = 2 * (span - 1)
    for c = col, col + span - 1 do have = have + widths[c] end
    if w > have then widths[col + span - 1] = widths[col + span - 1] + (w - have) end
  end

  return { rows = rows, wid = wid, spans = spans, n = n, ncol = ncol, header = header,
           left_upto = levels >= 2 and last_header or 0, widths = widths, caption = caption,
           caption_last = caption_last }
end

-- Rows of cell strings for the first table (every row as long as the widest, a
-- spanned or covered cell ""; none for a table with no text), the header flags
-- of the rows and the caption, or nil when there is no table.
function M.rows(html)
  local t = read(html)
  if not t then return nil end
  for _, row in ipairs(t.rows) do
    for c = #row + 1, t.ncol do row[c] = "" end
  end
  return t.rows, t.header, t.caption
end

-- Aligned text for the first table in `html` ("" for a table with no text), or
-- nil when there is none.
function M.to_text(html)
  local t = read(html)
  if not t then return nil end
  local rows, wid, spans, widths = t.rows, t.wid, t.spans, t.widths
  local out, parts = {}, {}
  local left_upto = t.left_upto
  for r = 1, t.n do
    local row, rwid, rspan = rows[r], wid[r], spans[r]
    local left = t.header[r] and r < left_upto
    local last = #row
    while last > 1 and row[last] == "" do last = last - 1 end
    local np, c = 0, 1
    while c <= last do
      local w, span = widths[c], rspan and rspan[c] or 1
      if span > 1 then
        w = w + 2 * (span - 1)
        for k = c + 1, c + span - 1 do w = w + widths[k] end
      end
      local pad = w - rwid[c]
      if c > 1 then np = np + 1; parts[np] = "  " end
      if left then
        np = np + 1; parts[np] = row[c]
        if c + span <= last then np = np + 1; parts[np] = SP[pad] end
      else
        np = np + 1; parts[np] = SP[pad]
        np = np + 1; parts[np] = row[c]
      end
      c = c + span
    end
    out[r] = concat(parts, "", 1, np)
  end
  if t.caption then
    local total = 2 * (t.ncol - 1)
    for c = 1, t.ncol do total = total + widths[c] end
    local pad = math.floor((total - strwidth(t.caption)) / 2)
    local line = (pad > 0 and SP[pad] or "") .. t.caption
    if t.caption_last then out[#out + 1] = line else table.insert(out, 1, line) end
  end
  return concat(out, "\n")
end

return M

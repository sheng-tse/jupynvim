-- An output whose text/plain is a bare repr but which carries an HTML table
-- (a pandas Styler) shows the table as aligned text.
-- This spec needs only Neovim; no backend or Python kernel is required.
--
-- Layout (VS Code's DataFrame output): every cell right-aligned; with two or
-- more levels of columns (a MultiIndex), the header rows above the last one
-- left-aligned (a row of index names is not a level); columns two spaces apart;
-- a caption centered on a line of its own, under the table for caption-side:
-- bottom. The timing checks run with 3x headroom;
-- JNV_PERF_STRICT=1 asserts the budgets themselves (1,000 x 10 in 10 ms,
-- 262,144 cells in 250 ms) and the medians print either way.
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local NB = require("jupynvim.notebook")
local HtmlTable = require("jupynvim.notebook.html_table")
local fails = 0
local function chk(name, ok, detail)
  if ok then io.write("  ok " .. name .. "\n")
  else
    io.write("FAIL " .. name .. (detail and (" -- " .. detail) or "") .. "\n")
    fails = fails + 1
  end
end

local function read_json(path)
  local f = assert(io.open(path, "r"))
  local s = f:read("*a")
  f:close()
  return vim.json.decode(s)
end

local function lines_for(data)
  local buf = vim.api.nvim_create_buf(false, true)
  local nb = NB.create(buf, "test.ipynb", "s", { cells = {
    { id = "c1", cell_type = "code", source = "x", outputs = {} },
  } })
  nb:apply_cell_event("c1", { kind = "execute_input", execution_count = 1 })
  nb:apply_cell_event("c1", { kind = "execute_result", execution_count = 1, data = data })
  return table.concat(NB.output_lines(nb.cells[1]), "\n"), nb
end

local function indent(text)
  return "  " .. text:gsub("\n", "\n  ")
end

-- What pandas 3 emits for df.style.format({"baris": "{:,}", "porsi": "{:.1%}"}).to_html()
local STYLER_HTML = [[
<style type="text/css">
</style>
<table id="T_77e94">
  <thead>
    <tr>
      <th class="blank level0" >&nbsp;</th>
      <th id="T_77e94_level0_col0" class="col_heading level0 col0" >baris</th>
      <th id="T_77e94_level0_col1" class="col_heading level0 col1" >porsi</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <th id="T_77e94_level0_row0" class="row_heading level0 row0" >12 SKU DUS</th>
      <td id="T_77e94_row0_col0" class="data row0 col0" >5,674</td>
      <td id="T_77e94_row0_col1" class="data row0 col1" >33.0%</td>
    </tr>
    <tr>
      <th id="T_77e94_level0_row1" class="row_heading level0 row1" >di luar &lt;scope&gt;</th>
      <td id="T_77e94_row1_col0" class="data row1 col0" >11,498</td>
      <td id="T_77e94_row1_col1" class="data row1 col1" >67.0%</td>
    </tr>
  </tbody>
</table>
]]

-- Every cell is right-aligned, the label column too (the contributor's first
-- version left-aligned the text column).
local WANT = table.concat({
  "                  baris  porsi",
  "     12 SKU DUS   5,674  33.0%",
  "di luar <scope>  11,498  67.0%",
}, "\n")

local REPR = "<pandas.io.formats.style.Styler at 0x11ef75eb0>"

-- ── contributor cases (H10), the alignment changes noted ──────────────────────
chk("H10 styler table to text", HtmlTable.to_text(STYLER_HTML) == WANT, "\n" .. tostring(HtmlTable.to_text(STYLER_HTML)))
chk("H10 no table gives nil", HtmlTable.to_text("<p>hi</p>") == nil)
-- changed from "a     b": a colspan cell is a cell like any other, so in a row
-- of its own it is right-aligned across the columns it spans
local COLSPAN_HTML = "<table><tr><th colspan=2>a</th><th>b</th></tr><tr><td>1</td><td>2</td><td>3</td></tr></table>"
chk("H10 colspan keeps columns aligned", HtmlTable.to_text(COLSPAN_HTML) == "   a  b\n1  2  3",
  tostring(HtmlTable.to_text(COLSPAN_HTML)))
chk("H10 styler repr replaced by its table",
  lines_for({ ["text/plain"] = REPR, ["text/html"] = STYLER_HTML }) == indent(WANT),
  lines_for({ ["text/plain"] = REPR, ["text/html"] = STYLER_HTML }))
chk("H10 useful text/plain kept over html", lines_for({
  ["text/plain"] = "   a\n0  1",
  ["text/html"] = "<table><tr><td>other</td></tr></table>",
}) == "     a\n  0  1")
chk("H10 bare repr without a table kept", lines_for({
  ["text/plain"] = "<foo.Bar at 0xabc>",
  ["text/html"] = "<b>no table</b>",
}) == "  <foo.Bar at 0xabc>")
chk("H10 empty text/plain shows the table", lines_for({
  ["text/plain"] = "",
  ["text/html"] = "<table><tr><td>7</td></tr></table>",
}) == "  7")
chk("H10 pandas 3 object repr replaced by its table", lines_for({
  ["text/plain"] = "<pandas.io.formats.style.Styler object at 0x109022a50>",
  ["text/html"] = "<table><tr><td>7</td></tr></table>",
}) == "  7")

-- ── H2: the sty_format fixture (pandas 3.0.0), text and through the output ────
local fx_fmt = read_json("tests/fixtures/styler_sty_format.json")
local GOLD_FMT = table.concat({
  "       a           b     c",
  "w   1.23   $1,000.00   12%",
  "x  -2.50  $25,000.50   50%",
  "y   3.14       $3.00   88%",
  "z    n/a      $47.25  100%",
}, "\n")
chk("H2 sty_format fixture to_text", HtmlTable.to_text(fx_fmt.data["text/html"]) == GOLD_FMT,
  "\n" .. tostring(HtmlTable.to_text(fx_fmt.data["text/html"])))
chk("H2 sty_format fixture through output_lines",
  lines_for(fx_fmt.data) == indent(GOLD_FMT) and not lines_for(fx_fmt.data):find("Styler", 1, true),
  "\n" .. lines_for(fx_fmt.data))

-- ── H3: MultiIndex, rowspan carried, spans in the header ──────────────────────
local fx_mi = read_json("tests/fixtures/styler_multiindex.json")
local GOLD_MI = table.concat({
  "      v",                -- upper column level: left-aligned over p and q
  "        p    q",         -- last header row: right-aligned
  "a  x  1.0  2.5",
  "   y  3.2  4.0",         -- the "a" label spans two rows: its column is empty here
  "b  x  5.5  6.8",
}, "\n")
chk("H3 MultiIndex fixture: values under their own column, header levels aligned",
  HtmlTable.to_text(fx_mi.data["text/html"]) == GOLD_MI, "\n" .. tostring(HtmlTable.to_text(fx_mi.data["text/html"])))
chk("H3 MultiIndex fixture through output_lines", lines_for(fx_mi.data) == indent(GOLD_MI), "\n" .. lines_for(fx_mi.data))
do
  local rows, header = HtmlTable.rows(fx_mi.data["text/html"])
  chk("H3 rows: rowspan label covers the next row's first column",
    rows and rows[4][1] == "" and rows[4][2] == "y" and rows[3][1] == "a" and rows[5][1] == "b"
      and header and header[1] and header[2] and not header[3])
end
-- a wide upper header widens the last column it spans, not the first
do
  local html = "<table><thead><tr><th colspan=2>Population</th></tr><tr><th>a</th><th>b</th></tr></thead>"
    .. "<tbody><tr><td>1</td><td>2</td></tr></tbody></table>"
  chk("H3 a spanning header wider than its columns widens the last one",
    HtmlTable.to_text(html) == "Population\na        b\n1        2", "\n" .. tostring(HtmlTable.to_text(html)))
end

-- ── H4: the caption ───────────────────────────────────────────────────────────
local fx_cap = read_json("tests/fixtures/styler_caption.json")
do
  local got = HtmlTable.to_text(fx_cap.data["text/html"])
  local want = {
    string.rep(" ", 9) .. "Quarterly numbers",
    "           a             b         c",
    "w   1.234560   1000.000000  0.120000",
    "x  -2.500000  25000.500000  0.500000",
    "y   3.141590      3.000000  0.875000",
    "z        nan     47.250000  1.000000",
  }
  chk("H4 the caption is the first line, centered over the table width",
    got and got:match("^[^\n]*") == want[1], tostring(got and got:match("^[^\n]*")))
  chk("H4 the table follows the caption", got == table.concat(want, "\n"), "\n" .. tostring(got))
  -- the table is 36 columns wide and the caption 17: 9 columns on each side
  chk("H4 the caption sits in the middle of the table", vim.fn.strdisplaywidth(want[3]) == 36)
  chk("H4 the caption fixture through output_lines", lines_for(fx_cap.data) == indent(table.concat(want, "\n")))
end
chk("H4 a caption wider than the table is not padded and not cut",
  HtmlTable.to_text("<table><caption>A very long caption here</caption><tr><td>1</td></tr></table>")
    == "A very long caption here\n1")
chk("H4 a caption after the rows is not the caption",
  HtmlTable.to_text("<table><tr><td>1</td></tr><caption>late</caption></table>") == "1")

-- ── H5: spans are capped and a hostile table stays bounded ────────────────────
do
  local t0 = vim.uv.hrtime()
  local rows = HtmlTable.rows('<table><tr><td colspan="999999999">x</td><td>y</td></tr></table>')
  local ms = (vim.uv.hrtime() - t0) / 1e6
  chk("H5 colspan 999999999 is capped at 1000", rows and #rows[1] == 1001 and rows[1][1] == "x" and rows[1][1001] == "y",
    rows and tostring(#rows[1]) or "nil")
  chk("H5 colspan 999999999 returns quickly", ms < 200, string.format("%.1f ms", ms))
end
do
  local t = { "<table>" }
  for i = 1, 1005 do
    t[#t + 1] = (i == 1) and '<tr><td rowspan="999999999">a</td><td>r1</td></tr>' or ("<tr><td>r" .. i .. "</td></tr>")
  end
  t[#t + 1] = "</table>"
  local t0 = vim.uv.hrtime()
  local rows = HtmlTable.rows(table.concat(t))
  local ms = (vim.uv.hrtime() - t0) / 1e6
  chk("H5 rowspan 999999999 is capped at 1000 rows",
    rows and #rows == 1005 and rows[2][1] == "" and rows[2][2] == "r2" and rows[1000][1] == "" and rows[1000][2] == "r1000"
      and rows[1001][1] == "r1001",
    rows and (tostring(rows[1000][1]) .. "|" .. tostring(rows[1001][1])) or "nil")
  chk("H5 rowspan 999999999 returns quickly", ms < 200, string.format("%.1f ms", ms))
end
do
  -- 20,000 cells that each span 1,000 columns and 1,000 rows: a table that size
  -- would need 4e10 cells. The cell budget stops the read.
  local t = { "<table>" }
  for _ = 1, 20000 do t[#t + 1] = '<tr><td colspan="1000" rowspan="1000">x</td><td>y</td></tr>' end
  t[#t + 1] = "</table>"
  local html = table.concat(t)
  local t0 = vim.uv.hrtime()
  local text = HtmlTable.to_text(html)
  local ms = (vim.uv.hrtime() - t0) / 1e6
  chk("H5 a table of huge spans is read within the cell budget", text ~= nil and ms < 3000, string.format("%.1f ms", ms))
  -- 3,000 cells with a thousand columns each, then rows that each walk the covers
  t = { "<table><tr>" }
  for _ = 1, 3000 do t[#t + 1] = '<td colspan="1000" rowspan="1000">x</td>' end
  t[#t + 1] = "</tr>"
  for _ = 1, 1500 do t[#t + 1] = "<tr><td>z</td></tr>" end
  t[#t + 1] = "</table>"
  html = table.concat(t)
  t0 = vim.uv.hrtime()
  text = HtmlTable.to_text(html)
  ms = (vim.uv.hrtime() - t0) / 1e6
  chk("H5 many running rowspans cost a bounded walk", text ~= nil and ms < 3000, string.format("%.1f ms", ms))
end
do
  -- searches that never match are made once, not once per row
  local t = { "<table>" }
  for i = 1, 20000 do t[#t + 1] = "<tr><td>" .. i .. "<td>b" end
  t[#t + 1] = "</table>"
  local html = table.concat(t)
  local t0 = vim.uv.hrtime()
  local rows = HtmlTable.rows(html)
  local ms = (vim.uv.hrtime() - t0) / 1e6
  chk("H5 rows and cells with no closing tag are read in linear time",
    rows and #rows == 20000 and rows[20000][1] == "20000" and rows[20000][2] == "b" and ms < 1000,
    string.format("%.1f ms", ms))
end

-- ── H6: upper case tags, <br>, nested inline tags, entities ───────────────────
do
  local html = "<TABLE><THEAD><TR><TH>Name</TH><TH>Note</TH></TR></THEAD>"
    .. "<TBODY><TR><TD><B>Ann</B> <I>Lee</I></TD><TD>a&amp;b<BR>c&nbsp;d &#x41;&#66;&lt;&gt;&bogus;</TD></TR></TBODY></TABLE>"
  local want = "   Name" .. string.rep(" ", 17) .. "Note\nAnn Lee  a&b c d AB<>&bogus;"
  chk("H6 upper case tags, <br>, inline tags and entities", HtmlTable.to_text(html) == want, "\n" .. tostring(HtmlTable.to_text(html)))
end
chk("H6 entities decode once", HtmlTable.to_text("<table><tr><td>&amp;lt; &#38;lt;</td></tr></table>") == "&lt; &lt;",
  tostring(HtmlTable.to_text("<table><tr><td>&amp;lt; &#38;lt;</td></tr></table>")))
chk("H6 a <br> with attributes is a space",
  HtmlTable.to_text('<table><tr><td>a<br class="x">b<br/>c<br />d</td></tr></table>') == "a b c d",
  tostring(HtmlTable.to_text('<table><tr><td>a<br class="x">b<br/>c<br />d</td></tr></table>')))
chk("H6 attribute names and quotes in any form",
  HtmlTable.to_text("<table><tr><TH COLSPAN = '2'>ab</TH></tr><tr><td>1</td><td>2</td></tr></table>") == "  ab\n1  2",
  tostring(HtmlTable.to_text("<table><tr><TH COLSPAN = '2'>ab</TH></tr><tr><td>1</td><td>2</td></tr></table>")))
chk("H6 empty rows are dropped",
  HtmlTable.to_text("<table><tr><td>1</td></tr><tr><td> </td><td>&nbsp;</td></tr><tr><td>2</td></tr></table>") == "1\n2")
chk("H6 tags <tbody>, <track> and <tdx> are not rows or cells",
  HtmlTable.to_text("<table><tbody><track><tr><tdx>no</tdx><td>1</td></tr></tbody></table>") == "1",
  tostring(HtmlTable.to_text("<table><tbody><track><tr><tdx>no</tdx><td>1</td></tr></tbody></table>")))
chk("H6 end tags may be missing",
  HtmlTable.to_text("<table><tr><td>a<td>b<tr><td>c<td>d</table>") == "a  b\nc  d",
  tostring(HtmlTable.to_text("<table><tr><td>a<td>b<tr><td>c<td>d</table>")))
chk("H6 only the first table is read",
  HtmlTable.to_text("<table><tr><td>1</td></tr></table><table><tr><td>2</td></tr></table>") == "1")
chk("H6 a table that holds a table is left alone (nil)",
  HtmlTable.to_text("<table><tr><td><table><tr><td>in</td></tr></table></td></tr></table>") == nil)
chk("H6 text/html given as a list of lines",
  lines_for({ ["text/plain"] = REPR, ["text/html"] = { "<table>\n", "<tr><td>1</td>", "<td>2</td></tr>\n", "</table>" } })
    == "  1  2")
chk("H6 a number or nil html gives nil", HtmlTable.to_text(nil) == nil and HtmlTable.to_text(5) == nil)
-- changed in attempt 2 (was nil): a table with no text is an empty text, so the
-- bare repr does not show in its place (H17)
chk("H6 a table with no cells gives an empty text", HtmlTable.to_text("<table></table>") == ""
  and HtmlTable.to_text("<table><tr></tr></table>") == "")

-- ── H7: display width ─────────────────────────────────────────────────────────
do
  local html = "<table><tr><td>日本語</td><td>1</td></tr><tr><td>e&#769;</td><td>22</td></tr>"
    .. "<tr><td>ab</td><td>333</td></tr><tr><td>😀</td><td>4</td></tr></table>"
  local got = HtmlTable.to_text(html)
  local want = table.concat({
    "日本語    1",
    "     e\204\129   22",
    "    ab  333",
    "    😀    4",
  }, "\n")
  chk("H7 CJK, combining marks and emoji align by display width", got == want, "\n" .. tostring(got))
  local widths = {}
  for line in (got or ""):gmatch("[^\n]+") do widths[#widths + 1] = vim.fn.strdisplaywidth(line) end
  chk("H7 every line is as wide as the table", #widths == 4 and widths[1] == 11 and widths[2] == 11
    and widths[3] == 11 and widths[4] == 11, vim.inspect(widths))
end

-- ── H8: one conversion per output data table (B45-3) ──────────────────────────
do
  local calls, real = 0, HtmlTable.to_text
  HtmlTable.to_text = function(...)
    calls = calls + 1
    return real(...)
  end
  local c0 = HtmlTable.conversions or 0
  local d1 = { ["text/plain"] = REPR, ["text/html"] = STYLER_HTML }
  local text, nb = lines_for(d1)
  local cell = nb.cells[1]
  local o1 = cell.outputs[1]
  -- a render again, the cursor moving, a rebuild of the lines and the widget's
  -- text all ask for the same output
  NB.output_lines(cell)
  cell._output_expanded = true
  NB.output_lines(cell)
  cell._output_expanded = nil
  local t1 = NB._result_text(o1)
  local t2 = NB._result_text(o1)
  local more = NB._more_after({ { output_type = "stream", text = "a" }, o1 }, 1)
  chk("H8 one conversion for repeated renders, _result_text and _more_after on one output",
    calls == 1 and (HtmlTable.conversions or 0) - c0 == 1 and t1 == WANT and t2 == WANT and more == true,
    string.format("to_text calls %d, conversions %s", calls, tostring((HtmlTable.conversions or 0) - c0)))
  -- a new data table is a new conversion
  nb:apply_cell_event("c1", { kind = "execute_result", execution_count = 2,
    data = { ["text/plain"] = REPR, ["text/html"] = fx_fmt.data["text/html"] } })
  NB.output_lines(cell)
  NB.output_lines(cell)
  chk("H8 a new data table is one more conversion",
    calls == 2 and (HtmlTable.conversions or 0) - c0 == 2,
    string.format("to_text calls %d, conversions %s", calls, tostring((HtmlTable.conversions or 0) - c0)))
  -- the same data table with its HTML changed in place is read again
  local o2 = cell.outputs[2]
  o2.data["text/html"] = "<table><tr><td>changed</td></tr></table>"
  chk("H8 the HTML of a data table changed in place is read again",
    NB._result_text(o2) == "changed" and calls == 3, tostring(calls))
  -- a data table with no table is remembered as well
  local d3 = { ["text/plain"] = REPR, ["text/html"] = "<b>no table</b>" }
  local o3 = { output_type = "execute_result", data = d3 }
  NB._result_text(o3)
  NB._result_text(o3)
  NB._result_text(o3)
  chk("H8 an output without a table is read once too", calls == 4, tostring(calls))
  HtmlTable.to_text = real
end

-- ── H11: the output cache notices a changed HTML of the same text/plain ───────
do
  local text, nb = lines_for({ ["text/plain"] = REPR, ["text/html"] = "<table><tr><td>1</td></tr></table>" })
  local cell = nb.cells[1]
  local before = table.concat(NB.output_lines(cell), "\n")
  -- the same output object, same text/plain, HTML of another length
  cell.outputs[1].data = { ["text/plain"] = REPR, ["text/html"] = "<table><tr><td>12345</td></tr></table>" }
  local after = table.concat(NB.output_lines(cell), "\n")
  chk("H11 a longer HTML with the same text/plain is shown", before == "  1" and after == "  12345",
    before .. " | " .. after)
end

-- ── H12: a single level of columns stays right-aligned with a named index ────
-- pandas writes the index name as a header row of its own under the column
-- labels; it is not a level of the columns, so the labels stay right-aligned
-- (VS Code, vscode_pd_named_dark; pandas' CSS left-aligns only MultiIndex
-- columns).
do
  local fx = read_json("tests/fixtures/styler_groupby.json")
  local gold = table.concat({
    "            sales   units",
    "region",
    "  east   2,070.50   20.00",
    " north      15.75    1.00",
    "  west  33,000.25  330.00",
  }, "\n")
  local got = HtmlTable.to_text(fx.data["text/html"])
  chk("H12 groupby (named index): column labels right-aligned, to_text", got == gold, "\n" .. tostring(got))
  chk("H12 groupby (named index): through output_lines", lines_for(fx.data) == indent(gold), "\n" .. lines_for(fx.data))
end
do
  local fx = read_json("tests/fixtures/styler_named_both.json")
  local gold = table.concat({
    "metric     sales  units",
    "region",
    "  east   2,070.5   20.0",
    "  west  33,000.2  330.0",
  }, "\n")
  local got = HtmlTable.to_text(fx.data["text/html"])
  chk("H12 pivot_table (index and columns named): labels right-aligned, to_text", got == gold, "\n" .. tostring(got))
  chk("H12 pivot_table (index and columns named): through output_lines", lines_for(fx.data) == indent(gold),
    "\n" .. lines_for(fx.data))
end
do
  -- two levels of columns and named index levels: the levels above the row of
  -- index names are left-aligned, as pandas' CSS for MultiIndex columns does
  -- (vscode_pd_mi_both_dark); the row of index names is right-aligned
  local fx = read_json("tests/fixtures/styler_mi_both.json")
  local gold = table.concat({
    "        kind     sales   cost",
    "        quarter  Q1  Q2  Q1  Q2",
    "letter   number",
    "     A      one  50  60  97  72",
    "            two  63  54  55  93",
    "     B      one  27  81  67   0",
    "            two  39  85  55   3",
  }, "\n")
  local got = HtmlTable.to_text(fx.data["text/html"])
  chk("H12 MultiIndex rows and columns, every level named: upper levels left", got == gold, "\n" .. tostring(got))
end
do
  -- the levels are counted past the index columns of the first body row; a
  -- table with a hidden index has none
  local html = "<table><thead><tr><th>long label</th><th>b</th></tr><tr><th>x</th><th>y</th></tr></thead>"
    .. "<tbody><tr><td>1</td><td>2</td></tr></tbody></table>"
  chk("H12 two label rows and no index: the upper one left-aligned",
    HtmlTable.to_text(html) == "long label  b\n         x  y\n         1  2", "\n" .. tostring(HtmlTable.to_text(html)))
end

-- ── H13: a "<" that does not start a tag is text ──────────────────────────────
-- Styler's default (escape=None) writes a string as it is. A tag opens only at
-- "<" and a letter, "/", "!" or "?".
do
  local fx = read_json("tests/fixtures/styler_lt_text.json")
  local gold = table.concat({
    "                rule  n",
    "0    x < 5 or x > 10  1",
    "1            a <-> b  2",
    "2             a <> b  3",
    "3  x <= 5 and y >= 3  4",
    "4         <18 or >65  5",
    "5               bold  6",
  }, "\n")
  local got = HtmlTable.to_text(fx.data["text/html"])
  chk("H13 strings with '<' read as written, to_text", got == gold, "\n" .. tostring(got))
  chk("H13 strings with '<' read as written, through output_lines", lines_for(fx.data) == indent(gold),
    "\n" .. lines_for(fx.data))
end
do
  local cases = {
    { "x < 5 or x > 10", "x < 5 or x > 10" },
    { "a <-> b", "a <-> b" },
    { "a <> b", "a <> b" },
    { "x <= 5 and y >= 3", "x <= 5 and y >= 3" },
    { "<18 or >65", "<18 or >65" },
    { "1<2>0", "1<2>0" },
    { "<b>b</b> <I>i</I> <x-y>c</x-y> <!-- note --><?pi?>d<br/>e", "b i c d e" },
  }
  for _, c in ipairs(cases) do
    local got = HtmlTable.to_text("<table><tr><td>" .. c[1] .. "</td></tr></table>")
    chk("H13 cell " .. c[1], got == c[2], tostring(got))
  end
end

-- ── H14: entity names are case sensitive ──────────────────────────────────────
do
  local got = HtmlTable.to_text("<table><tr><td>&Amp; &NBSP; &Lt; &AMP; &LT; &GT; &QUOT; &COPY; &REG;</td></tr></table>")
  chk("H14 a mixed case name is text, the legacy upper case names decode",
    got == '&Amp; &NBSP; &Lt; & < > " \194\169 \194\174', tostring(got))
end

-- ── H15: no-break spaces are not folded ───────────────────────────────────────
do
  local got = HtmlTable.to_text("<table><tr><td>a&nbsp;&nbsp;&nbsp;b</td><td>c&#160;&#xA0;d</td>"
    .. "<td>e\194\160\194\160f</td></tr></table>")
  chk("H15 a run of no-break spaces shows as written", got == "a   b  c  d  e  f", tostring(got))
  got = HtmlTable.to_text("<table><tr><td>a \n &nbsp; \t b</td></tr></table>")
  chk("H15 white space around a no-break space folds, the no-break space stays", got == "a   b", tostring(got))
  got = HtmlTable.to_text("<table><tr><td>1</td></tr><tr><td>&nbsp;&nbsp;</td><td> &#160; </td></tr><tr><td>2</td></tr></table>")
  chk("H15 a cell of only no-break spaces is empty (its row is dropped)", got == "1\n2", tostring(got))
end

-- ── H16: caption-side: bottom puts the caption under the table ────────────────
do
  local fx = read_json("tests/fixtures/styler_caption_bottom.json")
  local want = table.concat({
    "           a             b         c",
    "w   1.234560   1000.000000  0.120000",
    "x  -2.500000  25000.500000  0.500000",
    "y   3.141590      3.000000  0.875000",
    "z        nan     47.250000  1.000000",
    string.rep(" ", 9) .. "Quarterly numbers",
  }, "\n")
  local got = HtmlTable.to_text(fx.data["text/html"])
  chk("H16 set_table_styles caption-side: bottom, the caption is the last line", got == want, "\n" .. tostring(got))
  chk("H16 through output_lines", lines_for(fx.data) == indent(want), "\n" .. lines_for(fx.data))
  local t = "<table style='caption-side:bottom'><caption>cap</caption><tr><td>12345</td></tr></table>"
  chk("H16 a style attribute on the table", HtmlTable.to_text(t) == "12345\n cap", tostring(HtmlTable.to_text(t)))
  t = "<style>caption { caption-side: bottom }</style><table><caption style=\"caption-side: top\">cap</caption>"
    .. "<tr><td>12345</td></tr></table>"
  chk("H16 the caption's own style beats a rule for it", HtmlTable.to_text(t) == " cap\n12345", tostring(HtmlTable.to_text(t)))
end

-- ── H18: a ">" inside a quoted attribute value does not end the tag ───────────
-- pandas' set_tooltips(as_title_attribute=True) writes the tooltip into the
-- cell's start tag as it is (pandas 3.0.0 fixture): a ">" there, and a '"' that
-- ends the value early, are read as a browser's tokenizer reads them.
do
  local fx = read_json("tests/fixtures/styler_tooltips_title.json")
  local rows = HtmlTable.rows(fx.data["text/html"])
  local flat = rows and vim.inspect(rows) or "nil"
  chk("H18 tooltip titles: every value under its column",
    rows and #rows == 4 and rows[2][2] == "0.91" and rows[2][3] == "pass" and rows[3][2] == "0.42"
      and rows[4][2] == "0.77" and rows[4][3] == "pass", flat)
  chk("H18 no attribute text shows in a cell", not flat:find("title", 1, true) and not flat:find("0.9: top", 1, true)
    and not flat:find("0.8", 1, true), flat)
  -- title="flag "low" > review": the value ends at the second quote, low" is
  -- an attribute name and the tag ends at the ">" after it, so a browser
  -- shows the rest, ' review">fail', as the cell's text
  chk("H18 a quote that ends the title early leaves what a browser shows", rows and rows[3][3] == 'review">fail', flat)
  local want = table.concat({
    "   score         label",
    "a   0.91          pass",
    'b   0.42  review">fail',
    "c   0.77          pass",
  }, "\n")
  chk("H18 tooltip titles fixture through output_lines", lines_for(fx.data) == indent(want), "\n" .. lines_for(fx.data))
end
do
  local function cells(tags)
    local r = HtmlTable.rows("<table><tr>" .. tags .. "</tr></table>")
    return r and table.concat(r[1] or {}, "|") or "nil"
  end
  -- start tags read by the tokenizer's rules: single quotes, unquoted values,
  -- white space around "=", a quote in a name or in an unquoted value, an
  -- attribute name that starts with "="
  for _, case in ipairs({
    { "<td title='a>b'>1</td><td>2</td>", "1|2" },
    { "<td title = \"a>b\" >1</td>", "1" },
    { "<td colspan=1 title=\"a>b\">1</td>", "1" },
    { "<td a=b=\"x>y\">1</td>", 'y">1' },
    { "<td a = b=\"x>y\">1</td>", 'y">1' },
    { "<td =\"x>y\">1</td>", 'y">1' },
    { "<td a\"=\"x>y\">1</td>", "1" },
    { "<td/title=\"a>b\">1</td>", "1" },
    { "<td title=\"a>b\"class=\"c>d\">1</td>", "1" },
    { "<td title=\"a>b\" =x>1</td>", "1" },
    { "<td title=>1</td>", "1" },
  }) do
    local got = cells(case[1])
    chk("H18 the tag " .. case[1] .. " ends where a browser ends it", got == case[2], got)
  end
  chk("H18 a quote that never closes runs to the end, as in a browser",
    cells("<td title=\"a>1</td><td>2</td>") == "", cells("<td title=\"a>1</td><td>2</td>"))
  local got = HtmlTable.to_text('<table><tr><td title="a>b">1</td></tr><tr><td title="c">2</td></tr></table>')
  chk("H18 the next rows read as before", got == "1\n2", tostring(got))
  got = HtmlTable.to_text('<table><caption title="x>y">Cap</caption><tr><td>12345</td></tr></table>')
  chk("H18 a caption's title", got == " Cap\n12345", tostring(got))
  got = HtmlTable.to_text('<table><tr title="r>s"><td>1</td></tr></table>')
  chk("H18 a row's title", got == "1", tostring(got))
  -- inside a cell: a formatter's markup and a comment
  got = HtmlTable.to_text('<table><tr><td><span title="a>b">v</span> <!-- x > y --> w<br title="c>d">z</td></tr></table>')
  chk("H18 a quoted \">\" in an inner tag, a comment and a <br> with a title", got == "v w z", tostring(got))
  got = HtmlTable.to_text("<table><tr><td>it's <b>bold</b> <!-- open</td></tr></table>")
  chk("H18 an unclosed comment hides the rest, an apostrophe in text is text", got == "it's bold", tostring(got))
end

-- ── H19: caption-side follows the cascade ─────────────────────────────────────
-- caption-side is inherited: what the caption declares itself (its style
-- attribute, a rule that picks it) beats what it inherits from the table.
do
  local fx = read_json("tests/fixtures/styler_caption_rule.json")
  local got = HtmlTable.to_text(fx.data["text/html"])
  chk("H19 a caption rule beats the table's style attribute (pandas 3.0.0 fixture)",
    got and vim.split(got, "\n")[1]:find("Totals", 1, true) ~= nil, "\n" .. tostring(got))
  local function side(html)
    local t = HtmlTable.to_text(html)
    if not t then return "nil" end
    return vim.split(t, "\n")[1]:find("cap", 1, true) and "top" or "bottom"
  end
  local body = "<caption>cap</caption><tr><td>12345</td></tr></table>"
  for _, case in ipairs({
    { "<style>#t caption { caption-side: top }</style><table id=t style='caption-side: bottom'>" .. body, "top" },
    { "<style>caption{caption-side:bottom}</style><table style='caption-side: top'>" .. body, "bottom" },
    { "<style>table > caption.c, td { caption-side: bottom }</style><table style='caption-side: top'>"
      .. "<caption class='b c'>cap</caption><tr><td>12345</td></tr></table>", "bottom" },
    { "<style>caption.x, caption#y { caption-side: bottom }</style><table style='caption-side: top'>" .. body, "top" },
    { "<style>caption#y { caption-side: bottom }</style><table style='caption-side: top'><caption id=y>cap</caption>"
      .. "<tr><td>12345</td></tr></table>", "bottom" },
    { "<style>@media screen { caption { caption-side: bottom } }</style><table style='caption-side: top'>" .. body, "bottom" },
    { "<style>/* caption { caption-side: top } */ #t { caption-side: bottom }</style><table id=t>" .. body, "bottom" },
    { "<style>caption { caption-side: bottom } captions, .caption { caption-side: top }</style><table>" .. body, "bottom" },
    { "<style>caption { caption-side: bottom }</style><table><caption style='color: red'>cap</caption>"
      .. "<tr><td>12345</td></tr></table>", "bottom" },
    { "<table style='caption-side: bottom'><caption title='caption-side: top'>cap</caption><tr><td>12345</td></tr></table>",
      "bottom" },
  }) do
    chk("H19 " .. case[1]:sub(1, 70), side(case[1]) == case[2], side(case[1]))
  end
end

-- ── H17: a table with no text is an empty output, not the repr ────────────────
do
  local fx = read_json("tests/fixtures/styler_empty.json")
  chk("H17 pd.DataFrame().style is an empty text", HtmlTable.to_text(fx.data["text/html"]) == "",
    tostring(HtmlTable.to_text(fx.data["text/html"])))
  local text = lines_for(fx.data)
  chk("H17 pd.DataFrame().style shows no repr", text == "", text)
  chk("H17 a table with only a caption shows the caption",
    HtmlTable.to_text("<table><caption>Nothing yet</caption><thead></thead></table>") == "Nothing yet",
    tostring(HtmlTable.to_text("<table><caption>Nothing yet</caption><thead></thead></table>")))
  local rows = HtmlTable.rows(fx.data["text/html"])
  chk("H17 rows of an empty table is an empty list", type(rows) == "table" and #rows == 0)
end

-- ── H9: timing on pandas-like HTML ────────────────────────────────────────────
local strict = (vim.env.JNV_PERF_STRICT or "") ~= ""
-- What a Styler of floats writes (pandas 3.0.0): a five character table id
-- and the default %.6f, so the sizes are those the budgets name.
local function styler_html(nrows, ncols)
  local t = { '<style type="text/css">\n</style>\n<table id="T_d5e8d">\n  <thead>\n    <tr>\n'
    .. '      <th class="blank level0" >&nbsp;</th>\n' }
  for c = 0, ncols - 1 do
    t[#t + 1] = string.format('      <th id="T_d5e8d_level0_col%d" class="col_heading level0 col%d" >c%d</th>\n', c, c, c)
  end
  t[#t + 1] = "    </tr>\n  </thead>\n  <tbody>\n"
  for r = 0, nrows - 1 do
    t[#t + 1] = string.format('    <tr>\n      <th id="T_d5e8d_level0_row%d" class="row_heading level0 row%d" >%d</th>\n',
      r, r, r)
    for c = 0, ncols - 1 do
      t[#t + 1] = string.format('      <td id="T_d5e8d_row%d_col%d" class="data row%d col%d" >%.6f</td>\n', r, c, r, c,
        ((r * 31 + c * 17) % 100000) / 100 - 300)
    end
    t[#t + 1] = "    </tr>\n"
  end
  t[#t + 1] = "  </tbody>\n</table>\n"
  return table.concat(t)
end
local function median_ms(html, runs)
  local ms = {}
  local text
  for i = 1, runs do
    local t0 = vim.uv.hrtime()
    text = HtmlTable.to_text(html)
    ms[i] = (vim.uv.hrtime() - t0) / 1e6
  end
  table.sort(ms)
  return ms[math.ceil(#ms / 2)], text
end
do
  local html = styler_html(1000, 10)
  median_ms(html, 2) -- warm
  local med, text = median_ms(html, 7)
  local limit = strict and 10 or 30
  io.write(string.format("  H9 1,000 x 10 (%d KB of HTML): median %.2f ms (limit %d ms)\n", math.floor(#html / 1024), med, limit))
  local n = select(2, text:gsub("\n", "\n")) + 1
  chk("H9 1,000 x 10 in budget (B45-1)", n == 1001 and med <= limit, string.format("%d lines, %.2f ms", n, med))
end
do
  local html = styler_html(26214, 10)
  local med, text = median_ms(html, 3)
  local limit = strict and 250 or 750
  io.write(string.format("  H9 26,214 x 10 (%.1f MB of HTML): median %.1f ms (limit %d ms)\n", #html / 1048576, med, limit))
  local n = select(2, text:gsub("\n", "\n")) + 1
  chk("H9 262,144 cells in budget (B45-2)", n == 26215 and med <= limit, string.format("%d lines, %.1f ms", n, med))
end

if fails > 0 then
  io.write(fails .. " HTML-TABLE CHECKS FAILED\n")
  vim.cmd("cquit 1")
else
  io.write("ALL HTML-TABLE CHECKS PASSED\n")
  vim.cmd("qa!")
end

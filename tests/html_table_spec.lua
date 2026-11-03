-- An output whose text/plain is a bare repr but which carries an HTML table
-- (a pandas Styler) shows the table as aligned text.
-- This spec needs only Neovim; no backend or Python kernel is required.
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

local WANT = table.concat({
  "                  baris  porsi",
  "12 SKU DUS        5,674  33.0%",
  "di luar <scope>  11,498  67.0%",
}, "\n")

chk("styler table to text", HtmlTable.to_text(STYLER_HTML) == WANT, "\n" .. tostring(HtmlTable.to_text(STYLER_HTML)))
chk("no table gives nil", HtmlTable.to_text("<p>hi</p>") == nil)
chk("colspan keeps columns aligned",
  HtmlTable.to_text("<table><tr><th colspan=2>a</th><th>b</th></tr><tr><td>1</td><td>2</td><td>3</td></tr></table>")
    == "a     b\n1  2  3", HtmlTable.to_text("<table><tr><th colspan=2>a</th><th>b</th></tr><tr><td>1</td><td>2</td><td>3</td></tr></table>"))

local function lines_for(data)
  local buf = vim.api.nvim_create_buf(false, true)
  local nb = NB.create(buf, "test.ipynb", "s", { cells = {
    { id = "c1", cell_type = "code", source = "x", outputs = {} },
  } })
  nb:apply_cell_event("c1", { kind = "execute_input", execution_count = 1 })
  nb:apply_cell_event("c1", { kind = "execute_result", execution_count = 1, data = data })
  return table.concat(NB.output_lines(nb.cells[1]), "\n")
end

local indented = "  " .. WANT:gsub("\n", "\n  ")
chk("styler repr replaced by its table", lines_for({
  ["text/plain"] = "<pandas.io.formats.style.Styler at 0x11ef75eb0>",
  ["text/html"] = STYLER_HTML,
}) == indented, lines_for({
  ["text/plain"] = "<pandas.io.formats.style.Styler at 0x11ef75eb0>",
  ["text/html"] = STYLER_HTML,
}))
chk("useful text/plain kept over html", lines_for({
  ["text/plain"] = "   a\n0  1",
  ["text/html"] = "<table><tr><td>other</td></tr></table>",
}) == "     a\n  0  1")
chk("bare repr without a table kept", lines_for({
  ["text/plain"] = "<foo.Bar at 0xabc>",
  ["text/html"] = "<b>no table</b>",
}) == "  <foo.Bar at 0xabc>")

if fails > 0 then
  io.write(fails .. " HTML-TABLE CHECKS FAILED\n")
  vim.cmd("cquit 1")
else
  io.write("ALL HTML-TABLE CHECKS PASSED\n")
  vim.cmd("qa!")
end

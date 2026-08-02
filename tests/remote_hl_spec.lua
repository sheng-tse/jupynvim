-- Regression test for the dashboard/explorer highlight migration off the
-- deprecated nvim_buf_add_highlight.
--
-- Both call sites build `{ row, col0, col1, group }` tuples where col1 = -1
-- means "to end of line". nvim_buf_set_extmark rejects end_col = -1, and both
-- calls are pcall-wrapped, so a naive swap loses every to-end-of-line
-- highlight SILENTLY: no error, just uncolored text. That is most of the
-- dashboard (logo, info, footer, keys) and every filename in the explorer.
--
-- The extmark a correct migration produces must be identical to what
-- add_highlight produced: end_row = row + 1, end_col = 0.

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local fails = 0
local function fail(m) io.write("FAIL: " .. m .. "\n"); fails = fails + 1 end
local function ok(m) io.write("  ok " .. m .. "\n") end

local function ns_id(name)
  return vim.api.nvim_get_namespaces()[name]
end

-- Collect { [row] = { {col, end_row, end_col, group}, ... } } for a buffer.
local function marks_by_row(buf, name)
  local id = ns_id(name)
  if not id then return nil end
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, id, 0, -1, { details = true })) do
    local row, col, d = m[2], m[3], m[4]
    out[row] = out[row] or {}
    table.insert(out[row], { col = col, end_row = d.end_row, end_col = d.end_col,
                             group = d.hl_group })
  end
  return out
end

local function find(list, group)
  for _, e in ipairs(list or {}) do if e.group == group then return e end end
  return nil
end

-- ── dashboard ────────────────────────────────────────────────────────────
local RD = require("jupynvim.remote.dashboard")
local dbuf = RD.build("testalias", "/home/me/proj", nil)
local dm = marks_by_row(dbuf, "jupynvim.remote.dashboard")

if not dm then
  fail("dashboard namespace missing entirely")
else
  local groups, eol = {}, 0
  for _, list in pairs(dm) do
    for _, e in ipairs(list) do
      groups[e.group] = (groups[e.group] or 0) + 1
      -- a to-end-of-line highlight is the only way to get end_row > row
      if e.end_row and e.end_col == 0 then eol = eol + 1 end
    end
  end
  -- The logo alone emits one full-line highlight per logo row, plus info,
  -- two footers, and one key per action row.
  for _, g in ipairs({ "JupynvimDashLogo", "JupynvimDashInfo", "JupynvimDashFooter",
                       "JupynvimDashKey", "JupynvimDashIcon" }) do
    if (groups[g] or 0) == 0 then
      fail("dashboard: no extmark with hl_group " .. g)
    else
      ok(("dashboard %s x%d"):format(g, groups[g]))
    end
  end
  if eol == 0 then
    fail("dashboard: no to-end-of-line highlights survived (end_col = -1 was eaten)")
  else
    ok(("dashboard to-end-of-line highlights: %d"):format(eol))
  end
  -- The icon highlight is the one finite-width range; it must stay finite.
  local icon
  for _, list in pairs(dm) do icon = icon or find(list, "JupynvimDashIcon") end
  if icon and icon.end_row and icon.end_col == 0 then
    fail("dashboard: icon highlight became to-end-of-line, should be finite")
  elseif icon then
    ok(("dashboard icon range finite: col %d..%d"):format(icon.col, icon.end_col))
  end
end

-- ── explorer ─────────────────────────────────────────────────────────────
local RE = require("jupynvim.remote.explorer")
local ebuf = vim.api.nvim_create_buf(false, true)
local state = {
  alias = "testalias",
  root = "/home/me/proj",
  buf = ebuf,
  expanded = {},
  kids = {
    ["/home/me/proj"] = {
      loaded = true,
      items = {
        { name = "src",       path = "/home/me/proj/src",       kind = "dir" },
        { name = "main.py",   path = "/home/me/proj/main.py",   kind = "file" },
        { name = "link.py",   path = "/home/me/proj/link.py",   kind = "link" },
      },
    },
  },
}
RE._render(state)
local em = marks_by_row(ebuf, "jupynvim.remote.explorer")

if not em then
  fail("explorer namespace missing entirely")
else
  local groups, eol = {}, 0
  for _, list in pairs(em) do
    for _, e in ipairs(list) do
      groups[e.group] = (groups[e.group] or 0) + 1
      if e.end_row and e.end_col == 0 then eol = eol + 1 end
    end
  end
  for _, g in ipairs({ "JupynvimExplorerRootIcon", "JupynvimExplorerHeader",
                       "JupynvimExplorerChevron", "JupynvimExplorerDir" }) do
    if (groups[g] or 0) == 0 then
      fail("explorer: no extmark with hl_group " .. g)
    else
      ok(("explorer %s x%d"):format(g, groups[g]))
    end
  end
  -- header (row 0) and the dir name are to-end-of-line; both must survive.
  if eol < 2 then
    fail(("explorer: expected >=2 to-end-of-line highlights, got %d"):format(eol))
  else
    ok(("explorer to-end-of-line highlights: %d"):format(eol))
  end
  local hdr = find(em[0], "JupynvimExplorerHeader")
  if not hdr then
    fail("explorer: header highlight missing on row 0")
  elseif hdr.end_row ~= 1 or hdr.end_col ~= 0 then
    fail(("explorer header: expected end_row=1 end_col=0, got end_row=%s end_col=%s")
      :format(tostring(hdr.end_row), tostring(hdr.end_col)))
  else
    ok("explorer header spans to end of line (end_row=1, end_col=0)")
  end
  -- The last rendered row also carries a to-end-of-line name highlight, where
  -- end_row points one past the final line. Both APIs accept that; assert it.
  local last = vim.api.nvim_buf_line_count(ebuf) - 1
  local tail = em[last]
  if not tail then
    fail("explorer: no highlights on the last row")
  else
    local spans = false
    for _, e in ipairs(tail) do
      if e.end_row == last + 1 and e.end_col == 0 then spans = true end
    end
    if not spans then
      fail("explorer: last row has no to-end-of-line highlight past the buffer end")
    else
      ok("explorer last row spans past buffer end without erroring")
    end
  end
end

-- ── the deprecated API is gone from both files ───────────────────────────
for _, f in ipairs({ "lua/jupynvim/remote_dashboard.lua", "lua/jupynvim/remote_explorer.lua" }) do
  local fh = io.open(f, "r")
  if fh then
    local src = fh:read("*a"); fh:close()
    if src:find("nvim_buf_add_highlight", 1, true) then
      fail(f .. " still calls nvim_buf_add_highlight")
    else
      ok(f .. " free of nvim_buf_add_highlight")
    end
  end
end

if fails == 0 then
  io.write("\nALL REMOTE-HL CHECKS PASSED\n")
else
  io.write(("\nREMOTE-HL: %d CHECK(S) FAILED\n"):format(fails))
  vim.cmd("cquit 1")
end

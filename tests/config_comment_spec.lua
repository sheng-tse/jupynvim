-- The image size the comment above `image_rows` in lua/jupynvim/init.lua names
-- ("Default 16x48"), and the one README.md's config example shows, are the
-- defaults the code has. The comment said 32x96 for a long time while the
-- defaults were 16 rows by 48 columns (#46); this keeps the three in step.
--
-- Headless, no kernel and no backend: the files are read as text and compared
-- with `require("jupynvim").config` before setup() has run.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local fails = 0
local function chk(name, cond, detail)
  if cond then
    io.write("  ok " .. name .. "\n")
  else
    io.write("FAIL " .. name .. (detail and ("  -- " .. detail) or "") .. "\n")
    fails = fails + 1
  end
end

local function read_lines(path)
  local f = assert(io.open(path, "r"), "cannot open " .. path)
  local lines = {}
  for line in f:lines() do lines[#lines + 1] = line end
  f:close()
  return lines
end

local cfg = require("jupynvim").config
chk("config has numeric image_rows and image_cols",
    type(cfg.image_rows) == "number" and type(cfg.image_cols) == "number",
    ("rows=%s cols=%s"):format(tostring(cfg.image_rows), tostring(cfg.image_cols)))

-- init.lua: walk up from the `image_rows =` line through the comment block
-- right above it and take the "Default RxC" it states.
local init = read_lines(root .. "/lua/jupynvim/init.lua")
local at
for i, line in ipairs(init) do
  if line:match("^%s*image_rows%s*=") then at = i; break end
end
chk("init.lua has an image_rows line", at ~= nil)
if at then
  local stated_rows, stated_cols
  local i = at - 1
  while i >= 1 and init[i]:match("^%s*%-%-") do
    local r, c = init[i]:match("Default (%d+)x(%d+)")
    if r then stated_rows, stated_cols = tonumber(r), tonumber(c) end
    i = i - 1
  end
  chk("the comment above image_rows states a Default RxC", stated_rows ~= nil,
      "no 'Default <rows>x<cols>' in the comment block above line " .. at)
  chk("the comment's Default RxC equals the config's image_rows x image_cols",
      stated_rows == cfg.image_rows and stated_cols == cfg.image_cols,
      ("comment says %sx%s, config is %sx%s"):format(
        tostring(stated_rows), tostring(stated_cols), tostring(cfg.image_rows), tostring(cfg.image_cols)))
end

-- README.md: every `image_rows = N,` and `image_cols = N,` of its config
-- example is the default as well.
local readme = read_lines(root .. "/README.md")
local rows, cols = {}, {}
for _, line in ipairs(readme) do
  local r = line:match("^%s*image_rows%s*=%s*(%d+)")
  if r then rows[#rows + 1] = tonumber(r) end
  local c = line:match("^%s*image_cols%s*=%s*(%d+)")
  if c then cols[#cols + 1] = tonumber(c) end
end
chk("README.md shows image_rows and image_cols", #rows >= 1 and #cols >= 1,
    ("found %d image_rows and %d image_cols lines"):format(#rows, #cols))
local readme_ok = #rows >= 1 and #cols >= 1
for _, v in ipairs(rows) do if v ~= cfg.image_rows then readme_ok = false end end
for _, v in ipairs(cols) do if v ~= cfg.image_cols then readme_ok = false end end
chk("README.md's image_rows and image_cols equal the config defaults", readme_ok,
    ("README rows={%s} cols={%s}, config %sx%s"):format(
      table.concat(rows, ","), table.concat(cols, ","), tostring(cfg.image_rows), tostring(cfg.image_cols)))

if fails == 0 then
  io.write("\nALL CONFIG COMMENT CHECKS PASSED\n")
  vim.cmd("qa!")
else
  io.write(("\nCONFIG COMMENT: %d CHECK(S) FAILED\n"):format(fails))
  vim.cmd("cquit 1")
end

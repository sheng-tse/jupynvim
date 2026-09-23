-- Keymap overrides: which modes a binding lands in, and what a bad override
-- is allowed to break.
--
-- #30: run_stay and run_advance default to normal AND insert. Rebinding one
-- to "<leader>rs" with a space leader bound " rs" in insert mode, so every
-- space typed in a cell waited out timeoutlen. A replaced lhs that starts
-- with a printable key now stays out of insert mode unless `mode` asks for it.
--
-- An override keymap.set rejects (unknown mode, empty or non-string lhs) used
-- to throw out of M.open halfway, before cell mode attached. It must cost only
-- its own binding.

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
vim.g.mapleader = " "

local fails = 0
local function chk(name, cond, detail)
  if cond then io.write("  ok " .. name .. "\n")
  else io.write("FAIL " .. name .. (detail and ("  -- " .. detail) or "") .. "\n"); fails = fails + 1 end
end

local J  = require("jupynvim")
local NB = require("jupynvim.notebook")
J.setup({ log_level = "warn" })

local notes = {}
local real_notify = vim.notify
vim.notify = function(msg, lvl, o)
  notes[#notes + 1] = tostring(msg)
  return real_notify(msg, lvl, o)
end

local function fixture()
  local p = vim.fn.tempname() .. ".ipynb"
  local f = io.open(p, "w")
  f:write('{"cells":[{"cell_type":"code","id":"c1","metadata":{},"source":"x = 1",' ..
    '"execution_count":null,"outputs":[]}],"metadata":{"kernelspec":{"name":"python3",' ..
    '"display_name":"P","language":"python"}},"nbformat":4,"nbformat_minor":5}')
  f:close()
  return p
end

-- Open a notebook under `keymaps`, wait out the deferred rebinds, and return
-- the buffer-local maps as { n = { [lhs] = true }, i = { ... } }.
local function open_with(keymaps)
  J.config.keymaps = keymaps
  notes = {}
  local p = fixture()
  local ok, buf = pcall(J.open, p)
  vim.wait(1500, function() return ok and NB.get(buf) ~= nil end, 50)
  vim.wait(500)
  local maps = { n = {}, i = {} }
  if ok and vim.api.nvim_buf_is_valid(buf) then
    for _, m in ipairs({ "n", "i" }) do
      for _, k in ipairs(vim.api.nvim_buf_get_keymap(buf, m)) do maps[m][k.lhs] = true end
    end
  end
  local abs = vim.fn.fnamemodify(p, ":p")
  local stuck = J._opening and J._opening[abs] == true
  return { ok = ok, buf = buf, maps = maps, stuck = stuck, path = p }
end

local function close(r)
  if r.ok then pcall(vim.api.nvim_buf_delete, r.buf, { force = true }) end
  os.remove(r.path)
end

local function any_space_insert_map(r)
  for lhs in pairs(r.maps.i) do
    if lhs:sub(1, 1) == " " or lhs:find("^<Space>") then return lhs end
  end
end

-- defaults are unchanged: both run keys still work from insert mode
do
  local r = open_with({})
  chk("default <C-CR> is bound in insert mode", r.maps.i["<C-CR>"])
  chk("default <S-CR> is bound in insert mode", r.maps.i["<S-CR>"])
  close(r)
end

-- #30, the exact config from the report
do
  local r = open_with({ run_stay = "<leader>rs" })
  local bad = any_space_insert_map(r)
  chk("string override to a space leader is NOT bound in insert mode", bad == nil,
      "insert map " .. vim.inspect(bad) .. " makes every typed space wait for timeoutlen")
  chk("string override to a space leader is bound in normal mode", r.maps.n[" rs"])
  close(r)
end

do
  local r = open_with({ run_stay = { lhs = "<leader>rs" } })
  chk("table override with lhs only also stays out of insert mode",
      any_space_insert_map(r) == nil)
  close(r)
end

do
  local r = open_with({ run_stay = { lhs = "<leader>rs", mode = { "n", "i" } } })
  chk("an explicit mode is respected, insert included", r.maps.i[" rs"] and r.maps.n[" rs"])
  close(r)
end

do
  local r = open_with({ run_stay = { mode = "n" } })
  chk("mode without lhs keeps the default lhs", r.maps.n["<C-CR>"])
  chk("mode without lhs drops the other modes", not r.maps.i["<C-CR>"])
  close(r)
end

do
  local r = open_with({ run_stay = "<C-s>" })
  chk("a control-key replacement keeps insert mode", r.maps.i["<C-S>"] or r.maps.i["<C-s>"],
      vim.inspect(vim.tbl_keys(r.maps.i)))
  close(r)
end

-- A bad override costs only its own binding.
for _, case in ipairs({
  { "unknown mode", { run_stay = { lhs = "<leader>rs", mode = "normal" } } },
  { "empty lhs", { run_stay = "" } },
  { "non-string lhs", { run_stay = { lhs = 5 } } },
}) do
  local label, km = case[1], case[2]
  local r = open_with(km)
  chk(label .. ": the notebook still opens", r.ok and not r.stuck,
      "open threw or left the open guard set")
  chk(label .. ": cell mode still attached", r.maps.n["dd"])
  chk(label .. ": the other keymaps still bound", r.maps.n["]c"] and r.maps.i["<S-CR>"])
  local warned = false
  for _, m in ipairs(notes) do if m:find("keymaps.run_stay", 1, true) then warned = true end end
  chk(label .. ": the user is told which override was ignored", warned)
  chk(label .. ": and the action keeps its default key", r.maps.n["<C-CR>"] and r.maps.i["<C-CR>"])
  close(r)
end

J.config.keymaps = {}
vim.notify = real_notify

if fails == 0 then
  io.write("\nALL KEYMAP-OVERRIDE CHECKS PASSED\n")
  vim.cmd("qa!")
else
  io.write(("\nKEYMAP-OVERRIDE: %d CHECK(S) FAILED\n"):format(fails))
  vim.cmd("cquit 1")
end

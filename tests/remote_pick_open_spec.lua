-- Regression test for remote_pick.open_in_editor (the SNACKS picker file-open
-- path — what most users hit, since LazyVim ships snacks.picker). After closing
-- the dashboard with `q`, the layout is [snacks-explorer | terminal] with no
-- editor window. Opening a file used to `topleft vsplit` -> the file landed at
-- the far top-left, shoving the explorer into the middle. It must instead land
-- on TOP of the terminal (right of the explorer), terminal pushed below.

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
local RP = require("jupynvim.remote.pick")
local function fail(m) io.write("FAIL: " .. m .. "\n"); vim.cmd("cquit 1") end

-- [snacks-explorer (left) | terminal (right, full height)]
local exbuf = vim.api.nvim_create_buf(false, true)
vim.bo[exbuf].filetype = "snacks_picker_list"   -- editor_win skips ^snacks
vim.api.nvim_set_current_buf(exbuf)
local exwin = vim.api.nvim_get_current_win()
vim.cmd("botright vsplit")
local termbuf = vim.api.nvim_create_buf(false, true)
vim.bo[termbuf].buftype = "nofile"              -- how remote_term makes it
vim.b[termbuf].jupynvim_term_alias = "psc"
vim.b[termbuf].jupynvim_term_slot = "below"
vim.api.nvim_set_current_buf(termbuf)
local termwin = vim.api.nvim_get_current_win()
vim.wo[termwin].winfixheight = true

-- assertion 1: no editor window (terminal + snacks-explorer both skipped)
local ew = RP.editor_win()
if ew ~= nil then fail("editor_win returned " .. tostring(ew) .. " instead of nil") end

-- open a local dummy file (stands in for the jupynvim:// URI — the window
-- choreography is identical; restore_size no-ops on this unregistered terminal)
local dummy = vim.fn.tempname() .. ".txt"
RP.open_in_editor(dummy)
local filew = vim.api.nvim_get_current_win()

-- assertion 2: explorer left, file right-of-explorer (top), terminal below it.
-- (old code did `topleft vsplit` -> file at col 0, i.e. NOT right of explorer.)
local function pos(w) return vim.api.nvim_win_get_position(w) end
local pe, pf, pt = pos(exwin), pos(filew), pos(termwin)
if pf[2] <= pe[2] then
  fail("file col " .. pf[2] .. " not right of explorer col " .. pe[2] .. " (far-left bug)")
end
if pt[2] ~= pf[2] then fail("terminal col " .. pt[2] .. " != file col " .. pf[2]) end
if pt[1] <= pf[1] then fail("terminal row " .. pt[1] .. " not below file row " .. pf[1]) end

io.write("PASS: editor_win=nil; file top-right c" .. pf[2] .. " r" .. pf[1] ..
  "; terminal below c" .. pt[2] .. " r" .. pt[1] .. "; explorer left c" .. pe[2] .. "\n")
vim.cmd("qa!")

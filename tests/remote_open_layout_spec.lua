-- Regression test for the explorer file-open layout (issue 3(ii)).
--
-- After closing the remote dashboard with `q`, the layout is [explorer | term]
-- where the remote terminal is a `nofile` buffer marked with
-- jupynvim_term_alias (NOT buftype="terminal"). Opening a non-ipynb file used
-- to dump it at the far left. It must instead land on TOP of the main area with
-- the terminal pushed BELOW it, and the explorer kept on the left.
--
-- This test exercises only the window-placement logic (no SSH): it builds the
-- same window tree with marked dummy buffers and runs open_node's choreography.

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
local RE = require("jupynvim.remote.explorer")

local function fail(msg)
  io.write("FAIL: " .. msg .. "\n")
  vim.cmd("cquit 1")
end

-- ── build [explorer (left) | terminal (main, full height)] ──
-- explorer = the current (leftmost) window
local exbuf = vim.api.nvim_create_buf(false, true)
vim.b[exbuf].jupynvim_explorer = true
vim.api.nvim_set_current_buf(exbuf)
local exwin = vim.api.nvim_get_current_win()

-- terminal as a full-height column on the right (like make_split "right")
vim.cmd("botright vsplit")
local termbuf = vim.api.nvim_create_buf(false, true)
vim.bo[termbuf].buftype = "nofile"             -- exactly how remote_term makes it
vim.b[termbuf].jupynvim_term_alias = "psc"     -- the real marker
vim.b[termbuf].jupynvim_term_slot = "below"    -- the <C-/> slot
vim.api.nvim_set_current_buf(termbuf)
local termwin = vim.api.nvim_get_current_win()
vim.wo[termwin].winfixheight = true            -- as make_split("below") sets it

-- ── assertion 1: main_editor_win must SKIP the nofile terminal → nil ──
-- (the old `buftype == "terminal"` check returned the terminal window here,
--  since a nofile buffer is not buftype="terminal"; that is the bug.)
local state = { win = exwin, alias = "psc" }
local med = RE._main_editor_win(state)
if med ~= nil then
  fail("main_editor_win returned a window (" .. tostring(med) ..
       ") instead of nil; the nofile terminal was not skipped")
end

-- ── run open_node's choreography for a non-ipynb file (file part stubbed) ──
-- Replicates the exact nil-handling in open_node, then opens a local dummy file
-- in place of `:edit jupynvim://...` (which would need SSH). The WINDOW that the
-- file lands in is what we verify.
local COMPACT_H = 9
local target = med
if not target then
  local found
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local b = vim.api.nvim_win_get_buf(w)
    if w ~= state.win and vim.api.nvim_win_get_config(w).relative == ""
       and vim.b[b].jupynvim_term_alias then
      found = w
      break
    end
  end
  if found then
    vim.api.nvim_set_current_win(found)
    vim.cmd("aboveleft split")
    target = vim.api.nvim_get_current_win()
    -- mimic remote_term.restore_size: the term had filled the main area, so
    -- shrink it back to its compact slot height. Must override winfixheight.
    pcall(vim.api.nvim_win_set_height, found, COMPACT_H)
  else
    vim.api.nvim_set_current_win(state.win)
    vim.cmd("rightbelow vsplit")
    target = vim.api.nvim_get_current_win()
  end
end
vim.api.nvim_set_current_win(target)
vim.cmd("edit " .. vim.fn.tempname() .. "_repro.txt")  -- stand-in for the file
local filewin = vim.api.nvim_get_current_win()

-- ── assertion 2: explorer left, file top of main, terminal directly below ──
local function pos(w) -- returns {row, col}
  return vim.api.nvim_win_get_position(w)
end
local ex, fw, tp = pos(exwin), pos(filewin), pos(termwin)
-- explorer is the leftmost column
if ex[2] ~= 0 then fail("explorer not at col 0 (got col " .. ex[2] .. ")") end
-- file is to the RIGHT of the explorer (main area), not the far left
if fw[2] <= ex[2] then
  fail("file window col " .. fw[2] .. " is not right of explorer col " .. ex[2] ..
       " (file opened at the far left)")
end
-- terminal sits in the SAME column as the file, directly BELOW it
if tp[2] ~= fw[2] then
  fail("terminal col " .. tp[2] .. " != file col " .. fw[2] .. " (not stacked)")
end
if tp[1] <= fw[1] then
  fail("terminal row " .. tp[1] .. " is not below file row " .. fw[1])
end
-- and the explorer must NOT have been shoved out of the leftmost position
for _, w in ipairs(vim.api.nvim_list_wins()) do
  local p = pos(w)
  if p[2] < ex[2] then fail("a window is left of the explorer (col " .. p[2] .. ")") end
end

-- ── assertion 3: terminal restored to its compact height despite winfixheight,
--    file window takes the remaining space ──
local term_h = vim.api.nvim_win_get_height(termwin)
local file_h = vim.api.nvim_win_get_height(filewin)
if term_h ~= COMPACT_H then
  fail("terminal height " .. term_h .. " != compact " .. COMPACT_H ..
       " (winfixheight blocked the resize)")
end
if file_h <= term_h then
  fail("file height " .. file_h .. " is not greater than terminal height " .. term_h)
end

io.write("PASS: terminal skipped (main_editor_win=nil); file top-right col " ..
  fw[2] .. " row " .. fw[1] .. " h " .. file_h .. ", terminal below col " .. tp[2] ..
  " row " .. tp[1] .. " h " .. term_h .. ", explorer left col " .. ex[2] .. "\n")
vim.cmd("qa!")

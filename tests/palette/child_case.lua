-- One case of tests/palette_spec.lua in a fresh Neovim, because the library
-- loads once per process and some checks need a process that has not
-- touched it:
--
--   nvim --headless -u NONE -l tests/palette/child_case.lua <repo> <case>
--
-- Prints one JSON line and quits.
--
-- Cases:
--   off    require("jupynvim.palette").setup({}), then when_ready, run with
--          JUPYNVIM_NATIVE=off: { called, tokens, state, reason, later_asks,
--          retry_asks } (later_asks: how often 1000 get() calls asked the
--          loader for the library; retry_asks: the same after a refresh())
--   fast   the first get() of the process comes from a fast event (a luv
--          callback): { get_ok, get_err, get_fast, tokens_after, state }
--   setup  require("jupynvim").setup({}): { native_loaded, palette_autocmds }
--          (is the library still unloaded after the plugin's setup(), and is
--          the palette's augroup there)
--   cold_colorscheme  setup({}) with the default colorscheme (whose Normal has a
--          background) and nothing asking for the palette, then ColorScheme
--          fired 50 times: { normal_has_bg, native_loaded, derives, queries,
--          handler_ms (median of one ColorScheme), later_native_loaded }
--   show_off  setup({}), then palette.show() with no library (run with
--          JUPYNVIM_NATIVE=off): { notes (every vim.notify call: { msg,
--          level }), float_open }
--   health require("jupynvim").setup({}), then :checkhealth jupynvim:
--          { health (the report's text), notices (how many vim.notify calls
--          the report itself made) }
local repo, case = arg[1], arg[2]
if not repo or not case then
  io.stderr:write("usage: nvim --headless -u NONE -l child_case.lua <repo> <case>\n")
  vim.cmd("cquit 2")
  return
end
vim.opt.runtimepath:prepend(repo)
package.path = repo .. "/lua/?.lua;" .. repo .. "/lua/?/init.lua;" .. package.path

local out = {}
if case == "off" then
  local P = require("jupynvim.palette")
  P.setup({})
  P.when_ready(function() out.called = true end)
  vim.wait(5000, function() return out.called == true end, 1)
  out.tokens = P.get()
  local i = P.info()
  out.state, out.reason = i.state, i.reason
  -- the library is known to be missing: get() must not ask for it again, a
  -- refresh() may
  vim.wait(200)
  local N = require("jupynvim.native")
  local asks = 0
  local orig = N.when_ready
  N.when_ready = function(cb) asks = asks + 1; return orig(cb) end
  for _ = 1, 5 do
    for _ = 1, 200 do P.get() end
    vim.wait(20)
  end
  out.later_asks = asks
  P.refresh()
  vim.wait(500, function() return asks > 0 end, 1)
  vim.wait(50)
  out.retry_asks = asks
elseif case == "fast" then
  local P = require("jupynvim.palette")
  P.setup({})
  local timer = vim.uv.new_timer()
  local fired = false
  timer:start(0, 0, function()
    local ok, res = pcall(P.get)
    out.get_ok, out.get_err = ok, (not ok) and tostring(res) or nil
    out.get_fast = vim.in_fast_event()
    timer:close()
    fired = true
  end)
  vim.wait(3000, function() return fired end, 1)
  -- only the get() above may start the derivation: the wait reads the state, which starts nothing, and
  -- lasts past the loader's probe limit (native.lua _probe_ms, 10 s on macOS), returning when it is done
  vim.wait(15000, function() return P.info().state ~= "waiting" end, 1)
  out.tokens_after = P.get() ~= nil
  out.state = P.info().state
elseif case == "setup" then
  require("jupynvim").setup({})
  out.native_loaded = package.loaded["jupynvim.native"] ~= nil
  local ok, acs = pcall(vim.api.nvim_get_autocmds, { group = "jupynvim_palette", event = "ColorScheme" })
  out.palette_autocmds = ok and #acs or -1
elseif case == "cold_colorscheme" then
  local P = require("jupynvim.palette")
  P.setup({})
  out.normal_has_bg = vim.api.nvim_get_hl(0, { name = "Normal", link = false }).bg ~= nil
  -- scheduled work lands before anything is read (a setup() that queued a
  -- derivation or loaded the library would show here)
  vim.wait(300)
  local ms = {}
  for _ = 1, 50 do
    local t0 = vim.uv.hrtime()
    vim.api.nvim_exec_autocmds("ColorScheme", {})
    ms[#ms + 1] = (vim.uv.hrtime() - t0) / 1e6
  end
  table.sort(ms)
  out.handler_ms = ms[25]
  out.native_loaded = package.loaded["jupynvim.native"] ~= nil
  vim.wait(300)
  out.later_native_loaded = package.loaded["jupynvim.native"] ~= nil
  out.derives, out.queries = P._stats.derives, P._stats.queries
elseif case == "show_off" then
  local P = require("jupynvim.palette")
  P.setup({})
  local notes = {}
  vim.notify = function(msg, level) notes[#notes + 1] = { msg = tostring(msg), level = level } end
  P.show()
  vim.wait(3000, function() return #notes > 0 end, 1)
  vim.wait(100)
  out.notes = notes
  out.float_open = false
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then out.float_open = true end
  end
elseif case == "health" then
  require("jupynvim").setup({})
  local notices = 0
  local orig = vim.notify
  vim.notify = function(...) notices = notices + 1; return orig(...) end
  vim.cmd("checkhealth jupynvim")
  out.health = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  vim.wait(100)
  out.notices = notices
else
  io.stderr:write("unknown case " .. tostring(case) .. "\n")
  vim.cmd("cquit 2")
  return
end
io.stdout:write("\n", vim.json.encode(out), "\n")
vim.cmd("qa!")

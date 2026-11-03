-- The palette's question for the terminal's background (lua/jupynvim/palette.lua)
-- asked while a gif frame is on its way to the terminal.
--
--   nvim --headless -u NONE -c "luafile tests/stream_palette_spec.lua" -c "cquit 3"
--
-- notebook/image.lua follows every gif frame with a status request (DSR), and
-- the terminal answers in order, so the answer of every frame still in flight
-- when the palette writes its question (OSC 11, then a DSR) comes before the
-- question's own answers. The palette's window, in which Neovim's own handler
-- for the background is away, must not take such an answer for the end of its
-- question: it would end the window, and the answer to the question, which
-- then reaches Neovim's handler, would set 'background' from the terminal's
-- colour (the user's :set background=light in a dark terminal undone). The
-- palette asks image.lua for a fence (status_fence) right before it writes.
--
-- The terminal is the stand-in of tests/stream_writer_spec.lua: nvim_list_uis
-- and nvim_ui_send are recorders, and the answers are TermResponse events fired
-- in the order a terminal gives them.
--
-- A  no gif: the question answered late is the palette's alone (control)
-- B  a frame in flight: its answer comes first, then the marker's, then the
--    question's own, 150 ms later and 20 ms later
-- C  the terminal needs longer than the question's limit to read the frames
-- D  markers off (a terminal that answers no XTVERSION): the status answers
--    owed are skipped
-- E  a reset of the books while the question waits ends the fence

package.path = "./lua/?.lua;./lua/?/init.lua;./tests/?.lua;" .. package.path

local fails = 0
local function chk(name, cond, detail)
  if cond then io.write("  ok " .. name .. "\n")
  else io.write("FAIL " .. name .. (detail and ("  -- " .. detail) or "") .. "\n"); fails = fails + 1 end
end

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
vim.env.TERM = "xterm-kitty"
-- not inside tmux, whatever shell runs the spec (F sets it on purpose)
vim.env.TMUX, vim.env.JUPYNVIM_DISABLE_TMUX_PASSTHROUGH = nil, nil
vim.env.JUPYNVIM_TTY = tmp .. "/tty"
io.open(vim.env.JUPYNVIM_TTY, "w"):close()

-- ── the simulated UI ────────────────────────────────────────────────────
local real_chan_send = vim.api.nvim_chan_send
local ui_out, chan_out = {}, {}
-- tty_ui: true, a terminal UI; "two", two terminal UIs; "gui", a UI
-- without a terminal; "tui", a terminal attached with nvim --remote-ui as
-- Neovim 0.11 lists it (its term_name, no stdout_tty) on channel tui_chan;
-- false, none
local tty_ui, ui_send_api, ui_send_throws = false, true, false
-- the stand-in terminal answers the marker (XTVERSION) at once, once per
-- terminal UI; checks of the marker itself turn this off
local auto_mark = true
local MARK, MARK_ANSWER = "\27[>q", "\27P>|spec"
local tui_chan = 10
local list_uis_n = 0
-- like the real calls, the recorders refuse to run in a fast event
local function no_fast(name)
  if vim.in_fast_event() then error("E5560: " .. name .. " must not be called in a fast event context") end
end
local function install()
  vim.api.nvim_ui_send = ui_send_api and function(s)
    no_fast("nvim_ui_send")
    if ui_send_throws then error("ui_send failed") end
    ui_out[#ui_out + 1] = s
    if s == MARK and auto_mark then
      for _ = 1, (tty_ui == "two" and 2 or 1) do
        vim.api.nvim_exec_autocmds("TermResponse", { data = { sequence = MARK_ANSWER } })
      end
    end
  end or nil
  vim.api.nvim_list_uis = function()
    no_fast("nvim_list_uis")
    list_uis_n = list_uis_n + 1
    if not tty_ui then return {} end
    if tty_ui == "tui" then
      return { { chan = tui_chan, stdout_tty = false, stdin_tty = false, term_name = "xterm-256color",
                 width = 80, height = 24 } }
    end
    if tty_ui == "two" then
      return { { chan = 1, stdout_tty = true, width = 80, height = 24 },
               { chan = 2, stdout_tty = true, width = 80, height = 24 } }
    end
    return { { chan = 1, stdout_tty = tty_ui == true, width = 80, height = 24 } }
  end
end
vim.api.nvim_chan_send = function(ch, s)
  no_fast("nvim_chan_send")
  if ch == vim.v.stderr then chan_out[#chan_out + 1] = s; return end
  return real_chan_send(ch, s)
end
-- what the module sees its stderr as: a terminal, as for every TUI editor,
-- whatever the spec's own stderr is (a pipe in tests/run_all.sh); "file"
-- for nvim --headless started with stderr on a file
local real_guess_handle = vim.uv.guess_handle
local stderr_kind = "tty"
vim.uv.guess_handle = function(fd)
  if fd == 2 then return stderr_kind end
  return real_guess_handle(fd)
end
install()
local function reset() ui_out, chan_out = {}, {} end

local png = require("png_fixture")
local PNG = vim.base64.encode(png(40, 30, 1))
local FA, FB = vim.base64.encode(png(40, 30, 2)), vim.base64.encode(png(40, 30, 3))
local GIF1 = "R0lGODlhAQABAIAAAP///wAAACH5BAEAAAAALAAAAAABAAEAAAICRAEAOw=="

local Image = require("jupynvim.notebook.image")
local function ui_changed() if Image._ui_changed then Image._ui_changed() end end
-- the image module's own autocmds and hooks: absent on a tree without them,
-- where the checks that need them must fail one by one, not stop the spec
local function fire(ev) pcall(vim.api.nvim_exec_autocmds, ev, { group = "jupynvim_image_ui" }) end
local function catch_up() if Image._catch_up then pcall(Image._catch_up) end end

-- a backend stand-in: records calls; the tty probe of a local attach fails
-- unless `local_ok`
local function fake_client(local_ok)
  local c = { job = 1, sync = {}, async = {} }
  function c:call_sync(m, p)
    self.sync[#self.sync + 1] = { m, p }
    if p and p.tty and not local_ok then return "no tty here" end
    return nil, {}
  end
  function c:call(m, p, cb)
    self.async[#self.async + 1] = { m, p }
    if cb then cb(nil, {}) end
  end
  return c
end
local function asked(list, method, field)
  for _, x in ipairs(list) do
    if x[1] == method and x[2] and x[2][field] then return true end
  end
  return false
end
-- the base64 payload of a kitty transmit (its chunks joined)
local function payload(s)
  local t = {}
  for body in (s or ""):gmatch("\27_G[^;\27]*;([^\27]*)\27\\") do t[#t + 1] = body end
  return table.concat(t)
end
-- what went out with nvim_ui_send: gif frames and transmits (a=t), and the
-- status requests (DSR) that follow a frame
local REQ = "\27[5n"
local function count(list, pred)
  local n = 0
  for _, s in ipairs(list) do if pred(s) then n = n + 1 end end
  return n
end
local function is_tx(s) return s:find("\27_Ga=t,", 1, true) == 1 end
local function is_req(s) return s == REQ end
local function frames_out() return count(ui_out, is_tx) end
local function first_tx() for _, s in ipairs(ui_out) do if is_tx(s) then return s end end end
-- the terminal answering one status request
local function answer() vim.api.nvim_exec_autocmds("TermResponse", { data = { sequence = "\27[0n" } }) end
-- the marker (XTVERSION, "\27[>q"): what went out of it, what went out
-- besides it, and the terminal answering it once
local function is_mark(s) return s == MARK end
local function marks_out() return count(ui_out, is_mark) end
local function nomark()
  local t = {}
  for _, s in ipairs(ui_out) do if s ~= MARK then t[#t + 1] = s end end
  return t
end
local function answer_mark()
  vim.api.nvim_exec_autocmds("TermResponse", { data = { sequence = MARK_ANSWER } })
end

-- The rest of I drives a gif by hand: its clock ticks once a minute, and
-- push(p, i) sends frame i now the way a scroll back into view does
-- (Image._catch_up), true when it went out.
local function hand_gif(key, frames)
  Image.ensure_transmitted(key, frames[1], function() end, { renderer = "placeholder" })
  local p = Image._placements[key]
  pcall(Image.set_visible_probe, key, function() return true end)
  if p then
    p.frames, p.delays = frames, {}
    for i = 1, #frames do p.delays[i] = 60000 end
  end
  Image.resume_animations()
  return p
end
local function push(p, idx)
  if not p then return false end
  local n0 = Image._frames_sent or 0
  p.frame_idx, p.stale = idx, true
  catch_up()
  return (Image._frames_sent or 0) > n0
end
local function acks_n() return Image._acks_info and Image._acks_info().n or -1 end

-- ── the palette, with Neovim's own handler for the background standing by ──
local OSC11 = "\27]11;rgb:ffff/ffff/ffff"
local DSR_ANSWER = "\27[0n"
local nv_calls = {}
local function nvim_tty_handler()
  local g = vim.api.nvim_create_augroup("nvim.tty", { clear = true })
  vim.api.nvim_create_autocmd("TermResponse", { group = g,
    desc = "Update the value of 'background' automatically based on the terminal emulator's background color",
    callback = function(ev)
      local s = type(ev.data) == "table" and ev.data.sequence or ev.data
      if type(s) == "string" and s:find("^\27%]11;") then nv_calls[#nv_calls + 1] = s end
    end })
end
local function tr(s) vim.api.nvim_exec_autocmds("TermResponse", { data = { sequence = s } }) end

tty_ui = true; install(); ui_changed()
Image.attach(fake_client(false), vim.env.JUPYNVIM_TTY)
Image._remote_mode = true
Image._mark_seen = true
auto_mark = false

-- run(opts): the palette asks (Normal has no background, the terminal's is not known yet) with one gif
-- frame in flight; the terminal's answers come in the order it gives them. Returns what happened.
local function run(o)
  nv_calls = {}
  nvim_tty_handler()
  package.loaded["jupynvim.palette"] = nil
  local P = require("jupynvim.palette")
  P._started = function() return true end
  P._msgs_waiting = function() return false end
  P._osc_timeout_ms = o.timeout or 1000
  P._grace_ms = 100
  vim.api.nvim_set_hl(0, "Normal", {})
  ui_changed(); reset()
  Image._mark_off = o.mark_off or false
  local p
  if o.frames then
    local F = {}
    for i = 1, 3 do F[i] = vim.base64.encode(png(40, 30, 700 + i)) end
    p = hand_gif("pal_gif", F)
    if not o.mark_off then
      push(p, 1); answer_mark()                -- the marker is answered, frame 1 and its DSR are out
    else
      push(p, 1)
    end
    if o.two_frames then push(p, 2) end
  end
  local inflight = acks_n()
  local f0 = P._stats.fallbacks
  local m0 = marks_out()
  P.setup({})                                  -- asks OSC 11 and DSR
  local asked = P._stats.queries
  local fence_marker = marks_out() - m0
  -- the order the writes went out in: the marker is before the question
  local pos_mark, pos_q
  for i, x in ipairs(ui_out) do
    if x == MARK and i > 1 then pos_mark = pos_mark or i end
    if x:find("\27]11;?", 1, true) then pos_q = pos_q or i end
  end
  for _, step in ipairs(o.steps) do
    if type(step) == "number" then vim.wait(step) else tr(step) end
  end
  vim.wait(o.settle or 250)
  local info = P.info and P.info() or {}
  local r = { inflight = inflight, queries = asked, fallbacks = P._stats.fallbacks - f0, nv = #nv_calls,
              fence_marker = fence_marker, marker_first = pos_mark and pos_q and pos_mark < pos_q,
              answers = P._stats.answers, reason = info.reason }
  if p then Image.clear_for_cell("pal_gif") end
  pcall(vim.api.nvim_del_augroup_by_name, "jupynvim_palette")
  return r
end

-- A: no gif in flight
do
  local r = run({ steps = { 150, OSC11, DSR_ANSWER } })
  chk("A with no gif frame in flight the question answered 150 ms late is the palette's alone: Neovim's handler gets nothing, no fallback",
    r.queries == 1 and r.nv == 0 and r.fallbacks == 0 and r.fence_marker == 0,
    vim.inspect(r))
end
-- B: a frame in flight, the order of a terminal: the frame's status answer, the marker's answer, then the question's
do
  local r = run({ frames = true, steps = { DSR_ANSWER, 150, MARK_ANSWER, 5, OSC11, DSR_ANSWER } })
  chk("B a gif frame in flight: its status answer comes before the question's, the question's own OSC 11 answer 150 ms behind it does not reach Neovim's handler, and no fallback",
    r.inflight == 1 and r.queries == 1 and r.nv == 0 and r.fallbacks == 0 and r.fence_marker == 1 and r.marker_first,
    vim.inspect(r))
  local r2 = run({ frames = true, steps = { DSR_ANSWER, 20, MARK_ANSWER, 5, OSC11, DSR_ANSWER } })
  chk("B ...with the question's answer 20 ms behind it: the same", r2.nv == 0 and r2.fallbacks == 0 and r2.fence_marker == 1,
    vim.inspect(r2))
  local r3 = run({ frames = true, two_frames = true, steps = { DSR_ANSWER, DSR_ANSWER, 150, MARK_ANSWER, 5, OSC11, DSR_ANSWER } })
  chk("B ...two frames in flight: the same", r3.inflight == 2 and r3.nv == 0 and r3.fallbacks == 0 and r3.fence_marker == 1,
    vim.inspect(r3))
end
-- C: the terminal reads the frames longer than the question's limit
do
  local r = run({ frames = true, timeout = 150, steps = { 400, DSR_ANSWER, MARK_ANSWER, 5, OSC11, DSR_ANSWER } })
  chk("C the terminal needs longer than the question's limit to read the frames in flight: the question is still the palette's when its answers come",
    r.nv == 0 and r.fallbacks == 0 and r.answers == 1, vim.inspect(r))
end
-- D: markers off
do
  local r = run({ frames = true, mark_off = true, two_frames = true, steps = { DSR_ANSWER, DSR_ANSWER, 150, OSC11, DSR_ANSWER } })
  chk("D markers off: the status answers owed to the frames are skipped, the next ones are the palette's",
    r.inflight == 2 and r.fence_marker == 0 and r.nv == 0 and r.fallbacks == 0, vim.inspect(r))
  Image._mark_off = false
end
-- E: a reset of the books (a UI attached) while the question waits ends the fence: the question is not held back for good
do
  nv_calls = {}
  nvim_tty_handler()
  package.loaded["jupynvim.palette"] = nil
  local P = require("jupynvim.palette")
  P._started = function() return true end
  P._msgs_waiting = function() return false end
  P._osc_timeout_ms = 1000
  vim.api.nvim_set_hl(0, "Normal", {})
  ui_changed(); reset()
  local F = {}
  for i = 1, 3 do F[i] = vim.base64.encode(png(40, 30, 720 + i)) end
  local p = hand_gif("pal_gif_e", F)
  push(p, 1); answer_mark()
  P.setup({})
  ui_changed()                                 -- the books are reset: the marker is forgotten
  tr(DSR_ANSWER)                               -- (the forgotten frame's answer, taken as the question's: the old behavior)
  tr(OSC11); tr(DSR_ANSWER)
  vim.wait(250)
  chk("E a reset of the books while the question waits passes the fence: the question's own answers still end it",
    #vim.api.nvim_get_autocmds({ group = "nvim.tty", event = "TermResponse" }) == 1 and P._stats.answers == 1 and #nv_calls == 0,
    tostring(#vim.api.nvim_get_autocmds({ group = "nvim.tty", event = "TermResponse" })) .. " " .. tostring(P._stats.answers) .. " " .. #nv_calls)
  Image.clear_for_cell("pal_gif_e")
  pcall(vim.api.nvim_del_augroup_by_name, "jupynvim_palette")
end

vim.fn.delete(tmp, "rf")
if fails == 0 then
  io.write("\nALL STREAM-PALETTE CHECKS PASSED\n")
  vim.cmd("qa!")
else
  io.write(("\nSTREAM-PALETTE: %d CHECK(S) FAILED\n"):format(fails))
  vim.cmd("cquit 1")
end

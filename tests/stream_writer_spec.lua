-- How Kitty graphics reach the terminal, and when they are not sent at all.
--
-- Since Neovim 0.10 the screen is drawn by a separate UI process, and bytes
-- written to the terminal on another path (the stderr channel, the backend's
-- /dev/tty) can land inside one of its escape sequences. Neovim 0.12's
-- nvim_ui_send hands them to the UI, which writes them between its own
-- sequences. So with a terminal UI every escape is encoded here and sent that
-- way, and the backend is never asked to write to a tty. Writes are also cut
-- down to what the screen needs: a gif out of view sends no frames (its clock
-- runs on), and a render re-asserts an image's placement only when the
-- terminal may have lost it. Neovim 0.11 has no nvim_ui_send: there the
-- placements are healed at most once a second instead of on every render.
-- While no terminal shows the editor (a :detach, a suspend) nothing is
-- written, and what the terminal missed is sent when one is back. Gif frames
-- wait for the terminal: each is followed by a status request (DSR, which
-- the UI does not take for its own answer when it stops), and a frame goes
-- out only while the frames not answered for fit a small window; before
-- the UI stops, the requests in flight are answered.
-- The module notes a terminal UI already attached when it loads (a plugin
-- loaded lazily sees no UIEnter), so a :detach after that holds too. On
-- Neovim 0.11 a terminal attached with nvim --remote-ui gets the writes on
-- the stderr channel only when it runs in the terminal that channel reaches.
-- What the backend is asked to write in its local mode is held the same
-- way, and once a terminal UI has been attached the backend stops writing
-- wherever the escapes encoded here reach a terminal.
--
-- Image data from a notebook is checked against the base64 alphabet before it
-- goes into an escape (section S), and a gif counts as in view only when
-- rows of it are on the screen, not when its cell's last line is (section E,
-- continued).
--
-- The UI is simulated: nvim_list_uis, nvim_ui_send and the stderr channel are
-- replaced by recorders, so every byte meant for the terminal is seen here,
-- and the terminal's answers are TermResponse events fired by the spec.
-- The same is checked on a real screen by tests/stream_order_screen.sh,
-- stream_backlog_screen.sh, stream_suspend_screen.sh, stream_stop_screen.sh,
-- stream_fair_screen.sh, stream_detach_screen.sh, stream_inject_screen.sh,
-- stream_edge_screen.sh, stream_nomark_screen.sh and stream_remote_screen.sh
-- (all in tests/).
--
-- A gif's frame is the one its own clock is at, counted on the loop's time
-- from when it started, however late a tick runs or how long it was out of
-- view (section K). Without nvim_ui_send the editor writes beside the UI, so
-- gif frames, catch-ups and heals wait until no redraw started for a while,
-- and a frame held so goes once, when the screen is quiet (section Q). And
-- no other code in the plugin reaches the terminal than the places that are
-- meant to, in every form a scan of the source can see (section W). A session
-- with no local backend, only remote notebooks, follows every rule above too
-- (section R).

package.path = "./lua/?.lua;./lua/?/init.lua;./tests/?.lua;" .. package.path

local fails = 0
local function chk(name, cond, detail)
  if cond then io.write("  ok " .. name .. "\n")
  else io.write("FAIL " .. name .. (detail and ("  -- " .. detail) or "") .. "\n"); fails = fails + 1 end
end

-- A reading of how long Lua code takes. LuaJIT can fail to get memory for
-- machine code and then start, fail and flush every trace over and over,
-- which makes all Lua some 1000 times slower (the LuaJIT of Neovim 0.11.5's
-- macOS arm64 release does so in some runs, about one in five to eight
-- here, from any point of the run on; its limit on machine code set to 1 KB
-- before the first trace makes it do so every time). A reading taken while
-- LuaJIT flushes its traces is LuaJIT's, so it is taken again with the JIT
-- compiler off: slower than working machine code, a stricter test.
-- measure() returns the reading; `lj` stands in for LuaJIT's jit module
-- (the check of this function below).
local function jit_timed(measure, lj)
  if lj == nil then lj = rawget(_G, "jit") end
  if not lj then return measure(), "" end
  local flushes = 0
  local function on_trace(what) if what == "flush" then flushes = flushes + 1 end end
  lj.attach(on_trace, "trace")
  local ok, v = pcall(measure)
  lj.attach(on_trace)
  if not ok then error(v, 0) end
  if flushes == 0 then return v, "" end
  lj.off()
  ok, v = pcall(measure)
  lj.on()
  if not ok then error(v, 0) end
  return v, (", with the JIT off: LuaJIT flushed its traces %d times"):format(flushes)
end
-- What a call costs, in us (n calls, timed as above).
local function cost_us(n, fn)
  return jit_timed(function()
    local t0 = vim.uv.hrtime()
    for _ = 1, n do fn() end
    return (vim.uv.hrtime() - t0) / n / 1000
  end)
end
do
  -- a stand-in for the jit module whose trace hook reports flushes during
  -- the first reading: the reading is taken again with the JIT off, and that
  -- one is returned; with no flush, the first one is
  local calls, hook = {}, nil
  local fake = {
    attach = function(f, what) calls[#calls + 1] = what and "attach" or "detach"; hook = what and f or nil end,
    off = function() calls[#calls + 1] = "off" end,
    on = function() calls[#calls + 1] = "on" end,
  }
  local n = 0
  local v, why = jit_timed(function()
    n = n + 1
    calls[#calls + 1] = "measure"
    if n == 1 and hook then hook("flush"); hook("flush"); return 4488 end
    return 3
  end, fake)
  local seq = table.concat(calls, " ")
  local n2 = 0
  local v2, why2 = jit_timed(function() n2 = n2 + 1; return 5 end, fake)
  chk("T1 a reading taken while LuaJIT flushed its traces is taken again with the JIT off, and only then",
    v == 3 and why == ", with the JIT off: LuaJIT flushed its traces 2 times"
      and seq == "attach measure detach off measure on" and v2 == 5 and why2 == "" and n2 == 1,
    ("with flushes %s%s (%s); without %s%s, %d reading(s)"):format(tostring(v), why, seq, tostring(v2), why2, n2))
end

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
vim.env.TERM = "xterm-kitty"
-- not inside tmux, whatever shell runs the spec (F sets it on purpose)
vim.env.TMUX, vim.env.JUPYNVIM_DISABLE_TMUX_PASSTHROUGH = nil, nil
vim.env.JUPYNVIM_TTY = tmp .. "/tty"
io.open(vim.env.JUPYNVIM_TTY, "w"):close()

-- ── the simulated UI ────────────────────────────────────────────────────
-- the real nvim_ui_send (nil on Neovim 0.11), kept before the first install()
-- replaces it: section Q checks what the module does at load time without it
local REAL_UI_SEND = vim.api.nvim_ui_send
local real_chan_send = vim.api.nvim_chan_send
local ui_out, chan_out = {}, {}
-- tty_ui: true, a terminal UI; "two", two terminal UIs; "gui", a UI
-- without a terminal; "tty+gui", a terminal UI (channel 1) and a GUI
-- (channel 7); "tui", a terminal attached with nvim --remote-ui as
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
    if tty_ui == "tty+gui" then
      return { { chan = 1, stdout_tty = true, width = 80, height = 24 },
               { chan = 7, stdout_tty = false, width = 80, height = 24 } }
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
-- Without nvim_ui_send the module notes each redraw (Image._note_redraw, from
-- a decoration provider) and holds gif frames, catch-ups and heals while the
-- screen redraws (section Q). The modules here load with a stand-in
-- nvim_ui_send, so no provider is registered, and a headless :redraw runs
-- one anyway: the note is a counter in every section but Q, which puts the
-- real one back for its checks.
local REAL_NOTE_REDRAW = Image._note_redraw
local redraws_noted = 0
Image._note_redraw = function() redraws_noted = redraws_noted + 1 end
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

-- ── A. Neovim 0.12 with a terminal UI ───────────────────────────────────
tty_ui = true; install(); ui_changed()
local ca = fake_client(false)
Image.attach(ca, vim.env.JUPYNVIM_TTY)
chk("A1 with a terminal UI the backend is never asked to write to a tty",
  not asked(ca.sync, "kitty_attach", "tty") and not asked(ca.async, "kitty_attach", "tty"))
chk("A2 the backend is told the escapes are encoded here, without a wait",
  asked(ca.async, "kitty_attach", "remote") and Image._remote_mode == true)
chk("A10 attach with a terminal UI makes no synchronous kitty_attach call", not asked(ca.sync, "kitty_attach", "remote")
  and not asked(ca.sync, "kitty_attach", "tty"))

reset()
local id_a
Image.ensure_transmitted("spec_a", PNG, function(id) id_a = id end, { renderer = "placeholder" })
local pa = Image._placements.spec_a
local place = pa and ("\27_Ga=p,U=1,i=%d,p=1,c=%d,r=%d,q=2\27\\"):format(pa.image_id, pa.cols, pa.rows) or "?"
chk("A3 a transmit reaches the terminal through nvim_ui_send, encoded here",
  id_a and #ui_out == 2 and #chan_out == 0
    and ui_out[1]:find("\27_Ga=t,f=100,i=" .. id_a .. ",q=2,m=", 1, true) == 1
    and ui_out[1]:sub(-#place) == place and payload(ui_out[1]) == PNG,
  ("ui_send %d, stderr %d"):format(#ui_out, #chan_out))
chk("A4 followed by one clean placement",
  ui_out[2] == ("\27_Ga=d,d=i,i=%d,q=2\27\\"):format(id_a or -1) .. place)

reset()
for _ = 1, 5 do Image.reassert_virtual_placements() end
chk("A5 re-asserting placements nothing changed for writes nothing", #ui_out + #chan_out == 0,
  (#ui_out + #chan_out) .. " writes")

local inv_ok = pcall(Image.invalidate_placements)
reset(); Image.reassert_virtual_placements()
local after_inv = #ui_out
reset(); Image.reassert_virtual_placements()
chk("A6 after invalidate_placements one re-assert per image, then none",
  inv_ok and after_inv == 1 and #ui_out == 0, ("first %d, second %d"):format(after_inv, #ui_out))

reset(); Image.clear_visible_placements(); Image.reassert_virtual_placements()
chk("A7 clearing visible placements re-asserts the virtual ones once",
  #ui_out == 2 and ui_out[1] == "\27_Ga=d,d=a,q=2\27\\" and ui_out[2]:find("a=p,U=1", 1, true) ~= nil,
  #ui_out .. " writes")

reset()
local tty_n0 = Image._tty_n or 0
local t = vim.uv.new_timer()
t:start(0, 0, function() Image.clear_visible_placements() end)  -- a luv callback is a fast event
vim.wait(1000, function() return #ui_out + #chan_out > 0 end, 5)
t:close()
chk("A8 a write from a fast event is queued and goes through nvim_ui_send",
  #ui_out == 1 and ui_out[1] == "\27_Ga=d,d=a,q=2\27\\" and #chan_out == 0 and (Image._tty_n or 0) - tty_n0 == 1,
  ("ui_send %d, stderr %d, counted %d"):format(#ui_out, #chan_out, (Image._tty_n or 0) - tty_n0))

do
  -- a write that comes while fast-event writes wait for the main loop goes
  -- out after them, not before
  reset()
  local real_fast = vim.in_fast_event
  vim.in_fast_event = function() return true end
  Image.clear_visible_placements()                  -- d=a, waits for the main loop
  vim.in_fast_event = real_fast
  local pa12 = Image._placements.spec_a
  if pa12 then pcall(Image.invalidate_placements); Image.reassert_virtual_placements() end  -- a=p, from the main loop
  vim.wait(500, function() return #ui_out >= 2 end, 5)
  chk("A12 a write made while fast-event writes wait for the main loop goes out after them",
    #ui_out == 2 and ui_out[1] == "\27_Ga=d,d=a,q=2\27\\" and ui_out[2]:find("a=p,U=1", 1, true) ~= nil,
    vim.inspect(ui_out))
end

ui_send_throws = true; reset()
Image.clear_visible_placements()
ui_send_throws = false
chk("A9 when nvim_ui_send fails the write falls back to the stderr channel",
  #chan_out == 1 and chan_out[1] == "\27_Ga=d,d=a,q=2\27\\")
do
  -- the terminal UI check runs on every write and render: it is cached until
  -- a UI attaches or leaves, not asked of nvim_list_uis each time
  local n0 = list_uis_n
  for _ = 1, 20 do Image.clear_visible_placements(); Image.reassert_virtual_placements() end
  chk("A11 writes and renders reuse the cached terminal UI check", list_uis_n == n0,
    (list_uis_n - n0) .. " nvim_list_uis calls")
  reset()
end

-- ── S. image data never reaches the terminal unchecked ──────────────────
-- A notebook's image value goes into a Kitty APC as it is. A byte outside
-- the base64 alphabet (an ESC above all) can end the APC early, and the
-- terminal then runs what follows as its own escapes. ensure_transmitted
-- refuses such a value before anything is written.
do
  reset()
  local ffi0 = Image._b64_ffi
  local has_ok = type(Image._b64_ok) == "function"
  local NOFN = "no Image._b64_ok"
  local HOSTILE = PNG:sub(1, 40) .. "\27\\\27]52;c;aW5qZWN0ZWQ=\7" .. PNG:sub(41)
  local ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/="
  local keys = {}
  local function ask(key, value, opts)
    keys[#keys + 1] = key
    local n, last, sync = 0, "unset", false
    local before = #ui_out + #chan_out
    local calls0 = #ca.sync + #ca.async
    Image.ensure_transmitted(key, value, function(id) n = n + 1; last = id end, opts or { renderer = "placeholder" })
    sync = n == 1
    return { n = n, id = last, sync = sync, wrote = #ui_out + #chan_out - before,
             backend = #ca.sync + #ca.async - calls0 }
  end
  local function counting()
    local real, calls = Image._b64_ok, { n = 0 }
    Image._b64_ok = function(v) calls.n = calls.n + 1; return real(v) end
    return calls, function() Image._b64_ok = real end
  end

  local r1 = ask("spec_s1", HOSTILE)
  chk("S1 a value with an escape inside is refused before anything is written",
    r1.sync and r1.id == nil and r1.wrote == 0 and r1.backend == 0
      and not asked(ca.sync, "kitty_transmit_virtual", "png_b64")
      and not asked(ca.async, "kitty_transmit_virtual", "png_b64")
      and not asked(ca.sync, "kitty_transmit_only", "png_b64")
      and not asked(ca.async, "kitty_transmit_only", "png_b64")
      and Image._placements.spec_s1 == nil,
    ("callbacks %d (id %s), writes %d, backend calls %d%s"):format(r1.n, tostring(r1.id), r1.wrote, r1.backend,
      has_ok and "" or ("; " .. NOFN)))

  if has_ok then
    local calls, restore = counting()
    local r = ask("spec_s1", HOSTILE)
    restore()
    chk("S1b asked again for the same key and value it is refused at once, without a second check",
      r.sync and r.id == nil and r.wrote == 0 and calls.n == 0, ("callbacks %d, checks %d, writes %d"):format(r.n, calls.n, r.wrote))
    Image.clear_for_cell("spec_s1")
    local calls2, restore2 = counting()
    local r2 = ask("spec_s1", HOSTILE)
    restore2()
    chk("S1c after clear_for_cell the same value is checked again, and refused again",
      r2.sync and r2.id == nil and r2.wrote == 0 and calls2.n == 1, ("callbacks %d, checks %d, writes %d"):format(r2.n, calls2.n, r2.wrote))
    -- the check sits before the conversion of a gif or a jpeg, which would
    -- start a process on the value
    local r3 = ask("spec_s1m", HOSTILE, { renderer = "placeholder", mime = "image/jpeg" })
    local r4 = ask("spec_s1g", HOSTILE, { renderer = "placeholder", mime = "image/gif" })
    chk("S1d a gif or jpeg value with an escape inside is refused too, before any conversion",
      r3.sync and r3.id == nil and r3.wrote == 0 and r4.sync and r4.id == nil and r4.wrote == 0
        and Image._placements.spec_s1m == nil and Image._placements.spec_s1g == nil,
      ("jpeg: callbacks %d writes %d; gif: callbacks %d writes %d"):format(r3.n, r3.wrote, r4.n, r4.wrote))
  else
    chk("S1b asked again for the same key and value it is refused at once, without a second check", false, NOFN)
    chk("S1c after clear_for_cell the same value is checked again, and refused again", false, NOFN)
    chk("S1d a gif or jpeg value with an escape inside is refused too, before any conversion", false, NOFN)
  end

  -- every byte that is not in the alphabet, wherever it sits
  local BAD = {
    { "ESC", "\27" }, { "BEL", "\7" }, { "CAN", "\24" }, { "SUB", "\26" }, { "NUL", "\0" },
    { "DEL", "\127" }, { "lone C1 ST", "\156" }, { "UTF-8 C1 ST", "\194\156" },
    { "!", "!" }, { "-", "-" }, { "_", "_" }, { "space", " " },
  }
  local function bad_cases()
    local passed = {}
    for _, b in ipairs(BAD) do
      local v = PNG:sub(1, 40) .. b[2] .. PNG:sub(41)
      if Image._b64_ok(v) then passed[#passed + 1] = b[1] end
    end
    return passed
  end
  if has_ok then
    local passed = bad_cases()
    chk("S2 a value with one byte outside the alphabet (12 kinds) is not base64; empty and the alphabet are",
      #passed == 0 and Image._b64_ok("") == true and Image._b64_ok(ALPHA) == true and Image._b64_ok(PNG) == true,
      "accepted: " .. table.concat(passed, ", "))
  else
    chk("S2 a value with one byte outside the alphabet (12 kinds) is not base64; empty and the alphabet are", false, NOFN)
  end

  -- whitespace comes off first (clean_b64), then the rest is checked
  local wrapped = {}
  for i = 1, #PNG, 76 do wrapped[#wrapped + 1] = PNG:sub(i, i + 75) end
  reset()
  local r5 = ask("spec_s2b", table.concat(wrapped, "\n") .. "\n", { renderer = "placeholder" })
  local tx = first_tx()
  chk("S2b a valid PNG wrapped every 76 characters is still transmitted, whitespace removed first",
    has_ok and r5.id ~= nil and tx ~= nil and payload(tx) == PNG,
    has_ok and ("id %s, transmits %d"):format(tostring(r5.id), frames_out()) or NOFN)

  -- without the FFI a pattern makes the same check
  if has_ok then
    Image._b64_ffi = false
    local passed = bad_cases()
    reset()
    local r6 = ask("spec_s3", HOSTILE)
    chk("S3 without the FFI the pattern refuses the same twelve kinds and the escape value, and passes the alphabet",
      #passed == 0 and Image._b64_ok(ALPHA) == true and Image._b64_ok("") == true
        and r6.sync and r6.id == nil and r6.wrote == 0,
      "accepted: " .. table.concat(passed, ", ") .. "; writes " .. r6.wrote)
    Image._b64_ffi = ffi0
  else
    chk("S3 without the FFI the pattern refuses the same twelve kinds and the escape value, and passes the alphabet", false, NOFN)
  end

  -- the cost of a big image, on the fast path
  if has_ok then
    local BIG = vim.base64.encode(string.rep(string.char(unpack((function()
      local t = {}; for i = 0, 255 do t[#t + 1] = i end; return t
    end)())), 16384))
    local okv = true
    local best, why = jit_timed(function()
      local b = math.huge
      for _ = 1, 3 do
        local t0 = vim.uv.hrtime()
        okv = okv and Image._b64_ok(BIG)
        b = math.min(b, (vim.uv.hrtime() - t0) / 1e6)
      end
      return b
    end)
    chk(("S4 a 5 MB value is checked in under 20 ms on the fast path (best of three %.1f ms%s)"):format(best, why),
      okv == true and best < 20, ("ok %s, %d bytes"):format(tostring(okv), #BIG))
    chk("S4b an escape as the last byte is found", Image._b64_ok(BIG:sub(1, -2) .. "\27") == false)
  else
    chk("S4 a 5 MB value is checked in under 20 ms on the fast path", false, NOFN)
    chk("S4b an escape as the last byte is found", false, NOFN)
  end

  -- a key that shows an image gets other data that is not base64 (a display
  -- handle updated with a bad value): the old image does not stay
  if has_ok then
    reset()
    local ra = ask("spec_s5", PNG)
    local old = Image._placements.spec_s5
    local old_id = old and old.image_id
    local timer = vim.uv.new_timer()
    timer:start(1000000, 1000000, function() end)
    if old then old.timer = timer end
    reset()
    local rb = ask("spec_s5", HOSTILE)
    chk("S5 a key that shows an image and gets data that is not base64 loses the old image: freed in the terminal, its clock stopped, nothing else written",
      ra.id ~= nil and old_id ~= nil and rb.sync and rb.id == nil and Image._placements.spec_s5 == nil
        and #ui_out == 1 and ui_out[1] == ("\27_Ga=d,d=I,i=%d,q=2\27\\"):format(old_id or -1)
        and timer:is_closing(),
      ("old id %s, callbacks %d (id %s), placement %s, writes %s, timer closed %s"):format(tostring(old_id), rb.n, tostring(rb.id),
        tostring(Image._placements.spec_s5), vim.inspect(ui_out), tostring(timer:is_closing())))
    -- asked again for the same bad value it is refused at once; a good value later shows again
    reset()
    local rc = ask("spec_s5", HOSTILE)
    local rd = ask("spec_s5", PNG)
    chk("S5b the refused value is still refused at once, and a valid image for the key shows again",
      rc.sync and rc.id == nil and rc.wrote == 0 and rd.id ~= nil and Image._placements.spec_s5 ~= nil,
      ("again: callbacks %d, writes %d; valid: id %s"):format(rc.n, rc.wrote, tostring(rd.id)))
  else
    chk("S5 a key that shows an image and gets data that is not base64 loses the old image: freed in the terminal, its clock stopped, nothing else written", false, NOFN)
    chk("S5b the refused value is still refused at once, and a valid image for the key shows again", false, NOFN)
  end

  Image._b64_ffi = ffi0
  for _, k in ipairs(keys) do Image.clear_for_cell(k) end
  reset()
end

-- ── B. a gif off screen ─────────────────────────────────────────────────
reset()
local visible = false
local probe_ok = pcall(Image.set_visible_probe, "spec_a", function() return visible end)
if pa then pa.frames, pa.delays = { FA, FB, FA, FB }, { 30, 30, 30, 30 } end
Image.resume_animations()
vim.wait(400)
local hidden = #ui_out + #chan_out
local skipped = Image._frames_skipped or 0
chk("B1 a gif off screen sends nothing", probe_ok and pa and pa.timer ~= nil and hidden == 0,
  hidden .. " writes while hidden")
chk("B2 its clock keeps running", skipped >= 5, "frames skipped " .. skipped)
visible = true
vim.wait(500, function() return #ui_out > 0 end, 5)
local w = nomark()[1] or ""
chk("B3 back in view the next tick sends the frame its clock is at",
  w:find("\27_Ga=t,f=100,i=" .. (id_a or -1) .. ",", 1, true) == 1
    and (payload(w) == FA or payload(w) == FB) and w:sub(-#place) == place)
Image.clear_for_cell("spec_a")
chk("B4 clearing the image drops its probe and stops its clock",
  Image.has_visible_probe and not Image.has_visible_probe("spec_a") and pa and pa.timer == nil)
do
  -- a probe registered for an image that was never sent (or already freed)
  pcall(Image.set_visible_probe, "spec_np", function() return true end)
  Image.clear_for_cell("spec_np")
  chk("B8 clearing a key that has a probe but no image drops the probe",
    Image.has_visible_probe ~= nil and not Image.has_visible_probe("spec_np"))
end
do
  local F = {}
  for i = 1, 4 do F[i] = vim.base64.encode(png(40, 30, 10 + i)) end
  Image.ensure_transmitted("spec_clk", F[1], function() end, { renderer = "placeholder" })
  local pk = Image._placements.spec_clk
  local ticks = 0
  pcall(Image.set_visible_probe, "spec_clk", function() ticks = ticks + 1; return ticks >= 7 end)
  if pk then pk.frames, pk.delays = F, { 20, 20, 20, 20 } end
  reset()
  Image.resume_animations()
  vim.wait(1000, function() return #ui_out > 0 end, 5)
  local got, gi = payload(ui_out[1]), 0
  for i = 1, 4 do if F[i] == got then gi = i end end
  chk("B5 the first frame sent back in view is the one its clock reached (tick 7, 4 frames: frame 4)",
    gi == 4, "sent frame " .. gi .. ", ticks " .. ticks)
  Image.clear_for_cell("spec_clk")
end
do
  -- a probe that fails tells nothing about the screen, so the gif plays on
  Image.ensure_transmitted("spec_err", FA, function() end, { renderer = "placeholder" })
  local pe = Image._placements.spec_err
  local set_ok = pcall(Image.set_visible_probe, "spec_err", function() error("probe failed") end)
  if pe then pe.frames, pe.delays = { FA, FB }, { 20, 20 } end
  reset()
  Image.resume_animations()
  vim.wait(1000, function() return #ui_out + #chan_out > 0 end, 5)
  chk("B6 a probe that fails counts as on screen: the gif keeps sending frames",
    set_ok and #ui_out + #chan_out > 0, (#ui_out + #chan_out) .. " writes")
  -- a playing gif places itself with every frame, so a re-assert leaves it
  -- alone even when the placements were invalidated (no frame runs in between:
  -- nothing here yields to the event loop)
  local inv9 = pcall(Image.invalidate_placements)
  reset(); Image.reassert_virtual_placements()
  chk("B9 a re-assert skips a gif that is playing", inv9 and pe and pe.timer ~= nil and #ui_out + #chan_out == 0,
    (#ui_out + #chan_out) .. " writes")
  Image.clear_for_cell("spec_err")
end
do
  -- a frame sent places the gif again (a=t plus a=p), so a re-assert after
  -- the gif stopped has nothing to place
  Image.ensure_transmitted("spec_g", FA, function() end, { renderer = "placeholder" })
  local pg = Image._placements.spec_g
  if pg then pg.frames, pg.delays = { FA, FB }, { 20, 20 } end
  local inv = pcall(Image.invalidate_placements)
  reset()
  Image.resume_animations()
  vim.wait(1000, function() return #ui_out + #chan_out > 0 end, 5)
  local sent = #ui_out + #chan_out
  Image.pause_animations()
  reset(); Image.reassert_virtual_placements()
  chk("B7 a frame sent counts as placed: paused after it, a re-assert writes nothing",
    inv and sent > 0 and #ui_out + #chan_out == 0, ("frames %d, re-asserts %d"):format(sent, #ui_out + #chan_out))
  Image.clear_for_cell("spec_g")
  Image.resume_animations()
end

-- ── C. Neovim 0.11: no nvim_ui_send ─────────────────────────────────────
ui_send_api = false; install(); ui_changed()
Image.ensure_transmitted("spec_c", PNG, function() end, { renderer = "placeholder" })
-- a heal window of seconds, so a stall of the machine during the burst of
-- ten renders below cannot start a second window
Image._heal_ms = 2000
vim.wait(2100)
reset()
for _ = 1, 10 do Image.reassert_virtual_placements(); vim.wait(10) end
local burst = #chan_out
vim.wait(3000, function() return #chan_out > burst end, 10)
vim.wait(200)
local after = #chan_out
chk("C1 without nvim_ui_send the writes go to the stderr channel", #ui_out == 0 and after > 0)
chk("C2 a burst of renders heals at most once right away", burst == 1, burst .. " heals")
chk("C3 and once more when the burst is over", after - burst == 1, (after - burst) .. " trailing heals")
pcall(Image.set_visible_probe, "spec_c", function() return false end)
vim.wait(2100)
reset(); Image.reassert_virtual_placements(); vim.wait(400)
local off = #chan_out
pcall(Image.invalidate_placements)
reset(); Image.reassert_virtual_placements()
chk("C4 an image off screen is not healed, but a lost placement is always re-asserted",
  off == 0 and #chan_out == 1, ("healed %d off screen, re-asserted %d"):format(off, #chan_out))
Image.clear_for_cell("spec_c")
Image._heal_ms = 1000

-- ── D. a terminal UI attaching later (nvim --headless, then --remote-ui) ─
-- nvim --headless never had a terminal UI; the sections above attached one
-- to this module, so that is forgotten here
ui_send_api = true; tty_ui = false; install(); Image._had_ui = false; ui_changed()
local cd = fake_client(true)
Image.attach(cd, vim.env.JUPYNVIM_TTY)
chk("D1 headless, the backend keeps writing to the tty it was given", Image._remote_mode == false)
tty_ui = true; install()
vim.api.nvim_exec_autocmds("UIEnter", {})
reset(); Image.clear_visible_placements()
chk("D2 a terminal UI attaching moves every write to nvim_ui_send",
  Image._remote_mode == true and asked(cd.async, "kitty_attach", "remote") and #ui_out == 1 and #chan_out == 0)
-- the terminal UI leaves (:detach, a --remote-ui client quitting): nobody
-- sees the screen, and the stderr channel now reaches a terminal that
-- another program draws on, so nothing is written at all
tty_ui = false; install()
vim.api.nvim_exec_autocmds("UILeave", {})
local held0 = Image._held_n or 0
reset()
Image.ensure_transmitted("spec_d", PNG, function() end, { renderer = "placeholder" })
pcall(Image.set_visible_probe, "spec_d", function() return false end)
local pd = Image._placements.spec_d
chk("D3 once the terminal UI left nothing is written, on no path, and the writes held are counted",
  pd ~= nil and #ui_out == 0 and #chan_out == 0 and (Image._held_n or 0) - held0 == 2,
  ("ui_send %d, stderr %d, held %d"):format(#ui_out, #chan_out, (Image._held_n or 0) - held0))
-- nvim_ui_send reaches only UIs with a terminal (stdout_tty): a GUI or an
-- embedding client would drop the bytes, and it shows no Kitty graphics
tty_ui = "gui"; install()
vim.api.nvim_exec_autocmds("UIEnter", {})
reset(); Image.clear_visible_placements()
chk("D5 a UI without a terminal takes no writes, and neither does the stderr channel",
  #ui_out == 0 and #chan_out == 0, ("ui_send %d, stderr %d"):format(#ui_out, #chan_out))
do
  -- a terminal UI attaches: it gets what it missed, through nvim_ui_send:
  -- the delete of the visible placements, then the image sent while held,
  -- with its placement, and nothing placed twice
  local id = tostring(pd and pd.image_id or -1)
  local place_d = pd and ("\27_Ga=p,U=1,i=%d,p=1,c=%d,r=%d,q=2\27\\"):format(pd.image_id, pd.cols, pd.rows) or "?"
  tty_ui = true; install()
  reset()
  vim.api.nvim_exec_autocmds("UIEnter", {})
  vim.wait(500, function() return #ui_out >= 2 end, 5)
  vim.wait(100)
  local tx = first_tx() or ""
  chk("D4 a terminal UI attaching sends the image held meanwhile, with its placement, through nvim_ui_send",
    pd and tx:find("\27_Ga=t,f=100,i=" .. id .. ",", 1, true) == 1 and payload(tx) == PNG
      and tx:sub(-#place_d) == place_d and #chan_out == 0
      and count(ui_out, function(s) return s:find("i=" .. id .. ",", 1, true) ~= nil end) == 1,
    ("ui_send %d, stderr %d"):format(#ui_out, #chan_out))
  chk("D6 and the delete it missed, first", ui_out[1] == "\27_Ga=d,d=a,q=2\27\\" and #ui_out == 2,
    vim.inspect(ui_out):sub(1, 200))
  Image.clear_for_cell("spec_d")
end

-- ── E. a real notebook ──────────────────────────────────────────────────
tty_ui = true; install(); ui_changed()
local J      = require("jupynvim")
local NB     = require("jupynvim.notebook")
local Render = require("jupynvim.notebook.render")
local CellMode = require("jupynvim.notebook.cellmode")
J.setup({ log_level = "warn", image_renderer = "placeholder" })
vim.notify = function() end

local function out_png(b64)
  return { output_type = "display_data", metadata = vim.empty_dict(),
           data = { ["image/png"] = b64, ["text/plain"] = "<Figure>" } }
end
local long = {}
for i = 1, 60 do long[i] = ("v%d = %d"):format(i, i) end
local cells = {
  { cell_type = "code", id = "e1", metadata = vim.empty_dict(), source = "plot(1)", execution_count = 1,
    outputs = { out_png(PNG) } },
  { cell_type = "code", id = "e2", metadata = vim.empty_dict(), source = table.concat(long, "\n"),
    execution_count = vim.NIL, outputs = {} },
  { cell_type = "code", id = "e3", metadata = vim.empty_dict(), execution_count = 3,
    source = "a = 3\nb = a + 1\nc = b * 2\nd = c - 1\nplot(3)",
    outputs = { out_png(FA) } },
  { cell_type = "markdown", id = "e4", metadata = vim.empty_dict(),
    source = "a gif ![g](data:image/gif;base64," .. GIF1 .. ")" },
}
for i = 5, 300 do
  cells[i] = { cell_type = "code", id = "e" .. i, metadata = vim.empty_dict(), source = "x = " .. i,
               execution_count = vim.NIL, outputs = {} }
end
local path = tmp .. "/stream.ipynb"
local f = io.open(path, "w")
f:write(vim.json.encode({ cells = cells, nbformat = 4, nbformat_minor = 5,
  metadata = { kernelspec = { name = "python3", display_name = "P", language = "python" } } }))
f:close()
local buf = J.open(path)
vim.wait(5000, function() return NB.get(buf) ~= nil end, 20)
vim.api.nvim_set_current_buf(buf)
local nb = NB.get(buf)
local win = vim.fn.bufwinid(buf)
local function okey(i) return Image.output_key(Image.output_owner(buf, nb.cells[i].id), 1) end
vim.wait(5000, function() return Image._placements[okey(1)] ~= nil and Image._placements[okey(3)] ~= nil end, 20)
vim.wait(300)
Render.refresh_sync(nb, win)
chk("E1 opened with a terminal UI, the escapes are encoded here", Image._remote_mode == true)

local on = Render.output_on_screen
local c1, c3 = nb.cells[1].id, nb.cells[3].id
vim.api.nvim_win_call(win, function() vim.fn.winrestview({ lnum = 1, col = 0, topline = 1, topfill = 0 }) end)
chk("E2 at the top the first cell's image is on screen and the third's is not",
  on and on(nb, c1) == true and on(nb, c3) == false)
local r3 = CellMode.ranges(buf)[3]
vim.api.nvim_win_call(win, function() vim.fn.winrestview({ lnum = r3.start + 1, col = 0, topline = r3.start + 1, topfill = 0 }) end)
chk("E3 scrolled to the third cell it is the other way round",
  on and on(nb, c1) == false and on(nb, c3) == true)
do
  local r1x = CellMode.ranges(buf)[1]
  local a1 = math.max(r1x.stop, r1x.start + 1)
  local tf = vim.api.nvim_win_call(win, function()
    vim.fn.winrestview({ lnum = a1 + 1, col = 0, topline = a1 + 1, topfill = 8 })
    return vim.fn.winsaveview().topfill
  end)
  local w0 = vim.fn.line("w0", win)
  chk("E9 image rows left at the top after the cell's last line scrolled off are on screen",
    on and tf > 0 and w0 == a1 + 1 and on(nb, c1) == true,
    ("anchor %d w0 %d topfill %d on %s"):format(a1, w0, tf, tostring(on and on(nb, c1))))
  -- scrolled one row further: no filler left, the image rows are all above
  local tf0 = vim.api.nvim_win_call(win, function()
    vim.fn.winrestview({ lnum = a1 + 1, col = 0, topline = a1 + 1, topfill = 0 })
    return vim.fn.winsaveview().topfill
  end)
  chk("E15 once the image rows under a cell scrolled off the top too, they are off screen",
    on and tf0 == 0 and vim.fn.line("w0", win) == a1 + 1 and on(nb, c1) == false,
    ("anchor %d w0 %d topfill %d on %s"):format(a1, vim.fn.line("w0", win), tf0, tostring(on and on(nb, c1))))
end
local function show_c3()
  vim.api.nvim_win_call(win, function() vim.fn.winrestview({ lnum = r3.start + 1, col = 0, topline = r3.start + 1, topfill = 0 }) end)
end
do
  -- the image hangs under the cell's LAST source line: with the first three of
  -- its five lines scrolled off the top, the rest of the cell and its image show
  vim.api.nvim_win_call(win, function() vim.fn.winrestview({ lnum = r3.start + 4, col = 0, topline = r3.start + 4, topfill = 0 }) end)
  local w0 = vim.fn.line("w0", win)
  chk("E12 an image under a cell whose first lines scrolled off the top is on screen",
    on and r3.stop - r3.start == 5 and w0 == r3.start + 4 and on(nb, c3) == true,
    ("lines %d, w0 %d, first line %d, on %s"):format(r3.stop - r3.start, w0, r3.start + 1, tostring(on and on(nb, c3))))
end
do
  -- another window of this tab page has the cursor; the notebook still shows
  show_c3()
  local sbuf = vim.api.nvim_create_buf(false, true)
  local other = vim.api.nvim_open_win(sbuf, true, { split = "below", win = win })
  chk("E11 images in a notebook window that is not the current window are on screen",
    on and vim.api.nvim_get_current_win() == other and on(nb, c3) == true and on(nb, c1) == false)
  vim.api.nvim_win_close(other, true)
  pcall(vim.api.nvim_buf_delete, sbuf, { force = true })
  vim.api.nvim_set_current_win(win)
end
show_c3()
local in_own_tab = on and on(nb, c3)
vim.cmd("tabnew")
chk("E4 a notebook shown only in another tab page is off screen",
  on and in_own_tab == true and on(nb, c3) == false,
  ("in its own tab page %s, from another %s"):format(tostring(in_own_tab), tostring(on and on(nb, c3))))
vim.cmd("tabclose")
vim.api.nvim_set_current_win(win)

chk("E5 every image output and markdown image has a probe",
  Image.has_visible_probe ~= nil and Image.has_visible_probe(okey(1)) and Image.has_visible_probe(okey(3))
    and Image.has_visible_probe(nb.cells[4].id .. "_md_1"))

-- count what still goes to the backend too
local kitty_rpc = 0
local cl = J.client
local orig_call, orig_sync = cl.call, cl.call_sync
cl.call = function(self, m, ...) if m:find("^kitty_") then kitty_rpc = kitty_rpc + 1 end return orig_call(self, m, ...) end
cl.call_sync = function(self, m, ...) if m:find("^kitty_") then kitty_rpc = kitty_rpc + 1 end return orig_sync(self, m, ...) end
reset()
for _ = 1, 5 do Render.refresh_sync(nb, win) end
vim.api.nvim_win_set_cursor(win, { r3.start + 1, 0 })
CellMode.enter_edit(buf)
vim.wait(100)
vim.api.nvim_buf_set_text(buf, r3.start, 0, r3.start, 0, { "x" })
vim.api.nvim_exec_autocmds("TextChangedI", { buffer = buf })
vim.wait(300)
chk("E6 renders and an insert-mode edit write no graphics when nothing changed",
  #ui_out + #chan_out + kitty_rpc == 0,
  ("ui_send %d, stderr %d, backend %d"):format(#ui_out, #chan_out, kitty_rpc))
cl.call, cl.call_sync = orig_call, orig_sync
-- what a call costs: cost_us (top of the file)
local rus, rwhy = cost_us(1000, function() Image.reassert_virtual_placements() end)
chk(("E8 a render's placement check costs under 50 us when nothing changed (%.1f us%s)"):format(rus, rwhy), rus < 50)

if on then
  local last = nb.cells[300].id
  local us, why = cost_us(2000, function() on(nb, last) end)
  chk(("E7 the on-screen probe of a 300-cell notebook costs under 100 us (%.1f us%s)"):format(us, why), us < 100)
else
  chk("E7 the on-screen probe exists", false)
end
local probe_keys = { okey(1), okey(3), nb.cells[4].id .. "_md_1" }
pcall(vim.api.nvim_buf_delete, buf, { force = true })
vim.wait(100)
local kept = {}
for _, k in ipairs(probe_keys) do
  if Image.has_visible_probe and Image.has_visible_probe(k) then kept[#kept + 1] = k end
end
-- a probe holds the notebook it looks at, so one left behind keeps it alive
chk("E10 closing the notebook drops its probes", Image.has_visible_probe ~= nil and #kept == 0,
  #kept .. " left")

do
  -- two copies of one notebook hold the same cell ids, so a markdown image
  -- (keyed by its cell id) has one key and one probe for both
  local mcells = { { cell_type = "markdown", id = "mdcopy", metadata = vim.empty_dict(),
                     source = "# t\n\n![g](data:image/gif;base64," .. GIF1 .. ")" } }
  for i = 2, 4 do
    mcells[i] = { cell_type = "code", id = "mc" .. i, metadata = vim.empty_dict(), source = table.concat(long, "\n"),
                  execution_count = vim.NIL, outputs = {} }
  end
  local json = vim.json.encode({ cells = mcells, nbformat = 4, nbformat_minor = 5,
    metadata = { kernelspec = { name = "python3", display_name = "P", language = "python" } } })
  local function write(p) local fh = io.open(p, "w"); fh:write(json); fh:close() end
  local pa, pb = tmp .. "/mdA.ipynb", tmp .. "/mdB.ipynb"
  write(pa); write(pb)
  local key = "mdcopy_md_1"
  -- (guarded: the tree before this feature has no probes at all)
  local function onscr(k) return Image._on_screen and Image._on_screen(k) end
  local function open(p)
    local b = J.open(p)
    vim.wait(5000, function() return NB.get(b) ~= nil end, 20)
    vim.api.nvim_set_current_buf(b)
    Render.refresh_sync(NB.get(b), vim.api.nvim_get_current_win())
    return b
  end
  local ba = open(pa)
  local had = Image.has_visible_probe ~= nil and Image.has_visible_probe(key)
  local bb = open(pb)  -- the first copy stays loaded, in no window ('hidden')
  local w = vim.api.nvim_get_current_win()
  vim.api.nvim_win_call(w, function() vim.fn.winrestview({ lnum = 1, col = 0, topline = 1, topfill = 0 }) end)
  chk("E13 a markdown image shown only by a second copy of its notebook is on screen",
    had and vim.api.nvim_buf_is_loaded(ba) and vim.fn.bufwinid(ba) == -1 and NB.get(ba) ~= nil
      and onscr(key) == true,
    ("probe %s, first copy in a window %s, on %s"):format(tostring(had), tostring(vim.fn.bufwinid(ba)),
      tostring(onscr(key))))
  local rb = CellMode.ranges(bb)[3]
  vim.api.nvim_win_call(w, function() vim.fn.winrestview({ lnum = rb.start + 1, col = 0, topline = rb.start + 1, topfill = 0 }) end)
  local away = onscr(key)
  vim.api.nvim_win_call(w, function() vim.fn.winrestview({ lnum = 1, col = 0, topline = 1, topfill = 0 }) end)
  chk("E13b and off screen once that copy scrolled away from it", away == false)
  -- the boxed editor of a markdown cell draws no markdown images
  vim.api.nvim_win_set_cursor(w, { 1, 0 })
  CellMode.enter_edit(bb)
  local editing = onscr(key)
  CellMode.enter_command(bb)
  local after_edit = onscr(key)
  chk("E14 a markdown cell open in the boxed editor shows no image, so its gif sends nothing",
    editing == false and after_edit == true,
    ("editing %s, after %s"):format(tostring(editing), tostring(after_edit)))
  pcall(vim.api.nvim_buf_delete, bb, { force = true })
  pcall(vim.api.nvim_buf_delete, ba, { force = true })
  vim.wait(100)
end

-- ── E, continued: the rows of an image decide, not only its cell's last line ──
-- The image rows are virtual lines under the cell's last source line, so a gif
-- is out of view when that line is on the window's last rows, or when a plot
-- above it in the same cell fills the rest, or when the top filler shows only
-- what comes after it. The expected values are worked out here from the
-- cell's extmark (which of its virtual lines hold the placeholders of an
-- image) and from where Neovim puts the anchor line, not from the module's
-- own record of the rows.
do
  local function out_img(b64) return { output_type = "display_data", metadata = vim.empty_dict(), data = { ["image/png"] = b64 } } end
  local mcells = {}
  local function add(c) c.metadata = vim.empty_dict(); mcells[#mcells + 1] = c end
  for i = 1, 8 do add({ cell_type = "code", id = "xa" .. i, source = "pre = " .. i, execution_count = vim.NIL, outputs = {} }) end
  add({ cell_type = "code", id = "xs", source = "anim()", execution_count = 1, outputs = { out_img(FB) } })
  add({ cell_type = "code", id = "xk", source = "plot_then_anim()", execution_count = 2, outputs = { out_img(PNG), out_img(FA) } })
  add({ cell_type = "code", id = "xw", source = "w = '" .. string.rep("w", 150) .. "'", execution_count = 3, outputs = { out_img(FB) } })
  add({ cell_type = "code", id = "xp", source = "plain = 1", execution_count = vim.NIL, outputs = {} })
  add({ cell_type = "markdown", id = "xm", source = "![m](data:image/png;base64," .. PNG .. ")" })
  for i = 1, 40 do add({ cell_type = "code", id = "xz" .. i, source = "post = " .. i, execution_count = vim.NIL, outputs = {} }) end
  local mpath = tmp .. "/edge.ipynb"
  local fh = io.open(mpath, "w")
  fh:write(vim.json.encode({ cells = mcells, nbformat = 4, nbformat_minor = 5,
    metadata = { kernelspec = { name = "python3", display_name = "P", language = "python" } } }))
  fh:close()
  -- one window on the notebook, whatever the sections above left behind
  vim.cmd("silent! tabonly | silent! only")
  local mbuf = J.open(mpath)
  vim.wait(5000, function() return NB.get(mbuf) ~= nil end, 20)
  vim.api.nvim_set_current_buf(mbuf)
  local mnb = NB.get(mbuf)
  local mwin = vim.api.nvim_get_current_win()
  local function mkey(cid, n)
    for _, c in ipairs(mnb.cells) do
      if c.id == cid then return Image.output_key(Image.output_owner(mbuf, c.id), n) end
    end
  end
  local keys = { mkey("xs", 1), mkey("xk", 1), mkey("xk", 2), mkey("xw", 1), "xm_md_1" }
  vim.wait(8000, function()
    for _, k in ipairs(keys) do if not Image._placements[k] then return false end end
    return true
  end, 20)
  vim.wait(300)
  Render.refresh_sync(mnb, mwin)
  local function idx_of(cid) for i, c in ipairs(mnb.cells) do if c.id == cid then return i end end end
  local PH = vim.fn.nr2char(0x10EEEE)
  -- the anchor line, the number of virtual lines under it, and the runs of
  -- them that hold placeholders: { off (0-based), rows } per image
  local function layout(cid)
    local r = CellMode.ranges(mbuf)[idx_of(cid)]
    local anchor = math.max(r.stop, r.start + 1)
    local marks = vim.api.nvim_buf_get_extmarks(mbuf, mnb.border_ns, { anchor - 1, 0 }, { anchor - 1, -1 }, { details = true })
    for _, m in ipairs(marks) do
      local d = m[4]
      if d.virt_lines and not d.virt_lines_above and #d.virt_lines > 1 then
        local runs, cur = {}, nil
        for i, vl in ipairs(d.virt_lines) do
          local txt = ""
          for _, ch in ipairs(vl) do txt = txt .. ch[1] end
          if txt:find(PH, 1, true) then
            if not cur then cur = { off = i - 1, rows = 0 }; runs[#runs + 1] = cur end
            cur.rows = cur.rows + 1
          else
            cur = nil
          end
        end
        return anchor, #d.virt_lines, runs
      end
    end
  end
  local h = vim.api.nvim_win_get_height(mwin)
  local wi0 = vim.fn.getwininfo(mwin)[1]
  local first_row = wi0.winrow + wi0.winbar
  -- Where the anchor's first text row is in the window (1 is the top), nil when
  -- it is not in view. line("w$") makes Neovim validate the view first.
  local function anchor_row(anchor)
    vim.fn.line("w$", mwin)
    local sp = vim.fn.screenpos(mwin, anchor, 1)
    return sp.row > 0 and (sp.row - first_row + 1) or nil
  end
  local function scroll(key) vim.api.nvim_win_call(mwin, function() vim.cmd("normal! " .. key) end) end
  local CTRL_E, CTRL_Y = "\5", "\25"
  -- Scroll so that the anchor's first text row is window row `row`: a row at
  -- a time with CTRL-E and CTRL-Y, as a wheel does, which goes through the
  -- filler rows of the virtual lines one by one. Neovim itself keeps the view
  -- valid that way (a topfill set by winrestview is taken back when it is
  -- larger than the filler there is).
  local function anchor_at(anchor, row)
    vim.api.nvim_win_call(mwin, function()
      vim.fn.winrestview({ lnum = anchor, col = 0, topline = math.max(1, anchor - 8), topfill = 0 })
    end)
    for _ = 1, 4 * h do
      local r = anchor_row(anchor)
      if r == row then return true end
      if r == nil then scroll(vim.fn.line("w0", mwin) > anchor and CTRL_Y or CTRL_E)
      else scroll(r > row and CTRL_E or CTRL_Y) end
    end
    return false
  end
  -- Scroll so that the anchor line has just left the top, with `tf` rows of
  -- filler above the line after it (CTRL-Y from there). Returns the topfill
  -- the view has, and the top line.
  local function topfill_at(anchor, tf)
    vim.api.nvim_win_call(mwin, function()
      vim.fn.winrestview({ lnum = anchor + 1, col = 0, topline = anchor + 1, topfill = 0 })
    end)
    for _ = 1, tf do scroll(CTRL_Y) end
    vim.fn.line("w$", mwin)
    return vim.api.nvim_win_call(mwin, function() return vim.fn.winsaveview().topfill end), vim.fn.line("w0", mwin)
  end
  -- rows of virtual lines above line `lnum`
  local function above_rows(lnum)
    local n = 0
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(mbuf, -1, { lnum - 1, 0 }, { lnum - 1, -1 }, { details = true })) do
      if m[4].virt_lines and m[4].virt_lines_above then n = n + #m[4].virt_lines end
    end
    return n
  end
  local function seen(key) return Image._on_screen and Image._on_screen(key) end
  local function bad_list(t) return #t == 0 and "" or table.concat(t, "; ") end

  local anc_s, n_s, run_s = layout("xs")
  local anc_k, n_k, run_k = layout("xk")
  local anc_w, n_w, run_w = layout("xw")
  local anc_m, n_m, run_m = layout("xm")
  chk("M0 the layout is what the checks below assume: a gif after a plot, one row of filler after each cell's images",
    run_s and #run_s == 1 and run_k and #run_k == 2 and run_w and #run_w == 1 and run_m and #run_m == 1
      and run_k[2].off > run_k[1].off + run_k[1].rows and n_k > run_k[2].off + run_k[2].rows,
    vim.inspect({ s = run_s, k = run_k, w = run_w, m = run_m }))
  local spans_ok = true
  for _, e in ipairs({ { "xs", mkey("xs", 1), run_s and run_s[1] }, { "xk", mkey("xk", 1), run_k and run_k[1] },
                       { "xk", mkey("xk", 2), run_k and run_k[2] }, { "xm", "xm_md_1", run_m and run_m[1] } }) do
    local sp = mnb.image_spans and mnb.image_spans[e[1]] and mnb.image_spans[e[1]].keys[e[2]]
    if not (sp and e[3] and sp.off == e[3].off and sp.rows == e[3].rows) then spans_ok = false end
  end
  chk("M0b the rows recorded where the lines are built are the rows that hold the placeholders", spans_ok,
    vim.inspect(mnb.image_spans and mnb.image_spans.xk))

  if run_s and run_k and run_k[2] and run_w and run_m then
    -- bottom edge, one image: the cell's last line on the last row, the one above, and the third from the bottom
    local bad = {}
    for _, row in ipairs({ h, h - 1, h - 2, h - 3 }) do
      if not anchor_at(anc_s, row) then bad[#bad + 1] = "row " .. row .. " unreachable"
      else
        local want = run_s[1].off < h - row
        local got = seen(keys[1])
        if got ~= want then bad[#bad + 1] = ("anchor on row %d of %d: %s, want %s"):format(row, h, tostring(got), tostring(want)) end
      end
    end
    chk("M1 an image whose cell's last line is on the window's last rows is off screen; with one row in view it is on",
      #bad == 0, bad_list(bad))

    -- a plot, then a gif: the gif hangs below the window for as long as the plot is tall
    bad = {}
    local plot, gif = run_k[1], run_k[2]
    for _, row in ipairs({ 3, 8, h - gif.off - 2, h - gif.off - 1, h - gif.off, h - 2, h - 1, h }) do
      if row >= 1 and row <= h then
        if not anchor_at(anc_k, row) then bad[#bad + 1] = "row " .. row .. " unreachable"
        else
          for n, run in ipairs({ plot, gif }) do
            local want, got = run.off < h - row, seen(keys[1 + n])
            if got ~= want then bad[#bad + 1] = ("anchor row %d: image %d %s, want %s"):format(row, n, tostring(got), tostring(want)) end
          end
        end
      end
    end
    chk("M2 a gif after a plot is off screen while it hangs below the window, on once its first row shows (own probe per image)",
      #bad == 0, bad_list(bad))

    -- the anchor line wraps: its last text row is what counts
    bad = {}
    local line_w = vim.fn.strdisplaywidth(vim.api.nvim_buf_get_lines(mbuf, anc_w - 1, anc_w, false)[1])
    local text_w = vim.api.nvim_win_get_width(mwin) - vim.fn.getwininfo(mwin)[1].textoff
    local wrap_rows = math.ceil(line_w / text_w)
    for _, row in ipairs({ h - 4, h - 3, h - 2, h - 1 }) do
      if anchor_at(anc_w, row) then
        local want = run_w[1].off < h - (row + wrap_rows - 1)
        local got = seen(keys[4])
        if got ~= want then bad[#bad + 1] = ("first text row %d (%d rows): %s, want %s"):format(row, wrap_rows, tostring(got), tostring(want)) end
      else
        bad[#bad + 1] = "row " .. row .. " unreachable"
      end
    end
    chk("M3 a wrapped last line counts all its rows (here " .. wrap_rows .. ")", #bad == 0 and wrap_rows >= 2, bad_list(bad))

    -- the top filler: the end of the cell's virtual lines, then the next cell's top border
    bad = {}
    local above_next = above_rows(anc_k + 1)
    local nfill = n_k + above_next
    for _, tf in ipairs({ 1, 2, 3, gif.rows + 3, gif.rows + 4, gif.rows + 5 }) do
      local got_tf, w0 = topfill_at(anc_k, tf)
      if w0 ~= anc_k + 1 or got_tf ~= tf then
        bad[#bad + 1] = ("topfill %d unreachable (got %d)"):format(tf, got_tf)
      else
        for n, run in ipairs({ plot, gif }) do
          local want = run.off + run.rows > nfill - got_tf
          local got = seen(keys[1 + n])
          if got ~= want then bad[#bad + 1] = ("topfill %d: image %d %s, want %s"):format(tf, n, tostring(got), tostring(want)) end
        end
      end
    end
    chk("M4 the top filler shows an image only when it reaches one of its rows (a later image or the border after it does not)",
      #bad == 0, bad_list(bad))

    -- virtual lines another plugin put above the top line stand in the top
    -- filler after the cell's own lines, so fewer of the cell's rows show
    bad = {}
    local ns_up = vim.api.nvim_create_namespace("spec_foreign_up")
    vim.api.nvim_buf_set_extmark(mbuf, ns_up, anc_k, 0, {
      virt_lines = { { { "u1", "Normal" } }, { { "u2", "Normal" } } }, virt_lines_above = true })
    local above_up = above_rows(anc_k + 1)
    local nfill_up = n_k + above_up
    for _, tf in ipairs({ 2, 3, 4, 5 }) do
      local got_tf, w0 = topfill_at(anc_k, tf)
      if w0 ~= anc_k + 1 or got_tf ~= tf then
        bad[#bad + 1] = ("topfill %d unreachable (got %d)"):format(tf, got_tf)
      else
        local want = gif.off + gif.rows > nfill_up - got_tf
        local got = seen(keys[3])
        if got ~= want then bad[#bad + 1] = ("topfill %d: gif %s, want %s"):format(tf, tostring(got), tostring(want)) end
      end
    end
    vim.api.nvim_buf_clear_namespace(mbuf, ns_up, 0, -1)
    chk("M4b virtual lines above the top line stand in the top filler: with two of them the cell's last rows show from the fourth filler row on",
      #bad == 0 and above_up == 2, bad_list(bad) .. (above_up ~= 2 and ("; " .. above_up .. " rows above") or ""))

    -- a markdown image: its rows are the first virtual lines
    bad = {}
    local mimg = run_m[1]
    for _, row in ipairs({ h, h - 1, h - 2 }) do
      if not anchor_at(anc_m, row) then bad[#bad + 1] = "row " .. row .. " unreachable"
      else
        local want = mimg.off < h - row
        local got = seen("xm_md_1")
        if got ~= want then bad[#bad + 1] = ("anchor row %d: %s, want %s"):format(row, tostring(got), tostring(want)) end
      end
    end
    local nfill_m = n_m + above_rows(anc_m + 1)
    for _, tf in ipairs({ 1, 2, 3, 4 }) do
      local got_tf, w0 = topfill_at(anc_m, tf)
      if got_tf == tf and w0 == anc_m + 1 then
        local want = mimg.off + mimg.rows > nfill_m - got_tf
        local got = seen("xm_md_1")
        if got ~= want then bad[#bad + 1] = ("topfill %d: %s, want %s"):format(tf, tostring(got), tostring(want)) end
      end
    end
    chk("M5 a markdown image follows the same rule at the bottom edge and under the top filler", #bad == 0, bad_list(bad))

    -- virtual lines of another plugin on the anchor line only push the rows
    -- down: a gif that could be in view is never taken for hidden
    bad = {}
    local ns_other = vim.api.nvim_create_namespace("spec_foreign")
    vim.api.nvim_buf_set_extmark(mbuf, ns_other, anc_s - 1, 0, {
      virt_lines = { { { "d1", "Normal" } }, { { "d2", "Normal" } }, { { "d3", "Normal" } } } })
    if anchor_at(anc_s, h - 2) and not seen(keys[1]) then bad[#bad + 1] = "bottom: a visible gif taken for hidden" end
    local _, n_f, run_f = layout("xs")
    local tfs, w0s = topfill_at(anc_s, 3)
    if tfs == 3 and w0s == anc_s + 1 and not seen(keys[1]) then bad[#bad + 1] = "top: a visible gif taken for hidden" end
    vim.api.nvim_buf_clear_namespace(mbuf, ns_other, 0, -1)
    chk("M6 other virtual lines under the anchor never make a gif that could be in view count as hidden", #bad == 0, bad_list(bad))

    -- the tick sends nothing for a gif whose rows are out of view, and plays it once they show
    local pk = Image._placements[keys[1]]
    if pk then pk.frames, pk.delays = { FA, FB }, { 20, 20 } end
    Image.resume_animations()
    anchor_at(anc_s, h)
    reset()
    vim.wait(400)
    local hidden_n = frames_out()
    anchor_at(anc_s, h - 3)
    vim.wait(600, function() return frames_out() > 0 end, 5)
    local shown_n = frames_out()
    chk("M7 a gif whose cell's last line is on the last row sends no frame; with its rows in view it does",
      pk ~= nil and hidden_n == 0 and shown_n > 0, ("hidden %d frames, in view %d"):format(hidden_n, shown_n))
    Image.pause_animations()

    -- the cost of the probe for a cell in view
    anchor_at(anc_k, 10)
    local us, why = cost_us(2000, function() seen(keys[3]) end)
    chk(("M8 the probe of a cell in view costs under 100 us (%.1f us%s)"):format(us, why), us < 100)

    -- A floating window with a top border: getwininfo().winrow is the
    -- border's row but screenpos() gives text rows, so the window's first
    -- text row comes after the border (and a winbar). The notebook is shown
    -- in the float alone. The first text row is worked out from the config
    -- the float was opened with (row 1 is screen row 2, then the border and
    -- the winbar), and what is expected comes from the screen grid itself:
    -- whether a placeholder cell is drawn in the float's text rows.
    do
      local scratch = vim.api.nvim_create_buf(false, true)
      local main_win, main_h, main_first = mwin, h, first_row
      vim.api.nvim_win_set_buf(main_win, scratch)
      local function grid_rows(top, nrows)
        local n = 0
        for r = top, top + nrows - 1 do
          for c = 1, vim.o.columns do
            if vim.fn.screenstring(r, c):find(PH, 1, true) then n = n + 1; break end
          end
        end
        return n
      end
      local variants = {
        { "rounded", false, 1 }, { "single", false, 1 }, { "rounded", true, 1 }, { "none", false, 0 },
        { "shadow", false, 0 }, { { "", "", "", "|", "", "", "", "|" }, false, 0 },
        { { "", "-", "", "", "", "-", "", "" }, true, 1 },
        { { " ", "", " ", "", " ", "", " ", "" }, false, 0 },   -- corners only: no top edge
        { { { "+", "Normal" }, { "-", "Normal" }, "+", "|", "+", "-", "+", "|" }, false, 1 },
      }
      local bad, seen_rows = {}, 0
      for _, v in ipairs(variants) do
        local label = (type(v[1]) == "string" and v[1] or "list") .. (v[2] and "+winbar" or "")
        local ok, fw = pcall(vim.api.nvim_open_win, mbuf, false,
          { relative = "editor", row = 1, col = 2, width = 70, height = 16, border = v[1] })
        if not ok then
          bad[#bad + 1] = label .. ": " .. tostring(fw)
        else
          if v[2] then vim.api.nvim_set_option_value("winbar", "bar", { win = fw, scope = "local" }) end
          vim.cmd("redraw!")
          local wi = vim.fn.getwininfo(fw)[1]
          mwin, h, first_row = fw, wi.height, 2 + v[3] + wi.winbar
          for _, row in ipairs({ h, h - 1, h - 2, h - 3 }) do
            if not anchor_at(anc_s, row) then
              bad[#bad + 1] = ("%s: row %d unreachable"):format(label, row)
            else
              vim.cmd("redraw")
              local want = run_s[1].off < h - row
              local got = seen(keys[1])
              local on_grid = grid_rows(first_row, h)
              seen_rows = seen_rows + on_grid
              if got ~= want or (on_grid > 0) ~= want then
                bad[#bad + 1] = ("%s: anchor on row %d of %d: probe %s, grid shows %d image rows, want %s"):format(
                  label, row, h, tostring(got), on_grid, tostring(want))
              end
            end
          end
          mwin, h, first_row = main_win, main_h, main_first
          vim.api.nvim_win_close(fw, true)
        end
      end
      vim.api.nvim_win_set_buf(main_win, mbuf)
      pcall(vim.api.nvim_buf_delete, scratch, { force = true })
      chk("M9 in a floating window with a top border (and a winbar) the probe counts the same rows as the screen shows: a gif whose first row is on the last text row is on screen",
        #bad == 0 and seen_rows > 0, bad_list(bad) .. (seen_rows > 0 and "" or "; no image row ever on the grid"))
    end
  else
    chk("M1 an image whose cell's last line is on the window's last rows is off screen; with one row in view it is on", false, "no layout")
  end
  pcall(vim.api.nvim_buf_delete, mbuf, { force = true })
  vim.wait(100)
  Image.resume_animations()
  reset()
end

-- ── G. :JupynvimRenderStats shows where the writes went ────────────────
local note
vim.notify = function(m) note = tostring(m) end
Image._frames_skipped = (Image._frames_skipped or 0) + 1
-- a counter still at 0 here would pass the reset check whatever the command
-- does, so those get a value; the ones checked to be counted below keep theirs
for _, k in ipairs({ "_tty_n", "_tty_bytes", "_ui_send_bytes", "_frames_held", "_acks_got", "_ack_timeouts",
                     "_held_bytes", "_resent_n", "_marks_sent", "_marks_got", "_marks_lost" }) do
  if (Image[k] or 0) == 0 then Image[k] = 1 end
end
pcall(vim.cmd, "JupynvimRenderStats")
-- nothing reset the counters before: the writes and frames above are in them
local n_ui = tonumber(note and note:match("through nvim_ui_send: (%d+)") or "")
local n_sent = tonumber(note and note:match("gif frames: (%d+) sent") or "")
local n_place = tonumber(note and note:match("placement re%-asserts: (%d+)") or "")
local n_held = tonumber(note and note:match("held while no terminal showed the editor: (%d+) writes") or "")
local n_asked = tonumber(note and note:match("terminal answers: %d+ of (%d+) asked") or "")
local m_got, m_sent, m_lost = (note or ""):match("markers: (%d+) of (%d+) answered, (%d+) given up")
-- reset: to 0, but for the requests and a marker still on their way, which
-- count in the next period (G3)
local function after_reset(k)
  local a = Image._acks_info and Image._acks_info() or {}
  if k == "_acks_sent" then return a.n or 0 end
  if k == "_marks_sent" then return (a.mark or 0) > 0 and 1 or 0 end
  return 0
end
local all_reset = true
for _, k in ipairs({ "_ui_send_n", "_ui_send_bytes", "_frames_sent", "_place_writes", "_tty_n", "_tty_bytes",
                     "_frames_held", "_acks_sent", "_acks_got", "_ack_timeouts", "_held_n", "_held_bytes",
                     "_resent_n", "_marks_sent", "_marks_got", "_marks_lost" }) do
  if (Image[k] or 0) ~= after_reset(k) then all_reset = false end
end
chk("G1 :JupynvimRenderStats reports nvim_ui_send writes, gif frames, held writes and the terminal's answers, then resets them all",
  note and note:find("through nvim_ui_send:", 1, true) and note:find("skipped out of view or while no terminal showed the editor", 1, true)
    and note:find("placement re-asserts:", 1, true) and note:find("skipped waiting for the terminal", 1, true)
    and m_got and m_sent and m_lost and tonumber(m_sent) > 0 and tonumber(m_got) > 0
    and Image._frames_skipped == 0
    and n_ui and n_ui > 0 and n_sent and n_sent > 0 and n_place and n_place > 0
    and n_held and n_held > 0 and n_asked and n_asked > 0 and all_reset, note)
do
  -- every counter is printed with the value it had (byte counts in whole
  -- KB), then reset: each gets a value no other line of the report can have
  local vals = {
    { "_tty_n", 9101 }, { "_tty_bytes", 9102, true }, { "_ui_send_n", 9103 }, { "_ui_send_bytes", 9104, true },
    { "_frames_sent", 9105 }, { "_frames_skipped", 9106 }, { "_frames_held", 9107 }, { "_acks_sent", 9108 },
    { "_acks_got", 9109 }, { "_ack_timeouts", 9110 }, { "_place_writes", 9111 }, { "_held_n", 9112 },
    { "_held_bytes", 9113, true }, { "_resent_n", 9114 }, { "_marks_sent", 9115 }, { "_marks_got", 9116 },
    { "_marks_lost", 9117 },
  }
  for _, v in ipairs(vals) do Image[v[1]] = v[3] and v[2] * 1024 or v[2] end
  Render._render_n = 0
  note = nil
  pcall(vim.cmd, "JupynvimRenderStats")
  local unshown, kept = {}, {}
  for _, v in ipairs(vals) do
    if not (note and note:find("%f[%d]" .. v[2] .. "%f[%D]")) then unshown[#unshown + 1] = v[1] end
    if (Image[v[1]] or 0) ~= after_reset(v[1]) then kept[#kept + 1] = v[1] end
  end
  chk("G2 :JupynvimRenderStats prints every counter with its value, the bytes through nvim_ui_send too, then resets each",
    note ~= nil and #unshown == 0 and #kept == 0
      and note:find("markers: 9116 of 9115 answered, 9117 given up", 1, true) ~= nil,
    ("not printed: %s; not reset: %s; report: %s"):format(table.concat(unshown, " "), table.concat(kept, " "),
      tostring(note)))
end
do
  -- the gif frames that waited for a quiet screen (Neovim 0.11, section Q)
  -- are printed with their count and reset like the others
  Image._frames_quiet = 9118
  note = nil
  pcall(vim.cmd, "JupynvimRenderStats")
  chk("G4 :JupynvimRenderStats names the gif frames that waited for a quiet screen with their count, then resets it",
    note ~= nil and note:find("%f[%d]9118 waited for a quiet screen") ~= nil and (Image._frames_quiet or 0) == 0,
    ("count after: %s; report: %s"):format(tostring(Image._frames_quiet), tostring(note)))
end
vim.notify = function() end

-- ── H. no terminal shows the editor: a gif in view sends nothing ─────────
tty_ui = true; ui_send_api = true; install(); ui_changed()
do
  Image.ensure_transmitted("spec_h", FA, function() end, { renderer = "placeholder" })
  local ph = Image._placements.spec_h
  pcall(Image.set_visible_probe, "spec_h", function() return true end)
  if ph then ph.frames, ph.delays = { FA, FB }, { 30, 30 } end
  reset()
  Image.resume_animations()
  vim.wait(1000, function() return frames_out() > 0 end, 5)
  local playing = frames_out() > 0
  -- :detach, or the last --remote-ui client quits
  tty_ui = false; install()
  vim.api.nvim_exec_autocmds("UILeave", {})
  reset()
  local s0 = Image._frames_skipped or 0
  vim.wait(400)
  chk("H1 with no terminal UI left a gif in view writes nothing, and its clock runs on",
    playing and #ui_out + #chan_out == 0 and (Image._frames_skipped or 0) - s0 >= 5,
    ("playing %s, ui_send %d, stderr %d, skipped %d"):format(tostring(playing), #ui_out, #chan_out,
      (Image._frames_skipped or 0) - s0))
  tty_ui = true; install()
  reset()
  vim.api.nvim_exec_autocmds("UIEnter", {})
  vim.wait(500, function() return frames_out() > 0 end, 5)
  chk("H2 a terminal UI back, the gif's frames go out through nvim_ui_send again",
    frames_out() >= 1 and #chan_out == 0, ("ui_send %d, stderr %d"):format(#ui_out, #chan_out))
  -- CTRL-Z: the editor runs on while the shell has the terminal
  vim.api.nvim_exec_autocmds("VimSuspend", {})
  reset()
  s0 = Image._frames_skipped or 0
  vim.wait(400)
  chk("H3 a suspended editor writes nothing, and the gif's clock runs on",
    #ui_out + #chan_out == 0 and (Image._frames_skipped or 0) - s0 >= 5,
    ("ui_send %d, stderr %d, skipped %d"):format(#ui_out, #chan_out, (Image._frames_skipped or 0) - s0))
  do
    -- the view changes while suspended (the gif is stale and on screen), and
    -- a render re-asserts placements after they were invalidated: nothing is
    -- sent or even tried, so no frame is counted and no write held
    local sent0, held_n0, pw0 = Image._frames_sent or 0, Image._held_n or 0, Image._place_writes or 0
    if ph then ph.stale = true end
    fire("WinScrolled")
    chk("H3b while suspended a view change sends no frame of a stale gif in view, not even into the hold",
      ph and ph.stale and (Image._frames_sent or 0) == sent0 and (Image._held_n or 0) == held_n0
        and #ui_out + #chan_out == 0,
      ("frames sent %d, writes held %d"):format((Image._frames_sent or 0) - sent0, (Image._held_n or 0) - held_n0))
    -- the same with markers off (a terminal that answers no XTVERSION): with
    -- markers on, the wait for a marker keeps a frame back whatever the
    -- catch-up does, so only here does the catch-up's own check for held
    -- writes stand between it and a frame
    Image._mark_off = true
    sent0, held_n0 = Image._frames_sent or 0, Image._held_n or 0
    if ph then ph.stale = true end
    fire("WinScrolled")
    Image._mark_off = false
    chk("H3d while suspended with markers off a view change sends no frame of a stale gif in view either",
      ph and ph.stale and (Image._frames_sent or 0) == sent0 and (Image._held_n or 0) == held_n0
        and #ui_out + #chan_out == 0,
      ("frames sent %d, writes held %d"):format((Image._frames_sent or 0) - sent0, (Image._held_n or 0) - held_n0))
    Image.ensure_transmitted("spec_h3", PNG, function() end, { renderer = "placeholder" })
    pcall(Image.invalidate_placements)
    held_n0, pw0 = Image._held_n or 0, Image._place_writes or 0
    Image.reassert_virtual_placements()
    chk("H3c while suspended a render re-asserts no placement, not even into the hold",
      (Image._place_writes or 0) == pw0 and (Image._held_n or 0) == held_n0 and #ui_out + #chan_out == 0,
      ("re-asserts %d, writes held %d"):format((Image._place_writes or 0) - pw0, (Image._held_n or 0) - held_n0))
    Image.clear_for_cell("spec_h3")
  end
  reset()
  vim.api.nvim_exec_autocmds("VimResume", {})
  vim.wait(500, function() return frames_out() > 0 end, 5)
  chk("H4 resumed, its frames go out again", frames_out() >= 1 and #chan_out == 0,
    ("ui_send %d, stderr %d"):format(#ui_out, #chan_out))
  do
    -- CTRL-Z in one terminal, then nvim --remote-ui from another: a terminal
    -- UI attaches with no VimResume, and that ends the suspend
    vim.api.nvim_exec_autocmds("VimSuspend", {})
    Image.ensure_transmitted("spec_h4", PNG, function() end, { renderer = "placeholder" })
    local p4 = Image._placements.spec_h4
    local held_then = Image._writes_held and Image._writes_held()
    reset()
    vim.api.nvim_exec_autocmds("UIEnter", {})
    vim.wait(300, function() return #ui_out > 0 end, 5)
    local tx4 = p4 and ("\27_Ga=t,f=100,i=%d,"):format(p4.image_id) or "?"
    chk("H4b a terminal UI attaching ends a suspend that no VimResume ended: writes go out again, the held image first",
      held_then and Image._writes_held and not Image._writes_held()
        and count(ui_out, function(s) return s:find(tx4, 1, true) == 1 end) == 1,
      ("held then %s, held now %s, %s"):format(tostring(held_then), tostring(Image._writes_held and Image._writes_held()),
        vim.inspect(ui_out):sub(1, 160)))
    Image.clear_for_cell("spec_h4")
  end
  -- Neovim 0.11 writes on the stderr channel; a suspend holds that too
  ui_send_api = false; install(); ui_changed()
  vim.api.nvim_exec_autocmds("VimSuspend", {})
  reset()
  vim.wait(300)
  local susp = #ui_out + #chan_out
  vim.api.nvim_exec_autocmds("VimResume", {})
  vim.wait(500, function() return #chan_out > 0 end, 5)
  chk("H5 on Neovim 0.11 a suspended editor writes nothing on the stderr channel either, and resumed it does",
    susp == 0 and #chan_out > 0, ("while suspended %d, after %d"):format(susp, #chan_out))
  ui_send_api = true; install(); ui_changed()
  Image.clear_for_cell("spec_h")
end
do
  -- the kitty renderer places an image once, at a screen position: a place
  -- held while no terminal showed the editor goes out once one does, as it
  -- was asked for, and only once
  tty_ui = true; ui_send_api = true; install(); ui_changed()
  Image.ensure_transmitted("spec_k", PNG, function() end, { renderer = "kitty" })
  local pk = Image._placements.spec_k
  tty_ui = false; install()
  vim.api.nvim_exec_autocmds("UILeave", {})
  reset()
  pcall(Image.place_at_screen_row, "spec_k", 5, 3, 4, 10)
  local while_held = #ui_out + #chan_out
  tty_ui = true; install()
  reset()
  vim.api.nvim_exec_autocmds("UIEnter", {})
  vim.wait(300, function() return #ui_out > 0 end, 5)
  vim.wait(100)
  local want = pk and ("\27[s\27[5;3H\27_Ga=p,i=%d,p=%d,c=10,r=4,q=2\27\\\27[u"):format(pk.image_id, pk.placement_id)
  chk("H6 a direct placement held while no terminal showed the editor goes out once one does",
    pk and pk.renderer == "kitty" and while_held == 0 and #chan_out == 0
      and count(ui_out, function(s) return s == want end) == 1,
    ("while held %d, stderr %d, after %s"):format(while_held, #chan_out, vim.inspect(ui_out):sub(1, 160)))
  Image.clear_for_cell("spec_k")
  -- sent and placed while held: the image goes out, then its place, and
  -- the place counts as made (no render places it a second time)
  tty_ui = false; install()
  vim.api.nvim_exec_autocmds("UILeave", {})
  Image.ensure_transmitted("spec_k2", PNG, function() end, { renderer = "kitty" })
  local pk2 = Image._placements.spec_k2
  pcall(Image.place_at_screen_row, "spec_k2", 7, 3, 4, 10)
  tty_ui = true; install()
  reset()
  vim.api.nvim_exec_autocmds("UIEnter", {})
  vim.wait(300, function() return #ui_out >= 2 end, 5)
  vim.wait(100)
  local want2 = pk2 and ("\27[s\27[7;3H\27_Ga=p,i=%d,p=%d,c=10,r=4,q=2\27\\\27[u"):format(pk2.image_id, pk2.placement_id)
  local tx2 = pk2 and ui_out[1] and ui_out[1]:find("\27_Ga=t,f=100,i=" .. pk2.image_id .. ",", 1, true) == 1
  chk("H6b an image sent and placed while held goes out first, then its place, once, and stays placed",
    pk2 and tx2 and payload(ui_out[1]) == PNG and ui_out[2] == want2 and #ui_out == 2 and #chan_out == 0
      and pk2.placed_row == 7,
    ("ui_send %d, stderr %d, placed_row %s"):format(#ui_out, #chan_out, tostring(pk2 and pk2.placed_row)))
  Image.clear_for_cell("spec_k2")
  -- placed twice while held (a cell re-run moves the image: force_replace,
  -- then the next render places it at its new row): only the newest place
  -- goes out, or the image comes back where it no longer belongs
  tty_ui = false; install()
  vim.api.nvim_exec_autocmds("UILeave", {})
  Image.ensure_transmitted("spec_k3", PNG, function() end, { renderer = "kitty" })
  local pk3 = Image._placements.spec_k3
  pcall(Image.place_at_screen_row, "spec_k3", 5, 3, 4, 10)
  pcall(Image.force_replace, "spec_k3")
  pcall(Image.place_at_screen_row, "spec_k3", 9, 3, 4, 10)
  tty_ui = true; install()
  reset()
  vim.api.nvim_exec_autocmds("UIEnter", {})
  vim.wait(300, function() return #ui_out >= 2 end, 5)
  vim.wait(100)
  local function place_at(row)
    return pk3 and ("\27[s\27[%d;3H\27_Ga=p,i=%d,p=%d,c=10,r=4,q=2\27\\\27[u"):format(row, pk3.image_id, pk3.placement_id)
  end
  local places3 = count(ui_out, function(x) return x:find("\27_Ga=p,i=", 1, true) ~= nil end)
  chk("H6c an image placed twice while held is placed once when a terminal shows the editor, at the newer row",
    pk3 and places3 == 1 and count(ui_out, function(x) return x == place_at(9) end) == 1 and pk3.placed_row == 9,
    ("places %d, %s"):format(places3, vim.inspect(ui_out):sub(1, 200)))
  Image.clear_for_cell("spec_k3")
  -- a kitty-renderer gif placed before the hold whose frame write was still
  -- queued for the main loop (D12) when the hold began: that transmit is held
  -- and sent again, and with no place held the image is placed anew by the
  -- next render, not taken as placed where it was
  tty_ui = true; install(); ui_changed()
  -- the marker first, on the main loop (none is sent from a fast event)
  if Image._send_marker then pcall(Image._send_marker) end
  Image.ensure_transmitted("spec_k4", PNG, function() end, { renderer = "kitty" })
  local pk4 = Image._placements.spec_k4
  pcall(Image.place_at_screen_row, "spec_k4", 6, 3, 4, 10)
  local placed_before = pk4 and pk4.placed_row
  pcall(Image.set_visible_probe, "spec_k4", function() return true end)
  if pk4 then pk4.frames, pk4.delays = { FA, FB }, { 60000, 60000 } end
  Image.resume_animations()
  local real_fast = vim.in_fast_event
  vim.in_fast_event = function() return true end
  if pk4 then pk4.stale = true end
  catch_up()                              -- its frame waits for the main loop
  vim.in_fast_event = real_fast
  tty_ui = false; install()
  vim.api.nvim_exec_autocmds("UILeave", {})
  local h0 = Image._held_n or 0
  vim.wait(300, function() return (Image._held_n or 0) > h0 end, 5)
  local held_tx = (Image._held_n or 0) - h0
  -- paused before the terminal is back (a playing gif sends its next frame
  -- instead of the held one)
  Image.pause_animations()
  tty_ui = true; install()
  reset()
  vim.api.nvim_exec_autocmds("UIEnter", {})
  vim.wait(300, function() return #ui_out > 0 end, 5)
  vim.wait(100)
  chk("H6d a kitty-renderer transmit held with no place held is sent again and leaves the image to be placed anew",
    pk4 and placed_before == 6 and held_tx >= 1 and pk4.placed_row == nil
      and count(ui_out, function(x) return x:find("\27_Ga=t,f=100,i=" .. pk4.image_id .. ",", 1, true) == 1 end) == 1,
    ("placed before %s, held %d, placed_row now %s, %s"):format(tostring(placed_before), held_tx,
      tostring(pk4 and pk4.placed_row), vim.inspect(ui_out):sub(1, 160)))
  Image.clear_for_cell("spec_k4")
  Image.resume_animations()
end
do
  -- an image the terminal has, freed while no terminal shows the editor (an
  -- output cleared or replaced during a CTRL-Z or a :detach): its delete
  -- goes out first once a terminal shows the editor again, or the terminal
  -- keeps the image (with the kitty renderer, its placement stays on screen)
  tty_ui = true; ui_send_api = true; install(); ui_changed()
  Image.ensure_transmitted("spec_del", PNG, function() end, { renderer = "placeholder" })
  local pdl = Image._placements.spec_del
  tty_ui = false; install()
  vim.api.nvim_exec_autocmds("UILeave", {})
  reset()
  Image.clear_for_cell("spec_del")
  local while_held = #ui_out + #chan_out
  tty_ui = true; install()
  reset()
  vim.api.nvim_exec_autocmds("UIEnter", {})
  vim.wait(300, function() return #ui_out > 0 end, 5)
  vim.wait(100)
  local del = pdl and ("\27_Ga=d,d=I,i=%d,q=2\27\\"):format(pdl.image_id) or "?"
  chk("H7 an image freed while no terminal showed the editor is deleted once one does, first and once",
    pdl and while_held == 0 and #chan_out == 0 and ui_out[1] == del
      and count(ui_out, function(s) return s == del end) == 1,
    ("while held %d, stderr %d, after %s"):format(while_held, #chan_out, vim.inspect(ui_out):sub(1, 160)))
  -- every image freed at once while held (a notebook closed, the renderer
  -- switched): the terminal is cleared of them all once one shows the editor
  tty_ui = false; install()
  vim.api.nvim_exec_autocmds("UILeave", {})
  reset()
  Image.clear_all()
  local while_held_all = #ui_out + #chan_out
  tty_ui = true; install()
  reset()
  vim.api.nvim_exec_autocmds("UIEnter", {})
  vim.wait(300, function() return #ui_out > 0 end, 5)
  vim.wait(100)
  local del_all = "\27_Ga=d,d=A,q=2\27\\"
  chk("H7b every image freed at once while held is deleted from the terminal once one shows the editor, first and once",
    while_held_all == 0 and #chan_out == 0 and ui_out[1] == del_all
      and count(ui_out, function(s) return s == del_all end) == 1,
    ("while held %d, stderr %d, after %s"):format(while_held_all, #chan_out, vim.inspect(ui_out):sub(1, 160)))
  -- every image freed while held and then a new one sent, still held (the
  -- renderer switched from a GUI, or through --remote-send): the delete of
  -- them all goes out before the new image, or it would delete that too
  tty_ui = false; install()
  vim.api.nvim_exec_autocmds("UILeave", {})
  reset()
  Image.clear_all()
  Image.ensure_transmitted("spec_ca", FA, function() end, { renderer = "placeholder" })
  local pca = Image._placements.spec_ca
  local while_held_ca = #ui_out + #chan_out
  tty_ui = true; install()
  reset()
  vim.api.nvim_exec_autocmds("UIEnter", {})
  vim.wait(300, function() return #ui_out >= 2 end, 5)
  vim.wait(100)
  chk("H7c a held delete of every image goes out before an image sent after it while held, once",
    pca and while_held_ca == 0 and #chan_out == 0 and ui_out[1] == del_all and is_tx(ui_out[2] or "")
      and payload(ui_out[2]) == FA and count(ui_out, function(s) return s == del_all end) == 1,
    ("while held %d, stderr %d, after %s"):format(while_held_ca, #chan_out, vim.inspect(ui_out):sub(1, 200)))
  Image.clear_for_cell("spec_ca")
  -- an image sent and freed while held: the terminal never got it, so
  -- nothing goes out for it, neither the image nor a delete
  tty_ui = false; install()
  vim.api.nvim_exec_autocmds("UILeave", {})
  Image.ensure_transmitted("spec_nv", FB, function() end, { renderer = "placeholder" })
  local pnv = Image._placements.spec_nv
  local id_nv = pnv and pnv.image_id or -1
  Image.clear_for_cell("spec_nv")
  tty_ui = true; install()
  reset()
  vim.api.nvim_exec_autocmds("UIEnter", {})
  vim.wait(300)
  local about = count(ui_out, function(s) return s:find("i=" .. id_nv .. ",", 1, true) ~= nil end)
  chk("H7d an image sent and freed while held is neither sent nor deleted once a terminal shows the editor",
    pnv ~= nil and about == 0 and #chan_out == 0, ("writes about it %d: %s"):format(about, vim.inspect(ui_out):sub(1, 200)))
end
do
  -- the terminal may have lost the placements meanwhile (the shell drew on
  -- it after a CTRL-Z, or a terminal UI attaching is another terminal), so
  -- writes resuming and a terminal UI attaching place a static image again,
  -- once
  tty_ui = true; ui_send_api = true; install(); ui_changed()
  Image.ensure_transmitted("spec_st", PNG, function() end, { renderer = "placeholder" })
  local pst = Image._placements.spec_st
  local mark = pst and ("\27_Ga=p,U=1,i=%d,"):format(pst.image_id) or "?"
  local function placed() return count(ui_out, function(s) return s:find(mark, 1, true) ~= nil end) end
  reset(); Image.reassert_virtual_placements()
  local idle = #ui_out + #chan_out
  vim.api.nvim_exec_autocmds("VimSuspend", {})
  reset()
  vim.api.nvim_exec_autocmds("VimResume", {})
  vim.wait(300, function() return placed() > 0 end, 5)
  vim.wait(100)
  chk("H8 resumed, a static image is placed again, once",
    pst and idle == 0 and placed() == 1 and #chan_out == 0,
    ("before %d, placed %d, stderr %d"):format(idle, placed(), #chan_out))
  -- a second terminal UI attaches (nvim --remote-ui from another terminal)
  -- while the first still shows the editor: no write was held, it is the
  -- attaching alone that places the image again
  reset()
  vim.api.nvim_exec_autocmds("UIEnter", {})
  vim.wait(300, function() return placed() > 0 end, 5)
  vim.wait(100)
  chk("H8b a terminal UI attaching places a static image again, once",
    pst and placed() == 1 and #chan_out == 0, ("placed %d, stderr %d"):format(placed(), #chan_out))
  Image.clear_for_cell("spec_st")
end

-- ── I. gif frames wait for the terminal ────────────────────────────────
do
  local F = {}
  for i = 1, 4 do F[i] = vim.base64.encode(png(40, 30, 20 + i)) end
  Image._frame_window = 1  -- one frame in flight, whatever its size
  Image.ensure_transmitted("spec_i", F[1], function() end, { renderer = "placeholder" })
  local pi = Image._placements.spec_i
  pcall(Image.set_visible_probe, "spec_i", function() return true end)
  if pi then pi.frames, pi.delays = F, { 80, 80, 80, 80 } end
  ui_changed()
  reset()
  local held0 = Image._frames_held or 0
  local n0, u0 = Image._tty_n or 0, Image._ui_send_n or 0
  Image.resume_animations()
  vim.wait(700)
  -- a DSR, not a DA1: Neovim's UI, when it stops, reads the terminal until the
  -- first DA1 answer, which must be its own. The first frame after a UI
  -- change is preceded by one marker (XTVERSION), which counts as a write too.
  local o1 = nomark()
  chk("I1 a gif frame sent with nvim_ui_send is followed by a status request (DSR, not DA1), written and counted like any write",
    ui_out[1] == MARK and is_tx(o1[1] or "") and o1[2] == REQ and #o1 == 2
      and (Image._tty_n or 0) - n0 - marks_out() == 2 and (Image._ui_send_n or 0) - u0 - marks_out() == 2,
    ("%s, written %d, through nvim_ui_send %d, markers %d"):format(vim.inspect(o1[2]), (Image._tty_n or 0) - n0,
      (Image._ui_send_n or 0) - u0, marks_out()))
  chk("I2 until it is answered no other frame goes out: they are skipped and counted, the clock runs on",
    frames_out() == 1 and count(ui_out, is_req) == 1 and (Image._frames_held or 0) - held0 >= 5,
    ("frames %d, requests %d, held %d"):format(frames_out(), count(ui_out, is_req), (Image._frames_held or 0) - held0))
  reset()
  answer()
  vim.wait(400, function() return frames_out() > 0 end, 2)
  vim.wait(250)
  chk("I3 the answer lets the next frame go, and only that one, with its own request",
    frames_out() == 1 and count(ui_out, is_req) == 1 and ui_out[#ui_out] == REQ,
    ("frames %d, requests %d"):format(frames_out(), count(ui_out, is_req)))
  -- an answer with no frame waiting for it (another plugin's request, or
  -- one more terminal): nothing extra goes out
  Image.pause_animations()
  answer()
  for _ = 1, 3 do answer() end
  reset()
  Image.resume_animations()
  vim.wait(500)
  chk("I4 answers to requests that are not a frame's let no extra frame go", frames_out() == 1,
    ("frames %d"):format(frames_out()))
  -- a terminal that never answers: the requests are given up after a while
  -- (a terminal that answered once is waited for: see I11, so this one
  -- starts over, as after a UI change)
  -- a terminal that answers no XTVERSION: markers are off, and before its
  -- first answer a request is given up
  Image._mark_off = true
  ui_changed()
  Image._ack_timeout_ms = 200
  reset()
  local to0 = Image._ack_timeouts or 0
  vim.wait(1000)
  local slow = frames_out()
  Image._ack_timeout_ms = 3000
  chk("I5 a terminal that does not answer is given one more frame after the timeout: the gif slows down, it does not stop",
    slow >= 2 and (Image._ack_timeouts or 0) > to0,
    ("frames %d in 1 s, timeouts %d"):format(slow, (Image._ack_timeouts or 0) - to0))
  -- ... but only one: a terminal that has not answered yet may just be slow
  -- (the first frames behind a slow link take seconds, and the UI reads its
  -- input only between its writes), so a frame every timeout would pile up
  -- in it before its first answer. The next frames wait for the lost limit.
  ui_changed()
  Image._ack_timeout_ms = 150
  Image._ack_lost_ms = 900
  reset()
  vim.wait(550)
  local early = frames_out()           -- the first frame, one more after the timeout
  vim.wait(250)
  local pending = frames_out()         -- the 0.15 s timeout passed again and again: still no more
  vim.wait(1000)
  local after_lost = frames_out()      -- the lost limit dropped the requests: frames go again
  Image._ack_timeout_ms = 3000
  Image._ack_lost_ms = 30000
  chk("I5b before the first answer one request is given up and no more: two frames are on their way, the next ones wait for the lost limit",
    early == 2 and pending == 2 and after_lost >= 3,
    ("frames after 0.55 s %d, after 0.8 s %d, after 1.8 s %d"):format(early, pending, after_lost))
  Image._mark_off = false
  -- a UI attaching or leaving: the answers in flight may never come
  vim.wait(300)
  reset()
  ui_changed()
  vim.wait(400, function() return frames_out() > 0 end, 2)
  chk("I6 a UI change gives up the requests in flight", frames_out() >= 1, ("frames %d"):format(frames_out()))
  -- small frames: several fit the window before the first answer comes
  Image._frame_window = 64 * 1024
  ui_changed()
  reset()
  vim.wait(500)
  chk("I7 frames that fit the window go out without waiting, each with its request",
    frames_out() >= 4 and count(ui_out, is_req) == frames_out(),
    ("frames %d, requests %d"):format(frames_out(), count(ui_out, is_req)))
  -- Neovim 0.11: the stderr write blocks while the terminal is behind, and
  -- there is no nvim_ui_send to ask with
  ui_send_api = false; install(); ui_changed()
  reset()
  vim.wait(400)
  chk("I8 on Neovim 0.11 frames go out on the stderr channel with no request",
    count(chan_out, is_tx) >= 2 and count(chan_out, is_req) == 0 and #ui_out == 0,
    ("stderr frames %d, requests %d"):format(count(chan_out, is_tx), count(chan_out, is_req)))
  ui_send_api = true; install(); ui_changed()
  Image.clear_for_cell("spec_i")
end
do
  -- Neovim 0.12 asks the terminal things of its own (DA1, XTGETTCAP,
  -- DECRQSS), and their answers are TermResponse events too: only a status
  -- answer stands for a frame. (An OSC 11 answer sends a marker: I19d, I19e.)
  local F = {}
  for i = 1, 4 do F[i] = vim.base64.encode(png(40, 30, 40 + i)) end
  tty_ui = true; ui_send_api = true; install()
  Image._frame_window = 1
  Image.ensure_transmitted("spec_i9", F[1], function() end, { renderer = "placeholder" })
  local p9 = Image._placements.spec_i9
  pcall(Image.set_visible_probe, "spec_i9", function() return true end)
  if p9 then p9.frames, p9.delays = F, { 60, 60, 60, 60 } end
  ui_changed()
  reset()
  Image.resume_animations()
  vim.wait(400)
  local first = frames_out()
  reset()
  for _, seq in ipairs({ "\27[?62;22c", "\27P1+r524742=382f382f38\27\\", "\27P1$r0m\27\\" }) do
    vim.api.nvim_exec_autocmds("TermResponse", { data = { sequence = seq } })
  end
  vim.wait(300)
  local other = frames_out()
  answer()
  vim.wait(300)
  chk("I9 answers to the editor's other queries (DA1, XTGETTCAP, DECRQSS) let no frame go, a status answer lets one",
    first == 1 and other == 0 and frames_out() == 1,
    ("first %d, after the other answers %d, after a status answer %d"):format(first, other, frames_out()))
  Image.clear_for_cell("spec_i9")
  Image._frame_window = 64 * 1024
  -- the request of the frame sent last is still in flight: give it up, so
  -- the next section starts with none
  ui_changed()
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
-- (the tree before this feature has neither of these: a table with no fields
-- and a fence that is never passed stand in, so the checks that use them fail
-- one by one and the spec still ends with its completion line)
local function acks_info() return Image._acks_info and Image._acks_info() or {} end
local function status_fence()
  if Image.status_fence then return Image.status_fence() end
  return function() return false end, -1
end
-- The terminal answers, and a frame goes: a gif that skipped a frame sends
-- the frame its clock is at as the answer frees room; else frame `idx` is
-- tried the way push does. True when a frame went out.
local function answer_then_push(p, idx)
  local n0 = Image._frames_sent or 0
  answer()
  if (Image._frames_sent or 0) > n0 then return true end
  return push(p, idx)
end
do
  -- answers that came with nothing in flight (another program's requests)
  -- are not kept: they would pay for frames sent later
  tty_ui = true; ui_send_api = true; install(); ui_changed(); reset()
  Image._frame_window = 2500
  local one = string.rep("K", 1000)
  local p = hand_gif("spec_i4b", { one, one, one, one })
  push(p, 1); answer()                        -- the terminal answers; nothing in flight
  answer(); answer(); answer()                -- others' answers, nothing in flight
  push(p, 2); push(p, 3)                      -- two frames in flight (2000 of 2500)
  local c = push(p, 4)
  local d = answer_then_push(p, 4)            -- the first one's answer
  local e = push(p, 1)
  chk("I4b answers that came with nothing in flight are not kept for later frames: one answer frees one frame",
    not c and d and not e, ("full %s, after one answer %s then %s"):format(tostring(c), tostring(d), tostring(e)))
  Image.clear_for_cell("spec_i4b")
  Image._frame_window = 64 * 1024
  ui_changed()
end
do
  -- The marker. A status answer carries nothing to say whose it is (the
  -- editor's own start, attach and resume queries are answered the same way
  -- as a frame's), so after every reset of the books the first frame waits
  -- for an XTVERSION request, which Neovim never sends and whose answer is
  -- distinct: everything answered before it was asked before it.
  local F = {}
  for i = 1, 3 do F[i] = vim.base64.encode(png(40, 30, 200 + i)) end
  tty_ui = true; ui_send_api = true; install(); ui_changed(); reset()
  Image._remote_mode = true
  auto_mark = false
  Image._frame_window = 1
  local p = hand_gif("spec_i19", F)
  ui_changed(); reset()
  local a = push(p, 1)
  local m1, f1 = marks_out(), frames_out()
  answer_mark()
  local f2, n2 = frames_out(), acks_n()
  local b = push(p, 2)
  chk("I19 after a UI change the next frame first sends one marker (XTVERSION) and waits; the marker's answer lets it go",
    not a and m1 == 1 and f1 == 0 and f2 == 1 and n2 == 1 and not b,
    ("first push %s, markers %d, frames before the answer %d, after %d, in flight %d, next push %s"):format(
      tostring(a), m1, f1, f2, n2, tostring(b)))
  Image.clear_for_cell("spec_i19")
  auto_mark = true
  Image._frame_window = 64 * 1024
  ui_changed()
end
do
  -- G, continued: :JupynvimRenderStats resets its counters while a marker
  -- and then a frame's request are on their way. Each answer is counted in
  -- the report after the reset, against the request it answers, so no
  -- report shows more answers than requests (or than markers).
  local F = {}
  for i = 1, 3 do F[i] = vim.base64.encode(png(40, 30, 230 + i)) end
  tty_ui = true; ui_send_api = true; install(); ui_changed(); reset()
  Image._remote_mode = true
  auto_mark = false
  Image._frame_window = 64 * 1024
  local p = hand_gif("spec_g3", F)
  ui_changed(); reset()
  local saved_notify = vim.notify
  local rep_txt
  vim.notify = function(m) rep_txt = tostring(m) end
  local function report()
    rep_txt = nil
    pcall(vim.cmd, "JupynvimRenderStats")
    local t = rep_txt or ""
    local ag, as = t:match("terminal answers: (%d+) of (%d+) asked")
    local mg, ms = t:match("markers: (%d+) of (%d+) answered")
    return { ag = tonumber(ag), as = tonumber(as), mg = tonumber(mg), ms = tonumber(ms) }
  end
  push(p, 1)                -- the marker goes; the frame waits for its answer
  local m_flight = acks_info().mark
  report()                  -- reset with the marker on its way
  answer_mark()             -- answered: frame 1 goes, its request on its way
  local a_flight = acks_n()
  local r1 = report()       -- reset with that request on its way
  answer()
  local r2 = report()
  vim.notify = saved_notify
  chk("G5 a reset of :JupynvimRenderStats while a marker or a frame's request is on its way counts its answer in the next report: never more answers than requests",
    m_flight == 1 and a_flight == 1 and r1.mg == 1 and r1.ms == 1 and r1.ag == 0 and r1.as == 1
      and r2.ag == 1 and r2.as == 1 and r2.mg == 0 and r2.ms == 0,
    ("marker on its way %s, requests %s; after the marker's answer: markers %s of %s, answers %s of %s; after the frame's: answers %s of %s, markers %s of %s"):format(
      tostring(m_flight), tostring(a_flight), tostring(r1.mg), tostring(r1.ms), tostring(r1.ag), tostring(r1.as),
      tostring(r2.ag), tostring(r2.as), tostring(r2.mg), tostring(r2.ms)))
  Image.clear_for_cell("spec_g3")
  auto_mark = true
  ui_changed()
end
do
  -- the editor's own start, attach and resume answers: DA1, XTGETTCAP and
  -- DECRQSS (DCS strings that are not the marker's answer; Ghostty, kitty and
  -- WezTerm outside tmux send them when Neovim asks at its start), DSR, DSR,
  -- DA1 in one burst, all before the marker's answer, none a frame's
  local F = {}
  for i = 1, 3 do F[i] = vim.base64.encode(png(40, 30, 210 + i)) end
  tty_ui = true; ui_send_api = true; install(); ui_changed(); reset()
  Image._remote_mode = true
  auto_mark = false
  Image._frame_window = 1
  local p = hand_gif("spec_i19b", F)
  local res = {}
  for case = 1, 3 do
    if case == 1 then ui_changed()
    elseif case == 2 then pcall(Image._ui_changed, "enter", 1)
    else
      -- the suspend's drain asks with a marker (answered at once here); the
      -- resume then wants a new one
      auto_mark = true; fire("VimSuspend"); fire("VimResume"); auto_mark = false
    end
    reset()
    local x = push(p, 1)
    for _, seq in ipairs({ "\27[?1;2;4c", "\27P1+r524742=382f382f38\27\\", "\27P1$r0m\27\\",
                           "\27[0n", "\27[0n", "\27[?1;2;4c" }) do
      vim.api.nvim_exec_autocmds("TermResponse", { data = { sequence = seq } })
    end
    local f0 = frames_out()
    answer_mark()
    local fa, na = frames_out(), acks_n()
    answer()
    res[case] = { x, f0, fa, na, acks_n() }
  end
  local okb = true
  for _, r in ipairs(res) do
    if r[1] or r[2] ~= 0 or r[3] ~= 1 or r[4] ~= 1 or r[5] ~= 0 then okb = false end
  end
  chk("I19b status answers that come before the marker's answer (the editor's own start, attach or resume answers, even in one burst with DA1 answers) pay nothing; frames go on the marker's answer",
    okb, "cases (sent, frames before, after, in flight after, in flight after the frame's answer): " .. vim.inspect(res))
  Image.clear_for_cell("spec_i19b")
  auto_mark = true
  Image._frame_window = 64 * 1024
  ui_changed()
end
do
  -- once the marker is answered, a frame's status answer is a frame's even
  -- when a DA1 answer comes right before it in the same read: the first
  -- frame's own answer (nothing counted yet) and the next one's alike
  local F = {}
  for i = 1, 3 do F[i] = vim.base64.encode(png(40, 30, 220 + i)) end
  tty_ui = true; ui_send_api = true; install(); ui_changed(); reset()
  Image._remote_mode = true
  auto_mark = false
  Image._frame_window = 1
  local p = hand_gif("spec_i19c", F)
  local function burst()
    for _, seq in ipairs({ "\27[?1;2;4c", "\27[0n" }) do
      vim.api.nvim_exec_autocmds("TermResponse", { data = { sequence = seq } })
    end
  end
  ui_changed(); reset()
  push(p, 1); answer_mark()                   -- frame 1 goes, after one marker
  local m0 = marks_out()
  burst()                                     -- its own answer, in one read with a DA1 answer
  local n0 = acks_n()
  local c1 = push(p, 2)
  burst()
  local nc = acks_n()
  local c2 = push(p, 3)
  chk("I19c a frame's status answer that comes in one burst with a DA1 answer pays that frame",
    m0 == 1 and n0 == 0 and c1 and nc == 0 and c2,
    ("markers %d, in flight after the first burst %d, frame 2 sent %s, in flight after the second %d, frame 3 sent %s"):format(
      m0, n0, tostring(c1), nc, tostring(c2)))
  answer()
  Image.clear_for_cell("spec_i19c")
  auto_mark = true
  Image._frame_window = 64 * 1024
  ui_changed()
end
do
  -- another program's OSC 11 answer while frame requests wait: the status
  -- request that ends that query is answered after it, and nothing says
  -- whose it is, so a marker goes at once and its answer pays what was
  -- sent before it
  local one = string.rep("K", 1000)
  tty_ui = true; ui_send_api = true; install(); ui_changed(); reset()
  Image._remote_mode = true
  auto_mark = false
  Image._frame_window = 2500
  local q = hand_gif("spec_i19d", { one, one, one, one })
  ui_changed(); reset(); push(q, 1); answer_mark(); answer()
  local d1, d2 = push(q, 2), push(q, 3)
  local nd0 = acks_n()
  local m0 = marks_out()
  vim.api.nvim_exec_autocmds("TermResponse", { data = { sequence = "\27]11;rgb:1e1e/1e1e/2e2e\27\\" } })
  local md = marks_out()
  answer()
  local nd1 = acks_n()
  local d3 = push(q, 4)
  local s0 = Image._frames_sent or 0
  answer_mark()
  local nd2 = acks_n()
  local went = (Image._frames_sent or 0) > s0
  chk("I19d an OSC 11 answer while frame requests wait sends a marker at once; the status answer after it pays nothing; the marker's answer pays every request sent before it",
    d1 and d2 and nd0 == 2 and md == m0 + 1 and nd1 == 2 and not d3 and (went or push(q, 1)),
    ("in flight %d, markers %d then %d, after the status answer %d, frame 4 sent %s, after the marker's answer %d (a frame went %s)"):format(
      nd0, m0, md, nd1, tostring(d3), nd2, tostring(went)))
  Image.clear_for_cell("spec_i19d")
  auto_mark = true
  Image._frame_window = 64 * 1024
  ui_changed()
end
do
  -- the same, with the OSC 11 answer alone (no status answer after it
  -- from the editor): the frame whose own status answer came after it must
  -- not stay unpaid
  local one = string.rep("K", 1000)
  tty_ui = true; ui_send_api = true; install(); ui_changed(); reset()
  Image._remote_mode = true
  auto_mark = false
  Image._frame_window = 2500
  local q = hand_gif("spec_i19e", { one, one, one, one })
  ui_changed(); reset(); push(q, 1); answer_mark(); answer()
  local e1 = push(q, 2)
  vim.api.nvim_exec_autocmds("TermResponse", { data = { sequence = "\27]11;rgb:1e1e/1e1e/2e2e\27\\" } })
  answer()                                    -- frame 2's own, after the OSC 11 answer
  answer_mark()
  local ne = acks_n()
  local e2 = push(q, 3)
  answer()
  local ne2 = acks_n()
  local e3 = push(q, 4)
  chk("I19e after another program's lone OSC 11 answer no request stays unpaid: the marker's answer pays the frame whose status answer came after it",
    e1 and ne == 0 and e2 and ne2 == 0 and e3,
    ("frame 2 sent %s, in flight after the marker's answer %d, frame 3 sent %s, in flight after its answer %d, frame 4 sent %s"):format(
      tostring(e1), ne, tostring(e2), ne2, tostring(e3)))
  Image.clear_for_cell("spec_i19e")
  auto_mark = true
  Image._frame_window = 64 * 1024
  ui_changed()
end
do
  -- an answer to a marker when none is due (another program's XTVERSION)
  -- pays nothing while markers are on and one was answered before
  local one = string.rep("K", 1000)
  tty_ui = true; ui_send_api = true; install(); ui_changed(); reset()
  Image._remote_mode = true
  auto_mark = false
  Image._frame_window = 2500
  local q = hand_gif("spec_i19l", { one, one, one, one })
  ui_changed(); reset(); push(q, 1); answer_mark(); answer()
  local l1, l2 = push(q, 2), push(q, 3)
  local due = Image._acks_info and Image._acks_info().mark or -1
  local nl0 = acks_n()
  answer_mark()
  local nl = acks_n()
  local l3 = push(q, 4)
  chk("I19l an answer to a marker when none is due (another program's XTVERSION) pays nothing while markers are on",
    l1 and l2 and due == 0 and nl0 == 2 and nl == 2 and not l3,
    ("frames 2, 3 sent %s %s, marker due %s, in flight %d then %d, frame 4 sent %s"):format(
      tostring(l1), tostring(l2), tostring(due), nl0, nl, tostring(l3)))
  answer(); answer()
  Image.clear_for_cell("spec_i19l")
  auto_mark = true
  Image._frame_window = 64 * 1024
  ui_changed()
end
do
  -- a terminal that answers no XTVERSION (none of the supported ones): the
  -- marker is given up after the lost limit, and with none ever answered
  -- markers are off for good and frames go without them
  local F = {}
  for i = 1, 3 do F[i] = vim.base64.encode(png(40, 30, 230 + i)) end
  tty_ui = true; ui_send_api = true; install(); ui_changed(); reset()
  Image._remote_mode = true
  auto_mark = false
  Image._frame_window = 1
  local p = hand_gif("spec_i19f", F)
  Image._mark_seen = false
  Image._ack_lost_ms = 300
  ui_changed(); reset()
  local l0 = Image._marks_lost or 0
  local g1 = push(p, 1)
  local gm = marks_out()
  vim.wait(350)
  local g2 = push(p, 1)
  local off = Image._mark_off
  local lost = (Image._marks_lost or 0) - l0
  ui_changed(); reset()
  local g3 = push(p, 2)
  local gm2 = marks_out()
  chk("I19f a marker unanswered for the lost limit is given up; when no marker was ever answered, markers are off and frames go without them",
    not g1 and gm == 1 and g2 and off == true and lost == 1 and g3 and gm2 == 0,
    ("first push %s, markers %d, after the limit %s, markers off %s, given up %d, after a UI change %s with %d markers"):format(
      tostring(g1), gm, tostring(g2), tostring(off), lost, tostring(g3), gm2))
  Image._ack_lost_ms = 30000
  Image._mark_off = false
  Image._mark_seen = true
  Image.clear_for_cell("spec_i19f")
  auto_mark = true
  Image._frame_window = 64 * 1024
  ui_changed()
end
do
  -- a marker lost after one was answered: given up, markers stay on
  local F = {}
  for i = 1, 3 do F[i] = vim.base64.encode(png(40, 30, 240 + i)) end
  tty_ui = true; ui_send_api = true; install(); ui_changed(); reset()
  Image._remote_mode = true
  auto_mark = false
  Image._frame_window = 1
  local p = hand_gif("spec_i19g", F)
  Image._mark_seen = true
  Image._ack_lost_ms = 300
  ui_changed(); reset()
  local g1 = push(p, 1)
  vim.wait(350)
  local g2 = push(p, 1)
  local goff = Image._mark_off
  ui_changed(); reset()
  local g3 = push(p, 2)
  local gm = marks_out()
  answer_mark()
  Image._ack_lost_ms = 30000
  chk("I19g a marker lost after one was answered is given up, and markers stay on",
    not g1 and g2 and goff == false and not g3 and gm == 1,
    ("first push %s, after the limit %s, markers off %s, after a UI change %s with %d markers"):format(
      tostring(g1), tostring(g2), tostring(goff), tostring(g3), gm))
  Image.clear_for_cell("spec_i19g")
  auto_mark = true
  Image._frame_window = 64 * 1024
  ui_changed()
end
do
  -- a marker answered after it was given up (the first answer after a start
  -- takes longer than the lost limit over a slow link, or the marker sat in
  -- Neovim's buffer): the terminal does answer markers. They are on again,
  -- the books kept by the markers-off rules meanwhile are settled by a new
  -- marker, and the status answers before its answer pay nothing
  local F = {}
  for i = 1, 3 do F[i] = vim.base64.encode(png(40, 30, 245 + i)) end
  tty_ui = true; ui_send_api = true; install(); ui_changed(); reset()
  Image._remote_mode = true
  auto_mark = false
  Image._frame_window = 1
  local p = hand_gif("spec_i19m", F)
  Image._mark_seen = false
  Image._ack_lost_ms = 300
  ui_changed(); reset()
  push(p, 1)                                  -- the marker goes, no frame
  vim.wait(350)
  local m1 = push(p, 1)                       -- given up, markers off: the frame goes
  local off1, seen1, mk1, n1 = Image._mark_off, Image._mark_seen, marks_out(), acks_n()
  answer_mark()                               -- the terminal's late answer
  local off2, seen2, mk2 = Image._mark_off, Image._mark_seen, marks_out()
  answer()                                    -- the frame's status answer, before the new marker's
  local n2 = acks_n()
  local m2 = push(p, 2)
  local fr = frames_out()
  answer_mark()                               -- the new marker's answer pays the old request; the waiting frame goes
  local n3, fr2 = acks_n(), frames_out()
  chk("I19m a marker answered after it was given up turns markers on again: the next frame's books are settled by a new marker",
    m1 and off1 == true and seen1 == false and n1 == 1 and off2 == false and seen2 == true and mk2 == mk1 + 1
      and n2 == 1 and not m2 and fr2 == fr + 1 and n3 == 1,
    ("given up: off %s seen %s, in flight %d; after the late answer: off %s seen %s, markers %d then %d; after a status answer %d in flight, push %s; after the new marker's answer %d in flight (the waiting frame's), %d frames sent"):format(
      tostring(off1), tostring(seen1), n1, tostring(off2), tostring(seen2), mk1, mk2, n2, tostring(m2), n3, fr2 - fr))
  answer()
  Image._ack_lost_ms = 30000
  Image._mark_off = false
  Image._mark_seen = true
  Image.clear_for_cell("spec_i19m")
  auto_mark = true
  Image._frame_window = 64 * 1024
  ui_changed()
end
do
  -- the same where a marker was never given up but the answer to one the
  -- reset forgot comes before any was answered: it proves the terminal
  -- answers them, and a marker given up later does not turn them off
  local F = {}
  for i = 1, 3 do F[i] = vim.base64.encode(png(40, 30, 255 + i)) end
  tty_ui = true; ui_send_api = true; install(); ui_changed(); reset()
  Image._remote_mode = true
  auto_mark = false
  Image._frame_window = 1
  local p = hand_gif("spec_i19n", F)
  Image._mark_seen = false
  Image._ack_lost_ms = 300
  ui_changed(); reset()
  push(p, 1)                                  -- a marker goes
  ui_changed()                                -- a reset forgets it
  answer_mark()                               -- its answer, late
  local seen = Image._mark_seen
  reset()
  push(p, 1)                                  -- a new marker goes
  vim.wait(350)
  push(p, 1)                                  -- given up
  local off = Image._mark_off
  chk("I19n the late answer to a marker a reset forgot shows that the terminal answers them: a marker given up later does not turn them off",
    seen == true and off == false, ("seen %s, off after a marker given up %s"):format(tostring(seen), tostring(off)))
  Image._ack_lost_ms = 30000
  Image._mark_off = false
  Image._mark_seen = true
  Image.clear_for_cell("spec_i19n")
  auto_mark = true
  Image._frame_window = 64 * 1024
  ui_changed()
end
do
  -- two terminal UIs: the marker is answered by both, and only then do
  -- frames go
  local F = {}
  for i = 1, 3 do F[i] = vim.base64.encode(png(40, 30, 250 + i)) end
  tty_ui = true; ui_send_api = true; install(); ui_changed(); reset()
  Image._remote_mode = true
  auto_mark = false
  Image._frame_window = 1
  local p = hand_gif("spec_i19h", F)
  tty_ui = "two"; install(); ui_changed(); reset()
  local h1 = push(p, 1)
  answer_mark()
  local hf1 = frames_out()
  answer_mark()
  local hf2 = frames_out()
  chk("I19h with two terminal UIs frames wait until both answered the marker",
    not h1 and hf1 == 0 and hf2 == 1,
    ("first push %s, frames after one answer %d, after two %d"):format(tostring(h1), hf1, hf2))
  tty_ui = true; install()
  Image.clear_for_cell("spec_i19h")
  auto_mark = true
  Image._frame_window = 64 * 1024
  ui_changed()
end
do
  -- :JupynvimRenderStats counts a marker as answered when every terminal UI
  -- has answered it and a request when every UI has read it (not each
  -- answer), and the requests a marker's answer pays
  local one = string.rep("K", 1000)
  local real_notify, note3 = vim.notify, nil
  vim.notify = function(m) note3 = tostring(m) end
  pcall(vim.cmd, "JupynvimRenderStats")       -- start from zero
  tty_ui = "two"; ui_send_api = true; install(); ui_changed(); reset()
  Image._remote_mode = true
  auto_mark = false
  Image._frame_window = 64 * 1024
  local p = hand_gif("spec_g3", { one, one, one })
  ui_changed(); reset()
  push(p, 1); answer_mark(); answer_mark()    -- one marker, answered by both; frame 1 out
  push(p, 2)
  answer(); answer(); answer(); answer()      -- both UIs read both requests
  pcall(vim.cmd, "JupynvimRenderStats")
  local mg, ms, ml = (note3 or ""):match("markers: (%d+) of (%d+) answered, (%d+) given up")
  local ag, as = (note3 or ""):match("terminal answers: (%d+) of (%d+) asked")
  local two_ok = mg == "1" and ms == "1" and ml == "0" and ag == "2" and as == "2"
  local two_detail = ("two UIs: markers %s of %s, answers %s of %s"):format(tostring(mg), tostring(ms), tostring(ag), tostring(as))
  -- one UI: two requests in flight, then an OSC 11 answer sends a marker whose answer pays both
  tty_ui = true; install(); ui_changed(); reset()
  Image.clear_for_cell("spec_g3")
  local q = hand_gif("spec_g3b", { one, one, one })
  ui_changed(); reset()
  push(q, 1); answer_mark()                   -- frame 1 out
  push(q, 2)
  vim.api.nvim_exec_autocmds("TermResponse", { data = { sequence = "\27]11;rgb:1e1e/1e1e/2e2e\27\\" } })
  pcall(vim.cmd, "JupynvimRenderStats")       -- reset again, then count the paid requests
  push(q, 3)
  note3 = nil
  answer_mark()                               -- pays the requests sent before the OSC 11 answer's marker
  pcall(vim.cmd, "JupynvimRenderStats")
  local ag1, as1 = (note3 or ""):match("terminal answers: (%d+) of (%d+) asked")
  vim.notify = real_notify
  chk("G3 :JupynvimRenderStats with two terminal UIs counts a marker and a request once each, and counts the requests a marker's answer pays",
    two_ok and tonumber(ag1) ~= nil and tonumber(ag1) >= 2, two_detail .. (", one UI after a marker's answer: answers %s of %s"):format(
      tostring(ag1), tostring(as1)))
  Image.clear_for_cell("spec_g3b")
  auto_mark = true
  Image._frame_window = 64 * 1024
  ui_changed()
end
do
  -- a UI change while a marker is on its way forgets it (its answer may
  -- belong to a UI that left) and asks with a new one
  local F = {}
  for i = 1, 3 do F[i] = vim.base64.encode(png(40, 30, 260 + i)) end
  tty_ui = true; ui_send_api = true; install(); ui_changed(); reset()
  Image._remote_mode = true
  auto_mark = false
  Image._frame_window = 1
  local p = hand_gif("spec_i19i", F)
  ui_changed(); reset()
  local i1 = push(p, 1)
  ui_changed()
  local i2 = push(p, 1)
  local im = marks_out()
  answer_mark()
  local if1 = frames_out()
  chk("I19i a UI change while a marker is on its way asks with a new marker",
    not i1 and not i2 and im == 2 and if1 == 1,
    ("pushes %s %s, markers %d, frames after the answer %d"):format(tostring(i1), tostring(i2), im, if1))
  Image.clear_for_cell("spec_i19i")
  auto_mark = true
  Image._frame_window = 64 * 1024
  ui_changed()
end
do
  -- fast-event writes wait for the main loop in a queue; a marker asked
  -- meanwhile goes after them, not before (the order of writes is kept)
  local F = {}
  for i = 1, 3 do F[i] = vim.base64.encode(png(40, 30, 270 + i)) end
  tty_ui = true; ui_send_api = true; install(); ui_changed(); reset()
  Image._remote_mode = true
  auto_mark = false
  Image._frame_window = 1
  local p = hand_gif("spec_i19j", F)
  ui_changed(); reset()
  local real_fast = vim.in_fast_event
  vim.in_fast_event = function() return true end
  Image.clear_visible_placements()            -- its d=a waits for the main loop
  vim.in_fast_event = real_fast
  local j1 = push(p, 1)                       -- on the main loop, before the queue ran
  vim.wait(300, function() catch_up(); return marks_out() > 0 end, 5)
  local id_da, id_m
  for i, x in ipairs(ui_out) do
    if x == "\27_Ga=d,d=a,q=2\27\\" and not id_da then id_da = i end
    if x == MARK and not id_m then id_m = i end
  end
  chk("I19j a marker asked while fast-event writes wait for the main loop goes after them",
    not j1 and id_da and id_m and id_da < id_m,
    ("push %s, delete at %s, marker at %s"):format(tostring(j1), tostring(id_da), tostring(id_m)))
  answer_mark()
  Image.clear_for_cell("spec_i19j")
  auto_mark = true
  Image._frame_window = 64 * 1024
  ui_changed()
end
do
  -- the marker's answer is the terminal's: once it came, a slow answer to a
  -- frame is waited for, nothing times out (as after a frame's answer)
  local F = {}
  for i = 1, 3 do F[i] = vim.base64.encode(png(40, 30, 280 + i)) end
  tty_ui = true; ui_send_api = true; install(); ui_changed(); reset()
  Image._remote_mode = true
  auto_mark = false
  Image._frame_window = 1
  local p = hand_gif("spec_i19k", F)
  Image._ack_timeout_ms = 300
  ui_changed(); reset()
  push(p, 1)
  answer_mark()                               -- frame 1 out
  local k0 = Image._ack_timeouts or 0
  vim.wait(400)
  local k1 = push(p, 2)
  local k2 = (Image._ack_timeouts or 0) == k0
  local k3 = answer_then_push(p, 2)           -- an answer sends the frame of the gif that skipped one
  Image._ack_timeout_ms = 3000
  chk("I19k after the marker's answer a slow frame answer is waited for: the terminal has answered",
    not k1 and k2 and k3, ("pushed meanwhile %s, no timeout %s, after the answer %s"):format(
      tostring(k1), tostring(k2), tostring(k3)))
  answer()
  Image.clear_for_cell("spec_i19k")
  auto_mark = true
  Image._frame_window = 64 * 1024
  ui_changed()
end
do
  -- quitting while a marker is on its way: its answer would reach the shell
  local F = {}
  for i = 1, 3 do F[i] = vim.base64.encode(png(40, 30, 290 + i)) end
  tty_ui = true; ui_send_api = true; install(); ui_changed(); reset()
  Image._remote_mode = true
  auto_mark = false
  Image._frame_window = 1
  local p = hand_gif("spec_i16m", F)
  ui_changed(); reset()
  push(p, 1)                                  -- the marker goes, no frame
  vim.defer_fn(answer_mark, 200)
  local t = vim.uv.now()
  fire("VimLeavePre")
  local wm = vim.uv.now() - t
  Image._leaving = false
  chk("I16m a marker still on its way at a quit is waited for: its answer would reach the shell",
    wm >= 150 and wm < 2500, ("waited %d ms"):format(wm))
  Image.clear_for_cell("spec_i16m")
  auto_mark = true
  Image._frame_window = 64 * 1024
  ui_changed()
end
do
  -- a :detach while only a marker is on its way (the first frame after an
  -- attach, before the terminal answered it): its UILeave waits for the
  -- marker's answer, which would reach the leaving client's shell
  local F = {}
  for i = 1, 3 do F[i] = vim.base64.encode(png(40, 30, 300 + i)) end
  tty_ui = true; ui_send_api = true; install(); ui_changed(); reset()
  Image._remote_mode = true
  auto_mark = false
  Image._frame_window = 1
  local p = hand_gif("spec_i16o", F)
  local real_info = vim.api.nvim_get_chan_info
  local real_notify = vim.rpcnotify
  vim.api.nvim_get_chan_info = function(ch)
    if ch == 79 then return { id = ch, client = { type = "ui", attributes = { pid = vim.fn.getpid() } } } end
    return real_info(ch)
  end
  vim.rpcnotify = function(ch, ...)  -- the client runs: its channel takes a notification
    if ch == 79 then return 1 end
    return real_notify(ch, ...)
  end
  ui_changed(); reset()
  local x = push(p, 1)                        -- the marker goes, no frame
  local info = Image._acks_info and Image._acks_info() or {}
  vim.defer_fn(answer_mark, 200)
  tty_ui = false; install()
  local t = vim.uv.now()
  pcall(Image._drain_on_leave, 79)
  local wo = vim.uv.now() - t
  vim.api.nvim_get_chan_info = real_info
  vim.rpcnotify = real_notify
  tty_ui = true; install()
  vim.wait(300)
  chk("I16o a :detach while only a marker is on its way waits for its answer: it would reach the leaving client's shell",
    Image._drain_on_leave ~= nil and not x and info.n == 0 and info.mark == 1 and wo >= 150 and wo < 2500,
    ("frame sent %s, in flight %s, marker due %s, waited %d ms"):format(tostring(x), tostring(info.n), tostring(info.mark), wo))
  Image.clear_for_cell("spec_i16o")
  auto_mark = true
  Image._frame_window = 64 * 1024
  ui_changed()
end
do
  -- a frame's answer on its way to the first terminal UI when a second one
  -- attaches (its UIEnter resets the books, which forget the request): a quit
  -- before the next frame still asks with a marker and waits for the answers
  -- the reset forgot
  local F = {}
  for i = 1, 3 do F[i] = vim.base64.encode(png(40, 30, 310 + i)) end
  tty_ui = true; ui_send_api = true; install(); ui_changed(); reset()
  Image._remote_mode = true
  auto_mark = true
  Image._frame_window = 1
  local p = hand_gif("spec_i16p", F)
  Image._mark_seen = true
  ui_changed(); reset()
  local sent = push(p, 1)                     -- the marker is answered at once, frame 1 out, its answer due
  local n0 = acks_n()
  tty_ui = "two"; install()
  pcall(Image._ui_changed, "enter", 2)        -- a second terminal UI attaches
  local n1, note1 = acks_n(), acks_info().note
  auto_mark = false
  vim.defer_fn(answer, 200)                   -- frame 1's answer, from the first UI
  vim.defer_fn(answer_mark, 300)
  vim.defer_fn(answer_mark, 320)
  local t = vim.uv.now()
  fire("VimLeavePre")
  local wp = vim.uv.now() - t
  Image._leaving = false
  local note2 = acks_info().note
  vim.wait(100)
  chk("I16p after a second UI attached with a frame's answer on its way, a quit still asks with a marker and waits for it (its answer comes after the forgotten one)",
    sent and n0 == 1 and n1 == 0 and note1 == true and wp >= 300 and wp < 2500 and note2 == false,
    ("frame sent %s, in flight %d before the attach, %d after (note %s), waited %d ms, note after %s"):format(
      tostring(sent), n0, n1, tostring(note1), wp, tostring(note2)))
  tty_ui = true; install()
  Image.clear_for_cell("spec_i16p")
  auto_mark = true
  Image._frame_window = 64 * 1024
  ui_changed()
end
do
  -- another program's status answer was taken for a frame's, so no request
  -- counts in flight, yet the frame's own answer is still on its way: the
  -- drain asks with a marker, whose answer comes after it
  local F = {}
  for i = 1, 3 do F[i] = vim.base64.encode(png(40, 30, 300 + i)) end
  tty_ui = true; ui_send_api = true; install(); ui_changed(); reset()
  Image._remote_mode = true
  auto_mark = true
  Image._frame_window = 1
  local p = hand_gif("spec_i16n", F)
  ui_changed(); reset()
  push(p, 1)                                  -- the marker is answered at once, frame 1 out
  answer()                                    -- a foreign status answer pays frame 1 early
  auto_mark = false
  vim.defer_fn(answer, 150)                   -- frame 1's own, late
  vim.defer_fn(answer_mark, 300)
  local t = vim.uv.now()
  fire("VimLeavePre")
  local wn = vim.uv.now() - t
  Image._leaving = false
  chk("I16n the drain before a quit asks with a marker: with a request's answer taken early (another program's status answer), it still waits for the last answer on its way",
    wn >= 250, ("waited %d ms"):format(wn))
  Image.clear_for_cell("spec_i16n")
  auto_mark = true
  Image._frame_window = 64 * 1024
  ui_changed()
end
do
  -- another writer's question (the palette's OSC 11 and DSR) goes after the
  -- gif frames' requests still in flight, whose status answers come first
  -- and are nobody else's: status_fence() writes a marker after them and is
  -- passed once that marker is answered
  local one = string.rep("K", 1000)
  tty_ui = true; ui_send_api = true; install(); ui_changed(); reset()
  Image._remote_mode = true
  auto_mark = false
  Image._frame_window = 5000
  local q = hand_gif("spec_i20", { one, one, one, one })
  ui_changed(); reset(); push(q, 1); answer_mark()
  local f2, f3 = push(q, 2), push(q, 3)       -- three requests in flight
  local n0, m0 = acks_n(), marks_out()
  local passed, owed = status_fence()
  local m1, last_is_mark = marks_out(), ui_out[#ui_out] == MARK
  answer(); answer()                          -- the frames' answers, before the marker's
  local p1 = passed()
  answer()
  local p2 = passed()
  answer_mark()
  local p3, n3 = passed(), acks_n()
  local s0 = Image._frames_sent or 0
  local again = push(q, 4)
  chk("I20 status_fence with requests in flight writes a marker after them and is passed once the marker is answered, not by the status answers before it",
    f2 and f3 and n0 == 3 and m1 == m0 + 1 and last_is_mark and owed == 0 and p1 == false and p2 == false
      and p3 == true and n3 == 0 and again,
    ("in flight %d, markers %d then %d (last write a marker %s), owed %s, passed after 2 answers %s, 3 %s, after the marker %s, in flight %d, next frame %s"):format(
      n0, m0, m1, tostring(last_is_mark), tostring(owed), tostring(p1), tostring(p2), tostring(p3), n3, tostring(again)))
  answer()
  Image.clear_for_cell("spec_i20")
  auto_mark = true
  Image._frame_window = 64 * 1024
  ui_changed()
end
do
  -- nothing in flight: passed at once, nothing written; a marker on its
  -- way is used, not repeated; markers off: passed, with the number of
  -- status answers the frames still owe
  local one = string.rep("K", 1000)
  tty_ui = true; ui_send_api = true; install(); ui_changed(); reset()
  Image._remote_mode = true
  auto_mark = false
  Image._frame_window = 5000
  local q = hand_gif("spec_i20b", { one, one, one, one })
  ui_changed(); reset(); push(q, 1); answer_mark(); answer()  -- the books are clean
  reset()
  local pa, oa = status_fence()
  local nothing = pa() == true and oa == 0 and #ui_out == 0
  push(q, 2)                                  -- a request in flight
  local pb, ob = status_fence()
  local mb = marks_out()
  local pb2 = status_fence()
  local reused = marks_out() == mb
  answer_mark()
  local done = pb() == true
  answer()
  Image._mark_off = true                      -- markers off: frames go without them
  ui_changed(); reset()
  push(q, 1); push(q, 2)
  local mo0 = marks_out()
  local pc, oc = status_fence()
  local off_ok = pc() == true and oc == 2 and marks_out() == mo0
  Image._mark_off = false
  chk("I20b status_fence: nothing in flight is passed at once with nothing written, a marker on its way is used and not repeated, markers off pass at once with the status answers still owed",
    nothing and mb == 1 and reused and done and off_ok and ob == 0,
    ("nothing %s, markers %d, reused %s, passed after the answer %s, markers off: passed %s, owed %s, written %s"):format(
      tostring(nothing), mb, tostring(reused), tostring(done), tostring(pc()), tostring(oc), tostring(marks_out() ~= mo0)))
  answer(); answer()
  Image.clear_for_cell("spec_i20b")
  auto_mark = true
  Image._frame_window = 64 * 1024
  ui_changed()
end
do
  -- a reset of the books passes a fence (the marker is forgotten); one asked
  -- after a reset that forgot requests in flight still writes a marker; with
  -- two terminal UIs it is passed after both answered the marker
  local one = string.rep("K", 1000)
  tty_ui = true; ui_send_api = true; install(); ui_changed(); reset()
  Image._remote_mode = true
  auto_mark = false
  Image._frame_window = 5000
  local q = hand_gif("spec_i20c", { one, one, one, one })
  ui_changed(); reset(); push(q, 1); answer_mark()
  push(q, 2)
  local pa = status_fence()
  local before = pa()
  ui_changed()                                -- the marker and the requests are forgotten
  local after = pa()
  reset()
  local pb = status_fence()             -- the reset forgot requests in flight: a marker still goes
  local mk = marks_out()
  answer_mark()
  local fresh_ok = mk == 1 and pb() == true
  tty_ui = "two"; install(); ui_changed(); reset()
  push(q, 1)                                  -- the new marker (the UIs changed)
  local pt = status_fence()
  answer_mark()
  local one_answer = pt()
  answer_mark()
  local both = pt()
  tty_ui = true; install()
  chk("I20c a fence is passed by a reset of the books; asked after a reset that forgot requests in flight it still writes a marker; with two terminal UIs it is passed when both answered",
    before == false and after == true and fresh_ok and one_answer == false and both == true,
    ("before the reset %s, after %s, marker after a reset %d (passed after its answer %s), two UIs: after one answer %s, both %s"):format(
      tostring(before), tostring(after), mk, tostring(fresh_ok), tostring(one_answer), tostring(both)))
  Image.clear_for_cell("spec_i20c")
  auto_mark = true
  Image._frame_window = 64 * 1024
  ui_changed()
end
do
  -- a fence whose marker is never answered is passed when the marker is
  -- given up
  local one = string.rep("K", 1000)
  tty_ui = true; ui_send_api = true; install(); ui_changed(); reset()
  Image._remote_mode = true
  auto_mark = false
  Image._frame_window = 1
  local q = hand_gif("spec_i20d", { one, one, one })
  Image._mark_seen = true
  Image._ack_lost_ms = 300
  ui_changed(); reset()
  push(q, 1)                                  -- a marker goes
  local pd = status_fence()
  local before = pd()
  vim.wait(350)
  push(q, 1)                                  -- given up
  local after = pd()
  Image._ack_lost_ms = 30000
  chk("I20d a fence whose marker is never answered is passed when the marker is given up",
    before == false and after == true, ("before %s, after %s"):format(tostring(before), tostring(after)))
  Image.clear_for_cell("spec_i20d")
  auto_mark = true
  Image._frame_window = 64 * 1024
  ui_changed()
end
do
  -- a gif that finds the window full yields to the one that has waited
  -- longest; one that waits for the view (out of view, no stale_at) can never
  -- qualify for a gif that ticks, so its visible probe must not run for it
  local one = string.rep("K", 1000)
  tty_ui = true; ui_send_api = true; install(); ui_changed(); reset()
  Image._remote_mode = true
  auto_mark = true
  Image._frame_window = 64 * 1024
  Image.ensure_transmitted("spec_i21a", one, function() end, { renderer = "placeholder" })
  Image.ensure_transmitted("spec_i21b", one, function() end, { renderer = "placeholder" })
  local A, B = Image._placements.spec_i21a, Image._placements.spec_i21b
  local calls = 0
  pcall(Image.set_visible_probe, "spec_i21a", function() return true end)
  pcall(Image.set_visible_probe, "spec_i21b", function() calls = calls + 1; return false end)
  if A then A.frames, A.delays = { one, one, one }, { 30, 30, 30 } end
  if B then B.frames, B.delays = { one, one }, { 60000, 60000 } end
  ui_changed(); reset()
  Image.resume_animations()
  if B then B.stale = true end               -- skipped out of view: no stale_at
  calls = 0
  vim.wait(400)
  local sent = frames_out()
  chk("I21 a gif ticking in view does not run the visible probe of a gif waiting for the view (it can never qualify)",
    A and B and sent >= 3 and calls == 0, ("frames sent %d, probes of the gif out of view %d"):format(sent, calls))
  Image.clear_for_cell("spec_i21a"); Image.clear_for_cell("spec_i21b")
  auto_mark = true
  Image._frame_window = 64 * 1024
  ui_changed()
end
do
  -- one catch-up sends every waiting gif's frame the window has room for,
  -- the one that has waited longest first. send_frame's own yield always
  -- ends at the gif waiting longest, so a catch-up that picks the wrong gif
  -- first still sends the right gif's frame, but its pick stays waiting and
  -- the catch-up stops after one frame: room for several frames at once
  -- shows it.
  local one = string.rep("K", 1000)
  tty_ui = true; ui_send_api = true; install(); ui_changed(); reset()
  Image._remote_mode = true
  auto_mark = true                            -- the marker is not what this tests
  Image._frame_window = 64 * 1024
  local A = hand_gif("spec_i18ca", { one, one })
  local B = hand_gif("spec_i18cb", { one, one })
  local C = hand_gif("spec_i18cc", { one, one })
  ui_changed(); reset()
  local function order_of(ks)
    for i, g in ipairs({ A, B, C }) do
      if g then g.stale = true; g.stale_at = vim.uv.hrtime() - ks[i] * 1e9 end
    end
    reset()
    catch_up()
    local o = {}
    for _, x in ipairs(ui_out) do
      if is_tx(x) then
        for i, g in ipairs({ A, B, C }) do
          if g and x:find("i=" .. g.image_id .. ",", 1, true) then o[#o + 1] = ({ "A", "B", "C" })[i] end
        end
      end
    end
    return table.concat(o)
  end
  local o1 = order_of({ 3, 2, 1 })
  for _ = 1, 3 do answer() end
  local o2 = order_of({ 1, 2, 3 })
  for _ = 1, 3 do answer() end
  chk("I18c one catch-up sends every waiting gif's frame the window has room for, the one waiting longest first, whatever the order of the placements",
    o1 == "ABC" and o2 == "CBA", ("A waited longest: %s, C waited longest: %s"):format(o1, o2))
  for _, k in ipairs({ "spec_i18ca", "spec_i18cb", "spec_i18cc" }) do Image.clear_for_cell(k) end
  auto_mark = true
  Image._frame_window = 64 * 1024
  ui_changed()
end
do
  -- a gif whose clock ticks yields the room to a gif that has waited longer
  local one = string.rep("K", 1000)
  tty_ui = true; ui_send_api = true; install(); ui_changed(); reset()
  Image._remote_mode = true
  auto_mark = false
  Image._frame_window = 64 * 1024
  local A2 = hand_gif("spec_i18da", { one, one })
  Image.ensure_transmitted("spec_i18db", one, function() end, { renderer = "placeholder" })
  local B2 = Image._placements.spec_i18db
  pcall(Image.set_visible_probe, "spec_i18db", function() return true end)
  if B2 then B2.frames, B2.delays = { one, one, one }, { 30, 30, 30 } end
  ui_changed(); reset()
  Image.resume_animations()
  vim.wait(300, function() return marks_out() > 0 end, 5)  -- B's tick sent the marker
  answer_mark()
  vim.wait(100)
  answer(); answer(); answer()                -- nothing in flight, B not waiting
  if A2 then A2.stale = true; A2.stale_at = vim.uv.hrtime() - 2e9 end
  reset()
  vim.wait(200)
  local first
  for _, x in ipairs(ui_out) do if is_tx(x) then first = x break end end
  chk("I18d a gif whose clock ticks yields the room to a gif that has waited longer",
    A2 and first and first:find("i=" .. A2.image_id .. ",", 1, true) ~= nil,
    ("first transmit %s, A=%s B=%s"):format(tostring(first and first:sub(1, 40)), tostring(A2 and A2.image_id),
      tostring(B2 and B2.image_id)))
  Image.clear_for_cell("spec_i18da"); Image.clear_for_cell("spec_i18db")
  auto_mark = true
  Image._frame_window = 64 * 1024
  ui_changed()
end
do
  -- a terminal that answers, but slowly (a slow link, a frame that takes
  -- seconds to read): the frames must not pile up in it
  local F = {}
  for i = 1, 3 do F[i] = vim.base64.encode(png(40, 30, 50 + i)) end
  -- a terminal that answers no XTVERSION: markers are off, and before its
  -- first answer a request is given up
  Image._mark_off = true
  tty_ui = true; ui_send_api = true; install(); ui_changed(); reset()
  Image._frame_window = 1
  Image._ack_timeout_ms = 300
  local p = hand_gif("spec_i10", F)
  local a = push(p, 1)                 -- its request has no answer yet
  local early = push(p, 2)             -- no room
  vim.wait(350)
  local to0 = Image._ack_timeouts or 0
  local b = push(p, 2)                 -- the first request given up: the frame goes
  local to1 = (Image._ack_timeouts or 0) - to0
  answer()                             -- the first request's answer, late
  local c = push(p, 3)                 -- the second frame is still in flight
  local d = answer_then_push(p, 3)
  chk("I10 before the terminal has answered, a request unanswered for the timeout is given up and the next frame goes, but its late answer frees nothing newer",
    a and not early and b and to1 == 1 and not c and d,
    ("sent %s, while in flight %s, after the timeout %s (%d timeouts), after the late answer %s, after the next %s"):format(
      tostring(a), tostring(early), tostring(b), to1, tostring(c), tostring(d)))
  -- the terminal has answered now: it reads, if slowly, and is waited for
  vim.wait(700)
  local to2 = Image._ack_timeouts or 0
  local e = push(p, 1)
  vim.wait(400)
  local f = push(p, 1)
  local to3 = (Image._ack_timeouts or 0) - to2
  local g = answer_then_push(p, 1)
  chk("I11 once the terminal has answered, a slow answer is waited for: no timeout lets a frame by, the answer does",
    not e and not f and to3 == 0 and g,
    ("after 0.7 s %s, after 1.1 s %s, timeouts %d, after the answer %s"):format(tostring(e), tostring(f), to3, tostring(g)))
  Image.clear_for_cell("spec_i10")
  Image._ack_timeout_ms = 3000
  Image._mark_off = false
end
do
  -- an answer lost on its way (the terminal answered, the event never
  -- reached the editor) must not keep the window shut for good
  local F = {}
  for i = 1, 3 do F[i] = vim.base64.encode(png(40, 30, 60 + i)) end
  tty_ui = true; ui_send_api = true; install(); ui_changed(); reset()
  Image._frame_window = 1
  Image._ack_lost_ms = 400
  local p = hand_gif("spec_i12", F)
  push(p, 1); answer()                 -- answered at once: the terminal answers
  local to0 = Image._ack_timeouts or 0
  local a = push(p, 2)                 -- this answer is lost
  vim.wait(200)
  local b = push(p, 3)
  vim.wait(300)
  local c = push(p, 3)
  chk("I12 once the terminal has answered, requests with no answer at all for the lost limit are dropped and frames go again",
    a and not b and c and (Image._ack_timeouts or 0) - to0 == 1,
    ("sent %s, after 0.2 s %s, after 0.5 s %s, given up %d"):format(tostring(a), tostring(b), tostring(c),
      (Image._ack_timeouts or 0) - to0))
  -- the limit grows with the longest wait for an answer seen: a terminal
  -- that once took 0.3 s gets four times that before its answers count as
  -- lost
  ui_changed(); reset()
  Image._ack_lost_ms = 200
  push(p, 1)
  vim.wait(300)
  answer()                             -- 0.3 s for that answer
  local d = push(p, 2)
  vim.wait(500)
  local e = push(p, 3)                 -- past the 0.2 s floor, within 4 x 0.3 s
  vim.wait(900)
  local f = push(p, 3)
  chk("I12b the lost limit is at least four times the longest wait for an answer so far",
    d and not e and f, ("sent %s, after 0.5 s %s, after 1.4 s %s"):format(tostring(d), tostring(e), tostring(f)))
  -- ... but one very long wait does not stretch the limit for good: the
  -- longest wait counts at most as the lost limit itself (a terminal that
  -- stalled for a minute once is not given four minutes after that)
  ui_changed(); reset()
  Image._ack_lost_ms = 100
  push(p, 1)
  vim.wait(700)
  answer()                             -- 0.7 s for that answer
  local g = push(p, 2)                 -- this answer is lost
  vim.wait(500)
  local h = push(p, 3)                 -- past four times the limit (0.4 s), not 4 x 0.7 s
  chk("I12c one very long wait for an answer does not stretch the lost limit beyond four times the limit itself",
    g and h, ("sent %s, after 0.5 s %s"):format(tostring(g), tostring(h)))
  Image._ack_lost_ms = 30000
  Image.clear_for_cell("spec_i12")
end
do
  -- the terminal answers in order, so an answer is the oldest request's:
  -- a big frame then a small one in flight, one answer frees the big one's
  -- bytes (raw strings stand in for the frames: only their sizes matter)
  tty_ui = true; ui_send_api = true; install(); ui_changed(); reset()
  Image._frame_window = 4500
  local big, small, mid = string.rep("A", 3000), string.rep("B", 1000), string.rep("C", 2500)
  local p = hand_gif("spec_i13", { big, small, mid })
  local a, b, c = push(p, 1), push(p, 2), push(p, 3)
  local d = answer_then_push(p, 3)
  chk("I13 an answer frees the oldest frame's bytes (3000 and 1000 in a 4500 window, then 2500 fits)",
    a and b and not c and d, ("%s %s %s, after one answer %s"):format(tostring(a), tostring(b), tostring(c), tostring(d)))
  Image.clear_for_cell("spec_i13")
  -- small frames across several answered rounds: each answer frees its
  -- frame's bytes, so several frames go per round, not one
  ui_changed(); reset()
  local one = string.rep("D", 1000)
  local q = hand_gif("spec_i14", { one, one, one, one })
  local first = 0
  for i = 1, 6 do if push(q, (i - 1) % 4 + 1) then first = first + 1 end end
  -- the frames that found no room go as their answers free it
  local before = Image._frames_sent or 0
  for _ = 1, 4 do answer() end
  for i = 1, 6 do push(q, (i - 1) % 4 + 1) end
  local second = (Image._frames_sent or 0) - before
  chk("I14 every answer frees its frame's bytes: four 1000-byte frames per 4500-byte round, round after round",
    first == 4 and second == 4, ("first round %d, after four answers %d"):format(first, second))
  Image.clear_for_cell("spec_i14")
  Image._frame_window = 64 * 1024
end
do
  -- two terminal UIs (one attached with nvim --remote-ui): each gets every
  -- request and answers it, and an answer does not say whose it is. A frame
  -- counts as read only once the slower terminal can have answered it, or
  -- the faster one paces the gif and the slower one's queue grows without
  -- bound.
  local F = {}
  for i = 1, 3 do F[i] = string.rep(string.char(69 + i), 1000) end
  tty_ui = "two"; ui_send_api = true; install(); ui_changed(); reset()
  Image._frame_window = 1
  local p = hand_gif("spec_i15", F)
  local a = push(p, 1)
  answer()                             -- the faster terminal's answer
  local b = push(p, 2)
  local c = answer_then_push(p, 2)     -- the slower one's
  chk("I15 with two terminal UIs a frame counts as read once both answered",
    a and not b and c, ("sent %s, after one answer %s, after two %s"):format(tostring(a), tostring(b), tostring(c)))
  -- two requests in flight, both answered by the faster terminal: the
  -- slower one may have read neither
  ui_changed(); reset()
  Image._frame_window = 2500
  local d, e = push(p, 1), push(p, 2)
  answer(); answer()
  local f = push(p, 3)
  local g = answer_then_push(p, 3)     -- the slower terminal's first
  chk("I15b two requests in flight to two terminal UIs: the faster one's two answers free nothing, the slower one's first frees the first frame",
    d and e and not f and g, ("sent %s %s, after the faster's answers %s, after the slower's first %s"):format(
      tostring(d), tostring(e), tostring(f), tostring(g)))
  Image.clear_for_cell("spec_i15")
  Image._frame_window = 64 * 1024
  tty_ui = true; install(); ui_changed()
end
do
  -- Two gifs in view share the window. The room an answer frees goes to the
  -- gif that has waited longest, not to whichever ticks first: a fast gif
  -- would take it every time and a slow one (a frame a second) would never
  -- get a frame while the window is the bottleneck. The fast gif here
  -- ticks every 30 ms; the slow one's clock does not tick (a minute), it
  -- tries to send as a gif does when its tick comes.
  local FS, FF = {}, {}
  for i = 1, 3 do
    FS[i] = vim.base64.encode(png(40, 30, 100 + i))
    FF[i] = vim.base64.encode(png(40, 30, 110 + i))
  end
  tty_ui = true; ui_send_api = true; install(); ui_changed(); reset()
  Image._frame_window = 1
  local slow = hand_gif("spec_i18s", FS)
  Image.ensure_transmitted("spec_i18f", FF[1], function() end, { renderer = "placeholder" })
  local fast = Image._placements.spec_i18f
  pcall(Image.set_visible_probe, "spec_i18f", function() return true end)
  if fast then fast.frames, fast.delays = FF, { 30, 30, 30 } end
  local function of(p)
    if not p then return -1 end
    return count(ui_out, function(x) return is_tx(x) and x:find("i=" .. p.image_id .. ",", 1, true) ~= nil end)
  end
  vim.wait(100); reset()                      -- the images are transmitted; count the frames from here
  Image.resume_animations()
  vim.wait(200)                               -- the fast gif sent a frame; its next ticks found no room
  local f0 = of(fast)
  local s0 = push(slow, 1)                    -- the slow gif's tick finds the window full
  answer()                                    -- room: the fast gif has waited longer
  vim.wait(150)                               -- the fast gif's clock ticks again and waits again
  local f1, s1 = of(fast), of(slow)
  answer()                                    -- room: now the slow gif has waited longer
  vim.wait(150)
  local f2, s2 = of(fast), of(slow)
  chk("I18 with two gifs in view the room an answer frees goes to the gif that has waited longest: the slow gif is not starved by the fast one",
    fast and slow and f0 == 1 and not s0 and f1 == 2 and s1 == 0 and s2 == 1 and f2 == 2,
    ("fast frames %s %s %s, slow frames %s %s after the 1st and 2nd answer"):format(
      tostring(f0), tostring(f1), tostring(f2), tostring(s1), tostring(s2)))
  Image.clear_for_cell("spec_i18s"); Image.clear_for_cell("spec_i18f")
  Image._frame_window = 64 * 1024
  ui_changed()
end
do
  -- The room can also come with no answer: the terminal has not answered at
  -- all and the one request given up (the timeout). The gif whose clock
  -- ticks next must not take it when another gif in view has waited
  -- longer.
  local FS, FF = {}, {}
  for i = 1, 3 do
    FS[i] = vim.base64.encode(png(40, 30, 130 + i))
    FF[i] = vim.base64.encode(png(40, 30, 140 + i))
  end
  -- a terminal that answers no XTVERSION: markers are off, and before its
  -- first answer a request is given up
  Image._mark_off = true
  tty_ui = true; ui_send_api = true; install(); ui_changed(); reset()
  Image._frame_window = 1
  Image._ack_timeout_ms = 300
  local slow = hand_gif("spec_i18t", FS)
  Image.ensure_transmitted("spec_i18u", FF[1], function() end, { renderer = "placeholder" })
  local fast = Image._placements.spec_i18u
  pcall(Image.set_visible_probe, "spec_i18u", function() return true end)
  if fast then fast.frames, fast.delays = FF, { 30, 30, 30 } end
  local function of(p)
    if not p then return -1 end
    return count(ui_out, function(x) return is_tx(x) and x:find("i=" .. p.image_id .. ",", 1, true) ~= nil end)
  end
  vim.wait(100); reset()
  Image.resume_animations()
  vim.wait(120)                               -- the fast gif sent a frame and waits since
  if slow and fast then slow.stale, slow.stale_at = true, (fast.stale_at or vim.uv.hrtime()) - 1000 end
  local f0, s0 = of(fast), of(slow)
  vim.wait(500)                               -- the request is given up after 300 ms
  local f1, s1 = of(fast), of(slow)
  chk("I18b the room a given-up request makes goes to the gif that has waited longest, not to the one whose clock ticks first",
    fast and slow and f0 == 1 and s0 == 0 and s1 == 1 and f1 == 1,
    ("fast frames %s then %s, slow frames %s then %s"):format(tostring(f0), tostring(f1), tostring(s0), tostring(s1)))
  Image._ack_timeout_ms = 3000
  Image._mark_off = false
  Image.clear_for_cell("spec_i18t"); Image.clear_for_cell("spec_i18u")
  Image._frame_window = 64 * 1024
  ui_changed()
end
do
  -- quitting or CTRL-Z: Neovim's UI stops reading the terminal right after,
  -- so an answer still on its way would reach the shell. The requests in
  -- flight are answered first, with nothing new sent meanwhile.
  local F = {}
  for i = 1, 3 do F[i] = vim.base64.encode(png(40, 30, 70 + i)) end
  tty_ui = true; ui_send_api = true; install(); ui_changed(); reset()
  local p = hand_gif("spec_i16", F)
  push(p, 1); answer()                 -- the terminal answers
  push(p, 2); push(p, 3)               -- two requests in flight
  local n_before = acks_n()
  -- their answers, then the answer to the drain's own request (a marker,
  -- which the stand-in terminal answers only when told)
  auto_mark = false
  vim.defer_fn(answer, 150)
  vim.defer_fn(answer, 300)
  vim.defer_fn(answer_mark, 450)
  reset()
  local t0 = vim.uv.now()
  fire("VimLeavePre")
  local waited = vim.uv.now() - t0
  local n_after, sent_during = acks_n(), vim.deepcopy(ui_out)
  local held_after = Image._writes_held and Image._writes_held()
  local after = push(p, 1)
  chk("I16 before the editor quits, the requests in flight and one more request of its own (a marker) are answered first, and nothing else is written from then on",
    n_before == 2 and n_after == 0 and waited >= 400 and waited < 2500 and #sent_during == 1 and sent_during[1] == MARK
      and marks_out() == 1 and held_after and not after,
    ("in flight %d then %d, waited %d ms, written meanwhile %s, held after %s, a frame after %s"):format(
      n_before, n_after, waited, vim.inspect(sent_during), tostring(held_after), tostring(after)))
  Image._leaving = false
  auto_mark = true
  -- CTRL-Z: the same before the UI suspends
  ui_changed(); reset()
  push(p, 1); answer(); push(p, 2)
  auto_mark = false
  vim.defer_fn(answer, 200)
  vim.defer_fn(answer_mark, 350)
  reset()
  t0 = vim.uv.now()
  fire("VimSuspend")
  waited = vim.uv.now() - t0
  n_after, sent_during = acks_n(), vim.deepcopy(ui_out)
  chk("I16b before the UI suspends (CTRL-Z), the request in flight and one of its own (a marker) are answered first",
    n_after == 0 and waited >= 300 and waited < 2500 and #sent_during == 1 and sent_during[1] == MARK
      and marks_out() == 1,
    ("in flight after %d, waited %d ms, written meanwhile %s"):format(n_after, waited, vim.inspect(sent_during)))
  auto_mark = true
  fire("VimResume")
  -- another program's status answer was taken for a frame's (none counts in
  -- flight, but the frame's own answer is still on its way): the drain's own
  -- request is what is waited for, and all that can be left in flight
  ui_changed(); reset()
  push(p, 1); answer(); push(p, 2)
  answer()                             -- another program's, taken for the frame's
  local n_counted = acks_n()
  auto_mark = false
  vim.defer_fn(answer_mark, 150)       -- the answer to the drain's own request, after the frame's
  reset()
  t0 = vim.uv.now()
  fire("VimLeavePre")
  waited = vim.uv.now() - t0
  chk("I16g with none counted in flight but a frame's answer still on its way, the drain before a quit still asks once (a marker) and waits",
    n_counted == 0 and #ui_out == 1 and ui_out[1] == MARK and marks_out() == 1 and waited >= 100 and waited < 2500,
    ("counted in flight %d, written %s, waited %d ms"):format(n_counted, vim.inspect(ui_out), waited))
  Image._leaving = false
  auto_mark = true
  -- a terminal that has not answered since the UI attached: nothing to wait
  -- for (markers are off: one that answers no XTVERSION)
  Image._mark_off = true
  ui_changed(); reset()
  push(p, 1)
  t0 = vim.uv.now()
  fire("VimSuspend")
  local w1 = vim.uv.now() - t0
  fire("VimResume")
  Image._mark_off = false
  chk("I16c with markers off, a terminal that has not answered yet is not waited for", w1 < 100, ("waited %d ms"):format(w1))
  -- :detach: no event comes before the UI stops, but its UILeave comes while
  -- the UI still reads the terminal; the requests are answered there when
  -- no terminal UI is left and the client that left still runs (its pid is
  -- in its channel's client info: here the spec's own process, alive)
  -- (a channel of the spec's own: 77 a UI client that is running, 79 one that
  -- was killed or whose terminal closed, whose channel is still listed at its
  -- UILeave but takes no notification, 78 a channel that has closed. As
  -- Neovim does it: a notification to a channel that is gone fails with
  -- "Invalid channel".)
  local real_info = vim.api.nvim_get_chan_info
  local real_notify = vim.rpcnotify
  local client_pid
  vim.api.nvim_get_chan_info = function(ch)
    if ch == 77 or ch == 79 or ch == -1 then return { id = ch, client = { type = "ui", attributes = { pid = client_pid } } } end
    if ch == 78 then return {} end  -- a channel that has closed
    return real_info(ch)
  end
  vim.rpcnotify = function(ch, ...)
    if ch == 79 then error("Invalid channel: 79") end
    if ch == 77 or ch == -1 then return 1 end
    return real_notify(ch, ...)
  end
  local function leave_waits(remaining, chan)
    ui_changed(); reset()
    push(p, 1); answer(); push(p, 2)
    vim.defer_fn(answer, 200)
    tty_ui = remaining; install()
    local t = vim.uv.now()
    pcall(Image._drain_on_leave, chan or 77)
    local w = vim.uv.now() - t
    local n = acks_n()
    tty_ui = true; install(); ui_changed()
    vim.wait(300)
    return w, n
  end
  client_pid = vim.fn.getpid()
  local wd, nd = leave_waits(false)
  chk("I16d a :detach (no terminal UI left, its client still running) waits for the requests in flight",
    Image._drain_on_leave ~= nil and wd >= 150 and wd < 2500 and nd == 0, ("waited %d ms, in flight after %d"):format(wd, nd))
  -- the same :detach through the UILeave autocmd: UILeave fired by hand has
  -- no v:event, so the autocmd passes no channel and drain_on_leave asks
  -- for the client info of channel -1 (answered like channel 77 here)
  local function leave_waits_autocmd()
    ui_changed(); reset()
    push(p, 1); answer(); push(p, 2)
    vim.defer_fn(answer, 200)
    tty_ui = false; install()
    local t = vim.uv.now()
    pcall(vim.api.nvim_exec_autocmds, "UILeave", { group = "jupynvim_image_ui" })
    local w = vim.uv.now() - t
    tty_ui = true; install(); ui_changed()
    vim.wait(300)
    return w
  end
  local wa = leave_waits_autocmd()
  chk("I16h the UILeave of a :detach drains the requests in flight (through its autocmd)",
    wa >= 150 and wa < 2500, ("waited %d ms"):format(wa))
  local gone = vim.system({ "true" }); gone:wait()
  client_pid = vim.fn.getpid()
  local wg = leave_waits(false, 79)
  chk("I16e a UI whose client is gone (its terminal closed, it was killed: its channel takes no notification) is not waited for",
    wg < 100, ("waited %d ms"):format(wg))
  client_pid = vim.fn.getpid()
  local wr, nr = leave_waits(true)
  chk("I16f a UI leaving while another terminal UI shows the editor is waited for as well: its answers would reach its shell",
    wr >= 150 and wr < 2500 and nr == 0, ("waited %d ms, in flight after %d"):format(wr, nr))
  -- meanwhile no frame goes out, though the other UI still takes writes: a
  -- fast gif ticks all the while
  do
    local TF = {}
    for i = 1, 3 do TF[i] = vim.base64.encode(png(40, 30, 120 + i)) end
    Image.ensure_transmitted("spec_i16t", TF[1], function() end, { renderer = "placeholder" })
    local pt = Image._placements.spec_i16t
    pcall(Image.set_visible_probe, "spec_i16t", function() return true end)
    if pt then pt.frames, pt.delays = TF, { 20, 20, 20 } end
    ui_changed(); reset()
    push(p, 1); answer(); push(p, 2)
    tty_ui = true; install()
    vim.wait(100); reset()
    Image.resume_animations()
    vim.defer_fn(answer, 250)
    local t = vim.uv.now()
    pcall(Image._drain_on_leave, 77)
    local w = vim.uv.now() - t
    local during = count(ui_out, function(x)
      return is_tx(x) and pt and x:find("i=" .. pt.image_id .. ",", 1, true) ~= nil
    end)
    Image.clear_for_cell("spec_i16t")
    ui_changed(); vim.wait(100)
    chk("I16i while a UI leaving is waited for, no frame goes out to the UIs that stay",
      pt and w >= 150 and during == 0, ("waited %d ms, frames sent meanwhile %d"):format(w, during))
  end
  -- a client of another host or another pid namespace (a forwarded unix
  -- socket, a dev container): its pid is no process here, but its channel is
  -- open and takes the notification, so it is alive and waited for, whether
  -- the editor listens on a unix socket only or on a TCP port too
  local real_serverlist = vim.fn.serverlist
  client_pid = gone.pid
  vim.fn.serverlist = function() return { tmp .. "/nvim.sock" } end
  local wf, nf = leave_waits(false)
  vim.fn.serverlist = function() return { tmp .. "/nvim.sock", "127.0.0.1:6666" } end
  local wf2, nf2 = leave_waits(false)
  vim.fn.serverlist = real_serverlist
  chk("I16j a client whose pid is no process here (another pid namespace, a forwarded socket) is waited for, on a unix socket or a TCP port",
    wf >= 150 and wf < 2500 and nf == 0 and wf2 >= 150 and wf2 < 2500 and nf2 == 0,
    ("unix socket: waited %d ms, in flight after %d; TCP: waited %d ms, in flight after %d"):format(wf, nf, wf2, nf2))
  -- a live process of another user (kill says EPERM) is alive
  client_pid = 1
  local we, ne = leave_waits(false)
  chk("I16k a client whose process belongs to another user (EPERM) is alive: it is waited for",
    we >= 150 and we < 2500 and ne == 0, ("waited %d ms, in flight after %d"):format(we, ne))
  -- a channel that has closed already: nothing more is answered
  client_pid = vim.fn.getpid()
  local wc = leave_waits(false, 78)
  chk("I16l a UI whose channel has closed is not waited for", wc < 100, ("waited %d ms"):format(wc))
  -- the same on real channels of this Neovim: a client that runs takes the
  -- notification, one that was stopped does not
  do
    local job = vim.fn.jobstart({ vim.v.progpath, "--embed", "--headless", "-u", "NONE", "-i", "NONE" }, { rpc = true })
    local alive = job > 0 and pcall(real_notify, job, "nvim_eval", "1")
    client_pid = vim.fn.getpid()
    local w_live = alive and leave_waits(false, job) or -1
    if job > 0 then vim.fn.jobstop(job) end
    vim.wait(3000, function() return not pcall(real_notify, job, "nvim_eval", "1") end, 20)
    local w_dead = leave_waits(false, job)
    chk("I16q on real channels: a client that runs is waited for, one that was stopped is not",
      alive and w_live >= 150 and w_live < 2500 and w_dead < 100,
      ("alive %s, running client: waited %d ms, stopped: waited %d ms"):format(tostring(alive), w_live, w_dead))
  end
  vim.api.nvim_get_chan_info = real_info
  vim.rpcnotify = real_notify
  Image.clear_for_cell("spec_i16")
  ui_changed()
end

do
  -- tmux before 3.2 answers status requests but not XTVERSION: inside one
  -- (`tmux -V` says so) markers start off, so the first GIF of a session plays
  -- at once, not after the lost limit (30 s)
  local F = {}
  for i = 1, 3 do F[i] = vim.base64.encode(png(40, 30, 400 + i)) end
  tty_ui = true; ui_send_api = true; install(); ui_changed(); reset()
  Image._remote_mode = true
  auto_mark = false
  local p = hand_gif("spec_i22", F)
  Image._mark_seen, Image._mark_off = false, false
  ui_changed(); reset()
  if Image._tmux_version then Image._tmux_version("tmux 3.1c") end
  local off1 = Image._mark_off
  local g1 = push(p, 1)                        -- no marker to wait for: the frame goes at once
  chk("I22 inside tmux 3.1c markers start off: the first frame goes at once, with no marker written",
    off1 == true and g1 and marks_out() == 0 and frames_out() == 1 and count(ui_out, is_req) == 1,
    ("markers off %s, frame sent %s, markers written %d, frames %d, requests %d"):format(
      tostring(off1), tostring(g1), marks_out(), frames_out(), count(ui_out, is_req)))
  -- which versions: before 3.2 (3.0a and 3.1c were checked, 2.x answers fewer
  -- requests still), not 3.2 and newer, nor what cannot be read
  local VERS = { { "tmux 3.0a", true }, { "tmux 3.1c", true }, { "tmux 2.7", true }, { "tmux 3.2", false },
                 { "tmux 3.2a", false }, { "tmux 3.5a", false }, { "tmux next-3.4", false }, { "tmux 3.10", false },
                 { "tmux master", false }, { "tmux 4.0", false }, { "", false }, { "garbage", false } }
  local wrong = {}
  for _, v in ipairs(VERS) do
    Image._mark_seen, Image._mark_off = false, false
    if Image._tmux_version then Image._tmux_version(v[1]) end
    if Image._mark_off ~= v[2] then wrong[#wrong + 1] = ("%q: off %s"):format(v[1], tostring(Image._mark_off)) end
  end
  Image._mark_off = false
  if Image._tmux_version then pcall(Image._tmux_version, nil) end
  chk("I22b tmux before 3.2 turns markers off; 3.2 and newer, a development build and what cannot be read do not",
    Image._tmux_version ~= nil and #wrong == 0 and Image._mark_off == false, table.concat(wrong, "; "))
  -- a terminal that answered a marker answers them: the version changes nothing
  Image._mark_seen, Image._mark_off = true, false
  if Image._tmux_version then Image._tmux_version("tmux 3.1c") end
  chk("I22c once a marker was answered, an old tmux version changes nothing", Image._mark_off == false)
  -- a marker on its way when the version is learned is given up (no answer will come)
  Image.clear_for_cell("spec_i22")
  Image._mark_seen, Image._mark_off = false, false
  local q = hand_gif("spec_i22d", F)
  ui_changed(); reset()
  local l0 = Image._marks_lost or 0
  push(q, 1)                                   -- the marker goes, no frame
  local d0 = Image._acks_info and Image._acks_info() or {}
  if Image._tmux_version then Image._tmux_version("tmux 3.1c") end
  local d1 = Image._acks_info and Image._acks_info() or {}
  local g2 = push(q, 2)
  chk("I22d a marker on its way when tmux -V says 3.1c is given up: the next frame goes",
    d0.mark == 1 and d1.mark == 0 and (Image._marks_lost or 0) - l0 == 1 and Image._mark_off == true and g2,
    ("marker due %s then %s, given up %d, markers off %s, next frame %s"):format(tostring(d0.mark), tostring(d1.mark),
      (Image._marks_lost or 0) - l0, tostring(Image._mark_off), tostring(g2)))
  -- an answer to XTVERSION that comes after all shows the terminal answers it
  answer_mark()
  chk("I22e a marker answer after that turns markers on again", Image._mark_off == false and Image._mark_seen == true)
  Image.clear_for_cell("spec_i22d")
  Image._mark_seen, Image._mark_off = true, false
  auto_mark = true
  ui_changed()
end
do
  -- The drains wait as long as the link needs: a frame that takes seconds to
  -- reach the terminal has its answer read before the UI stops, or the answer
  -- reaches the shell. The limit follows the longest wait for an answer so
  -- far, for every request in flight and the marker.
  local F = {}
  for i = 1, 3 do F[i] = vim.base64.encode(png(40, 30, 410 + i)) end
  tty_ui = true; ui_send_api = true; install(); ui_changed(); reset()
  Image._remote_mode = true
  auto_mark = false
  Image._mark_seen = true
  Image._ack_timeout_ms = 200
  local p = hand_gif("spec_i23", F)
  ui_changed(); reset()
  push(p, 1); answer_mark()                    -- the marker is answered, frame 1 goes
  vim.wait(600)
  answer()                                     -- its answer took 600 ms
  local q0 = Image._acks_info and Image._acks_info() or {}
  push(p, 2)                                   -- frame 2 in flight
  vim.defer_fn(function() answer(); answer_mark() end, 900)
  local t = vim.uv.now()
  fire("VimLeavePre")
  local wd = vim.uv.now() - t
  Image._leaving = false
  local q1 = Image._acks_info and Image._acks_info() or {}
  chk("I23 the drain before a quit waits for the link: a frame that took 600 ms to be answered is waited for beyond the 200 ms limit",
    q0.n == 0 and wd >= 800 and q1.n == 0 and q1.mark == 0,
    ("in flight before %s, waited %d ms, in flight after %s, marker due after %s"):format(tostring(q0.n), wd, tostring(q1.n), tostring(q1.mark)))
  -- the books start over at a resume or an attach, the link does not: the
  -- first frame after it needs as long as the frames before did. What is
  -- measured after the reset is the marker's round trip, which is short
  -- (little is written before it)
  if Image._ui_changed then Image._ui_changed("resume") end
  local k1 = Image._acks_info and Image._acks_info() or {}
  reset()
  push(p, 3); answer_mark()                    -- the marker is answered at once, frame 3 goes
  local k2 = Image._acks_info and Image._acks_info() or {}
  vim.defer_fn(function() answer(); answer_mark() end, 900)
  local t3 = vim.uv.now()
  fire("VimLeavePre")
  local wk = vim.uv.now() - t3
  Image._leaving = false
  local k3 = Image._acks_info and Image._acks_info() or {}
  chk("I23c after a resume the first frame is still waited for as the link needs: the drain rests on what the session has seen, not on the marker's round trip",
    k1.quiet == 0 and (k1.link or 0) >= 550 and k2.n == 1 and (k2.quiet or 9999) < 300 and wk >= 800 and k3.n == 0 and k3.mark == 0,
    ("after the reset: this reset's longest wait %s, the session's %s; in flight %s; waited %d ms, in flight after %s, marker due %s"):format(
      tostring(k1.quiet), tostring(k1.link), tostring(k2.n), wk, tostring(k3.n), tostring(k3.mark)))
  -- the wait has a bound: with many requests in flight a terminal that
  -- stopped answering is not waited for beyond the lost limit (the larger of
  -- M._ack_lost_ms and four times the longest wait), however many requests
  -- there are
  Image._ack_lost_ms = 400
  Image._ack_timeout_ms = 100
  Image._frame_window = 1000000
  ui_changed(); reset()
  push(p, 1); answer_mark()
  vim.wait(300); answer()
  for i = 2, 6 do push(p, ((i - 1) % 3) + 1) end
  local b0 = Image._acks_info and Image._acks_info() or {}
  local t2 = vim.uv.now()
  fire("VimLeavePre")
  local wb = vim.uv.now() - t2
  Image._leaving = false
  local bound = math.max(400, 4 * (b0.quiet or 0))
  chk("I23b and it is bounded: five requests and a marker in flight with a terminal that answers nothing more are waited for no longer than the lost limit",
    b0.n == 5 and (b0.quiet or 0) >= 250 and wb >= bound - 150 and wb < bound + 400 and wb < 6 * (b0.quiet or 0) - 100,
    ("in flight %s, longest wait %s ms, waited %d ms, lost limit %d ms"):format(tostring(b0.n), tostring(b0.quiet), wb, bound))
  Image._ack_lost_ms = 30000
  Image._ack_timeout_ms = 3000
  Image._frame_window = 64 * 1024
  Image.clear_for_cell("spec_i23")
  auto_mark = true
  ui_changed()
end
do
  -- A marker still on its way when the books are reset (a UI attaches or
  -- leaves): the UIs that stay answer it late, behind the next marker's
  -- answers too. The next marker waits for them as well, or the old
  -- marker's late answer ends it early and a frame goes before it was
  -- answered by every UI.
  local F = {}
  for i = 1, 3 do F[i] = vim.base64.encode(png(40, 30, 420 + i)) end
  tty_ui = true; ui_send_api = true; install(); ui_changed(); reset()
  Image._remote_mode = true
  auto_mark = false
  Image._mark_seen = true
  Image._frame_window = 1
  local p = hand_gif("spec_i24", F)
  ui_changed(); reset()
  push(p, 1)                                   -- marker M_a goes (one UI), no frame
  tty_ui = "two"; install()
  if Image._ui_changed then Image._ui_changed("enter") end  -- a second UI attaches: the books are reset
  local c1 = Image._acks_info and Image._acks_info() or {}
  push(p, 2)                                   -- marker M_b goes: both UIs, and the one still owed
  local c2 = Image._acks_info and Image._acks_info() or {}
  answer_mark()                                -- M_a's answer, late
  answer_mark()                                -- the first UI's answer to M_b
  local f_mid = frames_out()
  answer_mark()                                -- the second UI's answer to M_b: the last
  local f_end = frames_out()
  chk("I24 a UI attaching while a marker is on its way: the next marker also waits for the old one's late answer, and no frame goes before the last answer",
    c1.carry == 1 and c2.mark == 3 and f_mid == 0 and f_end == 1,
    ("owed on after the reset %s, marker due %s, frames after two answers %d, after the last %d"):format(
      tostring(c1.carry), tostring(c2.mark), f_mid, f_end))
  -- a UI leaving: the leaving UI may or may not have answered, so the count
  -- is the lower bound (never a wait for an answer that cannot come)
  Image.clear_for_cell("spec_i24")
  tty_ui = "two"; install(); ui_changed(); reset()
  local p2 = hand_gif("spec_i24b", F)
  ui_changed(); reset()
  push(p2, 1)                                  -- marker due from two UIs
  tty_ui = true; install()
  if Image._ui_changed then Image._ui_changed("leave") end
  local l1 = Image._acks_info and Image._acks_info() or {}
  push(p2, 2)
  local l2 = Image._acks_info and Image._acks_info() or {}
  chk("I24b a UI leaving while a marker is on its way from both: the one that stays still owes the old answer",
    l1.carry == 1 and l2.mark == 2, ("owed on %s, marker due %s"):format(tostring(l1.carry), tostring(l2.mark)))
  answer_mark(); answer_mark()
  -- the old marker's late answer that comes before the next marker is sent
  -- is taken off what is owed: the next marker is the UIs' alone
  Image.clear_for_cell("spec_i24b")
  tty_ui = true; install(); ui_changed(); reset()
  local pe = hand_gif("spec_i24e", F)
  ui_changed(); reset()
  push(pe, 1)                                  -- marker M_a goes (one UI)
  tty_ui = "two"; install()
  if Image._ui_changed then Image._ui_changed("enter") end
  local e1 = Image._acks_info and Image._acks_info() or {}
  answer_mark()                                -- M_a's late answer, no marker due
  local e2 = Image._acks_info and Image._acks_info() or {}
  push(pe, 2)
  local e3 = Image._acks_info and Image._acks_info() or {}
  chk("I24e the late answer of the old marker is taken off what is owed: the next marker waits for the UIs' answers alone",
    e1.carry == 1 and e2.carry == 0 and e3.mark == 2,
    ("owed on after the reset %s, after the late answer %s, marker due %s"):format(tostring(e1.carry), tostring(e2.carry), tostring(e3.mark)))
  answer_mark(); answer_mark()
  -- an attach when the list holds only the new UI (the one the marker went
  -- to is gone): nothing is owed on
  Image.clear_for_cell("spec_i24e")
  tty_ui = true; install(); ui_changed(); reset()
  local pf = hand_gif("spec_i24f", F)
  ui_changed(); reset()
  push(pf, 1)                                  -- marker M_a goes (one UI)
  if Image._ui_changed then Image._ui_changed("enter") end
  local f1 = Image._acks_info and Image._acks_info() or {}
  push(pf, 2)
  local f2 = Image._acks_info and Image._acks_info() or {}
  chk("I24f a UI attaching when no other UI is left owes nothing: the next marker waits for that UI alone",
    f1.carry == 0 and f2.mark == 1, ("owed on %s, marker due %s"):format(tostring(f1.carry), tostring(f2.mark)))
  answer_mark()
  -- the UI that attaches is subtracted only when it is a terminal UI: a GUI
  -- attaching leaves the terminal UI where it was, and it still owes the
  -- marker on its way (UIEnter names the channel)
  Image.clear_for_cell("spec_i24f")
  tty_ui = true; install(); ui_changed(); reset()
  local pg = hand_gif("spec_i24g", F)
  ui_changed(); reset()
  push(pg, 1)                                  -- marker M_a goes (one terminal UI)
  tty_ui = "tty+gui"; install()
  if Image._ui_changed then Image._ui_changed("enter", 7) end   -- the GUI, channel 7
  local g1 = Image._acks_info and Image._acks_info() or {}
  push(pg, 2)
  local g2 = Image._acks_info and Image._acks_info() or {}
  answer_mark()                                -- M_a's late answer
  local g_mid = frames_out()
  answer_mark()                                -- the terminal UI's answer to M_b
  local g_end = frames_out()
  chk("I24g a GUI attaching while a marker is on its way: the terminal UI still owes the old answer, and no frame goes before the next marker's last answer",
    g1.carry == 1 and g2.mark == 2 and g_mid == 0 and g_end == 1,
    ("owed on after the reset %s, marker due %s, frames after the old marker's answer %d, after the last %d"):format(
      tostring(g1.carry), tostring(g2.mark), g_mid, g_end))
  Image.clear_for_cell("spec_i24g")
  tty_ui = "two"; install(); ui_changed(); reset()
  local ph2 = hand_gif("spec_i24h", F)
  ui_changed(); reset()
  push(ph2, 1)                                 -- marker due from two terminal UIs
  if Image._ui_changed then Image._ui_changed("enter", 2) end   -- one of them (channel 2) is the new one
  local h1 = Image._acks_info and Image._acks_info() or {}
  chk("I24h a terminal UI attaching (its channel named) takes itself off what is owed: one UI stays",
    h1.carry == 1, ("owed on %s"):format(tostring(h1.carry)))
  answer_mark(); answer_mark()
  -- UIEnter names the channel in v:event; with none passed that is the one used
  Image.clear_for_cell("spec_i24h")
  tty_ui = true; install(); ui_changed(); reset()
  local pi = hand_gif("spec_i24i", F)
  ui_changed(); reset()
  push(pi, 1)                                  -- marker M_a goes (one terminal UI)
  tty_ui = "tty+gui"; install()
  local real_v = vim.v
  vim.v = setmetatable({ event = { chan = 7 } }, { __index = real_v })
  if Image._ui_changed then Image._ui_changed("enter") end
  vim.v = real_v
  local i1 = Image._acks_info and Image._acks_info() or {}
  chk("I24i the channel UIEnter names (v:event.chan) is the one taken for the attaching UI when the caller names none",
    i1.carry == 1, ("owed on %s"):format(tostring(i1.carry)))
  answer_mark()
  -- with no UI left to answer, and across a suspend, nothing is owed on
  Image.clear_for_cell("spec_i24h")
  tty_ui = true; install(); ui_changed(); reset()
  local p3 = hand_gif("spec_i24c", F)
  ui_changed(); reset()
  push(p3, 1)
  tty_ui = false; install()
  if Image._ui_changed then Image._ui_changed("leave") end
  local n1 = Image._acks_info and Image._acks_info() or {}
  tty_ui = true; install()
  if Image._ui_changed then Image._ui_changed("enter") end
  local n2 = Image._acks_info and Image._acks_info() or {}
  push(p3, 2)
  local n3 = Image._acks_info and Image._acks_info() or {}
  chk("I24c with no UI left a marker's answer is not waited for; after a leave and an attach the next marker is one UI's",
    n1.carry == 0 and n2.carry == 0 and n3.mark == 1, ("owed after the leave %s, after the attach %s, marker due %s"):format(
      tostring(n1.carry), tostring(n2.carry), tostring(n3.mark)))
  answer_mark()
  ui_changed(); reset()
  push(p3, 1)
  if Image._ui_changed then Image._ui_changed("suspend") end
  local s1 = Image._acks_info and Image._acks_info() or {}
  chk("I24d across a suspend nothing is owed on: what is in flight goes to the shell", s1.carry == 0, tostring(s1.carry))
  Image.clear_for_cell("spec_i24c")
  Image._frame_window = 64 * 1024
  auto_mark = true
  ui_changed()
end
do
  -- A late answer to XTVERSION (markers were off) during the drain before a
  -- quit: no marker can go then, so the status answers keep paying the
  -- requests and the drain ends when they have come
  local F = {}
  for i = 1, 3 do F[i] = vim.base64.encode(png(40, 30, 430 + i)) end
  tty_ui = true; ui_send_api = true; install(); ui_changed(); reset()
  Image._remote_mode = true
  auto_mark = false
  Image._mark_seen, Image._mark_off = false, true
  Image._ack_timeout_ms = 2000
  local p = hand_gif("spec_i25", F)
  ui_changed(); reset()
  push(p, 1); answer()                        -- markers off: a frame goes, and the terminal answers its request
  push(p, 2)                                   -- the next one is in flight
  vim.defer_fn(function()
    answer_mark()                              -- the late XTVERSION answer, in the drain
    vim.defer_fn(function() answer(); answer() end, 50)  -- then the status answers (the frame's, the drain's own)
  end, 150)
  local t = vim.uv.now()
  fire("VimLeavePre")
  local wl = vim.uv.now() - t
  Image._leaving = false
  local k = Image._acks_info and Image._acks_info() or {}
  chk("I25 a late XTVERSION answer during the quit drain does not hold it up: the status answers that follow end it",
    wl >= 150 and wl < 1200 and k.n == 0, ("waited %d ms, in flight after %s"):format(wl, tostring(k.n)))
  Image.clear_for_cell("spec_i25")
  Image._ack_timeout_ms = 3000
  Image._mark_seen, Image._mark_off = true, false
  auto_mark = true
  ui_changed()
end

-- ── J. a gif back in view sends the frame its clock is at, at once ───────
do
  -- the view changed: WinScrolled for the image module's autocmds only (the
  -- tree before this feature has no such group)
  local function scrolled() pcall(vim.api.nvim_exec_autocmds, "WinScrolled", { group = "jupynvim_image_ui" }) end
  local F = {}
  for i = 1, 4 do F[i] = vim.base64.encode(png(40, 30, 30 + i)) end
  Image._frame_window = 64 * 1024
  Image.ensure_transmitted("spec_j", F[1], function() end, { renderer = "placeholder" })
  local pj = Image._placements.spec_j
  local vis = false
  pcall(Image.set_visible_probe, "spec_j", function() return vis end)
  if pj then pj.frames, pj.delays = F, { 1000, 1000, 1000, 1000 } end
  local s0 = Image._frames_skipped or 0
  reset()
  Image.resume_animations()
  vim.wait(1600, function() return (Image._frames_skipped or 0) > s0 end, 5)  -- its first tick, off screen
  local t0 = vim.uv.now()
  vis = true
  scrolled()
  vim.wait(400, function() return frames_out() > 0 end, 2)
  chk("J1 a slow gif scrolled back into view sends its current frame right away, not at its next tick",
    pj and frames_out() == 1 and payload(first_tx()) == F[pj.frame_idx] and vim.uv.now() - t0 < 600,
    ("frames %d after %d ms"):format(frames_out(), vim.uv.now() - t0))
  -- scrolled again with its current frame already sent: nothing to catch up
  reset()
  scrolled()
  vim.wait(200)
  chk("J1b a gif in view whose current frame went out sends nothing on the next view change",
    pj and not pj.stale and frames_out() == 0, ("frames %d"):format(frames_out()))
  -- and like any frame it waits while the terminal is behind
  Image._frame_window = 1
  vis = false
  s0 = Image._frames_skipped or 0
  vim.wait(1600, function() return (Image._frames_skipped or 0) > s0 end, 5)
  vis = true
  reset()
  local h0 = Image._frames_held or 0
  scrolled()
  vim.wait(100)
  local behind = frames_out()
  answer()
  scrolled()
  vim.wait(300, function() return frames_out() > 0 end, 2)
  chk("J2 with the terminal behind it waits, and goes once the terminal answered",
    behind == 0 and (Image._frames_held or 0) > h0 and frames_out() == 1,
    ("behind %d, held %d, after the answer %d"):format(behind, (Image._frames_held or 0) - h0, frames_out()))
  -- a window showing the notebook again (BufWinEnter) and a tab page entered
  -- (TabEnter) change the view too
  Image._frame_window = 64 * 1024
  for n, ev in ipairs({ "BufWinEnter", "TabEnter" }) do
    vis = false
    s0 = Image._frames_skipped or 0
    vim.wait(1600, function() return (Image._frames_skipped or 0) > s0 end, 5)
    vis = true
    reset()
    local te = vim.uv.now()
    pcall(vim.api.nvim_exec_autocmds, ev, { group = "jupynvim_image_ui" })
    vim.wait(400, function() return frames_out() > 0 end, 2)
    chk(("J%d after %s a slow gif back in view sends its current frame right away"):format(n + 2, ev),
      pj and frames_out() == 1 and payload(first_tx()) == F[pj.frame_idx] and vim.uv.now() - te < 600,
      ("frames %d after %d ms"):format(frames_out(), vim.uv.now() - te))
  end
  Image.clear_for_cell("spec_j")
end

-- ── K. a gif's clock is the loop's time ───────────────────────────────────
-- A gif shows the frame its own clock is at, counted from when it started on
-- the time the timers use: a tick that runs late, a tick that never ran
-- (34 s out of view) or one that was skipped changes nothing about which
-- frame is shown or when the next one comes. (The old clock counted ticks,
-- each re-armed from when it ran, so it fell behind.)
do
  local function rep(n, v) local t = {} for i = 1, n do t[i] = v end return t end
  local function names(n) local t = {} for i = 1, n do t[i] = "f" .. i end return t end
  local cf = Image._clock_frame
  local function frame_at(p, now)
    if not cf then return nil, nil end
    local ok, k, w = pcall(cf, p, now)
    if ok then return k, w end
    return nil, nil
  end

  -- K1: the frame at a time, and the ms to the next one
  local cases = {
    { "16 x 80 ms", { frames = names(16), delays = rep(16, 80), t0 = 0 }, {
      { 0, 1, 80 }, { 79, 1, 1 }, { 80, 2, 80 }, { 1279, 16, 1 }, { 1280, 1, 80 }, { 34000, 10, 80 }, { -5, 16, 5 } } },
    { "16 x 80 ms from t0 1000", { frames = names(16), delays = rep(16, 80), t0 = 1000 }, { { 1720, 10, 80 } } },
    { "delays 100, 20, 500", { frames = names(3), delays = { 100, 20, 500 }, t0 = 0 }, {
      { 0, 1, 100 }, { 119, 2, 1 }, { 120, 3, 500 }, { 619, 3, 1 }, { 620, 1, 100 }, { 745, 3, 495 } } },
    { "delays 0, 80 (a missing or zero delay counts 100 ms)", { frames = names(2), delays = { 0, 80 }, t0 = 0 }, {
      { 150, 2, 30 } } },
  }
  local bad, total = {}, 0
  for _, c in ipairs(cases) do
    for _, x in ipairs(c[3]) do
      total = total + 1
      local k, w = frame_at(c[2], x[1])
      if k ~= x[2] or w ~= x[3] then
        bad[#bad + 1] = ("%s at %d: (%s, %s) want (%d, %d)"):format(c[1], x[1], tostring(k), tostring(w), x[2], x[3])
      end
    end
  end
  -- a replaced delays table counts at once
  local pr = { frames = names(16), delays = rep(16, 80), t0 = 0 }
  local k0, w0 = frame_at(pr, 1279)
  pr.delays = rep(16, 100)
  local k1, w1 = frame_at(pr, 1279)
  total = total + 2
  if k0 ~= 16 or w0 ~= 1 then bad[#bad + 1] = ("80 ms at 1279: (%s, %s) want (16, 1)"):format(tostring(k0), tostring(w0)) end
  if k1 ~= 13 or w1 ~= 21 then
    bad[#bad + 1] = ("delays replaced by 100 ms at 1279: (%s, %s) want (13, 21)"):format(tostring(k1), tostring(w1))
  end
  chk("K1 Image._clock_frame gives the frame shown at a time (from the sum of the delays, repeating, from p.t0) and the ms until the next one",
    cf ~= nil and #bad == 0, cf == nil and "no Image._clock_frame" or ("%d of %d differ: %s"):format(#bad, total, table.concat(bad, "; ")))

  -- K1b: a call costs microseconds, so a tick can ask every time
  local big = { frames = names(300), delays = rep(300, 30), t0 = 0 }
  local best, why = math.huge, ""
  if cf then
    best, why = jit_timed(function()
      local b = math.huge
      for _ = 1, 3 do
        local t0 = vim.uv.hrtime()
        for i = 1, 10000 do cf(big, i * 37 + (i % 7)) end
        b = math.min(b, (vim.uv.hrtime() - t0) / 1e6)
      end
      return b
    end)
  end
  chk(("K1b a call for a gif of 300 frames takes under 50 us (10,000 calls, best of 3, under 500 ms: %.1f ms%s)"):format(best, why),
    cf ~= nil and best < 500, cf == nil and "no Image._clock_frame" or nil)

  -- K2: off screen for 34 s on a fake clock (Neovim 0.11, as section C:
  -- frames go to the stderr channel at once, unpaced)
  tty_ui = true; ui_send_api = false; install(); ui_changed()
  local fake = 0
  local saved_now = Image._now_ms
  Image._now_ms = function() return fake end
  local F2 = {}
  for i = 1, 16 do F2[i] = vim.base64.encode(png(40, 30, 60 + i)) end
  Image.ensure_transmitted("spec_k2", F2[1], function() end, { renderer = "placeholder" })
  local pk2 = Image._placements.spec_k2
  local vis2 = false
  pcall(Image.set_visible_probe, "spec_k2", function() return vis2 end)
  if pk2 then pk2.frames, pk2.delays = F2, rep(16, 80) end
  local s0 = Image._frames_skipped or 0
  reset()
  Image.resume_animations()
  fake = 34000
  vim.wait(300, function() return (Image._frames_skipped or 0) > s0 end, 5)
  local skipped_ok = (Image._frames_skipped or 0) > s0
  local while_off = #chan_out + #ui_out
  vis2 = true
  reset()
  catch_up()
  local sent2, got2 = {}, 0
  for _, s in ipairs(chan_out) do if is_tx(s) then sent2[#sent2 + 1] = payload(s) end end
  for i = 1, 16 do if F2[i] == sent2[1] then got2 = i end end
  chk("K2 a gif that was off screen for 34 s (a fake clock) sends the frame its clock is at when it is back in view: frame 10 of 16 at 80 ms",
    pk2 ~= nil and skipped_ok and while_off == 0 and #sent2 == 1 and got2 == 10,
    ("tick seen %s, writes while off screen %d, frames sent %d, frame %d, frame_idx %s"):format(
      tostring(skipped_ok), while_off, #sent2, got2, tostring(pk2 and pk2.frame_idx)))
  Image.clear_for_cell("spec_k2")
  Image._now_ms = saved_now
  reset()

  -- K3, K4: on the real clock, through a stall of the loop. K3: a gif out of
  -- view keeps the clock's frame (within one frame of it). K4: a gif in view
  -- is sent each frame soon after the frame starts, whatever came before.
  local real_send = vim.api.nvim_chan_send
  local sends = {}
  vim.api.nvim_chan_send = function(ch, s)
    if ch == vim.v.stderr and is_tx(s) then sends[#sends + 1] = { vim.uv.now(), payload(s) } end
    return real_send(ch, s)
  end
  local F3, F4, idx4 = {}, {}, {}
  for i = 1, 16 do
    F3[i] = vim.base64.encode(png(40, 30, 80 + i))
    F4[i] = vim.base64.encode(png(40, 30, 100 + i))
    idx4[F4[i]] = i
  end
  Image.ensure_transmitted("spec_k3", F3[1], function() end, { renderer = "placeholder" })
  Image.ensure_transmitted("spec_k4", F4[1], function() end, { renderer = "placeholder" })
  local pk3, pk4 = Image._placements.spec_k3, Image._placements.spec_k4
  pcall(Image.set_visible_probe, "spec_k3", function() return false end)
  pcall(Image.set_visible_probe, "spec_k4", function() return true end)
  if pk3 then pk3.frames, pk3.delays = F3, rep(16, 80) end
  if pk4 then pk4.frames, pk4.delays = F4, rep(16, 80) end
  reset()
  sends = {}
  local T0 = vim.uv.now()
  Image.resume_animations()
  vim.wait(400)
  -- the loop stalls for more than three frames (a busy editor, a machine
  -- briefly asleep), ending halfway through a frame on the gifs' clock: a
  -- clock that counts ticks stays those frames behind from then on, and a
  -- tick re-armed for a full delay from when it ran stays half a frame late
  -- (and later with every tick); the loop's clock is back on the frame
  -- starts after the first tick. 2 s after the stall give 25 frames.
  local stall_to
  do
    vim.uv.update_time()
    stall_to = T0 + math.ceil((vim.uv.now() + 260 - T0) / 80) * 80 + 40
    repeat vim.uv.update_time() until vim.uv.now() >= stall_to
  end
  vim.wait(2000)
  local cl3
  if cf and pk3 and pk3.t0 then
    local ok, k = pcall(cf, pk3, Image._now_ms())
    cl3 = ok and k or nil
  end
  local d3 = (cl3 and pk3) and math.abs(pk3.frame_idx - cl3) or nil
  if d3 then d3 = math.min(d3, 16 - d3) end
  chk("K3 a gif off screen on the real clock, through a stall of the loop, shows the clock's frame, within one frame",
    d3 ~= nil and d3 <= 1,
    (cf == nil and "no Image._clock_frame") or (not (pk3 and pk3.t0) and "no p.t0")
      or ("frame_idx %s, clock %s"):format(tostring(pk3 and pk3.frame_idx), tostring(cl3)))
  -- lateness of each send after the stall: its time minus the start of the
  -- frame it carries on the clock (modulo the cycle, early counted negative)
  local late, before = {}, 0
  for _, s in ipairs(sends) do
    local k = idx4[s[2]]
    if k and s[1] < stall_to then before = before + 1
    elseif k then late[#late + 1] = ((s[1] - T0 - (k - 1) * 80 + 640) % 1280) - 640 end
  end
  local lastn = {}
  for i = math.max(1, #late - 19), #late do lastn[#lastn + 1] = late[i] end
  table.sort(lastn)
  local med = lastn[math.ceil(#lastn / 2)]
  chk("K4 a gif in view is sent each frame within 25 ms of the frame's start on its clock (median of the 20 last sends, all after a stall of the loop)",
    before >= 2 and #late >= 20 and med ~= nil and med <= 25,
    ("%d sends before the stall, %d after; median lateness of the last %d: %s ms (%s)"):format(before, #late,
      #lastn, tostring(med), table.concat(lastn, " ")))
  Image.clear_for_cell("spec_k3")
  Image.clear_for_cell("spec_k4")
  vim.api.nvim_chan_send = real_send
  reset()
  tty_ui = true; ui_send_api = true; install(); ui_changed()
end

-- ── Q. Neovim 0.11: frames and heals wait for a quiet screen ───────────────
-- Without nvim_ui_send the editor writes beside the UI, and the UI writes
-- after each redraw, so a write that comes while the screen redraws can land
-- inside one of its escape sequences. The module notes each redraw
-- (Image._note_redraw) and sends gif frames, catch-ups and heals only after
-- M._quiet_ms without one, a frame after M._quiet_max_ms at the latest. The
-- clock is a fake one, so a section stays short.
do
  local function rep(n, v) local t = {} for i = 1, n do t[i] = v end return t end
  local function frames_of(n, seed)
    local t = {}
    for i = 1, n do t[i] = vim.base64.encode(png(40, 30, seed + i)) end
    return t
  end
  local have = REAL_NOTE_REDRAW ~= nil
  local missing = "no Image._note_redraw"
  local function nr() if REAL_NOTE_REDRAW then REAL_NOTE_REDRAW() end end
  local function sent_frames()
    local t = {}
    for _, s in ipairs(chan_out) do if is_tx(s) then t[#t + 1] = payload(s) end end
    return t
  end
  local function number_of(F, got)
    for i = 1, #F do if F[i] == got then return i end end
    return 0
  end
  local function count_of_any(F)
    local n = 0
    for _, f in ipairs(sent_frames()) do if number_of(F, f) > 0 then n = n + 1 end end
    return n
  end

  tty_ui = true; ui_send_api = false; install(); ui_changed()
  local fake = 0
  local function setfake(v) fake = v end
  local saved_now, saved_note = Image._now_ms, Image._note_redraw
  Image._now_ms = function() return fake end
  Image._note_redraw = REAL_NOTE_REDRAW
  local keys = {}
  local function mkgif(key, F, delay)
    keys[#keys + 1] = key
    Image.ensure_transmitted(key, F[1], function() end, { renderer = "placeholder" })
    local p = Image._placements[key]
    pcall(Image.set_visible_probe, key, function() return true end)
    if p then p.frames, p.delays = F, rep(#F, delay) end
    return p
  end

  -- Q1, Q2: a redraw just now holds the frames; 151 ms on, the clock's frame goes
  local F1 = frames_of(16, 200)
  local p1 = mkgif("spec_q1", F1, 80)
  setfake(0)
  reset()
  local q0 = Image._frames_quiet or 0
  Image.resume_animations()
  nr()
  vim.wait(300)
  local held = #chan_out
  local counted = (Image._frames_quiet or 0) - q0
  chk("Q1 with a redraw just now a gif in view sends nothing and the frames held are counted",
    have and p1 ~= nil and held == 0 and counted >= 2, have and ("%d writes, %d held"):format(held, counted) or missing)
  reset()
  setfake(149)
  vim.wait(250)
  local held149 = #sent_frames()
  chk("Q1b 149 ms after the redraw the frame is still held (the quiet window is 150 ms)",
    have and p1 ~= nil and held149 == 0, have and ("%d frames sent at 149 ms"):format(held149) or missing)
  reset()
  setfake(151)
  vim.wait(200, function() return #sent_frames() > 0 end, 2)
  local s2 = sent_frames()
  local all2 = #s2 > 0
  for _, f in ipairs(s2) do if f ~= F1[2] then all2 = false end end
  chk("Q2 150 ms after the redraw a frame goes: the clock's frame at that time (frame 2 at 151 ms)",
    have and all2, have and ("%d frames, first is frame %d"):format(#s2, number_of(F1, s2[1])) or missing)
  Image.clear_for_cell("spec_q1")

  -- Q3: a redraw every 50 ms keeps the screen busy, and a frame still goes
  -- once the first held tick is 1000 ms behind; the frame after it waits
  -- 1000 ms again. The fake clock stands still between the steps, so each
  -- frame is dated exactly with the step it went in.
  local F3 = frames_of(16, 240)
  mkgif("spec_q3", F3, 80)
  setfake(2000)
  reset()
  q0 = Image._frames_quiet or 0
  Image.resume_animations()
  local held_at
  local sent3 = {}
  for step = 1, 70 do
    setfake(2000 + step * 50)
    nr()
    vim.wait(30)
    if not held_at and (Image._frames_quiet or 0) > q0 then held_at = fake end
    for _ = #sent3 + 1, #sent_frames() do sent3[#sent3 + 1] = fake end
    if #sent3 >= 2 then break end
  end
  local sent_at, sent2_at = sent3[1], sent3[2]
  chk("Q3 under nonstop redraws no frame goes for 1000 ms from the first one held, then one does (by 1300 ms), and the next one waits 1000 ms again (and goes by 1300 ms)",
    have and held_at ~= nil and sent_at ~= nil and sent_at - held_at >= 1000 and sent_at - held_at <= 1300
      and sent2_at ~= nil and sent2_at - sent_at >= 1000 and sent2_at - sent_at <= 1300,
    have and ("first held at fake %s, frames sent at %s"):format(tostring(held_at), table.concat(sent3, ", ")) or missing)
  Image.clear_for_cell("spec_q3")

  -- Q4: a stale gif in view at a catch-up while the screen redraws waits for
  -- one timer, which sends its current frame at the quiet end
  local F4 = frames_of(4, 280)
  local p4 = mkgif("spec_q4", F4, 60000)
  setfake(10000)
  Image.resume_animations()
  reset()
  nr()
  if p4 then p4.frame_idx, p4.stale = 2, true end
  catch_up()
  vim.wait(60)
  local early4 = #sent_frames()
  setfake(10000 + 151)
  vim.wait(300, function() return #sent_frames() > 0 end, 2)
  local s4 = sent_frames()
  chk("Q4 a catch-up while the screen redraws writes nothing; a timer sends the stale gif's frame when the screen is quiet",
    have and p4 ~= nil and early4 == 0 and #s4 == 1 and s4[1] == F4[2],
    have and ("%d frames at once, %d later, frame %d"):format(early4, #s4, number_of(F4, s4[1])) or missing)
  Image.clear_for_cell("spec_q4")

  do
    -- Q10: a gif that waited for a quiet screen and then went out of view
    -- waits again from the start when it is back in view while the screen
    -- redraws: the second it may wait counts from when it is back, not from
    -- its first wait
    local F10 = frames_of(16, 300)
    local p10 = mkgif("spec_q10", F10, 80)
    local vis10 = true
    pcall(Image.set_visible_probe, "spec_q10", function() return vis10 end)
    setfake(50000)
    reset()
    q0 = Image._frames_quiet or 0
    Image.resume_animations()
    nr()
    vim.wait(250)
    local held10 = (Image._frames_quiet or 0) > q0 and #sent_frames() == 0
    vis10 = false
    setfake(50100)
    local k0 = Image._frames_skipped or 0
    vim.wait(250, function() return (Image._frames_skipped or 0) > k0 end, 2)
    local off10 = (Image._frames_skipped or 0) > k0
    vis10 = true
    setfake(51500)
    nr()
    reset()
    catch_up()
    vim.wait(250)
    local back10 = #sent_frames()
    chk("Q10 a gif that waited for a quiet screen, went out of view and is back while the screen redraws waits again (its wait counts from when it is back)",
      have and p10 ~= nil and held10 and off10 and back10 == 0,
      have and ("held first %s, ticked out of view %s, frames sent at once when back %d"):format(
        tostring(held10), tostring(off10), back10) or missing)
    Image.clear_for_cell("spec_q10")
  end

  do
    -- Q11: a catch-up while the screen never goes quiet (a cell streaming
    -- output, a redraw every 50 ms) sends the stale gif's frame once it has
    -- waited 1000 ms, though the gif's next tick is a minute away
    local F11 = frames_of(4, 380)
    local p11 = mkgif("spec_q11", F11, 60000)
    setfake(70000)
    Image.resume_animations()
    reset()
    nr()
    if p11 then p11.frame_idx, p11.stale = 2, true end
    catch_up()
    local sent11
    for step = 1, 60 do
      setfake(70000 + step * 50)
      nr()
      vim.wait(30)
      if not sent11 and count_of_any(F11) > 0 then sent11 = fake end
      if sent11 then break end
    end
    vim.wait(100)
    local s11 = {}
    for _, f in ipairs(sent_frames()) do
      local k = number_of(F11, f)
      if k > 0 then s11[#s11 + 1] = k end
    end
    chk("Q11 a catch-up under nonstop redraws sends a slow gif's frame once it has waited 1000 ms for a quiet screen (by 1300 ms), not at its next tick",
      have and p11 ~= nil and sent11 ~= nil and sent11 - 70000 >= 1000 and sent11 - 70000 <= 1300
        and #s11 == 1 and s11[1] == 2,
      have and ("sent at fake +%s, frames %s"):format(sent11 and tostring(sent11 - 70000) or "never",
        table.concat(s11, " ")) or missing)
    Image.clear_for_cell("spec_q11")
  end

  do
    -- Q11b, Q12: the timer of a catch-up and of a held tick is armed for the
    -- end of the second a frame may wait when that comes before the quiet
    -- window's end, so the frame goes when its second is up, not up to 150 ms
    -- later. The fake clock stands still, so what is read is what was armed.
    local F11b = frames_of(4, 440)
    local p11b = mkgif("spec_q11b", F11b, 60000)
    setfake(80000)
    Image.resume_animations()
    reset()
    nr()
    if p11b then p11b.frame_idx, p11b.stale = 2, true end
    catch_up()
    local due_quiet = Image._catch_up_due and Image._catch_up_due()
    setfake(80990)
    nr()          -- the quiet window ends 150 ms on, the second 10 ms on
    catch_up()
    local due_cap = Image._catch_up_due and Image._catch_up_due()
    setfake(81000)
    vim.wait(300, function() return count_of_any(F11b) > 0 end, 1)
    local s11b = {}
    for _, f in ipairs(sent_frames()) do
      local k = number_of(F11b, f)
      if k > 0 then s11b[#s11b + 1] = k end
    end
    chk("Q11b a catch-up waiting for a quiet screen looks again when the frame's second is up (10 ms on), not at the quiet window's end (150 ms on), and then sends it",
      have and p11b ~= nil and due_quiet ~= nil and due_quiet > 100 and due_cap ~= nil and due_cap <= 50
        and #s11b == 1 and s11b[1] == 2,
      have and ("due in %s ms with the second far off, %s ms with 10 ms of it left; frames %s"):format(
        tostring(due_quiet), tostring(due_cap), table.concat(s11b, " ")) or missing)
    Image.clear_for_cell("spec_q11b")
  end

  do
    local F12 = frames_of(3, 460)
    local p12 = mkgif("spec_q12", F12, 2000)
    if p12 then p12.delays = { 100, 2000, 2000 } end  -- the first tick comes soon
    setfake(90000)
    reset()
    q0 = Image._frames_quiet or 0
    Image.resume_animations()
    setfake(90050)
    nr()
    setfake(90100)  -- frame 2 starts; its tick holds it (quiet again at 90200)
    vim.wait(1500, function() return (Image._frames_quiet or 0) > q0 end, 1)
    local held12 = (Image._frames_quiet or 0) > q0
    local since12 = p12 and p12.quiet_since
    -- 990 ms into its wait, with a redraw just now: the next held tick arms
    -- its timer for the 10 ms left of the second
    local q1 = Image._frames_quiet or 0
    setfake((since12 or 90100) + 990)
    nr()
    vim.wait(500, function() return (Image._frames_quiet or 0) > q1 end, 1)
    local ok_due, due12 = false, nil
    if p12 and p12.timer then ok_due, due12 = pcall(p12.timer.get_due_in, p12.timer) end
    setfake((since12 or 90100) + 1000)
    vim.wait(300, function() return count_of_any(F12) > 0 end, 1)
    local s12 = {}
    for _, f in ipairs(sent_frames()) do
      local k = number_of(F12, f)
      if k > 0 then s12[#s12 + 1] = k end
    end
    chk("Q12 a tick that holds a frame for a quiet screen 990 ms into its wait arms its timer for the 10 ms left of the second, not for the quiet window's end, and the frame then goes",
      have and p12 ~= nil and held12 and since12 ~= nil and ok_due and due12 ~= nil and due12 <= 50
        and #s12 == 1 and s12[1] == 2,
      have and ("held %s since %s, timer due in %s ms; frames %s"):format(tostring(held12), tostring(since12),
        tostring(due12), table.concat(s12, " ")) or missing)
    Image.clear_for_cell("spec_q12")
  end

  -- Q5: the heal of an image on screen waits too; one heal when it is quiet
  local PQ5 = vim.base64.encode(png(40, 30, 320))
  keys[#keys + 1] = "spec_q5"
  Image.ensure_transmitted("spec_q5", PQ5, function() end, { renderer = "placeholder" })
  local p5 = Image._placements.spec_q5
  pcall(Image.set_visible_probe, "spec_q5", function() return true end)
  local place5 = p5 and ("\27_Ga=p,U=1,i=%d,p=1,c=%d,r=%d,q=2\27\\"):format(p5.image_id, p5.cols, p5.rows) or "?"
  local function heals5() return count(chan_out, function(s) return s:find(place5, 1, true) ~= nil end) end
  Image._heal_ms = 1000
  local f5 = vim.uv.now() + 2000
  local heal_fake = f5 + 151  -- the heal below is dated with it
  setfake(f5)
  reset()
  nr()
  Image.reassert_virtual_placements()
  vim.wait(60)
  local early5 = heals5()
  setfake(f5 + 151)
  vim.wait(300, function() return heals5() > 0 end, 2)
  vim.wait(60)
  local late5 = heals5()
  chk("Q5 the heal of an image on screen waits while the screen redraws, then writes it once",
    have and p5 ~= nil and early5 == 0 and late5 == 1,
    have and ("%d heals at once, %d later"):format(early5, late5) or missing)
  Image.clear_for_cell("spec_q5")

  -- Q6: with nvim_ui_send nothing waits, whatever redraws
  tty_ui = true; ui_send_api = true; install(); ui_changed()
  Image._frame_window = 64 * 1024
  local F6 = frames_of(4, 340)
  local p6 = hand_gif("spec_q6", F6)
  keys[#keys + 1] = "spec_q6"
  local PQ6 = vim.base64.encode(png(40, 30, 360))
  keys[#keys + 1] = "spec_q6b"
  Image.ensure_transmitted("spec_q6b", PQ6, function() end, { renderer = "placeholder" })
  local p6b = Image._placements.spec_q6b
  local place6 = p6b and ("\27_Ga=p,U=1,i=%d,p=1,c=%d,r=%d,q=2\27\\"):format(p6b.image_id, p6b.cols, p6b.rows) or "?"
  reset()
  nr()
  local went6 = push(p6, 2)
  local frame6 = frames_out() == 1 and payload(first_tx()) == F6[2]
  reset()
  pcall(Image.invalidate_placements)
  nr()
  Image.reassert_virtual_placements()
  local placed6 = count(ui_out, function(s) return s:find(place6, 1, true) ~= nil end)
  chk("Q6 with nvim_ui_send a redraw holds nothing: a stale gif goes at the catch-up and a changed placement is written at once",
    p6 ~= nil and p6b ~= nil and went6 and frame6 and placed6 == 1,
    ("catch-up sent %s (frame ok %s), placements written %d"):format(tostring(went6), tostring(frame6), placed6))
  Image.clear_for_cell("spec_q6")
  Image.clear_for_cell("spec_q6b")

  -- Q7: whether the module watches redraws is decided when it loads: without
  -- nvim_ui_send it registers a decoration provider that notes each redraw.
  -- Child editors, since this process loaded the module with a stand-in.
  local tree = vim.fn.getcwd()
  local script = tmp .. "/q7.lua"
  local function child(drop_api)
    local f = io.open(script, "w")
    f:write(("local tree = %q\n"):format(tree))
    f:write([[
vim.opt.runtimepath:prepend(tree)
package.path = tree .. "/lua/?.lua;" .. tree .. "/lua/?/init.lua;" .. package.path
]])
    if drop_api then f:write("vim.api.nvim_ui_send = nil\n") end
    f:write([[
local Image = require("jupynvim.notebook.image")
local n = 0
Image._note_redraw = function() n = n + 1 end
vim.cmd("redraw")
io.stdout:write(("watch=%s redraws=%d\n"):format(tostring(Image._redraw_watch), n))
]])
    f:close()
    local res = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-l", script }, { text = true, timeout = 30000 }):wait()
    local out = (res.stdout or "") .. (res.stderr or "")
    local w, n = out:match("watch=(%a+) redraws=(%d+)")
    return w, tonumber(n), out
  end
  local w1, n1, out1 = child(false)
  local w2, n2, out2 = child(true)
  local want1 = tostring(REAL_UI_SEND == nil)
  chk("Q7 the redraw watch is registered when nvim_ui_send is missing at load (this Neovim and with the API removed), and not otherwise",
    w1 == want1 and (w1 ~= "true" or (n1 or 0) >= 1) and (w1 ~= "false" or n1 == 0)
      and w2 == "true" and (n2 or 0) >= 1,
    ("real API (want watch %s): %s; API removed: %s"):format(want1, vim.trim(out1):sub(1, 200), vim.trim(out2):sub(1, 200)))
  os.remove(script)

  -- Q8, Q9 on Neovim 0.11's path again
  tty_ui = true; ui_send_api = false; install(); ui_changed()
  local function count_of(f) return count(chan_out, function(s) return is_tx(s) and payload(s) == f end) end

  -- Q8: a frame held for a quiet screen goes once. A view change while the
  -- screen redraws (a catch-up) waits for the quiet end too, so at the quiet
  -- end the catch-up and the held tick both come: whichever sends the frame
  -- first, the other finds it on the terminal. The catch-up is called right
  -- at the quiet end, so it comes first, then the held tick (at most 140 ms
  -- later); after that the next frame goes once at its start.
  local F8 = frames_of(4, 400)
  local p8 = mkgif("spec_q8", F8, 400)
  setfake(30000)
  reset()
  q0 = Image._frames_quiet or 0
  Image.resume_animations()
  setfake(30390)
  nr()          -- a redraw 10 ms before frame 2 starts: quiet again at 30540
  catch_up()
  setfake(30400)
  vim.wait(1500, function() return (Image._frames_quiet or 0) > q0 end, 1)
  local held8 = (Image._frames_quiet or 0) > q0
  local early8 = #sent_frames()
  catch_up()
  setfake(30540)
  catch_up()
  vim.wait(400)
  local f2_8 = count_of(F8[2])
  setfake(30800)  -- frame 3 starts
  vim.wait(800, function() return count_of(F8[3]) > 0 end, 2)
  vim.wait(100)
  local f3_8, all8 = count_of(F8[3]), #sent_frames()
  chk("Q8 a frame held for a quiet screen is written once at the quiet end, though a catch-up and the held tick both come then; the next frame goes once",
    have and p8 ~= nil and held8 and early8 == 0 and f2_8 == 1 and f3_8 == 1 and all8 == 2,
    have and ("held %s, %d frames before the quiet end, frame 2 written %d time(s), frame 3 %d, frames in all %d"):format(
      tostring(held8), early8, f2_8, f3_8, all8) or missing)
  Image.clear_for_cell("spec_q8")

  -- Q9: a frame held for a quiet screen goes when the screen is quiet, not
  -- at the gif's next frame start, which for a slow gif is seconds away
  local F9 = frames_of(3, 420)
  local p9 = mkgif("spec_q9", F9, 2000)
  if p9 then p9.delays = { 100, 2000, 2000 } end  -- the first tick comes soon
  setfake(40000)
  reset()
  q0 = Image._frames_quiet or 0
  Image.resume_animations()
  setfake(40050)
  nr()          -- quiet again at 40200
  setfake(40100)  -- frame 2 (of 2 s) starts
  vim.wait(1500, function() return (Image._frames_quiet or 0) > q0 end, 1)
  local held9 = (Image._frames_quiet or 0) > q0
  local early9 = #sent_frames()
  setfake(40201)
  local t9 = vim.uv.hrtime()
  vim.wait(1000, function() return #sent_frames() > 0 end, 2)
  local after9 = (vim.uv.hrtime() - t9) / 1e6
  local s9 = sent_frames()
  chk("Q9 a frame held for a quiet screen goes within the quiet window (150 ms; 300 ms allowed) once the screen is quiet, not at the next frame start (frames of 2 s)",
    have and p9 ~= nil and held9 and early9 == 0 and #s9 == 1 and s9[1] == F9[2] and after9 <= 300,
    have and ("held %s, %d frames before the quiet end, %d after it in %.0f ms, frame %d"):format(
      tostring(held9), early9, #s9, after9, number_of(F9, s9[1])) or missing)
  Image.clear_for_cell("spec_q9")
  tty_ui = true; ui_send_api = true; install(); ui_changed()

  -- back to the real clock: no redraw ever noted, the spec's counter again
  for _, k in ipairs(keys) do Image.clear_for_cell(k) end
  Image._now_ms = function() return -1e18 end
  if REAL_NOTE_REDRAW then REAL_NOTE_REDRAW() end
  Image._now_ms, Image._note_redraw = saved_now, saved_note
  -- a heal at the fake times above is dated ahead of the real clock: wait
  -- until the real clock has passed them, so the sections after this one see
  -- the heal gap as the real clock does
  vim.wait(3000, function() return vim.uv.now() > heal_fake end, 20)
  reset()
end

-- ── F. inside tmux ──────────────────────────────────────────────────────
package.loaded["jupynvim.notebook.image"] = nil
vim.env.TMUX = "/x/tmux-1/default,1,0"
local Img2 = require("jupynvim.notebook.image")
vim.env.TMUX = nil
tty_ui = true; install()
if Img2._ui_changed then Img2._ui_changed() end
Img2.attach(fake_client(false), vim.env.JUPYNVIM_TTY)
reset(); Img2.clear_visible_placements()
chk("F1 inside tmux the escape is wrapped for passthrough and sent with nvim_ui_send",
  ui_out[1] == "\27Ptmux;\27\27_Ga=d,d=a,q=2\27\27\\\27\\" and #chan_out == 0)
do
  -- :JupynvimRenderStats counts the bytes written as they go out, wrapped
  -- for tmux: the tty writes and their nvim_ui_send part agree
  local b0, u0 = Img2._tty_bytes or 0, Img2._ui_send_bytes or 0
  reset(); Img2.clear_visible_placements()
  local out = 0
  for _, x in ipairs(ui_out) do out = out + #x end
  local tb, ub = (Img2._tty_bytes or 0) - b0, (Img2._ui_send_bytes or 0) - u0
  chk("F1b inside tmux the bytes counted as written are the wrapped ones, as the nvim_ui_send count has them",
    out > 0 and tb == out and ub == out, ("sent %d bytes, counted as written %d, through nvim_ui_send %d"):format(out, tb, ub))
end
do
  -- tmux answers a status request itself once it has read what came before,
  -- so the request after a frame is sent as it is, not wrapped for the outer
  -- terminal; the marker (XTVERSION) is answered by tmux too, and goes as it
  -- is the same way
  Img2.ensure_transmitted("spec_f", FA, function() end, { renderer = "placeholder" })
  local pf = Img2._placements.spec_f
  pcall(Img2.set_visible_probe, "spec_f", function() return true end)
  if pf then pf.frames, pf.delays = { FA, FB }, { 30, 30 } end
  reset()
  Img2.resume_animations()
  vim.wait(1000, function() return count(ui_out, is_req) > 0 end, 5)
  local wrapped = count(ui_out, function(s) return s:find("\27Ptmux;\27\27_Ga=t,", 1, true) == 1 end)
  local marks, wrapped_mark = 0, false
  for _, x in ipairs(ui_out) do
    if x == MARK then marks = marks + 1 elseif x:find("[>q", 1, true) then wrapped_mark = true end
  end
  chk("F2 inside tmux a gif frame is wrapped and its status request and the marker are not",
    wrapped >= 1 and count(ui_out, is_req) >= 1 and #chan_out == 0 and marks == 1 and not wrapped_mark,
    ("wrapped frames %d, plain requests %d, plain markers %d, a wrapped marker %s"):format(wrapped,
      count(ui_out, is_req), marks, tostring(wrapped_mark)))
  Img2.clear_for_cell("spec_f")
end

-- ── H, continued: the image module loaded after a terminal UI attached ──
-- A plugin loaded lazily (lazy.nvim's VeryLazy, a filetype trigger) loads
-- the image module after the UI's UIEnter, so the module sees no UI event
-- before :detach. On Neovim 0.11 nothing else asks for the UI (there is no
-- nvim_ui_send), and on 0.12 nothing does either when the backend attaches
-- only after :detach (the first notebook opened then), so unless the module
-- notes the terminal UI when it loads, it writes on after :detach, into the
-- terminal the shell has by then.
-- These checks come after F because each loads a fresh module, as F does.
Img2.clear_all()
-- a fresh image module with a terminal UI already attached and no UIEnter
-- seen; Neovim 0.11's API when `v011`; the backend (which has no tty here,
-- so the escapes are encoded in Lua) attached now unless `late`
local function load_after_ui(v011, late)
  package.loaded["jupynvim.notebook.image"] = nil
  tty_ui = true; ui_send_api = not v011; install()
  local L = require("jupynvim.notebook.image")
  if not late then L.attach(fake_client(false), vim.env.JUPYNVIM_TTY) end
  return L
end
-- :detach, then (with `late`) the backend attached, an image and a delete
-- while no terminal shows the editor, then a terminal UI back: what was
-- written meanwhile, what the module knew then, how often the held image
-- went out once the UI was back, and what went out on the other path
local function detach_and_back(L, key, late)
  tty_ui = false; install()
  vim.api.nvim_exec_autocmds("UILeave", {})
  reset()
  if late then L.attach(fake_client(false), vim.env.JUPYNVIM_TTY) end
  L.ensure_transmitted(key, PNG, function() end, { renderer = "placeholder" })
  L.clear_visible_placements()
  local gone = #ui_out + #chan_out
  local had = ("had_ui %s, writes_held %s"):format(tostring(L._had_ui), tostring(L._writes_held and L._writes_held()))
  local pl = L._placements[key]
  tty_ui = true; install()
  reset()
  vim.api.nvim_exec_autocmds("UIEnter", {})
  vim.wait(300, function() return #ui_out + #chan_out > 0 end, 5)
  vim.wait(100)
  local tx = pl and ("\27_Ga=t,f=100,i=%d,"):format(pl.image_id) or "?"
  local path, other = chan_out, ui_out
  if ui_send_api then path, other = ui_out, chan_out end
  return gone, had, count(path, function(s) return s:find(tx, 1, true) == 1 end), #other
end
do
  -- an image written while the terminal UI showed the editor
  local L = load_after_ui(true)
  reset()
  L.ensure_transmitted("spec_l0", PNG, function() end, { renderer = "placeholder" })
  local before = #chan_out
  local gone, had, back, other = detach_and_back(L, "spec_l1")
  chk("H9 on Neovim 0.11 with the image module loaded after the terminal UI attached, nothing is written after :detach and the held image goes out when a terminal UI is back",
    L._remote_mode and before >= 1 and gone == 0 and back == 1 and other == 0,
    ("before %d, while detached %d (%s), held image sent back %d, through nvim_ui_send %d"):format(before, gone, had, back, other))
  L.clear_all()
end
do
  -- nothing written before :detach (the notebook's first plot comes from a
  -- cell still running then)
  local L = load_after_ui(true)
  local gone, had, back, other = detach_and_back(L, "spec_l2")
  chk("H9b the same when nothing was written before :detach",
    gone == 0 and back == 1 and other == 0,
    ("while detached %d (%s), held image sent back %d, through nvim_ui_send %d"):format(gone, had, back, other))
  L.clear_all()
end
do
  -- Neovim 0.12: the backend attaches only after :detach (the first
  -- notebook is opened then), so attach finds no terminal UI either
  local L = load_after_ui(false, true)
  local gone, had, back, other = detach_and_back(L, "spec_l3", true)
  chk("H9c on Neovim 0.12 the same when the backend attached only after :detach, and the held image goes out through nvim_ui_send",
    L._remote_mode and gone == 0 and back == 1 and other == 0,
    ("while detached %d (%s), held image sent back %d, on the stderr channel %d"):format(gone, had, back, other))
  L.clear_all()
end

-- ── H, continued: a terminal attached with nvim --remote-ui on Neovim 0.11 ─
-- After :detach the way back is nvim --remote-ui. Neovim 0.11 lists such a
-- TUI with its term_name but without stdout_tty (0.12 lists it), and with
-- no nvim_ui_send the writes go to the editor's stderr, the terminal the
-- editor was started in: they reach the TUI only when it runs there, and
-- from anywhere else they land in a terminal another program draws on. The
-- module asks the system once per such UI (Image._pid_in_my_terminal, with
-- the client's pid from its channel's client info). In H10 to H10d the spec
-- answers for the system; H11 asks the real one, in a child Neovim on a pty.
local real_chan_info = vim.api.nvim_get_chan_info
local tui_pid = {}  -- simulated UI channel -> its client's pid
vim.api.nvim_get_chan_info = function(ch)
  if tui_pid[ch] then
    return { id = ch, mode = "rpc", stream = "socket",
             client = { name = "nvim-tui", type = "ui", attributes = { pid = tui_pid[ch] } } }
  end
  return real_chan_info(ch)
end
-- a fresh image module and backend; Neovim 0.11's API when `v011`; its own
-- terminal UI attached when it loads when `own_tui` (else none, as with nvim
-- --headless --listen); `here(pid)` answers, 20 ms after it is asked,
-- whether that process runs in the editor's terminal; the backend can open
-- the editor's tty when `local_ok`. Returns the module, the pids asked
-- about and the backend.
local function stub_here(L, here)
  local q = {}
  L._pid_in_my_terminal = function(pid, cb)
    q[#q + 1] = pid
    vim.defer_fn(function() cb(here(pid)) end, 20)
  end
  return q
end
local function load_tui(v011, own_tui, here, local_ok)
  package.loaded["jupynvim.notebook.image"] = nil
  tty_ui = own_tui and true or false; ui_send_api = not v011; install()
  local L = require("jupynvim.notebook.image")
  local c = fake_client(local_ok)
  L.attach(c, vim.env.JUPYNVIM_TTY)
  return L, stub_here(L, here), c
end
-- how many kitty escapes the backend was asked to write itself
local function backend_writes(c)
  local n = 0
  for _, list in ipairs({ c.sync, c.async }) do
    for _, x in ipairs(list) do
      if x[1]:find("^kitty_") and x[1] ~= "kitty_attach" then n = n + 1 end
    end
  end
  return n
end
-- nvim --remote-ui attaches on channel `chan`, its client process being
-- `pid`. As with the real client, its channel carries no pid at UIEnter: the
-- client describes itself right after (nvim_set_client_info, then ChanInfo).
-- Returns how often the system was asked before that.
local function tui_attach(chan, pid, asked)
  tui_chan = chan
  tty_ui = "tui"; install()
  vim.api.nvim_exec_autocmds("UIEnter", {})
  local n = #asked
  tui_pid[chan] = pid
  vim.api.nvim_exec_autocmds("ChanInfo", {})
  return n
end
local function ui_gone()
  tty_ui = false; install()
  vim.api.nvim_exec_autocmds("UILeave", {})
end
local function tx_of(L, key)
  local pl = L._placements[key]
  return pl and ("\27_Ga=t,f=100,i=%d,"):format(pl.image_id) or "?"
end
local function sent(list, tx) return count(list, function(s) return s:find(tx, 1, true) == 1 end) end
do
  -- :detach, then nvim --remote-ui in the terminal the editor was started in
  local L, asked = load_tui(true, true, function(pid) return pid == 4242 end)
  reset()
  L.ensure_transmitted("spec_r0", PNG, function() end, { renderer = "placeholder" })
  local before = #chan_out
  ui_gone()
  reset()
  L.ensure_transmitted("spec_r1", PNG, function() end, { renderer = "placeholder" })
  L.clear_visible_placements()
  local gone = #ui_out + #chan_out
  local tx = tx_of(L, "spec_r1")
  tui_attach(11, 4242, asked)
  local early = #ui_out + #chan_out
  vim.wait(500, function() return #chan_out > 0 end, 5)
  vim.wait(100)
  local back, first, through_ui = sent(chan_out, tx), chan_out[1], #ui_out
  -- asked once for that UI: another UI event, a write, a render ask nothing
  vim.api.nvim_exec_autocmds("UIEnter", {})
  L.clear_visible_placements(); L.reassert_virtual_placements()
  vim.wait(100)
  chk("H10 on Neovim 0.11 a terminal attached with --remote-ui where the editor was started gets what was held, on the stderr channel, once the system said it runs there, asked once",
    before >= 1 and gone == 0 and early == 0 and back == 1 and first == "\27_Ga=d,d=a,q=2\27\\" and through_ui == 0
      and #asked == 1 and asked[1] == 4242 and L._writes_held and not L._writes_held(),
    ("before %d, while detached %d, before the answer %d, held image sent back %d, first %s, through nvim_ui_send %d, asked %s"):format(
      before, gone, early, back, vim.inspect(first), through_ui, vim.inspect(asked)))
  L.clear_all()
end
do
  -- :detach, then nvim --remote-ui from another terminal: the stderr
  -- channel reaches the first terminal, where the shell draws by then
  local L, asked = load_tui(true, true, function() return false end)
  ui_gone()
  reset()
  L.ensure_transmitted("spec_r2", PNG, function() end, { renderer = "placeholder" })
  local pr = L._placements.spec_r2
  pcall(L.set_visible_probe, "spec_r2", function() return true end)
  if pr then pr.frames, pr.delays = { FA, FB }, { 30, 30 } end
  L.resume_animations()
  tui_attach(12, 5151, asked)
  local s0 = L._frames_skipped or 0
  vim.wait(400)
  chk("H10b on Neovim 0.11 a terminal attached with --remote-ui from another terminal gets nothing on the stderr channel, and a gif's clock runs on",
    pr and pr.timer ~= nil and #chan_out + #ui_out == 0 and (L._frames_skipped or 0) - s0 >= 5
      and #asked == 1 and asked[1] == 5151 and L._writes_held and L._writes_held(),
    ("stderr %d, ui_send %d, skipped %d, asked %s"):format(#chan_out, #ui_out, (L._frames_skipped or 0) - s0,
      vim.inspect(asked)))
  L.clear_all()
end
do
  -- nvim --headless --listen: no terminal UI of its own; --remote-ui clients
  local L, asked = load_tui(true, false, function(pid) return pid == 6262 end)
  reset()
  L.ensure_transmitted("spec_r3", PNG, function() end, { renderer = "placeholder" })
  local headless = #chan_out
  tui_attach(13, 5252, asked)
  vim.wait(100)
  reset()
  L.ensure_transmitted("spec_r4", PNG, function() end, { renderer = "placeholder" })
  local elsewhere = #chan_out + #ui_out
  local tx = tx_of(L, "spec_r4")
  ui_gone()
  reset()
  tui_attach(14, 6262, asked)
  vim.wait(500, function() return #chan_out > 0 end, 5)
  vim.wait(100)
  chk("H10c on Neovim 0.11 a headless editor writes while no UI attached, holds while a --remote-ui terminal is elsewhere, and sends that once one runs where it was started",
    headless >= 1 and elsewhere == 0 and sent(chan_out, tx) == 1 and #ui_out == 0
      and #asked == 2 and asked[1] == 5252 and asked[2] == 6262,
    ("headless %d, while the terminal UI was elsewhere %d, held image sent back %d, through nvim_ui_send %d, asked %s"):format(
      headless, elsewhere, sent(chan_out, tx), #ui_out, vim.inspect(asked)))
  L.clear_all()
end
do
  -- Neovim 0.12 lists a terminal UI with stdout_tty, and nvim_ui_send reaches
  -- only those: one listed without it (a 0.11 client) is not asked about
  local L, asked = load_tui(false, true, function() return true end)
  ui_gone()
  reset()
  tui_attach(15, 7272, asked)
  vim.wait(100)
  L.ensure_transmitted("spec_r5", PNG, function() end, { renderer = "placeholder" })
  -- another UI event, now that the client gave its pid, looks at the UIs again
  vim.api.nvim_exec_autocmds("UIEnter", {})
  vim.wait(100)
  chk("H10d with nvim_ui_send a UI listed without stdout_tty is not asked about and takes no writes",
    #asked == 0 and #ui_out + #chan_out == 0 and L._writes_held and L._writes_held(),
    ("asked %s, ui_send %d, stderr %d"):format(vim.inspect(asked), #ui_out, #chan_out))
  L.clear_all()
end
do
  -- a plugin loaded lazily after :detach and nvim --remote-ui in the
  -- terminal the editor was started in (Neovim 0.11): the module loads while
  -- that UI is listed and its client has not described itself yet, so the
  -- writes are held from the start; what was written before the system's
  -- answer goes out once it says the client runs there
  package.loaded["jupynvim.notebook.image"] = nil
  tui_chan = 18; tty_ui = "tui"; ui_send_api = false; install()
  local L = require("jupynvim.notebook.image")
  local q = stub_here(L, function(pid) return pid == 4343 end)
  L.attach(fake_client(false), vim.env.JUPYNVIM_TTY)
  reset()
  L.ensure_transmitted("spec_r7", PNG, function() end, { renderer = "placeholder" })
  local early = #chan_out + #ui_out
  local held_then = L._writes_held and L._writes_held()
  local tx = tx_of(L, "spec_r7")
  tui_pid[18] = 4343
  vim.api.nvim_exec_autocmds("ChanInfo", {})
  vim.wait(500, function() return #chan_out > 0 end, 5)
  vim.wait(100)
  chk("H12 on Neovim 0.11, with the image module loaded while a --remote-ui terminal waits for the system's answer, what was written before the answer goes out on the stderr channel once the system said it runs there",
    held_then and early == 0 and sent(chan_out, tx) == 1 and #ui_out == 0
      and #q == 1 and q[1] == 4343 and L._writes_held and not L._writes_held(),
    ("held at first %s, before the answer %d, held image sent back %d, through nvim_ui_send %d, asked %s"):format(
      tostring(held_then), early, sent(chan_out, tx), #ui_out, vim.inspect(q)))
  L.clear_all()
end
do
  -- nvim --headless --listen on Neovim 0.11, started in a terminal that is
  -- its stderr: with no UI its backend writes to that terminal itself (the
  -- tests' case). Once a --remote-ui terminal attaches, the backend is told
  -- to stop and every write goes through tty_write and its hold: nothing
  -- reaches the first terminal while that UI runs elsewhere, and what was
  -- held goes out on the stderr channel once one runs where the editor was
  -- started.
  local L, q, c = load_tui(true, false, function(pid) return pid == 8282 end, true)
  local was_local = L._remote_mode == false
  L.ensure_transmitted("spec_r8", PNG, function() end, { renderer = "placeholder" })
  local headless = backend_writes(c)
  tui_attach(16, 8181, q)
  vim.wait(100)
  reset()
  local n0 = backend_writes(c)
  L.ensure_transmitted("spec_r9", PNG, function() end, { renderer = "placeholder" })
  L.clear_visible_placements()
  local to_backend = backend_writes(c) - n0
  local elsewhere = #chan_out + #ui_out
  local tx = tx_of(L, "spec_r9")
  ui_gone()
  reset()
  tui_attach(17, 8282, q)
  vim.wait(500, function() return #chan_out > 0 end, 5)
  vim.wait(100)
  chk("H13 on Neovim 0.11 a headless editor whose stderr is its terminal stops its backend writing there when a --remote-ui terminal attaches: nothing on any path while that UI is elsewhere, the held image on the stderr channel once one runs where it was started",
    was_local and headless >= 1 and asked(c.async, "kitty_attach", "remote") and L._remote_mode
      and to_backend == 0 and elsewhere == 0 and sent(chan_out, tx) == 1 and #ui_out == 0,
    ("local at first %s, backend writes headless %d, told to stop %s, backend writes after %d, other paths while elsewhere %d, held image sent back %d, through nvim_ui_send %d"):format(
      tostring(was_local), headless, tostring(asked(c.async, "kitty_attach", "remote")), to_backend, elsewhere,
      sent(chan_out, tx), #ui_out))
  L.clear_all()
end
do
  -- nvim --headless --listen on Neovim 0.11 started with its stderr not a
  -- terminal (in the background with 2>/dev/null): the escapes encoded here
  -- would go to that file, so the backend keeps writing to the editor's
  -- terminal, and what it is asked to write is held like any write: nothing
  -- while the --remote-ui terminal is elsewhere, the held image once one
  -- runs where the editor was started
  stderr_kind = "file"
  local L, q, c = load_tui(true, false, function(pid) return pid == 9393 end, true)
  local was_local = L._remote_mode == false
  tui_attach(19, 9292, q)
  vim.wait(100)
  reset()
  local n0 = backend_writes(c)
  L.ensure_transmitted("spec_rb", PNG, function() end, { renderer = "placeholder" })
  L.clear_visible_placements()
  local while_elsewhere = backend_writes(c) - n0
  local held_while = L._writes_held and L._writes_held()
  local other = #chan_out + #ui_out
  local pb = L._placements.spec_rb
  ui_gone()
  tui_attach(20, 9393, q)
  local function tx_back()
    local n = 0
    for _, x in ipairs(c.async) do
      if x[1] == "kitty_transmit_virtual" and pb and x[2].image_id == pb.image_id and x[2].png_b64 == PNG then n = n + 1 end
    end
    return n
  end
  vim.wait(500, function() return tx_back() > 0 end, 5)
  vim.wait(100)
  chk("H13c on Neovim 0.11 a headless editor whose stderr is not a terminal keeps its backend writing to its terminal, and holds what the backend is asked to write while the --remote-ui terminal is elsewhere",
    was_local and not L._remote_mode and not asked(c.async, "kitty_attach", "remote") and pb ~= nil
      and held_while and while_elsewhere == 0 and other == 0 and tx_back() == 1 and #chan_out == 0 and #ui_out == 0,
    ("local at first %s, local at the end %s, told to stop %s, held %s, backend writes while elsewhere %d, other paths %d, held image sent back through the backend %d, stderr %d"):format(
      tostring(was_local), tostring(not L._remote_mode), tostring(asked(c.async, "kitty_attach", "remote")),
      tostring(held_while), while_elsewhere, other, tx_back(), #chan_out))
  L.clear_all()
  stderr_kind = "tty"
end
do
  -- the same editor when the --remote-ui terminal attached first and the
  -- notebook (so the backend) comes after: attach keeps the backend's local
  -- mode, and with that terminal where the editor was started the image
  -- goes to the backend
  stderr_kind = "file"
  package.loaded["jupynvim.notebook.image"] = nil
  tui_chan = 21; tty_ui = "tui"; ui_send_api = false; install()
  local L = require("jupynvim.notebook.image")
  local q = stub_here(L, function(pid) return pid == 9494 end)
  tui_pid[21] = 9494
  vim.api.nvim_exec_autocmds("ChanInfo", {})
  vim.wait(500, function() return L._writes_held and not L._writes_held() end, 5)
  local c = fake_client(true)
  L.attach(c, vim.env.JUPYNVIM_TTY)
  reset()
  L.ensure_transmitted("spec_rc", PNG, function() end, { renderer = "placeholder" })
  local tx = 0
  for _, x in ipairs(c.sync) do if x[1] == "kitty_transmit_virtual" and x[2].png_b64 == PNG then tx = tx + 1 end end
  chk("H13d on Neovim 0.11 with its stderr not a terminal, a backend attached after a --remote-ui terminal keeps its local mode and writes the image while that UI runs where the editor was started",
    #q == 1 and asked(c.sync, "kitty_attach", "tty") and not L._remote_mode and tx == 1 and #chan_out + #ui_out == 0,
    ("asked %s, tty probed %s, remote %s, transmits to the backend %d, other paths %d"):format(vim.inspect(q),
      tostring(asked(c.sync, "kitty_attach", "tty")), tostring(L._remote_mode), tx, #chan_out + #ui_out))
  L.clear_all()
  stderr_kind = "tty"
end
do
  -- Neovim 0.12, nvim --headless --listen whose only terminal UI left
  -- (:detach) before the first notebook was opened: the backend attaches
  -- then and could open the editor's terminal, but is not asked to write;
  -- the image waits for a terminal UI and goes out through nvim_ui_send
  package.loaded["jupynvim.notebook.image"] = nil
  tty_ui = true; ui_send_api = true; install()
  local L = require("jupynvim.notebook.image")
  ui_gone()
  reset()
  local c = fake_client(true)
  L.attach(c, vim.env.JUPYNVIM_TTY)
  L.ensure_transmitted("spec_ra", PNG, function() end, { renderer = "placeholder" })
  local to_backend = backend_writes(c)
  local gone = #ui_out + #chan_out
  local tx = tx_of(L, "spec_ra")
  tty_ui = true; install()
  reset()
  vim.api.nvim_exec_autocmds("UIEnter", {})
  vim.wait(300, function() return #ui_out > 0 end, 5)
  vim.wait(100)
  chk("H13b on Neovim 0.12 a backend attached after the terminal UI left is not asked to write to the tty it could open, and the image goes out through nvim_ui_send when a terminal UI is back",
    L._remote_mode and not asked(c.sync, "kitty_attach", "tty") and to_backend == 0 and gone == 0
      and sent(ui_out, tx) == 1 and #chan_out == 0,
    ("remote %s, tty probed %s, backend writes %d, while detached %d, held image sent back %d, on the stderr channel %d"):format(
      tostring(L._remote_mode), tostring(asked(c.sync, "kitty_attach", "tty")), to_backend, gone, sent(ui_out, tx), #chan_out))
  L.clear_all()
end
vim.api.nvim_get_chan_info = real_chan_info
do
  -- the real question, asked in a child Neovim whose stderr is a pty of its
  -- own (a pty job): yes for a process it started (so on that terminal)
  -- whose arguments are a --remote-ui client's; no for one on that terminal
  -- that is not a --remote-ui client, for a --remote-ui one on another pty
  -- (a pty job of the spec's), and for a process that is gone
  local elsewhere = vim.fn.jobstart({ "sh", "-c", "read x", "--remote-ui" }, { pty = true })
  local gone_obj = vim.system({ "true" })
  gone_obj:wait()
  local done_pid = gone_obj.pid
  local res, child = tmp .. "/pidtty.txt", tmp .. "/pidtty.lua"
  local cwd = vim.fn.getcwd()
  local f = io.open(child, "w")
  f:write(([[
package.path = %q .. "/lua/?.lua;" .. %q .. "/lua/?/init.lua;" .. package.path
local I = require("jupynvim.notebook.image")
local got = {}
local a = vim.system({ "sh", "-c", "read x", "--remote-ui" }, { stdin = true })
local b = vim.system({ "sh", "-c", "read x", "other" }, { stdin = true })
local function ask(name, pid)
  if not I._pid_in_my_terminal then got[#got + 1] = name .. "=missing"; return end
  I._pid_in_my_terminal(pid, function(v) got[#got + 1] = name .. "=" .. tostring(v) end)
end
ask("remote_ui_here", a.pid); ask("other_here", b.pid); ask("remote_ui_elsewhere", %d); ask("gone", %d)
vim.wait(5000, function() return #got == 4 end, 10)
-- each answer waits for a ps to return: one that has not after 5 s is
-- stuck (a host whose ps hangs), and the answers are missing for that
local late = #got < 4 and (" (%%d of 4 not answered in 5 s: ps had not returned)"):format(4 - #got) or ""
a:write(nil); b:write(nil); a:wait(3000); b:wait(3000)
table.sort(got)
local o = io.open(%q, "w"); o:write(table.concat(got, " ") .. late); o:close()
]]):format(cwd, cwd, vim.fn.jobpid(elsewhere), done_pid, res))
  f:close()
  local job = vim.fn.jobstart({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-l", child }, { pty = true })
  local rc = vim.fn.jobwait({ job }, 20000)[1]
  if rc == -1 then vim.fn.jobstop(job) end
  vim.fn.jobstop(elsewhere)
  local o = io.open(res)
  local out = o and o:read("*a") or "(no answer)"
  if o then o:close() end
  chk("H11 the system says a process runs in the editor's terminal only when that is its controlling terminal and it is a --remote-ui client",
    out == "gone=false other_here=false remote_ui_elsewhere=false remote_ui_here=true",
    ("%s (child rc %s)"):format(out, tostring(rc)))
end
do
  -- the same question in a child Neovim about a --remote-ui process it
  -- started (a yes in H11) and, when given one, about one on another pty:
  -- with its stderr on /dev/null and a pty as its controlling terminal,
  -- where the backend's local mode writes, that terminal is the one
  -- compared; and when it cannot tell, the answer is no (the writes stay
  -- held): no ps on its PATH, or no terminal at all (a new session with its
  -- output on pipes)
  local child = tmp .. "/pidtty2.lua"
  local cwd = vim.fn.getcwd()
  local f = io.open(child, "w")
  f:write(([[
package.path = %q .. "/lua/?.lua;" .. %q .. "/lua/?/init.lua;" .. package.path
local I = require("jupynvim.notebook.image")
local a = vim.system({ "/bin/sh", "-c", "read x", "--remote-ui" }, { stdin = true })
local got = {}
local function ask(name, pid)
  if not I._pid_in_my_terminal then got[#got + 1] = name .. "=missing"; return end
  I._pid_in_my_terminal(pid, function(v) got[#got + 1] = name .. "=" .. tostring(v) end)
end
ask("remote_ui_here", a.pid)
if arg[2] then ask("remote_ui_elsewhere", tonumber(arg[2])) end
local want = arg[2] and 2 or 1
vim.wait(5000, function() return #got == want end, 10)
local late = #got < want and (" (%%d of %%d not answered in 5 s: ps had not returned)"):format(want - #got, want) or ""
a:write(nil); a:wait(3000)
table.sort(got)
local o = io.open(arg[1], "w")
o:write(("stderr=%%s ps=%%d %%s%%s"):format(vim.uv.guess_handle(2), vim.fn.executable("ps"), table.concat(got, " "), late))
o:close()
]]):format(cwd, cwd))
  f:close()
  local nv = { vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-l", child }
  local function read(res)
    local o = io.open(res)
    local out = o and o:read("*a") or "(no answer)"
    if o then o:close() end
    return out
  end
  local function run(cmd, opts)
    local job = vim.fn.jobstart(cmd, opts)
    local rc = vim.fn.jobwait({ job }, 20000)[1]
    if rc == -1 then vim.fn.jobstop(job) end
    return rc
  end
  local other = vim.fn.jobstart({ "sh", "-c", "read x", "--remote-ui" }, { pty = true })
  local res_b = tmp .. "/pidtty_ctty.txt"
  local rc_b = run(vim.list_extend({ "/bin/sh", "-c", 'exec "$0" "$@" 2>/dev/null' },
    vim.list_extend(vim.deepcopy(nv), { res_b, tostring(vim.fn.jobpid(other)) })), { pty = true })
  vim.fn.jobstop(other)
  local out_b = read(res_b)
  chk("H11b with its stderr not a terminal the editor's controlling terminal is the one compared",
    out_b == "stderr=file ps=1 remote_ui_elsewhere=false remote_ui_here=true", ("%s (child rc %s)"):format(out_b, tostring(rc_b)))
  local nops = tmp .. "/nops"
  vim.fn.mkdir(nops, "p")
  local res_c = tmp .. "/pidtty_nops.txt"
  local rc_c = run(vim.list_extend(vim.deepcopy(nv), { res_c }), { pty = true, env = { PATH = nops } })
  local out_c = read(res_c)
  chk("H11c with no ps to ask the answer is no",
    out_c == "stderr=tty ps=0 remote_ui_here=false", ("%s (child rc %s)"):format(out_c, tostring(rc_c)))
  local res_d = tmp .. "/pidtty_none.txt"
  local obj = vim.system(vim.list_extend(vim.deepcopy(nv), { res_d }), { detach = true })
  local r_d = obj:wait(20000)
  local out_d = read(res_d)
  chk("H11d with no terminal to compare with (stderr not one, no controlling terminal) the answer is no",
    out_d == "stderr=pipe ps=1 remote_ui_here=false", ("%s (child rc %s)"):format(out_d, tostring(r_d and r_d.code)))
end
-- ── I, continued: when the tmux version is asked, and which tmux answers ─
-- Asked once when the backend is attached, inside tmux only (the rule the
-- passthrough follows: TMUX set, and not switched off for a TMUX inherited
-- from outside a multiplexer), of the running tmux; the tmux binary on PATH
-- is the fallback, for a server that prints nothing for #{version}. Each
-- case loads a fresh module; the commands are stand-ins that note their name.
do
  local ran = tmp .. "/tmux_ran"
  local function stand_in(name, out, code)
    return { "sh", "-c", ("echo %s >> '%s'; echo '%s'; exit %d"):format(name, ran, out, code or 0) }
  end
  local function who()
    local f = io.open(ran)
    if not f then return "" end
    local t = f:read("*a")
    f:close()
    return (t:gsub("\n", " "))
  end
  -- env: TMUX and JUPYNVIM_DISABLE_TMUX_PASSTHROUGH as the module loads;
  -- returns markers off, the stand-ins that ran, inside tmux
  local function try(env_tmux, env_disable, server, binary, expect_off)
    os.remove(ran)
    package.loaded["jupynvim.notebook.image"] = nil
    vim.env.TMUX, vim.env.JUPYNVIM_DISABLE_TMUX_PASSTHROUGH = env_tmux, env_disable
    tty_ui = true; ui_send_api = true; install()
    local L = require("jupynvim.notebook.image")
    vim.env.TMUX, vim.env.JUPYNVIM_DISABLE_TMUX_PASSTHROUGH = nil, nil
    L._tmux_server_version_cmd, L._tmux_version_cmd = server, binary
    L.attach(fake_client(false), vim.env.JUPYNVIM_TTY)
    vim.wait(expect_off and 1500 or 500, function() return L._mark_off end, 10)
    vim.wait(150)
    local off, ran_now, inside = L._mark_off, who(), L._in_tmux
    L.clear_all()
    return off, ran_now, inside
  end
  local TM = tmp .. "/tmux-sock,1,0"
  local off1, r1, in1 = try(TM, nil, stand_in("server", "3.1c"), stand_in("binary", "tmux 3.5a"), true)
  chk("I26 inside tmux the running tmux is asked: a 3.1c server starts the session with markers off, and the tmux binary on PATH is not asked",
    in1 == true and off1 == true and r1 == "server ", ("inside %s, markers off %s, ran '%s'"):format(tostring(in1), tostring(off1), r1))
  local off2, r2 = try(TM, nil, stand_in("server", "3.5a"), stand_in("binary", "tmux 3.1c"), false)
  chk("I26b a 3.5a server with an older tmux binary on PATH keeps markers on: the server decides",
    off2 == false and r2 == "server ", ("markers off %s, ran '%s'"):format(tostring(off2), r2))
  local off3, r3 = try(TM, nil, stand_in("server", "x", 1), stand_in("binary", "tmux 3.0a"), true)
  chk("I26c when the server cannot be asked, the tmux binary's version is used",
    off3 == true and r3 == "server binary ", ("markers off %s, ran '%s'"):format(tostring(off3), r3))
  local off4, r4 = try(TM, nil, stand_in("server", ""), stand_in("binary", "tmux 2.9a"), true)
  chk("I26d when the server prints no version (an old tmux), the tmux binary's version is used",
    off4 == true and r4 == "server binary ", ("markers off %s, ran '%s'"):format(tostring(off4), r4))
  local off5, r5 = try(TM, nil, stand_in("server", "master"), stand_in("binary", "tmux master"), false)
  chk("I26e a version nobody can read changes nothing",
    off5 == false and r5 == "server binary ", ("markers off %s, ran '%s'"):format(tostring(off5), r5))
  local off6, r6, in6 = try(TM, "1", stand_in("server", "3.1c"), stand_in("binary", "tmux 3.1c"), false)
  chk("I26f a TMUX inherited from outside a multiplexer (JUPYNVIM_DISABLE_TMUX_PASSTHROUGH set) is no tmux: no version is asked, markers stay on",
    in6 == false and off6 == false and r6 == "", ("inside %s, markers off %s, ran '%s'"):format(tostring(in6), tostring(off6), r6))
  local off7, r7, in7 = try(nil, nil, stand_in("server", "3.1c"), stand_in("binary", "tmux 3.1c"), false)
  chk("I26g outside tmux no version is asked",
    in7 == false and off7 == false and r7 == "", ("inside %s, markers off %s, ran '%s'"):format(tostring(in7), tostring(off7), r7))
end

-- ── R. a session with no local backend ─────────────────────────────────────
-- A remote backend cannot reach this terminal, so it is only told not to
-- write (M.attach_remote) and never becomes the image writer; a session with
-- only remote notebooks runs no M.attach at all. The module may also load
-- after the UI's UIEnter (a plugin loaded lazily), so nothing sets
-- M._remote_mode. The escapes are then encoded here (no_writer), and what
-- depends on who writes follows that: gif frames wait for the terminal, the
-- status fence works, the tmux version is asked, and the hold applies as it
-- does to every other write. When the local backend of a headless editor
-- exits, its writes come here too. Each case loads a fresh module and none
-- runs M.attach unless it says so.
do
  local function load_no_backend(v011)
    package.loaded["jupynvim.notebook.image"] = nil
    tty_ui = true; ui_send_api = not v011; install()
    return require("jupynvim.notebook.image")
  end
  local function gif(L, key)
    local F = {}
    for i = 1, 4 do F[i] = vim.base64.encode(png(40, 30, 60 + i)) end
    L._frame_window = 1  -- one frame in flight, whatever its size
    L.ensure_transmitted(key, F[1], function() end, { renderer = "placeholder" })
    local p = L._placements[key]
    pcall(L.set_visible_probe, key, function() return true end)
    if p then p.frames, p.delays = F, { 80, 80, 80, 80 } end
    return p
  end
  local remote = fake_client(false)
  local L = load_no_backend()
  if L.attach_remote then L.attach_remote(remote) end
  chk("R1 a remote backend is told not to write, without waiting, and does not become the writer",
    #remote.sync == 0 and asked(remote.async, "kitty_attach", "remote") and not L._remote_mode,
    ("sync %d, told %s, remote mode %s"):format(#remote.sync, tostring(asked(remote.async, "kitty_attach", "remote")), tostring(L._remote_mode)))
  reset()
  L.ensure_transmitted("spec_r2", PNG, function() end, { renderer = "placeholder" })
  local written = count(ui_out, is_tx)
  chk("R2 with no local backend an image is encoded here and goes out through nvim_ui_send, nothing of it to the remote backend",
    written >= 1 and backend_writes(remote) == 0 and #chan_out == 0,
    ("transmits %d, asked of the remote backend %d, on the stderr channel %d"):format(written, backend_writes(remote), #chan_out))
  L.clear_all()

  L = load_no_backend()
  local p = gif(L, "spec_r3")
  reset()
  local held0, n0 = L._frames_held or 0, L._frames_sent or 0
  L.resume_animations()
  vim.wait(700)
  chk("R3 with no local backend, and the module loaded after the UI's UIEnter, a gif frame waits for the terminal: a status request follows it and the next frame waits for the answer",
    frames_out() == 1 and count(ui_out, is_req) == 1 and (L._frames_held or 0) - held0 >= 3 and (L._frames_sent or 0) - n0 == 1,
    ("frames %d, requests %d, held %d, sent %d"):format(frames_out(), count(ui_out, is_req), (L._frames_held or 0) - held0, (L._frames_sent or 0) - n0))
  auto_mark = false
  local passed = L.status_fence and L.status_fence()
  local shut = passed and not passed()
  answer_mark()
  auto_mark = true
  chk("R4 the status fence of the palette's question stands behind that frame, as with a backend attached",
    shut == true and passed and passed() == true, ("shut %s, after the marker's answer %s"):format(tostring(shut), tostring(passed and passed())))
  L.pause_animations()
  L.clear_all()

  -- the tmux version: inside tmux with no backend ever attached, asked at the
  -- first frame; a session that has one was asked at its attach (I26)
  local ran = tmp .. "/tmux_ran_r"
  os.remove(ran)
  package.loaded["jupynvim.notebook.image"] = nil
  vim.env.TMUX = tmp .. "/tmux-sock,1,0"
  tty_ui = true; ui_send_api = true; install()
  L = require("jupynvim.notebook.image")
  vim.env.TMUX = nil
  L._tmux_server_version_cmd = { "sh", "-c", ("echo server >> '%s'; echo 3.1c"):format(ran) }
  L._tmux_version_cmd = { "sh", "-c", ("echo binary >> '%s'; echo 3.1c"):format(ran) }
  p = gif(L, "spec_r5")
  reset()
  auto_mark = false  -- a tmux before 3.2 does not answer the marker
  L.resume_animations()
  vim.wait(1500, function() return L._mark_off end, 10)
  auto_mark = true
  local fh = io.open(ran)
  local who = fh and fh:read("*a") or ""
  if fh then fh:close() end
  chk("R5 inside tmux with no backend attached, the first frame asks the running tmux once: a 3.1c server turns markers off and the gif does not wait for a marker",
    L._mark_off == true and who == "server\n", ("markers off %s, ran %s"):format(tostring(L._mark_off), vim.inspect(who)))
  L.pause_animations()
  L.clear_all()

  -- the hold: :detach with no local backend, an image and a delete while no
  -- terminal shows the editor, then a terminal back
  L = load_no_backend()
  reset()
  L.ensure_transmitted("spec_r6a", PNG, function() end, { renderer = "placeholder" })
  tty_ui = false; install()
  vim.api.nvim_exec_autocmds("UILeave", {})
  reset()
  local h0 = L._held_n or 0
  L.ensure_transmitted("spec_r6", FA, function() end, { renderer = "placeholder" })
  L.clear_visible_placements()
  local gone, held = #ui_out + #chan_out, (L._held_n or 0) - h0
  local pl = L._placements.spec_r6
  tty_ui = true; install()
  reset()
  vim.api.nvim_exec_autocmds("UIEnter", {})
  vim.wait(300, function() return #ui_out > 0 end, 5)
  vim.wait(100)
  local tx = pl and ("\27_Ga=t,f=100,i=%d,"):format(pl.image_id) or "?"
  chk("R6 with no local backend nothing is written while no terminal shows the editor, each write is held, and the held image goes out when one is back",
    gone == 0 and held >= 2 and count(ui_out, function(s) return s:find(tx, 1, true) == 1 end) == 1,
    ("while detached %d, held %d, sent back %d"):format(gone, held, count(ui_out, function(s) return s:find(tx, 1, true) == 1 end)))
  L.clear_all()

  -- the same hold where nothing turns the mode on (Neovim 0.11 with stderr
  -- not a terminal, so the Lua writes reach none and a UI change leaves the
  -- mode off): with no local backend the escapes are still encoded here
  -- (no_writer); while the editor is suspended each write is held, and the
  -- held image is encoded and written at the resume (no backend is asked)
  stderr_kind = "file"
  L = load_no_backend(true)
  reset()
  fire("VimSuspend")
  local h6 = L._held_n or 0
  L.ensure_transmitted("spec_r6b", FB, function() end, { renderer = "placeholder" })
  local mode6, gone6, held6 = L._remote_mode, #ui_out + #chan_out, (L._held_n or 0) - h6
  local p6 = L._placements.spec_r6b
  local tx6 = p6 and ("\27_Ga=t,f=100,i=%d,"):format(p6.image_id) or "?"
  local function back6() return count(chan_out, function(x) return x:find(tx6, 1, true) == 1 end) end
  fire("VimResume")
  vim.wait(300, function() return back6() > 0 end, 5)
  local mode6b = L._remote_mode
  stderr_kind = "tty"
  chk("R6b with no local backend and the mode left off (Neovim 0.11, stderr not a terminal) a write while suspended is held, nothing is written, and the image is encoded here and sent at the resume",
    mode6 == false and mode6b == false and gone6 == 0 and held6 >= 1 and back6() == 1,
    ("mode %s then %s, written while suspended %d, held %d, sent at the resume %d"):format(tostring(mode6),
      tostring(mode6b), gone6, held6, back6()))
  L.clear_all()

  -- Neovim 0.11: the same session writes on the stderr channel, unpaced
  L = load_no_backend(true)
  reset()
  L.ensure_transmitted("spec_r7", PNG, function() end, { renderer = "placeholder" })
  chk("R7 on Neovim 0.11 with no local backend an image goes out on the stderr channel",
    count(chan_out, is_tx) >= 1 and #ui_out == 0, ("stderr %d, nvim_ui_send %d"):format(count(chan_out, is_tx), #ui_out))
  L.clear_all()

  -- a headless editor whose backend writes (LOCAL mode): held while writes
  -- are, and once it exited the writes are encoded here instead of dropped
  package.loaded["jupynvim.notebook.image"] = nil
  tty_ui = false; ui_send_api = true; install()
  L = require("jupynvim.notebook.image")
  local c = fake_client(true)
  L.attach(c, vim.env.JUPYNVIM_TTY)
  L._suspended = true
  reset()
  local h1 = L._held_n or 0
  L.ensure_transmitted("spec_r8", PNG, function() end, { renderer = "placeholder" })
  local asked_held, held_n = backend_writes(c), (L._held_n or 0) - h1
  L._suspended = false
  L.ensure_transmitted("spec_r8b", FA, function() end, { renderer = "placeholder" })
  local asked_live = backend_writes(c)
  c.job = nil
  reset()
  L.ensure_transmitted("spec_r8c", FB, function() end, { renderer = "placeholder" })
  chk("R8 a local backend is asked to write only while writes are not held, and once it exited the image is encoded here, not dropped",
    not L._remote_mode and asked_held == 0 and held_n >= 1 and asked_live >= 1 and backend_writes(c) == asked_live
      and count(chan_out, is_tx) >= 1,
    ("remote %s, asked while held %d, held %d, asked after %d, then %d, on the stderr channel %d"):format(tostring(L._remote_mode),
      asked_held, held_n, asked_live, backend_writes(c), count(chan_out, is_tx)))
  L.clear_all()
end

-- ── W. no other terminal writer in the source ──────────────────────────────
-- Every write to the terminal goes through the functions meant for it
-- (tty_write and the two requests in notebook/image.lua, the palette's
-- query), so the rules of this spec (ordering, holding, pacing) cover all of
-- it. A scan of the plugin's Lua source: each line loses its first "--" and
-- what follows, and the function a match is in is the last top-level
-- function header before it with no top-level "end" in between ("(top
-- level)" outside any). What is matched is the way out to the terminal, not
-- how a call is spelled: nvim_ui_send called, passed on (to pcall or any
-- function, or into a table), stored (the whole right side of an
-- assignment, or before an `or`) or indexed by its name as a string; any
-- use of the editor's stderr channel (vim.v.stderr, v:stderr, or channel 2
-- given to chansend or nvim_chan_send, in Lua, vim.fn, pcall or Vimscript
-- form); the editor's own stdout and stderr (io.write, io.stdout, io.stderr,
-- io.output, a libuv tty, fs_write on fd 1 or 2); a process that inherits
-- them (io.popen, os.execute, a libuv spawn whose stdio table, on one line,
-- holds fd 1 or 2); and the terminal's device (/dev/tty, /dev/stdout,
-- /dev/stderr, /dev/fd/1 or 2, /proc/self/fd/1 or 2, JUPYNVIM_TTY,
-- image.lua's resolve_tty). Each line is matched together with the next
-- one, so a call split after its opening parenthesis or a comma is seen
-- too (a match counts for the line it starts in). Not seen: a name or a
-- channel number computed at run time, a stdio table spread over lines,
-- and a "--" inside a string cuts the line there; W3 checks the scan on
-- each form it does see.
do
  local root = vim.fn.getcwd() .. "/lua/jupynvim"
  local IMG = "notebook/image.lua"
  local TOP = "(top level)"
  local GROUPS = {
    { "a nvim_ui_send call", { "nvim_ui_send%s*%(", "nvim_ui_send%s*[,%)}]", "=%s*[%w_%.]*nvim_ui_send[ \t]*\n",
        "=%s*[%w_%.]*nvim_ui_send%s*[,;}]", "=%s*[%w_%.]*nvim_ui_send%s+or%f[^%w_]",
        "%[%s*[\"']nvim_ui_send[\"']%s*%]" }, {
      [IMG] = { tty_write = true, send_marker = true, drain_acks = true },
      ["palette.lua"] = { ["M._send"] = true } } },
    { "the stderr channel", { "vim%.v%.stderr", "vim%.v%[%s*[\"']stderr[\"']%s*%]", "v:stderr",
        "chan_?send[\"']?%]?%s*%(%s*2%s*[,%)]", "chan_?send[\"']?%]?%s*,%s*2%s*[,%)]" }, {
      [IMG] = { tty_write = true } } },
    { "the editor's stdout or stderr", { "io%.write%f[^%w_]", "io%.stdout%f[^%w_]", "io%.stderr%f[^%w_]",
        "io%.output%f[^%w_]", "new_tty%f[^%w_]", "fs_write%s*%(%s*[12]%s*[,%)]", "fs_write%s*,%s*[12]%s*[,%)]" }, {
      [IMG] = { tty_write = true },
      ["palette.lua"] = { ["M._send"] = true },
      -- own nvim -l processes with stdout on a pipe (main tree only)
      ["backend/install_lib_job.lua"] = true, ["backend/native_probe.lua"] = true } },
    { "the terminal's device", { "/dev/tty", "/dev/stdout", "/dev/stderr", "/dev/fd/[12]%f[%D]",
        "/proc/self/fd/[12]%f[%D]", "JUPYNVIM_TTY", "resolve_tty%s*%(" }, {
      -- tty_write opens it; resolve_tty asks tty(1) for its path; M.attach
      -- and connect.lua's spawn_client name it for the backend's local mode
      -- (an editor with no terminal UI); term.lua's bash bindings write to
      -- the shell's own pty inside a terminal buffer
      [IMG] = { tty_write = true, resolve_tty = true, ["M.attach"] = true },
      ["backend/connect.lua"] = { spawn_client = true },
      ["remote/term.lua"] = { [TOP] = true } } },
    { "a process on the editor's stdout or stderr", { "io%.popen%f[^%w_]", "os%.execute%f[^%w_]",
        "stdio%s*=%s*{[^}]*[{,]%s*[12]%s*[,}]" }, {} },
  }
  -- every pattern above holds one of these words, so a line with none of
  -- them is not matched further (the scan stays cheap)
  local WORDS = { "send", "stderr", "io.", "tty", "TTY", "fs_write", "/dev/", "/proc/", "popen", "execute",
                  "stdio" }
  local function maybe(line)
    for _, w in ipairs(WORDS) do
      if line:find(w, 1, true) then return true end
    end
    return false
  end
  -- the lines of one file: on_match(line number, function, group index)
  -- for each group a line matches (the line, a newline and the next line:
  -- a match that starts in the line)
  local function scan_lines(lines, on_match)
    local fn = nil
    local code = {}
    for n, line in ipairs(lines) do code[n] = line:gsub("%-%-.*$", "") end
    for n, line in ipairs(code) do
      local name = line:match("^local function ([%w_]+)%(") or line:match("^function ([%w_%.:]+)%(")
      if name then fn = name
      elseif line:match("^end%f[%W]") then fn = nil end
      local two = line .. "\n" .. (code[n + 1] or "")
      if maybe(two) then
        for gi, g in ipairs(GROUPS) do
          for _, pat in ipairs(g[2]) do
            local at = two:find(pat)
            if at and at <= #line then
              on_match(n, fn or TOP, gi)
              break
            end
          end
        end
      end
    end
  end
  local files = vim.fn.globpath(root, "**/*.lua", false, true)
  table.sort(files)
  local t0 = vim.uv.hrtime()
  local stray, found = {}, {}   -- found[file][function][group] = matches
  for _, path in ipairs(files) do
    local rel = path:sub(#root + 2)
    local lines = {}
    for line in io.lines(path) do lines[#lines + 1] = line end
    scan_lines(lines, function(n, where, gi)
      local allow = GROUPS[gi][3][rel]
      local ok = allow == true or (type(allow) == "table" and allow[where] == true)
      if not ok then stray[#stray + 1] = ("%s:%d (%s) %s"):format(rel, n, where, GROUPS[gi][1]) end
      found[rel] = found[rel] or {}
      found[rel][where] = found[rel][where] or {}
      found[rel][where][gi] = (found[rel][where][gi] or 0) + 1
    end)
  end
  local took = (vim.uv.hrtime() - t0) / 1e6
  chk("W1 the plugin's source reaches the terminal only in the functions meant for it (image.lua tty_write, send_marker, drain_acks; the palette's M._send; the two install helper processes; the terminal's path named for the backend)",
    #files > 0 and #stray == 0 and took < 200,
    ("%d files in %.0f ms; not allowed: %s"):format(#files, took, table.concat(stray, "; ")))
  -- the places of image.lua hold what they are allowed for: a rename cannot
  -- empty the scan
  local img = found[IMG] or {}
  local lack = {}
  local function need(fn, gi)
    if not (img[fn] and img[fn][gi]) then lack[#lack + 1] = ("%s: %s"):format(fn, GROUPS[gi][1]) end
  end
  for gi = 1, 4 do need("tty_write", gi) end
  need("send_marker", 1)
  need("drain_acks", 1)
  chk("W2 the scan finds the writes where they are: tty_write holds all four kinds, send_marker and drain_acks the nvim_ui_send call",
    #lack == 0, "not found: " .. table.concat(lack, "; "))
  -- each form the scan is meant to see, in a function of a file no group
  -- allows (each must be seen in its first line, as the group named), and
  -- what is not a way out (each must not be seen)
  local seen_forms = {
    { 1, "nvim_ui_send called", { "  vim.api.nvim_ui_send(s)" } },
    { 1, "through pcall", { "  pcall(vim.api.nvim_ui_send, s)" } },
    { 1, "passed to a function", { "  later(vim.api.nvim_ui_send)" } },
    { 1, "stored", { "  local f = vim.api.nvim_ui_send" } },
    { 1, "stored, then called", { "  local f = vim.api.nvim_ui_send", "  f(s)" } },
    { 1, "stored with a fallback", { "  local f = vim.api.nvim_ui_send or print" } },
    { 1, "in a table", { "  local t = { w = vim.api.nvim_ui_send, n = 1 }" } },
    { 1, "indexed by its name", { "  vim.api['nvim_ui_send'](s)" } },
    { 2, "the stderr channel", { "  vim.api.nvim_chan_send(vim.v.stderr, s)" } },
    { 2, "channel 2 over two lines", { "  vim.fn.chansend(", "    2, s)" } },
    { 3, "io.write", { "  io.write(s)" } },
    { 3, "fd 2 over two lines", { "  vim.uv.fs_write(", "    2, s)" } },
    { 4, "the terminal's device", { "  local f = io.open('/dev/tty', 'w')" } },
    { 5, "io.popen", { "  local h = io.popen('printf x')" } },
    { 5, "os.execute", { "  os.execute('printf x')" } },
    { 5, "a spawn on the editor's stderr", { "  vim.uv.spawn('sh', { args = { '-c', 'x' }, stdio = { nil, 1, 2 } })" } },
    { 5, "a spawn on the editor's stdout", { "  uv.spawn(cmd, { stdio = {0, 1, nil} }, cb)" } },
  }
  local not_ways = {
    "  if vim.api.nvim_ui_send then return 0 end",
    "  if not vim.api.nvim_ui_send then return false end",
    "  local via_stderr = not vim.api.nvim_ui_send",
    "  local has_send = vim.api.nvim_ui_send ~= nil",
    "  return vim.api.nvim_ui_send ~= nil or vim.uv.guess_handle(2) == 'tty'",
    "  log.warn('nvim_ui_send failed: ' .. tostring(err))",
    "  -- vim.api.nvim_ui_send(s) and io.popen('x') in a comment",
    "  local handle, pid = uv.spawn(cmd, {",
    "    stdio = { stdin, stdout, stderr },",
    "  local n = vim.fn.chansend(job, data)",
  }
  local missed, wrong = {}, {}
  for _, c in ipairs(seen_forms) do
    local lines = { "local function w3()" }
    vim.list_extend(lines, c[3])
    lines[#lines + 1] = "end"
    local got = {}
    scan_lines(lines, function(n, where, gi) got[#got + 1] = { n, where, gi } end)
    if not (#got == 1 and got[1][1] == 2 and got[1][2] == "w3" and got[1][3] == c[1]) then
      missed[#missed + 1] = ("%s (%s)"):format(c[2], #got == 0 and "not seen"
        or ("line %d as %s"):format(got[1][1], GROUPS[got[1][3]][1]))
    end
  end
  local neg = { "local function w3()" }
  vim.list_extend(neg, not_ways)
  neg[#neg + 1] = "end"
  scan_lines(neg, function(n) wrong[#wrong + 1] = vim.trim(neg[n]) end)
  chk("W3 the scan sees each form of a way out it is meant to see (called, through pcall, passed, stored, indexed, over two lines, the stderr channel, io.popen, os.execute, a spawn on fd 1 or 2, the device) and none of the checks that are not one",
    #missed == 0 and #wrong == 0, ("missed: %s; seen though not a way out: %s"):format(table.concat(missed, "; "),
      table.concat(wrong, "; ")))
end

vim.uv.guess_handle = real_guess_handle
ui_send_api = true; install()

vim.fn.delete(tmp, "rf")
if fails == 0 then
  io.write("\nALL STREAM-WRITER CHECKS PASSED\n")
  vim.cmd("qa!")
else
  io.write(("\nSTREAM-WRITER: %d CHECK(S) FAILED\n"):format(fails))
  vim.cmd("cquit 1")
end

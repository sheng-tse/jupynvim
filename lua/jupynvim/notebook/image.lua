-- Native Kitty graphics protocol, Unicode placeholder mode.
--
-- We do NOT depend on image.nvim. Implementation:
--   1. Encode the Kitty escape (`a=t f=100 i=ID` data, then an explicit
--      `a=p U=1 p=1` virtual placement) and write it to the terminal with
--      tty_write: nvim_ui_send when a terminal UI takes it (Neovim 0.12+),
--      in order with the screen; on Neovim 0.11 the editor's stderr. The
--      backend encodes and writes it itself only for a headless editor that
--      never had a terminal UI (the tests), or on Neovim 0.11 for one whose
--      stderr is not a terminal (see M.attach).
--   2. Build placeholder text using U+10EEEE + row diacritic + col diacritic.
--   3. Render the text via virt_lines extmarks. The foreground color of each
--      placeholder encodes the image_id (24-bit RGB).
--   4. Kitty/Ghostty replaces placeholders with the actual image at draw time.
--      This survives Neovim's redraws because placeholders ARE buffer text.
--
-- Reference: https://sw.kovidgoyal.net/kitty/graphics-protocol/#unicode-placeholders

local log = require("jupynvim.log")
local M = {}

-- The 297 row/column diacritics defined by the Kitty protocol, in protocol order
-- (the same list as Ghostty 1.3.1 src/terminal/kitty/graphics_unicode.zig;
-- tests/vkitty_spec.py place/diacritics_match_lua and tests/lua_e2e.lua check it).
local DIACRITICS = {
  0x0305,0x030D,0x030E,0x0310,0x0312,0x033D,0x033E,0x033F,0x0346,0x034A,
  0x034B,0x034C,0x0350,0x0351,0x0352,0x0357,0x035B,0x0363,0x0364,0x0365,
  0x0366,0x0367,0x0368,0x0369,0x036A,0x036B,0x036C,0x036D,0x036E,0x036F,
  0x0483,0x0484,0x0485,0x0486,0x0487,0x0592,0x0593,0x0594,0x0595,0x0597,
  0x0598,0x0599,0x059C,0x059D,0x059E,0x059F,0x05A0,0x05A1,0x05A8,0x05A9,
  0x05AB,0x05AC,0x05AF,0x05C4,0x0610,0x0611,0x0612,0x0613,0x0614,0x0615,
  0x0616,0x0617,0x0657,0x0658,0x0659,0x065A,0x065B,0x065D,0x065E,0x06D6,
  0x06D7,0x06D8,0x06D9,0x06DA,0x06DB,0x06DC,0x06DF,0x06E0,0x06E1,0x06E2,
  0x06E4,0x06E7,0x06E8,0x06EB,0x06EC,0x0730,0x0732,0x0733,0x0735,0x0736,
  0x073A,0x073D,0x073F,0x0740,0x0741,0x0743,0x0745,0x0747,0x0749,0x074A,
  0x07EB,0x07EC,0x07ED,0x07EE,0x07EF,0x07F0,0x07F1,0x07F3,0x0816,0x0817,
  0x0818,0x0819,0x081B,0x081C,0x081D,0x081E,0x081F,0x0820,0x0821,0x0822,
  0x0823,0x0825,0x0826,0x0827,
  0x0829,0x082A,0x082B,0x082C,0x082D,0x0951,0x0953,0x0954,0x0F82,0x0F83,
  0x0F86,0x0F87,0x135D,0x135E,0x135F,0x17DD,0x193A,0x1A17,0x1A75,0x1A76,
  0x1A77,0x1A78,0x1A79,0x1A7A,0x1A7B,0x1A7C,0x1B6B,0x1B6D,0x1B6E,0x1B6F,
  0x1B70,0x1B71,0x1B72,0x1B73,0x1CD0,0x1CD1,0x1CD2,0x1CDA,0x1CDB,0x1CE0,
  0x1DC0,0x1DC1,0x1DC3,0x1DC4,0x1DC5,0x1DC6,0x1DC7,0x1DC8,0x1DC9,0x1DCB,
  0x1DCC,0x1DD1,0x1DD2,0x1DD3,0x1DD4,0x1DD5,0x1DD6,0x1DD7,0x1DD8,0x1DD9,
  0x1DDA,0x1DDB,0x1DDC,0x1DDD,0x1DDE,0x1DDF,0x1DE0,0x1DE1,0x1DE2,0x1DE3,
  0x1DE4,0x1DE5,0x1DE6,0x1DFE,0x20D0,0x20D1,0x20D4,0x20D5,0x20D6,0x20D7,
  0x20DB,0x20DC,0x20E1,0x20E7,0x20E9,0x20F0,0x2CEF,0x2CF0,0x2CF1,0x2DE0,
  0x2DE1,0x2DE2,0x2DE3,0x2DE4,0x2DE5,0x2DE6,0x2DE7,0x2DE8,0x2DE9,0x2DEA,
  0x2DEB,0x2DEC,0x2DED,0x2DEE,0x2DEF,0x2DF0,0x2DF1,0x2DF2,0x2DF3,0x2DF4,
  0x2DF5,0x2DF6,0x2DF7,0x2DF8,0x2DF9,0x2DFA,0x2DFB,0x2DFC,0x2DFD,0x2DFE,
  0x2DFF,0xA66F,0xA67C,0xA67D,0xA6F0,0xA6F1,0xA8E0,0xA8E1,0xA8E2,0xA8E3,
  0xA8E4,0xA8E5,0xA8E6,0xA8E7,0xA8E8,0xA8E9,0xA8EA,0xA8EB,0xA8EC,0xA8ED,
  0xA8EE,0xA8EF,0xA8F0,0xA8F1,0xAAB0,0xAAB2,0xAAB3,0xAAB7,0xAAB8,0xAABE,
  0xAABF,0xAAC1,0xFE20,0xFE21,0xFE22,0xFE23,0xFE24,0xFE25,0xFE26,0x10A0F,
  0x10A38,0x1D185,0x1D186,0x1D187,0x1D188,0x1D189,0x1D1AA,0x1D1AB,0x1D1AC,
  0x1D1AD,0x1D242,0x1D243,0x1D244,
}

local PLACEHOLDER = 0x10EEEE  -- the special Kitty placeholder code point

local function utf8(cp)
  if cp < 0x80 then
    return string.char(cp)
  elseif cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + (cp % 0x40))
  elseif cp < 0x10000 then
    return string.char(
      0xE0 + math.floor(cp / 0x1000),
      0x80 + math.floor(cp / 0x40) % 0x40,
      0x80 + (cp % 0x40)
    )
  else
    return string.char(
      0xF0 + math.floor(cp / 0x40000),
      0x80 + math.floor(cp / 0x1000) % 0x40,
      0x80 + math.floor(cp / 0x40) % 0x40,
      0x80 + (cp % 0x40)
    )
  end
end

-- Build the placeholder text for one row of a `cols`-wide image at row index `row`.
-- Returns one chunk per column for a single virt_line (a chunk is { text, hl }).
local function build_row_chunks(image_id, row, cols, hl_group)
  local row_d = utf8(DIACRITICS[row + 1] or DIACRITICS[1])
  local cell = utf8(PLACEHOLDER) .. row_d
  local chunks = {}
  for c = 0, cols - 1 do
    local col_d = utf8(DIACRITICS[c + 1] or DIACRITICS[1])
    table.insert(chunks, { cell .. col_d, hl_group })
  end
  return chunks
end

-- Define a per-image highlight group with fg color encoding image_id.
-- Kitty uses the foreground color's 24-bit RGB to identify the image.
-- 0xRRGGBB where RR=high byte of (image_id >> 16) etc.
local function ensure_hl(image_id)
  local hl = "JupynvimImg_" .. image_id
  local r = bit.band(bit.rshift(image_id, 16), 0xff)
  local g = bit.band(bit.rshift(image_id, 8), 0xff)
  local b = bit.band(image_id, 0xff)
  -- Avoid pitch-black fg for low IDs: Kitty needs a non-zero color
  if r == 0 and g == 0 and b == 0 then b = 1 end
  vim.api.nvim_set_hl(0, hl, {
    fg = string.format("#%02x%02x%02x", r, g, b),
    -- ctermfg may be needed for non-truecolor terminals; we target Kitty/Ghostty
  })
  return hl
end

-- Build virt_lines for a placement of `rows` x `cols` cells.
-- Returns list-of-list-of-{text, hl} suitable for nvim_buf_set_extmark `virt_lines`.
function M.build_virt_lines(image_id, rows, cols)
  local hl = ensure_hl(image_id)
  local out = {}
  for r = 0, rows - 1 do
    table.insert(out, build_row_chunks(image_id, r, cols, hl))
  end
  return out
end

-- ---------- per-cell placement state ----------

-- cell_id -> { image_id, rows, cols, png_hash, src_hash, want }
local placements = {}
M._placements = placements

-- cell_id -> the src_hash of the value ensure_transmitted refused for it
-- (not base64, see M._b64_ok): asked again for the same value it answers at
-- once, without reading the value again
local refused = {}

-- Base64 as it arrives from a notebook can be a list of strings and can carry
-- whitespace: a trailing newline from older Jupyter stacks and Colab, or one
-- every 76 characters from base64.encodebytes. Every decoder downstream
-- rejects whitespace. The plain finds keep the common, clean case to a memchr
-- instead of a pattern scan over megabytes.
function M.clean_b64(v)
  if type(v) == "table" then v = table.concat(v, "") end
  if type(v) ~= "string" then return nil end
  if v:find("\n", 1, true) or v:find("\r", 1, true)
     or v:find(" ", 1, true) or v:find("\t", 1, true) then
    v = (v:gsub("%s+", ""))
  end
  return v
end

-- Image data from a notebook goes into a Kitty APC as it is. A byte outside
-- the base64 alphabet (an ESC above all; C1 controls, CAN and SUB too) can
-- end the APC early and hand what follows to the terminal, so
-- ensure_transmitted refuses such a value before anything is written.
-- libc's strspn reads the value in one call through LuaJIT's FFI (about
-- 0.4 ns a byte); a NUL stops it early, which refuses the value too.
-- Without the FFI a pattern makes the same check, slower.
local B64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/="
local b64_C
do
  local ok, ffi = pcall(require, "ffi")
  if ok then
    pcall(ffi.cdef, "size_t strspn(const char *s, const char *accept);")
    if pcall(function() return ffi.C.strspn("A", "A") end) then b64_C = ffi.C end
  end
end
M._b64_ffi = b64_C ~= nil   -- the spec turns the fast path off with false

-- True when every byte of s is in the base64 alphabet (A-Z a-z 0-9 + / =).
function M._b64_ok(s)
  if M._b64_ffi and b64_C then
    return tonumber(b64_C.strspn(s, B64_ALPHABET)) == #s
  end
  return not s:find("[^A-Za-z0-9+/=]")
end

local rpc_client = nil
function M.set_client(c) rpc_client = c end

-- A backend on another host never becomes the writer: it cannot reach this
-- terminal, and every notebook's images would stop with it. It is only told
-- not to write, without waiting for the answer. While no local backend is
-- attached and running, the escapes are encoded here (see no_writer).
function M.attach_remote(client)
  if client and client.call then
    client:call("kitty_attach", { remote = true }, function(err)
      if err then log.debug("kitty_attach(remote): " .. tostring(err)) end
    end)
  end
end

-- Hash a base64 string roughly so we can detect when image content changes.
local function quick_hash(s)
  if not s or s == "" then return 0 end
  local h = 5381
  local n = #s
  local step = math.max(1, math.floor(n / 64))
  for i = 1, n, step do
    h = (h * 33 + string.byte(s, i)) % 0x7FFFFFFF
  end
  return h * n
end

-- tty_write (below) writes raw bytes to the user's terminal, trying in order:
--   0) nvim_ui_send, when a terminal UI takes it (Neovim 0.12+), in order
--      with the UI's own output (see ui_send_target)
--   1) chansend(v:stderr): the editor's stderr is the terminal itself, so
--      these bytes reach it beside the UI's own output, not in order with it
--   2) io.stdout
--   3) the path `tty` reports (resolve_tty), when there is a controlling tty
--   4) /dev/tty via libuv
--   5) /dev/tty via Lua io
-- Since Neovim 0.10 the editor process has no controlling tty (ENXIO), so
-- without nvim_ui_send it is 1). Nothing is written at all while no
-- terminal shows the editor (see writes_held). A gif frame's status request
-- (method "pace", see frame_room) goes only through 0).
local _resolved_tty = nil
local function resolve_tty()
  if _resolved_tty ~= nil then return _resolved_tty end
  local out = vim.fn.system("tty 2>/dev/null"):gsub("%s+$", "")
  if out and out ~= "" and out ~= "not a tty" and not out:match("^tty:") then
    _resolved_tty = out
  else
    _resolved_tty = false
  end
  return _resolved_tty
end

-- tmux's `allow-passthrough on` only forwards escapes that arrive wrapped as
-- `ESC P tmux ; <body with internal ESCs doubled> ESC \`. Raw Kitty graphics
-- escapes get dropped silently otherwise. The Rust backend wraps its own TTY
-- writes (core/src/kitty.rs); per-frame GIF animation goes through THIS Lua
-- function, so it needs the same treatment or static images render but gifs
-- don't animate inside tmux.
local IN_TMUX = (vim.env.TMUX ~= nil and vim.env.TMUX ~= "")
  and not (vim.env.JUPYNVIM_DISABLE_TMUX_PASSTHROUGH ~= nil
           and vim.env.JUPYNVIM_DISABLE_TMUX_PASSTHROUGH ~= "")

local function tmux_wrap(s)
  local doubled = s:gsub("\27", "\27\27")
  return "\27Ptmux;" .. doubled .. "\27\\"
end

-- Since Neovim 0.10 the TUI is its own process. Bytes that the editor
-- process (chansend to v:stderr) or the backend (/dev/tty) write to the
-- terminal reach it on another path than the TUI's own output, and the tty
-- does not keep the two apart: a write can land INSIDE one of the TUI's
-- escape sequences, e.g. between "ESC[38:2:59:" and "66:97m" of a LineNr
-- color. The terminal then drops the TUI's sequence, prints its tail as text
-- and leaves the cursor where the TUI does not expect it, so the rows drawn
-- after it (the box borders) land in the wrong cells until the screen is
-- cleared and redrawn. nvim_ui_send (0.12+) hands the bytes to the TUI,
-- which writes them between its own sequences.
--
-- terminal_ui(): a UI with a terminal that the writes reach is attached:
-- one with stdout_tty, or, without nvim_ui_send (Neovim 0.11), a terminal
-- attached with nvim --remote-ui that runs where the writes go (see
-- tui_here). Cached until a UI attaches or leaves (UIEnter, UILeave
-- below); vim.api is looked up on every call, never kept in a local.
-- ui_send_target(): that, and nvim_ui_send exists.
--
-- Neovim 0.11 lists a --remote-ui terminal with its term_name but without
-- stdout_tty (0.12 lists it), and with no nvim_ui_send the writes go to the
-- terminal the editor was started in: its stderr, or, when that is not a
-- terminal, its controlling terminal (through the backend). They reach that
-- UI when it runs there (the way back after a :detach in that terminal);
-- from another terminal they would land where another program draws (the
-- shell left in the first one), so that UI shows no images. Which one it is
-- is asked of the system once per UI (M._pid_in_my_terminal, with the
-- client's pid from its channel's client info); until the answer comes the
-- UI counts as elsewhere, and a yes is handled as the UI attaching. The
-- client describes itself (nvim_set_client_info, which carries the pid)
-- only after it attached, so a UI with no pid yet is asked about again on
-- its ChanInfo (below).
local ui_tty_cache = nil
M._had_ui = false  -- a terminal UI has been attached at some point
local tui_here = {}  -- UI channel -> true, false, or "asking"
local function ask_tui_here(chan)
  local ok, info = pcall(vim.api.nvim_get_chan_info, chan)
  local attrs = ok and type(info) == "table" and type(info.client) == "table" and info.client.attributes
  local pid = type(attrs) == "table" and tonumber(attrs.pid)
  if not pid then return end
  tui_here[chan] = "asking"
  M._pid_in_my_terminal(pid, function(here)
    tui_here[chan] = here == true
    if here == true then M._ui_changed("enter") end
  end)
end
local function terminal_ui()
  if ui_tty_cache ~= nil then return ui_tty_cache end
  local ok, uis = pcall(vim.api.nvim_list_uis)  -- errors in a fast (luv) callback
  if not ok then return false end
  local via_stderr = not vim.api.nvim_ui_send
  ui_tty_cache = false
  for _, ui in ipairs(uis) do
    if ui.stdout_tty then
      ui_tty_cache = true
    elseif via_stderr and type(ui.term_name) == "string" and ui.term_name ~= "" and ui.chan then
      M._had_ui = true
      if tui_here[ui.chan] == nil then ask_tui_here(ui.chan) end
      if tui_here[ui.chan] == true then ui_tty_cache = true end
    end
  end
  if ui_tty_cache then M._had_ui = true end
  return ui_tty_cache
end

-- Does process `pid` run in the terminal the writes reach (the same device
-- is its controlling terminal), and is it a --remote-ui client? Without
-- nvim_ui_send the writes reach the editor's stderr when that is a terminal
-- (tty_write); when it is not (nvim --headless started with stderr on a
-- file), the backend writes them to the editor's controlling terminal
-- (local mode, see M.attach), so that one is compared. cb(true or false) on
-- the main loop. ps answers in a few ms (it is stopped after 3 s). No ps, a
-- process that is gone or one elsewhere (another terminal, another
-- machine), no terminal to compare with: false.
function M._pid_in_my_terminal(pid, cb)
  local function answer(v) vim.schedule(function() cb(v) end) end
  local err = vim.uv.guess_handle(2) == "tty" and vim.uv.fs_fstat(2)
  local me = vim.fn.getpid()
  local ok = pcall(vim.system, { "ps", "-o", "pid=", "-o", "tty=", "-o", "args=", "-p", pid .. "," .. me },
    { text = true, timeout = 3000 }, function(r)
      local tty_of, args_of = {}, {}
      for line in (r.stdout or ""):gmatch("[^\n]+") do
        local p, tty, args = line:match("^%s*(%d+)%s+(%S+)%s*(.-)%s*$")
        if p then tty_of[tonumber(p)], args_of[tonumber(p)] = tty, args end
      end
      local function dev(tty)
        local st = tty and vim.uv.fs_stat("/dev/" .. tty)
        return st and st.rdev or nil
      end
      local target = err and err.rdev or dev(tty_of[me])
      if not target then answer(false); return end
      local client = (args_of[pid] or ""):find("--remote-ui", 1, true) and dev(tty_of[pid])
      answer(client == target)
    end)
  if not ok then answer(false) end
end
local function ui_send_target()
  if not vim.api.nvim_ui_send then return false end
  return terminal_ui()
end
M._ui_send_target = ui_send_target
-- Do tty_write's writes reach a terminal? With nvim_ui_send they go to the
-- terminal UIs. Without it they go to the editor's stderr, a terminal for
-- every TUI editor but not for nvim --headless started with stderr on a
-- file; there only the backend's local mode, which writes to the editor's
-- controlling terminal, reaches one (M.attach).
local function lua_writes_reach_terminal()
  return vim.api.nvim_ui_send ~= nil or vim.uv.guess_handle(2) == "tty"
end

-- Nothing is written while no terminal shows the editor: it is suspended
-- (CTRL-Z), or a terminal UI was attached and none that the writes reach is
-- now (:detach, a --remote-ui client that left, on Neovim 0.11 one in
-- another terminal; see terminal_ui). On the fallback path such a write would go
-- into a terminal that another program draws on by then (the shell the user
-- went back to), out of order with it. Each held write is counted, and what
-- it carried is noted (note_held) and sent again once a terminal shows the
-- editor (replay_held). The same holds for what the backend is asked to
-- write in its local mode (backend_held). A headless editor that never had
-- a terminal UI (the tests) is not held. Once the editor is quitting
-- (VimLeavePre) nothing more is written either.
M._suspended = false
M._leaving = false
local function writes_held()
  -- terminal_ui() first: it is what records that a terminal UI is attached
  -- (M._had_ui) when this module loaded after the UI did (a lazy-loaded
  -- plugin sees no UIEnter), and on Neovim 0.11 nothing else asks it
  local tty = terminal_ui()
  return M._suspended or M._leaving or (M._had_ui and not tty)
end
M._writes_held = writes_held
-- Asked now, when the module loads, for two reasons. A terminal UI can be
-- attached before this module is first loaded (a plugin loaded lazily sees
-- no UIEnter): terminal_ui() records it, or nothing may ask for the UI
-- before a :detach (on Neovim 0.11 nothing does; on 0.12 only the backend
-- attaching or a write does), and the writes after it would not be held.
-- And the writes can be held from the start (on Neovim 0.11 a --remote-ui
-- terminal whose answer has not come yet): M._ui_changed sends what was
-- held only on a change from held to not held, so it must know.
local was_held = writes_held()

local function no_held()
  return { all = false, visible = false, deletes = {}, images = {}, places = {} }
end
local held = no_held()
local function note_held(method, a)
  a = a or {}
  if method == "kitty_clear_all" then
    held = no_held()
    held.all = true
  elseif method == "kitty_clear_visible" then
    held.visible = true
  elseif method == "kitty_clear_image" and a.image_id and not a.placement_id then
    -- an image the terminal never got needs no delete
    if held.images[a.image_id] then held.images[a.image_id] = nil
    else held.deletes[a.image_id] = true end
  elseif (method == "kitty_transmit_virtual" or method == "kitty_transmit_only") and a.image_id then
    held.images[a.image_id] = true
  elseif method == "kitty_place" and a.image_id then
    -- a direct placement (the kitty renderer) is made once, at a screen
    -- position: keep the newest one asked for, to send as it was
    held.places[a.image_id] = a
  end
  -- held virtual placements need nothing here: a terminal UI attaching
  -- invalidates every placement (M._ui_changed)
end

-- A write made from a fast event (a luv callback) waits for the main loop,
-- which nvim_ui_send and nvim_list_uis need, and so does every write after
-- it until that queue has been written: the order is kept.
local queued = nil
local ack_note_sent  -- a gif frame's status request went out (see frame_room)
local function tty_write(s, method, args)
  if queued or vim.in_fast_event() then
    if not queued then
      queued = {}
      vim.schedule(function()
        local q = queued
        queued = nil
        for _, w in ipairs(q) do tty_write(w[1], w[2], w[3]) end
      end)
    end
    queued[#queued + 1] = { s, method, args }
    return true
  end
  if writes_held() then
    M._held_n = (M._held_n or 0) + 1
    M._held_bytes = (M._held_bytes or 0) + #s
    note_held(method, args)
    return false
  end
  if method == "pace" then
    -- a gif frame's status request: through the UI only, as it is (tmux
    -- answers it itself once it has read what came before, so it is not
    -- wrapped for the terminal outside), and on no other path: its answer
    -- would go to whatever reads the terminal then
    if not ui_send_target() or not pcall(vim.api.nvim_ui_send, s) then return false end
    M._tty_n = (M._tty_n or 0) + 1
    M._tty_bytes = (M._tty_bytes or 0) + #s
    M._ui_send_n = (M._ui_send_n or 0) + 1
    M._ui_send_bytes = (M._ui_send_bytes or 0) + #s
    ack_note_sent(args and args.bytes or 0)
    return true
  end
  -- counted as written, after the wrap for tmux (as the nvim_ui_send line)
  if IN_TMUX then s = tmux_wrap(s) end
  M._tty_n = (M._tty_n or 0) + 1
  M._tty_bytes = (M._tty_bytes or 0) + #s
  local uv = vim.uv

  -- 0) through the TUI, in order with its own output (see ui_send_target)
  if ui_send_target() then
    local ok, err = pcall(vim.api.nvim_ui_send, s)
    if ok then
      M._ui_send_n = (M._ui_send_n or 0) + 1
      M._ui_send_bytes = (M._ui_send_bytes or 0) + #s
      return true
    end
    log.warn("nvim_ui_send failed: " .. tostring(err))
  end

  -- 1) chansend(vim.v.stderr, ...): vim.v.stderr is a channel ID that always
  -- points at nvim's stderr stream, which is the user's terminal for an
  -- editor started in one. APC graphics escapes pass through unmodified.
  -- Works regardless of /dev/tty access, but beside the UI's own output,
  -- not in order with it (see terminal_ui).
  if vim.v.stderr and vim.v.stderr ~= 0 then
    local ok, ret = pcall(vim.api.nvim_chan_send, vim.v.stderr, s)
    if ok then
      log.debug(string.format("tty_write chansend(stderr=%d) %d bytes ok", vim.v.stderr, #s))
      return true
    else
      log.warn("chansend stderr failed: " .. tostring(ret))
    end
  end

  -- 2) io.stdout (works for some nvim launches)
  local ok = pcall(function() io.stdout:write(s); io.stdout:flush() end)
  if ok then
    log.debug(string.format("tty_write stdout %d bytes ok", #s))
    return true
  end

  -- 3) tty(1)-resolved path (interactive nvim with controlling tty)
  local tty = resolve_tty()
  if tty then
    local fd = uv.fs_open(tty, "w", 420)
    if fd then
      local _, werr = uv.fs_write(fd, s, -1)
      uv.fs_close(fd)
      if not werr then
        log.debug(string.format("tty_write resolved=%s %d bytes ok", tty, #s))
        return true
      end
    end
  end

  -- 4) /dev/tty via libuv
  local fd = uv.fs_open("/dev/tty", "w", 420)
  if fd then
    local _, werr2 = uv.fs_write(fd, s, -1)
    uv.fs_close(fd)
    if not werr2 then
      log.debug(string.format("tty_write libuv-tty %d bytes ok", #s))
      return true
    end
  end

  -- 5) Lua io /dev/tty
  local f = io.open("/dev/tty", "wb")
  if f then
    local ok2 = pcall(function() f:write(s); f:close() end)
    if ok2 then
      log.debug(string.format("tty_write io-tty %d bytes ok", #s))
      return true
    end
  end

  log.error(string.format("ALL tty_write methods failed for %d bytes", #s))
  return false
end

-- ── Kitty escapes encoded here (M._remote_mode) ──
--
-- Once a terminal UI has been attached (when tty_write's writes reach a
-- terminal), whenever the backend cannot open a tty (since Neovim 0.10 it
-- cannot open /dev/tty: the editor process it runs under has no controlling
-- terminal), and while no local backend runs (no_writer), the escapes are
-- encoded here and written by tty_write. The PNG already lives here (it
-- arrived in the cell-output notification), so no image bytes go back to the
-- backend, which over SSH would cross the link twice more. These encoders
-- mirror core/src/kitty.rs byte for byte. Only a headless nvim with a tty
-- leaves encoding and writing to the backend (kitty_attach with a tty, LOCAL
-- mode): one that never had a terminal UI (the tests), or on Neovim 0.11 one
-- whose stderr is not a terminal.
M._remote_mode = false

local KITTY_CHUNK = 4096

local function enc_transmit(first_header, b64)
  local out, pos, total, first = {}, 1, #b64, true
  while pos <= total do
    local stop = math.min(pos + KITTY_CHUNK - 1, total)
    local chunk = b64:sub(pos, stop)
    local more = (stop < total) and 1 or 0
    if first then
      table.insert(out, string.format(first_header, more, chunk))
      first = false
    else
      table.insert(out, string.format("\x1b_Gm=%d,q=2;%s\x1b\\", more, chunk))
    end
    pos = stop + 1
  end
  return table.concat(out)
end

-- Build the local kitty escape for a method+args (matches backend semantics).
local function encode_local(method, a)
  if method == "kitty_transmit_only" then
    return enc_transmit("\x1b_Ga=t,f=100,i=" .. a.image_id .. ",q=2,m=%d;%s\x1b\\", a.png_b64)
  elseif method == "kitty_transmit_virtual" then
    -- a=t data + explicit virtual placement (p=1). NOT a=T: displays
    -- without a placement id get internal ids that ACCUMULATE one per
    -- transmit (ghost/double rendering); an external p=1 is replaced in
    -- place, so per-frame retransmits keep exactly one placement.
    return enc_transmit("\x1b_Ga=t,f=100,i=" .. a.image_id .. ",q=2,m=%d;%s\x1b\\", a.png_b64)
      .. string.format("\x1b_Ga=p,U=1,i=%d,p=1,c=%d,r=%d,q=2\x1b\\",
        a.image_id, a.cols, a.rows)
  elseif method == "kitty_place_virtual" then
    -- placement-only re-assert: drop ALL of the image's placements
    -- (lowercase d=i keeps the data), then create the single external one
    return string.format(
      "\x1b_Ga=d,d=i,i=%d,q=2\x1b\\\x1b_Ga=p,U=1,i=%d,p=1,c=%d,r=%d,q=2\x1b\\",
      a.image_id, a.image_id, a.cols, a.rows)
  elseif method == "kitty_place" then
    if a.screen_row and a.screen_col then
      return string.format("\x1b[s\x1b[%d;%dH\x1b_Ga=p,i=%d,p=%d,c=%d,r=%d,q=2\x1b\\\x1b[u",
        a.screen_row, a.screen_col, a.image_id, a.placement_id, a.cols, a.rows)
    end
    return string.format("\x1b_Ga=p,i=%d,p=%d,c=%d,r=%d,q=2\x1b\\",
      a.image_id, a.placement_id, a.cols, a.rows)
  elseif method == "kitty_clear_image" then
    if a.placement_id then
      return string.format("\x1b_Ga=d,d=I,i=%d,p=%d,q=2\x1b\\", a.image_id, a.placement_id)
    end
    return string.format("\x1b_Ga=d,d=I,i=%d,q=2\x1b\\", a.image_id)
  elseif method == "kitty_clear_visible" then
    return "\x1b_Ga=d,d=a,q=2\x1b\\"
  elseif method == "kitty_clear_all" then
    return "\x1b_Ga=d,d=A,q=2\x1b\\"
  end
  return nil
end

-- No backend that writes to this terminal is attached and running: none has
-- attached yet (the first open of a session clears the placements a file
-- explorer's preview left before its backend starts), or the attached one
-- exited (a remote notebook's plots must keep showing). The escapes are then
-- encoded here, as in remote mode, instead of being dropped.
local function no_writer()
  return not (rpc_client and rpc_client.job)
end

-- Whether the escapes are encoded here and written by tty_write. Whatever
-- depends on who writes asks this, not M._remote_mode: a session with only
-- remote notebooks never runs M.attach, so M._remote_mode alone would call
-- its frames the backend's and send them without waiting for the terminal.
local function lua_encodes()
  return M._remote_mode or no_writer()
end

-- In LOCAL mode the backend writes to the terminal itself, so the hold
-- (writes_held) applies to what it is asked to write, as in tty_write: the
-- call is not made, it is counted, and what it carried is noted and sent
-- again (replay_held).
local function backend_held(method, args)
  if not writes_held() then return false end
  M._held_n = (M._held_n or 0) + 1
  M._held_bytes = (M._held_bytes or 0) + (args and type(args.png_b64) == "string" and #args.png_b64 or 0)
  note_held(method, args)
  return true
end

-- RPC dispatch to the backend's kitty handlers (LOCAL mode), or encode here
-- and tty_write (lua_encodes). Synchronous shape: returns res, or nil and the
-- error.
local function kitty_call_sync(method, args, timeout)
  if lua_encodes() then
    local esc = encode_local(method, args or {})
    if esc then tty_write(esc, method, args) end
    return { image_id = args and args.image_id }  -- mimic backend response shape
  end
  if backend_held(method, args) then return { image_id = args and args.image_id } end
  local err, res = rpc_client:call_sync(method, args or {}, timeout or 5000)
  if err then return nil, err end
  if res and res.escape_b64 then
    local ok, decoded = pcall(vim.base64.decode, res.escape_b64)
    if ok and decoded then tty_write(decoded) end
  end
  return res
end

-- Fire-and-forget variant for deletes / gif frames (no need to block).
local function kitty_call_async(method, args)
  if lua_encodes() then
    local esc = encode_local(method, args or {})
    if esc then tty_write(esc, method, args) end
    return
  end
  if backend_held(method, args) then return end
  rpc_client:call(method, args or {}, function(err, res)
    if err then log.warn(method .. " error: " .. tostring(err)); return end
    if res and res.escape_b64 then
      local ok, decoded = pcall(vim.base64.decode, res.escape_b64)
      if ok and decoded then
        vim.schedule(function() tty_write(decoded) end)
      end
    end
  end)
end

-- Image ids double as the placeholder cell's FOREGROUND color (Kitty's Unicode
-- placeholder protocol encodes the id in the cell's fg). Any cell the image
-- fails to cover (Kitty's mapping breaks when the window narrows/wraps on a
-- layout toggle) falls back to the font rendering U+10EEEE in that fg. With the
-- old base (id 1000 -> #0003E8) those gaps flashed BRIGHT BLUE. Derive ids from
-- the editor BACKGROUND instead, nudging each channel a little for uniqueness
-- but staying dark, so an uncovered cell blends into the background. Override
-- the base with setup({ image_placeholder_bg = "#rrggbb" }) when the theme is
-- transparent and the fallback doesn't match the terminal background.
local NEXT_N = 0
local function next_image_id()
  local ok, cfg = pcall(function() return require("jupynvim").config end)
  local bg
  if ok and cfg and type(cfg.image_placeholder_bg) == "string" then
    bg = tonumber((cfg.image_placeholder_bg:gsub("#", "")), 16)
  end
  if not bg then
    local nrm = vim.api.nvim_get_hl(0, { name = "Normal" })
    bg = (type(nrm.bg) == "number") and (nrm.bg % 0x1000000) or 0x16161e
  end
  local n = NEXT_N
  NEXT_N = NEXT_N + 1
  -- spread n across the three channels, each +0..23, so ids stay near the bg
  local off = (n % 24) + (math.floor(n / 24) % 24) * 0x100 + (math.floor(n / 576) % 24) * 0x10000
  local id = (bg + off) % 0x1000000
  if id == 0 then id = 0x010101 end  -- never #000000 (Kitty reads it as "default")
  return id
end

-- Generate ASCII art via chafa for the PNG and CACHE it per cell hash.
-- ASCII art is rendered as virt_lines in the buffer; it scrolls naturally
-- with the cell, never moves independently. Fixed size = chafa's --size arg.
local CHAFA_ROWS, CHAFA_COLS = 32, 100

local function ascii_art_for(b64, callback)
  local tmp_png = vim.fn.tempname() .. ".png"
  -- Decode base64 to png
  local raw = nil
  local ok, decoded = pcall(vim.base64.decode, b64)
  if ok then raw = decoded end
  if not raw then callback(nil); return end
  local f = io.open(tmp_png, "wb")
  if not f then callback(nil); return end
  f:write(raw); f:close()
  -- Block symbols + 16-color mode produces the densest, most recognizable
  -- ASCII rendering of a plot. We strip ANSI in post-processing.
  -- --animate=off is critical: without it, chafa animates GIFs by emitting
  -- many frames separated by clear-screen sequences, blowing up the line
  -- count from ~32 to thousands.
  local cmd = string.format(
    "chafa --format symbols --symbols block --animate=off --size %dx%d --colors=16 %s 2>/dev/null",
    CHAFA_COLS, CHAFA_ROWS, vim.fn.shellescape(tmp_png))
  local result = vim.fn.system(cmd)
  pcall(os.remove, tmp_png)
  if vim.v.shell_error ~= 0 or result == "" then callback(nil); return end
  -- Strip all escape sequences: SGR, cursor show/hide, mode set/reset.
  result = result:gsub("\27%[[?]?[%d;]*[a-zA-Z]", "")
  result = result:gsub("\27%][^\27]*\27\\", "")
  result = result:gsub("\27.", "")
  local lines = {}
  for line in (result .. "\n"):gmatch("([^\n]*)\n") do
    if line ~= "" then table.insert(lines, line) end
  end
  callback(lines)
end

-- Image grid size for Unicode-placeholder rendering (rows × cols of terminal cells).
-- Larger = higher resolution = clearer image; bounded by typical terminal size.
-- Mutable so init.lua's setup can override from user config without a
-- circular require. See `require("jupynvim").setup({ image_rows, image_cols })`.
local PLACEHOLDER_ROWS, PLACEHOLDER_COLS = 16, 48

function M.set_size(opts)
  opts = opts or {}
  if type(opts.rows) == "number" and opts.rows > 0 then PLACEHOLDER_ROWS = opts.rows end
  if type(opts.cols) == "number" and opts.cols > 0 then PLACEHOLDER_COLS = opts.cols end
end

-- Extract every frame of an animated GIF as PNG along with per-frame delays.
-- Returns { frames = { b64, b64, ... }, delays = { ms, ms, ... } } or nil.
-- Used to drive timer-based animation since Ghostty 1.3 doesn't implement
-- the kitty animation protocol (a=f / a=a / a=c return "unimplemented action").
-- We re-transmit each frame with the same image_id; Ghostty replaces the
-- image on retransmit and the placeholders on screen refresh automatically.
-- Asynchronously decompose an animated GIF into a sequence of PNG frames
-- plus per-frame delays. Calls callback({ frames = ..., delays = ... })
-- on success or callback(nil) on failure. Uses vim.system so the editor
-- doesn't block on the multi-frame extraction (~1.9s for a 189-frame gif).
local MAX_ANIM_FRAMES = 500
local function extract_gif_frames_async(b64, callback)
  local raw_ok, raw = pcall(vim.base64.decode, b64)
  if not raw_ok or not raw then callback(nil); return end
  local in_path = vim.fn.tempname() .. ".gif"
  local f = io.open(in_path, "wb")
  if not f then callback(nil); return end
  f:write(raw); f:close()
  local in_q = vim.fn.shellescape(in_path)

  -- frame count and delays are tiny `identify` calls. fine to run sync.
  local fc_str = vim.fn.system(string.format(
    "magick identify -format '%%n ' %s 2>/dev/null", in_q))
  local frame_count = tonumber(fc_str:match("^%s*(%d+)")) or 1
  if frame_count <= 1 then
    pcall(os.remove, in_path)
    callback(nil); return
  end

  local delays_str = vim.fn.system(string.format(
    "magick identify -format '%%T\\n' %s 2>/dev/null", in_q))
  local delays = {}
  for d in delays_str:gmatch("(%d+)") do
    local ms = tonumber(d) * 10
    -- gif T is in centiseconds. T=0 means "as fast as possible" which
    -- browsers and VSCode interpret as ~100ms. apply the same default.
    if ms < 20 then ms = 100 end
    table.insert(delays, ms)
  end

  -- Frame extraction is the slow part. -coalesce flattens disposal so each
  -- frame is the full composited picture, not a delta from the previous.
  local out_pattern = vim.fn.tempname()
  local out_glob = out_pattern .. "_%04d.png"
  vim.system(
    { "sh", "-c", string.format("magick %s -coalesce %s 2>/dev/null",
        in_q, vim.fn.shellescape(out_glob)) },
    { text = false },
    vim.schedule_wrap(function()
      pcall(os.remove, in_path)
      local frames = {}
      for i = 0, math.min(frame_count, MAX_ANIM_FRAMES) - 1 do
        local p = string.format("%s_%04d.png", out_pattern, i)
        if vim.fn.filereadable(p) ~= 1 then break end
        local pf = io.open(p, "rb")
        local png_bytes = pf:read("*a")
        pf:close()
        pcall(os.remove, p)
        table.insert(frames, vim.base64.encode(png_bytes))
      end
      for i = MAX_ANIM_FRAMES, frame_count - 1 do
        pcall(os.remove, string.format("%s_%04d.png", out_pattern, i))
      end
      if #frames < 2 then callback(nil); return end
      local total = 0
      for _, d in ipairs(delays) do total = total + d end
      log.info(string.format("extract_gif_frames_async: %d frames, %dms loop",
        #frames, total))
      callback({ frames = frames, delays = delays })
    end))
end

-- Convert non-PNG image bytes to PNG via ImageMagick. Returns the PNG b64
-- on success, nil on failure. Callers must handle nil (typically by falling
-- back to a renderer that can read the source format directly, like chafa).
local _warned_missing_magick = false
local function ensure_png(b64, mime, callback)
  if mime == nil or mime == "image/png" or mime == "" then
    callback(b64); return
  end
  if vim.fn.executable("magick") ~= 1 and vim.fn.executable("convert") ~= 1 then
    log.warn("ensure_png: ImageMagick not found, cannot convert " .. tostring(mime))
    if not _warned_missing_magick then
      _warned_missing_magick = true
      vim.schedule(function()
        vim.notify(
          "jupynvim: ImageMagick not found. Non-PNG images (gif, jpg, svg) will fall back to chafa ascii. Install with `brew install imagemagick` for native PNG rendering.",
          vim.log.levels.WARN)
      end)
    end
    callback(nil); return
  end
  local raw_ok, raw = pcall(vim.base64.decode, b64)
  if not raw_ok or not raw then callback(nil); return end
  local in_path = vim.fn.tempname()
  local out_path = vim.fn.tempname() .. ".png"
  local f = io.open(in_path, "wb")
  if not f then callback(nil); return end
  f:write(raw); f:close()
  -- ImageMagick's "[0]" first-frame selector must live INSIDE the shell
  -- quotes. shellescape(in_path) wraps with single quotes, leaving "[0]"
  -- outside the quotes where zsh tries to glob it and aborts the command.
  local frame0 = vim.fn.shellescape(in_path .. "[0]")
  local out_q = vim.fn.shellescape(out_path)
  local cmd = string.format(
    "magick %s %s 2>/dev/null || convert %s %s 2>/dev/null",
    frame0, out_q, frame0, out_q)
  vim.fn.system(cmd)
  pcall(os.remove, in_path)
  if vim.v.shell_error ~= 0 or vim.fn.filereadable(out_path) ~= 1 then
    pcall(os.remove, out_path)
    log.warn("ensure_png: conversion failed for " .. tostring(mime))
    callback(nil); return
  end
  local pf = io.open(out_path, "rb")
  if not pf then pcall(os.remove, out_path); callback(nil); return end
  local png_bytes = pf:read("*a")
  pf:close()
  pcall(os.remove, out_path)
  callback(vim.base64.encode(png_bytes))
end

-- key -> function returning false while that output's rows are off screen
-- (render.lua registers one per image output). An animation keeps its clock
-- but sends no frames while nobody can see it: a gif scrolled away used to
-- push every frame to the terminal (hundreds of KB/s), each write one more
-- chance to land inside the TUI's output.
local visible_probe = {}
function M.set_visible_probe(key, fn) visible_probe[key] = fn end
function M.has_visible_probe(key) return visible_probe[key] ~= nil end

local function on_screen(key)
  local probe = visible_probe[key]
  if not probe then return true end
  local ok, v = pcall(probe)
  return not ok or v ~= false
end
M._on_screen = on_screen

-- ── gif frames wait for the terminal (nvim_ui_send only) ──
--
-- nvim_ui_send never blocks: what the terminal has not read yet waits in
-- the editor's queue to the UI, and the UI's screen updates wait behind it.
-- A gif whose frames outrun the terminal (a slow link, a busy terminal, a
-- large animation) grew that queue without bound: the editor's memory
-- climbed by megabytes a second and the screen stopped following the
-- keyboard. (chansend to stderr blocks, which held the frame timer back.)
-- So every frame sent with nvim_ui_send is followed by a status request,
-- DSR (ESC [ 5 n), which the terminal answers (ESC [ 0 n) once it has read
-- everything before it; the answer comes back as a TermResponse. Inside
-- tmux, tmux answers it, so the frames follow what the pane has read.
--
-- DSR, not DA1 (ESC [ c): when Neovim 0.12's UI stops (quit, CTRL-Z,
-- :detach) it sends a DA1 request of its own and reads the terminal until
-- the first DA1 answer comes, and that one would be a frame's answer still
-- on its way: the UI would stop reading too early and its own answer would
-- reach the shell. (Its startup queries and the runtime's OSC 52 check use
-- DA1 the same way.) A DSR answer the UI reads and passes on as a
-- TermResponse. But a status answer tells nothing of whose request it
-- answers, and Neovim asks DSR itself too: its UI and its runtime end their
-- background color queries (OSC 11 then DSR, in one write) with it when the
-- editor starts, when a UI attaches or resumes, and when the terminal's
-- theme changes; other programs may ask too. Taken for a frame's, such an
-- answer frees a frame early and ends a drain one answer too soon. Over a
-- slow link the UI reads its input only between its writes, so the
-- answers to its start queries can come seconds late, after frames went
-- out, and in one piece with a frame's own answer.
--
-- So the books are settled with a marker: an XTVERSION request (ESC [ > q),
-- which every terminal jupynvim supports answers (ESC P > | name ESC \),
-- tmux too, in order with everything else, and which Neovim does not ask.
-- After every reset of the books (the module loading, a UI attaching or
-- leaving, a suspend, a resume) the next frame first sends a marker, and no
-- frame goes until every terminal UI has answered it: every answer to a
-- request written before it, the editor's own start answers included, has
-- come by then. While a marker is on its way a status answer pays nothing,
-- and the marker's last answer pays every request still counted (all were
-- sent before it). An OSC 11 answer while frame requests wait sends a
-- marker too (a status answer of a background query may follow, or a
-- frame's after another program's lone OSC 11), and a drain before the UI
-- stops asks with a marker. A marker not answered within the lost limit
-- (below) is given up; if no marker was ever answered (a terminal that
-- does not answer XTVERSION), markers stay off, and status answers are taken
-- as they come, until an XTVERSION answer comes after all: it shows that the
-- terminal answers and was only slow (the first answer after a start can
-- take longer than the lost limit over a slow link, which reads its input
-- late), so markers are on again and the next frame settles the books.
-- tmux before 3.2 (3.0a and 3.1c were checked in containers) answers status
-- requests but not XTVERSION: inside such a tmux (M._tmux_version, from the
-- running tmux's version) the first marker is not waited for, markers start
-- off, and the late-answer rule above puts a wrong guess right. A status
-- answer behind the marker cannot tell the other terminals that do not answer
-- it: Neovim's own start answers, late over a slow link, come before the
-- marker's and look the same, so they wait for the lost limit.
--
-- Another module that writes a question to the terminal and ends it with a
-- status request of its own (the palette's background question) asks
-- M.status_fence() first, so that it can tell the frames' status answers,
-- which come before its own, from its own.
--
-- A frame goes out only while the frames not read yet stay within
-- M._frame_window bytes (one frame is always let through); a frame the
-- terminal has no room for is skipped (M._frames_held) and the gif's clock
-- runs on. So once the terminal answers, the queue stays within the window
-- plus one frame, and a gif plays at most M._frame_window bytes (or one
-- frame) per round trip.
--
-- Every terminal UI gets each request and answers it, and the answers tell
-- nothing of who sent them. With U terminal UIs, R requests sent and A
-- answers, the slowest UI has answered at least A - (U - 1) * R requests,
-- so that many frames count as read: the slowest terminal paces the gif and
-- no queue grows behind it.
--
-- Where markers are off, until the terminal has answered once (since the
-- last UI change), the requests in flight are given up, all of them once,
-- when the oldest has gone unanswered for M._ack_timeout_ms, and one more
-- frame goes, so a terminal that does not answer plays the gif instead of
-- stopping it. (Where markers are on, a marker's answer is the terminal's
-- first answer, and no frame goes before it.) They stay in the list: a late
-- answer is theirs and frees nothing newer. This is done once, not at every
-- timeout: a terminal that has not answered yet may just be slow (the first
-- frames behind a slow link need seconds, and Neovim's UI reads its input
-- only between its writes), and a frame sent every timeout into it would pile
-- up before its first answer and keep that answer from being read. So before
-- the first answer at most two windows of frames are on their way (the
-- frames not read yet stay within M._frame_window until the requests are
-- given up, and within it again after), or two frames when a frame is larger
-- than the window; a terminal that never answers gets the next ones when
-- M._ack_lost_ms has passed. Once the terminal has answered, a slow answer is
-- waited for, since giving up then would only pile frames into a terminal
-- that is still reading. Only when no answer at all has come for
-- M._ack_lost_ms (or four times the longest wait for one so far, at most four
-- times M._ack_lost_ms) while requests wait are they all dropped: an answer
-- lost on its way would otherwise keep the window shut. A UI attaching or
-- leaving, a suspend and a resume start over, as the answers in flight may
-- never come; a marker still in flight at an attach or a leave keeps owing the
-- answers of the UIs that stay (mark_carry).
--
-- One window serves every gif. A gif that finds no room is skipped and
-- waits (p.stale_at); the room an answer frees goes to the gif that has
-- waited longest, not to whichever ticks first, so a slow gif (a frame a
-- second) is not starved by a fast one.
M._frame_window = 64 * 1024
M._ack_timeout_ms = 3000
M._ack_lost_ms = 30000
local DSR = "\27[5n"
local MARK = "\27[>q"
-- the requests not yet read by every terminal UI, oldest first:
-- { frame bytes, sent at }; the first ack_given of them no longer count
local acks, ack_bytes, ack_given
-- since the last reset: requests sent, answers got, requests read by every
-- terminal UI, terminal UIs; whether one was read, when the last one was,
-- the longest wait for one
local ack_sent, ack_got, ack_paid, ack_uis
local ack_answered, ack_last, ack_quiet
-- a drain is waiting for the answers (drain_acks): no frame goes meanwhile,
-- also when another terminal UI still takes writes
local draining = false
-- the marker (see above): mark_due answers still to come for the one sent
-- at mark_at, or (mark_wanted) one to send before the next frame;
-- M._mark_seen once any marker was answered, M._mark_off once one was
-- given up with none ever answered (any later marker answer turns them on
-- again: it is the terminal's, only slow); in_send while send_frame sends
-- one. mark_seq counts the markers sent and mark_closed those over
-- (answered by every UI, given up or forgotten at a reset): a fence for
-- another writer (M.status_fence) is passed once mark_closed reaches the
-- marker it was given. flight_note: a reset forgot requests or a marker in
-- flight, whose answers may still come, until a marker answered since.
local mark_due, mark_at, mark_wanted, in_send = 0, 0, true, false
local mark_seq, mark_closed, flight_note = 0, 0, false
-- answers a marker still in flight at a reset owes from the UIs that stay: the
-- next marker needs them too (see marker_carry)
local mark_carry = 0
M._mark_seen, M._mark_off = false, false
local function acks_reset()
  if acks and (#acks > 0 or mark_due > 0) then flight_note = true end
  acks, ack_bytes, ack_given = {}, 0, 0
  ack_sent, ack_got, ack_paid, ack_uis = 0, 0, 0, nil
  ack_answered, ack_last, ack_quiet = false, vim.uv.now(), 0
  mark_due, mark_wanted, mark_closed = 0, true, mark_seq
  mark_carry = 0
end
acks_reset()
local function terminal_uis()
  local ok, uis = pcall(vim.api.nvim_list_uis)
  local n = 0
  for _, u in ipairs(ok and uis or {}) do
    if u.stdout_tty then n = n + 1 end
  end
  return math.max(n, 1)
end
-- The answers a marker still in flight owes when the books are reset by a UI
-- attaching ("enter") or leaving ("leave"): the UIs that stay will still
-- answer it, behind the next marker's answers too, so the next marker waits
-- for them as well (else its count runs out on the old marker's late answers,
-- and a frame goes before the new marker is answered). At an attach every UI
-- but the new one stays; the new one is subtracted only when it is a terminal
-- UI (`chan`, the channel UIEnter names; a GUI attaching is no terminal UI,
-- is not counted, and takes nothing off). At a leave the leaving UI may or
-- may not have answered: the count is the lower bound (a frame may go one
-- answer early, never a wait for an answer that cannot come). A suspend and a
-- resume carry nothing: what is in flight then goes to the shell, not back
-- here.
local function marker_carry(ev, chan)
  local owed = mark_due + mark_carry
  if owed <= 0 or (ev ~= "enter" and ev ~= "leave") then return 0 end
  local ok, uis = pcall(vim.api.nvim_list_uis)
  local n, entering = 0, chan == nil  -- no channel named: taken for a terminal UI
  for _, u in ipairs(ok and uis or {}) do
    if u.stdout_tty then
      n = n + 1
      if chan ~= nil and u.chan == chan then entering = true end
    end
  end
  if ev == "enter" then return math.max(0, math.min(owed, n - (entering and 1 or 0))) end
  return math.max(0, math.min(owed - 1, n))
end
-- tty_write sent a frame's request (on the main loop)
ack_note_sent = function(nbytes)
  ack_uis = ack_uis or terminal_uis()
  acks[#acks + 1] = { nbytes, vim.uv.now() }
  ack_bytes = ack_bytes + nbytes
  ack_sent = ack_sent + 1
  M._acks_sent = (M._acks_sent or 0) + 1
end
local function lost_limit() return math.max(M._ack_lost_ms, 4 * ack_quiet) end
-- A request was answered `waited` ms after it was sent (or after the answer
-- before it). ack_quiet starts over with the books at every UI change;
-- M._link_quiet is the same measure for the whole session, at most the lost
-- limit: a suspend and a resume leave the link as it was, and a terminal
-- attaching again is mostly the same link, so a drain rests on what the
-- session has seen (see drain_limit), not on the one round trip a reset
-- leaves, which is a marker's, small as little is written before it.
M._link_quiet = 0
local function note_quiet(waited)
  ack_quiet = math.min(M._ack_lost_ms, math.max(ack_quiet, waited))
  M._link_quiet = math.min(M._ack_lost_ms, math.max(M._link_quiet, waited))
end
local function marking() return not M._mark_off and (mark_wanted or mark_due > 0) end
-- send the marker wanted, unless one is on its way. Written with
-- nvim_ui_send itself, so never wrapped for tmux (tmux answers it) and on no
-- other path; not from a fast event or while fast-event writes wait for the
-- main loop (the order of writes is kept: the frame waits and asks again),
-- and not while the writes are held unless `direct` (a drain before the UI
-- stops). Noted before the write, so an answer that comes during it counts.
local function send_marker(direct)
  if M._mark_off or mark_due > 0 or queued or vim.in_fast_event() or not ui_send_target() then return end
  if not direct and writes_held() then return end
  local carried = mark_carry
  mark_wanted, mark_due, mark_at = false, terminal_uis() + carried, vim.uv.now()
  mark_carry = 0
  mark_seq = mark_seq + 1
  if not pcall(vim.api.nvim_ui_send, MARK) then
    mark_wanted, mark_due, mark_seq, mark_carry = true, 0, mark_seq - 1, carried
    return
  end
  M._tty_n = (M._tty_n or 0) + 1
  M._tty_bytes = (M._tty_bytes or 0) + #MARK
  M._ui_send_n = (M._ui_send_n or 0) + 1
  M._ui_send_bytes = (M._ui_send_bytes or 0) + #MARK
  M._marks_sent = (M._marks_sent or 0) + 1
end
M._send_marker = send_marker
-- a marker not answered within the lost limit: given up, and markers stay
-- off when none was ever answered
local function mark_lost()
  mark_due, mark_wanted, mark_closed, flight_note = 0, false, mark_seq, false
  mark_carry = 0
  M._marks_lost = (M._marks_lost or 0) + 1
  if not M._mark_seen then M._mark_off = true end
end

-- tmux before 3.2 answers status requests but not XTVERSION (3.0a and 3.1c
-- checked in containers; 3.2a answers), so inside one the marker would be
-- waited for until the lost limit and the first GIF of every session would
-- stand still that long. The running tmux tells its version (asked once
-- inside tmux, when the local backend is attached or at the first frame that
-- waits for the terminal, a session with only remote notebooks attaching
-- none; the server, not the binary on PATH, which can be another one): such a
-- version starts the session with markers off, as if the first marker had
-- been given up, and a marker answer that comes after all turns them on again
-- (got_mark). Inside tmux the nearest terminal is the tmux itself, and it
-- answers status requests at once and in order, so Neovim's own start answers
-- are not late there. Anything else that does not answer XTVERSION waits for
-- the lost limit (known issue C (5)).
-- `str` is the version as tmux prints it: "3.1c" (display-message) or
-- "tmux 3.1c" (-V), "next-3.4", "master".
-- Inside tmux is what the passthrough rule above says: TMUX set, and not
-- switched off for a TMUX that was inherited from outside a multiplexer.
M._in_tmux = IN_TMUX
M._tmux_server_version_cmd = { "tmux", "display-message", "-p", "#{version}" }
M._tmux_version_cmd = { "tmux", "-V" }
function M._tmux_version(str)
  local major, minor = tostring(str or ""):match("(%d+)%.(%d+)")
  major, minor = tonumber(major), tonumber(minor)
  if not major or (major > 3 or (major == 3 and minor >= 2)) then return end
  if M._mark_seen then return end
  if mark_due > 0 then
    mark_lost()  -- one is on its way: not waited for either (it never gets an answer)
  else
    M._mark_off, mark_wanted = true, false
  end
end
local tmux_asked = false
local function ask_tmux_version()
  if tmux_asked or not M._in_tmux then return end
  tmux_asked = true
  -- run `cmd`; its output goes to M._tmux_version when it holds a version,
  -- else `fallback` is tried (an old tmux prints nothing for #{version})
  local function run(cmd, fallback)
    pcall(vim.system, cmd, { text = true, timeout = 2000 }, function(r)
      local out = r and r.code == 0 and r.stdout or ""
      vim.schedule(function()
        if out:find("%d+%.%d+") then M._tmux_version(out)
        elseif fallback then run(fallback) end
      end)
    end)
  end
  run(M._tmux_server_version_cmd, M._tmux_version_cmd)
end

local function frame_room(nbytes)
  if draining then return false end
  if marking() then
    -- frames wait for the marker's answer (send_frame sends a wanted one)
    if mark_due == 0 or vim.uv.now() - mark_at < lost_limit() then return false end
    mark_lost()
  end
  if #acks == 0 then return true end
  local now = vim.uv.now()
  if now - math.max(ack_last, acks[1][2]) >= lost_limit() then
    -- nothing answered for that long: the answers are lost
    M._ack_timeouts = (M._ack_timeouts or 0) + 1
    acks, ack_bytes, ack_given = {}, 0, 0
    ack_paid, ack_got = ack_sent, ack_sent * (ack_uis or 1)
    return true
  end
  if ack_given == #acks then return true end
  -- before the first answer the requests in flight are given up once (all of
  -- them), and no more until one is answered (or the lost limit above drops
  -- them)
  if not ack_answered and ack_given == 0 and now - acks[1][2] >= M._ack_timeout_ms then
    M._ack_timeouts = (M._ack_timeouts or 0) + 1
    ack_given, ack_bytes = #acks, 0
    return true
  end
  return ack_bytes + nbytes <= M._frame_window
end
local function got_ack()
  if #acks == 0 then return end  -- the answer to someone else's request
  ack_got = math.min(ack_got + 1, ack_sent * ack_uis)
  local now = vim.uv.now()
  while #acks > 0 and ack_paid < ack_got - (ack_uis - 1) * ack_sent do
    local a = table.remove(acks, 1)
    M._acks_got = (M._acks_got or 0) + 1
    if ack_given > 0 then ack_given = ack_given - 1 else ack_bytes = ack_bytes - a[1] end
    ack_paid = ack_paid + 1
    note_quiet(now - math.max(ack_last, a[2]))
    ack_last = now
    ack_answered = true
  end
end
-- an answer to the marker; with the last one every request sent before it
-- has been answered by every terminal UI, and no frame went after it: all
-- of them are paid, and the terminal answers
local function got_mark()
  if mark_due == 0 then
    -- None is due: another program's XTVERSION, or a late answer to a marker
    -- given up or forgotten (one a reset left owing, if mark_carry says so).
    -- While markers are on and one was answered it pays nothing (the frames'
    -- books stay as they are). But where markers are off, or none was ever
    -- answered, it is the proof that the terminal answers them and was only
    -- slow (a long link, a backlog of what was written before): markers are
    -- on again, and the next frame settles the books, which were kept by the
    -- markers-off rules meanwhile, with a new marker (asked at once when
    -- requests wait). While a drain waits, or the editor leaves or is
    -- suspended, no marker can go: the books stay as they are and the status
    -- answers keep paying them as they come.
    if mark_carry > 0 then mark_carry = mark_carry - 1 end
    if M._mark_off or not M._mark_seen then
      M._mark_seen, M._mark_off = true, false
      if draining or M._leaving or M._suspended then
        mark_wanted = false
      else
        mark_wanted = true
        if #acks > 0 then send_marker() end
      end
    end
    return
  end
  M._mark_seen = true
  mark_due = mark_due - 1
  if mark_due > 0 then return end
  M._marks_got = (M._marks_got or 0) + 1
  mark_closed, flight_note = mark_seq, false
  local now = vim.uv.now()
  note_quiet(now - math.max(ack_last, mark_at))
  M._acks_got = (M._acks_got or 0) + #acks
  acks, ack_bytes, ack_given = {}, 0, 0
  ack_paid, ack_got = ack_sent, ack_sent * (ack_uis or 1)
  ack_answered, ack_last = true, now
  if not in_send and next(placements) then pcall(M._catch_up) end
end
-- answers the terminal still owes: frame requests it has answered before,
-- or a marker (while markers are on), or requests a reset forgot, which a
-- marker's answer, coming after them, settles (flight_note)
local function expect_answers()
  return ack_answered or (mark_due > 0 and not M._mark_off)
    or (flight_note and M._mark_seen and not M._mark_off)
end
local function in_flight() return #acks > 0 or mark_due > 0 end
-- Before Neovim's UI stops reading the terminal (quit, CTRL-Z, :detach) the
-- requests in flight are answered: an answer that comes after it goes to
-- the shell. The UI's own wait for its DA1 answer would read them too, but
-- only for a second, and frames still on their way (a slow link, a terminal
-- busy decoding) can take longer. No frame is sent meanwhile (the writes
-- are held, and `draining` keeps the frames back where another terminal UI
-- still takes writes); with `ask`, while the UI still takes writes, a
-- marker goes out first (also when no request is counted in flight) and is
-- waited for too: its answer comes after every answer still on its way, so
-- nothing is left for the shell even when another program's status answer
-- was taken for a frame's. (Where markers are off, a status request is
-- asked instead, and then only that request, a few bytes, can be left in
-- flight, which the UI's own wait reads.) How long it waits is drain_limit
-- (below), and not at all for a terminal that has answered nothing since the
-- last UI change.
-- How long a drain waits: at least M._ack_timeout_ms, and on a slow link long
-- enough for everything in flight to be read, each request taking as long as
-- the longest wait for an answer seen in the session (M._link_quiet, kept
-- across the resets of the books) and the marker one more, at most the lost
-- limit. A frame that needs seconds to reach the terminal (115 KB over a
-- 25 KB/s link) is still read before the UI stops, also the first one after a
-- resume or an attach, so its answer does not reach the shell. A drain ends
-- with the last answer, so a faster link than the one measured costs nothing.
local function drain_limit()
  local n = #acks + (mark_due > 0 and 1 or 0)
  return math.max(M._ack_timeout_ms, math.min(lost_limit(), n * M._link_quiet))
end
local function drain_acks(ask)
  if not expect_answers() then return end
  if ask and ui_send_target() then
    if not M._mark_off then
      send_marker(true)
    elseif pcall(vim.api.nvim_ui_send, DSR) then
      M._tty_n = (M._tty_n or 0) + 1
      M._tty_bytes = (M._tty_bytes or 0) + #DSR
      M._ui_send_n = (M._ui_send_n or 0) + 1
      M._ui_send_bytes = (M._ui_send_bytes or 0) + #DSR
      ack_note_sent(0)
    end
  end
  if not in_flight() then return end
  draining = true
  pcall(vim.wait, drain_limit(), function() return not in_flight() end, 5)
  draining = false
end
-- Is the client of UI channel `chan` gone? Neovim tells exactly: at the
-- UILeave of a :detach the channel is still open and a notification to it goes
-- through, while for a client that was killed or whose terminal closed it
-- fails ("Invalid channel"), and a channel that has closed has no info at all.
-- The notification is an empty `redraw`, a batch with no event, which every UI
-- client takes and does nothing for (an unknown method makes the client answer
-- with an error that Neovim writes to its log). So nothing is guessed from the
-- client's pid, which says nothing of a client in another pid namespace or on
-- another host behind a forwarded socket; such a client is waited for, as any
-- live one, and the wait is bounded.
local function client_gone(chan)
  chan = chan or -1
  local ok, info = pcall(vim.api.nvim_get_chan_info, chan)
  if not ok or type(info) ~= "table" or next(info) == nil then return true end
  return not pcall(vim.rpcnotify, chan, "redraw")
end
-- :detach has no event before the UI stops, but its UILeave comes while the
-- UI still reads the terminal and passes the answers on. So the requests in
-- flight are answered there, also while another terminal UI keeps showing
-- the editor (the one that left still reads and answers until it stops, and
-- every request waits for the slowest UI): unless the client that left is
-- gone, since one that is gone (its terminal closed, it was killed) answers
-- nothing more.
local function drain_on_leave(chan)
  if not in_flight() or not expect_answers() or M._leaving or M._suspended then return end
  ui_tty_cache = nil  -- the UI that left is no longer listed: writes held from here
  if client_gone(chan) then return end
  drain_acks()
end
M._drain_on_leave = drain_on_leave
-- :JupynvimRenderStats prints the counters since the last reset, then
-- resets them here. A request or a marker still on its way belongs to the
-- new period, where its answer is counted: so the next report never shows
-- more answers than requests.
M._stat_keys = {
  "_tty_n", "_tty_bytes", "_ui_send_n", "_ui_send_bytes", "_frames_sent", "_frames_skipped",
  "_frames_held", "_frames_quiet", "_acks_sent", "_acks_got", "_ack_timeouts", "_place_writes",
  "_marks_sent", "_marks_got", "_marks_lost", "_held_n", "_held_bytes", "_resent_n",
}
function M.reset_stats()
  for _, k in ipairs(M._stat_keys) do M[k] = 0 end
  M._acks_sent = #acks
  M._marks_sent = mark_due > 0 and 1 or 0
end
-- for the tests: the requests not read yet and how many of them count
function M._acks_info()
  return { n = #acks, given = ack_given, bytes = ack_bytes, answered = ack_answered, uis = ack_uis,
           mark = mark_due, wanted = mark_wanted, note = flight_note, seq = mark_seq, closed = mark_closed,
           carry = mark_carry, quiet = ack_quiet, link = M._link_quiet }
end

-- For another module that writes a question of its own to the terminal and
-- counts the status answers (ESC [ 0 n) that end it: the status answers of
-- gif frames still in flight come before its own, and nothing about them
-- says whose they are. Called right before its write, it returns
--   passed, owed
-- `passed` is a function: true once every status answer to a request
-- written before the call has been read. The module ignores the status
-- answers it reads until then. While markers are on and requests or a
-- marker are in flight, a marker is written now (or the one on its way is
-- used), and `passed` is true once that marker has been answered by every
-- terminal UI, in order after every earlier answer; a reset of the books, or
-- the marker given up, passes it too. Otherwise `passed` is true at once, and
-- `owed` is the number of status answers still owed to the frames' requests
-- (markers off, or no marker could be written now), to be ignored first. With
-- nothing in flight: true, 0. Never a request or a marker is written when no
-- frame can be paced (no nvim_ui_send, or no terminal UI).
local function always_passed() return true end
function M.status_fence()
  if not (lua_encodes() and ui_send_target()) then return always_passed, 0 end
  if not (#acks > 0 or mark_due > 0 or flight_note) then return always_passed, 0 end
  if not M._mark_off then
    if mark_due == 0 then mark_wanted = true; send_marker() end
    if mark_due > 0 then
      local want = mark_seq
      return function() return mark_closed >= want end, 0
    end
  end
  return always_passed, math.max(0, ack_sent * (ack_uis or 1) - ack_got)
end

-- A gif that skipped a frame for want of room waits (p.stale, and p.stale_at
-- from when it first found the window full); one that skipped it because it
-- is out of view or nothing is shown has no stale_at and waits for the view.
local function mark_waiting(p)
  p.stale = true
  p.stale_at = p.stale_at or vim.uv.hrtime()
end
-- The gif playing in view that has been waiting for room the longest, among
-- those that waited since before `before` (a gif that ticks now goes after
-- them); nil when none. Without `before`, any waiting gif, a gif with no
-- stale_at after those that have one.
local function longest_waiting(except, before)
  local best, best_at
  for key, p in pairs(placements) do
    if p ~= except and p.stale and p.timer and p.frames then
      local at = p.stale_at or math.huge
      -- the cheap tests first: the visible probe costs up to 100 us, and a
      -- gif out of view (no stale_at) never qualifies against a bound
      if (not best or at < best_at) and (not before or at < before) and on_screen(key) then
        best, best_at = p, at
      end
    end
  end
  return best
end

-- The clock of gif frames and of the heal below (the loop's time, which the
-- timers use). The spec puts a fake clock here.
M._now_ms = function() return vim.uv.now() end

-- A gif shows frame k from the sum of the delays before it to that plus its
-- own delay, counted from p.t0 and repeating. Returns that frame at `now` and
-- the ms until the next one starts. Reads p.delays on every call (a few
-- microseconds for hundreds of frames), so a replaced table counts at once.
local function delay_of(p, k)
  local d = p.delays and p.delays[k]
  if not d or d <= 0 then d = 100 end
  return d
end
function M._clock_frame(p, now)
  local n, cycle = #p.frames, 0
  for k = 1, n do cycle = cycle + delay_of(p, k) end
  local pos, acc = (now - (p.t0 or now)) % cycle, 0
  for k = 1, n do
    local d = delay_of(p, k)
    if pos < acc + d then return k, acc + d - pos end
    acc = acc + d
  end
  return n, 1
end

-- Without nvim_ui_send (Neovim 0.10 and 0.11) the editor writes beside the
-- UI, and the UI writes after each redraw, so a write then can land inside
-- one of its escape sequences. A decoration provider notes when each redraw
-- starts; gif frames, catch-ups and the heal of on-screen images wait until
-- no redraw started for M._quiet_ms, and a frame waits at most
-- M._quiet_max_ms, so a gif beside output that redraws all the time still
-- shows a frame a second. With nvim_ui_send nothing waits.
M._quiet_ms = 150
M._quiet_max_ms = 1000
local last_redraw = -1e18
function M._note_redraw() last_redraw = M._now_ms() end
local function quiet_left(now)
  if vim.api.nvim_ui_send then return 0 end
  return M._quiet_ms - (now - last_redraw)
end
M._redraw_watch = false
if not vim.api.nvim_ui_send then
  vim.api.nvim_set_decoration_provider(vim.api.nvim_create_namespace("jupynvim_redraw"), {
    on_start = function() M._note_redraw(); return false end,
  })
  M._redraw_watch = true
end

-- Send the frame a gif's clock is at, unless the terminal has no room for
-- it yet, or a gif that has waited longer goes first. transmit_virtual =
-- a=t frame data + a=p,U=1,p=1 in ONE atomic write: the explicit p=1
-- placement is replaced in place every frame, so the grid geometry stays
-- authoritative (no re-derivation crops) and placements never accumulate
-- (no ghost/double rendering).
local function send_frame(p)
  local frame = p.frames[p.frame_idx]
  local paced = lua_encodes() and ui_send_target()
  if paced then
    ask_tmux_version()
    if mark_wanted and not M._mark_off then
      in_send = true; send_marker(); in_send = false
    end
    local first = longest_waiting(p, p.stale and p.stale_at or math.huge)
    if first then
      -- every gif shares the window: p waits its turn behind the gif that
      -- has been waiting the longest, which takes the room instead
      M._frames_held = (M._frames_held or 0) + 1
      mark_waiting(p)
      return send_frame(first)
    end
    if not frame_room(#frame) then
      M._frames_held = (M._frames_held or 0) + 1
      mark_waiting(p)
      return
    end
  end
  M._frames_sent = (M._frames_sent or 0) + 1
  -- the terminal has this frame now (p.sent_idx: a tick in the same frame
  -- sends nothing), and nothing waits for a quiet screen any more
  p.stale, p.stale_at, p.quiet_since = false, nil, nil
  p.sent_idx = p.frame_idx
  if p.renderer == "placeholder" and p.cols and p.rows then
    kitty_call_async("kitty_transmit_virtual", {
      image_id = p.image_id, png_b64 = frame, cols = p.cols, rows = p.rows,
    })
    p.placed_gen = M._place_gen
  else
    kitty_call_async("kitty_transmit_only", { image_id = p.image_id, png_b64 = frame })
  end
  if paced then tty_write(DSR, "pace", { bytes = #frame }) end
end

-- A gif that skipped a frame (off screen, or no room) shows an old frame
-- until its next tick, which for a slow gif is seconds away. When the view
-- changes (scroll, window, tab page) or an answer frees room, the gifs that
-- skipped a frame send the frame their clock is at right away, once they are
-- on screen, the one that has waited longest first, while the window has
-- room. Without nvim_ui_send they wait for a quiet screen first, each at
-- most M._quiet_max_ms, counted as a held tick counts it (p.quiet_since,
-- one count for both): so while a cell streams output and the screen never
-- goes quiet, a slow gif scrolled into view still shows its clock's frame
-- within a second, not only after its next tick.
local quiet_timer
local function catch_up_later(wait)
  -- one timer, armed again at each call for the soonest of the quiet end
  -- and the caps as they are now (a redraw since the last call moved the
  -- quiet end later; a gif sent since has no cap any more)
  quiet_timer = quiet_timer or vim.uv.new_timer()
  quiet_timer:start(math.max(1, math.ceil(wait)), 0, vim.schedule_wrap(function()
    if quiet_timer then pcall(quiet_timer.close, quiet_timer); quiet_timer = nil end
    M._catch_up()
  end))
end
-- for the tests: the ms until the catch-up looks again, or nil
function M._catch_up_due()
  if not quiet_timer then return nil end
  local ok, due = pcall(quiet_timer.get_due_in, quiet_timer)
  return ok and due or nil
end
function M._catch_up()
  if writes_held() or draining then return end
  local now = M._now_ms()
  local left = quiet_left(now)
  if left > 0 then
    local due, wait = {}, left
    for key, p in pairs(placements) do
      -- the gifs the catch-up below would send (as longest_waiting picks them)
      if p.stale and p.timer and p.frames and on_screen(key) then
        p.quiet_since = p.quiet_since or now
        local w = p.quiet_since + M._quiet_max_ms - now
        if w <= 0 then due[#due + 1] = p else wait = math.min(wait, w) end
      end
    end
    table.sort(due, function(a, b) return (a.stale_at or math.huge) < (b.stale_at or math.huge) end)
    for _, p in ipairs(due) do
      send_frame(p)
      if p.stale then break end  -- no room: the rest wait
    end
    catch_up_later(wait)
    return
  end
  for _ = 1, 256 do
    local p = longest_waiting()
    if not p then return end
    send_frame(p)
    if p.stale then return end  -- no room: the rest wait
  end
end

-- Drive a placement's animation by re-transmitting the next frame to the
-- same image_id on a timer. Ghostty 1.3 doesn't implement the kitty
-- animation protocol, but it does replace image data on retransmit
-- (graphics_storage.zig: addImage frees any existing image with the same
-- id), so the placeholders showing that id refresh on each tick. Each tick
-- shows the frame of the gif's clock (M._clock_frame), so a late tick never
-- slows the animation down.
local function start_animation(p, cell_id)
  if not p or not p.frames or #p.frames < 2 then return end
  if M._anim_paused then return end
  if p.timer then pcall(p.timer.stop, p.timer); pcall(p.timer.close, p.timer) end
  p.frame_idx = 1
  p.t0 = M._now_ms()
  p.cell_id = cell_id
  local function tick()
    -- Stop if the placement was cleared from under us.
    if placements[cell_id] ~= p then
      if p.timer then pcall(p.timer.stop, p.timer); pcall(p.timer.close, p.timer) end
      p.timer = nil
      return
    end
    local now = M._now_ms()
    local idx, wait = M._clock_frame(p, now)
    p.frame_idx = idx
    -- Off screen, or with no terminal to draw on, the clock runs on and
    -- nothing is sent; the next tick in view (or M._catch_up) catches up.
    -- A frame the terminal has already (a catch-up sent it when the screen
    -- went quiet, just before this held tick came) is not sent again.
    if writes_held() or not on_screen(cell_id) then
      M._frames_skipped = (M._frames_skipped or 0) + 1
      p.stale, p.stale_at, p.quiet_since = true, nil, nil
    elseif p.stale or idx ~= p.sent_idx then
      local left = quiet_left(now)
      if left > 0 and now - (p.quiet_since or now) < M._quiet_max_ms then
        p.quiet_since = p.quiet_since or now
        M._frames_quiet = (M._frames_quiet or 0) + 1
        p.stale, p.stale_at = true, nil
        wait = math.min(wait, left, p.quiet_since + M._quiet_max_ms - now)
      else
        send_frame(p)
      end
    end
    if p.timer then
      pcall(p.timer.start, p.timer, math.max(1, math.ceil(wait)), 0, vim.schedule_wrap(tick))
    end
  end
  p.timer = vim.uv.new_timer()
  local _, w0 = M._clock_frame(p, p.t0)
  pcall(p.timer.start, p.timer, math.max(1, math.ceil(w0)), 0, vim.schedule_wrap(tick))
end

-- Pause / resume all gif animations. Diagnostic + workaround: each animated
-- gif re-transmits a frame on a timer, which in remote mode runs on nvim's main
-- loop. Toggling this off is an A/B test for whether animation drives the
-- "slow motion" navigation users see over a remote backend.
M._anim_paused = false
function M.pause_animations()
  M._anim_paused = true
  for _, p in pairs(placements) do
    if p.timer then pcall(p.timer.stop, p.timer); pcall(p.timer.close, p.timer); p.timer = nil end
  end
end
function M.resume_animations()
  M._anim_paused = false
  for cid, p in pairs(placements) do
    if p.frames and #p.frames > 1 and not p.timer then start_animation(p, cid) end
  end
end
function M.animations_paused() return M._anim_paused end

local function stop_timer(p)
  if p and p.timer then
    pcall(p.timer.stop, p.timer)
    pcall(p.timer.close, p.timer)
    p.timer = nil
  end
end

local inflight = {}  -- key -> "src_hash|renderer" of a transmit under way
local gen = {}       -- key -> number of the newest transmit started for it

-- Is the image the caller would ask for already transmitted for this cell?
-- Keyed on the request, the source bytes and the renderer asked for, not on
-- what was stored: a jpeg or gif is stored as its converted png, and a failed
-- conversion is stored as chafa, so comparing against the stored image missed
-- on every render and redid the work.
function M.is_cached(cell_id, b64, renderer)
  local p = placements[cell_id]
  return p ~= nil and p.src_hash == quick_hash(b64) and p.want == (renderer or "chafa")
end

-- A newer request for this key started while this one was being sent: free
-- this image and report nothing, so it does not cover the newer one.
local function superseded(cell_id, opts, id, callback)
  if opts._gen and gen[cell_id] ~= opts._gen then
    kitty_call_async("kitty_clear_image", { image_id = id })
    callback(nil)
    return true
  end
  return false
end

function M.ensure_transmitted(cell_id, b64, callback, opts)
  opts = opts or {}
  local renderer = opts.renderer or "chafa"
  local mime = opts.mime
  local src_hash = opts._src_hash or quick_hash(b64)
  local want = opts._want or renderer
  local existing = placements[cell_id]
  if existing and existing.src_hash == src_hash and existing.want == want then
    callback(existing.image_id)
    return
  end
  if refused[cell_id] == src_hash then
    callback(nil)
    return
  end
  -- A local-mode transmit waits in call_sync, and vim.wait runs scheduled
  -- renders meanwhile, which asked for the same image again and sent it a
  -- second time under a new id that nothing ever freed. The outer transmit
  -- finishes and refreshes, so a nested request for it just stands down.
  if not opts._src_hash then
    local tag = tostring(src_hash) .. "|" .. want
    if inflight[cell_id] == tag then return end
    inflight[cell_id] = tag
    -- A newer transmit for this key can start and finish inside this one's
    -- wait, a frame loop for example. Whichever is older steps aside when it
    -- lands (see superseded) instead of covering the newer image.
    gen[cell_id] = (gen[cell_id] or 0) + 1
    opts._gen = gen[cell_id]
    local done = callback
    callback = function(id)
      if inflight[cell_id] == tag then inflight[cell_id] = nil end
      -- the image this one replaced is still held by the terminal; free it
      if id and existing and existing.image_id ~= id and placements[cell_id] ~= existing then
        stop_timer(existing)
        kitty_call_async("kitty_clear_image", { image_id = existing.image_id })
      end
      done(id)
    end
  end
  -- Outputs are cleaned once when they enter the model. This covers anything
  -- that did not come through there, and only runs on a miss, where a
  -- transmit already costs time linear in the image.
  b64 = M.clean_b64(b64)
  if not b64 or b64 == "" then
    callback(nil)
    return
  end
  if not M._b64_ok(b64) then
    refused[cell_id] = src_hash
    log.warn(("image %s: its data is not base64 and is not shown"):format(tostring(cell_id)))
    -- The key stands for this data now, so the image it showed before (other
    -- data: an unchanged value returned above) goes too. The wrapped callback
    -- frees a replaced image only for an id.
    local old = placements[cell_id]
    if old then
      stop_timer(old)
      kitty_call_async("kitty_clear_image", { image_id = old.image_id })
      placements[cell_id] = nil
    end
    callback(nil)
    return
  end
  opts._src_hash, opts._want = src_hash, want
  local h = quick_hash(b64)
  -- Convert non-PNG to PNG if needed for placeholder/kitty renderers.
  -- chafa accepts any format directly via tempfile.
  -- If conversion fails (no magick, or unsupported source), fall through to
  -- chafa so the user sees something rather than a blank cell.
  if mime and mime ~= "image/png" and renderer ~= "chafa" then
    ensure_png(b64, mime, function(png_b64)
      if png_b64 then
        opts.mime = "image/png"
        opts._gif_b64 = (mime == "image/gif" and renderer == "placeholder") and b64 or nil
        M.ensure_transmitted(cell_id, png_b64, callback, opts)
      elseif vim.fn.executable("chafa") == 1 then
        log.info("falling back to chafa for " .. tostring(mime))
        local fallback = vim.tbl_extend("force", opts, { renderer = "chafa", mime = mime })
        M.ensure_transmitted(cell_id, b64, callback, fallback)
      else
        callback(nil)
      end
    end)
    return
  end
  local id = next_image_id()

  if renderer == "placeholder" then
    -- Real PNG via Kitty Unicode placeholder protocol: the image stays
    -- anchored to buffer text because placeholders ARE text.
    log.debug(string.format("placeholder: cell=%s id=%d transmitting %d b64 chars (%dx%d cells)",
      cell_id, id, #b64, PLACEHOLDER_COLS, PLACEHOLDER_ROWS))
    local _, terr = kitty_call_sync("kitty_transmit_virtual", {
      image_id = id, png_b64 = b64,
      cols = PLACEHOLDER_COLS, rows = PLACEHOLDER_ROWS,
    })
    if terr then
      log.warn(string.format("placeholder: cell=%s id=%d transmit FAILED: %s", cell_id, id, tostring(terr)))
      callback(nil)
      return
    end
    if superseded(cell_id, opts, id, callback) then return end
    local p = {
      image_id = id, png_hash = h, b64 = b64, src_hash = src_hash, want = want,
      placement_id = 1, renderer = "placeholder",
      rows = PLACEHOLDER_ROWS, cols = PLACEHOLDER_COLS,
    }
    placements[cell_id] = p
    -- one-time cleanup: drop any anonymous placements this image id may
    -- have accumulated in the terminal (older sessions used a=T per
    -- frame), leaving exactly the explicit p=1 placement
    kitty_call_async("kitty_place_virtual", {
      image_id = id, cols = PLACEHOLDER_COLS, rows = PLACEHOLDER_ROWS,
    })
    p.placed_gen = M._place_gen
    log.debug(string.format("placeholder: cell=%s id=%d transmitted ok, fg=#%06x",
      cell_id, id, id))
    callback(id)

    -- For gifs, extract remaining frames asynchronously and start animation
    -- when ready. The first frame is already showing via the placement above,
    -- so the editor isn't blocked on the multi-second magick run.
    if opts._gif_b64 then
      local gif_b64 = opts._gif_b64
      extract_gif_frames_async(gif_b64, function(anim)
        local pp = placements[cell_id]
        if pp ~= p then return end -- placement was replaced or cleared
        if anim and anim.frames and #anim.frames > 1 then
          pp.frames = anim.frames
          pp.delays = anim.delays
          start_animation(pp, cell_id)
        end
      end)
    end
    return
  end

  if renderer == "chafa" and vim.fn.executable("chafa") == 1 then
    ascii_art_for(b64, function(lines)
      if lines then
        if superseded(cell_id, opts, id, callback) then return end
        placements[cell_id] = {
          image_id = id, png_hash = h, b64 = b64, src_hash = src_hash, want = want,
          ascii_lines = lines, placement_id = id, renderer = "chafa",
        }
        callback(id)
      else
        callback(nil)
      end
    end)
    return
  end

  local _, terr = kitty_call_sync("kitty_transmit_only", { image_id = id, png_b64 = b64 })
  if terr then
    callback(nil)
    return
  end
  if superseded(cell_id, opts, id, callback) then return end
  placements[cell_id] = {
    image_id = id, png_hash = h, b64 = b64, src_hash = src_hash, want = want,
    placement_id = id, placed_row = nil, placed_col = nil,
    renderer = "kitty",
  }
  callback(id)
end

-- Build the placeholder virt_lines for a transmitted-virtual image.
-- Returns list of virt_lines, each = list of {text, hl_group} chunks.
function M.placeholder_virt_lines(cell_id)
  local p = placements[cell_id]
  if not p or p.renderer ~= "placeholder" then return nil end
  local id = p.image_id
  -- Image_id encoded as 24-bit RGB foreground color (most significant byte = R)
  local r = bit.band(bit.rshift(id, 16), 0xff)
  local g = bit.band(bit.rshift(id, 8), 0xff)
  local b = bit.band(id, 0xff)
  if r == 0 and g == 0 and b == 0 then b = 1 end  -- avoid pure black (would mean "default")
  local hl = "JupynvimPH_" .. id
  vim.api.nvim_set_hl(0, hl, { fg = string.format("#%02x%02x%02x", r, g, b) })

  local rows = {}
  local placeholder_utf8 = utf8(0x10EEEE)
  for ridx = 0, p.rows - 1 do
    local row_d = utf8(DIACRITICS[ridx + 1] or DIACRITICS[1])
    local cells_str = ""
    for cidx = 0, p.cols - 1 do
      local col_d = utf8(DIACRITICS[cidx + 1] or DIACRITICS[1])
      cells_str = cells_str .. placeholder_utf8 .. row_d .. col_d
    end
    table.insert(rows, { { cells_str, hl } })
  end
  return rows
end

-- Get the ASCII-art lines for a cell (or nil if direct placement was used).
function M.ascii_lines_for(cell_id)
  local p = placements[cell_id]
  if p and p.ascii_lines then return p.ascii_lines end
  return nil
end

function M.placement_cols(cell_id)
  local p = placements[cell_id]
  if p and p.cols then return p.cols end
  return nil
end

-- Place the cell's image at (screen_row, screen_col) ONCE. Subsequent calls
-- are no-ops to avoid the image jumping around as renders re-fire.
-- Use M.force_replace(cell_id) to allow re-placement (called when cell re-runs).
function M.place_at_screen_row(cell_id, screen_row, screen_col, rows, cols)
  local p = placements[cell_id]
  if not p then return end
  if p.placed_row then return end  -- already placed; don't move
  local _, perr = kitty_call_sync("kitty_place", {
    image_id = p.image_id, placement_id = p.placement_id,
    cols = cols, rows = rows,
    screen_row = screen_row, screen_col = screen_col,
  })
  if perr then return end
  p.placed_row = screen_row
  p.placed_col = screen_col
  log.debug(string.format("place: cell=%s id=%d row=%d col=%d (locked)", cell_id, p.image_id, screen_row, screen_col))
end

function M.force_replace(cell_id)
  local p = placements[cell_id]
  if p then p.placed_row = nil; p.placed_col = nil end
end

-- Re-assert the explicit virtual placement of placeholder images whose
-- placement the terminal may have lost (~60 bytes each, no image data). A
-- placeholder cell whose image has no virtual placement falls back to
-- native-size tile mapping, which renders as a randomly cropped image.
--
-- This runs on every render, which in insert mode is every keystroke, so it
-- writes only what changed: an image is placed again when the placement
-- generation moved on since it was last placed (invalidate_placements: a
-- terminal UI attached, visible placements were cleared). With nvim_ui_send
-- nothing else loses a placement: kitty and Ghostty keep virtual placements
-- through screen clears and d=a deletes. Without it (Neovim 0.11, or no
-- terminal UI) a write can still be cut by the UI's own output, so the
-- images on screen are healed too, at most once per M._heal_ms, once the
-- screen is quiet (Neovim 0.11: no redraw for M._quiet_ms), with one more
-- pass when a burst of renders is over. Animated images are skipped:
-- every frame they send places them again. While writes are held (no
-- terminal shows the editor) nothing is placed; the terminal UI that
-- attaches next gets every placement anew.
M._place_gen = 0
function M.invalidate_placements() M._place_gen = M._place_gen + 1 end
M._heal_ms = 1000
local last_heal = -1e18
local heal_timer = nil
function M.reassert_virtual_placements()
  if writes_held() then return end
  local heal = false
  if not ui_send_target() then
    local now, gap = M._now_ms(), M._heal_ms
    local due = math.max(gap - (now - last_heal), quiet_left(now))
    if due <= 0 then
      heal, last_heal = true, now
    elseif not heal_timer then
      heal_timer = vim.uv.new_timer()
      heal_timer:start(math.max(1, math.ceil(due)), 0, vim.schedule_wrap(function()
        if heal_timer then pcall(heal_timer.close, heal_timer); heal_timer = nil end
        pcall(M.reassert_virtual_placements)
      end))
    end
  end
  for key, p in pairs(placements) do
    if p.renderer == "placeholder" and p.cols and p.rows and not p.timer
       and (p.placed_gen ~= M._place_gen or (heal and on_screen(key))) then
      kitty_call_async("kitty_place_virtual", {
        image_id = p.image_id, cols = p.cols, rows = p.rows,
      })
      p.placed_gen = M._place_gen
      M._place_writes = (M._place_writes or 0) + 1
    end
  end
end

function M.clear_for_cell(cell_id)
  visible_probe[cell_id] = nil
  -- a refused key has no placement, so this comes before the early return
  refused[cell_id] = nil
  local p = placements[cell_id]
  if not p then return end
  stop_timer(p)
  kitty_call_async("kitty_clear_image", { image_id = p.image_id })
  placements[cell_id] = nil
end

-- The owner of a code cell's image outputs is that cell in one notebook
-- buffer. A copied .ipynb holds the same cell ids, and owned by the id alone,
-- hiding or clearing an output in one copy freed the other copy's image.
function M.output_owner(buf, cell_id) return tostring(buf) .. "\31" .. tostring(cell_id) end

-- Registry key of a code cell's image output, one per output. The owner is
-- recorded rather than parsed back out of the key, because nothing stops a
-- cell id from looking like another cell's id plus a suffix.
local key_owner = {}
function M.output_key(owner, idx)
  local key = tostring(owner) .. "\31out" .. tostring(idx)
  key_owner[key] = owner
  return key
end

-- Is `key` still one of a cell's current image outputs? A local transmit
-- waits in call_sync, and a render nested in that wait can find the output
-- gone and drop the key before the image lands.
function M.is_output_key_live(key) return key_owner[key] ~= nil end

-- Free the output images of `owner` whose keys are not in `keep` (all of
-- them when keep is nil). Markdown images are keyed separately and stay.
-- Returns the keys it cleared.
function M.clear_outputs_for_cell(owner, keep)
  local cleared = {}
  for key, o in pairs(key_owner) do
    if o == owner and not (keep and keep[key]) then
      M.clear_for_cell(key)
      key_owner[key] = nil
      cleared[#cleared + 1] = key
    end
  end
  return cleared
end

function M.clear_all()
  for k, p in pairs(placements) do
    stop_timer(p)
    placements[k] = nil
  end
  for k in pairs(key_owner) do key_owner[k] = nil end
  for k in pairs(visible_probe) do visible_probe[k] = nil end
  for k in pairs(refused) do refused[k] = nil end
  kitty_call_async("kitty_clear_all", {})
end

-- Backwards-compat alias. init.lua and other call sites use Image.delete_all().
M.delete_all = M.clear_all

-- Clear all VISIBLE placements but keep image data in kitty's cache. Used on
-- notebook open to wipe stray direct placements left behind by file
-- explorers (snacks.image previews .ipynb files; the placement persists
-- past the explorer closing). Our cells use virtual placements (U=1 +
-- Unicode placeholder chars in buffer text), so kitty automatically
-- re-creates them when it next reads the placeholder chars on screen.
-- Gif animation isn't disturbed because its image bytes survive.
function M.clear_visible_placements()
  kitty_call_async("kitty_clear_visible", {})
  M.invalidate_placements()
end

function M.supported()
  -- Require a TTY (interactive nvim) and Kitty-compat terminal.
  if not vim.env.TERM then return false end
  local term = (vim.env.TERM_PROGRAM or "") .. " " .. (vim.env.TERM or "")
  if term:lower():find("ghostty") or term:lower():find("kitty") then return true end
  if vim.env.KITTY_WINDOW_ID or vim.env.GHOSTTY_RESOURCES_DIR then return true end
  return false
end

function M.attach(client, tty_path)
  rpc_client = client
  ask_tmux_version()
  -- With a TUI that takes nvim_ui_send, every escape is encoded here and goes
  -- out through the TUI (tty_write). The backend writing its own /dev/tty is
  -- exactly the out-of-order writer that cut the TUI's sequences. The same
  -- once any terminal UI has been attached (M._had_ui, also on Neovim 0.11
  -- and when it has left since), as long as tty_write's writes reach a
  -- terminal: then they go where the Neovim 0.11 question compares
  -- (M._pid_in_my_terminal), and no image goes to the backend and back.
  if ui_send_target() or (M._had_ui and lua_writes_reach_terminal()) then
    M._remote_mode = true
    log.info("kitty_attach: escapes encoded in Lua, written by tty_write")
    if client.call then
      client:call("kitty_attach", { remote = true }, function(err)
        if err then log.warn("kitty_attach(remote): " .. tostring(err)) end
      end)
    end
    return
  end
  -- No terminal UI so far (nvim --headless), or one but the editor's stderr
  -- is not a terminal: try local mode first, the backend writing kitty
  -- escapes to that tty directly. Works when the editor has a controlling
  -- tty that the backend (its child) shares. The writes it is asked for are
  -- held like tty_write's (backend_held); the first terminal UI to attach
  -- ends it when tty_write's writes reach a terminal (M._ui_changed).
  local err = client:call_sync("kitty_attach", { tty = tty_path or "/dev/tty" }, 2000)
  if not err then
    M._remote_mode = false
    log.info("kitty_attach: local mode (backend owns " .. (tty_path or "/dev/tty") .. ")")
    return
  end
  -- The backend cannot open the tty (no controlling terminal, /dev/tty not
  -- accessible): encode the escapes here (the PNG is already here, from the
  -- cell-output notification) and write them with tty_write. The backend is
  -- told to enter remote mode too, for any path that still goes through it.
  M._remote_mode = true
  log.info("kitty_attach: remote mode, escapes encoded in Lua and written by tty_write")
  client:call_sync("kitty_attach", { remote = true }, 2000)  -- best-effort; we don't depend on it
end

-- What the terminal missed while writes were held, sent once a terminal
-- shows the editor again: the deletes, then every image whose transmit was
-- held, then the direct placements held. A playing gif is left to its next
-- frame in view (M._catch_up).
local function replay_held()
  local h = held
  held = no_held()
  if h.all then kitty_call_async("kitty_clear_all", {})
  elseif h.visible then kitty_call_async("kitty_clear_visible", {}) end
  for id in pairs(h.deletes) do kitty_call_async("kitty_clear_image", { image_id = id }) end
  for _, p in pairs(placements) do
    if h.images[p.image_id] then
      if p.timer then
        p.stale = true
      elseif p.b64 and p.renderer == "placeholder" and p.cols and p.rows then
        M._resent_n = (M._resent_n or 0) + 1
        kitty_call_async("kitty_transmit_virtual", {
          image_id = p.image_id, png_b64 = p.b64, cols = p.cols, rows = p.rows,
        })
        p.placed_gen = M._place_gen
      elseif p.b64 and p.renderer == "kitty" then
        M._resent_n = (M._resent_n or 0) + 1
        kitty_call_async("kitty_transmit_only", { image_id = p.image_id, png_b64 = p.b64 })
        -- placed again below when its placement was held too, else by the
        -- next render
        if not h.places[p.image_id] then p.placed_row, p.placed_col = nil, nil end
      end
    end
    local place = h.places[p.image_id]
    if place and p.renderer == "kitty" then kitty_call_async("kitty_place", place) end
  end
end

-- A UI attached or left (ev "enter" or "leave"), or the editor was
-- suspended or resumed. A terminal UI attaching (nvim --remote-ui to a
-- headless nvim, which attached the backend to its own tty) tells the
-- backend to stop writing when tty_write's writes reach a terminal: from
-- then on every write is encoded here and goes through tty_write and its
-- hold (nvim_ui_send on 0.12). Its terminal may not hold our placements,
-- so they are placed again. When a terminal shows the editor again after
-- writes were held (was_held, above), what they carried is sent. The frame
-- requests in flight start over, and the next frame waits for a marker
-- (see frame_room).
function M._ui_changed(ev, chan)
  ui_tty_cache = nil
  local carry = marker_carry(ev, chan or (vim.v.event or {}).chan)
  acks_reset()
  mark_carry = carry
  local tty = terminal_ui()
  if ev == "enter" and tty then M._suspended = false end  -- in case no VimResume comes
  local now_held = writes_held()
  local resumed = was_held and not now_held
  was_held = now_held
  local attached = ev == "enter" and ui_send_target()
  if M._had_ui and not M._remote_mode and lua_writes_reach_terminal() then
    M._remote_mode = true
    if rpc_client and rpc_client.call then
      rpc_client:call("kitty_attach", { remote = true }, function() end)
    end
    log.info("kitty: a terminal UI attached; escapes now encoded in Lua and written by tty_write")
  end
  if not (attached or resumed) then return end
  M.invalidate_placements()
  if resumed then replay_held() end
  vim.schedule(function()
    pcall(M.reassert_virtual_placements)
    pcall(M._catch_up)
  end)
end
local aug = vim.api.nvim_create_augroup("jupynvim_image_ui", { clear = true })
vim.api.nvim_create_autocmd("UIEnter", {
  group = aug,
  callback = function() M._ui_changed("enter") end,
})
-- nested: autocmds that scheduled work raises while drain_on_leave and
-- drain_acks wait still fire. (The terminal's answers need no flag: Neovim
-- raises TermResponse as forced, so it runs inside any autocmd.)
vim.api.nvim_create_autocmd("UILeave", {
  group = aug,
  nested = true,
  callback = function()
    drain_on_leave((vim.v.event or {}).chan)
    M._ui_changed("leave")
  end,
})
vim.api.nvim_create_autocmd("VimSuspend", {
  group = aug,
  nested = true,
  callback = function() M._suspended = true; drain_acks(true); M._ui_changed("suspend") end,
})
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = aug,
  nested = true,
  callback = function() M._leaving = true; drain_acks(true) end,
})
vim.api.nvim_create_autocmd("VimResume", {
  group = aug,
  callback = function() M._suspended = false; M._ui_changed("resume") end,
})
-- a --remote-ui client described itself (its pid) just after it attached:
-- on Neovim 0.11 the UIs are looked at again, which asks where it runs
-- (see terminal_ui); nothing else changes here
vim.api.nvim_create_autocmd("ChanInfo", {
  group = aug,
  callback = function()
    if not vim.api.nvim_ui_send then ui_tty_cache = nil; terminal_ui() end
  end,
})
-- the terminal's answers (see frame_room): a marker's (ESC P > | ..., not any
-- other DCS answer: Neovim's own start queries get some); an
-- OSC 11 answer, after which a status answer may not be a frame's, so while
-- frame requests wait a marker settles them; a status answer to a frame's
-- request, ESC [ 0 n or ESC [ 3 n from a terminal that reports a
-- malfunction, which pays nothing while a marker is wanted or on its way.
-- An answer that frees room sends the frame of the gif that has waited
-- longest at once (M._catch_up).
vim.api.nvim_create_autocmd("TermResponse", {
  group = aug,
  callback = function(ev)
    local d = ev.data
    local seq = type(d) == "table" and d.sequence or d
    if type(seq) ~= "string" then return end
    if seq:find("^\27P>|") then got_mark(); return end
    if seq:find("^\27%]11;") then
      if #acks > 0 and mark_due == 0 and not M._mark_off then mark_wanted = true; send_marker() end
      return
    end
    if seq ~= "\27[0n" and seq ~= "\27[3n" then return end
    if #acks == 0 or marking() then return end
    got_ack()
    if next(placements) then pcall(M._catch_up) end
  end,
})
vim.api.nvim_create_autocmd({ "WinScrolled", "BufWinEnter", "TabEnter" }, {
  group = aug,
  callback = function() if next(placements) then pcall(M._catch_up) end end,
})

return M

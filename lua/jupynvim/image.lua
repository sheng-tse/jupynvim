-- Native Kitty graphics protocol — Unicode placeholder mode.
--
-- We do NOT depend on image.nvim. Implementation:
--   1. Send PNG bytes (base64) to Rust backend via `kitty_transmit` RPC.
--      Rust opens /dev/tty and emits Kitty escape `a=t f=100 i=ID U=1 q=2`,
--      which transmits the image to the terminal in virtual-placement mode.
--   2. Build placeholder text using U+10EEEE + row diacritic + col diacritic.
--   3. Render the text via virt_lines extmarks. The foreground color of each
--      placeholder encodes the image_id (24-bit RGB).
--   4. Kitty/Ghostty replaces placeholders with the actual image at draw time.
--      This survives Neovim's redraws because placeholders ARE buffer text.
--
-- Reference: https://sw.kovidgoyal.net/kitty/graphics-protocol/#unicode-placeholders

local log = require("jupynvim.log")
local M = {}

-- The 297 row/column diacritics defined by the Kitty protocol.
-- Source: kitty/kitty/data-types.h `placeholder_diacritics` (verified array).
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
  0x0818,0x0819,0x081B,0x081C,0x081D,0x081E,0x0823,0x0825,0x0826,0x0827,
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
  -- Avoid pitch-black fg for low IDs — Kitty needs a non-zero color
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

-- cell_id -> { image_id, rows, cols, png_hash }
local placements = {}
M._placements = placements

local rpc_client = nil
function M.set_client(c) rpc_client = c end

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

-- Write raw bytes to the user's terminal.
-- /dev/tty is the canonical path, but some nvim launches have no controlling
-- tty (ENXIO). We try, in order:
--   1) the path returned by `tty` (if controlling tty is set)
--   2) fd 2 (stderr) — usually pointed at the same terminal as stdout
--   3) /dev/tty via libuv
--   4) /dev/tty via Lua io
--   5) `cat > /dev/tty` via shell
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

local function tty_write(s)
  if IN_TMUX then s = tmux_wrap(s) end
  local uv = vim.uv or vim.loop

  -- 1) chansend(vim.v.stderr, ...) — this is what image.nvim uses. vim.v.stderr
  -- is a channel ID that always points at nvim's stderr stream, which the TUI
  -- has connected to the user's terminal. APC graphics escapes pass through
  -- unmodified. Works regardless of /dev/tty access.
  if vim.v.stderr and vim.v.stderr ~= 0 then
    local ok, ret = pcall(vim.api.nvim_chan_send, vim.v.stderr, s)
    if ok then
      log.info(string.format("tty_write chansend(stderr=%d) %d bytes ok", vim.v.stderr, #s))
      return true
    else
      log.warn("chansend stderr failed: " .. tostring(ret))
    end
  end

  -- 2) io.stdout (works for some nvim launches)
  local ok = pcall(function() io.stdout:write(s); io.stdout:flush() end)
  if ok then
    log.info(string.format("tty_write stdout %d bytes ok", #s))
    return true
  end

  -- 2) tty(1)-resolved path (interactive nvim with controlling tty)
  local tty = resolve_tty()
  if tty then
    local fd = uv.fs_open(tty, "w", 420)
    if fd then
      local _, werr = uv.fs_write(fd, s, -1)
      uv.fs_close(fd)
      if not werr then
        log.info(string.format("tty_write resolved=%s %d bytes ok", tty, #s))
        return true
      end
    end
  end

  -- 3) /dev/tty via libuv
  local fd = uv.fs_open("/dev/tty", "w", 420)
  if fd then
    local _, werr2 = uv.fs_write(fd, s, -1)
    uv.fs_close(fd)
    if not werr2 then
      log.info(string.format("tty_write libuv-tty %d bytes ok", #s))
      return true
    end
  end

  -- 4) Lua io /dev/tty
  local f = io.open("/dev/tty", "wb")
  if f then
    local ok2 = pcall(function() f:write(s); f:close() end)
    if ok2 then
      log.info(string.format("tty_write io-tty %d bytes ok", #s))
      return true
    end
  end

  log.error(string.format("ALL tty_write methods failed for %d bytes", #s))
  return false
end

-- ── Local kitty escape encoding (remote-mode fast path) ──
--
-- In REMOTE mode the PNG already lives here (it arrived in the cell-output
-- notification). Sending it BACK to the backend just to get the kitty escape
-- means the bytes cross the slow SSH/srun link three times. Instead we encode
-- the escape in Lua and write straight to the local /dev/tty — zero backend
-- round-trips. These encoders mirror core/src/kitty.rs byte-for-byte.
-- In LOCAL mode we keep using the backend (fast IPC + it owns tmux wrapping).
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

-- RPC dispatch to backend's kitty handlers (LOCAL mode), or local encode +
-- direct tty write (REMOTE mode). Synchronous shape — returns res or nil+err.
local function kitty_call_sync(method, args, timeout)
  if M._remote_mode then
    local esc = encode_local(method, args or {})
    if esc then tty_write(esc) end
    return { image_id = args and args.image_id }  -- mimic backend response shape
  end
  if not rpc_client or not rpc_client.job then return nil, "no rpc client" end
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
  if M._remote_mode then
    local esc = encode_local(method, args or {})
    if esc then tty_write(esc) end
    return
  end
  if not rpc_client or not rpc_client.job then return end
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

local NEXT_ID = 1000

-- Generate ASCII art via chafa for the PNG and CACHE it per cell hash.
-- ASCII art is rendered as virt_lines in the buffer — it scrolls naturally
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

-- Drive a placement's animation by re-transmitting the next frame to the
-- same image_id on a timer. Ghostty 1.3 doesn't implement the kitty
-- animation protocol, but it does replace image data on retransmit
-- (graphics_storage.zig: addImage frees any existing image with the same
-- id), so the placeholders showing that id refresh on each tick.
local function start_animation(p, cell_id)
  if not p or not p.frames or #p.frames < 2 then return end
  if p.timer then pcall(p.timer.stop, p.timer); pcall(p.timer.close, p.timer) end
  p.frame_idx = 1
  p.cell_id = cell_id
  local function tick()
    -- Stop if the placement was cleared from under us.
    if placements[cell_id] ~= p then
      if p.timer then pcall(p.timer.stop, p.timer); pcall(p.timer.close, p.timer) end
      p.timer = nil
      return
    end
    p.frame_idx = (p.frame_idx % #p.frames) + 1
    -- transmit_virtual = a=t frame data + a=p,U=1,p=1 in ONE atomic write:
    -- the explicit p=1 placement is replaced in place every frame, so the
    -- grid geometry stays authoritative (no re-derivation crops) and
    -- placements never accumulate (no ghost/double rendering)
    if p.renderer == "placeholder" and p.cols and p.rows then
      kitty_call_async("kitty_transmit_virtual", {
        image_id = p.image_id,
        png_b64 = p.frames[p.frame_idx],
        cols = p.cols, rows = p.rows,
      })
    else
      kitty_call_async("kitty_transmit_only", {
        image_id = p.image_id,
        png_b64 = p.frames[p.frame_idx],
      })
    end
    if p.timer then
      local d = p.delays[p.frame_idx] or 100
      pcall(p.timer.start, p.timer, d, 0, vim.schedule_wrap(tick))
    end
  end
  p.timer = vim.loop.new_timer()
  pcall(p.timer.start, p.timer, p.delays[1] or 100, 0, vim.schedule_wrap(tick))
end

function M.ensure_transmitted(cell_id, b64, callback, opts)
  opts = opts or {}
  local renderer = opts.renderer or "chafa"
  local mime = opts.mime
  local h = quick_hash(b64)
  local existing = placements[cell_id]
  if existing and existing.png_hash == h and existing.renderer == renderer then
    callback(existing.image_id)
    return
  end
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
  local id = NEXT_ID
  NEXT_ID = NEXT_ID + 1

  if renderer == "placeholder" then
    -- Real PNG via Kitty Unicode placeholder protocol — image stays
    -- anchored to buffer text because placeholders ARE text.
    log.info(string.format("placeholder: cell=%s id=%d transmitting %d b64 chars (%dx%d cells)",
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
    local p = {
      image_id = id, png_hash = h, b64 = b64,
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
    log.info(string.format("placeholder: cell=%s id=%d transmitted ok, fg=#%06x",
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
        placements[cell_id] = {
          image_id = id, png_hash = h, b64 = b64,
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
  placements[cell_id] = {
    image_id = id, png_hash = h, b64 = b64,
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
  log.info(string.format("place: cell=%s id=%d row=%d col=%d (locked)", cell_id, p.image_id, screen_row, screen_col))
end

function M.force_replace(cell_id)
  local p = placements[cell_id]
  if p then p.placed_row = nil; p.placed_col = nil end
end

-- Re-assert the explicit virtual placement of every placeholder image
-- (~60 bytes each, no image data). A placeholder cell whose image has no
-- virtual placement falls back to native-size tile mapping, which renders
-- as a randomly cropped image; this heals that within one refresh.
function M.reassert_virtual_placements()
  for _, p in pairs(placements) do
    -- animated placements self-heal on every frame tick; statics need this
    if p.renderer == "placeholder" and p.cols and p.rows and not p.timer then
      kitty_call_async("kitty_place_virtual", {
        image_id = p.image_id, cols = p.cols, rows = p.rows,
      })
    end
  end
end

local function stop_timer(p)
  if p and p.timer then
    pcall(p.timer.stop, p.timer)
    pcall(p.timer.close, p.timer)
    p.timer = nil
  end
end

function M.clear_for_cell(cell_id)
  local p = placements[cell_id]
  if not p then return end
  stop_timer(p)
  kitty_call_async("kitty_clear_image", { image_id = p.image_id })
  placements[cell_id] = nil
end

function M.clear_all()
  for k, p in pairs(placements) do
    stop_timer(p)
    placements[k] = nil
  end
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
  -- Try local mode first: backend writes kitty escapes to its own /dev/tty
  -- directly. Works when nvim is interactive in a real terminal and the
  -- backend (its child) shares the controlling tty.
  local err = client:call_sync("kitty_attach", { tty = tty_path or "/dev/tty" }, 2000)
  if not err then
    M._remote_mode = false
    log.info("kitty_attach: local mode (backend owns " .. (tty_path or "/dev/tty") .. ")")
    return
  end
  -- Local failed (headless nvim, SSH-spawn backend on a remote host, /dev/tty
  -- inaccessible, etc). Use remote mode: we encode kitty escapes in Lua (the
  -- PNG is already here from the cell-output notification) and write to the
  -- LOCAL /dev/tty directly — no backend round-trips, so plots aren't dragged
  -- back and forth across the slow SSH/srun link. We still tell the backend
  -- to enter remote mode for any code path that does go through it.
  M._remote_mode = true
  log.info("kitty_attach: remote mode — Lua-side encoding to local tty")
  client:call_sync("kitty_attach", { remote = true }, 2000)  -- best-effort; we don't depend on it
end

return M

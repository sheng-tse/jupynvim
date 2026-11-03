-- The palette: the color tokens everything jupynvim draws with, derived from
-- the colorscheme in use.
--
-- Everything is computed in libjupynvim (core/native/src/palette): this
-- module reads the colorscheme's highlight groups from Neovim, sends them as
-- one short text (kind JNV_KIND_PALETTE, a synchronous call of microseconds),
-- reads the 35 tokens back and gives them to the consumers, as a table and as
-- highlight groups. Without the library (missing, turned off, no LuaJIT) there
-- are no tokens: get() is nil and every consumer keeps the colors it had.
--
-- A consumer asks for the palette with when_ready(cb) (or get(), which starts
-- the derivation when nothing was derived yet) and repaints when the User
-- event JupynvimPalette fires, which it does once per derivation that gave
-- another palette: data = { theme_id, generation }. Highlight groups
-- JupynvimPal_<token> (fg) and JupynvimPalBg_<token> (bg) carry the same
-- colors for text mode. Nothing loads at require() or setup(): the library
-- loads (away from the UI thread) when the first consumer asks, and a
-- ColorScheme before that does no work at all. After that a ColorScheme
-- derives again, coalesced to one derivation per main-loop tick; an input
-- equal to the last one does nothing (no derivation, no highlight group, no
-- event).
--
-- The canvas, the background everything is drawn on, is Normal's background.
-- When Normal has none (a transparent colorscheme) it is the terminal's own,
-- which the terminal tells on request (OSC 11, sent with a DSR so that, on
-- Neovim 0.12, a terminal that cannot answer is known at once). Any OSC 11
-- answer is read, also those Neovim's own queries get (it asks again when the
-- terminal reports a change, Neovim 0.11 and later), and a new color derives
-- again. A terminal that reports nothing (tmux 3.5) is asked again when
-- 'background' really changes, which is when a changed terminal shows.
--
-- Two rules keep the questions from touching what the user chose. Neovim's
-- own handler (augroup nvim.tty) sets 'background' from every OSC 11 answer it
-- sees, ours included, and a colorscheme reloaded in the other kind can even
-- be dropped by it. So (1) nothing is written before VimEnter: an answer
-- handled during startup (a vim.wait in a config file, a BufReadCmd that
-- waits) reaches that handler before it has dropped itself, and would
-- override a 'background' the user set. The question waits for VimEnter
-- instead; Neovim's own VimEnter callback has run by then and, when the user
-- set 'background' in a startup file, has taken the handler away. (2) The
-- handler is taken away while a question of ours is in flight (the one at
-- VimEnter too: something may set 'background' right after it) and put back
-- when every answer to it is in, so no answer of ours moves a 'background' the
-- user chose that the terminal does not share (a light colorscheme in a dark
-- terminal). The OSC 11 answers that are not ours still reach it.
--
-- Standalone: it requires jupynvim.native and jupynvim.log lazily, never at
-- load and never in setup().
--
-- Names that start with an underscore are seams for the tests.

local M = {}

-- The 35 tokens, in the order of the library's `Token` enum and of
-- palette/tokens.json; the library's schema is checked against this list at
-- the first derivation.
M.TOKENS = {
  "canvas", "text", "text_muted", "comment", "fill", "lifted", "edge", "track", "thumb", "accent",
  "heading_h1_h3", "heading_h4_h5", "heading_h6", "math", "link", "inline_code_fg", "inline_code_bg",
  "task_checked", "task_unchecked", "alert_note", "alert_tip", "alert_important", "alert_warning",
  "alert_caution", "ok", "info", "warn", "error", "selection_border_command", "selection_border_edit",
  "selected_bg", "mark_bg", "kbd_bg", "kbd_border", "quote_bar",
}

-- The corner radius of a table's box, in pixels (palette/tokens.json).
M.RADIUS_PX = 6

local FG_GROUP, BG_GROUP, IS_TOKEN = {}, {}, { canvas = true }
for i, t in ipairs(M.TOKENS) do
  FG_GROUP[i] = "JupynvimPal_" .. t
  BG_GROUP[i] = "JupynvimPalBg_" .. t
  IS_TOKEN[t] = true
end

M._stats = {
  derives = 0, skipped_same = 0, queries = 0, held = 0, answers = 0, forwarded = 0, fallbacks = 0, events = 0, last_ms = nil,
}
local stats = M._stats

-- Module state.
--   tokens, info   the last good derivation (tokens: name -> "#rrggbb"; info: its facts);
--                  tokens is the module's own and never leaves it
--   shown          the copy of tokens that get() and when_ready give out
--   last_input     the wire text of that derivation
--   gen            how many derivations stored a palette
--   wanted         something asked for the palette (refresh() only schedules work then)
--   kick_scheduled one kick() is queued for the next tick
--   deriving       a derivation waits for the library
--   dirty          something changed since the derivation started (or none ran)
--   waiters        callbacks of when_ready
--   schema         { groups, tokens, ports } the library gave (once per process); ports[key] = { label, source }
--   err            why the last derivation failed
--   dead           why there is no library at all (cleared by refresh(), which may retry)
--   term           the terminal's own background: bg ("#rrggbb" of its last OSC 11 answer),
--                  pending (a query is in flight), deferred (a query waits for VimEnter),
--                  timer (the limit of the query, then the end of the window), failed (why
--                  the terminal's background is not known), sent_at, ms (the last round
--                  trip), muted (Neovim's own OSC 11 handler, taken away while a query of
--                  ours is in flight: the window), owed (OSC 11 answers of our queries not
--                  yet seen, which Neovim does not get), open (DSR answers of our queries
--                  not yet seen, which end the window), held (the query in flight was
--                  written without a flush of the screen, see flush_ui), fence and skip
--                  (the status answers of the gif frames written before our question,
--                  which come first and are not ours, see M._fence), cmd (the id of
--                  our own TermResponse autocmd)
--   overrides      setup()'s token -> "#rrggbb"
--   ignored        what setup() ignored, for :checkhealth
--   float          { win, buf } of the open :JupynvimPalette window
local S = {
  gen = 0, wanted = false, kick_scheduled = false, deriving = false, dirty = false,
  waiters = {}, term = { owed = 0, open = 0, skip = 0 }, overrides = {}, ignored = {},
}

local native_mod
local function native()
  if not native_mod then native_mod = require("jupynvim.native") end
  return native_mod
end

local function log(level, msg)
  local ok, L = pcall(require, "jupynvim.log")
  if ok and type(L) == "table" and type(L[level]) == "function" then pcall(L[level], msg) end
end

local function hrtime() return vim.uv.hrtime() end

-- ── the library's schema ─────────────────────────────────────────────────

-- { groups = {...37 names}, tokens = {...35 names}, ports = { key = { label =,
-- source = } } (the 19 known VS Code ports) } from the library, once per
-- process; errors (a message) when it cannot be had, when its tokens are not
-- M.TOKENS or when a port line is not `<key> <source> <label>`.
local function schema()
  if S.schema then return S.schema end
  local N = native()
  local ok, text = N.call(N.KIND.PALETTE_SCHEMA, "")
  if not ok then error("the library's palette schema failed: " .. tostring(text), 0) end
  local lines = vim.split(text, "\n", { plain = true, trimempty = true })
  local pos = 1
  local function take(word)
    local n = tonumber((lines[pos] or ""):match("^" .. word .. " (%d+)$"))
    if not n then error("the library's palette schema has no `" .. word .. "` line", 0) end
    pos = pos + 1
    local list = {}
    for i = 1, n do list[i] = lines[pos + i - 1] end
    pos = pos + n
    return list
  end
  if lines[1] ~= "JNP 1" then error("the library's palette schema is not `JNP 1`", 0) end
  pos = 2
  local groups = take("groups")
  local tokens = take("tokens")
  if #tokens ~= #M.TOKENS then
    error(("the library's palette has %d tokens, this plugin %d"):format(#tokens, #M.TOKENS), 0)
  end
  for i, t in ipairs(tokens) do
    if t ~= M.TOKENS[i] then
      error(("the library's palette token %d is %s, this plugin's is %s"):format(i, t, M.TOKENS[i]), 0)
    end
  end
  local plines = take("ports")
  local ports = {}
  for _, l in ipairs(plines) do
    local key, source, label = (type(l) == "string" and l or ""):match("^(%S+) (%S+) (.+)$")
    if not key then
      error("the library's palette schema has a port line that is not `<key> <source> <label>`: " .. tostring(l), 0)
    end
    ports[key] = { label = label, source = source }
  end
  S.schema = { groups = groups, tokens = tokens, ports = ports }
  return S.schema
end

-- The schema, or nil and why (a test seam).
function M._schema()
  local ok, res = pcall(schema)
  if ok then return res end
  return nil, tostring(res)
end

-- ── reading Neovim, writing the library's text ───────────────────────────

local function hex(n) return ("#%06x"):format(n) end

-- Is `s` well-formed UTF-8 (as Rust's std::str::from_utf8 takes it: no
-- overlong form, no surrogate, nothing past U+10FFFF)?
local function valid_utf8(s)
  local i, n = 1, #s
  while i <= n do
    local c = s:byte(i)
    if c < 0x80 then
      i = i + 1
    else
      local lo, hi, more = 0x80, 0xBF, 0
      if c >= 0xC2 and c <= 0xDF then
        more = 1
      elseif c >= 0xE0 and c <= 0xEF then
        more = 2
        if c == 0xE0 then lo = 0xA0 elseif c == 0xED then hi = 0x9F end
      elseif c >= 0xF0 and c <= 0xF4 then
        more = 3
        if c == 0xF0 then lo = 0x90 elseif c == 0xF4 then hi = 0x8F end
      else
        return false
      end
      local b = s:byte(i + 1)
      if not b or b < lo or b > hi then return false end
      for k = 2, more do
        b = s:byte(i + k)
        if not b or b < 0x80 or b > 0xBF then return false end
      end
      i = i + 1 + more
    end
  end
  return true
end
M._valid_utf8 = valid_utf8

-- The input a derivation is made from, read from Neovim: for every group of
-- the schema its fg and bg ("#rrggbb"; a linked group gives the colors it
-- resolves to; a group that does not exist is not created and gives none), the
-- colorscheme's name, 'background', the terminal's background when it is known
-- and the overrides.
function M._collect()
  local groups = schema().groups
  local out = {}
  local opts = { name = "", link = false, create = false }
  for i = 1, #groups do
    local name = groups[i]
    opts.name = name
    local h = vim.api.nvim_get_hl(0, opts)
    local fg, bg = h.fg, h.bg
    if fg or bg then out[name] = { fg = fg and hex(fg) or nil, bg = bg and hex(bg) or nil } end
  end
  local name = vim.g.colors_name
  return {
    groups = out,
    colors_name = type(name) == "string" and name or nil,
    background = vim.o.background == "light" and "light" or "dark",
    terminal = S.term.bg,
    overrides = S.overrides,
  }
end

-- The wire text of a derive request (core/native/src/palette/wire.rs) from a
-- table { groups = { name = { fg =, bg = } }, colors_name, background,
-- terminal, overrides = { token = "#rrggbb" }, set }. Groups outside the
-- schema are left out, and the rest go in the schema's order, so the same
-- table always gives the same text. Colors are "#rrggbb".
function M._input_from(t)
  local groups = schema().groups
  local name = type(t.colors_name) == "string" and vim.trim((t.colors_name:gsub("[\r\n]+", " "))) or ""
  -- the library refuses the whole input when a byte of it is not UTF-8, and
  -- only the port lookup reads the name: a name it could not read names none
  if not valid_utf8(name) then name = "" end
  local out = {
    "JNP 1",
    t.background == "light" and "kind light" or "kind dark",
    name ~= "" and ("name " .. name) or "name -",
    "term " .. (t.terminal or "-"),
  }
  if t.set then out[#out + 1] = "set" end
  local have = t.groups or {}
  for i = 1, #groups do
    local g = groups[i]
    local c = have[g]
    if c and (c.fg or c.bg) then out[#out + 1] = ("g %s %s %s"):format(g, c.fg or "-", c.bg or "-") end
  end
  local ov = t.overrides
  if ov then
    if ov.canvas then out[#out + 1] = "o canvas " .. ov.canvas end
    for i = 2, #M.TOKENS do
      local tok = M.TOKENS[i]
      if ov[tok] then out[#out + 1] = ("o %s %s"):format(tok, ov[tok]) end
    end
  end
  out[#out + 1] = ""
  return table.concat(out, "\n")
end

-- A derive result: { tokens, info } or nil and why. tokens: name -> "#rrggbb";
-- info: theme_id, kind, canvas_source, port (the key; nil without one),
-- port_label and port_source (that port's VS Code theme name and extension,
-- from the library's schema; nil without a port), sources: name ->
-- "<source>" or "<source> <detail>". A port the schema does not list is an
-- error, never a port without a name.
local function parse_output(text)
  local theme = text:match("\ntheme (%x+)\n")
  local kind = text:match("\nkind (%a+)\n")
  local canvas_source = text:match("\ncanvas_source ([^\n]+)\n")
  local port = text:match("\nport ([^\n]+)\n")
  if not (theme and kind and canvas_source and port) then return nil, "the library's palette answer has no header" end
  local tokens, sources, n = {}, {}, 0
  for name, color, source in text:gmatch("\nt (%S+) (#%x%x%x%x%x%x) ([^\n]*)") do
    tokens[name] = color
    sources[name] = source
    n = n + 1
  end
  if n ~= #M.TOKENS then
    return nil, ("the library's palette answer has %d tokens, not %d"):format(n, #M.TOKENS)
  end
  for _, t in ipairs(M.TOKENS) do
    if not tokens[t] then return nil, "the library's palette answer has no " .. t end
  end
  local meta
  if port ~= "-" then
    local oks, sch = pcall(schema)
    if not oks then return nil, tostring(sch) end
    meta = sch.ports[port]
    if not meta then
      return nil, ("the library's palette answer names port %s, which its schema does not list"):format(port)
    end
  end
  return {
    tokens = tokens,
    info = {
      theme_id = theme, kind = kind, canvas_source = canvas_source,
      port = port ~= "-" and port or nil,
      port_label = meta and meta.label or nil, port_source = meta and meta.source or nil,
      sources = sources,
    },
  }
end

-- A synchronous library call on a wire text: tokens, info (or nil and why).
function M._derive_input(s)
  local N = native()
  local ok, out = N.call(N.KIND.PALETTE, s)
  if not ok then return nil, tostring(out) end
  local r, err = parse_output(out)
  if not r then return nil, err end
  return r.tokens, r.info
end

-- ── the highlight groups and the event ───────────────────────────────────

local function set_groups(tokens)
  for i, t in ipairs(M.TOKENS) do
    local c = tokens[t]
    vim.api.nvim_set_hl(0, FG_GROUP[i], { fg = c })
    vim.api.nvim_set_hl(0, BG_GROUP[i], { bg = c })
  end
end

-- :hi clear (every :colorscheme) wipes groups a plugin defined, and the
-- palette may well be the same afterwards: look at one group.
local function groups_intact(tokens)
  local h = vim.api.nvim_get_hl(0, { name = FG_GROUP[1], link = false, create = false })
  return h.fg == tonumber(tokens.canvas:sub(2), 16)
end

-- ── the derivation ───────────────────────────────────────────────────────

-- Collect, build, call, store, set the groups, tell the consumers. The library
-- is loaded. Errors are the caller's to catch.
local function derive_now()
  local t0 = hrtime()
  local c = M._collect()
  c.set = true
  local input = M._input_from(c)
  if S.tokens and input == S.last_input then
    stats.skipped_same = stats.skipped_same + 1
    S.err = nil
    if not groups_intact(S.tokens) then set_groups(S.tokens) end
    stats.last_ms = (hrtime() - t0) / 1e6
    return true
  end
  local N = native()
  local ok, out = N.call(N.KIND.PALETTE, input)
  if not ok then
    S.err = "the library refused the palette input: " .. tostring(out)
    return false
  end
  local r, perr = parse_output(out)
  if not r then
    S.err = perr
    return false
  end
  stats.derives = stats.derives + 1
  S.err = nil
  local old_id = S.info and S.info.theme_id
  S.tokens, S.last_input = r.tokens, input
  -- what get() gives out is a copy: a consumer that writes to it (against the
  -- rule) never changes what the module compares and paints with
  local shown = {}
  for k, v in pairs(r.tokens) do shown[k] = v end
  S.shown = shown
  S.gen = S.gen + 1
  r.info.colors_name = c.colors_name
  S.info = r.info
  set_groups(r.tokens)
  stats.last_ms = (hrtime() - t0) / 1e6
  if r.info.theme_id ~= old_id then
    stats.events = stats.events + 1
    local okev, err = pcall(vim.api.nvim_exec_autocmds, "User", {
      pattern = "JupynvimPalette", modeline = false,
      data = { theme_id = r.info.theme_id, generation = S.gen },
    })
    if not okev then log("error", "palette: the JupynvimPalette event failed: " .. tostring(err)) end
  end
  return true
end

-- What info() says about the palette's state.
local function state()
  if S.tokens then return "ok", S.err end
  if S.err then return "unavailable", S.err end
  return "waiting", nil
end

function M.info()
  local i = S.info or {}
  local st, reason = state()
  -- a canvas that is a guess says why, unless something worse is to be said
  if not reason and i.canvas_source == "fallback" then
    reason = S.term.failed or "the terminal's background is not known (OSC 11)"
  end
  return {
    theme_id = i.theme_id, generation = S.gen, kind = i.kind, colors_name = i.colors_name,
    canvas_source = i.canvas_source, port = i.port, port_label = i.port_label, port_source = i.port_source,
    sources = i.sources, state = st, reason = reason, osc_ms = S.term.ms,
  }
end

local function flush()
  if #S.waiters == 0 then return end
  local list = S.waiters
  S.waiters = {}
  local tokens, info = S.shown, M.info()
  for _, cb in ipairs(list) do
    local ok, err = pcall(cb, tokens, info)
    if not ok then log("error", "palette when_ready callback: " .. tostring(err)) end
  end
end

local function normal_bg_none()
  return vim.api.nvim_get_hl(0, { name = "Normal", link = false, create = false }).bg == nil
end

-- Is the terminal's own background neither known nor given up on, and not
-- needed because the user set the canvas?
local function terminal_unknown()
  return not (S.overrides.canvas or S.term.bg or S.term.failed)
end

-- Does the next derivation need the terminal's own background for the canvas?
local function needs_terminal()
  return terminal_unknown() and normal_bg_none()
end

-- ── asking the terminal for its background (OSC 11) ──────────────────────

-- Who takes the query: nvim_ui_send (Neovim 0.12) reaches every terminal UI,
-- also a remote one; before it, our own stdout is the terminal only when the
-- UI on channel 1 is a terminal (Neovim's own startup query does the same).
-- Returns the way and how many terminals will answer (each UI with a
-- terminal of its own does); nil, 0 when no terminal UI can take the query
-- (headless, a GUI, embedded).
local function writer()
  local has_send = vim.api.nvim_ui_send ~= nil
  local n = 0
  for _, ui in ipairs(vim.api.nvim_list_uis()) do
    if ui.stdout_tty then
      if has_send then
        n = n + 1
      elseif ui.chan == 1 then
        return "stdout", 1
      end
    end
  end
  if n > 0 then return "ui_send", n end
  return nil, 0
end

-- True when a UI takes the query.
function M._has_tty_ui() return writer() ~= nil end

-- Neovim 0.12 hands what nvim_ui_send is given to the UIs with the next flush
-- of the screen, not at the call. A main loop that does not get to one (jupynvim's
-- own vim.wait in a blocking call, heavy work in a handler) holds the question
-- back while the window's limit already runs; the limit then ends the window
-- before the question has been written, and the answer, when it comes, reaches
-- Neovim's handler. So the screen is flushed right after the write.
-- (nvim__redraw is the lighter call; ":redraw" is there for a Neovim without it.)
--
-- The flush redraws the screen first, and a redraw is not harmless at every
-- moment. While messages that scrolled the screen wait for their hit-enter
-- prompt (an error in a plugin file at start-up, a warning of two lines), it
-- clears them and drops the prompt: they would never be drawn. And while
-- Neovim starts (VimEnter, before its main loop) it draws the screen before
-- its time, under what a later VimEnter autocmd draws (a dashboard). So a
-- question asked then is written without the flush (held): it leaves with
-- Neovim's own next flush (the prompt, the first screen, the start of a
-- vim.wait), and its limit counts again from the main loop (see hold_limit).
local function flush_ui()
  if not pcall(vim.api.nvim__redraw, { flush = true }) then pcall(vim.cmd, "redraw") end
end

-- Do messages that scrolled the screen wait for their hit-enter prompt? A seam
-- for the tests.
function M._msgs_waiting() return vim.fn.state("s") ~= "" end

-- Write `s` to the terminal; the number of terminals it reached (each of them
-- answers), false when it was not written. This is the one terminal write
-- outside notebook/image.lua: the nearest terminal must answer (tmux for its
-- pane, which knows what is really underneath), so it is never wrapped for
-- tmux, and it writes only while a terminal UI is attached. `noflush`: the
-- question is asked while Neovim starts (see flush_ui). The second value is
-- true when the write waits in Neovim for its next flush of the screen.
function M._send(s, noflush)
  local w, n = writer()
  if w == "ui_send" then
    if not pcall(vim.api.nvim_ui_send, s) then return false end
    local okm, waiting = pcall(M._msgs_waiting)
    if noflush or not okm or waiting then return n, true end
    flush_ui()
    return n, false
  end
  if w == "stdout" then
    return (pcall(function()
      io.stdout:write(s)
      io.stdout:flush()
    end)) and 1 or false
  end
  return false
end

-- How long a query is waited for. Tests set it.
M._osc_timeout_ms = 1000

-- How long the window stays open after an answer when the DSR answer that
-- would close it does not come (Neovim 0.11 hands none over), and after the
-- last DSR answer while an OSC 11 answer is still owed (a terminal chain that
-- answers out of order). Tests set it.
M._grace_ms = 100

local QUERY = "\027]11;?\007\027[5n" -- OSC 11 query, then a DSR (ESC [ 5 n)

-- How long a question waits for the terminal to read what was written before
-- it (the gif frames of notebook/image.lua still in flight; see M._fence)
-- before its own limit starts to count. Tests set it.
M._fence_limit_ms = 30000

-- A DSR answer carries nothing to say whose request it answers, and
-- notebook/image.lua follows every gif frame with one: the answers of the
-- frames still in flight when our question is written come before ours.
-- Taken for ours they close the question early, and the OSC 11 answer, which
-- then comes after the window has ended, reaches Neovim's own handler (the
-- bug the window exists to prevent). So the question is asked behind a fence
-- of image.lua's (status_fence): its marker is written first, and the status
-- answers read before it is answered are not ours. Returns passed, owed (see
-- there), or nothing when no frame can be in flight (the module is not
-- loaded). A seam for the tests.
function M._fence()
  local img = package.loaded["jupynvim.notebook.image"]
  if type(img) ~= "table" or type(img.status_fence) ~= "function" then return nil end
  local ok, passed, owed = pcall(img.status_fence)
  if ok and type(passed) == "function" then return passed, tonumber(owed) or 0 end
end

-- Has Neovim finished starting (VimEnter has fired)? A seam for the tests,
-- which run before it.
function M._started() return vim.v.vim_did_enter == 1 end

local kick

-- The terminal told, or failed to tell, its background: derive again when
-- someone asked for the palette (a query setup() sent has nobody waiting yet).
local function terminal_settled()
  S.dirty = true
  if S.wanted then kick() end
end

local function stop_timer()
  local t = S.term.timer
  S.term.timer = nil
  if t then
    pcall(function()
      t:stop()
      if not t:is_closing() then t:close() end
    end)
  end
end

-- ── Neovim's own handler for the terminal's background ───────────────────
-- Neovim (augroup nvim.tty, a TermResponse autocmd) sets 'background' from the
-- luminance of every OSC 11 answer it sees, ours included, and stays doing so
-- for the session unless 'background' was set from a startup file before
-- VimEnter. An answer to a question of ours must not move a 'background' the
-- user chose that the terminal does not share (a light colorscheme in a dark
-- terminal): the reload of the colorscheme in the other kind is visible, and
-- one that sets 'background' itself is dropped by Neovim then. So that
-- handler, and only that one (Neovim's other TermResponse autocmds, the probe
-- for truecolor among them, stay where they are), is taken away from the
-- moment a question is written until every answer to it is in: the window.
--
-- The answers that are not ours still belong to Neovim, and it must get them:
-- its own startup question is answered only after VimEnter on Neovim 0.11
-- (and on a slow link on 0.12), and a terminal that reports a change of theme
-- makes Neovim ask again. An answer is the terminal's color, whoever asked, so
-- which answer is whose does not matter, only how many: of the OSC 11 answers
-- in the window the first as many as we asked for (once per terminal UI) are
-- ours and go to the palette alone, any other is given to the handler that was
-- taken away. The window ends when the DSR answers that close our questions
-- are in and no OSC 11 answer is still owed (Neovim 0.12; 0.11 does not hand a
-- DSR answer over, and a terminal can be silent), or a moment after the last
-- answer or the last DSR, or at the limit. Then the handler is put back from
-- the next tick, never inside the TermResponse that ends the window (an
-- autocmd added during an event may run for that same event). The question
-- itself is written at once and not at the next flush of the screen (see
-- flush_ui), or the limit would run while it waits; one that cannot be (held)
-- has its limit counted again from the main loop (see hold_limit).

-- The description of Neovim's handler for the background; the same in Neovim
-- 0.11 and 0.12. What the handler is called is all that tells it from the
-- probe for truecolor (no description) in the same group.
local NEOVIM_HANDLER = "^Update the value of 'background' automatically"

-- Take Neovim's handler for the terminal's background out of augroup
-- nvim.tty. Nothing to do when there is none (the user set 'background' in a
-- startup file, or this Neovim has no such group), and nothing is touched when
-- it cannot be put back (its callback is not a Lua function).
local function mute_neovim()
  if S.term.muted then return end
  local ok, list = pcall(vim.api.nvim_get_autocmds, { group = "nvim.tty", event = "TermResponse" })
  if not ok then return end
  local found = {}
  for _, a in ipairs(list) do
    if type(a.desc) == "string" and a.desc:find(NEOVIM_HANDLER) then
      if type(a.callback) ~= "function" then return end
      found[#found + 1] = a
    end
  end
  local saved = {}
  for _, a in ipairs(found) do
    if pcall(vim.api.nvim_del_autocmd, a.id) then
      saved[#saved + 1] = { callback = a.callback, desc = a.desc, once = a.once }
    end
  end
  if #saved > 0 then S.term.muted = saved end
end

-- Put it back, the way Neovim defines it (nested: its handler sets
-- 'background', which must run the colorscheme and OptionSet autocmds), and
-- ours again after it, as it was: Neovim's runs first on every answer, so
-- that what we read afterwards (the changes of 'background' it makes) is
-- ordered the same way as before. Not while another question is in flight:
-- its end puts it back. (Put back, it runs after the TermResponse autocmds
-- made since start-up, where it ran before them.)
local register_term_response
local function unmute_neovim()
  local saved = S.term.muted
  if not saved or S.term.pending or S.term.owed > 0 or S.term.open > 0 then return end
  S.term.muted = nil
  for _, a in ipairs(saved) do
    local ok, err = pcall(vim.api.nvim_create_autocmd, "TermResponse", {
      group = "nvim.tty", callback = a.callback, desc = a.desc, once = a.once, nested = true,
    })
    if not ok then log("error", "palette: could not put Neovim's TermResponse handler back: " .. tostring(err)) end
  end
  register_term_response()
end

-- Give an OSC 11 answer that is not ours to the handler that was taken away,
-- as if it had seen it. On the next tick, outside of any autocmd, so that what
-- it sets runs the colorscheme and OptionSet autocmds.
local function forward(ev)
  local saved = S.term.muted
  if not saved then return end
  stats.forwarded = stats.forwarded + 1
  vim.schedule(function()
    for _, a in ipairs(saved) do
      local ok, err = pcall(a.callback, ev)
      if not ok then log("error", "palette: Neovim's TermResponse handler failed: " .. tostring(err)) end
    end
  end)
end

-- The one timer: the limit of a question, then, after an answer, the moment
-- the window ends if nothing more comes. A timer that fires late says the main
-- loop was blocked after the question was written (a colorscheme that does heavy
-- work, a slow plugin): what the terminal said meanwhile is queued and may not
-- have been read yet. Neovim usually reads it before the callback of the overdue
-- timer, but that order is not promised (it depends on how the loop's queues
-- were filled), so `fn` waits one more moment (once) before the window forgets
-- what it is owed. (This is not what keeps a question from being late: that is
-- the write, see flush_ui, and for a question held, hold_limit.)
local STALL_MS = 20

local function arm(ms, fn, extended)
  stop_timer()
  local timer = vim.uv.new_timer()
  -- libuv counts a timer from the time it cached when the loop last ran, which
  -- is old after a long callback: a limit started then would run out early.
  -- Count from the call.
  vim.uv.update_time()
  local due = hrtime() + ms * 1e6
  S.term.timer = timer
  timer:start(ms, 0, vim.schedule_wrap(function()
    if S.term.timer ~= timer then return end -- stopped, or armed again, meanwhile
    S.term.timer = nil
    pcall(function() if not timer:is_closing() then timer:close() end end)
    if not extended and (hrtime() - due) / 1e6 > STALL_MS then return arm(M._grace_ms, fn, true) end
    fn()
  end))
end

-- Nothing more of ours is to come: forget what was still owed, and give
-- Neovim its handler back.
local function end_window()
  stop_timer()
  S.term.owed, S.term.open = 0, 0
  S.term.fence, S.term.skip = nil, 0
  if S.term.muted then vim.schedule(unmute_neovim) end
end

-- Forget a query in flight (its answer, if it still comes, is read as any other).
local function cancel_query()
  S.term.pending = false
  S.term.held = nil
  end_window()
end

-- The canvas cannot be had from the terminal: say why, unless a color from an
-- earlier answer is still there (a terminal that stays silent when asked again
-- keeps its last color).
local function give_up(why)
  if S.term.bg then return end
  S.term.failed = why
  stats.fallbacks = stats.fallbacks + 1
end

-- The limit of the question in flight, counted from now: when it runs out
-- unanswered, the window ends and the canvas falls back.
local function arm_limit()
  local limit = M._osc_timeout_ms
  arm(limit, function()
    -- The terminal has not read what was written before our question yet
    -- (frames in flight, see M._fence): it cannot have answered, and its
    -- limit counts from when the fence is passed (see on_term_response).
    if S.term.pending and S.term.fence and not S.term.fence()
        and (hrtime() - (S.term.sent_at or hrtime())) / 1e6 < M._fence_limit_ms then
      return arm_limit()
    end
    local was_pending = S.term.pending
    S.term.pending = false
    S.term.held = nil
    end_window()
    if was_pending then
      give_up(("the terminal did not answer the query for its background (OSC 11) within %d ms"):format(limit))
      terminal_settled()
    end
  end)
end

-- A question held (written without the flush, see flush_ui) leaves with
-- Neovim's next flush of the screen, which can be later than its limit: a
-- VimEnter autocmd after ours that works for a while, a hit-enter prompt the
-- user reads. Neovim's main loop flushes before it waits for a key, and
-- SafeState comes just before that wait (and after the prompt), ahead of the
-- callback of a limit that ran out meanwhile. So at the next SafeState a
-- question still unanswered gets its whole limit again, counted from there,
-- and the answer that comes after the late write is still read as ours. The
-- first limit stays the bound where no SafeState comes (Terminal mode).
local function hold_limit()
  pcall(function()
    local g = vim.api.nvim_create_augroup("jupynvim_palette_held", { clear = true })
    vim.api.nvim_create_autocmd("SafeState", {
      group = g, once = true,
      callback = function()
        if S.term.pending and S.term.held then
          S.term.held = nil
          arm_limit()
        end
      end,
    })
  end)
end

-- Write the query now, with Neovim's handler away until every answer to it is
-- in. True when a query is in flight (its answer, the terminal's refusal or
-- the timer calls for a derivation again); false when it cannot be asked (no
-- terminal UI, a write that failed): the canvas falls back and info() says why.
-- `noflush`: asked while Neovim starts (see flush_ui).
local function send_query(noflush)
  if not M._has_tty_ui() then
    give_up("no terminal is attached to ask for its background (OSC 11)")
    return false
  end
  local passed, owed = M._fence()
  local written, held = M._send(QUERY, noflush)
  if not written then
    give_up("the query for the terminal's background (OSC 11) could not be written")
    return false
  end
  -- every terminal UI answers (a stand-in for the writer says true: one)
  local n = type(written) == "number" and written or 1
  stats.queries = stats.queries + 1
  if held then stats.held = stats.held + 1 end
  S.term.pending = true
  S.term.held = held and true or nil
  S.term.sent_at = hrtime()
  S.term.owed, S.term.open = S.term.owed + n, S.term.open + n
  if passed and not (passed() and (owed or 0) == 0) then
    S.term.fence, S.term.skip = passed, S.term.skip + (owed or 0)
  end
  -- the answer comes through the event loop, never before this returns
  mute_neovim()
  arm_limit()
  if held then hold_limit() end
  return true
end

-- The question that waited for VimEnter. Neovim's own VimEnter callback has
-- run by now (it was defined earlier), and took its handler away when the
-- user set 'background' in a startup file before it. A 'background' set after
-- it (a VimEnter autocmd made later, a scheduled callback, UIEnter) leaves the
-- handler alive, so this question is sent like any other, with the handler
-- away: its answer must not undo what is set right after VimEnter. Neovim's
-- own answer to its startup question, which Neovim 0.11 reads only now (and
-- 0.12 after a slow link), is not ours and reaches the handler all the same.
-- Neovim is still starting: the question is held (see flush_ui).
local function on_vim_enter()
  S.term.deferred = false
  if S.term.pending then return end
  if needs_terminal() then
    if not send_query(true) and S.wanted then terminal_settled() end
  elseif S.wanted then
    -- learned meanwhile, or not needed after all: whoever waits goes on
    terminal_settled()
  end
end

-- Ask the terminal for its background. True when a query is in flight or
-- will be (its answer, the terminal's refusal or the timer calls for a
-- derivation again); at most one is. Before VimEnter nothing is written: the
-- question waits for it (see the top of this file). False when it cannot be
-- asked. `noflush`: see send_query.
local function start_query(noflush)
  if S.term.pending or S.term.deferred then return true end
  if not M._started() and M._has_tty_ui() then
    S.term.deferred = true
    local group = vim.api.nvim_create_augroup("jupynvim_palette", { clear = false })
    vim.api.nvim_create_autocmd("VimEnter", { group = group, once = true, callback = on_vim_enter })
    return true
  end
  return send_query(noflush)
end

-- "#rrggbb" from an OSC 11 answer, as Neovim hands it over (ESC ] 11 ; rgb:R/G/B
-- or rgba:R/G/B/A, each channel 1 to 4 hex digits, scaled to 8 bits; the alpha
-- is ignored), or nil.
function M._parse_osc11(seq)
  if type(seq) ~= "string" then return nil end
  seq = seq:gsub("\007$", ""):gsub("\027\\$", "")
  local r, g, b = seq:match("^\027%]11;rgb:(%x+)/(%x+)/(%x+)$")
  if not r then
    local a
    r, g, b, a = seq:match("^\027%]11;rgba:(%x+)/(%x+)/(%x+)/(%x+)$")
    if not a or #a > 4 then return nil end
  end
  if not (r and #r <= 4 and #g <= 4 and #b <= 4) then return nil end
  local function channel(c) return math.floor(tonumber(c, 16) / (16 ^ #c - 1) * 255 + 0.5) end
  return ("#%02x%02x%02x"):format(channel(r), channel(g), channel(b))
end

-- TermResponse: the terminal's answers, also those Neovim's own queries get.
-- Every OSC 11 answer is read: it ends a pending query, else it re-derives
-- when the color is new and Normal has no background of its own. While the
-- window is open (Neovim's handler is away) the first as many as were asked for
-- are ours and Neovim does not get them; any other is given to Neovim's
-- handler (see the top of this section). The DSR answer (ESC [ 0 n) closes one
-- of our questions. One that had no OSC 11 answer before it was most likely not
-- answered by a terminal that does not report its background, and the canvas
-- falls back at once; but a terminal chain may answer out of order (Neovim's own
-- handler allows for it), so the window stays open a moment for the OSC 11
-- answer that is still owed, which is ours if it comes, and the canvas is
-- derived again from it. The last DSR ends the window, else that moment does.
-- Anything else is none of our business.
local function on_term_response(ev)
  local seq = ev and ev.data
  if type(seq) == "table" then seq = seq.sequence end
  if type(seq) ~= "string" then return end
  if seq:find("^\027P>|") then
    -- the marker's answer (image.lua's fence): the question was written after
    -- it, so everything the terminal answers from here is ours, and its limit
    -- counts from now. (On the next tick: image.lua's own autocmd for this
    -- answer may run after this one.)
    if S.term.fence then
      vim.schedule(function()
        if S.term.fence and S.term.fence() then
          S.term.fence = nil
          if S.term.pending then arm_limit() end
        end
      end)
    end
    return
  end
  if seq == "\027[0n" then
    if S.term.open > 0 then
      if S.term.skip > 0 then
        S.term.skip = S.term.skip - 1
        return
      end
      if S.term.fence then
        if not S.term.fence() then return end
        S.term.fence = nil
      end
      local silent = S.term.owed >= S.term.open
      S.term.open = S.term.open - 1
      if S.term.open == 0 then
        if S.term.owed > 0 then arm(M._grace_ms, end_window) else end_window() end
      end
      if silent and S.term.pending then
        S.term.pending = false
        give_up("the terminal does not report its background (OSC 11)")
        terminal_settled()
      end
    end
    return
  end
  local color = M._parse_osc11(seq)
  if not color then return end
  stats.answers = stats.answers + 1
  if S.term.owed > 0 then
    S.term.owed = S.term.owed - 1
    -- the answer that was still owed after the last DSR: nothing more is to come
    if S.term.owed == 0 and S.term.open == 0 then end_window() end
  else
    forward(ev)
  end
  local was = S.term.bg
  S.term.bg, S.term.failed = color, nil
  -- more of ours may follow (the DSR, the answer of another terminal): the
  -- window stays open for them for a moment, not for the whole limit
  if S.term.open > 0 then arm(M._grace_ms, end_window) end
  if S.term.pending then
    S.term.ms = (hrtime() - (S.term.sent_at or hrtime())) / 1e6
    S.term.pending = false
    terminal_settled()
  elseif color ~= was and normal_bg_none() then
    M.refresh()
  end
end

-- Our TermResponse autocmd, in the palette's augroup: (re)created, so that it is
-- the last one for the event.
register_term_response = function()
  if S.term.cmd then pcall(vim.api.nvim_del_autocmd, S.term.cmd) end
  local group = vim.api.nvim_create_augroup("jupynvim_palette", { clear = false })
  S.term.cmd = vim.api.nvim_create_autocmd("TermResponse", {
    group = group,
    callback = function(ev) on_term_response(ev) end,
  })
end

-- Ask the terminal again, because 'background' really changed and the canvas
-- is the terminal's: a terminal that reports its changes (DEC mode 2031) is
-- read through Neovim's own re-query, but one that does not (tmux 3.5)
-- tells nobody, and the color from the last answer would stay for the whole
-- session. Nothing is asked when the canvas does not come from the terminal
-- (Normal has a background, setup() gave one), when nothing is known of the
-- terminal yet (the first derivation asks), or when the terminal was found
-- unable to answer. A question in flight is not asked twice.
local function ask_again()
  if S.overrides.canvas or not S.term.bg or not normal_bg_none() then return end
  start_query()
end

-- The OptionSet handler's body ('background' changed from `old` to `new`). The
-- same value is nothing: Neovim's own handler sets 'background' on every
-- answer. A real change derives again (the kind follows 'background') and asks
-- the terminal again (see ask_again), which cannot undo it: Neovim's handler
-- is away while the question is in flight. Both happen on the next tick, when
-- the answer to a theme report that moved 'background' has been read (it is
-- the same event, and the color it brought is then the one known) and the
-- colorscheme has been reloaded for the new value.
function M._on_option_background(old, new)
  if old == new then return end
  local answers = stats.answers
  vim.schedule(function()
    -- an answer came meanwhile (the change was Neovim following a report): the color is fresh
    if stats.answers == answers then ask_again() end
    M.refresh()
  end)
end

-- One derivation, or a note that one is due. At most one runs at a time; a
-- trigger meanwhile only sets `dirty`, and the derivation starts over when it
-- ends.
kick = function()
  if S.deriving then
    S.dirty = true
    return
  end
  -- wait for a question in flight about a canvas that comes from the terminal
  if (needs_terminal() or (S.term.pending and not S.overrides.canvas and normal_bg_none())) and start_query() then
    return
  end
  S.deriving = true
  S.dirty = false
  local okw, errw = pcall(function()
    native().when_ready(function(ok, st)
      S.deriving = false
      if not ok then
        S.dead = (type(st) == "table" and st.reason) or "libjupynvim is not available"
        S.err = S.dead
        S.dirty = false
        flush()
        return
      end
      S.dead = nil
      local okd, derived = pcall(derive_now)
      if not okd then S.err = tostring(derived) end
      -- something changed meanwhile: derive again before anyone is told
      if S.dirty then return kick() end
      flush()
    end)
  end)
  if not okw then
    S.deriving = false
    S.dead = "libjupynvim could not be asked: " .. tostring(errw)
    S.err = S.dead
    flush()
  end
end

-- A waiter that came while nothing changed: answer on the next tick.
local function settle()
  if S.deriving or #S.waiters == 0 then return end
  if S.dirty or not S.tokens then return kick() end
  flush()
end

-- ── the public interface ─────────────────────────────────────────────────

-- cb(tokens | nil, info) on the main loop (never in a fast event, never before
-- when_ready returns) once the palette is derived for what Neovim has now; nil
-- tokens when there is no library or the derivation failed (info().state and
-- info().reason say why).
function M.when_ready(cb)
  if type(cb) ~= "function" then error("jupynvim.palette.when_ready: cb must be a function", 2) end
  -- Neovim's API is not for a fast event (a luv callback): ask on the main loop.
  if vim.in_fast_event() then
    vim.schedule(function() M.when_ready(cb) end)
    return
  end
  S.waiters[#S.waiters + 1] = cb
  S.wanted = true
  if S.deriving then return end
  if S.tokens and not S.dirty then
    vim.schedule(settle)
  else
    kick()
  end
end

-- The tokens ({ canvas = "#222436", ... }; the same table until the palette
-- changes), or nil. Read only: it is shared by every consumer, so a write
-- changes what they read until the next derivation gives a new table; the
-- module itself keeps its own copy and does not see it. Nil also starts the
-- derivation (as when_ready without a callback) when nothing was derived yet.
function M.get()
  local t = S.shown
  if t then return t end
  S.wanted = true
  if not S.deriving and not S.dead then
    if vim.in_fast_event() then vim.schedule(kick) else kick() end
  end
  return nil
end

-- Something that feeds the palette changed (a colorscheme, 'background', the
-- terminal's answer): derive again in the next tick if anything asked for the
-- palette, else just remember that it is stale.
function M.refresh()
  S.dirty = true
  S.dead = nil
  if S.wanted and not S.kick_scheduled and not S.deriving then
    S.kick_scheduled = true
    vim.schedule(function()
      S.kick_scheduled = false
      if S.dirty then kick() end
    end)
  end
end

-- #rrggbb for `fg` on `bg` (text on its own fill): fg itself when it meets
-- `target` (default 4.5) against bg, else whichever of the palette's text and
-- canvas contrasts more with bg (white or black without a palette). Nil
-- without the library, and nil when fg or bg is not a string (a color a user
-- gave may be missing) or target is not a number. It loads the library
-- synchronously when it is not loaded yet, so a consumer calls it after its
-- when_ready.
function M.readable(fg, bg, target)
  if type(fg) ~= "string" or type(bg) ~= "string" or (target ~= nil and type(target) ~= "number") then return nil end
  local N = native()
  local ok, out = N.call(N.KIND.PALETTE_READABLE, target and ("%s %s %s"):format(fg, bg, target) or (fg .. " " .. bg))
  if not ok then return nil end
  return out:sub(1, 7)
end

-- setup({ palette = ... }): opts is a table of token (or canvas) = "#rrggbb",
-- each one winning over everything the colorscheme gives. An entry that is not
-- a token or not a color is ignored, with one warning naming all of them.
-- Loads nothing.
function M.setup(opts)
  local overrides, bad = {}, {}
  if opts ~= nil and opts ~= false and type(opts) ~= "table" then
    bad[#bad + 1] = "the setting (a table is wanted)"
  elseif type(opts) == "table" then
    local keys = {}
    for k in pairs(opts) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do
      local v = opts[k]
      if v == false then
        -- unset
      elseif type(k) ~= "string" or not IS_TOKEN[k] then
        bad[#bad + 1] = ("%s (not a palette token)"):format(tostring(k))
      elseif type(v) ~= "string" or not v:match("^#%x%x%x%x%x%x$") then
        bad[#bad + 1] = ("%s (not a #rrggbb color)"):format(k)
      else
        overrides[k] = v:lower()
      end
    end
  end
  if #bad > 0 then
    vim.notify("jupynvim: palette: ignored " .. table.concat(bad, ", "), vim.log.levels.WARN)
  end
  S.overrides = overrides
  S.ignored = bad
  S.last_input = nil
  local group = vim.api.nvim_create_augroup("jupynvim_palette", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function() M.refresh() end,
  })
  vim.api.nvim_create_autocmd("OptionSet", {
    group = group,
    pattern = "background",
    callback = function() M._on_option_background(vim.v.option_old, vim.v.option_new) end,
  })
  S.term.cmd = nil -- it went with the group
  register_term_response()
  M.refresh()
  -- Ask the terminal now when the canvas needs it and nothing is known of it,
  -- so that the answer is there when a consumer wants the palette. Not when
  -- Normal has a background: an opaque canvas never needs the terminal's, and
  -- a switch to a transparent colorscheme asks then. Before VimEnter nothing
  -- is written: look again at VimEnter (the colorscheme may still change
  -- before it), when Neovim's own handler is away if the user set
  -- 'background'. Nothing is derived and nothing is loaded by it. After
  -- VimEnter this is a setup() from a VimEnter autocmd or a plugin manager:
  -- Neovim may still be starting, so the question is held (see flush_ui).
  S.term.deferred = false -- the VimEnter autocmd of an earlier setup() went with the group
  if M._has_tty_ui() then
    if M._started() then
      if needs_terminal() then start_query(true) end
    else
      S.term.deferred = true
      vim.api.nvim_create_autocmd("VimEnter", { group = group, once = true, callback = on_vim_enter })
    end
  end
end

-- As if the terminal answered OSC 11 with `color` ("#rrggbb"; nil forgets the
-- answer, and a query in flight). A changed color derives again when Normal has
-- no background of its own.
function M._set_terminal_bg(color)
  local was, was_pending = S.term.bg, S.term.pending
  cancel_query()
  S.term.bg = color and color:lower() or nil
  S.term.failed = nil
  if (S.term.bg ~= was or was_pending) and normal_bg_none() then M.refresh() end
end

-- ── :JupynvimPalette ─────────────────────────────────────────────────────

-- Where the canvas came from, in words.
local CANVAS_FROM = {
  ["Normal.bg"] = "Normal.bg",
  terminal = "the terminal",
  fallback = "the fallback (a guess)",
  override = "setup()",
}

local BLOCKS = ("\226\150\136"):rep(6) -- six full blocks; 18 bytes
local FLOAT_NS = vim.api.nvim_create_namespace("jupynvim_palette_show")

local function close_float(f)
  if f and S.float ~= f then return end
  f = S.float
  S.float = nil
  if f and vim.api.nvim_win_is_valid(f.win) then pcall(vim.api.nvim_win_close, f.win, true) end
end

-- The float: a header line, then a line per token with its color as six
-- blocks, its name, its hex and where it came from.
local function open_float(tokens, info)
  close_float()
  local lines = {
    ("colorscheme %s (%s), background %s, canvas %s from %s"):format(
      info.colors_name or "none", info.port_label or "no known port", info.kind or "dark", tokens.canvas,
      CANVAS_FROM[info.canvas_source] or tostring(info.canvas_source)),
  }
  for _, t in ipairs(M.TOKENS) do
    lines[#lines + 1] = ("%s  %-24s  %s  %s"):format(BLOCKS, t, tokens[t], info.sources and info.sources[t] or "")
  end
  local width = 0
  for _, l in ipairs(lines) do width = math.max(width, vim.fn.strdisplaywidth(l)) end
  width = math.min(width, math.max(vim.o.columns - 4, 20))
  local height = math.min(#lines, math.max(vim.o.lines - 4, 3))
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  for i = 1, #M.TOKENS do
    vim.api.nvim_buf_set_extmark(buf, FLOAT_NS, i, 0, { end_col = #BLOCKS, hl_group = FG_GROUP[i] })
  end
  vim.bo[buf].modifiable = false
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor", style = "minimal", border = "rounded",
    title = " jupynvim palette ", title_pos = "center",
    width = width, height = height,
    row = math.max(math.floor((vim.o.lines - height) / 2) - 1, 0),
    col = math.max(math.floor((vim.o.columns - width) / 2) - 1, 0),
  })
  -- the panel of spec section 7: fill, the edge as border, the title in accent and bold
  vim.api.nvim_set_hl(0, "JupynvimPalTitle", { fg = tokens.accent, bold = true })
  vim.wo[win].winhighlight = "NormalFloat:JupynvimPalBg_fill,FloatBorder:JupynvimPal_edge,FloatTitle:JupynvimPalTitle"
  vim.wo[win].wrap = false
  local f = { win = win, buf = buf }
  S.float = f
  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, function() close_float(f) end, { buffer = buf, nowait = true, silent = true })
  end
  -- leaving it closes it (a float is for a look)
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = buf, once = true,
    callback = function() vim.schedule(function() close_float(f) end) end,
  })
end

-- :JupynvimPalette: the tokens, and where each came from, in a float.
function M.show()
  M.when_ready(function(tokens, info)
    if not tokens then
      if S.dead then
        vim.notify(("jupynvim: the palette needs libjupynvim (%s); see :checkhealth jupynvim"):format(
          info.reason or "it is not available"), vim.log.levels.WARN)
      else
        vim.notify(("jupynvim: the palette could not be derived (%s); see :checkhealth jupynvim"):format(
          info.reason or "no reason given"), vim.log.levels.WARN)
      end
      return
    end
    local ok, err = pcall(open_float, tokens, info)
    if not ok then vim.notify("jupynvim: could not show the palette: " .. tostring(err), vim.log.levels.ERROR) end
  end)
end

-- ── :checkhealth ─────────────────────────────────────────────────────────

-- A synchronous derivation from what Neovim and the terminal say right now,
-- for :checkhealth (the library is loaded). It makes nothing current, sets no
-- group and fires no event. { tokens, info, guess, overrides, ignored } (guess:
-- why the canvas had to be guessed, or nil; overrides: the names setup() set,
-- canvas first; ignored: what setup() ignored), or nil and why.
function M._derive_now_for_health()
  local okc, c = pcall(M._collect)
  if not okc then return nil, tostring(c) end
  local ok, tokens, info = pcall(function() return M._derive_input(M._input_from(c)) end)
  if not ok then return nil, tostring(tokens) end
  if not tokens then return nil, tostring(info) end
  info.colors_name = c.colors_name
  local names = {}
  if c.overrides.canvas then names[1] = "canvas" end
  for i = 2, #M.TOKENS do
    if c.overrides[M.TOKENS[i]] then names[#names + 1] = M.TOKENS[i] end
  end
  local guess
  if info.canvas_source == "fallback" then
    guess = S.term.failed or (S.term.pending and "the terminal has not answered the query for its background (OSC 11) yet")
      or (S.term.deferred and "the terminal is asked for its background (OSC 11) once Neovim has started")
      or "the terminal has not been asked for its background (OSC 11)"
  end
  return { tokens = tokens, info = info, guess = guess, overrides = names, ignored = vim.deepcopy(S.ignored) }
end

return M

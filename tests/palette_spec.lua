-- The palette seen from Lua: lua/jupynvim/palette.lua, which derives the
-- color tokens everything jupynvim draws with from the colorscheme in use
-- through libjupynvim.
--
--   nvim --headless -u NONE -c "luafile tests/palette_spec.lua" -c "cquit 3"
--
-- A  fixtures through the library: the wire text Lua builds, and the 35
--    tokens each case of tests/fixtures/palette gives
-- B  collection from Neovim's highlight groups (a linked group resolves),
--    the tokens, the JupynvimPal_ groups, the User event, get(), when_ready
--    (also from a fast event, while a derivation waits, and when one fails)
-- E  setup() overrides and the notice for entries it ignores
-- F  readable() through the library, and its cost
-- G  the path without the library, and get() from a fast event first
-- H  budgets: setup() loads nothing and costs little, an identical input
--    does no work, get() with tokens present
-- I  the cost of a changed refresh
--
-- C  the triggers: ColorScheme, a change of 'background' (the handler's
--    body, since OptionSet does not fire while Neovim starts), typing, a
--    ColorScheme before anything asked
-- D  OSC 11: the parser, one query in flight, a DSR first, no answer (the
--    limit counted from the call, also after a long callback), no terminal
--    UI, an answer that comes late, other answers
-- J  :checkhealth jupynvim: the palette's section
-- K  :JupynvimPalette
-- L  the known ports: the schema lists them (key, label, source), a
--    derivation names its port by all three, a wrong port list is a schema
--    error
-- M  review fixes: a colorscheme name that is not UTF-8, readable() with a
--    color that is not a string, a token table a consumer wrote to, what
--    :JupynvimPalette and :checkhealth say when the library is not to blame
-- N  Neovim's own handler for the terminal's background (augroup nvim.tty):
--    away while a question is in flight, the others in the group left alone,
--    back after; the question that waits for VimEnter
-- P  the window a question opens: which OSC 11 answer is whose (the first as
--    many as were asked for are ours, any other goes to Neovim's handler),
--    what ends it (the DSR answers, a moment after the last answer, the
--    limit), several terminal UIs, a main loop blocked past the limit, a
--    terminal that answers the DSR before the OSC 11 answer, the write
--    being flushed
-- O  the README's list of ports
--
-- From C on the terminal is simulated: P._send records what would be written,
-- P._has_tty_ui is a flag, and the terminal's answers are TermResponse events.
--
-- It needs the library, which section 1 of tests/run_all.sh builds: cd core
-- && cargo build --release. A missing one is a failure, never a skip.

local fails = 0
local function chk(name, cond, detail)
  if cond then io.write("  ok " .. name .. "\n")
  else io.write("FAIL " .. name .. (detail and ("  -- " .. tostring(detail)) or "") .. "\n"); fails = fails + 1 end
end
local function finish()
  if fails == 0 then
    io.write("\nALL PALETTE CHECKS PASSED\n")
    vim.cmd("qa!")
  else
    io.write(("\n%d PALETTE CHECKS FAILED\n"):format(fails))
    vim.cmd("cquit 1")
  end
end
local function section(title) io.write("\n-- " .. title .. "\n") end

local REPO = vim.fn.getcwd()
vim.opt.runtimepath:prepend(REPO)
package.path = REPO .. "/lua/?.lua;" .. REPO .. "/lua/?/init.lua;" .. package.path
local EXT = jit.os == "OSX" and "dylib" or "so"
local LIB = REPO .. "/core/target/release/libjupynvim." .. EXT
local FX = REPO .. "/tests/fixtures/palette/"

local function read_json(name)
  local text = table.concat(vim.fn.readfile(FX .. name), "\n")
  return vim.json.decode(text, { luanil = { object = true, array = true } })
end
local function loadavg()
  local a = vim.uv.loadavg()
  return ("load %.1f"):format(a)
end
local function median(t)
  local c = vim.deepcopy(t)
  table.sort(c)
  return c[math.ceil(#c / 2)]
end
local function max_of(t)
  local m = -math.huge
  for _, v in ipairs(t) do if v > m then m = v end end
  return m
end

section("files the spec needs")
chk("the library is built (" .. LIB .. ")", vim.uv.fs_stat(LIB) ~= nil, "build it: cd core && cargo build --release")
for _, f in ipairs({ "cases.json", "user_hl.json", "user_tokens.json", "user_live_hl.json", "mocha_hl.json",
                     "mocha_tokens.json", "latte_hl.json", "latte_tokens.json" }) do
  chk("fixture " .. f, vim.uv.fs_stat(FX .. f) ~= nil)
end

-- ── the JIT ──────────────────────────────────────────────────────────────
-- The budgets below assume LuaJIT's compiler. jit.status() can say on while
-- this process compiles nothing: Neovim 0.11.5's LuaJIT on arm64 macOS
-- sometimes cannot get memory for machine code, every trace then aborts, and
-- every budget would time the interpreter. A fresh hot loop must finish a
-- trace. When it does not, and nothing has failed yet, the whole spec runs
-- again in a fresh Neovim, up to three tries; JNV_PALETTE_SPEC_FAKE_NOMCODE=1
-- makes the first try report none.
section("the JIT")
do
  chk("the JIT compiler is on (jit.status()); the budgets assume it", jit.status() == true,
      "JIT is off in this Neovim, so the timings below measure the interpreter")
  local TRY = tonumber(os.getenv("JNV_PALETTE_SPEC_TRY") or "1") or 1
  local function compiles()
    local stops, reason = 0, nil
    local okv, vmdef = pcall(require, "jit.vmdef")
    local function on_trace(what, _, _, _, otr, oex)
      if what == "stop" then
        stops = stops + 1
      elseif what == "abort" and not reason then
        local f = okv and type(vmdef) == "table" and type(vmdef.traceerr) == "table" and vmdef.traceerr[otr]
        local okf, text = pcall(string.format, tostring(f or "trace error %s"), oex or otr)
        reason = okf and text or tostring(f)
      end
    end
    jit.attach(on_trace, "trace")
    local okl, err = pcall(function() load("local a = 0 for i = 1, 100000 do a = a + i % 7 end return a")() end)
    jit.attach(on_trace)
    if not okl then return false, "the probe failed: " .. tostring(err) end
    return stops > 0, reason or "no trace started"
  end
  local mcode, why = compiles()
  if os.getenv("JNV_PALETTE_SPEC_FAKE_NOMCODE") == "1" and TRY == 1 then
    mcode, why = false, "JNV_PALETTE_SPEC_FAKE_NOMCODE=1"
  end
  if not mcode and fails == 0 and TRY < 3 then
    io.write(("this LuaJIT compiled no machine code in this process (%s); running the whole spec again"
      .. " in a fresh Neovim (try %d of 3)\n"):format(why, TRY + 1))
    local r = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-c", "luafile " .. REPO .. "/tests/palette_spec.lua",
      "-c", "cquit 3" }, { cwd = REPO, env = { JNV_PALETTE_SPEC_TRY = tostring(TRY + 1) }, text = true }):wait(900000)
    io.write(r.stdout or "")
    if (r.stderr or "") ~= "" then io.stderr:write(r.stderr) end
    if r.code == 0 then vim.cmd("qa!") else vim.cmd("cquit " .. tostring(r.code)) end
    return
  end
  chk("this process compiles machine code (a fresh hot loop finished a trace)", mcode, why)
end

-- ── the module ───────────────────────────────────────────────────────────
section("the module")
local okP, P = pcall(require, "jupynvim.palette")
chk("require(\"jupynvim.palette\") works", okP and type(P) == "table", P)
if not okP or type(P) ~= "table" then finish() return end
chk("it loads no library (the library loads when something asks)", package.loaded["jupynvim.native"] == nil)
chk("M.TOKENS lists 35 tokens", #P.TOKENS == 35, #P.TOKENS)
chk("M.TOKENS starts with canvas, text and ends with quote_bar", P.TOKENS[1] == "canvas" and P.TOKENS[2] == "text"
    and P.TOKENS[35] == "quote_bar")
chk("M.RADIUS_PX is 6", P.RADIUS_PX == 6)
do
  local seen, dup = {}, nil
  for _, t in ipairs(P.TOKENS) do
    if seen[t] then dup = t end
    seen[t] = true
  end
  chk("no token is listed twice", dup == nil, dup)
end
P.setup({})
chk("setup({}) loads no library", package.loaded["jupynvim.native"] == nil)
local i0 = P.info()
chk("info() is a table before anything asked", type(i0) == "table")
chk("info().state is waiting before anything asked", i0.state == "waiting", i0.state)
chk("info().generation is 0 before anything asked", i0.generation == 0, i0.generation)

-- Every User JupynvimPalette event of the run.
local events = {}
vim.api.nvim_create_autocmd("User", {
  pattern = "JupynvimPalette",
  callback = function(ev) events[#events + 1] = ev.data end,
})

-- when_ready, waited for.
local function ready(timeout)
  local got
  P.when_ready(function(t, i) got = { tokens = t, info = i } end)
  vim.wait(timeout or 3000, function() return got ~= nil end, 1)
  if not got then return nil, nil end
  return got.tokens, got.info
end

-- ── A. fixtures through the library ──────────────────────────────────────
section("A. fixtures through the library")
local sch, sch_err = P._schema()
chk("A0 the library gives its schema", sch ~= nil, sch_err)
if not sch then finish() return end
chk("A0 37 groups, Normal first, PmenuSel last", #sch.groups == 37 and sch.groups[1] == "Normal"
    and sch.groups[37] == "PmenuSel", #sch.groups)
chk("A0 the library's tokens are M.TOKENS, in order", vim.deep_equal(sch.tokens, P.TOKENS))

-- The wire text, exactly: schema order for groups, canvas then token order
-- for overrides, `-` for what is not there.
local wire = P._input_from({
  groups = {
    CursorLine = {},
    ["@comment"] = { fg = "#989898" },
    NotInTheSchema = { fg = "#ffffff" },
    Comment = { fg = "#222222", bg = "#111111" },
    Normal = { fg = "#c0caf5" },
  },
  colors_name = "tokyonight-storm", background = "dark", terminal = "#222436",
  overrides = { fill = "#101010", canvas = "#000000", accent = "#ff0000" }, set = true,
})
chk("A0 the wire text of a full table", wire == table.concat({
  "JNP 1", "kind dark", "name tokyonight-storm", "term #222436", "set",
  "g Normal #c0caf5 -", "g Comment #222222 #111111", "g @comment #989898 -",
  "o canvas #000000", "o fill #101010", "o accent #ff0000", "",
}, "\n"), wire)
local wire2 = P._input_from({ groups = {}, background = "light" })
chk("A0 no name, no terminal, light", wire2 == "JNP 1\nkind light\nname -\nterm -\n", wire2)
local wire3 = P._input_from({ groups = {}, background = "anything", colors_name = "a\nb\r\nc" })
chk("A0 any other background is dark; a line break in a name becomes a space",
    wire3 == "JNP 1\nkind dark\nname a b c\nterm -\n", wire3)
chk("A0 the same table gives the same text", P._input_from({ groups = { Normal = { fg = "#c0caf5" } } })
    == P._input_from({ groups = { Normal = { fg = "#c0caf5" } } }))
local toks0, info0 = P._derive_input(wire)
chk("A0 the library accepts the text", toks0 ~= nil, info0)
chk("A0 its override and its terminal show in the result", toks0 and toks0.fill == "#101010" and toks0.canvas == "#000000",
    toks0 and (toks0.fill .. " " .. toks0.canvas))
local bad, bad_err = P._derive_input("garbage")
chk("A0 a bad input is nil plus the library's message", bad == nil and type(bad_err) == "string"
    and bad_err:find("palette input line 1", 1, true) ~= nil, tostring(bad_err))

local cases = read_json("cases.json")
local function groups_of(dump)
  local g = {}
  for name, a in pairs(dump) do
    if name:sub(1, 1) ~= "_" and type(a) == "table" and (a.fg or a.bg) then g[name] = { fg = a.fg, bg = a.bg } end
  end
  return g
end
for _, key in ipairs({ "user", "user_live", "mocha", "latte" }) do
  local c = cases[key]
  local hl = read_json(c.hl)
  local exp = read_json(c.expected)
  local dump = hl.groups or hl
  local want = exp.tokens or exp
  for t, v in pairs(c.expected_differences or {}) do want[t] = v end
  local input = P._input_from({
    groups = groups_of(dump), colors_name = c.colors_name, background = c.background, terminal = c.terminal_canvas,
  })
  local tokens, info = P._derive_input(input)
  chk("A " .. key .. " derives", tokens ~= nil, info)
  if tokens then
    for _, t in ipairs(P.TOKENS) do
      chk(("A %s %s"):format(key, t), tokens[t] == want[t], ("%s, wanted %s"):format(tostring(tokens[t]), tostring(want[t])))
    end
    chk("A " .. key .. " reports a port and a theme id", type(info.theme_id) == "string" and #info.theme_id == 16,
        vim.inspect(info))
  end
end

-- ── B. collection, tokens, groups and the event ──────────────────────────
section("B. collection, tokens, groups and the event")
-- B0: nothing asked yet. get() starts a derivation and gives nil; a moment
-- later the tokens are there (the default colorscheme has a Normal background,
-- so no terminal is needed).
chk("B0 get() before any derivation is nil", P.get() == nil)
local got0 = vim.wait(3000, function() return P.get() ~= nil end, 1)
chk("B0 a get() started the derivation: tokens appear", got0)
chk("B0 info().state is ok then", P.info().state == "ok", P.info().state)
chk("B0 that derivation fired one event", #events == 1, #events)
local gen_before = P.info().generation
chk("B0 the schema's groups the colorscheme does not define do not exist yet", vim.fn.hlexists("MarkviewCode") == 0
    and vim.fn.hlexists("RenderMarkdownCodeInline") == 0)
P._collect()
chk("B0 _collect() creates no group it reads", vim.fn.hlexists("MarkviewCode") == 0
    and vim.fn.hlexists("RenderMarkdownCodeInline") == 0)

-- The user's setup, as tests/fixtures/palette/user_hl.json dumps it.
vim.o.background = "dark"
vim.cmd("hi clear")
for _, g in ipairs(sch.groups) do vim.api.nvim_set_hl(0, g, {}) end
local user_hl = read_json("user_hl.json")
for name, a in pairs(user_hl) do
  if name:sub(1, 1) ~= "_" then
    local attrs = {}
    if type(a) == "table" then attrs.fg, attrs.bg = a.fg, a.bg end
    vim.api.nvim_set_hl(0, name, attrs)
  end
end
-- a linked group: its color must come through the link
vim.api.nvim_set_hl(0, "@markup.heading.1", { link = "Title" })
vim.g.colors_name = "tokyonight-storm"
P._set_terminal_bg("#222436")

local collected = P._collect()
chk("B _collect() has the colorscheme's name, background and terminal", collected.colors_name == "tokyonight-storm"
    and collected.background == "dark" and collected.terminal == "#222436", vim.inspect(collected.colors_name))
chk("B _collect() resolves a linked group (@markup.heading.1 gives Title's color)",
    collected.groups["@markup.heading.1"] and collected.groups["@markup.heading.1"].fg == "#7aa2f7",
    vim.inspect(collected.groups["@markup.heading.1"]))
chk("B _collect() leaves out a group with no color", collected.groups["@markup.link.url"] == nil
    and collected.groups["@markup.quote"] == nil)
chk("B _collect() sees Normal without a background", collected.groups.Normal
    and collected.groups.Normal.fg == "#c0caf5" and collected.groups.Normal.bg == nil, vim.inspect(collected.groups.Normal))
local from_json = {
  groups = groups_of(user_hl), colors_name = "tokyonight-storm", background = "dark", terminal = "#222436",
}
chk("B the input read from Neovim equals the input built from the JSON",
    P._input_from(collected) == P._input_from(from_json), P._input_from(collected))

local ev0 = #events
local returned, in_fast, sync_call = false, nil, nil
local got
P.when_ready(function(t, i)
  sync_call = not returned
  in_fast = vim.in_fast_event()
  got = { tokens = t, info = i }
end)
returned = true
vim.wait(3000, function() return got ~= nil end, 1)
chk("B when_ready calls back", got ~= nil)
if not got then finish() return end
chk("B the callback runs after when_ready returned, outside a fast event", sync_call == false and in_fast == false,
    tostring(sync_call) .. " " .. tostring(in_fast))
vim.wait(50)
local want = read_json("user_tokens.json")
local mism = {}
for _, t in ipairs(P.TOKENS) do
  if got.tokens[t] ~= want[t] then mism[#mism + 1] = ("%s %s wanted %s"):format(t, tostring(got.tokens[t]), tostring(want[t])) end
end
chk("B the 35 tokens equal user_tokens.json", #mism == 0, table.concat(mism, "; "))
chk("B table_radius_px of the fixture is M.RADIUS_PX", want.table_radius_px == P.RADIUS_PX)
chk("B the tokens table holds only the 35 tokens", vim.tbl_count(got.tokens) == 35, vim.tbl_count(got.tokens))
local gmis = {}
for _, t in ipairs(P.TOKENS) do
  local fg = vim.api.nvim_get_hl(0, { name = "JupynvimPal_" .. t, link = false })
  local bg = vim.api.nvim_get_hl(0, { name = "JupynvimPalBg_" .. t, link = false })
  local n = tonumber(got.tokens[t]:sub(2), 16)
  chk("B JupynvimPal_" .. t .. " is the token as fg", fg.fg == n, tostring(fg.fg) .. " vs " .. n)
  chk("B JupynvimPalBg_" .. t .. " is the token as bg", bg.bg == n, tostring(bg.bg) .. " vs " .. n)
end
chk("B exactly one User JupynvimPalette event for that derivation", #events == ev0 + 1, #events - ev0)
local last_ev = events[#events]
chk("B the event carries the theme id and the generation", last_ev and last_ev.theme_id == got.info.theme_id
    and last_ev.generation == got.info.generation, vim.inspect(last_ev))
chk("B info(): ok, terminal canvas, port tokyonight-storm, dark", got.info.state == "ok"
    and got.info.canvas_source == "terminal" and got.info.port == "tokyonight-storm" and got.info.kind == "dark"
    and got.info.colors_name == "tokyonight-storm", vim.inspect(got.info))
chk("B info().generation went up by one", got.info.generation == gen_before + 1, got.info.generation)
chk("B info().theme_id is 16 hex digits", type(got.info.theme_id) == "string" and #got.info.theme_id == 16
    and got.info.theme_id:match("^%x+$") ~= nil, tostring(got.info.theme_id))
chk("B info().sources names a source for every token", (function()
  for _, t in ipairs(P.TOKENS) do
    if type(got.info.sources[t]) ~= "string" or got.info.sources[t] == "" then return false end
  end
  return true
end)())
chk("B info().sources: canvas from the terminal, text from a group", got.info.sources.canvas:find("^derived") ~= nil
    and got.info.sources.text:find("^group") ~= nil, tostring(got.info.sources.canvas) .. " / " .. tostring(got.info.sources.text))
chk("B get() returns the same table the callback got", rawequal(P.get(), got.tokens))
chk("B info().state is ok", P.info().state == "ok")

-- a waiter that throws does not stop the next
do
  local second
  P.when_ready(function() error("a consumer that fails") end)
  P.when_ready(function(t) second = t end)
  vim.wait(3000, function() return second ~= nil end, 1)
  chk("B a callback that throws does not stop the next one", second ~= nil)
end

-- a palette that is ready and unchanged answers on the next tick, not at once
do
  local returned3, sync3, got3 = false, nil, nil
  P.when_ready(function(t) sync3 = not returned3; got3 = t end)
  returned3 = true
  vim.wait(1000, function() return got3 ~= nil end, 1)
  chk("B a ready, unchanged palette answers on the next tick, never before when_ready returns",
      sync3 == false and rawequal(got3, P.get()), tostring(sync3))
end

-- asked from a fast event (a luv callback), where the API is not allowed. The
-- terminal's answer is forgotten and Normal has a background, so a derivation
-- has to look at Normal (an API call) to learn that it needs no answer.
do
  vim.api.nvim_set_hl(0, "Normal", { fg = "#c0caf5", bg = "#222436" })
  P._set_terminal_bg(nil)
  P.refresh()
  local timer = vim.uv.new_timer()
  local errs, cb_tokens, cb_fast = {}, nil, nil
  timer:start(0, 0, function()
    local okg, eg = pcall(P.get)
    local okr, er = pcall(P.refresh)
    local okw, ew = pcall(P.when_ready, function(t)
      cb_tokens, cb_fast = t, vim.in_fast_event()
    end)
    if not okg then errs[#errs + 1] = "get: " .. tostring(eg) end
    if not okr then errs[#errs + 1] = "refresh: " .. tostring(er) end
    if not okw then errs[#errs + 1] = "when_ready: " .. tostring(ew) end
    timer:close()
  end)
  vim.wait(3000, function() return cb_tokens ~= nil end, 1)
  chk("B get(), refresh() and when_ready() work from a fast event", #errs == 0, table.concat(errs, "; "))
  chk("B ...and the callback runs on the main loop, with the tokens", cb_tokens ~= nil and cb_fast == false,
      tostring(cb_tokens) .. " " .. tostring(cb_fast))
  chk("B ...a Normal with a background gives the canvas (no terminal needed)", P.info().canvas_source == "Normal.bg",
      tostring(P.info().canvas_source))
  vim.api.nvim_set_hl(0, "Normal", { fg = "#c0caf5" })
  P._set_terminal_bg("#222436")
  local _, ib = ready()
  chk("B the terminal's answer makes the canvas the terminal's again", ib and ib.canvas_source == "terminal"
      and P.get().canvas == "#222436", ib and ib.canvas_source)
end

-- something changes while a derivation waits for its turn: it is read when the
-- derivation runs, and one more derivation follows at its end
do
  vim.api.nvim_set_hl(0, "Normal", { fg = "#a9b1d6" })
  P.refresh()
  local d0, s0 = P._stats.derives, P._stats.skipped_same
  local seen
  P.when_ready(function(t) seen = t end)
  vim.api.nvim_set_hl(0, "Normal", { fg = "#9aa5ce" })
  P.refresh()
  P.refresh()
  vim.wait(3000, function() return seen ~= nil end, 1)
  chk("B a change while a derivation waits is in the tokens the callback gets", seen ~= nil and seen.text == "#9aa5ce",
      seen and seen.text)
  chk("B ...one derivation, then one more that finds nothing new", P._stats.derives == d0 + 1
      and P._stats.skipped_same == s0 + 1, ("derives +%d, skipped_same +%d"):format(P._stats.derives - d0,
      P._stats.skipped_same - s0))
  vim.api.nvim_set_hl(0, "Normal", { fg = "#c0caf5" })
  P.refresh()
  ready()
end

-- a derivation that fails: the callbacks are still called, with the tokens
-- from before and the reason in info()
do
  local collect, input_from = P._collect, P._input_from
  P._collect = function() error("boom from the collection", 0) end
  P.refresh()
  local t1, i1 = ready()
  P._collect = collect
  chk("B a failure while collecting still calls back, with the earlier tokens", t1 ~= nil and t1.text == "#c0caf5",
      tostring(t1))
  chk("B ...info() says ok with the reason", i1 and i1.state == "ok" and tostring(i1.reason):find("boom", 1, true) ~= nil,
      vim.inspect(i1 and { i1.state, i1.reason }))
  P._input_from = function() return "this is not a palette input\n" end
  P.refresh()
  local t2, i2 = ready()
  P._input_from = input_from
  chk("B an input the library refuses still calls back, with the earlier tokens", t2 ~= nil and t2.text == "#c0caf5",
      tostring(t2))
  chk("B ...the reason is the library's", i2 and tostring(i2.reason):find("palette input line 1", 1, true) ~= nil,
      vim.inspect(i2 and i2.reason))
  P.refresh()
  local t3, i3 = ready()
  chk("B the next good derivation clears the reason", t3 ~= nil and i3.reason == nil, vim.inspect(i3 and i3.reason))
end

-- groups wiped by a colorscheme change come back though the input is the same
do
  local ev_n, sets = #events, 0
  -- what a :colorscheme's `hi clear` does to groups a plugin defined
  for _, t in ipairs(P.TOKENS) do
    vim.api.nvim_set_hl(0, "JupynvimPal_" .. t, {})
    vim.api.nvim_set_hl(0, "JupynvimPalBg_" .. t, {})
  end
  chk("B (control) the wiped group has no color", vim.api.nvim_get_hl(0, { name = "JupynvimPal_text", link = false }).fg == nil)
  local orig = vim.api.nvim_set_hl
  vim.api.nvim_set_hl = function(...) sets = sets + 1; return orig(...) end
  P.refresh()
  local t = ready()
  vim.api.nvim_set_hl = orig
  chk("B wiped JupynvimPal_ groups are defined again with an unchanged input", t ~= nil
      and vim.api.nvim_get_hl(0, { name = "JupynvimPal_text", link = false }).fg == tonumber(t.text:sub(2), 16)
      and vim.api.nvim_get_hl(0, { name = "JupynvimPalBg_fill", link = false }).bg == tonumber(t.fill:sub(2), 16))
  chk("B ...without an event (the theme did not change)", #events == ev_n, #events - ev_n)
end

-- ── E. overrides ─────────────────────────────────────────────────────────
section("E. overrides")
local notes = {}
local orig_notify = vim.notify
vim.notify = function(msg, level) notes[#notes + 1] = { msg = tostring(msg), level = level } end
local ev_e = #events
P.setup({ fill = "#101010", canvas = "#000000" })
chk("E a good setup gives no notice", #notes == 0, vim.inspect(notes))
P.refresh()
local te, ie = ready()
chk("E fill override is final, source override", te and te.fill == "#101010" and ie.sources.fill == "override",
    te and (te.fill .. " / " .. tostring(ie.sources.fill)))
chk("E canvas override, canvas_source override", te and te.canvas == "#000000" and ie.canvas_source == "override",
    te and (te.canvas .. " / " .. tostring(ie.canvas_source)))
chk("E kbd_bg follows the fill override", te and te.kbd_bg == "#101010", te and te.kbd_bg)
chk("E a changed palette fires one event", #events == ev_e + 1, #events - ev_e)

P.setup({ fill = "#ABCDEF" })
P.refresh()
te = ready()
chk("E an upper case color is taken, as lower case", te and te.fill == "#abcdef"
    and P._collect().overrides.fill == "#abcdef", te and te.fill)

notes = {}
P.setup({ nope = "#ffffff", text = "red", accent = 5, fill = "#101010" })
chk("E bad entries give exactly one notice", #notes == 1, vim.inspect(notes))
local note = notes[1] or { msg = "" }
chk("E ...at WARN level", note.level == vim.log.levels.WARN, tostring(note.level))
chk("E ...naming nope, text and accent, with the module's prefix", note.msg:find("nope", 1, true) and note.msg:find("text", 1, true)
    and note.msg:find("accent", 1, true) and note.msg:find("jupynvim: palette: ignored", 1, true) ~= nil, note.msg)
chk("E ...and not the good entry", note.msg:find("fill", 1, true) == nil, note.msg)
P.refresh()
te, ie = ready()
chk("E the ignored entries changed nothing, the good one applies", te and te.text == "#c0caf5" and te.fill == "#101010"
    and te.canvas == "#222436", vim.inspect(te and { te.text, te.fill, te.canvas }))
notes = {}
P.setup(nil)
P.setup(false)
chk("E nil and false options give no notice", #notes == 0, vim.inspect(notes))
P.setup("red")
chk("E an option that is not a table gives one notice", #notes == 1 and notes[1].msg:find("jupynvim: palette:", 1, true) ~= nil,
    vim.inspect(notes))
notes = {}
P.setup({ fill = false })
chk("E false for a token means unset, without a notice", #notes == 0, vim.inspect(notes))
vim.notify = orig_notify

P.setup({})
P.refresh()
te, ie = ready()
local back = {}
for _, t in ipairs(P.TOKENS) do
  if te[t] ~= want[t] then back[#back + 1] = t end
end
chk("E setup({}) takes the overrides away: the user tokens again", #back == 0, table.concat(back, ", "))
chk("E ...and the canvas is the terminal's again", ie.canvas_source == "terminal", ie.canvas_source)

-- ── F. readable ──────────────────────────────────────────────────────────
section("F. readable")
chk("F a readable color is returned as it is", P.readable("#c0caf5", "#222436") == "#c0caf5", P.readable("#c0caf5", "#222436"))
chk("F a color that cannot be read on its background is the canvas (user palette)",
    P.readable("#7aa2f7", "#ffff00") == "#222436", P.readable("#7aa2f7", "#ffff00"))
chk("F ...or the text, whichever contrasts more", P.readable("#1c1f31", "#222436") == "#c0caf5",
    P.readable("#1c1f31", "#222436"))
chk("F the target is respected (3.0 keeps what 4.5 would change)", P.readable("#6b7090", "#222436", 3.0) == "#6b7090"
    and P.readable("#6b7090", "#222436", 7.0) ~= "#6b7090", P.readable("#6b7090", "#222436", 7.0))
chk("F a bad color is nil", P.readable("red", "#222436") == nil)
-- deriving Latte with `set` makes it the library's current palette
do
  local l = read_json("cases.json").latte
  local input = P._input_from({
    groups = groups_of(read_json(l.hl).groups), colors_name = l.colors_name, background = l.background, set = true,
  })
  local lt = P._derive_input(input)
  chk("F latte derives", lt ~= nil)
  chk("F after a derivation with set the library's current palette is Latte's",
      P.readable("#000001", "#000000") == "#eff1f5", P.readable("#000001", "#000000"))
end
-- the user palette is current again after a refresh with a changed input
P.setup({})
P.refresh()
ready()
chk("F the module's own derivation makes its palette current again", P.readable("#7aa2f7", "#ffff00") == "#222436",
    P.readable("#7aa2f7", "#ffff00"))
do
  local best, runs = math.huge, {}
  for _ = 1, 3 do
    local n = 20000
    local t0 = vim.uv.hrtime()
    for _ = 1, n do P.readable("#7aa2f7", "#ffff00") end
    local per = (vim.uv.hrtime() - t0) / n / 1000
    runs[#runs + 1] = ("%.2f"):format(per)
    if per < best then best = per end
  end
  chk(("F B9 readable() under 5 us per call (best of 3 batches: %s us; %s)"):format(table.concat(runs, ", "), loadavg()),
      best < 5)
end

-- ── G. the path without the library ──────────────────────────────────────
section("G. the path without the library")
local function child(case, env)
  local r = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-l", REPO .. "/tests/palette/child_case.lua", REPO,
    case }, { env = env, text = true }):wait(30000)
  local line
  for l in (r.stdout or ""):gmatch("[^\n]+") do
    if l:sub(1, 1) == "{" then line = l end
  end
  local ok, j = pcall(vim.json.decode, line or "")
  if not ok or type(j) ~= "table" then
    return nil, r, ("exit %s, stdout %q, stderr %q"):format(tostring(r.code), r.stdout or "", r.stderr or "")
  end
  return j, r
end
do
  local j, r, why = child("off", { JUPYNVIM_NATIVE = "off" })
  chk("G the child ran", j ~= nil, why)
  if j then
    chk("G without the library the tokens are nil", j.tokens == nil, vim.inspect(j.tokens))
    chk("G ...the state is unavailable", j.state == "unavailable", tostring(j.state))
    chk("G ...and the reason says it was turned off", type(j.reason) == "string" and j.reason:find("turned off", 1, true) ~= nil,
        tostring(j.reason))
    chk("G ...the callback was called", j.called == true)
    chk("G ...get() asks nothing of the library again (it is known to be missing)", j.later_asks == 0, tostring(j.later_asks))
    chk("G ...a refresh() lets it try once more", j.retry_asks == 1, tostring(j.retry_asks))
    chk("G ...exit code 0", r.code == 0, r.code)
    local err = r.stderr or ""
    chk("G ...no E5108 or Error line on stderr", not err:find("E5108", 1, true) and not err:find("Error", 1, true), err)
  end
end

do
  local j, _, why = child("fast", {})
  chk("G (fast) the child ran", j ~= nil, why)
  chk("G (fast) the first get() of a process, from a fast event, does not throw", j ~= nil and j.get_ok == true
      and j.get_fast == true, j and tostring(j.get_err))
  chk("G (fast) ...and starts the derivation: the tokens come", j ~= nil and j.tokens_after == true and j.state == "ok",
      j and tostring(j.state))
end

-- ── H. budgets ───────────────────────────────────────────────────────────
section("H. budgets")
do
  local best, runs = math.huge, {}
  for _ = 1, 3 do
    local ms = {}
    for _ = 1, 20 do
      local t0 = vim.uv.hrtime()
      P.setup({})
      ms[#ms + 1] = (vim.uv.hrtime() - t0) / 1e6
    end
    local m = median(ms)
    runs[#runs + 1] = ("%.3f"):format(m)
    if m < best then best = m end
  end
  chk(("H B3 palette.setup() median under 0.2 ms (best of 3 batches: %s ms; %s)"):format(table.concat(runs, ", "), loadavg()),
      best < 0.2)
end
chk("H sixty calls of setup() left one ColorScheme autocmd", #vim.api.nvim_get_autocmds({ group = "jupynvim_palette",
    event = "ColorScheme" }) == 1)
-- setup() reset the cached input: the next derivation runs, with the same
-- theme, so it sets the groups and fires no event
do
  local ev_n, d0 = #events, P._stats.derives
  P.refresh()
  local t, i = ready()
  chk("H a derivation after setup() runs (the cached input was reset)", P._stats.derives == d0 + 1, P._stats.derives - d0)
  chk("H ...and fires no event: the theme is the same", #events == ev_n, #events - ev_n)
  chk("H ...with the same tokens", t and t.text == "#c0caf5" and t.canvas == "#222436")
end
do
  local sets, orig = 0, vim.api.nvim_set_hl
  vim.api.nvim_set_hl = function(...) sets = sets + 1; return orig(...) end
  local s0, d0, e0, g0 = P._stats.skipped_same, P._stats.derives, #events, P.info().generation
  P.refresh()
  P.refresh()
  ready()
  chk("H B5 two refreshes in one tick with nothing changed: skipped_same +1", P._stats.skipped_same == s0 + 1,
      P._stats.skipped_same - s0)
  chk("H B5 ...no derivation, no event, no nvim_set_hl", P._stats.derives == d0 and #events == e0 and sets == 0,
      ("derives +%d, events +%d, sets %d"):format(P._stats.derives - d0, #events - e0, sets))
  P.refresh()
  ready()
  chk("H B5 a refresh of its own: skipped_same +2 in all", P._stats.skipped_same == s0 + 2, P._stats.skipped_same - s0)
  chk("H B5 the generation did not move", P.info().generation == g0, P.info().generation)
  -- the counter counts: a changed refresh calls nvim_set_hl 70 times
  orig(0, "Normal", { fg = "#a9b1d6" })
  sets = 0
  P.refresh()
  ready()
  chk("H B5 (control) a changed refresh calls nvim_set_hl for the 70 groups", sets == 70, sets)
  vim.api.nvim_set_hl = orig
  vim.api.nvim_set_hl(0, "Normal", { fg = "#c0caf5" })
  P.refresh()
  ready()
end
do
  local n = 100000
  local best, runs = math.huge, {}
  for _ = 1, 3 do
    local t0 = vim.uv.hrtime()
    for _ = 1, n do P.get() end
    local per = (vim.uv.hrtime() - t0) / n / 1000
    runs[#runs + 1] = ("%.4f"):format(per)
    if per < best then best = per end
  end
  chk(("H B7 get() with tokens present under 1 us (mean of %d calls, best of 3: %s us; %s)"):format(n,
      table.concat(runs, ", "), loadavg()), best < 1)
end

-- H: the plugin's own setup() loads nothing (a fresh process)
do
  local j, _, why = child("setup", {})
  chk("H B3 the child ran", j ~= nil, why)
  chk("H B3 require(\"jupynvim\").setup({}) does not load the library", j ~= nil and j.native_loaded == false,
      j and tostring(j.native_loaded))
  chk("H B3 ...but the palette is set up (its augroup exists)", j ~= nil and j.palette_autocmds == 1, j and tostring(j.palette_autocmds))
end

-- ── I. the cost of a changed refresh ─────────────────────────────────────
section("I. the cost of a changed refresh")
do
  local best, runs = nil, {}
  local colors = { "#c0caf5", "#a9b1d6" }
  local all_events_ok = true
  for b = 1, 3 do
    local ms = {}
    for i = 1, 20 do
      vim.api.nvim_set_hl(0, "Normal", { fg = colors[(i % 2) + 1] })
      local n0 = #events
      P.refresh()
      vim.wait(2000, function() return #events > n0 end, 1)
      if #events ~= n0 + 1 then all_events_ok = false end
      ms[#ms + 1] = P._stats.last_ms
    end
    local m, mx = median(ms), max_of(ms)
    runs[#runs + 1] = ("median %.3f max %.3f"):format(m, mx)
    if m < 0.5 and mx < 2 then best = best or b end
  end
  chk("I every changed refresh fired exactly one event", all_events_ok)
  chk(("I B2 a changed refresh: median under 0.5 ms and every run under 2 ms (3 batches of 20, ms: %s; %s)"):format(
      table.concat(runs, " | "), loadavg()), best ~= nil)
  vim.api.nvim_set_hl(0, "Normal", { fg = "#c0caf5" })
  P.refresh()
  ready()
end

-- ── C. the triggers ──────────────────────────────────────────────────────
section("C. the triggers: ColorScheme, 'background', typing")
-- From here on no terminal is asked for real: _send records, _has_tty_ui is a
-- flag, and the terminal's answers are TermResponse events made by hand.
local orig_send, orig_has_tty = P._send, P._has_tty_ui
chk("C (control) without a terminal UI the real _has_tty_ui() is false", orig_has_tty() == false)
chk("C ...and the real _send() writes nothing and says so", orig_send("\027]11;?\007") == false)
local sent, tty_on = {}, false
P._send = function(s) sent[#sent + 1] = s; return true end
P._has_tty_ui = function() return tty_on end
-- This spec runs from -c, before VimEnter, when the palette sends nothing and
-- waits for it (section N proves that). From here on Neovim has "started".
local orig_started = P._started
chk("C (control) the real _started() follows v:vim_did_enter", orig_started() == (vim.v.vim_did_enter == 1))
local started = true
P._started = function() return started end
local QUERY = "\027]11;?\007\027[5n"
local function answer(seq)
  vim.api.nvim_exec_autocmds("TermResponse", { modeline = false, data = { sequence = seq } })
end
local function wait_for(cond, ms) return vim.wait(ms or 3000, cond, 1) end
-- libuv's own clock in ms, brought up to date (what a timer counts with)
local function uvnow() vim.uv.update_time(); return vim.uv.now() end
local function user_groups()
  -- the user's setup again (a change of 'background' resets Neovim's own groups)
  for name, a in pairs(user_hl) do
    if name:sub(1, 1) ~= "_" and type(a) == "table" then
      vim.api.nvim_set_hl(0, name, { fg = a.fg, bg = a.bg })
    end
  end
  vim.api.nvim_set_hl(0, "@markup.heading.1", { link = "Title" })
end
local function stats_copy() return vim.deepcopy(P._stats) end

-- the augroup the triggers live in
do
  local function count(event, pattern)
    local n = 0
    for _, a in ipairs(vim.api.nvim_get_autocmds({ group = "jupynvim_palette", event = event })) do
      if pattern == nil or a.pattern == pattern then n = n + 1 end
    end
    return n
  end
  chk("C the augroup jupynvim_palette has one OptionSet autocmd, on background", count("OptionSet", "background") == 1
      and count("OptionSet") == 1)
  chk("C ...one TermResponse autocmd", count("TermResponse") == 1)
  chk("C ...one ColorScheme autocmd", count("ColorScheme") == 1)
end

-- a ColorScheme with a changed Normal.fg: one derivation, the new text, the event once
do
  local e0, d0, id0 = #events, P._stats.derives, P.info().theme_id
  vim.api.nvim_set_hl(0, "Normal", { fg = "#a9b1d6" })
  vim.cmd("doautocmd ColorScheme")
  chk("C a ColorScheme derives nothing before the next tick", P._stats.derives == d0)
  wait_for(function() return #events > e0 end)
  chk("C ColorScheme with a changed Normal.fg: text follows", P.get().text == "#a9b1d6", P.get().text)
  chk("C ...one derivation, one event", P._stats.derives == d0 + 1 and #events == e0 + 1,
      ("derives +%d, events +%d"):format(P._stats.derives - d0, #events - e0))
  chk("C ...the theme id changed and the event carries it", P.info().theme_id ~= id0
      and events[#events].theme_id == P.info().theme_id, tostring(P.info().theme_id))
  -- nothing changed: B5 again, through the trigger
  local s1, d1, e1, sets = stats_copy(), P._stats.derives, #events, 0
  local orig_set = vim.api.nvim_set_hl
  vim.api.nvim_set_hl = function(...) sets = sets + 1; return orig_set(...) end
  vim.cmd("doautocmd ColorScheme")
  vim.wait(100)
  vim.api.nvim_set_hl = orig_set
  chk("C a second ColorScheme with nothing changed: skipped_same +1, no derivation, no event, no group written",
      P._stats.skipped_same == s1.skipped_same + 1 and P._stats.derives == d1 and #events == e1 and sets == 0,
      ("skipped +%d, derives +%d, events +%d, sets %d"):format(P._stats.skipped_same - s1.skipped_same,
      P._stats.derives - d1, #events - e1, sets))
  -- five in a tick are one derivation
  vim.api.nvim_set_hl(0, "Normal", { fg = "#9aa5ce" })
  local d2 = P._stats.derives
  for _ = 1, 5 do vim.cmd("doautocmd ColorScheme") end
  wait_for(function() return P.get().text == "#9aa5ce" end)
  vim.wait(50)
  chk("C five ColorSchemes in a tick are one derivation", P._stats.derives == d2 + 1, P._stats.derives - d2)
  vim.api.nvim_set_hl(0, "Normal", { fg = "#c0caf5" })
  vim.cmd("doautocmd ColorScheme")
  wait_for(function() return P.get().text == "#c0caf5" end)
end

-- OptionSet background: the handler's body. The spec runs while Neovim starts,
-- when OptionSet does not fire, so the body is driven directly. A change of
-- 'background' derives again and asks the terminal again, because a terminal
-- that reports no change of theme tells nobody; the question cannot undo the
-- change, since Neovim's own handler is away while it is in flight (section
-- N, and palette_terminal_screen.sh on a real screen).
do
  tty_on = true
  sent = {}
  local s0 = stats_copy()
  P._on_option_background("dark", "dark")
  vim.wait(100)
  chk("C 'background' set to the value it had: no query", #sent == 0, #sent)
  chk("C ...and no derivation, no refresh", P._stats.derives == s0.derives and P._stats.skipped_same == s0.skipped_same,
      ("derives +%d, skipped +%d"):format(P._stats.derives - s0.derives, P._stats.skipped_same - s0.skipped_same))

  -- dark to light: Neovim resets its groups, Normal has no background of its own
  local d0, e0, q0 = P._stats.derives, #events, P._stats.queries
  vim.o.background = "light"
  user_groups()
  vim.api.nvim_set_hl(0, "Normal", { fg = "#4c4f69" })
  P._on_option_background("dark", "light")
  chk("C dark to light: nothing happens in the event itself (the work is for the next tick)", #sent == 0
      and P._stats.derives == d0)
  wait_for(function() return #sent == 1 end)
  chk("C dark to light with a transparent Normal and a known canvas: the terminal is asked again", #sent == 1
      and sent[1] == QUERY and P._stats.queries == q0 + 1, vim.inspect(sent))
  P.when_ready(function() end)
  vim.wait(50)
  chk("C ...the derivation waits for the answer (nothing derived yet)", P._stats.derives == d0, P._stats.derives - d0)
  -- the terminal did not change: the same color comes back
  answer("\027]11;rgb:2222/2424/3636")
  wait_for(function() return P.info().kind == "light" end)
  chk("C ...the palette derives again: kind light", P.info().kind == "light", P.info().kind)
  chk("C ...and keeps what the terminal said: canvas #222436 from the terminal", P.get().canvas == "#222436"
      and P.info().canvas_source == "terminal", P.get().canvas .. " " .. tostring(P.info().canvas_source))
  chk("C ...one derivation, one event, one query in all", P._stats.derives == d0 + 1 and #events == e0 + 1 and #sent == 1
      and P._stats.queries == q0 + 1, ("derives +%d, events +%d, sent %d"):format(P._stats.derives - d0, #events - e0, #sent))

  -- the terminal itself turned light, with no theme report: the next change
  -- of 'background' asks, and learns it
  sent = {}
  P._on_option_background("dark", "light")
  wait_for(function() return #sent == 1 end)
  answer("\027]11;rgb:eeee/f1f1/f5f5")
  wait_for(function() return P.get().canvas == "#eef1f5" end)
  chk("C a change of 'background' asks again, and the answer (the terminal turned light unreported) makes the canvas #eef1f5",
      #sent == 1 and P.get().canvas == "#eef1f5", P.get().canvas .. " sent " .. #sent)
  chk("C ...canvas from the terminal, kind light", P.info().canvas_source == "terminal" and P.info().kind == "light",
      P.info().canvas_source .. " " .. P.info().kind)

  -- the terminal reports its change (what Neovim 0.11 asks for again on a
  -- theme change): the answer is read, and the change of 'background' that
  -- follows it (Neovim's handler) asks nothing more
  sent = {}
  local a0 = P._stats.answers
  vim.o.background = "dark"
  user_groups()
  vim.api.nvim_set_hl(0, "Normal", { fg = "#c0caf5" })
  P._on_option_background("light", "dark") -- Neovim's handler set it...
  answer("\027]11;rgb:2222/2424/3636") -- ...from this report, which the palette reads in the same event
  wait_for(function() return P.get().canvas == "#222436" and P.info().kind == "dark" end)
  vim.wait(50)
  chk("C a report and the change of 'background' it caused: the canvas follows, no query of our own",
      P.get().canvas == "#222436" and P.info().kind == "dark" and #sent == 0, P.get().canvas .. " sent " .. #sent)
  chk("C ...one answer counted", P._stats.answers == a0 + 1, P._stats.answers - a0)
  chk("C ...the user's tokens again (text, accent, fill)", P.get().text == want.text and P.get().accent == want.accent
      and P.get().fill == want.fill, P.get().text .. " " .. P.get().accent .. " " .. P.get().fill)
  sent = {}
end

-- when the change of 'background' asks nothing, and when the terminal keeps its last color
do
  tty_on = true
  sent = {}
  local function change_and_settle()
    P._on_option_background("dark", "light")
    vim.wait(60)
  end
  -- a canvas the user gave
  P.setup({ canvas = "#000000" })
  P._set_terminal_bg("#222436")
  sent = {}
  change_and_settle()
  chk("C a canvas override: a change of 'background' asks nobody", #sent == 0, #sent)
  P.setup({})
  P._set_terminal_bg("#222436")
  sent = {}
  -- nothing known of the terminal: the derivation asks (needs_terminal), once;
  -- the change of 'background' adds no second question
  P._set_terminal_bg(nil)
  change_and_settle()
  chk("C nothing known of the terminal yet: one question, the derivation's, not two", #sent == 1, #sent)
  P._set_terminal_bg("#222436")
  -- a question in flight is not asked twice
  sent = {}
  change_and_settle()
  P._on_option_background("light", "dark")
  vim.wait(60)
  chk("C two changes of 'background' while a question is in flight send one", #sent == 1, #sent)
  -- it stays silent: the known color stays, no fallback is counted
  local f0 = P._stats.fallbacks
  P._osc_timeout_ms = 80
  P._set_terminal_bg("#222436")
  sent = {}
  P._osc_timeout_ms = 80
  change_and_settle()
  wait_for(function() return P.info().osc_ms == nil or true end, 10)
  vim.wait(250)
  P._osc_timeout_ms = 1000
  local t, i = ready()
  chk("C a terminal that does not answer when asked again keeps its last color", t.canvas == "#222436"
      and i.canvas_source == "terminal" and i.reason == nil, t.canvas .. " " .. tostring(i.canvas_source) .. " " .. tostring(i.reason))
  chk("C ...and no fallback is counted for it", P._stats.fallbacks == f0, P._stats.fallbacks - f0)
  -- the DSR comes first: same
  sent = {}
  change_and_settle()
  answer("\027[0n")
  vim.wait(80)
  t, i = ready()
  chk("C a DSR answer to a question asked again keeps the last color too", t.canvas == "#222436"
      and i.canvas_source == "terminal" and i.reason == nil and P._stats.fallbacks == f0, t.canvas .. " " .. tostring(i.canvas_source))
  P._set_terminal_bg("#222436")
  ready()
  sent = {}
end

-- a Normal that has a background asks nobody
do
  sent = {}
  vim.api.nvim_set_hl(0, "Normal", { fg = "#c0caf5", bg = "#101010" })
  P._on_option_background("dark", "light")
  P._on_option_background("light", "dark")
  vim.wait(60)
  chk("C 'background' changed while Normal has a background: no query", #sent == 0, #sent)
  vim.api.nvim_set_hl(0, "Normal", { fg = "#c0caf5" })
  P._set_terminal_bg("#222436")
  ready()
  sent = {}
end

-- B6: typing and moving derive nothing and ask nothing. Nothing in the
-- palette's augroup listens to the cursor or to text changes (a headless
-- feedkeys does not run every such autocmd, so the list is checked too).
do
  local allowed, stray = { ColorScheme = true, OptionSet = true, TermResponse = true }, {}
  for _, a in ipairs(vim.api.nvim_get_autocmds({ group = "jupynvim_palette" })) do
    if not allowed[a.event] then stray[#stray + 1] = a.event end
  end
  chk("C B6 the palette listens only to ColorScheme, OptionSet and TermResponse", #stray == 0, table.concat(stray, ", "))
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.fn["repeat"]({ "a line of text" }, 300))
  tty_on = true
  local s0 = stats_copy()
  vim.api.nvim_feedkeys("gg", "tx", false)
  vim.api.nvim_feedkeys("i" .. string.rep("x", 200) .. "\27", "tx", false)
  vim.api.nvim_feedkeys(string.rep("jk", 100), "tx", false)
  vim.wait(200)
  chk("C B6 typing 200 characters and moving 200 times: 0 derivations, 0 queries, 0 checks of the input",
      P._stats.derives == s0.derives and P._stats.queries == s0.queries and P._stats.skipped_same == s0.skipped_same
      and #sent == 0, ("derives +%d, queries +%d, skipped +%d, sent %d"):format(P._stats.derives - s0.derives,
      P._stats.queries - s0.queries, P._stats.skipped_same - s0.skipped_same, #sent))
  vim.cmd("bwipe! " .. buf)
end

-- B4: a ColorScheme before anything asked, in a fresh process
do
  local j, _, why = child("cold_colorscheme", {})
  chk("C B4 the child ran", j ~= nil, why)
  if j then
    chk("C B4 (control) the default colorscheme's Normal has a background", j.normal_has_bg == true)
    chk("C B4 ColorScheme before any consumer asked loads no library", j.native_loaded == false and j.later_native_loaded == false,
        tostring(j.native_loaded) .. " " .. tostring(j.later_native_loaded))
    chk("C B4 ...derives nothing and asks nothing", j.derives == 0 and j.queries == 0,
        tostring(j.derives) .. " " .. tostring(j.queries))
    chk(("C B4 ...the handler costs under 0.05 ms (median of 50: %.4f ms; %s)"):format(j.handler_ms or -1, loadavg()),
        type(j.handler_ms) == "number" and j.handler_ms < 0.05)
  end
end

-- ── D. OSC 11 ────────────────────────────────────────────────────────────
section("D. OSC 11: the terminal's own background")
do
  local p = P._parse_osc11
  chk("D 4-digit channels", p("\027]11;rgb:2222/2424/3636") == "#222436", tostring(p("\027]11;rgb:2222/2424/3636")))
  chk("D 2-digit channels", p("\027]11;rgb:22/24/36") == "#222436", tostring(p("\027]11;rgb:22/24/36")))
  chk("D 1-digit channels (scaled: f is ff, 2 is 22)", p("\027]11;rgb:2/2/3") == "#222233", tostring(p("\027]11;rgb:2/2/3")))
  chk("D white", p("\027]11;rgb:ffff/ffff/ffff") == "#ffffff", tostring(p("\027]11;rgb:ffff/ffff/ffff")))
  chk("D 3-digit channels (fff is ff)", p("\027]11;rgb:fff/000/800") == "#ff0080", tostring(p("\027]11;rgb:fff/000/800")))
  chk("D upper case hex", p("\027]11;rgb:AAAA/BBBB/CCCC") == "#aabbcc", tostring(p("\027]11;rgb:AAAA/BBBB/CCCC")))
  chk("D rgba: the alpha is ignored", p("\027]11;rgba:2222/2424/3636/ffff") == "#222436",
      tostring(p("\027]11;rgba:2222/2424/3636/ffff")))
  chk("D a terminator after the color is tolerated", p("\027]11;rgb:22/24/36\007") == "#222436"
      and p("\027]11;rgb:22/24/36\027\\") == "#222436")
  chk("D two channels are nil", p("\027]11;rgb:22/24") == nil)
  chk("D OSC 10 (the foreground) is nil", p("\027]10;rgb:2222/2424/3636") == nil)
  chk("D a 5-digit channel is nil", p("\027]11;rgb:12345/0/0") == nil)
  chk("D an alpha of 5 digits is nil", p("\027]11;rgba:1/2/3/12345") == nil)
  chk("D a non-hex channel is nil", p("\027]11;rgb:zz/00/00") == nil)
  chk("D the query itself is nil", p("\027]11;?") == nil)
  chk("D a non-string is nil", p(nil) == nil and p(5) == nil)
end

do
  -- a fresh start: Normal has no background, nothing known, a terminal UI
  tty_on = true
  vim.api.nvim_set_hl(0, "Normal", { fg = "#c0caf5" })

  -- when_ready sends one query; a second when_ready before the answer sends none
  sent = {}
  P._set_terminal_bg(nil)
  local c1, c2
  local s0 = stats_copy()
  P.when_ready(function(t, i) c1 = { t = t, i = i } end)
  P.when_ready(function(t, i) c2 = { t = t, i = i } end)
  vim.wait(100)
  chk("D when_ready with an unknown canvas sends one query, OSC 11 and a DSR", #sent == 1 and sent[1] == QUERY, vim.inspect(sent))
  chk("D ...a second when_ready before the answer sends none (B8: one query in flight)", #sent == 1, #sent)
  chk("D ...nobody is called back while the query is in flight", c1 == nil and c2 == nil)
  P.refresh()
  vim.wait(50)
  chk("D ...nor does a refresh send one", #sent == 1, #sent)
  answer("\027]11;rgb:2222/2424/3636")
  wait_for(function() return c1 ~= nil and c2 ~= nil end)
  chk("D the answer completes both callbacks", c1 ~= nil and c2 ~= nil)
  chk("D ...with the terminal's canvas", c1 and c2 and c1.i.canvas_source == "terminal" and c2.i.canvas_source == "terminal"
      and c1.t.canvas == "#222436" and c2.t.canvas == "#222436", c1 and vim.inspect(c1.i.canvas_source))
  chk("D ...one query and one answer counted", P._stats.queries == s0.queries + 1 and P._stats.answers == s0.answers + 1,
      ("queries +%d, answers +%d"):format(P._stats.queries - s0.queries, P._stats.answers - s0.answers))
  chk("D ...info().osc_ms is the round trip", type(P.info().osc_ms) == "number" and P.info().osc_ms >= 0
      and P.info().osc_ms < 1000, tostring(P.info().osc_ms))
  chk("D ...the canvas is the user's tokens again", c1 and c1.t.text == want.text and c1.t.fill == want.fill)

  -- the same answer again: nothing is derived
  local s1, ev1 = stats_copy(), #events
  answer("\027]11;rgb:2222/2424/3636")
  vim.wait(100)
  chk("D the same color answered again changes nothing", P._stats.derives == s1.derives and P._stats.skipped_same == s1.skipped_same
      and #events == ev1, ("derives +%d, skipped +%d"):format(P._stats.derives - s1.derives,
      P._stats.skipped_same - s1.skipped_same))
  chk("D ...and sends no query", #sent == 1, #sent)

  -- a different color answered later (the terminal's theme changed): a refresh and the event
  local e0 = #events
  answer("\027]11;rgb:1111/1212/1313")
  wait_for(function() return P.get().canvas == "#111213" end)
  chk("D a new color from the terminal re-derives with it, and the event fires", P.get().canvas == "#111213"
      and #events == e0 + 1, P.get().canvas .. " events +" .. (#events - e0))
  chk("D ...without a query", #sent == 1, #sent)
  answer("\027]11;rgb:2222/2424/3636")
  wait_for(function() return P.get().canvas == "#222436" end)
end

-- the DSR comes first: the terminal does not answer OSC 11
do
  tty_on = true
  sent = {}
  P._set_terminal_bg(nil)
  local got3, t_done
  P.when_ready(function(t, i) got3 = { t = t, i = i }; t_done = vim.uv.hrtime() end)
  vim.wait(50)
  chk("D (DSR) one query is in flight", #sent == 1 and got3 == nil)
  local f0 = P._stats.fallbacks
  local t_dsr = vim.uv.hrtime()
  answer("\027[0n")
  wait_for(function() return got3 ~= nil end, 1000)
  local ms = t_done and (t_done - t_dsr) / 1e6 or math.huge
  chk(("D B8 a DSR answer first gives the fallback in under 50 ms (%.1f ms; %s)"):format(ms, loadavg()), ms < 50)
  chk("D ...the canvas is VS Code's default for the kind, #1e1e1e, from the fallback", got3 and got3.t.canvas == "#1e1e1e"
      and got3.i.canvas_source == "fallback", got3 and (got3.t.canvas .. " " .. got3.i.canvas_source))
  chk("D ...info().reason mentions OSC 11", got3 and type(got3.i.reason) == "string" and got3.i.reason:find("OSC 11", 1, true) ~= nil,
      got3 and tostring(got3.i.reason))
  chk("D ...the fallback is counted", P._stats.fallbacks == f0 + 1, P._stats.fallbacks - f0)
  chk("D ...the palette is still ok (it has tokens)", got3 and got3.i.state == "ok")
  -- a second DSR with nothing pending changes nothing
  local s1 = stats_copy()
  answer("\027[0n")
  vim.wait(100)
  chk("D a DSR answer with no query pending changes nothing", P._stats.derives == s1.derives and P._stats.fallbacks == s1.fallbacks)
  -- the OSC 11 answer arriving after the fallback
  local e0 = #events
  answer("\027]11;rgb:2222/2424/3636")
  wait_for(function() return P.info().canvas_source == "terminal" end)
  chk("D the OSC 11 answer after the fallback re-derives with the terminal's canvas", P.get().canvas == "#222436"
      and P.info().canvas_source == "terminal", P.get().canvas .. " " .. P.info().canvas_source)
  chk("D ...fires the event, sends no new query", #events == e0 + 1 and #sent == 1, ("events +%d, sent %d"):format(#events - e0, #sent))
  chk("D ...and the reason is gone", P.info().reason == nil, tostring(P.info().reason))
end

-- no answer at all: the fallback after the limit
do
  tty_on = true
  sent = {}
  P._osc_timeout_ms = 100
  P._set_terminal_bg(nil)
  local got4, t_done, u_done
  -- libuv counts timers in whole milliseconds, from its own clock: the lower bound is read on that clock
  -- (a timer never fires before it has run its milliseconds), the upper one on the wall
  local uv0 = uvnow()
  local t0 = vim.uv.hrtime()
  P.when_ready(function(t, i) got4 = { t = t, i = i }; t_done = vim.uv.hrtime(); u_done = uvnow() end)
  wait_for(function() return got4 ~= nil end, 3000)
  local ms = t_done and (t_done - t0) / 1e6 or math.huge
  P._osc_timeout_ms = 1000
  chk(("D B8 no answer: the fallback comes after the limit, 100 to 300 ms (%.1f ms; libuv's clock %s ms; %s)"):format(
      ms, tostring(u_done and (u_done - uv0)), loadavg()), u_done ~= nil and u_done - uv0 >= 100 and ms <= 300)
  chk("D ...one query only, the fallback canvas", #sent == 1 and got4 and got4.i.canvas_source == "fallback"
      and got4.t.canvas == "#1e1e1e", got4 and got4.i.canvas_source)
  chk("D ...the reason says how long it waited", got4 and tostring(got4.i.reason):find("100 ms", 1, true) ~= nil,
      got4 and tostring(got4.i.reason))
  answer("\027]11;rgb:2222/2424/3636")
  wait_for(function() return P.info().canvas_source == "terminal" end)
  chk("D ...a late answer after the timeout is still taken", P.get().canvas == "#222436")
  -- libuv counts a timer from the time it cached when the loop last ran, which stands still during a
  -- long callback: a limit started at the end of one must still run from the call, not from its start
  sent = {}
  P._osc_timeout_ms = 250
  local t_call, t_late
  vim.schedule(function()
    local b = vim.uv.hrtime()
    while (vim.uv.hrtime() - b) / 1e6 < 200 do end
    -- (nothing here may bring libuv's clock up to date: that is the module's job)
    t_call = vim.uv.hrtime()
    P._set_terminal_bg(nil) -- forgets the color, and asks (somebody waits)
    P.when_ready(function() t_late = vim.uv.hrtime() end)
  end)
  wait_for(function() return t_late ~= nil end, 3000)
  P._osc_timeout_ms = 1000
  local ms_late = t_late and (t_late - t_call) / 1e6 or math.huge
  -- (from a clock that may be 1 ms coarse, and in whole milliseconds: 3 ms of slack; a limit counted from the
  -- start of the long callback comes after 50)
  chk(("D B8 the limit counts from the call, also after a long callback: the fallback comes 247 to 600 ms after it (%.1f ms; %s)")
      :format(ms_late, loadavg()), ms_late >= 247 and ms_late <= 600)
  answer("\027]11;rgb:2222/2424/3636")
  wait_for(function() return P.info().canvas_source == "terminal" end)
  -- the timer of an answered query is stopped: no fallback later
  sent = {}
  P._osc_timeout_ms = 100
  P._set_terminal_bg(nil)
  local got5
  P.when_ready(function(t, i) got5 = { t = t, i = i } end)
  vim.wait(20)
  answer("\027]11;rgb:2222/2424/3636")
  wait_for(function() return got5 ~= nil end)
  local f0 = P._stats.fallbacks
  vim.wait(250)
  P._osc_timeout_ms = 1000
  chk("D an answered query leaves no timer behind: no fallback after the limit", P._stats.fallbacks == f0 and got5.i.canvas_source == "terminal"
      and P.info().canvas_source == "terminal", P._stats.fallbacks - f0)
end

-- no terminal UI: no query, the fallback at once
do
  tty_on = false
  sent = {}
  P._set_terminal_bg(nil)
  local got6, t_done
  local t0 = vim.uv.hrtime()
  P.when_ready(function(t, i) got6 = { t = t, i = i }; t_done = vim.uv.hrtime() end)
  wait_for(function() return got6 ~= nil end, 1000)
  local ms = t_done and (t_done - t0) / 1e6 or math.huge
  chk(("D without a terminal UI the fallback is immediate (%.1f ms) and nothing is written"):format(ms), ms < 50 and #sent == 0
      and got6 and got6.i.canvas_source == "fallback", ("%.1f ms, sent %d"):format(ms, #sent))
  chk("D ...the reason says there is no terminal to ask", got6 and type(got6.i.reason) == "string" and got6.i.reason ~= "",
      got6 and tostring(got6.i.reason))
  tty_on = true
  P._set_terminal_bg("#222436")
  ready()
end

-- a canvas override and a Normal background ask nobody
do
  tty_on = true
  sent = {}
  P.setup({ canvas = "#000000" })
  P._set_terminal_bg(nil)
  local t7, i7 = ready()
  chk("D a canvas override: no query, canvas_source override", #sent == 0 and i7 and i7.canvas_source == "override"
      and t7.canvas == "#000000", vim.inspect(sent))
  sent = {}
  vim.api.nvim_set_hl(0, "Normal", { fg = "#c0caf5", bg = "#101010" })
  P.setup({})
  P._set_terminal_bg(nil)
  sent = {}
  P.refresh()
  local t8, i8 = ready()
  chk("D Normal with a background: no query, canvas_source Normal.bg", #sent == 0 and i8 and i8.canvas_source == "Normal.bg"
      and t8.canvas == "#101010", vim.inspect(sent))
  -- an answer arriving now is kept and derives nothing
  local s1 = stats_copy()
  answer("\027]11;rgb:3333/3333/3333")
  vim.wait(100)
  chk("D an answer while Normal has a background derives nothing", P._stats.derives == s1.derives
      and P._stats.skipped_same == s1.skipped_same and P._stats.answers == s1.answers + 1,
      ("derives +%d, answers +%d"):format(P._stats.derives - s1.derives, P._stats.answers - s1.answers))
  -- Normal loses its background: the kept answer is used, no query
  vim.api.nvim_set_hl(0, "Normal", { fg = "#c0caf5" })
  P.refresh()
  local t9, i9 = ready()
  chk("D ...and is used when Normal loses its background, without a query", #sent == 0 and i9 and i9.canvas_source == "terminal"
      and t9.canvas == "#333333", t9 and (t9.canvas .. " sent " .. #sent))
  answer("\027]11;rgb:2222/2424/3636")
  wait_for(function() return P.get().canvas == "#222436" end)
end

-- setup() asks once when the canvas needs the terminal's background and nothing
-- is known of it (after startup; before it, section N)
do
  tty_on = true
  -- forget the canvas while Normal has a background, so that nothing asks yet
  vim.api.nvim_set_hl(0, "Normal", { fg = "#c0caf5", bg = "#101010" })
  P._set_terminal_bg(nil)
  vim.api.nvim_set_hl(0, "Normal", { fg = "#c0caf5" })
  sent = {}
  P.setup({})
  chk("D setup() with a transparent Normal and no known canvas sends the query", #sent == 1 and sent[1] == QUERY, vim.inspect(sent))
  P.setup({})
  chk("D ...a second setup() while it is in flight sends none", #sent == 1, #sent)
  answer("\027]11;rgb:2222/2424/3636")
  wait_for(function() return P.get().canvas == "#222436" end)
  sent = {}
  P.setup({})
  chk("D setup() with the canvas known sends none", #sent == 0, #sent)
  vim.api.nvim_set_hl(0, "Normal", { fg = "#c0caf5", bg = "#101010" })
  P._set_terminal_bg(nil)
  sent = {}
  P.setup({})
  chk("D setup() with a Normal background and no known canvas sends none (an opaque canvas never needs the terminal's)",
      #sent == 0, vim.inspect(sent))
  P._set_terminal_bg(nil)
  sent = {}
  P.setup({ canvas = "#000000" })
  chk("D setup() with a canvas override sends none", #sent == 0, #sent)
  vim.api.nvim_set_hl(0, "Normal", { fg = "#c0caf5" })
  tty_on = false
  P.setup({})
  P._set_terminal_bg(nil)
  sent = {}
  P.setup({})
  chk("D setup() without a terminal UI sends none", #sent == 0, #sent)
  tty_on = true
  P.setup({})
  P._set_terminal_bg("#222436")
  sent = {}
  ready()
  chk("D ...state back to the user's tokens", P.get().text == want.text and P.get().canvas == "#222436")
end

-- answers that are not the background change nothing
do
  tty_on = true
  sent = {}
  ready()
  local s1 = stats_copy()
  local e1 = #events
  answer("\027[?1;2;4c")
  answer("\027P1$r0m\027\\")
  answer("\027[?64;1;2c")
  answer("\027]10;rgb:ffff/ffff/ffff")
  answer("")
  vim.api.nvim_exec_autocmds("TermResponse", { modeline = false })
  vim.api.nvim_exec_autocmds("TermResponse", { modeline = false, data = 5 })
  vim.wait(150)
  local s2 = P._stats
  chk("D other terminal answers change nothing at all", s2.derives == s1.derives and s2.skipped_same == s1.skipped_same
      and s2.queries == s1.queries and s2.answers == s1.answers and s2.fallbacks == s1.fallbacks and #events == e1
      and #sent == 0, vim.inspect({ s1, s2 }))
  -- the data as a plain string (older Neovim versions) is read too
  vim.api.nvim_exec_autocmds("TermResponse", { modeline = false, data = "\027]11;rgb:1111/1212/1313" })
  wait_for(function() return P.get().canvas == "#111213" end)
  chk("D the answer as a plain string is read too", P.get().canvas == "#111213", P.get().canvas)
  answer("\027]11;rgb:2222/2424/3636")
  wait_for(function() return P.get().canvas == "#222436" end)
end

-- a module nobody has asked anything of yet (a second copy of it): setup()
-- asks the terminal when the canvas needs it, a change of 'background' asks
-- again, and the answers derive nothing and load nothing until a consumer
-- wants the palette
do
  package.loaded["jupynvim.palette"] = nil
  local P2 = require("jupynvim.palette")
  P2._send, P2._has_tty_ui, P2._started = P._send, P._has_tty_ui, P._started
  tty_on = true
  vim.api.nvim_set_hl(0, "Normal", { fg = "#c0caf5" })
  sent = {}
  P2.setup({})
  chk("D (cold) setup() asks the terminal at once", #sent == 1 and sent[1] == QUERY and P2._stats.queries == 1, vim.inspect(sent))
  answer("\027]11;rgb:2222/2424/3636")
  vim.wait(100)
  chk("D (cold) ...its answer is kept and derives nothing, since nobody asked for the palette", P2._stats.answers == 1
      and P2._stats.derives == 0 and P2._stats.skipped_same == 0, ("answers %d, derives %d"):format(P2._stats.answers, P2._stats.derives))
  sent = {}
  P2._on_option_background("dark", "light")
  wait_for(function() return #sent == 1 end)
  chk("D (cold) a change of 'background' asks the terminal again", #sent == 1 and sent[1] == QUERY and P2._stats.queries == 2,
      vim.inspect(sent))
  vim.wait(100)
  chk("D (cold) ...and derives nothing, since nobody asked for the palette", P2._stats.derives == 0 and P2._stats.skipped_same == 0,
      P2._stats.derives)
  answer("\027]11;rgb:eeee/f1f1/f5f5")
  vim.wait(100)
  chk("D (cold) ...the answer, the terminal's new color, is kept and derives nothing", P2._stats.answers == 2 and P2._stats.derives == 0
      and P2._stats.skipped_same == 0, ("answers %d, derives %d"):format(P2._stats.answers, P2._stats.derives))
  local gotc
  sent = {}
  P2.when_ready(function(t, i) gotc = { t = t, i = i } end)
  wait_for(function() return gotc ~= nil end)
  chk("D (cold) ...a consumer then gets the kept color as the canvas, with no further query", gotc ~= nil
      and gotc.t and gotc.t.canvas == "#eef1f5" and gotc.i.canvas_source == "terminal" and #sent == 0
      and P2._stats.queries == 2, gotc and vim.inspect(gotc.i.canvas_source) .. " sent " .. #sent)
  -- the first copy is the module again
  package.loaded["jupynvim.palette"] = P
  vim.api.nvim_set_hl(0, "Normal", { fg = "#c0caf5" })
  P.setup({})
  P._set_terminal_bg("#222436")
  ready()
  chk("D (cold) ...back to the first copy: the user's tokens", P.get().canvas == "#222436" and P.get().text == want.text)
end

-- ── J. :checkhealth jupynvim ─────────────────────────────────────────────
section("J. :checkhealth jupynvim")
local LIB_HEAD = "jupynvim: in-process library (libjupynvim)"
local PAL_HEAD = "jupynvim: palette"
local INSTALL_HEAD = "jupynvim: installing the prebuilt"
-- the text of one section of a health report, from its title to the next
local function health_part(text, head)
  local a = text:find(head, 1, true)
  if not a then return "" end
  local b = text:find("\n%S[^\n]* ~\n", a + #head)
  return text:sub(a, b or #text)
end
local function line_with(text, sub)
  for l in text:gmatch("[^\n]+") do if l:find(sub, 1, true) then return l end end
end
-- :checkhealth jupynvim in this process: the report's text and how many
-- notices it made
local function health_here()
  local notices = 0
  local orig = vim.notify
  vim.notify = function() notices = notices + 1 end
  local ok, err = pcall(vim.cmd, "checkhealth jupynvim")
  vim.notify = orig
  local buf = vim.api.nvim_get_current_buf()
  local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  pcall(vim.cmd, "bwipe! " .. buf)
  return text, notices, ok, err
end
do
  tty_on = true
  vim.api.nvim_set_hl(0, "Normal", { fg = "#c0caf5" })
  P._set_terminal_bg("#222436")
  vim.g.colors_name = "tokyonight-storm"
  ready()
  local d0, e0, g0 = P._stats.derives, #events, P.info().generation
  local text, notices, ok, err = health_here()
  chk("J :checkhealth jupynvim runs, and no check of the report failed to run", ok and not text:find("Failed to run healthcheck", 1, true),
      err or text:match("Failed to run healthcheck[^\n]*\n[^\n]*\n[^\n]*"))
  local pal = health_part(text, PAL_HEAD .. " ~")
  local at = { lib = text:find(LIB_HEAD, 1, true), pal = text:find(PAL_HEAD .. " ~", 1, true), inst = text:find(INSTALL_HEAD, 1, true) }
  chk("J the palette has a section of its own, after the library's and before the installer's", at.lib and at.pal and at.inst
      and at.lib < at.pal and at.pal < at.inst, vim.inspect(at))
  local l1 = line_with(pal, "palette: 35 tokens from tokyonight-storm")
  chk("J the section says 35 tokens from tokyonight-storm, as OK", l1 and l1:find("OK", 1, true) ~= nil, tostring(l1))
  chk("J ...with the background and the theme id", l1 and l1:find("background dark", 1, true) ~= nil
      and l1:find(P.info().theme_id, 1, true) ~= nil, tostring(l1))
  local l2 = line_with(pal, "canvas #222436 from the terminal (OSC 11)")
  chk("J canvas #222436 from the terminal (OSC 11), as OK", l2 and l2:find("OK", 1, true) ~= nil, tostring(l2))
  local l3 = line_with(pal, "known VS Code port: Tokyo Night Storm (enkia.tokyo-night-1.1.2)")
  chk("J known VS Code port: Tokyo Night Storm (enkia.tokyo-night-1.1.2)", l3 ~= nil, tostring(line_with(pal, "known VS Code port") or pal))
  chk("J nothing in the palette's section warns", not pal:find("WARNING", 1, true) and not pal:find("ERROR", 1, true), pal)
  chk("J :checkhealth makes no vim.notify call", notices == 0, notices)
  chk("J ...and derives nothing for the editor: no derivation, no event, no generation", P._stats.derives == d0
      and #events == e0 and P.info().generation == g0, ("derives +%d, events +%d"):format(P._stats.derives - d0, #events - e0))

  -- a scheme without a known port
  vim.g.colors_name = "my-own-scheme"
  text = health_here()
  pal = health_part(text, PAL_HEAD .. " ~")
  chk("J a colorscheme without a port: no known VS Code port for it, Neovim groups and VS Code's formulas",
      line_with(pal, "no known VS Code port for my-own-scheme: Neovim groups and VS Code's formulas") ~= nil, pal)
  vim.g.colors_name = nil
  text = health_here()
  pal = health_part(text, PAL_HEAD .. " ~")
  chk("J no colorscheme at all is named so", line_with(pal, "palette: 35 tokens from no colorscheme") ~= nil, pal)
  vim.g.colors_name = "tokyonight-storm"

  -- overrides, and entries setup() ignored
  local notes0 = vim.notify
  vim.notify = function() end
  local cur0 = P.readable("#000001", "#000000")
  -- the override is not derived by the module yet (no tick has passed), but the
  -- report's own derivation includes it
  P.setup({ fill = "#101010", canvas = "#000000", text = "#ff0000", nope = "#ffffff" })
  vim.notify = notes0
  text = health_here()
  chk("J the report's derivation does not change the library's current palette (readable() is as before)",
      P.readable("#000001", "#000000") == cur0 and cur0 ~= "#ff0000", tostring(cur0) .. " / " .. tostring(P.readable("#000001", "#000000")))
  pal = health_part(text, PAL_HEAD .. " ~")
  chk("J overrides are listed (canvas, then tokens in their order)", line_with(pal, "overrides: canvas, text, fill") ~= nil, pal)
  chk("J ...the canvas set in setup() says so", line_with(pal, "canvas #000000 set in setup()") ~= nil, pal)
  local lw = line_with(pal, "nope")
  chk("J ...an ignored entry is a WARNING naming it", lw and lw:find("WARNING", 1, true) ~= nil, tostring(lw))
  P.setup({})
  vim.wait(50)
  P._set_terminal_bg("#222436")
  ready()

  -- a guess: the DSR came first
  sent = {}
  P._set_terminal_bg(nil)
  local gotg
  P.when_ready(function(t, i) gotg = { t = t, i = i } end)
  vim.wait(30)
  answer("\027[0n")
  wait_for(function() return gotg ~= nil end)
  text, notices = health_here()
  pal = health_part(text, PAL_HEAD .. " ~")
  local lg = line_with(pal, "canvas #1e1e1e is a guess")
  chk("J after a fallback the canvas is a WARNING: canvas #1e1e1e is a guess", lg and lg:find("WARNING", 1, true) ~= nil, tostring(lg))
  chk("J ...with the reason the terminal gave", lg and lg:find("OSC 11", 1, true) ~= nil, tostring(lg))
  chk("J ...and the way out, palette = { canvas = ... }", pal:find('palette = { canvas = "#rrggbb" }', 1, true) ~= nil, pal)
  chk("J ...still no vim.notify call", notices == 0, notices)
  answer("\027]11;rgb:2222/2424/3636")
  wait_for(function() return P.info().canvas_source == "terminal" end)
end
-- a library that is up but cannot derive: an information line, no warning
do
  local orig_derive = P._derive_now_for_health
  P._derive_now_for_health = function() return nil, "boom from the derivation" end
  local text, notices = health_here()
  P._derive_now_for_health = orig_derive
  local pal = health_part(text, PAL_HEAD .. " ~")
  local l = line_with(pal, "palette: could not be derived")
  chk("J a derivation that fails is an information line with its reason, not a warning", l ~= nil
      and l:find("boom from the derivation", 1, true) ~= nil and not pal:find("WARNING", 1, true) and notices == 0, pal)
  chk("J ...and it does not blame the library, which is up", not pal:find("needs libjupynvim", 1, true), pal)
end
do
  local j, r, why = child("health", { JUPYNVIM_NATIVE = "off" })
  chk("J (no library) the child ran", j ~= nil, why)
  if j then
    local pal = health_part(j.health, PAL_HEAD .. " ~")
    chk("J without the library the section says palette: needs libjupynvim", line_with(pal, "palette: needs libjupynvim") ~= nil, pal)
    chk("J ...and nothing in it warns", pal ~= "" and not pal:find("WARNING", 1, true) and not pal:find("ERROR", 1, true), pal)
    chk("J ...the report made no notice", j.notices == 0, tostring(j.notices))
    chk("J ...exit code 0, no E5108 or Error line on stderr", r.code == 0 and not (r.stderr or ""):find("E5108", 1, true)
        and not (r.stderr or ""):find("Error", 1, true), (r.stderr or ""))
  end
end

-- ── K. :JupynvimPalette ──────────────────────────────────────────────────
section("K. :JupynvimPalette")
do
  require("jupynvim.backend.commands").install(require("jupynvim"), require("jupynvim.notebook.image"))
  chk("K the command exists", vim.fn.exists(":JupynvimPalette") == 2)
  local function floats()
    local out = {}
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(w).relative ~= "" then out[#out + 1] = w end
    end
    return out
  end
  tty_on = true
  vim.api.nvim_set_hl(0, "Normal", { fg = "#c0caf5" })
  vim.g.colors_name = "tokyonight-storm"
  P._set_terminal_bg("#222436")
  local tokens, info = ready()
  local wins0 = #vim.api.nvim_list_wins()
  local e0 = #events
  vim.cmd("JupynvimPalette")
  wait_for(function() return #floats() > 0 end)
  local fl = floats()
  chk("K the command opens one float", #fl == 1 and #vim.api.nvim_list_wins() == wins0 + 1, #fl)
  local win = fl[1]
  if win then
    local buf = vim.api.nvim_win_get_buf(win)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    chk("K the buffer has 36 lines: a header and 35 tokens", #lines == 36, #lines)
    chk("K line 1 names the colorscheme, its port, the background and the canvas with its source",
        lines[1] == "colorscheme tokyonight-storm (Tokyo Night Storm), background dark, canvas #222436 from the terminal", lines[1])
    local bad = {}
    for i, t in ipairs(P.TOKENS) do
      local want_line = ("\226\150\136\226\150\136\226\150\136\226\150\136\226\150\136\226\150\136  %-24s  %s  %s"):format(t, tokens[t], info.sources[t])
      if lines[i + 1] ~= want_line then bad[#bad + 1] = ("%d: %q vs %q"):format(i + 1, tostring(lines[i + 1]), want_line) end
    end
    chk("K every token line is blocks, the name padded to 24, the hex and the source", #bad == 0, bad[1])
    local nsid = {}
    local missing = {}
    for i, t in ipairs(P.TOKENS) do
      local marks = vim.api.nvim_buf_get_extmarks(buf, -1, { i, 0 }, { i, -1 }, { details = true })
      local okm = false
      for _, m in ipairs(marks) do
        if m[4].hl_group == "JupynvimPal_" .. t and m[3] == 0 and m[4].end_col == 18 and (m[4].end_row or m[2]) == m[2] then okm = true end
      end
      if not okm then missing[#missing + 1] = t end
    end
    chk("K the six blocks of every token line are drawn in JupynvimPal_<token>", #missing == 0, table.concat(missing, ", "))
    local cfg = vim.api.nvim_win_get_config(win)
    local title = cfg.title
    if type(title) == "table" then
      local parts = {}
      for _, c in ipairs(title) do parts[#parts + 1] = type(c) == "table" and c[1] or tostring(c) end
      title = table.concat(parts)
    end
    chk("K the title is ' jupynvim palette ' and the border rounded", title == " jupynvim palette "
        and type(cfg.border) == "table" and cfg.border[1] == "\226\149\173", vim.inspect({ cfg.title, cfg.border }))
    chk("K the window uses the palette's own colors (winhighlight)", vim.wo[win].winhighlight
        == "NormalFloat:JupynvimPalBg_fill,FloatBorder:JupynvimPal_edge,FloatTitle:JupynvimPalTitle", vim.wo[win].winhighlight)
    local title_hl = vim.api.nvim_get_hl(0, { name = "JupynvimPalTitle", link = false })
    chk("K ...the title is the accent color and bold (spec section 7: the panel's title)", title_hl.bold == true
        and title_hl.fg == tonumber(P.get().accent:sub(2), 16), vim.inspect(title_hl))
    chk("K the float is the current window and cannot be edited", vim.api.nvim_get_current_win() == win
        and vim.bo[buf].modifiable == false and vim.bo[buf].bufhidden == "wipe")
    chk("K opening it made no derivation of its own (the palette was ready)", #events == e0)
    -- a second :JupynvimPalette replaces it
    vim.cmd("JupynvimPalette")
    vim.wait(100)
    chk("K a second :JupynvimPalette leaves one float", #floats() == 1 and #vim.api.nvim_list_wins() == wins0 + 1, #floats())
    win = floats()[1]
    vim.api.nvim_feedkeys("q", "x", false)
    chk("K q closes it (the window count is back)", #floats() == 0 and #vim.api.nvim_list_wins() == wins0,
        #vim.api.nvim_list_wins() .. " vs " .. wins0)
    vim.cmd("JupynvimPalette")
    wait_for(function() return #floats() > 0 end)
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "x", false)
    chk("K <Esc> closes it too", #floats() == 0 and #vim.api.nvim_list_wins() == wins0, #vim.api.nvim_list_wins())
  end
  -- a fallback canvas shows in the header
  tty_on = true
  sent = {}
  P._set_terminal_bg(nil)
  local gotk
  P.when_ready(function(t, i) gotk = { t = t, i = i } end)
  vim.wait(30)
  answer("\027[0n")
  wait_for(function() return gotk ~= nil end)
  vim.cmd("JupynvimPalette")
  wait_for(function() return #floats() > 0 end)
  local fw = floats()[1]
  local l1 = fw and vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(fw), 0, 1, false)[1]
  chk("K the header says where a fallback canvas came from", l1 and l1:find("canvas #1e1e1e from the fallback", 1, true) ~= nil, tostring(l1))
  if fw then vim.api.nvim_win_close(fw, true) end
  answer("\027]11;rgb:2222/2424/3636")
  wait_for(function() return P.info().canvas_source == "terminal" end)

  -- no library: one notice, no float
  local j, _, why = child("show_off", { JUPYNVIM_NATIVE = "off" })
  chk("K (no library) the child ran", j ~= nil, why)
  if j then
    local n = j.notes or {}
    chk("K without the library :JupynvimPalette gives one notice and opens nothing", #n == 1 and j.float_open == false,
        vim.inspect(j))
    local m = n[1] and n[1].msg or ""
    chk("K ...it says the palette needs libjupynvim, the reason and :checkhealth jupynvim", m:find("^jupynvim: the palette needs libjupynvim %(") ~= nil
        and m:find("turned off", 1, true) ~= nil and m:find("; see :checkhealth jupynvim$") ~= nil, m)
  end
end

-- ── L. the known ports ───────────────────────────────────────────────────
section("L. the known ports: key, label and source")
do
  tty_on = true
  local function ports_now() return (P._schema() or {}).ports or {} end
  local ports = ports_now()
  local n, bad = 0, {}
  for key, e in pairs(ports) do
    n = n + 1
    if not (type(e) == "table" and type(e.label) == "string" and e.label ~= "" and type(e.source) == "string"
            and e.source ~= "" and not e.source:find("%s")) then
      bad[#bad + 1] = tostring(key)
    end
  end
  chk("L the schema lists 19 known ports, each with a label and a source", n == 19 and #bad == 0,
      ("%d ports, bad: %s"):format(n, table.concat(bad, " ")))
  chk("L tokyonight-storm is Tokyo Night Storm from enkia.tokyo-night-1.1.2", ports["tokyonight-storm"] ~= nil
      and ports["tokyonight-storm"].label == "Tokyo Night Storm" and ports["tokyonight-storm"].source == "enkia.tokyo-night-1.1.2",
      vim.inspect(ports["tokyonight-storm"]))
  chk("L a label keeps its spaces and its UTF-8: rosepine is Rose Pine from mvllow.rose-pine-2.15.2", ports.rosepine ~= nil
      and ports.rosepine.label == "Ros\195\169 Pine" and ports.rosepine.source == "mvllow.rose-pine-2.15.2", vim.inspect(ports.rosepine))
  chk("L catppuccin-latte comes from catppuccin.catppuccin-vsc-3.19.0", ports["catppuccin-latte"] ~= nil
      and ports["catppuccin-latte"].source == "catppuccin.catppuccin-vsc-3.19.0", vim.inspect(ports["catppuccin-latte"]))

  -- a derivation names its port by key, label and source
  vim.api.nvim_set_hl(0, "Normal", { fg = "#c0caf5" })
  vim.g.colors_name = "tokyonight-storm"
  P._set_terminal_bg("#222436")
  P.refresh()
  local _, info = ready()
  chk("L a derivation names its port by key, label and source", info ~= nil and info.port == "tokyonight-storm"
      and info.port_label == "Tokyo Night Storm" and info.port_source == "enkia.tokyo-night-1.1.2",
      vim.inspect(info and { info.port, info.port_label, info.port_source }))
  local pi = P.info()
  chk("L ...and info() passes them on", pi.port == "tokyonight-storm" and pi.port_label == "Tokyo Night Storm"
      and pi.port_source == "enkia.tokyo-night-1.1.2", vim.inspect({ pi.port, pi.port_label, pi.port_source }))

  -- no known port: all three are nil
  vim.g.colors_name = "my-own-scheme"
  P.refresh()
  ready()
  local pn = P.info()
  chk("L without a known port, port, label and source are all nil", pn.port == nil and pn.port_label == nil
      and pn.port_source == nil, vim.inspect({ pn.port, pn.port_label, pn.port_source }))
  vim.g.colors_name = "tokyonight-storm"
  P.refresh()
  ready()

  -- a port the schema does not list is an error, never a nameless port
  local list = ports_now()
  local saved = list["tokyonight-storm"]
  list["tokyonight-storm"] = nil
  local okc, c = pcall(P._collect)
  local t, e
  if okc then t, e = P._derive_input(P._input_from(c)) end
  list["tokyonight-storm"] = saved
  chk("L a port the schema does not list is an error, never a nameless port", okc and t == nil
      and tostring(e):find("names port tokyonight-storm, which its schema does not list", 1, true) ~= nil, tostring(e))
  chk("L ...and the schema's entry is back", ports_now()["tokyonight-storm"] == saved)

  -- a schema whose port list is wrong is a schema error (a cold copy of the
  -- module reads it; the library's answer is edited on its way)
  local N = require("jupynvim.native")
  local real_call = N.call
  local function schema_error(edit)
    package.loaded["jupynvim.palette"] = nil
    local P3 = require("jupynvim.palette")
    N.call = function(kind, text)
      local ok, out = real_call(kind, text)
      if ok and kind == N.KIND.PALETTE_SCHEMA then out = edit(out) end
      return ok, out
    end
    local sch, err = P3._schema()
    N.call = real_call
    package.loaded["jupynvim.palette"] = P
    return sch, err
  end
  local sch, err = schema_error(function(out)
    return (out:gsub("tokyonight%-storm enkia%.tokyo%-night%-1%.1%.2 Tokyo Night Storm", "tokyonight-storm", 1))
  end)
  chk("L a port line that is not <key> <source> <label> is a schema error that shows the line", sch == nil
      and tostring(err):find("a port line that is not `<key> <source> <label>`: tokyonight-storm", 1, true) ~= nil, tostring(err))
  sch, err = schema_error(function(out) return (out:match("^(.-)\nports %d+\n")) .. "\n" end)
  chk("L a schema without the ports list is a schema error", sch == nil
      and tostring(err):find("has no `ports` line", 1, true) ~= nil, tostring(err))
  chk("L ...and the first copy of the module is back with its schema", package.loaded["jupynvim.palette"] == P
      and N.call == real_call and ports_now()["tokyonight-storm"] == saved)
end

-- ── M. review fixes ──────────────────────────────────────────────────────
section("M. review fixes: names, readable(), a table written to, wording")
do
  tty_on = true
  vim.api.nvim_set_hl(0, "Normal", { fg = "#c0caf5" })
  vim.g.colors_name = "tokyonight-storm"
  P.setup({})
  P._set_terminal_bg("#222436")
  ready()

  -- M1: the Lua check for UTF-8 says what the library says
  local valid = { "a", "caf\xc3\xa9", "\xe2\x82\xac", "\xf0\x9f\x98\x80", "\xed\x9f\xbf", "\xee\x80\x80", "\xf4\x8f\xbf\xbf",
                  "\xc2\x80", "\xdf\xbf", "\xe0\xa0\x80", "\xef\xbf\xbd", "\xf0\x90\x80\x80", "\xf1\x80\x80\x80", "rose pine \xc3\xa9" }
  local invalid = { "\xff", "\xfe", "\xc0\x80", "\xc1\xbf", "\xe0\x80\x80", "\xe0\x9f\xbf", "\xed\xa0\x80", "\xed\xbf\xbf",
                    "\xf0\x80\x80\x80", "\xf0\x8f\xbf\xbf", "\xf4\x90\x80\x80", "\xf5\x80\x80\x80", "\xc3", "\xe2\x82",
                    "\xf0\x9f\x98", "\x80", "\xbf", "a\xc3(", "\xe2(\xa1", "\xf0\x28\x8c\xbc", "ab\xff" }
  local diff = {}
  for _, group in ipairs({ { valid, true }, { invalid, false } }) do
    for _, str in ipairs(group[1]) do
      local lua_says = P._valid_utf8(str)
      local t = P._derive_input("JNP 1\nkind dark\nname " .. str .. "\nterm -\n")
      if lua_says ~= group[2] or (t ~= nil) ~= group[2] then
        diff[#diff + 1] = ("%q lua %s library %s wanted %s"):format(str, tostring(lua_says), tostring(t ~= nil), tostring(group[2]))
      end
    end
  end
  chk("M the Lua check for UTF-8 and the library agree on " .. (#valid + #invalid) .. " names", #diff == 0, diff[1])

  -- M2: a name that is not UTF-8 is sent as no name, and the palette is derived
  local bad = P._input_from({ colors_name = "tokyo\xffnight", background = "dark", terminal = "#222436", groups = {} })
  chk("M a colorscheme name that is not UTF-8 is sent as `name -`", bad:find("\nname -\n", 1, true) ~= nil
      and not bad:find("tokyo", 1, true), bad)
  local good = P._input_from({ colors_name = "caf\xc3\xa9", background = "dark", terminal = "#222436", groups = {} })
  chk("M ...a UTF-8 name is sent as it is", good:find("\nname caf\xc3\xa9\n", 1, true) ~= nil, good)
  local d0, e0 = P._stats.derives, #events
  vim.g.colors_name = "tokyo\xffnight\xfe"
  P.refresh()
  local t1, i1 = ready()
  chk("M the palette is derived with such a name: tokens, state ok, no reason", t1 ~= nil and i1.state == "ok" and i1.reason == nil
      and P._stats.derives == d0 + 1, i1 and tostring(i1.state) .. " " .. tostring(i1.reason))
  chk("M ...no port (only the port lookup reads the name), the canvas still the terminal's", i1 and i1.port == nil
      and t1 and t1.canvas == "#222436", i1 and tostring(i1.port))
  chk("M ...the event fired for the changed palette", #events == e0 + 1, #events - e0)
  local h = health_here()
  chk("M :checkhealth derives it too", line_with(health_part(h, PAL_HEAD .. " ~"), "palette: 35 tokens") ~= nil,
      health_part(h, PAL_HEAD .. " ~"))
  vim.g.colors_name = "tokyonight-storm"
  P.refresh()
  local _, i2 = ready()
  chk("M ...a valid name later finds the port again", i2 and i2.port == "tokyonight-storm", i2 and tostring(i2.port))

  -- M3: readable() with what a user may leave out
  local function safe(...)
    local ok, v = pcall(P.readable, ...)
    return ok, v
  end
  local o1, v1 = safe(nil, "#000000")
  local o2, v2 = safe("#ffffff", nil)
  local o3, v3 = safe(nil, nil)
  local o4, v4 = safe(5, "#000000")
  local o5, v5 = safe("#ffffff", "#000000", "x")
  chk("M readable(nil, bg) gives nil and raises nothing", o1 and v1 == nil, tostring(v1))
  chk("M readable(fg, nil), readable(nil, nil) and a number for a color give nil", o2 and v2 == nil and o3 and v3 == nil
      and o4 and v4 == nil, tostring(v2) .. " " .. tostring(v3) .. " " .. tostring(v4))
  chk("M readable(fg, bg, a target that is not a number) gives nil", o5 and v5 == nil, tostring(v5))
  chk("M readable with good arguments still answers (and a number target is taken)",
      P.readable("#000001", "#000000") ~= nil and P.readable("#777777", "#000000", 3) == "#777777", tostring(P.readable("#777777", "#000000", 3)))

  -- M4: a consumer that writes to the table (against the rule) cannot break the module
  local shown = P.get()
  local real_canvas = shown.canvas
  shown.canvas = "x"
  local s1 = stats_copy()
  vim.cmd("doautocmd ColorScheme")
  vim.wait(80)
  chk("M after a write to get(): an unchanged ColorScheme is skipped without a failure", P._stats.skipped_same == s1.skipped_same + 1
      and P.info().state == "ok" and P.info().reason == nil, vim.inspect({ P._stats.skipped_same - s1.skipped_same, P.info().state, P.info().reason }))
  chk("M ...the groups still carry the real canvas", vim.api.nvim_get_hl(0, { name = "JupynvimPal_canvas", link = false }).fg
      == tonumber(real_canvas:sub(2), 16), real_canvas)
  vim.api.nvim_set_hl(0, "JupynvimPal_canvas", {})
  vim.cmd("doautocmd ColorScheme")
  vim.wait(80)
  chk("M ...a wiped group is set again from the module's own copy, not from the table that was written to",
      vim.api.nvim_get_hl(0, { name = "JupynvimPal_canvas", link = false }).fg == tonumber(real_canvas:sub(2), 16)
      and P.info().reason == nil, tostring(P.info().reason))
  vim.api.nvim_set_hl(0, "Normal", { fg = "#a9b1d6" })
  vim.cmd("doautocmd ColorScheme")
  wait_for(function() return P.get() ~= shown end)
  chk("M ...the next derivation gives a new, correct table", P.get() ~= shown and P.get().canvas == real_canvas
      and P.get().text == "#a9b1d6", vim.inspect(P.get().canvas))
  vim.api.nvim_set_hl(0, "Normal", { fg = "#c0caf5" })
  P.refresh()
  ready()

  -- M5: :JupynvimPalette blames the library only when it is missing
  local notes = {}
  local orig_notify = vim.notify
  vim.notify = function(msg, level) notes[#notes + 1] = { msg = msg, level = level } end
  package.loaded["jupynvim.palette"] = nil
  local P3 = require("jupynvim.palette")
  P3._send, P3._has_tty_ui = P._send, P._has_tty_ui
  P3._collect = function() error("collect boom", 0) end
  vim.api.nvim_set_hl(0, "Normal", { fg = "#c0caf5", bg = "#101010" })
  P3.show()
  vim.wait(3000, function() return #notes > 0 end, 1)
  vim.notify = orig_notify
  package.loaded["jupynvim.palette"] = P
  local m = notes[1] and notes[1].msg or ""
  chk("M a derivation that fails with the library up: one notice that says it could not be derived, with the reason",
      #notes == 1 and m:find("^jupynvim: the palette could not be derived %(.*collect boom.*%); see :checkhealth jupynvim$") ~= nil
      and not m:find("needs libjupynvim", 1, true) and notes[1].level == vim.log.levels.WARN, vim.inspect(notes))
  vim.api.nvim_set_hl(0, "Normal", { fg = "#c0caf5" })

  -- M6: :checkhealth while the library is still being opened
  local H = require("jupynvim.health")
  local N = require("jupynvim.native")
  local function recorder()
    local lines, hh = {}, {}
    for _, k in ipairs({ "start", "ok", "info", "warn", "error" }) do
      hh[k] = function(msg) lines[#lines + 1] = k .. ": " .. msg end
    end
    return hh, lines
  end
  local real_status = N.status
  N.status = function() return { state = "unloaded" } end
  local hh, lines = recorder()
  local okh, errh = pcall(H._palette, hh)
  N.status = real_status
  local joined = table.concat(lines, "\n")
  chk("M the library still being opened: the palette section says to run :checkhealth jupynvim again", okh
      and joined:find("run :checkhealth jupynvim again", 1, true) ~= nil and not joined:find("needs libjupynvim", 1, true), joined .. tostring(errh))

  -- M7: a guess while the query is in flight says it has not been answered yet
  sent = {}
  P._set_terminal_bg(nil)
  P.when_ready(function() end)
  vim.wait(30)
  local r = P._derive_now_for_health()
  chk("M a canvas guessed while the query is in flight says the terminal has not answered yet", r and r.guess
      and r.guess:find("has not answered", 1, true) ~= nil and not r.guess:find("has not been asked", 1, true), r and tostring(r.guess))
  answer("\027]11;rgb:2222/2424/3636")
  wait_for(function() return P.info().canvas_source == "terminal" end)
  sent = {}
  ready()
end

-- ── N. Neovim's handler, and VimEnter ────────────────────────────────────
section("N. Neovim's own handler for the terminal's background, and VimEnter")
-- Neovim's description of its handler, the same in 0.11 and 0.12; it is what
-- tells it from the probe for truecolor (no description) in the same group.
local NVIM_DESC = "Update the value of 'background' automatically based on the terminal emulator's background color"
P._grace_ms = 30 -- the window after an answer, when no DSR closes it; the real one is 100
-- Neovim's handler (augroup nvim.tty, a TermResponse autocmd that sets
-- 'background' from every OSC 11 answer) does not exist in this headless run,
-- so a stand-in is made: it records what it sees and runs a nested User
-- event, as Neovim's runs the colorscheme and OptionSet autocmds. The real
-- one is proven on a real screen (palette_screen.sh, palette_terminal_screen.sh).
do
  local group = vim.api.nvim_create_augroup("nvim.tty", { clear = true })
  local seen, nested_runs = {}, 0
  vim.api.nvim_create_autocmd("User", { pattern = "JnvSpecNested", callback = function() nested_runs = nested_runs + 1 end })
  local function add_stand_in()
    return vim.api.nvim_create_autocmd("TermResponse", {
      group = group, nested = true, desc = NVIM_DESC,
      callback = function(ev)
        seen[#seen + 1] = type(ev.data) == "table" and ev.data.sequence or ev.data
        vim.api.nvim_exec_autocmds("User", { pattern = "JnvSpecNested", modeline = false })
      end,
    })
  end
  local function handlers() return #vim.api.nvim_get_autocmds({ group = "nvim.tty", event = "TermResponse" }) end
  local function reset_world()
    started = true
    tty_on = true
    P.setup({})
    vim.api.nvim_set_hl(0, "Normal", { fg = "#c0caf5" })
    P._set_terminal_bg("#222436")
    ready()
    sent = {}
  end
  add_stand_in()
  reset_world()
  chk("N the stand-in is there", handlers() == 1, handlers())

  -- N1: a question asked again: the handler is away while it is in flight and
  -- is back after, and does not see the answer
  P._on_option_background("dark", "light")
  wait_for(function() return #sent == 1 end)
  chk("N a change of 'background' asks again", #sent == 1 and sent[1] == QUERY, vim.inspect(sent))
  chk("N ...and Neovim's handler is away while the question is in flight", handlers() == 0, handlers())
  answer("\027]11;rgb:2222/2424/3636")
  chk("N ...the answer does not reach it", #seen == 0, vim.inspect(seen))
  chk("N ...the palette read the answer", P._stats.answers > 0 and P.info().canvas_source == "terminal")
  chk("N ...the handler is not put back inside the event that ended the question", handlers() == 0, handlers())
  wait_for(function() return handlers() == 1 end)
  chk("N ...it is back on the next tick, once", handlers() == 1, handlers())
  local a = vim.api.nvim_get_autocmds({ group = "nvim.tty", event = "TermResponse" })[1]
  chk("N ...as it was defined: the same function, its description", a and a.desc == NVIM_DESC
      and type(a.callback) == "function" and a.once == false, a and vim.inspect(a.desc))
  answer("\027]11;rgb:2222/2424/3636")
  chk("N ...and it sees the next answer, nested (it can run autocmds)", #seen == 1 and nested_runs == 1, #seen .. " " .. nested_runs)

  -- N2: the DSR comes first
  reset_world()
  seen = {}
  P._on_option_background("dark", "light")
  wait_for(function() return #sent == 1 end)
  chk("N a question asked again is muted too (second time)", handlers() == 0)
  answer("\027[0n")
  wait_for(function() return handlers() == 1 end)
  chk("N the terminal's DSR ends the question: the handler is back, the last color kept", handlers() == 1
      and P.get().canvas == "#222436" and P.info().canvas_source == "terminal" and #seen == 0, handlers() .. " " .. #seen)

  -- N3: no answer at all
  reset_world()
  P._osc_timeout_ms = 80
  P._on_option_background("dark", "light")
  wait_for(function() return #sent == 1 end)
  chk("N no answer: the handler is away while it waits", handlers() == 0)
  wait_for(function() return handlers() == 1 end, 1500)
  P._osc_timeout_ms = 1000
  chk("N ...and is back when the limit is over", handlers() == 1, handlers())
  chk("N ...the last color is kept", P.get().canvas == "#222436" and P.info().canvas_source == "terminal")

  -- N4: a burst of questions and answers leaves exactly one handler
  reset_world()
  for _ = 1, 6 do
    P._on_option_background("dark", "light")
    wait_for(function() return #sent >= 1 end)
    answer("\027]11;rgb:2222/2424/3636")
    sent = {}
    vim.wait(5)
  end
  wait_for(function() return handlers() == 1 end)
  vim.wait(50)
  chk("N six questions and answers in a row: one handler left, not none and not two", handlers() == 1, handlers())

  -- N5: only Neovim's handler for the background is taken: the others in the
  -- group stay where they are, with the id they have (Neovim removes its
  -- truecolor probe by id a second after start-up, so a copy under another id
  -- would stay for the session)
  reset_world()
  local probe_runs = 0
  local probe_id = vim.api.nvim_create_autocmd("TermResponse", {
    group = group, callback = function() probe_runs = probe_runs + 1 end, -- the probe: a function, no description
  })
  local cmd_id = vim.api.nvim_create_autocmd("TermResponse", { group = group, command = "let g:jnv_spec_cmd = 1" })
  local function ids()
    local t = {}
    for _, x in ipairs(vim.api.nvim_get_autocmds({ group = "nvim.tty", event = "TermResponse" })) do t[#t + 1] = x.id end
    table.sort(t)
    return t
  end
  chk("N (setup) the group holds the stand-in, a probe without description and a command", handlers() == 3, handlers())
  P._on_option_background("dark", "light")
  wait_for(function() return #sent == 1 end)
  chk("N only Neovim's handler is away while the question is in flight", handlers() == 2, handlers())
  chk("N ...the probe and the command are still there, with their ids",
      vim.deep_equal(ids(), { math.min(probe_id, cmd_id), math.max(probe_id, cmd_id) }), vim.inspect(ids()))
  answer("\027]11;rgb:2222/2424/3636")
  chk("N ...the probe saw the answer (it was not taken)", probe_runs == 1, probe_runs)
  wait_for(function() return handlers() == 3 end)
  chk("N ...all three are there after, the probe and the command with the ids they had", handlers() == 3
      and vim.tbl_contains(ids(), probe_id) and vim.tbl_contains(ids(), cmd_id), vim.inspect(ids()))
  vim.api.nvim_clear_autocmds({ group = group })
  add_stand_in()

  -- a handler with Neovim's description that cannot be put back (not a Lua
  -- function) is left alone, the question is still asked, and its answer read
  reset_world()
  vim.api.nvim_clear_autocmds({ group = group })
  vim.api.nvim_create_autocmd("TermResponse", { group = group, command = "let g:jnv_spec_cmd = 1", desc = NVIM_DESC })
  chk("N (setup) a handler with Neovim's description that is a command", handlers() == 1)
  P._on_option_background("dark", "light")
  wait_for(function() return #sent == 1 end)
  chk("N ...it cannot be put back: none is taken away", handlers() == 1, handlers())
  answer("\027]11;rgb:2222/2424/3636")
  vim.wait(60)
  chk("N ...the question is answered all the same", P.info().canvas_source == "terminal" and handlers() == 1)
  vim.api.nvim_clear_autocmds({ group = group })
  add_stand_in()

  -- N6: no nvim.tty group at all (a headless run, a Neovim without it)
  vim.api.nvim_del_augroup_by_name("nvim.tty")
  reset_world()
  P._on_option_background("dark", "light")
  wait_for(function() return #sent == 1 end)
  answer("\027]11;rgb:2222/2424/3636")
  vim.wait(60)
  chk("N without the group the question is asked and answered, nothing raised", #sent == 1
      and P.info().canvas_source == "terminal" and P.info().state == "ok")

  -- N7: the question setup() asks after start-up is muted like any other
  group = vim.api.nvim_create_augroup("nvim.tty", { clear = true })
  add_stand_in()
  seen, sent = {}, {}
  P.setup({})
  P._set_terminal_bg(nil)
  P.setup({})
  wait_for(function() return #sent == 1 end)
  chk("N setup() after startup with a transparent Normal and no known canvas asks, with the handler away", #sent == 1
      and handlers() == 0, #sent .. " " .. handlers())
  answer("\027]11;rgb:2222/2424/3636")
  wait_for(function() return handlers() == 1 end)
  chk("N ...and the handler is back", handlers() == 1)
  reset_world()
end

-- before VimEnter nothing is written: the question waits for it
do
  local function enters() return #vim.api.nvim_get_autocmds({ group = "jupynvim_palette", event = "VimEnter" }) end
  local function handlers() return #vim.api.nvim_get_autocmds({ group = "nvim.tty", event = "TermResponse" }) end
  local function enter() vim.api.nvim_exec_autocmds("VimEnter", { group = "jupynvim_palette", modeline = false }) end
  local function world()
    started, tty_on = false, true
    P._set_terminal_bg(nil)
    sent = {}
  end

  -- setup() with a transparent Normal and nothing known
  world()
  vim.api.nvim_set_hl(0, "Normal", { fg = "#c0caf5" })
  local q0 = P._stats.queries
  P.setup({})
  chk("N before VimEnter setup() writes nothing", #sent == 0 and P._stats.queries == q0, vim.inspect(sent))
  chk("N ...and waits for VimEnter (one autocmd)", enters() == 1, enters())
  P.setup({})
  chk("N ...a second setup() leaves one autocmd, not two", enters() == 1 and #sent == 0, enters())
  local got
  P.when_ready(function(t, i) got = { t = t, i = i } end)
  vim.wait(120)
  chk("N a consumer before VimEnter waits, and nothing is written", got == nil and #sent == 0, vim.inspect(sent))
  local hr = P._derive_now_for_health()
  chk("N :checkhealth before VimEnter says the terminal is asked once Neovim has started", hr and hr.guess
      and hr.guess:find("once Neovim has started", 1, true) ~= nil, hr and tostring(hr.guess))
  P._on_option_background("dark", "light")
  vim.wait(60)
  chk("N a change of 'background' before VimEnter writes nothing either", #sent == 0, #sent)
  started = true
  enter()
  chk("N VimEnter sends the question", #sent == 1 and sent[1] == QUERY, vim.inspect(sent))
  chk("N ...with Neovim's handler away, as for any question (a 'background' set right after VimEnter must stay)", handlers() == 0, handlers())
  chk("N ...and the autocmd is spent", enters() == 0, enters())
  answer("\027]11;rgb:2222/2424/3636")
  wait_for(function() return got ~= nil end)
  wait_for(function() return handlers() == 1 end)
  chk("N ...the handler is back after it", handlers() == 1, handlers())
  chk("N ...the answer releases the consumer", got and got.t and got.t.canvas == "#222436" and got.i.canvas_source == "terminal",
      got and vim.inspect(got.i.canvas_source))

  -- an opaque Normal at VimEnter: nothing to ask
  world()
  vim.api.nvim_set_hl(0, "Normal", { fg = "#c0caf5", bg = "#101010" })
  P.setup({})
  enter()
  vim.wait(60)
  chk("N an opaque Normal at VimEnter: no question", #sent == 0, vim.inspect(sent))

  -- the colorscheme turns transparent between setup() and VimEnter
  world()
  vim.api.nvim_set_hl(0, "Normal", { fg = "#c0caf5", bg = "#101010" })
  P.setup({})
  vim.api.nvim_set_hl(0, "Normal", { fg = "#c0caf5" })
  got = nil
  P.when_ready(function(t, i) got = { t = t, i = i } end)
  vim.wait(60)
  chk("N a colorscheme that turned transparent before VimEnter: the consumer waits, nothing is written", got == nil
      and #sent == 0, vim.inspect(sent))
  started = true
  enter()
  chk("N ...VimEnter asks then", #sent == 1, #sent)
  answer("\027]11;rgb:2222/2424/3636")
  wait_for(function() return got ~= nil end)
  chk("N ...and the consumer gets the terminal's canvas", got and got.t.canvas == "#222436")

  -- the terminal answers before VimEnter (Neovim's own question, say): used,
  -- nothing is sent at VimEnter, the waiting consumer goes on
  world()
  vim.api.nvim_set_hl(0, "Normal", { fg = "#c0caf5" })
  P.setup({})
  got = nil
  P.when_ready(function(t, i) got = { t = t, i = i } end)
  vim.wait(30)
  answer("\027]11;rgb:2222/2424/3636")
  wait_for(function() return got ~= nil end)
  chk("N an answer before VimEnter is used", got and got.t.canvas == "#222436" and got.i.canvas_source == "terminal")
  started = true
  enter()
  vim.wait(60)
  chk("N ...and VimEnter then sends nothing", #sent == 0, vim.inspect(sent))

  -- no terminal UI: nothing is waited for
  world()
  tty_on = false
  vim.api.nvim_set_hl(0, "Normal", { fg = "#c0caf5" })
  P.setup({})
  chk("N without a terminal UI setup() waits for nothing", enters() == 0 and #sent == 0, enters())
  tty_on = true
  started = true
  P.setup({})
  P._set_terminal_bg("#222436")
  ready()
  sent = {}
end

-- ── P. the window a question opens ───────────────────────────────────────
section("P. the window a question opens: whose answer is whose, and when it ends")
-- A question takes Neovim's handler away; the OSC 11 answers it asks for are
-- ours (the first as many as terminals asked), any other inside the window is
-- Neovim's own (its startup question, a theme report's re-query) and is given
-- to it. The DSR answers that close the questions end the window; without
-- them it ends a moment after the last answer.
do
  local OSC, DSR = "\027]11;rgb:2222/2424/3636", "\027[0n"
  local group, seen, nested_runs
  local reach = true
  P._send = function(s) sent[#sent + 1] = s; return reach end
  local function handlers() return #vim.api.nvim_get_autocmds({ group = "nvim.tty", event = "TermResponse" }) end
  vim.api.nvim_create_autocmd("User", { pattern = "JnvSpecNestedP", callback = function() nested_runs = nested_runs + 1 end })
  local function world()
    started, tty_on, reach = true, true, true
    pcall(vim.api.nvim_del_augroup_by_name, "nvim.tty")
    group = vim.api.nvim_create_augroup("nvim.tty", { clear = true })
    seen, nested_runs = {}, 0
    vim.api.nvim_create_autocmd("TermResponse", {
      group = group, nested = true, desc = NVIM_DESC,
      callback = function(ev)
        seen[#seen + 1] = type(ev.data) == "table" and ev.data.sequence or ev.data
        vim.api.nvim_exec_autocmds("User", { pattern = "JnvSpecNestedP", modeline = false })
      end,
    })
    P._grace_ms, P._osc_timeout_ms = 40, 1000
    P.setup({})
    vim.api.nvim_set_hl(0, "Normal", { fg = "#c0caf5" })
    P._set_terminal_bg("#222436")
    ready()
    sent = {}
  end
  local function ask()
    P._on_option_background("dark", "light")
    wait_for(function() return #sent >= 1 end)
  end

  -- P1: two answers to one question (Neovim's own, first, then ours): the
  -- first is counted as ours, the second goes to Neovim, which sees exactly one
  world()
  ask()
  chk("P a question takes Neovim's handler away", handlers() == 0, handlers())
  local f0 = P._stats.forwarded
  answer(OSC)
  chk("P the first answer is the palette's alone (the palette read it, Neovim's handler is away)", handlers() == 0
      and #seen == 0 and P.info().canvas_source == "terminal", handlers() .. " " .. #seen)
  answer(OSC)
  wait_for(function() return #seen == 1 end)
  chk("P ...a second answer in the window is given to Neovim's handler, once", #seen == 1 and seen[1] == OSC, vim.inspect(seen))
  chk("P ...as if it had read it: what it sets can run other autocmds", nested_runs == 1, nested_runs)
  chk("P ...and it is counted", P._stats.forwarded == f0 + 1, P._stats.forwarded - f0)
  wait_for(function() return handlers() == 1 end)
  chk("P ...the handler is back a moment after the last answer (no DSR closes the window)", handlers() == 1, handlers())
  chk("P ...and it was given nothing more", #seen == 1, #seen)

  -- P2: the DSR closes the window at once, not the grace (set far away)
  world()
  P._grace_ms = 5000
  ask()
  answer(OSC)
  chk("P an answer alone does not end the window while the DSR is awaited", handlers() == 0, handlers())
  answer(DSR)
  local t0 = vim.uv.hrtime()
  wait_for(function() return handlers() == 1 end, 1000)
  chk("P ...the DSR does, at the next tick (not the grace)", handlers() == 1 and (vim.uv.hrtime() - t0) / 1e6 < 500, handlers())
  chk("P ...nothing of ours reached Neovim's handler", #seen == 0, vim.inspect(seen))

  -- P3: Neovim's own late answer right behind our DSR, before the handler is back
  world()
  P._grace_ms = 5000
  ask()
  answer(OSC); answer(DSR); answer(OSC)
  wait_for(function() return #seen == 1 end)
  chk("P an answer behind the closing DSR, before the handler is back, still goes to Neovim", #seen == 1, vim.inspect(seen))
  wait_for(function() return handlers() == 1 end)

  -- P4: after the window an answer reaches the handler on its own, once
  world()
  ask()
  answer(OSC); answer(DSR)
  wait_for(function() return handlers() == 1 end)
  local f1 = P._stats.forwarded
  answer(OSC)
  chk("P an answer after the window reaches Neovim's handler itself, once, and is not forwarded", #seen == 1
      and P._stats.forwarded == f1, #seen .. " " .. (P._stats.forwarded - f1))

  -- P5: two terminal UIs: both answers are ours, and the window waits for both DSR answers
  world()
  P._grace_ms = 5000
  reach = 2
  ask()
  answer(OSC); answer(DSR)
  vim.wait(30)
  chk("P two terminals asked: the first one's DSR does not end the window", handlers() == 0, handlers())
  answer(OSC)
  vim.wait(10)
  chk("P ...the second one's answer is ours as well: Neovim's handler sees neither", #seen == 0, vim.inspect(seen))
  answer(DSR)
  wait_for(function() return handlers() == 1 end)
  chk("P ...the second DSR ends the window", handlers() == 1 and #seen == 0, handlers() .. " " .. #seen)
  -- the second terminal stays silent: the window ends a moment after the first's answer
  world()
  P._grace_ms = 60
  reach = 2
  ask()
  answer(OSC); answer(DSR)
  wait_for(function() return handlers() == 1 end, 1000)
  chk("P a second terminal that stays silent cannot hold the window open (the grace ends it)", handlers() == 1
      and #seen == 0, handlers() .. " " .. #seen)
  reach = true

  -- P6: the main loop is blocked past the limit; the answer, read after the
  -- timer's callback, is still ours
  world()
  P._osc_timeout_ms, P._grace_ms = 60, 300
  ask()
  local done = false
  vim.schedule(function()
    local t = vim.uv.hrtime()
    while (vim.uv.hrtime() - t) / 1e6 < 140 do end -- blocked past the limit
    local tm = vim.uv.new_timer()
    -- due after the limit (60 ms after the question; libuv's clock stood still during the block): both are
    -- overdue when the block ends and fire in that order, so the answers are read after the timer's callback
    tm:start(70, 0, vim.schedule_wrap(function()
      tm:close()
      answer(OSC); answer(DSR)
      done = true
    end))
  end)
  wait_for(function() return done end, 2000)
  wait_for(function() return handlers() == 1 end, 1000)
  vim.wait(80)
  chk("P a main loop blocked past the limit: an answer read after the timer's callback is still ours", #seen == 0
      and handlers() == 1, handlers() .. " " .. #seen)
  chk("P ...and the palette took it (the terminal's canvas, no failure noted)", P.info().canvas_source == "terminal"
      and P.info().reason == nil, vim.inspect(P.info().reason))
  P._osc_timeout_ms, P._grace_ms = 1000, 40

  -- P8: a terminal chain that answers out of order, the DSR answer before the OSC 11 answer (Neovim's own
  -- handler allows for it). The canvas falls back at once, as for a terminal that does not report; the
  -- window stays open for the OSC 11 answer that is still owed, which is ours when it comes.
  local OSC2 = "\027]11;rgb:1111/1212/1313"
  -- in one tick
  world()
  ask()
  local f8 = P._stats.forwarded
  answer(DSR); answer(OSC2)
  wait_for(function() return handlers() == 1 end, 1000)
  vim.wait(60)
  chk("P8 [DSR, OSC 11] in one tick: Neovim's handler sees neither, and nothing is forwarded", #seen == 0
      and P._stats.forwarded == f8, vim.inspect(seen))
  chk("P8 ...the handler is back (the owed answer came, nothing more is to come)", handlers() == 1, handlers())
  wait_for(function() return P.get().canvas == "#111213" end)
  chk("P8 ...the canvas is derived again from the answer that followed the DSR", P.get().canvas == "#111213"
      and P.info().canvas_source == "terminal", P.get().canvas .. " " .. tostring(P.info().canvas_source))
  -- some time apart, inside the moment the window is held
  world()
  P._grace_ms = 1500
  ask()
  answer(DSR)
  vim.wait(80)
  chk("P8 a DSR with no OSC 11 answer before it: the window stays open for the answer still owed", handlers() == 0, handlers())
  answer(OSC2)
  wait_for(function() return handlers() == 1 end, 400)
  chk("P8 ...80 ms later the answer is ours (Neovim's handler sees nothing) and it ends the window at once, not after the 1.5 s moment",
      #seen == 0 and handlers() == 1, handlers() .. " " .. #seen)
  -- no OSC 11 answer at all after the DSR: the window ends after the moment, the canvas fell back at once
  world()
  P._grace_ms = 500
  P._set_terminal_bg(nil)
  local got8, away_at_fallback, t_dsr8, t_cb8, t_back8
  P.when_ready(function(tk, inf)
    got8 = inf; t_cb8 = vim.uv.hrtime(); away_at_fallback = handlers() == 0
  end)
  vim.wait(30)
  answer(DSR)
  t_dsr8 = vim.uv.hrtime()
  wait_for(function() return got8 ~= nil end, 2000)
  chk("P8 a terminal that answers the DSR only: the canvas falls back at the DSR (the callback comes before the window has ended)",
      got8 ~= nil and got8.canvas_source == "fallback" and away_at_fallback, vim.inspect(got8 and got8.canvas_source))
  wait_for(function() return handlers() == 1 end, 3000)
  t_back8 = vim.uv.hrtime()
  chk(("P8 ...and the window ends the moment (500 ms) after the DSR, not at once (%.0f ms)"):format((t_back8 - t_dsr8) / 1e6),
      (t_back8 - t_dsr8) / 1e6 >= 450 and #seen == 0, #seen)
  -- an answer after the moment is not ours: it reaches Neovim's handler (a terminal slower than that is the residual)
  world()
  P._grace_ms = 40
  ask()
  answer(DSR)
  wait_for(function() return handlers() == 1 end, 1000)
  answer(OSC2)
  chk("P8 an OSC 11 answer after that moment reaches Neovim's handler itself, once (the known residual)", #seen == 1,
      vim.inspect(seen))
  -- two terminals, one silent: its DSR comes first, the other's OSC 11 answer and DSR follow
  world()
  P._grace_ms = 600
  reach = 2
  ask()
  answer(DSR); answer(OSC2); answer(DSR)
  vim.wait(60)
  chk("P8 two terminals, the first one silent: neither answer reaches Neovim's handler", #seen == 0, vim.inspect(seen))
  wait_for(function() return handlers() == 1 end, 3000)
  chk("P8 ...and the window ends after the moment", handlers() == 1 and #seen == 0, handlers() .. " " .. #seen)
  reach = true

  -- P9: a question asked while Neovim starts (at VimEnter, or by a setup() after it: a VimEnter autocmd, a
  -- plugin manager) is written without the flush of the screen: a redraw then clears the messages of the
  -- start-up that wait for their hit-enter prompt, and draws the screen under a later VimEnter autocmd's.
  -- The questions of the session keep the flush (P7b). A question held has its limit counted again at the
  -- next SafeState (the main loop), once.
  local flags, say_held = {}, false
  P._send = function(s, noflush)
    sent[#sent + 1] = s
    flags[#flags + 1] = noflush and "noflush" or "flush"
    return reach, say_held or nil
  end
  world()
  P._set_terminal_bg(nil)
  started = false
  P.setup({})
  flags, sent = {}, {}
  started = true
  vim.api.nvim_exec_autocmds("VimEnter", { group = "jupynvim_palette", modeline = false })
  chk("P9 the question at VimEnter is written without the flush (Neovim is still starting)", #sent == 1
      and flags[1] == "noflush", vim.inspect(flags))
  answer(OSC); answer(DSR)
  wait_for(function() return handlers() == 1 end, 1000)
  world()
  P._set_terminal_bg(nil)
  flags, sent = {}, {}
  P.setup({})
  chk("P9 ...and so is the question of a setup() after VimEnter", #sent == 1 and flags[1] == "noflush", vim.inspect(flags))
  answer(OSC); answer(DSR)
  wait_for(function() return handlers() == 1 end, 1000)
  world()
  flags = {}
  ask()
  chk("P9 ...a question of the session ('background' changed) keeps the flush", #sent == 1 and flags[1] == "flush",
      vim.inspect(flags))
  answer(OSC); answer(DSR)
  wait_for(function() return handlers() == 1 end, 1000)
  world()
  P._set_terminal_bg(nil)
  flags = {}
  wait_for(function() return #sent >= 1 end)
  chk("P9 ...and so does the question asked for a consumer", #sent == 1 and flags[1] == "flush", vim.inspect(flags))
  answer(OSC); answer(DSR)
  wait_for(function() return handlers() == 1 end, 1000)

  -- a held question: SafeState gives it its whole limit again, so an answer after the first limit is ours
  local h0 = P._stats.held
  world()
  say_held = true
  ask()
  chk("P9 a held question is counted", P._stats.held == h0 + 1, P._stats.held - h0)
  vim.wait(500)
  vim.api.nvim_exec_autocmds("SafeState", { modeline = false })
  local ts9 = uvnow()
  vim.wait(750)
  answer(OSC); answer(DSR)
  wait_for(function() return handlers() == 1 end, 1000)
  chk("P9 ...an answer 1.25 s after it (the limit is 1 s), 750 ms after a SafeState, is ours: Neovim's handler sees nothing",
      #seen == 0 and handlers() == 1, handlers() .. " " .. vim.inspect(seen))
  -- the new limit counts from the SafeState, once
  world()
  say_held = true
  P._set_terminal_bg("#222436")
  ask()
  vim.wait(300)
  vim.api.nvim_exec_autocmds("SafeState", { modeline = false })
  ts9 = uvnow()
  vim.wait(500)
  vim.api.nvim_exec_autocmds("SafeState", { modeline = false })
  local ts9b = uvnow()
  wait_for(function() return handlers() == 1 end, 3000)
  local te9 = uvnow()
  chk(("P9 ...the limit runs out a whole limit after the SafeState (%d ms), not after the question"):format(te9 - ts9),
      te9 - ts9 >= 990, te9 - ts9)
  chk(("P9 ...and a second SafeState does not start it again (%d ms after it)"):format(te9 - ts9b), te9 - ts9b < 800,
      te9 - ts9b)
  -- a question that was flushed is not held: a SafeState does not lengthen its window
  world()
  say_held = false
  ask()
  vim.wait(500)
  vim.api.nvim_exec_autocmds("SafeState", { modeline = false })
  vim.wait(750)
  answer(OSC)
  chk("P9 ...a question that was flushed is not held: SafeState leaves its limit, and an answer after it is Neovim's",
      #seen == 1, vim.inspect(seen))
  say_held = false
  P._send = function(s) sent[#sent + 1] = s; return reach end

  -- P7: the real writer says how many terminals took the query
  local list0, send0 = vim.api.nvim_list_uis, vim.api.nvim_ui_send
  local wrote = {}
  vim.api.nvim_ui_send = function(s) wrote[#wrote + 1] = s end
  vim.api.nvim_list_uis = function()
    return { { stdout_tty = true, chan = 1 }, { stdout_tty = true, chan = 3 }, { stdout_tty = false, chan = 4 } }
  end
  chk("P the real _send writes once and says how many terminals took it (a TUI and a remote UI)", orig_send("q") == 2
      and #wrote == 1 and wrote[1] == "q", tostring(orig_send("q")))
  chk("P ...a UI without a terminal does not count", orig_has_tty() == true)
  vim.api.nvim_list_uis = function() return { { stdout_tty = true, chan = 1 } } end
  chk("P ...one terminal: one", orig_send("q") == 1)
  vim.api.nvim_list_uis = function() return { { stdout_tty = false, chan = 1 } } end
  chk("P ...none: false, and no terminal UI", orig_send("q") == false and orig_has_tty() == false)

  -- P7b: Neovim 0.12 hands what nvim_ui_send is given to the UIs with the next flush of the screen; the
  -- limit and the window run from the call, so the screen is flushed right after the write
  local redraw0, cmd0 = vim.api.nvim__redraw, vim.cmd
  local waiting0 = P._msgs_waiting
  P._msgs_waiting = function() return false end
  local order = {}
  vim.api.nvim_list_uis = function() return { { stdout_tty = true, chan = 1 } } end
  vim.api.nvim_ui_send = function() order[#order + 1] = "send" end
  vim.api.nvim__redraw = function(o) order[#order + 1] = (type(o) == "table" and o.flush == true) and "flush" or "redraw?" end
  chk("P the real _send flushes the screen right after nvim_ui_send, nothing in between", orig_send("q") == 1
      and table.concat(order, ",") == "send,flush", table.concat(order, ","))
  -- a Neovim without a working nvim__redraw: ':redraw' does the same
  order = {}
  vim.api.nvim__redraw = function() error("no such thing") end
  vim.cmd = function(c) order[#order + 1] = "cmd " .. tostring(c) end
  chk("P ...with no working nvim__redraw it is ':redraw'", orig_send("q") == 1 and table.concat(order, ",") == "send,cmd redraw",
      table.concat(order, ","))
  -- a failed write is not flushed, and a failed flush does not fail the write
  order = {}
  vim.api.nvim_ui_send = function() order[#order + 1] = "send"; error("no") end
  vim.api.nvim__redraw = function() order[#order + 1] = "flush" end
  chk("P ...a write that failed is not flushed, and says false", orig_send("q") == false and table.concat(order, ",") == "send",
      table.concat(order, ","))
  vim.api.nvim_ui_send = function() order[#order + 1] = "send" end
  vim.api.nvim__redraw = function() error("no") end
  vim.cmd = function() error("no") end
  chk("P ...a flush that fails does not fail the write", orig_send("q") == 1)
  -- P9: the real _send holds a write (no flush) while Neovim starts, and while messages wait for their prompt
  vim.api.nvim__redraw, vim.cmd = redraw0, cmd0
  vim.api.nvim_ui_send = function() order[#order + 1] = "send" end
  vim.api.nvim__redraw = function() order[#order + 1] = "flush" end
  order = {}
  local n9, h9 = orig_send("q")
  chk("P9 the real _send flushes and says the write is not held", n9 == 1 and h9 == false
      and table.concat(order, ",") == "send,flush", table.concat(order, ",") .. " " .. tostring(h9))
  order = {}
  n9, h9 = orig_send("q", true)
  chk("P9 ...noflush (Neovim is starting): written, not flushed, held", n9 == 1 and h9 == true
      and table.concat(order, ",") == "send", table.concat(order, ",") .. " " .. tostring(h9))
  order = {}
  P._msgs_waiting = function() return true end
  n9, h9 = orig_send("q")
  chk("P9 ...messages waiting for their hit-enter prompt (a redraw would clear them): not flushed, held", n9 == 1
      and h9 == true and table.concat(order, ",") == "send", table.concat(order, ",") .. " " .. tostring(h9))
  order = {}
  P._msgs_waiting = function() error("no") end
  n9, h9 = orig_send("q")
  chk("P9 ...when that cannot be told: not flushed, held", n9 == 1 and h9 == true and table.concat(order, ",") == "send",
      table.concat(order, ",") .. " " .. tostring(h9))
  P._msgs_waiting = waiting0
  local state0, asked9 = rawget(vim.fn, "state"), {}
  vim.fn.state = function(w) asked9[#asked9 + 1] = w; return "s" end
  local w9a = P._msgs_waiting()
  vim.fn.state = function(w) asked9[#asked9 + 1] = w; return "" end
  local w9b = P._msgs_waiting()
  vim.fn.state = state0
  chk("P9 _msgs_waiting() is state('s'): the screen scrolled for messages", w9a == true and w9b == false
      and table.concat(asked9, ",") == "s,s", table.concat(asked9, ","))
  vim.api.nvim__redraw, vim.cmd = redraw0, cmd0
  vim.api.nvim_list_uis, vim.api.nvim_ui_send = list0, send0

  -- P10: the status answers of the gif frames written before the question (notebook/image.lua follows
  -- each frame with a DSR) come first and are not ours. image.lua gives a fence (M._fence): its marker
  -- (XTVERSION) is written before the question, and the status answers read until the marker's answer
  -- are not counted; markers off, the number of them still owed is skipped instead. The limit of the
  -- question counts from when the fence is passed (at most M._fence_limit_ms from the write).
  do
    local MARK_ANSWER = "\027P>|spec"
    local fence_orig = P._fence
    local passed_flag, owed_n = false, 0
    P._fence = function() return function() return passed_flag end, owed_n end
    P._send = function(s) sent[#sent + 1] = s; return reach end

    -- P10a: a frame's DSR answer comes first, the marker's answer, a slow terminal (longer than the grace),
    -- then the question's own OSC 11 answer and DSR
    world()
    passed_flag, owed_n = false, 0
    ask()
    answer(DSR)
    vim.wait(200)
    chk("P10 a status answer before the fence is passed is a frame's: the window stays open (not closed by it, not by the grace)",
        handlers() == 0 and P.info().canvas_source ~= "fallback", handlers())
    answer(MARK_ANSWER); passed_flag = true
    vim.wait(30)
    chk("P10 ...the marker's answer does not end it", handlers() == 0, handlers())
    answer(OSC)
    chk("P10 ...the OSC 11 answer after the marker is the palette's alone: Neovim's handler gets nothing", #seen == 0
        and P.info().canvas_source == "terminal", vim.inspect(seen))
    answer(DSR)
    wait_for(function() return handlers() == 1 end, 1000)
    chk("P10 ...and its own DSR answer ends the window", handlers() == 1 and #seen == 0, handlers() .. " " .. #seen)

    -- P10b: without the fence the same sequence ends the window at the frame's DSR and Neovim's handler gets
    -- the question's own answer (the bug the window is for)
    P._fence = fence_orig
    world()
    ask()
    answer(DSR)
    vim.wait(200)
    answer(OSC)
    chk("P10 (control) with no fence a frame's DSR answer closes the question, and its own OSC 11 answer reaches Neovim's handler",
        handlers() == 1 and #seen == 1, handlers() .. " " .. #seen)
    P._fence = function() return function() return passed_flag end, owed_n end

    -- P10c: markers off: the status answers still owed are skipped, the next one is the palette's
    world()
    passed_flag, owed_n = true, 2
    ask()
    answer(DSR); answer(DSR)
    vim.wait(200)
    chk("P10 markers off: the status answers owed to the frames are skipped; the window stays open", handlers() == 0, handlers())
    answer(OSC); answer(DSR)
    wait_for(function() return handlers() == 1 end, 1000)
    chk("P10 ...and the next OSC 11 and DSR answers are the palette's", #seen == 0 and handlers() == 1, handlers() .. " " .. #seen)

    -- P10d: the limit does not run out while the terminal is still reading what came before; it counts from
    -- the pass; the fence's own bound ends it
    world()
    P._osc_timeout_ms = 120
    passed_flag, owed_n = false, 0
    ask()
    vim.wait(400)
    local open_waiting = handlers() == 0 and P.info().reason == nil
    answer(MARK_ANSWER); passed_flag = true
    vim.wait(30)
    local open_after = handlers() == 0
    vim.wait(400)
    chk("P10 the limit does not run out while the fence is pending, and counts from the pass", open_waiting and open_after
        and handlers() == 1, ("open while waiting %s, just after the pass %s, ended after the limit %s"):format(
          tostring(open_waiting), tostring(open_after), tostring(handlers() == 1)))
    world()
    P._osc_timeout_ms, P._fence_limit_ms = 120, 300
    passed_flag, owed_n = false, 0
    ask()
    vim.wait(700)
    chk("P10 ...at most M._fence_limit_ms from the write", handlers() == 1, handlers())
    P._osc_timeout_ms, P._fence_limit_ms = 1000, 30000

    -- P10e: a fence already passed (nothing in flight) changes nothing
    world()
    passed_flag, owed_n = true, 0
    ask()
    answer(OSC); answer(DSR)
    wait_for(function() return handlers() == 1 end, 1000)
    chk("P10 a fence already passed with nothing owed changes nothing", #seen == 0 and handlers() == 1 and P.info().canvas_source == "terminal",
        handlers() .. " " .. #seen)
    P._fence = fence_orig
  end

  pcall(vim.api.nvim_del_augroup_by_name, "nvim.tty")
  P._send = function(s) sent[#sent + 1] = s; return true end
  P._grace_ms, P._osc_timeout_ms = 100, 1000
  world()
  pcall(vim.api.nvim_del_augroup_by_name, "nvim.tty")
end

-- ── O. the README's list of ports ────────────────────────────────────────
section("O. the README names exactly the colorscheme names that have a port")
do
  tty_on = true
  local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
  local lines = vim.fn.readfile(root .. "/README.md")
  local text = table.concat(lines, "\n")
  local s = text:find("3. The colors of the colorscheme's VS Code port", 1, true)
  local e = s and text:find("4. VS Code's own defaults", s, true)
  chk("O the README has the numbered step for the VS Code port", s ~= nil and e ~= nil)
  local item = (s and e) and text:sub(s, e - 1):gsub("%s+", " ") or ""
  local function names_of(s2)
    local out = {}
    for n in (s2 or ""):gmatch("`([^`]+)`") do
      if n ~= "background" then out[#out + 1] = n end
    end
    return out
  end
  -- the three sentences: any background, a dark one only, the kind that background says
  local any_s = item:match("whatever `background` says: (.-)%. With a dark")
  local dark_s = item:match("With a dark `background`, (.-) have one%.")
  local kind_s = item:match("In the light or dark kind that `background` says, (.-) have one%.")
  chk("O the README lists the three groups of names", any_s ~= nil and dark_s ~= nil and kind_s ~= nil,
      tostring(any_s) .. " | " .. tostring(dark_s) .. " | " .. tostring(kind_s))
  local function port_of(name, kind)
    local tokens, info = P._derive_input(P._input_from({ colors_name = name, background = kind, terminal = "#222436",
      groups = {}, overrides = {} }))
    return info and info.port or nil
  end
  local listed = {}
  local wrong = {}
  for _, n in ipairs(names_of(any_s)) do
    listed[n] = true
    if not (port_of(n, "dark") and port_of(n, "light")) then wrong[#wrong + 1] = n .. " (any)" end
  end
  for _, n in ipairs(names_of(dark_s)) do
    listed[n] = true
    if not (port_of(n, "dark") and not port_of(n, "light")) then wrong[#wrong + 1] = n .. " (dark only)" end
  end
  for _, n in ipairs(names_of(kind_s)) do
    listed[n] = true
    local pd, pl = port_of(n, "dark"), port_of(n, "light")
    if not (pd and pl and pd ~= pl) then wrong[#wrong + 1] = n .. " (by kind)" end
  end
  chk("O every name the README lists has a port as it says (any background, dark only, or one per kind)", #wrong == 0,
      table.concat(wrong, ", "))
  -- the names of the library's table (core/native/src/palette/ports.rs): a name
  -- with a port that the README does not list is a README that lies by omission
  local table_names = {
    "tokyonight-storm", "tokyonight-night", "catppuccin-mocha", "catppuccin-latte", "gruvbox", "dracula", "onedark",
    "onedark_vivid", "onedark_dark", "nord", "kanagawa", "kanagawa-wave", "rose-pine", "rose-pine-main", "rose-pine-dawn",
    "everforest", "solarized", "github_dark", "github_dark_default", "github_light", "github_light_default", "vscode",
  }
  local omitted, listed_without_port = {}, {}
  for _, n in ipairs(table_names) do
    if (port_of(n, "dark") or port_of(n, "light")) and not listed[n] then omitted[#omitted + 1] = n end
  end
  chk("O no name that has a port is missing from the README", #omitted == 0, table.concat(omitted, ", "))
  local variants = { "tokyonight-moon", "tokyonight-day", "catppuccin-frappe", "catppuccin-macchiato", "kanagawa-dragon",
    "kanagawa-lotus", "catppuccin" }
  local with_port = {}
  for _, n in ipairs(variants) do
    if port_of(n, "dark") or port_of(n, "light") then with_port[#with_port + 1] = n end
  end
  chk("O the variants the README says have none (and catppuccin) have none", #with_port == 0, table.concat(with_port, ", "))
end

P._send, P._has_tty_ui, P._started = orig_send, orig_has_tty, orig_started

finish()

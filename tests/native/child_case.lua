-- One case of tests/native_spec.lua in a fresh Neovim, because the library
-- loads once per process:
--
--   nvim --headless -u NONE -l tests/native/child_case.lua <repo> <case>
--
-- Prints one JSON line { available, status, notes, loaded_after_setup,
-- extra } and quits. notes are the vim.notify calls the case made (a
-- recorder replaces vim.notify), extra.require_ms is what
-- require("jupynvim.native") cost.
--
-- Cases:
--   plain    available() three times (one notice at most, whatever the state)
--   setup    require("jupynvim").setup({}) first: is jupynvim.native loaded
--            after it? Then available()
--   cfg_off  setup({ native = { enabled = false } }), then available()
--   noffi    a Neovim without LuaJIT: no ffi module and no jit table
--            ($JNV_TEST_NOFFI=1 does the same before any other case)
--   fast     the first available() and a submit from inside a luv callback
--   cfg_path setup({ native = { path = "$JNV_TEST_LIB" } }), first used from a
--            luv callback
--   setup_json require("jupynvim").setup(opts), opts the JSON object in
--            $JNV_TEST_SETUP (default {}), then available()
--   health   require("jupynvim").setup(opts), opts the JSON object in
--            $JNV_TEST_SETUP (default {}), then :checkhealth jupynvim;
--            extra.health is the report's text, extra.config_native the
--            merged native config, extra.bg_starts the background installs
--            it asked for (install.lua's run_lib_background is replaced by
--            a counter, so none ever runs). $JNV_TEST_LIB_TARGET stands in for the
--            installer's answer to "which library prebuilt is made here":
--            "none", or "<target>:<ext>"; with it, $JNV_TEST_LIB_REFUSED is
--            the reason a refused library prebuilt was recorded with.
--   wanted   setup(opts) as setup_json, then plugin_lib_wanted() only
--            (extra.wanted, extra.why, extra.clibs); nothing loads. With
--            $JNV_TEST_CONFIG_THROWS=1 the main module throws on every read
--            after setup(), as a config that cannot be read would
--   ready    when_ready(cb) with a 2 ms timer running; $JNV_TEST_FAST=1
--            calls it from a luv callback; extra.call_ms, extra.max_gap_ms,
--            extra.ready = { ok, state, fast, before_return, ms (from the
--            call to the callback) }, extra.warm = { started, done, ms, err,
--            killed, late, fallback, how, pid and exited (the probe's) }; right after
--            the call (not with $JNV_TEST_FAST) the main thread's own
--            library loads are timed: extra.ts_ms, Neovim's bundled lua
--            parser by its path (false when there is none), and
--            extra.ffi_c_ms, a first ffi.C lookup. It waits for the
--            callback up to $JNV_TEST_READY_WAIT_MS (default 10000) ms
--   heal     setup(opts) as setup_json; install.lua's run_lib_background
--            replaced by a counter; then when_ready twice ($JNV_TEST_SYNC=1:
--            available() once instead); extra.bg_starts, extra.bg_dir,
--            extra.bg_state, extra.fix, extra.bg_starts_at_cb (the count
--            when the first callback ran)
--   (health) with $JNV_TEST_BG set, the main module's _lib_bg_state is that
--            value right after setup(), as during a background install
--
-- Every case: extra.log_path, the file jupynvim.log writes to, and
-- extra.columns and extra.echospace, the screen width the notices met and
-- the room a message has there without a hit-enter prompt (v:echospace).
-- $JNV_TEST_COLUMNS sets 'columns' first (headless: 80); $JNV_TEST_PROBE_MS
-- sets the loader's limit for its probe (native.lua _probe_ms).
local repo, case = arg[1], arg[2]
if not repo or not case then
  io.stderr:write("usage: nvim --headless -u NONE -l child_case.lua <repo> <case>\n")
  vim.cmd("cquit 2")
  return
end
vim.opt.runtimepath:prepend(repo)
package.path = repo .. "/lua/?.lua;" .. repo .. "/lua/?/init.lua;" .. package.path

local notes = {}
---@diagnostic disable-next-line: duplicate-set-field
vim.notify = function(msg, level) notes[#notes + 1] = { msg = tostring(msg), level = level } end
local out = { notes = notes, extra = {} }
if (vim.env.JNV_TEST_COLUMNS or "") ~= "" then vim.o.columns = tonumber(vim.env.JNV_TEST_COLUMNS) end
if (vim.env.JNV_TEST_PROBE_MS or "") ~= "" then
  require("jupynvim.native")._probe_ms = tonumber(vim.env.JNV_TEST_PROBE_MS)
end

if case == "noffi" or vim.env.JNV_TEST_NOFFI == "1" then
  package.loaded.ffi = nil
  package.preload.ffi = function() error("module 'ffi' not found") end
  _G.jit = nil
end

local function require_native()
  local t0 = vim.uv.hrtime()
  local N = require("jupynvim.native")
  out.extra.require_ms = (vim.uv.hrtime() - t0) / 1e6
  return N
end

-- run fn inside a luv timer callback (a fast event), then wait for it and
-- for done() (optional) on the main loop
local function in_fast(fn, done)
  local timer = vim.uv.new_timer()
  local fired = false
  timer:start(0, 0, function()
    fn()
    timer:close()
    fired = true
  end)
  vim.wait(3000, function() return fired and (not done or done()) end, 1)
  vim.wait(50)
end

local N
if case == "plain" or case == "noffi" then
  N = require_native()
  out.available = N.available()
  N.available()
  N.available()
elseif case == "fast" then
  -- the first use comes from a fast event (a luv callback), where vim.fn
  -- (most of it), vim.env and nvim_create_autocmd are not allowed
  N = require_native()
  in_fast(function()
    out.extra.in_fast = vim.in_fast_event()
    local ok, avail = pcall(N.available)
    out.extra.load_ok, out.extra.load_err = ok, (not ok) and tostring(avail) or nil
    out.available = ok and avail or false
    if out.available then
      out.extra.submitted = N.submit(N.KIND.ECHO, "from a fast event", {}, function(_, v)
        out.extra.echo, out.extra.echo_fast = v, vim.in_fast_event()
      end) ~= nil
    end
  end, function() return out.extra.echo ~= nil or not out.available end)
  local okh, hooks = pcall(vim.api.nvim_get_autocmds, { group = "jupynvim_native", event = "VimLeavePre" })
  out.extra.leave_hooks = okh and #hooks or 0
elseif case == "cfg_path" then
  -- setup({ native = { path } }) with an environment variable in it, first
  -- used from a fast event
  require("jupynvim").setup({ native = { path = "$JNV_TEST_LIB" } })
  N = require_native()
  in_fast(function()
    local ok, avail = pcall(N.available)
    out.extra.load_ok, out.extra.load_err = ok, (not ok) and tostring(avail) or nil
    out.available = ok and avail or false
  end)
elseif case == "setup_json" then
  local opts = {}
  if (vim.env.JNV_TEST_SETUP or "") ~= "" then opts = vim.json.decode(vim.env.JNV_TEST_SETUP) end
  require("jupynvim").setup(opts)
  N = require_native()
  out.available = N.available()
elseif case == "wanted" then
  -- whether the background install would fetch the plugin's own library:
  -- settings only, so nothing below may load the library either
  local opts = {}
  if (vim.env.JNV_TEST_SETUP or "") ~= "" then opts = vim.json.decode(vim.env.JNV_TEST_SETUP) end
  require("jupynvim").setup(opts)
  if vim.env.JNV_TEST_CONFIG_THROWS == "1" then
    package.loaded["jupynvim"] = setmetatable({}, { __index = function() error("test: config exploded") end })
  end
  N = require_native()
  local w, why = N.plugin_lib_wanted()
  out.extra.wanted, out.extra.why = w, why
  local clibs = 0
  for _ in pairs(debug.getregistry().jupynvim_native.clibs) do clibs = clibs + 1 end
  out.extra.clibs = clibs
  out.available = false
elseif case == "ready" then
  N = require_native()
  local okffi, cffi = pcall(require, "ffi")
  if okffi and vim.env.JNV_TEST_NOFFI ~= "1" then cffi.cdef("int getppid(void);") end
  -- the largest gap between the runs of a 2 ms timer, from just before
  -- the call until the callback
  local maxgap, last = 0, vim.uv.hrtime()
  local timer = vim.uv.new_timer()
  timer:start(2, 2, function()
    local t = vim.uv.hrtime()
    if t - last > maxgap then maxgap = t - last end
    last = t
  end)
  local got, returned, t_call = nil, false, nil
  local function cb(ok, st)
    got = { ok = ok, state = st.state, fast = vim.in_fast_event(), before_return = not returned,
            ms = (vim.uv.hrtime() - t_call) / 1e6 }
  end
  local function call()
    local t0 = vim.uv.hrtime()
    t_call = t0
    N.when_ready(cb)
    out.extra.call_ms = (vim.uv.hrtime() - t0) / 1e6
    returned = true
  end
  if vim.env.JNV_TEST_FAST == "1" then
    in_fast(call)
  else
    call()
    -- right away, while a first open may still run: the main thread's own
    -- library loads must not wait for it (on macOS a dlopen holds dyld's
    -- lock). Neovim's own parser, by its path: one that other processes
    -- opened before, so its own first open is quick.
    local parser = vim.fs.normalize(vim.fs.dirname(vim.fs.dirname(vim.v.progpath)) .. "/lib/nvim/parser/lua.so")
    out.extra.ts_ms = false
    if vim.uv.fs_stat(parser) then
      local t0 = vim.uv.hrtime()
      pcall(vim.treesitter.language.add, "lua", { path = parser })
      out.extra.ts_ms = (vim.uv.hrtime() - t0) / 1e6
    end
    if okffi and vim.env.JNV_TEST_NOFFI ~= "1" then
      local t0 = vim.uv.hrtime()
      local _ = cffi.C.getppid
      out.extra.ffi_c_ms = (vim.uv.hrtime() - t0) / 1e6
    end
  end
  vim.wait(tonumber(vim.env.JNV_TEST_READY_WAIT_MS) or 10000, function() return got ~= nil end, 1)
  local t = vim.uv.hrtime()
  if t - last > maxgap then maxgap = t - last end
  timer:stop()
  timer:close()
  out.extra.max_gap_ms = maxgap / 1e6
  out.extra.ready = got
  local w = debug.getregistry().jupynvim_native.warm
  -- a probe that ended, or was stopped at the limit, has exited by now or
  -- within moments: its exit callback marks it
  if got and w and w.proc and not w.exited then vim.wait(3000, function() return w.exited == true end, 5) end
  out.extra.warm = { started = w ~= nil, done = w and w.done, ms = w and w.ms, err = w and w.err,
                     killed = w and w.killed, late = w and w.late, fallback = w and w.fallback, how = w and w.how,
                     pid = w and w.proc and w.proc.pid, exited = w and w.exited }
  out.available = got and got.ok or false
elseif case == "heal" then
  -- a first use that finds the plugin's own library missing or stale asks
  -- for the background install a notebook open starts; available() never
  local opts = {}
  if (vim.env.JNV_TEST_SETUP or "") ~= "" then opts = vim.json.decode(vim.env.JNV_TEST_SETUP) end
  require("jupynvim").setup(opts)
  local I = require("jupynvim.backend.install")
  local starts = 0
  I.run_lib_background = function(dir)
    starts = starts + 1
    out.extra.bg_dir = dir
    return true
  end
  N = require_native()
  if vim.env.JNV_TEST_SYNC == "1" then
    N.available()
  else
    for i = 1, 2 do
      local got
      N.when_ready(function()
        got = true
        if i == 1 then out.extra.bg_starts_at_cb = starts end
      end)
      vim.wait(10000, function() return got end, 1)
    end
  end
  vim.wait(300) -- the ask is scheduled
  out.extra.bg_starts = starts
  out.extra.bg_state = require("jupynvim")._lib_bg_state
  out.extra.fix = N.status().fix
  out.available = N.status().state == "ok"
elseif case == "setup" or case == "cfg_off" then
  require("jupynvim").setup(case == "cfg_off" and { native = { enabled = false } } or {})
  out.loaded_after_setup = package.loaded["jupynvim.native"] ~= nil
  N = require_native()
  out.available = N.available()
elseif case == "health" then
  local opts = {}
  if (vim.env.JNV_TEST_SETUP or "") ~= "" then opts = vim.json.decode(vim.env.JNV_TEST_SETUP) end
  local J = require("jupynvim")
  J.setup(opts)
  if (vim.env.JNV_TEST_BG or "") ~= "" then J._lib_bg_state = vim.env.JNV_TEST_BG end
  out.loaded_after_setup = package.loaded["jupynvim.native"] ~= nil
  out.extra.config_native = vim.deepcopy(J.config.native)
  local I = require("jupynvim.backend.install")
  out.extra.bg_starts = 0
  I.run_lib_background = function()
    out.extra.bg_starts = out.extra.bg_starts + 1
    return true
  end
  local lt = vim.env.JNV_TEST_LIB_TARGET
  if lt and lt ~= "" then
    local target, ext = lt:match("^([^:]+):(.+)$")
    I._lib_target = function() return target and { target = target, ext = ext } or nil end
    local refused, known_bad = vim.env.JNV_TEST_LIB_REFUSED, I.known_bad
    I.known_bad = function(tag, t)
      if refused and refused ~= "" and t == "lib-" .. tostring(target) then return refused end
      return known_bad(tag, t)
    end
  end
  vim.cmd("checkhealth jupynvim")
  out.extra.health = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  N = require("jupynvim.native")
  out.available = N.available()
else
  io.stderr:write("unknown case " .. tostring(case) .. "\n")
  vim.cmd("cquit 2")
  return
end

-- the notice is scheduled; let it land
vim.wait(100)
out.status = N.status()
if not out.available and case ~= "wanted" and case ~= "ready" and case ~= "heal" then
  local r, e = N.submit(N.KIND.NOP, "", {}, nil)
  out.extra.submit_nil, out.extra.submit_err = r == nil, e
  local ok, msg = N.call(N.KIND.NOP, "")
  out.extra.call_ok, out.extra.call_msg = ok, msg
end
local okl, Lg = pcall(require, "jupynvim.log")
if okl and type(Lg) == "table" and type(Lg.path) == "function" then out.extra.log_path = Lg.path() end
out.extra.columns, out.extra.echospace = vim.o.columns, vim.v.echospace
-- on a line of its own: :checkhealth writes progress to stdout with no newline
io.stdout:write("\n", vim.json.encode(out), "\n")
vim.cmd("qa!")

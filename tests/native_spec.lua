-- The in-process library (libjupynvim) seen from Lua: lua/jupynvim/native.lua.
--
--   nvim --headless -u NONE -c "luafile tests/native_spec.lua" -c "cquit 3"
--
-- A  discovery, the first load and the checks it makes on the real library
-- B  synchronous calls (jnv_call): bytes in and out, in place reads, errors
-- C  jobs on the worker threads, the wake pipe and the pump that hands
--    results to callbacks; C11 a callback that runs the event loop
--    (vim.wait) or closes its own context in the middle of a batch
-- D  budgets: what a call, a submit, a round trip, a large result, a burst
--    and a long job may cost the UI thread, and no buffer left behind
-- E  shutdown: closing never waits for a running job
-- F  the path without the library: turned off, missing, unloadable,
--    unsupported, whether the background install would fetch the plugin's
--    own library, and the fake libraries for every refused mismatch
-- H  :checkhealth jupynvim for each of those states, and setup()'s native
--    key merged into its defaults
--
-- It needs the library and the fake libraries, which section 1 of
-- tests/run_all.sh builds: cd core && cargo build --release && cargo build
-- --release --examples. A missing one is a failure, never a skip.

local fails = 0
local function chk(name, cond, detail)
  if cond then io.write("  ok " .. name .. "\n")
  else io.write("FAIL " .. name .. (detail and ("  -- " .. tostring(detail)) or "") .. "\n"); fails = fails + 1 end
end
local function finish()
  if fails == 0 then
    io.write("\nALL NATIVE CHECKS PASSED\n")
    vim.cmd("qa!")
  else
    io.write(("\nNATIVE: %d CHECK(S) FAILED\n"):format(fails))
    vim.cmd("cquit 1")
  end
end
local function section(title) io.write("\n-- " .. title .. "\n") end

local REPO = vim.fn.getcwd()
package.path = REPO .. "/lua/?.lua;" .. REPO .. "/lua/?/init.lua;" .. package.path
local ffi = require("ffi")
local EXT = jit.os == "OSX" and "dylib" or "so"
local LIB = REPO .. "/core/target/release/libjupynvim." .. EXT
local FAKE = REPO .. "/core/target/release/examples/libjnv_fake." .. EXT
local NOSYM = REPO .. "/core/target/release/examples/libjnv_fake_nosym." .. EXT
local BUILD = "cd core && cargo build --release"
local BUILD_FAKES = "cd core && cargo build --release --examples"

local function manifest_version(dir)
  for line in io.lines(dir .. "/core/Cargo.toml") do
    local v = line:match('^version%s*=%s*"([^"]+)"')
    if v then return v end
  end
end
local VERSION = manifest_version(REPO)
local function now() return vim.uv.hrtime() end
local function ms_since(t0) return (vim.uv.hrtime() - t0) / 1e6 end
local function has(s, sub) return type(s) == "string" and s:find(sub, 1, true) ~= nil end

-- One case of tests/native/child_case.lua in a fresh Neovim, in directory
-- cwd (default: this one), with repo as the plugin (default: this one);
-- its JSON line.
local function child(case, env, cwd, repo)
  local r = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-l",
    REPO .. "/tests/native/child_case.lua", repo or REPO, case }, { env = env, cwd = cwd, text = true }):wait(30000)
  local line
  for l in (r.stdout or ""):gmatch("[^\n]+") do
    if l:sub(1, 1) == "{" then line = l end
  end
  local ok, j = pcall(vim.json.decode, line or "")
  if not ok or type(j) ~= "table" then
    return nil, ("exit %s, stdout %q, stderr %q"):format(tostring(r.code), r.stdout or "", r.stderr or "")
  end
  j.notes = type(j.notes) == "table" and j.notes or {}
  j.status = type(j.status) == "table" and j.status or {}
  j.extra = type(j.extra) == "table" and j.extra or {}
  return j, vim.inspect(j)
end

section("files the spec needs")
chk("the library is built (" .. LIB .. ")", vim.uv.fs_stat(LIB) ~= nil, "build it: " .. BUILD)
chk("the fake library is built (" .. FAKE .. ")", vim.uv.fs_stat(FAKE) ~= nil, "build it: " .. BUILD_FAKES)
chk("the fake without symbols is built (" .. NOSYM .. ")", vim.uv.fs_stat(NOSYM) ~= nil,
    "build it: " .. BUILD_FAKES)
chk("core/Cargo.toml names a version", VERSION ~= nil)

-- ── A. discovery and the first load ──────────────────────────────────────
section("A. discovery and the first load")
local t_req = now()
local okreq, N = pcall(require, "jupynvim.native")
local req_ms = ms_since(t_req)
chk("A1 require(\"jupynvim.native\") works", okreq and type(N) == "table", tostring(N))
if not okreq or type(N) ~= "table" then finish() return end
local S = debug.getregistry().jupynvim_native
chk("A1 the state lives in the Lua registry", type(S) == "table")
chk("A1 the require loads nothing (state unloaded)", N.status().state == "unloaded", N.status().state)

-- A load happens once per process, so a value over budget is measured again
-- in up to two fresh processes; the first one under budget passes.
local function budget(name, value, limit, pick)
  local vals = { ("%.3f"):format(value) }
  local pass = value < limit
  local n = 0
  while not pass and n < 2 do
    n = n + 1
    local j, why = child("plain")
    local v = j and pick(j)
    vals[#vals + 1] = type(v) == "number" and ("%.3f"):format(v) or ("? (" .. tostring(why) .. ")")
    if type(v) == "number" and v < limit then pass = true end
  end
  chk(("%s under %d ms (runs: %s ms)"):format(name, limit, table.concat(vals, ", ")), pass)
end
budget("A1 require", req_ms, 2, function(j) return j.extra.require_ms end)

local avail = N.available()
chk("A2 available() is true", avail == true, vim.inspect(N.status()))
if not avail then
  chk("A..F need the library; build it", false, BUILD .. " (status: " .. vim.inspect(N.status()) .. ")")
  finish()
  return
end
local st = N.status()
io.write(("  status: state=%s version=%s abi=%s path=%s workers=%s load_ms=%.3f reason=%s fix=%s\n"):format(
  tostring(st.state), tostring(st.version), tostring(st.abi), tostring(st.path), tostring(st.workers),
  tonumber(st.load_ms) or -1, tostring(st.reason), tostring(st.fix)))
chk("A3 state is ok", st.state == "ok", st.state)
chk("A3 version equals core/Cargo.toml (v" .. tostring(VERSION) .. ")", st.version == VERSION, st.version)
chk("A3 ABI is 1.0", st.abi == "1.0", st.abi)
chk("A3 path is the build next to jupynvim-core", st.path == LIB, st.path)
chk("A3 and it came from the plugin's own place (source plugin)", st.source == "plugin", tostring(st.source))
chk("A3 1 to 4 worker threads", type(st.workers) == "number" and st.workers >= 1 and st.workers <= 4,
    st.workers)
budget("A3 first load()", st.load_ms, 20, function(j) return j.status.load_ms end)
local ctx0 = S.ctx
chk("A3 load() again is a no-op that keeps the one context", N.load() == true and S.ctx == ctx0 and ctx0 ~= nil)
-- through pcall: with no such augroup nvim_get_autocmds throws, which
-- would end the spec here instead of reporting this check
local okg, aus = pcall(vim.api.nvim_get_autocmds, { group = "jupynvim_native", event = "VimLeavePre" })
chk("A3 a VimLeavePre hook in augroup jupynvim_native closes it", okg and #aus == 1, okg and #aus or aus)

-- the declarations Lua uses are the header's, word for word
local hdr = table.concat(vim.fn.readfile(REPO .. "/core/native/include/jupynvim.h"), "\n")
local block = hdr:match("/%* JNV%-CDEF%-BEGIN %*/(.-)/%* JNV%-CDEF%-END %*/")
local function norm(s)
  s = s:gsub("/%*.-%*/", ""):gsub("%s+", " ")
  return (s:gsub("^ ", ""):gsub(" $", ""))
end
chk("A4 the header has a CDEF block", block ~= nil)
chk("A4 M._CDEF equals the header's CDEF block", block ~= nil and type(N._CDEF) == "string"
    and norm(block) == norm(N._CDEF), N._CDEF)
-- every constant of the header, as LuaJIT sees it, equals the Lua tables
local consts = 0
for name, val in (block or ""):gmatch("JNV_([%w_]+)%s*=%s*(%d+)") do
  consts = consts + 1
  val = tonumber(val)
  local lua
  if name:match("^KIND_") then lua = N.KIND[name:sub(6)]
  elseif name:match("^PRIO_") then lua = N.PRIO[name:sub(6):lower()]
  elseif name == "FLAG_COPY" then lua = N.FLAG_COPY
  elseif name:match("^SIZEOF_") then lua = val
  else lua = N.STATUS[name] end
  local okc, cval = pcall(function() return ffi.C["JNV_" .. name] end)
  chk(("A5 JNV_%s = %d in ffi.C and in native.lua"):format(name, val),
      okc and cval == val and lua == val, ("ffi %s, lua %s"):format(tostring(cval), tostring(lua)))
end
chk("A5 the header declares all 21 constants", consts == 21, consts)
local function count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
chk("A5 native.lua has no constant the header lacks",
    count(N.KIND) == 7 and count(N.STATUS) == 8 and count(N.PRIO) == 3)
local lib = N.lib()
chk("A6 lib() gives the loaded library", lib ~= nil and lib == S.lib)
local kinds_ok = true
for k = 1, 7 do if lib.jnv_kind_supported(k) ~= 1 then kinds_ok = false end end
chk("A6 jnv_kind_supported is 1 for kinds 1 to 7", kinds_ok)
chk("A6 jnv_kind_supported is 0 for 0, 8 and 65535",
    lib.jnv_kind_supported(0) == 0 and lib.jnv_kind_supported(8) == 0 and lib.jnv_kind_supported(65535) == 0)
chk("A6 has_abi(0) is true, has_abi(1) is false", N.has_abi(0) == true and N.has_abi(1) == false)
local src = table.concat(vim.fn.readfile(REPO .. "/lua/jupynvim/native.lua"), "\n"):lower()
chk("A7 native.lua never mentions mpack or msgpack", not has(src, "mpack") and not has(src, "msgpack"))
-- the largest worker count native.lua asks for is the largest the library takes
do
  local maxw = N.MAX_WORKERS
  local err = ffi.new("jnv_buf*[1]")
  local okm, at_max = pcall(function() return lib.jnv_open(maxw, err) end)
  local opened = okm and at_max ~= nil
  if opened then lib.jnv_close(at_max) end
  local above, msg = nil, nil
  if type(maxw) == "number" then
    above = lib.jnv_open(maxw + 1, err)
    if above ~= nil then lib.jnv_close(above) end
    if err[0] ~= nil then
      msg = ffi.string(err[0].ptr, tonumber(err[0].len))
      lib.jnv_buf_free(err[0])
      err[0] = nil
    end
  end
  chk(("A8 the library opens with native.lua's MAX_WORKERS (%s) worker threads"):format(tostring(maxw)),
      maxw == 64 and opened, okm and "" or tostring(at_max))
  chk("A8 and refuses one more, naming the range 1 to 64", type(maxw) == "number" and above == nil
      and has(msg, "1 to 64"), tostring(msg))
end

-- A9, A10: loading without blocking. A first dlopen of a library file no
-- process has opened before takes tens of milliseconds on macOS and holds
-- dyld's lock meanwhile; when_ready does that first open away from the UI
-- thread and calls back on the main loop once the library is loaded.
local atmp = vim.fn.tempname()
vim.fn.mkdir(atmp, "p")
local function loadavg()
  local a, b, c = vim.uv.loadavg()
  return ("%.2f %.2f %.2f"):format(a, b, c)
end
-- a copy of the library no process has opened yet
local fresh_n = 0
local function fresh_copy(from)
  fresh_n = fresh_n + 1
  local d = atmp .. "/fresh" .. fresh_n
  vim.fn.mkdir(d, "p")
  local p = d .. "/libjupynvim." .. EXT
  vim.uv.fs_copyfile(from or LIB, p)
  return p
end
-- The processes whose command line names path (a fresh copy only a probe
-- Neovim names), looked for up to ms after its editor exited; any found is
-- stopped with SIGKILL, so a failing check leaves nothing behind. Their
-- "pid command" lines, "" for none.
local function leftover(path, ms)
  local found
  local deadline = vim.uv.hrtime() + (ms or 3000) * 1e6
  repeat
    found = {}
    local r = vim.system({ "ps", "-A", "-o", "pid=,command=" }, { text = true }):wait(5000)
    for l in (r.stdout or ""):gmatch("[^\n]+") do
      if l:find(path, 1, true) then found[#found + 1] = vim.trim(l) end
    end
    if #found == 0 then return "" end
    vim.wait(50)
  until vim.uv.hrtime() > deadline
  for _, l in ipairs(found) do
    local pid = tonumber(l:match("^(%d+)"))
    if pid then pcall(vim.uv.kill, pid, "sigkill") end
  end
  return table.concat(found, "; ")
end
do
  -- Neovim's own lua parser, which A9's child loads by its path right after
  -- when_ready: opened here once first, so its own first open is quick
  local parser = vim.fs.normalize(vim.fs.dirname(vim.fs.dirname(vim.v.progpath)) .. "/lib/nvim/parser/lua.so")
  if vim.uv.fs_stat(parser) then pcall(vim.treesitter.language.add, "lua", { path = parser }) end
  local runs, passed = {}, false
  for r = 1, 3 do
    local copy = fresh_copy()
    local j, why = child("ready", { JUPYNVIM_NATIVE = copy })
    local e = j and j.extra or {}
    local rd, w = type(e.ready) == "table" and e.ready or {}, type(e.warm) == "table" and e.warm or {}
    local call_ms, load_ms = tonumber(e.call_ms), j and tonumber(j.status.load_ms)
    local gap, ts, fc = tonumber(e.max_gap_ms), e.ts_ms, tonumber(e.ffi_c_ms)
    local text = j and ("call %.3f ms, load %.3f ms, first open away from the UI thread %s ms, largest timer gap %.2f ms,"
      .. " a parser load meanwhile %s ms, a first ffi.C lookup %s ms, load %s"):format(
        call_ms or -1, load_ms or -1, w.ms and ("%.1f"):format(w.ms) or "none", gap or -1,
        ts == false and "(no bundled parser)" or ("%.3f"):format(tonumber(ts) or -1),
        fc and ("%.3f"):format(fc) or "?", loadavg()) or ("no answer: " .. tostring(why))
    io.write(("  A9 run%d: %s\n"):format(r, text))
    runs[#runs + 1] = ("run%d %s"):format(r, text)
    if j and rd.ok == true and rd.state == "ok" and call_ms and load_ms and call_ms + load_ms < 10
        and gap and gap < 25 and (ts == false or (tonumber(ts) or 99) < 10) and fc and fc < 10 then
      passed = true
      break
    end
  end
  chk(("A9 when_ready on a library file never opened before: under 10 ms of UI-thread time, no main-loop gap"
    .. " over 25 ms, and the main thread's own library loads meanwhile under 10 ms each (%s)"):format(
      table.concat(runs, "; ")), passed)
  local j = child("plain", { JUPYNVIM_NATIVE = fresh_copy() })
  io.write(("  A9 for comparison, a synchronous first load of a fresh copy: %s ms (load %s)\n"):format(
    j and tostring(j.status.load_ms) or "?", loadavg()))
end
do
  -- in this process, where it is loaded
  local r10, ret10
  N.when_ready(function(ok10, st10)
    r10 = { ok = ok10, state = st10.state, fast = vim.in_fast_event(), before = not ret10 }
  end)
  ret10 = true
  vim.wait(1000, function() return r10 ~= nil end, 1)
  chk("A10 loaded: when_ready calls back with ok and state ok, on the main loop, after it returned",
      r10 ~= nil and r10.ok == true and r10.state == "ok" and r10.fast == false and r10.before == false, vim.inspect(r10))
  local function ready(env)
    local j, why = child("ready", env)
    local e = j and j.extra or {}
    return j, type(e.ready) == "table" and e.ready or {}, type(e.warm) == "table" and e.warm or {}, why
  end
  local j, rd, w, why = ready({ JUPYNVIM_NATIVE = atmp .. "/none." .. EXT })
  chk("A10 a missing file: when_ready gives false, state missing, nothing to open, no notice", j ~= nil
      and rd.ok == false and rd.state == "missing" and w.started == false and #j.notes == 0
      and rd.fast == false and rd.before_return == false, why)
  j, rd, w, why = ready({ JUPYNVIM_NATIVE = "off" })
  chk("A10 JUPYNVIM_NATIVE=off: false, disabled, nothing to open", j ~= nil and rd.ok == false
      and rd.state == "disabled" and w.started == false and #j.notes == 0, why)
  j, rd, w, why = ready({ JNV_TEST_NOFFI = "1" })
  chk("A10 a Neovim without LuaJIT: false, unsupported", j ~= nil and rd.ok == false and rd.state == "unsupported"
      and w.started == false and #j.notes == 0, why)
  local agarbage = atmp .. "/garbage." .. EXT
  vim.fn.writefile({ "not a library" }, agarbage)
  j, rd, w, why = ready({ JUPYNVIM_NATIVE = agarbage })
  local warns = 0
  for _, n in ipairs(j and j.notes or {}) do if n.level == vim.log.levels.WARN then warns = warns + 1 end end
  chk("A10 a file that does not load: the open ran, false, state error, exactly one WARN notice", j ~= nil
      and w.started == true and w.done == true and rd.ok == false and rd.state == "error" and #j.notes == 1
      and warns == 1, why)
  if jit.os == "OSX" then
    chk("A10 and on macOS the separate Neovim that opened it first said why", j ~= nil
        and has(w.err, "could not be loaded from " .. agarbage) and w.how == "probe", why)
  end
  j, rd, w, why = ready({ JUPYNVIM_NATIVE = fresh_copy(), JNV_TEST_FAST = "1" })
  chk("A10 called from a luv callback (a fast event): true, and the callback runs on the main loop", j ~= nil
      and rd.ok == true and rd.state == "ok" and rd.fast == false and rd.before_return == false, why)
  if jit.os == "OSX" then
    -- a library that kills the process that loads it: the separate Neovim
    -- dies, this one never loads it and goes on without it
    local killer = fresh_copy(FAKE)
    j, rd, w, why = ready({ JUPYNVIM_NATIVE = killer, JNV_FAKE = "signal" })
    chk("A10 a library that kills the Neovim that loads it is never loaded here: false, state error, one WARN",
        j ~= nil and rd.ok == false and rd.state == "error" and has(j.status.reason, "could not be loaded from " .. killer)
        and has(j.status.reason, "killed by signal 31 (SIGUSR2)") and #j.notes == 1
        and j.notes[1].level == vim.log.levels.WARN and w.killed ~= nil, why)
    -- SIGKILL is how macOS ends a process that maps a library page whose
    -- code signature fails (a build copied over a library a process holds
    -- open): the library's doing, never someone else's
    local k9 = fresh_copy(FAKE)
    j, rd, w, why = ready({ JUPYNVIM_NATIVE = k9, JNV_FAKE = "kill" })
    chk("A10 a library whose load ends the Neovim with SIGKILL is never loaded here: false, state error, one WARN",
        j ~= nil and rd.ok == false and rd.state == "error" and has(j.status.reason, "could not be loaded from " .. k9)
        and has(j.status.reason, "killed by signal 9 (SIGKILL)") and #j.notes == 1
        and j.notes[1].level == vim.log.levels.WARN and w.killed ~= nil, why)
    -- a load that never returns (it deadlocks): the probe is stopped at the
    -- loader's limit, 1 s here, and the file refused for this session; never
    -- loaded on this main loop, where it would never return either
    local hung = fresh_copy(FAKE)
    j, rd, w, why = ready({ JUPYNVIM_NATIVE = hung, JNV_FAKE = "hang", JNV_TEST_PROBE_MS = "1000" })
    local left = leftover(hung)
    local rms = tonumber(rd.ms)
    chk(("A10 a library whose load never returns: false at the limit (1 s; the callback after %s ms), state error,"
      .. " gave no answer, one WARN"):format(rms and ("%.1f"):format(rms) or "no"),
        j ~= nil and rd.ok == false and rd.state == "error" and has(j.status.reason, "could not be loaded from " .. hung)
        and has(j.status.reason, "a separate Neovim that loaded it first gave no answer within 1 s")
        and rms ~= nil and rms >= 900 and rms < 4000 and #j.notes == 1 and j.notes[1].level == vim.log.levels.WARN
        and w.late ~= nil, ("callback after %s ms: %s"):format(tostring(rd.ms), why))
    chk("A10 and the probe itself is stopped at the limit: its exit is seen while the editor still runs",
        j ~= nil and w.exited == true, ("exited %s: %s"):format(tostring(w.exited), why))
    chk(("A10 and the editor's main loop kept running meanwhile (largest 2 ms timer gap %s ms, under 250)"):format(
        tostring(j and j.extra.max_gap_ms)), j ~= nil and (tonumber(j.extra.max_gap_ms) or 999) < 250, why)
    chk("A10 and its probe Neovim is gone once the editor has exited", j ~= nil and w.pid ~= nil and left == "",
        ("pid %s, left: %s"):format(tostring(w.pid), left))
    -- the editor exits while its probe still hangs, before the limit: the
    -- probe is stopped for good (a TERM is never acted on there)
    local hung2 = fresh_copy(FAKE)
    j, rd, w, why = ready({ JUPYNVIM_NATIVE = hung2, JNV_FAKE = "hang", JNV_TEST_READY_WAIT_MS = "300" })
    left = leftover(hung2)
    chk("A10 an editor that exits while its probe hangs leaves no probe Neovim behind", j ~= nil and rd.ok == nil
        and w.started == true and w.pid ~= nil and left == "", ("pid %s, left: %s; %s"):format(tostring(w.pid), left, why))
  else
    io.write("  A10 a library that kills the Neovim that loads it: macOS only (the first open is here elsewhere)\n")
  end
  -- _forget_missing() forgets a finished first open too, so a library
  -- installed since is opened away from the UI thread again
  local saved = { S.state, S.warm, S.reason, S.fix, S.load_ms }
  S.state, S.warm = "missing", { done = true }
  N._forget_missing()
  local forgot = S.warm == nil and S.state == "unloaded"
  S.state, S.warm, S.reason, S.fix, S.load_ms = unpack(saved, 1, 5)
  chk("A10 _forget_missing() forgets a finished first open too", forgot)
end
vim.fn.delete(atmp, "rf")

-- ── B. synchronous calls ─────────────────────────────────────────────────
section("B. synchronous calls")
local live0 = tonumber(lib.jnv_live_buffers())
local K, ST = N.KIND, N.STATUS
local s_nul = "a\0b\0\0c\0"
local ok, v, code = N.call(K.ECHO, s_nul)
chk("B1 ECHO round trips a string with NUL bytes", ok == true and v == s_nul and code == ST.OK, vim.inspect({ ok, v, code }))
ok, v, code = N.call(K.ECHO, "")
chk("B1 ECHO round trips an empty string", ok == true and v == "" and code == ST.OK, vim.inspect({ ok, v, code }))
local seed, bytes = 12345, {}
for i = 1, 4096 do seed = (seed * 1103515245 + 12345) % 2147483648; bytes[i] = string.char(math.floor(seed / 65536) % 256) end
local mib = string.rep(table.concat(bytes), 256)
ok, v = N.call(K.ECHO, mib)
chk("B1 ECHO round trips 1 MiB of varied bytes", ok == true and #mib == 1048576 and v == mib)
local function u64_at(buf) return tonumber(ffi.cast("const uint64_t*", buf.ptr)[0]) end
local sc, buf = N.call_raw(K.BYTESUM, string.rep("\1", 1e6))
chk("B2 BYTESUM of 1e6 one bytes is 1e6, read in place", sc == ST.OK and buf ~= nil and tonumber(buf.len) == 8
    and u64_at(buf) == 1e6, buf ~= nil and u64_at(buf) or sc)
N.free(buf)
sc, buf = N.call_raw(K.BYTESUM, "\255\255")
chk("B2 BYTESUM of \\255\\255 is 510", sc == ST.OK and buf ~= nil and u64_at(buf) == 510)
N.free(buf)
local s64 = string.rep("p", 64 * 1024 * 1024)
sc, buf = N.call_raw(K.PTR, s64)
local want_addr = ffi.cast("uint64_t", ffi.cast("uintptr_t", ffi.cast("const char*", s64)))
local got_addr = buf ~= nil and ffi.cast("const uint64_t*", buf.ptr)[0]
chk("B3 PTR of a 64 MiB string is the Lua string's own address (no copy)",
    sc == ST.OK and got_addr ~= nil and got_addr == want_addr, tostring(got_addr) .. " vs " .. tostring(want_addr))
N.free(buf)
ok, v, code = N.call(0, "x")
chk("B4 kind 0 gives false, a message and EKIND", ok == false and type(v) == "string" and #v > 0 and code == ST.EKIND,
    vim.inspect({ ok, v, code }))
ok, v, code = N.call(K.PANIC, "boom")
chk("B5 PANIC gives false, the panic's message and PANIC", ok == false and has(v, "jnv test panic: boom")
    and code == ST.PANIC, vim.inspect({ ok, v, code }))
ok, v = N.call(K.ECHO, "after the panic")
chk("B5 the next ECHO works", ok == true and v == "after the panic")
chk("B6 every buffer is freed (jnv_live_buffers back to its start)", tonumber(lib.jnv_live_buffers()) == live0,
    tostring(lib.jnv_live_buffers()) .. " vs " .. live0)
s64 = nil

-- ── C. jobs, the wake pipe and the pump ──────────────────────────────────
section("C. jobs, the wake pipe and the pump")
live0 = tonumber(lib.jnv_live_buffers())
local function wait_for(cond, ms) return vim.wait(ms or 3000, cond, 1) end
local got, fast
local id = N.submit(K.ECHO, "hello async", {}, function(o, val) got = { o, val }; fast = vim.in_fast_event() end)
chk("C1 submit gives a job id", type(id) == "number" and id >= 1, tostring(id))
wait_for(function() return got ~= nil end)
chk("C1 the callback gets the same string", got ~= nil and got[1] == true and got[2] == "hello async", vim.inspect(got))
chk("C1 the callback runs on the main loop, not in a fast event", fast == false, tostring(fast))

local FILL_N = 64 * 1024 * 1024
local fill
N.submit(K.FILL, N.u64(FILL_N), { raw = true }, function(o, b)
  if o and type(b) == "cdata" and b ~= nil then
    local p = ffi.cast("const uint8_t*", b.ptr)
    fill = { len = tonumber(b.len), at = p[12345], last = p[FILL_N - 1] }
    N.free(b)
  else
    fill = { err = tostring(b) }
  end
end)
wait_for(function() return fill ~= nil end)
chk("C2 a raw 64 MiB FILL result is read in place through the pointer, then freed", fill ~= nil
    and fill.len == FILL_N and fill.at == 12345 % 251 and fill.last == (FILL_N - 1) % 251, vim.inspect(fill))

local s_ptr = string.rep("q", 4096)
local addr = ffi.cast("uint64_t", ffi.cast("uintptr_t", ffi.cast("const char*", s_ptr)))
local p_borrow, p_copy
N.submit(K.PTR, s_ptr, {}, function(_, val) p_borrow = val end)
N.submit(K.PTR, s_ptr, { copy = true }, function(_, val) p_copy = val end)
wait_for(function() return p_borrow and p_copy end)
local function u64_of(str) return ffi.cast("const uint64_t*", ffi.cast("const char*", str))[0] end
chk("C3 PTR via submit is the Lua string's address (read in place)", p_borrow ~= nil and #p_borrow == 8
    and u64_of(p_borrow) == addr)
chk("C3 with copy = true the job reads a copy", p_copy ~= nil and #p_copy == 8 and u64_of(p_copy) ~= addr)

-- a private context with one worker: what runs next is predictable
local P, perr = N._new_context({ workers = 1 })
chk("C4 a private context opens with 1 worker", P ~= nil and tonumber(lib.jnv_workers(P.ptr)) == 1, perr)
if P then
  local order, slept = {}, false
  P:submit(K.SLEEP, N.u32(200), {}, function() slept = true end)
  for _, pr in ipairs({ "background", "normal", "visible" }) do
    for i = 1, 3 do
      P:submit(K.ECHO, pr:sub(1, 1) .. i, { priority = pr }, function(_, val) order[#order + 1] = val end)
    end
  end
  wait_for(function() return #order == 9 end)
  chk("C4 visible first, then normal, then background, FIFO within each",
      table.concat(order, " ") == "v1 v2 v3 n1 n2 n3 b1 b2 b3", table.concat(order, " "))
  wait_for(function() return slept end)

  slept = false
  P:submit(K.SLEEP, N.u32(300), {}, function() slept = true end)
  local rq
  local qid = P:submit(K.ECHO, "queued", {}, function(o, val, s) rq = { o, val, s, slept } end)
  local cok = P:cancel(qid)
  wait_for(function() return rq ~= nil end)
  chk("C5 cancel of a queued job is true", cok == true)
  chk("C5 it completes false, \"cancelled\", CANCELLED before the SLEEP ends, never with its ECHO value",
      rq ~= nil and rq[1] == false and rq[2] == "cancelled" and rq[3] == ST.CANCELLED and rq[4] == false, vim.inspect(rq))
  wait_for(function() return slept end)

  local rs
  local sid = P:submit(K.SLEEP, N.u32(5000), {}, function(o, val, s) rs = { o, val, s, t = now() } end)
  vim.wait(30)
  local tc = now()
  local c2 = P:cancel(sid)
  wait_for(function() return rs ~= nil end, 2000)
  local cms = rs and (rs.t - tc) / 1e6
  chk(("C6 cancel of a running SLEEP 5000 completes CANCELLED within 100 ms (%s ms)"):format(
      cms and ("%.1f"):format(cms) or "never"), c2 == true and rs ~= nil and rs[3] == ST.CANCELLED and cms < 100,
      vim.inspect(rs))
  chk("C7 cancel of an unknown id is false", P:cancel(987654321) == false)

  local rp, rn
  P:submit(K.PANIC, "boom2", {}, function(o, val, s) rp = { o, val, s } end)
  P:submit(K.ECHO, "after a panic", {}, function(o, val) rn = { o, val } end)
  wait_for(function() return rp and rn end)
  chk("C8 a PANIC job gives false, its message and PANIC", rp ~= nil and rp[1] == false
      and has(rp[2], "jnv test panic: boom2") and rp[3] == ST.PANIC, vim.inspect(rp))
  chk("C8 the next job on that one worker completes", rn ~= nil and rn[1] == true and rn[2] == "after a panic")

  local re
  P:submit(K.SLEEP, "abc", {}, function(o, val, s) re = { o, val, s } end)
  wait_for(function() return re ~= nil end)
  chk("C9 SLEEP with 3 bytes gives ERR", re ~= nil and re[1] == false and re[3] == ST.ERR
      and has(re[2], "SLEEP wants 4 bytes"), vim.inspect(re))

  -- the document is read in place, so its Lua string stays anchored until
  -- the job's completion is dispatched
  local s_anchor = "anchored document " .. string.rep("z", 200)
  local in_cb, a_val
  slept = false
  P:submit(K.SLEEP, N.u32(100), {}, function() slept = true end)
  local aid
  aid = P:submit(K.ECHO, s_anchor, {}, function(_, val)
    a_val = val
    in_cb = P.pending[aid]
  end)
  local held_queued = P.pending[aid] ~= nil and rawequal(P.pending[aid].data, s_anchor)
  vim.uv.sleep(150)
  local held_done = P.pending[aid] ~= nil and rawequal(P.pending[aid].data, s_anchor)
  wait_for(function() return a_val ~= nil end)
  chk("C10 ctx.pending[id].data holds the input string while the job is queued", held_queued)
  chk("C10 and after the job finished, until the pump dispatches it", held_done)
  chk("C10 the callback gets the value and the entry is released", a_val == s_anchor and in_cb == nil)
  local cid = P:submit(K.ECHO, "copied", { copy = true }, function() end)
  chk("C10 with copy = true nothing is anchored", P.pending[cid] ~= nil and P.pending[cid].data == nil)
  wait_for(function() return P.pending[cid] == nil end)
  chk("C10 pending_count() is 0 once every callback ran", P:pending_count() == 0, P:pending_count())

  local second, pump1, pump2
  P:submit(K.ECHO, "t1", {}, function()
    pump1 = P.stats.pumps
    error("deliberate test error from a callback")
  end)
  P:submit(K.ECHO, "t2", {}, function(_, val) second = val; pump2 = P.stats.pumps end)
  vim.uv.sleep(50)
  wait_for(function() return second ~= nil end)
  chk("C12 a callback that throws does not stop the next one in the same pump",
      second == "t2" and pump1 ~= nil and pump1 == pump2, vim.inspect({ second, pump1, pump2 }))
  local lp = require("jupynvim.log").path()
  local lt = vim.uv.fs_stat(lp) and table.concat(vim.fn.readfile(lp), "\n") or ""
  chk("C12 the error is logged", has(lt, "deliberate test error from a callback"), lp)

  -- C13: an error while finishing one completion (outside its callback:
  -- ffi.string failing to allocate) loses that one, never the rest of its
  -- batch with their callbacks and buffers
  local live13 = tonumber(lib.jnv_live_buffers())
  local got13 = {}
  for _, s in ipairs({ "r1", "r2", "r3" }) do
    P:submit(K.ECHO, s, {}, function(_, val) got13[s] = val end)
  end
  vim.uv.sleep(50) -- all three finish, and one pump takes them in one batch
  local real_string, calls13 = ffi.string, 0
  ffi.string = function(...)
    calls13 = calls13 + 1
    if calls13 == 2 then error("test: out of memory") end
    return real_string(...)
  end
  local okw = pcall(vim.wait, 1000, function() return got13.r1 ~= nil and got13.r3 ~= nil end, 1)
  ffi.string = real_string
  collectgarbage(); collectgarbage()
  chk("C13 an error while finishing one completion never drops the rest of its batch",
      okw and got13.r1 == "r1" and got13.r3 == "r3" and got13.r2 == nil, vim.inspect(got13))
  chk("C13 and every buffer of that batch is freed", tonumber(lib.jnv_live_buffers()) == live13,
      tostring(lib.jnv_live_buffers()) .. " vs " .. live13)
  P:close()
end

-- C11: re-entrancy. A1 and A2 finish while the UI thread is blocked, so one
-- pump polls both in one batch. A1's callback runs the event loop
-- (vim.wait), which runs a nested pump for B1 and B2; that pump must not
-- overwrite A2's record in the outer batch.
do
  local Q = N._new_context({ workers = 1 })
  chk("C11 a private context opens", Q ~= nil)
  if Q then
    local base = tonumber(lib.jnv_live_buffers())
    local log, seen = {}, {}
    local b1, b2, a2
    local nested0 = Q.stats.nested
    local pumps_a1, nested_a1, pumps_a2, nested_a2
    local function saw(i) seen[i] = (seen[i] or 0) + 1 end
    local ida1, ida2, idb1, idb2
    ida1 = Q:submit(K.ECHO, "A1", {}, function()
      saw(ida1)
      log[#log + 1] = "A1-start"
      pumps_a1, nested_a1 = Q.stats.pumps, Q.stats.nested
      idb1 = Q:submit(K.ECHO, "B1", {}, function(_, val) saw(idb1); b1 = val; log[#log + 1] = "B1" end)
      idb2 = Q:submit(K.ECHO, "B2", {}, function(_, val) saw(idb2); b2 = val; log[#log + 1] = "B2" end)
      vim.uv.sleep(50)
      vim.wait(1000, function() return b1 ~= nil and b2 ~= nil end, 1)
      log[#log + 1] = "A1-end"
    end)
    ida2 = Q:submit(K.ECHO, "A2", {}, function(_, val)
      saw(ida2); a2 = val; log[#log + 1] = "A2"
      pumps_a2, nested_a2 = Q.stats.pumps, Q.stats.nested
    end)
    vim.uv.sleep(50)
    wait_for(function() return a2 ~= nil end)
    vim.wait(50)
    chk("C11 order A1-start, B1, B2, A1-end, A2", table.concat(log, ", ") == "A1-start, B1, B2, A1-end, A2",
        table.concat(log, ", "))
    chk("C11 B1 and B2 reached their callbacks inside the wait with their own values", b1 == "B1" and b2 == "B2")
    chk("C11 A2's callback ran once with \"A2\"", a2 == "A2" and seen[ida2] == 1)
    local once = true
    for _, i in ipairs({ ida1, ida2, idb1 or -1, idb2 or -2 }) do if seen[i] ~= 1 then once = false end end
    chk("C11 every id was dispatched exactly once", once, vim.inspect(seen))
    chk("C11 A1 and A2 came in one batch of one outer pump", pumps_a1 ~= nil and pumps_a2 ~= nil
        and pumps_a2 - pumps_a1 == nested_a2 - nested_a1, vim.inspect({ pumps_a1, nested_a1, pumps_a2, nested_a2 }))
    chk("C11 a nested pump ran (stats.nested >= 1)", Q.stats.nested - nested0 >= 1, Q.stats.nested)
    chk("C11 depth is back to 0", Q.depth == 0, Q.depth)
    chk("C11 every buffer is freed", tonumber(lib.jnv_live_buffers()) == base,
        tostring(lib.jnv_live_buffers()) .. " vs " .. base)
    Q:close()
  end

  -- a callback that closes its context in the middle of a full batch
  local R = N._new_context({ workers = 1 })
  chk("C11 another private context opens", R ~= nil)
  if R then
    local base = tonumber(lib.jnv_live_buffers())
    local real = R.lib
    local polls, after, first_n, closed = 0, 0, nil, false
    R.lib = setmetatable({
      jnv_poll = function(...)
        polls = polls + 1
        if closed then after = after + 1 end
        local n = real.jnv_poll(...)
        first_n = first_n or tonumber(n)
        return n
      end,
    }, { __index = real })
    local calls = 0
    for i = 1, 70 do
      R:submit(K.ECHO, "c" .. i, {}, function()
        calls = calls + 1
        if calls == 1 then R:close(); closed = true end
      end)
    end
    vim.uv.sleep(50)
    wait_for(function() return calls >= 1 end)
    vim.wait(100)
    chk("C11 the first batch was full (64 records)", first_n == 64, first_n)
    chk("C11 the later records of that batch run no callback", calls == 1, calls)
    chk("C11 no jnv_poll after the close", polls == 1 and after == 0, ("polls %d, after the close %d"):format(polls, after))
    chk("C11 their buffers are freed", tonumber(lib.jnv_live_buffers()) == base,
        tostring(lib.jnv_live_buffers()) .. " vs " .. base)
    chk("C11 the context is closed", R.closed == true and R.ptr == nil)
  end
end
chk("C every buffer of section C is freed", tonumber(lib.jnv_live_buffers()) == live0,
    tostring(lib.jnv_live_buffers()) .. " vs " .. live0)

-- ── D. budgets ───────────────────────────────────────────────────────────
-- Numbered after the budgets they enforce. A timing check runs up to three
-- times and passes on the first run within its budget; every run's numbers
-- are printed. Tight loops call the library and the default context's
-- pointer directly, as a consumer's hot path would.
section("D. budgets")
do
  chk("D0 the JIT compiler is on (jit.status()); the budgets assume it", jit.status() == true,
      "JIT is off in this Neovim, so these timings measure the interpreter")
  -- jit.status() can say on while this process compiles nothing: Neovim
  -- 0.11.5's LuaJIT on arm64 macOS sometimes cannot get memory for machine
  -- code, every trace then aborts, and every budget below would time the
  -- interpreter. A fresh hot loop (a new prototype each time, so nothing of
  -- it is compiled yet) must finish a trace. When it does not, and nothing
  -- has failed yet, the whole spec runs again in a fresh Neovim, up to three
  -- tries; JNV_NATIVE_SPEC_FAKE_NOMCODE=1 makes the first try report none.
  local TRY = tonumber(os.getenv("JNV_NATIVE_SPEC_TRY") or "1") or 1
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
  if os.getenv("JNV_NATIVE_SPEC_FAKE_NOMCODE") == "1" and TRY == 1 then
    mcode, why = false, "JNV_NATIVE_SPEC_FAKE_NOMCODE=1"
  end
  if not mcode and fails == 0 and TRY < 3 then
    io.write(("D0 this LuaJIT compiled no machine code in this process (%s); running the whole spec again"
      .. " in a fresh Neovim (try %d of 3)\n"):format(why, TRY + 1))
    local r = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-c", "luafile " .. REPO .. "/tests/native_spec.lua",
      "-c", "cquit 3" }, { cwd = REPO, env = { JNV_NATIVE_SPEC_TRY = tostring(TRY + 1) }, text = true }):wait(900000)
    io.write(r.stdout or "")
    if (r.stderr or "") ~= "" then io.stderr:write(r.stderr) end
    if r.code == 0 then vim.cmd("qa!") else vim.cmd("cquit " .. tostring(r.code)) end
    return
  end
  chk("D0 this process compiles machine code (a fresh hot loop finished a trace)", mcode, why)
  if mcode then
    -- and the probe sees it when there is none
    jit.off()
    local off, why_off = compiles()
    jit.on()
    chk("D0 with jit.off() the probe finds no machine code", off == false, why_off)
  end
  local ctx = S.ctx
  local ptr = ctx.ptr
  local base = tonumber(lib.jnv_live_buffers())
  local function fmt(x, digits) return ("%." .. (digits or 3) .. "f"):format(x) end
  -- the run function returns met, text (and may record functional failures)
  local function timed(name, budget_text, run)
    local runs, met = {}, false
    for r = 1, 3 do
      local ok_r, text = run(r)
      io.write(("  %s: run%d %s\n"):format(name, r, text))
      runs[#runs + 1] = ("run%d %s"):format(r, text)
      if ok_r then met = true break end
    end
    chk(("%s %s (%s)"):format(name, budget_text, table.concat(runs, "; ")), met)
  end
  local function live_back(after)
    local lv = tonumber(lib.jnv_live_buffers())
    chk("D12 jnv_live_buffers() is back at its baseline after " .. after, lv == base,
        ("%d vs %d"):format(lv, base))
  end
  local function pct(sorted, p) return sorted[math.max(1, math.ceil(#sorted * p))] end
  local out1 = ffi.new("jnv_buf*[1]")

  -- D3: a raw FFI call
  timed("D3 raw jnv_abi_version()", "mean under 20 ns over 10,000,000 calls", function()
    local acc = 0
    local t0 = now()
    for _ = 1, 1e7 do acc = acc + lib.jnv_abi_version() end
    local mean = (now() - t0) / 1e7
    return mean < 20 and acc == 1e7 * 65536, ("mean %s ns"):format(fmt(mean, 2))
  end)

  -- D4: jnv_call takes the document by pointer: no work proportional to size.
  -- Each loop runs in chunks of 1,000 calls and stops once 2 s have passed,
  -- so a call that does work proportional to the document fails here by
  -- name within seconds instead of running for hours.
  local s1 = "x"
  local s64 = string.rep("d", 64 * 1024 * 1024)
  -- up to n calls of jnv_call NOP on s: the mean ns per call made, the
  -- calls made, the sum of their statuses and the seconds the loop ran
  local function nop_loop(s, n)
    local bad, made, len = 0, 0, #s
    local t0 = now()
    for _ = 1, n / 1000 do
      for _ = 1, 1000 do bad = bad + lib.jnv_call(ptr, K.NOP, s, len, out1) end
      made = made + 1000
      if now() - t0 > 2e9 then break end
    end
    local dt = now() - t0
    return dt / made, made, bad, dt / 1e9
  end
  timed("D4 jnv_call NOP", "mean under 150 ns with 1 byte and with 64 MiB, the 64 MiB mean under"
      .. " twice the 1-byte mean + 20 ns (1,000,000 calls each, a loop stops after 2 s)", function()
    local m1, n1, b1, t1 = nop_loop(s1, 1e6)
    local m64, n64, b64, t64 = nop_loop(s64, 1e6)
    local stopped = {}
    if n1 < 1e6 then stopped[#stopped + 1] = ("the 1-byte loop stopped after %d calls (%.2f s)"):format(n1, t1) end
    if n64 < 1e6 then stopped[#stopped + 1] = ("the 64 MiB loop stopped after %d calls (%.2f s)"):format(n64, t64) end
    local bad = b1 + b64
    return #stopped == 0 and bad == 0 and out1[0] == nil and m1 < 150 and m64 < 150 and m64 < 2 * m1 + 20,
        ("1 B %s ns, 64 MiB %s ns, statuses %s%s"):format(fmt(m1, 2), fmt(m64, 2), bad == 0 and "all OK" or "NOT OK",
          #stopped > 0 and (", " .. table.concat(stopped, ", ")) or "")
  end)
  local want64 = ffi.cast("uint64_t", ffi.cast("uintptr_t", ffi.cast("const char*", s64)))
  local stp = lib.jnv_call(ptr, K.PTR, s64, #s64, out1)
  local gotp = out1[0] ~= nil and ffi.cast("const uint64_t*", out1[0].ptr)[0] or nil
  lib.jnv_buf_free(out1[0])
  out1[0] = nil
  chk("D4 jnv_call PTR of the 64 MiB document is the Lua string's own address", stp == ST.OK
      and gotp ~= nil and gotp == want64, tostring(gotp) .. " vs " .. tostring(want64))
  live_back("D4")

  -- D5: a whole document read in place on the calling thread
  local pattern = {}
  for i = 0, 255 do pattern[#pattern + 1] = string.char(i) end
  local doc = string.rep(table.concat(pattern), 64 * 1024 * 1024 / 256) -- 64 MiB, every byte value
  local want_sum = 32640 * (64 * 1024 * 1024 / 256)
  timed("D5 BYTESUM over a 64 MiB document in place", "under 40 ms", function()
    local t0 = now()
    local stb = lib.jnv_call(ptr, K.BYTESUM, doc, #doc, out1)
    local dt = (now() - t0) / 1e6
    local sum = out1[0] ~= nil and tonumber(ffi.cast("const uint64_t*", out1[0].ptr)[0]) or nil
    lib.jnv_buf_free(out1[0])
    out1[0] = nil
    return stb == ST.OK and sum == want_sum and dt < 40,
        ("%s ms, sum %s (want %d)"):format(fmt(dt), tostring(sum), want_sum)
  end)
  doc = nil
  live_back("D5")

  -- D6: what a submit costs the UI thread
  local d6_ok = true
  timed("D6 submit on the UI thread", "p99 under 20 us over 10,000 submits", function()
    local times, n, ids = {}, 0, {}
    local data = string.rep("s", 16)
    local function cb() n = n + 1 end
    for i = 1, 10000 do
      local t0 = now()
      local sid = ctx:submit(K.NOP, data, {}, cb)
      times[i] = now() - t0
      ids[i] = sid
    end
    vim.wait(5000, function() return n == 10000 end, 1)
    for i = 1, 10000 do if type(ids[i]) ~= "number" then d6_ok = false end end
    if n ~= 10000 then d6_ok = false end
    table.sort(times)
    local p99 = pct(times, 0.99) / 1e3
    return p99 < 20, ("p50 %s us p99 %s us max %s us, %d callbacks"):format(
        fmt(pct(times, 0.5) / 1e3), fmt(p99), fmt(times[#times] / 1e3), n)
  end)
  chk("D6 every submit gave an id and every callback ran", d6_ok)
  live_back("D6")

  -- D7: a worker round trip on an idle loop
  local d7_ok = true
  timed("D7 round trip (16-byte ECHO, sequential)", "p50 under 0.5 ms and p95 under 2 ms over 1,000 jobs",
      function()
    local times = {}
    local data = string.rep("e", 16)
    for i = 1, 1000 do
      local got
      local t0 = now()
      ctx:submit(K.ECHO, data, {}, function(_, val) got = val end)
      vim.wait(50, function() return got ~= nil end, 0)
      times[i] = now() - t0
      if got ~= data then d7_ok = false end
    end
    table.sort(times)
    local p50, p95 = pct(times, 0.5) / 1e6, pct(times, 0.95) / 1e6
    return p50 < 0.5 and p95 < 2, ("p50 %s ms p95 %s ms max %s ms"):format(fmt(p50), fmt(p95),
        fmt(times[#times] / 1e6))
  end)
  chk("D7 every round trip gave back its own bytes", d7_ok)
  local pid_got
  ctx:submit(K.PTR, s64, {}, function(_, val) pid_got = val end)
  wait_for(function() return pid_got ~= nil end)
  chk("D7 a submitted 64 MiB document is read in place (PTR is the Lua string's address)",
      pid_got ~= nil and #pid_got == 8 and ffi.cast("const uint64_t*", ffi.cast("const char*", pid_got))[0] == want64)
  s64 = nil
  live_back("D7")

  -- D8: a 64 MiB result is picked up in place: the whole pump tick (poll,
  -- finish and a callback that reads one byte and frees it) stays small.
  -- The result is never copied into a Lua string.
  local d8_ok = true
  timed("D8 a raw 64 MiB FILL result picked up", "whole pump tick under 100 us", function()
    ctx.stats.max_tick_ns = 0
    local done0, pumps0 = ctx.stats.done, ctx.stats.pumps
    local byte, blen
    local t0 = now()
    ctx:submit(K.FILL, N.u64(FILL_N), { raw = true }, function(o, b)
      if o and b ~= nil then
        byte = ffi.cast("const uint8_t*", b.ptr)[12345]
        blen = tonumber(b.len)
        N.free(b)
      else
        byte = -1
      end
    end)
    local sub_us = (now() - t0) / 1e3
    wait_for(function() return byte ~= nil end)
    local tick = ctx.stats.max_tick_ns
    local via_pump = ctx.stats.done - done0 == 1 and ctx.stats.pumps - pumps0 >= 1
    if byte ~= 12345 % 251 or blen ~= FILL_N or not via_pump then d8_ok = false end
    return tick > 0 and tick < 1e5, ("tick %s us (submit %s us, byte %s, through %d pump(s))"):format(
        fmt(tick / 1e3, 1), fmt(sub_us, 1), tostring(byte), ctx.stats.pumps - pumps0)
  end)
  chk("D8 the callback read the right byte of the 64 MiB result, delivered by the pump", d8_ok)
  live_back("D8")

  -- D9: a burst. Each callback does 1 us of work, a stand-in for a real
  -- consumer, so the 20,000 need at least 20 ms: only the pump's 2 ms tick
  -- limit keeps every tick under 4 ms.
  local d9_ok, d9_detail = true, ""
  timed("D9 a burst of 20,000 NOP jobs", "all complete in under 1 s, at most 2,000 wakes, no pump tick"
      .. " over 4 ms, more than one tick", function()
    ctx.stats.max_tick_ns = 0
    local w0, p0 = ctx.stats.wakes, ctx.stats.pumps
    local seen, n, ids = {}, 0, {}
    local t0 = now()
    for i = 1, 20000 do
      local bid
      bid = ctx:submit(K.NOP, nil, {}, function()
        seen[bid] = (seen[bid] or 0) + 1
        n = n + 1
        local tw = now()
        while now() - tw < 1000 do end
      end)
      ids[i] = bid
    end
    vim.wait(5000, function() return n >= 20000 end, 0)
    local total = (now() - t0) / 1e6
    local once = n == 20000
    for i = 1, 20000 do if seen[ids[i]] ~= 1 then once = false end end
    if not once then d9_ok, d9_detail = false, ("%d callbacks"):format(n) end
    local wakes, pumps, tick = ctx.stats.wakes - w0, ctx.stats.pumps - p0, ctx.stats.max_tick_ns / 1e6
    return total < 1000 and wakes <= 2000 and tick < 4 and pumps > 1,
        ("%s ms, %d wakes, %d pump ticks, max tick %s ms"):format(fmt(total, 1), wakes, pumps, fmt(tick))
  end)
  chk("D9 every id completed exactly once", d9_ok, d9_detail)
  live_back("D9")

  -- D10: a long job never blocks the UI thread
  local d10_ok = true
  timed("D10 a 5 ms timer during a SLEEP 1000 job", "never gaps more than 25 ms, the submit returns in"
      .. " under 50 us", function()
    local timer = vim.uv.new_timer()
    local ticks, maxgap = 0, 0
    local last = now()
    timer:start(5, 5, function()
      local tt = now()
      if tt - last > maxgap then maxgap = tt - last end
      last = tt
      ticks = ticks + 1
    end)
    local res
    local t0 = now()
    ctx:submit(K.SLEEP, N.u32(1000), {}, function(o, val) res = { o, val } end)
    local sub_us = (now() - t0) / 1e3
    vim.wait(5000, function() return res ~= nil end, 1)
    -- the stretch since the last tick counts too: a UI thread blocked
    -- until the job ended leaves no tick at all
    if now() - last > maxgap then maxgap = now() - last end
    timer:stop()
    timer:close()
    if not (res and res[1] == true) then d10_ok = false end
    local gap = maxgap / 1e6
    return gap < 25 and sub_us < 50, ("max gap %s ms over %d ticks, submit %s us"):format(fmt(gap, 2), ticks,
        fmt(sub_us, 1))
  end)
  chk("D10 every SLEEP 1000 job completed OK", d10_ok)
  live_back("D10")

  -- D11: closing never waits, also not for a running job that never looks
  -- at its cancel flag. E1 closes over a SLEEP, which stops within 1 ms of
  -- the flag, so only a job like this FILL of 1 GiB tells a close that
  -- waits for its workers from one that does not. The worker drops the
  -- result when it finishes.
  timed("D11 close() with a FILL of 1 GiB running on its only worker", "returns in under 5 ms", function()
    local C = N._new_context({ workers = 1 })
    if not C then return false, "no private context" end
    C:submit(K.FILL, N.u64(1024 * 1024 * 1024), {}, function() end)
    vim.uv.sleep(2) -- the worker has taken the job by now
    local t0 = now()
    C:close()
    local ms = (now() - t0) / 1e6
    return ms < 5, ("%s ms"):format(fmt(ms))
  end)
  live_back("D11")

  -- D12: 10,000 round trips leave no buffer behind
  local echo_ok, n12 = true, 0
  for i = 1, 10000 do
    local data = "round trip " .. i
    local got
    ctx:submit(K.ECHO, data, {}, function(_, val) got = val end)
    vim.wait(50, function() return got ~= nil end, 0)
    if got ~= data then echo_ok = false else n12 = n12 + 1 end
  end
  chk("D12 10,000 ECHO round trips each gave back their own bytes", echo_ok, n12)
  live_back("10,000 ECHO round trips")
  chk("D every job of section D was dispatched (nothing pending)", ctx:pending_count() == 0, ctx:pending_count())
end

-- ── E. shutdown ──────────────────────────────────────────────────────────
section("E. shutdown")
do
  -- a timing budget: up to three runs, the first one under budget passes
  local E1, sid, s_sleep, g0
  local runs, fast_close = {}, false
  for _ = 1, 3 do
    E1 = N._new_context({ workers = 1 })
    if not E1 then break end
    s_sleep = N.u32(2000)
    sid = E1:submit(K.SLEEP, s_sleep, {}, function() end)
    vim.wait(30)
    g0 = #S.graveyard
    local t0 = now()
    E1:close()
    local cms = ms_since(t0)
    runs[#runs + 1] = ("%.3f"):format(cms)
    if cms < 5 then fast_close = true break end
  end
  chk("E1 a private context opens", E1 ~= nil)
  if E1 then
    chk(("E1 close() with a SLEEP 2000 running returns in under 5 ms (runs: %s ms)"):format(
        table.concat(runs, ", ")), fast_close)
    local r, e = E1:submit(K.ECHO, "x", {}, function() end)
    chk("E1 a submit after close gives nil, \"closed\"", r == nil and e == "closed", vim.inspect({ r, e }))
    chk("E1 a call after close gives false", (E1:call(K.ECHO, "x")) == false)
    local grave = S.graveyard[#S.graveyard]
    chk("E1 the graveyard grew by one table", #S.graveyard == g0 + 1, #S.graveyard - g0)
    chk("E1 it holds the running job's anchor", grave ~= nil and grave[sid] ~= nil and grave[sid].data == s_sleep)
    chk("E1 the wake pipe is closing", E1.pipe:is_closing() == true)
    chk("E1 close() twice does nothing", pcall(E1.close, E1))
  end

  local E2 = N._new_context({ workers = 1 })
  chk("E2 a private context opens", E2 ~= nil)
  if E2 then
    E2.pipe:read_stop()
    E2.pipe:close()
    vim.wait(20)
    local got2
    E2:submit(K.ECHO, "after the pipe closed", {}, function(_, val) got2 = val end)
    vim.wait(100)
    chk("E2 a job that completes after only the Lua pipe closed leaves Neovim alive",
        vim.api.nvim_eval("1 + 1") == 2)
    chk("E2 no wake reaches Lua then", got2 == nil)
    E2:_pump()
    chk("E2 the job did complete (a pump by hand collects it)", got2 == "after the pipe closed", tostring(got2))
    local okc, errc = pcall(E2.close, E2)
    chk("E2 that context still closes cleanly", okc and E2.closed == true and E2.ptr == nil, errc)
  end
end

-- ── F. the path without the library ──────────────────────────────────────
section("F. the path without the library (child processes)")
vim.env.JNV_FAKE = nil
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local WARN = vim.log.levels.WARN
for _, off in ipairs({ "off", "0", "FALSE", "No" }) do
  local j, why = child("plain", { JUPYNVIM_NATIVE = off })
  chk(("F1 JUPYNVIM_NATIVE=%s: disabled, not available, no notice"):format(off), j ~= nil
      and j.status.state == "disabled" and j.available == false and #j.notes == 0
      and has(j.status.reason, "turned off by JUPYNVIM_NATIVE=" .. off), why)
  if off == "off" then
    chk("F1 module functions say why", j ~= nil and j.extra.submit_nil == true
        and j.extra.submit_err == "libjupynvim unavailable: turned off by JUPYNVIM_NATIVE=off"
        and j.extra.call_ok == false and has(j.extra.call_msg, "libjupynvim unavailable"), why)
  end
end
local missing = tmp .. "/none." .. EXT
local j, why = child("plain", { JUPYNVIM_NATIVE = missing })
chk("F2 a missing path: missing, the path in the reason, no notice", j ~= nil and j.status.state == "missing"
    and j.available == false and has(j.status.reason, "not found at " .. missing) and #j.notes == 0, why)
-- the file was named by the variable, so the fix is the variable: an
-- install or a rebuild in core/ would not change what loads
chk("F2 the fix points at JUPYNVIM_NATIVE, the setting that named the file (source env)", j ~= nil
    and j.status.fix == "JUPYNVIM_NATIVE names this file; unset it, or point it at a library you built"
    and j.status.source == "env", j and vim.inspect({ fix = j.status.fix, source = j.status.source }))
local garbage = tmp .. "/libjupynvim." .. EXT
vim.fn.writefile({ "not a library" }, garbage)
j, why = child("plain", { JUPYNVIM_NATIVE = garbage })
local warns = 0
for _, n in ipairs(j and j.notes or {}) do if n.level == WARN then warns = warns + 1 end end
chk("F3 a garbage file: error, could not be loaded", j ~= nil and j.status.state == "error" and j.available == false
    and has(j.status.reason, "could not be loaded from " .. garbage), why)
chk("F3 exactly one WARN notice after three available() calls", j ~= nil and #j.notes == 1 and warns == 1, why)
-- One line, so it never stops at a hit-enter prompt while the user types;
-- the reason and the fix are in status(), :checkhealth and the log. With
-- Neovim's defaults (showcmd, ruler, laststatus 2, cmdheight 1) a message
-- fits the last line of an 80-column screen without that prompt only up to
-- 68 cells (v:echospace is columns - 12, the showcmd column taken off); a
-- longer one stops there and swallows the next key typed.
local ROOM80 = 68
local NOTICE_LOAD = "jupynvim: libjupynvim could not be loaded; see :checkhealth jupynvim"
local NOTICE_START = "jupynvim: libjupynvim could not start; see :checkhealth jupynvim"
local NOTICE_MISMATCH = "jupynvim: libjupynvim does not match; see :checkhealth jupynvim"
local NOTICE_SHORT = "jupynvim: see :checkhealth jupynvim"
-- msg fits the room the child jj had: 80 columns, and v:echospace there
local function fits80(jj, msg)
  return jj ~= nil and type(msg) == "string" and jj.extra.columns == 80 and #msg <= ROOM80
    and #msg <= (tonumber(jj.extra.echospace) or -1)
end
local function note_room(jj)
  return jj and ("%q, %d characters, at %s columns with %s cells of room"):format(tostring(jj.notes[1] and jj.notes[1].msg),
    jj.notes[1] and #jj.notes[1].msg or -1, tostring(jj.extra.columns), tostring(jj.extra.echospace)) or "no child"
end
local function notes_say(jj, sub)
  for _, n in ipairs(jj and jj.notes or {}) do if has(n.msg, sub) then return true end end
  return false
end
chk("F3 the notice is one line that names :checkhealth jupynvim and fits 80 columns (68 cells)", j ~= nil
    and j.notes[1] ~= nil and j.notes[1].msg == NOTICE_LOAD and fits80(j, j.notes[1].msg), note_room(j))
chk("F3 and its fix is the one the variable needs, never a rebuild", j ~= nil
    and j.status.fix == "JUPYNVIM_NATIVE names this file; unset it, or point it at a library built from "
      .. "this version of the plugin, then restart Neovim" and not notes_say(j, "cargo build"),
    j and vim.inspect({ fix = j.status.fix, notes = j.notes }))
local flog = j and j.extra.log_path
local ftext = type(flog) == "string" and vim.uv.fs_stat(flog) and table.concat(vim.fn.readfile(flog), "\n") or ""
chk("F3 the log keeps the whole text", has(ftext, "libjupynvim could not be loaded from " .. garbage)
    and has(ftext, "Everything keeps working without it."), tostring(flog))
j, why = child("plain", { JUPYNVIM_NATIVE = FAKE, JNV_FAKE = "version" })
chk("F3b a library of another version: mismatch, one WARN notice, the one line", j ~= nil
    and j.status.state == "mismatch" and #j.notes == 1 and j.notes[1].level == WARN
    and j.notes[1].msg == NOTICE_MISMATCH, why)
chk("F3b and it fits 80 columns (68 cells)", j ~= nil and fits80(j, j.notes[1] and j.notes[1].msg), note_room(j))
-- A screen narrower than 80 columns (a split terminal) has less room: the
-- notice is a shorter line that still names :checkhealth, cut to the room
-- when even that is too long
for _, c in ipairs({ { "70", NOTICE_SHORT }, { "50", NOTICE_SHORT }, { "40", NOTICE_SHORT:sub(1, 28) } }) do
  j, why = child("plain", { JUPYNVIM_NATIVE = garbage, JNV_TEST_COLUMNS = c[1] })
  local m = j and j.notes[1] and j.notes[1].msg
  chk(("F3c at %s columns the one notice is %q, within the room there"):format(c[1], c[2]), j ~= nil and #j.notes == 1
      and m == c[2] and tostring(j.extra.columns) == c[1] and #m <= (tonumber(j.extra.echospace) or -1), note_room(j))
end
j, why = child("plain", { JUPYNVIM_NATIVE = FAKE, JNV_FAKE = "version", JNV_TEST_COLUMNS = "79" })
chk("F3c and at 79 columns the mismatch notice is still the whole line (63 of 67 cells)", j ~= nil and #j.notes == 1
    and j.notes[1].msg == NOTICE_MISMATCH and #j.notes[1].msg <= (tonumber(j.extra.echospace) or -1), note_room(j))
j, why = child("setup")
chk("F4 setup() leaves jupynvim.native unloaded", j ~= nil and j.loaded_after_setup == false, why)
chk("F4 and the library still loads on first use", j ~= nil and j.available == true and j.status.state == "ok", why)
j, why = child("cfg_off")
chk("F5 setup({ native = { enabled = false } }): disabled", j ~= nil and j.status.state == "disabled"
    and j.available == false and has(j.status.reason, "turned off in setup() (native.enabled = false)")
    and #j.notes == 0, why)
j, why = child("noffi")
chk("F6 a Neovim without LuaJIT: unsupported, needs LuaJIT, no notice", j ~= nil
    and j.status.state == "unsupported" and j.available == false and has(j.status.reason, "needs LuaJIT")
    and #j.notes == 0, why)
j, why = child("plain", { JUPYNVIM_NATIVE = FAKE, JNV_FAKE = "ok" })
chk("F7 a library that passes the checks but cannot start: error, fake library: no worker pool", j ~= nil
    and j.status.state == "error" and has(j.status.reason, "could not start: fake library: no worker pool")
    and #j.notes == 1 and j.notes[1].level == WARN, why)
chk("F7 and its notice is " .. NOTICE_START .. ", which fits 80 columns (68 cells)", j ~= nil and j.notes[1] ~= nil
    and j.notes[1].msg == NOTICE_START and fits80(j, j.notes[1].msg), note_room(j))
-- the first consumer may be a luv callback (a fast event), where vim.fn and
-- nvim_create_autocmd are not allowed
j, why = child("fast")
chk("F15 the first available() from a luv callback (a fast event) loads the library", j ~= nil
    and j.extra.in_fast == true and j.extra.load_ok == true and j.available == true and j.status.state == "ok", why)
chk("F15 a job submitted there reaches its callback on the main loop", j ~= nil
    and j.extra.echo == "from a fast event" and j.extra.echo_fast == false, why)
chk("F15 the VimLeavePre hook is added once the main loop runs", j ~= nil and j.extra.leave_hooks == 1, why)
j, why = child("fast", { JUPYNVIM_NATIVE = garbage })
chk("F15 an unloadable library met in a fast event: error, one WARN notice", j ~= nil and j.extra.load_ok == true
    and j.available == false and j.status.state == "error" and #j.notes == 1 and j.notes[1].level == WARN, why)
j, why = child("cfg_path", { JNV_TEST_LIB = LIB })
chk("F16 setup({ native = { path = \"$JNV_TEST_LIB\" } }) is expanded and loads, also from a fast event",
    j ~= nil and j.extra.load_ok == true and j.available == true and j.status.state == "ok"
    and j.status.path == LIB and #j.notes == 0, why)
-- A relative path is taken from the current directory when the library
-- first loads: the file checked is the file loaded (dlopen of a name with
-- no slash searches the library path on glibc, never the current directory)
local LIB_DIR, LIB_NAME = LIB:match("^(.*)/([^/]+)$")
j, why = child("plain", { JUPYNVIM_NATIVE = "./" .. LIB_NAME }, LIB_DIR)
chk("F17 JUPYNVIM_NATIVE=./" .. LIB_NAME .. " from its directory: loads, path made absolute, source env",
    j ~= nil and j.available == true and j.status.state == "ok" and j.status.path == LIB
    and j.status.source == "env" and #j.notes == 0, why)
j, why = child("setup_json", { JNV_TEST_SETUP = vim.json.encode({ native = { path = "./" .. LIB_NAME } }) }, LIB_DIR)
chk("F18 setup({ native = { path = \"./" .. LIB_NAME .. "\" } }) from its directory: loads, path made absolute,"
    .. " source setup", j ~= nil and j.available == true and j.status.state == "ok" and j.status.path == LIB
    and j.status.source == "setup" and #j.notes == 0, why)
-- native.path names a file that does not load: the fix is that setting
local SETUP_FIX = "native.path in setup() names this file; remove it, or point it at a library built from "
  .. "this version of the plugin, then restart Neovim"
j, why = child("setup_json", { JNV_TEST_SETUP = vim.json.encode({ native = { path = garbage } }) })
chk("F19 setup({ native = { path = <a file that does not load> } }): error, the fix points at native.path",
    j ~= nil and j.status.state == "error" and j.status.source == "setup" and j.status.fix == SETUP_FIX, why)
chk("F19 and the one notice is the one line; status().fix carries the setting", j ~= nil and #j.notes == 1
    and j.notes[1].level == WARN and j.notes[1].msg == NOTICE_LOAD and fits80(j, j.notes[1].msg)
    and j.status.fix == SETUP_FIX, why)
-- Whether the background install would fetch the plugin's own library,
-- told from the settings alone: asking never opens a library and never
-- changes the loader's state
j, why = child("wanted")
chk("F20 no settings: the plugin's own library is wanted, and asking loads nothing", j ~= nil
    and j.extra.wanted == true and j.extra.why == nil and j.status.state == "unloaded" and j.extra.clibs == 0
    and #j.notes == 0, why)
j, why = child("wanted", { JUPYNVIM_NATIVE = "off" })
chk("F21 JUPYNVIM_NATIVE=off: not wanted, turned off by JUPYNVIM_NATIVE=off, nothing loads", j ~= nil
    and j.extra.wanted == false and has(j.extra.why, "turned off by JUPYNVIM_NATIVE=off")
    and j.status.state == "unloaded" and j.extra.clibs == 0, why)
j, why = child("wanted", { JUPYNVIM_NATIVE = LIB })
chk("F21 JUPYNVIM_NATIVE=<a file>: not wanted, a library of your own, nothing loads", j ~= nil
    and j.extra.wanted == false and j.extra.why == "JUPYNVIM_NATIVE names a library of your own"
    and j.status.state == "unloaded" and j.extra.clibs == 0, why)
j, why = child("wanted", { JNV_TEST_SETUP = vim.json.encode({ native = false }) })
chk("F22 setup({ native = false }): not wanted, turned off in setup(), nothing loads", j ~= nil
    and j.extra.wanted == false and j.extra.why == "turned off in setup() (native = false)"
    and j.status.state == "unloaded" and j.extra.clibs == 0, why)
j, why = child("wanted", { JNV_TEST_SETUP = vim.json.encode({ native = { path = LIB } }) })
chk("F22 setup({ native = { path = <a file> } }): not wanted, a library of your own, nothing loads", j ~= nil
    and j.extra.wanted == false and j.extra.why == "native.path in setup() names a library of your own"
    and j.status.state == "unloaded" and j.extra.clibs == 0, why)
j, why = child("wanted", { JNV_TEST_NOFFI = "1" })
chk("F22 a Neovim without LuaJIT: not wanted, needs LuaJIT, nothing loads", j ~= nil
    and j.extra.wanted == false and has(j.extra.why, "needs LuaJIT")
    and j.status.state == "unloaded" and j.extra.clibs == 0, why)
-- a setting that cannot be read: the answer is no, and why, never an error
j, why = child("wanted", { JNV_TEST_CONFIG_THROWS = "1" })
chk("F26 settings that throw when read: not wanted, could not tell why, nothing loads", j ~= nil
    and j.extra.wanted == false and type(j.extra.why) == "string" and j.extra.why:find("^could not tell:") ~= nil
    and has(j.extra.why, "test: config exploded") and j.status.state == "unloaded" and j.extra.clibs == 0, why)

section("F. the checks on the fake libraries (in this process)")
vim.env.JNV_FAKE = "ok"
local pr = N._probe(FAKE)
chk("F8 control: the fake in ok mode passes _probe with the plugin version", pr.ok == true
    and pr.version == VERSION and pr.abi == "1.0", vim.inspect(pr))
local flib, fstate, freason = N._open_lib(FAKE, { want = VERSION })
chk("F8 control: and _open_lib with the version check", flib ~= nil and fstate == "ok", vim.inspect({ fstate, freason }))
local preal = N._probe(LIB)
chk("F8 _probe of the real library", preal.ok == true and preal.version == VERSION and preal.abi == "1.0", vim.inspect(preal))
vim.env.JNV_FAKE = "abi_major"
flib, fstate, freason = N._open_lib(FAKE, { want = VERSION })
chk("F9 ABI major 2: mismatch, ABI 2.0", flib == nil and fstate == "mismatch" and has(freason, "has ABI 2.0, this plugin needs 1.0 or a later 1.x"),
    vim.inspect({ fstate, freason }))
vim.env.JNV_FAKE = "ok"
flib, fstate, freason = N._open_lib(FAKE, { want = VERSION, need_minor = 1 })
chk("F10 a plugin that needs ABI 1.1: mismatch naming 1.0 and 1.1", flib == nil and fstate == "mismatch"
    and has(freason, "ABI 1.0") and has(freason, "needs 1.1"), vim.inspect({ fstate, freason }))
vim.env.JNV_FAKE = "version"
flib, fstate, freason = N._open_lib(FAKE, { want = VERSION })
chk("F11 another version: mismatch naming both", flib == nil and fstate == "mismatch"
    and has(freason, "is v0.0.0-fake but the plugin is v" .. VERSION), vim.inspect({ fstate, freason }))
vim.env.JNV_FAKE = "sizeof"
flib, fstate, freason = N._open_lib(FAKE, { want = VERSION })
chk("F12 other struct sizes: mismatch, struct layout", flib == nil and fstate == "mismatch"
    and has(freason, "has a different struct layout (jnv_buf 99 bytes, expected 16)"), vim.inspect({ fstate, freason }))
vim.env.JNV_FAKE = nil
flib, fstate, freason = N._open_lib(NOSYM, { want = VERSION })
chk("F13 a library without jnv_sizeof: mismatch naming it", flib == nil and fstate == "mismatch"
    and has(freason, "at " .. NOSYM .. " lacks jnv_sizeof (an older or foreign build)"), vim.inspect({ fstate, freason }))
flib, fstate, freason = N._open_lib(tmp .. "/nothing." .. EXT, {})
chk("F14 _open_lib of a missing file: missing", flib == nil and fstate == "missing", vim.inspect({ fstate, freason }))
chk("F every fake was checked in this process without changing its state", N.status().state == "ok")

-- ── H. :checkhealth jupynvim and the native config ───────────────────────
section("H. :checkhealth jupynvim and the native config (child processes)")
local LIB_HEAD = "jupynvim: in-process library (libjupynvim)"
local BACKEND_HEAD = "jupynvim: backend"
local INSTALL_HEAD = "jupynvim: installing the prebuilt"
-- the text of one section of a health report, from its title to the next
local function health_part(text, head)
  local a = text:find(head, 1, true)
  if not a then return "" end
  local b = text:find("\n%S[^\n]* ~\n", a + #head)
  return text:sub(a, b or #text)
end
local function line_with(text, sub)
  for l in text:gmatch("[^\n]+") do if has(l, sub) then return l end end
end
-- how a report line was written: h.ok, h.warn, h.error or h.info
local function level(l)
  if not l then return "absent" end
  if l:find("^%- .*OK ") then return "ok" end
  if l:find("^%- .*WARNING ") then return "warn" end
  if l:find("^%- .*ERROR ") then return "error" end
  if l:find("^%- ") then return "info" end
  return "other"
end
local function count(text, sub)
  local n, i = 0, 1
  while true do
    local a, b = text:find(sub, i, true)
    if not a then return n end
    n, i = n + 1, b + 1
  end
end
-- :checkhealth jupynvim in a child after setup(opts); the child's JSON, the
-- library's section and the installer's section
local function health(env, repo)
  local r = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-l",
    REPO .. "/tests/native/child_case.lua", repo or REPO, "health" }, { env = env, text = true }):wait(30000)
  local line
  for l in (r.stdout or ""):gmatch("[^\n]+") do
    if l:sub(1, 1) == "{" then line = l end
  end
  local ok, j = pcall(vim.json.decode, line or "")
  if not ok or type(j) ~= "table" or type(j.extra) ~= "table" or type(j.extra.health) ~= "string" then
    return nil, ("exit %s, stdout %q, stderr %q"):format(tostring(r.code), r.stdout or "", r.stderr or ""), "", ""
  end
  j.notes = type(j.notes) == "table" and j.notes or {}
  j.status = type(j.status) == "table" and j.status or {}
  local text = j.extra.health
  return j, text, health_part(text, LIB_HEAD), health_part(text, INSTALL_HEAD)
end
local function clean(part) return not has(part, "WARNING") and not has(part, "ERROR") end

-- H1 the library loads: an OK line with its version, ABI, path and workers
local hj, htext, hlib, hinst = health({})
local hl = hj and line_with(hlib, "libjupynvim v" .. VERSION .. " (ABI 1.0)")
local nw = hj and tonumber(hj.status.workers)
chk("H1 the report has the library's section, after the backend's and before the installer's", hj ~= nil
    and (htext:find(BACKEND_HEAD, 1, true) or math.huge) < (htext:find(LIB_HEAD, 1, true) or -1)
    and htext:find(LIB_HEAD, 1, true) < (htext:find(INSTALL_HEAD, 1, true) or -1), htext)
chk("H1 with the library: OK libjupynvim v" .. VERSION .. " (ABI 1.0) at the library, its worker threads",
    level(hl) == "ok" and nw ~= nil and nw >= 1 and nw <= 4
    and has(hl, ("libjupynvim v%s (ABI 1.0) at %s, %d worker thread%s"):format(VERSION, LIB, nw or -1, nw == 1 and "" or "s")),
    hl or hlib)
chk("H1 nothing in the library's section warns", hj ~= nil and clean(hlib), hlib)
chk("H1 setup({}) loads nothing; the default native config is enabled with workers = 0", hj ~= nil
    and hj.loaded_after_setup == false and type(hj.extra.config_native) == "table"
    and hj.extra.config_native.enabled == true and hj.extra.config_native.workers == 0
    and hj.extra.config_native.path == nil, hj and vim.inspect(hj.extra.config_native))
chk("H1 :checkhealth makes no notice", hj ~= nil and #hj.notes == 0, hj and vim.inspect(hj.notes))

-- H2 JUPYNVIM_NATIVE names a missing file
hj, htext, hlib = health({ JUPYNVIM_NATIVE = missing })
hl = line_with(hlib, "libjupynvim is not installed at")
chk("H2 JUPYNVIM_NATIVE=<missing file>: WARNING libjupynvim is not installed at it",
    level(hl) == "warn" and has(hl, "libjupynvim is not installed at " .. missing .. "; everything works without it"),
    hl or hlib)
chk("H2 the advice points at JUPYNVIM_NATIVE, not at an install that would not change it",
    has(hlib, "- JUPYNVIM_NATIVE names this file; unset it, or point it at a library you built")
    and not has(hlib, ":JupynvimInstall") and not has(hlib, "cargo build"), hlib)
chk("H2 and no notice", hj ~= nil and #hj.notes == 0, hj and vim.inspect(hj.notes))
hj, htext, hlib = health({ JUPYNVIM_NATIVE = missing, JNV_TEST_LIB_TARGET = "none" })
hl = line_with(hlib, "libjupynvim is not installed at")
chk("H2 the same where no library prebuilt is made: the file was named, so the advice is still the variable",
    level(hl) == "warn" and has(hlib, "- JUPYNVIM_NATIVE names this file; unset it, or point it at a library you built")
    and not has(hlib, "no libjupynvim prebuilt"), hlib)

-- H3 turned off in the environment
hj, htext, hlib = health({ JUPYNVIM_NATIVE = "off" })
hl = line_with(hlib, "libjupynvim is turned off")
chk("H3 JUPYNVIM_NATIVE=off: libjupynvim is turned off (info, no warning)",
    hl == "- libjupynvim is turned off by JUPYNVIM_NATIVE=off" and clean(hlib), hl or hlib)

-- H4 a nested setup() key merges into the defaults
hj, htext, hlib = health({ JNV_TEST_SETUP = '{"native":{"workers":2}}' })
hl = hj and line_with(hlib, "libjupynvim v" .. VERSION)
chk("H4 setup({ native = { workers = 2 } }) keeps enabled = true (deep merge)", hj ~= nil
    and type(hj.extra.config_native) == "table" and hj.extra.config_native.enabled == true
    and hj.extra.config_native.workers == 2, hj and vim.inspect(hj.extra.config_native) or htext)
chk("H4 and the library runs 2 worker threads", hj ~= nil and hj.status.workers == 2 and hj.status.state == "ok"
    and level(hl) == "ok" and has(hl, ", 2 worker threads"), (hl or hlib) .. " " .. vim.inspect(hj and hj.status))
hj, htext, hlib = health({ JNV_TEST_SETUP = '{"native":{"workers":1}}' })
hl = hj and line_with(hlib, "libjupynvim v" .. VERSION)
chk("H4 workers = 1: 1 worker thread", hj ~= nil and hj.status.workers == 1 and level(hl) == "ok"
    and has(hl, ", 1 worker thread") and not has(hl, "threads"), hl or hlib)

-- H5 turned off in setup()
hj, htext, hlib = health({ JNV_TEST_SETUP = '{"native":{"enabled":false}}' })
hl = line_with(hlib, "libjupynvim is turned off")
chk("H5 setup({ native = { enabled = false } }): turned off in setup() (info, no warning)",
    hl == "- libjupynvim is turned off in setup() (native.enabled = false)" and clean(hlib), hl or hlib)
chk("H5 the merge keeps workers = 0 beside enabled = false", hj ~= nil and type(hj.extra.config_native) == "table"
    and hj.extra.config_native.enabled == false and hj.extra.config_native.workers == 0,
    hj and vim.inspect(hj.extra.config_native))

-- H6, H7: JUPYNVIM_NATIVE names a file that does not load, or a library of
-- another version; the advice is about the variable, since an install or a
-- rebuild in core/ would not change what loads
local NAMED_FIX = "JUPYNVIM_NATIVE names this file; unset it, or point it at a library built from "
  .. "this version of the plugin, then restart Neovim"
local function named_advice(part)
  return has(part, "- " .. NAMED_FIX) and not has(part, ":JupynvimInstall") and not has(part, "cargo build")
end
hj, htext, hlib = health({ JUPYNVIM_NATIVE = garbage })
hl = line_with(hlib, "libjupynvim could not be loaded")
chk("H6 a file that does not load: WARNING with the reason", hj ~= nil and hj.status.state == "error"
    and level(hl) == "warn" and has(hl, "libjupynvim could not be loaded from " .. garbage), hlib)
chk("H6 the advice points at JUPYNVIM_NATIVE", named_advice(hlib), hlib)
hj, htext, hlib = health({ JUPYNVIM_NATIVE = FAKE, JNV_FAKE = "version" })
hl = line_with(hlib, "libjupynvim at ")
chk("H7 a library of another version: WARNING naming both versions", hj ~= nil and hj.status.state == "mismatch"
    and level(hl) == "warn" and has(hl, "libjupynvim at " .. FAKE .. " is v0.0.0-fake but the plugin is v" .. VERSION),
    hlib)
chk("H7 the advice points at JUPYNVIM_NATIVE", named_advice(hlib), hlib)

-- H8 a Neovim without LuaJIT
hj, htext, hlib = health({ JNV_TEST_NOFFI = "1" })
hl = line_with(hlib, "libjupynvim needs LuaJIT")
chk("H8 a Neovim without LuaJIT: needs LuaJIT; everything works without it (info, no warning)",
    hl == "- libjupynvim needs LuaJIT, and this Neovim was built without it; everything works without it"
    and clean(hlib), hl or hlib)

-- H9 native.path in setup() names a missing file
local nolib = tmp .. "/nolib." .. EXT
hj, htext, hlib = health({ JNV_TEST_SETUP = vim.json.encode({ native = { path = nolib } }) })
hl = line_with(hlib, "libjupynvim is not installed at")
chk("H9 native.path = <missing file>: WARNING libjupynvim is not installed at it",
    level(hl) == "warn" and has(hl, "libjupynvim is not installed at " .. nolib), hl or hlib)
chk("H9 the advice points at native.path", has(hlib, "- native.path in setup() names this file; remove it, "
    .. "or point it at a library you built") and not has(hlib, ":JupynvimInstall"), hlib)

-- H10, H11: a plugin directory without the library (a copy of lua/ and of
-- core/Cargo.toml), as after an install that did not fetch it
local plug = tmp .. "/plug"
vim.fn.mkdir(plug .. "/core", "p")
local cp = vim.system({ "cp", "-R", REPO .. "/lua", plug .. "/lua" }):wait()
vim.fn.writefile(vim.fn.readfile(REPO .. "/core/Cargo.toml"), plug .. "/core/Cargo.toml")
chk("H10 a plugin directory without the library", cp.code == 0 and vim.uv.fs_stat(plug .. "/lua/jupynvim/init.lua") ~= nil
    and vim.uv.fs_stat(plug .. "/core/target") == nil, cp.stderr)
local plib = plug .. "/core/target/release/libjupynvim." .. EXT
local refused = "does not load here: a test reason"
hj, htext, hlib, hinst = health({ JNV_TEST_LIB_TARGET = "test-target:" .. EXT, JNV_TEST_LIB_REFUSED = refused }, plug)
hl = line_with(hlib, "libjupynvim is not installed at")
chk("H10 no library where a prebuilt is made: WARNING libjupynvim is not installed at the plugin's place",
    hj ~= nil and hj.status.state == "missing" and level(hl) == "warn"
    and has(hl, "libjupynvim is not installed at " .. plib .. "; everything works without it"), hl or htext)
chk("H10 the advice is the install", hj ~= nil and hj.status.fix == "Run :JupynvimInstall"
    and has(hlib, "- Run :JupynvimInstall"), hlib)
hl = line_with(hinst, "library prebuilt for this platform")
chk("H10 the installer's section: OK library prebuilt for this platform: test-target",
    level(hl) == "ok" and has(hl, "library prebuilt for this platform: test-target"), hl or hinst)
hl = line_with(hinst, "library prebuilt was refused")
chk("H10 and the refused library prebuilt, once, as a WARNING", level(hl) == "warn"
    and has(hl, ("the v%s library prebuilt was refused: %s"):format(VERSION, refused))
    and count(hinst, "library prebuilt was refused") == 1, hinst)
hj, htext, hlib, hinst = health({ JNV_TEST_LIB_TARGET = "none" }, plug)
hl = line_with(hlib, "no libjupynvim prebuilt")
chk("H11 no library and no prebuilt for this platform: how to build it (info, no warning)",
    hj ~= nil and hj.status.state == "missing" and hl == "- no libjupynvim prebuilt is made for this platform; "
    .. "cargo build --release in core/ builds it; everything works without it" and clean(hlib), hl or htext)
chk("H11 the installer's section names no library prebuilt", hj ~= nil
    and not has(hinst, "library prebuilt for this platform:") and not has(hinst, "library prebuilt was refused"), hinst)

-- H12, H13: at the plugin's own place, a file that does not load and a
-- library of another version: the advice is the install, then a restart
vim.fn.mkdir(plug .. "/core/target/release", "p")
vim.fn.writefile({ "not a library" }, plib)
hj, htext, hlib = health({}, plug)
hl = line_with(hlib, "libjupynvim could not be loaded")
chk("H12 a file at the plugin's place that does not load: WARNING with the reason", hj ~= nil
    and hj.status.state == "error" and level(hl) == "warn" and has(hl, "libjupynvim could not be loaded from " .. plib),
    hlib)
chk("H12 the advice is the install, then a restart", hj ~= nil
    and hj.status.fix == "Run :JupynvimInstall, then restart Neovim" and has(hlib, "- " .. hj.status.fix), hlib)
local cpf = vim.uv.fs_copyfile(FAKE, plib)
hj, htext, hlib = health({ JNV_FAKE = "version" }, plug)
hl = line_with(hlib, "libjupynvim at ")
chk("H13 a library of another version at the plugin's place: WARNING naming both versions", cpf and hj ~= nil
    and hj.status.state == "mismatch" and level(hl) == "warn"
    and has(hl, "libjupynvim at " .. plib .. " is v0.0.0-fake but the plugin is v" .. VERSION), hlib)
chk("H13 the advice is the install, then a restart", hj ~= nil
    and hj.status.fix == "Run :JupynvimInstall, then restart Neovim" and has(hlib, "- " .. hj.status.fix), hlib)

-- H14 more worker threads than the library takes runs the most it takes
hj, htext, hlib = health({ JNV_TEST_SETUP = '{"native":{"workers":100}}' })
hl = hj and line_with(hlib, "libjupynvim v" .. VERSION)
chk("H14 setup({ native = { workers = 100 } }): the library runs 64 worker threads", hj ~= nil
    and hj.status.state == "ok" and hj.status.workers == 64 and hj.available == true,
    hj and vim.inspect(hj.status) or htext)
chk("H14 and says so in an OK line, with no warning", level(hl) == "ok" and has(hl, ", 64 worker threads")
    and clean(hlib), hl or hlib)

-- H15 the shorthand native = false is native = { enabled = false }
hj, htext, hlib = health({ JNV_TEST_SETUP = '{"native":false}' })
hl = line_with(hlib, "libjupynvim is turned off")
chk("H15 setup({ native = false }): disabled, not available", hj ~= nil and hj.status.state == "disabled"
    and hj.available == false and has(hj.status.reason, "turned off in setup() (native = false)"),
    hj and vim.inspect(hj.status) or htext)
chk("H15 the library's section says it is turned off in setup() (info, no warning)",
    hl == "- libjupynvim is turned off in setup() (native = false)" and clean(hlib), hl or hlib)

-- H16 the plugin's own place in a checkout with a cargo build (cargo's
-- core/target/release/.fingerprint): the advice is the rebuild, never the
-- install, which would not change what a build of your own loads
vim.fn.mkdir(plug .. "/core/target/release/.fingerprint", "p")
os.remove(plib)
hj, htext, hlib = health({}, plug)
chk("H16 a cargo build at the plugin's place without the library: the advice is the rebuild", hj ~= nil
    and hj.status.state == "missing" and hj.status.source == "plugin"
    and hj.status.fix == "Rebuild it: cargo build --release in core/" and has(hlib, "- " .. hj.status.fix),
    hj and vim.inspect(hj.status) or htext)
vim.fn.writefile({ "not a library" }, plib)
hj, htext, hlib = health({}, plug)
chk("H16 and for a file there that does not load, the rebuild, then a restart", hj ~= nil
    and hj.status.state == "error" and hj.status.source == "plugin"
    and hj.status.fix == "Rebuild it: cargo build --release in core/, then restart Neovim"
    and has(hlib, "- " .. hj.status.fix), hj and vim.inspect(hj.status) or htext)
os.remove(plib)
local cpf16 = vim.uv.fs_copyfile(FAKE, plib)
hj, htext, hlib = health({ JNV_FAKE = "version" }, plug)
chk("H16 and for a library of another version there, the rebuild, then a restart", cpf16 and hj ~= nil
    and hj.status.state == "mismatch" and hj.status.source == "plugin"
    and hj.status.fix == "Rebuild it: cargo build --release in core/, then restart Neovim"
    and has(hlib, "- " .. hj.status.fix), hj and vim.inspect(hj.status) or htext)

-- H17 to H21: the plugin's own place without a cargo build again (with one,
-- nothing is ever fetched there and the advice is the rebuild)
vim.fn.delete(plug .. "/core/target/release/.fingerprint", "rf")
-- H17 the advice follows a background install: H16's fake at the plugin's
-- place, of another version
local BG_RUN_STALE = "A matching libjupynvim is being installed in the background; restart Neovim once it is in"
local BG_DONE = "A matching libjupynvim was installed; restart Neovim to load it"
local BG_RUN_MISSING = "A matching libjupynvim is being installed in the background; it loads on its next use"
for _, c in ipairs({ { "running", BG_RUN_STALE }, { "done", BG_DONE } }) do
  hj, htext, hlib = health({ JNV_FAKE = "version", JNV_TEST_BG = c[1] }, plug)
  chk(("H17 a library of another version while the background install is %s: the advice is %q"):format(c[1], c[2]),
      hj ~= nil and hj.status.state == "mismatch" and hj.status.fix == c[2] and has(hlib, "- " .. c[2]),
      hj and (vim.inspect(hj.status) .. "\n" .. hlib) or htext)
end
-- H18 a release that did not publish the library is not a refusal, and a
-- notebook opened a day later asks again
hj, htext, hlib, hinst = health({ JNV_TEST_LIB_TARGET = "test-target:" .. EXT,
  JNV_TEST_LIB_REFUSED = "not published in v" .. VERSION }, plug)
hl = line_with(hinst, "publishes no library prebuilt")
chk("H18 a library prebuilt the release does not publish: an info line, never refused", level(hl) == "info"
    and has(hl, ("the v%s release publishes no library prebuilt for test-target; a notebook opened a day after that"
      .. " was found asks again, and :JupynvimInstall asks now"):format(VERSION))
    and not has(hinst, "was refused"), hinst)
os.remove(plib)
-- H19 to H21: a first use that finds the plugin's own library missing asks
-- for the background install a notebook open starts; each child has a state
-- dir of its own (install_spec leaves library verdicts in the shared one)
local function heal(env)
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return child("heal", vim.tbl_extend("force", { XDG_STATE_HOME = d }, env or {}), nil, plug)
end
local hh, hwhy = heal()
local he = hh and hh.extra or {}
chk("H19 a first use (two when_ready) that finds the plugin's own library missing starts one background install,"
    .. " for the plugin's directory, after the load returned", hh ~= nil and hh.status.state == "missing"
    and he.bg_starts == 1 and he.bg_starts_at_cb == 0 and he.bg_dir == plug and he.bg_state == "running", hwhy)
chk("H19 and the advice says it is on its way", hh ~= nil and he.fix == BG_RUN_MISSING, hwhy)
hh, hwhy = heal({ JNV_TEST_SYNC = "1" })
he = hh and hh.extra or {}
chk("H20 available() alone starts none: it reports and never installs", hh ~= nil and hh.status.state == "missing"
    and he.bg_starts == 0 and he.fix == "Run :JupynvimInstall", hwhy)
hh, hwhy = heal({ JNV_TEST_SETUP = vim.json.encode({ auto_install = false }) })
he = hh and hh.extra or {}
chk("H21 with auto_install = false a first use starts none", hh ~= nil and hh.status.state == "missing"
    and he.bg_starts == 0, hwhy)
hh, hwhy = heal({ JUPYNVIM_NATIVE = tmp .. "/none." .. EXT })
he = hh and hh.extra or {}
chk("H21 nor for a file JUPYNVIM_NATIVE names (source env)", hh ~= nil and hh.status.state == "missing"
    and hh.status.source == "env" and he.bg_starts == 0, hwhy)
-- H22 :checkhealth jupynvim is what the notice says to run, and the first
-- thing a fresh session may run: its load goes through the probe as a first
-- use does (macOS), so a library that kills the process that loads it is
-- reported, never loaded into the editor; and it never asks for an install
if jit.os == "OSX" then
  for _, c in ipairs({ { "kill", "killed by signal 9 (SIGKILL)" }, { "signal", "killed by signal 31 (SIGUSR2)" } }) do
    local killer = tmp .. "/h22-" .. c[1] .. "." .. EXT
    vim.uv.fs_copyfile(FAKE, killer)
    hj, htext, hlib = health({ JUPYNVIM_NATIVE = killer, JNV_FAKE = c[1] })
    hl = line_with(hlib, "could not be loaded from " .. killer)
    chk(("H22 :checkhealth jupynvim in a fresh session with a library that ends its loader (%s): the editor"
      .. " lives and the library's section gives the probe's reason"):format(c[2]), hj ~= nil
      and hj.status.state == "error" and level(hl) == "warn"
      and has(hl, "a separate Neovim that loaded it first was " .. c[2]),
      hj and hlib or htext)
  end
else
  io.write("  H22 :checkhealth with a library that kills its loader: macOS only (the first open is here elsewhere)\n")
end
do
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  hj, htext, hlib = health({ XDG_STATE_HOME = d }, plug)
  chk("H22 :checkhealth jupynvim with the plugin's own library missing reports it and asks for no install",
      hj ~= nil and hj.status.state == "missing" and hj.status.source == "plugin" and hj.extra.bg_starts == 0,
      hj and vim.inspect({ hj.status, hj.extra.bg_starts }) or htext)
end

-- ── shutdown of the default context (last) ───────────────────────────────
section("E3. shutdown of the default context")
chk("E3 every buffer is freed", tonumber(lib.jnv_live_buffers()) == live0,
    tostring(lib.jnv_live_buffers()) .. " vs " .. live0)
N.shutdown()
chk("E3 shutdown() closes the default context: state closed, not available", S.ctx.closed == true
    and N.status().state == "closed" and N.available() == false, vim.inspect(N.status()))
local r3, e3 = N.submit(K.NOP, "", {}, nil)
chk("E3 then module functions say unavailable", r3 == nil and has(e3, "libjupynvim unavailable"), tostring(e3))

vim.fn.delete(tmp, "rf")
finish()

-- libjupynvim, the in-process library, seen from Lua.
--
-- The library is a Rust cdylib that cargo builds next to jupynvim-core
-- (core/target/release/libjupynvim.dylib or .so). Neovim loads it through
-- LuaJIT's FFI. Heavy work runs on its worker threads, never on the UI
-- thread; a finished batch writes one byte to a pipe that Neovim's event
-- loop watches, and one scheduled pump hands the results to their callbacks
-- on the main loop. Documents are passed by pointer and results are read in
-- place. Everything works without it: available() is false and callers
-- keep their own code path.
--
-- Standalone: it requires only ffi (guarded), vim and, lazily, jupynvim.log,
-- so the installer's probe can load it by path with dofile.
--
-- Discovery: JUPYNVIM_NATIVE (off, 0, false or no turns it off; any other
-- value is the library's path), then setup({ native = { enabled, path,
-- workers } }) (native = false is enabled = false), then <plugin
-- root>/core/target/release/libjupynvim.<ext>. A relative path is taken
-- from the current directory at the first load. Nothing loads at require
-- or setup(): the first available() (or any call) does, once per process.
--
-- A consumer on an interactive path (a notebook open, a buffer being
-- typed in) calls warm() as early as its path allows and when_ready(cb)
-- before its first job in a buffer, never available(): the first dlopen of
-- a file the system has not opened before can take tens of milliseconds,
-- and when_ready does it away from the UI thread, then calls cb(ok,
-- status()) on the main loop. available() stays for :checkhealth, tests
-- and callers that must know at once.
--
-- State lives in the Lua registry, so reloading this module never loads a
-- second copy or starts a second worker pool, and no loaded library is ever
-- released: a worker thread may still be running its code. One context per
-- process (the default one); tests open private ones.

local M = {}

local REG = debug.getregistry()
REG.jupynvim_native = REG.jupynvim_native
  or { state = "unloaded", clibs = {}, graveyard = {}, cdefs = {}, notified = false }
local S = REG.jupynvim_native

local has_ffi, ffi = pcall(require, "ffi")
if not has_ffi then ffi = nil end

M.ABI_MAJOR, M.ABI_MINOR = 1, 0
M.KIND = { NOP = 1, ECHO = 2, BYTESUM = 3, PTR = 4, SLEEP = 5, PANIC = 6, FILL = 7 }
M.STATUS = { OK = 0, ERR = 1, PANIC = 2, CANCELLED = 3, EINVAL = 4, EKIND = 5, ESHUTDOWN = 6, ENOJOB = 7 }
M.PRIO = { visible = 0, normal = 1, background = 2 }
M.FLAG_COPY = 256
-- The most worker threads the library takes (MAX_WORKERS in pool.rs).
M.MAX_WORKERS = 64

-- The declarations between the markers of core/native/include/jupynvim.h,
-- verbatim (tests/native_spec.lua compares them).
M._CDEF = [[
typedef struct jnv_ctx jnv_ctx;
typedef struct jnv_buf { const uint8_t *ptr; size_t len; } jnv_buf;
typedef struct jnv_done { uint64_t job; uint32_t kind; int32_t status; jnv_buf *result; } jnv_done;
enum {
  JNV_OK = 0, JNV_ERR = 1, JNV_PANIC = 2, JNV_CANCELLED = 3,
  JNV_EINVAL = 4, JNV_EKIND = 5, JNV_ESHUTDOWN = 6, JNV_ENOJOB = 7
};
enum { JNV_PRIO_VISIBLE = 0, JNV_PRIO_NORMAL = 1, JNV_PRIO_BACKGROUND = 2, JNV_FLAG_COPY = 256 };
enum {
  JNV_KIND_NOP = 1, JNV_KIND_ECHO = 2, JNV_KIND_BYTESUM = 3, JNV_KIND_PTR = 4,
  JNV_KIND_SLEEP = 5, JNV_KIND_PANIC = 6, JNV_KIND_FILL = 7
};
enum { JNV_SIZEOF_BUF = 1, JNV_SIZEOF_DONE = 2 };
uint32_t jnv_abi_version(void);
const char *jnv_version(void);
size_t jnv_sizeof(uint32_t which);
int32_t jnv_kind_supported(uint32_t kind);
uint64_t jnv_live_buffers(void);
void jnv_buf_free(jnv_buf *buf);
jnv_ctx *jnv_open(uint32_t workers, jnv_buf **err);
int32_t jnv_wake_fd(jnv_ctx *ctx);
uint32_t jnv_workers(const jnv_ctx *ctx);
void jnv_close(jnv_ctx *ctx);
int32_t jnv_call(jnv_ctx *ctx, uint32_t kind, const char *data, size_t len, jnv_buf **out);
int32_t jnv_submit(jnv_ctx *ctx, uint32_t kind, uint32_t flags, const char *data, size_t len, uint64_t *job);
int32_t jnv_cancel(jnv_ctx *ctx, uint64_t job);
size_t jnv_poll(jnv_ctx *ctx, jnv_done *out, size_t cap);
]]

-- Every export, in the order a stale or foreign build is checked for them.
local SYMBOLS = {
  "jnv_abi_version", "jnv_version", "jnv_sizeof", "jnv_kind_supported", "jnv_live_buffers",
  "jnv_buf_free", "jnv_open", "jnv_wake_fd", "jnv_workers", "jnv_close", "jnv_call",
  "jnv_submit", "jnv_cancel", "jnv_poll",
}

local STATUS_NAME = {}
for name, code in pairs(M.STATUS) do STATUS_NAME[code] = name end
local function status_name(code) return STATUS_NAME[code] or ("status " .. tostring(code)) end

local BATCH = 64            -- completions per jnv_poll
local TICK_NS = 2e6         -- a pump tick hands over the main loop after 2 ms
local NO_LUAJIT = "needs LuaJIT, and this Neovim was built without it"
local function noop() end

-- ── helpers ──────────────────────────────────────────────────────────────

-- Through jupynvim.log, required lazily; never throws. Its first require
-- touches vim.fn, which a fast event (a luv callback) may not, so a message
-- from one waits for the main loop.
local function log(level, msg)
  local function write()
    local ok, L = pcall(require, "jupynvim.log")
    if ok and type(L) == "table" and type(L[level]) == "function" then pcall(L[level], msg) end
  end
  if vim.in_fast_event() then vim.schedule(write) else write() end
end

local function exists(path) return vim.uv.fs_stat(path) ~= nil end

-- A path the user gave, ~ and $VARS expanded and made absolute against the
-- current directory: dlopen of a name without a slash searches the library
-- path on glibc, never the current directory, so the file checked would not
-- be the file loaded. Only luv and string, so it works in a fast event.
local function absolute(p)
  p = vim.fs.normalize(p)
  if p:sub(1, 1) ~= "/" then p = vim.fs.normalize((vim.uv.cwd() or ".") .. "/" .. p) end
  return p
end

-- The plugin's directory: up from this file to the one that holds
-- lua/jupynvim/init.lua. Only luv and string work, so a load from a fast
-- event works too.
local root_memo
local function plugin_root()
  if root_memo ~= nil then return root_memo or nil end
  root_memo = false
  local src = debug.getinfo(1, "S").source
  if src:sub(1, 1) ~= "@" then return nil end
  src = src:sub(2)
  if src:sub(1, 1) ~= "/" then src = (vim.uv.cwd() or ".") .. "/" .. src end
  local dir = vim.fs.normalize(src):match("^(.*)/[^/]*$")
  for _ = 1, 8 do
    if not dir or dir == "" then break end
    if exists(dir .. "/lua/jupynvim/init.lua") then
      root_memo = dir
      return dir
    end
    dir = dir:match("^(.*)/[^/]*$")
  end
  return nil
end

-- The plugin's version: the first version line of core/Cargo.toml.
local function plugin_version(root)
  local f = root and io.open(root .. "/core/Cargo.toml", "r")
  if not f then return nil end
  for line in f:lines() do
    local v = line:match('^version%s*=%s*"([^"]+)"')
    if v then
      f:close()
      return v
    end
  end
  f:close()
  return nil
end

local function lib_filename()
  if type(jit) ~= "table" then return nil end
  if jit.os == "OSX" then return "libjupynvim.dylib" end
  if jit.os == "Linux" or jit.os == "BSD" then return "libjupynvim.so" end
  return nil
end

-- setup({ native = false }) is setup({ native = { enabled = false } }); this
-- table stands for it, so the reason can say which one was written.
local OFF_CFG = { enabled = false }

local function config()
  local J = package.loaded["jupynvim"]
  if type(J) ~= "table" or type(J.config) ~= "table" then return {} end
  local c = J.config.native
  if c == false then return OFF_CFG end
  return type(c) == "table" and c or {}
end

-- 0 picks the count automatically; anything that is not a whole number
-- of at least 0 means that too. A count above MAX_WORKERS runs that many.
local function workers_of(w)
  w = tonumber(w)
  if not w or w < 0 or w ~= math.floor(w) then return 0 end
  if w > M.MAX_WORKERS then return M.MAX_WORKERS end
  return w
end

-- What to do about a library that is missing or does not load. A file the
-- user named is fixed by changing that setting: an install or a rebuild in
-- core/ would not change what loads. :checkhealth and the one notice both
-- print this text.
local NAMED_BY = {
  env = "JUPYNVIM_NATIVE names this file; unset it",
  setup = "native.path in setup() names this file; remove it",
}
local function fix_for(state, source)
  if state ~= "missing" and state ~= "mismatch" and state ~= "error" then return nil end
  local named = NAMED_BY[source]
  if named then
    if state == "missing" then return named .. ", or point it at a library you built" end
    return named .. ", or point it at a library built from this version of the plugin, then restart Neovim"
  end
  local root = plugin_root()
  local fix = (root and exists(root .. "/core/target/release/.fingerprint"))
    and "Rebuild it: cargo build --release in core/" or "Run :JupynvimInstall"
  if state ~= "missing" then fix = fix .. ", then restart Neovim" end
  return fix
end

local OFF = { off = true, ["0"] = true, ["false"] = true, no = true }

-- Where the library is: a path, nil, nil and where the path came from
-- ("env", "setup" or "plugin"), or nil, state, reason. os.getenv sees what
-- vim.env sets and, unlike vim.env, works in a fast event.
local function resolve()
  local env = os.getenv("JUPYNVIM_NATIVE")
  if env == "" then env = nil end
  if env and OFF[env:lower()] then return nil, "disabled", "turned off by JUPYNVIM_NATIVE=" .. env end
  local cfg = config()
  if not env and cfg.enabled == false then
    return nil, "disabled", cfg == OFF_CFG and "turned off in setup() (native = false)"
      or "turned off in setup() (native.enabled = false)"
  end
  if type(jit) ~= "table" or not ffi then return nil, "unsupported", NO_LUAJIT end
  if not ffi.abi("64bit") or not ffi.abi("le") then
    return nil, "unsupported", "needs a 64-bit little-endian platform"
  end
  local name = lib_filename()
  if not name then
    return nil, "unsupported", ("is not built for %s %s"):format(tostring(jit.os), tostring(jit.arch))
  end
  if env then return absolute(env), nil, nil, "env" end
  if type(cfg.path) == "string" and cfg.path ~= "" then return absolute(cfg.path), nil, nil, "setup" end
  local root = plugin_root()
  if not root then return nil, "missing", "not found: the plugin's directory could not be located" end
  return root .. "/core/target/release/" .. name, nil, nil, "plugin"
end

-- Whether the library the installer puts in the plugin's place is the
-- one this Neovim would load: false, and why, when it is turned off, a
-- file of the user's own is named, or this Neovim cannot load it.
-- Settings only: no dlopen, no change to the loader's state, and safe
-- in a fast event.
function M.plugin_lib_wanted()
  local ok, path, state, reason, source = pcall(resolve)
  if not ok then return false, "could not tell: " .. tostring(path) end
  if path and source == "plugin" then return true end
  if path then
    return false, source == "env" and "JUPYNVIM_NATIVE names a library of your own"
      or "native.path in setup() names a library of your own"
  end
  return false, reason or state
end

local function ensure_cdef()
  if not S.cdef_done then
    ffi.cdef(M._CDEF)
    S.cdef_done = true
  end
end

-- Declarations a later feature adds, once per name per process.
function M.cdef(name, decls)
  if not ffi then error("libjupynvim: " .. NO_LUAJIT, 2) end
  ensure_cdef()
  if S.cdefs[name] then return end
  ffi.cdef(decls)
  S.cdefs[name] = true
end

-- Open the library at path and check it: every export present, the ABI, the
-- struct layout and (unless opts.skip_version) the version opts.want.
-- Returns the clib, "ok", nil, info or nil, state, reason, info; info holds
-- the version and ABI when the library could tell them.
function M._open_lib(path, opts)
  opts = opts or {}
  if not ffi then return nil, "unsupported", NO_LUAJIT end
  ensure_cdef()
  if type(path) ~= "string" or not exists(path) then
    return nil, "missing", "not found at " .. tostring(path)
  end
  local lib = S.clibs[path]
  if not lib then
    local ok, res = pcall(ffi.load, path)
    if not ok then
      local why = tostring(res):gsub("%s+$", "")
      return nil, "error", ("could not be loaded from %s: %s"):format(path, why)
    end
    lib = res
    S.clibs[path] = lib -- never released
  end
  for _, name in ipairs(SYMBOLS) do
    if not pcall(function() return lib[name] end) then
      return nil, "mismatch", ("at %s lacks %s (an older or foreign build)"):format(path, name)
    end
  end
  local v = tonumber(lib.jnv_abi_version())
  local major, minor = math.floor(v / 65536), v % 65536
  local vp = lib.jnv_version()
  local info = { abi = major .. "." .. minor, major = major, minor = minor,
                 version = vp ~= nil and ffi.string(vp) or nil }
  local need = opts.need_minor or M.ABI_MINOR
  if major ~= M.ABI_MAJOR or minor < need then
    return nil, "mismatch", ("at %s has ABI %d.%d, this plugin needs %d.%d or a later %d.x"):format(
      path, major, minor, M.ABI_MAJOR, need, M.ABI_MAJOR), info
  end
  for _, s in ipairs({ { 1, "jnv_buf" }, { 2, "jnv_done" } }) do
    local have, want = tonumber(lib.jnv_sizeof(s[1])), ffi.sizeof(s[2])
    if have ~= want then
      return nil, "mismatch", ("at %s has a different struct layout (%s %d bytes, expected %d)"):format(
        path, s[2], have, want), info
    end
  end
  if not opts.skip_version and info.version ~= opts.want then
    return nil, "mismatch", ("at %s is v%s but the plugin is v%s"):format(
      path, tostring(info.version), tostring(opts.want)), info
  end
  return lib, "ok", nil, info
end

-- The checks alone, no context (the installer's probe). Never throws.
function M._probe(path)
  local ok, lib, state, reason, info = pcall(M._open_lib, path, { skip_version = true })
  if not ok then return { ok = false, state = "error", reason = "probe failed: " .. tostring(lib) } end
  info = info or {}
  return { ok = lib ~= nil, state = state, version = info.version, abi = info.abi, reason = reason }
end

-- ── loading without blocking ─────────────────────────────────────────────
-- On macOS the first dlopen of a library file no process has opened yet
-- checks its code signature, tens of milliseconds, and holds dyld's lock
-- all that time: even with the open on a thread of its own, the main
-- thread's next library load (a treesitter parser, a first ffi.C lookup)
-- waits for it. Another process's open holds no lock of this one, and once
-- any process has opened the file the system keeps it checked, so the open
-- here then takes under a millisecond. So the first open happens in a
-- short Neovim of its own, the installer's probe (native_probe.lua, which
-- also runs the checks), and this process loads the library on the main
-- loop once the probe is done. A library that kills the process that loads
-- it, or whose load never returns, is then never loaded here. Elsewhere a
-- first open is fast: it happens on the main loop at once.

-- How long the probe may take. Past it the loader stops the probe itself,
-- with SIGKILL (a process stuck inside a library's load never runs the
-- event loop that would act on a TERM), and refuses that file for the rest
-- of the session: loading it here would never return either. Tests lower it.
M._probe_ms = 10000
local function probe_limit()
  local ms = tonumber(M._probe_ms)
  return (ms and ms > 0) and ms or 10000
end
-- How the probe's Neovim may stop without the library having done it: its
-- terminal going away, which ends the editor too. The loader's own stops
-- (the limit, the editor's exit) are marked on the probe. Any other signal
-- is the library's, SIGKILL included: on macOS it is how the system ends a
-- process that maps a library page whose code signature fails (a build
-- copied over a library some process holds open).
local STOPS = { SIGHUP = true, SIGINT = true, SIGPIPE = true }
local SIGNAL_NAME = {}
local ALIAS = { SIGIOT = true, SIGCLD = true, SIGPOLL = true }
for name, n in pairs(vim.uv.constants or {}) do
  if type(name) == "string" and name:match("^SIG[%u%d]+$") and not ALIAS[name] and type(n) == "number" then
    SIGNAL_NAME[n] = name
  end
end

local function open_elsewhere() return type(jit) == "table" and jit.os == "OSX" end

-- A first use that finds the plugin's own library missing or unusable asks,
-- once per process, for the background install a notebook open starts:
-- .md files and remote notebooks never start a local backend, so that open
-- never comes for them. Scheduled, never inside the load. It does nothing
-- where jupynvim is not set up (the probe's and the install job's Neovims).
local function ask_install()
  if S.install_asked then return end
  S.install_asked = true
  vim.schedule(function()
    local J = package.loaded["jupynvim"]
    local f = type(J) == "table" and J._maybe_fetch_lib
    local root = plugin_root()
    if type(f) == "function" and root then
      local ok, err = pcall(f, root, plugin_version(root))
      if not ok then log("warn", "libjupynvim: could not ask for an install: " .. tostring(err)) end
    end
  end)
end

local STALE = { missing = true, mismatch = true, error = true }

-- Load, then call every when_ready callback waiting, each with its own
-- status(). Runs on the main loop, never in a fast event.
local function finish_ready()
  local ok = M.load()
  if S.source == "plugin" and STALE[S.state] then ask_install() end
  local waiters = S.waiters or {}
  S.waiters = {}
  for _, cb in ipairs(waiters) do
    local okc, err = xpcall(cb, debug.traceback, ok, M.status())
    if not okc then log("error", "libjupynvim when_ready callback: " .. tostring(err)) end
  end
end

local function wake_waiters()
  if S.waiters and #S.waiters > 0 then vim.schedule(finish_ready) end
end

local function close_timer(w)
  local t = w.timer
  w.timer = nil
  if t and not t:is_closing() then
    t:stop()
    t:close()
  end
end

-- The probe ended (a fast event): what it learned, then the waiters. After
-- the limit or at the editor's exit there is nothing left to learn.
local function probe_done(w, res)
  w.exited = true
  close_timer(w)
  if w.done or w.leaving then return end
  w.done = true
  w.ms = (vim.uv.hrtime() - w.t0) / 1e6
  local sig = res and tonumber(res.signal) or 0
  local name = SIGNAL_NAME[sig]
  local out = res and res.stdout or ""
  if not res then
    w.fallback = "the probe gave no result"
  elseif sig ~= 0 and not STOPS[name] then
    w.killed = ("a separate Neovim that loaded it first was killed by signal %d (%s)"):format(sig, tostring(name))
  elseif sig ~= 0 then
    w.fallback = "the probe was stopped by " .. tostring(name)
  else
    w.err = out:match("jnv%-probe err ([^\n]*)")
    if not w.err and not out:find("jnv-probe ok", 1, true) then
      w.fallback = "the probe said nothing (exit " .. tostring(res.code) .. ")"
    end
  end
  if w.fallback then log("debug", "libjupynvim: " .. w.fallback .. "; it is loaded here") end
  wake_waiters()
end

-- The limit passed with the probe still running (a fast event): stop it
-- for good and answer the waiters now, without waiting for its exit (a
-- process stuck on a stalled file system may take long to die).
local function probe_late(w)
  close_timer(w)
  if w.done or w.leaving then return end
  w.done = true
  w.ms = (vim.uv.hrtime() - w.t0) / 1e6
  w.late = ("a separate Neovim that loaded it first gave no answer within %g s"):format(w.limit / 1000)
  if w.proc then pcall(w.proc.kill, w.proc, "sigkill") end
  log("debug", "libjupynvim: " .. w.late .. "; it is not loaded here")
  wake_waiters()
end

-- Start the probe for w (on the main loop: vim.v and the spawn's error path
-- are not for a fast event), with the loader's own limit. A Neovim that
-- exits while it runs stops it, with SIGKILL as at the limit.
local function start_probe(w)
  local root = plugin_root()
  local script = root and (root .. "/lua/jupynvim/backend/native_probe.lua")
  if not script or not exists(script) then error("the probe script is not next to the loader") end
  local timer = assert(vim.uv.new_timer(), "no timer for the probe's limit")
  w.limit = probe_limit()
  local ok, proc = pcall(vim.system, { vim.v.progpath, "--clean", "--headless", "-l", script, w.path, root },
    { text = true }, function(res) probe_done(w, res) end)
  if not ok then
    timer:close()
    error(proc, 0)
  end
  w.proc, w.timer = proc, timer
  -- from now, not from the loop's cached time, which may lag
  vim.uv.update_time()
  if not w.exited then timer:start(w.limit, 0, function() probe_late(w) end) end
  pcall(vim.api.nvim_create_autocmd, "VimLeavePre", {
    group = vim.api.nvim_create_augroup("jupynvim_native_probe", { clear = true }),
    callback = function()
      if w.proc and not w.exited then
        w.leaving = true
        pcall(w.proc.kill, w.proc, "sigkill")
      end
    end,
  })
end

-- Start the first open of the library away from the UI thread, once per
-- process. True when one runs or ran, or the library is loaded; false when
-- there is nothing to open (turned off, unsupported, no such file) or the
-- state is final. Never throws, never blocks, safe in a fast event.
function M.warm()
  if S.state ~= "unloaded" then return S.state == "ok" end
  if S.warm then return true end
  local okr, path = pcall(resolve)
  if not okr or type(path) ~= "string" or not exists(path) then return false end
  local w = { path = path, t0 = vim.uv.hrtime(), done = false }
  S.warm = w
  if not open_elsewhere() then
    -- a first open is fast here: it happens on the main loop
    w.done, w.ms, w.how = true, 0, "here"
    return true
  end
  w.how = "probe"
  local function start()
    local ok, err = pcall(start_probe, w)
    if not ok then
      -- no probe: the main loop opens it, as a first available() would
      w.done, w.fallback = true, "the probe could not start: " .. tostring(err)
      log("debug", "libjupynvim: " .. w.fallback .. "; it is loaded here")
      wake_waiters()
    end
  end
  if vim.in_fast_event() then vim.schedule(start) else start() end
  return true
end

-- cb(ok, status()) on the main loop once the library is loaded (or found
-- missing, turned off, unusable): after the first open warm() starts away
-- from the UI thread, or at once, scheduled, when there is nothing to wait
-- for. Never in a fast event and never before when_ready returns; an error
-- in cb is logged.
function M.when_ready(cb)
  if type(cb) ~= "function" then error("libjupynvim when_ready: cb must be a function", 2) end
  S.waiters = S.waiters or {}
  S.waiters[#S.waiters + 1] = cb
  if S.state == "unloaded" and not S.warm then M.warm() end
  if S.state ~= "unloaded" or not S.warm or S.warm.done then vim.schedule(finish_ready) end
end

-- ── contexts ─────────────────────────────────────────────────────────────

local Ctx = {}
Ctx.__index = Ctx

function Ctx.new(lib, workers)
  local err = ffi.new("jnv_buf*[1]")
  local ptr = lib.jnv_open(workers, err)
  if ptr == nil then
    local msg = "no reason given"
    if err[0] ~= nil then
      msg = ffi.string(err[0].ptr, tonumber(err[0].len))
      lib.jnv_buf_free(err[0])
    end
    return nil, "could not start: " .. msg
  end
  local fd = lib.jnv_wake_fd(ptr)
  if fd < 0 then
    lib.jnv_close(ptr)
    return nil, "could not start: the library gave no wake descriptor"
  end
  local pipe = vim.uv.new_pipe(false)
  local opened, perr = false, "no pipe handle"
  if pipe then opened, perr = pipe:open(fd) end
  if not opened then
    if pipe then pipe:close() end
    vim.uv.fs_close(fd)
    lib.jnv_close(ptr)
    return nil, "could not start: cannot watch the wake descriptor: " .. tostring(perr)
  end
  local self = setmetatable({
    lib = lib,
    ptr = ptr,
    pipe = pipe,
    workers = tonumber(lib.jnv_workers(ptr)),
    closed = false,
    scheduled = false,
    depth = 0,
    pending = {},
    stats = { wakes = 0, pumps = 0, done = 0, nested = 0, max_tick_ns = 0 },
    done_buf = ffi.new("jnv_done[?]", BATCH),
    out1 = ffi.new("jnv_buf*[1]"),
    id1 = ffi.new("uint64_t[1]"),
  }, Ctx)
  -- A fast event: only count the wake and schedule the pump.
  local started, serr = pipe:read_start(function(e, data)
    if e or not data then
      if not pipe:is_closing() then pipe:close() end
      return
    end
    self.stats.wakes = self.stats.wakes + 1
    self:_schedule()
  end)
  if not started then
    self.closed = true
    lib.jnv_close(ptr)
    self.ptr = nil
    if not pipe:is_closing() then pipe:close() end
    return nil, "could not start: cannot watch the wake descriptor: " .. tostring(serr)
  end
  return self
end

function Ctx:_schedule()
  if not self.scheduled then
    self.scheduled = true
    vim.schedule(function() self:_pump() end)
  end
end

-- Hand finished jobs to their callbacks, BATCH at a time, for at most
-- TICK_NS per main loop tick (then the rest waits for the next tick). A
-- callback may run the event loop (vim.wait), which can start a nested pump:
-- that one polls into its own array, so the records the outer pump has not
-- dispatched yet stay intact, and no pump polls once a callback closed the
-- context. Each record is finished under a pcall of its own: an error there
-- (ffi.string failing to allocate) loses that one completion, never the
-- rest of its batch, which the library has already handed over.
function Ctx:_pump()
  self.scheduled = false
  if self.closed then return end
  local t0 = vim.uv.hrtime()
  self.stats.pumps = self.stats.pumps + 1
  -- the outermost pump reuses the preallocated array; a nested one gets its own
  local buf = self.depth == 0 and self.done_buf or ffi.new("jnv_done[?]", BATCH)
  if self.depth > 0 then self.stats.nested = self.stats.nested + 1 end
  self.depth = self.depth + 1
  local ok, err = pcall(function()
    while not self.closed do
      local n = tonumber(self.lib.jnv_poll(self.ptr, buf, BATCH))
      for i = 0, n - 1 do
        local okf, ferr = pcall(self._finish, self, buf[i])
        if not okf then log("error", "libjupynvim pump: " .. tostring(ferr)) end
      end
      if n < BATCH then break end
      if vim.uv.hrtime() - t0 > TICK_NS then self:_schedule(); break end
    end
  end)
  self.depth = self.depth - 1
  if not ok then log("error", "libjupynvim pump: " .. tostring(err)) end
  local dt = vim.uv.hrtime() - t0
  if dt > self.stats.max_tick_ns then self.stats.max_tick_ns = dt end
end

-- One completion. The record's fields are read first: a callback may run a
-- nested pump or close the context.
function Ctx:_finish(rec)
  local job, status, result = rec.job, rec.status, rec.result
  local lib = self.lib
  local id = tonumber(job)
  local buf = result ~= nil and ffi.gc(result, lib.jnv_buf_free) or nil
  local e = self.pending[id]
  self.pending[id] = nil -- releases the input's anchor
  if not e then
    -- closed by an earlier callback (the entry is in the graveyard)
    if buf then
      ffi.gc(buf, nil)
      lib.jnv_buf_free(buf)
    end
    return
  end
  self.stats.done = self.stats.done + 1
  local ok, err
  if status == M.STATUS.OK and e.raw then
    ok, err = xpcall(e.cb, debug.traceback, true, buf)
  else
    local text
    if buf then
      text = ffi.string(buf.ptr, tonumber(buf.len))
      ffi.gc(buf, nil)
      lib.jnv_buf_free(buf)
    end
    if status == M.STATUS.OK then
      ok, err = xpcall(e.cb, debug.traceback, true, text)
    else
      ok, err = xpcall(e.cb, debug.traceback, false, text or status_name(status), status)
    end
  end
  if not ok then log("error", "libjupynvim callback: " .. tostring(err)) end
end

-- Queue a job. data (a string or nil) is read in place by a worker, so it
-- stays anchored here until the job's completion is dispatched; opts.copy
-- makes the library copy it instead. opts.priority: "visible", "normal"
-- (default) or "background". opts.raw: cb gets the result buffer (cdata)
-- and frees it with M.free. cb(true, value) on success, cb(false, message,
-- status) otherwise; it always runs on the main loop, never in a fast
-- event. Returns the job id, or nil, why, status.
function Ctx:submit(kind, data, opts, cb)
  if self.closed then return nil, "closed" end
  opts = opts or {}
  data = data or ""
  if type(data) ~= "string" then error("libjupynvim submit: data must be a string or nil", 2) end
  local prio = M.PRIO[opts.priority or "normal"]
  if not prio then error("libjupynvim submit: unknown priority " .. tostring(opts.priority), 2) end
  local flags = prio + (opts.copy and M.FLAG_COPY or 0)
  local st = self.lib.jnv_submit(self.ptr, kind, flags, data, #data, self.id1)
  if st ~= 0 then return nil, status_name(st), st end
  local id = tonumber(self.id1[0])
  self.pending[id] = { cb = cb or noop, data = (not opts.copy) and data or nil, raw = opts.raw }
  return id
end

function Ctx:cancel(id)
  if self.closed or type(id) ~= "number" then return false end
  return self.lib.jnv_cancel(self.ptr, id) == 0
end

local function call_input(data)
  data = data or ""
  if type(data) ~= "string" then error("libjupynvim call: data must be a string or nil", 3) end
  return data
end

-- Run a job on this thread (bounded work only): ok, value or message, status.
function Ctx:call(kind, data)
  if self.closed then return false, "closed", M.STATUS.ESHUTDOWN end
  data = call_input(data)
  local out = self.out1
  local st = self.lib.jnv_call(self.ptr, kind, data, #data, out)
  local b = out[0]
  local text
  if b ~= nil then
    out[0] = nil
    text = ffi.string(b.ptr, tonumber(b.len))
    self.lib.jnv_buf_free(b)
  end
  if st == 0 then return true, text, st end
  return false, text or status_name(st), st
end

-- As call, but the result buffer itself: status, buf (or nil). The caller
-- frees it with M.free (the garbage collector does otherwise).
function Ctx:call_raw(kind, data)
  if self.closed then return nil, "closed" end
  data = call_input(data)
  local out = self.out1
  local st = self.lib.jnv_call(self.ptr, kind, data, #data, out)
  local b = out[0]
  out[0] = nil
  if b == nil then return st, nil end
  return st, ffi.gc(b, self.lib.jnv_buf_free)
end

function Ctx:pending_count()
  local n = 0
  for _ in pairs(self.pending) do n = n + 1 end
  return n
end

-- Never waits: the library drops queued jobs and tells running ones to stop.
-- A running job may still read its input, so the pending table (with every
-- anchor) moves to the graveyard for the rest of the process.
function Ctx:close()
  if self.closed then return end
  self.closed = true
  self.lib.jnv_close(self.ptr)
  self.ptr = nil
  S.graveyard[#S.graveyard + 1] = self.pending
  self.pending = {}
  -- jnv_close closed the write end under its lock: no wake can follow
  local p = self.pipe
  if p and not p:is_closing() then
    p:read_stop()
    p:close()
  end
end

-- ── the module ───────────────────────────────────────────────────────────

-- msg as a line that fits the message line as the screen is now, so it
-- never stops at the hit-enter prompt, which swallows the key the user
-- types next (a leader Space, so the keys after it run as plain commands).
-- With Neovim's defaults (showcmd, ruler, laststatus 2, cmdheight 1) the
-- room is the width less 12 cells, the showcmd column: 68 at 80 columns.
-- The notices are written to fit 80 columns; a narrower screen gets short
-- instead, cut to the room when even that is too long. Main loop only.
function M._one_line(msg, short)
  local ok, room = pcall(function() return vim.v.echospace end)
  room = ok and tonumber(room) or nil
  if not room or room < 1 or #msg <= room then return msg end
  short = short or msg
  if #short <= room then return short end
  return short:sub(1, room)
end

-- The one notice per process for a library that is there but unusable:
-- one line that names :checkhealth jupynvim (at most 68 characters, see
-- _one_line). The reason and the fix go to the log, and status() and
-- :checkhealth give them in full.
local function notify_once()
  if S.notified then return end
  S.notified = true
  log("warn", ("jupynvim: libjupynvim %s. %s. Everything keeps working without it."):format(
    tostring(S.reason), tostring(S.fix)))
  local what = S.state == "mismatch" and "does not match"
    or tostring(S.reason):find("^could not be loaded") and "could not be loaded"
    or "could not start"
  local msg = ("jupynvim: libjupynvim %s; see :checkhealth jupynvim"):format(what)
  vim.schedule(function()
    vim.notify(M._one_line(msg, "jupynvim: see :checkhealth jupynvim"), vim.log.levels.WARN)
  end)
end

local function hook_leave()
  local function add()
    vim.api.nvim_create_autocmd("VimLeavePre", {
      group = vim.api.nvim_create_augroup("jupynvim_native", { clear = true }),
      callback = function() M.shutdown() end,
    })
  end
  if vim.in_fast_event() then vim.schedule(add) else add() end
end

local function load_now()
  local path, state, reason, source = resolve()
  S.path, S.source = path, source
  if not path then return state, reason end
  -- the probe's Neovim died of it, or its load never returned: mapping it
  -- here would take this one down or never return
  local w = S.warm
  local refused = w and w.path == path and (w.killed or w.late)
  if refused then
    return "error", ("could not be loaded from %s: %s"):format(path, refused)
  end
  local lib, st, why, info = M._open_lib(path, { want = plugin_version(plugin_root()) })
  if info then S.version, S.abi, S.abi_major, S.abi_minor = info.version, info.abi, info.major, info.minor end
  if not lib then return st, why end
  local ctx, err = Ctx.new(lib, workers_of(config().workers))
  if not ctx then return "error", err end
  S.lib, S.ctx, S.workers = lib, ctx, ctx.workers
  return "ok"
end

-- Discover, check and start the library, once per process. Never throws.
function M.load()
  if S.state ~= "unloaded" then return S.state == "ok" end
  local t0 = vim.uv.hrtime()
  S.path, S.source = nil, nil -- this load's, also when it throws
  local ok, state, reason = pcall(load_now)
  if not ok then state, reason = "error", "could not start: " .. tostring(state) end
  S.state, S.reason, S.fix = state, reason, fix_for(state, S.source)
  S.load_ms = (vim.uv.hrtime() - t0) / 1e6
  if state == "ok" then
    local okh, herr = pcall(hook_leave)
    if not okh then log("warn", "libjupynvim: no VimLeavePre hook: " .. tostring(herr)) end
  elseif state == "mismatch" or state == "error" then
    notify_once()
  else
    log("debug", ("libjupynvim %s: %s"):format(state, tostring(reason)))
  end
  return state == "ok"
end

function M.available()
  return M.load() and S.state == "ok"
end

-- For a caller that may wait on the main loop (:checkhealth): available(),
-- with the first open away from this process first, as warm() starts it,
-- waited for up to ms (default: the probe's limit and 2 s). Unlike
-- when_ready it never asks for an install. False, with the state still
-- unloaded, if that first open has not finished by then.
function M._load_waiting(ms)
  if S.state == "unloaded" and M.warm() and S.warm and not S.warm.done then
    vim.wait(ms or (probe_limit() + 2000), function() return S.warm == nil or S.warm.done end, 10)
    if S.warm and not S.warm.done then return false end
  end
  return M.available()
end

-- The advice, at the time it is asked for: while a background install
-- (connect.lua's, which sets _lib_bg_state on the main module) is running
-- or has put a matching library in place, an install is no longer the
-- thing to do.
local function live_fix()
  if S.source ~= "plugin" or not STALE[S.state] then return S.fix end
  local J = package.loaded["jupynvim"]
  local bg = type(J) == "table" and J._lib_bg_state or nil
  if bg == "running" then
    return S.state == "missing" and "A matching libjupynvim is being installed in the background; it loads on its next use"
      or "A matching libjupynvim is being installed in the background; restart Neovim once it is in"
  end
  if bg == "done" and S.state ~= "missing" then return "A matching libjupynvim was installed; restart Neovim to load it" end
  return S.fix
end

-- state: "unloaded", "ok", "disabled", "unsupported", "missing", "mismatch",
-- "error" or "closed"; reason and fix say why and what to do; source is
-- where path came from: "env" (JUPYNVIM_NATIVE), "setup" (native.path) or
-- "plugin" (core/target/release), nil when there is no path.
function M.status()
  return {
    state = S.state, reason = S.reason, fix = live_fix(), path = S.path, source = S.source,
    version = S.version, abi = S.abi, workers = S.workers, load_ms = S.load_ms,
  }
end

local function unavailable()
  return "libjupynvim unavailable: " .. tostring(S.reason or S.state)
end

function M.submit(kind, data, opts, cb)
  if not M.load() then return nil, unavailable() end
  return S.ctx:submit(kind, data, opts, cb)
end

function M.cancel(id)
  if not M.load() then return false, unavailable() end
  return S.ctx:cancel(id)
end

function M.call(kind, data)
  if not M.load() then return false, unavailable() end
  return S.ctx:call(kind, data)
end

function M.call_raw(kind, data)
  if not M.load() then return nil, unavailable() end
  return S.ctx:call_raw(kind, data)
end

-- Free a result buffer (raw callbacks, call_raw).
function M.free(buf)
  if buf == nil then return end
  ffi.gc(buf, nil)
  S.lib.jnv_buf_free(buf)
end

-- Read a result in place: its pointer and length.
function M.view(buf)
  return buf.ptr, tonumber(buf.len)
end

-- Copy a result into a Lua string, then free it.
function M.tostring(buf)
  if buf == nil then return nil end
  local s = ffi.string(buf.ptr, tonumber(buf.len))
  M.free(buf)
  return s
end

-- 4 and 8 byte little-endian encodings (job inputs such as SLEEP and FILL).
function M.u32(n) return ffi.string(ffi.new("uint32_t[1]", n), 4) end
function M.u64(n) return ffi.string(ffi.new("uint64_t[1]", n), 8) end

function M.lib()
  if M.load() then return S.lib end
  return nil
end

-- Does the loaded library offer ABI minor `minor` (of this major)?
function M.has_abi(minor)
  if not M.load() then return false end
  return S.abi_major == M.ABI_MAJOR and S.abi_minor >= minor
end

-- VimLeavePre: close the default context. Worker threads are never joined,
-- so Neovim exits at once whatever still runs.
function M.shutdown()
  if S.ctx then S.ctx:close() end
  if S.state == "ok" then
    S.state = "closed"
    S.reason = "closed when Neovim exited"
  end
end

-- A private context with its own worker pool (tests).
function M._new_context(opts)
  if not M.load() then return nil, unavailable() end
  return Ctx.new(S.lib, workers_of((opts or {}).workers))
end

-- After an install: a missing library is looked for again on next use, and
-- its first open happens away from the UI thread again.
function M._forget_missing()
  if S.state == "missing" then
    S.state, S.reason, S.fix, S.load_ms = "unloaded", nil, nil, nil
    S.warm = nil
  end
end

return M

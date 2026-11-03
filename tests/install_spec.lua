-- Installing the backend binary without lazy.nvim (#33).
--
-- Only lazy's build hook ever installed jupynvim-core. With vim.pack nothing
-- did, and opening a notebook died with "spawn failed: ENOENT". The one
-- manual route broke in v0.4.3 as well: install.lua became a shim that
-- require()d the real module, and vim.pack runs its install hook before the
-- plugin is on 'runtimepath', so the hook failed with "module not found".
--
-- Nothing here touches the network: the download is stubbed, and the
-- "binaries" are shell scripts that answer --version.

local fails = 0
-- A FAIL line starts on a line of its own: a notice Neovim prints here
-- (headless, the real vim.notify) ends without a newline, and run_all.sh's
-- spec_out shows the lines that start with FAIL.
local function chk(name, cond, detail)
  if cond then io.write("  ok " .. name .. "\n")
  else io.write("\nFAIL " .. name .. (detail and ("  -- " .. detail) or "") .. "\n"); fails = fails + 1 end
end

local REPO = vim.fn.getcwd()
local tmp = vim.fn.tempname()
-- where vim.pack puts a plugin: stdpath("data")/site/pack/core/opt/<name>
local PACK = tmp .. "/site/pack/core/opt/jupynvim"
vim.fn.mkdir(PACK .. "/core", "p")
vim.fn.system({ "cp", "-R", REPO .. "/lua", PACK .. "/lua" })
vim.fn.system({ "cp", REPO .. "/core/Cargo.toml", PACK .. "/core/Cargo.toml" })

local function manifest_version(dir)
  for line in io.lines(dir .. "/core/Cargo.toml") do
    local v = line:match('^version%s*=%s*"([^"]+)"')
    if v then return v end
  end
end
local VERSION = manifest_version(REPO)

-- No jupynvim-core from the host's PATH, and a state dir of our own, so the
-- checks below see only what they set up.
local BIN = tmp .. "/bin"
vim.fn.mkdir(BIN, "p")
vim.env.PATH = BIN .. ":/usr/bin:/bin:/usr/sbin:/sbin"
local real_stdpath = vim.fn.stdpath
---@diagnostic disable-next-line: duplicate-set-field
vim.fn.stdpath = function(what)
  if what == "state" then return tmp .. "/state" end
  return real_stdpath(what)
end

-- Every download a case does not stub goes to a release of our own that
-- does not exist, so no case can reach the network, even by mistake.
local NO_RELEASE = "file://" .. tmp .. "/no-release"
vim.env.JUPYNVIM_RELEASE_BASE = NO_RELEASE

-- The in-process library (libjupynvim): the prebuilt each machine gets, as
-- the release workflow publishes them, and the files cargo built here.
local LIB_EXPECT = {
  { "Darwin", "arm64",   "aarch64-apple-darwin",      "dylib" },
  { "Darwin", "x86_64",  "x86_64-apple-darwin",       "dylib" },
  { "Linux",  "x86_64",  "x86_64-unknown-linux-gnu",  "so" },
  { "Linux",  "aarch64", "aarch64-unknown-linux-gnu", "so" },
  { "Linux",  "arm64",   "aarch64-unknown-linux-gnu", "so" },
}
local LIB_ALL = {}   -- the four published assets
for i = 1, 4 do LIB_ALL[i] = { target = LIB_EXPECT[i][3], ext = LIB_EXPECT[i][4] } end
local HOST_LT
do
  local u = vim.uv.os_uname()
  for _, e in ipairs(LIB_EXPECT) do
    if e[1] == u.sysname and e[2] == u.machine then HOST_LT = { target = e[3], ext = e[4] } end
  end
end
local HOST_EXT = vim.uv.os_uname().sysname == "Darwin" and "dylib" or "so"
local REAL_LIB = REPO .. "/core/target/release/libjupynvim." .. HOST_EXT
local FAKE_LIB = REPO .. "/core/target/release/examples/libjnv_fake." .. HOST_EXT
local LIBF = PACK .. "/core/target/release/libjupynvim." .. HOST_EXT
local LSTAMP = PACK .. "/core/target/release/.libjupynvim-installed"
local FAILED_JSON = tmp .. "/state/jupynvim/prebuilt_failed.json"
local TAG = "v" .. VERSION

local function read_file(p)
  local f = io.open(p, "rb")
  if not f then return nil end
  local s = f:read("*a"); f:close()
  return s
end
local function write_file(p, s)
  vim.fn.mkdir(vim.fn.fnamemodify(p, ":h"), "p")
  local f = assert(io.open(p, "wb")); f:write(s); f:close()
end
local function exists(p) return vim.uv.fs_stat(p) ~= nil end
local function same_file(a, b)
  local x, y = read_file(a), read_file(b)
  return x ~= nil and x == y
end
local function sha256(p) return vim.fn.system({ "shasum", "-a", "256", p }):match("^(%x+)") end
-- The installer's stamp for the library: its version, then the file's
-- size:mtime.sec:mtime.nsec, so a file put there later no longer matches.
local function write_lib_stamp(version)
  local st = vim.uv.fs_stat(LIBF)
  write_file(LSTAMP, version .. "\n" .. ("%d:%d:%d"):format(st.size, st.mtime.sec, st.mtime.nsec) .. "\n")
end
-- A case whose code throws (a function the installer does not have) is a
-- failure, and the cases after it still run.
local function case(name, fn)
  local ok, err = pcall(fn)
  if not ok then chk(name, false, tostring(err)) end
end

-- A binary that downloads and verifies but cannot run here, the way a build
-- against a newer glibc fails on an older distro.
local function broken_binary(path)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = io.open(path, "w")
  f:write("#!/bin/sh\necho \"version 'GLIBC_2.39' not found\" >&2\nexit 1\n")
  f:close()
  vim.fn.setfperm(path, "rwxr-xr-x")
end

-- A PATH with the tools the stub and the installer run here (cp, chmod
-- and, on macOS, xattr; the fake binaries are #!/bin/sh scripts that use
-- only builtins), and neither shasum nor sha256sum.
local NOTOOL = tmp .. "/notool"
vim.fn.mkdir(NOTOOL, "p")
for _, tool in ipairs({ "cp", "chmod", "xattr" }) do
  local at = vim.fn.exepath(tool)
  if at ~= "" then vim.uv.fs_symlink(at, NOTOOL .. "/" .. tool) end
end
local function without_hash_tools(fn)
  local prev = vim.env.PATH
  vim.env.PATH = NOTOOL
  local ok, a, b, c = pcall(fn)
  vim.env.PATH = prev
  if not ok then error(a, 0) end
  return a, b, c
end

local function fake_binary(path, version)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = io.open(path, "w")
  f:write("#!/bin/sh\necho 'jupynvim-core " .. version .. "'\n")
  f:close()
  vim.fn.setfperm(path, "rwxr-xr-x")
end

-- ── the hook vim.pack runs, before the plugin is on 'runtimepath' ────────
local ok, Install = pcall(dofile, PACK .. "/lua/jupynvim/install.lua")
chk("install.lua loads by path with the plugin not on 'runtimepath'",
    ok and type(Install) == "table" and type(Install.run) == "function", tostring(Install))
if not ok then Install = dofile(REPO .. "/lua/jupynvim/backend/install.lua") end
-- The real download, before any case stubs it: only the case that serves a
-- release from disk with the real curl uses it.
local REAL_CURL = Install._curl

-- ── where it installs ────────────────────────────────────────────────────
if Install._resolve_dir then
  chk("run() takes lazy's plugin spec", Install._resolve_dir({ dir = "/x" }) == "/x")
  chk("run() takes vim.pack and mini.deps data", Install._resolve_dir({ path = "/y" }) == "/y")
  chk("run() takes a plain path", Install._resolve_dir("/z") == "/z")
  chk("run() with nothing installs next to itself, not into lazy's directory",
      vim.fn.resolve(Install._resolve_dir() or "") == vim.fn.resolve(PACK),
      tostring(Install._resolve_dir()))
else
  chk("run() accepts vim.pack's { path }", false, "no _resolve_dir")
end

-- A copy inside some other git repository must not borrow that repo's tag.
vim.fn.system({ "git", "-C", tmp, "init", "-q" })
vim.fn.system({ "git", "-C", tmp, "-c", "user.email=t@t", "-c", "user.name=t",
                "commit", "-q", "--allow-empty", "-m", "dotfiles" })
vim.fn.system({ "git", "-C", tmp, "tag", "v9.9" })
chk("the release tag comes from the plugin's own version",
    Install._detect_tag(PACK) == "v" .. VERSION, tostring(Install._detect_tag(PACK)))

-- ── run(): the download, stubbed ─────────────────────────────────────────
local target = Install._detect_target()
local final = PACK .. "/core/target/release/jupynvim-core"
local downloads, last_out, fetched = 0, nil, {}
-- The library's downloads are counted apart, so every count above keeps its
-- meaning; all_urls is every URL a run asked for, in order.
local lib_downloads, last_lib_out, lib_fetched, all_urls = 0, nil, {}, {}
-- every argv the stub was handed, for the check that each one limits curl
-- to https and file
local all_argv = {}
-- The installer modules the stub stands in for. The locate_core section
-- adds the one connect.lua requires.
local STUBS = { Install }
-- A release that serves opts.served for every asset, or opts.served[target]
-- per asset. opts.fail, or opts.fail[target], is what curl prints when the
-- download fails. Its SHA256SUMS lists every asset it serves, the way the
-- release workflow writes it, so a machine with two targets verifies both.
-- opts.vanish reports a download that left no file behind.
-- The library: opts.lib (a path, or a path per target) is served as
-- libjupynvim-<target>.<ext>; opts.lib_fail is what curl prints instead
-- (true: a 404); opts.lib_bad_hash lists it with a wrong hash and
-- opts.lib_unlisted not at all. A release without opts.lib does not publish
-- the library (404), so a case that predates it keeps its result.
-- SHA256SUMS: opts.sums_text is served as it is; opts.sums = false answers
-- a 404 (a release that publishes none); opts.sums_fail is what curl
-- prints when fetching it fails some other way (the network).
local function stub_release(opts)
  local function pick(v, t) if type(v) == "table" then return v[t] end return v end
  local function curl(args)
    local url = args[#args]
    all_urls[#all_urls + 1] = url
    all_argv[#all_argv + 1] = args
    if url:find("SHA256SUMS", 1, true) then
      if opts.sums_text then return opts.sums_text, true end
      if opts.sums_fail then return opts.sums_fail, false end
      if opts.sums == false then return "curl: (22) The requested URL returned error: 404", false end
      local lines = {}
      for t in pairs(Install._published) do
        local served = pick(opts.served, t)
        if served then
          local hash = opts.bad_hash and string.rep("0", 64)
            or vim.fn.system({ "shasum", "-a", "256", served }):match("^(%x+)")
          lines[#lines + 1] = hash .. "  jupynvim-core-" .. t
        end
      end
      if opts.lib and not opts.lib_unlisted then
        for _, lt in ipairs(LIB_ALL) do
          local served = pick(opts.lib, lt.target)
          if served then
            local hash = opts.lib_bad_hash and string.rep("0", 64) or sha256(served)
            lines[#lines + 1] = hash .. "  libjupynvim-" .. lt.target .. "." .. lt.ext
          end
        end
      end
      return table.concat(lines, "\n") .. "\n", true
    end
    local lt = url:match("libjupynvim%-([%w_%-]+)%.(%a+)$")
    if lt then
      lib_downloads = lib_downloads + 1
      lib_fetched[#lib_fetched + 1] = lt
      local served, fail = pick(opts.lib, lt), pick(opts.lib_fail, lt)
      if fail or not served then
        return type(fail) == "string" and fail or "curl: (22) The requested URL returned error: 404", false
      end
      local out
      for i, a in ipairs(args) do if a == "-o" then out = args[i + 1] end end
      last_lib_out = out
      vim.fn.system({ "cp", served, out })
      return "", true
    end
    downloads = downloads + 1
    local t = url:match("jupynvim%-core%-([%w_%-]+)$")
    fetched[#fetched + 1] = t
    local fail = pick(opts.fail, t)
    if fail then return fail == true and "curl: (22) The requested URL returned error: 404" or fail, false end
    local out
    for i, a in ipairs(args) do if a == "-o" then out = args[i + 1] end end
    last_out = out
    if not opts.vanish then vim.fn.system({ "cp", pick(opts.served, t), out }) end
    return "", true
  end
  for _, m in ipairs(STUBS) do m._curl = curl end
end

if target then
  local served = tmp .. "/served-binary"
  fake_binary(served, VERSION)

  stub_release({ served = served })
  local rok, rerr = pcall(Install.run, { path = PACK })
  chk("a verified download is installed", rok and vim.fn.executable(final) == 1, tostring(rerr))
  chk("no partial download is left behind", #vim.fn.glob(final .. ".download*", false, true) == 0)
  chk("each download gets a name of its own, so two installs cannot clobber it",
      last_out ~= nil and last_out:find(".download." .. vim.fn.getpid(), 1, true) ~= nil, tostring(last_out))

  -- a bad release must leave the working binary alone
  local before = io.open(final):read("*a")
  stub_release({ served = served, bad_hash = true })
  pcall(Install.run, { path = PACK }, { no_cargo = true })
  chk("a checksum mismatch leaves the installed binary untouched",
      io.open(final):read("*a") == before and #vim.fn.glob(final .. ".download*", false, true) == 0)

  -- verifies, but does not run here: never renamed in, and remembered
  os.remove(final)
  local glibc = tmp .. "/served-glibc"
  broken_binary(glibc)
  stub_release({ served = glibc })
  downloads = 0
  local gok, gerr = pcall(Install.run, { path = PACK }, { no_cargo = true })
  chk("a prebuilt that does not run here is not installed", not gok and vim.fn.filereadable(final) == 0,
      tostring(gerr))
  chk("and the error says why", tostring(gerr):find("does not run here", 1, true) ~= nil
      and tostring(gerr):find("GLIBC", 1, true) ~= nil, tostring(gerr))
  local first = downloads
  pcall(Install.run, { path = PACK }, { no_cargo = true })
  chk("the next first-use install does not fetch it again", downloads == first,
      (downloads - first) .. " more downloads")
  pcall(Install.run, { path = PACK }, { no_cargo = true, force = true })
  chk(":JupynvimInstall tries it again", downloads > first)
  downloads = 0
  pcall(Install.run, { dir = PACK })
  chk("so does a build hook", downloads > 0, downloads .. " downloads")

  -- one that runs clears the entry, so a later first-use install fetches it
  stub_release({ served = served })
  local cok, cerr = pcall(Install.run, { path = PACK }, { force = true })
  chk("a prebuilt that runs clears its entry", cok and Install.known_bad("v" .. VERSION, target) == nil,
      tostring(cerr) .. " / " .. tostring(Install.known_bad("v" .. VERSION, target)))
  os.remove(final)
  downloads = 0
  pcall(Install.run, { path = PACK }, { no_cargo = true })
  chk("and the install on first use fetches it again", downloads == 1 and vim.fn.executable(final) == 1,
      downloads .. " downloads")

  -- slow to answer, the way a first exec behind a virus scanner can be: not
  -- installed this time, but not remembered as a prebuilt that does not run
  os.remove(final)
  local slow = tmp .. "/served-slow"
  local sf = io.open(slow, "w")
  sf:write("#!/bin/sh\nexec sleep 30\n")
  sf:close()
  vim.fn.setfperm(slow, "rwxr-xr-x")
  stub_release({ served = slow })
  local sok, serr = pcall(Install.run, { path = PACK }, { no_cargo = true })
  chk("a prebuilt that does not answer in time is not installed",
      not sok and vim.fn.filereadable(final) == 0, tostring(serr))
  chk("and is not remembered as one that does not run here",
      Install.known_bad("v" .. VERSION, target) == nil, tostring(Install.known_bad("v" .. VERSION, target)))
  stub_release({ served = served })
  downloads = 0
  pcall(Install.run, { path = PACK }, { no_cargo = true })
  chk("so the next first-use install fetches it", downloads == 1 and vim.fn.executable(final) == 1,
      downloads .. " downloads")

  -- curl said it downloaded, but there is no file to check
  os.remove(final)
  stub_release({ served = served, vanish = true })
  local vok, verr = pcall(Install.run, { path = PACK }, { no_cargo = true })
  chk("a download that left no file fails its checksum", not vok and vim.fn.filereadable(final) == 0
      and tostring(verr):find("download is gone", 1, true) ~= nil, tostring(verr))

  os.remove(tmp .. "/state/jupynvim/prebuilt_failed.json")   -- a real download failure, not a skip
  stub_release({ served = served, fail = true })
  local fok, ferr = pcall(Install.run, { path = PACK }, { no_cargo = true })
  chk("a failed download with no_cargo says how to fix it, without building",
      not fok and tostring(ferr):find(":JupynvimInstall", 1, true) ~= nil, tostring(ferr))
  os.remove(final)
else
  io.write("  skip run(): no prebuilt target for this machine\n")
end

-- ── Linux: the glibc asset only when the musl one is not published ──────
-- Linux tries the static musl asset, then the glibc name that releases
-- before it have. Only a 404 says the second one might be there. Offline,
-- or behind a firewall that drops packets, every asset fails the same way,
-- and trying the second one doubled the freeze on the first open, 46s to
-- 92s. A musl asset that is published but will not run has the same bytes
-- under the glibc name, so that one fails too. The host here may be a Mac,
-- so pretend to be Linux; the fake binaries are shell scripts and run on
-- either.
do
  local real_uname = vim.uv.os_uname
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.uv.os_uname = function()
    local u = real_uname(); u.sysname, u.machine = "Linux", "x86_64"; return u
  end
  local MUSL, GNU = "x86_64-unknown-linux-musl", "x86_64-unknown-linux-gnu"
  local FAILED = tmp .. "/state/jupynvim/prebuilt_failed.json"
  local good, bad = tmp .. "/served-linux", tmp .. "/served-linux-broken"
  fake_binary(good, VERSION)
  broken_binary(bad)
  local function attempt(opts)
    os.remove(final)
    os.remove(FAILED)
    downloads, fetched = 0, {}
    stub_release(opts)
    return pcall(Install.run, { path = PACK }, { no_cargo = true })
  end
  local function times(str, pat) local n = 0; for _ in str:gmatch(pat) do n = n + 1 end; return n end

  chk("Linux tries musl, then the glibc name", vim.deep_equal(Install._detect_targets(), { MUSL, GNU }))

  local rok, rerr = attempt({ served = good })
  chk("a musl build that runs is installed, and the glibc one never fetched",
      rok and vim.fn.executable(final) == 1 and vim.deep_equal(fetched, { MUSL }), table.concat(fetched, ","))

  -- curl --retry 3 prints the same error once per attempt
  local timeout = string.rep("curl: (28) Failed to connect to github.com port 443 after 10002 ms: " ..
    "Timeout was reached\n", 4)
  rok, rerr = attempt({ served = good, fail = timeout })
  chk("a blackholed GitHub is not tried again for the glibc asset",
      not rok and vim.deep_equal(fetched, { MUSL }), table.concat(fetched, ", "))
  chk("and the error quotes curl once, not once per retry",
      times(tostring(rerr), "curl: %(28%)") == 1, tostring(rerr))

  attempt({ served = good, fail = string.rep("curl: (6) Could not resolve host: github.com\n", 4) })
  chk("offline, the glibc asset is not tried either", vim.deep_equal(fetched, { MUSL }),
      table.concat(fetched, ", "))

  -- a release from before the musl build. curl 8 over HTTP/2 exits 56 on a
  -- 404, not 22, so the message is what tells it apart.
  for _, gone in ipairs({ "curl: (56) The requested URL returned error: 404",
                          "curl: (22) The requested URL returned error: 404 Not Found" }) do
    rok, rerr = attempt({ served = good, fail = { [MUSL] = gone } })
    chk("a release without the musl asset installs the glibc one " .. gone:match("%(%d+%)"),
        rok and vim.deep_equal(fetched, { MUSL, GNU }) and vim.fn.executable(final) == 1,
        tostring(rerr) .. " / " .. table.concat(fetched, ", "))
  end
  chk("and a missing asset is not remembered as one that does not run",
      not Install.known_bad("v" .. VERSION, MUSL))

  attempt({ served = bad })
  chk("a musl asset that does not run is not fetched again as the glibc copy",
      vim.deep_equal(fetched, { MUSL }), table.concat(fetched, ", "))
  downloads, fetched = 0, {}
  pcall(Install.run, { path = PACK }, { no_cargo = true })
  chk("nor on the next first open", #fetched == 0, table.concat(fetched, ", "))

  os.remove(final)
  os.remove(FAILED)
  vim.uv.os_uname = real_uname
end

-- ── a cargo build the installer made is not one of your own ─────────────
-- :JupynvimInstall builds with cargo where no prebuilt runs. That left the
-- same metadata as a build of your own, so later updates never fetched the
-- release that did run, and warned on every start instead.
do
  local rel = PACK .. "/core/target/release"
  local cargo = BIN .. "/cargo"
  local f = io.open(cargo, "w")
  f:write("#!/bin/sh\nmkdir -p '" .. rel .. "/.fingerprint'\n" ..
          "printf '#!/bin/sh\\necho jupynvim-core " .. VERSION .. "\\n' > '" .. rel .. "/jupynvim-core'\n" ..
          "chmod +x '" .. rel .. "/jupynvim-core'\n")
  f:close()
  vim.fn.setfperm(cargo, "rwxr-xr-x")
  local real_uname = vim.uv.os_uname
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.uv.os_uname = function() local u = real_uname(); u.sysname, u.machine = "Plan9", "mips"; return u end
  local bok, berr = pcall(Install.run, { path = PACK }, { force = true })
  vim.uv.os_uname = real_uname
  chk("with no prebuilt the installer builds with cargo (precondition)", bok ~= nil
      and vim.fn.isdirectory(rel .. "/.fingerprint") == 1, tostring(berr))
  chk("and that build is not taken for one of your own", not Install.is_dev_build(PACK))
  vim.wait(1100)   -- a rebuild of your own has a new mtime
  fake_binary(final, VERSION)
  chk("a build of your own after it is", Install.is_dev_build(PACK))
  os.remove(cargo)
  vim.fn.delete(rel, "rf")
end

-- ── the in-process library (libjupynvim) ────────────────────────────────
-- The installer fetches libjupynvim with the core: the same release, the
-- same SHA256SUMS, then a check in a Neovim of its own that it loads here
-- and is this plugin's version, and only then the rename into place. The
-- library served here is the real one cargo built, and the probe really
-- loads it; the fake library answers a wrong ABI or version (JNV_FAKE, which
-- the probe inherits).
local BUILD_HINT = "build them first: cd core && cargo build --release && cargo build --release --examples"
chk("the real library is built (" .. REAL_LIB .. ")", exists(REAL_LIB), BUILD_HINT)
chk("the fake library is built (" .. FAKE_LIB .. ")", exists(FAKE_LIB), BUILD_HINT)
chk("the installer has the library functions",
    type(Install._lib_target) == "function" and type(Install.run_lib) == "function"
    and type(Install.run_lib_background) == "function", "no Install._lib_target, run_lib or run_lib_background")

local real_uname0 = vim.uv.os_uname
local function as_uname(sys, mach, fn)
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.uv.os_uname = function() local u = real_uname0(); u.sysname, u.machine = sys, mach; return u end
  local ok, a, b = pcall(fn)
  vim.uv.os_uname = real_uname0
  if not ok then error(a, 0) end
  return a, b
end

case("the library prebuilt each platform gets", function()
  for _, e in ipairs(LIB_EXPECT) do
    local t, name = as_uname(e[1], e[2], function() return Install._lib_target(), Install.lib_name() end)
    chk(("%s %s gets the %s library prebuilt"):format(e[1], e[2], e[3]),
        type(t) == "table" and t.target == e[3] and t.ext == e[4], vim.inspect(t))
    chk(("and names it libjupynvim.%s (%s %s)"):format(e[4], e[1], e[2]), name == "libjupynvim." .. e[4], tostring(name))
  end
  local none = as_uname("Plan9", "mips", function() return Install._lib_target() end)
  chk("Plan9 mips gets no library prebuilt", none == nil, vim.inspect(none))
  local all = {}
  for _, t in ipairs(Install._lib_targets_all()) do all[#all + 1] = t.target .. "." .. t.ext end
  chk("the release publishes four library prebuilts", vim.deep_equal(all, {
    "aarch64-apple-darwin.dylib", "x86_64-apple-darwin.dylib",
    "x86_64-unknown-linux-gnu.so", "aarch64-unknown-linux-gnu.so" }), table.concat(all, ", "))
  chk("each as libjupynvim-<target>.<ext>",
      Install._lib_asset({ target = "x86_64-unknown-linux-gnu", ext = "so" }) == "libjupynvim-x86_64-unknown-linux-gnu.so")
  chk("the library is installed next to jupynvim-core", Install.lib_path(PACK) == LIBF, tostring(Install.lib_path(PACK)))
end)

-- ── the release workflow publishes what the installer fetches ──────────
-- The installer asks the release for libjupynvim-<target>.<ext> and wants it
-- listed in SHA256SUMS. A workflow that names one differently, or leaves it
-- out of SHA256SUMS, or publishes a library its checks never saw, ships a
-- release every install of that platform refuses or cannot find.
case("the release workflow publishes every library the installer fetches", function()
  local path = REPO .. "/.github/workflows/release.yml"
  local text = read_file(path)
  chk("the release workflow is there (" .. path .. ")", text ~= nil)
  if not text then return end
  local lines = vim.split(text, "\n", { plain = true })
  -- One job: from its "  <name>:" line to the next job's.
  local function job(name)
    local out, inside = {}, false
    for _, l in ipairs(lines) do
      if l:match("^  [%w_%-]+:%s*$") then inside = (l == "  " .. name .. ":") end
      if inside then out[#out + 1] = l end
    end
    return out
  end
  local function value(s)
    s = s:gsub("%s+#.*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
    return (s:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1"))
  end
  -- The rows of a job's matrix include list, each a table of its keys.
  local function matrix_rows(jl)
    local rows, row, at, seen = {}, nil, nil, false
    for _, l in ipairs(jl) do
      if l:match("^%s*include:%s*$") then seen = true
      elseif seen then
        local ind, k, v = l:match("^(%s*)%- ([%w_]+):(.*)$")
        if ind then
          row = { [k] = value(v) }; rows[#rows + 1] = row; at = #ind + 2
        elseif l:match("^%s*steps:%s*$") then break
        elseif row then
          local ind2, k2, v2 = l:match("^(%s*)([%w_]+):(.*)$")
          if ind2 and #ind2 == at then row[k2] = value(v2) end
        end
      end
    end
    return rows
  end
  -- A line that is a comment (YAML or shell) does not count: a check that
  -- is commented out is a check that no longer runs.
  local function has(jl, needle)
    for _, l in ipairs(jl) do
      if not l:match("^%s*#") and l:find(needle, 1, true) then return l end
    end
  end
  local function count(jl, pat)
    local n = 0
    for _, l in ipairs(jl) do if not l:match("^%s*#") and l:match(pat) then n = n + 1 end end
    return n
  end

  local lib = job("build-lib")
  chk("release.yml has a build-lib job", #lib > 0)
  local rows = matrix_rows(lib)
  local want, got = {}, {}
  for _, t in ipairs(Install._lib_targets_all()) do want[#want + 1] = t.target .. "." .. t.ext end
  for _, r in ipairs(rows) do got[#got + 1] = tostring(r.target) .. "." .. tostring(r.ext) end
  table.sort(want); table.sort(got)
  for _, w in ipairs(want) do
    chk("build-lib has a matrix row for " .. w, vim.tbl_contains(got, w), table.concat(got, ", "))
  end
  chk("and builds no library the installer never fetches", vim.deep_equal(want, got),
      "workflow " .. table.concat(got, ", ") .. "; installer " .. table.concat(want, ", "))
  local stage = 'out="dist/libjupynvim-${{ matrix.target }}.${{ matrix.ext }}"'
  chk("build-lib stages each library as libjupynvim-<target>.<ext>", has(lib, stage) ~= nil, stage)
  chk("and checks that file with native_artifact.py",
      has(lib, 'native_artifact.py "$out" --target ${{ matrix.target }}') ~= nil)
  chk("and loads that file with abi_check, against the plugin's version",
      has(lib, '"$RUNNER_TEMP/abi_check" "$out" "$version"') ~= nil)
  -- The installer wants the library to report the first version line of
  -- core/Cargo.toml (detect_tag is "v" .. that), so the check must too.
  chk("the version abi_check gets is read from core/Cargo.toml",
      has(lib, "version=$(sed -n 's/^version *= *\"\\([^\"]*\\)\".*/\\1/p' core/Cargo.toml | head -n 1)") ~= nil)
  chk("and never from the tag", not has(lib, "GITHUB_REF") and not has(lib, "github.ref"))
  chk("and set only there", count(lib, "^%s*version=") == 1, tostring(count(lib, "^%s*version=")))
  chk("build-lib uploads the staged libraries", has(lib, "path: dist/libjupynvim-*") ~= nil)
  local glibc_rows = 0
  for _, r in ipairs(rows) do
    if r.ext == "so" then
      glibc_rows = glibc_rows + 1
      chk("the " .. tostring(r.target) .. " library needs at most glibc 2.17", r.glibc == "2.17", tostring(r.glibc))
    end
  end
  chk("and native_artifact.py checks that limit",
      glibc_rows > 0 and has(lib, "${glibc:+--max-glibc $glibc}") ~= nil
      and has(lib, [[glibc="${{ matrix.glibc }}"]]) ~= nil)

  local build = job("build")
  chk("the core build builds the jupynvim-core package only",
      has(build, "cargo build --release -p jupynvim-core --target ${{ matrix.target }}") ~= nil,
      tostring(has(build, "run: cargo")))
  local rel = job("release")
  local needs = has(rel, "needs:") or ""
  chk("the release waits for the library builds", needs:find("build-lib", 1, true) ~= nil, needs)
  chk("and for the core builds", needs:match("[%[%s,]build[%],%s]") ~= nil or needs:match("needs:%s*build%s*$") ~= nil, needs)
  local sums = has(rel, "> SHA256SUMS") or ""
  chk("SHA256SUMS lists the libraries", sums:find("libjupynvim-*", 1, true) ~= nil, sums)
  chk("and the core binaries", sums:find("jupynvim-core-*", 1, true) ~= nil, sums)
  chk("the release publishes every file it summed", has(rel, "files: artifacts/*") ~= nil,
      tostring(has(rel, "files:")))
end)

case("JUPYNVIM_RELEASE_BASE", function()
  local gh = "https://github.com/sheng-tse/jupynvim/releases/download"
  vim.env.JUPYNVIM_RELEASE_BASE = nil
  local base0, url0 = Install._release_base(), Install._url_for("v1.2.3", "x86_64-unknown-linux-musl")
  vim.env.JUPYNVIM_RELEASE_BASE = "https://mirror.example/jnv//"
  local base1 = Install._release_base()
  vim.env.JUPYNVIM_RELEASE_BASE = NO_RELEASE
  chk("downloads come from the GitHub release by default", base0 == gh, tostring(base0))
  chk("and an asset's URL is under it", url0 == gh .. "/v1.2.3/jupynvim-core-x86_64-unknown-linux-musl", tostring(url0))
  chk("JUPYNVIM_RELEASE_BASE replaces it, trailing slashes dropped", base1 == "https://mirror.example/jnv", tostring(base1))
end)

-- Over plain http (or any other scheme curl knows) anyone on the path can
-- replace an asset and SHA256SUMS alike, so the check proves nothing: only
-- https:// and file:// bases are used, and nothing is downloaded otherwise.
case("a release base that is not https:// or file://", function()
  local function scheme_ok(base)
    vim.env.JUPYNVIM_RELEASE_BASE = base
    local b, why = Install._release_base_ok()
    vim.env.JUPYNVIM_RELEASE_BASE = NO_RELEASE
    return b, why
  end
  local why = "JUPYNVIM_RELEASE_BASE must start with https:// or file://"
  chk("https:// and file:// bases are taken, also in capitals", scheme_ok("https://mirror.example/jnv") ~= nil
      and scheme_ok("file:///srv/jnv") ~= nil and scheme_ok("HTTPS://mirror.example") ~= nil)
  for _, base in ipairs({ "http://127.0.0.1:9", "ftp://mirror.example/jnv", "mirror.example/jnv" }) do
    local b, w = scheme_ok(base)
    chk(base .. " is refused, and says why", b == nil and w == why, tostring(w))
  end
end)

if target and HOST_LT then
  local served_lc = tmp .. "/served-core-for-lib"
  fake_binary(served_lc, VERSION)
  local garbage = tmp .. "/garbage-lib"
  write_file(garbage, "this is not a library\n")
  local function lib_reset()
    os.remove(LIBF); os.remove(LSTAMP); os.remove(FAILED_JSON)
    vim.fn.delete(PACK .. "/core/target/release/.fingerprint", "rf")
    os.remove(PACK .. "/core/target/release/.jupynvim-installed")
    downloads, lib_downloads, lib_fetched, last_lib_out, all_urls = 0, 0, {}, nil, {}
  end
  -- no download and no half-written stamp left beside the library
  local function no_partial()
    return #vim.fn.glob(LIBF .. ".download*", false, true) == 0 and #vim.fn.glob(LSTAMP .. ".*", false, true) == 0
  end
  local function capture(fn)
    local notes, real = {}, vim.notify
    vim.notify = function(m, lvl) notes[#notes + 1] = { tostring(m), lvl } end
    local ok, a, b = pcall(fn)
    vim.notify = real
    return notes, ok, a, b
  end
  local function noted(notes, lvl, needle)
    for _, n in ipairs(notes) do
      if n[2] == lvl and n[1]:find(needle, 1, true) then return true end
    end
    return false
  end
  local function lib_bad() return Install.known_bad(TAG, "lib-" .. HOST_LT.target) end
  -- A probe that could not run never checked the library: run_lib's reason
  -- and its notice say it could not be checked here (want, the start of the
  -- reason after that), and nothing says it does not load here.
  local function unchecked(notes, why, want)
    local all = { tostring(why) }
    for _, n in ipairs(notes) do all[#all + 1] = n[1] end
    local head = "could not be checked here: " .. want
    return tostring(why):sub(1, #head) == head
      and noted(notes, vim.log.levels.WARN, "libjupynvim not installed (" .. head)
      and not table.concat(all, "\n"):find("does not load here", 1, true)
  end

  case("a release with the library", function()
    lib_reset(); os.remove(final)
    vim.env.JUPYNVIM_RELEASE_BASE = "https://mirror.example/jnv/"
    stub_release({ served = served_lc, lib = REAL_LIB })
    local ok, res = pcall(Install.run, { path = PACK })
    vim.env.JUPYNVIM_RELEASE_BASE = NO_RELEASE
    chk("a release with the library installs the core and the library",
        ok and res == true and vim.fn.executable(final) == 1 and same_file(LIBF, REAL_LIB) and lib_downloads == 1,
        ("ok=%s res=%s lib downloads=%d"):format(tostring(ok), tostring(res), lib_downloads))
    local st = read_file(LSTAMP) or ""
    local s = vim.uv.fs_stat(LIBF) or { size = -1, mtime = { sec = -1, nsec = -1 } }
    chk("its stamp holds the version and the file's size and mtime",
        st == VERSION .. "\n" .. ("%d:%d:%d"):format(s.size, s.mtime.sec, s.mtime.nsec) .. "\n", st)
    chk("lib_installed_version reads it", Install.lib_installed_version(PACK) == VERSION,
        tostring(Install.lib_installed_version(PACK)))
    chk("no partial library download is left behind", no_partial())
    chk("the library download gets a name of its own",
        last_lib_out == LIBF .. ".download." .. vim.fn.getpid(), tostring(last_lib_out))
    local off, libs = {}, 0
    for _, u in ipairs(all_urls) do
      if not u:find("^https://mirror%.example/jnv/" .. vim.pesc(TAG) .. "/") then off[#off + 1] = u end
      if u:find("libjupynvim-", 1, true) then libs = libs + 1 end
    end
    chk("every download goes to JUPYNVIM_RELEASE_BASE: the core, SHA256SUMS and the library",
        #all_urls == 4 and libs == 1 and #off == 0, table.concat(all_urls, " "))
    chk("a library of this release needs nothing", Install.lib_needs_install(PACK, VERSION) == false)
    lib_downloads = 0
    pcall(Install.run, { path = PACK })
    chk("so the next install does not fetch it again", lib_downloads == 0, lib_downloads .. " library downloads")
  end)

  -- macOS x86_64 and Linux arm64 have a library prebuilt but no core
  -- prebuilt: the library's install does not wait for the core's, which
  -- builds with cargo there or fails without it
  case("the library on the platforms without a core prebuilt", function()
    local real_exec = vim.fn.executable
    local function no_cargo(x) if x == "cargo" then return 0 end return real_exec(x) end
    for _, e in ipairs({ { "Darwin", "x86_64", "x86_64-apple-darwin" }, { "Linux", "aarch64", "aarch64-unknown-linux-gnu" } }) do
      local tgt = e[3]
      local r = {}
      local okc, errc = pcall(as_uname, e[1], e[2], function()
        lib_reset()
        stub_release({ served = served_lc, lib = REAL_LIB })
        vim.fn.executable = no_cargo
        r.notes, r.ok, r.err = capture(function() return Install.run({ path = PACK }, { force = true }) end)
        r.lp = Install.lib_path(PACK)
        r.downloads, r.fetched = lib_downloads, lib_fetched[1]
        r.same, r.version = same_file(r.lp, REAL_LIB), Install.lib_installed_version(PACK)
        lib_downloads = 0
        pcall(Install.run, { path = PACK }, { no_cargo = true })
        r.again = lib_downloads
      end)
      vim.fn.executable = real_exec
      chk(tgt .. ": :JupynvimInstall without cargo installs the library", okc and r.downloads == 1 and r.fetched == tgt
          and r.same and r.version == VERSION and noted(r.notes or {}, vim.log.levels.INFO, "libjupynvim " .. tgt .. " installed"),
          tostring(errc) .. " / " .. vim.inspect({ r.downloads, r.fetched, r.same, r.version }))
      chk(tgt .. ": and still reports the core's error", okc and r.ok == false
          and tostring(r.err):find("cargo is not on PATH", 1, true) ~= nil, tostring(r.err))
      chk(tgt .. ": the next first-use install fetches nothing more", okc and r.again == 0, tostring(r.again))
      if r.lp then os.remove(r.lp) end
      lib_reset()
    end
    -- on this machine: a core prebuilt that does not run here, and no cargo
    lib_reset(); os.remove(final)
    local glibc = tmp .. "/served-core-broken-for-lib"
    broken_binary(glibc)
    stub_release({ served = glibc, lib = REAL_LIB })
    vim.fn.executable = no_cargo
    local _, hok, herr = capture(function() return Install.run({ path = PACK }, { force = true }) end)
    vim.fn.executable = real_exec
    chk("host: a core that fails still gets the library", hok == false and tostring(herr):find("cargo is not on PATH", 1, true)
        and lib_downloads == 1 and same_file(LIBF, REAL_LIB) and Install.lib_installed_version(PACK) == VERSION,
        tostring(herr) .. " / " .. lib_downloads .. " library downloads")
    lib_reset(); os.remove(final)
  end)

  -- Where cargo builds the core it builds the library too, and stamps it:
  -- :JupynvimInstall (force) must not download the release's library over
  -- it, nor warn that it is missing when the release has none
  case("a library cargo built for :JupynvimInstall", function()
    local cargo = BIN .. "/cargo"
    local r = {}
    local okc, errc = pcall(as_uname, "Darwin", "x86_64", function()
      local lp = Install.lib_path(PACK)
      local rel = PACK .. "/core/target/release"
      write_file(cargo, "#!/bin/sh\nmkdir -p '" .. rel .. "/.fingerprint'\n" ..
        "printf '#!/bin/sh\\necho jupynvim-core " .. VERSION .. "\\n' > '" .. rel .. "/jupynvim-core'\n" ..
        "chmod +x '" .. rel .. "/jupynvim-core'\ncp '" .. FAKE_LIB .. "' '" .. lp .. "'\n")
      vim.fn.setfperm(cargo, "rwxr-xr-x")
      r.lp = lp
      for i, lib in ipairs({ false, REAL_LIB }) do   -- a release without the library, then one with it
        lib_reset(); os.remove(lp); os.remove(final)
        stub_release({ served = served_lc, lib = lib or nil })
        local notes, ok = capture(function() return Install.run({ path = PACK }, { force = true }) end)
        r[i] = { ok = ok, downloads = lib_downloads, built = same_file(lp, FAKE_LIB),
                 warned = noted(notes, vim.log.levels.WARN, "libjupynvim not installed") }
      end
    end)
    os.remove(cargo)
    for i, what in ipairs({ "a release without the library", "a release with it" }) do
      local x = r[i] or {}
      chk(("after cargo built the library, :JupynvimInstall downloads none and keeps it (%s)"):format(what),
          okc and x.ok and x.downloads == 0 and x.built and not x.warned, tostring(errc) .. " / " .. vim.inspect(x))
    end
    if r.lp then os.remove(r.lp) end
    lib_reset(); os.remove(final)
  end)

  case("the probe", function()
    local t0 = vim.uv.hrtime()
    local p = Install._probe_lib(REAL_LIB, PACK)
    local ms = (vim.uv.hrtime() - t0) / 1e6
    chk(("the probe loads the real library in a Neovim of its own, in under 2 s (%.0f ms)"):format(ms),
        p.version == VERSION and p.abi == "1.1" and not p.err and ms < 2000, vim.inspect(p))
    local g = Install._probe_lib(garbage, PACK)
    chk("and says why a file does not load", g.version == nil and type(g.err) == "string" and g.err ~= ""
        and not g.transient, vim.inspect(g))
    local okp, rp = pcall(loadfile(PACK .. "/lua/jupynvim/backend/native_probe.lua"), "jupynvim.backend.native_probe")
    local okj, rj = pcall(loadfile(PACK .. "/lua/jupynvim/backend/install_lib_job.lua"), "jupynvim.backend.install_lib_job")
    local okn, rn = pcall(loadfile(PACK .. "/lua/jupynvim/backend/install_lib_job.lua"))
    chk("the probe and the job scripts do nothing when required",
        okp and vim.deep_equal(rp, {}) and okj and vim.deep_equal(rj, {}) and okn and vim.deep_equal(rn, {}),
        table.concat({ tostring(rp), tostring(rj), tostring(rn) }, " | "))
    -- nor when another nvim -l script, with arguments that look like
    -- theirs, requires them
    local req = tmp .. "/require-scripts.lua"
    write_file(req, ("package.path = %q .. '/lua/?.lua;' .. package.path\n"):format(PACK) ..
      "local a = require('jupynvim.backend.native_probe')\n" ..
      "local b = require('jupynvim.backend.install_lib_job')\n" ..
      "io.stdout:write('required ', vim.inspect(a), ' ', vim.inspect(b), '\\n')\n")
    local r = vim.system({ vim.v.progpath, "--clean", "--headless", "-l", req, PACK, PACK }, { text = true }):wait(10000)
    chk("nor when another nvim -l script requires them", r.code == 0 and vim.trim(r.stdout or "") == "required {} {}",
        vim.inspect(r))
  end)

  case("a wrong library hash", function()
    lib_reset()
    vim.fn.system({ "cp", FAKE_LIB, LIBF })
    write_lib_stamp("0.0.1")   -- the library of an older release, so this run wants a new one
    local before, stamp0 = read_file(LIBF), read_file(LSTAMP)
    os.remove(final)
    stub_release({ served = served_lc, lib = REAL_LIB, lib_bad_hash = true })
    local notes, ok, res = capture(function() return Install.run({ path = PACK }) end)
    chk("a library with the wrong hash leaves the installed one and its stamp untouched",
        lib_downloads == 1 and read_file(LIBF) == before and read_file(LSTAMP) == stamp0 and no_partial(),
        lib_downloads .. " library downloads")
    chk("and the core is installed all the same", ok and res == true and vim.fn.executable(final) == 1, tostring(res))
    chk("and it says so as an error", noted(notes, vim.log.levels.ERROR, "SHA256"), vim.inspect(notes))
    chk("and says the editor works without it", noted(notes, vim.log.levels.WARN, "everything works without it"),
        vim.inspect(notes))
  end)

  case("an unlisted library", function()
    lib_reset()
    stub_release({ served = served_lc, lib = REAL_LIB, lib_unlisted = true })
    local _, ok, done, why = capture(function() return Install.run_lib(PACK, {}) end)
    chk("a library the release's SHA256SUMS does not list is refused",
        ok and done == false and lib_downloads == 1 and not exists(LIBF) and no_partial()
        and tostring(why):find("not listed", 1, true) ~= nil, tostring(why))
  end)

  -- The library loads into Neovim's own process, and every release that
  -- has it publishes SHA256SUMS: one that cannot be checked is refused,
  -- never installed with a warning, and never remembered (a mirror that
  -- gains SHA256SUMS works next time). The core keeps its warn-and-proceed
  -- for releases older than SHA256SUMS.
  case("a library whose checksum cannot be checked", function()
    lib_reset()
    stub_release({ served = served_lc, lib = REAL_LIB, sums = false })
    local notes, ok, done, why = capture(function() return Install.run_lib(PACK, { force = true }) end)
    chk("a library with no SHA256SUMS to check it against is refused", ok and done == false
        and tostring(why):find("^checksum: not verified, no SHA256SUMS published for") ~= nil
        and not exists(LIBF) and no_partial(), tostring(why))
    chk("and it says so as an error", noted(notes, vim.log.levels.ERROR, "could not be verified"), vim.inspect(notes))
    chk("and it is not remembered", lib_bad() == nil, tostring(lib_bad()))
    lib_reset()
    local sums = (sha256(REAL_LIB) or "") .. "  " .. Install._lib_asset(HOST_LT) .. "\n"
    stub_release({ served = served_lc, lib = REAL_LIB, sums_text = sums })
    local n2, ok2, done2, why2 = capture(function()
      return without_hash_tools(function() return Install.run_lib(PACK, { force = true }) end)
    end)
    chk("a library on a machine without shasum or sha256sum is refused", ok2 and done2 == false
        and why2 == "checksum: not verified, no shasum/sha256sum available" and not exists(LIBF) and no_partial(),
        tostring(why2) .. " / " .. vim.inspect(n2))
    -- a SHA256SUMS the network did not deliver is not one the release lacks
    lib_reset()
    stub_release({ served = served_lc, lib = REAL_LIB,
                   sums_fail = "curl: (6) Could not resolve host: mirror.example\ncurl: (6) Could not resolve host: mirror.example" })
    local _, ok3, done3, why3 = capture(function() return Install.run_lib(PACK, { force = true }) end)
    chk("a SHA256SUMS that could not be fetched says so, with curl's line, and the library is refused", ok3
        and done3 == false and why3 == "checksum: not verified, SHA256SUMS could not be fetched "
        .. "(curl: (6) Could not resolve host: mirror.example)" and not exists(LIBF) and lib_bad() == nil, tostring(why3))
    lib_reset()
  end)

  case("a core whose checksum cannot be checked", function()
    os.remove(final)
    local sums = (sha256(served_lc) or "") .. "  jupynvim-core-" .. target .. "\n"
    stub_release({ served = served_lc, sums_text = sums })
    local notes, ok, res = capture(function()
      return without_hash_tools(function() return Install._fetch(TAG, target, final, VERSION) end)
    end)
    chk("the core keeps its documented warn-and-proceed when no tool can check it", ok and res == true
        and vim.fn.executable(final) == 1
        and noted(notes, vim.log.levels.WARN, "checksum not verified (no shasum/sha256sum available)"),
        tostring(res) .. " / " .. vim.inspect(notes))
    os.remove(final)
  end)

  case("an http release base downloads nothing", function()
    local why = "JUPYNVIM_RELEASE_BASE must start with https:// or file://"
    local function errors(notes)
      local n = 0
      for _, x in ipairs(notes) do if x[2] == vim.log.levels.ERROR and x[1]:find(why, 1, true) then n = n + 1 end end
      return n
    end
    lib_reset(); os.remove(final)
    stub_release({ served = served_lc, lib = REAL_LIB })
    vim.env.JUPYNVIM_RELEASE_BASE = "http://127.0.0.1:9"
    local n1, ok1, done1, why1 = capture(function() return Install.run_lib(PACK, { force = true }) end)
    local urls1 = #all_urls
    local n2, ok2, res2, why2 = capture(function() return Install._fetch(TAG, target, final, VERSION) end)
    local urls2 = #all_urls - urls1
    vim.env.JUPYNVIM_RELEASE_BASE = NO_RELEASE
    chk("an http base: the library is not fetched, with one ERROR notice", ok1 and done1 == false and why1 == why
        and urls1 == 0 and errors(n1) == 1 and not exists(LIBF), tostring(why1) .. " / " .. urls1 .. " requests")
    chk("an http base: nor is the core", ok2 and res2 == false and why2 == why and urls2 == 0 and errors(n2) == 1
        and vim.fn.filereadable(final) == 0, tostring(why2) .. " / " .. urls2 .. " requests")
    lib_reset()
  end)

  case("a release without the library", function()
    lib_reset(); os.remove(final)
    stub_release({ served = served_lc })
    local ok, res = pcall(Install.run, { path = PACK })
    chk("a release without the library still installs the core",
        ok and res == true and vim.fn.executable(final) == 1 and lib_downloads == 1 and not exists(LIBF),
        ("%s / %d library downloads"):format(tostring(res), lib_downloads))
    chk("and remembers the library is not published", tostring(lib_bad()):find("not published in " .. TAG, 1, true) ~= nil,
        tostring(lib_bad()))
    lib_downloads = 0; os.remove(final)
    pcall(Install.run, { path = PACK }, { no_cargo = true })
    chk("so the next first-use install does not ask for it", lib_downloads == 0 and vim.fn.executable(final) == 1,
        lib_downloads .. " library downloads")
    -- not published is a verdict about this moment (a mirror that synced
    -- the core first, a release still uploading): a day later first opens
    -- ask again
    local rec = vim.json.decode(read_file(FAILED_JSON) or "{}")[TAG .. "|lib-" .. HOST_LT.target]
    chk("the not-published verdict is kept with the time it was found", type(rec) == "table"
        and tostring(rec.reason):find("^not published in") ~= nil and type(rec.at) == "number" and rec.ttl == 86400,
        vim.inspect(rec))
    local real_now = Install._now
    local okd, gone, again = pcall(function()
      Install._now = function() return real_now() + Install.LIB_RECHECK_S + 1 end
      local g = lib_bad() == nil
      lib_downloads = 0
      pcall(Install.run, { path = PACK }, { no_cargo = true })
      return g, lib_downloads
    end)
    Install._now = real_now
    chk("a day later it is no longer remembered", okd and gone == true, tostring(gone))
    chk("and the next first-use install asks for the library once", okd and again == 1, tostring(again))
    -- a verdict found while the clock was ahead (set wrong at boot, then
    -- corrected) is from the future: it is no verdict, or it would hold
    -- until the clock caught up, a year for a clock a year ahead
    local okf, fgone, fagain, fat = pcall(function()
      lib_reset()
      stub_release({ served = served_lc })
      Install._now = function() return real_now() + 3600 end
      pcall(Install.run, { path = PACK }, { no_cargo = true })
      local r = vim.json.decode(read_file(FAILED_JSON) or "{}")[TAG .. "|lib-" .. HOST_LT.target]
      local at = type(r) == "table" and r.at
      Install._now = real_now
      local g = lib_bad() == nil
      lib_downloads = 0
      pcall(Install.run, { path = PACK }, { no_cargo = true })
      return g, lib_downloads, at
    end)
    Install._now = real_now
    chk("a not-published verdict found with the clock an hour ahead is no longer remembered once it is right",
        okf and type(fat) == "number" and fat > os.time() + 3000 and fgone == true, vim.inspect({ okf, fgone, fat }))
    chk("and the next first-use install asks for the library once", okf and fagain == 1, tostring(fagain))
    -- offline is not "not published": the next try asks again
    lib_reset()
    stub_release({ served = served_lc, lib = REAL_LIB, lib_fail = "curl: (6) Could not resolve host: github.com" })
    local _, rok, done, why = capture(function() return Install.run_lib(PACK, {}) end)
    chk("a library download that fails is not remembered", rok and done == false and lib_bad() == nil
        and tostring(why):find("Could not resolve host", 1, true) ~= nil, tostring(why) .. " / " .. tostring(lib_bad()))
  end)

  -- A release laid out as a directory (a file:// mirror) answers an asset
  -- it lacks with curl's exit 37 (it cannot read the file), not a 404. That
  -- is "not published" too, or every first open would ask again. The real
  -- curl, against a release on disk.
  case("a file:// release without the library", function()
    lib_reset()
    local rel = tmp .. "/rel-without-lib"
    vim.fn.mkdir(rel .. "/" .. TAG, "p")
    write_file(rel .. "/" .. TAG .. "/SHA256SUMS", "")
    local prev_base, prev_curl = vim.env.JUPYNVIM_RELEASE_BASE, Install._curl
    vim.env.JUPYNVIM_RELEASE_BASE = "file://" .. rel
    Install._curl = REAL_CURL
    local _, okf, got = capture(function() return { Install._fetch_lib(TAG, HOST_LT, LIBF, VERSION, PACK) } end)
    local fok, freason, fnp = unpack(type(got) == "table" and got or {})
    local _, rok, rdone, rwhy = capture(function() return Install.run_lib(PACK, {}) end)
    Install._curl = prev_curl
    vim.env.JUPYNVIM_RELEASE_BASE = prev_base
    chk("a file:// release without the library asset: not published (curl's exit 37 is its 404)",
        okf and fok == false and freason == "not published in " .. TAG and fnp == true,
        vim.inspect({ okf, fok, freason, fnp }))
    chk("and run_lib remembers that, so first opens stop asking", rok and rdone == false
        and rwhy == "not published in " .. TAG and lib_bad() == "not published in " .. TAG
        and not exists(LIBF) and no_partial(), tostring(rwhy) .. " / " .. tostring(lib_bad()))
    -- only a release on disk: from any other base that exit is a download
    -- that failed, which the next try asks for again
    lib_reset()
    stub_release({ served = served_lc, lib_fail = "curl: (37) Couldn't open file /x" })
    vim.env.JUPYNVIM_RELEASE_BASE = "https://mirror.example/jnv"
    local _, hok, hdone, hwhy = capture(function() return Install.run_lib(PACK, {}) end)
    vim.env.JUPYNVIM_RELEASE_BASE = prev_base
    chk("the same exit from an https:// release is a failed download, not remembered", hok and hdone == false
        and tostring(hwhy):find("download failed", 1, true) ~= nil and lib_bad() == nil,
        tostring(hwhy) .. " / " .. tostring(lib_bad()))
    lib_reset()
  end)

  case("the library each platform asks for", function()
    for _, e in ipairs(LIB_EXPECT) do
      lib_reset()
      stub_release({ served = served_lc })   -- nothing published: only the request matters
      capture(function() return as_uname(e[1], e[2], function() return Install.run_lib(PACK, {}) end) end)
      local want = "/" .. TAG .. "/libjupynvim-" .. e[3] .. "." .. e[4]
      chk(("%s %s asks the release for libjupynvim-%s.%s"):format(e[1], e[2], e[3], e[4]),
          vim.deep_equal(lib_fetched, { e[3] }) and #all_urls == 1 and all_urls[1]:sub(-#want) == want,
          table.concat(all_urls, " "))
    end
    lib_reset()
  end)

  case("libraries that do not load here", function()
    for _, c in ipairs({
      { "a file that is not a library", garbage, nil, "does not load here" },
      { "a library of another ABI major", FAKE_LIB, "abi_major", "does not load here: has ABI 2.0" },
      { "a library of another version", FAKE_LIB, "version", "it is v0.0.0-fake, not v" .. VERSION },
    }) do
      lib_reset()
      vim.env.JNV_FAKE = c[3]
      stub_release({ served = served_lc, lib = c[2] })
      local _, ok, done, why = capture(function() return Install.run_lib(PACK, {}) end)
      vim.env.JNV_FAKE = nil
      chk(c[1] .. " is refused and never renamed in",
          ok and done == false and lib_downloads == 1 and not exists(LIBF) and not exists(LSTAMP) and no_partial(),
          tostring(why))
      chk(c[1] .. " is remembered: " .. c[4], tostring(lib_bad()):find(c[4], 1, true) ~= nil, tostring(lib_bad()))
      if c[2] == garbage then
        -- a library that does not load here does not start loading tomorrow
        local real_now = Install._now
        Install._now = function() return real_now() + Install.LIB_RECHECK_S + 1 end
        local okb, bad = pcall(lib_bad)
        Install._now = real_now
        chk("a library that does not load here stays remembered after a day", okb
            and tostring(bad):find("^does not load here") ~= nil, tostring(bad))
      end
      -- over the library of an older release, which stays as it was
      lib_reset()
      vim.fn.system({ "cp", REAL_LIB, LIBF })
      write_lib_stamp("0.0.1")
      local before, stamp0 = read_file(LIBF), read_file(LSTAMP)
      vim.env.JNV_FAKE = c[3]
      local _, ok2, done2, why2 = capture(function() return Install.run_lib(PACK, {}) end)
      vim.env.JNV_FAKE = nil
      chk(c[1] .. " leaves the installed library and its stamp as they were",
          ok2 and done2 == false and lib_downloads == 1 and read_file(LIBF) == before
          and read_file(LSTAMP) == stamp0 and no_partial(), tostring(why2))
    end
    os.remove(LIBF); os.remove(LSTAMP)
    lib_downloads = 0
    capture(function() return Install.run_lib(PACK, {}) end)
    chk("a refused library is not fetched again on first use", lib_downloads == 0, lib_downloads .. " downloads")
    stub_release({ served = served_lc, lib = REAL_LIB })
    local _, ok, done = capture(function() return Install.run_lib(PACK, { force = true }) end)
    chk(":JupynvimInstall (force) tries again, and one that loads clears the entry",
        ok and done == true and lib_downloads == 1 and same_file(LIBF, REAL_LIB) and lib_bad() == nil,
        tostring(lib_bad()))
  end)

  case("a probe that does not answer", function()
    lib_reset()
    local real_probe = Install._probe_lib
    Install._probe_lib = function() return { err = "no answer within 10s", transient = true } end
    stub_release({ served = served_lc, lib = REAL_LIB })
    local notes, ok, done, why = capture(function() return Install.run_lib(PACK, {}) end)
    Install._probe_lib = real_probe
    chk("a library whose probe does not answer is not installed", ok and done == false and not exists(LIBF) and no_partial())
    chk("and is not remembered as one that does not load", lib_bad() == nil, tostring(lib_bad()))
    chk("a probe that does not answer: its reason and notice say it could not be checked here, never that it does not load",
        unchecked(notes, why, "no answer within 10s"), tostring(why) .. " / " .. vim.inspect(notes))
  end)

  case("when the library needs installing", function()
    lib_reset()
    local n, why = Install.lib_needs_install(PACK, VERSION)
    chk("a missing library needs installing", n == true and why == "missing", tostring(why))
    vim.fn.system({ "cp", REAL_LIB, LIBF })
    write_lib_stamp("0.0.1")
    n, why = Install.lib_needs_install(PACK, VERSION)
    chk("so does the library of another release", n == true and tostring(why):find("v0.0.1", 1, true) ~= nil
        and tostring(why):find("v" .. VERSION, 1, true) ~= nil, tostring(why))
    chk("whose stamp names its version", Install.lib_installed_version(PACK) == "0.0.1")
    write_lib_stamp(VERSION)
    chk("the library of this release does not", Install.lib_needs_install(PACK, VERSION) == false)
    -- the stamp is written for the file about to be renamed in, so an
    -- install cut short between the two leaves a stamp the file does not match
    local f = assert(io.open(LIBF, "ab")); f:write("x"); f:close()
    chk("a stamp the file does not match names no version", Install.lib_installed_version(PACK) == nil)
    n, why = Install.lib_needs_install(PACK, VERSION)
    chk("and the library is installed again, as after an install that did not finish", n == true, tostring(why))
    chk("nothing is installed where no library prebuilt is made",
        as_uname("Plan9", "mips", function() return Install.lib_needs_install(PACK, VERSION) end) == false)
  end)

  case("an install that cannot rename", function()
    lib_reset()
    vim.fn.system({ "cp", FAKE_LIB, LIBF })
    write_lib_stamp("0.0.1")
    local before, stamp0 = read_file(LIBF), read_file(LSTAMP)
    stub_release({ served = served_lc, lib = REAL_LIB })
    local real_rename = os.rename
    ---@diagnostic disable-next-line: duplicate-set-field
    os.rename = function(a, b)
      if b == LIBF then return nil, "Permission denied" end
      return real_rename(a, b)
    end
    local _, ok, done, why = capture(function() return Install.run_lib(PACK, {}) end)
    os.rename = real_rename
    chk("a library that cannot be renamed in leaves the old one and its stamp as they were",
        ok and done == false and read_file(LIBF) == before and read_file(LSTAMP) == stamp0 and no_partial()
        and tostring(why):find("could not replace", 1, true) ~= nil, tostring(why))
  end)

  -- An install cut short, the way a dead laptop or a kill stops it between
  -- two system calls: os.rename stands in for the last call that happened.
  -- The stamp is written for the incoming file before it is renamed in, so
  -- whichever side of the rename the install stopped on, the next look is
  -- right: the old library does not match it (install again), the new one
  -- does (installed). Without it, a new library with no stamp would count as
  -- one you put there and never be updated again.
  case("an install cut short", function()
    local real_rename = os.rename
    local function cut(after_rename, opts)
      ---@diagnostic disable-next-line: duplicate-set-field
      os.rename = function(a, b)
        if b == LIBF then
          if after_rename then real_rename(a, b) end
          error("cut short", 0)
        end
        return real_rename(a, b)
      end
      local notes, ok, done = capture(function() return Install.run_lib(PACK, opts or {}) end)
      os.rename = real_rename
      -- a killed install leaves its download beside the library; the next one uses its own name
      local left = vim.fn.glob(LIBF .. ".download.*", false, true)
      for _, p in ipairs(left) do os.remove(p) end
      return ok and done == false and noted(notes, vim.log.levels.WARN, "cut short"), #left
    end
    lib_reset()
    stub_release({ served = served_lc, lib = REAL_LIB })
    local stopped = cut(true)
    chk("an install cut short right after the library's rename leaves it stamped as installed",
        stopped and same_file(LIBF, REAL_LIB) and Install.lib_installed_version(PACK) == VERSION and no_partial(),
        tostring(read_file(LSTAMP)))
    chk("so a later release still replaces it", Install.lib_needs_install(PACK, "9.9.9") == true,
        tostring(select(2, Install.lib_needs_install(PACK, "9.9.9"))))
    lib_reset()
    vim.fn.system({ "cp", FAKE_LIB, LIBF })
    write_lib_stamp(VERSION)   -- this version's library, repaired by :JupynvimInstall (force), cut short
    local before = read_file(LIBF)
    stub_release({ served = served_lc, lib = REAL_LIB })
    local stopped2, left2 = cut(false, { force = true })
    local need, why = Install.lib_needs_install(PACK, VERSION)
    chk("an install cut short right before the rename leaves the old library and a stamp it does not match",
        stopped2 and left2 == 1 and read_file(LIBF) == before and Install.lib_installed_version(PACK) == nil,
        ("%d download left; the stamp says v%s"):format(left2, tostring(Install.lib_installed_version(PACK))))
    chk("so the next first use installs it again", need == true, tostring(why))
    lib_downloads = 0
    capture(function() return Install.run_lib(PACK, {}) end)
    chk("and that install puts this release's library in place",
        lib_downloads == 1 and same_file(LIBF, REAL_LIB) and Install.lib_installed_version(PACK) == VERSION and no_partial(),
        lib_downloads .. " library downloads")
    lib_reset()
  end)

  -- Two Neovims finishing an install at the same moment: the other one's
  -- library lands between this one's look at the file and its stamp's
  -- rename. The stamp is checked against the file after it is written, so
  -- it ends up describing the library that won.
  case("two installs finishing at once", function()
    lib_reset()
    stub_release({ served = served_lc, lib = REAL_LIB })
    local other = tmp .. "/other-install"
    local real_rename = os.rename
    local lib_in, raced = false, false
    ---@diagnostic disable-next-line: duplicate-set-field
    os.rename = function(a, b)
      if b == LIBF then
        lib_in = true
      elseif b == LSTAMP and lib_in and not raced then
        raced = true
        vim.fn.system({ "cp", REAL_LIB, other })
        vim.uv.fs_utime(other, 1000000000, 1000000000)   -- a file of its own: another mtime
        real_rename(other, LIBF)
      end
      return real_rename(a, b)
    end
    local _, ok, done = capture(function() return Install.run_lib(PACK, {}) end)
    os.rename = real_rename
    local st = vim.uv.fs_stat(LIBF)
    chk("two installs finishing at once leave a stamp that describes the library in place",
        ok and done == true and raced and st and st.mtime.sec == 1000000000
        and Install.lib_installed_version(PACK) == VERSION and no_partial(), tostring(read_file(LSTAMP)))
    lib_reset()
  end)

  -- The probe's own Neovim that never answers (a library whose loading
  -- hangs) is killed when the 10 s wait runs out. That says nothing about
  -- the library, so it is not remembered as one that does not load. The
  -- probe's process is a real one that hangs; only the wait is shortened.
  case("a probe that does not answer in time", function()
    lib_reset()
    local real_system = vim.system
    local waited
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.system = function(argv, opts, cb)
      if type(argv) == "table" and tostring(argv[5]):find("native_probe.lua", 1, true) then
        local obj = real_system({ "sleep", "30" }, opts)
        return { wait = function(_, ms) waited = ms; return obj:wait(300) end }
      end
      return real_system(argv, opts, cb)
    end
    local t0 = vim.uv.hrtime()
    local okp, p = pcall(Install._probe_lib, REAL_LIB, PACK)
    local ms = (vim.uv.hrtime() - t0) / 1e6
    stub_release({ served = served_lc, lib = REAL_LIB })
    local notes, ok, done, why = capture(function() return Install.run_lib(PACK, {}) end)
    vim.system = real_system
    chk("the probe waits 10 s for an answer", waited == 10000, tostring(waited))
    chk(("a probe that does not answer is stopped and says so (%.0f ms)"):format(ms),
        okp and type(p) == "table" and p.err == "no answer within 10s" and p.transient == true and p.version == nil,
        vim.inspect(p))
    chk("so the library is not installed, and not remembered as one that does not load",
        ok and done == false and not exists(LIBF) and no_partial() and lib_bad() == nil,
        tostring(why) .. " / " .. tostring(lib_bad()))
    chk("a probe stopped after 10 s: its reason and notice say it could not be checked here, never that it does not load",
        unchecked(notes, why, "no answer within 10s"), tostring(why) .. " / " .. vim.inspect(notes))
    lib_reset()
  end)

  -- A probe whose Neovim cannot start (vim.v.progpath gone because Neovim
  -- was upgraded under a running session, or no process slot free) says
  -- nothing about the library either: not remembered, so the next try (a
  -- first open, a new session) installs it.
  case("a probe that cannot start", function()
    lib_reset()
    local real_system = vim.system
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.system = function(argv, opts, cb)
      if type(argv) == "table" and tostring(argv[5]):find("native_probe.lua", 1, true) then
        error("ENOENT: no such file or directory (cmd): '" .. tostring(argv[1]) .. "'")
      end
      return real_system(argv, opts, cb)
    end
    local okp, p = pcall(Install._probe_lib, REAL_LIB, PACK)
    stub_release({ served = served_lc, lib = REAL_LIB })
    local notes, ok, done, why = capture(function() return Install.run_lib(PACK, {}) end)
    vim.system = real_system
    chk("a probe that cannot start says so, as a failure that says nothing about the library",
        okp and type(p) == "table" and p.version == nil and p.transient == true
        and tostring(p.err):find("^the probe could not start: ") ~= nil, vim.inspect(p))
    chk("then the library is not installed, and is not remembered: the next try installs it",
        ok and done == false and not exists(LIBF) and no_partial() and lib_bad() == nil
        and Install.lib_needs_install(PACK, VERSION) == true, tostring(why) .. " / " .. tostring(lib_bad()))
    chk("a probe that cannot start: its reason and notice say it could not be checked here, never that it does not load",
        unchecked(notes, why, "the probe could not start: ") and tostring(why):find("ENOENT", 1, true) ~= nil,
        tostring(why) .. " / " .. vim.inspect(notes))
    lib_reset()
  end)

  -- The background install's own Neovim that cannot start: it says so, so
  -- the caller does not wait for a result that never comes.
  case("a background install that cannot start", function()
    local real_system = vim.system
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.system = function() error("EAGAIN: resource temporarily unavailable") end
    local called = false
    local okb, started, why = pcall(Install.run_lib_background, PACK, function() called = true end)
    vim.system = real_system
    vim.wait(50)
    chk("a background install whose Neovim cannot start says it did not start, and why",
        okb and started == false and tostring(why):find("EAGAIN", 1, true) ~= nil and not called,
        vim.inspect({ okb, started, why, called }))
  end)

  -- A loader that already looked for the library in this session and found
  -- it missing (a :checkhealth, a first use) looks again once an install in
  -- this Neovim puts it in place: its advice is :JupynvimInstall, no restart.
  case("a loader that found the library missing", function()
    local prev_native, forgot = package.loaded["jupynvim.native"], 0
    package.loaded["jupynvim.native"] = { _forget_missing = function() forgot = forgot + 1 end }
    lib_reset()
    stub_release({ served = served_lc, lib = REAL_LIB })
    local _, ok1, done1 = capture(function() return Install.run_lib(PACK, {}) end)
    local after_install = forgot
    lib_reset()
    stub_release({ served = served_lc, lib = garbage })
    capture(function() return Install.run_lib(PACK, {}) end)
    local after_refused = forgot - after_install
    -- a cargo build the installer made builds the library too
    lib_reset(); os.remove(final)
    local rel = PACK .. "/core/target/release"
    local cargo = BIN .. "/cargo"
    write_file(cargo, "#!/bin/sh\nmkdir -p '" .. rel .. "/.fingerprint'\n" ..
      "printf '#!/bin/sh\\necho jupynvim-core " .. VERSION .. "\\n' > '" .. rel .. "/jupynvim-core'\n" ..
      "chmod +x '" .. rel .. "/jupynvim-core'\ncp '" .. REAL_LIB .. "' '" .. LIBF .. "'\n")
    vim.fn.setfperm(cargo, "rwxr-xr-x")
    stub_release({ served = served_lc, lib = REAL_LIB, fail = true })
    forgot = 0
    local _, cok, cres = capture(function() return Install.run({ path = PACK }) end)
    os.remove(cargo)
    package.loaded["jupynvim.native"] = prev_native
    chk("a library the installer puts in place makes a loader that found it missing look again",
        ok1 and done1 == true and after_install == 1, after_install .. " forget calls")
    chk("one it refuses does not", after_refused == 0, after_refused .. " forget calls")
    chk("and so does a library a cargo build of the installer's made",
        cok and cres == false and same_file(LIBF, REAL_LIB) and forgot == 1, forgot .. " forget calls")
    lib_reset(); os.remove(final)
  end)

  -- A plugin directory nobody may write to (a system package, a Nix store):
  -- the install would fail at the rename in every session, which is never
  -- remembered, so nothing is downloaded or probed there at all.
  case("a plugin directory the installer cannot write", function()
    local ro = tmp .. "/ro-plugin"
    vim.fn.mkdir(ro .. "/core", "p")
    local changed = {}
    local function ro_dir(d) vim.uv.fs_chmod(d, 365); changed[#changed + 1] = d end -- 0555
    local need1, why1, need2, why2
    local okc, errc = pcall(function()
      ro_dir(ro .. "/core")
      need1, why1 = Install.lib_needs_install(ro, VERSION)
      vim.uv.fs_chmod(ro .. "/core", 493) -- 0755
      vim.fn.mkdir(ro .. "/core/target/release", "p")
      ro_dir(ro .. "/core/target/release")
      need2, why2 = Install.lib_needs_install(ro, VERSION)
    end)
    for _, d in ipairs(changed) do vim.uv.fs_chmod(d, 493) end
    chk("a read-only plugin directory gets no library download (no target dir yet)",
        okc and need1 == false and why1 == "the plugin's directory is not writable", tostring(errc) .. " / " .. tostring(why1))
    chk("nor with a read-only core/target/release",
        okc and need2 == false and why2 == "the plugin's directory is not writable", tostring(errc) .. " / " .. tostring(why2))
  end)

  case("a cargo build of your own", function()
    lib_reset()
    vim.fn.mkdir(PACK .. "/core/target/release/.fingerprint", "p")
    fake_binary(final, VERSION)
    stub_release({ served = served_lc, lib = REAL_LIB })
    local need, why = Install.lib_needs_install(PACK, VERSION)
    local _, ok, done = capture(function() return Install.run_lib(PACK, {}) end)
    chk("a cargo build of your own never gets a library download",
        need == false and ok and done == true and lib_downloads == 0 and not exists(LIBF), tostring(why))
    vim.fn.delete(PACK .. "/core/target/release/.fingerprint", "rf")
  end)

  case("a library you put there", function()
    lib_reset()
    vim.fn.system({ "cp", FAKE_LIB, LIBF })
    local before = read_file(LIBF)
    os.remove(final)
    stub_release({ served = served_lc, lib = REAL_LIB })
    local need = Install.lib_needs_install(PACK, VERSION)
    local ok, res = pcall(Install.run, { path = PACK })
    chk("a library with no stamp and no cargo build is left alone",
        need == false and ok and res == true and lib_downloads == 0 and read_file(LIBF) == before,
        ("%s / %d library downloads"):format(tostring(res), lib_downloads))
  end)

  case("a cargo build the installer made", function()
    lib_reset(); os.remove(final)
    local rel = PACK .. "/core/target/release"
    local cargo = BIN .. "/cargo"
    write_file(cargo, "#!/bin/sh\nmkdir -p '" .. rel .. "/.fingerprint'\n" ..
      "printf '#!/bin/sh\\necho jupynvim-core " .. VERSION .. "\\n' > '" .. rel .. "/jupynvim-core'\n" ..
      "chmod +x '" .. rel .. "/jupynvim-core'\ncp '" .. REAL_LIB .. "' '" .. LIBF .. "'\n")
    vim.fn.setfperm(cargo, "rwxr-xr-x")
    stub_release({ served = served_lc, lib = REAL_LIB, fail = true })   -- no core prebuilt: cargo builds both
    local ok, res = pcall(Install.run, { path = PACK })
    os.remove(cargo)
    chk("a cargo build the installer made stamps the library it built",
        ok and res == false and same_file(LIBF, REAL_LIB) and Install.lib_installed_version(PACK) == VERSION
        and not Install.is_dev_build(PACK) and Install.lib_needs_install(PACK, VERSION) == false and lib_downloads == 0,
        ("%s / %s"):format(tostring(res), tostring(Install.lib_installed_version(PACK))))
    lib_reset()
  end)

  lib_reset(); os.remove(final)
else
  io.write("  skip the library installs: no core and library prebuilt for this machine\n")
end

-- every download the installer made above limited curl to https and file,
-- and a redirect to https
do
  local bad = {}
  for _, a in ipairs(all_argv) do
    local s = " " .. table.concat(a, " ") .. " "
    if not s:find(" --proto =https,file ", 1, true) or not s:find(" --proto-redir =https ", 1, true) then
      bad[#bad + 1] = s
    end
  end
  chk(("every curl the installer ran limits it to https and file (%d runs)"):format(#all_argv),
      #all_argv > 0 and #bad == 0, table.concat(bad, "\n"))
end

-- ── first use: locate_core ──────────────────────────────────────────────
package.path = REPO .. "/lua/?.lua;" .. REPO .. "/lua/?/init.lua;" .. package.path
local J = require("jupynvim")
vim.notify = function() end
J.setup({ log_level = "warn" })
local RepoInstall = require("jupynvim.backend.install")
local real_root, real_run = J._plugin_root, RepoInstall.run
J._plugin_root = function() return PACK end
STUBS[#STUBS + 1] = RepoInstall
-- The background library install, counted and not started, unless a case
-- puts the real one back.
local real_bg, bg_starts = RepoInstall.run_lib_background, 0
local function bg_stub() bg_starts = bg_starts + 1; return true end
RepoInstall.run_lib_background = bg_stub
local runs = 0
local function install_stub(version)
  RepoInstall.run = function()
    runs = runs + 1
    if version then fake_binary(final, version) end
    return true
  end
end
local function fresh(auto)
  runs = 0
  J.config.auto_install = auto
  if J._reset_install_tried then J._reset_install_tried() end
end

os.remove(final)
fresh(true); install_stub(VERSION)
local lok, bin = pcall(J._locate_core)
chk("a missing binary is installed on first use", lok and runs == 1 and bin == final,
    ("ok=%s runs=%d bin=%s"):format(tostring(lok), runs, tostring(bin)))

fake_binary(final, "0.0.1")
fresh(true); install_stub(VERSION)
pcall(J._locate_core)
chk("a binary older than the plugin is replaced", runs == 1)
fake_binary(final, "0.0.1")
install_stub(nil)
pcall(J._locate_core)
chk("and tried once per session, not on every spawn", runs == 1, runs .. " installs")

fake_binary(final, "0.0.1")
vim.fn.mkdir(PACK .. "/core/target/release/.fingerprint", "p")
fresh(true); install_stub(VERSION)
local dok, dbin = pcall(J._locate_core)
chk("a cargo build of your own is never downloaded over", runs == 0 and dok and dbin == final)
vim.fn.delete(PACK .. "/core/target/release/.fingerprint", "rf")

-- a binary on PATH must match too; a stale one is only the fallback
os.remove(final)
fake_binary(BIN .. "/jupynvim-core", "0.0.1")
fresh(true); install_stub(VERSION)
local pok, pbin = pcall(J._locate_core)
chk("a stale jupynvim-core on PATH does not shadow the install", runs == 1 and pbin == final,
    ("runs=%d bin=%s"):format(runs, tostring(pbin)))
os.remove(final)
fresh(false); install_stub(VERSION)
pok, pbin = pcall(J._locate_core)
chk("with auto_install off it is still used, as the fallback", pok and pbin == "jupynvim-core" and runs == 0,
    tostring(pbin))
fake_binary(BIN .. "/jupynvim-core", VERSION)
fresh(true); install_stub(VERSION)
pok, pbin = pcall(J._locate_core)
chk("a matching one on PATH is used as it is", pok and pbin == "jupynvim-core" and runs == 0)
os.remove(BIN .. "/jupynvim-core")

-- a local binary that is there but does not run is not "not installed", and
-- is not spawned either: it only traded the message for a backend that died
broken_binary(final)
fresh(false); install_stub(VERSION)
local bok, berr = pcall(J._locate_core)
chk("a binary that does not run is reported as such", not bok
    and tostring(berr):find("does not run here", 1, true) ~= nil, tostring(berr))
-- a matching one on PATH is used instead
fake_binary(BIN .. "/jupynvim-core", VERSION)
fresh(false); install_stub(VERSION)
bok, berr = pcall(J._locate_core)
chk("a matching one on PATH wins over a local one that does not run",
    bok and berr == "jupynvim-core", tostring(berr))
os.remove(BIN .. "/jupynvim-core")
-- a build of your own that does not run gets the rebuild hint
vim.fn.mkdir(PACK .. "/core/target/release/.fingerprint", "p")
local notes = {}
local real_notify = vim.notify
vim.notify = function(m) notes[#notes + 1] = tostring(m) end
fresh(true); install_stub(VERSION)
bok, berr = pcall(J._locate_core)
vim.notify = real_notify
chk("a build of your own that does not run says so, and is not downloaded over",
    bok and berr == final and runs == 0 and table.concat(notes, " "):find("does not run here", 1, true) ~= nil
    and table.concat(notes, " "):find("cargo build", 1, true) ~= nil, table.concat(notes, " | "))
vim.fn.delete(PACK .. "/core/target/release/.fingerprint", "rf")

os.remove(final)
fresh(false); install_stub(VERSION)
local nok, nerr = pcall(J._locate_core)
chk("auto_install = false downloads nothing", runs == 0)
chk("and the error says what to run", not nok and tostring(nerr):find(":JupynvimInstall", 1, true) ~= nil,
    tostring(nerr))

-- opening a notebook with no backend reports it instead of throwing
notes = {}
vim.notify = function(m, lvl) notes[#notes + 1] = { tostring(m), lvl } end
local nb = tmp .. "/x.ipynb"
io.open(nb, "w"):write('{"cells":[],"metadata":{},"nbformat":4,"nbformat_minor":5}')
local ook = pcall(J.open, nb)
local said = false
for _, n in ipairs(notes) do
  if n[1]:find(":JupynvimInstall", 1, true) and n[2] == vim.log.levels.ERROR then said = true end
end
chk("opening a notebook without a backend is a readable error, not a stack trace", ook and said)

chk(":JupynvimInstall exists", vim.fn.exists(":JupynvimInstall") == 2)

-- ── first use: the library behind a current core ────────────────────────
-- A current core with no library (a plugin manager that never ran a build
-- hook, or an update from before the library) gets it in the background,
-- once per session, and opening the notebook never waits for it.
if target and HOST_LT then
  local function prep(auto)
    fake_binary(final, VERSION)
    os.remove(LIBF); os.remove(LSTAMP); os.remove(FAILED_JSON)
    vim.fn.delete(PACK .. "/core/target/release/.fingerprint", "rf")
    os.remove(PACK .. "/core/target/release/.jupynvim-installed")
    fresh(auto); install_stub(VERSION)
    bg_starts = 0
    if J._reset_lib_tried then J._reset_lib_tried() end
  end

  case("locate_core and the library", function()
    prep(true)
    local a1, b1 = pcall(J._locate_core)
    local a2, b2 = pcall(J._locate_core)
    chk("a current core with no library starts the library install in the background",
        a1 and b1 == final and a2 and b2 == final and bg_starts >= 1 and runs == 0,
        ("%s %s / %d starts"):format(tostring(b1), tostring(b2), bg_starts))
    chk("once per session, not on every spawn", bg_starts == 1, bg_starts .. " starts")
    prep(false)
    pcall(J._locate_core)
    chk("never with auto_install = false", bg_starts == 0, bg_starts .. " starts")
    prep(true)
    J.config.core_path = final
    pcall(J._locate_core)
    J.config.core_path = nil
    chk("with core_path set, a missing library still comes in the background", bg_starts == 1, bg_starts .. " starts")
    prep(true)
    os.remove(final)
    fake_binary(BIN .. "/jupynvim-core", VERSION)
    local pok, pbin = pcall(J._locate_core)
    os.remove(BIN .. "/jupynvim-core")
    chk("and for a jupynvim-core on PATH", pok and pbin == "jupynvim-core" and bg_starts == 1, bg_starts .. " starts")
    prep(true)
    vim.fn.system({ "cp", REAL_LIB, LIBF })
    write_lib_stamp(VERSION)
    local cur_native = package.loaded["jupynvim.native"]
    package.loaded["jupynvim.native"] = nil
    pcall(J._locate_core)
    chk("nor when the library is current", bg_starts == 0, bg_starts .. " starts")
    chk("and an open with nothing to fetch never requires jupynvim.native", package.loaded["jupynvim.native"] == nil)
    package.loaded["jupynvim.native"] = cur_native
    prep(true)
    write_file(FAILED_JSON, vim.json.encode({ [TAG .. "|lib-" .. HOST_LT.target] = "not published in " .. TAG }))
    pcall(J._locate_core)
    chk("nor when this release's library was refused or is not published", bg_starts == 0, bg_starts .. " starts")
    prep(true)
    vim.fn.mkdir(PACK .. "/core/target/release/.fingerprint", "p")
    pcall(J._locate_core)
    chk("nor for a cargo build of your own", bg_starts == 0, bg_starts .. " starts")
    prep(true)
  end)

  -- A first open with no core installs the core in the foreground, as it
  -- did before the library existed, and nothing more: the library then
  -- comes in the background, as for a current core with no library.
  case("a first open that installs the core fetches the library in the background", function()
    prep(true)
    os.remove(final)
    RepoInstall.run = real_run
    stub_release({ served = tmp .. "/served-core-for-lib", lib = REAL_LIB })
    downloads, lib_downloads = 0, 0
    local ok, bin = pcall(J._locate_core)
    local fg_core, fg_lib, lib_there = downloads, lib_downloads, exists(LIBF)
    install_stub(VERSION)
    chk("a first open with no core installs the core and returns it", ok and bin == final and fg_core == 1
        and J._binary_version(final) == VERSION, ("%s %s / %d core downloads"):format(tostring(ok), tostring(bin), fg_core))
    chk("with no library download before it returns", fg_lib == 0 and not lib_there,
        ("%d library downloads, library there: %s"):format(fg_lib, tostring(lib_there)))
    chk("and the library's install starts in the background", bg_starts == 1, bg_starts .. " starts")
    prep(true)
  end)

  -- The background install fetches only the library this Neovim would
  -- load: never one turned off, one the user replaced with a file of their
  -- own, nor one a Neovim without LuaJIT cannot load. Each setting is put
  -- back at once, also when the open throws.
  case("the background install leaves a library turned off or replaced alone", function()
    local saved_cfg, saved_env = vim.deepcopy(J.config.native), vim.env.JUPYNVIM_NATIVE
    local saved_jit, saved_native = _G.jit, package.loaded["jupynvim.native"]
    local function restore()
      J.config.native = vim.deepcopy(saved_cfg)
      vim.env.JUPYNVIM_NATIVE = saved_env
      _G.jit = saved_jit
    end
    local function first_open(apply)
      prep(true)
      local okp, ok, bin = pcall(function()
        apply()
        return pcall(J._locate_core)
      end)
      restore()
      return okp and ok and bin == final, ("%s / %d starts"):format(tostring(bin), bg_starts)
    end
    local came, detail = first_open(function() J.config.native = false end)
    chk("a library turned off in setup() (native = false) is not fetched in the background",
        came and bg_starts == 0, detail)
    came, detail = first_open(function() J.config.native = { enabled = false, workers = 0 } end)
    chk("a library turned off in setup() (native.enabled = false) is not fetched in the background",
        came and bg_starts == 0, detail)
    came, detail = first_open(function() J.config.native = { enabled = true, workers = 0, path = REAL_LIB } end)
    chk("a library named by native.path is not fetched in the background", came and bg_starts == 0, detail)
    came, detail = first_open(function() vim.env.JUPYNVIM_NATIVE = "off" end)
    chk("nor with JUPYNVIM_NATIVE=off", came and bg_starts == 0, detail)
    came, detail = first_open(function() vim.env.JUPYNVIM_NATIVE = REAL_LIB end)
    chk("nor with JUPYNVIM_NATIVE naming a file", came and bg_starts == 0, detail)
    came, detail = first_open(function() _G.jit = nil end)
    chk("nor in a Neovim without LuaJIT", came and bg_starts == 0, detail)
    -- a plugin_lib_wanted that throws: no background install, and the open
    -- still gets its core
    local stand_in = { plugin_lib_wanted = function() error("test: boom") end }
    package.loaded["jupynvim.native"] = stand_in
    prep(true)
    local okt, bint = pcall(J._locate_core)
    package.loaded["jupynvim.native"] = saved_native
    chk("a plugin_lib_wanted that throws starts no background install, and the core comes back",
        okt and bint == final and bg_starts == 0, ("%s %s / %d starts"):format(tostring(okt), tostring(bint), bg_starts))
    -- everything put back: the same open starts it (the stub still counts)
    came, detail = first_open(function() end)
    chk("control: with none of these the background install starts", came and bg_starts == 1, detail)
    package.loaded["jupynvim.native"] = saved_native
    prep(true)
  end)

  -- The real background install: a child Neovim fetches from a release on
  -- disk (file://, real curl, real SHA256SUMS, real probe), so no network.
  local REL = tmp .. "/rel"
  local asset = "libjupynvim-" .. HOST_LT.target .. "." .. HOST_LT.ext
  vim.fn.mkdir(REL .. "/" .. TAG, "p")
  vim.fn.system({ "cp", REAL_LIB, REL .. "/" .. TAG .. "/" .. asset })
  write_file(REL .. "/" .. TAG .. "/SHA256SUMS", (sha256(REAL_LIB) or "") .. "  " .. asset .. "\n")
  local prev_state = vim.env.XDG_STATE_HOME
  local function on_disk(fn)
    vim.env.JUPYNVIM_RELEASE_BASE = "file://" .. REL
    -- the child keeps what it remembers in a state dir of the test's own
    vim.env.XDG_STATE_HOME = tmp .. "/child-state"
    RepoInstall.run_lib_background = real_bg
    local ok, err = pcall(fn)
    RepoInstall.run_lib_background = bg_stub
    vim.env.JUPYNVIM_RELEASE_BASE = NO_RELEASE
    vim.env.XDG_STATE_HOME = prev_state
    if not ok then error(err, 0) end
  end

  case("the background install", function()
    on_disk(function()
      prep(true)
      local done, dres, dmsg
      local max_gap, last = 0, vim.uv.hrtime()
      local timer = vim.uv.new_timer()
      timer:start(5, 5, function()
        local now = vim.uv.hrtime()
        if now - last > max_gap then max_gap = now - last end
        last = now
      end)
      local t0 = vim.uv.hrtime()
      local in_fast
      local started = real_bg(PACK, function(ok, msg)
        done, dres, dmsg, in_fast = true, ok, msg, vim.in_fast_event()
      end)
      local call_ms = (vim.uv.hrtime() - t0) / 1e6
      vim.wait(20000, function() return done end, 5)
      local total_s = (vim.uv.hrtime() - t0) / 1e9
      timer:stop(); timer:close()
      chk(("the background install returns at once (%.2f ms)"):format(call_ms), started == true and call_ms < 20)
      chk(("and the UI keeps running: a 5 ms timer never gapped more than 50 ms (%.1f ms)"):format(max_gap / 1e6),
          max_gap / 1e6 < 50)
      chk(("it reports success within 20 s (%.2f s)"):format(total_s), done and dres == true, tostring(dmsg))
      chk("and the library and its stamp are in place",
          same_file(LIBF, REAL_LIB) and RepoInstall.lib_installed_version(PACK) == VERSION, tostring(read_file(LSTAMP)))
      -- the child's exit is seen in a fast event, where most of the API may
      -- not be called; the caller's callback runs on the main loop
      chk("its callback runs on the main loop, not in the child's exit event", done and in_fast == false,
          "in a fast event: " .. tostring(in_fast))
    end)
  end)

  case("the background install from a first open", function()
    on_disk(function()
      prep(true)
      local prev_native, forgot = package.loaded["jupynvim.native"], 0
      -- the first open asks the real module whether to fetch (settings only,
      -- never a load); the stand-in counts the loader's second look
      local wanted = require("jupynvim.native").plugin_lib_wanted
      package.loaded["jupynvim.native"] = {
        _forget_missing = function() forgot = forgot + 1 end, plugin_lib_wanted = wanted }
      local t0 = vim.uv.hrtime()
      local ok, bin = pcall(J._locate_core)
      local ms = (vim.uv.hrtime() - t0) / 1e6
      local absent = not exists(LIBF)
      vim.wait(20000, function() return forgot > 0 end, 5)
      package.loaded["jupynvim.native"] = prev_native
      chk(("opening a notebook returns the core without waiting for the library (%.1f ms)"):format(ms),
          ok and bin == final and absent, ("%s / library already there: %s"):format(tostring(bin), tostring(not absent)))
      chk("when the install finishes the library is in place and the loader looks for it again",
          forgot == 1 and same_file(LIBF, REAL_LIB) and RepoInstall.lib_installed_version(PACK) == VERSION,
          forgot .. " forget calls")
    end)
    prep(true)
  end)

  -- The real background install when it fails: a release whose library
  -- does not load here, and one without the library. Its Neovim exits 0
  -- either way; its last line says how it went, and so must on_done.
  case("a background install that fails", function()
    local function bg(base, label)
      prep(true)
      vim.env.JUPYNVIM_RELEASE_BASE = base
      vim.env.XDG_STATE_HOME = tmp .. "/child-state-" .. label
      local done, dres, dmsg
      local started = real_bg(PACK, function(okd, msg) done, dres, dmsg = true, okd, msg end)
      vim.wait(20000, function() return done end, 5)
      vim.env.JUPYNVIM_RELEASE_BASE = NO_RELEASE
      vim.env.XDG_STATE_HOME = prev_state
      return started, done, dres, dmsg
    end
    local bad = tmp .. "/rel-bad-lib"
    vim.fn.mkdir(bad .. "/" .. TAG, "p")
    write_file(bad .. "/" .. TAG .. "/" .. asset, "this is not a library\n")
    write_file(bad .. "/" .. TAG .. "/SHA256SUMS", (sha256(bad .. "/" .. TAG .. "/" .. asset) or "") .. "  " .. asset .. "\n")
    local s1, d1, r1, m1 = bg("file://" .. bad, "bad")
    chk("a background install of a library that does not load here reports failure, with the child's reason",
        s1 == true and d1 == true and r1 == false and tostring(m1):find("jnv-lib fail does not load here", 1, true) ~= nil
        and not exists(LIBF), tostring(m1))
    local none = tmp .. "/rel-no-lib"
    vim.fn.mkdir(none .. "/" .. TAG, "p")
    write_file(none .. "/" .. TAG .. "/SHA256SUMS", "")
    local s2, d2, r2, m2 = bg("file://" .. none, "none")
    chk("and one from a release without the library",
        s2 == true and d2 == true and r2 == false
        and tostring(m2):find("jnv-lib fail not published in " .. TAG, 1, true) ~= nil and not exists(LIBF), tostring(m2))
    prep(true)
  end)

  -- A background install refused for the download's integrity, or for a
  -- release base it must not download from, says so in one line (which
  -- never stops at a hit-enter prompt); any other failure stays in the log.
  -- Through the first open, with the real child, from releases on disk.
  -- With Neovim's defaults (showcmd, ruler, laststatus 2, cmdheight 1) a
  -- message fits the last line of an 80-column screen without that prompt
  -- only up to 68 cells (v:echospace, columns - 12); a narrower screen
  -- gets a shorter line.
  case("a background install refused on its checksum", function()
    local function rel(label, files)
      local d = tmp .. "/rel-" .. label
      vim.fn.mkdir(d .. "/" .. TAG, "p")
      for name, text in pairs(files) do write_file(d .. "/" .. TAG .. "/" .. name, text) end
      return "file://" .. d
    end
    local libtext = read_file(REAL_LIB)
    local nosums = rel("nosums", { [asset] = libtext })
    local http = "http://127.0.0.1:9"
    local cases = {
      { "nosums", nosums, "jupynvim: libjupynvim download refused: could not be checked" },
      { "badsum", rel("badsum", { [asset] = libtext, SHA256SUMS = string.rep("0", 64) .. "  " .. asset .. "\n" }),
        "jupynvim: libjupynvim download refused: failed its SHA256 check" },
      { "nolib", rel("nolib", { SHA256SUMS = "" }), nil },
      { "http", http, "jupynvim: JUPYNVIM_RELEASE_BASE must start with https:// or file://" },
      { "nosums at 50 columns", nosums, "jupynvim: libjupynvim download refused", 50 },
      { "http at 50 columns", http, "jupynvim: bad JUPYNVIM_RELEASE_BASE", 50 },
    }
    RepoInstall.run_lib_background = real_bg
    local columns0 = vim.o.columns
    for _, c in ipairs(cases) do
      local label, base, want, cols = c[1], c[2], c[3], c[4] or 80
      prep(true)
      J._lib_bg_state = nil
      local notes, real_notify = {}, vim.notify
      vim.notify = function(m, lvl) notes[#notes + 1] = { tostring(m), lvl } end
      vim.env.JUPYNVIM_RELEASE_BASE = base
      vim.env.XDG_STATE_HOME = tmp .. "/child-state-" .. label:gsub(" ", "-")
      vim.o.columns = cols
      local room = vim.v.echospace
      local okl, bin = pcall(J._locate_core)
      vim.wait(20000, function() return J._lib_bg_state == "failed" or J._lib_bg_state == "done" end, 5)
      vim.o.columns = columns0
      vim.env.JUPYNVIM_RELEASE_BASE = NO_RELEASE
      vim.env.XDG_STATE_HOME = prev_state
      vim.notify = real_notify
      local warns = {}
      for _, n in ipairs(notes) do if n[2] == vim.log.levels.WARN then warns[#warns + 1] = n[1] end end
      if want then
        chk(("rel-%s: the background install fails and says so in one WARN line that fits the %d cells of room"
          .. " at %d columns (68 at 80)"):format(label, room, cols),
            okl and bin == final and J._lib_bg_state == "failed" and not exists(LIBF) and #warns == 1
            and warns[1] == want and #want <= room and (cols ~= 80 or (room == 68 and #want <= 68)),
            ("%s / %s / %d characters, room %d"):format(tostring(J._lib_bg_state), vim.inspect(notes), #(warns[1] or ""), room))
      else
        chk(("rel-%s: a background install that fails for another reason says nothing"):format(label),
            okl and bin == final and J._lib_bg_state == "failed" and not exists(LIBF) and #warns == 0,
            ("%s / %s"):format(tostring(J._lib_bg_state), vim.inspect(notes)))
      end
    end
    RepoInstall.run_lib_background = bg_stub
    J._lib_bg_state = nil
    prep(true)
  end)

  case(":JupynvimInstall and the library", function()
    RepoInstall.run = real_run
    fake_binary(final, "0.0.1")
    os.remove(FAILED_JSON); os.remove(LSTAMP)
    vim.fn.system({ "cp", FAKE_LIB, LIBF })   -- one you put there: only force replaces it
    stub_release({ served = tmp .. "/served-core-for-lib", lib = REAL_LIB })
    downloads, lib_downloads = 0, 0
    vim.cmd("JupynvimInstall")
    chk(":JupynvimInstall replaces both the core and the library",
        J._binary_version(final) == VERSION and same_file(LIBF, REAL_LIB)
        and RepoInstall.lib_installed_version(PACK) == VERSION and downloads == 1 and lib_downloads == 1,
        ("core %s, %d + %d downloads"):format(tostring(J._binary_version(final)), downloads, lib_downloads))
    install_stub(VERSION)
    os.remove(final); os.remove(LIBF); os.remove(LSTAMP); os.remove(FAILED_JSON)
  end)

  -- The same with the real loader: it looked before the install and found
  -- no library (a :checkhealth, a first use), and its advice is
  -- :JupynvimInstall with no restart. JUPYNVIM_NATIVE points it at the
  -- plugin copy's library place.
  case("a session that found the library missing", function()
    -- An earlier first open may have required the Lua module to ask
    -- plugin_lib_wanted(), which never loads the library; what this case
    -- needs is a loader that has not looked yet.
    local S0 = debug.getregistry().jupynvim_native
    local state0 = S0 and S0.state
    RepoInstall.run = real_run
    fake_binary(final, VERSION)
    os.remove(LIBF); os.remove(LSTAMP); os.remove(FAILED_JSON)
    stub_release({ served = tmp .. "/served-core-for-lib", lib = REAL_LIB })
    local prev_env = vim.env.JUPYNVIM_NATIVE
    vim.env.JUPYNVIM_NATIVE = LIBF
    local N = require("jupynvim.native")
    local before, st0 = N.available(), N.status()
    vim.cmd("JupynvimInstall")
    local after, st1 = N.available(), N.status()
    vim.env.JUPYNVIM_NATIVE = prev_env
    install_stub(VERSION)
    chk("the loader found no library before the install (precondition)",
        (state0 == nil or state0 == "unloaded") and before == false and st0.state == "missing",
        vim.inspect({ state0 = state0, st0 = st0 }))
    chk("after :JupynvimInstall this session uses the library, without a restart",
        after == true and st1.state == "ok" and st1.path == LIBF and same_file(LIBF, REAL_LIB),
        ("%s: %s"):format(tostring(st1.state), tostring(st1.reason)))
    os.remove(final); os.remove(LIBF); os.remove(LSTAMP); os.remove(FAILED_JSON)
  end)
end

-- ── cross builds name the backend package ───────────────────────────────
-- core/ is a workspace with the library in it. A cross build of it all
-- would also try the library for musl, a crate type that target drops.
case("cross builds", function()
  local want = { "cargo", "zigbuild", "--release", "--target", "x86_64-unknown-linux-musl",
                 "--package", "jupynvim-core", "--manifest-path", PACK .. "/core/Cargo.toml" }
  local cmd = J._cross_build_cmd("x86_64-unknown-linux-musl")
  chk("a cross build builds the jupynvim-core package only", vim.deep_equal(cmd, want), vim.inspect(cmd))
  local seen = {}
  local real_system, real_systemlist = vim.system, vim.fn.systemlist
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.system = function(argv, _, cb)
    seen[#seen + 1] = argv
    local res = { code = 0, stdout = "", stderr = "" }
    if cb then cb(res) end
    return { wait = function() return res end }
  end
  vim.fn.systemlist = function() return { "aarch64-apple-darwin", "x86_64-unknown-linux-musl" } end
  local ok1, e1 = pcall(J._cross_build_if_stale, "x86_64-unknown-linux-musl")
  local ok2, e2 = pcall(vim.cmd, "JupynvimCrossBuild")
  vim.system, vim.fn.systemlist = real_system, real_systemlist
  chk("the cross build before an upload runs it", ok1 and vim.deep_equal(seen[1], want), tostring(e1) .. " " .. vim.inspect(seen[1]))
  chk(":JupynvimCrossBuild runs it", ok2 and vim.deep_equal(seen[2], want), tostring(e2) .. " " .. vim.inspect(seen[2]))
end)

-- ── :checkhealth jupynvim ────────────────────────────────────────────────
do
  -- :checkhealth finds lua/jupynvim/health.lua through 'runtimepath'
  vim.opt.runtimepath:prepend(REPO)
  local function health()
    vim.cmd("checkhealth jupynvim")
    -- :checkhealth writes its progress to stdout with no newline: end that
    -- line, so a FAIL line after it starts at column 0 (run_all.sh's
    -- spec_out shows the lines that start with FAIL)
    io.write("\n")
    vim.wait(2000, function() return #vim.api.nvim_buf_get_lines(0, 0, -1, false) > 3 end, 20)
    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    vim.cmd("bwipeout!")
    return text
  end
  J.config.core_path = tmp .. "/nowhere/jupynvim-core"
  local h = health()
  chk("health says when core_path points at nothing",
      h:find("core_path points at no executable", 1, true) ~= nil, h)
  J.config.core_path = nil
  local target0 = Install._detect_targets()[1]
  if target0 then
    vim.fn.mkdir(tmp .. "/state/jupynvim", "p")
    local f = io.open(tmp .. "/state/jupynvim/prebuilt_failed.json", "w")
    f:write(vim.json.encode({ ["v" .. VERSION .. "|" .. target0] = "it does not run here: GLIBC" }))
    f:close()
    h = health()
    chk("health names a prebuilt that was refused, once",
        h:find("prebuilt was refused: it does not run here: GLIBC", 1, true) ~= nil
        and select(2, h:gsub("does not run here", "")) == 1, h)
    os.remove(tmp .. "/state/jupynvim/prebuilt_failed.json")
  end
  if HOST_LT then
    write_file(FAILED_JSON, vim.json.encode({
      [TAG .. "|lib-" .. HOST_LT.target] = "does not load here: needs GLIBC_2.99" }))
    h = health()
    chk("health names this platform's library prebuilt",
        h:find("library prebuilt for this platform: " .. HOST_LT.target, 1, true) ~= nil, h)
    chk("and a library prebuilt that was refused, once",
        h:find(TAG .. " library prebuilt was refused: does not load here: needs GLIBC_2.99", 1, true) ~= nil
        and select(2, h:gsub("does not load here", "")) == 1, h)
    os.remove(FAILED_JSON)
  end
  h = without_hash_tools(health)
  chk("health says that without shasum or sha256sum the library prebuilt is refused",
      h:find("neither shasum nor sha256sum found: jupynvim-core downloads cannot be SHA256-checked, "
        .. "and the library prebuilt is refused", 1, true) ~= nil, h)
end

-- ── the README's mini.deps example pins the release this copy is ─────────
do
  local readme = table.concat(vim.fn.readfile(REPO .. "/README.md"), "\n")
  local pin = readme:match('checkout%s*=%s*"(v[^"]+)"')
  if VERSION:find("-", 1, true) then
    -- a pre-release: the README keeps pointing at the last stable release
    chk("README's mini.deps checkout is a stable release during a pre-release",
        pin ~= nil and not pin:find("-", 1, true), tostring(pin))
  else
    chk("README's mini.deps checkout is v" .. VERSION, pin == "v" .. VERSION, tostring(pin))
  end
end

J._plugin_root, RepoInstall.run, RepoInstall.run_lib_background = real_root, real_run, real_bg
vim.fn.delete(tmp, "rf")

if fails == 0 then
  io.write("\nALL INSTALL CHECKS PASSED\n")
  vim.cmd("qa!")
else
  io.write(("\nINSTALL: %d CHECK(S) FAILED\n"):format(fails))
  vim.cmd("cquit 1")
end

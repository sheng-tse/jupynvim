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
local function chk(name, cond, detail)
  if cond then io.write("  ok " .. name .. "\n")
  else io.write("FAIL " .. name .. (detail and ("  -- " .. detail) or "") .. "\n"); fails = fails + 1 end
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

-- A binary that downloads and verifies but cannot run here, the way a build
-- against a newer glibc fails on an older distro.
local function broken_binary(path)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = io.open(path, "w")
  f:write("#!/bin/sh\necho \"version 'GLIBC_2.39' not found\" >&2\nexit 1\n")
  f:close()
  vim.fn.setfperm(path, "rwxr-xr-x")
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
-- A release that serves opts.served for every asset, or opts.served[target]
-- per asset. opts.fail, or opts.fail[target], is what curl prints when the
-- download fails. Its SHA256SUMS lists every asset it serves, the way the
-- release workflow writes it, so a machine with two targets verifies both.
-- opts.vanish reports a download that left no file behind.
local function stub_release(opts)
  local function pick(v, t) if type(v) == "table" then return v[t] end return v end
  Install._curl = function(args)
    local url = args[#args]
    if url:find("SHA256SUMS", 1, true) then
      if opts.sums == false then return "", false end
      local lines = {}
      for t in pairs(Install._published) do
        local served = pick(opts.served, t)
        if served then
          local hash = opts.bad_hash and string.rep("0", 64)
            or vim.fn.system({ "shasum", "-a", "256", served }):match("^(%x+)")
          lines[#lines + 1] = hash .. "  jupynvim-core-" .. t
        end
      end
      return table.concat(lines, "\n") .. "\n", true
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

-- ── first use: locate_core ──────────────────────────────────────────────
package.path = REPO .. "/lua/?.lua;" .. REPO .. "/lua/?/init.lua;" .. package.path
local J = require("jupynvim")
vim.notify = function() end
J.setup({ log_level = "warn" })
local RepoInstall = require("jupynvim.backend.install")
local real_root, real_run = J._plugin_root, RepoInstall.run
J._plugin_root = function() return PACK end
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

-- ── :checkhealth jupynvim ────────────────────────────────────────────────
do
  -- :checkhealth finds lua/jupynvim/health.lua through 'runtimepath'
  vim.opt.runtimepath:prepend(REPO)
  local function health()
    vim.cmd("checkhealth jupynvim")
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

J._plugin_root, RepoInstall.run = real_root, real_run
vim.fn.delete(tmp, "rf")

if fails == 0 then
  io.write("\nALL INSTALL CHECKS PASSED\n")
  vim.cmd("qa!")
else
  io.write(("\nINSTALL: %d CHECK(S) FAILED\n"):format(fails))
  vim.cmd("cquit 1")
end

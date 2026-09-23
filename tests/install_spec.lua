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
local function stub_release(opts)
  Install._curl = function(args)
    local url = args[#args]
    if url:find("SHA256SUMS", 1, true) then
      if opts.sums == false then return "", false end
      local hash = opts.bad_hash and string.rep("0", 64)
        or vim.fn.system({ "shasum", "-a", "256", opts.served }):match("^(%x+)")
      return hash .. "  jupynvim-core-" .. tostring(target) .. "\n", true
    end
    if opts.fail then return "curl: (22) 404", false end
    local out
    for i, a in ipairs(args) do if a == "-o" then out = args[i + 1] end end
    vim.fn.system({ "cp", opts.served, out })
    return "", true
  end
end

if target then
  local served = tmp .. "/served-binary"
  fake_binary(served, VERSION)

  stub_release({ served = served })
  local rok, rerr = pcall(Install.run, { path = PACK })
  chk("a verified download is installed", rok and vim.fn.executable(final) == 1, tostring(rerr))
  chk("no partial download is left behind", vim.fn.filereadable(final .. ".download") == 0)

  -- a bad release must leave the working binary alone
  local before = io.open(final):read("*a")
  stub_release({ served = served, bad_hash = true })
  pcall(Install.run, { path = PACK }, { no_cargo = true })
  chk("a checksum mismatch leaves the installed binary untouched",
      io.open(final):read("*a") == before and vim.fn.filereadable(final .. ".download") == 0)

  stub_release({ served = served, fail = true })
  local fok, ferr = pcall(Install.run, { path = PACK }, { no_cargo = true })
  chk("a failed download with no_cargo says how to fix it, without building",
      not fok and tostring(ferr):find(":JupynvimInstall", 1, true) ~= nil, tostring(ferr))
  os.remove(final)
else
  io.write("  skip run(): no prebuilt target for this machine\n")
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

os.remove(final)
fresh(false); install_stub(VERSION)
local nok, nerr = pcall(J._locate_core)
chk("auto_install = false downloads nothing", runs == 0)
chk("and the error says what to run", not nok and tostring(nerr):find(":JupynvimInstall", 1, true) ~= nil,
    tostring(nerr))

-- opening a notebook with no backend reports it instead of throwing
local notes = {}
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

J._plugin_root, RepoInstall.run = real_root, real_run
vim.fn.delete(tmp, "rf")

if fails == 0 then
  io.write("\nALL INSTALL CHECKS PASSED\n")
  vim.cmd("qa!")
else
  io.write(("\nINSTALL: %d CHECK(S) FAILED\n"):format(fails))
  vim.cmd("cquit 1")
end

-- Download prebuilt jupynvim-core binary from GitHub releases.
--
-- Used by the lazy.nvim `build` hook, a vim.pack or mini.deps install hook,
-- :JupynvimInstall, and the install on first use when the binary is missing,
-- so users don't need a Rust toolchain. Falls back to cargo build when the
-- platform is unsupported, the binary isn't published for the current tag,
-- or the download fails.
--
-- The in-process library (libjupynvim) comes with the same install: the
-- same release and SHA256SUMS, then a check in a Neovim of its own that it
-- loads here before it is renamed into place. It is optional, so nothing
-- about it ever fails the install of the core.

local M = {}

local REPO = "sheng-tse/jupynvim"

-- Where every release asset is downloaded from: the GitHub release, or
-- JUPYNVIM_RELEASE_BASE (a mirror, a cluster without access to GitHub, or a
-- file:// release on disk), under which each tag is a directory.
function M._release_base()
  local base = os.getenv("JUPYNVIM_RELEASE_BASE")
  base = base and base:gsub("/+$", "") or ""
  if base ~= "" then return base end
  return ("https://github.com/%s/releases/download"):format(REPO)
end

-- The base when the installer may download from it, else nil and why. Over
-- plain http, or any other scheme curl knows, anyone on the path could
-- replace an asset and SHA256SUMS alike, and the check would prove nothing.
local BASE_SCHEMES = "JUPYNVIM_RELEASE_BASE must start with https:// or file://"
function M._release_base_ok()
  local base = M._release_base()
  local lower = base:lower()
  if lower:find("^https://") or lower:find("^file://") then return base end
  return nil, BASE_SCHEMES
end
-- Every installer curl: https or file only, and a redirect (GitHub's
-- release links redirect) to https only.
local PROTO = { "--proto", "=https,file", "--proto-redir", "=https" }
local function curl_argv(...)
  local argv = { "curl" }
  vim.list_extend(argv, PROTO)
  vim.list_extend(argv, { ... })
  return argv
end
-- A base the installer refuses: one ERROR notice, nothing downloaded.
local function refuse_base(why)
  vim.notify(("jupynvim: %s (it is %s); nothing was downloaded"):format(why,
    tostring(os.getenv("JUPYNVIM_RELEASE_BASE"))), vim.log.levels.ERROR)
end

-- The plugin directory this file sits in, found by walking up to the
-- plugin's own entry point. It is right for every layout: lazy.nvim,
-- vim.pack's site/pack/core/opt, packer, mini.deps, a manual clone.
local function own_root()
  local src = debug.getinfo(1, "S").source
  if src:sub(1, 1) == "@" then src = src:sub(2) end
  local dir = vim.fn.fnamemodify(src, ":p:h")
  for _ = 1, 8 do
    if vim.fn.filereadable(dir .. "/lua/jupynvim/init.lua") == 1 then return dir end
    local up = vim.fn.fnamemodify(dir, ":h")
    if up == dir then break end
    dir = up
  end
  return nil
end

-- What run() may be handed: lazy's plugin spec ({ dir }), vim.pack's
-- PackChanged data or mini.deps' hook params ({ path }), a path, or nothing.
-- Nothing used to mean ~/.local/share/nvim/lazy/jupynvim, which is wrong for
-- every other manager and even for lazy under NVIM_APPNAME.
local function resolve_dir(plugin)
  if type(plugin) == "string" and plugin ~= "" then return plugin end
  if type(plugin) == "table" and (plugin.dir or plugin.path) then
    return plugin.dir or plugin.path
  end
  return own_root()
end
M._resolve_dir = resolve_dir

-- The backend version this copy of the plugin was released with.
function M.source_version(plugin_dir)
  local f = io.open(plugin_dir .. "/core/Cargo.toml", "r")
  if not f then return nil end
  for line in f:lines() do
    local v = line:match('^version%s*=%s*"([^"]+)"')
    if v then f:close(); return v end
  end
  f:close()
  return nil
end

-- Release assets this machine can use, best first. Linux gets the static musl
-- build first: the glibc one is built on a current Ubuntu and needs a glibc
-- as new as that, which rules out most servers and HPC login nodes. Releases
-- before the musl build only have the glibc name, so it stays second.
local PUBLISHED = {
  ["aarch64-apple-darwin"] = true,
  ["x86_64-unknown-linux-musl"] = true,
  ["x86_64-unknown-linux-gnu"] = true,
}
local function detect_targets()
  local u = vim.uv.os_uname()
  local sys, mach = u.sysname, u.machine
  local want = {}
  if sys == "Darwin" and mach == "arm64" then
    want = { "aarch64-apple-darwin" }
  elseif sys == "Linux" and mach == "x86_64" then
    want = { "x86_64-unknown-linux-musl", "x86_64-unknown-linux-gnu" }
  end
  return vim.tbl_filter(function(t) return PUBLISHED[t] end, want)
end
local function detect_target() return detect_targets()[1] end

-- A prebuilt that downloaded and verified but would not run here, remembered
-- per tag and target so the install on first use does not fetch it again in
-- every session. Build hooks and :JupynvimInstall try again regardless, and
-- one that then runs clears its entry.
local function failed_file() return vim.fn.stdpath("state") .. "/jupynvim/prebuilt_failed.json" end
local function failed_load()
  local f = io.open(failed_file(), "r")
  if not f then return {} end
  local ok, t = pcall(vim.json.decode, f:read("*a")); f:close()
  return (ok and type(t) == "table") and t or {}
end
local function failed_save(t)
  pcall(vim.fn.mkdir, vim.fn.stdpath("state") .. "/jupynvim", "p")
  local f = io.open(failed_file(), "w")
  if f then f:write(vim.json.encode(t)); f:close() end
end
-- A verdict is a string, kept for the tag, or { reason, at, ttl } for one
-- that may change (a library the release does not publish yet), forgotten
-- ttl seconds after it was found. One from the future was found while the
-- clock was ahead (set wrong at boot, corrected since) and is forgotten
-- too: kept, it would hold until the clock caught up.
M._now = os.time
M.LIB_RECHECK_S = 86400
function M.known_bad(tag, target)
  local v = failed_load()[tag .. "|" .. target]
  if type(v) == "table" then
    local at, ttl = tonumber(v.at), tonumber(v.ttl)
    if not at or not ttl then return nil end
    local age = M._now() - at
    if age < 0 or age >= ttl then return nil end
    return v.reason
  end
  return v
end
local function remember_bad(key, reason, ttl)
  local t = failed_load()
  t[key] = ttl and { reason = reason, at = M._now(), ttl = ttl } or reason
  failed_save(t)
end
local function forget_bad(key)
  local t = failed_load()
  if t[key] then
    t[key] = nil
    failed_save(t)
  end
end

-- The release tag whose binary matches this copy. core/Cargo.toml names it
-- directly, and it works for copies that are not a git checkout. git describe
-- is the fallback: it walks up to ANY enclosing repository, so a copy vendored
-- into a dotfiles repo got that repo's tag and a 404.
local function detect_tag(plugin_dir)
  local v = M.source_version(plugin_dir)
  if v then return "v" .. v end
  local out = vim.fn.system({ "git", "-C", plugin_dir, "describe", "--tags", "--exact-match" })
  if vim.v.shell_error == 0 then return vim.trim(out) end
  out = vim.fn.system({ "git", "-C", plugin_dir, "describe", "--tags", "--abbrev=0" })
  if vim.v.shell_error == 0 then return vim.trim(out) end
  return nil
end

-- A cargo build leaves its metadata beside the binary, and one of the user's
-- own is never downloaded over. The build below, made because no prebuilt
-- ran here, is not theirs: it carries a stamp of the binary it installed,
-- which a later build of their own no longer matches. Without it, the
-- installer's own fallback turned the plugin into a build nothing updated.
local function stamp_of(bin)
  local st = vim.uv.fs_stat(bin)
  return st and ("%d:%d:%d"):format(st.size, st.mtime.sec, st.mtime.nsec) or nil
end
local function stamp_path(plugin_dir) return plugin_dir .. "/core/target/release/.jupynvim-installed" end
local function stamp_install(plugin_dir)
  local rel = plugin_dir .. "/core/target/release"
  if vim.fn.isdirectory(rel .. "/.fingerprint") ~= 1 then return end
  local f = io.open(stamp_path(plugin_dir), "w")
  if f then f:write(stamp_of(rel .. "/jupynvim-core") or "", "\n"); f:close() end
end
function M.is_dev_build(plugin_dir)
  local rel = plugin_dir .. "/core/target/release"
  if vim.fn.isdirectory(rel .. "/.fingerprint") ~= 1 then return false end
  local f = io.open(stamp_path(plugin_dir), "r")
  if not f then return true end
  local s = f:read("*l"); f:close()
  return s ~= stamp_of(rel .. "/jupynvim-core")
end

-- ── the in-process library (libjupynvim) ────────────────────────────────
-- Neovim loads it into its own process through LuaJIT's FFI, so there is
-- one per OS and CPU, linked against the C library Neovim uses: glibc on
-- Linux (2.17 symbols, so any glibc Linux from 2014 on), the system one on
-- macOS. Keyed by uname's sysname and machine.
local LIB_TARGETS = {
  ["Darwin arm64"]  = { target = "aarch64-apple-darwin",      ext = "dylib" },
  ["Darwin x86_64"] = { target = "x86_64-apple-darwin",       ext = "dylib" },
  ["Linux x86_64"]  = { target = "x86_64-unknown-linux-gnu",  ext = "so" },
  ["Linux aarch64"] = { target = "aarch64-unknown-linux-gnu", ext = "so" },
  ["Linux arm64"]   = { target = "aarch64-unknown-linux-gnu", ext = "so" },
}
local LIB_PUBLISHED = { "Darwin arm64", "Darwin x86_64", "Linux x86_64", "Linux aarch64" }
local function lib_copy(t) return t and { target = t.target, ext = t.ext } or nil end

-- This machine's library prebuilt, { target, ext }, or nil when none is made.
function M._lib_target()
  local u = vim.uv.os_uname()
  return lib_copy(LIB_TARGETS[u.sysname .. " " .. u.machine])
end
-- Every library prebuilt a release publishes.
function M._lib_targets_all()
  local all = {}
  for i, key in ipairs(LIB_PUBLISHED) do all[i] = lib_copy(LIB_TARGETS[key]) end
  return all
end
function M.lib_name()
  return vim.uv.os_uname().sysname == "Darwin" and "libjupynvim.dylib" or "libjupynvim.so"
end
-- Where cargo builds it and the installer puts it, next to jupynvim-core.
function M.lib_path(plugin_dir) return plugin_dir .. "/core/target/release/" .. M.lib_name() end
function M._lib_asset(t) return ("libjupynvim-%s.%s"):format(t.target, t.ext) end

-- The library's stamp: the version it was installed as, then the file's
-- size:mtime it was written for. Without a stamp the file is one you put
-- there, and it is left alone. A stamp the file does not match is an
-- install that did not finish, and the library is installed again.
local function lib_stamp_path(plugin_dir) return plugin_dir .. "/core/target/release/.libjupynvim-installed" end
local function lib_stamp_read(plugin_dir)
  local f = io.open(lib_stamp_path(plugin_dir), "r")
  if not f then return nil end
  local text = f:read("*a"); f:close()
  return text
end
-- Written whole under a name of its own and renamed in, so a reader never
-- sees half a stamp.
local function lib_stamp_write(plugin_dir, text)
  local path = lib_stamp_path(plugin_dir)
  local part = ("%s.%d"):format(path, vim.fn.getpid())
  local f = io.open(part, "w")
  if not f then return false end
  f:write(text); f:close()
  if not os.rename(part, path) then
    os.remove(part)
    return false
  end
  return true
end
local function lib_stamp_text(version, fp) return tostring(version) .. "\n" .. fp .. "\n" end
-- Stamp the library now at its place. Checked against the file after
-- writing: two Neovims finishing an install at the same moment both end up
-- describing the file that won.
local function stamp_lib(plugin_dir, version)
  local lib = M.lib_path(plugin_dir)
  for _ = 1, 5 do
    local fp = stamp_of(lib)
    if not fp or not lib_stamp_write(plugin_dir, lib_stamp_text(version, fp)) then return false end
    if stamp_of(lib) == fp then return true end
  end
  return false
end

-- The version the installer put there, or nil (no stamp, or a stamp the
-- file does not match).
function M.lib_installed_version(plugin_dir)
  local text = lib_stamp_read(plugin_dir)
  local version, fp = (text or ""):match("^([^\n]+)\n([^\n]+)")
  if not version then return nil end
  return stamp_of(M.lib_path(plugin_dir)) == fp and version or nil
end

-- Whether the installer can write the library's place: the nearest of its
-- directories that exists (the install makes the rest).
local function writable_dir(plugin_dir)
  for _, d in ipairs({ "/core/target/release", "/core/target", "/core" }) do
    local p = plugin_dir .. d
    if vim.uv.fs_stat(p) then return vim.uv.fs_access(p, "W") == true end
  end
  return false
end

-- Whether the installer should fetch the library, and why.
function M.lib_needs_install(plugin_dir, want)
  if not M._lib_target() then return false, "no library prebuilt is made for this platform" end
  if M.is_dev_build(plugin_dir) then return false, "a cargo build of yours builds it" end
  -- a system package or a store: the rename would fail in every session
  if not writable_dir(plugin_dir) then return false, "the plugin's directory is not writable" end
  local present = vim.uv.fs_stat(M.lib_path(plugin_dir)) ~= nil
  if present and not lib_stamp_read(plugin_dir) then return false, "a library you put there" end
  if not present then return true, "missing" end
  local have = M.lib_installed_version(plugin_dir)
  if not have then return true, "it changed after it was installed, or its install did not finish" end
  if want and have ~= want then return true, ("is v%s, the plugin is v%s"):format(have, want) end
  return false, "v" .. have .. " is installed"
end

-- After an install in this Neovim put the library in place: a loader that
-- already looked and found it missing (a :checkhealth, a first use) looks
-- again on its next use, so the install needs no restart. Only a loader
-- that is loaded already; the installer never loads it.
local function loader_look_again()
  local N = package.loaded["jupynvim.native"]
  if type(N) == "table" and type(N._forget_missing) == "function" then pcall(N._forget_missing) end
end

local function build_from_source(plugin_dir, opts, why)
  if opts.no_cargo then
    error(("jupynvim: could not install the prebuilt jupynvim-core (%s). " ..
      "Run :JupynvimInstall to build it with cargo, or set core_path."):format(why), 0)
  end
  if vim.fn.executable("cargo") ~= 1 then
    error(("jupynvim: no prebuilt jupynvim-core could be installed (%s) and cargo is " ..
      "not on PATH. Install a Rust toolchain and run :JupynvimInstall, or set core_path.")
      :format(why), 0)
  end
  local manifest = plugin_dir .. "/core/Cargo.toml"
  vim.notify("jupynvim: building from source via cargo (" .. why .. ")",
    vim.log.levels.INFO)
  local out = vim.fn.system({ "cargo", "build", "--release", "--manifest-path", manifest })
  if vim.v.shell_error ~= 0 then
    error(("jupynvim: cargo build failed: %s"):format(out))
  end
  stamp_install(plugin_dir)
  -- the workspace builds the library too; this build is the installer's,
  -- so a later release replaces it like any library the installer put there
  if vim.uv.fs_stat(M.lib_path(plugin_dir)) then
    stamp_lib(plugin_dir, M.source_version(plugin_dir))
    loader_look_again()
  end
end

-- sha256 of a file via shasum (macOS + most Linux) or sha256sum. nil if
-- neither answers: through vim.system, which a missing tool makes fail
-- (vim.fn.system raises E475 for it instead).
local function sha256_of(path)
  for _, cmd in ipairs({ { "shasum", "-a", "256", path }, { "sha256sum", path } }) do
    local ok, r = pcall(function() return vim.system(cmd, { text = true }):wait(30000) end)
    local hex = ok and r and r.code == 0 and (r.stdout or ""):match("^(%x+)")
    if hex then return hex:lower() end
  end
  return nil
end

-- Find the expected hash for `artifact` in a SHA256SUMS blob. Handles both the
-- "<hash>  name" and "<hash> *name" (binary-mode) formats. Exposed for tests.
function M._expected_hash(sums_text, artifact)
  for line in (sums_text .. "\n"):gmatch("(.-)\n") do
    local hash, name = line:match("^(%x+)%s+%*?(.-)%s*$")
    if name and (name == artifact or name:match("/" .. artifact .. "$")) then
      return hash:lower()
    end
  end
  return nil
end

-- Verify `dest` against the release's published SHA256SUMS.
--   true       -> verified
--   false, why -> check failed: hash mismatch, or the release publishes a
--                 SHA256SUMS that does not list this binary. caller MUST refuse.
--   nil,  why  -> nothing to check against (no SHA256SUMS published, one
--                 that could not be fetched, no shasum tool). The core
--                 proceeds with a warning; the library is refused.
-- `artifact` is the asset's name, jupynvim-core-<target> unless given.
local function verify_checksum(dest, tag, target, artifact)
  artifact = artifact or ("jupynvim-core-" .. target)
  local sums_url = M._release_base() .. "/" .. tag .. "/SHA256SUMS"
  local sums, got = M._curl(curl_argv("-fsSL", "--connect-timeout", "10", "--max-time", "30",
                                      "--max-filesize", "1048576", "--retry", "2", "--retry-delay", "1", sums_url))
  if not got then
    -- a 404 (or, from a release on disk, curl's exit 37) is a release that
    -- publishes none; anything else is the network, said as such
    local out = vim.trim(sums or "")
    if out:find("returned error: 404%f[%D]") or (M._release_base():find("^file://") and out:find("(37)", 1, true)) then
      return nil, "no SHA256SUMS published for " .. tag
    end
    return nil, "SHA256SUMS could not be fetched (" .. (out:match("[^\n]*$") or "") .. ")"
  end
  -- A release that publishes SHA256SUMS lists every binary it ships, so an
  -- unlisted one is as untrustworthy as a mismatch. Fail closed, do not skip.
  local expected = M._expected_hash(sums, artifact)
  if not expected then return false, "binary not listed in published SHA256SUMS" end
  if vim.fn.filereadable(dest) ~= 1 then return false, "the download is gone" end
  local actual = sha256_of(dest)
  if not actual then return nil, "no shasum/sha256sum available" end
  if actual ~= expected then
    return false, ("expected %s, got %s"):format(expected, actual)
  end
  return true
end

-- The core: a prebuilt, else a cargo build, else the core's error. True on
-- a prebuilt, false after a cargo build; throws when neither worked.
local function run_core(plugin_dir, opts)
  local tag = detect_tag(plugin_dir)
  local targets = detect_targets()
  if #targets == 0 then
    local u = vim.uv.os_uname()
    build_from_source(plugin_dir, opts, "no prebuilt for " .. u.sysname .. " " .. u.machine)
    return false
  end
  if not tag then
    build_from_source(plugin_dir, opts, "no release tag found")
    return false
  end

  local dest_dir = plugin_dir .. "/core/target/release"
  pcall(vim.fn.mkdir, dest_dir, "p")
  local final = dest_dir .. "/jupynvim-core"
  local want = M.source_version(plugin_dir)
  local why = {}
  for _, target in ipairs(targets) do
    -- only the install on first use skips one that did not run before
    local reason = opts.no_cargo and not opts.force and M.known_bad(tag, target)
    local next_one
    if not reason then
      local ok
      ok, reason, next_one = M._fetch(tag, target, final, want)
      if ok then
        stamp_install(plugin_dir)
        vim.notify(("jupynvim: prebuilt %s installed"):format(target), vim.log.levels.INFO)
        return true
      end
    end
    why[#why + 1] = target .. ": " .. reason
    -- Only a release that does not publish this asset moves on to the next
    -- one. After a network error the next download would wait out the same
    -- timeouts, and the glibc asset is a copy of the musl one from the
    -- release that publishes both, so one that did not run will not either.
    if not next_one then break end
  end
  build_from_source(plugin_dir, opts, table.concat(why, "; "))
  return false
end

-- Main entry. `plugin` is anything resolve_dir accepts. opts.no_cargo: fail
-- instead of starting a cargo build, for the install on first use, which must
-- not block opening a notebook for minutes. opts.lib_later: install the core
-- only; the install on first use fetches the library in the background
-- after it, so nothing is added to the wait before the notebook opens.
-- Returns true on prebuilt-download success, false if it fell back to cargo.
--
-- The library's install does not depend on the core's: macOS x86_64 and
-- Linux arm64 get a library prebuilt but no core prebuilt, and a core that
-- could not be installed leaves the library just as useful. So the library
-- comes after the core whatever happened to it (it never throws), and then
-- the core's error, if any, is raised. After a cargo build it is not forced:
-- cargo built and stamped the library, which a forced download would
-- replace (and, with no library in the release, warn about).
function M.run(plugin, opts)
  opts = opts or {}
  local plugin_dir = resolve_dir(plugin)
  if not plugin_dir or vim.fn.filereadable(plugin_dir .. "/core/Cargo.toml") ~= 1 then
    error("jupynvim: install: not a jupynvim checkout: " .. tostring(plugin_dir), 0)
  end
  local ok, res = pcall(run_core, plugin_dir, opts)
  if not opts.lib_later then
    local built = ok and res == false
    M.run_lib(plugin_dir, { force = opts.force and not built, no_cargo = opts.no_cargo })
  end
  if not ok then error(res, 0) end
  return res
end

-- Download one release asset, check it, and rename it into place. Returns
-- true, or false, why, and whether the release just does not publish it.
-- The file lands beside the binary under a name of
-- its own and is renamed in only once it has verified AND run here. Writing
-- the final path directly left a partial binary behind when a download
-- failed, truncated the one a running backend was executing, and two nvims
-- installing at once clobbered each other's download.
function M._fetch(tag, target, final, want)
  local okb, bwhy = M._release_base_ok()
  if not okb then
    refuse_base(bwhy)
    return false, bwhy
  end
  local url = M._url_for(tag, target)
  local dest = ("%s.download.%d"):format(final, vim.fn.getpid())
  vim.notify(("jupynvim: downloading prebuilt binary %s (%s)..."):format(tag, target),
    vim.log.levels.INFO)
  local out, fetched = M._curl(curl_argv(
    "-fsSL", "--connect-timeout", "10", "--max-time", "300", "--max-filesize", "67108864",
    "--retry", "3", "--retry-delay", "2", "-o", dest, url))
  if not fetched then
    vim.fn.delete(dest)
    -- curl 8 over HTTP/2 exits 56 on a 404, not 22, so go by what it says.
    -- Its retries repeat the same line; the last one is enough.
    out = vim.trim(out or "")
    return false, "download failed (" .. (out:match("[^\n]*$") or "") .. ")",
      out:find("returned error: 404%f[%D]") ~= nil
  end

  -- Integrity check. The download came over TLS, but TLS only protects transit,
  -- not whether the artifact on the release is the real one. Verify it against
  -- the release's SHA256SUMS. Fail closed on a mismatch or an unlisted binary;
  -- only when no SHA256SUMS is published at all do we warn and proceed, so
  -- releases that predate the check still install.
  local vok, vwhy = verify_checksum(dest, tag, target)
  if vok == false then
    vim.fn.delete(dest)
    vim.notify(("jupynvim: SHA256 integrity check failed (%s). Refusing the prebuilt."):format(vwhy),
      vim.log.levels.ERROR)
    return false, "checksum: " .. vwhy
  elseif vok == nil then
    vim.notify(("jupynvim: checksum not verified (%s)"):format(vwhy), vim.log.levels.WARN)
  else
    vim.notify("jupynvim: checksum verified", vim.log.levels.INFO)
  end

  vim.fn.system({ "chmod", "+x", dest })
  -- macOS gatekeeper rejects unsigned downloaded binaries by default. Clear
  -- the quarantine attribute so the binary runs without "developer cannot
  -- be verified" prompts.
  if vim.uv.os_uname().sysname == "Darwin" then
    vim.fn.system({ "xattr", "-cr", dest })
  end
  -- It has to run here. A verified binary can still need a newer glibc than
  -- the host has, and renaming that in only turned "missing" into "broken".
  local ran = M._run_version(dest)
  if not ran.version or (want and ran.version ~= want) then
    vim.fn.delete(dest)
    local reason = ran.version and ("it is v" .. ran.version .. ", not v" .. tostring(want))
      or ("it does not run here: " .. (ran.err ~= "" and ran.err or "no output"))
    -- a first run that was slow, or killed, says nothing about the binary
    if not ran.transient then
      local t = failed_load()
      t[tag .. "|" .. target] = reason
      failed_save(t)
    end
    return false, reason
  end
  local rok, rerr = os.rename(dest, final)
  if not rok then
    vim.fn.delete(dest)
    return false, "could not replace " .. final .. ": " .. tostring(rerr)
  end
  local t = failed_load()
  if t[tag .. "|" .. target] then
    t[tag .. "|" .. target] = nil
    failed_save(t)
  end
  return true
end

-- `bin --version`, as { version = "0.4.5" } or { err = first line of stderr }.
-- `transient` is set when the process was killed, by the wait giving up after
-- 5s or by something else, which says nothing about the binary. Antivirus
-- scanning a new file or a loaded network filesystem can make a first run
-- that slow.
function M._run_version(bin)
  local ok, res = pcall(function()
    return vim.system({ bin, "--version" }, { text = true }):wait(5000)
  end)
  if not ok then return { err = tostring(res) } end
  if not res or res.signal == 9 then return { err = "no answer within 5s", transient = true } end
  local v = res.code == 0 and (res.stdout or ""):match("jupynvim%-core%s+(%S+)") or nil
  return { version = v, err = vim.trim(((res.stderr or ""):match("[^\n]+")) or "") }
end

-- The download itself, separate so tests can stand in for the network.
-- Returns the output and whether curl succeeded.
function M._curl(args)
  local out = vim.fn.system(args)
  return out, vim.v.shell_error == 0
end

-- The URL run() downloads the core from (exposed for tests).
function M._url_for(tag, target)
  return M._release_base() .. "/" .. tag .. "/jupynvim-core-" .. target
end

-- ── installing the library ──────────────────────────────────────────────

-- Check a library in a Neovim of its own: it must load, pass the ABI and
-- struct layout checks and tell its version. A library that does not load
-- can take the process that tries down with it, and that must never be the
-- user's editor. { version, abi } or { err }; `transient` when the probe
-- could not start (vim.v.progpath gone after Neovim was upgraded under a
-- running session, no process slot free) or gave no answer in time
-- (killed), neither of which says anything about the library.
function M._probe_lib(path, plugin_dir)
  local ok, res = pcall(function()
    return vim.system({ vim.v.progpath, "--clean", "--headless", "-l",
      plugin_dir .. "/lua/jupynvim/backend/native_probe.lua", path, plugin_dir }, { text = true }):wait(10000)
  end)
  if not ok then return { err = "the probe could not start: " .. tostring(res), transient = true } end
  if not res or res.signal == 9 then return { err = "no answer within 10s", transient = true } end
  local out = res.stdout or ""
  local version, abi = out:match("jnv%-probe ok (%S+) (%S+)")
  if version then return { version = version, abi = abi } end
  local why = out:match("jnv%-probe err ([^\n]+)")
    or vim.trim(((res.stderr or ""):match("[^\n]+")) or "")
  if why == "" then
    why = (res.signal and res.signal ~= 0) and ("the probe stopped on signal " .. res.signal)
      or ("the probe said nothing (exit " .. tostring(res.code) .. ")")
  end
  return { err = why }
end

-- Download the library of `tag` for target `t`, check it and rename it into
-- `final`. Returns true, or false, why, and whether the release just does
-- not publish it. Like the core it lands beside its place under a name of
-- its own and is renamed in only once it has verified and loaded. Renaming
-- also keeps a running Neovim safe: it has the old file mapped, and that
-- file stays as it was.
function M._fetch_lib(tag, t, final, want, plugin_dir)
  local okb, bwhy = M._release_base_ok()
  if not okb then
    refuse_base(bwhy)
    return false, bwhy
  end
  local asset = M._lib_asset(t)
  local dest = ("%s.download.%d"):format(final, vim.fn.getpid())
  vim.notify(("jupynvim: downloading libjupynvim %s (%s)..."):format(tag, t.target), vim.log.levels.INFO)
  local out, fetched = M._curl(curl_argv(
    "-fsSL", "--connect-timeout", "10", "--max-time", "300", "--max-filesize", "67108864",
    "--retry", "3", "--retry-delay", "2", "-o", dest, M._release_base() .. "/" .. tag .. "/" .. asset))
  if not fetched then
    vim.fn.delete(dest)
    out = vim.trim(out or "")
    -- A release on disk (a file:// mirror) answers an asset it lacks with
    -- curl's exit 37 (it cannot read the file), not a 404.
    local absent = out:find("returned error: 404%f[%D]")
      or (M._release_base():find("^file://") and out:find("(37)", 1, true))
    if absent then return false, "not published in " .. tag, true end
    return false, "download failed (" .. (out:match("[^\n]*$") or "") .. ")"
  end

  -- The library loads into Neovim's own process, and every release that
  -- has one publishes SHA256SUMS: one that cannot be checked is refused like
  -- a mismatch, never installed with a warning, and never remembered, so a
  -- mirror that gains SHA256SUMS works the next time.
  local vok, vwhy = verify_checksum(dest, tag, nil, asset)
  if vok ~= true then vim.fn.delete(dest) end
  if vok == false then
    vim.notify(("jupynvim: SHA256 integrity check failed for %s (%s). Refusing it."):format(asset, vwhy),
      vim.log.levels.ERROR)
    return false, "checksum: " .. vwhy
  elseif vok == nil then
    vim.notify(("jupynvim: %s could not be verified (%s). Refusing it."):format(asset, vwhy), vim.log.levels.ERROR)
    return false, "checksum: not verified, " .. vwhy
  end
  if vim.uv.os_uname().sysname == "Darwin" then
    pcall(function() vim.system({ "xattr", "-cr", dest }):wait(10000) end)
  end

  local key = tag .. "|lib-" .. t.target
  local p = M._probe_lib(dest, plugin_dir)
  if not p.version or (want and p.version ~= want) then
    vim.fn.delete(dest)
    local reason
    if p.version then
      reason = "it is v" .. p.version .. ", not v" .. tostring(want)
    else
      -- the download's own name means nothing once it is gone
      local err = tostring(p.err):gsub("^at " .. vim.pesc(dest) .. " ", ""):gsub(vim.pesc(dest), asset)
      -- a probe that could not start or gave no answer never checked it
      reason = (p.transient and "could not be checked here: " or "does not load here: ") .. err
    end
    if not p.transient then remember_bad(key, reason) end
    return false, reason
  end

  -- Stamped before the rename, for the file about to land (a rename keeps
  -- its size and mtime): an install cut short between the two leaves a
  -- stamp the file does not match, and the next one installs it again.
  local old_stamp = lib_stamp_read(plugin_dir)
  local fp = stamp_of(dest)
  if fp then lib_stamp_write(plugin_dir, lib_stamp_text(p.version, fp)) end
  local rok, rerr = os.rename(dest, final)
  if not rok then
    vim.fn.delete(dest)
    if old_stamp then lib_stamp_write(plugin_dir, old_stamp) else os.remove(lib_stamp_path(plugin_dir)) end
    return false, "could not replace " .. final .. ": " .. tostring(rerr)
  end
  stamp_lib(plugin_dir, p.version)
  forget_bad(key)
  return true
end

-- Install the library from the release this copy matches. Never throws: it
-- is optional, and nothing may fail the core's install over it. Returns
-- true when it is in place or there is nothing to install, else false and
-- why. Without opts.force it skips a library that needs nothing and one this
-- release does not publish or that did not load here before; opts.force
-- (:JupynvimInstall) fetches it regardless. opts.no_cargo is accepted for
-- symmetry with run(): the library is never built here.
function M.run_lib(plugin, opts)
  opts = opts or {}
  local ok, res, why = pcall(function()
    local plugin_dir = resolve_dir(plugin)
    if not plugin_dir or vim.fn.filereadable(plugin_dir .. "/core/Cargo.toml") ~= 1 then
      return false, "not a jupynvim checkout: " .. tostring(plugin_dir)
    end
    local t = M._lib_target()
    if not t then return true, "no library prebuilt is made for this platform" end
    local want = M.source_version(plugin_dir)
    if not opts.force then
      local need, nwhy = M.lib_needs_install(plugin_dir, want)
      if not need then return true, nwhy end
    end
    local tag = detect_tag(plugin_dir)
    if not tag then return false, "no release tag found" end
    local key = tag .. "|lib-" .. t.target
    if not opts.force then
      local bad = M.known_bad(tag, "lib-" .. t.target)
      if bad then return false, bad end
    end
    local final = M.lib_path(plugin_dir)
    pcall(vim.fn.mkdir, vim.fs.dirname(final), "p")
    local fok, reason, not_published = M._fetch_lib(tag, t, final, want, plugin_dir)
    if fok then
      loader_look_again()
      vim.notify(("jupynvim: libjupynvim %s installed"):format(t.target), vim.log.levels.INFO)
      return true
    end
    -- a release without it: first opens stop asking, for a day (a mirror
    -- that synced the core first, a release still uploading its assets)
    if not_published then remember_bad(key, reason, M.LIB_RECHECK_S) end
    return false, reason
  end)
  if not ok then res, why = false, tostring(res) end
  if not res then
    vim.notify(("jupynvim: libjupynvim not installed (%s); everything works without it"):format(tostring(why)),
      vim.log.levels.WARN)
  end
  return res, why
end

-- The library's install in a Neovim of its own, for a first notebook opened
-- with a current core and no library: the download and the probe never
-- block the editor. on_done(ok, output) runs on the main loop. Returns
-- whether the install started.
function M.run_lib_background(plugin_dir, on_done)
  local ok, err = pcall(vim.system, {
    vim.v.progpath, "--clean", "--headless", "-l",
    plugin_dir .. "/lua/jupynvim/backend/install_lib_job.lua", plugin_dir,
  }, { text = true }, function(res)
    vim.schedule(function()
      local out, errs = vim.trim(res.stdout or ""), vim.trim(res.stderr or "")
      local msg = (out ~= "" and errs ~= "") and (out .. "\n" .. errs) or (out .. errs)
      if on_done then on_done(res.code == 0 and out:find("jnv-lib ok", 1, true) ~= nil, msg) end
    end)
  end)
  if not ok then return false, tostring(err) end
  return true
end

M._detect_target = detect_target
M._detect_targets = detect_targets
M._published = PUBLISHED
M._detect_tag = detect_tag
M._own_root = own_root

return M

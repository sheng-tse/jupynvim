-- Download prebuilt jupynvim-core binary from GitHub releases.
--
-- Used by the lazy.nvim `build` hook, a vim.pack or mini.deps install hook,
-- :JupynvimInstall, and the install on first use when the binary is missing,
-- so users don't need a Rust toolchain. Falls back to cargo build when the
-- platform is unsupported, the binary isn't published for the current tag,
-- or the download fails.

local M = {}

local REPO = "sheng-tse/jupynvim"

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
-- every session. :JupynvimInstall tries again regardless.
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
function M.known_bad(tag, target) return failed_load()[tag .. "|" .. target] end

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
end

-- sha256 of a file via shasum (macOS + most Linux) or sha256sum. nil if neither.
local function sha256_of(path)
  local out = vim.fn.system({ "shasum", "-a", "256", path })
  if vim.v.shell_error ~= 0 then
    out = vim.fn.system({ "sha256sum", path })
    if vim.v.shell_error ~= 0 then return nil end
  end
  return (out:match("^(%x+)") or ""):lower()
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
--   nil,  why  -> nothing to check against (no SHA256SUMS at all, no shasum
--                 tool); caller may proceed with a warning.
local function verify_checksum(dest, tag, target)
  local sums_url = string.format(
    "https://github.com/%s/releases/download/%s/SHA256SUMS", REPO, tag)
  local sums, got = M._curl({ "curl", "-fsSL", "--connect-timeout", "10", "--max-time", "30",
                              "--retry", "2", "--retry-delay", "1", sums_url })
  if not got then
    return nil, "no SHA256SUMS published for " .. tag
  end
  -- A release that publishes SHA256SUMS lists every binary it ships, so an
  -- unlisted one is as untrustworthy as a mismatch. Fail closed, do not skip.
  local expected = M._expected_hash(sums, "jupynvim-core-" .. target)
  if not expected then return false, "binary not listed in published SHA256SUMS" end
  if vim.fn.filereadable(dest) ~= 1 then return false, "the download is gone" end
  local actual = sha256_of(dest)
  if not actual then return nil, "no shasum/sha256sum available" end
  if actual ~= expected then
    return false, ("expected %s, got %s"):format(expected, actual)
  end
  return true
end

-- Main entry. `plugin` is anything resolve_dir accepts. opts.no_cargo: fail
-- instead of starting a cargo build, for the install on first use, which must
-- not block opening a notebook for minutes.
-- Returns true on prebuilt-download success, false if it fell back to cargo.
function M.run(plugin, opts)
  opts = opts or {}
  local plugin_dir = resolve_dir(plugin)
  if not plugin_dir or vim.fn.filereadable(plugin_dir .. "/core/Cargo.toml") ~= 1 then
    error("jupynvim: install: not a jupynvim checkout: " .. tostring(plugin_dir), 0)
  end

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
    local bad = not opts.force and M.known_bad(tag, target)
    if bad then
      why[#why + 1] = target .. ": " .. bad
    else
      local ok, reason = M._fetch(tag, target, final, want)
      if ok then
        vim.notify(("jupynvim: prebuilt %s installed"):format(target), vim.log.levels.INFO)
        return true
      end
      why[#why + 1] = target .. ": " .. reason
    end
  end
  build_from_source(plugin_dir, opts, table.concat(why, "; "))
  return false
end

-- Download one release asset, check it, and rename it into place. Returns
-- true, or false and why. The file lands beside the binary under a name of
-- its own and is renamed in only once it has verified AND run here. Writing
-- the final path directly left a partial binary behind when a download
-- failed, truncated the one a running backend was executing, and two nvims
-- installing at once clobbered each other's download.
function M._fetch(tag, target, final, want)
  local url = string.format("https://github.com/%s/releases/download/%s/jupynvim-core-%s",
    REPO, tag, target)
  local dest = ("%s.download.%d"):format(final, vim.fn.getpid())
  vim.notify(("jupynvim: downloading prebuilt binary %s (%s)..."):format(tag, target),
    vim.log.levels.INFO)
  local out, fetched = M._curl({
    "curl", "-fsSL", "--connect-timeout", "10", "--max-time", "300",
    "--retry", "3", "--retry-delay", "2", "-o", dest, url,
  })
  if not fetched then
    vim.fn.delete(dest)
    return false, "download failed (" .. vim.trim(out or "") .. ")"
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
    local t = failed_load()
    t[tag .. "|" .. target] = reason
    failed_save(t)
    return false, reason
  end
  local rok, rerr = os.rename(dest, final)
  if not rok then
    vim.fn.delete(dest)
    return false, "could not replace " .. final .. ": " .. tostring(rerr)
  end
  return true
end

-- `bin --version`, as { version = "0.4.5" } or { err = first line of stderr }.
function M._run_version(bin)
  local ok, res = pcall(function()
    return vim.system({ bin, "--version" }, { text = true }):wait(5000)
  end)
  if not ok or not res then return { err = tostring(res) } end
  local v = res.code == 0 and (res.stdout or ""):match("jupynvim%-core%s+(%S+)") or nil
  return { version = v, err = vim.trim(((res.stderr or ""):match("[^\n]+")) or "") }
end

-- The download itself, separate so tests can stand in for the network.
-- Returns the output and whether curl succeeded.
function M._curl(args)
  local out = vim.fn.system(args)
  return out, vim.v.shell_error == 0
end

-- Exposed for testing: just the URL the run() would download.
function M._url_for(tag, target)
  return string.format(
    "https://github.com/%s/releases/download/%s/jupynvim-core-%s",
    REPO, tag, target
  )
end

M._detect_target = detect_target
M._detect_targets = detect_targets
M._published = PUBLISHED
M._detect_tag = detect_tag
M._own_root = own_root

return M

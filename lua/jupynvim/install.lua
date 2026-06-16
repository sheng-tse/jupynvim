-- Download prebuilt jupynvim-core binary from GitHub releases.
--
-- Used by the lazy.nvim `build` hook so users don't need a Rust toolchain.
-- Falls back to cargo build when the platform is unsupported, the binary
-- isn't published for the current tag, or the download fails.

local M = {}

local REPO = "sheng-tse/jupynvim"

-- Map vim.uv.os_uname() to Rust target triple matching CI artifact names.
local function detect_target()
  local u = vim.uv.os_uname()
  local sys = u.sysname    -- "Darwin", "Linux"
  local mach = u.machine   -- "arm64", "aarch64", "x86_64"
  if sys == "Darwin" then
    if mach == "arm64" then return "aarch64-apple-darwin" end
    if mach == "x86_64" then return "x86_64-apple-darwin" end
  elseif sys == "Linux" then
    if mach == "x86_64" then return "x86_64-unknown-linux-gnu" end
    if mach == "aarch64" then return "aarch64-unknown-linux-gnu" end
  end
  return nil
end

-- Get the plugin's currently-checked-out tag. Lazy.nvim usually checks out
-- a specific tag for users who pin one; defaults to the latest tag for
-- users who track main without pinning.
local function detect_tag(plugin_dir)
  local out = vim.fn.system({ "git", "-C", plugin_dir, "describe", "--tags", "--exact-match" })
  if vim.v.shell_error == 0 then return vim.trim(out) end
  out = vim.fn.system({ "git", "-C", plugin_dir, "describe", "--tags", "--abbrev=0" })
  if vim.v.shell_error == 0 then return vim.trim(out) end
  return nil
end

local function build_from_source(plugin_dir)
  local manifest = plugin_dir .. "/core/Cargo.toml"
  vim.notify("jupynvim: building from source via cargo (no prebuilt available)",
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
--   false, why -> mismatch (caller MUST refuse the binary)
--   nil,  why  -> can't verify (no SHA256SUMS / no tool); caller may proceed
local function verify_checksum(dest, tag, target)
  local sums_url = string.format(
    "https://github.com/%s/releases/download/%s/SHA256SUMS", REPO, tag)
  local sums = vim.fn.system({ "curl", "-fsSL", "--retry", "2", "--retry-delay", "1", sums_url })
  if vim.v.shell_error ~= 0 then
    return nil, "no SHA256SUMS published for " .. tag
  end
  local expected = M._expected_hash(sums, "jupynvim-core-" .. target)
  if not expected then return nil, "binary not listed in SHA256SUMS" end
  local actual = sha256_of(dest)
  if not actual then return nil, "no shasum/sha256sum available" end
  if actual ~= expected then
    return false, ("expected %s, got %s"):format(expected, actual)
  end
  return true
end

-- Main entry. Called from the lazy.nvim build hook.
-- plugin: lazy plugin spec (has `.dir`, the install path).
-- Returns true on prebuilt-download success, false if it fell back to cargo.
function M.run(plugin)
  local plugin_dir = (plugin and plugin.dir) or vim.fn.expand("~/.local/share/nvim/lazy/jupynvim")

  local target = detect_target()
  if not target then
    build_from_source(plugin_dir)
    return false
  end

  local tag = detect_tag(plugin_dir)
  if not tag then
    build_from_source(plugin_dir)
    return false
  end

  local url = string.format(
    "https://github.com/%s/releases/download/%s/jupynvim-core-%s",
    REPO, tag, target
  )
  local dest_dir = plugin_dir .. "/core/target/release"
  vim.fn.mkdir(dest_dir, "p")
  local dest = dest_dir .. "/jupynvim-core"

  vim.notify(("jupynvim: downloading prebuilt binary %s..."):format(tag),
    vim.log.levels.INFO)
  local out = vim.fn.system({
    "curl", "-fsSL", "--retry", "3", "--retry-delay", "2",
    "-o", dest, url,
  })
  if vim.v.shell_error ~= 0 then
    vim.notify(("jupynvim: download failed (%s), falling back to cargo build"):format(out),
      vim.log.levels.WARN)
    build_from_source(plugin_dir)
    return false
  end

  -- Integrity check. The download came over TLS, but TLS only protects transit,
  -- not whether the artifact on the release is the real one. Verify it against
  -- the release's SHA256SUMS. Fail closed (build from source) only on a real
  -- mismatch; if no SHA256SUMS is published yet, warn and proceed.
  local vok, vwhy = verify_checksum(dest, tag, target)
  if vok == false then
    vim.fn.delete(dest)
    vim.notify(("jupynvim: SHA256 checksum mismatch (%s). Refusing the prebuilt, building from source."):format(vwhy),
      vim.log.levels.ERROR)
    build_from_source(plugin_dir)
    return false
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

  vim.notify(("jupynvim: prebuilt %s installed"):format(target), vim.log.levels.INFO)
  return true
end

-- Exposed for testing: just the URL the run() would download.
function M._url_for(tag, target)
  return string.format(
    "https://github.com/%s/releases/download/%s/jupynvim-core-%s",
    REPO, tag, target
  )
end

M._detect_target = detect_target
M._detect_tag = detect_tag

return M

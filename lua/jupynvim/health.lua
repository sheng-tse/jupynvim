-- :checkhealth jupynvim
local M = {}

local WITHOUT = "; everything works without it"

-- The in-process library. Checking it loads it, as its first use would,
-- with the first open away from this Neovim first (macOS): this is what the
-- loader's notice says to run, often in a fresh session, so a library that
-- kills the process that loads it, or whose load never returns, is
-- reported here and never loaded into the editor. It never asks for an
-- install. The advice is the loader's own (status().fix), the same text its
-- one notice gives: for a file JUPYNVIM_NATIVE or native.path named, the
-- setting; for the plugin's own place, the install or the rebuild.
function M._library(h, J, Install)
  h.start("jupynvim: in-process library (libjupynvim)")
  local okn, N = pcall(require, "jupynvim.native")
  if not okn then
    h.warn("libjupynvim: the loader failed: " .. tostring(N) .. WITHOUT)
    return
  end
  N._load_waiting()
  local st = N.status()
  if st.state == "ok" then
    local n = tonumber(st.workers) or 0
    h.ok(("libjupynvim v%s (ABI %s) at %s, %d worker thread%s"):format(
      tostring(st.version), tostring(st.abi), tostring(st.path), n, n == 1 and "" or "s"))
  elseif st.state == "missing" and not st.path then
    h.warn("libjupynvim " .. tostring(st.reason) .. WITHOUT)
  elseif st.state == "missing" then
    local msg = "libjupynvim is not installed at " .. st.path .. WITHOUT
    if st.source ~= "plugin" or Install._lib_target() then
      h.warn(msg, { st.fix })
    else
      h.info("no libjupynvim prebuilt is made for this platform; cargo build --release in core/ builds it" .. WITHOUT)
    end
  elseif st.state == "disabled" then
    h.info("libjupynvim is " .. tostring(st.reason))
  elseif st.state == "unsupported" then
    h.info("libjupynvim " .. tostring(st.reason) .. WITHOUT)
  elseif st.state == "mismatch" or st.state == "error" then
    h.warn("libjupynvim " .. tostring(st.reason), { st.fix })
  elseif st.state == "unloaded" then
    h.info("libjupynvim is still being opened for the first time; run :checkhealth jupynvim again")
  else
    h.info(("libjupynvim is %s%s"):format(tostring(st.state), st.reason and (": " .. st.reason) or ""))
  end
end

function M.check()
  local h = vim.health
  local J = require("jupynvim")
  local Install = require("jupynvim.backend.install")

  h.start("jupynvim: backend")
  if vim.fn.has("nvim-0.11") ~= 1 then h.error("Neovim 0.11 or newer is required") end
  local root = J._plugin_root()
  local want = Install.source_version(root)
  local cfg_path = J.config and J.config.core_path
  local local_bin = root .. "/core/target/release/jupynvim-core"
  local dev_build = Install.is_dev_build(root)
  -- the binary locate_core would use, in its order
  local bin = cfg_path
    or (vim.fn.executable(local_bin) == 1 and local_bin)
    or (vim.fn.executable("jupynvim-core") == 1 and vim.fn.exepath("jupynvim-core"))
    or local_bin
  local fix = dev_build and "Rebuild it: cargo build --release in core/" or "Run :JupynvimInstall"
  if vim.fn.executable(bin) ~= 1 then
    h.error("jupynvim-core not found at " .. bin, cfg_path and { "core_path points at no executable" } or {
      "Run :JupynvimInstall",
      "Or leave auto_install on and open a notebook: it fetches the matching release",
      "Or set core_path in setup() to a binary you built",
    })
  else
    local have, err = J._binary_version(bin)
    if not have then
      h.error(bin .. " does not run here" .. (err and err ~= "" and (": " .. err) or ""), { fix })
    elseif want and have ~= want then
      h.warn(("jupynvim-core is v%s but the plugin is v%s"):format(have, want), { fix })
    else
      h.ok(("jupynvim-core v%s at %s"):format(have, bin))
    end
  end
  h.info("auto_install: " .. tostring(not (J.config and J.config.auto_install == false)))

  M._library(h, J, Install)

  h.start("jupynvim: installing the prebuilt")
  local tag = want and ("v" .. want)
  local targets = Install._detect_targets()
  if #targets > 0 then
    h.ok("prebuilt targets for this platform, tried in order: " .. table.concat(targets, ", "))
    for _, t in ipairs(targets) do
      local bad = tag and Install.known_bad(tag, t)
      if bad then h.warn(("the %s %s prebuilt was refused: %s"):format(tag, t, bad)) end
    end
  else
    h.warn("no prebuilt is made for this platform",
      { "Install a Rust toolchain; :JupynvimInstall builds with cargo" })
  end
  local lt = Install._lib_target()
  if lt then
    h.ok("library prebuilt for this platform: " .. lt.target)
    local bad = tag and Install.known_bad(tag, "lib-" .. lt.target)
    if bad and tostring(bad):find("^not published") then
      h.info(("the %s release publishes no library prebuilt for %s; a notebook opened a day after that was found "
        .. "asks again, and :JupynvimInstall asks now"):format(tag, lt.target))
    elseif bad then
      h.warn(("the %s library prebuilt was refused: %s"):format(tag, bad))
    end
  end
  if vim.fn.executable("curl") == 1 then h.ok("curl found") else h.error("curl not found") end
  if vim.fn.executable("shasum") == 1 or vim.fn.executable("sha256sum") == 1 then
    h.ok("shasum found, downloads are SHA256-checked")
  else
    h.warn("neither shasum nor sha256sum found: jupynvim-core downloads cannot be SHA256-checked, "
      .. "and the library prebuilt is refused")
  end
  if vim.fn.executable("cargo") == 1 then
    h.ok("cargo found, a source build is possible")
  else
    h.info("cargo not found, only needed where no prebuilt runs")
  end
end

return M

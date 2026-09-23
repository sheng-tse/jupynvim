-- :checkhealth jupynvim
local M = {}

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
  local dev_build = vim.fn.isdirectory(root .. "/core/target/release/.fingerprint") == 1
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

  h.start("jupynvim: installing the prebuilt")
  local targets = Install._detect_targets()
  if #targets > 0 then
    h.ok("prebuilt published for " .. table.concat(targets, ", "))
    local tag = want and ("v" .. want)
    for _, t in ipairs(targets) do
      local bad = tag and Install.known_bad(tag, t)
      if bad then h.warn(("the %s %s prebuilt did not run here: %s"):format(tag, t, bad)) end
    end
  else
    h.warn("no prebuilt is published for this platform",
      { "Install a Rust toolchain; :JupynvimInstall builds with cargo" })
  end
  if vim.fn.executable("curl") == 1 then h.ok("curl found") else h.error("curl not found") end
  if vim.fn.executable("shasum") == 1 or vim.fn.executable("sha256sum") == 1 then
    h.ok("shasum found, downloads are SHA256-checked")
  else
    h.warn("neither shasum nor sha256sum found, downloads cannot be SHA256-checked")
  end
  if vim.fn.executable("cargo") == 1 then
    h.ok("cargo found, a source build is possible")
  else
    h.info("cargo not found, only needed where no prebuilt runs")
  end
end

return M

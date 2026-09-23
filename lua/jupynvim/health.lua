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
  local bin = (J.config and J.config.core_path) or (root .. "/core/target/release/jupynvim-core")
  if vim.fn.executable(bin) ~= 1 and vim.fn.executable("jupynvim-core") == 1 then
    bin = vim.fn.exepath("jupynvim-core")
  end
  if vim.fn.executable(bin) ~= 1 then
    h.error("jupynvim-core not found at " .. bin, {
      "Run :JupynvimInstall",
      "Or leave auto_install on and open a notebook: it downloads the matching release",
      "Or set core_path in setup() to a binary you built",
    })
  else
    local have = J._binary_version and J._binary_version(bin)
    if not have then
      h.error(bin .. " does not run (--version failed)", { "Run :JupynvimInstall" })
    elseif want and have ~= want then
      h.warn(("jupynvim-core is v%s but the plugin is v%s"):format(have, want),
        { "Run :JupynvimInstall" })
    else
      h.ok(("jupynvim-core v%s at %s"):format(have, bin))
    end
  end
  h.info("auto_install: " .. tostring(not (J.config and J.config.auto_install == false)))

  h.start("jupynvim: installing the prebuilt")
  local target = Install._detect_target()
  if target then
    h.ok("prebuilt available for " .. target)
  else
    h.warn("no prebuilt for this platform", { "Install a Rust toolchain; :JupynvimInstall builds with cargo" })
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
    h.info("cargo not found, only needed where no prebuilt exists")
  end
end

return M

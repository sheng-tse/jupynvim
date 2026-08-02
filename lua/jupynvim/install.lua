-- Compatibility shim. The implementation moved to backend/install.lua, but the
-- lazy.nvim build hook in the README loads this file BY PATH:
--
--   loadfile(plugin.dir .. "/lua/jupynvim/install.lua")()
--
-- so every existing user's config points here. Removing it would break their
-- next plugin update, not ours. Keep it.
return require("jupynvim.backend.install")

-- Compatibility shim. The implementation moved to backend/install.lua, but
-- install hooks load this file BY PATH:
--
--   loadfile(plugin.dir .. "/lua/jupynvim/install.lua")()     -- lazy.nvim
--   dofile(ev.data.path .. "/lua/jupynvim/install.lua")       -- vim.pack
--
-- so every existing user's config points here. Removing it would break their
-- next plugin update, not ours. Keep it.
--
-- It loads the implementation by path too. A require only works once the
-- plugin is on 'runtimepath', and vim.pack runs its install hook before
-- adding it, so the require failed there with "module not found".
local here = debug.getinfo(1, "S").source:gsub("^@", "")
return dofile(vim.fn.fnamemodify(here, ":p:h") .. "/backend/install.lua")

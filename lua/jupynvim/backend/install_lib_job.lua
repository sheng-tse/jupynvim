-- The library's install in the background: the first notebook opened with a
-- current jupynvim-core and no libjupynvim starts it in a Neovim of its own
-- (install.lua run_lib_background), so the download and the check never
-- block the editor:
--
--   nvim --clean --headless -l install_lib_job.lua <plugin dir>
--
-- Its notices go to stderr and the last line on stdout says how it went:
--
--   jnv-lib ok
--   jnv-lib fail <why>
--
-- It acts only as the script nvim -l runs (whose arguments are in _G.arg,
-- arg[0] naming the script); required as a module, by mistake or by a tool
-- loading every file, it does nothing.
local function own_args()
  local a = rawget(_G, "arg")
  if type(a) ~= "table" or type(a[0]) ~= "string" then return nil end
  local me = debug.getinfo(1, "S").source:gsub("^@", "")
  if vim.fn.fnamemodify(a[0], ":p") ~= vim.fn.fnamemodify(me, ":p") then return nil end
  return a
end
local args = own_args()
local dir = args and args[1]
if type(dir) ~= "string" or dir == "" then return {} end

vim.notify = function(msg) io.stderr:write(tostring(msg), "\n") end
local ok, done, why = pcall(function()
  local Install = dofile(dir .. "/lua/jupynvim/backend/install.lua")
  return Install.run_lib(dir, { no_cargo = true })
end)
if not ok then done, why = false, tostring(done) end
local line = done and "jnv-lib ok" or ("jnv-lib fail " .. tostring(why))
io.stdout:write((line:gsub("\n", " ")), "\n")
io.stdout:flush()
return {}

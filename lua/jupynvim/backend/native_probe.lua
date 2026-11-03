-- Checks a downloaded libjupynvim before the installer renames it into
-- place, in a Neovim of its own, so a library that does not load can never
-- take the user's editor down with it:
--
--   nvim --clean --headless -l native_probe.lua <library> <plugin dir>
--
-- It loads the library with the plugin's own loader (lua/jupynvim/native.lua)
-- and runs its checks: every export, the ABI and the struct layout. No
-- worker starts. One line on stdout says how it went:
--
--   jnv-probe ok <version> <abi major>.<abi minor>
--   jnv-probe err <reason>
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
local lib, dir = args and args[1], args and args[2]
if type(lib) ~= "string" or type(dir) ~= "string" then return {} end

local ok, res = pcall(function()
  local N = dofile(dir .. "/lua/jupynvim/native.lua")
  return N._probe(lib)
end)
local line
if not ok then
  line = "jnv-probe err the loader failed: " .. tostring(res)
elseif res.ok then
  line = ("jnv-probe ok %s %s"):format(tostring(res.version), tostring(res.abi))
else
  line = "jnv-probe err " .. tostring(res.reason)
end
io.stdout:write((line:gsub("\n", " ")), "\n")
io.stdout:flush()
return {}

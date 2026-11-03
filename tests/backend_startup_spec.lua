-- A second notebook can request the backend while image attachment waits.
vim.opt.runtimepath:prepend(vim.fn.getcwd())
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local J = require("jupynvim")
local RPC = require("jupynvim.rpc")
local Image = require("jupynvim.notebook.image")

J.config.core_path = "jupynvim-core"
J.config.remote = J.config.remote or {}
J.config.remote.startup = { transport_cmd = { "jupynvim-core" } }
J._binary_verified = J._binary_verified or {}
J._binary_verified.startup = true
local original_spawn = RPC.spawn
local original_attach = Image.attach

for _, entry in ipairs({
  { name = "_ensure_client", call = function() return J._ensure_client() end },
  { name = "client_for", call = function() return J.client_for("local") end },
  { name = "remote client_for", alias = "startup", call = function() return J.client_for("startup") end },
}) do
  J.client = nil
  J.clients[entry.alias or "local"] = nil
  local spawn_count = 0
  local nested_client
  local attaching = false

  RPC.spawn = function()
    spawn_count = spawn_count + 1
    return { job = spawn_count, on = function() end }
  end
  Image.attach = function()
    if not attaching then
      attaching = true
      nested_client = entry.call()
    end
  end

  local first_client = entry.call()
  assert(spawn_count == 1, entry.name .. " started " .. spawn_count .. " backends")
  assert(nested_client == first_client, entry.name .. " routed the second open to another backend")
end

RPC.spawn = original_spawn
Image.attach = original_attach
io.write("ALL BACKEND STARTUP CHECKS PASSED\n")
vim.cmd("qa!")

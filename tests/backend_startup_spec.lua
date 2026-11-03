-- A second notebook can request the backend while image attachment waits,
-- and the backend it gets already listens: a notebook opened in that wait
-- starts its kernel through it, and a notification with no handler is lost.
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
local original_attach_remote = Image.attach_remote

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
  local listening

  RPC.spawn = function()
    spawn_count = spawn_count + 1
    local c = { job = spawn_count, handlers = {} }
    function c:on(method, h) self.handlers[method] = h end
    return c
  end
  -- A local backend attaches through Image.attach, a remote one through
  -- Image.attach_remote; either stands in for the wait during which another
  -- notebook asks for the backend.
  local function nested_open()
    if not attaching then
      attaching = true
      nested_client = entry.call()
      listening = {}
      for _, m in ipairs({ "cell_event", "widget_event", "kernel_event", "user_message" }) do
        if nested_client and nested_client.handlers[m] then listening[#listening + 1] = m end
      end
    end
  end
  Image.attach = nested_open
  Image.attach_remote = nested_open

  local first_client = entry.call()
  assert(spawn_count == 1, entry.name .. " started " .. spawn_count .. " backends")
  assert(nested_client == first_client, entry.name .. " routed the second open to another backend")
  assert(listening and #listening == 4, entry.name .. " handed out a backend whose notifications are not handled yet"
    .. " (handled during the attach: " .. table.concat(listening or {}, ", ") .. ")")
  -- what the backend says in that wait reaches the user
  local said
  local real_notify = vim.notify
  vim.notify = function(msg) said = msg end
  first_client.handlers.user_message({ { level = "info", text = "installing ipykernel" } })
  vim.notify = real_notify
  assert(said == "jupynvim: installing ipykernel", entry.name .. ": a user_message is shown: " .. tostring(said))
end

RPC.spawn = original_spawn
Image.attach = original_attach
Image.attach_remote = original_attach_remote
io.write("ALL BACKEND STARTUP CHECKS PASSED\n")
vim.cmd("qa!")

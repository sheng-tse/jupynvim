-- The first notebook open of a session, in a fresh editor of its own, for
-- tests/routing_spec.lua: nothing has started a backend yet, as when a
-- notebook is opened right after a file explorer previewed it. The open must
-- still clear the placements such a preview leaves on screen.
--
-- FIRST_OPEN_DIR holds the notebook (nb.ipynb), the file the backend takes
-- for its terminal (tty) and the stub remote's home (rhome). FIRST_OPEN_MODE
-- is "local" (a local notebook) or "remote" (the same file from the stub
-- remote, a second jupynvim-core started through transport_cmd). A clear
-- reaches the terminal in one of two ways, and the caller counts both: the
-- escapes this editor encodes go to its stderr, and a clear a backend
-- answered was written by that backend (in a file standing in for the
-- terminal its later writes start over at the top, so the file cannot be
-- read for it). This prints one line,
-- "FIRST_OPEN mode=<mode> opened=<true|false> asked=<n> answered=<m>", where
-- n counts the clears sent to a backend and m those it answered without an
-- error.
package.path = "./lua/?.lua;./lua/?/init.lua;./tests/?.lua;" .. package.path

local dir = assert(vim.env.FIRST_OPEN_DIR, "FIRST_OPEN_DIR is not set")
local mode = vim.env.FIRST_OPEN_MODE or "local"
vim.env.TERM = "xterm-kitty"
vim.env.JUPYNVIM_TTY = dir .. "/tty"
local CORE = vim.env.JUPYNVIM_TEST_CORE or vim.fn.fnamemodify("core/target/release/jupynvim-core", ":p")

local RPC = require("jupynvim.rpc")
local asked, answered = 0, 0
local orig_spawn = RPC.spawn
---@diagnostic disable-next-line: duplicate-set-field
RPC.spawn = function(o)
  local c = orig_spawn(o)
  local call = c.call
  c.call = function(self, method, params, cb)
    if method == "kitty_clear_visible" then
      asked = asked + 1
      local inner = cb
      cb = function(err, res)
        if err == nil then answered = answered + 1 end
        if inner then return inner(err, res) end
      end
    end
    return call(self, method, params, cb)
  end
  return c
end

local J = require("jupynvim")
J.setup({
  core_path = CORE, auto_install = false, auto_venv = false, log_level = "warn",
  image_renderer = "placeholder",
  remote = {
    stub = { host = "stub.invalid",
             transport_cmd = { "env", "JNV_SIDE=remote", "HOME=" .. dir .. "/rhome",
                               "PYTHONUSERBASE=" .. (vim.env.FIRST_OPEN_USERBASE or ""), CORE } },
  },
})
vim.notify = function() end

local path = dir .. "/nb.ipynb"
local buf
if mode == "remote" then buf = J.open(path, { alias = "stub" }) else buf = J.open(path) end
-- a clear handed to a backend counts once the backend answered it
if asked > 0 then vim.wait(5000, function() return answered >= asked end, 20) end
io.stdout:write(("FIRST_OPEN mode=%s opened=%s asked=%d answered=%d\n"):format(mode, tostring(buf ~= nil), asked,
  answered))
io.stdout:flush()
vim.cmd("qa!")

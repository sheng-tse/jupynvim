-- The frontend's walk for a project interpreter (init.lua find_local_venv_python):
-- each directory from the notebook's upward is checked for .venv, venv and env
-- and then for Pixi's default environment (.pixi/envs/default; python.exe at the
-- env root on Windows). The first interpreter found decides: it is used when
-- ipykernel imports in it, and the walk ends with nil when it does not.
--
-- Headless, no kernel and no backend: the interpreters are #!/bin/sh scripts
-- that exit 0 (ipykernel present) or 1 (absent) on `-c "import ipykernel"` and
-- 2 on anything else, so a probe that is not that one fails the check.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local fails = 0
local function chk(name, cond, detail)
  if cond then
    io.write("  ok " .. name .. "\n")
  else
    io.write("FAIL " .. name .. (detail and ("  -- " .. detail) or "") .. "\n")
    fails = fails + 1
  end
end

local J = require("jupynvim")
local find = J._find_local_venv_python

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")

-- A fake interpreter at `path` (parents made); has_ipykernel picks its answer.
local function fake_python(path, has_ipykernel)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = assert(io.open(path, "w"))
  f:write("#!/bin/sh\n",
    'if [ "$1" = "-c" ] && [ "$2" = "import ipykernel" ]; then exit ',
    has_ipykernel and "0" or "1", "; fi\nexit 2\n")
  f:close()
  vim.fn.setfperm(path, "rwxr-xr-x")
end

-- A fresh case dir under tmp.
local n = 0
local function case_dir()
  n = n + 1
  local d = tmp .. "/case" .. n
  vim.fn.mkdir(d, "p")
  return d
end

local PIXI_BIN = "/.pixi/envs/default/bin/python"
local PIXI_EXE = "/.pixi/envs/default/python.exe"

-- P1: a Pixi env with ipykernel is found from a nested notebook dir.
do
  local d = case_dir()
  fake_python(d .. "/proj" .. PIXI_BIN, true)
  vim.fn.mkdir(d .. "/proj/sub/deeper", "p")
  local got = find(d .. "/proj/sub/deeper")
  chk("P1 a Pixi env with ipykernel is found from a nested dir",
      got == d .. "/proj" .. PIXI_BIN, "got " .. tostring(got))
end

-- P2: a .venv beside the Pixi env wins, whichever has ipykernel.
do
  local d = case_dir()
  fake_python(d .. "/proj" .. PIXI_BIN, true)
  fake_python(d .. "/proj/.venv/bin/python", true)
  local got = find(d .. "/proj")
  chk("P2 a .venv in the same dir wins over the Pixi env",
      got == d .. "/proj/.venv/bin/python", "got " .. tostring(got))
  -- The closest env decides: a .venv without ipykernel ends the walk even
  -- though the Pixi env beside it has it (the same rule the venvs follow).
  local d2 = case_dir()
  fake_python(d2 .. "/proj" .. PIXI_BIN, true)
  fake_python(d2 .. "/proj/.venv/bin/python", false)
  local got2 = find(d2 .. "/proj")
  chk("P2 a .venv without ipykernel ends the walk, the Pixi env is not tried", got2 == nil,
      "got " .. tostring(got2))
end

-- P3: a Pixi python without ipykernel returns nil and does not fall back to an
-- outer .venv (the same "closest env decides" rule as for the venvs).
do
  local d = case_dir()
  fake_python(d .. "/.venv/bin/python", true)
  fake_python(d .. "/proj" .. PIXI_BIN, false)
  local got = find(d .. "/proj/nb")
  chk("P3 a Pixi python without ipykernel ends the walk (no outer .venv)", got == nil,
      "got " .. tostring(got))
end

-- P4: a .pixi/envs/default dir with no python is passed over.
do
  local d = case_dir()
  fake_python(d .. "/.venv/bin/python", true)
  vim.fn.mkdir(d .. "/proj/.pixi/envs/default/lib", "p")
  local got = find(d .. "/proj")
  chk("P4 a Pixi env dir with no python is passed over, the outer .venv is found",
      got == d .. "/.venv/bin/python", "got " .. tostring(got))
end

-- P5 and P7 run with the Windows layout switched on.
local config = package.config
local function as_windows(fn)
  package.config = "\\" .. config:sub(2)
  local ok, err = pcall(fn)
  package.config = config
  if not ok then error(err, 0) end
end

as_windows(function()
  -- P5: Pixi puts python.exe at the env root on Windows, not in Scripts.
  local d = case_dir()
  fake_python(d .. "/proj" .. PIXI_EXE, true)
  local got = find(d .. "/proj/sub")
  chk("P5 on Windows the Pixi env's python.exe is at the env root",
      got == d .. "/proj" .. PIXI_EXE, "got " .. tostring(got))
  -- A python only under Scripts\ in a Pixi env is not Pixi's interpreter.
  local d2 = case_dir()
  fake_python(d2 .. "/proj/.pixi/envs/default/Scripts\\python.exe", true)
  local got2 = find(d2 .. "/proj")
  chk("P5 on Windows a Scripts\\python.exe inside a Pixi env is not taken", got2 == nil,
      "got " .. tostring(got2))

  -- P7: the venv branch is unchanged: Scripts\python.exe.
  local d3 = case_dir()
  fake_python(d3 .. "/proj/.venv/Scripts\\python.exe", true)
  local got3 = find(d3 .. "/proj/sub")
  chk("P7 on Windows a venv's Scripts\\python.exe is still found",
      got3 == d3 .. "/proj/.venv/Scripts\\python.exe", "got " .. tostring(got3))
end)
chk("package.config is restored", package.config == config)

-- P6 (B47-1): with no Pixi env anywhere the walk spawns no process, and the
-- Pixi check adds at most one executable() call per directory level.
do
  local d = case_dir()
  vim.fn.mkdir(d .. "/a/b/c", "p")
  local start = d .. "/a/b/c"
  -- the levels the walk visits: from `start` up to the root, at most 10
  local levels, dir = 0, start
  for _ = 1, 10 do
    levels = levels + 1
    local parent = vim.fn.fnamemodify(dir, ":h")
    if parent == dir then break end
    dir = parent
  end
  local sys_calls, exe_calls = 0, 0
  local real_system, real_exe = vim.fn.system, vim.fn.executable
  vim.fn.system = function(...) sys_calls = sys_calls + 1; return real_system(...) end
  vim.fn.executable = function(...) exe_calls = exe_calls + 1; return real_exe(...) end
  local ok, got = pcall(find, start)
  vim.fn.system = real_system
  vim.fn.executable = real_exe
  chk("P6 the walk with no env anywhere does not fail", ok, tostring(got))
  chk("P6 no env anywhere: nil", got == nil, "got " .. tostring(got))
  chk("P6 no env anywhere: no process is spawned", sys_calls == 0, sys_calls .. " vim.fn.system calls")
  chk("P6 at most one extra executable() check per directory level (B47-1)",
      exe_calls <= 4 * levels,
      ("%d executable() calls over %d levels (the three venv names plus Pixi make %d)")
        :format(exe_calls, levels, 4 * levels))
end

vim.fn.delete(tmp, "rf")

if fails == 0 then
  io.write("\nALL PIXI ENV CHECKS PASSED\n")
  vim.cmd("qa!")
else
  io.write(("\nPIXI ENV: %d CHECK(S) FAILED\n"):format(fails))
  vim.cmd("cquit 1")
end

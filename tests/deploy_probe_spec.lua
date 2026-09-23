-- Regression test for the number of SSH round trips a remote connect spends
-- verifying the backend binary.
--
-- Why this is worth a test: on a loaded cluster login node one ssh channel is
-- not cheap. Measured against PSC bridges2 on 2026-08-28, `hostname` over an
-- already-authenticated ControlMaster took 21.4s, 44.7s and 47.4s back to
-- back. ensure_remote_binary used to spend TWO of those (a `uname -m` probe,
-- then a separate `cat <marker>`) before the backend was even spawned, every
-- single connect, on the UI thread. That is where "takes forever to load"
-- came from, so the round-trip count is the thing to pin down.
--
-- Asserted here:
--   1. a cold verify costs exactly ONE ssh round trip (arch + marker folded
--      into one channel), not two;
--   2. a second verify with an unchanged local binary costs ZERO, because the
--      confirmed sha is remembered across sessions;
--   3. that memory is dropped when a spawn reports 127 (binary gone), so we
--      re-probe instead of trusting a stale record;
--   4. a changed local binary re-probes and re-uploads.

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local fails = 0
local function fail(m) io.write("FAIL: " .. m .. "\n"); fails = fails + 1 end
local function ok(m) io.write("  ok " .. m .. "\n") end

local J = require("jupynvim")

-- Isolate the persisted deploy record from the real cache dir.
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local orig_stdpath = vim.fn.stdpath
---@diagnostic disable-next-line: duplicate-set-field
vim.fn.stdpath = function(what)
  if what == "cache" then return tmp end
  return orig_stdpath(what)
end

-- A stand-in for the cross-built linux artifact. Its bytes are the "version".
local fake_bin = tmp .. "/jupynvim-core-linux"
local function write_bin(contents)
  local f = assert(io.open(fake_bin, "w")); f:write(contents); f:close()
end
write_bin("v1")

J.config = J.config or {}
J.config.remote = J.config.remote or {}
J.config.remote.probehost = {
  host = "user@probehost.invalid",
  core_path = "~/.local/bin/jupynvim-core",
  local_core = fake_bin,   -- pins the artifact, so no cross-build is attempted
}

-- ---- stub the outside world -------------------------------------------
-- Count only ssh invocations that actually cross the network. `ssh -O check`
-- (master_alive) is a local query against the control socket and costs
-- nothing, so it must not be counted as a round trip.
local ssh_cmds = {}
local probe_cmds = {}   -- the staleness probes specifically
local orig_system = vim.system
local orig_fn_system = vim.fn.system
local uploaded = 0

---@diagnostic disable-next-line: duplicate-set-field
vim.system = function(cmd, opts, on_exit)
  local joined = table.concat(cmd, " ")
  local out = ""
  if joined:match("ssh") and not joined:match("%-O check") then
    table.insert(ssh_cmds, joined)
    -- A staleness probe is any read of the arch or the marker. The combined
    -- form matches on "uname -m" and counts once; the pre-fix code issued two
    -- separate ones (uname, then `cat <marker>`) and counts twice. Writing the
    -- marker back after an upload is a write, not a probe.
    if joined:match("uname %-m")
       or (joined:match("sha256") and not joined:match("printf")) then
      table.insert(probe_cmds, joined)
    end
    if joined:match("uname %-m") then
      -- one channel answering BOTH probes: arch line, then the sha marker
      out = "x86_64\n" .. (_G.__remote_sha or "") .. "\n"
    elseif opts and opts.stdin then
      uploaded = uploaded + 1
      _G.__remote_sha = _G.__local_sha       -- upload lands
    elseif joined:match("printf") then
      out = ""
    end
  end
  local res = { stdout = out, code = 0, stderr = "" }
  if on_exit then on_exit(res) end
  return { wait = function() return res end }
end

---@diagnostic disable-next-line: duplicate-set-field
vim.fn.system = function(cmd)
  local joined = type(cmd) == "table" and table.concat(cmd, " ") or tostring(cmd)
  -- vim.v.shell_error is READ-ONLY, so it cannot be set directly. Run a
  -- real trivial command through the original to make it 0, which is what
  -- master_alive actually checks.
  orig_fn_system({ "true" })
  if joined:match("shasum") then
    -- stand-in hash: the file's own bytes, so "v1" and "v2" differ
    local f = io.open(fake_bin, "r")
    local body = f and f:read("*a") or ""
    if f then f:close() end
    -- must be HEX: the production code parses it with match("^(%x+)")
    _G.__local_sha = (body:gsub(".", function(c) return ("%02x"):format(c:byte()) end))
    return _G.__local_sha .. "  " .. fake_bin .. "\n"
  end
  if joined:match("%-O check") then return "Master running" end
  return ""
end

-- ensure_remote_binary is a local inside Connect.install; drive it the way
-- production does, through client_for, with the actual spawn stubbed out.
local RPC = require("jupynvim.rpc")
local orig_spawn = RPC.spawn
local spawn_exit                     -- captured on_exit, to simulate 127
---@diagnostic disable-next-line: duplicate-set-field
RPC.spawn = function(o)
  spawn_exit = o.on_exit
  return {
    job = 1,
    on = function() end,
    stop = function() end,
    request = function() end,
    notify = function() end,
    -- Image.attach probes kitty_attach; a non-nil error puts it in remote
    -- mode, which needs nothing else from us.
    call_sync = function() return "no tty in headless test" end,
  }
end

-- Returns (probe round trips, total round trips). Only the probes are what
-- this fix is about: an upload that genuinely has to happen costs its own
-- channels (stream the bytes, then write the marker) and always will.
local function verify(label)
  ssh_cmds = {}
  probe_cmds = {}
  J.clients.probehost = nil
  J._binary_verified = J._binary_verified or {}
  J._binary_verified.probehost = nil        -- force the deploy check to run
  local okc, err = pcall(function() return J.client_for("probehost") end)
  if not okc then fail(label .. ": client_for errored: " .. tostring(err)) end
  return #probe_cmds, #ssh_cmds
end

-- ---- 1. cold verify: ONE round trip, not two --------------------------
_G.__remote_sha = nil
local n1, t1 = verify("cold")
if n1 ~= 1 then
  fail(("cold verify made %d probe round trips, expected exactly 1 (arch+marker in one channel); cmds:\n    %s")
    :format(n1, table.concat(ssh_cmds, "\n    ")))
else
  ok("cold verify: 1 probe round trip (was 2 before the fix)")
end
-- documents the rest of a first deploy: stream the bytes, then the marker
if t1 ~= 3 then
  fail(("cold verify total round trips = %d, expected 3 (probe + upload + marker)"):format(t1))
else
  ok("cold verify total: 3 (probe + upload + marker)")
end
-- and it really did carry both probes
local combined = false
for _, c in ipairs(ssh_cmds) do
  if c:match("uname %-m") and c:match("sha256") then combined = true end
end
if not combined and n1 == 1 then
  fail("the single round trip did not carry both the arch probe and the marker read")
elseif combined then
  ok("that one channel carried both the arch probe and the marker read")
end
if uploaded ~= 1 then fail("expected the cold verify to upload once, got " .. uploaded)
else ok("cold verify uploaded the binary once") end

-- ---- 2. unchanged binary: ZERO round trips ----------------------------
local _, n2 = verify("warm")
if n2 ~= 0 then
  fail(("warm verify made %d ssh round trips, expected 0 (sha unchanged, already recorded); cmds:\n    %s")
    :format(n2, table.concat(ssh_cmds, "\n    ")))
else
  ok("warm verify with unchanged binary: 0 ssh round trips")
end

-- the record must survive a fresh nvim session, not just this one
local rec = J._deploy_record_get("probehost")
if not rec or rec.sha ~= _G.__local_sha or rec.arch ~= "x86_64" then
  fail("deploy record not persisted correctly: " .. vim.inspect(rec))
else
  ok("deploy record persisted (arch=" .. rec.arch .. ")")
end

-- ---- 3. a 127 spawn drops the record ----------------------------------
if spawn_exit then spawn_exit(127) end
if J._deploy_record_get("probehost") ~= nil then
  fail("a spawn exiting 127 must drop the deploy record (binary is gone)")
else
  ok("spawn exit 127 dropped the deploy record")
end
local n3 = verify("after 127")
if n3 ~= 1 then
  fail("after a 127 the next verify must re-probe exactly once, made " .. n3)
else
  ok("after 127 the next verify re-probed (" .. n3 .. " round trip)")
end

-- ---- 4. a changed binary re-probes and re-uploads ----------------------
uploaded = 0
write_bin("v2")                       -- new artifact => new sha
local n4 = verify("changed")
if n4 ~= 1 then
  fail("a changed local binary must re-probe exactly once, made " .. n4)
else
  ok("changed binary re-probed (" .. n4 .. " round trip)")
end
if uploaded ~= 1 then
  fail("a changed local binary must be re-uploaded, uploads=" .. uploaded)
else
  ok("changed binary was re-uploaded")
end

-- ---- 5. a newer-but-older artifact counts as stale ---------------------
-- mtime is not proof of freshness. This is the case that actually bit: the
-- cross-built musl binary had a newer mtime than every source file, so it was
-- treated as current, while the code inside it was two releases behind and the
-- remote kept running it.
do
  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. "/core/target/x86_64-unknown-linux-musl/release", "p")
  vim.fn.mkdir(root .. "/core/src", "p")
  local function put(path, body)
    local f = assert(io.open(path, "w")); f:write(body); f:close()
  end
  put(root .. "/core/src/main.rs", "fn main() {}\n")
  put(root .. "/core/Cargo.toml", '[package]\nname = "jupynvim-core"\nversion = "0.4.5"\n')
  local art = root .. "/core/target/x86_64-unknown-linux-musl/release/jupynvim-core"
  -- built from an OLDER manifest, but written last => newest mtime of the lot
  put(art, "\0\0padding\0jupynvim-core starting (v0.4.3)\0more padding\0")

  local orig_root = J._plugin_root
  ---@diagnostic disable-next-line: duplicate-set-field
  J._plugin_root = function() return root end

  local stale, why = J._linux_core_stale("x86_64-unknown-linux-musl")
  if not stale then
    fail("an artifact built from v0.4.3 against a v0.4.5 manifest must be stale, "
         .. "even with the newest mtime (this is how the remote silently ran old code)")
  else
    ok("version-mismatched artifact is stale (" .. tostring(why) .. ")")
  end

  -- and the matching case must NOT be stale, or every connect would rebuild
  put(art, "\0jupynvim-core starting (v0.4.5)\0")
  local stale2 = J._linux_core_stale("x86_64-unknown-linux-musl")
  if stale2 then
    fail("an artifact matching the manifest version must not be reported stale")
  else
    ok("version-matched artifact is not stale")
  end

  J._plugin_root = orig_root
  vim.fn.delete(root, "rf")
end

-- ---- restore -----------------------------------------------------------
vim.system = orig_system
vim.fn.system = orig_fn_system
vim.fn.stdpath = orig_stdpath
RPC.spawn = orig_spawn
vim.fn.delete(tmp, "rf")

if fails == 0 then
  io.write("\nALL DEPLOY-PROBE CHECKS PASSED\n")
else
  io.write(("\nDEPLOY-PROBE: %d CHECK(S) FAILED\n"):format(fails))
  vim.cmd("cquit 1")
end

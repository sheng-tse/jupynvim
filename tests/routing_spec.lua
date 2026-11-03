-- Every notebook talks to its own backend.
--
-- A local and a remote notebook open at once. The remote is a second
-- jupynvim-core started through the profile's transport_cmd, with
-- JNV_SIDE=remote and a HOME of its own, so its kernel says which side it
-- runs on and "~/" means its home, not this one. Every request each backend
-- receives is recorded, so a call that reached the wrong backend is caught
-- even though the two share a filesystem here. The stub remote reaches its
-- backend through tests/lib/view_relay.py, which hides this machine's
-- LONLY directory from it, as another machine would not have it: the local
-- notebook there, opened on the remote, is the empty notebook of a path the
-- remote does not have.
--
-- Opening a remote notebook used to point the shared client at the remote
-- backend. A later :e of a local notebook then opened it on the remote, and
-- save, cell operations, stop, interrupt, restart and clear of a local
-- notebook went to whichever backend was used last.
--
-- Also here: the first open of a session, each in a fresh editor of its own
-- (tests/lib/routing_first_open.lua); a remote reached through a relay that
-- holds one answer back on request (tests/lib/delay_relay.py), to time a save;
-- and images once the local backend, the only one that writes to this
-- terminal, is gone.

package.path = "./lua/?.lua;./lua/?/init.lua;./tests/?.lua;" .. package.path

-- This editor's own graphics writes go to its stderr, which run_all.sh
-- captures with the verdict; one landing after the verdict line hid it. They
-- are counted (Image._tty_n, before the send) and not printed. The first-open
-- child editors keep their stderr: the first section reads it.
local chan_send = vim.api.nvim_chan_send
---@diagnostic disable-next-line: duplicate-set-field
vim.api.nvim_chan_send = function(chan, data)
  if chan == vim.v.stderr then return end
  return chan_send(chan, data)
end

local started = vim.uv.hrtime()
local fails, failed = 0, {}
local function chk(name, cond, detail)
  if cond then
    io.write("  ok " .. name .. "\n")
  else
    io.write("FAIL " .. name .. (detail ~= nil and ("  -- " .. tostring(detail)) or "") .. "\n")
    fails = fails + 1
    failed[#failed + 1] = name
  end
end
-- A section that errors (an API this tree does not have) fails, and the
-- sections after it still run.
local function section(title, fn)
  io.write("-- " .. title .. "\n")
  local ok, err = xpcall(fn, debug.traceback)
  if not ok then chk(title .. ": ran to the end", false, err) end
end

local tmp = vim.fn.tempname()
local LDIR, RHOME = tmp .. "/local", tmp .. "/rhome"
-- a directory only this machine has: the stub remote sees jnv-local-gone,
-- which does not exist, wherever a request names it
local LONLY = tmp .. "/jnv-local-only"
for _, d in ipairs({ LDIR, RHOME, LONLY }) do vim.fn.mkdir(d, "p") end
vim.env.TERM = "xterm-kitty"
vim.env.JUPYNVIM_TTY = tmp .. "/tty"
io.open(vim.env.JUPYNVIM_TTY, "w"):close()
vim.env.JNV_SIDE = "local"
local CORE = vim.env.JUPYNVIM_TEST_CORE or vim.fn.fnamemodify("core/target/release/jupynvim-core", ":p")
-- The remote's home is RHOME. Its kernel keeps this machine's user site
-- (where a Homebrew python keeps ipykernel), which HOME would otherwise move.
local KPY = vim.env.JNV_KERNEL_PYTHON or "python3"
local USERBASE = vim.trim(vim.fn.system({ KPY, "-c", "import site; print(site.getuserbase())" }))
-- Names that exist nowhere but the remote's home: a tree that expands "~"
-- here only ever reads a missing file in this user's home.
local TAG = ("jnv-routing-%d"):format(vim.uv.hrtime())
local R2NAME, TXTNAME, R5NAME = TAG .. ".ipynb", TAG .. ".txt", TAG .. "-adhoc.ipynb"
local RELAY = vim.fn.fnamemodify("tests/lib/delay_relay.py", ":p")
local VIEW = vim.fn.fnamemodify("tests/lib/view_relay.py", ":p")
local TRIGGER = tmp .. "/hold"

-- Record every request each backend gets: { side, method, params, sync }.
local RPC = require("jupynvim.rpc")
local calls = {}
local spawned = { ["local"] = 0, remote = 0 }
-- a backend from before fs_stat said the path it stat'ed (set by one section)
local STAT_WITHOUT_PATH = false
-- INJECT[method] = { side = s, err = e, n = k }: the next k requests for
-- `method` to side `s` are answered `e` without reaching the backend, as a
-- backend not connected yet ("backend exited ...") or one that does not
-- answer ("timeout", what call_sync returns when its wait ends) would answer
local INJECT = {}
-- DURING[method] = { side = s, fn = f }: the next call_sync of `method` to
-- side `s` runs f first, while the caller waits on that reply, as a timer, an
-- autocommand or a second click can run inside call_sync's wait
local DURING = {}
local orig_spawn = RPC.spawn
---@diagnostic disable-next-line: duplicate-set-field
RPC.spawn = function(o)
  local c = orig_spawn(o)
  -- the remotes say which they are in their command; the local one does not
  local side = table.concat(o.cmd, " "):match("JNV_SIDE=(%w+)") or "local"
  spawned[side] = (spawned[side] or 0) + 1
  c.side = side
  local call, call_sync = c.call, c.call_sync
  local skip = false   -- the call call_sync makes, already recorded as sync
  c.call = function(self, method, params, cb)
    if skip then
      skip = false
    else
      calls[#calls + 1] = { side = side, method = method, params = params or {}, sync = false }
    end
    local inj = INJECT[method]
    if inj and inj.side == side and inj.n > 0 then
      inj.n = inj.n - 1
      vim.schedule(function() if cb then cb(inj.err, nil) end end)
      return
    end
    return call(self, method, params, cb)
  end
  c.call_sync = function(self, method, params, timeout)
    calls[#calls + 1] = { side = side, method = method, params = params or {}, sync = true }
    local d = DURING[method]
    if d and d.side == side then
      DURING[method] = nil
      d.fn()
    end
    skip = true
    local err, res = call_sync(self, method, params, timeout)
    if STAT_WITHOUT_PATH and method == "fs_stat" and type(res) == "table" then res.path = nil end
    return err, res
  end
  return c
end

local J      = require("jupynvim")
local NB     = require("jupynvim.notebook")
local CM     = require("jupynvim.notebook.cellmode")
local Image  = require("jupynvim.notebook.image")
local Render = require("jupynvim.notebook.render")
J.setup({
  core_path = CORE, auto_install = false, auto_venv = false, log_level = "warn",
  image_renderer = "placeholder",
  remote = {
    -- a backend on "another machine": its own environment and its own home
    -- (LONLY, this machine's alone, is missing there)
    stub = { host = "stub.invalid",
             transport_cmd = { "python3", "-I", VIEW, "jnv-local-only", "jnv-local-gone", "env", "JNV_SIDE=remote",
                               "HOME=" .. RHOME, "PYTHONUSERBASE=" .. USERBASE, CORE } },
    -- the same, slow to start, as an SSH connect to a loaded cluster is
    slowstub = { host = "slowstub.invalid",
                 transport_cmd = { "sh", "-c", 'sleep 6; exec env JNV_SIDE=remote HOME="$1" PYTHONUSERBASE="$2" "$3"',
                                   "sh", RHOME, USERBASE, CORE } },
    -- a second remote, never started: every open asked of it is refused
    stub2 = { host = "stub2.invalid",
              transport_cmd = { "env", "JNV_SIDE=remote2", "HOME=" .. RHOME, "PYTHONUSERBASE=" .. USERBASE, CORE } },
    -- a remote whose link holds one answer back when TRIGGER says so
    slowsave = { host = "slowsave.invalid",
                 transport_cmd = { "python3", "-I", RELAY, TRIGGER, "env", "JNV_SIDE=remote", "HOME=" .. RHOME,
                                   "PYTHONUSERBASE=" .. USERBASE, CORE } },
    -- the session profile :JupynvimOpenRemote names after a one-off
    -- me@stub.invalid (made here with a transport, so no ssh runs)
    me_stub_invalid = { host = "me@stub.invalid",
                        transport_cmd = { "env", "JNV_SIDE=adhoc", "HOME=" .. RHOME, "PYTHONUSERBASE=" .. USERBASE,
                                          CORE } },
  },
})
local notes, note_levels = {}, {}
vim.notify = function(msg, level)
  notes[#notes + 1] = tostring(msg)
  note_levels[#notes] = level
end

local png = require("png_fixture")
local PNG_L = vim.base64.encode(png(40, 30, 1))
local PNG_R = vim.base64.encode(png(40, 30, 2))
local function write_nb(path, img)
  local function code(id, src, outputs)
    return { cell_type = "code", id = id, metadata = vim.empty_dict(), source = src,
             execution_count = outputs and 1 or vim.NIL, outputs = outputs or {} }
  end
  local f = assert(io.open(path, "w"))
  f:write(vim.json.encode({
    nbformat = 4, nbformat_minor = 5,
    metadata = { kernelspec = { name = "python3", display_name = "Python 3", language = "python" } },
    cells = {
      code("c1", "import os\nprint('side=' + os.environ.get('JNV_SIDE', '?'))"),
      code("c2", "import time\ntime.sleep(60)"),
      code("c3", "plot()", { { output_type = "display_data", metadata = vim.empty_dict(),
                               data = { ["image/png"] = img, ["text/plain"] = "<Figure>" } } }),
    },
  }))
  f:close()
end
local L, R, R3 = LONLY .. "/L.ipynb", RHOME .. "/R.ipynb", RHOME .. "/R3.ipynb"
local R4, B = RHOME .. "/R4.ipynb", LDIR .. "/B.ipynb"
write_nb(L, PNG_L)
write_nb(R, PNG_R)
write_nb(RHOME .. "/" .. R2NAME, PNG_R)
write_nb(R3, PNG_R)
write_nb(R4, PNG_R)
write_nb(RHOME .. "/" .. R5NAME, PNG_R)
write_nb(B, PNG_L)

-- The first open of a session, local and remote, each in a fresh editor of
-- its own. Both start now and are judged in the first section. Each has its
-- own state and cache dirs: two editors creating the default undo dir at the
-- same moment can fail in Neovim itself (E5003), which is not this test.
local first = {}
for _, mode in ipairs({ "local", "remote" }) do
  local dir = tmp .. "/first-" .. mode
  vim.fn.mkdir(dir .. "/rhome", "p")
  io.open(dir .. "/tty", "w"):close()
  write_nb(dir .. "/nb.ipynb", PNG_L)
  first[mode] = { dir = dir, proc = vim.system(
    { vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE",
      "-c", "luafile tests/lib/routing_first_open.lua", "-c", "cquit 3" },
    { cwd = vim.fn.getcwd(), env = { FIRST_OPEN_DIR = dir, FIRST_OPEN_MODE = mode, FIRST_OPEN_USERBASE = USERBASE,
                                     XDG_STATE_HOME = dir .. "/state", XDG_CACHE_HOME = dir .. "/cache" } }) }
end
do
  local f = assert(io.open(RHOME .. "/" .. TXTNAME, "w"))
  f:write("a remote file\n")
  f:close()
end

-- ── helpers ─────────────────────────────────────────────────────────────
local function wait(ms, cond) return vim.wait(ms, cond, 20) end
local function mark() return #calls end
-- requests `side` got for `method` since mark `from`, matching `want`
local function got(side, method, from, want)
  local n = 0
  for i = (from or 0) + 1, #calls do
    local c = calls[i]
    if c.side == side and c.method == method then
      local hit = true
      for k, v in pairs(want or {}) do
        if c.params[k] ~= v then hit = false end
      end
      if hit then n = n + 1 end
    end
  end
  return n
end
-- `method` for session `sid` went to `side` and never to the other one
local function only(side, method, sid, from)
  local other = side == "local" and "remote" or "local"
  local here = got(side, method, from, { session_id = sid })
  local there = got(other, method, from, { session_id = sid })
  return here > 0 and there == 0, ("%s got %d, %s got %d"):format(side, here, other, there)
end
-- graphics requests (other than kitty_attach) `side` got since `from`
local function kitty_calls(side, from)
  local n = 0
  for i = (from or 0) + 1, #calls do
    local c = calls[i]
    if c.side == side and c.method:sub(1, 6) == "kitty_" and c.method ~= "kitty_attach" then n = n + 1 end
  end
  return n
end
local function side_of(client) return client and client.side or "nil" end
-- The home this editor has learned for a remote (nil: none). The table is
-- part of the fix; a tree without it reads as knowing no home, so the
-- sections that use it run to the end there and fail on what they check.
local function forget_home(alias) if J._remote_homes then J._remote_homes[alias] = nil end end
local function known_home(alias) return J._remote_homes and J._remote_homes[alias] or nil end
local function nb_at(path)
  for b, nb in pairs(NB.all()) do
    if nb.path == path then return b, nb end
  end
end
local function nb_ending(tail)
  for b, nb in pairs(NB.all()) do
    if nb.path:sub(-#tail) == tail then return b, nb end
  end
end
local function focus(buf, idx)
  vim.api.nvim_set_current_buf(buf)
  if idx then vim.api.nvim_win_set_cursor(0, { CM.ranges(buf)[idx].start + 1, 0 }) end
end
local function out_text(nb, idx)
  local t = {}
  for _, o in ipairs((nb.cells[idx] or {}).outputs or {}) do
    if o.output_type == "stream" then
      t[#t + 1] = type(o.text) == "table" and table.concat(o.text) or tostring(o.text)
    elseif o.output_type == "error" then
      t[#t + 1] = tostring(o.ename)
    end
  end
  return table.concat(t)
end
-- Run a cell and wait for `want` in what this run printed. The outputs of
-- the run before are dropped first, so they never count for this one.
local function run(buf, idx, want, ms)
  local nb = NB.get(buf)
  nb.cells[idx].outputs = {}
  focus(buf, idx)
  J.run_cell(buf, { advance = false })
  wait(ms or 20000, function() return out_text(nb, idx):find(want, 1, true) ~= nil end)
  return out_text(nb, idx)
end
local function kernel_ready(buf, ms)
  return wait(ms or 30000, function()
    local nb = NB.get(buf)
    return nb ~= nil and nb.kernel_started == true
  end)
end
-- completion at "import o|s" in the first cell, from the notebook's kernel LSP
local function complete(buf)
  local client = vim.lsp.get_clients({ bufnr = buf, name = "jupynvim_kernel" })[1]
  if not client then return {}, "no jupynvim_kernel client" end
  local r = CM.ranges(buf)[1]
  local resp = client:request_sync("textDocument/completion", {
    textDocument = { uri = vim.uri_from_bufnr(buf) },
    position = { line = r.start, character = 8 },
  }, 20000, buf)
  local items = {}
  for _, it in ipairs(resp and resp.result and resp.result.items or {}) do items[it.label] = true end
  return items
end
-- the kernel completion clients attached to `buf`
local function kclients(buf) return vim.lsp.get_clients({ bufnr = buf, name = "jupynvim_kernel" }) end
local function kid(buf) local c = kclients(buf); return #c == 1 and c[1].id or nil end
local function count_in(s, sub)
  local n, i = 0, 1
  while true do
    local j = (s or ""):find(sub, i, true)
    if not j then return n end
    n, i = n + 1, j + #sub
  end
end
local function set_cell(buf, idx, lines)
  local r = CM.ranges(buf)[idx]
  local was = vim.bo[buf].modifiable
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, r.start, r.stop, false, lines)
  vim.bo[buf].modifiable = was
end
local function write(buf)
  focus(buf)
  vim.cmd("write")
end
local function saved(path)
  local f = assert(io.open(path))
  local nb = vim.json.decode(f:read("*a"))
  f:close()
  return nb.cells
end
local function src(cell) return type(cell.source) == "table" and table.concat(cell.source) or tostring(cell.source) end
local function noted(text)
  for _, n in ipairs(notes) do
    if n:find(text, 1, true) then return true end
  end
  return false
end
local function count_noted(text)
  local n = 0
  for _, s in ipairs(notes) do if s:find(text, 1, true) then n = n + 1 end end
  return n
end

-- a notebook of one markdown cell with this text
local function write_text(path, text)
  local f = assert(io.open(path, "w"))
  f:write(vim.json.encode({
    nbformat = 4, nbformat_minor = 5,
    metadata = { kernelspec = { name = "python3", display_name = "Python 3", language = "python" } },
    cells = { { cell_type = "markdown", id = "m1", metadata = vim.empty_dict(), source = text } },
  }))
  f:close()
end
-- Wipe these buffers and drop their notebook records. A kernel still
-- starting is waited for first, so its session is closed, not abandoned.
local function wipe(bufs)
  for _, b in ipairs(bufs) do
    if b and vim.api.nvim_buf_is_valid(b) then
      if NB.get(b) then kernel_ready(b, 20000) end
      pcall(vim.cmd, "bwipeout! " .. b)
    end
    if b and NB.get(b) then NB.remove(b) end
  end
end

local bufR, bufL, bufR2, bufR3
local function both()
  return { { buf = bufL, path = L, side = "local" }, { buf = bufR, path = R, side = "remote" } }
end

-- ── 0. the first open of a session ─────────────────────────────────────
section("the first open of a session clears what a file explorer's preview left", function()
  for _, mode in ipairs({ "local", "remote" }) do
    local f = first[mode]
    local r = f.proc:wait(60000)
    -- the escape that deletes the visible placements, written by this editor,
    -- or a backend's answer to the clear it was asked for
    local n = count_in(r.stderr, "_Ga=d,d=a") + tonumber((r.stdout or ""):match("answered=(%d+)") or 0)
    chk(("a %s notebook opened first clears the visible placements"):format(mode),
        r.code == 0 and (r.stdout or ""):find("opened=true", 1, true) ~= nil and n > 0,
        ("rc %s, %s, %d clears %s"):format(tostring(r.code), vim.trim(r.stdout or ""):sub(1, 60), n,
          (r.stderr or ""):match("E%d+:[^\n]*") or ""))
  end
end)

-- ── A. a remote notebook first, then a local one (the reported order) ────
section("a remote notebook opened first, the way the explorer opens it", function()
  local m, tty0 = mark(), Image._tty_n or 0
  J.use_remote("stub")
  bufR = J.open(R, { alias = "stub" })
  local nb = bufR and NB.get(bufR)
  chk("the remote notebook opens with its cells", nb ~= nil and #nb.cells == 3, nb and #nb.cells)
  chk("it knows its backend", nb ~= nil and nb.alias == "stub", nb and tostring(nb.alias))
  chk("the remote backend opened it", got("remote", "open", m, { path = R }) == 1 and got("local", "open", m) == 0)
  chk("opening it started no local backend", spawned["local"] == 0 and J.client == nil,
      ("local spawns %d, J.client %s"):format(spawned["local"], side_of(J.client)))
  local tty_asks, sync_asks = 0, 0
  for _, c in ipairs(calls) do
    if c.side == "remote" and c.method == "kitty_attach" then
      if c.params.tty ~= nil then tty_asks = tty_asks + 1 end
      if c.sync then sync_asks = sync_asks + 1 end
    end
  end
  chk("the remote backend is never asked to write to a terminal", tty_asks == 0, tty_asks .. " kitty_attach with a tty")
  chk("starting it waited on no graphics round trip", sync_asks == 0, sync_asks .. " synchronous kitty_attach")
  local key = Image.output_key(Image.output_owner(bufR, "c3"), 1)
  wait(5000, function() local p = Image._placements[key]; return p ~= nil and p.b64 == PNG_R end)
  chk("its plot is shown", (Image._placements[key] or {}).b64 == PNG_R)
  chk("written by this editor, never sent to the remote backend",
      (Image._tty_n or 0) > tty0 and kitty_calls("remote") == 0,
      ("tty writes %d -> %d, remote graphics requests %d"):format(tty0, Image._tty_n or 0, kitty_calls("remote")))
end)

section("then a local notebook opened with :e", function()
  local m = mark()
  vim.cmd("edit " .. vim.fn.fnameescape(L))
  wait(15000, function() return NB.get(vim.fn.bufnr(L)) ~= nil end)
  bufL = vim.fn.bufnr(L)
  local nb = NB.get(bufL)
  chk("the local notebook opens with its cells", nb ~= nil and #nb.cells == 3, nb and #nb.cells)
  -- its cells are the file's, in order: type and source of each
  local file_cells, same = saved(L), nb ~= nil and #nb.cells == 3
  for i, c in ipairs(file_cells) do
    local mine = nb and nb.cells[i]
    if not mine or mine.cell_type ~= c.cell_type or src(mine) ~= src(c) then same = false end
  end
  chk("its cells equal the file", same and #file_cells == 3,
      nb and (#nb.cells .. " cells: "
        .. vim.inspect(vim.tbl_map(function(c) return c.cell_type .. ":" .. src(c):sub(1, 20) end, nb.cells))))
  chk("the local backend opened it", got("local", "open", m, { path = L }) == 1 and got("remote", "open", m) == 0,
      ("local %d, remote %d"):format(got("local", "open", m), got("remote", "open", m)))
  chk("it knows it is local", nb ~= nil and nb.alias == nil, nb and tostring(nb.alias))
  chk("the shared client is the local backend", side_of(J.client) == "local", side_of(J.client))
  local key = Image.output_key(Image.output_owner(bufL, "c3"), 1)
  wait(5000, function()
    local p = Image._placements[key]
    return p ~= nil and p.b64 == PNG_L and got("local", "kitty_transmit_virtual", m) > 0
  end)
  chk("its plot goes to the terminal through the local backend",
      (Image._placements[key] or {}).b64 == PNG_L and got("local", "kitty_transmit_virtual", m) > 0
        and kitty_calls("remote") == 0,
      ("local transmits %d, remote graphics requests %d"):format(got("local", "kitty_transmit_virtual", m),
        kitty_calls("remote")))
end)

section("each notebook runs on its own kernel", function()
  chk("the remote kernel starts", kernel_ready(bufR))
  chk("the local kernel starts", kernel_ready(bufL))
  chk("the remote kernel was started by the remote backend", only("remote", "start_kernel", NB.get(bufR).session_id, 0))
  chk("the local kernel was started by the local backend", only("local", "start_kernel", NB.get(bufL).session_id, 0))
  local m = mark()
  local outL = run(bufL, 1, "side=")
  chk("a local cell runs on the local kernel", outL:find("side=local", 1, true) ~= nil, outL)
  chk("execute through the local backend", only("local", "execute", NB.get(bufL).session_id, m))
  local outR = run(bufR, 1, "side=")
  chk("a remote cell runs on the remote kernel", outR:find("side=remote", 1, true) ~= nil, outR)
  chk("execute through the remote backend", only("remote", "execute", NB.get(bufR).session_id, m))
end)

section("kernel completion asks the notebook's own kernel", function()
  local cL, cR = kclients(bufL), kclients(bufR)
  chk("each notebook buffer has one kernel completion client", #cL == 1 and #cR == 1, #cL .. "/" .. #cR)
  chk("the two notebooks' clients are not the same", cL[1] ~= nil and cR[1] ~= nil and cL[1].id ~= cR[1].id)
  local on = cL[1] and vim.tbl_keys(cL[1].attached_buffers) or {}
  chk("a notebook's client serves its own buffer alone", #on == 1 and on[1] == bufL, vim.inspect(on))
  for _, t in ipairs(both()) do
    local m = mark()
    local items, why = complete(t.buf)
    chk(t.side .. " notebook: completion offers os", items.os == true, why or vim.inspect(vim.tbl_keys(items)):sub(1, 120))
    chk(t.side .. " notebook: asked through the " .. t.side .. " backend",
        only(t.side, "complete", NB.get(t.buf).session_id, m))
  end
end)

section("the kernel picker lists the notebook's own kernels", function()
  local select, shown = vim.ui.select, nil
  vim.ui.select = function(items, _, cb) shown = items; cb(nil) end
  local m = mark()
  J.kernel_picker(bufR)
  wait(10000, function() return shown ~= nil end)
  vim.ui.select = select
  chk("a remote notebook's picker asks the remote backend",
      shown ~= nil and got("remote", "list_kernels", m) == 1 and got("local", "list_kernels", m) == 0,
      ("remote %d, local %d"):format(got("remote", "list_kernels", m), got("local", "list_kernels", m)))
  shown, m = nil, mark()
  vim.ui.select = function(items, _, cb) shown = items; cb(nil) end
  J.kernel_picker(bufL)
  wait(10000, function() return shown ~= nil end)
  vim.ui.select = select
  chk("a local notebook's picker asks the local backend",
      shown ~= nil and got("local", "list_kernels", m) == 1 and got("remote", "list_kernels", m) == 0,
      ("local %d, remote %d"):format(got("local", "list_kernels", m), got("remote", "list_kernels", m)))
end)

section(":w saves through the notebook's own backend", function()
  for _, t in ipairs(both()) do
    set_cell(t.buf, 1, { "import os", "print('side=' + os.environ.get('JNV_SIDE', '?'))", "# edited-" .. t.side })
    local m = mark()
    write(t.buf)
    local cells = saved(t.path)
    chk(t.side .. " notebook: :w writes its edit", src(cells[1]):find("# edited-" .. t.side, 1, true) ~= nil,
        src(cells[1]))
    chk(t.side .. " notebook: saved through the " .. t.side .. " backend",
        only(t.side, "save", NB.get(t.buf).session_id, m))
  end
end)

section("cell operations go to the notebook's own backend", function()
  for _, t in ipairs(both()) do
    local nb, sid, m = NB.get(t.buf), NB.get(t.buf).session_id, mark()
    focus(t.buf, 1)
    J.add_cell(t.buf, "below")
    J._settle(t.buf)
    chk(t.side .. " notebook: a cell is added", #nb.cells == 4, #nb.cells)
    J.move_cell(t.buf, 1)
    J._settle(t.buf)
    J.set_cell_type(t.buf, "markdown")
    chk(t.side .. " notebook: it moves down and turns markdown",
        nb.cells[3] ~= nil and nb.cells[3].cell_type == "markdown"
          and tostring(nb.cells[2].source):find("time.sleep", 1, true) ~= nil)
    J.delete_cell(t.buf)
    J._settle(t.buf)
    chk(t.side .. " notebook: and is deleted", #nb.cells == 3, #nb.cells)
    for _, op in ipairs({ "insert_cell", "move_cell", "set_cell_type", "delete_cell" }) do
      chk(t.side .. " notebook: " .. op .. " through the " .. t.side .. " backend", only(t.side, op, sid, m))
    end
    write(t.buf)
    local cells = saved(t.path)
    chk(t.side .. " notebook: the file keeps its three code cells",
        #cells == 3 and cells[2].cell_type == "code" and cells[3].cell_type == "code"
          and src(cells[2]):find("time.sleep", 1, true) ~= nil, #cells)
  end
end)

section("clearing outputs goes to the notebook's own backend", function()
  for _, t in ipairs(both()) do
    local sid, m = NB.get(t.buf).session_id, mark()
    focus(t.buf, 1)
    J.clear_cell_output(t.buf)
    J.clear_outputs(t.buf)
    chk(t.side .. " notebook: clear_cell_output through the " .. t.side .. " backend",
        only(t.side, "clear_cell_output", sid, m))
    chk(t.side .. " notebook: clear_outputs through the " .. t.side .. " backend",
        only(t.side, "clear_outputs", sid, m))
  end
end)

section("interrupt reaches the notebook's own kernel", function()
  for _, t in ipairs(both()) do
    local nb, m = NB.get(t.buf), mark()
    focus(t.buf, 2)
    J.run_cell(t.buf, { advance = false })
    local id = nb.cells[2].id
    wait(20000, function() local s = nb.cell_state[id]; return s ~= nil and s.exec_state == "busy" end)
    vim.wait(300)
    J.interrupt_kernel(t.buf)
    wait(20000, function() return out_text(nb, 2):find("KeyboardInterrupt", 1, true) ~= nil end)
    chk(t.side .. " notebook: interrupt stops its running cell",
        out_text(nb, 2):find("KeyboardInterrupt", 1, true) ~= nil, out_text(nb, 2))
    chk(t.side .. " notebook: interrupt_kernel through the " .. t.side .. " backend",
        only(t.side, "interrupt_kernel", nb.session_id, m))
  end
end)

section("restart reaches the notebook's own kernel", function()
  for _, t in ipairs(both()) do
    local nb, m, n0 = NB.get(t.buf), mark(), count_noted("kernel restarted")
    J.restart_kernel(t.buf)
    wait(20000, function() return count_noted("kernel restarted") > n0 end)
    chk(t.side .. " notebook: its kernel restarts", count_noted("kernel restarted") > n0)
    chk(t.side .. " notebook: restart_kernel through the " .. t.side .. " backend",
        only(t.side, "restart_kernel", nb.session_id, m))
    local out = run(t.buf, 1, "side=")
    chk(t.side .. " notebook: and runs on its own kernel after", out:find("side=" .. t.side, 1, true) ~= nil, out)
  end
end)

-- An interrupt or a stop the notebook's backend refuses is shown, not
-- swallowed. The backend refuses a session it does not have: the notebook's
-- session id is swapped for one no backend made, for one request each, and
-- put back whatever happens.
section("a kernel request the notebook's backend refuses is shown", function()
  for _, t in ipairs(both()) do
    local nb = NB.get(t.buf)
    local sid, started = nb.session_id, nb.kernel_started
    local bogus = "jnv-routing-no-such-session-" .. t.side
    local ok, err = pcall(function()
      for _, op in ipairs({ { "interrupt", J.interrupt_kernel, "interrupt_kernel" },
                            { "stop", J.stop_kernel, "stop_kernel" } }) do
        local word, fn, method = op[1], op[2], op[3]
        local m, n0 = mark(), #notes
        nb.session_id = bogus
        fn(t.buf)
        local function shown()
          for i = n0 + 1, #notes do
            if notes[i]:find(word, 1, true) and notes[i]:find("no session", 1, true)
              and note_levels[i] == vim.log.levels.ERROR then return notes[i] end
          end
        end
        wait(10000, function() return shown() ~= nil end)
        nb.session_id = sid
        local here, there = got(t.side, method, m, { session_id = bogus }),
          got(t.side == "local" and "remote" or "local", method, m)
        chk(("%s notebook: %s's error from its backend is shown"):format(t.side, word),
            here == 1 and there == 0 and shown() ~= nil,
            ("%s got %d, the other %d; notes: %s"):format(t.side, here, there,
              table.concat(vim.list_slice(notes, n0 + 1), " | "):sub(1, 200)))
      end
    end)
    nb.session_id, nb.kernel_started = sid, started
    if not ok then error(err, 0) end
  end
end)

-- Running several cells, and a cell's content set from a paste or an undo,
-- show what the backend refused. The run stops at the first refusal: every
-- cell after it would get the same answer. A refused update is shown as a
-- failed sync (the next :w sends every cell again).
section("a run of several cells stops at the first refusal and shows it", function()
  local P = RHOME .. "/runs-" .. TAG .. ".ipynb"
  do
    local function code(id, s)
      return { cell_type = "code", id = id, metadata = vim.empty_dict(), source = s,
               execution_count = vim.NIL, outputs = {} }
    end
    local f = assert(io.open(P, "w"))
    f:write(vim.json.encode({ nbformat = 4, nbformat_minor = 5,
      metadata = { kernelspec = { name = "python3", display_name = "Python 3", language = "python" } },
      cells = { code("r1", "x = 1"), code("r2", "y = 2"), code("r3", "z = 3") } }))
    f:close()
  end
  local b = J.open(P, { alias = "stub" })
  local nb = b and NB.get(b)
  chk("a remote notebook of three code cells opens", nb ~= nil and #nb.cells == 3, nb and #nb.cells)
  if not nb then return end
  kernel_ready(b, 20000)
  local sid = nb.session_id
  local function count(from, method, want)
    return got("remote", method, from, want) + got("local", method, from, want)
  end
  local function shown(n0, text, level)
    local k = 0
    for i = n0 + 1, #notes do
      if notes[i]:find(text, 1, true) and note_levels[i] == level then k = k + 1 end
    end
    return k
  end
  local ok, err = pcall(function()
    local bogus = "jnv-routing-no-such-session-run"
    for _, r in ipairs({ { "run all", J.run_all, 1 }, { "run above", J.run_above, 3 },
                         { "run below", J.run_below, 1 } }) do
      focus(b, r[3])
      local m, n0 = mark(), #notes
      nb.session_id = bogus
      r[2](b)
      wait(5000, function() return shown(n0, "no session", vim.log.levels.ERROR) > 0 end)
      vim.wait(300)
      nb.session_id = sid
      chk(r[1] .. ": the first refused update is shown once and the run stops there",
          shown(n0, "no session", vim.log.levels.ERROR) == 1
            and count(m, "update_cell_source", { session_id = bogus }) == 1
            and count(m, "execute", { session_id = bogus }) == 0,
          ("%d shown, %d updates, %d executes"):format(shown(n0, "no session", vim.log.levels.ERROR),
            count(m, "update_cell_source", { session_id = bogus }), count(m, "execute", { session_id = bogus })))
    end
    -- the kernel stopped: every execute is refused, the first one is shown
    -- (stopped through its client, so the stop is done before the run)
    local serr = J._nb_client(nb):call_sync("stop_kernel", { session_id = sid }, 15000)
    nb.kernel_started = false
    chk("the kernel stops (precondition)", serr == nil, tostring(serr))
    local m, n0 = mark(), #notes
    J.run_all(b)
    wait(5000, function() return shown(n0, "kernel not started", vim.log.levels.ERROR) > 0 end)
    vim.wait(300)
    chk("run all with no kernel: the first refused execute is shown once and the run stops there",
        shown(n0, "kernel not started", vim.log.levels.ERROR) == 1
          and count(m, "execute", { session_id = sid }) == 1,
        ("%d shown, %d executes"):format(shown(n0, "kernel not started", vim.log.levels.ERROR),
          count(m, "execute", { session_id = sid })))
    -- a kernel still starting (<leader>nR right after the open): the calm
    -- notice asks for the run that was refused again, not a single cell's
    nb.kernel_starting = true
    for _, r in ipairs({ { "run all", J.run_all, 1, 'Run all again once "kernel started" appears' },
                         { "run above", J.run_above, 3, 'Run the cells above again once "kernel started" appears' },
                         { "run below", J.run_below, 1,
                           'Run this cell and the ones below again once "kernel started" appears' },
                         { "run cell", function(bb) J.run_cell(bb, { advance = false }) end, 1,
                           'Run the cell again once "kernel started" appears' } }) do
      focus(b, r[3])
      n0 = #notes
      r[2](b)
      wait(5000, function() return shown(n0, "kernel is still starting", vim.log.levels.WARN) > 0 end)
      vim.wait(200)
      chk(r[1] .. " while the kernel is still starting asks for that run again",
          shown(n0, "kernel is still starting", vim.log.levels.WARN) == 1
            and shown(n0, r[4], vim.log.levels.WARN) == 1,
          table.concat(vim.list_slice(notes, n0 + 1), " | "):sub(1, 240))
    end
    nb.kernel_starting = nil
    -- a cell's content set (a paste, an undo of a delete) on a refused session
    n0 = #notes
    nb.session_id = bogus
    J.set_cell_content(b, 1, { "# pasted" }, "markdown")
    wait(5000, function() return shown(n0, "backend sync failed", vim.log.levels.WARN) >= 2 end)
    nb.session_id = sid
    chk("a cell's content set on a refused session shows both refusals",
        shown(n0, "update_cell_source backend sync failed", vim.log.levels.WARN) == 1
          and shown(n0, "set_cell_type backend sync failed", vim.log.levels.WARN) == 1,
        table.concat(vim.list_slice(notes, n0 + 1), " | "):sub(1, 200))
  end)
  nb.session_id = sid
  if not ok then error(err, 0) end
  pcall(vim.cmd, "bwipeout! " .. b)
  if NB.get(b) then NB.remove(b) end
end)

section("run above, run below and run all send the cells they name, in order", function()
  -- three code cells and a markdown cell; the cursor on the third cell
  local P = RHOME .. "/runorder-" .. TAG .. ".ipynb"
  do
    local function cell(t, id, s)
      local c = { cell_type = t, id = id, metadata = vim.empty_dict(), source = s }
      if t == "code" then c.execution_count, c.outputs = vim.NIL, {} end
      return c
    end
    local f = assert(io.open(P, "w"))
    f:write(vim.json.encode({ nbformat = 4, nbformat_minor = 5,
      metadata = { kernelspec = { name = "python3", display_name = "Python 3", language = "python" } },
      cells = { cell("code", "c1", "a = 1"), cell("markdown", "m2", "# notes"), cell("code", "c3", "b = 2"),
                cell("code", "c4", "c = 3") } }))
    f:close()
  end
  local b = J.open(P, { alias = "stub" })
  local nb = b and NB.get(b)
  chk("a remote notebook of three code cells and a markdown cell opens", nb ~= nil and #nb.cells == 4,
      nb and #nb.cells)
  if not nb then return end
  chk("its kernel starts (precondition)", kernel_ready(b, 30000))
  -- the cell ids executed since `from`, in the order sent; one the local
  -- backend got is marked so
  local function sent(from)
    local ids = {}
    for i = from + 1, #calls do
      local c = calls[i]
      if c.method == "execute" then
        ids[#ids + 1] = (c.side == "remote" and "" or c.side .. ":") .. tostring(c.params.cell_id)
      end
    end
    return ids
  end
  for _, r in ipairs({ { "run above", J.run_above, { "c1" } }, { "run below", J.run_below, { "c3", "c4" } },
                       { "run all", J.run_all, { "c1", "c3", "c4" } } }) do
    focus(b, 3)
    local m = mark()
    r[2](b)
    wait(10000, function() return #sent(m) >= #r[3] end)
    vim.wait(500)
    local want, got_ids = table.concat(r[3], ","), table.concat(sent(m), ",")
    chk(r[1] .. " from the third cell sends " .. want .. ", in that order, to the notebook's own backend",
        got_ids == want, got_ids)
  end
  wipe({ b })
end)

section("deleting a notebook's last cell shows a refused insert of the empty one", function()
  local P = RHOME .. "/lastcell-" .. TAG .. ".ipynb"
  write_text(P, "only cell")
  local b = J.open(P, { alias = "stub" })
  local nb = b and NB.get(b)
  chk("a remote notebook of one cell opens", nb ~= nil and #nb.cells == 1, nb and #nb.cells)
  if not nb then return end
  kernel_ready(b, 20000)
  focus(b, 1)
  local n0 = #notes
  INJECT.insert_cell = { side = "remote", err = "refused by the test", n = 1 }
  J.delete_cell(b)
  J._settle(b)
  wait(3000, function()
    for i = n0 + 1, #notes do if notes[i]:find("refused by the test", 1, true) then return true end end
  end)
  INJECT.insert_cell = nil
  local k = 0
  for i = n0 + 1, #notes do
    if notes[i]:find("insert: refused by the test", 1, true) and note_levels[i] == vim.log.levels.ERROR then k = k + 1 end
  end
  chk("the refused insert is shown", k == 1, k .. " shown")
  wipe({ b })
end)

-- ── B. commands ─────────────────────────────────────────────────────────
section("a remote path is never expanded on this machine", function()
  for _, c in ipairs({ { "~/x.ipynb", "/~/x.ipynb" }, { "~", "/~" }, { "work/x.ipynb", "/~/work/x.ipynb" },
                       { "/abs/x.ipynb", "/abs/x.ipynb" }, { " ~/y.ipynb ", "/~/y.ipynb" } }) do
    chk(("%q is %q"):format(c[1], c[2]), J._remote_path(c[1]) == c[2], tostring(J._remote_path(c[1])))
  end
  -- ~name is another user's home in the shell and scp: the backend resolves
  -- only its own "~", so the text is refused (nil and a message), never
  -- turned into $HOME/~name/x
  for _, p in ipairs({ "~bob/x.ipynb", "~bob", " ~bob/x " }) do
    local r, why = J._remote_path(p)
    chk(("%q is refused, with the absolute path as the way out"):format(p),
        r == nil and type(why) == "string" and why:find("absolute path", 1, true) ~= nil,
        tostring(r) .. " / " .. tostring(why))
  end
  chk('"./~bob/x" is the file of that name in the remote\'s home', J._remote_path("./~bob/x") == "/~/./~bob/x",
      tostring(J._remote_path("./~bob/x")))
  chk('"/~bob/x", with its slash, is kept as written', J._remote_path("/~bob/x") == "/~bob/x",
      tostring(J._remote_path("/~bob/x")))
end)

section(":JupynvimOpenRemote opens on the remote, at its home", function()
  local m = mark()
  vim.cmd("JupynvimOpenRemote stub:~/" .. R2NAME)
  local nb
  wait(15000, function() bufR2, nb = nb_ending("/" .. R2NAME); return nb ~= nil end)
  chk("it knows its remote", nb ~= nil and nb.alias == "stub", nb and tostring(nb.alias))
  chk("the remote opened the path at its own home", got("remote", "open", m, { path = RHOME .. "/" .. R2NAME }) == 1,
      nb and nb.path)
  chk("with its cells", nb ~= nil and #nb.cells == 3, nb and #nb.cells)
  chk("the shared client is still the local backend", side_of(J.client) == "local", side_of(J.client))
end)

section(":JupynvimOpenRemote opens a remote file as a remote buffer", function()
  local m = mark()
  vim.cmd("JupynvimOpenRemote stub:~/" .. TXTNAME)
  local name = vim.api.nvim_buf_get_name(0)
  chk("it is the remote file's buffer, named by its path at the remote's home",
      name == "jupynvim://stub" .. RHOME .. "/" .. TXTNAME, name)
  chk("with the remote file's text", vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] == "a remote file",
      vim.api.nvim_buf_get_lines(0, 0, 1, false)[1])
  chk("read by the remote backend", got("remote", "fs_read", m) >= 1 and got("local", "fs_read", m) == 0)
end)

section(":JupynvimOpenRemote opens a one-off user@host through a session profile", function()
  -- :JupynvimConnect's one-off form names its profile the same way
  local orig_connect, seen = J.connect, nil
  ---@diagnostic disable-next-line: duplicate-set-field
  J.connect = function(alias) seen = alias end
  local okc, errc = pcall(J.connect_adhoc, "me@some.host")
  J.connect = orig_connect
  chk("a one-off connect goes through the same session profile",
      okc and seen == "me_some_host" and ((J.config.remote or {}).me_some_host or {}).host == "me@some.host",
      okc and tostring(seen) or tostring(errc))
  local a = J._adhoc_profile and J._adhoc_profile("u@h.invalid")
  chk("a one-off host gets a session profile named after it",
      a == "u_h_invalid" and ((J.config.remote or {}).u_h_invalid or {}).host == "u@h.invalid", tostring(a))
  local m = mark()
  pcall(vim.cmd, "JupynvimOpenRemote me@stub.invalid:~/" .. R5NAME)
  local buf, nb
  wait(15000, function() buf, nb = nb_ending("/" .. R5NAME); return nb ~= nil end)
  chk("a one-off user@host opens on its session profile",
      nb ~= nil and nb.alias == "me_stub_invalid" and got("adhoc", "open", m, { path = RHOME .. "/" .. R5NAME }) == 1
        and got("local", "open", m) == 0 and got("remote", "open", m) == 0, nb and tostring(nb.alias))
  if buf then vim.cmd("bwipeout! " .. buf) end
end)

section(":e! reloads a remote notebook from its remote", function()
  local old, m, kc = NB.get(bufR).session_id, mark(), kid(bufR)
  focus(bufR)
  vim.cmd("edit!")
  wait(15000, function() local n = NB.get(bufR); return n ~= nil and n.session_id ~= old end)
  local nb = NB.get(bufR)
  chk("it reopens", nb ~= nil and nb.session_id ~= old)
  chk("still on its remote", nb ~= nil and nb.alias == "stub", nb and tostring(nb.alias))
  chk("the remote backend opened it, by the path it has there",
      got("remote", "open", m, { path = R }) == 1 and got("local", "open", m) == 0 and nb ~= nil and #nb.cells == 3)
  chk("its old session closed on the remote",
      got("remote", "close", m, { session_id = old }) == 1 and got("local", "close", m, { session_id = old }) == 0)
  chk(":e! keeps the notebook's own completion client", kc ~= nil and kid(bufR) == kc,
      tostring(kc) .. " -> " .. tostring(kid(bufR)))
end)

section(":JupynvimUseLocal leaves remote notebooks running", function()
  local stub = J.clients.stub
  vim.cmd("JupynvimUseLocal")
  chk("the session keys point back here", J._active_alias == nil, tostring(J._active_alias))
  chk("the local backend stays the shared client", side_of(J.client) == "local", side_of(J.client))
  chk("the reloaded remote notebook gets its kernel", kernel_ready(bufR))
  local out = run(bufR, 1, "side=")
  chk("and still runs on it", out:find("side=remote", 1, true) ~= nil, out)
  chk("the remote backend kept running", stub ~= nil and stub.job ~= nil and J.clients.stub == stub)
  -- the remote dashboard's "l Local backend" does the same and says what moved
  pcall(J.use_remote, "stub")
  local was = vim.api.nvim_get_current_buf()
  local dbuf = require("jupynvim.remote.dashboard").build("stub", "~", vim.api.nvim_get_current_win())
  vim.api.nvim_set_current_buf(dbuf)
  local n0 = #notes
  local act
  for _, mp in ipairs(vim.api.nvim_buf_get_keymap(dbuf, "n")) do
    if mp.lhs == "l" then act = mp.callback end
  end
  if act then pcall(act) end
  local k = 0
  for i = n0 + 1, #notes do
    if notes[i] == "jupynvim: explorer, terminal and pickers back on this machine"
        and note_levels[i] == vim.log.levels.INFO then k = k + 1 end
  end
  chk("the dashboard's Local backend action says the explorer, terminal and pickers are back here",
      act ~= nil and k == 1 and J._active_alias == nil and J.clients.stub == stub and stub.job ~= nil,
      ("action %s, %d notes: %s"):format(act and "found" or "missing", k,
        table.concat(vim.list_slice(notes, n0 + 1), " | "):sub(1, 200)))
  if vim.api.nvim_buf_is_valid(was) then pcall(vim.api.nvim_set_current_buf, was) end
end)

section("a name already open from another backend is refused", function()
  local nb = NB.get(bufL)
  local sid, m = nb.session_id, mark()
  local r = J.open(L, { alias = "stub" })
  chk("opening a local notebook's path from the remote is refused", r == nil and noted("already open locally"),
      tostring(r))
  chk("the local notebook stays as it was", NB.get(bufL) == nb and nb.session_id == sid and nb.alias == nil)
  chk("and the remote is never asked", got("remote", "open", m) == 0)
  local sp = spawned["local"] + spawned.remote
  m = mark()
  local again = J.open(L)
  local sent = 0
  for i = m + 1, #calls do
    if calls[i].method:sub(1, 6) ~= "kitty_" then sent = sent + 1 end
  end
  chk("opening an open notebook again focuses it", again == bufL and vim.api.nvim_get_current_buf() == bufL)
  chk("and sends no notebook request, spawning nothing", sent == 0 and spawned["local"] + spawned.remote == sp,
      sent .. " requests")
  -- from a remote that is not running: refused before anything starts
  local n0 = count_noted("already open locally")
  m = mark()
  local r2 = J.open(L, { alias = "stub2" })
  local sent2 = 0
  for i = m + 1, #calls do
    if calls[i].method:sub(1, 6) ~= "kitty_" then sent2 = sent2 + 1 end
  end
  chk("opening it from a remote that is not running is refused too",
      r2 == nil and count_noted("already open locally") > n0, tostring(r2))
  chk("and that remote is not started for it",
      (spawned.remote2 or 0) == 0 and J.clients.stub2 == nil and sent2 == 0,
      ("stub2 spawns %d, %d requests"):format(spawned.remote2 or 0, sent2))
  -- one path open from one remote is refused from another
  local nbR = NB.get(bufR)
  local sidR = nbR.session_id
  local r3 = J.open(R, { alias = "stub2" })
  chk("a notebook open from one remote is refused from another",
      r3 == nil and noted("already open from stub. Close it with :bwipeout before opening it from stub2"),
      tostring(r3))
  chk("it stays on its own remote, the other never started",
      NB.get(bufR) == nbR and nbR.session_id == sidR and nbR.alias == "stub" and (spawned.remote2 or 0) == 0)
  -- and a remote notebook's path opened locally
  m = mark()
  local r4 = J.open(R)
  chk("opening a remote notebook's path locally is refused",
      r4 == nil and noted("already open from stub. Close it with :bwipeout before opening it locally"), tostring(r4))
  chk("the remote notebook stays as it was, the local backend never asked",
      NB.get(bufR) == nbR and nbR.session_id == sidR and nbR.alias == "stub" and got("local", "open", m) == 0)
  -- and :edit of that path from another buffer goes to the notebook open
  focus(bufL)
  local n1 = #notes
  m = mark()
  local oke, erre = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(R))
  -- an open would come from a scheduled callback: give it the chance to run
  wait(500, function() return got("remote", "open", m) + got("local", "open", m) > 0 end)
  chk(":edit of a remote notebook's path goes to the notebook already open",
      oke and vim.api.nvim_get_current_buf() == bufR and NB.get(bufR) == nbR and nbR.session_id == sidR
        and nbR.alias == "stub" and got("remote", "open", m) + got("local", "open", m) == 0
        and got("remote", "close", m) + got("local", "close", m) == 0 and #notes == n1,
      ("%s, current buffer %d, wanted %d, %d opens, %d new messages"):format(oke and "ok" or tostring(erre):sub(1, 80),
        vim.api.nvim_get_current_buf(), bufR, got("remote", "open", m) + got("local", "open", m), #notes - n1))
end)

section("a remote notebook is one notebook however its path is spelled", function()
  -- The explorer and the pickers name a remote file by the absolute path
  -- fs_list gave them; :JupynvimOpenRemote and :JupynvimEdit name it by the
  -- home ("~/x", or a relative "x"). Opened both ways, one notebook became
  -- two buffers with two sessions and two kernels, and a :w in either
  -- overwrote what the other saved.
  local function count_nbs(tail)
    local n = 0
    for _, nn in pairs(NB.all()) do
      if nn.path:sub(-#tail) == tail then n = n + 1 end
    end
    return n
  end
  -- open requests the remote got for a file whose path ends with `tail`
  local function opens(from, tail)
    local n = 0
    for i = from + 1, #calls do
      local c = calls[i]
      if c.side == "remote" and c.method == "open" and tostring(c.params.path):sub(-#tail) == tail then n = n + 1 end
    end
    return n
  end
  local function named(substr)
    local out = {}
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(b):find(substr, 1, true) then out[#out + 1] = b end
    end
    return out
  end

  -- ~/name first, then the absolute path the explorer gives
  local A = "spellA-" .. TAG .. ".ipynb"
  write_nb(RHOME .. "/" .. A, PNG_R)
  forget_home("stub")   -- this backend has not been asked its home yet
  local m = mark()
  vim.cmd("JupynvimOpenRemote stub:~/" .. A)
  local bA, nbA
  wait(15000, function() bA, nbA = nb_ending("/" .. A); return nbA ~= nil end)
  chk("a notebook opened by ~/name is named by its absolute path",
      nbA ~= nil and nbA.path == RHOME .. "/" .. A
        and vim.fn.resolve(vim.api.nvim_buf_get_name(bA)) == vim.fn.resolve(RHOME .. "/" .. A),
      nbA and (nbA.path .. ", buffer " .. vim.api.nvim_buf_get_name(bA)))
  local sidA = nbA and nbA.session_id
  local bA2 = J.open(RHOME .. "/" .. A, { alias = "stub" })
  chk("then opened by the explorer's absolute path, it is the same notebook",
      nbA ~= nil and bA2 == bA and count_nbs(A) == 1 and NB.get(bA).session_id == sidA,
      ("buffer %s, %d notebooks"):format(tostring(bA2), count_nbs(A)))
  chk("and its remote was asked to open it once", opens(m, A) == 1, opens(m, A) .. " opens")

  -- the other order, the backend's home not known yet
  local B = "spellB-" .. TAG .. ".ipynb"
  write_nb(RHOME .. "/" .. B, PNG_R)
  m = mark()
  local bB = J.open(RHOME .. "/" .. B, { alias = "stub" })
  forget_home("stub")
  vim.cmd("JupynvimOpenRemote stub:~/" .. B)
  vim.wait(200)
  chk("opened by the absolute path first, then by ~/name: the same notebook, shown",
      bB ~= nil and count_nbs(B) == 1 and vim.api.nvim_get_current_buf() == bB,
      ("%d notebooks, current buffer %d, wanted %s"):format(count_nbs(B), vim.api.nvim_get_current_buf(), tostring(bB)))
  chk("and its remote was asked to open it once", opens(m, B) == 1, opens(m, B) .. " opens")

  -- the other spellings of the one name. Neovim itself reads a "./" or "//"
  -- in a directory that exists on this machine too (the stub remote shares
  -- its disk) as the plain path, and finds a file there by identity; on a
  -- real remote it does neither. So these open a notebook that is on no disk
  -- (the remote makes a new one), and the name function is checked directly
  -- below.
  local N = "spellN-" .. TAG .. ".ipynb"
  local bN = J.open(RHOME .. "/" .. N, { alias = "stub" })
  chk("a new notebook opens on the remote by its absolute path", bN ~= nil and count_nbs(N) == 1, tostring(bN))
  if bN then kernel_ready(bN, 20000) end
  for _, c in ipairs({ { "stub:" .. N, "a name relative to the home" }, { "stub:./" .. N, "a ./ name" },
                       { "stub:~/./" .. N, "a ~/./ name" }, { "stub:~//" .. N, "a ~// name" } }) do
    m = mark()
    pcall(vim.cmd, "JupynvimOpenRemote " .. c[1])
    vim.wait(100)
    chk(c[2] .. " is the notebook already open",
        bN ~= nil and count_nbs(N) == 1 and vim.api.nvim_get_current_buf() == bN and opens(m, N) == 0,
        ("%d notebooks, %d opens, current buffer %d, wanted %s"):format(count_nbs(N), opens(m, N),
          vim.api.nvim_get_current_buf(), tostring(bN)))
  end
  m = mark()
  local bS = J.open(RHOME .. "//./" .. N, { alias = "stub" })
  chk("and so is an absolute path with a // and a ./ in it", bN ~= nil and bS == bN and count_nbs(N) == 1
      and opens(m, N) == 0, ("buffer %s, %d notebooks, %d opens"):format(tostring(bS), count_nbs(N), opens(m, N)))
  -- the name function itself (a tree without it fails this check and still
  -- runs the behavior checks after it)
  if J._remote_name then
    local function nm(p) return (J._remote_name("stub", p)) end
    chk("a path's spellings are one name; .. is left alone",
        nm("/~/./X") == RHOME .. "/X" and nm("/~/a//b") == RHOME .. "/a/b" and nm(RHOME .. "//./X") == RHOME .. "/X"
          and nm("/~") == RHOME and nm("/~/.") == RHOME and nm("/a/b/.") == "/a/b" and nm("/") == "/"
          and nm("/~/x/../y") == RHOME .. "/x/../y",
        table.concat({ nm("/~/./X"), nm("/~/a//b"), nm(RHOME .. "//./X"), nm("/~"), nm("/~/."), nm("/a/b/."),
                       nm("/"), nm("/~/x/../y") }, " "))
  else
    chk("a path's spellings are one name; .. is left alone", false, "no J._remote_name")
  end
  if bN then wipe({ bN }) end

  if nbA then
    -- :JupynvimEdit of a notebook goes through its URI
    m = mark()
    local okj, errj = pcall(vim.cmd, "JupynvimEdit stub:~/" .. A)
    wait(2000, function() return #named("jupynvim://stub/~/") == 0 end)
    chk(":JupynvimEdit of ~/name is the notebook already open, with no buffer left behind",
        okj and count_nbs(A) == 1 and vim.api.nvim_get_current_buf() == bA and opens(m, A) == 0
          and #named("jupynvim://stub/~/") == 0,
        okj and ("%d notebooks, %d opens, %d URI buffers"):format(count_nbs(A), opens(m, A),
          #named("jupynvim://stub/~/")) or tostring(errj):sub(1, 120))
  end

  -- a text file: the same two names
  local T, T2 = "spellT-" .. TAG .. ".txt", "spellU-" .. TAG .. ".txt"
  for _, t in ipairs({ T, T2 }) do
    local f = assert(io.open(RHOME .. "/" .. t, "w"))
    f:write("SPELLED\n")
    f:close()
  end
  local function uri_of(t) return "jupynvim://stub" .. RHOME .. "/" .. t end
  forget_home("stub")
  m = mark()
  vim.cmd("JupynvimEdit stub:~/" .. T)
  local bT = vim.api.nvim_get_current_buf()
  chk(":JupynvimEdit of ~/name on a text file names the buffer by the file's absolute path",
      vim.api.nvim_buf_get_name(bT) == uri_of(T) and vim.api.nvim_buf_get_lines(bT, 0, 1, false)[1] == "SPELLED",
      vim.api.nvim_buf_get_name(bT))
  -- the way the explorer opens it, from another buffer (:edit of the buffer
  -- it is in reads the file again)
  vim.cmd("enew")
  vim.cmd("edit " .. vim.fn.fnameescape(uri_of(T)))
  chk("then opened by the explorer's name, it is the buffer already open",
      vim.api.nvim_get_current_buf() == bT and #named("/" .. T) == 1 and got("remote", "fs_read", m) == 1,
      ("%d buffers, %d reads"):format(#named("/" .. T), got("remote", "fs_read", m)))

  m = mark()
  vim.cmd("edit " .. vim.fn.fnameescape(uri_of(T2)))
  local bU = vim.api.nvim_get_current_buf()
  forget_home("stub")
  vim.cmd("enew")
  pcall(vim.cmd, "JupynvimEdit stub:~/" .. T2)
  local same_edit = vim.api.nvim_get_current_buf() == bU
  vim.cmd("enew")
  pcall(vim.cmd, "JupynvimOpenRemote stub:" .. T2)
  local same_open = vim.api.nvim_get_current_buf() == bU
  vim.cmd("enew")
  pcall(vim.cmd, "edit jupynvim://stub/~/" .. T2)   -- the URI typed by hand
  wait(2000, function() return #named("/~/") == 0 end)
  chk("opened by its absolute name first, then as ~/name, a relative name and a typed URI: one buffer",
      same_edit and same_open and vim.api.nvim_get_current_buf() == bU and #named("/" .. T2) == 1
        and #named("/~/") == 0 and got("remote", "fs_read", m) == 1,
      ("edit %s, open %s, current %d (wanted %d), %d buffers, %d with /~/, %d reads"):format(tostring(same_edit),
        tostring(same_open), vim.api.nvim_get_current_buf(), bU, #named("/" .. T2), #named("/~/"),
        got("remote", "fs_read", m)))

  -- the tree's first listing of the home says where it is
  local RE = require("jupynvim.remote.explorer")
  RE.reset("stub")
  forget_home("stub")
  RE.open("stub")
  wait(15000, function() return known_home("stub") ~= nil end)
  chk("the explorer's listing of ~ tells the home", known_home("stub") == RHOME, tostring(known_home("stub")))
  RE.reset("stub")

  pcall(vim.cmd, "silent! only!")
  local left = { bA, bB }
  for _, t in ipairs({ T, T2 }) do
    for _, b in ipairs(named("/" .. t)) do left[#left + 1] = b end
  end
  wipe(left)
end)

section("a backend that cannot say its home still opens a notebook once", function()
  -- A backend from before fs_stat said the path it stat'ed cannot tell the
  -- home up front. The path its open reply names is then the file's name:
  -- a notebook opened by ~/name takes it, and one already open under it is
  -- found after the reply and the extra session closed.
  local function count_nbs(tail)
    local n = 0
    for _, nn in pairs(NB.all()) do
      if nn.path:sub(-#tail) == tail then n = n + 1 end
    end
    return n
  end
  local C, D = "oldC-" .. TAG .. ".ipynb", "oldD-" .. TAG .. ".ipynb"
  write_nb(RHOME .. "/" .. C, PNG_R)
  write_nb(RHOME .. "/" .. D, PNG_R)
  STAT_WITHOUT_PATH = true
  forget_home("stub")
  local m = mark()
  vim.cmd("JupynvimOpenRemote stub:~/" .. C)
  local bC, nbC
  wait(15000, function() bC, nbC = nb_ending("/" .. C); return nbC ~= nil end)
  chk("a notebook opened by ~/name is named by the path its backend opened",
      nbC ~= nil and nbC.path == RHOME .. "/" .. C and known_home("stub") == RHOME,
      ("%s, home %s"):format(tostring(nbC and nbC.path), tostring(known_home("stub"))))
  if nbC then kernel_ready(bC, 20000) end

  local bD = J.open(RHOME .. "/" .. D, { alias = "stub" })
  if bD then kernel_ready(bD, 20000) end
  forget_home("stub")
  m = mark()
  vim.cmd("JupynvimOpenRemote stub:~/" .. D)
  vim.wait(300)
  local n_open = 0
  for i = m + 1, #calls do
    local c = calls[i]
    if c.side == "remote" and c.method == "open" and tostring(c.params.path):sub(-#D) == D then n_open = n_open + 1 end
  end
  chk("opened by the absolute path first, then by ~/name: the same notebook, shown",
      bD ~= nil and count_nbs(D) == 1 and vim.api.nvim_get_current_buf() == bD,
      ("%d notebooks, current buffer %d, wanted %s"):format(count_nbs(D), vim.api.nvim_get_current_buf(), tostring(bD)))
  chk("its extra session is closed on the remote and no kernel starts for it",
      n_open == 1 and got("remote", "close", m) == 1 and got("remote", "start_kernel", m) == 0,
      ("%d opens, %d closes, %d kernel starts"):format(n_open, got("remote", "close", m),
        got("remote", "start_kernel", m)))
  STAT_WITHOUT_PATH = false
  wipe({ bC, bD })
end)

section(":edit of a path after :bdelete brings the remote notebook back and says so; :bwipeout frees it", function()
  -- :bdelete hides the buffer and keeps its notebook, and the backend it came
  -- from. The path is the same text as this machine's file where both have it
  -- (a shared home, a container with the project mounted at one path), so a
  -- :edit of it reopened the remote notebook with no word, and the README
  -- said :bdelete frees the path.
  local P = LDIR .. "/bdwipe-" .. TAG .. ".ipynb"
  write_nb(P, PNG_R)
  local b = J.open(P, { alias = "stub" })
  local nb0 = b and NB.get(b)
  chk("a remote notebook opens under a path this machine has too", nb0 ~= nil and nb0.alias == "stub",
      nb0 and tostring(nb0.alias))
  if not nb0 then return end
  kernel_ready(b, 20000)
  local old = nb0.session_id
  vim.cmd("bdelete " .. b)
  local n0, m = #notes, mark()
  vim.cmd("edit " .. vim.fn.fnameescape(P))
  wait(15000, function() local n = NB.get(b); return n ~= nil and n.session_id ~= old end)
  local nb = NB.get(b)
  chk(":edit of the path after :bdelete reopens the notebook on its remote",
      nb ~= nil and nb.alias == "stub" and got("remote", "open", m, { path = P }) == 1 and got("local", "open", m) == 0,
      nb and tostring(nb.alias))
  local said_from = 0
  for i = n0 + 1, #notes do
    local n = notes[i]
    if n:find(P, 1, true) and n:find("stub", 1, true) and n:find(":bwipeout", 1, true) then said_from = said_from + 1 end
  end
  chk("and says it came from the remote, and how to open this machine's file", said_from == 1,
      said_from .. " messages")
  if not nb then return end
  kernel_ready(b, 20000)
  -- a notebook still open is read again without a word
  local old2, n1 = nb.session_id, #notes
  focus(b)
  vim.cmd("edit!")
  wait(15000, function() local n = NB.get(b); return n ~= nil and n.session_id ~= old2 end)
  local extra = 0
  for i = n1 + 1, #notes do
    if notes[i]:find(":bwipeout", 1, true) then extra = extra + 1 end
  end
  chk(":e! of a remote notebook that is open says nothing about where it came from", extra == 0, extra .. " messages")
  -- :bwipeout drops the notebook and the backend it came from
  kernel_ready(b, 20000)
  local sid, m2 = NB.get(b).session_id, mark()
  vim.cmd("bwipeout! " .. b)
  chk(":bwipeout closes the remote session", got("remote", "close", m2, { session_id = sid }) == 1)
  vim.cmd("edit " .. vim.fn.fnameescape(P))
  local b2, nb2
  wait(15000, function() b2, nb2 = nb_at(P); return nb2 ~= nil end)
  chk(":edit of the path after :bwipeout opens this machine's file, on the local backend",
      nb2 ~= nil and nb2.alias == nil and got("local", "open", m2, { path = P }) == 1 and got("remote", "open", m2) == 0,
      nb2 and tostring(nb2.alias))
  if b2 then wipe({ b2 }) end
end)

section("a remote notebook closed with :bdelete reopens from the remote's side without a word", function()
  -- The remote explorer, the pickers, :JupynvimOpenRemote and a jupynvim://
  -- URI open a notebook by its remote path. Closed with :bdelete (LazyVim's
  -- <leader>bd, a bufferline close button), it was shown again and read
  -- through the *.ipynb BufReadCmd, which took that read for an :edit of the
  -- path: every close and reopen said the notebook "is open from stub" and
  -- how to open this machine's file.
  local name = "bdre-" .. TAG .. ".ipynb"
  local P = RHOME .. "/" .. name
  write_nb(P, PNG_R)
  local b = J.open(P, { alias = "stub" })
  local nb0 = b and NB.get(b)
  chk("a remote notebook opens the way the explorer opens it", nb0 ~= nil and nb0.alias == "stub",
      nb0 and tostring(nb0.alias))
  if not nb0 then return end
  local routes = {
    { "the explorer's open", function() J.open(P, { alias = "stub" }) end },
    { ":JupynvimOpenRemote by the absolute path", function() vim.cmd("JupynvimOpenRemote stub:" .. P) end },
    { ":JupynvimOpenRemote by ~/name", function() vim.cmd("JupynvimOpenRemote stub:~/" .. name) end },
    { "a jupynvim:// URI", function() vim.cmd("edit " .. vim.fn.fnameescape("jupynvim://stub" .. P)) end },
  }
  for _, r in ipairs(routes) do
    kernel_ready(b, 20000)
    local old = NB.get(b) and NB.get(b).session_id
    vim.cmd("bdelete " .. b)
    local n0, m = #notes, mark()
    local okr, errr = pcall(r[2])
    wait(15000, function()
      local n = NB.get(b)
      return n ~= nil and n.session_id ~= old and vim.api.nvim_buf_is_loaded(b) and vim.api.nvim_get_current_buf() == b
    end)
    vim.wait(200)
    local nb = NB.get(b)
    chk(r[1] .. " after :bdelete reopens the notebook on its remote, in its own buffer",
        okr and nb ~= nil and nb.alias == "stub" and nb.session_id ~= old and vim.api.nvim_buf_is_loaded(b)
          and vim.bo[b].buflisted and vim.api.nvim_get_current_buf() == b
          and got("remote", "open", m, { path = P }) == 1 and got("local", "open", m) == 0
          and got("remote", "close", m, { session_id = old }) == 1,
        okr and ("alias %s, %d opens, %d closes of the old session, current buffer %d (wanted %d)"):format(
          tostring(nb and nb.alias), got("remote", "open", m, { path = P }), got("remote", "close", m, { session_id = old }),
          vim.api.nvim_get_current_buf(), b) or tostring(errr))
    local said = {}
    for i = n0 + 1, #notes do
      if notes[i]:find("reopened there", 1, true) or notes[i]:find(":bwipeout", 1, true) then
        said[#said + 1] = notes[i]:sub(1, 120)
      end
    end
    chk(r[1] .. " after :bdelete says nothing about where it came from", #said == 0,
        #said .. " messages: " .. table.concat(said, " | "))
  end
  wipe({ b })
end)

section(":edit after :bdelete of a remote notebook whose path this machine lacks only says where it came from", function()
  -- How to open "this machine's file" is advice for a path this machine has.
  -- A remote's own path (a laptop and a Linux cluster) is on no local disk.
  -- The stub shares this disk, so the file goes once the remote has it open:
  -- the remote's session still holds the notebook.
  local dir = RHOME .. "/gone-" .. TAG
  vim.fn.mkdir(dir, "p")
  local P = dir .. "/G.ipynb"
  write_nb(P, PNG_R)
  local b = J.open(P, { alias = "stub" })
  local nb0 = b and NB.get(b)
  chk("a remote notebook opens", nb0 ~= nil and nb0.alias == "stub", nb0 and tostring(nb0.alias))
  if not nb0 then return end
  kernel_ready(b, 20000)
  local old = nb0.session_id
  vim.cmd("bdelete " .. b)
  os.remove(P)
  local n0, m = #notes, mark()
  vim.cmd("edit " .. vim.fn.fnameescape(P))
  wait(15000, function() local n = NB.get(b); return n ~= nil and n.session_id ~= old end)
  local nb = NB.get(b)
  chk(":edit of its path after :bdelete reopens it on its remote",
      nb ~= nil and nb.alias == "stub" and got("remote", "open", m, { path = P }) == 1 and got("local", "open", m) == 0,
      nb and tostring(nb.alias))
  local from, advice = 0, {}
  for i = n0 + 1, #notes do
    local n = notes[i]
    if n:find(P, 1, true) and n:find("stub", 1, true) and n:find("reopened there", 1, true) then from = from + 1 end
    if n:find("this machine", 1, true) or n:find(":bwipeout", 1, true) then advice[#advice + 1] = n:sub(1, 160) end
  end
  chk("and says once that it came from the remote", from == 1, from .. " messages")
  chk("with no advice to open a file this machine does not have", #advice == 0, table.concat(advice, " | "))
  wipe({ b })
end)

section("a home lookup that fails is asked again; one that times out ends the open after one wait", function()
  local function named(substr)
    local out = {}
    for _, bb in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(bb):find(substr, 1, true) then out[#out + 1] = bb end
    end
    return out
  end
  local function text_file(t, s)
    local f = assert(io.open(RHOME .. "/" .. t, "w"))
    f:write(s .. "\n")
    f:close()
  end
  local function uri_of(t) return "jupynvim://stub" .. RHOME .. "/" .. t end
  local function first_line(bb) return vim.api.nvim_buf_get_lines(bb, 0, 1, false)[1] end
  local function since(n0, text)
    local k = 0
    for i = n0 + 1, #notes do if notes[i]:find(text, 1, true) then k = k + 1 end end
    return k
  end
  local GONE = "backend exited (code=255) - not connected? :JupynvimConnect"
  pcall(vim.cmd, "silent! only!")

  -- The first ask fails (the remote not connected yet, its backend gone at
  -- once); the read of the file asks again and names it by its absolute path.
  local T1 = "failA-" .. TAG .. ".txt"
  text_file(T1, "FAILED-ONCE")
  forget_home("stub")
  INJECT.fs_stat = { side = "remote", err = GONE, n = 1 }
  vim.cmd("enew")
  pcall(vim.cmd, "JupynvimEdit stub:~/" .. T1)
  wait(3000, function() return #named("/~/") == 0 and vim.api.nvim_buf_get_name(0) == uri_of(T1) end)
  local b1 = vim.api.nvim_get_current_buf()
  vim.cmd("enew")
  vim.cmd("edit " .. vim.fn.fnameescape(uri_of(T1)))
  chk(":JupynvimEdit of ~/name after a failed home lookup, then the explorer's name: one buffer",
      vim.api.nvim_get_current_buf() == b1 and #named("/" .. T1) == 1 and #named("/~/") == 0
        and first_line(b1) == "FAILED-ONCE",
      ("%d buffers, %d with /~/, current %s"):format(#named("/" .. T1), #named("/~/"),
        vim.api.nvim_buf_get_name(0)))

  -- Every ask of one action fails; the next name, in a later action, asks
  -- again (a remote that connected in between).
  local T2a, T2 = "failB0-" .. TAG .. ".txt", "failB-" .. TAG .. ".txt"
  text_file(T2a, "B0")
  text_file(T2, "AFTER-FAIL")
  forget_home("stub")
  INJECT.fs_stat = { side = "remote", err = GONE, n = 2 }
  vim.cmd("enew")
  pcall(vim.cmd, "JupynvimEdit stub:~/" .. T2a)
  INJECT.fs_stat = nil
  vim.cmd("enew")
  pcall(vim.cmd, "JupynvimEdit stub:~/" .. T2)
  wait(3000, function() return vim.api.nvim_buf_get_name(0) == uri_of(T2) end)
  local b2 = vim.api.nvim_get_current_buf()
  vim.cmd("enew")
  vim.cmd("edit " .. vim.fn.fnameescape(uri_of(T2)))
  chk("after a failed home lookup the next name asks again: ~/name and the explorer's name are one buffer",
      vim.api.nvim_get_current_buf() == b2 and #named("/" .. T2) == 1 and first_line(b2) == "AFTER-FAIL"
        and known_home("stub") == RHOME,
      ("%d buffers, home %s, current %s"):format(#named("/" .. T2), tostring(known_home("stub")),
        vim.api.nvim_buf_get_name(0)))

  -- A lookup that times out had the whole wait a remote request gets: the
  -- open, or the read, would wait as long again. Each stops and says so.
  local N3 = "failC-" .. TAG .. ".ipynb"
  write_nb(RHOME .. "/" .. N3, PNG_R)
  forget_home("stub")
  INJECT.fs_stat = { side = "remote", err = "timeout", n = 1 }
  local m, n0 = mark(), #notes
  local okt, r3 = pcall(J.open, "~/" .. N3, { alias = "stub" })
  local _, nb3 = nb_ending("/" .. N3)
  chk("an open whose home lookup timed out sends no open and says it timed out",
      okt and r3 == nil and nb3 == nil and got("remote", "open", m) == 0 and since(n0, "jupynvim open failed: timeout") == 1,
      ("returned %s, %d opens, %d notes"):format(tostring(r3), got("remote", "open", m),
        since(n0, "jupynvim open failed: timeout")))
  INJECT.fs_stat = nil
  m = mark()
  local b3 = J.open("~/" .. N3, { alias = "stub" })
  local nb3b = b3 and NB.get(b3)
  chk("and the next open asks again and names the notebook by its absolute path",
      nb3b ~= nil and nb3b.path == RHOME .. "/" .. N3 and got("remote", "fs_stat", m, { path = "/~" }) == 1,
      ("%s, %d asks"):format(tostring(nb3b and nb3b.path), got("remote", "fs_stat", m, { path = "/~" })))
  if b3 then wipe({ b3 }) end

  for _, c in ipairs({
    { ":JupynvimEdit", function(t) vim.cmd("JupynvimEdit stub:~/" .. t) end },
    { ":JupynvimOpenRemote", function(t) vim.cmd("JupynvimOpenRemote stub:~/" .. t) end },
    { "a typed jupynvim:// URI", function(t) vim.cmd("edit jupynvim://stub/~/" .. t) end },
  }) do
    local t = "failD-" .. TAG .. "-" .. c[1]:gsub("[^%w]", "") .. ".txt"
    text_file(t, "D")
    forget_home("stub")
    INJECT.fs_stat = { side = "remote", err = "timeout", n = 1 }
    vim.cmd("enew")
    m, n0 = mark(), #notes
    pcall(c[2], t)
    vim.wait(200)
    INJECT.fs_stat = nil
    local loaded = 0
    for _, bb in ipairs(named("/" .. t)) do
      if vim.api.nvim_buf_is_loaded(bb) and first_line(bb) == "D" then loaded = loaded + 1 end
    end
    -- the request that timed out is the home lookup, not a read
    chk(c[1] .. " of ~/name whose home lookup timed out reads nothing and says the remote did not answer",
        got("remote", "fs_read", m) == 0 and loaded == 0
          and since(n0, "jupynvim: stub did not answer (timeout)") == 1 and since(n0, "fs_read") == 0,
        ("%d reads, %d buffers with the file, notes: %s"):format(got("remote", "fs_read", m), loaded,
          table.concat(vim.list_slice(notes, n0 + 1), " | "):sub(1, 200)))
    wipe(named("/" .. t))
  end

  vim.cmd("enew")
  local left = {}
  for _, t in ipairs({ T1, T2a, T2 }) do
    for _, bb in ipairs(named("/" .. t)) do left[#left + 1] = bb end
  end
  wipe(left)
end)

section(":JupynvimConnect and :JupynvimUseJob ask the new backend its home again", function()
  -- Both stop an alias's backend and start a fresh one (a new binary, a
  -- compute node). What the old one could not say is asked of the new one.
  -- A profile of its own, so the stub's notebooks keep their backend; ssh's
  -- control-socket check answers "alive" and the explorer stays shut.
  J.config.remote.homestub = { host = "homestub.invalid",
    transport_cmd = { "env", "JNV_SIDE=homestub", "HOME=" .. RHOME, "PYTHONUSERBASE=" .. USERBASE, CORE } }
  local sys, browse, active = vim.fn.system, J.remote_browse, J._active_alias
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.fn.system = function(cmd, ...)
    if type(cmd) == "table" and cmd[1] == "ssh" and cmd[2] == "-O" and cmd[3] == "check" then return sys({ "true" }) end
    return sys(cmd, ...)
  end
  J.remote_browse = function() end
  local ok, err = pcall(function()
    for _, c in ipairs({ { ":JupynvimConnect", function() J.connect("homestub") end },
                         { ":JupynvimUseJob", function() J.use_job("homestub") end } }) do
      -- a backend that answers without saying its home (an older binary)
      STAT_WITHOUT_PATH = true
      forget_home("homestub")
      local _ = J._remote_name and J._remote_name("homestub", "/~/x")
      local was = J._remote_homes and J._remote_homes.homestub
      STAT_WITHOUT_PATH = false
      local old = J.clients.homestub
      c[2]()
      local name = J._remote_name and J._remote_name("homestub", "/~/x")
      chk(c[1] .. " asks the new backend its home again",
          was == false and J.clients.homestub ~= old and name == RHOME .. "/x",
          ("before %s, new backend %s, name %s"):format(tostring(was), tostring(J.clients.homestub ~= old),
            tostring(name)))
    end
  end)
  STAT_WITHOUT_PATH = false
  vim.fn.system, J.remote_browse = sys, browse
  pcall(J._set_active_alias, active)
  local cl = J.clients.homestub
  if cl then pcall(function() cl:stop() end) end
  J.clients.homestub = nil
  J.config.remote.homestub = nil
  if not ok then error(err, 0) end
end)

section("a ~/ URI opened in a split is replaced in that split", function()
  -- The URI buffer was deleted before its file's buffer took its place: the
  -- split closed, and the file's buffer replaced what the other window showed.
  local function named(substr)
    local out = {}
    for _, bb in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(bb):find(substr, 1, true) then out[#out + 1] = bb end
    end
    return out
  end
  local V = "splitV-" .. TAG .. ".txt"
  local f = assert(io.open(RHOME .. "/" .. V, "w"))
  f:write("SPLIT\n")
  f:close()
  local canon = "jupynvim://stub" .. RHOME .. "/" .. V
  -- the home already learned (a tree without the table has no redirect)
  if J._remote_homes then J._remote_homes.stub = RHOME end
  pcall(vim.cmd, "silent! only!")
  vim.cmd("enew")
  local keep = vim.api.nvim_get_current_buf()
  vim.bo[keep].buftype = "nofile"
  vim.api.nvim_buf_set_lines(keep, 0, -1, false, { "KEEP" })
  local w0 = vim.api.nvim_get_current_win()
  pcall(vim.cmd, "vsplit " .. vim.fn.fnameescape("jupynvim://stub/~/" .. V))
  local w1 = vim.api.nvim_get_current_win()
  wait(3000, function() return #named("/~/") == 0 end)
  vim.wait(100)
  local function shows(w) return vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_buf(w) or -1 end
  local tb = shows(w1)
  chk("the split shows the file's buffer, by its absolute name, and the other window keeps its own",
      #vim.api.nvim_tabpage_list_wins(0) == 2 and w1 ~= w0 and tb > 0 and vim.api.nvim_buf_get_name(tb) == canon
        and vim.api.nvim_buf_get_lines(tb, 0, 1, false)[1] == "SPLIT" and shows(w0) == keep
        and vim.api.nvim_get_current_win() == w1 and #named("/~/") == 0,
      ("%d windows, split shows %s, other shows %s"):format(#vim.api.nvim_tabpage_list_wins(0),
        tb > 0 and vim.api.nvim_buf_get_name(tb) or "nothing", shows(w0) == keep and "its own" or tostring(shows(w0))))
  -- the file's buffer already open: a second split of the ~/ URI shows it too
  pcall(vim.api.nvim_set_current_win, w0)
  pcall(vim.cmd, "vsplit " .. vim.fn.fnameescape("jupynvim://stub/~/" .. V))
  local w2 = vim.api.nvim_get_current_win()
  wait(3000, function() return #named("/~/") == 0 end)
  vim.wait(100)
  chk("a second split of it shows the buffer already open; the other windows keep theirs",
      #vim.api.nvim_tabpage_list_wins(0) == 3 and w2 ~= w0 and shows(w2) == tb and shows(w1) == tb and shows(w0) == keep
        and #named("/" .. V) == 1 and #named("/~/") == 0,
      ("%d windows, %d buffers"):format(#vim.api.nvim_tabpage_list_wins(0), #named("/" .. V)))
  pcall(vim.cmd, "silent! only!")
  vim.cmd("enew")
  wipe(named("/" .. V))
  wipe({ keep })
end)

section("after a ~/ URI is read, <C-^> goes back to the file before it", function()
  -- The redirect read the file's absolute name in the window while the URI
  -- buffer was still shown there, and put the buffer into other windows with
  -- nvim_win_set_buf: each window's alternate file became the URI buffer,
  -- which was then wiped, so <C-^> said E23 and :b# E86. In train.py,
  -- :e jupynvim://psc/~/notes.txt and then <C-^> is how a user meets it.
  local function named(substr)
    local out = {}
    for _, bb in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(bb):find(substr, 1, true) then out[#out + 1] = bb end
    end
    return out
  end
  local X = LDIR .. "/alt-" .. TAG .. ".py"
  do
    local f = assert(io.open(X, "w"))
    f:write("print('train')\n")
    f:close()
  end
  local A, Bn = "altA-" .. TAG .. ".txt", "altB-" .. TAG .. ".txt"
  for _, t in ipairs({ A, Bn }) do
    local f = assert(io.open(RHOME .. "/" .. t, "w"))
    f:write("ALT " .. t .. "\n")
    f:close()
  end
  local canonA, canonB = "jupynvim://stub" .. RHOME .. "/" .. A, "jupynvim://stub" .. RHOME .. "/" .. Bn
  -- the home already learned (a tree without the table has no redirect)
  if J._remote_homes then J._remote_homes.stub = RHOME end
  pcall(vim.cmd, "silent! only!")
  vim.cmd("edit " .. vim.fn.fnameescape(X))
  local xb = vim.api.nvim_get_current_buf()
  local function name_of(bb) return bb > 0 and vim.api.nvim_buf_is_valid(bb) and vim.api.nvim_buf_get_name(bb) or "none" end
  -- <C-^> in the current window: what it lands on and what it said
  local function back()
    local okb, e = pcall(vim.cmd, 'exe "normal! \\<C-^>"')
    return vim.api.nvim_get_current_buf(), okb and "" or tostring(e):sub(1, 60)
  end
  local function read_uri(cmd, uri, canon)
    pcall(vim.cmd, cmd .. " " .. vim.fn.fnameescape(uri))
    wait(3000, function() return #named("/~/") == 0 and vim.api.nvim_buf_get_name(0) == canon end)
    vim.wait(100)
  end
  local function lands_on_x(what, canon)
    local on = vim.api.nvim_buf_get_name(0) == canon
    local alt = vim.fn.bufnr("#")
    local lb, e = back()
    chk(what, on and alt == xb and lb == xb,
        ("on %s, # is %s, <C-^> lands on %s %s"):format(on and "the file" or name_of(vim.api.nvim_get_current_buf()),
          name_of(alt), name_of(lb), e))
  end
  -- 1. the file's buffer made by this read
  read_uri("edit", "jupynvim://stub/~/" .. A, canonA)
  lands_on_x("read into a new buffer: <C-^> goes back to the file before it", canonA)
  -- 2. the file's buffer already open: it is shown as it is
  vim.cmd("buffer " .. xb)
  read_uri("edit", "jupynvim://stub/~/" .. A, canonA)
  lands_on_x("its buffer already open: <C-^> goes back to the file before it", canonA)
  -- 3. a split of the URI: the split's own alternate is the file it was split from
  vim.cmd("buffer " .. xb)
  local w0 = vim.api.nvim_get_current_win()
  read_uri("vsplit", "jupynvim://stub/~/" .. Bn, canonB)
  local w1 = vim.api.nvim_get_current_win()
  chk("a split of it stays (precondition)", #vim.api.nvim_tabpage_list_wins(0) == 2 and w1 ~= w0
      and vim.api.nvim_win_get_buf(w0) == xb, #vim.api.nvim_tabpage_list_wins(0) .. " windows")
  lands_on_x("in a split: the split's <C-^> goes back to the file it was split from", canonB)
  pcall(vim.cmd, "silent! only!")
  vim.cmd("enew")
  wipe(named("/" .. A))
  wipe(named("/" .. Bn))
  wipe({ xb })
end)

section("a notebook's jupynvim:// URI opened in a split opens in that split", function()
  -- The URI buffer was deleted before the notebook opened: the split closed,
  -- and the notebook replaced what the other window showed.
  local X = LDIR .. "/altnb-" .. TAG .. ".py"
  do
    local f = assert(io.open(X, "w"))
    f:write("print('train')\n")
    f:close()
  end
  local Pv, Pe = RHOME .. "/splitnb-" .. TAG .. ".ipynb", RHOME .. "/editnb-" .. TAG .. ".ipynb"
  write_nb(Pv, PNG_R)
  write_nb(Pe, PNG_R)
  pcall(vim.cmd, "silent! only!")
  vim.cmd("edit " .. vim.fn.fnameescape(X))
  local xb = vim.api.nvim_get_current_buf()
  local w0 = vim.api.nvim_get_current_win()
  -- the URI buffer of `p` is still there
  local function uri_left(p) return vim.fn.bufexists("jupynvim://stub" .. p) == 1 end
  pcall(vim.cmd, "vsplit " .. vim.fn.fnameescape("jupynvim://stub" .. Pv))
  local w1 = vim.api.nvim_get_current_win()
  wait(20000, function() return nb_at(Pv) ~= nil and not uri_left(Pv) end)
  vim.wait(200)
  local bv, nbv = nb_at(Pv)
  local function shows(w) return vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_buf(w) or -1 end
  chk("the split shows the notebook, from its remote, and the other window keeps its file",
      nbv ~= nil and nbv.alias == "stub" and #vim.api.nvim_tabpage_list_wins(0) == 2 and w1 ~= w0
        and shows(w1) == bv and shows(w0) == xb and not uri_left(Pv),
      ("%d windows, split shows %s, other shows %s"):format(#vim.api.nvim_tabpage_list_wins(0),
        vim.api.nvim_win_is_valid(w1) and vim.api.nvim_buf_get_name(shows(w1)) or "closed",
        vim.api.nvim_buf_get_name(math.max(shows(w0), 0))))
  local split_kept = vim.api.nvim_win_is_valid(w1)
  if split_kept then vim.api.nvim_set_current_win(w1) end
  local alt = vim.fn.bufnr("#")
  local okb = pcall(vim.cmd, 'exe "normal! \\<C-^>"')
  chk("the split's <C-^> goes back to the file it was split from",
      split_kept and okb and alt == xb and vim.api.nvim_get_current_buf() == xb,
      ("split %s, # is %d, file %d"):format(split_kept and "kept" or "closed", alt, xb))
  -- :edit of a notebook URI in the one window: <C-^> goes back too
  pcall(vim.cmd, "silent! only!")
  vim.cmd("buffer " .. xb)
  pcall(vim.cmd, "edit " .. vim.fn.fnameescape("jupynvim://stub" .. Pe))
  wait(20000, function() return nb_at(Pe) ~= nil and not uri_left(Pe) end)
  vim.wait(200)
  local be = nb_at(Pe)
  local on = be ~= nil and vim.api.nvim_get_current_buf() == be
  alt = vim.fn.bufnr("#")
  okb = pcall(vim.cmd, 'exe "normal! \\<C-^>"')
  chk(":edit of a notebook URI: the notebook opens there and <C-^> goes back to the file before it",
      on and not uri_left(Pe) and okb and alt == xb and vim.api.nvim_get_current_buf() == xb, ("on %s, # is %d, file %d"):format(
        tostring(on), alt, xb))
  pcall(vim.cmd, "silent! only!")
  vim.cmd("enew")
  wipe({ bv, be, xb })
end)

section("a remote path that a local notebook's name ends with opens on the remote", function()
  -- the local notebook <tmp>/x<RHOME>/S.ipynb: its name ends with the remote
  -- path <RHOME>/S.ipynb, which a lookup by bufnr() alone takes for it
  local RS = RHOME .. "/S.ipynb"
  local LS = tmp .. "/x" .. RS
  vim.fn.mkdir(vim.fn.fnamemodify(LS, ":h"), "p")
  write_nb(RS, PNG_R)
  write_nb(LS, PNG_L)
  local bl = J.open(LS)
  local nbl = bl and NB.get(bl)
  chk("a local notebook opens under a directory named like a remote path", nbl ~= nil and nbl.alias == nil,
      nbl and tostring(nbl.alias))
  if not nbl then return end
  local name, m = vim.api.nvim_buf_get_name(bl), mark()
  local br = J.open(RS, { alias = "stub" })
  local nbr = br and NB.get(br)
  chk("a remote notebook whose path a local notebook's name ends with opens on its remote",
      nbr ~= nil and nbr.alias == "stub" and got("remote", "open", m, { path = RS }) == 1,
      nbr and tostring(nbr.alias) or tostring(br))
  chk("in a buffer of its own, the local notebook left as it was",
      br ~= nil and br ~= bl and NB.get(bl) == nbl and nbl.alias == nil and vim.api.nvim_buf_get_name(bl) == name,
      ("%s vs %s, %s"):format(tostring(br), tostring(bl), vim.api.nvim_buf_get_name(bl)))
  for _, b in ipairs({ br or -1, bl }) do
    if vim.api.nvim_buf_is_valid(b) and NB.get(b) then
      kernel_ready(b, 20000)
      vim.cmd("bwipeout! " .. b)
    end
  end
end)

section("a notebook whose name reads as a file pattern keeps its own buffer", function()
  -- <dir>/run[1]/P.ipynb read as a file pattern ([1] is a character class;
  -- ? and {1,x} are wildcards too) also matches the name of
  -- <dir>/run1/P.ipynb, so a lookup by bufnr(path) takes that other
  -- notebook's buffer for it, whichever was opened first
  local n = 0
  for _, kind in ipairs({ "[1]", "?", "{1,x}" }) do
    for _, order in ipairs({ "plain first", "pattern first" }) do
      n = n + 1
      local label = kind .. ", " .. order
      local D = vim.fn.resolve(tmp) .. "/pat" .. n
      vim.fn.mkdir(D .. "/run1", "p")
      vim.fn.mkdir(D .. "/run" .. kind, "p")
      local PLAIN, PAT = D .. "/run1/P.ipynb", D .. "/run" .. kind .. "/P.ipynb"
      write_text(PLAIN, "PLAIN-TEXT")
      write_text(PAT, "PAT-TEXT")
      local bp, bq
      if order == "plain first" then
        bp = J.open(PLAIN)
        bq = J.open(PAT)
      else
        bq = J.open(PAT)
        bp = J.open(PLAIN)
      end
      local nbp, nbq = bp and NB.get(bp), bq and NB.get(bq)
      local both_open = nbp ~= nil and nbq ~= nil and bp ~= bq and nbp.path == PLAIN and nbq.path == PAT
      chk("two local notebooks open, one in a directory named like a file pattern", both_open,
          ("%s: %s and %s"):format(label, tostring(bp), tostring(bq)))
      if both_open then
        kernel_ready(bp, 20000)
        kernel_ready(bq, 20000)
        local sidp, sidq, m = nbp.session_id, nbq.session_id, mark()
        local again = J.open(PAT)
        chk("opening it again focuses its own buffer, not one its name matches as a pattern",
            again == bq and vim.api.nvim_get_current_buf() == bq,
            ("%s: got %s, wanted %s"):format(label, tostring(again), tostring(bq)))
        local plain_again = J.open(PLAIN)
        chk("and the other notebook opens again on its own buffer",
            plain_again == bp and vim.api.nvim_get_current_buf() == bp, ("%s: %s"):format(label, tostring(plain_again)))
        chk("neither open sent a request, the notebooks left as they were",
            got("local", "open", m) == 0 and got("local", "close", m) == 0 and NB.get(bp) == nbp and NB.get(bq) == nbq
              and nbp.session_id == sidp and nbq.session_id == sidq, label)
        focus(bq)
        vim.cmd("edit!")
        wait(15000, function()
          local a, b2 = NB.get(bq), NB.get(bp)
          return (a ~= nil and a.session_id ~= sidq) or (b2 ~= nil and b2.session_id ~= sidp)
        end)
        local nq, np = NB.get(bq), NB.get(bp)
        chk(":e! of it reloads it, from its own file",
            nq ~= nil and nq.session_id ~= sidq and nq.path == PAT and got("local", "open", m, { path = PAT }) == 1,
            ("%s: %s"):format(label, nq and nq.path or "no notebook"))
        chk("its own text is back in its buffer",
            table.concat(vim.api.nvim_buf_get_lines(bq, 0, -1, false), "\n"):find("PAT-TEXT", 1, true) ~= nil
              and table.concat(vim.api.nvim_buf_get_lines(bq, 0, -1, false), "\n"):find("PLAIN-TEXT", 1, true) == nil,
            ("%s: %q"):format(label, table.concat(vim.api.nvim_buf_get_lines(bq, 0, -1, false), "|")))
        chk("and the other notebook keeps its session",
            np == nbp and np ~= nil and np.session_id == sidp and got("local", "open", m, { path = PLAIN }) == 0
              and got("local", "close", m, { session_id = sidp }) == 0, label)
        write(bq)
        local cells = saved(PAT)
        chk(":w afterwards keeps its cell in its file",
            #cells == 1 and src(cells[1]):find("PAT-TEXT", 1, true) ~= nil,
            ("%s: %d cells, %s"):format(label, #cells, cells[1] and src(cells[1]) or "none"))
        -- closed with :bdelete, the buffer is unlisted but keeps its name: the
        -- notebook must open again in that buffer, not in the loaded one of
        -- the other notebook that the name matches as a pattern
        if nq then
          kernel_ready(bq, 20000)
          local sid2, m2 = NB.get(bq).session_id, mark()
          vim.cmd("bdelete " .. bq)
          local back = J.open(PAT)
          wait(15000, function() local x = NB.get(bq); return x ~= nil and x.session_id ~= sid2 end)
          local nk, npl = NB.get(bq), NB.get(bp)
          chk("closed with :bdelete, it opens again in its own buffer",
              back == bq and nk ~= nil and nk.path == PAT and nk.session_id ~= sid2
                and vim.bo[bq].buflisted and vim.api.nvim_buf_is_loaded(bq)
                and got("local", "open", m2, { path = PAT }) == 1 and got("local", "close", m2, { session_id = sid2 }) == 1,
              ("%s: got %s, wanted %s, %s"):format(label, tostring(back), tostring(bq), nk and nk.path or "no notebook"))
          chk("and the other notebook is left as it was",
              npl == np and np ~= nil and np.session_id == sidp and got("local", "open", m2, { path = PLAIN }) == 0
                and got("local", "close", m2, { session_id = sidp }) == 0, label)
        end
      end
      wipe({ bq, bp })
    end
  end
end)

section(":bdelete hands a notebook to another backend", function()
  local b = J.open(B)
  local nb0 = b and NB.get(b)
  chk("B opens locally", nb0 ~= nil and nb0.alias == nil, nb0 and tostring(nb0.alias))
  if not (nb0 and nb0.alias == nil) then return end
  kernel_ready(b, 20000)
  local sid0, m = nb0.session_id, mark()
  vim.cmd("bdelete " .. b)
  local b2 = J.open(B, { alias = "stub" })
  local nb = b2 and NB.get(b2)
  chk("closed with :bdelete, a local notebook reopens from a remote",
      nb ~= nil and nb.alias == "stub" and got("remote", "open", m, { path = B }) == 1 and got("local", "open", m) == 0,
      nb and tostring(nb.alias))
  chk("in the same buffer, loaded and listed",
      b2 == b and vim.api.nvim_buf_is_loaded(b) and vim.bo[b].buflisted, tostring(b2) .. " vs " .. tostring(b))
  chk("its local session closed on the local backend",
      got("local", "close", m, { session_id = sid0 }) == 1 and got("remote", "close", m, { session_id = sid0 }) == 0)
  if not (nb and nb.alias == "stub") then return end
  kernel_ready(b, 20000)
  local old, m2 = nb.session_id, mark()
  focus(b)
  vim.cmd("edit!")
  wait(15000, function() local n = NB.get(b); return n ~= nil and n.session_id ~= old end)
  local nb2 = NB.get(b)
  chk(":e! keeps it on the remote",
      nb2 ~= nil and nb2.session_id ~= old and nb2.alias == "stub" and got("remote", "open", m2, { path = B }) == 1
        and got("local", "open", m2) == 0, nb2 and tostring(nb2.alias))
  if not nb2 then return end
  kernel_ready(b, 20000)
  local sid2, m3 = nb2.session_id, mark()
  vim.cmd("bdelete " .. b)
  local b3 = J.open(B)
  local nb3 = b3 and NB.get(b3)
  chk("closed with :bdelete again, it reopens locally",
      nb3 ~= nil and nb3.alias == nil and got("local", "open", m3, { path = B }) == 1 and got("remote", "open", m3) == 0,
      nb3 and tostring(nb3.alias))
  chk("its remote session closed on the remote",
      got("remote", "close", m3, { session_id = sid2 }) == 1 and got("local", "close", m3, { session_id = sid2 }) == 0)
  if b3 then
    kernel_ready(b3, 20000)
    vim.cmd("bwipeout! " .. b3)
  end
end)

section("a remote notebook read again after :bdelete and a :cd keeps its own path", function()
  -- a directory with no symlink in its path, so a :cd into it is the buffer
  -- name's own directory and Neovim shortens that name to a relative one
  local PROJ = vim.fn.resolve(tmp) .. "/proj"
  vim.fn.mkdir(PROJ .. "/sub", "p")
  local E = PROJ .. "/sub/E.ipynb"
  write_nb(E, PNG_R)
  local b = J.open(E, { alias = "stub" })
  local nb0 = b and NB.get(b)
  chk("a remote notebook opens under a directory this machine has too", nb0 ~= nil and nb0.alias == "stub",
      nb0 and tostring(nb0.alias))
  if not nb0 then return end
  kernel_ready(b, 20000)
  -- modules still to load are found while the current directory is PROJ
  local cwd = vim.fn.getcwd()
  package.path = cwd .. "/lua/?.lua;" .. cwd .. "/lua/?/init.lua;" .. package.path
  local old, m = nb0.session_id, mark()
  vim.cmd("bdelete " .. b)
  vim.cmd("cd " .. vim.fn.fnameescape(PROJ))
  local short = vim.fn.bufname(b)
  local okr, errr = pcall(vim.api.nvim_set_current_buf, b)
  wait(15000, function() local n = NB.get(b); return n ~= nil and n.session_id ~= old end)
  vim.cmd("cd " .. vim.fn.fnameescape(cwd))
  chk("after :bdelete and the :cd its buffer name is relative", short == "sub/E.ipynb", short)
  local nb = NB.get(b)
  chk("read again, it reopens on its remote by its own path",
      okr and nb ~= nil and nb.session_id ~= old and nb.alias == "stub" and got("remote", "open", m, { path = E }) == 1
        and got("remote", "open", m, { path = "/~/sub/E.ipynb" }) == 0
        and got("remote", "open", m, { path = RHOME .. "/sub/E.ipynb" }) == 0 and got("local", "open", m) == 0,
      okr and ("opened %s"):format(nb and tostring(nb.path)) or tostring(errr))
  -- whatever happened, no notebook of this section stays for the ones after
  -- it: a wrong reopen leaves a second one (at /~/sub/E.ipynb), and the old
  -- record in a buffer whose autocommands the reread already dropped
  local left = {}
  for bb, n in pairs(NB.all()) do
    if n.path:sub(-#"/sub/E.ipynb") == "/sub/E.ipynb" then left[#left + 1] = bb end
  end
  for _, bb in ipairs(left) do
    if vim.api.nvim_buf_is_valid(bb) then
      kernel_ready(bb, 20000)
      pcall(vim.cmd, "bwipeout! " .. bb)
    end
    if NB.get(bb) then NB.remove(bb) end
  end
end)

section("a notebook whose buffer was renamed is read again as its new name", function()
  -- :file and :saveas give the buffer a new name; Neovim keeps the old one as
  -- an unlisted alternate buffer. A reread by the old path would build the
  -- notebook in that other buffer and leave this one blank, still holding the
  -- old notebook and its session.
  local D = vim.fn.resolve(tmp) .. "/ren"
  vim.fn.mkdir(D, "p")
  for _, how in ipairs({ "file", "saveas" }) do
    local A, Bn = D .. "/" .. how .. "A.ipynb", D .. "/" .. how .. "B.ipynb"
    write_text(A, "A-TEXT")
    local b = J.open(A)
    local nb0 = b and NB.get(b)
    chk("a local notebook opens before it is renamed", nb0 ~= nil and nb0.alias == nil and nb0.path == A,
        how .. ": " .. tostring(b))
    if nb0 then
      kernel_ready(b, 20000)
      local old, m = nb0.session_id, mark()
      focus(b)
      local okn, errn = pcall(vim.cmd, (how == "saveas" and "saveas " or "file ") .. vim.fn.fnameescape(Bn))
      chk("the buffer takes its new name", okn and vim.api.nvim_buf_get_name(b) == Bn,
          how .. ": " .. (okn and vim.api.nvim_buf_get_name(b) or tostring(errn)))
      focus(b)
      vim.cmd("edit!")
      -- any session but the old one, in whichever buffer it was built
      wait(15000, function()
        for _, nn in pairs(NB.all()) do
          if (nn.path == A or nn.path == Bn) and nn.session_id ~= old then return true end
        end
        return false
      end)
      local nb = NB.get(b)
      chk("read again, it is read as its new name, in the same buffer",
          nb ~= nil and nb.path == Bn and nb.session_id ~= old and vim.api.nvim_get_current_buf() == b
            and got("local", "open", m, { path = Bn }) == 1 and got("local", "open", m, { path = A }) == 0,
          ("%s: %s, current buffer %d, wanted %d"):format(how, nb and nb.path or "no notebook",
            vim.api.nvim_get_current_buf(), b))
      chk("its old session is closed on its backend",
          got("local", "close", m, { session_id = old }) == 1, how .. ": " .. got("local", "close", m, { session_id = old }))
      local records = 0
      for _, nn in pairs(NB.all()) do
        if nn.path == A or nn.path == Bn then records = records + 1 end
      end
      chk("and no other buffer holds a notebook for it", records == 1, how .. ": " .. records .. " notebooks")
      if nb then
        kernel_ready(b, 20000)
        local okw, errw = pcall(vim.cmd, "write")
        chk(":w in that buffer saves the notebook as its new name", okw and vim.uv.fs_stat(Bn) ~= nil,
            how .. ": " .. (okw and "no file" or tostring(errw):sub(1, 120)))
        local cells = saved(A)
        chk("and the old file keeps its cell", #cells == 1 and src(cells[1]):find("A-TEXT", 1, true) ~= nil,
            how .. ": " .. #cells .. " cells")
      end
    end
    -- the notebooks of this round, then the buffer that kept the old name
    local left = { b }
    for bb, nn in pairs(NB.all()) do
      if nn.path == A or nn.path == Bn then left[#left + 1] = bb end
    end
    if vim.fn.bufexists(A) == 1 then left[#left + 1] = vim.fn.bufadd(A) end
    wipe(left)
  end
end)

section("a remote notebook renamed to a relative name is read again as that name, on its remote", function()
  -- After a :cd into the notebook's directory, :file sub/B.ipynb (or :saveas)
  -- names the buffer relatively, and <afile> is that relative name. A remote
  -- takes a relative path as one under its home (/~/sub/B.ipynb): a reread by
  -- it would build the notebook in a new buffer of that name and leave this
  -- one blank, still holding the old notebook and its session.
  local D = vim.fn.resolve(tmp) .. "/rren"
  vim.fn.mkdir(D .. "/sub", "p")
  -- modules still to load are found while the current directory is D
  local cwd = vim.fn.getcwd()
  package.path = cwd .. "/lua/?.lua;" .. cwd .. "/lua/?/init.lua;" .. package.path
  for _, how in ipairs({ "file", "saveas" }) do
    local A, rel = D .. "/" .. how .. "A.ipynb", "sub/" .. how .. "B.ipynb"
    local Bn = D .. "/" .. rel
    -- this round's notebooks, wherever they were built (a wrong reread names
    -- one /~/<rel>)
    local function ours(path) return path == A or path:sub(-#rel - 1) == "/" .. rel end
    write_text(A, "A-TEXT")
    local b = J.open(A, { alias = "stub" })
    local nb0 = b and NB.get(b)
    chk("a remote notebook opens before it is renamed", nb0 ~= nil and nb0.alias == "stub" and nb0.path == A,
        how .. ": " .. tostring(b))
    if nb0 then
      kernel_ready(b, 20000)
      local old, m = nb0.session_id, mark()
      vim.cmd("cd " .. vim.fn.fnameescape(D))
      focus(b)
      local okn, errn = pcall(vim.cmd, (how == "saveas" and "saveas " or "file ") .. vim.fn.fnameescape(rel))
      local short = vim.fn.bufname(b)
      chk("the remote notebook's buffer takes its new name, relative to the current directory",
          okn and short == rel and vim.api.nvim_buf_get_name(b) == Bn,
          how .. ": " .. (okn and (short .. ", " .. vim.api.nvim_buf_get_name(b)) or tostring(errn)))
      focus(b)
      local oke, erre = pcall(vim.cmd, "edit!")
      -- any session but the old one, in whichever buffer it was built
      wait(15000, function()
        for _, nn in pairs(NB.all()) do
          if ours(nn.path) and nn.session_id ~= old then return true end
        end
        return false
      end)
      vim.cmd("cd " .. vim.fn.fnameescape(cwd))
      local nb = NB.get(b)
      chk("read again, a renamed remote notebook is read as its new name, in the same buffer, on its remote",
          oke and nb ~= nil and nb.path == Bn and nb.alias == "stub" and nb.session_id ~= old
            and vim.api.nvim_get_current_buf() == b and got("remote", "open", m, { path = Bn }) == 1
            and got("remote", "open", m, { path = A }) == 0 and got("local", "open", m) == 0,
          ("%s: %s on %s, current buffer %d, wanted %d%s"):format(how, nb and nb.path or "no notebook",
            nb and tostring(nb.alias) or "-", vim.api.nvim_get_current_buf(), b,
            oke and "" or (", :e! " .. tostring(erre):sub(1, 80))))
      chk("the renamed remote notebook's old session is closed on its remote",
          got("remote", "close", m, { session_id = old }) == 1 and got("local", "close", m, { session_id = old }) == 0,
          how .. ": " .. got("remote", "close", m, { session_id = old }) .. " closes")
      local records = 0
      for _, nn in pairs(NB.all()) do
        if ours(nn.path) then records = records + 1 end
      end
      chk("and no other buffer holds a notebook for the renamed remote notebook", records == 1,
          how .. ": " .. records .. " notebooks")
      local home = {}
      for i = m + 1, #calls do
        local c = calls[i]
        local cp = tostring(c.params.path)
        if c.method == "open" and (cp:sub(1, 3) == "/~/" or cp == RHOME .. "/" .. rel) then home[#home + 1] = cp end
      end
      chk("and its remote is never asked to open a path under its home", #home == 0,
          how .. ": " .. table.concat(home, ", "))
      if nb then
        kernel_ready(b, 20000)
        focus(b)
        local okw, errw = pcall(vim.cmd, "write")
        chk(":w in that buffer saves the renamed remote notebook as its new name", okw and vim.uv.fs_stat(Bn) ~= nil,
            how .. ": " .. (okw and "no file" or tostring(errw):sub(1, 120)))
        local cells = saved(A)
        chk("and the renamed remote notebook's old file keeps its cell",
            #cells == 1 and src(cells[1]):find("A-TEXT", 1, true) ~= nil, how .. ": " .. #cells .. " cells")
      end
    end
    -- the notebooks of this round, then the buffer that kept the old name
    local left = { b }
    for bb, nn in pairs(NB.all()) do
      if ours(nn.path) then left[#left + 1] = bb end
    end
    if vim.fn.bufexists(A) == 1 then left[#left + 1] = vim.fn.bufadd(A) end
    if vim.fn.getcwd() ~= cwd then vim.cmd("cd " .. vim.fn.fnameescape(cwd)) end
    wipe(left)
  end
end)

section("a notebook read by a relative name opens that file when a hook changes the directory first", function()
  -- The open runs on the next tick, after BufEnter. A BufEnter hook that
  -- changes the directory (as project-root plugins do) made a relative
  -- <afile> name one under the new directory: the notebook was built there,
  -- in a new buffer, and the buffer being read stayed blank (or kept its old
  -- notebook and session after :file).
  local D, O = vim.fn.resolve(tmp) .. "/hook", vim.fn.resolve(tmp) .. "/hookother"
  vim.fn.mkdir(D .. "/sub", "p")
  vim.fn.mkdir(O, "p")
  -- modules still to load are found while the current directory is D or O
  local cwd = vim.fn.getcwd()
  package.path = cwd .. "/lua/?.lua;" .. cwd .. "/lua/?/init.lua;" .. package.path
  local armed, moved = false, 0
  local hook = vim.api.nvim_create_augroup("JnvSpecRootHook", { clear = true })
  vim.api.nvim_create_autocmd("BufEnter", { group = hook, pattern = "*.ipynb", callback = function()
    if armed then
      armed = false
      moved = moved + 1
      vim.cmd("cd " .. vim.fn.fnameescape(O))
    end
  end })
  -- read `rel` from D with the hook armed; the directory it left the editor in
  local function read_moved(cmd)
    vim.cmd("cd " .. vim.fn.fnameescape(D))
    moved, armed = 0, true
    local ok, err = pcall(vim.cmd, cmd)
    armed = false
    return ok, err, vim.fn.getcwd()
  end
  -- requests to open, and notebooks for, a path under O
  local function under_o(m, rel)
    local n = got("local", "open", m, { path = O .. "/" .. rel })
    for _, nn in pairs(NB.all()) do
      if nn.path == O .. "/" .. rel then n = n + 1 end
    end
    return n
  end
  local function back() if vim.fn.getcwd() ~= cwd then vim.cmd("cd " .. vim.fn.fnameescape(cwd)) end end

  -- the first open, by :edit of a relative name
  local E = D .. "/sub/hookE.ipynb"
  write_text(E, "E-TEXT")
  local m = mark()
  local ok, err, after = read_moved("edit sub/hookE.ipynb")
  wait(15000, function() return nb_ending("/sub/hookE.ipynb") ~= nil end)
  back()
  chk("the hook changed the directory before the open ran", ok and moved == 1 and after == O,
      tostring(ok and after or err))
  local b = vim.fn.bufexists(E) == 1 and vim.fn.bufadd(E) or -1
  local nb = b > 0 and NB.get(b) or nil
  chk("a notebook opened by a relative name is that file, in the buffer being read",
      nb ~= nil and nb.path == E and nb.alias == nil and src(nb.cells[1] or {}):find("E-TEXT", 1, true) ~= nil
        and got("local", "open", m, { path = E }) == 1,
      nb and nb.path or ("no notebook in buffer " .. b))
  chk("and nothing is opened under the directory the hook moved to", under_o(m, "sub/hookE.ipynb") == 0,
      under_o(m, "sub/hookE.ipynb"))
  local left = { b }
  for bb, nn in pairs(NB.all()) do
    if nn.path:sub(-#"/sub/hookE.ipynb") == "/sub/hookE.ipynb" then left[#left + 1] = bb end
  end
  wipe(left)

  -- a notebook renamed with :file to a relative name, then :e!
  local A, Bn = D .. "/hookA.ipynb", D .. "/sub/hookR.ipynb"
  write_text(A, "A-TEXT")
  local ba = J.open(A)
  local nb0 = ba and NB.get(ba)
  chk("a local notebook opens before it is renamed and read again", nb0 ~= nil and nb0.path == A, tostring(ba))
  if nb0 then
    kernel_ready(ba, 20000)
    local old = nb0.session_id
    vim.cmd("cd " .. vim.fn.fnameescape(D))
    focus(ba)
    vim.cmd("file sub/hookR.ipynb")
    m = mark()
    ok, err, after = read_moved("edit!")
    wait(15000, function()
      for _, nn in pairs(NB.all()) do
        if nn.path:sub(-#"/sub/hookR.ipynb") == "/sub/hookR.ipynb" and nn.session_id ~= old then return true end
      end
      return false
    end)
    back()
    chk("the hook changed the directory before the reread ran", ok and moved == 1 and after == O,
        tostring(ok and after or err))
    local nr = NB.get(ba)
    chk("a renamed notebook read again is read as its new name, in the same buffer",
        nr ~= nil and nr.path == Bn and nr.session_id ~= old and got("local", "open", m, { path = Bn }) == 1,
        nr and nr.path or "no notebook")
    chk("and its old session is closed, nothing opened under the directory the hook moved to",
        got("local", "close", m, { session_id = old }) == 1 and under_o(m, "sub/hookR.ipynb") == 0,
        got("local", "close", m, { session_id = old }) .. " closes, " .. under_o(m, "sub/hookR.ipynb") .. " under it")
  end
  left = { ba }
  for bb, nn in pairs(NB.all()) do
    if nn.path == A or nn.path:sub(-#"/sub/hookR.ipynb") == "/sub/hookR.ipynb" then left[#left + 1] = bb end
  end
  if vim.fn.bufexists(A) == 1 then left[#left + 1] = vim.fn.bufadd(A) end
  wipe(left)

  -- a new notebook through BufNewFile, which fires instead of BufReadCmd only
  -- while BufReadCmd is in 'eventignore'
  local N = D .. "/sub/hookN.ipynb"
  local ei = vim.o.eventignore
  vim.o.eventignore = "BufReadCmd"
  m = mark()
  ok, err, after = read_moved("edit sub/hookN.ipynb")
  vim.o.eventignore = ei
  wait(15000, function() return nb_ending("/sub/hookN.ipynb") ~= nil end)
  back()
  local bn = vim.fn.bufexists(N) == 1 and vim.fn.bufadd(N) or -1
  local nn0 = bn > 0 and NB.get(bn) or nil
  chk("a new notebook named relatively is made at that name, in the buffer being edited",
      ok and moved == 1 and after == O and nn0 ~= nil and nn0.path == N and got("local", "open", m, { path = N }) == 1
        and under_o(m, "sub/hookN.ipynb") == 0,
      ("%s, %s, %d under the moved directory"):format(tostring(ok and after or err), nn0 and nn0.path or "no notebook",
        under_o(m, "sub/hookN.ipynb")))
  if nn0 then
    focus(bn)
    local okw, errw = pcall(vim.cmd, "write")
    chk("and :w writes it there, nothing under the directory the hook moved to",
        okw and vim.uv.fs_stat(N) ~= nil and vim.uv.fs_stat(O .. "/sub/hookN.ipynb") == nil,
        okw and "no file" or tostring(errw):sub(1, 120))
  end
  left = { bn }
  for bb, nx in pairs(NB.all()) do
    if nx.path:sub(-#"/sub/hookN.ipynb") == "/sub/hookN.ipynb" then left[#left + 1] = bb end
  end
  wipe(left)
  back()
  vim.api.nvim_del_augroup_by_id(hook)
end)

section("a remote file's name is a name, never a pattern or command syntax", function()
  -- :JupynvimEdit and the explorer ran :edit with the name unescaped, so a
  -- # or % in it was replaced by the alternate or current file's name (or
  -- the open failed, E194); the explorer and the picker took the buffer to
  -- show by bufnr(name), which reads [ ] * ? { } as wildcards and showed
  -- another file's buffer (run[1].txt opened, run1.txt shown).
  local D = vim.fn.resolve(tmp) .. "/names"
  vim.fn.mkdir(D, "p")
  local function put(name, text)
    local f = assert(io.open(D .. "/" .. name, "w"))
    f:write(text .. "\n")
    f:close()
  end
  for name, text in pairs({ ["notes #2 (50%).txt"] = "EDIT-HASH", ["tree #2 (50%).txt"] = "TREE-HASH",
                            ["tree1.txt"] = "TREE-ONE", ["tree[1].txt"] = "TREE-BRACKET",
                            ["pick1.txt"] = "PICK-ONE", ["pick[1].txt"] = "PICK-BRACKET" }) do
    put(name, text)
  end
  local function uri(name) return "jupynvim://stub" .. D .. "/" .. name end
  local function shows(win, name, text)
    if not (win and vim.api.nvim_win_is_valid(win)) then return false, "no window" end
    local wb = vim.api.nvim_win_get_buf(win)
    local first = vim.api.nvim_buf_get_lines(wb, 0, 1, false)[1]
    return vim.api.nvim_buf_get_name(wb) == uri(name) and first == text,
      vim.api.nvim_buf_get_name(wb) .. ": " .. tostring(first)
  end
  local made = {}

  -- :JupynvimEdit
  local m = mark()
  local oke, erre = pcall(vim.cmd, "JupynvimEdit stub:" .. D .. "/notes #2 (50%).txt")
  local cur = vim.api.nvim_get_current_win()
  local okshow, what = shows(cur, "notes #2 (50%).txt", "EDIT-HASH")
  chk("a remote file whose name has # and % opens with :JupynvimEdit, from its remote",
      oke and okshow and got("remote", "fs_read", m, { path = D .. "/notes #2 (50%).txt" }) == 1
        and got("local", "fs_read", m) == 0,
      oke and what or tostring(erre):sub(1, 120))
  made[#made + 1] = uri("notes #2 (50%).txt")

  -- A name relative to the remote's home (the scp-style alias:proj/train.py)
  -- is read where :JupynvimOpenRemote reads it, under the remote's home. It
  -- was put under "/", an empty buffer with no message, and :w then wrote
  -- there.
  local REL, TILDE = "rel-" .. TAG .. ".txt", "tilde-" .. TAG .. ".txt"
  for name, text in pairs({ [REL] = "HOME-REL", [TILDE] = "HOME-TILDE" }) do
    local f = assert(io.open(RHOME .. "/" .. name, "w"))
    f:write(text .. "\n")
    f:close()
  end
  for _, c in ipairs({
    { REL, "HOME-REL", "a name relative to the remote's home" },
    { "~/" .. TILDE, "HOME-TILDE", "a ~/ name" },
  }) do
    local want = RHOME .. "/" .. c[1]:gsub("^~/", "")
    m = mark()
    local okr, errr = pcall(vim.cmd, "JupynvimEdit stub:" .. c[1])
    local rb = vim.api.nvim_get_current_buf()
    local rfirst = vim.api.nvim_buf_get_lines(rb, 0, 1, false)[1]
    chk((":JupynvimEdit of %s opens that file from the remote's home"):format(c[3]),
        okr and rfirst == c[2] and vim.b[rb].jupynvim_remote_path == want
          and got("remote", "fs_read", m, { path = want }) == 1 and got("local", "fs_read", m) == 0,
        okr and ("first %q, path %s, remote fs_read of %s: %d"):format(tostring(rfirst),
          tostring(vim.b[rb].jupynvim_remote_path), want, got("remote", "fs_read", m, { path = want }))
          or tostring(errr):sub(1, 120))
    made[#made + 1] = "jupynvim://stub" .. want
  end

  -- the explorer (the tree one; the snacks one opens through the picker)
  local RE = require("jupynvim.remote.explorer")
  local exbuf = RE.open("stub", D)
  local function line_of(name)
    for i, l in ipairs(vim.api.nvim_buf_get_lines(exbuf, 0, -1, false)) do
      if l:sub(-#name) == name then return i end
    end
  end
  wait(15000, function() return line_of("tree[1].txt") ~= nil end)
  -- <CR> on a name, the way a user opens it
  local function cr_on(name)
    local exwin = RE.visible_win("stub")
    local i = line_of(name)
    if not (exwin and i) then return false, "no explorer line for " .. name end
    vim.api.nvim_set_current_win(exwin)
    vim.api.nvim_win_set_cursor(exwin, { i, 0 })
    local map = vim.fn.maparg("<CR>", "n", false, true)
    local okc, errc = pcall(map.callback)
    return okc, errc
  end
  local target = RE._main_editor_win({ win = RE.visible_win("stub") })
  m = mark()
  local okt, errt = cr_on("tree #2 (50%).txt")
  wait(15000, function() return (shows(target, "tree #2 (50%).txt", "TREE-HASH")) end)
  okshow, what = shows(target, "tree #2 (50%).txt", "TREE-HASH")
  chk("a remote file whose name has # and % opens from the explorer, from its remote, in the editor window",
      okt and okshow and got("remote", "fs_read", m, { path = D .. "/tree #2 (50%).txt" }) == 1,
      okt and what or tostring(errt):sub(1, 120))
  cr_on("tree1.txt")
  wait(15000, function() return (shows(target, "tree1.txt", "TREE-ONE")) end)
  local ok1 = shows(target, "tree1.txt", "TREE-ONE")
  okt, errt = cr_on("tree[1].txt")
  wait(15000, function() return (shows(target, "tree[1].txt", "TREE-BRACKET")) end)
  vim.wait(100)   -- the explorer places the buffer again on the next tick
  okshow, what = shows(target, "tree[1].txt", "TREE-BRACKET")
  chk("a remote file named with [1] opens from the explorer as itself, not as another file's buffer",
      ok1 and okt and okshow, (ok1 and "" or "tree1.txt never shown; ") .. (okt and what or tostring(errt):sub(1, 120)))
  for _, n in ipairs({ "tree #2 (50%).txt", "tree1.txt", "tree[1].txt" }) do made[#made + 1] = uri(n) end
  RE.reset("stub")

  -- the picker (also what the snacks explorer opens a file through)
  local RP = require("jupynvim.remote.pick")
  RP.open_in_editor(uri("pick1.txt"))
  wait(15000, function() return (shows(vim.api.nvim_get_current_win(), "pick1.txt", "PICK-ONE")) end)
  ok1 = shows(vim.api.nvim_get_current_win(), "pick1.txt", "PICK-ONE")
  local okp, errp = pcall(RP.open_in_editor, uri("pick[1].txt"))
  okshow, what = shows(vim.api.nvim_get_current_win(), "pick[1].txt", "PICK-BRACKET")
  chk("a remote file named with [1] opens from the picker as itself, not as another file's buffer",
      ok1 and okp and okshow, (ok1 and "" or "pick1.txt never shown; ") .. (okp and what or tostring(errp):sub(1, 120)))
  for _, n in ipairs({ "pick1.txt", "pick[1].txt" }) do made[#made + 1] = uri(n) end

  -- The backend's error for a read that failed names the file, so a name
  -- that says "is a directory" or "no such file" was taken for that cause
  -- whatever really failed: the explorer opened at a file, and an empty new
  -- buffer (that :w would then create) hid the error. Under a plain file
  -- nothing can be read (not a directory), whatever the name says.
  put("plain file.txt", "PLAIN")
  local function failed_read(name)
    local before = #notes
    pcall(vim.cmd, "JupynvimEdit stub:" .. D .. "/plain file.txt/" .. name)
    local b = vim.api.nvim_get_current_buf()
    local bname, rpath = vim.api.nvim_buf_get_name(b), vim.b[b].jupynvim_remote_path
    wait(1500, function() return RE.visible_win("stub") ~= nil end)
    local errs = {}
    for i = before + 1, #notes do
      if notes[i]:find("fs_read failed", 1, true) then errs[#errs + 1] = notes[i] end
    end
    made[#made + 1] = bname
    return #errs, RE.visible_win("stub") ~= nil, rpath
  end
  RE.reset("stub")
  local nerr, explorer, rpath = failed_read("this is a directory.txt")
  chk("a remote file whose name says it is a directory, when it cannot be read, shows the error and no explorer",
      nerr == 1 and not explorer, ("%d errors, explorer %s"):format(nerr, tostring(explorer)))
  RE.reset("stub")
  nerr, explorer, rpath = failed_read("no such file.txt")
  chk("a remote file whose name says no such file, when it cannot be read, shows the error and is not a new file",
      nerr == 1 and rpath == nil, ("%d errors, remote path %s"):format(nerr, tostring(rpath)))
  RE.reset("stub")
  -- a file that does not exist yet still opens as an empty new buffer
  local before = #notes
  local okn = pcall(vim.cmd, "JupynvimEdit stub:" .. D .. "/brand new.txt")
  local nb_ = vim.api.nvim_get_current_buf()
  local nerrs = 0
  for i = before + 1, #notes do
    if notes[i]:find("fs_read failed", 1, true) then nerrs = nerrs + 1 end
  end
  chk("a remote file that does not exist opens as an empty new buffer, with no error",
      okn and nerrs == 0 and vim.b[nb_].jupynvim_remote_path == D .. "/brand new.txt"
        and vim.api.nvim_buf_get_lines(nb_, 0, -1, false)[1] == "",
      ("%d errors, remote path %s"):format(nerrs, tostring(vim.b[nb_].jupynvim_remote_path)))
  made[#made + 1] = uri("brand new.txt")

  pcall(vim.cmd, "silent! only!")
  for _, name in ipairs(made) do
    if vim.fn.bufexists(name) == 1 then pcall(vim.cmd, "bwipeout! " .. vim.fn.bufadd(name)) end
  end
end)

section(":JupynvimOpenRemote of a remote directory named without its slash browses it", function()
  -- The remote's fs_read of a directory failed ("Is a directory"): an empty
  -- jupynvim:// buffer and an error, where the name with a trailing slash
  -- opened the explorer there.
  local D = vim.fn.resolve(tmp) .. "/rdir"
  vim.fn.mkdir(D, "p")
  local f = assert(io.open(D .. "/inside.txt", "w"))
  f:write("INSIDE\n")
  f:close()
  local RE = require("jupynvim.remote.explorer")
  RE.reset("stub")
  local n0 = #notes
  local ok, err = pcall(vim.cmd, "JupynvimOpenRemote stub:" .. D)
  wait(15000, function() return RE.visible_win("stub") ~= nil and RE.current_root("stub") == D end)
  local errs = {}
  for i = n0 + 1, #notes do
    if notes[i]:find("fs_read", 1, true) then errs[#errs + 1] = notes[i] end
  end
  chk(":JupynvimOpenRemote of a remote directory without a trailing slash opens the explorer there",
      ok and RE.visible_win("stub") ~= nil and RE.current_root("stub") == D and #errs == 0
        and vim.fn.bufexists("jupynvim://stub" .. D) == 0,
      ok and ("root %s, %d errors %s, uri buffer %d"):format(tostring(RE.current_root("stub")), #errs,
        table.concat(errs, " / "):sub(1, 80), vim.fn.bufexists("jupynvim://stub" .. D)) or tostring(err):sub(1, 120))
  RE.reset("stub")
  if vim.fn.bufexists("jupynvim://stub" .. D) == 1 then
    pcall(vim.cmd, "bwipeout! " .. vim.fn.bufadd("jupynvim://stub" .. D))
  end
  pcall(vim.cmd, "silent! only!")

  -- A plain ssh profile has a ControlMaster socket only after
  -- :JupynvimConnect (key login needs none), but its backend runs: the
  -- explorer was refused ("not connected; run :JupynvimConnect first") though
  -- the backend that reads the directory was up. The profile is a plain one
  -- (no transport_cmd, so the master check applies) whose backend is the
  -- running stub; no ssh master exists for it.
  local prev_alias = J._active_alias
  J.config.remote.plain = { host = "plain.invalid" }
  J.clients.plain = J.client_for("stub")
  RE.reset("plain")
  n0 = #notes
  local m = mark()
  ok, err = pcall(vim.cmd, "JupynvimOpenRemote plain:" .. D)
  wait(15000, function() return RE.visible_win("plain") ~= nil and RE.current_root("plain") == D end)
  local refused = {}
  for i = n0 + 1, #notes do
    if notes[i]:find("not connected", 1, true) then refused[#refused + 1] = notes[i] end
  end
  chk(":JupynvimOpenRemote of a directory browses it on a running backend that has no ControlMaster",
      ok and RE.visible_win("plain") ~= nil and RE.current_root("plain") == D and #refused == 0
        and got("remote", "fs_list", m) >= 1,
      ok and ("root %s, refused %s"):format(tostring(RE.current_root("plain")), table.concat(refused, " / "):sub(1, 90))
        or tostring(err):sub(1, 120))
  RE.reset("plain")
  J.clients.plain = nil
  J.config.remote.plain = nil
  J._set_active_alias(prev_alias)
  local urib = "jupynvim://plain" .. D
  if vim.fn.bufexists(urib) == 1 then pcall(vim.cmd, "bwipeout! " .. vim.fn.bufadd(urib)) end
  pcall(vim.cmd, "silent! only!")
end)

section("a remote path in another user's home (~user/name) is refused and opens nothing", function()
  -- ~name/x is how the shell and scp name another user's home. The backend
  -- resolves only its own "~", so the text was read as $HOME/~name/x: an
  -- empty buffer or one-cell notebook and no message, and :w then made a
  -- directory called ~name in the remote's home. The files below are what
  -- that reading opens.
  local USER = "~jnvuser-" .. TAG
  local SUB = RHOME .. "/" .. USER .. "/shared"
  vim.fn.mkdir(SUB, "p")
  local f = assert(io.open(SUB .. "/notes.txt", "w"))
  f:write("STRAY\n")
  f:close()
  local NBNAME = "stray-" .. TAG .. ".ipynb"
  write_nb(SUB .. "/" .. NBNAME, PNG_R)
  local LIT = "~lit-" .. TAG .. ".txt"
  f = assert(io.open(RHOME .. "/" .. LIT, "w"))
  f:write("LITERAL\n")
  f:close()

  -- reads, listings, opens and writes any backend was asked for since `from`
  local function asked(from)
    local n = 0
    for i = from + 1, #calls do
      local mth = calls[i].method
      if mth == "fs_read" or mth == "fs_list" or mth == "open" or mth == "fs_write" then n = n + 1 end
    end
    return n
  end
  local function said(from, needle)
    local out = {}
    for i = from + 1, #notes do
      if notes[i]:find(needle, 1, true) then out[#out + 1] = notes[i] end
    end
    return out
  end
  local function stray_buffers()
    local out = {}
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(b):find(USER, 1, true) then out[#out + 1] = vim.api.nvim_buf_get_name(b) end
    end
    return out
  end

  local cur0 = vim.api.nvim_get_current_buf()
  local n0, m = #notes, mark()
  local ok, err = pcall(vim.cmd, "JupynvimEdit stub:" .. USER .. "/shared/notes.txt")
  local msgs, strays = said(n0, "absolute path"), stray_buffers()
  chk(":JupynvimEdit of ~user/name is refused with the absolute path as the way out, reading nothing",
      ok and #msgs == 1 and msgs[1]:find("./", 1, true) ~= nil and asked(m) == 0 and #strays == 0
        and vim.api.nvim_get_current_buf() == cur0,
      ok and ("%d messages, %d requests, buffers %s"):format(#msgs, asked(m), table.concat(strays, " ")) or tostring(err):sub(1, 120))

  n0, m = #notes, mark()
  ok, err = pcall(vim.cmd, "JupynvimOpenRemote stub:" .. USER .. "/shared/" .. NBNAME)
  vim.wait(200)
  msgs, strays = said(n0, "absolute path"), stray_buffers()
  chk(":JupynvimOpenRemote of a ~user/name notebook is refused with the absolute path as the way out, opening nothing",
      ok and #msgs == 1 and nb_ending(NBNAME) == nil and asked(m) == 0 and #strays == 0,
      ok and ("%d messages, notebook %s, %d requests, buffers %s"):format(#msgs, tostring(nb_ending(NBNAME) ~= nil),
        asked(m), table.concat(strays, " ")) or tostring(err):sub(1, 120))

  n0, m = #notes, mark()
  local okm, ret = pcall(J.open, USER .. "/shared/" .. NBNAME, { alias = "stub" })
  vim.wait(200)
  msgs, strays = said(n0, "absolute path"), stray_buffers()
  chk("opening a ~user/name notebook with an alias is refused with the absolute path as the way out, opening nothing",
      okm and ret == nil and #msgs == 1 and nb_ending(NBNAME) == nil and asked(m) == 0 and #strays == 0,
      okm and ("returned %s, %d messages, %d requests, buffers %s"):format(tostring(ret), #msgs, asked(m),
        table.concat(strays, " ")) or tostring(ret):sub(1, 120))

  -- A refused path changes nothing: it is judged before the remote is
  -- chosen, so no backend starts and the active remote stays.
  J.config.remote.neverstub = { host = "never.invalid",
    transport_cmd = { "env", "JNV_SIDE=never", "HOME=" .. RHOME, "PYTHONUSERBASE=" .. USERBASE, CORE } }
  local prev_alias = J._active_alias
  pcall(vim.cmd, "JupynvimOpenRemote neverstub:" .. USER .. "/shared/notes.txt")
  vim.wait(200)
  chk(":JupynvimOpenRemote of a refused path starts no backend and keeps the active remote",
      (spawned.never or 0) == 0 and J.clients.neverstub == nil and J._active_alias == prev_alias,
      ("never spawned %d, client %s, active %s (was %s)"):format(spawned.never or 0,
        tostring(J.clients.neverstub), tostring(J._active_alias), tostring(prev_alias)))
  -- A one-off user@host is made a session profile only once its path is
  -- judged: a host this spec never named has no profile to begin with, so one
  -- that appears is the command's doing (and its note says so).
  local FRESH = "fresh-" .. TAG .. "@nohost.invalid"
  local FRESH_ALIAS = FRESH:gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", "")
  local pre_remote = vim.deepcopy(J.config.remote)
  n0 = #notes
  pcall(vim.cmd, "JupynvimOpenRemote " .. FRESH .. ":" .. USER .. "/shared/" .. NBNAME)
  vim.wait(200)
  chk("a refused path on a one-off host adds no session profile and starts no backend",
      J.config.remote[FRESH_ALIAS] == nil and vim.deep_equal(J.config.remote, pre_remote)
        and J.clients[FRESH_ALIAS] == nil and #said(n0, "session profile") == 0 and J._active_alias == prev_alias,
      ("profile %s, client %s, %d notes, active %s"):format(vim.inspect(J.config.remote[FRESH_ALIAS]),
        tostring(J.clients[FRESH_ALIAS]), #said(n0, "session profile"), tostring(J._active_alias)))
  J.config.remote[FRESH_ALIAS] = nil

  -- ./~name is the file of that name in the remote's home
  m = mark()
  ok, err = pcall(vim.cmd, "JupynvimEdit stub:./" .. LIT)
  local lb = vim.api.nvim_get_current_buf()
  local first = vim.api.nvim_buf_get_lines(lb, 0, 1, false)[1]
  chk(":JupynvimEdit of ./~name reads the file of that name in the remote's home",
      ok and first == "LITERAL" and vim.b[lb].jupynvim_remote_path == RHOME .. "/" .. LIT
        and got("remote", "fs_read", m, { path = RHOME .. "/" .. LIT }) == 1,
      ok and ("first %q, path %s"):format(tostring(first), tostring(vim.b[lb].jupynvim_remote_path))
        or tostring(err):sub(1, 120))

  -- clean up, including what an unrefused path leaves behind
  if J.clients.neverstub then pcall(function() J.clients.neverstub:stop() end) end
  J.clients.neverstub = nil
  J.config.remote.neverstub = nil
  J._set_active_alias(prev_alias)
  pcall(vim.cmd, "silent! only!")
  local left = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(b)
    if name:find(USER, 1, true) or name:find(LIT, 1, true) or name:find(NBNAME, 1, true) then left[#left + 1] = b end
  end
  wipe(left)
end)

section(":JupynvimInstall says how the new backend starts running", function()
  -- It said ":JupynvimReset to switch the running backend to it", but Reset
  -- reopens the notebooks on the same running backend, which keeps its old
  -- binary until it exits.
  local key = "jupynvim.backend.install"
  local saved_mod = package.loaded[key]
  package.loaded[key] = { run = function() end }   -- an install that changes nothing here
  J._ensure_client()
  local n0 = #notes
  local ok, err = pcall(vim.cmd, "JupynvimInstall")
  package.loaded[key] = saved_mod
  local said = table.concat(notes, " / ", n0 + 1)
  chk("after :JupynvimInstall the message says to restart Neovim, not :JupynvimReset",
      ok and said:find("restart Neovim", 1, true) ~= nil and said:find("JupynvimReset", 1, true) == nil,
      ok and said or tostring(err):sub(1, 120))
end)

section("a cell event counts only from the notebook's own backend", function()
  local nb = NB.get(bufL)
  local id = nb.cells[1].id
  -- through the handler each backend's client registered, as a real event
  -- arrives
  J.clients.stub.handlers.cell_event({ { session_id = nb.session_id, cell_id = id,
    event = { kind = "stream", name = "stdout", text = "FORGED\n" } } })
  chk("an event from another backend is dropped", out_text(nb, 1):find("FORGED", 1, true) == nil, out_text(nb, 1))
  J.client.handlers.cell_event({ { session_id = nb.session_id, cell_id = id,
    event = { kind = "stream", name = "stdout", text = "OWN\n" } } })
  chk("one from its own backend is taken", out_text(nb, 1):find("OWN", 1, true) ~= nil, out_text(nb, 1))
  -- the other way round: the local backend's event for the remote notebook
  local nbR = NB.get(bufR)
  J.client.handlers.cell_event({ { session_id = nbR.session_id, cell_id = nbR.cells[1].id,
    event = { kind = "stream", name = "stdout", text = "FORGED\n" } } })
  chk("an event from the local backend for a remote notebook is dropped",
      out_text(nbR, 1):find("FORGED", 1, true) == nil, out_text(nbR, 1))
  -- The last event a backend wrote before it exited: its exit callback has
  -- cleared the client's job at once, its on_exit (which takes it out of
  -- routing) is still queued, and the event is handled in between.
  for _, t in ipairs(both()) do
    local n = NB.get(t.buf)
    local cl = t.side == "local" and J.client or J.clients.stub
    local job = cl.job
    cl.job = nil
    local okh, errh = pcall(cl.handlers.cell_event, { { session_id = n.session_id, cell_id = n.cells[1].id,
      event = { kind = "stream", name = "stdout", text = "LAST\n" } } })
    cl.job = job
    chk(("a %s notebook takes the last event its backend sent before it exited"):format(t.side),
        okh and out_text(n, 1):find("LAST", 1, true) ~= nil, okh and out_text(n, 1) or tostring(errh))
  end
end)

section(":JupynvimDebug names the notebook's backend", function()
  for _, t in ipairs(both()) do
    focus(t.buf)
    local ok, res = pcall(vim.api.nvim_exec2, "JupynvimDebug", { output = true })
    local out = ok and res.output or tostring(res)
    local want = t.side == "local" and "backend: local" or "backend: stub"
    chk((":JupynvimDebug names a %s notebook's backend"):format(t.side), out:find(want, 1, true) ~= nil,
        out:match("backend:[^\n]*") or "no backend line")
  end
end)

-- This guards the per-notebook open timeout (30 s for a remote): a fixed 5 s
-- one fails it. Base failed it for another reason: its use_remote blocked on
-- two synchronous kitty_attach calls while the remote slept, so the open
-- itself was timed short.
section("a remote that is slow to start still opens", function()
  J.use_remote("slowstub")
  local t0 = vim.uv.hrtime()
  bufR3 = J.open(R3, { alias = "slowstub" })
  local secs = (vim.uv.hrtime() - t0) / 1e9
  local nb = bufR3 and NB.get(bufR3)
  chk("it opens although its backend took over five seconds", nb ~= nil and #nb.cells == 3 and secs > 5,
      ("%.1f s"):format(secs))
  chk("on its own backend", nb ~= nil and nb.alias == "slowstub", nb and tostring(nb.alias))
  J.use_local()
end)

section("a remote save waits as long as a remote open", function()
  local b = J.open(R4, { alias = "slowsave" })
  local nb = b and NB.get(b)
  chk("a notebook opens through the slow link", nb ~= nil and nb.alias == "slowsave", nb and tostring(nb.alias))
  if not nb then return end
  -- nothing else on the link while the answer is held
  kernel_ready(b, 30000)
  vim.wait(500)
  set_cell(b, 1, { "import os", "print('side=' + os.environ.get('JNV_SIDE', '?'))", "# saved-slowly" })
  -- the link holds the next answer 8 s: longer than a local save waits (5 s)
  local f = assert(io.open(TRIGGER .. ".tmp", "w"))
  f:write("8000")
  f:close()
  os.rename(TRIGGER .. ".tmp", TRIGGER)
  local n0, t0 = #notes, vim.uv.hrtime()
  write(b)
  local secs = (vim.uv.hrtime() - t0) / 1e9
  local failed_note
  for i = n0 + 1, #notes do
    if notes[i]:find("failed", 1, true) then failed_note = notes[i] end
  end
  chk("a remote save waits for an answer that takes eight seconds",
      src(saved(R4)[1]):find("# saved-slowly", 1, true) ~= nil and failed_note == nil and secs > 7,
      ("%.1f s, %s"):format(secs, failed_note or "no failure noted"))
end)

section("a ~/ open inside the wait of an open by the absolute path leaves one session", function()
  -- A backend that cannot say its home: a ~/ open is named by its open's
  -- reply. One that ran while an open of the same file by its absolute path
  -- waited on its own reply (a slow link, a second click) found no buffer of
  -- that name yet, built the notebook itself, and the outer open then took
  -- the buffer over: the inner session and its kernel stayed on the remote,
  -- never closed.
  local name = "nest-" .. TAG .. ".ipynb"
  local P = RHOME .. "/" .. name
  write_nb(P, PNG_R)
  STAT_WITHOUT_PATH = true
  local ok, err = pcall(function()
    local cl = J.client_for("slowsave")
    cl:call_sync("fs_stat", { path = "/" }, 15000)   -- the link is up before the hold
    forget_home("slowsave")
    local m = mark()
    -- the link holds the next answer 2.5 s; the ~/ open starts 0.3 s into it
    local f = assert(io.open(TRIGGER .. ".tmp", "w"))
    f:write("2500")
    f:close()
    os.rename(TRIGGER .. ".tmp", TRIGGER)
    local inner_ran = false
    vim.defer_fn(function()
      inner_ran = true
      pcall(vim.cmd, "JupynvimOpenRemote slowsave:~/" .. name)
    end, 300)
    local b = J.open(P, { alias = "slowsave" })
    vim.wait(500)
    local nb = b and NB.get(b)
    local n = 0
    for _, x in pairs(NB.all()) do if x.path == P then n = n + 1 end end
    chk("the open by the absolute path builds the one notebook", inner_ran and nb ~= nil and n == 1
        and nb.alias == "slowsave", ("inner ran %s, %d notebooks"):format(tostring(inner_ran), n))
    if not nb then return end
    kernel_ready(b, 30000)
    vim.wait(500)
    local opens, extra_closed, extra_kernels, extra = 0, 0, 0, {}
    for i = m + 1, #calls do
      local c = calls[i]
      if c.side == "remote" and c.method == "open" and tostring(c.params.path):sub(-#name) == name then
        opens = opens + 1
      end
    end
    -- the sessions the remote made for it: every close or kernel start of a
    -- session other than the notebook's
    for i = m + 1, #calls do
      local c = calls[i]
      if c.side == "remote" and c.params.session_id and c.params.session_id ~= nb.session_id then
        if c.method == "close" then extra_closed = extra_closed + 1; extra[c.params.session_id] = true end
        if c.method == "start_kernel" then extra_kernels = extra_kernels + 1 end
      end
    end
    chk("the ~/ open inside its wait closes its own session and starts no kernel for it",
        opens == 2 and extra_closed == 1 and extra_kernels == 0,
        ("%d opens, %d other sessions closed, %d kernels started for them"):format(opens, extra_closed, extra_kernels))
    wipe({ b })
  end)
  STAT_WITHOUT_PATH = false
  if not ok then error(err, 0) end
end)

section("an open from another backend inside the wait of an open of the same path is refused, and says so", function()
  -- One buffer per name, so the second notebook cannot open; it was refused
  -- without a word (the cross-backend refusal never shown): by the guard an
  -- open of a name already waiting on its reply returns from, from a backend
  -- that cannot say its home by the ~/ open's reply naming that path, and
  -- for an :edit by the notebook BufReadCmd's own guard.
  local name = "busy-" .. TAG .. ".ipynb"
  local P = RHOME .. "/" .. name
  write_nb(P, PNG_R)
  local refusal = "is already open locally. Close it with :bwipeout before opening it from stub."
  local home0 = known_home("stub")
  local ok, err = pcall(function()
    J.client_for("stub")
    for _, v in ipairs({
      { "by its absolute path", function() return J.open(P, { alias = "stub" }) end, 0 },
      { "by ~/name, from a backend that cannot say its home", function()
          STAT_WITHOUT_PATH = true
          forget_home("stub")
          local r = J.open("~/" .. name, { alias = "stub" })
          STAT_WITHOUT_PATH = false
          return r
        end, 1 },
    }) do
      local m, n0 = mark(), #notes
      local ran, inner = false, nil
      -- the remote open runs while the local open of P waits on its reply
      DURING.open = { side = "local", fn = function() ran = true; inner = v[2]() end }
      local b = J.open(P)
      DURING.open = nil
      STAT_WITHOUT_PATH = false
      local nb = b and NB.get(b)
      local n = 0
      for _, x in pairs(NB.all()) do if x.path == P then n = n + 1 end end
      chk(v[1] .. ": the local open builds the one notebook (precondition)",
          ran and inner == nil and nb ~= nil and nb.alias == nil and n == 1,
          ("inner ran %s and gave %s, %d notebooks"):format(tostring(ran), tostring(inner), n))
      local k = 0
      for i = n0 + 1, #notes do
        if notes[i]:find(P .. " " .. refusal, 1, true) and note_levels[i] == vim.log.levels.ERROR then k = k + 1 end
      end
      local closes, kernels = got("remote", "close", m), got("remote", "start_kernel", m)
      chk(v[1] .. ": the remote open says the notebook is open locally", k == 1,
          k .. " shown; " .. table.concat(vim.list_slice(notes, n0 + 1), " | "):sub(1, 200))
      chk(v[1] .. ": the remote keeps no session for it and starts no kernel",
          got("remote", "open", m) == v[3] and closes == v[3] and kernels == 0,
          ("%d opens, %d closed, %d kernels"):format(got("remote", "open", m), closes, kernels))
      if b then wipe({ b }) end
    end
    -- the other way round: this machine's :e of the path while the remote
    -- open of it waits on its reply; the remote notebook takes the buffer
    local m, n0 = mark(), #notes
    local ran = false
    DURING.open = { side = "remote", fn = function()
      ran = true
      pcall(vim.cmd, "edit " .. vim.fn.fnameescape(P))
    end }
    local b = J.open(P, { alias = "stub" })
    DURING.open = nil
    vim.wait(300)
    local nb = b and NB.get(b)
    local n = 0
    for _, x in pairs(NB.all()) do if x.path == P then n = n + 1 end end
    chk(":e of the path inside a remote open's wait: the remote notebook is the one notebook (precondition)",
        ran and nb ~= nil and nb.alias == "stub" and n == 1 and got("local", "open", m) == 0,
        ("ran %s, %d notebooks, %d local opens"):format(tostring(ran), n, got("local", "open", m)))
    local k = 0
    for i = n0 + 1, #notes do
      if notes[i]:find(P .. " is already open from stub. Close it with :bwipeout before opening it locally.", 1, true)
          and note_levels[i] == vim.log.levels.ERROR then k = k + 1 end
    end
    chk(":e of the path inside a remote open's wait says the notebook is open from the remote", k == 1,
        k .. " shown; " .. table.concat(vim.list_slice(notes, n0 + 1), " | "):sub(1, 200))
    if b then wipe({ b }) end
  end)
  DURING.open = nil
  STAT_WITHOUT_PATH = false
  if J._remote_homes then J._remote_homes.stub = home0 end
  if not ok then error(err, 0) end
end)

section(":JupynvimReset reopens every notebook on its own backend", function()
  local before = {}
  for _, nb in pairs(NB.all()) do before[nb.path] = { sid = nb.session_id, alias = nb.alias } end
  local m = mark()
  vim.cmd("JupynvimReset")
  wait(30000, function()
    for path, o in pairs(before) do
      local _, nb = nb_at(path)
      if not nb or nb.session_id == o.sid then return false end
    end
    return true
  end)
  for path, o in pairs(before) do
    local _, nb = nb_at(path)
    local side = o.alias and "remote" or "local"
    local other = side == "local" and "remote" or "local"
    -- the same name in every run, whatever TAG is
    local tail = vim.fn.fnamemodify(path, ":t"):gsub("^jnv%-routing%-%d+", "tagged")
    chk(tail .. " reopens on its own backend",
        nb ~= nil and nb.alias == o.alias and got(side, "open", m, { path = path }) == 1
          and got(other, "open", m, { path = path }) == 0,
        nb and tostring(nb.alias))
    chk(tail .. ": its old session closed there",
        got(side, "close", m, { session_id = o.sid }) == 1 and got(other, "close", m, { session_id = o.sid }) == 0)
  end
  bufL, bufR, bufR3 = vim.fn.bufnr(L), vim.fn.bufnr(R), vim.fn.bufnr(R3)
  bufR2 = nb_ending("/" .. R2NAME)
end)

section("stopping a kernel goes to the notebook's own backend", function()
  chk("both kernels are back", kernel_ready(bufL) and kernel_ready(bufR))
  for _, t in ipairs(both()) do
    local m = mark()
    J.stop_kernel(t.buf)
    chk(t.side .. " notebook: stop_kernel through the " .. t.side .. " backend",
        only(t.side, "stop_kernel", NB.get(t.buf).session_id, m))
  end
end)

section("wiping a remote notebook closes its session on the remote", function()
  local kL, cid = kid(bufL), kid(bufR2)
  local sid, m = NB.get(bufR2).session_id, mark()
  local gone = bufR2
  local had = pcall(vim.api.nvim_get_autocmds, { group = "JupynvimKernelLsp_" .. gone })
  vim.cmd("bwipeout! " .. bufR2)
  chk("closed on the remote", only("remote", "close", sid, m))
  wait(3000, function() return cid == nil or vim.lsp.get_client_by_id(cid) == nil end)
  chk("wiping a notebook stops its completion client", cid ~= nil and vim.lsp.get_client_by_id(cid) == nil,
      tostring(cid))
  chk("and removes its autocommand group",
      had and not pcall(vim.api.nvim_get_autocmds, { group = "JupynvimKernelLsp_" .. gone }),
      had and "still there" or "it never had one")
  chk("another notebook keeps its own completion client", kL ~= nil and kid(bufL) == kL,
      tostring(kL) .. " -> " .. tostring(kid(bufL)))
end)

section("a stopped completion client is never handed back", function()
  -- the slow remote's notebook: nothing after this asks it for completions
  local old = kclients(bufR3)[1]
  if old then old:stop() end
  -- attached again before the stopped client's exit is handled
  require("jupynvim.lsp.kernel").attach(bufR3, function() return NB.get(bufR3) end,
    function() return J._live_client(NB.get(bufR3)) end)
  wait(3000, function() return old == nil or vim.lsp.get_client_by_id(old.id) == nil end)
  local now = kclients(bufR3)
  chk("a stopped completion client is not reused",
      old ~= nil and #now == 1 and now[1].id ~= old.id and not now[1]:is_stopped(),
      ("%s -> %s"):format(old and old.id or "none", table.concat(vim.tbl_map(function(c) return c.id end, now), ",")))
end)

section("with its backend gone, a remote notebook spawns nothing", function()
  local stub = J.clients.stub
  local sp0, t0 = spawned.remote, vim.uv.hrtime()
  stub:stop()
  wait(10000, function() return J.clients.stub == nil end)
  io.write(("   measured: the stopped backend was gone after %.0f ms\n"):format((vim.uv.hrtime() - t0) / 1e6))
  chk("the remote backend stopped", J.clients.stub == nil,
      ("same=%s job=%s stub.job=%s remote spawns %d -> %d"):format(tostring(J.clients.stub == stub),
        tostring(J.clients.stub and J.clients.stub.job), tostring(stub.job), sp0, spawned.remote))
  local sp_l, sp_r = spawned["local"], spawned.remote
  local sid, m = NB.get(bufR).session_id, mark()
  complete(bufR)
  chk("completion in it spawns no backend", spawned["local"] == sp_l and spawned.remote == sp_r,
      ("spawns %d/%d -> %d/%d"):format(sp_l, sp_r, spawned["local"], spawned.remote))
  vim.cmd("bwipeout! " .. bufR)
  chk("wiping it spawns no backend", spawned["local"] == sp_l and spawned.remote == sp_r,
      ("spawns %d/%d -> %d/%d"):format(sp_l, sp_r, spawned["local"], spawned.remote))
  chk("and sends its session to no other backend", got("local", "close", m, { session_id = sid }) == 0)
end)

section("a remote that stops leaves this editor's images alone", function()
  local nb = NB.get(bufL)
  Image.clear_all()
  nb.image_ids = {}
  local m = mark()
  focus(bufL)
  Render.refresh_sync(nb, vim.fn.bufwinid(bufL))
  wait(5000, function() return got("local", "kitty_transmit_virtual", m) > 0 end)
  chk("a local plot is sent again through the local backend",
      got("local", "kitty_transmit_virtual", m) > 0 and kitty_calls("remote", m) == 0)
end)

section("routing costs nothing measurable", function()
  local nbL, nbR3 = NB.get(bufL), NB.get(bufR3)
  local nbs = { nbL, nbR3 }
  -- The editor's own CPU time, not the wall clock: a loaded machine can take
  -- the CPU away from this editor for longer than the whole budget (one run
  -- in over a hundred at load 140, 260 ms under swap), which is not what the
  -- lookups cost. The best of three runs; every run must find all.
  local function cpu_ms()
    local ru = vim.uv.getrusage and vim.uv.getrusage()
    if ru and ru.utime and ru.stime then
      return (ru.utime.sec + ru.stime.sec) * 1e3 + (ru.utime.usec + ru.stime.usec) / 1e3
    end
    return os.clock() * 1e3
  end
  -- In the interpreter. In about one Neovim 0.11 process in six LuaJIT
  -- cannot allocate machine code, and every trace it starts on the loop
  -- aborts ("failed to allocate mcode memory"): about 250 ms of the JIT's own
  -- failed work, against 1 ms compiled and about 20 ms interpreted. The
  -- interpreter costs the same in every process and more than compiled code,
  -- so the budget still holds for the JIT. A Lua without the jit module
  -- interprets anyway.
  local JIT = rawget(_G, "jit")
  -- With 500 more buffers open: a lookup that went through the buffer list
  -- (nvim_list_bufs, bufnr() of a name) costs in proportion to it and blows
  -- the budget; one table lookup costs the same however many there are.
  local extra = {}
  for _ = 1, 500 do extra[#extra + 1] = vim.api.nvim_create_buf(false, true) end
  local ms, found = math.huge, 200000
  local okm, errm = pcall(function()
    if JIT then JIT.flush(); JIT.off() end
    for _ = 1, 3 do
      local n, t0 = 0, cpu_ms()
      for i = 1, 200000 do
        local nb = nbs[i % 2 + 1]
        local c = (i % 4 < 2) and J._nb_client(nb) or J._live_client(nb)
        if c then n = n + 1 end
      end
      ms = math.min(ms, cpu_ms() - t0)
      found = math.min(found, n)
    end
  end)
  if JIT then JIT.on() end
  for _, eb in ipairs(extra) do pcall(vim.api.nvim_buf_delete, eb, { force = true }) end
  if not okm then error(errm, 0) end
  io.write(("   measured: 200,000 lookups in %.1f ms of CPU time, interpreted, 500 more buffers open (best of 3)\n")
    :format(ms))
  chk("200,000 lookups take under 200 ms", ms < 200 and found == 200000,
      ("%.1f ms, %d found"):format(ms, found))
  local sid, m = nbL.session_id, mark()
  vim.cmd("bwipeout! " .. bufL)
  chk("wiping the local notebook closes its session on the local backend", only("local", "close", sid, m))
  chk("the shared client never became a remote backend", side_of(J.client) == "local", side_of(J.client))
end)

section("a remote notebook's plots keep showing when the local backend is gone", function()
  local nloc = 0
  for _, n in pairs(NB.all()) do if n.alias == nil then nloc = nloc + 1 end end
  chk("only remote notebooks are open", nloc == 0, nloc)
  -- the local backend, the one that wrote to this terminal, goes away
  local lc = J.client
  if lc then
    lc:stop()
    if lc.stdin and not lc.stdin:is_closing() then lc.stdin:close() end
  end
  wait(10000, function() return lc == nil or (lc.job == nil and J.client == nil) end)
  chk("the local backend is gone", lc ~= nil and lc.job == nil and J.client == nil)
  local nb = NB.get(bufR3)
  Image.clear_all()
  nb.image_ids = {}
  local sp, m, n0 = spawned["local"], mark(), Image._tty_n or 0
  focus(bufR3)
  Render.refresh_sync(nb, vim.fn.bufwinid(bufR3))
  local key = Image.output_key(Image.output_owner(bufR3, "c3"), 1)
  wait(5000, function() return (Image._tty_n or 0) > n0 and (Image._placements[key] or {}).b64 == PNG_R end)
  chk("a remote notebook's plot is still written to the terminal",
      (Image._tty_n or 0) > n0 and (Image._placements[key] or {}).b64 == PNG_R,
      ("tty writes %d -> %d"):format(n0, Image._tty_n or 0))
  chk("by this editor, starting no backend and asking none",
      spawned["local"] == sp and kitty_calls("local", m) == 0 and kitty_calls("remote", m) == 0,
      ("local spawns %d -> %d, graphics requests %d/%d"):format(sp, spawned["local"], kitty_calls("local", m),
        kitty_calls("remote", m)))
end)

section("a local notebook opened while no local backend runs", function()
  local orig, wrote, asked = Image.clear_visible_placements, false, 0
  ---@diagnostic disable-next-line: duplicate-set-field
  Image.clear_visible_placements = function(...)
    local n, m = Image._tty_n or 0, mark()
    orig(...)
    wrote = (Image._tty_n or 0) > n
    asked = got("local", "kitty_clear_visible", m) + got("remote", "kitty_clear_visible", m)
  end
  local sp = spawned["local"]
  local ok, b = pcall(J.open, L)
  Image.clear_visible_placements = orig
  chk("still clears the visible placements", ok and b ~= nil and (wrote or asked > 0),
      ("written here %s, sent to a backend %d"):format(tostring(wrote), asked))
  chk("and starts the local backend for itself",
      side_of(J.client) == "local" and J.client.job ~= nil and spawned["local"] == sp + 1)
  if ok and b then
    kernel_ready(b, 20000)
    vim.cmd("bwipeout! " .. b)
  end
end)

io.write(("%.0f s\n"):format((vim.uv.hrtime() - started) / 1e9))
if fails == 0 then
  io.write("ALL ROUTING CHECKS PASSED\n")
  vim.cmd("qa!")
else
  for i = math.max(1, #notes - 15), #notes do io.write("note: " .. notes[i]:sub(1, 200) .. "\n") end
  io.write(("ROUTING: %d FAILED: %s\n"):format(fails, table.concat(failed, "; ")))
  vim.cmd("cquit 1")
end

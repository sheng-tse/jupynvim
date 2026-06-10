-- Remote terminal via jupynvim-core's proc_spawn RPC.
--
-- Opens a PTY-backed shell on the remote (via proc_spawn) and connects it to
-- a local nvim terminal buffer using nvim_open_term. PTY output flows back
-- as `proc_event` notifications; keystrokes flow out as proc_stdin RPCs.
-- Window resizes propagate via proc_resize.
--
-- Architecturally the same as VSCode's remote terminals: the shell runs on
-- the remote machine, the rendering happens locally.

local M = {}

-- (alias, pid) → terminal state, keyed "alias:pid".
local terms = {}
-- Toggle slots per alias: slot name ("below"/"right"/"left"/"tab") → buffer.
-- Each slot is independently summon/dismiss-able. "below" is the <C-/> one.
M._slots = {}

local function key(alias, pid) return alias .. ":" .. pid end
local function slots(alias) M._slots[alias] = M._slots[alias] or {}; return M._slots[alias] end

local function win_of(buf)
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(w) == buf then return w end
  end
  return nil
end

-- Push the buffer's CURRENT window size to its PTY. `force` jiggles the size
-- (rows-1 then rows) to guarantee a SIGWINCH so the shell repaints even when
-- the size is unchanged — needed on reshow, where nvim's terminal grid is
-- stale but the PTY size didn't change, so a plain resize sends no signal.
function M.sync_size(buf, force)
  local pid = buf and vim.b[buf].jupynvim_term_pid
  local alias = buf and vim.b[buf].jupynvim_term_alias
  if not (pid and alias) then return end
  local w = win_of(buf)
  if not w then return end
  local entry = terms[key(alias, pid)]
  if not entry then return end
  local cols = vim.api.nvim_win_get_width(w)
  local rows = vim.api.nvim_win_get_height(w)
  if force and rows > 1 then
    entry.client:call("proc_resize", { pid = pid, cols = cols, rows = rows - 1 }, function()
      vim.defer_fn(function()
        entry.client:call("proc_resize", { pid = pid, cols = cols, rows = rows }, function() end)
      end, 20)
    end)
  else
    entry.client:call("proc_resize", { pid = pid, cols = cols, rows = rows }, function() end)
  end
end

-- ── resize (side-aware) ────────────────────────────────────────────────────
-- Keys name a DIRECTION (up/down/left/right); the actual grow/shrink is chosen
-- from where the window's neighbor is, so it feels natural anywhere:
--   right-side terminal: h pushes its left border left -> broader; l -> narrower
--   left-side terminal:  l -> broader; h -> narrower
--   bottom terminal:     k -> taller; j -> shorter
local function do_resize(buf, dir)
  local step = ((require("jupynvim").config or {}).terminal or {}).resize_step or 3
  if dir == "left" or dir == "right" then
    local has_left = vim.fn.winnr("h") ~= vim.fn.winnr()
    local grow = has_left and (dir == "left") or (not has_left and dir == "right")
    pcall(vim.cmd, "vertical resize " .. (grow and "+" or "-") .. step)
  else
    local has_above = vim.fn.winnr("k") ~= vim.fn.winnr()
    local grow = has_above and (dir == "up") or (not has_above and dir == "down")
    pcall(vim.cmd, "resize " .. (grow and "+" or "-") .. step)
  end
  vim.schedule(function() M.sync_size(buf) end)
end

local function resize_cfg()
  local c = (require("jupynvim").config or {}).terminal or {}
  return {
    normal = c.resize_keys_normal or { up = "K", down = "J", left = "H", right = "L" },
    insert = c.resize_keys or { up = "<C-Up>", down = "<C-Down>", left = "<C-Left>", right = "<C-Right>" },
  }
end

local function bind_resize_keys(buf)
  local cfg = resize_cfg()
  local function rk(modes, lhs, dir)
    if not lhs or lhs == "" then return end
    pcall(vim.keymap.set, modes, lhs, function() do_resize(buf, dir) end,
      { buffer = buf, silent = true, nowait = true, desc = "jupynvim: resize remote terminal (" .. dir .. ")" })
  end
  for dir, lhs in pairs(cfg.normal) do rk("n", lhs, dir) end       -- Shift+hjkl, normal mode
  for dir, lhs in pairs(cfg.insert) do rk({ "n", "t" }, lhs, dir) end  -- Ctrl+arrows, also in insert
end

-- ── splits ─────────────────────────────────────────────────────────────────
local SIZE = { below = "resize 15", left = "vertical resize 80", right = "vertical resize 80" }
local function make_split(split, buf)
  if split == "tab" then
    if buf then vim.cmd("tab sb " .. buf) else vim.cmd("tabnew") end
    return
  end
  local cmds = {
    below = buf and ("botright sb " .. buf) or "botright new",
    right = buf and ("botright vert sb " .. buf) or "botright vnew",
    left  = buf and ("topleft vert sb " .. buf) or "topleft vnew",
  }
  vim.cmd(cmds[split] or cmds.below)
  if SIZE[split] then pcall(vim.cmd, SIZE[split]) end
end

-- ── open / toggle ──────────────────────────────────────────────────────────
-- Open a remote shell. opts.split: "below"(default)/"right"/"left"/"tab".
-- opts.slot: toggle slot name (defaults to opts.split). opts.cwd: working dir.
function M.open(alias, opts)
  opts = opts or {}
  local split = opts.split or "below"
  local slot = opts.slot or split
  local J = require("jupynvim")
  local client = J.client_for(alias)

  make_split(split, nil)
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].buflisted = false
  vim.b[buf].jupynvim_term_alias = alias
  vim.b[buf].jupynvim_term_alive = true
  vim.b[buf].jupynvim_term_slot = slot
  slots(alias)[slot] = buf
  vim.api.nvim_buf_set_name(buf, string.format("term://%s/%s[connecting]", alias, slot ~= "below" and (slot .. "-") or ""))

  local win = vim.api.nvim_get_current_win()
  local cols, rows = vim.api.nvim_win_get_width(win), vim.api.nvim_win_get_height(win)

  local pid_ref = { pid = nil }
  local chan = vim.api.nvim_open_term(buf, {
    on_input = function(_e, _t, _b, data)
      if not pid_ref.pid then return end
      client:call("proc_stdin", { pid = pid_ref.pid, data_b64 = vim.base64.encode(data) }, function() end)
    end,
  })

  local cwd = opts.cwd
  if not cwd then
    local ok, root = pcall(function() return require("jupynvim.remote_explorer").current_root(alias) end)
    if ok then cwd = root end
  end
  local err, res = client:call_sync("proc_spawn", {
    cmd = opts.cmd or "bash", args = opts.args or { "-l", "-i" }, cwd = cwd,
    env = { TERM = "xterm-256color", COLORTERM = "truecolor" }, cols = cols, rows = rows,
  }, 10000)
  if err then
    vim.notify("jupynvim: proc_spawn failed: " .. tostring(err), vim.log.levels.ERROR)
    vim.api.nvim_chan_send(chan, "\r\n[spawn failed: " .. tostring(err) .. "]\r\n")
    return
  end
  pid_ref.pid = res.pid
  vim.b[buf].jupynvim_term_pid = res.pid
  local k = key(alias, res.pid)
  terms[k] = { buf = buf, chan = chan, alias = alias, pid = res.pid, client = client }
  vim.api.nvim_buf_set_name(buf, string.format("term://%s/%s%d", alias, slot ~= "below" and (slot .. "-") or "", res.pid))

  if not client._proc_event_hooked then
    client._proc_event_hooked = true
    client:on("proc_event", function(args)
      local e = args[1] or args
      local entry = terms[key(alias, e.pid)]
      if not entry then return end
      if e.kind == "stdout" then
        pcall(vim.api.nvim_chan_send, entry.chan, vim.base64.decode(e.data_b64))
      elseif e.kind == "exit" then
        pcall(vim.api.nvim_chan_send, entry.chan, "\r\n[process exited with code " .. tostring(e.code) .. "]\r\n")
        if entry.buf and vim.api.nvim_buf_is_valid(entry.buf) then
          vim.b[entry.buf].jupynvim_term_alive = false
        end
        terms[key(alias, e.pid)] = nil
      end
    end)
  end

  -- Resize → PTY. Look up the buffer's CURRENT window each time (not a captured
  -- handle, which goes stale across hide/reshow and silently dropped resizes).
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    buffer = buf, callback = function() M.sync_size(buf) end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    callback = function()
      client:call("proc_kill", { pid = res.pid }, function() end)
      terms[k] = nil
      if slots(alias)[slot] == buf then slots(alias)[slot] = nil end
    end,
  })

  bind_resize_keys(buf)
  vim.cmd("startinsert")
  return buf, res.pid
end

-- Toggle a remote terminal slot for `alias`:
--   visible      → hide its window (PTY keeps running)
--   hidden+alive → reshow at its position, force-repaint, enter insert
--   none/dead    → spawn fresh
-- opts.split selects the position/slot ("below" default = the <C-/> terminal).
function M.toggle(alias, opts)
  opts = opts or {}
  local split = opts.split or "below"
  local slot = opts.slot or split
  local buf = slots(alias)[slot]
  if buf and vim.api.nvim_buf_is_valid(buf) then
    local w = win_of(buf)
    if w then pcall(vim.api.nvim_win_close, w, false); return end
    if vim.b[buf].jupynvim_term_alive then
      make_split(split, buf)
      vim.schedule(function() M.sync_size(buf, true); vim.cmd("startinsert") end)
      return
    end
  end
  M.open(alias, { split = split, slot = slot, cwd = opts.cwd })
end

return M

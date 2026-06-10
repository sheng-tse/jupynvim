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

-- Map of (alias, pid) → terminal state. Keys are formatted "alias:pid".
local terms = {}
-- The <C-/> "primary" terminal buffer per alias (the one toggle reuses).
-- Additional terminals (e.g. a left split for claude) are NOT primary.
M._primary = {}

local function key(alias, pid) return alias .. ":" .. pid end

-- The window currently showing `buf`, or nil.
local function win_of(buf)
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(w) == buf then return w end
  end
  return nil
end

-- Push the buffer's CURRENT window size to its PTY. Used on every resize and
-- on reshow — critical because the PTY keeps its old size while the window is
-- hidden, so without this the shell's line wrapping is wrong after a toggle
-- (the garbled prompt after hide/show).
function M.sync_size(buf)
  local pid = buf and vim.b[buf].jupynvim_term_pid
  local alias = buf and vim.b[buf].jupynvim_term_alias
  if not (pid and alias) then return end
  local w = win_of(buf)
  if not w then return end
  local entry = terms[key(alias, pid)]
  if not entry then return end
  entry.client:call("proc_resize", {
    pid = pid,
    cols = vim.api.nvim_win_get_width(w),
    rows = vim.api.nvim_win_get_height(w),
  }, function() end)
end

-- Resize keys (configurable via config.terminal). Two sets, both buffer-local
-- so they only act on the terminal and never shadow your global maps:
--   * Shift+hjkl in NORMAL mode (what people reach for; J/K/H/L are useless
--     in a terminal buffer otherwise, and unbound they hit defaults like
--     J=join -> E21 and K=keywordprg -> E349).
--   * Ctrl+arrows in NORMAL and TERMINAL-INSERT mode, so you can resize
--     without leaving insert (Shift+hjkl can't work in insert: it'd type).
local function resize_cfg()
  local c = (require("jupynvim").config or {}).terminal or {}
  return {
    step = c.resize_step or 3,
    normal = c.resize_keys_normal
      or { taller = "K", shorter = "J", wider = "L", narrower = "H" },
    insert = c.resize_keys
      or { taller = "<C-Up>", shorter = "<C-Down>", wider = "<C-Right>", narrower = "<C-Left>" },
  }
end

local function bind_resize_keys(buf)
  local cfg = resize_cfg()
  local cmds = {
    taller = "resize +" .. cfg.step, shorter = "resize -" .. cfg.step,
    wider = "vertical resize +" .. cfg.step, narrower = "vertical resize -" .. cfg.step,
  }
  local function rk(modes, lhs, dir)
    if not lhs or lhs == "" then return end
    pcall(vim.keymap.set, modes, lhs, function()
      pcall(vim.cmd, cmds[dir])
      vim.schedule(function() M.sync_size(buf) end)
    end, { buffer = buf, silent = true, nowait = true, desc = "jupynvim: resize remote terminal" })
  end
  for dir, lhs in pairs(cfg.normal) do rk("n", lhs, dir) end
  for dir, lhs in pairs(cfg.insert) do rk({ "n", "t" }, lhs, dir) end
end

-- Build the split for a position. `reshow` uses `sb <buf>` to re-display an
-- existing (hidden) buffer; otherwise a fresh empty split.
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

-- Open a remote shell. opts.cmd defaults to "bash", opts.args = {"-l","-i"}.
-- opts.split: "below" (default), "right", "left", "tab".
-- opts.primary: mark as the <C-/> toggle terminal for this alias.
-- opts.cwd: working dir (defaults to the explorer's current root).
function M.open(alias, opts)
  opts = opts or {}
  local J = require("jupynvim")
  local client = J.client_for(alias)

  make_split(opts.split or "below", nil)
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].bufhidden = "hide"   -- survive window close so toggle can reshow it
  vim.bo[buf].buflisted = false    -- keep out of the bufferline
  vim.b[buf].jupynvim_term_alias = alias
  vim.b[buf].jupynvim_term_alive = true
  if opts.primary ~= false then M._primary[alias] = buf end
  vim.api.nvim_buf_set_name(buf,
    string.format("term://%s/%s[connecting]", alias, opts.label and (opts.label .. "-") or ""))

  local win = vim.api.nvim_get_current_win()
  local cols = vim.api.nvim_win_get_width(win)
  local rows = vim.api.nvim_win_get_height(win)

  local pid_ref = { pid = nil }
  local chan = vim.api.nvim_open_term(buf, {
    on_input = function(_event, _term, _bufnr, data)
      if not pid_ref.pid then return end
      client:call("proc_stdin", { pid = pid_ref.pid, data_b64 = vim.base64.encode(data) }, function() end)
    end,
  })

  -- cwd defaults to the explorer's current root.
  local cwd = opts.cwd
  if not cwd then
    local ok, root = pcall(function() return require("jupynvim.remote_explorer").current_root(alias) end)
    if ok then cwd = root end
  end
  local err, res = client:call_sync("proc_spawn", {
    cmd = opts.cmd or "bash",
    args = opts.args or { "-l", "-i" },
    cwd = cwd,
    env = { TERM = "xterm-256color", COLORTERM = "truecolor" },
    cols = cols,
    rows = rows,
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
  vim.api.nvim_buf_set_name(buf,
    string.format("term://%s/%s%d", alias, opts.label and (opts.label .. "-") or "", res.pid))

  if not client._proc_event_hooked then
    client._proc_event_hooked = true
    client:on("proc_event", function(args)
      local e = args[1] or args
      local entry = terms[key(alias, e.pid)]
      if not entry then return end
      if e.kind == "stdout" then
        pcall(vim.api.nvim_chan_send, entry.chan, vim.base64.decode(e.data_b64))
      elseif e.kind == "exit" then
        pcall(vim.api.nvim_chan_send, entry.chan,
              "\r\n[process exited with code " .. tostring(e.code) .. "]\r\n")
        if entry.buf and vim.api.nvim_buf_is_valid(entry.buf) then
          vim.b[entry.buf].jupynvim_term_alive = false
        end
        terms[key(alias, e.pid)] = nil
      end
    end)
  end

  -- Propagate window resize → PTY. Look up the buffer's CURRENT window each
  -- time (NOT a captured handle): after a hide/reshow the buffer lives in a
  -- different window, and a stale handle silently dropped every resize.
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    buffer = buf,
    callback = function() M.sync_size(buf) end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    callback = function()
      client:call("proc_kill", { pid = res.pid }, function() end)
      terms[k] = nil
      if M._primary[alias] == buf then M._primary[alias] = nil end
    end,
  })

  bind_resize_keys(buf)
  vim.cmd("startinsert")
  return buf, res.pid
end

-- Toggle the PRIMARY remote terminal for `alias` (the <C-/> one):
--   • visible      → hide its window (PTY keeps running, bufhidden=hide)
--   • hidden+alive → reshow in a split + resync size (fixes wrap) + insert
--   • none/dead    → spawn a fresh one
function M.toggle(alias, opts)
  local prim = M._primary[alias]
  if prim and vim.api.nvim_buf_is_valid(prim) then
    local w = win_of(prim)
    if w then pcall(vim.api.nvim_win_close, w, false); return end
    if vim.b[prim].jupynvim_term_alive then
      make_split((opts and opts.split) or "below", prim)
      vim.schedule(function() M.sync_size(prim); vim.cmd("startinsert") end)
      return
    end
  end
  M.open(alias, vim.tbl_extend("force", { primary = true }, opts or {}))
end

return M

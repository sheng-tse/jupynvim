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
-- Output that arrived for a pid BEFORE its terms[] entry existed (the PTY
-- starts emitting the login banner/prompt the instant it spawns, racing the
-- spawn RPC's response). Flushed into the terminal once registered; without
-- this the first prompt was missing.
local orphans = {}
-- Toggle slots per alias: slot name ("below"/"right"/"left"/"tab") → buffer.
-- Each slot is independently summon/dismiss-able. "below" is the <C-/> one.
M._slots = {}

local function key(alias, pid) return alias .. ":" .. pid end
local function slots(alias) M._slots[alias] = M._slots[alias] or {}; return M._slots[alias] end
-- Remembered window size per slot, so a resized terminal keeps its size across
-- hide/reshow (toggle) instead of snapping back to the default.
M._sizes = {}
local function skey(alias, slot) return alias .. ":" .. slot end

local function win_of(buf)
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(w) == buf then return w end
  end
  return nil
end

-- Send raw text to the buffer's remote PTY (the shell's stdin).
local function send_text(buf, text)
  local alias, pid = vim.b[buf].jupynvim_term_alias, vim.b[buf].jupynvim_term_pid
  local entry = alias and pid and terms[key(alias, pid)]
  if not entry then return false end
  entry.client:call("proc_stdin", { pid = pid, data_b64 = vim.base64.encode(text) }, function() end)
  return true
end

-- Take over pasting for jupynvim terminals. Neovim's built-in paste only
-- knows how to feed its own :terminal jobs; for our relayed PTY it garbled
-- the bracketed-paste markers (the shell got the start marker but never the
-- end, showing a stray "~" + highlighted text and hanging until Ctrl-C).
-- We send the text directly down the PTY, with newlines as CR like real
-- terminals paste.
local paste_hooked = false
local function hook_paste()
  if paste_hooked then return end
  paste_hooked = true
  local orig = vim.paste
  vim.paste = function(lines, phase)
    local buf = vim.api.nvim_get_current_buf()
    if vim.b[buf].jupynvim_term_pid then
      send_text(buf, table.concat(lines, "\r"))
      return true
    end
    return orig(lines, phase)
  end
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

-- ── resize ──────────────────────────────────────────────────────────────
-- Each terminal only resizes the dimension that makes sense for its position,
-- so a key never disturbs a neighbor:
--   below slot  -> height only (taller/shorter); width keys are no-ops
--   left/right  -> width only  (broader/narrower); height keys are no-ops
-- Keys: K taller, J shorter, H broader, L narrower (Ctrl+arrows mirror them).
local ACTION_CMD = {
  taller = "resize +", shorter = "resize -",
  broader = "vertical resize +", narrower = "vertical resize -",
}
-- Which actions are meaningful for a slot (others bind to a silent no-op so
-- they neither error (J=join/K=keywordprg) nor poke a neighbor).
local function active_actions(slot)
  if slot == "left" or slot == "right" then return { broader = true, narrower = true } end
  if slot == "below" then return { taller = true, shorter = true } end
  return {}  -- tab: full screen, nothing to resize
end

local function remember_size(buf)
  local alias, slot = vim.b[buf].jupynvim_term_alias, vim.b[buf].jupynvim_term_slot
  local w = alias and win_of(buf)
  if not (alias and slot and w) then return end
  M._sizes[skey(alias, slot)] = { h = vim.api.nvim_win_get_height(w), w = vim.api.nvim_win_get_width(w) }
end

local function do_resize(buf, action)
  local step = ((require("jupynvim").config or {}).terminal or {}).resize_step or 3
  pcall(vim.cmd, ACTION_CMD[action] .. step)
  remember_size(buf)  -- persist across toggle
  vim.schedule(function() M.sync_size(buf) end)
end

local function resize_cfg()
  local c = (require("jupynvim").config or {}).terminal or {}
  return {
    normal = c.resize_keys_normal or { taller = "K", shorter = "J", broader = "H", narrower = "L" },
    insert = c.resize_keys or { taller = "<C-Up>", shorter = "<C-Down>", broader = "<C-Left>", narrower = "<C-Right>" },
  }
end

local function bind_resize_keys(buf, slot)
  local cfg = resize_cfg()
  local active = active_actions(slot)
  local function rk(modes, lhs, action)
    if not lhs or lhs == "" or not ACTION_CMD[action] then return end
    local on = active[action] and true or false
    local fn = on and function() do_resize(buf, action) end or function() end
    pcall(vim.keymap.set, modes, lhs, fn, {
      buffer = buf, silent = true, nowait = true,
      desc = "jupynvim: resize term (" .. action .. (on and "" or ", n/a here") .. ")",
    })
  end
  for action, lhs in pairs(cfg.normal) do rk("n", lhs, action) end
  for action, lhs in pairs(cfg.insert) do rk({ "n", "t" }, lhs, action) end
end

-- ── splits ─────────────────────────────────────────────────────────────────
-- If focus is in a FLOATING window (e.g. the snacks explorer picker), move to
-- a normal window first: splitting from a float fails / mangles the layout
-- ("E36: Not enough room"). Returns false if no normal window exists.
local function leave_floating()
  if vim.api.nvim_win_get_config(0).relative == "" then return true end
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative == "" then
      vim.api.nvim_set_current_win(w); return true
    end
  end
  return false
end

-- The main editor window: a normal (non-floating) window that isn't a
-- jupynvim terminal or the explorer/picker. Used so the BOTTOM terminal
-- splits under the editor column only, not full-width under a right terminal
-- (which caused the two terminals to overlap).
local function main_win()
  local best, best_area
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative == "" then
      local b = vim.api.nvim_win_get_buf(w)
      local ft = vim.bo[b].filetype or ""
      if not vim.b[b].jupynvim_term_alias and not vim.b[b].jupynvim_explorer
         and not ft:match("^snacks") then
        local area = vim.api.nvim_win_get_width(w) * vim.api.nvim_win_get_height(w)
        if not best_area or area > best_area then best, best_area = w, area end
      end
    end
  end
  return best
end

local function make_split(split, buf)
  leave_floating()
  if split == "tab" then
    pcall(vim.cmd, buf and ("tab sb " .. buf) or "tabnew")
    return true
  end
  local cmd
  if split == "below" then
    -- Split UNDER the editor column (belowright), not botright (full width),
    -- so a bottom terminal and a full-height right terminal tile cleanly.
    local mw = main_win()
    if mw then pcall(vim.api.nvim_set_current_win, mw) end
    cmd = buf and ("belowright sb " .. buf) or "belowright new"
  elseif split == "left" then
    cmd = buf and ("topleft vert sb " .. buf) or "topleft vnew"
  else -- right (and default): full-height column on the far right
    cmd = buf and ("botright vert sb " .. buf) or "botright vnew"
  end
  local ok, err = pcall(vim.cmd, cmd)
  if not ok then
    vim.notify("jupynvim: couldn't open terminal split (" .. tostring(err):gsub("^.-:E", "E") ..
               ").\n  Close a window/split and retry.", vim.log.levels.WARN)
    return false
  end
  -- Pin the terminal's size so toggling another window (e.g. the explorer)
  -- doesn't redistribute freed space into it (the "right term grew by the
  -- explorer's width" bug). Explicit :resize from the user still overrides.
  local w = vim.api.nvim_get_current_win()
  if split == "below" then vim.wo[w].winfixheight = true
  elseif split == "left" or split == "right" then vim.wo[w].winfixwidth = true end
  return true
end

-- Size the just-created split window: the slot's remembered size if any, else
-- the (configurable) default. Defaults are intentionally compact.
local function apply_size(split, alias, slot)
  local c = (require("jupynvim").config or {}).terminal or {}
  local remembered = M._sizes[skey(alias, slot)]
  if split == "below" then
    local h = (remembered and remembered.h) or c.bottom_height or 9
    pcall(vim.cmd, "resize " .. h)
  elseif split ~= "tab" then
    local w = (remembered and remembered.w)
      or c.side_width
      or math.max(40, math.min(80, math.floor(vim.o.columns * 0.4)) - 27)
    pcall(vim.cmd, "vertical resize " .. w)
  end
end

-- ── open / toggle ──────────────────────────────────────────────────────────
-- Open a remote shell. opts.split: "below"(default)/"right"/"left"/"tab".
-- opts.slot: toggle slot name (defaults to opts.split). opts.cwd: working dir.
function M.open(alias, opts)
  opts = opts or {}
  hook_paste()
  local split = opts.split or "below"
  local slot = opts.slot or split
  local J = require("jupynvim")
  local client = J.client_for(alias)

  if not make_split(split, nil) then return end
  apply_size(split, alias, slot)
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
  -- Shell line editing mode. Vim-style prompt editing (esc -> dd/cw/v/p at
  -- the command line) is the SHELL's job, exactly like a local zsh with
  -- `bindkey -v`: set terminal.editing = "vi" to get it on remotes whose
  -- dotfiles don't already enable it (bash and zsh both accept -o vi).
  local args = opts.args
  if not args then
    args = { "-l", "-i" }
    local editing = opts.editing or ((require("jupynvim").config or {}).terminal or {}).editing
    if editing == "vi" or editing == "emacs" then
      table.insert(args, "-o"); table.insert(args, editing)
    end
  end
  local err, res = client:call_sync("proc_spawn", {
    cmd = opts.cmd or "bash", args = args, cwd = cwd,
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
      local k2 = key(alias, e.pid)
      local entry = terms[k2]
      if not entry then
        -- terminal not registered yet (spawn RPC response still in flight):
        -- stash so the first prompt isn't lost. Bounded.
        local q = orphans[k2] or {}
        if #q < 200 then table.insert(q, e) end
        orphans[k2] = q
        return
      end
      if e.kind == "stdout" then
        pcall(vim.api.nvim_chan_send, entry.chan, vim.base64.decode(e.data_b64))
      elseif e.kind == "exit" then
        pcall(vim.api.nvim_chan_send, entry.chan, "\r\n[process exited with code " .. tostring(e.code) .. "]\r\n")
        if entry.buf and vim.api.nvim_buf_is_valid(entry.buf) then
          vim.b[entry.buf].jupynvim_term_alive = false
        end
        terms[k2] = nil
      end
    end)
  end
  -- Flush output that raced the spawn response (login banner, first prompt).
  local early = orphans[k]
  orphans[k] = nil
  for _, e in ipairs(early or {}) do
    if e.kind == "stdout" then
      pcall(vim.api.nvim_chan_send, chan, vim.base64.decode(e.data_b64))
    elseif e.kind == "exit" then
      pcall(vim.api.nvim_chan_send, chan, "\r\n[process exited with code " .. tostring(e.code) .. "]\r\n")
      vim.b[buf].jupynvim_term_alive = false
      terms[k] = nil
    end
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
      M._sizes[skey(alias, slot)] = nil  -- forget size so next open is default
      if slots(alias)[slot] == buf then slots(alias)[slot] = nil end
    end,
  })
  -- `:q`/`:close` on a terminal RESETS it (vs <C-/> toggle which keeps it):
  -- forget the remembered size and wipe the buffer (-> BufWipeout kills the
  -- PTY + clears the slot), so the next open is a fresh default-sized shell.
  -- Toggle hides via the window API, which doesn't fire QuitPre.
  vim.api.nvim_create_autocmd("QuitPre", {
    buffer = buf,
    callback = function()
      M._sizes[skey(alias, slot)] = nil
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(buf) then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
      end)
    end,
  })

  bind_resize_keys(buf, slot)
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
    if w then
      remember_size(buf)  -- capture current size so reshow restores it
      pcall(vim.api.nvim_win_close, w, false)
      return
    end
    if vim.b[buf].jupynvim_term_alive then
      if not make_split(split, buf) then return end
      apply_size(split, alias, slot)  -- restore the size you had
      vim.schedule(function() M.sync_size(buf, true); vim.cmd("startinsert") end)
      return
    end
  end
  M.open(alias, { split = split, slot = slot, cwd = opts.cwd })
end

return M

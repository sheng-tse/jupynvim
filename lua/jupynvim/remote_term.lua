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
-- Most recent terminal buffer per alias, for toggle/reuse.
M._last = {}

local function key(alias, pid) return alias .. ":" .. pid end

-- Open a remote shell. opts.cmd defaults to "bash", opts.args = {"-l", "-i"}.
-- opts.split: "below" (default), "right", "tab".
function M.open(alias, opts)
  opts = opts or {}
  local J = require("jupynvim")
  local client = J.client_for(alias)

  -- Layout
  local split = opts.split or "below"
  if split == "below" then vim.cmd("botright new")
  elseif split == "right" then vim.cmd("botright vnew")
  elseif split == "tab" then vim.cmd("tabnew")
  else vim.cmd("botright new") end
  local buf = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].bufhidden = "hide"  -- survive window close so toggle can reshow it
  vim.b[buf].jupynvim_term_alias = alias
  vim.b[buf].jupynvim_term_alive = true
  M._last[alias] = buf
  vim.api.nvim_buf_set_name(buf, string.format("term://%s/[connecting]", alias))

  local cols = vim.api.nvim_win_get_width(win)
  local rows = vim.api.nvim_win_get_height(win)

  -- Create the terminal channel BEFORE spawning so we can write the initial
  -- "spawning..." message and any early output without race.
  local pid_ref = { pid = nil }
  local chan = vim.api.nvim_open_term(buf, {
    on_input = function(_event, _term, _bufnr, data)
      if not pid_ref.pid then return end
      local b64 = vim.base64.encode(data)
      client:call("proc_stdin", { pid = pid_ref.pid, data_b64 = b64 }, function() end)
    end,
  })

  -- Spawn
  local err, res = client:call_sync("proc_spawn", {
    cmd = opts.cmd or "bash",
    args = opts.args or { "-l", "-i" },
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
  local k = key(alias, res.pid)
  terms[k] = { buf = buf, win = win, chan = chan, alias = alias, pid = res.pid, client = client }
  vim.api.nvim_buf_set_name(buf, string.format("term://%s/%d", alias, res.pid))

  -- Subscribe to proc_event for this pid. Register on the client once;
  -- multi-pid demuxing happens by filtering inside the handler.
  if not client._proc_event_hooked then
    client._proc_event_hooked = true
    client:on("proc_event", function(args)
      local e = args[1] or args
      local entry = terms[key(alias, e.pid)]
      if not entry then return end
      if e.kind == "stdout" then
        local data = vim.base64.decode(e.data_b64)
        pcall(vim.api.nvim_chan_send, entry.chan, data)
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

  -- Propagate window resize → proc_resize
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    buffer = buf,
    callback = function()
      if not vim.api.nvim_win_is_valid(win) then return end
      local c = vim.api.nvim_win_get_width(win)
      local r = vim.api.nvim_win_get_height(win)
      client:call("proc_resize", { pid = res.pid, cols = c, rows = r }, function() end)
    end,
  })

  -- On buffer wipeout, kill the remote process
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    callback = function()
      client:call("proc_kill", { pid = res.pid }, function() end)
      terms[k] = nil
    end,
  })

  -- Drop into terminal mode immediately
  vim.cmd("startinsert")
  return buf, res.pid
end

-- Toggle the remote terminal for `alias`:
--   • visible  → hide it (close the window; PTY keeps running, bufhidden=hide)
--   • hidden+alive → reshow in a split, enter insert
--   • none/dead → spawn a fresh one
-- So you can summon/dismiss a terminal from anywhere mid-task.
function M.toggle(alias, opts)
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.b[b].jupynvim_term_alias == alias then
      pcall(vim.api.nvim_win_close, w, false)
      return
    end
  end
  local last = M._last[alias]
  if last and vim.api.nvim_buf_is_valid(last) and vim.b[last].jupynvim_term_alive then
    local split = (opts and opts.split) or "below"
    vim.cmd((split == "right" and "botright vert sb " or "botright sb ") .. last)
    vim.cmd("resize 15")
    vim.cmd("startinsert")
    return
  end
  M.open(alias, opts)
end

return M

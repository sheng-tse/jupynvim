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
  vim.api.nvim_create_autocmd("TextYankPost", {
    group = vim.api.nvim_create_augroup("jupynvim_term_yank", { clear = true }),
    callback = function() M._yank_ts = vim.uv.hrtime() end,
  })
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

-- ── readline config ────────────────────────────────────────────────────────
-- bash's vi command mode hardwires `v` to "edit the command line in $EDITOR"
-- (nano on stock debian), which is jarring inside an embedded terminal, and
-- readline has no inline visual mode to offer instead (that is a zsh
-- feature). jupynvim's bash terminals therefore get their own INPUTRC that
-- keeps system + user settings via $include and disables just that binding.
-- Scoped to our terminals only: nothing else on the remote sees it.
local INPUTRC_BODY = table.concat({
  "# generated by jupynvim - readline setup for its remote terminals",
  "$include /etc/inputrc",
  "$include ~/.inputrc",
  "$if mode=vi",
  "set keymap vi-command",
  '"v": ""',
  "$endif",
}, "\n")

-- Write a generated config file under ~/.local/share/jupynvim on the remote
-- (once per connection) and return its absolute path. Returns nil on failure.
local function provision_file(client, cache_key, relpath, body)
  if client[cache_key] ~= nil then
    return client[cache_key] or nil
  end
  local script = 'f="$HOME/' .. relpath .. '" && mkdir -p "${f%/*}" && cat > "$f" <<\'JNVEOF\'\n'
    .. body .. '\nJNVEOF\nprintf \'%s\' "$f"'
  local err, res = client:call_sync("run", { argv = { "sh", "-c", script } }, 8000)
  local path = (not err) and type(res) == "table" and res.code == 0 and res.stdout or nil
  if path == "" then path = nil end
  client[cache_key] = path or false
  return path
end

local function ensure_inputrc(client)
  return provision_file(client, "_jnv_inputrc", ".local/share/jupynvim/inputrc", INPUTRC_BODY)
end

-- zsh side of the same idea: visual mode at the prompt (v + region
-- highlight + d) only exists in zsh's line editor, so when a terminal runs
-- zsh, give it a generated ZDOTDIR. The user's own ~/.zshrc wins when one
-- exists; otherwise a minimal vi-mode setup with a NORMAL/VISUAL right
-- prompt indicator, conda hook and a sane prompt. Nothing in $HOME changes.
local ZSHRC_BODY = table.concat({
  "# generated by jupynvim - sourced via ZDOTDIR in its remote terminals",
  'if [ -f "$HOME/.zshrc" ]; then',
  '  ZDOTDIR="$HOME"',
  '  . "$HOME/.zshrc"',
  "else",
  '  export PATH="$HOME/.local/bin:$PATH"',
  "  PROMPT='%F{6}%n@%m%f:%F{4}%~%f$ '",
  '  if [ -f "$HOME/miniconda3/etc/profile.d/conda.sh" ]; then',
  '    . "$HOME/miniconda3/etc/profile.d/conda.sh" && conda activate base',
  "  fi",
  "  bindkey -v",
  "  export KEYTIMEOUT=15",
  "  function jupynvim-vi-indicator {",
  '    local m=""',
  "    if [[ $KEYMAP == vicmd ]]; then",
  '      if (( REGION_ACTIVE )); then m="%F{5}VISUAL%f"; else m="%F{2}NORMAL%f"; fi',
  "    fi",
  '    if [[ $RPS1 != $m ]]; then RPS1=$m; zle reset-prompt; fi',
  "  }",
  "  function zle-keymap-select { jupynvim-vi-indicator }",
  "  function zle-line-init { jupynvim-vi-indicator }",
  "  function zle-line-pre-redraw { jupynvim-vi-indicator }",
  "  zle -N zle-keymap-select",
  "  zle -N zle-line-init",
  "  zle -N zle-line-pre-redraw",
  "fi",
}, "\n")

local function ensure_zdotdir(client)
  local rc = provision_file(client, "_jnv_zshrc", ".local/share/jupynvim/zdot/.zshrc", ZSHRC_BODY)
  return rc and rc:gsub("/%.zshrc$", "") or nil
end

-- ── v -> visual mode bridge (bash) ─────────────────────────────────────────
-- bash's line editor has no visual mode, but jupynvim owns both ends of the
-- PTY. So in bash terminals, v in vi command mode is bound (via a
-- PROMPT_COMMAND-installed bind -x) to emit a private OSC sequence. When
-- that sequence comes back through the output stream, the frontend puts the
-- shell back in insert mode and drops nvim into ITS visual mode at the
-- cursor: real highlight, every motion, y yanks to registers. One esc, then
-- v, exactly like a local vi-mode shell.
local VISUAL_OSC = "\27]51;jupynvim-visual\7"
local PASTE_OSC = "\27]51;jupynvim-paste\7"
local BIND_VISUAL =
  [[bind -m vi-command -x '"v": printf "\033]51;jupynvim-visual\007" > /dev/tty' 2>/dev/null; ]] ..
  [[bind -m vi-command -x '"p": printf "\033]51;jupynvim-paste\007" > /dev/tty' 2>/dev/null; ]] ..
  [[bind -m vi-insert '"\C-y": yank' 2>/dev/null]]

-- Timestamp of the last nvim yank anywhere (TextYankPost). Compared against
-- the per-terminal shell kill-ring timestamp to decide what p pastes.
M._yank_ts = 0

-- Freshness heuristic for the unified p: every key typed into the terminal
-- passes through on_input, so shell-side kill-ring activity (dd/x/cw/y...
-- in vi command mode after an esc) can be noticed as it happens.
local function track_keys(buf, data)
  if data == "\27" then
    vim.b[buf].jnv_vicmd = true
  elseif vim.b[buf].jnv_vicmd and #data == 1 then
    if data:match("^[dxXyD]") then
      vim.b[buf].jnv_kill_ts = vim.uv.hrtime()
    elseif data:match("^[csSC]") then
      vim.b[buf].jnv_kill_ts = vim.uv.hrtime()
      vim.b[buf].jnv_vicmd = false  -- these end in insert mode
    elseif data:match("^[iaAIR]") then
      vim.b[buf].jnv_vicmd = false
    end
  end
end

-- Unified p at the prompt: paste whichever is fresher, the nvim register
-- (esc-esc yanks in the terminal, yanks from any other buffer) or the
-- shell's own kill-ring (dd/x/cw at the prompt). The shell sits in vi
-- command mode when this fires; both branches paste after the cursor and
-- end back in command mode, like vi's p.
local function bridge_paste(buf)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  local kill_ts = vim.b[buf].jnv_kill_ts or 0
  local reg = (vim.fn.getreg('"') or ""):gsub("\n", " "):gsub("%s+$", "")
  if M._yank_ts > kill_ts and reg ~= "" then
    send_text(buf, "a" .. reg .. "\27")
  else
    send_text(buf, "a\25\27")  -- C-y: the shell's native kill-ring yank
  end
end

local function enter_visual(buf)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  if vim.api.nvim_get_current_buf() ~= buf then return end
  local m = vim.fn.mode()
  local keys
  if m == "t" then
    keys = "<C-\\><C-n>v"
  elseif m:sub(1, 1) == "n" then
    keys = "v"
  end
  if not keys then return end
  -- remember where the SHELL's cursor is (== nvim cursor here): the shell
  -- sits in vi command mode at this spot while the user selects in nvim,
  -- and the visual operators below translate the selection into readline
  -- edits relative to it
  local win = win_of(buf)
  if win then
    local cur = vim.api.nvim_win_get_cursor(win)
    vim.b[buf].jnv_bridge_row = cur[1]
    vim.b[buf].jnv_bridge_col = cur[2]
  end
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "n", false)
end

-- Visual operators on the terminal buffer. On the command line (the row
-- where the bridge started, shell waiting in vi command mode) they become
-- real readline edits sent down the PTY:
--   d/x  -> delete the selected chars (lands in the shell kill-ring: p works)
--   c    -> same, then insert mode
--   y    -> delete + undo: line untouched, kill-ring loaded, so p pastes the
--           selection; the text is also yanked into nvim's registers
-- Anywhere else (output/scrollback) y is a plain nvim yank and d/c are
-- read-only, exactly like a local :terminal.
local function bind_visual_ops(buf)
  local function op(key)
    local brow = vim.b[buf].jnv_bridge_row
    local bcol = vim.b[buf].jnv_bridge_col
    local mode = vim.fn.mode()
    local vp, cp = vim.fn.getpos("v"), vim.fn.getpos(".")
    local sl, sc, el = vp[2], vp[3], cp[2]
    if el < sl or (el == sl and cp[3] < sc) then
      sl, sc, el = cp[2], cp[3], vp[2]
    end
    local on_prompt = brow and mode == "v" and sl == brow and el == brow
    if not on_prompt then
      -- outside the command line: behave exactly like a local :terminal
      if key == "y" then
        vim.api.nvim_feedkeys("y", "n", false)
      else
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
        vim.notify("jupynvim: output is read-only (y copies; d/c/x edit the command line)",
                   vim.log.levels.INFO)
      end
      return
    end
    local region = vim.fn.getregion(vp, cp, { type = mode })
    vim.fn.setreg('"', table.concat(region, "\n"))
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
    local line = vim.api.nvim_buf_get_lines(buf, brow - 1, brow, false)[1] or ""
    local n = vim.fn.strchars(region[1] or "")
    -- chars between the selection start and the shell cursor (the anchor,
    -- where v was pressed: the shell is still parked there in command mode)
    local back = vim.fn.strchars(line:sub(sc, bcol))
    local seq = (back > 0 and (back .. "h") or "") .. n .. "x"
    if key == "y" then
      seq = seq .. "u"  -- delete + undo: kill-ring loaded, line untouched
    elseif key == "c" then
      seq = seq .. "i"
    end
    send_text(buf, seq)
    -- both the register and the shell kill-ring now hold the selection;
    -- equal timestamps make the unified p prefer the ring (same content)
    local now = vim.uv.hrtime()
    M._yank_ts = now
    vim.b[buf].jnv_kill_ts = now
    vim.b[buf].jnv_bridge_row = nil
    vim.cmd("startinsert")
  end
  for _, lhs in ipairs({ "d", "x", "c", "y" }) do
    pcall(vim.keymap.set, "x", lhs, function() op(lhs) end,
      { buffer = buf, silent = true, nowait = true, desc = "jupynvim: visual " .. lhs })
  end
  -- back at the live prompt: the bridge handoff is over
  vim.api.nvim_create_autocmd("TermEnter", {
    buffer = buf,
    callback = function() vim.b[buf].jnv_bridge_row = nil end,
  })
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

-- Resize the window currently showing the alias/slot terminal back to its
-- remembered/default size. Used by the explorer when it relocates a terminal:
-- after the dashboard closes with `q`, the <C-/> terminal expands to fill the
-- main area; when a file then opens on top of it, this shrinks it back to its
-- compact slot size. remember_size only fires on manual resize/toggle (not the
-- auto-expand), so the remembered size here is never the expanded one.
function M.restore_size(alias, slot)
  slot = slot or "below"
  local buf = slots(alias)[slot]
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  local w = win_of(buf)
  if not w then return end
  local c = (require("jupynvim").config or {}).terminal or {}
  local remembered = M._sizes[skey(alias, slot)]
  if slot == "below" then
    local h = (remembered and remembered.h) or c.bottom_height or 9
    pcall(vim.api.nvim_win_set_height, w, h)
  elseif slot ~= "tab" then
    local width = (remembered and remembered.w) or c.side_width
      or math.max(40, math.min(80, math.floor(vim.o.columns * 0.4)) - 27)
    pcall(vim.api.nvim_win_set_width, w, width)
  end
end

-- Opening/hiding a terminal split resizes the notebook window (a side
-- terminal narrows it), leaving the width-sized frames stale. Re-render via
-- the shared helper (synchronous + scheduled backstop, before the redraw,
-- so no flash). Covers the :JupynvimTerm path that the <C-/> dispatcher
-- doesn't go through.
local function refresh_notebooks()
  pcall(function() require("jupynvim")._refresh_notebooks_soon() end)
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
      track_keys(buf, data)
      client:call("proc_stdin", { pid = pid_ref.pid, data_b64 = vim.base64.encode(data) }, function() end)
    end,
  })

  local cwd = opts.cwd
  if not cwd then
    local ok, root = pcall(function() return require("jupynvim.remote_explorer").current_root(alias) end)
    if ok then cwd = root end
  end
  -- Shell + line editing mode. Vim-style prompt editing (esc -> dd/cw/v/p
  -- at the command line) is the SHELL's job, exactly like a local zsh with
  -- `bindkey -v`. terminal.editing = "vi" passes -o vi (bash and zsh both
  -- accept it) for remotes whose dotfiles don't enable it. Visual mode with
  -- highlight only exists in zsh: set shell = "zsh" on the profile (or
  -- terminal.shell globally) for full parity with a local zsh.
  local conf = J.config or {}
  local prof = (conf.remote or {})[alias] or {}
  local shell = opts.cmd or prof.shell or (conf.terminal or {}).shell or "bash"
  local editing = opts.editing or (conf.terminal or {}).editing
  local args = opts.args
  if not args then
    args = { "-l", "-i" }
    if editing == "vi" or editing == "emacs" then
      table.insert(args, "-o"); table.insert(args, editing)
    end
  end
  local function spawn(c)
    local env = { TERM = "xterm-256color", COLORTERM = "truecolor" }
    if c:match("bash$") then
      local irc = ensure_inputrc(client)
      if irc then env.INPUTRC = irc end
      if editing == "vi" then env.PROMPT_COMMAND = BIND_VISUAL end
    elseif c:match("zsh$") then
      local zd = ensure_zdotdir(client)
      if zd then env.ZDOTDIR = zd end
    end
    return client:call_sync("proc_spawn", {
      cmd = c, args = args, cwd = cwd,
      env = env, cols = cols, rows = rows,
    }, 10000)
  end
  local err, res = spawn(shell)
  if err and shell ~= "bash" then
    -- configured shell missing on this remote: never lock the user out
    vim.notify("jupynvim: shell '" .. shell .. "' unavailable on " .. alias ..
               " (" .. tostring(err) .. "); using bash.\n" ..
               "  For visual mode at the prompt: install zsh on the remote\n" ..
               "  (e.g. sudo apt-get install -y zsh), then reopen the terminal.",
               vim.log.levels.WARN)
    shell = "bash"
    err, res = spawn(shell)
  end
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
        local data = vim.base64.decode(e.data_b64)
        if data:find(VISUAL_OSC, 1, true) then
          -- the shell's v announced itself: the shell stays parked in vi
          -- command mode at the cursor while nvim runs the selection; the
          -- visual operators translate the result back into readline edits
          vim.schedule(function() enter_visual(entry.buf) end)
        elseif data:find(PASTE_OSC, 1, true) then
          vim.schedule(function() bridge_paste(entry.buf) end)
        end
        pcall(vim.api.nvim_chan_send, entry.chan, data)
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
  bind_visual_ops(buf)
  refresh_notebooks()  -- the new split narrowed the notebook; redraw frames
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
      refresh_notebooks()  -- notebook reclaimed the space; redraw frames
      return
    end
    if vim.b[buf].jupynvim_term_alive then
      if not make_split(split, buf) then return end
      apply_size(split, alias, slot)  -- restore the size you had
      refresh_notebooks()  -- the reshown split narrowed the notebook again
      vim.schedule(function() M.sync_size(buf, true); vim.cmd("startinsert") end)
      return
    end
  end
  M.open(alias, { split = split, slot = slot, cwd = opts.cwd })
end

return M

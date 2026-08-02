-- Remote session dispatch: the explorer/terminal/picker entry points, the
-- working-directory bookkeeping behind them, and the global keys that are
-- borrowed only while a session is active (issue #24).
--
-- install(M) writes onto the main module table, so callers keep reaching these
-- as jupynvim.explorer / jupynvim.use_local / jupynvim._set_active_alias.

local Dispatch = {}

function Dispatch.install(M)
M._resolved_home = {}
function M._note_resolved_home(alias, path)
  if alias and path and path ~= "" and path ~= "~" then
    M._resolved_home[alias] = path
  end
end

-- Where the session starts out, before any re-rooting.
local function session_home(alias)
  local profile = M.config.remote and M.config.remote[alias]
  return M._resolved_home[alias] or (profile and profile.home) or "~"
end

-- The remote analogue of vim's cwd, tracked per alias.
M._session_cwd = {}

-- Record an explicit cd: :JupynvimRemoteCd, or `-` / `.` in the tree. This is
-- deliberately NOT the tree's current root. <leader>e re-roots the tree at the
-- project root of the file you are in, and if cwd followed that, one press of
-- <leader>e would overwrite the very thing <leader>E exists to remember and
-- you could never get back to where you cd'd.
function M._note_session_cwd(alias, path)
  if alias and path and path ~= "" then M._session_cwd[alias] = path end
end

local function session_cwd(alias)
  return M._session_cwd[alias] or session_home(alias)
end

-- Walk up from `dir` looking for a project marker, one fs_list per level (a
-- marker-per-level fs_stat would be markers x levels round trips over SSH).
-- Stops at the session home so we never climb out into /.
local function remote_project_root(alias, dir, cb)
  local cl = M.clients[alias]
  if not (cl and cl.job and dir) then return cb(nil) end
  local mk = M.config.root_markers or {}
  local vcs, build = {}, {}
  for _, m in ipairs(mk.vcs or {}) do vcs[m] = true end
  for _, m in ipairs(mk.build or {}) do build[m] = true end
  -- Stop at whichever boundary we reach first. Without the cwd stop, browsing
  -- somewhere with no repo above it (e.g. /ocean/projects/...) walks all the
  -- way to / one fs_list at a time.
  local home, cwd = session_home(alias), session_cwd(alias)
  -- Nearest build-file hit, kept as the answer only if no VCS root turns up
  -- further out. Otherwise a sub-crate's Cargo.toml would beat the repo.
  local fallback = nil
  local seen = 0
  local function step(d)
    seen = seen + 1
    if not d or d == "" or d == "/" or seen > 12 then return cb(fallback) end
    cl:call("fs_list", { path = d }, function(err, res)
      if not err and res then
        for _, e in ipairs(res.entries or {}) do
          if vcs[e.name] then return cb(d) end
          if build[e.name] and not fallback then fallback = d end
        end
      end
      if d == home or d == cwd then return cb(fallback) end
      local parent = d:match("(.+)/[^/]+$")
      if not parent or parent == d then return cb(fallback) end
      step(parent)
    end)
  end
  step(dir)
end

-- Shared toggle for both explorer variants. `root_for` is called only when we
-- are about to OPEN, and hands back the root asynchronously.
local function explorer_toggle(root_for)
  local alias = M._active_alias
  if alias and M.clients[alias] and M.clients[alias].job then
    local re = require("jupynvim.remote.explorer")
    local win = re.visible_win(alias)
    if win and #vim.api.nvim_list_wins() > 1 then
      -- toggle: hide it (picker-based explorer needs picker:close, not win_close)
      if re.close then pcall(re.close, alias) else pcall(vim.api.nvim_win_close, win, false) end
      M._refresh_notebooks_soon()
    else
      -- fresh: an explicit jump lands collapsed, unlike `-` / backspace which
      -- is navigation and keeps the folds you already opened.
      root_for(alias, function(root) M.remote_browse(alias, root, { fresh = true }) end)
    end
    return
  end
  -- Local fallback: snacks explorer, else netrw.
  local ok = pcall(function() require("snacks").explorer() end)
  if not ok then pcall(vim.cmd, "Lexplore") end
  M._refresh_notebooks_soon()
end

-- Toggle the remote tree at the PROJECT ROOT of the file you are in: walk up
-- from the current jupynvim:// buffer until a root marker turns up, else the
-- session home. Mirrors what a distro's <leader>e (root dir) does locally.
function M.explorer()
  explorer_toggle(function(alias, done)
    local name = vim.api.nvim_buf_get_name(0)
    local a, path = M._parse_uri(name)
    -- Not sitting on a remote file, so there is no project to root at. Fall
    -- back to the working directory rather than to wherever you happened to
    -- browse to, which is what leaving this nil used to do.
    if not (a == alias and path) then return done(session_cwd(alias)) end
    local dir = path:match("(.+)/[^/]+$") or path
    remote_project_root(alias, dir, function(root)
      done(root or session_cwd(alias))
    end)
  end)
end

-- Toggle the remote tree at the remote working directory, the analogue of a
-- distro's <leader>E (cwd).
function M.explorer_cwd()
  explorer_toggle(function(alias, done) done(session_cwd(alias)) end)
end

-- Terminal dispatcher / TOGGLE. SSH-connected → toggle a REMOTE PTY terminal
-- for the active alias (summon/dismiss from anywhere); otherwise fall back to
-- the local terminal (snacks, else :terminal). Bound to terminal_keys in setup.
function M.terminal()
  local alias = M._active_alias
  if alias and M.clients[alias] and M.clients[alias].job then
    require("jupynvim.remote.term").toggle(alias)
    M._refresh_notebooks_soon()
    return
  end
  local ok = pcall(function() require("snacks").terminal() end)
  if not ok then pcall(vim.cmd, "botright split | terminal") end
  M._refresh_notebooks_soon()
end

-- Toggle a SECOND remote terminal on the right (independent of the <C-/>
-- bottom one). For a scratch/extra shell. Bound to terminal_right_keys.
function M.terminal_right()
  local alias = M._active_alias
  if alias and M.clients[alias] and M.clients[alias].job then
    require("jupynvim.remote.term").toggle(alias, { split = "right" })
    M._refresh_notebooks_soon()
  else
    vim.notify("jupynvim: no active SSH session", vim.log.levels.WARN)
  end
end

-- True when an SSH session is the active context (so file/search keys should
-- target the remote). Otherwise callers fall back to the user's local mapping.
function M.remote_active()
  local a = M._active_alias
  return a and M.clients[a] and M.clients[a].job and true or false
end

-- Find-files dispatcher: remote picker when SSH-connected, else the user's own
-- local mapping (captured at bind time). Bound to pick_keys.files.
function M.find_files()
  if M.remote_active() then
    require("jupynvim.remote.pick").files(M._active_alias)
    return true
  end
  return false
end

-- Grep dispatcher: remote grep when SSH-connected, else local mapping.
function M.grep_pick()
  if M.remote_active() then
    require("jupynvim.remote.pick").grep(M._active_alias)
    return true
  end
  return false
end

-- ---------- global dispatch keys ----------
--
-- <leader>e, <C-/>, <leader>ff and friends target the remote when a session is
-- active. Each key lands in one of two modes, decided by whether you already
-- had a mapping for it (issue #24: we used to take all of them unconditionally,
-- so every buffer of every filetype showed "jupynvim:" in which-key):
--
--   "ssh"        you had one. we take the key only while a session is active
--                and mapset() yours back the moment it ends.
--   "permanent"  you had none. nothing to clobber, so we keep it bound and it
--                falls through to the local equivalent.
--
-- terminal_right_keys is always "ssh": it has no local behavior to offer.
M._dispatch = { mode = {}, saved = {}, specs = {}, applied = {} }

-- Ownership is tracked by CALLBACK IDENTITY, not by matching a prefix on the
-- description. Descriptions are user-visible and get reworded; if that string
-- were load-bearing, a rename would make us mistake our own mapping for yours
-- and capture it as the "original", losing yours for good.
local function dispatch_is_ours(lhs, mode)
  local fn = (M._dispatch.applied[lhs] or {})[mode]
  if not fn then return false end
  local m = vim.fn.maparg(lhs, mode, false, true)
  return m ~= nil and m.callback == fn
end

-- Replay the mapping we displaced, for the connected case where the remote
-- picker declines (find_files/grep_pick return false).
local function dispatch_replay(lhs, kind)
  local orig = (M._dispatch.saved[lhs] or {})["n"]
  if orig and orig.callback then pcall(orig.callback)
  elseif orig and orig.rhs and orig.rhs ~= "" then
    local feed = vim.api.nvim_replace_termcodes(orig.rhs, true, true, true)
    vim.api.nvim_feedkeys(feed, orig.noremap == 1 and "n" or "m", false)
  else
    pcall(function() require("snacks").picker[kind]() end)
  end
end

local function dispatch_specs()
  local pk = M.config.pick_keys or {}
  local s = {}
  for _, lhs in ipairs(M.config.explorer_keys or {}) do
    s[#s + 1] = { lhs = lhs, modes = { "n" },
      rhs = function() M.explorer() end,
      opts = { desc = "Remote Explorer (project root)" } }
  end
  for _, lhs in ipairs(M.config.explorer_cwd_keys or {}) do
    s[#s + 1] = { lhs = lhs, modes = { "n" },
      rhs = function() M.explorer_cwd() end,
      opts = { desc = "Remote Explorer (cwd)" } }
  end
  for _, lhs in ipairs(M.config.terminal_keys or {}) do
    s[#s + 1] = { lhs = lhs, modes = { "n", "t" },
      rhs = function()
        if vim.fn.mode() == "t" then vim.cmd("stopinsert") end
        M.terminal()
      end,
      opts = { desc = "Remote Terminal (bottom)" } }
  end
  for _, lhs in ipairs(M.config.terminal_right_keys or {}) do
    s[#s + 1] = { lhs = lhs, modes = { "n" }, ssh_only = true,
      rhs = function() M.terminal_right() end,
      opts = { desc = "Remote Terminal (right)" } }
  end
  local pick_desc = { files = "Remote Find Files", grep = "Remote Grep" }
  for _, kind in ipairs({ "files", "grep" }) do
    for _, lhs in ipairs(pk[kind] or {}) do
      s[#s + 1] = { lhs = lhs, modes = { "n" },
        rhs = function()
          local handled = (kind == "files") and M.find_files() or M.grep_pick()
          if not handled then dispatch_replay(lhs, kind) end
        end,
        opts = { desc = pick_desc[kind], silent = true } }
    end
  end
  return s
end

local function dispatch_apply(spec)
  for _, mode in ipairs(spec.modes) do
    if pcall(vim.keymap.set, mode, spec.lhs, spec.rhs, spec.opts) then
      M._dispatch.applied[spec.lhs] = M._dispatch.applied[spec.lhs] or {}
      M._dispatch.applied[spec.lhs][mode] = spec.rhs
    end
  end
end

local function dispatch_unapply(spec)
  for _, mode in ipairs(spec.modes) do
    local saved = (M._dispatch.saved[spec.lhs] or {})[mode]
    if saved and not vim.tbl_isempty(saved) then
      pcall(vim.fn.mapset, saved)
    else
      pcall(vim.keymap.del, mode, spec.lhs)
    end
    if M._dispatch.applied[spec.lhs] then
      M._dispatch.applied[spec.lhs][mode] = nil
    end
  end
end

local function dispatch_snapshot(spec)
  local snap, any = {}, false
  for _, mode in ipairs(spec.modes) do
    local m = vim.fn.maparg(spec.lhs, mode, false, true)
    snap[mode] = m
    if m and not vim.tbl_isempty(m) then any = true end
  end
  M._dispatch.saved[spec.lhs] = snap
  return any
end

-- Decide each key's mode and bind the permanent ones. Runs more than once
-- (setup, VeryLazy, +500ms) so it lands after a distro's own maps; a pass that
-- finds OUR mapping in place leaves the earlier decision alone.
function M._dispatch_bind()
  M._dispatch.specs = dispatch_specs()
  local connected = M.remote_active()
  for _, spec in ipairs(M._dispatch.specs) do
    if not dispatch_is_ours(spec.lhs, spec.modes[1]) then
      local had = dispatch_snapshot(spec)
      if had or spec.ssh_only then
        M._dispatch.mode[spec.lhs] = "ssh"
        if connected then dispatch_apply(spec) end
      else
        M._dispatch.mode[spec.lhs] = "permanent"
        dispatch_apply(spec)
      end
    end
  end
end

-- Session became active: take the "ssh" keys, re-snapshotting first in case
-- your mapping changed since the last bind pass.
local function dispatch_install()
  for _, spec in ipairs(M._dispatch.specs or {}) do
    if M._dispatch.mode[spec.lhs] == "ssh" then
      if not dispatch_is_ours(spec.lhs, spec.modes[1]) then
        dispatch_snapshot(spec)
      end
      dispatch_apply(spec)
    end
  end
end

-- Session ended: give the keys back exactly as they were.
local function dispatch_restore()
  for _, spec in ipairs(M._dispatch.specs or {}) do
    if M._dispatch.mode[spec.lhs] == "ssh"
       and dispatch_is_ours(spec.lhs, spec.modes[1]) then
      dispatch_unapply(spec)
    end
  end
end

-- Single funnel for every place the active session changes, so the keymap
-- lifecycle can't drift out of sync with it.
function M._set_active_alias(alias)
  local was = M._active_alias
  M._active_alias = alias
  if alias and not was then dispatch_install()
  elseif was and not alias then dispatch_restore() end
end

-- Switch back to a local backend. Clears the active-remote alias so
-- <leader>e goes back to the local (snacks) explorer.
function M.use_local()
  M._set_active_alias(nil)
  if M.client and not M._remote_spec then return M.client end
  if M.client then
    pcall(function() M.client:stop() end)
    M.client = nil
  end
  M._remote_spec = nil
  local c = M._ensure_client()
  -- spawning the local core re-attaches kitty graphics with raw tty writes;
  -- if those scroll the screen, nvim's grid is visually shifted (stale rows
  -- on top, dead rows below the statusline). Repaint the whole screen once
  -- the attach has settled.
  vim.defer_fn(function() pcall(vim.cmd, "mode") end, 150)
  vim.defer_fn(function() pcall(vim.cmd, "mode") end, 500)
  return c
end

-- Parse a jupynvim:// URI into (alias, path). Returns nil on no match.
--   jupynvim://psc/home/user/foo.py  →  "psc", "/home/user/foo.py"
end

return Dispatch

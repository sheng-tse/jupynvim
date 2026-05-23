-- jupynvim — VSCode-style Jupyter notebook editing in Neovim.
--
-- Usage (lazy.nvim-style):
--   require("jupynvim").setup({ core_path = "/path/to/jupynvim-core" })
--
-- Or just call setup({}) — it'll auto-detect the binary in this repo.

local M = {}

local Notebook = require("jupynvim.notebook")
local Render   = require("jupynvim.render")
local RPC      = require("jupynvim.rpc")
local Keymaps  = require("jupynvim.keymaps")
local Image    = require("jupynvim.image")
local Log      = require("jupynvim.log")

M.client = nil    -- single backend process shared by all notebooks
M.config = {
  core_path = nil,
  python = nil,
  log_level = "info",
  -- "placeholder": real PNG via Kitty Unicode placeholder protocol
  --              (Ghostty 1.3.1+ supports it; image stays anchored to cell)
  -- "kitty":       real PNG via direct placement (lives at fixed screen coords)
  -- "chafa":       ASCII art fallback for terminals without graphics support
  image_renderer = "placeholder",
  -- Inline image grid size in terminal cells (rows x cols). Default 32x96
  -- works for typical matplotlib plots; bump if your terminal is large and
  -- you want sharper output, or shrink for compact display. Affects the
  -- Kitty Unicode placeholder rendering. Reported as #7 by medwatt.
  image_rows = 32,
  image_cols = 96,
  -- Per-action keymap overrides. Each value is either a string (replace lhs)
  -- or `false` (disable). See lua/jupynvim/keymaps.lua for the full default
  -- list. nil/missing leaves the default in place.
  keymaps = {},
  -- Skip ALL default keybindings if you want to bind everything yourself.
  disable_default_keymaps = false,
  -- Auto-detect a `.venv` next to the notebook (or in any parent directory)
  -- and use its python as the kernel interpreter. Bypasses needing to
  -- `ipykernel install --user` in every uv/poetry/pdm project. Set false
  -- to keep the old behavior of using only registered kernelspecs.
  auto_venv = true,
  -- LSP server names that should NOT attach to jupynvim buffers. Empty
  -- by default: users opt in for the ones that misbehave.
  --
  -- Common candidate: `ty` (Astral). It advertises notebookDocumentSync
  -- capability and assumes a `.ipynb` URI's buffer text must be the file's
  -- JSON content. jupynvim's buffer is the rendered cell view, not the
  -- on-disk JSON, so ty emits a "Failed to read notebook" diagnostic on
  -- every notebook open. Add `lsp_blocklist = { "ty" }` to setup if you
  -- hit this and don't need ty on notebooks. The proper long-term fix is
  -- jupynvim implementing the LSP notebook protocol so ty (and future
  -- notebook-aware LSPs) can do per-cell analysis. Tracked for v0.3.
  lsp_blocklist = {},
  -- Named remote profiles for :JupynvimOpenRemote. Each entry maps an alias
  -- (used as `alias:relative/path` in the command) to a connection spec.
  -- Example:
  --   remote = {
  --     psc_bridges2 = {
  --       host = "user@bridges2.psc.edu",
  --       core_path = "~/.local/bin/jupynvim-core",
  --       -- ssh_args = { "-J", "jumpbox" },  -- optional ProxyJump etc
  --       -- slurm = "interact -p GPU-shared --gpus 1 -t 02:00:00", -- v0.3.x
  --     },
  --   }
  remote = {},
}

-- ---------- backend helpers ----------

local function locate_core()
  if M.config.core_path then return M.config.core_path end
  -- Look for the binary next to this lua file: ../../core/target/release/jupynvim-core
  local src = debug.getinfo(1, "S").source
  if src:sub(1, 1) == "@" then src = src:sub(2) end
  local dir = vim.fn.fnamemodify(src, ":h:h:h")  -- .../jupynvim
  local candidate = dir .. "/core/target/release/jupynvim-core"
  if vim.fn.executable(candidate) == 1 then return candidate end
  return "jupynvim-core"
end

-- Internal: spawn a backend process with the given cmd vector and wire it up
-- with TTY attach + event handlers. Used for both local and SSH-remote spawns.
local function spawn_client(cmd_vec, label)
  Log.info(string.format("spawning core (%s): %s", label, table.concat(cmd_vec, " ")))
  local client = RPC.spawn({
    cmd = cmd_vec,
    env = vim.tbl_extend("force", vim.fn.environ(), {
      JUPYNVIM_LOG = M.config.log_level,
    }),
    on_exit = function(code)
      M.client = nil
      vim.schedule(function()
        vim.notify(string.format("jupynvim-core (%s) exited (code=%s)", label, tostring(code)),
                   vim.log.levels.WARN)
      end)
    end,
  })
  -- Attach the controlling TTY for native Kitty graphics. Local mode is
  -- attempted first; for SSH-remote backends the local-mode attempt fails
  -- (backend is on a different host) and Image.attach auto-falls-back to
  -- remote mode (escape_b64 round-trip).
  local tty_path = vim.env.JUPYNVIM_TTY or "/dev/tty"
  Image.attach(client, tty_path)

  client:on("cell_event", function(args)
    local p = args[1] or args
    M._handle_cell_event(p)
  end)
  client:on("kernel_event", function(args)
    local p = args[1] or args
    Log.debug("kernel_event: " .. vim.inspect(p):sub(1, 200))
  end)
  return client
end

local function ensure_client()
  if M.client and M.client.job then return M.client end
  M.client = spawn_client({ locate_core() }, "local")
  return M.client
end

-- ControlMaster socket path for an alias. Multiplexed SSH: run
-- `:JupynvimConnect <alias>` once to authenticate interactively (password,
-- 2FA, etc); subsequent ssh commands reuse the socket and skip auth.
local function control_path(alias)
  if not alias or alias == "" then return nil end
  local dir = vim.fn.stdpath("cache") .. "/jupynvim"
  vim.fn.mkdir(dir, "p")
  return dir .. "/cm-" .. alias
end

-- Resolve a possibly-function spec field. Functions can read env, prompt
-- the user, etc. at spawn time — useful for dynamic slurm jobids, cloud
-- tokens, anything that varies between calls.
local function resolve(field, spec)
  if type(field) == "function" then return field(spec) end
  return field
end

-- Build an SSH command vector that spawns jupynvim-core on a remote host.
-- spec.host: "user@host" passed to ssh (or an alias from ~/.ssh/config).
-- spec.core_path: remote path to jupynvim-core (default "jupynvim-core").
-- spec.ssh_args: extra args appended after `ssh` (e.g. ProxyJump). Optional.
--   Can be a function returning the array.
-- spec.slurm: if set, prepended to the remote command. Typical:
--   slurm = "srun -p GPU-shared --gpus 1 -t 02:00:00"
-- Can be a function returning the string — useful for attaching to an
-- existing job whose ID isn't known until call time:
--   slurm = function()
--     local jid = vim.env.PSC_JOBID or vim.fn.input("Job ID: ")
--     return ("srun --jobid=%s --overlap"):format(jid)
--   end
local function build_ssh_cmd(spec)
  local cmd = { "ssh" }
  -- -T disables remote PTY (we want raw stdio for msgpack).
  -- BatchMode=yes blocks interactive prompts (no password hangs). Use
  -- :JupynvimConnect <alias> first for hosts that need interactive auth.
  table.insert(cmd, "-T")
  table.insert(cmd, "-o")
  table.insert(cmd, "BatchMode=yes")
  -- Always pass ControlPath: if a ControlMaster socket exists (from a prior
  -- :JupynvimConnect), this reuses it (no auth). If not, ssh just makes a
  -- fresh connection. Either way, no extra wiring needed by the user.
  local cp = control_path(spec.label or spec.host)
  if cp then
    table.insert(cmd, "-o")
    table.insert(cmd, "ControlPath=" .. cp)
  end
  local ssh_args = resolve(spec.ssh_args, spec) or {}
  for _, a in ipairs(ssh_args) do table.insert(cmd, a) end
  table.insert(cmd, spec.host)
  local remote_cmd = spec.core_path or "jupynvim-core"
  local slurm = resolve(spec.slurm, spec)
  if slurm and slurm ~= "" then
    remote_cmd = slurm .. " " .. remote_cmd
  end
  -- `exec` keeps backend's stdio identical to ssh's stdio (no shell wrapper
  -- buffering in between). When slurm is involved the exec applies to srun
  -- which itself execs the job step.
  table.insert(cmd, "exec " .. remote_cmd)
  return cmd
end

-- Switch the active backend to a remote one spawned over SSH. Tears down
-- any existing client and any open notebook sessions (they belonged to the
-- previous backend). Idempotent: calling with the same host is a no-op.
function M.use_remote(spec)
  assert(type(spec) == "table" and spec.host, "use_remote: spec.host required")
  if M._remote_spec and M._remote_spec.host == spec.host and M.client and M.client.job then
    Log.info("jupynvim: already connected to " .. spec.host)
    return M.client
  end
  if M.client then
    pcall(function() M.client:stop() end)
    M.client = nil
  end
  M._remote_spec = spec
  -- spec.transport_cmd lets users override the default SSH-based spawn for
  -- non-SSH transports (gcloud compute ssh, aws ssm start-session, docker
  -- exec, etc). Can be a function returning the array for dynamic args.
  local cmd = resolve(spec.transport_cmd, spec) or build_ssh_cmd(spec)
  M.client = spawn_client(cmd, "remote:" .. spec.host)
  return M.client
end

-- Is the ControlMaster for this alias alive?
local function master_alive(alias, profile)
  local cp = control_path(alias)
  if not cp then return false end
  vim.fn.system({ "ssh", "-O", "check", "-o", "ControlPath=" .. cp, profile.host })
  return vim.v.shell_error == 0
end

-- Open an interactive SSH ControlMaster session in a terminal split. After
-- you authenticate (password, 2FA, key passphrase), the connection persists
-- as a multiplexed socket. Subsequent :JupynvimOpenRemote calls reuse it
-- without prompting. Similar to VSCode's "Connect to Host" flow.
--
-- Idempotent: if master is already alive, returns early. If a stale socket
-- file exists (master died but file remained), cleans up before reconnecting.
function M.connect(alias)
  local profile = M.config.remote and M.config.remote[alias]
  if not profile then
    vim.notify("jupynvim: no remote profile '" .. tostring(alias) .. "'", vim.log.levels.ERROR)
    return
  end
  local cp = control_path(alias)
  if master_alive(alias, profile) then
    vim.notify("jupynvim: " .. alias .. " already connected (control master alive)")
    return
  end
  -- Clean up stale socket file if any (master died without cleanup)
  vim.fn.system({ "rm", "-f", cp })

  -- -N: no remote command, just hold the connection open for multiplexing.
  -- ControlMaster=yes: create the socket. ControlPersist=4h: keep it for 4
  -- hours after the foreground exits (ssh detaches to background after auth).
  local args = { "ssh", "-N",
                 "-o", "ControlMaster=yes",
                 "-o", "ControlPath=" .. cp,
                 "-o", "ControlPersist=4h" }
  local ssh_args = resolve(profile.ssh_args, profile) or {}
  for _, a in ipairs(ssh_args) do table.insert(args, a) end
  table.insert(args, profile.host)
  vim.cmd("botright 15split")
  vim.cmd("enew")
  vim.fn.termopen(args, {
    on_exit = function(_, code)
      vim.schedule(function()
        if code == 0 and master_alive(alias, profile) then
          vim.notify("jupynvim: " .. alias .. " connected (master persists 4h)",
                     vim.log.levels.INFO)
        elseif code ~= 0 then
          vim.notify("jupynvim: " .. alias .. " connect failed (code=" .. code .. ")",
                     vim.log.levels.WARN)
        end
      end)
    end,
  })
  vim.notify("jupynvim: authenticate " .. alias .. " in the terminal split below",
             vim.log.levels.INFO)
end

-- Tear down the ControlMaster socket for an alias, forcing the next
-- :JupynvimOpenRemote to re-authenticate.
function M.disconnect(alias)
  local profile = M.config.remote and M.config.remote[alias]
  if not profile then
    vim.notify("jupynvim: no remote profile '" .. tostring(alias) .. "'", vim.log.levels.ERROR)
    return
  end
  local cp = control_path(alias)
  if not cp then return end
  vim.fn.system({ "ssh", "-O", "exit", "-o", "ControlPath=" .. cp, profile.host })
  vim.fn.system({ "rm", "-f", cp })  -- always clean up file even if -O exit failed
  vim.notify("jupynvim: " .. alias .. " control socket closed")
end

-- Browse files on a remote alias and open the selected one.
--   .ipynb        → opened as a notebook through jupynvim
--   other files   → fetched via `ssh cat` into a read-only scratch buffer
--   directories   → recurse: re-invokes remote_browse on the picked dir
-- subpath defaults to "." (relative to your remote home).
--
-- For a real remote workspace (editable files, search, grep, write-back),
-- install distant.nvim alongside jupynvim. jupynvim's scope is notebooks.
function M.remote_browse(alias, subpath)
  local profile = M.config.remote and M.config.remote[alias]
  if not profile then
    vim.notify("jupynvim: no remote profile '" .. tostring(alias or "?") .. "'", vim.log.levels.ERROR)
    return
  end
  if not master_alive(alias, profile) then
    vim.notify("jupynvim: " .. alias .. " not connected; run :JupynvimConnect " .. alias .. " first",
               vim.log.levels.WARN)
    return
  end
  subpath = (subpath ~= nil and subpath ~= "") and subpath or "."
  local cp = control_path(alias)
  -- One level deep listing (entries with trailing / for dirs). Recurse via
  -- subsequent calls. Skips dotfiles. -L follows symlinks (so /jet/home links
  -- through to the actual storage).
  local list_cmd = string.format(
    "cd %s && ls -Ap | head -500",
    vim.fn.shellescape(subpath)
  )
  local cmd = { "ssh", "-T", "-o", "BatchMode=yes",
                "-o", "ControlPath=" .. cp, profile.host, list_cmd }
  local result = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    vim.notify("jupynvim: remote ls failed: " .. result, vim.log.levels.ERROR)
    return
  end
  local entries = { ".." }  -- parent always available
  for line in result:gmatch("[^\n]+") do table.insert(entries, line) end
  if #entries == 1 then
    vim.notify("jupynvim: empty directory on " .. alias .. ":" .. subpath)
    return
  end
  vim.ui.select(entries, {
    prompt = string.format("[%s] %s:", alias, subpath),
    format_item = function(e) return e end,
  }, function(choice)
    if not choice then return end
    local resolved
    if choice == ".." then
      -- naive parent: strip last component
      resolved = subpath:match("^(.+)/[^/]+/?$") or "."
    else
      resolved = (subpath == "." and choice or (subpath .. "/" .. choice))
      resolved = resolved:gsub("/+", "/"):gsub("/$", "")
    end
    if choice:sub(-1) == "/" or choice == ".." then
      -- directory: recurse
      vim.schedule(function() M.remote_browse(alias, resolved) end)
    elseif choice:sub(-6) == ".ipynb" then
      -- notebook: open via jupynvim
      M.use_remote(profile)
      M.open(resolved, { remote_label = alias })
    else
      -- other file: fetch read-only into a scratch buffer
      local cat_cmd = { "ssh", "-T", "-o", "BatchMode=yes",
                        "-o", "ControlPath=" .. cp, profile.host,
                        "cat " .. vim.fn.shellescape(resolved) }
      local body = vim.fn.system(cat_cmd)
      if vim.v.shell_error ~= 0 then
        vim.notify("jupynvim: cat failed: " .. body, vim.log.levels.ERROR)
        return
      end
      vim.cmd("enew")
      local buf = vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_set_name(buf, string.format("[%s]:%s", alias, resolved))
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(body, "\n", { plain = true }))
      vim.bo[buf].buftype = "nofile"
      vim.bo[buf].modifiable = false
      vim.bo[buf].readonly = true
      vim.bo[buf].swapfile = false
      -- Guess filetype from extension
      local ft = vim.filetype.match({ filename = resolved })
      if ft then vim.bo[buf].filetype = ft end
      vim.notify("[remote read-only] install distant.nvim for editing", vim.log.levels.INFO)
    end
  end)
end

-- Switch back to a local backend.
function M.use_local()
  if M.client and not M._remote_spec then return M.client end
  if M.client then
    pcall(function() M.client:stop() end)
    M.client = nil
  end
  M._remote_spec = nil
  return ensure_client()
end

-- Parse a remote-open spec.
--   "alias:relative/or/abs/path"   uses M.config.remote[alias]
--   "user@host:/abs/path"          one-off; alias name defaults to user@host
-- Returns { host, core_path, path, ssh_args, slurm } or nil + err.
function M._parse_remote_spec(s)
  if type(s) ~= "string" or s == "" then return nil, "empty spec" end
  local prefix, path = s:match("^([^:]+):(.+)$")
  if not prefix or not path then return nil, "expected `alias:path` or `user@host:/path`" end
  local profile = M.config.remote and M.config.remote[prefix]
  if profile then
    -- Copy the whole profile so any field (transport_cmd, custom keys) flows
    -- through to use_remote/build_ssh_cmd unchanged.
    local spec = vim.tbl_deep_extend("force", {}, profile)
    spec.host = profile.host or prefix
    spec.path = path
    spec.label = prefix
    return spec
  end
  -- Bare user@host:/path (no configured alias)
  return { host = prefix, path = path, label = prefix }
end

function M._handle_cell_event(p)
  if not p or not p.session_id then
    Log.warn("cell_event missing session_id: " .. vim.inspect(p):sub(1, 200))
    return
  end
  Log.debug("cell_event cell=" .. tostring(p.cell_id) .. " kind=" .. tostring(p.event and p.event.kind))
  for buf, nb in pairs(Notebook.all()) do
    if nb.session_id == p.session_id then
      nb:apply_cell_event(p.cell_id, p.event or {})
      -- Output events change cell.outputs but not buffer TEXT, so vim's
      -- "modified" flag stays false. That's why :wqa was a no-op after
      -- running a cell - vim skipped :w because the buffer looked
      -- unchanged. Mark modified so :w / :wqa trigger BufWriteCmd.
      local ek = p.event and p.event.kind
      if ek == "execute_input" or ek == "stream" or ek == "execute_result"
         or ek == "display_data" or ek == "error" or ek == "clear_output" then
        vim.schedule(function()
          if vim.api.nvim_buf_is_valid(buf) then
            vim.bo[buf].modified = true
          end
        end)
      end
      -- EAGER image transmission — must use the SAME renderer as the active
      -- config so the cache entry matches what render_cell expects.
      -- Prefer image/gif (animations) over image/png so display_data with
      -- both formats animates instead of showing a static frame.
      local ev = p.event or {}
      if ev.kind == "display_data" or ev.kind == "execute_result" then
        if ev.data then
          local b64, mime
          for _, m in ipairs({ "image/gif", "image/png", "image/jpeg" }) do
            local v = ev.data[m]
            if type(v) == "table" then v = table.concat(v, "") end
            if type(v) == "string" and v ~= "" then
              b64, mime = v, m
              break
            end
          end
          if b64 and Image.supported() then
            nb.image_ids = nb.image_ids or {}
            local renderer = M.config.image_renderer or "chafa"
            Image.ensure_transmitted(p.cell_id, b64, function(id)
              if id then
                nb.image_ids[p.cell_id] = id
                vim.schedule(function() Render.refresh(nb, vim.fn.bufwinid(buf)) end)
              end
            end, { renderer = renderer, mime = mime })
          end
        end
      end
      vim.schedule(function()
        Render.refresh(nb, vim.fn.bufwinid(buf))
      end)
      return
    end
  end
  Log.warn("no buf for session " .. tostring(p.session_id))
end

-- ---------- buffer lifecycle ----------

M._opening = M._opening or {}

-- Walk up from `start_dir` looking for a `.venv/bin/python` (or
-- `.venv/Scripts/python.exe` on Windows). Return the python path if the venv
-- exists AND ipykernel is importable from it. nil otherwise.
local function find_local_venv_python(start_dir)
  local is_win = package.config:sub(1, 1) == "\\"
  local rel = is_win and ".venv\\Scripts\\python.exe" or ".venv/bin/python"
  local dir = start_dir
  for _ = 1, 10 do
    local candidate = dir .. "/" .. rel
    if vim.fn.executable(candidate) == 1 then
      vim.fn.system({ candidate, "-c", "import ipykernel" })
      if vim.v.shell_error == 0 then return candidate end
      return nil  -- venv exists but no ipykernel - don't fall back silently
    end
    local parent = vim.fn.fnamemodify(dir, ":h")
    if parent == dir then break end
    dir = parent
  end
  return nil
end
M._find_local_venv_python = find_local_venv_python

function M.open(path, opts)
  opts = opts or {}
  ensure_client()
  local abs = vim.fn.fnamemodify(path, ":p")
  -- Clear stray direct placements left by file explorers (snacks.image
  -- previews .ipynb files and the placement survives past the explorer
  -- closing, overlaying our cell renders at the wrong size). We only
  -- clear visible placements, not image data, so kitty auto-re-creates
  -- our virtual placements from the buffer's placeholder chars on the
  -- next redraw and the gif animation isn't disturbed.
  pcall(function() Image.clear_visible_placements() end)

  -- Idempotency #1: if a notebook for this path is already alive AND we're not
  -- being asked to force-reload, just refocus and re-render.
  local existing_buf = vim.fn.bufnr(abs)
  if existing_buf > 0 then
    local existing_nb = Notebook.get(existing_buf)
    if existing_nb and not opts.force then
      vim.api.nvim_set_current_buf(existing_buf)
      Render.refresh(existing_nb, vim.api.nvim_get_current_win())
      return existing_buf
    end
  end

  -- Idempotency #2: re-entrancy guard. The first M.open is mid-flight
  -- (likely blocked in call_sync's vim.wait). A second BufReadCmd that fires
  -- during the wait must NOT touch the notebook the first call is building
  -- (including the force-tear-down path below — that would wipe the new nb
  -- before the outer call finishes).
  if M._opening[abs] then
    return existing_buf > 0 and existing_buf or nil
  end
  M._opening[abs] = true

  -- Force reload: tear down old session BEFORE creating new one. Safe to do
  -- now that the re-entrancy guard is set.
  if existing_buf > 0 then
    local existing_nb = Notebook.get(existing_buf)
    if existing_nb and opts.force then
      pcall(function()
        ensure_client():call("close", { session_id = existing_nb.session_id }, function() end)
      end)
      Notebook.remove(existing_buf)
      pcall(function() require("jupynvim.image").clear_all() end)
    end
  end

  -- Remote backends (SSH-spawned) take longer to first-respond because of
  -- ssh connect + scheduler attach (srun, etc) + binary startup. Bump to 30s
  -- so a slow PSC node doesn't time out before jupynvim-core is ready.
  local open_timeout = M._remote_spec and 30000 or 5000
  local err, result = M.client:call_sync("open", { path = abs }, open_timeout)
  if err then
    M._opening[abs] = nil
    vim.notify("jupynvim open failed: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  local sid = result.session_id
  local snap = result.snapshot

  -- Create or reuse the buffer
  local buf = vim.fn.bufnr(abs, true)
  vim.api.nvim_buf_set_name(buf, abs)
  -- acwrite forces :w through our BufWriteCmd. With "" Neovim sometimes
  -- falls through to native write that dumps the visible cell-rendered
  -- text to disk, breaking save. Neovim's vim.lsp.enable callback
  -- explicitly skips buftype != '' (runtime/lua/vim/lsp.lua: lsp_enable_callback)
  -- so we attach LSP manually below in M._attach_lsp.
  vim.api.nvim_set_option_value("buftype", "acwrite", { buf = buf })
  vim.api.nvim_buf_set_option(buf, "swapfile", false)
  vim.api.nvim_buf_set_option(buf, "modifiable", true)
  local ft = language_filetype(snap)
  vim.b[buf].jupynvim_filetype = ft

  local nb = Notebook.create(buf, abs, sid, snap)
  M._populate_buffer(nb)
  -- Snapshot the rendered buffer text as the "saved" baseline. TextChanged
  -- compares against this to decide whether to force modified=true. Without
  -- a baseline, an open with no edits would still flip modified on the
  -- first internal repaint that fires TextChanged.
  nb.saved_hash = vim.fn.sha256(
    table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
  -- Wipe undo history. BufReadCmd pre-populates the buffer with one empty
  -- placeholder line per on-disk json line so plugins like snacks picker
  -- can call nvim_win_set_cursor without "Cursor position outside buffer"
  -- errors. _populate_buffer then replaces those placeholders with the
  -- rendered cells. Both writes land in the undo history, so a fresh `u`
  -- after open jumps back to a buffer of N empty lines under one giant
  -- "Markdown" cell. Clearing undolevels (then restoring) discards the
  -- pre-edit history without affecting future edits.
  do
    local prev = vim.bo[buf].undolevels
    vim.bo[buf].undolevels = -1
    vim.api.nvim_buf_call(buf, function()
      vim.cmd('exe "normal! a \\<BS>\\<Esc>"')
    end)
    vim.bo[buf].undolevels = prev
    -- The no-op insert/backspace bumps `modified` even though buffer text is
    -- unchanged. Reset it so :q doesn't prompt to save on a freshly-opened
    -- file the user hasn't actually edited.
    vim.bo[buf].modified = false
  end
  -- Enable persistent undo so `u` works across nvim sessions. The undo file
  -- is keyed by the .ipynb absolute path; cell ids in the file are stable
  -- across opens, so replaying undo entries through replace_cells matches
  -- cells correctly. Vim's normal-load path auto-reads the undo file, but
  -- our BufReadCmd hijack bypasses that, so we rundo manually here.
  vim.bo[buf].undofile = true
  vim.api.nvim_buf_call(buf, function()
    local uf = vim.fn.undofile(abs)
    if uf ~= "" and vim.fn.filereadable(uf) == 1 then
      pcall(vim.cmd, "silent! rundo " .. vim.fn.fnameescape(uf))
    end
  end)
  M._attach_autocmds(buf)
  Keymaps.attach(buf, M)

  -- Display the buffer FIRST so we have a real window for the synchronous
  -- option-setting that follows. Without this, win_findbuf is empty and
  -- conceallevel doesn't get applied before the first redraw - which made
  -- the literal "# %%[jupynvim:cell-sep]" markers flash visible on open.
  vim.api.nvim_set_current_buf(buf)
  local cur_win = vim.api.nvim_get_current_win()

  -- Force a single window for the notebook buffer. Other plugins (LazyVim
  -- defaults, snacks.dashboard, neo-tree, etc.) sometimes auto-split on
  -- :edit, which makes cells appear duplicated.
  local wins = vim.fn.win_findbuf(buf)
  if #wins > 1 then
    for _, w in ipairs(wins) do
      if w ~= cur_win then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
  end

  -- Window options NOW (synchronously, while the buffer is displayed) so
  -- the conceal extmarks placed by _populate_buffer take effect on the
  -- very first redraw. Doing this in a scheduled callback caused a one-frame
  -- flash where the separator markers were visible.
  vim.api.nvim_win_call(cur_win, function()
    vim.cmd("setlocal signcolumn=no conceallevel=2 concealcursor=nc wrap linebreak breakindent breakindentopt=min:2 nofoldenable foldmethod=manual")
    vim.cmd([[setlocal showbreak=\ ]])
  end)
  -- Cursor to top of the rendered notebook. The BufReadCmd pre-populates
  -- the buffer with one placeholder line per on-disk json line so plugins
  -- like snacks picker can call nvim_win_set_cursor without "outside
  -- buffer" errors. After _populate_buffer replaces those placeholders
  -- with the shorter rendered content, the cursor would otherwise be
  -- stuck at a high line number and clamped to the last line, leaving
  -- the view scrolled down. Anchor at (1, 0) so we at least land on the
  -- first source line. The cell header `virt_lines_above` of line 1 is
  -- a known limitation - clipped above the window's top edge until the
  -- user scrolls up. Acceptable trade-off vs. a phantom-line refactor.
  pcall(vim.api.nvim_win_set_cursor, cur_win, { 1, 0 })

  -- Set filetype AFTER buffer display + window setup so FileType-driven
  -- plugins (treesitter, snippets, copilot) see a fully-prepared buffer.
  -- Setting `filetype` fires FileType, which in turn loads ftplugin/indent
  -- via Neovim's runtime autocmds. For buffers created via nvim_buf_set_lines
  -- (instead of `:edit`) the indent file occasionally doesn't get sourced —
  -- explicitly source it so `for i in range(...):<CR>` auto-indents.
  vim.bo[buf].filetype = ft
  vim.api.nvim_win_call(cur_win, function()
    pcall(vim.cmd, "runtime! ftplugin/" .. ft .. ".vim")
    pcall(vim.cmd, "runtime! ftplugin/" .. ft .. "/*.vim")
    pcall(vim.cmd, "runtime! indent/" .. ft .. ".vim")
    -- nvim-treesitter binds indentexpr to nvim_treesitter#indent() during
    -- FileType. That function consults the parse tree, which we
    -- periodically invalidate via set_included_regions, so Enter after `:`
    -- sometimes drops the indent until the tree re-parses. The runtime
    -- indent file's python#GetIndent is regex-based and doesn't depend on
    -- treesitter state, so re-asserting it here gives consistent autoindent.
    if ft == "python" then
      pcall(function() vim.bo[buf].indentexpr = "python#GetIndent(v:lnum)" end)
    end
  end)

  -- Look up the kernel python BEFORE LSP attaches so we can inject
  -- settings.python.pythonPath + analysis.extraPaths into the config.
  -- basedpyright doesn't execute the interpreter to discover sys.path - it
  -- probes the filesystem under <pythonPath>/../lib/.../site-packages. With
  -- Homebrew Python that path is empty (numpy actually lives at
  -- /opt/homebrew/lib/python3.14/site-packages). We run the kernel python
  -- once to harvest its real site-packages directories.
  local py_path
  local extra_paths = {}
  -- Auto-detected .venv takes precedence over registered kernelspec, since
  -- the user effectively asked for project-local environment by putting the
  -- notebook next to one. Falls through to kernelspec lookup otherwise.
  if M.config.auto_venv ~= false then
    local nb_dir = vim.fn.fnamemodify(abs, ":h")
    py_path = find_local_venv_python(nb_dir)
  end
  if not py_path then
    local kspec_name = (snap.metadata and snap.metadata.kernelspec and snap.metadata.kernelspec.name) or "python3"
    local kerr, kres = M.client:call_sync("list_kernels", {}, 2000)
    if not kerr and type(kres) == "table" then
      for _, k in ipairs(kres) do
        if k.name == kspec_name and k.argv and k.argv[1] then
          py_path = k.argv[1]
          break
        end
      end
    end
  end
  if py_path then
    local sys_path = vim.fn.system({ py_path, "-c", "import sys; print('\\n'.join(p for p in sys.path if p))" })
    if vim.v.shell_error == 0 then
      for line in sys_path:gmatch("[^\r\n]+") do
        if line:find("site%-packages") or line:find("dist%-packages") then
          table.insert(extra_paths, line)
        end
      end
    end
  end
  nb.kernel_python_path = py_path
  nb.kernel_extra_paths = extra_paths
  M._attach_lsp(buf, ft, py_path, extra_paths)
  -- Kernel-backed completion + hover via virtual LSP. Language-agnostic:
  -- the kernel's complete_request/inspect_request handle the actual work,
  -- so the same code path serves Python, Julia, R, anything with a kernel.
  pcall(function()
    require("jupynvim.kernel_lsp").attach(buf,
      function() return Notebook.get(buf) end,
      function() return M.client end)
  end)

  Render.refresh(nb, cur_win)
  M._opening[abs] = nil

  -- Auto-start kernel based on notebook metadata
  vim.defer_fn(function() M.start_kernel(buf) end, 50)
  return buf
end

function language_filetype(snap)
  local meta = snap.metadata or {}
  local kspec = meta.kernelspec or {}
  local lang = kspec.language or meta.language_info and meta.language_info.name
  if not lang then return "python" end
  -- Map known kernel languages to Neovim filetypes
  local map = { python = "python", julia = "julia", r = "r", javascript = "javascript", typescript = "typescript" }
  return map[lang:lower()] or "python"
end

-- Attach LSP clients manually. Two problems we work around here:
--
-- 1. Many LazyVim-style configs lazy-load nvim-lspconfig / mason-lspconfig on
--    `BufReadPre, BufNewFile`. But .ipynb opens go through our `BufReadCmd`
--    hijack, and Vim's "Cmd" events SUPPRESS BufReadPre, so the LSP plugin
--    never loads → vim.lsp._enabled_configs stays empty. We force-load it
--    via lazy.nvim's API.
--
-- 2. Even with configs registered, Neovim's own FileType callback for
--    vim.lsp.enable bails on `buftype ~= ''` (runtime/lua/vim/lsp.lua,
--    lsp_enable_callback). We need buftype='acwrite' for save hijack, so
--    we replicate the callback body (filetype filter + vim.lsp.start) but
--    skip the buftype guard.
function M._attach_lsp(buf, ft, py_path, extra_paths)
  -- Force-load any LSP plugins gated on BufReadPre that our BufReadCmd skipped.
  -- Only attempt plugins lazy.nvim actually knows about. Without the per-name
  -- check, lazy.load emits "Plugin X not found" notifications for users who
  -- don't have nvim-lspconfig / mason installed. (Reported in #6 by medwatt.)
  pcall(function()
    local ok_lazy, lazy = pcall(require, "lazy")
    if not ok_lazy then return end
    local known = require("lazy.core.config").plugins or {}
    local to_load = {}
    for _, name in ipairs({ "nvim-lspconfig", "mason-lspconfig.nvim", "mason.nvim" }) do
      if known[name] then table.insert(to_load, name) end
    end
    if #to_load > 0 then lazy.load({ plugins = to_load }) end
  end)
  -- Some setups also register configs by firing BufReadPre at FileType time.
  pcall(vim.api.nvim_exec_autocmds, "BufReadPre", { buffer = buf, modeline = false })

  local lsp = vim.lsp
  if not (lsp and lsp.config and lsp._enabled_configs) then
    pcall(vim.cmd, "LspStart")
    return
  end
  if not next(lsp._enabled_configs) then
    -- No configs registered yet — try once more after a short defer in case
    -- mason-lspconfig is still finishing its async registry refresh.
    vim.defer_fn(function()
      if vim.api.nvim_buf_is_valid(buf) then M._attach_lsp(buf, ft, py_path, extra_paths) end
    end, 200)
    return
  end
  -- LSP servers the user blocked from attaching to jupynvim buffers. ty,
  -- for example, treats `.ipynb` URIs as raw notebooks and emits a
  -- "Failed to read notebook ... isn't valid JSON" diagnostic on every
  -- buffer because our rendered cell view isn't JSON.
  local blocklist = {}
  for _, n in ipairs(M.config.lsp_blocklist or {}) do blocklist[n] = true end
  for name in pairs(lsp._enabled_configs) do
    if blocklist[name] then goto continue end
    local config = lsp.config[name]
    local ft_ok = config
      and (not config.filetypes or vim.tbl_contains(config.filetypes, ft))
    if ft_ok then
      local cfg = vim.deepcopy(config)
      -- Force Full sync ONLY for Python LSPs. The cleaned-text patch in
      -- jupynvim.lsp's _buf_get_full_text only blanks markdown for Python
      -- (basedpyright would otherwise parse markdown as code), and Full
      -- sync routes didChange through that patch. For Julia/R/etc. there's
      -- no cleaning to apply, and forcing Full sync can destabilise some
      -- servers (julials dies on startup with Full sync). Default to
      -- whatever sync the server announces.
      if name == "basedpyright" or name == "pyright" or name == "pylsp" or name == "ruff" then
        require("jupynvim.lsp").force_full_sync(cfg)
      end
      -- Inject the kernel's interpreter AND its real site-packages dirs.
      -- pythonPath alone is not enough for basedpyright because it probes
      -- <pythonPath>/../lib for site-packages instead of running the
      -- interpreter, and Homebrew Python's site-packages live elsewhere.
      if py_path and py_path ~= ""
         and (name == "basedpyright" or name == "pyright" or name == "pylsp" or name == "ruff") then
        cfg.settings = vim.tbl_deep_extend("force", cfg.settings or {}, {
          python = { pythonPath = py_path, analysis = { extraPaths = extra_paths or {} } },
          basedpyright = {
            python = { pythonPath = py_path },
            analysis = { extraPaths = extra_paths or {} },
          },
        })
        cfg.init_options = vim.tbl_deep_extend("force", cfg.init_options or {}, {
          settings = {
            python = { pythonPath = py_path },
            basedpyright = { analysis = { extraPaths = extra_paths or {} } },
          },
        })
      end
      -- For Mason's julials wrapper: the wrapper script hard-fails with
      -- "Usage: julia-lsp <julia-env-path>" when launched without an env
      -- path. nvim-lspconfig + mason-lspconfig set this via a before_init
      -- hook, but in our manual vim.lsp.start path before_init's mutation
      -- of cfg.cmd doesn't always reach the process spawn. Resolve the env
      -- path ourselves and set cfg.cmd directly so the spawn always sees it.
      if name == "julials" then
        if not cfg.julia_env_path then
          local home = vim.env.HOME or os.getenv("HOME")
          if home then
            local guess = home .. "/.julia/environments"
            local entries = vim.fn.glob(guess .. "/v*", true, true)
            table.sort(entries, function(a, b) return a > b end)  -- newest first
            if entries[1] and vim.fn.isdirectory(entries[1]) == 1 then
              cfg.julia_env_path = entries[1]
            end
          end
        end
        if cfg.julia_env_path then
          cfg.cmd = { "julia-lsp", vim.fn.expand(cfg.julia_env_path) }
        end
      end
      local opts = {
        bufnr = buf,
        -- Don't reuse a client that may have been started earlier for a .py
        -- buffer with a different pythonPath. Force a fresh client per
        -- jupynvim buffer so settings.python.pythonPath actually applies.
        reuse_client = py_path and function() return false end or cfg.reuse_client,
        _root_markers = cfg.root_markers,
      }
      -- Fallback root_dir for servers whose strict root_markers don't match.
      -- Mason's julia-lsp wrapper hard-fails without an env-path argument
      -- (which nvim-lspconfig builds from root_dir), so we'd see "Client
      -- julials quit with exit code 1" for any notebook outside a Julia
      -- project. Use the buffer's directory as a last resort so the LSP
      -- always has SOME root to work with. Only applies if the config didn't
      -- already specify a root_dir.
      local function resolve_root(root_dir)
        if not root_dir or root_dir == "" then
          local bufpath = vim.api.nvim_buf_get_name(buf)
          if bufpath ~= "" then
            root_dir = vim.fs.dirname(bufpath)
          end
        end
        return root_dir
      end
      local function start_with_log()
        local ok, res = pcall(lsp.start, cfg, opts)
        if not ok then
          vim.schedule(function()
            vim.notify(("jupynvim LSP %s: %s"):format(name, tostring(res)),
              vim.log.levels.WARN)
          end)
        end
      end
      if type(cfg.root_dir) == "function" then
        cfg.root_dir(buf, function(root_dir)
          cfg.root_dir = resolve_root(root_dir)
          vim.schedule(function()
            if vim.api.nvim_buf_is_valid(buf) then start_with_log() end
          end)
        end)
      else
        if not cfg.root_dir and cfg.root_markers then
          local found = vim.fs.root(buf, cfg.root_markers)
          cfg.root_dir = resolve_root(found)
        elseif not cfg.root_dir then
          cfg.root_dir = resolve_root(nil)
        end
        start_with_log()
      end
    end
    ::continue::
  end
end

function M._populate_buffer(nb)
  local lines = nb:to_lines()
  vim.api.nvim_buf_set_option(nb.buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(nb.buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(nb.buf, "modified", false)
  -- Pre-conceal cell separator marker lines synchronously, before the
  -- debounced Render.refresh runs. Without this, the literal
  -- "# %%[jupynvim:cell-sep]" text flashes visible on screen for one or
  -- two redraw frames between buffer population and the first render.
  local sep = require("jupynvim.notebook").CELL_SEP
  for i, line in ipairs(lines) do
    if line == sep then
      pcall(vim.api.nvim_buf_set_extmark, nb.buf, nb.border_ns, i - 1, 0, {
        end_col = #line,
        conceal = "",
        priority = 200,
      })
    end
  end
  -- wrap=true with linebreak + breakindent gives word-wrapped editing for
  -- long content. showbreak="│ " keeps the left border visible on every
  -- continuation row. Right border on continuation rows is a known gap.
  for _, win in ipairs(vim.fn.win_findbuf(nb.buf)) do
    vim.api.nvim_win_call(win, function()
      vim.cmd("setlocal signcolumn=no conceallevel=2 concealcursor=nc wrap linebreak breakindent breakindentopt=min:2 nofoldenable foldmethod=manual")
      vim.cmd([[setlocal showbreak=\ ]])
    end)
  end
  M._sync_treesitter_ranges(nb)
end

-- Restrict the treesitter Python parser to code-cell line ranges only.
-- Markdown cells contain words like "with both side bars" that the Python
-- parser tries to interpret as a `with` statement, which throws it into
-- error-recovery mode and corrupts highlighting in the next code cell
-- (the second `import` ends up captured as @variable.python instead of
-- @keyword.import.python). Treesitter's set_included_regions tells the
-- parser to ignore everything outside these byte ranges, so the Python
-- AST sees only code.
function M._sync_treesitter_ranges(nb)
  if not vim.treesitter then return end
  local ok, parser = pcall(vim.treesitter.get_parser, nb.buf, vim.bo[nb.buf].filetype)
  if not ok or not parser then return end
  local _, ranges = nb:to_lines()
  local lines = vim.api.nvim_buf_get_lines(nb.buf, 0, -1, false)
  local regions = {}
  for _, r in ipairs(ranges) do
    if r.type == "code" and r.start < #lines and r.stop > r.start then
      local last_row = math.min(r.stop - 1, #lines - 1)
      local start_byte = vim.api.nvim_buf_get_offset(nb.buf, r.start)
      local last_line = lines[last_row + 1] or ""
      local end_byte = vim.api.nvim_buf_get_offset(nb.buf, last_row) + #last_line
      table.insert(regions, {
        { r.start, 0, start_byte, last_row, #last_line, end_byte },
      })
    end
  end
  -- Skip set_included_regions when the cell structure (row boundaries)
  -- hasn't changed. Byte offsets shift on every keystroke, but treesitter's
  -- own incremental parser handles intra-line edits inside an existing
  -- region. Re-setting regions here would force a full tree invalidation
  -- on each keystroke, which races with indentexpr (treesitter indent
  -- returns -1 against an invalidated tree, so Enter after `:` falls back
  -- to plain autoindent). Compare row boundaries only.
  local row_sig = {}
  for i, region in ipairs(regions) do
    row_sig[i] = region[1][1] .. ":" .. region[1][4]
  end
  local sig = table.concat(row_sig, ",")
  if nb._ts_regions_sig == sig then return end
  nb._ts_regions_sig = sig
  pcall(parser.set_included_regions, parser, regions)
end

function M._attach_autocmds(buf)
  local group = vim.api.nvim_create_augroup("Jupynvim_" .. buf, { clear = true })

  -- Force window options + close duplicates whenever the notebook buf
  -- appears. Also reassert the kernel-language filetype if anything
  -- knocked it back to json (Neovim's default for .ipynb).
  vim.api.nvim_create_autocmd({ "BufWinEnter", "WinNew", "WinEnter", "BufEnter" }, {
    group = group, buffer = buf,
    callback = function()
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(buf) then return end
        local want_ft = vim.b[buf].jupynvim_filetype or "python"
        if vim.bo[buf].filetype ~= want_ft then
          vim.bo[buf].filetype = want_ft
        end
        -- Re-assert vim's regex-based indent so nvim-treesitter's
        -- FileType handler (which fires when filetype is set) doesn't
        -- silently rebind indentexpr to its parse-tree-dependent version.
        if want_ft == "python" then
          pcall(function() vim.bo[buf].indentexpr = "python#GetIndent(v:lnum)" end)
        end
        local wins = vim.fn.win_findbuf(buf)
        for _, win in ipairs(wins) do
          vim.api.nvim_win_call(win, function()
            vim.cmd("setlocal signcolumn=no conceallevel=2 concealcursor=nc wrap linebreak breakindent breakindentopt=min:2 nofoldenable foldmethod=manual")
            vim.cmd([[setlocal showbreak=\ ]])
          end)
        end
        if #wins > 1 then
          for i = 2, #wins do
            pcall(vim.api.nvim_win_close, wins[i], true)
          end
        end
      end)
    end,
  })

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group, buffer = buf,
    callback = function()
      local nb = Notebook.get(buf)
      if not nb then return end
      M._save(nb)
    end,
  })
  -- LSP may attach after the kernel started (timing depends on lazy
  -- loading). If so, the start_kernel didChangeConfiguration call missed
  -- this client - re-push the kernel's pythonPath now.
  vim.api.nvim_create_autocmd("LspAttach", {
    group = group, buffer = buf,
    callback = function(args)
      -- Defensively detach blocklisted LSPs. Our manual attach path skips
      -- them, but other paths (LazyVim auto-attach, FileType handlers)
      -- might still attach them, so catch them here too.
      local blocklist = {}
      for _, n in ipairs(M.config.lsp_blocklist or {}) do blocklist[n] = true end
      local client = vim.lsp.get_client_by_id(args.data.client_id)
      if client and blocklist[client.name] then
        pcall(vim.lsp.buf_detach_client, args.buf, args.data.client_id)
        return
      end
      local nb = Notebook.get(buf)
      -- For clients that advertise notebookDocumentSync (ty etc.), send
      -- the LSP notebook protocol's didOpen so they receive proper cell
      -- structure instead of choking on our rendered-cell textDocument view.
      if nb and client then
        pcall(function()
          require("jupynvim.notebook_lsp").on_attach(buf, nb, client)
        end)
      end
      if nb and nb.kernel_python_path then
        vim.schedule(function()
          M._sync_lsp_python_path(buf, nb.kernel_python_path, nb.kernel_extra_paths)
        end)
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group, buffer = buf,
    callback = function()
      local nb = Notebook.get(buf)
      if not nb then return end
      -- Mark the buffer modified IF the current text actually differs from
      -- the last-saved state. Vim's automatic modified tracking depends on a
      -- saved-tick reference that we never update because BufWriteCmd
      -- bypasses the normal :w path - after `u` to revert previous-session
      -- edits, vim sometimes leaves modified=false even though the buffer
      -- differs from on-disk content, so :wqa would skip the buffer.
      -- Comparing against saved_hash fixes that without falsely flagging
      -- the buffer as modified on internal repaint events (rundo,
      -- treesitter region updates, etc.) that fire TextChanged but don't
      -- actually change visible text.
      if nb.saved_hash then
        local current = vim.fn.sha256(
          table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
        if current ~= nb.saved_hash then
          pcall(vim.api.nvim_buf_set_option, buf, "modified", true)
        end
      end
      -- Sync cell.source from buffer so render's content-driven filters
      -- (e.g., markdown image placeholder presence) reflect undo/redo
      -- restoring text. Without this, `u` brings the line back visually
      -- but cell.source still says it's gone, so the gif never re-renders.
      nb:sync_from_buffer()
      -- If the user pasted a `data:image/...;base64,...` URI into a markdown
      -- cell, replace it with a short `jupynvim-img:N` placeholder and stash
      -- the originals so render can transmit + animate the image. Without
      -- this, the giant base64 stays inline in the buffer (laggy) and the
      -- image never displays until reopen.
      local Embedded = require("jupynvim.embedded")
      local needs_repop = false
      for _, c in ipairs(nb.cells) do
        -- Only repop when preprocess_incremental ACTUALLY rewrites the
        -- source (i.e. found a real `![alt](data:image/...;base64,...)` URI
        -- that needs replacing with a placeholder). Just having the literal
        -- string "data:image" inside descriptive text or fenced code does
        -- not require a repop. _populate_buffer resets modified=false, so
        -- spurious repops silently throw away the user's pending changes
        -- when :qa or :wqa runs next.
        if c.cell_type == "markdown" and c.source and c.source:find("data:image", 1, true) then
          local before = c.source
          local after = Embedded.preprocess_incremental(c.id, c.source)
          if after ~= before then
            c.source = after
            needs_repop = true
          end
        end
      end
      if needs_repop then
        local cur = vim.api.nvim_win_get_cursor(0)
        M._populate_buffer(nb)
        pcall(vim.api.nvim_win_set_cursor, 0,
          { math.min(cur[1], vim.api.nvim_buf_line_count(buf)), cur[2] })
        -- We just rewrote the buffer to swap a pasted data:URI with the
        -- short placeholder; that's a real edit, not a no-op. Keep the
        -- modified flag set so :wqa actually triggers BufWriteCmd.
        pcall(vim.api.nvim_buf_set_option, buf, "modified", true)
      end
      Render.refresh(nb, vim.fn.bufwinid(buf))
      M._sync_treesitter_ranges(nb)
      -- Push cell-array diff to notebook-aware LSPs (ty etc.).
      pcall(function() require("jupynvim.notebook_lsp").on_text_change(buf, nb) end)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group, buffer = buf,
    callback = function()
      local nb = Notebook.get(buf)
      if nb and nb.session_id then
        ensure_client():call("close", { session_id = nb.session_id }, function() end)
      end
      pcall(function() require("jupynvim.notebook_lsp").on_close(buf) end)
      Notebook.remove(buf)
      pcall(Image.delete_all)
    end,
  })
  -- Refresh borders whenever window dimensions or buffer focus changes —
  -- width is computed from the active window, so cells need re-rendering
  -- when switching between buffers/windows or resizing.
  vim.api.nvim_create_autocmd({ "WinResized", "VimResized", "BufWinEnter", "BufEnter", "WinEnter" }, {
    group = group, buffer = buf,
    callback = function()
      local nb = Notebook.get(buf)
      if not nb then return end
      vim.schedule(function() Render.refresh(nb, vim.fn.bufwinid(buf)) end)
    end,
  })
  -- Note: we do NOT re-place images on scroll. With Ghostty 1.3 the placement
  -- escape interleaves with Neovim's own TUI writes, causing the image to land
  -- at unpredictable screen positions on every re-draw. Placing once at run
  -- time is the cleanest behavior until Ghostty fully implements Unicode
  -- placeholder mode (which lets the image stick to buffer text).
end

function M._save(nb)
  nb:sync_from_buffer()
  local cl = ensure_client()
  local Embedded = require("jupynvim.embedded")
  local incoming = {}
  for _, c in ipairs(nb.cells) do
    local src = c.source or ""
    if c.cell_type == "markdown" then
      src = Embedded.postprocess(c.id, src)
    end
    table.insert(incoming, {
      id = c.id,
      cell_type = c.cell_type or "code",
      source = src,
    })
  end
  -- Synchronous RPC. BufWriteCmd has to block until the on-disk file is
  -- actually written; if we return early, :wqa quits before the save
  -- completes and the file is left in whatever state was before this
  -- write, which is what was making :wqa appear to drop changes.
  local rerr, rres = cl:call_sync("replace_cells",
    { session_id = nb.session_id, cells = incoming }, 5000)
  if rerr then
    vim.notify("replace_cells failed: " .. tostring(rerr), vim.log.levels.ERROR)
    return
  end
  if rres and rres.ids then
    for i, new_id in ipairs(rres.ids) do
      if nb.cells[i] then nb.cells[i].id = new_id end
    end
  end
  local serr = cl:call_sync("save", { session_id = nb.session_id }, 5000)
  if serr then
    vim.notify("save failed: " .. tostring(serr), vim.log.levels.ERROR)
    return
  end
  if vim.api.nvim_buf_is_valid(nb.buf) then
    vim.api.nvim_buf_set_option(nb.buf, "modified", false)
    -- Refresh the saved-state hash so subsequent TextChanged checks compare
    -- against the post-save buffer text, not the pre-save one.
    nb.saved_hash = vim.fn.sha256(
      table.concat(vim.api.nvim_buf_get_lines(nb.buf, 0, -1, false), "\n"))
    -- Persist undo history to disk. Vim's normal :w would do this for any
    -- buffer with undofile=true, but our BufWriteCmd handles save manually
    -- via the backend, bypassing vim's write path. Call wundo so subsequent
    -- session opens can rundo and restore undo across the gap.
    if vim.bo[nb.buf].undofile then
      vim.api.nvim_buf_call(nb.buf, function()
        local uf = vim.fn.undofile(nb.path)
        if uf ~= "" then
          pcall(vim.cmd, "silent! wundo! " .. vim.fn.fnameescape(uf))
        end
      end)
    end
  end
end

-- ---------- public API (called by keymaps) ----------

function M.run_cell(buf, opts)
  opts = opts or {}
  local nb = Notebook.get(buf)
  if not nb then return end
  nb:sync_from_buffer()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local cell_id, range = nb:cell_at_line(lnum)
  if not cell_id then return end
  local cell = nb:get_cell(cell_id)
  -- Push current source to backend, then execute
  local cl = ensure_client()
  cl:call("update_cell_source", { session_id = nb.session_id, cell_id = cell.id, source = cell.source }, function(err)
    if err then
      vim.notify("update_cell_source: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    -- For markdown cells, just re-render
    if cell.cell_type == "markdown" then
      vim.schedule(function() Render.refresh(nb, vim.fn.bufwinid(buf)) end)
      if opts.advance then M.jump_cell(buf, 1) end
      return
    end
    cl:call("execute", { session_id = nb.session_id, cell_id = cell.id }, function(err2)
      if err2 then
        vim.notify("execute: " .. tostring(err2), vim.log.levels.ERROR)
      end
    end)
    if opts.advance then
      vim.schedule(function() M.jump_cell(buf, 1, true) end)
    end
  end)
end

function M.run_all(buf)
  local nb = Notebook.get(buf)
  if not nb then return end
  nb:sync_from_buffer()
  -- Sequence cells: each one's execute fires only after the previous update + execute have completed
  local cl = ensure_client()
  local code_cells = {}
  for _, c in ipairs(nb.cells) do
    if c.cell_type == "code" then table.insert(code_cells, c) end
  end
  local i = 1
  local function step()
    if i > #code_cells then return end
    local c = code_cells[i]; i = i + 1
    cl:call("update_cell_source", { session_id = nb.session_id, cell_id = c.id, source = c.source }, function()
      cl:call("execute", { session_id = nb.session_id, cell_id = c.id }, function()
        step()
      end)
    end)
  end
  step()
end

function M.run_above(buf)
  local nb = Notebook.get(buf)
  if not nb then return end
  nb:sync_from_buffer()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local cur_id = nb:cell_at_line(lnum)
  for _, c in ipairs(nb.cells) do
    if c.id == cur_id then break end
    if c.cell_type == "code" then
      local cl = ensure_client()
      cl:call("update_cell_source", { session_id = nb.session_id, cell_id = c.id, source = c.source }, function() end)
      cl:call("execute", { session_id = nb.session_id, cell_id = c.id }, function() end)
    end
  end
end

function M.run_below(buf)
  local nb = Notebook.get(buf)
  if not nb then return end
  nb:sync_from_buffer()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local cur_id = nb:cell_at_line(lnum)
  local seen = false
  for _, c in ipairs(nb.cells) do
    if c.id == cur_id then seen = true end
    if seen and c.cell_type == "code" then
      local cl = ensure_client()
      cl:call("update_cell_source", { session_id = nb.session_id, cell_id = c.id, source = c.source }, function() end)
      cl:call("execute", { session_id = nb.session_id, cell_id = c.id }, function() end)
    end
  end
end

function M.add_cell(buf, where)
  local nb = Notebook.get(buf)
  if not nb then return end
  nb:sync_from_buffer()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local cur_id, range = nb:cell_at_line(lnum)
  local _, cur_idx = nb:get_cell(cur_id)
  local insert_at  -- 0-based after_index
  if where == "above" then
    insert_at = (cur_idx or 1) - 2  -- after the previous cell
    if insert_at < -1 then insert_at = -1 end
  else
    insert_at = (cur_idx or 1) - 1
  end

  local cl = ensure_client()
  cl:call("insert_cell", { session_id = nb.session_id, after_index = insert_at, cell_type = "code" }, function(err, res)
    if err then vim.notify("insert: " .. tostring(err), vim.log.levels.ERROR); return end
    -- Insert into local cells
    table.insert(nb.cells, insert_at + 2, { id = res.cell_id, cell_type = "code", source = "", outputs = {} })
    M._populate_buffer(nb)
    Render.refresh(nb, vim.fn.bufwinid(buf))
    -- Move cursor into the new cell
    local _, ranges = nb:to_lines()
    local r = ranges[insert_at + 2]
    if r then vim.api.nvim_win_set_cursor(vim.fn.bufwinid(buf), { r.start + 1, 0 }) end
  end)
end

function M.delete_cell(buf)
  local nb = Notebook.get(buf)
  if not nb then return end
  nb:sync_from_buffer()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local cur_id = nb:cell_at_line(lnum)
  if not cur_id then return end
  local cl = ensure_client()
  cl:call("delete_cell", { session_id = nb.session_id, cell_id = cur_id }, function(err)
    if err then vim.notify("delete: " .. tostring(err), vim.log.levels.ERROR); return end
    -- Remove locally
    for i, c in ipairs(nb.cells) do
      if c.id == cur_id then table.remove(nb.cells, i); break end
    end
    if #nb.cells == 0 then
      cl:call("insert_cell", { session_id = nb.session_id, after_index = -1, cell_type = "code" }, function(_, res)
        if res then table.insert(nb.cells, { id = res.cell_id, cell_type = "code", source = "", outputs = {} }) end
        M._populate_buffer(nb)
        Render.refresh(nb, vim.fn.bufwinid(buf))
      end)
    else
      M._populate_buffer(nb)
      Render.refresh(nb, vim.fn.bufwinid(buf))
    end
  end)
end

function M.move_cell(buf, delta)
  local nb = Notebook.get(buf)
  if not nb then return end
  nb:sync_from_buffer()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local cur_id = nb:cell_at_line(lnum)
  if not cur_id then return end
  local cl = ensure_client()
  cl:call("move_cell", { session_id = nb.session_id, cell_id = cur_id, delta = delta }, function(err, res)
    if err then vim.notify("move: " .. tostring(err), vim.log.levels.ERROR); return end
    -- Apply locally
    local idx
    for i, c in ipairs(nb.cells) do if c.id == cur_id then idx = i; break end end
    if not idx then return end
    local new_idx = math.max(1, math.min(#nb.cells, idx + delta))
    local cell = table.remove(nb.cells, idx)
    table.insert(nb.cells, new_idx, cell)
    M._populate_buffer(nb)
    Render.refresh(nb, vim.fn.bufwinid(buf))
  end)
end

function M.set_cell_type(buf, t)
  local nb = Notebook.get(buf)
  if not nb then return end
  nb:sync_from_buffer()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local cur_id = nb:cell_at_line(lnum)
  if not cur_id then return end
  local cell = nb:get_cell(cur_id)
  if not cell then return end
  if cell.cell_type == t then return end
  -- Update local state synchronously. Doing this in the RPC callback meant a
  -- :w fired immediately after <leader>nm raced the callback and saved the
  -- old type. Buffer text doesn't change so we also have to flip `modified`
  -- by hand or :wqa skips the buffer entirely.
  cell.cell_type = t
  if t ~= "code" then cell.outputs = {}; cell.execution_count = nil end
  pcall(vim.api.nvim_buf_set_option, buf, "modified", true)
  M._sync_treesitter_ranges(nb)
  Render.refresh(nb, vim.fn.bufwinid(buf))
  -- LSPs aren't notified of cell-type changes (no didChange fires - the
  -- buffer text is unchanged), so any diagnostics they published while the
  -- cell was code remain in the diagnostic store and stay visible on the
  -- now-markdown lines. Re-call show() so our diag.filter runs against the
  -- updated cell types and the stale diagnostics get hidden.
  vim.schedule(function()
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.diagnostic.show, nil, buf)
    end
  end)
  -- Backend sync as a side effect. _save's replace_cells already propagates
  -- the type on next save, so this is mostly to keep the in-memory backend
  -- model consistent for read-side RPCs (kernel completion, debug dumps).
  local cl = ensure_client()
  cl:call("set_cell_type", { session_id = nb.session_id, cell_id = cur_id, cell_type = t }, function(err)
    if err then
      vim.notify("set_cell_type backend sync failed: " .. tostring(err), vim.log.levels.WARN)
    end
  end)
end

-- Push a python interpreter path to any pyright/basedpyright/pylsp clients
-- attached to this buffer. Without this, basedpyright uses its bundled
-- interpreter (no numpy / no project deps) and shows spurious
-- "Import 'numpy' could not be resolved" diagnostics on every notebook.
function M._sync_lsp_python_path(buf, py_path, extra_paths)
  if not py_path or py_path == "" then return end
  extra_paths = extra_paths or {}
  local clients = vim.lsp.get_clients({ bufnr = buf })
  for _, client in ipairs(clients) do
    local n = client.name or ""
    if n == "basedpyright" or n == "pyright" or n == "pylsp" or n == "ruff" then
      client.settings = vim.tbl_deep_extend("force", client.settings or {}, {
        python = { pythonPath = py_path, analysis = { extraPaths = extra_paths } },
        basedpyright = {
          python = { pythonPath = py_path },
          analysis = { extraPaths = extra_paths },
        },
      })
      -- Per LSP spec, settings=null tells the server to re-fetch via
      -- workspace/configuration. Sending the settings inline doesn't always
      -- trigger basedpyright's module-resolution refresh - lspconfig's own
      -- :LspPyrightSetPythonPath command uses settings=nil for this reason.
      pcall(client.notify, client, "workspace/didChangeConfiguration", { settings = vim.NIL })
    end
  end
end

function M.start_kernel(buf, kernel_name)
  local nb = Notebook.get(buf)
  if not nb then return end
  -- Don't auto-restart if a kernel is already running for this notebook.
  -- The auto-start in M.open could otherwise run multiple times (e.g.
  -- BufReadCmd re-firing) and orphan ipykernel processes.
  if nb.kernel_started and not kernel_name then return end
  local cl = ensure_client()
  -- Auto-detect a local .venv near the notebook and use its python directly,
  -- bypassing the global kernelspec registry. Only on auto-start (no
  -- explicit kernel_name) so users picking via `<leader>nK` aren't
  -- overridden. Disable with `auto_venv = false` in setup.
  local python_path = nil
  if not kernel_name and M.config.auto_venv ~= false then
    local nb_dir = nb.path and vim.fn.fnamemodify(nb.path, ":h") or nil
    if nb_dir then
      python_path = find_local_venv_python(nb_dir)
      if python_path then
        Log.info("auto_venv: using " .. python_path)
      end
    end
  end
  cl:call("start_kernel", {
    session_id = nb.session_id,
    kernel_name = kernel_name,
    python_path = python_path,
  }, function(err, res)
    if err then
      vim.notify("start_kernel: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    nb.kernel_started = true
    vim.notify("jupynvim: kernel '" .. (res.kernel_name or "?") .. "' started", vim.log.levels.INFO)
    -- Auto-inject inline plotting magic for python kernels (silent — no output)
    local lang = (nb.notebook_meta and nb.notebook_meta.language) or "python"
    if (res.kernel_name or ""):lower():find("python") or lang == "python" then
      cl:call("execute_silent", {
        session_id = nb.session_id,
        code = "try:\n    get_ipython().run_line_magic('matplotlib', 'inline')\nexcept Exception:\n    pass\n",
      }, function() end)
    end
    -- Tell the LSP about the kernel's interpreter so import resolution
    -- matches what `pip list` in that env reports.
    cl:call("list_kernels", {}, function(_, kernels)
      if not kernels then return end
      local active = res.kernel_name
      for _, k in ipairs(kernels) do
        -- argv is typically ["/path/to/python", "-m", "ipykernel_launcher", ...]
        -- Lua's 1-based indexing -> argv[1] is the python interpreter.
        if k.name == active and k.argv and k.argv[1] then
          local py = k.argv[1]
          nb.kernel_python_path = py
          local sp = vim.fn.system({ py, "-c", "import sys; print('\\n'.join(p for p in sys.path if p))" })
          local extra = {}
          if vim.v.shell_error == 0 then
            for line in sp:gmatch("[^\r\n]+") do
              if line:find("site%-packages") or line:find("dist%-packages") then
                table.insert(extra, line)
              end
            end
          end
          nb.kernel_extra_paths = extra
          vim.schedule(function()
            M._sync_lsp_python_path(buf, py, extra)
          end)
          return
        end
      end
    end)
    Render.refresh(nb, vim.fn.bufwinid(buf))
  end)
end

function M.stop_kernel(buf)
  local nb = Notebook.get(buf)
  if not nb then return end
  nb.kernel_started = false
  ensure_client():call("stop_kernel", { session_id = nb.session_id }, function() end)
end

function M.interrupt_kernel(buf)
  local nb = Notebook.get(buf)
  if not nb then return end
  ensure_client():call("interrupt_kernel", { session_id = nb.session_id }, function() end)
end

-- Clear outputs and execution_count from every CODE cell in the notebook.
-- Markdown cells (and their embedded images) are left untouched. Mirrors
-- `jupyter nbconvert --clear-output --inplace`.
function M.clear_outputs(buf)
  local nb = Notebook.get(buf)
  if not nb then return end
  local Image = require("jupynvim.image")
  nb.image_ids = nb.image_ids or {}
  for _, c in ipairs(nb.cells) do
    if c.cell_type == "code" then
      c.outputs = {}
      c.execution_count = nil
      nb.cell_state[c.id] = nil
      -- Drop only code-cell image placements; markdown embedded images
      -- (keys like "<id>_md_<idx>") stay so the cell still renders them.
      pcall(Image.clear_for_cell, c.id)
      nb.image_ids[c.id] = nil
    end
  end
  -- Refresh immediately so the user sees execution badges and outputs
  -- reset even if the backend RPC is missing (older binary). The backend
  -- call is best-effort; on success the on-disk state will match too.
  Render.refresh(nb, vim.fn.bufwinid(buf))
  -- Mark buffer modified so :w / :wqa actually trigger BufWriteCmd.
  vim.bo[buf].modified = true
  ensure_client():call("clear_outputs", { session_id = nb.session_id }, function(err)
    if err then
      vim.schedule(function()
        vim.notify(
          "jupynvim: backend doesn't support clear_outputs yet — rebuild with `cargo build --release`",
          vim.log.levels.WARN)
      end)
    end
  end)
end

-- Clear outputs of just the cell under the cursor.
function M.clear_cell_output(buf)
  local nb = Notebook.get(buf)
  if not nb then return end
  nb:sync_from_buffer()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local cell_id = nb:cell_at_line(lnum)
  if not cell_id then return end
  local cell = nb:get_cell(cell_id)
  if not cell or cell.cell_type ~= "code" then
    vim.notify("jupynvim: not a code cell", vim.log.levels.INFO)
    return
  end
  cell.outputs = {}
  cell.execution_count = nil
  nb.cell_state[cell.id] = nil
  pcall(require("jupynvim.image").clear_for_cell, cell.id)
  nb.image_ids = nb.image_ids or {}
  nb.image_ids[cell.id] = nil
  Render.refresh(nb, vim.fn.bufwinid(buf))
  vim.bo[buf].modified = true
  ensure_client():call("clear_cell_output",
    { session_id = nb.session_id, cell_id = cell.id }, function(err)
    if err then
      vim.schedule(function()
        vim.notify(
          "jupynvim: backend doesn't support clear_cell_output yet — rebuild with `cargo build --release`",
          vim.log.levels.WARN)
      end)
    end
  end)
end

function M.restart_kernel(buf)
  local nb = Notebook.get(buf)
  if not nb then return end
  ensure_client():call("restart_kernel", { session_id = nb.session_id }, function(err, res)
    if err then vim.notify("restart: " .. tostring(err), vim.log.levels.ERROR); return end
    vim.notify("jupynvim: kernel restarted", vim.log.levels.INFO)
  end)
end

-- Delete an embedded image (gif/png/jpeg) from the markdown cell under the
-- cursor. The buffer holds short placeholders like `![alt](jupynvim-img:N)`,
-- so removing the image is just a matter of dropping that line and re-syncing
-- the cell source. On save, postprocess() won't find the placeholder and
-- the original base64 data drops out of the .ipynb on disk.
function M.delete_image(buf)
  local nb = Notebook.get(buf)
  if not nb then return end
  nb:sync_from_buffer()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local cell_id = nb:cell_at_line(lnum)
  if not cell_id then return end
  local cell = nb:get_cell(cell_id)
  if not cell or cell.cell_type ~= "markdown" then
    vim.notify("jupynvim: not a markdown cell", vim.log.levels.INFO)
    return
  end
  local Embedded = require("jupynvim.embedded")
  local imgs = Embedded.list_images(cell.id) or {}
  if #imgs == 0 then
    vim.notify("jupynvim: no embedded image in this cell", vim.log.levels.INFO)
    return
  end

  local function drop(idx)
    -- Only remove the placeholder line from the buffer / cell.source.
    -- Leave the side-table entry in place so `u` (undo) restores the line
    -- AND the image data, both. postprocess() is idempotent: if the
    -- placeholder isn't in the source on save, the data is dropped from
    -- the .ipynb; if it's there (after undo), the data is restored.
    local pat = "%!%[[^%]]*%]%(jupynvim%-img:" .. idx .. "%)\n?"
    cell.source = (cell.source or ""):gsub(pat, "", 1)
    pcall(require("jupynvim.image").clear_for_cell, cell.id)
    M._populate_buffer(nb)
    Render.refresh(nb, vim.fn.bufwinid(buf))
    vim.bo[buf].modified = true
    vim.notify("jupynvim: deleted image " .. idx .. " (undo with `u` to restore)",
      vim.log.levels.INFO)
  end

  if #imgs == 1 then
    drop(imgs[1].idx)
    return
  end
  vim.ui.select(imgs, {
    prompt = "Delete which image?",
    format_item = function(im)
      return string.format("[%d] %s (%s)", im.idx, im.alt ~= "" and im.alt or "(no alt)", im.mime)
    end,
  }, function(choice) if choice then drop(choice.idx) end end)
end

function M.kernel_picker(buf)
  ensure_client():call("list_kernels", {}, function(err, kernels)
    if err then vim.notify("list_kernels: " .. err, vim.log.levels.ERROR); return end
    vim.ui.select(kernels, {
      prompt = "Select kernel:",
      format_item = function(k) return k.display_name .. "  (" .. k.name .. ")" end,
    }, function(choice)
      if not choice then return end
      M.stop_kernel(buf)
      vim.defer_fn(function() M.start_kernel(buf, choice.name) end, 200)
    end)
  end)
end

-- Internal helper: open the given cell's output as a scratch split.
local function _open_output_split(buf, cell, origin_line)
  local function as_str(v)
    if type(v) == "table" then return table.concat(v, "") end
    if type(v) == "string" then return v end
    return ""
  end
  local function strip_ansi(s)
    s = s:gsub("\27%[[?]?[%d;]*[a-zA-Z]", "")
    s = s:gsub("\27%][^\27]*\27\\", "")
    s = s:gsub("\27.", "")
    return s
  end
  -- Apply tqdm/progress-bar carriage-return semantics: \r overwrites the
  -- current line, so only the LAST \r-terminated chunk per logical line
  -- survives. Without this, the scratch split shows every intermediate
  -- progress-bar tick as its own line (the inline view already applies
  -- this in render.lua's process_cr).
  local function process_cr(s)
    local out = {}
    for chunk in (s .. "\n"):gmatch("([^\n]*)\n") do
      local segments = {}
      for seg in (chunk .. "\r"):gmatch("([^\r]*)\r") do
        table.insert(segments, seg)
      end
      table.insert(out, segments[#segments] or "")
    end
    if out[#out] == "" then table.remove(out) end
    return table.concat(out, "\n")
  end

  local lines = {}
  for _, o in ipairs(cell.outputs) do
    if o.output_type == "stream" then
      local txt = strip_ansi(process_cr(as_str(o.text)))
      for line in (txt .. "\n"):gmatch("([^\n]*)\n") do
        table.insert(lines, line)
      end
    elseif o.output_type == "execute_result" or o.output_type == "display_data" then
      local data = o.data or {}
      local txt = as_str(data["text/plain"])
      if txt ~= "" then
        for line in (txt .. "\n"):gmatch("([^\n]*)\n") do
          table.insert(lines, line)
        end
      end
      if data["image/png"] then
        table.insert(lines, "[image/png — view in main notebook]")
      end
    elseif o.output_type == "error" then
      table.insert(lines, as_str(o.ename) .. ": " .. as_str(o.evalue))
      for _, tb in ipairs(o.traceback or {}) do
        local txt = strip_ansi(process_cr(as_str(tb)))
        for line in (txt .. "\n"):gmatch("([^\n]*)\n") do
          table.insert(lines, line)
        end
      end
    end
  end
  if lines[#lines] == "" then table.remove(lines) end
  if #lines == 0 then
    vim.notify("jupynvim: output has no text content", vim.log.levels.INFO)
    return
  end

  local scratch = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(scratch, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = scratch })
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = scratch })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = scratch })
  vim.api.nvim_set_option_value("filetype", "jupynvim_output", { buf = scratch })
  vim.b[scratch].jupynvim_origin_buf = buf
  vim.b[scratch].jupynvim_origin_line = origin_line
  vim.api.nvim_buf_set_name(scratch,
    string.format("jupynvim://Out[%s]", tostring(cell.execution_count or "?")))

  local height = math.min(math.max(#lines, 4), math.floor(vim.o.lines * 0.4))
  vim.cmd("belowright " .. height .. "split")
  vim.api.nvim_set_current_buf(scratch)

  local close_map = function()
    local origin_buf = vim.b.jupynvim_origin_buf
    local origin_l = vim.b.jupynvim_origin_line
    vim.cmd("close")
    for _, w in ipairs(vim.fn.win_findbuf(origin_buf)) do
      vim.api.nvim_set_current_win(w)
      if origin_l then
        pcall(vim.api.nvim_win_set_cursor, w, { origin_l, 0 })
      end
      return
    end
  end
  vim.keymap.set("n", "<C-j>", close_map, { buffer = scratch, silent = true, desc = "Leave output" })
  vim.keymap.set("n", "<C-k>", close_map, { buffer = scratch, silent = true, desc = "Leave output" })
  vim.keymap.set("n", "q",     close_map, { buffer = scratch, silent = true, desc = "Leave output" })
end

local function _has_output(cell)
  return cell and cell.cell_type == "code" and cell.outputs and #cell.outputs > 0
end

-- <C-j>: enter the current cell's output (or the NEXT cell's output if
-- the current cell has none). <C-k>: enter the PREVIOUS cell's output
-- so when the cursor is below an output region, this key enters that
-- region. From inside the scratch split, either key (or q) returns.
function M.enter_output(buf, direction)
  -- Already inside a jupynvim output scratch? Close and return.
  local ok, _ = pcall(vim.api.nvim_buf_get_var, buf, "jupynvim_origin_buf")
  if ok then
    local origin_buf = vim.b[buf].jupynvim_origin_buf
    local origin_line = vim.b[buf].jupynvim_origin_line
    vim.cmd("close")
    if origin_buf then
      for _, w in ipairs(vim.fn.win_findbuf(origin_buf)) do
        vim.api.nvim_set_current_win(w)
        if origin_line then
          pcall(vim.api.nvim_win_set_cursor, w, { origin_line, 0 })
        end
        return
      end
    end
    return
  end

  local nb = Notebook.get(buf)
  if not nb then return end
  nb:sync_from_buffer()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local cur_id = nb:cell_at_line(lnum)
  local cur_idx = 1
  for i, c in ipairs(nb.cells) do if c.id == cur_id then cur_idx = i; break end end

  local target_idx
  if direction == "up" then
    -- look at current cell, then walk backwards
    for i = cur_idx, 1, -1 do
      if _has_output(nb.cells[i]) then target_idx = i; break end
    end
  else
    -- down: current cell first, then walk forwards
    for i = cur_idx, #nb.cells do
      if _has_output(nb.cells[i]) then target_idx = i; break end
    end
  end
  if not target_idx then
    vim.notify("jupynvim: no " .. direction .. " cell with output", vim.log.levels.INFO)
    return
  end

  _open_output_split(buf, nb.cells[target_idx], lnum)
end

-- Save the current cell's image (markdown embedded or code-cell output)
-- to a file. Format inferred from image/png vs image/jpeg vs image/gif.
function M.save_image(buf, path)
  local nb = Notebook.get(buf)
  if not nb then return end
  nb:sync_from_buffer()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local cell_id = nb:cell_at_line(lnum)
  if not cell_id then return end
  local cell = nb:get_cell(cell_id)
  if not cell then return end

  local b64, ext, mime
  if cell.cell_type == "markdown" then
    local imgs = require("jupynvim.embedded").list_images(cell.id) or {}
    if imgs[1] then
      b64 = imgs[1].b64
      mime = imgs[1].mime or "image/png"
    end
  end
  if not b64 then
    for _, o in ipairs(cell.outputs or {}) do
      local d = (o.output_type == "execute_result" or o.output_type == "display_data") and o.data or nil
      if d then
        for k, v in pairs(d) do
          if k:match("^image/") then
            b64 = type(v) == "table" and table.concat(v, "") or v
            mime = k
            break
          end
        end
        if b64 then break end
      end
    end
  end
  if not b64 then
    vim.notify("jupynvim: no image in this cell", vim.log.levels.WARN)
    return
  end
  ext = ({ ["image/png"] = "png", ["image/jpeg"] = "jpg", ["image/gif"] = "gif",
           ["image/svg+xml"] = "svg", ["image/webp"] = "webp" })[mime] or "png"

  if not path or path == "" then
    local default = string.format("./jupynvim_%s.%s", cell.id:sub(1, 8), ext)
    path = vim.fn.input({ prompt = "Save image as: ", default = default, completion = "file" })
    if path == "" then return end
  end
  path = vim.fn.fnamemodify(path, ":p")

  local raw_ok, raw = pcall(vim.base64.decode, b64)
  if not raw_ok or not raw then
    vim.notify("jupynvim: failed to decode image", vim.log.levels.ERROR)
    return
  end
  local f = io.open(path, "wb")
  if not f then
    vim.notify("jupynvim: cannot write " .. path, vim.log.levels.ERROR)
    return
  end
  f:write(raw); f:close()
  vim.notify("jupynvim: saved " .. path, vim.log.levels.INFO)
end

-- Compatibility shim for the old name; defaults to "down" direction.
function M.toggle_output(buf) M.enter_output(buf, "down") end

-- Jump cursor to the next or previous cell that contains an image, either as
-- a markdown embedded image or a code-cell image output. delta > 0 moves
-- forward, delta < 0 moves backward.
function M.jump_image(buf, delta)
  local nb = Notebook.get(buf)
  if not nb then return end
  nb:sync_from_buffer()
  local _, ranges = nb:to_lines()
  if #ranges == 0 then return end
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local cur_id = nb:cell_at_line(lnum)
  local cur_idx = 1
  for i, r in ipairs(ranges) do if r.id == cur_id then cur_idx = i; break end end

  local Embedded = require("jupynvim.embedded")
  local function has_image(cell)
    if cell.cell_type == "markdown" then
      local imgs = Embedded.list_images(cell.id) or {}
      if #imgs > 0 then return true end
    end
    for _, o in ipairs(cell.outputs or {}) do
      local d = (o.output_type == "execute_result" or o.output_type == "display_data") and o.data or nil
      if d and d["image/png"] then return true end
    end
    return false
  end

  local n = #ranges
  local step = delta >= 0 and 1 or -1
  for off = 1, n do
    local idx = cur_idx + off * step
    if idx < 1 or idx > n then break end
    local cell = nb.cells[idx]
    if cell and has_image(cell) then
      local r = ranges[idx]
      vim.api.nvim_win_set_cursor(0, { r.start + 1, 0 })
      return
    end
  end
  vim.notify("jupynvim: no " .. (delta >= 0 and "next" or "prev") .. " image cell",
    vim.log.levels.INFO)
end

function M.jump_cell(buf, delta, advance_to_end)
  local nb = Notebook.get(buf)
  if not nb then return end
  nb:sync_from_buffer()
  local _, ranges = nb:to_lines()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local cur_id, _, idx_at = nb:cell_at_line(lnum)
  -- find current index in ranges
  local cur_idx
  for i, r in ipairs(ranges) do if r.id == cur_id then cur_idx = i; break end end
  if not cur_idx then return end
  local target = cur_idx + delta
  if target < 1 then target = 1 end
  if target > #ranges then
    if advance_to_end then
      -- Insert a new cell below
      M.add_cell(buf, "below")
      return
    end
    target = #ranges
  end
  local r = ranges[target]
  if r then vim.api.nvim_win_set_cursor(0, { r.start + 1, 0 }) end
end

function M.refresh(buf)
  local nb = Notebook.get(buf)
  if nb then Render.refresh(nb, vim.fn.bufwinid(buf)) end
end

-- ---------- setup ----------

function M.setup(opts)
  M.config = vim.tbl_extend("force", M.config, opts or {})
  Log.set_level(M.config.log_level)
  Render.setup_highlights()
  require("jupynvim.diag").setup()
  require("jupynvim.lsp").setup()
  Image.set_size({ rows = M.config.image_rows, cols = M.config.image_cols })

  -- Inside tmux, image_renderer = "kitty" (direct placement) places at the
  -- TTY's cursor coordinates and is never auto-cleaned, which surfaces as
  -- "image at bottom of screen, persists after :qa". Auto-switch to
  -- placeholder mode so users get the inline cell behavior they expect.
  -- Set JUPYNVIM_FORCE_KITTY_IN_TMUX=1 to opt out and keep direct mode.
  if M.config.image_renderer == "kitty"
      and vim.env.TMUX ~= nil and vim.env.TMUX ~= ""
      and not (vim.env.JUPYNVIM_FORCE_KITTY_IN_TMUX ~= nil
               and vim.env.JUPYNVIM_FORCE_KITTY_IN_TMUX ~= "") then
    M.config.image_renderer = "placeholder"
    vim.schedule(function()
      vim.notify(
        "jupynvim: image_renderer='kitty' is unstable in tmux (places at " ..
        "fixed screen coords, no auto-cleanup). Switching to 'placeholder' " ..
        "for inline cell rendering. Set JUPYNVIM_FORCE_KITTY_IN_TMUX=1 to " ..
        "keep direct mode.",
        vim.log.levels.INFO)
    end)
  end

  -- Hijack .ipynb opens
  local group = vim.api.nvim_create_augroup("JupynvimDispatch", { clear = true })
  vim.api.nvim_create_autocmd("BufReadCmd", {
    group = group,
    pattern = { "*.ipynb" },
    callback = function(args)
      -- BufReadCmd means user wants to read this file. If we already have a
      -- live notebook for it, treat as :e! (force reload from disk).
      local abs = vim.fn.fnamemodify(args.file, ":p")
      local b = vim.fn.bufnr(abs)
      local force = b > 0 and Notebook.get(b) ~= nil
      -- Pre-populate the buffer with the on-disk file's line count of empty
      -- placeholder lines BEFORE scheduling M.open. Plugins that grep the
      -- raw .ipynb json and then call nvim_win_set_cursor on a matched line
      -- (snacks.nvim picker, telescope grep_string, etc.) fire immediately
      -- after BufReadCmd. Without placeholders the buffer is empty and the
      -- cursor set fails with "Cursor position outside buffer". M.open then
      -- overwrites with rendered cells.
      local f = io.open(abs, "r")
      if f then
        local count = 0
        for _ in f:lines() do count = count + 1 end
        f:close()
        if count > 0 then
          local lines = {}
          for _ = 1, count do lines[#lines + 1] = "" end
          pcall(vim.api.nvim_buf_set_lines, args.buf, 0, -1, false, lines)
        end
      end
      vim.schedule(function() M.open(args.file, { force = force }) end)
    end,
  })
  vim.api.nvim_create_autocmd("BufNewFile", {
    group = group,
    pattern = { "*.ipynb" },
    callback = function(args)
      -- New file: defer-create with empty notebook
      vim.schedule(function() M.open(args.file) end)
    end,
  })

  vim.api.nvim_create_user_command("JupynvimImageMode", function(o)
    local mode = o.args:match("^%s*(%S+)%s*$") or ""
    if mode ~= "chafa" and mode ~= "kitty" and mode ~= "placeholder" then
      vim.notify("Usage: :JupynvimImageMode chafa|kitty|placeholder", vim.log.levels.WARN)
      return
    end
    M.config.image_renderer = mode
    pcall(function() require("jupynvim.image").clear_all() end)
    for buf, nb in pairs(Notebook.all()) do
      nb.image_ids = {}
      Render.refresh(nb, vim.fn.bufwinid(buf))
    end
    vim.notify("jupynvim image_renderer = " .. mode, vim.log.levels.INFO)
  end, { nargs = 1, complete = function() return { "chafa", "kitty", "placeholder" } end })

  vim.api.nvim_create_user_command("JupynvimSaveImage", function(o)
    M.save_image(vim.api.nvim_get_current_buf(), o.args)
  end, { nargs = "?", complete = "file" })
  vim.api.nvim_create_user_command("JupynvimDeleteImage", function()
    M.delete_image(vim.api.nvim_get_current_buf())
  end, {})
  vim.api.nvim_create_user_command("JupynvimOpen", function(o) M.open(o.args) end, { nargs = 1, complete = "file" })

  -- :JupynvimOpenRemote alias:path  (alias from config.remote)
  -- :JupynvimOpenRemote user@host:/abs/path  (one-off)
  -- Switches the active backend to an SSH-spawned one on the named host,
  -- then opens the notebook at the given remote path.
  vim.api.nvim_create_user_command("JupynvimOpenRemote", function(o)
    local spec, perr = M._parse_remote_spec(o.args)
    if not spec then
      vim.notify("jupynvim: " .. tostring(perr), vim.log.levels.ERROR)
      return
    end
    M.use_remote(spec)
    -- For remote opens, the path is whatever the user wrote (we don't expand
    -- ~ or resolve relative against the local CWD). Backend opens it on the
    -- remote filesystem.
    M.open(spec.path, { remote_label = spec.label })
  end, { nargs = 1 })

  vim.api.nvim_create_user_command("JupynvimUseLocal", function() M.use_local() end, {})

  -- :JupynvimConnect <alias>  — open a terminal split for interactive SSH
  -- auth (password / 2FA). Sets up a ControlMaster socket; future
  -- :JupynvimOpenRemote calls for this alias reuse it without prompting.
  vim.api.nvim_create_user_command("JupynvimConnect", function(o) M.connect(o.args) end, {
    nargs = 1,
    complete = function()
      local names = {}
      for name, _ in pairs(M.config.remote or {}) do table.insert(names, name) end
      return names
    end,
  })

  -- :JupynvimDisconnect <alias>  — close the ControlMaster socket.
  vim.api.nvim_create_user_command("JupynvimDisconnect", function(o) M.disconnect(o.args) end, {
    nargs = 1,
    complete = function()
      local names = {}
      for name, _ in pairs(M.config.remote or {}) do table.insert(names, name) end
      return names
    end,
  })

  -- :JupynvimRemoteFiles <alias> [<subpath>]  — browse files on a remote,
  -- open notebooks via jupynvim and other files as read-only scratch. Requires
  -- :JupynvimConnect <alias> first.
  vim.api.nvim_create_user_command("JupynvimRemoteFiles", function(o)
    local parts = vim.split(o.args, " ", { trimempty = true })
    if #parts == 0 then
      vim.notify("usage: :JupynvimRemoteFiles <alias> [<subpath>]", vim.log.levels.WARN)
      return
    end
    M.remote_browse(parts[1], parts[2])
  end, {
    nargs = "*",
    complete = function(_, line)
      local words = vim.split(line, " ", { trimempty = true })
      if #words <= 2 then
        local names = {}
        for name, _ in pairs(M.config.remote or {}) do table.insert(names, name) end
        return names
      end
      return {}
    end,
  })
  vim.api.nvim_create_user_command("JupynvimRunCell", function() M.run_cell(0, { advance = false }) end, {})
  vim.api.nvim_create_user_command("JupynvimRunAll", function() M.run_all(0) end, {})
  vim.api.nvim_create_user_command("JupynvimKernel", function() M.kernel_picker(0) end, {})
  vim.api.nvim_create_user_command("JupynvimRestart", function() M.restart_kernel(0) end, {})
  vim.api.nvim_create_user_command("JupynvimClearOutputs", function() M.clear_outputs(0) end, {})
  vim.api.nvim_create_user_command("JupynvimClearCellOutput", function() M.clear_cell_output(0) end, {})

  -- Nuclear reset: close all sessions, wipe all notebook buffers, reload from disk.
  vim.api.nvim_create_user_command("JupynvimReset", function()
    for buf, nb in pairs(Notebook.all()) do
      if nb.session_id and M.client then
        M.client:call("close", { session_id = nb.session_id }, function() end)
      end
      Notebook.remove(buf)
      pcall(Image.clear_all)
      if vim.api.nvim_buf_is_valid(buf) then
        local path = vim.api.nvim_buf_get_name(buf)
        vim.api.nvim_buf_delete(buf, { force = true })
        if path:match("%.ipynb$") then
          vim.defer_fn(function() M.open(path, { force = true }) end, 100)
        end
      end
    end
    vim.notify("jupynvim: reset complete", vim.log.levels.INFO)
  end, {})

  -- Diagnostic: print the current state of the notebook buffer.
  vim.api.nvim_create_user_command("JupynvimDebug", function()
    local buf = vim.api.nvim_get_current_buf()
    local nb = Notebook.get(buf)
    if not nb then
      print("no notebook for buffer " .. buf)
      return
    end
    print(string.format("buf=%d session=%s path=%s", buf, nb.session_id:sub(1,8), nb.path))
    print(string.format("buffer line count: %d", vim.api.nvim_buf_line_count(buf)))
    print(string.format("nb.cells count:    %d", #nb.cells))
    -- Window dup detection — if more than one window shows this buffer, the user
    -- is seeing apparent "duplicate cells" because both windows render the same buffer.
    local wins = vim.fn.win_findbuf(buf)
    print(string.format("windows showing this buf: %d  (Ctrl-w o to close others)", #wins))
    for i, c in ipairs(nb.cells) do
      print(string.format("  [%d] id=%s type=%s ec=%s outs=%d", i, c.id, c.cell_type, tostring(c.execution_count), #(c.outputs or {})))
    end
    print(string.format("image.supported: %s", tostring(Image.supported())))
    print(string.format("image_ids: %s", vim.inspect(nb.image_ids or {})))
    print(string.format("placements: %s", vim.inspect(Image._placements or {})))
  end, {})
end

return M

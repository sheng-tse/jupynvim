-- jupynvim — VSCode-style Jupyter notebook editing in Neovim.
--
-- Usage (lazy.nvim-style):
--   require("jupynvim").setup({ core_path = "/path/to/jupynvim-core" })
--
-- Or just call setup({}) — it'll auto-detect the binary in this repo.

local M = {}

local Notebook = require("jupynvim.notebook")
local Render   = require("jupynvim.notebook.render")
local RPC      = require("jupynvim.rpc")
local Keymaps  = require("jupynvim.keymaps")
local Image    = require("jupynvim.notebook.image")
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
  image_rows = 16,
  image_cols = 48,
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
  --     mycluster = {
  --       host = "user@cluster.example.edu",
  --       core_path = "~/.local/bin/jupynvim-core",
  --       -- ssh_args = { "-J", "jumpbox" },  -- optional ProxyJump etc
  --       -- slurm = "interact -p GPU-shared --gpus 1 -t 02:00:00", -- v0.3.x
  --     },
  --   }
  remote = {},
  -- When an SSH session is active, these keys open the REMOTE tree explorer
  -- instead of the local one; with no active session they fall through to the
  -- local explorer (snacks). Set to {} to disable the hijack and bind
  -- M.explorer / :JupynvimExplorer yourself.
  -- Split to mirror what distros put on these keys locally: <leader>e is the
  -- PROJECT ROOT of the file you are in, <leader>E is the session's base dir.
  -- Both used to open the same place, so the two keys were indistinguishable
  -- once you connected.
  explorer_keys = { "<leader>e" },          -- remote tree at the project root
  explorer_cwd_keys = { "<leader>E" },      -- remote tree at the session home
  -- What counts as a project root when walking up for explorer_keys. A `vcs`
  -- hit wins outright even if a `build` file sits nearer: in a monorepo the
  -- nearest Cargo.toml is a sub-crate, not the project, and distros root on
  -- the repo. `build` is the fallback for code that isn't in version control.
  root_markers = {
    vcs   = { ".git", ".hg", ".svn" },
    build = { "pyproject.toml", "setup.py", "package.json", "Cargo.toml", "go.mod" },
  },
  -- Toggle a remote PTY terminal for the active SSH session (or the local
  -- terminal when not connected). LazyVim's <C-/> is the natural fit; <C-_>
  -- is how many terminals transmit <C-/>. Set to {} to disable + bind yourself.
  terminal_keys = { "<c-/>", "<c-_>" },
  -- Toggle a SECOND remote terminal on the right (open/close like <C-/>),
  -- for a scratch shell to run whatever you like. Set {} to disable.
  terminal_right_keys = { "<leader>tr" },
  -- Remote-terminal resize keys, bound buffer-local on the terminal (they
  -- never shadow your global maps). Two sets:
  --   resize_keys_normal: Shift+hjkl in NORMAL mode.
  --   resize_keys:        Ctrl+arrows in NORMAL + terminal-INSERT mode (so
  --                       you can resize without leaving insert).
  -- Set a field to "" to unbind it.
  terminal = {
    resize_step = 3,
    -- Default sizes (compact; you can resize and it now persists across
    -- toggle). bottom_height = rows for the <C-/> terminal; side_width = cols
    -- for a left/right terminal. nil side_width auto-computes (~40% screen, a
    -- bit narrower). A bottom terminal only resizes height (K/J); a side
    -- terminal only resizes width (H/L) - the other keys are no-ops.
    bottom_height = 9,
    side_width = nil,
    resize_keys_normal = { taller = "K", shorter = "J", broader = "H", narrower = "L" },
    resize_keys = { taller = "<C-Up>", shorter = "<C-Down>", broader = "<C-Left>", narrower = "<C-Right>" },
  },
  -- File-picker / grep keys that should target the REMOTE when SSH-connected
  -- and otherwise replay your own local mapping (captured at bind time, so
  -- LazyVim's local behavior is preserved). Defaults match LazyVim. Set a
  -- group to {} to leave those keys alone.
  pick_keys = {
    files = { "<leader>ff", "<leader><space>" },
    grep  = { "<leader>/", "<leader>sg" },
  },
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

-- Path to this plugin's repo root (.../jupynvim).
local function plugin_root()
  local src = debug.getinfo(1, "S").source
  if src:sub(1, 1) == "@" then src = src:sub(2) end
  return vim.fn.fnamemodify(src, ":h:h:h")
end

-- Forward declarations: these helpers are defined further down but referenced
-- by ensure_remote_binary (just below). Without forward-declaring, the refs
-- would resolve to nil globals and the upload would silently no-op.
local control_path, master_alive, ssh_base

-- Map a remote `uname -m` to the musl target triple we cross-build. Covers
-- x86 (PSC, most cloud VMs) and arm64 (AWS Graviton, GCP Tau T2A, etc.).
local ARCH_TRIPLE = {
  x86_64 = "x86_64-unknown-linux-musl",
  amd64 = "x86_64-unknown-linux-musl",
  aarch64 = "aarch64-unknown-linux-musl",
  arm64 = "aarch64-unknown-linux-musl",
}

-- Path to the cross-compiled linux binary on THIS machine for the remote's
-- architecture, for auto-upload. Override per-profile with `local_core`.
-- Built by :JupynvimCrossBuild (cargo zigbuild, musl targets).
local function locate_local_linux_core(profile, triple)
  if profile and profile.local_core then return vim.fn.expand(profile.local_core) end
  triple = triple or "x86_64-unknown-linux-musl"
  return plugin_root() .. "/core/target/" .. triple .. "/release/jupynvim-core"
end

-- Newest mtime across the backend sources. Lets a connect tell whether the
-- cross-built linux binary predates the code it is meant to be carrying.
local function core_source_mtime()
  local root = plugin_root() .. "/core"
  local files = vim.fn.glob(root .. "/src/**/*.rs", false, true)
  table.insert(files, root .. "/Cargo.toml")
  table.insert(files, root .. "/Cargo.lock")
  local newest = 0
  for _, f in ipairs(files) do
    local t = vim.fn.getftime(f)
    if t > newest then newest = t end
  end
  return newest
end

-- Is the linux artifact we would upload older than the source it came from?
local function linux_core_stale(triple)
  local bin = plugin_root() .. "/core/target/" .. triple .. "/release/jupynvim-core"
  local bin_t = vim.fn.getftime(bin)
  if bin_t < 0 then return true, "missing" end
  if bin_t < core_source_mtime() then return true, "older than core/" end
  return false
end
M._core_source_mtime = core_source_mtime   -- exposed for tests
M._linux_core_stale = linux_core_stale     -- exposed for tests

-- Cross-build the linux binary HERE if it has fallen behind the source. We
-- never build on the remote: a login node is not a build box, and PSC would
-- not thank us for it. Nothing used to keep this artifact in step, so it went
-- weeks stale while every connect compared it, found no change, and uploaded
-- nothing. Synchronous, because the upload right after depends on it.
local function cross_build_if_stale(triple)
  local stale, why = linux_core_stale(triple)
  if not stale then return true end
  vim.notify("jupynvim: linux binary " .. why .. ", cross-building " .. triple .. " ...",
             vim.log.levels.INFO)
  local res = vim.system({
    "cargo", "zigbuild", "--release", "--target", triple,
    "--manifest-path", plugin_root() .. "/core/Cargo.toml",
  }, { text = true }):wait()
  local bin = plugin_root() .. "/core/target/" .. triple .. "/release/jupynvim-core"
  if res.code ~= 0 then
    vim.notify("jupynvim: cross-build failed; the remote keeps whatever it has.\n" ..
               "  one-time setup: brew install zig; cargo install cargo-zigbuild; " ..
               "rustup target add " .. triple .. "\n" ..
               ((res.stderr or ""):sub(1, 300)), vim.log.levels.WARN)
    return vim.fn.filereadable(bin) == 1
  end
  vim.notify("jupynvim: cross-build done, uploading to the remote", vim.log.levels.INFO)
  return true
end

-- Ensure the remote alias has the current backend binary at profile.core_path,
-- uploading the locally cross-built linux binary over the SSH ControlMaster if
-- the remote copy is missing or stale (sha256 mismatch). PSC blocks scp/sftp,
-- so we stream the bytes via `ssh 'cat > path'`. Synchronous (must finish
-- before the backend spawns). Best-effort: on any problem we warn and let the
-- spawn use whatever's already on the remote.
local function ensure_remote_binary(alias, profile)
  if profile.transport_cmd then return end  -- custom transport: user owns deployment
  local cp = control_path(alias)
  if not cp or not master_alive(alias, profile) then return end
  -- Detect the remote architecture so multi-cloud setups work: PSC/most VMs
  -- are x86_64, AWS Graviton / GCP Tau T2A are aarch64. One RTT, once per
  -- session (this whole function runs behind the _binary_verified guard).
  local arch_probe = vim.system(
    vim.list_extend(ssh_base(cp, profile.host), { "uname -m" }), {}):wait()
  local arch = ((arch_probe.stdout or ""):match("(%S+)")) or "x86_64"
  local triple = ARCH_TRIPLE[arch]
  if not triple then
    vim.notify("jupynvim: unsupported remote arch '" .. arch .. "' on " .. alias ..
               " - deploy jupynvim-core manually (profile.core_path)", vim.log.levels.WARN)
    return
  end
  -- Line the artifact up with the source before comparing hashes, unless the
  -- profile pins its own binary (then it is the user's to manage).
  if not (profile and profile.local_core) then cross_build_if_stale(triple) end
  local local_bin = locate_local_linux_core(profile, triple)
  if vim.fn.filereadable(local_bin) ~= 1 then
    vim.notify("jupynvim: no local linux binary at " .. local_bin ..
               "\n  run :JupynvimCrossBuild (one-time: brew install zig; " ..
               "cargo install cargo-zigbuild; rustup target add " .. triple .. ")",
               vim.log.levels.WARN)
    return
  end
  -- Same default as ad-hoc connects: a fixed home path, NOT a bare name
  -- (non-interactive ssh exec doesn't source .profile, so ~/.local/bin is
  -- not on PATH and a bare name fails with exit 127).
  local core_path = profile.core_path or "~/.local/bin/jupynvim-core"
  local local_sha = (vim.fn.system({ "shasum", "-a", "256", local_bin }) or ""):match("^(%x+)")
  if not local_sha then return end
  -- Make a remote-shell-expandable, quoted path: "~/.x" -> "$HOME/.x", wrapped
  -- in double quotes so $HOME expands AND spaces survive. (shellescape uses
  -- single quotes, which would keep ~ literal — the marker never persisted and
  -- the upload path could be wrong.)
  local function rp(p)
    if p:sub(1, 2) == "~/" then p = "$HOME/" .. p:sub(3) end
    return '"' .. p .. '"'
  end
  local core_q = rp(core_path)
  local marker_q = rp(core_path .. ".sha256")
  local dir_q = rp(core_path:match("^(.*)/[^/]+$") or ".")
  -- Use vim.system (not vim.fn.system): the latter throws E976 "Using a Blob
  -- as a String" when stdin contains NUL bytes, so piping the binary silently
  -- failed inside the caller's pcall and the upload never happened. vim.system
  -- writes raw binary stdin correctly. Returns (stdout, exit_code).
  local function ssh(args, input)
    local c = ssh_base(cp, profile.host)
    for _, a in ipairs(args) do table.insert(c, a) end
    local res = vim.system(c, input and { stdin = input } or {}):wait()
    return res.stdout or "", res.code or -1
  end
  local remote_sha = (ssh({ "cat " .. marker_q .. " 2>/dev/null" })):gsub("%s+", "")
  if remote_sha == local_sha then return end  -- already current

  vim.notify("jupynvim: uploading backend to " .. alias .. " ...", vim.log.levels.INFO)
  -- Stream the binary to a temp path, chmod, atomically move into place, then
  -- write the sha marker. Quoted-$HOME paths expand on the remote shell.
  local remote_cmd = string.format(
    "mkdir -p %s && cat > %s.up && chmod +x %s.up && mv -f %s.up %s",
    dir_q, core_q, core_q, core_q, core_q)
  local data = io.open(local_bin, "rb")
  if not data then return end
  local bytes = data:read("*a"); data:close()
  local _, code = ssh({ remote_cmd }, bytes)
  if code ~= 0 then
    vim.notify("jupynvim: binary upload to " .. alias .. " failed (exit " .. code .. ")", vim.log.levels.ERROR)
    return
  end
  ssh({ "printf %s " .. vim.fn.shellescape(local_sha) .. " > " .. marker_q })
  vim.notify("jupynvim: backend updated on " .. alias .. " (" .. local_sha:sub(1, 12) .. ")",
             vim.log.levels.INFO)
end

-- Multi-client storage. Keyed by alias ("local" for the default local backend,
-- or any user-defined remote alias from M.config.remote). Lets you have a
-- local notebook AND multiple remote notebooks open simultaneously, each
-- routed to the right backend by their buffer's stored alias.
M.clients = M.clients or {}

-- Internal: spawn a backend process with the given cmd vector and wire it up
-- with TTY attach + event handlers. Stores in M.clients[alias] for routing.
local function spawn_client(cmd_vec, alias)
  Log.info(string.format("spawning core (%s): %s", alias, table.concat(cmd_vec, " ")))
  local client = RPC.spawn({
    cmd = cmd_vec,
    env = vim.tbl_extend("force", vim.fn.environ(), {
      JUPYNVIM_LOG = M.config.log_level,
    }),
    on_exit = function(code)
      M.clients[alias] = nil
      if alias == "local" then M.client = nil end
      vim.schedule(function()
        vim.notify(string.format("jupynvim-core (%s) exited (code=%s)", alias, tostring(code)),
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
  -- Backend-initiated user-facing messages (e.g. "installing ipykernel into
  -- this env..." during a first-use kernel start).
  client:on("user_message", function(args)
    local p = args[1] or args
    local lvl = ({ info = vim.log.levels.INFO, warn = vim.log.levels.WARN,
                   error = vim.log.levels.ERROR })[p.level or "info"] or vim.log.levels.INFO
    vim.notify("jupynvim: " .. tostring(p.text or ""), lvl)
  end)
  M.clients[alias] = client
  return client
end

-- M.client_for is defined below after the SSH helpers are declared (Lua
-- needs `resolve` and `build_ssh_cmd` to be in scope at definition time).

local function ensure_client()
  if M.client and M.client.job then return M.client end
  M.client = spawn_client({ locate_core() }, "local")
  return M.client
end

-- Resolve the RPC client a notebook's operations should route to. Remote
-- notebooks (nb.alias set) go to their own backend; local ones to the
-- shared local backend. Always use this in execute/kernel paths rather than
-- the global M.client — otherwise, with a local AND a remote notebook open,
-- run-cell on one routes to whichever backend was touched last.
local function nb_client(nb)
  if nb and nb.alias then return M.client_for(nb.alias) end
  return ensure_client()
end

-- ControlMaster socket path for an alias. Multiplexed SSH: run
-- `:JupynvimConnect <alias>` once to authenticate interactively (password,
-- 2FA, etc); subsequent ssh commands reuse the socket and skip auth.
control_path = function(alias)
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

-- ssh options that make a hung/dead connection FAIL FAST instead of blocking
-- nvim forever. Without these, a timed-out compute node freezes the editor on
-- the blocking vim.fn.system ssh calls (master_alive, binary upload, etc).
-- ConnectTimeout caps the initial connect; ServerAlive* drops a silent-dead
-- session in ~15s. Inserted into every ssh invocation.
local SSH_TIMEOUT_OPTS = {
  "-o", "ConnectTimeout=10",
  "-o", "ServerAliveInterval=5",
  "-o", "ServerAliveCountMax=3",
}
ssh_base = function(cp, host)
  local c = { "ssh", "-T", "-o", "BatchMode=yes" }
  for _, o in ipairs(SSH_TIMEOUT_OPTS) do table.insert(c, o) end
  if cp then table.insert(c, "-o"); table.insert(c, "ControlPath=" .. cp) end
  if host then table.insert(c, host) end
  return c
end

-- Build an SSH command vector that spawns jupynvim-core on a remote host.
-- spec.host: "user@host" passed to ssh (or an alias from ~/.ssh/config).
-- spec.core_path: remote path to jupynvim-core
--   (default "~/.local/bin/jupynvim-core", where auto-upload deploys it).
-- spec.ssh_args: extra args appended after `ssh` (e.g. ProxyJump). Optional.
--   Can be a function returning the array.
-- spec.slurm: if set, prepended to the remote command. Typical:
--   slurm = "srun -p GPU-shared --gpus 1 -t 02:00:00"
-- Can be a function returning the string — useful for attaching to an
-- existing job whose ID isn't known until call time:
--   slurm = function()
--     local jid = vim.env.PSC_JOBID or vim.fn.input("Job ID: ")
--     return ("srun --jobid=%s --overlap --unbuffered"):format(jid)
--   end
local function build_ssh_cmd(spec)
  -- -T raw stdio (msgpack), BatchMode no prompts, timeout opts fail fast,
  -- ControlPath reuses the :JupynvimConnect master (or makes a fresh conn).
  local cp = control_path(spec.label or spec.host)
  local cmd = ssh_base(cp, nil)  -- host appended after ssh_args
  local ssh_args = resolve(spec.ssh_args, spec) or {}
  for _, a in ipairs(ssh_args) do table.insert(cmd, a) end
  table.insert(cmd, spec.host)
  local remote_cmd = spec.core_path or "~/.local/bin/jupynvim-core"
  -- Environment setup before the backend starts (runs INSIDE the slurm step
  -- when one is active, i.e. on the compute node). A login bash sources the
  -- cluster's profile so `module` exists; the backend then inherits the
  -- prepared PATH/env, which kernels, LSP servers, and terminals all reuse.
  --   remote = { psc = { setup_cmd = "module load anaconda3" } }
  local setup = resolve(spec.setup_cmd, spec)
  if type(setup) == "string" and setup ~= "" then
    remote_cmd = "bash -lc " .. vim.fn.shellescape(setup .. " && exec " .. remote_cmd)
  end
  -- Slurm wrapping: only honor (a) the :JupynvimUseJob cache or (b) a
  -- static `slurm = "..."` string in the profile. Function-valued slurm
  -- fields are intentionally IGNORED here — calling them from inside the
  -- BufReadCmd that triggered the spawn would block on vim.fn.input with
  -- no visible prompt. For dynamic per-spawn slurm, use :JupynvimUseJob.
  local slurm
  if M._slurm_cache and spec.label and M._slurm_cache[spec.label] then
    slurm = M._slurm_cache[spec.label]
  elseif type(spec.slurm) == "string" and spec.slurm ~= "" then
    slurm = spec.slurm
  end
  if slurm then
    remote_cmd = slurm .. " " .. remote_cmd
  end
  -- `exec` keeps backend's stdio identical to ssh's stdio (no shell wrapper
  -- buffering in between). When slurm is involved the exec applies to srun
  -- which itself execs the job step.
  table.insert(cmd, "exec " .. remote_cmd)
  return cmd
end

-- Get or spawn the client for an alias.
--   nil / "" / "local"  → the default local backend (M.client)
--   <other>             → looks up M.config.remote[<alias>], spawns via SSH
--                         (or profile.transport_cmd), caches in M.clients
-- Multiple remote aliases coexist: each gets its own subprocess + msgpack
-- session, routed to whichever buffer's `b:jupynvim_alias` matches.
function M.client_for(alias)
  if alias == nil or alias == "" or alias == "local" then
    if M.client and M.client.job then return M.client end
    M.client = spawn_client({ locate_core() }, "local")
    return M.client
  end
  local existing = M.clients[alias]
  if existing and existing.job then return existing end
  local profile = M.config.remote and M.config.remote[alias]
  if not profile then
    error("jupynvim: no remote profile '" .. alias .. "'")
  end
  -- Auto-upload the cross-built linux binary if the remote copy is stale.
  -- Once per session per alias (cleared on disconnect). Synchronous so the
  -- spawn below uses the fresh binary.
  M._binary_verified = M._binary_verified or {}
  if not M._binary_verified[alias] then
    pcall(ensure_remote_binary, alias, profile)
    M._binary_verified[alias] = true
  end
  -- Attach alias as `label` so build_ssh_cmd can find the cached slurm string.
  local spec = vim.tbl_extend("force", {}, profile, { label = alias })
  local cmd = resolve(spec.transport_cmd, spec) or build_ssh_cmd(spec)
  return spawn_client(cmd, alias)
end

-- Point the "active" client at a remote alias's backend. Reuses the
-- existing M.clients[alias] connection (spawned at :JupynvimConnect time)
-- instead of tearing down and respawning. Accepts either an alias string
-- or a spec table (the latter must include `label` or `host` for lookup).
function M.use_remote(alias_or_spec)
  local alias, spec
  if type(alias_or_spec) == "string" then
    alias = alias_or_spec
    spec = M.config.remote and M.config.remote[alias]
  else
    spec = alias_or_spec
    alias = spec.label or spec.host
  end
  assert(spec and spec.host, "use_remote: profile not found or missing host")
  M._remote_spec = spec
  -- Only treat named-profile aliases as the "active" explorer target
  -- (one-off user@host specs aren't in M.config.remote).
  if M.config.remote and M.config.remote[alias] then M._set_active_alias(alias) end
  M.client = M.client_for(alias)  -- reuse existing alive client
  return M.client
end

-- Is the ControlMaster for this alias alive?
master_alive = function(alias, profile)
  local cp = control_path(alias)
  if not cp then return false end
  -- `ssh -O check` is local (queries the control socket), fast, no network.
  vim.fn.system({ "ssh", "-O", "check", "-o", "ControlPath=" .. cp, profile.host })
  return vim.v.shell_error == 0
end

-- Hosts declared in ~/.ssh/config (incl. Include files): the natural home of
-- AWS/GCP boxes (`gcloud compute config-ssh`, ProxyCommand/IAP entries, EC2
-- aliases). Wildcard patterns are skipped. Best-effort parse.
-- Parse ~/.ssh/config (incl. Include files) into { {name, hostname}, ... }.
-- hostname is the block's HostName when present (used for deduping aliases
-- that point at the same machine).
local function ssh_config_hosts_full()
  local entries, seen = {}, {}
  local function parse(path, depth)
    if depth > 3 then return end
    local f = io.open(path, "r")
    if not f then return end
    local block = {}  -- entries from the current Host line, awaiting HostName
    for line in f:lines() do
      local inc = line:match("^%s*[Ii]nclude%s+(.+)$")
      local hs = not inc and line:match("^%s*[Hh]ost%s+(.+)$") or nil
      local hn = not inc and not hs and line:match("^%s*[Hh]ost[Nn]ame%s+(%S+)") or nil
      if inc then
        for _, pat in ipairs(vim.split(inc, "%s+", { trimempty = true })) do
          if not pat:match("^[/~]") then pat = "~/.ssh/" .. pat end
          for _, p in ipairs(vim.fn.glob(vim.fn.expand(pat), true, true)) do
            parse(p, depth + 1)
          end
        end
      elseif hs then
        block = {}
        for _, h in ipairs(vim.split(hs, "%s+", { trimempty = true })) do
          if not h:match("[%*%?!]") and not seen[h] then
            seen[h] = true
            local e = { name = h, hostname = h }
            table.insert(entries, e)
            table.insert(block, e)
          end
        end
      elseif hn then
        for _, e in ipairs(block) do e.hostname = hn end
      end
    end
    f:close()
  end
  parse(vim.fn.expand("~/.ssh/config"), 0)
  table.sort(entries, function(a, b)
    if #a.name ~= #b.name then return #a.name < #b.name end  -- shortest alias first
    return a.name < b.name
  end)
  return entries
end

local function ssh_config_hosts()
  local names = {}
  for _, e in ipairs(ssh_config_hosts_full()) do table.insert(names, e.name) end
  table.sort(names)
  return names
end
M._ssh_config_hosts = ssh_config_hosts  -- exposed for the :JupynvimConnect completion

-- Hosts nobody means as a jupynvim target (git hosting etc) — hidden from the
-- chooser, still accepted if typed explicitly.
local SSH_HOST_NOISE = {
  ["github.com"] = true, ["ssh.github.com"] = true, ["gitlab.com"] = true,
  ["bitbucket.org"] = true, ["codeberg.org"] = true, ["aur.archlinux.org"] = true,
}

-- Interactive connection chooser: configured jupynvim profiles, then hosts
-- from ~/.ssh/config, then "new connection". So AWS + GCP + PSC (and any mix
-- of accounts) coexist: each is one entry; pick or type one on the fly.
-- Build the chooser entries. Profiles first, then ssh-config hosts with the
-- noise removed: git-hosting hosts hidden, aliases pointing at a machine a
-- profile already covers hidden, and multiple aliases for the SAME machine
-- (e.g. `gcp` + gcloud's generated `instance-...` entry) collapsed to the
-- shortest one. Keeps the list to one entry per real target.
-- Filtered, deduped connect targets: { {kind="profile"|"ssh", name=, host=} }.
-- Shared by the chooser AND the :JupynvimConnect tab-completion so both show
-- one entry per real machine.
function M._connect_targets()
  local out = {}
  local profile_hostnames = {}
  local function strip_user(h) return (tostring(h):gsub("^[^@]+@", "")) end
  local names = {}
  for name, _ in pairs(M.config.remote or {}) do table.insert(names, name) end
  table.sort(names)
  for _, name in ipairs(names) do
    local prof = M.config.remote[name]
    profile_hostnames[strip_user(prof.host or "")] = true
    table.insert(out, { kind = "profile", name = name, host = prof.host })
  end
  local seen_machine = {}
  for _, e in ipairs(ssh_config_hosts_full()) do  -- shortest-alias-first order
    local machine = e.hostname or e.name
    if not SSH_HOST_NOISE[e.name]
       and not (M.config.remote or {})[e.name]
       and not profile_hostnames[e.name]
       and not profile_hostnames[machine]
       and not seen_machine[machine] then
      seen_machine[machine] = true
      table.insert(out, { kind = "ssh", name = e.name })
    end
  end
  return out
end

function M._connect_items()
  local items = {}
  for _, t in ipairs(M._connect_targets()) do
    if t.kind == "profile" then
      table.insert(items, {
        label = t.name .. "  (" .. (t.host or "?") .. ")",
        run = function() M.connect(t.name) end,
      })
    else
      table.insert(items, {
        label = "ssh: " .. t.name .. "  (~/.ssh/config)",
        run = function() M.connect_adhoc(t.name) end,
      })
    end
  end
  table.insert(items, {
    label = "new connection (user@host) ...",
    run = function()
      vim.ui.input({ prompt = "user@host: " }, function(host)
        if host and host ~= "" then M.connect_adhoc(vim.trim(host)) end
      end)
    end,
  })
  return items
end

function M.connect_choose()
  local items = M._connect_items()
  vim.ui.select(items, {
    prompt = "jupynvim: connect to",
    format_item = function(it) return it.label end,
  }, function(choice)
    if choice then choice.run() end
  end)
end

-- Connect to an arbitrary user@host with no pre-declared profile. Creates a
-- session-scoped profile (alias = sanitized host string) with the default
-- core_path; everything (auto binary upload, explorer, LSP, terminal) works
-- the same. Add it under config.remote to make it permanent.
function M.connect_adhoc(host)
  local alias = host:gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", "")
  if alias == "" then alias = "adhoc" end
  M.config.remote = M.config.remote or {}
  if not M.config.remote[alias] then
    M.config.remote[alias] = { host = host, core_path = "~/.local/bin/jupynvim-core" }
    vim.notify(("jupynvim: session profile '%s' -> %s\n  add to config.remote to persist"):format(alias, host),
      vim.log.levels.INFO)
  end
  M.connect(alias)
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
  -- Connect always spawns the backend on the login node (no slurm wrap).
  -- File ops, browsing, editing, search, terminal all happen on cheap CPU
  -- resources and don't need a compute allocation. Use :JupynvimUseJob
  -- separately when you want subsequent backend spawns to attach to a
  -- specific slurm job (for kernel execution on GPU/compute nodes).
  local cp = control_path(alias)
  if master_alive(alias, profile) then
    -- Already connected. Restart the backend so an explicit :JupynvimConnect
    -- always picks up a fresh binary: stop the (possibly stale) backend
    -- process and clear the per-session upload guard, so the next client_for
    -- re-verifies/uploads and respawns. The ControlMaster (auth) stays up, so
    -- no re-auth. Without this, a backend started before a rebuild keeps
    -- serving old code ("unknown method 'run'").
    local existing = M.clients[alias]
    if existing then pcall(function() existing:stop() end); M.clients[alias] = nil end
    if M._binary_verified then M._binary_verified[alias] = nil end
    M.remote_browse(alias)
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
  local term_buf
  vim.cmd("botright 15split")
  vim.cmd("enew")
  term_buf = vim.api.nvim_get_current_buf()
  vim.bo[term_buf].buflisted = false  -- keep the auth terminal out of the bufferline
  -- termopen() was deprecated in 0.11. term=true is the same call underneath:
  -- same pty, same on_exit signature, same exit code. The pty matters here,
  -- the password and Duo prompts only appear on a real tty.
  vim.fn.jobstart(args, {
    term = true,
    on_exit = function(_, code)
      vim.schedule(function()
        -- Always close the auth terminal on clean exit (code 0). With
        -- ControlPersist, the ssh foreground exits as soon as the master
        -- forks to background — that's the success signal. If auth
        -- actually failed, code != 0 and we leave the terminal up.
        if code == 0 then
          if term_buf and vim.api.nvim_buf_is_valid(term_buf) then
            -- Close the auth split's WINDOW first: deleting only the buffer
            -- leaves the window open on a fresh [No Name] buffer (the stray
            -- bottom strip after login).
            for _, w in ipairs(vim.api.nvim_list_wins()) do
              if vim.api.nvim_win_get_buf(w) == term_buf
                 and #vim.api.nvim_list_wins() > 1 then
                pcall(vim.api.nvim_win_close, w, true)
              end
            end
            pcall(vim.api.nvim_buf_delete, term_buf, { force = true })
          end
          -- Poll briefly for master to appear (FSEvent race after fork).
          local deadline = vim.uv.hrtime() + 3e9  -- 3 seconds
          local function check()
            if master_alive(alias, profile) then
              vim.notify("jupynvim: " .. alias .. " connected", vim.log.levels.INFO)
              M.remote_browse(alias)
            elseif vim.uv.hrtime() < deadline then
              vim.defer_fn(check, 200)
            else
              vim.notify("jupynvim: " .. alias .. " auth exited 0 but master not detected",
                         vim.log.levels.WARN)
            end
          end
          check()
        else
          vim.notify("jupynvim: " .. alias .. " connect failed (code=" .. code .. ")",
                     vim.log.levels.WARN)
        end
      end)
    end,
  })
  -- Drop straight into terminal-insert mode so the password prompt is
  -- immediately typeable. Without this the split is in NORMAL mode: keys do
  -- vim motions, nothing reaches ssh, and the prompt looks frozen.
  vim.cmd("startinsert")
  vim.notify("jupynvim: authenticate " .. alias .. " in the terminal split below"
             .. " (type password; press i if you clicked away)",
             vim.log.levels.INFO)
end

-- Explicitly route future backend spawns for an alias through an existing
-- slurm job (so kernels land on the compute node you've already allocated).
-- Without this, backends spawn on the login node.
--
--   :JupynvimUseJob psc 40962291  -- attach to running job
--   :JupynvimUseJob psc           -- clear; back to login node
--
-- Takes effect on the NEXT backend spawn for that alias. If a backend is
-- already running, run :JupynvimReconnect <alias> (TODO) or restart nvim.
function M.use_job(alias, jobid)
  local profile = M.config.remote and M.config.remote[alias]
  if not profile then
    vim.notify("jupynvim: no remote profile '" .. tostring(alias) .. "'", vim.log.levels.ERROR)
    return
  end
  M._slurm_cache = M._slurm_cache or {}
  if not jobid or jobid == "" then
    M._slurm_cache[alias] = nil
  else
    -- --unbuffered is critical: without it srun block-buffers the task's
    -- stdout when it's a pipe (our case — no TTY), so the backend's
    -- length-prefixed msgpack response frames sit in srun's buffer and
    -- never reach the frontend → every RPC times out. --unbuffered
    -- forwards task output immediately.
    M._slurm_cache[alias] = string.format("srun --jobid=%s --overlap --unbuffered", jobid)
  end
  local desc = jobid and ("job " .. jobid) or "login node (no slurm)"

  -- Tear down any existing backend for this alias so the new slurm wrap takes effect.
  local existing = M.clients[alias]
  if existing and existing.job then
    pcall(function() existing:stop() end)
    M.clients[alias] = nil
    if M.client == existing then M.client = nil end
  end

  -- If there's no live SSH master, do a full connect (auth terminal + spawn);
  -- otherwise just spawn the backend through the existing master.
  if not master_alive(alias, profile) then
    M.connect(alias)  -- async: prompts auth, opens browser when ready
    vim.notify(string.format("jupynvim: %s -> %s (connecting)", alias, desc),
               vim.log.levels.INFO)
    return
  end

  -- Master is alive: spawn backend and refresh browser
  local ok = pcall(function() M.client_for(alias) end)
  if not ok then
    vim.notify("jupynvim: " .. alias .. " respawn failed; try :JupynvimConnect " .. alias,
               vim.log.levels.WARN)
    return
  end
  -- New backend → the cached tree is stale; drop it and (re)open the explorer.
  require("jupynvim.remote.explorer").reset(alias)
  M._set_active_alias(alias)
  M.remote_browse(alias)
  vim.notify(string.format("jupynvim: %s -> %s", alias, desc), vim.log.levels.INFO)
end

-- Tear down the ControlMaster socket for an alias, forcing the next
-- :JupynvimOpenRemote to re-authenticate.
function M.disconnect(alias)
  local profile = M.config.remote and M.config.remote[alias]
  -- ssh-config aliases (ad-hoc connects) have no declared profile, and the
  -- control master survives nvim restarts (ControlPersist), so disconnect
  -- must work without having connected THIS session: the alias itself is a
  -- valid ssh destination.
  if not profile then
    profile = { host = alias }
  end
  local cp = control_path(alias)
  if not cp then return end
  vim.fn.system({ "ssh", "-O", "exit", "-o", "ControlPath=" .. cp, profile.host })
  vim.fn.system({ "rm", "-f", cp })  -- always clean up file even if -O exit failed
  -- Drop the backend client + cached explorer tree; revert explorer to local.
  local cl = M.clients[alias]
  if cl then pcall(function() cl:stop() end); M.clients[alias] = nil end
  pcall(function() require("jupynvim.remote.explorer").reset(alias) end)
  if M._active_alias == alias then M._set_active_alias(nil) end
  M._session_cwd[alias] = nil
  M._resolved_home[alias] = nil
  if M._binary_verified then M._binary_verified[alias] = nil end
  vim.notify("jupynvim: " .. alias .. " control socket closed")
end

-- Open the tree-style remote file explorer (lua/jupynvim/remote_explorer.lua)
-- for `alias`, rooted at `subpath` (default remote $HOME). snacks/LazyVim-style
-- sidebar: icons + indented tree, <CR>/l expand-or-open, h collapse, a/d/r
-- create/delete/rename, R refresh, q close. Notebooks open via the notebook
-- flow; other files via the jupynvim:// URI scheme.
function M.remote_browse(alias, subpath, opts)
  local profile = M.config.remote and M.config.remote[alias]
  if not profile then
    vim.notify("jupynvim: no remote profile '" .. tostring(alias or "?") .. "'", vim.log.levels.ERROR)
    return
  end
  -- Custom transports (transport_cmd) don't use an SSH ControlMaster; the
  -- master check only applies to plain ssh profiles.
  if not profile.transport_cmd and not master_alive(alias, profile) then
    vim.notify("jupynvim: " .. alias .. " not connected; run :JupynvimConnect " .. alias .. " first",
               vim.log.levels.WARN)
    return
  end
  M._set_active_alias(alias)
  -- Pass nil (not "~") when no subpath: the explorer then KEEPS its current root
  -- across a close/reopen toggle (only a first-ever open with no state falls
  -- back to "~"). Passing "~" here reset a :JupynvimRemoteCd'd root every toggle.
  local subroot = (subpath ~= nil and subpath ~= "") and subpath or nil
  require("jupynvim.remote.explorer").open(alias, subroot, opts)
end

-- Re-render every visible notebook's frames. Toggling the explorer or a
-- terminal (local snacks float OR remote split) changes the layout, but
-- those toggles settle ASYNC and don't reliably fire a resize event the
-- notebook sees, so the width-sized frames go stale until something else
-- re-renders (the user found `i`/`a` or a second toggle "fixes" it — both
-- just trigger a refresh). So every toggle dispatcher calls this. We fire
-- once on the next tick (synchronous-settle case, before the redraw) and
-- once after a short delay (async-settle backstop). Render.refresh clears
-- and redraws in one pass and re-resolves the notebook's current window,
-- so running it twice never shows a half-state.
function M._refresh_notebooks_soon()
  local Render = require("jupynvim.notebook.render")
  local function each(fn)
    for buf, nb in pairs(Notebook.all()) do
      if vim.api.nvim_buf_is_valid(buf) and vim.fn.bufwinid(buf) ~= -1 then
        fn(nb, vim.fn.bufwinid(buf))
      end
    end
  end
  -- The frame extmarks are already correct after a toggle (verified via
  -- :JupynvimDebugFrames). The real problem is the SCREEN: closing a
  -- terminal float does a PARTIAL repaint that leaves the notebook's cells
  -- stale. The cellmode WinNew/WinClosed handler re-renders + redraws
  -- regardless of how the key was routed; this is a dispatcher-side backstop
  -- for the toggles that DO go through here. No SYNCHRONOUS render: snacks
  -- settles its window async, so an immediate render shows the pre-settle
  -- layout for a tick (the "jump" you saw). Render on the next tick
  -- (settled), then redraw to flush the stale screen. Plain redraw, no flash.
  vim.schedule(function()
    each(function(nb, win) pcall(Render.refresh_sync, nb, win) end)
    pcall(vim.cmd, "redraw")
  end)
  vim.defer_fn(function() pcall(vim.cmd, "redraw") end, 90)
end

-- "~" resolved to an absolute path, learned from the first fs_list that
-- returns it. Rooting at the literal "~" makes the tree show a placeholder
-- row until the listing lands and renames it; once we know the real path we
-- can root there directly and skip that flicker.
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
  local c = ensure_client()
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
--   jupynvim://psc/~/foo.py                →  "psc", "/~/foo.py"  (server expands ~)
function M._parse_uri(uri)
  local alias, path = uri:match("^jupynvim://([^/]+)(/.*)$")
  if alias and path then return alias, path end
  return nil
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

-- Debounced rewrite of cells' output REGIONS (real buffer lines) after
-- kernel events. Bottom-up so line numbers stay valid across edits.
local _out_sync = {}  -- buf -> { timer, ids }
function M._queue_output_sync(buf, nb, cell_id)
  local q = _out_sync[buf]
  if not q then q = { ids = {} }; _out_sync[buf] = q end
  q.ids[cell_id] = true
  if q.timer then return end
  q.timer = vim.uv.new_timer()
  q.timer:start(150, 0, vim.schedule_wrap(function()
    if q.timer then q.timer:stop(); q.timer:close(); q.timer = nil end
    local ids = q.ids
    q.ids = {}
    if not vim.api.nvim_buf_is_valid(buf) then return end
    M._apply_output_sync(nb, ids)
  end))
end

function M._apply_output_sync(nb, ids)
  local buf = nb.buf
  local CellMode = require("jupynvim.notebook.cellmode")
  local was_modifiable = vim.bo[buf].modifiable
  vim.bo[buf].modifiable = true
  local ranges = CellMode.ranges(buf)
  for i = #nb.cells, 1, -1 do
    local cell = nb.cells[i]
    if cell and ids[cell.id] and ranges[i] then
      local r = ranges[i]
      local rep = {}
      if cell.cell_type == "code" then
        local out_lines = Notebook.output_lines(cell)
        if #out_lines > 0 then
          rep = { Notebook.OUT_SEP }
          vim.list_extend(rep, out_lines)
        end
      end
      local s0 = r.out_sep or r.stop
      local e0 = r.out_stop or s0
      pcall(vim.api.nvim_buf_set_lines, buf, s0, e0, false, rep)
    end
  end
  vim.bo[buf].modifiable = not CellMode.is_command(buf) and was_modifiable or false
  if not CellMode.is_command(buf) then vim.bo[buf].modifiable = true end
  Render.refresh(nb, vim.fn.bufwinid(buf))
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
        M._queue_output_sync(buf, nb, p.cell_id)
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

-- Walk up from `start_dir` looking for a project venv python under `.venv`,
-- `venv`, or `env` (`Scripts\python.exe` on Windows). Return the python path
-- if the venv exists AND ipykernel is importable from it. nil otherwise.
local function find_local_venv_python(start_dir)
  local is_win = package.config:sub(1, 1) == "\\"
  local bin = is_win and "Scripts\\python.exe" or "bin/python"
  local dir = start_dir
  for _ = 1, 10 do
    for _, name in ipairs({ ".venv", "venv", "env" }) do
      local candidate = dir .. "/" .. name .. "/" .. bin
      if vim.fn.executable(candidate) == 1 then
        vim.fn.system({ candidate, "-c", "import ipykernel" })
        if vim.v.shell_error == 0 then return candidate end
        return nil  -- venv exists but no ipykernel - don't fall back silently
      end
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
  -- Route through the right client. opts.alias picks a specific remote
  -- backend (set by the URI handler / file browser for remote notebooks);
  -- without it, fall back to the local backend.
  if opts.alias then
    M.client = M.client_for(opts.alias)
  else
    ensure_client()
  end
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
      -- Already open: if a window already shows it, FOCUS that window (like
      -- <C-w>w to it) rather than re-displaying the buffer in the current
      -- window. Re-displaying (e.g. when the explorer opens the same file)
      -- duplicated the notebook into the explorer's pane and forced a stale
      -- re-render. Only fall back to set_current_buf when no window shows it.
      local wins = vim.fn.win_findbuf(existing_buf)
      if #wins > 0 then
        pcall(vim.api.nvim_set_current_win, wins[1])
      else
        vim.api.nvim_set_current_buf(existing_buf)
      end
      Render.refresh(existing_nb, vim.fn.bufwinid(existing_buf))
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
      pcall(function() require("jupynvim.notebook.image").clear_all() end)
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
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = true
  -- List it so it shows in the bufferline as a tab, like the .py/.rs files the
  -- explorer opens via :edit (bufnr(abs, true) creates it UNLISTED otherwise).
  vim.bo[buf].buflisted = true
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
    -- Force modifiable for the no-op insert: after :bd + reopen the reused
    -- buffer can come back with 'modifiable' off (cellmode leaves it off in
    -- command mode), which made this normal! a<BS> throw E21.
    local prev_mod = vim.bo[buf].modifiable
    vim.bo[buf].modifiable = true
    vim.bo[buf].undolevels = -1
    vim.api.nvim_buf_call(buf, function()
      vim.cmd('exe "normal! a \\<BS>\\<Esc>"')
    end)
    vim.bo[buf].undolevels = prev
    vim.bo[buf].modifiable = prev_mod
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
  require("jupynvim.notebook.cellmode").attach(buf, M)

  -- Display the buffer FIRST so we have a real window for the synchronous
  -- option-setting that follows. Without this, win_findbuf is empty and
  -- conceallevel doesn't get applied before the first redraw - which made
  -- the literal "# %%[jupynvim:cell-sep]" markers flash visible on open.
  vim.api.nvim_set_current_buf(buf)
  local cur_win = vim.api.nvim_get_current_win()
  M._disable_indent_guides(buf)

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
    -- nolist: a global `set list` (LazyVim sets it) renders the trailing
    -- spaces on blank output lines (the "  " from OUT_INDENT) as listchars
    -- `trail` dashes, which showed as stray gray "—" between output blocks.
    -- A rendered notebook view shouldn't show whitespace markers anyway.
    -- nocursorline: notebooks open in command mode where the cursor is hidden;
    -- cursorline would paint the parked cursor's line and fight the per-cell
    -- orange anchor. cellmode turns it back on for edit mode (active-line
    -- highlight, like VSCode) and off again on Esc back to command.
    vim.cmd("setlocal nolist nocursorline signcolumn=no conceallevel=2 concealcursor=nc wrap linebreak breakindent breakindentopt=min:2 nofoldenable foldmethod=manual")
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
  -- Restore where the cursor last sat (each cell's remembered line + the active
  -- position) from the sidecar, so reopening lands you where you left off.
  pcall(M._restore_cursor_positions, nb, buf, cur_win)

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
  -- Re-scope treesitter NOW. _populate_buffer already called this, but that
  -- ran before the filetype above attached the parser, so it was a no-op and
  -- treesitter would parse the whole buffer (markdown + separators + code)
  -- unscoped — which throws the Python parser into error recovery and the
  -- cells render plain. Re-run it here, after the parser exists, so code
  -- cells are highlighted even if no edit (which also re-syncs) ever happens.
  pcall(M._sync_treesitter_ranges, nb)

  -- Look up the kernel python BEFORE LSP attaches so we can inject
  -- settings.python.pythonPath + analysis.extraPaths into the config.
  -- basedpyright doesn't execute the interpreter to discover sys.path - it
  -- probes the filesystem under <pythonPath>/../lib/.../site-packages. With
  -- Homebrew Python that path is empty (numpy actually lives at
  -- /opt/homebrew/lib/python3.14/site-packages). We run the kernel python
  -- once to harvest its real site-packages directories.
  local py_path
  local extra_paths = {}
  local is_remote = opts.alias ~= nil
  -- Local-only: .venv discovery walks the local filesystem and the python
  -- introspection runs locally. For remote notebooks the kernel lives on the
  -- remote backend; the LSP work that wants sys.path won't make sense anyway
  -- until we implement Phase 6 (remote LSP relay). Skip both for now.
  if not is_remote then
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
    -- Belt-and-braces: even when is_remote is false, refuse to spawn a
    -- python that isn't executable here. A stale local kernelspec pointing
    -- at a remote-only path (PSC anaconda etc) was producing E475.
    if py_path and vim.fn.executable(py_path) == 1 then
      local sys_path = vim.fn.system({ py_path, "-c", "import sys; print('\\n'.join(p for p in sys.path if p))" })
      if vim.v.shell_error == 0 then
        for line in sys_path:gmatch("[^\r\n]+") do
          if line:find("site%-packages") or line:find("dist%-packages") then
            table.insert(extra_paths, line)
          end
        end
      end
    elseif py_path then
      Log.warn("kernel python path '" .. py_path .. "' is not executable locally; skipping sys.path probe")
      py_path = nil
    end
  end
  nb.kernel_python_path = py_path
  nb.kernel_extra_paths = extra_paths
  nb.alias = opts.alias
  vim.b[buf].jupynvim_alias = opts.alias
  M._attach_lsp(buf, ft, py_path, extra_paths)
  -- Kernel-backed completion + hover via virtual LSP. Language-agnostic:
  -- the kernel's complete_request/inspect_request handle the actual work,
  -- so the same code path serves Python, Julia, R, anything with a kernel.
  pcall(function()
    require("jupynvim.lsp.kernel").attach(buf,
      function() return Notebook.get(buf) end,
      function() return M.client end)
  end)

  Render.refresh(nb, cur_win)
  M._opening[abs] = nil

  -- Fast follow-up render + redraw. The first paint can be incomplete if the
  -- user fires a command the instant the notebook opens (e.g. run-all), so
  -- the frames look absent for a beat; this repaints once things settle. (It
  -- does not speed up treesitter's own async parse, which colors a little
  -- later on its own.)
  vim.defer_fn(function()
    if vim.api.nvim_buf_is_valid(buf) and vim.fn.bufwinid(buf) ~= -1 then
      pcall(M._sync_treesitter_ranges, nb)  -- backstop if the parser wasn't ready synchronously
      pcall(Render.refresh, nb, vim.fn.bufwinid(buf))
      pcall(vim.cmd, "redraw")
    end
  end, 120)

  -- Treesitter scoping can be reset asynchronously after open by an LSP
  -- attaching or the kernel starting (the "leader-nB too fast renders plain"
  -- path: running cells starts the kernel, which makes the LSP attach). We
  -- re-scope in those handlers, but the exact moment the reset lands is
  -- timing-dependent, so also run a couple of self-healing passes over the
  -- first second. _sync compares actual-vs-desired regions, so each pass is a
  -- cheap no-op (a row-signature compare, no re-parse) once scoping is correct.
  for _, delay in ipairs({ 400, 1000 }) do
    vim.defer_fn(function()
      if vim.api.nvim_buf_is_valid(buf) then pcall(M._sync_treesitter_ranges, nb) end
    end, delay)
  end

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
  vim.bo[nb.buf].modifiable = true
  vim.api.nvim_buf_set_lines(nb.buf, 0, -1, false, lines)
  vim.bo[nb.buf].modified = false
  -- cell command mode keeps the buffer non-modifiable; restore the lock
  -- after this (possibly async) repopulation
  if require("jupynvim.notebook.cellmode").is_command(nb.buf) then
    vim.bo[nb.buf].modifiable = false
  end
  -- Pre-conceal cell separator marker lines synchronously, before the
  -- debounced Render.refresh runs. Without this, the literal
  -- "# %%[jupynvim:cell-sep]" text flashes visible on screen for one or
  -- two redraw frames between buffer population and the first render.
  local sep = require("jupynvim.notebook").CELL_SEP
  local osep = require("jupynvim.notebook").OUT_SEP
  for i, line in ipairs(lines) do
    if line == sep or line == osep then
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
      vim.cmd("setlocal nolist signcolumn=no conceallevel=2 concealcursor=nc wrap linebreak breakindent breakindentopt=min:2,list:-1 nofoldenable foldmethod=manual nonumber relativenumber")
      -- The statuscolumn IS the cell gutter: per-cell line numbers,
      -- selection bar, and the cell's left border. The buffer number is
      -- baked in because the expression can evaluate while ANOTHER window
      -- is current. 'relativenumber' stays on only so cursor movement
      -- triggers gutter redraws; the gutter computes its own numbers.
      vim.opt_local.statuscolumn =
        string.format("%%!v:lua.require'jupynvim.notebook.cellmode'.statuscol(%d)", nb.buf)
      -- hanging indents for wrapped markdown list items
      vim.opt_local.formatlistpat = [[^\s*\(\d\+[.)]\|[-*+]\)\s\+]]
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
  -- When the treesitter highlighter is active, turn off Vim's regex syntax.
  -- They otherwise both run: treesitter (scoped to code cells below) colors the
  -- code, while vim syntax knows nothing about our cell/output regions and
  -- paints every output line that starts with "#" as pythonComment, so printed
  -- output like `# transpose` rendered gray. Treesitter alone is enough; gate
  -- on the highlighter being active so configs without treesitter highlighting
  -- keep their syntax-based colors (the output mask uses hl_mode=replace, which
  -- covers that case too). Re-checked on every sync, so a filetype re-set that
  -- reloads syntax gets corrected on the next pass.
  pcall(function()
    local hltr = vim.treesitter.highlighter
    if hltr and hltr.active and hltr.active[nb.buf] and vim.bo[nb.buf].syntax ~= "" then
      vim.bo[nb.buf].syntax = ""
    end
  end)
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
  -- Re-scope only when the parser isn't already scoped the way we want, but
  -- decide that by comparing our desired regions against the parser's CURRENT
  -- included_regions rather than a cached copy of our own last value.
  -- Something external resets the regions to the whole buffer after open — an
  -- LSP attaching, the kernel starting, or nvim-treesitter re-initialising the
  -- parser when FileType fires — and a self-keyed cache never notices, so the
  -- re-sync no-ops and the cells parse as plain markdown+separator+code soup
  -- (the "leader-nB too fast renders plain" report). Comparing actual-vs-
  -- desired self-heals after any such reset while still skipping the genuine
  -- no-op case, so we don't force a full tree invalidation on every keystroke
  -- (which races indentexpr: treesitter indent returns -1 against a freshly
  -- invalidated tree, dropping autoindent after `:`). Byte offsets shift on
  -- every keystroke, so compare row boundaries only — treesitter's own
  -- incremental parser handles intra-line edits inside an existing region.
  local function row_signature(regs)
    local parts = {}
    for i, region in ipairs(regs) do
      local rng = region[1]
      if rng then parts[i] = (rng[1] or 0) .. ":" .. (rng[4] or 0) end
    end
    return table.concat(parts, ",")
  end
  local want_sig = row_signature(regions)
  local ok_cur, current = pcall(parser.included_regions, parser)
  local have_sig = ok_cur and row_signature(current) or nil
  if want_sig == have_sig then return end
  pcall(parser.set_included_regions, parser, regions)
end

-- Indent-guide plugins (snacks.indent, mini.indentscope, indent-blankline)
-- draw guides from leading whitespace. Our output lines are indented two
-- spaces, so the blank lines between output blocks pick up stray guide marks
-- (the "gray dashes between each \n"). A notebook buffer renders its own
-- structure, so turn those plugins off per-buffer. Each is a no-op if the
-- plugin isn't installed.
function M._disable_indent_guides(buf)
  pcall(function() vim.b[buf].snacks_indent = false end)
  pcall(function() vim.b[buf].miniindentscope_disable = true end)
  pcall(function() vim.b[buf].indent_blankline_enabled = false end)
  pcall(function() require("ibl").setup_buffer(buf, { enabled = false }) end)
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
        -- Re-setting filetype above (when something knocked it off "python")
        -- re-fires FileType, which makes nvim-treesitter rebuild the parser
        -- with the whole buffer as one region — the cells then render as plain
        -- markdown+code soup. Re-scope to code cells. _sync is self-healing, so
        -- this is a cheap no-op (a row-signature compare, no re-parse) whenever
        -- the regions are already correct.
        local nb_for_ts = Notebook.get(buf)
        if nb_for_ts then pcall(M._sync_treesitter_ranges, nb_for_ts) end
        M._disable_indent_guides(buf)  -- snacks/ibl re-enable per event; reassert
        local wins = vim.fn.win_findbuf(buf)
        for _, win in ipairs(wins) do
          vim.api.nvim_win_call(win, function()
            vim.cmd("setlocal nolist signcolumn=no conceallevel=2 concealcursor=nc wrap linebreak breakindent breakindentopt=min:2,list:-1 nofoldenable foldmethod=manual nonumber relativenumber")
            -- buffer number baked in: the expression can evaluate while
            -- ANOTHER window is current (see _populate_buffer)
            vim.opt_local.statuscolumn =
              string.format("%%!v:lua.require'jupynvim.notebook.cellmode'.statuscol(%d)", buf)
            -- hanging indents for wrapped markdown list items
            vim.opt_local.formatlistpat = [[^\s*\(\d\+[.)]\|[-*+]\)\s\+]]
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
      pcall(M._persist_cursor_positions, nb, buf)
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
          require("jupynvim.lsp.notebook").on_attach(buf, nb, client)
        end)
      end
      if nb and nb.kernel_python_path then
        vim.schedule(function()
          M._sync_lsp_python_path(buf, nb.kernel_python_path, nb.kernel_extra_paths)
        end)
      end
      -- An attaching LSP (and the nvim-treesitter FileType handling it can
      -- trigger) often resets the parser's included_regions back to the whole
      -- buffer, so code cells render plain until the next edit — this is the
      -- "leader-nB too fast renders plain" path, since running cells starts the
      -- kernel which is what makes the LSP attach. Re-scope once the attach
      -- settles. _sync is self-healing, so it's a no-op when nothing reset it.
      if nb then
        vim.schedule(function()
          if vim.api.nvim_buf_is_valid(buf) then pcall(M._sync_treesitter_ranges, nb) end
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
          pcall(vim.api.nvim_set_option_value, "modified", true, { buf = buf })
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
      local Embedded = require("jupynvim.notebook.embedded")
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
        pcall(vim.api.nvim_set_option_value, "modified", true, { buf = buf })
      end
      Render.refresh(nb, vim.fn.bufwinid(buf))
      M._sync_treesitter_ranges(nb)
      -- Push cell-array diff to notebook-aware LSPs (ty etc.).
      pcall(function() require("jupynvim.lsp.notebook").on_text_change(buf, nb) end)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group, buffer = buf,
    callback = function()
      local nb = Notebook.get(buf)
      if nb and nb.session_id then
        ensure_client():call("close", { session_id = nb.session_id }, function() end)
      end
      pcall(function() require("jupynvim.lsp.notebook").on_close(buf) end)
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

-- Persist where the cursor last sat in each cell + the active position, to a
-- sidecar state file, so reopening this notebook restores it (see
-- _restore_cursor_positions). Called on save and on quit.
-- Cell identity for the sidecar: in-memory cell ids are regenerated on every
-- open (they aren't written to disk), so they can't key positions across a
-- reopen. We key by cell INDEX and validate with the cell's first source line
-- as a fingerprint, so a structurally-changed notebook won't restore a position
-- into the wrong cell (the fingerprint won't match -> we skip it).
local function _cell_fp(buf, r)
  return vim.api.nvim_buf_get_lines(buf, r.start, r.start + 1, false)[1] or ""
end

function M._persist_cursor_positions(nb, buf)
  if not (nb and buf and vim.api.nvim_buf_is_valid(buf)) then return end
  local key = vim.api.nvim_buf_get_name(buf)
  if not key or key == "" then return end
  local CellMode = require("jupynvim.notebook.cellmode")
  local ranges = CellMode.ranges(buf)
  local entry = { cells = {} }
  for idx, pos in pairs(CellMode.get_positions(buf)) do
    local r = ranges[idx]
    if r and pos[1] then
      table.insert(entry.cells,
        { idx = idx, line = pos[1] - 1 - r.start, col = pos[2] or 0, fp = _cell_fp(buf, r) })
    end
  end
  local win = vim.fn.bufwinid(buf)
  if win ~= -1 then
    local cl = vim.api.nvim_win_get_cursor(win)
    local idx = CellMode.cell_idx_at(buf, cl[1])
    local r = ranges[idx]
    if r then
      entry.last = { idx = idx, line = cl[1] - 1 - r.start, col = cl[2], fp = _cell_fp(buf, r) }
    end
  end
  pcall(require("jupynvim.notebook.cursor_persist").save, key, entry)
end

-- Restore per-cell remembered lines (the orange anchors) and the active cursor
-- from the sidecar, after the notebook is populated + attached on open.
function M._restore_cursor_positions(nb, buf, win)
  if not (nb and buf and vim.api.nvim_buf_is_valid(buf)) then return end
  local entry = require("jupynvim.notebook.cursor_persist").load(vim.api.nvim_buf_get_name(buf))
  if not entry then return end
  local CellMode = require("jupynvim.notebook.cellmode")
  local ranges = CellMode.ranges(buf)
  local function clamp(r, off)
    return math.max(r.start + 1, math.min(r.start + (off or 0) + 1, r.stop))
  end
  for _, c in ipairs(entry.cells or {}) do
    local r = ranges[c.idx]
    if r and _cell_fp(buf, r) == c.fp then
      CellMode.set_position(buf, c.idx, clamp(r, c.line), c.col or 0)
    end
  end
  if entry.last and win and win ~= -1 then
    local r = ranges[entry.last.idx]
    if r and _cell_fp(buf, r) == entry.last.fp then
      pcall(vim.api.nvim_win_set_cursor, win, { clamp(r, entry.last.line), entry.last.col or 0 })
    end
  end
end

function M._save(nb)
  nb:sync_from_buffer()
  local cl = ensure_client()
  local Embedded = require("jupynvim.notebook.embedded")
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
    vim.bo[nb.buf].modified = false
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
  local cl = nb_client(nb)
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
      -- "kernel not started" alone is unactionable. While a start is in
      -- flight (first use may be pip-installing ipykernel into the env),
      -- say so calmly; otherwise append the actual start failure.
      if err2 and tostring(err2):find("kernel not started") then
        if nb.kernel_starting then
          vim.notify("jupynvim: kernel is still starting (first use of an env may install ipykernel; can take a minute). Run the cell again once \"kernel started\" appears.",
            vim.log.levels.WARN)
          return
        elseif nb.kernel_error then
          err2 = tostring(err2) .. "\n  last start_kernel error: " .. nb.kernel_error
        end
      end
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
  local cl = nb_client(nb)
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
  local cl = nb_client(nb)
  local co
  co = coroutine.wrap(function()
    for _, c in ipairs(nb.cells) do
      if c.id == cur_id then break end
      if c.cell_type == "code" then
        cl:call("update_cell_source", { session_id = nb.session_id, cell_id = c.id, source = c.source }, function()
          cl:call("execute", { session_id = nb.session_id, cell_id = c.id }, function()
            co()
          end)
        end)
        coroutine.yield()
      end
    end
  end)
  co()
end

function M.run_below(buf)
  local nb = Notebook.get(buf)
  if not nb then return end
  nb:sync_from_buffer()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local cur_id = nb:cell_at_line(lnum)
  local seen = false
  local cl = nb_client(nb)
  local co
  co = coroutine.wrap(function()
    for _, c in ipairs(nb.cells) do
      if c.id == cur_id then seen = true end
      if seen and c.cell_type == "code" then
        cl:call("update_cell_source", { session_id = nb.session_id, cell_id = c.id, source = c.source }, function()
          cl:call("execute", { session_id = nb.session_id, cell_id = c.id }, function()
            co()
          end)
        end)
        coroutine.yield()
      end
    end
  end)
  co()
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
  pcall(vim.api.nvim_set_option_value, "modified", true, { buf = buf })
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
  -- Route to the alias's backend if this is a remote notebook. Without
  -- this, ensure_client() would return whatever M.client happens to point
  -- at, which can race if multiple notebooks across aliases are open.
  local cl = nb.alias and M.client_for(nb.alias) or ensure_client()
  -- Auto-venv, local flavor: probe the local filesystem and pass the python
  -- directly. For REMOTE notebooks the backend does the equivalent walk-up on
  -- its own filesystem when we pass auto_venv (same .venv/venv/env semantics).
  local python_path = nil
  if not kernel_name and M.config.auto_venv ~= false and not nb.alias then
    local nb_dir = nb.path and vim.fn.fnamemodify(nb.path, ":h") or nil
    if nb_dir then
      python_path = find_local_venv_python(nb_dir)
      if python_path then
        Log.info("auto_venv: using " .. python_path)
      end
    end
  end
  nb.kernel_starting = true
  cl:call("start_kernel", {
    session_id = nb.session_id,
    kernel_name = kernel_name,
    python_path = python_path,
    auto_venv = M.config.auto_venv ~= false,
  }, function(err, res)
    nb.kernel_starting = nil
    if err then
      nb.kernel_error = tostring(err)  -- surfaced by later "kernel not started"
      vim.notify("start_kernel: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    nb.kernel_error = nil
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
    -- matches what `pip list` in that env reports. Local-only — the LSP
    -- runs on the user's machine and can't introspect a remote python.
    -- Phase 6 (remote LSP relay) will be the right path for remote.
    if nb.alias then return end
    cl:call("list_kernels", {}, function(_, kernels)
      if not kernels then return end
      local active = res.kernel_name
      for _, k in ipairs(kernels) do
        -- argv is typically ["/path/to/python", "-m", "ipykernel_launcher", ...]
        -- Lua's 1-based indexing -> argv[1] is the python interpreter.
        if k.name == active and k.argv and k.argv[1] then
          local py = k.argv[1]
          nb.kernel_python_path = py
          -- Defensive: don't try to run a python path that isn't here
          if vim.fn.executable(py) ~= 1 then return end
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
  local Image = require("jupynvim.notebook.image")
  nb.image_ids = nb.image_ids or {}
  for _, c in ipairs(nb.cells) do
    if c.cell_type == "code" then
      c.outputs = {}
      c.execution_count = nil
      -- also drop the execution-timing stamp, else saved_duration_ns rebuilds
      -- the "✓ 1.6s" badge from it after the clear
      if type(c.metadata) == "table" then c.metadata.execution = nil end
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
  if type(cell.metadata) == "table" then cell.metadata.execution = nil end
  nb.cell_state[cell.id] = nil
  pcall(require("jupynvim.notebook.image").clear_for_cell, cell.id)
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
  local Embedded = require("jupynvim.notebook.embedded")
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
    pcall(require("jupynvim.notebook.image").clear_for_cell, cell.id)
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
  -- Route to the notebook's OWN backend (a remote notebook lists kernels on
  -- the remote, incl. its conda envs), and pass the notebook's dir so
  -- project-local venvs (.venv/venv/env) show up as picker entries.
  local nb = Notebook.get(buf)
  local cl = (nb and nb.alias) and M.client_for(nb.alias) or ensure_client()
  local dir = nb and nb.path and vim.fn.fnamemodify(nb.path, ":h") or nil
  cl:call("list_kernels", { dir = dir }, function(err, kernels)
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
local function _has_output(cell)
  return cell and cell.cell_type == "code" and cell.outputs and #cell.outputs > 0
end

-- <C-j>: enter the current cell's output (or the NEXT cell's output if
-- the current cell has none). <C-k>: enter the PREVIOUS cell's output
-- so when the cursor is below an output region, this key enters that
-- region. From inside the scratch split, either key (or q) returns.
function M.enter_output(buf, direction)
  local nb = Notebook.get(buf)
  if not nb then return end
  local CellMode = require("jupynvim.notebook.cellmode")
  -- command mode: C-j/C-k are plain window navigation (terminal/explorer
  -- round-trips). Inside a cell: hop between the source editor and its
  -- output region, which is REAL buffer text (motions/visual/yank native).
  if CellMode.is_command(buf) then
    vim.cmd("wincmd " .. (direction == "up" and "k" or "j"))
    return
  end
  if direction == "up" then
    CellMode.focus_source(buf)
  else
    CellMode.focus_output(buf)
  end
end

-- gx on a rendered markdown link: the URL part is concealed, so resolve
-- the link under the cursor from the raw line and open it.
function M.open_link(buf)
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1
  local l = require("jupynvim.notebook.markdown").link_at(line, col)
  if l and l.url and l.url ~= "" then
    if l.url:match("^jupynvim%-img:") then
      vim.notify("jupynvim: embedded image (<leader>nI saves it to a file)", vim.log.levels.INFO)
      return
    end
    vim.ui.open(l.url)
    local shown = #l.url > 70 and (l.url:sub(1, 70) .. "…") or l.url
    vim.notify("jupynvim: opening " .. shown, vim.log.levels.INFO)
    return
  end
  local cf = vim.fn.expand("<cfile>")
  if cf and cf ~= "" then pcall(vim.ui.open, cf) end
end

-- Open the markdown link under the MOUSE pointer. Used by the
-- <LeftRelease> mapping in command mode, where rendered markdown isn't
-- cursor-addressable (j/k jump whole cells), so a click is how links get
-- followed, like VSCode's rendered view. Returns true when a link was
-- opened so the mapping swallows that click.
function M.click_link(buf)
  local ok, mp = pcall(vim.fn.getmousepos)
  if not ok or not mp or not mp.line or mp.line == 0 then return false end
  if not mp.winid or mp.winid == 0 then return false end
  local wok, wbuf = pcall(vim.api.nvim_win_get_buf, mp.winid)
  if not wok or wbuf ~= buf then return false end
  local line = (vim.api.nvim_buf_get_lines(buf, mp.line - 1, mp.line, false))[1]
  if not line or line == "" then return false end
  -- link_at falls back to the line's first link, which absorbs the
  -- column drift that concealed URLs introduce under the mouse position
  local l = require("jupynvim.notebook.markdown").link_at(line, math.max(mp.column or 1, 1))
  if not (l and l.url and l.url ~= "") or l.url:match("^jupynvim%-img:") then
    return false
  end
  pcall(vim.ui.open, l.url)
  local shown = #l.url > 70 and (l.url:sub(1, 70) .. "…") or l.url
  vim.notify("jupynvim: opening " .. shown, vim.log.levels.INFO)
  return true
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
    local imgs = require("jupynvim.notebook.embedded").list_images(cell.id) or {}
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

  local Embedded = require("jupynvim.notebook.embedded")
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

-- Deep-merge user opts into config: nested MAPS merge recursively (so e.g.
-- terminal = { bottom_height = 12 } keeps the other terminal defaults), while
-- key-LIST arrays (explorer_keys, terminal_keys, pick_keys.*) are replaced
-- wholesale (so you set exactly the keys you want). Makes every option
-- independently overridable.
local function deep_merge(dst, src)
  for k, v in pairs(src) do
    if type(v) == "table" and type(dst[k]) == "table"
       and not vim.islist(v) and not vim.islist(dst[k]) then
      dst[k] = deep_merge(vim.deepcopy(dst[k]), v)
    else
      dst[k] = v
    end
  end
  return dst
end

function M.setup(opts)
  M.config = deep_merge(M.config, opts or {})
  Log.set_level(M.config.log_level)
  Render.setup_highlights()
  -- A `:colorscheme` runs `hi clear`, wiping our groups (and the
  -- JupynvimOutputText -> Normal link). Re-establish them on every
  -- colorscheme change so output text never falls back to a stale color.
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("jupynvim_colors", { clear = true }),
    callback = function() pcall(Render.setup_highlights) end,
  })
  -- Keep indent-guide plugins (snacks.indent etc.) off notebook buffers. This
  -- catches buffers already open when the plugin (re)loads and re-asserts on
  -- every notebook display, so it works even on a hot reload without reopening
  -- (M.open's call only covers fresh opens).
  vim.api.nvim_create_autocmd({ "BufWinEnter", "BufEnter", "FileType" }, {
    group = vim.api.nvim_create_augroup("jupynvim_indent_guards", { clear = true }),
    callback = function(ev)
      if require("jupynvim.notebook").get(ev.buf) then
        M._disable_indent_guides(ev.buf)
        -- nolist on the notebook window: a global `set list` renders the
        -- trailing spaces of blank output lines as gray `trail` dashes.
        pcall(function() vim.wo.list = false end)
      end
    end,
  })
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if require("jupynvim.notebook").get(b) then pcall(M._disable_indent_guides, b) end
  end
  require("jupynvim.notebook.diag").setup()
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

  -- Decide the mode of each global dispatch key (see M._dispatch_bind). Run on
  -- User VeryLazy so it lands AFTER a distro sets its own <leader>e, otherwise
  -- we would read "you have no mapping" and claim the key for good.
  local bind_dispatch_keys = M._dispatch_bind
  local pk = M.config.pick_keys or {}
  if (M.config.explorer_keys and #M.config.explorer_keys > 0)
     or (M.config.terminal_keys and #M.config.terminal_keys > 0)
     or (M.config.terminal_right_keys and #M.config.terminal_right_keys > 0)
     or (pk.files and #pk.files > 0) or (pk.grep and #pk.grep > 0) then
    -- LazyVim registers <leader>e / <C-/> via snacks' `keys` spec, and
    -- lazy.nvim sets those at startup. We must bind AFTER that or LazyVim
    -- wins. Bind on VeryLazy AND on a 500ms timer (belt + braces) to land last.
    vim.api.nvim_create_autocmd("User", {
      pattern = "VeryLazy",
      once = true,
      callback = function() vim.defer_fn(bind_dispatch_keys, 100) end,
    })
    vim.defer_fn(bind_dispatch_keys, 500)
    bind_dispatch_keys()
  end

  -- Hijack .ipynb opens
  local group = vim.api.nvim_create_augroup("JupynvimDispatch", { clear = true })
  vim.api.nvim_create_autocmd("BufReadCmd", {
    group = group,
    pattern = { "*.ipynb" },
    callback = function(args)
      -- Skip jupynvim:// URIs — they're handled by our dedicated URI BufReadCmd
      -- (registered below) which routes through the alias's remote backend
      -- and passes opts.alias to M.open. This pattern would otherwise call
      -- M.open with no alias and the local client, trying to run remote
      -- paths through local fs ops.
      if args.file:match("^jupynvim://") then return end
      -- BufReadCmd means user wants to read this file. If we already have a
      -- live notebook for it, treat as :e! (force reload from disk).
      local abs = vim.fn.fnamemodify(args.file, ":p")
      -- Skip if M.open is mid-flight for this path — it created the buffer
      -- itself via vim.fn.bufnr(true) and is about to populate it.
      if M._opening and M._opening[abs] then return end
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
      -- Skip URIs (handled by the dedicated jupynvim:// autocmd).
      if args.file:match("^jupynvim://") then return end
      -- Skip if our M.open is mid-flight for this path — it creates the
      -- buffer via vim.fn.bufnr(abs, true), which triggers BufNewFile.
      -- Re-entering M.open here would race with the in-progress one,
      -- wipe its alias tagging, and (worst) drop the remote-backend route.
      local abs = vim.fn.fnamemodify(args.file, ":p")
      if M._opening and M._opening[abs] then return end
      vim.schedule(function() M.open(args.file) end)
    end,
  })

  -- ===========================================================
  -- Remote URI scheme: jupynvim://<alias>/<path>
  --
  -- Any buffer whose name matches this scheme is fetched/saved via the
  -- alias's backend (M.client_for(alias)) using fs_read/fs_write RPCs.
  -- Works for any file type. .ipynb gets routed to M.open instead so the
  -- notebook flow takes over.
  -- ===========================================================
  vim.api.nvim_create_autocmd("BufReadCmd", {
    group = group,
    pattern = "jupynvim://*",
    callback = function(args)
      local alias, path = M._parse_uri(args.file)
      if not alias then
        vim.notify("jupynvim: invalid URI " .. args.file, vim.log.levels.ERROR)
        return
      end
      local ok, client = pcall(M.client_for, alias)
      if not ok then
        vim.notify("jupynvim: " .. tostring(client), vim.log.levels.ERROR)
        return
      end
      -- Directory (URI ends in /): open the tree explorer rooted there.
      -- Wipe the throwaway URI buffer first; the explorer makes its own.
      if path:sub(-1) == "/" then
        local dir = path:gsub("/+$", "")
        if dir == "" then dir = "/" end
        local uri_buf = args.buf
        vim.schedule(function()
          if vim.api.nvim_buf_is_valid(uri_buf) then
            pcall(vim.api.nvim_buf_delete, uri_buf, { force = true })
          end
          M.remote_browse(alias, dir)
        end)
        return
      end
      -- Notebook: hand off to the notebook open flow. The notebook flow
      -- creates its own buffer (named with the remote path), so wipe the
      -- empty URI buffer we just created — otherwise we get an orphan
      -- "jupynvim://..." buffer alongside the real notebook buffer.
      if path:sub(-6) == ".ipynb" then
        local uri_buf = args.buf
        vim.schedule(function()
          if vim.api.nvim_buf_is_valid(uri_buf) then
            pcall(vim.api.nvim_buf_delete, uri_buf, { force = true })
          end
          M.use_remote(alias)
          M.open(path, { alias = alias })
        end)
        return
      end
      -- Regular file: fs_read then populate the buffer.
      local err, res = client:call_sync("fs_read", { path = path }, 30000)
      local lines
      if err then
        -- "No such file" is expected when editing a new remote file
        -- (BufReadCmd fires before the user starts typing). Treat as empty
        -- buffer rather than error so :w later creates the file.
        if tostring(err):lower():find("no such file") then
          lines = { "" }
        else
          vim.notify("jupynvim: fs_read failed: " .. tostring(err), vim.log.levels.ERROR)
          return
        end
      else
        local content = vim.base64.decode(res.content_b64)
        lines = vim.split(content, "\n", { plain = true })
        -- vim.split with trailing \n produces a phantom empty string; drop
        -- it so the buffer matches the file exactly.
        if #lines > 0 and lines[#lines] == "" then
          table.remove(lines, #lines)
        end
      end
      vim.api.nvim_buf_set_lines(args.buf, 0, -1, false, lines)
      vim.bo[args.buf].buftype = "acwrite"
      vim.bo[args.buf].swapfile = false  -- buffer content lives on the remote, no need for local swap
      vim.bo[args.buf].modified = false
      vim.b[args.buf].jupynvim_alias = alias
      vim.b[args.buf].jupynvim_remote_path = path
      -- Filetype detection → syntax, treesitter, ftplugin (indent etc).
      local ft = vim.filetype.match({ filename = path, buf = args.buf })
      if ft then vim.bo[args.buf].filetype = ft end
      -- Remote LSP: attach a language server running ON the remote (Phase 6).
      -- Deferred so the buffer/filetype are fully settled first.
      if ft and ft ~= "" then
        local b = args.buf
        vim.schedule(function()
          if vim.api.nvim_buf_is_valid(b) then
            pcall(function() require("jupynvim.remote.lsp").attach(b, alias, path, ft) end)
          end
        end)
      end
      -- The file often opens into a window that the dashboard/explorer left
      -- with number/signcolumn OFF — restore the user's normal display opts
      -- so a remote .py/.cpp looks like a normal buffer (line numbers etc).
      local w = vim.api.nvim_get_current_win()
      if vim.api.nvim_win_get_buf(w) == args.buf then
        vim.wo[w].number = vim.go.number
        vim.wo[w].relativenumber = vim.go.relativenumber
        vim.wo[w].signcolumn = "yes"
        vim.wo[w].cursorline = vim.go.cursorline
        vim.wo[w].foldcolumn = vim.go.foldcolumn
        vim.wo[w].winfixwidth = false
        vim.wo[w].list = vim.go.list
        vim.wo[w].wrap = vim.go.wrap
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    pattern = "jupynvim://*",
    callback = function(args)
      local alias = vim.b[args.buf].jupynvim_alias
      local path = vim.b[args.buf].jupynvim_remote_path
      if not alias or not path then
        vim.notify("jupynvim: buffer missing remote metadata", vim.log.levels.ERROR)
        return
      end
      local client = M.client_for(alias)
      local lines = vim.api.nvim_buf_get_lines(args.buf, 0, -1, false)
      local content = table.concat(lines, "\n") .. "\n"
      local b64 = vim.base64.encode(content)
      local err, _ = client:call_sync("fs_write",
        { path = path, content_b64 = b64 }, 30000)
      if err then
        vim.notify("jupynvim: fs_write failed: " .. tostring(err), vim.log.levels.ERROR)
        return
      end
      vim.bo[args.buf].modified = false
      vim.notify(string.format("written %d lines to %s:%s", #lines, alias, path),
                 vim.log.levels.INFO)
    end,
  })

  -- Guard: Neovim 0.11's vim.lsp auto-enable may try to attach the user's
  -- LOCAL language servers to a jupynvim:// buffer (same filetype). Those
  -- can't read the remote file and would duplicate our relay. Detach any
  -- non-jupynvim client from a jupynvim:// buffer; our relay clients are
  -- named "jupynvim:..." and are kept.
  vim.api.nvim_create_autocmd("LspAttach", {
    group = group,
    callback = function(args)
      local name = vim.api.nvim_buf_get_name(args.buf)
      if not name:match("^jupynvim://") then return end
      local client = vim.lsp.get_client_by_id(args.data.client_id)
      if client and not client.name:match("^jupynvim:") then
        pcall(vim.lsp.buf_detach_client, args.buf, args.data.client_id)
      end
    end,
  })

  -- Remote FILE buffers (not the explorer tree / dashboard) should look like
  -- normal editable files: restore the window's display options every time the
  -- buffer is shown. BufWinEnter is the reliable place (the BufReadCmd reset
  -- can run before the window actually displays the buffer, and the file often
  -- lands in a window the dashboard/explorer left with number/signcolumn off).
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    pattern = "jupynvim://*",
    callback = function(args)
      if vim.b[args.buf].jupynvim_browser or vim.b[args.buf].jupynvim_dashboard then return end
      local w = vim.api.nvim_get_current_win()
      if vim.api.nvim_win_get_buf(w) ~= args.buf then return end
      vim.wo[w].number = vim.go.number
      vim.wo[w].relativenumber = vim.go.relativenumber
      vim.wo[w].signcolumn = "yes"
      vim.wo[w].cursorline = vim.go.cursorline
      vim.wo[w].foldcolumn = vim.go.foldcolumn
      vim.wo[w].winfixwidth = false
      vim.wo[w].wrap = vim.go.wrap
      vim.wo[w].list = vim.go.list
    end,
  })

  -- :JupynvimGrep <alias> <pattern>  — ripgrep-equivalent on remote.
  -- Populates the quickfix list with matches. Uses the search RPC (ignore +
  -- regex on the backend — no remote ripgrep binary required). Search root
  -- defaults to the remote home; pass `:JupynvimGrep alias pattern path` to
  -- scope it.
  vim.api.nvim_create_user_command("JupynvimGrep", function(o)
    local parts = vim.split(o.args, " ", { trimempty = true })
    if #parts < 2 then
      vim.notify("usage: :JupynvimGrep <alias> <pattern> [<path>]", vim.log.levels.WARN)
      return
    end
    local alias = parts[1]
    local pattern = parts[2]
    local path = parts[3] or "~"
    local client = M.client_for(alias)
    vim.notify("jupynvim: searching " .. alias .. ":" .. path .. " for " .. pattern)
    client:call("search", { path = path, pattern = pattern }, function(err, res)
      if err then
        vim.notify("jupynvim: search failed: " .. tostring(err), vim.log.levels.ERROR)
        return
      end
      vim.schedule(function()
        local qf = {}
        for _, m in ipairs(res.matches or {}) do
          table.insert(qf, {
            filename = "jupynvim://" .. alias .. m.path,
            lnum = m.line,
            col = m.col,
            text = m.text,
          })
        end
        vim.fn.setqflist({}, "r", {
          title = string.format("jupynvim %s:%s `%s`", alias, path, pattern),
          items = qf,
        })
        local msg = string.format("found %d matches%s", #qf, res.truncated and " (truncated)" or "")
        vim.notify(msg, vim.log.levels.INFO)
        if #qf > 0 then vim.cmd("copen") end
      end)
    end)
  end, {
    nargs = "+",
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

  -- :JupynvimTerm <alias>  — open a PTY-backed remote shell in a split.
  -- :JupynvimTerm [alias] [below|left|right|tab]
  --   Opens a plain remote shell. With a position it's an extra terminal
  --   alongside the <C-/> one (e.g. `:JupynvimTerm psc right` for a second
  --   shell on the right to use however you like); bare form opens/uses the
  --   primary <C-/> terminal.
  vim.api.nvim_create_user_command("JupynvimTerm", function(o)
    local parts = vim.split(o.args or "", "%s+", { trimempty = true })
    local alias = parts[1] or M._active_alias
    if not alias or alias == "" then
      vim.notify("usage: :JupynvimTerm <alias> [below|left|right|tab]", vim.log.levels.WARN)
      return
    end
    local positions = { below = true, left = true, right = true, tab = true }
    local split = (parts[2] and positions[parts[2]]) and parts[2] or "below"
    require("jupynvim.remote.term").toggle(alias, { split = split })
  end, {
    nargs = "*",
    complete = function(_, line)
      local words = vim.split(line, "%s+", { trimempty = true })
      if #words <= 2 then
        local names = {}
        for name, _ in pairs(M.config.remote or {}) do table.insert(names, name) end
        return names
      elseif #words == 3 then
        return { "below", "left", "right", "tab" }
      end
      return {}
    end,
  })

  -- :JupynvimEdit <alias>:<path>  — convenience wrapper for opening a remote
  -- file. Equivalent to `:e jupynvim://<alias>/<path>` (which also works).
  vim.api.nvim_create_user_command("JupynvimEdit", function(o)
    local alias, path = o.args:match("^([^:]+):(.+)$")
    if not alias or not path then
      vim.notify("usage: :JupynvimEdit <alias>:<path>", vim.log.levels.WARN)
      return
    end
    if not path:match("^/") then path = "/" .. path end  -- relative → home-relative
    vim.cmd("edit jupynvim://" .. alias .. path)
  end, {
    nargs = 1,
    complete = function(_, line)
      local words = vim.split(line, " ", { trimempty = true })
      if #words <= 2 and not line:find(":") then
        local names = {}
        for name, _ in pairs(M.config.remote or {}) do table.insert(names, name) end
        return names
      end
      return {}
    end,
  })

  vim.api.nvim_create_user_command("JupynvimImageMode", function(o)
    local mode = o.args:match("^%s*(%S+)%s*$") or ""
    if mode ~= "chafa" and mode ~= "kitty" and mode ~= "placeholder" then
      vim.notify("Usage: :JupynvimImageMode chafa|kitty|placeholder", vim.log.levels.WARN)
      return
    end
    M.config.image_renderer = mode
    pcall(function() require("jupynvim.notebook.image").clear_all() end)
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

  -- :JupynvimDebugFrames — dump the exact frame state so a broken render can
  -- be diagnosed without screenshots. Run it right after the breakage.
  vim.api.nvim_create_user_command("JupynvimDebugFrames", function()
    local buf = vim.api.nvim_get_current_buf()
    local nb = Notebook.get(buf)
    if not nb then print("not a jupynvim buffer"); return end
    local CellMode = require("jupynvim.notebook.cellmode")
    local win = vim.fn.bufwinid(buf)
    local info = win ~= -1 and vim.fn.getwininfo(win)[1] or {}
    local out = {}
    table.insert(out, string.format("win=%d width=%s textoff=%s win_get_width=%s wins_showing_buf=%s",
      win, tostring(info.width), tostring(info.textoff),
      tostring(win ~= -1 and vim.api.nvim_win_get_width(win)), vim.inspect(vim.fn.win_findbuf(buf))))
    -- collect header/footer extmark widths per row
    local marks = vim.api.nvim_buf_get_extmarks(buf, nb.border_ns, 0, -1, { details = true })
    local frames = {}
    for _, m in ipairs(marks) do
      for _, vl in ipairs(m[4].virt_lines or {}) do
        local s = ""
        for _, c in ipairs(vl) do s = s .. (c[1] or "") end
        if s:find("#%d") or s:find("Python") or s:find("Markdown") then
          table.insert(frames, string.format("  row %d  width=%d  %q", m[2], vim.fn.strwidth(s), s:sub(1, 24)))
        end
      end
    end
    table.insert(out, "frames (want width == win width " .. tostring(info.width) .. "):")
    vim.list_extend(out, frames)
    -- statuscolumn sample for the first source line of each cell
    for i, r in ipairs(CellMode.ranges(buf)) do
      local sc = CellMode._statuscol_for(buf, r.start + 1, 0):gsub("%%#%w+#", ""):gsub("%%%*", "")
      table.insert(out, string.format("  cell %d line %d statuscol=%q", i, r.start + 1, sc))
    end
    local msg = table.concat(out, "\n")
    print(msg)
    -- also stash to a register + a file so it's easy to copy
    pcall(vim.fn.setreg, "+", msg)
    pcall(function()
      local f = io.open(vim.fn.stdpath("cache") .. "/jupynvim_debug.txt", "w")
      if f then f:write(msg); f:close() end
    end)
  end, {})

  -- :JupynvimDebugHl — dump every highlight source at the cursor (treesitter,
  -- semantic tokens, syntax, jupynvim extmarks) with each group's resolved
  -- foreground. Put the cursor on a line that looks wrong (e.g. gray output)
  -- and run this; it tells us exactly which group is painting it instead of
  -- guessing from a screenshot.
  vim.api.nvim_create_user_command("JupynvimDebugHl", function()
    local buf = vim.api.nvim_get_current_buf()
    local win = vim.api.nvim_get_current_win()
    local pos = vim.api.nvim_win_get_cursor(win)
    local row, col = pos[1] - 1, pos[2]
    local function fg_of(group)
      local seen = {}
      local name = group
      while name and not seen[name] do
        seen[name] = true
        local h = vim.api.nvim_get_hl(0, { name = name })
        if h.fg then return string.format("#%06x", h.fg) end
        if h.link then name = h.link else break end
      end
      return "(no fg" .. (group ~= name and " via " .. tostring(name) or "") .. ")"
    end
    local out = {}
    local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
    table.insert(out, string.format("row=%d col=%d text=%q", row, col, line:sub(1, 40)))
    table.insert(out, "Normal fg = " .. fg_of("Normal")
      .. " | JupynvimOutputText -> " .. fg_of("JupynvimOutputText"))
    local winhl = vim.wo[win].winhighlight
    table.insert(out, "winhighlight = " .. (winhl ~= "" and winhl or "(none)"))
    local info = vim.inspect_pos(buf, row, math.max(col, 0))
    for _, t in ipairs(info.treesitter or {}) do
      local g = "@" .. (t.capture or "?") .. "." .. (t.lang or "?")
      table.insert(out, "  treesitter " .. g .. "  fg=" .. fg_of(g) .. " (hl=" .. tostring(t.hl_group) .. ")")
    end
    for _, s in ipairs(info.semantic_tokens or {}) do
      local g = s.opts and s.opts.hl_group or "?"
      table.insert(out, "  semantic " .. tostring(g) .. "  fg=" .. fg_of(g)
        .. " prio=" .. tostring(s.opts and s.opts.priority))
    end
    for _, sy in ipairs(info.syntax or {}) do
      table.insert(out, "  syntax " .. tostring(sy.hl_group) .. "  fg=" .. fg_of(sy.hl_group))
    end
    for _, e in ipairs(info.extmarks or {}) do
      local g = e.opts and (e.opts.hl_group or e.opts.line_hl_group)
      if g then
        table.insert(out, "  extmark[" .. tostring(e.ns) .. "] " .. tostring(g)
          .. "  fg=" .. fg_of(g) .. " prio=" .. tostring(e.opts.priority))
      end
    end
    if #info.treesitter == 0 and #(info.semantic_tokens or {}) == 0 and #(info.syntax or {}) == 0 then
      table.insert(out, "  (no treesitter / semantic / syntax at this position)")
    end
    local msg = table.concat(out, "\n")
    print(msg)
    pcall(vim.fn.setreg, "+", msg)
    pcall(function()
      local f = io.open(vim.fn.stdpath("cache") .. "/jupynvim_debug.txt", "w")
      if f then f:write(msg); f:close() end
    end)
  end, {})

  -- :JupynvimExplorer — open the explorer dispatcher (remote tree if an SSH
  -- session is active, else local). Same as the explorer_keys binding.
  vim.api.nvim_create_user_command("JupynvimExplorer", function() M.explorer() end, {})

  -- :JupynvimRemoteCd <alias> <path> — re-root the remote explorer at <path>
  -- (absolute remote path, e.g. /ocean/projects/<alloc>/shared). Lets you
  -- browse/edit anywhere on the remote, not just $HOME. In the tree, `-` roots
  -- up one level and `.` prompts for a path.
  vim.api.nvim_create_user_command("JupynvimRemoteCd", function(o)
    local parts = vim.split(o.args, " ", { trimempty = true })
    local alias = parts[1] or M._active_alias
    local path = parts[2] or parts[1]
    if not alias or not path or (#parts < 2 and not M._active_alias) then
      vim.notify("usage: :JupynvimRemoteCd <alias> <path>", vim.log.levels.WARN)
      return
    end
    if #parts == 1 and M._active_alias then alias = M._active_alias; path = parts[1] end
    M._set_active_alias(alias)
    -- This is the ONLY thing that designates the working directory. Browsing
    -- the tree with `-` / backspace is navigation, not a cd, so <leader>e and
    -- <leader>E still bring you back here afterwards.
    M._note_session_cwd(alias, path)
    require("jupynvim.remote.explorer").set_root(alias, path)
  end, {
    nargs = "+",
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

  -- :JupynvimCrossBuild — cross-compile the linux backend binary locally
  -- (static musl, runs on PSC's old glibc). Output is auto-uploaded to remotes
  -- on the next connect. One-time setup: brew install zig; cargo install
  -- cargo-zigbuild; rustup target add x86_64-unknown-linux-musl.
  -- Builds every installed linux-musl rustup target (x86_64 always once
  -- added; add aarch64-unknown-linux-musl for arm64 remotes like AWS
  -- Graviton). Auto-upload then picks the right one per remote via uname -m.
  vim.api.nvim_create_user_command("JupynvimCrossBuild", function()
    local root = plugin_root()
    local manifest = root .. "/core/Cargo.toml"
    local installed = vim.fn.systemlist({ "rustup", "target", "list", "--installed" }) or {}
    local targets = {}
    for _, t in ipairs(installed) do
      if t:match("linux%-musl$") then table.insert(targets, t) end
    end
    if #targets == 0 then
      vim.notify("jupynvim: no linux-musl rustup targets installed.\n" ..
                 "  rustup target add x86_64-unknown-linux-musl" ..
                 "  (and aarch64-unknown-linux-musl for arm64 remotes)", vim.log.levels.WARN)
      return
    end
    local function build(i)
      if i > #targets then return end
      local triple = targets[i]
      vim.notify("jupynvim: cross-building " .. triple .. " ...", vim.log.levels.INFO)
      vim.system({
        "cargo", "zigbuild", "--release", "--target", triple, "--manifest-path", manifest,
      }, { text = true }, function(res)
        vim.schedule(function()
          if res.code == 0 then
            M._binary_verified = {}  -- force re-upload check on next connect
            vim.notify("jupynvim: " .. triple .. " OK -> " ..
              root .. "/core/target/" .. triple .. "/release/jupynvim-core",
              vim.log.levels.INFO)
          else
            vim.notify("jupynvim: " .. triple .. " build failed:\n" ..
              (res.stderr or res.stdout or "?"), vim.log.levels.ERROR)
          end
          build(i + 1)
        end)
      end)
    end
    build(1)
  end, {})

  -- :JupynvimUseJob <alias> [<jobid>]  — route next backend spawn through
  -- srun --jobid=N --overlap. Omit jobid to clear (back to login node).
  vim.api.nvim_create_user_command("JupynvimUseJob", function(o)
    local parts = vim.split(o.args, " ", { trimempty = true })
    if #parts == 0 then
      vim.notify("usage: :JupynvimUseJob <alias> [<jobid>]", vim.log.levels.WARN)
      return
    end
    M.use_job(parts[1], parts[2] or "")
  end, {
    nargs = "+",
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

  -- :JupynvimConnect <alias>  — open a terminal split for interactive SSH
  -- auth (password / 2FA). Sets up a ControlMaster socket; future
  -- :JupynvimOpenRemote calls for this alias reuse it without prompting.
  -- :JupynvimConnect                 -> pick a profile (or "new connection")
  -- :JupynvimConnect <alias>         -> connect a configured profile
  -- :JupynvimConnect <user@host>     -> ad-hoc connection (session profile;
  --                                     add to config.remote to persist)
  vim.api.nvim_create_user_command("JupynvimConnect", function(o)
    local arg = vim.trim(o.args or "")
    if arg == "" then return M.connect_choose() end
    if (M.config.remote or {})[arg] then return M.connect(arg) end
    -- ssh-config aliases (e.g. a gcloud/EC2 Host entry) have no @ or dot;
    -- accept them when they exist in ~/.ssh/config.
    if vim.tbl_contains(M._ssh_config_hosts(), arg)
       or arg:find("@") or arg:find("%.") then
      return M.connect_adhoc(arg)
    end
    vim.notify("jupynvim: no profile or ssh-config host '" .. arg ..
      "'. Use <user@host> for a new connection.", vim.log.levels.WARN)
  end, {
    nargs = "?",
    complete = function()
      -- Same filtered/deduped list as the chooser: one name per real machine.
      local names = {}
      for _, t in ipairs(M._connect_targets()) do table.insert(names, t.name) end
      return names
    end,
  })

  -- :JupynvimLspStatus — dump the remote-LSP attach chain breadcrumbs
  -- (resolved servers, probe/install results, root, server/client state).
  vim.api.nvim_create_user_command("JupynvimLspStatus", function()
    require("jupynvim.remote.lsp").status()
  end, {})

  -- :JupynvimRpcStats — print per-method RPC counts since the last reset, then
  -- reset. Run once to clear, do the laggy action (e.g. j/k around a big cell),
  -- run again: the counts are exactly what crossed the link during that window.
  vim.api.nvim_create_user_command("JupynvimRpcStats", function()
    local rpc = require("jupynvim.rpc")
    local function fmt(label, t)
      local rows = {}
      for k, v in pairs(t) do rows[#rows + 1] = { k, v } end
      table.sort(rows, function(a, b) return a[2] > b[2] end)
      local lines = { label .. ":" }
      if #rows == 0 then lines[#lines + 1] = "    (none)" end
      for _, r in ipairs(rows) do lines[#lines + 1] = string.format("    %5d  %s", r[2], r[1]) end
      return table.concat(lines, "\n")
    end
    local out = fmt("outgoing (nvim -> backend)", rpc.stats.out)
    local inc = fmt("incoming (backend -> nvim)", rpc.stats.inc)
    rpc.reset_stats()
    vim.notify("jupynvim RPC since last reset (now reset):\n" .. out .. "\n" .. inc, vim.log.levels.INFO)
  end, {})

  -- :JupynvimRenderStats — local-render counters (frame re-renders, tty/kitty
  -- writes and their byte volume) since last reset, then reset. Pairs with
  -- JupynvimRpcStats: if RPC is zero but these are high during the laggy
  -- action, the cost is local rendering, not the link.
  vim.api.nvim_create_user_command("JupynvimRenderStats", function()
    local img = require("jupynvim.notebook.image")
    local rnd = require("jupynvim.notebook.render")
    local msg = string.format(
      "jupynvim render since last reset (now reset):\n    renders:   %d\n    tty writes: %d  (%d KB)",
      rnd._render_n or 0, img._tty_n or 0, math.floor((img._tty_bytes or 0) / 1024))
    rnd._render_n, img._tty_n, img._tty_bytes = 0, 0, 0
    vim.notify(msg, vim.log.levels.INFO)
  end, {})

  -- :JupynvimPauseAnimations — toggle all gif animation timers. A/B test for
  -- whether animation drives navigation lag over a remote backend, and a
  -- workaround if it does.
  vim.api.nvim_create_user_command("JupynvimPauseAnimations", function()
    local img = require("jupynvim.notebook.image")
    if img.animations_paused() then
      img.resume_animations()
      vim.notify("jupynvim: animations resumed", vim.log.levels.INFO)
    else
      img.pause_animations()
      vim.notify("jupynvim: animations paused", vim.log.levels.INFO)
    end
  end, {})

  -- :JupynvimLspRetry [alias] — clear cached LSP provisioning failures and
  -- re-attach remote language servers for open jupynvim:// buffers.
  vim.api.nvim_create_user_command("JupynvimLspRetry", function(o)
    local alias = vim.trim(o.args or "")
    require("jupynvim.remote.lsp").retry(alias ~= "" and alias or M._active_alias)
  end, {
    nargs = "?",
    complete = function()
      local names = {}
      for name, _ in pairs(M.config.remote or {}) do table.insert(names, name) end
      return names
    end,
  })

  -- :JupynvimDisconnect <alias>  — close the ControlMaster socket. Completes
  -- with the same target list as Connect (profiles + ssh-config hosts), with
  -- live-socket targets first.
  vim.api.nvim_create_user_command("JupynvimDisconnect", function(o) M.disconnect(o.args) end, {
    nargs = 1,
    complete = function()
      local names = {}
      for _, t in ipairs(M._connect_targets()) do table.insert(names, t.name) end
      return names
    end,
  })

  -- On nvim exit we only stop the backend SUBPROCESSES (clean shutdown of
  -- jupynvim-core over each transport), but DELIBERATELY LEAVE the SSH
  -- ControlMaster sockets alive. ControlPersist keeps them for their TTL
  -- (4h), so the next nvim session reuses them WITHOUT re-auth — critical
  -- with password+2FA logins where re-auth every restart is painful.
  -- Use :JupynvimDisconnect <alias> for explicit teardown.
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      for b, nb in pairs(Notebook.all()) do
        pcall(M._persist_cursor_positions, nb, b)
      end
      for _, client in pairs(M.clients or {}) do
        pcall(function() client:stop() end)
      end
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

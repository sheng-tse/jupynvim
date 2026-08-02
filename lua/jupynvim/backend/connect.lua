-- Backend lifecycle: locating and spawning jupynvim-core, the SSH
-- ControlMaster helpers, cross-building and uploading the linux binary, and
-- the connect / use_job / disconnect entry points.
--
-- install(M) writes onto the main module table, so callers keep reaching these
-- as jupynvim.connect / jupynvim.client_for / jupynvim._ensure_client.

local RPC   = require("jupynvim.rpc")
local Image = require("jupynvim.notebook.image")
local Log   = require("jupynvim.log")

local Connect = {}

function Connect.install(M)
-- ---------- backend helpers ----------

local function locate_core()
  if M.config.core_path then return M.config.core_path end
  -- Ask the one helper that knows where the plugin lives; this used to repeat
  -- the :h:h:h path math and broke silently, falling back to a bare name that
  -- is not on PATH, when this file moved a directory deeper.
  local candidate = M._plugin_root() .. "/core/target/release/jupynvim-core"
  if vim.fn.executable(candidate) == 1 then return candidate end
  return "jupynvim-core"
end

-- Path to this plugin's repo root (.../jupynvim).
function M._plugin_root()
  local src = debug.getinfo(1, "S").source
  if src:sub(1, 1) == "@" then src = src:sub(2) end
  -- Walk up looking for the plugin's own entry point rather than counting
  -- directories. This function moved one level deeper when the backend split
  -- out, and a fixed :h:h:h silently returned lua/ instead of the repo root,
  -- so locate_core could not find the binary any more.
  local dir = vim.fn.fnamemodify(src, ":h")
  for _ = 1, 8 do
    if vim.fn.filereadable(dir .. "/lua/jupynvim/init.lua") == 1 then return dir end
    local up = vim.fn.fnamemodify(dir, ":h")
    if up == dir then break end
    dir = up
  end
  return vim.fn.fnamemodify(src, ":h:h:h:h")
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
  return M._plugin_root() .. "/core/target/" .. triple .. "/release/jupynvim-core"
end

-- Newest mtime across the backend sources. Lets a connect tell whether the
-- cross-built linux binary predates the code it is meant to be carrying.
local function core_source_mtime()
  local root = M._plugin_root() .. "/core"
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
  local bin = M._plugin_root() .. "/core/target/" .. triple .. "/release/jupynvim-core"
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
    "--manifest-path", M._plugin_root() .. "/core/Cargo.toml",
  }, { text = true }):wait()
  local bin = M._plugin_root() .. "/core/target/" .. triple .. "/release/jupynvim-core"
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

function M._ensure_client()
  if M.client and M.client.job then return M.client end
  M.client = spawn_client({ locate_core() }, "local")
  return M.client
end

-- Resolve the RPC client a notebook's operations should route to. Remote
-- notebooks (nb.alias set) go to their own backend; local ones to the
-- shared local backend. Always use this in execute/kernel paths rather than
-- the global M.client — otherwise, with a local AND a remote notebook open,
-- run-cell on one routes to whichever backend was touched last.
function M._nb_client(nb)
  if nb and nb.alias then return M.client_for(nb.alias) end
  return M._ensure_client()
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
function M._resolve(field, spec)
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
function M._build_ssh_cmd(spec)
  -- -T raw stdio (msgpack), BatchMode no prompts, timeout opts fail fast,
  -- ControlPath reuses the :JupynvimConnect master (or makes a fresh conn).
  local cp = control_path(spec.label or spec.host)
  local cmd = ssh_base(cp, nil)  -- host appended after ssh_args
  local ssh_args = M._resolve(spec.ssh_args, spec) or {}
  for _, a in ipairs(ssh_args) do table.insert(cmd, a) end
  table.insert(cmd, spec.host)
  local remote_cmd = spec.core_path or "~/.local/bin/jupynvim-core"
  -- Environment setup before the backend starts (runs INSIDE the slurm step
  -- when one is active, i.e. on the compute node). A login bash sources the
  -- cluster's profile so `module` exists; the backend then inherits the
  -- prepared PATH/env, which kernels, LSP servers, and terminals all reuse.
  --   remote = { psc = { setup_cmd = "module load anaconda3" } }
  local setup = M._resolve(spec.setup_cmd, spec)
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
  local cmd = M._resolve(spec.transport_cmd, spec) or M._build_ssh_cmd(spec)
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
  local ssh_args = M._resolve(profile.ssh_args, profile) or {}
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
end

return Connect

-- Remote LSP relay (Phase 6).
--
-- Runs a language server ON THE REMOTE (via the backend's lsp_start) and wires
-- it to a local vim.lsp client whose `cmd` is a function. The client forwards
-- JSON-RPC to the remote server through the msgpack channel and rewrites URIs
-- both directions (jupynvim://<alias>  <->  file://) so diagnostics, goto-def,
-- completion, hover, format, etc. all land on the right buffer.
--
-- Server selection is driven by the USER's setup, not a hardcoded list:
--   1. remote.<alias>.lsp[<ft>] explicit override
--   2. the cmd lspconfig would use for that filetype (the user's configured
--      servers), with the binary launched on the remote
--   3. a small built-in default map as a last resort
-- Provisioning is zero-manual: if the server binary isn't on the remote PATH,
-- run an install recipe (built-in for common ones, user-extensible), once.

local log = require("jupynvim.log")
local M = {}

-- key "alias:root:server" -> { lsp_id, client_id, dispatch, pending, next_id }
local servers = {}
-- per (alias, server) provisioning result cache: nil=unknown, false=unavailable, string=cmd[1]
local provisioned = {}

-- Breadcrumbs for :JupynvimLspStatus. Every step of the attach chain records
-- what happened so a silent failure on a real remote is diagnosable.
local steps = {}
local function step(key, k, v)
  steps[key] = steps[key] or {}
  steps[key][k] = v
end

-- ── server selection ──────────────────────────────────────────────────────

-- Built-in defaults (last resort). Standard binaries; users override via config.
local DEFAULT_SERVERS = {
  python = { "basedpyright-langserver", "--stdio" },
  c =      { "clangd" },
  cpp =    { "clangd" },
  rust =   { "rust-analyzer" },
  go =     { "gopls" },
  lua =    { "lua-language-server" },
  typescript = { "typescript-language-server", "--stdio" },
  javascript = { "typescript-language-server", "--stdio" },
}
-- Built-in install recipes (argv run on the remote). Users extend via
-- remote.<alias>.lsp_install[<server-bin>] = "pip install --user X".
local DEFAULT_INSTALL = {
  ["basedpyright-langserver"] = { "pip", "install", "--user", "basedpyright" },
  ["pyright-langserver"]      = { "pip", "install", "--user", "pyright" },
  ["ruff"]                    = { "pip", "install", "--user", "ruff" },
  ["pylsp"]                   = { "pip", "install", "--user", "python-lsp-server" },
  -- clangd is a prebuilt binary (not pip): download the LLVM release, extract
  -- into ~/.local/share/jupynvim, symlink onto ~/.local/bin (its lib/clang
  -- resource dir must stay beside the binary, so we symlink the bin not copy).
  ["clangd"] = { "sh", "-lc", table.concat({
    "set -e",
    "mkdir -p ~/.local/share/jupynvim ~/.local/bin",
    "cd ~/.local/share/jupynvim",
    'V=18.1.3',
    'curl -fsSL -o clangd.zip "https://github.com/clangd/clangd/releases/download/$V/clangd-linux-$V.zip"',
    "unzip -oq clangd.zip && rm -f clangd.zip",
    'ln -sf "$HOME/.local/share/jupynvim/clangd_$V/bin/clangd" ~/.local/bin/clangd',
  }, " && ") },
}

-- A server spec: { cmd=table, name=string, settings=?, init_options=?, root_markers=? }

-- Modern API (Neovim 0.11+): the user's enabled servers live in
-- vim.lsp.config + vim.lsp._enabled_configs. Return EVERY enabled server whose
-- filetypes include `ft` (a user may run several per language, e.g.
-- basedpyright + ruff for python). This is the primary, general source.
local function modern_servers_for_ft(ft)
  local out = {}
  local enabled = rawget(vim.lsp, "_enabled_configs")
  if type(enabled) ~= "table" or not vim.lsp.config then return out end
  for name, _ in pairs(enabled) do
    local ok, cfg = pcall(function() return vim.lsp.config[name] end)
    if ok and type(cfg) == "table" and type(cfg.cmd) == "table"  -- skip function cmds
       and cfg.filetypes and vim.tbl_contains(cfg.filetypes, ft) then
      out[#out + 1] = {
        cmd = vim.deepcopy(cfg.cmd), name = name,
        settings = cfg.settings, init_options = cfg.init_options,
        root_markers = cfg.root_markers or cfg.root_dir,
      }
    end
  end
  return out
end

-- Old lspconfig API (pre-0.11 setups): servers in lspconfig.configs.
local function lspconfig_servers_for_ft(ft)
  local out = {}
  local ok_cfg, configs = pcall(require, "lspconfig.configs")
  local ok_lc, lspconfig = pcall(require, "lspconfig")
  if not (ok_cfg and ok_lc) then return out end
  for name, _ in pairs(configs or {}) do
    local mod = lspconfig[name]
    local dc = mod and mod.document_config and mod.document_config.default_config
    if dc and type(dc.cmd) == "table" and dc.filetypes and vim.tbl_contains(dc.filetypes, ft) then
      out[#out + 1] = { cmd = vim.deepcopy(dc.cmd), name = name,
                        settings = dc.settings, init_options = dc.init_options,
                        root_markers = dc.root_dir }
    end
  end
  return out
end

-- Lazy-loaders (lazy.nvim/LazyVim) only load the LSP layer on real file
-- events, which our BufReadCmd doesn't fire — so vim.lsp._enabled_configs can
-- be empty when we resolve, hiding the user's real servers. Best-effort load
-- it once so modern detection sees the full set (e.g. basedpyright + ruff).
local lsp_layer_loaded = false
local function ensure_lsp_layer_loaded()
  if lsp_layer_loaded then return end
  local enabled = rawget(vim.lsp, "_enabled_configs")
  if type(enabled) == "table" and next(enabled) then lsp_layer_loaded = true; return end
  pcall(function()
    require("lazy").load({ plugins = { "nvim-lspconfig", "mason-lspconfig.nvim", "mason.nvim" } })
  end)
  -- Generic fallback: fire the file events lazy-loaders gate on.
  pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "LazyFile" })
  lsp_layer_loaded = true
end

-- Resolve the LIST of server specs for an alias+filetype, mirroring the user's
-- own setup. Order: explicit config override → modern vim.lsp.config (enabled)
-- → old lspconfig → built-in defaults. Generalized: whatever servers the user
-- runs locally for this language get launched on the remote.
local function resolve_servers(alias, ft)
  ensure_lsp_layer_loaded()
  local profile = (require("jupynvim").config.remote or {})[alias] or {}
  local override = profile.lsp and profile.lsp[ft]
  if override then
    -- allow a single {cmd=...} / bare cmd table, or a list of them
    local list = override
    if override.cmd or (override[1] and type(override[1]) == "string") then list = { override } end
    local specs = {}
    for _, o in ipairs(list) do
      local cmd = o.cmd or o
      if type(cmd) == "table" and cmd[1] then
        specs[#specs + 1] = { cmd = cmd, name = o.name or cmd[1], settings = o.settings, init_options = o.init_options }
      end
    end
    if #specs > 0 then return specs end
  end
  local specs = modern_servers_for_ft(ft)
  if #specs > 0 then return specs end
  specs = lspconfig_servers_for_ft(ft)
  if #specs > 0 then return specs end
  if DEFAULT_SERVERS[ft] then
    return { { cmd = vim.deepcopy(DEFAULT_SERVERS[ft]), name = DEFAULT_SERVERS[ft][1] } }
  end
  return {}
end

-- ── provisioning (zero-manual) ─────────────────────────────────────────────

-- Ensure the server binary exists on the remote; install once if a recipe is
-- known. Fully ASYNC (a pip install can take minutes; the old sync version
-- froze the editor for its duration). Calls cb(launch_cmd or nil).
--
-- On success the binary is resolved to its ABSOLUTE path via `command -v`
-- under a login shell (sh -lc): pip --user installs land in ~/.local/bin,
-- which is on the login-shell PATH but not necessarily on the backend
-- process's PATH, so spawning by bare name could fail for any user whose
-- shell setup differs. The absolute path works regardless.
local function ensure_provisioned(alias, cmd, cb)
  local J = require("jupynvim")
  local client = J.client_for(alias)
  local bin = cmd[1]
  local cache_key = alias .. ":" .. bin
  local hit = provisioned[cache_key]
  if hit ~= nil then
    step(cache_key, "probe", hit and ("cached: " .. tostring(hit)) or "cached: unavailable (:JupynvimLspRetry to reprobe)")
    if hit == false then return cb(nil) end
    local c = vim.deepcopy(cmd); c[1] = hit
    return cb(c)
  end
  local function resolve(after_install)
    -- command -v under a login shell, with an explicit ~/.local/bin fallback:
    -- pip --user installs land there, and on some clusters the login-shell
    -- PATH only picks it up on a fresh login (basedpyright was "installed but
    -- not found" without this).
    local q = vim.fn.shellescape(bin)
    local probe = ("command -v %s || { [ -x \"$HOME/.local/bin\"/%s ] && echo \"$HOME/.local/bin\"/%s; }")
      :format(q, q, q)
    client:call("run", { argv = { "sh", "-lc", probe } }, function(err, res)
      if err then
        -- run RPC itself failed (old backend without `run`, dead client, ...)
        step(cache_key, "probe", "run RPC error: " .. tostring(err))
        vim.notify("jupynvim: LSP probe failed on " .. alias .. ": " .. tostring(err), vim.log.levels.WARN)
        return cb(nil)  -- not cached: retried on next open
      end
      local abs = (res and tonumber(res.code) == 0)
        and (res.stdout or ""):match("^%s*(%S+)") or nil
      if abs then
        step(cache_key, "probe", "found " .. abs)
        provisioned[cache_key] = abs
        local c = vim.deepcopy(cmd); c[1] = abs
        return cb(c)
      end
      step(cache_key, "probe", "not on PATH (code=" .. tostring(res and res.code) .. ")")
      if after_install then
        step(cache_key, "install", "completed but binary still not found")
        vim.notify(("jupynvim: '%s' installed but not found on %s PATH"):format(bin, alias),
          vim.log.levels.ERROR)
        provisioned[cache_key] = false
        return cb(nil)
      end
      -- not on PATH: try an install recipe
      local profile = (J.config.remote or {})[alias] or {}
      local recipe = (profile.lsp_install and profile.lsp_install[bin]) or DEFAULT_INSTALL[bin]
      if not recipe then
        step(cache_key, "install", "no recipe")
        vim.notify(("jupynvim: LSP '%s' not on %s PATH and no install recipe.\n  add remote.%s.lsp_install['%s'] = {...}")
          :format(bin, alias, alias, bin), vim.log.levels.WARN)
        provisioned[cache_key] = false
        return cb(nil)
      end
      if type(recipe) == "string" then recipe = { "sh", "-lc", recipe } end
      step(cache_key, "install", "running...")
      vim.notify(("jupynvim: installing LSP '%s' on %s (one-time, in background)..."):format(bin, alias),
        vim.log.levels.INFO)
      client:call("run", { argv = recipe }, function(ierr, ires)
        if ierr or not ires or tonumber(ires.code) ~= 0 then
          local why = (ires and ires.stderr) or tostring(ierr)
          step(cache_key, "install", "FAILED: " .. tostring(why):sub(1, 200))
          vim.notify(("jupynvim: install of '%s' failed:\n%s"):format(bin, why),
            vim.log.levels.ERROR)
          provisioned[cache_key] = false
          return cb(nil)
        end
        step(cache_key, "install", "ok")
        vim.notify(("jupynvim: '%s' installed on %s"):format(bin, alias), vim.log.levels.INFO)
        resolve(true)
      end)
    end)
  end
  resolve(false)
end

-- ── URI rewriting (jupynvim://<alias>  <->  file://) ───────────────────────

local function rewrite_uris(obj, from, to)
  local t = type(obj)
  if t == "string" then
    if obj:sub(1, #from) == from then return to .. obj:sub(#from + 1) end
    return obj
  elseif t == "table" then
    for k, v in pairs(obj) do obj[k] = rewrite_uris(v, from, to) end
    return obj
  end
  return obj
end

-- ── the cmd-as-function relay client ───────────────────────────────────────

local function make_cmd(alias, lsp_id_ref, state)
  return function(dispatchers)
    local closed = false
    local client = {}
    state.dispatch = dispatchers
    state.pending = {}
    state.next_id = 0

    local out_prefix = "jupynvim://" .. alias          -- client -> server: strip to file://
    local function to_server(params) return rewrite_uris(params, out_prefix, "file://") end
    local function to_client(params) return rewrite_uris(params, "file://", "jupynvim://" .. alias) end
    state.to_client = to_client

    local function send(msg)
      local cl = require("jupynvim").client_for(alias)
      cl:call("lsp_send", { lsp_id = lsp_id_ref.id, message = msg }, function() end)
    end

    function client.request(method, params, callback, _notify)
      state.next_id = state.next_id + 1
      local id = state.next_id
      if closed then callback({ code = -32000, message = "shutdown" }, nil); return id, id end
      state.pending[id] = callback
      send({ jsonrpc = "2.0", id = id, method = method, params = to_server(params or vim.empty_dict()) })
      return id, id
    end

    function client.notify(method, params)
      if closed then return false end
      send({ jsonrpc = "2.0", method = method, params = to_server(params or vim.empty_dict()) })
      return true
    end

    function client.is_closing() return closed end
    function client.terminate()
      closed = true
      local cl = require("jupynvim").client_for(alias)
      if lsp_id_ref.id then cl:call("lsp_stop", { lsp_id = lsp_id_ref.id }, function() end) end
    end

    return client
  end
end

-- Route an incoming lsp_message (from the backend) to the right state.
-- Registered once per backend client.
local function hook_lsp_messages(alias)
  local cl = require("jupynvim").client_for(alias)
  if cl._lsp_msg_hooked then return end
  cl._lsp_msg_hooked = true
  cl:on("lsp_message", function(args)
    local e = args[1] or args
    -- find the state for this lsp_id
    local st
    for _, s in pairs(servers) do
      if s.alias == alias and s.lsp_id_ref and s.lsp_id_ref.id == e.lsp_id then st = s; break end
    end
    if not st then return end
    if e.exit then
      if st.dispatch and st.dispatch.on_exit then pcall(st.dispatch.on_exit, 0, 0) end
      return
    end
    local msg = e.message
    if type(msg) ~= "table" then return end
    msg = st.to_client and st.to_client(msg) or msg
    if msg.id ~= nil and msg.method ~= nil then
      -- server -> client request (e.g. workspace/configuration)
      if st.dispatch and st.dispatch.server_request then
        local result, err = st.dispatch.server_request(msg.method, msg.params or vim.empty_dict())
        local cl2 = require("jupynvim").client_for(alias)
        cl2:call("lsp_send", { lsp_id = e.lsp_id, message = {
          jsonrpc = "2.0", id = msg.id, result = result, error = err,
        } }, function() end)
      end
    elseif msg.id ~= nil then
      -- response to one of our requests
      local cb = st.pending and st.pending[msg.id]
      if cb then st.pending[msg.id] = nil; pcall(cb, msg.error, msg.result) end
    elseif msg.method ~= nil then
      -- server -> client notification (publishDiagnostics, etc.)
      if st.dispatch and st.dispatch.notification then
        pcall(st.dispatch.notification, msg.method, msg.params or vim.empty_dict())
      end
    end
  end)
end

-- Find the project root on the REMOTE by walking up from `start_dir` for any
-- of `markers` (root_markers from the user's server config). Falls back to the
-- file's dir. Async: one `run` call, cached per (alias, start_dir, markers).
local root_cache = {}
local function find_remote_root(alias, start_dir, markers, cb)
  -- markers can be nested (e.g. lua_ls), a function, or strings; flatten to a
  -- clean string list. Non-strings are dropped so table.concat/shellescape
  -- never error in this async path (an error here would vanish silently).
  local flat = {}
  local function add(m)
    if type(m) == "string" then flat[#flat + 1] = m
    elseif type(m) == "table" then for _, x in ipairs(m) do add(x) end end
  end
  add(markers)
  if #flat == 0 then return cb(start_dir) end
  local ck = alias .. "|" .. start_dir .. "|" .. table.concat(flat, ",")
  if root_cache[ck] then return cb(root_cache[ck]) end

  local pat = table.concat(vim.tbl_map(function(m) return vim.fn.shellescape(m) end, flat), " ")
  local script = ([[d=%s; while [ "$d" != / ]; do for m in %s; do [ -e "$d/$m" ] && echo "$d" && exit 0; done; d=$(dirname "$d"); done; echo %s]])
    :format(vim.fn.shellescape(start_dir), pat, vim.fn.shellescape(start_dir))
  local done = false
  local function finish(root)
    if done then return end
    done = true
    root_cache[ck] = root
    cb(root)
  end
  -- Timeout fallback: if the remote walk stalls (slow/hung login shell, lost
  -- response), proceed with the file's dir so the LSP chain never gets stuck.
  vim.defer_fn(function() finish(start_dir) end, 6000)
  -- `sh -c` (NOT -lc): this is pure filesystem checks, so it needs no login
  -- shell. On HPC, `sh -lc` sources module/conda init and can be slow or hang.
  local ok, cl = pcall(function() return require("jupynvim").client_for(alias) end)
  if not ok then return finish(start_dir) end
  cl:call("run", { argv = { "sh", "-c", script } }, function(err, res)
    local root = (not err and res and (res.stdout or ""):match("([^\n]+)")) or start_dir
    finish(root)
  end)
end

-- Start (or reuse) one server `spec` for `buf` rooted under `path`'s project.
-- Fully async (provision -> root-find -> lsp_start are all background RPCs);
-- the editor never blocks while a server installs or spawns. Concurrent
-- attaches for the same (alias, root, server) queue on pending_bufs instead
-- of double-starting.
local function start_one(buf, alias, path, spec)
  local skey = alias .. ":" .. spec.name
  step(skey, "spec", table.concat(spec.cmd, " "))
  ensure_provisioned(alias, spec.cmd, function(launch)
    if not launch then step(skey, "state", "provisioning failed (see probe/install)"); return end
    step(skey, "state", "provisioned: " .. launch[1])

    -- root_markers may be a list, a string, or a function; normalize to a list.
    local markers = spec.root_markers
    if type(markers) == "string" then markers = { markers } end
    if type(markers) ~= "table" then markers = { ".git" } end
    local start_dir = path:match("^(.*)/[^/]+$") or "/"
    step(skey, "state", "finding root...")

    find_remote_root(alias, start_dir, markers, function(root)
      local cont_ok, cont_err = pcall(function()
      step(skey, "root", root)
      local key = alias .. ":" .. root .. ":" .. spec.name
      local st = servers[key]
      if st then
        if st.client_id and vim.lsp.get_client_by_id(st.client_id) then
          if vim.api.nvim_buf_is_valid(buf) then pcall(vim.lsp.buf_attach_client, buf, st.client_id) end
        else
          table.insert(st.pending_bufs, buf)  -- start in flight; attach when ready
        end
        return
      end

      st = { alias = alias, lsp_id_ref = { id = nil }, pending_bufs = { buf } }
      servers[key] = st
      hook_lsp_messages(alias)

      local client = require("jupynvim").client_for(alias)
      step(skey, "state", "starting server...")
      client:call("lsp_start", { cmd = launch, cwd = root }, function(err, res)
       local sok, serr = pcall(function()
        if err or not res or not res.lsp_id then
          step(skey, "state", "lsp_start FAILED: " .. tostring(err))
          vim.notify("jupynvim: lsp_start " .. spec.name .. " failed: " .. tostring(err), vim.log.levels.ERROR)
          servers[key] = nil
          return
        end
        st.lsp_id_ref.id = res.lsp_id
        step(skey, "state", "server running (lsp_id " .. tostring(res.lsp_id) .. ")")

        local first
        for _, b in ipairs(st.pending_bufs) do
          if vim.api.nvim_buf_is_valid(b) then first = b; break end
        end
        if not first then
          -- every waiting buffer died while the server started; clean up
          client:call("lsp_stop", { lsp_id = res.lsp_id }, function() end)
          servers[key] = nil
          return
        end

        -- root_dir = the REMOTE absolute path; vim.lsp turns it into rootUri
        -- file://<root>, exactly what the remote server expects. Forward the
        -- user's settings + init_options so behavior matches local.
        -- didChangeWatchedFiles is disabled: vim.lsp's libuv watcher would try
        -- to watch the REMOTE root path on the LOCAL machine (the
        -- "watch.watch: ENOENT" error).
        local caps = vim.lsp.protocol.make_client_capabilities()
        caps.workspace = caps.workspace or {}
        caps.workspace.didChangeWatchedFiles = { dynamicRegistration = false }
        local client_id = vim.lsp.start({
          name = "jupynvim:" .. spec.name .. "@" .. alias,
          cmd = make_cmd(alias, st.lsp_id_ref, st),
          root_dir = root,
          settings = spec.settings,
          init_options = spec.init_options,
          capabilities = caps,
        }, { bufnr = first, reuse_client = function() return false end })
        st.client_id = client_id
        step(skey, "client", client_id and ("attached (client " .. client_id .. ")") or "vim.lsp.start returned nil")
        if client_id then
          for _, b in ipairs(st.pending_bufs) do
            if b ~= first and vim.api.nvim_buf_is_valid(b) then
              pcall(vim.lsp.buf_attach_client, b, client_id)
            end
          end
          log.info(("remote-lsp: %s attached buf=%d (%s)"):format(spec.name, first, root))
        end
        st.pending_bufs = {}
       end)  -- pcall (lsp_start callback)
       if not sok then step(skey, "state", "lsp_start cb ERROR: " .. tostring(serr)) end
      end)
      end)  -- pcall (find_remote_root continuation)
      if not cont_ok then step(skey, "state", "post-root ERROR: " .. tostring(cont_err)) end
    end)
  end)
end

-- ── public: attach a remote buffer ─────────────────────────────────────────

-- Attach remote LSP to `buf` (a jupynvim:// file) for `alias`, remote abs
-- `path`, filetype `ft`. Starts ALL servers the user runs for this filetype
-- (mirrors their setup), each on the remote. Idempotent; servers reused per
-- (alias, root, server).
function M.attach(buf, alias, path, ft)
  if not ft or ft == "" then return end
  local ok, specs = pcall(resolve_servers, alias, ft)
  if not ok then
    step(alias .. " [" .. ft .. "]", "resolve", "ERROR: " .. tostring(specs))
    return
  end
  local names = {}
  for _, s in ipairs(specs) do table.insert(names, s.name) end
  step(alias .. " [" .. ft .. "]", "resolve",
    #specs > 0 and table.concat(names, ", ") or "NO servers found for this filetype")
  for _, spec in ipairs(specs) do
    local ok2, e2 = pcall(start_one, buf, alias, path, spec)
    if not ok2 then
      step(alias .. ":" .. spec.name, "state", "attach ERROR: " .. tostring(e2))
    end
  end
end

-- Dump the attach-chain breadcrumbs (what resolved, probe/install results,
-- root, server/client state). :JupynvimLspStatus
function M.status()
  local keys = {}
  for k in pairs(steps) do table.insert(keys, k) end
  table.sort(keys)
  if #keys == 0 then
    vim.notify("jupynvim: no remote-LSP activity yet (open a remote file first)", vim.log.levels.INFO)
    return
  end
  local lines = { "jupynvim remote LSP status:" }
  for _, k in ipairs(keys) do
    table.insert(lines, "  " .. k)
    local order = { "resolve", "spec", "probe", "install", "root", "state", "client" }
    for _, f in ipairs(order) do
      if steps[k][f] then table.insert(lines, "    " .. f .. ": " .. tostring(steps[k][f])) end
    end
  end
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

-- Clear provisioning/root caches for `alias` (or all) and re-attach every
-- loaded jupynvim:// buffer. Use after fixing a failed install (the failure
-- is cached per session so we don't probe on every file open).
-- :JupynvimLspRetry [alias]
function M.retry(alias)
  for k in pairs(provisioned) do
    if not alias or k:sub(1, #alias + 1) == alias .. ":" then provisioned[k] = nil end
  end
  for k in pairs(root_cache) do
    if not alias or k:sub(1, #alias + 1) == alias .. "|" then root_cache[k] = nil end
  end
  local n = 0
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      local a, path = name:match("^jupynvim://([^/]+)(/.*)$")
      if a and (not alias or a == alias) then
        local ft = vim.bo[buf].filetype
        if ft and ft ~= "" then
          M.attach(buf, a, path, ft)
          n = n + 1
        end
      end
    end
  end
  vim.notify(("jupynvim: LSP retry for %s (%d buffer%s)"):format(alias or "all", n, n == 1 and "" or "s"),
    vim.log.levels.INFO)
end

return M

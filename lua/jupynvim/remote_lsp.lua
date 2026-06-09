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

-- The cmd lspconfig would use for `ft`, preferring servers the user has
-- actually configured. Returns (cmd_table, server_name) or nil.
local function lspconfig_cmd_for_ft(ft)
  local ok_cfg, configs = pcall(require, "lspconfig.configs")
  local ok_lc, lspconfig = pcall(require, "lspconfig")
  if not (ok_cfg and ok_lc) then return nil end
  for name, _ in pairs(configs or {}) do
    local mod = lspconfig[name]
    local dc = mod and mod.document_config and mod.document_config.default_config
    if dc and dc.cmd and dc.filetypes and vim.tbl_contains(dc.filetypes, ft) then
      return vim.deepcopy(dc.cmd), name
    end
  end
  return nil
end

-- Resolve (cmd, server_name) for an alias+filetype, honoring user config first.
local function resolve_server(alias, ft)
  local profile = (require("jupynvim").config.remote or {})[alias] or {}
  local override = profile.lsp and profile.lsp[ft]
  if override then
    local cmd = override.cmd or override  -- allow {cmd=...} or a bare cmd table
    if type(cmd) == "table" and cmd[1] then return cmd, (override.name or cmd[1]) end
  end
  local cmd, name = lspconfig_cmd_for_ft(ft)
  if cmd then return cmd, name end
  if DEFAULT_SERVERS[ft] then return vim.deepcopy(DEFAULT_SERVERS[ft]), DEFAULT_SERVERS[ft][1] end
  return nil
end

-- ── provisioning (zero-manual) ─────────────────────────────────────────────

-- Ensure the server binary exists on the remote; install once if a recipe is
-- known. Returns the cmd to launch (possibly unchanged) or nil if unavailable.
-- Synchronous (uses the backend `run` RPC); cached per (alias, bin).
local function ensure_provisioned(alias, cmd)
  local client = require("jupynvim").client_for(alias)
  local bin = cmd[1]
  local cache_key = alias .. ":" .. bin
  if provisioned[cache_key] ~= nil then
    return provisioned[cache_key] and cmd or nil
  end
  -- already on PATH?
  local err, res = client:call_sync("run", { argv = { "sh", "-lc", "command -v " .. vim.fn.shellescape(bin) } }, 8000)
  if not err and res and tonumber(res.code) == 0 and (res.stdout or ""):match("%S") then
    provisioned[cache_key] = true
    return cmd
  end
  -- try an install recipe
  local profile = (require("jupynvim").config.remote or {})[alias] or {}
  local recipe = (profile.lsp_install and profile.lsp_install[bin]) or DEFAULT_INSTALL[bin]
  if not recipe then
    vim.notify(("jupynvim: LSP '%s' not on %s PATH and no install recipe.\n  add remote.%s.lsp_install['%s'] = {...}")
      :format(bin, alias, alias, bin), vim.log.levels.WARN)
    provisioned[cache_key] = false
    return nil
  end
  if type(recipe) == "string" then recipe = { "sh", "-lc", recipe } end
  vim.notify(("jupynvim: installing LSP '%s' on %s (one-time)..."):format(bin, alias), vim.log.levels.INFO)
  local ierr, ires = client:call_sync("run", { argv = recipe }, 180000)
  if ierr or not ires or tonumber(ires.code) ~= 0 then
    vim.notify(("jupynvim: install of '%s' failed:\n%s"):format(bin, (ires and ires.stderr) or tostring(ierr)),
      vim.log.levels.ERROR)
    provisioned[cache_key] = false
    return nil
  end
  provisioned[cache_key] = true
  vim.notify(("jupynvim: '%s' installed on %s"):format(bin, alias), vim.log.levels.INFO)
  return cmd
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

-- ── public: attach a remote buffer ─────────────────────────────────────────

-- Attach a remote-LSP client to `buf` (a jupynvim:// file buffer) for `alias`,
-- remote absolute `path`, filetype `ft`. Idempotent; reuses a server per
-- (alias, root, server). Async-friendly: provisioning may block briefly.
function M.attach(buf, alias, path, ft)
  if not ft or ft == "" then return end
  local cmd, server_name = resolve_server(alias, ft)
  if not cmd then return end  -- no server for this filetype; that's fine

  -- root = nearest ancestor dir of the file (good enough; servers refine it).
  local root = path:match("^(.*)/[^/]+$") or "/"
  local key = alias .. ":" .. root .. ":" .. server_name

  local st = servers[key]
  if st and st.client_id and vim.lsp.get_client_by_id(st.client_id) then
    pcall(vim.lsp.buf_attach_client, buf, st.client_id)
    return
  end

  -- provision (sync, cached) then start the server on the remote
  local launch = ensure_provisioned(alias, cmd)
  if not launch then return end

  st = { alias = alias, lsp_id_ref = { id = nil } }
  servers[key] = st
  hook_lsp_messages(alias)

  local client = require("jupynvim").client_for(alias)
  local err, res = client:call_sync("lsp_start", { cmd = launch, cwd = root }, 15000)
  if err or not res or not res.lsp_id then
    vim.notify("jupynvim: lsp_start failed: " .. tostring(err), vim.log.levels.ERROR)
    servers[key] = nil
    return
  end
  st.lsp_id_ref.id = res.lsp_id

  -- root_dir = the REMOTE absolute path: vim.lsp turns it into rootUri
  -- file://<root>, which is exactly what the remote server expects.
  local client_id = vim.lsp.start({
    name = "jupynvim:" .. server_name .. "@" .. alias,
    cmd = make_cmd(alias, st.lsp_id_ref, st),
    root_dir = root,
    settings = ((require("jupynvim").config.remote or {})[alias] or {}).lsp_settings,
  }, { bufnr = buf, reuse_client = function() return false end })
  st.client_id = client_id
  if client_id then
    log.info(("remote-lsp: %s attached buf=%d (%s)"):format(server_name, buf, root))
  end
end

return M

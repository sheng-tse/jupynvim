-- The :Jupynvim* user commands. Registered from setup() via install(M) so the
-- command bodies stay next to each other instead of trailing 500 lines off the
-- end of setup.

local Notebook = require("jupynvim.notebook")
local Render   = require("jupynvim.notebook.render")

local Commands = {}

function Commands.install(M, Image)
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
    local root = M._plugin_root()
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

return Commands

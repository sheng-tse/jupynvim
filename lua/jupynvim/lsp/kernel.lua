-- Kernel-backed LSP completion and hover via an in-process virtual server.
--
-- We register a `cmd`-as-function client with vim.lsp.start that pretends to
-- be a normal language server. It implements just textDocument/completion
-- and textDocument/hover, both of which proxy to the Rust backend's
-- `complete` / `inspect` RPC methods, which in turn talk to the live Jupyter
-- kernel via complete_request / inspect_request.
--
-- Why this shape: any LSP-aware client (built-in completion, nvim-cmp,
-- blink.cmp, etc.) picks up the kernel's completions through the standard
-- LSP source, no plugin-specific adapter required. And because Jupyter's
-- complete_request is language-agnostic, this works across any kernel the
-- user starts (python, julia, R, javascript, …).

local M = {}

local CompletionItemKind = {
  Text = 1, Method = 2, Function = 3, Constructor = 4, Field = 5,
  Variable = 6, Class = 7, Interface = 8, Module = 9, Property = 10,
  Keyword = 14, Snippet = 15, File = 17, Folder = 19,
}

-- Map IPython type strings (sometimes returned in metadata) to LSP kinds.
local TYPE_TO_KIND = {
  ["function"] = CompletionItemKind.Function,
  ["method"] = CompletionItemKind.Method,
  ["module"] = CompletionItemKind.Module,
  ["class"] = CompletionItemKind.Class,
  ["instance"] = CompletionItemKind.Variable,
  ["statement"] = CompletionItemKind.Variable,
  ["keyword"] = CompletionItemKind.Keyword,
  ["magic"] = CompletionItemKind.Keyword,
  ["path"] = CompletionItemKind.File,
  ["dir"] = CompletionItemKind.Folder,
  ["property"] = CompletionItemKind.Property,
}

-- Build the full code text for a buffer position. We send the entire current
-- cell's source up through the cursor so the kernel sees attribute chains
-- and dotted paths in context.
local function code_and_cursor_for(buf, pos, nb)
  if not nb then return nil end
  local cell_id = nb:cell_at_line(pos.line + 1)
  if not cell_id then return nil end
  local cell, idx = nb:get_cell(cell_id)
  if not cell or cell.cell_type ~= "code" then return nil end
  local _, ranges = nb:to_lines()
  local r = ranges[idx]
  if not r then return nil end
  local lines = vim.api.nvim_buf_get_lines(buf, r.start, r.stop, false)
  -- Cursor is in `pos` (0-based). Compute byte offset within the cell text.
  local cell_row = pos.line - r.start
  local code = table.concat(lines, "\n")
  if cell_row < 0 or cell_row >= #lines then return nil end
  local before_rows = 0
  for i = 1, cell_row do before_rows = before_rows + #lines[i] + 1 end
  local cursor_pos = before_rows + math.min(pos.character, #(lines[cell_row + 1] or ""))
  return code, cursor_pos
end

-- Return the function used as `cmd` in vim.lsp.start. When called by Neovim,
-- it returns a "client" object with request / notify / is_closing / terminate.
local function make_cmd(buf, nb_getter, rpc_getter)
  return function(dispatchers)
    local closed = false
    local id_counter = 0
    local client = {}

    local function next_id()
      id_counter = id_counter + 1
      return id_counter
    end

    function client.request(method, params, callback, _notify_reply_callback)
      local id = next_id()
      if closed then
        callback({ code = -32000, message = "shutdown" }, nil)
        return id
      end

      if method == "initialize" then
        callback(nil, {
          capabilities = {
            textDocumentSync = { openClose = true, change = 0 },
            completionProvider = {
              triggerCharacters = { ".", "/", "_", "[", "(", '"', "'" },
              resolveProvider = false,
            },
            hoverProvider = true,
          },
          serverInfo = { name = "jupynvim_kernel", version = "0.2-dev" },
        })
        return id
      end

      if method == "shutdown" then
        callback(nil, vim.NIL)
        return id
      end

      if method == "textDocument/completion" then
        local nb = nb_getter()
        local rpc = rpc_getter()
        if not nb or not rpc then
          callback(nil, nil)
          return id
        end
        local code, cursor = code_and_cursor_for(buf, params.position, nb)
        if not code then
          callback(nil, nil)
          return id
        end
        rpc:call("complete", {
          session_id = nb.session_id,
          code = code,
          cursor_pos = cursor,
        }, function(err, res)
          if err or not res or res.status ~= "ok" then
            callback(nil, nil)
            return
          end
          local matches = res.matches or {}
          local meta = (res.metadata and res.metadata["_jupyter_types_experimental"]) or {}
          local items = {}
          for i, m in ipairs(matches) do
            local kind = CompletionItemKind.Variable
            local detail
            local entry = meta[i]
            if type(entry) == "table" then
              if entry.type then
                kind = TYPE_TO_KIND[entry.type] or kind
                detail = entry.type
              end
              if entry.signature and entry.signature ~= "" then
                detail = (detail and (detail .. " ") or "") .. entry.signature
              end
            end
            items[#items + 1] = { label = m, kind = kind, detail = detail }
          end
          callback(nil, { isIncomplete = false, items = items })
        end)
        return id
      end

      if method == "textDocument/hover" then
        local nb = nb_getter()
        local rpc = rpc_getter()
        if not nb or not rpc then
          callback(nil, nil)
          return id
        end
        local code, cursor = code_and_cursor_for(buf, params.position, nb)
        if not code then
          callback(nil, nil)
          return id
        end
        rpc:call("inspect", {
          session_id = nb.session_id,
          code = code,
          cursor_pos = cursor,
          detail_level = 0,
        }, function(err, res)
          if err or not res or res.status ~= "ok" or not res.found then
            callback(nil, nil)
            return
          end
          local data = res.data or {}
          -- Strip ANSI from text/plain. The kernel usually returns rich
          -- terminal-formatted help; we keep it readable in a hover popup.
          local text = data["text/plain"]
          if type(text) == "string" then
            text = text:gsub("\27%[[?]?[%d;]*[a-zA-Z]", "")
          else
            text = ""
          end
          if text == "" then
            callback(nil, nil)
            return
          end
          callback(nil, {
            contents = { kind = "markdown", value = "```\n" .. text .. "\n```" },
          })
        end)
        return id
      end

      -- Unknown method. Return empty result rather than erroring so the
      -- standard client doesn't disconnect us.
      callback(nil, nil)
      return id
    end

    function client.notify(method, _params)
      if method == "exit" then
        closed = true
        if dispatchers and dispatchers.on_exit then
          pcall(dispatchers.on_exit, 0, 0)
        end
      end
      return true
    end

    function client.is_closing() return closed end
    function client.terminate() closed = true end

    return client
  end
end

-- Attach the virtual LSP to a notebook buffer. Safe to call multiple times;
-- vim.lsp.start de-dupes by name+root within a buffer.
function M.attach(buf, nb_getter, rpc_getter)
  if not (vim.lsp and vim.lsp.start) then return end
  pcall(vim.lsp.start, {
    name = "jupynvim_kernel",
    cmd = make_cmd(buf, nb_getter, rpc_getter),
    root_dir = vim.fn.getcwd(),
    bufnr = buf,
    -- Don't reuse: each notebook buffer gets its own session-bound client
    -- because the nb_getter / rpc_getter closures are per-buffer.
    reuse_client = function() return false end,
  })
end

return M

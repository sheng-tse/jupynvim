-- LSP notebook protocol (notebookDocument/*) implementation.
--
-- For LSP servers that advertise `notebookDocumentSync` (Astral's `ty`,
-- and any future notebook-aware server), we send notebookDocument/didOpen,
-- didChange, and didClose. The server receives proper cell structure
-- instead of choking on our rendered-cell textDocument view.
--
-- Why this layer exists:
--   ty (and similar) hooks the `.ipynb` extension. When Neovim auto-sends
--   `textDocument/didOpen` for an `.ipynb` URI, ty registers the buffer
--   as a Text document, then any salsa query that resolves it tries
--   `Notebook::from_source_code(buffer_text)` because is_notebook returns
--   true for the .ipynb extension. That parses the buffer as JSON and
--   fails, emitting "Failed to read notebook ... isn't valid JSON".
--
-- Two design decisions follow from ty's source (see ty_server/src/system.rs
-- and the e2e tests in ty_server/tests/e2e/notebook.rs):
--
--   1. NOT use `file://` for the notebook URI. ty's DocumentKey::from_url
--      routes file:// to a path that any unrelated salsa query can resolve
--      back to disk; if the disk read fails, the same error surfaces
--      independently of our didOpen. Use `jupynvim:/` (virtual) so ty's
--      Opaque path is taken; no disk fallback.
--
--   2. Detach the auto-attached LSP client from the buffer at the Neovim
--      level (vim.lsp.buf_detach_client). This suppresses the auto
--      textDocument/{didOpen,didChange,didClose} cascade that triggers
--      ty's text-Document-with-.ipynb-extension trap. We still hold the
--      client object to send notebookDocument/* messages directly via
--      client:notify(); diagnostics come back via the standard
--      publishDiagnostics handler which we override per-buffer to map
--      cell URIs back to buffer lines.
--
-- Cell URI scheme follows VSCode convention: vscode-notebook-cell:/<path>#<id>.
-- Cell ids in nbformat are stable across opens, so URIs survive reopens.

local M = {}

-- Per-buffer state.
-- {
--   notebook_uri = "jupynvim:/path/to/notebook.ipynb",
--   notebook_version = N,
--   notebook_cells = { { kind, document } },             -- LSP NotebookCell[]
--   cell_text_documents = { { uri, languageId, version, text } },
--   cell_uri_to_id = { [cell_uri] = cell_id },           -- for diagnostic mapping
--   client_ids = { ... },                                -- clients we registered with
-- }
local state = {}

local function notebook_uri_for(path)
  if not path or path == "" then return nil end
  -- Strip drive letter on windows? Path is absolute; just prefix the scheme.
  return "jupynvim:" .. path
end

local function cell_uri(notebook_uri, cell_id)
  -- vscode-notebook-cell scheme matches what ty's tests assume; the path
  -- portion mirrors the notebook path (decorative; ty just uses it as a
  -- unique key) and the fragment carries the cell id for stable identity.
  local path = notebook_uri:gsub("^[^:]+:", "")
  return "vscode-notebook-cell:" .. path .. "#" .. cell_id
end

local function cell_kind(cell)
  -- LSP NotebookCellKind: 1 = Markup, 2 = Code.
  if cell.cell_type == "code" then return 2 end
  return 1
end

local function cell_language(cell, default_lang)
  if cell.cell_type == "markdown" then return "markdown" end
  if cell.cell_type == "raw" then return "plaintext" end
  return default_lang or "python"
end

local function cells_to_protocol(notebook_uri, cells, default_lang)
  local notebook_cells = {}
  local cell_text_documents = {}
  local uri_to_id = {}
  for _, c in ipairs(cells) do
    local uri = cell_uri(notebook_uri, c.id)
    uri_to_id[uri] = c.id
    table.insert(notebook_cells, { kind = cell_kind(c), document = uri })
    table.insert(cell_text_documents, {
      uri = uri,
      languageId = cell_language(c, default_lang),
      version = 1,
      text = c.source or "",
    })
  end
  return notebook_cells, cell_text_documents, uri_to_id
end

local function supports_notebook(client)
  return client and client.server_capabilities
    and client.server_capabilities.notebookDocumentSync ~= nil
end

-- Map a cell URI + cell-relative line back to a buffer line (1-based).
-- Used by publishDiagnostics override so ty's per-cell diagnostics land
-- on the right buffer rows.
local function buf_line_for_cell(buf, target_cell_uri, cell_line)
  local s = state[buf]
  if not s then return nil end
  local cell_id = s.cell_uri_to_id[target_cell_uri]
  if not cell_id then return nil end
  local Notebook = require("jupynvim.notebook")
  local nb = Notebook.get(buf)
  if not nb then return nil end
  local _, ranges = nb:to_lines()
  for _, r in ipairs(ranges) do
    if r.id == cell_id then
      return r.start + cell_line + 1
    end
  end
  return nil
end

-- Wrap a client's notify so textDocument/* notifications targeting any of
-- the listed buffer URIs are silently dropped. The client keeps receiving
-- notebookDocument/* messages we send via the same notify, which sidesteps
-- ty's "auto-textDocument-with-.ipynb-extension trap" without detaching
-- the buffer. Detaching would leave Neovim's change tracking with stale
-- state for the (buf, client) pair, causing nil errors on later edits.
local _wrapped_notify = {}
local function install_notify_wrapper(client_id, suppressed_uri)
  if _wrapped_notify[client_id] then
    table.insert(_wrapped_notify[client_id], suppressed_uri)
    return
  end
  local client = vim.lsp.get_client_by_id(client_id)
  if not client then return end
  local suppressed = { suppressed_uri }
  _wrapped_notify[client_id] = suppressed
  local original_notify = client.notify
  client.notify = function(self, method, params)
    if type(method) == "string" and method:sub(1, 13) == "textDocument/" then
      local uri = params and params.textDocument and params.textDocument.uri
      if uri then
        for _, s in ipairs(suppressed) do
          if uri == s then return true end
        end
      end
    end
    return original_notify(self, method, params)
  end
  -- Wrap request the same way. Cursor moves and many other events trigger
  -- textDocument/* requests (hover, documentHighlight, codeAction, etc.).
  -- Letting these reach the server with an unknown URI gives -32602
  -- "Document is not open in the session" on every move.
  local original_request = client.request
  client.request = function(self, method, params, handler, bufnr)
    if type(method) == "string" and method:sub(1, 13) == "textDocument/" then
      local uri = params and params.textDocument and params.textDocument.uri
      if uri then
        for _, s in ipairs(suppressed) do
          if uri == s then
            -- Find the buffer for this URI so handlers that assert on
            -- ctx.bufnr (e.g. vim/lsp/semantic_tokens.lua) don't crash.
            local target_buf
            for b, _ in pairs(state) do
              if vim.api.nvim_buf_is_valid(b) and vim.uri_from_bufnr(b) == uri then
                target_buf = b
                break
              end
            end
            if handler then
              vim.schedule(function()
                handler(nil, nil, {
                  client_id = self.id,
                  method = method,
                  bufnr = target_buf or vim.api.nvim_get_current_buf(),
                  params = params,
                }, nil)
              end)
            end
            return true, 0
          end
        end
      end
    end
    return original_request(self, method, params, handler, bufnr)
  end
end

-- Override publishDiagnostics for a client so cell-URI diagnostics map
-- to buffer lines. Keep one wrapped version per client so we don't
-- double-wrap on multiple LspAttach events.
local _wrapped_handlers = {}
local function install_diagnostic_handler(client_id)
  if _wrapped_handlers[client_id] then return end
  _wrapped_handlers[client_id] = true
  local client = vim.lsp.get_client_by_id(client_id)
  if not client then return end
  local original = client.handlers and client.handlers["textDocument/publishDiagnostics"]
                  or vim.lsp.handlers["textDocument/publishDiagnostics"]
  client.handlers = client.handlers or {}
  -- Accumulator of mapped diagnostics per (buf, client_id, cell_uri) so each
  -- cell's publish doesn't overwrite the previous one when we re-issue
  -- against the buffer URI. Without this, the last cell publish (often n=0)
  -- wipes diagnostics from earlier cells.
  -- Layout: _accum[buf][client_id][cell_uri] = { diag, diag, ... }
  client.handlers["textDocument/publishDiagnostics"] = function(err, result, ctx, config)
    if not result or not result.uri then
      return original and original(err, result, ctx, config)
    end
    -- Find which buffer holds a notebook with this cell URI.
    local target_buf, target_state
    for buf, s in pairs(state) do
      if s.cell_uri_to_id[result.uri] then
        target_buf = buf
        target_state = s
        break
      end
    end
    if not target_buf then
      -- Not one of our cell URIs; pass through unchanged.
      return original and original(err, result, ctx, config)
    end
    -- Re-write each diagnostic's range to the buffer's line numbering.
    local mapped = {}
    for _, d in ipairs(result.diagnostics or {}) do
      local start_line = buf_line_for_cell(target_buf, result.uri, d.range.start.line)
      local end_line = buf_line_for_cell(target_buf, result.uri, d.range["end"].line)
      if start_line and end_line then
        local copy = vim.deepcopy(d)
        copy.range.start.line = start_line - 1
        copy.range["end"].line = end_line - 1
        table.insert(mapped, copy)
      end
    end
    -- Update the accumulator for this cell and re-issue the FULL list
    -- across all cells so we don't overwrite previous publishes.
    target_state.diag_accum = target_state.diag_accum or {}
    target_state.diag_accum[ctx.client_id] = target_state.diag_accum[ctx.client_id] or {}
    target_state.diag_accum[ctx.client_id][result.uri] = mapped
    local merged = {}
    for _, cell_diags in pairs(target_state.diag_accum[ctx.client_id]) do
      for _, d in ipairs(cell_diags) do table.insert(merged, d) end
    end
    local rewritten = {
      uri = vim.uri_from_bufnr(target_buf),
      diagnostics = merged,
      version = result.version,
    }
    return original and original(err, rewritten, ctx, config)
  end
end

-- Public: called from init.lua's LspAttach autocmd. If `client` advertises
-- notebookDocumentSync, detach from the buffer (suppressing the auto
-- textDocument cascade) and send notebookDocument/didOpen.
function M.on_attach(buf, nb, client)
  if not supports_notebook(client) then return end
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local nb_path = nb and nb.path
  if not nb_path then return end

  local notebook_uri = notebook_uri_for(nb_path)
  local default_lang = nb and nb.notebook_meta
    and nb.notebook_meta.language or "python"

  local s = state[buf]
  if not s then
    local notebook_cells, cell_text_documents, uri_to_id = cells_to_protocol(
      notebook_uri, nb.cells, default_lang)
    s = {
      notebook_uri = notebook_uri,
      notebook_version = 1,
      notebook_cells = notebook_cells,
      cell_text_documents = cell_text_documents,
      cell_uri_to_id = uri_to_id,
      client_ids = {},
    }
    state[buf] = s
  end

  -- Only send didOpen + register the diagnostic handler once per (buf, client).
  for _, cid in ipairs(s.client_ids) do
    if cid == client.id then
      -- Re-attach without re-init: just make sure the suppression is still
      -- in place (idempotent install).
      install_notify_wrapper(client.id, vim.uri_from_bufnr(buf))
      return
    end
  end
  table.insert(s.client_ids, client.id)

  install_diagnostic_handler(client.id)

  -- Send textDocument/didClose now (before wrapping notify) so the server
  -- forgets the textDocument view it briefly held during the auto-attach.
  -- This retracts the failed-JSON-parse diagnostic.
  local file_uri = vim.uri_from_bufnr(buf)
  pcall(function()
    client:notify("textDocument/didClose", {
      textDocument = { uri = file_uri },
    })
  end)

  -- Now wrap notify to silently drop future textDocument/* messages
  -- targeting this URI. Without this, Neovim's change tracker auto-sends
  -- textDocument/didChange on every edit, which the server rejects with
  -- -32602 because the textDocument is closed. notebookDocument/* messages
  -- still flow through; the server stays "attached" at the Neovim level
  -- which keeps change-tracking state intact (avoids buf_detach nil errors).
  install_notify_wrapper(client.id, file_uri)

  client:notify("notebookDocument/didOpen", {
    notebookDocument = {
      uri = s.notebook_uri,
      notebookType = "jupyter-notebook",
      version = s.notebook_version,
      cells = s.notebook_cells,
    },
    cellTextDocuments = s.cell_text_documents,
  })
  -- NOTE: ty uses push diagnostics (publishDiagnostics) for notebooks/cells
  -- per its source comment in crates/ty_server/src/server/api/diagnostics.rs.
  -- Sending textDocument/diagnostic for a cell URI panics ty's handler
  -- (LspDiagnostics::NotebookDocument hits expect_text_document → panic!).
  -- So we don't pull for cells. ty's push path comes through our overridden
  -- publishDiagnostics handler the same way basedpyright's does.
end

-- Public: called from init.lua's TextChanged autocmd. Diffs cells against
-- last-known state and sends notebookDocument/didChange to registered
-- clients. Per-cell full sync (changes = { text = full_cell_text }).
function M.on_text_change(buf, nb)
  local s = state[buf]
  if not s or #s.client_ids == 0 then return end

  local notebook_uri = s.notebook_uri
  local default_lang = nb and nb.notebook_meta
    and nb.notebook_meta.language or "python"
  local new_notebook_cells, new_cell_text_documents, new_uri_to_id = cells_to_protocol(
    notebook_uri, nb.cells, default_lang)

  -- Index old/new by URI for diff computation.
  local old_by_uri = {}
  for i, c in ipairs(s.cell_text_documents) do
    old_by_uri[c.uri] = { idx = i, text = c.text, version = c.version }
  end
  local new_by_uri = {}
  for i, c in ipairs(new_cell_text_documents) do
    new_by_uri[c.uri] = { idx = i, text = c.text, languageId = c.languageId }
  end

  -- Structural changes: which cell URIs were added or removed.
  local added = {}
  local removed = {}
  for uri, _ in pairs(new_by_uri) do
    if not old_by_uri[uri] then table.insert(added, uri) end
  end
  for uri, _ in pairs(old_by_uri) do
    if not new_by_uri[uri] then table.insert(removed, uri) end
  end

  -- Content changes: same URI, different text. Bump per-cell version.
  local content_changes = {}
  for uri, new_c in pairs(new_by_uri) do
    local old_c = old_by_uri[uri]
    if old_c and old_c.text ~= new_c.text then
      local new_version = (old_c.version or 1) + 1
      new_cell_text_documents[new_c.idx].version = new_version
      table.insert(content_changes, {
        document = { uri = uri, version = new_version },
        changes = { { text = new_c.text } },
      })
    elseif old_c then
      new_cell_text_documents[new_c.idx].version = old_c.version or 1
    end
  end

  local structural = #added > 0 or #removed > 0
  if #content_changes == 0 and not structural then return end

  s.notebook_version = s.notebook_version + 1

  local change_event = {}
  if structural then
    -- Send a single ArrayChange that replaces the whole cell list. Simpler
    -- than tracking individual moves; ty handles this.
    local opened_docs = {}
    for _, uri in ipairs(added) do
      local idx = new_by_uri[uri].idx
      table.insert(opened_docs, new_cell_text_documents[idx])
    end
    local closed_docs = {}
    for _, uri in ipairs(removed) do
      table.insert(closed_docs, { uri = uri })
    end
    change_event.cells = {
      structure = {
        array = {
          start = 0,
          deleteCount = #s.notebook_cells,
          cells = new_notebook_cells,
        },
        didOpen = opened_docs,
        didClose = closed_docs,
      },
    }
  end
  if #content_changes > 0 then
    change_event.cells = change_event.cells or {}
    change_event.cells.textContent = content_changes
  end

  for _, cid in ipairs(s.client_ids) do
    local client = vim.lsp.get_client_by_id(cid)
    if client then
      client:notify("notebookDocument/didChange", {
        notebookDocument = { uri = s.notebook_uri, version = s.notebook_version },
        change = change_event,
      })
    end
  end

  s.notebook_cells = new_notebook_cells
  s.cell_text_documents = new_cell_text_documents
  s.cell_uri_to_id = new_uri_to_id
end

-- Public: called from init.lua's BufWipeout. Sends notebookDocument/didClose
-- and clears state.
function M.on_close(buf)
  local s = state[buf]
  if not s then return end
  local cell_doc_ids = {}
  for _, c in ipairs(s.cell_text_documents) do
    table.insert(cell_doc_ids, { uri = c.uri })
  end
  for _, cid in ipairs(s.client_ids) do
    local client = vim.lsp.get_client_by_id(cid)
    if client then
      client:notify("notebookDocument/didClose", {
        notebookDocument = { uri = s.notebook_uri },
        cellTextDocuments = cell_doc_ids,
      })
    end
  end
  state[buf] = nil
end

-- Public: get the cell URI for a given buffer line (1-based). Used by
-- request-translation paths (hover, completion) to redirect to the cell.
function M.cell_pos_for_buf_line(buf, nb, lnum, col)
  local s = state[buf]
  if not s then return nil end
  local _, ranges = nb:to_lines()
  for _, r in ipairs(ranges) do
    if (lnum - 1) >= r.start and (lnum - 1) < r.stop then
      local cell_line = (lnum - 1) - r.start
      return cell_uri(s.notebook_uri, r.id), cell_line, col
    end
  end
  return nil
end

return M

-- Give attached LSP servers a code-only view of jupynvim buffers.
--
-- basedpyright (and any whole-file Python LSP) parses the entire buffer text,
-- so markdown cells, separator markers, and Out[N] headers leak into the
-- parser and corrupt diagnostics in the next code cell ("with both side
-- bars" → fake `with` statement → "Expected indented block" on the next
-- `for:` line).
--
-- Strategy: monkey-patch vim.lsp._buf_get_full_text. For jupynvim buffers,
-- return the buffer text with every non-code line replaced by an empty line.
-- Code-cell line numbers stay aligned, so diagnostics map back to the same
-- buffer positions. Non-jupynvim buffers go through the original function.
--
-- We also force `flags.allow_incremental_sync = false` per config so every
-- edit triggers a Full-sync didChange that routes through the patched
-- function (incremental sync uses nvim_buf_get_lines directly, which we
-- can't intercept).

local M = {}

local function clean_lines_for(bufnr)
  local ok, Notebook = pcall(require, "jupynvim.notebook")
  if not ok then return nil end
  local nb = Notebook.get(bufnr)
  if not nb then return nil end
  local raw = vim.api.nvim_buf_get_lines(bufnr, 0, -1, true)
  local _, ranges = nb:to_lines()
  local is_code = {}
  for _, r in ipairs(ranges) do
    if r.type == "code" then
      for ln = r.start, r.stop - 1 do is_code[ln] = true end
    end
  end
  for i = 1, #raw do
    if not is_code[i - 1] then raw[i] = "" end
  end
  return raw
end

function M.setup()
  if M._patched then return end
  M._patched = true
  local orig = vim.lsp._buf_get_full_text
  if type(orig) ~= "function" then return end
  vim.lsp._buf_get_full_text = function(bufnr)
    local cleaned = clean_lines_for(bufnr)
    if not cleaned then return orig(bufnr) end
    local line_ending = vim.lsp._buf_get_line_ending(bufnr)
    local text = table.concat(cleaned, line_ending)
    if vim.bo[bufnr].eol then text = text .. line_ending end
    return text
  end
end

-- Mutate an LSP config so it uses Full sync (so every change re-sends the
-- whole document via _buf_get_full_text, which we patched).
function M.force_full_sync(cfg)
  cfg.flags = cfg.flags or {}
  cfg.flags.allow_incremental_sync = false
  return cfg
end

return M

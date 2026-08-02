-- Restrict LSP diagnostics to code-cell line ranges.
--
-- basedpyright (and any other Python LSP) treats the whole notebook buffer as
-- one Python file, so it complains about markdown text, separator markers,
-- and rendered Out[N] headers. This module wraps `vim.diagnostic.handlers`
-- so that for jupynvim buffers, diagnostics outside code cells are filtered
-- out before being shown. Non-jupynvim buffers are untouched.

local M = {}

local function filter_for_buf(bufnr, diagnostics)
  local ok, Notebook = pcall(require, "jupynvim.notebook")
  if not ok then return diagnostics end
  local nb = Notebook.get(bufnr)
  if not nb then return diagnostics end

  -- Build a sorted list of {start_0, stop_0} half-open ranges for code cells.
  local _, ranges = nb:to_lines()
  local code_ranges = {}
  for _, r in ipairs(ranges) do
    if r.type == "code" then
      table.insert(code_ranges, { r.start, r.stop })
    end
  end
  if #code_ranges == 0 then return {} end

  local function in_code(lnum)
    for _, cr in ipairs(code_ranges) do
      if lnum >= cr[1] and lnum < cr[2] then return true end
    end
    return false
  end

  local out = {}
  for _, d in ipairs(diagnostics) do
    if in_code(d.lnum) then table.insert(out, d) end
  end
  return out
end

function M.setup()
  if M._installed then return end
  M._installed = true
  for _, name in ipairs({ "virtual_text", "signs", "underline", "virtual_lines" }) do
    local orig = vim.diagnostic.handlers[name]
    if orig and type(orig.show) == "function" then
      local wrapped = setmetatable({}, { __index = orig })
      wrapped.show = function(ns, bufnr, diagnostics, opts)
        diagnostics = filter_for_buf(bufnr, diagnostics)
        return orig.show(ns, bufnr, diagnostics, opts)
      end
      if type(orig.hide) == "function" then
        wrapped.hide = function(...) return orig.hide(...) end
      end
      vim.diagnostic.handlers[name] = wrapped
    end
  end
end

return M

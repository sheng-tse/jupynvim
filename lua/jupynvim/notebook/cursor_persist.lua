-- Per-notebook cursor-position persistence.
--
-- Stores where the cursor last sat in each cell, plus the active position, so
-- reopening a notebook restores it as if it was never closed. Kept in a sidecar
-- state file (stdpath("state")/jupynvim/cursors.json), NOT in the .ipynb, so the
-- notebook you commit stays clean. Keyed by the buffer's full path / URI.
--
-- Entry shape: { cells = { {idx, line, col, fp}, ... }, last = {idx, line, col, fp} }
-- idx is the cell index; line/col are 0-based offsets from the cell's first
-- source line (so they survive absolute line numbers shifting); fp is that first
-- source line, a fingerprint used to skip a position whose cell changed.
local M = {}

local function store_file()
  local override = vim.env.JUPYNVIM_CURSOR_STORE  -- tests point this at a temp file
  if override and override ~= "" then return override end
  local dir = vim.fn.stdpath("state") .. "/jupynvim"
  pcall(vim.fn.mkdir, dir, "p")
  return dir .. "/cursors.json"
end

local function read_all()
  local f = io.open(store_file(), "r")
  if not f then return {} end
  local s = f:read("*a")
  f:close()
  if not s or s == "" then return {} end
  local ok, t = pcall(vim.json.decode, s)
  return (ok and type(t) == "table") and t or {}
end

local function write_all(t)
  local f = io.open(store_file(), "w")
  if not f then return end
  local ok, s = pcall(vim.json.encode, t)
  if ok then f:write(s) end
  f:close()
end

function M.save(key, entry)
  if not key or key == "" then return end
  local all = read_all()
  all[key] = entry
  write_all(all)
end

function M.load(key)
  if not key or key == "" then return nil end
  return read_all()[key]
end

return M

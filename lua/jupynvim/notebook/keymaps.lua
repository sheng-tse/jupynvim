-- Buffer-local keybindings for a notebook buffer.
--
-- Defaults can be overridden or disabled per-action via the user's setup:
--
--   require("jupynvim").setup({
--     keymaps = {
--       run_advance = "<leader>jr",                      -- replace the lhs
--       run_stay = { lhs = "<leader>js", mode = "n" },   -- lhs and mode
--       move_up = false,                                 -- disable a binding
--     },
--     disable_default_keymaps = false,  -- set true to skip ALL defaults
--   })
--
-- A replaced lhs that starts with a printable key, which includes a space
-- leader, is not bound in insert mode unless `mode` says so, because an
-- insert-mode map on a printable prefix stalls every time that key is typed.

local M = {}

-- Default keybindings. Each entry: { mode, lhs, action_name, desc }.
-- action_name maps to a function in init.lua's public api.
M.defaults = {
  run_advance      = { mode = { "n", "i" }, lhs = "<S-CR>",     desc = "Run cell + advance" },
  run_stay         = { mode = { "n", "i" }, lhs = "<C-CR>",     desc = "Run cell" },
  run_advance_alt  = { mode = "n",          lhs = "<leader>nr", desc = "Run cell + advance" },
  run_all          = { mode = "n",          lhs = "<leader>nR", desc = "Run all cells" },
  run_above        = { mode = "n",          lhs = "<leader>nA", desc = "Run all cells above" },
  run_below        = { mode = "n",          lhs = "<leader>nB", desc = "Run all cells below" },
  add_above        = { mode = "n",          lhs = "<leader>na", desc = "Add cell above" },
  add_below        = { mode = "n",          lhs = "<leader>nb", desc = "Add cell below" },
  delete_cell      = { mode = "n",          lhs = "<leader>nd", desc = "Delete cell" },
  move_up          = { mode = "n",          lhs = "<leader>nk", desc = "Move cell up" },
  move_down        = { mode = "n",          lhs = "<leader>nj", desc = "Move cell down" },
  to_markdown      = { mode = "n",          lhs = "<leader>nm", desc = "→ markdown cell" },
  to_code          = { mode = "n",          lhs = "<leader>ny", desc = "→ code cell" },
  pick_kernel      = { mode = "n",          lhs = "<leader>nK", desc = "Pick kernel" },
  start_kernel     = { mode = "n",          lhs = "<leader>ns", desc = "Start kernel" },
  stop_kernel      = { mode = "n",          lhs = "<leader>nS", desc = "Stop kernel" },
  interrupt_kernel = { mode = "n",          lhs = "<leader>ni", desc = "Interrupt kernel" },
  restart_kernel   = { mode = "n",          lhs = "<leader>nx", desc = "Restart kernel" },
  expand_output    = { mode = "n",          lhs = "<leader>no", desc = "Expand/collapse truncated output" },
  clear_output     = { mode = "n",          lhs = "<leader>nc", desc = "Clear current cell output" },
  clear_all        = { mode = "n",          lhs = "<leader>nC", desc = "Clear all outputs" },
  next_cell        = { mode = "n",          lhs = "]c",         desc = "Next cell" },
  prev_cell        = { mode = "n",          lhs = "[c",         desc = "Prev cell" },
  next_image       = { mode = "n",          lhs = "]i",         desc = "Next image cell" },
  prev_image       = { mode = "n",          lhs = "[i",         desc = "Prev image cell" },
  enter_output_dn  = { mode = "n",          lhs = "<C-j>",      desc = "Enter output below" },
  enter_output_up  = { mode = "n",          lhs = "<C-k>",      desc = "Enter output above" },
  save_image       = { mode = "n",          lhs = "<leader>nI", desc = "Save cell image" },
  delete_image     = { mode = "n",          lhs = "<leader>nD", desc = "Delete cell image" },
  refresh          = { mode = "n",          lhs = "<leader>nL", desc = "Refresh notebook display" },
  open_link        = { mode = "n",          lhs = "gx",         desc = "Open link under cursor" },
}

-- Action name → function-builder taking (buf, api).
-- Each builder returns the rhs callback for that action.
local actions = {
  run_advance      = function(buf, api) return function() api.run_cell(buf, { advance = true }) end end,
  run_stay         = function(buf, api) return function() api.run_cell(buf, { advance = false }) end end,
  run_advance_alt  = function(buf, api) return function() api.run_cell(buf, { advance = true }) end end,
  run_all          = function(buf, api) return function() api.run_all(buf) end end,
  run_above        = function(buf, api) return function() api.run_above(buf) end end,
  run_below        = function(buf, api) return function() api.run_below(buf) end end,
  -- the keys typed after one of these wait for the backend's answer, which
  -- is when the cells change
  add_above        = function(buf, api) return function() api.add_cell(buf, "above"); api._settle(buf) end end,
  add_below        = function(buf, api) return function() api.add_cell(buf, "below"); api._settle(buf) end end,
  delete_cell      = function(buf, api) return function() api.delete_cell(buf); api._settle(buf) end end,
  move_up          = function(buf, api) return function() api.move_cell(buf, -1); api._settle(buf) end end,
  move_down        = function(buf, api) return function() api.move_cell(buf, 1); api._settle(buf) end end,
  to_markdown      = function(buf, api) return function() api.set_cell_type(buf, "markdown") end end,
  to_code          = function(buf, api) return function() api.set_cell_type(buf, "code") end end,
  pick_kernel      = function(buf, api) return function() api.kernel_picker(buf) end end,
  start_kernel     = function(buf, api) return function() api.start_kernel(buf) end end,
  stop_kernel      = function(buf, api) return function() api.stop_kernel(buf) end end,
  interrupt_kernel = function(buf, api) return function() api.interrupt_kernel(buf) end end,
  restart_kernel   = function(buf, api) return function() api.restart_kernel(buf) end end,
  expand_output    = function(buf, api) return function() api.toggle_output_expand(buf) end end,
  clear_output     = function(buf, api) return function() api.clear_cell_output(buf) end end,
  clear_all        = function(buf, api) return function() api.clear_outputs(buf) end end,
  next_cell        = function(buf, api) return function() api.jump_cell(buf, 1) end end,
  prev_cell        = function(buf, api) return function() api.jump_cell(buf, -1) end end,
  next_image       = function(buf, api) return function() api.jump_image(buf, 1) end end,
  prev_image       = function(buf, api) return function() api.jump_image(buf, -1) end end,
  enter_output_dn  = function(buf, api) return function() api.enter_output(buf, "down") end end,
  enter_output_up  = function(buf, api) return function() api.enter_output(buf, "up") end end,
  save_image       = function(buf, api) return function() api.save_image(buf) end end,
  delete_image     = function(buf, api) return function() api.delete_image(buf) end end,
  refresh          = function(buf, api) return function() api.refresh(buf) end end,
  open_link        = function(buf, api) return function() api.open_link(buf) end end,
}

-- Does `lhs` begin with a key that inserts text? keycode expands <leader> the
-- way keymap.set does, and special keys like <S-CR> or <F5> start with
-- K_SPECIAL (0x80) while control keys sit below 0x20.
local function starts_printable(lhs)
  local ok, keys = pcall(vim.keycode, lhs)
  local b = ok and keys:byte(1) or nil
  return b ~= nil and b >= 0x20 and b ~= 0x7f and b ~= 0x80
end

-- Resolve an action's lhs and mode from its default and the user's override.
-- Returns nil when the action should not be bound.
local function resolve(def, override)
  if override == false then return nil end
  local lhs, mode, mode_given = def.lhs, def.mode, false
  if type(override) == "string" then
    lhs = override
  elseif type(override) == "table" then
    if override.lhs ~= nil then lhs = override.lhs end
    if override.mode ~= nil then mode, mode_given = override.mode, true end
  end
  -- #30: the default modes of run_stay and run_advance include insert. Keep
  -- that for their own keys, but not for a leader or other printable prefix,
  -- or space in a cell waits out timeoutlen every time it is typed.
  if not mode_given and lhs ~= def.lhs and type(mode) == "table"
     and type(lhs) == "string" and starts_printable(lhs) then
    mode = vim.tbl_filter(function(m) return m ~= "i" end, mode)
  end
  return lhs, mode
end

local warned = {}

-- Bind every default (honouring overrides) onto `buf`.
local function bind_all(buf, api)
  local cfg = api.config or {}
  local overrides = cfg.keymaps or {}
  for name, def in pairs(M.defaults) do
    local lhs, mode = resolve(def, overrides[name])
    local builder = actions[name]
    if lhs ~= nil and builder and not (type(mode) == "table" and #mode == 0) then
      -- keymap.set throws on an unknown mode or an empty lhs. Uncaught, that
      -- aborted M.open halfway and left the notebook half set up. A bad
      -- override now falls back to the default binding, and says so once the
      -- open has redrawn, or the redraw would wipe the message.
      local opts = { buffer = buf, silent = true, desc = def.desc }
      local ok, err = pcall(vim.keymap.set, mode, lhs, builder(buf, api), opts)
      if not ok then
        pcall(vim.keymap.set, def.mode, def.lhs, builder(buf, api), opts)
        if not warned[name .. tostring(err)] then
          warned[name .. tostring(err)] = true
          local msg = ("jupynvim: keymaps.%s is invalid (%s), using the default %s")
            :format(name, err, def.lhs)
          vim.schedule(function() vim.notify(msg, vim.log.levels.WARN) end)
        end
      end
    end
  end
end

function M.attach(buf, api)
  local cfg = api.config or {}
  if cfg.disable_default_keymaps then return end
  bind_all(buf, api)
  -- Bind again once the FileType autocmds have run. We attach during
  -- BufReadCmd, and plugins that map the same keys BUFFER-LOCALLY on FileType
  -- land afterwards and win: LazyVim's treesitter-textobjects takes ]c and [c,
  -- so the documented next/prev-cell motions silently did nothing. Same
  -- last-writer-wins problem the global dispatch keys solve by binding late.
  vim.schedule(function()
    if vim.api.nvim_buf_is_valid(buf) then bind_all(buf, api) end
  end)
  vim.defer_fn(function()
    if vim.api.nvim_buf_is_valid(buf) then bind_all(buf, api) end
  end, 300)
end

return M

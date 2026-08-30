-- Buffer-local keybindings for a notebook buffer.
--
-- Defaults can be overridden or disabled per-action via the user's setup:
--
--   require("jupynvim").setup({
--     keymaps = {
--       run_advance = "<leader>jr",   -- override lhs, keep default mode
--       run_stay = false,             -- disable a binding
--     },
--     disable_default_keymaps = false,  -- set true to skip ALL defaults
--   })

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
  add_above        = function(buf, api) return function() api.add_cell(buf, "above") end end,
  add_below        = function(buf, api) return function() api.add_cell(buf, "below") end end,
  delete_cell      = function(buf, api) return function() api.delete_cell(buf) end end,
  move_up          = function(buf, api) return function() api.move_cell(buf, -1) end end,
  move_down        = function(buf, api) return function() api.move_cell(buf, 1) end end,
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

-- Bind every default (honouring overrides) onto `buf`.
local function bind_all(buf, api)
  local cfg = api.config or {}
  local overrides = cfg.keymaps or {}
  for name, def in pairs(M.defaults) do
    local override = overrides[name]
    -- false explicitly disables the binding; nil leaves the default in place
    if override == false then
      -- skip
    else
      local lhs = def.lhs
      local mode = def.mode
      if type(override) == "string" then
        lhs = override
      elseif type(override) == "table" then
        if override.lhs then lhs = override.lhs end
        if override.mode then mode = override.mode end
      end
      local builder = actions[name]
      if builder then
        vim.keymap.set(mode, lhs, builder(buf, api),
          { buffer = buf, silent = true, desc = def.desc })
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

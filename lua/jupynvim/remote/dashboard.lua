-- jupynvim remote dashboard: a LazyVim-style landing screen shown in the main
-- pane while SSH-connected (instead of the local dashboard, whose Find File /
-- Recent act on the LOCAL machine). Logo + quick actions + connection info,
-- centered both axes and re-centered on resize.

local M = {}

-- ── logo (swap M.logo to restyle) — "ANSI Shadow" JUPYNVIM ──
M.logo = {
  "     ██╗██╗   ██╗██████╗ ██╗   ██╗███╗   ██╗██╗   ██╗██╗███╗   ███╗",
  "     ██║██║   ██║██╔══██╗╚██╗ ██╔╝████╗  ██║██║   ██║██║████╗ ████║",
  "     ██║██║   ██║██████╔╝ ╚████╔╝ ██╔██╗ ██║██║   ██║██║██╔████╔██║",
  "██   ██║██║   ██║██╔═══╝   ╚██╔╝  ██║╚██╗██║╚██╗ ██╔╝██║██║╚██╔╝██║",
  "╚█████╔╝╚██████╔╝██║        ██║   ██║ ╚████║ ╚████╔╝ ██║██║ ╚═╝ ██║",
  " ╚════╝  ╚═════╝ ╚═╝        ╚═╝   ╚═╝  ╚═══╝  ╚═══╝  ╚═╝╚═╝     ╚═╝",
}

-- ANSI Shadow block font for the logo, in Knicks orange.
vim.api.nvim_set_hl(0, "JupynvimDashLogo",   { fg = "#F58426", bold = true })
vim.api.nvim_set_hl(0, "JupynvimDashIcon",   { default = true, link = "Special" })
vim.api.nvim_set_hl(0, "JupynvimDashKey",    { default = true, link = "Special" })
vim.api.nvim_set_hl(0, "JupynvimDashDesc",   { default = true, link = "Normal" })
vim.api.nvim_set_hl(0, "JupynvimDashFooter", { default = true, link = "Comment" })
vim.api.nvim_set_hl(0, "JupynvimDashInfo",   { default = true, link = "Title" })
local ns = vim.api.nvim_create_namespace("jupynvim.remote.dashboard")

-- Icons by codepoint (classic FontAwesome, present in every Nerd Font patch —
-- the same family mini.icons/LazyVim use, which render in this setup).
-- Encoding by codepoint avoids editor/byte ambiguity in the literal glyph.
local function u(cp) return vim.fn.nr2char(cp) end
local ICON = {
  folder = u(0xF07B),   --
  term   = u(0xF120),   --
  search = u(0xF002),   --
  home   = u(0xF015),   --
  power  = u(0xF011),   --
}

local actions = {
  { key = "e", icon = ICON.folder, desc = "Explorer",        run = function(a) require("jupynvim").remote_browse(a) end },
  { key = "t", icon = ICON.term,   desc = "Remote terminal", run = function(a) require("jupynvim.remote.term").open(a) end },
  { key = "g", icon = ICON.search, desc = "Search remote",   run = function(a)
      require("jupynvim.remote.pick").grep(a)  -- live grep picker
    end },
  { key = "l", icon = ICON.home,   desc = "Local backend",   run = function()
      local J = require("jupynvim")
      J.use_local()
      vim.notify("jupynvim: switched to local backend", vim.log.levels.INFO)
      J.explorer()  -- active alias cleared → opens the local (snacks) explorer
    end },
  { key = "q", icon = ICON.power,  desc = "Close",           run = function() vim.cmd("q") end },
}

local KEYHINT = "notebook:  <leader>nr run · <leader>nR run-all · <leader>nK kernel · <C-j/k> output"

local shared_buf
local dw = vim.fn.strdisplaywidth

-- Build/refresh the dashboard for `alias`/`root`, centered to `win`'s size.
function M.build(alias, root, win)
  local width, height = 80, 24
  if win and vim.api.nvim_win_is_valid(win) then
    width = vim.api.nvim_win_get_width(win)
    height = vim.api.nvim_win_get_height(win)
  end
  local buf = (shared_buf and vim.api.nvim_buf_is_valid(shared_buf)) and shared_buf
    or vim.api.nvim_create_buf(false, true)
  shared_buf = buf

  local lines, hl = {}, {}  -- hl: { row0, col0, col1, group }
  local function center_pad(w) return math.max(0, math.floor((width - w) / 2)) end
  local function emit(text, group)
    table.insert(lines, text)
    if group then table.insert(hl, { #lines - 1, 0, -1, group }) end
  end

  -- Logo (centered as a block to its own max width)
  local logo_w = 0
  for _, l in ipairs(M.logo) do logo_w = math.max(logo_w, dw(l)) end
  local logo_pad = center_pad(logo_w)
  for _, l in ipairs(M.logo) do
    table.insert(lines, string.rep(" ", logo_pad) .. l)
    table.insert(hl, { #lines - 1, 0, -1, "JupynvimDashLogo" })
  end

  emit("")
  local info = " " .. alias .. " · " .. (root or "")
  emit(string.rep(" ", center_pad(dw(info))) .. info, "JupynvimDashInfo")
  emit("")
  emit("")

  -- Action rows: LazyVim-style — icon + desc left, key far right, fixed block.
  local block_w = math.min(46, math.max(30, width - 8))
  local block_pad = center_pad(block_w)
  for _, a in ipairs(actions) do
    local lead = a.icon .. "   " .. a.desc
    local gap = math.max(1, block_w - dw(lead) - dw(a.key))
    local row = string.rep(" ", block_pad) .. lead .. string.rep(" ", gap) .. a.key
    table.insert(lines, row)
    local r0 = #lines - 1
    table.insert(hl, { r0, block_pad, block_pad + #a.icon, "JupynvimDashIcon" })
    table.insert(hl, { r0, #row - #a.key, -1, "JupynvimDashKey" })
  end

  emit("")
  emit("")
  emit(string.rep(" ", center_pad(dw(KEYHINT))) .. KEYHINT, "JupynvimDashFooter")
  emit("")
  local ver = "jupynvim · connected to " .. alias
  emit(string.rep(" ", center_pad(dw(ver))) .. ver, "JupynvimDashFooter")

  -- Vertical centering: prepend blank lines.
  local top = math.max(0, math.floor((height - #lines) / 2))
  local padded = {}
  for _ = 1, top do table.insert(padded, "") end
  for _, l in ipairs(lines) do table.insert(padded, l) end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, padded)
  vim.bo[buf].modifiable = false
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].buflisted = false
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].filetype = "jupynvim-dashboard"
  vim.b[buf].jupynvim_dashboard = true
  vim.b[buf].jupynvim_alias = alias
  vim.b[buf].jupynvim_root = root
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, h in ipairs(hl) do
    -- col1 = -1 means "to end of line", which extmarks spell as the next row
    -- at col 0. Passing end_col = -1 errors and the pcall would eat it.
    local row = h[1] + top
    local o = { hl_group = h[4], end_col = h[3] }
    if h[3] < 0 then o.end_row, o.end_col = row + 1, 0 end
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, h[2], o)
  end

  for _, a in ipairs(actions) do
    vim.keymap.set("n", a.key, function() a.run(alias) end,
      { buffer = buf, nowait = true, silent = true })
  end
  -- scope="local" so these don't leak to the GLOBAL option (the `vim.wo[w].x`
  -- form on the current window does, which was turning line numbers off
  -- everywhere). See remote_explorer.setlocalwin.
  local function setlocalwin(w, name, val)
    pcall(vim.api.nvim_set_option_value, name, val, { scope = "local", win = w })
  end
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(w) == buf then
      setlocalwin(w, "number", false)
      setlocalwin(w, "relativenumber", false)
      setlocalwin(w, "signcolumn", "no")
      setlocalwin(w, "cursorline", false)
      setlocalwin(w, "fillchars", "eob: ")
    end
  end
  return buf
end

-- Swap any startup-dashboard window (local snacks/alpha/starter, or our own)
-- for the jupynvim remote dashboard. Skips floating windows and the explorer.
-- Used by the explorers when a session connects.
function M.place(alias, root)
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative == "" then
      local ft = vim.bo[vim.api.nvim_win_get_buf(w)].filetype or ""
      if ft == "snacks_dashboard" or ft == "dashboard" or ft == "alpha"
         or ft == "starter" or ft == "ministarter" or ft == "jupynvim-dashboard" then
        local dbuf = M.build(alias, root or "~", w)
        pcall(vim.api.nvim_win_set_buf, w, dbuf)
      end
    end
  end
  vim.schedule(function() M.refresh_layout() end)
end

-- Re-center the dashboard in whatever window currently shows it (on resize /
-- explorer toggle). No-op if it isn't visible.
function M.refresh_layout()
  if not (shared_buf and vim.api.nvim_buf_is_valid(shared_buf)) then return end
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(w) == shared_buf then
      M.build(vim.b[shared_buf].jupynvim_alias, vim.b[shared_buf].jupynvim_root, w)
      return
    end
  end
end

-- Re-center on any layout change that affects the dashboard window's size:
-- resize, explorer toggle (WinResized), and entering the dashboard window.
vim.api.nvim_create_autocmd({ "WinResized", "VimResized", "WinEnter", "BufWinEnter" }, {
  group = vim.api.nvim_create_augroup("JupynvimDashboardResize", { clear = true }),
  callback = function() vim.schedule(M.refresh_layout) end,
})

return M

-- jupynvim remote dashboard: a LazyVim-style landing screen shown in the main
-- pane while SSH-connected (instead of the local dashboard, whose Find File /
-- Recent act on the LOCAL machine). Logo + quick actions + connection info.

local M = {}

-- ── logo (swap M.logo to restyle; see the alternatives in chat) ──
-- Option A: "ANSI Shadow"
M.logo = {
  "     ██╗██╗   ██╗██████╗ ██╗   ██╗███╗   ██╗██╗   ██╗██╗███╗   ███╗",
  "     ██║██║   ██║██╔══██╗╚██╗ ██╔╝████╗  ██║██║   ██║██║████╗ ████║",
  "     ██║██║   ██║██████╔╝ ╚████╔╝ ██╔██╗ ██║██║   ██║██║██╔████╔██║",
  "██   ██║██║   ██║██╔═══╝   ╚██╔╝  ██║╚██╗██║╚██╗ ██╔╝██║██║╚██╔╝██║",
  "╚█████╔╝╚██████╔╝██║        ██║   ██║ ╚████║ ╚████╔╝ ██║██║ ╚═╝ ██║",
  " ╚════╝  ╚═════╝ ╚═╝        ╚═╝   ╚═╝  ╚═══╝  ╚═══╝  ╚═╝╚═╝     ╚═╝",
}

vim.api.nvim_set_hl(0, "JupynvimDashLogo",   { default = true, link = "Function" })
vim.api.nvim_set_hl(0, "JupynvimDashKey",    { default = true, link = "Special" })
vim.api.nvim_set_hl(0, "JupynvimDashDesc",   { default = true, link = "Normal" })
vim.api.nvim_set_hl(0, "JupynvimDashFooter", { default = true, link = "Comment" })
vim.api.nvim_set_hl(0, "JupynvimDashInfo",   { default = true, link = "Title" })
local ns = vim.api.nvim_create_namespace("jupynvim.remote_dashboard")

-- Quick actions (single-key, fired inside the dashboard buffer).
local actions = {
  { key = "e", icon = "", desc = "Explorer",        run = function(a) require("jupynvim").remote_browse(a) end },
  { key = "t", icon = "", desc = "Remote terminal", run = function(a) require("jupynvim.remote_term").open(a) end },
  { key = "g", icon = "", desc = "Search remote",   run = function(a)
      vim.ui.input({ prompt = "Grep " .. a .. ": " }, function(pat)
        if pat and pat ~= "" then vim.cmd("JupynvimGrep " .. a .. " " .. pat) end
      end)
    end },
  { key = "l", icon = "", desc = "Local backend",   run = function() require("jupynvim").use_local() end },
  { key = "q", icon = "", desc = "Quit",            run = function() vim.cmd("qa") end },
}

-- Reference line of notebook keymaps (informational, not bound here).
local KEYHINT = "notebook:  <leader>nr run · <leader>nR run-all · <leader>nK kernel · <C-j/k> output"

local shared_buf

-- Build/refresh the dashboard buffer for `alias` rooted at `root`, centered to
-- `width` columns. Returns the buffer.
function M.build(alias, root, width)
  width = (width and width > 20) and width or 80
  local buf = (shared_buf and vim.api.nvim_buf_is_valid(shared_buf)) and shared_buf
    or vim.api.nvim_create_buf(false, true)  -- unlisted scratch
  shared_buf = buf

  local logo_w = 0
  for _, l in ipairs(M.logo) do logo_w = math.max(logo_w, vim.fn.strdisplaywidth(l)) end
  local function center(str, w)
    local pad = math.max(0, math.floor((width - (w or vim.fn.strdisplaywidth(str))) / 2))
    return string.rep(" ", pad) .. str
  end

  local lines, hl = {}, {}  -- hl: { row0, col0, col1, group }
  local function add(text, group, w)
    table.insert(lines, text)
    if group then table.insert(hl, { #lines - 1, 0, -1, group }) end
    return #lines
  end

  add("")
  add("")
  for _, l in ipairs(M.logo) do
    table.insert(lines, center(l, logo_w))
    table.insert(hl, { #lines - 1, 0, -1, "JupynvimDashLogo" })
  end
  add("")
  add(center(" " .. alias .. " · " .. (root or "")), "JupynvimDashInfo")
  add("")
  add("")

  -- action rows, centered as a block
  local rows = {}
  for _, a in ipairs(actions) do
    rows[#rows + 1] = string.format("%s  %-18s %s", a.icon, a.desc, a.key)
  end
  local block_w = 0
  for _, r in ipairs(rows) do block_w = math.max(block_w, vim.fn.strdisplaywidth(r)) end
  local left = math.max(0, math.floor((width - block_w) / 2))
  for i, a in ipairs(actions) do
    local text = string.rep(" ", left) .. rows[i]
    table.insert(lines, text)
    local row0 = #lines - 1
    -- highlight the trailing key char
    local keycol = #text - #a.key
    table.insert(hl, { row0, left, left + #a.icon, "JupynvimDashKey" })
    table.insert(hl, { row0, keycol, -1, "JupynvimDashKey" })
  end

  add("")
  add("")
  add(center(KEYHINT), "JupynvimDashFooter")
  add("")
  local ver = "jupynvim · connected to " .. alias
  add(center(ver), "JupynvimDashFooter")

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].buflisted = false
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].filetype = "jupynvim-dashboard"
  vim.b[buf].jupynvim_dashboard = true
  vim.b[buf].jupynvim_alias = alias
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, h in ipairs(hl) do
    pcall(vim.api.nvim_buf_add_highlight, buf, ns, h[4], h[1], h[2], h[3])
  end

  -- bind action keys
  for _, a in ipairs(actions) do
    vim.keymap.set("n", a.key, function() a.run(alias) end,
      { buffer = buf, nowait = true, silent = true })
  end
  -- cosmetic window opts when shown
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(w) == buf then
      vim.wo[w].number = false
      vim.wo[w].relativenumber = false
      vim.wo[w].signcolumn = "no"
      vim.wo[w].cursorline = false
      vim.wo[w].fillchars = "eob: "
    end
  end
  return buf
end

return M

-- VSCode-style rendering for markdown cells.
--
-- We don't actually rewrite the buffer; instead we use extmarks with
-- `conceal` and `virt_text` to make markdown source LOOK like rendered
-- markdown — headings get larger/bolder fg, list bullets get glyphs,
-- inline code/bold/italic get their markers concealed and styled.
--
-- Reference: https://neovim.io/doc/user/api.html#nvim_buf_set_extmark()

local M = {}

-- Highlight groups (defined in setup_hl)
local HL = {
  H1   = "JupynvimMdH1",
  H2   = "JupynvimMdH2",
  H3   = "JupynvimMdH3",
  H4   = "JupynvimMdH4",
  H5   = "JupynvimMdH5",
  H6   = "JupynvimMdH6",
  Bold = "JupynvimMdBold",
  Em   = "JupynvimMdEm",
  Code = "JupynvimMdCode",
  Link = "JupynvimMdLink",
  Quote = "JupynvimMdQuote",
  Bullet = "JupynvimMdBullet",
  HR    = "JupynvimMdHR",
  Math  = "JupynvimMdMath",
  MathBlock = "JupynvimMdMathBlock",
  Strike = "JupynvimMdStrike",
  Check = "JupynvimMdCheck",
  TableBorder = "JupynvimMdTableBorder",
  TableHead = "JupynvimMdTableHead",
}

function M.setup_hl()
  local hl = vim.api.nvim_set_hl
  -- VSCode-notebook style: bold colored heading text, NO background fill.
  hl(0, HL.H1,   { fg = "#7aa2f7", bold = true })
  hl(0, HL.H2,   { fg = "#bb9af7", bold = true })
  hl(0, HL.H3,   { fg = "#9ece6a", bold = true })
  hl(0, HL.H4,   { fg = "#e0af68", bold = true })
  hl(0, HL.H5,   { fg = "#7dcfff", bold = true })
  hl(0, HL.H6,   { fg = "#a9b1d6", bold = true })
  hl(0, HL.Bold, { bold = true, fg = "#c0caf5" })
  hl(0, HL.Em,   { italic = true, fg = "#c0caf5" })
  hl(0, HL.Code, { fg = "#9ece6a", bg = "#1f2335" })
  hl(0, HL.Link, { fg = "#7dcfff", underline = true })
  hl(0, HL.Quote, { fg = "#737aa2", italic = true })
  hl(0, HL.Bullet, { fg = "#7aa2f7", bold = true })
  hl(0, HL.HR,   { fg = "#414868" })
  hl(0, HL.Math, { fg = "#7dcfff", italic = true })
  hl(0, HL.MathBlock, { fg = "#7dcfff", bold = true, bg = "#1f2335" })
  hl(0, HL.Strike, { strikethrough = true, fg = "#565f89" })
  hl(0, HL.Check, { fg = "#9ece6a", bold = true })
  hl(0, HL.TableBorder, { fg = "#414868" })
  hl(0, HL.TableHead, { bold = true, fg = "#7aa2f7" })
end

-- Replace common LaTeX commands with Unicode equivalents for visual rendering.
-- Keeps the original buffer text unchanged — used only for virt_text overlays.
local LATEX_SYMBOLS = {
  ["\\int"] = "∫", ["\\sum"] = "∑", ["\\prod"] = "∏",
  ["\\infty"] = "∞", ["\\partial"] = "∂", ["\\nabla"] = "∇",
  ["\\alpha"] = "α", ["\\beta"] = "β", ["\\gamma"] = "γ",
  ["\\delta"] = "δ", ["\\epsilon"] = "ε", ["\\zeta"] = "ζ",
  ["\\eta"] = "η", ["\\theta"] = "θ", ["\\iota"] = "ι",
  ["\\kappa"] = "κ", ["\\lambda"] = "λ", ["\\mu"] = "μ",
  ["\\nu"] = "ν", ["\\xi"] = "ξ", ["\\pi"] = "π",
  ["\\rho"] = "ρ", ["\\sigma"] = "σ", ["\\tau"] = "τ",
  ["\\phi"] = "φ", ["\\chi"] = "χ", ["\\psi"] = "ψ", ["\\omega"] = "ω",
  ["\\Gamma"] = "Γ", ["\\Delta"] = "Δ", ["\\Theta"] = "Θ",
  ["\\Lambda"] = "Λ", ["\\Xi"] = "Ξ", ["\\Pi"] = "Π",
  ["\\Sigma"] = "Σ", ["\\Phi"] = "Φ", ["\\Psi"] = "Ψ", ["\\Omega"] = "Ω",
  ["\\leq"] = "≤", ["\\geq"] = "≥", ["\\neq"] = "≠",
  ["\\approx"] = "≈", ["\\equiv"] = "≡", ["\\sim"] = "∼",
  ["\\pm"] = "±", ["\\mp"] = "∓", ["\\times"] = "×", ["\\div"] = "÷",
  ["\\cdot"] = "·", ["\\circ"] = "∘", ["\\bullet"] = "•",
  ["\\rightarrow"] = "→", ["\\leftarrow"] = "←", ["\\Rightarrow"] = "⇒",
  ["\\Leftarrow"] = "⇐", ["\\Leftrightarrow"] = "⇔",
  ["\\sqrt"] = "√", ["\\forall"] = "∀", ["\\exists"] = "∃",
  ["\\in"] = "∈", ["\\notin"] = "∉", ["\\subset"] = "⊂", ["\\supset"] = "⊃",
  ["\\cup"] = "∪", ["\\cap"] = "∩", ["\\emptyset"] = "∅",
  ["\\,"] = " ", ["\\;"] = " ", ["\\:"] = " ", ["\\!"] = "",
}

local SUPER = {
  ["0"]="⁰", ["1"]="¹", ["2"]="²", ["3"]="³", ["4"]="⁴",
  ["5"]="⁵", ["6"]="⁶", ["7"]="⁷", ["8"]="⁸", ["9"]="⁹",
  ["+"]="⁺", ["-"]="⁻", ["="]="⁼", ["("]="⁽", [")"]="⁾",
  ["a"]="ᵃ", ["b"]="ᵇ", ["c"]="ᶜ", ["d"]="ᵈ", ["e"]="ᵉ",
  ["f"]="ᶠ", ["g"]="ᵍ", ["h"]="ʰ", ["i"]="ⁱ", ["j"]="ʲ",
  ["k"]="ᵏ", ["l"]="ˡ", ["m"]="ᵐ", ["n"]="ⁿ", ["o"]="ᵒ",
  ["p"]="ᵖ", ["r"]="ʳ", ["s"]="ˢ", ["t"]="ᵗ", ["u"]="ᵘ",
  ["v"]="ᵛ", ["w"]="ʷ", ["x"]="ˣ", ["y"]="ʸ", ["z"]="ᶻ",
}
local SUB = {
  ["0"]="₀", ["1"]="₁", ["2"]="₂", ["3"]="₃", ["4"]="₄",
  ["5"]="₅", ["6"]="₆", ["7"]="₇", ["8"]="₈", ["9"]="₉",
  ["+"]="₊", ["-"]="₋", ["="]="₌", ["("]="₍", [")"]="₎",
  ["a"]="ₐ", ["e"]="ₑ", ["h"]="ₕ", ["i"]="ᵢ", ["j"]="ⱼ",
  ["k"]="ₖ", ["l"]="ₗ", ["m"]="ₘ", ["n"]="ₙ", ["o"]="ₒ",
  ["p"]="ₚ", ["r"]="ᵣ", ["s"]="ₛ", ["t"]="ₜ", ["u"]="ᵤ",
  ["v"]="ᵥ", ["x"]="ₓ",
}

-- Sort LaTeX command keys by length descending so longer commands match before
-- shorter prefixes (e.g. \int before \in, \sigma before \sin).
local _LATEX_ORDERED = nil
local function ordered_latex()
  if _LATEX_ORDERED then return _LATEX_ORDERED end
  _LATEX_ORDERED = {}
  for k, v in pairs(LATEX_SYMBOLS) do
    table.insert(_LATEX_ORDERED, { k, v })
  end
  table.sort(_LATEX_ORDERED, function(a, b) return #a[1] > #b[1] end)
  return _LATEX_ORDERED
end

local function unicodify_math(s)
  local out = s
  -- LaTeX commands, longest first
  for _, kv in ipairs(ordered_latex()) do
    local cmd, sym = kv[1], kv[2]
    out = out:gsub(cmd:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"), sym)
  end
  -- ^N (single char)
  out = out:gsub("%^(%w)", function(c) return SUPER[c] or ("^" .. c) end)
  out = out:gsub("%^{([^}]+)}", function(s)
    local r = ""; for ch in s:gmatch(".") do r = r .. (SUPER[ch] or ch) end; return r
  end)
  -- _N
  out = out:gsub("_(%w)", function(c) return SUB[c] or ("_" .. c) end)
  out = out:gsub("_{([^}]+)}", function(s)
    local r = ""; for ch in s:gmatch(".") do r = r .. (SUB[ch] or ch) end; return r
  end)
  -- \frac{a}{b} → a/b
  out = out:gsub("\\frac%s*{([^}]+)}%s*{([^}]+)}", "%1⁄%2")
  return out
end
M._unicodify_math = unicodify_math

-- ---------- helpers (must be declared before any caller) ----------

local function set_mark(buf, ns, lnum, col, opts)
  pcall(vim.api.nvim_buf_set_extmark, buf, ns, lnum, col, opts)
end

local function conceal_range(buf, ns, lnum, start_col, end_col, char)
  set_mark(buf, ns, lnum, start_col, {
    end_col = end_col,
    conceal = char or "",
    hl_mode = "combine",
    priority = 200,
  })
end

-- Scan a line for [text](url) links with BALANCED brackets, so link text
-- like "[[link]]" (brackets inside the label) parses. Returns a list of
-- { start, text_close, stop, text, url } with 1-based byte positions of
-- the opening '[', the closing ']' and the closing ')'.
local function find_links(line)
  local links = {}
  local i = 1
  while i <= #line do
    if line:sub(i, i) == "[" then
      local depth, j = 1, i + 1
      while j <= #line and depth > 0 do
        local cj = line:sub(j, j)
        if cj == "[" then depth = depth + 1
        elseif cj == "]" then depth = depth - 1 end
        j = j + 1
      end
      if depth == 0 and line:sub(j, j) == "(" then
        local pdepth, k = 1, j + 1
        while k <= #line and pdepth > 0 do
          local ck = line:sub(k, k)
          if ck == "(" then pdepth = pdepth + 1
          elseif ck == ")" then pdepth = pdepth - 1 end
          k = k + 1
        end
        if pdepth == 0 then
          table.insert(links, {
            start = i, text_close = j - 1, stop = k - 1,
            text = line:sub(i + 1, j - 2),
            url = line:sub(j + 1, k - 2),
          })
          i = k
        else
          i = i + 1
        end
      else
        i = i + 1
      end
    else
      i = i + 1
    end
  end
  return links
end
M.find_links = find_links

-- The link under byte column `col` (1-based) in `line`, or the first link
-- on the line as a fallback. Used by the gx mapping.
function M.link_at(line, col)
  local links = find_links(line)
  for _, l in ipairs(links) do
    if col >= l.start and col <= l.stop then return l end
  end
  -- autolink <http://...>
  for a, url, b in line:gmatch("()<(%a[%w+.-]*://[^>%s]+)>()") do
    if col >= a and col < b then return { url = url } end
  end
  -- bare URL under cursor
  for a, url in line:gmatch("()(%a[%w+.-]*://[%w%-._~:/?#%[%]@!$&'()*+,;=%%]+)") do
    if col >= a and col < a + #url then return { url = url } end
  end
  return links[1]
end

local function inline_styling(buf, ns, lnum, line)
  -- Links FIRST (balanced-bracket scan), marking their spans so emphasis
  -- regexes don't fire inside URLs.
  for _, l in ipairs(find_links(line)) do
    local img = l.start > 1 and line:sub(l.start - 1, l.start - 1) == "!"
    -- conceal "[", show text as link, conceal "](url)"
    conceal_range(buf, ns, lnum, l.start - 1, l.start, "")
    set_mark(buf, ns, lnum, l.start, { end_col = l.text_close - 1, hl_group = HL.Link, hl_mode = "combine" })
    set_mark(buf, ns, lnum, l.text_close - 1, {
      end_col = l.stop,
      conceal = "",
      virt_text = { { img and " 🖼" or " ↗", HL.Link } },
      virt_text_pos = "inline",
      hl_mode = "combine",
      priority = 105,
    })
  end
  -- Autolinks <http://...>
  for a, url in line:gmatch("()<(%a[%w+.-]*://[^>%s]+)>") do
    conceal_range(buf, ns, lnum, a - 1, a, "")
    set_mark(buf, ns, lnum, a, { end_col = a + #url, hl_group = HL.Link, hl_mode = "combine" })
    conceal_range(buf, ns, lnum, a + #url, a + #url + 1, "")
  end
  -- Bold **text** and __text__
  for _, pat in ipairs({ "%*%*[^%*]+%*%*", "__[^_]+__" }) do
    local s = 1
    while true do
      local a, b = line:find(pat, s)
      if not a then break end
      conceal_range(buf, ns, lnum, a - 1, a + 1, "")
      set_mark(buf, ns, lnum, a + 1, { end_col = b - 2, hl_group = HL.Bold, hl_mode = "combine" })
      conceal_range(buf, ns, lnum, b - 2, b, "")
      s = b + 1
    end
  end
  -- Strikethrough ~~text~~
  local s = 1
  while true do
    local a, b = line:find("~~[^~]+~~", s)
    if not a then break end
    conceal_range(buf, ns, lnum, a - 1, a + 1, "")
    set_mark(buf, ns, lnum, a + 1, { end_col = b - 2, hl_group = HL.Strike, hl_mode = "combine" })
    conceal_range(buf, ns, lnum, b - 2, b, "")
    s = b + 1
  end
  -- Italic *text* (single asterisks; require non-* neighbours to avoid bold/list overlap)
  s = 1
  while true do
    local a, b = line:find("([^%*])%*([^%*\n][^%*\n]-)%*", s)
    if not a then break end
    local star1 = a + 1
    local inner_end = b
    conceal_range(buf, ns, lnum, star1 - 1, star1, "")
    set_mark(buf, ns, lnum, star1, { end_col = inner_end - 1, hl_group = HL.Em, hl_mode = "combine" })
    conceal_range(buf, ns, lnum, inner_end - 1, inner_end, "")
    s = b + 1
  end
  -- Italic _text_ (word-boundary guarded so snake_case identifiers survive)
  s = 1
  while true do
    local a, b = line:find("_[^_%s][^_]-_", s)
    if not a then break end
    local prev = a > 1 and line:sub(a - 1, a - 1) or " "
    local nxt = line:sub(b + 1, b + 1)
    if not prev:match("[%w_]") and not nxt:match("[%w_]") then
      conceal_range(buf, ns, lnum, a - 1, a, "")
      set_mark(buf, ns, lnum, a, { end_col = b - 1, hl_group = HL.Em, hl_mode = "combine" })
      conceal_range(buf, ns, lnum, b - 1, b, "")
    end
    s = b + 1
  end
  -- Inline code `text`
  s = 1
  while true do
    local a, b = line:find("`([^`]+)`", s)
    if not a then break end
    conceal_range(buf, ns, lnum, a - 1, a, "")
    set_mark(buf, ns, lnum, a, { end_col = b - 1, hl_group = HL.Code, hl_mode = "combine" })
    conceal_range(buf, ns, lnum, b - 1, b, "")
    s = b + 1
  end
  -- Inline math $...$ — replace with Unicode-rendered version
  s = 1
  while true do
    local a, b = line:find("%$[^%$\n]+%$", s)
    if not a then break end
    local prev = a > 1 and line:sub(a - 1, a - 1) or ""
    local next_ = line:sub(b + 1, b + 1)
    if prev ~= "$" and next_ ~= "$" then
      local raw_inner = line:sub(a + 1, b - 1)
      local pretty = unicodify_math(raw_inner)
      set_mark(buf, ns, lnum, a - 1, {
        end_col = b,
        conceal = "",
        virt_text = { { pretty, HL.Math } },
        virt_text_pos = "inline",
        hl_mode = "combine",
        priority = 105,
      })
    end
    s = b + 1
  end
end

local function apply_line(buf, ns, lnum, raw)
  if raw == "" then return end
  -- Block math single-line: $$...$$ on one line — replace with unicode-rendered
  if raw:match("^%s*%$%$") and raw:match("%$%$%s*$") and not raw:match("^%s*%$%$%s*$") then
    local inner = raw:gsub("^%s*%$%$", ""):gsub("%$%$%s*$", "")
    local pretty = "  " .. unicodify_math(inner)
    set_mark(buf, ns, lnum, 0, {
      end_col = #raw,
      conceal = "",
      virt_text = { { pretty, HL.MathBlock } },
      virt_text_pos = "overlay",
      line_hl_group = HL.MathBlock,
      priority = 110,
    })
    return
  end
  -- ATX headings — accept `#`, `##` etc with OR without trailing space
  -- (CommonMark requires space; Jupyter/VSCode are lenient).
  local hashes = raw:match("^(#+)")
  if hashes and #hashes <= 6 and (raw:sub(#hashes + 1, #hashes + 1) ~= "#") then
    local level = #hashes
    local hl = HL["H" .. level]
    local prefix = ({ "█ ", "▌ ", "▎ ", "▏ ", "· ", "· " })[level] or "  "
    -- Conceal hashes; if a space follows, conceal it too.
    local conceal_end = #hashes
    if raw:sub(#hashes + 1, #hashes + 1) == " " then conceal_end = conceal_end + 1 end
    set_mark(buf, ns, lnum, 0, {
      end_col = conceal_end,
      conceal = "",
      virt_text = { { prefix, hl } },
      virt_text_pos = "inline",
      hl_mode = "combine",
      priority = 105,
    })
    set_mark(buf, ns, lnum, 0, { line_hl_group = hl, priority = 100 })
    -- breathing room above headings, like VSCode's vertical rhythm
    set_mark(buf, ns, lnum, 0, {
      virt_lines = { { { " ", "Normal" } } },
      virt_lines_above = true,
    })
    inline_styling(buf, ns, lnum, raw)
    return
  end
  -- HR — fully conceal the line (no decoration). Render-markdown convention.
  if raw:match("^%s*[-_*]%s*[-_*]%s*[-_*][-_*%s]*$") then
    set_mark(buf, ns, lnum, 0, {
      end_col = #raw,
      conceal = "",
      hl_mode = "combine",
      priority = 200,
    })
    return
  end
  -- Quote: ^> text
  if raw:match("^>%s*") then
    set_mark(buf, ns, lnum, 0, { line_hl_group = HL.Quote, priority = 90 })
    inline_styling(buf, ns, lnum, raw)
    return
  end
  -- Bullet list (with GitHub task-list checkboxes). Overlay WITHOUT
  -- conceal: concealing the marker shifted the text left one cell and
  -- glued the bullet to the word.
  local indent, marker = raw:match("^(%s*)([%-%*%+])%s+")
  if marker then
    set_mark(buf, ns, lnum, #indent, {
      end_col = #indent + 1,
      virt_text = { { "•", HL.Bullet } },
      virt_text_pos = "overlay",
      hl_mode = "combine",
    })
    local box_s, box_e, state = raw:find("^%s*[%-%*%+]%s+%[([ xX])%]")
    if box_s then
      local glyph = (state == " ") and "☐" or "☑"
      set_mark(buf, ns, lnum, box_e - 3, {
        end_col = box_e,
        conceal = "",
        virt_text = { { glyph, HL.Check } },
        virt_text_pos = "inline",
        hl_mode = "combine",
        priority = 105,
      })
      if state ~= " " then
        set_mark(buf, ns, lnum, box_e, { end_col = #raw, hl_group = HL.Strike, hl_mode = "combine", priority = 90 })
      end
    end
    inline_styling(buf, ns, lnum, raw)
    return
  end
  -- Numbered list
  local num_pre = raw:match("^(%s*%d+%.)%s+")
  if num_pre then
    set_mark(buf, ns, lnum, 0, { hl_group = HL.Bullet, end_col = #num_pre, hl_mode = "combine", priority = 100 })
    inline_styling(buf, ns, lnum, raw)
    return
  end
  -- Embedded image placeholder: ![alt](jupynvim-img:N) — fully conceal so
  -- the cell shows just the rendered image below, like VSCode does.
  if raw:match("!%[[^%]]*%]%(jupynvim%-img:%d+%)") then
    set_mark(buf, ns, lnum, 0, {
      end_col = #raw,
      conceal = "",
      priority = 200,
    })
    return
  end

  -- Plain
  inline_styling(buf, ns, lnum, raw)
end

-- ---------- tables ----------

local function dw(s) return vim.fn.strdisplaywidth(s) end

-- A pipe-table separator row: only |, -, :, spaces, with at least one dash.
local function is_table_sep(line)
  if not (line:find("|") and line:find("%-")) then return false end
  return line:match("^[|: %-%s]+$") ~= nil
end

local function split_row(raw)
  local inner = raw:gsub("^%s*|", ""):gsub("|%s*$", "")
  local cells = {}
  for cell in (inner .. "|"):gmatch("([^|]*)|") do
    table.insert(cells, vim.trim(cell))
  end
  return cells
end

-- Word-wrap one cell's text to `width` display columns (hard-breaking
-- words longer than the column, multi-byte safe).
local function wrap_cell(text, width)
  if dw(text) <= width then return { text } end
  local out, cur = {}, ""
  for word in text:gmatch("%S+") do
    while dw(word) > width do
      if cur ~= "" then table.insert(out, cur); cur = "" end
      local taken, rest, w = "", "", 0
      for ch in word:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        local cw = dw(ch)
        if rest ~= "" or w + cw > width then
          rest = rest .. ch
        else
          taken = taken .. ch
          w = w + cw
        end
      end
      if taken == "" then break end
      table.insert(out, taken)
      word = rest
    end
    if word ~= "" then
      local cand = cur == "" and word or (cur .. " " .. word)
      if dw(cand) > width and cur ~= "" then
        table.insert(out, cur)
        cur = word
      else
        cur = cand
      end
    end
  end
  if cur ~= "" then table.insert(out, cur) end
  if #out == 0 then out = { "" } end
  return out
end

-- Pure layout (testable): logical rows -> boxed physical lines that fit
-- max_w display columns. Wide columns shrink and their text wraps INSIDE
-- the cell (VSCode behavior for dataframe-style tables), so the box never
-- overflows the window. rows[1] is the header.
function M._layout_table(rows, max_w)
  local ncols = 0
  for _, cells in ipairs(rows) do ncols = math.max(ncols, #cells) end
  if ncols == 0 then return nil end
  local wid = {}
  for c = 1, ncols do
    local w = 3
    for _, cells in ipairs(rows) do w = math.max(w, dw(cells[c] or "")) end
    wid[c] = w
  end
  local MIN = 8
  local function total()
    local t = ncols + 1
    for c = 1, ncols do t = t + wid[c] + 2 end
    return t
  end
  for _ = 1, 256 do
    if total() <= max_w then break end
    local bi, bw = nil, MIN
    for c = 1, ncols do
      if wid[c] > bw then bi, bw = c, wid[c] end
    end
    if not bi then break end  -- every column already at MIN: give up
    wid[bi] = math.max(MIN, wid[bi] - math.max(1, total() - max_w))
  end
  local function border(l, m, r)
    local parts = {}
    for c = 1, ncols do parts[c] = string.rep("─", wid[c] + 2) end
    return l .. table.concat(parts, m) .. r
  end
  local function fmt_row(cells)
    local wrapped, height = {}, 1
    for c = 1, ncols do
      wrapped[c] = wrap_cell(cells[c] or "", wid[c])
      height = math.max(height, #wrapped[c])
    end
    local phys = {}
    for i = 1, height do
      local parts = {}
      for c = 1, ncols do
        local t = wrapped[c][i] or ""
        parts[c] = " " .. t .. string.rep(" ", math.max(wid[c] - dw(t), 0)) .. " "
      end
      phys[i] = "│" .. table.concat(parts, "│") .. "│"
    end
    return phys
  end
  local body = {}
  for ri = 2, #rows do body[ri - 1] = fmt_row(rows[ri]) end
  return {
    header = fmt_row(rows[1]),
    top = border("┌", "┬", "┐"),
    mid = border("├", "┼", "┤"),
    bot = border("└", "┴", "┘"),
    body = body,
  }
end

-- Render a pipe table as a proper box: raw rows are fully concealed and a
-- laid-out version is drawn in their place. Robust to ragged sources and
-- rows wider than the window (the old renderer assumed monospace-aligned
-- pipes and overflowed past the border).
--
-- Two placements, because conceal hides TEXT but does not collapse a long
-- line's WRAP ROWS (they stay as blank screen rows):
--   • every raw row fits the width  -> overlay each row 1:1 (no gaps)
--   • some raw row would wrap       -> the whole boxed table renders as
--     one contiguous virt-line block above the concealed source rows;
--     the leftover blank rows fall BELOW the box as plain spacing
local function render_table(buf, ns, base, lines, first, last, max_w)
  max_w = math.max(max_w or 80, 24)
  local rows = { split_row(lines[first]) }
  for i = first + 2, last do
    table.insert(rows, split_row(lines[i]))
  end
  local layout = M._layout_table(rows, max_w)
  if not layout then return end

  local function conceal_row(lnum)
    local raw = lines[lnum - base + 1] or ""
    set_mark(buf, ns, lnum, 0, { end_col = #raw, conceal = "", priority = 150 })
  end

  local fits = true
  for i = first, last do
    if dw(lines[i]) > max_w then fits = false; break end
  end

  if not fits then
    local vls = { { { layout.top, HL.TableBorder } } }
    for _, h in ipairs(layout.header) do table.insert(vls, { { h, HL.TableHead } }) end
    table.insert(vls, { { layout.mid, HL.TableBorder } })
    for _, phys in ipairs(layout.body) do
      for _, p in ipairs(phys) do table.insert(vls, { { p, "Normal" } }) end
    end
    table.insert(vls, { { layout.bot, HL.TableBorder } })
    set_mark(buf, ns, base + first - 1, 0, {
      virt_lines = vls,
      virt_lines_above = true,
    })
    for i = first, last do conceal_row(base + i - 1) end
    return
  end

  local function put(lnum, phys, hl, extra_below)
    conceal_row(lnum)
    set_mark(buf, ns, lnum, 0, {
      virt_text = { { phys[1], hl } },
      virt_text_pos = "overlay",
      hl_mode = "combine",
      priority = 160,
    })
    local below = {}
    for i = 2, #phys do table.insert(below, { { phys[i], hl } }) end
    for _, b in ipairs(extra_below or {}) do table.insert(below, b) end
    if #below > 0 then
      set_mark(buf, ns, lnum, 0, { virt_lines = below })
    end
  end

  set_mark(buf, ns, base + first - 1, 0, {
    virt_lines = { { { layout.top, HL.TableBorder } } },
    virt_lines_above = true,
  })
  local bot_row = { { { layout.bot, HL.TableBorder } } }
  put(base + first - 1, layout.header, HL.TableHead)
  put(base + first, { layout.mid }, HL.TableBorder,
    #layout.body == 0 and bot_row or nil)
  for bi, phys in ipairs(layout.body) do
    put(base + first + 1 + bi - 1, phys, "Normal",
      bi == #layout.body and bot_row or nil)
  end
end

-- ---------- public API ----------

-- Apply markdown extmarks to lines [start_line, end_line] (0-based, inclusive)
-- in `buf`, in namespace `ns`. Multi-line constructs (fenced code blocks,
-- block math) are tracked via a small state machine.
function M.render(buf, ns, start_line, end_line, render_width)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local total = vim.api.nvim_buf_line_count(buf)
  if start_line >= total then return end
  end_line = math.min(end_line, total - 1)
  local lines = vim.api.nvim_buf_get_lines(buf, start_line, end_line + 1, false)
  local heading_width = render_width or 60

  -- Pre-pass: pipe tables (outside fences). Rows claimed by a table are
  -- rendered here and skipped by the per-line pass below.
  local claimed = {}
  do
    local fence = false
    local i = 1
    while i <= #lines do
      local raw = lines[i]
      if raw:match("^%s*```") then fence = not fence end
      if not fence and raw:find("|") and not is_table_sep(raw)
         and lines[i + 1] and is_table_sep(lines[i + 1]) then
        local first, last = i, i + 1
        local j = i + 2
        while j <= #lines and lines[j]:find("|") and not lines[j]:match("^%s*```") do
          last = j
          j = j + 1
        end
        render_table(buf, ns, start_line, lines, first, last, render_width)
        for r = first, last do claimed[r] = true end
        i = last + 1
      else
        i = i + 1
      end
    end
  end

  local in_fence = false
  local in_math_block = false

  for i, raw in ipairs(lines) do
    local lnum = start_line + i - 1
    if claimed[i] then
      -- table row: already rendered by the pre-pass
      goto continue
    end
    -- Fenced code blocks ```...```
    if raw:match("^%s*```") then
      in_fence = not in_fence
      set_mark(buf, ns, lnum, 0, {
        line_hl_group = HL.Code,
        virt_text = { { string.rep("─", 60), HL.Code } },
        virt_text_pos = "overlay",
        conceal = "",
        hl_mode = "combine",
        priority = 110,
      })
    elseif in_fence then
      set_mark(buf, ns, lnum, 0, { line_hl_group = HL.Code, priority = 100 })
    -- Block math $$...$$ over multiple lines
    elseif (not in_math_block) and raw:match("^%s*%$%$%s*$") then
      in_math_block = true
      set_mark(buf, ns, lnum, 0, {
        line_hl_group = HL.MathBlock,
        priority = 110,
      })
    elseif in_math_block and raw:match("^%s*%$%$%s*$") then
      in_math_block = false
      set_mark(buf, ns, lnum, 0, { line_hl_group = HL.MathBlock, priority = 110 })
    elseif in_math_block then
      set_mark(buf, ns, lnum, 0, { line_hl_group = HL.MathBlock, priority = 100 })
    else
      -- Setext headings: text line followed by `===` (h1) or `---` (h2).
      -- Style the text line as a heading; fully conceal the underline below.
      local next_line = lines[i + 1]
      local is_setext_h1 = next_line and next_line:match("^=+%s*$")
      local is_setext_h2 = next_line and next_line:match("^%-+%s*$")
      if (is_setext_h1 or is_setext_h2) and raw ~= "" and not raw:match("^#+%s") then
        local level = is_setext_h1 and 1 or 2
        local hl = HL["H" .. level]
        set_mark(buf, ns, lnum, 0, { line_hl_group = hl, priority = 100 })
        inline_styling(buf, ns, lnum, raw)
        -- Conceal the entire underline-marker line — no decoration overlay.
        set_mark(buf, ns, lnum + 1, 0, {
          end_col = #(next_line or ""),
          conceal = "",
          hl_mode = "combine",
          priority = 200,
        })
      else
        apply_line(buf, ns, lnum, raw)
        -- ATX heading: NO underline virt_line. The styled heading text speaks for itself.
      end
    end
    ::continue::
  end
end

return M

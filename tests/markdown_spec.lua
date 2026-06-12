-- Headless verification of the markdown engine.
local here = debug.getinfo(1, "S").source:sub(2)
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(here, ":p:h:h"))
local MD = require("jupynvim.markdown")
MD.setup_hl()

-- 1. balanced-bracket links: the exact failing case from the HW notebook
local line = 'written"[[link]](https://www.google.com/url?sa=t&opi=899,what%2520are(x))". In this'
local links = MD.find_links(line)
assert(#links == 1, "expected 1 link, got " .. #links)
assert(links[1].text == "[link]", "link text wrong: " .. links[1].text)
assert(links[1].url:find("google.com", 1, true), "url wrong: " .. links[1].url)
assert(links[1].url:sub(-3) == "(x)", "balanced parens in url broken: " .. links[1].url)
print("1. [[link]](url) parses, balanced parens ok")

-- 2. link_at by cursor position + autolink + bare url
local l = MD.link_at(line, links[1].start + 2)
assert(l and l.url:find("google"), "link_at inside link failed")
assert(MD.link_at("see <https://nvim.io> now", 8).url == "https://nvim.io", "autolink link_at failed")
assert(MD.link_at("at https://x.dev/page ok", 5).url:find("x.dev"), "bare url link_at failed")
print("2. link_at: link/autolink/bare-url ok")

-- 3. rendered extmarks in a buffer
local buf = vim.api.nvim_create_buf(true, false)
local ns = vim.api.nvim_create_namespace("t")
local content = {
  "# Head",
  'phonetic transcription, "the conversion"[[link]](https://krisp.ai/blog/x). Both letters',
  "| Frame | Feature 1 | Phoneme |",
  "|-------|-----------|---------|",
  "| 0     | v0_1      | /d/     |",
  "| 1     | v1_1      | /i/     |",
  "plain __getitem__ and ~~gone~~ and _soft_ but snake_case_name stays",
  "- [x] done thing",
  "- [ ] todo thing",
  "see <https://neovim.io> too",
}
vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
MD.render(buf, ns, 0, #content - 1, 80)
local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })

local function marks_on(row)
  local out = {}
  for _, m in ipairs(marks) do if m[2] == row then table.insert(out, m[4]) end end
  return out
end
local function any(row, pred)
  for _, d in ipairs(marks_on(row)) do if pred(d) then return true end end
  return false
end

-- link row: text styled as link, ](url) concealed, arrow virt
assert(any(1, function(d) return d.hl_group == "JupynvimMdLink" end), "link hl missing")
assert(any(1, function(d)
  return d.virt_text and d.virt_text[1] and d.virt_text[1][1]:find("↗")
end), "link arrow missing")
print("3a. link rendering ok")

-- table: top border above header, sep overlay, pipes -> │, header bold group
assert(any(2, function(d)
  return d.virt_lines and d.virt_lines[1][1][1]:find("┌") and d.virt_lines[1][1][1]:find("┬")
end), "table top border missing")
assert(any(3, function(d)
  return d.virt_text and d.virt_text[1][1]:find("├") and d.virt_text[1][1]:find("┼")
end), "table separator overlay missing")
assert(any(4, function(d) return d.conceal == "│" end), "pipes not turned into │")
assert(any(2, function(d) return d.hl_group == "JupynvimMdTableHead" end), "table header style missing")
assert(any(5, function(d)
  return d.virt_lines and d.virt_lines[1][1][1]:find("└")
end), "table bottom border missing")
print("3b. table rendering ok")

-- emphasis: __bold__, ~~strike~~, _em_, snake_case untouched
assert(any(6, function(d) return d.hl_group == "JupynvimMdBold" end), "__bold__ missing")
assert(any(6, function(d) return d.hl_group == "JupynvimMdStrike" end), "~~strike~~ missing")
assert(any(6, function(d) return d.hl_group == "JupynvimMdEm" end), "_em_ missing")
for _, m in ipairs(marks) do
  if m[2] == 6 and m[4].hl_group == "JupynvimMdEm" then
    local span = content[7]:sub(m[3] + 1, m[4].end_col)
    assert(span == "soft", "emphasis leaked: styled span [" .. span .. "]")
  end
end
print("3c. emphasis ok")

-- task lists
assert(any(7, function(d)
  return d.virt_text and d.virt_text[1][1] == "☑"
end), "checked box missing")
assert(any(8, function(d)
  return d.virt_text and d.virt_text[1][1] == "☐"
end), "unchecked box missing")
print("3d. task lists ok")

-- autolink styled
assert(any(9, function(d) return d.hl_group == "JupynvimMdLink" end), "autolink hl missing")
print("3e. autolink ok")

print("ALL MARKDOWN CHECKS PASSED")
vim.cmd("qa!")

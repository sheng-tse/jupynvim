-- Image base64 as real notebooks store it, and what rendering it may cost.
--
-- Older Jupyter stacks and Colab write image/png with a trailing newline,
-- base64.encodebytes wraps it every 76 characters, and nbformat allows a list
-- of strings. Both decoders reject whitespace, so none of these rendered or
-- saved. The cleaning has to happen once, where outputs enter the model:
-- render runs per keystroke, and a pattern scan of every image on every call
-- is the kind of cost v0.4.5 just took out of the render path.
--
-- Two older bugs sit on the same path and are covered here too. A jpeg or gif
-- is stored as its converted png, so the cache never matched and ImageMagick
-- ran again on every render. Without ImageMagick the chafa fallback stored a
-- renderer that never matched the one asked for, and every render scheduled
-- another one, forever.

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local fails = 0
local function chk(name, cond, detail)
  if cond then io.write("  ok " .. name .. "\n")
  else io.write("FAIL " .. name .. (detail and ("  -- " .. detail) or "") .. "\n"); fails = fails + 1 end
end

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
-- A Kitty terminal whose "tty" is a plain file: the backend writes the
-- graphics escapes there, so transmits succeed or fail exactly as they would
-- on screen, headless.
vim.env.TERM = "xterm-kitty"
vim.env.JUPYNVIM_TTY = tmp .. "/tty"
io.open(vim.env.JUPYNVIM_TTY, "w"):close()

local J      = require("jupynvim")
local NB     = require("jupynvim.notebook")
local Image  = require("jupynvim.notebook.image")
local Render = require("jupynvim.notebook.render")
J.setup({ log_level = "warn", image_renderer = "placeholder" })

local notes = {}
vim.notify = function(m) notes[#notes + 1] = tostring(m) end

package.path = "./tests/?.lua;" .. package.path
local PNG = vim.base64.encode(require("png_fixture")(160, 120, 1))

local function w76(s)
  local t = {}
  for i = 1, #s, 76 do t[#t + 1] = s:sub(i, i + 75) end
  return table.concat(t, "\n") .. "\n"
end
local function l76(s)
  local t = {}
  for i = 1, #s, 76 do t[#t + 1] = s:sub(i, i + 75) .. "\n" end
  return t
end

local function write_nb(cells)
  local p = tmp .. "/" .. vim.fn.fnamemodify(vim.fn.tempname(), ":t") .. ".ipynb"
  local f = io.open(p, "w")
  f:write(vim.json.encode({
    cells = cells, nbformat = 4, nbformat_minor = 5,
    metadata = { kernelspec = { name = "python3", display_name = "P", language = "python" } },
  }))
  f:close()
  return p
end

local function image_cell(id, mime, v)
  return {
    cell_type = "code", id = id, metadata = vim.empty_dict(), source = "plot()",
    execution_count = 1,
    outputs = { { output_type = "display_data", metadata = vim.empty_dict(),
                  data = { [mime] = v, ["text/plain"] = "<Figure>" } } },
  }
end

local function open(path)
  local buf = J.open(path)
  vim.wait(3000, function() return NB.get(buf) ~= nil end, 20)
  return buf
end

local C1 = Image.output_key("c1", 1)   -- the first output of cell c1

local function placement(key, ms)
  vim.wait(ms or 3000, function() return Image._placements[key] ~= nil end, 20)
  return Image._placements[key]
end

local function save_bytes(buf)
  vim.api.nvim_set_current_buf(buf)
  local nb = NB.get(buf)
  for l = 1, vim.api.nvim_buf_line_count(buf) do
    if nb:cell_at_line(l) then vim.api.nvim_win_set_cursor(0, { l, 0 }); break end
  end
  local out = tmp .. "/saved_" .. buf .. ".bin"
  os.remove(out)
  J.save_image(buf, out)
  local f = io.open(out, "rb")
  local got = f and f:read("*a")
  if f then f:close() end
  return got
end

local function close(buf)
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  for k in pairs(Image._placements) do Image._placements[k] = nil end
end

-- ── whitespace in code-cell image data ──────────────────────────────────
local RAW = vim.base64.decode(PNG)
for _, v in ipairs({
  { "trailing newline", PNG .. "\n" },
  { "crlf", PNG .. "\r\n" },
  { "wrapped at 76 as one string", w76(PNG) },
  { "wrapped at 76 as a list", l76(PNG) },
}) do
  local label, value = v[1], v[2]
  local buf = open(write_nb({ image_cell("c1", "image/png", value) }))
  local p = placement(C1)
  chk(label .. ": the image is transmitted", p and p.renderer == "placeholder",
      p and ("renderer " .. tostring(p.renderer)) or "no placement")
  local stored = NB.get(buf).cells[1].outputs[1].data["image/png"]
  chk(label .. ": the model holds it once, cleaned", stored == PNG,
      type(stored) .. " of length " .. (type(stored) == "string" and #stored or #stored))
  chk(label .. ": :JupynvimSaveImage writes the original bytes", save_bytes(buf) == RAW)
  close(buf)
end

do
  local buf = open(write_nb({ image_cell("c1", "image/png", "\n") }))
  vim.wait(500)
  chk("whitespace-only data renders nothing", Image._placements[C1] == nil)
  notes = {}
  chk("whitespace-only data saves nothing", save_bytes(buf) == nil)
  chk("whitespace-only data says there is no image",
      table.concat(notes, " "):find("no image", 1, true) ~= nil, table.concat(notes, " | "))
  close(buf)
end

do
  local buf = open(write_nb({ {
    cell_type = "markdown", id = "m1", metadata = vim.empty_dict(),
    source = "# pic\n\n![p](data:image/png;base64," .. w76(PNG) .. ")\n",
  } }))
  chk("a wrapped markdown data URI renders", placement("m1_md_1") ~= nil)
  close(buf)
end

-- ── saving: which bytes land in the file ─────────────────────────────────
do
  local SVG = '<svg xmlns="http://www.w3.org/2000/svg" width="4" height="4"><rect width="4" height="4"/></svg>'
  local function svg_cell(v)
    return { cell_type = "code", id = "c1", metadata = vim.empty_dict(), source = "svg()",
             execution_count = 1, outputs = { { output_type = "display_data",
             metadata = vim.empty_dict(), data = { ["image/svg+xml"] = v } } } }
  end
  -- nbformat stores an output's svg as the XML itself, as one string or as lines
  local buf = open(write_nb({ svg_cell(SVG) }))
  chk("a code cell's svg saves as the XML it is", save_bytes(buf) == SVG)
  close(buf)
  buf = open(write_nb({ svg_cell({ SVG:sub(1, 40), SVG:sub(41) }) }))
  chk("and so does one stored as a list of lines", save_bytes(buf) == SVG)
  close(buf)
  -- an output carrying both: the raster, every time, not whichever pairs() gave
  local both = image_cell("c1", "image/png", PNG)
  both.outputs[1].data["image/svg+xml"] = SVG
  buf = open(write_nb({ both }))
  -- pairs() order differs between runs, so make it hand over the svg first:
  -- a picker that walks pairs() then fails every time, not half the time
  local real_pairs = pairs
  pairs = function(t)
    if type(t) == "table" and t["image/png"] and t["image/svg+xml"] then
      local keys = {}
      for k in next, t do keys[#keys + 1] = k end
      table.sort(keys, function(x, y) return x > y end)
      local i = 0
      return function() i = i + 1; if keys[i] then return keys[i], t[keys[i]] end end
    end
    return real_pairs(t)
  end
  local saved = save_bytes(buf)
  pairs = real_pairs
  chk("an output with png and svg saves the png", saved == RAW)
  close(buf)
  -- a markdown data URI is base64 whatever its mime, svg included
  buf = open(write_nb({ {
    cell_type = "markdown", id = "m1", metadata = vim.empty_dict(),
    source = "![s](data:image/svg+xml;base64," .. vim.base64.encode(SVG) .. ")\n",
  } }))
  chk("a markdown base64 svg saves decoded", save_bytes(buf) == SVG)
  close(buf)
end

-- ── a cache hit must not rescan the image ──────────────────────────────
do
  local buf = open(write_nb({ image_cell("c1", "image/png", l76(PNG)) }))
  placement(C1)
  local stored = NB.get(buf).cells[1].outputs[1].data["image/png"]
  if type(stored) == "table" then stored = table.concat(stored, "") end
  local noop = function() end
  local t0 = vim.uv.hrtime()
  for _ = 1, 500 do
    Image.ensure_transmitted(C1, stored, noop, { renderer = "placeholder", mime = "image/png" })
  end
  local ms = (vim.uv.hrtime() - t0) / 1e6
  chk("500 cache hits on a 77KB image stay cheap (render path, every keystroke)", ms < 30,
      ("%.1f ms"):format(ms))
  close(buf)
end

-- ── non-png: convert once, not on every render ─────────────────────────
-- png bytes labelled jpeg take the same conversion path as a real jpeg.
local magick = vim.fn.executable("magick") == 1 or vim.fn.executable("convert") == 1
local real_system = vim.fn.system
local conversions = 0
vim.fn.system = function(cmd, ...)
  if type(cmd) == "string" and cmd:find("magick", 1, true) then conversions = conversions + 1 end
  return real_system(cmd, ...)
end

if magick then
  local buf = open(write_nb({ image_cell("c1", "image/jpeg", PNG) }))
  placement(C1, 8000)
  vim.wait(300)
  conversions = 0
  local win = vim.fn.bufwinid(buf)
  for _ = 1, 5 do Render.refresh_sync(NB.get(buf), win) end
  chk("a jpeg is not converted again on re-render", conversions == 0,
      conversions .. " ImageMagick runs over 5 renders")
  close(buf)
else
  io.write("  skip jpeg re-conversion: no ImageMagick\n")
end

-- ── no ImageMagick: the chafa fallback must settle ─────────────────────
if vim.fn.executable("chafa") == 1 then
  local real_exec = vim.fn.executable
  vim.fn.executable = function(name)
    if name == "magick" or name == "convert" then return 0 end
    return real_exec(name)
  end
  local buf = open(write_nb({ image_cell("c1", "image/jpeg", PNG) }))
  local p = placement(C1, 8000)
  chk("without ImageMagick a jpeg falls back to chafa", p and p.renderer == "chafa")
  local n0 = Render._render_n or 0
  vim.wait(1500)
  local renders = (Render._render_n or 0) - n0
  chk("the chafa fallback does not re-render forever", renders < 10,
      renders .. " renders in 1.5s of idle")
  close(buf)
  vim.fn.executable = real_exec
else
  io.write("  skip chafa fallback: no chafa\n")
end

vim.fn.system = real_system
vim.fn.delete(tmp, "rf")

if fails == 0 then
  io.write("\nALL IMAGE-B64 CHECKS PASSED\n")
  vim.cmd("qa!")
else
  io.write(("\nIMAGE-B64: %d CHECK(S) FAILED\n"):format(fails))
  vim.cmd("cquit 1")
end

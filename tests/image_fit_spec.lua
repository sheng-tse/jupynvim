-- image_fit: "box" keeps the fixed image_rows x image_cols box; "auto" fits each
-- image in it by aspect ratio and takes only the cells it covers.

package.path = "./lua/?.lua;./lua/?/init.lua;./tests/?.lua;" .. package.path

local fails = 0
local function chk(name, got, want)
  if got == want then io.write("  ok " .. name .. "\n")
  else io.write(("FAIL %s  -- got %s, want %s\n"):format(name, tostring(got), tostring(want))); fails = fails + 1 end
end

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
vim.env.TERM = "xterm-kitty"
vim.env.JUPYNVIM_TTY = tmp .. "/tty"
io.open(vim.env.JUPYNVIM_TTY, "w"):close()

local J, NB, Image = require("jupynvim"), require("jupynvim.notebook"), require("jupynvim.notebook.image")
J.setup({ log_level = "warn", image_renderer = "placeholder", image_cols = 40, image_rows = 30, image_fit = "auto" })
vim.notify = function() end
Image._cell_ratio = function() return 0.5 end -- pinned: a real terminal's ratio varies

local function png(w, h) return vim.base64.encode(require("png_fixture")(w, h, 1)) end
local function size(b64) return ("%dx%d"):format(Image._size_for(b64)) end

chk("auto: width is the limit", size(png(400, 100)), "40x5")
chk("auto: height is the limit", size(png(100, 400)), "15x30")
chk("auto: not a PNG gets the box", size(vim.base64.encode("not a png")), "40x30")
Image.set_size({ fit = "box" })
chk("box: unchanged", size(png(400, 100)), "40x30")
Image.set_size({ fit = "auto" })

-- end to end: a notebook's image is placed at that size
local path = tmp .. "/nb.ipynb"
local f = io.open(path, "w")
f:write(vim.json.encode({
  nbformat = 4, nbformat_minor = 5,
  metadata = { kernelspec = { name = "python3", display_name = "P", language = "python" } },
  cells = { { cell_type = "code", id = "c1", metadata = vim.empty_dict(), source = "plot()", execution_count = 1,
              outputs = { { output_type = "display_data", metadata = vim.empty_dict(),
                            data = { ["image/png"] = png(400, 100), ["text/plain"] = "<Figure>" } } } } },
}))
f:close()
local buf = J.open(path)
local key = Image.output_key(Image.output_owner(buf, "c1"), 1)
vim.wait(5000, function() return Image._placements[key] ~= nil end, 20)
local p = Image._placements[key]
chk("notebook image placed", p and ("%dx%d"):format(p.cols, p.rows), "40x5")
chk("placeholder lines", #(Image.placeholder_virt_lines(key) or {}), 5)

vim.fn.delete(tmp, "rf")
if fails == 0 then
  io.write("\nALL IMAGE-FIT CHECKS PASSED\n")
  vim.cmd("qa!")
else
  io.write(("\nIMAGE-FIT: %d CHECK(S) FAILED\n"):format(fails))
  vim.cmd("cquit 1")
end

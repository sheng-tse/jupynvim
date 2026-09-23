-- Several images in one cell (#34), and the output messages that decide
-- which images a cell holds.
--
-- Every code cell had exactly one image slot, keyed by the cell id. The
-- render took the first image output and stopped, and the live path wrote
-- each new image into that same slot, so a cell with two plt.show() calls
-- showed one plot, and which one came down to timing.
--
-- Each image output now has its own key. That makes two Jupyter messages
-- matter that the single slot hid: clear_output(wait=True), which has to
-- replace a live-updating frame instead of stacking one per iteration, and
-- update_display_data, which has to change the output it names.

package.path = "./lua/?.lua;./lua/?/init.lua;./tests/?.lua;" .. package.path

local fails = 0
local function chk(name, cond, detail)
  if cond then io.write("  ok " .. name .. "\n")
  else io.write("FAIL " .. name .. (detail and ("  -- " .. detail) or "") .. "\n"); fails = fails + 1 end
end

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
vim.env.TERM = "xterm-kitty"
vim.env.JUPYNVIM_TTY = tmp .. "/tty"
io.open(vim.env.JUPYNVIM_TTY, "w"):close()

local J      = require("jupynvim")
local NB     = require("jupynvim.notebook")
local Image  = require("jupynvim.notebook.image")
local Render = require("jupynvim.notebook.render")
J.setup({ log_level = "warn", image_renderer = "placeholder" })
vim.notify = function() end

local png = require("png_fixture")
local A = vim.base64.encode(png(120, 90, 1))
local B = vim.base64.encode(png(120, 90, 2))
local C = vim.base64.encode(png(120, 90, 3))
local ROWS = J.config.image_rows or 16

local function display(b64, display_id)
  return { output_type = "display_data", metadata = vim.empty_dict(),
           data = { ["image/png"] = b64, ["text/plain"] = "<Figure>" },
           transient = display_id and { display_id = display_id } or nil }
end

local function open(outputs)
  local p = tmp .. "/" .. vim.fn.fnamemodify(vim.fn.tempname(), ":t") .. ".ipynb"
  local f = io.open(p, "w")
  f:write(vim.json.encode({
    cells = { { cell_type = "code", id = "c1", metadata = vim.empty_dict(), source = "plot()",
                execution_count = 1, outputs = outputs } },
    metadata = { kernelspec = { name = "python3", display_name = "P", language = "python" } },
    nbformat = 4, nbformat_minor = 5,
  }))
  f:close()
  local buf = J.open(p)
  vim.wait(3000, function() return NB.get(buf) ~= nil end, 20)
  vim.api.nvim_set_current_buf(buf)
  return buf, p
end

local function key(i) return Image.output_key("c1", i) end
local function shown(i) local p = Image._placements[key(i)]; return p and p.b64 end

local function settle(want)
  vim.wait(3000, function()
    for i, b in ipairs(want) do if shown(i) ~= b then return false end end
    return true
  end, 20)
  vim.wait(300)
end

local function image_rows(buf)
  local cell = NB.get(buf).cells[1]
  return #Render._build_image_virt_lines(cell, 80, NB.get(buf), "")
end

local function event(buf, ev)
  J._handle_cell_event({ session_id = NB.get(buf).session_id, cell_id = "c1", event = ev })
end

local function close(buf, p)
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  Image.clear_all()
  os.remove(p)
end

-- Count the transmits that reach the backend, to catch doubled sends.
local transmits = 0
local function count_transmits()
  local cl = J.client
  if cl and not cl.__counted then
    local orig = cl.call_sync
    cl.call_sync = function(self, method, ...)
      if method == "kitty_transmit_virtual" then transmits = transmits + 1 end
      return orig(self, method, ...)
    end
    cl.__counted = true
  end
end

-- ── opened from disk ────────────────────────────────────────────────────
do
  local buf, p = open({ display(A), display(B) })
  count_transmits()
  settle({ A, B })
  chk("both plots are transmitted", shown(1) == A and shown(2) == B,
      ("slot1=%s slot2=%s"):format(shown(1) == A and "A" or tostring(shown(1) and "other"),
                                   shown(2) == B and "B" or tostring(shown(2) and "other")))
  chk("each plot has its own image id",
      Image._placements[key(1)] and Image._placements[key(2)]
      and Image._placements[key(1)].image_id ~= Image._placements[key(2)].image_id)
  chk("the cell reserves rows for both plots and a gap", image_rows(buf) == 2 * ROWS + 1,
      image_rows(buf) .. " rows")
  local ids = { Image._placements[key(1)].image_id, Image._placements[key(2)].image_id }
  Render.refresh_sync(NB.get(buf), vim.fn.bufwinid(buf))
  chk("a later render keeps both, in order",
      Image._placements[key(1)].image_id == ids[1] and Image._placements[key(2)].image_id == ids[2])
  close(buf, p)
end

-- ── produced live, the reported case ─────────────────────────────────────
do
  local buf, p = open({})
  count_transmits()
  transmits = 0
  event(buf, { kind = "execute_input", execution_count = 1 })
  event(buf, { kind = "display_data", data = { ["image/png"] = A }, metadata = {} })
  event(buf, { kind = "display_data", data = { ["image/png"] = B }, metadata = {} })
  settle({ A, B })
  chk("a live run with two plt.show() shows both", shown(1) == A and shown(2) == B)
  chk("each plot is sent to the terminal once", transmits == 2, transmits .. " transmits")

  -- re-run producing a single plot: the second slot must go
  event(buf, { kind = "execute_input", execution_count = 2 })
  event(buf, { kind = "display_data", data = { ["image/png"] = C }, metadata = {} })
  settle({ C })
  chk("a re-run with fewer plots frees the extra one", shown(1) == C and Image._placements[key(2)] == nil)
  close(buf, p)
end

-- ── clear_output(wait=True): a live-updating frame ──────────────────────
do
  local buf, p = open({})
  event(buf, { kind = "execute_input", execution_count = 1 })
  event(buf, { kind = "display_data", data = { ["image/png"] = A }, metadata = {} })
  settle({ A })
  -- the backend applies the deferred clear and says so on the next output
  event(buf, { kind = "clear_output", wait = true })
  chk("clear_output(wait=True) keeps the frame until the next one", #NB.get(buf).cells[1].outputs == 1)
  event(buf, { kind = "display_data", data = { ["image/png"] = B }, metadata = {}, clear_first = true })
  settle({ B })
  chk("the next frame replaces it instead of stacking", #NB.get(buf).cells[1].outputs == 1
      and shown(1) == B and Image._placements[key(2)] == nil)
  close(buf, p)
end

-- ── update_display_data ──────────────────────────────────────────────────
do
  local buf, p = open({})
  event(buf, { kind = "execute_input", execution_count = 1 })
  event(buf, { kind = "display_data", data = { ["image/png"] = A }, metadata = {},
               transient = { display_id = "h1" } })
  event(buf, { kind = "display_data", data = { ["image/png"] = B }, metadata = {},
               transient = { display_id = "h2" } })
  settle({ A, B })
  event(buf, { kind = "update_display_data", display_id = "h1",
               data = { ["image/png"] = C }, metadata = {}, cells = { "c1" } })
  settle({ C, B })
  chk("h.update() replaces the output it names", shown(1) == C and shown(2) == B)
  close(buf, p)
end

-- ── saving when a cell has several ───────────────────────────────────────
do
  local buf, p = open({ display(A), display(B) })
  settle({ A, B })
  local offered
  local real_select = vim.ui.select
  vim.ui.select = function(items, _, cb) offered = #items; cb(items[2]) end
  local real_input = vim.fn.input
  local out = tmp .. "/second.png"
  vim.fn.input = function() return out end
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  J.save_image(buf)
  vim.ui.select, vim.fn.input = real_select, real_input
  local f = io.open(out, "rb")
  local got = f and f:read("*a")
  if f then f:close() end
  chk(":JupynvimSaveImage offers each image in the cell", offered == 2, tostring(offered))
  chk("and saves the one picked", got == vim.base64.decode(B))
  close(buf, p)
end

-- ── an output that goes away while its image is being sent ──────────────
-- A local transmit waits in call_sync, and a render nested in that wait can
-- find the output gone. The image then landed for a key nothing would ever
-- clear again, and a gif kept animating for the rest of the session.
do
  local buf, p = open({})
  local nb = NB.get(buf)
  local cl = J.client
  local before = cl.call_sync
  local fired = false
  cl.call_sync = function(self, method, ...)
    if method == "kitty_transmit_virtual" and not fired then
      fired = true
      nb.cells[1].outputs = {}
      Render.refresh_sync(nb, vim.fn.bufwinid(buf))
    end
    return before(self, method, ...)
  end
  event(buf, { kind = "execute_input", execution_count = 1 })
  event(buf, { kind = "display_data", data = { ["image/png"] = A }, metadata = {} })
  vim.wait(2000, function() return fired end, 20)
  vim.wait(400)
  cl.call_sync = before
  chk("an image whose output vanished while it was sent is freed", fired and Image._placements[key(1)] == nil,
      fired and "still placed" or "the transmit never ran")
  close(buf, p)
end

-- ── a newer frame overtakes an older one on the way ──────────────────────
do
  local buf, p = open({})
  local cl = J.client
  local before_sync, before_async = cl.call_sync, cl.call
  local cleared = {}
  cl.call = function(self, method, params, cb)
    if method == "kitty_clear_image" then cleared[#cleared + 1] = params.image_id end
    return before_async(self, method, params, cb)
  end
  local nested = false
  cl.call_sync = function(self, method, params, ...)
    if method == "kitty_transmit_virtual" and not nested then
      nested = true
      Image.ensure_transmitted(key(1), B, function() end, { renderer = "placeholder", mime = "image/png" })
    end
    return before_sync(self, method, params, ...)
  end
  local older
  Image.ensure_transmitted(key(1), A, function(id) older = id end, { renderer = "placeholder", mime = "image/png" })
  vim.wait(500)
  cl.call_sync, cl.call = before_sync, before_async
  chk("a newer frame is not covered by the older one landing after it", shown(1) == B,
      shown(1) == A and "the older frame is showing" or "nothing is showing")
  chk("and the older frame's image is freed", #cleared >= 1, vim.inspect(cleared))
  close(buf, p)
end

-- ── deleting a markdown image, then undo ─────────────────────────────────
do
  local p = tmp .. "/md.ipynb"
  local f = io.open(p, "w")
  f:write(vim.json.encode({ cells = { { cell_type = "markdown", id = "m1", metadata = vim.empty_dict(),
    source = "# pic\n\n![p](data:image/png;base64," .. A .. ")\n" } }, nbformat = 4, nbformat_minor = 5,
    metadata = { kernelspec = { name = "python3", display_name = "P", language = "python" } } }))
  f:close()
  local buf = J.open(p)
  vim.wait(3000, function() return NB.get(buf) ~= nil end, 20)
  vim.api.nvim_set_current_buf(buf)
  local nb = NB.get(buf)
  vim.wait(3000, function() return Image._placements["m1_md_1"] ~= nil end, 20)
  local src = nb.cells[1].source
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  J.delete_image(buf)
  vim.wait(400)
  chk("deleting a markdown image takes it off the screen", Image._placements["m1_md_1"] == nil)
  -- what u does: the placeholder line comes back
  nb.cells[1].source = src
  J._populate_buffer(nb)
  Render.refresh_sync(nb, vim.fn.bufwinid(buf))
  vim.wait(2000, function() return Image._placements["m1_md_1"] ~= nil end, 20)
  chk("undoing the delete brings the image back", Image._placements["m1_md_1"] ~= nil)
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  Image.clear_all()
end

vim.fn.delete(tmp, "rf")

if fails == 0 then
  io.write("\nALL MULTI-IMAGE CHECKS PASSED\n")
  vim.cmd("qa!")
else
  io.write(("\nMULTI-IMAGE: %d CHECK(S) FAILED\n"):format(fails))
  vim.cmd("cquit 1")
end

-- #32: closing a Julia notebook with :bdelete and opening it again attached
-- pyright next to julials.
--
-- :bdelete resets the buffer's options and b: vars but keeps its
-- buffer-local autocmds. On the next :e the old BufEnter handler ran while
-- M.open was still waiting on the backend, found no b:jupynvim_filetype, and
-- set filetype=python with buftype still "". vim.lsp.enable's FileType
-- handler then started pyright, and the later switch to julia never
-- detached it. Any language jupynvim did not know was also mapped to python
-- on the very first open.
--
-- The servers here are in-process fakes, so the spec needs neither pyright
-- nor julia installed. What it asserts is which configs Neovim decided to
-- start on the notebook buffer.

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local fails = 0
local function chk(name, cond, detail)
  if cond then io.write("  ok " .. name .. "\n")
  else io.write("FAIL " .. name .. (detail and ("  -- " .. detail) or "") .. "\n"); fails = fails + 1 end
end

vim.notify = function() end

local function fake_server()
  return function(dispatchers)
    local closing = false
    local srv = {}
    function srv.request(method, _, callback)
      vim.schedule(function()
        if method == "initialize" then callback(nil, { capabilities = {} })
        else callback(nil, vim.NIL) end
      end)
      return true, 1
    end
    function srv.notify(method)
      if method == "exit" then closing = true; dispatchers.on_exit(0, 15) end
      return true
    end
    function srv.is_closing() return closing end
    function srv.terminate() closing = true end
    return srv
  end
end

vim.lsp.config("pyright", { cmd = fake_server(), filetypes = { "python" } })
-- julials itself gets its cmd rewritten to Mason's julia-lsp wrapper in _attach_lsp,
-- which is not installed here, so a fake under another name stands in.
vim.lsp.config("juliafake", { cmd = fake_server(), filetypes = { "julia" } })
vim.lsp.config("bashls", { cmd = fake_server(), filetypes = { "sh" } })
vim.lsp.enable({ "juliafake", "pyright", "bashls" })

local J  = require("jupynvim")
local NB = require("jupynvim.notebook")
J.setup({ log_level = "warn" })

local python_ft = {}
vim.api.nvim_create_autocmd("FileType", {
  pattern = "python",
  callback = function(a) python_ft[#python_ft + 1] = a.buf end,
})

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")

local function write_nb(name, metadata)
  local p = tmp .. "/" .. name .. ".ipynb"
  local f = io.open(p, "w")
  f:write(vim.json.encode({
    cells = { { cell_type = "code", id = "c1", metadata = vim.empty_dict(),
                source = "println(\"hi\")", execution_count = vim.NIL, outputs = {} } },
    metadata = metadata, nbformat = 4, nbformat_minor = 0,
  }))
  f:close()
  return p
end

local function edit(path)
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  local buf = vim.fn.bufnr(path)
  vim.wait(4000, function()
    return NB.get(buf) ~= nil and vim.b[buf].jupynvim_filetype ~= nil
  end, 20)
  vim.wait(600)
  return buf
end

local function clients(buf)
  local names = {}
  for _, c in ipairs(vim.lsp.get_clients({ bufnr = buf })) do names[c.name] = true end
  return names
end

local function names(t)
  local out = vim.tbl_keys(t)
  table.sort(out)
  return table.concat(out, ",")
end

-- the reporter's notebook
local julia = write_nb("julia-test", {
  kernelspec = { display_name = "Julia 0.5.0", language = "julia", name = "julia-0.5" },
  language_info = { file_extension = ".jl", mimetype = "application/julia",
                    name = "julia", version = "0.5.0" },
})

do
  local buf = edit(julia)
  local c = clients(buf)
  chk("first open: filetype is julia", vim.bo[buf].filetype == "julia", vim.bo[buf].filetype)
  chk("first open: the julia server attached", c.juliafake, names(c))
  chk("first open: pyright not attached", not c.pyright, names(c))

  vim.cmd("bdelete")
  vim.wait(300)
  python_ft = {}

  buf = edit(julia)
  c = clients(buf)
  chk("reopen after :bdelete: filetype is julia", vim.bo[buf].filetype == "julia",
      vim.bo[buf].filetype)
  chk("reopen after :bdelete: no FileType python fired on the notebook",
      not vim.tbl_contains(python_ft, buf))
  chk("reopen after :bdelete: the julia server attached", c.juliafake, names(c))
  chk("reopen after :bdelete: pyright not attached", not c.pyright, names(c))
  pcall(vim.cmd, "bwipeout!")
end

do
  local buf = edit(write_nb("bash-test", {
    kernelspec = { display_name = "Bash", language = "bash", name = "bash" },
    language_info = { file_extension = ".sh", name = "bash" },
  }))
  local c = clients(buf)
  chk("a bash notebook gets filetype sh, not python", vim.bo[buf].filetype == "sh",
      vim.bo[buf].filetype)
  chk("a bash notebook does not get pyright", not c.pyright, names(c))
  pcall(vim.cmd, "bwipeout!")
end

do
  local buf = edit(write_nb("rust-test", {
    kernelspec = { display_name = "Rust", language = "rust", name = "rust" },
    language_info = { file_extension = ".rs", name = "Rust" },
  }))
  chk("an unmapped language resolves through its file extension",
      vim.bo[buf].filetype == "rust", vim.bo[buf].filetype)
  pcall(vim.cmd, "bwipeout!")
end

do
  local buf = edit(write_nb("bare-test", vim.empty_dict()))
  chk("a notebook with no language metadata is still python",
      vim.bo[buf].filetype == "python", vim.bo[buf].filetype)
  pcall(vim.cmd, "bwipeout!")
end

-- ── language names ───────────────────────────────────────────────────────
do
  local lf = J._language_filetype
  local function ft(meta) return lf({ metadata = meta }) end
  chk("kernelspec language python3 is python", ft({ kernelspec = { language = "python3" } }) == "python")
  chk("kernelspec language 'Python 3' is python", ft({ kernelspec = { language = "Python 3" } }) == "python")
  chk("ipython is python", ft({ language_info = { name = "ipython" } }) == "python")
  chk("VSCode's plaintext means no language yet, so python",
      ft({ language_info = { name = "plaintext" } }) == "python")
  chk("an empty kernelspec language falls through to language_info",
      ft({ kernelspec = { language = "" }, language_info = { name = "julia" } }) == "julia")
end

-- ── a reopen that fails must not let :w write placeholders over the file ──
do
  local p = write_nb("fails-on-reopen", {
    kernelspec = { display_name = "P", language = "python", name = "python3" } })
  local buf = edit(p)
  vim.cmd("bdelete")
  vim.wait(300)
  -- the file turns unreadable while closed, say a bad merge
  local broken = "<<<<<<< HEAD\nnot json at all\n>>>>>>> theirs\n"
  local f = io.open(p, "w"); f:write(broken); f:close()
  pcall(vim.cmd, "edit " .. vim.fn.fnameescape(p))
  vim.wait(1500)
  pcall(vim.cmd, "write")
  vim.wait(300)
  local now = io.open(p):read("*a")
  chk("a failed reopen leaves the file as it was on :w", now == broken,
      ("file is now %d bytes of %q"):format(#now, now:sub(1, 40)))
  pcall(vim.cmd, "bwipeout!")
end

-- ── what a kernel start does depends on the kernel that started ──────────
do
  -- a .venv beside the notebook, with a python in it
  local dir = tmp .. "/proj"
  vim.fn.mkdir(dir .. "/.venv/bin", "p")
  local py = dir .. "/.venv/bin/python"
  local f = io.open(py, "w"); f:write("#!/bin/sh\nexit 0\n"); f:close()
  vim.fn.setfperm(py, "rwxr-xr-x")
  local p = dir .. "/j.ipynb"
  f = io.open(p, "w")
  f:write(vim.json.encode({ cells = { { cell_type = "code", id = "c1", metadata = vim.empty_dict(),
    source = "1", execution_count = vim.NIL, outputs = {} } }, nbformat = 4, nbformat_minor = 5,
    metadata = { kernelspec = { name = "julia-1.12", language = "julia", display_name = "J" } } }))
  f:close()
  local buf = edit(p)
  local nb = NB.get(buf)

  local calls = {}
  local function fake(started)
    return { job = 1, call = function(_, method, params, cb)
      calls[#calls + 1] = { method = method, params = params }
      if method == "start_kernel" and cb then cb(nil, started) end
    end }
  end
  local real = J._ensure_client
  local function start(started)
    calls = {}
    nb.kernel_started = false
    nb.kernel_python_path = nil
    J._ensure_client = function() return fake(started) end
    J.start_kernel(buf)
    vim.wait(200)
    J._ensure_client = real
  end
  local function sent(method)
    for _, c in ipairs(calls) do if c.method == method then return c end end
  end

  start({ kernel_name = "julia-1.12", language = "julia", argv = { "/opt/julia/bin/julia" } })
  chk("a julia notebook does not start the .venv beside it", sent("start_kernel").params.python_path == nil,
      tostring(sent("start_kernel").params.python_path))
  chk("a julia kernel gets no matplotlib magic", sent("execute_silent") == nil)
  chk("and its binary is never taken for a python", nb.kernel_python_path == nil,
      tostring(nb.kernel_python_path))

  start({ kernel_name = "python3", language = "python", argv = { py, "-m", "ipykernel_launcher" } })
  chk("switching it to a python kernel does get the magic", sent("execute_silent") ~= nil)
  chk("and the python path from the kernel that started", nb.kernel_python_path == py,
      tostring(nb.kernel_python_path))
  pcall(vim.cmd, "bwipeout!")
end

vim.fn.delete(tmp, "rf")

if fails == 0 then
  io.write("\nALL REOPEN-LSP CHECKS PASSED\n")
  vim.cmd("qa!")
else
  io.write(("\nREOPEN-LSP: %d CHECK(S) FAILED\n"):format(fails))
  vim.cmd("cquit 1")
end

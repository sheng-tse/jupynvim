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

-- a notebook-aware server, recording the notebookDocument messages it gets
local nbmsgs = {}
local function notebook_server()
  return function(dispatchers)
    local closing = false
    local srv = {}
    function srv.request(method, _, callback)
      vim.schedule(function()
        if method == "initialize" then
          callback(nil, { capabilities = {
            notebookDocumentSync = { notebookSelector = { { notebook = "*" } } } } })
        else callback(nil, vim.NIL) end
      end)
      return true, 1
    end
    function srv.notify(method)
      if method:find("^notebookDocument/") then nbmsgs[#nbmsgs + 1] = method end
      if method == "exit" then closing = true; dispatchers.on_exit(0, 15) end
      return true
    end
    function srv.is_closing() return closing end
    function srv.terminate() closing = true end
    return srv
  end
end
vim.lsp.config("tyfake", { cmd = notebook_server(), filetypes = { "python" } })

-- pyrightconfig.json is one of pyright's real root markers. Only the project
-- that has one gets a root this way; every other dir falls back as before.
vim.lsp.config("pyright", { cmd = fake_server(), filetypes = { "python" },
                            root_markers = { "pyrightconfig.json" } })
-- julials itself gets its cmd rewritten to Mason's julia-lsp wrapper in _attach_lsp,
-- which is not installed here, so a fake under another name stands in.
vim.lsp.config("juliafake", { cmd = fake_server(), filetypes = { "julia" } })
vim.lsp.config("bashls", { cmd = fake_server(), filetypes = { "sh" } })
vim.lsp.enable({ "juliafake", "pyright", "bashls", "tyfake" })

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

-- ── pyright: one per notebook, reused across a reopen ──────────────────
-- A .venv beside the notebooks gives every open a known interpreter, so the
-- reuse rule for Python servers runs whatever kernels the host has.
local PROJ = tmp .. "/pyproj"
vim.fn.mkdir(PROJ .. "/.venv/bin", "p")
local VPY = PROJ .. "/.venv/bin/python"
do
  local f = io.open(VPY, "w"); f:write("#!/bin/sh\nexit 0\n"); f:close()
  vim.fn.setfperm(VPY, "rwxr-xr-x")
end
local function py_nb(name, dir)
  local p = (dir or PROJ) .. "/" .. name .. ".ipynb"
  local f = io.open(p, "w")
  f:write(vim.json.encode({ cells = { { cell_type = "code", id = "c1", metadata = vim.empty_dict(),
    source = "x = 1", execution_count = vim.NIL, outputs = {} } }, nbformat = 4, nbformat_minor = 5,
    metadata = { kernelspec = { display_name = "P", language = "python", name = "python3" } } }))
  f:close()
  return p
end
local function pyright_of(buf) return vim.lsp.get_clients({ bufnr = buf, name = "pyright" })[1] end
-- servers of `name` running for the project at `root`, attached or not
local function running(name, root)
  local n = 0
  for _, c in ipairs(vim.lsp.get_clients({ name = name })) do
    if vim.fn.resolve(c.config.root_dir or "") == vim.fn.resolve(root) and not c:is_stopped() then
      n = n + 1
    end
  end
  return n
end
local function python_path(client)
  return client and ((client.settings or {}).python or {}).pythonPath
end

do
  local p = py_nb("py-reopen")
  local buf = edit(p)
  chk("the notebook has a known interpreter (precondition)",
      NB.get(buf) and NB.get(buf).kernel_python_path == VPY,
      tostring(NB.get(buf) and NB.get(buf).kernel_python_path))
  local first = pyright_of(buf)
  vim.cmd("bdelete")
  vim.wait(300)
  buf = edit(p)
  vim.cmd("bdelete")
  vim.wait(300)
  buf = edit(p)
  local n = running("pyright", PROJ)
  chk("a python notebook gets pyright", first ~= nil and pyright_of(buf) ~= nil)
  chk("reopening it twice leaves one pyright, not three", n == 1, n .. " pyright clients running")
  pcall(vim.cmd, "bwipeout!")
end

do
  local a = edit(py_nb("nb-a"))
  local b = edit(py_nb("nb-b"))
  local ca, cb = pyright_of(a), pyright_of(b)
  chk("two notebooks in one project get a pyright each", ca and cb and ca.id ~= cb.id,
      ("%s / %s"):format(tostring(ca and ca.id), tostring(cb and cb.id)))
  -- notebook A switches kernel: its pyright moves, B's does not
  J._sync_lsp_python_path(a, "/other/env/bin/python", {})
  chk("switching one notebook's interpreter leaves the other's alone",
      python_path(cb) == VPY and python_path(ca) == "/other/env/bin/python",
      ("a=%s b=%s"):format(tostring(python_path(ca)), tostring(python_path(cb))))
  pcall(vim.api.nvim_buf_delete, a, { force = true })
  pcall(vim.api.nvim_buf_delete, b, { force = true })
end

do
  -- A .py file in the project got a pyright from vim.lsp.enable, which syncs
  -- incrementally, and :bdelete left it running with no buffer. Taking it
  -- over sent the notebook's raw markdown and output lines to the server
  -- instead of the cleaned text that only Full sync carries.
  local proj = tmp .. "/pyfile"
  vim.fn.mkdir(proj .. "/.venv/bin", "p")
  local py = proj .. "/.venv/bin/python"
  local f = io.open(py, "w"); f:write("#!/bin/sh\nexit 0\n"); f:close()
  vim.fn.setfperm(py, "rwxr-xr-x")
  f = io.open(proj .. "/pyrightconfig.json", "w"); f:write("{}\n"); f:close()
  local pyf = proj .. "/mod.py"
  f = io.open(pyf, "w"); f:write("x = 1\n"); f:close()
  vim.cmd("edit " .. vim.fn.fnameescape(pyf))
  vim.bo.filetype = "python"   -- -u NONE detects no filetypes
  vim.wait(2000, function() return pyright_of(0) ~= nil end, 20)
  local plain = pyright_of(0)
  vim.cmd("bdelete")
  vim.wait(300)
  chk("a .py file's pyright is left idle for the project (precondition)",
      plain and not plain:is_stopped() and next(plain.attached_buffers) == nil
      and vim.fn.resolve(plain.config.root_dir or "") == vim.fn.resolve(proj),
      tostring(plain and plain.config.root_dir))
  local buf = edit(py_nb("after-py", proj))
  local c = pyright_of(buf)
  chk("a notebook does not take over a .py file's idle pyright",
      c and plain and c.id ~= plain.id and c.flags.allow_incremental_sync == false,
      ("notebook %s, .py %s, allow_incremental_sync %s"):format(tostring(c and c.id),
        tostring(plain and plain.id), tostring(c and c.flags.allow_incremental_sync)))
  pcall(vim.api.nvim_buf_delete, buf, { force = true })

  -- nor one whose interpreter nothing could find: no .venv, no such kernel
  local proj2 = tmp .. "/pyfile2"
  vim.fn.mkdir(proj2, "p")
  f = io.open(proj2 .. "/pyrightconfig.json", "w"); f:write("{}\n"); f:close()
  pyf = proj2 .. "/mod.py"
  f = io.open(pyf, "w"); f:write("x = 1\n"); f:close()
  vim.cmd("edit " .. vim.fn.fnameescape(pyf))
  vim.bo.filetype = "python"
  vim.wait(2000, function() return pyright_of(0) ~= nil end, 20)
  plain = pyright_of(0)
  vim.cmd("bdelete")
  vim.wait(300)
  local p = proj2 .. "/no-interp.ipynb"
  f = io.open(p, "w")
  f:write(vim.json.encode({ cells = { { cell_type = "code", id = "c1", metadata = vim.empty_dict(),
    source = "x = 1", execution_count = vim.NIL, outputs = {} } }, nbformat = 4, nbformat_minor = 5,
    metadata = { kernelspec = { display_name = "N", language = "python", name = "jn-no-such-kernel" } } }))
  f:close()
  buf = edit(p)
  c = pyright_of(buf)
  chk("nor does one with no interpreter found",
      NB.get(buf) and NB.get(buf).kernel_python_path == nil
      and c and plain and c.id ~= plain.id and c.flags.allow_incremental_sync == false,
      ("py_path %s, notebook %s, .py %s"):format(tostring(NB.get(buf) and NB.get(buf).kernel_python_path),
        tostring(c and c.id), tostring(plain and plain.id)))
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end

-- ── a notebook-aware server sees the reopened notebook ──────────────────
do
  local p = write_nb("ty-reopen", {
    kernelspec = { display_name = "P", language = "python", name = "python3" } })
  nbmsgs = {}
  edit(p)
  vim.cmd("bdelete")
  vim.wait(300)
  edit(p)
  vim.wait(300)
  local opens, closes = 0, 0
  for _, m in ipairs(nbmsgs) do
    if m == "notebookDocument/didOpen" then opens = opens + 1 end
    if m == "notebookDocument/didClose" then closes = closes + 1 end
  end
  chk("a reopen closes the old notebook document and opens the new one",
      opens == 2 and closes == 1, vim.inspect(nbmsgs))
  chk("and the server is reused, not started again", running("tyfake", tmp) == 1,
      running("tyfake", tmp) .. " running")
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

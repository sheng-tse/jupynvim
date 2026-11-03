-- Pre-release versions (v0.5.0-beta.1, v0.5.0-rc.1) through everything
-- that reads a version: the installer and its download of the release
-- assets, the check between the plugin and the binary it runs, the deploy's
-- check of the cross-built binary, the library's loader, :checkhealth, the
-- kernel language server's serverInfo and the release workflow (the tags it
-- runs for, the tag check, the pre-release flag and the version the library
-- check reads).
--
-- Every case uses a copy of the plugin whose core/Cargo.toml names a fixed
-- pre-release, so the checks hold whatever version this tree is at. Nothing
-- touches the network: releases are directories (file://) and the binaries
-- are shell scripts that answer --version.

local fails = 0
local function chk(name, cond, detail)
  if cond then io.write("  ok " .. name .. "\n")
  else io.write("\nFAIL " .. name .. (detail and ("  -- " .. tostring(detail)) or "") .. "\n"); fails = fails + 1 end
end
-- a case whose code throws is a failure, and the cases after it still run
local function case(name, fn)
  local ok, err = pcall(fn)
  if not ok then chk(name, false, err) end
end

local REPO = vim.fn.getcwd()
vim.opt.runtimepath:prepend(REPO)
package.path = REPO .. "/lua/?.lua;" .. REPO .. "/lua/?/init.lua;" .. package.path
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")

local BETA, RC = "0.5.0-beta.1", "0.5.0-rc.1"
local BETA_TAG = "v" .. BETA

local function read_file(p)
  local f = io.open(p, "rb")
  if not f then return nil end
  local s = f:read("*a"); f:close()
  return s
end
local function write_file(p, s)
  vim.fn.mkdir(vim.fn.fnamemodify(p, ":h"), "p")
  local f = assert(io.open(p, "wb")); f:write(s); f:close()
end
local function has(s, sub) return type(s) == "string" and s:find(sub, 1, true) ~= nil end
local function sha256(p)
  local tool = vim.fn.executable("shasum") == 1 and { "shasum", "-a", "256", p } or { "sha256sum", p }
  return (vim.system(tool, { text = true }):wait().stdout or ""):match("^(%x+)")
end
local function manifest(name, version)
  -- the [package] version comes first; the dependency's must not be read
  return ('[package]\nname = "%s"\nversion = "%s"\nedition = "2021"\n\n[dependencies]\n'
    .. 'serde = { version = "1", features = ["derive"] }\n'):format(name, version)
end
-- A copy of the plugin (its Lua and both manifests) at `version`.
local function plugin(name, version)
  local dir = tmp .. "/" .. name
  vim.fn.mkdir(dir .. "/core/native", "p")
  local cp = vim.system({ "cp", "-R", REPO .. "/lua", dir .. "/lua" }):wait()
  assert(cp.code == 0, "cp: " .. tostring(cp.stderr))
  write_file(dir .. "/core/Cargo.toml", manifest("jupynvim-core", version))
  write_file(dir .. "/core/native/Cargo.toml", manifest("libjupynvim", version))
  return dir
end
local function fake_core(path, version)
  write_file(path, "#!/bin/sh\necho 'jupynvim-core " .. version .. "'\n")
  vim.fn.setfperm(path, "rwxr-xr-x")
end

-- No jupynvim-core from the host's PATH, the installer's records in a state
-- dir of our own, and every download a case does not point elsewhere goes
-- to a release that does not exist.
local BIN = tmp .. "/bin"
vim.fn.mkdir(BIN, "p")
vim.env.PATH = BIN .. ":/usr/bin:/bin:/usr/sbin:/sbin"
local real_stdpath = vim.fn.stdpath
---@diagnostic disable-next-line: duplicate-set-field
vim.fn.stdpath = function(what)
  if what == "state" then return tmp .. "/state" end
  return real_stdpath(what)
end
local NO_RELEASE = "file://" .. tmp .. "/no-release"
vim.env.JUPYNVIM_RELEASE_BASE = NO_RELEASE

local notes = {}
local real_notify = vim.notify
---@diagnostic disable-next-line: duplicate-set-field
vim.notify = function(msg, level) notes[#notes + 1] = { msg = tostring(msg), level = level } end
local function notes_text()
  local t = {}
  for _, n in ipairs(notes) do t[#t + 1] = n.msg end
  return table.concat(t, " | ")
end

local Install = require("jupynvim.backend.install")
local J = require("jupynvim")

-- ── R1 the installer reads the version, and the tag and URLs from it ────
local P_BETA = plugin("beta", BETA)
local P_RC = plugin("rc", RC)
case("R1", function()
  chk("R1 the installer reads a beta version from core/Cargo.toml", Install.source_version(P_BETA) == BETA,
      Install.source_version(P_BETA))
  chk("R1 and a release candidate", Install.source_version(P_RC) == RC, Install.source_version(P_RC))
  chk("R1 the release tag is v<version>, suffix and all", Install._detect_tag(P_BETA) == BETA_TAG
      and Install._detect_tag(P_RC) == "v" .. RC, tostring(Install._detect_tag(P_BETA)))
  vim.env.JUPYNVIM_RELEASE_BASE = "https://mirror.example/jnv"
  local url = Install._url_for(BETA_TAG, "x86_64-unknown-linux-musl")
  vim.env.JUPYNVIM_RELEASE_BASE = NO_RELEASE
  chk("R1 the core asset's URL names the pre-release tag",
      url == "https://mirror.example/jnv/v0.5.0-beta.1/jupynvim-core-x86_64-unknown-linux-musl", url)
end)

-- ── R2 a binary's --version, suffix and all ──────────────────────────────
case("R2", function()
  local b, r = tmp .. "/v/beta", tmp .. "/v/rc"
  fake_core(b, BETA); fake_core(r, RC)
  chk("R2 a binary's --version is read with its pre-release suffix", Install._run_version(b).version == BETA,
      vim.inspect(Install._run_version(b)))
  chk("R2 also a release candidate's", Install._run_version(r).version == RC, vim.inspect(Install._run_version(r)))
end)

-- ── R3 the core's download from a pre-release ────────────────────────────
-- A release laid out like GitHub's downloads: <base>/<tag>/<asset> and its
-- SHA256SUMS, with real curl and the real checksum check.
local function release(dir, tag, assets)
  local sums = {}
  for name, body in pairs(assets) do
    local p = dir .. "/" .. tag .. "/" .. name
    write_file(p, body)
    sums[#sums + 1] = sha256(p) .. "  " .. name
  end
  table.sort(sums)
  write_file(dir .. "/" .. tag .. "/SHA256SUMS", table.concat(sums, "\n") .. "\n")
  return "file://" .. dir
end
local function core_script(version) return "#!/bin/sh\necho 'jupynvim-core " .. version .. "'\n" end
local targets = Install._detect_targets()
case("R3", function()
  if #targets == 0 then
    io.write("  skip R3: no core prebuilt is made for this platform\n")
    return
  end
  local assets = {}
  for _, t in ipairs(targets) do assets["jupynvim-core-" .. t] = core_script(BETA) end
  vim.env.JUPYNVIM_RELEASE_BASE = release(tmp .. "/rel-beta", BETA_TAG, assets)
  notes = {}
  local ok, res = pcall(Install.run, P_BETA, { no_cargo = true, lib_later = true })
  vim.env.JUPYNVIM_RELEASE_BASE = NO_RELEASE
  local final = P_BETA .. "/core/target/release/jupynvim-core"
  chk("R3 a plugin at a beta installs the core from the beta's release", ok and res == true,
      tostring(res) .. " / " .. notes_text())
  chk("R3 and the installed core reports the beta", Install._run_version(final).version == BETA,
      vim.inspect(Install._run_version(final)))
  chk("R3 its checksum was verified", has(notes_text(), "checksum verified"), notes_text())

  -- the final release's binary is not the beta's, nor the other way round
  local wrong = {}
  for _, t in ipairs(targets) do wrong["jupynvim-core-" .. t] = core_script("0.5.0") end
  vim.env.JUPYNVIM_RELEASE_BASE = release(tmp .. "/rel-wrong", BETA_TAG, wrong)
  local dest = tmp .. "/wrong/jupynvim-core"
  vim.fn.mkdir(tmp .. "/wrong", "p")
  local okf, why = Install._fetch(BETA_TAG, targets[1], dest, BETA)
  vim.env.JUPYNVIM_RELEASE_BASE = NO_RELEASE
  chk("R3 a core that reports 0.5.0 is refused for a plugin at 0.5.0-beta.1, naming both",
      okf == false and why == "it is v0.5.0, not v0.5.0-beta.1" and vim.uv.fs_stat(dest) == nil, tostring(why))
end)

-- ── R4 the library's download from a pre-release ─────────────────────────
-- The library check in a Neovim of its own is native_probe.lua; this copy's
-- probe answers for a library at `version`, so the case needs no build.
case("R4", function()
  local t = Install._lib_target()
  if not t then
    io.write("  skip R4: no library prebuilt is made for this platform\n")
    return
  end
  local function probe_says(dir, version)
    write_file(dir .. "/lua/jupynvim/backend/native_probe.lua",
      ('io.write("jnv-probe ok %s 1.1\\n")\n'):format(version))
  end
  local P = plugin("lib-beta", BETA)
  probe_says(P, BETA)
  local asset = Install._lib_asset(t)
  vim.env.JUPYNVIM_RELEASE_BASE = release(tmp .. "/rel-lib", BETA_TAG, { [asset] = "a library\n" })
  local final = Install.lib_path(P)
  vim.fn.mkdir(vim.fn.fnamemodify(final, ":h"), "p")
  local ok, why = Install._fetch_lib(BETA_TAG, t, final, BETA, P)
  chk("R4 a plugin at a beta installs the library of the beta's release", ok == true and read_file(final) == "a library\n",
      tostring(why))
  chk("R4 and records it at the beta", Install.lib_installed_version(P) == BETA, tostring(Install.lib_installed_version(P)))
  local need = Install.lib_needs_install(P, BETA)
  chk("R4 which then needs no install", need == false, tostring(need))
  probe_says(P, "0.5.0")
  os.remove(final)
  local ok2, why2 = Install._fetch_lib(BETA_TAG, t, final, BETA, P)
  vim.env.JUPYNVIM_RELEASE_BASE = NO_RELEASE
  chk("R4 a library that reports 0.5.0 is refused for a plugin at 0.5.0-beta.1, naming both",
      ok2 == false and why2 == "it is v0.5.0, not v0.5.0-beta.1" and vim.uv.fs_stat(final) == nil, tostring(why2))
end)

-- ── R5 the plugin's check of the binary it runs ──────────────────────────
case("R5", function()
  local real_root, real_run, real_bg = J._plugin_root, Install.run, Install.run_lib_background
  local real_auto = J.config.auto_install
  local runs = {}
  ---@diagnostic disable-next-line: duplicate-set-field
  Install.run = function(root, opts) runs[#runs + 1] = root; error("jupynvim: stub install", 0) end
  Install.run_lib_background = function() return false end
  local P = plugin("locate", BETA)
  J._plugin_root = function() return P end
  J.config.core_path = nil
  local cand = P .. "/core/target/release/jupynvim-core"
  local ok, res = pcall(function()
    fake_core(cand, BETA)
    J._reset_install_tried()
    notes = {}
    local got = J._locate_core()
    chk("R5 a core at the plugin's beta is used as it is", got == cand and #runs == 0, tostring(got))
    chk("R5 with no notice", #notes == 0, notes_text())

    fake_core(cand, "0.5.0")
    J.config.auto_install = false
    notes = {}
    got = J._locate_core()
    chk("R5 a core at 0.5.0 for a plugin at 0.5.0-beta.1 is a mismatch, and the notice names both", got == cand
        and #runs == 0 and has(notes_text(), "jupynvim-core is v0.5.0 but the plugin is v0.5.0-beta.1"), notes_text())

    J.config.auto_install = true
    J._reset_install_tried()
    notes = {}
    got = J._locate_core()
    chk("R5 and with auto_install it fetches the plugin's release", #runs == 1 and runs[1] == P
        and Install._detect_tag(runs[1]) == BETA_TAG, vim.inspect(runs))
  end)
  J._plugin_root, Install.run, Install.run_lib_background = real_root, real_run, real_bg
  J.config.auto_install = real_auto
  J._reset_install_tried()
  if not ok then error(res, 0) end
end)

-- ── R6 the deploy's check of the cross-built linux binary ────────────────
case("R6", function()
  local real_root = J._plugin_root
  local P = plugin("deploy", BETA)
  local triple = "x86_64-unknown-linux-musl"
  local art = P .. "/core/target/" .. triple .. "/release/jupynvim-core"
  local function artifact(version)
    write_file(art, "\127ELF...jupynvim-core starting (v" .. version .. ")...\0")
    -- newer than the manifest, so only the version decides
    local later = os.time() + 60
    vim.uv.fs_utime(art, later, later)
  end
  J._plugin_root = function() return P end
  local ok, res = pcall(function()
    artifact(BETA)
    chk("R6 the version baked into a binary is read with its suffix", J._artifact_version(art) == BETA,
        tostring(J._artifact_version(art)))
    local stale, why = J._linux_core_stale(triple)
    chk("R6 a binary built at the beta is current for a plugin at the beta", stale == false, tostring(why))
    artifact("0.5.0")
    stale, why = J._linux_core_stale(triple)
    chk("R6 one built at 0.5.0 is stale, naming both", stale == true
        and why == "built from v0.5.0 but the manifest says v0.5.0-beta.1", tostring(why))
  end)
  J._plugin_root = real_root
  if not ok then error(res, 0) end
end)

-- ── R7 the kernel language server names the plugin's version ─────────────
case("R7", function()
  local real_root = J._plugin_root
  J._plugin_root = function() return P_BETA end
  local ok, res = pcall(function()
    local K = require("jupynvim.lsp.kernel")
    local client = K._make_cmd(0, function() end, function() end)({})
    local got
    client.request("initialize", {}, function(_, r) got = r end)
    local info = got and got.serverInfo or {}
    chk("R7 the kernel language server's serverInfo carries the plugin's version",
        info.name == "jupynvim_kernel" and info.version == BETA, vim.inspect(info))
  end)
  J._plugin_root = real_root
  if not ok then error(res, 0) end
end)

-- ── R8 the library's loader and :checkhealth, in Neovims of their own ────
-- tests/native/child_case.lua runs setup() and :checkhealth jupynvim with a
-- plugin copy as the plugin; the library loads once per process.
local EXT = vim.uv.os_uname().sysname == "Darwin" and "dylib" or "so"
local REAL_LIB = REPO .. "/core/target/release/libjupynvim." .. EXT
local function health(dir)
  local r = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-l",
    REPO .. "/tests/native/child_case.lua", dir, "health" }, { text = true }):wait(60000)
  local line
  for l in (r.stdout or ""):gmatch("[^\n]+") do
    if l:sub(1, 1) == "{" then line = l end
  end
  local okj, j = pcall(vim.json.decode, line or "")
  if not okj or type(j) ~= "table" or type(j.extra) ~= "table" or type(j.extra.health) ~= "string" then
    return nil, ("exit %s, stdout %q, stderr %q"):format(tostring(r.code), r.stdout or "", r.stderr or "")
  end
  return j, j.extra.health
end
local function line_with(text, sub)
  for l in (text or ""):gmatch("[^\n]+") do if has(l, sub) then return l end end
end
case("R8", function()
  local okffi = pcall(require, "ffi")
  local lib_version = Install.source_version(REPO)
  chk("R8 the library is built (cargo build --release in core/)", not okffi or vim.uv.fs_stat(REAL_LIB) ~= nil, REAL_LIB)
  local RC7 = "0.5.0-rc.7"
  local P = plugin("health", RC7)
  local rel = P .. "/core/target/release"
  vim.fn.mkdir(rel, "p")
  if okffi and vim.uv.fs_stat(REAL_LIB) then vim.uv.fs_copyfile(REAL_LIB, rel .. "/libjupynvim." .. EXT) end
  fake_core(rel .. "/jupynvim-core", RC7)
  local j, text = health(P)
  chk("R8 :checkhealth ran with a plugin at " .. RC7, j ~= nil, text)
  if not j then return end
  chk("R8 :checkhealth names the plugin's version, suffix and all",
      line_with(text, "jupynvim v" .. RC7 .. " at ") ~= nil, text)
  chk("R8 and the core at that version, OK", has(line_with(text, "jupynvim-core v" .. RC7 .. " at "), "OK"), text)
  if okffi and vim.uv.fs_stat(REAL_LIB) then
    -- the library is at this tree's version, never 0.5.0-rc.7: the loader
    -- compares the whole pre-release
    chk("R8 the loader reads the plugin's pre-release and refuses a library of another version, naming both",
        j.status.state == "mismatch" and has(line_with(text, "libjupynvim at "),
          " is v" .. tostring(lib_version) .. " but the plugin is v" .. RC7), vim.inspect(j.status))
  end

  fake_core(rel .. "/jupynvim-core", "0.5.0")
  j, text = health(P)
  chk("R8 a core at 0.5.0 for a plugin at " .. RC7 .. ": a WARNING naming both", j ~= nil
      and has(line_with(text, "jupynvim-core is v0.5.0 but the plugin is v" .. RC7), "WARNING"), text)

  os.remove(rel .. "/jupynvim-core")
  j, text = health(P)
  chk("R8 with no core, :checkhealth still names the plugin's version", j ~= nil
      and line_with(text, "jupynvim v" .. RC7 .. " at ") ~= nil
      and has(line_with(text, "jupynvim-core not found at"), "ERROR"), text)

  -- the library at the manifest's own version loads, a pre-release included
  if okffi and vim.uv.fs_stat(REAL_LIB) and lib_version then
    local PV = plugin("health-own", lib_version)
    vim.fn.mkdir(PV .. "/core/target/release", "p")
    vim.uv.fs_copyfile(REAL_LIB, PV .. "/core/target/release/libjupynvim." .. EXT)
    j, text = health(PV)
    chk("R8 a library at the plugin's own version (v" .. lib_version .. ") loads", j ~= nil
        and j.status.state == "ok" and j.status.version == lib_version, j and vim.inspect(j.status) or text)
  end
end)

-- ── R9 the release workflow ──────────────────────────────────────────────
local WF = REPO .. "/.github/workflows/release.yml"
local wf_lines = vim.split(read_file(WF) or "", "\n", { plain = true })
-- one job: from its "  <name>:" line to the next job's
local function job(name)
  local out, inside = {}, false
  for _, l in ipairs(wf_lines) do
    if l:match("^  [%w_%-]+:%s*$") then inside = (l == "  " .. name .. ":") end
    if inside then out[#out + 1] = l end
  end
  return out
end
-- the script of a job's step that has `run: |`, dedented
local function run_block(jl)
  for i, l in ipairs(jl) do
    local ind = l:match("^(%s*)run: |%s*$")
    if ind then
      local body, cut = {}, nil
      for k = i + 1, #jl do
        local m = jl[k]
        local mi = m:match("^(%s*)%S")
        if mi and #mi <= #ind then break end
        if mi and not cut then cut = #mi end
        body[#body + 1] = m:sub((cut or 0) + 1)
      end
      return table.concat(body, "\n")
    end
  end
end
local function code_line(jl, needle)
  for _, l in ipairs(jl) do
    if not l:match("^%s*#") and l:find(needle, 1, true) then return l end
  end
end
-- A filter pattern of a workflow's tags, as GitHub reads it: * is anything
-- but /, ** anything, ? and + make the character or [set] before them
-- optional or repeated; everything else is itself.
local function glob_match(glob, s)
  local out, i = {}, 1
  while i <= #glob do
    local c = glob:sub(i, i)
    if c == "*" and glob:sub(i + 1, i + 1) == "*" then
      out[#out + 1] = ".*"; i = i + 2
    elseif c == "*" then
      out[#out + 1] = "[^/]*"; i = i + 1
    elseif c == "[" then
      local close = glob:find("]", i + 1, true)
      if not close then return false end
      out[#out + 1] = "[" .. glob:sub(i + 1, close - 1):gsub("%%", "%%%%") .. "]"; i = close + 1
    elseif c == "?" or c == "+" then
      out[#out + 1] = c == "?" and "?" or "+"; i = i + 1
    else
      out[#out + 1] = c:gsub("[%^%$%(%)%%%.%[%]%-]", "%%%0"); i = i + 1
    end
  end
  return s:match("^" .. table.concat(out) .. "$") ~= nil
end
local function sh(script, dir, env)
  local r = vim.system({ "bash", "-c", script }, { cwd = dir, env = env, text = true }):wait(20000)
  return r.code, (r.stdout or "") .. (r.stderr or "")
end

case("R9", function()
  chk("R9 the release workflow is there", #wf_lines > 1, WF)
  -- the tags it runs for
  local tags, in_tags = {}, false
  for _, l in ipairs(wf_lines) do
    if l:match("^%s+tags:%s*$") then in_tags = true
    elseif in_tags then
      local g = l:match("^%s+%-%s*[\"']?([^\"']+)[\"']?%s*$")
      if g then tags[#tags + 1] = g else in_tags = false end
    end
  end
  -- the last pattern that matches decides; one that starts with ! leaves out
  local function runs_for(tag)
    local yes = false
    for _, g in ipairs(tags) do
      if g:sub(1, 1) == "!" then
        if glob_match(g:sub(2), tag) then yes = false end
      elseif glob_match(g, tag) then
        yes = true
      end
    end
    return yes
  end
  chk("R9 the filter model: v* takes a beta, v[0-9]+.[0-9]+.[0-9]+ only a final, a/** a nested name",
      glob_match("v*", BETA_TAG) and not glob_match("v*", "x/v1") and glob_match("v[0-9]+.[0-9]+.[0-9]+", "v0.5.0")
      and not glob_match("v[0-9]+.[0-9]+.[0-9]+", BETA_TAG) and glob_match("a/**", "a/b/c")
      and glob_match("v1.?0", "v1.0") and not glob_match("v1.0", "v1x0"))
  chk("R9 a pushed beta, release candidate and final tag each run the workflow",
      runs_for(BETA_TAG) and runs_for("v" .. RC) and runs_for("v0.5.0"), table.concat(tags, ", "))

  -- the pre-release flag
  local rel = job("release")
  local flag = code_line(rel, "prerelease:") or ""
  local needle = flag:match("prerelease:%s*%${{%s*contains%(github%.ref_name,%s*'([^']+)'%)%s*}}%s*$")
  chk("R9 the release is flagged pre-release by a suffix in its tag", needle ~= nil, flag)
  if needle then
    chk("R9 a beta and a release candidate are pre-releases, the final is not",
        has(BETA_TAG, needle) and has("v" .. RC, needle) and not has("v0.5.0", needle), needle)
  end

  -- the version the library check reads
  local lib = job("build-lib")
  local vline = code_line(lib, "version=$(") or ""
  local code, out = sh(vim.trim(vline) .. '\nprintf "%s" "$version"', P_BETA)
  chk("R9 build-lib reads the beta from core/Cargo.toml for the library check", code == 0 and out == BETA,
      vline .. " => " .. out)

  -- the tag check, before anything is built
  local vjob = job("version")
  local script = run_block(vjob)
  chk("R9 a job checks the tag against core/Cargo.toml", script ~= nil and has(script, "core/Cargo.toml"),
      table.concat(vjob, "\n"))
  local bneeds, lneeds = code_line(job("build"), "needs:") or "", code_line(lib, "needs:") or ""
  chk("R9 and the core and library builds wait for it", bneeds:match("needs:.*%f[%w]version%f[^%w]") ~= nil
      and lneeds:match("needs:.*%f[%w]version%f[^%w]") ~= nil, bneeds .. " / " .. lneeds)
  local env_tag = code_line(vjob, "TAG:") or ""
  chk("R9 the check gets the tag from the pushed ref", env_tag:match("TAG:%s*%${{%s*github%.ref_name%s*}}") ~= nil,
      env_tag)
  if script then
    local okc = sh(script, P_BETA, { TAG = BETA_TAG })
    chk("R9 tag v0.5.0-beta.1 with the manifests at 0.5.0-beta.1 passes the check", okc == 0)
    local c2, o2 = sh(script, P_BETA, { TAG = "v0.5.0" })
    chk("R9 tag v0.5.0 with the manifests at 0.5.0-beta.1 fails it, naming both", c2 ~= 0
        and has(o2, "v0.5.0") and has(o2, BETA), o2)
    local c3, o3 = sh(script, P_BETA, { TAG = "v0.5.0-beta.10" })
    chk("R9 so does tag v0.5.0-beta.10: the whole version must match", c3 ~= 0, o3)
    local P2 = plugin("tag-lib", BETA)
    write_file(P2 .. "/core/native/Cargo.toml", manifest("libjupynvim", "0.4.6"))
    local c4, o4 = sh(script, P2, { TAG = BETA_TAG })
    chk("R9 and a library manifest at another version fails it", c4 ~= 0 and has(o4, "0.4.6"), o4)
  end
end)

vim.notify = real_notify
vim.fn.stdpath = real_stdpath
vim.fn.delete(tmp, "rf")

if fails == 0 then
  io.write("\nALL RELEASE VERSION CHECKS PASSED\n")
  vim.cmd("qa!")
else
  io.write(("\nRELEASE VERSION: %d CHECK(S) FAILED\n"):format(fails))
  vim.cmd("cquit 1")
end

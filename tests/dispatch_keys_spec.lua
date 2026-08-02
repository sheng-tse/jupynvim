-- Regression test for issue #24: jupynvim took <leader>e, <leader>ff, <C-/> and
-- friends GLOBALLY at startup, so every buffer of every filetype showed
-- "jupynvim:" in which-key even if you never opened a notebook, and <leader>e
-- silently stopped being your explorer.
--
-- The contract now:
--   you already had a mapping -> we take the key only while an SSH session is
--                                active, and give yours back untouched after
--   you had none              -> nothing to clobber, we keep it bound
--   terminal_right_keys       -> always session-only, it has no local behavior
--
-- No SSH needed: remote_active() keys off _active_alias + clients[a].job, so a
-- fake client entry is enough to simulate a session.

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local fails = 0
local function chk(name, cond, detail)
  if cond then
    io.write("  ok " .. name .. "\n")
  else
    io.write("FAIL " .. name .. (detail and ("  -- " .. detail) or "") .. "\n")
    fails = fails + 1
  end
end

local J = require("jupynvim")

-- Distinctive keys so we never fight whatever the host nvim has bound.
local MINE      = "<leader>Zmine"   -- user already has a mapping here
local UNCLAIMED = "<leader>Zfree"   -- user has nothing here
local CWD       = "<leader>Zcwd"    -- the cwd explorer variant
local TERMR     = "<leader>Zterm"   -- terminal_right: session-only regardless

J.setup({
  explorer_keys       = { MINE, UNCLAIMED },
  explorer_cwd_keys   = { CWD },
  terminal_right_keys = { TERMR },
  terminal_keys       = {},
  pick_keys           = { files = {}, grep = {} },
})

-- The user's own mapping, created AFTER setup's first pass, exactly like a
-- distro binding on VeryLazy after jupynvim's immediate pass.
_G.__dispatch_sentinel = 0
vim.keymap.set("n", MINE, function() _G.__dispatch_sentinel = 99 end,
  { desc = "MY OWN EXPLORER" })

local function desc_of(lhs, mode)
  local m = vim.fn.maparg(lhs, mode or "n", false, true)
  return m and m.desc or nil
end
local function is_mapped(lhs, mode)
  local m = vim.fn.maparg(lhs, mode or "n", false, true)
  return m ~= nil and not vim.tbl_isempty(m)
end
-- Ownership is deliberately NOT a desc prefix match any more (the descriptions
-- are user-visible and get reworded), so the spec recognises ours by the set of
-- names jupynvim actually installs.
local OURS = {
  ["Remote Explorer (project root)"] = true,
  ["Remote Explorer (cwd)"] = true,
  ["Remote Terminal (bottom)"]       = true,
  ["Remote Terminal (right)"]        = true,
  ["Remote Find Files"]              = true,
  ["Remote Grep"]                    = true,
}
local function is_jupynvim(lhs, mode)
  return OURS[desc_of(lhs, mode)] == true
end

-- The VeryLazy pass: this is where the mode for each key gets decided.
J._dispatch_bind()

-- ── disconnected: your keys must be untouched ────────────────────────────
chk("your mapping survives the bind pass", desc_of(MINE) == "MY OWN EXPLORER",
    "desc is " .. tostring(desc_of(MINE)))
chk("your key is NOT jupynvim's while disconnected", not is_jupynvim(MINE))
chk("an unclaimed key IS bound (nothing to clobber)", is_jupynvim(UNCLAIMED),
    "desc is " .. tostring(desc_of(UNCLAIMED)))
chk("terminal_right is NOT bound while disconnected", not is_mapped(TERMR),
    "desc is " .. tostring(desc_of(TERMR)))

-- ── connect (faked): we take the key ─────────────────────────────────────
J.clients["faketest"] = { job = 1 }
J._set_active_alias("faketest")
chk("remote_active() true with the fake session", J.remote_active())
chk("your key becomes jupynvim's while connected", is_jupynvim(MINE),
    "desc is " .. tostring(desc_of(MINE)))
chk("terminal_right appears while connected", is_jupynvim(TERMR),
    "desc is " .. tostring(desc_of(TERMR)))
chk("the unclaimed key stays ours", is_jupynvim(UNCLAIMED))

-- ── disconnect: give it back, byte for byte ──────────────────────────────
J._set_active_alias(nil)
J.clients["faketest"] = nil
chk("your desc is restored exactly", desc_of(MINE) == "MY OWN EXPLORER",
    "desc is " .. tostring(desc_of(MINE)))
chk("terminal_right is gone again", not is_mapped(TERMR))
chk("the unclaimed key is still ours", is_jupynvim(UNCLAIMED))

-- the restored mapping must be YOUR function, not an equivalent-looking one
_G.__dispatch_sentinel = 0
local restored = vim.fn.maparg(MINE, "n", false, true)
if restored and restored.callback then pcall(restored.callback) end
chk("restored mapping calls YOUR original function",
    _G.__dispatch_sentinel == 99, "sentinel = " .. tostring(_G.__dispatch_sentinel))

-- ── a second connect/disconnect cycle must not degrade ───────────────────
J.clients["faketest"] = { job = 1 }
J._set_active_alias("faketest")
chk("second connect takes the key again", is_jupynvim(MINE))
J._set_active_alias(nil)
J.clients["faketest"] = nil
chk("second disconnect restores again", desc_of(MINE) == "MY OWN EXPLORER",
    "desc is " .. tostring(desc_of(MINE)))

-- ── the two explorer keys must be genuinely different things ─────────────
-- Before the split, <leader>e and <leader>E both called M.explorer(), so once
-- you connected they were indistinguishable and their descriptions matched.
J.clients["faketest"] = { job = 1 }
J._set_active_alias("faketest")
local d_root, d_cwd = desc_of(UNCLAIMED), desc_of(CWD)
chk("project-root and cwd explorers have different names",
    d_root ~= d_cwd, ("both say %q"):format(tostring(d_root)))
chk("project-root explorer named for what it does",
    d_root == "Remote Explorer (project root)", tostring(d_root))
chk("cwd explorer named for what it does",
    d_cwd == "Remote Explorer (cwd)", tostring(d_cwd))
local cb_root = vim.fn.maparg(UNCLAIMED, "n", false, true).callback
local cb_cwd  = vim.fn.maparg(CWD, "n", false, true).callback
chk("they are not the same callback", cb_root ~= nil and cb_root ~= cb_cwd)
chk("no description still says 'remote when SSH-connected'",
    not (tostring(d_root) .. tostring(d_cwd)):find("remote when SSH%-connected"))
J._set_active_alias(nil)
J.clients["faketest"] = nil

-- ── the remote cwd must survive a <leader>e project-root jump ────────────
-- <leader>e re-roots the tree at the project root of the file you are in. The
-- first cut of this resolved <leader>E's target as the tree's current root, so
-- one press of e overwrote the cd and you could never get back. Verified
-- against psc: cd to /ocean/..., open a file under /jet/home/.../src/jupynvim,
-- press e then E, and both landed on the repo instead of the ocean path.
local CD = "/ocean/projects/testalloc/me"
J._session_cwd = {}
J._note_session_cwd("faketest", CD)
chk("an explicit cd sets the remote cwd", J._session_cwd["faketest"] == CD,
    tostring(J._session_cwd["faketest"]))
-- the project-root jump re-roots the tree; it must NOT touch the cd
J._note_session_cwd("faketest", nil)
chk("cwd survives a nil write (the e path records nothing)",
    J._session_cwd["faketest"] == CD, tostring(J._session_cwd["faketest"]))
-- and the tree moving underneath it must not matter either
pcall(function() require("jupynvim.remote_explorer").reset("faketest") end)
chk("cwd is independent of where the tree is rooted",
    J._session_cwd["faketest"] == CD, tostring(J._session_cwd["faketest"]))
-- browsing the tree (backspace / `-` / `.`) is NAVIGATION, not a cd. it must
-- leave the working directory alone, otherwise going up one level and pressing
-- <leader>e no longer brings you back to where :JupynvimRemoteCd put you.
pcall(function()
  require("jupynvim.remote_explorer").set_root("faketest", "/tmp/elsewhere")
end)
chk("browsing the tree does NOT move the working dir",
    J._session_cwd["faketest"] == CD, tostring(J._session_cwd["faketest"]))
J._session_cwd = {}

-- ── renaming a description must not break ownership tracking ─────────────
-- Ownership keys off callback identity. If it matched on the desc text, the
-- rename above would make us read our own mapping as YOURS and capture it,
-- destroying the original. Simulate that by rewriting our desc in place.
J.clients["faketest"] = { job = 1 }
J._set_active_alias("faketest")
local ours = vim.fn.maparg(MINE, "n", false, true)
vim.keymap.set("n", MINE, ours.callback, { desc = "TOTALLY DIFFERENT NAME" })
J._dispatch_bind()
J._set_active_alias(nil)
J.clients["faketest"] = nil
chk("a reworded description does not cost you your mapping",
    desc_of(MINE) == "MY OWN EXPLORER", "desc is " .. tostring(desc_of(MINE)))

-- ── a later bind pass must not capture OUR map as if it were yours ───────
J.clients["faketest"] = { job = 1 }
J._set_active_alias("faketest")
J._dispatch_bind()          -- the +500ms pass, fired while connected
J._set_active_alias(nil)
J.clients["faketest"] = nil
chk("a bind pass while connected does not swallow your mapping",
    desc_of(MINE) == "MY OWN EXPLORER", "desc is " .. tostring(desc_of(MINE)))

if fails == 0 then
  io.write("\nALL DISPATCH-KEY CHECKS PASSED\n")
else
  io.write(("\nDISPATCH-KEYS: %d CHECK(S) FAILED\n"):format(fails))
  vim.cmd("cquit 1")
end

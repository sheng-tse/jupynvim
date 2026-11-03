#!/usr/bin/env bash
# The palette and the terminal's own background on a real screen: what the
# questions it asks do to the user's 'background', and a terminal that changes
# its color without telling.
#
# Neovim runs in a tmux pane (a private server, tests/lib/tmux.sh). tmux
# answers an OSC 11 query from the window-style of the pane, so the pane's
# background is the terminal's background and the test chooses it; and tmux
# sends no report when that changes (no DEC mode 2031), like any terminal
# chain without theme reports.
#
# Neovim's own handler (augroup nvim.tty) sets 'background' from every OSC 11
# answer, and keeps doing so for the session unless 'background' was set from
# a startup file, when it takes itself away at VimEnter. The palette must not
# make it move a 'background' the user chose:
#
#   start-up   the config sets background=light in a dark terminal, loads a
#              colorscheme and sets jupynvim up; then something runs the event
#              loop before VimEnter, as jupynvim's own open of a remote file
#              given on the command line does (a BufReadCmd that waits), or
#              as a plain vim.wait later in init.lua does. With an opaque
#              colorscheme and with a transparent one: 'background' is still
#              light 1.5 s after VimEnter, the colorscheme was sourced once,
#              and the palette asked nothing (opaque) or asked once, at
#              VimEnter, after Neovim's handler was gone (transparent).
#   late       jupynvim is set up after the user changed 'background' in the
#              session (a plugin manager that loads it on first use), Neovim's
#              handler still there: the same, nothing is moved.
#   stale      the terminal turns light without a report and the user then
#              sets 'background': the palette asks again, learns the new
#              canvas, and the text, comment and fill read on it. With
#              Neovim's handler alive and with it gone.
#   afterenter the question sent at VimEnter must not undo a 'background'
#              set right after VimEnter, with a transparent colorscheme in a
#              dark terminal: a VimEnter autocmd made after jupynvim's, a
#              vim.schedule in the config, a colorscheme loaded from a nested
#              VimEnter or from a scheduled UIEnter that sets 'background'
#              itself (a light one). Neovim's handler is still alive then.
#   lightterm  nothing set, a light terminal: Neovim's own detection must
#              still give light (Neovim 0.11 reads its start-up answer only
#              after VimEnter, behind the palette's question).
#   probe      the truecolor probe Neovim starts with (ssh, tmux, no
#              COLORTERM) is not touched by the questions: one TermResponse
#              autocmd is left in nvim.tty a few seconds in, not two.
#   ooo        a terminal chain that answers the DSR before the OSC 11 question
#              (tests/lib/reorder_pty.py holds the OSC 11 answers back 60 ms):
#              the answer that follows the DSR is still the palette's, and
#              must not undo a 'background' the user set. (Neovim 0.12; 0.11
#              hands over no DSR answer.)
#   waitbg     the user's 'background' set from a timer inside a vim.wait of
#              3 s (the shape of jupynvim's own blocking calls): the question
#              the palette asks then must reach the terminal at once and not
#              at the end of the wait (Neovim 0.12 holds what nvim_ui_send is
#              given until the next flush of the screen), or the limit of 1 s
#              ends the window first and the answer undoes the choice.
#   twouis     (Neovim 0.12) a TUI in a dark terminal and a remote UI in a
#              light one: both answer every question, and an answer of the
#              other UI must not undo an explicit 'background'.
#   startmsg   the messages of the start-up that wait for their hit-enter
#              prompt (an error in a plugin file, two lines echoed by the
#              config after setup(), setup() from a VimEnter autocmd) are on
#              the screen with the prompt, with a transparent colorscheme in
#              a dark terminal: the question asked while Neovim starts must
#              not redraw the screen (a redraw clears them, Neovim 0.12).
#   insession  the same for a first question asked in the session right after
#              three echoed lines, in one command line.
#   intro      the question at VimEnter does not draw the screen before a
#              VimEnter autocmd made after it draws its own (a dashboard): no
#              intro screen reaches the terminal before the dashboard.
#   slowenter  (Neovim 0.12) that question leaves only with Neovim's first
#              screen; a VimEnter autocmd made after it works for 1.5 s
#              (longer than the limit) and then sets 'background' to light,
#              on a link that brings every answer 300 ms late (longer than
#              the grace): the answer is still the palette's, 'background'
#              stays.
#
# The nvim is JNV_PALETTE_NVIM (a path, default nvim on PATH), so the same
# test runs the writer of Neovim 0.11 (io.stdout) and of 0.12 (nvim_ui_send).
#
#   bash tests/palette_terminal_screen.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/tests/lib/tmux.sh"

case "$(uname -s)" in Darwin) EXT=dylib ;; *) EXT=so ;; esac
LIB="$ROOT/core/target/release/libjupynvim.$EXT"
if [ ! -f "$LIB" ]; then
  echo "FAIL palette terminal screen: $LIB is not built: cd core && cargo build --release"
  exit 1
fi
NV="${JNV_PALETTE_NVIM:-nvim}"
if ! command -v "$NV" >/dev/null 2>&1; then
  echo "FAIL palette terminal screen: JNV_PALETTE_NVIM ($NV) is not an executable"
  exit 1
fi

# under the run's TMPDIR (macOS mktemp ignores TMPDIR for -t or no template)
WORK="$(mktemp -d "$TMPDIR/jnv_palette_term.XXXXXX")"
S=""
# the server first, so no nvim is left to write into WORK as it goes
cleanup() { jnv_tmux_stop; rm -rf "$WORK"; }
jnv_on_exit cleanup

FAILS=0
ok() { echo "ok $1"; }
bad() { echo "FAIL $1"; FAILS=$((FAILS + 1)); }
# run_py_checks FILE...: a python3 -I script (on stdin) that prints `ok ...`
# and `FAIL ...` lines; they are shown and counted. A script that dies counts.
run_py_checks() {
  local out rc
  out="$(python3 -I - "$@")"; rc=$?
  printf '%s\n' "$out"
  FAILS=$((FAILS + $(printf '%s\n' "$out" | grep -c '^FAIL')))
  if [ "$rc" -ne 0 ] && ! printf '%s\n' "$out" | grep -q '^FAIL'; then
    bad "the checker exited with $rc and no FAIL line"
  fi
}

send() { tmux send-keys -t "=$S:" "$@"; }
# a command line, typed literally (no key names in it), then Enter
cmd() { tmux send-keys -t "=$S:" -l "$1"; tmux send-keys -t "=$S:" Enter; }
cap() { tmux capture-pane -p -t "=$S:"; }
# nv_sync: a barrier. Types :lua __sync(N) and waits until nvim wrote N to
# $DIR/sync, so every key sent before it has been taken (normal mode only).
SYNC=0
nv_sync() {
  SYNC=$((SYNC + 1))
  cmd ":lua __sync($SYNC)"
  jnv_wait_file_eq "$DIR/sync" "$SYNC" 20 || {
    bad "$NAME: nvim did not take a command within 20s"
    return 1
  }
}
screen_note() { echo "-- the screen:"; cap | sed -e 's/[[:space:]]*$//' | head -n 40; }

# The colorschemes, as files on the runtimepath so that Neovim reloads them
# when 'background' is set; each counts its loads.
#   opaquelight  Normal has a background (a light colorscheme)
#   transp       Normal has a foreground and no background (a transparent one)
#   forcelight   transparent, and sets 'background' to light itself (as the
#                light variants of many colorschemes do)
write_colors() {
  mkdir -p "$DIR/colors"
  cat > "$DIR/colors/opaquelight.lua" <<'LUA'
vim.cmd("hi clear")
vim.g.colors_name = "opaquelight"
_G.__loads = _G.__loads or {}
_G.__loads.opaquelight = (_G.__loads.opaquelight or 0) + 1
vim.api.nvim_set_hl(0, "Normal", { fg = "#3760bf", bg = "#e1e2e7" })
LUA
  cat > "$DIR/colors/forcelight.lua" <<'LUA'
vim.cmd("hi clear")
vim.o.background = "light"
vim.g.colors_name = "forcelight"
_G.__loads = _G.__loads or {}
_G.__loads.forcelight = (_G.__loads.forcelight or 0) + 1
vim.api.nvim_set_hl(0, "Normal", { fg = "#3760bf" })
LUA
  cat > "$DIR/colors/transp.lua" <<'LUA'
vim.cmd("hi clear")
vim.g.colors_name = "transp"
_G.__loads = _G.__loads or {}
_G.__loads.transp = (_G.__loads.transp or 0) + 1
vim.api.nvim_set_hl(0, "Normal", { fg = vim.o.background == "light" and "#3760bf" or "#c0caf5" })
LUA
}

# write_init SCHEME PRE POST SETUP: init.lua of the Neovim under test.
#   PRE    Lua before the colorscheme (the user's 'background')
#   SETUP  Lua that sets jupynvim up ("" for a late setup, typed by the test)
#   POST   Lua after it (something that runs the event loop, say)
write_init() {
  local tgc='vim.o.termguicolors = true' intro='vim.opt.shortmess:append("I")'
  [ "${TGC:-1}" = 1 ] || tgc='-- termguicolors is left to Neovim'
  [ "${INTRO:-0}" = 0 ] || intro='-- the intro screen is shown'
  cat > "$DIR/init.lua" <<LUA
vim.opt.runtimepath:prepend("$ROOT")
vim.opt.runtimepath:prepend("$DIR")
$tgc
-- the terminal's answers in the order Neovim saw them: osc (an OSC 11 answer), dsr, other
_G.__tr = {}
vim.api.nvim_create_autocmd("TermResponse", {
  callback = function(ev)
    local s = type(ev.data) == "table" and ev.data.sequence or ev.data
    _G.__tr[#_G.__tr + 1] = (type(s) ~= "string" and "other") or (s:find("\027]11;", 1, true) and "osc")
      or (s == "\027[0n" and "dsr") or "other"
  end,
})
-- when VimEnter ran, for the dumps (how long after it a dump was taken)
vim.api.nvim_create_autocmd("VimEnter", { once = true, callback = function()
  _G.__t_enter = vim.uv.hrtime()
  local f = io.open("$DIR/entered", "w"); f:write("1"); f:close()
end })
-- the ids of the TermResponse autocmds Neovim started with (its handler for the
-- background and, where it exists, the probe for truecolor)
_G.__tty_ids0 = {}
for _, a in ipairs(vim.api.nvim_get_autocmds({ group = "nvim.tty", event = "TermResponse" })) do
  _G.__tty_ids0[#_G.__tty_ids0 + 1] = a.id
end
vim.o.swapfile = false
vim.o.laststatus = 0
$intro
$2
vim.cmd.colorscheme("$1")
$4
$3

-- every real change of 'background', as "old>new"
_G.__bg_log = {}
vim.api.nvim_create_autocmd("OptionSet", {
  pattern = "background",
  callback = function()
    if vim.v.option_old ~= vim.v.option_new then
      _G.__bg_log[#_G.__bg_log + 1] = vim.v.option_old .. ">" .. vim.v.option_new
    end
  end,
})
-- wait (events are read meanwhile) until ms have passed since this nvim started
_G.__t_start = vim.uv.hrtime()
function _G.__wait_since_start(ms)
  local left = ms - (vim.uv.hrtime() - _G.__t_start) / 1e6
  if left > 0 then vim.wait(left) end
end
function _G.__sync(n)
  local f = io.open("$DIR/sync.tmp", "w"); f:write(tostring(n)); f:close()
  os.rename("$DIR/sync.tmp", "$DIR/sync")
end
-- wait (at most ms) for 'background' to become anything but \`want\`: a flip
-- is seen at once, and a 'background' that stays costs the whole wait
function _G.__watch(want, ms)
  vim.wait(ms, function() return vim.o.background ~= want end, 5)
end
-- 'background' and what bears on it, as JSON, through a tmp file and a rename,
-- once the palette is derived for what Neovim and the terminal say now
function _G.__bgdump(path)
  local P = require("jupynvim.palette")
  P.when_ready(function(tokens, info)
    local f = io.open(path .. ".tmp", "w")
    local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false, create = false })
    f:write(vim.json.encode({
      background = vim.o.background,
      colors_name = vim.g.colors_name or vim.NIL,
      since_enter_ms = _G.__t_enter and (vim.uv.hrtime() - _G.__t_enter) / 1e6 or vim.NIL,
      tr = _G.__tr,
      handler = #vim.api.nvim_get_autocmds({ group = "nvim.tty", event = "TermResponse" }),
      tty_ids0 = _G.__tty_ids0 or {},
      tty_now = (function()
        local t = {}
        for _, a in ipairs(vim.api.nvim_get_autocmds({ group = "nvim.tty", event = "TermResponse" })) do
          t[#t + 1] = { a.id, a.desc or vim.NIL }
        end
        return t
      end)(),
      -- Neovim 0.12 gave up waiting for its own start-up answer (a slow start): its
      -- handler then reads that answer after the config, with or without us
      slow_start = vim.fn.execute("messages"):find("E1568", 1, true) ~= nil,
      bg_log = _G.__bg_log,
      loads = _G.__loads or vim.empty_dict(),
      normal_bg = normal.bg or vim.NIL,
      tokens = tokens or vim.NIL,
      info = info,
      stats = P._stats,
    }), "\n")
    f:close()
    os.rename(path .. ".tmp", path)
  end)
end
LUA
}

# begin NAME WINDOW_BG [FILE]: a fresh session whose terminal is WINDOW_BG,
# nvim started with the init.lua (and the file, if given)
begin() {
  NAME="$1"
  DIR="$WORK/$1"
  S="jnv_pt_${1}_$$"
  mkdir -p "$DIR"
  write_colors
  echo "-- $NAME"
  tmux new-session -d -s "$S" -x 160 -y 50
  tmux set-option -t "=$S:" status off
  # the form proven in palette_screen.sh: tmux answers OSC 11 from the pane's window-style
  tmux set-option -w -t "=$S:" window-style "bg=$2"
  send "cd $DIR && ${NVENV:-} $NV -u $DIR/init.lua ${3:-}" Enter
  # NVNOUP: a wrapper around nvim is what the pane runs, so the pane does not say that nvim is up;
  # nvim says it itself, at VimEnter
  if [ -n "${NVNOUP:-}" ]; then
    jnv_wait_file_eq "$DIR/entered" 1 20 || { bad "$NAME: nvim did not start within 20s"; screen_note; return 1; }
  elif ! jnv_wait_nvim_up 20; then
    bad "$NAME: nvim did not start within 20s"
    screen_note
    return 1
  fi
  # NVNOSYNC: no key is sent yet (the pane is read as Neovim left it at start-up)
  [ -n "${NVNOSYNC:-}" ] || nv_sync
}

# finish: quit nvim and stop the session
finish() {
  send Escape
  send ":qa!" Enter
  jnv_wait_nvim_exit 15 || bad "$NAME: nvim did not quit within 15s of :qa!"
  jnv_stop_session "$S" || bad "$NAME: session $S did not stop cleanly (LEAK above)"
}

dump() {
  cmd ":lua __bgdump('$DIR/$1.json')"
  jnv_wait_lines "$DIR/$1.json" 1 15 || { bad "$NAME: the dump $1 never came"; screen_note; return 1; }
}

echo "-- palette terminal screen on $("$NV" --version | head -n 1)"
# y when this Neovim writes the question with nvim_ui_send (0.12), n when to its own stdout (0.11)
HAS_SEND="$("$NV" --headless -u NONE '+lua io.stdout:write(vim.api.nvim_ui_send and "y" or "n")' +qa 2>&1)"

# ── start-up: the user's 'background' stays ───────────────────────────────
# The config sets background=light in a dark terminal; the event loop runs
# before VimEnter. TRIGGER: file (a BufReadCmd that waits, for a file given
# on the command line) or initwait (a vim.wait in init.lua).
startup() {
  local scheme="$1" trigger="$2" post="" file=""
  case "$trigger" in
    file)
      post='vim.api.nvim_create_autocmd("BufReadCmd", { pattern = "*.pt", callback = function() vim.wait(300, function() return false end, 5) end })'
      file="$WORK/startup_${scheme}_${trigger}/x.pt"
      ;;
    initwait) post='vim.wait(300, function() return false end, 5)' ;;
  esac
  local name="startup_${scheme}_${trigger}"
  DIR="$WORK/$name"; mkdir -p "$DIR"
  write_init "$scheme" 'vim.o.background = "light"' "$post" 'require("jupynvim").setup({})'
  [ -n "$file" ] && : > "$file"
  begin "$name" '#222436' "$file" || return 0
  cmd ":lua __watch('light', 1500)"
  nv_sync
  dump r
  run_py_checks "$DIR/r.json" "$scheme" "$trigger" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
scheme, trigger = sys.argv[2], sys.argv[3]
tag = "start-up %s %s" % (scheme, trigger)
def chk(name, cond, detail=""):
    print(("ok " if cond else "FAIL ") + tag + ": " + name + ("" if cond else " (" + str(detail) + ")"))
st, info, tokens = d["stats"], d["info"], d["tokens"] or {}
print("   background %s, colors_name %s, handler %s, bg_log %s, loads %s, queries %s, answers %s, canvas %s from %s" % (
    d["background"], d["colors_name"], d["handler"], d["bg_log"], d["loads"], st["queries"], st["answers"],
    tokens.get("canvas"), info.get("canvas_source")))
chk("'background' is still light 1.5 s after VimEnter", d["background"] == "light", d["background"])
chk("Neovim saw no change of it", d["bg_log"] == [], d["bg_log"])
chk("the colorscheme was sourced once, and is still the colorscheme", d["loads"].get(scheme) == 1
    and d["colors_name"] == scheme, "%s %s" % (d["loads"], d["colors_name"]))
chk("Neovim's own handler is gone (the config set 'background')", d["handler"] == 0, d["handler"])
chk("the palette is ready", info.get("state") == "ok", "%s %s" % (info.get("state"), info.get("reason")))
chk("the kind follows the user's 'background': light", info.get("kind") == "light", info.get("kind"))
if scheme == "opaquelight":
    chk("an opaque Normal: the canvas is Normal's and the terminal was asked nothing",
        tokens.get("canvas") == "#e1e2e7" and info.get("canvas_source") == "Normal.bg" and st["queries"] == 0,
        "%s %s queries %s" % (tokens.get("canvas"), info.get("canvas_source"), st["queries"]))
else:
    # one question at VimEnter; none when Neovim's own question of the start
    # (answered late on Neovim 0.11) already told the canvas
    chk("a transparent Normal: the canvas is the terminal's, learned from at most one question",
        tokens.get("canvas") == "#222436" and info.get("canvas_source") == "terminal" and st["queries"] <= 1
        and st["answers"] >= 1, "%s %s queries %s answers %s" % (tokens.get("canvas"), info.get("canvas_source"),
        st["queries"], st["answers"]))
sys.exit(0)
PY
  finish
}

for scheme in opaquelight transp; do
  for trigger in file initwait; do
    startup "$scheme" "$trigger"
  done
done

# ── late: jupynvim is set up after the user changed 'background' ──────────
# Neovim's handler is still there (the user set nothing in a startup file).
late() {
  local scheme="$1" name="late_$1"
  DIR="$WORK/$name"; mkdir -p "$DIR"
  write_init "$scheme" '' '' ''
  begin "$name" '#222436' || return 0
  cmd ":set background=light"
  cmd ":lua require('jupynvim').setup({})"
  cmd ":lua __watch('light', 1500)"
  nv_sync
  dump r
  run_py_checks "$DIR/r.json" "$scheme" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
scheme = sys.argv[2]
tag = "late %s" % scheme
def chk(name, cond, detail=""):
    print(("ok " if cond else "FAIL ") + tag + ": " + name + ("" if cond else " (" + str(detail) + ")"))
st, info, tokens = d["stats"], d["info"], d["tokens"] or {}
print("   background %s, colors_name %s, handler %s, bg_log %s, loads %s, queries %s, answers %s, canvas %s from %s" % (
    d["background"], d["colors_name"], d["handler"], d["bg_log"], d["loads"], st["queries"], st["answers"],
    tokens.get("canvas"), info.get("canvas_source")))
chk("Neovim's own handler is alive (the precondition)", d["handler"] >= 1, d["handler"])
chk("':set background=light' in a dark terminal is still light 1.5 s after a late setup", d["background"] == "light", d["background"])
chk("Neovim saw the one change and nothing set it back", d["bg_log"] == ["dark>light"], d["bg_log"])
chk("the colorscheme was sourced for each of the two values, no third time, and is still the colorscheme",
    d["loads"].get(scheme) == 2 and d["colors_name"] == scheme, "%s %s" % (d["loads"], d["colors_name"]))
chk("the palette is ready, kind light", info.get("state") == "ok" and info.get("kind") == "light",
    "%s %s" % (info.get("state"), info.get("kind")))
if scheme == "opaquelight":
    chk("an opaque Normal: the terminal was asked nothing", st["queries"] == 0 and info.get("canvas_source") == "Normal.bg",
        "queries %s %s" % (st["queries"], info.get("canvas_source")))
else:
    chk("a transparent Normal: one question, answered, the canvas is the terminal's",
        st["queries"] == 1 and st["answers"] >= 1 and tokens.get("canvas") == "#222436"
        and info.get("canvas_source") == "terminal", "queries %s answers %s %s" % (st["queries"], st["answers"], tokens.get("canvas")))
    chk("Neovim's handler is back after the question", d["handler"] >= 1, d["handler"])
sys.exit(0)
PY
  finish
}

late opaquelight
late transp

# ── stale: the terminal changes without a report ──────────────────────────
# The terminal turns light (tmux sends nothing), then the user sets
# 'background': the palette asks again and learns the canvas.
# MODE: alive (Neovim's handler is there) or gone (the config set 'background').
stale() {
  local mode="$1" name="stale_$1" pre=""
  [ "$mode" = gone ] && pre='vim.o.background = "dark"'
  DIR="$WORK/$name"; mkdir -p "$DIR"
  write_init transp "$pre" '' 'require("jupynvim").setup({})'
  begin "$name" '#222436' || return 0
  # The question at VimEnter takes Neovim's handler away until its answers are in, which on Neovim
  # 0.11 (no DSR answer reaches TermResponse) is 100 ms after the last one: the precondition below
  # is read once that window is over, not in a race with it.
  cmd ":lua __wait_since_start(1000)"
  nv_sync
  dump p1
  # the terminal turns light and tells nobody
  tmux set-option -w -t "=$S:" window-style 'bg=#eff1f5'
  cmd ":set background=light"
  nv_sync
  dump p2
  cmd ":lua __watch('light', 1000)"
  nv_sync
  dump p3
  run_py_checks "$DIR/p1.json" "$DIR/p2.json" "$DIR/p3.json" "$mode" <<'PY'
import json, sys
p1, p2, p3 = (json.load(open(a)) for a in sys.argv[1:4])
mode = sys.argv[4]
tag = "stale %s" % mode
def chk(name, cond, detail=""):
    print(("ok " if cond else "FAIL ") + tag + ": " + name + ("" if cond else " (" + str(detail) + ")"))
def lin(c):
    c /= 255.0
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
def lum(h):
    r, g, b = (int(h[i:i + 2], 16) for i in (1, 3, 5))
    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
def contrast(a, b):
    la, lb = sorted((lum(a), lum(b)), reverse=True)
    return (la + 0.05) / (lb + 0.05)
def oklab_l(h):
    r, g, b = (lin(int(h[i:i + 2], 16)) for i in (1, 3, 5))
    l = (0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b) ** (1 / 3)
    m = (0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b) ** (1 / 3)
    s = (0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b) ** (1 / 3)
    return 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
for tag2, d in (("p1", p1), ("p2", p2), ("p3", p3)):
    t, i, st = d["tokens"] or {}, d["info"], d["stats"]
    print("   %s: background %s, handler %s, bg_log %s, canvas %s (%s) kind %s text %s comment %s fill %s, queries %s answers %s" % (
        tag2, d["background"], d["handler"], d["bg_log"], t.get("canvas"), i.get("canvas_source"), i.get("kind"),
        t.get("text"), t.get("comment"), t.get("fill"), st["queries"], st["answers"]))
want_handler = 1 if mode == "alive" else 0
chk("the precondition is read after the start-up window (at least 500 ms after VimEnter, %s)" % p1["since_enter_ms"],
    p1["since_enter_ms"] is not None and p1["since_enter_ms"] >= 500, p1["since_enter_ms"])
chk("the precondition: the terminal is dark and the canvas is its #222436",
    (p1["tokens"] or {}).get("canvas") == "#222436" and p1["info"].get("canvas_source") == "terminal"
    and p1["background"] == "dark", "%s %s" % ((p1["tokens"] or {}).get("canvas"), p1["background"]))
chk("...Neovim's own handler is %s" % ("alive" if mode == "alive" else "gone"), (p1["handler"] >= 1) == (mode == "alive"), p1["handler"])
t, i, st = p2["tokens"] or {}, p2["info"], p2["stats"]
chk("':set background=light' asks the terminal again: a second question", st["queries"] == 2 and st["answers"] >= 2,
    "queries %s answers %s" % (st["queries"], st["answers"]))
chk("...and the canvas is the terminal's new #eff1f5, from the terminal", t.get("canvas") == "#eff1f5"
    and i.get("canvas_source") == "terminal", "%s %s" % (t.get("canvas"), i.get("canvas_source")))
chk("...the kind is light", i.get("kind") == "light", i.get("kind"))
# the terminal's real background, which tmux answers from its window-style
real = "#eff1f5"
c_text, c_comment = contrast(t.get("text", "#000000"), real), contrast(t.get("comment", "#000000"), real)
chk("...the text reads on the real background (%.2f:1, floor 4.5)" % c_text, c_text >= 4.5, c_text)
chk("...the comment reads on it (%.2f:1, floor 4.5)" % c_comment, c_comment >= 4.5, c_comment)
dl = abs(oklab_l(t.get("fill", "#000000")) - oklab_l(real))
chk("...the fill shows on it (OKLab dL %.4f, floor 0.02)" % dl, dl >= 0.02, dl)
chk("...'background' is the user's light, and nothing set it back", p3["background"] == "light"
    and p3["bg_log"] == ["dark>light"], "%s %s" % (p3["background"], p3["bg_log"]))
chk("...Neovim's handler is as it was (%d)" % want_handler, (p3["handler"] >= 1) == (mode == "alive"), p3["handler"])
chk("...the colorscheme was sourced for each of the two values, no third time", p3["loads"].get("transp") == 2, p3["loads"])
sys.exit(0)
PY
  finish
}

stale alive
stale gone

# ── afterenter: a 'background' set right after VimEnter stays ───────────
# The user's config sets nothing before VimEnter, so Neovim's handler is
# still alive after its own VimEnter check; then, in a dark terminal with a
# transparent colorscheme, 'background' is set to light. The palette's
# question (sent at VimEnter, answered dark) must not undo it.
# TRIGGER: vimenter (a VimEnter autocmd made after jupynvim's), sched (a
# vim.schedule), scheme (a nested VimEnter loads a light colorscheme that sets
# 'background' itself), uienter (a scheduled UIEnter does).
afterenter_run() {
  local trigger="$1" post="" name="after_$1" want_scheme=transp
  case "$trigger" in
    vimenter) post='vim.api.nvim_create_autocmd("VimEnter", { callback = function() vim.o.background = "light" end })' ;;
    sched) post='vim.schedule(function() vim.o.background = "light" end)' ;;
    scheme)
      post='vim.api.nvim_create_autocmd("VimEnter", { nested = true, callback = function() vim.cmd.colorscheme("forcelight") end })'
      want_scheme=forcelight
      ;;
    uienter)
      post='vim.api.nvim_create_autocmd("UIEnter", { nested = true, callback = function() vim.schedule(function() vim.cmd.colorscheme("forcelight") end) end })'
      want_scheme=forcelight
      ;;
  esac
  DIR="$WORK/$name"; mkdir -p "$DIR"
  write_init transp '' "$post" 'require("jupynvim").setup({})'
  begin "$name" '#222436' || return 1
  cmd ":lua __watch('light', 1500)"
  nv_sync
  dump r
  AFTER_SLOW=False
  [ -f "$DIR/r.json" ] && AFTER_SLOW="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["slow_start"])' "$DIR/r.json")"
  return 0
}
afterenter() {
  local trigger="$1" try
  for try in 1 2 3; do
    afterenter_run "$trigger" || return 0
    # Neovim 0.12 that gave up waiting for its own start-up answer reads it
    # after the config, with or without jupynvim (the control flips the same):
    # not a result, start again
    if [ "$AFTER_SLOW" = True ] && [ "$try" -lt 3 ]; then
      echo "-- $NAME: Neovim's own start-up answer was late (E1568), again"
      finish
      continue
    fi
    break
  done
  local scheme=transp
  case "$trigger" in scheme|uienter) scheme=forcelight ;; esac
  run_py_checks "$DIR/r.json" "$trigger" "$scheme" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
trigger, scheme = sys.argv[2], sys.argv[3]
tag = "afterenter %s" % trigger
def chk(name, cond, detail=""):
    print(("ok " if cond else "FAIL ") + tag + ": " + name + ("" if cond else " (" + str(detail) + ")"))
st, info, tokens = d["stats"], d["info"], d["tokens"] or {}
print("   background %s, colors_name %s, handler %s, bg_log %s, loads %s, queries %s, answers %s, canvas %s from %s, slow start %s" % (
    d["background"], d["colors_name"], d["handler"], d["bg_log"], d["loads"], st["queries"], st["answers"],
    tokens.get("canvas"), info.get("canvas_source"), d["slow_start"]))
chk("Neovim's own handler is alive (the precondition: nothing set 'background' before VimEnter's check)",
    d["handler"] >= 1, d["handler"])
chk("'background' is light 1.5 s after VimEnter", d["background"] == "light", d["background"])
chk("Neovim never set it back to dark", "light>dark" not in d["bg_log"], d["bg_log"])
chk("the colorscheme is still %s" % scheme, d["colors_name"] == scheme, d["colors_name"])
if scheme == "forcelight":
    chk("...sourced once, and the transparent one before it once", d["loads"].get("forcelight") == 1
        and d["loads"].get("transp") == 1, d["loads"])
else:
    chk("...sourced for each of the two values, no third time", d["loads"].get("transp") == 2, d["loads"])
chk("the palette asked the terminal, once, and is ready", st["queries"] >= 1 and info.get("state") == "ok",
    "%s %s" % (st["queries"], info.get("state")))
chk("...the canvas is the terminal's #222436, the kind is light (the user's choice, not the terminal's)",
    tokens.get("canvas") == "#222436" and info.get("canvas_source") == "terminal" and info.get("kind") == "light",
    "%s %s %s" % (tokens.get("canvas"), info.get("canvas_source"), info.get("kind")))
sys.exit(0)
PY
  finish
}

for trigger in vimenter sched scheme uienter; do
  afterenter "$trigger"
done

# ── lightterm: Neovim's own detection of a light terminal ──────────────
# Nothing set, a light terminal. Neovim 0.11 reads the answer to its own
# start-up question after VimEnter, behind the palette's question: the
# palette must hand it that answer, or 'background' stays dark.
lightterm() {
  local name="lightterm"
  DIR="$WORK/$name"; mkdir -p "$DIR"
  write_init transp '' '' 'require("jupynvim").setup({})'
  begin "$name" '#eff1f5' || return 0
  cmd ":lua __watch('dark', 1500)"
  nv_sync
  dump r
  run_py_checks "$DIR/r.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
tag = "lightterm"
def chk(name, cond, detail=""):
    print(("ok " if cond else "FAIL ") + tag + ": " + name + ("" if cond else " (" + str(detail) + ")"))
st, info, tokens = d["stats"], d["info"], d["tokens"] or {}
print("   background %s, colors_name %s, handler %s, bg_log %s, loads %s, queries %s, answers %s, canvas %s from %s" % (
    d["background"], d["colors_name"], d["handler"], d["bg_log"], d["loads"], st["queries"], st["answers"],
    tokens.get("canvas"), info.get("canvas_source")))
chk("Neovim detected the light terminal: 'background' is light", d["background"] == "light", d["background"])
chk("...and the colorscheme is still the colorscheme (Neovim 0.11 reloaded it for the new value)", d["colors_name"] == "transp"
    and d["loads"].get("transp") in (1, 2), "%s %s" % (d["colors_name"], d["loads"]))
chk("...Neovim's handler is alive again", d["handler"] >= 1, d["handler"])
chk("the palette is ready on the terminal's #eff1f5, kind light", tokens.get("canvas") == "#eff1f5"
    and info.get("canvas_source") == "terminal" and info.get("kind") == "light" and info.get("state") == "ok",
    "%s %s %s %s" % (tokens.get("canvas"), info.get("canvas_source"), info.get("kind"), info.get("state")))
sys.exit(0)
PY
  finish
}
lightterm

# ── probe: Neovim's truecolor probe is left alone ──────────────────────
# Without COLORTERM (ssh, a tmux with no RGB) Neovim keeps a TermResponse
# autocmd of its own for the first second to find out about truecolor, and
# removes it by its id. A question of ours in that second must not take it
# and put it back under another id: it would stay for the session.
probe() {
  local name="probe"
  DIR="$WORK/$name"; mkdir -p "$DIR"
  TGC=0 write_init transp '' 'vim.defer_fn(function() vim.o.background = "light" end, 150)' 'require("jupynvim").setup({})'
  NVENV='env -u COLORTERM TERM=screen-256color' begin "$name" '#222436' || return 0
  cmd ":lua __wait_since_start(3000)"
  nv_sync
  dump r
  run_py_checks "$DIR/r.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
tag = "probe"
def chk(name, cond, detail=""):
    print(("ok " if cond else "FAIL ") + tag + ": " + name + ("" if cond else " (" + str(detail) + ")"))
st = d["stats"]
is_bg = lambda a: isinstance(a[1], str) and a[1].startswith("Update the value of 'background'")
others = [a for a in d["tty_now"] if not is_bg(a)]
print("   background %s, queries %s, answers %s, autocmd ids at start %s, now %s" % (
    d["background"], st["queries"], st["answers"], d["tty_ids0"], d["tty_now"]))
chk("the precondition: Neovim started with its handler and the truecolor probe (two autocmds)", len(d["tty_ids0"]) == 2, d["tty_ids0"])
chk("the palette asked the terminal again after the change inside that second", st["queries"] >= 2, st["queries"])
chk("'background' is the user's light", d["background"] == "light", d["background"])
chk("Neovim's handler for the background is back, once", sum(1 for a in d["tty_now"] if is_bg(a)) == 1, d["tty_now"])
chk("the probe is gone, or still the one Neovim made (never a copy under another id, which Neovim could not remove)",
    all(a[0] in d["tty_ids0"] for a in others), others)
sys.exit(0)
PY
  finish
}
probe

# ── ooo: the DSR answer comes before the OSC 11 answer ─────────────────
# Neovim's own handler allows for a terminal chain that answers out of order,
# and so does the palette: a DSR answer with no OSC 11 answer before it makes
# the canvas fall back at once, but the window stays open a moment for the
# OSC 11 answer, which is the palette's when it comes. Here every OSC 11
# answer is held back 60 ms (the palette keeps the window open for 100) by a
# pty between tmux and Neovim. The user sets 'background' to light in a dark
# terminal after start-up.
ooo() {
  local name="ooo"
  DIR="$WORK/$name"; mkdir -p "$DIR"
  write_init transp '' '' 'require("jupynvim").setup({})'
  NVENV="python3 -I $ROOT/tests/lib/reorder_pty.py 60 --" NVNOUP=1 begin "$name" '#222436' || return 0
  cmd ":lua __wait_since_start(1000)"
  nv_sync
  # the answers seen from here on are those to the question the change asks
  cmd ":lua _G.__tr = {}"
  nv_sync
  cmd ":set background=light"
  cmd ":lua __watch('light', 1500)"
  nv_sync
  dump r
  run_py_checks "$DIR/r.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
tag = "ooo"
def chk(name, cond, detail=""):
    print(("ok " if cond else "FAIL ") + tag + ": " + name + ("" if cond else " (" + str(detail) + ")"))
st, info, tokens = d["stats"], d["info"], d["tokens"] or {}
print("   background %s, colors_name %s, handler %s, bg_log %s, loads %s, queries %s, answers %s, canvas %s from %s, answers seen %s" % (
    d["background"], d["colors_name"], d["handler"], d["bg_log"], d["loads"], st["queries"], st["answers"],
    tokens.get("canvas"), info.get("canvas_source"), d["tr"]))
tr = d["tr"]
if "dsr" in tr:
    # Neovim 0.12 hands the DSR answers over: with the OSC 11 answers held back, a DSR comes before the first one
    chk("the precondition: the DSR answer came before the OSC 11 answer to the question the change asked (the chain answers out of order)",
        "osc" in tr and tr.index("dsr") < tr.index("osc"), tr)
else:
    print("ok ooo: this Neovim hands over no DSR answer, so there is no order to change (the rest is still checked)")
chk("Neovim's own handler is alive again", d["handler"] >= 1, d["handler"])
chk("the palette asked again when 'background' changed", st["queries"] >= 2, st["queries"])
chk("'background' is the user's light 1.5 s after", d["background"] == "light", d["background"])
chk("Neovim saw the one change and never set it back", d["bg_log"] == ["dark>light"], d["bg_log"])
chk("the colorscheme was sourced for each of the two values, no third time, and is still the colorscheme",
    d["loads"].get("transp") == 2 and d["colors_name"] == "transp", "%s %s" % (d["loads"], d["colors_name"]))
chk("the canvas is the terminal's #222436 (the answer after the DSR was read), kind light",
    tokens.get("canvas") == "#222436" and info.get("canvas_source") == "terminal" and info.get("kind") == "light"
    and info.get("state") == "ok", "%s %s %s %s" % (tokens.get("canvas"), info.get("canvas_source"), info.get("kind"), info.get("state")))
sys.exit(0)
PY
  finish
}
ooo

# ── waitbg: a 'background' set inside a long vim.wait ─────────────────
# jupynvim's own blocking calls (open, save, the read of a remote file) run
# vim.wait for seconds, and a timer that fires inside one can set 'background'.
# The question the palette asks then (the limit is 1 s, the wait 3 s) must be
# written at once: held until the wait ends, the limit would have ended the
# window and put Neovim's handler back, and the answer, read right after the
# wait, would set 'background' from the terminal.
waitbg() {
  local name="waitbg"
  DIR="$WORK/$name"; mkdir -p "$DIR"
  local post
  post='vim.api.nvim_create_autocmd("VimEnter", { callback = function()
  vim.defer_fn(function()
    vim.wait(3000, function() return false end)
    local f = io.open("'"$DIR"'/waitdone.tmp", "w"); f:write("1"); f:close()
    os.rename("'"$DIR"'/waitdone.tmp", "'"$DIR"'/waitdone")
  end, 800)
  vim.defer_fn(function() vim.o.background = "light" end, 1100)
end })'
  write_init transp '' "$post" 'require("jupynvim").setup({})'
  begin "$name" '#222436' || return 0
  if ! jnv_wait_file_eq "$DIR/waitdone" 1 30; then
    bad "$NAME: the long wait never ended"
    screen_note
  fi
  cmd ":lua __watch('light', 1500)"
  nv_sync
  dump r
  run_py_checks "$DIR/r.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
tag = "waitbg"
def chk(name, cond, detail=""):
    print(("ok " if cond else "FAIL ") + tag + ": " + name + ("" if cond else " (" + str(detail) + ")"))
st, info, tokens = d["stats"], d["info"], d["tokens"] or {}
print("   background %s, colors_name %s, handler %s, bg_log %s, loads %s, queries %s, answers %s, canvas %s from %s" % (
    d["background"], d["colors_name"], d["handler"], d["bg_log"], d["loads"], st["queries"], st["answers"],
    tokens.get("canvas"), info.get("canvas_source")))
chk("Neovim's own handler is alive again (the precondition: nothing set 'background' before VimEnter's check)",
    d["handler"] >= 1, d["handler"])
chk("the user's light is still light after the wait and 1.5 s more", d["background"] == "light", d["background"])
chk("Neovim saw the one change and never set it back", d["bg_log"] == ["dark>light"], d["bg_log"])
chk("the colorscheme was sourced for each of the two values, no third time, and is still the colorscheme",
    d["loads"].get("transp") == 2 and d["colors_name"] == "transp", "%s %s" % (d["loads"], d["colors_name"]))
chk("the palette asked again for the change (inside the wait) and is ready on the terminal's #222436, kind light",
    st["queries"] >= 2 and tokens.get("canvas") == "#222436" and info.get("canvas_source") == "terminal"
    and info.get("kind") == "light" and info.get("state") == "ok",
    "queries %s %s %s %s %s" % (st["queries"], tokens.get("canvas"), info.get("canvas_source"), info.get("kind"), info.get("state")))
sys.exit(0)
PY
  finish
}
waitbg

# ── startmsg: the messages of the start-up stay ──────────────────────
# Neovim shows the messages of the start-up that scrolled the screen (more
# than one line) with a hit-enter prompt, from its main loop, after VimEnter.
# A redraw before that (the flush the palette makes after a question, see
# palette.lua flush_ui) clears them and drops the prompt, so the question
# asked while Neovim starts is written without it. MODE: plugin (an error in a
# plugin file), echo (two lines echoed by init.lua after setup()), vimenter
# (setup() from a VimEnter autocmd, the same two lines). The pane is read
# before any key is sent.
# pane_has TEXT: the pane shows TEXT
pane_has() { cap | grep -qF -- "$1"; }
startmsg() {
  local mode="$1" name="startmsg_$1" setup='require("jupynvim").setup({})' post="" want
  DIR="$WORK/$name"; mkdir -p "$DIR"
  case "$mode" in
    plugin)
      mkdir -p "$DIR/plugin"
      echo 'error("STARTMSG a plugin file failed")' > "$DIR/plugin/bad.lua"
      want="STARTMSG a plugin file failed" ;;
    echo)
      post='vim.api.nvim_echo({ { "STARTMSG one\nSTARTMSG two" } }, true, {})'
      want="STARTMSG two" ;;
    vimenter)
      post='vim.api.nvim_echo({ { "STARTMSG one\nSTARTMSG two" } }, true, {})
vim.api.nvim_create_autocmd("VimEnter", { callback = function() require("jupynvim").setup({}) end })'
      setup=''
      want="STARTMSG two" ;;
  esac
  write_init transp '' "$post" "$setup"
  NVNOSYNC=1 begin "$name" '#222436' || return 0
  if ! jnv_wait_file_eq "$DIR/entered" 1 20; then
    bad "$NAME: VimEnter never came"
    screen_note
    finish
    return 0
  fi
  # the prompt comes from the main loop, right after VimEnter; nothing runs while it is up
  if _jnv_poll 10 pane_has "Press ENTER"; then
    ok "$NAME: the hit-enter prompt of the start-up is on the screen"
  else
    bad "$NAME: the hit-enter prompt of the start-up is on the screen"
    screen_note
  fi
  if pane_has "$want" && pane_has "Press ENTER"; then
    ok "$NAME: ...with the message it is for ($want)"
  else
    bad "$NAME: ...with the message it is for ($want)"
    screen_note
  fi
  send Enter
  nv_sync || { finish; return 0; }
  # the answers were read after the prompt: the window ends a moment later (on Neovim 0.11, with no DSR
  # answer, the grace after the last answer), and Neovim's handler is back from then
  cmd ':lua vim.wait(1500, function() return #vim.api.nvim_get_autocmds({ group = "nvim.tty", event = "TermResponse" }) > 0 end, 5)'
  nv_sync || { finish; return 0; }
  dump r
  run_py_checks "$DIR/r.json" "$NAME" "$HAS_SEND" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
tag = sys.argv[2]
has_send = sys.argv[3] == "y"
def chk(name, cond, detail=""):
    print(("ok " if cond else "FAIL ") + tag + ": " + name + ("" if cond else " (" + str(detail) + ")"))
st, info, tokens = d["stats"], d["info"], d["tokens"] or {}
print("   background %s, bg_log %s, loads %s, handler %s, queries %s, held %s, answers %s, canvas %s from %s" % (
    d["background"], d["bg_log"], d["loads"], d["handler"], st["queries"], st.get("held"), st["answers"],
    tokens.get("canvas"), info.get("canvas_source")))
chk("the palette asked once and is ready on the terminal's #222436", st["queries"] == 1 and tokens.get("canvas") == "#222436"
    and info.get("canvas_source") == "terminal" and info.get("state") == "ok",
    "queries %s %s %s %s" % (st["queries"], tokens.get("canvas"), info.get("canvas_source"), info.get("state")))
if has_send:
    chk("the question was written without the flush (held: Neovim was starting)", st.get("held") == 1, st.get("held"))
else:
    chk("this Neovim's writer is its own stdout, never held", st.get("held") == 0, st.get("held"))
chk("'background' is Neovim's dark, never moved, the colorscheme sourced once", d["background"] == "dark"
    and d["bg_log"] == [] and d["loads"].get("transp") == 1, "%s %s %s" % (d["background"], d["bg_log"], d["loads"]))
chk("Neovim's own handler is alive again, 1.5 s after the prompt at the most", d["handler"] >= 1, d["handler"])
sys.exit(0)
PY
  finish
}
startmsg plugin
startmsg echo
startmsg vimenter

# ── insession: messages in the session stay too ──────────────────────
# An opaque colorscheme at start-up (nothing asked), then a transparent one,
# then, in one command line, three echoed lines and a consumer's first get():
# its question is asked while the messages wait for their prompt.
insession() {
  local name="insession"
  DIR="$WORK/$name"; mkdir -p "$DIR"
  write_init opaquelight '' '' 'require("jupynvim").setup({})'
  begin "$name" '#222436' || return 0
  cmd ":colorscheme transp"
  nv_sync || { finish; return 0; }
  cmd ':echo "INSESSION one\nINSESSION two\nINSESSION three" | lua require("jupynvim.palette").get()'
  if _jnv_poll 10 pane_has "Press ENTER"; then
    ok "$NAME: the hit-enter prompt of the three lines is on the screen"
  else
    bad "$NAME: the hit-enter prompt of the three lines is on the screen"
    screen_note
  fi
  if pane_has "INSESSION one" && pane_has "INSESSION three" && pane_has "Press ENTER"; then
    ok "$NAME: ...with the three lines"
  else
    bad "$NAME: ...with the three lines"
    screen_note
  fi
  send Enter
  nv_sync || { finish; return 0; }
  dump r
  run_py_checks "$DIR/r.json" "$HAS_SEND" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
tag = "insession"
has_send = sys.argv[2] == "y"
def chk(name, cond, detail=""):
    print(("ok " if cond else "FAIL ") + tag + ": " + name + ("" if cond else " (" + str(detail) + ")"))
st, info, tokens = d["stats"], d["info"], d["tokens"] or {}
print("   background %s, bg_log %s, loads %s, handler %s, queries %s, held %s, answers %s, canvas %s from %s" % (
    d["background"], d["bg_log"], d["loads"], d["handler"], st["queries"], st.get("held"), st["answers"],
    tokens.get("canvas"), info.get("canvas_source")))
chk("the palette is ready on the terminal's #222436", tokens.get("canvas") == "#222436"
    and info.get("canvas_source") == "terminal" and info.get("state") == "ok",
    "%s %s %s" % (tokens.get("canvas"), info.get("canvas_source"), info.get("state")))
if has_send:
    # Neovim 0.12 reads its own start-up answer before the config, so the palette did not know the terminal
    chk("the get() asked, and its question was held (the messages waited for their prompt)",
        st["queries"] == 1 and st.get("held") == 1, "queries %s held %s" % (st["queries"], st.get("held")))
else:
    print("ok insession: this Neovim reads its own start-up answer after the config (the palette took it), so the get() needs no question")
chk("Neovim's own handler is alive again", d["handler"] >= 1, d["handler"])
sys.exit(0)
PY
  finish
}
insession

# ── intro: no early screen under a dashboard ─────────────────────────
# The intro screen is on (no 'shortmess' I), and a VimEnter autocmd made after
# setup() fills the buffer (a dashboard). Without the palette the first screen
# is the dashboard; the question at VimEnter must not draw one before it.
# What nvim writes is logged by tests/lib/reorder_pty.py (DELAY_MS 0: nothing
# is reordered). MODE: dashboard (setup() in init.lua), vimenter (setup() from a
# VimEnter autocmd made before the dashboard's: its question is asked then),
# control (no dashboard: the intro is drawn, so the log can see it).
intro() {
  local mode="$1" name="intro_$1" post="" setup='require("jupynvim").setup({})'
  local dash='vim.api.nvim_create_autocmd("VimEnter", { callback = function()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "DASHBOARD", "", "  [f] find a file", "  [q] quit" })
end })'
  DIR="$WORK/$name"; mkdir -p "$DIR"
  case "$mode" in
    dashboard) post="$dash" ;;
    vimenter)
      post='vim.api.nvim_create_autocmd("VimEnter", { callback = function() require("jupynvim").setup({}) end })'"
$dash"
      setup='' ;;
  esac
  INTRO=1 write_init transp '' "$post" "$setup"
  NVENV="python3 -I $ROOT/tests/lib/reorder_pty.py 0 --out $DIR/wire.log --" NVNOUP=1 begin "$name" '#222436' || return 0
  cmd ":lua __wait_since_start(1500)"
  nv_sync || { finish; return 0; }
  dump r
  run_py_checks "$DIR/wire.log" "$DIR/r.json" "$mode" <<'PY'
import json, sys
wire = open(sys.argv[1], "rb").read()
d = json.load(open(sys.argv[2]))
mode = sys.argv[3]
tag = "intro_" + mode
def chk(name, cond, detail=""):
    print(("ok " if cond else "FAIL ") + tag + ": " + name + ("" if cond else " (" + str(detail) + ")"))
st = d["stats"]
dash = wire.find(b"DASHBOARD")
intro = wire.find(b"NVIM v")
print("   %d bytes written; first DASHBOARD at %d, first intro at %d; queries %s, held %s" % (
    len(wire), dash, intro, st["queries"], st.get("held")))
chk("the palette asked at VimEnter", st["queries"] == 1, st["queries"])
if mode != "control":
    chk("the dashboard was drawn", dash >= 0, dash)
    chk("no intro screen was drawn before it", intro < 0 or intro > dash, "intro at %d, dashboard at %d" % (intro, dash))
else:
    chk("(control) without the dashboard the intro screen is drawn, and the log sees it", intro >= 0, intro)
sys.exit(0)
PY
  finish
}
intro dashboard
intro vimenter
intro control

# ── slowenter: the held question's limit counts from the main loop ────
# The question at VimEnter is held (see startmsg) and leaves with Neovim's
# first screen. A VimEnter autocmd made after setup() works for 1.5 s without
# the event loop and then sets 'background' to light (Neovim's handler is still
# alive); every answer comes 300 ms late (tests/lib/reorder_pty.py, a slow link
# from 500 ms on). The limit (1 s) has run out by the time the question is
# written, so it is counted again from the main loop (SafeState): the answer,
# 300 ms after the write, is the palette's and does not undo the light.
slowenter() {
  local name="slowenter" post
  if [ "$HAS_SEND" != y ]; then
    ok "slowenter: skipped (this Neovim writes the question to its own stdout at once: nothing is held)"
    return 0
  fi
  DIR="$WORK/$name"; mkdir -p "$DIR"
  post='vim.api.nvim_create_autocmd("VimEnter", { callback = function()
  local t = vim.uv.hrtime()
  while (vim.uv.hrtime() - t) / 1e6 < 1500 do end
  vim.o.background = "light"
end })'
  write_init transp '' "$post" 'require("jupynvim").setup({})'
  NVENV="python3 -I $ROOT/tests/lib/reorder_pty.py 300 --slow-after 500 --" NVNOUP=1 begin "$name" '#222436' || return 0
  cmd ":lua __watch('light', 2000)"
  nv_sync || { finish; return 0; }
  dump r
  run_py_checks "$DIR/r.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
tag = "slowenter"
def chk(name, cond, detail=""):
    print(("ok " if cond else "FAIL ") + tag + ": " + name + ("" if cond else " (" + str(detail) + ")"))
st, info, tokens = d["stats"], d["info"], d["tokens"] or {}
print("   background %s, colors_name %s, handler %s, bg_log %s, loads %s, queries %s, held %s, answers %s, forwarded %s, canvas %s from %s, rtt %s" % (
    d["background"], d["colors_name"], d["handler"], d["bg_log"], d["loads"], st["queries"], st.get("held"), st["answers"],
    st["forwarded"], tokens.get("canvas"), info.get("canvas_source"), info.get("osc_ms")))
# held for real: written after the 1.5 s of work and answered over the slow link (written at VimEnter, the
# answer would have come at once and been read when the work ended, 1.5 s after the question)
chk("the precondition: the question at VimEnter was held until the work ended, and answered 300 ms after that",
    st["queries"] == 1 and st.get("held") == 1 and (info.get("osc_ms") or 0) > 1700,
    "queries %s held %s osc_ms %s" % (st["queries"], st.get("held"), info.get("osc_ms")))
chk("Neovim's own handler is alive again (nothing set 'background' before VimEnter's check)", d["handler"] >= 1, d["handler"])
chk("the light set right after VimEnter is still light", d["background"] == "light", d["background"])
chk("Neovim never set it back", d["bg_log"] == [], d["bg_log"])
chk("the colorscheme was sourced for each of the two values, no third time", d["loads"].get("transp") == 2
    and d["colors_name"] == "transp", "%s %s" % (d["loads"], d["colors_name"]))
chk("the answer was the palette's: the canvas is the terminal's #222436, kind light, nothing forwarded",
    tokens.get("canvas") == "#222436" and info.get("canvas_source") == "terminal" and info.get("kind") == "light"
    and st["forwarded"] == 0, "%s %s %s fwd %s" % (tokens.get("canvas"), info.get("canvas_source"), info.get("kind"), st["forwarded"]))
sys.exit(0)
PY
  finish
}
slowenter

# ── twouis: a TUI and a remote UI, in terminals of two colors ─────────
# nvim_ui_send reaches every terminal UI, so each question gets two
# answers. 'background' is set by hand, dark and light in turn, the two
# terminals disagreeing: an answer of the other UI that arrives after the
# first one must not set it.
twouis() {
  local name="twouis" has_send
  has_send="$("$NV" --headless -u NONE '+lua io.stdout:write(vim.api.nvim_ui_send and "y" or "n")' +qa 2>&1)"
  if [ "$has_send" != y ]; then
    ok "twouis: skipped (this Neovim writes the question to its own stdout only, never to a remote UI)"
    return 0
  fi
  DIR="$WORK/$name"; mkdir -p "$DIR"
  write_init transp '' '' 'require("jupynvim").setup({})'
  cat >> "$DIR/init.lua" <<LUA
function _G.__uis(path)
  local f = io.open(path .. ".tmp", "w"); f:write(tostring(#vim.api.nvim_list_uis())); f:close()
  os.rename(path .. ".tmp", path)
end
-- set 'background' by hand n times, dark and light in turn, and wait for the
-- two terminals' answers after each; what it was after each wait
function _G.__flips(n, path)
  vim.wait(800)
  local res = {}
  for i = 1, n do
    local want = (i % 2 == 1) and "dark" or "light"
    vim.o.background = want
    vim.wait(250)
    res[#res + 1] = { want, vim.o.background }
  end
  local f = io.open(path .. ".tmp", "w"); f:write(vim.json.encode(res), "\n"); f:close()
  os.rename(path .. ".tmp", path)
end
LUA
  begin "$name" '#222436' "--listen $DIR/s.sock" || return 0
  local S2="jnv_pt_${name}_ui2_$$" tries=0
  tmux new-session -d -s "$S2" -x 120 -y 40
  tmux set-option -t "=$S2:" status off
  tmux set-option -w -t "=$S2:" window-style 'bg=#eff1f5'
  tmux send-keys -t "=$S2:" "cd $DIR && $NV --remote-ui --server $DIR/s.sock" Enter
  # the second UI has attached when the server counts two
  while [ "$tries" -lt 20 ]; do
    cmd ":lua __uis('$DIR/uis')"
    jnv_wait_file_eq "$DIR/uis" 2 3 && break
    tries=$((tries + 1))
  done
  if ! jnv_wait_file_eq "$DIR/uis" 2 1; then
    bad "$NAME: the second UI did not attach"
    jnv_stop_session "$S2"
    finish
    return 0
  fi
  cmd ":lua __flips(8, '$DIR/flips.json')"
  if ! jnv_wait_lines "$DIR/flips.json" 1 40; then
    bad "$NAME: the flips never finished"
  fi
  dump r
  run_py_checks "$DIR/r.json" "$DIR/flips.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
flips = json.load(open(sys.argv[2]))
tag = "twouis"
def chk(name, cond, detail=""):
    print(("ok " if cond else "FAIL ") + tag + ": " + name + ("" if cond else " (" + str(detail) + ")"))
st = d["stats"]
print("   flips %s, queries %s, answers %s, handler %s" % (flips, st["queries"], st["answers"], d["handler"]))
chk("each of the 8 explicit changes of 'background' is what 'background' is after both answers",
    all(w == g for w, g in flips), [f for f in flips if f[0] != f[1]])
chk("the palette asked the terminals (more than once)", st["queries"] >= 2, st["queries"])
chk("Neovim's handler is alive again", d["handler"] >= 1, d["handler"])
sys.exit(0)
PY
  jnv_stop_session "$S2" || bad "$NAME: session $S2 did not stop cleanly (LEAK above)"
  finish
}
twouis

# ── the end ─────────────────────────────────────────────
jnv_tmux_stop || bad "the tmux server did not stop cleanly (LEAK above)"
if [ "$FAILS" -eq 0 ]; then
  echo "PALETTE TERMINAL SCREEN: ALL OK"
  exit 0
fi
echo "PALETTE TERMINAL SCREEN: $FAILS CHECK(S) FAILED"
exit 1

#!/usr/bin/env bash
# The palette on a real screen: the terminal's own background through an
# OSC 11 query, end to end, and the swatches of :JupynvimPalette.
#
# Neovim runs in a tmux pane (a private server, tests/lib/tmux.sh). tmux
# answers an OSC 11 query from the window-style of the pane, so the pane's
# background is the terminal's background and the test chooses it.
#
#   phase 1  window-style bg=#222436, the groups of tests/fixtures/palette/
#            user_hl.json (a Tokyo Night Storm user: Normal has no background),
#            colors_name tokyonight-storm, setup({}).
#            - the canvas is #222436 and comes from the terminal
#            - the 35 tokens equal user_tokens.json
#            - exactly one query was sent and answered within 200 ms, and
#              still exactly one after a barrier
#            - the terminal then sends an unsolicited answer of the same
#              color: Neovim's own handler sets 'background' to the same
#              value (an OptionSet with old equal to new), and that starts
#              no query (the palette's handler must tell it from a change)
#            - :JupynvimPalette: the swatch of each token line is drawn in
#              that token's color (the SGR read off the screen), line 1 names
#              the canvas and its source, and neither the query nor the
#              answer shows as text
#   phase 1b a user's own 'background' stays, with Neovim's own handler alive
#            (init.lua never sets 'background', so the handler that sets it
#            from every OSC 11 answer is registered for the whole session) and
#            a transparent colorscheme, in a dark terminal:
#            - ':set background=light' is still light 1.5 s later although the
#              palette asked the terminal again (a second query: the handler
#              is away while it is in flight) and the colorscheme was reloaded
#              only by that change
#            - a terminal answer that says dark still moves 'background' (the
#              control: the handler is back and the test would see a flip)
#            - a colorscheme that sets background=light itself ('forcedlight')
#              stays light and is sourced once, and is still the colorscheme
#   phase 2  the terminal turns light (window-style bg=#eff1f5) and reports it
#            (an OSC 11 answer, as a terminal that reports a change does, which
#            Neovim's handler turns into background=light): the canvas is
#            #eff1f5 from the terminal, kind light, and the palette asked
#            nothing more (the report is enough)
# (a terminal that changes and reports nothing, and the order of start-up, are
# in palette_terminal_screen.sh)
#
# The nvim is JNV_PALETTE_NVIM (a path, default nvim on PATH), so the same
# test runs the writer of Neovim 0.11 (io.stdout) and of 0.12 (nvim_ui_send).
#
#   bash tests/palette_screen.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/tests/lib/tmux.sh"

case "$(uname -s)" in Darwin) EXT=dylib ;; *) EXT=so ;; esac
LIB="$ROOT/core/target/release/libjupynvim.$EXT"
if [ ! -f "$LIB" ]; then
  echo "FAIL palette screen: $LIB is not built: cd core && cargo build --release"
  exit 1
fi
NV="${JNV_PALETTE_NVIM:-nvim}"
if ! command -v "$NV" >/dev/null 2>&1; then
  echo "FAIL palette screen: JNV_PALETTE_NVIM ($NV) is not an executable"
  exit 1
fi
FX="$ROOT/tests/fixtures/palette"

# under the run's TMPDIR (macOS mktemp ignores TMPDIR for -t or no template)
WORK="$(mktemp -d "$TMPDIR/jnv_palette.XXXXXX")"
S="jnv_palette_$$"
# the server first, so no nvim is left to write into WORK as it goes
cleanup() { jnv_tmux_stop; rm -rf "$WORK"; }
jnv_on_exit cleanup

FAILS=0
ok() { echo "ok $1"; }
bad() { echo "FAIL $1"; FAILS=$((FAILS + 1)); }
holds() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
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

# init.lua of the Neovim under test. It never sets 'background' itself: a
# user who does is not followed by Neovim's own handler, and what this test
# proves includes that handler's equal-valued 'background' set on our answer.
cat > "$WORK/init.lua" <<LUA
vim.opt.runtimepath:prepend("$ROOT")
vim.opt.runtimepath:prepend("$WORK") -- colors/transp.lua, colors/forcedlight.lua
vim.o.termguicolors = true
vim.o.swapfile = false
vim.o.laststatus = 0
vim.opt.shortmess:append("I")
-- the groups of a Tokyo Night Storm user, as palette_spec B applies them
local P = require("jupynvim.palette")
local sch = assert(P._schema())
vim.cmd("hi clear")
for _, g in ipairs(sch.groups) do vim.api.nvim_set_hl(0, g, {}) end
local hl = vim.json.decode(table.concat(vim.fn.readfile("$FX/user_hl.json"), "\n"), { luanil = { object = true, array = true } })
for name, a in pairs(hl) do
  if name:sub(1, 1) ~= "_" and type(a) == "table" then vim.api.nvim_set_hl(0, name, { fg = a.fg, bg = a.bg }) end
end
vim.api.nvim_set_hl(0, "@markup.heading.1", { link = "Title" })
vim.g.colors_name = "tokyonight-storm"
require("jupynvim").setup({})

-- every real change of 'background' (Neovim's own handler also sets it to the
-- value it has, which is not a change), as "old>new"
_G.__bg_log = {}
vim.api.nvim_create_autocmd("OptionSet", {
  pattern = "background",
  callback = function()
    if vim.v.option_old ~= vim.v.option_new then
      _G.__bg_log[#_G.__bg_log + 1] = vim.v.option_old .. ">" .. vim.v.option_new
    end
  end,
})

function _G.__sync(n)
  local f = io.open("$WORK/sync.tmp", "w"); f:write(tostring(n)); f:close()
  os.rename("$WORK/sync.tmp", "$WORK/sync")
end
-- tokens, info and stats as JSON, through a tmp file and a rename
function _G.__dump(path)
  local f = io.open(path .. ".tmp", "w")
  f:write(vim.json.encode({ tokens = P.get(), info = P.info(), stats = P._stats,
    marks = { answers = _G.__answers0 or vim.NIL, queries = _G.__queries0 or vim.NIL } }), "\n")
  f:close()
  os.rename(path .. ".tmp", path)
end
-- dump once the palette is derived for what Neovim and the terminal say now
function _G.__ready(path) P.when_ready(function() _G.__dump(path) end) end
-- 'background' and what bears on it, as JSON, through a tmp file and a rename
function _G.__bgdump(path)
  local f = io.open(path .. ".tmp", "w")
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false, create = false })
  local tokens = P.get()
  f:write(vim.json.encode({
    background = vim.o.background,
    colors_name = vim.g.colors_name or vim.NIL,
    handler = #vim.api.nvim_get_autocmds({ group = "nvim.tty", event = "TermResponse" }),
    bg_log = _G.__bg_log,
    loads = _G.__loads or vim.empty_dict(),
    normal_bg = normal.bg or vim.NIL,
    canvas = tokens and tokens.canvas or vim.NIL,
    info = P.info(),
    stats = P._stats,
  }), "\n")
  f:close()
  os.rename(path .. ".tmp", path)
end
-- wait (at most ms) for 'background' to become anything but \`want\`: a flip
-- is seen at once, and a 'background' that stays costs the whole wait
function _G.__watch(want, ms)
  vim.wait(ms, function() return vim.o.background ~= want end, 5)
end
-- wait (at most ms) until 'background' is \`want\`
function _G.__until_bg(want, ms)
  vim.wait(ms, function() return vim.o.background == want end, 5)
end
-- remember how many OSC 11 answers and queries there were, then dump once one
-- more answer has come (at most 3 s) and what it started has run
function _G.__mark() _G.__answers0, _G.__queries0 = P._stats.answers, P._stats.queries end
function _G.__after_answer(path)
  vim.wait(3000, function() return P._stats.answers > _G.__answers0 end, 10)
  vim.wait(200)
  _G.__dump(path)
end
-- phase 2: the terminal's report is there (Neovim's handler has turned it into
-- 'background'), the user's Normal has no background again, then the same wait
function _G.__phase2(path)
  vim.wait(3000, function() return P._stats.answers > _G.__answers0 end, 10)
  vim.api.nvim_set_hl(0, "Normal", { fg = "#4c4f69" })
  vim.cmd("doautocmd ColorScheme")
  _G.__ready(path)
end
LUA

# two transparent colorschemes (Normal has a foreground and no background), as
# files on the runtimepath so that Neovim reloads them when 'background' is
# set; each counts its loads
mkdir -p "$WORK/colors"
cat > "$WORK/colors/transp.lua" <<'LUA'
vim.cmd("hi clear")
vim.g.colors_name = "transp"
_G.__loads = _G.__loads or {}
_G.__loads.transp = (_G.__loads.transp or 0) + 1
vim.api.nvim_set_hl(0, "Normal", { fg = vim.o.background == "light" and "#3760bf" or "#c0caf5" })
LUA
cat > "$WORK/colors/forcedlight.lua" <<'LUA'
-- a light colorscheme that sets 'background' itself, whatever the terminal is
vim.o.background = "light"
vim.cmd("hi clear")
vim.g.colors_name = "forcedlight"
_G.__loads = _G.__loads or {}
_G.__loads.forcedlight = (_G.__loads.forcedlight or 0) + 1
vim.api.nvim_set_hl(0, "Normal", { fg = "#3760bf" })
LUA

send() { tmux send-keys -t "=$S:" "$@"; }
# a command line, typed literally (no key names in it), then Enter
cmd() { tmux send-keys -t "=$S:" -l "$1"; tmux send-keys -t "=$S:" Enter; }
cap() { tmux capture-pane -p -t "=$S:"; }
cap_raw() { tmux capture-pane -p -e -t "=$S:"; }
# nv_sync: a barrier. Types :lua __sync(N) and waits until nvim wrote N to
# $WORK/sync, so every key sent before it has been taken (normal mode only).
SYNC=0
nv_sync() {
  SYNC=$((SYNC + 1))
  cmd ":lua __sync($SYNC)"
  jnv_wait_file_eq "$WORK/sync" "$SYNC" 20 || {
    bad "nvim did not take a command within 20s"
    return 1
  }
}
# show the screen when something went wrong, so the log says what was there
screen_note() { echo "-- the screen:"; cap | sed -e 's/[[:space:]]*$//' | head -n 50; }

echo "-- palette screen on $("$NV" --version | head -n 1)"

# ── phase 1: a dark terminal ────────────────────────────
echo "-- phase 1: the terminal is #222436"
tmux new-session -d -s "$S" -x 160 -y 50
tmux set-option -t "=$S:" status off
# the form proven in planning: tmux answers OSC 11 from the pane's window-style
tmux set-option -w -t "=$S:" window-style 'bg=#222436'
send "cd $WORK && $NV -u $WORK/init.lua" Enter
if ! jnv_wait_nvim_up 20; then
  bad "nvim did not start within 20s"
  screen_note
  echo "PALETTE SCREEN: $FAILS CHECK(S) FAILED"
  exit 1
fi
nv_sync || { screen_note; jnv_tmux_stop; echo "PALETTE SCREEN: $FAILS CHECK(S) FAILED"; exit 1; }
cap > "$WORK/screen_start.txt"
cmd ':lua __ready("'"$WORK"'/p1.json")'
if ! jnv_wait_lines "$WORK/p1.json" 1 15; then
  bad "the palette was not ready within 15s (when_ready never called back)"
  screen_note
  jnv_tmux_stop
  echo "PALETTE SCREEN: $FAILS CHECK(S) FAILED"
  exit 1
fi
nv_sync
cmd ':lua __dump("'"$WORK"'/p1b.json")'
jnv_wait_lines "$WORK/p1b.json" 1 15 || bad "the second dump never came"
# The terminal sends its background again, unasked (as a terminal that reports
# a change of color would): input to the pane, as the terminal would write it.
cmd ":lua __mark()"
nv_sync
tmux send-keys -t "=$S:" -l $'\033]11;rgb:2222/2424/3636\007'
cmd ':lua __after_answer("'"$WORK"'/p1c.json")'
jnv_wait_lines "$WORK/p1c.json" 1 15 || bad "the third dump never came"

run_py_checks "$WORK/p1.json" "$WORK/p1b.json" "$FX/user_tokens.json" "$WORK/p1c.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d2 = json.load(open(sys.argv[2]))
want = json.load(open(sys.argv[3]))
want_tokens = {k: v for k, v in want.items() if k != "table_radius_px"}
tokens, info, stats = d["tokens"] or {}, d["info"], d["stats"]
def chk(name, cond, detail=""):
    print(("ok " if cond else "FAIL ") + name + ("" if cond else " (" + str(detail) + ")"))
print("   p1: canvas %s from %s, kind %s, queries %s, answers %s, fallbacks %s, osc_ms %s, state %s" % (
    tokens.get("canvas"), info.get("canvas_source"), info.get("kind"), stats.get("queries"),
    stats.get("answers"), stats.get("fallbacks"), info.get("osc_ms"), info.get("state")))
chk("P1 the palette is ready (state ok)", info.get("state") == "ok", "%s %s" % (info.get("state"), info.get("reason")))
chk("P1 the canvas comes from the terminal", info.get("canvas_source") == "terminal",
    "%s: %s" % (info.get("canvas_source"), info.get("reason")))
chk("P1 the canvas is #222436", tokens.get("canvas") == "#222436", tokens.get("canvas"))
mism = ["%s %s wanted %s" % (k, tokens.get(k), v) for k, v in want_tokens.items() if tokens.get(k) != v]
extra = sorted(set(tokens) - set(want_tokens))
chk("P1 the 35 tokens equal user_tokens.json", len(want_tokens) == 35 and not mism and not extra,
    "; ".join(mism + (["extra " + ",".join(extra)] if extra else [])))
chk("P1 the kind is dark (Neovim took it from the same answer)", info.get("kind") == "dark", info.get("kind"))
chk("P1 one query was sent", stats.get("queries") == 1, stats.get("queries"))
ms = info.get("osc_ms")
chk("P1 the round trip took under 200 ms", isinstance(ms, (int, float)) and ms < 200, ms)
chk("P1 no fallback", stats.get("fallbacks") == 0, stats.get("fallbacks"))
s2 = d2["stats"]
chk("P1 still one query after a barrier (Neovim's own 'background' set on our answer starts no other)",
    s2.get("queries") == 1, s2.get("queries"))
chk("P1 the canvas is the same after the barrier", (d2["tokens"] or {}).get("canvas") == "#222436",
    (d2["tokens"] or {}).get("canvas"))
d3 = json.load(open(sys.argv[4]))
s3 = d3["stats"]
print("   p1c: queries %s, answers %s (before %s), fallbacks %s" % (
    s3.get("queries"), s3.get("answers"), s2.get("answers"), s3.get("fallbacks")))
chk("P1 the unsolicited answer reached the palette (one more answer)", s3.get("answers") == s2.get("answers", 0) + 1,
    "%s after %s" % (s3.get("answers"), s2.get("answers")))
chk("P1 an unsolicited answer of the same color starts no query (Neovim sets 'background' to the same value)",
    s3.get("queries") == 1, s3.get("queries"))
chk("P1 the canvas is the same after the unsolicited answer",
    (d3["tokens"] or {}).get("canvas") == "#222436" and d3["info"].get("canvas_source") == "terminal",
    "%s from %s" % ((d3["tokens"] or {}).get("canvas"), d3["info"].get("canvas_source")))
sys.exit(0)
PY

# ── :JupynvimPalette, read off the screen ───────────────
echo "-- :JupynvimPalette"
cmd ":JupynvimPalette"
FLOAT=0
for _ in $(seq 1 100); do
  if cap | grep -q "jupynvim palette"; then FLOAT=1; break; fi
  sleep 0.1
done
if [ "$FLOAT" -ne 1 ]; then
  bad "the :JupynvimPalette float did not open within 10s"
  screen_note
else
  ok "the :JupynvimPalette float opened"
  sleep 0.3
  cap_raw > "$WORK/float_raw.txt"
  cap > "$WORK/float_plain.txt"
  run_py_checks "$WORK/float_raw.txt" "$FX/user_tokens.json" "$WORK/screen_start.txt" <<'PY'
import json, re, sys
raw = open(sys.argv[1], encoding="utf-8").read()
want = json.load(open(sys.argv[2]))
start = open(sys.argv[3], encoding="utf-8").read()
names = [k for k in want if k != "table_radius_px"]
def chk(name, cond, detail=""):
    print(("ok " if cond else "FAIL ") + name + ("" if cond else " (" + str(detail) + ")"))
SGR = re.compile(r"\x1b\[([0-9;:]*)m$")
ANY = re.compile(r"\x1b(?:\[[0-9;:?]*[ -/]*[@-~]|\][^\x07\x1b]*(?:\x07|\x1b\\))")
def cells(line):
    """(char, foreground, bold) per character; the foreground is (r, g, b), ('i', n) or None."""
    fg = None
    bold = False
    out = []
    pos = 0
    def apply(params):
        nonlocal fg, bold
        ps = re.split(r"[;:]", params) if params else ["0"]
        i = 0
        while i < len(ps):
            try:
                n = int(ps[i] or "0")
            except ValueError:
                i += 1
                continue
            if n == 0:
                fg, bold = None, False
            elif n == 39:
                fg = None
            elif n == 1:
                bold = True
            elif n == 22:
                bold = False
            elif 30 <= n <= 37:
                fg = ("i", n - 30)
            elif 90 <= n <= 97:
                fg = ("i", n - 82)
            elif n in (38, 48):
                rest = ps[i + 1:]
                mode = rest[0] if rest else ""
                if mode == "2":
                    vals = rest[1:]
                    skip = 0
                    if len(vals) > 3 and vals[0] == "":  # 38:2::r:g:b
                        vals = vals[1:]
                        skip = 1
                    if n == 38:
                        fg = tuple(int(v or "0") for v in vals[:3])
                    i += 1 + skip + 3
                elif mode == "5":
                    if n == 38 and len(rest) > 1:
                        fg = ("i", int(rest[1] or "0"))
                    i += 2
            i += 1
    for m in ANY.finditer(line):
        for ch in line[pos:m.start()]:
            out.append((ch, fg, bold))
        sgr = SGR.match(m.group(0))
        if sgr:
            apply(sgr.group(1))
        pos = m.end()
    for ch in line[pos:]:
        out.append((ch, fg, bold))
    return out
rows = [cells(l) for l in raw.split("\n")]
plain = ["".join(c[0] for c in r) for r in rows]
tok = re.compile(r"(█{6})\s+([a-z0-9_]+)\s+(#[0-9a-f]{6})")
found = []
for r, p in zip(rows, plain):
    m = tok.search(p)
    if m:
        i = m.start(1)
        found.append((m.group(2), m.group(3), {r[i + k][1] for k in range(6)}, p))
chk("S the float has a swatch line for each of the 35 tokens", len(found) == 35, len(found))
chk("S the swatch lines are in token order", [f[0] for f in found] == names,
    "got %s" % [f[0] for f in found][:6])
bad = []
for name, hexv, fgs, _ in found:
    h = want.get(name)
    rgb = tuple(int(hexv[j:j + 2], 16) for j in (1, 3, 5))
    if hexv != h:
        bad.append("%s prints %s, wanted %s" % (name, hexv, h))
    elif fgs != {rgb}:
        bad.append("%s swatch is %s, wanted %s" % (name, sorted(map(str, fgs)), rgb))
chk("S each swatch is drawn in its token's color (SGR on the screen) and prints that hex", not bad, "; ".join(bad[:5]))
hdr = None
for k, p in enumerate(plain):
    if found and found[0][3] == p and k > 0:
        hdr = plain[k - 1]
        break
title_at = [(r, p) for r, p in zip(rows, plain) if " jupynvim palette " in p]
if title_at:
    r, p = title_at[0]
    k = p.index("jupynvim palette")
    acc = want.get("accent", "#000000")
    acc_rgb = tuple(int(acc[j:j + 2], 16) for j in (1, 3, 5))
    chk("S the title of the float is the accent color and bold", r[k][1] == acc_rgb and r[k][2] is True,
        "fg %s bold %s, accent %s" % (r[k][1], r[k][2], acc_rgb))
else:
    chk("S the title of the float is on the screen", False)
chk("S line 1 names the colorscheme", hdr is not None and "colorscheme tokyonight-storm" in hdr, hdr)
chk("S line 1 says canvas #222436 from the terminal", hdr is not None and "canvas #222436 from the terminal" in hdr, hdr)
for label, text in (("before the float", re.sub(ANY, "", start)), ("with the float", "\n".join(plain))):
    chk("S neither the query nor its answer shows as text (" + label + ")",
        "]11;" not in text and "rgb:" not in text,
        [l for l in text.split("\n") if "]11;" in l or "rgb:" in l][:2])
sys.exit(0)
PY
fi
send q
nv_sync
holds "q closes the float" '! cap | grep -q "jupynvim palette"'

# ── phase 1b: the user's 'background' stays ────────────
echo "-- phase 1b: a 'background' the terminal does not agree with stays"
bgdump() {
  cmd ":lua __bgdump('$WORK/$1.json')"
  jnv_wait_lines "$WORK/$1.json" 1 15 || bad "the dump $1 never came"
}
cmd ":colorscheme transp"
nv_sync
bgdump b1
# ':set background=light' in a dark terminal, with Neovim's handler alive
cmd ":set background=light"
cmd ":lua __watch('light', 1500)"
nv_sync
bgdump b2
# the control: the terminal says it is dark, and Neovim's handler follows it
tmux send-keys -t "=$S:" -l $'\033]11;rgb:2222/2424/3636\007'
cmd ":lua __until_bg('dark', 3000)"
nv_sync
bgdump b3
# a colorscheme that sets 'background' itself, loaded in a dark terminal
cmd ":colorscheme forcedlight"
cmd ":lua __watch('light', 1500)"
nv_sync
bgdump b4
run_py_checks "$WORK/b1.json" "$WORK/b2.json" "$WORK/b3.json" "$WORK/b4.json" <<'PY'
import json, sys
b1, b2, b3, b4 = (json.load(open(a)) for a in sys.argv[1:5])
def chk(name, cond, detail=""):
    print(("ok " if cond else "FAIL ") + name + ("" if cond else " (" + str(detail) + ")"))
def show(tag, d):
    print("   %s: background %s, colors_name %s, handler %s, bg_log %s, loads %s, queries %s, answers %s, canvas %s" % (
        tag, d["background"], d["colors_name"], d["handler"], d["bg_log"], d["loads"], d["stats"]["queries"],
        d["stats"]["answers"], d["canvas"]))
for tag, d in (("b1", b1), ("b2", b2), ("b3", b3), ("b4", b4)):
    show(tag, d)
chk("P1b the precondition: Neovim's own background handler (augroup nvim.tty) is alive", b1["handler"] >= 1, b1["handler"])
chk("P1b ...the terminal is dark, so is 'background'", b1["background"] == "dark", b1["background"])
chk("P1b ...a transparent colorscheme is in use (Normal has no background)",
    b1["colors_name"] == "transp" and b1["normal_bg"] is None, "%s %s" % (b1["colors_name"], b1["normal_bg"]))
chk("P1b ...the palette's canvas is the terminal's", b1["canvas"] == "#222436" and b1["info"]["canvas_source"] == "terminal",
    "%s %s" % (b1["canvas"], b1["info"]["canvas_source"]))
chk("P1b ':set background=light' in a dark terminal is still light 1.5 s later", b2["background"] == "light", b2["background"])
chk("P1b ...Neovim saw one change of 'background' and no other (nothing set it back)", b2["bg_log"] == ["dark>light"], b2["bg_log"])
chk("P1b ...the palette asked the terminal again, once (a second query), and Neovim's handler is back", b2["stats"]["queries"] == 2
    and b2["handler"] >= 1, "queries %s handler %s" % (b2["stats"]["queries"], b2["handler"]))
chk("P1b ...the transparent colorscheme was sourced by :colorscheme and once by that change, no third time",
    b2["loads"].get("transp") == 2, b2["loads"])
chk("P1b ...the palette follows: kind light, canvas still the terminal's", b2["info"]["kind"] == "light"
    and b2["canvas"] == "#222436" and b2["info"]["canvas_source"] == "terminal",
    "%s %s %s" % (b2["info"]["kind"], b2["canvas"], b2["info"]["canvas_source"]))
chk("P1b the control: an answer that says dark moves 'background' to dark (Neovim's handler)",
    b3["background"] == "dark" and b3["bg_log"][-1:] == ["light>dark"], "%s %s" % (b3["background"], b3["bg_log"]))
chk("P1b ...the palette read that answer too, and asked nothing for it (the report is enough)",
    b3["stats"]["answers"] > b2["stats"]["answers"] and b3["stats"]["queries"] == 2,
    "answers %s after %s, queries %s" % (b3["stats"]["answers"], b2["stats"]["answers"], b3["stats"]["queries"]))
chk("P1b a colorscheme that sets background=light itself stays light in a dark terminal", b4["background"] == "light"
    and b4["colors_name"] == "forcedlight", "%s %s" % (b4["background"], b4["colors_name"]))
chk("P1b ...and was sourced once, not again after a flip", b4["loads"].get("forcedlight") == 1, b4["loads"])
chk("P1b ...Neovim saw one change, the palette asked once for it, and the colorscheme is still the colorscheme",
    b4["bg_log"][len(b3["bg_log"]):] == ["dark>light"] and b4["stats"]["queries"] == 3 and b4["colors_name"] == "forcedlight",
    "%s queries %s" % (b4["bg_log"][len(b3["bg_log"]):], b4["stats"]["queries"]))
sys.exit(0)
PY

# ── phase 2: the terminal turns light ───────────────────
echo "-- phase 2: the terminal is #eff1f5 and says so"
cmd ":lua vim.g.colors_name = nil"
cmd ":set background=dark"
nv_sync
# the palette asks again for that change; its answer comes while the terminal is still dark
cmd ':lua __ready("'"$WORK"'/p2pre.json")'
jnv_wait_lines "$WORK/p2pre.json" 1 15 || bad "phase 2: the palette was not ready after ':set background=dark'"
tmux set-option -w -t "=$S:" window-style 'bg=#eff1f5'
cmd ":lua __mark()"
nv_sync
# the terminal reports its new color (an OSC 11 answer); Neovim's own handler
# turns it into background=light, and the palette reads it
tmux send-keys -t "=$S:" -l $'\033]11;rgb:efef/f1f1/f5f5\007'
cmd ':lua __phase2("'"$WORK"'/p2.json")'
if ! jnv_wait_lines "$WORK/p2.json" 1 15; then
  bad "phase 2: the palette was not ready within 15s"
  screen_note
else
  run_py_checks "$WORK/p2.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
tokens, info, stats = d["tokens"] or {}, d["info"], d["stats"]
def chk(name, cond, detail=""):
    print(("ok " if cond else "FAIL ") + name + ("" if cond else " (" + str(detail) + ")"))
print("   p2: canvas %s from %s, kind %s, queries %s, answers %s, fallbacks %s, osc_ms %s" % (
    tokens.get("canvas"), info.get("canvas_source"), info.get("kind"), stats.get("queries"),
    stats.get("answers"), stats.get("fallbacks"), info.get("osc_ms")))
chk("P2 the canvas is #eff1f5", tokens.get("canvas") == "#eff1f5", tokens.get("canvas"))
chk("P2 the canvas comes from the terminal", info.get("canvas_source") == "terminal",
    "%s: %s" % (info.get("canvas_source"), info.get("reason")))
chk("P2 no query after the terminal's report (it is read, none is sent)", stats.get("queries") == d["marks"]["queries"],
    "%s after %s" % (stats.get("queries"), d["marks"]["queries"]))
chk("P2 the kind is light", info.get("kind") == "light", info.get("kind"))
sys.exit(0)
PY
fi

# ── the end ─────────────────────────────────────────────
send Escape
send ":qa!" Enter
jnv_wait_nvim_exit 15 || bad "nvim did not quit within 15s of :qa!"
jnv_stop_session "$S" || bad "session $S did not stop cleanly (LEAK above)"
jnv_tmux_stop || bad "the tmux server did not stop cleanly (LEAK above)"
if [ "$FAILS" -eq 0 ]; then
  echo "PALETTE SCREEN: ALL OK"
  exit 0
fi
echo "PALETTE SCREEN: $FAILS CHECK(S) FAILED"
exit 1

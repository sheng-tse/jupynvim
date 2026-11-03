#!/usr/bin/env bash
# The palette's question for the terminal's background must not be undone by a
# gif: on a real screen, behind a terminal that reads slowly.
#
# With a transparent colorscheme the palette asks the terminal for its
# background (OSC 11, then a DSR) when 'background' changes, with Neovim's own
# handler for the answer (it would set 'background' from the terminal's
# colour) taken away until every answer is in. A gif playing in view has
# frames, each followed by a DSR of its own, in flight on the way to the
# terminal: their status answers come before the question's. Taken for the
# question's, the first of them ended the window, and the question's own OSC 11
# answer, which then came after it, reached Neovim's handler: the user's
# :set background=light in a dark terminal was undone. The palette now asks
# notebook/image.lua for a fence (status_fence) right before it writes, and
# the status answers read before the fence's marker is answered are not
# its own. And a terminal that needs longer than the question's limit to read
# the frames in flight has not had the chance to answer yet, so the limit
# counts from when the fence is passed.
#
# Neovim runs behind tests/lib/tty_relay.py, which passes the output on at
# about 25 KB/s (several frames take seconds), in a private tmux pane whose window-style is dark (tmux
# answers an OSC 11 query from it). The notebook holds one animated gif in
# view. The test types :set background=light once the gif plays and watches
# the next seconds: 'background' must stay light, Neovim's handler must have
# been given none of the palette's answers (the options log shows the one
# change), the palette must have asked and been answered, some frame's status
# answer must have come before the question's own answer (the precondition),
# and nothing may be cut (tests/lib/escape_scan.py).
#
# Not covered: a question that waits behind other output (a screen redraw, an
# image) for longer than its limit of 1 s, which the palette's limit alone
# decides and which happens without any gif: at 25 KB/s the same test with
# the gif off screen fails the same way, a limit of the palette and not of
# the frames.
#
# Needs Neovim 0.12+ (nvim_ui_send), tmux and ImageMagick 7.
# JNV_STREAM_NVIM=/path/to/nvim runs another Neovim; JNV_STPAL_KEEP=DIR keeps
# the logs there.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/core/target/release/jupynvim-core"
[ -x "$BIN" ] || { echo "SKIP stream_palette: build core first ($BIN)"; exit 0; }
source "$(dirname "$0")/lib/tmux.sh"
NVIM_BIN="${JNV_STREAM_NVIM:-nvim}"
command -v magick >/dev/null || { echo "SKIP stream_palette: no ImageMagick 7 (magick)"; exit 0; }
"$NVIM_BIN" --headless -u NONE -c 'lua io.stdout:write(vim.api.nvim_ui_send and "y" or "n")' -c 'qa!' 2>/dev/null \
  | grep -q y || { echo "SKIP stream_palette: $NVIM_BIN has no nvim_ui_send (Neovim 0.12+)"; exit 0; }
WORK="$(mktemp -d "$TMPDIR/jupynvim_stpal.XXXXXX")"
cleanup() { [ -n "${JNV_STPAL_KEEP:-}" ] && cp -R "$WORK" "$JNV_STPAL_KEEP" 2>/dev/null; jnv_tmux_stop; rm -rf "$WORK"; }
jnv_on_exit cleanup

# 12 frames at 40 ms of noise PNG cannot squeeze, small: about 14 KB of
# escape a frame, so several frames (and their status requests) are on their
# way at once, which is what puts the answers of frames in front of the
# palette's
( cd "$WORK" && for i in $(seq 0 11); do
    magick -size 60x60 xc: -seed $((i + 1)) +noise Random -depth 8 "h_$(printf %02d "$i").png" || exit 1
  done && magick -delay 4 -loop 0 h_*.png heavy.gif ) \
  || { echo "FAIL stream_palette: ImageMagick could not make the gif"; exit 1; }

python3 - "$WORK" <<'PY'
import base64, json, os, sys
w = sys.argv[1]
gif = base64.b64encode(open(os.path.join(w, "heavy.gif"), "rb").read()).decode()
long_src = "\n".join("v%02d = [i * %d for i in range(%d)]  # row %d" % (i, i, i + 3, i) for i in range(60))
def code(i, src, outs=()):
    return {"cell_type": "code", "id": "c%d" % i, "metadata": {}, "execution_count": i,
            "outputs": list(outs), "source": src}
gifcell = code(1, "show_gif()", [{"output_type": "display_data", "metadata": {},
                                  "data": {"image/gif": gif, "text/plain": "<img>"}}])
json.dump({"cells": [gifcell, code(2, long_src), code(3, "x = 1")], "metadata": {"language_info": {"name": "python"}},
           "nbformat": 4, "nbformat_minor": 5}, open(os.path.join(w, "nb_view.ipynb"), "w"))
PY
mkdir -p "$WORK/colors"
# a transparent colorscheme: Normal has no background of its own
cat > "$WORK/colors/transp.lua" <<'LUA'
vim.cmd("hi clear")
vim.g.colors_name = "transp"
vim.api.nvim_set_hl(0, "Normal", { fg = "#c0caf5" })
LUA

cat > "$WORK/init.lua" <<LUA
vim.opt.runtimepath:prepend("$ROOT")
vim.opt.runtimepath:prepend("$WORK")
vim.o.swapfile = false
vim.o.termguicolors = true
vim.opt.shortmess:append("I")
local D = os.getenv("JNV_DIR")
local function put(name, s) local f = io.open(D .. "/" .. name, "a"); f:write(s); f:close() end
local t0 = vim.uv.hrtime()
local function ms() return math.floor((vim.uv.hrtime() - t0) / 1e6) end
-- every change of 'background', and every OSC 11 answer Neovim's own handler is given
vim.api.nvim_create_autocmd("OptionSet", { pattern = "background", callback = function()
  put("bg_log", ms() .. " " .. vim.o.background .. "\n")
end })
vim.cmd.colorscheme("transp")
require("jupynvim").setup({ core_path = "$BIN", auto_venv = false })
local I = require("jupynvim.notebook.image")
local P = require("jupynvim.palette")
-- what Neovim's handler saw: the OSC 11 answers (the handler is in augroup nvim.tty)
vim.api.nvim_create_autocmd("TermResponse", { callback = function(ev)
  local d = ev.data
  local s = type(d) == "table" and d.sequence or d
  if type(s) == "string" then
    local kind = s:find("\27]11;", 1, true) and "osc" or s == "\27[0n" and "dsr" or s:find("^\27P>|") and "mark" or "other"
    put("termresp", ms() .. " " .. kind .. "\n")
  end
end })
function _G.__ready()
  for _, p in pairs(I._placements) do
    if p.timer then
      local f = io.open(D .. "/ready", "w"); f:write("1"); f:close()
      return
    end
  end
end
function _G.__state(tag)
  local info = P.info()
  put("snap", string.format("%s background=%s handler=%d queries=%d answers=%d forwarded=%d fallbacks=%d frames=%d marks=%d\n",
    tag, vim.o.background, #vim.api.nvim_get_autocmds({ group = "nvim.tty", event = "TermResponse" }),
    P._stats.queries, P._stats.answers, P._stats.forwarded, P._stats.fallbacks, I._frames_sent or 0, I._marks_got or 0))
end
local timer = vim.uv.new_timer()
timer:start(100, 100, vim.schedule_wrap(function() pcall(_G.__ready) end))
local f = io.open(D .. "/pid", "w"); f:write(tostring(vim.fn.getpid())); f:close()
LUA

q() { printf %q "$1"; }
# run NAME NOTEBOOK: nvim behind the relay (25 KB/s) in a dark pane; the gif plays; :set background=light,
# then 12 s of watching
run() {
  local name="$1" nb="$2" P="$WORK/$1" S="jupy_stpal_$1_$$"
  mkdir -p "$P"
  cat > "$P/run.sh" <<SH
while [ ! -e "$P/go" ]; do sleep 0.02; done
exec python3 -I "$ROOT/tests/lib/tty_relay.py" --read 1024 --delay-ms 40 -- env -u TMUX -u TMUX_PANE JNV_DIR=$P \
  TERM=xterm-256color XDG_STATE_HOME="$P/state" "$NVIM_BIN" -i NONE -u "$WORK/init.lua" "$WORK/$nb"
SH
  mkdir -p "$P/state"
  tmux new-session -d -s "$S" -x 160 -y 50 "sh $(q "$P/run.sh")"
  tmux set-option -t "=$S:" status off
  # tmux answers OSC 11 from the pane's window-style: a dark terminal
  tmux set-option -w -t "=$S:" window-style "bg=#222436"
  tmux pipe-pane -t "=$S:" -O "cat > $(q "$P/raw.bin")"
  touch "$P/go"
  jnv_wait_file_eq "$P/ready" 1 120 || { echo "never" > "$P/never"; echo "FAIL $name: the gif never animated"; }
  sleep 3
  tmux send-keys -t "=$S:" ":lua __state('before')" Enter
  sleep 2
  tmux send-keys -t "=$S:" ":set background=light" Enter
  sleep 12
  tmux send-keys -t "=$S:" ":lua __state('after')" Enter
  sleep 3
  tmux send-keys -t "=$S:" Escape ":qa!" Enter
  for _ in $(seq 1 300); do tmux has-session -t "=$S" 2>/dev/null || break; sleep 0.1; done
  local last=-1 sz
  for _ in $(seq 1 50); do
    sz="$(wc -c < "$P/raw.bin" 2>/dev/null || echo 0)"
    [ "$sz" = "$last" ] && break
    last="$sz"; sleep 0.2
  done
  jnv_stop_session "$S" || echo "LEAK" >> "$P/leak"
}

run view nb_view.ipynb
leak=0
[ -e "$WORK/view/leak" ] && leak=1
jnv_tmux_stop || leak=1

WORK="$WORK" LEAK="$leak" LIB="$ROOT/tests/lib" python3 -I - <<'PY'
import os, re, sys
sys.dont_write_bytecode = True
sys.path.insert(0, os.environ["LIB"])
from escape_scan import scan, summary
W = os.environ["WORK"]
fails = []
def chk(name, ok, detail=""):
    print(("  ok " if ok else "FAIL ") + name + ("" if ok else "  -- " + detail))
    if not ok: fails.append(name)
def read(ph, name):
    p = os.path.join(W, ph, name)
    return [l for l in open(p).read().split("\n") if l.strip()] if os.path.exists(p) else []
def state(ph):
    out = {}
    for l in read(ph, "snap"):
        tag, *kv = l.split()
        out[tag] = {k: v for k, v in (x.split("=", 1) for x in kv)}
    return out
for ph in ("view",):
    data = open(os.path.join(W, ph, "raw.bin"), "rb").read() if os.path.exists(os.path.join(W, ph, "raw.bin")) else b""
    cuts, kitty = scan(data)
    st = state(ph)
    bg_log = [l.split()[1] for l in read(ph, "bg_log")]
    tr = [l.split()[1] for l in read(ph, "termresp")]
    tr_ms = [int(l.split()[0]) for l in read(ph, "termresp")]
    bg_ms = [int(l.split()[0]) for l in read(ph, "bg_log")]
    print("%s: %s" % (ph, summary(data, cuts, kitty)))
    print("  state %s" % st)
    print("  options log %s, the terminal's answers in order %s" % (bg_log, " ".join(tr[:40])))
    if ph == "view":
        # the precondition: after the user's change, status answers (the frames') came before the last
        # OSC 11 answer (the question's own)
        t_set = max([t for t, v in zip(bg_ms, bg_log) if v == "light"] or [0])
        last_osc = max([i for i, k in enumerate(tr) if k == "osc"] or [-1])
        before_q = [i for i, (k, t) in enumerate(zip(tr, tr_ms)) if k == "dsr" and t >= t_set and i < last_osc]
        chk("view: frames' status answers came before the question's own answer (the case this test is for)",
            len(before_q) >= 1, "answers in order: %s" % " ".join(tr))
        chk("view: the gif played", not os.path.exists(os.path.join(W, ph, "never")) and int((st.get("after") or {}).get("frames", 0)) > 5, str(st))
        chk("view: frames waited behind a marker (the editor's markers were answered)", int((st.get("after") or {}).get("marks", 0)) >= 1, str(st))
    a, b = st.get("before"), st.get("after")
    chk(ph + ": the state was read before and after :set background=light", a is not None and b is not None, str(st))
    if a and b:
        chk(ph + ": 'background' is still light after the question and its answers", b["background"] == "light", b["background"])
        chk(ph + ": 'background' was set to light by the user and never back to dark (Neovim's handler never set it from the terminal)",
            "light" in bg_log and "dark" not in bg_log[bg_log.index("light"):], str(bg_log))
        chk(ph + ": the palette asked again for the change and its question was answered", int(b["queries"]) > int(a["queries"])
            and int(b["answers"]) > int(a["answers"]), "queries %s -> %s, answers %s -> %s" % (a["queries"], b["queries"], a["answers"], b["answers"]))
        chk(ph + ": none of the palette's answers was given to Neovim's handler", b["forwarded"] == a["forwarded"], "forwarded %s -> %s" % (a["forwarded"], b["forwarded"]))
        chk(ph + ": Neovim's handler is back after the window", int(b["handler"]) >= 1, b["handler"])
    chk(ph + ": no escape sequence was cut", not cuts, "%d cut" % len(cuts))
chk("no process or session was left", os.environ.get("LEAK") == "0", "leak")
if fails:
    print("STREAM-PALETTE-SCREEN: %d FAILED" % len(fails))
    sys.exit(1)
print("STREAM-PALETTE-SCREEN: ALL PASSED")
PY

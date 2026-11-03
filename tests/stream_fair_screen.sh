#!/usr/bin/env bash
# Two gifs in view share the terminal fairly.
#
# Every gif frame jupynvim sends with nvim_ui_send is followed by a status
# request the terminal answers once it has read the frame, and a frame goes
# out only while the frames not read yet fit a window (tests/stream_backlog
# _screen.sh). All gifs share that one window. A gif that finds it full
# skips the frame and waits; if the room an answer frees went to whichever
# gif ticks first, a fast gif would take it every time and a slow one (a
# frame a second) would never get a frame while the window is the
# bottleneck: it would sit frozen in view for as long as the other plays.
# The room goes to the gif that has waited longest.
#
# Neovim runs behind tests/lib/tty_relay.py set to pass the output on at
# 60 KB/s (a slow link with large buffers), in a private tmux pane whose raw
# output is logged (pipe-pane). The notebook shows two gifs, both in view:
# a heavy one (about 115 KB of escape a frame, a frame every 40 ms, about
# 2 s a frame on that link) and a light one (6 small frames, one a second).
# Once both play, the test counts, over HOLD seconds (20), the transmits of
# each gif that reached the terminal (per image id in the pane's output). It
# fails when fewer than a fifth of the light gif's ticks did (the heavy
# gif's frames take most of the link, so it can have about half), when the
# heavy one stopped, when the bytes written ran ahead of the terminal by
# more than a few frames, or when an escape sequence was cut
# (tests/lib/escape_scan.py).
#
# Needs Neovim 0.12+ (nvim_ui_send), tmux and ImageMagick 7 (gif playback).
# JNV_STREAM_NVIM=/path/to/nvim runs another Neovim; JNV_FAIR_HOLD=S sets the
# measured window (default 20 s; a value that is not a whole number above 0
# is ignored).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/core/target/release/jupynvim-core"
[ -x "$BIN" ] || { echo "SKIP stream_fair: build core first ($BIN)"; exit 0; }
source "$(dirname "$0")/lib/tmux.sh"
NVIM_BIN="${JNV_STREAM_NVIM:-nvim}"
HOLD="${JNV_FAIR_HOLD:-20}"
case "$HOLD" in ''|*[!0-9]*) HOLD=0 ;; esac
HOLD=$((10#$HOLD))
[ "$HOLD" -gt 0 ] || { echo "stream_fair: JNV_FAIR_HOLD=${JNV_FAIR_HOLD:-} is not a whole number above 0; using 20"; HOLD=20; }
command -v magick >/dev/null || { echo "SKIP stream_fair: no ImageMagick 7 (magick)"; exit 0; }
"$NVIM_BIN" --headless -u NONE -c 'lua io.stdout:write(vim.api.nvim_ui_send and "y" or "n")' -c 'qa!' 2>/dev/null \
  | grep -q y || { echo "SKIP stream_fair: $NVIM_BIN has no nvim_ui_send (Neovim 0.12+)"; exit 0; }
WORK="$(mktemp -d "$TMPDIR/jupynvim_fair.XXXXXX")"
cleanup() { jnv_tmux_stop; rm -rf "$WORK"; }
jnv_on_exit cleanup

# heavy: 12 frames at 40 ms, each with a block of noise PNG cannot squeeze;
# light: 6 small frames at 1 s
( cd "$WORK" && for i in $(seq 0 11); do
    magick -size 640x480 gradient:'#203040-#506070' \( -size 320x240 xc: -seed $((i + 1)) +noise Random \) \
      -geometry +$((i * 20))+$((i * 10)) -composite -depth 8 "h_$(printf %02d "$i").png" || exit 1
  done && magick -delay 4 -loop 0 h_*.png heavy.gif \
  && for i in $(seq 0 5); do
    magick -size 200x100 xc:"rgb($((i * 40)),80,$((200 - i * 30)))" "l_$i.png" || exit 1
  done && magick -delay 100 -loop 0 l_*.png light.gif ) \
  || { echo "FAIL stream_fair: ImageMagick could not make the gifs"; exit 1; }

python3 - "$WORK" <<'PY'
import base64, json, os, sys
w = sys.argv[1]
def cell(cid, name):
    gif = base64.b64encode(open(os.path.join(w, name), "rb").read()).decode()
    return {"cell_type": "code", "id": cid, "metadata": {}, "execution_count": 1, "source": "show()",
            "outputs": [{"output_type": "display_data", "metadata": {},
                         "data": {"image/gif": gif, "text/plain": "<img>"}}]}
json.dump({"cells": [cell("c1", "heavy.gif"), cell("c2", "light.gif")],
           "metadata": {"language_info": {"name": "python"}}, "nbformat": 4, "nbformat_minor": 5},
          open(os.path.join(w, "two.ipynb"), "w"))
PY

# __stats(tag) appends the totals and the image id of each gif (told apart
# by the size of its first frame); ready is written once both gifs animate
mkdir -p "$WORK/state" "$WORK/xdg"
cat > "$WORK/init.lua" <<LUA
vim.opt.runtimepath:prepend("$ROOT")
vim.o.swapfile = false
vim.o.termguicolors = true
local D = "$WORK/state"
local function put(name, s, mode)
  local f = io.open(D .. "/" .. name, mode or "a"); f:write(s); f:close()
end
require("jupynvim").setup({ core_path = "$BIN", auto_venv = false })
local I = require("jupynvim.notebook.image")
put("addr", vim.v.servername, "w")
put("pid", tostring(vim.fn.getpid()), "w")
function _G.__stats(tag)
  local heavy, light = {}, {}
  for _, p in pairs(I._placements) do
    if p.timer and p.frames then
      if #(p.frames[1] or "") > 20000 then heavy = p else light = p end
    end
  end
  put("stats", string.format("%s tty_bytes=%d frames_sent=%d frames_held=%d heavy_id=%d light_id=%d\n",
    tag, I._tty_bytes or 0, I._frames_sent or 0, I._frames_held or 0, heavy.image_id or 0, light.image_id or 0))
end
local ready = vim.uv.new_timer()
ready:start(100, 100, vim.schedule_wrap(function()
  local n = 0
  for _, p in pairs(I._placements) do
    if p.timer and (p.frame_idx or 1) > 1 then n = n + 1 end
  end
  if n >= 2 then ready:stop(); put("ready", "1", "w") end
end))
LUA

q() { printf %q "$1"; }
cat > "$WORK/run.sh" <<SH
while [ ! -e "$WORK/go" ]; do sleep 0.02; done
exec python3 -I "$ROOT/tests/lib/tty_relay.py" --out-rate 60 -- env -u TMUX -u TMUX_PANE TERM=xterm-256color \
  XDG_STATE_HOME="$WORK/xdg" "$NVIM_BIN" -i NONE -u "$WORK/init.lua" "$WORK/two.ipynb"
SH
S="jupy_fair_$$"
tmux new-session -d -s "$S" -x 160 -y 60 "sh $(q "$WORK/run.sh")"
tmux pipe-pane -t "=$S:" -O "cat > $(q "$WORK/raw.bin")"
touch "$WORK/go"
CAP() { tmux capture-pane -t "=$S:" -p; }
if ! jnv_wait_file_eq "$WORK/state/ready" 1 90; then
  echo "the two gifs never animated; the screen:"
  CAP 2>/dev/null | LC_ALL=C sed -e '/^ *$/d' -e 's/^/  | /' | tail -n 20
  echo "never" >> "$WORK/never"
fi
addr="$(cat "$WORK/state/addr" 2>/dev/null)"
n=0
stats() {
  n=$((n + 1))
  "$NVIM_BIN" --server "$addr" --remote-expr "luaeval('_G.__stats(\"$1\") or 0')" >/dev/null 2>&1
  jnv_wait_lines "$WORK/state/stats" "$n" 30 || echo "stats $1: no answer"
  echo "$1 pane_bytes=$(wc -c < "$WORK/raw.bin" | tr -d ' ')" >> "$WORK/samples"
}
sleep 3
stats s0
sleep "$HOLD"
stats s1
"$NVIM_BIN" --server "$addr" --remote-send '<Esc>:qa!<CR>' >/dev/null 2>&1
for _ in $(seq 1 300); do tmux has-session -t "=$S" 2>/dev/null || break; sleep 0.1; done
last=-1
for _ in $(seq 1 50); do
  sz="$(wc -c < "$WORK/raw.bin" 2>/dev/null || echo 0)"
  [ "$sz" = "$last" ] && break
  last="$sz"; sleep 0.2
done
ep="$(cat "$WORK/state/pid" 2>/dev/null)"
if [ -n "$ep" ] && ps -p "$ep" -o command= 2>/dev/null | grep -qF "$WORK"; then
  echo "the editor did not quit; stopping pid $ep"
  kill "$ep" 2>/dev/null
  echo "leftover" >> "$WORK/leftover"
fi
leak=0
jnv_stop_session "$S" || leak=1
jnv_tmux_stop || leak=1

WORK="$WORK" HOLD="$HOLD" LEAK="$leak" LIB="$ROOT/tests/lib" python3 -I - <<'PY'
import os, re, sys
sys.dont_write_bytecode = True
sys.path.insert(0, os.environ["LIB"])
from escape_scan import scan, summary
W = os.environ["WORK"]
hold = int(os.environ["HOLD"])
fails = []
def chk(name, ok, detail=""):
    print(("  ok " if ok else "FAIL ") + name + ("" if ok else "  -- " + detail))
    if not ok: fails.append(name)
def read(name):
    p = os.path.join(W, name)
    return open(p, errors="replace").read().split("\n") if os.path.exists(p) else []
data = open(os.path.join(W, "raw.bin"), "rb").read() if os.path.exists(os.path.join(W, "raw.bin")) else b""
cuts, kitty = scan(data)
st, sm = {}, {}
for line in read("state/stats"):
    if line.strip():
        tag, *kv = line.split()
        st[tag] = {k: v for k, v in (x.split("=", 1) for x in kv)}
for line in read("samples"):
    if line.strip():
        tag, *kv = line.split()
        sm[tag] = int(kv[0].split("=", 1)[1])
def n(tag, k):
    try: return int(st[tag][k])
    except (KeyError, ValueError): return None
print("two gifs behind 60 KB/s, %d s: %s" % (hold, summary(data, cuts, kitty)))
for tag in ("s0", "s1"):
    print("  %-3s %s pane=%s" % (tag, st.get(tag), sm.get(tag)))
# the transmits of each image id that reached the terminal between the samples
seg = data[sm["s0"]:sm["s1"]] if "s0" in sm and "s1" in sm else b""
tx = {}
for m in re.finditer(rb"\x1b_Ga=t,f=100,i=(\d+),q=2,m=", seg):
    tx[int(m.group(1))] = tx.get(int(m.group(1)), 0) + 1
hid, lid = n("s0", "heavy_id"), n("s0", "light_id")
ls, hs = tx.get(lid, 0), tx.get(hid, 0)
print("  frames that reached the terminal in %d s: heavy %s, light %s (its clock ticks %d times)" % (hold, hs, ls, hold))
chk("both gifs started to animate", not os.path.exists(os.path.join(W, "never")), "not within 90 s")
chk("the light gif was not starved: at least a fifth of its %d ticks reached the terminal (the heavy gif takes most of the link)" % hold,
    ls >= max(1, hold // 5), "the light gif's frames in %d s: %s (transmits per image id: %s)" % (hold, ls, tx))
chk("the heavy gif kept playing (at least %d frames in %d s)" % (max(1, hold // 8), hold), hs >= max(1, hold // 8),
    "the heavy gif's frames: %s" % hs)
wrote, got = n("s1", "tty_bytes"), sm.get("s1")
chk("the graphics written ran no more than a few frames ahead of what the terminal got (1 MB)",
    None not in (wrote, got) and wrote - got < 1024 * 1024, "written %s, the terminal got %s" % (wrote, got))
chk("kitty graphics reached the terminal", kitty > 0, "no kitty escape in the log")
chk("no escape sequence was cut", not cuts, "%d cut" % len(cuts))
chk("the editor quit", not os.path.exists(os.path.join(W, "leftover")), "stopped by pid")
chk("nvim and its terminal multiplexer stopped cleanly", os.environ.get("LEAK") == "0", "LEAK above")
print(("\nSTREAM-FAIR: %d FAILED" % len(fails)) if fails else "\nSTREAM-FAIR: ALL PASSED")
sys.exit(1 if fails else 0)
PY

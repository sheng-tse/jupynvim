#!/usr/bin/env bash
# Kitty graphics must reach the terminal in order with Neovim's own output.
#
# Since Neovim 0.10 the screen is drawn by a separate UI process. Graphics
# written to the terminal on any other path (the editor's stderr channel, the
# backend's /dev/tty) can land inside one of the UI's escape sequences when
# the terminal is slow to read: the terminal drops that sequence, prints its
# tail (a stray "66:97m") and the cursor drifts, so cell borders break until
# the screen is cleared and redrawn. Every write now goes through
# nvim_ui_send, which the UI puts between its own sequences.
#
# Neovim runs on a pty whose reader lags (tests/lib/tty_relay.py), in a
# private tmux pane whose raw output is logged (pipe-pane). The notebook has an
# animated gif, a long cell and a static plot. The test scrolls the screen
# while the gif plays, far enough that the gif leaves the view and comes back,
# parks it off screen, types next to the plot and scrolls back. It fails when
# the log holds an escape sequence that something cut (tests/lib/escape_scan.py:
# any ESC, CSI, OSC, DCS or APC sequence another ESC arrived inside, or a
# UTF-8 character an ESC split), when a write did not go through nvim_ui_send,
# when the gif sent anything while off screen, when typing wrote graphics
# although nothing changed, or when the gif stopped playing in view or did not
# resume when it came back.
#
# Needs Neovim 0.12+ (nvim_ui_send), tmux and ImageMagick 7 (gif playback).
# JNV_STREAM_NVIM=/path/to/nvim runs another Neovim; JNV_STREAM_MEASURE=1
# only prints the counts (for Neovim 0.11, which has no in-order write);
# JNV_STREAM_HOLD=S sets the scroll and typing windows (S/2 seconds each,
# default 20; a value that is not a whole number of 2 or more is ignored:
# below 2 the windows would be empty).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/core/target/release/jupynvim-core"
[ -x "$BIN" ] || { echo "SKIP stream_order: build core first ($BIN)"; exit 0; }
source "$(dirname "$0")/lib/tmux.sh"
NVIM_BIN="${JNV_STREAM_NVIM:-nvim}"
MEASURE="${JNV_STREAM_MEASURE:-}"
HOLD="${JNV_STREAM_HOLD:-20}"
case "$HOLD" in ''|*[!0-9]*) HOLD=0 ;; esac
HOLD=$((10#$HOLD))
[ "$HOLD" -ge 2 ] || { echo "stream_order: JNV_STREAM_HOLD=${JNV_STREAM_HOLD:-} is not a whole number of 2 or more; using 20"; HOLD=20; }
command -v magick >/dev/null || { echo "SKIP stream_order: no ImageMagick 7 (magick)"; exit 0; }
UI_SEND=""
"$NVIM_BIN" --headless -u NONE -c 'lua io.stdout:write(vim.api.nvim_ui_send and "y" or "n")' -c 'qa!' 2>/dev/null \
  | grep -q y && UI_SEND=1
[ -n "$UI_SEND" ] || [ -n "$MEASURE" ] || { echo "SKIP stream_order: $NVIM_BIN has no nvim_ui_send (Neovim 0.12+)"; exit 0; }
WORK="$(mktemp -d "$TMPDIR/jupynvim_stream.XXXXXX")"
S="jupy_stream_$$"
cleanup() { jnv_tmux_stop; rm -rf "$WORK"; }
jnv_on_exit cleanup
mkdir -p "$WORK/state"

# 16 frames at 80 ms, and a static plot
( cd "$WORK" && for i in $(seq 0 15); do
    magick -size 480x320 gradient:'#1e3050-#402060' -fill "rgb($((i * 15)),200,$((240 - i * 15)))" \
      -draw "circle $((40 + i * 25)),160 $((40 + i * 25)),110" "f_$(printf %02d "$i").png" || exit 1
  done \
  && magick -delay 8 -loop 0 f_*.png anim.gif \
  && magick -size 640x400 xc:white -stroke '#3070c0' -strokewidth 3 -fill none \
       -draw 'polyline 20,380 180,320 340,240 500,160 620,40' plot.png ) \
  || { echo "FAIL stream_order: ImageMagick could not make the images"; exit 1; }

# the gif cell, a 28-line cell, the plot cell
python3 - "$WORK" <<'PY'
import base64, json, os, sys
w = sys.argv[1]
b = lambda f: base64.b64encode(open(os.path.join(w, f), "rb").read()).decode()
long_src = "\n".join("v%02d = [i * %d for i in range(%d)]  # row %d" % (i, i, i + 3, i) for i in range(28))
def code(i, src, outs=()):
    return {"cell_type": "code", "id": "c%d" % i, "metadata": {}, "execution_count": i,
            "outputs": list(outs), "source": src}
img = lambda m, f: {"output_type": "display_data", "metadata": {}, "data": {m: b(f), "text/plain": "<img>"}}
cells = [code(1, "show_gif()", [img("image/gif", "anim.gif")]),
         code(2, long_src, [{"output_type": "stream", "name": "stdout", "text": "done\n"}]),
         code(3, "plot()", [img("image/png", "plot.png")])]
json.dump({"cells": cells, "metadata": {"language_info": {"name": "python"}},
           "nbformat": 4, "nbformat_minor": 5}, open(os.path.join(w, "nb.ipynb"), "w"))
PY

# __stats(tag) appends the image writer's counters; ready is written once the
# gif animates (a placement with a frame timer); addr and pid name the editor
# process, which outlives its UI after :detach; detached is written 0.5 s and
# 3.5 s after the last UI left, with the counters at each
cat > "$WORK/init.lua" <<LUA
vim.opt.runtimepath:prepend("$ROOT")
vim.o.swapfile = false
vim.o.termguicolors = true
vim.o.number = true
require("jupynvim").setup({ core_path = "$BIN", auto_venv = false })
local I = require("jupynvim.notebook.image")
function _G.__stats(tag)
  local f = io.open("$WORK/stats", "a")
  f:write(string.format("%s tty_n=%d tty_bytes=%d ui_send_n=%d frames_sent=%d frames_skipped=%d place_writes=%d remote=%s\n",
    tag, I._tty_n or 0, I._tty_bytes or 0, I._ui_send_n or 0, I._frames_sent or 0,
    I._frames_skipped or 0, I._place_writes or 0, tostring(I._remote_mode)))
  f:close()
end
local ready = vim.uv.new_timer()
ready:start(100, 100, vim.schedule_wrap(function()
  for _, p in pairs(I._placements) do
    if p.timer then
      ready:stop()
      local f = io.open("$WORK/ready", "w"); f:write("1"); f:close()
      return
    end
  end
end))
for name, v in pairs({ addr = vim.v.servername, pid = tostring(vim.fn.getpid()) }) do
  local f = io.open("$WORK/" .. name, "w"); f:write(v); f:close()
end
vim.api.nvim_create_autocmd("UILeave", { callback = function()
  if #vim.api.nvim_list_uis() > 0 then return end
  local function mark(tag, v)
    _G.__stats(tag)
    local f = io.open("$WORK/detached", "w"); f:write(v); f:close()
  end
  vim.defer_fn(function()
    mark("detached", "1")
    vim.defer_fn(function() mark("detached3s", "2") end, 3000)
  end, 500)
end })
LUA

# nvim on the slow relay; the pane's raw output (what the terminal got) is
# logged from the first byte: the relay waits for the go file. A shell on the
# relay's terminal runs nvim and outlives it, as the user's shell does, so
# the terminal stays open after the UI quits (with the UI as the terminal's
# session leader the system would revoke it); it prints UI-GONE when nvim's
# UI has quit and waits for the end file.
cat > "$WORK/run.sh" <<SH
while [ ! -e "$WORK/go" ]; do sleep 0.02; done
exec python3 -I "$ROOT/tests/lib/tty_relay.py" -- sh -c 'env -u TMUX -u TMUX_PANE TERM=xterm-256color \
  XDG_STATE_HOME="$WORK/state" "$NVIM_BIN" -i NONE -u "$WORK/init.lua" "$WORK/nb.ipynb"; printf UI-GONE; \
  while [ ! -e "$WORK/end" ]; do sleep 0.1; done'
SH
tmux new-session -d -s "$S" -x 160 -y 50 "sh $(printf %q "$WORK/run.sh")"
tmux pipe-pane -t "=$S:" -O "cat > $(printf %q "$WORK/raw.bin")"
touch "$WORK/go"
CAP() { tmux capture-pane -t "=$S:" -p; }
# CAPWAIT FILE [WANT [NOT]]: the screen once it shows WANT and not NOT (the
# keys before it were processed, and the terminal drew their result), or as
# it is after 15 s
CAPWAIT() {
  local end=$((SECONDS + 15)) c
  while :; do
    c="$(CAP)"
    { [ -z "${2:-}" ] || [[ "$c" == *"$2"* ]]; } && { [ -z "${3:-}" ] || [[ "$c" != *"$3"* ]]; } && break
    [ "$SECONDS" -ge "$end" ] && break
    sleep 0.1
  done
  printf '%s\n' "$c" > "$1"
}
n=0
stats() { n=$((n + 1)); tmux send-keys -t "=$S:" ":lua __stats('$1')" Enter; jnv_wait_lines "$WORK/stats" "$n" 15 || echo "stats $1: no answer"; }
# logged WORD: the pane's raw log holds WORD (waits up to 15 s)
logged() {
  local end=$((SECONDS + 15))
  until LC_ALL=C grep -qaF "$1" "$WORK/raw.bin" 2>/dev/null; do
    [ "$SECONDS" -ge "$end" ] && return 1
    sleep 0.1
  done
}
# a gif that never animates (nvim did not start, or the image did not play)
# ends the run here with one FAIL and the screen: every step after it would
# only wait out its timeouts
stop_early() {
  local fails=1 leak=0 c
  echo "FAIL $1"
  if c="$(CAP 2>/dev/null)"; then
    printf '%s\n' "$c" | LC_ALL=C sed -e '/^ *$/d' -e 's/^/  | /' | tail -n 20
  else
    echo "  | (none: the pane has closed, the program in it ended)"
  fi
  jnv_stop_session "$S" || leak=1
  jnv_tmux_stop || leak=1
  [ "$leak" = 0 ] || { echo "FAIL nvim and its terminal multiplexer stopped cleanly  -- LEAK above"; fails=2; }
  printf '\nSTREAM-ORDER: %d FAILED (stopped early)\n' "$fails"
  exit 1
}
jnv_wait_file_eq "$WORK/ready" 1 40 || stop_early "the gif started to animate  -- not within 40 s; the screen:"
stats start

# 1) the screen scrolls while the gif plays: 30 rows down takes the gif's
# image rows out of view, 30 up brings them back
end=$((SECONDS + HOLD / 2))
while [ "$SECONDS" -lt "$end" ]; do
  for _ in $(seq 1 30); do tmux send-keys -t "=$S:" C-e; sleep 0.03; done
  for _ in $(seq 1 30); do tmux send-keys -t "=$S:" C-y; sleep 0.03; done
done
stats scrolled
CAPWAIT "$WORK/cap_scrolled.txt" "show_gif()"

# 2) the plot cell at the top: the gif is off screen and must send nothing
tmux send-keys -t "=$S:" gg; sleep 0.3
tmux send-keys -t "=$S:" j; sleep 0.3; tmux send-keys -t "=$S:" j; sleep 0.3
tmux send-keys -t "=$S:" zt
stats idle0
CAPWAIT "$WORK/cap_parked.txt" "plot()" "show_gif()"
sleep 3
stats idle1

# 3) typing next to the plot: nothing changes for the terminal's images
tmux send-keys -t "=$S:" Enter; sleep 0.5; tmux send-keys -t "=$S:" o; sleep 0.3
end=$((SECONDS + HOLD / 2))
while [ "$SECONDS" -lt "$end" ]; do
  for k in x x x x BSpace BSpace BSpace BSpace; do tmux send-keys -t "=$S:" "$k"; sleep 0.06; done
done
tmux send-keys -t "=$S:" Escape; sleep 0.3
stats typed

# 4) back to the top: the gif resumes where its clock is
tmux send-keys -t "=$S:" Escape; sleep 0.4; tmux send-keys -t "=$S:" gg; sleep 1.5
stats back
CAPWAIT "$WORK/cap_back.txt" "show_gif()"

if [ -n "$UI_SEND" ]; then
  # 5) :detach: the UI quits, and the editor runs on in the background with
  # the gif in view and its stderr still on this pane's terminal. Nobody sees
  # the screen, and the shell the user got back draws there: nothing may be
  # written. The editor is then told to quit through its socket.
  tmux send-keys -t "=$S:" Escape ":detach" Enter
  jnv_wait_file_eq "$WORK/detached" 1 15 || echo "no UILeave with every UI gone"
  # the UI's last bytes and then the shell's UI-GONE are in the log (late
  # under load): whatever the log gets after this sample came from the editor
  logged UI-GONE || echo "no UI-GONE in the log"
  echo "detached pane_bytes=$(wc -c < "$WORK/raw.bin" | tr -d ' ')" >> "$WORK/samples"
  jnv_wait_file_eq "$WORK/detached" 2 15 || echo "no stats 3 s after :detach"
  echo "detached3s pane_bytes=$(wc -c < "$WORK/raw.bin" | tr -d ' ')" >> "$WORK/samples"
  "$NVIM_BIN" --server "$(cat "$WORK/addr")" --remote-send '<C-\><C-N>:qa!<CR>' >/dev/null 2>&1
else
  tmux send-keys -t "=$S:" Escape ":qa!" Enter
fi
# the editor process is gone (after :detach it outlived its UI)
ep="$(cat "$WORK/pid" 2>/dev/null)"
for _ in $(seq 1 100); do
  { [ -n "$ep" ] && ps -p "$ep" -o command= 2>/dev/null | grep -qF "$WORK"; } || break
  sleep 0.1
done
# one that did not quit when told to is ours to stop (by pid)
if [ -n "$ep" ] && ps -p "$ep" -o command= 2>/dev/null | grep -qF "$WORK"; then
  echo "the detached editor did not quit; stopping pid $ep"
  kill "$ep" 2>/dev/null
  echo "leftover pid=$ep" >> "$WORK/samples"
fi
touch "$WORK/end"
for _ in $(seq 1 200); do tmux has-session -t "=$S" 2>/dev/null || break; sleep 0.1; done
# the logging cat ends with the pane; wait until the log stops growing
last=-1
for _ in $(seq 1 50); do
  sz="$(wc -c < "$WORK/raw.bin" 2>/dev/null || echo 0)"
  [ "$sz" = "$last" ] && break
  last="$sz"; sleep 0.2
done
leak=0
jnv_stop_session "$S" || leak=1
jnv_tmux_stop || leak=1

WORK="$WORK" HOLD="$HOLD" MEASURE="$MEASURE" LEAK="$leak" LIB="$ROOT/tests/lib" python3 -I - <<'PY'
import os, re, sys
sys.dont_write_bytecode = True
sys.path.insert(0, os.environ["LIB"])
from escape_scan import scan, summary
W = os.environ["WORK"]
hold, measure = int(os.environ["HOLD"]), bool(os.environ["MEASURE"])
data = open(os.path.join(W, "raw.bin"), "rb").read() if os.path.exists(os.path.join(W, "raw.bin")) else b""
cuts, kitty = scan(data)

st = {}
for line in open(os.path.join(W, "stats")) if os.path.exists(os.path.join(W, "stats")) else []:
    tag, *kv = line.split()
    st[tag] = {k: (v if k == "remote" else int(v)) for k, v in (x.split("=", 1) for x in kv)}
def g(tag, k): return st.get(tag, {}).get(k)
def cap(name):
    p = os.path.join(W, name)
    return open(p, encoding="utf-8", errors="replace").read() if os.path.exists(p) else ""
sm = {}
for line in open(os.path.join(W, "samples")) if os.path.exists(os.path.join(W, "samples")) else []:
    tag, *kv = line.split()
    sm[tag] = dict(x.split("=", 1) for x in kv if "=" in x)

print(summary(data, cuts, kitty))
for tag in ("start", "scrolled", "idle0", "idle1", "typed", "back", "detached", "detached3s"):
    print("  %-10s %s %s" % (tag, st.get(tag), sm.get(tag, "")))
if measure:
    print("MEASURE stream_order: cut_sequences=%d" % len(cuts)); sys.exit(0)

fails = []
def chk(name, ok, detail=""):
    print(("  ok " if ok else "FAIL ") + name + ("" if ok else "  -- " + detail))
    if not ok: fails.append(name)
chk("kitty graphics reached the terminal", kitty > 0, "no kitty escape in the log")
chk("no escape sequence was cut", not cuts, "%d cut" % len(cuts))
chk("every write went through nvim_ui_send",
    g("back", "tty_n") and g("back", "ui_send_n") == g("back", "tty_n") and g("back", "remote") == "true",
    str(st.get("back")))
chk("the gif played while in view",
    None not in (g("scrolled", "frames_sent"), g("start", "frames_sent"))
    and g("scrolled", "frames_sent") - g("start", "frames_sent") >= hold // 2,
    "frames sent %s -> %s" % (g("start", "frames_sent"), g("scrolled", "frames_sent")))
chk("the gif left the view and came back while the screen scrolled",
    None not in (g("scrolled", "frames_skipped"), g("start", "frames_skipped"))
    and g("scrolled", "frames_skipped") > g("start", "frames_skipped"),
    "frames skipped %s -> %s" % (g("start", "frames_skipped"), g("scrolled", "frames_skipped")))
chk("the gif was parked off screen", "plot()" in cap("cap_parked.txt") and "show_gif()" not in cap("cap_parked.txt"),
    "scenario: the parked screen still shows the gif cell")
chk("an off-screen gif sends nothing",
    g("idle1", "tty_bytes") is not None and g("idle1", "tty_bytes") == g("idle0", "tty_bytes"),
    "%s bytes in 3 s" % (None if g("idle1", "tty_bytes") is None else g("idle1", "tty_bytes") - g("idle0", "tty_bytes")))
chk("its clock kept running off screen",
    (g("idle1", "frames_skipped") or 0) > (g("idle0", "frames_skipped") or 0), str(st.get("idle1")))
chk("typing next to the plot wrote no graphics",
    g("typed", "tty_bytes") is not None and g("typed", "tty_bytes") == g("idle1", "tty_bytes"),
    "%s bytes while typing" % (None if g("typed", "tty_bytes") is None else g("typed", "tty_bytes") - g("idle1", "tty_bytes")))
chk("the gif resumed back in view",
    "show_gif()" in cap("cap_back.txt") and (g("back", "frames_sent") or 0) > (g("typed", "frames_sent") or 0),
    str(st.get("back")))
# what a cut leaves on screen: the tail of a color sequence or a graphics command
# as text. The multiplexer's own parser drops most cut tails before they
# reach its screen, so this sees only what gets through; the scanner check
# above is the guard against cuts
tail = re.compile(r"\d+[:;]\d+(?:[:;]\d+)*m|_Ga=")
bad = [c for c in ("cap_scrolled.txt", "cap_parked.txt", "cap_back.txt") if tail.search(cap(c))]
chk("no escape tail shows in the multiplexer's screen captures", not bad, "in " + ", ".join(bad))
pb = [int(sm.get(t, {}).get("pane_bytes", -1)) for t in ("detached", "detached3s")]
chk("after :detach the editor wrote nothing and its gif's clock ran on",
    None not in (g("detached", "tty_bytes"), g("detached3s", "tty_bytes"))
    and g("detached3s", "tty_bytes") == g("detached", "tty_bytes")
    and (g("detached3s", "frames_skipped") or 0) > (g("detached", "frames_skipped") or 0),
    "%s -> %s" % (st.get("detached"), st.get("detached3s")))
gone = data.rfind(b"UI-GONE")
chk("once the UI had quit, nothing reached the terminal", gone >= 0 and len(data) == gone + len(b"UI-GONE")
    and -1 not in pb and pb[1] == pb[0],
    "UI-GONE at %d of %d bytes; %s bytes after it by 3.5 s after :detach" % (gone, len(data), pb[1] - pb[0] if -1 not in pb else None))
chk("the detached editor quit when told to through its socket", "leftover" not in sm,
    "stopped by pid %s" % sm.get("leftover", {}).get("pid"))
chk("nvim and its terminal multiplexer stopped cleanly", os.environ.get("LEAK") == "0", "LEAK above")
print(("\nSTREAM-ORDER: %d FAILED" % len(fails)) if fails else "\nSTREAM-ORDER: ALL PASSED")
sys.exit(1 if fails else 0)
PY

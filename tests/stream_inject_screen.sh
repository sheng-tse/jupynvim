#!/usr/bin/env bash
# Image data in a notebook never reaches the terminal as an escape.
#
# An image/png value goes into a Kitty graphics escape (ESC _ G ... ESC \)
# as it is. A value with an ESC \ inside it ends that escape early, and the
# terminal then runs whatever follows as escapes of its own (a window title,
# a clipboard write), with the rest of the value printed over the notebook.
# The file needs no code to run: opening a shared or downloaded .ipynb is
# enough. ensure_transmitted refuses a value with a byte outside the base64
# alphabet before anything is written.
#
# A real nvim opens a notebook with two cells in an interactive bash in a
# private tmux pane whose raw output (what the terminal gets) is logged from
# the first byte. Cell 1 holds a valid PNG, cell 2 the same PNG's base64 with
# ESC \ ESC ] 2 ; jnv-inject-probe BEL spliced in (an OSC 2, a window title:
# nothing here touches a clipboard even when it gets through). The test
# fails when the valid image did not reach the terminal, or when the probe
# text did, or (with nvim_ui_send, Neovim 0.12+) when an escape sequence was
# cut (tests/lib/escape_scan.py).
#
# Needs tmux. No ImageMagick. JNV_STREAM_NVIM=/path/to/nvim runs another
# Neovim (0.11 has no in-order writer: there the cut count is only printed).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/core/target/release/jupynvim-core"
[ -x "$BIN" ] || { echo "SKIP stream_inject: build core first ($BIN)"; exit 0; }
source "$(dirname "$0")/lib/tmux.sh"
NVIM_BIN="${JNV_STREAM_NVIM:-nvim}"
UI_SEND=""
"$NVIM_BIN" --headless -u NONE -c 'lua io.stdout:write(vim.api.nvim_ui_send and "y" or "n")' -c 'qa!' 2>/dev/null \
  | grep -q y && UI_SEND=1
WORK="$(mktemp -d "$TMPDIR/jupynvim_inject.XXXXXX")"
S="jupy_inject_$$"
cleanup() { jnv_tmux_stop; rm -rf "$WORK"; }
jnv_on_exit cleanup

python3 -I - "$WORK" <<'PY'
import base64, json, os, struct, sys, zlib
w = sys.argv[1]
def chunk(kind, body):
    c = kind + body
    return struct.pack(">I", len(body)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)
W, H = 64, 32
rows = b"".join(b"\x00" + b"".join(bytes((x * 4 % 256, y * 8 % 256, 160)) for x in range(W))
                for y in range(H))
png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))
good = base64.b64encode(png).decode()
bad = good[:40] + "\x1b\\\x1b]2;jnv-inject-probe\x07" + good[40:]
def cell(i, value):
    return {"cell_type": "code", "id": "c%d" % i, "metadata": {}, "execution_count": i, "source": "plot(%d)" % i,
            "outputs": [{"output_type": "display_data", "metadata": {},
                         "data": {"image/png": value, "text/plain": "<img>"}}]}
json.dump({"cells": [cell(1, good), cell(2, bad)], "metadata": {"language_info": {"name": "python"}},
           "nbformat": 4, "nbformat_minor": 5}, open(os.path.join(w, "nb.ipynb"), "w"))
PY
[ -s "$WORK/nb.ipynb" ] || { echo "FAIL stream_inject: could not write the notebook"; exit 1; }

cat > "$WORK/init.lua" <<LUA
vim.opt.runtimepath:prepend("$ROOT")
vim.o.swapfile = false
vim.o.termguicolors = true
require("jupynvim").setup({ core_path = "$BIN", auto_venv = false })
LUA

# an interactive shell, as the user's; the pane's raw output (what the
# terminal got) is logged from its first byte
tmux new-session -d -s "$S" -x 160 -y 50 "env -u TMUX -u TMUX_PANE PS1='SH\$ ' bash --norc --noprofile -i"
tmux pipe-pane -t "=$S:" -O "cat > $(printf %q "$WORK/raw.bin")"
CAP() { tmux capture-pane -t "=$S:" -p; }
pane_bytes() { wc -c < "$WORK/raw.bin" 2>/dev/null | tr -d ' '; }
# the log has caught up with what the terminal got: its size held for 0.4 s
# (at most 3 s)
settle() {
  local end=$((SECONDS + 3)) a b
  a="$(pane_bytes)"
  while [ "$SECONDS" -lt "$end" ]; do
    sleep 0.4; b="$(pane_bytes)"
    [ "$a" = "$b" ] && return 0
    a="$b"
  done
  return 1
}
# the raw log has the bytes WANT (a fixed string)
raw_has() { grep -aqF -- "$1" "$WORK/raw.bin" 2>/dev/null; }
wait_raw() { local end=$((SECONDS + $2)); until raw_has "$1"; do [ "$SECONDS" -ge "$end" ] && return 1; sleep 0.1; done; }
# the screen shows WANT within SECS
wait_screen() {
  local end=$((SECONDS + $2))
  until [[ "$(CAP)" == *"$1"* ]]; do [ "$SECONDS" -ge "$end" ] && return 1; sleep 0.1; done
}
q() { printf %q "$1"; }

wait_screen 'SH$' 15 || echo "no shell prompt in the pane"
tmux send-keys -t "=$S:" "env TERM=xterm-256color XDG_STATE_HOME=$(q "$WORK/state") $(q "$NVIM_BIN") -i NONE -u $(q "$WORK/init.lua") $(q "$WORK/nb.ipynb")" Enter
reached=1
wait_raw '_Ga=t' 30 || reached=0
settle
nvim_up=1
jnv_wait_nvim_up 5 || nvim_up=0
tmux send-keys -t "=$S:" Escape ":qa!" Enter
quit=1
jnv_wait_nvim_exit 15 || quit=0
tmux send-keys -t "=$S:" "exit" Enter
for _ in $(seq 1 100); do tmux has-session -t "=$S" 2>/dev/null || break; sleep 0.1; done
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

WORK="$WORK" UI_SEND="$UI_SEND" LEAK="$leak" REACHED="$reached" QUIT="$quit" NVIM_UP="$nvim_up" \
  LIB="$ROOT/tests/lib" python3 -I - <<'PY'
import os, sys
sys.dont_write_bytecode = True
sys.path.insert(0, os.environ["LIB"])
from escape_scan import scan, summary
W = os.environ["WORK"]
p = os.path.join(W, "raw.bin")
data = open(p, "rb").read() if os.path.exists(p) else b""
cuts, kitty = scan(data)
print(summary(data, cuts, kitty))
fails = []
def chk(name, ok, detail=""):
    print(("  ok " if ok else "FAIL ") + name + ("" if ok else "  -- " + detail))
    if not ok: fails.append(name)
chk("nvim opened the notebook and the valid image reached the terminal",
    os.environ["REACHED"] == "1" and os.environ["NVIM_UP"] == "1" and b"_Ga=t" in data,
    "%d bytes logged, %d kitty escapes, nvim up %s" % (len(data), kitty, os.environ["NVIM_UP"]))
chk("no escape from the notebook's image data reached the terminal",
    b"jnv-inject-probe" not in data,
    "the probe text is in the terminal's input at byte %d of %d" % (data.find(b"jnv-inject-probe"), len(data)))
if os.environ.get("UI_SEND"):
    chk("no escape sequence was cut", not cuts, "%d cut" % len(cuts))
else:
    print("  (no nvim_ui_send: %d cut sequences, not checked)" % len(cuts))
chk("nvim quit with :qa!", os.environ["QUIT"] == "1")
chk("nvim and its terminal multiplexer stopped cleanly", os.environ.get("LEAK") == "0", "LEAK above")
print(("\nSTREAM-INJECT: %d FAILED" % len(fails)) if fails else "\nSTREAM-INJECT: ALL PASSED")
sys.exit(1 if fails else 0)
PY

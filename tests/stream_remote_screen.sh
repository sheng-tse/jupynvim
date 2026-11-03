#!/usr/bin/env bash
# A session with only remote notebooks plays a gif the way any other does.
#
# A remote backend cannot reach this terminal, so it never becomes the image
# writer: the escapes are encoded in the editor, and no local backend needs to
# run at all. A plugin loaded lazily also sees no UIEnter, so nothing marks the
# session as one whose escapes are encoded here. The gif frames of such a
# session must still wait for the terminal (each followed by a status request,
# a frame going only while the frames not answered for fit the window), or
# behind a slow terminal or link they pile up in the editor's queue to the UI
# and the screen stops following the keyboard.
#
# The plugin is loaded after the UI attached. The remote is a second
# jupynvim-core that the profile's transport_cmd starts. The notebook, opened
# through its jupynvim:// URI, holds one gif in view; Neovim runs behind
# tests/lib/tty_relay.py set to read 1 KB every 4 ms (250 KB/s, under what the
# gif plays at), in a private tmux pane whose raw output is logged (pipe-pane).
# The test samples the counters 3 s after the gif started and 8 s later. It
# fails when a local backend ran, when frames went without a status request,
# when no frame waited or none was answered, when the bytes written ran ahead
# of the bytes the terminal got by more than a few frames, or when an escape
# sequence was cut (tests/lib/escape_scan.py).
#
# Needs Neovim 0.12+ (nvim_ui_send), tmux and ImageMagick 7.
# JNV_STREAM_NVIM=/path/to/nvim runs another Neovim.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/core/target/release/jupynvim-core"
[ -x "$BIN" ] || { echo "SKIP stream_remote: build core first ($BIN)"; exit 0; }
source "$(dirname "$0")/lib/tmux.sh"
NVIM_BIN="${JNV_STREAM_NVIM:-nvim}"
command -v magick >/dev/null || { echo "SKIP stream_remote: no ImageMagick 7 (magick)"; exit 0; }
"$NVIM_BIN" --headless -u NONE -c 'lua io.stdout:write(vim.api.nvim_ui_send and "y" or "n")' -c 'qa!' 2>/dev/null \
  | grep -q y || { echo "SKIP stream_remote: $NVIM_BIN has no nvim_ui_send (Neovim 0.12+)"; exit 0; }
WORK="$(mktemp -d "$TMPDIR/jupynvim_sremote.XXXXXX")"
S="jupy_sremote_$$"
cleanup() { jnv_tmux_stop; rm -rf "$WORK"; }
jnv_on_exit cleanup
mkdir -p "$WORK/state"

# 16 frames at 80 ms, each a noisy picture, so a frame costs real bytes
( cd "$WORK" && for i in $(seq 0 15); do
    magick -size 480x320 "plasma:fractal" -seed "$((i + 1))" -fill white \
      -draw "circle $((40 + i * 25)),160 $((40 + i * 25)),110" "f_$(printf %02d "$i").png" || exit 1
  done && magick -delay 8 -loop 0 f_*.png play.gif ) \
  || { echo "FAIL stream_remote: ImageMagick could not make the gif"; exit 1; }

python3 -I - "$WORK" <<'PY'
import base64, json, os, sys
w = sys.argv[1]
gif = base64.b64encode(open(os.path.join(w, "play.gif"), "rb").read()).decode()
cells = [{"cell_type": "code", "id": "c1", "metadata": {}, "execution_count": 1, "source": "show_gif()",
          "outputs": [{"output_type": "display_data", "metadata": {},
                       "data": {"image/gif": gif, "text/plain": "<img>"}}]}]
json.dump({"cells": cells, "metadata": {"language_info": {"name": "python"}},
           "nbformat": 4, "nbformat_minor": 5}, open(os.path.join(w, "nb.ipynb"), "w"))
PY

# the plugin loads after the UI attached, as with a lazy plugin manager;
# __stats(tag) appends the counters, ready is written once the gif animates
cat > "$WORK/init.lua" <<LUA
vim.opt.runtimepath:prepend("$ROOT")
vim.o.swapfile = false
vim.o.termguicolors = true
local function put(name, s, mode)
  local f = io.open("$WORK/" .. name, mode or "a"); f:write(s); f:close()
end
vim.api.nvim_create_autocmd("UIEnter", { once = true, callback = function()
  vim.schedule(function()
    local J = require("jupynvim")
    J.setup({ core_path = "$BIN", auto_venv = false,
      remote = { stub = { host = "stub.invalid", transport_cmd = { "$BIN" } } } })
    local I = require("jupynvim.notebook.image")
    function _G.__stats(tag)
      local anim = 0
      for _, p in pairs(I._placements) do if p.timer then anim = anim + 1 end end
      put("stats", string.format("%s frames_sent=%d frames_held=%d acks_sent=%d acks_got=%d ui_bytes=%d remote_mode=%d local_backend=%d remote_backend=%d anim=%d\n",
        tag, I._frames_sent or 0, I._frames_held or 0, I._acks_sent or 0, I._acks_got or 0, I._ui_send_bytes or 0,
        I._remote_mode and 1 or 0, (J.clients["local"] and J.clients["local"].job) and 1 or 0,
        (J.clients.stub and J.clients.stub.job) and 1 or 0, anim))
    end
    local ready = vim.uv.new_timer()
    ready:start(100, 100, vim.schedule_wrap(function()
      for _, p in pairs(I._placements) do
        if p.timer and (p.frame_idx or 1) > 1 then
          ready:stop()
          put("ready", "1", "w")
          return
        end
      end
    end))
    put("addr", vim.v.servername, "w")
  end)
end })
LUA

q() { printf %q "$1"; }
cat > "$WORK/run.sh" <<SH
while [ ! -e "$WORK/go" ]; do sleep 0.02; done
exec python3 -I "$ROOT/tests/lib/tty_relay.py" --read 1024 --delay-ms 4 -- \
  env -u TMUX -u TMUX_PANE TERM=xterm-256color XDG_STATE_HOME=$(q "$WORK/state") \
  $(q "$NVIM_BIN") -i NONE -u $(q "$WORK/init.lua")
SH
tmux new-session -d -s "$S" -x 160 -y 50 "sh $(q "$WORK/run.sh")"
tmux pipe-pane -t "=$S:" -O "cat > $(q "$WORK/raw.bin")"
touch "$WORK/go"
CAP() { tmux capture-pane -t "=$S:" -p; }
jnv_wait_file_nonempty() { for _ in $(seq 1 "$(($2 * 20))"); do [ -s "$1" ] && return 0; sleep 0.05; done; return 1; }
jnv_wait_file_nonempty "$WORK/addr" 30 || { echo "FAIL the editor did not start"; CAP | tail -n 10; jnv_stop_session "$S"; jnv_tmux_stop; exit 1; }
"$NVIM_BIN" --server "$(cat "$WORK/addr")" --remote-send ":e jupynvim://stub$WORK/nb.ipynb<CR>" >/dev/null 2>&1
if ! jnv_wait_file_eq "$WORK/ready" 1 60; then
  echo "FAIL the gif never animated; the screen:"
  CAP | LC_ALL=C sed -e '/^ *$/d' -e 's/^/  | /' | tail -n 20
  jnv_stop_session "$S"; jnv_tmux_stop
  printf '\nSTREAM-REMOTE: 1 FAILED (stopped early)\n'
  exit 1
fi
n=0
rstats() {
  n=$((n + 1))
  "$NVIM_BIN" --server "$(cat "$WORK/addr")" --remote-expr "luaeval('_G.__stats(\"$1\") or 0')" >/dev/null 2>&1
  jnv_wait_lines "$WORK/stats" "$n" 30 || echo "stats $1: no answer"
  wc -c < "$WORK/raw.bin" > "$WORK/raw_$1"
}
sleep 3
rstats early
sleep 8
rstats later
tmux send-keys -t "=$S:" Escape ":qa!" Enter
for _ in $(seq 1 100); do tmux has-session -t "=$S" 2>/dev/null || break; sleep 0.1; done
last=-1
for _ in $(seq 1 50); do
  sz="$(wc -c < "$WORK/raw.bin" 2>/dev/null || echo 0)"
  [ "$sz" = "$last" ] && break
  last="$sz"; sleep 0.2
done
leak=0
jnv_stop_session "$S" || leak=1
jnv_tmux_stop || leak=1

WORK="$WORK" LEAK="$leak" LIB="$ROOT/tests/lib" python3 -I - <<'PY'
import os, sys
sys.dont_write_bytecode = True
sys.path.insert(0, os.environ["LIB"])
from escape_scan import scan, summary
W = os.environ["WORK"]
def read(name):
    p = os.path.join(W, name)
    return open(p, encoding="utf-8", errors="replace").read() if os.path.exists(p) else ""
data = open(os.path.join(W, "raw.bin"), "rb").read() if os.path.exists(os.path.join(W, "raw.bin")) else b""
cuts, kitty = scan(data)
st = {}
for line in read("stats").splitlines():
    if line.strip():
        tag, *kv = line.split()
        st[tag] = {k: int(v) for k, v in (x.split("=", 1) for x in kv)}
print(summary(data, cuts, kitty))
for tag in ("early", "later"):
    print("  %-6s %s, terminal bytes %s" % (tag, st.get(tag), read("raw_" + tag).strip()))
fails = []
def chk(name, ok, detail=""):
    print(("  ok " if ok else "FAIL ") + name + ("" if ok else "  -- " + detail))
    if not ok: fails.append(name)
g = lambda tag, k: (st.get(tag) or {}).get(k)
frame = max(1, (g("later", "ui_bytes") or 0) // max(1, g("later", "frames_sent") or 1))
ahead = (g("later", "ui_bytes") or 0) - int(read("raw_later").strip() or 0)
chk("the session has only the remote backend, and nothing marked it as encoding here",
    g("later", "local_backend") == 0 and g("later", "remote_backend") == 1 and g("later", "remote_mode") == 0,
    "local %s, remote %s, remote mode %s" % (g("later", "local_backend"), g("later", "remote_backend"), g("later", "remote_mode")))
chk("the gif plays: frames kept going out", (g("later", "frames_sent") or 0) - (g("early", "frames_sent") or 0) >= 3,
    "frames %s then %s" % (g("early", "frames_sent"), g("later", "frames_sent")))
chk("every frame is followed by a status request", g("later", "acks_sent") is not None
    and g("later", "frames_sent") - g("later", "acks_sent") <= 1,
    "frames %s, requests %s" % (g("later", "frames_sent"), g("later", "acks_sent")))
chk("the terminal answered and frames waited for it", (g("later", "acks_got") or 0) >= 3 and (g("later", "frames_held") or 0) > 0,
    "answers %s, frames held %s" % (g("later", "acks_got"), g("later", "frames_held")))
chk("the bytes written stay within a few frames of what the terminal got", ahead <= 6 * frame,
    "%d bytes ahead, a frame is %d" % (ahead, frame))
chk("kitty graphics reached the terminal", kitty > 0, "no kitty escape in the log")
chk("no escape sequence was cut", not cuts, "%d cut" % len(cuts))
chk("nvim and its terminal multiplexer stopped cleanly", os.environ.get("LEAK") == "0", "LEAK above")
print(("\nSTREAM-REMOTE: %d FAILED" % len(fails)) if fails else "\nSTREAM-REMOTE: ALL PASSED")
sys.exit(1 if fails else 0)
PY

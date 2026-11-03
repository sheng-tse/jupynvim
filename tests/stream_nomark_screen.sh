#!/usr/bin/env bash
# A terminal that answers status requests but not XTVERSION plays the first
# gif at once, and leaves nothing for the shell.
#
# Before the first gif frame of a session jupynvim sends a version query
# (XTVERSION) and waits for its answer, so that the terminal's answers to
# Neovim's own queries are not taken for the frames' (see
# lua/jupynvim/notebook/image.lua). tmux before 3.2 (Ubuntu 20.04's 3.0a,
# Debian 11's and Alpine 3.13's 3.1c) answers status requests but gives no
# answer to that query, and the query was given up only after 30 s, so the
# first gif of every session stood still all that time. Inside tmux jupynvim
# now asks the running tmux for its version once, and for a version before
# 3.2 starts with the query off.
#
# The editor believes it runs in tmux 3.1c: its environment names a tmux
# socket (nothing wraps the escapes: the passthrough is off), the module is
# told it is inside tmux (the passthrough switch would say otherwise), and
# the commands it runs for the version are stand-ins: the running server
# says 3.1c, the tmux binary on PATH says 3.5a (so the server decides). An
# interactive bash runs behind tests/lib/tty_relay.py --drop-xtversion (the
# terminal's answers to XTVERSION never reach the program, as if the terminal
# gave none) in a private tmux pane whose raw output is logged (pipe-pane).
# bash starts nvim on a notebook whose gif plays in view. The test counts the
# frames sent, then runs :qa! and reads what the shell gets. It fails when
# the gif sent fewer than 20 frames in the 8 s after it started, when a query
# was written or given up (the query is off from the start), when the shell
# got a terminal answer as input or shows one on its screen after the quit,
# or when an escape sequence was cut (tests/lib/escape_scan.py).
#
# Needs Neovim 0.12+ (nvim_ui_send), tmux and ImageMagick 7 (gif playback).
# JNV_STREAM_NVIM=/path/to/nvim runs another Neovim.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/core/target/release/jupynvim-core"
[ -x "$BIN" ] || { echo "SKIP stream_nomark: build core first ($BIN)"; exit 0; }
source "$(dirname "$0")/lib/tmux.sh"
NVIM_BIN="${JNV_STREAM_NVIM:-nvim}"
command -v magick >/dev/null || { echo "SKIP stream_nomark: no ImageMagick 7 (magick)"; exit 0; }
"$NVIM_BIN" --headless -u NONE -c 'lua io.stdout:write(vim.api.nvim_ui_send and "y" or "n")' -c 'qa!' 2>/dev/null \
  | grep -q y || { echo "SKIP stream_nomark: $NVIM_BIN has no nvim_ui_send (Neovim 0.12+)"; exit 0; }
WORK="$(mktemp -d "$TMPDIR/jupynvim_nomark.XXXXXX")"
S="jupy_nomark_$$"
cleanup() { jnv_tmux_stop; rm -rf "$WORK"; }
jnv_on_exit cleanup
mkdir -p "$WORK/state"

# 16 frames at 80 ms
( cd "$WORK" && for i in $(seq 0 15); do
    magick -size 480x320 gradient:'#1e3050-#402060' -fill "rgb($((i * 15)),200,$((240 - i * 15)))" \
      -draw "circle $((40 + i * 25)),160 $((40 + i * 25)),110" "f_$(printf %02d "$i").png" || exit 1
  done && magick -delay 8 -loop 0 f_*.png light.gif ) \
  || { echo "FAIL stream_nomark: ImageMagick could not make the gif"; exit 1; }

python3 -I - "$WORK" <<'PY'
import base64, json, os, sys
w = sys.argv[1]
gif = base64.b64encode(open(os.path.join(w, "light.gif"), "rb").read()).decode()
cells = [{"cell_type": "code", "id": "c1", "metadata": {}, "execution_count": 1, "source": "show_gif()",
          "outputs": [{"output_type": "display_data", "metadata": {},
                       "data": {"image/gif": gif, "text/plain": "<img>"}}]}]
json.dump({"cells": cells, "metadata": {"language_info": {"name": "python"}},
           "nbformat": 4, "nbformat_minor": 5}, open(os.path.join(w, "nb.ipynb"), "w"))
PY

# what the shell reads before each prompt: the input pending now or within
# the next SECS seconds, read raw and with no echo, logged as one line (a
# Python bytes literal)
cat > "$WORK/pending.py" <<'PY'
import os, select, sys, termios, time, tty
old = termios.tcgetattr(0)
tty.setraw(0, termios.TCSANOW)
end, got = time.monotonic() + float(sys.argv[2]), b""
while True:
    left = end - time.monotonic()
    if left <= 0:
        break
    if select.select([0], [], [], left)[0]:
        d = os.read(0, 4096)
        if not d:
            break
        got += d
termios.tcsetattr(0, termios.TCSADRAIN, old)
with open(sys.argv[1], "a") as f:
    f.write(repr(got) + "\n")
PY

# __stats(tag) appends the image writer's counters; addr names the editor,
# and ready is written once the gif animates (its clock runs from the start)
cat > "$WORK/init.lua" <<LUA
vim.opt.runtimepath:prepend("$ROOT")
vim.o.swapfile = false
vim.o.termguicolors = true
-- the editor's environment only (the UI process started before this)
vim.env.TMUX = "$WORK/fake-tmux-socket,1,0"
vim.env.JUPYNVIM_DISABLE_TMUX_PASSTHROUGH = "1"
require("jupynvim").setup({ core_path = "$BIN", auto_venv = false })
local I = require("jupynvim.notebook.image")
-- inside tmux, and what the editor runs to learn the version (before the
-- backend is attached): the running server's answer
I._in_tmux = true
I._tmux_server_version_cmd = { "sh", "-c", "echo 3.1c" }
I._tmux_version_cmd = { "sh", "-c", "echo tmux 3.5a" }
local function put(name, s, mode)
  local f = io.open("$WORK/" .. name, mode or "a"); f:write(s); f:close()
end
put("addr", vim.v.servername, "w")
put("pid", tostring(vim.fn.getpid()), "w")
function _G.__stats(tag)
  put("stats", string.format("%s frames_sent=%d marks_sent=%d marks_lost=%d mark_off=%d mark_seen=%d acks_sent=%d acks_got=%d\n",
    tag, I._frames_sent or 0, I._marks_sent or 0, I._marks_lost or 0, I._mark_off and 1 or 0, I._mark_seen and 1 or 0,
    I._acks_sent or 0, I._acks_got or 0))
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
LUA

q() { printf %q "$1"; }
cat > "$WORK/run.sh" <<SH
while [ ! -e "$WORK/go" ]; do sleep 0.02; done
exec python3 -I "$ROOT/tests/lib/tty_relay.py" --drop-xtversion -- \
  env -u TMUX -u TMUX_PANE PS1='SH\$ ' PROMPT_COMMAND='python3 -I "$WORK/pending.py" "$WORK/shellin" 2' \
  bash --norc --noprofile -i
SH
tmux new-session -d -s "$S" -x 160 -y 50 "sh $(q "$WORK/run.sh")"
tmux pipe-pane -t "=$S:" -O "cat > $(q "$WORK/raw.bin")"
touch "$WORK/go"
CAP() { tmux capture-pane -t "=$S:" -p; }
p=0
prompt() { p=$((p + 1)); jnv_wait_lines "$WORK/shellin" "$p" 30 || echo "no prompt $p ($1)"; CAP > "$WORK/screen_$1.txt" 2>/dev/null; }
n=0
rstats() {
  n=$((n + 1))
  "$NVIM_BIN" --server "$(cat "$WORK/addr")" --remote-expr "luaeval('_G.__stats(\"$1\") or 0')" >/dev/null 2>&1
  jnv_wait_lines "$WORK/stats" "$n" 15 || echo "stats $1: no answer"
}
prompt start
tmux send-keys -t "=$S:" "env TERM=xterm-256color XDG_STATE_HOME=$(q "$WORK/state") $(q "$NVIM_BIN") -i NONE -u $(q "$WORK/init.lua") $(q "$WORK/nb.ipynb")" Enter
if ! jnv_wait_file_eq "$WORK/ready" 1 60; then
  echo "FAIL the gif never animated; the screen:"
  CAP | LC_ALL=C sed -e '/^ *$/d' -e 's/^/  | /' | tail -n 20
  jnv_stop_session "$S"; jnv_tmux_stop
  printf '\nSTREAM-NOMARK: 1 FAILED (stopped early)\n'
  exit 1
fi
rstats early
sleep 8
rstats later
tmux send-keys -t "=$S:" Escape ":qa!" Enter
prompt quit
ep="$(cat "$WORK/pid" 2>/dev/null)"
for _ in $(seq 1 100); do
  { [ -n "$ep" ] && ps -p "$ep" -o command= 2>/dev/null | grep -qF "$WORK"; } || break
  sleep 0.1
done
if [ -n "$ep" ] && ps -p "$ep" -o command= 2>/dev/null | grep -qF "$WORK"; then
  echo "the editor did not quit; stopping pid $ep"
  kill "$ep" 2>/dev/null
  echo "leftover" >> "$WORK/leftover"
fi
tmux send-keys -t "=$S:" "exit" Enter
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
import ast, os, re, sys
sys.dont_write_bytecode = True
sys.path.insert(0, os.environ["LIB"])
from escape_scan import scan, summary
W = os.environ["WORK"]
def read(name):
    p = os.path.join(W, name)
    return open(p, encoding="utf-8", errors="replace").read() if os.path.exists(p) else ""
data = open(os.path.join(W, "raw.bin"), "rb").read() if os.path.exists(os.path.join(W, "raw.bin")) else b""
cuts, kitty = scan(data)
shellin = []
for line in read("shellin").splitlines():
    try: shellin.append(ast.literal_eval(line))
    except (ValueError, SyntaxError): shellin.append(line.encode())
st = {}
for line in read("stats").splitlines():
    if line.strip():
        tag, *kv = line.split()
        st[tag] = {k: int(v) for k, v in (x.split("=", 1) for x in kv)}
print(summary(data, cuts, kitty))
print("  shell input before each prompt: %r" % shellin)
for tag in ("early", "later"):
    print("  %-6s %s" % (tag, st.get(tag)))
fails = []
def chk(name, ok, detail=""):
    print(("  ok " if ok else "FAIL ") + name + ("" if ok else "  -- " + detail))
    if not ok: fails.append(name)
g = lambda tag, k: (st.get(tag) or {}).get(k)
chk("the gif plays at once: at least 20 frames in the 8 s after it started",
    g("later", "frames_sent") is not None and g("later", "frames_sent") >= 20, "frames sent %s" % g("later", "frames_sent"))
chk("no version query was written or waited for (markers off from the start)",
    g("later", "marks_sent") == 0 and g("later", "marks_lost") == 0 and g("later", "mark_off") == 1
    and g("later", "mark_seen") == 0,
    "marks sent %s, given up %s, off %s, seen %s" % (g("later", "marks_sent"), g("later", "marks_lost"),
                                                    g("later", "mark_off"), g("later", "mark_seen")))
chk("the shell was ready (its first prompt read no input)", len(shellin) >= 1 and shellin[0] == b"",
    "first prompt: %r" % (shellin[:1],))
chk("after :qa! the shell got no terminal answer as input", len(shellin) >= 2 and shellin[1] == b"",
    "the shell read %r" % (shellin[1:2],))
tail = [l.rstrip() for l in read("screen_quit.txt").splitlines() if l.strip()][-4:]
answer = re.compile(r"\^\[|\x1b|\[\?[\d;]*c|\[[03]n")
chk("after :qa! the shell's screen shows no terminal answer and an empty prompt",
    bool(tail) and tail[-1] == "SH$" and not any(answer.search(l) for l in tail),
    "the screen's last lines:\n" + "\n".join("    | " + l for l in tail))
chk("kitty graphics reached the terminal", kitty > 0, "no kitty escape in the log")
chk("no escape sequence was cut", not cuts, "%d cut" % len(cuts))
chk("the editor quit", not read("leftover"), "stopped by pid")
chk("nvim and its terminal multiplexer stopped cleanly", os.environ.get("LEAK") == "0", "LEAK above")
print(("\nSTREAM-NOMARK: %d FAILED" % len(fails)) if fails else "\nSTREAM-NOMARK: ALL PASSED")
sys.exit(1 if fails else 0)
PY

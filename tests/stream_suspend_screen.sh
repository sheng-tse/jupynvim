#!/usr/bin/env bash
# A suspended or detached Neovim writes nothing to the terminal, and a
# terminal attached again with nvim --remote-ui shows the images.
#
# CTRL-Z stops Neovim's UI and gives the terminal back to the shell, while
# the editor process runs on with its timers; so does :detach, after which
# the way back is nvim --remote-ui. A gif in view used to keep sending its
# frames on the editor's stderr, straight into the terminal the shell now
# draws on (hundreds of KB in a few seconds, each write able to cut the
# shell's own output). Now nothing is written while no terminal shows the
# editor, the gif's clock runs on, and the gif plays again once a terminal
# shows the editor: after fg, and after nvim --remote-ui in the terminal the
# editor was started in. Neovim 0.11 lists such a UI without stdout_tty, so
# jupynvim asks the system where it runs.
#
# An interactive bash runs in a private tmux pane whose raw output is logged
# (pipe-pane); it starts nvim on a notebook whose gif is in view. The test
# presses CTRL-Z, counts the bytes the terminal gets while the shell has it,
# runs fg and checks that the gif plays again. Then :detach, the bytes the
# terminal gets meanwhile, nvim --remote-ui in the same pane (the gif shows
# again), :detach again, and nvim --remote-ui in a second session (another
# pty, logged too). It fails when anything reached the terminal while nvim
# was suspended or detached, when the editor's memory grew while suspended,
# when the gif's clock stopped or it did not play after fg or after the
# reattach in the same terminal, when anything reached the first terminal
# while the UI was the other one, when that other terminal did not get the
# gif with nvim_ui_send (Neovim 0.12+) or the writes were not held without
# it (Neovim 0.11, where they could only reach the first terminal), or (with
# nvim_ui_send) when an escape sequence was cut (tests/lib/escape_scan.py).
#
# Needs tmux and ImageMagick 7 (gif playback). JNV_STREAM_NVIM=/path/to/nvim
# runs another Neovim (0.11 has no in-order writer: there the cut count is
# only printed); JNV_STREAM_HOLD=S sets how long nvim stays suspended
# (default 8 s; a value that is not a whole number above 0 is ignored).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/core/target/release/jupynvim-core"
[ -x "$BIN" ] || { echo "SKIP stream_suspend: build core first ($BIN)"; exit 0; }
source "$(dirname "$0")/lib/tmux.sh"
NVIM_BIN="${JNV_STREAM_NVIM:-nvim}"
HOLD="${JNV_STREAM_HOLD:-8}"
case "$HOLD" in ''|*[!0-9]*) HOLD=0 ;; esac
HOLD=$((10#$HOLD))
[ "$HOLD" -gt 0 ] || { echo "stream_suspend: JNV_STREAM_HOLD=${JNV_STREAM_HOLD:-} is not a whole number above 0; using 8"; HOLD=8; }
command -v magick >/dev/null || { echo "SKIP stream_suspend: no ImageMagick 7 (magick)"; exit 0; }
UI_SEND=""
"$NVIM_BIN" --headless -u NONE -c 'lua io.stdout:write(vim.api.nvim_ui_send and "y" or "n")' -c 'qa!' 2>/dev/null \
  | grep -q y && UI_SEND=1
WORK="$(mktemp -d "$TMPDIR/jupynvim_suspend.XXXXXX")"
S="jupy_suspend_$$"
cleanup() { jnv_tmux_stop; rm -rf "$WORK"; }
jnv_on_exit cleanup
mkdir -p "$WORK/state"

# 16 frames at 80 ms
( cd "$WORK" && for i in $(seq 0 15); do
    magick -size 480x320 gradient:'#1e3050-#402060' -fill "rgb($((i * 15)),200,$((240 - i * 15)))" \
      -draw "circle $((40 + i * 25)),160 $((40 + i * 25)),110" "f_$(printf %02d "$i").png" || exit 1
  done && magick -delay 8 -loop 0 f_*.png anim.gif ) \
  || { echo "FAIL stream_suspend: ImageMagick could not make the gif"; exit 1; }

python3 - "$WORK" <<'PY'
import base64, json, os, sys
w = sys.argv[1]
gif = base64.b64encode(open(os.path.join(w, "anim.gif"), "rb").read()).decode()
cells = [{"cell_type": "code", "id": "c1", "metadata": {}, "execution_count": 1, "source": "show_gif()",
          "outputs": [{"output_type": "display_data", "metadata": {},
                       "data": {"image/gif": gif, "text/plain": "<img>"}}]}]
json.dump({"cells": cells, "metadata": {"language_info": {"name": "python"}},
           "nbformat": 4, "nbformat_minor": 5}, open(os.path.join(w, "nb.ipynb"), "w"))
PY

# __stats(tag) appends the image writer's counters (held: writes are held
# now; uis: UIs attached); pid, addr (the editor's address, for --remote-ui)
# and ready are written once, ready when the gif animates (a placement whose
# frame timer ticked); events gets a line for each suspend, resume, UI attach
# and UI leave
cat > "$WORK/init.lua" <<LUA
vim.opt.runtimepath:prepend("$ROOT")
vim.o.swapfile = false
vim.o.termguicolors = true
require("jupynvim").setup({ core_path = "$BIN", auto_venv = false })
local I = require("jupynvim.notebook.image")
for name, v in pairs({ pid = tostring(vim.fn.getpid()), addr = vim.v.servername }) do
  local f = io.open("$WORK/" .. name, "w"); f:write(v); f:close()
end
function _G.__stats(tag)
  local f = io.open("$WORK/stats", "a")
  f:write(string.format("%s tty_bytes=%d frames_sent=%d frames_skipped=%d held_n=%d held=%d uis=%d\n",
    tag, I._tty_bytes or 0, I._frames_sent or 0, I._frames_skipped or 0, I._held_n or 0,
    (I._writes_held and I._writes_held()) and 1 or 0, #vim.api.nvim_list_uis()))
  f:close()
end
vim.api.nvim_create_autocmd({ "VimSuspend", "VimResume", "UIEnter", "UILeave" }, { callback = function(ev)
  local f = io.open("$WORK/events", "a"); f:write(ev.event .. "\n"); f:close()
end })
local ready = vim.uv.new_timer()
ready:start(100, 100, vim.schedule_wrap(function()
  for _, p in pairs(I._placements) do
    if p.timer and (p.frame_idx or 1) > 1 then
      ready:stop()
      local f = io.open("$WORK/ready", "w"); f:write("1"); f:close()
      return
    end
  end
end))
LUA

# an interactive shell with job control, as the user's; the pane's raw
# output (what the terminal got) is logged from its first byte
tmux new-session -d -s "$S" -x 160 -y 50 "env -u TMUX -u TMUX_PANE PS1='SH\$ ' bash --norc --noprofile -i"
tmux pipe-pane -t "=$S:" -O "cat > $(printf %q "$WORK/raw.bin")"
CAP() { tmux capture-pane -t "=$S:" -p; }
# CAPWAIT FILE WANT: the screen once it shows WANT, or as it is after 15 s
CAPWAIT() {
  local end=$((SECONDS + 15)) c
  while :; do
    c="$(CAP)"
    [[ "$c" == *"$2"* ]] && break
    [ "$SECONDS" -ge "$end" ] && break
    sleep 0.1
  done
  printf '%s\n' "$c" > "$1"
}
# HASLINE FILE WORD: FILE has a line that is exactly WORD
hasline() { grep -qx "$2" "$1" 2>/dev/null; }
waitline() { local end=$((SECONDS + 15)); until hasline "$1" "$2"; do [ "$SECONDS" -ge "$end" ] && return 1; sleep 0.1; done; }
n=0
stats() { n=$((n + 1)); tmux send-keys -t "=$S:" ":lua __stats('$1')" Enter; jnv_wait_lines "$WORK/stats" "$n" 15 || echo "stats $1: no answer"; }
pane_bytes() { wc -c < "$WORK/raw.bin" | tr -d ' '; }
# the log has caught up with what the terminal got: its size held for 0.4 s
# (at most 3 s; a writer that never stops is what the check below finds)
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
rss() { ps -o rss= -p "$(cat "$WORK/pid" 2>/dev/null)" 2>/dev/null | tr -d ' '; }
# kitty_n FILE OFFSET: the Kitty graphics escapes in the raw log FILE from
# byte OFFSET on
kitty_n() {
  python3 -I - "$1" "$2" <<'PY'
import os, sys
p, off = sys.argv[1], int(sys.argv[2])
print(open(p, "rb").read()[off:].count(b"\x1b_G") if os.path.exists(p) else 0)
PY
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
  printf '\nSTREAM-SUSPEND: %d FAILED (stopped early)\n' "$fails"
  exit 1
}

CAPWAIT "$WORK/cap_shell.txt" 'SH$'
# the paths are quoted for the shell in the pane (bash, as printf %q quotes)
q() { printf %q "$1"; }
tmux send-keys -t "=$S:" "env TERM=xterm-256color XDG_STATE_HOME=$(q "$WORK/state") $(q "$NVIM_BIN") -i NONE -u $(q "$WORK/init.lua") $(q "$WORK/nb.ipynb")" Enter
jnv_wait_file_eq "$WORK/ready" 1 40 || stop_early "the gif started to animate  -- not within 40 s; the screen:"
stats pre

# CTRL-Z: once the shell shows the stopped job, the terminal is the shell's
tmux send-keys -t "=$S:" C-z
waitline "$WORK/events" UILeave || echo "no UILeave after CTRL-Z"
CAPWAIT "$WORK/cap_suspended.txt" "Stopped"
settle
s0="$(pane_bytes)"; r0="$(rss)"
sleep "$HOLD"
s1="$(pane_bytes)"; r1="$(rss)"
echo "suspended pane_bytes=$s0 rss_kb=$r0" >> "$WORK/samples"
echo "suspended_end pane_bytes=$s1 rss_kb=$r1" >> "$WORK/samples"

# fg: the gif plays again
tmux send-keys -t "=$S:" "fg" Enter
waitline "$WORK/events" VimResume || echo "no VimResume after fg"
stats resumed
sleep 3
stats post
# the gif's own frames since the suspend ended (nvim's redraw alone writes
# no graphics)
echo "post pane_bytes=$(pane_bytes) kitty=$(kitty_n "$WORK/raw.bin" "$s1")" >> "$WORK/samples"

# :detach: nvim's UI quits and the shell has the terminal again, while the
# editor runs on with no UI and its stderr on this terminal. From here the
# editor is asked for its counters through its address (rstats), and the
# way back is nvim --remote-ui.
ADDR="$(cat "$WORK/addr" 2>/dev/null)"
rstats() {
  n=$((n + 1))
  "$NVIM_BIN" --server "$ADDR" --remote-expr "luaeval('_G.__stats(\"$1\") or 0')" >/dev/null 2>&1
  jnv_wait_lines "$WORK/stats" "$n" 15 || echo "stats $1: no answer"
}
# waitev EVENT N: events has N lines that are exactly EVENT
waitev() {
  local end=$((SECONDS + 15))
  until [ "$(grep -cx "$1" "$WORK/events" 2>/dev/null)" -ge "$2" ]; do
    [ "$SECONDS" -ge "$end" ] && return 1; sleep 0.1
  done
}
tmux send-keys -t "=$S:" Escape ":detach" Enter
waitev UILeave 2 || echo "no UILeave after :detach"
settle
d0="$(pane_bytes)"; rstats detached
sleep 2
d1="$(pane_bytes)"; rstats detached_end
echo "detached pane_bytes=$d0" >> "$WORK/samples"
echo "detached_end pane_bytes=$d1" >> "$WORK/samples"

# nvim --remote-ui in this terminal, the one the editor was started in: the
# gif shows again (its frames go out, and the terminal gets them)
tmux send-keys -t "=$S:" "env TERM=xterm-256color XDG_STATE_HOME=$(q "$WORK/state") $(q "$NVIM_BIN") --remote-ui --server $(q "$ADDR")" Enter
waitev UIEnter 3 || echo "no UIEnter after --remote-ui"
rstats here_start
sleep 2.5
rstats here
echo "here pane_bytes=$(pane_bytes) kitty=$(kitty_n "$WORK/raw.bin" "$d1")" >> "$WORK/samples"

# that UI detaches too, and nvim --remote-ui attaches from another terminal
# (a second session with its own pty, raw output logged as well): nothing
# reaches the first terminal, where the shell draws again. With nvim_ui_send
# the other terminal gets the gif; on Neovim 0.11 the writes can only go to
# the first terminal, so they are held.
tmux send-keys -t "=$S:" Escape ":detach" Enter
waitev UILeave 3 || echo "no UILeave after the second :detach"
settle
e0="$(pane_bytes)"
cat > "$WORK/other.sh" <<SH
while [ ! -e "$WORK/go_b" ]; do sleep 0.02; done
exec env -u TMUX -u TMUX_PANE TERM=xterm-256color XDG_STATE_HOME="$WORK/state" "$NVIM_BIN" --remote-ui --server "$ADDR"
SH
tmux new-session -d -s "${S}b" -x 160 -y 50 "sh $(q "$WORK/other.sh")"
tmux pipe-pane -t "=${S}b:" -O "cat > $(q "$WORK/raw_b.bin")"
touch "$WORK/go_b"
waitev UIEnter 4 || echo "no UIEnter from the other terminal"
rstats elsewhere_start
sleep 2.5
rstats elsewhere
e1="$(pane_bytes)"
echo "elsewhere_start pane_bytes=$e0" >> "$WORK/samples"
echo "elsewhere pane_bytes=$e1 kitty_b=$(kitty_n "$WORK/raw_b.bin" 0)" >> "$WORK/samples"

# the editor is told to quit through its address; one that does not is ours
# to stop (by pid)
"$NVIM_BIN" --server "$ADDR" --remote-send '<C-\><C-N>:qa!<CR>' >/dev/null 2>&1
ep="$(cat "$WORK/pid" 2>/dev/null)"
for _ in $(seq 1 100); do
  { [ -n "$ep" ] && ps -p "$ep" -o command= 2>/dev/null | grep -qF "$WORK"; } || break
  sleep 0.1
done
if [ -n "$ep" ] && ps -p "$ep" -o command= 2>/dev/null | grep -qF "$WORK"; then
  echo "the detached editor did not quit; stopping pid $ep"
  kill "$ep" 2>/dev/null
  echo "leftover pid=$ep" >> "$WORK/samples"
fi
for _ in $(seq 1 100); do tmux has-session -t "=${S}b" 2>/dev/null || break; sleep 0.1; done
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
jnv_stop_session "${S}b" || leak=1
jnv_stop_session "$S" || leak=1
jnv_tmux_stop || leak=1

WORK="$WORK" HOLD="$HOLD" UI_SEND="$UI_SEND" LEAK="$leak" LIB="$ROOT/tests/lib" python3 -I - <<'PY'
import os, sys
sys.dont_write_bytecode = True
sys.path.insert(0, os.environ["LIB"])
from escape_scan import scan, summary
W = os.environ["WORK"]
def read(name):
    p = os.path.join(W, name)
    return open(p, encoding="utf-8", errors="replace").read() if os.path.exists(p) else ""
def raw(name):
    p = os.path.join(W, name)
    return open(p, "rb").read() if os.path.exists(p) else b""
data, data_b = raw("raw.bin"), raw("raw_b.bin")
cuts, kitty = scan(data)
cuts_b, kitty_b = scan(data_b)
st, sm = {}, {}
for line in read("stats").splitlines():
    if line.strip():
        tag, *kv = line.split()
        st[tag] = {k: int(v) for k, v in (x.split("=", 1) for x in kv)}
for line in read("samples").splitlines():
    if line.strip():
        tag, *kv = line.split()
        sm[tag] = {k: int(v) for k, v in (x.split("=", 1) for x in kv) if v.lstrip("-").isdigit()}
events = read("events").split()
def g(tag, k): return st.get(tag, {}).get(k)
def s(tag, k): return sm.get(tag, {}).get(k)
print(summary(data, cuts, kitty))
print("  other terminal: " + summary(data_b, cuts_b, kitty_b))
for tag in ("pre", "resumed", "post", "detached", "detached_end", "here_start", "here", "elsewhere_start", "elsewhere"):
    print("  %-15s %s" % (tag, st.get(tag)))
for tag in ("suspended", "suspended_end", "post", "detached", "detached_end", "here", "elsewhere_start", "elsewhere"):
    print("  %-15s %s" % (tag, sm.get(tag)))
print("  events %s" % " ".join(events))

fails = []
def chk(name, ok, detail=""):
    print(("  ok " if ok else "FAIL ") + name + ("" if ok else "  -- " + detail))
    if not ok: fails.append(name)
chk("the gif played before the suspend", (g("pre", "frames_sent") or 0) > 0, str(st.get("pre")))
# the UI left after the suspend and before the resume (the final :qa! and
# the :detach steps add UILeave events of their own later)
after = events[events.index("VimSuspend") + 1:] if "VimSuspend" in events else []
before_resume = after[:after.index("VimResume")] if "VimResume" in after else after
chk("CTRL-Z suspended nvim and gave the shell the terminal",
    "UILeave" in before_resume and "Stopped" in read("cap_suspended.txt"),
    "events %s" % events)
a, b = s("suspended", "pane_bytes"), s("suspended_end", "pane_bytes")
chk("nothing reached the terminal while nvim was suspended (%s s)" % os.environ["HOLD"],
    None not in (a, b) and b == a, "%s bytes" % (None if None in (a, b) else b - a))
r0, r1 = s("suspended", "rss_kb"), s("suspended_end", "rss_kb")
chk("the editor's memory stayed flat while suspended (under 10 MB more)",
    None not in (r0, r1) and r1 - r0 < 10 * 1024, "rss %s -> %s KB" % (r0, r1))
chk("the gif's clock ran on while suspended",
    (g("resumed", "frames_skipped") or 0) > (g("pre", "frames_skipped") or 0),
    "frames skipped %s -> %s" % (g("pre", "frames_skipped"), g("resumed", "frames_skipped")))
chk("after fg the gif played again (its frames reached the terminal)",
    "VimResume" in events and (g("post", "frames_sent") or 0) > (g("resumed", "frames_sent") or 0)
    and (s("post", "kitty") or 0) > 0,
    "frames sent %s -> %s, %s kitty escapes after fg" % (g("resumed", "frames_sent"), g("post", "frames_sent"),
                                                        s("post", "kitty")))
d0, d1 = s("detached", "pane_bytes"), s("detached_end", "pane_bytes")
chk("after :detach nothing reached the terminal (2 s), and the gif's clock ran on",
    None not in (d0, d1) and d1 == d0 and g("detached", "uis") == 0
    and (g("detached_end", "frames_skipped") or 0) > (g("detached", "frames_skipped") or 0),
    "%s bytes, uis %s, frames skipped %s -> %s" % (None if None in (d0, d1) else d1 - d0, g("detached", "uis"),
                                                  g("detached", "frames_skipped"), g("detached_end", "frames_skipped")))
chk("nvim --remote-ui in the terminal nvim was started in shows the gif again",
    (g("here", "frames_sent") or 0) > (g("here_start", "frames_sent") or 0) and g("here", "held") == 0
    and g("here", "uis") == 1 and (s("here", "kitty") or 0) > 0,
    "frames sent %s -> %s, held %s, uis %s, %s kitty escapes since the reattach" % (
        g("here_start", "frames_sent"), g("here", "frames_sent"), g("here", "held"), g("here", "uis"), s("here", "kitty")))
e0, e1 = s("elsewhere_start", "pane_bytes"), s("elsewhere", "pane_bytes")
chk("nvim --remote-ui from another terminal: nothing reached the first one, where the shell draws",
    None not in (e0, e1) and e1 == e0 and g("elsewhere", "uis") == 1,
    "%s bytes, uis %s" % (None if None in (e0, e1) else e1 - e0, g("elsewhere", "uis")))
if os.environ.get("UI_SEND"):
    chk("and the other terminal shows the gif (nvim_ui_send reaches it)",
        (g("elsewhere", "frames_sent") or 0) > (g("elsewhere_start", "frames_sent") or 0)
        and g("elsewhere", "held") == 0 and (s("elsewhere", "kitty_b") or 0) > 0,
        "frames sent %s -> %s, held %s, %s kitty escapes there" % (
            g("elsewhere_start", "frames_sent"), g("elsewhere", "frames_sent"), g("elsewhere", "held"),
            s("elsewhere", "kitty_b")))
    chk("no escape sequence was cut", not cuts and not cuts_b, "%d cut, %d in the other terminal" % (len(cuts), len(cuts_b)))
else:
    # without nvim_ui_send the writes can only go to the first terminal
    chk("and on Neovim 0.11 the editor holds its writes (they could only reach the first terminal)",
        g("elsewhere", "held") == 1 and g("elsewhere", "tty_bytes") == g("elsewhere_start", "tty_bytes")
        and (g("elsewhere", "frames_skipped") or 0) > (g("elsewhere_start", "frames_skipped") or 0)
        and (s("elsewhere", "kitty_b") or 0) == 0,
        "held %s, editor bytes %s -> %s, frames skipped %s -> %s, %s kitty escapes there" % (
            g("elsewhere", "held"), g("elsewhere_start", "tty_bytes"), g("elsewhere", "tty_bytes"),
            g("elsewhere_start", "frames_skipped"), g("elsewhere", "frames_skipped"), s("elsewhere", "kitty_b")))
    print("  (no nvim_ui_send: %d cut sequences, %d in the other terminal, not checked)" % (len(cuts), len(cuts_b)))
chk("nvim and its terminal multiplexer stopped cleanly", os.environ.get("LEAK") == "0", "LEAK above")
print(("\nSTREAM-SUSPEND: %d FAILED" % len(fails)) if fails else "\nSTREAM-SUSPEND: ALL PASSED")
sys.exit(1 if fails else 0)
PY

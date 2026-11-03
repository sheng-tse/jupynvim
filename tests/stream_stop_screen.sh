#!/usr/bin/env bash
# The terminal's answers never reach the shell when Neovim stops.
#
# Each gif frame jupynvim sends with nvim_ui_send is followed by a request
# the terminal answers once it has read the frame (Neovim 0.12+). When
# Neovim's UI stops (CTRL-Z, :detach, :qa!) it sends a DA1 request of its own
# and reads the terminal until the first DA1 answer comes (for a quit or a
# :detach at most a second), then stops reading; whatever the terminal
# answers after that goes to the program that reads the terminal next, the
# user's shell, which shows it on its command line ("^[[?1;2;4c", or
# "1;2;4c" in front of what the user types next). With a DA1 request after
# each frame, a frame's answer still on its way ended the UI's wait early,
# and the UI's own answer reached the shell. And frames still on their way
# to a terminal behind a slow link can outlast that second. Now the frames'
# request is DSR, which the UI never takes for its own, and before the UI
# stops the requests in flight are answered (VimLeavePre, VimSuspend, the
# UILeave of a :detach).
#
# An interactive bash runs behind tests/lib/tty_relay.py in a private tmux
# pane whose raw output is logged (pipe-pane). Before each prompt the shell
# reads, raw and without echo, whatever input is pending for a while and
# logs it. bash starts nvim on a notebook whose gif plays in view; the test
# presses CTRL-Z, runs fg, runs :detach, attaches again with nvim
# --remote-ui and runs :qa!. Twice, each time with a fresh pane:
#   A  the terminal answers 250 ms late, 50 ms apart (one request at a time
#      from a slow link), output passes at once; a light gif
#   B  output passes at 60 KB/s from a buffer of any size (a link with
#      large buffers, as over SSH: Neovim's writes finish at once, the
#      terminal reads them seconds later); a heavy gif (about 115 KB a frame,
#      so about 2 s on the way)
#   C  the same at 25 KB/s: a frame needs 4.6 s, more than the 3 s a drain
#      used to wait, so the drain follows the round trip it measured
#   D  the same link and gif as C, but each stop comes right after the FIRST
#      frame the editor sent after fg and after the reattach: the books start
#      over at those, so the one round trip measured since is the version
#      query's, short (little is written before it), while that frame needs
#      4.6 s. The drain rests on what the session has seen of the link.
# Each stop is sent right after the gif sent a frame, so in phases B, C and D
# that whole frame is still on its way: longer than the second Neovim's UI
# waits.
# It fails when the shell got a terminal answer as input or shows one on
# its screen after any stop, when no frame request was in flight when the UI
# stopped (the run then proves nothing; in D also when the frame's answer had
# come, so the link was measured again), when the gif did not play again
# after fg or after the reattach, or when an escape sequence was cut
# (tests/lib/escape_scan.py).
#
# Needs Neovim 0.12+ (nvim_ui_send), tmux and ImageMagick 7 (gif playback).
# JNV_STREAM_NVIM=/path/to/nvim runs another Neovim.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/core/target/release/jupynvim-core"
[ -x "$BIN" ] || { echo "SKIP stream_stop: build core first ($BIN)"; exit 0; }
source "$(dirname "$0")/lib/tmux.sh"
NVIM_BIN="${JNV_STREAM_NVIM:-nvim}"
command -v magick >/dev/null || { echo "SKIP stream_stop: no ImageMagick 7 (magick)"; exit 0; }
"$NVIM_BIN" --headless -u NONE -c 'lua io.stdout:write(vim.api.nvim_ui_send and "y" or "n")' -c 'qa!' 2>/dev/null \
  | grep -q y || { echo "SKIP stream_stop: $NVIM_BIN has no nvim_ui_send (Neovim 0.12+)"; exit 0; }
WORK="$(mktemp -d "$TMPDIR/jupynvim_stop.XXXXXX")"
cleanup() { jnv_tmux_stop; rm -rf "$WORK"; }
jnv_on_exit cleanup

# A: 16 frames at 80 ms; B: 12 frames at 40 ms, each with a block of noise
# PNG cannot squeeze (about 115 KB of escape a frame)
( cd "$WORK" && for i in $(seq 0 15); do
    magick -size 480x320 gradient:'#1e3050-#402060' -fill "rgb($((i * 15)),200,$((240 - i * 15)))" \
      -draw "circle $((40 + i * 25)),160 $((40 + i * 25)),110" "f_$(printf %02d "$i").png" || exit 1
  done && magick -delay 8 -loop 0 f_*.png light.gif \
  && for i in $(seq 0 11); do
    magick -size 640x480 gradient:'#203040-#506070' \( -size 320x240 xc: -seed $((i + 1)) +noise Random \) \
      -geometry +$((i * 20))+$((i * 10)) -composite -depth 8 "h_$(printf %02d "$i").png" || exit 1
  done && magick -delay 4 -loop 0 h_*.png heavy.gif ) \
  || { echo "FAIL stream_stop: ImageMagick could not make the gifs"; exit 1; }

python3 - "$WORK" <<'PY'
import base64, json, os, sys
w = sys.argv[1]
for name in ("light", "heavy"):
    gif = base64.b64encode(open(os.path.join(w, name + ".gif"), "rb").read()).decode()
    cells = [{"cell_type": "code", "id": "c1", "metadata": {}, "execution_count": 1, "source": "show_gif()",
              "outputs": [{"output_type": "display_data", "metadata": {},
                           "data": {"image/gif": gif, "text/plain": "<img>"}}]}]
    json.dump({"cells": cells, "metadata": {"language_info": {"name": "python"}},
               "nbformat": 4, "nbformat_minor": 5}, open(os.path.join(w, name + ".ipynb"), "w"))
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

# The test's own autocmds come first (before jupynvim's), so stops logs the
# requests in flight as each stop begins: at VimSuspend and VimLeavePre, and
# at the UILeave of a :detach (which has no event before it). __stats(tag)
# appends the image writer's counters; addr names the editor, and ready is
# written once the gif animates. JNV_PHASE names the phase's directory.
cat > "$WORK/init.lua" <<LUA
vim.opt.runtimepath:prepend("$ROOT")
vim.o.swapfile = false
vim.o.termguicolors = true
local D = "$WORK/" .. vim.env.JNV_PHASE
local I
local function put(name, s, mode)
  local f = io.open(D .. "/" .. name, mode or "a"); f:write(s); f:close()
end
-- the frame requests not answered yet, as jupynvim counts them (before this
-- fix only the totals asked and answered exist)
-- and the longest wait for an answer since the books started over (quiet)
-- and in the session (link), -1 where they are not counted
local function books()
  if I and I._acks_info then
    local a = I._acks_info()
    return a.n, a.quiet or -1, a.link or -1
  end
  return I and ((I._acks_sent or 0) - (I._acks_got or 0)) or -1, -1, -1
end
vim.api.nvim_create_autocmd("VimSuspend", { callback = function() put("stops", ("suspend in_flight=%d quiet=%d link=%d\n"):format(books())) end })
vim.api.nvim_create_autocmd("VimLeavePre", { callback = function() put("stops", ("quit in_flight=%d quiet=%d link=%d\n"):format(books())) end })
vim.api.nvim_create_autocmd("UILeave", { callback = function()
  if vim.g.jnv_detaching then vim.g.jnv_detaching = nil; put("stops", ("detach in_flight=%d quiet=%d link=%d\n"):format(books())) end
end })
vim.api.nvim_create_autocmd("UIEnter", { callback = function() put("events", "UIEnter\n") end })
require("jupynvim").setup({ core_path = "$BIN", auto_venv = false })
I = require("jupynvim.notebook.image")
put("addr", vim.v.servername, "w")
put("pid", tostring(vim.fn.getpid()), "w")
function _G.__stats(tag)
  put("stats", string.format("%s frames_sent=%d acks_sent=%d acks_got=%d\n",
    tag, I._frames_sent or 0, I._acks_sent or 0, I._acks_got or 0))
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
# phase NAME GIF PENDING PLAY RELAY_ARGS...: the scenario in a fresh pane;
# PENDING is how long the shell reads pending input before each prompt, PLAY
# how long the gif is given to play again after fg and after the reattach.
# With FIRST set (phase D) the :detach and the :qa! come right after the
# first frame the editor sent after fg and after the reattach instead
phase() {
  local name="$1" gif="$2" pend="$3" play="$4"; shift 4
  local P="$WORK/$name" S="jupy_stop_${name}_$$" n=0 p=0 addr
  mkdir -p "$P/state"
  cat > "$P/run.sh" <<SH
while [ ! -e "$P/go" ]; do sleep 0.02; done
exec python3 -I "$ROOT/tests/lib/tty_relay.py" $* -- \
  env -u TMUX -u TMUX_PANE PS1='SH\$ ' PROMPT_COMMAND='python3 -I "$WORK/pending.py" "$P/shellin" $pend' \
  bash --norc --noprofile -i
SH
  tmux new-session -d -s "$S" -x 160 -y 50 "sh $(q "$P/run.sh")"
  tmux pipe-pane -t "=$S:" -O "cat > $(q "$P/raw.bin")"
  touch "$P/go"
  CAP() { tmux capture-pane -t "=$S:" -p; }
  # prompt: the shell has shown its next prompt and read what was pending
  prompt() { p=$((p + 1)); jnv_wait_lines "$P/shellin" "$p" 30 || echo "phase $name: no prompt $p ($1)"; CAP > "$P/screen_$1.txt" 2>/dev/null; }
  rstats() {
    n=$((n + 1))
    "$NVIM_BIN" --server "$addr" --remote-expr "luaeval('_G.__stats(\"$1\") or 0')" >/dev/null 2>&1
    jnv_wait_lines "$P/stats" "$n" 15 || echo "phase $name: stats $1: no answer"
  }
  waitev() {
    local end=$((SECONDS + 30))
    until [ "$(grep -cx "$1" "$P/events" 2>/dev/null)" -ge "$2" ]; do
      [ "$SECONDS" -ge "$end" ] && return 1; sleep 0.1
    done
  }
  # first_frame N: the gif sent a frame since its count was N (at most 20 s)
  first_frame() {
    local b end=$((SECONDS + 20))
    while [ "$SECONDS" -lt "$end" ]; do
      b="$(frames)"
      [ -n "$b" ] && [ "$b" != "$1" ] && return 0
      sleep 0.02
    done
    echo "phase $name: no frame went out within 20 s of the resume (frames sent: '$1' then '$b')"
    echo "nofirst" >> "$P/nofirst"
  }
  # fresh: the gif has just sent a frame (its count moved; at most 20 s), so
  # the stop that follows finds that frame still on its way
  frames() { "$NVIM_BIN" --server "$addr" --remote-expr "luaeval('require(\"jupynvim.notebook.image\")._frames_sent or 0')" 2>/dev/null; }
  fresh() {
    local a b end=$((SECONDS + 20))
    a="$(frames)"
    while [ "$SECONDS" -lt "$end" ]; do
      b="$(frames)"
      [ -n "$b" ] && [ "$b" != "$a" ] && return 0
      sleep 0.02
    done
    echo "phase $name: no frame went out within 20 s before a stop"
  }
  prompt start
  tmux send-keys -t "=$S:" "env JNV_PHASE=$name TERM=xterm-256color XDG_STATE_HOME=$(q "$P/state") $(q "$NVIM_BIN") -i NONE -u $(q "$WORK/init.lua") $(q "$WORK/$gif.ipynb")" Enter
  if ! jnv_wait_file_eq "$P/ready" 1 60; then
    echo "phase $name: the gif never animated; the screen:"; CAP | LC_ALL=C sed -e '/^ *$/d' -e 's/^/  | /' | tail -n 20
    jnv_stop_session "$S" || echo "LEAK" >> "$P/leak"
    return
  fi
  addr="$(cat "$P/addr")"
  sleep 2   # frames and their requests in flight
  # 1) CTRL-Z, then fg
  fresh
  tmux send-keys -t "=$S:" C-z
  prompt suspend
  local f0
  if [ -n "${FIRST:-}" ]; then rstats pre_fg; f0="$(frames)"; fi
  tmux send-keys -t "=$S:" "fg" Enter
  waitev UIEnter 2 || echo "phase $name: no UIEnter after fg"
  if [ -n "${FIRST:-}" ]; then
    first_frame "$f0"; rstats resumed
  else
    sleep 1; rstats resumed; sleep "$play"; rstats post
  fi
  # 2) :detach, then nvim --remote-ui in this terminal
  [ -n "${FIRST:-}" ] || fresh
  tmux send-keys -t "=$S:" ":let g:jnv_detaching = 1 | detach" Enter
  prompt detach
  if [ -n "${FIRST:-}" ]; then rstats pre_attach; f0="$(frames)"; fi
  tmux send-keys -t "=$S:" "env TERM=xterm-256color XDG_STATE_HOME=$(q "$P/state") $(q "$NVIM_BIN") --remote-ui --server $(q "$addr")" Enter
  waitev UIEnter 3 || echo "phase $name: no UIEnter after --remote-ui"
  if [ -n "${FIRST:-}" ]; then
    first_frame "$f0"; rstats back
  else
    sleep 1; rstats back; sleep "$play"; rstats back_post
  fi
  # 3) :qa! from that UI: the editor quits
  [ -n "${FIRST:-}" ] || fresh
  tmux send-keys -t "=$S:" Escape ":qa!" Enter
  prompt quit
  local ep; ep="$(cat "$P/pid" 2>/dev/null)"
  for _ in $(seq 1 100); do
    { [ -n "$ep" ] && ps -p "$ep" -o command= 2>/dev/null | grep -qF "$WORK"; } || break
    sleep 0.1
  done
  if [ -n "$ep" ] && ps -p "$ep" -o command= 2>/dev/null | grep -qF "$WORK"; then
    echo "phase $name: the editor did not quit; stopping pid $ep"
    kill "$ep" 2>/dev/null
    echo "leftover" >> "$P/leftover"
  fi
  tmux send-keys -t "=$S:" "exit" Enter
  for _ in $(seq 1 100); do tmux has-session -t "=$S" 2>/dev/null || break; sleep 0.1; done
  # the logging cat ends with the pane; wait until the log stops growing
  local last=-1 sz
  for _ in $(seq 1 50); do
    sz="$(wc -c < "$P/raw.bin" 2>/dev/null || echo 0)"
    [ "$sz" = "$last" ] && break
    last="$sz"; sleep 0.2
  done
  jnv_stop_session "$S" || echo "LEAK" >> "$P/leak"
}

phase A light 1.5 2.5 --answer-delay-ms 250 --answer-gap-ms 50
phase B heavy 6 8 --out-rate 60
phase C heavy 9 12 --out-rate 25
FIRST=1 phase D heavy 9 0 --out-rate 25
leak=0
{ [ -e "$WORK/A/leak" ] || [ -e "$WORK/B/leak" ] || [ -e "$WORK/C/leak" ] || [ -e "$WORK/D/leak" ]; } && leak=1
jnv_tmux_stop || leak=1

WORK="$WORK" LEAK="$leak" LIB="$ROOT/tests/lib" python3 -I - <<'PY'
import ast, os, re, sys
sys.dont_write_bytecode = True
sys.path.insert(0, os.environ["LIB"])
from escape_scan import scan, summary
W = os.environ["WORK"]
fails = []
def chk(name, ok, detail=""):
    print(("  ok " if ok else "FAIL ") + name + ("" if ok else "  -- " + detail))
    if not ok: fails.append(name)
# a terminal answer as the tty echoes it onto the screen (^[ for its ESC)
# or as a shell would print it; the shell's last line must be an empty
# prompt (nothing typed, nothing the shell took for typed)
answer = re.compile(r"\^\[|\x1b|\[\?[\d;]*c|\[[03]n")
for ph, what_ph in (("A", "answers late"), ("B", "a slow link"), ("C", "a slower link"),
                    ("D", "a slower link, stopped at the first frame after fg and after the reattach")):
    P = os.path.join(W, ph)
    def read(name):
        p = os.path.join(P, name)
        return open(p, encoding="utf-8", errors="replace").read() if os.path.exists(p) else ""
    raw = os.path.join(P, "raw.bin")
    data = open(raw, "rb").read() if os.path.exists(raw) else b""
    cuts, kitty = scan(data)
    shellin = []
    for line in read("shellin").splitlines():
        try: shellin.append(ast.literal_eval(line))
        except (ValueError, SyntaxError): shellin.append(line.encode())
    stops = {}
    for line in read("stops").splitlines():
        tag, *kv = line.split()
        stops.setdefault(tag, []).append({k: int(v) for k, v in (x.split("=", 1) for x in kv)})
    st = {}
    for line in read("stats").splitlines():
        if line.strip():
            tag, *kv = line.split()
            st[tag] = {k: int(v) for k, v in (x.split("=", 1) for x in kv)}
    print("phase %s (%s): %s" % (ph, what_ph, summary(data, cuts, kitty)))
    print("  shell input before each prompt: %r" % shellin)
    print("  stops %s" % stops)
    for tag in ("pre_fg", "resumed", "post", "pre_attach", "back", "back_post"):
        if tag in st: print("  %-10s %s" % (tag, st.get(tag)))
    def sent(tag): return (st.get(tag) or {}).get("frames_sent") or 0
    chk("%s: the shell was ready (its first prompt read no input)" % ph, len(shellin) >= 1 and shellin[0] == b"",
        "first prompt: %r" % (shellin[:1],))
    for i, (what, tag) in enumerate((("CTRL-Z", "suspend"), (":detach", "detach"), (":qa!", "quit")), 1):
        flight = [s.get("in_flight", -1) for s in stops.get(tag, [])]
        chk("%s: a frame request was in flight when the UI stopped (%s)" % (ph, what), bool(flight) and flight[0] > 0,
            "in flight %s" % flight)
        got = shellin[i] if len(shellin) > i else None
        chk("%s: after %s the shell got no terminal answer as input" % (ph, what), got == b"",
            "the shell read %r" % (got,))
        tail = [l.rstrip() for l in read("screen_%s.txt" % tag).splitlines() if l.strip()][-4:]
        chk("%s: after %s the shell's screen shows no terminal answer and an empty prompt" % (ph, what),
            bool(tail) and tail[-1] == "SH$" and not any(answer.search(l) for l in tail),
            "the screen's last lines:\n" + "\n".join("    | " + l for l in tail))
    if ph == "D":
        # the stops came with the first frame after the resume and after the
        # attach in flight, before its answer: the books had measured only
        # the version query's round trip since they started over
        chk("D: after fg the first frame went out", sent("resumed") > sent("pre_fg") and not read("nofirst"),
            "frames sent %s -> %s" % (sent("pre_fg"), sent("resumed")))
        chk("D: after nvim --remote-ui the first frame went out", sent("back") > sent("pre_attach") and not read("nofirst"),
            "frames sent %s -> %s" % (sent("pre_attach"), sent("back")))
        for what, tag in ((":detach", "detach"), (":qa!", "quit")):
            quiet = [s.get("quiet", -1) for s in stops.get(tag, [])]
            chk("D: at %s the frame's answer had not come (the link was measured only by the version query: %s ms)" % (what, quiet),
                bool(quiet) and 0 <= quiet[0] < 3000, "longest wait since the books started over: %s" % quiet)
    else:
        chk("%s: after fg the gif played again" % ph, sent("post") > sent("resumed"),
            "frames sent %s -> %s" % (sent("resumed"), sent("post")))
        chk("%s: after nvim --remote-ui the gif played again" % ph, sent("back_post") > sent("back"),
            "frames sent %s -> %s" % (sent("back"), sent("back_post")))
    chk("%s: kitty graphics reached the terminal" % ph, kitty > 0, "no kitty escape in the log")
    chk("%s: no escape sequence was cut" % ph, not cuts, "%d cut" % len(cuts))
    chk("%s: the editor quit" % ph, not read("leftover"), "stopped by pid")
chk("nvim and its terminal multiplexer stopped cleanly", os.environ.get("LEAK") == "0", "LEAK above")
print(("\nSTREAM-STOP: %d FAILED" % len(fails)) if fails else "\nSTREAM-STOP: ALL PASSED")
sys.exit(1 if fails else 0)
PY

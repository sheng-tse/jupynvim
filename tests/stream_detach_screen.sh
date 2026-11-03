#!/usr/bin/env bash
# A :detach leaves no terminal answer for the shell, also with a second UI
# attached and also for a client on another host.
#
# Each gif frame jupynvim sends with nvim_ui_send is followed by a request
# the terminal answers once it has read the frame (Neovim 0.12+). When a UI
# leaves with :detach, whatever the terminal answers after its UI stopped
# reading goes to the program that reads the terminal next, the user's
# shell, which shows it on its command line ("^[[0n^[[?1;2;4c"). So at the
# UILeave of a :detach the requests in flight are answered first
# (tests/stream_stop_screen.sh has the single UI). Two cases where that was
# skipped:
#   TWO  the editor's own UI in a fast pane and a UI attached with nvim
#        --remote-ui in a pane whose output passes at 60 KB/s: the slow UI
#        does :detach with a frame still on its way. Another UI still shows
#        the editor then, and the leaving one was not waited for.
#   FOREIGN  the editor listens on a unix socket and a client in another pid
#        namespace (a dev container) or on another host behind a forwarded
#        socket leaves (simulated: the client reports a pid that is no
#        process here, as such a pid is). A pid says nothing about a client
#        that may run elsewhere; Neovim tells whether the channel of a
#        client that left is still open (a client that ran :detach is a
#        live one), so the client is waited for, and the wait is bounded.
#        The editor's own UI and a local client detach in the same pane as
#        controls.
# Each phase fails when the slow pane's shell got a terminal answer as input
# or shows one on its screen, when no frame request was in flight at the
# :detach (the run then proves nothing), when the gif did not go on in the
# fast pane (TWO), when Neovim's log holds an error from a message a client
# did not know (the question to a client that left must be one it takes), or
# when an escape sequence was cut (tests/lib/escape_scan.py).
#
# Needs Neovim 0.12+ (nvim_ui_send), tmux and ImageMagick 7 (gif playback).
# JNV_STREAM_NVIM=/path/to/nvim runs another Neovim.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/core/target/release/jupynvim-core"
[ -x "$BIN" ] || { echo "SKIP stream_detach: build core first ($BIN)"; exit 0; }
source "$(dirname "$0")/lib/tmux.sh"
NVIM_BIN="${JNV_STREAM_NVIM:-nvim}"
command -v magick >/dev/null || { echo "SKIP stream_detach: no ImageMagick 7 (magick)"; exit 0; }
"$NVIM_BIN" --headless -u NONE -c 'lua io.stdout:write(vim.api.nvim_ui_send and "y" or "n")' -c 'qa!' 2>/dev/null \
  | grep -q y || { echo "SKIP stream_detach: $NVIM_BIN has no nvim_ui_send (Neovim 0.12+)"; exit 0; }
WORK="$(mktemp -d "$TMPDIR/jupynvim_detach.XXXXXX")"
# JNV_DETACH_KEEP=DIR keeps a copy of the work dir (logs, timelines) in DIR
cleanup() { jnv_tmux_stop; [ -n "${JNV_DETACH_KEEP:-}" ] && cp -R "$WORK" "$JNV_DETACH_KEEP" 2>/dev/null; rm -rf "$WORK"; }
jnv_on_exit cleanup

# 12 frames at 40 ms, each with a block of noise PNG cannot squeeze (about
# 115 KB of escape a frame: about 2 s on a 60 KB/s link)
( cd "$WORK" && for i in $(seq 0 11); do
    magick -size 640x480 gradient:'#203040-#506070' \( -size 320x240 xc: -seed $((i + 1)) +noise Random \) \
      -geometry +$((i * 20))+$((i * 10)) -composite -depth 8 "h_$(printf %02d "$i").png" || exit 1
  done && magick -delay 4 -loop 0 h_*.png heavy.gif ) \
  || { echo "FAIL stream_detach: ImageMagick could not make the gif"; exit 1; }

python3 - "$WORK" <<'PY'
import base64, json, os, sys
w = sys.argv[1]
gif = base64.b64encode(open(os.path.join(w, "heavy.gif"), "rb").read()).decode()
cells = [{"cell_type": "code", "id": "c1", "metadata": {}, "execution_count": 1, "source": "show_gif()",
          "outputs": [{"output_type": "display_data", "metadata": {},
                       "data": {"image/gif": gif, "text/plain": "<img>"}}]}]
json.dump({"cells": cells, "metadata": {"language_info": {"name": "python"}},
           "nbformat": 4, "nbformat_minor": 5}, open(os.path.join(w, "heavy.ipynb"), "w"))
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

# The editor's init: stops logs, as a :detach (marked by g:jnv_detaching)
# leaves, the requests in flight and the terminal UIs left; with
# g:jnv_foreign set the editor is told its clients' pids are not processes
# here (a pid that is gone; the real pid is kept otherwise).
# __stats(tag) appends the counters; ready is written once the gif animates.
cat > "$WORK/init.lua" <<LUA
vim.opt.runtimepath:prepend("$ROOT")
vim.o.swapfile = false
vim.o.termguicolors = true
local D = "$WORK/" .. vim.env.JNV_PHASE
local I
local function put(name, s, mode)
  local f = io.open(D .. "/" .. name, mode or "a"); f:write(s); f:close()
end
local gone = vim.system({ "true" }); gone:wait()
local real_info = vim.api.nvim_get_chan_info
vim.api.nvim_get_chan_info = function(chan)
  local info = real_info(chan)
  if vim.g.jnv_foreign == 1 and type(info) == "table" and type(info.client) == "table"
     and type(info.client.attributes) == "table" and info.client.attributes.pid then
    info = vim.deepcopy(info)
    info.client.attributes.pid = gone.pid
  end
  return info
end
local function inflight()
  if I and I._acks_info then return I._acks_info().n end
  return I and ((I._acks_sent or 0) - (I._acks_got or 0)) or -1
end
vim.api.nvim_create_autocmd("UILeave", { callback = function()
  if vim.g.jnv_detaching then
    vim.g.jnv_detaching = nil
    put("stops", ("detach in_flight=%d uis=%d\n"):format(inflight(), #vim.api.nvim_list_uis()))
  end
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
-- JNV_DETACH_TIMELINE=1: the counters twice a second, for a closer look
if vim.env.JNV_DETACH_TIMELINE then
  local tl = vim.uv.new_timer()
  tl:start(500, 500, vim.schedule_wrap(function()
    local a = I._acks_info()
    put("timeline", string.format("t=%d sent=%d held=%d asent=%d agot=%d n=%d given=%d answered=%s uis=%d tty=%d\n",
      vim.uv.now() % 1000000, I._frames_sent or 0, I._frames_held or 0, I._acks_sent or 0, I._acks_got or 0,
      a.n, a.given, tostring(a.answered), #vim.api.nvim_list_uis(), I._tty_bytes or 0))
  end))
end
LUA

q() { printf %q "$1"; }
# phase NAME: the scenario; the panes F (fast) and S (slow) are sessions of
# their own. pane PANE PEND RELAY_ARGS...: an interactive bash (behind the
# relay when RELAY_ARGS are given) whose prompt logs pending input to
# $P/shellin_PANE; PEND is how long the shell reads input before a prompt
phase() {
  local name="$1" P="$WORK/$1" addr
  mkdir -p "$P/state"
  local npF=0 npS=0
  pane() {
    local pn="$1" pend="$2"; shift 2
    local relay=""
    [ "$#" -gt 0 ] && relay="python3 -I $(q "$ROOT/tests/lib/tty_relay.py") $* --"
    cat > "$P/run_$pn.sh" <<SH
exec $relay env -u TMUX -u TMUX_PANE PS1='SH\$ ' PROMPT_COMMAND='python3 -I "$WORK/pending.py" "$P/shellin_$pn" $pend' bash --norc --noprofile -i
SH
    tmux new-session -d -s "jupy_detach_${name}_${pn}_$$" -x 160 -y 50 "sh $(q "$P/run_$pn.sh")"
    tmux pipe-pane -t "=jupy_detach_${name}_${pn}_$$:" -O "cat > $(q "$P/raw_$pn.bin")"
  }
  CAP() { tmux capture-pane -t "=jupy_detach_${name}_$1_$$:" -p; }
  # prompt PANE TAG: that pane's shell has shown its next prompt and read
  # what was pending
  prompt() {
    local cnt
    if [ "$1" = F ]; then npF=$((npF + 1)); cnt=$npF; else npS=$((npS + 1)); cnt=$npS; fi
    jnv_wait_lines "$P/shellin_$1" "$cnt" 30 || echo "phase $name: no prompt $cnt in $1 ($2)"
    CAP "$1" > "$P/screen_$1_$2.txt" 2>/dev/null
  }
  waitev() {
    local end=$((SECONDS + 30))
    until [ "$(grep -cx "$1" "$P/events" 2>/dev/null)" -ge "$2" ]; do
      [ "$SECONDS" -ge "$end" ] && return 1; sleep 0.1
    done
  }
  frames() { "$NVIM_BIN" --server "$addr" --remote-expr "luaeval('require(\"jupynvim.notebook.image\")._frames_sent or 0')" 2>/dev/null; }
  fresh() {
    local a b end=$((SECONDS + 20))
    a="$(frames)"
    while [ "$SECONDS" -lt "$end" ]; do
      b="$(frames)"; [ -n "$b" ] && [ "$b" != "$a" ] && return 0; sleep 0.02
    done
    echo "phase $name: no frame went out within 20 s before a stop (frames sent: '$a' then '$b')"
  }
  local ns=0
  rstats() {
    ns=$((ns + 1))
    "$NVIM_BIN" --server "$addr" --remote-expr "luaeval('_G.__stats(\"$1\") or 0')" >/dev/null 2>&1
    jnv_wait_lines "$P/stats" "$ns" 15 || echo "phase $name: stats $1: no answer"
  }
  local NV="env JNV_PHASE=$name TERM=xterm-256color XDG_STATE_HOME=$(q "$P/state") NVIM_LOG_FILE=$(q "$P/nvim.log") $(q "$NVIM_BIN")"
  if [ "$name" = TWO ]; then
    pane F 1
    pane S 6 --out-rate 60
    prompt F start; prompt S start
    tmux send-keys -t "=jupy_detach_${name}_F_$$:" "$NV -i NONE -u $(q "$WORK/init.lua") $(q "$WORK/heavy.ipynb")" Enter
    jnv_wait_file_eq "$P/ready" 1 60 || { echo "phase $name: the gif never animated"; CAP F | tail -n 20; }
    addr="$(cat "$P/addr" 2>/dev/null)"
    tmux send-keys -t "=jupy_detach_${name}_S_$$:" "$NV --remote-ui --server $(q "$addr")" Enter
    waitev UIEnter 2 || echo "phase $name: no UIEnter for the slow UI"
    sleep 5; rstats two_uis   # frames paced by the slow UI
    fresh
    tmux send-keys -t "=jupy_detach_${name}_S_$$:" ":let g:jnv_detaching = 1 | detach" Enter
    prompt S detach
    sleep 1; rstats after_detach; sleep 4; rstats later
    tmux send-keys -t "=jupy_detach_${name}_F_$$:" Escape ":qa!" Enter
    prompt F quit
  else
    pane S 6 --out-rate 60
    prompt S start
    tmux send-keys -t "=jupy_detach_${name}_S_$$:" "$NV --listen $(q "$WORK/sock") -i NONE -u $(q "$WORK/init.lua") $(q "$WORK/heavy.ipynb")" Enter
    jnv_wait_file_eq "$P/ready" 1 60 || { echo "phase $name: the gif never animated"; CAP S | tail -n 20; }
    addr="$(cat "$P/addr" 2>/dev/null)"
    sleep 3
    # 1) control: the editor's own UI detaches
    fresh
    tmux send-keys -t "=jupy_detach_${name}_S_$$:" ":let g:jnv_detaching = 1 | detach" Enter
    prompt S detach_own
    # 2) a client in another pid namespace or on another host detaches (its
    #    pid is no process here)
    tmux send-keys -t "=jupy_detach_${name}_S_$$:" "$NV --remote-ui --server $(q "$addr")" Enter
    waitev UIEnter 2 || echo "phase $name: no UIEnter for the first client"
    sleep 5; rstats foreign_in
    fresh
    tmux send-keys -t "=jupy_detach_${name}_S_$$:" ":let g:jnv_foreign = 1 | let g:jnv_detaching = 1 | detach" Enter
    prompt S detach_foreign
    # 3) control: a local client detaches
    tmux send-keys -t "=jupy_detach_${name}_S_$$:" "$NV --remote-ui --server $(q "$addr")" Enter
    waitev UIEnter 3 || echo "phase $name: no UIEnter for the second client"
    sleep 5; rstats local_in
    fresh
    tmux send-keys -t "=jupy_detach_${name}_S_$$:" ":let g:jnv_foreign = 0 | let g:jnv_detaching = 1 | detach" Enter
    prompt S detach_local
    "$NVIM_BIN" --server "$addr" --remote-send '<Esc>:qa!<CR>' >/dev/null 2>&1
    sleep 2
  fi
  local ep; ep="$(cat "$P/pid" 2>/dev/null)"
  if [ -n "$ep" ] && ps -p "$ep" -o command= 2>/dev/null | grep -qF "$WORK"; then
    echo "phase $name: the editor did not quit; stopping pid $ep"
    kill "$ep" 2>/dev/null
    echo "leftover" >> "$P/leftover"
  fi
  local pn
  for pn in F S; do
    tmux has-session -t "=jupy_detach_${name}_${pn}_$$" 2>/dev/null || continue
    tmux send-keys -t "=jupy_detach_${name}_${pn}_$$:" "exit" Enter
  done
  for _ in $(seq 1 100); do
    tmux has-session -t "=jupy_detach_${name}_F_$$" 2>/dev/null || tmux has-session -t "=jupy_detach_${name}_S_$$" 2>/dev/null || break
    sleep 0.1
  done
  local last=-1 sz
  for _ in $(seq 1 50); do
    sz="$(cat "$P"/raw_*.bin 2>/dev/null | wc -c | tr -d ' ')"
    [ "$sz" = "$last" ] && break
    last="$sz"; sleep 0.2
  done
  for pn in F S; do
    tmux has-session -t "=jupy_detach_${name}_${pn}_$$" 2>/dev/null || continue
    jnv_stop_session "jupy_detach_${name}_${pn}_$$" || echo "LEAK" >> "$P/leak"
  done
}

# JNV_DETACH_PHASES="TWO" (or FOREIGN) runs one phase only, for a closer look
PHASES="${JNV_DETACH_PHASES:-TWO FOREIGN}"
for ph in $PHASES; do phase "$ph"; done
leak=0
{ [ -e "$WORK/TWO/leak" ] || [ -e "$WORK/FOREIGN/leak" ]; } && leak=1
jnv_tmux_stop || leak=1

WORK="$WORK" PHASES="$PHASES" LEAK="$leak" LIB="$ROOT/tests/lib" python3 -I - <<'PY'
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
for ph, what_ph, stops_wanted in (
        ("TWO", "a second UI stays", [("detach", "S", 1)]),
        ("FOREIGN", "a client on another host or in another pid namespace", [("detach_own", "S", 0), ("detach_foreign", "S", 1), ("detach_local", "S", 2)])):
    if ph not in os.environ["PHASES"].split():
        continue
    P = os.path.join(W, ph)
    def read(name):
        p = os.path.join(P, name)
        return open(p, encoding="utf-8", errors="replace").read() if os.path.exists(p) else ""
    data = b"".join(open(os.path.join(P, f), "rb").read() for f in sorted(os.listdir(P)) if f.startswith("raw_") and f.endswith(".bin"))
    cuts, kitty = scan(data)
    def shellin(pane):
        out = []
        for line in read("shellin_%s" % pane).splitlines():
            try: out.append(ast.literal_eval(line))
            except (ValueError, SyntaxError): out.append(line.encode())
        return out
    stops = []
    for line in read("stops").splitlines():
        tag, *kv = line.split()
        stops.append({k: int(v) for k, v in (x.split("=", 1) for x in kv)})
    st = {}
    for line in read("stats").splitlines():
        if line.strip():
            tag, *kv = line.split()
            st[tag] = {k: int(v) for k, v in (x.split("=", 1) for x in kv)}
    print("phase %s (%s): %s" % (ph, what_ph, summary(data, cuts, kitty)))
    print("  slow pane's input before each prompt: %r" % shellin("S"))
    print("  detaches %s" % stops)
    for tag in st: print("  %-12s %s" % (tag, st[tag]))
    chk("%s: the slow pane's shell was ready (its first prompt read no input)" % ph,
        len(shellin("S")) >= 1 and shellin("S")[0] == b"", "first prompt: %r" % (shellin("S")[:1],))
    for i, (tag, pane, _w) in enumerate(stops_wanted):
        got = shellin(pane)[i + 1] if len(shellin(pane)) > i + 1 else None
        flight = stops[i].get("in_flight", -1) if len(stops) > i else -1
        chk("%s: a frame request was in flight at the :detach (%s)" % (ph, tag), flight > 0, "in flight %s" % flight)
        chk("%s: after the :detach (%s) the slow pane's shell got no terminal answer as input" % (ph, tag), got == b"",
            "the shell read %r" % (got,))
        tail = [l.rstrip() for l in read("screen_%s_%s.txt" % (pane, tag)).splitlines() if l.strip()][-4:]
        chk("%s: after the :detach (%s) the slow pane's screen shows no terminal answer and an empty prompt" % (ph, tag),
            bool(tail) and tail[-1] == "SH$" and not any(answer.search(l) for l in tail),
            "the screen's last lines:\n" + "\n".join("    | " + l for l in tail))
    if ph == "TWO":
        chk("TWO: the other UI stayed (one UI was left at the :detach)", stops and stops[0].get("uis") == 1,
            "UIs left %s" % (stops and stops[0].get("uis")))
        chk("TWO: the fast pane's shell got no terminal answer as input after the quit",
            len(shellin("F")) >= 2 and shellin("F")[1] == b"", "the shell read %r" % (shellin("F")[1:2],))
        a, b = (st.get("after_detach") or {}).get("frames_sent"), (st.get("later") or {}).get("frames_sent")
        chk("TWO: the gif went on in the fast pane after the slow UI left", a is not None and b is not None and b > a,
            "frames sent %s -> %s" % (a, b))
    chk("%s: kitty graphics reached the terminal" % ph, kitty > 0, "no kitty escape in the log")
    chk("%s: no escape sequence was cut" % ph, not cuts, "%d cut" % len(cuts))
    # the editor asks a client that left whether it is still there with a
    # message every UI client takes; one it did not know would come back as an
    # error that Neovim writes to its log (the phase's own, NVIM_LOG_FILE)
    log = [l for l in read("nvim.log").splitlines() if "Invalid method" in l or "async error" in l]
    chk("%s: no client was sent a method it does not know (no async error in Neovim's log)" % ph, not log,
        "the log has: %s" % log[:3])
    chk("%s: the editor quit" % ph, not read("leftover"), "stopped by pid")
chk("nvim and its terminal multiplexer stopped cleanly", os.environ.get("LEAK") == "0", "LEAK above")
print(("\nSTREAM-DETACH: %d FAILED" % len(fails)) if fails else "\nSTREAM-DETACH: ALL PASSED")
sys.exit(1 if fails else 0)
PY

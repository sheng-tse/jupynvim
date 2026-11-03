#!/usr/bin/env bash
# A gif must not outrun the terminal.
#
# nvim_ui_send never blocks: bytes the terminal has not read yet wait in the
# editor's queue to the UI, and the UI's screen updates wait behind them. A
# gif whose frames come faster than the terminal reads them (a slow link, a
# busy terminal, a large animation) grew that queue without bound: the
# editor's memory climbed by megabytes a second and the screen stopped
# following the keyboard for a minute and more. Frames now wait for the
# terminal: each is followed by a status request (DSR) the terminal answers
# once it has read it, and a frame the terminal has no room for is skipped.
# Before the terminal has answered at all, one request is given up after a
# few seconds and one more frame goes (a terminal that never answers still
# plays the gif); no more are given up until it answers, because behind a
# slow link Neovim's UI reads its input only between its writes, and a frame
# every few seconds piled up in it before its first answer, which then came
# late and left the gif without a frame for as long as the pile took to
# read. Once the terminal has answered, a slow answer is waited for, so a
# terminal that needs longer than a few seconds to read one frame still
# paces the gif (giving up there let a frame through every few seconds,
# faster than such a terminal reads them, and the queue grew again). The
# answers to the editor's own start queries (which come late over a slow
# link, after the first frames) are not a frame's.
#
# Neovim runs behind tests/lib/tty_relay.py set to read slowly, in a private
# tmux pane whose raw output is logged (pipe-pane). The notebook holds one
# large animated gif in view (about 115 KB of escape a frame). Four times,
# each time with a fresh pane:
#   1  the relay reads 4 KB every 4 ms (under 1 MB/s, a third of what the
#      gif plays at): over HOLD seconds the test samples the editor's
#      resident memory, the bytes of graphics it wrote and the bytes the
#      terminal got
#   2  the relay reads 1 KB every 40 ms (about 25 KB/s: one frame takes
#      longer to read than the 3 s after which a request is given up): one
#      sample 3 s after the gif plays, then two 10 s apart from the
#      terminal's first answer, and a log of every request, every frame and
#      every answer the editor counted
#   3  the same, and the relay holds everything the terminal sends (the
#      answers to Neovim's own start queries first) until 1 s after the first
#      status request that follows a graphics command reached the terminal,
#      or until 20 s, and passes it on in one write: had a frame gone out
#      before those answers came, the UI would read them in one piece with
#      that frame's own answer, as over a slow link it does now and then
#   4  the same relay, holding everything the terminal sends until 40 s
#      after the first marker request (ESC [ > q) reached the terminal,
#      longer than the 30 s after which a marker request nobody answered is
#      given up, counted from that request, so however long the editor took
#      to start: the first answer after the start comes later than the
#      limit, as over a very slow link or behind a long backlog. The
#      terminal does answer the marker, only late; its answer must turn
#      markers on again, and the next marker, not the status answers counted
#      meanwhile, must settle the books
# then it runs a command that prints a word and times how long until the
# word shows on screen. It fails when the memory grew, when the bytes
# written ran ahead of the bytes the terminal got by more than a few frames,
# when the word took too long (8 s, 15 s), when the gif played fewer than
# HOLD/4 frames, when no frame waited for the terminal or the terminal never
# answered, when an answer was counted before the terminal can have read the
# frame it answers (the pane's byte count is compared with the bytes written
# up to that request), when more than two frames were on their way before
# the terminal's first answer, when a request was given up once the terminal
# had answered, when the gif waited longer than 10 s for a frame after the
# first answer (phases 2 and 3), when in phase 3 a frame went out before the
# answers to Neovim's own start queries came in (frames wait for the answer
# to a marker request, which comes after them), when in phase 4 the marker
# answered after it was given up did not turn markers on again (or no marker
# was answered after it), when an answer was counted before the terminal can
# have read the frame it answers once markers were on again, or when an
# escape sequence was cut
# (tests/lib/escape_scan.py).
#
# Needs Neovim 0.12+ (nvim_ui_send), tmux and ImageMagick 7 (gif playback).
# JNV_STREAM_NVIM=/path/to/nvim runs another Neovim; JNV_STREAM_HOLD=S sets
# phase 1's measured window (default 12 s; a value that is not a whole
# number above 0 is ignored).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/core/target/release/jupynvim-core"
[ -x "$BIN" ] || { echo "SKIP stream_backlog: build core first ($BIN)"; exit 0; }
source "$(dirname "$0")/lib/tmux.sh"
NVIM_BIN="${JNV_STREAM_NVIM:-nvim}"
HOLD="${JNV_STREAM_HOLD:-12}"
case "$HOLD" in ''|*[!0-9]*) HOLD=0 ;; esac
HOLD=$((10#$HOLD))
[ "$HOLD" -gt 0 ] || { echo "stream_backlog: JNV_STREAM_HOLD=${JNV_STREAM_HOLD:-} is not a whole number above 0; using 12"; HOLD=12; }
command -v magick >/dev/null || { echo "SKIP stream_backlog: no ImageMagick 7 (magick)"; exit 0; }
"$NVIM_BIN" --headless -u NONE -c 'lua io.stdout:write(vim.api.nvim_ui_send and "y" or "n")' -c 'qa!' 2>/dev/null \
  | grep -q y || { echo "SKIP stream_backlog: $NVIM_BIN has no nvim_ui_send (Neovim 0.12+)"; exit 0; }
WORK="$(mktemp -d "$TMPDIR/jupynvim_backlog.XXXXXX")"
cleanup() { jnv_tmux_stop; rm -rf "$WORK"; }
jnv_on_exit cleanup

# 12 frames at 40 ms, each with a block of noise PNG cannot squeeze: about
# 115 KB of escape a frame, near 3 MB a second while it plays
( cd "$WORK" && for i in $(seq 0 11); do
    magick -size 640x480 gradient:'#203040-#506070' \( -size 320x240 xc: -seed $((i + 1)) +noise Random \) \
      -geometry +$((i * 20))+$((i * 10)) -composite -depth 8 "h_$(printf %02d "$i").png" || exit 1
  done && magick -delay 4 -loop 0 h_*.png heavy.gif ) \
  || { echo "FAIL stream_backlog: ImageMagick could not make the gif"; exit 1; }

python3 - "$WORK" <<'PY'
import base64, json, os, sys
w = sys.argv[1]
gif = base64.b64encode(open(os.path.join(w, "heavy.gif"), "rb").read()).decode()
long_src = "\n".join("v%02d = [i * %d for i in range(%d)]  # row %d" % (i, i, i + 3, i) for i in range(28))
def code(i, src, outs=()):
    return {"cell_type": "code", "id": "c%d" % i, "metadata": {}, "execution_count": i,
            "outputs": list(outs), "source": src}
cells = [code(1, "show_gif()", [{"output_type": "display_data", "metadata": {},
                                 "data": {"image/gif": gif, "text/plain": "<img>"}}]),
         code(2, long_src), code(3, "x = 1")]
json.dump({"cells": cells, "metadata": {"language_info": {"name": "python"}},
           "nbformat": 4, "nbformat_minor": 5}, open(os.path.join(w, "nb.ipynb"), "w"))
PY

# __stats(tag) appends the image writer's counters; pid and ready are written
# once, ready when the gif animates (a placement with a frame timer).
# JNV_PHASE names the phase's directory.
cat > "$WORK/init.lua" <<LUA
vim.opt.runtimepath:prepend("$ROOT")
vim.o.swapfile = false
vim.o.termguicolors = true
vim.o.number = true
require("jupynvim").setup({ core_path = "$BIN", auto_venv = false })
local I = require("jupynvim.notebook.image")
local D = "$WORK/" .. vim.env.JNV_PHASE
local fp = io.open(D .. "/pid", "w"); fp:write(tostring(vim.fn.getpid())); fp:close()
function _G.__stats(tag)
  local f = io.open(D .. "/stats", "a")
  f:write(string.format("%s tty_bytes=%d frames_sent=%d frames_held=%d acks_sent=%d acks_got=%d timeouts=%d remote=%s marks_sent=%d marks_got=%d marks_lost=%d mark_off=%d mark_seen=%d\n",
    tag, I._tty_bytes or 0, I._frames_sent or 0, I._frames_held or 0, I._acks_sent or 0, I._acks_got or 0,
    I._ack_timeouts or 0, tostring(I._remote_mode), I._marks_sent or 0, I._marks_got or 0, I._marks_lost or 0,
    I._mark_off and 1 or 0, I._mark_seen and 1 or 0))
  f:close()
end
-- every status request with the bytes written through nvim_ui_send up to and
-- including it, every transmit with its time, and (below) every answer the
-- editor counted with the bytes the pane has got by then: an answer counted
-- before the pane has the bytes of the frame it answers was not that
-- frame's
local function put(name, s)
  local f = io.open(D .. "/" .. name, "a"); f:write(s); f:close()
end
local t0, written, reqs = vim.uv.hrtime(), 0, {}
local function ms() return math.floor((vim.uv.hrtime() - t0) / 1e6) end
local real_send = vim.api.nvim_ui_send
vim.api.nvim_ui_send = function(s)
  written = written + #s
  if s == "\27[5n" then reqs[#reqs + 1] = written
  elseif s:find("^\27_Ga=t,") then put("frames", ms() .. "\n") end
  return real_send(s)
end
local last_got = 0
vim.api.nvim_create_autocmd("TermResponse", { callback = function(ev)
  local d = ev.data
  put("termresp", string.format("%d %q\n", ms(), tostring(type(d) == "table" and d.sequence or d)))
  local got = I._acks_got or 0
  if got > last_got then
    last_got = got
    local st = vim.uv.fs_stat(D .. "/raw.bin")
    put("answers", string.format("%d k=%d frames=%d timeouts=%d cum=%d pane=%d mo=%d\n", ms(), got,
      I._frames_sent or 0, I._ack_timeouts or 0, reqs[got] or -1, st and st.size or -1, I._mark_off and 1 or 0))
  end
end })
local ready = vim.uv.new_timer()
ready:start(100, 100, vim.schedule_wrap(function()
  for _, p in pairs(I._placements) do
    if p.timer then
      ready:stop()
      local f = io.open(D .. "/ready", "w"); f:write("1"); f:close()
      return
    end
  end
end))
LUA

q() { printf %q "$1"; }
# phase NAME ANSWERED WAIT1 WAIT2 RELAY_ARGS...: nvim on the relay in a fresh
# pane; samples s0 (3 s after the gif plays), s1 (WAIT1 s later; with
# ANSWERED=1 WAIT1 s after the terminal's first answer, which is waited for
# up to 90 s: how soon it comes depends on the link) and, when WAIT2 is
# above 0, s2 (WAIT2 s after s1); then the time until a command's output
# shows. The pane's raw output is logged from the first byte: the relay
# waits for the go file.
phase() {
  local name="$1" answered="$2" w1="$3" w2="$4"; shift 4
  local P="$WORK/$name" S="jupy_backlog_${name}_$$" n=0
  mkdir -p "$P/state"
  cat > "$P/run.sh" <<SH
while [ ! -e "$P/go" ]; do sleep 0.02; done
exec python3 -I "$ROOT/tests/lib/tty_relay.py" $* -- env -u TMUX -u TMUX_PANE JNV_PHASE=$name \
  TERM=xterm-256color XDG_STATE_HOME="$P/state" "$NVIM_BIN" -i NONE -u "$WORK/init.lua" "$WORK/nb.ipynb"
SH
  tmux new-session -d -s "$S" -x 160 -y 50 "sh $(q "$P/run.sh")"
  tmux pipe-pane -t "=$S:" -O "cat > $(q "$P/raw.bin")"
  touch "$P/go"
  CAP() { tmux capture-pane -t "=$S:" -p; }
  stats() { n=$((n + 1)); tmux send-keys -t "=$S:" ":lua __stats('$1')" Enter; jnv_wait_lines "$P/stats" "$n" 70 || echo "phase $name: stats $1: no answer"; }
  # sample TAG: the editor's resident memory (KB) and the bytes the terminal
  # got so far, right after the stats line for TAG was written
  rss() { ps -o rss= -p "$(cat "$P/pid" 2>/dev/null)" 2>/dev/null | tr -d ' '; }
  sample() { stats "$1"; echo "$1 rss_kb=$(rss) pane_bytes=$(wc -c < "$P/raw.bin" | tr -d ' ')" >> "$P/samples"; }
  if ! jnv_wait_file_eq "$P/ready" 1 90; then
    echo "phase $name: the gif never animated; the screen:"
    CAP 2>/dev/null | LC_ALL=C sed -e '/^ *$/d' -e 's/^/  | /' | tail -n 20
    echo "never" >> "$P/never"
    jnv_stop_session "$S" || echo "LEAK" >> "$P/leak"
    return
  fi
  sleep 3
  sample s0
  if [ "$answered" = 1 ]; then
    local aend=$((SECONDS + 90))
    while [ ! -s "$P/answers" ] && [ "$SECONDS" -lt "$aend" ]; do sleep 0.1; done
    [ -s "$P/answers" ] || echo "phase $name: the terminal's first answer did not come within 90 s"
  fi
  sleep "$w1"
  sample s1
  if [ "$w2" -gt 0 ]; then sleep "$w2"; sample s2; fi
  # a word only the command's output holds (the typed command line reads QZ.J)
  local t0 end seen=""
  t0="$(python3 -I -c 'import time; print(time.monotonic())')"
  tmux send-keys -t "=$S:" ":lua print(('QZ%sJ'):format('XY'))" Enter
  end=$((SECONDS + 30))
  while [ "$SECONDS" -lt "$end" ]; do
    if CAP | grep -q QZXYJ; then seen=1; break; fi
    sleep 0.05
  done
  echo "echo seen=${seen:-0} after=$(python3 -I -c "import time; print('%.2f' % (time.monotonic() - $t0))")" >> "$P/samples"
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

phase 1 0 "$HOLD" 0 --read 4096 --delay-ms 4
phase 2 1 10 10 --read 1024 --delay-ms 40
phase 3 1 10 10 --read 1024 --delay-ms 40 --hold-answers-ms 20000 --hold-until-frame-request \
  --hold-log "$(q "$WORK/3/release")"
phase 4 1 10 10 --read 1024 --delay-ms 40 --hold-answers-ms 40000 --hold-from-marker \
  --hold-log "$(q "$WORK/4/release")"
leak=0
{ [ -e "$WORK/1/leak" ] || [ -e "$WORK/2/leak" ] || [ -e "$WORK/3/leak" ] || [ -e "$WORK/4/leak" ]; } && leak=1
jnv_tmux_stop || leak=1

WORK="$WORK" HOLD="$HOLD" LEAK="$leak" LIB="$ROOT/tests/lib" python3 -I - <<'PY'
import os, sys
sys.dont_write_bytecode = True
sys.path.insert(0, os.environ["LIB"])
from escape_scan import scan, summary
W = os.environ["WORK"]
hold = int(os.environ["HOLD"])
fails = []
def chk(name, ok, detail=""):
    print(("  ok " if ok else "FAIL ") + name + ("" if ok else "  -- " + detail))
    if not ok: fails.append(name)
def load(ph):
    P = os.path.join(W, ph)
    def read(name):
        p = os.path.join(P, name)
        return open(p).read().split("\n") if os.path.exists(p) else []
    raw = os.path.join(P, "raw.bin")
    data = open(raw, "rb").read() if os.path.exists(raw) else b""
    st, sm, echo = {}, {}, {}
    for line in read("stats"):
        if line.strip():
            tag, *kv = line.split()
            st[tag] = {k: (v if k == "remote" else int(v)) for k, v in (x.split("=", 1) for x in kv)}
    for line in read("samples"):
        if line.strip():
            tag, *kv = line.split()
            d = dict(x.split("=", 1) for x in kv)
            (echo if tag == "echo" else sm.setdefault(tag, {})).update(d)
    return data, st, sm, echo, bool(read("never"))
MARK_OFF = {}
def counted(ph):
    ph_key = ph
    # the answers the editor counted: (ms, k, frames sent, requests given up, bytes written up to
    # request k, bytes the pane had), and the times of every transmit
    P = os.path.join(W, ph)
    def read(name):
        p = os.path.join(P, name)
        return open(p).read().split("\n") if os.path.exists(p) else []
    ans = []
    for line in read("answers"):
        if line.strip():
            t, *kv = line.split()
            d = {k: int(v) for k, v in (x.split("=", 1) for x in kv)}
            ans.append((int(t), d["k"], d["frames"], d["timeouts"], d["cum"], d["pane"]))
            MARK_OFF[(ph_key, int(t), d["k"])] = d.get("mo", 0)
    return ans, [int(x) for x in read("frames") if x.strip()]
def num(d, k):
    try: return float(d.get(k, ""))
    except (ValueError, AttributeError): return None
# an answer cannot be counted before the pane has got what was written up to its request
# (the pane also holds Neovim's own output, so it has at least that; 16 KB for the log's lag)
LAG = 16 * 1024
def early_answers(ans):
    return [(t, k, cum, pane) for (t, k, _f, _o, cum, pane) in ans if cum < 0 or pane < 0 or cum > pane + LAG]

# phase 1: a terminal a third as fast as the gif
data, st, sm, echo, never = load("1")
cuts, kitty = scan(data)
def g(tag, k): return st.get(tag, {}).get(k)
print("phase 1 (4 KB every 4 ms): " + summary(data, cuts, kitty))
for tag in ("s0", "s1"):
    print("  %-3s %s %s" % (tag, st.get(tag), sm.get(tag)))
print("  echo %s" % echo)
chk("1: the gif started to animate", not never, "not within 90 s")
sent = None if None in (g("s0", "frames_sent"), g("s1", "frames_sent")) else g("s1", "frames_sent") - g("s0", "frames_sent")
chk("1: the gif played (at least %d frames in %d s)" % (max(1, hold // 4), hold),
    sent is not None and sent >= max(1, hold // 4) and g("s1", "remote") == "true", str(st.get("s1")))
held = None if None in (g("s0", "frames_held"), g("s1", "frames_held")) else g("s1", "frames_held") - g("s0", "frames_held")
chk("1: frames waited for the terminal (it reads slower than the gif plays)", held is not None and held > 0,
    "frames held %s" % held)
chk("1: the terminal answered the frames' requests", (g("s1", "acks_got") or 0) > 0, str(st.get("s1")))
r0, r1 = num(sm.get("s0", {}), "rss_kb"), num(sm.get("s1", {}), "rss_kb")
chk("1: the editor's memory stayed flat (under 20 MB more in %s s)" % hold,
    None not in (r0, r1) and r1 - r0 < 20 * 1024, "rss %s -> %s KB" % (r0, r1))
wrote, got = g("s1", "tty_bytes"), num(sm.get("s1", {}), "pane_bytes")
chk("1: the graphics written ran no more than a few frames ahead of what the terminal got (3 MB)",
    None not in (wrote, got) and wrote - got < 3 * 1024 * 1024, "written %s, the terminal got %s" % (wrote, got))
after = num(echo, "after")
chk("1: a command's output showed on screen within 8 s", echo.get("seen") == "1" and after is not None and after < 8,
    "seen %s after %s s" % (echo.get("seen"), after))
ans1, _fr1 = counted("1")
bad = early_answers(ans1)
chk("1: no answer was counted before the terminal can have read the frame it answers", not bad,
    "counted too early (ms, k, bytes written up to the request, bytes the pane had): %s" % bad[:3])
chk("1: kitty graphics reached the terminal", kitty > 0, "no kitty escape in the log")
chk("1: no escape sequence was cut", not cuts, "%d cut" % len(cuts))

for ph in ("2", "3"):
    P = ph + ": "
    # phases 2 and 3: a terminal that needs longer than the timeout to read one frame; in phase 3 what
    # the terminal sends is held back and passed on in one piece (see the top of this file)
    data, st, sm, echo, never = load(ph)
    cuts, kitty = scan(data)
    print("phase %s (1 KB every 40 ms%s): " % (ph, ", the terminal's answers held and passed on in one piece" if ph == "3" else "") + summary(data, cuts, kitty))
    for tag in ("s0", "s1", "s2"):
        s = st.get(tag) or {}
        ahead = None if None in (s.get("tty_bytes"), num(sm.get(tag, {}), "pane_bytes")) else s["tty_bytes"] - num(sm.get(tag, {}), "pane_bytes")
        print("  %-3s %s %s ahead=%s" % (tag, st.get(tag), sm.get(tag), ahead))
    print("  echo %s" % echo)
    chk(P + "the gif started to animate", not never, "not within 90 s")
    ans2, fr2 = counted(ph)
    if ph == "3":
        path = os.path.join(W, "3", "termresp")
        tr = [int(l.split()[0]) for l in open(path).read().split("\n") if l.strip()] if os.path.exists(path) else []
        rpath = os.path.join(W, "3", "release")
        rel = open(rpath).read().split() if os.path.exists(rpath) else []
        chk(P + "the terminal's answers were held and passed on in one piece (what this phase forces)",
            len(rel) >= 4 and rel[0] == "release", "relay log: %s" % (" ".join(rel) or "none"))
        n_tx = len([t for t in fr2 if tr and t < tr[0]])
        chk(P + "no gif frame went out before the answers to Neovim's own start queries came in (frames wait for the marker's answer, which comes after them)",
            bool(tr) and n_tx <= 1, "first answer read at %s ms, transmits before it: %d (the image itself is one) %s" % (tr[:1], n_tx, " ".join(rel)))
    first = ans2[0] if ans2 else None
    print("  answers counted (ms, k, frames sent, given up, bytes written to the request, bytes the pane had): %s" % ans2[:6])
    chk(P + "the terminal answered the frames' requests", (g("s2", "acks_got") or 0) > 0 and first is not None,
        str(st.get("s2")))
    bad = early_answers(ans2)
    chk(P + "no answer was counted before the terminal can have read the frame it answers (the editor's own start answers are not a frame's)",
        not bad, "counted too early (ms, k, bytes written up to the request, bytes the pane had): %s" % bad[:3])
    chk(P + "before the terminal's first answer at most two frames were on their way (no pile in a terminal that has not answered)",
        first is not None and first[2] <= 2, "frames sent when the first answer was counted: %s" % (first and first[2]))
    chk(P + "once the terminal had answered, no request was given up (a slow answer is waited for)",
        first is not None and g("s2", "timeouts") == first[3],
        "requests given up %s at the first answer, %s at s2" % (first and first[3], g("s2", "timeouts")))
    after_first = [t for t in fr2 if first is not None and t > first[0]]
    times = ([first[0]] if first else []) + after_first
    gaps = [b - a for a, b in zip(times, times[1:])]
    chk(P + "after the first answer the gif went on, with no wait of more than 10 s for a frame (at least 2 frames)",
        len(after_first) >= 2 and max(gaps) <= 10000,
        "frames after the first answer (ms) %s, first answer at %s" % (after_first, first and first[0]))
    sent = None if None in (g("s1", "frames_sent"), g("s2", "frames_sent")) else g("s2", "frames_sent") - g("s1", "frames_sent")
    chk(P + "the gif played on (a frame at least every 10 s)", sent is not None and sent >= 1,
        "frames sent %s -> %s" % (g("s1", "frames_sent"), g("s2", "frames_sent")))
    r0, r2 = num(sm.get("s0", {}), "rss_kb"), num(sm.get("s2", {}), "rss_kb")
    chk(P + "the editor's memory stayed flat (under 20 MB more in 20 s)",
        None not in (r0, r2) and r2 - r0 < 20 * 1024, "rss %s -> %s KB" % (r0, r2))
    after = num(echo, "after")
    chk(P + "a command's output showed on screen within 15 s", echo.get("seen") == "1" and after is not None and after < 15,
        "seen %s after %s s" % (echo.get("seen"), after))
    chk(P + "no escape sequence was cut", not cuts, "%d cut" % len(cuts))

# phase 4: the first answer after the start comes later than the lost limit
P = "4: "
data, st, sm, echo, never = load("4")
cuts, kitty = scan(data)
print("phase 4 (1 KB every 40 ms, the terminal's answers held until 40 s after the first marker request, longer than the lost limit): " + summary(data, cuts, kitty))
for tag in ("s0", "s1", "s2"):
    print("  %-3s %s %s" % (tag, st.get(tag), sm.get(tag)))
print("  echo %s" % echo)
chk(P + "the gif started to animate", not never, "not within 90 s")
rpath = os.path.join(W, "4", "release")
rel = open(rpath).read().split() if os.path.exists(rpath) else []
relk = dict(x.split("=", 1) for x in rel[1:] if "=" in x)
def relms(k):
    try: return int(relk.get(k, ""))
    except ValueError: return None
held_ms = relms("held_ms")
print("  relay: %s" % (" ".join(rel) or "no release line"))
# the hold is counted from the marker request (when the relay passed it on,
# which is no earlier than the editor sent it), so the editor's own lost
# limit, counted from when it sent it, has run out before any answer comes
chk(P + "the terminal's answers were held until 40 s after the first marker request and passed on in one piece (what this phase forces)",
    len(rel) == 6 and rel[0] == "release" and relk.get("why") == "marker" and relms("marker_ms") is not None
    and held_ms is not None and 40000 <= held_ms <= 60000, "relay log: %s" % (" ".join(rel) or "none"))
ans4, fr4 = counted("4")
chk(P + "the marker nobody answered in time was given up (the answer came after the lost limit)",
    (g("s2", "marks_lost") or 0) >= 1, str(st.get("s2")))
chk(P + "the late answer turned markers on again: markers are on and the terminal is known to answer them",
    g("s2", "mark_off") == 0 and g("s2", "mark_seen") == 1, str(st.get("s2")))
chk(P + "a marker was answered after the first one was given up (the books were settled by a marker, not by status answers)",
    (g("s2", "marks_got") or 0) >= 1, str(st.get("s2")))
# once markers are on again (a marker sent after the give-up and answered), an answer counted is no
# earlier than the terminal can have read the frame it answers
on_again = [a for a in ans4 if not MARK_OFF.get(("4", a[0], a[1]), 0)]
bad = early_answers(on_again)
chk(P + "no answer counted while markers were on was counted before the terminal can have read the frame it answers",
    not bad, "counted too early (ms, k, bytes written up to the request, bytes the pane had): %s" % bad[:3])
after4 = [t for t in fr4 if ans4 and t > ans4[0][0]]
chk(P + "the gif went on after the late answer (at least 2 frames)", len(after4) >= 2,
    "frames after the first answer (ms) %s, first answer at %s" % (after4, ans4 and ans4[0][0]))
r0, r2 = num(sm.get("s0", {}), "rss_kb"), num(sm.get("s2", {}), "rss_kb")
chk(P + "the editor's memory stayed flat (under 20 MB more)", None not in (r0, r2) and r2 - r0 < 20 * 1024, "rss %s -> %s KB" % (r0, r2))
after = num(echo, "after")
chk(P + "a command's output showed on screen within 30 s", echo.get("seen") == "1" and after is not None and after < 30,
    "seen %s after %s s" % (echo.get("seen"), after))
chk(P + "no escape sequence was cut", not cuts, "%d cut" % len(cuts))
chk("nvim and its terminal multiplexer stopped cleanly", os.environ.get("LEAK") == "0", "LEAK above")
print(("\nSTREAM-BACKLOG: %d FAILED" % len(fails)) if fails else "\nSTREAM-BACKLOG: ALL PASSED")
sys.exit(1 if fails else 0)
PY

#!/usr/bin/env bash
# The cell-box scenarios, measured: three runs of one session each behind a
# slow terminal, recorded by the headless pixel harness (tests/lib/vkitty) and
# replayed through its Ghostty 1.4.0 model.
#
# Neovim runs on a pty whose reader lags (tests/lib/tty_relay.py), inside the
# harness's relay (tests/lib/vkitty/relay.py), in a 160x50 private tmux pane.
# The notebook has an animated gif (16 frames of 480x320 at 80 ms), a 28-line
# cell and a 12-line cell with a static plot. A run leaves the gif untouched
# for 13 s, scrolls it out of view and back 21 times, parks it off screen for
# 34 s, types next to the plot 21 times and scrolls back; marks in the
# recording name each step. tests/lib/stream_measure.py reads the recording
# twice into Ghostty models, once as the terminal got it and once with every
# Kitty graphics command removed (the screen Neovim drew), and checks:
#   M1  the gif plays: at least 157 frame changes in 13 s with no input
#   M2  no escape sequence is cut while the gif is in view and the screen scrolls
#   M3  no screen differs from the one Neovim drew while it scrolls
#   M4  the same for 34 s with the gif off screen
#   M5  an off-screen gif sends nothing and graphics traffic stays under 9 KB
#   M6  typing next to a static plot cuts nothing and writes no graphics
#   M7  back in view, the first frame is the one the gif's own clock is at
#   M8  it comes within 80 ms of the gif showing and the gif plays on
#   M9  every graphics byte the terminal got was sent with nvim_ui_send
#   M10 no escape sequence is cut anywhere in the recording
# Neovim 0.11 has no in-order write, so its mode (N1 to N4) checks the
# reduced race instead: N1 at most half the cuts of the tree before the fix
# (PRE011_CUTS), N2 none while parked, N3 nothing from the parked gif, N4 none
# while typing.
#
# The checks of timing (M1, M7, M8; N1, N4) say something about the product only
# when the host let the pipeline run. tests/lib/stream_sampler.py follows tmux,
# both relays, the shell and Neovim 20 times a second and records how long each
# waited for a CPU and how much of the host's CPU was idle; a timed check beyond
# its limit prints UNDECIDED (not a failure) when those waits in its window add
# up to more than 2 % of the window plus 20 ms, or the host had under 10 % of its
# CPU idle for longer than that, and FAIL when neither holds. Every other check
# always decides. With JNV_STREAM_DECIDE=1 an UNDECIDED check is a FAIL: use it
# where the result must be decided, and rerun when it says so. The undecided
# checks are counted in one line before the verdict.
#
# Needs the headless pixel harness, ImageMagick 7 (magick), tmux and the
# built core. JNV_STREAM_NVIM=/path/to/nvim runs another Neovim (0.11 mode
# when it has no nvim_ui_send); JNV_STREAM_MEASURE=1 only prints the numbers;
# JNV_STREAM_KEEP=DIR copies each run's folder (recording included) to DIR;
# JNV_STREAM_DECIDE=1 turns an UNDECIDED timed check into a failure.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/core/target/release/jupynvim-core"
[ -x "$BIN" ] || { echo "SKIP stream_measure: build core first ($BIN)"; exit 0; }
# Neovim 0.11.5, the tree before the fix, three runs of this scenario (2026-11-02,
# Apple M3 Max, arm64 macOS with 16 cores, a quiet host): the whole recording's cut
# escape sequences plus UTF-8 splits (JNV_STREAM_NVIM=<0.11.5> JNV_STREAM_MEASURE=1).
# N1 allows each run at most half of the smallest of them.
PRE011_CUTS="48 44 50"
source "$(dirname "$0")/lib/tmux.sh"
NVIM_BIN="${JNV_STREAM_NVIM:-nvim}"
MEASURE="${JNV_STREAM_MEASURE:-}"
KEEP="${JNV_STREAM_KEEP:-}"
DECIDE="${JNV_STREAM_DECIDE:-}"
command -v magick >/dev/null || { echo "SKIP stream_measure: no ImageMagick 7 (magick)"; exit 0; }
VK="$ROOT/tests/lib/vkitty"
if [ ! -f "$VK/relay.py" ]; then
  # a tree from before the harness has neither it nor its screen test; a tree
  # with the screen test and no harness is broken
  if [ ! -e "$ROOT/tests/vkitty_screen.sh" ]; then
    echo "SKIP stream_measure: needs the headless pixel harness tests/lib/vkitty, which this tree does not have yet"
    exit 0
  fi
  echo "FAIL stream_measure: tests/vkitty_screen.sh exists but the harness $VK/relay.py does not"
  exit 1
fi
source "$VK/python.sh"
VKPY="$(jnv_vkitty_python)" || { echo "FAIL stream_measure: no python3 can run the pixel harness (numpy, fontTools, Pillow with raqm)"; exit 1; }
MODE=011
"$NVIM_BIN" --headless -u NONE -c 'lua io.stdout:write(vim.api.nvim_ui_send and "y" or "n")' -c 'qa!' 2>/dev/null \
  | grep -q y && MODE=012
PRE011_MIN=""
for c in $PRE011_CUTS; do
  if [ -z "$PRE011_MIN" ] || [ "$c" -lt "$PRE011_MIN" ]; then PRE011_MIN="$c"; fi
done
if [ "$MODE" = 011 ] && [ -z "$PRE011_MIN" ] && [ -z "$MEASURE" ]; then
  echo "FAIL stream_measure: PRE011_CUTS is empty, so N1 has nothing to compare with"
  exit 1
fi
# the stripper and the damage test, on streams with known answers
"$VKPY" -I "$ROOT/tests/lib/stream_measure.py" --self-test \
  || { printf '\nSTREAM-MEASURE: 1 FAILED (the measuring code itself)\n'; exit 1; }
WORK="$(mktemp -d "$TMPDIR/jupynvim_measure.XXXXXX")"
S="jupy_measure_$$"
SAMPLER_PID=""
cleanup() {
  [ -n "$SAMPLER_PID" ] && kill "$SAMPLER_PID" 2>/dev/null
  jnv_tmux_stop; rm -rf "$WORK"
}
jnv_on_exit cleanup

# 16 frames at 80 ms, and a static plot
( cd "$WORK" && for i in $(seq 0 15); do
    magick -size 480x320 gradient:'#1e3050-#402060' -fill "rgb($((i * 15)),200,$((240 - i * 15)))" \
      -draw "circle $((40 + i * 25)),160 $((40 + i * 25)),110" "f_$(printf %02d "$i").png" || exit 1
  done \
  && magick -delay 8 -loop 0 f_*.png anim.gif \
  && magick -size 640x400 xc:white -stroke '#3070c0' -strokewidth 3 -fill none \
       -draw 'polyline 20,380 180,320 340,240 500,160 620,40' plot.png ) \
  || { echo "FAIL stream_measure: ImageMagick could not make the images"; exit 1; }

# the gif cell, a 28-line cell, a 12-line cell with the plot
python3 - "$WORK" <<'PY'
import base64, json, os, sys
w = sys.argv[1]
b = lambda f: base64.b64encode(open(os.path.join(w, f), "rb").read()).decode()
long_src = "\n".join("v%02d = [i * %d for i in range(%d)]  # row %d" % (i, i, i + 3, i) for i in range(28))
plot_src = "\n".join(["q%02d = %d" % (i, i) for i in range(11)] + ["plot()"])
def code(i, src, outs=()):
    return {"cell_type": "code", "id": "c%d" % i, "metadata": {}, "execution_count": i,
            "outputs": list(outs), "source": src}
img = lambda m, f: {"output_type": "display_data", "metadata": {}, "data": {m: b(f), "text/plain": "<img>"}}
cells = [code(1, "show_gif()", [img("image/gif", "anim.gif")]),
         code(2, long_src, [{"output_type": "stream", "name": "stdout", "text": "done\n"}]),
         code(3, plot_src, [img("image/png", "plot.png")])]
json.dump({"cells": cells, "metadata": {"language_info": {"name": "python"}},
           "nbformat": 4, "nbformat_minor": 5}, open(os.path.join(w, "nb.ipynb"), "w"))
PY

CAP() { tmux capture-pane -t "=$S:" -p; }
# CAPWAIT FILE [WANT [NOT [CAP]]]: the screen once it shows WANT and not NOT
# (the keys before it were processed, and the terminal drew their result), or as
# it is after CAP seconds (15). The screen goes to FILE either way; the status is
# 0 when it matched and 1 on a timeout, so a caller cannot go on with a screen
# the terminal has not finished drawing.
CAPWAIT() {
  local end=$((SECONDS + ${4:-15})) c rc=1
  while :; do
    c="$(CAP)"
    if { [ -z "${2:-}" ] || [[ "$c" == *"$2"* ]]; } && { [ -z "${3:-}" ] || [[ "$c" != *"$3"* ]]; }; then
      rc=0
      break
    fi
    [ "$SECONDS" -ge "$end" ] && break
    sleep 0.1
  done
  printf '%s\n' "$c" > "$1"
  return "$rc"
}
# a run that cannot go on (the gif never animates, the relay does not answer a
# mark) ends the test here with one FAIL and the screen: every step after it
# would only wait out its timeouts
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
  printf '\nSTREAM-MEASURE: %d FAILED (stopped early)\n' "$fails"
  exit 1
}
# mark NAME: a mark in the recording, taken once the relay has everything the
# program wrote before it, and acknowledged by the relay (the ack of an
# earlier mark is removed first, so it cannot pass for this one)
mark() {
  rm -f "$RUN/ctl.ack"
  perl -e 'alarm 10; open(my $f, ">", $ARGV[0]) or exit 1; print $f "mark $ARGV[1]\n"; close $f' \
    "$RUN/ctl" "$1" || stop_early "mark $1 could not be sent to the relay"
  local end=$((SECONDS + 30)) v=""
  while :; do
    v=""
    [ -f "$RUN/ctl.ack" ] && IFS= read -r -d '' v < "$RUN/ctl.ack" 2>/dev/null
    if [ "${v%$'\n'}" = "$1" ]; then
      # the sampler tags its readings with the last name in this file
      printf '%s\n' "$1" >> "$RUN/marks.log"
      return 0
    fi
    [ "$SECONDS" -ge "$end" ] && stop_early "the relay acknowledged mark $1  -- not within 30 s"
    sleep 0.01
  done
}

fails=0
leak=0
UNDECIDED_N=0
UNDECIDED_LIST=""
run_one() {
  RUN="$WORK/run$1"
  mkdir -p "$RUN/state"
  # __stats(tag) appends the image writer's counters; ready is written once
  # the gif animates (a placement with a frame timer), after meta (the gif's
  # image id and frame delays) and frames.txt (each frame's base64, a line
  # each) are
  cat > "$RUN/init.lua" <<LUA
vim.opt.runtimepath:prepend("$ROOT")
vim.o.swapfile = false
vim.o.termguicolors = true
vim.o.number = true
require("jupynvim").setup({ core_path = "$BIN", auto_venv = false })
local I = require("jupynvim.notebook.image")
function _G.__stats(tag)
  local f = io.open("$RUN/stats", "a")
  f:write(string.format("%s tty_n=%d tty_bytes=%d ui_send_n=%d ui_send_bytes=%d frames_sent=%d frames_skipped=%d place_writes=%d remote=%s\n",
    tag, I._tty_n or 0, I._tty_bytes or 0, I._ui_send_n or 0, I._ui_send_bytes or 0, I._frames_sent or 0,
    I._frames_skipped or 0, I._place_writes or 0, tostring(I._remote_mode)))
  f:close()
end
local ready = vim.uv.new_timer()
ready:start(100, 100, vim.schedule_wrap(function()
  for _, p in pairs(I._placements) do
    if p.timer then
      ready:stop()
      local m = io.open("$RUN/meta", "w")
      m:write(string.format("gid=%d delays=%s\n", p.image_id, table.concat(p.delays or {}, ",")))
      m:close()
      local fr = io.open("$RUN/frames.txt", "w")
      for _, b64 in ipairs(p.frames) do fr:write(b64, "\n") end
      fr:close()
      local f = io.open("$RUN/ready", "w"); f:write("1"); f:close()
      return
    end
  end
end))
LUA
  # nvim on the slow relay, recorded from the first byte: the pane's command
  # waits for the go file. The relay (the harness's recorder, with no hop and
  # no answers of its own: the multiplexer answers the status and version
  # requests, and Neovim runs with TMUX unset, so the stream is the one a
  # terminal gets directly) runs the lagging reader, which runs a shell on its
  # terminal that runs nvim and outlives it, as the user's shell does; it
  # prints UI-GONE when the UI has quit and waits for the end file.
  cat > "$RUN/run.sh" <<SH
while [ ! -e "$RUN/go" ]; do sleep 0.02; done
exec "$VKPY" -I "$VK/relay.py" --rec "$RUN/rec" --ctl "$RUN/ctl" --hop none --respond none --media-unlink no \
  -- python3 -I "$ROOT/tests/lib/tty_relay.py" -- sh -c 'env -u TMUX -u TMUX_PANE TERM=xterm-256color \
  XDG_STATE_HOME="$RUN/state" "$NVIM_BIN" -i NONE -u "$RUN/init.lua" "$WORK/nb.ipynb"; printf UI-GONE; \
  while [ ! -e "$RUN/end" ]; do sleep 0.1; done'
SH
  tmux new-session -d -s "$S" -x 160 -y 50 "sh $(printf %q "$RUN/run.sh")"
  # the processes the run's speed depends on: the multiplexer's server and the
  # pane's process, with everything they start
  local roots
  roots="$(tmux display-message -p '#{pid}') $(tmux display-message -p -t "=$S:" '#{pane_pid}')"
  perl -e 'alarm 900; exec @ARGV' python3 -I "$ROOT/tests/lib/stream_sampler.py" "$RUN" $roots > "$RUN/sampler.log" 2>&1 &
  SAMPLER_PID=$!
  touch "$RUN/go"
  jnv_wait_file_eq "$RUN/ready" 1 40 || stop_early "run $1: the gif started to animate  -- not within 40 s; the screen:"

  # untouched: the gif plays with no input
  sleep 1
  mark u0
  sleep 13.5
  mark u1

  # the screen scrolls while the gif plays: 30 rows down takes the gif's image
  # rows out of view, 30 up brings them back
  local k=0 s i key
  for s in $(seq 1 21); do
    for i in $(seq 1 15); do
      if [ $((k % 60)) -lt 30 ]; then key=C-e; else key=C-y; fi
      tmux send-keys -t "=$S:" "$key"; sleep 0.03
      k=$((k + 1))
    done
    mark "s$(printf %02d "$s")"
  done

  # the plot cell on top, the gif off screen, for 34 s
  tmux send-keys -t "=$S:" gg; sleep 0.3
  tmux send-keys -t "=$S:" j; sleep 0.3; tmux send-keys -t "=$S:" j; sleep 0.3
  tmux send-keys -t "=$S:" zt
  # a mark taken while the terminal still replays the scroll would measure the
  # scroll, not the park: the parked screen must show, or the run ends here
  CAPWAIT "$RUN/cap_parked.txt" "plot()" "show_gif()" 60 \
    || stop_early "run $1: the parked screen (plot() shown, show_gif() gone) did not show within 60 s; the screen:"
  sleep 0.5
  mark p00
  for s in $(seq 1 31); do
    sleep 1.097
    mark "p$(printf %02d "$s")"
  done

  # typing next to the plot: nothing changes for the terminal's images
  tmux send-keys -t "=$S:" Enter; sleep 0.5; tmux send-keys -t "=$S:" o; sleep 0.3
  mark t00
  for s in $(seq 1 21); do
    for key in x x x x BSpace BSpace BSpace BSpace; do tmux send-keys -t "=$S:" "$key"; sleep 0.06; done
    mark "t$(printf %02d "$s")"
  done
  tmux send-keys -t "=$S:" Escape

  # back to the top: the gif resumes where its clock is; gg follows the mark
  # at once, so every byte of the way back comes after it
  tmux send-keys -t "=$S:" Escape; sleep 0.4
  mark b0
  tmux send-keys -t "=$S:" gg
  sleep 1.5
  mark b1

  # mark e first, then the stats line: with the gif in view a frame sent after
  # the stats call can reach the recording before the mark, and M9 compares the
  # recording at e with what was sent by the time of the call. Everything the
  # terminal got by mark e was sent before the call, so it is counted. The stats
  # line comes after mark e.
  mark e
  tmux send-keys -t "=$S:" ":lua __stats('end')" Enter
  jnv_wait_lines "$RUN/stats" 1 15 || echo "run $1: stats end: no answer"
  tmux send-keys -t "=$S:" Escape ":qa!" Enter
  touch "$RUN/end"
  # the sampler takes one last round and ends; the cap is a few seconds, then
  # only its own process is stopped
  for i in $(seq 1 50); do kill -0 "$SAMPLER_PID" 2>/dev/null || break; sleep 0.1; done
  kill "$SAMPLER_PID" 2>/dev/null
  wait "$SAMPLER_PID" 2>/dev/null
  SAMPLER_PID=""
  for i in $(seq 1 200); do tmux has-session -t "=$S" 2>/dev/null || break; sleep 0.1; done
  # the relay writes done last, once the program and the lagging reader are gone
  for i in $(seq 1 100); do [ -e "$RUN/rec/done" ] && break; sleep 0.1; done
  jnv_stop_session "$S" || leak=1

  local out rc n
  out="$("$VKPY" -I "$ROOT/tests/lib/stream_measure.py" "$RUN" --run "$1" --mode "$MODE" --pre011 "${PRE011_MIN:-0}" ${MEASURE:+--measure} ${DECIDE:+--decide} 2>&1)"
  rc=$?
  printf '%s\n' "$out"
  # the timing checks the host left undecided: "run R <check id>"
  local u
  u="$(printf '%s\n' "$out" | sed -n 's/^UNDECIDED run \([0-9][0-9]*\): \([A-Z][0-9]*\) .*$/run \1 \2/p')"
  if [ -n "$u" ]; then
    while IFS= read -r line; do
      UNDECIDED_N=$((UNDECIDED_N + 1))
      UNDECIDED_LIST="${UNDECIDED_LIST:+$UNDECIDED_LIST, }$line"
    done <<EOF_U
$u
EOF_U
  fi
  n="$(printf '%s\n' "$out" | grep -c '^FAIL')"
  if [ "$rc" != 0 ] && [ -z "$MEASURE" ] && [ "$n" = 0 ]; then
    echo "FAIL run $1: stream_measure.py  -- exited $rc"
    n=1
  fi
  [ -z "$MEASURE" ] && fails=$((fails + n))
  if [ -n "$KEEP" ]; then
    mkdir -p "$KEEP" && cp -R "$RUN" "$KEEP/run$1" || echo "run $1: could not copy the run folder to $KEEP"
  fi
}
for r in 1 2 3; do run_one "$r"; done
jnv_tmux_stop || leak=1

"$VKPY" -I "$ROOT/tests/lib/stream_measure.py" --table --mode "$MODE" "$WORK/run1" "$WORK/run2" "$WORK/run3"
if [ -n "$MEASURE" ]; then
  echo "MEASURE stream_measure: cuts=$("$VKPY" -I "$ROOT/tests/lib/stream_measure.py" --cuts "$WORK/run1" "$WORK/run2" "$WORK/run3")"
  exit 0
fi
if [ "$leak" = 0 ]; then
  echo "  ok nvim and its terminal multiplexer stopped cleanly"
else
  echo "FAIL nvim and its terminal multiplexer stopped cleanly  -- LEAK above"
  fails=$((fails + 1))
fi
if [ "$UNDECIDED_N" != 0 ]; then
  printf '\nstream_measure: %d timing checks undecided (host busy): %s\n' "$UNDECIDED_N" "$UNDECIDED_LIST"
fi
if [ "$fails" = 0 ]; then
  printf '\nSTREAM-MEASURE: ALL PASSED\n'
  exit 0
fi
printf '\nSTREAM-MEASURE: %d FAILED\n' "$fails"
exit 1

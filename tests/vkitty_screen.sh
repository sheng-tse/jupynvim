#!/usr/bin/env bash
# The headless Kitty graphics harness against real tmux (tests/lib/vkitty).
#
#   bash tests/vkitty_screen.sh [CASE ...]
#   VKITTY_ARTIFACTS=DIR bash tests/vkitty_screen.sh 2   (keeps the pictures and reports in DIR)
#
# Cases are named by number, as screen_lib.sh's run_cases selects them:
#   1  battery      every VT stream of tests/lib/vkitty/battery.py runs in a tmux
#                   pane (80x24, stdin in raw mode); the pane's capture and cursor
#                   must agree with the emulator's screen (text, width, style, cursor)
#   2  plot_fifo    a stored plot in a real notebook (nvim, the backend, tmux 160x50),
#                   recorded by the relay in the pane. The backend's graphics go to a
#                   FIFO (JUPYNVIM_TTY, the gfx channel), so one writer feeds the pane.
#                   The screen at the top and after scrolling must match tmux, the stream
#                   must show no interleaving (checks.py cuts: no cut sequence, no UTF-8
#                   splice, no dropped or foreign passthrough), and the plot's own pixels
#                   must be in its placeholder cells, over the whole 48 columns and the
#                   expected rows (checks.py tiles --expect-rows --expect-cols, fit-free)
#   3  plot_full    the same notebook with no FIFO: the graphics go through nvim's own
#                   stream (the full stream, the way a user runs it). Its grid and tiles
#                   checks run in full on a clean stream and on a stream whose only
#                   interference is UTF-8 splices (tmux keeps a split character whole, and
#                   so does the emulator). Until the in-order writer (nvim_ui_send in
#                   lua/jupynvim/notebook/image.lua) is in use, the case prints one
#                   SKIP line for the tiles when the recording shows cuts, passthrough
#                   drops, foreign tokens in a passthrough body or warnings, and one SKIP
#                   line for the grid when foreign tokens came out of a passthrough body.
#                   With the writer in use (in the tree, and nvim_ui_send in the Neovim
#                   that runs the case) nothing is skipped and every interleaving count
#                   must be 0.
#   4  kernel_plot  a notebook whose cell is run on the kernel: the matplotlib figure the
#                   kernel sends back must be shown fitted in its box (checks.py fit), from
#                   one writer
#   5  snap_cursor the snapshot helper (vk_snap) on a program that only moves its cursor around
#                   the mark: the first attempt must be repeated (the cursor of the later capture
#                   differs from the one before the mark), and the settled snapshot's grid check,
#                   which compares the cursor with the emulator's at the mark, must pass. No nvim
#                   and no backend, so it runs in about 3 s.
#   6  writer_rule case 3 expects the in-order writer only when the tree has it and the Neovim
#                   that runs the case has nvim_ui_send (stub nvim on PATH; no tmux, no backend)
#
# Needs tmux (the private-server wrapper of tests/lib/tmux.sh, tmux 3.5a is the
# version the battery was measured on), a python with numpy, Pillow built with
# raqm and fontTools for the harness (tests/lib/vkitty/requirements.txt), and the
# kernel's python with matplotlib for the plot pictures. Without the first, the
# test fails. Cases 2 to 4 start a real nvim and the backend (core/target/release).
set -u
source "$(dirname "$0")/screen_lib.sh"
source "$ROOT/tests/lib/vkitty/python.sh"
VKPY="$(jnv_vkitty_python)" || { echo "FAIL vkitty screen: no python for the harness"; exit 1; }
VK="$ROOT/tests/lib/vkitty"
VK_RAN=0
# Pictures and reports of the plot cases. Outside the run dir when VKITTY_ARTIFACTS names one, so
# they survive the run's cleanup and a restart.
ART="${VKITTY_ARTIFACTS:-$JNV_RUN_ROOT/vkitty-artifacts}"
mkdir -p "$ART"

# case_1 battery: every stream of the battery, one pane each, compared with the emulator
case_1() {
  VK_RAN=$((VK_RAN + 1))
  local name cur prev i names listed compared=0
  # The list is read before the loop, and its exit status and count are checked: a
  # --list that fails or names nothing must fail this case, not run zero streams and pass.
  names="$("$VKPY" -I "$VK/battery.py" --list)" \
    || { fail_later "battery: battery.py --list failed"; return 0; }
  listed="$(printf '%s\n' "$names" | grep -c .)"
  [ "$listed" -gt 0 ] || { fail_later "battery: battery.py --list named no stream"; return 0; }
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    stop_session
    "$VKPY" -I "$VK/battery.py" "$name" 80 24 "$WORK/b_$name.bin" \
      || { fail_later "battery $name: the stream could not be written"; continue; }
    tmux new-session -d -s "$S" -x 80 -y 24 \
      "stty raw -echo; cat '$WORK/b_$name.bin'; : > '$WORK/b_$name.done'; exec sleep 120"
    _jnv_poll 10 test -e "$WORK/b_$name.done" \
      || { fail_later "battery $name: the pane did not finish the stream in 10 s"; continue; }
    # cat has written the stream; wait until the pane has drawn all of it (the capture stops changing)
    prev=""
    for i in $(seq 1 60); do
      tmux capture-pane -t "=$S:" -p -e -N > "$WORK/b_$name.ansi"
      if [ "$i" -gt 1 ] && cmp -s "$WORK/b_$name.ansi" "$WORK/b_$name.prev"; then break; fi
      cp "$WORK/b_$name.ansi" "$WORK/b_$name.prev"
      sleep 0.1
    done
    cur="$(tmux display-message -p -t "=$S:" '#{cursor_x},#{cursor_y}')"
    stop_session
    compared=$((compared + 1))
    if "$VKPY" -I "$VK/grid_tmux.py" compare --stream "$WORK/b_$name.bin" --size 80x24 \
        --capture "$WORK/b_$name.ansi" --cursor "$cur" > "$WORK/b_$name.out" 2>&1; then
      echo "ok battery $name"
    else
      cat "$WORK/b_$name.out" >&2
      fail_later "battery $name: emulator and tmux differ"
    fi
  done <<< "$names"
  [ "$compared" -eq "$listed" ] || fail_later "battery: compared $compared of $listed streams"
}

# ---------------------------------------------------------------- helpers ---
# The real-notebook cases (2 to 4). Each one runs nvim and the backend in a pane of a private
# tmux server, with the relay (tests/lib/vkitty/relay.py) between the pane and nvim. Every
# snapshot goes through vk_snap, so the mark in the recording and the tmux capture show the
# same screen.

# vk_plot_png PATH W H: a line plot of fixed data, W x H pixels, drawn by the kernel's python
# (matplotlib, Agg). The size is checked with the harness python and PIL.
vk_plot_png() {
  local path="$1" w="$2" h="$3"
  [ -n "${JNV_KERNEL_PYTHON:-}" ] || { fail_later "vkitty: no kernel python for the plot picture"; return 1; }
  "$JNV_KERNEL_PYTHON" - "$path" "$w" "$h" <<'PY' \
    || { fail_later "vkitty: matplotlib could not draw $path (the kernel needs matplotlib)"; return 1; }
import sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
path, w, h = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
fig = plt.figure(figsize=(w / 100, h / 100), dpi=100)
ax = fig.add_subplot(111)
ax.plot([1, 3, 2, 4, 2.5, 5], marker="o")
ax.set_title("vkitty plot")
fig.savefig(path, dpi=100)
PY
  "$VKPY" -I -B -c 'import sys
from PIL import Image
im = Image.open(sys.argv[1])
want = (int(sys.argv[2]), int(sys.argv[3]))
sys.exit(0 if im.size == want else "%s is %dx%d, %dx%d expected" % (sys.argv[1], im.size[0], im.size[1], want[0], want[1]))' \
    "$path" "$w" "$h" || { fail_later "vkitty: the plot picture $path is not ${w}x${h}"; return 1; }
}

# vk_nb PATH MODE PNG: a notebook. stored: a markdown heading, a code cell whose output is PNG
# (display_data, image/png), then a code cell. kernel: one code cell, no outputs (the cursor
# starts in it, so :JupynvimRunCell needs no navigation).
vk_nb() {
  "$VKPY" -I -B - "$1" "$2" "${3:-}" <<'PY' || { fail_later "vkitty: cannot write the notebook $1"; return 1; }
import base64
import json
import sys
path, mode, png = sys.argv[1], sys.argv[2], sys.argv[3]


def code(i, src, outputs=()):
    return {"cell_type": "code", "id": "c%d" % i, "metadata": {}, "source": src,
            "execution_count": 1 if outputs else None, "outputs": list(outputs)}


if mode == "stored":
    with open(png, "rb") as fh:
        b64 = base64.b64encode(fh.read()).decode("ascii")
    out = {"output_type": "display_data", "metadata": {},
           "data": {"image/png": b64, "text/plain": "<Figure>"}}
    cells = [{"cell_type": "markdown", "id": "m1", "metadata": {}, "source": "# vkitty plot"},
             code(1, "plot()", [out]),
             code(2, "x = 1")]
elif mode == "kernel":
    cells = [code(1, "import matplotlib.pyplot as plt\nplt.plot([1, 3, 2, 4])\n"
                     "plt.title('vkitty kernel')\nplt.show()")]
else:
    sys.exit("vk_nb: unknown mode %r" % mode)
nb = {"cells": cells, "nbformat": 4, "nbformat_minor": 5,
      "metadata": {"kernelspec": {"name": "python3", "display_name": "Python 3",
                                  "language": "python"}}}
with open(path, "w", encoding="ascii") as fh:
    json.dump(nb, fh)
PY
}

# vk_launch NAME NB GFX: nvim on NB in a new pane of this run's tmux server, under the relay. The
# relay runs inside the pane, so its hop (auto) is tmux, the condition under which jupynvim wraps
# its escapes. GFX=1 gives the backend a FIFO for its graphics (JUPYNVIM_TTY, the gfx channel).
vk_launch() {
  local name="$1" nb="$2" gfx="${3:-0}" gfxarg="" gfxenv="" script="$WORK/launch_$1.sh"
  if [ "$gfx" = 1 ]; then
    gfxarg="--gfx-fifo $WORK/gfx_$name"
    gfxenv="JUPYNVIM_TTY=$WORK/gfx_$name"
  fi
  # The command goes into a script: a long line typed into the pane's shell was echoed, but never ran.
  printf '%s\n' "cd $WORK && $VKPY -I $VK/relay.py --rec $WORK/rec_$name --ctl $WORK/ctl_$name --respond ghostty $gfxarg -- env $gfxenv XDG_STATE_HOME=$WORK/state nvim -u $WORK/init.lua $nb" > "$script"
  stop_session
  tmux new-session -d -s "$S" -x 160 -y 50
  tmux send-keys -t "$S" "sh $script" Enter
}

_vk_has_text() { tmux capture-pane -t "=$S:" -p | grep -qF -- "$1"; }
# vk_wait_text TEXT SECS: the pane shows TEXT
vk_wait_text() { _jnv_poll "$2" _vk_has_text "$1"; }
_vk_has_placeholders() {
  tmux capture-pane -t "=$S:" -p | "$VKPY" -I -B -c 'import sys
sys.exit(0 if "\U0010eeee" in sys.stdin.read() else 1)'
}
# vk_wait_placeholders SECS: the pane shows a Kitty placeholder (U+10EEEE)
vk_wait_placeholders() { _jnv_poll "$1" _vk_has_placeholders; }

# vk_mark NAME MARK: a mark of the recording of NAME, acknowledged by the relay. The ack of an
# earlier mark of this name is removed first: vk_snap repeats mark names, and an ack left by
# the earlier mark would look like this one, before the new mark is recorded.
vk_mark() {
  local name="$1" mark="$2"
  rm -f "$WORK/ctl_$name.ack"
  perl -e 'alarm 10; open(my $f, ">", $ARGV[0]) or exit 1; print $f "mark $ARGV[1]\n"; close $f' \
    "$WORK/ctl_$name" "$mark" \
    || { fail_later "vkitty $name: could not send mark $mark to the relay"; return 1; }
  jnv_wait_file_eq "$WORK/ctl_$name.ack" "$mark" 40 \
    || { fail_later "vkitty $name: the relay did not acknowledge mark $mark within 40 s"; return 1; }
}

# vk_snap NAME MARK: the only way a case takes a snapshot. Up to 5 attempts: capture A, wait
# 0.5 s, capture B (with the cursor, read right after it); when A and B differ the screen is
# still drawing, so the next attempt starts. When they agree, the mark is taken, 0.3 s later the
# capture C is written (with the cursor) and compared with B. Equal text and an equal cursor mean
# the mark shows the settled screen; anything else means the screen or the cursor changed around
# the mark, so the attempt repeats with the same mark name (checks use its last occurrence). The
# cursor counts because vk_grid compares the cursor of C with the emulator's at the mark: a
# program that only moves its cursor around the mark (nvim does, when a kernel start ends in the
# middle of a snapshot: it shows the message, blocks, then puts the cursor back) leaves the text
# unchanged and would fail that comparison on a correct tree.
vk_snap() {
  local name="$1" mark="$2" i cap="$WORK/cap_${1}_$2.ansi"
  for i in 1 2 3 4 5; do
    tmux capture-pane -t "=$S:" -p -e -N > "$WORK/snap_a_$name.ansi"
    sleep 0.5
    tmux capture-pane -t "=$S:" -p -e -N > "$WORK/snap_b_$name.ansi"
    tmux display-message -p -t "=$S:" '#{cursor_x},#{cursor_y}' > "$WORK/snap_b_$name.cur"
    cmp -s "$WORK/snap_a_$name.ansi" "$WORK/snap_b_$name.ansi" || continue
    vk_mark "$name" "$mark" || return 1
    sleep 0.3
    tmux capture-pane -t "=$S:" -p -e -N > "$cap"
    tmux display-message -p -t "=$S:" '#{cursor_x},#{cursor_y}' > "$cap.cur"
    if cmp -s "$cap" "$WORK/snap_b_$name.ansi" && cmp -s "$cap.cur" "$WORK/snap_b_$name.cur"; then
      echo "ok snap $name $mark (attempt $i)"
      return 0
    fi
  done
  fail_later "vkitty $name: screen never settled for $mark"
  return 1
}

# vk_quit NAME: quit nvim (the relay then writes the end and the done file)
vk_quit() {
  local name="$1"
  k Escape
  k ":qa!" Enter
  jnv_wait_file_eq "$WORK/rec_$name/done" done 30 \
    || fail_later "vkitty $name: the recording did not finish within 30 s of :qa!"
  stop_session
}

# vk_grid NAME MARK: the emulator's screen at the mark against the capture, and its cursor
vk_grid() {
  local name="$1" mark="$2" cur
  cur="$(cat "$WORK/cap_${name}_$mark.ansi.cur")"
  "$VKPY" -I "$VK/checks.py" grid "$WORK/rec_$name" "$mark" "$WORK/cap_${name}_$mark.ansi" \
    --cursor "$cur" || fail_later "vkitty $name $mark: the emulator's screen differs from tmux"
}

# vk_interleave NAME: how another writer's bytes mixed with nvim's in the recording of NAME
# (checks.py cuts). Prints the report and sets VK_LINE (its first line) and VK_CUTS, VK_SPLICES,
# VK_DROPS, VK_BODY and VK_WARNS from it. Returns 1 when the report is missing or malformed.
vk_interleave() {
  local name="$1" v
  "$VKPY" -I -B "$VK/checks.py" cuts "$WORK/rec_$name" > "$WORK/interleave_$name.txt" 2>&1 \
    || { cat "$WORK/interleave_$name.txt" >&2; fail_later "vkitty $name: checks.py cuts failed"; return 1; }
  cat "$WORK/interleave_$name.txt"
  VK_LINE="$(head -n 1 "$WORK/interleave_$name.txt")"
  # shellcheck disable=SC2086
  set -- $VK_LINE
  VK_CUTS=${1#cuts=}; VK_SPLICES=${2#splices=}; VK_DROPS=${3#tmux_drops=}
  VK_BODY=${4#body_other=}; VK_WARNS=${5#warnings=}
  for v in "$VK_CUTS" "$VK_SPLICES" "$VK_DROPS" "$VK_BODY" "$VK_WARNS"; do
    case "$v" in
      ''|*[!0-9]*) fail_later "vkitty $name: checks.py cuts printed '$VK_LINE', not the five counts"; return 1 ;;
    esac
  done
}

# vk_one_writer NAME: the recording of NAME shows one writer: no cut sequence, no UTF-8 splice,
# no passthrough that tmux drops and no foreign token in a passthrough body. Warnings are
# printed, not asserted.
vk_one_writer() {
  local name="$1"
  vk_interleave "$name" || return 0
  if [ "$VK_CUTS" -eq 0 ] && [ "$VK_SPLICES" -eq 0 ] && [ "$VK_DROPS" -eq 0 ] && [ "$VK_BODY" -eq 0 ]; then
    echo "ok one writer $name: $VK_LINE"
  else
    fail_later "vkitty $name: $VK_LINE, expected cuts=0 splices=0 tmux_drops=0 body_other=0 (another writer's bytes are interleaved with nvim's)"
  fi
}

# vk_artifact NAME MARK: the picture and the report of the recording at the mark, into ART
vk_artifact() {
  local name="$1" mark="$2"
  "$VKPY" -I "$VK/replay.py" "$WORK/rec_$name" --at "$mark" \
    --png "$ART/${name}_$mark.png" --report "$ART/${name}_$mark.json" \
    || fail_later "vkitty $name $mark: replay.py could not write the artifacts"
}

# vk_stats NAME: the graphics counts of the recording (the per-image wire bytes against the total,
# by the rule checks.py stats prints)
vk_stats() {
  local name="$1"
  "$VKPY" -I -B "$VK/checks.py" stats "$WORK/rec_$name" > "$WORK/stats_$name.txt" 2>&1 \
    || { cat "$WORK/stats_$name.txt" >&2; fail_later "vkitty $name: the graphics counts do not add up"; return 0; }
  cat "$WORK/stats_$name.txt"
}

# vk_plot_flow NAME GFX PNG: the stored plot on screen, then scrolled until its top image row is 3.
# Takes the snapshots "open" (before the scroll) and "scrolled" (its top row in toprow).
vk_plot_flow() {
  local name="$1" gfx="$2" png="$3" n top
  vk_nb "$WORK/nb_$name.ipynb" stored "$png" || return 1
  vk_launch "$name" "$WORK/nb_$name.ipynb" "$gfx"
  vk_wait_text "vkitty plot" 20 || {
    tmux capture-pane -t "=$S:" -p >&2
    fail_later "vkitty $name: the notebook did not show its heading within 20 s"
    return 1
  }
  vk_wait_placeholders 20 \
    || { fail_later "vkitty $name: no plot placeholder appeared within 20 s"; return 1; }
  nv_sync || return 1
  vk_snap "$name" open || return 1
  top=-1
  for n in $(seq 1 40); do
    k C-e
    nv_sync || return 1
    tmux capture-pane -t "=$S:" -p -e -N > "$WORK/scroll_$name.ansi"
    top="$("$VKPY" -I "$VK/checks.py" toprow "$WORK/scroll_$name.ansi")"
    [ "$top" -ge 3 ] 2>/dev/null && break
  done
  [ "${top:--1}" -ge 3 ] 2>/dev/null \
    || { fail_later "vkitty $name: the plot did not scroll to its row 3 in 40 steps (toprow ${top:-none})"; return 1; }
  nv_sync || return 1
  vk_snap "$name" scrolled || return 1
  echo "$top" > "$WORK/top_$name"
}

# vk_tiles NAME MARK PNG [EXTRA...]: checks.py tiles on the recording at the mark
vk_tiles() {
  local name="$1" mark="$2" png="$3"
  shift 3
  "$VKPY" -I "$VK/checks.py" tiles "$WORK/rec_$name" "$mark" "$png" "$@" \
    || fail_later "vkitty $name $mark: the placeholder tiles differ from the picture"
}

# vk_negative_controls NAME PNG: the tile check must fail on a render without images and on a
# vertically flipped picture (exit status 1 exactly; 2 would be a usage error, not a failure)
vk_negative_controls() {
  local name="$1" png="$2" rc flipped="$WORK/flipped_$1.png"
  "$VKPY" -I -B -c 'import sys
from PIL import Image
Image.open(sys.argv[1]).transpose(Image.Transpose.FLIP_TOP_BOTTOM).save(sys.argv[2])' \
    "$png" "$flipped" || { fail_later "vkitty $name: could not flip the picture"; return 0; }
  "$VKPY" -I "$VK/checks.py" tiles "$WORK/rec_$name" open "$png" --no-images > "$WORK/neg_noimg_$name.out" 2>&1
  rc=$?
  if [ "$rc" -eq 1 ]; then
    echo "ok negative control $name: tiles with --no-images fail (exit 1)"
  else
    cat "$WORK/neg_noimg_$name.out" >&2
    fail_later "vkitty $name: tiles with --no-images exited $rc, expected 1"
  fi
  "$VKPY" -I "$VK/checks.py" tiles "$WORK/rec_$name" open "$flipped" > "$WORK/neg_flip_$name.out" 2>&1
  rc=$?
  if [ "$rc" -eq 1 ]; then
    echo "ok negative control $name: tiles against a flipped picture fail (exit 1)"
  else
    cat "$WORK/neg_flip_$name.out" >&2
    fail_later "vkitty $name: tiles against a flipped picture exited $rc, expected 1"
  fi
}

# case_2 plot_fifo: the backend's graphics on the gfx FIFO (variant B)
case_2() {
  VK_RAN=$((VK_RAN + 1))
  local png="$WORK/plot_624.png" top
  vk_plot_png "$png" 624 528 || return 0
  vk_plot_flow plotb 1 "$png" || return 0
  top="$(cat "$WORK/top_plotb")"
  vk_grid plotb open
  vk_grid plotb scrolled
  vk_quit plotb
  vk_one_writer plotb
  vk_tiles plotb open "$png" --expect-rows 0:15 --expect-cols 0:47
  vk_tiles plotb scrolled "$png" --expect-rows "$top:15" --expect-cols 0:47
  vk_negative_controls plotb "$png"
  vk_stats plotb
  vk_artifact plotb open
  vk_artifact plotb scrolled
}

# vk_nvim_has_ui_send: the nvim that PATH gives a pane has nvim_ui_send (Neovim 0.12 and later)
vk_nvim_has_ui_send() {
  local got
  got="$(perl -e 'alarm 30; exec @ARGV' nvim --headless -u NONE -i NONE \
    -c 'lua io.stdout:write(vim.api.nvim_ui_send and "yes" or "no")' -c 'qa!' 2>/dev/null)"
  [ "${got##*$'\n'}" = yes ] || [ "$got" = yes ]
}

# vk_writer_in_use [IMAGE_LUA]: prints yes when the tree's image.lua has the in-order writer
# (nvim_ui_send) and this Neovim has the call, no when the tree lacks the writer, no-nvim when the
# tree has it and the Neovim does not.
vk_writer_in_use() {
  local image="${1:-$ROOT/lua/jupynvim/notebook/image.lua}"
  grep -q nvim_ui_send "$image" 2>/dev/null || { echo no; return 0; }
  if vk_nvim_has_ui_send; then echo yes; else echo no-nvim; fi
}

# case_3 plot_full: the full stream, no FIFO (variant A). The graphics go through nvim's stream.
# Without the FIFO and without JUPYNVIM_TTY the backend cannot attach to a terminal, so the
# editor's own writes carry the graphics, and the backend's second writer may land inside nvim's
# output. What that leaves in the recording decides what can still be checked (checks.py cuts).
case_3() {
  VK_RAN=$((VK_RAN + 1))
  local png="$WORK/plot_624.png" top writer
  vk_plot_png "$png" 624 528 || return 0
  vk_plot_flow plotf 0 "$png" || return 0
  top="$(cat "$WORK/top_plotf")"
  vk_quit plotf
  vk_interleave plotf || return 0
  echo "note plot_full: $VK_LINE"
  # The in-order writer is in use only when the tree has it and the Neovim this case runs has the
  # call it needs: on 0.11 image.lua falls back to the editor's stderr, which keeps the reduced
  # race, so the skip rule stays there and its reason is printed.
  writer="$(vk_writer_in_use)"
  if [ "$writer" = no-nvim ]; then
    echo "note plot_full: the tree has the in-order writer but this Neovim has no nvim_ui_send; the skip rule applies"
    writer=no
  fi
  # what the case fails and skips follows from the writer and the counts (checks.py case3)
  local rule f_fail f_grid f_tiles
  rule="$("$VKPY" -I -B "$VK/checks.py" case3 --writer "$writer" "$VK_CUTS" "$VK_SPLICES" "$VK_DROPS" "$VK_BODY" "$VK_WARNS")" \
    || { fail_later "vkitty plotf: checks.py case3 failed"; return 0; }
  read -r f_fail f_grid f_tiles <<EOF_RULE
$rule
EOF_RULE
  if [ "$f_fail" = "fail=yes" ]; then
    # one in-order writer: nothing may be interleaved, and every check runs
    fail_later "vkitty plotf: $VK_LINE with the in-order writer in the tree (nvim_ui_send); every count but warnings must be 0"
  fi
  if [ "$writer" = no ] && [ "$f_grid" = "grid=skip" ]; then
    # The second writer's bytes decide what the recording can prove. Foreign tokens that came out of
    # a passthrough body were drawn by the outer terminal outside tmux's grid, so the screen cannot
    # be compared. Cuts, splices, drops and warnings leave the emulator and tmux in agreement.
    echo "SKIP plot_full grid: $VK_BODY tokens other than APC came out of passthrough bodies, drawn by the outer terminal outside tmux's grid (the backend's second writer; the in-order writer is not in use)"
  fi
  if [ "$f_grid" = "grid=run" ]; then
    vk_grid plotf open
    vk_grid plotf scrolled
  fi
  if [ "$f_tiles" = "tiles=skip" ]; then
    # Splices alone never skip anything: under tmux they are harmless, and a run with only
    # splices has its grid and tiles checked in full.
    echo "SKIP plot_full tiles: the backend's second writer interleaved with nvim's output (cuts=$VK_CUTS tmux_drops=$VK_DROPS body_other=$VK_BODY warnings=$VK_WARNS; the in-order writer is not in use)"
    vk_stats plotf
    vk_artifact plotf open
    vk_artifact plotf scrolled
    return 0
  fi
  vk_tiles plotf open "$png" --expect-rows 0:15 --expect-cols 0:47
  vk_tiles plotf scrolled "$png" --expect-rows "$top:15" --expect-cols 0:47
  vk_negative_controls plotf "$png"
  vk_stats plotf
  vk_artifact plotf open
  vk_artifact plotf scrolled
}

# case_4 kernel_plot: a cell run on the kernel; the figure the kernel sends back is fitted in its box
case_4() {
  VK_RAN=$((VK_RAN + 1))
  vk_nb "$WORK/nb_kern.ipynb" kernel || return 0
  vk_launch kern "$WORK/nb_kern.ipynb" 1
  vk_wait_text "vkitty kernel" 20 \
    || { fail_later "vkitty kern: the notebook did not show its cell within 20 s"; return 0; }
  nv_sync || return 0
  # the kernel's start is announced in the message line, which may be redrawn before it is seen
  vk_wait_text "kernel 'python3' started" 30 || true
  k ":JupynvimRunCell" Enter
  if ! vk_wait_placeholders 60; then
    k ":JupynvimRunCell" Enter
    vk_wait_placeholders 60 \
      || { fail_later "vkitty kern: the kernel's figure never appeared (120 s, two runs)"; return 0; }
  fi
  nv_sync || return 0
  vk_snap kern ran || return 0
  vk_quit kern
  vk_grid kern ran
  vk_one_writer kern
  "$VKPY" -I "$VK/checks.py" fit "$WORK/rec_kern" ran || fail_later "vkitty kern ran: the figure is not fitted in its box"
  vk_artifact kern ran
}

# case_6 writer_rule: case 3 expects the in-order writer only when the tree has it and the Neovim
# that runs the case has nvim_ui_send. A stub nvim on PATH answers yes, no or nothing.
case_6() {
  VK_RAN=$((VK_RAN + 1))
  local bin="$WORK/stubbin" with="$WORK/image_with.lua" without="$WORK/image_without.lua"
  mkdir -p "$bin"
  printf '%s\n' 'if vim.api.nvim_ui_send then end' > "$with"
  printf '%s\n' 'local x = 1' > "$without"
  printf '%s\n' '#!/bin/sh' 'printf "%s" "$STUB_NVIM_OUT"' > "$bin/nvim"
  chmod +x "$bin/nvim"
  vk_writer_check yes "$with" yes
  vk_writer_check no "$with" no-nvim
  vk_writer_check "" "$with" no-nvim
  vk_writer_check "$(printf 'a warning\nyes')" "$with" yes
  vk_writer_check yes "$without" no
  vk_writer_check no "$without" no
}

# vk_writer_check NVIM_SAYS IMAGE EXPECTED: vk_writer_in_use with a stub nvim that prints NVIM_SAYS
vk_writer_check() {
  local says="$1" image="$2" want="$3" got
  got="$(PATH="$WORK/stubbin:$PATH" STUB_NVIM_OUT="$says" vk_writer_in_use "$image")"
  if [ "$got" = "$want" ]; then
    echo "ok writer rule: nvim says '$says', $(basename "$image") -> $got"
  else
    fail_later "vkitty writer rule: nvim says '$says' with $(basename "$image"): got '$got', expected '$want'"
  fi
}

# case_5 snap_cursor: a program that moves only its cursor, right after the relay acknowledges
# the first mark. The text never changes, so a snapshot helper that settles on the text alone
# accepts the first attempt, and the grid check then compares the later cursor (20,7) with the
# emulator's cursor at the mark (5,3). vk_snap also settles on the cursor, so it repeats the
# attempt and the second mark (cursor 20,7 on both sides) passes.
case_5() {
  VK_RAN=$((VK_RAN + 1))
  local out script="$WORK/launch_cur.sh" mover="$WORK/cursor_mover.py"
  cat > "$mover" <<'PY'
import os
import sys
import time

work = sys.argv[1]
os.write(1, b"\x1b[2J\x1b[Hcursor settle test\x1b[3;1Hrow three\x1b[4;6H")
deadline = time.monotonic() + 120
while time.monotonic() < deadline and not os.path.exists(work + "/ctl_cur.ack"):
    time.sleep(0.02)
time.sleep(0.05)
os.write(1, b"\x1b[8;21H")
open(work + "/cur_moved", "w").close()
while time.monotonic() < deadline and not os.path.exists(work + "/cur_quit"):
    time.sleep(0.05)
PY
  printf '%s\n' "cd $WORK && $VKPY -I $VK/relay.py --rec $WORK/rec_cur --ctl $WORK/ctl_cur --respond none -- $VKPY -I -B $mover $WORK" > "$script"
  stop_session
  tmux new-session -d -s "$S" -x 80 -y 24
  tmux send-keys -t "$S" "sh $script" Enter
  vk_wait_text "cursor settle test" 20 \
    || { tmux capture-pane -t "=$S:" -p >&2; fail_later "vkitty cur: the program did not show its text within 20 s"; return 0; }
  out="$(vk_snap cur settle)" || { echo "$out"; return 0; }
  echo "$out"
  case "$out" in
    *"(attempt 2)"*) ;;
    *) fail_later "vkitty cur: the cursor moved around the mark but the snapshot was not repeated ($out)" ;;
  esac
  _jnv_poll 10 test -e "$WORK/cur_moved" || fail_later "vkitty cur: the program never saw the first mark's acknowledgement"
  : > "$WORK/cur_quit"
  jnv_wait_file_eq "$WORK/rec_cur/done" done 30 \
    || fail_later "vkitty cur: the recording did not finish within 30 s of the program's end"
  stop_session
  vk_grid cur settle
}

run_cases "$@"
[ "$VK_RAN" -gt 0 ] || [ -n "${JNV_SHARD:-}" ] || fail_later "no case selected"
finish "vkitty screen"

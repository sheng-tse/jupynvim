#!/usr/bin/env bash
# ]c / [c while editing a cell, in a real nvim under tmux (#27).
#
# The bug lived in the CursorMoved handler that keeps the cursor inside the
# edited cell, and CursorMoved only fires from the real main loop, never
# inside a headless Lua chunk. So this drives actual keys and records where
# the cursor settled after the loop ran every handler.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/core/target/release/jupynvim-core"
[ -x "$BIN" ] || { echo "SKIP edit_nav_screen: build core first ($BIN)"; exit 0; }
command -v tmux >/dev/null || { echo "SKIP edit_nav_screen: no tmux"; exit 0; }

WORK="$(mktemp -d -t jupynvim_nav.XXXXXX)"
S="jupy_nav_$$"
cleanup() { tmux kill-session -t "$S" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

python3 - "$WORK/nav.ipynb" <<'PY'
import json, sys
cells = [{"cell_type": "code", "id": f"c{i}", "metadata": {}, "execution_count": None,
          "outputs": [], "source": "\n".join(f"cell{i}_line{j}" for j in range(1, 5))}
         for i in range(1, 10)]
# cell 5 carries an output, for clearing it from inside
cells[4]["execution_count"] = 1
cells[4]["outputs"] = [{"output_type": "stream", "name": "stdout",
                        "text": "".join(f"out5_{k}\n" for k in range(1, 9))}]
json.dump({"cells": cells, "nbformat": 4, "nbformat_minor": 5,
           "metadata": {"kernelspec": {"name": "python3", "display_name": "P", "language": "python"}}},
          open(sys.argv[1], "w"))
PY

cat > "$WORK/init.lua" <<LUA
vim.opt.runtimepath:prepend("$ROOT")
vim.o.swapfile = false
vim.o.cursorline = true
vim.g.mapleader = " "
require("jupynvim").setup({ core_path = "$BIN", auto_venv = false })
-- what the cursor is on and which mode cell mode is in, one line per call
function _G.__navrec()
  local CM = require("jupynvim.notebook.cellmode")
  local text = vim.api.nvim_get_current_line()
  local f = io.open("$WORK/rec", "a")
  f:write(text .. " " .. CM.mode(vim.api.nvim_get_current_buf()) .. "\n")
  f:close()
end
function _G.__navcount()
  local CM = require("jupynvim.notebook.cellmode")
  local f = io.open("$WORK/rec", "a")
  f:write("cells=" .. #CM.ranges(vim.api.nvim_get_current_buf()) .. "\n")
  f:close()
end
LUA

tmux kill-session -t "$S" 2>/dev/null
tmux new-session -d -s "$S" -x 140 -y 30
tmux set-option -t "$S" status off
tmux send-keys -t "$S" "cd $WORK && XDG_STATE_HOME=$WORK/state XDG_CACHE_HOME=$WORK/cache nvim -u $WORK/init.lua nav.ipynb" Enter

rendered=0
for _ in $(seq 1 20); do
  sleep 1
  if tmux capture-pane -t "$S" -p | grep -q "cell1_line1"; then rendered=1; break; fi
done
[ "$rendered" -eq 1 ] || { echo "FAIL: notebook never rendered"; exit 1; }
sleep 0.5

rec() { tmux send-keys -t "$S" ":lua __navrec()" Enter; sleep 0.4; }

tmux send-keys -t "$S" Enter; sleep 0.4        # edit cell 1
tmux send-keys -t "$S" "j" "j"; sleep 0.4      # somewhere inside it
tmux send-keys -t "$S" "]c"; sleep 0.5; rec
tmux send-keys -t "$S" "]c"; sleep 0.5; rec
tmux send-keys -t "$S" "[c"; sleep 0.5; rec
tmux send-keys -t "$S" "j"; sleep 0.4; rec
tmux send-keys -t "$S" Escape; sleep 0.4; rec

# a click on another cell's text while editing: that cell becomes the edited one
tmux send-keys -t "$S" Enter; sleep 0.4
pos=$(tmux capture-pane -t "$S" -p | python3 -c '
import sys
for row, l in enumerate(sys.stdin.read().splitlines()):
    c = l.find("cell4_line2")
    if c >= 0:
        print(row, c + 2); break')
if [ -n "$pos" ]; then
  set -- $pos
  tmux send-keys -t "$S" ":lua vim.api.nvim_input_mouse('left','press','',0,$1,$2); vim.api.nvim_input_mouse('left','release','',0,$1,$2)" Enter
  sleep 0.6
fi
rec

# scrolling while editing drags the cursor along, and a half-page scroll
# lands it several lines on, inside another cell. That is not a jump, so the
# edited cell stays put.
tmux send-keys -t "$S" C-d; sleep 0.5
tmux send-keys -t "$S" C-d; sleep 0.8; rec

# clearing an output from inside it rewrites the buffer under the cursor
tmux send-keys -t "$S" Escape; sleep 0.3
tmux send-keys -t "$S" "]c"; sleep 0.4
tmux send-keys -t "$S" Enter; sleep 0.4
tmux send-keys -t "$S" C-j; sleep 0.4
tmux send-keys -t "$S" " nc"; sleep 1.0; rec

# a visual selection is not a jump: ggVGd while editing cell 1 clears that
# cell and leaves the other eight alone
tmux send-keys -t "$S" Escape; sleep 0.3
tmux send-keys -t "$S" "gg"; sleep 0.3
tmux send-keys -t "$S" Enter; sleep 0.4
tmux send-keys -t "$S" "gg" "V" "G"; sleep 0.4
tmux send-keys -t "$S" "d"; sleep 0.6
tmux send-keys -t "$S" ":lua __navcount()" Enter; sleep 0.4

python3 - "$WORK/rec" <<'PY'
import re, sys
want = [
    ("]c from cell 1 while editing", "cell2_line1 edit"),
    ("a second ]c", "cell3_line1 edit"),
    ("[c", "cell2_line1 edit"),
    ("j stays in the cell [c reached", "cell2_line2 edit"),
    ("Esc selects that cell", "cell2_line2 command"),
    ("a click on another cell while editing edits that one", "cell4_line2 edit"),
    ("scrolling while editing keeps the edited cell", r"cell4_line\d edit"),
    ("<leader>nc from an output keeps editing that cell", "cell5_line4 edit"),
    ("ggVGd while editing a cell deletes only inside it", "cells=9"),
]
got = open(sys.argv[1]).read().splitlines()
fail = 0
for i, (label, exp) in enumerate(want):
    g = got[i] if i < len(got) else "<nothing recorded>"
    ok = re.fullmatch(exp, g) is not None
    fail += not ok
    print(f"{'ok' if ok else 'FAIL'} {label}: {g}" + ("" if ok else f"  (want {exp})"))
print(("\nEDIT-NAV SCREEN: %d FAILED" % fail) if fail else "\nEDIT-NAV SCREEN: ALL OK")
sys.exit(1 if fail else 0)
PY

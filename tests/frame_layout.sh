#!/usr/bin/env bash
# Frame-alignment regression test (real rendered screen, via tmux).
#
# Reproduces "the frame goes off after a layout change": the header/footer box
# corners must stay aligned with the source rows' │ edge across a terminal
# split and a floating window. Drives a real nvim in tmux and asserts the
# rendered columns line up. Requires: tmux + the local jupynvim-core binary.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/core/target/release/jupynvim-core"
[ -x "$BIN" ] || { echo "SKIP frame_layout: build core first ($BIN)"; exit 0; }
command -v tmux >/dev/null || { echo "SKIP frame_layout: no tmux"; exit 0; }

INIT="$ROOT/tests/.frame_init.lua"
cat > "$INIT" <<LUA
vim.opt.runtimepath:prepend("$ROOT")
vim.o.number = true
vim.o.termguicolors = true
vim.o.swapfile = false
vim.g.mapleader = " "
require("jupynvim").setup({ core_path = "$BIN", auto_venv = false })
LUA

S="jupy_frame_$$"
CAP() { tmux capture-pane -t "$S" -p; }
tmux kill-session -t "$S" 2>/dev/null
tmux new-session -d -s "$S" -x 160 -y 45
tmux set-option -t "$S" status off
tmux send-keys -t "$S" "cd $ROOT && nvim -u $INIT examples/demo.ipynb" Enter

# poll until the notebook actually renders (a box corner appears), up to ~20s
rendered=0
for _ in $(seq 1 20); do
  sleep 1
  if CAP | grep -q "╭"; then rendered=1; break; fi
done
if [ "$rendered" -ne 1 ]; then
  echo "FAIL: notebook never rendered (no box corner in 20s)"; CAP | head -5
  tmux kill-session -t "$S" 2>/dev/null; rm -f "$INIT"; exit 1
fi

# deterministically bring cell #8 (the for-loop) into view and center it
tmux send-keys -t "$S" Escape; sleep 0.3
tmux send-keys -t "$S" "gg"; sleep 0.3
tmux send-keys -t "$S" "/for i in range(5)" Enter; sleep 0.4
tmux send-keys -t "$S" "zz"; sleep 0.6
CAP > /tmp/fl_baseline.txt

# 1) terminal split, exit term-mode, back to the notebook, LEAVE the term open
tmux send-keys -t "$S" ":botright 10split | terminal" Enter; sleep 2
tmux send-keys -t "$S" C-\\ C-n; sleep 0.4
tmux send-keys -t "$S" C-w k; sleep 1.0
tmux send-keys -t "$S" "k" "j"; sleep 0.6
CAP > /tmp/fl_after_term.txt

# 2) floating window over the notebook, then close it
tmux send-keys -t "$S" ":lua _G.__fw=vim.api.nvim_open_win(vim.api.nvim_create_buf(false,true),true,{relative='editor',row=3,col=6,width=70,height=14,style='minimal',border='single'})" Enter
sleep 1
tmux send-keys -t "$S" ":lua vim.api.nvim_win_close(_G.__fw,true)" Enter; sleep 0.6
tmux send-keys -t "$S" "k" "j"; sleep 0.6
CAP > /tmp/fl_after_float.txt

tmux kill-session -t "$S" 2>/dev/null
rm -f "$INIT"

python3 - <<'PY'
import sys
def cols(path):
    lines = open(path, encoding="utf-8").read().splitlines()
    hdr = next((l for l in lines if "#8" in l and "╭" in l), None)
    src = next((l for l in lines if "for i in range" in l and "│" in l), None)
    if hdr is None or src is None:
        return None, None
    return hdr.index("╭"), src.index("│")

fail = 0
for name, path in [("baseline","/tmp/fl_baseline.txt"),
                   ("after-terminal","/tmp/fl_after_term.txt"),
                   ("after-float","/tmp/fl_after_float.txt")]:
    hc, sc = cols(path)
    if hc is None:
        print(f"FAIL {name}: #8 header or source line not found"); fail += 1; continue
    ok = (hc == sc)
    print(f"{'ok' if ok else 'FAIL'} {name}: header ╭ col={hc}  source │ col={sc}")
    if not ok: fail += 1

print(("\nFRAME-LAYOUT: %d FAILED" % fail) if fail else "\nFRAME-LAYOUT: ALL ALIGNED")
sys.exit(1 if fail else 0)
PY

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

# The init file and the screen captures live in a directory of this run's
# own, so two runs cannot overwrite each other's captures. nvim's state dir is
# isolated too, where a cursor saved by an earlier run could move the view
# this test measures. The cache dir is not; see the launch line below.
WORK="$(mktemp -d -t jupynvim_frame.XXXXXX)"
INIT="$WORK/init.lua"

# The notebook is generated rather than read from examples/, which is not in
# the repository, so the test runs on a fresh clone. Markdown, a plot, text
# outputs, and cell #8 holding the for-loop the checks look for.
python3 - "$WORK/frame.ipynb" <<'PY'
import base64, json, struct, sys, zlib
def png(w, h):
    rows = b"".join(b"\0" + b"".join(bytes((x * 7 % 256, y * 5 % 256, (x + y) % 256))
                                     for x in range(w)) for y in range(h))
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))
def md(i, s): return {"cell_type": "markdown", "id": f"c{i}", "metadata": {}, "source": s}
def code(i, s, outputs=()):
    return {"cell_type": "code", "id": f"c{i}", "metadata": {}, "source": s,
            "execution_count": 1 if outputs else None, "outputs": list(outputs)}
def stream(t): return {"output_type": "stream", "name": "stdout", "text": t}
cells = [
    md(1, "# frame layout\n\nA notebook with the usual mix of cells."),
    code(2, "import math\nprint(math.pi)", [stream("3.141592653589793\n")]),
    md(3, "## a plot"),
    code(4, "plot()", [{"output_type": "display_data", "metadata": {},
                         "data": {"image/png": base64.b64encode(png(160, 120)).decode(),
                                  "text/plain": "<Figure>"}}]),
    code(5, "x = 1"),
    code(6, "x + 1", [{"output_type": "execute_result", "execution_count": 1,
                        "metadata": {}, "data": {"text/plain": "2"}}]),
    md(7, "## plain-text output"),
    code(8, "for i in range(5):\n    print(f'iteration {i}: {2 ** i}')",
         [stream("".join(f"iteration {i}: {2 ** i}\n" for i in range(5)))]),
    code(9, "y = 2"),
]
json.dump({"cells": cells, "nbformat": 4, "nbformat_minor": 5,
           "metadata": {"kernelspec": {"name": "python3", "display_name": "P", "language": "python"}}},
          open(sys.argv[1], "w"))
PY
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
cleanup() { tmux kill-session -t "$S" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
# Only the state dir is isolated: that is where a saved cursor could move the
# view. The cache is left alone, because the :terminal below inherits it and
# a user's shell setup rebuilt from an empty cache on every run.
tmux send-keys -t "$S" "cd $ROOT && XDG_STATE_HOME=$WORK/state nvim -u $INIT $WORK/frame.ipynb" Enter

# poll until the notebook actually renders (a box corner appears), up to ~20s
rendered=0
for _ in $(seq 1 20); do
  sleep 1
  if CAP | grep -q "╭"; then rendered=1; break; fi
done
if [ "$rendered" -ne 1 ]; then
  echo "FAIL: notebook never rendered (no box corner in 20s)"; CAP | head -5
  exit 1
fi

# deterministically bring cell #8 (the for-loop) into view and center it
tmux send-keys -t "$S" Escape; sleep 0.3
tmux send-keys -t "$S" "gg"; sleep 0.3
tmux send-keys -t "$S" "/for i in range(5)" Enter; sleep 0.4
tmux send-keys -t "$S" "zz"; sleep 0.6
CAP > "$WORK/fl_baseline.txt"

# 1) terminal split, exit term-mode, back to the notebook, LEAVE the term open
tmux send-keys -t "$S" ":botright 10split | terminal" Enter; sleep 2
tmux send-keys -t "$S" C-\\ C-n; sleep 0.4
tmux send-keys -t "$S" C-w k; sleep 1.0
tmux send-keys -t "$S" "k" "j"; sleep 0.6
CAP > "$WORK/fl_after_term.txt"

# 2) floating window over the notebook, then close it
tmux send-keys -t "$S" ":lua _G.__fw=vim.api.nvim_open_win(vim.api.nvim_create_buf(false,true),true,{relative='editor',row=3,col=6,width=70,height=14,style='minimal',border='single'})" Enter
sleep 1
tmux send-keys -t "$S" ":lua vim.api.nvim_win_close(_G.__fw,true)" Enter; sleep 0.6
tmux send-keys -t "$S" "k" "j"; sleep 0.6
CAP > "$WORK/fl_after_float.txt"

tmux kill-session -t "$S" 2>/dev/null

WORK="$WORK" python3 - <<'PY'
import os, sys
W = os.environ["WORK"]
def cols(path):
    lines = open(path, encoding="utf-8").read().splitlines()
    hdr = next((l for l in lines if "#8" in l and "╭" in l), None)
    src = next((l for l in lines if "for i in range" in l and "│" in l), None)
    if hdr is None or src is None:
        return None, None
    return hdr.index("╭"), src.index("│")

fail = 0
for name, path in [("baseline", f"{W}/fl_baseline.txt"),
                   ("after-terminal", f"{W}/fl_after_term.txt"),
                   ("after-float", f"{W}/fl_after_float.txt")]:
    hc, sc = cols(path)
    if hc is None:
        print(f"FAIL {name}: #8 header or source line not found"); fail += 1; continue
    ok = (hc == sc)
    print(f"{'ok' if ok else 'FAIL'} {name}: header ╭ col={hc}  source │ col={sc}")
    if not ok: fail += 1

print(("\nFRAME-LAYOUT: %d FAILED" % fail) if fail else "\nFRAME-LAYOUT: ALL ALIGNED")
sys.exit(1 if fail else 0)
PY

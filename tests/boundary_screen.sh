#!/usr/bin/env bash
# Cell boundaries survive ordinary editing, in a real nvim under tmux.
#
# Separators are real buffer lines, and sync_from_buffer pairs cells with the
# text between them by position. One Backspace at the start of a cell glued
# its first line onto the separator, and the next :w saved that cell's code
# under its neighbour's id and dropped a cell. This drives the edits that
# break a boundary with real keys and reads back what :w wrote.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/core/target/release/jupynvim-core"
[ -x "$BIN" ] || { echo "SKIP boundary_screen: build core first ($BIN)"; exit 0; }
command -v tmux >/dev/null || { echo "SKIP boundary_screen: no tmux"; exit 0; }

WORK="$(mktemp -d -t jupynvim_bound.XXXXXX)"
S="jupy_bound_$$"
cleanup() { tmux kill-session -t "$S" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

python3 - "$WORK/nb.ipynb" <<'PY'
import json, sys
cells = [{"cell_type": "code", "id": f"c{i}", "metadata": {}, "execution_count": None,
          "outputs": [], "source": f"a{i} = {i}\nb{i} = {i}"} for i in range(1, 4)]
cells[0]["execution_count"] = 1
cells[0]["outputs"] = [{"output_type": "stream", "name": "stdout", "text": "OUT1\n"}]
json.dump({"cells": cells, "nbformat": 4, "nbformat_minor": 5,
           "metadata": {"kernelspec": {"name": "python3", "display_name": "P", "language": "python"}}},
          open(sys.argv[1], "w"))
PY

cat > "$WORK/init.lua" <<LUA
vim.opt.runtimepath:prepend("$ROOT")
vim.o.swapfile = false
require("jupynvim").setup({ core_path = "$BIN", auto_venv = false })
LUA

tmux kill-session -t "$S" 2>/dev/null
tmux new-session -d -s "$S" -x 120 -y 40
tmux set-option -t "$S" status off
tmux send-keys -t "$S" "cd $WORK && XDG_STATE_HOME=$WORK/state nvim -u $WORK/init.lua nb.ipynb" Enter
rendered=0
for _ in $(seq 1 20); do
  sleep 1
  if tmux capture-pane -t "$S" -p | grep -q "a1 = 1"; then rendered=1; break; fi
done
[ "$rendered" -eq 1 ] || { echo "FAIL: notebook never rendered"; exit 1; }
sleep 0.5
k() { tmux send-keys -t "$S" "$@"; sleep 0.4; }

# Backspace at the start of cell 2
k j; k Enter; k g g; k 0; k i; k BSpace; k Escape
# J on cell 1's last line, which would pull its output separator up
k Escape; k g g; k Enter; k G; k J; k Escape
# dj on cell 2's last line takes the separator below with it
k Escape; k j; k Enter; k G; k d j
# dG from inside cell 1 would take every cell after it
k Escape; k g g; k Enter; k d G
# u after all that must not loop or reach past a boundary
k u; k u
# and ordinary typing still lands
k Escape; k G; k Enter; k G; k A; tmux send-keys -t "$S" "  # kept" ; sleep 0.3; k Escape
k Escape
tmux send-keys -t "$S" ":w" Enter; sleep 2

python3 - "$WORK/nb.ipynb" <<'PY'
import json, sys
nb = json.load(open(sys.argv[1]))
got = [(c["id"], "".join(c["source"]), len(c.get("outputs", []))) for c in nb["cells"]]
want = [("c1", "a1 = 1\nb1 = 1", 1), ("c2", "a2 = 2\nb2 = 2", 0),
        ("c3", "a3 = 3\nb3 = 3  # kept", 0)]
fail = 0
for i, w in enumerate(want):
    g = got[i] if i < len(got) else None
    ok = g == w
    fail += not ok
    print(f"{'ok' if ok else 'FAIL'} cell {i + 1} saved intact: {g!r}" + ("" if ok else f"  (want {w!r})"))
if len(got) != len(want):
    fail += 1
    print(f"FAIL saved {len(got)} cells, want {len(want)}")
print(("\nBOUNDARY SCREEN: %d FAILED" % fail) if fail else "\nBOUNDARY SCREEN: ALL OK")
sys.exit(1 if fail else 0)
PY

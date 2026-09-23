#!/usr/bin/env bash
# Cell boundaries survive ordinary editing, in a real nvim under tmux.
#
# Separators are real buffer lines, and sync_from_buffer pairs cells with the
# text between them by position. One Backspace at the start of a cell glued
# its first line onto the separator, and the next :w saved that cell's code
# under its neighbor's id and dropped a cell. Each case below drives real
# keys on a fresh notebook and reads back what :w wrote.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/core/target/release/jupynvim-core"
[ -x "$BIN" ] || { echo "SKIP boundary_screen: build core first ($BIN)"; exit 0; }
command -v tmux >/dev/null || { echo "SKIP boundary_screen: no tmux"; exit 0; }

WORK="$(mktemp -d -t jupynvim_bound.XXXXXX)"
S="jupy_bound_$$"
cleanup() { tmux kill-session -t "$S" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
FAILS=0

cat > "$WORK/init.lua" <<LUA
vim.opt.runtimepath:prepend("$ROOT")
vim.o.swapfile = false
require("jupynvim").setup({ core_path = "$BIN", auto_venv = false })
function _G.__rec(s)
  local f = io.open("$WORK/rec", "a"); f:write(s .. "\n"); f:close()
end
LUA

# Five cells: 1 has an output, 4 prints, 5 holds separator TEXT inside a line
# of code and of its output, which is not a boundary and must stay as it is.
make_nb() {
  python3 - "$WORK/nb.ipynb" ${1:-} <<'PY'
import json, sys
def code(i, src, outputs=()):
    return {"cell_type": "code", "id": f"c{i}", "metadata": {}, "source": src,
            "execution_count": 1 if outputs else None, "outputs": list(outputs)}
def stream(t): return {"output_type": "stream", "name": "stdout", "text": t}
cells = [code(1, "a1 = 1\nb1 = 1", [stream("OUT1\n")]),
         code(2, "a2 = 2\nb2 = 2"),
         code(3, "a3 = 3\nb3 = 3"),
         code(4, "print('hi4')"),
         code(5, 'x = "# %%[jupynvim:cell-sep]"', [stream("# %%[jupynvim:out] printed\n")])]
if len(sys.argv) > 2:   # "plain": no separator text anywhere
    cells = cells[:4]
json.dump({"cells": cells, "nbformat": 4, "nbformat_minor": 5,
           "metadata": {"kernelspec": {"name": "python3", "display_name": "P", "language": "python"}}},
          open(sys.argv[1], "w"))
PY
}

start() {
  make_nb "${1:-}"
  rm -f "$WORK/rec"
  tmux kill-session -t "$S" 2>/dev/null
  tmux new-session -d -s "$S" -x 120 -y 50
  tmux set-option -t "$S" status off
  tmux send-keys -t "$S" "cd $WORK && XDG_STATE_HOME=$WORK/state nvim -u $WORK/init.lua nb.ipynb" Enter
  for _ in $(seq 1 20); do
    sleep 1
    tmux capture-pane -t "$S" -p | grep -q "a1 = 1" && break
  done
  sleep 0.5
}
k() { tmux send-keys -t "$S" "$@"; sleep 0.4; }
type_text() { tmux send-keys -t "$S" -l "$1"; sleep 0.4; }
save() { k Escape; k Escape; k ":w" Enter; sleep 1.5; }

# check CASE 'python expression over cells' where cells maps id -> (source, n_outputs)
check() {
  local name="$1" expect="$2"
  python3 - "$WORK/nb.ipynb" "$name" "$expect" <<'PY'
import json, sys
nb = json.load(open(sys.argv[1]))
cells = {c["id"]: ("".join(c["source"]), len(c.get("outputs", []))) for c in nb["cells"]}
order = [c["id"] for c in nb["cells"]]
base = {"c1": ("a1 = 1\nb1 = 1", 1), "c2": ("a2 = 2\nb2 = 2", 0), "c3": ("a3 = 3\nb3 = 3", 0),
        "c4": ("print('hi4')", 0), "c5": ('x = "# %%[jupynvim:cell-sep]"', 1)}
ok = eval(sys.argv[3], {"cells": cells, "order": order, "base": base})
print(f"{'ok' if ok else 'FAIL'} {sys.argv[2]}" + ("" if ok else f"\n     saved: {cells} order {order}"))
sys.exit(0 if ok else 1)
PY
  [ $? -eq 0 ] || FAILS=$((FAILS + 1))
}
INTACT='order == ["c1","c2","c3","c4","c5"] and all(cells[i] == base[i] for i in ["c2","c5"])'

# 1. the edits that break a boundary: <BS> at a cell's start, J into an
#    output, dj over a separator, dG from the top, then u
start
k j; k Enter; k g g; k 0; k i; k BSpace; k Escape
k Escape; k g g; k Enter; k G; k J; k Escape
k Escape; k j; k Enter; k G; k d j
k Escape; k g g; k Enter; k d G
k u; k u
save
check "Backspace, J, dj, dG and u leave every cell intact" "$INTACT and cells['c1'] == base['c1'] and cells['c3'] == base['c3']"

# 2. repairing a join moves nothing else: a mark in cell 3 stays on its line
start
k j; k j; k Enter; k g g; k m a; k Escape
k k; k Enter; k g g; k 0; k i; k BSpace; k Escape
k ":lua __rec(vim.fn.getline(vim.fn.line(\"'a\")))" Enter
save
if [ "$(head -1 "$WORK/rec" 2>/dev/null)" = "a3 = 3" ]; then
  echo "ok a mark in another cell survives the repair of a join"
else
  echo "FAIL a mark in another cell survives the repair of a join: mark is on '$(head -1 "$WORK/rec" 2>/dev/null)'"
  FAILS=$((FAILS + 1))
fi

# 3. <Del> at a cell's end does nothing, and what is typed next lands at the end
start
k Enter; k G; k A; k Delete; type_text "Z"; k Escape
save
check "<Del> at a cell's end then typing appends to that line" "$INTACT and cells['c1'] == ('a1 = 1\nb1 = 1Z', 1)"

# 4. a counted J that runs through a separator is taken back whole
start
k j; k Enter; k g g; k 3 J
save
check "3J across a separator leaves the cells as they were" "$INTACT and cells['c1'] == base['c1'] and cells['c3'] == base['c3']"

# 5. u after a run undoes the user's edit, not the output the run wrote
start
k j; k j; k Enter; k G; k A; type_text "  # e3"; k Escape; k Escape
# the run's output line, not the source line print('hi4')
ran() { tmux capture-pane -t "$S" -p | grep -cE "(^|[^'])hi4([^']|$)"; }
k j; k ":JupynvimRunCell" Enter
for _ in $(seq 1 40); do
  sleep 1
  [ "$(ran)" -ge 1 ] && break
done
if [ "$(ran)" -lt 1 ]; then echo "FAIL the kernel never ran cell 4"; FAILS=$((FAILS + 1)); fi
sleep 0.6
k k; k Enter; k u; k Escape
k Enter; k A; type_text "  # after"; k Escape
sleep 0.6
shows=$(ran)
save
check "u after running another cell undoes the edit" "$INTACT and cells['c3'] == ('a3 = 3\nb3 = 3  # after', 0) and cells['c4'][1] >= 1"
if [ "$shows" -ge 1 ]; then
  echo "ok the run's output is back on screen after the next edit"
else
  echo "FAIL the run's output is back on screen after the next edit"
  FAILS=$((FAILS + 1))
fi

# 6. g- after a boundary break was taken back, then ordinary edits still land
start
k j; k Enter; k G; k d j
k Escape; k j; k Enter; k A; type_text "  # one"; k Escape
k g -; k g -; k g +; k g +
k A; type_text "  # kept"; k Escape
save
check "g- and g+ after a taken-back delete, and later edits still save" "$INTACT and cells['c1'] == base['c1'] and cells['c3'][0] == 'a3 = 3  # one  # kept\nb3 = 3'"

# 7. u inside a cell right after moving a cell must not pair text with the
#    wrong cells: vim's undo would put the sources back but not the cells
start plain
k j; k ":lua require('jupynvim').move_cell(0, 1)" Enter; sleep 1
k Enter; k u; k Escape
save
check "u inside a cell after a move keeps each source with its cell" \
  "order == ['c1','c3','c2','c4'] and all(cells[i] == base[i] for i in ['c1','c2','c3','c4'])"

echo
if [ "$FAILS" -eq 0 ]; then echo "BOUNDARY SCREEN: ALL OK"; else echo "BOUNDARY SCREEN: $FAILS FAILED"; fi
exit $((FAILS > 0))

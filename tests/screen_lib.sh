# Shared by the tmux screen tests that edit a notebook with real keys and
# read back what :w wrote. Source it; it sets WORK, S, FAILS and the helpers.
#
# A case: start [variant]; keys with k / type_text; save; check "name" 'expr'.
# `expr` is Python over cells, which maps an id to (source, n_outputs),
# order, the ids in order, and base, the cells as make_nb wrote them.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/core/target/release/jupynvim-core"
[ -x "$BIN" ] || { echo "SKIP $(basename "$0"): build core first ($BIN)"; exit 0; }
command -v tmux >/dev/null || { echo "SKIP $(basename "$0"): no tmux"; exit 0; }

WORK="$(mktemp -d -t jupynvim_screen.XXXXXX)"
S="jupy_screen_$$"
cleanup() { tmux kill-session -t "$S" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
FAILS=0

cat > "$WORK/init.lua" <<LUA
vim.opt.runtimepath:prepend("$ROOT")
vim.o.swapfile = false
require("jupynvim").setup({ core_path = "$BIN", auto_venv = false })
-- tmux cannot send <C-CR>; <F5> reaches the notebook's own insert-mode map
vim.keymap.set("i", "<F5>", "<C-CR>", { remap = true })
-- LazyVim's line moves
vim.keymap.set("n", "<A-j>", "<cmd>execute 'move .+' . v:count1<cr>==")
vim.keymap.set("n", "<A-k>", "<cmd>execute 'move .-' . (v:count1 + 1)<cr>==")
function _G.__rec(s)
  local f = io.open("$WORK/rec", "a"); f:write(tostring(s) .. "\n"); f:close()
end
LUA

# Five code cells: 1 has an output, 4 prints, 5 holds separator TEXT inside a
# line of code and of its output, which is not a boundary and must stay.
# Variants: plain has no cell 5, stream is plain with cell 4 printing for
# 4s, md is plain with cell 3 markdown, image has a markdown cell with a png.
make_nb() {
  python3 - "$WORK/nb.ipynb" "${1:-}" <<'PY'
import json, sys, base64, struct, zlib
mode = sys.argv[2]
def code(i, src, outputs=()):
    return {"cell_type": "code", "id": f"c{i}", "metadata": {}, "source": src,
            "execution_count": 1 if outputs else None, "outputs": list(outputs)}
def stream(t): return {"output_type": "stream", "name": "stdout", "text": t}
cells = [code(1, "a1 = 1\nb1 = 1", [stream("OUT1\n")]),
         code(2, "a2 = 2\nb2 = 2"),
         code(3, "a3 = 3\nb3 = 3"),
         code(4, "print('hi4')"),
         code(5, 'x = "# %%[jupynvim:cell-sep]"', [stream("# %%[jupynvim:out] printed\n")])]
if mode:
    cells = cells[:4]
if mode == "stream":
    cells[3] = code(4, "import time\nfor i in range(10):\n    print('tick', i, flush=True); time.sleep(0.4)")
if mode == "md":
    cells[2] = {"cell_type": "markdown", "id": "c3", "metadata": {}, "source": "a3 = 3\nb3 = 3"}
if mode == "image":
    def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))
    png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 4, 4, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(b"".join(b"\x00" + b"\xff\x00\x00" * 4 for _ in range(4))))
           + chunk(b"IEND", b""))
    uri = "data:image/png;base64," + base64.b64encode(png).decode()
    cells[2] = {"cell_type": "markdown", "id": "c3", "metadata": {},
                "source": "# pic\n![p](" + uri + ")\nend"}
json.dump({"cells": cells, "nbformat": 4, "nbformat_minor": 5,
           "metadata": {"kernelspec": {"name": "python3", "display_name": "P", "language": "python"}}},
          open(sys.argv[1], "w"))
PY
}

# nvim on nb.ipynb as it is on disk, with the undo history an earlier :w left
launch() {
  rm -f "$WORK/rec"
  tmux kill-session -t "$S" 2>/dev/null
  tmux new-session -d -s "$S" -x 200 -y 50
  tmux set-option -t "$S" status off
  tmux send-keys -t "$S" "cd $WORK && XDG_STATE_HOME=$WORK/state nvim -u $WORK/init.lua nb.ipynb" Enter
  for _ in $(seq 1 20); do
    sleep 1
    tmux capture-pane -t "$S" -p | grep -q "a1 = 1" && break
  done
  sleep 0.5
}
# a fresh notebook with no undo history
start() { make_nb "${1:-}"; rm -rf "$WORK/state"; launch; }
# quit without saving and open it again
reopen() { k Escape; k Escape; k ":qa!" Enter; sleep 1.5; launch; }

k() { tmux send-keys -t "$S" "$@"; sleep 0.4; }
type_text() { tmux send-keys -t "$S" -l "$1"; sleep 0.4; }
save() { k Escape; k Escape; k ":w" Enter; sleep 1.5; }
screen() { tmux capture-pane -t "$S" -p; }

# lines of output a run of cell 4 printed, hi4 outside quotes or a tick
ran() { screen | grep -cE "(^|[^'])hi4([^']|$)|tick [0-9]"; }
# run the cell under the cursor and wait for its first output
run_wait() {
  k ":JupynvimRunCell" Enter
  for _ in $(seq 1 40); do
    sleep 0.5
    [ "$(ran)" -ge 1 ] && break
  done
  if [ "$(ran)" -lt 1 ]; then echo "FAIL the kernel never ran the cell"; FAILS=$((FAILS + 1)); fi
  sleep 0.6
}
# the undo warning, or the text given, is in :messages
warned() { warned_about "stops at the last cell change"; }
warned_about() {
  k ":lua __rec(vim.fn.execute('messages'))" Enter
  grep -q "$1" "$WORK/rec" 2>/dev/null
}

# check NAME EXPR, over what :w wrote
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
# holds NAME COND: a shell condition that must hold
holds() {
  if eval "$2"; then echo "ok $1"; else echo "FAIL $1"; FAILS=$((FAILS + 1)); fi
}

INTACT='order == ["c1","c2","c3","c4","c5"] and all(cells[i] == base[i] for i in ["c2","c5"])'
PLAIN="order == ['c1','c2','c3','c4'] and all(cells[i] == base[i] for i in ['c1','c2','c3','c4'])"

# run the cases named on the command line, or all of them
run_cases() {
  local want=("$@") c
  for c in $(declare -F | awk '{print $3}' | grep '^case_' | sort -t_ -k2 -n); do
    if [ ${#want[@]} -eq 0 ] || [[ " ${want[*]} " == *" ${c#case_} "* ]]; then "$c"; fi
  done
}
finish() {
  echo
  if [ "$FAILS" -eq 0 ]; then echo "$1: ALL OK"; else echo "$1: $FAILS FAILED"; fi
  exit $((FAILS > 0))
}

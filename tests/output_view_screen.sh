#!/usr/bin/env bash
# <leader>no, <leader>nO and <leader>nl with real keys in a real nvim under
# tmux, #37.
# What each says where it has nothing to do, the line a hidden output leaves,
# :q after either, and u after a restart when the save had an output
# expanded or hidden.
#
# Two of these need the real main loop. TextChanged compares the buffer with
# the file, and used to mark a notebook modified when only its view changed.
# After a restart, vim reads the undo file back only onto the text it was
# written from.
#
#   bash tests/output_view_screen.sh [case numbers...]
set -u
source "$(dirname "$0")/screen_lib.sh"

cat > "$WORK/init.lua" <<LUA
vim.opt.runtimepath:prepend("$ROOT")
vim.o.swapfile = false
vim.g.mapleader = " "
require("jupynvim").setup({ core_path = "$BIN", auto_venv = false })
function _G.__rec(s)
  local f = io.open("$WORK/rec", "a"); f:write(tostring(s) .. "\n"); f:close()
end
function _G.__sync(n) local f = io.open("$WORK/sync.tmp", "w"); f:write(tostring(n)); f:close(); os.rename("$WORK/sync.tmp", "$WORK/sync") end
LUA

# The report's plot, a 1000-line print, and a cell to edit.
make_views() {
  python3 - "$WORK/nb.ipynb" <<'PY'
import json, sys, base64, struct, zlib
def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))
png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 4, 4, 8, 2, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(b"".join(b"\x00" + b"\xff\x00\x00" * 4 for _ in range(4))))
       + chunk(b"IEND", b""))
def code(i, src, outputs=()):
    return {"cell_type": "code", "id": i, "metadata": {}, "source": src,
            "execution_count": 1 if outputs else None, "outputs": list(outputs)}
cells = [code("plot", "plot_it()", [{"output_type": "display_data", "metadata": {},
             "data": {"image/png": base64.b64encode(png).decode(),
                      "text/plain": "<Figure size 640x480 with 1 Axes>"}}]),
         code("long", "print_long()", [{"output_type": "stream", "name": "stdout",
             "text": "".join(f"long line {i}\n" for i in range(1, 1001))}]),
         code("edit", "a3 = 3")]
json.dump({"cells": cells, "nbformat": 4, "nbformat_minor": 5,
           "metadata": {"kernelspec": {"name": "python3", "display_name": "P", "language": "python"}}},
          open(sys.argv[1], "w"))
PY
}

launch_views() {
  rm -f "$WORK/rec"
  stop_session
  tmux new-session -d -s "$S" -x 200 -y 50
  tmux set-option -t "$S" status off
  tmux send-keys -t "$S" "cd $WORK && XDG_STATE_HOME=$WORK/state nvim -u $WORK/init.lua nb.ipynb" Enter
  for _ in $(seq 1 20); do
    sleep 1
    screen | grep -q "plot_it()" && break
  done
  sleep 0.5
}
start_views() { stop_session; make_views; rm -rf "$WORK/state"; launch_views; }

rec() { rm -f "$WORK/rec"; k ":lua __rec($1)" Enter; nv_sync; cat "$WORK/rec" 2>/dev/null; }
modified() { rec "vim.bo.modified"; }
# Press keys with the message history cleared first, then ask whether they
# said a line. The kernel starts on open and its message can come after.
press() { k ":messages clear" Enter; k "$@"; }
said() { rec "vim.fn.execute('messages')" | grep -qxF "$1"; }
# the source of a cell as :w wrote it
saved_src() {
  python3 - "$WORK/nb.ipynb" "$1" <<'PY'
import json, sys
nb = json.load(open(sys.argv[1]))
print("".join(next(c["source"] for c in nb["cells"] if c["id"] == sys.argv[2])))
PY
}

# Where nothing is cut or there is no output, each key says so and leaves
# the notebook as it was. Hiding leaves one line with the key to show it.
case_1() {
  start_views
  press Space n o
  holds "<leader>no on a plot says there is nothing to expand" 'said "jupynvim: nothing to expand"'
  press Space n O
  holds "<leader>nO hides the plot" 'said "jupynvim: output hidden"'
  holds "one line says what is hidden, with the key to show it" \
    'screen | grep -q "⋯ output hidden (1 image)  <leader>nO to show"'
  holds "hiding leaves the notebook unmodified" '[ "$(modified)" = "false" ]'
  press Space n o
  holds "<leader>no on a hidden output points at <leader>nO" \
    'said "jupynvim: output is hidden, <leader>nO shows it"'
  press Space n O
  holds "<leader>nO shows it again" 'said "jupynvim: output shown" && ! screen | grep -q "output hidden"'
  k j
  press Space n o
  holds "<leader>no expands the long print" 'said "jupynvim: output expanded"'
  holds "all of it is in the buffer" '[ "$(rec "vim.api.nvim_buf_line_count(0)")" -ge 1000 ]'
  holds "expanding leaves the notebook unmodified" '[ "$(modified)" = "false" ]'
  press Space n o
  holds "<leader>no cuts it again" 'said "jupynvim: output collapsed"'
  k j
  press Space n O
  holds "<leader>nO with no output says there is nothing to hide" 'said "jupynvim: nothing to hide"'
  k ":q" Enter
  jnv_wait_nvim_exit 10 || true
  holds ":q after all of it quits, with nothing to save" '! screen | grep -q "E37" && ! tmux capture-pane -t "$S" -p | grep -q "plot_it()"'
}

# Saved with the long print expanded, a restart and u still take back the
# edit made before the save. Opened cut, the buffer no longer matched the
# undo file and vim dropped the history.
case_2() {
  start_views
  k G; k Enter; k A; type_text "  # edited"; k Escape; k Escape
  k k
  press Space n o
  save
  k ":qa!" Enter
  jnv_wait_nvim_exit 15 || { echo "FAIL nvim did not quit within 15s of :qa!"; FAILS=$((FAILS + 1)); }
  launch_views
  holds "reopened, the long print is still expanded" '[ "$(rec "vim.api.nvim_buf_line_count(0)")" -ge 1000 ]'
  k G; k Enter; k u; k Escape; k Escape
  save
  holds "u after a restart takes back the edit saved with an output expanded" '[ "$(saved_src edit)" = "a3 = 3" ]'
}

# The same with the plot hidden, which also comes back hidden.
case_3() {
  start_views
  k G; k Enter; k A; type_text "  # edited"; k Escape; k Escape
  k g g
  press Space n O
  save
  k ":qa!" Enter
  jnv_wait_nvim_exit 15 || { echo "FAIL nvim did not quit within 15s of :qa!"; FAILS=$((FAILS + 1)); }
  launch_views
  holds "reopened, the plot is still hidden" 'screen | grep -q "⋯ output hidden (1 image)"'
  k G; k Enter; k u; k Escape; k Escape
  save
  holds "u after a restart takes back the edit saved with an output hidden" '[ "$(saved_src edit)" = "a3 = 3" ]'
}

# <leader>nl asks how many lines, and the answer typed at the prompt cuts the
# output to its first lines and its last 5.
case_4() {
  start_views
  k j
  press Space n l
  holds "<leader>nl asks how many lines" 'screen | grep -q "Show how many lines (now 500)?"'
  type_text "100"; k Enter
  holds "the answer cuts the output to its first 100 lines" 'said "jupynvim: output cut to its first 100 lines"'
  holds "the notebook stays unmodified" '[ "$(modified)" = "false" ]'
  k "/895 lines hidden" Enter
  holds "line 100, then the marker with its key" \
    'screen | grep -A1 "long line 100$" | grep -q "⋯ 895 lines hidden (1000 total)  <leader>no to expand"'
  holds "then the last 5 lines" 'screen | grep -A1 "895 lines hidden" | grep -q "long line 996$"'
  press Space n o
  holds "<leader>no then shows every line" \
    'said "jupynvim: output expanded" && [ "$(rec "vim.api.nvim_buf_line_count(0)")" -ge 1000 ]'
  press Space n o
  holds "and cuts back to 100" \
    'said "jupynvim: output collapsed" && [ "$(rec "vim.api.nvim_buf_line_count(0)")" -lt 200 ]'
}

run_cases "$@"
finish "output-view screen"

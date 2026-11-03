#!/usr/bin/env bash
# The widget protocol on the real screen, in a real nvim under tmux. The rows are
# read from the pane, as a user sees them.
#   scr   tqdm.notebook runs live: while it runs the pane shows at least three
#         distinct 'screen: N%' values with 0 < N < 100, then the line
#         'screen: 100%' with 25 full blocks and 30/30.
#   color that line's bar is drawn in the palette's ok token (set in init.lua to a
#         green no highlight group has, so the bar shows it only when it takes
#         the token), and in JupynvimWidgetBarSuccess: the foreground nvim has
#         for the group is the one tmux keeps for those cells.
#   ow    an Output widget's text shows in its cell, and the widget's own repr
#         ('Output()') does not show as a row.
#   save  :w writes the widget state to metadata.widgets; a relaunch with nothing
#         run shows the same 100% line from the saved state within 20 s, and the
#         relaunched notebook's kernel starts with that line still on screen.
# The relaunch needs the file that the first case saved, so run both cases
# together (the default).
#
#   bash tests/widget_screen.sh [case numbers...]
set -u
source "$(dirname "$0")/screen_lib.sh"

# The palette's ok token for this test: no group of the default colorscheme has it.
OK_HEX=7ee787
cat > "$WORK/init.lua" <<LUA
vim.opt.runtimepath:prepend("$ROOT")
vim.o.swapfile = false
vim.o.termguicolors = true
require("jupynvim").setup({ core_path = "$BIN", auto_venv = false, palette = { ok = "#$OK_HEX" } })
function _G.__rec(s)
  local f = io.open("$WORK/rec", "a"); f:write(tostring(s) .. "\n"); f:close()
end
function _G.__sync(n) local f = io.open("$WORK/sync.tmp", "w"); f:write(tostring(n)); f:close(); os.rename("$WORK/sync.tmp", "$WORK/sync") end
LUA

# The 100% line of the progress bar: the label, one space, 25 full blocks, one
# space, then the count. The label's width is not fixed, so the regex allows
# any run of spaces.
FULL_RE='screen:\s+100%\s+█{25}\s+30/30\s\['
# The output row sits behind the cell's left gutter on screen; the source line
# ends in "')", so a row that ends in the text is the output.
INSIDE_RE='(?m)inside the widget\s*$'
# The text/plain of the Output widget is 'Output()'. Its row is a row of its own, so
# it starts the line (after the gutter's spaces) and ends it; the source line
# 'out = w.Output()' does not match, its name follows a dot.
REPR_RE='(?m)(^|\s)Output\(\)\s*$'

# The scr cell (tqdm.notebook, 30 steps of 0.1 s) and the ow cell (an Output
# widget that prints one line).
make_widgets() {
  python3 - "$WORK/nb.ipynb" <<'PY'
import json, sys
def code(i, src):
    return {"cell_type": "code", "id": i, "metadata": {}, "source": src,
            "execution_count": None, "outputs": []}
cells = [code("scr", "from tqdm.notebook import tqdm\nimport time\n"
                     "for _ in tqdm(range(30), desc='screen'):\n    time.sleep(0.1)"),
         code("ow", "import ipywidgets as w\nfrom IPython.display import display\n"
                    "out = w.Output()\ndisplay(out)\nwith out:\n    print('inside the widget')")]
json.dump({"cells": cells, "nbformat": 4, "nbformat_minor": 5,
           "metadata": {"kernelspec": {"name": "python3", "display_name": "P", "language": "python"}}},
          open(sys.argv[1], "w"))
PY
}

# nvim on nb.ipynb with the state dir of this run. It does not wait for a row:
# the caller does (a relaunch waits for the saved 100% line, not the first cell).
launch_widgets() {
  rm -f "$WORK/rec"
  stop_session
  tmux new-session -d -s "$S" -x 200 -y 50
  tmux set-option -t "$S" status off
  tmux send-keys -t "$S" "cd $WORK && XDG_STATE_HOME=$WORK/state nvim -u $WORK/init.lua nb.ipynb" Enter
}
# rec EXPR: nvim evaluates EXPR as __rec(EXPR) and the value comes back here.
rec() { rm -f "$WORK/rec"; k ":lua __rec($1)" Enter; nv_sync; cat "$WORK/rec" 2>/dev/null; }
# wait_kernel SECONDS: nvim has the notebook's kernel started (its own record).
# A cell run before that finds no kernel, so the run waits for it, as a user does.
wait_kernel() {
  local i
  for i in $(seq 1 $(( $1 * 2 ))); do
    [ "$(rec 'tostring(require("jupynvim.notebook").get(0).kernel_started)')" = "true" ] && return 0
    sleep 0.5
  done
  return 1
}
start_widgets() {
  stop_session; make_widgets; rm -rf "$WORK/state"; launch_widgets
  wait_pane "from tqdm.notebook import tqdm" 20
  wait_kernel 30 || { echo "FAIL the kernel did not start within 30s"; FAILS=$((FAILS + 1)); }
  sleep 0.5
}

# The pane as Python reads it: UTF-8, the regex with re.M (^ and $ per row).
pane_has() {
  screen | python3 -c 'import re,sys; sys.exit(0 if re.search(sys.argv[1], sys.stdin.buffer.read().decode("utf-8"), re.M) else 1)' "$1"
}
# the 'screen: N%' values on the pane, one per token
pane_values() {
  screen | python3 -c 'import re,sys; print(" ".join(re.findall(r"screen:\s+(\d+)%", sys.stdin.buffer.read().decode("utf-8"))))'
}
# wait_pane REGEX SECONDS: true once the pane has a row matching REGEX
wait_pane() {
  local i
  for i in $(seq 1 $(( $2 * 2 ))); do
    pane_has "$1" && return 0
    sleep 0.5
  done
  return 1
}
# pane_colour_has SGR: the 100% line carries that SGR (capture with colours)
pane_colour_has() {
  tmux capture-pane -t "$S" -e -p | grep 'screen:' | grep '100%' | grep -q -F "$1"
}
# wait_colour SGR SECONDS: true once the 100% line carries that SGR
wait_colour() {
  local i
  for i in $(seq 1 $(( $2 * 2 ))); do
    pane_colour_has "$1" && return 0
    sleep 0.5
  done
  return 1
}
# wait_palette SECONDS: nvim's palette is derived (its own record)
wait_palette() {
  local i
  for i in $(seq 1 $(( $1 * 2 ))); do
    [ "$(rec 'require("jupynvim.palette").info().state')" = "ok" ] && return 0
    sleep 0.5
  done
  return 1
}
# the widget state :w wrote, as Python reads the notebook file
saved_widgets() {
  python3 - "$WORK/nb.ipynb" <<'PY'
import json, sys
nb = json.load(open(sys.argv[1]))
block = nb.get("metadata", {}).get("widgets", {}).get("application/vnd.jupyter.widget-state+json", {})
models = block.get("state", {})
bar = [m for m in models.values() if m.get("model_name") in ("IntProgressModel", "FloatProgressModel")
       and m.get("state", {}).get("value") == 30 and m.get("state", {}).get("max") == 30]
out = [m for m in models.values() if m.get("model_name") == "OutputModel"
       and "inside the widget" in json.dumps(m.get("state", {}))]
print("ok" if bar and out else "missing: " + ", ".join(sorted(m.get("model_name", "?") for m in models.values())))
PY
}

case_1() {
  start_widgets
  k "/from tqdm" Enter
  k ":JupynvimRunCell" Enter
  local vals="" full=0 n mid
  for n in $(seq 1 150); do
    sleep 0.2
    vals="$vals $(pane_values)"
    if pane_has "$FULL_RE"; then full=1; break; fi
  done
  mid="$(printf '%s\n' $vals | sort -un | awk '$1 > 0 && $1 < 100' | wc -l | tr -d ' ')"
  holds "scr: at least 3 distinct 'screen: N%' values with 0 < N < 100 while it runs (saw $mid)" '[ "$mid" -ge 3 ]'
  holds "scr: then 'screen: 100%' with 25 full blocks and 30/30" '[ "$full" = 1 ]'
  if [ "$full" = 1 ]; then
    local hex sgr tok
    # The first bar asked for the palette; its tokens reach the bar groups.
    holds "color: the palette is derived (the first bar asked for it)" 'wait_palette 20'
    tok="$(rec "(require('jupynvim.palette').get() or {}).ok")"
    holds "color: the palette's ok token is the one init.lua set (#$OK_HEX, got $tok)" '[ "$tok" = "#$OK_HEX" ]'
    sgr="38;2;$((16#${OK_HEX:0:2}));$((16#${OK_HEX:2:2}));$((16#${OK_HEX:4:2}))"
    holds "color: the 100% line is drawn in the palette's ok token ($sgr)" 'wait_colour "$sgr" 10'
    hex="$(rec "string.format('%06x', vim.api.nvim_get_hl(0, { name = 'JupynvimWidgetBarSuccess' }).fg or 0)")"
    hex="$(printf '%s' "$hex" | tr -dc '0-9a-f')"
    sgr="38;2;$((16#${hex:0:2}));$((16#${hex:2:2}));$((16#${hex:4:2}))"
    holds "color: the 100% line is drawn in JupynvimWidgetBarSuccess ($sgr)" 'pane_colour_has "$sgr"'
  else
    echo "FAIL color: no 100% line to read" >&2; FAILS=$((FAILS + 1))
  fi

  k "/out = w.Output" Enter
  k ":JupynvimRunCell" Enter
  holds "ow: the screen shows the Output widget's 'inside the widget' row" 'wait_pane "$INSIDE_RE" 20'
  holds "ow: no row shows the widget's own repr 'Output()' (the output is the widget's text)" \
    '! pane_has "$REPR_RE"'

  save
  holds "save: metadata.widgets holds the progress bar at 30/30 and the Output widget's text" \
    '[ "$(saved_widgets)" = "ok" ]'
}

# Relaunch with nothing run: the state comes from the file.
case_2() {
  k ":qa!" Enter
  jnv_wait_nvim_exit 20 || { echo "FAIL nvim did not quit within 20s of :qa!"; FAILS=$((FAILS + 1)); }
  launch_widgets
  holds "relaunch with nothing run: 'screen: 100%' with 25 full blocks shows within 20 s" \
    'wait_pane "$FULL_RE" 20'
  # The stop comes after the relaunched nvim has finished its blocking interpreter
  # lookups: the kernel start (its sys.path lookup) is one of them. A stop during such a
  # lookup leaves nvim asleep in vim.fn.system, which the suite reports as a leak.
  holds "relaunch: the notebook's kernel starts, and the 100% line is still on screen" \
    'wait_kernel 30 && pane_has "$FULL_RE"'
}

run_cases "$@"
finish "widget screen"

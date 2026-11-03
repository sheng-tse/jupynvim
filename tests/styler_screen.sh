#!/usr/bin/env bash
# A pandas Styler shows its table as aligned text on the real screen, in a real
# nvim under tmux. The Styler's text/plain is only a repr ("<pandas.io.formats
# .style.Styler object at 0x...>"), so the table has to come from its text/html.
# The bundle is a recorded Styler (pandas 3.0.0, tests/fixtures/), so pandas is
# not needed here.
#
#   s1  live: a kernel displays the bundle with display(bundle, raw=True), the
#       cell is run with the cell-run key, and the pane shows the table's rows in
#       order under the cell and never the repr.
#   s2  saved: the same bundle as an execute_result in the notebook file, opened
#       without running anything: the same rows, and no repr.
#   s3  a saved table of 600 rows is under the output cap's cut: its first
#       rows, the cap's marker line and its last rows show.
#   s4  saved Stylers of a groupby (a named index), a pivot_table (index and
#       columns named) and of strings with "<" that is not a tag: the column
#       labels are right-aligned over their columns and the strings read as
#       written. The row check itself is shown to refuse a row moved sideways.
#   s5  saved Stylers whose tooltips are titles in the cells' start tags (a ">"
#       inside a quoted value, and a quote that ends one early) and whose
#       caption has a rule of its own beside the table's style attribute: every
#       value stays in its column, no attribute text shows, the caption is the
#       first line.
#
#   bash tests/styler_screen.sh [case numbers...]
set -u
source "$(dirname "$0")/screen_lib.sh"

cat > "$WORK/init.lua" <<LUA
vim.opt.runtimepath:prepend("$ROOT")
vim.o.swapfile = false
require("jupynvim").setup({ core_path = "$BIN", auto_venv = false })
-- tmux cannot send <S-CR>, the cell-run key: <F5> reaches its map
vim.keymap.set("n", "<F5>", "<S-CR>", { remap = true })
function _G.__rec(s)
  local f = io.open("$WORK/rec", "a"); f:write(tostring(s) .. "\n"); f:close()
end
function _G.__sync(n) local f = io.open("$WORK/sync.tmp", "w"); f:write(tostring(n)); f:close(); os.rename("$WORK/sync.tmp", "$WORK/sync") end
LUA

# The table of tests/fixtures/styler_sty_format.json as the cell shows it (the
# golden of tests/html_table_spec.lua, H2), one row per line.
cat > "$WORK/golden" <<'GOLD'
       a           b     c
w   1.23   $1,000.00   12%
x  -2.50  $25,000.50   50%
y   3.14       $3.00   88%
z    n/a      $47.25  100%
GOLD

make_live() {
  python3 -I - "$WORK/nb.ipynb" "$ROOT/tests/fixtures/styler_sty_format.json" <<'PY'
import json, sys
src = ("import json\nfrom IPython.display import display\n"
       "display(json.load(open(%s))[\"data\"], raw=True)" % json.dumps(sys.argv[2]))
cell = {"cell_type": "code", "id": "sty", "metadata": {}, "source": src,
        "execution_count": None, "outputs": []}
json.dump({"cells": [cell], "nbformat": 4, "nbformat_minor": 5,
           "metadata": {"kernelspec": {"name": "python3", "display_name": "P", "language": "python"}}},
          open(sys.argv[1], "w"))
PY
}

make_saved() {
  python3 -I - "$WORK/nb.ipynb" "$ROOT/tests/fixtures/styler_sty_format.json" <<'PY'
import json, sys
bundle = json.load(open(sys.argv[2]))["data"]
# a notebook file keeps multi-line text as a list of lines
data = {k: v.splitlines(keepends=True) if k == "text/html" else v for k, v in bundle.items()}
out = {"output_type": "execute_result", "execution_count": 1, "metadata": {}, "data": data}
cell = {"cell_type": "code", "id": "sty", "metadata": {}, "source": "num.style.format(...)",
        "execution_count": 1, "outputs": [out]}
json.dump({"cells": [cell], "nbformat": 4, "nbformat_minor": 5,
           "metadata": {"kernelspec": {"name": "python3", "display_name": "P", "language": "python"}}},
          open(sys.argv[1], "w"))
PY
}

# A Styler of 600 rows, written the way pandas writes one (no pandas needed).
make_long() {
  python3 -I - "$WORK/nb.ipynb" <<'PY'
import json, sys
t = ['<style type="text/css">\n</style>\n<table id="T_long">\n  <thead>\n    <tr>\n'
     '      <th class="blank level0" >&nbsp;</th>\n']
for c in range(3):
    t.append('      <th id="T_long_level0_col%d" class="col_heading level0 col%d" >c%d</th>\n' % (c, c, c))
t.append("    </tr>\n  </thead>\n  <tbody>\n")
for r in range(600):
    t.append('    <tr>\n      <th id="T_long_level0_row%d" class="row_heading level0 row%d" >r%d</th>\n' % (r, r, r))
    for c in range(3):
        t.append('      <td id="T_long_row%d_col%d" class="data row%d col%d" >%d</td>\n' % (r, c, r, c, r * 3 + c))
    t.append("    </tr>\n")
t.append("  </tbody>\n</table>\n")
data = {"text/plain": "<pandas.io.formats.style.Styler object at 0x10a2b4c50>", "text/html": "".join(t)}
out = {"output_type": "execute_result", "execution_count": 1, "metadata": {}, "data": data}
cell = {"cell_type": "code", "id": "long", "metadata": {}, "source": "big.style",
        "execution_count": 1, "outputs": [out]}
json.dump({"cells": [cell], "nbformat": 4, "nbformat_minor": 5,
           "metadata": {"kernelspec": {"name": "python3", "display_name": "P", "language": "python"}}},
          open(sys.argv[1], "w"))
PY
}

# Saved outputs of recorded Stylers, one cell each (fixture names as arguments).
make_saved_many() {
  python3 -I - "$WORK/nb.ipynb" "$ROOT/tests/fixtures" "$@" <<'PY'
import json, sys
cells = []
for n, name in enumerate(sys.argv[3:]):
    bundle = json.load(open("%s/%s.json" % (sys.argv[2], name)))["data"]
    data = {k: v.splitlines(keepends=True) if k == "text/html" else v for k, v in bundle.items()}
    out = {"output_type": "execute_result", "execution_count": n + 1, "metadata": {}, "data": data}
    cells.append({"cell_type": "code", "id": "c%d" % n, "metadata": {}, "source": name,
                  "execution_count": n + 1, "outputs": [out]})
json.dump({"cells": cells, "nbformat": 4, "nbformat_minor": 5,
           "metadata": {"kernelspec": {"name": "python3", "display_name": "P", "language": "python"}}},
          open(sys.argv[1], "w"))
PY
}

# The goldens of tests/html_table_spec.lua, H12 and H13.
cat > "$WORK/golden_groupby" <<'GOLD'
            sales   units
region
  east   2,070.50   20.00
 north      15.75    1.00
  west  33,000.25  330.00
GOLD
cat > "$WORK/golden_named" <<'GOLD'
metric     sales  units
region
  east   2,070.5   20.0
  west  33,000.2  330.0
GOLD
cat > "$WORK/golden_lt" <<'GOLD'
                rule  n
0    x < 5 or x > 10  1
1            a <-> b  2
2             a <> b  3
3  x <= 5 and y >= 3  4
4         <18 or >65  5
5               bold  6
GOLD

# The goldens of tests/html_table_spec.lua, H18 and H19.
cat > "$WORK/golden_tips" <<'GOLD'
   score         label
a   0.91          pass
b   0.42  review">fail
c   0.77          pass
GOLD
cat > "$WORK/golden_caprule" <<'GOLD'
     Totals
          a    b
x  1.500000   10
y  2.250000  200
GOLD

launch_nb() {
  rm -f "$WORK/rec"
  stop_session
  tmux new-session -d -s "$S" -x 200 -y 50
  tmux set-option -t "$S" status off
  tmux send-keys -t "$S" "cd $WORK && XDG_STATE_HOME=$WORK/state nvim -u $WORK/init.lua nb.ipynb" Enter
}
rec() { rm -f "$WORK/rec"; k ":lua __rec($1)" Enter; nv_sync; cat "$WORK/rec" 2>/dev/null; }
wait_kernel() {
  local i
  for i in $(seq 1 $(( $1 * 2 ))); do
    [ "$(rec 'tostring(require("jupynvim.notebook").get(0).kernel_started)')" = "true" ] && return 0
    sleep 0.5
  done
  return 1
}
# pane_has REGEX: some row of the pane matches (Python, UTF-8, re.M)
pane_has() {
  screen | python3 -I -c 'import re,sys; sys.exit(0 if re.search(sys.argv[1], sys.stdin.buffer.read().decode("utf-8"), re.M) else 1)' "$1"
}
wait_pane() {
  local i
  for i in $(seq 1 $(( $2 * 2 ))); do
    pane_has "$1" && return 0
    sleep 0.5
  done
  return 1
}
# in_order GOLDEN: the pane on stdin holds every row of the file GOLDEN, one
# under the other, each starting at the same pane column: every pane row is
# the same prefix (the gutter and the output's indent) and then the golden
# row, with nothing after it. A row moved sideways does not match.
in_order() {
  python3 -I -c '
import sys
rows = [r.rstrip() for r in sys.stdin.buffer.read().decode("utf-8").split("\n")]
want = [l.rstrip("\n") for l in open(sys.argv[1], encoding="utf-8")]
for i in range(len(rows) - len(want) + 1):
    pre = None
    for j, w in enumerate(want):
        r = rows[i + j]
        if not r.endswith(w) or (pre is not None and r[:len(r) - len(w)] != pre):
            break
        pre = r[:len(r) - len(w)]
    else:
        sys.exit(0)
sys.exit(1)' "$1"
}
# golden_in_order [GOLDEN]: the pane holds GOLDEN's rows (default: the
# sty_format table)
golden_in_order() { screen | in_order "${1:-$WORK/golden}"; }
no_repr() { ! screen | grep -qE "Styler (object )?at 0x"; }

case_1() {
  stop_session; make_live; rm -rf "$WORK/state"; launch_nb
  wait_pane "display\(json.load" 20
  wait_kernel 30 || { echo "FAIL the kernel did not start within 30s"; FAILS=$((FAILS + 1)); }
  sleep 0.5
  k Escape
  k F5
  holds "s1: a live display(bundle, raw=True) shows the table's rows in order under the cell" \
    'wait_pane "\\\$25,000\\.50\\s+50%" 40 && golden_in_order'
  holds "s1: the repr of the Styler is not on the screen" 'no_repr'
}

case_2() {
  stop_session; make_saved; rm -rf "$WORK/state"; launch_nb
  holds "s2: a saved output shows the table's rows in order, with nothing run" \
    'wait_pane "\\\$25,000\\.50\\s+50%" 30 && golden_in_order'
  holds "s2: the repr of the Styler is not on the screen" 'no_repr'
}

case_3() {
  stop_session; make_long; rm -rf "$WORK/state"; launch_nb
  holds "s3: the first rows of a 600-row table show" \
    'wait_pane "\\br0\\s+0\\s+1\\s+2\\s*$" 30 && pane_has "\\br3\\s+9\\s+10\\s+11\\s*$" && pane_has "\\bc0\\s+c1\\s+c2\\s*$"'
  k "/lines hidden" Enter
  holds "s3: the cap's marker line says what it hides" 'pane_has "96 lines hidden \\(601 total\\)"'
  holds "s3: the last rows show after the marker" \
    'pane_has "\\br595\\s+1785\\s+1786\\s+1787\\s*$" && pane_has "\\br599\\s+1797\\s+1798\\s+1799\\s*$"'
  holds "s3: a row under the cut does not show" '! pane_has "\\br594\\s"'
  holds "s3: the repr of the Styler is not on the screen" 'no_repr'
}

case_4() {
  # the row check: the same rows, one of them a column to the right, is refused
  printf 'ab\ncd\n' > "$WORK/golden_ab"
  holds "s4: the row check takes rows that start at one column" \
    'printf "%s\n" "x" "  | ab" "  | cd" | in_order "$WORK/golden_ab"'
  holds "s4: the row check refuses a row moved a column to the right" \
    '! printf "%s\n" "x" "  | ab" "  |  cd" | in_order "$WORK/golden_ab"'
  stop_session; make_saved_many styler_groupby styler_named_both styler_lt_text; rm -rf "$WORK/state"; launch_nb
  holds "s4: a groupby Styler shows its labels right-aligned over their columns" \
    'wait_pane "33,000\\.25\\s+330\\.00\\s*$" 30 && golden_in_order "$WORK/golden_groupby"'
  holds "s4: a pivot_table Styler (index and columns named) shows its labels right-aligned" \
    'golden_in_order "$WORK/golden_named"'
  holds "s4: strings with '<' that is not a tag read as written" 'golden_in_order "$WORK/golden_lt"'
  holds "s4: the repr of a Styler is not on the screen" 'no_repr'
}

case_5() {
  stop_session; make_saved_many styler_tooltips_title styler_caption_rule; rm -rf "$WORK/state"; launch_nb
  holds "s5: tooltip titles in the start tags leave every value in its column" \
    'wait_pane "review\">fail\s*$" 30 && golden_in_order "$WORK/golden_tips"'
  holds "s5: no attribute text shows" '! pane_has "title=|0\.9: top|0\.5 < s|\">pass"'
  holds "s5: a caption rule beats the table's caption-side: the caption is the first line" \
    'golden_in_order "$WORK/golden_caprule"'
  holds "s5: the repr of a Styler is not on the screen" 'no_repr'
}

run_cases "$@"
finish "styler screen"

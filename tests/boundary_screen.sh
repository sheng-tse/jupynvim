#!/usr/bin/env bash
# Cell boundaries survive ordinary editing, in a real nvim under tmux.
#
# Separators are real buffer lines, and sync_from_buffer pairs cells with the
# text between them by position. One Backspace at the start of a cell glued
# its first line onto the separator, and the next :w saved that cell's code
# under its neighbor's id and dropped a cell. Each case below drives real
# keys on a fresh notebook and reads back what :w wrote. Undo across the
# plugin's own rewrites is in undo_screen.sh.
#
#   bash tests/boundary_screen.sh [case numbers...]
set -u
source "$(dirname "$0")/screen_lib.sh"

# the edits that break a boundary: <BS> at a cell's start, J into an output,
# dj over a separator, dG from the top, then u
case_1() {
  start
  k j; k Enter; k g g; k 0; k i; k BSpace; k Escape
  k Escape; k g g; k Enter; k G; k J; k Escape
  k Escape; k j; k Enter; k G; k d j
  k Escape; k g g; k Enter; k d G
  k u; k u
  save
  check "Backspace, J, dj, dG and u leave every cell intact" "$INTACT and cells['c1'] == base['c1'] and cells['c3'] == base['c3']"
}

# repairing a join moves nothing else: a mark in cell 3 stays on its line
case_2() {
  start
  k j; k j; k Enter; k g g; k m a; k Escape
  k k; k Enter; k g g; k 0; k i; k BSpace; k Escape
  k ":lua __rec(vim.fn.getline(vim.fn.line(\"'a\")))" Enter
  save
  holds "a mark in another cell survives the repair of a join" '[ "$(head -1 "$WORK/rec" 2>/dev/null)" = "a3 = 3" ]'
}

# <Del> at a cell's end does nothing, and what is typed next lands at the end
case_3() {
  start
  k Enter; k G; k A; k Delete; type_text "Z"; k Escape
  save
  check "<Del> at a cell's end then typing appends to that line" "$INTACT and cells['c1'] == ('a1 = 1\nb1 = 1Z', 1)"
}

# a counted J that runs through a separator is taken back whole
case_4() {
  start
  k j; k Enter; k g g; k 3 J
  save
  check "3J across a separator leaves the cells as they were" "$INTACT and cells['c1'] == base['c1'] and cells['c3'] == base['c3']"
}

# g- after a boundary break was taken back, then ordinary edits still land
case_5() {
  start
  k j; k Enter; k G; k d j
  k Escape; k j; k Enter; k A; type_text "  # one"; k Escape
  k g -; k g -; k g +; k g +
  k A; type_text "  # kept"; k Escape
  save
  check "g- and g+ after a taken-back delete, and later edits still save" "$INTACT and cells['c1'] == base['c1'] and cells['c3'][0] == 'a3 = 3  # one  # kept\nb3 = 3'"
}

# A cell never has no line at all. dd on a one-line cell, dj over a two-line
# one and <BS> at the start of an emptied one left two separators back to
# back. The cursor then sat on a separator, where every key was taken back,
# and o put the text in the next cell.
case_6() {
  start
  k j; k j; k j; k Enter; k d d
  k i; k z; k 4; k Escape
  save
  check "dd on a one-line cell leaves a line to type on" \
    "$INTACT and cells['c3'] == base['c3'] and cells['c4'] == ('z4', 0)"

  start
  k j; k j; k j; k Enter; k A
  for _ in $(seq 1 13); do k BSpace; done
  k q; k Escape
  save
  check "<BS> at the start of an emptied cell does nothing" \
    "$INTACT and cells['c3'] == base['c3'] and cells['c4'] == ('q', 0)"

  start
  k j; k Enter; k g g; k d j
  k o; k w; k 2; k Escape
  save
  check "o in a cell dj emptied opens the line in that cell" \
    "order == ['c1','c2','c3','c4','c5'] and all(cells[i] == base[i] for i in ['c1','c3','c4','c5']) and cells['c2'] == ('\nw2', 0)"
}

# . repeats an insert as one change, so the join and the text typed after it
# arrive together: only the join is taken back, and the text is in the cell
# before any :w
case_7() {
  start
  k j; k j; k Enter; k g g; k I; k BSpace; type_text "foo"; k Escape
  k Escape; k j; k Enter; k g g; k 0; k .
  k ":lua __rec(require('jupynvim.notebook').get(0).cells[4].source)" Enter
  save
  check ". of an insert that began with <BS> keeps what it typed" \
    "$INTACT and cells['c3'] == ('fooa3 = 3\nb3 = 3', 0) and cells['c4'] == (\"fooprint('hi4')\", 0)"
  holds "and the kept text is in its cell at once" "[ \"\$(head -1 \"\$WORK/rec\" 2>/dev/null)\" = \"fooprint('hi4')\" ]"
}

# a macro, and keys that arrive together, the same way; the cursor comes back
# after the text, so the next key lands there too
case_8() {
  start
  k j; k j; k Enter; k g g; k q a; k I; k BSpace; type_text "M"; k Escape; k q
  k Escape; k j; k Enter; k g g; k @ a
  k Escape; k k; k k; k Enter; k g g; k I
  tmux send-keys -t "$S" BSpace Z; sleep 0.5
  type_text "Y"; k Escape
  save
  check "a macro and a burst of keys that began with <BS> keep what they typed" \
    "order == ['c1','c2','c3','c4','c5'] and cells['c1'] == base['c1'] and cells['c5'] == base['c5'] and cells['c2'] == ('ZYa2 = 2\nb2 = 2', 0) and cells['c3'] == ('Ma3 = 3\nb3 = 3', 0) and cells['c4'] == (\"Mprint('hi4')\", 0)"
}

# . of an insert that began with <Del> at a cell's end
case_9() {
  start
  k Enter; k G; k A; k Delete; type_text "Z"; k Escape
  k Escape; k j; k j; k Enter; k G; k .
  save
  check ". of an insert that began with <Del> keeps what it typed" \
    "$INTACT and cells['c1'] == ('a1 = 1\nb1 = 1Z', 1) and cells['c3'] == ('a3 = 3\nb3 = 3Z', 0)"
}

# Output lines are display and never saved. A source line moved under an
# output marker left the separators as they were, and :w dropped it.
case_10() {
  start
  k Enter; k G; k M-j; k A; type_text "Z"; k Escape
  save
  check "a line moved into an output stays in its cell" "$INTACT and cells['c1'] == ('a1 = 1\nb1 = 1Z', 1)"

  start
  k j; k Enter; k g g; k ":m -2" Enter
  save
  check "a line moved up into the output above stays in its cell" "$INTACT and cells['c1'] == base['c1']"
}

# :s that matches separator text: the separator stays, the rest of it is kept
case_11() {
  start
  k Enter; k ":%s/jupynvim/JN/g" Enter
  save
  check ":s over separator text keeps its other changes" \
    "order == ['c1','c2','c3','c4','c5'] and cells['c1'] == base['c1'] and cells['c5'] == ('x = \"# %%[JN:cell-sep]\"', 1)"
}

# <C-u> at a cell's first column joins like <BS>: the next key lands in the
# cell being edited, not at the end of the one below
case_12() {
  start
  k j; k j; k Enter; k g g; k I; k C-u; type_text "Q"; k Escape
  save
  check "<C-u> at a cell's start then typing stays in that cell" "$INTACT and cells['c3'] == ('Qa3 = 3\nb3 = 3', 0)"
}

# the separator a take-back puts back is hidden again at once
case_13() {
  start
  k j; k j; k Enter; k G; k J; sleep 0.3
  # the marker text in cell 5's code sits between quotes
  holds "a separator put back after J is not shown" \
    '! screen | grep -qE "(^|[^\"])# %%\[jupynvim:cell-sep\]([^\"]|$)"'
  k Escape; k Escape
}

# The keys that run a cell can arrive in the same read as the <BS> that broke
# a boundary. The run synced the merged layout into the cells, and the next
# :w saved one cell fewer.
case_14() {
  start
  k j; k Enter; k g g; k I
  tmux send-keys -t "$S" BSpace F5; sleep 3
  save
  check "a run in the same keys as a <BS> at a cell's start keeps every cell" \
    "$INTACT and cells['c1'] == base['c1'] and cells['c3'] == base['c3']"
}

# :s | w saves before TextChanged fires
case_15() {
  start
  k Enter; k ":%s/jupynvim:out/res/ | w" Enter; sleep 1.5
  check ":s over an output marker then :w in one line saves the cells intact" \
    "$INTACT and cells['c1'] == base['c1']"
  k Escape
}

run_cases "$@"
finish "BOUNDARY SCREEN"

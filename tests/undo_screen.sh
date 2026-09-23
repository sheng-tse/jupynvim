#!/usr/bin/env bash
# Undo and redo inside cells around the plugin's own rewrites of the buffer,
# its outputs, cell moves and the history an open reads back, in a real nvim
# under tmux. Each case reads back what :w wrote.
#
# u means the user's last edit. The plugin writes outputs and whole layouts
# into the buffer too, and vim's undo steps over neither, so the cell guard
# does: u and <C-r> go on past an output, and never onto a state from before
# a cell was added, removed or moved, which would pair text with the wrong
# cells.
#
#   bash tests/undo_screen.sh [case numbers...]
set -u
source "$(dirname "$0")/screen_lib.sh"

# u after running another cell undoes the edit, not the output the run wrote
case_1() {
  start
  k j; k j; k Enter; k G; k A; type_text "  # e3"; k Escape; k Escape
  k j; run_wait
  k k; k Enter; k u; k Escape
  k Enter; k A; type_text "  # after"; k Escape
  sleep 0.6
  local shows; shows=$(ran)
  save
  check "u after running another cell undoes the edit" "$INTACT and cells['c3'] == ('a3 = 3\nb3 = 3  # after', 0) and cells['c4'][1] >= 1"
  holds "the run's output is back on screen after the next edit" "[ $shows -ge 1 ]"
}

# u inside a cell right after moving a cell must not pair text with the wrong
# cells: vim's undo would put the sources back but not the cells
case_2() {
  start plain
  k j; k ":lua require('jupynvim').move_cell(0, 1)" Enter; sleep 1
  k Enter; k u; k Escape
  save
  check "u inside a cell after a move keeps each source with its cell" \
    "order == ['c1','c3','c2','c4'] and all(cells[i] == base[i] for i in ['c1','c2','c3','c4'])"
}

# Opening wipes the history, so the opened state comes back from undo as
# change 0, which the guard took for a state from before the cells.
case_3() {
  start plain
  k j; k j; k Enter; k A; type_text "  # typo"; k Escape
  k u
  if warned; then echo "FAIL u after the first edit warns about a cell change"; FAILS=$((FAILS + 1)); fi
  save
  check "u after the first edit of a session takes it back" "$PLAIN"
}

# the same across sessions: u after reopening goes to the root of the history
# the last :w saved
case_4() {
  start plain
  k j; k j; k Enter; k A; type_text "  # typo"; k Escape
  save
  reopen
  k j; k j; k Enter; k u
  if warned; then echo "FAIL u after reopening warns about a cell change"; FAILS=$((FAILS + 1)); fi
  save
  check "u after reopening takes back the edit saved last session" "$PLAIN"
}

# :e! reads the history back from the undo file
case_5() {
  start plain
  k j; k j; k Enter; k A; type_text "  # one"; k Escape
  k A; type_text "  # two"; k Escape
  save
  k ":e!" Enter; sleep 2
  k Escape; k g g; k j; k j; k Enter; k u; k u
  save
  check "u u after :e! undoes the two saved edits" "$PLAIN"

  start plain
  k j; k j; k Enter; k A; type_text "  # one"; k Escape
  save
  k ":e!" Enter; sleep 2
  k Escape; k g g; k j; k j; k Enter; k A; type_text "  # two"; k Escape
  k A; type_text "  # three"; k Escape; k u
  save
  check "one u after :e! undoes one new edit" "cells['c3'] == ('a3 = 3  # one  # two\nb3 = 3', 0)"
}

# history read back stops at a move the last session made, however many
# changes came before the move
case_6() {
  start plain
  k j; k j; k j; k Enter; k A; type_text "  # p1"; k Escape; k A; type_text "  # p2"; k Escape
  k A; type_text "  # p3"; k Escape; k Escape
  k g g; k j; k ":lua require('jupynvim').move_cell(0, 1)" Enter; sleep 1
  k Enter; k A; type_text "  # e"; k Escape
  save
  reopen
  k j; k Enter; k u; k u
  save
  check "u after reopening stops at the last session's move" \
    "order == ['c1','c3','c2','c4'] and all(cells[i] == base[i] for i in ['c1','c2','c3']) and cells['c4'][0] == \"print('hi4')  # p1  # p2  # p3\""
}

# and so does u that steps over a run's output in the reopened notebook
case_7() {
  start plain
  k j; k ":lua require('jupynvim').move_cell(0, 1)" Enter; sleep 1
  k Enter; k A; type_text "  # e"; k Escape
  save
  reopen
  k j; k j; k Enter; k u; k Escape
  k j; run_wait
  k g g; k j; k Enter; k u; k Escape
  save
  check "u after a run in a reopened notebook does not undo the last session's move" \
    "order == ['c1','c3','c2','c4'] and all(cells[i][0] == base[i][0] for i in ['c1','c2','c3','c4'])"
}

# u after a run keeps undoing to the user's edit, but not past a move
case_8() {
  start plain
  k j; k ":lua require('jupynvim').move_cell(0, 1)" Enter; sleep 1
  k j; run_wait
  k g g; k j; k Enter; k u; k Escape
  save
  check "u after a run does not undo a move before it" \
    "order == ['c1','c3','c2','c4'] and all(cells[i][0] == base[i][0] for i in ['c1','c2','c3','c4'])"
}

# nor does redo: with the moved cell back in place, a state from before the
# move is this cell list's again, and <C-r> from it redid the output clear,
# then the move and the edit after it, whose text follows the moved order
case_9() {
  start plain
  k Enter; k A; type_text "  # e1"; k Escape; k Escape
  k ":lua _G.__before = vim.fn.changenr()" Enter
  k ":lua require('jupynvim').clear_cell_output(0)" Enter
  k j; k ":lua require('jupynvim').move_cell(0, 1)" Enter; sleep 1
  k Enter; k A; type_text "  # moved"; k Escape; k Escape
  k ":lua require('jupynvim').move_cell(0, -1)" Enter; sleep 1
  k k; k Enter; k A; type_text "  # e2"; k Escape; k Escape
  k ":exe 'undo ' . luaeval('_G.__before')" Enter
  k Enter; k C-r
  save
  check "<C-r> from before a move and back stops short of the move" \
    "order == ['c1','c2','c3','c4'] and all(cells[i] == base[i] for i in ['c2','c3','c4']) and cells['c1'] == ('a1 = 1  # e1\nb1 = 1', 0)"
}

# Output streaming in while typing in another cell lands in the open insert,
# or just after A, before anything is typed. Either way one u after the
# insert takes back the insert and stops there.
case_10() {
  local when
  for when in typed entered; do
    start stream
    k j; k j; k Enter; k A; type_text "  # one"; k Escape; k Escape
    k j; k ":JupynvimRunCell" Enter
    for _ in $(seq 1 40); do sleep 0.5; screen | grep -q "tick 0" && break; done
    k k; k k; k Enter; k A
    if [ "$when" = typed ]; then type_text "x"; sleep 1.2; type_text "y"; else sleep 1.2; type_text "xy"; fi
    k Escape
    for _ in $(seq 1 20); do sleep 0.5; screen | grep -q "tick 9" && break; done
    sleep 0.6
    k u
    save
    check "u after typing while output streams undoes only the insert ($when)" \
      "order == ['c1','c2','c3','c4'] and cells['c1'] == base['c1'] and cells['c2'] == base['c2'] and cells['c3'] == ('a3 = 3  # one\nb3 = 3', 0)"
  done
}

# <C-CR> in insert mode. Output that arrives in the insert is the user's step;
# with nothing typed, the run's step holds only output and u goes on past it.
case_11() {
  local E2='cells["c2"] == ("a2 = 2\nb2 = 2  # e2", 0) and cells["c4"][0] == base["c4"][0] and cells["c4"][1] >= 1'
  start
  k j; k Enter; k G; k A; type_text "  # e2"; k Escape; k Escape
  k j; k j; k Enter; k A; type_text "  # e4"; k F5
  for _ in $(seq 1 20); do sleep 0.5; [ "$(ran)" -ge 1 ] && break; done
  sleep 0.6
  k Escape; k u
  save
  check "u after <C-CR> while typing undoes that insert only" "order == ['c1','c2','c3','c4','c5'] and $E2"

  start
  k j; k Enter; k G; k A; type_text "  # e2"; k Escape; k Escape
  k j; k j; k Enter; k A; k F5
  for _ in $(seq 1 20); do sleep 0.5; [ "$(ran)" -ge 1 ] && break; done
  sleep 0.6
  type_text "  # e4"; k Escape; k u
  save
  check "u after typing into a run's output undoes that insert only" "order == ['c1','c2','c3','c4','c5'] and $E2"

  start
  k j; k Enter; k G; k A; type_text "  # e2"; k Escape; k Escape
  k j; k j; k Enter; k A; k F5
  for _ in $(seq 1 20); do sleep 0.5; [ "$(ran)" -ge 1 ] && break; done
  sleep 0.6
  k Escape; k u
  save
  check "u after <C-CR> with nothing typed undoes the edit before the run" \
    "order == ['c1','c2','c3','c4','c5'] and cells['c2'] == base['c2'] and cells['c4'][0] == base['c4'][0] and cells['c4'][1] >= 1"
}

# A data:image URI typed or pasted into markdown is swapped for a
# placeholder by rewriting the buffer, in the same undo step. One u takes the
# insert back and stops there.
case_12() {
  local URI='![x](data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==)'
  start md
  k j; k Enter; k A; type_text "  # one"; k Escape; k Escape
  k j; k Enter; k o; type_text "$URI"; k Escape
  k u
  save
  check "u after typing an image URI into markdown undoes only the insert" \
    "order == ['c1','c2','c3','c4'] and cells['c2'] == ('a2 = 2  # one\nb2 = 2', 0) and cells['c3'] == base['c3']"

  start md
  k j; k Enter; k A; type_text "  # one"; k Escape; k Escape
  k j; k Enter; k G
  k ":let @a = '$URI'" Enter
  k '"'; k a; k p; sleep 0.6
  k u
  save
  check "u after pasting an image URI into markdown undoes the paste only" \
    "order == ['c1','c2','c3','c4'] and cells['c2'] == ('a2 = 2  # one\nb2 = 2', 0) and cells['c3'] == base['c3']"
}

# :earlier 1f after a run goes back to the save, not one edit past it: only
# a single u or g- steps over an output
case_13() {
  start
  k j; k j; k Enter; k G; k A; type_text "  # saved"; k Escape
  save
  k j; run_wait
  k k; k Enter; k ":earlier 1f" Enter; k Escape
  save
  check ":earlier 1f after a run lands on the save" "$INTACT and cells['c3'] == ('a3 = 3\nb3 = 3  # saved', 0)"
}

# and :undo N forward onto a run's output does not redo the edit after it
case_14() {
  start
  k j; k j; k Enter; k G; k A; type_text "  # one"; k Escape; k Escape
  k j; run_wait
  k ":let g:jn_ran = changenr()" Enter
  k k; k Enter; k A; type_text "  # two"; k Escape
  k u; k u
  k ":execute 'undo' g:jn_ran" Enter; k Escape
  save
  check ":undo N onto a run's output lands there" "$INTACT and cells['c3'] == ('a3 = 3\nb3 = 3  # one', 0)"
}

# u after deleting an image brings it back and nothing else: the delete is
# an edit made for the user, not an output to step over
case_15() {
  start image
  k Enter; k A; type_text "  # one"; k Escape; k Escape
  k j; k j; k Enter; k ":JupynvimDeleteImage" Enter; k u; k Escape
  save
  check "u after deleting an image keeps the edit before it" \
    "order == ['c1','c2','c3','c4'] and cells['c1'][0] == 'a1 = 1  # one\nb1 = 1' and 'data:image/png' in cells['c3'][0]"
}

# the u from case 1 reaches the cells too: clearing every output rebuilds the
# buffer from them, and must not bring the undone edit back
case_16() {
  start
  k j; k j; k Enter; k A; type_text "  # one"; k Escape; k Escape
  k j; run_wait
  k k; k Enter; k u; k Escape
  k '\'; k n; k C; sleep 0.6
  local back; back=$(screen | grep -c "a3 = 3  # one")
  save
  check "u after a run, then clear all outputs, keeps the edit undone" \
    "order == ['c1','c2','c3','c4','c5'] and cells['c3'] == ('a3 = 3\nb3 = 3', 0) and cells['c4'][1] == 0"
  holds "the undone edit stays off screen after clear all outputs" "[ $back -eq 0 ]"
}

# keys that arrive together with a <BS> at a cell's start after u hid an
# output stay in the cell being edited, and the output comes back
case_17() {
  start
  k j; k j; k Enter; k G; k A; type_text "  # e3"; k Escape; k Escape
  k j; run_wait
  k k; k Enter; k u; k Escape
  k Enter; k g g; k I
  tmux send-keys -t "$S" BSpace Z; sleep 0.5
  type_text "Y"; k Escape
  sleep 0.6
  local shows; shows=$(ran)
  save
  check "a burst after u hid an output keeps its keys in the edited cell" \
    "$INTACT and cells['c3'] == ('ZYa3 = 3\nb3 = 3', 0) and cells['c4'][1] >= 1"
  holds "and the output is back on screen after the next key" "[ $shows -ge 1 ]"
}

# A step per output sync pushed the user's own edits out of 'undolevels'
# within minutes of a chatty run. Outputs between two edits share one step.
case_18() {
  start stream
  k j; k j; k Enter; k A; type_text "  # one"; k Escape; k Escape
  k ":let g:jn_before = undotree().seq_last" Enter
  k j; k ":JupynvimRunCell" Enter
  for _ in $(seq 1 30); do sleep 0.5; screen | grep -q "tick 9" && break; done
  sleep 0.8
  k ":lua __rec(vim.fn.undotree().seq_last - vim.g.jn_before)" Enter
  local steps; steps=$(tail -1 "$WORK/rec" 2>/dev/null)
  holds "ten outputs of one run take one undo step (took ${steps:-?})" "[ '${steps:-99}' -le 1 ]"
  k k; k Enter; k u; k Escape
  save
  check "and u still steps over them to the edit" "cells['c3'] == base['c3'] and cells['c4'][1] >= 1"
}

# An output written after u starts a branch of the undo tree, and <C-r>
# said "Already at newest change" with the undone edit one branch over
case_19() {
  start stream
  k j; k j; k Enter; k A; type_text "  # one"; k Escape; k Escape
  k j; k ":JupynvimRunCell" Enter
  for _ in $(seq 1 40); do sleep 0.3; screen | grep -q "tick 0" && break; done
  k k; k Enter; k u
  sleep 1.5
  k C-r; sleep 0.5
  for _ in $(seq 1 20); do sleep 0.5; screen | grep -q "tick 9" && break; done
  sleep 0.6
  save
  check "<C-r> after outputs landed on an undo redoes the edit" "cells['c3'] == ('a3 = 3  # one\nb3 = 3', 0)"
}

# U takes back the changes on the last line changed, which vim knows by
# number only. A run that cleared an output above it shifted the lines, and U
# rewrote the line that took the number, in the next cell.
case_20() {
  start plain
  k j; k Enter; k G; k A; type_text "Z"; k Escape; k Escape
  k k; k ":JupynvimRunCell" Enter; sleep 3
  k j; k Enter; k U; sleep 0.3
  save
  check "U after an output above moved the lines leaves the other cells alone" \
    "order == ['c1','c2','c3','c4'] and cells['c3'] == base['c3'] and cells['c2'] == ('a2 = 2\nb2 = 2Z', 0)"
}

# Clearing outputs is asked for, not an output streaming in: u takes back the
# clear, and stepping over it took back an edit in another cell instead
case_21() {
  start
  k j; k j; k Enter; k A; type_text "  # one"; k Escape; k Escape
  k '\'; k n; k C; sleep 0.6
  k Enter; k u; sleep 0.5
  local shown; shown=$(screen | grep -c OUT1)
  k Escape
  save
  check "u after clearing outputs keeps the edit before the clear" "cells['c3'] == ('a3 = 3  # one\nb3 = 3', 0)"
  holds "and does not show the cleared output as if it were back" "[ $shown -eq 0 ]"
  holds "but says why" 'warned_about "cannot bring back cleared outputs"'
}

# u after running another cell takes back the edit and leaves the output on
# screen. Stepping over the output took its lines away until the next edit.
case_22() {
  start
  k j; k j; k Enter; k A; type_text "  # mine"; k Escape; k Escape
  k j; run_wait
  k k; k Enter; k u; sleep 0.5
  local shown; shown=$(ran)
  local gone; gone=$(screen | grep -c "# mine")
  k C-r; sleep 0.8
  local back; back=$(screen | grep -c "# mine")
  save
  holds "u after a run leaves the output on screen" "[ $shown -ge 1 ]"
  holds "and takes the edit away" "[ $gone -eq 0 ]"
  holds "and <C-r> brings the edit back" "[ $back -ge 1 ]"
  check "and :w keeps both" "cells['c3'] == ('a3 = 3  # mine\nb3 = 3', 0) and cells['c4'][1] >= 1"
}

run_cases "$@"
finish "UNDO SCREEN"

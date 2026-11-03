#!/usr/bin/env bash
# Cells that wait behind a running one show as queued, on the real screen, in
# a real nvim under tmux with the colors the terminal gets (capture-pane -e),
# and a restart, a kernel that dies or a backend that goes away releases them.
# #48.
#
# Three cells with a saved badge each: 1 sleeps 6 s and prints, 2 and 3 are
# quick. Run all marks all three "[*]". Cell 1 is the running one (the busy
# color on the label, the dot and the timer, and the whole frame); 2 and 3 wait
# (the label in the header color, a dot of the same color and no timer, and
# the frame as calm as an idle cell's). After the run every footer is "[n] ✓".
#
#   q1  Run all while cell 1 sleeps, then to the end.
#   q2  Run all, then :JupynvimRestart while cell 1 sleeps: cells 2 and 3 show
#       the badges they had before the run, cell 1 shows ✗ and its time stops.
#   q3  Run all, then the backend process is killed (kill -9): the same.
#   q4  Run all, and Run all again while cell 1 sleeps: once the first run is
#       over, cells 2 and 3 wait as [*] behind cell 1's second run, not done.
#   q5  Run all, then the kernel alone is killed (kill -9): as q2, and the
#       death is said.
#   q6  Run all, then :JupynvimClearOutputs while cell 1 sleeps: cell 1 keeps
#       running with its time, cells 2 and 3 keep waiting as [*].
#
#   bash tests/queued_screen.sh [case numbers...]
set -u
source "$(dirname "$0")/screen_lib.sh"

# the checks over what capture-pane -e wrote: SGR runs are read into one
# attribute set per cell, so two cells compare by what they look like
cat > "$WORK/chk.py" <<'PY'
import re, sys

def parse(path):
    rows = []
    for line in open(path, encoding="utf-8").read().split("\n"):
        cells, st, pos = [], {}, 0
        def put(seg):
            for ch in seg:
                cells.append((ch, tuple(sorted(st.items()))))
        for m in re.finditer(r"\x1b\[([0-9;:]*)m", line):
            put(line[pos:m.start()])
            p = [x for x in m.group(1).split(";")]
            i = 0
            while i < len(p):
                n = p[i] or "0"
                if n == "0":
                    st.clear()
                elif n in ("38", "48") and i + 1 < len(p):
                    k = 3 if p[i + 1] == "2" else 1
                    st["fg" if n == "38" else "bg"] = ";".join(p[i + 1:i + 2 + k])
                    i += 1 + k
                elif n in ("39", "49"):
                    st.pop("fg" if n == "39" else "bg", None)
                elif n.isdigit() and (30 <= int(n) <= 37 or 90 <= int(n) <= 97):
                    st["fg"] = n
                elif n.isdigit() and (40 <= int(n) <= 47 or 100 <= int(n) <= 107):
                    st["bg"] = n
                elif n in ("22", "23", "24", "25", "27", "28", "29"):
                    for a in (("1", "2") if n == "22" else (str(int(n) - 20),)):
                        st.pop("a" + a, None)
                else:
                    st["a" + n] = True
                i += 1
            pos = m.end()
        put(line[pos:])
        rows.append(cells)
    return rows

def text(row): return "".join(c for c, _ in row)
def footers(rows): return [i for i, r in enumerate(rows) if "╰─" in text(r)]
def at(row, sub):
    # the attributes of the first cell of `sub` in the row; a sub that is not
    # there gives a value no other cell has, so a comparison fails
    j = text(row).find(sub)
    return row[j][1] if j >= 0 else "missing " + sub
BORDER = set("╭╮╰╯│─")
def frame(rows, i):
    # the attribute sets of the frame glyphs of the cell whose footer is row i
    top = max([j for j in range(i) if "╭" in text(rows[j])], default=0)
    return {k for j in range(top, i + 1) for c, k in rows[j] if c in BORDER}

fails = 0
def ok(name, cond, why=""):
    global fails
    if not cond: fails += 1
    print(("ok " if cond else "FAIL ") + name + ("" if cond else "  " + why))

mode = sys.argv[1]
caps = [parse(p) for p in sys.argv[2:]]
fs = [footers(c) for c in caps]
for n, f in enumerate(fs):
    if len(f) != 3:
        ok("capture %d shows three cells" % n, False, "footers at rows %s" % f)
        sys.exit(1)

if mode == "q1":
    idle, run, done = caps
    fi, fr, fd = fs
    ti = [text(idle[i]) for i in fi]
    ok("q1: before the run the cells show their saved badges",
       all(re.search(r"\[%d\] ✓ 0\.3s" % n, t) for n, t in zip((5, 7, 8), ti)), str(ti))
    tr = [text(run[i]) for i in fr]
    ok("q1: the running cell shows [*] and a live time", re.search(r"\[\*\] ● \d+\.\ds", tr[0]), tr[0])
    for n in (1, 2):
        ok("q1: cell %d waits as [*] with a dot and no time" % (n + 1),
           re.search(r"\[\*\] ●\s+─", tr[n]) and not re.search(r"\[\*\] ● ?\d", tr[n]), tr[n])
    busy_label, busy_dot = at(run[fr[0]], "[*]"), at(run[fr[0]], "●")
    ok("q1: the running cell's label and dot share the busy color", busy_label == busy_dot, "%s %s" % (busy_label, busy_dot))
    for n in (1, 2):
        row = run[fr[n]]
        label, dot = at(row, "[*]"), at(row, "●")
        ok("q1: cell %d's dot is the color of its label (Comment)" % (n + 1), label == dot, "%s %s" % (label, dot))
        ok("q1: cell %d's dot is not the running cell's busy color" % (n + 1), dot != busy_dot, str(dot))
        ok("q1: cell %d's frame is as calm as an idle cell's" % (n + 1),
           frame(run, fr[n]) == frame(idle, fi[n]), "%s vs %s" % (frame(run, fr[n]), frame(idle, fi[n])))
    fgs = {dict(k).get("fg") for k in frame(run, fr[0])}
    ok("q1: the running cell's frame is painted in the busy color",
       frame(run, fr[0]) != frame(idle, fi[0]) and not isinstance(busy_label, str) and dict(busy_label).get("fg") in fgs,
       "busy %s, frame colors %s" % (busy_label, fgs))
    td = [text(done[i]) for i in fd]
    ok("q1: after the run every footer is [n] ✓", all(re.search(r"\[\d+\] ✓", t) for t in td), str(td))
elif mode == "q4":
    mid, done = caps
    fm, fd = fs
    tm = [text(mid[i]) for i in fm]
    ok("q4: cell 1's second run is running", re.search(r"\[\*\] ● \d+\.\ds", tm[0]), tm[0])
    for n in (1, 2):
        ok("q4: cell %d waits as [*] for its second run, it is not shown done" % (n + 1),
           re.search(r"\[\*\] ●\s+─", tm[n]) and "✓" not in tm[n], tm[n])
    td = [text(done[i]) for i in fd]
    ok("q4: after both runs every footer is [n] ✓", all(re.search(r"\[\d+\] ✓", t) for t in td), str(td))
elif mode == "q6":
    idle, a, done = caps
    fi, fa, fd = fs
    ta = [text(a[i]) for i in fa]
    ok("q6: the running cell keeps running through the clear", re.search(r"\[\*\] ● \d+\.\ds", ta[0]), ta[0])
    ok("q6: and its frame stays busy", frame(a, fa[0]) != frame(idle, fi[0]), "%s" % frame(a, fa[0]))
    for n in (1, 2):
        ok("q6: cell %d still waits as [*] after the clear" % (n + 1), re.search(r"\[\*\] ●\s+─", ta[n]), ta[n])
    td = [text(done[i]) for i in fd]
    ok("q6: the run still ends with every footer [n] ✓", all(re.search(r"\[\d+\] ✓", t) for t in td), str(td))
elif mode in ("q2", "q3", "q5"):
    idle, a, b = caps
    fi, fa, fb = fs
    for n in (1, 2):
        ok("%s: cell %d shows the badge it had before the run" % (mode, n + 1),
           text(a[fa[n]]) == text(idle[fi[n]]) and text(b[fb[n]]) == text(idle[fi[n]]),
           "%r / %r / %r" % (text(idle[fi[n]]), text(a[fa[n]]), text(b[fb[n]])))
        ok("%s: cell %d is not drawn busy or queued" % (mode, n + 1), "[*]" not in text(b[fb[n]]), text(b[fb[n]]))
    ta, tb = text(a[fa[0]]), text(b[fb[0]])
    ok("%s: the running cell shows ✗ and a time" % mode, re.search(r"✗ \d+(\.\d)?s", tb), tb)
    ok("%s: its time stopped (the same 1.5 s later)" % mode, ta == tb, "%r then %r" % (ta, tb))
    ok("%s: nothing is drawn as running any more" % mode, all("[*]" not in text(b[i]) for i in fb))
sys.exit(1 if fails else 0)
PY
chk() { python3 -I "$WORK/chk.py" "$@" || FAILS=$((FAILS + 1)); }

# Cell 1 sleeps. Every cell has the badge a saved run left (execution count,
# 0.3 s from the standard timing stamps), so a badge that is not "[*]" is
# the old one coming back.
make_queue_nb() {
  python3 -I - "$WORK/nb.ipynb" <<'PY'
import json, sys
stamp = {"iopub.execute_input": "2026-06-12T21:38:05.100Z", "shell.execute_reply": "2026-06-12T21:38:05.400Z"}
def code(i, src, n):
    return {"cell_type": "code", "id": "q%d" % i, "metadata": {"execution": stamp}, "source": src,
            "execution_count": n, "outputs": []}
cells = [code(1, 'import time; time.sleep(6); print("one")', 5),
         code(2, "x = 2", 7),
         code(3, 'print("three")', 8)]
json.dump({"cells": cells, "nbformat": 4, "nbformat_minor": 5,
           "metadata": {"kernelspec": {"name": "python3", "display_name": "P", "language": "python"}}},
          open(sys.argv[1], "w"))
PY
}

launch_nb() {
  rm -f "$WORK/rec"
  stop_session
  tmux new-session -d -s "$S" -x 120 -y 30
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
pane_has() {
  screen | python3 -I -c 'import re,sys; sys.exit(0 if re.search(sys.argv[1], sys.stdin.buffer.read().decode("utf-8"), re.M) else 1)' "$1"
}
wait_pane() {
  local i
  for i in $(seq 1 $(( $2 * 5 ))); do
    pane_has "$1" && return 0
    sleep 0.2
  done
  return 1
}
# cap NAME: the pane with its colors, $WORK/NAME.raw
cap() { tmux capture-pane -t "$S" -e -p > "$WORK/$1.raw"; }

# a fresh notebook, its kernel up, the cursor in command mode, the idle pane
# captured as idle.raw
begin() {
  stop_session; make_queue_nb; rm -rf "$WORK/state"; launch_nb
  wait_pane 'print\("three"\)' 20 || { fail_later "$1: the notebook did not show within 20s"; return 1; }
  wait_kernel 30 || { fail_later "$1: the kernel did not start within 30s"; return 1; }
  k Escape
  sleep 0.5
  cap idle
}
# the run is on: cell 1 shows its live time
running() { wait_pane '\[\*\] ● [0-9]+\.[0-9]s' 15; }

case_1() {
  begin q1 || return
  k ":JupynvimRunAll" Enter
  running || { fail_later "q1: cell 1 never showed [*] with a time"; return; }
  cap run
  wait_pane '^[^A-Za-z0-9"]*three\s*$' 30 || { fail_later "q1: three was never printed"; return; }
  sleep 0.6
  cap done
  chk q1 "$WORK/idle.raw" "$WORK/run.raw" "$WORK/done.raw"
}

case_2() {
  begin q2 || return
  k ":JupynvimRunAll" Enter
  running || { fail_later "q2: cell 1 never showed [*] with a time"; return; }
  k ":JupynvimRestart" Enter
  wait_pane '✗ [0-9]' 15 || { fail_later "q2: cell 1 never showed ✗ after the restart"; return; }
  sleep 0.3
  cap a
  sleep 1.5
  cap b
  chk q2 "$WORK/idle.raw" "$WORK/a.raw" "$WORK/b.raw"
}

case_3() {
  begin q3 || return
  local pid kernels
  pid="$(rec 'require("jupynvim").client.pid')"
  case "$pid" in ''|*[!0-9]*) fail_later "q3: the backend pid is '$pid'"; return;; esac
  k ":JupynvimRunAll" Enter
  running || { fail_later "q3: cell 1 never showed [*] with a time"; return; }
  # the kernel is a child of the backend, and outlives a backend killed this
  # way: remember it, to stop it below (both were started by this test)
  kernels="$(pgrep -P "$pid" || true)"
  kill -9 "$pid"
  wait_pane '✗ [0-9]' 15 || { fail_later "q3: cell 1 never showed ✗ after the backend was killed"; }
  sleep 0.3
  cap a
  sleep 1.5
  cap b
  chk q3 "$WORK/idle.raw" "$WORK/a.raw" "$WORK/b.raw"
  # shellcheck disable=SC2086
  [ -n "$kernels" ] && kill $kernels 2>/dev/null
  return 0
}

case_4() {
  begin q4 || return
  k ":JupynvimRunAll" Enter
  running || { fail_later "q4: cell 1 never showed [*] with a time"; return; }
  k ":JupynvimRunAll" Enter
  # the first run printed three: cell 1's second run is on, 2 and 3 wait
  wait_pane '^[^A-Za-z0-9"]*three\s*$' 30 || { fail_later "q4: three was never printed"; return; }
  sleep 1
  cap mid
  # the second run of cell 1 printed one; then three again once it is over
  wait_pane '^[^A-Za-z0-9"]*one\s*$' 30 || { fail_later "q4: one was never printed by the second run"; return; }
  wait_pane '^[^A-Za-z0-9"]*three\s*$' 30 || { fail_later "q4: the second run never printed three"; return; }
  sleep 0.6
  cap done
  chk q4 "$WORK/mid.raw" "$WORK/done.raw"
}

case_5() {
  begin q5 || return
  local pid kernels
  pid="$(rec 'require("jupynvim").client.pid')"
  case "$pid" in ''|*[!0-9]*) fail_later "q5: the backend pid is '$pid'"; return;; esac
  kernels="$(pgrep -P "$pid" -f ipykernel || true)"
  [ -n "$kernels" ] || { fail_later "q5: the backend $pid has no kernel process"; return; }
  k ":JupynvimRunAll" Enter
  running || { fail_later "q5: cell 1 never showed [*] with a time"; return; }
  # the kernel only (it was started by this test's backend); the backend lives
  # shellcheck disable=SC2086
  kill -9 $kernels
  wait_pane '✗ [0-9]' 15 || { fail_later "q5: cell 1 never showed ✗ after the kernel was killed"; return; }
  sleep 0.3
  cap a
  pane_has 'kernel died' || fail_later "q5: the death of the kernel was not said"
  sleep 1.5
  cap b
  chk q5 "$WORK/idle.raw" "$WORK/a.raw" "$WORK/b.raw"
  kill -0 "$pid" 2>/dev/null || fail_later "q5: the backend went away with its kernel"
}

case_6() {
  begin q6 || return
  k ":JupynvimRunAll" Enter
  running || { fail_later "q6: cell 1 never showed [*] with a time"; return; }
  k ":JupynvimClearOutputs" Enter
  sleep 0.5
  cap a
  wait_pane '^[^A-Za-z0-9"]*three\s*$' 30 || { fail_later "q6: three was never printed"; return; }
  sleep 0.6
  cap done
  chk q6 "$WORK/idle.raw" "$WORK/a.raw" "$WORK/done.raw"
}

run_cases "$@"
finish "queued screen"

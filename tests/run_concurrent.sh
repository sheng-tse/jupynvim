#!/usr/bin/env bash
# The full suite (tests/run_all.sh) in N copies of this repo at the same time:
#
#   bash tests/run_concurrent.sh [N]          N copies, default 2
#
# Each copy is a fresh copy of the source tree, made in one new dir in the
# caller's temp dir; the build dir core/target is cloned into it (a clone
# costs no disk space where the file system can share blocks), so cargo
# starts warm. Every copy starts at the same moment, in a process group of
# its own (as a suite started on its own is), and makes its own run
# (tests/lib/test_env.sh), so a green result shows that suites running side
# by side never see or touch each other's files, tmux servers, kernels or
# processes. Two runs of one tree at once are not supported: lua_e2e changes
# the time stamp of its tree's cross-build artifact and cargo locks its
# tree's target dir.
#
# For each copy it prints
#
#   copy<i>: rc=<exit status> <wall seconds>s <the RESULTS line of its log>
#
# and every FAIL: line of that copy's summary. The exit status is 0 only when
# every copy exited 0. Then the dir of copies is removed (JNV_KEEP_RUN=1
# keeps it, and the runs inside keep theirs); otherwise it is kept and the
# logs are named.
#
# On INT, TERM or HUP each copy's suite and every process under it get TERM,
# by pid, so the suite stops at once instead of after the section it is in;
# each suite's own exit hook then stops what is left of its run and removes
# its run dir. A process that is still there 30 s later, or at a second
# signal, gets KILL; the suites themselves never do, so their hooks finish.
# This script waits for the suites (up to 120 s) before it exits.
#
# It runs outside the run env on purpose: each copy makes its own run.
# Bash 3.2 compatible.

set -u

usage() { echo "usage: bash tests/run_concurrent.sh [N]   (N copies, 1 or more; default 2)" >&2; exit 2; }
N="${1:-2}"
case "$N" in ''|*[!0-9]*) usage ;; esac
N=$((10#$N))
[ "$N" -ge 1 ] || usage

SRC="$(cd "$(dirname "$0")/.." && pwd)"
TMP_BASE="${TMPDIR:-$(dirname "$(mktemp -u)")}"
# The copies must live outside the tree they copy, or the copy would copy
# itself until the path is too long.
if python3 -I -c '
import os, sys
src, base = (os.path.realpath(p) for p in sys.argv[1:3])
sys.exit(0 if base == src or base.startswith(src.rstrip(os.sep) + os.sep) else 1)' "$SRC" "$TMP_BASE"; then
  echo "run_concurrent: the temp dir $TMP_BASE is inside $SRC; set TMPDIR to a dir outside it" >&2
  exit 2
fi
BASE="$(mktemp -d "${TMP_BASE%/}/jnv-conc.XXXXXX")" || {
  echo "run_concurrent: cannot make a dir in $TMP_BASE" >&2
  exit 2
}

# remove_base: the dir of copies, only when it is the one mktemp made here
remove_base() {
  case "$BASE" in /*/jnv-conc.?*) rm -rf "$BASE" ;; esac
}

# ── the copies ──────────────────────────────────────────
# copy_tree SRC DST: the source tree without the build dir core/target,
# without __pycache__ and node_modules anywhere, and without the top-level
# examples playground and hidden dirs other than .github (version control
# and local tool state, not part of the source).
copy_tree() {
  python3 -I -c '
import os, shutil, sys
src, dst = sys.argv[1], sys.argv[2]
core = os.path.join(src, "core")

def skip(d, names):
    out = {n for n in names if n in ("__pycache__", "node_modules")}
    if d == src:
        out |= {n for n in names if n == "examples"
                or (n.startswith(".") and n != ".github" and os.path.isdir(os.path.join(d, n)))}
    elif d == core and "target" in names:
        out.add("target")
    return out

shutil.copytree(src, dst, symlinks=True, ignore=skip)
' "$1" "$2"
}

# clone_dir SRC DST: DST becomes a copy of SRC, cloned where it can be
clone_dir() {
  case "${OSTYPE:-}" in
    darwin*) cp -cR "$1" "$2" 2>/dev/null || { rm -rf "$2"; cp -R "$1" "$2"; } ;;
    *) cp -R --reflink=auto "$1" "$2" ;;
  esac
}

# ── stopping the copies on a signal ─────────────────────
PIDS=()     # PIDS[i]: copy i's suite (run_all.sh), started as a background job
START=()    # START[i], END[i]: SECONDS when copy i started and when it ended
END=()
RC=()       # RC[i]: copy i's exit status
STARTED=0   # how many copies were started
SIGNALLED=""  # the first signal this script got (INT, TERM or HUP)
SIG_AT=0      # SECONDS when that signal came
KILLED=""     # set once the KILL step ran
TERMED=""     # "pid lstart" lines of the processes sent TERM

# proc_tree PID...: the PIDs and every process under them, one pid per line
proc_tree() {
  ps -A -o pid=,ppid= | awk -v roots="$*" '
    BEGIN { n = split(roots, r, " "); for (i = 1; i <= n; i++) want[r[i]] = 1 }
    { kids[$2] = kids[$2] " " $1; seen[$1] = 1 }
    END {
      n = 0
      for (p in want) if (p in seen) { q[++n] = p; got[p] = 1 }
      for (i = 1; i <= n; i++) {
        m = split(kids[q[i]], k, " ")
        for (j = 1; j <= m; j++) if (!(k[j] in got)) { got[k[j]] = 1; q[++n] = k[j] }
      }
      for (i = 1; i <= n; i++) print q[i]
    }'
}

# lstarts PID...: "pid lstart" for those still running (lstart is the start
# time, so a pid that was used again never matches)
lstarts() {
  [ "$#" -gt 0 ] || return 0
  LC_ALL=C ps -o pid=,lstart= -p "$(echo "$@" | tr ' ' ',')" 2>/dev/null \
    | awk '{ $1 = $1; print }'
}

# running_suites: the pids of the copies' suites still running
running_suites() {
  local i=1
  while [ "$i" -le "$STARTED" ]; do
    [ -z "${END[$i]:-}" ] && printf '%s\n' "${PIDS[$i]}"
    i=$((i + 1))
  done
}

# term_copies: TERM to every suite and every process under it, by pid
term_copies() {
  local roots pids
  roots="$(running_suites)"
  [ -n "$roots" ] || return 0
  # shellcheck disable=SC2086
  pids="$(proc_tree $roots)"
  [ -n "$pids" ] || return 0
  # shellcheck disable=SC2086
  TERMED="$(lstarts $pids)"
  # shellcheck disable=SC2086
  kill -TERM $pids 2>/dev/null
}

# kill_survivors: KILL each process sent TERM that is still the same process
# (the same pid and start time), except the suites themselves: their exit
# hooks clean up their runs
kill_survivors() {
  local roots same pids="" p
  KILLED=1
  [ -n "$TERMED" ] || return 0
  roots=" $(running_suites | tr '\n' ' ') "
  # shellcheck disable=SC2046
  same="$(printf '%s\n%s\n' "$TERMED" "$(lstarts $(printf '%s\n' "$TERMED" | awk '{ print $1 }'))" \
    | sort | uniq -d | awk '{ print $1 }')"
  for p in $same; do
    case "$roots" in *" $p "*) ;; *) pids="$pids $p" ;; esac
  done
  [ -n "$pids" ] || return 0
  echo "run_concurrent: still running after TERM, sent KILL:$pids" >&2
  # shellcheck disable=SC2086
  kill -KILL $pids 2>/dev/null
}

on_signal() {
  if [ -n "$SIGNALLED" ]; then
    # a second signal: do not wait any longer for what TERM did not stop
    [ -n "$KILLED" ] || kill_survivors
    return 0
  fi
  SIGNALLED="$1"
  SIG_AT=$SECONDS
  if [ "$STARTED" -eq 0 ]; then
    echo "run_concurrent: $1 while copying; removing $BASE" >&2
    remove_base
    case "$1" in INT) exit 130 ;; HUP) exit 129 ;; *) exit 143 ;; esac
  fi
  echo "run_concurrent: $1: stopping the copies (each suite's exit hook removes its run)" >&2
  term_copies
}
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM
trap 'on_signal HUP' HUP

# ── run ─────────────────────────────────────────────────
echo "run_concurrent: $N cop$([ "$N" -eq 1 ] && echo y || echo ies) of $SRC in $BASE"
i=1
while [ "$i" -le "$N" ]; do
  copy_tree "$SRC" "$BASE/copy$i" || { echo "run_concurrent: copying $SRC failed" >&2; remove_base; exit 2; }
  if [ -d "$SRC/core/target" ]; then
    clone_dir "$SRC/core/target" "$BASE/copy$i/core/target" \
      || { echo "run_concurrent: copying $SRC/core/target failed" >&2; remove_base; exit 2; }
  fi
  i=$((i + 1))
done

# Every copy starts now, each a suite of its own: the run variables are
# dropped so that each makes its own run even when this script was started
# from inside one, and each leads a process group of its own, as a suite
# started on its own does (an orphan one copy leaves in its group is then
# never taken for another copy's; the copies are stopped by pid).
i=1
while [ "$i" -le "$N" ] && [ -z "$SIGNALLED" ]; do
  ( cd "$BASE/copy$i" && exec env -u JNV_RUN_ENV_READY -u JNV_RUN_ROOT -u JNV_RUN_ID -u JNV_RUN_REPO \
      perl -e 'setpgrp(0, 0) or exit 126; exec @ARGV or exit 127' bash tests/run_all.sh ) \
    < /dev/null > "$BASE/copy$i.log" 2>&1 &
  PIDS[$i]=$!
  START[$i]=$SECONDS
  STARTED=$i
  i=$((i + 1))
done
echo "run_concurrent: started; logs: $BASE/copy<i>.log"

# Wait for every copy. A finished background job is reaped by bash at once,
# so kill -0 fails for it and wait returns its saved status.
left=$STARTED
while [ "$left" -gt 0 ]; do
  i=1
  while [ "$i" -le "$STARTED" ]; do
    if [ -z "${END[$i]:-}" ] && ! kill -0 "${PIDS[$i]}" 2>/dev/null; then
      wait "${PIDS[$i]}"
      RC[$i]=$?
      END[$i]=$SECONDS
      left=$((left - 1))
    fi
    i=$((i + 1))
  done
  [ "$left" -gt 0 ] || break
  if [ -n "$SIGNALLED" ]; then
    if [ -z "$KILLED" ] && [ $((SECONDS - SIG_AT)) -ge 30 ]; then
      kill_survivors
    fi
    if [ $((SECONDS - SIG_AT)) -ge 120 ]; then
      echo "run_concurrent: still running 120 s after $SIGNALLED, not waiting any longer:$(running_suites | tr '\n' ' ')" >&2
      break
    fi
  fi
  sleep 1
done

# ── report ──────────────────────────────────────────────
ok=1
i=1
while [ "$i" -le "$STARTED" ]; do
  log="$BASE/copy$i.log"
  # run_all's own summary is the last RESULTS: line (a test may print one)
  res="$(grep 'RESULTS:' "$log" 2>/dev/null | tail -n 1 | sed 's/^[[:space:]]*//')"
  if [ -n "${END[$i]:-}" ]; then
    echo "copy$i: rc=${RC[$i]} $((END[i] - START[i]))s ${res:-(no RESULTS line)}"
    [ "${RC[$i]}" -eq 0 ] || ok=0
  else
    echo "copy$i: still running (pid ${PIDS[$i]}) ${res:-(no RESULTS line)}"
    ok=0
  fi
  # the FAIL: lines of that last summary only
  awk '/RESULTS:/ { n = 0; s = 1; next }
       s && /^[[:space:]]*FAIL: / { sub(/^[[:space:]]*/, "  "); f[++n] = $0 }
       END { for (j = 1; j <= n; j++) print f[j] }' "$log" 2>/dev/null
  i=$((i + 1))
done

if [ -n "$SIGNALLED" ]; then
  echo "run_concurrent: stopped by $SIGNALLED; copies and logs kept in $BASE"
  case "$SIGNALLED" in INT) exit 130 ;; HUP) exit 129 ;; *) exit 143 ;; esac
fi
if [ "$ok" -eq 1 ]; then
  if [ "${JNV_KEEP_RUN:-}" = 1 ]; then
    echo "run_concurrent: every copy passed; kept $BASE"
  else
    remove_base
    echo "run_concurrent: every copy passed"
  fi
  exit 0
fi
echo "run_concurrent: not every copy passed; copies kept in $BASE, logs:"
i=1
while [ "$i" -le "$STARTED" ]; do
  echo "  $BASE/copy$i.log"
  i=$((i + 1))
done
exit 1

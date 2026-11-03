#!/usr/bin/env bash
# Runtime isolation spec. Every run of the suite lives in a run dir of its
# own (tests/lib/test_env.sh), runs tmux on a private server
# (tests/lib/tmux.sh) and only ever signals processes it provably started
# (tests/lib/run_procs.py). Two suites at once must never share a path, a
# tmux server or a process, and neither may touch the user's own state.
#
#   bash tests/isolation_spec.sh
#
# S1 environment, S2 unique and removed run dirs and the exit hooks, S3 nvim,
# S4 tmux, S5 processes, S6 backend and kernel (tests/isolation_spec.py).
#
# S5 runs right after S1. Each fresh run in S2 owns its run dir and calls
# `run_procs.py cleanup` (scan --kill) when it exits, and jnv_tmux_stop in S4
# stops what `run_procs.py snapshot` lists. A finder that lists processes this
# run did not start would signal them, so it has to be caught before anything
# acts on what it finds: S5 checks that scan refuses a run dir test_env.sh did
# not make, and never takes a process that was running before the run dir
# was made or a parent of its own; that snapshot never starts from pid 1,
# this script's parent or an orphan outside the run; and, with one fresh run
# (whose exit stops what its finder takes, so it comes last), that a process
# someone else started that refers to a run is neither listed, snapshotted,
# reaped nor stopped by it, also when its parent is pid 1 (a holder of a
# run file in a session of its own, a tmux server started in the run dir, a
# `(cmd &)` job, a tail left by a shell that exited), while what the run
# started is: a double-forked process, a tmux server and its pane after
# their script was KILLed, an orphan in that pane's session. Scan also lists
# a session leader whose command line names a backend dir under the run's
# runtime dir (a kernel or the backend's guard), and neither one that names
# only the run dir nor a process that names such a dir but leads no
# session. When S5 cannot show that scan and snapshot are selective, S2
# and S4 fail without running, and this script leaves without running its
# exit hooks, because the hook of the shell that owns a run dir runs scan
# --kill as well.
#
# S2 also checks the exit hooks and signals (HUP like TERM), that a caller's
# Python and matplotlib settings and JUPYNVIM_RUNTIME_DIR stay out of a run
# and an interactive python's history stays in it, that a run's owner
# removes the tmux socket a killed script left, and that the next run sweeps
# a run whose owner was killed (and nothing else): while a section of that
# run still runs it leaves the dir, a later sweep removes it once (owner
# file last), and a kept run is never swept, killed or not. S4 also checks
# that tmux run around the wrapper finds no server outside the run, that a
# subshell gets a tmux server of its own, and that the screen tests'
# barriers (nv_sync, jnv_wait_nvim_exit) wait for nvim.
set -u
# The run this script was given, if any. When sourcing below makes a new run
# instead, this script owns that run dir.
iso_inherited_root="${JNV_RUN_ROOT:-}"
source "$(dirname "$0")/lib/test_env.sh" || {
  echo "FAIL test env: tests/lib/test_env.sh could not be sourced"
  echo
  echo "1 ISOLATION CHECKS FAILED"
  exit 1
}

FAILS=0
# chk NAME CMD...: run CMD, print "  ok NAME" or "FAIL NAME", count failures;
# returns CMD's verdict so a caller can act on it
chk() {
  local name="$1"; shift
  if "$@"; then echo "  ok $name"; return 0; fi
  echo "FAIL $name"; FAILS=$((FAILS + 1)); return 1
}
not() { ! "$@"; }
# is_under PATH BASE: PATH is BASE or inside it, both resolved
is_under() {
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 1
  python3 -I -c '
import os, sys
p, b = (os.path.realpath(a) for a in sys.argv[1:3])
sys.exit(0 if p == b or p.startswith(b.rstrip(os.sep) + os.sep) else 1)' "$1" "$2"
}
is_dir_under() { [ -n "${1:-}" ] && [ -d "$1" ] && is_under "$1" "$2"; }
mode_is() {
  [ -e "${2:-}" ] && python3 -I -c '
import os, stat, sys
sys.exit(0 if "%o" % stat.S_IMODE(os.stat(sys.argv[2]).st_mode) == sys.argv[1] else 1)' "$1" "$2"
}
gone() { [ -n "${1:-}" ] && [ ! -e "$1" ]; }
# poll_for SECS CMD...: CMD every 0.1 s until it succeeds; 1 on timeout
poll_for() {
  local n=0 max=$(( $1 * 10 )); shift
  until "$@"; do
    n=$((n + 1)); [ "$n" -ge "$max" ] && return 1
    sleep 0.1
  done
}
# deadline SECS CMD...: CMD with its exit status, or 142 when it is still
# running after SECS seconds; then CMD and every process it started are
# stopped, by pid, so a child that hangs fails its check instead of stalling
# the spec or leaving a grandchild behind that holds its output open. INT,
# TERM and HUP are passed on to CMD.
deadline() {
  python3 -I -c '
import os, signal, subprocess, sys
try:
    p = subprocess.Popen(sys.argv[2:])
except OSError as e:
    print("deadline: %s: %s" % (sys.argv[2], e), file=sys.stderr)
    sys.exit(127)
for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(s, lambda n, f: p.send_signal(n))
try:
    rc = p.wait(timeout=float(sys.argv[1]))
except subprocess.TimeoutExpired:
    rows = [r.split() for r in subprocess.run(["ps", "-A", "-o", "pid=,ppid="],
            capture_output=True, text=True).stdout.splitlines()]
    tree, todo = [], [p.pid]
    while todo:
        q = todo.pop()
        tree.append(q)
        todo += [int(a) for a, b in rows if int(b) == q and int(a) not in tree]
    for q in tree:
        try:
            os.kill(q, signal.SIGKILL)
        except OSError:
            pass
    p.wait()
    print("deadline: stopped after %ss: %s" % (sys.argv[1], " ".join(sys.argv[2:])),
          file=sys.stderr)
    sys.exit(142)
sys.exit(rc if rc >= 0 else 128 - rc)' "$@"
}

R="${JNV_RUN_ROOT:-}"
REPO="${JNV_REPO:-}"
PROCS="$REPO/tests/lib/run_procs.py"

# Background processes this script started are stopped on any exit, by pid.
# The exit hooks run in a subshell, where `jobs` lists nothing, so iso_bg
# records each pid as it starts, and only a pid that is still a child of this
# shell is signalled: one that ended and was waited for may be someone
# else's by now.
ISO_BG=""
iso_bg() { ISO_BG="$ISO_BG $1"; }
_iso_cleanup() {
  local kids p
  kids=" $(ps -A -o pid=,ppid= | awk -v me="$$" '$2 == me { printf "%s ", $1 }')"
  for p in $ISO_BG; do
    case "$kids" in *" $p "*) kill -9 "$p" 2>/dev/null ;; esac
  done
  return 0
}
jnv_on_exit _iso_cleanup

# Until S5 shows that scan lists only this run's processes, every way out of
# this script skips the exit hooks: an owner's hook runs scan --kill. After
# that, iso_exit is a plain exit and the hooks run as usual.
scan_safe=0
snap_safe=0
iso_exit() {
  [ "$scan_safe" = 1 ] && exit "$1"
  _iso_cleanup
  # The run dir is removed here only when this script made it, and only when
  # it is an absolute path whose last part is a run dir name.
  if [ -n "$R" ] && [ "$R" != "$iso_inherited_root" ] && [ -d "$R" ]; then
    case "$R" in
      /*) case "${R##*/}" in jnv.?*) rm -rf "$R" && echo "run dir removed here: $R" ;; esac ;;
    esac
  fi
  echo "exit hooks skipped: they run run_procs.py scan --kill, and S5 did not show that scan is selective"
  exec /bin/sh -c 'exit "$1"' sh "$1"
}
trap 'iso_exit 130' INT
trap 'iso_exit 143' TERM
trap 'iso_exit 129' HUP

# ── S1 environment ──────────────────────────────────────
echo "S1 environment"
run_root_ok() { [ -n "$R" ] && [ -d "$R" ]; }
chk "the run dir exists ($R)" run_root_ok
for v in TMPDIR XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME XDG_RUNTIME_DIR \
         JUPYTER_CONFIG_DIR JUPYTER_DATA_DIR JUPYTER_RUNTIME_DIR JUPYTER_PATH IPYTHONDIR \
         MPLCONFIGDIR JUPYNVIM_LOG_DIR; do
  chk "$v is a dir under the run dir" is_dir_under "${!v:-}" "$R"
done
outside_repo() { [ -n "$R" ] && [ -n "$REPO" ] && ! is_under "$R" "$REPO"; }
chk "the run dir is outside the repo" outside_repo
xrd="${XDG_RUNTIME_DIR:-}"
xrd_short() { [ -n "$xrd" ] && [ "${#xrd}" -le 80 ]; }
chk "XDG_RUNTIME_DIR is at most 80 characters (${#xrd})" xrd_short
chk "XDG_RUNTIME_DIR has mode 700" mode_is 700 "$xrd"
chk "SHELL is /bin/sh" test "${SHELL:-}" = /bin/sh
chk "TERM is xterm-256color" test "${TERM:-}" = xterm-256color
chk "KITTY_WINDOW_ID is 1" test "${KITTY_WINDOW_ID:-}" = 1
# An interactive sh saves its history when it exits, by default into HOME;
# the panes and :terminal run one, so the history file must be the run's.
hist_ok() { [ "${1:-}" = /dev/null ] || is_under "${1:-}" "$R"; }
chk "HISTFILE is /dev/null or under the run dir (${HISTFILE:-unset})" hist_ok "${HISTFILE:-}"
# An interactive python saves its history when it exits, by default into
# HOME; Python 3.13 and later save it to PYTHON_HISTORY instead.
chk "PYTHON_HISTORY is under the run dir (${PYTHON_HISTORY:-unset})" is_under "${PYTHON_HISTORY:-}" "$R"
# tmux run without -L or -S (around tests/lib/tmux.sh) looks for its default
# server in TMUX_TMPDIR: in the run, never the user's server.
chk "TMUX_TMPDIR is the run dir or under it (${TMUX_TMPDIR:-unset})" is_under "${TMUX_TMPDIR:-}" "$R"
# The run's owner (the shell that made the run dir): its pid and start in
# owner, its process group in owner.info (run_procs.py: rule 3).
iso_owner_pid="$(cut -f 1 "$R/owner" 2>/dev/null)"
owner_ok() {
  local line; IFS= read -r line < "$R/owner" 2>/dev/null || return 1
  [ -n "$iso_owner_pid" ] && [ "$(jnv_proc_ident "$iso_owner_pid")" = "${line#*$'\t'}" ]
}
chk "the owner file names a running process by its pid and start ($iso_owner_pid)" owner_ok
group_ok() {
  [ -n "$iso_owner_pid" ] && [ "$(sed -n 's/^pgid=//p' "$R/owner.info" 2>/dev/null)" \
    = "$(ps -o pgid= -p "$iso_owner_pid" 2>/dev/null | tr -d ' ')" ]
}
chk "owner.info holds the owner's process group" group_ok
case "${OSTYPE:-}" in
  linux*)
    # the start in clock ticks since boot (field 22), which a step of the
    # wall clock does not move, and the ticks of the run dir's making
    ticks_ok() {
      [ "$(cut -f 2 "$R/owner")" = "$(awk '{ sub(/.*\) /, ""); print $20 }' "/proc/$iso_owner_pid/stat")" ] \
        && grep -q '^born=[0-9][0-9]*$' "$R/owner.info"
    }
    chk "on Linux the owner's start is its start in ticks since boot, and owner.info has the run's" ticks_ok
    ;;
esac
for v in GHOSTTY_RESOURCES_DIR TMUX TERM_PROGRAM; do
  chk "$v is empty" test -z "${!v:-}"
done
# The caller's Python and matplotlib settings stay out of the run (and so
# out of every kernel): see tests/lib/test_env.sh. S2 plants them in a fresh
# run's caller.
ISO_PY_VARS="PYTHONSTARTUP PYTHONPATH PYTHONHOME PYTHONSAFEPATH PYTHONINSPECT PYTHONOPTIMIZE
  PYTHONWARNINGS PYTHONVERBOSE PYTHONDEBUG PYTHONDEVMODE PYTHONBREAKPOINT PYTHONPYCACHEPREFIX
  PYTHONEXECUTABLE PYTHONIOENCODING PYTHONUTF8 MPLBACKEND MATPLOTLIBRC JUPYTER_CONFIG_PATH
  JUPYTER_PREFER_ENV_PATH JUPYTER_PLATFORM_DIRS"
is_unset() { [ -z "${!1+set}" ]; }
for v in $ISO_PY_VARS; do
  chk "$v is unset" is_unset "$v"
done
# The caller's choice of in-process library and release mirror stays out of
# the run: every run loads the repo's own library and never downloads.
for v in JUPYNVIM_NATIVE JUPYNVIM_RELEASE_BASE; do
  chk "$v is unset" is_unset "$v"
done
# A caller's JUPYNVIM_RUNTIME_DIR would move the run's kernel connection
# files out of the run dir. S2 plants one in a fresh run's caller.
chk "JUPYNVIM_RUNTIME_DIR is unset" is_unset JUPYNVIM_RUNTIME_DIR
has_spec() { [ -n "${JUPYTER_PATH:-}" ] && [ -f "$JUPYTER_PATH/kernels/python3/kernel.json" ]; }
chk "the run has its own python3 kernelspec" has_spec
kernel_has_ipykernel() {
  [ -n "${JNV_KERNEL_PYTHON:-}" ] && "$JNV_KERNEL_PYTHON" -c 'import ipykernel' >/dev/null 2>&1
}
chk "the kernel python imports ipykernel (${JNV_KERNEL_PYTHON:-unset})" kernel_has_ipykernel
# A kernel with matplotlib finds a font cache in the run: copied from the
# caller's, or built once while the run was made. Without one, the first plot
# of every test would build it (seconds, past what a test waits for).
kernel_has_mpl() {
  [ -n "${JNV_KERNEL_PYTHON:-}" ] && (cd / && "$JNV_KERNEL_PYTHON" -c \
    'import importlib.util,sys; sys.exit(importlib.util.find_spec("matplotlib") is None)') >/dev/null 2>&1
}
mpl_cached() {
  local f
  [ -n "${MPLCONFIGDIR:-}" ] || return 1
  for f in "$MPLCONFIGDIR"/fontlist-v*.json; do [ -f "$f" ] && return 0; done
  return 1
}
if kernel_has_mpl; then
  chk "MPLCONFIGDIR holds a matplotlib font cache (fontlist-v*.json)" mpl_cached
else
  echo "  -- matplotlib: the kernel python has none"
fi

# ── S5 processes (before S2 and S4, which act on what it finds) ──
echo "S5 processes"
procs() { deadline 60 python3 -I "$PROCS" "$@"; }
# wait_cmd PID TEXT: until the pid's command line contains TEXT, up to 5 s
wait_cmd() {
  local n=0
  while [ "$n" -lt 50 ]; do
    case "$(ps -ww -o command= -p "$1" 2>/dev/null)" in *"$2"*) return 0 ;; esac
    sleep 0.1; n=$((n + 1))
  done
  return 1
}
# stopped PID: no such process, or only its exit status is left
stopped() {
  local st; st="$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ')"
  [ -z "$st" ] || [ "${st#Z}" != "$st" ]
}
# pids_of TEXT: the first field of each line of TEXT that is a pid
pids_of() { printf '%s\n' "$1" | awk -F '\t' '$1 ~ /^[0-9]+$/ { print $1 }'; }
# pids_within TEXT PID...: every pid TEXT lists is one of PID...
pids_within() {
  local text="$1" p; shift
  for p in $(pids_of "$text"); do
    case " $* " in *" $p "*) ;; *) return 1 ;; esac
  done
  return 0
}
# same_pids TEXT PID...: TEXT lists exactly PID..., each once
same_pids() {
  local text="$1"; shift
  [ "$(pids_of "$text" | sort -n | tr '\n' ' ')" = "$(printf '%s\n' "$@" | sort -n | tr '\n' ' ')" ]
}
# in_list TEXT PID: TEXT lists PID
in_list() { [ -n "${2:-}" ] && pids_of "$1" | grep -qx "$2"; }
# ran_for PID SECS: ps says PID has been running for at least SECS seconds
ran_for() {
  local s
  s="$(ps -o etime= -p "$1" 2>/dev/null | awk '{ n = split($1, a, /[-:]/)
    m[1] = 1; m[2] = 60; m[3] = 3600; m[4] = 86400
    for (i = 1; i <= n; i++) t += a[n - i + 1] * m[i]; print t }')"
  [ -n "$s" ] && [ "$s" -ge "$2" ]
}
# procs_in ROOT ARGS...: run_procs.py for the run dir ROOT, with the
# JNV_RUN_ID of its name, and a deadline
procs_in() {
  local root="$1"; shift
  deadline 60 env JNV_RUN_ROOT="$root" JNV_RUN_ID="${root##*/jnv.}" python3 -I "$PROCS" "$@"
}
# fresh_run SCRIPT ARGS...: a fresh run, as a suite started from scratch
# would make: none of the variables that let a child reuse this run. Each
# gets a deadline. SCRIPT runs in the bash running this spec, and sees the
# repo as $1 and ARGS from $2. With iso_signals=1, INT, TERM and HUP start
# with their default actions, as in a script started from a terminal,
# whatever started this spec: a background job starts with INT ignored,
# and a shell cannot trap a signal that was ignored when it started. The
# run's shell leads a process group of its own, as a suite started from an
# interactive shell or by an agent's command does: what this script starts
# is not in its group (and what another suite started by the same command
# as this one leaves is not either). A fresh run's shell owns its run, and
# its exit hook runs run_procs.py cleanup (scan --kill), so it is used only
# once S5 has shown scan is selective.
iso_signals=""
fresh_run() {
  local script="$1"; shift
  set -- perl -e 'my $sig = shift;
      if ($sig) { $SIG{$_} = "DEFAULT" for qw(INT TERM HUP) }
      setpgrp(0, 0) or exit 126;
      exec @ARGV or exit 127' "$iso_signals" "${BASH:-bash}" -c "$script" _ "$REPO" "$@"
  deadline 120 env -u JNV_RUN_ENV_READY -u JNV_RUN_ROOT -u JNV_RUN_ID -u JNV_RUN_REPO "$@"
}
# cmd_has PID TEXT: PID runs and its command line contains TEXT (so a pid
# that was used again by another process is never signalled)
cmd_has() { case "$(ps -ww -o command= -p "$1" 2>/dev/null)" in *"$2"*) return 0 ;; esac; return 1; }
# stop_own PID TEXT: KILL PID, a process this script started that is not its
# child, only while its command line still contains TEXT
stop_own() { [ -n "${1:-}" ] && cmd_has "$1" "$2" && kill -9 "$1" 2>/dev/null; return 0; }
# started_since_root PID...: every listed pid that still runs started after
# the run dir was created; prints the ones that did not. The start is the
# current time, read after ps returns, minus ps etime (elapsed, so no locale,
# time zone or DST takes part). etime is whole seconds, and macOS counts it
# from the second the process started in, so that estimate can be up to one
# second earlier than the real start, never more: a pid counts as older only
# when its estimate is at least one second before the run dir's birth, which
# a process started after the birth can never reach. The birth time comes
# from stat; where the file system keeps none, the earliest time stamp on the
# run dir and its entries stands in (never earlier than the birth).
started_since_root() {
  python3 -I -c '
import os, subprocess, sys, time
root, want = sys.argv[1], set(sys.argv[2:])
st = os.stat(root)
born = getattr(st, "st_birthtime", 0) or 0
if not born:
    try:
        out = subprocess.run(["stat", "-c", "%W", root], capture_output=True, text=True).stdout.strip()
        born = float(out) if out.isdigit() else 0
    except OSError:
        born = 0
if not born:
    stamps = [st.st_mtime, st.st_ctime]
    for e in os.scandir(root):
        s = e.stat(follow_symlinks=False)
        stamps += [s.st_mtime, s.st_ctime]
    born = min(stamps)
rows = subprocess.run(["ps", "-A", "-ww", "-o", "pid=,etime=,command="],
                      capture_output=True, text=True).stdout.splitlines()
now = time.time()

def secs(et):
    days, _, hms = et.rpartition("-")
    parts = [int(x) for x in hms.split(":")]
    while len(parts) < 3:
        parts.insert(0, 0)
    return int(days or 0) * 86400 + parts[0] * 3600 + parts[1] * 60 + parts[2]

bad = []
for row in rows:
    f = row.split(None, 2)
    if len(f) < 2 or f[0] not in want:
        continue
    try:
        start = now - secs(f[1])
    except ValueError:
        continue
    if start <= born - 1:
        bad.append("%s started %ds before the run dir: %s"
                   % (f[0], born - start, (f[2] if len(f) > 2 else "")[:120]))
for b in bad[:10]:
    print("    " + b)
if len(bad) > 10:
    print("    ... and %d more" % (len(bad) - 10))
sys.exit(1 if bad else 0)' "$R" "$@"
}

# The old process. It starts now, and once the fresh run dir further down
# exists it moves into that dir: its working dir then ties it to a run dir
# made after it started, which never makes it that run's. Its command line
# names this run, so this run's exit hook stops it if the spec is cut short.
(cd / && exec perl -e '
  my $go = shift; my $n = 0;
  until (-s $go) { exit 1 if ++$n > 3000; select(undef, undef, undef, 0.1) }
  open(my $f, "<", $go) or exit 1; chomp(my $d = <$f>); close $f;
  chdir $d or exit 1;
  open(my $r, ">", "$go.ready") or exit 1; close $r;
  sleep 300' "$R/iso-old-go" </dev/null >/dev/null 2>&1) &
old=$!; iso_bg "$old"

# Both run from / with no files open, so nothing but the marker in the
# command line ties either one to the run dir.
(cd / && exec perl -e 'sleep 300' "$R/iso-marker" </dev/null >/dev/null 2>&1) &
marked=$!; iso_bg "$marked"
(cd / && exec perl -e 'sleep 300' </dev/null >/dev/null 2>&1) &
unmarked=$!; iso_bg "$unmarked"
chk "the marked process started" wait_cmd "$marked" "$R/iso-marker"
chk "the unmarked process started" wait_cmd "$unmarked" perl
scan_out="$(procs scan 2>&1)"; scan_rc=$?
scan_pids="$(pids_of "$scan_out")"
listed() { printf '%s\n' "$scan_pids" | grep -qx "$1"; }
# The checks that show scan is selective. The list may hold other processes
# of this run, so its length is not checked. A scan that lists nothing is no
# proof that it would list only this run's processes, so the marked process
# must be in it too.
scan_ok=1
chk "scan exits 1 when it finds run processes (rc $scan_rc)" test "$scan_rc" = 1
chk "scan lists the marked process" listed "$marked" || scan_ok=0
chk "scan does not list an unmarked process" not listed "$unmarked" || scan_ok=0
# shellcheck disable=SC2086
chk "every process scan lists started after the run dir was created" \
  started_since_root $scan_pids || scan_ok=0
kill "$marked" "$unmarked" 2>/dev/null
wait "$marked" 2>/dev/null; wait "$unmarked" 2>/dev/null

# A run dir test_env.sh did not make is refused before anything is matched
# (rc 2). List mode only: a finder that took one of these would match
# processes outside any run.
mkdir -p "$R/tmp/iso-notrun" "$R/tmp/jnv.isodir"
ln -s iso-notrun "$R/tmp/jnv.isolink" 2>/dev/null
# scan_from DIR ENV...: scan (list mode) run from DIR, the run variables
# replaced by ENV; its exit status
scan_from() {
  local dir="$1"; shift
  ( cd "$dir" && deadline 60 env -u JNV_RUN_ROOT -u JNV_RUN_ID "$@" python3 -I "$PROCS" scan >/dev/null 2>&1 )
}
refused() { scan_from "$@"; [ "$?" = 2 ]; }
taken() { scan_from "$@"; [ "$?" = 0 ]; }
chk "scan refuses to run with JNV_RUN_ROOT unset (rc 2)" refused / || scan_ok=0
chk "scan refuses a relative run dir (rc 2)" \
  refused "$R/tmp" JNV_RUN_ROOT=jnv.isodir || scan_ok=0
chk "scan refuses / as the run dir (rc 2)" refused / JNV_RUN_ROOT=/ || scan_ok=0
chk "scan refuses a dir whose name does not start with jnv. (rc 2)" \
  refused / JNV_RUN_ROOT="$R/tmp/iso-notrun" || scan_ok=0
chk "scan refuses a jnv. link to a dir that is not a run dir (rc 2)" \
  refused / JNV_RUN_ROOT="$R/tmp/jnv.isolink" || scan_ok=0
chk "scan refuses a run dir that does not exist (rc 2)" \
  refused / JNV_RUN_ROOT="$R/tmp/jnv.isomissing" || scan_ok=0
chk "scan refuses a JNV_RUN_ID that does not match the run dir (rc 2)" \
  refused / JNV_RUN_ROOT="$R/tmp/jnv.isodir" JNV_RUN_ID=isoother || scan_ok=0
chk "scan takes that dir with its own JNV_RUN_ID (rc 0)" \
  taken / JNV_RUN_ROOT="$R/tmp/jnv.isodir" JNV_RUN_ID=isodir

# snapshot: a process without children, and one with a child. Each must list
# exactly its own tree; listing anything else is what makes it unsafe. The
# child is not a job of this shell, so the exit cleanup never sees it: it ends
# itself within a second of its parent, however the parent goes.
(cd / && exec perl -e 'sleep 300' </dev/null >/dev/null 2>&1) &
leaf=$!; iso_bg "$leaf"
(cd / && exec perl -e 'my $pp = $$; my $c = fork(); exit 1 unless defined $c;
  if ($c == 0) { sleep 1 while getppid() == $pp; exit 0 } waitpid($c, 0)' \
  </dev/null >/dev/null 2>&1) &
parent=$!; iso_bg "$parent"
child=""
find_child() {
  child="$(ps -A -o pid=,ppid= | awk -v p="$parent" '$2 == p { print $1; exit }')"
  [ -n "$child" ]
}
chk "the childless process started" wait_cmd "$leaf" perl
snap_ok=1
snap_leaf="$(procs snapshot "$leaf" 2>/dev/null)"
pids_within "$snap_leaf" "$leaf" || snap_ok=0
chk "snapshot of a childless process lists only that process" same_pids "$snap_leaf" "$leaf"
if chk "the parent process started its child" poll_for 5 find_child; then
  snap_tree="$(procs snapshot "$parent" 2>/dev/null)"
  pids_within "$snap_tree" "$parent" "$child" || snap_ok=0
  chk "snapshot of a process with one child lists exactly those two" \
    same_pids "$snap_tree" "$parent" "$child"
else
  snap_ok=0
fi
[ -n "$child" ] && kill "$child" 2>/dev/null
kill "$parent" 2>/dev/null
wait "$parent" 2>/dev/null

# reap, fed only a snapshot already shown to hold exactly the childless one
if same_pids "$snap_leaf" "$leaf"; then
  printf '%s\n' "$snap_leaf" \
    | JNV_LEAKS_FILE="$R/iso_leaks" deadline 60 python3 -I "$PROCS" reap --timeout 1 --label iso \
        >/dev/null 2>&1
  reap_rc=$?
  chk "reap exits 1 when a process outlives its timeout (rc $reap_rc)" test "$reap_rc" = 1
  chk "reap stops that process" stopped "$leaf"
  leak_named() {
    awk -F '\t' -v p="$leaf" '$1 == "iso" && $2 == p { f = 1 } END { exit !f }' "$R/iso_leaks" 2>/dev/null
  }
  chk "the leaks file names that process" leak_named
else
  echo "FAIL reap not run: the snapshot it would be fed does not hold exactly the childless process"
  FAILS=$((FAILS + 1))
fi
stopped "$leaf" || kill -9 "$leaf" 2>/dev/null
wait "$leaf" 2>/dev/null

# snapshot starts only from a process the run started: never from pid 1, from
# this script's parent (an ancestor of the checker, or older than the run), or
# from a process that started after the run dir but not in the run: here an
# orphan that someone else started (double-forked from / into a session of
# its own, as a GUI app or a daemon is, so its parent is pid 1 and it is in
# neither the run's process group nor a session of the run; its paths and no
# JNV_RUN_ROOT come in its environment). Each would hand reap processes to
# stop.
chk "snapshot 1 lists nothing" test -z "$(procs snapshot 1 2>/dev/null)" || snap_ok=0
chk "snapshot of this script's parent ($PPID) lists nothing" \
  test -z "$(procs snapshot "$PPID" 2>/dev/null)" || snap_ok=0
env -u JNV_RUN_ROOT ISO_OPID="$R/iso-orphan.pid" ISO_OSTOP="$R/iso-orphan.stop" perl -MPOSIX -e '
  defined(my $a = fork()) or exit 1; if ($a) { waitpid($a, 0); exit 0 }
  POSIX::setsid() or exit 1;
  defined(my $b = fork()) or exit 1; if ($b) { exit 0 }
  chdir "/"; open(my $f, ">", "$ENV{ISO_OPID}.part") or exit 1; print $f "$$\n"; close $f;
  rename("$ENV{ISO_OPID}.part", $ENV{ISO_OPID});
  my $n = 0; until (-e $ENV{ISO_OSTOP} or ++$n > 1200) { select(undef, undef, undef, 0.1) }' \
  </dev/null >/dev/null 2>&1
orphan=""
poll_for 5 test -s "$R/iso-orphan.pid" && orphan="$(cat "$R/iso-orphan.pid")"
# orphaned PID: PID runs and its parent is pid 1 or a subreaper, not this
# script (its parent in between has exited)
orphaned() {
  local pp; pp="$(ps -o ppid= -p "${1:-}" 2>/dev/null | tr -d ' ')"
  [ -n "$pp" ] && [ "$pp" != "$$" ]
}
if chk "an orphan someone else started is running (no longer this script's child)" \
  orphaned "$orphan"; then
  chk "snapshot of that orphan lists nothing" \
    test -z "$(procs snapshot "$orphan" 2>/dev/null)" || snap_ok=0
else
  snap_ok=0
fi
: > "$R/iso-orphan.stop"  # it ends by itself within 0.1 s

# A kernel the backend starts leads a session of its own, and so does the
# backend's guard. Once the backend is gone their parent is pid 1, they are
# in no group or session of the run, and on macOS their environment cannot
# be read: what ties them to the run is their command line, which names a
# backend dir under the run's runtime dir (core-<token>-<pid>-<12 hex>): the
# kernel's connection file in it, or, for the guard, the dir itself. So scan
# lists such a session leader, and neither one that names only the run dir
# nor a process that names a backend dir but leads no session (an orphan of
# a session whose leader is gone, as any process someone else started can
# be). Each one forks, its parent exits at once, and the child calls setsid
# (the last one then forks again, and the child in between exits), writes
# its pid file through a rename and ends itself once the stop file exists
# (or after 120 s).
ISO_RT_PL='defined(my $c = fork()) or exit 1; exit 0 if $c;
  POSIX::setsid() or exit 1;
  if ($ENV{ISO_KTWICE}) { defined(my $d = fork()) or exit 1; exit 0 if $d }
  chdir "/"; open(my $f, ">", "$ENV{ISO_KPID}.part") or exit 1; print $f "$$\n"; close $f;
  rename("$ENV{ISO_KPID}.part", $ENV{ISO_KPID});
  my $n = 0; until (-e $ENV{ISO_KSTOP} or ++$n > 1200) { select(undef, undef, undef, 0.1) }'
rt_arg_k="$XDG_RUNTIME_DIR/jupynvim/core-isotoken-1-000000000000/kernel-00000000000000000000000000000000/connection.json"
rt_arg_g="$XDG_RUNTIME_DIR/jupynvim/core-isotoken-2-000000000000"
rt_arg_o="$R/iso-runtime-other/connection.json"
rt_arg_n="$XDG_RUNTIME_DIR/jupynvim/core-isotoken-3-000000000000/kernel-00000000000000000000000000000000/connection.json"
# rt_leader NAME ARG [twice]: start one with ARG as its argument (with
# twice, one that leads no session); prints its pid
rt_leader() {
  env -u JNV_RUN_ROOT ISO_KPID="$R/iso-rt-$1.pid" ISO_KSTOP="$R/iso-rt.stop" ISO_KTWICE="${3:-}" \
    perl -MPOSIX -e "$ISO_RT_PL" "$2" </dev/null >/dev/null 2>&1
  poll_for 5 test -s "$R/iso-rt-$1.pid" && cat "$R/iso-rt-$1.pid"
}
pid_k="$(rt_leader k "$rt_arg_k")"
pid_g="$(rt_leader g "$rt_arg_g")"
pid_o="$(rt_leader o "$rt_arg_o")"
pid_n="$(rt_leader n "$rt_arg_n" twice)"
# leads_session PID: PID runs and is the leader of its session
leads_session() {
  [ -n "${1:-}" ] && python3 -I -c '
import os, sys
p = int(sys.argv[1])
try:
    sys.exit(0 if os.getsid(p) == p else 1)
except OSError:
    sys.exit(1)' "$1"
}
# rt_ready: the first three run and lead their sessions, the last one runs
# and does not, and none is this script's child
rt_ready() {
  local p
  for p in "$pid_k" "$pid_g" "$pid_o"; do
    orphaned "$p" && leads_session "$p" || return 1
  done
  orphaned "$pid_n" && ! leads_session "$pid_n"
}
# not_in_list TEXT PID: TEXT does not list PID
not_in_list() { ! in_list "$@"; }
if chk "four processes that name paths in the run dir run, three of them as session leaders" \
  rt_ready; then
  scan_rt="$(procs scan 2>/dev/null)"
  chk "scan lists a session leader that names a backend dir of the run's runtime dir" \
    in_list "$scan_rt" "$pid_k"
  chk "scan lists a session leader whose argument is a backend dir" in_list "$scan_rt" "$pid_g"
  chk "scan does not list a session leader that names only the run dir" \
    not_in_list "$scan_rt" "$pid_o" || scan_ok=0
  chk "scan does not list a process that names a backend dir but leads no session" \
    not_in_list "$scan_rt" "$pid_n" || scan_ok=0
else
  scan_ok=0
fi
: > "$R/iso-rt.stop"  # each ends by itself within 0.1 s
for p in "$pid_k" "$pid_g" "$pid_o" "$pid_n"; do
  [ -n "$p" ] && poll_for 5 stopped "$p"
done
stop_own "$pid_k" "$rt_arg_k"; stop_own "$pid_g" "$rt_arg_g"; stop_own "$pid_o" "$rt_arg_o"
stop_own "$pid_n" "$rt_arg_n"

# A fresh run dir, made inside this one, and two processes tied to it only by
# their working dir: the old one, running for at least 4 s before the dir was
# made, and a young one started in it. Only the young one is that run's. (ps
# gives whole seconds, so the finder only skips a process that started at
# least a second before the dir; 4 s keeps the old one well past that.)
chk "the old process has run for 4 s before the fresh run dir is made" poll_for 20 ran_for "$old" 4
fresh="$(mktemp -d "$TMPDIR/jnv.XXXXXXXXXX")"
# This script made that dir, so it is its owner, as test_env.sh would record
# for the shell that made a run.
_jnv_owner_line "$$" > "$fresh/owner"
printf '%s\n' "$fresh" > "$R/iso-old-go.part" && mv "$R/iso-old-go.part" "$R/iso-old-go"
chk "the old process moved into the fresh run dir" poll_for 10 test -e "$R/iso-old-go.ready"
(cd "$fresh" && exec perl -e 'sleep 300' </dev/null >/dev/null 2>&1) &
young=$!; iso_bg "$young"
chk "the young process started in the fresh run dir" wait_cmd "$young" perl
scan_f="$(procs_in "$fresh" scan 2>/dev/null)"
chk "scan of the fresh run dir lists the young process (working dir only)" in_list "$scan_f" "$young"
chk "scan of the fresh run dir does not list the old process" \
  not in_list "$scan_f" "$old" || scan_ok=0
# --kill acts on what scan found, so it runs only when scan found exactly
# the young process.
if [ "$scan_ok" = 1 ] && same_pids "$scan_f" "$young"; then
  procs_in "$fresh" scan --kill >/dev/null 2>&1
  chk "scan --kill of the fresh run dir stops the young process" poll_for 5 stopped "$young"
  chk "scan --kill of the fresh run dir leaves the old process running" \
    not stopped "$old" || scan_ok=0
else
  echo "FAIL scan --kill of the fresh run dir not run: scan did not find exactly the young process"
  FAILS=$((FAILS + 1)); scan_ok=0
fi
# reap is fed only the old process, by hand (snapshot would not list it), so
# the most it could signal is that process of this script's.
old_line="$(printf '%s\t%s\t%s' "$old" "$(jnv_proc_ident "$old")" "perl (old)")"
printf '%s\n' "$old_line" \
  | JNV_LEAKS_FILE="$R/iso_leaks_old" procs_in "$fresh" reap --timeout 1 --label iso-old >/dev/null 2>&1
reap_old_rc=$?
chk "reap counts the old process as left over at its timeout (rc $reap_old_rc)" test "$reap_old_rc" = 1
chk "reap does not signal the old process, which is not provably the run's" \
  not stopped "$old" || snap_ok=0
kill "$young" "$old" 2>/dev/null
wait "$young" 2>/dev/null; wait "$old" 2>/dev/null

# A tmux server the run's record names (pid and start, as tests/lib/tmux.sh
# writes them) is the run's whatever else is known of it: here a daemon in a
# session of its own that names the fresh run dir, listed only once the
# record names it.
env -u JNV_RUN_ROOT ISO_RPID="$R/iso-rec.pid" perl -MPOSIX -e '
  defined(my $a = fork()) or exit 1; if ($a) { waitpid($a, 0); exit 0 }
  POSIX::setsid() or exit 1;
  defined(my $b = fork()) or exit 1; if ($b) { exit 0 }
  chdir "/"; open(my $f, ">", "$ENV{ISO_RPID}.part") or exit 1; print $f "$$\n"; close $f;
  rename("$ENV{ISO_RPID}.part", $ENV{ISO_RPID}); sleep 300' "$fresh/iso-recorded" </dev/null >/dev/null 2>&1
rec=""
poll_for 5 test -s "$R/iso-rec.pid" && rec="$(cat "$R/iso-rec.pid")"
wait_cmd "$rec" iso-recorded
chk "a daemon that names the fresh run dir, with nothing else tying it to the run, is not listed" \
  not in_list "$(procs_in "$fresh" scan 2>/dev/null)" "$rec" || scan_ok=0
printf '%s\t%s\t%s\n' "$fresh/jnv-sock" "$rec" "$(jnv_proc_ident "$rec")" > "$fresh/tmux-sockets"
chk "the same daemon is listed once the run's record names it as a tmux server" \
  in_list "$(procs_in "$fresh" scan 2>/dev/null)" "$rec"
: > "$fresh/tmux-sockets"
stop_own "$rec" iso-recorded

# The checker's parents are never the run's, whatever ties them to it: one
# names the fresh run dir in its command line, one has its working dir there.
# Each writes its pid to a file and then runs scan (list mode) as its child.
PARENT_PL='my $pf = shift; shift; open(my $f, ">", $pf) or exit 1; print $f "$$\n"; close $f;
  system(@ARGV); exit($? >> 8)'
# parent_clean NAME RC: scan exited 0 and did not list the parent
parent_clean() {
  local pid; pid="$(cat "$R/iso-parent-$1.pid" 2>/dev/null)"
  [ "$2" = 0 ] && [ -n "$pid" ] && ! in_list "$(cat "$R/iso-parent-$1.out" 2>/dev/null)" "$pid"
}
deadline 60 env JNV_RUN_ROOT="$fresh" JNV_RUN_ID="${fresh##*/jnv.}" \
  perl -e "$PARENT_PL" "$R/iso-parent-argv.pid" "$fresh/named-by-the-parent" \
  python3 -I "$PROCS" scan > "$R/iso-parent-argv.out" 2>/dev/null
parent_rc=$?
chk "scan does not list its parent that names the run dir (rc $parent_rc)" \
  parent_clean argv "$parent_rc" || scan_ok=0
deadline 60 sh -c 'cd "$1" && shift && exec "$@"' sh "$fresh" \
  env JNV_RUN_ROOT="$fresh" JNV_RUN_ID="${fresh##*/jnv.}" \
  perl -e "$PARENT_PL" "$R/iso-parent-cwd.pid" - \
  python3 -I "$PROCS" scan > "$R/iso-parent-cwd.out" 2>/dev/null
parent_rc=$?
chk "scan does not list its parent whose working dir is in the run dir (rc $parent_rc)" \
  parent_clean cwd "$parent_rc" || scan_ok=0

# Only what a run started is its own. A fresh run made by test_env.sh, whose
# shell is its owner and leads a process group of its own (as a suite
# started from an interactive shell or by an agent's command does), starts:
#   - a process that names its run dir, and one it double-forks (its parent
#     is then pid 1, or a subreaper on Linux; it stays in the owner's group);
#   - a script that starts a tmux server with a pane, whose shell
#     double-forks a process that names the run dir (an orphan in the pane's
#     session, as a kernel orphaned under a pane's nvim is), and that is
#     then KILLed before its exit hook: the server, the pane and the pane's
#     orphan stay, and they are the run's.
# This script, which that run did not start, then starts processes that
# refer to the run (most of them with parent pid 1, which alone never makes
# a process the run's):
#   - one that names the run dir and one with its working dir there (its
#     children: a tail -F, a shell someone opened in the dir);
#   - one whose parent is pid 1 from birth, in a session of its own, that
#     holds the run's log open with no run path on its command line (a GUI
#     app opening a file: Console.app);
#   - a tmux server, on a private server of this run (not the fresh run's),
#     started with its working dir in the fresh run dir, with a pane;
#   - a `(cmd &)` job that names the run dir, and a tail -F of the run's log
#     left by a shell that then exits (orphans, in this script's group).
# The fresh run's scan, snapshot and reap must take its own and leave this
# script's alone, and so must its cleanup and its exit. Then, as in the
# suite's hygiene check (the run's own processes have ended, and someone
# has just started a tail -F of its log in the background and opened the
# log in an app), a scan --kill finds nothing and exits 0, and both still
# run. Run only when the checks above held: what the fresh run's finder
# takes is stopped.
if [ "$scan_ok" = 1 ] && [ "$snap_ok" = 1 ] && type -P tmux >/dev/null 2>&1; then
  L="$R/iso_lin"
  # the double fork: pid file written when the last process runs
  printf '%s\n' 'my ($mark, $pf) = @ARGV;' \
    'defined(my $a = fork()) or exit 1; if ($a) { waitpid($a, 0); exit 0 }' \
    'defined(my $b = fork()) or exit 1; if ($b) { exit 0 }' \
    'open(my $f, ">", "$pf.part") or exit 1; print $f "$$\n"; close $f; rename("$pf.part", $pf);' \
    'sleep 300;' > "$R/iso_daemon.pl"
  # the fresh run's tmux script: a server and a pane whose shell double-forks
  # an orphan that names the run dir, then the pane runs on; KILLed later
  printf '%s\n' 'source "$1/tests/lib/tmux.sh"' \
    "tmux new-session -d -s own -x 80 -y 20 \"perl '\$3' '\$JNV_RUN_ROOT/iso-panedaemon' '\$2.panedaemon'; exec perl -e 'sleep 300' '\$JNV_RUN_ROOT/iso-pane'\"" \
    'tmux list-panes -t =own: -F "#{pane_pid}" > "$2.pane"' \
    '_jnv_server_pid > "$2.srv"; echo "$_JNV_TMUX_SOCKET_PATH" > "$2.sock"' \
    'n=0; until [ -s "$2.panedaemon" ]; do n=$((n + 1)); [ "$n" -ge 100 ] && break; sleep 0.1; done' \
    'echo ready > "$2.tmuxready.part" && mv "$2.tmuxready.part" "$2.tmuxready"' \
    'exec perl -e "sleep 300"' > "$R/iso_tmuxown.sh"
  # this script's tmux server, started in the fresh run dir; stopped (by its
  # own exit hook) once told to
  printf '%s\n' 'cd "$3" || exit 1' 'source "$1/tests/lib/tmux.sh"' \
    "tmux new-session -d -s out -x 80 -y 20 \"exec perl -e 'sleep 300'\"" \
    'tmux list-panes -t =out: -F "#{pane_pid}" > "$2.opane"' \
    '_jnv_server_pid > "$2.osrv"' \
    'echo ready > "$2.oready.part" && mv "$2.oready.part" "$2.oready"' \
    'n=0; until [ -e "$2.ostop" ]; do n=$((n + 1)); [ "$n" -ge 1200 ] && break; sleep 0.1; done' \
    > "$R/iso_outsrv.sh"
  fresh_run 'source "$1/tests/lib/test_env.sh"; out=$2
    P="$1/tests/lib/run_procs.py"
    echo "$$" > "$out.pid"
    : > "$JNV_RUN_ROOT/xdg/cache/jupynvim/core.log"
    perl -e "sleep 300" "$JNV_RUN_ROOT/iso-own" </dev/null >/dev/null 2>&1 &
    echo "$!" > "$out.own"
    perl "$3" "$JNV_RUN_ROOT/iso-daemon" "$out.daemon" </dev/null >/dev/null 2>&1
    bash "$4" "$1" "$out" "$3" </dev/null >/dev/null 2>&1 &
    c=$!
    n=0; until [ -s "$out.daemon" ] && [ -s "$out.tmuxready" ]; do n=$((n + 1)); [ "$n" -ge 150 ] && break; sleep 0.1; done
    kill -KILL "$c"; wait "$c" 2>/dev/null
    echo "$JNV_RUN_ROOT" > "$out.root.part" && mv "$out.root.part" "$out.root"
    n=0; until [ -s "$out.go" ]; do n=$((n + 1)); [ "$n" -ge 300 ] && exit 9; sleep 0.1; done
    read -r named cwd < "$out.go"
    python3 -I "$P" scan > "$out.scan" 2> "$out.scan.err"
    python3 -I "$P" snapshot "$named" "$cwd" > "$out.snapx" 2>/dev/null
    python3 -I "$P" snapshot "$(cat "$out.own")" "$(cat "$out.daemon")" > "$out.snapown" 2>/dev/null
    printf "%s\t%s\t%s\n" "$named" "$(jnv_proc_ident "$named")" "perl (named)" \
      | JNV_LEAKS_FILE="$out.leaks" python3 -I "$P" reap --timeout 0.5 --label iso-forged >/dev/null 2>&1
    echo "$?" > "$out.reaprc"
    python3 -I "$P" cleanup >/dev/null 2>&1
    echo "$?" > "$out.cleanuprc.part" && mv "$out.cleanuprc.part" "$out.cleanuprc"
    n=0; until [ -s "$out.go2" ]; do n=$((n + 1)); [ "$n" -ge 300 ] && exit 9; sleep 0.1; done
    python3 -I "$P" scan --kill > "$out.kill" 2>/dev/null
    echo "$?" > "$out.killrc"
    exit 0' "$L" "$R/iso_daemon.pl" "$R/iso_tmuxown.sh" </dev/null 2>/dev/null &
  lin_pid=$!; iso_bg "$lin_pid"
  lnamed=""; lcwd=""; lroot=""; ldaemon=""; lown=""; lsrv=""; lpane=""; lpaned=""; lsock=""
  lhold=""; lout=""; losrv=""; lopane=""; lparen=""; ltail=""; ltail2=""; lhold2=""
  if poll_for 40 test -s "$L.root"; then
    lroot="$(cat "$L.root")"; ldaemon="$(cat "$L.daemon" 2>/dev/null)"; lown="$(cat "$L.own" 2>/dev/null)"
    lsrv="$(cat "$L.srv" 2>/dev/null)"; lpane="$(cat "$L.pane" 2>/dev/null)"
    lpaned="$(cat "$L.panedaemon" 2>/dev/null)"; lsock="$(cat "$L.sock" 2>/dev/null)"
    (cd / && exec perl -e 'sleep 300' "$lroot/named-by-this-script" </dev/null >/dev/null 2>&1) &
    lnamed=$!; iso_bg "$lnamed"
    (cd "$lroot" && exec perl -e 'sleep 300' </dev/null >/dev/null 2>&1) &
    lcwd=$!; iso_bg "$lcwd"
    # parent pid 1 from birth, a session of its own, the run's log open; its
    # command line names no run path (iso-holder only marks it for the stop)
    ISO_HOLD="$lroot/xdg/cache/jupynvim/core.log" ISO_HPID="$L.hold" perl -MPOSIX -e '
      defined(my $a = fork()) or exit 1; if ($a) { waitpid($a, 0); exit 0 }
      POSIX::setsid() or exit 1;
      defined(my $b = fork()) or exit 1; if ($b) { exit 0 }
      chdir "/"; open(my $h, "<", $ENV{ISO_HOLD}) or exit 1;
      open(my $f, ">", "$ENV{ISO_HPID}.part") or exit 1; print $f "$$\n"; close $f;
      rename("$ENV{ISO_HPID}.part", $ENV{ISO_HPID}); sleep 300' iso-holder </dev/null >/dev/null 2>&1
    bash "$R/iso_outsrv.sh" "$REPO" "$L" "$lroot" </dev/null >/dev/null 2>&1 &
    lout=$!; iso_bg "$lout"
    ( cd / || exit 1
      perl -e 'sleep 300' "$lroot/iso-paren" </dev/null >/dev/null 2>&1 &
      echo "$!" > "$L.paren" )
    bash -c 'tail -F "$1" </dev/null >/dev/null 2>&1 & echo "$!" > "$2"' _ "$lroot/xdg/cache/jupynvim/core.log" "$L.tail"
    poll_for 10 test -s "$L.hold"; poll_for 20 test -s "$L.oready"
    lhold="$(cat "$L.hold" 2>/dev/null)"; lparen="$(cat "$L.paren" 2>/dev/null)"; ltail="$(cat "$L.tail" 2>/dev/null)"
    losrv="$(cat "$L.osrv" 2>/dev/null)"; lopane="$(cat "$L.opane" 2>/dev/null)"
    wait_cmd "$lnamed" named-by-this-script; wait_cmd "$lcwd" perl
    wait_cmd "$lparen" iso-paren; wait_cmd "$ltail" core.log
    chk "the fresh run's double-forked process is no longer a child of its shell" \
      not test "$(ps -o ppid= -p "${ldaemon:-0}" 2>/dev/null | tr -d ' ')" = "$(cat "$L.pid" 2>/dev/null)"
    ppid_is_1() { [ "$(ps -o ppid= -p "${1:-0}" 2>/dev/null | tr -d ' ')" = 1 ]; }
    chk "its tmux server, and the orphan in its pane's session, have parent pid 1" \
      eval 'ppid_is_1 "$lsrv" && ppid_is_1 "$lpaned"'
    chk "this script's log holder, tmux server, (cmd &) job and tail have parent pid 1" \
      eval 'ppid_is_1 "$lhold" && ppid_is_1 "$losrv" && ppid_is_1 "$lparen" && ppid_is_1 "$ltail"'
    printf '%s %s\n' "$lnamed" "$lcwd" > "$L.go.part" && mv "$L.go.part" "$L.go"
    # once its cleanup is done: a second tail -F and log holder, then the
    # hygiene scan
    if poll_for 40 test -s "$L.cleanuprc"; then
      bash -c 'tail -F "$1" </dev/null >/dev/null 2>&1 & echo "$!" > "$2"' _ "$lroot/xdg/cache/jupynvim/core.log" "$L.tail2"
      ISO_HOLD="$lroot/xdg/cache/jupynvim/core.log" ISO_HPID="$L.hold2" perl -MPOSIX -e '
        defined(my $a = fork()) or exit 1; if ($a) { waitpid($a, 0); exit 0 }
        POSIX::setsid() or exit 1;
        defined(my $b = fork()) or exit 1; if ($b) { exit 0 }
        chdir "/"; open(my $h, "<", $ENV{ISO_HOLD}) or exit 1;
        open(my $f, ">", "$ENV{ISO_HPID}.part") or exit 1; print $f "$$\n"; close $f;
        rename("$ENV{ISO_HPID}.part", $ENV{ISO_HPID}); sleep 300' iso-holder2 </dev/null >/dev/null 2>&1
      poll_for 10 test -s "$L.hold2"
      ltail2="$(cat "$L.tail2" 2>/dev/null)"; lhold2="$(cat "$L.hold2" 2>/dev/null)"
      wait_cmd "$ltail2" core.log
    fi
    echo go > "$L.go2.part" && mv "$L.go2.part" "$L.go2"
  else
    echo "FAIL the fresh run for the lineage checks did not start"; FAILS=$((FAILS + 1))
  fi
  wait "$lin_pid"; lin_rc=$?
  lscan="$(cat "$L.scan" 2>/dev/null)"
  chk "the fresh run ran its checks and exited 0 (rc $lin_rc)" test "$lin_rc" = 0
  chk "its scan lists the process it started" in_list "$lscan" "$lown"
  chk "its scan lists the process it double-forked" in_list "$lscan" "$ldaemon"
  chk "its scan lists its tmux server, whose script was KILLed" in_list "$lscan" "$lsrv"
  chk "its scan lists that server's pane" in_list "$lscan" "$lpane"
  chk "its scan lists the orphan in that pane's session" in_list "$lscan" "$lpaned"
  # name PID: not listed by the fresh run's scan (feeds scan_ok)
  not_taken() {
    local what="$1" p="$2"
    chk "its scan does not list $what" not in_list "$lscan" "$p" || scan_ok=0
  }
  not_taken "a process this script started that names its run dir" "$lnamed"
  not_taken "a process this script started in its run dir" "$lcwd"
  not_taken "a process with parent pid 1 from birth that holds its log open" "$lhold"
  not_taken "a tmux server of this script's started in its run dir" "$losrv"
  not_taken "that server's pane" "$lopane"
  not_taken "a (cmd &) job of this script's that names its run dir" "$lparen"
  not_taken "a tail -F of its log left by a shell that exited" "$ltail"
  says_left_alone() { grep -q "^run_procs: $1 refers to the run but the run did not start it" "$L.scan.err" 2>/dev/null; }
  chk "its scan reports the one that names its run dir as not started by the run" \
    says_left_alone "$lnamed"
  chk "its scan reports the one in its run dir as not started by the run" \
    says_left_alone "$lcwd"
  chk "and the log holder, the tmux server and pane, the (cmd &) job and the tail" \
    eval 'says_left_alone "$lhold" && says_left_alone "$losrv" && says_left_alone "$lopane" && says_left_alone "$lparen" && says_left_alone "$ltail"'
  chk "its snapshot of those two lists nothing" test -z "$(cat "$L.snapx" 2>/dev/null)" || snap_ok=0
  chk "its snapshot of its own two lists both" \
    same_pids "$(cat "$L.snapown" 2>/dev/null)" "$lown" "$ldaemon"
  chk "its reap, fed the first of them, counts it as left over (rc $(cat "$L.reaprc" 2>/dev/null))" \
    test "$(cat "$L.reaprc" 2>/dev/null)" = 1
  chk "its cleanup stops what the run started (rc $(cat "$L.cleanuprc" 2>/dev/null))" \
    test "$(cat "$L.cleanuprc" 2>/dev/null)" = 1
  chk "then, with a tail -F of its log and an app holding it just started, the hygiene scan --kill finds nothing (rc $(cat "$L.killrc" 2>/dev/null): $(tr '\n' ' ' < "$L.kill" 2>/dev/null))" \
    test "$(cat "$L.killrc" 2>/dev/null)" = 0 || scan_ok=0
  chk "the process it started is stopped" poll_for 5 not cmd_has "$lown" iso-own
  chk "the process it double-forked is stopped" poll_for 5 not cmd_has "$ldaemon" iso-daemon
  chk "its tmux server is stopped" poll_for 5 not cmd_has "$lsrv" "jnv-"
  chk "its pane and the orphan in the pane's session are stopped" \
    poll_for 5 eval 'not cmd_has "$lpane" iso-pane && not cmd_has "$lpaned" iso-panedaemon'
  chk "and its socket file is removed (${lsock##*/})" gone "$lsock"
  # still_runs WHAT PID TEXT: after the fresh run's reap, cleanup, scan
  # --kill and exit, this script's process still runs (feeds scan_ok)
  still_runs() {
    chk "after all that, $1 still runs" cmd_has "$2" "$3" || scan_ok=0
  }
  still_runs "this script's process that names its run dir" "$lnamed" named-by-this-script
  still_runs "this script's process in its run dir" "$lcwd" perl
  still_runs "the log holder" "$lhold" iso-holder
  still_runs "this script's tmux server" "$losrv" "jnv-"
  still_runs "that server's pane" "$lopane" perl
  still_runs "the (cmd &) job" "$lparen" iso-paren
  still_runs "the tail" "$ltail" core.log
  still_runs "the tail started after its cleanup" "$ltail2" core.log
  still_runs "the log holder started after its cleanup" "$lhold2" iso-holder2
  chk "the fresh run's dir is removed" gone "$lroot"
  # never leave them, even when failing
  stop_own "$lown" iso-own; stop_own "$ldaemon" iso-daemon; stop_own "$lpaned" iso-panedaemon
  stop_own "$lpane" iso-pane; stop_own "$lsrv" "jnv-"
  case "${lsock##*/}" in jnv-?*) [ -S "$lsock" ] && ! cmd_has "$lsrv" "jnv-" && rm -f "$lsock" ;; esac
  for p in $lnamed $lcwd; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done
  stop_own "$lhold" iso-holder; stop_own "$lparen" iso-paren; stop_own "$ltail" core.log
  stop_own "$ltail2" core.log; stop_own "$lhold2" iso-holder2
  : > "$L.ostop"
  [ -n "$lout" ] && wait "$lout" 2>/dev/null
  chk "this script's tmux server stops at its script's exit" poll_for 5 not cmd_has "$losrv" "jnv-"
  stop_own "$lopane" perl; stop_own "$losrv" "jnv-"
elif [ "$scan_ok" = 1 ] && [ "$snap_ok" = 1 ]; then
  echo "FAIL tmux missing (the lineage checks)"; FAILS=$((FAILS + 1)); scan_ok=0
else
  echo "FAIL the lineage checks were not run: the checks above did not hold"
  FAILS=$((FAILS + 1)); scan_ok=0
fi

scan_safe=$scan_ok
snap_safe=$snap_ok

# ── S2 unique and removed ───────────────────────────────
echo "S2 unique and removed"
if [ "$scan_safe" != 1 ]; then
  echo "FAIL S2 not run: scan lists processes this run did not start, and each fresh run calls scan --kill when it exits"
  FAILS=$((FAILS + 1))
else
  S2A="$R/iso_s2_a"; S2B="$R/iso_s2_b"; S2C="$R/iso_s2_c"
  fresh_run 'source "$1/tests/lib/test_env.sh"; echo "$JNV_RUN_ROOT" > "$2"; sleep 1' "$S2A" &
  pa=$!; iso_bg "$pa"
  fresh_run 'source "$1/tests/lib/test_env.sh"; echo "$JNV_RUN_ROOT" > "$2"; sleep 1' "$S2B" &
  pb=$!; iso_bg "$pb"
  wait "$pa"; rca=$?
  wait "$pb"; rcb=$?
  ra="$(cat "$S2A" 2>/dev/null)"; rb="$(cat "$S2B" 2>/dev/null)"
  both_ok() { [ "$rca" = 0 ] && [ "$rcb" = 0 ]; }
  chk "two runs started at once both finish (rc $rca and $rcb)" both_ok
  differ() { [ -n "$1" ] && [ -n "$2" ] && [ "$1" != "$2" ]; }
  chk "two runs started at once get different run dirs" differ "$ra" "$rb"
  chk "the first run's dir is removed when it exits" gone "$ra"
  chk "the second run's dir is removed when it exits" gone "$rb"
  # Two runs started by the same command share its process group. One
  # leaves an orphan there that refers to nothing (a section's leftover);
  # the other, ending normally, still removes its dir: at a run's own exit
  # only what runs under its owner keeps the dir.
  printf '%s\n' 'source "$1/tests/lib/test_env.sh"; echo "$JNV_RUN_ROOT" > "$2.b"' \
    'n=0; until [ -e "$2.bgo" ]; do n=$((n + 1)); [ "$n" -ge 300 ] && exit 9; sleep 0.1; done' \
    > "$R/iso_shared_b.sh"
  printf '%s\n' 'source "$1/tests/lib/test_env.sh"' \
    '( cd / || exit 1; perl -e "sleep 30" </dev/null >/dev/null 2>&1 & echo "$!" > "$2.orphan" )' \
    > "$R/iso_shared_a.sh"
  fresh_run 'out=$2
    bash "$3/iso_shared_b.sh" "$1" "$out" </dev/null 2>/dev/null &
    b=$!
    n=0; until [ -s "$out.b" ]; do n=$((n + 1)); [ "$n" -ge 300 ] && exit 9; sleep 0.1; done
    bash "$3/iso_shared_a.sh" "$1" "$out" </dev/null 2>/dev/null
    : > "$out.bgo"
    wait "$b"' "$R/iso_shared" "$R" </dev/null 2>/dev/null
  rcsh=$?
  shared_orphan="$(cat "$R/iso_shared.orphan" 2>/dev/null)"
  chk "a run sharing its process group with another run's orphan still removes its dir when it ends (rc $rcsh)" \
    eval '[ "$rcsh" = 0 ] && gone "$(cat "$R/iso_shared.b" 2>/dev/null)"'
  chk "and leaves that orphan alone" cmd_has "$shared_orphan" "sleep 30"
  stop_own "$shared_orphan" "sleep 30"
  fresh_run 'source "$1/tests/lib/test_env.sh"; echo "$JNV_RUN_ROOT" > "$2"; exit 3' "$S2C"
  rcc=$?
  rc3="$(cat "$S2C" 2>/dev/null)"
  chk "a run that exits 3 keeps its exit status (rc $rcc)" test "$rcc" = 3
  chk "a run that exits 3 still removes its run dir" gone "$rc3"

  # The exit hooks. A fresh run made inside a subshell belongs to that
  # subshell: it is removed when the subshell exits, while the shell around it
  # keeps its own run dir until it exits itself.
  fresh_run 'source "$1/tests/lib/test_env.sh"; out=$2
    echo "$JNV_RUN_ROOT" > "$out.outer"
    ( unset JNV_RUN_ENV_READY; source "$1/tests/lib/test_env.sh"; echo "$JNV_RUN_ROOT" > "$out.inner" )
    inner="$(cat "$out.inner" 2>/dev/null)"
    if [ -n "$inner" ] && [ "$inner" != "$JNV_RUN_ROOT" ] && [ ! -e "$inner" ]; then i=removed; else i=left; fi
    if [ -d "$JNV_RUN_ROOT" ]; then o=kept; else o=removed; fi
    echo "inner=$i outer=$o" > "$out.state"' "$R/iso_sub" </dev/null
  rcs=$?
  sub_state="$(cat "$R/iso_sub.state" 2>/dev/null)"
  has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }
  chk "a fresh run made in a subshell is removed when the subshell exits ($sub_state)" \
    has "$sub_state" inner=removed
  chk "the shell around that subshell keeps its own run dir meanwhile" has "$sub_state" outer=kept
  outer_done() { [ "$rcs" = 0 ] && gone "$(cat "$R/iso_sub.outer" 2>/dev/null)"; }
  chk "and removes it when it exits itself (rc $rcs)" outer_done

  # A subshell that sources test_env.sh again reuses the run, and leaves it
  # in place when it exits: only the shell that made a run removes it.
  fresh_run 'source "$1/tests/lib/test_env.sh"; out=$2
    echo "$JNV_RUN_ROOT" > "$out.root"
    ( source "$1/tests/lib/test_env.sh"; echo "$JNV_RUN_ROOT" > "$out.inner" )
    if [ "$(cat "$out.inner" 2>/dev/null)" = "$JNV_RUN_ROOT" ] && [ -d "$JNV_RUN_ROOT" ]; then
      echo kept; else echo removed; fi > "$out.state"' "$R/iso_resrc" </dev/null
  rcr=$?
  chk "a subshell that sources test_env.sh again reuses the run and leaves it in place ($(cat "$R/iso_resrc.state" 2>/dev/null))" \
    test "$(cat "$R/iso_resrc.state" 2>/dev/null)" = kept
  resrc_done() { [ "$rcr" = 0 ] && gone "$(cat "$R/iso_resrc.root" 2>/dev/null)"; }
  chk "the shell that made it still removes it when it exits (rc $rcr)" resrc_done

  # Nothing a hook does keeps the hooks after it, or the run dir removal, from
  # running, and the script's own exit status stays. Each run below adds a
  # hook that logs "last", then the hook under test, then one that logs
  # "first" (the last added runs first), and exits 0. MODE is plain, errexit
  # (set -e), nounset (set -u) or posix (set -o posix). Helpers: iso_fail
  # exits; iso_guard stops at an `|| exit 0` guard (iso_empty is never set)
  # and logs "after" past it. Each run starts in a dir of its own,
  # $R/iso_hook_NAME.wd.
  hook_run() {  # hook_run NAME MODE HOOK
    mkdir -p "$R/iso_hook_$1.wd" || return 1
    ( cd "$R/iso_hook_$1.wd" && fresh_run '[ "$3" = posix ] && set -o posix
      [ "$3" = nounset ] && set -u
      [ "$3" = errexit ] && set -e
      iso_fail() { exit 5; }
      iso_guard() { [ -n "${iso_empty:-}" ] || exit 0; echo after >> "$out.log"; }
      source "$1/tests/lib/test_env.sh"; out=$2
      echo "$JNV_RUN_ROOT" > "$out.root"
      jnv_on_exit "echo last >> \"\$out.log\""
      jnv_on_exit "$4"
      jnv_on_exit "echo first >> \"\$out.log\""
      exit 0' "$R/iso_hook_$1" "$2" "$3" )
  }
  hooks_ran() { [ "$2" = 0 ] && [ "$(tr '\n' ' ' < "$R/iso_hook_$1.log" 2>/dev/null)" = "first last " ]; }
  hook_root_gone() { gone "$(cat "$R/iso_hook_$1.root" 2>/dev/null)"; }
  # hook_case NAME WHAT MODE HOOK: run it (stdin is the caller's) and check
  hook_case() {
    local rc
    hook_run "$1" "$3" "$4"; rc=$?
    chk "$2: the hooks after it run and status 0 stays (rc $rc)" hooks_ran "$1" "$rc"
    chk "$2: the run dir is still removed" hook_root_gone "$1"
  }
  # hook_stops NAME WHAT MODE HOOK: hook_case, and the hook itself ended
  # there: nothing after that point logged "after"
  ended_there() { [ -f "$R/iso_hook_$1.log" ] && ! grep -q after "$R/iso_hook_$1.log"; }
  hook_stops() {
    hook_case "$@"
    chk "$2: the hook ends there (nothing after it in the hook runs)" ended_there "$1"
  }
  hook_case fail "a hook that fails under set -e" errexit 'false' </dev/null
  # Under set -e a failed command ends the hook it is in, as it would end a
  # plain EXIT trap, so nothing meant to follow a step that failed runs.
  hook_stops errexit "a hook whose command fails under set -e" errexit \
    'false; echo after >> "$out.log"' </dev/null
  # Without set -e a failed command does not end its hook, as in a plain
  # EXIT trap, so a cleanup step after one that failed still runs.
  hook_run plainfail plain 'false; echo after >> "$out.log"' </dev/null; rcpf=$?
  goes_on() { [ "$2" = 0 ] && [ "$(tr '\n' ' ' < "$R/iso_hook_$1.log" 2>/dev/null)" = "first after last " ]; }
  chk "a hook whose command fails without set -e goes on past it, then the hooks after it run (rc $rcpf)" \
    goes_on plainfail "$rcpf"
  chk "a hook whose command fails without set -e: the run dir is still removed" hook_root_gone plainfail
  hook_case unset "a hook that reads an unset variable under set -u" nounset \
    ': "$iso_no_such_var"' </dev/null 2> "$R/iso_hook_unset.err"
  hook_case stdin "a hook that reads stdin" plain 'cat > "$out.stdin"' <<< "from-stdin"
  chk "that hook reads the script's stdin, not the hook list" \
    test "$(cat "$R/iso_hook_stdin.stdin" 2>/dev/null)" = from-stdin
  # exit, return and break end the hook they are in, and only that hook,
  # wherever they are: at its top level, in a helper, in posix mode.
  hook_stops exit "a hook that calls exit 4" plain 'exit 4; echo after >> "$out.log"' </dev/null
  hook_stops helper "a hook whose helper calls exit" plain \
    'iso_fail; echo after >> "$out.log"' </dev/null
  hook_stops guard "a hook whose helper meets its || exit 0 guard" plain 'iso_guard' </dev/null
  hook_stops posix "in posix mode, a hook that calls exit 4" posix \
    'exit 4; echo after >> "$out.log"' </dev/null
  hook_stops return "a hook that calls return 3" plain 'return 3; echo after >> "$out.log"' </dev/null
  hook_stops break "a hook that calls break" plain 'break; echo after >> "$out.log"' </dev/null
  # `cd DIR || exit` in a subshell of a hook stops that subshell, so nothing
  # meant for DIR runs in the hook's own dir.
  hook_case cdexit "a hook whose subshell runs cd DIR || exit 1 on a missing DIR" plain \
    '( cd "$out.missing" 2>/dev/null || exit 1; : > "$PWD/iso-wrongdir" )' </dev/null
  chk "that subshell stops at its exit and writes nothing in the hook's working dir" \
    not test -e "$R/iso_hook_cdexit.wd/iso-wrongdir"
  # A signal to the script while the hooks run: TERM, INT or HUP sent to the
  # script's shell alone does not cut the hooks short, and a Ctrl-C ends only
  # the hook that is running. A Ctrl-C sends INT to every process in the
  # terminal's foreground group: here the script's shell ($$) and the hook's
  # subshell (the parent of the sh it starts; bash 3.2 has no BASHPID), the
  # shell first, since a signal a process sends itself lands at once.
  iso_signals=1
  hook_case term "a hook during which the script gets TERM" plain 'kill -TERM $$' </dev/null
  hook_case int "a hook during which the script gets INT" plain 'kill -INT $$' </dev/null
  hook_case hup "a hook during which the script gets HUP" plain 'kill -HUP $$' </dev/null
  hook_stops ctrlc "a hook during which the script and the hook get INT (Ctrl-C)" plain \
    'sh -c "echo \$PPID > \"\$1\"" sh "$out.hp"; read -r hp < "$out.hp"; kill -INT $$ "$hp"; sleep 2; echo after >> "$out.log"' </dev/null
  # A HUP to the script's shell alone while a command runs in the foreground
  # (as TERM): the run and its dir stay until that command returns, then the
  # script exits 129 and the hooks run. (Untrapped, bash would run the hooks
  # at once and remove the run dir under the command still running.)
  # The foreground command waits for the HUP to be sent, gives an untrapped
  # shell 1.5 s to remove the run dir, then records whether it is still there.
  fresh_run 'source "$1/tests/lib/test_env.sh"; out=$2
    echo "$JNV_RUN_ROOT" > "$out.root"
    jnv_on_exit "echo hook >> \"\$out.log\""
    echo "$$" > "$out.pid.part" && mv "$out.pid.part" "$out.pid"
    perl -e "my \$n = 0; until (-e \$ARGV[1] or ++\$n > 300) { select(undef, undef, undef, 0.05) }
      select(undef, undef, undef, 1.5); print((-d \$ARGV[0]) ? \"kept\n\" : \"gone\n\")" \
      "$JNV_RUN_ROOT" "$out.sent" </dev/null > "$out.fg"
    echo after >> "$out.log"
    exit 0' "$R/iso_hupfg" </dev/null &
  hup_job=$!; iso_bg "$hup_job"
  hup_root=""
  # has_child PID: PID has a child process (its foreground command)
  has_child() { ps -A -o ppid= | tr -d ' ' | grep -qx "$1"; }
  if poll_for 30 test -s "$R/iso_hupfg.pid"; then
    hup_sh="$(cat "$R/iso_hupfg.pid")"; hup_root="$(cat "$R/iso_hupfg.root" 2>/dev/null)"
    poll_for 5 has_child "$hup_sh"
    kill -HUP "$hup_sh"
    : > "$R/iso_hupfg.sent"
  fi
  wait "$hup_job"; rchup=$?
  chk "a HUP to a run's shell while a command runs in the foreground leaves its run dir until the command returns" \
    test "$(cat "$R/iso_hupfg.fg" 2>/dev/null)" = kept
  chk "then that run exits 129 (rc $rchup)" test "$rchup" = 129
  chk "and its hooks run (and nothing after the command)" \
    test "$(cat "$R/iso_hupfg.log" 2>/dev/null)" = hook
  chk "and its run dir is removed" gone "$hup_root"
  iso_signals=""

  # jnv_on_exit with no command is a usage error the script survives.
  fresh_run 'set -u; source "$1/tests/lib/test_env.sh"; out=$2
    echo "$JNV_RUN_ROOT" > "$out.root"
    jnv_on_exit 2> "$out.err"; echo "$?" > "$out.rc"; exit 0' "$R/iso_noarg" </dev/null
  rcn=$?
  noarg_ok() {
    [ "$rcn" = 0 ] && [ "$(cat "$R/iso_noarg.rc" 2>/dev/null)" = 2 ] \
      && grep -q 'jnv_on_exit' "$R/iso_noarg.err" 2>/dev/null
  }
  chk "jnv_on_exit with no command says so, returns 2 and the script goes on (rc $rcn)" noarg_ok
  chk "after that usage error the run dir is still removed" gone "$(cat "$R/iso_noarg.root" 2>/dev/null)"

  # The dir removed at exit is the one the shell made, even when the script
  # has pointed JNV_RUN_ROOT at another dir.
  decoy="$R/tmp/jnv.isodecoy"
  fresh_run 'source "$1/tests/lib/test_env.sh"; out=$2
    echo "$JNV_RUN_ROOT" > "$out.root"
    mkdir -p "$3" && JNV_RUN_ROOT="$3"
    exit 0' "$R/iso_decoy" "$decoy" </dev/null
  rcy=$?
  own_gone() { [ "$rcy" = 0 ] && gone "$(cat "$R/iso_decoy.root" 2>/dev/null)"; }
  chk "a run whose script points JNV_RUN_ROOT at another jnv. dir removes its own (rc $rcy)" own_gone
  chk "and leaves that other dir alone" test -d "$decoy"

  # The shell that made a run stops what is left of it when it exits: here a
  # process that names the run dir, left running in the background.
  fresh_run 'source "$1/tests/lib/test_env.sh"; out=$2
    echo "$JNV_RUN_ROOT" > "$out.root"
    perl -e "sleep 300" "$JNV_RUN_ROOT/iso-left" </dev/null >/dev/null 2>&1 &
    echo "$!" > "$out.pid"
    n=0
    until ps -ww -o command= -p "$!" 2>/dev/null | grep -q iso-left; do
      n=$((n + 1)); [ "$n" -ge 50 ] && break; sleep 0.1
    done
    exit 0' "$R/iso_left" </dev/null
  rcl=$?
  left_pid="$(cat "$R/iso_left.pid" 2>/dev/null)"
  # left_running: that pid is still the process the run left
  left_running() {
    [ -n "$left_pid" ] && ps -ww -o command= -p "$left_pid" 2>/dev/null | grep -q iso-left
  }
  left_done() { [ "$rcl" = 0 ] && gone "$(cat "$R/iso_left.root" 2>/dev/null)"; }
  chk "a run that leaves a process behind exits 0 and removes its run dir (rc $rcl)" left_done
  chk "and stops that process when it exits" poll_for 5 not left_running
  left_running && kill -9 "$left_pid" 2>/dev/null

  # The matplotlib font cache. With fontlist files in the caller's
  # MPLCONFIGDIR, those are copied into the run, and never matplotlibrc.
  mkdir -p "$R/iso_mplsrc"
  printf '{"iso": "fontlist"}\n' > "$R/iso_mplsrc/fontlist-v999.json"
  printf 'backend: iso\n' > "$R/iso_mplsrc/matplotlibrc"
  fresh_run 'out=$2; MPLCONFIGDIR="$3"; export MPLCONFIGDIR
    source "$1/tests/lib/test_env.sh"
    echo "$JNV_RUN_ROOT" > "$out.root"; echo "$MPLCONFIGDIR" > "$out.dir"
    ls -A "$MPLCONFIGDIR" > "$out.ls"
    cat "$MPLCONFIGDIR/fontlist-v999.json" > "$out.json" 2>/dev/null
    exit 0' "$R/iso_mplcopy" "$R/iso_mplsrc" </dev/null 2> "$R/iso_mplcopy.err"
  rcm=$?
  mpl_in_run() {
    [ "$rcm" = 0 ] && is_under "$(cat "$R/iso_mplcopy.dir" 2>/dev/null)" "$(cat "$R/iso_mplcopy.root" 2>/dev/null)"
  }
  chk "a run gets an MPLCONFIGDIR of its own when the caller has one (rc $rcm)" mpl_in_run
  chk "the caller's fontlist files are copied into it" \
    cmp -s "$R/iso_mplsrc/fontlist-v999.json" "$R/iso_mplcopy.json"
  chk "the caller's matplotlibrc is not" not grep -qx matplotlibrc "$R/iso_mplcopy.ls"
  chk "nothing is built when the cache was copied" not grep -q 'font cache' "$R/iso_mplcopy.err"
  chk "the caller's MPLCONFIGDIR is left as it was" \
    test "$(ls -A "$R/iso_mplsrc" | tr '\n' ' ')" = "fontlist-v999.json matplotlibrc "
  # With none to copy, the run builds one with the kernel's python, in the
  # run, when that python has matplotlib; the stand-in python below logs each
  # call with the MPLCONFIGDIR it got, and has matplotlib when ISO_FAKE_MPL=1.
  # With ISO_FAKE_TERM=PID it logs its TMPDIR and sends PID a TERM when the
  # run checks for ipykernel.
  mkdir -p "$R/iso_mplempty"
  printf '%s\n' '#!/bin/sh' \
    'printf "%s|%s\n" "$*" "${MPLCONFIGDIR:-}" >> "$ISO_FAKE_LOG"' \
    'case "$*:${ISO_FAKE_TERM:-}" in *ipykernel*:?*)' \
    '  printf "tmp|%s\n" "$TMPDIR" >> "$ISO_FAKE_LOG"; kill -TERM "$ISO_FAKE_TERM" ;; esac' \
    'case "$*" in *find_spec*) [ "${ISO_FAKE_MPL:-}" = 1 ] ;; esac' > "$R/iso_fakepy"
  chmod 755 "$R/iso_fakepy"
  mpl_build_run() {  # mpl_build_run NAME HAS_MATPLOTLIB
    fresh_run 'out=$2; MPLCONFIGDIR="$3" JUPYNVIM_TEST_KERNEL_PYTHON="$4" ISO_FAKE_LOG="$2.log" ISO_FAKE_MPL="$5"
      export MPLCONFIGDIR JUPYNVIM_TEST_KERNEL_PYTHON ISO_FAKE_LOG ISO_FAKE_MPL
      source "$1/tests/lib/test_env.sh"
      echo "$JNV_RUN_ROOT" > "$out.root"; echo "$MPLCONFIGDIR" > "$out.dir"
      exit 0' "$R/iso_$1" "$R/iso_mplempty" "$R/iso_fakepy" "$2" </dev/null 2> "$R/iso_$1.err"
  }
  # built_in_run NAME: the log shows the build, run with the run's MPLCONFIGDIR
  built_in_run() {
    local d; d="$(cat "$R/iso_$1.dir" 2>/dev/null)"
    [ -n "$d" ] && is_under "$d" "$(cat "$R/iso_$1.root" 2>/dev/null)" \
      && grep -qxF -- "-c import matplotlib.font_manager|$d" "$R/iso_$1.log"
  }
  mpl_build_run mplbuild 1; rcb1=$?
  chk "with no cache to copy and matplotlib in the kernel, the run builds one (rc $rcb1)" \
    built_in_run mplbuild
  chk "and says so" grep -q 'building the matplotlib font cache' "$R/iso_mplbuild.err"
  mpl_build_run mplnone 0; rcb0=$?
  chk "with no cache to copy and no matplotlib in the kernel, nothing is built (rc $rcb0)" \
    not grep -q font_manager "$R/iso_mplnone.log"
  chk "nothing is written to the caller's empty MPLCONFIGDIR" test -z "$(ls -A "$R/iso_mplempty")"

  # The caller's Python and matplotlib settings do not reach the run: a
  # caller with a startup file (it writes a marker when it runs), a Python
  # path, a matplotlib backend and rc file and the rest of the list makes a
  # run in which all of them are unset, the kernel's python sees none of
  # them, and an interactive python (which would run a startup file) leaves
  # no marker. That interactive python also saves its history when it exits:
  # Python 3.13 and later into PYTHON_HISTORY, which must be in the run, an
  # older one into $HOME/.python_history. So it is given a HOME in this run
  # (iso_home), never the user's, and with 3.13 or later nothing may land
  # there.
  mkdir -p "$R/iso_pypath" "$R/iso_home"
  printf '%s\n' 'import os' 'open(os.environ["ISO_PYMARK"], "w").write("ran")' > "$R/iso_pystartup.py"
  ( export ISO_PYMARK="$R/iso_pyenv.ran" PYTHONSTARTUP="$R/iso_pystartup.py" \
      PYTHONPATH="$R/iso_pypath" PYTHONSAFEPATH=1 PYTHONWARNINGS=default PYTHONBREAKPOINT=0 \
      PYTHONPYCACHEPREFIX="$R/iso_pyc" PYTHONIOENCODING=utf-8 PYTHONUTF8=1 MPLBACKEND=iso-bogus \
      MATPLOTLIBRC="$R/iso_mplrc" JUPYTER_CONFIG_PATH="$R/iso_jcfg" JUPYTER_PREFER_ENV_PATH=1 \
      JUPYTER_PLATFORM_DIRS=1
    fresh_run 'source "$1/tests/lib/test_env.sh"; out=$2
      for v in $3; do eval "[ -z \"\${$v+set}\" ]" || echo "$v"; done > "$out.left"
      "$JNV_KERNEL_PYTHON" -c "import os, sys; print(\" \".join(v for v in sys.argv[1:] if v in os.environ))" $3 > "$out.kenv"
      "$JNV_KERNEL_PYTHON" -c "import sys; print(int(sys.version_info >= (3, 13)))" > "$out.py313" 2>/dev/null
      HOME="$4" "$JNV_KERNEL_PYTHON" -i </dev/null >/dev/null 2>&1
      h="${PYTHON_HISTORY:-}"
      case "$h" in "$JNV_RUN_ROOT"/*) [ -e "$h" ] && echo "in the run" ;; esac > "$out.hist"
      exit 0' "$R/iso_pyenv" "$ISO_PY_VARS" "$R/iso_home" </dev/null 2>/dev/null )
  rcpy=$?
  chk "a caller's Python and matplotlib settings are unset in the run (rc $rcpy; left: $(tr '\n' ' ' < "$R/iso_pyenv.left" 2>/dev/null))" \
    test "$rcpy" = 0 -a -f "$R/iso_pyenv.left" -a ! -s "$R/iso_pyenv.left"
  chk "the kernel's python sees none of them ($(cat "$R/iso_pyenv.kenv" 2>/dev/null))" \
    test -f "$R/iso_pyenv.kenv" -a -z "$(tr -d '\n' < "$R/iso_pyenv.kenv" 2>/dev/null)"
  chk "an interactive python in the run does not run the caller's startup file" \
    not test -e "$R/iso_pyenv.ran"
  if [ "$(cat "$R/iso_pyenv.py313" 2>/dev/null)" = 1 ]; then
    chk "that interactive python saves its history in the run (PYTHON_HISTORY)" \
      test "$(cat "$R/iso_pyenv.hist" 2>/dev/null)" = "in the run"
    chk "and writes nothing in the HOME it was given ($(ls -A "$R/iso_home" | tr '\n' ' '))" \
      test -z "$(ls -A "$R/iso_home")"
  else
    echo "  -- the kernel python is older than 3.13: it saves its history into HOME, here a HOME in this run"
    chk "that interactive python saves its history into the HOME it was given, in this run" \
      test -e "$R/iso_home/.python_history"
  fi

  # A caller's JUPYNVIM_RUNTIME_DIR stays out of a run too: the backend would
  # put the run's kernel connection files there, outside the run dir.
  fresh_run 'export JUPYNVIM_RUNTIME_DIR="$3"; source "$1/tests/lib/test_env.sh" >/dev/null 2>&1; printf %s "${JUPYNVIM_RUNTIME_DIR-unset}" > "$2"' \
    "$R/iso_rtd.out" "$R/elsewhere" </dev/null 2>/dev/null
  rcrtd=$?
  chk "test_env.sh does not pass on JUPYNVIM_RUNTIME_DIR (rc $rcrtd: $(cat "$R/iso_rtd.out" 2>/dev/null))" \
    test "$(cat "$R/iso_rtd.out" 2>/dev/null)" = unset

  # The caller's terminal variables stay out of the run by prefix, not by a
  # list of names: Ghostty 1.4 sets GHOSTTY_SURFACE_ID, which a fixed list
  # let into every pane, and GHOSTTY_ISO_LATER stands for a name a later
  # release adds. The run's shell has none of them and exports none.
  ( export GHOSTTY_RESOURCES_DIR=/iso/ghostty GHOSTTY_SURFACE_ID=0x1 GHOSTTY_ISO_LATER=1
    fresh_run 'source "$1/tests/lib/test_env.sh"; out=$2
      { set; env; } | grep -o "^GHOSTTY_[A-Za-z0-9_]*" | sort -u > "$out.left"
      exit 0' "$R/iso_ghostty" </dev/null 2>/dev/null )
  rcgh=$?
  chk "a caller's GHOSTTY_ variables, new names included, are unset in the run (rc $rcgh; left: $(tr '\n' ' ' < "$R/iso_ghostty.left" 2>/dev/null))" \
    test "$rcgh" = 0 -a -f "$R/iso_ghostty.left" -a ! -s "$R/iso_ghostty.left"

  # The run's umask is 022 whatever the caller's: under a caller's 002 (a
  # Linux account's default) the run's dirs would be open to the group, and
  # the backend never puts kernel files below such a dir. A run started
  # under 002 has 0022, a dir made in it is 755, and so is one of its own.
  ( umask 002
    fresh_run 'source "$1/tests/lib/test_env.sh"; out=$2
      umask > "$out.umask"
      mkdir "$out.dir"
      python3 -I -c "import os, sys; print(\" \".join(\"%o\" % (os.stat(p).st_mode & 0o777) for p in sys.argv[1:]))" \
        "$out.dir" "$JNV_RUN_ROOT/xdg" > "$out.modes"
      exit 0' "$R/iso_umask" </dev/null 2>/dev/null )
  rcum=$?
  chk "a run started under a caller's umask 002 has umask 0022 and makes dirs 755, its own too (rc $rcum; umask $(cat "$R/iso_umask.umask" 2>/dev/null); modes $(cat "$R/iso_umask.modes" 2>/dev/null))" \
    test "$rcum" = 0 -a "$(cat "$R/iso_umask.umask" 2>/dev/null)" = 0022 -a "$(cat "$R/iso_umask.modes" 2>/dev/null)" = "755 755"

  # A TERM while the run is being made ends the script with 143 and removes
  # the half made run dir.
  iso_signals=1
  fresh_run 'ISO_FAKE_LOG="$2.log" ISO_FAKE_TERM=$$ JUPYNVIM_TEST_KERNEL_PYTHON="$3"
    export ISO_FAKE_LOG ISO_FAKE_TERM JUPYNVIM_TEST_KERNEL_PYTHON
    source "$1/tests/lib/test_env.sh"
    echo made > "$2.made"; exit 0' "$R/iso_setupterm" "$R/iso_fakepy" </dev/null 2>/dev/null
  rcst=$?
  iso_signals=""
  half="$(sed -n 's/^tmp|//p' "$R/iso_setupterm.log" 2>/dev/null | head -n 1)"
  half="${half%/*}"  # that TMPDIR is the run dir's tmp
  setup_cut() { [ "$rcst" = 143 ] && [ ! -e "$R/iso_setupterm.made" ]; }
  chk "a TERM while the run is being made ends the script with 143 (rc $rcst)" setup_cut
  half_gone() { case "$half" in "$TMPDIR"/jnv.?*) gone "$half" ;; *) return 1 ;; esac; }
  chk "and removes the half made run dir (${half##*/})" half_gone

  # A script of a run that is killed before its exit hook (KILL, a tool
  # timeout) leaves its private tmux server running and its socket file in
  # tmux's dir. The run's owner stops the server when it exits, and removes
  # that socket file too, once no server answers on it. The same holds when
  # the server's record (pid and start) could not be written (here its file
  # is a dir): the server's command line, its private socket name and the
  # run's tmux.conf, ties it to the run.
  if type -P tmux >/dev/null 2>&1; then
    printf '%s\n' 'source "$1/tests/lib/tmux.sh"' \
      'echo "$_JNV_TMUX_SOCKET_PATH" > "$2.sock"; _jnv_server_pid > "$2.srv"' \
      'echo "$$" > "$2.child.part" && mv "$2.child.part" "$2.child"' \
      'exec perl -e "sleep 300" "$JNV_RUN_ROOT/iso-child"' > "$R/iso_tmuxchild.sh"
    for so_mode in recorded unrecorded; do
      fresh_run 'source "$1/tests/lib/test_env.sh"; out=$2
        echo "$JNV_RUN_ROOT" > "$out.root"
        [ "$4" = unrecorded ] && mkdir "$JNV_RUN_ROOT/tmux-sockets"
        bash "$3" "$1" "$out" </dev/null >/dev/null 2>&1 &
        c=$!
        n=0; until [ -s "$out.child" ] && [ -s "$out.srv" ]; do n=$((n + 1)); [ "$n" -ge 100 ] && break; sleep 0.1; done
        kill -KILL "$c"; wait "$c" 2>/dev/null
        [ -S "$(cat "$out.sock" 2>/dev/null)" ] && echo yes > "$out.left"
        [ -f "$JNV_RUN_ROOT/tmux-sockets" ] || echo none > "$out.record"
        exit 0' "$R/iso_sock_$so_mode" "$R/iso_tmuxchild.sh" "$so_mode" </dev/null 2>/dev/null
      rcso=$?
      so="$R/iso_sock_$so_mode"
      so_sock="$(cat "$so.sock" 2>/dev/null)"; so_srv="$(cat "$so.srv" 2>/dev/null)"
      if [ "$so_mode" = recorded ]; then
        so_what="a script killed in a run"
      else
        so_what="a script killed in a run whose server record could not be written"
        chk "($so_what: no record was written)" test "$(cat "$so.record" 2>/dev/null)" = none
      fi
      chk "$so_what leaves its tmux socket behind (rc $rcso)" \
        test "$(cat "$so.left" 2>/dev/null)" = yes
      chk "$so_what: the run's owner stops that script's tmux server when it exits" \
        poll_for 5 not cmd_has "$so_srv" "jnv-"
      chk "$so_what: and removes its socket file (${so_sock##*/})" gone "$so_sock"
      chk "$so_what: and its run dir" gone "$(cat "$so.root" 2>/dev/null)"
      # never leave them, even when failing
      stop_own "$so_srv" "jnv-"
      case "${so_sock##*/}" in jnv-?*) [ -S "$so_sock" ] && ! cmd_has "$so_srv" "jnv-" && rm -f "$so_sock" ;; esac
    done
  else
    echo "FAIL tmux missing (socket cleanup)"; FAILS=$((FAILS + 1))
  fi

  # A run whose owner is killed cleans nothing up itself. The next run made
  # in the same temp dir does: it stops that run's processes (its tmux server
  # and pane, an orphan that names its dir) and removes its socket file. A
  # section of that run that does not refer to it (an orphan in the killed
  # owner's process group, which writes into the run dir later, as nvim makes
  # its stdpath dirs and the backend its runtime dir with mkdir -p) still
  # runs, so the dir stays, owner file and all, until a later sweep finds the
  # run idle and removes it; several sweeps at once say so once. Every sweep
  # leaves alone a run whose owner still runs (the fresh dir of S5, owned by
  # this script), a dir with no owner file, a kept run (JNV_KEEP_RUN=1,
  # marked when it is made, so also when it is killed), and a process
  # someone else (this script) started that names the killed run's dir.
  if type -P tmux >/dev/null 2>&1; then
    # The kept run first: every run made sweeps at its setup, so the run
    # under test below must be the first one made after the kill.
    ( export JNV_KEEP_RUN=1
      fresh_run 'source "$1/tests/lib/test_env.sh"; echo "$JNV_RUN_ROOT" > "$2.root"
        perl -e "sleep 300" "$JNV_RUN_ROOT/iso-kept" </dev/null >/dev/null 2>&1 &
        echo "$!" > "$2.orphan"
        echo "$$" > "$2.pid.part" && mv "$2.pid.part" "$2.pid"
        wait' "$R/iso_kept" </dev/null >/dev/null 2>&1 ) &
    kept_job=$!; iso_bg "$kept_job"
    kept_root=""; kept_orphan=""
    if poll_for 30 test -s "$R/iso_kept.pid"; then
      kept_root="$(cat "$R/iso_kept.root")"; kept_orphan="$(cat "$R/iso_kept.orphan" 2>/dev/null)"
      poll_for 5 cmd_has "$kept_orphan" iso-kept
      kill -KILL "$(cat "$R/iso_kept.pid")"
    fi
    wait "$kept_job" 2>/dev/null
    fresh_run 'source "$1/tests/lib/tmux.sh"; out=$2
      echo "$JNV_RUN_ROOT" > "$out.root"; echo "$_JNV_TMUX_SOCKET_PATH" > "$out.sock"
      _jnv_server_pid > "$out.srv"
      tmux new-session -d -s doom -x 80 -y 20 "exec perl -e \"sleep 300\" $JNV_RUN_ROOT/iso-pane"
      tmux list-panes -t =doom: -F "#{pane_pid}" > "$out.pane"
      perl -e "sleep 300" "$JNV_RUN_ROOT/iso-wait" </dev/null >/dev/null 2>&1 &
      echo "$!" > "$out.wait"
      ISO_LATE_GO="$out.late.go" perl -MFile::Path=make_path -e "
        my \$n = 0; until (-e \$ENV{ISO_LATE_GO} or ++\$n > 1200) { select(undef, undef, undef, 0.1) }
        make_path(\"\$ENV{TMPDIR}/late\"); exit 0" </dev/null >/dev/null 2>&1 &
      echo "$!" > "$out.late"
      mkdir "$JNV_RUN_ROOT/iso-locked" && : > "$JNV_RUN_ROOT/iso-locked/f" && chmod 500 "$JNV_RUN_ROOT/iso-locked"
      mkdir "$JNV_RUN_ROOT/iso-sealed" && : > "$JNV_RUN_ROOT/iso-sealed/f" && chmod 000 "$JNV_RUN_ROOT/iso-sealed"
      echo "$$" > "$out.pid.part" && mv "$out.pid.part" "$out.pid"
      wait' "$R/iso_doom" </dev/null >/dev/null 2>&1 &
    doom_job=$!; iso_bg "$doom_job"
    doom_root=""; doom_sock=""; doom_srv=""; doom_pane=""; doom_wait=""; doom_late=""
    if poll_for 30 test -s "$R/iso_doom.pid"; then
      doom_root="$(cat "$R/iso_doom.root")"; doom_sock="$(cat "$R/iso_doom.sock")"
      doom_srv="$(cat "$R/iso_doom.srv")"; doom_pane="$(cat "$R/iso_doom.pane")"
      doom_wait="$(cat "$R/iso_doom.wait")"; doom_late="$(cat "$R/iso_doom.late")"
      poll_for 5 cmd_has "$doom_pane" iso-pane
      kill -KILL "$(cat "$R/iso_doom.pid")"
    fi
    wait "$doom_job" 2>/dev/null
    doom_left() {
      [ -d "$doom_root" ] && [ -S "$doom_sock" ] && cmd_has "$doom_srv" "jnv-" \
        && cmd_has "$doom_pane" iso-pane && cmd_has "$doom_wait" iso-wait && cmd_has "$doom_late" make_path
    }
    chk "a run whose shell is killed leaves its dir, tmux server, pane, orphans and socket" doom_left
    (cd / && exec perl -e 'sleep 300' "$doom_root/iso-someone-else" </dev/null >/dev/null 2>&1) &
    doom_other=$!; iso_bg "$doom_other"
    wait_cmd "$doom_other" iso-someone-else
    base_mode() { python3 -I -c 'import os, stat, sys; print("%o" % stat.S_IMODE(os.stat(sys.argv[1]).st_mode))' "$TMPDIR"; }
    mode_before="$(base_mode)"
    # the next run, in the same temp dir, while the killed run's section runs
    fresh_run 'source "$1/tests/lib/test_env.sh"; echo "$JNV_RUN_ROOT" > "$2.root"; exit 0' \
      "$R/iso_sweeper" </dev/null 2> "$R/iso_sweeper.err"
    rcsw=$?
    chk "the next run (rc $rcsw) stops the killed run's tmux server" not cmd_has "$doom_srv" "jnv-"
    chk "its pane's process" not cmd_has "$doom_pane" iso-pane
    chk "and its orphan" not cmd_has "$doom_wait" iso-wait
    chk "and removes its socket file (${doom_sock##*/})" gone "$doom_sock"
    chk "it leaves the killed run's section running (it does not refer to the run)" \
      cmd_has "$doom_late" make_path
    chk "and leaves the killed run's dir in place meanwhile, its owner file too" \
      test -f "$doom_root/owner"
    chk "and says so" grep -q "left .*/${doom_root##*/} in place" "$R/iso_sweeper.err"
    # the section ends: it makes its dir under the killed run's TMPDIR, then exits
    : > "$R/iso_doom.late.go"
    chk "the killed run's section has ended" poll_for 15 not cmd_has "$doom_late" make_path
    # Later sweeps, three at once (each run made in the temp dir sweeps it)
    sw_pids=""
    for i in 1 2 3; do
      procs_in "$fresh" sweep 2> "$R/iso_sweep$i.err" &
      sw_pids="$sw_pids $!"; iso_bg "$!"
    done
    for p in $sw_pids; do wait "$p"; done
    sw_removed="$(cat "$R"/iso_sweep[123].err 2>/dev/null | grep -c "removed .*/${doom_root##*/}, left by a run")"
    chk "once that run is idle, a later sweep removes its dir; of three at once, one says so ($sw_removed)" \
      test "$sw_removed" = 1 || sed 's/^/    sweep said: /' "$R"/iso_sweep[123].err
    # gone, under its own name and under a sweep's claim (<dir>.removing-<pid>)
    gone_all() { gone "$1" && [ -z "$(cd "${1%/*}" 2>/dev/null && ls -d "${1##*/}".removing-* 2>/dev/null)" ]; }
    chk "the killed run's dir is gone (a read-only and an unreadable dir in it too, and the dir its section made)" gone_all "$doom_root"
    chk "the temp dir around it keeps its mode ($mode_before)" test "$(base_mode)" = "$mode_before"
    # Another sweep may have removed a dir first: removing it again changes
    # nothing around it.
    gone_again() {
      python3 -I -c 'import sys; sys.dont_write_bytecode = True; sys.path.insert(0, sys.argv[1])
import run_procs
sys.exit(0 if run_procs.remove_tree(sys.argv[2]) and not run_procs.remove_run_dir(sys.argv[2]) else 1)' \
        "$REPO/tests/lib" "$doom_root" && [ "$(base_mode)" = "$mode_before" ]
    }
    chk "removing a run dir that is already gone succeeds and leaves the temp dir's mode" gone_again
    chk "a process this script started that names the killed run's dir still runs" \
      cmd_has "$doom_other" iso-someone-else
    chk "a run whose owner still runs is left alone" test -d "$fresh"
    chk "a dir with no owner file is left alone" test -d "$R/tmp/jnv.isodir"
    chk "a kept run whose shell was killed is left alone" is_dir_under "$kept_root" "$TMPDIR"
    chk "and so is the process it left" cmd_has "$kept_orphan" iso-kept
    # never leave them, even when failing
    kill "$doom_other" 2>/dev/null; wait "$doom_other" 2>/dev/null
    stop_own "$doom_srv" "jnv-"; stop_own "$doom_pane" iso-pane; stop_own "$doom_wait" iso-wait
    stop_own "$doom_late" make_path; stop_own "$kept_orphan" iso-kept
    case "${doom_sock##*/}" in jnv-?*) [ -S "$doom_sock" ] && ! cmd_has "$doom_srv" "jnv-" && rm -f "$doom_sock" ;; esac
    for d in "$doom_root" "$kept_root"; do
      case "$d" in "$TMPDIR"/jnv.?*) [ -d "$d" ] && chmod -R u+rwx "$d"; rm -rf "$d" ;; esac
    done
  else
    echo "FAIL tmux missing (sweep)"; FAILS=$((FAILS + 1))
  fi

  # A sweep removes a run dir's owner file last, after everything else in
  # it: a sweep that is cut short, or that cannot remove an entry, leaves the
  # owner file, so a later sweep can still tell whose dir it is and finish.
  # The order, recorded on a dir like a killed run's ...
  order_dir="$(mktemp -d "$TMPDIR/jnv.XXXXXXXXXX")"
  printf '1\tx\n' > "$order_dir/owner"; printf 'pgid=1\n' > "$order_dir/owner.info"
  mkdir -p "$order_dir/a" "$order_dir/z"
  for f in a/f b c zz z/g kept.x; do : > "$order_dir/$f"; done
  owner_last() {
    python3 -I -c 'import os, sys; sys.dont_write_bytecode = True; sys.path.insert(0, sys.argv[1])
import run_procs
done = []
real = os.unlink
def unlink(p, *a, **k):
    done.append(os.path.basename(p))
    return real(p, *a, **k)
os.unlink = unlink
gone = run_procs.remove_run_dir(sys.argv[2])
print(" ".join(done))
sys.exit(0 if gone and done[-2:] == ["owner.info", "owner"] and not os.path.lexists(sys.argv[2]) else 1)' \
      "$REPO/tests/lib" "$order_dir"
  }
  order_out="$(owner_last)"; order_rc=$?
  chk "a sweep removes owner.info and then the owner file last ($order_out)" test "$order_rc" = 0
  case "$order_dir" in "$TMPDIR"/jnv.?*) rm -rf "$order_dir" ;; esac
  # Only the sweep that removed a dir says so: here another sweep removes
  # it while this one is still stopping that run's processes (the three at
  # once above overlap that way only now and then).
  race_dir="$(mktemp -d "$TMPDIR/jnv.XXXXXXXXXX")"
  printf '1\tx\n' > "$race_dir/owner"; : > "$race_dir/f"
  race_out="$(JNV_RUN_ROOT="$fresh" JNV_RUN_ID="${fresh##*/jnv.}" python3 -I -c '
import os, shutil, sys
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
import run_procs
target = os.path.realpath(sys.argv[2])
real = run_procs.cleanup
def cleanup(run_):
    out = real(run_)
    if run_.real == target:
        shutil.rmtree(target)  # the other sweep is done first
    return out
run_procs.cleanup = cleanup
run_procs.cmd_sweep([])' "$REPO/tests/lib" "$race_dir" 2>&1)"
  race_said() { printf '%s\n' "$race_out" | grep -q "removed .*/${race_dir##*/}"; }
  chk "a sweep that another sweep beat to a dir does not say it removed it" not race_said
  case "$race_dir" in "$TMPDIR"/jnv.?*) rm -rf "$race_dir" ;; esac
  # A sweep claims a dead run's dir by renaming it to <dir>.removing-<pid>
  # (two rmdir calls on one dir can both succeed on macOS; two renames
  # cannot). A claimed dir is left to its sweep while that runs (here this
  # script stands in for it), and finished by the next sweep once that sweep
  # has died (here a pid that has ended).
  claim_live="$(mktemp -d "$TMPDIR/jnv.XXXXXXXXXX")"
  mv "$claim_live" "$claim_live.removing-$$" && claim_live="$claim_live.removing-$$"
  sh -c 'exit 0' & claim_gone_pid=$!; wait "$claim_gone_pid"
  claim_dead="$(mktemp -d "$TMPDIR/jnv.XXXXXXXXXX")"
  mv "$claim_dead" "$claim_dead.removing-$claim_gone_pid" && claim_dead="$claim_dead.removing-$claim_gone_pid"
  for d in "$claim_live" "$claim_dead"; do printf '1\tx\n' > "$d/owner"; : > "$d/f"; done
  procs_in "$fresh" sweep 2>/dev/null
  chk "a dir a running sweep claimed is left to it" test -f "$claim_live/owner"
  chk "a dir whose sweep has died is finished by the next sweep" gone "$claim_dead"
  for d in "$claim_live" "$claim_dead"; do
    case "$d" in "$TMPDIR"/jnv.?*) rm -rf "$d" ;; esac
  done
  # ... and a dead run with an entry that cannot be removed (macOS: a file
  # flagged immutable, which even its owner cannot remove until the flag is
  # cleared): the sweep keeps the owner file and says so, and once the
  # flag is cleared a later sweep removes the dir.
  if _jnv_darwin && type -P chflags >/dev/null 2>&1; then
    stuck="$(mktemp -d "$TMPDIR/jnv.XXXXXXXXXX")"
    printf '1\tx\n' > "$stuck/owner"; : > "$stuck/f"; : > "$stuck/immutable"
    chflags uchg "$stuck/immutable"
    procs_in "$fresh" sweep 2> "$R/iso_stuck1.err"
    chk "a sweep that cannot remove an entry keeps the run dir's owner file" test -f "$stuck/owner"
    chk "and says it could not remove all of it" grep -q "could not remove all of .*/${stuck##*/}" "$R/iso_stuck1.err"
    chflags nouchg "$stuck/immutable"
    procs_in "$fresh" sweep 2> "$R/iso_stuck2.err"
    chk "a later sweep removes it" gone "$stuck"
    case "$stuck" in "$TMPDIR"/jnv.?*) [ -e "$stuck/immutable" ] && chflags nouchg "$stuck/immutable"; rm -rf "$stuck" ;; esac
  fi

  # A run dir that its owner cannot remove whole (a dir in it made read
  # only) is reported, and the script's exit status stays, under set -e too.
  # Its owner file is removed last, so it stays, and a later sweep removes
  # the dir (making the read-only dir writable).
  fresh_run 'set -e; source "$1/tests/lib/test_env.sh"; out=$2
    echo "$JNV_RUN_ROOT" > "$out.root"
    mkdir "$JNV_RUN_ROOT/iso-locked"; : > "$JNV_RUN_ROOT/iso-locked/f"
    chmod 500 "$JNV_RUN_ROOT/iso-locked"
    exit 0' "$R/iso_locked" </dev/null 2> "$R/iso_locked.err"
  rck=$?
  locked="$(cat "$R/iso_locked.root" 2>/dev/null)"
  chk "a run dir that cannot be removed whole keeps status 0 under set -e (rc $rck)" test "$rck" = 0
  if [ -n "$locked" ] && [ -d "$locked" ]; then
    chk "and the run says it could not remove it" grep -q 'could not remove' "$R/iso_locked.err"
    chk "and keeps its owner file" test -f "$locked/owner"
    procs_in "$fresh" sweep 2>/dev/null
    chk "which a later sweep removes" gone "$locked"
    # never leave it, even when failing
    case "$locked" in "$TMPDIR"/jnv.?*) [ -d "$locked" ] && chmod -R u+w "$locked" && rm -rf "$locked" ;; esac
  else
    echo "  -- a read only dir did not stop the removal here (root?)"
  fi
fi

# ── S3 nvim ─────────────────────────────────────────────
echo "S3 nvim"
# nvim with a deadline, so a hang fails this check instead of the run
nv() { deadline 60 nvim "$@"; }
NV_PATHS=()
while IFS= read -r line; do NV_PATHS+=("$line"); done < <(
  nv --headless -u NONE \
    -c 'lua io.stdout:write(table.concat({vim.fn.stdpath("config"), vim.fn.stdpath("data"), vim.fn.stdpath("state"), vim.fn.stdpath("cache"), vim.fn.stdpath("log"), vim.fn.stdpath("run"), vim.fn.tempname(), vim.v.servername}, "\n") .. "\n")' \
    -c 'qa!' </dev/null 2>/dev/null)
chk "nvim prints eight paths (${#NV_PATHS[@]})" test "${#NV_PATHS[@]}" -eq 8
i=0
for what in 'stdpath("config")' 'stdpath("data")' 'stdpath("state")' 'stdpath("cache")' \
            'stdpath("log")' 'stdpath("run")' 'tempname()' 'v:servername'; do
  chk "nvim $what is under the run dir (${NV_PATHS[$i]:-})" is_under "${NV_PATHS[$i]:-}" "$R"
  i=$((i + 1))
done
sn="${NV_PATHS[7]:-}"
sn_short() { [ -n "$sn" ] && [ "${#sn}" -lt 100 ]; }
chk "nvim's server socket path is shorter than 100 characters (${#sn})" sn_short
if [ -n "${JNV_TS_SITE:-}" ]; then
  ts_out="$(nv --headless -u NONE \
    -c 'lua local ok, p = pcall(vim.treesitter.get_string_parser, "x=1", "python"); io.stdout:write(tostring(ok and p ~= nil) .. "\n" .. tostring(vim.api.nvim_get_runtime_file("parser/python.so", false)[1]) .. "\n")' \
    -c 'qa!' </dev/null 2>/dev/null)"
  ts_ok="$(printf '%s\n' "$ts_out" | sed -n 1p)"
  ts_so="$(printf '%s\n' "$ts_out" | sed -n 2p)"
  chk "nvim loads the python parser" test "$ts_ok" = true
  chk "the python parser comes from the run dir ($ts_so)" is_under "$ts_so" "$R"
else
  echo "  -- parsers: none"
fi

# ── S4 tmux ─────────────────────────────────────────────
echo "S4 tmux"
# The wrapper is a function, its socket name is this run's, and its text
# routes calls through that name. All checked before the first tmux call.
wrapper_ready() {
  [ "$(type -t tmux)" = function ] || return 1
  case "${JNV_TMUX_SOCKET:-}" in "jnv-${JNV_RUN_ID:-unset}-"?*) ;; *) return 1 ;; esac
  declare -f tmux | grep -q '_jnv_tmux' && declare -f _jnv_tmux | grep -q 'JNV_TMUX_SOCKET'
}
if ! type -P tmux >/dev/null 2>&1; then
  echo "FAIL tmux missing"; FAILS=$((FAILS + 1))
elif [ "$scan_safe" != 1 ] || [ "$snap_safe" != 1 ]; then
  # jnv_tmux_stop stops what run_procs.py snapshot lists
  echo "FAIL S4 not run: run_procs.py lists processes this run did not start, and stopping the tmux server acts on its list"
  FAILS=$((FAILS + 1))
elif ! source "$REPO/tests/lib/tmux.sh"; then
  echo "FAIL tests/lib/tmux.sh could not be sourced"; FAILS=$((FAILS + 1))
elif ! wrapper_ready; then
  # Never reach another server: without a wrapper bound to this run, stop here.
  echo "FAIL tests/lib/tmux.sh defines no tmux wrapper bound to this run's socket"
  FAILS=$((FAILS + 1))
else
  tmux new-session -d -s iso -x 80 -y 20
  sock="$(tmux display-message -p -t iso '#{socket_path}' 2>/dev/null)"
  wrapper_sock() { [ -n "$sock" ] && [ "${sock##*/}" = "$JNV_TMUX_SOCKET" ]; }
  chk "tmux runs on the wrapper's socket (${sock##*/})" wrapper_sock
  run_unique() { case "${sock##*/}" in "jnv-${JNV_RUN_ID:-unset}-"*) return 0 ;; esac; return 1; }
  chk "the socket name is unique to this run" run_unique
  # The run's config and nothing else: a wrapper without its -f would load
  # the user's ~/.tmux.conf (and its plugins) into the private server.
  cfg="$(tmux display-message -p '#{config_files}' 2>/dev/null)"
  chk "the server loaded only the run's tmux.conf (${cfg:-none})" test "$cfg" = "$R/tmux.conf"
  # The pane's environment, then its shell's own HISTFILE (set or not), written
  # whole and then renamed, so the reader never sees half of it.
  tmux send-keys -t iso "{ env; printf 'PANE_HISTFILE=%s\n' \"\${HISTFILE-}\"; } > '$R/iso_env.part' && mv '$R/iso_env.part' '$R/iso_env'" Enter
  chk "the pane writes its environment" jnv_wait_lines "$R/iso_env" 1
  pane_var() { sed -n "s/^$1=//p" "$R/iso_env" 2>/dev/null | head -n 1; }
  chk "the pane has SHELL=/bin/sh" grep -qx 'SHELL=/bin/sh' "$R/iso_env"
  chk "the pane has KITTY_WINDOW_ID=1" grep -qx 'KITTY_WINDOW_ID=1' "$R/iso_env"
  chk "the pane has TERM_PROGRAM=tmux" grep -qx 'TERM_PROGRAM=tmux' "$R/iso_env"
  chk "the pane's TMPDIR is under the run dir" is_under "$(pane_var TMPDIR)" "$R"
  chk "the pane's XDG_CACHE_HOME is under the run dir" is_under "$(pane_var XDG_CACHE_HOME)" "$R"
  no_ghostty() { [ -f "$R/iso_env" ] && ! grep -q '^GHOSTTY_' "$R/iso_env"; }
  chk "the pane has no GHOSTTY_ variable" no_ghostty
  chk "the pane has HISTFILE, /dev/null or under the run dir ($(pane_var HISTFILE))" \
    hist_ok "$(pane_var HISTFILE)"
  # what the pane's shell will save its history to: unset or empty saves none
  shell_hist_ok() {
    grep -q '^PANE_HISTFILE=' "$R/iso_env" 2>/dev/null || return 1
    local h; h="$(pane_var PANE_HISTFILE)"
    [ -z "$h" ] || hist_ok "$h"
  }
  chk "the pane's shell keeps its history out of HOME ($(pane_var PANE_HISTFILE))" shell_hist_ok
  chk "the pane's TMUX_TMPDIR is under the run dir ($(pane_var TMUX_TMPDIR))" \
    is_under "$(pane_var TMUX_TMPDIR)" "$R"
  # tmux run around the wrapper (no -L or -S, no TMUX), as a Python or Lua
  # test that runs the binary itself would, looks for its server in the run
  # dir and finds none: it can never reach the user's server.
  plain_sock="$(_jnv_plain_socket 2>/dev/null)"
  chk "tmux run around the wrapper looks for its server in the run dir ($plain_sock)" \
    is_under "$plain_sock" "$R"
  # A subshell that sources tests/lib/tmux.sh again gets a server of its own
  # (named after its own pid, not the parent's $$), and its exit stops that
  # server, not this script's.
  ( source "$REPO/tests/lib/tmux.sh"
    printf '%s\n%s\n' "$JNV_TMUX_SOCKET" "$_JNV_TMUX_SOCKET_PATH" > "$R/iso_subtmux" )
  sub_name="$(sed -n 1p "$R/iso_subtmux" 2>/dev/null)"; sub_path="$(sed -n 2p "$R/iso_subtmux" 2>/dev/null)"
  chk "a subshell that sources tests/lib/tmux.sh gets a server of its own (${sub_name:-none})" \
    eval '[ -n "$sub_name" ] && [ "$sub_name" != "$JNV_TMUX_SOCKET" ]'
  iso_session_up() { tmux has-session -t =iso 2>/dev/null; }
  chk "its exit leaves this script's server and session alone" iso_session_up
  chk "and stops its own server and removes its socket (${sub_path##*/})" gone "$sub_path"
  # tests/lib is bash 3.2 compatible (macOS /bin/bash runs the suite where
  # no newer bash comes first on PATH): a bash 3.2 script sources
  # tests/lib/tmux.sh, gets a working server, and a subshell of it one of
  # its own, which leaves the script's alone.
  b32=""
  case "$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null)" in 3) b32=/bin/bash ;; esac
  if [ -n "$b32" ]; then
    printf '%s\n' 'source "$1/tests/lib/tmux.sh"' \
      'tmux new-session -d -s s32 -x 40 -y 5 && echo "server ok"' \
      '( source "$1/tests/lib/tmux.sh"; echo "sub $JNV_TMUX_SOCKET" )' \
      'echo "main $JNV_TMUX_SOCKET"' \
      'tmux has-session -t =s32 2>/dev/null && echo "still ok"' > "$R/iso_b32.sh"
    out32="$(deadline 60 "$b32" "$R/iso_b32.sh" "$REPO" 2>&1)"
    b32_ok() {
      local sub main
      sub="$(printf '%s\n' "$out32" | sed -n 's/^sub //p')"; main="$(printf '%s\n' "$out32" | sed -n 's/^main //p')"
      printf '%s\n' "$out32" | grep -qx 'server ok' && printf '%s\n' "$out32" | grep -qx 'still ok' \
        && [ -n "$sub" ] && [ -n "$main" ] && [ "$sub" != "$main" ]
    }
    chk "under bash 3.2, tests/lib/tmux.sh starts a server, and a subshell gets its own ($(printf '%s' "$out32" | tr '\n' ' '))" b32_ok
  else
    echo "  -- bash 3.2: /bin/bash here is not 3.2"
  fi
  # A clean stop: the server and the pane's shell end by themselves, so the
  # stop returns 0 and adds no line to the leaks file (a process it had to
  # stop would be a LEAK there).
  leaks_file="${JNV_LEAKS_FILE:-$R/leaks}"
  leak_lines() { if [ -f "$leaks_file" ]; then wc -l < "$leaks_file" | tr -d ' '; else echo 0; fi; }
  leaks_before="$(leak_lines)"
  jnv_tmux_stop
  stop_rc=$?
  chk "jnv_tmux_stop returns 0 (rc $stop_rc)" test "$stop_rc" = 0
  chk "jnv_tmux_stop adds no LEAK line" test "$(leak_lines)" = "$leaks_before"
  chk "the socket is removed when the server stops" gone "$sock"
  server_gone() { ! tmux ls >/dev/null 2>&1; }
  chk "the server is gone (tmux ls fails)" server_gone
  # The screen tests' barriers really wait: nv_sync returns only once nvim
  # has taken every key sent before it (here a :sleep 2 still running), and
  # jnv_wait_nvim_exit only once nvim has quit (after a :sleep 2). A barrier
  # that returned at once would let a test read the screen too early. A
  # script of its own (tests/screen_lib.sh, its own tmux server) runs them.
  printf '%s\n' 'source "$1/tests/screen_lib.sh"' \
    'now() { perl -MTime::HiRes=time -e "printf q(%.2f), time"; }' \
    'took() { perl -e "exit !(\$ARGV[1] - \$ARGV[0] >= \$ARGV[2])" "$1" "$2" "$3"; }' \
    'tmux new-session -d -s "$S" -x 100 -y 20' \
    'tmux send-keys -t "$S" "nvim -u $WORK/init.lua" Enter' \
    'jnv_wait_nvim_up 20 || { echo "FAIL nvim did not start"; FAILS=$((FAILS + 1)); finish "sync barriers"; }' \
    'nv_sync' \
    't0=$(now); tmux send-keys -t "$S" ":sleep 2" Enter; nv_sync; t1=$(now)' \
    'holds "nv_sync waits for a command nvim is still running ($t0 to $t1)" "took $t0 $t1 1.8"' \
    't0=$(now); tmux send-keys -t "$S" ":sleep 2 | qa!" Enter; jnv_wait_nvim_exit 15; rc=$?; t1=$(now)' \
    'holds "jnv_wait_nvim_exit waits until nvim has quit (rc $rc, $t0 to $t1)" "[ $rc = 0 ] && took $t0 $t1 1.8"' \
    'finish "sync barriers"' > "$R/iso_sync.sh"
  sync_out="$(deadline 90 bash "$R/iso_sync.sh" "$REPO" 2>&1)"; sync_rc=$?
  if printf '%s\n' "$sync_out" | grep -q '^SKIP'; then
    echo "  -- sync barriers: $(printf '%s\n' "$sync_out" | grep '^SKIP' | head -n 1)"
  else
    printf '%s\n' "$sync_out" | grep -E '^(ok|FAIL) ' | sed 's/^/    /'
    sync_ok() { [ "$sync_rc" = 0 ] && printf '%s\n' "$sync_out" | grep -qx 'sync barriers: ALL OK'; }
    chk "nv_sync and jnv_wait_nvim_exit wait for nvim (rc $sync_rc)" sync_ok
  fi
fi

# ── S6 backend and kernel ───────────────────────────────
echo "S6 backend and kernel"
deadline 300 python3 "$REPO/tests/isolation_spec.py"
py_rc=$?
chk "the backend and its kernel stay in the run dir (isolation_spec.py rc $py_rc)" test "$py_rc" = 0

echo
if [ "$FAILS" -eq 0 ]; then
  echo "ALL ISOLATION CHECKS PASSED"
  iso_exit 0
fi
echo "$FAILS ISOLATION CHECKS FAILED"
iso_exit 1

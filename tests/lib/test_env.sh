# shellcheck shell=bash
# The per-run test environment. Every test script sources it first:
#
#   source "$(dirname "$0")/lib/test_env.sh"
#
# The first source in a process tree makes a fresh run dir in the caller's
# temp dir (mktemp, never inside the repo) and points every location a test,
# nvim, the backend, a kernel, IPython, matplotlib or tmux writes to into it:
# TMPDIR, the XDG dirs, the Jupyter and IPython dirs, the matplotlib cache,
# the backend log, the shell and Python histories and the dir of tmux's
# default server (TMUX_TMPDIR, so tmux run around tests/lib/tmux.sh never
# reaches the user's server). Children inherit the environment and reuse
# that run, so one run is one dir and two runs never share a path. The
# user's own state is never written; it is read only to copy the python3
# kernelspec, the matplotlib font cache and the treesitter parsers (on macOS
# the backend also still lists the user's kernelspecs). The caller's Python
# startup file, Python path and matplotlib backend do not reach the run.
#
# The shell that made the run is its owner: its pid and start go in
# $JNV_RUN_ROOT/owner, its process group in $JNV_RUN_ROOT/owner.info. Only
# processes the run provably started are ever stopped
# (tests/lib/run_procs.py has the rule); a process someone else started that
# merely refers to the run dir (a tail -F on a log in it) is left alone.
# When the owner exits it stops what is left of the run, removes the run's
# tmux socket files and removes the dir, its owner file last; while a
# process under the owner still runs (one that does not refer to the run,
# so it is not stopped) the dir stays. A run whose owner was killed before
# it could do all that is cleaned up the same way by the next run made in
# the same temp dir (run_procs.py sweep), which never touches a run whose
# owner still runs, a kept run or a dir with no owner file.
#
# It also gives the run its own python3 kernelspec (the one the backend would
# find, copied), seeds the matplotlib font cache and the treesitter parsers
# (copies, never links into the user's dirs), and pins one terminal identity
# whatever the host: Kitty graphics, xterm-256color, /bin/sh, a UTF-8 locale.
#
# Exports: JNV_REPO, JNV_RUN_ROOT, JNV_RUN_ID, JNV_RUN_REPO,
# JNV_RUN_ENV_READY, JNV_KERNEL_PYTHON, JNV_KERNEL_SPEC_SRC, JNV_TS_SITE,
# JNV_TMUX_TMPDIR (the caller's own TMUX_TMPDIR, kept for the private
# servers of tests/lib/tmux.sh) and the locations above. Files:
# $JNV_RUN_ROOT/owner, owner.info, tmux.conf, leaks, kept (JNV_KEEP_RUN=1)
# and tmux-sockets (tests/lib/tmux.sh). Functions: jnv_on_exit (below) and
# jnv_proc_ident PID (the start that identifies a process, as
# tests/lib/run_procs.py reads it). Knobs: JUPYNVIM_TEST_KERNEL_PYTHON (the
# kernel's python), JUPYNVIM_TEST_TS_SITE (a site dir to copy parsers from,
# or "none"), JNV_KEEP_RUN=1 (keep the run dir, killed or not: it is marked
# kept when the run is made, and a kept dir is never swept).
#
# jnv_on_exit CMD adds an exit hook: one line of shell, run when the script
# exits, the last added first. INT exits 130, TERM 143 and HUP 129, so the
# hooks run then too, and the script's exit status is kept. bash runs such a
# trap only once the command it waits for in the foreground has returned: a
# signal sent to the script's pid alone (not to its process group, as a
# terminal's Ctrl-C or hangup is) takes effect when that command ends, which
# in run_all.sh can be minutes. So stop a suite by its process group, or
# give it that time after a TERM: a KILL that follows too soon leaves the
# run behind, until the next run's setup sweeps it. Each hook runs in a
# subshell of its own: exit, return or break in it (or in a helper it calls),
# a failure under set -e (as in a plain EXIT trap) or an unset variable under
# set -u ends that hook and nothing else, and it may read the script's stdin.
# An INT, TERM or HUP while the hooks run does not cut them short. So a hook
# cannot change the script's variables or working dir, and cannot list
# (jobs) or wait for the script's background processes: record their pids
# as they start. Last of all, the shell that made the run stops what is left
# of it and removes the run dir. Scripts never set an EXIT trap of their own
# (it would replace the hooks).
#
# Bash 3.2 compatible and safe under set -u.

# ── exit hooks, once per shell ──────────────────────────
# The guard names the shell that installed the hooks (its pid and subshell
# level), so a new bash process, or a subshell (bash resets its EXIT trap),
# installs its own even though the guard reached it. A subshell starts with
# no hooks and owns no run: the hooks and the run dir of the shell it came
# from are not its to run or remove.
if [ "${_JNV_HOOKS:-}" != "$$.${BASH_SUBSHELL:-0}" ]; then
  _JNV_HOOKS="$$.${BASH_SUBSHELL:-0}"
  _JNV_EXIT_HOOKS=""
  JNV_OWNS_ROOT=""
  _JNV_OWNED_ROOT=""
  jnv_on_exit() {
    if [ -z "${1:-}" ]; then
      echo "jnv_on_exit: needs a command (one line of shell)" >&2
      return 2
    fi
    _JNV_EXIT_HOOKS="$1"$'\n'"$_JNV_EXIT_HOOKS"
  }
  _jnv_exit() {
    _jnv_rc=$?
    # Nothing a hook does cuts the rest short. From here on an INT, TERM or
    # HUP to this shell runs ':' and the hooks go on (set before the EXIT
    # trap is cleared, so no signal lands between the two), while the
    # subshells start with the default actions (a subshell resets a trap
    # that runs a command, but keeps one set to ''), so a Ctrl-C ends only
    # the hook that is running.
    trap ':' INT TERM HUP
    trap - EXIT
    # Each hook runs in a subshell, so exit, return, a failure under set -e
    # or an unset variable under set -u ends only that subshell, and the
    # one-pass loop makes break and continue end it too in every bash
    # version. set -e is off in this shell, so a failed hook never ends it,
    # and each subshell turns it back on when the script had it. A hook is a
    # plain command, never the left side of || or &&, where bash ignores
    # set -e in everything it runs: so under set -e a failed command ends
    # its hook, as it ends a plain EXIT trap. The list comes in on fd 9,
    # which the hooks do not get, so a hook that reads stdin cannot eat the
    # rest.
    case $- in *e*) _jnv_e=1 ;; *) _jnv_e="" ;; esac
    set +e
    while IFS= read -r _jnv_h <&9; do
      [ -n "$_jnv_h" ] || continue
      ( [ -z "$_jnv_e" ] || set -e; for _jnv_once in 1; do eval "$_jnv_h"; done ) 9<&-
    done 9<<_JNV_HOOKS_END
$_JNV_EXIT_HOOKS
_JNV_HOOKS_END
    # Last, in this shell: the owner stops what is left of its run and
    # removes the run dir (nothing when this shell made no run).
    _jnv_cleanup_root
    exit "$_jnv_rc"
  }
  trap _jnv_exit EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  # HUP like TERM: untrapped, bash would run the exit hooks at once while
  # the command in the foreground keeps running, and remove the run dir
  # under a test that is still running.
  trap 'exit 129' HUP
fi

# ── setup ───────────────────────────────────────────────
# _jnv_setup makes the run. Its locals (base, orig_*) are seen by the
# functions it calls (bash scoping is dynamic): orig_* are the caller's
# values, recorded before anything is changed.

_jnv_darwin() { case "${OSTYPE:-}" in darwin*) return 0 ;; esac; return 1; }

# _jnv_remove_root: remove the owned run dir, only when it is an absolute
# path whose last part is a run dir name; JNV_KEEP_RUN=1 keeps it. All of it
# but the owner files first, then owner.info, then owner, then the dir: a
# removal that is cut short (a KILL now) or that fails leaves the owner
# file, so the next run's sweep finishes it. A dir that cannot be removed
# whole is reported, never an error, so the script's own exit status stays.
_jnv_remove_root() {
  local r="${_JNV_OWNED_ROOT:-}" own="" info=""
  [ -n "$r" ] || return 0
  case "$r" in /*) ;; *) return 0 ;; esac
  case "${r##*/}" in jnv.?*) ;; *) return 0 ;; esac
  if [ "${JNV_KEEP_RUN:-}" = 1 ]; then
    # marked when the run was made, so no sweep removes it, killed or not
    : > "$r/kept" 2>/dev/null
    echo "run dir kept: $r" >&2
    return 0
  fi
  [ -d "$r" ] || return 0
  IFS= read -r own < "$r/owner" 2>/dev/null
  info="$(cat "$r/owner.info" 2>/dev/null)"
  if find "$r" -mindepth 1 -maxdepth 1 ! -name owner ! -name owner.info -exec rm -rf {} + 2>/dev/null \
    && [ -z "$(find "$r" -mindepth 1 -maxdepth 1 ! -name owner ! -name owner.info 2>/dev/null)" ]; then
    rm -f "$r/owner.info" "$r/owner"
    rmdir "$r" 2>/dev/null && return 0
    # an entry appeared after the check: the owner files go back (owner
    # last), so the next run's sweep can still tell whose dir this is
    if [ -d "$r" ] && [ -n "$own" ]; then
      if [ -n "$info" ]; then printf '%s\n' "$info" > "$r/owner.info"; fi
      printf '%s\n' "$own" > "$r/owner"
    fi
  fi
  echo "test env: could not remove the run dir $r (the next run made in ${r%/*} removes it)" >&2
}

# Run by _jnv_exit last, in the shell that made the run (no other shell has
# _JNV_OWNED_ROOT set): stop every process of the run that is still there,
# remove the run's tmux socket files no server answers on (a script killed
# before its own tmux stop leaves one), then remove the dir, unless a
# process under this shell still runs (cleanup exits 3): it may still write
# into the dir, so the dir stays for the next run's sweep.
_jnv_cleanup_root() {
  local r="${_JNV_OWNED_ROOT:-}" rc=0
  [ -n "$r" ] || return 0
  JNV_RUN_ROOT="$r" JNV_RUN_ID="${r##*/jnv.}" \
    python3 -I "$JNV_REPO/tests/lib/run_procs.py" cleanup >/dev/null 2>&1 || rc=$?
  if [ "$rc" = 3 ] && [ "${JNV_KEEP_RUN:-}" != 1 ] && [ -d "$r" ]; then
    echo "test env: left the run dir $r in place: a process this run started still runs; the next run made in ${r%/*} removes it once that process has ended" >&2
    return 0
  fi
  _jnv_remove_root
}

# _jnv_proc_info PID: set _JNV_PI_START to the start that identifies PID and
# _JNV_PI_PGID to its process group; 1 when PID is not running. The start is
# what tests/lib/run_procs.py compares: on Linux the start in clock ticks
# since boot (/proc/PID/stat; a step of the wall clock does not move it),
# elsewhere the start time ps prints, in the C locale and UTC so that every
# reader gets the same text.
_jnv_proc_info() {
  local s
  _JNV_PI_START=""
  _JNV_PI_PGID=""
  case "${OSTYPE:-}" in
    linux*)
      IFS= read -r s < "/proc/$1/stat" 2>/dev/null || return 1
      s="${s##*) }"  # the fields after the command name: state first
      # shellcheck disable=SC2086
      set -- $s
      [ "$#" -ge 20 ] || return 1
      _JNV_PI_PGID="$3"
      _JNV_PI_START="${20}"
      ;;
    *)
      s="$(LC_ALL=C TZ=UTC0 ps -o pgid=,lstart= -p "$1" 2>/dev/null)" || return 1
      # shellcheck disable=SC2086
      set -- $s
      [ "$#" -ge 6 ] || return 1
      _JNV_PI_PGID="$1"
      shift
      _JNV_PI_START="$*"
      ;;
  esac
  case "$_JNV_PI_PGID" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$_JNV_PI_START" ]
}

# jnv_proc_ident PID: the start that identifies a running PID (see above)
jnv_proc_ident() { _jnv_proc_info "$1" && printf '%s\n' "$_JNV_PI_START"; }

# _jnv_owner_line PID: "PID<TAB>start" of a running PID; 1 when it is not
_jnv_owner_line() { _jnv_proc_info "$1" && printf '%s\t%s\n' "$1" "$_JNV_PI_START"; }

# _jnv_my_pid: set _JNV_MY_PID to this shell's own pid, also in a subshell:
# BASHPID where bash has it, else the parent of a child it starts (bash 3.2
# has no BASHPID, and $$ is the parent shell's pid in a subshell). The child
# writes to a file in the run dir, never to a pipe: in $(...) its parent
# would be the subshell that reads the pipe.
_jnv_my_pid() {
  local f
  if [ -n "${BASHPID:-}" ]; then
    _JNV_MY_PID="$BASHPID"
    return 0
  fi
  f="$JNV_RUN_ROOT/.pid.$$.$RANDOM$RANDOM"
  sh -c 'echo "$PPID"' > "$f" && IFS= read -r _JNV_MY_PID < "$f"
  set -- "$?"
  rm -f "$f"
  return "$1"
}

# _jnv_write_owner: record this shell as the owner of the run just made: its
# own pid (also in a subshell) and start in owner, its process group (and on
# Linux the ticks of a process started right before the run dir) in
# owner.info. Each written whole, then renamed, owner last, so a sweep in
# another run never reads half of one, and owner.info is there whenever
# owner is.
_jnv_write_owner() {
  local o="$JNV_RUN_ROOT/owner" i="$JNV_RUN_ROOT/owner.info"
  _jnv_my_pid && _jnv_proc_info "$_JNV_MY_PID" || return 1
  {
    printf 'pgid=%s\n' "$_JNV_PI_PGID"
    if [ -n "${_JNV_BORN_TICKS:-}" ]; then printf 'born=%s\n' "$_JNV_BORN_TICKS"; fi
  } > "$i.part" && mv -f "$i.part" "$i" || return 1
  printf '%s\t%s\n' "$_JNV_MY_PID" "$_JNV_PI_START" > "$o.part" && mv -f "$o.part" "$o"
}

# _jnv_sweep BASE: clean up the runs in BASE whose owner is gone (see the
# header). Python (run_procs.py sweep, which checks every owner again) starts
# only when another run dir names an owner that is not running as the same
# process; kill -0 sends no signal, it only asks whether the pid exists.
_jnv_sweep() {
  local d pid ls line tab=$'\t'
  for d in "$1"/jnv.?*; do
    [ "$d" != "$JNV_RUN_ROOT" ] && [ -f "$d/owner" ] && [ ! -e "$d/kept" ] || continue
    IFS= read -r line < "$d/owner" 2>/dev/null || continue
    pid="${line%%"$tab"*}"; ls="${line#*"$tab"}"
    case "$pid" in ''|*[!0-9]*) continue ;; esac  # the sweep skips it too
    if kill -0 "$pid" 2>/dev/null && [ "$(_jnv_owner_line "$pid")" = "$pid$tab$ls" ]; then
      continue  # its owner still runs
    fi
    python3 -I "$JNV_REPO/tests/lib/run_procs.py" sweep || true
    return 0
  done
  return 0
}

# _jnv_find_spec: print the python3 kernel.json the backend would pick, in
# the order of core/src/kernelspec.rs search_dirs (first found wins), with
# the caller's original environment.
_jnv_find_spec() {
  local rest="$orig_jpath" d
  while [ -n "$rest" ]; do
    d="${rest%%:*}"
    case "$rest" in *:*) rest="${rest#*:}" ;; *) rest="" ;; esac
    if [ -n "$d" ] && [ -f "$d/kernels/python3/kernel.json" ]; then
      printf '%s\n' "$d/kernels/python3/kernel.json"
      return 0
    fi
  done
  set -- "$HOME/Library/Jupyter/kernels"
  if _jnv_darwin; then
    set -- "$@" "$HOME/Library/Application Support/jupyter/kernels"
  else
    set -- "$@" "$orig_data/jupyter/kernels"
  fi
  [ -n "$orig_conda" ] && set -- "$@" "$orig_conda/share/jupyter/kernels"
  [ -n "$orig_venv" ] && set -- "$@" "$orig_venv/share/jupyter/kernels"
  set -- "$@" /usr/share/jupyter/kernels /usr/local/share/jupyter/kernels \
    /opt/homebrew/share/jupyter/kernels
  for d in "$@"; do
    if [ -f "$d/python3/kernel.json" ]; then
      printf '%s\n' "$d/python3/kernel.json"
      return 0
    fi
  done
  return 0
}

# _jnv_provision_kernel: the run's own python3 kernelspec, so the suite runs
# the interpreter the backend would pick on this machine, and still finds a
# kernel with the XDG dirs moved.
_jnv_provision_kernel() {
  local dst="$JUPYTER_PATH/kernels/python3/kernel.json" src="" py="" given=""
  mkdir -p "${dst%/*}" || return 1
  if [ -n "${JUPYNVIM_TEST_KERNEL_PYTHON:-}" ]; then
    py="$JUPYNVIM_TEST_KERNEL_PYTHON"
  else
    src="$(_jnv_find_spec)"
    if [ -n "$src" ]; then
      py="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["argv"][0])' "$src" 2>/dev/null)"
      if [ -z "$py" ]; then
        echo "test env: cannot read the interpreter (argv[0]) of $src" >&2
        return 1
      fi
    else
      py="$(type -P python3)"
    fi
  fi
  given="$py"
  # A relative interpreter is resolved now, so the kernel runs the python
  # checked here whatever PATH a test sets later.
  case "$py" in
    /*) ;;
    */*) py="$(CDPATH='' cd "$(dirname "$py")" 2>/dev/null && pwd)/${py##*/}" ;;
    *) py="$(type -P "$py")" ;;
  esac
  if [ -z "$py" ]; then
    echo "test env: ${given:-python3} is not on PATH, so the python3 kernel cannot start; set JUPYNVIM_TEST_KERNEL_PYTHON to a python that has ipykernel" >&2
    return 1
  fi
  if [ -n "$src" ] && [ "$py" = "$given" ]; then
    cp "$src" "$dst" || return 1
  elif [ -n "$src" ]; then
    python3 -I -c 'import json,sys
s = json.load(open(sys.argv[1]))
s["argv"][0] = sys.argv[3]
with open(sys.argv[2], "w") as f:
    json.dump(s, f, indent=1)' "$src" "$dst" "$py" || return 1
  else
    python3 -I -c 'import json,sys
with open(sys.argv[1], "w") as f:
    json.dump({"argv": [sys.argv[2], "-m", "ipykernel_launcher", "-f", "{connection_file}"],
               "display_name": "Python 3", "language": "python"}, f, indent=1)' "$dst" "$py" || return 1
  fi
  # One check of everything the suite's kernel needs, from the installed
  # package metadata instead of imports (importing the five takes about
  # 0.36 s, the metadata check about 0.05 s, and every test run pays it).
  # No -I here: an interpreter may keep these in its user site.
  if ! (cd / && "$py" -c 'import sys, importlib.metadata as m
try:
    v = [m.version(n) for n in ("ipykernel", "numpy", "matplotlib", "tqdm", "ipywidgets")]
except m.PackageNotFoundError:
    sys.exit(1)
sys.exit(int(v[-1].split(".")[0]) < 8)') >/dev/null 2>&1; then
    echo "test env: $py does not have ipykernel, numpy, matplotlib, tqdm and ipywidgets 8 or later installed, which the suite's kernel needs; set JUPYNVIM_TEST_KERNEL_PYTHON to a python that has them" >&2
    return 1
  fi
  JNV_KERNEL_PYTHON="$py"
  JNV_KERNEL_SPEC_SRC="${src:-synthesized}"
  export JNV_KERNEL_PYTHON JNV_KERNEL_SPEC_SRC
}

# _jnv_seed_mpl: copy matplotlib's font cache (never matplotlibrc); a fresh
# one costs about 15 s, longer than a test waits for its first plot.
_jnv_seed_mpl() {
  local src f n=0
  if [ -n "$orig_mpl" ]; then
    src="$orig_mpl"
  else
    case "${OSTYPE:-}" in
      linux*|freebsd*) src="$orig_cache/matplotlib" ;;
      *) src="$HOME/.matplotlib" ;;
    esac
  fi
  for f in "$src"/fontlist-v*.json; do
    [ -f "$f" ] || continue
    cp "$f" "$MPLCONFIGDIR/" && n=$((n + 1))
  done
  if [ "$n" -eq 0 ] && (cd / && "$JNV_KERNEL_PYTHON" -c 'import importlib.util,sys; sys.exit(importlib.util.find_spec("matplotlib") is None)') >/dev/null 2>&1; then
    echo "test env: building the matplotlib font cache for the test kernel" >&2
    (cd / && "$JNV_KERNEL_PYTHON" -c 'import matplotlib.font_manager') >/dev/null 2>&1 || true
  fi
  return 0
}

# _jnv_seed_parsers: copy the treesitter parsers and queries nvim would load
# (links dereferenced, dead links skipped; clones where the file system can).
_jnv_seed_parsers() {
  local site="${JUPYNVIM_TEST_TS_SITE:-$orig_data/nvim/site}" d e dst
  JNV_TS_SITE=""
  export JNV_TS_SITE
  if [ "$site" = none ] || [ ! -d "$site/parser" ]; then
    return 0
  fi
  for d in parser parser-info queries; do
    dst="$XDG_DATA_HOME/nvim/site/$d"
    mkdir -p "$dst" || return 1
    set --
    for e in "$site/$d"/*; do
      [ -e "$e" ] && set -- "$@" "$e"
    done
    [ "$#" -gt 0 ] || continue
    if _jnv_darwin; then
      cp -cRL "$@" "$dst/" 2>/dev/null || cp -RL "$@" "$dst/"
    else
      cp -RL --reflink=auto "$@" "$dst/" 2>/dev/null || cp -RL "$@" "$dst/"
    fi || echo "test env: some of $site/$d could not be copied" >&2
  done
  JNV_TS_SITE="$site"
}

# _jnv_fill_run: everything after the run dir exists; 1 on the first failure.
_jnv_fill_run() {
  local R="$JNV_RUN_ROOT" loc
  # The run's umask is 022 whatever the caller's: under a Linux account's
  # default 002 the run's dirs would be open to the group, and the backend
  # never puts kernel files below such a dir (the suite would fail there).
  # Everything the run starts inherits it.
  umask 022
  mkdir -p "$R/tmp" "$R/xdg/config" "$R/xdg/data" "$R/xdg/state" "$R/xdg/cache/jupynvim" \
    "$R/run" "$R/jupyter/config" "$R/jupyter/data" "$R/jupyter/runtime" "$R/jupyter/path" \
    "$R/ipython" "$R/mpl" || return 1
  chmod 700 "$R/run" || return 1

  JNV_RUN_REPO="$JNV_REPO"
  export JNV_RUN_ROOT JNV_RUN_ID JNV_RUN_REPO
  export TMPDIR="$R/tmp"
  export XDG_CONFIG_HOME="$R/xdg/config" XDG_DATA_HOME="$R/xdg/data"
  export XDG_STATE_HOME="$R/xdg/state" XDG_CACHE_HOME="$R/xdg/cache"
  export XDG_RUNTIME_DIR="$R/run"
  export XDG_CONFIG_DIRS=/etc/xdg XDG_DATA_DIRS=/usr/local/share:/usr/share
  export JUPYTER_CONFIG_DIR="$R/jupyter/config" JUPYTER_DATA_DIR="$R/jupyter/data"
  export JUPYTER_RUNTIME_DIR="$R/jupyter/runtime" JUPYTER_PATH="$R/jupyter/path"
  export IPYTHONDIR="$R/ipython" MPLCONFIGDIR="$R/mpl"
  export JUPYNVIM_LOG_DIR="$R/xdg/cache/jupynvim"
  # The panes and :terminal run an interactive sh, which saves its history.
  export HISTFILE="$R/sh_history"
  # An interactive python saves its history when it exits: Python 3.13 and
  # later here, an older one into $HOME/.python_history (no test runs one;
  # the isolation spec gives the one it runs a HOME in the run).
  export PYTHON_HISTORY="$R/python_history"
  # tmux run around tests/lib/tmux.sh (a Python or Lua test that runs the
  # binary itself) looks for its default server in the run, so it can never
  # reach the user's server; tmux.conf below gives the panes the same. The
  # private servers of tests/lib/tmux.sh keep the caller's own socket dir
  # (JNV_TMUX_TMPDIR, inherited by nested runs): a socket path has room for
  # only 103 bytes, which a run dir nested in another run's TMPDIR exceeds.
  [ -n "${JNV_TMUX_TMPDIR+set}" ] || JNV_TMUX_TMPDIR="${TMUX_TMPDIR:-}"
  export JNV_TMUX_TMPDIR TMUX_TMPDIR="$R"

  # Ghostty's variables go by their prefix, not a list of names: each release
  # can add one (1.4 sets GHOSTTY_SURFACE_ID), and the panes must see none.
  local gv
  for gv in $(compgen -v GHOSTTY_); do unset "$gv"; done
  # The caller's terminal, nvim and jupynvim settings stay out of the run (a
  # JUPYNVIM_RUNTIME_DIR would move the run's connection files out of it).
  unset TMUX TMUX_PANE TERM_PROGRAM TERM_PROGRAM_VERSION TERMINFO \
    KITTY_PID KITTY_PUBLIC_KEY KITTY_INSTALLATION_DIR KITTY_LISTEN_ON \
    WEZTERM_EXECUTABLE WEZTERM_EXECUTABLE_DIR WEZTERM_CONFIG_FILE WEZTERM_CONFIG_DIR \
    WEZTERM_PANE WEZTERM_UNIX_SOCKET ITERM_SESSION_ID ITERM_PROFILE \
    LC_TERMINAL LC_TERMINAL_VERSION NVIM NVIM_LISTEN_ADDRESS NVIM_LOG_FILE NVIM_APPNAME \
    VIMINIT MYVIMRC VIMRUNTIME ENV BASH_ENV JUPYNVIM_TTY JUPYNVIM_CURSOR_STORE \
    JUPYNVIM_FORCE_KITTY_IN_TMUX JUPYNVIM_DISABLE_TMUX_PASSTHROUGH \
    JUPYNVIM_NATIVE JUPYNVIM_RELEASE_BASE JUPYNVIM_RUNTIME_DIR
  # The caller's Python and matplotlib settings stay out of every python the
  # run starts, kernels included: a startup file runs in every kernel (and
  # may save history into HOME), a path or home can swap the modules a test
  # imports, the rest change what Python does or prints, and a matplotlib
  # backend or rc file overrides the inline backend that makes plots into
  # image outputs. PYTHONUSERBASE stays: an interpreter may keep ipykernel
  # in its user site.
  unset PYTHONSTARTUP PYTHONPATH PYTHONHOME PYTHONSAFEPATH PYTHONINSPECT \
    PYTHONOPTIMIZE PYTHONWARNINGS PYTHONVERBOSE PYTHONDEBUG PYTHONDEVMODE \
    PYTHONBREAKPOINT PYTHONPYCACHEPREFIX PYTHONEXECUTABLE PYTHONIOENCODING PYTHONUTF8 \
    MPLBACKEND MATPLOTLIBRC JUPYTER_CONFIG_PATH JUPYTER_PREFER_ENV_PATH JUPYTER_PLATFORM_DIRS
  export SHELL=/bin/sh TERM=xterm-256color COLORTERM=truecolor KITTY_WINDOW_ID=1
  export PYTHONDONTWRITEBYTECODE=1
  loc="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
  case "$loc" in
    *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) ;;
    *) if _jnv_darwin; then export LC_ALL=en_US.UTF-8; else export LC_ALL=C.UTF-8; fi ;;
  esac

  _jnv_provision_kernel || return 1
  _jnv_seed_mpl || return 1
  _jnv_seed_parsers || return 1
  printf '%s\n' 'set -g default-shell /bin/sh' 'set -g default-command /bin/sh' \
    'set -g status off' 'set -g allow-passthrough on' 'set -g history-limit 5000' \
    > "$R/tmux.conf" || return 1
  # a server takes its environment from the client that starts it, which
  # tests/lib/tmux.sh gives the caller's socket dir; the panes get the run's
  # (single quotes: tmux expands nothing in them)
  case "$R" in
    *"'"*) ;;
    *) printf "set-environment -g TMUX_TMPDIR '%s'\n" "$R" >> "$R/tmux.conf" || return 1 ;;
  esac
}

_jnv_setup() {
  local base orig_data orig_cache orig_mpl orig_jpath orig_conda orig_venv s
  _JNV_BORN_TICKS=""
  case "${OSTYPE:-}" in
    linux*)
      # the start, in ticks since boot, of a process started right before
      # the run dir: run_procs.py takes a process that started at or after
      # it for one that started after the run dir, with no wall clock
      s="$(cat /proc/self/stat 2>/dev/null)"
      s="${s##*) }"
      # shellcheck disable=SC2086
      set -- $s
      if [ "$#" -ge 20 ]; then _JNV_BORN_TICKS="${20}"; fi
      ;;
  esac
  base="${TMPDIR:-}"
  [ -n "$base" ] || base="$(dirname "$(mktemp -u)")"
  case "$base" in /*) ;; *) base="$(CDPATH='' cd "$base" 2>/dev/null && pwd)" ;; esac
  [ -n "$base" ] || return 1
  orig_data="${XDG_DATA_HOME:-$HOME/.local/share}"
  orig_cache="${XDG_CACHE_HOME:-$HOME/.cache}"
  orig_mpl="${MPLCONFIGDIR:-}"
  orig_jpath="${JUPYTER_PATH:-}"
  orig_conda="${CONDA_PREFIX:-}"
  orig_venv="${VIRTUAL_ENV:-}"

  JNV_RUN_ROOT="$(mktemp -d "${base%/}/jnv.XXXXXXXXXX")" || return 1
  [ -n "$JNV_RUN_ROOT" ] && [ -d "$JNV_RUN_ROOT" ] || return 1
  JNV_RUN_ID="${JNV_RUN_ROOT##*/jnv.}"
  # Shell-local: only this shell removes the dir; children never own it.
  # From here on _jnv_exit calls _jnv_cleanup_root, after every hook, so an
  # interrupted setup leaves nothing behind either.
  JNV_OWNS_ROOT=1
  _JNV_OWNED_ROOT="$JNV_RUN_ROOT"
  export -n JNV_OWNS_ROOT _JNV_OWNED_ROOT 2>/dev/null

  # A kept run is marked now, so even a run that is killed is never swept.
  if [ "${JNV_KEEP_RUN:-}" = 1 ]; then
    : > "$JNV_RUN_ROOT/kept" || echo "test env: could not mark $JNV_RUN_ROOT kept" >&2
  fi
  # The owner first: before it, nothing of the run exists to be stopped.
  if _jnv_write_owner && _jnv_fill_run; then
    export JNV_RUN_ENV_READY=1
    _jnv_sweep "${base%/}"
    return 0
  fi
  _jnv_remove_root
  JNV_OWNS_ROOT=""
  _JNV_OWNED_ROOT=""
  return 1
}

# ── this run ────────────────────────────────────────────
# Always recomputed from this file's place, never inherited.
JNV_REPO="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export JNV_REPO

if [ "${JNV_RUN_ENV_READY:-}" = 1 ] && [ "${JNV_RUN_REPO:-}" = "$JNV_REPO" ] \
  && [ -n "${JNV_RUN_ROOT:-}" ] && [ -d "$JNV_RUN_ROOT" ]; then
  :  # a parent made this run: reuse it
else
  _jnv_setup || { echo "test env: setup failed" >&2; exit 2; }
fi

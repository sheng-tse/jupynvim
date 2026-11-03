# shellcheck shell=bash
# tmux for the screen tests, on a private server of this script's own.
#
#   source "$(dirname "$0")/lib/tmux.sh"
#
# It sources tests/lib/test_env.sh (the per-run environment) and SKIPs the
# script (exit 0) when there is no tmux. Every plain `tmux ...` line of the
# script then goes through the tmux function below, which talks to the
# server jnv-<run id>-<pid of the shell that sourced this file> with the
# run's config ($JNV_RUN_ROOT/tmux.conf: /bin/sh in the panes, no status
# line, passthrough on). So the script never reaches the user's server or
# another run's, a session name can never match a session of someone
# else's, and the panes get the run's environment, not the one a server
# started elsewhere had. A subshell that sources this file again gets a
# server of its own, which its exit stops. Never call the tmux binary any
# other way, and never give it -L, -S or -f; tmux run around the wrapper
# looks for its server in the run dir (TMUX_TMPDIR) and finds none.
#
# The server starts right here and stays up with no session at all
# (exit-empty off) until the script exits, when jnv_tmux_stop stops it and
# removes its socket file (tmux leaves that behind). The server takes the
# script's environment as it is now, when this file is sourced, and every
# pane gets that environment: export what a pane needs before sourcing it.
# The socket path, the server's pid and its start are recorded in
# $JNV_RUN_ROOT/tmux-sockets (by the subshell that starts the server, so a
# KILL of the script alone does not stop the record), so a server that
# outlives a script killed before its exit hook is still the run's: it is
# stopped, and its socket removed, by the run's owner (or, when the owner
# was killed too, by the next run's setup).
#
#   jnv_stop_session [NAME]   stop session NAME (default $S) and wait until
#                             every process that ran in it is gone
#   jnv_tmux_stop             the same for the whole server, then its socket
#                             file; it runs on exit by itself (jnv_on_exit)
#   jnv_wait_nvim_exit [SECS] the pane of $S no longer runs nvim (default 15)
#   jnv_wait_nvim_up [SECS]   the pane of $S runs nvim (default 20)
#   jnv_wait_lines FILE N [SECS]       FILE has at least N lines (15)
#   jnv_wait_file_eq FILE VALUE [SECS] FILE holds exactly VALUE (20)
#
# The waits poll every 0.1 s and return 0 as soon as the condition holds, 1
# at the timeout. A process still running 10 s after its session or the
# server was stopped is stopped by tests/lib/run_procs.py, written to
# $JNV_RUN_ROOT/leaks and printed as a LEAK line, and the stop returns 1.
# A script counts that as a failure: it checks what jnv_stop_session returns
# and calls jnv_tmux_stop itself before its verdict (the exit hook's stop
# cannot change the exit status; screen_lib.sh does both). Sessions are named
# exactly: =NAME for a session, =NAME: for its window or pane (a bare NAME,
# or =NAME where a window is meant, can pick another session).

source "$(dirname "${BASH_SOURCE[0]}")/test_env.sh"
type -P tmux >/dev/null 2>&1 || { echo "SKIP $(basename "$0"): no tmux"; exit 0; }

# Named after this shell's own pid (also in a subshell, where $$ is the
# parent's): two shells never share a server, and one never stops another's.
_jnv_my_pid || { echo "FAIL $(basename "$0"): cannot read this shell's pid"; exit 1; }
JNV_TMUX_SOCKET="jnv-${JNV_RUN_ID}-${_JNV_MY_PID}"
# The private server's socket goes in the caller's own socket dir (tmux's
# default for the caller), not the run's TMUX_TMPDIR, whose deeper path a
# socket name may not fit in.
_jnv_tmux() { TMUX_TMPDIR="${JNV_TMUX_TMPDIR:-}" command tmux -u -L "$JNV_TMUX_SOCKET" "$@"; }
tmux() { _jnv_tmux -f "$JNV_RUN_ROOT/tmux.conf" "$@"; }
_jnv_procs() { python3 -I "$JNV_REPO/tests/lib/run_procs.py" "$@"; }

# _jnv_poll SECS CMD...: CMD every 0.1 s until it succeeds; 1 on timeout.
# SECONDS is bash's own clock (whole seconds), so a poll costs no fork for
# the time.
_jnv_poll() {
  local end=$((SECONDS + $1)); shift
  while :; do
    "$@" && return 0
    [ "$SECONDS" -ge "$end" ] && return 1
    sleep 0.1
  done
}

# jnv_stop_session [NAME]: the process trees of the session's panes are
# recorded (pid and start time), the session is killed, and the call returns
# once every recorded process has ended (1 when one had to be stopped).
jnv_stop_session() {
  local s="${1:-${S:-}}" pids snap
  [ -n "$s" ] || return 0
  pids="$(tmux list-panes -s -t "=$s:" -F '#{pane_pid}' 2>/dev/null)"
  [ -n "$pids" ] || return 0
  # shellcheck disable=SC2086
  snap="$(_jnv_procs snapshot $pids)"
  tmux kill-session -t "=$s" 2>/dev/null
  printf '%s\n' "$snap" | _jnv_procs reap --timeout 10 --label "$(basename "$0") session $s"
}

_jnv_server_pid() { tmux display-message -p '#{pid}' 2>/dev/null; }
_jnv_server_gone() { [ -z "$(_jnv_server_pid)" ]; }

# jnv_tmux_stop: the same for every pane of the server and the server
# itself; then the socket file, once no server answers on it.
jnv_tmux_stop() {
  local pids snap rc=0 p="${_JNV_TMUX_SOCKET_PATH:-}"
  pids="$(tmux list-panes -a -F '#{pane_pid}' 2>/dev/null; _jnv_server_pid)"
  if [ -n "$pids" ]; then
    # shellcheck disable=SC2086
    snap="$(_jnv_procs snapshot $pids)"
    _jnv_tmux kill-server 2>/dev/null
    printf '%s\n' "$snap" | _jnv_procs reap --timeout 10 --label "$(basename "$0") tmux server" || rc=1
  fi
  if [ -n "$p" ] && [ "${p##*/}" = "$JNV_TMUX_SOCKET" ] && [ -S "$p" ]; then
    if _jnv_poll 5 _jnv_server_gone; then
      rm -f "$p"
    else
      echo "tmux: the server on $p did not stop" >&2
      rc=1
    fi
  fi
  return "$rc"
}

# _jnv_plain_socket: the socket a tmux client run around the wrapper (no -L
# or -S, no TMUX) would use with this environment, as tmux itself reports it;
# tmux is not run at all unless TMUX_TMPDIR is the run dir or a dir in it,
# so this never reaches the user's server. env is a program of its own, so
# it runs the tmux binary from PATH and never this file's tmux function
# (command is a shell builtin, not a program on every system).
_jnv_plain_socket() {
  case "${TMUX_TMPDIR:-}" in
    "$JNV_RUN_ROOT"|"$JNV_RUN_ROOT"/*) ;;
    *) echo "(TMUX_TMPDIR is ${TMUX_TMPDIR:-unset}, not in the run)"; return 1 ;;
  esac
  env -u TMUX tmux ls 2>&1 \
    | sed -n -e 's/^no server running on //p' -e 's/^error connecting to \(.*\) ([^)]*)$/\1/p' \
    | head -n 1
}

# Start the server now and keep it up with no session, so stopping the last
# session never ends it and its pid and socket path are always known. The
# subshell that starts it also records it (path, pid, start), before it
# prints the path, so the record is made even if this script is killed now.
# Inside that subshell no case statement and no comment: bash 3.2 misreads
# a case pattern, or a quote in a comment, inside a command substitution.
_JNV_TMUX_SOCKET_PATH="$(
  out="$(tmux start-server \; set-option -g exit-empty off \; \
    display-message -p '#{pid} #{socket_path}' 2>&1)" || { printf '%s\n' "$out"; exit 1; }
  out="${out##*$'\n'}"
  pid="${out%% *}"
  [ -n "$pid" ] && [ -z "${pid//[0-9]/}" ] || { printf '%s\n' "$out"; exit 1; }
  path="${out#* }"
  printf '%s\t%s\t%s\n' "$path" "$pid" "$(jnv_proc_ident "$pid")" >> "$JNV_RUN_ROOT/tmux-sockets"
  printf '%s\n' "$path")" || {
  echo "FAIL $(basename "$0"): tmux could not start its server: $_JNV_TMUX_SOCKET_PATH"
  exit 1
}
jnv_on_exit jnv_tmux_stop

# What the pane of session $S runs in the foreground: nvim, or the shell
# once nvim quit. No such session prints nothing.
_jnv_pane_cmd() { tmux display-message -p -t "=${S:-}:" '#{pane_current_command}' 2>/dev/null; }
_jnv_nvim_gone() { [ "$(_jnv_pane_cmd)" != nvim ]; }
_jnv_nvim_runs() { [ "$(_jnv_pane_cmd)" = nvim ]; }
jnv_wait_nvim_exit() { _jnv_poll "${1:-15}" _jnv_nvim_gone; }
jnv_wait_nvim_up() { _jnv_poll "${1:-20}" _jnv_nvim_runs; }

_jnv_has_lines() {
  local n
  [ -f "$1" ] || return 1
  n="$(wc -l < "$1" 2>/dev/null)" || return 1
  n="${n//[!0-9]/}"
  [ "${n:-0}" -ge "$2" ]
}
# the whole file (read stops at its end), one trailing newline ignored
_jnv_file_is() {
  local v=""
  [ -f "$1" ] || return 1
  IFS= read -r -d '' v < "$1" 2>/dev/null
  [ "${v%$'\n'}" = "$2" ]
}
jnv_wait_lines() { _jnv_poll "${3:-15}" _jnv_has_lines "$1" "$2"; }
jnv_wait_file_eq() { _jnv_poll "${3:-20}" _jnv_file_is "$1" "$2"; }

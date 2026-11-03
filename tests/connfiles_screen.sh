#!/usr/bin/env bash
# Kernel connection files on a real screen: a real nvim under tmux opens a
# notebook, runs its cell, and then ends in one of four ways. Each time, no
# kernel of that nvim may still run and no connection file may be left,
# neither in the runtime dir ($XDG_RUNTIME_DIR/jupynvim) nor in the old
# location ($TMPDIR/jupynvim).
#
#   1. :qa              nvim quits; the backend stops its kernel and
#                       removes its dir
#   2. closed terminal  the tmux session is killed, so the pane hangs up
#   3. killed backend   kill -9 of the backend: the kernel guard process
#                       stops the kernel and removes the dir, and nvim keeps
#                       the notebook on screen
#   4. killed nvim      kill -9 of nvim: the backend reads the end of its
#                       input and exits as after :qa
#
# Each case records the backend, its kernel, the kernel guard process, the
# backend's dir and the connection file the kernel was given (its -f
# argument, which must exist while the kernel runs), then waits for all of
# it to be gone: the kernel, the guard and the backend no longer run, the
# dir and the file are removed, and no other connection file is left in
# either place. What is still there at the timeout is named in the FAIL
# line, and the kernel and the guard are then stopped by pid (after their
# command lines are checked again), so the next case starts clean.
#
#   bash tests/connfiles_screen.sh
#
# Standalone: it sources tests/lib/tmux.sh (the run env and a private tmux
# server), not screen_lib.sh. The cell runs only once nvim reports the kernel
# started, and every case that signals nvim, or the tmux session, first waits
# until nvim has taken a command (a barrier), so the signal never lands while
# nvim waits inside a blocking call.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/core/target/release/jupynvim-core"
[ -x "$BIN" ] || { echo "SKIP connfiles_screen: build core first ($BIN)"; exit 0; }
source "$ROOT/tests/lib/tmux.sh"

# Under the run's TMPDIR (macOS mktemp ignores TMPDIR for -t or no template)
WORK="$(mktemp -d "$TMPDIR/jupynvim_connf.XXXXXX")"
S="jupy_connf_$$"
# the server first, so no nvim is left to write into WORK as it goes
cleanup() { jnv_tmux_stop; rm -rf "$WORK"; }
jnv_on_exit cleanup
FAILS=0
RT="$XDG_RUNTIME_DIR/jupynvim"
LEGACY="$TMPDIR/jupynvim"

fail() { echo "FAIL $1"; FAILS=$((FAILS + 1)); }

cat > "$WORK/init.lua" <<LUA
vim.opt.runtimepath:prepend("$ROOT")
vim.o.swapfile = false
require("jupynvim").setup({ core_path = "$BIN", auto_venv = false })
local function put(name, s)
  local f = io.open("$WORK/" .. name .. ".tmp", "w"); f:write(s); f:close()
  os.rename("$WORK/" .. name .. ".tmp", "$WORK/" .. name)
end
function _G.__sync(n) put("sync", tostring(n)) end
-- Writes "N started" to kernel once the notebook's kernel start has
-- answered, "N error" when it failed, "N timeout" after 30 s; checked every
-- 0.1 s on the main loop, so nothing else waits for it.
function _G.__await_kernel(n)
  local buf, tries, t = vim.api.nvim_get_current_buf(), 0, vim.uv.new_timer()
  t:start(0, 100, vim.schedule_wrap(function()
    if t:is_closing() then return end
    tries = tries + 1
    local nb = require("jupynvim.notebook").get(buf)
    local st = nb and (nb.kernel_started == true and "started" or (nb.kernel_error and "error")) or nil
    if st or tries > 300 then
      t:stop(); t:close()
      put("kernel", n .. " " .. (st or "timeout"))
    end
  end))
end
LUA

# One code cell. Its source holds 'conn' + 'ok', so connok appears on the
# screen only once the kernel ran it.
cat > "$WORK/nb.ipynb" <<'JSON'
{"cells": [{"cell_type": "code", "id": "c1", "metadata": {}, "execution_count": null,
            "outputs": [], "source": "print('conn' + 'ok')"}],
 "metadata": {"kernelspec": {"name": "python3", "display_name": "Python 3", "language": "python"}},
 "nbformat": 4, "nbformat_minor": 5}
JSON
SRC="'conn' + 'ok'"

# poll SECS CMD...: CMD every 0.1 s until it succeeds, for at least SECS
# seconds (counted in polls, so a slow check only makes the wait longer);
# 1 on timeout.
poll() {
  local n=$(($1 * 10)); shift
  while :; do
    "$@" && return 0
    [ "$n" -gt 0 ] || return 1
    n=$((n - 1))
    sleep 0.1
  done
}
on_screen() { tmux capture-pane -p -t "=$S:" 2>/dev/null | grep -qF -- "$1"; }
cmd_of() { ps -ww -o command= -p "$1" 2>/dev/null; }
# alive PID: PID runs (a zombie, which only waits for its parent to read its
# status, does not)
alive() {
  local st
  st="$(ps -o stat= -p "$1" 2>/dev/null)"
  st="${st//[[:space:]]/}"
  [ -n "$st" ] && [ "${st#Z}" = "$st" ]
}
is_core() { case "$1" in *" --guard "*) return 1 ;; "$BIN"|"$BIN "*) return 0 ;; esac; return 1; }

# launch LABEL: nvim on nb.ipynb in a new session $S, the last one stopped
launch() {
  jnv_stop_session "$S" || fail "$1: the last session did not stop cleanly (LEAK above)"
  tmux new-session -d -s "$S" -x 160 -y 40
  tmux set-option -t "=$S:" status off
  tmux send-keys -t "=$S:" "cd $WORK && XDG_STATE_HOME=$WORK/state nvim -u $WORK/init.lua nb.ipynb" Enter
  poll 20 on_screen "$SRC" || { fail "$1: the notebook was not on screen within 20s"; return 1; }
}

# nv_sync: a barrier. It types :lua __sync(N) and waits until nvim wrote N,
# so every key sent before it has been taken and nvim is back in its main
# loop. Normal mode only.
SYNC_N=0
nv_sync() {
  SYNC_N=$((SYNC_N + 1))
  tmux send-keys -t "=$S:" ":lua __sync($SYNC_N)" Enter
  jnv_wait_file_eq "$WORK/sync" "$SYNC_N" 20
}

# run_cell LABEL: once the kernel started, run the cell, wait for its
# output, then the barrier
KERNEL_N=0
KERNEL_V=""
kernel_answered() {
  KERNEL_V=""
  [ -f "$WORK/kernel" ] || return 1
  IFS= read -r KERNEL_V < "$WORK/kernel" || true
  case "$KERNEL_V" in "$KERNEL_N "*) return 0 ;; esac
  return 1
}
run_cell() {
  KERNEL_N=$((KERNEL_N + 1))
  tmux send-keys -t "=$S:" ":lua __await_kernel($KERNEL_N)" Enter
  poll 35 kernel_answered || true
  if [ "$KERNEL_V" != "$KERNEL_N started" ]; then
    fail "$1: the kernel did not start (nvim said: ${KERNEL_V:-nothing within 35s})"
    return 1
  fi
  tmux send-keys -t "=$S:" ":JupynvimRunCell" Enter
  poll 30 on_screen connok || { fail "$1: the cell did not print connok within 30s"; return 1; }
  nv_sync || { fail "$1: nvim did not take a command within 20s"; return 1; }
}

# find_core: the backend nvim started in the pane of $S, breadth first
# through the pane's process tree (children by parent pid), 6 levels down
CORE=""
find_core() {
  local queue next p c level=0
  CORE=""
  queue="$(tmux display-message -p -t "=$S:" '#{pane_pid}' 2>/dev/null)"
  while [ -n "$queue" ] && [ "$level" -lt 6 ]; do
    next=""
    for p in $queue; do
      for c in $(pgrep -P "$p"); do
        if is_core "$(cmd_of "$c")"; then CORE="$c"; return 0; fi
        next="$next $c"
      done
    done
    queue="$next"
    level=$((level + 1))
  done
  return 1
}

# conn_arg CMDLINE: the connection file a kernel command line names
# (-f FILE or --f=FILE)
conn_arg() {
  local prev="" w words
  [ -n "$1" ] || return 1
  read -r -a words <<< "$1"
  for w in "${words[@]}"; do
    case "$prev" in -f|--f) printf '%s\n' "$w"; return 0 ;; esac
    case "$w" in -f=*|--f=*) printf '%s\n' "${w#*=}"; return 0 ;; esac
    prev="$w"
  done
  return 1
}

# record LABEL: CORE, KP (its kernel), GP (its kernel guard process), BD (its
# backend dir under RT), CF (the kernel's connection file) and the command
# lines of CORE, KP and GP, into $WORK/case.log and on stdout. Each must be
# found, and CF must be in BD, or the checks after it would look at nothing.
KP=""; GP=""; BD=""; CF=""; CORE_CMD=""; KP_CMD=""; GP_CMD=""
record() {
  local c cmd d
  KP=""; GP=""; BD=""; CF=""; CORE_CMD=""; KP_CMD=""; GP_CMD=""
  find_core || { fail "$1: no backend ($BIN) under the pane"; return 1; }
  CORE_CMD="$(cmd_of "$CORE")"
  for c in $(pgrep -P "$CORE"); do
    cmd="$(cmd_of "$c")"
    case "$cmd" in
      *" --guard "*) GP="$c"; GP_CMD="$cmd" ;;
      *ipykernel_launcher*) KP="$c"; KP_CMD="$cmd" ;;
    esac
  done
  for d in "$RT"/core-*-"$CORE"-*; do
    if [ -d "$d" ] && [ ! -L "$d" ]; then BD="$d"; fi
  done
  CF="$(conn_arg "$KP_CMD")"
  printf '%s: backend %s, kernel %s, guard %s, dir %s, file %s\n' "$1" "$CORE" "${KP:-none}" \
    "${GP:-none}" "${BD:-none}" "${CF:-none}" | tee -a "$WORK/case.log" | sed 's/^/  /'
  [ -n "$KP" ] || { fail "$1: no kernel under the backend $CORE"; return 1; }
  [ -n "$GP" ] || { fail "$1: no kernel guard under the backend $CORE"; return 1; }
  [ -n "$BD" ] || { fail "$1: no backend dir of $CORE in $RT"; return 1; }
  [ -n "$CF" ] && [ -f "$CF" ] || {
    fail "$1: the kernel's connection file (${CF:-no -f argument}) is not there while it runs"
    return 1
  }
  case "$CF" in
    "$BD"/kernel-*/connection.json) ;;
    *) fail "$1: the kernel's connection file $CF is not in the backend dir $BD"; return 1 ;;
  esac
}

# left: what of the recorded case is still there, one line each
left() {
  local f seen=" "
  if [ -n "$CORE" ] && alive "$CORE"; then echo "backend $CORE still runs"; fi
  if [ -n "$KP" ] && alive "$KP"; then echo "kernel $KP still runs"; fi
  if [ -n "$GP" ] && alive "$GP"; then echo "kernel guard $GP still runs"; fi
  if [ -n "$BD" ] && { [ -e "$BD" ] || [ -L "$BD" ]; }; then echo "backend dir $BD"; fi
  for f in "$CF" "$RT"/core-*/kernel-*/connection.json "$LEGACY"/kernel-*.json; do
    [ -n "$f" ] && { [ -e "$f" ] || [ -L "$f" ]; } || continue
    case "$seen" in *" $f "*) continue ;; esac
    seen="$seen$f "
    echo "connection file $f"
  done
}
gone_all() { [ -z "$(left)" ]; }

# stop_pid PID CMDLINE: kill -9 PID when it still runs CMDLINE
stop_pid() {
  [ -n "$1" ] && [ -n "$2" ] || return 0
  [ "$(cmd_of "$1")" = "$2" ] || return 0
  kill -9 "$1" 2>/dev/null
}

# check_gone LABEL SECS: everything the case recorded is gone within SECS
check_gone() {
  local what
  if poll "$2" gone_all; then
    echo "  ok $1: kernel, kernel guard, backend and connection files gone within $2s"
    return 0
  fi
  what="$(left | paste -s -d ';' -)"
  fail "$1: still there ${2}s later: ${what//;/; }"
  stop_pid "$KP" "$KP_CMD"
  stop_pid "$GP" "$GP_CMD"
  stop_pid "$CORE" "$CORE_CMD"
  return 1
}

quit_nvim() {
  tmux send-keys -t "=$S:" Escape
  tmux send-keys -t "=$S:" ":qa!" Enter
  jnv_wait_nvim_exit 15 || fail "$1: nvim did not quit within 15s of :qa!"
}

echo "connection files on a real screen (runtime dir $RT)"

# 1. :qa
case_qa() {
  local L=":qa"
  launch "$L" && run_cell "$L" && record "$L" || return
  quit_nvim "$L"
  check_gone "$L" 5
}

# 2. a closed terminal: the session is killed and the pane hangs up
case_closed() {
  local L="closed terminal"
  launch "$L" && run_cell "$L" && record "$L" || return
  jnv_stop_session "$S" || fail "$L: a process had to be stopped (LEAK above)"
  check_gone "$L" 5
}

# 3. a killed backend: nvim keeps the notebook on screen
case_backend() {
  local L="killed backend"
  launch "$L" && run_cell "$L" && record "$L" || return
  is_core "$(cmd_of "$CORE")" || { fail "$L: $CORE is not the backend any more"; return; }
  kill -9 "$CORE"
  check_gone "$L" 3
  if [ "$(tmux display-message -p -t "=$S:" '#{pane_current_command}' 2>/dev/null)" = nvim ] \
    && on_screen "$SRC"; then
    echo "  ok $L: nvim still shows the notebook"
  else
    fail "$L: nvim no longer shows the notebook"
  fi
  quit_nvim "$L"
}

# 4. a killed nvim: the backend reads the end of its input
case_nvim() {
  local L="killed nvim" nv
  launch "$L" && run_cell "$L" && record "$L" || return
  nv="$(ps -o ppid= -p "$CORE" 2>/dev/null)"
  nv="${nv//[[:space:]]/}"
  # this test's nvim: it runs this test's init.lua
  case "$(cmd_of "$nv")" in
    *nvim*" -u $WORK/init.lua "*) ;;
    *) fail "$L: the backend's parent (${nv:-none}) is not this test's nvim"; return ;;
  esac
  kill -9 "$nv"
  check_gone "$L" 5
  jnv_stop_session "$S" || fail "$L: a process had to be stopped (LEAK above)"
}

case_qa
case_closed
case_backend
case_nvim

jnv_stop_session "$S" || fail "the last session did not stop cleanly (LEAK above)"
if [ -e "$LEGACY" ] || [ -L "$LEGACY" ]; then
  fail "the old location $LEGACY exists: $(ls -A "$LEGACY" 2>/dev/null | head -n 5 | paste -s -d ' ' -)"
fi
jnv_tmux_stop || fail "the tmux server did not stop cleanly (LEAK above)"
echo "connfiles screen: $FAILS failure(s)"
[ "$FAILS" -eq 0 ]

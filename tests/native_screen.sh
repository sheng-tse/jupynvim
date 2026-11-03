#!/usr/bin/env bash
# libjupynvim, the in-process library, in a real nvim under tmux, and the
# files it ships as.
#
#   N1  the artifact checker (tests/lib/native_artifact.py): its self-test,
#       then the library cargo built for this host
#   N2  tests/native/abi_check.c loads the library the way LuaJIT does and
#       checks its C ABI; control: it fails on a fake with the wrong ABI
#   N3  typed text shows at once while a 1.5 s job runs on a worker thread;
#       control: the same wait on the UI thread holds typing back
#   N4  a panic in a call and in a job comes back as a message: nothing on
#       stderr (control: a line Lua writes there is seen) or on the screen
#   N5  :qa! with a 10 s job running: nvim is gone within 1 s
#   N6  with the library missing, the notebook draws exactly as with it,
#       and nothing on screen or in :messages mentions the library
#   N7  each one-line notice at 80x24 (the loader's for a file that does
#       not load and for one of another version, the background install's
#       refusals at a startup open): no hit-enter prompt, typing goes on
#       (control: a notice one character over the room does stop there)
#
#   bash tests/native_screen.sh
set -u
source "$(dirname "$0")/screen_lib.sh"

case "$(uname -s)" in Darwin) EXT=dylib ;; *) EXT=so ;; esac
LIB="$ROOT/core/target/release/libjupynvim.$EXT"
FAKE="$ROOT/core/target/release/examples/libjnv_fake.$EXT"
VERSION="$(sed -n 's/^version *= *"\([^"]*\)".*/\1/p' "$ROOT/core/Cargo.toml" | head -n 1)"
for f in "$LIB" "$FAKE"; do
  if [ ! -f "$f" ]; then
    echo "FAIL native screen: $f is not built: cd core && cargo build --release && cargo build --release --examples"
    exit 1
  fi
done

# Jobs for the cases. A result reaches a file through a tmp file and a
# rename, so a reader never sees half of it.
cat >> "$WORK/init.lua" <<LUA
local function __put(name, text)
  local f = io.open("$WORK/" .. name .. ".tmp", "w"); f:write(text); f:close()
  os.rename("$WORK/" .. name .. ".tmp", "$WORK/" .. name)
end
_G.__native_put = __put
-- SLEEP on a worker thread; its callback writes ok to sleep_done
function _G.__native_sleep(ms)
  local N = require("jupynvim.native")
  return N.submit(N.KIND.SLEEP, N.u32(ms), {}, function(ok) __put("sleep_done", ok and "ok" or "failed") end)
end
-- the same SLEEP on the UI thread
function _G.__native_sleep_sync(ms)
  local N = require("jupynvim.native")
  return N.call(N.KIND.SLEEP, N.u32(ms))
end
-- a PANIC in a call and in a job; both messages, one per line, to panic_msgs
function _G.__native_panics()
  local N = require("jupynvim.native")
  local _, m1 = N.call(N.KIND.PANIC, "boom")
  N.submit(N.KIND.PANIC, "boom", {}, function(_, m2)
    __put("panic_msgs", tostring(m1) .. "\n" .. tostring(m2) .. "\n")
  end)
end
LUA

send() { tmux send-keys -t "=$S:" "$@"; }
cap() { tmux capture-pane -p -t "=$S:"; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
# the text of a __rec call, once nvim has run it
rec() { rm -f "$WORK/rec"; send ":lua __rec($1)" Enter; nv_sync; cat "$WORK/rec" 2>/dev/null; }
since() { perl -e "printf '%.3f', $(now) - $1"; }
# poll_screen TEXT N [SECS]: capture the screen up to N times, 0.02 s apart,
# and, given SECS, no later than SECS after T0; 0 as soon as TEXT shows.
# POLLS is the number of captures taken, SEEN_AT the seconds from T0 to the
# capture that showed TEXT.
poll_screen() {
  POLLS=0; SEEN_AT=""
  while [ "$POLLS" -lt "$2" ]; do
    POLLS=$((POLLS + 1))
    if cap | grep -qF "$1"; then SEEN_AT="$(since "$T0")"; return 0; fi
    if [ -n "${3:-}" ] && perl -e "exit !($(now) - $T0 > $3)"; then return 1; fi
    sleep 0.02
  done
  return 1
}
# edit_mode: Vim's normal mode inside the selected cell. A notebook opens in
# its command mode, where i only opens the cell for editing; two Escapes
# reach command mode from insert or edit mode, then Enter opens the cell.
edit_mode() {
  send Escape; send Escape
  nv_sync
  send Enter
  nv_sync
  [ "$(rec "tostring(vim.bo.modifiable) .. ' ' .. vim.api.nvim_get_mode().mode")" = "true n" ] \
    || fail_later "the cell did not open for editing"
}
# the rows of the notebook's frame: from the first ╭ to the last ╰
frame() { awk '/╭/ && !s { s = 1 } s { row[++n] = $0; if (/╰/) last = n } END { for (i = 1; i <= last; i++) print row[i] }'; }
# The screen once it stopped changing: two captures 1 s apart are equal.
# The first cell's top border is a virtual line above line 1, which the
# view after an open may leave scrolled out (winrestview's topfill does not
# reach it); scrolling up shows it, so both launches show the same rows.
settled() {
  send ":lua vim.cmd('normal! ' .. vim.keycode('5<C-y>'))" Enter
  nv_sync
  local a b
  b="$(cap)"
  for _ in $(seq 1 30); do
    sleep 1
    a="$b"; b="$(cap)"
    [ "$a" = "$b" ] && break
  done
  printf '%s\n' "$b"
}

# launch_with ENVSTR [FILE]: nvim in a fresh session of $S with ENVSTR in
# its environment and its stderr in $WORK/stderr. With FILE, once the
# notebook shows; without, once nvim runs. Then once it takes a command.
# The terminal is NS_X columns by NS_Y rows (default 200x50).
launch_with() {
  local envs="$1" file="${2:-}" up=0
  rm -f "$WORK/rec"
  stop_session
  tmux new-session -d -s "$S" -x "${NS_X:-200}" -y "${NS_Y:-50}"
  send "cd $WORK && $envs XDG_STATE_HOME=$WORK/state nvim -u $WORK/init.lua $file 2>$WORK/stderr" Enter
  if [ -n "$file" ]; then
    for _ in $(seq 1 100); do
      sleep 0.2
      if cap | grep -q "a1 = 1"; then up=1; break; fi
    done
    [ "$up" = 1 ] || fail_later "the notebook did not show within 20s ($envs nvim $file)"
  else
    jnv_wait_nvim_up 20 || fail_later "nvim did not start within 20s ($envs nvim)"
  fi
  nv_sync
}
# quit nvim and wait until its pane runs the shell again
quit_nvim() {
  send Escape; send Escape; send ":qa!" Enter
  jnv_wait_nvim_exit 15 || fail_later "nvim did not quit within 15s of :qa!"
}

# ── N1 the artifact checker ─────────────────────────────
echo "-- N1 the artifact checker"
out="$(python3 -I "$ROOT/tests/lib/native_artifact.py" --self-test 2>&1)"; rc=$?
printf '%s\n' "$out" | tail -n 1
holds "N1 native_artifact.py --self-test passes (rc $rc)" '[ "$rc" -eq 0 ]'
[ "$rc" -eq 0 ] || printf '%s\n' "$out" | grep -v '^ok '
out="$(python3 -I "$ROOT/tests/lib/native_artifact.py" "$LIB" --host 2>&1)"; rc=$?
printf '%s\n' "$out"
holds "N1 native_artifact.py passes the library built for this host (rc $rc)" \
  '[ "$rc" -eq 0 ] && printf "%s\n" "$out" | grep -qx "ALL ARTIFACT CHECKS PASSED"'

# ── N2 the C ABI, loaded as LuaJIT loads it ─────────────
echo "-- N2 the C ABI"
# The system's compiler. An active conda env (run_all.sh has one from
# section 2 on) puts its own cc and ld first on PATH and exports compiler
# variables for them, and that linker cannot read this system's SDK; so the
# compile runs without those variables and without the env's bin dirs.
sys_path() {
  local d out="" IFS=:
  for d in $PATH; do
    case "$d" in
      "${CONDA_PREFIX:-/no conda prefix}"/*|*/conda*/*|*/miniconda*/*|*/anaconda*/*|*/miniforge*/*|*/mambaforge*/*) ;;
      *) out="${out:+$out:}$d" ;;
    esac
  done
  printf '%s' "$out"
}
LDL=""; [ "$(uname -s)" = Linux ] && LDL="-ldl"
CCPATH="$(sys_path)"
cout="$(env -u CC -u CXX -u LD -u LDFLAGS -u CFLAGS -u CPPFLAGS -u SDKROOT -u CONDA_BUILD_SYSROOT \
  PATH="$CCPATH" cc -std=gnu99 -Wall -Wextra -Werror -I "$ROOT/core/native/include" \
  "$ROOT/tests/native/abi_check.c" -o "$WORK/abi_check" $LDL 2>&1)"; rc=$?
echo "   compiler: $(PATH="$CCPATH" command -v cc)"
holds "N2 abi_check compiles against the header with -Werror (rc $rc)" '[ "$rc" -eq 0 ]'
[ "$rc" -eq 0 ] || printf '%s\n' "$cout"
out="$("$WORK/abi_check" "$LIB" "$VERSION" 2>&1)"; rc=$?
printf '%s\n' "$out" | grep -v '^ok '
holds "N2 abi_check passes the library, version $VERSION (rc $rc)" \
  '[ "$rc" -eq 0 ] && printf "%s\n" "$out" | grep -qx "ALL ABI CHECKS PASSED"'
out="$(JNV_FAKE=abi_major "$WORK/abi_check" "$FAKE" 2>&1)"; rc=$?
holds "N2 control: abi_check fails the fake with JNV_FAKE=abi_major (rc $rc)" \
  '[ "$rc" -ne 0 ] && printf "%s\n" "$out" | grep -q "^FAIL ABI major 1"'

# ── N3 typing while a job runs ──────────────────────────
echo "-- N3 typing while a job runs"
make_nb plain
launch_with "" nb.ipynb
av="$(rec "tostring(require('jupynvim.native').available())")"
holds "N3 the library loads in this nvim ($av)" '[ "$av" = true ]'
edit_mode
rm -f "$WORK/sleep_done"
T0="$(now)"
send ":lua __native_sleep(1500)" Enter
send -l "ihello native"
shown=0; early=0
if poll_screen "hello native" 25; then
  shown=1
  [ -e "$WORK/sleep_done" ] || early=1
fi
echo "   typed text: shown=$shown at poll $POLLS, ${SEEN_AT:-never} s after the keys; job still running then: $early"
holds "N3 typed text shows within 25 polls of 0.02 s and 0.5 s while a 1.5 s job runs" \
  '[ "$shown" = 1 ] && [ "$early" = 1 ] && perl -e "exit !($SEEN_AT < 0.5)"'
jnv_wait_file_eq "$WORK/sleep_done" ok 10
holds "N3 the job then completes (sleep_done is ok)" '[ "$(cat "$WORK/sleep_done" 2>/dev/null)" = ok ]'
# control: the same wait on the UI thread, the same window
edit_mode
T0="$(now)"
send ":lua __native_sleep_sync(1500)" Enter
send -l "ihello blocked"
blocked=1
poll_screen "hello blocked" 25 0.5 && blocked=0
echo "   control: shown=$((1 - blocked)) after $POLLS polls, $(since "$T0") s after the keys"
holds "N3 control: with the 1.5 s job on the UI thread the typed text is not shown within the same window" \
  '[ "$blocked" = 1 ]'
later=0
poll_screen "hello blocked" 1000 5 && later=1
echo "   control: shown at ${SEEN_AT:-never} s after the keys"
holds "N3 control: and it shows within 5 s, once the UI thread is free" '[ "$later" = 1 ]'

# ── N4 panics stay silent ───────────────────────────────
echo "-- N4 panics"
edit_mode
rm -f "$WORK/panic_msgs"
send ":lua __native_panics()" Enter
jnv_wait_lines "$WORK/panic_msgs" 2 10
holds "N4 the call's and the job's panic messages both arrive" \
  '[ "$(grep -c "jnv test panic: boom" "$WORK/panic_msgs" 2>/dev/null)" = 2 ]'
send ':lua io.stderr:write("STDERR-CONTROL\n")' Enter
nv_sync
holds "N4 control: a line Lua writes to stderr reaches $WORK/stderr" 'grep -q "STDERR-CONTROL" "$WORK/stderr"'
holds "N4 stderr has no \"panicked\" and no \"jnv test panic\"" \
  '! grep -q "panicked" "$WORK/stderr" && ! grep -q "jnv test panic" "$WORK/stderr"'
holds "N4 the screen has no \"panicked\"" '! cap | grep -q "panicked"'
T0="$(now)"
send -l "iecho still"
holds "N4 typing still echoes" 'poll_screen "echo still" 1000 5'

# ── N5 :qa! with a long job running ─────────────────────
echo "-- N5 :qa! with a 10 s job running"
quit_nvim
launch_with ""
send ":lua __native_sleep(10000)" Enter
nv_sync
pend="$(rec "debug.getregistry().jupynvim_native.ctx:pending_count()")"
holds "N5 the 10 s job is running (pending $pend)" '[ "$pend" = 1 ]'
# the process that runs Lua (the server) and the one in the pane (the UI),
# when they are two; both must be gone
pids="$(rec "vim.fn.getpid() .. ' ' .. vim.uv.os_getppid()")"
srv="${pids% *}"; ui="${pids#* }"
[ "$(ps -p "$ui" -o comm= 2>/dev/null | sed 's|.*/||')" = nvim ] || ui=""
echo "   server pid $srv, ui pid ${ui:-(same process)}"
alive() { local p; for p in "$@"; do ps -p "$p" >/dev/null 2>&1 && return 0; done; return 1; }
t0="$(now)"
send ":qa!" Enter
jnv_wait_nvim_exit 5
gone=0
for _ in $(seq 1 250); do
  # shellcheck disable=SC2086
  if ! alive $srv $ui; then gone=1; break; fi
  sleep 0.02
done
dt="$(perl -e "printf '%.3f', $(now) - $t0")"
holds "N5 nvim (every process of it) is gone ${dt} s after :qa!, under 1.0 s" \
  '[ "$gone" = 1 ] && perl -e "exit !($dt < 1.0)"'

# ── N6 the notebook without the library ─────────────────
echo "-- N6 the notebook without the library"
make_nb plain
launch_with "JUPYNVIM_NATIVE=$WORK/none.$EXT" nb.ipynb
st="$(rec "tostring(require('jupynvim.native').available()) .. ' ' .. require('jupynvim.native').status().state")"
holds "N6 with JUPYNVIM_NATIVE at a missing file: not available, state missing ($st)" '[ "$st" = "false missing" ]'
screen_a="$(settled)"
A="$(printf '%s\n' "$screen_a" | frame)"
holds "N6 the notebook frame shows" '[ -n "$A" ]'
holds "N6 nothing on screen mentions libjupynvim" '! printf "%s\n" "$screen_a" | grep -qi "libjupynvim"'
# a notice is gone from the screen once the next command line is typed;
# :messages keeps it
msgs="$(rec "vim.fn.execute('messages')")"
holds "N6 no message mentions libjupynvim (:messages)" '! printf "%s\n" "$msgs" | grep -qi "libjupynvim"'
quit_nvim
launch_with "" nb.ipynb
st="$(rec "tostring(require('jupynvim.native').available()) .. ' ' .. require('jupynvim.native').status().state")"
holds "N6 with the library: available, state ok ($st)" '[ "$st" = "true ok" ]'
B="$(settled | frame)"
holds "N6 the frame rows without the library equal those with it ($(printf '%s\n' "$A" | grep -c '') rows)" \
  '[ "$A" = "$B" ]'
if [ "$A" != "$B" ]; then
  diff <(printf '%s\n' "$A") <(printf '%s\n' "$B")
fi
quit_nvim

# ── N7 the one notice at 80x24 ──────────────────────────
# A notice longer than the command line stops at the hit-enter prompt, which
# swallows a Space (the usual leader key), so the keys after it run as plain
# Normal-mode commands and edit the buffer. With Neovim's defaults
# (showcmd, ruler, laststatus 2, cmdheight 1) a message fits the last line of
# an 80-column screen only up to 68 cells (v:echospace, columns - 12). Each
# of the feature's one-line notices must stay there: the loader's for a file
# that does not load and for one of another version, and the background
# install's refusals, met at a startup open.
echo "-- N7 the one-line notices at 80x24: no hit-enter prompt, typing goes on"
# prompt_gone SECS: 0 once no row shows the hit-enter prompt, within SECS
prompt_gone() {
  local i
  for i in $(seq 1 $(( $1 * 10 ))); do
    cap | grep -qF "Press ENTER" || return 0
    sleep 0.1
  done
  return 1
}
# a <Space>x mapping that writes leader, and a line of text it must not change
leader_and_hello() {
  send ":lua vim.keymap.set('n', '<Space>x', function() __native_put('leader', 'ran') end)" Enter
  send ":lua vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'hello' }); vim.api.nvim_win_set_cursor(0, { 1, 0 })" Enter
  nv_sync
}
# loader_notice LABEL NOTICE: when_ready in the running nvim finds the
# library unusable, and its notice shows as one line with no prompt; then
# <Space>x runs its mapping and the line stays hello
loader_notice() {
  local label="$1" notice="$2" shown=0 screen line
  rm -f "$WORK/rec"
  send ":lua require('jupynvim.native').when_ready(function(ok) __rec(tostring(ok)) end)" Enter
  jnv_wait_file_eq "$WORK/rec" false 10
  holds "N7 $label: when_ready reports the library unusable (rec is false)" '[ "$(cat "$WORK/rec" 2>/dev/null)" = false ]'
  T0="$(now)"
  poll_screen "$notice" 1000 5 && shown=1
  screen="$(cap)"
  printf '%s\n' "$screen" | tail -n 3
  holds "N7 $label: the notice shows as one line of ${#notice} characters: $notice" '[ "$shown" = 1 ]'
  holds "N7 $label: and no row has the hit-enter prompt" '! printf "%s\n" "$screen" | grep -qF "Press ENTER"'
  rm -f "$WORK/leader"
  tmux send-keys -t "=$S:" -l " x"
  jnv_wait_file_eq "$WORK/leader" ran 5
  line="$(rec "vim.api.nvim_get_current_line()")"
  holds "N7 $label: <Space>x typed after the notice runs its mapping and leaves the line as it was ($line)" \
    '[ "$(cat "$WORK/leader" 2>/dev/null)" = ran ] && [ "$line" = hello ]'
}
printf 'not a library\n' > "$WORK/garbage.$EXT"
NS_X=80 NS_Y=24 launch_with "JUPYNVIM_NATIVE=$WORK/garbage.$EXT"
room="$(rec "vim.o.columns .. ' ' .. vim.v.echospace .. ' ' .. tostring(vim.o.showcmd) .. ' ' .. tostring(vim.o.ruler)")"
echo "   columns, v:echospace, showcmd, ruler: $room"
holds "N7 the screen is 80 columns with 68 cells of message room, Neovim's defaults ($room)" '[ "$room" = "80 68 true true" ]'
leader_and_hello
# control: the harness sees a hit-enter prompt when there is one, and what
# it does to <Space>x; 69 characters, one more than the room, is enough
T0="$(now)"
send ':lua vim.notify(string.rep("x", 69), vim.log.levels.WARN)' Enter
ctl=0
poll_screen "Press ENTER" 1000 2 && ctl=1
holds "N7 control: a 69-character notice stops at the hit-enter prompt" '[ "$ctl" = 1 ]'
rm -f "$WORK/leader"
tmux send-keys -t "=$S:" -l " x"
prompt_gone 2 || fail_later "N7 control: the hit-enter prompt did not go away"
sleep 0.5
line="$(rec "vim.api.nvim_get_current_line()")"
holds "N7 control: there <Space>x runs no mapping and x edits the line ($line)" \
  '[ ! -e "$WORK/leader" ] && [ "$line" != hello ]'
send ":lua vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'hello' }); vim.api.nvim_win_set_cursor(0, { 1, 0 })" Enter
nv_sync
loader_notice "a file that does not load" "jupynvim: libjupynvim could not be loaded; see :checkhealth jupynvim"
tmux send-keys -t "=$S:" -l "ihello notice"
T0="$(now)"
typed=0
poll_screen "hello notice" 1000 2 && typed=1
holds "N7 typed text (ihello notice) shows within 2 s" '[ "$typed" = 1 ]'
holds "N7 and still no row has the hit-enter prompt" '! cap | grep -qF "Press ENTER"'
quit_nvim
# a library of another version (a plugin update without the library's): the
# loader's notice for a mismatch
NS_X=80 NS_Y=24 launch_with "JUPYNVIM_NATIVE=$FAKE JNV_FAKE=version"
leader_and_hello
loader_notice "a library of another version" "jupynvim: libjupynvim does not match; see :checkhealth jupynvim"
quit_nvim
# The background install's refusals, met where they come: a notebook opened
# at startup, in a plugin copy without the library (core_path set, so the
# install is the library's alone), from a release on disk without
# SHA256SUMS, and from a release base it must not download from. Nothing is
# typed until the notice shows; <Space>x is mapped by the init file.
case "$(uname -s) $(uname -m)" in
  "Darwin arm64") LT=aarch64-apple-darwin ;; "Darwin x86_64") LT=x86_64-apple-darwin ;;
  "Linux x86_64") LT=x86_64-unknown-linux-gnu ;; "Linux aarch64"|"Linux arm64") LT=aarch64-unknown-linux-gnu ;;
  *) LT="" ;;
esac
if [ -z "$LT" ]; then
  echo "   N7 background refusals: no library prebuilt is made for $(uname -s) $(uname -m)"
else
  P="$WORK/plug"
  mkdir -p "$P/core/target/release"
  cp -R "$ROOT/lua" "$P/lua"
  cp "$ROOT/core/Cargo.toml" "$P/core/Cargo.toml"
  sed "s|^vim.opt.runtimepath:prepend(\"$ROOT\")|vim.opt.runtimepath:prepend(\"$P\")|" "$WORK/init.lua" > "$WORK/init-plug.lua"
  grep -qF "prepend(\"$P\")" "$WORK/init-plug.lua" || fail_later "N7 the plugin copy's init file does not load the copy"
  printf '%s\n' "vim.keymap.set('n', '<Space>x', function() __native_put('leader', 'ran') end)" >> "$WORK/init-plug.lua"
  mkdir -p "$WORK/rel-nosums/v$VERSION"
  cp "$LIB" "$WORK/rel-nosums/v$VERSION/libjupynvim-$LT.$EXT"
  make_nb plain
  # bg_notice LABEL BASE NOTICE
  bg_notice() {
    local label="$1" base="$2" notice="$3" shown=0 screen st
    rm -f "$WORK/leader" "$WORK/rec"
    stop_session
    tmux new-session -d -s "$S" -x 80 -y 24
    send "cd $WORK && JUPYNVIM_RELEASE_BASE=$base XDG_STATE_HOME=$WORK/state-$label nvim -u $WORK/init-plug.lua nb.ipynb 2>$WORK/stderr-$label" Enter
    T0="$(now)"
    poll_screen "$notice" 3000 40 && shown=1
    if [ "$shown" = 1 ]; then echo "   $label: the notice showed $SEEN_AT s after the start"; else echo "   $label: the notice never showed"; fi
    sleep 0.5
    screen="$(cap)"
    printf '%s\n' "$screen" | tail -n 3
    holds "N7 $label at a startup open: the notice shows as one line of ${#notice} characters: $notice" '[ "$shown" = 1 ]'
    holds "N7 $label: and no row has the hit-enter prompt" '! printf "%s\n" "$screen" | grep -qF "Press ENTER"'
    tmux send-keys -t "=$S:" -l " x"
    jnv_wait_file_eq "$WORK/leader" ran 5
    holds "N7 $label: <Space>x typed after the notice runs its mapping" '[ "$(cat "$WORK/leader" 2>/dev/null)" = ran ]'
    prompt_gone 2 || send Enter
    st="$(rec "tostring(require('jupynvim')._lib_bg_state)")"
    holds "N7 $label: the background install failed and installed nothing ($st)" \
      '[ "$st" = failed ] && [ ! -e "$P/core/target/release/libjupynvim.$EXT" ]'
    quit_nvim
  }
  bg_notice nosums "file://$WORK/rel-nosums" "jupynvim: libjupynvim download refused: could not be checked"
  bg_notice httpbase "http://127.0.0.1:9" "jupynvim: JUPYNVIM_RELEASE_BASE must start with https:// or file://"
fi

finish "native screen"

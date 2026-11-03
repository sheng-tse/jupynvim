#!/usr/bin/env bash
# Comprehensive test runner for jupynvim.
#
# Runs:
#   0. isolation_audit.py (static: no fixed temp path, no blanket kill, tmux
#      only on a private server, every test on the run env and wired in here)
#      + gitignore_spec.sh (the fake library sources are tracked, while the
#      top-level examples/ playground and the build output stay ignored)
#      + audit_rules_spec.sh (the audit's rules for the node helpers under
#      tests/ and the native library's Rust files, on made-up trees)
#   1. cargo test (Rust unit tests), then cargo build --release
#      + the fake libraries the native tests load (cargo build --release --examples)
#      + mathgrammar_spec.sh (the library's math grammar against its reference
#      implementation in node: the committed goldens, and a fresh random
#      corpus each run)
#   2. backend_integration.py (Python harness against jupynvim-core)
#      + widget_protocol.py (the ipywidgets comm protocol on a real kernel:
#      widget state, callbacks, progress bars, Output widgets, binary buffers,
#      restarts)
#      + connfiles_spec.py (kernel connection files: a private runtime dir,
#      0600 files in 0700 dirs, removed when a kernel stops and when its
#      backend exits or is killed, swept at the next start, ports bound by
#      the kernel)
#      + isolation_spec.sh (the run env at run time: its dirs, nvim's paths,
#      a private tmux server, the process finder, the backend and the kernel)
#      + spec_out_spec.sh (what spec_out below prints and keeps of a
#      headless spec's output, so a failed spec names its failing checks)
#   3. lua_e2e.lua (headless Neovim Lua tests)
#   4. cellui_spec.lua + markdown_spec.lua + remote_hl_spec.lua (headless
#      render/UI specs) + remote_pick_open_spec.lua + remote_open_layout_spec.lua
#      (window placement when opening a file from the remote explorer/picker)
#      + dispatch_keys_spec.lua (global keys are session-only, issue #24)
#      + deploy_probe_spec.lua (ssh round trips spent verifying the
#      remote backend binary; each one costs 20-50s on a loaded cluster)
#      + keymap_override_spec.lua (override modes, issue #30; a bad override
#      must not break the open)
#      + image_b64_spec.lua (whitespace in image base64, and what a render
#      may cost once an image is transmitted)
#      + reopen_lsp_spec.lua (which language servers attach, issue #32)
#      + edit_nav_spec.lua (moving between cells while editing, issue #27,
#      and which cell an output row belongs to)
#      + vkitty_spec.py (the headless Kitty graphics harness on synthetic
#      streams: the tokenizer, Unicode widths, the VT emulator, Kitty graphics
#      and media, placements and animation, the renderer and SSIM, the relay,
#      the faults and the throughput groups, and the file checks of meta)
#      + multi_image_spec.lua (several images in one cell, issue #34, and
#      clear_output(wait) / update_display_data)
#      + install_spec.lua (installing the binary without lazy.nvim, #33)
#      + output_cache_spec.lua (equal-length output after fast reruns)
#      + stale_output_e2e.lua (redefine a function and rerun its unchanged caller)
#      + output_view_spec.lua (outputs cut, expanded, hidden or given a number
#      of lines, #37)
#      + native_spec.lua (the in-process library libjupynvim from Lua: its
#      discovery and checks, jobs, the pump, the budgets of what each may cost
#      the UI thread, shutdown and the path without it)
#      + widget_spec.lua (the widget mirror: saved state, events, outputs of
#      an Output widget, and a widget's redraw that keeps the buffer clean)
#      + widget_e2e.lua (the widget protocol on a real kernel: tqdm bars live
#      to 100% within 320 ms of their event, a slider's change before the
#      kernel's reply and the kernel's view of it, a button click, and the
#      saved state back with no kernel)
#      + palette_spec.lua (the palette tokens derived through the library from
#      highlight groups, the overrides, the highlight groups and event,
#      readable(), the path without the library, its budgets)
#      + routing_spec.lua (a local and a remote notebook open at once: every
#      request goes to the notebook's own backend)
#      + stream_writer_spec.lua (Kitty graphics written through nvim_ui_send,
#      nothing sent for a gif out of view or a render that changed nothing)
#      + lib/escape_scan.py --self-test (the scanner of cut escape sequences
#      the stream screen tests use, on streams with known answers)
#      + stream_palette_spec.lua (the palette's background question behind
#      gif frames in flight: their status answers are not taken for its own)
#   5. frame_layout.sh (real rendered screen via tmux: frame alignment across
#      terminal-split / floating-window layout changes)
#      vkitty_screen.sh (the headless Kitty graphics harness against tmux 3.5a:
#      the VT battery, every stream's screen and cursor compared with the
#      emulator's)
#      remote_hl_screen.sh (real rendered screen via tmux: dashboard/explorer
#      highlights actually paint)
#      edit_nav_screen.sh (real nvim via tmux: ]c/[c while editing a cell)
#      boundary_screen.sh (real nvim via tmux: edits that would break a cell
#      boundary, and what :w saves)
#      undo_screen.sh (real nvim via tmux: undo and redo around outputs, cell
#      moves and the history an open reads back)
#      output_view_screen.sh (real nvim via tmux: <leader>no, <leader>nO and
#      <leader>nl, :q after them, and u after a restart with an output
#      expanded or hidden)
#      native_screen.sh (real nvim via tmux: the library's artifact and C ABI
#      checks, typing while a job runs, silent panics, :qa! with a job
#      running, and the notebook drawn the same without the library)
#      widget_screen.sh (real nvim via tmux: a progress bar live to 100% in
#      its colour, an Output widget's text, and the saved state on a relaunch)
#      connfiles_screen.sh (real nvim via tmux: after :qa, a closed
#      terminal, a killed backend and a killed nvim no kernel runs and no
#      connection file is left)
#      palette_screen.sh (real nvim via tmux: the terminal's background asked
#      by OSC 11 and answered by tmux, the canvas and the 35 tokens from it,
#      no loop, a 'background' the terminal does not share staying as the user
#      set it, the swatches and the title of :JupynvimPalette in their colors,
#      and the terminal turning light)
#      palette_terminal_screen.sh (real nvim via tmux, on a terminal that
#      changes its color without a report: nothing asked before VimEnter, so a
#      'background' set in the config stays when the event loop runs during
#      start-up, a late setup() that moves nothing, a 'background' set right
#      after VimEnter or inside a long vim.wait that stays, a terminal chain
#      that answers the DSR before the OSC 11 question
#      (tests/lib/reorder_pty.py), the canvas learned again when
#      'background' changes, with Neovim's handler alive and gone, the
#      messages of the start-up and their hit-enter prompt still drawn, no
#      screen drawn before a dashboard, and the question asked while Neovim
#      starts still the palette's on a slow link after a long VimEnter)
#      routing_screen.sh (real nvim via tmux: a remote notebook, then a local
#      one; each runs on its own kernel and saves through its own backend)
#      stream_order_screen.sh (real nvim behind a slow terminal: no escape
#      sequence cut by an image write, gif frames only in view, no graphics
#      written while typing next to a plot)
#      stream_backlog_screen.sh (real nvim behind a terminal slower than a
#      large gif, one slower than a frame per timeout, and one whose first
#      answer comes later than the 30 s lost limit: frames wait for the
#      terminal, memory stays flat, the screen keeps up with the keyboard)
#      stream_suspend_screen.sh (real nvim suspended with CTRL-Z and detached:
#      nothing reaches the terminal the shell has, the gif plays again after
#      fg and after nvim --remote-ui in that terminal, and a --remote-ui
#      terminal elsewhere gets nothing into it)
#      stream_stop_screen.sh (real nvim behind a terminal that answers late
#      or reads slowly: after CTRL-Z, :detach and :qa! with a gif playing, also
#      right after the first frame after fg and after a reattach, no terminal
#      answer reaches the shell)
#      stream_fair_screen.sh (real nvim behind a slow link with two gifs in
#      view: the slow gif is not starved by the fast one)
#      stream_detach_screen.sh (real nvim with a second UI, and with a client
#      on another host: after :detach no terminal answer reaches the shell, and
#      Neovim's log holds no error from a message a client did not know)
#      stream_nomark_screen.sh (real nvim behind a terminal that answers status
#      requests but not XTVERSION, as tmux before 3.2: the first gif plays at
#      once and a quit leaves the shell clean)
#      stream_inject_screen.sh (real nvim on a notebook whose image data carries
#      an escape: nothing of it reaches the terminal)
#      stream_edge_screen.sh (real nvim with a gif whose cell's last line is on
#      the window's last rows, also in a bordered floating window: the screen
#      shows no gif row and no frame is sent)
#      stream_measure_screen.sh (three runs of the cell-box scenarios behind a
#      slow terminal, recorded and replayed by the pixel harness: no cut, no
#      damaged screen, nothing from an off-screen gif, gif frames on their clock)
#      stream_remote_screen.sh (real nvim with only a remote notebook and the
#      plugin loaded after the UI attached, behind a slow terminal: gif frames
#      still wait for the terminal)
#      stream_palette_screen.sh (real nvim behind a slow terminal with a gif
#      playing: the palette's background question still gets its own answer
#      and 'background' stays as the colorscheme set it)
#   6. no leftover processes (nothing a test started is still running, and no
#      test's cleanup had to stop one) and no leftover connection files
#      (nothing in the run's kernel runtime dirs, $TMPDIR/jupynvim-<uid>
#      among them, no old location $TMPDIR/jupynvim: every place is named
#      in tests/lib/connfiles_left.py)
#
# Every run is isolated (tests/lib/test_env.sh): its own run dir in the
# caller's temp dir for TMPDIR, the XDG, Jupyter and IPython dirs and the
# logs, its own python3 kernelspec and a private tmux server per screen test,
# so two runs at once never share a path or a process. The user's own state
# is never written; it is read only to copy the python3 kernelspec, the
# matplotlib font cache and the treesitter parsers (on macOS the backend also
# still lists the user's kernelspecs). Only processes the run started are
# ever stopped. The run dir is removed at exit, also on Ctrl-C (INT to the
# whole process group). A TERM or HUP sent to this script's pid alone takes
# effect once the section running in the foreground returns; a run that is
# killed outright is cleaned up by the next run's setup. To check two or more
# runs at once: bash tests/run_concurrent.sh [N]
#
# All must pass for the suite to succeed.

set -u
cd "$(dirname "$0")/.." || exit 2
ROOT="$(pwd)"
# Every run gets its own dirs (TMPDIR, XDG, Jupyter, IPython, logs), its own
# python3 kernelspec and private tmux servers; the exit hook it installs
# stops what is left of the run and removes the run dir.
source "$ROOT/tests/lib/test_env.sh"

PASS=0
FAIL=0
SECTIONS=()

section() {
  local name="$1"
  local rc="$2"
  if [ "$rc" -eq 0 ]; then
    PASS=$((PASS + 1))
    SECTIONS+=("PASS: $name")
    echo
    echo "✓ $name"
  else
    FAIL=$((FAIL + 1))
    SECTIONS+=("FAIL: $name (rc=$rc)")
    echo
    echo "✗ $name (rc=$rc)"
  fi
}

echo "==================================================="
echo "  jupynvim: comprehensive test suite"
echo "  run dir:  $JNV_RUN_ROOT"
echo "  kernel:   python3 = $JNV_KERNEL_PYTHON ($JNV_KERNEL_SPEC_SRC)"
echo "  parsers:  ${JNV_TS_SITE:-none}"
echo "==================================================="

# Every headless nvim gets a deadline. A spec that hangs, the way the chafa
# render loop spun forever, fails its section instead of stalling the suite.
# If nvim cannot be executed at all, perl's exec fails and a bare -e script
# would exit 0, a silent pass; exit 127 instead.
nv() { perl -e 'alarm 300; exec { $ARGV[0] } @ARGV or do { print STDERR "exec $ARGV[0]: $!\n"; exit 127 }' nvim "$@"; }

# spec_out NAME RC OUTPUT: what a headless spec printed. Its whole output is
# kept in the run dir (specs/NAME.log; JNV_KEEP_RUN=1 keeps the dir) and,
# when JNV_SPEC_LOGS names a dir, also in JNV_SPEC_LOGS/<run id>/NAME.log,
# which outlives the run; its last line is shown. When it failed, its FAIL
# lines are shown too, so the log names the check, or its last 15 lines
# when it stopped before reporting any (a Lua error).
spec_out() {
  local name="$1" rc="$2" out="$3" fails="" d
  for d in "$JNV_RUN_ROOT/specs" ${JNV_SPEC_LOGS:+"$JNV_SPEC_LOGS/$JNV_RUN_ID"}; do
    mkdir -p "$d" 2>/dev/null && printf '%s\n' "$out" > "$d/$name.log"
  done
  if [ "$rc" -ne 0 ]; then
    fails="$(printf '%s\n' "$out" | grep -E '^FAIL[: ]' | head -n 40)"
    if [ -z "$fails" ]; then
      printf '%s\n' "$out" | tail -n 15
      return 0
    fi
    printf '%s\n' "$fails"
  fi
  printf '%s\n' "$out" | tail -n 1
}

# conda's activate functions reference unset vars, so they abort under
# `set -u` (which silently killed the whole suite in non-interactive / CI
# shells). Relax set -u around every conda call.
set +u
# shellcheck disable=SC1091
# Load conda's shell functions from wherever it is installed. An activated
# env exports CONDA_EXE; ~/miniconda3 is the fallback for a clean shell.
if [ -n "${CONDA_EXE:-}" ] && [ -x "$CONDA_EXE" ]; then
  eval "$("$CONDA_EXE" shell.bash hook)"
elif [ -f "$HOME/miniconda3/etc/profile.d/conda.sh" ]; then
  source "$HOME/miniconda3/etc/profile.d/conda.sh"
fi
# Cargo must not see a conda env. The jupynvim env exports CC, LD and LDFLAGS
# for its own clang, whose linker cannot read a newer macOS SDK, so anything
# cargo has to relink fails there. A warm target/ hid that until a rebuild.
# Leave whatever env the caller had active, not just the one we activate.
if command -v conda >/dev/null 2>&1; then
  while [ "${CONDA_SHLVL:-0}" -gt 0 ]; do conda deactivate || break; done
fi
set -u

# ── 0. Isolation audit ──────────────────────────────────
echo
echo "── 0/6 isolation audit (static) ─"
python3 -I "$ROOT/tests/isolation_audit.py" "$ROOT"
section "isolation audit" "$?"
bash "$ROOT/tests/gitignore_spec.sh"
section "gitignore spec" "$?"
bash "$ROOT/tests/audit_rules_spec.sh"
section "audit rules spec" "$?"

# ── 1. Rust ─────────────────────────────────────────────
# The exit status is taken inside the subshell: outside it, PIPESTATUS only
# holds the subshell's own status, which is tail's, which is always 0.
echo
echo "── 1/6 cargo test + build (Rust) ─"
( cd core && cargo test --release 2>&1 | tail -20; exit "${PIPESTATUS[0]}" )
section "cargo test" "$?"
# Always build, so every later section drives the binary the source describes
# rather than whatever was built last. A no-op when nothing changed. The
# workspace builds libjupynvim next to jupynvim-core; the second build adds
# the fake libraries native_spec loads (examples/libjnv_fake*). It stays
# workspace wide: a build of one package (-p) resolves its dependencies'
# features differently and rewrites libjupynvim, so every later build would
# relink it again.
( cd core && { cargo build --release 2>&1 | tail -3; s1=${PIPESTATUS[0]}
               cargo build --release --examples 2>&1 | tail -3; s2=${PIPESTATUS[0]}
               exit $(( s1 || s2 )); } )
section "cargo build" "$?"
# The math grammar against its reference (node): the committed golden files
# are regenerated and compared, and a fresh random corpus is held to the same.
# Before the conda activation: it runs cargo, which must not see a conda env.
bash "$ROOT/tests/mathgrammar_spec.sh"
section "math grammar spec" "$?"

# Now the conda env, for the Python deps.
set +u
command -v conda >/dev/null 2>&1 && conda activate jupynvim 2>/dev/null
set -u

# ── 2. Backend integration + isolation spec ─────────────
echo
echo "── 2/6 backend integration (Python ↔ Rust binary) + connection files + isolation spec ─"
python tests/backend_integration.py
section "backend integration" "$?"
python tests/widget_protocol.py
section "widget protocol" "$?"
python tests/connfiles_spec.py
section "connection files" "$?"
bash "$ROOT/tests/isolation_spec.sh"
section "isolation spec" "$?"
bash "$ROOT/tests/spec_out_spec.sh"
section "spec_out spec" "$?"

# ── 3. Lua e2e ──────────────────────────────────────────
echo
echo "── 3/6 lua e2e (headless nvim) ─"
STATUS_FILE="$(mktemp "$TMPDIR/jupynvim_lua_status.XXXXXX")"
JUPYNVIM_TEST_STATUS_FILE="$STATUS_FILE" \
  nv --headless -u NONE -c "luafile $ROOT/tests/lua_e2e.lua" -c 'qa!' 2>&1
LUA_RC=$?
if [ -f "$STATUS_FILE" ]; then
  status=$(head -n1 "$STATUS_FILE")
  if [ "$status" = "PASS" ]; then
    section "lua e2e" 0
  else
    section "lua e2e" 1
  fi
  rm -f "$STATUS_FILE"
else
  section "lua e2e" "$LUA_RC"
fi

# ── 4. Cell-UI + markdown + remote-hl specs ─────────────
echo
echo "── 4/6 cell-ui + markdown + remote-hl specs (headless nvim) ─"
ui_out=$(nv --headless -u NONE -c "luafile $ROOT/tests/cellui_spec.lua" -c 'qa!' 2>&1)
echo "$ui_out" | grep -q "ALL CELL-UI CHECKS PASSED"; rc=$?
spec_out cellui_spec "$rc" "$ui_out"
section "cell-ui spec" "$rc"
md_out=$(nv --headless -u NONE -c "luafile $ROOT/tests/markdown_spec.lua" -c 'qa!' 2>&1)
echo "$md_out" | grep -q "ALL MARKDOWN CHECKS PASSED"; rc=$?
spec_out markdown_spec "$rc" "$md_out"
section "markdown spec" "$rc"
co_out=$(nv --headless -u NONE -c "luafile $ROOT/tests/cellops_spec.lua" -c 'qa!' 2>&1)
echo "$co_out" | grep -q "ALL CELL-OPS CHECKS PASSED"; rc=$?
spec_out cellops_spec "$rc" "$co_out"
section "cell-ops spec" "$rc"
hl_out=$(nv --headless -u NONE -c "luafile $ROOT/tests/remote_hl_spec.lua" -c 'qa!' 2>&1)
echo "$hl_out" | grep -q "ALL REMOTE-HL CHECKS PASSED"; rc=$?
spec_out remote_hl_spec "$rc" "$hl_out"
section "remote-hl spec" "$rc"
# These exit on their own, `qa!` when they pass and `cquit 1` when a check
# fails, so the exit code is the verdict. The trailing `cquit 3` only runs when
# the spec never reached its own exit: a Lua error aborts the chunk, and with a
# plain `qa!` there that crash used to count as a pass.
for spec in remote_pick_open_spec remote_open_layout_spec dispatch_keys_spec deploy_probe_spec \
            keymap_override_spec image_b64_spec reopen_lsp_spec edit_nav_spec \
            multi_image_spec install_spec output_cache_spec stale_output_e2e output_view_spec \
            native_spec widget_spec widget_e2e palette_spec routing_spec \
            stream_writer_spec stream_palette_spec; do
  out=$(nv --headless -u NONE -c "luafile $ROOT/tests/$spec.lua" -c 'cquit 3' 2>&1)
  rc=$?
  spec_out "$spec" "$rc" "$out"
  section "$spec" "$rc"
done
# the cut-sequence scanner the stream screen tests rely on, on streams with
# known answers
python3 -I "$ROOT/tests/lib/escape_scan.py" --self-test
section "escape scanner" "$?"

# The headless Kitty graphics harness (tests/lib/vkitty): its own python,
# resolved by jnv_vkitty_python (numpy, Pillow with raqm, fontTools; see
# tests/lib/vkitty/requirements.txt). No tmux and no nvim are used. It takes
# about 45 s of case time (41 to 45 s measured at load averages of 6 to 30);
# the screen test below about 55 s.
source "$ROOT/tests/lib/vkitty/python.sh"
if VK_PY="$(jnv_vkitty_python)"; then
  vk_out=$("$VK_PY" -I "$ROOT/tests/vkitty_spec.py" 2>&1); vk_rc=$?
  echo "$vk_out" | grep -E '^(FAIL|ok perf(clock)?/|[0-9]+ timed cases undecided)'
  echo "$vk_out" | tail -1
  section "vkitty spec" "$vk_rc"
else
  section "vkitty spec" 1
fi

# ── 5. Frame-layout (real rendered screen via tmux) ─────
echo
echo "── 5/6 frame-layout (tmux rendered screen) ─"
bash "$ROOT/tests/frame_layout.sh"
section "frame layout" "$?"
bash "$ROOT/tests/remote_hl_screen.sh"
section "remote-hl screen" "$?"
bash "$ROOT/tests/edit_nav_screen.sh"
section "edit-nav screen" "$?"
bash "$ROOT/tests/boundary_screen.sh"
section "boundary screen" "$?"
bash "$ROOT/tests/undo_screen.sh"
section "undo screen" "$?"
bash "$ROOT/tests/output_view_screen.sh"
section "output-view screen" "$?"
bash "$ROOT/tests/native_screen.sh"
section "native screen" "$?"
bash "$ROOT/tests/widget_screen.sh"
section "widget screen" "$?"
bash "$ROOT/tests/connfiles_screen.sh"
section "connection-files screen" "$?"
bash "$ROOT/tests/palette_screen.sh"
section "palette screen" "$?"
bash "$ROOT/tests/palette_terminal_screen.sh"
section "palette terminal screen" "$?"
bash "$ROOT/tests/vkitty_screen.sh"
section "vkitty screen" "$?"
bash "$ROOT/tests/routing_screen.sh"
section "routing screen" "$?"
bash "$ROOT/tests/stream_order_screen.sh"
section "stream-order screen" "$?"
bash "$ROOT/tests/stream_backlog_screen.sh"
section "stream-backlog screen" "$?"
bash "$ROOT/tests/stream_suspend_screen.sh"
section "stream-suspend screen" "$?"
bash "$ROOT/tests/stream_stop_screen.sh"
section "stream-stop screen" "$?"
bash "$ROOT/tests/stream_fair_screen.sh"
section "stream-fair screen" "$?"
bash "$ROOT/tests/stream_detach_screen.sh"
section "stream-detach screen" "$?"
bash "$ROOT/tests/stream_nomark_screen.sh"
section "stream-nomark screen" "$?"
bash "$ROOT/tests/stream_inject_screen.sh"
section "stream-inject screen" "$?"
bash "$ROOT/tests/stream_edge_screen.sh"
section "stream-edge screen" "$?"
bash "$ROOT/tests/stream_measure_screen.sh"
section "stream-measure screen" "$?"
bash "$ROOT/tests/stream_remote_screen.sh"
section "stream-remote screen" "$?"
bash "$ROOT/tests/stream_palette_screen.sh"
section "stream-palette screen" "$?"

# ── 6. Run hygiene ──────────────────────────────────────
# A test must stop everything it started. A session or server stop that had
# to kill a process is recorded in the leaks file; anything the run started
# that is still running now (named after the run, or holding a file in the
# run dir) is listed, stopped and fails the section. A process someone else
# started that refers to the run (a tail -F on its log) is named and left
# alone. It also checks that no connection files are left: nothing in the
# run's kernel runtime dirs ($XDG_RUNTIME_DIR/jupynvim, the Jupyter runtime
# dirs, $JUPYNVIM_RUNTIME_DIR/jupynvim, $TMPDIR/jupynvim-<uid> and the other
# per-user names; the full list is in tests/lib/connfiles_left.py) and no
# old location $TMPDIR/jupynvim.
echo
echo "── 6/6 run hygiene ─"
leak=0
if [ -s "$JNV_RUN_ROOT/leaks" ]; then
  echo "processes a test left running (its cleanup stopped them):"; cat "$JNV_RUN_ROOT/leaks"; leak=1
fi
python3 -I "$ROOT/tests/lib/run_procs.py" scan --grace 15 --kill || leak=1
python3 -I "$ROOT/tests/lib/connfiles_left.py" || leak=1
section "no leftover processes" "$leak"

# ── Summary ─────────────────────────────────────────────
echo
echo "==================================================="
echo "  RESULTS: $PASS passed, $FAIL failed"
for s in "${SECTIONS[@]}"; do echo "    $s"; done
echo "==================================================="

# The exit hook from tests/lib/test_env.sh keeps this status and removes the
# run dir.
exit $FAIL

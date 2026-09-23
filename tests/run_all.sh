#!/usr/bin/env bash
# Comprehensive test runner for jupynvim.
#
# Runs:
#   1. cargo test (Rust unit tests), then cargo build --release
#   2. backend_integration.py (Python harness against jupynvim-core)
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
#      + edit_nav_spec.lua (which cell an output row belongs to)
#   5. frame_layout.sh (real rendered screen via tmux: frame alignment across
#      terminal-split / floating-window layout changes)
#      remote_hl_screen.sh (real rendered screen via tmux: dashboard/explorer
#      highlights actually paint)
#
# All must pass for the suite to succeed.

set -u
cd "$(dirname "$0")/.." || exit 2
ROOT="$(pwd)"

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
echo "  jupynvim — comprehensive test suite"
echo "==================================================="

# ── 1. Rust ─────────────────────────────────────────────
# Runs BEFORE conda is activated. The jupynvim env exports CC, LD and LDFLAGS
# for its own clang, whose linker cannot read a newer macOS SDK, so anything
# cargo has to relink fails there. A warm target/ hid that until a rebuild.
# The exit status is taken inside the subshell: outside it, PIPESTATUS only
# holds the subshell's own status, which is tail's, which is always 0.
echo
echo "── 1/5 cargo test + build (Rust) ─"
( cd core && cargo test --release 2>&1 | tail -20; exit "${PIPESTATUS[0]}" )
section "cargo test" "$?"
# Always build, so every later section drives the binary the source describes
# rather than whatever was built last. A no-op when nothing changed.
( cd core && cargo build --release 2>&1 | tail -3; exit "${PIPESTATUS[0]}" )
section "cargo build" "$?"

# Activate the conda env for the Python deps. conda's activate functions
# reference unset vars, so they abort under `set -u` (which silently killed the
# whole suite in non-interactive / CI shells). Relax set -u just for this.
set +u
# shellcheck disable=SC1091
[ -f "$HOME/miniconda3/etc/profile.d/conda.sh" ] && source "$HOME/miniconda3/etc/profile.d/conda.sh"
conda activate jupynvim 2>/dev/null
set -u

# ── 2. Backend integration ──────────────────────────────
echo
echo "── 2/5 backend integration (Python ↔ Rust binary) ─"
python tests/backend_integration.py
section "backend integration" "$?"

# ── 3. Lua e2e ──────────────────────────────────────────
echo
echo "── 3/5 lua e2e (headless nvim) ─"
STATUS_FILE="$(mktemp -t jupynvim_lua_status.XXXXXX)"
JUPYNVIM_TEST_STATUS_FILE="$STATUS_FILE" \
  nvim --headless -u NONE -c "luafile $ROOT/tests/lua_e2e.lua" -c 'qa!' 2>&1
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
echo "── 4/5 cell-ui + markdown + remote-hl specs (headless nvim) ─"
ui_out=$(nvim --headless -u NONE -c "luafile $ROOT/tests/cellui_spec.lua" -c 'qa!' 2>&1)
echo "$ui_out" | tail -1
echo "$ui_out" | grep -q "ALL CELL-UI CHECKS PASSED"
section "cell-ui spec" "$?"
md_out=$(nvim --headless -u NONE -c "luafile $ROOT/tests/markdown_spec.lua" -c 'qa!' 2>&1)
echo "$md_out" | tail -1
echo "$md_out" | grep -q "ALL MARKDOWN CHECKS PASSED"
section "markdown spec" "$?"
co_out=$(nvim --headless -u NONE -c "luafile $ROOT/tests/cellops_spec.lua" -c 'qa!' 2>&1)
echo "$co_out" | tail -1
echo "$co_out" | grep -q "ALL CELL-OPS CHECKS PASSED"
section "cell-ops spec" "$?"
hl_out=$(nvim --headless -u NONE -c "luafile $ROOT/tests/remote_hl_spec.lua" -c 'qa!' 2>&1)
echo "$hl_out" | tail -1
echo "$hl_out" | grep -q "ALL REMOTE-HL CHECKS PASSED"
section "remote-hl spec" "$?"
# These exit on their own, `qa!` when they pass and `cquit 1` when a check
# fails, so the exit code is the verdict. The trailing `cquit 3` only runs when
# the spec never reached its own exit: a Lua error aborts the chunk, and with a
# plain `qa!` there that crash used to count as a pass.
for spec in remote_pick_open_spec remote_open_layout_spec dispatch_keys_spec deploy_probe_spec \
            keymap_override_spec image_b64_spec reopen_lsp_spec edit_nav_spec; do
  out=$(nvim --headless -u NONE -c "luafile $ROOT/tests/$spec.lua" -c 'cquit 3' 2>&1)
  rc=$?
  echo "$out" | tail -1
  section "$spec" "$rc"
done

# ── 5. Frame-layout (real rendered screen via tmux) ─────
echo
echo "── 5/5 frame-layout (tmux rendered screen) ─"
bash "$ROOT/tests/frame_layout.sh"
section "frame layout" "$?"
bash "$ROOT/tests/remote_hl_screen.sh"
section "remote-hl screen" "$?"

# ── Summary ─────────────────────────────────────────────
echo
echo "==================================================="
echo "  RESULTS: $PASS passed, $FAIL failed"
for s in "${SECTIONS[@]}"; do echo "    $s"; done
echo "==================================================="

exit $FAIL

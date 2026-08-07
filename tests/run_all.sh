#!/usr/bin/env bash
# Comprehensive test runner for jupynvim.
#
# Runs:
#   1. cargo test (Rust unit tests)
#   2. backend_integration.py (Python harness against jupynvim-core)
#   3. lua_e2e.lua (headless Neovim Lua tests)
#   4. cellui_spec.lua + markdown_spec.lua + remote_hl_spec.lua (headless
#      render/UI specs) + remote_pick_open_spec.lua + remote_open_layout_spec.lua
#      (window placement when opening a file from the remote explorer/picker)
#      + dispatch_keys_spec.lua (global keys are session-only, issue #24)
#   5. frame_layout.sh (real rendered screen via tmux: frame alignment across
#      terminal-split / floating-window layout changes)
#      remote_hl_screen.sh (real rendered screen via tmux: dashboard/explorer
#      highlights actually paint)
#
# All must pass for the suite to succeed.

set -u
cd "$(dirname "$0")/.." || exit 2
ROOT="$(pwd)"

# Activate the conda env so cargo/python deps are available. conda's activate
# functions reference unset vars, so they abort under `set -u` (which silently
# killed the whole suite in non-interactive / CI shells). Relax set -u just for
# the activation.
set +u
# shellcheck disable=SC1091
[ -f "$HOME/miniconda3/etc/profile.d/conda.sh" ] && source "$HOME/miniconda3/etc/profile.d/conda.sh"
conda activate jupynvim 2>/dev/null
set -u

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
echo
echo "── 1/3 cargo test (Rust unit tests) ─"
( cd core && cargo test --release 2>&1 | tail -20 )
section "cargo test" "${PIPESTATUS[0]}"

# Build release binary if not present
if [ ! -x "$ROOT/core/target/release/jupynvim-core" ]; then
  echo "Building jupynvim-core..."
  ( cd core && cargo build --release 2>&1 | tail -3 )
fi

# ── 2. Backend integration ──────────────────────────────
echo
echo "── 2/3 backend integration (Python ↔ Rust binary) ─"
python tests/backend_integration.py
section "backend integration" "$?"

# ── 3. Lua e2e ──────────────────────────────────────────
echo
echo "── 3/3 lua e2e (headless nvim) ─"
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
# These signal failure with `cquit 1`, so the exit code is the verdict.
for spec in remote_pick_open_spec remote_open_layout_spec dispatch_keys_spec; do
  out=$(nvim --headless -u NONE -c "luafile $ROOT/tests/$spec.lua" -c 'qa!' 2>&1)
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

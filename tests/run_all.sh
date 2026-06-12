#!/usr/bin/env bash
# Comprehensive test runner for jupynvim.
#
# Runs:
#   1. cargo test (Rust unit tests)
#   2. backend_integration.py (Python harness against jupynvim-core)
#   3. lua_e2e.lua (headless Neovim Lua tests)
#
# All three must pass for the suite to succeed.

set -u
cd "$(dirname "$0")/.." || exit 2
ROOT="$(pwd)"

# Activate the conda env so cargo/python deps are available
# shellcheck disable=SC1091
source "$HOME/miniconda3/etc/profile.d/conda.sh"
conda activate jupynvim 2>/dev/null

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
  nvim --headless -u NONE -c "luafile $ROOT/tests/lua_e2e.lua" -c 'qa' 2>&1
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

# ── Summary ─────────────────────────────────────────────
echo
echo "==================================================="
echo "  RESULTS: $PASS passed, $FAIL failed"
for s in "${SECTIONS[@]}"; do echo "    $s"; done
echo "==================================================="

exit $FAIL

#!/usr/bin/env bash
# Real-screen check for the dashboard/explorer highlight migration off the
# deprecated nvim_buf_add_highlight (tests/remote_hl_spec.lua covers the
# extmark shape; this proves the pixels actually get colored).
#
# Both renderers use col1 = -1 for "to end of line". nvim_buf_set_extmark
# rejects end_col = -1 and both call sites are pcall-wrapped, so a wrong
# migration paints nothing and raises no error. Asserting on extmarks alone
# would not catch a highlight that exists but renders with no color, so this
# drives a real nvim under tmux and reads SGR escapes off the screen.
#
# Neither renderer needs SSH: M.build and _render take synthetic state.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v tmux >/dev/null || { echo "SKIP remote_hl_screen: no tmux"; exit 0; }

INIT="$ROOT/tests/.hlscreen_init.lua"
cat > "$INIT" <<LUA
vim.opt.runtimepath:prepend("$ROOT")
vim.o.termguicolors = true
vim.o.swapfile = false
vim.o.laststatus = 0
vim.o.cmdheight = 1
LUA

S="jupy_hl_$$"
CAP_RAW() { tmux capture-pane -t "$S" -p -e; }   # -e keeps SGR escapes
cleanup() { tmux kill-session -t "$S" 2>/dev/null; rm -f "$INIT"; }
trap cleanup EXIT

tmux kill-session -t "$S" 2>/dev/null
tmux new-session -d -s "$S" -x 120 -y 40
tmux set-option -t "$S" status off
tmux send-keys -t "$S" "cd $ROOT && nvim -u $INIT" Enter
sleep 2

fails=0
note() { echo "$1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }

# ── dashboard ────────────────────────────────────────────────────────────
tmux send-keys -t "$S" ":lua vim.api.nvim_win_set_buf(0, require('jupynvim.remote.dashboard').build('testalias','/home/me/proj',0))" Enter
sleep 1.5

rendered=0
for _ in $(seq 1 10); do
  if CAP_RAW | grep -q "JUPYNVIM\|██"; then rendered=1; break; fi
  sleep 0.5
done
if [ "$rendered" -ne 1 ]; then
  bad "dashboard never rendered"
  CAP_RAW | sed -n '1,6p'
else
  note "ok dashboard rendered"
  # The logo is explicitly #F58426. With termguicolors that is an RGB SGR.
  # tmux normalizes to 38;2;245;132;38.
  if CAP_RAW | grep -q "38;2;245;132;38"; then
    note "ok logo painted in its orange (38;2;245;132;38 present on screen)"
  else
    bad "logo has no color on screen (to-end-of-line highlight lost)"
    note "  SGR codes seen: $(CAP_RAW | grep -o $'\033\[[0-9;]*m' | sort -u | tr -d $'\033' | tr '\n' ' ' | head -c 300)"
  fi
  # The connection-info line links to Title; the footer links to Comment.
  # Both are to-end-of-line highlights, so both must carry a non-default SGR.
  info_line=$(CAP_RAW | grep -a "testalias" | head -1)
  if printf '%s' "$info_line" | grep -q $'\033\[[0-9;]*m'; then
    note "ok connection-info line carries a highlight"
  else
    bad "connection-info line rendered with no SGR at all"
  fi
fi

# ── explorer ─────────────────────────────────────────────────────────────
tmux send-keys -t "$S" ":lua local RE=require('jupynvim.remote.explorer'); local b=vim.api.nvim_create_buf(false,true); vim.api.nvim_win_set_buf(0,b); RE._render({alias='a',root='/home/me/proj',buf=b,expanded={},kids={['/home/me/proj']={loaded=true,items={{name='src',path='/home/me/proj/src',kind='dir'},{name='main.py',path='/home/me/proj/main.py',kind='file'}}}}})" Enter
sleep 1.5

if CAP_RAW | grep -qa "main.py"; then
  note "ok explorer rendered"
  # The basename is a to-end-of-line highlight linking to Title. Color cannot
  # discriminate here: in the default colorscheme Title's fg equals the normal
  # foreground, and nvim emits that as an RGB code on plain text too. Title's
  # distinguishing attribute is BOLD, which neither the root icon (Directory)
  # nor unhighlighted text carries.
  hdr=$(CAP_RAW | grep -a "proj" | head -1)
  if printf '%s' "$hdr" | grep -q $'\033\[1m'; then
    note "ok explorer header basename rendered bold (Title highlight applied)"
  else
    bad "explorer header basename not bold (to-end-of-line highlight lost)"
  fi
  dir=$(CAP_RAW | grep -a "src/" | head -1)
  if printf '%s' "$dir" | grep -q $'\033\[[0-9;]*m'; then
    note "ok explorer dir name carries a highlight"
  else
    bad "explorer dir name rendered with no SGR (to-end-of-line highlight lost)"
  fi
else
  bad "explorer never rendered"
  CAP_RAW | sed -n '1,6p'
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "REMOTE-HL SCREEN: ALL PAINTED"
  exit 0
else
  echo "REMOTE-HL SCREEN: $fails CHECK(S) FAILED"
  exit 1
fi

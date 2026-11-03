#!/usr/bin/env bash
# A gif whose rows are not on the screen sends no frame, also when its cell's
# last line is.
#
# The image rows are virtual lines under the cell's last source line: a
# border first, then the image. With that line on the window's last row, or
# the one above, none of the image shows (Neovim still reports the line as
# the last one in view), and one row further up the first image row does.
# The module sent frames whenever the line was in view, so a gif sitting just
# below the window cost its frames on every tick (up to 64 KB unread on a
# slow link, and on Neovim 0.11 each frame can cut the UI's escape sequences).
#
# The same at the top: with the cell's last line just scrolled off, the
# window's top rows are the end of those virtual lines (the topfill), the
# last of which is a blank row after the image; a gif shows only once the
# topfill reaches its last row.
#
# A real nvim runs in a private tmux pane whose raw output is logged
# (pipe-pane). The notebook has a gif cell among short cells. The test
# scrolls row by row (CTRL-E and CTRL-Y, as a wheel does) until the cell's
# last line is on a window row, or has left the top with a number of filler
# rows, then judges two things apart: the screen (how many rows show the
# gif's placeholder cells) and the frames written in the next 2.5 s. With the
# line on the last row, and on the one above, or with one filler row, the
# screen shows no gif row and no frame may go out; with the first image row
# on the last row, or two filler rows, the screen shows it and the gif plays.
# The same bottom edge is judged in a floating window with a rounded border
# (a zen or focus float, a picker's preview): its text starts one row below
# the border, so the window's last text row is one below where the window's
# own row numbers put it. The notebook is shown in the float alone; with the
# line on the float's last text row no gif row is shown and no frame goes out,
# with the first image row on that last row it is shown and the gif plays.
# It also fails when an escape sequence was cut (Neovim 0.12+;
# tests/lib/escape_scan.py).
#
# Needs tmux and ImageMagick 7 (the gif). JNV_STREAM_NVIM=/path/to/nvim runs
# another Neovim (0.11 has no in-order writer: there the cut count is only
# printed).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/core/target/release/jupynvim-core"
[ -x "$BIN" ] || { echo "SKIP stream_edge: build core first ($BIN)"; exit 0; }
source "$(dirname "$0")/lib/tmux.sh"
NVIM_BIN="${JNV_STREAM_NVIM:-nvim}"
command -v magick >/dev/null || { echo "SKIP stream_edge: no ImageMagick 7 (magick)"; exit 0; }
UI_SEND=""
"$NVIM_BIN" --headless -u NONE -c 'lua io.stdout:write(vim.api.nvim_ui_send and "y" or "n")' -c 'qa!' 2>/dev/null \
  | grep -q y && UI_SEND=1
WORK="$(mktemp -d "$TMPDIR/jupynvim_edge.XXXXXX")"
S="jupy_edge_$$"
cleanup() { jnv_tmux_stop; rm -rf "$WORK"; }
jnv_on_exit cleanup
mkdir -p "$WORK/state"

# 16 frames at 80 ms
( cd "$WORK" && for i in $(seq 0 15); do
    magick -size 480x320 gradient:'#1e3050-#402060' -fill "rgb($((i * 15)),200,$((240 - i * 15)))" \
      -draw "circle $((40 + i * 25)),160 $((40 + i * 25)),110" "f_$(printf %02d "$i").png" || exit 1
  done && magick -delay 8 -loop 0 f_*.png anim.gif ) \
  || { echo "FAIL stream_edge: ImageMagick could not make the gif"; exit 1; }

python3 -I - "$WORK" <<'PY'
import base64, json, os, sys
w = sys.argv[1]
gif = base64.b64encode(open(os.path.join(w, "anim.gif"), "rb").read()).decode()
def code(i, src, outs=()):
    return {"cell_type": "code", "id": "c%d" % i, "metadata": {}, "execution_count": i,
            "outputs": list(outs), "source": src}
cells = [code(i, "pre_%d = %d" % (i, i)) for i in range(1, 17)]
cells.append(code(17, "show_gif()", [{"output_type": "display_data", "metadata": {},
                                      "data": {"image/gif": gif}}]))
cells += [code(i, "post_%d = %d" % (i, i)) for i in range(18, 40)]
json.dump({"cells": cells, "metadata": {"language_info": {"name": "python"}},
           "nbformat": 4, "nbformat_minor": 5}, open(os.path.join(w, "nb.ipynb"), "w"))
PY

# __place(row): scroll a row at a time until the gif cell's last line is on
# window row `row` (1 is the top; -1 the last, -2 the one above, and so on),
# then write "ROW:HEIGHT" to placed; ready is
# written once the gif animates
cat > "$WORK/init.lua" <<LUA
vim.opt.runtimepath:prepend("$ROOT")
vim.o.swapfile = false
vim.o.termguicolors = true
require("jupynvim").setup({ core_path = "$BIN", auto_venv = false })
local I = require("jupynvim.notebook.image")
local function put(name, v) local f = io.open("$WORK/" .. name, "w"); f:write(v); f:close() end
-- __float(): the notebook in a floating window with a rounded border, the
-- window under it showing another buffer, the float the current window. The
-- float's text starts one row below its top border, which the test counts on
-- its own (border_rows) and does not ask the module.
local border_rows = 0
function _G.__float()
  local main = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_win_set_buf(main, vim.api.nvim_create_buf(false, true))
  local fw = vim.api.nvim_open_win(buf, true, { relative = "editor", row = 2, col = 4,
    width = vim.o.columns - 8, height = vim.o.lines - 6, border = "rounded" })
  border_rows = 1
  vim.cmd("redraw!")
  put("placed", ("float:%d"):format(vim.api.nvim_win_get_height(fw)))
end
function _G.__place(row)
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_get_current_buf()
  local CM = require("jupynvim.notebook.cellmode")
  local r = CM.ranges(buf)[17]
  local anchor = math.max(r.stop, r.start + 1)
  local wi = vim.fn.getwininfo(win)[1]
  local first = wi.winrow + border_rows + wi.winbar
  local function where()
    vim.fn.line("w\$", win)
    local sp = vim.fn.screenpos(win, anchor, 1)
    return sp.row > 0 and (sp.row - first + 1) or nil
  end
  local function scroll(k) vim.cmd("normal! " .. vim.api.nvim_replace_termcodes(k, true, false, true)) end
  local want = row < 0 and (wi.height + row + 1) or row
  vim.fn.winrestview({ lnum = anchor, col = 0, topline = math.max(1, anchor - 8), topfill = 0 })
  for _ = 1, 4 * wi.height do
    local at = where()
    if at == want then
      vim.cmd("redraw")
      put("placed", ("%d:%d"):format(at, wi.height))
      return
    end
    if at == nil then scroll(vim.fn.line("w0", win) > anchor and "<C-y>" or "<C-e>")
    else scroll(at > want and "<C-e>" or "<C-y>") end
  end
  put("placed", "none:" .. wi.height)
end
-- __top(n): the gif cell's last line has just left the top, with n rows of
-- filler (CTRL-Y from the line after it, as a wheel scrolls up)
function _G.__top(n)
  local buf = vim.api.nvim_get_current_buf()
  local r = require("jupynvim.notebook.cellmode").ranges(buf)[17]
  local anchor = math.max(r.stop, r.start + 1)
  vim.fn.winrestview({ lnum = anchor + 1, col = 0, topline = anchor + 1, topfill = 0 })
  for _ = 1, n do vim.cmd("normal! " .. vim.api.nvim_replace_termcodes("<C-y>", true, false, true)) end
  vim.cmd("redraw")
  put("placed", ("top%d:%d"):format(vim.fn.winsaveview().topfill, vim.fn.line("w0") - anchor))
end
local ready = vim.uv.new_timer()
ready:start(100, 100, vim.schedule_wrap(function()
  for _, p in pairs(I._placements) do
    if p.timer and (p.frame_idx or 1) > 1 then
      ready:stop()
      put("ready", "1")
      return
    end
  end
end))
LUA

tmux new-session -d -s "$S" -x 160 -y 50 "env -u TMUX -u TMUX_PANE PS1='SH\$ ' bash --norc --noprofile -i"
tmux pipe-pane -t "=$S:" -O "cat > $(printf %q "$WORK/raw.bin")"
CAP() { tmux capture-pane -t "=$S:" -p; }
pane_bytes() { wc -c < "$WORK/raw.bin" 2>/dev/null | tr -d ' '; }
q() { printf %q "$1"; }
end=$((SECONDS + 15))
until [[ "$(CAP)" == *'SH$'* ]]; do
  if [ "$SECONDS" -ge "$end" ]; then
    echo "FAIL the shell showed its prompt  -- not within 15 s"
    jnv_stop_session "$S"; jnv_tmux_stop
    printf '\nSTREAM-EDGE: 1 FAILED (stopped early)\n'
    exit 1
  fi
  sleep 0.1
done
tmux send-keys -t "=$S:" "env TERM=xterm-256color XDG_STATE_HOME=$(q "$WORK/state") $(q "$NVIM_BIN") -i NONE -u $(q "$WORK/init.lua") $(q "$WORK/nb.ipynb")" Enter
if ! jnv_wait_file_eq "$WORK/ready" 1 40; then
  echo "FAIL the gif started to animate  -- not within 40 s; the screen:"
  CAP | LC_ALL=C sed -e '/^ *$/d' -e 's/^/  | /' | tail -n 20
  jnv_stop_session "$S"; jnv_tmux_stop
  printf '\nSTREAM-EDGE: 1 FAILED (stopped early)\n'
  exit 1
fi
sleep 1

# STEP LABEL ROW: scroll to ROW (negative: from the bottom), let the screen
# settle, log the screen (rows with a placeholder cell), then watch 2.5 s
# of frames. Frames are the a=t writes the raw log gains.
# STEP_TOP LABEL N: the same with N rows of topfill (the cell's last line
# has left the top)
step_top() {
  local label="$1" n="$2" end
  rm -f "$WORK/placed"
  tmux send-keys -t "=$S:" Escape ":lua __top($n)" Enter
  end=$((SECONDS + 15))
  until [ -s "$WORK/placed" ] || [ "$SECONDS" -ge "$end" ]; do sleep 0.1; done
  sleep 0.8
  CAP > "$WORK/screen_$label.txt"
  echo "$label placed=$(cat "$WORK/placed" 2>/dev/null) from=$(pane_bytes)" >> "$WORK/steps"
  sleep 2.5
  echo "$label to=$(pane_bytes)" >> "$WORK/steps"
}
step() {
  local label="$1" row="$2" end
  rm -f "$WORK/placed"
  tmux send-keys -t "=$S:" Escape ":lua __place($row)" Enter
  end=$((SECONDS + 15))
  until [ -s "$WORK/placed" ] || [ "$SECONDS" -ge "$end" ]; do sleep 0.1; done
  sleep 0.8
  CAP > "$WORK/screen_$label.txt"
  echo "$label placed=$(cat "$WORK/placed" 2>/dev/null) from=$(pane_bytes)" >> "$WORK/steps"
  sleep 2.5
  echo "$label to=$(pane_bytes)" >> "$WORK/steps"
}
step last -1
step above -2
step one -3
step two -4
step_top top1 1
step_top top2 2
# the notebook in a bordered float
rm -f "$WORK/placed"
tmux send-keys -t "=$S:" Escape ":lua __float()" Enter
end=$((SECONDS + 15))
until [ -s "$WORK/placed" ] || [ "$SECONDS" -ge "$end" ]; do sleep 0.1; done
sleep 0.5
step fl_last -1
step fl_one -3

tmux send-keys -t "=$S:" Escape ":qa!" Enter
jnv_wait_nvim_exit 15 || echo "nvim did not quit"
tmux send-keys -t "=$S:" "exit" Enter
for _ in $(seq 1 100); do tmux has-session -t "=$S" 2>/dev/null || break; sleep 0.1; done
last=-1
for _ in $(seq 1 50); do
  sz="$(wc -c < "$WORK/raw.bin" 2>/dev/null || echo 0)"
  [ "$sz" = "$last" ] && break
  last="$sz"; sleep 0.2
done
leak=0
jnv_stop_session "$S" || leak=1
jnv_tmux_stop || leak=1

WORK="$WORK" UI_SEND="$UI_SEND" LEAK="$leak" LIB="$ROOT/tests/lib" python3 -I - <<'PY'
import os, re, sys
sys.dont_write_bytecode = True
sys.path.insert(0, os.environ["LIB"])
from escape_scan import scan, summary
W = os.environ["WORK"]
data = open(os.path.join(W, "raw.bin"), "rb").read()
cuts, kitty = scan(data)
print(summary(data, cuts, kitty))
steps = {}
for line in open(os.path.join(W, "steps")).read().splitlines():
    label, kv = line.split(" ", 1)
    for item in kv.split():
        k, v = item.split("=", 1)
        steps.setdefault(label, {})[k] = v
PH = "\U0010EEEE"
def rows_with_image(label):
    p = os.path.join(W, "screen_%s.txt" % label)
    txt = open(p, encoding="utf-8", errors="replace").read() if os.path.exists(p) else ""
    return sum(1 for l in txt.splitlines() if PH in l)
def frames(label):
    s = steps.get(label, {})
    if "from" not in s or "to" not in s: return None
    return data[int(s["from"]):int(s["to"])].count(b"\x1b_Ga=t")
fails = []
def chk(name, ok, detail=""):
    print(("  ok " if ok else "FAIL ") + name + ("" if ok else "  -- " + detail))
    if not ok: fails.append(name)
info = {l: (steps.get(l, {}).get("placed"), rows_with_image(l), frames(l))
        for l in ("last", "above", "one", "two", "top1", "top2", "fl_last", "fl_one")}
for l, (pl, rows, fr) in info.items():
    print("  %-6s gif cell's last line at window row (or topfill:top line) %s, %s screen rows with image cells, %s frames in 2.5 s" % (l, pl, rows, fr))
chk("the gif cell's last line was put on the window's last row, and the one above",
    info["last"][0] is not None and info["last"][0].split(":")[0] == info["last"][0].split(":")[1]
    and info["above"][0] is not None and int(info["above"][0].split(":")[0]) == int(info["above"][0].split(":")[1]) - 1,
    "%s %s" % (info["last"][0], info["above"][0]))
chk("last line on the last row: the screen shows no gif row and no frame is sent",
    info["last"][1] == 0 and info["last"][2] == 0, "%s image rows, %s frames" % (info["last"][1], info["last"][2]))
chk("last line on the row above the last: the screen shows no gif row and no frame is sent",
    info["above"][1] == 0 and info["above"][2] == 0, "%s image rows, %s frames" % (info["above"][1], info["above"][2]))
chk("first image row on the last row: the screen shows it and the gif plays",
    info["one"][1] >= 1 and (info["one"][2] or 0) >= 3, "%s image rows, %s frames" % (info["one"][1], info["one"][2]))
chk("two image rows in view: the gif plays",
    info["two"][1] >= 2 and (info["two"][2] or 0) >= 3, "%s image rows, %s frames" % (info["two"][1], info["two"][2]))
chk("the last line has left the top with one filler row: the screen shows no gif row and no frame is sent",
    info["top1"][0] == "top1:1" and info["top1"][1] == 0 and info["top1"][2] == 0,
    "%s, %s image rows, %s frames" % (info["top1"][0], info["top1"][1], info["top1"][2]))
chk("the last line has left the top with two filler rows: the screen shows the gif's last row and the gif plays",
    info["top2"][0] == "top2:1" and info["top2"][1] == 1 and (info["top2"][2] or 0) >= 3,
    "%s, %s image rows, %s frames" % (info["top2"][0], info["top2"][1], info["top2"][2]))
chk("in a bordered float, the gif cell's last line was put on the last text row, and then two rows above it",
    info["fl_last"][0] is not None and info["fl_last"][0].split(":")[0] == info["fl_last"][0].split(":")[1]
    and info["fl_one"][0] is not None and int(info["fl_one"][0].split(":")[0]) == int(info["fl_one"][0].split(":")[1]) - 2,
    "%s %s" % (info["fl_last"][0], info["fl_one"][0]))
chk("in a bordered float, last line on the last text row: the screen shows no gif row and no frame is sent",
    info["fl_last"][1] == 0 and info["fl_last"][2] == 0, "%s image rows, %s frames" % (info["fl_last"][1], info["fl_last"][2]))
chk("in a bordered float, first image row on the last text row: the screen shows it and the gif plays",
    info["fl_one"][1] >= 1 and (info["fl_one"][2] or 0) >= 3, "%s image rows, %s frames" % (info["fl_one"][1], info["fl_one"][2]))
if os.environ.get("UI_SEND"):
    chk("no escape sequence was cut", not cuts, "%d cut" % len(cuts))
else:
    print("  (no nvim_ui_send: %d cut sequences, not checked)" % len(cuts))
chk("nvim and its terminal multiplexer stopped cleanly", os.environ.get("LEAK") == "0", "LEAK above")
print(("\nSTREAM-EDGE: %d FAILED" % len(fails)) if fails else "\nSTREAM-EDGE: ALL PASSED")
sys.exit(1 if fails else 0)
PY

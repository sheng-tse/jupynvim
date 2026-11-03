#!/usr/bin/env bash
# A local and a remote notebook open side by side in a real nvim under tmux.
#
# The remote is a second jupynvim-core that the profile's transport_cmd starts
# with JNV_SIDE=remote; this nvim runs with JNV_SIDE=local, so each kernel
# prints which side it runs on. The remote notebook opens first, through its
# jupynvim:// URI the way the explorer and the pickers open it, then :e opens
# a local one: the order that used to send the local notebook, its runs and
# its saves to the remote backend. Each must run on its own kernel and save
# its edit (which backend a save goes to is checked by routing_spec.lua,
# which records every request).
#
#   bash tests/routing_screen.sh
set -u
source "$(dirname "$0")/screen_lib.sh"

mkdir -p "$WORK/local" "$WORK/rhome"
cat > "$WORK/init.lua" <<LUA
vim.opt.runtimepath:prepend("$ROOT")
vim.o.swapfile = false
require("jupynvim").setup({ core_path = "$BIN", auto_venv = false,
  remote = { stub = { host = "stub.invalid", transport_cmd = { "env", "JNV_SIDE=remote", "$BIN" } } } })
function _G.__rec(s)
  local f = io.open("$WORK/rec", "a"); f:write(tostring(s) .. "\n"); f:close()
end
function _G.__sync(n) local f = io.open("$WORK/sync.tmp", "w"); f:write(tostring(n)); f:close(); os.rename("$WORK/sync.tmp", "$WORK/sync") end
-- the windows of this tab: how many, then each one's file name, sorted
function _G.__wins()
  local t = {}
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    t[#t + 1] = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)), ":t")
  end
  table.sort(t)
  return #t .. " " .. table.concat(t, " ")
end
-- whether the notebook in the current buffer has its kernel
function _G.__kernel()
  local nb = require("jupynvim.notebook").get(vim.api.nvim_get_current_buf())
  return nb and nb.kernel_started and "up" or "down"
end
LUA

python3 - "$WORK" <<'PY'
import json, sys
work = sys.argv[1]
def nb(marker):
    cell = {"cell_type": "code", "id": "c1", "metadata": {}, "execution_count": None, "outputs": [],
            "source": "# " + marker + "\nimport os\nprint('side=' + os.environ.get('JNV_SIDE', '?'))"}
    return {"cells": [cell], "nbformat": 4, "nbformat_minor": 5,
            "metadata": {"kernelspec": {"name": "python3", "display_name": "P", "language": "python"}}}
json.dump(nb("local notebook"), open(work + "/local/L.ipynb", "w"))
json.dump(nb("remote notebook"), open(work + "/rhome/R.ipynb", "w"))
json.dump(nb("split notebook"), open(work + "/rhome/S.ipynb", "w"))
PY

on_screen() { screen | grep -qF -- "$1"; }
wait_screen() { _jnv_poll "$2" on_screen "$1"; }
rec() { rm -f "$WORK/rec"; k ":lua __rec($1)" Enter; nv_sync; cat "$WORK/rec" 2>/dev/null; }
is_kernel_up() { [ "$(rec "__kernel()")" = "up" ]; }
# the notebook on screen has its kernel, within 30s
kernel_up() { _jnv_poll 30 is_kernel_up; }
# the first line of a notebook's first cell, as :w wrote it
first_line() {
  python3 - "$1" <<'PY'
import json, sys
print("".join(json.load(open(sys.argv[1]))["cells"][0]["source"]).split("\n")[0])
PY
}
# on the notebook named $1: edit mode on its first line, append $2, save
append_save() {
  k ":b $1" Enter
  k Enter; k g g; k A; type_text "$2"; k Escape; k Escape
  save
}

stop_session
tmux new-session -d -s "$S" -x 200 -y 50
tmux set-option -t "$S" status off
tmux send-keys -t "$S" "cd $WORK && JNV_SIDE=local XDG_STATE_HOME=$WORK/state nvim -u $WORK/init.lua" Enter
jnv_wait_nvim_up 20 || fail_later "nvim did not start"
nv_sync

# the remote notebook first, the way the explorer and the pickers open it
k ":e jupynvim://stub$WORK/rhome/R.ipynb" Enter
holds "the remote notebook opens" 'wait_screen "# remote notebook" 30'
holds "its kernel starts" 'kernel_up'
# then a local notebook with :e
k ":e $WORK/local/L.ipynb" Enter
holds "then a local notebook opens with its own cells" 'wait_screen "# local notebook" 30'
holds "its kernel starts" 'kernel_up'
k ":JupynvimRunCell" Enter
holds "the local cell runs on the local kernel" 'wait_screen "side=local" 30'
holds "nothing in the local notebook ran on the remote" '! on_screen "side=remote"'
k ":b R.ipynb" Enter
k ":JupynvimRunCell" Enter
holds "the remote cell runs on the remote kernel" 'wait_screen "side=remote" 30'
append_save L.ipynb " saved"
holds "the local notebook saves its edit" \
  '[ "$(first_line "$WORK/local/L.ipynb")" = "# local notebook saved" ]'
append_save R.ipynb " saved"
holds "the remote notebook saves its edit" \
  '[ "$(first_line "$WORK/rhome/R.ipynb")" = "# remote notebook saved" ]'

# Closed with :bdelete (LazyVim's <leader>bd), the remote notebook opened
# again the way the explorer opens it comes back without a note: it said "is
# open from stub, and is reopened there", and how to open this machine's file.
k ":b R.ipynb" Enter
k ":bdelete" Enter
k ":messages clear" Enter
k ":e jupynvim://stub$WORK/rhome/R.ipynb" Enter
holds "closed with :bdelete, the remote notebook opens again from its remote" \
  'wait_screen "# remote notebook saved" 30'
holds "its kernel starts" 'kernel_up'
holds "and nothing says where it came from" \
  '! on_screen "reopened there" && ! rec "vim.fn.execute(\"messages\")" | grep -qF "reopened there"'

# A remote file named with a // in a split: the split shows the file's buffer
# under its one name, and the window it was split from keeps its own buffer.
printf 'split text\n' > "$WORK/rhome/notes.txt"
k ":enew" Enter
k ":vsplit jupynvim://stub$WORK//rhome/notes.txt" Enter
holds "a remote file opened in a split shows in that split" 'wait_screen "split text" 15'
holds "both windows stay, the split on the file's one name" \
  '[ "$(rec "#vim.api.nvim_tabpage_list_wins(0) .. \" \" .. vim.api.nvim_buf_get_name(0)")" = "2 jupynvim://stub$WORK/rhome/notes.txt" ]'

# Back with <C-^> after a remote file named with a // (or ~/): the read put
# the file's buffer in place of the URI buffer and wiped that, which had
# become the window's alternate file, so <C-^> said E23.
printf "print('train')\n" > "$WORK/local/train.py"
printf 'notes two\n' > "$WORK/rhome/notes2.txt"
k ":only" Enter
k ":e $WORK/local/train.py" Enter
holds "a local file is shown" 'wait_screen "print(" 10'
k ":e jupynvim://stub$WORK//rhome/notes2.txt" Enter
holds "then the remote file named with a //" 'wait_screen "notes two" 15'
k C-^
holds "<C-^> goes back to the local file, with no E23" \
  'wait_screen "print(" 10 && ! on_screen "notes two" && ! on_screen "E23"'

# A notebook's URI in a split opens in that split; the window it was split
# from keeps its file, and the split's <C-^> goes back to that file.
k ":vsplit jupynvim://stub$WORK/rhome/S.ipynb" Enter
holds "a notebook URI opened in a split shows the notebook" 'wait_screen "# split notebook" 30'
holds "both windows stay, the file in the other one" '[ "$(rec "__wins()")" = "2 S.ipynb train.py" ]'
holds "its kernel starts" 'kernel_up'
k Escape
k C-^
holds "the split's <C-^> goes back to the file it was split from" \
  '[ "$(rec "__wins()")" = "2 train.py train.py" ] && ! on_screen "E23"'
k ":qa!" Enter
jnv_wait_nvim_exit 15 || fail_later "nvim did not quit within 15s of :qa!"
finish "routing screen"

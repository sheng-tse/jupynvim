# jupynvim

Open `.ipynb` files in Neovim and edit them like a real notebook. Cells with
borders, inline images, real Jupyter kernels, and an LSP that actually
understands the file. Built on a Rust backend that talks the Jupyter wire
protocol directly, with no Python remote-plugin layer.

It also works over SSH: point it at a remote machine or an HPC cluster and the
editor stays local while files, kernels, terminals, and search run on the
remote. The demo below is a remote session.

https://github.com/user-attachments/assets/2a3fbd17-561d-4c37-b856-a912944f88f8

## Highlights

- Open and save `.ipynb` files natively. `:w` writes nbformat v4 JSON, and
  unknown fields round-trip untouched.
- Cells render as visual blocks with virtual-line borders and execution-count
  badges. You edit inside cells with vim motions, and treesitter highlights
  only the code lines.
- Real Jupyter kernels via the wire protocol over ZMQ with HMAC-SHA256.
  Pick any installed kernelspec. Outputs render inside the cell, including
  text, errors, PNGs, and animated GIFs. Notebooks pinned to a specific
  kernel version still open when only a related version is installed, via
  prefix and language fallback.
- Inline images using the Kitty graphics protocol. Native PNG placement, not
  ASCII art, unless you ask for it. Animated GIFs loop at native speed via
  ImageMagick frame extraction.
- Markdown cells render with their own highlight overlay. Embedded
  `data:image/...;base64,...` URIs get rewritten to short placeholders so the
  buffer stays small while images still display.
- LSP that works on `.ipynb`. basedpyright, pyright, pylsp, or ruff attach
  with the kernel's interpreter so `numpy`, `matplotlib`, and project deps
  resolve. Diagnostics are scoped to code-cell line ranges so markdown text
  doesn't drown you in fake errors.
- LSP notebook protocol for notebook-aware servers (Astral's `ty`, future
  ones). jupynvim sends `notebookDocument/didOpen` and `didChange` with
  proper cell URIs so servers that advertise `notebookDocumentSync` analyze
  cells correctly instead of choking on the rendered cell view as if it
  were JSON. Per-cell diagnostics map back to buffer rows and accumulate
  across cells.
- Kernel-driven completion and hover for any language. A virtual LSP proxies
  the running kernel's `complete_request` and `inspect_request`, so names
  defined in earlier cells show up in completion and `K` brings up the
  kernel's own docstring. nvim-cmp and blink.cmp consume it through the
  standard LSP client. Works for Python, Julia, R, or anything else whose
  kernel implements those messages.
- Auto-detect a project-local `.venv`. If a notebook lives next to (or
  inside) a uv/poetry/pdm project with a `.venv` containing `ipykernel`,
  the kernel spawns from that interpreter directly. No need to
  `python -m ipykernel install --user --name foo` per project.
- Multi-image markdown cells are supported. `<leader>nD` deletes one image
  and `u` brings it back.
- Remote over SSH. Connect to a machine or HPC cluster and edit notebooks
  whose files and kernels live there, with a remote file browser, PTY
  terminals, and ripgrep search, all over one `ssh` connection. Works even
  where SFTP and inbound ports are blocked (tested on PSC Bridges-2). The
  Linux backend is cross-built and uploaded on connect.
- Per-cell execution timing. Each run shows an elapsed-time badge in the
  cell's footer border, persisted in the notebook so it survives save and
  reopen. Clearing the output clears it.
- One Rust binary, one Lua plugin. No `pynvim`, no `jupyter_client`, no
  `image.nvim`, no Node-based notebook server.

## Requirements

- Neovim 0.11 or newer.
- A Kitty-graphics terminal. Ghostty 1.3 and later, kitty, or WezTerm.
- Rust toolchain (`cargo`) only on platforms without a prebuilt binary.
  Mac arm64 and Linux x86_64 download a prebuilt on install. Other
  platforms fall back to building locally.
- A Jupyter kernel installed for the language you intend to use. See below.
- ImageMagick 7 (`magick`) is required for animated GIF playback. Static
  images work without it.
- For tmux users: enable Kitty-graphics passthrough in your tmux config:

  ```tmux
  set -g allow-passthrough on
  ```

  Without this, image cells render as blank space because tmux drops the
  Kitty graphics escapes. Set `JUPYNVIM_DISABLE_TMUX_PASSTHROUGH=1` if
  you have `TMUX` set but are not actually inside a multiplexer.

  jupynvim auto-switches `image_renderer = "kitty"` to `"placeholder"`
  inside tmux because direct placement places at fixed screen coords and
  doesn't auto-clean. Set `JUPYNVIM_FORCE_KITTY_IN_TMUX=1` to override.

`chafa` is optional. Install it if you want an ASCII-art fallback for
terminals without graphics support.

### Kernels

Install the kernel for whichever language you plan to run. jupynvim picks up
anything that shows in `jupyter kernelspec list`.

```bash
# Python (one per env you want to use)
pip install ipykernel

# Julia
julia -e 'using Pkg; Pkg.add("IJulia")'

# R
R -e 'install.packages("IRkernel"); IRkernel::installspec()'
```

Kernel-driven completion and hover work as soon as the kernel is running.
The editor-side LSPs covered above (basedpyright for Python, `julials` for
Julia, `r_language_server` for R) are optional and live in your normal
nvim-lspconfig / mason setup. Install them through `:Mason` like any other
language server. Julia and R additionally need the underlying language
package installed in their own runtimes, since mason only ships the
wrappers:

```julia
# Julia, inside the project's environment
using Pkg; Pkg.add("LanguageServer")
```

```r
# R
install.packages("languageserver")
```

## Install

With [`lazy.nvim`](https://github.com/folke/lazy.nvim):

```lua
{
  "sheng-tse/jupynvim",
  build = function(plugin)
    local install = loadfile(plugin.dir .. "/lua/jupynvim/install.lua")()
    install.run(plugin)
  end,
  config = function()
    require("jupynvim").setup({
      log_level = "info",
      image_renderer = "placeholder",  -- "placeholder", "kitty", or "chafa"
    })
  end,
}
```

That's it. Open any `.ipynb` and the kernel auto-starts based on the
notebook's `kernelspec` metadata.

## Quick start

Open an existing notebook with `:edit my-notebook.ipynb` or create a fresh
one with `:JupynvimOpen new-notebook.ipynb`.

Inside the buffer, move your cursor into a code cell and press `<leader>nr`
or `<S-CR>`. The execution count badge cycles to `[*]`, then `[1]`, and the
output appears below the code framed by the same border. `<leader>nb` adds a
code cell below, `<leader>nm` converts it to markdown, and `<leader>nK`
opens a picker listing every installed kernelspec.

`:w` saves. `:wqa` works as expected even if you only ran cells. jupynvim
flips the `modified` flag on every output event so vim's "unchanged" check
doesn't skip the save.

## Remote workspace (SSH)

Point jupynvim at a remote machine and the editor runs locally while the
notebook, its kernel, the file tree, terminals, and search all run on the
remote. Only `jupynvim-core` runs there; cursor motion and rendering never
cross the link. It is built on plain `ssh` (one connection, multiplexed), so
it works on clusters where SFTP/scp are disabled and inbound ports are
firewalled. It is tested against PSC Bridges-2.

Declare a profile in `setup`:

```lua
require("jupynvim").setup({
  remote = {
    cluster = {
      host = "user@cluster.example.edu",   -- or an ~/.ssh/config Host alias
      core_path = "~/.local/bin/jupynvim-core",
      -- ssh_args = { "-J", "jumpbox" },    -- optional ProxyJump etc.
    },
  },
})
```

Then connect and open a notebook:

```vim
:JupynvimConnect cluster
:JupynvimOpenRemote cluster:~/work/train.ipynb
```

`:JupynvimConnect` opens a short-lived terminal split for the SSH handshake
(password, 2FA) and sets up a ControlMaster socket, so it survives `nvim`
restarts and later opens reuse it without re-authenticating. With no argument
it shows a picker; a bare `user@host` (or any `~/.ssh/config` Host) connects
ad hoc. The Linux backend binary is cross-built (`:JupynvimCrossBuild`) and
uploaded to `core_path` automatically when it is missing or out of date.

Once connected:

- **Files.** Remote paths use the `jupynvim://<alias>/<path>` URI scheme.
  `:JupynvimExplorer` opens a browser for the remote tree; while a session is
  active, `<leader>e` and your file/grep pickers target the remote and fall
  back to local when not.
- **Terminals, VSCode-style.** A bottom PTY shell (`:JupynvimTerm` or
  `<C-/>`) and a second one on the right (`<leader>tr`) tile and resize
  together, so you can run a job in one and a tool like Claude Code in the
  other. Both run on the remote, with vi editing on the shell prompt.
- **Search.** `:JupynvimGrep <alias> <pattern> [<path>]` runs ripgrep on the
  remote and fills the quickfix list.
- **Slurm.** `:JupynvimUseJob <alias> [<jobid>]` routes the kernel through an
  `srun` overlay so it lands on an allocated compute node.
- **Multiple remotes.** Local and several remotes coexist, each buffer routed
  to its own connection. `:JupynvimUseLocal` switches back to local.

## Concepts

A jupynvim buffer is one Neovim buffer per `.ipynb` file. Cells are line
ranges separated by an invisible marker, `# %%[jupynvim:cell-sep]`,
concealed at runtime. Cell type, execution count, and outputs live as state
on the notebook object. The buffer text contains only what you'd type as
the cell's source.

Cells aren't floating windows or scratch buffers. Splits, marks, motions,
and search all work like a normal buffer. The visual block appearance comes
from extmark virtual text, not separate windows.

The Rust backend (`jupynvim-core`) owns the Jupyter connection. It runs as
a single subprocess and is shared across every open notebook. Kernel events
flow back as msgpack-RPC notifications which the Lua side maps to cells.

When you open a notebook, jupynvim reads the file via the backend
(round-tripping unknown nbformat fields), creates a buffer with
`buftype=acwrite` so `:w` routes through our `BufWriteCmd`, auto-starts the
kernel from the notebook's `kernelspec.name`, and manually attaches LSP.
Neovim's built-in `vim.lsp.enable` callback bails on non-empty `buftype`,
so jupynvim replicates the FileType callback's logic without that guard,
then injects the kernel's `pythonPath` and `analysis.extraPaths` (harvested
from `python -c "import sys"`) so import resolution matches the env you'll
actually run.

## Commands

| Command | Description |
|---|---|
| `:JupynvimOpen <path>` | Open a notebook. Also handles `:edit *.ipynb`. |
| `:JupynvimRunCell` | Run the cell under cursor. |
| `:JupynvimRunAll` | Run every code cell in order. |
| `:JupynvimKernel` | Pick a kernelspec from the installed list. |
| `:JupynvimRestart` | Restart the active kernel. |
| `:JupynvimClearOutputs` | Clear outputs from every code cell. |
| `:JupynvimClearCellOutput` | Clear output for the current cell only. |
| `:JupynvimSaveImage [path]` | Save the current cell's image to disk. |
| `:JupynvimDeleteImage` | Delete an embedded image from a markdown cell. |
| `:JupynvimImageMode {placeholder\|kitty\|chafa}` | Switch image renderer at runtime. |
| `:JupynvimReset` | Close every session, wipe state, reload current buffer. |
| `:JupynvimDebug` | Print buffer/cell/notebook state. |
| `:JupynvimConnect [<alias>]` | Connect to a remote (picker, configured profile, or `user@host`). |
| `:JupynvimOpenRemote <alias>:<path>` | Open a notebook or file on a connected remote. |
| `:JupynvimExplorer` | File browser for the active remote tree. |
| `:JupynvimTerm` | Toggle a PTY terminal on the remote (local when not connected). |
| `:JupynvimGrep <alias> <pattern> [<path>]` | ripgrep the remote into the quickfix list. |
| `:JupynvimRemoteCd <path>` | Change the remote working directory. |
| `:JupynvimUseJob <alias> [<jobid>]` | Route the kernel through a Slurm `srun` overlay. |
| `:JupynvimUseLocal` | Switch the active backend back to local. |
| `:JupynvimDisconnect [<alias>]` | Tear down a remote connection. |

## Keymaps

All notebook keymaps are buffer-local. They only exist while you're inside
an `.ipynb`.

### Cell execution

| Key | Action |
|---|---|
| `<S-CR>` or `<leader>nr` | Run cell, advance to next |
| `<C-CR>` | Run cell, stay |
| `<leader>nR` | Run all cells |
| `<leader>nA` or `<leader>nB` | Run all cells above or below |

### Cell editing

| Key | Action |
|---|---|
| `<leader>na` or `<leader>nb` | Add cell above or below |
| `<leader>nd` | Delete cell |
| `<leader>nk` or `<leader>nj` | Move cell up or down |
| `<leader>nm` or `<leader>ny` | Convert to markdown or code |
| `<leader>nc` or `<leader>nC` | Clear current cell output, or clear all |
| `]c` or `[c` | Jump to next or prev cell |

### Outputs and images

| Key | Action |
|---|---|
| `<C-j>` or `<C-k>` | Enter the next or prev cell's output in a scratch split with full vim motions |
| `<leader>nI` | Save current cell's image to file |
| `<leader>nD` | Delete an embedded image from a markdown cell |
| `]i` or `[i` | Jump to next or prev cell with an image |

### Kernel control

| Key | Action |
|---|---|
| `<leader>nK` | Pick kernel |
| `<leader>ns` or `<leader>nS` | Start or stop kernel |
| `<leader>ni` | Interrupt kernel |
| `<leader>nx` | Restart kernel |
| `<leader>nL` | Force re-render |

## Configuration

```lua
require("jupynvim").setup({
  -- Verbosity for both the Rust backend and the Lua frontend.
  log_level = "info",  -- trace, debug, info, warn, or error

  -- How code-cell outputs and embedded markdown images are rendered.
  --   "placeholder" uses the Kitty Unicode placeholder protocol. The image
  --                 is anchored to buffer text and stays put when scrolling.
  --                 Required for animated GIFs.
  --   "kitty"       uses direct kitty placement. Lives at fixed screen
  --                 coordinates and doesn't follow scroll.
  --   "chafa"       is an ASCII-art fallback. Use this on terminals without
  --                 graphics support.
  image_renderer = "placeholder",

  -- Inline image grid size in terminal cells (rows x cols). Default 16x48;
  -- bump for sharper output on large terminals or shrink for compact display.
  image_rows = 16,
  image_cols = 48,

  -- Override the path to the jupynvim-core binary. Auto-detected from the
  -- plugin directory if unset.
  core_path = nil,

  -- Per-action keymap overrides. Pass a string to replace the default lhs
  -- (mode and description preserved), `false` to disable a binding. The
  -- full action list lives in lua/jupynvim/keymaps.lua.
  keymaps = {
    -- run_advance = "<leader>jr",  -- example: rebind run-and-advance
    -- move_up = false,             -- example: disable move-cell-up
  },

  -- Skip the entire default keymap set if you want to bind everything yourself.
  disable_default_keymaps = false,

  -- Walk up from the notebook's directory to find a `.venv/bin/python` (or
  -- `.venv/Scripts/python.exe` on Windows) and use it as the kernel
  -- interpreter when ipykernel is installed there. Bypasses needing to
  -- register a per-project user kernel. Set false to use only registered
  -- kernelspecs.
  auto_venv = true,

  -- LSP servers to skip on jupynvim buffers. Useful for servers that
  -- misbehave on `.ipynb` URIs without advertising notebook capability.
  -- Notebook-aware servers (anything with notebookDocumentSync) are
  -- handled correctly via the LSP notebook protocol and don't need to be
  -- listed here.
  lsp_blocklist = {},

  -- Restore animated (smooth) scrolling inside notebook buffers. Off by
  -- default so cell navigation is one-shot and frames stay aligned. Set true
  -- if you use snacks.scroll and want it back in notebooks.
  smooth_scroll = false,

  -- Named remote profiles for :JupynvimConnect / :JupynvimOpenRemote. Key is
  -- the alias; value is the connection spec.
  remote = {
    -- cluster = {
    --   host = "user@cluster.example.edu",  -- or an ~/.ssh/config Host
    --   core_path = "~/.local/bin/jupynvim-core",
    --   -- ssh_args = { "-J", "jumpbox" },
    -- },
  },

  -- While a remote session is active these keys target the remote (and fall
  -- back to your local mapping when not connected). Set a group to {} to
  -- leave those keys alone.
  explorer_keys = { "<leader>e", "<leader>E" },   -- remote file tree
  terminal_keys = { "<c-/>", "<c-_>" },           -- toggle a remote PTY
  pick_keys = {
    files = { "<leader>ff", "<leader><space>" },
    grep  = { "<leader>/", "<leader>sg" },
  },
})
```

## How the LSP integration works

Two non-obvious tricks make basedpyright behave on `.ipynb`.

The first is a cleaned-text view to the LSP. The Python parser sees the
buffer as one file, so phrases like *with both side bars intact* in a
markdown cell get parsed as a `with` statement and the parse error
propagates into the next code cell's diagnostics. jupynvim patches
`vim.lsp._buf_get_full_text` to return the buffer with non-code lines
blanked out (line numbers preserved so diagnostics still map back). It
also forces `flags.allow_incremental_sync = false` so every `didChange`
re-routes through the patched function. The LSP only ever sees code.

The second is a kernel-aware `pythonPath`. basedpyright probes the
filesystem under `<pythonPath>/../lib/site-packages` rather than executing
the interpreter, so Homebrew Python breaks `import numpy` because its
site-packages live in `/opt/homebrew/lib/python3.x/site-packages` rather
than under the binary's prefix. jupynvim runs the kernel's interpreter
once at startup, harvests every `site-packages` and `dist-packages` dir
from `sys.path`, and injects them as `analysis.extraPaths` before
`vim.lsp.start`.

Treesitter is also restricted to code-cell byte ranges via
`set_included_regions`. Same problem space, different fix point.

Kernel completion and hover come from a second, virtual LSP. A
Lua-defined `vim.lsp.start` config forwards `textDocument/completion` and
`textDocument/hover` to the running kernel over msgpack-RPC, so standard
LSP clients see kernel matches and docstrings as plain LSP results.

Notebook-aware servers (Astral's `ty`, future ones) get a different
treatment. Those servers expect the LSP notebook protocol
(`notebookDocument/didOpen` with cell array, `notebookDocument/didChange`
with cell-array diffs) and assume any `.ipynb` URI's buffer text is the
file's JSON content. Sending them our rendered cell view via the regular
`textDocument/didOpen` makes them try to JSON-parse the rendered text,
which fails. jupynvim detects the `notebookDocumentSync` capability,
suppresses `textDocument/*` for the notebook URI on those clients, and
sends `notebookDocument/*` with stable cell URIs of the form
`vscode-notebook-cell:/<path>#<cell_id>`. Diagnostics come back keyed by
cell URI; an overridden `textDocument/publishDiagnostics` handler maps
them to buffer rows and accumulates across cells so each server's
findings coexist correctly.

## Architecture

```
  Neovim (Lua frontend)
           |
           |  msgpack-rpc over stdio
           v
  jupynvim-core (Rust backend)
           |
           |  ZMQ + HMAC-SHA256, Jupyter wire protocol
           v
         ipykernel
```

The Lua frontend also writes Kitty graphics escapes straight to
`/dev/tty` for inline image rendering, bypassing both the backend and
Neovim's own draw pipeline.

The Lua side hijacks `*.ipynb` via `BufReadCmd`, renders cells with
virtual-line borders, transmits PNG bytes via the Kitty graphics
protocol, drives gif animation on a `vim.loop` timer, and owns keymaps
and commands.

The Rust backend runs one async task per ZMQ socket so `send` and
`recv` don't conflict, HMAC-SHA256 signs every message, parses and
serializes `.ipynb` (nbformat v4) preserving unknown fields, routes
iopub events to cells via `parent_msg_id`, and decomposes animated
GIFs into a frame sequence with ImageMagick.

### Remote (SSH)

When connected to a remote, the same picture splits across the link. Neovim
and the Lua frontend stay local; only `jupynvim-core` runs on the remote,
spawned over `ssh` with msgpack-RPC tunneled through its stdio.

```
  Neovim + Lua frontend (local)
           |
           |  msgpack-rpc over ssh stdio (one multiplexed connection)
           v
  jupynvim-core (remote)  ->  ZMQ  ->  ipykernel (remote)
```

Files are read and written through the backend over the same channel
(`jupynvim://<alias>/<path>`). Kitty image bytes are encoded locally from
output already on this side, so plot data never crosses the link more than
once.

## Logs

Backend logs to `~/Library/Caches/jupynvim/core.log` on macOS and
`$XDG_CACHE_HOME/jupynvim/core.log` elsewhere. Set `JUPYNVIM_LOG=debug`
for verbose output. The Lua frontend logs to
`vim.fn.stdpath("cache") .. "/jupynvim/lua.log"`.

## Limitations

Kitty graphics or bust. Without a graphics-capable terminal, set
`image_renderer = "chafa"` for ASCII output.

Ghostty 1.3 doesn't implement the Kitty animation protocol, so animated
GIFs are driven by re-transmitting frames on a timer. Cheap, works
everywhere, but consumes a small amount of CPU while playing.

One backend instance is shared across all open notebooks. Restarting it
with `:JupynvimReset` restarts every kernel.

Remote LSP is partial. Kernel-driven completion and hover work over SSH, but
running a full editor language server on the remote and relaying it is still
in progress; editor-side LSP features are most complete on local notebooks.

## Thanks

[Magma](https://github.com/dccsillag/magma-nvim) and
[molten-nvim](https://github.com/benlubas/molten-nvim) proved that Jupyter
in Neovim is a real workflow worth investing in. The Jupyter team
documented an excellent
[wire protocol](https://jupyter-client.readthedocs.io/en/stable/messaging.html).
Kitty and Ghostty built the graphics protocol that makes terminal-native
notebooks possible at all.

## License

MIT. See [`LICENSE`](LICENSE).

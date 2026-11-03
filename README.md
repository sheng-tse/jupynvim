# jupynvim

[![release](https://img.shields.io/github/v/release/sheng-tse/jupynvim?label=release&labelColor=24292f&color=F58426)](https://github.com/sheng-tse/jupynvim/releases)
[![downloads](https://img.shields.io/github/downloads/sheng-tse/jupynvim/total?labelColor=24292f&color=006BB6)](https://github.com/sheng-tse/jupynvim/releases)
[![license](https://img.shields.io/badge/license-MIT-006BB6?labelColor=24292f)](LICENSE)
[![closed issues](https://img.shields.io/github/issues-closed/sheng-tse/jupynvim?labelColor=24292f&color=006BB6)](https://github.com/sheng-tse/jupynvim/issues?q=is%3Aissue+is%3Aclosed)
[![open issues](https://img.shields.io/github/issues/sheng-tse/jupynvim?labelColor=24292f&color=006BB6)](https://github.com/sheng-tse/jupynvim/issues)
[![Neovim](https://img.shields.io/badge/Neovim-0.11%2B-006BB6?logo=neovim&logoColor=57A143&labelColor=24292f)](https://neovim.io)

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
- Auto-detect a project-local `.venv`, or a Pixi project's default env. If
  a notebook lives next to (or inside) a uv/poetry/pdm project with a
  `.venv` containing `ipykernel`, the kernel spawns from that interpreter
  directly. A Pixi project works the same way: its default env
  (`.pixi/envs/default`) is used when there is no venv (`.venv`, `venv` or
  `env`) beside it and ipykernel is installed in it. No need to
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
  reopen. Clearing the output clears it. Run all, run above and run below
  mark every cell they submit `[*]` the JupyterLab way, with a grayed dot
  while a cell waits behind the running one. A restart, a kernel that dies
  and a backend that exits release the waiting cells.
- Jupyter widgets from ipywidgets 8 talk to the kernel. `tqdm.notebook` and
  `tqdm.auto` bars update live until they reach 100%. An Output widget captures
  the prints and displays made inside it, plots included. The widget state is
  saved in the notebook, so a saved notebook shows its widgets without a kernel.
  Widgets draw as text for now.
- One Rust binary, one Lua plugin. No `pynvim`, no `jupyter_client`, no
  `image.nvim`, no Node-based notebook server.

## Requirements

- Neovim 0.11 or newer. 0.12 is recommended: it writes images in order with
  the screen (see Limitations).
- A terminal that implements the Kitty graphics protocol with Unicode
  placeholders: kitty or Ghostty 1.3+. WezTerm is not yet supported for inline
  images (its Kitty-graphics support lacks the Unicode placeholders jupynvim
  uses), so plots and gifs won't render there; the rest of the editor works,
  and `image_renderer = "chafa"` gives a static ASCII fallback.
- Rust toolchain (`cargo`) only where no prebuilt binary runs. Mac arm64
  and Linux x86_64 download a prebuilt, from the install hook or the first
  time you open a notebook, and it is checked to run before it is used.
  Other platforms fall back to building locally.
- The in-process library `libjupynvim` comes with the same install. A
  prebuilt is made for macOS arm64 and x86_64 and for Linux x86_64 and arm64,
  and the installer fetches it on all four, also on macOS x86_64 and Linux
  arm64, where `jupynvim-core` itself has no prebuilt and is built with
  cargo. `cargo build --release` in `core/` builds it next to
  `jupynvim-core`. Neovim loads it through LuaJIT's FFI and runs heavy work
  on its worker threads, never on the UI thread. Without it, or on a Neovim
  built without LuaJIT, everything works as before.
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

Widgets need ipywidgets 8 in the kernel's environment, next to `ipykernel`:

```bash
pip install "ipywidgets>=8,<9"
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

With Neovim 0.12's built-in `vim.pack`, following release tags so the
plugin and its backend binary always move together:

```lua
vim.pack.add({
  { src = "https://github.com/sheng-tse/jupynvim", version = vim.version.range("*") },
})
require("jupynvim").setup({})
```

vim.pack has no build step, so the first notebook you open downloads the
backend binary that matches the plugin, and does it again after an update
changes the version. To install at install time instead, register this hook
before `vim.pack.add`:

```lua
vim.api.nvim_create_autocmd("PackChanged", {
  callback = function(ev)
    local d = ev.data
    if d.spec.name == "jupynvim" and (d.kind == "install" or d.kind == "update") then
      dofile(d.path .. "/lua/jupynvim/install.lua").run({ dir = d.path })
    end
  end,
})
```

With [`mini.deps`](https://github.com/nvim-mini/mini.nvim), the same call
goes in its hooks. Pin `checkout` to a release tag, since the binary is
matched to the release the plugin came from:

```lua
local function build(p) dofile(p.path .. "/lua/jupynvim/install.lua").run({ dir = p.path }) end
MiniDeps.add({ source = "sheng-tse/jupynvim", checkout = "v0.4.6",
               hooks = { post_install = build, post_checkout = build } })
```

Any other way works too, a manual clone included. Run `:JupynvimInstall`
once, or just open a notebook. `:checkhealth jupynvim` shows what is
installed and what is missing. Set `auto_install = false` if you would
rather nothing is downloaded without you asking.

The installer fetches the in-process library `libjupynvim` together with
`jupynvim-core` on all four platforms, also on macOS x86_64 and Linux arm64,
where `jupynvim-core` itself is built with cargo (a cargo build makes the
library too, and then nothing is downloaded over it). If the library is
missing or out of date when you open a notebook, whichever `jupynvim-core`
you use (the plugin's own, `core_path` or one on `PATH`), or when a feature
first needs it, it is fetched in the background while you keep working,
unless `auto_install` is off, the library is turned off, `native.path` or
`JUPYNVIM_NATIVE` names a library of your own, or the plugin's directory is
not writable. `:checkhealth jupynvim` shows whether it loaded and from where.

`JUPYNVIM_RELEASE_BASE` points every download at a mirror laid out like the
GitHub release downloads (`<base>/<tag>/<asset>`, an `https://` mirror or a
`file://` directory), for machines that cannot reach GitHub; the
`SHA256SUMS` check applies the same way. Any other scheme is refused and
nothing is downloaded: over plain `http://` the binary and its `SHA256SUMS`
could both be replaced on the way.

## Security of the prebuilt binary

The installer, whether it runs from a build hook, `:JupynvimInstall` or the
first time a notebook opens, downloads `jupynvim-core` from the GitHub release
over HTTPS and runs it. HTTPS protects the download in transit; on top of that
the installer checks the binary against the release's published `SHA256SUMS`
and refuses it if the hash does not match or the binary is not listed, which
catches a corrupted, swapped, or unlisted binary. Releases
older than this check publish no `SHA256SUMS`, and the installer warns and
proceeds for those. It does not yet catch a release where both the binary and
`SHA256SUMS` were replaced; signature verification for that is on the roadmap.
If you would rather not trust the prebuilt `jupynvim-core`, point `core_path`
at a binary you built yourself, or build from source (the installer falls
back to `cargo build` on unsupported platforms). `core_path` covers only
`jupynvim-core`: the library prebuilt still comes with every core, from build
hooks, `:JupynvimInstall`, the first notebook open and a feature's first use.
To run no prebuilt code at all, set `auto_install = false` and either build
both with `cargo build --release` in `core/` (and skip the build hook and
`:JupynvimInstall`, which fetch the prebuilts), or point `core_path` at your
own build and turn the library off with `native = false`.

The library prebuilt, `libjupynvim`, goes through the same check, but
strictly: it must be listed in `SHA256SUMS` with a matching hash, and one
that cannot be checked (no `SHA256SUMS` to fetch, or no `shasum` or
`sha256sum` on the machine) is refused instead of installed with a warning.
It loads into Neovim's own process, so before it is moved into place it must
also load in a separate Neovim and report the plugin's version and a
compatible interface. A library that fails any of these checks is never
installed, jupynvim runs without it, and a refusal by the background install
is shown in a one-line notice.

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
  active, `<leader>e` (the project root of the remote file you are in, found
  by walking up for a `.git`) and `<leader>E` (the remote working directory,
  which `:JupynvimRemoteCd` moves) mirror what those keys mean locally, and
  your file and grep pickers target the remote too. These keys are borrowed
  only for the length of the session: if you already had a mapping, jupynvim
  restores it exactly when the session ends, so your leader menu is untouched
  when you are not connected. Keys you had not mapped stay bound and fall
  back to the local equivalent.
- **Terminals, VSCode-style.** A bottom PTY shell (`:JupynvimTerm` or
  `<C-/>`) and a second one on the right (`<leader>tr`) tile together, so you
  can run a job in one and keep working in the other. Resize with
  Shift+hjkl in normal mode (or Ctrl+arrows, also in insert). Both run on the
  remote, with vi editing on the shell prompt.
- **Search.** `:JupynvimGrep <alias> <pattern> [<path>]` runs ripgrep on the
  remote and fills the quickfix list.
- **Slurm.** `:JupynvimUseJob <alias> [<jobid>]` routes the kernel through an
  `srun` overlay so it lands on an allocated compute node.
- **Multiple remotes.** Local and several remotes coexist. Every notebook
  talks to its own backend: a local notebook always runs, saves and completes
  on the local one, even while a remote session is active, and a remote
  notebook on its remote. `:JupynvimUseLocal` points the explorer, terminal
  and picker keys back at this machine without stopping any backend. A remote
  file is one buffer whichever of these names you use: `~/work/train.ipynb`,
  a relative name and the absolute path the explorer shows are the same
  notebook, and opening it again focuses the one that is open. A path through
  a symlinked directory or with a `..` step is a different name, and opens a
  second buffer. A notebook is open from one backend at a time: opening the
  same path from another remote, or locally, is refused until the first is
  closed with `:bwipeout`, and `:edit` of that path goes to the notebook
  already open. `:bdelete` only hides the buffer, which keeps its backend:
  `:edit` of the path (or `:buffer`) brings the remote notebook back and says
  so. After `:bwipeout`, `:edit`, a file explorer and `:JupynvimOpen` open the
  path from this machine.

## Concepts

A jupynvim buffer is one Neovim buffer per `.ipynb` file. Cells are line
ranges separated by an invisible marker, `# %%[jupynvim:cell-sep]`,
concealed at runtime. Cell type, execution count, and outputs live as state
on the notebook object. The buffer text contains only what you'd type as
the cell's source.

Cells aren't floating windows or scratch buffers. Splits, marks, motions,
and search all work like a normal buffer. The visual block appearance comes
from extmark virtual text, not separate windows.

The Rust backend (`jupynvim-core`) owns the Jupyter connection. One runs on
this machine for every local notebook, and one on each connected remote for
that remote's notebooks. Kernel events flow back as msgpack-RPC
notifications which the Lua side maps to cells.

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
| `:JupynvimPauseAnimations` | Pause every GIF animation, or resume them when paused. |
| `:JupynvimRenderStats` | Show the image write counters since the last call, then reset them. |
| `:JupynvimReset` | Close every session and reopen every notebook on its own backend. |
| `:JupynvimDebug` | Print buffer/cell/notebook state. |
| `:JupynvimPalette` | Show the color tokens jupynvim draws with and where each came from. |
| `:JupynvimConnect [<alias>]` | Connect to a remote (picker, configured profile, or `user@host`). |
| `:JupynvimOpenRemote <alias>:<path>` | Open a notebook or file on a connected remote (`~`, `~/path` and relative paths resolve against the remote's home; another user's home, `~user/path`, is not expanded, so give its absolute path). |
| `:JupynvimExplorer` | File browser for the active remote tree. |
| `:JupynvimTerm` | Toggle a PTY terminal on the remote (local when not connected). |
| `:JupynvimGrep <alias> <pattern> [<path>]` | ripgrep the remote into the quickfix list. |
| `:JupynvimRemoteCd <path>` | Change the remote working directory. |
| `:JupynvimUseJob <alias> [<jobid>]` | Route the kernel through a Slurm `srun` overlay. |
| `:JupynvimUseLocal` | Point the explorer, terminal and picker keys back at this machine. |
| `:JupynvimDisconnect [<alias>]` | Tear down a remote connection. |

## Keymaps

All notebook keymaps are buffer-local. They only exist while you're inside
an `.ipynb`.

A notebook opens in command mode, like VSCode and JupyterLab. `j` and `k`
select whole cells, `dd`, `yy`, `p`, `a` and `b` act on cells, and `u`
undoes the last cell you added, pasted, deleted or moved. Enter or `i`
edits the selected cell with plain vim, and Esc goes back. While editing,
`j`, `k`, `gg`, `G` and the paragraph and sentence motions stay inside the
cell, and an edit that would join two cells or delete the boundary between
them is taken back. `u` while editing undoes your last edit, not an output
a run wrote, and stops at the last cell added, deleted or moved. `]c` and
`[c` move to the next or previous cell and keep you editing, and a search,
a diagnostic jump or a click that lands in another cell moves the editing
there.

### Cell execution

| Key | Action |
|---|---|
| `<S-CR>` or `<leader>nr` | Run cell and select the next one, or add and edit a new cell at the end. `<S-CR>` works in insert mode too |
| `<C-CR>` | Run cell, stay. Works in insert mode too |
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
| `]c` or `[c` | Jump to next or prev cell, in either mode |

### Outputs and images

| Key | Action |
|---|---|
| `<C-j>` or `<C-k>` | While editing, hop between the cell's source and its output, which takes every vim motion. In command mode they move between windows |
| `<leader>nI` | Save current cell's image to file |
| `<leader>nD` | Delete an embedded image from a markdown cell |
| `]i` or `[i` | Jump to next or prev cell with an image |
| `<leader>no` | Show all of an output cut at `max_output_lines`, or cut it again |
| `<leader>nO` | Hide a cell's whole output, plots included, or show it again |
| `<leader>nl` | Set how many lines of a cell's output show. It asks for the number |
| `gx` | Open the link under the cursor |

A long output shows its first `max_output_lines` lines and its last 5, with
a marker between them. `<leader>nl` gives one cell its own number, and
`<leader>no` then toggles between that and every line. All of these change
only the view. The `.ipynb` keeps every output and the notebook isn't marked
modified. A hidden output and a cell's own number stay when the cell runs
again, while a new run cuts an expanded output back. A notebook you save
reopens with its outputs shown the same way, unless the file changed since.

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

  -- How many lines of an output show. A longer one shows its first
  -- max_output_lines lines and its last 5, with a marker between them, and
  -- <leader>no expands it. <leader>nl sets another number for one cell. The
  -- .ipynb keeps everything. 0 renders all of it.
  max_output_lines = 500,

  -- The in-process library, libjupynvim, runs heavy work on worker threads
  -- inside Neovim, never on the UI thread. It is optional and everything
  -- works without it. enabled = false never loads it; native = false is
  -- the same. path = "<file>" loads a library you built instead of the one
  -- in core/target/release, next to jupynvim-core; ~ and $VARS in it are
  -- expanded, and a relative path is taken from the current directory when
  -- the library first loads. workers = 0 picks one less than the CPU
  -- count, at least 1 and at most 4; workers = N runs N threads, 1 to 64
  -- (a larger N runs 64).
  -- In the environment, JUPYNVIM_NATIVE=off turns it off and
  -- JUPYNVIM_NATIVE=/path/to/libjupynvim.so loads that file, even with
  -- enabled = false.
  native = {
    enabled = true,
    path = nil,
    workers = 0,
  },

  -- The colors jupynvim draws with are derived from your colorscheme (see
  -- Colors below). A token set here wins over what the colorscheme gives, for
  -- example palette = { fill = "#1c1f31" }; canvas is the background they are
  -- drawn on, which is otherwise Normal's background or, when Normal has
  -- none, the terminal's own. :JupynvimPalette lists every token and where it
  -- came from.
  palette = {},

  -- Override the path to the jupynvim-core binary. Auto-detected from the
  -- plugin directory if unset.
  core_path = nil,

  -- Per-action keymap overrides. A string replaces the default lhs, a table
  -- sets the lhs and the mode, and `false` disables the binding. The full
  -- action list lives in lua/jupynvim/notebook/keymaps.lua. <S-CR> and
  -- <C-CR> are bound in normal and insert mode; a replacement that starts
  -- with a printable key, like a space leader, stays out of insert mode
  -- unless you pass `mode`, so typing that key in a cell never stalls.
  keymaps = {
    -- example: rebind run-and-advance, in normal mode only as noted above
    -- run_advance = "<leader>jr",
    --
    -- example: rebind run-and-stay and pick its modes yourself
    -- run_stay = { mode = { "n", "i" }, lhs = "<C-s>" },
    --
    -- example: disable move-cell-up
    -- move_up = false,
  },

  -- Skip the entire default keymap set if you want to bind everything yourself.
  disable_default_keymaps = false,

  -- Walk up from the notebook's directory to find a `.venv/bin/python` (or
  -- `.venv/Scripts/python.exe` on Windows) and use it as the kernel
  -- interpreter when ipykernel is installed there. A Pixi project's default
  -- env (`.pixi/envs/default`, with `python.exe` at the env root on Windows)
  -- is used the same way when there is no venv beside it. Bypasses needing
  -- to register a per-project user kernel. Set false to use only registered
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

  -- Borrowed only while a remote session is active. If you already have a
  -- mapping for one of these, jupynvim takes it on connect and gives it back
  -- exactly on disconnect; if you don't, it stays bound and falls back to the
  -- local equivalent. Set a group to {} to leave those keys alone entirely.
  explorer_keys     = { "<leader>e" },  -- remote tree at the project root
  explorer_cwd_keys = { "<leader>E" },  -- remote tree at the remote cwd
  terminal_keys = { "<c-/>", "<c-_>" },           -- toggle a remote PTY
  pick_keys = {
    files = { "<leader>ff", "<leader><space>" },
    grep  = { "<leader>/", "<leader>sg" },
  },
})
```

## Colors

jupynvim derives the colors it draws with from your colorscheme, so that what
it adds to the editor sits among your own colors and not in a theme of its
own. It works with 35 color tokens (text, fill, edge, heading, link, inline
code, task and alert colors, and so on). For each token it uses the first of
these that has a color:

1. Your `palette` setting.
2. The colorscheme's Neovim highlight groups (`Normal`, `Comment`,
   `@markup.heading`, `DiagnosticError`, and the like).
3. The colors of the colorscheme's VS Code port, when it is a known one. A
   port is found by the colorscheme's name. These names have one whatever
   `background` says: `tokyonight-storm`, `tokyonight-night`,
   `catppuccin-mocha`, `catppuccin-latte`, `dracula`, `nord`, `kanagawa-wave`,
   `github_dark`, `github_dark_default`, `github_light`,
   `github_light_default`, `onedark_vivid`, `onedark_dark`, `rose-pine-main`
   and `rose-pine-dawn`. With a dark `background`, `onedark`, `kanagawa` and
   `vscode` (VS Code's Dark+) have one. In the light or dark kind that
   `background` says, `gruvbox`, `rose-pine`, `everforest` and `solarized`
   have one. Any other name or variant (`tokyonight-moon`,
   `catppuccin-frappe`, `kanagawa-dragon`, and so on) has no port and takes the
   other three steps.
4. VS Code's own defaults for a dark or a light theme.

Then a few rules keep the result readable on any background. A translucent
color is flattened over the real background, as VS Code does. A fill too
close to the background is moved until it shows. A text color below 4.5:1
contrast with its background is made darker or lighter until it reads.

The names of the tokens, which `palette` accepts: `canvas`, `text`,
`text_muted`, `comment`, `fill`, `lifted`, `edge`, `track`, `thumb`, `accent`,
`heading_h1_h3`, `heading_h4_h5`, `heading_h6`, `math`, `link`,
`inline_code_fg`, `inline_code_bg`, `task_checked`, `task_unchecked`,
`alert_note`, `alert_tip`, `alert_important`, `alert_warning`, `alert_caution`,
`ok`, `info`, `warn`, `error`, `selection_border_command`,
`selection_border_edit`, `selected_bg`, `mark_bg`, `kbd_bg`, `kbd_border`, and
`quote_bar`.

The background everything is drawn on is `Normal`'s. When the colorscheme
leaves `Normal` transparent, it is the terminal's own background, which
jupynvim asks the terminal for (OSC 11) once Neovim has started, and reads
whenever the terminal tells it (a terminal that reports a change of theme
makes Neovim ask again, and jupynvim reads the answer). A terminal chain that
reports no change (tmux 3.5, for one) tells nobody, so jupynvim asks
again each time `background` changes: that is when a changed terminal shows,
and until then the color from the last answer is the one in use. Neovim sets
`background` from every answer the terminal gives, and jupynvim does not let
its own questions do that: nothing is asked before Neovim has started, so
that a `background` you set in your config stays, and while a question is in
flight (the first one, right after start-up, included) Neovim's handler is out
of the way; any answer that is not the answer to jupynvim's question still
reaches it. So a `background` you chose that the terminal does not share, in
your config or right after Neovim has started, for example a light
colorscheme in a dark terminal, is left as it is. The question asked at
start-up does not redraw the screen, nor does any question while messages wait
for Enter, so the messages of the start-up (a plugin that failed to load, a
warning) show as they do without jupynvim. An opaque colorscheme never
needs the terminal's color, and nothing is asked then. Where the terminal does not answer, for
example over mosh, set the canvas yourself:

```lua
require("jupynvim").setup({
  palette = { canvas = "#1e1e2e", fill = "#313244" },
})
```

The palette is derived again when you change the colorscheme or `background`.
`:JupynvimPalette` lists every token, its color, and where it came from, and
`:checkhealth jupynvim` reports the colorscheme, the background, where the
canvas came from, and any setting that was ignored. The palette needs the
in-process library (see Requirements); without it, colors stay as they are.

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
  Neovim (Lua frontend)  <-- FFI -->  libjupynvim (Rust, inside Neovim,
           |                          worker threads)
           |  msgpack-rpc over stdio
           v
  jupynvim-core (Rust backend)
           |
           |  ZMQ + HMAC-SHA256, Jupyter wire protocol
           v
         ipykernel
```

The Lua frontend encodes the Kitty graphics escapes for inline images
itself and hands them to Neovim's UI with `nvim_ui_send` (Neovim 0.12+),
which writes them to the terminal between its own screen updates; the
backend does not write to the terminal then. Neovim 0.11 has no such call;
there the escapes go out on Neovim's stderr channel, or from the backend
when Neovim's stderr is not a terminal.

The Lua side hijacks `*.ipynb` via `BufReadCmd`, renders cells with
virtual-line borders, transmits PNG bytes via the Kitty graphics
protocol, drives gif animation on a `vim.uv` timer, and owns keymaps
and commands.

The Rust backend runs one async task per ZMQ socket so `send` and
`recv` don't conflict, HMAC-SHA256 signs every message, parses and
serializes `.ipynb` (nbformat v4) preserving unknown fields, routes
iopub events to cells via `parent_msg_id`, and decomposes animated
GIFs into a frame sequence with ImageMagick.

Rust computes and Lua paints. `libjupynvim` is a Rust library that Neovim
loads into its own process through LuaJIT's FFI. Heavy work runs on its
worker threads; queuing a job takes no lock unless a parked worker has to
be woken, so the UI thread does not wait for workers that are busy. A
finished batch writes one byte to a pipe that Neovim's
event loop watches, so results reach Lua on the main loop as soon as they
are ready, with no timer. Documents are passed by pointer rather than
copied, and large results are read in place instead of being decoded on the
UI thread, which is left to paint.

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
`$XDG_CACHE_HOME/jupynvim/core.log` elsewhere. Set `JUPYNVIM_LOG_DIR` to
write `core.log` to another directory. Set `JUPYNVIM_LOG=debug`
for verbose output. The Lua frontend logs to
`vim.fn.stdpath("cache") .. "/jupynvim/lua.log"`.

## Runtime files

Each kernel's connection file is written to a runtime directory only you
can access: `jupynvim` inside `$XDG_RUNTIME_DIR` when that is a private
directory of yours (no group or other access), otherwise `jupynvim` inside
Jupyter's runtime directory (`$JUPYTER_RUNTIME_DIR`, else `runtime` in
Jupyter's data directory: `$JUPYTER_DATA_DIR`, else `~/Library/Jupyter` on
macOS and `$XDG_DATA_HOME/jupyter` or `~/.local/share/jupyter` elsewhere),
otherwise `jupynvim-<your uid>` in the system temp directory (`$TMPDIR`
when set). Set `JUPYNVIM_RUNTIME_DIR` to an absolute path to use `jupynvim`
inside that directory instead; the directory itself is left as it is (when
it does not exist, it is made with mode 0700, as is every missing directory
above it). In a directory with the sticky bit that others can write to, such
as `/tmp`, the name is `jupynvim-<your uid>`.

A directory is used only when it and every directory above it can be
written to only by you or root: one your group can write to is skipped,
even when you are its only member, while one with the sticky bit is fine.
On macOS access control lists count too: a directory with an entry that
lets anyone but root add or delete entries in it is skipped, an entry
naming you included (it adds nothing to the mode; on Linux a POSIX ACL
entry that lets someone write shows in the mode; NFSv4 ACLs are not read).
A directory that cannot be used is skipped for the next one, and `core.log`
says why. Directories are created with mode 0700 and files with mode 0600,
and a runtime directory of yours (`jupynvim` or `jupynvim-<your uid>`) that
already exists with group or other access is set to 0700, also one inside
`JUPYNVIM_RUNTIME_DIR`. On macOS the runtime directory keeps no access
control list entry but root's, so nothing in it inherits one.

A kernel's file is removed when the kernel stops, and the backend's
directory when the backend exits. A backend that starts a kernel also runs
one small helper process, `jupynvim-core --guard`, which stops that
backend's kernels and removes its directory when the backend ends without
doing so itself (for example when it is killed). When the backend and the
helper are both killed, the files they leave are removed the next time
jupynvim starts, but not the kernels: ipykernel exits by itself about a
second after its backend is gone, while other kernels (IJulia, IRkernel, a
kernel started by a wrapper script) keep running until you stop them. In a
runtime directory shared by several machines, such as a cluster home
directory, a directory another machine left is removed once nothing in it
has changed for a week; on a file system without working file locks it
stays until you remove it. A remote backend does the same on its host.

ipykernel picks its own ports and writes them to the connection file; other
kernels get ports reserved for them. jupynvim tells ipykernel apart by its
command line. A kernel taken for ipykernel that never writes its ports back
fails to start after 5 minutes: add `"jupynvim": {"ports": "reserved"}` to
the `metadata` of its `kernel.json` (`"kernel"` does the opposite).

Any kernel that is not ready 5 minutes after it was started fails to start,
and its processes are stopped. If a kernel's first start takes longer, as a
first IJulia start that precompiles its packages can, run that step once
outside jupynvim (for IJulia, `julia -e 'using IJulia'`). A kernel's own
process must keep running while the kernel runs: a launcher that starts the
kernel in the background and exits (a daemonizing wrapper script,
`docker run -d`) makes the start fail with
`kernel '<name>' exited during start`; run such a launcher in the
foreground instead (`exec` in a wrapper script, `docker run` without `-d`).

## Limitations

Kitty graphics or bust. Without a graphics-capable terminal, set
`image_renderer = "chafa"` for ASCII output.

Ghostty 1.3 doesn't implement the Kitty animation protocol, so animated GIFs
are driven by re-transmitting frames on a timer. Cheap, works everywhere, but
consumes a small amount of CPU while playing. Frames follow the GIF's own
clock: each one shows for its delay, counted from when the GIF started, so a
frame that goes out late or is skipped never slows the animation down. A GIF
scrolled out of view sends nothing, also while its cell's last line is still
on the window's last rows and none of the GIF shows; it picks up where its
clock is when it comes back. On Neovim 0.12, when the terminal reads frames
slower than a GIF plays (a slow link, a large animation), frames are skipped
instead of queued, so what you type waits behind at most 64 KB of frames, or
one frame when a frame is larger: about a second on a 60 KB/s link, a fifth of
a second for 115 KB frames on a 600 KB/s one (`:JupynvimPauseAnimations` stops
it); with two terminals attached (`nvim --remote-ui`), the slower one sets the
pace. Frames go out only as fast as the terminal confirms reading them, so
over a link with a long round trip a GIF plays slower than its own rate: at
most 64 KB of frames, or one frame, per round trip. With several GIFs in view
they share that, and the one that has waited longest goes first, so a slow GIF
is not held back by a fast one. When Neovim starts, or a terminal attaches,
leaves or resumes, the first frame waits until the terminal has answered a
version query (XTVERSION), which Ghostty, kitty, WezTerm and tmux 3.2 or newer
answer, so the terminal's answers to Neovim's own queries are not taken for
the frames'. Inside tmux before 3.2, which does not answer it (jupynvim asks
the running tmux for its version once), the query is skipped and the first GIF
starts at once; any other terminal that does not answer it starts the first
GIF after 30 s, once per session. If a query's answer only comes later (a very
slow link), the query is used again from then on. Quitting, suspending or
detaching waits for the frames still on their way to the terminal, as long as
the link has been seen to need, up to a bound, so none of the terminal's
answers reaches your shell. Nothing is sent while no terminal shows Neovim
(suspended with CTRL-Z, or after `:detach`); what changed meanwhile is sent
when one does again. On Neovim 0.11 images go to the terminal Neovim was
started in: after `:detach`, `nvim --remote-ui` run in that terminal shows
them again, and one run in another terminal shows none (on Neovim 0.12 new
images and GIF frames go to every terminal UI on the same side of tmux as the
one Neovim started in: tmux wraps the escapes, so a terminal attached from
outside tmux to an editor started inside it, or the other way round, shows
none).

On Neovim 0.11 an image write can land inside one of Neovim's own screen
updates while the terminal is busy, or a screen update inside an image write.
That leaves garbled text on screen (a stray `66:97m`, a broken cell border, or
rows of image data printed as text) until you pause the GIF with
`:JupynvimPauseAnimations` (run it again to resume) and then run `:mode` (or
press `<C-l>` with its default mapping), which clears and redraws the screen;
`:redraw!` does not, and a redraw while the GIF still plays can garble the
screen again. jupynvim holds a GIF's frames back while Neovim redraws the
screen (scrolling, typing) and sends the frame its clock is at once the screen
has been still for 150 ms, or after a second at the latest, so it is rare; a
redraw that starts while an image is being written (a GIF frame, a new plot)
can still do it. `:JupynvimPauseAnimations` stops the GIF frames that cause
most of it. jupynvim keeps image writes few there: nothing for GIFs out of
view, GIF frames only between screen redraws, and a refresh of the visible
images at most once a second, once you stop typing. Neovim 0.12 writes images
in order with the screen and does not have this problem.

One local backend serves every local notebook, and each remote has one
backend for its notebooks. `:JupynvimReset` reopens every notebook on its own
backend, which restarts its kernel.

Widgets draw as text until the pixel renderer is in. A slider, a progress bar
or a button shows its state as text, and an Image widget shows its format and
size, not its picture. Nothing in the editor clicks a button or moves a slider
yet, so a widget's callback runs only when the kernel changes the widget.
Images inside an Output widget show above the widget's text, not in place.

Remote LSP is partial. Kernel-driven completion and hover work over SSH, but
running a full editor language server on the remote and relaying it is still
in progress; editor-side LSP features are most complete on local notebooks.

A Neovim built without LuaJIT, or one linked against musl as on Alpine,
cannot load the prebuilt `libjupynvim`, and jupynvim runs without it.

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

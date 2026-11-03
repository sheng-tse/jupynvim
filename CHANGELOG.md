# Changelog

Every release and its full notes are on the [releases page](https://github.com/sheng-tse/jupynvim/releases). This file starts at v0.5.0.

## v0.5.0-beta.1 (pre-release)

The first beta of v0.5.0. What changed since v0.4.6:

- On Neovim 0.12 images are written in order with the screen, so they no longer garble text or break cell borders. A GIF out of view sends nothing, GIFs keep their own speed and wait for a slow terminal, and nothing is written while Neovim is suspended or detached. New commands: `:JupynvimPauseAnimations` and `:JupynvimRenderStats`.
- Images wider or taller than 116 cells draw every row and column.
- Every notebook talks to its own backend. A local notebook runs, saves and completes on the local backend while a remote session is active, `:JupynvimUseLocal` no longer stops a backend, and a remote file is one buffer by whichever name you open it.
- Widgets from ipywidgets 8 talk to the kernel: `tqdm.notebook` bars update live, Output widgets capture what is printed inside them, and the widget state is saved in the notebook. They draw as text for now.
- Colors come from your colorscheme, as 35 tokens you can override with `palette = { ... }` and list with `:JupynvimPalette`.
- The in-process library `libjupynvim` installs with the backend and runs heavy work off the UI thread. Everything works without it.
- Kernel connection files are kept in a private per-user runtime directory and removed when kernels stop or jupynvim exits, and kernels start faster.
- A second notebook opened while the first is attaching joins its backend instead of starting another (#44, by @nyxar77).
- A pandas Styler shows its table as aligned text instead of its repr (#45, by @Matthew-Eucaristo).
- The comment above `image_rows` names the real default, 16x48 (#46, by @Matthew-Eucaristo).
- A project's Pixi environment is found automatically when ipykernel is installed in it (#47, by @jdefowler).
- Run all, run above and run below mark the cells waiting behind the running one as queued (#48, by @ClaytonMcCray).
- `:checkhealth jupynvim` starts with the plugin's version. `JUPYNVIM_LOG_DIR` moves `core.log`, and `JUPYNVIM_RELEASE_BASE` points downloads at a mirror.
- The release workflow refuses a tag that is not the version in `core/Cargo.toml`.

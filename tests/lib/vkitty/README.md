# Headless Kitty graphics harness

This folder holds a test harness written in Python. It records the exact bytes a program sends to
its terminal, interprets them the way Ghostty does (the text grid and the Kitty graphics
protocol: every transmission medium, chunking, zlib, Unicode placeholders, virtual and cursor
placements, animation, deletes), and paints the resulting screen to pixels at 2x. A placeholder
cell shows its real image pixels, not a stand in box. It needs no terminal window, no network and
no Chrome at test time, and it is fast enough to run on every screen test.

The pieces are used by:

- `tests/vkitty_spec.py`: the synthetic spec. No tmux and no nvim, only byte streams the spec builds.
- `tests/vkitty_screen.sh`: the same model against a real tmux 3.5a (a battery of VT streams) and
  against a real notebook session (nvim, the backend, tmux), recorded by the relay.
- `tests/run_all.sh`: runs both as two sections.

The text in this file is about the harness only. It describes what the model reproduces from
Ghostty, kitty and tmux, and where it stops.

Two Ghostty versions are modeled. `ghostty-1.4.0` (released 2026-10-27, the current release)
is the default of the relay, the replay tool and the screen test. `ghostty-1.3.1` is the
oldest supported version (the plugin supports Ghostty 1.3 and later) and the default of the
library's own `Terminal`, which the older cases of the spec use. A recording keeps the profile it
was made with. Where 1.4.0 differs from 1.3.1 (a retransmission to an image id removes the
placements, the deletes, C0 controls, CAN and SUB, the 65 MiB cap, images that move with a scroll
of a region, Unicode 18, the animation actions) the section "Profiles" lists it, and the spec group
`g140` runs the same bytes through both profiles.

## Running it

Python 3.10 or newer, with the packages of `requirements.txt` (numpy, Pillow built with raqm for
shaped text, fontTools). Install them into a dedicated environment, never into the system Python.
On Linux raqm needs the `libfribidi0` system library at run time, `ps` (package `procps`) must
exist, and the renderer's fallback chain needs fontconfig with DejaVu Sans Mono, Noto Sans CJK SC
and Noto Color Emoji (see "Known gaps", Renderer). The whole spec has run in a `python:3.12-slim`
container with those packages (aarch64, 3.12), 390 cases. `python.sh` defines
`jnv_vkitty_python`, which prints the first `python3` that can run the harness: the one named by
`JUPYNVIM_TEST_VKITTY_PYTHON`, then `JNV_KERNEL_PYTHON`, then every `python3` on `PATH`.

```
PY="$(jnv_vkitty_python)"            # after: source tests/lib/vkitty/python.sh
"$PY" -I tests/vkitty_spec.py                       # every group
"$PY" -I tests/vkitty_spec.py --only tokens,vt      # some groups, or group/case names
"$PY" -I tests/vkitty_spec.py --list
bash tests/vkitty_screen.sh                         # all screen cases (1 battery, 2 to 4 notebook,
                                                    # 5 snapshot cursor, 6 writer rule)
bash tests/vkitty_screen.sh 1                       # the battery only
```

Every program of the harness runs under `python -I` and sets `sys.dont_write_bytecode` itself
(`-I` ignores `PYTHONDONTWRITEBYTECODE`), so a run writes nothing into the repository tree.

The spec prints `ok group/name (N ms)` or `FAIL group/name: message` per case and ends with
`ALL VKITTY CHECKS PASSED` (exit 0) or `N VKITTY CHECKS FAILED` (exit 1). When a busy host left
timed limits undecided (see Performance), the line before the verdict says so; that never changes
the exit status. A usage error exits 2.
Its groups: `tokens` (the byte tokenizer), `widths` (Unicode width and grapheme tables), `vt` (the
terminal model), `kgp` (Kitty graphics commands, storage, responses, deletes), `media` (file,
temporary file and shared memory), `place` (placements, pins, Unicode placeholders), `anim` (the
kitty profile's animation), `ssim` and `render` (the renderer), `relay` (the live recorder, its
recording, the live terminal's worker, the replay command line), `g140` (the same bytes through
the ghostty-1.3.1 and ghostty-1.4.0 profiles, asserting what differs), `perf` (throughput, decided on the
measurements the host did not disturb), `perfclock` (the clock that decides them), `faults` (the
fault switches below) and `meta` (checks on the harness's own files).

## Modules

| Module | What it does |
|---|---|
| `tokens.py` | bytes to tokens: Ghostty's parser state machine, tmux 3.5a's passthrough and UTF-8 rules |
| `widths.py`, `widths_data.py`, `widths_data_140.py`, `widths_rules.py`, `widths_rules14.py` | Ghostty's cell widths and grapheme breaks per version (generated tables, Unicode 17.0.0 and 18.0.0) |
| `style.py` | cell styles and the SGR parser |
| `vt.py` | the terminal model: grid, modes, cursor, margins, screens, mode 2027 |
| `kgp.py`, `media.py`, `unicode_place.py`, `anim.py` | Kitty graphics: commands, storage, media, placeholders, the kitty profile's animation |
| `snapshot.py` | what a terminal shows at one moment (`Snapshot`) and its JSON report |
| `render.py`, `fonts.py`, `ssim.py` | the renderer, its fonts, the structural similarity score |
| `grid_tmux.py`, `battery.py` | a tmux `capture-pane` dump as a snapshot and the comparison; the VT streams of the tmux test |
| `relay.py`, `live.py`, `recording.py`, `replay.py` | the live recorder, its live terminal worker, the recording format, replay |
| `checks.py` | the checks of the notebook screen cases |
| `perfclock.py` | samples, counters and verdicts that decide a timing limit on undisturbed measurements |
| `faults.py` | switches that break one component on purpose |

## Recording

`relay.py` is a pty relay. It runs a program on a new pty, forwards its output to the terminal it
runs in, and records every byte.

```
relay.py --rec DIR [--size CxR] [--cell 13x33] [--pad 4]
         [--profile ghostty-1.4.0|ghostty-1.3.1|kitty]
         [--hop auto|tmux|tmux-off|none] [--respond ghostty|none] [--gfx-fifo PATH] [--ctl PATH]
         [--no-forward] [--media-unlink yes|no] -- CMD ARGS...
```

- Inside a tmux pane, run it as the pane's command: the child's bytes go on to tmux and the
  recording holds what the child wrote. Headless, give `--no-forward` and a size; the relay then
  never enters tty mode and nothing reaches a terminal.
- `--hop` says whether the child's bytes come through tmux. `auto` (the default) means `none` when
  `TMUX` is not set in the relay's environment. When it is set, `auto` reads the pane's
  `allow-passthrough` (`tmux show-options -Apv allow-passthrough`): `on` and `all` mean `tmux`,
  `off` (tmux's default) means `tmux-off`, and an old tmux without the option, a tmux that cannot
  be run or an unexpected answer mean `tmux` (`VKITTY_TMUX` names another program than `tmux`
  for that question; the spec puts a stub there). Hop `tmux-off` is tmux with passthrough off: every
  `DCS tmux;` and every raw APC is dropped, so no graphics command reaches the terminal, the tap
  reads no file, and no `a=q` is answered (`--respond ghostty` answers none, as a real setup
  would not); the model counts each ignored DCS and warns. This is the row of a remote matrix for
  "passthrough off". The hop is recorded in the start event, and the tap and the live terminal
  use it.
- `--gfx-fifo PATH` makes a second byte channel, for a program that writes its graphics to a file
  or a FIFO of its own (a backend whose tty is that FIFO). It is recorded in `gfx.bin` and never
  forwarded.
- `--ctl PATH` is a FIFO with lines `mark NAME`, `resize C R`, `reattach` and `quit`. A mark drains what the
  child and the graphics FIFO have written, waits for the live terminal when there is one, records
  the mark, and then writes `NAME` to `PATH.ack`. A waiter removes `PATH.ack` before each mark: a
  repeated name would otherwise look acknowledged at once. `resize` records the new size, then
  resizes the pty and signals the child. `reattach` drains and records a reattach: a new outer
  terminal (a tmux client attached from elsewhere) takes the old one's place. The screen text and
  cursor stay, as tmux redraws them for the new client, and the terminal's graphics storage is
  empty on both screens: every image and placement is gone, and a program has to send them again.
  Nothing is sent to the child. Replay and the live terminal both apply it (the `reattach` event),
  so a test can assert that every placeholder cell resolves again only after the images were
  re-uploaded (`missing` before, empty after). `quit` sends SIGTERM to the child.
- `--respond ghostty` answers the child's queries the way the model does (see "VT queries"). It
  runs the model in a worker process of its own (`live.py`), which the relay feeds with one line
  per event. The bytes stay in the recording's files, so the relay's cost per read does not include
  the emulator. The worker's answers arrive asynchronously, as a real terminal's do, so a `resp`
  event can follow later data events, but a mark waits until the worker has handled everything
  before it (at most 30 s), and the end waits for the worker's final report. An answer that arrives
  after the child exited is recorded and not delivered. A failure of the worker is an `error` event
  and the relay goes on without it (no `live_final.json`). The worker's pid is `live_pid` in the
  start event.
- The tap reads every file or shared memory object a transmission names, once, and removes it as
  the terminal would (`--media-unlink yes`, the default), so the replay never needs the object
  again: its bytes are in `blobs/`.

A recording is a folder:

```
tui.bin  gfx.bin (with --gfx-fifo)  blobs/NNNNNN.bin  events.jsonl  live_final.json (with --respond ghostty)  done
```

`events.jsonl` has one JSON object per line, in arrival order: `start` (size, cell, pad, profile,
hop, `live_pid`), `data` (channel, offset, length, time), `resize`, `reattach`, `blob`, `resp`
(an answer, base64), `mark`, `error` and `end`. The start event is flushed at once, so it is on disk before the child
runs.

Recording with a real terminal downstream: when a real terminal shows the session and should do
its own work, pass `--media-unlink no --respond none`. The terminal then reads and removes the
files and answers its own queries, and the relay only records.

A headless relay under hop `tmux` answers no VT query, since no tmux is there to answer them. A
recording that needs those answers runs inside a tmux pane.

## Replay and render

```
replay.py REC_DIR [--at MARK] [--png OUT] [--report OUT.json] [--crop R0:R1] [--profile P]
          [--hop tmux|tmux-off|none] [--no-images]
replay.py --stream TUI_FILE --size CxR [--gfx GFX_FILE] [same outputs]
replay.py --capture CAP.ansi --size CxR [--gfx GFX_FILE] [same outputs]
grid_tmux.py compare --stream FILE --size CxR --capture CAP.ansi [--cursor X,Y] [--hop tmux|tmux-off|none]
battery.py --list | NAME COLS ROWS OUT
checks.py grid | cuts | case3 | toprow | tiles | fit | stats ...
```

A recording replays with its recorded hop and profile. `--stream` replays under hop `none` and
`--capture` (a tmux `capture-pane -p -e -N` dump, with the graphics only stream of `--gfx`) under
hop `tmux`; `--hop` overrides. With neither `--png` nor `--report` the screen's text is printed.
Exit status 0 is success, 1 is a failed check or a recording with error events, 2 is a usage error.

The Python API:

```python
from vkitty import Terminal, Recording, parse_capture, save_png
from vkitty import render, ssim          # the modules: render.render(snap), ssim.ssim(a, b)

term = Terminal(80, 24, profile="ghostty-1.4.0", hop="tmux")   # the default profile is ghostty-1.3.1
term.feed(data, "tui", t)                # bytes of a channel ("tui" or "gfx"), arrival time optional
snap = term.snapshot(t=None)             # a Snapshot: cells, styles, cursor, images, draws, report
pixels = render.render(snap)             # (H, W, 3) uint8, W = 2 * 4 + cols * 13, H = 2 * 4 + rows * 33
save_png(pixels, "screen.png")           # written with Pillow
rec = Recording.load("rec")              # rec.snapshot("mark"), rec.replay(at="mark")
```

`save_png` is exported lazily, so importing the package stays cheap.

`ssim.ssim(a, b)` scores the luma only (0.299 R + 0.587 G + 0.114 B), so two colors of nearly the
same luma score the same, and SSIM alone cannot catch a draw in a wrong palette token. A pixel
test that depends on a color pairs SSIM with an exact color check (`tiles` in `checks.py` compares
every channel to within one level) or a per-channel score: `ssim.ssim(a, b, channels="rgb")` is
the mean of the SSIM of the R, G and B channels, which tells a hue from another hue of the same
luma.

## Report schema

`snapshot.to_report` gives a JSON safe dictionary: `cols`, `rows`, `cell`, `pad`, `profile`,
`cursor` (x, y, visible, shape), `text` (a string per row), `images` (id, w, h, sha256, `seq`,
`frame`, transmissions, wire bytes), `virtual` (the placeholder runs), `draws` (image, kind
`virtual` or `pin`, z, cell, offset, source rectangle, destination size), `missing` (placeholder
runs whose image or placement is absent, with the reason), `warnings`, `stats` and `responses`.

- `seq` is a version stamp of the image's pixels as the renderer uploads them. It changes when the
  texture is uploaded again: a new transmission, an edit of the frame that is being shown, or a
  frame change that shows other pixels. An edit of a frame that is not shown changes nothing on
  screen and does not change `seq`. A counter shared by every terminal of a process makes it, so
  two terminals never agree on it; compare reports without it.
- `frame` is the frame shown (1 for the root frame or an image without animation).
- A pin draw's `row` is negative when its top rows are in history; it still draws its visible part.
- `stats`: `tui_bytes`, `gfx_bytes`, `apc`, `apc_bytes`, `transmit_wire_bytes`, `cuts`, `splices`,
  `media`, `queries`, `vt_queries`, `enoent`, `tmux` (`discards`, `timer_drops`, `dropped_apc`,
  `ignored_dcs`, `body_other`), `by_image`, `deletes` and `since_prev_mark`.
  - `transmit_wire_bytes` is the base64 length of the payload of every `a=t`, `a=T` and `a=q`
    command, so it includes the payload of a query, which stores nothing. In the kitty profile it
    also counts every chunk of an `a=f` frame load, the first chunk included. A per image entry in
    `by_image` adds up the wire bytes of that image's transmissions and frames. A transmission
    counts in its image's entry once its image is stored, and an `a=f` frame load once its data has
    been read, whatever happens to the frame after that. A command refused before its data is
    loaded (a transmission whose payload does not decode, an `a=f` for an image that does not
    exist, an `a=f` whose keys are rejected) counts in the total only, and so does a query, and so
    does a transmission whose data is refused when it completes (too little data for its size, for
    example). So the entries add up to at most the total.
  - `media` counts `a=t` and `a=T` commands by medium (`d`, `f`, `t`, `s`), once per transmission,
    not per chunk. `queries` counts the Kitty `a=q` commands. `vt_queries` counts every DA and
    DSR the model parses, under both hops.
  - `cuts` counts escape sequences and strings that an ESC, CAN or SUB cut off before their end.
    `splices` counts escape sequences that arrived inside an unfinished UTF-8 character.
    `tmux.body_other` counts tokens other than APC that came out of passthrough bodies under hop
    `tmux`. These three diagnose interleaved writers; none changes the screen.
  - `since_prev_mark` restarts at each mark.

## Profiles

- `ghostty-1.4.0` (the default of the relay, the replay tool and the screen test) is Ghostty
  v1.4.0, ported from its source tree (`src/terminal/kitty/graphics_*.zig`, `Terminal.zig`,
  `stream.zig`, `Parser.zig`, `parse_table.zig`, `apc.zig`, `src/unicode`, and its uucode
  ea62149 for Unicode 18.0.0). Against 1.3.1 it differs in:
  - A transmission to an image id that exists removes the old image and all its placements,
    virtual ones included, when the transmission begins (the first chunk of a chunked one), and
    again when the new image is stored. A re-upload without a new `a=p` therefore shows blank
    placeholder cells; 1.3.1 kept the placements.
  - Eviction frees the image with the lowest (priority, generation, id), priority 0 for a transient
    image (the `N` key) that nothing uses, 1 unused, 2 transient and used, 3 used; it stops when
    enough bytes are free (1.3.1 went one image further when the freed bytes equalled the need);
    the replaced image is credited and never evicted. An image given a number takes the lowest free
    id from 1; one with neither id nor number takes the automatic id.
  - Deletes: `d=a`/`A` remove only placements on the screen (a placement wholly in the scrollback
    stays; `A` frees only the images of the removed ones), `d=i`/`I` with a placement id that
    matches nothing frees nothing, `d=r`/`R` take the placements of the images of the range (a
    missing or inverted range selects nothing; `R` also frees unused images of the range), point
    deletes (`d=p`, `d=c`, `d=q`) delete a placement whose rectangle holds the cell (1.3.1
    compared row-major and deleted a tall image for a cell beside it), ED 2 and ED 22 clear the
    visible placements, and every delete aborts a chunked upload.
  - The parser takes any `q` (above 1 is quiet), any `C` (only 1 keeps the cursor), any `U`
    (non-zero is virtual), `f=0` as RGBA, an unknown `f` as an error of the load (`EINVAL:
    unsupported format`), the `N` usage hint, a missing or inverted delete range as one that selects
    nothing, and drops a command whose data is over 65 MiB with no answer. An image id together
    with an image number is refused for every action with an answer that names both. A command that
    names another medium than direct abandons a chunked load. `a=q` completes the load (a PNG that
    is not one, a wrong size) and answers its error.
  - Placement geometry: `X` and `Y` are kept inside the first cell, the source rectangle is cut to
    the image, the pixel size leaves out the pixels the offset takes, so a crop is not stretched.
    After a pin placement without `C=1` the cursor goes to the image's last row (the index is
    bounded by the region's bottom plus one screen), in the column after it, or to column 0 of the
    next row when that is past the right edge. A placeholder without a placement id shows the
    virtual placement `PlacementId.preferredOver` picks.
  - A scroll of a region that is not the whole screen (index, SU, SD, reverse index; not IL and
    DL) moves the placements wholly inside the region with the content, clips the ones it pushes
    over a margin (the source rectangle shrinks) and deletes the ones clipped away; placements
    across a margin or outside it stay on their rows. A full-screen scroll still moves them
    through the pins. Left and right margins are not modelled.
  - Relative placements (`P=`, `Q=`, `H=`, `V=`): the parent is resolved as Ghostty does (`ENOPARENT`,
    `EINVAL`, `ECYCLE`, `ETOODEEP`), the placement is removed with its parent chain after every
    delete, replacement and eviction, and it is stored but never drawn (a known gap).
  - The animation actions `a=f`, `a=a` and `a=c` are accepted and run the animation layer of the
    kitty profile (below), with Ghostty's words for a missing image or frame.
  - C0 controls 0x10 to 0x1F are executed (no-ops) instead of printed, C1 code points decoded from
    UTF-8 are ignored, an APC or OSC canceled by CAN or SUB (or aborted by a C1 control other than
    ST) is thrown away while one ended by ESC or 0x9C runs, and the DCS tables read 0x80 to 0xFF as
    payload.
  - Unicode 18.0.0 widths and grapheme breaks (the Indic conjunct linker classes and GB9c), and a
    variation selector applies to the code point before it in the cluster; VS15 on a wide base
    makes it narrow and puts the cursor after it.
- `ghostty-1.3.1` is Ghostty 1.3.1, the oldest supported version and the default of the library's
  `Terminal`. It does not implement the animation actions: `a=f`, `a=a` and `a=c` log a warning
  and answer nothing.
- `kitty` shares Ghostty's command parser and only executes differently. Animation follows kitty's
  `graphics.c`: frames advance at their exact due times; an image advances only while it is drawn
  (`is_drawn`, set when the image has a placement, here a pin or a virtual placement); a frame can
  be a delta on another frame and is coalesced lazily, with kitty's integer and float32 blends; a
  chain of delta frames that grows too long is stored as a full key frame; `d=f` deletes one frame
  and `d=F` also frees the image when no extra frame is left; `d=R` frees the images of its range
  that nothing refers to; a delete drops an unfinished chunked load. Kitty's indexed colour
  formats and usage hints are not modelled. An `a=f` whose keys the loader rejects is answered
  with kitty's text (`EINVAL` with `Unknown image format`, `Zero width/height not allowed`,
  `Unknown transmission type`, `Unknown image compression`, or `Animation is not supported for
  indexed color images`), in kitty's order for a load in one chunk. `f=0` is RGBA, as it is in kitty.
  - A chunked `a=f` load follows kitty's chunk rules. While a load is in progress, a chunk with no
    `t` or `t=d` continues it, with or without an `a=f` key, and only its `m` counts: its `f`, `o`,
    size and other keys belong to the first chunk, so none of them can be refused, and its answer
    carries the `i` and `I` it names, or the first chunk's. A chunk with another `t` is a new
    first chunk for the same image: it drops the load in progress and is checked for its keys and
    loaded like any first chunk.

## What is modeled, and from which source

| Behavior | Source |
|---|---|
| Byte parser, ground text, CSI fast path | Ghostty `src/terminal/Parser.zig`, `parse_table.zig`, `stream.zig` |
| VT operations, print, wrap, mode 2027, scrolling, erase, margins, screens | Ghostty `src/terminal/Terminal.zig`, `Screen.zig`, `stream.zig`, `modes.zig` |
| SGR, character sets, tab stops | Ghostty `sgr.zig`, `charsets.zig`, `Tabstops.zig` |
| Cell widths, grapheme breaks, emoji variation bases | Ghostty `src/build/uucode_config.zig`, `src/unicode/props_uucode.zig`, `grapheme.zig`, uucode 0.2.0 (1.3.1, Unicode 17.0.0) and uucode ea62149 (1.4.0, Unicode 18.0.0) |
| Kitty graphics commands, storage, deletes, responses | Ghostty `src/terminal/kitty/graphics_command.zig`, `graphics_exec.zig`, `graphics_image.zig`, `graphics_storage.zig` |
| Unicode placeholders | Ghostty `src/terminal/kitty/graphics_unicode.zig` |
| Base64 of a payload | Ghostty `src/simd/base64.zig` and `base64.cpp` (simdutf 5.2.8 `base64_to_binary`) |
| PNG decoding | Ghostty `pkg/wuffs` (wuffs 0.4.0-alpha.9 `std/png/decode_png.wuffs`) |
| Pins and how rows move them | Ghostty `PageList.zig` (`grow`, `eraseRow`, `eraseRowBounded`, `eraseRows`, `trimTrailingBlankRows`, `resizeWithoutReflow`), `Screen.zig` (`cursorScrollAbove`, `scrollClear`), `graphics_storage.zig` (`Placement.rect`) |
| Image draw rules, layers, sorting, sampling | Ghostty `src/renderer/image.zig`, `generic.zig`, `shaders/shaders.metal`, `Metal.zig` |
| The tmux hop: passthrough, its limit and timer, UTF-8 | tmux 3.5a `input.c` (`input_state_dcs_handler_table`, `input_state_dcs_escape_table`, `input_input`, `input_dcs_dispatch`, `input_enter_dcs`, `input_start_timer`, `input_top_bit_set`, `utf8_open`, `utf8_append`, `input_print`, `input_c0_dispatch`), `utf8.c` |
| Animation, frame deletes, blends (kitty profile) | kitty `graphics.c` (`grman_handle_command`, `handle_animation_frame_load_command`, `handle_compose_command`, `scan_active_animations`, `update_current_frame`, `handle_delete_command`), `simd-string.h` |
| Glyph shapes, box and block sprites, colours | the reference renderer that made the calibration images (below) |

The tmux hop is modeled from tmux 3.5a for a full window pane with `allow-passthrough on` (hop
`tmux`; with it off, hop `tmux-off`, tmux ignores every `DCS tmux;`):

- A DCS with no parameters and final byte `t` is read by tmux's own rules from the `t` to the
  `ESC \` that ends it. CAN and SUB are data, `ESC ESC` stores one ESC, and an ESC before any other
  byte is dropped (the byte stays).
- The stored data may not reach 1,048,576 bytes; a DCS that would is dropped whole, so a plot whose
  escape passes about 1 MiB never shows through tmux unless it is sent in pieces.
- Only a body that starts with `tmux;` is forwarded, and it is parsed as Ghostty parses it, with no
  passthrough rule of its own (a `DCS tmux;` inside a forwarded body is not unwrapped again). Every
  other DCS is dropped. A raw APC never reaches the terminal through tmux, so it is dropped.
- tmux starts a 5 s timer when the DCS opens (at `ESC P`, not at its final byte) and resets its
  parser when it fires. The model applies this to the passthrough DCS only, from the arrival times
  of the chunks.
- Under hop `tmux` the outer stream's UTF-8 is decoded as tmux 3.5a decodes it, because the
  terminal behind tmux shows tmux's redraw: an unfinished character survives escape sequences and
  strings and finishes when its last byte arrives, a byte that cannot start or continue a character
  is dropped, and a malformed character prints nothing (`input.c` `input_top_bit_set`, `utf8_open`,
  `utf8_append`). The replacement character rule of the next section applies to hop `none` only.

## VT queries

tmux answers DA1, DA2 and DSR itself and never forwards them, so a terminal behind tmux never sees
them. The model follows the hop:

| Query | Hop `none` (a bare Ghostty) | Hop `tmux` |
|---|---|---|
| `CSI c` (DA1, any parameters) | `ESC [ ? 62;22;52 c` | no answer |
| `CSI > c` (DA2) | `ESC [ > 1;10;0 c` | no answer |
| `CSI = c` | no answer | no answer |
| `CSI 5 n` | `ESC [ 0 n` | no answer |
| `CSI 6 n` | the cursor position (relative to the top margin in origin mode) | no answer |
| `CSI ? 6 n`, `CSI ? 996 n`, a DSR with other than one parameter | no answer | no answer |
| Kitty graphics query `a=q` | answered | answered when it comes inside a passthrough DCS |

Not answered under either hop: XTVERSION (`CSI > q`), XTGETTCAP (`DCS + q`), DECRQM, the OSC 11
colour query, the kitty keyboard protocol query, and the colour scheme report (`CSI ? 996 n`).
Answers are delivered to the child as the model produces them. A real tmux passes the answers it
receives through its key parser and encodes them again; the two are the same while `extended-keys`
is off.

## Rules of the base64, PNG and media readers

Base64 of a payload (Ghostty's simd build, simdutf 5.2.8, on arm64):

- ASCII space, tab, line feed, form feed and carriage return are skipped anywhere (not a vertical
  tab), with one exception: the arm64 kernel refuses a form feed inside the part of a long payload
  it decodes in 64 character blocks. `srclen` is the payload length once its end is trimmed in
  simdutf's order: trailing white space, then one `=`, then white space, then a second `=`, and
  nothing after that. White space to the left of the second `=` stays in `srclen`: 62 base64
  characters followed by space, form feed, `=`, line feed, `=` have a `srclen` of 64, so the form
  feed at index 63 is refused. A form feed at index `p` is refused when `p < 64 * (srclen // 64)`
  and skipped otherwise. The x86 kernels skip a form feed everywhere (`kgp._decode_data(raw, arch="x86")`
  selects that rule); the model follows arm64, the build the harness runs against on a Mac.
- At most two `=`, only at the end, and when there are any the total is a multiple of 4. A length of
  1 mod 4 is refused. Trailing bits are not checked. So a payload wrapped at 76 characters or ending
  in a newline shows, and a badly padded one is refused.

PNG (wuffs 0.4.0-alpha.9):

- Ancillary chunk CRCs are not checked. Critical chunk CRCs are checked up to the end of the image
  data. Bytes after the zlib stream in its own chunk are refused. Nothing after the image data is
  read (not `IEND`, not its CRC). A 16 bit RGB `tRNS` matches on all six bytes.
- The zlib header and the Adler-32 are read as wuffs reads them, wherever the IDAT chunks cut them.
- An interlaced image one row high stops reading once its last non empty pass is full (Adam7 pass 7
  is empty for it), so surplus image data after that point is not an error. Nothing about the
  surplus is checked: not the Adler-32 (a stream that goes on by exactly one byte included), not the
  end of the stream, and not the CRC of the chunk where the surplus is first seen. When a chunk ends
  exactly at the needed size, wuffs stops at once, with no CRC check of that chunk, if its decoder
  is inside a stored block with bytes left (it owes output without reading on); in any other state
  it has to read a code first, so the chunk's CRC is checked and the next chunk is read. The model
  walks the deflate blocks to tell the two (`kgp._deflate_stored_left`, a pure Python loop that runs
  only at such a chunk end). When the stream ends exactly at the needed size every check stays.

Media:

- The offset `O` is ignored for the file and temporary file media (Ghostty reads from offset 0), and
  a file of `S` bytes or more, or 400 MB or more when `S` is absent, is refused. So a client that
  relies on `O` or `S` for files works in kitty and fails in Ghostty 1.3.1.
- A temporary file must be under the temp directory and have `tty-graphics-protocol` in its name;
  the temporary file or shared memory object is removed after it is read.
- A shared memory object is read from its start; its size must cover the declared image.

## Pins and the renderer's dirty rule

A pin placement is a position in the screen's absolute row space (`abs_y`, with the screen's `base`
counting the rows the active area has moved down), and each operation adjusts it as Ghostty's
`PageList` adjusts a tracked pin. A pin whose row went into history still draws its visible part.
The model assumes one page per screen. The renderer's dirty rule and the rows pulled back from
history are not modeled.

## The renderer

`render.render(snap)` paints the cell grid at 2x: 13 x 33 pixel cells, 4 pixel padding. The text
part follows the reference renderer that made the calibration images (Chrome canvas text with
Ghostty's metrics, the box and block sprites, the symbol fit of Ghostty's constraint, runs shaped as
Ghostty breaks them). The draw order is Ghostty's: window background, images below the cell
backgrounds, the backgrounds, images between the backgrounds and the text, a block cursor, underlines
and overlines, glyphs and sprites, strikethroughs, the other cursor shapes, images above the text.
An image is sampled bilinearly in linear light, because Ghostty's image textures are sRGB.

- Glyphs are rasterized by FreeType through Pillow, not by CoreText, and calibrated against the
  reference images at SSIM 0.98 or more. The coverage gamma of 0.6 (`fonts.COVERAGE_GAMMA`) is part
  of that calibration, against the reference renderer's heavier text; it is not a Ghostty rule.
- A block cursor paints its cell (two cells on a wide character, head or tail) before the
  decorations and the glyph of that cell, which are drawn in the cursor text colour. The underline
  cursor is 1 px tall.
- The box drawing sprites follow the reference renderer's table, not Ghostty's full set. These code
  points fall back to the font glyph, with a warning: the dashed lines U+2504 to U+250B and U+254C
  to U+254F, the mixed single and double lines among U+2552 to U+256C other than the nine all double
  ones in the table, the light and heavy mixes such as U+251D to U+2522, and any other the
  calibration sweep warns about. It stays a gap because the calibration images and the reference
  renders of later features come from that renderer, so Ghostty's sprites for these cells would make
  the harness differ from its references on exactly those cells.
- Fonts: the four IosevkaCustom faces are bundled as subsets in `fonts/` (OFL.txt, SOURCE.txt).
  `$JNV_VKITTY_FONT_DIR` with the four full faces replaces them. A code point the face lacks falls
  back to the installed full face, then on macOS to Menlo, Apple Symbols, Apple Color Emoji and Arial
  Unicode, on Linux to DejaVu Sans Mono, Noto Sans CJK SC and Noto Color Emoji. A code point
  nothing carries draws nothing and warns.

## The tmux differential test

`battery.py` has named byte streams. For each one `tests/vkitty_screen.sh` runs a tmux 3.5a pane
(80 x 24, raw mode), writes the stream, and compares the pane's `capture-pane` dump and cursor
with the model: text, width, every style key, cursor. Every stream starts from a clear screen and
ends with a cursor move to a known cell. A case that tmux and Ghostty draw differently is left out of
the battery (the battery's own rule) and held by a `vt/` case that follows Ghostty's source. The
differences:

- A zero count sent to IL, DL, SU, SD, ICH, DCH, the `a` and `e` relative moves or the tab
  commands: tmux reads 0 as 1, Ghostty reads 0 as no change.
- Insert and delete lines with the cursor outside the margins: tmux moves lines over the whole
  screen, Ghostty does nothing (`vt/il_dl_outside_margins`).
- A relative cursor move from the pending wrap state: tmux's cursor sits at the last column.
- A redraw that overwrites half of a wide character: the two clear the other half with different
  colours.
- `REP` after a character in the DEC graphics set: Ghostty repeats the character through the set
  again, tmux repeats the mapped cell (`vt/rep_dec_graphics`).
- `CSI g` with no parameter: Ghostty ignores it, tmux clears the tab stop (`vt/tbc_no_param_ignored`).
- `CSI s` with parameters: Ghostty reads it as DECSLRM, which it ignores without left and right
  margin mode; tmux saves the cursor (`vt/csi_s_with_params_is_decslrm`).
- Grapheme widths under mode 2027 that tmux decides differently: a tmux capture holding them does
  not compare.
- `grid_tmux.parse_capture` lays out a capture with the `ghostty-1.3.1` width tables (Unicode
  17.0.0), while a recording replays under `ghostty-1.4.0` by default (Unicode 18.0.0): a code
  point whose width changed in Unicode 18 shows as a `grid` difference. No jupynvim screen holds
  one.
- Raw 0x10 to 0x1F bytes in ground are printed as cells by Ghostty 1.3.1 and by the model's
  `ghostty-1.3.1` profile; Ghostty 1.4.0 executes them (they do nothing) and so does tmux, so the
  battery could hold them under the 1.4.0 profile. DEL in ground is printed by both Ghostty
  versions, tmux ignores it.

## Performance

The timed tests assert a limit of twice the budget and print the measured value. A shared machine
slows a measurement without any change to the code (the process waits for a CPU, or runs on the slow
cores), so a limit is decided only on measurements the host did not disturb
(`tests/lib/vkitty/perfclock.py`). A measurement is split into samples: a stream fed in pieces of
131,072 bytes, one render, one read of the relay. A sample counts when it was not run on an
efficiency core for more than a twentieth of its time and either was not preempted or lost no more
than a twentieth of its time to preemption. Waiting in a read or a select is the code's own time and
does not disqualify a sample. A run of other processes (the relay, its child, the live terminal's
worker) counts when, taken together, they neither waited for a CPU nor ran on efficiency cores for
more than a tenth of their CPU time. A read of the relay is shorter than the allowance one sample
gets, so the relay's reads count only when the relay's process, followed over the whole run, neither
waited for a CPU nor ran on efficiency cores for more than a tenth of its CPU time. A limit passes
on any measurement within it, because a busy host only makes a measurement slower. It fails on
counted samples beyond it: at least a fifth of the work and eight samples, or 100 reads for a
median, or one counted run. It is printed as undecided, which is not a failure, only when the host
left no counted measurement: the case line says `UNDECIDED` with the counted share of the work, and
the spec ends with the line `N timed cases undecided (host busy): CASES` before its verdict. A quiet
machine decides every limit.

| Path | Budget |
|---|---|
| Tokenizer, TUI like text | 17 MB/s or more (asserted 10 MB/s) |
| Tokenizer, bulk base64 in an APC | 300 MB/s or more |
| Tokenizer, a 1 MiB passthrough body | 0.1 s or less |
| Emulator replay (tokenizer, VT, graphics), TUI text | 4.5 MB/s or more under both hops (asserted 2.5 MB/s) |
| Relay overhead per read, normalized to 64 KB | 1 ms with `--respond none`, 1.5 ms with `--respond ghostty` (asserted 2 ms and 3 ms) |
| Live terminal answer latency | 5 ms median (asserted 10 ms) |
| Relay throughput, 20 MB of APC data | 1 s with `--respond none`, 2 s with `--respond ghostty` |
| Render 160 x 50 at 2x with two images | 300 ms warm, 1 s cold |
| One 624 x 528 image composite | 30 ms |
| `tests/vkitty_spec.py` | 45 s of case time (measured 41 to 45 s at load averages of 6 to 30; 25 s before the relay and `g140` cases of the last rounds) |
| `tests/vkitty_screen.sh` | 120 s (measured 50 s at load 10) |

## Regenerating data

- The width and grapheme tables: `python3 -I tests/lib/vkitty/tools/gen_widths.py --uucode UUCODE_DIR --out tests/lib/vkitty/widths_data.py`
  for Ghostty 1.3.1 and `... --profile ghostty-1.4.0 --uucode UUCODE_DIR --out tests/lib/vkitty/widths_data_140.py`
  for 1.4.0. `UUCODE_DIR` is an unpacked uucode tree: 0.2.0 (the release tarball Ghostty 1.3.1
  pins) or the revision ea62149 that Ghostty 1.4.0 pins (Unicode 18.0.0); the tarball beside the
  tree (`UUCODE_DIR.tar.gz`) is checked against its sha256. No network is used. The generator
  checks every line of `GraphemeBreakTest.txt` against the break rules first (853 lines for
  Unicode 18.0.0), and the output is deterministic.
- The font subsets: `python3 -I tests/lib/vkitty/tools/subset_fonts.py [--src-dir DIR] [--out DIR]`.
  It reads the four full IosevkaCustom faces (default `~/Library/Fonts`), writes the subsets, `OFL.txt`
  and `SOURCE.txt`, which names the folder it actually read (the home folder shown as `~`). A second
  run writes the same bytes.

## Faults

`VKITTY_FAULT` takes a comma separated list of fault names. Each breaks one component so that the
cases listed for it in `faults.py` must fail; the `faults` group of the spec runs those cases with the
fault set and asserts that each one fails.

| Fault | What it breaks |
|---|---|
| `no_unwrap` | the tokenizer stops recognizing `DCS tmux;`, so no body is forwarded, limited, timed out or refused |
| `diacritic_shift` | every placeholder diacritic index plus one |
| `no_linear` | the renderer filters image pixels in sRGB instead of linear light |
| `no_images` | the renderer skips every image layer |
| `keep_temp` | `DirectMedia` does not remove temporary files and shared memory objects |
| `ghostty_animation` | the `ghostty-1.3.1` profile accepts the animation actions it does not implement |

A shared memory object left behind by a spec run that was killed with SIGKILL is not removed (a
signal handler removes the objects on SIGTERM and SIGINT, and the end of a run reports any left).

## Known gaps

The model stops here. Each item is something the harness does not reproduce, or reproduces
differently from the program it follows.

Terminal model

- A DCS with parameters, intermediates or a private leader before the final `t` (`ESC P 1 tmux;`,
  `ESC P 0;5 tmux;`, `ESC P $ tmux;`, `ESC P ? tmux;`): tmux 3.5a stores from the final byte and
  forwards the body; the model treats it as an ordinary DCS, so its APCs are not via tmux.
- tmux's 5 s timer is modeled only for the passthrough DCS and from the arrival times of chunks.
- tmux drops that depend on the client's state (another window current, a redraw pending, a frozen
  tty) are not modeled. The model also does not reproduce a pane that is not a full window.
- Answers are delivered to the child verbatim, where a real tmux passes them through its key parser
  and encodes them again (identical while `extended-keys` is off).
- `CSI t` queries are left to the host terminal.
- A snapshot taken inside a synchronized update (mode 2026) advances to the end of that update.
- Invalid UTF-8 is replaced by the maximal subpart rule where Ghostty's result depends on where its
  reads split the stream. This gap applies to hop `none` only; behind tmux the rule of the tmux hop
  applies. Nothing sends invalid UTF-8 on purpose.
- Two differences that a random comparison against tmux 3.5a found at both hops, neither of which
  occurs in nvim's output: tmux drops a zero width mark that follows a wide character (`A`, U+4E16,
  U+065C), where the model attaches it to the wide character as Ghostty does; and tmux attaches a C1
  code point (U+0080 to U+009F) to the previous cell as a zero width character, where the model
  gives it a cell of its own.
- Primary screen resize does not reflow: columns are cut or extended as on the alternate screen.
- Reverse wrap, left and right margins (DECLRMM), protected cells, scrollback contents (only the
  count of rows sent into history is kept), DECALN, DECRQSS and capability replies are not modeled.
- Under hop `tmux`, DEL in ground (and, under the `ghostty-1.3.1` profile, raw 0x10 to 0x1F bytes)
  is printed as Ghostty prints it, where tmux ignores it. A DCS with final `q` is parsed by tmux builds with sixel support as a
  sixel image (not modeled). A DCS other than the passthrough ends in the model at an ESC that is not
  `ESC \`, where tmux keeps the ESC and the next byte as data (the DCS queries nvim sends hold no
  ESC). Text that arrives inside a passthrough body is drawn by the outer terminal outside tmux's
  grid, so a screen holding it does not compare with a tmux capture.

Kitty graphics

- Pins on rows that leave the screen or a region follow `PageList`; rows pulled back from history are
  not modeled.
- Animated PNG is not modeled (`acTL`, `fcTL`, `fdAT`). Two cases are known to differ. Wuffs refuses
  an `acTL` or `fcTL` chunk of the wrong length, or otherwise malformed, before `IDAT` (`png: bad
  chunk`), where the model ignores them. For a valid APNG whose default image is not part of the
  animation, wuffs shows the first animation frame, where the model shows the default image.
- A 16 bit RGB PNG with `tRNS` and Average or Paeth rows takes an exact but slow path (seconds at
  1600 x 1600).
- Three edge behaviors of Ghostty 1.3.1 are not reproduced. A shared memory load with `O` beyond the
  expected size slices with start above end, unchecked in a ReleaseFast build (the model answers
  `EINVAL: invalid data`). Opening a FIFO path with no writer blocks Ghostty's read (the model refuses
  it at once). A u32 overflow of `width * height * bpp` in `readSharedMemory` happens for huge `s`
  and `v`.
- In the kitty profile: the indexed colour formats and usage hints are not modeled. A chunk that
  starts a new load while an `a=f` load is in progress (another `t`) answers with the `q` of the
  load it dropped when it names none; kitty does that only for an error found before it sets the
  new load up. An unknown `o` is refused when the first chunk arrives, where kitty refuses it when the load
  completes (after the last chunk, and for a file medium after reading the file and removing a
  `t=t` temporary file). An explicit `a=t`, `a=T` or `a=q` during an `a=f` load is taken as a chunk
  of that load, where kitty runs it through its transmission path (with `t=d` it continues the load
  there, with another medium it starts a new image). A continuation chunk that names its own `r` is
  answered with the load's frame number, where kitty answers with the chunk's nonzero `r`. A command
  that names both `i` and `I` is not refused, where kitty refuses it with `EINVAL:Must not specify
  both image id and image number` and leaves a load in progress alone. Data past the size limit is
  answered with Ghostty's `EINVAL: invalid data` at 400 MB, where kitty answers `EFBIG:Too much
  data` once a direct chunk overflows the frame's buffer (its size plus 10 bytes, 1024 when
  compressed).

Relay

- The tap keeps one chunked load flag for the terminal, so a screen switch inside a chunked load warns
  `no blob for key`.
- A chunked kitty `a=f` that names a missing image sets the tap's chunk flag, so the following `a=t`
  and `a=T` are taken as continuations: the replay warns `no blob for key`, and the live terminal
  answers `EINVAL` where kitty loads the image.
- A disabled storage still has its files read by the tap.
- A child that read the old size just before a resize can write one line of old size output after
  the resize event.

Timing

- Time on efficiency cores is known only on macOS (`proc_pid_rusage`, flavor 6). On a Linux machine
  with performance and efficiency cores, time on the slower cores is not seen, so a loaded run there
  can fail a limit.
- On macOS the kernel counts a wait in `time.sleep` as an involuntary context switch (a wait in a
  select, a read or a lock is a voluntary one), so a regression that sleeps inside a timed sample
  makes the sample not count, and its limit is undecided where it fails on Linux.
- Under heavy load the median of the counted relay reads leans slightly fast: a read that was not
  preempted is more often a short one.
- A read of the relay is too short to show a disturbance by itself, so `perf/relay_tui` judges the
  whole relay run: a run disturbed anywhere has no counted read, and a counted run can still
  hold a few reads that were briefly disturbed.
- On macOS a process under the background policy gets next to no CPU while the host has more
  normal priority work than cores (seen at load averages above 100 on a machine with 16 cores:
  none at all for minutes, or a few milliseconds every ten seconds). The measuring child of
  `perfclock/contention_seen` and `perfclock/busy_host_undecided` runs under that policy, so on
  such a host those two cases wait 60 s for a child that is runnable (R) or in an uninterruptible
  wait (U on macOS, D on Linux; the background policy throttles disk I/O as well as CPU) and
  uses less than a quarter second of CPU in that time, and then pass as undecided (named in the
  summary line) with nothing measured; a child in any other state (asleep, stopped, gone, or one
  whose state `ps` cannot give) still fails them.

Renderer

- Glyph rasterization is FreeType, not CoreText.
- The box drawing sprites that fall back to the font glyph (above).
- The cell size is fixed at 13 x 33 pixels, the size the renderer was calibrated at: the renderer
  refuses any other, and a recording has no event for a cell size change (a font size change, a
  window moved to a display of another scale). A remote test that must prove the re-upload after
  such a change cannot do it with this harness; it needs a renderer with metrics for the new size
  and a `cellsize` event of the recording, both unbuilt. A reattach (a new outer terminal with
  empty graphics storage) is expressible: the `reattach` ctl line and event.
- Fonts: the primary faces are the bundled Iosevka subsets. A code point outside them is drawn
  with the first fallback face of the host that carries it: on macOS Menlo, Apple Symbols, Apple
  Color Emoji and Arial Unicode, on Linux what fontconfig answers for DejaVu Sans Mono, Noto Sans
  CJK SC and Noto Color Emoji (Ubuntu: `fontconfig`, `fonts-dejavu-core`, `fonts-noto-cjk`,
  `fonts-noto-color-emoji`; also `libfribidi0` for raqm and `procps` for `ps`). Without them
  `render/fallback_glyph` and `render/cursor_block_wide` fail and say which packages to install;
  every other case draws only code points of the subsets or checks the warning for a missing glyph.

Ghostty 1.4.0 profile

- Relative placements (`P=`) are resolved, stored and removed with their parents, but never drawn.
  The Kitty protocol positions them from the root of the chain (a cursor pin, or the placeholder
  cells of a virtual placement) plus the offsets; the model draws nothing for them.
- The animation actions run the kitty profile's layer (`anim.py`, kitty's `graphics.c`). Ghostty
  1.4.0 composes every frame eagerly into a full image-sized buffer and stores the frames against
  the image storage limit (`ENOSPC: animation frame storage full`), and words its other failures
  (`EINVAL: frame dimensions exceed image`, `base frame not found`, `destination rectangle out of
  bounds`, and the like) in its own text; the model words only a missing image, source frame and
  destination frame as Ghostty does, so the text of the other failures and the storage limit for
  frames are kitty's.
- Loading differences of 1.4.0 that the model does not reproduce. Both Ghostty profiles load
  file, temporary file and shared memory media by 1.3.1's rules (`media.py`, also in the relay's
  tap); a client that sends exact sizes from `$TMPDIR` or shared memory gets the same bytes under
  both. Where 1.4.0 differs:
  - Files (`t=f`, `t=t`): 1.4.0 seeks to `O` (1.3.1 and the model ignore it) and reads exactly `S`
    bytes, so a file shorter than `S` is `EINVAL` (the model reads up to `S`).
  - Temporary files: 1.4.0 matches a directory on a path separator boundary and accepts `/tmp`,
    `/dev/shm`, the temp directory and, on macOS, `/private/tmp`. The model takes a plain prefix
    of the resolved path, so on macOS a temporary file in `/tmp` (resolved to `/private/tmp/...`)
    is refused unless `TMPDIR` covers it, where 1.4.0 loads it.
  - Shared memory: `S` larger than the bytes after `O` is `EINVAL` (the model cuts the end
    instead), a compressed raw image without `S` reads everything after `O` (the model expects
    width x height x bytes per pixel and refuses a smaller object), the raw size is checked
    against the bytes after `O` (the model checks it against the whole object), and raw
    dimensions are checked against the dimension limit first. A PNG without `S` reads the same
    bytes under both.
  - The `limits` object that can disable file mediums (the app enables them all), and the
    pending images of a snapshot restore.
- Left and right margins are not modelled, so the margin scroll rule of the images knows only top
  and bottom margins.
- The width tables and break rules are generated from the pinned uucode, which Ghostty's own build
  derives at compile time; a difference in a derivation that no line of `GraphemeBreakTest.txt`
  and no spot check covers would not show.

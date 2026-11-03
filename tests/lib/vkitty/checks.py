#!/usr/bin/env python3
"""Checks for the real-notebook screen tests of tests/vkitty_screen.sh.

    checks.py grid   REC MARK CAP [--cursor X,Y]
    checks.py cuts   REC
    checks.py case3  --writer yes|no CUTS SPLICES DROPS BODY WARNS
    checks.py toprow CAP
    checks.py tiles  REC MARK PNG [--no-images] [--expect-rows A:B] [--expect-cols A:B]
    checks.py fit    REC MARK
    checks.py stats  REC

REC is a recording folder (relay.py --rec), MARK a mark it holds (a name used more than once
means its last occurrence), CAP a tmux capture-pane -p -e -N dump, PNG the picture the test
transmitted.

grid     the emulator's screen at MARK against the capture, cell by cell (text, width and the style
         keys grid_tmux.compare checks) and the cursor. Each difference is a FAIL line.
cuts     prints one line, cuts=N splices=M tmux_drops=D body_other=B warnings=W, from the snapshot
         at the end of the recording, then the first five warnings as `warning: TEXT` lines. Each
         count names a way a second writer's bytes mix with the first writer's:
           cuts        escape sequences and strings (CSI, ESC, OSC, DCS, APC) that an ESC, CAN or
                       SUB cut off before their end
           splices     escape sequences that arrived inside an unfinished UTF-8 character (behind
                       tmux the character survives, so the screen is the same)
           tmux_drops  passthrough DCSs that tmux drops (too long, not tmux, or open past its timer)
           body_other  tokens other than APC inside passthrough bodies, which tmux hands to the
                       outer terminal, outside its own grid
           warnings    the emulator's warnings (a count only)
         Always exit 0; the test asserts the values.
case3    the rule of the plot_full screen case (tests/vkitty_screen.sh case 3), from the counts
         `cuts` printed. Prints one line, fail=yes|no grid=run|skip tiles=run|skip. --writer yes
         (the tree has one in-order writer): fail=yes when any of CUTS, SPLICES, DROPS or BODY is
         not 0, and the grid and tile checks run. --writer no (a second writer may land inside the
         editor's output): fail=no; the grid check is skipped when BODY is above 0 (foreign tokens
         came out of passthrough bodies, drawn by the outer terminal outside tmux's grid); the tile
         check is skipped when CUTS + DROPS + BODY + WARNS is above 0 (splices alone never skip:
         behind tmux the character survives).
toprow   prints the row index (the diacritic that names the image row) of the first placeholder
         cell on the top screen row that carries one, or -1 when there is none.
tiles    the emulator's render against the picture, one placeholder run at a time: the run's cells
         show the picture's rows and columns the run names (the picture is the image's own size,
         624 x 528 px, one pixel per pixel). A difference above 1 in any channel of any pixel fails.
         The visible image rows are printed as A:B, both ends inclusive, and the image columns the
         placeholder runs cover as A:B too; --expect-rows A:B and --expect-cols A:B assert them (a
         placeholder grid one column short shows the right pixels in every cell it has, so only
         the columns tell). With --no-images the render draws no image, so the check must fail.
fit      the picture of a placement that is not the box's size: the 48 x 16 cell box (624 x 528 px)
         holds the image fitted and centred, as Ghostty's renderPlacement does. The letterbox bands,
         two pixels from the image edge excluded, must be the cell background exactly. The image
         region must reach SSIM 0.97 against the transmitted RGBA composited over that background
         and resized with PIL's bilinear filter.
stats    the per-image transmissions and wire bytes, the totals (cuts=N splices=M among them), and
         the APC and transmit bytes of each mark interval. It fails only when the per-image wire
         bytes break the rule for the stream: with no a=q query in it they add up to the total
         transmit_wire_bytes exactly; with queries they add up to at most the total, since a
         query's payload counts in the total and in no image.

Exit status: 0 the check passes, 1 the check fails, 2 a usage or input error.
"""
import argparse
import os
import re
import sys
import traceback

sys.dont_write_bytecode = True   # a run of the harness writes no bytecode into the repository tree

_LIB = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _LIB not in sys.path:
    sys.path.insert(0, _LIB)

from vkitty import grid_tmux  # noqa: E402
from vkitty import style as _style  # noqa: E402
from vkitty import unicode_place  # noqa: E402
from vkitty.recording import Recording  # noqa: E402

BOX_COLS = 48                # the placement box of jupynvim's images (init.lua image_cols)
BOX_ROWS = 16                # (image_rows)
CELL_W = 13
CELL_H = 33
BOX_W = BOX_COLS * CELL_W    # 624
BOX_H = BOX_ROWS * CELL_H    # 528
TILE_TOLERANCE = 1           # max abs difference per channel that a tile may show
SSIM_MIN = 0.97
EDGE_GAP = 2                 # pixels next to the image edge that the band check leaves out
TOPROW_COLS = 512            # the width a capture line is read with (wider than any screen)
MAX_LINES = 10               # difference lines printed before the rest are counted


class UsageError(Exception):
    pass


def _pair(text, sep, what):
    match = re.match(r"^(-?\d+)%s(-?\d+)$" % re.escape(sep), text or "")
    if match is None:
        raise UsageError("%s takes two numbers separated by %r" % (what, sep))
    return int(match.group(1)), int(match.group(2))


def _read_capture(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read()


def _snapshot(rec, mark):
    if mark is None:
        return rec.snapshot()
    return rec.snapshot(at=mark)


def _warnings(snap):
    for line in snap.warnings:
        print("warning: %s" % line)


def _fail(lines):
    for line in lines:
        print("FAIL %s" % line)
    return 1


def _single_image(snap, what):
    """The one image id the placeholder runs name; a usage of the wrong shape fails the check."""
    if not snap.virtual:
        raise AssertionError("%s: no placeholder run on the screen" % what)
    ids = sorted({v["image_id"] for v in snap.virtual})
    if len(ids) != 1:
        raise AssertionError("%s: %d image ids among the placeholder runs, one expected (%r)"
                             % (what, len(ids), ids))
    return ids[0]


# ------------------------------------------------------------------ grid ---

def cmd_grid(args):
    rec = Recording.load(args.rec)
    emu = _snapshot(rec, args.mark)
    cap = grid_tmux.parse_capture(_read_capture(args.cap), emu.cols, emu.rows)
    cursor = _pair(args.cursor, ",", "--cursor") if args.cursor else None
    notes = []
    diffs = grid_tmux.compare(emu, cap, cursor=cursor, notes=notes)
    if cursor is None:
        notes.append("note: no --cursor given, the cursor is not compared")
    for line in notes:
        print(line)
    _warnings(emu)
    if diffs:
        for line in diffs[:MAX_LINES]:
            print("FAIL grid %s: %s" % (args.mark, line))
        if len(diffs) > MAX_LINES:
            print("FAIL grid %s: %d more differences" % (args.mark, len(diffs) - MAX_LINES))
        print("FAIL grid %s: %d difference(s)" % (args.mark, len(diffs)))
        return 1
    print("ok grid %s: the emulator and tmux agree on %dx%d (cursor %s)"
          % (args.mark, emu.cols, emu.rows, "compared" if cursor else "not compared"))
    return 0


# ------------------------------------------------------------------ cuts ---

def cmd_cuts(args):
    rec = Recording.load(args.rec)
    snap = rec.snapshot()
    stats = snap.stats
    tmux = stats["tmux"]
    print("cuts=%d splices=%d tmux_drops=%d body_other=%d warnings=%d"
          % (stats["cuts"], stats["splices"], tmux["discards"] + tmux["timer_drops"],
             tmux["body_other"], len(snap.warnings)))
    for text in snap.warnings[:5]:
        print("warning: %s" % text)
    return 0


# ----------------------------------------------------------------- case3 ---

def case3_rule(writer, cuts, splices, drops, body, warns):
    """(fail, grid runs, tiles run) for the plot_full screen case; see the module docstring."""
    if writer == "yes":
        return (cuts or splices or drops or body) != 0, True, True
    return False, body == 0, cuts + drops + body + warns == 0


def cmd_case3(args):
    fail, grid, tiles = case3_rule(args.writer, args.cuts, args.splices, args.drops, args.body,
                                   args.warns)
    print("fail=%s grid=%s tiles=%s" % ("yes" if fail else "no", "run" if grid else "skip",
                                        "run" if tiles else "skip"))
    return 0


# ---------------------------------------------------------------- toprow ---

def cmd_toprow(args):
    snap = grid_tmux.parse_capture(_read_capture(args.cap), TOPROW_COLS, 1)
    value = -1
    for text, _sid, _width in snap.cells[0]:
        if not text.startswith(unicode_place.PLACEHOLDER_CHAR):
            continue
        for ch in text[1:]:
            index = unicode_place.DIAC_INDEX.get(ord(ch))
            if index is not None:
                value = index
                break
        if value != -1:
            break
    print(value)
    return 0


# ----------------------------------------------------------------- tiles ---

def cmd_tiles(args):
    import numpy as np
    from PIL import Image
    from vkitty import render
    rec = Recording.load(args.rec)
    snap = _snapshot(rec, args.mark)
    failures = []
    for miss in snap.missing:
        failures.append("missing placeholder run at x=%d y=%d: %s"
                        % (miss["x"], miss["y"], miss["reason"]))
    if not snap.virtual:
        failures.append("tiles %s: no placeholder run on the screen" % args.mark)
    if failures:
        return _fail(failures)
    try:
        image_id = _single_image(snap, "tiles %s" % args.mark)
    except AssertionError as exc:
        return _fail([str(exc)])
    image = snap.images.get(image_id)
    if image is None or (image.width, image.height) != (BOX_W, BOX_H):
        return _fail(["tiles %s: the image is not %dx%d px (it is %s)"
                      % (args.mark, BOX_W, BOX_H,
                         "missing" if image is None else "%dx%d" % (image.width, image.height))])
    pic = Image.open(args.png)
    if pic.size != (BOX_W, BOX_H):
        return _fail(["tiles %s: the picture %s is %dx%d px, %dx%d expected"
                      % (args.mark, args.png, pic.size[0], pic.size[1], BOX_W, BOX_H)])
    rgba = np.asarray(pic.convert("RGBA"))
    if int(rgba[..., 3].min()) < 255:
        return _fail(["tiles %s: the picture %s is not opaque" % (args.mark, args.png)])
    expect_all = rgba[..., :3].astype(np.int16)
    warn = []
    pixels = render.render(snap, images=not args.no_images, warn=warn).astype(np.int16)
    for line in warn:
        print("warning: %s" % line)
    rows = sorted({v["row"] for v in snap.virtual})
    lo, hi = rows[0], rows[-1]
    clo = min(v["col"] for v in snap.virtual)
    chi = max(v["col"] + v["w"] - 1 for v in snap.virtual)
    print("visible image rows %d:%d (inclusive), columns %d:%d, %d tiles"
          % (lo, hi, clo, chi, len(snap.virtual)))
    if args.expect_rows is not None and (lo, hi) != args.expect_rows:
        return _fail(["tiles %s: visible image rows %d:%d, %d:%d expected"
                      % (args.mark, lo, hi, args.expect_rows[0], args.expect_rows[1])])
    if args.expect_cols is not None and (clo, chi) != args.expect_cols:
        return _fail(["tiles %s: visible image columns %d:%d, %d:%d expected"
                      % (args.mark, clo, chi, args.expect_cols[0], args.expect_cols[1])])
    worst = 0
    bad = []
    for v in snap.virtual:
        row, col, width = v["row"], v["col"], v["w"]
        expect = expect_all[row * CELL_H:(row + 1) * CELL_H,
                            col * CELL_W:(col + width) * CELL_W]
        top = snap.pad + v["y"] * snap.cell_h
        left = snap.pad + v["x"] * snap.cell_w
        got = pixels[top:top + snap.cell_h, left:left + width * snap.cell_w]
        if got.shape != expect.shape:
            bad.append("tile at x=%d y=%d lies outside the render" % (v["x"], v["y"]))
            continue
        diff = int(np.abs(got - expect).max())
        worst = max(worst, diff)
        if diff > TILE_TOLERANCE:
            bad.append("tile x=%d y=%d (image row %d, cols %d to %d): max diff %d"
                       % (v["x"], v["y"], row, col, col + width - 1, diff))
    print("max abs diff %d over %d tiles" % (worst, len(snap.virtual)))
    if bad:
        lines = ["tiles %s: %s" % (args.mark, line) for line in bad[:MAX_LINES]]
        lines.append("tiles %s: %d of %d tiles differ from the picture"
                     % (args.mark, len(bad), len(snap.virtual)))
        return _fail(lines)
    print("ok tiles %s: %d tiles match the picture (tolerance %d)"
          % (args.mark, len(snap.virtual), TILE_TOLERANCE))
    return 0


# ------------------------------------------------------------------- fit ---

def _bg_rgb(value):
    """A cell background (style_to_dict's form) as RGB; no value is the theme's background."""
    from vkitty import render
    if value is None:
        value = render.DEFAULT_THEME["bg"]
    return render._colour(value, render.DEFAULT_THEME)


def cmd_fit(args):
    import numpy as np
    from PIL import Image
    from vkitty import render, ssim
    rec = Recording.load(args.rec)
    snap = _snapshot(rec, args.mark)
    failures = []
    for miss in snap.missing:
        failures.append("missing placeholder run at x=%d y=%d: %s"
                        % (miss["x"], miss["y"], miss["reason"]))
    if failures:
        return _fail(failures)
    try:
        image_id = _single_image(snap, "fit %s" % args.mark)
    except AssertionError as exc:
        return _fail([str(exc)])
    image = snap.images.get(image_id)
    if image is None:
        return _fail(["fit %s: image %d is not stored" % (args.mark, image_id)])
    x0 = min(v["x"] - v["col"] for v in snap.virtual)
    y0 = min(v["y"] - v["row"] for v in snap.virtual)
    if any(v["x"] - v["col"] != x0 or v["y"] - v["row"] != y0 for v in snap.virtual):
        return _fail(["fit %s: the placeholder runs do not share one box" % args.mark])
    covered = sum(v["w"] for v in snap.virtual)
    if covered != BOX_COLS * BOX_ROWS:
        return _fail(["fit %s: the box is not fully on screen (%d of %d cells)"
                      % (args.mark, covered, BOX_COLS * BOX_ROWS)])
    box_cells = [(x0 + dx, y0 + dy) for dy in range(BOX_ROWS) for dx in range(BOX_COLS)]
    backgrounds = set()
    for x, y in box_cells:
        _text, sid, _width = snap.cells[y][x]
        style = _style.style_to_dict(snap.styles[sid])
        if style.get("inv"):
            return _fail(["fit %s: inverse placeholder cells are not modelled here" % args.mark])
        backgrounds.add(_bg_rgb(style.get("bg")))
    if len(backgrounds) != 1:
        return _fail(["fit %s: the placeholder cells have %d backgrounds, one expected"
                      % (args.mark, len(backgrounds))])
    bg = backgrounds.pop()
    w, h = image.width, image.height
    scale = min(BOX_W / w, BOX_H / h)
    dw = int(scale * w + 0.5)
    dh = int(scale * h + 0.5)
    ox = (BOX_W - dw) // 2
    oy = (BOX_H - dh) // 2
    pixels = render.render(snap).astype(np.int16)
    top = snap.pad + y0 * snap.cell_h
    left = snap.pad + x0 * snap.cell_w
    box = pixels[top:top + BOX_H, left:left + BOX_W]
    band = np.ones((BOX_H, BOX_W), dtype=bool)
    band[max(0, oy - EDGE_GAP):oy + dh + EDGE_GAP, max(0, ox - EDGE_GAP):ox + dw + EDGE_GAP] = False
    outside = box[band]
    bad_band = int(np.any(outside != np.array(bg, dtype=np.int16), axis=1).sum())
    print("image %dx%d shown at %dx%d, offset %d,%d in the %dx%d px box, background %s"
          % (w, h, dw, dh, ox, oy, BOX_W, BOX_H, "#%02x%02x%02x" % bg))
    if bad_band:
        return _fail(["fit %s: %d letterbox pixels differ from the cell background"
                      % (args.mark, bad_band)])
    rgba = np.frombuffer(image.rgba, dtype=np.uint8).reshape(h, w, 4).astype(np.float64)
    alpha = rgba[..., 3:4] / 255.0
    composed = rgba[..., :3] * alpha + np.array(bg, dtype=np.float64) * (1.0 - alpha)
    composed = np.clip(np.rint(composed), 0, 255).astype(np.uint8)
    resample = getattr(Image, "Resampling", Image).BILINEAR
    want = np.asarray(Image.fromarray(composed).resize((dw, dh), resample))
    got = box[oy:oy + dh, ox:ox + dw].astype(np.uint8)
    score = ssim.ssim(got, want)
    print("ssim %.4f of the image region (minimum %.2f)" % (score, SSIM_MIN))
    if score < SSIM_MIN:
        return _fail(["fit %s: SSIM %.4f below %.2f" % (args.mark, score, SSIM_MIN)])
    print("ok fit %s: the image is fitted and centred, the bands are the cell background"
          % args.mark)
    return 0


# ----------------------------------------------------------------- stats ---

def cmd_stats(args):
    rec = Recording.load(args.rec)
    end = rec.snapshot()
    stats = end.stats
    by_image = stats["by_image"]
    print("images transmitted: %d" % len(by_image))
    for key in sorted(by_image, key=int):
        entry = by_image[key]
        print("image %s: transmissions=%d wire_bytes=%d medium=%s"
              % (key, entry["transmissions"], entry["wire_bytes"], entry["medium"]))
    print("totals: transmit_wire_bytes=%d apc=%d apc_bytes=%d cuts=%d splices=%d deletes=%d "
          "tui_bytes=%d gfx_bytes=%d" % (stats["transmit_wire_bytes"], stats["apc"],
                                         stats["apc_bytes"], stats["cuts"], stats["splices"],
                                         stats["deletes"], stats["tui_bytes"], stats["gfx_bytes"]))
    for name in sorted(rec.marks, key=rec.marks.get):
        since = rec.snapshot(at=name).stats["since_prev_mark"]
        print("interval ending at %s: apc_bytes=%d transmit_wire_bytes=%d"
              % (name, since["apc_bytes"], since["transmit_wire_bytes"]))
    per_image = sum(entry["wire_bytes"] for entry in by_image.values())
    total = stats["transmit_wire_bytes"]
    queries = stats["queries"]
    if queries == 0:
        print("rule: no a=q query in the stream, so the per-image wire bytes must equal the total")
        if per_image != total:
            print("FAIL stats: per-image wire bytes add up to %d, the total is %d"
                  % (per_image, total))
            return 1
        print("ok stats: per-image wire bytes add up to the total (%d)" % total)
        return 0
    print("rule: %d a=q queries in the stream, so the per-image wire bytes must not exceed the "
          "total"
          % queries)
    if per_image > total:
        print("FAIL stats: per-image wire bytes add up to %d, above the total %d"
              % (per_image, total))
        return 1
    print("ok stats: per-image wire bytes (%d) do not exceed the total (%d)" % (per_image, total))
    return 0


# ------------------------------------------------------------------ main ---

def _parser():
    parser = argparse.ArgumentParser(prog="checks.py", description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="cmd")
    p = sub.add_parser("grid", help="the emulator's screen at a mark against a tmux capture")
    p.add_argument("rec")
    p.add_argument("mark")
    p.add_argument("cap")
    p.add_argument("--cursor", default=None, help="X,Y from tmux display-message")
    p = sub.add_parser("cuts",
                       help="how a second writer's bytes mixed with the first (one line of counts)")
    p.add_argument("rec")
    p = sub.add_parser("case3", help="what the plot_full screen case fails and skips, by counts")
    p.add_argument("--writer", required=True, choices=("yes", "no"),
                   help="yes when the tree has one in-order writer")
    for name in ("cuts", "splices", "drops", "body", "warns"):
        p.add_argument(name, type=int)
    p = sub.add_parser("toprow", help="the image row of the first placeholder on the top row")
    p.add_argument("cap")
    p = sub.add_parser("tiles", help="the placeholder tiles against a picture")
    p.add_argument("rec")
    p.add_argument("mark")
    p.add_argument("png")
    p.add_argument("--no-images", action="store_true", help="render without the images")
    p.add_argument("--expect-rows", default=None, help="A:B, the visible image rows (inclusive)")
    p.add_argument("--expect-cols", default=None, help="A:B, the image columns covered (inclusive)")
    p = sub.add_parser("fit", help="a picture fitted in the placement box")
    p.add_argument("rec")
    p.add_argument("mark")
    p = sub.add_parser("stats", help="the graphics counts of a recording")
    p.add_argument("rec")
    return parser


_COMMANDS = {
    "grid": cmd_grid,
    "cuts": cmd_cuts,
    "case3": cmd_case3,
    "toprow": cmd_toprow,
    "tiles": cmd_tiles,
    "fit": cmd_fit,
    "stats": cmd_stats,
}


def main(argv):
    parser = _parser()
    try:
        args = parser.parse_args(argv)
    except SystemExit:
        return 2
    if args.cmd not in _COMMANDS:
        parser.print_usage(sys.stderr)
        return 2
    try:
        if args.cmd == "tiles" and args.expect_rows is not None:
            args.expect_rows = _pair(args.expect_rows, ":", "--expect-rows")
        if args.cmd == "tiles" and args.expect_cols is not None:
            args.expect_cols = _pair(args.expect_cols, ":", "--expect-cols")
        return _COMMANDS[args.cmd](args)
    except (UsageError, KeyError, OSError, ValueError) as exc:
        message = exc.args[0] if isinstance(exc, KeyError) and exc.args else exc
        print("checks.py: %s" % message, file=sys.stderr)
        return 2
    except Exception:
        print("checks.py: internal error", file=sys.stderr)
        traceback.print_exc()
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

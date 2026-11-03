#!/usr/bin/env python3
"""Replay a recording, a byte stream, or a tmux capture into a screen, and report or render it.

    replay.py REC_DIR [--at MARK] [OUTPUTS] [--profile P] [--hop tmux|tmux-off|none] [--no-images]
    replay.py --stream TUI_FILE --size CxR [--gfx GFX_FILE] [OUTPUTS] [--profile P] [--hop H]
    replay.py --capture CAP.ansi --size CxR [--gfx GFX_FILE] [OUTPUTS] [--profile P] [--hop H]

    OUTPUTS: --png OUT.png (the rendered screen), --report OUT.json (the report, as JSON),
             --crop R0:R1 (only those cell rows of the picture). With neither output, the
             screen's text is printed.

A recording replays with its recorded hop and profile; --hop and --profile override them. A
--stream file is replayed under hop none by default; --capture (a tmux capture-pane dump, with
the graphics-only stream of --gfx) under hop tmux. In --capture mode the text and styles are the
capture's, and the placeholders are resolved against them (unicode_place.iterate). Its pins, if
any, come from the graphics stream replayed on its own, because a capture holds no cursor
history: the pins are placed on that stream's primary screen, whose images are the capture's
images too. --at is for a recording only (a usage error with --stream or --capture).

Exit status: 0 ok; 1 when the recording holds error events (the relay logged a failure) or the
output could not be made; 2 for a usage error.
"""
import argparse
import copy
import json
import os
import re
import sys

sys.dont_write_bytecode = True   # a run of the harness writes no bytecode into the repository tree

_LIB = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _LIB not in sys.path:
    sys.path.insert(0, _LIB)

from vkitty import grid_tmux, kgp, snapshot as _snapshot  # noqa: E402
from vkitty.media import RecordedMedia  # noqa: E402
from vkitty.recording import Recording  # noqa: E402
from vkitty.vt import Terminal  # noqa: E402


class _CaptureRow:
    """The row shape unicode_place.iterate reads: text, style id and width per cell."""

    def __init__(self, cells):
        self.text = [cell[0] for cell in cells]
        self.sid = [cell[1] for cell in cells]
        self.wide = [cell[2] for cell in cells]


class _CaptureScreen:
    """Stands in for vt.Screen while a capture's placeholders are resolved: its grid is the
    capture's, and its graphics storage and base row (what pins are placed against) are those of
    the stream's screen it borrows them from."""

    def __init__(self, cap, screen):
        self.grid = [_CaptureRow(cells) for cells in cap.cells]
        self.kitty = screen.kitty
        self.base = screen.base


class _CaptureStyles:
    def __init__(self, styles):
        self.styles = styles


def capture_snapshot(term, cap):
    """The capture's screen with the graphics of the terminal that replayed the graphics stream:
    the placeholder runs are found in the capture's cells (with its styles), and their images are
    the terminal's."""
    saved_active, saved_styles = term.active, term.styles
    term.active = _CaptureScreen(cap, term.primary)
    term.styles = _CaptureStyles(cap.styles)
    try:
        graphics = _snapshot.graphics(term, None)
    finally:
        term.active, term.styles = saved_active, saved_styles
    cap.images = graphics.images
    cap.draws = graphics.draws
    cap.missing = graphics.missing
    cap.virtual = graphics.virtual
    cap.warnings = list(term.warnings)
    cap.stats = copy.deepcopy(term.stats)
    cap.responses = list(term.responses)
    cap.profile = term.profile
    return cap


def _read(path):
    with open(path, "rb") as fh:
        return fh.read()


def _size(text):
    match = re.match(r"^(\d+)x(\d+)$", text or "")
    if match is None:
        raise ValueError("--size is CxR")
    return int(match.group(1)), int(match.group(2))


def _stream_screen(args):
    cols, rows = _size(args.size)
    term = Terminal(cols, rows, hop=args.hop or "none", profile=args.profile or kgp.DEFAULT_PROFILE)
    term.media = RecordedMedia({}, warnings=term.warnings)
    term.feed(_read(args.stream), "tui")
    if args.gfx:
        term.feed(_read(args.gfx), "gfx")
    return term.snapshot(), []


def _capture_screen(args):
    cols, rows = _size(args.size)
    with open(args.capture, encoding="utf-8", errors="replace") as fh:
        cap = grid_tmux.parse_capture(fh.read(), cols, rows)
    term = Terminal(cols, rows, hop=args.hop or "tmux", profile=args.profile or kgp.DEFAULT_PROFILE)
    term.media = RecordedMedia({}, warnings=term.warnings)
    if args.gfx:
        term.feed(_read(args.gfx), "gfx")
    return capture_snapshot(term, cap), []


def _recording_screen(args):
    rec = Recording.load(args.rec)
    snap = rec.snapshot(at=args.at, profile=args.profile, hop=args.hop)
    return snap, rec.errors


def _render(snap, args):
    from vkitty.render import render
    crop = None
    if args.crop:
        match = re.match(r"^(\d+):(\d+)$", args.crop)
        if match is None:
            raise ValueError("--crop is R0:R1")
        crop = (int(match.group(1)), int(match.group(2)))
    warn = []
    pixels = render(snap, crop_rows=crop, images=not args.no_images, warn=warn)
    return pixels, warn


def parse(argv):
    parser = argparse.ArgumentParser(prog="replay.py", description=__doc__.split("\n")[0])
    parser.add_argument("rec", nargs="?", help="a recording folder")
    parser.add_argument("--stream", help="a tui byte stream (instead of a recording)")
    parser.add_argument("--capture", help="a tmux capture-pane dump (instead of a recording)")
    parser.add_argument("--gfx", help="the graphics byte stream (with --stream or --capture)")
    parser.add_argument("--size", help="CxR for --stream and --capture")
    parser.add_argument("--at", help="replay to this mark (a recording)")
    parser.add_argument("--profile", choices=kgp.PROFILES)
    parser.add_argument("--hop", choices=("tmux", "tmux-off", "none"))
    parser.add_argument("--png", help="write the rendered screen here")
    parser.add_argument("--report", help="write the report here as JSON")
    parser.add_argument("--crop", help="only these cell rows of the picture, R0:R1")
    parser.add_argument("--no-images", action="store_true", help="render without the images")
    args = parser.parse_args(argv)
    modes = [m for m in (args.rec, args.stream, args.capture) if m]
    if len(modes) != 1:
        parser.error("give exactly one of REC_DIR, --stream, --capture")
    if args.stream is None and args.capture is None and args.gfx is not None:
        parser.error("--gfx goes with --stream or --capture")
    if args.stream is not None or args.capture is not None:
        if not args.size:
            parser.error("--stream and --capture need --size CxR")
        if args.at is not None:
            parser.error("--at goes with a recording, not with --stream or --capture")
    return args


def main(argv=None):
    argv = sys.argv[1:] if argv is None else list(argv)
    try:
        args = parse(argv)
    except SystemExit as exc:
        return 2 if exc.code else 0
    try:
        if args.stream is not None:
            snap, errors = _stream_screen(args)
        elif args.capture is not None:
            snap, errors = _capture_screen(args)
        else:
            snap, errors = _recording_screen(args)
    except (KeyError, ValueError, OSError) as exc:
        print("replay.py: %s" % (exc.args[0] if isinstance(exc, KeyError) else exc),
              file=sys.stderr)
        return 2
    status = 0
    for ev in errors:
        print("error %s: %s" % (ev.get("where"), ev.get("msg")), file=sys.stderr)
        status = 1
    try:
        if args.png:
            pixels, warn = _render(snap, args)
            from vkitty.render import save_png
            save_png(pixels, args.png)
            for line in warn:
                print("render: %s" % line, file=sys.stderr)
        if args.report:
            from vkitty.snapshot import to_report
            with open(args.report, "w", encoding="ascii") as fh:
                json.dump(to_report(snap), fh)
                fh.write("\n")
        if not args.png and not args.report:
            for row in snap.text():
                print(row.rstrip())
            for warning in snap.warnings:
                print("warning: %s" % warning)
    except (OSError, ValueError) as exc:
        print("replay.py: %s" % exc, file=sys.stderr)
        return 1
    return status


if __name__ == "__main__":
    sys.exit(main())

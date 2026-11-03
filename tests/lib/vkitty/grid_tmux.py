"""A `tmux capture-pane -p -e -N` dump as a Snapshot, and the comparison of an
emulator snapshot with it.

    python3 -I tests/lib/vkitty/grid_tmux.py compare --stream FILE --size CxR \\
        --capture CAP [--cursor X,Y] [--hop tmux|tmux-off|none]

parse_capture follows the reference capture parser: the SGR state carries across
lines, a zero-width character joins the cell before it, a wide character takes
two cells, and tmux 3.5a's overline (written as 5:3) is read as 53. Widths are
Ghostty's (vkitty.widths), so a capture is read the way the emulator reads a
stream. compare checks, for every cell, the text and width and each style key
the two sides report; it returns the differences as text lines (at most 30).

Exit status of the CLI: 0 when the emulator and the capture agree, 1 when they
differ, 2 on a usage error.
"""
import argparse
import os
import re
import sys

sys.dont_write_bytecode = True   # a run of the harness writes no bytecode into the repository tree

_LIB = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _LIB not in sys.path:
    sys.path.insert(0, _LIB)

from vkitty import style as _style  # noqa: E402
from vkitty import widths as _widths  # noqa: E402
from vkitty.charsets_dec import DEC_SPECIAL as _DEC_SPECIAL  # noqa: E402
from vkitty.snapshot import Snapshot  # noqa: E402

SGR_RE = re.compile(r"\x1b\[([0-9;:]*)m")
DEFAULT_KEYS = ("fg", "bg", "b", "d", "i", "u", "r", "s", "o", "blink", "inv", "ul")
MAX_DIFFS = 30


def _tmux_sgr(params):
    """tmux 3.5a writes overline as 5:3; Ghostty reads 5:x as an unknown blink."""
    if ":" not in params:
        return params
    return ";".join("53" if part == "5:3" else part for part in params.split(";"))


def parse_capture(text, cols, rows):
    """A capture as a Snapshot (no images, cursor at home). In a capture, a cell
    of the DEC special graphics set is written as its letter between SO and SI
    (tmux's grid_string_cells); it is read back as the graphics character."""
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines = lines[:-1]
    table = _style.StyleTable()
    state = _style.DEFAULT_STYLE
    grid = []
    for line in lines[:rows]:
        cells = []                   # [text, sid, width]
        pos = 0
        acs = [False]
        for match in SGR_RE.finditer(line):
            state = _apply_segment(line[pos:match.start()], state, table, cells, acs)
            state = _style.apply_sgr(state, _tmux_sgr(match.group(1)).encode("ascii"))
            pos = match.end()
        _apply_segment(line[pos:], state, table, cells, acs)
        grid.append(cells)
    out = []
    for r in range(rows):
        cells = grid[r] if r < len(grid) else []
        row = []
        for text, sid, width in cells:
            row.append((text, sid, width))
        if len(row) > cols:
            row = row[:cols]
        blank = table.intern(_style.DEFAULT_STYLE)
        while len(row) < cols:
            row.append((" ", blank, 1))
        out.append(row)
    return Snapshot(cols=cols, rows=rows, cell_w=13, cell_h=33, pad=4, cells=out,
                    styles=list(table.styles), cursor=(0, 0, True, "block"),
                    profile="tmux-3.5a")


def _apply_segment(seg, state, table, cells, acs):
    """Append the cells of one run of text; acs is [graphics set on] (SO and SI
    switch it, and they take no cell)."""
    if not seg:
        return state
    sid = table.intern(state)
    for ch in seg:
        if ch == "\x0e":
            acs[0] = True
            continue
        if ch == "\x0f":
            acs[0] = False
            continue
        cp = ord(ch)
        if acs[0] and cp in _DEC_SPECIAL:
            ch = chr(_DEC_SPECIAL[cp])
            cp = ord(ch)
        width = 1 if cp < 0x7F else _widths.props(cp)[0] if cp <= _widths.MAX_CP else 1
        if width == 0:
            if cells:
                cells[-1][0] += ch
            continue
        cells.append([ch, sid, width])
        if width == 2:
            cells.append(["", sid, 0])
    return state


def _cell_key(snap, sid_cache, sid):
    got = sid_cache.get(sid)
    if got is None:
        got = _style.style_to_dict(snap.styles[sid])
        sid_cache[sid] = got
    return got


def _keys_seen(snap):
    seen = set()
    cache = {}
    for row in snap.cells:
        for _text, sid, _width in row:
            if sid:
                seen.update(_cell_key(snap, cache, sid).keys())
    return seen


def compare(emu, cap, keys=DEFAULT_KEYS, cursor=None, notes=None):
    """Differences between an emulator snapshot and a capture snapshot. A style key
    that neither side reports anywhere is left out (a note says so in `notes`)."""
    diffs = []
    if notes is None:
        notes = []
    if (emu.cols, emu.rows) != (cap.cols, cap.rows):
        return ["size: emulator %dx%d, capture %dx%d" % (emu.cols, emu.rows, cap.cols, cap.rows)]
    seen = _keys_seen(emu) | _keys_seen(cap)
    use = []
    left_out = []
    for key in keys:
        if key in seen:
            use.append(key)
        else:
            left_out.append(key)
    if left_out:
        notes.append("note: neither side reports %s in this screen; not compared"
                     % ", ".join(left_out))
    ecache, ccache = {}, {}
    for y in range(emu.rows):
        erow = emu.cells[y]
        crow = cap.cells[y]
        for x in range(emu.cols):
            et, es, ew = erow[x]
            ct, cs, cw = crow[x]
            if (et, ew) != (ct, cw):
                diffs.append("row %d col %d: text %r width %d, capture %r width %d"
                             % (y, x, et, ew, ct, cw))
            elif use:
                ed = _cell_key(emu, ecache, es)
                cd = _cell_key(cap, ccache, cs)
                for key in use:
                    if ed.get(key) != cd.get(key):
                        diffs.append("row %d col %d %s: emulator %r, capture %r"
                                     % (y, x, key, ed.get(key), cd.get(key)))
                        break
            if len(diffs) >= MAX_DIFFS:
                diffs.append("(more differences not listed)")
                return diffs
    if cursor is not None:
        if (emu.cursor[0], emu.cursor[1]) != tuple(cursor):
            diffs.append("cursor: emulator %r, tmux %r"
                         % ((emu.cursor[0], emu.cursor[1]), tuple(cursor)))
    return diffs


def _parse_size(text):
    cols, rows = text.lower().split("x")
    return int(cols), int(rows)


def _parse_cursor(text):
    x, y = text.split(",")
    return int(x), int(y)


def main(argv):
    from vkitty.vt import Terminal
    parser = argparse.ArgumentParser(prog="grid_tmux.py")
    sub = parser.add_subparsers(dest="cmd")
    cmp_p = sub.add_parser("compare", help="feed a stream and compare with a capture")
    cmp_p.add_argument("--stream", required=True)
    cmp_p.add_argument("--size", required=True, help="CxR, the pane size")
    cmp_p.add_argument("--capture", required=True, help="tmux capture-pane -p -e -N output")
    cmp_p.add_argument("--cursor", default=None, help="X,Y from tmux display-message")
    cmp_p.add_argument("--hop", default="tmux", choices=("tmux", "tmux-off", "none"))
    try:
        args = parser.parse_args(argv)
    except SystemExit:
        return 2
    if args.cmd != "compare":
        parser.print_usage(sys.stderr)
        return 2
    try:
        cols, rows = _parse_size(args.size)
        cursor = _parse_cursor(args.cursor) if args.cursor else None
    except ValueError:
        print("usage: --size CxR and --cursor X,Y", file=sys.stderr)
        return 2
    with open(args.stream, "rb") as fh:
        stream = fh.read()
    with open(args.capture, "r", encoding="utf-8", errors="replace") as fh:
        capture = fh.read()
    term = Terminal(cols, rows, hop=args.hop)
    term.feed(stream)
    emu = term.snapshot()
    cap = parse_capture(capture, cols, rows)
    notes = []
    diffs = compare(emu, cap, cursor=cursor, notes=notes)
    for line in notes:
        print(line)
    for line in diffs:
        print("FAIL " + line)
    if diffs:
        print("grid: %d difference(s)" % len(diffs))
        return 1
    print("ok grid: emulator and capture agree (%dx%d)" % (cols, rows))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

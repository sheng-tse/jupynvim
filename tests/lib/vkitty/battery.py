"""VT battery: named byte streams for the differential test against tmux 3.5a.

    python3 -I tests/lib/vkitty/battery.py --list
    python3 -I tests/lib/vkitty/battery.py NAME COLS ROWS OUT

Each case is a function (cols, rows) -> bytes that starts from a clear screen and
ends with a CUP to a known cell, so the cursor check has a fixed reference. The
streams keep to what tmux 3.5a and Ghostty 1.3.1 both do. A case that differs for
a known reason is removed from here and covered by a vt/ spec case that follows
Ghostty's source; tests/lib/vkitty/README.md lists the reasons. In particular no
case sends a zero count to IL, DL, SU, SD, ICH, DCH, the a/e relative moves or the
tab commands: tmux reads 0 as 1 there, Ghostty reads 0 as no change.

The utf8_splice case holds an unfinished UTF-8 character carried across escape
sequences, C0 bytes and strings, decoded the way tmux 3.5a decodes it. Its rows are
UTF8_SPLICE_ROWS, each checked against a live tmux 3.5a; the 80 x 24 screen holds 21 of
them, so utf8_splice_2 draws the rest. The cases after it (motion_outside,
nel, decrc_unsaved and placeholder_marks) were added from the review of the terminal model:
relative moves that start outside the scroll region, NEL, restoring a cursor that was never
saved, and the placeholder marks for the indices 112 to 123 (the diacritics that a placeholder
row and column of an image 112 or more cells across or down carry).
"""
import os
import random
import sys

sys.dont_write_bytecode = True   # a run of the harness writes no bytecode into the repository tree

_LIB = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _LIB not in sys.path:
    sys.path.insert(0, _LIB)

from vkitty.tokens import tmux_wrap  # noqa: E402

CASES = {}

EACUTE = "\u00e9"
ACUTE = "\u0301"
DIAER = "\u0308"
MACRON = "\u0305"
DBLACUTE = "\u030d"
BREVE = "\u0306"
WORLD = "\u4e16\u754c"
SMILE = "\U0001F600"
PLACEHOLDER = "\U0010EEEE"

# Rows of the utf8_splice case and of the tmux 3.5a probe of the same rules. Each row is
# (name, data, want, splices, in_battery): data follows an "A" (a %d in it is the row number),
# want is the text tmux shows after the "A", splices the count the tmux hop reports. A row with
# in_battery False holds a raw DEL or CAN in ground. The tokenizer prints both (its ground rule
# prints every byte above 0x0F, the known gap for those two bytes), while tmux shows neither, so
# the battery leaves those rows out; the tokens spec cases hold their text and their state.
UTF8_SPLICE_ROWS = [
    ("csi_inside", b"\xe4\x1b[31m\xb8\x96\x1b[mZ", "\u4e16Z", 1, True),
    ("dcs_tmux_inside", b"\xf4" + tmux_wrap(b"\x1b_Ga=d,d=i,i=7,q=2\x1b\\")
     + b"\x8e\xbb\xae\xcc\x85\xcc\x8dZ",
     "\U0010eeee\u0305\u030dZ", 1, True),
    ("osc_bel_inside", b"\xe4\x1b]0;title\x07\xb8\x96Z", "\u4e16Z", 1, True),
    ("ascii_resets", b"\xe4B\xb8\x96Z", "BZ", 0, True),
    ("nul_in_csi_resets", b"\xe4\x1b[3\x001m\xb8\x96Z\x1b[m", "Z", 1, True),
    ("lead_after_lead", b"\xe4\xe4\xb8\x96Z", "Z", 0, True),
    ("stray_continuation", b"\x8eZ", "Z", 0, True),
    ("esc7_esc8_inside", b"\xe4\xb8\x1b7\x1b8\x96Z", "\u4e16Z", 2, True),
    ("dcs_normal_inside", b"\xe4\x1bP|ab\x1b\\\xb8\x96Z", "\u4e16Z", 1, True),
    ("raw_apc_inside", b"\xe4\x1b_Gi=1;AAAA\x1b\\\xb8\x96Z", "\u4e16Z", 1, True),
    ("overlong", b"\xe0\x80\x80Z", "Z", 0, True),
    ("surrogate", b"\xed\xa0\x80Z", "Z", 0, True),
    ("above_max", b"\xf4\x90\x80\x80Z", "Z", 0, True),
    ("del_keeps", b"\xe4\x7f\xb8\x96Z", "\x7f\u4e16Z", 0, False),
    ("can_ground_resets", b"\xe4\x18\xb8\x96Z", "\x18Z", 0, False),
    ("can_in_csi_resets", b"\xe4\x1b[1;31\x18\xb8\x96Z", "Z", 1, True),
    ("cup_inside", b"\xe4\x1b[%d;30H\xb8\x96Z", "\u4e16Z", 1, True),
    ("c0_in_esc_resets", b"\xe4\x1b\x007\xb8\x96Z", "Z", 1, True),
    ("c0_after_osc_esc_resets", b"\xe4\x1b]0;t\x1b\x01\\\xb8\x96Z", "Z", 1, True),
    ("c0_in_tmux_body_keeps", b"\xe4\x1bPtmux;\x01\x1b\\\xb8\x96Z", "\u4e16Z", 1, True),
    ("can_in_osc_resets", b"\xe4\x1b]0;ab\x18\xb8\x96Z", "Z", 1, True),
    ("two_splices", b"\xf4\x1b[1m\x8e\x1b[22m\xbb\x1b[0m\xae\xcc\x85\xcc\x8dZ",
     "\U0010eeee\u0305\u030dZ", 3, True),
    ("e4_then_valid_4byte", b"\xe4\xf0\x9f\x98\x80Z", "Z", 0, True),
    ("lead_c0_dropped", b"\xc0\xe4\xb8\x96Z", "\u4e16Z", 0, True),
    ("lead_f5_dropped", b"\xf5\xe4\xb8\x96Z", "\u4e16Z", 0, True),
    ("sp_in_csi_keeps", b"\xe4\x1b[2 q\xb8\x96Z", "\u4e16Z", 1, True),
    ("c0_in_dcs_entry_keeps", b"\xe4\x1bP\x01|ab\x1b\\\xb8\x96Z", "\u4e16Z", 1, True),
]


def case(name):
    def register(fn):
        CASES[name] = fn
        return fn
    return register


def u8(text):
    return text.encode("utf-8")


def _cup(row, col):
    return b"\x1b[%d;%dH" % (row, col)


def _clear():
    return b"\x1b[0m\x1b[H\x1b[2J"


def _fill(rows, cols, ch=b"."):
    out = [_clear()]
    for y in range(1, rows + 1):
        out.append(_cup(y, 1) + ch * cols)
    return b"".join(out)


def _end(rows, cols):
    return b"\x1b[0m" + _cup(rows, cols)


@case("sgr")
def _sgr(cols, rows):
    forms = [
        ("0", "plain"), ("1", "bold"), ("2", "faint"), ("3", "italic"), ("4", "under"),
        ("4:0", "u-none"), ("4:1", "u-single"), ("4:2", "u-double"), ("4:3", "u-curly"),
        ("4:4", "u-dotted"), ("4:5", "u-dashed"), ("21", "u-21"), ("5", "blink"),
        ("7", "inverse"), ("8", "hidden"), ("9", "strike"), ("53", "overline"),
        ("1;3;4", "bold-italic-under"), ("2;9", "faint-strike"),
        ("22", "reset-bold"), ("23", "reset-italic"), ("24", "reset-under"),
        ("25", "reset-blink"), ("27", "reset-inverse"), ("28", "reset-hidden"),
        ("29", "reset-strike"), ("55", "reset-overline"),
        ("31", "red"), ("32", "green"), ("33", "yellow"), ("34", "blue"), ("35", "magenta"),
        ("36", "cyan"), ("37", "white"), ("90", "gray"), ("97", "bright-white"),
        ("41", "bg-red"), ("42", "bg-green"), ("44", "bg-blue"), ("100", "bg-gray"),
        ("107", "bg-bright-white"), ("39", "fg-default"), ("49", "bg-default"),
        ("38;5;1", "256-fg1"), ("38;5;100", "256-fg100"), ("38;5;200", "256-fg200"),
        ("48;5;4", "256-bg4"), ("48;5;220", "256-bg220"),
        ("38;2;255;128;0", "rgb-fg"), ("48;2;10;20;30", "rgb-bg"),
        ("38:5:9", "colon-256-fg"), ("48:5:33", "colon-256-bg"),
        ("38:2::1:2:3", "colon-rgb-fg"), ("48:2::200:100:50", "colon-rgb-bg"),
        ("38:2:7:8:9", "colon-rgb-nocs-fg"),
        ("58;5;196;4", "ul-256"), ("58;2;0;255;0;4:3", "ul-rgb-curly"),
        ("58:2::255:0:0;4", "ul-colon-rgb"), ("59", "ul-reset"),
        ("1;38;5;160;48;5;17", "bold-256-both"),
    ]
    out = [_clear()]
    for i, (params, label) in enumerate(forms):
        row = i % rows + 1
        col = (i // rows) * 26 + 1
        out.append(_cup(row, col) + b"\x1b[" + params.encode() + b"m" + label.encode()
                   + b"\x1b[0m")
    out.append(_cup(rows, 1) + b"\x1b[1;4:3;38;5;81mstack\x1b[22mhalf\x1b[0mdone")
    return b"".join(out) + _end(rows, cols)


@case("motion")
def _motion(cols, rows):
    # Every move is its own group, which starts with a CUP to a cell away from the
    # right edge: a relative move from the pending-wrap state is read differently
    # by tmux (its cursor sits at column 80) and is covered by a vt/ spec case.
    ops = [
        b"\x1b[8;12H", b"\x1b[A", b"\x1b[3A", b"\x1b[99A", b"\x1b[B", b"\x1b[2B", b"\x1b[99B",
        b"\x1b[C", b"\x1b[4C", b"\x1b[500C", b"\x1b[D", b"\x1b[3D", b"\x1b[99D",
        b"\x1b[H", b"\x1b[f", b"\x1b[7;12H", b"\x1b[;5H", b"\x1b[3;H", b"\x1b[99;99H",
        b"\x1b[12G", b"\x1b[G", b"\x1b[200G", b"\x1b[0G", b"\x1b[6d", b"\x1b[d", b"\x1b[99d",
        b"\x1b[0d", b"\x1b[2E", b"\x1b[3F", b"\x1b[0;0H", b"\x1b[0;7H", b"\x1b[5;0H",
        b"\x1b[24;80H", b"\x1b[25;81H", b"\x1b[1;1H", b"\x1b[K",
    ]
    out = [_clear()]
    for i, op in enumerate(ops):
        out.append(_cup(12, 40) + op + bytes([0x61 + i % 26]))
    out.append(b"\x1b[5;15r\x1b[?6h" + _cup(1, 1) + b"O" + _cup(99, 1) + b"P"
               + b"\x1b[A\x1b[A\x1b[A"
               + b"Q" + b"\x1b[30;99H" + b"R" + b"\x1b[?6l\x1b[r")
    out.append(b"\x1b[3;3H" + b"S")
    return b"".join(out) + _end(rows, cols)


# Each erase and scroll experiment is its own case: a stream starts by clearing the
# screen, so experiments in one stream would hide each other's results. Insert and
# delete lines with the cursor outside the margins are not here: tmux 3.5a moves
# lines over the whole screen there (screen-write.c screen_write_insertline), and
# Ghostty and the VT standard do nothing; vt/il_dl_outside_margins states that.
ERASE_OPS = [
    b"\x1b[10;20H\x1b[0J", b"\x1b[10;20H\x1b[1J", b"\x1b[2J",
    b"\x1b[10;20H\x1b[0K", b"\x1b[10;20H\x1b[1K", b"\x1b[10;20H\x1b[2K",
    b"\x1b[10;20H\x1b[3X", b"\x1b[10;20H\x1b[X", b"\x1b[10;78H\x1b[9X",
    b"\x1b[10;20H\x1b[41m\x1b[0J", b"\x1b[10;20H\x1b[44m\x1b[1K",
    b"\x1b[10;20H\x1b[42m\x1b[5X", b"\x1b[10;20H\x1b[45m\x1b[2K",
    b"\x1b[10;20H\x1b[46m\x1b[2J",
    b"\x1b[10;20H\x1b[43m\x1b[3X\x1b[0m\x1b[10;20H\x1b[K",
]


def _erase_case(op):
    def gen(cols, rows):
        return _fill(rows, cols) + op + _cup(rows, 1) + b"|" + _end(rows, cols)
    return gen


for _i, _op in enumerate(ERASE_OPS):
    CASES["erase-%02d" % _i] = _erase_case(_op)


@case("erase-edge")
def _erase_edge(cols, rows):
    # EL from the last column of a full line, with no pending wrap
    return _fill(rows, cols) + _cup(rows, cols) + b"\x1b[K" + _end(rows, cols)


SCROLL_OPS = [
    b"\x1b[5;10r" + _cup(10, 1) + b"\n" + b"\x1b[r",
    b"\x1b[5;10r" + _cup(5, 1) + b"\x1bM" + b"\x1b[r",
    b"\x1b[5;10r" + _cup(7, 3) + b"\x1b[2S" + b"\x1b[r",
    b"\x1b[5;10r" + _cup(7, 3) + b"\x1b[2T" + b"\x1b[r",
    b"\x1b[5;10r" + _cup(7, 1) + b"\x1b[2L" + b"\x1b[r",
    b"\x1b[5;10r" + _cup(7, 1) + b"\x1b[3M" + b"\x1b[r",
    _cup(24, 1) + b"\n\nend" + _cup(1, 1) + b"\x1bM",
    b"\x1b[1;5r" + _cup(5, 1) + b"\n\nab" + b"\x1b[r",
    b"\x1b[1;5r" + _cup(1, 1) + b"\x1bM\x1bM" + b"\x1b[r",
]


def _scroll_case(op):
    def gen(cols, rows):
        return _fill(rows, cols) + op + _end(rows, cols)
    return gen


for _i, _op in enumerate(SCROLL_OPS):
    CASES["scroll-%02d" % _i] = _scroll_case(_op)


@case("insdel")
def _insdel(cols, rows):
    out = [_clear()]
    out.append(_cup(3, 1) + b"abcdefghij" + _cup(3, 4) + b"\x1b[2@" + b"XY")
    out.append(_cup(4, 1) + b"abcdefghij" + _cup(4, 4) + b"\x1b[3P")
    out.append(_cup(5, 1) + b"abcdefghij" + _cup(5, 8) + b"\x1b[10@")
    out.append(_cup(6, 1) + b"abcdefghij" + _cup(6, 8) + b"\x1b[10P")
    out.append(_cup(7, 1) + b"0123456789" + b"\x1b[4h" + _cup(7, 3) + b"IN" + b"\x1b[4l" + b"out")
    out.append(_cup(8, 1) + b"0123456789" + _cup(8, 2) + b"\x1b[4h\x1b[5@" + b"\x1b[4l")
    out.append(_cup(9, 1) + b"x\x1b[7b")
    out.append(_cup(10, 40) + b"ab\x1b[5b")
    out.append(_cup(11, 1) + u8(WORLD * 2) + _cup(11, 3) + b"\x1b[2P")
    out.append(_cup(12, 1) + u8("abc" + WORLD[0] + "de") + _cup(12, 4) + b"\x1b[2@")
    return b"".join(out) + _end(rows, cols)


@case("wrap")
def _wrap(cols, rows):
    out = [_clear()]
    out.append(_cup(1, 1) + b"abcdefghijklmnopqrstuvwxyz" * 4 + b"!")
    out.append(_cup(3, 1) + b"\x1b[?7l" + b"0123456789" * 9 + b"END" + b"\x1b[?7h")
    out.append(_cup(5, 79) + u8(WORLD[0] + WORLD[1] + WORLD[0]) + b"tail")
    out.append(_cup(7, 1) + u8(WORLD[0] * 40) + b"z")
    out.append(_cup(9, 1) + u8("e" + ACUTE + "a" + ACUTE + "o" + DIAER) + u8(EACUTE + "x"))
    out.append(_cup(10, 1) + u8(SMILE * 3) + b"w")
    out.append(_cup(11, 78) + u8(SMILE) + b"w")
    out.append(_cup(12, 1) + u8(PLACEHOLDER + MACRON + DBLACUTE + PLACEHOLDER + MACRON + BREVE)
               + b"p")
    out.append(_cup(13, 80) + b"\x1b[1;4:3;38:5:33m" + u8(PLACEHOLDER + MACRON + DBLACUTE)
               + b"\x1b[0m" + b"after")
    return b"".join(out) + _end(rows, cols)


@case("screens")
def _screens(cols, rows):
    out = [_clear()]
    out.append(_cup(2, 2) + b"primary" + b"\x1b[?1049h" + b"\x1b[2J" + b"alt text" + _cup(3, 3)
               + b"\x1b[?1049l" + b"P2")
    out.append(_cup(5, 1) + b"keep" + b"\x1b[?47h" + b"x47" + b"\x1b[?47l" + b"y")
    out.append(_cup(7, 1) + b"base" + b"\x1b[?1047h" + b"z" + b"\x1b[?1047l" + b"w")
    out.append(_cup(9, 4) + b"\x1b7" + _cup(12, 20) + b"moved\x1b8" + b"saved")
    out.append(_cup(14, 6) + b"\x1b[s" + _cup(15, 1) + b"other\x1b[u" + b"back")
    out.append(_cup(16, 1) + b"\t" + b"T1" + b"\t" + b"T2" + b"\x1b[Z" + b"B")
    out.append(_cup(17, 1) + b"\x1b[3g" + b"\x1b[10G\x1bH" + b"\x1b[30G\x1bH" + b"\x1b[1G"
               + b"\t\tS")
    out.append(_cup(18, 1) + b"\x1b[0g" + b"\x1b[1G\t" + b"\x1b[g" + b"x")
    return b"".join(out) + _end(rows, cols)


@case("charset")
def _charset(cols, rows):
    out = [_clear()]
    out.append(_cup(2, 1) + b"\x1b(0lqqqk\x1b(Bplain")
    out.append(_cup(4, 1) + b"\x1b(0xaa\x0eabc\x0fx\x0elqk\x0fy")
    out.append(_cup(6, 1) + b"\x1b)0\x0e`~}{\x0f|z")
    out.append(_cup(8, 1) + b"\x1b(0mqj\x1b(B#")
    return b"".join(out) + _end(rows, cols)


@case("cuts")
def _cuts(cols, rows):
    out = [_clear()]
    out.append(_cup(2, 1) + b"\x1b[1;3\x1b[0mA")
    out.append(_cup(3, 1) + b"\x1b]0;title\x1b[1mB")
    out.append(_cup(4, 1) + b"\x1b[1\x18mZ")
    out.append(_cup(5, 1) + b"\x1b[2\x1aXY")
    out.append(_cup(6, 1) + b"\x1b[2\x0d;3H" + b"C")
    out.append(_cup(7, 1) + b"\x1b[1\x0a2;4H" + b"D")
    out.append(_cup(8, 1) + b"\x1b]2;a\x18E")
    out.append(_cup(11, 1) + b"\x1b[38;5;\x1b[7mH")
    return b"".join(out) + _end(rows, cols)


@case("nvimlike")
def _nvimlike(cols, rows):
    rnd = random.Random(20260624)
    sgrs = [b"\x1b[0m", b"\x1b[1m", b"\x1b[38;5;%dm", b"\x1b[1;34m", b"\x1b[48;2;30;30;46m",
            b"\x1b[7m", b"\x1b[4:3m", b"\x1b[0;33m", b"\x1b[38;2;200;160;60m"]
    words = [b"local ", b"function ", b"return ", b"self.", b"print(", b"x = 1 ", b"\"string\" ",
             b"-- note ", b"  ", b"end", b"}"]
    out = [_clear()]
    for _ in range(3000):
        row = rnd.randrange(1, rows + 1)
        col = rnd.randrange(1, cols + 1)
        sgr = rnd.choice(sgrs)
        if b"%d" in sgr:
            sgr = sgr % rnd.randrange(256)
        run = [rnd.choice(words) for _w in range(rnd.randrange(1, 4))]
        out.append(_cup(row, col))
        out.append(sgr)
        out.extend(run)
        if rnd.random() < 0.05:
            out.append(b"\x1b[K")
    out.append(b"\x1b[0m")
    # wide characters, with and without a background, are in the wrap case; a
    # redraw that overwrites half of one is in vt/ (tmux and Ghostty clear the
    # other half with different colours)
    return b"".join(out) + _end(rows, cols)


# Screen lines the utf8_splice stream uses (lines 1 to 21 of the 80 x 24 screen); the rows after
# them go to utf8_splice_2, from line 1 again.
SPLICE_LINES = 21


def _splice_stream(skip, limit, rows):
    """The battery rows of UTF8_SPLICE_ROWS after the first `skip` of them (at most `limit`, or all
    when it is None), one per line from line 1: "A", then the row's bytes."""
    out = [_clear()]
    number = 0
    seen = 0
    for _name, data, _want, _splices, in_battery in UTF8_SPLICE_ROWS:
        if not in_battery:
            continue
        seen += 1
        if seen <= skip or (limit is not None and seen > skip + limit):
            continue
        number += 1
        if number > rows:
            raise ValueError("the splice rows do not fit the %d-line screen" % rows)
        out.append(_cup(number, 1) + b"A" + (data % number if b"%d" in data else data))
    return b"".join(out)


@case("utf8_splice")
def _utf8_splice(cols, rows):
    # One row per UTF8_SPLICE_ROWS entry that the battery holds, the first SPLICE_LINES of them:
    # "A", then the row's bytes. An unfinished character carried across escape sequences, C0 bytes
    # and strings shows what tmux 3.5a shows (the characters, not replacement characters).
    return _splice_stream(0, SPLICE_LINES, rows) + _end(rows, cols)


@case("utf8_splice_2")
def _utf8_splice_2(cols, rows):
    # The battery rows after the first SPLICE_LINES (the screen has no more lines), from line 1:
    # the same "A" prefix and the same %d rule as utf8_splice.
    return _splice_stream(SPLICE_LINES, None, rows) + _end(rows, cols)


@case("motion_outside")
def _motion_outside(cols, rows):
    # CUD and CUU stop at a margin only when the cursor starts inside the region; from outside
    # they run to the screen edge. A region of rows 5 to 10 with moves from above, below and inside.
    return (_fill(rows, cols)
            + b"\x1b[5;10r\x1b[15;3H\x1b[3BX\x1b[20;3H\x1b[99BW\x1b[3;3H\x1b[9AY"
            + b"\x1b[2;6H\x1b[B\x1b[BV\x1b[7;3H\x1b[9AZ\x1b[7;6H\x1b[99BU\x1b[r"
            + _end(rows, cols))


@case("nel")
def _nel(cols, rows):
    # ESC E is a carriage return plus an index, also at the bottom margin of a region
    return (_fill(rows, cols)
            + b"\x1b[5;10H\x1bEA\x1b[10;30H\x1bE\x1bEB\x1b[5;8r\x1b[8;40H\x1bEC\x1b[r"
            + _end(rows, cols))


@case("decrc_unsaved")
def _decrc_unsaved(cols, rows):
    # DECRC with nothing saved homes the cursor and resets the pen
    return _clear() + b"\x1b[5;5H\x1b[31;44m\x1b8x" + _end(rows, cols)


# The marks of the indices 112 to 123 of the placeholder diacritic table: U+081B to U+0823 and
# U+0825 to U+0827. U+0824 is not in the table, so the run skips it. Each placeholder with its
# marks must be one cell.
PLACEHOLDER_MARKS = (0x081B, 0x081C, 0x081D, 0x081E, 0x081F, 0x0820, 0x0821, 0x0822, 0x0823,
                     0x0825, 0x0826, 0x0827)


@case("placeholder_marks")
def _placeholder_marks(cols, rows):
    # Twelve placeholder cells with a column mark of index 112 to 123 (row 0) on line 2, and
    # twelve with a row mark of that index (column 0, the two marks swapped) on line 3. Each
    # placeholder with its marks is one cell, as in Ghostty's model.
    cols_line = "".join(PLACEHOLDER + MACRON + chr(d) for d in PLACEHOLDER_MARKS)
    rows_line = "".join(PLACEHOLDER + chr(d) + MACRON for d in PLACEHOLDER_MARKS)
    return (_clear() + b"\x1b[38;2;0;0;7m" + _cup(2, 1) + u8(cols_line) + _cup(3, 1) + u8(rows_line)
            + _end(rows, cols))


def names():
    return list(CASES)


def main(argv):
    if argv == ["--list"]:
        for name in names():
            print(name)
        return 0
    if len(argv) != 4:
        print("usage: battery.py --list | battery.py NAME COLS ROWS OUT", file=sys.stderr)
        return 2
    name = argv[0]
    if name not in CASES:
        print("unknown case: %s" % name, file=sys.stderr)
        return 2
    try:
        cols, rows = int(argv[1]), int(argv[2])
    except ValueError:
        print("COLS and ROWS must be numbers", file=sys.stderr)
        return 2
    data = CASES[name](cols, rows)
    with open(argv[3], "wb") as fh:
        fh.write(data)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

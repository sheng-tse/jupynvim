"""Unicode placeholder placements of the Kitty graphics protocol (a Ghostty 1.3.1 port).

Ports src/terminal/kitty/graphics_unicode.zig: the 297 row and column diacritics (DIACRITICS, the
list of the Kitty protocol, which lua/jupynvim/notebook/image.lua also carries), the placement
iterator over a screen's rows (iterate: PlacementIterator, IncompletePlacement and colorToId), and
renderPlacement (render_placement: the image fitted into the placement's grid, with the source and
destination rectangles the renderer draws). Arithmetic is float64 and rounds with Zig's @round
(half away from zero), as the source does.

A run is one row of consecutive placeholder cells. Ghostty only looks for runs when the image
storage holds a virtual placement (renderer/image.zig kittyUpdate); the snapshot does the same.
Ghostty keeps a row flag (kitty_virtual_placeholder) to skip rows; this port scans every row for
the placeholder code point, which finds the same runs.

The diacritic_shift fault (faults.py) adds one to every diacritic index, to show that the tests
notice a wrong index.
"""
import math

from vkitty import faults
from vkitty import style as _style

PLACEHOLDER = 0x10EEEE            # graphics_unicode.zig placeholder
PLACEHOLDER_CHAR = chr(PLACEHOLDER)

# graphics_unicode.zig diacritics: the index of a code point is the row or column it encodes
DIACRITICS = (
    0x0305, 0x030D, 0x030E, 0x0310, 0x0312, 0x033D, 0x033E, 0x033F, 0x0346, 0x034A,
    0x034B, 0x034C, 0x0350, 0x0351, 0x0352, 0x0357, 0x035B, 0x0363, 0x0364, 0x0365,
    0x0366, 0x0367, 0x0368, 0x0369, 0x036A, 0x036B, 0x036C, 0x036D, 0x036E, 0x036F,
    0x0483, 0x0484, 0x0485, 0x0486, 0x0487, 0x0592, 0x0593, 0x0594, 0x0595, 0x0597,
    0x0598, 0x0599, 0x059C, 0x059D, 0x059E, 0x059F, 0x05A0, 0x05A1, 0x05A8, 0x05A9,
    0x05AB, 0x05AC, 0x05AF, 0x05C4, 0x0610, 0x0611, 0x0612, 0x0613, 0x0614, 0x0615,
    0x0616, 0x0617, 0x0657, 0x0658, 0x0659, 0x065A, 0x065B, 0x065D, 0x065E, 0x06D6,
    0x06D7, 0x06D8, 0x06D9, 0x06DA, 0x06DB, 0x06DC, 0x06DF, 0x06E0, 0x06E1, 0x06E2,
    0x06E4, 0x06E7, 0x06E8, 0x06EB, 0x06EC, 0x0730, 0x0732, 0x0733, 0x0735, 0x0736,
    0x073A, 0x073D, 0x073F, 0x0740, 0x0741, 0x0743, 0x0745, 0x0747, 0x0749, 0x074A,
    0x07EB, 0x07EC, 0x07ED, 0x07EE, 0x07EF, 0x07F0, 0x07F1, 0x07F3, 0x0816, 0x0817,
    0x0818, 0x0819, 0x081B, 0x081C, 0x081D, 0x081E, 0x081F, 0x0820, 0x0821, 0x0822,
    0x0823, 0x0825, 0x0826, 0x0827, 0x0829, 0x082A, 0x082B, 0x082C, 0x082D, 0x0951,
    0x0953, 0x0954, 0x0F82, 0x0F83, 0x0F86, 0x0F87, 0x135D, 0x135E, 0x135F, 0x17DD,
    0x193A, 0x1A17, 0x1A75, 0x1A76, 0x1A77, 0x1A78, 0x1A79, 0x1A7A, 0x1A7B, 0x1A7C,
    0x1B6B, 0x1B6D, 0x1B6E, 0x1B6F, 0x1B70, 0x1B71, 0x1B72, 0x1B73, 0x1CD0, 0x1CD1,
    0x1CD2, 0x1CDA, 0x1CDB, 0x1CE0, 0x1DC0, 0x1DC1, 0x1DC3, 0x1DC4, 0x1DC5, 0x1DC6,
    0x1DC7, 0x1DC8, 0x1DC9, 0x1DCB, 0x1DCC, 0x1DD1, 0x1DD2, 0x1DD3, 0x1DD4, 0x1DD5,
    0x1DD6, 0x1DD7, 0x1DD8, 0x1DD9, 0x1DDA, 0x1DDB, 0x1DDC, 0x1DDD, 0x1DDE, 0x1DDF,
    0x1DE0, 0x1DE1, 0x1DE2, 0x1DE3, 0x1DE4, 0x1DE5, 0x1DE6, 0x1DFE, 0x20D0, 0x20D1,
    0x20D4, 0x20D5, 0x20D6, 0x20D7, 0x20DB, 0x20DC, 0x20E1, 0x20E7, 0x20E9, 0x20F0,
    0x2CEF, 0x2CF0, 0x2CF1, 0x2DE0, 0x2DE1, 0x2DE2, 0x2DE3, 0x2DE4, 0x2DE5, 0x2DE6,
    0x2DE7, 0x2DE8, 0x2DE9, 0x2DEA, 0x2DEB, 0x2DEC, 0x2DED, 0x2DEE, 0x2DEF, 0x2DF0,
    0x2DF1, 0x2DF2, 0x2DF3, 0x2DF4, 0x2DF5, 0x2DF6, 0x2DF7, 0x2DF8, 0x2DF9, 0x2DFA,
    0x2DFB, 0x2DFC, 0x2DFD, 0x2DFE, 0x2DFF, 0xA66F, 0xA67C, 0xA67D, 0xA6F0, 0xA6F1,
    0xA8E0, 0xA8E1, 0xA8E2, 0xA8E3, 0xA8E4, 0xA8E5, 0xA8E6, 0xA8E7, 0xA8E8, 0xA8E9,
    0xA8EA, 0xA8EB, 0xA8EC, 0xA8ED, 0xA8EE, 0xA8EF, 0xA8F0, 0xA8F1, 0xAAB0, 0xAAB2,
    0xAAB3, 0xAAB7, 0xAAB8, 0xAABE, 0xAABF, 0xAAC1, 0xFE20, 0xFE21, 0xFE22, 0xFE23,
    0xFE24, 0xFE25, 0xFE26, 0x10A0F, 0x10A38, 0x1D185, 0x1D186, 0x1D187, 0x1D188,
    0x1D189, 0x1D1AA, 0x1D1AB, 0x1D1AC, 0x1D1AD, 0x1D242, 0x1D243, 0x1D244,
)

DIAC_INDEX = {cp: i for i, cp in enumerate(DIACRITICS)}


class Missing(Exception):
    """A run that draws nothing. `reason` is what the snapshot reports for it."""

    def __init__(self, reason):
        Exception.__init__(self, reason)
        self.reason = reason


class VPlacement:
    """A virtual placement (graphics_unicode.zig Placement): the first cell of its run (x, the
    column, and y, the screen row), the image id (low 24 bits from the fg, the high byte from the
    third diacritic), the placement id (from the underline colour, 0 for none), the fragment of the
    image it shows (col, row, in placement cells) and its width in cells (height is always 1)."""

    __slots__ = ("x", "y", "image_id", "placement_id", "col", "row", "width", "height")

    def __init__(self, x, y, image_id, placement_id, col, row, width):
        self.x = x
        self.y = y
        self.image_id = image_id
        self.placement_id = placement_id
        self.col = col
        self.row = row
        self.width = width
        self.height = 1


class RenderPlacement:
    """graphics_unicode.zig RenderPlacement: the offsets and source rectangle (image pixels) and
    the destination size (device pixels) of one run."""

    __slots__ = ("offset_x", "offset_y", "source_x", "source_y", "source_width", "source_height",
                 "dest_width", "dest_height")

    def __init__(self, offset_x, offset_y, source_x, source_y, source_width, source_height,
                 dest_width, dest_height):
        self.offset_x = offset_x
        self.offset_y = offset_y
        self.source_x = source_x
        self.source_y = source_y
        self.source_width = source_width
        self.source_height = source_height
        self.dest_width = dest_width
        self.dest_height = dest_height


class _Incomplete:
    """IncompletePlacement: what one cell says. A missing row, column or high byte continues the
    run."""

    __slots__ = ("x", "y", "image_id_low", "image_id_high", "placement_id", "row", "col", "width")


def zig_round(x):
    """Zig's @round: the nearest integer, halves away from zero, as an int."""
    a = abs(x)
    r = math.floor(a)
    if a - r >= 0.5:
        r += 1
    return int(r) if x >= 0 else -int(r)


def color_id(color):
    """colorToId: a palette index as it is, an RGB colour's 24 bits, and 0 for no colour."""
    if color is None:
        return 0
    if color & _style.RGB_FLAG:
        return color & 0xFFFFFF
    return color


def _index(cp, shift):
    idx = DIAC_INDEX.get(cp)
    if idx is None:
        return None              # an invalid diacritic counts as absent
    return idx + shift


def _incomplete(x, y, text, sid, styles, shift):
    fg, _bg, ul, _flags = styles[sid]
    inc = _Incomplete()
    inc.x = x
    inc.y = y
    inc.image_id_low = color_id(fg)
    pid = color_id(ul)
    inc.placement_id = pid if pid else None
    inc.row = None
    inc.col = None
    inc.image_id_high = None
    inc.width = 1
    if len(text) > 1:
        inc.row = _index(ord(text[1]), shift)
        if len(text) > 2:
            inc.col = _index(ord(text[2]), shift)
            if len(text) > 3:
                high = _index(ord(text[3]), shift)
                # the high byte is 8 bits: a larger index is an invalid diacritic (u8 cast)
                inc.image_id_high = high if high is not None and high <= 255 else None
    return inc


def _start(run):
    """A run starts at its first cell, which gives a missing row or column the value 0."""
    if run.row is None:
        run.row = 0
    if run.col is None:
        run.col = 0
    return run


def _can_append(run, other):
    """IncompletePlacement.canAppend: the same image low bits and placement id, a row that is absent
    or the same, a column that is absent or the next one, and a high byte that is absent or the
    same."""
    return (run.image_id_low == other.image_id_low
            and run.placement_id == other.placement_id
            and (other.row is None or other.row == run.row)
            and (other.col is None or other.col == run.col + run.width)
            and (other.image_id_high is None or other.image_id_high == run.image_id_high))


def _complete(run):
    """IncompletePlacement.complete."""
    high = run.image_id_high or 0
    return VPlacement(run.x, run.y, run.image_id_low | (high << 24),
                      run.placement_id or 0, run.col, run.row, run.width)


def iterate(sc, styles, shift=None):
    """Every virtual placement on the screen's rows, in row-major order (PlacementIterator). sc is
    a vt.Screen (its grid of rows) and styles the terminal's style list (style ids index it)."""
    if shift is None:
        shift = 1 if faults.active("diacritic_shift") else 0
    out = []
    for y, row in enumerate(sc.grid):
        if not any(text and text[0] == PLACEHOLDER_CHAR for text in row.text):
            continue
        run = None
        for x, text in enumerate(row.text):
            if not text or text[0] != PLACEHOLDER_CHAR:
                if run is not None:
                    out.append(_complete(run))
                    run = None
                continue
            cur = _incomplete(x, y, text, row.sid[x], styles, shift)
            if run is None:
                run = _start(cur)
            elif _can_append(run, cur):
                run.width += 1
            else:
                out.append(_complete(run))
                run = _start(cur)
        if run is not None:
            out.append(_complete(run))
    return out


def _ceil_div(a, b):
    return 0 if b == 0 else -(-a // b)


def grid(vp, storage, image, cell_w, cell_h):
    """Placement.grid: the columns and rows of the placement the run names. A placement id selects
    that placement; otherwise the image's first virtual placement is used. Zero sizes take the
    image's size in cells, rounded up. Raises Missing when no placement is there."""
    if vp.placement_id > 0:
        place = storage.placements.get((vp.image_id, ("e", vp.placement_id)))
    elif storage.v14:
        # placeholderTarget: of the image's virtual placements the one an external id names comes
        # first, then the lowest id (the preferredOver order), so the choice is stable
        place = None
        best = None
        for (image_id, pkey), cand in storage.placements.items():
            if image_id != vp.image_id or cand.location is not None or cand.relative is not None:
                continue
            rank = (0 if pkey[0] == "e" else 1, pkey[1])
            if best is None or rank < best:
                best, place = rank, cand
    else:
        place = None
        for (image_id, _pkey), cand in storage.placements.items():
            if image_id == vp.image_id and cand.location is None:
                place = cand
                break
    if place is None:
        raise Missing("placement missing")
    rows = place.rows or _ceil_div(image.height, cell_h)
    cols = place.columns or _ceil_div(image.width, cell_w)
    if rows > 0xFFFF or cols > 0xFFFF:
        raise Missing("placement grid out of bounds")
    return cols, rows


def render_placement(vp, storage, image, cell_w, cell_h):
    """renderPlacement: fit the image into the grid of the run, keeping its aspect ratio and
    centring it, then cut out the part the run shows. Returns a RenderPlacement, or None when the
    run's rectangle lies outside the image (Ghostty returns a zero-sized placement then)."""
    cols, rows = grid(vp, storage, image, cell_w, cell_h)
    img_w = float(image.width)
    img_h = float(image.height)
    p_rows_px = float(rows * cell_h)
    p_cols_px = float(cols * cell_w)
    if img_w * p_rows_px > img_h * p_cols_px:
        # wider than the grid: fit the width and centre the height
        x_scale = p_cols_px / max(img_w, 1.0)
        y_scale = x_scale
        x_off = 0.0
        y_off = (p_rows_px - img_h * y_scale) / 2.0
    else:
        # taller than the grid: fit the height and centre the width
        y_scale = p_rows_px / max(img_h, 1.0)
        x_scale = y_scale
        x_off = (p_cols_px - img_w * x_scale) / 2.0
        y_off = 0.0
    # the scaled image, with the bars left and right and top and bottom, in image pixels
    sx_off = x_off / x_scale
    sy_off = y_off / y_scale
    w_s = img_w + sx_off * 2.0
    h_s = img_h + sy_off * 2.0
    # the source rectangle in the scaled image
    vp_w = float(vp.width)
    vp_h = float(vp.height)
    vp_col = float(vp.col)
    vp_row = float(vp.row)
    p_grid_cols = float(cols)
    p_grid_rows = float(rows)
    src_w = w_s * (vp_w / p_grid_cols)
    src_h = h_s * (vp_h / p_grid_rows)
    src_x = w_s * (vp_col / p_grid_cols)
    src_y = h_s * (vp_row / p_grid_rows)
    # the destination, cut where the source runs into a bar
    dst_x_off = 0.0
    dst_y_off = 0.0
    dst_w = float(vp.width * cell_w)
    dst_h = float(vp.height * cell_h)
    if src_y < sy_off:
        off = sy_off - src_y
        src_h -= off
        dst_y_off = off
        dst_h -= off * y_scale
        src_y = 0.0
        if src_h > img_h:
            src_h = img_h
            dst_h = img_h * y_scale
    elif src_y + src_h > h_s - sy_off:
        src_y -= sy_off
        src_h = h_s - sy_off - src_y
        src_h -= sy_off
        dst_h = src_h * y_scale
    else:
        src_y -= sy_off
    if src_x < sx_off:
        off = sx_off - src_x
        src_w -= off
        dst_x_off = off
        dst_w -= off * x_scale
        src_x = 0.0
        if src_w > img_w:
            src_w = img_w
            dst_w = img_w * x_scale
    elif src_x + src_w > w_s - sx_off:
        src_x -= sx_off
        src_w = w_s - sx_off - src_x
        src_w -= sx_off
        dst_w = src_w * x_scale
    else:
        src_x -= sx_off
    if src_w <= 0 or src_h <= 0:
        return None
    return RenderPlacement(
        zig_round(dst_x_off * x_scale), zig_round(dst_y_off * y_scale),
        zig_round(src_x), zig_round(src_y), zig_round(src_w), zig_round(src_h),
        zig_round(dst_w), zig_round(dst_h))

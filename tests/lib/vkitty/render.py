"""The headless renderer: a cell grid (vkitty.snapshot.Snapshot) painted to pixels as the reference
renderer paints it, with the image layers of Ghostty 1.3.1.

    render(snap, *, theme=DEFAULT_THEME, crop_rows=None, images=True, warn=None) -> (H, W, 3) uint8

W = 2 * pad + cols * cw and H = 2 * pad + rows * ch, at 2x (13 x 33 px cells, pad 4). The text part
is a port of the reference renderer (Chrome canvas text with Ghostty's metrics, the box and block
sprites, the symbol fit of Ghostty's constraint, runs shaped as Ghostty breaks them) and the
reference capture parser (the per-cell flags). The draw order is Ghostty's (renderer/generic.zig,
renderer/image.zig):

  1 the window background
  2 images below the cell backgrounds (z below INT32_MIN / 2)
  3 the cell backgrounds
  4 images between the backgrounds and the text (-2^30 <= z < 0; virtual placements draw at z -1)
  5 a block cursor's rectangle (two cells on a wide character, head or tail)
  6 underlines and overlines
  7 glyphs and sprites, cell by cell
  8 strikethroughs
  9 a bar, an underline or a hollow block cursor, painted over its cell
 10 images above the text (z >= 0)

The cells of a block cursor are drawn like any other (decorations, glyph) but in the cursor text
colour, which is what Ghostty's text pass does after it draws the block cursor first.

An image is sampled bilinearly in linear light (Ghostty's image textures are sRGB, so the filter
runs on linear values), unlinearized, premultiplied and composited with out = src + dst * (1 - a).
Colours blend in sRGB. The frame is float32 and is rounded once at the end.

faults: "no_linear" filters the image in sRGB; "no_images" skips the image layers (both in
tests/lib/vkitty/faults.py, both checked by the spec).
"""
import functools
import math
import unicodedata
from collections import OrderedDict

import numpy as np
from PIL import Image, ImageDraw

from vkitty import faults as _faults
from vkitty import fonts as _fonts
from vkitty import style as _style

LAYER_LIMIT = -(1 << 30)     # INT32_MIN // 2: draws below it sit under the cell backgrounds
PLACEHOLDER = 0x10EEEE       # Kitty Unicode placeholder (U+10EEEE)
# one cell's advance in Iosevka font units (the reference renderer's ADV)
ADVANCE = 500
SS = 4                       # supersampling of curved strokes
TEXTURE_CACHE = 8            # linear textures kept (each is a float32 copy of the image)

PALETTE = ("#1b1d2b", "#ff757f", "#c3e88d", "#ffc777", "#82aaff", "#c099ff", "#86e1fc", "#828bb8",
           "#444a73", "#ff757f", "#c3e88d", "#ffc777", "#82aaff", "#c099ff", "#86e1fc", "#c8d3f5")

# the reference renderer's THEME: TokyoNight Moon (Ghostty's bundled theme), faint opacity 0.5
DEFAULT_THEME = {
    "bg": "#222436",
    "fg": "#c8d3f5",
    "cursor": "#c8d3f5",
    "cursor_text": "#222436",
    "palette": PALETTE,
    "faint": 0.5,
}

# up, down, left, right per box drawing character (the reference renderer's BOX)
_BOX = {
    0x2500: "nnll", 0x2501: "nnhh", 0x2502: "llnn", 0x2503: "hhnn",
    0x250c: "nlnl", 0x250d: "nlnh", 0x250e: "nhnl", 0x250f: "nhnh",
    0x2510: "nlln", 0x2511: "nlhn", 0x2512: "nhln", 0x2513: "nhhn",
    0x2514: "lnnl", 0x2515: "lnnh", 0x2516: "hnnl", 0x2517: "hnnh",
    0x2518: "lnln", 0x2519: "lnhn", 0x251a: "hnln", 0x251b: "hnhn",
    0x251c: "llnl", 0x2524: "llln", 0x252c: "nlll", 0x2534: "lnll", 0x253c: "llll",
    0x2523: "hhnh", 0x252b: "hhhn", 0x2533: "nhhh", 0x253b: "hnhh", 0x254b: "hhhh",
    0x2550: "nndd", 0x2551: "ddnn", 0x2554: "ndnd", 0x2557: "nddn", 0x255a: "dnnd", 0x255d: "dndn",
    0x2560: "ddnd", 0x2563: "dddn", 0x2566: "nddd", 0x2569: "dndd", 0x256c: "dddd",
    0x2574: "nnln", 0x2575: "lnnn", 0x2576: "nnnl", 0x2577: "nlnn",
    0x2578: "nnhn", 0x2579: "hnnn", 0x257a: "nnnh", 0x257b: "nhnn",
}
# rounded corners: br, bl, tl, tr (the reference renderer's ARC)
_ARC = {0x256d: "br", 0x256e: "bl", 0x256f: "tl", 0x2570: "tr"}
# block elements: align, width and height as a fraction of the cell, shade alpha (the reference
# renderer's BLOCK)
_BLOCK = {
    0x2580: ("top", 1, 1 / 2, 1), 0x2581: ("bottom", 1, 1 / 8, 1), 0x2582: ("bottom", 1, 1 / 4, 1),
    0x2583: ("bottom", 1, 3 / 8, 1), 0x2584: ("bottom", 1, 1 / 2, 1),
    0x2585: ("bottom", 1, 5 / 8, 1),
    0x2586: ("bottom", 1, 3 / 4, 1), 0x2587: ("bottom", 1, 7 / 8, 1), 0x2588: ("left", 1, 1, 1),
    0x2589: ("left", 7 / 8, 1, 1), 0x258a: ("left", 3 / 4, 1, 1), 0x258b: ("left", 5 / 8, 1, 1),
    0x258c: ("left", 1 / 2, 1, 1), 0x258d: ("left", 3 / 8, 1, 1), 0x258e: ("left", 1 / 4, 1, 1),
    0x258f: ("left", 1 / 8, 1, 1), 0x2590: ("right", 1 / 2, 1, 1), 0x2594: ("top", 1, 1 / 8, 1),
    0x2595: ("right", 1 / 8, 1, 1), 0x2591: ("left", 1, 1, 0x40 / 255),
    0x2592: ("left", 1, 1, 0x80 / 255),
    0x2593: ("left", 1, 1, 0xC0 / 255),
}
# quadrant blocks U+2596..U+259F: the quadrants each one fills (the reference renderer)
_QUADRANTS = {
    0x2596: "bl", 0x2597: "br", 0x2598: "tl", 0x2599: "tl bl br", 0x259A: "tl br",
    0x259B: "tl tr bl", 0x259C: "tl tr br", 0x259D: "tr", 0x259E: "tr bl", 0x259F: "tr bl br",
}
# Ghostty's symbol class (src/build/uucode_config.zig computeIsSymbol), as the reference capture
# parser lists it
_SYMBOL_RANGES = ((0x2190, 0x21FF), (0x2700, 0x27BF), (0x1F600, 0x1F64F), (0x2600, 0x26FF),
                  (0x2460, 0x24FF), (0x1F100, 0x1F1FF), (0x1F300, 0x1F5FF), (0x1F680, 0x1F6FF))

_METRICS = {}
_TEXTURES = OrderedDict()


class Metrics:
    """The reference renderer's metricsFor: the cell and the face's positions, in device pixels."""

    def __init__(self, **values):
        self.__dict__.update(values)


def _zround(v):
    """Zig's @round (half away from zero), as the reference renderer zround."""
    return -math.floor(-v + 0.5) if v < 0 else math.floor(v + 0.5)


def _zr(v):
    """The reference renderer's zr and Math.round for the positive values drawn here (half up)."""
    return math.floor(v + 0.5)


def metrics_for(face_path, px=26, pad=4):
    """metricsFor (the reference renderer, Ghostty's src/font/Metrics.zig) for a face file: upm, the
    OS/2 typo ascender, descender and line gap, the advance of U+0020, the post underline and the
    OS/2 strikeout. For IosevkaCustom Regular at 26 px: cell 13 x 33, baseline 26, underline 27 (2
    px), strikethrough 19 (2 px), box line 2 px."""
    from fontTools.ttLib import TTFont
    font = TTFont(face_path, lazy=True)
    try:
        upm = font["head"].unitsPerEm
        os2 = font["OS/2"]
        adv_units = font["hmtx"][font.getBestCmap()[0x20]][0]
        post = font["post"]
        typo_asc, typo_desc, typo_gap = os2.sTypoAscender, os2.sTypoDescender, os2.sTypoLineGap
        ul_pos, ul_th = post.underlinePosition, post.underlineThickness
        st_pos, st_th = os2.yStrikeoutPosition, os2.yStrikeoutSize
    finally:
        font.close()
    u = px / upm
    ascent = typo_asc * u
    descent = typo_desc * u
    gap = typo_gap * u
    face_h = ascent - descent + gap
    face_w = adv_units * u
    cell_w = _zround(face_w)
    cell_h = _zround(face_h)
    face_base = gap / 2 - descent
    cell_base = _zround(face_base - (cell_h - face_h) / 2)
    top_to_base = cell_h - cell_base
    ul_thick = max(1, math.ceil(ul_th * u))
    st_thick = max(1, math.ceil(st_th * u))
    return Metrics(cw=cell_w, ch=cell_h, base=top_to_base, ulPos=_zround(top_to_base - ul_pos * u),
                   ulTh=ul_thick, stPos=_zround(top_to_base - st_pos * u), stTh=st_thick,
                   boxTh=ul_thick, px=px, pad=pad, adv=adv_units, faceW=face_w, faceH=face_h,
                   cellBase=cell_base, faceBase=face_base)


def _metrics():
    path = _fonts.faces()["regular"]
    got = _METRICS.get(path)
    if got is None:
        got = metrics_for(path)
        _METRICS[path] = got
    return got


def drop_caches():
    """Forget the loaded fonts, glyph masks, metrics and image textures: the next render starts
    cold."""
    _fonts.drop()
    _METRICS.clear()
    _TEXTURES.clear()


def _hex(value):
    text = value.lstrip("#")
    return (int(text[0:2], 16), int(text[2:4], 16), int(text[4:6], 16))


def _palette_rgb(theme, n):
    """A 256-colour palette index as RGB (the reference renderer's x256)."""
    if n < 16:
        return _hex(theme["palette"][n])
    if n < 232:
        n -= 16
        lv = (0, 95, 135, 175, 215, 255)
        return (lv[n // 36], lv[(n // 6) % 6], lv[n % 6])
    v = 8 + (n - 232) * 10
    return (v, v, v)


def _colour(value, theme):
    """A colour of style_to_dict (a palette index or '#rrggbb') as an RGB tuple, or None."""
    if value is None:
        return None
    if isinstance(value, str):
        return _hex(value)
    return _palette_rgb(theme, int(value))


class _Look:
    """A cell style as the renderer reads it (the reference renderer's s object, the capture
    parser's keys)."""
    __slots__ = ("fg", "bg", "ul", "u", "b", "i", "d", "r", "s", "o", "inv", "face", "key",
                 "rfg", "rbg", "ralpha")


def _look(style, theme):
    d = _style.style_to_dict(style)
    look = _Look()
    look.fg = _colour(d.get("fg"), theme)
    look.bg = _colour(d.get("bg"), theme)
    look.ul = _colour(d.get("ul"), theme)
    look.u = d.get("u")
    look.b = bool(d.get("b"))
    look.i = bool(d.get("i"))
    look.d = bool(d.get("d"))
    look.r = bool(d.get("r"))
    look.s = bool(d.get("s"))
    look.o = bool(d.get("o"))
    look.inv = bool(d.get("inv"))
    look.face = "bold_italic" if look.b and look.i else "bold" if look.b else \
        "italic" if look.i else "regular"
    look.key = tuple(sorted((k, str(v)) for k, v in d.items() if k != "bg"))
    return look


@functools.lru_cache(maxsize=None)
def _is_symbol(cp):
    """Ghostty's symbol class (the reference capture parser's is_symbol)."""
    if unicodedata.category(chr(cp)) == "Co":
        return True
    return any(a <= cp <= b for a, b in _SYMBOL_RANGES)


def _is_graphics(cp):
    """The reference capture parser's is_graphics: the characters whose cell is not the font's to
    scale."""
    return (0x2500 <= cp <= 0x259F or 0x1FB00 <= cp <= 0x1FBFF or 0x1CC00 <= cp <= 0x1CEBF
            or 0xE0B0 <= cp <= 0xE0D7)


def _constraint_width(row, x, cols, width, cp):
    """The cells a symbol may fill (Ghostty's constraint width in renderer/cell.zig, as the
    reference renderer's per-cell flags compute it)."""
    if width > 1:
        return width
    if not _is_symbol(cp):
        return 1
    if x == cols - 1:
        return 1
    prev = row[x - 1][0] if x > 0 else ""
    pcp = ord(prev[0]) if prev else 0
    nxt = row[x + 1][0] if x + 1 < cols else ""
    ncp = ord(nxt[0]) if nxt else 0
    if x > 0 and pcp and _is_symbol(pcp) and not _is_graphics(pcp):
        return 1
    # Ghostty's constraintWidth: the next cell is empty (code point 0) or isSpace (U+0020, U+2002)
    if ncp == 0 or ncp == 0x20 or ncp == 0x2002:
        return 2
    return 1


def _vec(rgb):
    return np.asarray(rgb, dtype=np.float32)


def _fill_int(canvas, x, y, w, h, rgb, alpha=1.0):
    """A whole-pixel rectangle, blended with alpha, clipped to the canvas."""
    H, W = canvas.shape[0], canvas.shape[1]
    x0, y0 = max(0, x), max(0, y)
    x1, y1 = min(W, x + w), min(H, y + h)
    if x0 >= x1 or y0 >= y1:
        return
    region = canvas[y0:y1, x0:x1]
    if alpha >= 1.0:
        region[...] = rgb
    else:
        region += (_vec(rgb) - region) * np.float32(alpha)


def _blend_mask(canvas, mask, x0, y0, rgb, alpha=1.0):
    """Composite a coverage mask (h, w) with its top left at (x0, y0): out = src * a + dst * (1 -
    a). rgb is one colour, or an (h, w, 3) array of colours (a colour glyph)."""
    if not isinstance(rgb, np.ndarray):
        rgb = _vec(rgb)
    h, w = mask.shape[0], mask.shape[1]
    H, W = canvas.shape[0], canvas.shape[1]
    xa, ya = max(0, x0), max(0, y0)
    xb, yb = min(W, x0 + w), min(H, y0 + h)
    if xa >= xb or ya >= yb:
        return
    a = mask[ya - y0:yb - y0, xa - x0:xb - x0]
    if alpha != 1.0:
        a = a * np.float32(alpha)
    a = a[..., None]
    region = canvas[ya:yb, xa:xb]
    if rgb.ndim == 1:
        region += (rgb - region) * a
    else:
        region += (rgb[ya - y0:yb - y0, xa - x0:xb - x0] - region) * a


def _fill_frac(canvas, x, y, w, h, rgb, alpha=1.0):
    """A rectangle at fractional device coordinates, with its edge pixels covered in proportion."""
    if float(x).is_integer() and float(y).is_integer() and float(w).is_integer() \
            and float(h).is_integer():
        _fill_int(canvas, int(x), int(y), int(w), int(h), rgb, alpha)
        return
    xs = np.arange(math.floor(x), math.ceil(x + w))
    ys = np.arange(math.floor(y), math.ceil(y + h))
    cover_x = np.clip(np.minimum(xs + 1, x + w) - np.maximum(xs, x), 0, 1).astype(np.float32)
    cover_y = np.clip(np.minimum(ys + 1, y + h) - np.maximum(ys, y), 0, 1).astype(np.float32)
    _blend_mask(canvas, np.outer(cover_y, cover_x), int(xs[0]), int(ys[0]), rgb, alpha)


def _bezier(p0, p1, p2, p3, n=24):
    """Points of a cubic Bezier curve after its start point, ending at p3."""
    out = []
    for k in range(1, n + 1):
        t = k / n
        mt = 1 - t
        a, b, c, d = mt * mt * mt, 3 * mt * mt * t, 3 * mt * t * t, t * t * t
        out.append((a * p0[0] + b * p1[0] + c * p2[0] + d * p3[0],
                    a * p0[1] + b * p1[1] + c * p2[1] + d * p3[1]))
    return out


def _stroke(canvas, points, width, rgb, alpha, round_caps=False):
    """A polyline in device pixels stroked with width px (butt caps, or round caps), supersampled SS
    times on each axis and box filtered."""
    xs = [p[0] for p in points]
    ys = [p[1] for p in points]
    margin = width / 2 + 2
    x0 = math.floor(min(xs) - margin)
    y0 = math.floor(min(ys) - margin)
    w = math.ceil(max(xs) + margin) - x0
    h = math.ceil(max(ys) + margin) - y0
    img = Image.new("L", (w * SS, h * SS), 0)
    draw = ImageDraw.Draw(img)
    half = width * SS / 2
    pts = [((px - x0) * SS, (py - y0) * SS) for px, py in points]
    for (ax, ay), (bx, by) in zip(pts, pts[1:]):
        dx, dy = bx - ax, by - ay
        length = math.hypot(dx, dy)
        if length == 0:
            continue
        nx, ny = -dy / length * half, dx / length * half
        draw.polygon([(ax + nx, ay + ny), (bx + nx, by + ny), (bx - nx, by - ny),
                      (ax - nx, ay - ny)],
                     fill=255)
    if round_caps:
        for ax, ay in (pts[0], pts[-1]):
            draw.ellipse([ax - half, ay - half, ax + half, ay + half], fill=255)
    cov = np.asarray(img, dtype=np.float32).reshape(h, SS, w, SS).mean(axis=(1, 3)) / 255.0
    _blend_mask(canvas, cov, x0, y0, rgb, alpha)


class _Frame:
    """Everything one render reads: the canvas, the metrics, the colours and the cursor."""

    def __init__(self, snap, theme, warn):
        self.snap = snap
        self.cols = snap.cols
        self.rows = snap.rows
        self.m = _metrics()
        m = self.m
        if (snap.cell_w, snap.cell_h, snap.pad) != (m.cw, m.ch, m.pad):
            raise ValueError("the snapshot's cell %r is not the renderer's %r"
                             % ((snap.cell_w, snap.cell_h, snap.pad), (m.cw, m.ch, m.pad)))
        self.W = 2 * m.pad + self.cols * m.cw
        self.H = 2 * m.pad + self.rows * m.ch
        self.theme = theme
        self.bg = _hex(theme["bg"])
        self.fg = _hex(theme["fg"])
        self.cursor_rgb = _hex(theme["cursor"])
        self.cursor_text_rgb = _hex(theme["cursor_text"])
        self.faint = float(theme["faint"])
        self.warn = warn
        self.canvas = np.empty((self.H, self.W, 3), dtype=np.float32)
        self.canvas[...] = _vec(self.bg)
        self.looks = [_look(style, theme) for style in snap.styles]
        for look in self.looks:
            look.rfg, look.rbg, look.ralpha = self.resolved(look)
        self.cur_x, self.cur_y, self.cur_visible, self.cur_shape = snap.cursor
        self.block_cursor = bool(self.cur_visible) and self.cur_shape == "block"
        self.cursor_box = None            # (first cell, cells) of a block cursor, on its row
        if self.block_cursor and 0 <= self.cur_y < self.rows and 0 <= self.cur_x < self.cols:
            width = snap.cells[self.cur_y][self.cur_x][2]
            first, count = self.cur_x, 1
            if width == 0 and self.cur_x > 0:          # the tail of a wide character: its head
                first, count = self.cur_x - 1, 2
            elif width == 2:
                count = 2
            self.cursor_box = (first, min(count, self.cols - first))
        self.flags = {}

    def origin(self, x, y):
        return self.m.pad + x * self.m.cw, self.m.pad + y * self.m.ch

    def in_cursor(self, x, y):
        """True for a cell under a block cursor (both cells of a wide character)."""
        box = self.cursor_box
        return box is not None and y == self.cur_y and box[0] <= x < box[0] + box[1]

    def ink(self, x, y, look, underline=False):
        """(colour, alpha) of a cell's text, underline or strikethrough: the cursor text colour in a
        block cursor's cell, else the style's own."""
        if self.in_cursor(x, y):
            return self.cursor_text_rgb, 1.0
        return ((look.ul or look.rfg) if underline else look.rfg), look.ralpha

    def resolved(self, look):
        """fg, bg and alpha of a cell style (the reference renderer resolve, without the cursor)."""
        fg = look.fg or self.fg
        bg = look.bg
        if look.r:
            fg, bg = (bg or self.bg), fg
        return fg, bg, (self.faint if look.d else 1.0)

    def cov_adv(self, style, cp):
        key = (style, cp)
        got = self.flags.get(key)
        if got is None:
            primary = _fonts.primary(style)
            adv = primary.advance(cp)
            got = (adv is not None, adv)
            self.flags[key] = got
        return got


def _box_lines(frame, X, Y, spec, rgb, alpha):
    """Box drawing lines (the reference renderer's linesChar): the arms of a cell, light, heavy
    or double."""
    m = frame.m
    up, down, left, right = spec
    cw, ch = m.cw, m.ch
    lp = m.boxTh
    hp = m.boxTh * 2
    hlt = math.floor((ch - lp) / 2)
    hlb = hlt + lp
    hht = math.floor((ch - hp) / 2)
    hhb = hht + hp
    hdt = hlt - lp
    hdb = hlb + lp
    vll = math.floor((cw - lp) / 2)
    vlr = vll + lp
    vhl = math.floor((cw - hp) / 2)
    vhr = vhl + hp
    vdl = vll - lp
    vdr = vlr + lp
    up_bottom = hhb if (left == "h" or right == "h") else (
        (hdb if (left == "d" or right == "d") else hlb) if (left != right or down == up) else (
            hlb if (left == "n" and right == "n") else hlt))
    down_top = hht if (left == "h" or right == "h") else (
        (hdt if (left == "d" or right == "d") else hlt) if (left != right or up == down) else (
            hlt if (left == "n" and right == "n") else hlb))
    left_right = vhr if (up == "h" or down == "h") else (
        (vdr if (up == "d" or down == "d") else vlr) if (up != down or left == right) else (
            vlr if (up == "n" and down == "n") else vll))
    right_left = vhl if (up == "h" or down == "h") else (
        (vdl if (up == "d" or down == "d") else vll) if (up != down or right == left) else (
            vll if (up == "n" and down == "n") else vlr))

    def box(x0, y0, x1, y1):
        if x1 > x0 and y1 > y0:
            _fill_int(frame.canvas, X + x0, Y + y0, x1 - x0, y1 - y0, rgb, alpha)

    if up == "l":
        box(vll, 0, vlr, up_bottom)
    if up == "h":
        box(vhl, 0, vhr, up_bottom)
    if up == "d":
        box(vdl, 0, vll, hlt if left == "d" else up_bottom)
        box(vlr, 0, vdr, hlt if right == "d" else up_bottom)
    if right == "l":
        box(right_left, hlt, cw, hlb)
    if right == "h":
        box(right_left, hht, cw, hhb)
    if right == "d":
        box(right_left if up != "d" else vlr, hdt, cw, hlt)
        box(right_left if down != "d" else vlr, hlb, cw, hdb)
    if down == "l":
        box(vll, down_top, vlr, ch)
    if down == "h":
        box(vhl, down_top, vhr, ch)
    if down == "d":
        box(vdl, hlb if left == "d" else down_top, vll, ch)
        box(vlr, hlb if right == "d" else down_top, vdr, ch)
    if left == "l":
        box(0, hlt, left_right, hlb)
    if left == "h":
        box(0, hht, left_right, hhb)
    if left == "d":
        box(0, hdt, vll if up == "d" else left_right, hlt)
        box(0, hlb, vll if down == "d" else left_right, hdb)


def _arc(frame, X, Y, corner, rgb, alpha):
    """A rounded corner (the reference renderer's arc): a butt-capped stroke of the box line
    width."""
    m = frame.m
    t = m.boxTh
    fw, fh = m.cw, m.ch
    cx = math.floor((m.cw - t) / 2) + t / 2
    cy = math.floor((m.ch - t) / 2) + t / 2
    r = min(fw, fh) / 2
    s = 0.25
    dy = 1 if corner[0] == "b" else -1
    dx = 1 if corner[1] == "r" else -1
    pts = [(X + cx, Y + (fh if dy > 0 else 0)), (X + cx, Y + cy + dy * r)]
    pts += _bezier((X + cx, Y + cy + dy * r), (X + cx, Y + cy + dy * s * r),
                   (X + cx + dx * s * r, Y + cy), (X + cx + dx * r, Y + cy))
    pts.append((X + (fw if dx > 0 else 0), Y + cy))
    _stroke(frame.canvas, pts, t, rgb, alpha)


def _block(frame, X, Y, spec, rgb, alpha):
    """A block element (the reference renderer's block): aligned to its edge, rounded half up."""
    m = frame.m
    align, w, h, shade = spec
    bw = _zr(m.cw * w)
    bh = _zr(m.ch * h)
    if "right" in align:
        x = m.cw - bw
    elif "left" in align:
        x = 0
    else:
        x = math.floor((m.cw - bw) / 2)
    if "top" in align:
        y = 0
    elif "bottom" in align:
        y = m.ch - bh
    else:
        y = math.floor((m.ch - bh) / 2)
    _fill_int(frame.canvas, X + x, Y + y, bw, bh, rgb, alpha * shade)


def _sprite(frame, cp, X, Y, rgb, alpha):
    """Draws the box, arc, block or quadrant sprite of cp; False when cp has none."""
    m = frame.m
    spec = _BOX.get(cp)
    if spec is not None:
        _box_lines(frame, X, Y, spec, rgb, alpha)
        return True
    corner = _ARC.get(cp)
    if corner is not None:
        _arc(frame, X, Y, corner, rgb, alpha)
        return True
    block = _BLOCK.get(cp)
    if block is not None:
        _block(frame, X, Y, block, rgb, alpha)
        return True
    quad = _QUADRANTS.get(cp)
    if quad is not None:
        hw = _zr(m.cw / 2)
        hh = _zr(m.ch / 2)
        for k in quad.split(" "):
            x0 = X + (hw if k[1] == "r" else 0)
            y0 = Y + (hh if k[0] == "b" else 0)
            w = m.cw - hw if k[1] == "r" else hw
            h = m.ch - hh if k[0] == "b" else hh
            _fill_int(frame.canvas, x0, y0, w, h, rgb, alpha)
        return True
    return False


def _underline(frame, x, y, kind, rgb, alpha):
    """An underline of the given kind across the cell (the reference renderer's underline)."""
    m = frame.m
    X, Y = frame.origin(x, y)
    cw, ulh, ulp = m.cw, m.ulTh, m.ulPos
    if kind == "single":
        _fill_int(frame.canvas, X, Y + ulp, cw, ulh, rgb, alpha)
    elif kind == "double":
        _fill_int(frame.canvas, X, Y + ulp - ulh, cw, ulh, rgb, alpha)
        _fill_int(frame.canvas, X, Y + ulp + ulh, cw, ulh, rgb, alpha)
    elif kind == "curly":
        amp = cw / math.pi
        top = min(ulp, m.ch + math.floor(m.ch / 4) - amp - ulh)
        bot = top + amp
        r = 0.4
        c = 0.5 * cw
        pts = [(X, Y + bot)]
        pts += _bezier((X, Y + bot), (X + c * r, Y + bot), (X + c - c * r, Y + top),
                       (X + c, Y + top))
        pts += _bezier((X + c, Y + top), (X + c + c * r, Y + top), (X + cw - c * r, Y + bot),
                       (X + cw, Y + bot))
        _stroke(frame.canvas, pts, ulh, rgb, alpha, round_caps=True)
    elif kind == "dotted":
        n = max(1, _zr(cw / (2 * ulh)))
        for i in range(n):
            _fill_frac(frame.canvas, X + i * (cw / n), Y + ulp, ulh, ulh, rgb, alpha)
    elif kind == "dashed":
        _fill_int(frame.canvas, X, Y + ulp, _zr(cw / 2), ulh, rgb, alpha)


def _glyph_at(frame, glyph, X, Y, rgb, alpha):
    """A glyph mask with its origin (left, baseline) at (X, Y); a colour glyph keeps its colours."""
    if glyph is None:
        return
    if glyph.rgb is not None:
        _blend_mask(frame.canvas, glyph.alpha, X + glyph.ox, Y + glyph.oy, glyph.rgb, alpha)
    else:
        _blend_mask(frame.canvas, glyph.alpha, X + glyph.ox, Y + glyph.oy, _vec(rgb), alpha)


def _resize(array, size):
    """A float32 array resized to size (width, height) with Lanczos, one channel or three."""
    if array.ndim == 2:
        img = Image.fromarray(np.ascontiguousarray(array, dtype=np.float32))
        return np.asarray(img.resize(size, Image.Resampling.LANCZOS), dtype=np.float32)
    return np.stack([_resize(array[..., k], size) for k in range(array.shape[2])], axis=-1)


def _symbol_glyph(frame, face, text, X, Y, cwn, rgb, alpha):
    """A symbol class glyph fitted to its cells (the reference renderer, Ghostty's constraint with
    size fit): the ink box is scaled by f = min(1, cells * face width / ink width, face height / ink
    height) and placed about its centre inside the face's box; the scaled mask is resampled."""
    glyph = _fonts.glyph(face, text)
    if glyph is None:
        return
    m = frame.m
    h, w = glyph.alpha.shape[0], glyph.alpha.shape[1]
    gw = float(w)
    gh = float(h)
    gx = float(glyph.ox)
    gy = m.cellBase - (glyph.oy + h)
    f = min(1.0, (cwn * m.faceW) / max(gw, 0.01), m.faceH / max(gh, 0.01))
    nw = gw * f
    nh = gh * f
    nx = gx + gw / 2 - nw / 2
    ny = gy + gh / 2 - nh / 2
    span = m.faceW + (cwn - 1) * m.cw
    nx = max(0.0, min(nx, span - nw))
    face_y = m.cellBase - m.faceBase
    end_y = face_y + m.faceH - nh
    ny = (face_y + end_y) / 2 if end_y < face_y else max(face_y, min(ny, end_y))
    nx += (m.cw - m.faceW) / 2
    tx = X + nx
    ty = Y + m.ch - ny
    if f >= 1.0:
        _glyph_at(frame, glyph, int(round(tx - gx)), int(round(ty - nh - glyph.oy)), rgb, alpha)
        return
    size = (max(1, _zr(nw)), max(1, _zr(nh)))
    # Lanczos rings: a coverage outside [0, 1] or a colour outside [0, 255] would paint a pixel
    # brighter than the text colour or darker than the background
    alpha_s = np.clip(_resize(glyph.alpha, size), 0.0, 1.0)
    rgb_s = np.clip(_resize(glyph.rgb, size), 0.0, 255.0) if glyph.rgb is not None else None
    scaled = _fonts.Glyph(alpha_s, 0, 0, rgb_s)
    _glyph_at(frame, scaled, _zr(tx), _zr(ty - nh), rgb, alpha)


def _cell_glyph(frame, x, y, text, width, look, rgb, alpha, row):
    """One cell's glyph drawn alone: a sprite for box drawing, else the face's glyph at the cell's
    origin, fitted to its cells when it is a symbol. A code point no face carries warns."""
    m = frame.m
    cp = ord(text[0])
    X, Y = frame.origin(x, y)
    if text != " " and 0x2500 <= cp <= 0x259F:
        if _sprite(frame, cp, X, Y, _vec(rgb), alpha):
            return
        frame.warn.append("no sprite for U+%04X; drew font glyph" % cp)
    face = _fonts.face_for(look.face, cp)
    if face is None:
        frame.warn.append("no glyph U+%04X" % cp)
        return
    if _is_symbol(cp):
        _symbol_glyph(frame, face, text, X, Y, _constraint_width(row, x, frame.cols, width, cp),
                      rgb, alpha)
    else:
        _glyph_at(frame, _fonts.glyph(face, text), X, Y + m.base, rgb, alpha)


def _glyph_pass(frame):
    """Step 7: the glyphs and sprites, row by row. Runs of runnable cells are shaped together and
    broken as the reference renderer breaks them: on any change of colour or alpha, at the f|l, f|i
    and s|t ligature pairs, at a placeholder, a hidden or wide cell, and at a block cursor."""
    m = frame.m
    cols = frame.cols
    for y in range(frame.rows):
        row = frame.snap.cells[y]
        run = None
        for x in range(cols):
            text, sid, width = row[x]
            if width == 0:
                if run is not None:
                    _flush_run(frame, run, y)
                    run = None
                continue
            if not text:
                text = " "
            look = frame.looks[sid]
            cp = ord(text[0]) if text else 0x20
            if look.inv or cp == PLACEHOLDER:
                if run is not None:
                    _flush_run(frame, run, y)
                    run = None
                continue
            fg, alpha = frame.ink(x, y, look)
            if frame.in_cursor(x, y):
                # a block cursor's glyph is its own draw, in the cursor text colour
                if run is not None:
                    _flush_run(frame, run, y)
                    run = None
                _cell_glyph(frame, x, y, text, width, look, fg, alpha, row)
                continue
            if text != " " and 0x2500 <= cp <= 0x259F:
                if run is not None:
                    _flush_run(frame, run, y)
                    run = None
                _cell_glyph(frame, x, y, text, width, look, fg, alpha, row)
                continue
            has_cov, adv = frame.cov_adv(look.face, cp) if text != " " else (True, ADVANCE)
            runnable = text == " " or (width == 1 and len(text) == 1 and has_cov and adv == ADVANCE)
            if not runnable:
                if run is not None:
                    _flush_run(frame, run, y)
                    run = None
                _cell_glyph(frame, x, y, text, width, look, fg, alpha, row)
                continue
            key = (look.key, fg, alpha)
            if run is not None:
                prev = run[1][-1]
                bad = (prev == "f" and text in ("l", "i")) or (prev == "s" and text == "t")
                if run[2] != key or bad:
                    _flush_run(frame, run, y)
                    run = None
            if run is None:
                run = (x, [], key, look.face, fg, alpha)
            run[1].append(text)
        if run is not None:
            _flush_run(frame, run, y)


def _flush_run(frame, run, y):
    """Draws a run as its words: Iosevka is monospace with no ligature across a space, so each word
    is shaped alone at its own cell (the glyph masks are cached per word)."""
    x0, chars, _key, style, fg, alpha = run
    face = _fonts.primary(style)
    m = frame.m
    X, Y = frame.origin(x0, y)
    base_y = Y + m.base
    n = len(chars)
    i = 0
    while i < n:
        if chars[i] == " ":
            i += 1
            continue
        j = i
        while j < n and chars[j] != " ":
            j += 1
        word = "".join(chars[i:j])
        _glyph_at(frame, _fonts.glyph(face, word), X + i * m.cw, base_y, fg, alpha)
        i = j


def _underlines(frame):
    """Step 6: the underlines and overlines, per cell, each spanning the cell's width (two cells for
    a wide character), in the underline colour or the text colour (the cursor text colour in a block
    cursor's cell). They are drawn before the glyphs, which show over them."""
    m = frame.m
    for y in range(frame.rows):
        row = frame.snap.cells[y]
        for x in range(frame.cols):
            text, sid, width = row[x]
            if width == 0:
                continue
            look = frame.looks[sid]
            if look.u:
                colour, alpha = frame.ink(x, y, look, underline=True)
                for k in range(width or 1):
                    _underline(frame, x + k, y, look.u, colour, alpha)
            if look.o:
                colour, alpha = frame.ink(x, y, look)
                X, Y = frame.origin(x, y)
                _fill_int(frame.canvas, X, Y, m.cw * (width or 1), m.ulTh, colour, alpha)


def _strikes(frame):
    """Step 8: the strikethroughs, over the glyphs."""
    m = frame.m
    for y in range(frame.rows):
        row = frame.snap.cells[y]
        for x in range(frame.cols):
            text, sid, width = row[x]
            if width == 0:
                continue
            look = frame.looks[sid]
            if not look.s:
                continue
            colour, alpha = frame.ink(x, y, look)
            X, Y = frame.origin(x, y)
            _fill_int(frame.canvas, X, Y + m.stPos, m.cw * (width or 1), m.stTh, colour, alpha)


def _backgrounds(frame):
    """Step 3: the cell backgrounds that are set (a block cursor is painted at step 5, the other
    shapes at step 9)."""
    m = frame.m
    for y in range(frame.rows):
        row = frame.snap.cells[y]
        for x in range(frame.cols):
            bg = frame.looks[row[x][1]].rbg
            if bg is None:
                continue
            X, Y = frame.origin(x, y)
            _fill_int(frame.canvas, X, Y, m.cw, m.ch, bg)


def _block_cursor(frame):
    """Step 5: the rectangle of a block cursor, in the cursor colour, over the cell backgrounds and
    the images under the text (Ghostty draws the block cursor first in its text pass). On a wide
    character, head or tail, it covers both cells (generic.zig addCursor)."""
    box = frame.cursor_box
    if box is None:
        return
    m = frame.m
    X, Y = frame.origin(box[0], frame.cur_y)
    _fill_int(frame.canvas, X, Y, m.cw * box[1], m.ch, frame.cursor_rgb)


def _cursor(frame):
    """Step 9: the cursor shapes painted over their cell: a bar, an underline (Ghostty's
    cursor_underline: Metrics.cursor_thickness, 1 px, at the underline position or the lowest row
    that keeps the line inside the sprite canvas, which extends a quarter of the cell height below
    the cell) and a hollow block. The block cursor is step 5."""
    if not frame.cur_visible:
        return
    m = frame.m
    X, Y = frame.origin(frame.cur_x, frame.cur_y)
    shape = frame.cur_shape
    if shape == "bar":
        _fill_int(frame.canvas, X - 1, Y, 1, m.ch, frame.cursor_rgb)
    elif shape == "underline":
        top = min(m.ulPos, m.ch + m.ch // 4 - m.ulTh)
        _fill_int(frame.canvas, X, Y + top, m.cw, 1, frame.cursor_rgb)
    elif shape == "block_hollow":
        c = frame.cursor_rgb
        _fill_int(frame.canvas, X, Y, m.cw, 1, c)
        _fill_int(frame.canvas, X, Y + m.ch - 1, m.cw, 1, c)
        _fill_int(frame.canvas, X, Y, 1, m.ch, c)
        _fill_int(frame.canvas, X + m.cw - 1, Y, 1, m.ch, c)


def _texture(view, linear):
    """The image as the renderer samples it: colour (float32 (h, w, 3), linear light unless linear
    is False) and straight alpha (float32 (h, w)). Cached per (image id, seq, linear): seq is the
    image's version stamp, so a retransmitted or edited image never reuses a stale texture."""
    key = (view.id, view.seq, bool(linear))
    got = _TEXTURES.get(key)
    if got is not None:
        return got
    arr = np.frombuffer(view.rgba, dtype=np.uint8).reshape(view.height, view.width, 4)
    if linear:
        rgb = _SRGB_TO_LINEAR[arr[..., :3]]
    else:
        rgb = arr[..., :3].astype(np.float32) / np.float32(255.0)
    alpha = arr[..., 3].astype(np.float32) / np.float32(255.0)
    got = (rgb, alpha)
    _TEXTURES[key] = got
    while len(_TEXTURES) > TEXTURE_CACHE:
        _TEXTURES.popitem(last=False)
    return got


def _srgb_to_linear(v):
    """The sRGB electro-optical transfer function, exact (v in [0, 1])."""
    return np.where(v <= 0.04045, v / 12.92, ((v + 0.055) / 1.055) ** 2.4)


def _linear_to_srgb(v):
    """The inverse transfer function (Ghostty's unlinearize), v in [0, 1]."""
    v = np.clip(v, 0.0, 1.0)
    return np.where(v <= 0.0031308, v * 12.92, 1.055 * np.power(v, 1 / 2.4) - 0.055)


_SRGB_TO_LINEAR = _srgb_to_linear(np.arange(256, dtype=np.float64) / 255.0).astype(np.float32)


def _draw_image(frame, draw, view, linear):
    """Composite one placement: the destination rectangle, sampled at each destination pixel centre
    (u = sx + (i + 0.5) * sw / dw, the same for v), clipped to the canvas, then unlinearized,
    premultiplied and composited over the canvas."""
    m = frame.m
    x0 = m.pad + draw.col * m.cw + draw.offset_x
    y0 = m.pad + draw.row * m.ch + draw.offset_y
    dw, dh = draw.dest
    if dw <= 0 or dh <= 0:
        return
    cx0, cx1 = max(0, x0), min(frame.W, x0 + dw)
    cy0, cy1 = max(0, y0), min(frame.H, y0 + dh)
    if cx0 >= cx1 or cy0 >= cy1:
        return
    rgb_tex, alpha_tex = _texture(view, linear)
    th, tw = alpha_tex.shape
    sx, sy, sw, sh = draw.src
    i = np.arange(cx0 - x0, cx1 - x0, dtype=np.float64)
    j = np.arange(cy0 - y0, cy1 - y0, dtype=np.float64)
    fu = sx + (i + 0.5) * sw / dw - 0.5
    fv = sy + (j + 0.5) * sh / dh - 0.5
    iu = np.floor(fu)
    iv = np.floor(fv)
    tu = (fu - iu).astype(np.float32)
    tv = (fv - iv).astype(np.float32)
    iu = iu.astype(np.int64)
    iv = iv.astype(np.int64)
    ux0 = np.clip(iu, 0, tw - 1)
    ux1 = np.clip(iu + 1, 0, tw - 1)
    vy0 = np.clip(iv, 0, th - 1)
    vy1 = np.clip(iv + 1, 0, th - 1)
    wv = tv[:, None]
    rows_rgb = rgb_tex[vy0] * (1 - wv)[..., None] + rgb_tex[vy1] * wv[..., None]
    rows_a = alpha_tex[vy0] * (1 - wv) + alpha_tex[vy1] * wv
    wu = tu[None, :]
    col_rgb = rows_rgb[:, ux0] * (1 - wu)[..., None] + rows_rgb[:, ux1] * wu[..., None]
    col_a = rows_a[:, ux0] * (1 - wu) + rows_a[:, ux1] * wu
    if linear:
        src = _linear_to_srgb(col_rgb) * np.float32(255.0)
    else:
        src = col_rgb * np.float32(255.0)
    a = col_a[..., None]
    region = frame.canvas[cy0:cy1, cx0:cx1]
    region[...] = src * a + region * (1 - a)


def _images(frame, layer, linear):
    """Composite the draws of one layer: 0 below the backgrounds, 1 between the backgrounds and the
    text, 2 above the text. Draws are already in z order (then image id)."""
    for draw in frame.snap.draws:
        if draw.z < LAYER_LIMIT:
            current = 0
        elif draw.z < 0:
            current = 1
        else:
            current = 2
        if current != layer:
            continue
        view = frame.snap.images.get(draw.image_id)
        if view is None:
            continue
        _draw_image(frame, draw, view, linear)


def save_png(pixels, path):
    """Write an (H, W, 3) uint8 canvas, such as render() returns, to a PNG file with Pillow."""
    Image.fromarray(pixels).save(path)


def render(snap, *, theme=DEFAULT_THEME, crop_rows=None, images=True, warn=None):
    """The pixels of a snapshot, (H, W, 3) uint8.

    theme: colours as in DEFAULT_THEME. crop_rows: (r0, r1) to return only those cell rows, as
    the reference renderer crops them. images: False skips every image layer (the same as the
    no_images fault). warn: a list that receives the warnings (a code point with no glyph, a sprite
    that is missing)."""
    if warn is None:
        warn = []
    frame = _Frame(snap, theme, warn)
    m = frame.m
    show_images = images and not _faults.active("no_images")
    linear = not _faults.active("no_linear")
    if show_images:
        _images(frame, 0, linear)
    _backgrounds(frame)
    if show_images:
        _images(frame, 1, linear)
    _block_cursor(frame)
    _underlines(frame)
    _glyph_pass(frame)
    _strikes(frame)
    _cursor(frame)
    if show_images:
        _images(frame, 2, linear)
    out = np.clip(np.rint(frame.canvas), 0, 255).astype(np.uint8)
    if crop_rows is not None:
        r0, r1 = crop_rows
        y0 = 0 if r0 == 0 else m.pad + r0 * m.ch
        y1 = frame.H if r1 >= frame.rows - 1 else m.pad + (r1 + 1) * m.ch + m.pad
        out = out[y0:y1]
    return out


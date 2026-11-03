"""Cell styles and the SGR parser, as Ghostty 1.3.1 has them.

A style is a tuple (fg, bg, ul, flags):

    fg, bg, ul   None (default), a palette index 0..255, or RGB_FLAG | 0xRRGGBB
    flags        F_* bits, and the underline style in bits UL_SHIFT..UL_SHIFT+2
                 (0 none, 1 single, 2 double, 3 curly, 4 dotted, 5 dashed)

The parser is a port of src/terminal/sgr.zig (Parser.next and parseDirectColor,
countColon, consumeUnknownColon): the parameters are the CSI values with the
separator set (a bit for each ':'), and a colon is only meaningful after 4, 38,
48 and 58. The attribute meanings follow Screen.setAttribute in
src/terminal/Screen.zig. A CSI parameter list is read the way Parser.zig and
stream.zig read it: values saturate at 65535, a separator stores the value
before it, and a final value is kept only when at least one digit was read.

``style_to_dict`` gives the keys of the reference capture parser (the one that
made the calibration images), so a capture of tmux and an emulator state compare
key by key.
"""
RGB_FLAG = 1 << 24
F_BOLD, F_FAINT, F_ITALIC, F_BLINK, F_INVERSE, F_INVISIBLE, F_STRIKE, F_OVERLINE = (
    1 << i for i in range(8))
UL_SHIFT = 8
UL_NAMES = ("", "single", "double", "curly", "dotted", "dashed")
MAX_PARAMS = 24          # Ghostty Parser.zig MAX_PARAMS
U16_MAX = 65535

DEFAULT_STYLE = (None, None, None, 0)


def csi_params(params):
    """The CSI parameter bytes as (values, colon_seps) the way Parser.zig and
    stream.zig build them. ``values`` is a list of ints, ``colon_seps`` a set of
    indexes whose following separator was ':'."""
    if b":" not in params:
        # the common case: digits and ';' only. A field before a ';' is its value
        # (an empty one is 0); the field after the last ';' counts only when it has
        # a digit. The same values as the byte loop below.
        if not params:
            return [], set()
        parts = params.split(b";")
        last = parts.pop()
        vals = [min(int(p), U16_MAX) if p else 0 for p in parts]
        if last:
            vals.append(min(int(last), U16_MAX))
        if len(vals) > MAX_PARAMS:
            del vals[MAX_PARAMS:]
        return vals, set()
    vals = []
    seps = set()
    acc = 0
    acc_digits = False
    for c in params:
        if c == 0x3B or c == 0x3A:           # ';' or ':'
            if len(vals) >= MAX_PARAMS:
                continue
            vals.append(acc)
            if c == 0x3A:
                seps.add(len(vals) - 1)
            acc = 0
            acc_digits = False
        else:
            acc = min(min(acc * 10, U16_MAX) + (c - 0x30), U16_MAX)
            acc_digits = True
    if acc_digits and len(vals) < MAX_PARAMS:
        vals.append(acc)
    return vals, seps


class _SgrParser:
    """sgr.zig Parser: yields attributes as tuples, see _attr_apply."""

    def __init__(self, vals, seps):
        self.params = vals
        self.seps = seps
        self.n = len(vals)
        self.idx = 0

    def count_colon(self):
        count = 0
        idx = self.idx
        while idx < self.n - 1 and idx in self.seps:
            count += 1
            idx += 1
        return count

    def consume_unknown_colon(self):
        self.idx += self.count_colon() + 1

    def direct_color(self, tag, colon, i):
        """parseDirectColor: an rgb attribute, or None (the caller returns unknown).
        p[i] is the 38, 48 or 58; self.idx is i + 1."""
        p = self.params
        if self.n - i < 5:
            return None
        if not colon:
            self.idx += 4
            return (tag, (p[i + 2] & 0xFF, p[i + 3] & 0xFF, p[i + 4] & 0xFF))
        count = self.count_colon()
        if count == 3:
            self.idx += 4
            return (tag, (p[i + 2] & 0xFF, p[i + 3] & 0xFF, p[i + 4] & 0xFF))
        if count == 4:
            self.idx += 5
            return (tag, (p[i + 3] & 0xFF, p[i + 4] & 0xFF, p[i + 5] & 0xFF))
        self.consume_unknown_colon()
        return None

    def next(self):
        """The next attribute tuple, or None when the list is done."""
        if self.idx >= self.n:
            first = self.idx == 0
            self.idx += 1
            return ("unset",) if first else None
        i = self.idx
        colon = i in self.seps
        self.idx += 1
        v = self.params[i]
        if colon and v not in (4, 38, 48, 58):
            while self.idx in self.seps:
                self.idx += 1
            self.idx += 1
            return ("unknown",)
        if v == 0:
            return ("unset",)
        if v == 1:
            return ("bold",)
        if v == 2:
            return ("faint",)
        if v == 3:
            return ("italic",)
        if v == 4:
            if colon:
                if self.n - i < 2:
                    return ("unknown",)
                if self.idx in self.seps:
                    self.consume_unknown_colon()
                    return ("unknown",)
                self.idx += 1
                sub = self.params[i + 1]
                return ("underline", sub if sub <= 5 else 1)
            return ("underline", 1)
        if v == 5 or v == 6:
            return ("blink",)
        if v == 7:
            return ("inverse",)
        if v == 8:
            return ("invisible",)
        if v == 9:
            return ("strike",)
        if v == 21:
            return ("underline", 2)
        if v == 22:
            return ("reset_bold",)
        if v == 23:
            return ("reset_italic",)
        if v == 24:
            return ("underline", 0)
        if v == 25:
            return ("reset_blink",)
        if v == 27:
            return ("reset_inverse",)
        if v == 28:
            return ("reset_invisible",)
        if v == 29:
            return ("reset_strike",)
        if 30 <= v <= 37:
            return ("fg_pal", v - 30)
        if v in (38, 48, 58):
            if self.n - i >= 2:
                sub = self.params[i + 1]
                if sub == 2:
                    tag = {38: "fg_rgb", 48: "bg_rgb", 58: "ul_rgb"}[v]
                    got = self.direct_color(tag, colon, i)
                    if got is not None:
                        return got
                elif sub == 5 and self.n - i >= 3:
                    self.idx += 2
                    tag = {38: "fg_pal", 48: "bg_pal", 58: "ul_pal"}[v]
                    return (tag, self.params[i + 2] & 0xFF)
            return ("unknown",)
        if v == 39:
            return ("reset_fg",)
        if 40 <= v <= 47:
            return ("bg_pal", v - 40)
        if v == 49:
            return ("reset_bg",)
        if v == 53:
            return ("overline",)
        if v == 55:
            return ("reset_overline",)
        if v == 59:
            return ("reset_ul",)
        if 90 <= v <= 97:
            return ("fg_pal", v - 82)
        if 100 <= v <= 107:
            return ("bg_pal", v - 92)
        return ("unknown",)


_ATTR_CACHE = {}


def sgr_attributes(params):
    """The attribute tuples of one SGR parameter list (bytes), cached."""
    got = _ATTR_CACHE.get(params)
    if got is not None:
        return got
    vals, seps = csi_params(params)
    parser = _SgrParser(vals, seps)
    out = []
    while True:
        attr = parser.next()
        if attr is None:
            break
        out.append(attr)
    got = tuple(out)
    if len(_ATTR_CACHE) < 4096:
        _ATTR_CACHE[params] = got
    return got


def _with_ul(flags, kind):
    return (flags & ~(7 << UL_SHIFT)) | (kind << UL_SHIFT)


def apply_attr(style, attr):
    """Screen.setAttribute: one attribute applied to a style tuple."""
    fg, bg, ul, flags = style
    kind = attr[0]
    if kind == "unset":
        return DEFAULT_STYLE
    if kind == "bold":
        flags |= F_BOLD
    elif kind == "reset_bold":
        flags &= ~(F_BOLD | F_FAINT)
    elif kind == "italic":
        flags |= F_ITALIC
    elif kind == "reset_italic":
        flags &= ~F_ITALIC
    elif kind == "faint":
        flags |= F_FAINT
    elif kind == "underline":
        flags = _with_ul(flags, attr[1])
    elif kind == "ul_rgb":
        ul = RGB_FLAG | (attr[1][0] << 16 | attr[1][1] << 8 | attr[1][2])
    elif kind == "ul_pal":
        ul = attr[1]
    elif kind == "reset_ul":
        ul = None
    elif kind == "overline":
        flags |= F_OVERLINE
    elif kind == "reset_overline":
        flags &= ~F_OVERLINE
    elif kind == "blink":
        flags |= F_BLINK
    elif kind == "reset_blink":
        flags &= ~F_BLINK
    elif kind == "inverse":
        flags |= F_INVERSE
    elif kind == "reset_inverse":
        flags &= ~F_INVERSE
    elif kind == "invisible":
        flags |= F_INVISIBLE
    elif kind == "reset_invisible":
        flags &= ~F_INVISIBLE
    elif kind == "strike":
        flags |= F_STRIKE
    elif kind == "reset_strike":
        flags &= ~F_STRIKE
    elif kind == "fg_rgb":
        fg = RGB_FLAG | (attr[1][0] << 16 | attr[1][1] << 8 | attr[1][2])
    elif kind == "bg_rgb":
        bg = RGB_FLAG | (attr[1][0] << 16 | attr[1][1] << 8 | attr[1][2])
    elif kind == "fg_pal":
        fg = attr[1]
    elif kind == "bg_pal":
        bg = attr[1]
    elif kind == "reset_fg":
        fg = None
    elif kind == "reset_bg":
        bg = None
    else:
        return style        # unknown: ignored, as Screen.setAttribute returns
    return (fg, bg, ul, flags)


def apply_sgr(style, params):
    """Apply one CSI m parameter list (bytes) to a style tuple."""
    for attr in sgr_attributes(params):
        style = apply_attr(style, attr)
    return style


def style_to_dict(style):
    """The capture parser's keys of a style: fg, bg, ul (colour), b, d, i, u (name),
    r (inverse), s (strike), o (overline), blink, inv (invisible). Only the keys
    that are set appear; a colour is a palette int or '#rrggbb'."""
    fg, bg, ul, flags = style
    out = {}
    if flags & F_BOLD:
        out["b"] = True
    if flags & F_FAINT:
        out["d"] = True
    if flags & F_ITALIC:
        out["i"] = True
    ul_kind = (flags >> UL_SHIFT) & 7
    if ul_kind:
        out["u"] = UL_NAMES[ul_kind] if ul_kind < len(UL_NAMES) else "single"
    if flags & F_INVERSE:
        out["r"] = True
    if flags & F_STRIKE:
        out["s"] = True
    if flags & F_OVERLINE:
        out["o"] = True
    if flags & F_BLINK:
        out["blink"] = True
    if flags & F_INVISIBLE:
        out["inv"] = True
    if fg is not None:
        out["fg"] = _colour_key(fg)
    if bg is not None:
        out["bg"] = _colour_key(bg)
    if ul is not None:
        out["ul"] = _colour_key(ul)
    return out


def _colour_key(value):
    if value & RGB_FLAG:
        return "#%06x" % (value & 0xFFFFFF)
    return value


class StyleTable:
    """Interned styles. Id 0 is the default style.

    A blank that carries only a background colour (Ghostty's Style.bgCell: a cell whose content
    is the colour, content tag bg_color_palette or bg_color_rgb) has an id of its own, listed in
    ``bg_cells``, even when a pen has the same style tuple: Cell.isEmpty counts such a blank as not
    empty, and a codepoint 0 cell with that pen's style as empty."""

    def __init__(self):
        self.styles = [DEFAULT_STYLE]
        self.ids = {DEFAULT_STYLE: 0}
        self.bg_cells = set()

    def intern(self, style):
        sid = self.ids.get(style)
        if sid is None:
            sid = len(self.styles)
            self.styles.append(style)
            self.ids[style] = sid
        return sid

    def intern_bg(self, bg):
        """The id of a background-only blank of colour bg (not None)."""
        key = ("bg", bg)
        sid = self.ids.get(key)
        if sid is None:
            sid = len(self.styles)
            self.styles.append((None, bg, None, 0))
            self.ids[key] = sid
            self.bg_cells.add(sid)
        return sid

    def get(self, sid):
        return self.styles[sid]

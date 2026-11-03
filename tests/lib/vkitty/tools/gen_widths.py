#!/usr/bin/env python3
"""Generate tests/lib/vkitty/widths_data.py (Ghostty 1.3.1) or widths_data_140.py (Ghostty 1.4.0)
from the uucode sources.

    python3 -I tests/lib/vkitty/tools/gen_widths.py --uucode UUCODE_DIR \
        --out tests/lib/vkitty/widths_data.py
    python3 -I tests/lib/vkitty/tools/gen_widths.py --profile ghostty-1.4.0 --uucode UUCODE_DIR \
        --out tests/lib/vkitty/widths_data_140.py

UUCODE_DIR is an unpacked uucode tree: for ghostty-1.3.1 the 0.2.0 release tarball whose sha256
is pinned below (Ghostty 1.3.1 pins it in build.zig.zon), for ghostty-1.4.0 the tarball of the
revision that Ghostty 1.4.0 pins (uucode ea62149, Unicode 18.0.0). The derivation of the four
fields is the same in both: the width extension of the 1.4.0 uucode (src/components.zig) is
the 0.2.0 wcwidth extension (src/x/config_x/wcwidth.zig) line for line. No network is used.
The output is deterministic: a second run writes the same bytes. Before anything is written,
the generator runs every line of ucd/auxiliary/GraphemeBreakTest.txt through the break
rules (the full rule with control classes, and the no-control rule that Ghostty uses), and
checks the emoji variation and grapheme derivation asserts of uucode's tables.zig. Any
failure exits 1 and leaves the output alone.

The derivation is a port of uucode's build, for the four fields Ghostty reads
(src/unicode/props_uucode.zig):

  Ucd.zig         UnicodeData general category (First/Last ranges, gaps Cn),
                  DerivedEastAsianWidth (@missing lines in file order, then the
                  entries), GraphemeBreakProperty (default Other),
                  DerivedCoreProperties (Default_Ignorable_Code_Point, InCB),
                  emoji-data.txt, emoji-variation-sequences.txt
  tables.zig      grapheme_break: emoji modifier, emoji modifier base,
                  extended pictographic, then the InCB rules over the original
                  property
  x/config_x/grapheme_break.zig   grapheme_break_no_control (control, cr, lf
                  become other)
  x/config_x/wcwidth.zig          wcwidth_standalone and wcwidth_zero_in_grapheme
  build/uucode_config.zig         Ghostty's width (0 for zero-in-grapheme code
                                  points that are not emoji modifiers or prepend,
                                  else min(2, standalone))

Code points above U+10FFFF are not in the tables: props() gives Ghostty's
fallback (width 1, zero in grapheme, other, not a VS base) for them.
"""
import argparse
import hashlib
import os
import re
import sys

sys.dont_write_bytecode = True   # a run of the harness writes no bytecode into the repository tree

_HERE = os.path.dirname(os.path.abspath(__file__))
_LIB = os.path.dirname(os.path.dirname(_HERE))
if _LIB not in sys.path:
    sys.path.insert(0, _LIB)

from vkitty import widths_rules as _rules131  # noqa: E402
from vkitty import widths_rules14 as _rules140  # noqa: E402

# the tarball of each profile: (sha256, what the header says it is, the Ghostty version)
_PINS = {
    "ghostty-1.3.1": ("d0abee0f4f8bd6eae3c051777e16e7c42d8964aaaa015591c4e565703f465f95",
                      "uucode 0.2.0 (release tarball", "1.3.1"),
    "ghostty-1.4.0": ("f37c4071a217853450d084cb9c12b6d4b68f887eb9cb42fe77a84f86056eacbf",
                      "uucode ea62149739404a73c202b48a33bf6dd2af4bd9b0 (tarball", "1.4.0"),
}
UUCODE_TARBALL_SHA256 = _PINS["ghostty-1.3.1"][0]
UUCODE_TARBALL_NAME = "uucode-0.2.0.tar.gz"
MAX_CP = 0x10FFFF
N = MAX_CP + 1

GC_NAMES = (
    "Lu", "Ll", "Lt", "Lm", "Lo", "Mn", "Mc", "Me", "Nd", "Nl", "No", "Pc", "Pd", "Ps",
    "Pe", "Pi", "Pf", "Po", "Sm", "Sc", "Sk", "So", "Zs", "Zl", "Zp", "Cc", "Cf", "Cs",
    "Co", "Cn",
)
GC_INDEX = {name: i for i, name in enumerate(GC_NAMES)}
CN = GC_INDEX["Cn"]

EAW_NAMES = ("neutral", "fullwidth", "halfwidth", "wide", "narrow", "ambiguous")
EAW_INDEX = {name: i for i, name in enumerate(EAW_NAMES)}
EAW_CODES = {"F": "fullwidth", "H": "halfwidth", "W": "wide", "Na": "narrow",
             "A": "ambiguous", "N": "neutral"}

# types.zig OriginalGraphemeBreak
OBG_NAMES = ("other", "prepend", "cr", "lf", "control", "extend", "regional_indicator",
             "spacing_mark", "l", "v", "t", "lv", "lvt", "zwj")
OBG_INDEX = {name: i for i, name in enumerate(OBG_NAMES)}

rules = _rules131


def _select_rules(module):
    """Point the module's class tables at the rules of a profile (widths_rules or
    widths_rules14), which differ in the Indic conjunct classes."""
    global rules, FULL, NC, FULL_INDEX, NC_INDEX, FULL_TO_NC
    rules = module
    FULL = rules.FULL_CLASSES
    NC = rules.NC_CLASSES
    FULL_INDEX = {name: i for i, name in enumerate(FULL)}
    NC_INDEX = {name: i for i, name in enumerate(NC)}
    FULL_TO_NC = tuple(NC_INDEX["other" if name in ("control", "cr", "lf") else name]
                       for name in FULL)


_select_rules(_rules131)
FULL = rules.FULL_CLASSES
NC = rules.NC_CLASSES
FULL_INDEX = {name: i for i, name in enumerate(FULL)}
NC_INDEX = {name: i for i, name in enumerate(NC)}
# GraphemeBreak index -> GraphemeBreakNoControl index (control, cr and lf become other)
FULL_TO_NC = tuple(NC_INDEX["other" if name in ("control", "cr", "lf") else name] for name in FULL)

# types.x.zig and tables.zig: InCB values
INCB_NONE, INCB_LINKER, INCB_CONSONANT, INCB_EXTEND = 0, 1, 2, 3
INCB_CODES = {"Linker": INCB_LINKER, "Consonant": INCB_CONSONANT, "Extend": INCB_EXTEND}

ZWNJ = 0x200C
ZWJ = 0x200D

# Expected widths for the spot check (the same values the spec checks).
SPOT = (
    (0x61, 1), (0x4E16, 2), (0x0305, 0), (0x10EEEE, 1), (0x1F600, 2), (0x200D, 0),
    (0xFE0F, 0), (0x00AD, 1), (0x2500, 1), (0x2713, 1), (0x3000, 2), (0x1F1E6, 2),
    (0x1F3FB, 2), (0x0600, 1), (0x0903, 1), (0x1160, 0), (0x11A8, 0), (0x20E3, 0),
    (0x2E3B, 2), (0x00E9, 1),
)


class GenError(Exception):
    pass


def fail(msg):
    raise GenError(msg)


def ucd_path(root, rel):
    path = os.path.join(root, rel)
    if not os.path.isfile(path):
        fail("missing UCD file: %s" % rel)
    return path


def read_lines(root, rel):
    with open(ucd_path(root, rel), encoding="utf-8") as handle:
        return handle.read().split("\n")


def strip_comment(line):
    """uucode's trim(): drop everything from the first '#', then surrounding blanks."""
    return line.split("#", 1)[0].strip(" \t\r")


def parse_range(text):
    text = text.strip()
    if ".." in text:
        lo, hi = text.split("..", 1)
        return int(lo, 16), int(hi, 16)
    cp = int(text, 16)
    return cp, cp


def set_range(arr, lo, hi, value):
    arr[lo:hi + 1] = bytes([value]) * (hi - lo + 1)


def read_unicode_version(root):
    for line in read_lines(root, "ucd/extracted/DerivedEastAsianWidth.txt"):
        match = re.search(r"DerivedEastAsianWidth-(\d+\.\d+\.\d+)\.txt", line)
        if match:
            return match.group(1)
    fail("no Unicode version in DerivedEastAsianWidth.txt")


def read_general_category(root):
    gc = bytearray(bytes([CN]) * N)
    start = None
    for line in read_lines(root, "ucd/UnicodeData.txt"):
        if not line.strip():
            continue
        fields = line.split(";")
        cp = int(fields[0], 16)
        name = fields[1]
        cat = GC_INDEX[fields[2]]
        if name.endswith("First>"):
            start = cp
            gc[cp] = cat
        elif name.endswith("Last>"):
            if start is None:
                fail("Last range without First at U+%04X" % cp)
            set_range(gc, start, cp, cat)
            start = None
        else:
            gc[cp] = cat
    return gc


def read_east_asian_width(root):
    eaw = bytearray(bytes([EAW_INDEX["neutral"]]) * N)
    for raw in read_lines(root, "ucd/extracted/DerivedEastAsianWidth.txt"):
        text = raw.strip(" \t\r")
        if not text:
            continue
        if text.startswith("# @missing:"):
            body = text[len("# @missing:"):]
            cp_text, width = [part.strip() for part in body.split(";")[:2]]
            lo, hi = parse_range(cp_text)
            if width == "Neutral":
                continue
            if width != "Wide":
                fail("unknown @missing EastAsianWidth value %s" % width)
            set_range(eaw, lo, hi, EAW_INDEX["wide"])
            continue
        data = strip_comment(text)
        if not data:
            continue
        cp_text, width = [part.strip() for part in data.split(";")[:2]]
        if width not in EAW_CODES:
            fail("unknown EastAsianWidth value %s" % width)
        lo, hi = parse_range(cp_text)
        set_range(eaw, lo, hi, EAW_INDEX[EAW_CODES[width]])
    return eaw


def read_original_grapheme_break(root):
    obg = bytearray(N)
    for line in read_lines(root, "ucd/auxiliary/GraphemeBreakProperty.txt"):
        data = strip_comment(line)
        if not data:
            continue
        cp_text, prop = [part.strip() for part in data.split(";")[:2]]
        mapping = {"Prepend": "prepend", "CR": "cr", "LF": "lf", "Control": "control",
                   "Extend": "extend", "Regional_Indicator": "regional_indicator",
                   "SpacingMark": "spacing_mark", "L": "l", "V": "v", "T": "t", "LV": "lv",
                   "LVT": "lvt", "ZWJ": "zwj"}
        set_range(obg, *parse_range(cp_text), OBG_INDEX[mapping.get(prop, "other")])
    return obg


def read_derived_core(root):
    ignorable = bytearray(N)
    incb = bytearray(N)
    for line in read_lines(root, "ucd/DerivedCoreProperties.txt"):
        data = strip_comment(line)
        if not data:
            continue
        parts = [part.strip() for part in data.split(";")]
        lo, hi = parse_range(parts[0])
        if parts[1] == "Default_Ignorable_Code_Point":
            set_range(ignorable, lo, hi, 1)
        elif parts[1] == "InCB":
            value = parts[2] if len(parts) > 2 else ""
            if value not in INCB_CODES:
                fail("unknown InCB value %s" % value)
            set_range(incb, lo, hi, INCB_CODES[value])
    return ignorable, incb


def read_emoji_data(root):
    flags = {name: bytearray(N) for name in ("modifier", "modifier_base", "component", "pict")}
    names = {"Emoji_Modifier": "modifier", "Emoji_Modifier_Base": "modifier_base",
             "Emoji_Component": "component", "Extended_Pictographic": "pict"}
    for line in read_lines(root, "ucd/emoji/emoji-data.txt"):
        data = strip_comment(line)
        if not data:
            continue
        cp_text, prop = [part.strip() for part in data.split(";")[:2]]
        if prop in names:
            set_range(flags[names[prop]], *parse_range(cp_text), 1)
    return flags


def read_emoji_vs(root):
    text_base = bytearray(N)   # U+FE0E sequences (VS15): is_emoji_vs_base
    emoji_base = bytearray(N)  # U+FE0F sequences (VS16)
    for line in read_lines(root, "ucd/emoji/emoji-variation-sequences.txt"):
        data = strip_comment(line).split()
        if not data:
            continue
        cp = int(data[0], 16)
        vs = int(data[1], 16)
        if vs == 0xFE0E:
            text_base[cp] = 1
        elif vs == 0xFE0F:
            emoji_base[cp] = 1
        else:
            fail("unknown emoji variation selector %04X" % vs)
    if text_base != emoji_base:
        fail("emoji variation sequences: VS15 and VS16 bases differ (tables.zig asserts they "
             "match)")
    return text_base


def derive_grapheme_break(obg, incb, flags):
    """tables.zig: the GraphemeBreak class of every code point, then the no-control
    class (x/config_x/grapheme_break.zig). Returns (full, no_control) bytearrays."""
    to_full = bytearray([255] * 256)
    for name in OBG_NAMES:
        if name not in ("extend",):
            to_full[OBG_INDEX[name]] = FULL_INDEX[name]
    gb = bytearray(obg.translate(bytes(to_full)))
    emod, embase = flags["modifier"], flags["modifier_base"]
    ecomp, epict = flags["component"], flags["pict"]
    o_extend = OBG_INDEX["extend"]
    o_other = OBG_INDEX["other"]
    o_zwj = OBG_INDEX["zwj"]
    c_emod = FULL_INDEX["emoji_modifier"]
    c_embase = FULL_INDEX["emoji_modifier_base"]
    c_pict = FULL_INDEX["extended_pictographic"]
    c_icb_ext = FULL_INDEX["indic_conjunct_break_extend"]
    new_rules = "indic_conjunct_break_linker_other" in FULL_INDEX
    c_icb_link = FULL_INDEX["indic_conjunct_break_linker_extend" if new_rules
                            else "indic_conjunct_break_linker"]
    c_icb_link_other = FULL_INDEX.get("indic_conjunct_break_linker_other")
    c_icb_cons = FULL_INDEX["indic_conjunct_break_consonant"]
    c_zwnj = FULL_INDEX["zwnj"]
    c_zwj = FULL_INDEX["zwj"]
    for cp in range(N):
        if emod[cp]:
            if obg[cp] != o_extend or epict[cp] or not ecomp[cp]:
                fail("emoji modifier U+%04X breaks tables.zig's asserts" % cp)
            gb[cp] = c_emod
        elif embase[cp]:
            if obg[cp] != o_other or not epict[cp]:
                fail("emoji modifier base U+%04X breaks tables.zig's asserts" % cp)
            gb[cp] = c_embase
        elif epict[cp]:
            if obg[cp] != o_other:
                fail("extended pictographic U+%04X breaks tables.zig's asserts" % cp)
            gb[cp] = c_pict
        else:
            value = incb[cp]
            if value == INCB_NONE:
                if obg[cp] == o_extend:
                    if cp != ZWNJ:
                        fail("extend U+%04X without an InCB value (not ZWNJ)" % cp)
                    gb[cp] = c_zwnj
            elif value == INCB_EXTEND:
                if cp == ZWJ:
                    if obg[cp] != o_zwj:
                        fail("ZWJ original class mismatch")
                    gb[cp] = c_zwj
                else:
                    if obg[cp] != o_extend:
                        fail("InCB extend U+%04X is not Extend" % cp)
                    gb[cp] = c_icb_ext
            elif value == INCB_LINKER:
                if obg[cp] == o_other and c_icb_link_other is not None:
                    gb[cp] = c_icb_link_other      # Unicode 18: a linker that is not Extend
                elif obg[cp] != o_extend:
                    fail("InCB linker U+%04X is not Extend" % cp)
                else:
                    gb[cp] = c_icb_link
            else:
                if obg[cp] != o_other:
                    fail("InCB consonant U+%04X is not Other" % cp)
                gb[cp] = c_icb_cons
    if 255 in gb:
        fail("unmapped grapheme break class")
    nc = bytearray(gb.translate(bytes(FULL_TO_NC) + bytes(256 - len(FULL_TO_NC))))
    return gb, nc


def derive_width(gc, eaw, gb, ignorable, flags):
    """wcwidth.zig (wcwidth_standalone, wcwidth_zero_in_grapheme) and
    uucode_config.zig (Ghostty's width). Returns (width, zero_in_grapheme)."""
    width_out = bytearray(N)
    zig_out = bytearray(N)
    emod = flags["modifier"]
    cat_zero = {GC_INDEX["Cc"], GC_INDEX["Cs"], GC_INDEX["Zl"], GC_INDEX["Zp"]}
    cat_mark = {GC_INDEX["Mn"], GC_INDEX["Me"]}
    wide_set = {EAW_INDEX["wide"], EAW_INDEX["fullwidth"]}
    gb_ri = FULL_INDEX["regional_indicator"]
    gb_zero_set = {FULL_INDEX["v"], FULL_INDEX["t"], FULL_INDEX["prepend"]}
    nc_prepend = NC_INDEX["prepend"]
    for cp in range(N):
        cat = gc[cp]
        if cat in cat_zero:
            local = 0
        elif cp == 0xAD:
            local = 1
        elif ignorable[cp]:
            local = 0
        elif cp == 0x2E3A:
            local = 2
        elif cp == 0x2E3B:
            local = 3
        elif eaw[cp] in wide_set:
            local = 2
        elif gb[cp] == gb_ri:
            local = 2
        else:
            local = 1
        standalone = 2 if cp == 0x20E3 else local
        is_emod = emod[cp]
        zig = local == 0 or bool(is_emod) or cat in cat_mark or gb[cp] in gb_zero_set
        if zig and not is_emod and FULL_TO_NC[gb[cp]] != nc_prepend:
            width = 0
        else:
            width = min(2, standalone)
        width_out[cp] = width
        zig_out[cp] = 1 if zig else 0
    return width_out, zig_out


def ranges_of(arr, skip):
    """Maximal runs of equal values other than `skip`: (start, end, value)."""
    out = []
    start = None
    value = None
    for cp, v in enumerate(arr):
        if v == skip:
            if start is not None:
                out.append((start, cp - 1, value))
                start = None
            continue
        if start is not None and v == value:
            continue
        if start is not None:
            out.append((start, cp - 1, value))
        start = cp
        value = v
    if start is not None:
        out.append((start, N - 1, value))
    return out


def flag_ranges(arr):
    """Runs of true (nonzero) values as (start, end)."""
    return [(lo, hi) for lo, hi, _v in ranges_of(arr, 0)]


# ----------------------------------------------------------- self-check ---

def load_break_test(root):
    """Each line is: break cp (break cp)* break. Returns (line, cps, expects) where
    expects[k] is True for a break between cps[k] and cps[k + 1]."""
    cases = []
    for number, raw in enumerate(read_lines(root, "ucd/auxiliary/GraphemeBreakTest.txt"), 1):
        text = strip_comment(raw)
        if not text:
            continue
        parts = text.split()
        if parts[0] != "\u00f7" or parts[-1] != "\u00f7":
            fail("GraphemeBreakTest line %d does not start and end with a break" % number)
        tokens = parts[1:]
        cps = [int(tok, 16) for tok in tokens[0::2]]
        seps = tokens[1::2]
        if len(seps) != len(cps) or seps[-1] != "\u00f7" or len(cps) < 2:
            fail("GraphemeBreakTest line %d is malformed" % number)
        expects = [sep == "\u00f7" for sep in seps[:-1]]
        cases.append((number, cps, expects))
    return cases


def self_check(root, full_gb, nc_gb, version):
    """Run every GraphemeBreakTest line through the rule, as uucode's own test does
    (the full rule on all lines, the no-control rule on lines without controls),
    with uucode's emoji modifier divergence. Returns a summary line."""
    cases = load_break_test(root)
    full_pairs = 0
    nc_pairs = 0
    nc_lines = 0
    for number, cps, expects in cases:
        # full rule
        state = "default"
        for k in range(len(cps) - 1):
            cp1, cp2 = cps[k], cps[k + 1]
            gb1 = FULL[full_gb[cp1]]
            gb2 = FULL[full_gb[cp2]]
            expected = expects[k]
            if gb2 == "emoji_modifier" and gb1 != "emoji_modifier_base":
                if expected:
                    fail("line %d: file says break before an emoji modifier after %s"
                         % (number, gb1))
                expected = True
            actual, state = rules.compute_grapheme_break(gb1, gb2, state)
            full_pairs += 1
            if actual != expected:
                fail("line %d: U+%04X U+%04X full rule says %s, file says %s"
                     % (number, cp1, cp2, actual, expected))
        # no-control rule: skip lines with a control class (uucode's test does)
        if any(FULL[full_gb[cp]] in ("control", "cr", "lf") for cp in cps):
            continue
        nc_lines += 1
        state = "default"
        for k in range(len(cps) - 1):
            cp1, cp2 = cps[k], cps[k + 1]
            gb1 = NC[nc_gb[cp1]]
            gb2 = NC[nc_gb[cp2]]
            expected = expects[k]
            if gb2 == "emoji_modifier" and gb1 != "emoji_modifier_base":
                if expected:
                    fail("line %d: file says break before an emoji modifier (no-control)" % number)
                expected = True
            actual, state = rules.compute_grapheme_break(gb1, gb2, state)
            nc_pairs += 1
            if actual != expected:
                fail("line %d: U+%04X U+%04X no-control rule says %s, file says %s"
                     % (number, cp1, cp2, actual, expected))
    return ("GraphemeBreakTest.txt (%s): %d lines, %d pairs with the full rule, "
            "%d lines and %d pairs with the no-control rule"
            % (version, len(cases), full_pairs, nc_lines, nc_pairs))


def spot_check(width_out):
    for cp, want in SPOT:
        if width_out[cp] != want:
            fail("spot check U+%04X: width %d, want %d" % (cp, width_out[cp], want))
    return "%d spot-check widths match" % len(SPOT)


# ------------------------------------------------------------- output ---

def write_output(path, root, version, gb_names_nc, width_rows, zig_rows, gb_rows, vs_rows, summary):
    header = """# Generated by tests/lib/vkitty/tools/gen_widths.py. Do not edit by hand.
#
# Source: %(source)s sha256
#   %(sha)s),
# Unicode %(version)s, derived the way Ghostty %(ghostty)s derives it
# (src/build/uucode_config.zig, src/unicode/props_uucode.zig). Regenerate with:
#
#   %(command)s
#
# UUCODE_DIR is an unpacked uucode tree of the source above. Self-check at generation time:
%(summary)s
#
# Tables are sorted, disjoint, inclusive (start, end[, value]) ranges. A code
# point outside every range has width 1, is not zero in grapheme, is class
# other and is not a VS base.

UNICODE_VERSION = "%(version)s"
UUCODE_TARBALL_SHA256 = "%(sha)s"

# GraphemeBreakNoControl, in uucode's enum order (the index used by GB)
GB_NAMES = (
%(gbnames)s)

# Ghostty width, only the values other than 1: (start, end, width); the width is
# 0 or 2 (min(2, standalone) caps the 3 of U+2E3B at 2)
WIDTH = (
%(width)s)

# wcwidth_zero_in_grapheme (uucode): (start, end)
ZERO_IN_GRAPHEME = (
%(zig)s)

# grapheme_break_no_control: (start, end, class index), class other omitted
GB = (
%(gb)s)

# is_emoji_vs_base (an emoji text variation sequence exists): (start, end)
VS_BASE = (
%(vs)s)
"""
    sha = UUCODE_TARBALL_SHA256
    source, ghostty = _PINS[PROFILE[0]][1], _PINS[PROFILE[0]][2]

    def fmt_rows(rows, two=False):
        out = []
        for row in rows:
            if two:
                out.append("    (0x%04X, 0x%04X)," % row)
            elif len(row) == 3 and isinstance(row[2], str):
                out.append("    (0x%04X, 0x%04X, %r)," % (row[0], row[1], row[2]))
            else:
                out.append("    (0x%04X, 0x%04X, %d)," % row)
        return "\n".join(out) + ("\n" if out else "")

    command = ("python3 -I tests/lib/vkitty/tools/gen_widths.py%s --uucode UUCODE_DIR "
               "--out tests/lib/vkitty/%s"
               % ("" if PROFILE[0] == "ghostty-1.3.1" else " --profile " + PROFILE[0],
                  os.path.basename(path)))
    body = header % {
        "source": source,
        "ghostty": ghostty,
        "command": command,
        "sha": sha,
        "version": version,
        "summary": "\n".join("#   " + part for part in summary.split("; ")),
        "gbnames": "".join('    "%s",\n' % name for name in gb_names_nc),
        "width": fmt_rows(width_rows),
        "zig": fmt_rows(zig_rows, two=True),
        "gb": fmt_rows(gb_rows),
        "vs": fmt_rows(vs_rows, two=True),
    }
    tmp_path = path + ".tmp-gen"
    with open(tmp_path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(body)
    os.replace(tmp_path, path)


def verify_tarball(root):
    """The release tarball sits next to the unpacked tree (DIR.tar.gz). When it is
    there, its sha256 must be the pinned one; when it is not, the pinned value is
    recorded and the check is skipped."""
    tarball = root + ".tar.gz"
    if not os.path.isfile(tarball):
        return "tarball not found beside the tree; sha256 recorded from the pin"
    digest = hashlib.sha256()
    with open(tarball, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    if digest.hexdigest() != UUCODE_TARBALL_SHA256:
        fail("tarball sha256 %s does not match the pin %s"
             % (digest.hexdigest(), UUCODE_TARBALL_SHA256))
    return "tarball sha256 verified"


def generate(root, out, verbose=True):
    tarball_note = verify_tarball(root)
    version = read_unicode_version(root)
    say = (lambda msg: print(msg)) if verbose else (lambda msg: None)
    say("reading uucode %s from the UCD files (Unicode %s; %s)" % (root, version, tarball_note))
    gc = read_general_category(root)
    eaw = read_east_asian_width(root)
    obg = read_original_grapheme_break(root)
    ignorable, incb = read_derived_core(root)
    flags = read_emoji_data(root)
    vs_base = read_emoji_vs(root)
    full_gb, nc_gb = derive_grapheme_break(obg, incb, flags)
    width, zig = derive_width(gc, eaw, full_gb, ignorable, flags)
    summary_parts = [tarball_note, spot_check(width), self_check(root, full_gb, nc_gb, version)]
    summary = "; ".join(summary_parts)
    say("self-check: " + summary)

    width_rows = [(lo, hi, value) for lo, hi, value in ranges_of(width, 1)]
    zig_rows = flag_ranges(zig)
    gb_rows = [(lo, hi, value) for lo, hi, value in ranges_of(nc_gb, 0)]
    vs_rows = flag_ranges(vs_base)
    write_output(out, root, version, NC, width_rows, zig_rows, gb_rows, vs_rows, summary)
    say("wrote %s: %d width ranges, %d zero-in-grapheme ranges, %d grapheme ranges, %d VS base "
        "ranges"
        % (out, len(width_rows), len(zig_rows), len(gb_rows), len(vs_rows)))
    return summary


PROFILE = ["ghostty-1.3.1"]      # the profile whose tables are generated (set by --profile)


def main(argv):
    global UUCODE_TARBALL_SHA256
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--profile", default="ghostty-1.3.1", choices=sorted(_PINS))
    parser.add_argument("--uucode", required=True, help="unpacked uucode tree")
    parser.add_argument("--out", required=True, help="the tables file to write")
    args = parser.parse_args(argv)
    PROFILE[0] = args.profile
    _select_rules(_rules140 if args.profile == "ghostty-1.4.0" else _rules131)
    UUCODE_TARBALL_SHA256 = _PINS[args.profile][0]
    root = os.path.abspath(args.uucode)
    out = os.path.abspath(args.out)
    try:
        generate(root, out)
    except GenError as exc:
        print("gen_widths: FAILED: %s" % exc)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

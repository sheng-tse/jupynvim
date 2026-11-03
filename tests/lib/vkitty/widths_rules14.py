"""Grapheme break rules of Ghostty 1.4.0's uucode (ea62149, Unicode 18.0.0), ported from
src/grapheme.zig computeGraphemeBreak. The module has the same names as widths_rules.py (the
rules of uucode 0.2.0 that Ghostty 1.3.1 uses).

What Unicode 18 and the new uucode change:

  * InCB=Linker code points that have Grapheme_Cluster_Break=Other (U+1CF5, U+1CF6, U+11A3A) are a
    class of their own, indic_conjunct_break_linker_other, which is not part of Extend; the
    linkers that are Extend are indic_conjunct_break_linker_extend.
  * The break state is a base (default, extended_pictographic or regional_indicator) and a flag
    that a linker has been seen since the last consonant (after_linker), where 0.2.0 had one of
    five states. GB9c is "after_linker and the next is a consonant", which also holds across
    Extend characters.

The states are names: "default", "extended_pictographic" and "regional_indicator", each with the
suffix "+linker" when after_linker is set, in the order of BreakState.tableIndex.
"""

FULL_CLASSES = (
    "other", "control", "prepend", "cr", "lf", "regional_indicator", "spacing_mark",
    "l", "v", "t", "lv", "lvt", "zwj", "zwnj", "extended_pictographic",
    "emoji_modifier_base", "emoji_modifier", "indic_conjunct_break_extend",
    "indic_conjunct_break_linker_extend", "indic_conjunct_break_linker_other",
    "indic_conjunct_break_consonant",
)

NC_CLASSES = (
    "other", "prepend", "regional_indicator", "spacing_mark", "l", "v", "t", "lv", "lvt",
    "zwj", "zwnj", "extended_pictographic", "emoji_modifier_base", "emoji_modifier",
    "indic_conjunct_break_extend", "indic_conjunct_break_linker_extend",
    "indic_conjunct_break_linker_other", "indic_conjunct_break_consonant",
)

BREAK_STATES = (
    "default", "default+linker", "extended_pictographic", "extended_pictographic+linker",
    "regional_indicator", "regional_indicator+linker",
)

_KEEP_EXT_PICT = frozenset((
    "indic_conjunct_break_extend", "indic_conjunct_break_linker_extend", "zwnj", "zwj",
    "extended_pictographic", "emoji_modifier_base", "emoji_modifier",
))


def _is_icb_extend(gb):
    return gb in ("indic_conjunct_break_extend", "zwj")


def _is_linker(gb):
    return gb in ("indic_conjunct_break_linker_extend", "indic_conjunct_break_linker_other")


def _is_extend(gb):
    return gb in ("zwnj", "indic_conjunct_break_extend", "indic_conjunct_break_linker_extend")


def _is_ext_pict(gb):
    return gb in ("extended_pictographic", "emoji_modifier_base")


def compute_grapheme_break(gb1, gb2, state):
    """Return (is_break, new_state) for the pair gb1, gb2 in state (a name)."""
    base, _plus, flag = state.partition("+")
    had_linker = bool(flag)
    after_linker = _is_linker(gb1) or (had_linker and _is_icb_extend(gb1))
    has_linker = after_linker and _is_icb_extend(gb2)

    def done(is_break):
        return is_break, base + ("+linker" if has_linker else "")

    if base == "regional_indicator":
        if gb1 != "regional_indicator" or gb2 != "regional_indicator":
            base = "default"
    elif base == "extended_pictographic":
        if gb1 not in _KEEP_EXT_PICT:
            base = "default"
        if gb2 not in _KEEP_EXT_PICT:
            base = "default"

    # GB3: CR x LF
    if gb1 == "cr" and gb2 == "lf":
        return done(False)
    # GB4 and GB5: break after and before a control
    if gb1 in ("control", "cr", "lf") or gb2 in ("control", "cr", "lf"):
        return done(True)
    # GB6 to GB8: Hangul syllable sequences
    if gb1 == "l" and gb2 in ("l", "v", "lv", "lvt"):
        return done(False)
    if gb1 in ("lv", "v") and gb2 in ("v", "t"):
        return done(False)
    if gb1 in ("lvt", "t") and gb2 == "t":
        return done(False)
    # GB9a: x SpacingMark; GB9b: Prepend x
    if gb2 == "spacing_mark" or gb1 == "prepend":
        return done(False)
    # GB9c: a linker, then any number of Extend, then a consonant
    if after_linker and gb2 == "indic_conjunct_break_consonant":
        base = "default"
        return done(False)
    # GB11: emoji ZWJ sequences and emoji modifier sequences
    if _is_ext_pict(gb1):
        if _is_extend(gb2) or gb2 == "zwj":
            base = "extended_pictographic"
            return done(False)
        if gb1 == "emoji_modifier_base" and gb2 == "emoji_modifier":
            base = "extended_pictographic"
            return done(False)
    elif base == "extended_pictographic":
        if (_is_extend(gb1) or gb1 == "emoji_modifier") and (_is_extend(gb2) or gb2 == "zwj"):
            return done(False)
        if gb1 == "zwj" and _is_ext_pict(gb2):
            base = "default"
            return done(False)
        base = "default"
    # GB12 and GB13: regional indicator pairs
    if gb1 == "regional_indicator" and gb2 == "regional_indicator":
        if base == "default":
            base = "regional_indicator"
            return done(False)
        base = "default"
        return done(True)
    # GB9: x (Extend | ZWJ)
    if _is_extend(gb2) or gb2 == "zwj":
        return done(False)
    # GB999: break everywhere else
    return done(True)

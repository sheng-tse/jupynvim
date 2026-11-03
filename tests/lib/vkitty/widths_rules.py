"""Grapheme break rules, ported from uucode 0.2.0 (src/grapheme.zig).

The classes are names, as in uucode's enums. ``FULL_CLASSES`` is
``types.GraphemeBreak`` (with the control classes) and ``NC_CLASSES`` is
``x.types.GraphemeBreakNoControl`` (the classes Ghostty 1.3.1 looks up, with
control, cr and lf mapped to other). ``BREAK_STATES`` is
``uucode.grapheme.BreakState``, in uucode's order.

``compute_grapheme_break`` is uucode's ``computeGraphemeBreak`` (the full
rule, GB3 to GB5 included); ``widths.py`` precomputes it over the no-control
classes, which is the same rule, because control classes never reach it there.
The self-check in tools/gen_widths.py runs every line of GraphemeBreakTest.txt
through it.
"""

FULL_CLASSES = (
    "other", "control", "prepend", "cr", "lf", "regional_indicator", "spacing_mark",
    "l", "v", "t", "lv", "lvt", "zwj", "zwnj", "extended_pictographic",
    "emoji_modifier_base", "emoji_modifier", "indic_conjunct_break_extend",
    "indic_conjunct_break_linker", "indic_conjunct_break_consonant",
)

NC_CLASSES = (
    "other", "prepend", "regional_indicator", "spacing_mark", "l", "v", "t", "lv", "lvt",
    "zwj", "zwnj", "extended_pictographic", "emoji_modifier_base", "emoji_modifier",
    "indic_conjunct_break_extend", "indic_conjunct_break_linker",
    "indic_conjunct_break_consonant",
)

BREAK_STATES = (
    "default", "regional_indicator", "extended_pictographic",
    "indic_conjunct_break_consonant", "indic_conjunct_break_linker",
)

_STATE_KEEP_EXT_PICT = frozenset((
    "indic_conjunct_break_extend", "indic_conjunct_break_linker", "zwnj", "zwj",
    "extended_pictographic", "emoji_modifier_base", "emoji_modifier",
))
_STATE_KEEP_INDIC = frozenset((
    "indic_conjunct_break_consonant", "indic_conjunct_break_linker",
    "indic_conjunct_break_extend", "zwj",
))


def _is_extend(gb):
    return gb in ("zwnj", "indic_conjunct_break_extend", "indic_conjunct_break_linker")


def _is_icb_extend(gb):
    return gb in ("indic_conjunct_break_extend", "zwj")


def _is_ext_pict(gb):
    return gb in ("extended_pictographic", "emoji_modifier_base")


def compute_grapheme_break(gb1, gb2, state):
    """Return (is_break, new_state) for the pair gb1, gb2 in state (a name)."""
    # The state goes back to default when gb1 or gb2 cannot continue it.
    if state == "regional_indicator":
        if gb1 != "regional_indicator" or gb2 != "regional_indicator":
            state = "default"
    elif state == "extended_pictographic":
        if gb1 not in _STATE_KEEP_EXT_PICT:
            state = "default"
        if gb2 not in _STATE_KEEP_EXT_PICT:
            state = "default"
    elif state in ("indic_conjunct_break_consonant", "indic_conjunct_break_linker"):
        if gb1 not in _STATE_KEEP_INDIC:
            state = "default"
        if gb2 not in _STATE_KEEP_INDIC:
            state = "default"

    # GB3: CR x LF
    if gb1 == "cr" and gb2 == "lf":
        return False, state
    # GB4: break after control
    if gb1 in ("control", "cr", "lf"):
        return True, state
    # GB5: break before control
    if gb2 in ("control", "cr", "lf"):
        return True, state
    # GB6: L x (L | V | LV | LVT)
    if gb1 == "l" and gb2 in ("l", "v", "lv", "lvt"):
        return False, state
    # GB7: (LV | V) x (V | T)
    if gb1 in ("lv", "v") and gb2 in ("v", "t"):
        return False, state
    # GB8: (LVT | T) x T
    if gb1 in ("lvt", "t") and gb2 == "t":
        return False, state
    # GB9a: x SpacingMark
    if gb2 == "spacing_mark":
        return False, state
    # GB9b: Prepend x
    if gb1 == "prepend":
        return False, state

    # GB9c: Indic conjunct break sequences
    if gb1 == "indic_conjunct_break_consonant":
        if _is_icb_extend(gb2):
            return False, "indic_conjunct_break_consonant"
        if gb2 == "indic_conjunct_break_linker":
            return False, "indic_conjunct_break_linker"
    elif state == "indic_conjunct_break_consonant":
        if gb2 == "indic_conjunct_break_linker":
            return False, "indic_conjunct_break_linker"
        if _is_icb_extend(gb2):
            return False, state
        state = "default"
    elif state == "indic_conjunct_break_linker":
        if gb2 == "indic_conjunct_break_linker" or _is_icb_extend(gb2):
            return False, state
        if gb2 == "indic_conjunct_break_consonant":
            return False, "default"
        state = "default"

    # GB11: emoji ZWJ sequences and emoji modifier sequences
    if _is_ext_pict(gb1):
        if _is_extend(gb2) or gb2 == "zwj":
            return False, "extended_pictographic"
        if gb1 == "emoji_modifier_base" and gb2 == "emoji_modifier":
            return False, "extended_pictographic"
    elif state == "extended_pictographic":
        if (_is_extend(gb1) or gb1 == "emoji_modifier") and (_is_extend(gb2) or gb2 == "zwj"):
            return False, state
        if gb1 == "zwj" and _is_ext_pict(gb2):
            return False, "default"
        state = "default"

    # GB12 and GB13: regional indicator pairs
    if gb1 == "regional_indicator" and gb2 == "regional_indicator":
        if state == "default":
            return False, "regional_indicator"
        return True, "default"

    # GB9: x (Extend | ZWJ)
    if _is_extend(gb2) or gb2 == "zwj":
        return False, state

    # GB999: break everywhere else
    return True, state

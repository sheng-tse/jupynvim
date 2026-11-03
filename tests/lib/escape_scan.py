"""Find escape sequences that something else cut, in a raw terminal byte log.

usage: python3 -I tests/lib/escape_scan.py RAW_LOG   (prints a summary)
       python3 -I tests/lib/escape_scan.py --self-test   (run_all.sh)
       or import it: scan(data) -> (cuts, kitty)

A terminal parses its input as one stream (the VT500 parser model): an ESC
starts a new sequence from any state, so a sequence that another write lands
inside ends right there. The terminal drops it and prints whatever came
after the cut as text. This scanner follows the same states and reports each
place where an ESC arrives before the sequence it interrupts was complete:

  ESC   an ESC, or ESC plus intermediate bytes (ESC ( before its B), cut by
        another ESC
  CSI   ESC [ cut before its final byte (a color sequence cut after "38;")
  OSC   ESC ] cut before its BEL or ST
  DCS   ESC P cut before its ST (inside a passthrough wrapper, a doubled ESC
        is part of the body, not a cut)
  APC   ESC _ cut before its ST (a Kitty graphics command)
  PM    ESC ^ or ESC X cut before its ST
  UTF8  a UTF-8 character of the screen text (a placeholder cell, a
        diacritic, a border) whose bytes an ESC split

cuts is a list of (offset of the cut sequence, kind, offset of the ESC that
cut it); kitty counts the Kitty graphics commands (ESC _ G).
"""
import sys

GROUND, ESC, ESC_INT, CSI, STR = range(5)
_STR_KIND = {0x5D: "OSC", 0x50: "DCS", 0x5F: "APC", 0x5E: "PM", 0x58: "PM"}


def _utf8_len(b):
    if 0xC2 <= b <= 0xDF:
        return 2
    if 0xE0 <= b <= 0xEF:
        return 3
    if 0xF0 <= b <= 0xF4:
        return 4
    return 0


def scan(data):
    cuts, kitty = [], 0
    st, start, kind, wrapped = GROUND, 0, None, False
    i, n = 0, len(data)
    while i < n:
        b = data[i]
        if st == GROUND:
            if b == 0x1B:
                st, start = ESC, i
                i += 1
                continue
            need = _utf8_len(b)
            if need:
                j = i + 1
                while j < n and j < i + need and 0x80 <= data[j] <= 0xBF:
                    j += 1
                if j < i + need and j < n and data[j] == 0x1B:
                    cuts.append((i, "UTF8", j))
                i = j
                continue
            i += 1
            continue
        if st == ESC:
            if b == 0x1B:
                cuts.append((start, "ESC", i))
                start = i
                i += 1
                continue
            if b == 0x5B:
                st = CSI
            elif b in _STR_KIND:
                st, kind = STR, _STR_KIND[b]
                wrapped = kind == "DCS" and data[i + 1:i + 6] == b"tmux;"
                if kind == "APC" and data[i + 1:i + 2] == b"G":
                    kitty += 1
            elif 0x20 <= b <= 0x2F:
                st = ESC_INT
            else:
                st = GROUND  # the final byte
            i += 1
            continue
        if st == ESC_INT:
            if b == 0x1B:
                cuts.append((start, "ESC", i))
                st, start = ESC, i
            elif not 0x20 <= b <= 0x2F:
                st = GROUND
            i += 1
            continue
        if st == CSI:
            if b == 0x1B:
                cuts.append((start, "CSI", i))
                st, start = ESC, i
            elif 0x40 <= b <= 0x7E:
                st = GROUND
            i += 1
            continue
        # a string: OSC (ends with BEL or ST), DCS, APC, PM (end with ST)
        if b == 0x07 and kind == "OSC":
            st = GROUND
            i += 1
            continue
        if b == 0x1B:
            nxt = data[i + 1:i + 2]
            if nxt == b"\\":
                st = GROUND
                i += 2
                continue
            if wrapped and nxt == b"\x1b":
                i += 2
                continue
            if not nxt:  # the log ends here
                break
            cuts.append((start, kind, i))
            st, start = ESC, i
            i += 1
            continue
        i += 1
    return cuts, kitty


def summary(data, cuts, kitty, show=5):
    kinds = {}
    for _, k, _ in cuts:
        kinds[k] = kinds.get(k, 0) + 1
    out = ["bytes=%d kitty_escapes=%d cut_sequences=%d %s" % (
        len(data), kitty, len(cuts), " ".join("%s:%d" % kv for kv in sorted(kinds.items())) or "-")]
    for off, kind, by in cuts[:show]:
        out.append("  @%d %s %r cut by %r" % (off, kind, data[off:min(by, off + 24)], data[by:by + 24]))
    return "\n".join(out)


# Streams with known answers. Every kind of cut is found, in order, and
# complete sequences, a passthrough wrapper's doubled ESCs, UTF-8 screen
# text and a log that ends inside a sequence are not cuts. A BEL ends only
# an OSC, and a doubled ESC is body only inside the wrapper it belongs to.
SELF_TEST = [
    # (name, stream, kinds of the cuts in order, kitty count or None)
    ("complete sequences are not cuts",
     b"abc \x1b[38;2;59;66;97mtext\x1b[0m \x1b(B \x1b]11;?\x07 \x1b]8;;http://x\x1b\\link\x1b]8;;\x1b\\ "
     b"\x1b_Ga=p,U=1,i=5,p=1,c=2,r=1,q=2\x1b\\ \x1bP+q544e\x1b\\ \x1b=\x1b> \x1b^pm\x1b\\", (), 1),
    ("the doubled ESCs inside a passthrough wrapper are not cuts",
     b"\x1bPtmux;\x1b\x1b_Ga=t,f=100,i=7,q=2,m=0;QUFB\x1b\x1b\\\x1b\\after", (), None),
    ("UTF-8 text, box drawing and placeholder cells are not cuts",
     "─│╰ \U0010EEEE̅̍ é".encode("utf-8"), (), 0),
    ("a log that ends inside a sequence holds no cut", b"x\x1b_Ga=t,q=2;QUFB", (), 1),
    ("a log that ends on an ESC holds no cut", b"x\x1b_Ga=t,q=2;QUFB\x1b", (), 1),
    ("a color sequence cut by a graphics command",
     b"\x1b[38;2;59;\x1b_Ga=t,q=2;QUFB\x1b\\66;97m", ("CSI",), 1),
    ("a charset designation cut before its final byte",
     b"\x1b(\x1b_Ga=d,d=i,i=3,q=2\x1b\\B", ("ESC",), 1),
    ("a lone ESC followed by another", b"\x1b\x1b[0m", ("ESC",), 0),
    ("an OSC reply cut before its BEL",
     b"\x1b]11;rgb:1e1e\x1b_Ga=p,i=1,q=2\x1b\\/2e2e\x07", ("OSC",), 1),
    ("a DCS query cut before its ST", b"\x1bP+q544e\x1b[c", ("DCS",), 0),
    ("a graphics command cut by a color sequence",
     b"\x1b_Ga=t,f=100,i=9,q=2,m=1;QUFB\x1b[38;2;1;2;3mX", ("APC",), 1),
    ("a PM and an SOS string cut", b"\x1b^note\x1b[0m\x1bXsos\x1b[0m", ("PM", "PM"), 0),
    ("a box drawing character split by an ESC", b"\xe2\x95\x1b[0m\xb0", ("UTF8",), 0),
    ("a placeholder cell split by a graphics command",
     b"\xf4\x8f\x1b_Ga=p,i=1,q=2\x1b\\\xbb\xae", ("UTF8",), 1),
    ("a cut sequence whose cutter is cut too", b"\x1b[38;\x1b_Ga=t;QQ\x1b[0m", ("CSI", "APC"), 1),
    ("a passthrough wrapper cut by an ESC that is not doubled",
     b"\x1bPtmux;\x1b\x1b_Ga=t;QQ\x1b[0m\x1b\\", ("DCS",), None),
    ("a placeholder cell split after its third byte",
     b"\xf4\x8e\xbb\x1b_Ga=p,i=1,q=2\x1b\\\xae", ("UTF8",), 1),
    ("an APC that is not a graphics command is not counted as one", b"\x1b_x\x1b\\", (), 0),
    ("@ ends a CSI sequence (insert characters)", b"\x1b[4@\x1b[0m", (), 0),
    ("a BEL ends only an OSC: inside a graphics command it is data",
     b"\x1b_Ga=t;QQ\x07\x1b[0m", ("APC",), 1),
    ("a doubled ESC cuts a DCS that is not a passthrough wrapper", b"\x1bP+q\x1b\x1b[0m", ("DCS", "ESC"), 0),
    ("a passthrough wrapper does not make the next DCS one",
     b"\x1bPtmux;\x1b\x1b_Ga=t;QQ\x1b\x1b\\\x1b\\\x1bP+q\x1b\x1b[0m", ("DCS", "ESC"), None),
    ("~ ends a CSI sequence (a function key)", b"\x1b[3~\x1b[0m", (), 0),
    ("0xC0 is no UTF-8 lead byte, so an ESC after it cuts nothing", b"\xc0\x1b[0m", (), 0),
    ("a UTF-8 lead byte followed by plain text is broken text, not a cut", b"\xe2X\x1b[0m", (), 0),
    ("a DCS that starts with tmux but not tmux; is no passthrough wrapper",
     b"\x1bPtmuxQ\x1b\x1b[0m\x1b\\", ("DCS", "ESC"), 0),
]


def self_test():
    fails = 0
    def report(name, ok, detail):
        nonlocal fails
        print(("  ok " if ok else "FAIL ") + name + ("" if ok else "  -- " + detail))
        fails += 0 if ok else 1
    for name, data, kinds, kitty in SELF_TEST:
        cuts, k = scan(data)
        report(name, tuple(c[1] for c in cuts) == kinds and (kitty is None or k == kitty),
               "cuts %r, kitty %d" % (cuts, k))
    # a cut is reported at the start of the cut sequence, with the ESC that cut it
    cuts, _ = scan(b"ab\x1b[38;2;59;\x1b_Ga=t,q=2;QUFB\x1b\\66;97m")
    report("a cut names where the cut sequence starts and where it was cut",
           cuts == [(2, "CSI", 12)], "cuts %r" % (cuts,))
    # the ESC that cut a sequence starts the next one, also after ESC plus intermediates
    cuts, _ = scan(b"ab\x1b(\x1b[3\x1b[0m")
    report("the ESC that cut a charset designation starts the next sequence",
           cuts == [(2, "ESC", 4), (4, "CSI", 7)], "cuts %r" % (cuts,))
    # and after a CSI, a string and a lone ESC that were cut: a second cut
    # names where its own sequence started
    cuts, _ = scan(b"\x1b[38;\x1b[3\x1b[0m")
    report("the ESC that cut a CSI starts the next sequence",
           cuts == [(0, "CSI", 5), (5, "CSI", 8)], "cuts %r" % (cuts,))
    cuts, _ = scan(b"\x1b]11;x\x1b_Gq\x1b[0m")
    report("the ESC that cut a string starts the next sequence",
           cuts == [(0, "OSC", 6), (6, "APC", 10)], "cuts %r" % (cuts,))
    cuts, _ = scan(b"x\x1b\x1b\x1b[0m")
    report("the ESC that cut a lone ESC starts the next sequence",
           cuts == [(1, "ESC", 2), (2, "ESC", 3)], "cuts %r" % (cuts,))
    print(("\nESCAPE-SCAN: %d SELF-TEST(S) FAILED" % fails) if fails else "\nESCAPE-SCAN: ALL SELF-TESTS PASSED")
    return fails == 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        sys.exit(0 if self_test() else 1)
    raw = open(sys.argv[1], "rb").read()
    c, k = scan(raw)
    print(summary(raw, c, k))
    sys.exit(1 if c else 0)

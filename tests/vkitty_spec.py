#!/usr/bin/env python3
"""Synthetic spec for the headless Kitty graphics harness (tests/lib/vkitty).

    "$PY" -I tests/vkitty_spec.py [--only GROUP[,GROUP|GROUP/CASE...]] [--list]

It runs without tmux and without nvim, on streams it builds itself. The groups: tokens (byte
tokenizer: Ghostty parser, tmux passthrough, fast paths against the slow path), widths (Unicode
width and grapheme tables), vt (the terminal model against Ghostty 1.3.1: grid, modes, margins,
screens, the mode 2027 grapheme cases of Terminal.zig, SGR and the DEC graphics table by hand),
kgp (the Kitty graphics core: commands, storage, responses, deletes and the answers and wire bytes
of the hop rules), media (file, temporary file and shared memory transmissions), place (placements,
pins and Unicode placeholders), anim (the kitty profile's animation), ssim and render (the
renderer and its score), relay (the live recorder, its recording, the live terminal's worker and
the replay command line), g140 (the same bytes through the ghostty-1.3.1 and ghostty-1.4.0
profiles, asserting what Ghostty 1.4.0 changed), perf (tokenizer, replay, render and relay
throughput, decided on the
measurements the host did not disturb), perfclock (the clock that decides them), faults (each
fault of tests/lib/vkitty/faults.py makes its listed cases fail) and meta (checks on the harness's
own files). The tmux differential test is tests/vkitty_screen.sh.

Every case prints `ok group/name (N ms)` or `FAIL group/name: message`; a case
may add a note (a measured value) after the time. The last line is the verdict:
`ALL VKITTY CHECKS PASSED` (exit 0) or `N VKITTY CHECKS FAILED` (exit 1). When a busy host left
timed limits undecided, the line before it is `N timed cases undecided (host busy): CASES`; that
never changes the exit status. A usage error exits 2. Heavy modules (numpy, Pillow, fontTools) are
imported inside the cases that need them, so this file runs anywhere Python 3.10 runs.
VKITTY_FAULT (see tests/lib/vkitty/faults.py) breaks one component on purpose;
the cases it must fail are listed there.
"""
import os
import random
import sys
import time
import traceback

sys.dont_write_bytecode = True   # a run of the harness writes no bytecode into the repository tree

HERE = os.path.dirname(os.path.abspath(__file__))
LIB = os.path.join(HERE, "lib")
if LIB not in sys.path:
    sys.path.insert(0, LIB)

CASES = []  # (group, name, function)


def case(group, name):
    """Register a case; the function raises AssertionError on failure and may
    return a note string to print after the timing."""
    def register(fn):
        CASES.append((group, name, fn))
        return fn
    return register


def check(cond, msg="check failed"):
    if not cond:
        raise AssertionError(msg)


def short(value, limit=400):
    """repr cut to `limit` characters, so a failure over a megabyte stays readable."""
    text = repr(value)
    return text if len(text) <= limit else text[:limit] + "...(%d chars)" % len(text)


def eq(got, want, msg=""):
    if got != want:
        raise AssertionError("%s: got %s, want %s"
                             % (msg or "values differ", short(got), short(want)))


PRINT, EXEC, ESC, CSI, OSC, DCS, APC, SOS_PM = range(8)
KIND_NAMES = ("PRINT", "EXEC", "ESC", "CSI", "OSC", "DCS", "APC", "SOS_PM")


def tokenize(chunks, offsets=None, **kwargs):
    """Feed the chunks in order (absolute offsets) and return (tokens, tokenizer)."""
    from vkitty.tokens import Tokenizer
    out = []
    tk = Tokenizer(out.append, **kwargs)
    off = 0
    for chunk in chunks:
        tk.feed(chunk, off)
        off += len(chunk)
    tk.finish()
    return out, tk


def utf8_tmux():
    """The utf8 value that selects tmux's decoding rule (vkitty.tokens.UTF8_TMUX)."""
    from vkitty.tokens import UTF8_TMUX
    return UTF8_TMUX


def merge_prints(tokens):
    """Join PRINT tokens that touch (a.end == b.start, same tmux origin): a feed
    boundary may split one printed run into two tokens; the text is the same."""
    from vkitty.tokens import Token
    merged = []
    for tok in tokens:
        if merged:
            prev = merged[-1]
            if (prev.kind == PRINT and tok.kind == PRINT and prev.end == tok.start
                    and prev.via_tmux == tok.via_tmux):
                merged[-1] = Token(PRINT, prev.payload + tok.payload, prev.start, tok.end,
                                   False, 0, prev.via_tmux)
                continue
        merged.append(tok)
    return merged


def as_tuples(tokens):
    return [(t.kind, t.payload, t.start, t.end, t.cut, t.ordinal, t.via_tmux) for t in tokens]


def describe(tokens):
    return [(KIND_NAMES[t.kind], t.payload, t.start, t.end, t.cut) for t in tokens]


def wrap(data):
    """What core/src/kitty.rs LocalTty::write produces inside tmux."""
    from vkitty.tokens import tmux_wrap
    return tmux_wrap(data)


def apc(payload):
    return b"\x1b_" + payload + b"\x1b\\"


# ---------------------------------------------------------------- tokens ---

HOSTILE_ITEMS = (
    b"\x1b\x1b", b"\x18", b"\x1a", b"\x1bx", b"AA", b"\x1b\x1b_Gi=3;", b"\x9c", b"\x1b\x1b\\",
    b"\x1b[1m", b"Q", b"\x07", b"\x0d", b"\x1b\x1b_Ga=q,i=4;AAAA\x1b\x1b\\",
)


def hostile_piece(rnd):
    """Pieces the tmux and string rules must agree on: passthrough bodies with CAN,
    SUB, lone ESC and C1 bytes; DCS with final t that is not tmux; DCS with 20 to 26
    separators; 0x9C inside APC, DCS and OSC strings."""
    kind = rnd.random()
    if kind < 0.4:
        body = b"".join(rnd.choice(HOSTILE_ITEMS) for _ in range(rnd.randrange(0, 10)))
        return b"\x1bPtmux;" + body + b"\x1b\\"
    if kind < 0.6:
        prefix = bytes(rnd.choice(b"mux;xyz\x18\x1a") for _ in range(rnd.randrange(0, 6)))
        body = b"".join(rnd.choice(HOSTILE_ITEMS) for _ in range(rnd.randrange(0, 6)))
        return b"\x1bPt" + prefix + body + b"\x1b\\"
    if kind < 0.75:
        return b"\x1bP" + b"1;" * rnd.randrange(20, 27) + b"q" + b"zz" + b"\x1b\\"
    return rnd.choice([b"\x1b_Gi=5;\x9cAA\x1b\\", b"\x1bPq#1\x9c", b"\x1b]0;a\x9cb\x07"])


@case("tokens", "fast_equals_slow")
def _tokens_fast_equals_slow():
    rnd = random.Random(20260624)
    seen = set()
    b64 = b"QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo"

    def text_piece():
        n = rnd.randrange(1, 24)
        return "".join(rnd.choice("abcdefgh XYZ012.,;") for _ in range(n)).encode()

    def utf8_piece():
        return rnd.choice(["\u00e9", "\u4e16\u754c", "\U0001f600", "e\u0301", "\ud55c", "\u0600",
                           "\u0903"]).encode("utf-8")

    def csi_piece():
        params = bytes(rnd.choice(b"0123456789;:") for _ in range(rnd.randrange(0, 6)))
        inter = bytes(rnd.choice(b" !\"#$%&'()*+,-./") for _ in range(rnd.randrange(0, 2)))
        if rnd.random() < 0.1:
            params = b"?" + params
        final = bytes([rnd.randrange(0x40, 0x7F)])
        if rnd.random() < 0.07:
            return b"\x1b[" + params[:1] + b"\r" + params[1:] + inter + final
        if rnd.random() < 0.05:
            return b"\x1b[" + params + b"\x18" + final
        if rnd.random() < 0.05:
            return b"\x1b[" + params + b"\x1a" + final
        return b"\x1b[" + params + inter + final

    def osc_piece():
        body = text_piece()
        term = rnd.choice([b"\x07", b"\x1b\\", b""])
        return b"\x1b]0;" + body + term

    def apc_piece():
        payload = b"Ga=T,f=100,m=1,i=%d;" % rnd.randrange(1, 99) + b64[: rnd.randrange(4, 33)]
        return apc(payload)

    def tmux_piece():
        inner = b"".join(apc(b"Ga=q,i=%d;AAAA" % rnd.randrange(1, 9)) for _
                         in range(rnd.randrange(1, 4)))
        return wrap(inner)

    def misc_piece():
        choice = rnd.random()
        if choice < 0.4:
            return b"\x1bPq" + bytes(rnd.choice(b"0123456789abcdef") for _ in range(6)) + b"\x1b\\"
        if choice < 0.6:
            return b"\x1b7" + b"\x1b8"
        if choice < 0.8:
            return b"\xe4"  # a lone lead byte, made invalid by whatever comes next
        return b"\x9c"

    def splice_piece():
        # a character no other maker emits, split after a random interior byte, with a
        # sequence, a passthrough body or ESC 7 inside the split
        enc = rnd.choice(["\u00fc", "\u3042", "\U0001f680"]).encode("utf-8")
        cut = rnd.randrange(1, len(enc))
        inner = rnd.choice([csi_piece, osc_piece, tmux_piece, lambda: b"\x1b7"])()
        return enc[:cut] + inner + enc[cut:]

    makers = [text_piece, utf8_piece, csi_piece, osc_piece, apc_piece, tmux_piece, misc_piece,
              lambda: hostile_piece(rnd), splice_piece]
    split_chars = ("\u00fc", "\u3042", "\U0001f680")
    discards_seen = 0
    splices_seen = 0
    split_printed = False
    for index in range(200):
        pieces = []
        for _ in range(rnd.randrange(8, 40)):
            pieces.append(rnd.choice(makers)())
        stream = b"".join(pieces)
        # chunks of 1 to 64 bytes
        chunks = []
        pos = 0
        while pos < len(stream):
            step = rnd.randrange(1, 65)
            chunks.append(stream[pos:pos + step])
            pos += step
        fast_tokens, fast_tk = tokenize(chunks)
        slow_tokens, slow_tk = tokenize([stream], _force_slow=True)
        fast = as_tuples(merge_prints(fast_tokens))
        slow = as_tuples(merge_prints(slow_tokens))
        if fast != slow:
            for i, (a, b) in enumerate(zip(fast, slow)):
                if a != b:
                    raise AssertionError("stream %d: token %d differs: fast %r slow %r"
                                         % (index, i, a, b))
            raise AssertionError("stream %d: token counts differ: %d vs %d"
                                 % (index, len(fast), len(slow)))
        eq(fast_tk.cuts, slow_tk.cuts, "stream %d cuts" % index)
        # the same streams with a 48-byte passthrough limit, so that drops occur
        fast48_tokens, fast48_tk = tokenize(chunks, _tmux_limit=48)
        slow48_tokens, slow48_tk = tokenize([stream], _force_slow=True, _tmux_limit=48)
        eq(as_tuples(merge_prints(fast48_tokens)), as_tuples(merge_prints(slow48_tokens)),
           "stream %d tokens at a 48-byte limit" % index)
        eq(fast48_tk.discards, slow48_tk.discards, "stream %d discards at a 48-byte limit" % index)
        eq(fast48_tk.cuts, slow48_tk.cuts, "stream %d cuts at a 48-byte limit" % index)
        discards_seen += len(slow48_tk.discards)
        seen.update(t.kind for t in slow_tokens)
        # the same chunks under the tmux hop's UTF-8 rule: same tokens, cuts and splices
        tmux_fast, tmux_fast_tk = tokenize(chunks, utf8=utf8_tmux())
        tmux_slow, tmux_slow_tk = tokenize([stream], _force_slow=True, utf8=utf8_tmux())
        eq(as_tuples(merge_prints(tmux_fast)), as_tuples(merge_prints(tmux_slow)),
           "stream %d tmux-mode tokens" % index)
        eq(tmux_fast_tk.cuts, tmux_slow_tk.cuts, "stream %d tmux-mode cuts" % index)
        eq(tmux_fast_tk.splices, tmux_slow_tk.splices, "stream %d tmux-mode splices" % index)
        splices_seen += len(tmux_slow_tk.splices)
        if any(tok.kind == PRINT and any(ch in tok.payload for ch in split_chars) for tok
               in tmux_slow):
            split_printed = True
    for kind in (PRINT, EXEC, ESC, CSI, OSC, DCS, APC):
        check(kind in seen, "no %s token in 200 streams: the generator lost a kind"
              % KIND_NAMES[kind])
    check(discards_seen > 0,
          "no passthrough DCS was dropped at a 48-byte limit: the generator is too tame")
    check(splices_seen >= 20, "only %d splices in the tmux runs: the generator is too tame"
          % splices_seen)
    check(split_printed,
          "no split character was printed whole in the tmux runs: the generator is too tame")
    return "200 streams, kinds %s, %d drops at a 48-byte limit, %d splices in the tmux runs" % (
        ",".join(KIND_NAMES[k] for k in sorted(seen)), discards_seen, splices_seen)


@case("tokens", "probe_cut")
def _tokens_probe_cut():
    prefix = b"\x1b[18;\x1bPtmux;\x1b\x1b_Ga=d,d=i,i=5,q=2\x1b\x1b\\\x1b\\"
    data = prefix + b"5H"
    toks, tk = tokenize([data])
    eq(tk.cuts, [(0, "csi")], "cuts")
    kinds = [t.kind for t in toks]
    eq(kinds, [APC, PRINT], "token kinds")
    a = toks[0]
    eq(a.payload, b"Ga=d,d=i,i=5,q=2", "APC payload")
    eq(a.start, 5, "APC start (the DCS ESC)")
    eq(a.via_tmux, True, "via_tmux")
    eq(a.ordinal, 0, "ordinal")
    eq(a.cut, False, "APC cut")
    eq(toks[1].payload, "5H", "PRINT after the DCS")
    eq(toks[1].start, len(prefix), "PRINT start")


@case("tokens", "apc_cut_dispatches")
def _tokens_apc_cut_dispatches():
    data = b"\x1b_Ga=t;QUJD\x1b[m"
    toks, tk = tokenize([data])
    eq(kinds_of(toks), [APC, CSI], "token kinds")
    eq(toks[0].payload, b"Ga=t;QUJD", "APC payload")
    eq(toks[0].cut, True, "APC is cut by ESC")
    eq((toks[0].start, toks[0].end), (0, 11), "APC span")
    eq(toks[1].payload, (b"", b"", ord("m")), "CSI m")
    eq(tk.cuts, [(0, "apc")], "cuts")


def kinds_of(tokens):
    return [t.kind for t in tokens]


@case("tokens", "c0_in_csi")
def _tokens_c0_in_csi():
    toks, tk = tokenize([b"\x1b[1\r2m"])
    eq(kinds_of(toks), [EXEC, CSI], "token kinds")
    eq(toks[0].payload, 13, "EXEC CR")
    eq((toks[0].start, toks[0].end), (3, 4), "EXEC span")
    eq(toks[1].payload, (b"12", b"", ord("m")), "CSI params")
    eq((toks[1].start, toks[1].end, toks[1].cut), (0, 6, False), "CSI span")
    eq(tk.cuts, [], "no cut")


@case("tokens", "can_sub")
def _tokens_can_sub():
    # Ghostty stream.zig (nextNonUtf8, csi_param fast path): CAN and SUB in
    # csi_param move the parser to ground without executing anything.
    toks, tk = tokenize([b"\x1b[12\x18x"])
    eq(describe(toks), [("PRINT", "x", 5, 6, False)], "csi_param CAN")
    eq(tk.cuts, [(0, "csi")], "csi_param CAN cut")
    toks, tk = tokenize([b"\x1b[12\x1ax"])
    eq(describe(toks), [("PRINT", "x", 5, 6, False)], "csi_param SUB")
    eq(tk.cuts, [(0, "csi")], "csi_param SUB cut")
    # Outside csi_param the table applies: CAN is executed and ends the CSI.
    toks, tk = tokenize([b"\x1b[\x18x"])
    eq(describe(toks), [("EXEC", 0x18, 2, 3, False), ("PRINT", "x", 3, 4, False)], "csi_entry CAN")
    eq(tk.cuts, [(0, "csi")], "csi_entry CAN cut")


@case("tokens", "csi_colon_rule")
def _tokens_csi_colon_rule():
    """Parser.zig csi_dispatch: colon separators are dispatched only for SGR (m).
    The same rule holds on the fast path and on the slow path."""
    for data in (b"\x1b[38:5:1H", b"\x1b[1:2A", b"\x1b[?1:2h"):
        toks, tk = tokenize([data])
        eq(kinds_of(toks), [], "colon CSI %r is dropped" % data)
        check(any("colon" in w for w in tk.warnings), "no warning for %r" % data)
        slow, _ = tokenize([data], _force_slow=True)
        eq(kinds_of(slow), [], "slow path drops %r" % data)
    toks, _ = tokenize([b"\x1b[38:5:1m"])
    eq(as_tuples(toks), [(CSI, (b"38:5:1", b"", ord("m")), 0, 9, False, 0, False)],
       "SGR with colons is dispatched")
    slow, _ = tokenize([b"\x1b[38:5:1m"], _force_slow=True)
    eq(as_tuples(slow), as_tuples(toks), "SGR colon form, both paths")


@case("tokens", "csi_param_cap")
def _tokens_csi_param_cap():
    """Parser.zig MAX_PARAMS is 24: a CSI with 24 separators is ignored, 23 is kept."""
    ok = b"\x1b[" + b";".join([b"1"] * 24) + b"m"
    dropped = b"\x1b[" + b";".join([b"1"] * 25) + b"m"
    for data, want in ((ok, 1), (dropped, 0)):
        toks, _ = tokenize([data])
        eq(len(toks), want, "tokens for a %d-parameter CSI" % (data.count(b";") + 1))
        slow, _ = tokenize([data], _force_slow=True)
        eq(as_tuples(slow), as_tuples(toks), "both paths, %d separators" % data.count(b";"))


@case("tokens", "osc_terms")
def _tokens_osc_terms():
    toks, tk = tokenize([b"\x1b]0;title\x07a"])
    eq(kinds_of(toks), [OSC, PRINT], "BEL kinds")
    eq(toks[0].payload, (b"0;title", b"\x07"), "BEL payload")
    eq(toks[0].cut, False, "BEL not cut")
    eq(tk.cuts, [], "BEL no cut")
    toks, tk = tokenize([b"\x1b]0;title\x1b\\a"])
    eq(kinds_of(toks), [OSC, PRINT], "ST kinds: the ESC \\ is part of the OSC")
    eq(toks[0].payload, (b"0;title", b"\x1b\\"), "ST payload")
    eq(toks[0].cut, False, "ST not cut")
    eq(tk.cuts, [], "ST no cut")
    toks, tk = tokenize([b"\x1b]0;ti\x1b[m"])
    eq(kinds_of(toks), [OSC, CSI], "cut kinds")
    eq(toks[0].payload, (b"0;ti", b""), "cut payload")
    eq(toks[0].cut, True, "cut flag")
    eq(tk.cuts, [(0, "osc")], "cut list")


@case("tokens", "utf8_split")
def _tokens_utf8_split():
    cjk = "\u4e16".encode("utf-8")
    toks, tk = tokenize([cjk[i:i + 1] for i in range(len(cjk))])
    eq(describe(toks), [("PRINT", "\u4e16", 0, 3, False)], "split CJK")
    toks, tk = tokenize([b"\x9c"])
    eq(describe(toks), [("PRINT", "\ufffd", 0, 1, False)], "lone continuation byte")


@case("tokens", "ground_c0")
def _tokens_ground_c0():
    data = b"a\x07b\x18c\x7fd\x1fe"
    toks, tk = tokenize([data])
    eq(describe(toks), [
        ("PRINT", "a", 0, 1, False),
        ("EXEC", 7, 1, 2, False),
        ("PRINT", "b\x18c\x7fd\x1fe", 2, 9, False),
    ], "ground runs")
    eq(tk.cuts, [], "no cut")


@case("tokens", "tmux_prefix_split")
def _tokens_tmux_prefix_split():
    stream = b"ab" + wrap(apc(b"Ga=q,i=7;AAAA")) + b"cd"
    whole, _ = tokenize([stream])
    want = as_tuples(merge_prints(whole))
    check(any(t.via_tmux or t.kind == DCS for t in whole), "the stream has no DCS token at all")
    for pos in range(1, len(stream)):
        got, _ = tokenize([stream[:pos], stream[pos:]])
        eq(as_tuples(merge_prints(got)), want, "split at byte %d" % pos)
    pieces = [stream[i:i + 1] for i in range(len(stream))]
    got, _ = tokenize(pieces)
    eq(as_tuples(merge_prints(got)), as_tuples(merge_prints(whole)), "one-byte feeds")


@case("tokens", "multi_apc_dcs")
def _tokens_multi_apc_dcs():
    inner = apc(b"Ga=q,i=1;AAAA") + apc(b"Ga=q,i=2;AAAA") + apc(b"Ga=q,i=3;AAAA")
    data = b"x" + wrap(inner) + b"y"
    toks, tk = tokenize([data])
    apcs = [t for t in toks if t.kind == APC]
    eq(len(apcs), 3, "APC count")
    eq([t.ordinal for t in apcs], [0, 1, 2], "ordinals")
    eq(len(set(t.start for t in apcs)), 1, "same DCS start")
    eq(apcs[0].start, 1, "start is the DCS ESC")
    eq([t.payload for t in apcs], [b"Ga=q,i=1;AAAA", b"Ga=q,i=2;AAAA", b"Ga=q,i=3;AAAA"],
       "payloads")
    check(all(t.via_tmux for t in apcs), "via_tmux")


@case("tokens", "random_bytes")
def _tokens_random_bytes():
    """Random bytes, mostly controls and ESC, fed in random chunks: no exception,
    the fast path equals the slow path (tokens and cuts), and strings_only keeps
    exactly the APC tokens of the full parse. The same holds under the tmux hop's
    UTF-8 rule (tokens, cuts, splices, strings_only)."""
    rnd = random.Random(20260625)
    specials = [0x1B, 0x1B, 0x1B, 0x5B, 0x5D, 0x50, 0x5F, 0x58, 0x5E, 0x5C, 0x07, 0x18, 0x1A,
                0x3B, 0x3A, 0x3F, 0x20, 0x6D, 0x74, 0x9B, 0x9C, 0x90, 0x9D, 0x98, 0x9F, 0xE4,
                0x80, 0x0D, 0x7F]
    kinds = set()
    for index in range(300):
        if index % 2:
            data = b"".join(hostile_piece(rnd)
                            + bytes(rnd.choice(specials) for _ in range(rnd.randrange(0, 3)))
                            for _ in range(rnd.randrange(1, 12)))
        else:
            data = bytes(rnd.choice(specials) if rnd.random() < 0.6 else rnd.randrange(256)
                         for _ in range(rnd.randrange(0, 300)))
        chunks = []
        pos = 0
        while pos < len(data):
            step = rnd.randrange(1, 9)
            chunks.append(data[pos:pos + step])
            pos += step
        fast, fast_tk = tokenize(chunks)
        slow, slow_tk = tokenize([data], _force_slow=True)
        eq(as_tuples(merge_prints(fast)), as_tuples(merge_prints(slow)), "stream %d tokens" % index)
        eq(fast_tk.cuts, slow_tk.cuts, "stream %d cuts" % index)
        fast48, fast48_tk = tokenize(chunks, _tmux_limit=48)
        slow48, slow48_tk = tokenize([data], _force_slow=True, _tmux_limit=48)
        eq(as_tuples(merge_prints(fast48)), as_tuples(merge_prints(slow48)),
           "stream %d tokens at a 48-byte limit" % index)
        eq(fast48_tk.discards, slow48_tk.discards, "stream %d discards at a 48-byte limit" % index)
        eq(fast48_tk.cuts, slow48_tk.cuts, "stream %d cuts at a 48-byte limit" % index)
        only_apc, _ = tokenize([data], strings_only=True)
        eq(as_tuples(only_apc), as_tuples([t for t in slow if t.kind == APC]),
           "stream %d strings_only" % index)
        tmux_fast, tmux_fast_tk = tokenize(chunks, utf8=utf8_tmux())
        tmux_slow, tmux_slow_tk = tokenize([data], _force_slow=True, utf8=utf8_tmux())
        eq(as_tuples(merge_prints(tmux_fast)), as_tuples(merge_prints(tmux_slow)),
           "stream %d tmux-mode tokens" % index)
        eq(tmux_fast_tk.cuts, tmux_slow_tk.cuts, "stream %d tmux-mode cuts" % index)
        eq(tmux_fast_tk.splices, tmux_slow_tk.splices, "stream %d tmux-mode splices" % index)
        tmux_only_apc, _ = tokenize([data], strings_only=True, utf8=utf8_tmux())
        eq(as_tuples(tmux_only_apc), as_tuples([t for t in tmux_slow if t.kind == APC]),
           "stream %d tmux-mode strings_only" % index)
        kinds.update(t.kind for t in slow)
    check(APC in kinds and CSI in kinds and EXEC in kinds, "the random streams lack a kind")


@case("tokens", "utf8_tmux_rule")
def _tokens_utf8_tmux_rule():
    """The tmux hop's UTF-8 rule (input.c input_top_bit_set, utf8_open, utf8_append): every row of
    battery.UTF8_SPLICE_ROWS, after an "A", prints the text tmux shows however its bytes are fed,
    and counts its splices. The default rule (Ghostty's decoder) keeps its own answers."""
    from vkitty.battery import UTF8_SPLICE_ROWS
    for name, data, want, splices, _in_battery in UTF8_SPLICE_ROWS:
        stream = b"A" + (data % 1 if b"%d" in data else data)
        n = len(stream)
        whole, whole_tk = tokenize([stream], utf8=utf8_tmux())
        ones, ones_tk = tokenize([stream[i:i + 1] for i in range(n)], utf8=utf8_tmux())
        threes, threes_tk = tokenize([stream[i:i + 3] for i in range(0, n, 3)], utf8=utf8_tmux())
        slow, slow_tk = tokenize([stream], _force_slow=True, utf8=utf8_tmux())
        for how, toks, tk in (("whole", whole, whole_tk), ("1-byte", ones, ones_tk),
                              ("3-byte", threes, threes_tk), ("slow", slow, slow_tk)):
            text = "".join(t.payload for t in toks if t.kind == PRINT and not t.via_tmux)
            eq(text, "A" + want, "%s (%s): printed text" % (name, how))
            eq(len(tk.splices), splices, "%s (%s): splices" % (name, how))
            eq(tk.cuts, whole_tk.cuts, "%s (%s): cuts" % (name, how))
            eq(tk.splices, whole_tk.splices, "%s (%s): splice positions" % (name, how))
    # the default rule keeps Ghostty's answers for the same bytes
    toks, tk = tokenize([b"A\xe4\x1b[31m\xb8\x96\x1b[mZ"])
    eq("".join(t.payload for t in toks if t.kind == PRINT), "A\ufffd\ufffd\ufffdZ",
       "Ghostty's rule: csi_inside")
    eq(tk.splices, [(1, 2)], "Ghostty's rule: csi_inside splice")
    toks, tk = tokenize([b"A\xf4\x1b[1m\x8e\x1b[22m\xbb\x1b[0m\xae\xcc\x85\xcc\x8dZ"])
    eq("".join(t.payload for t in toks if t.kind == PRINT),
       "A\ufffd\ufffd\ufffd\ufffd\u0305\u030dZ",
       "Ghostty's rule: two_splices")
    eq(len(tk.splices), 1, "Ghostty's rule: two_splices splices")
    toks, tk = tokenize([b"A\xe4\x7f\xb8\x96Z"])
    eq("".join(t.payload for t in toks if t.kind == PRINT), "A\ufffd\x7f\ufffd\ufffdZ",
       "Ghostty's rule: del_keeps")
    eq(tk.splices, [], "Ghostty's rule: del_keeps has no splice")
    toks, tk = tokenize([b"A\xe4\x1b[31m\xb8\x96\x1b[mZ"], utf8=utf8_tmux())
    eq(tk.splices, [(1, 2)], "tmux rule: csi_inside splice position")
    try:
        tokenize([b"A"], utf8="x")
    except ValueError:
        pass
    else:
        raise AssertionError("an unknown utf8 rule is accepted")


# ------------------------------------------------------ tmux 3.5a passthrough ---
# The rules tmux 3.5a applies to a DCS tmux; passthrough body (input.c), checked
# against a live tmux 3.5a: the body a pane writes, and what reaches the client.

TMUX_PROBE_STREAMS = {
    # name: (the stream a pane writes, the body tmux 3.5a forwards to the terminal)
    "can": (b"\x1bPtmux;\x1b\x1b_Gi=23;AA\x18BB\x1b\x1b\\\x1b\\", b"\x1b_Gi=23;AA\x18BB\x1b\\"),
    "sub": (b"\x1bPtmux;\x1b\x1b_Gi=24;AA\x1aBB\x1b\x1b\\\x1b\\", b"\x1b_Gi=24;AA\x1aBB\x1b\\"),
    "lone_esc": (b"\x1bPtmux;\x1b\x1b_Gi=25;AA\x1bxBB\x1b\x1b\\\x1b\\", b"\x1b_Gi=25;AAxBB\x1b\\"),
}


def tmux_body_tokens(body, end):
    """What tmux forwards for a body, parsed as a plain stream: every token carries
    the DCS span (0 to end) and via_tmux, and APC tokens are numbered. Returns the
    tokens as tuples and the cuts of that plain parse."""
    from vkitty.tokens import Tokenizer
    inner_tokens = []
    inner = Tokenizer(inner_tokens.append, tmux_passthrough=False)
    inner.feed(body, 0)
    inner.finish()
    out = []
    ordinal = 0
    for tok in inner_tokens:
        number = 0
        if tok.kind == APC:
            number = ordinal
            ordinal += 1
        out.append((tok.kind, tok.payload, 0, end, tok.cut, number, True))
    return out, [(0, kind) for _start, kind in inner.cuts]


def feed_timed(pieces, slow=False, **kwargs):
    """Feed (bytes, t) pairs in order with cumulative offsets; returns (tokens, tokenizer)."""
    from vkitty.tokens import Tokenizer
    out = []
    tk = Tokenizer(out.append, _force_slow=slow, **kwargs)
    off = 0
    for chunk, t in pieces:
        tk.feed(chunk, off, t=t)
        off += len(chunk)
    tk.finish()
    return out, tk


@case("tokens", "tmux_body_controls")
def _tokens_tmux_body_controls():
    """tmux 3.5a input.c: inside a passthrough body CAN and SUB are data, and an ESC
    followed by another byte loses the ESC (the byte is kept, with a warning). The
    tokens of each stream are those of the body tmux forwards, in every chunking."""
    for name, (stream, body) in TMUX_PROBE_STREAMS.items():
        want, want_cuts = tmux_body_tokens(body, len(stream))
        for slow in (False, True):
            for size in (None, 1, 2, 3, 4, 5, 6, 7):
                if size is None:
                    chunks = [stream]
                else:
                    chunks = [stream[i:i + size] for i in range(0, len(stream), size)]
                toks, tk = tokenize(chunks, _force_slow=slow)
                eq(as_tuples(toks), want, "%s tokens (chunk %s, slow %s)" % (name, size, slow))
                eq(tk.cuts, want_cuts, "%s cuts (chunk %s, slow %s)" % (name, size, slow))
                check(not any(kind == "dcs" for _s, kind in tk.cuts), "%s: the DCS itself is cut"
                      % name)
                where = "%s (chunk %s, slow %s)" % (name, size, slow)
                if name == "lone_esc":
                    eq(len(tk.warnings), 1, "lone ESC warnings, " + where)
                    check("lone ESC" in tk.warnings[0] and "0x78" in tk.warnings[0],
                          "lone ESC warning names the byte, %s: %r" % (where, tk.warnings))
                else:
                    eq(tk.warnings, [], "warnings, " + where)


@case("tokens", "tmux_limit")
def _tokens_tmux_limit():
    """tmux 3.5a input_input: the DCS buffer holds at most 1048575 bytes (the
    leading t and tmux; included). The DCS that would store one more is dropped
    whole (input_dcs_dispatch returns on INPUT_DISCARD)."""
    from vkitty import perfclock as pc
    ok = wrap(b"\x1b_Gi=21;" + b"A" * 1048560 + b"\x1b\\")
    over = wrap(b"\x1b_Gi=22;" + b"A" * 1048561 + b"\x1b\\")
    eq(len(b"tmux;" + b"\x1b_Gi=21;" + b"A" * 1048560 + b"\x1b\\"), 1048575, "the edge case size")
    # the chunked streams: one boundary between the two ESCs of the first ESC ESC pair, then
    # 65,536-byte chunks
    eq(ok[7:9], b"\x1b\x1b", "the first ESC ESC pair of the forwarded stream")
    ok_chunks = [ok[:8]] + [ok[i:i + 65536] for i in range(8, len(ok), 65536)]
    stream = over + b"ok"
    eq(stream[7:9], b"\x1b\x1b", "the first ESC ESC pair")
    over_chunks = [stream[:8]] + [stream[i:i + 65536] for i in range(8, len(stream), 65536)]
    # the four timed calls make one try: its value is the slowest, and it is clean when all four are
    calls = ([ok], ok_chunks, [stream], over_chunks)

    def timed_calls():
        results, slowest, clean = [], 0.0, True
        for chunks in calls:
            result, sample = pc.timed(tokenize, chunks)
            results.append(result)
            slowest = max(slowest, sample.wall)
            clean = clean and sample.clean
        return results, slowest, clean
    (first, first_slowest, first_clean) = timed_calls()
    (toks, tk), (toks_chunked, tk_chunked), (toks_over, tk_over), (toks_over_chunked,
                                                                    tk_over_chunked) = first
    eq(kinds_of(toks), [APC], "1,048,575 stored bytes are forwarded")
    eq(toks[0].payload, b"Gi=21;" + b"A" * 1048560, "forwarded payload")
    eq(kinds_of(toks_chunked), [APC], "chunked: 1,048,575 stored bytes are forwarded")
    eq(toks_chunked[0].payload, b"Gi=21;" + b"A" * 1048560, "chunked forwarded payload")
    eq((tk_chunked.discards, tk_chunked.warnings), ([], []),
       "chunked forwarded: no drop, no warning")
    eq(describe(toks_over), [("PRINT", "ok", len(over), len(stream), False)],
       "1,048,576 stored bytes: dropped, the rest is ground text")
    eq(tk_over.discards, [(0, 1048576, "limit")], "discards")
    eq(len(tk_over.warnings), 1, "one warning")
    eq(describe(toks_over_chunked), [("PRINT", "ok", len(over), len(stream), False)],
       "chunked: dropped")
    eq(tk_over_chunked.discards, [(0, 1048576, "limit")], "chunked discards")
    # a slow first try repeats only the timed calls, up to three tries in all
    made = [(first_slowest, first_clean)]

    def measure():
        if made:
            return made.pop()
        _results, slowest, clean = timed_calls()
        return slowest, clean
    verdict, _tries = pc.retry(measure, 0.2)
    limit_note = _perf_limit("tokens/tmux_limit", verdict, "a 1 MiB passthrough body took",
                             lambda v: "%.1f ms" % (v * 1000), "200 ms")

    # the same rule at a 64-byte limit, both paths, chunks of 1 to 7 bytes
    # "\x1b_Gi=10;" is 8 bytes: t and mux; make 5, the ESC ST pair 2, the payload 48
    small_ok = wrap(b"\x1b_Gi=10;" + b"A" * 48 + b"\x1b\\")     # 63 stored bytes
    small_over = wrap(b"\x1b_Gi=10;" + b"A" * 49 + b"\x1b\\")   # 64 stored bytes
    eq(len(b"tmux;" + b"\x1b_Gi=10;" + b"A" * 48 + b"\x1b\\"), 63, "the 63-byte size")
    for slow in (False, True):
        for size in range(1, 8):
            chunks = [small_ok[i:i + size] for i in range(0, len(small_ok), size)]
            toks, tk = tokenize(chunks, _force_slow=slow, _tmux_limit=64)
            eq(kinds_of(toks), [APC], "63 stored bytes forwarded (chunk %d, slow %s)"
               % (size, slow))
            eq(toks[0].payload, b"Gi=10;" + b"A" * 48, "63-byte payload")
            eq(tk.discards, [], "63 stored bytes: no drop")
            chunks = [small_over[i:i + size] for i in range(0, len(small_over), size)]
            toks, tk = tokenize(chunks, _force_slow=slow, _tmux_limit=64)
            eq(kinds_of(toks), [], "64 stored bytes dropped (chunk %d, slow %s)" % (size, slow))
            eq(tk.discards, [(0, 64, "limit")], "64 stored bytes: discards")
    return limit_note


@case("tokens", "tmux_timer")
def _tokens_tmux_timer():
    """tmux 3.5a input_enter_dcs starts a 5 s timer when the DCS opens (ESC P). When it
    fires, input_reset returns the parser to ground and the rest of the input is
    parsed from ground."""
    c1 = b"\x1bPtmux;\x1b\x1b_Gi=1;AA"
    c2 = b"AA\x1b\x1b\\\x1b\\xy"
    for slow in (False, True):
        toks, tk = feed_timed([(c1, 0.0), (c2, 5.5)], slow=slow)
        check(APC not in kinds_of(toks), "5.5 s: no APC token (slow %s)" % slow)
        eq(tk.discards, [(0, 14, "timer")], "5.5 s: discards (slow %s)" % slow)
        check((0, "dcs") in tk.cuts, "5.5 s: the DCS is cut (slow %s)" % slow)
        eq(len(tk.warnings), 1, "5.5 s: one warning")
        from vkitty.tokens import Tokenizer
        fresh_out = []
        fresh = Tokenizer(fresh_out.append, _force_slow=slow)
        fresh.feed(c2, len(c1))
        fresh.finish()
        eq(as_tuples(toks), as_tuples(fresh_out), "5.5 s: chunk 2 is parsed from ground (slow %s)"
           % slow)

        toks, tk = feed_timed([(c1, 0.0), (c2, 4.9)], slow=slow)
        eq(describe(toks), [("APC", b"Gi=1;AAAA", 0, 24, False), ("PRINT", "xy", 24, 26, False)],
           "4.9 s: one APC then PRINT (slow %s)" % slow)
        eq(toks[0].payload, b"Gi=1;AAAA", "4.9 s: APC payload")
        eq((tk.discards, tk.cuts), ([], []), "4.9 s: no drop, no cut (slow %s)" % slow)

        toks2, _ = feed_timed([(c1, None), (c2, None)], slow=slow)
        eq(as_tuples(toks2), as_tuples(toks), "no timestamps: the same as 4.9 s (slow %s)" % slow)
        _tokens_tmux_timer_from_open(slow)


def _tokens_tmux_timer_from_open(slow):
    """tmux starts its 5 s timer when the DCS opens (input_enter_dcs, at ESC P), not at
    the final byte. The four cases of the carried minor 1."""
    from vkitty.tokens import Tokenizer
    # (a) the DCS is still before its final byte when the 5 s are over: reset, the next
    # chunk is parsed from ground, nothing was stored
    head = b"\x1bP"
    rest = b"tmux;\x1b\x1b_Gi=35;AA\x1b\x1b\\\x1b\\xy"
    toks, tk = feed_timed([(head, 0.0), (rest, 6.0)], slow=slow)
    check(not any(t.via_tmux for t in toks), "(a) no via-tmux token (slow %s)" % slow)
    check((0, "dcs") in tk.cuts, "(a) the DCS is cut: %r (slow %s)" % (tk.cuts, slow))
    eq(tk.discards, [(0, 0, "timer")], "(a) discards (slow %s)" % slow)
    eq(len(tk.warnings), 1, "(a) one warning (slow %s)" % slow)
    check("DCS open" in tk.warnings[0] and "before its final byte" in tk.warnings[0],
          "(a) the warning names the open DCS: %r" % tk.warnings)
    fresh_out = []
    fresh = Tokenizer(fresh_out.append, _force_slow=slow)
    fresh.feed(rest, len(head))
    fresh.finish()
    eq(as_tuples(toks), as_tuples(fresh_out), "(a) chunk 2 is parsed from ground (slow %s)" % slow)
    # (b) the same chunks 4 s apart: forwarded
    toks, tk = feed_timed([(head, 0.0), (rest, 4.0)], slow=slow)
    eq([(t.kind, t.payload, t.via_tmux) for t in toks],
       [(APC, b"Gi=35;AA", True), (PRINT, "xy", False)], "(b) forwarded (slow %s)" % slow)
    eq((tk.discards, tk.cuts, tk.warnings), ([], [], []), "(b) no drop (slow %s)" % slow)
    # (c) the DCS opened at 0.0, its final byte came at 4.9 and the end at 5.2: the timer
    # started at the open, so the DCS is dropped (it was forwarded when the timer
    # started at the final byte)
    toks, tk = feed_timed([(head, 0.0), (b"tmux;\x1b\x1b_Gi=37;AA", 4.9),
                           (b"\x1b\x1b\\\x1b\\", 5.2)], slow=slow)
    check(not any(t.via_tmux for t in toks), "(c) dropped, no via-tmux token (slow %s)" % slow)
    eq([d[2] for d in tk.discards], ["timer"], "(c) one timer discard (slow %s)" % slow)
    # (d) the DCS opens in chunk 2, 5.5 s after chunk 1: nothing was open before
    toks, tk = feed_timed([(b"ab\x1b", 0.0),
                           (b"Ptmux;\x1b\x1b_Gi=36;AA\x1b\x1b\\\x1b\\", 5.5)], slow=slow)
    eq([(t.kind, t.payload, t.via_tmux) for t in toks if t.kind in (APC, PRINT)],
       [(PRINT, "ab", False), (APC, b"Gi=36;AA", True)], "(d) forwarded (slow %s)" % slow)
    eq((tk.discards, tk.warnings), ([], []), "(d) no drop (slow %s)" % slow)


@case("tokens", "utf8_tmux_timer_keeps")
def _tokens_utf8_tmux_timer_keeps():
    """Under the tmux rule an unfinished UTF-8 character survives the reset of tmux's 5 s DCS
    timer: the DCS tmux; that opened right after the lead byte is dropped when the next chunk
    comes more than 5 s later, but the character is not, so the continuation bytes in that chunk
    finish it. Both paths, and every split of the second chunk."""
    first = b"A\xe4\x1bPtmux;"
    second = b"\xb8\x96Z"
    for slow in (False, True):
        for sizes in ((3,), (1, 2), (2, 1), (1, 1, 1)):
            pieces = [(first, 0.0)]
            pos = 0
            for size in sizes:
                pieces.append((second[pos:pos + size], 6.0))
                pos += size
            where = "(slow %s, second chunk cut %r)" % (slow, sizes)
            toks, tk = feed_timed(pieces, slow=slow, utf8=utf8_tmux())
            eq("".join(t.payload for t in toks if t.kind == PRINT and not t.via_tmux),
               "A\u4e16Z", "the character survives the timer " + where)
            eq(tk.discards, [(2, 5, "timer")], "the DCS is dropped by the timer " + where)
            eq(len(tk.warnings), 1, "one warning " + where)
            check("tmux timer" in tk.warnings[0], "the warning names the timer: %r %s"
                  % (tk.warnings, where))


@case("tokens", "tmux_nested")
def _tokens_tmux_nested():
    """A DCS tmux; inside a forwarded body is not unwrapped again: tmux forwards the
    body once, and what Ghostty receives is parsed with no passthrough rule. So the
    twice wrapped stream gives the tokens of the once wrapped stream parsed with
    tmux_passthrough=False, each with the outer DCS span, via_tmux and the APC
    ordinals counted."""
    from vkitty.tokens import Token, tmux_wrap
    apc_bytes = b"\x1b_Gi=40;AAAA\x1b\\"
    inner = tmux_wrap(apc_bytes)
    nested = tmux_wrap(inner)

    def expected(ref, span):
        out = []
        ordinal = 0
        for tok in ref:
            number = 0
            if tok.kind == APC:
                number = ordinal
                ordinal += 1
            out.append(Token(tok.kind, tok.payload, 0, span, tok.cut, number, True))
        return out

    ref, _ = tokenize([inner], tmux_passthrough=False)
    check(ref, "the reference parse has tokens")
    want = expected(ref, len(nested))
    for slow in (False, True):
        for size in range(1, 8):
            chunks = [nested[i:i + size] for i in range(0, len(nested), size)]
            toks, tk = tokenize(chunks, _force_slow=slow)
            eq(as_tuples(toks), as_tuples(want), "nested tokens (chunk %d, slow %s)" % (size, slow))
        toks, tk = tokenize([nested], _force_slow=slow)
        eq(as_tuples(toks), as_tuples(want), "nested tokens whole (slow %s)" % slow)
        eq((tk.discards, tk.warnings), ([], []), "nested: no drop, no warning (slow %s)" % slow)
    # two APCs in the inner body: the ordinals count the APC tokens only
    two_inner = tmux_wrap(apc_bytes + apc_bytes)
    two = tmux_wrap(two_inner)
    ref2, _ = tokenize([two_inner], tmux_passthrough=False)
    want2 = expected(ref2, len(two))
    eq([t.ordinal for t in want2 if t.kind == APC], [0, 1], "two APCs count 0 and 1")
    for slow in (False, True):
        toks, _ = tokenize([two], _force_slow=slow)
        eq(as_tuples(toks), as_tuples(want2), "two APCs (slow %s)" % slow)


@case("tokens", "tmux_not_mux")
def _tokens_tmux_not_mux():
    """tmux 3.5a input_dcs_dispatch forwards only a body whose data starts with tmux;.
    Any other DCS with final t is consumed without a token, and CAN inside the prefix
    is data (no abort)."""
    for slow in (False, True):
        stream = b"\x1bPtmuy;abc\x1b\\de"
        toks, tk = tokenize([stream], _force_slow=slow)
        eq(describe(toks), [("PRINT", "de", len(stream) - 2, len(stream), False)],
           "tmuy: no token, ground text after (slow %s)" % slow)
        eq(tk.discards, [(0, 8, "not_tmux")], "tmuy: discards (slow %s)" % slow)
        eq(len(tk.warnings), 1, "tmuy: one warning")
        toks, tk = tokenize([b"\x1bPtm\x18ux;\x1b\\"], _force_slow=slow)
        eq(kinds_of(toks), [], "CAN in the prefix: no token, no EXEC (slow %s)" % slow)
        eq(tk.discards, [(0, 6, "not_tmux")], "CAN in the prefix: discards (slow %s)" % slow)
        eq(tk.cuts, [], "CAN in the prefix: no cut")


@case("tokens", "dcs_param_cap")
def _tokens_dcs_param_cap():
    """Parser.zig dcs_passthrough hook: with 24 separators already read (MAX_PARAMS
    24) the DCS is dropped; 23 separators leave room and the DCS is kept."""
    ok = b"\x1bP" + b"1;" * 23 + b"|x\x1b\\"
    dropped = b"\x1bP" + b"1;" * 24 + b"|x\x1b\\"
    for slow in (False, True):
        toks, _ = tokenize([ok], _force_slow=slow)
        eq(kinds_of(toks), [DCS], "23 separators: one DCS (slow %s)" % slow)
        eq(toks[0].payload[3], b"x", "23 separators: data")
        toks, tk = tokenize([dropped], _force_slow=slow)
        eq(kinds_of(toks), [], "24 separators: no DCS (slow %s)" % slow)
        check(any("too many parameters" in w for w in tk.warnings), "24 separators: warning")


@case("tokens", "c1_st")
def _tokens_c1_st():
    """Parser.zig parse_table: 0x9C (C1 ST) is an anywhere transition to ground, so it
    ends an APC or a DCS uncut. Inside an OSC string it is data (osc_string takes 0x20
    to 0xFF)."""
    for slow in (False, True):
        data = b"\x1b_Gabc\x9c"
        toks, tk = tokenize([data], _force_slow=slow)
        eq(as_tuples(toks), [(APC, b"Gabc", 0, 7, False, 0, False)], "APC ended by 0x9C (slow %s)"
           % slow)
        eq(tk.cuts, [], "APC ended by 0x9C is not cut")
        toks, tk = tokenize([b"\x1bPq#0\x9c"], _force_slow=slow)
        eq(kinds_of(toks), [DCS], "DCS ended by 0x9C: one token")
        eq((toks[0].payload[3], toks[0].cut), (b"#0", False), "DCS ended by 0x9C: data and cut")
        eq(tk.cuts, [], "DCS ended by 0x9C is not cut")
        data = b"\x1b]0;t\x9cz\x07"
        toks, tk = tokenize([data], _force_slow=slow)
        eq(as_tuples(toks), [(OSC, (b"0;t\x9cz", b"\x07"), 0, len(data), False, 0, False)],
           "OSC keeps 0x9C as data (slow %s)" % slow)


@case("tokens", "csi_param_c0_high")
def _tokens_csi_param_c0_high():
    """stream.zig nextNonUtf8, csi_param fast path: bytes 0x10 to 0x17, 0x19 and 0x1C
    to 0x1F are ignored inside a CSI; 0x00 to 0x0F execute."""
    for slow in (False, True):
        data = b"\x1b[1\x10\x17\x19\x1c\x1f2m"
        toks, _ = tokenize([data], _force_slow=slow)
        eq(as_tuples(toks), [(CSI, (b"12", b"", ord("m")), 0, len(data), False, 0, False)],
           "ignored C0 bytes inside a CSI (slow %s)" % slow)
        toks, _ = tokenize([b"\x1b[1\x052m"], _force_slow=slow)
        eq(kinds_of(toks), [EXEC, CSI], "C0 0x05 executes inside a CSI (slow %s)" % slow)
        eq((toks[0].payload, toks[1].payload), (5, (b"12", b"", ord("m"))), "payloads (slow %s)"
           % slow)


def _tui_stream(size, seed):
    """Nvim-like redraw output: cursor moves, SGR, short text runs, 10 % UTF-8."""
    rnd = random.Random(seed)
    sgrs = [b"\x1b[0m", b"\x1b[38;5;%dm", b"\x1b[1;34m", b"\x1b[48;2;30;30;46m",
            b"\x1b[4:3m\x1b[58:2::9:9:9m"]
    words = [b"local ", b"function ", b"return ", b"self.", b"print(", b"x = 1 ", b"\"string\" ",
             b"-- note "]
    utf8 = ["\u00e9\u4e16\u754c", "\u2192 arrow ", "\U0001f600 ", "\ud55c\uad6d\uc5b4 ", "\u00f1 "]
    parts = []
    total = 0
    while total < size:
        row = rnd.randrange(1, 51)
        col = rnd.randrange(1, 161)
        piece = [b"\x1b[%d;%dH" % (row, col)]
        sgr = rnd.choice(sgrs)
        piece.append(sgr % rnd.randrange(256) if b"%d" in sgr else sgr)
        for _ in range(rnd.randrange(1, 5)):
            if rnd.random() < 0.1:
                piece.append(rnd.choice(utf8).encode("utf-8"))
            else:
                piece.append(rnd.choice(words))
        if rnd.random() < 0.05:
            piece.append(b"\x1b[K")
        chunk = b"".join(piece)
        parts.append(chunk)
        total += len(chunk)
    return b"".join(parts)[:size]


def _timed_pieces(feed, data, size=131072, offsets=False):
    """Feed data to feed(piece) (feed(piece, offset) with offsets) in pieces of at most `size`
    bytes, each through perfclock.timed with its length as the work. Returns the samples."""
    from vkitty import perfclock as pc
    samples = []
    for off in range(0, len(data), size):
        piece = data[off:off + size]
        if offsets:
            _, sample = pc.timed(feed, piece, off, units=len(piece))
        else:
            _, sample = pc.timed(feed, piece, units=len(piece))
        samples.append(sample)
    return samples


def _mb_s(rate):
    return "%.1f MB/s" % (rate / 1e6)


def _ms(seconds):
    return "%d ms" % round(seconds * 1000)


def _ms3(millis):
    return "%.2f ms" % millis


@case("perf", "tokens")
def _perf_tokens():
    # a stream is fed in pieces (131,072 bytes for the TUI text, 1,000,000 for the APC body), each
    # timed on its own, and the rate is decided by perfclock (a busy host is not a failure)
    from vkitty import perfclock as pc
    from vkitty.tokens import Tokenizer
    mb = 1000000
    tui = _tui_stream(8 * mb, 7)
    chunked, whole = [0] * 8, [0] * 8

    def count_chunked(tok):
        chunked[tok.kind] += 1

    def count_whole(tok):
        whole[tok.kind] += 1

    samples = _timed_pieces(Tokenizer(count_chunked).feed, tui, 131072, offsets=True)
    Tokenizer(count_whole).feed(tui, 0)
    # the chunking changes nothing but where a run of text is cut: a PRINT token is one per feed
    # call at most, so each piece boundary inside text adds one PRINT token
    eq(chunked[EXEC:], whole[EXEC:], "every token that is not text, by kind, chunked and whole")
    cuts = chunked[PRINT] - whole[PRINT]
    check(0 <= cuts < len(samples), "the chunked feed has %d more text tokens than the whole one "
          "(at most one per piece boundary, %d)" % (cuts, len(samples) - 1))
    tui_note = _perf_limit("perf/tokens", pc.rate_verdict(samples, 10e6), "TUI", _mb_s,
                           "10 MB/s (budget 20)")

    chunk = b"Q" * 4096
    body = b"".join(apc(b"Ga=t,f=100,m=1;" + chunk) for _ in range(8000))
    check(len(body) >= 32 * mb, "APC stream is too small")
    samples = _timed_pieces(Tokenizer(count_whole).feed, body, 1000000, offsets=True)
    apc_note = _perf_limit("perf/tokens", pc.rate_verdict(samples, 150e6), "APC", _mb_s,
                           "150 MB/s (budget 300)")
    return "%s over %d MB; %s over %d MB" % (tui_note, len(tui) // mb, apc_note,
                                              len(body) // mb)


# ---------------------------------------------------------------- widths ---

@case("widths", "basics")
def _widths_basics():
    from vkitty.widths import wcwidth
    table = [
        (0x61, 1), (0x4E16, 2), (0x0305, 0), (0x10EEEE, 1), (0x1F600, 2),
        (0x200D, 0), (0xFE0F, 0), (0x00AD, 1), (0x2500, 1), (0x2713, 1),
        (0x3000, 2), (0x1F1E6, 2), (0x1F3FB, 2), (0x0600, 1), (0x0903, 1),
        (0x1160, 0), (0x11A8, 0), (0x20E3, 0), (0x2E3B, 2), (0x00E9, 1),
    ]
    eq(len(table), 20, "table size")
    for cp, want in table:
        eq(wcwidth(cp), want, "wcwidth(U+%04X)" % cp)


@case("widths", "grapheme_break")
def _widths_grapheme_break():
    from vkitty.widths import grapheme_break, props

    def breaks(cps):
        state = 0
        out = []
        for a, b in zip(cps, cps[1:]):
            is_break, state = grapheme_break(a, b, state)
            out.append(is_break)
        return out

    eq(breaks([0x0065, 0x0301]), [False], "e + combining acute")
    eq(breaks([0x1F468, 0x200D, 0x1F469]), [False, False], "ZWJ sequence, state carried")
    eq(breaks([0x1F1E6, 0x1F1E8, 0x1F1EA]), [False, True], "flag pair then a break")
    eq(breaks([0x0061, 0x0062]), [True], "a and b")
    check(props(0x2764)[3] is True, "U+2764 has an emoji variation sequence")
    check(props(0x0041)[3] is False, "U+0041 has none")


@case("widths", "props_fields")
def _widths_props_fields():
    """props(cp) = (width, zero_in_grapheme, gb_no_control, emoji_vs_base), with the
    wcwidth.zig rules: marks, emoji modifiers, prepend and Me are zero in grapheme;
    ordinary wide and ambiguous code points are not."""
    from vkitty.widths import GB_INDEX, props
    cases = [
        (0x0305, 0, True, "Mn is zero in grapheme"),
        (0x0041, 1, False, "A"),
        (0x1F3FB, 2, True, "emoji modifier: width 2, zero in grapheme"),
        (0x0600, 1, True, "prepend: width 1, zero in grapheme"),
        (0x20E3, 0, True, "Me keycap"),
        (0x1160, 0, True, "default ignorable Hangul filler"),
        (0x2E3B, 2, False, "three-em dash, capped at 2"),
        (0x1F1E6, 2, False, "regional indicator"),
        (0x4E16, 2, False, "CJK ideograph"),
    ]
    for cp, width, zero, label in cases:
        got = props(cp)
        eq((got[0], got[1]), (width, zero), "%s U+%04X" % (label, cp))
    eq(props(0x1F1E6)[2], GB_INDEX["regional_indicator"], "gb class of a regional indicator")
    eq(props(0x200D)[2], GB_INDEX["zwj"], "gb class of ZWJ")
    eq(props(0x0061)[2], GB_INDEX["other"], "gb class of a")
    eq(props(0x110000), (1, True, GB_INDEX["other"], False), "fallback above U+10FFFF")


@case("widths", "table_rule")
def _widths_table_rule():
    """The precomputed (state, gb1, gb2) table equals the rule, for every key."""
    from vkitty import widths
    for state in range(5):
        for gb1 in range(len(widths.GB_NAMES)):
            for gb2 in range(len(widths.GB_NAMES)):
                want_break, want_state = widths.compute_grapheme_break(gb1, gb2, state)
                got_break, got_state = widths.grapheme_break_classes(gb1, gb2, state)
                eq((got_break, got_state), (want_break, want_state),
                   "state %d gb %d %d" % (state, gb1, gb2))


# ------------------------------------------------------------------ vt ---
# The VT emulator (vkitty.vt) against Ghostty 1.3.1's own behaviour. The grapheme
# cases are the Terminal.zig tests named in each docstring, with the same input
# and the cells and cursor those tests assert.

def _term(cols, rows, data=b"", grapheme=True, hop="none"):
    from vkitty.vt import Terminal
    t = Terminal(cols, rows, grapheme_cluster=grapheme, hop=hop)
    if data:
        t.feed(data)
    return t


def _cp_bytes(cps):
    return "".join(chr(c) for c in cps).encode("utf-8")


def _row(snap, y):
    """The row's characters with trailing blanks dropped (spacer tails are skipped)."""
    return snap.row_text(y).rstrip(" ")


def _tmux(snap):
    """The tmux hop's counters (vkitty.vt.tmux_counts)."""
    from vkitty.vt import tmux_counts
    return tmux_counts(snap)


def _cell(snap, x, y):
    return snap.cells[y][x]


def _cursor_xy(snap):
    return (snap.cursor[0], snap.cursor[1])


@case("vt", "wrap")
def _vt_wrap():
    snap = _term(5, 3, b"abcdefg").snapshot()
    eq(_row(snap, 0), "abcde", "row 0 after the wrap")
    eq(_row(snap, 1), "fg", "row 1 after the wrap")
    eq(_cursor_xy(snap), (2, 1), "cursor after abcdefg")
    snap = _term(5, 3, b"abcde\r").snapshot()
    eq(_cursor_xy(snap), (0, 0), "CR keeps the pending wrap off")
    eq(_row(snap, 1), "", "no wrap after abcde and CR")


@case("vt", "wide_last_col")
def _vt_wide_last_col():
    snap = _term(5, 3, "abcd\u4e16".encode("utf-8")).snapshot()
    eq(_row(snap, 0), "abcd", "row 0 holds abcd; the spacer head at column 4 reads blank")
    eq(_cell(snap, 4, 0)[2], 1, "the spacer head at the last column is width 1")
    eq(_cell(snap, 0, 1)[2], 2, "the wide character is a head on row 1")
    eq(_cell(snap, 1, 1)[2], 0, "and its tail follows it")
    eq(_row(snap, 1), "\u4e16", "row 1 text")
    eq(_cursor_xy(snap), (2, 1), "cursor after the wide character")


@case("vt", "combining_and_placeholder")
def _vt_combining_and_placeholder():
    snap = _term(10, 2, "e\u0301".encode("utf-8")).snapshot()
    eq(_cell(snap, 0, 0)[0], "e\u0301", "a combining mark joins its base in one cell")
    eq(_cursor_xy(snap), (1, 0), "the mark takes no cell")
    snap = _term(10, 2, "\U0010EEEE\u0305\u030d".encode("utf-8")).snapshot()
    text, _sid, width = _cell(snap, 0, 0)
    eq(text, "\U0010EEEE\u0305\u030d", "a placeholder with two diacritics is one cell")
    eq(width, 1, "placeholder width")
    eq(_cursor_xy(snap), (1, 0), "cursor after the placeholder")


@case("vt", "region_scroll")
def _vt_region_scroll():
    data = b"".join(b"row%d\r\n" % i for i in range(5)).rstrip(b"\r\n")
    t = _term(8, 5, data)
    t.feed(b"\x1b[2;4r\x1b[4;1H\n")       # margins rows 2..4, LF at the bottom margin
    snap = t.snapshot()
    eq(_row(snap, 0), "row0", "the row above the region is untouched")
    eq(_row(snap, 1), "row2", "row 2 moves up inside the region")
    eq(_row(snap, 2), "row3", "row 3 moves up inside the region")
    eq(_row(snap, 3), "", "the bottom margin row is blank")
    eq(_row(snap, 4), "row4", "the row below the region is untouched")


@case("vt", "bce")
def _vt_bce():
    snap = _term(6, 2, b"ab\x1b[41m\x1b[K").snapshot()
    eq(_row(snap, 0), "ab", "text before the erase stays")
    style = snap.styles[_cell(snap, 3, 0)[1]]
    eq(style[1], 1, "erased cells take the background colour (palette 1)")
    eq(snap.styles[_cell(snap, 0, 0)[1]], (None, None, None, 0), "the text keeps the default style")


@case("vt", "alt_screen")
def _vt_alt_screen():
    t = _term(10, 3, b"primary\x1b[1;4H")
    t.feed(b"\x1b[?1049h")
    snap = t.snapshot()
    eq(_row(snap, 0), "", "the alternate screen starts cleared")
    t.feed(b"alt")
    t.feed(b"\x1b[?1049l")
    snap = t.snapshot()
    eq(_row(snap, 0), "primary", "leaving 1049 restores the primary text")
    eq(_cursor_xy(snap), (3, 0), "and the primary cursor")


@case("vt", "probe_cut_prints_tail")
def _vt_probe_cut_prints_tail():
    stream = (b"\x1b[18;\x1bPtmux;\x1b\x1b_Ga=d,d=i,i=5,q=2\x1b\x1b\\\x1b\\5H")
    from vkitty.vt import HOP_TMUX
    t = _term(20, 5, stream, hop=HOP_TMUX)
    snap = t.snapshot()
    eq(_row(snap, 0), "5H", "the cut CSI prints nothing and the tail prints at the cursor")
    eq(_cursor_xy(snap), (2, 0), "cursor after 5H")
    eq(snap.stats["apc"], 1, "the passthrough APC reached the graphics layer")
    eq(snap.stats["cuts"], 1, "one sequence was cut")


@case("vt", "sgr_forms")
def _vt_sgr_forms():
    snap = _term(20, 2, b"\x1b[4:3mA\x1b[0m\x1b[58:2::4:5:6mB\x1b[0m\x1b[38;2;1;2;3;48:5:200mC"
                         b"\x1b[0mD").snapshot()
    eq(_style_dict(snap, 0, 0), {"u": "curly"}, "4:3 is a curly underline")
    eq(_style_dict(snap, 1, 0), {"ul": "#040506"}, "58:2::r:g:b with the colour space")
    eq(_style_dict(snap, 2, 0), {"fg": "#010203", "bg": 200}, "semicolon rgb fg and 256 bg")
    eq(_style_dict(snap, 3, 0), {}, "reset clears every attribute")


def _style_dict(snap, x, y):
    from vkitty.style import style_to_dict
    return style_to_dict(snap.styles[_cell(snap, x, y)[1]])


@case("vt", "rep")
def _vt_rep():
    snap = _term(10, 2, b"x\x1b[3b").snapshot()
    eq(_row(snap, 0), "xxxx", "REP repeats the last printed character")


@case("vt", "ground_c0")
def _vt_ground_c0():
    snap = _term(10, 2, b"a\x18b\x7fc").snapshot()
    eq([_cell(snap, x, 0)[0] for x in range(5)], ["a", "\x18", "b", "\x7f", "c"],
       "CAN and DEL print in ground, as Ghostty prints them")
    eq(_cursor_xy(snap), (5, 0), "cursor after five cells")
    snap = _term(10, 2, b"\x1b[5\x18x").snapshot()
    eq(_row(snap, 0), "x", "CAN inside a CSI aborts it, and x prints at column 0")
    eq(_cursor_xy(snap), (1, 0), "cursor after x")


@case("vt", "c1_exec")
def _vt_c1_exec():
    t = _term(5, 3, b"a\x1b[3;1H")               # cursor on the last row
    t.feed(b"\x1b[1\x84")                        # C1 IND leaves the CSI and executes
    snap = t.snapshot()
    eq(_row(snap, 0), "", "IND on the last row scrolls, so the a leaves the screen")
    eq(_row(snap, 1), "", "the second row is blank")
    eq(_cursor_xy(snap), (0, 2), "the cursor stays on the last row")
    t = _term(5, 3, b"a\x1b[1;1H")
    t.feed(b"\x1b_X\x8d")                        # the APC ends at C1 RI, which runs
    snap = t.snapshot()
    eq(_row(snap, 0), "", "RI at the top scrolls the screen down")
    eq(_row(snap, 1), "a", "the row that held a moved down one line")


# Ghostty's tests move the cursor (CUF) before printing the second code point
GRAPHEME_PREFIX = {"vs16_next_line": b"\x1b[2C", "vs16_pending_wrap": b"\x1b[1C"}

@case("vt", "erase_pending_wrap")
def _vt_erase_pending_wrap():
    # Ghostty's EL clears from the cursor, which sits on the last column with the
    # pending wrap set (tmux leaves that cell: its cursor is past the edge).
    snap = _term(5, 2, b"xxxxx\x1b[K").snapshot()
    eq(_row(snap, 0), "xxxx", "the last column is erased")
    eq(_cursor_xy(snap), (4, 0), "EL keeps the cursor on the last column")


@case("vt", "cursor_left_from_pending")
def _vt_cursor_left_from_pending():
    # CUB from the pending-wrap state moves one column left of the last column.
    snap = _term(5, 2, b"xxxxx\x1b[Dy").snapshot()
    eq(_row(snap, 0), "xxxyx", "y lands on column 3, the column before the last")
    eq(_cursor_xy(snap), (4, 0), "cursor after y")


@case("vt", "wide_overwrite_bce")
def _vt_wide_overwrite_bce():
    # Overwriting the head of a wide character clears its tail with the current
    # background (Screen.clearCells uses the cursor's bgCell).
    snap = _term(5, 2, "\u4e16\x1b[41m\x1b[1;1Ha".encode("utf-8")).snapshot()
    eq(_cell(snap, 0, 0)[0], "a", "the head is overwritten")
    eq(_cell(snap, 0, 0)[2], 1, "and is narrow now")
    eq(snap.styles[_cell(snap, 1, 0)[1]][1], 1, "the old tail is blank on background 1")


@case("vt", "spacer_head_pen")
def _vt_spacer_head_pen():
    # The spacer head written when a wide character wraps takes the pen (printCell).
    snap = _term(3, 3, b"\x1b[44mab\xe4\xb8\x96").snapshot()
    eq(_cell(snap, 2, 0)[2], 1, "the spacer head reads as width 1")
    eq(snap.styles[_cell(snap, 2, 0)[1]][1], 4, "with the pen's background")
    eq(_row(snap, 1), "\u4e16", "the wide character is on the next row")


@case("vt", "rep_across_sequences")
def _vt_rep_across_sequences():
    # REP repeats the last printed character even after other sequences (Ghostty
    # keeps previous_char; tmux only repeats right after a printed character).
    snap = _term(10, 2, b"x\x1b[3b\x1b[2b").snapshot()
    eq(_row(snap, 0), "xxxxxx", "1 + 3 + 2 characters")


@case("vt", "cht_and_relative_moves")
def _vt_cht_and_relative_moves():
    # CHT, HPR and VPR, which tmux 3.5a does not implement (Ghostty does).
    snap = _term(20, 3, b"\x1b[Ia\x1b[2ab\x1b[1ec").snapshot()
    eq(_cell(snap, 8, 0)[0], "a", "CHT moves to the next tab stop")
    eq(_cell(snap, 11, 0)[0], "b", "HPR 2 moves right two columns")
    eq(_cell(snap, 12, 1)[0], "c", "VPR 1 moves down one row, the column kept")


@case("vt", "british_pound")
def _vt_british_pound():
    snap = _term(5, 2, b"\x1b(A#\x1b(B#").snapshot()
    eq(_cell(snap, 0, 0)[0], "\u00a3", "ESC ( A maps # to the pound sign")
    eq(_cell(snap, 1, 0)[0], "#", "ESC ( B restores ASCII")


@case("vt", "dcs_can_resumes")
def _vt_dcs_can_resumes():
    # A DCS that is not tmux; is ignored, and CAN ends it, so the text after prints.
    snap = _term(10, 2, b"\x1bPq#0\x18AB").snapshot()
    eq(_row(snap, 0), "AB", "CAN aborts the DCS in Ghostty")


@case("vt", "compare_detects_difference")
def _vt_compare_detects_difference():
    # The differential harness must notice a real difference: a bold cell against
    # a capture that has no bold.
    from vkitty.grid_tmux import compare, parse_capture
    from vkitty.vt import Terminal
    emu = Terminal(4, 1)
    emu.feed(b"\x1b[1mab")
    cap = parse_capture("ab  \n", 4, 1)
    diffs = compare(emu.snapshot(), cap, cursor=(2, 0))
    check(any("b" in d and "emulator" in d for d in diffs), "bold difference not reported: %r"
          % diffs)
    same = Terminal(4, 1)
    same.feed(b"ab")
    eq(compare(same.snapshot(), cap, cursor=(2, 0)), [], "identical screens differ")
    # a difference in a style key that sorts after the first one is reported too: red and bold
    # in the emulator, red only in the capture
    emu = Terminal(4, 1)
    emu.feed(b"\x1b[31;1mab")
    cap = parse_capture("\x1b[31mab\x1b[0m  \n", 4, 1)
    check(compare(emu.snapshot(), cap, cursor=(2, 0)),
          "bold on a red cell is not reported when the colour agrees")


# The emulator and the capture parser share the SGR decoder and the DEC graphics
# table, so the battery cannot test them against tmux alone: these cases state the
# expected values by hand (from the SGR and VT100 references, not from the code).
SGR_TABLE = (
    ("1", {"b": True}), ("2", {"d": True}), ("3", {"i": True}), ("4", {"u": "single"}),
    ("4:0", {}), ("4:1", {"u": "single"}), ("4:2", {"u": "double"}), ("4:3", {"u": "curly"}),
    ("4:4", {"u": "dotted"}), ("4:5", {"u": "dashed"}), ("21", {"u": "double"}),
    ("5", {"blink": True}), ("7", {"r": True}), ("8", {"inv": True}), ("9", {"s": True}),
    ("53", {"o": True}), ("1;3;4", {"b": True, "i": True, "u": "single"}),
    ("31", {"fg": 1}), ("90", {"fg": 8}), ("41", {"bg": 1}), ("100", {"bg": 8}),
    ("97", {"fg": 15}), ("107", {"bg": 15}),
    ("38;5;1", {"fg": 1}), ("38;5;100", {"fg": 100}), ("48;5;4", {"bg": 4}),
    ("38;2;255;128;0", {"fg": "#ff8000"}), ("48;2;10;20;30", {"bg": "#0a141e"}),
    ("38:5:9", {"fg": 9}), ("48:5:33", {"bg": 33}),
    ("38:2::1:2:3", {"fg": "#010203"}), ("48:2::200:100:50", {"bg": "#c86432"}),
    ("38:2:7:8:9", {"fg": "#070809"}),
    ("58;5;196;4", {"ul": 196, "u": "single"}),
    ("58;2;0;255;0;4:3", {"ul": "#00ff00", "u": "curly"}),
    ("58:2::255:0:0;4", {"ul": "#ff0000", "u": "single"}),
    ("1;38;5;160;48;5;17", {"b": True, "fg": 160, "bg": 17}),
)


@case("vt", "sgr_table")
def _vt_sgr_table():
    from vkitty.style import apply_sgr, style_to_dict
    for params, want in SGR_TABLE:
        got = style_to_dict(apply_sgr((None, None, None, 0), params.encode("ascii")))
        eq(got, want, "SGR %s" % params)


# DEC special graphics, from the VT100 character chart: the letter sent in the set
# and the code point it draws (0x5F and everything outside the set stay as they are).
DEC_CHART = (
    ("`", 0x25C6), ("a", 0x2592), ("b", 0x2409), ("c", 0x240C), ("d", 0x240D), ("e", 0x240A),
    ("f", 0x00B0), ("g", 0x00B1), ("h", 0x2424), ("i", 0x240B), ("j", 0x2518), ("k", 0x2510),
    ("l", 0x250C), ("m", 0x2514), ("n", 0x253C), ("o", 0x23BA), ("p", 0x23BB), ("q", 0x2500),
    ("r", 0x23BC), ("s", 0x23BD), ("t", 0x251C), ("u", 0x2524), ("v", 0x2534), ("w", 0x252C),
    ("x", 0x2502), ("y", 0x2264), ("z", 0x2265), ("{", 0x03C0), ("|", 0x2260), ("}", 0x00A3),
    ("~", 0x00B7),
)


@case("vt", "dec_special_table")
def _vt_dec_special_table():
    from vkitty.vt import Terminal
    for letter, glyph in DEC_CHART:
        t = Terminal(4, 1)
        t.feed(b"\x1b(0" + letter.encode("ascii"))
        eq(t.snapshot().cells[0][0][0], chr(glyph), "ESC ( 0 then %r" % letter)
    t = Terminal(4, 1)
    t.feed(b"\x1b(0_")
    eq(t.snapshot().cells[0][0][0], "_", "0x5F is not in the set")


@case("vt", "il_dl_outside_margins")
def _vt_il_dl_outside_margins():
    # Insert and delete lines with the cursor above the margins change nothing
    # (Terminal.insertLines and deleteLines return early outside the region).
    t = _term(4, 4, b"aaaa\r\nbbbb\r\ncccc\r\ndddd")
    t.feed(b"\x1b[3;4r\x1b[1;1H\x1b[2L\x1b[2M")
    snap = t.snapshot()
    eq([_row(snap, y) for y in range(4)], ["aaaa", "bbbb", "cccc", "dddd"],
       "rows above the region are kept")


@case("vt", "ech_dch_reset_pending_wrap")
def _vt_ech_dch_reset_pending_wrap():
    # Ghostty's eraseChars and deleteChars call cursorResetWrap (Terminal.zig, Screen.zig),
    # which clears the pending-wrap flag, so the next print lands on the last column.
    snap = _term(5, 2, b"abcde\x1b[XZ").snapshot()
    eq(_row(snap, 0), "abcdZ", "ECH clears the last column, and Z prints there")
    eq(_row(snap, 1), "", "Z does not wrap to the next row")
    eq(_cursor_xy(snap), (4, 0), "cursor stays on the last column")
    snap = _term(5, 2, b"abcde\x1b[PZ").snapshot()
    eq(_row(snap, 0), "abcdZ", "DCH clears the last column, and Z prints there")
    eq(_row(snap, 1), "", "Z does not wrap after DCH")
    eq(_cursor_xy(snap), (4, 0), "cursor after DCH and Z")


@case("vt", "erase_clears_wrapped_spacer_head")
def _vt_erase_clears_wrapped_spacer_head():
    # cursorResetWrap clears the spacer head that a wrapped wide character left in the last
    # column, with the cursor's current background (Screen.blankCell): the default here.
    snap = _term(5, 2, "\x1b[44mabcd\u4e16\x1b[0m\x1b[1;1H\x1b[X".encode("utf-8")).snapshot()
    eq(_cell(snap, 4, 0)[0], " ", "the spacer head at the last column is blank")
    eq(snap.styles[_cell(snap, 4, 0)[1]][1], None, "with the default background, not blue")


@case("vt", "dch_splits_wide_boundary")
def _vt_dch_splits_wide_boundary():
    # DCH calls splitCellBoundary at x + count: the wide character that the deleted run
    # ends inside is cleared, so its tail does not survive at column 0.
    snap = _term(5, 1, "a\u4e16bc".encode("utf-8") + b"\x1b[1;1H\x1b[2P").snapshot()
    eq([_cell(snap, x, 0)[0] for x in range(3)], [" ", "b", "c"], "blank, then b and c")
    eq([_cell(snap, x, 0)[2] for x in range(3)], [1, 1, 1], "every cell is narrow")


@case("vt", "ich_on_wide_tail")
def _vt_ich_on_wide_tail():
    # ICH with the cursor on a spacer tail clears the pair to its left and the tail
    # (insertBlanks clears (left - 1)[0..2]), so the tail is not shifted away from its head.
    snap = _term(10, 1, "a\u4e16b\x1b[1;3H\x1b[@".encode("utf-8")).snapshot()
    eq([_cell(snap, x, 0)[0] for x in range(5)], ["a", " ", " ", " ", "b"], "a, three blanks, b")
    eq([_cell(snap, x, 0)[2] for x in range(5)], [1, 1, 1, 1, 1], "every cell is narrow")


@case("vt", "ich_wide_to_last_column")
def _vt_ich_wide_to_last_column():
    # A wide character that ICH shifts onto the last column is cleared before the shift
    # (insertBlanks clears the last shifted wide cell), so no head is left without its tail.
    snap = _term(10, 1, "abcdefgh\u4e16\x1b[1;1H\x1b[@".encode("utf-8")).snapshot()
    eq([_cell(snap, x, 0)[0] for x in range(10)],
       [" ", "a", "b", "c", "d", "e", "f", "g", "h", " "], "the wide character is cleared")
    eq(_cell(snap, 9, 0)[2], 1, "the last column is narrow")
    eq(_cursor_xy(snap), (0, 0), "ICH keeps the cursor")


@case("vt", "lnm_does_not_change_output_lf")
def _vt_lnm_does_not_change_output_lf():
    # The app's stream handler runs LF as terminal.index() only (termio/stream_handler.zig),
    # so LNM (mode 20) adds no carriage return to output.
    snap = _term(5, 2, b"\x1b[20hab\ncd").snapshot()
    eq(_row(snap, 1), "  cd", "cd starts under the column the cursor was in")


@case("vt", "sync_flag_tracks_2026")
def _vt_sync_flag_tracks_2026():
    # DECSET 2026 sets the flag that Recording reads; a snapshot taken inside the update
    # warns. DECRST clears the flag, and RIS clears it as well.
    t = _term(5, 2, b"\x1b[?2026h")
    check(t.sync, "DECSET 2026 sets the flag")
    snap = t.snapshot()
    check(any("2026" in w for w in snap.warnings), "a snapshot inside the update warns: %r"
          % snap.warnings)
    t.feed(b"\x1b[?2026l")
    check(not t.sync, "DECRST 2026 clears the flag")
    eq(len(t.snapshot().warnings), len(snap.warnings), "no new warning outside the update")
    t.feed(b"\x1b[?2026h\x1bc")
    check(not t.sync, "RIS clears the flag")


@case("vt", "ris_restores_grapheme_default")
def _vt_ris_restores_grapheme_default():
    # RIS restores the configured default of mode 2027, which Termio turns on (Ghostty's
    # modes.reset()). A constructor value of off is the default that RIS keeps.
    snap = _term(5, 2, b"\x1b[?2027l\x1bc\xe2\x9d\xa4\xef\xb8\x8f").snapshot()
    eq(_cell(snap, 0, 0)[2], 2, "after RIS the heart with VS16 is wide again")
    eq(_cursor_xy(snap), (2, 0), "cursor after the wide heart")
    snap = _term(5, 2, b"\x1bc\xe2\x9d\xa4\xef\xb8\x8f", grapheme=False).snapshot()
    eq(_cell(snap, 0, 0)[2], 1, "a constructor value of off survives RIS: the heart stays narrow")


@case("vt", "ris_resets_screen_and_modes")
def _vt_ris_resets_screen_and_modes():
    t = _term(10, 3, b"\x1b[1;31mtext\x1b[?1049h\x1b[?7l\x1b[3gx\x1bc")
    snap = t.snapshot()
    eq(_row(snap, 0), "", "RIS leaves the alternate screen and clears the primary one")
    eq(_cursor_xy(snap), (0, 0), "cursor home")
    t.feed(b"\tY0123456789ab")
    snap = t.snapshot()
    eq(_cell(snap, 8, 0)[0], "Y", "default tab stops are back")
    eq(snap.styles[_cell(snap, 8, 0)[1]][0], None, "the pen is the default")
    eq(_cell(snap, 9, 0)[0], "0", "autowrap is on again")
    eq(_row(snap, 1), "123456789a", "the next row holds the rest of the line")


@case("vt", "cursor_shape_and_visibility")
def _vt_cursor_shape_and_visibility():
    # DECSCUSR (stream.zig): 0 to 2 block, 3 and 4 underline, 5 and 6 bar; other values are
    # ignored. DECTCEM (mode 25) shows and hides the cursor.
    for seq, shape in ((b"\x1b[5 q", "bar"), (b"\x1b[4 q", "underline"), (b"\x1b[2 q", "block"),
                       (b"\x1b[6 q", "bar"), (b"\x1b[3 q", "underline"), (b"\x1b[0 q", "block")):
        eq(_term(5, 2, seq).snapshot().cursor[3], shape, "DECSCUSR %r" % seq)
    eq(_term(5, 2, b"\x1b[5 q\x1b[9 q").snapshot().cursor[3], "bar",
       "an unknown value changes nothing")
    eq(_term(5, 2).snapshot().cursor[2], True, "the cursor is visible by default")
    eq(_term(5, 2, b"\x1b[?25l").snapshot().cursor[2], False, "DECRST 25 hides it")
    eq(_term(5, 2, b"\x1b[?25l\x1b[?25h").snapshot().cursor[2], True, "DECSET 25 shows it")


@case("vt", "single_shift_g2_g3")
def _vt_single_shift_g2_g3():
    # ESC N (SS2) and ESC O (SS3) print one character from G2 or G3, then GL is used again.
    snap = _term(10, 1, b"\x1b*0\x1bNq" + b"q" + b"\x1b+0\x1bOq" + b"q").snapshot()
    eq(_cell(snap, 0, 0)[0], "\u2500", "SS2 takes q from G2, the DEC graphics horizontal line")
    eq(_cell(snap, 1, 0)[0], "q", "then GL is ASCII again")
    eq(_cell(snap, 2, 0)[0], "\u2500", "SS3 takes q from G3")
    eq(_cell(snap, 3, 0)[0], "q", "and GL is ASCII again")


@case("vt", "alt_screen_exit_details")
def _vt_alt_screen_exit_details():
    # 1049 saves the cursor with its character sets on entry and restores them on exit, so a
    # DEC graphics set selected on the alternate screen is gone afterwards: q prints as q.
    snap = _term(10, 2, b"\x1b[?1049h\x1b(0\x1b[?1049lq").snapshot()
    eq(_cell(snap, 0, 0)[0], "q", "1049 restores the character sets")
    # 1047 clears the alternate screen when it is left: nothing of X is there when it is
    # entered again (with 47, which does not clear, it would still be).
    snap = _term(10, 2, b"\x1b[?1047hX\x1b[?1047l\x1b[?47h").snapshot()
    eq(_cell(snap, 0, 0)[0], " ", "1047 off clears the alternate screen")


@case("vt", "rep_dec_graphics")
def _vt_rep_dec_graphics():
    # Ghostty's REP prints the previous character again through the same print path, so it is
    # mapped again by the DEC graphics set. (tmux repeats the mapped cell instead; the two
    # differ here, so this is a spec case and not a battery stream.)
    snap = _term(10, 1, b"\x1b(0q\x1b[2b").snapshot()
    eq([_cell(snap, x, 0)[0] for x in range(4)], ["\u2500", "\u2500", "\u2500", " "],
       "q and two repeats are all the horizontal line")


@case("vt", "tbc_no_param_ignored")
def _vt_tbc_no_param_ignored():
    # CSI g with no parameter does nothing in Ghostty (it needs exactly one parameter); tmux
    # reads it as TBC 0 and clears the stop. So the stop at column 8 is still there: a tab
    # from column 0 reaches column 8 and X goes to column 9. (spec case, tmux differs)
    snap = _term(20, 1, b"\t\x1b[g\x1b[1G\tX").snapshot()
    eq(_cursor_xy(snap), (9, 0), "the tab stop at column 8 is kept")
    eq(_cell(snap, 8, 0)[0], "X", "X is at column 8, the cursor after it")


@case("vt", "csi_s_with_params_is_decslrm")
def _vt_csi_s_with_params_is_decslrm():
    # CSI s with a parameter is DECSLRM (set left and right margins), not a cursor save; with
    # DECLRMM off Ghostty ignores it. tmux saves the cursor there, so the two differ (spec
    # case, not a battery stream). Nothing is saved, so CSI u homes the cursor and Z lands there.
    snap = _term(10, 5, b"\x1b[3;3H\x1b[1s\x1b[5;5H\x1b[uZ").snapshot()
    eq(_cursor_xy(snap), (1, 0), "restore with nothing saved homes the cursor")
    eq(_cell(snap, 0, 0)[0], "Z", "Z at the origin")


@case("vt", "channels_own_tokenizer")
def _vt_channels_own_tokenizer():
    # Each channel has its own tokenizer: a CSI left open on the tui channel is not continued
    # by bytes of the gfx channel, which are plain text there.
    from vkitty.vt import Terminal
    t = Terminal(10, 1)
    t.feed(b"\x1b[3", "tui")
    t.feed(b"1mX", "gfx")
    snap = t.snapshot()
    check(snap.row_text(0).startswith("1mX"), "gfx bytes are text: %r" % snap.row_text(0))
    eq((snap.stats["tui_bytes"], snap.stats["gfx_bytes"]), (3, 3), "bytes per channel")


@case("vt", "single_shift_spacers")
def _vt_single_shift_spacers():
    # Terminal.printCell runs its charset block on every call, so a spacer write spends a pending
    # single shift too (print: printCell(0, .spacer_head) before the wrap, printCell(0,
    # .spacer_tail) after a wide cell, the same two in the mode 2027 block that widens a cell).
    # A wide character at the last column: the spacer head spends the shift and the wide cell is
    # mapped through GL (ASCII), so it stays the CJK character.
    snap = _term(5, 2, "\x1b*0\x1b[1;5H\x1bN\u4e16".encode("utf-8")).snapshot()
    eq((_cell(snap, 0, 1)[0], _cell(snap, 0, 1)[2]), ("\u4e16", 2), "SS2, wide at the edge")
    # '#' made wide by VS16 inside the row: the spacer tail spends the shift, so q stays q
    snap = _term(10, 2, "\x1b*0#\x1bN\ufe0fq".encode("utf-8")).snapshot()
    eq(_cell(snap, 2, 0)[0], "q", "SS2 spent on the spacer tail of a VS16 cell")
    # the same at the last column: the spacer head spends it (the wide '#' is printed again)
    snap = _term(5, 2, "\x1b*0\x1b[1;5H#\x1bN\ufe0fq".encode("utf-8")).snapshot()
    eq(_cell(snap, 2, 1)[0], "q", "SS2 spent on the spacer head of a VS16 cell at the edge")
    # the spacer head spends the shift before the base is printed again: with the British set in
    # G2, the shifted base would be the pound sign, and it stays '#'
    snap = _term(5, 2, "\x1b*A\x1b[1;5H#\x1bN\ufe0f".encode("utf-8")).snapshot()
    eq(_cell(snap, 0, 1)[0], "#\ufe0f", "the spacer head spent the shift, the base is not shifted")
    # a one column screen writes a blank for a wide character (printCell(0, .narrow)), and that
    # call spends the shift too, so the next character is not shifted
    snap = _term(1, 2, "\x1b*0\x1bN\u4e16q".encode("utf-8")).snapshot()
    eq(_cell(snap, 0, 1)[0], "q", "the blank of a wide character on one column spent the shift")
    # a wide character in the middle of the row: the wide cell takes the shift (as before) and
    # the spacer tail has nothing left to spend
    snap = _term(10, 1, "\x1b*0\x1bN\u4e16q".encode("utf-8")).snapshot()
    eq((_cell(snap, 0, 0)[0], _cell(snap, 2, 0)[0]), (" ", "q"), "SS2 spent on the wide cell")
    # the base code point that the mode 2027 block prints again as wide (printCell(prev_cp, .wide))
    # goes through the charset mapping: '#' stored under ASCII becomes the pound sign when the
    # British set is selected before the selector arrives, for a bare base and for a base that
    # already holds a grapheme
    snap = _term(5, 2, "\x1b[1;5H#\x1b(A\ufe0f".encode("utf-8")).snapshot()
    eq(_cell(snap, 0, 1)[0], "\u00a3\ufe0f", "the base is mapped when it is printed again")
    snap = _term(5, 2, "\x1b[1;5H#\ufe0e\x1b(A\ufe0f".encode("utf-8")).snapshot()
    eq(_cell(snap, 0, 1)[0], "\u00a3\ufe0e\ufe0f", "the same with a grapheme already on the base")


@case("vt", "resize_rows_trims_blank_rows_first")
def _vt_resize_rows_trims_blank_rows_first():
    # Shrinking the rows trims blank rows below the cursor before any row leaves the top
    # (PageList.resizeWithoutReflow, trimTrailingBlankRows), so the text stays on screen.
    t = _term(4, 5, b"r0\r\nr1")
    t.resize(4, 3)
    snap = t.snapshot()
    eq([_row(snap, y) for y in range(3)], ["r0", "r1", ""], "the blank rows below the cursor go")
    eq(_cursor_xy(snap), (2, 1), "the cursor keeps its row and column")


@case("vt", "resize_rows_keeps_cursor_row_on_screen")
def _vt_resize_rows_keeps_cursor_row_on_screen():
    # With no blank row below the cursor, the top rows leave the screen (into history on the
    # primary screen), so the cursor row stays on screen.
    t = _term(8, 5, b"row0\r\nrow1\r\nrow2\r\nrow3\r\nrow4")
    t.resize(8, 3)
    snap = t.snapshot()
    eq([_row(snap, y) for y in range(3)], ["row2", "row3", "row4"], "the bottom three rows stay")
    eq(_cursor_xy(snap), (4, 2), "the cursor moves up with its row")


@case("vt", "resize_rows_cursor_above_history")
def _vt_resize_rows_cursor_above_history():
    # When the cursor's own row is one of the rows that leave the screen, Ghostty moves the
    # tracked cursor to the top-left of the new active area (Screen.cursorReload).
    t = _term(4, 5, b"r0\r\nr1\r\nr2\r\nr3\r\nr4\x1b[1;3H")
    t.resize(4, 3)
    snap = t.snapshot()
    eq([_row(snap, y) for y in range(3)], ["r2", "r3", "r4"], "the bottom three rows stay")
    eq(_cursor_xy(snap), (0, 0),
       "the cursor row left the screen, so the cursor goes home (column too)")


@case("vt", "resize_alt_screen_trims")
def _vt_resize_alt_screen_trims():
    # The alternate screen has no history: the same rule applies and the rows above the new
    # active area are simply gone.
    t = _term(4, 5, b"\x1b[?1049hA0\r\nA1\r\nA2\r\nA3\r\nA4")
    t.resize(4, 3)
    snap = t.snapshot()
    eq([_row(snap, y) for y in range(3)], ["A2", "A3", "A4"], "alternate rows 2 to 4 remain")


@case("vt", "hop_none_dcs_is_ghostty")
def _vt_hop_none_dcs_is_ghostty():
    # Without tmux in front, DCS tmux; is an ordinary DCS to Ghostty: CAN ends it, so the x
    # after the CAN prints. Passthrough would take the CAN as data and print nothing.
    snap = _term(5, 2, b"\x1bPtmux;\x18x\x1b\\").snapshot()
    eq(_row(snap, 0), "x", "CAN aborts the DCS and x prints")
    eq(_tmux(snap)["discards"], 0, "nothing is discarded without the hop")


@case("vt", "hop_tmux_drops_raw_apc")
def _vt_hop_tmux_drops_raw_apc():
    # Behind tmux a raw APC never reaches the terminal (tmux takes it for the pane title).
    from vkitty.vt import HOP_TMUX
    snap = _term(5, 2, b"\x1b_Gi=1;AA\x1b\\", hop=HOP_TMUX).snapshot()
    eq(snap.stats["apc"], 0, "the raw APC is not delivered")
    eq(_tmux(snap)["dropped_apc"], 1, "and it is counted as dropped")
    snap = _term(5, 2, b"\x1b_Gi=1;AA\x1b\\").snapshot()
    eq(snap.stats["apc"], 1, "with no hop the APC is delivered")


@case("vt", "tmux_dcs_counts_and_unwraps")
def _vt_tmux_dcs_counts_and_unwraps():
    # A DCS tmux; is counted as ignored with no hop, and forwarded behind tmux.
    snap = _term(5, 2, b"\x1bPtmux;abc\x1b\\").snapshot()
    eq(_tmux(snap)["ignored_dcs"], 1, "ignored and counted without the hop")
    eq(_row(snap, 0), "", "its body prints nothing")
    from vkitty.vt import HOP_TMUX
    snap = _term(5, 2, b"\x1bPtmux;abc\x1b\\", hop=HOP_TMUX).snapshot()
    eq(_row(snap, 0), "abc", "behind tmux the body is forwarded and prints")
    eq(_tmux(snap)["ignored_dcs"], 0, "nothing is ignored behind tmux")


@case("vt", "tmux_timer_through_feed")
def _vt_tmux_timer_through_feed():
    # Terminal.feed passes each chunk's arrival time on: a passthrough DCS left open for more
    # than 5 s is dropped and counted as a timer drop; one open for 4.9 s is kept.
    from vkitty.vt import HOP_TMUX, Terminal
    t = Terminal(10, 3, hop=HOP_TMUX)
    t.feed(b"\x1bPtmux;\x1b\x1b_Gi=1;AA", t=0.0)
    t.feed(b"AA\x1b\x1b\\\x1b\\xy", t=5.5)
    snap = t.snapshot()
    eq(_tmux(snap)["timer_drops"], 1, "the timer drop is counted")
    eq(_tmux(snap)["discards"], 0, "and it is not counted as a limit or not-tmux discard")
    eq(snap.stats["apc"], 0, "no APC was delivered")
    eq(_row(snap, 0), "AAxy", "the second chunk is parsed from ground")
    t = Terminal(10, 3, hop=HOP_TMUX)
    t.feed(b"\x1bPtmux;\x1b\x1b_Gi=1;AA", t=0.0)
    t.feed(b"AA\x1b\x1b\\\x1b\\xy", t=4.9)
    snap = t.snapshot()
    eq(_tmux(snap)["timer_drops"], 0, "a DCS open for 4.9 s is kept")
    eq(snap.stats["apc"], 1, "its APC is delivered")
    eq(_row(snap, 0), "xy", "and the text after it prints")


@case("vt", "tmux_discard_counters")
def _vt_tmux_discard_counters():
    # A passthrough DCS whose data does not start with tmux; is discarded (not_tmux), and one
    # whose stored data reaches 1,048,576 bytes is discarded whole (limit). Both are counted
    # in stats tmux discards.
    from vkitty.vt import HOP_TMUX
    snap = _term(5, 2, b"\x1bPtmuy;abc\x1b\\", hop=HOP_TMUX).snapshot()
    eq(_tmux(snap)["discards"], 1, "the not-tmux DCS is counted")
    eq(_row(snap, 0), "", "and its body prints nothing")
    check(any("not a tmux" in w for w in snap.warnings), "a warning names it: %r" % snap.warnings)
    limit = 1048576
    snap = _term(5, 2, b"\x1bPtmux;" + b"A" * (limit - 5) + b"\x1b\\", hop=HOP_TMUX).snapshot()
    eq(_tmux(snap)["discards"], 1, "the limit discard is counted")
    eq(_tmux(snap)["timer_drops"], 0, "and no timer drop is counted")


@case("vt", "utf8_splice_tmux")
def _vt_utf8_splice_tmux():
    """The bytes of a splice seen in a jupynvim session: the second writer put a complete
    passthrough DCS (a placement refresh) inside a placeholder character. tmux 3.5a keeps its
    UTF-8 state across the DCS, so behind tmux the characters show; with no hop the emulator
    keeps Ghostty's decoder and shows the replacement character."""
    from vkitty import tokens
    from vkitty.vt import HOP_TMUX, Terminal
    dcs = tokens.tmux_wrap(b"\x1b_Ga=d,d=i,i=1316379,q=2\x1b\\"
                           + b"\x1b_Ga=p,U=1,i=1316379,p=1,c=48,r=16,q=2\x1b\\")
    eq(len(dcs), 79, "the DCS is the 79 bytes of the session")
    stream = (b"\x1b[38;2;20;22;27m\x1b[1;12H\xf4" + dcs
              + b"\x8e\xbb\xae\xcc\x85\xcc\x8e\x1b[1;13H\xf4\x8e\xbb\xae\xcc\x85\xcc\x90")
    whole = Terminal(20, 2, hop=HOP_TMUX)
    whole.feed(stream)
    pieces = Terminal(20, 2, hop=HOP_TMUX)
    for i in range(len(stream)):
        pieces.feed(stream[i:i + 1])
    for label, term in (("whole", whole), ("1-byte", pieces)):
        snap = term.snapshot()
        eq(_cell(snap, 11, 0)[0], "\U0010eeee\u0305\u030e", "%s: cell x 11" % label)
        eq(_cell(snap, 12, 0)[0], "\U0010eeee\u0305\u0310", "%s: cell x 12" % label)
        check("\ufffd" not in [snap.cells[0][x][0] for x in range(20)],
              "%s: no replacement character in row 0" % label)
        eq(snap.stats["splices"], 1, "%s: one splice" % label)
        eq(snap.stats["cuts"], 0, "%s: no cut" % label)
    snap = _term(20, 2, stream).snapshot()
    eq(_cell(snap, 11, 0)[0], "\ufffd", "hop none: Ghostty's decoder shows the replacement")
    eq(snap.stats["splices"], 1, "hop none: the splice is counted")


@case("vt", "passthrough_body_other")
def _vt_passthrough_body_other():
    """stats tmux body_other counts the tokens other than APC that a passthrough body carries,
    behind tmux only: an APC alone counts none, text and a CSI count two, and the DCS is ignored
    (counts none) with no hop."""
    from vkitty import tokens
    from vkitty.vt import HOP_TMUX, Terminal
    t = Terminal(20, 2, hop=HOP_TMUX)
    t.feed(tokens.tmux_wrap(b"\x1b_Ga=q,i=1,s=1,v=1,f=24;AAAA\x1b\\"))
    eq(_tmux(t.snapshot())["body_other"], 0, "an APC alone counts nothing")
    body = tokens.tmux_wrap(b"xy\x1b[2J\x1b_Ga=q,i=2,s=1,v=1,f=24;AAAA\x1b\\")
    t.feed(body)
    eq(_tmux(t.snapshot())["body_other"], 2, "the PRINT and the CSI of the body count two")
    eq(_tmux(_term(20, 2, body).snapshot())["body_other"], 0,
       "with no hop the DCS is ignored and counts nothing")


@case("vt", "snapshot_stats_are_copies")
def _vt_snapshot_stats_are_copies():
    # A snapshot keeps the counters it had: the nested dicts are copies, not shared.
    from vkitty.vt import HOP_TMUX, Terminal
    t = Terminal(5, 2, hop=HOP_TMUX)
    t.feed(b"ab")
    first = t.snapshot()
    t.feed(b"\x1bPtmuy;abc\x1b\\")
    second = t.snapshot()
    eq(_tmux(first)["discards"], 0, "the earlier snapshot still shows no discard")
    eq(_tmux(second)["discards"], 1, "the later one shows it")
    first.stats["by_image"]["7"] = {"transmissions": 1}
    eq("7" in second.stats["by_image"], False, "a change to one snapshot does not reach another")


@case("vt", "compare_text_and_cursor")
def _vt_compare_text_and_cursor():
    # The differential harness must notice a text difference and a cursor difference, not
    # only a style difference.
    from vkitty.grid_tmux import compare, parse_capture
    from vkitty.vt import Terminal
    emu = Terminal(4, 1)
    emu.feed(b"ab")
    diffs = compare(emu.snapshot(), parse_capture("ac  \n", 4, 1), cursor=(2, 0))
    check(any(d.startswith("row 0 col 1: text") for d in diffs), "a text difference: %r" % diffs)
    diffs = compare(emu.snapshot(), parse_capture("ab  \n", 4, 1), cursor=(3, 0))
    check(any(d.startswith("cursor:") for d in diffs), "a cursor difference: %r" % diffs)
    eq(compare(emu.snapshot(), parse_capture("ab  \n", 4, 1), cursor=(2, 0)), [],
       "identical text and cursor agree")


@case("vt", "package_exports")
def _vt_package_exports():
    # the package exports Terminal, Snapshot, parse_capture and Recording
    from vkitty import Recording, Snapshot, Terminal, parse_capture
    from vkitty.grid_tmux import parse_capture as capture_parser
    from vkitty.recording import Recording as recording_class
    from vkitty.snapshot import Snapshot as snapshot_class
    from vkitty.vt import Terminal as terminal_class
    check(Terminal is terminal_class and Snapshot is snapshot_class
          and parse_capture is capture_parser and Recording is recording_class,
          "the exports are the modules' own objects")


@case("vt", "zero_counts")
def _vt_zero_counts():
    # Ghostty reads a 0 count as no change where tmux reads it as 1 (stream.zig, Terminal.zig):
    # IL and DL return at 0, DCH returns at 0, SU and SD do nothing, CHT and CBT do nothing,
    # HPR and VPR do not move; ICH, ECH and REP read 0 as 1.
    base = b"abcd\r\nefgh\r\nijkl"
    t = _term(4, 3, base + b"\x1b[2;1H\x1b[0L")
    eq([_row(t.snapshot(), y) for y in range(3)], ["abcd", "efgh", "ijkl"],
       "CSI 0 L inserts nothing")
    t = _term(4, 3, base + b"\x1b[2;1H\x1b[0M")
    eq([_row(t.snapshot(), y) for y in range(3)], ["abcd", "efgh", "ijkl"],
       "CSI 0 M deletes nothing")
    t = _term(4, 3, base + b"\x1b[2;2H\x1b[0P")
    eq(_row(t.snapshot(), 1), "efgh", "CSI 0 P deletes nothing")
    t = _term(4, 3, base + b"\x1b[0S\x1b[0T")
    eq([_row(t.snapshot(), y) for y in range(3)], ["abcd", "efgh", "ijkl"],
       "CSI 0 S and 0 T scroll nothing")
    t = _term(4, 1, b"abcd\x1b[2G\x1b[0@")
    eq(_row(t.snapshot(), 0), "a bc", "CSI 0 @ inserts one blank")
    t = _term(4, 1, b"abcd\x1b[2G\x1b[0X")
    eq(_row(t.snapshot(), 0), "a cd", "CSI 0 X erases one cell")
    t = _term(4, 1, b"x\x1b[0b")
    eq(_row(t.snapshot(), 0), "xx", "CSI 0 b repeats once")
    t = _term(20, 1, b"\x1b[0I\x1b[0Z")
    eq(_cursor_xy(t.snapshot()), (0, 0), "CSI 0 I and CSI 0 Z move nothing")
    t = _term(20, 2, b"\x1b[3G\x1b[0a\x1b[0e")
    eq(_cursor_xy(t.snapshot()), (2, 0), "CSI 0 a and CSI 0 e move nothing")


@case("vt", "csi_w_tab_stops")
def _vt_csi_w_tab_stops():
    # CSI W sets a tab stop at the cursor; CSI 2 W and CSI 5 W clear the current one and
    # all; CSI ? 5 W resets the defaults (stream.zig csiDispatch 'W').
    t = _term(20, 1, b"\x1b[5G\x1b[W\x1b[1G\tA")
    eq(_cell(t.snapshot(), 4, 0)[0], "A", "a stop set at column 5 is the first stop")
    t = _term(20, 1, b"\x1b[5G\x1b[W\x1b[2W\x1b[1G\tA")
    eq(_cell(t.snapshot(), 8, 0)[0], "A", "CSI 2 W clears the stop at 5; the default at 9 applies")
    t = _term(20, 1, b"\x1b[5G\x1b[5W\x1b[1G\tA")
    eq(_cell(t.snapshot(), 19, 0)[0], "A", "CSI 5 W clears every stop: the tab goes to the edge")
    t = _term(20, 1, b"\x1b[5W\x1b[?5W\x1b[1G\tA")
    eq(_cell(t.snapshot(), 8, 0)[0], "A", "CSI ? 5 W restores the default stops")


@case("vt", "dch_clears_spacer_head_above")
def _vt_dch_clears_spacer_head_above():
    # DCH at column 0 of a continuation row: splitCellBoundary(0) clears the spacer head that
    # the wide character's wrap left at the end of the row above (Screen.splitCellBoundary).
    snap = _term(5, 2, "\x1b[44mabcd\u4e16\x1b[0m\x1b[2;1H\x1b[P".encode("utf-8")).snapshot()
    eq(_cell(snap, 4, 0)[0], " ", "the spacer head above is blank")
    eq(snap.styles[_cell(snap, 4, 0)[1]][1], None, "with the default background")
    eq(_row(snap, 1), "", "the wide character on the second row is deleted")


@case("vt", "scrolled_counts_full_screen_only")
def _vt_scrolled_counts_full_screen_only():
    # Rows sent into history (the count the pins use) are the rows that leave the top of the
    # primary screen. Terminal.index and scrollUp send them whenever the region's top is row 0 and
    # the region is full width (cursorScrollAbove), whatever its bottom margin. A region that
    # starts lower moves its rows inside the screen (eraseRowBounded or deleteLines) and sends none.
    t = _term(4, 5, b"\x1b[1;3r\x1b[3;1H\n\n\n")
    eq(t.primary.scrolled, 3, "three LFs at the bottom margin of rows 1 to 3 send three rows")
    t = _term(4, 5, b"\x1b[2;4r\x1b[4;1H\n\n\n")
    eq(t.primary.scrolled, 0, "scrolls inside rows 2 to 4 add no history")
    t = _term(4, 5, b"a\r\nb\r\nc\r\nd\r\ne\r\nf")
    check(t.primary.scrolled >= 1, "full-screen scrolls add history: %d" % t.primary.scrolled)


@case("vt", "resize_grow_rows_and_cols")
def _vt_resize_grow_rows_and_cols():
    # Growing rows and columns together: every row ends up exactly as wide as the screen.
    t = _term(4, 2, b"ab")
    t.resize(6, 4)
    snap = t.snapshot()
    eq([len(row) for row in snap.cells], [6, 6, 6, 6], "each row is 6 cells wide")
    eq(_row(snap, 0), "ab", "the text stays")
    eq(_cursor_xy(snap), (2, 0), "the cursor stays")


@case("vt", "il_clears_soft_wrap")
def _vt_il_clears_soft_wrap():
    # Terminal.insertLines narrows the spacer heads of the rows it shifts (rowWillBeShifted) and
    # unsets their soft-wrap flags, so ECH on the moved row 1 finds no spacer head to clear
    # (cursorResetWrap only clears a spacer head of a wrapped row): the narrowed cell stays blue.
    # Row 1 is wrapped too: its spacer head sits in column 4 and nothing overwrites it.
    data = ("\x1b[44mabcd\u4e16"            # row 0 wraps, its wide character lands on row 1
            "\x1b[2;3H\x1b[44mab\u4e16"    # row 1: ab, then a wide character wraps to row 2
            "\x1b[0m\x1b[1;1H\x1b[L"       # insert a line at row 0: the wrapped rows move down
            "\x1b[2;1H\x1b[X").encode("utf-8")   # ECH at row 1 column 0
    snap = _term(5, 5, data).snapshot()
    eq(_cell(snap, 4, 1)[0], " ", "the moved spacer head reads blank")
    eq(snap.styles[_cell(snap, 4, 1)[1]][1], 4,
       "and keeps its background: a narrow cell on an unwrapped row")



@case("vt", "dch_clears_spacer_head_at_row_end")
def _vt_dch_clears_spacer_head_at_row_end():
    # DCH splits the right margin first (splitCellBoundary(cols)): on a wrapped row the spacer
    # head in the last column is cleared before the cells shift, so the shifted cell is blank
    # with the default background, not the spacer head's blue.
    snap = _term(5, 2, "\x1b[44mabcd\u4e16\x1b[0m\x1b[1;1H\x1b[P".encode("utf-8")).snapshot()
    eq(_row(snap, 0), "bcd", "a is deleted and the rest moves left")
    eq(snap.styles[_cell(snap, 3, 0)[1]][1], None, "the cell that moved into column 3 is default")
    eq(snap.styles[_cell(snap, 4, 0)[1]][1], None, "and so is the last column")


@case("vt", "dch_zero_keeps_pending_wrap")
def _vt_dch_zero_keeps_pending_wrap():
    # CSI 0 P returns before anything else (Terminal.deleteChars), so the pending wrap stays
    # set and the Z wraps to the next row; a count of one would have cleared it.
    snap = _term(5, 2, b"abcde\x1b[0PZ").snapshot()
    eq(_row(snap, 0), "abcde", "nothing was deleted")
    eq(_row(snap, 1), "Z", "Z wrapped, so the pending wrap was still set")
    eq(_cursor_xy(snap), (1, 1), "cursor after Z")



@case("vt", "resize_keeps_pending_wrap")
def _vt_resize_keeps_pending_wrap():
    # Terminal.resize and Screen.resize leave the active cursor's pending-wrap flag alone (only
    # a saved cursor's is reset), so the next print still wraps to the next row.
    t = _term(5, 3, b"abcde")
    t.resize(5, 2)
    t.feed(b"Z")
    snap = t.snapshot()
    eq(_row(snap, 0), "abcde", "the last column keeps its character")
    eq(_row(snap, 1), "Z", "Z wraps to the next row")



def _bg(snap, x, y):
    """The background colour (palette index, or None for the default) of cell (x, y)."""
    return snap.styles[_cell(snap, x, y)[1]][1]


@case("vt", "scroll_top_region_keeps_flags")
def _vt_scroll_top_region_keeps_flags():
    # cursorScrollAbove moves whole rows when the region's top is row 0, so a soft-wrap flag
    # stays with its row (index at the bottom margin, or SU). ECH at the start of the moved row
    # then clears the spacer head the wrap left, with the default background.
    wrapped_row = "\x1b[2;1H\x1b[44mabcd\u4e16\x1b[0m".encode("utf-8")
    t = _term(5, 5, wrapped_row + b"\x1b[1;3r\x1b[3;1H\x1b[42m\n\x1b[0m\x1b[1;1H\x1b[X")
    eq(_bg(t.snapshot(), 4, 0), None,
       "index at the bottom margin keeps the flag: spacer head cleared")
    t = _term(5, 5, wrapped_row + b"\x1b[1;3r\x1b[1S\x1b[1;1H\x1b[X")
    eq(_bg(t.snapshot(), 4, 0), None, "SU keeps the flag: spacer head cleared")


@case("vt", "index_bg_partial_region_clears_flags")
def _vt_index_bg_partial_region_clears_flags():
    # With a background set, index at the bottom margin of a region that starts lower scrolls
    # with deleteLines (scrollUp), which narrows the spacer heads of the rows it shifts and unsets
    # their soft-wrap flags. ECH at the start of the moved row then leaves the narrowed cell blue
    # (the whole-row path would keep the spacer head and the flag, and ECH would clear it).
    data = ("\x1b[3;1H\x1b[44mabcd\u4e16\x1b[0m"   # row 2: abcd + blue spacer head (wrap)
            "\x1b[2;4r"                            # region rows 1 to 3
            "\x1b[4;1H\x1b[42m\n\x1b[0m"           # index at the bottom margin, green background
            "\x1b[2;1H\x1b[X").encode("utf-8")
    snap = _term(5, 5, data).snapshot()
    eq(_bg(snap, 4, 1), 4, "deleteLines narrowed the moved spacer head: the cell stays blue")


@case("vt", "scrolled_counts_su_partial_top")
def _vt_scrolled_counts_su_partial_top():
    # SU takes the same path as index: a region whose top is row 0 sends its top rows into
    # history, a region that starts lower sends none, and the alternate screen never counts.
    eq(_term(4, 5, b"\x1b[1;3r\x1b[2S").primary.scrolled, 2, "SU 2 on rows 1 to 3 sends two rows")
    eq(_term(4, 5, b"\x1b[2;4r\x1b[2S").primary.scrolled, 0, "SU 2 on rows 2 to 4 sends none")
    t = _term(4, 5, b"\x1b[?1049h\x1b[1;3r\x1b[3;1H\n\n\n")
    eq(t.alternate.scrolled, 0, "the alternate screen keeps no history")


@case("vt", "package_lazy_exports")
def _vt_package_lazy_exports():
    # tools/gen_widths.py imports vkitty.widths_rules, which runs the package __init__ first.
    # With widths_data.py absent (regeneration from scratch) that must neither load the terminal
    # model nor fail: the exports load on first use.
    import shutil
    import subprocess
    import tempfile
    tmp = tempfile.mkdtemp(prefix="vkitty-lazy-")
    try:
        shutil.copytree(os.path.join(LIB, "vkitty"), os.path.join(tmp, "vkitty"),
                        ignore=shutil.ignore_patterns("__pycache__", "widths_data.py"))
        code = ("import sys\n"
                "sys.path.insert(0, %r)\n"
                "import vkitty.widths_rules\n"
                "print('vt loaded' if 'vkitty.vt' in sys.modules else 'vt not loaded')\n") % tmp
        proc = subprocess.run([sys.executable, "-I", "-B", "-c", code], capture_output=True,
                              text=True, timeout=120)
        check(proc.returncode == 0,
              "widths_rules imports without widths_data.py: %s" % proc.stderr[-400:])
        eq(proc.stdout.strip(), "vt not loaded", "the package does not load vt at import")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


@case("vt", "wide_wrap_sets_continuation")
def _vt_wide_wrap_sets_continuation():
    # printWrap marks the row that receives a wrapped wide character as a continuation. ECH at
    # the start of that row clears the spacer head left on the row above (splitCellBoundary(0)).
    snap = _term(5, 2, "\x1b[44mabcd\u4e16\x1b[0m\x1b[2;1H\x1b[X".encode("utf-8")).snapshot()
    eq(_bg(snap, 4, 0), None, "the spacer head above is cleared with the default background")
    eq(_row(snap, 1), "", "and the wide character on row 1 is erased")


@case("vt", "cont_flag_per_row")
def _vt_cont_flag_per_row():
    # The continuation flag belongs to each row. IL clears it on the rows it moves but leaves the
    # wrap flag of the row above the cursor, so a wide character printed on the moved row does not
    # clear the blue spacer head above it (probe P2 of verification 2).
    data = ("\x1b[44mabcd\u4e16\x1b[0m"
            "\x1b[2;1H\x1b[L"
            "\x1b[2;1H\u4e16"
            "\x1b[2;1H\x1b[X").encode("utf-8")
    snap = _term(5, 5, data).snapshot()
    eq(_bg(snap, 4, 0), 4, "the blue spacer head on row 0 keeps its background")


@case("vt", "resize_saved_cursor_pins_trim")
def _vt_resize_saved_cursor_pins_trim():
    # Screen.resize tracks a pin for the saved cursor, so trimTrailingBlankRows stops at its row:
    # DECSC saved on blank row 4 (the cursor is on row 2), the blank row stays, and the two rows
    # above it leave the top (probe P3 of verification 2).
    t = _term(4, 5, b"r0\r\nr1\r\nr2\x1b[5;1H\x1b7\x1b[3;3H")
    t.resize(4, 3)
    t.feed(b"\x1b8X")
    snap = t.snapshot()
    eq([_row(snap, y) for y in range(3)], ["r2", "", "X"],
       "rows 0 and 1 leave, the saved row stays")
    eq(_cursor_xy(snap), (1, 2), "the restored cursor is on row 2")


@case("vt", "resize_saved_row_moves_with_row")
def _vt_resize_saved_row_moves_with_row():
    # The saved cursor moves with its row: DECSC on row 2 is row 0 once two rows have left.
    t = _term(4, 5, b"r0\r\nr1\r\nr2\x1b7\r\n\r\n")
    t.resize(4, 3)
    t.feed(b"\x1b8X")
    snap = t.snapshot()
    eq(_row(snap, 0), "r2X", "the restored cursor is on the row that held r2, at its saved column")
    eq(_cursor_xy(snap), (3, 0), "the cursor after X")


@case("vt", "resize_saved_row_leaves_homes")
def _vt_resize_saved_row_leaves_homes():
    # A saved cursor whose row leaves the screen goes to the top-left, column included
    # (Screen.resize: sc.x = 0, sc.y = 0).
    t = _term(5, 5, b"r0\r\nr1\r\nr2\r\nr3\r\nr4\x1b[1;4H\x1b7\x1b[5;1H")
    t.resize(5, 3)
    t.feed(b"\x1b8X")
    snap = t.snapshot()
    eq([_row(snap, y) for y in range(3)], ["X2", "r3", "r4"], "the restored cursor is at (0, 0)")


@case("vt", "resize_clears_sync")
def _vt_resize_clears_sync():
    # Termio.resize turns synchronized output off so that the resize shows at once (the spec
    # allows it): the flag and the mode are both cleared.
    t = _term(5, 2, b"\x1b[?2026h")
    check(t.sync, "DECSET 2026 is on")
    t.resize(6, 2)
    check(not t.sync, "a resize clears the synchronized-output flag")
    check(not t._dec.get(2026, False), "and the mode itself")
    check(not any("2026" in w for w in t.snapshot().warnings), "no warning after the resize")


@case("vt", "resize_cols_keeps_cut_head")
def _vt_resize_cols_keeps_cut_head():
    # On the alternate screen (no reflow) resizeWithoutReflow clears only the cells the narrower
    # screen cuts (page.clearCells from the new column count). A wide head that stays on the last
    # column keeps its character and width.
    t = _term(5, 1, "\x1b[?1049habc\u4e16".encode("utf-8"))
    t.resize(4, 1)
    snap = t.snapshot()
    eq(_cell(snap, 3, 0)[0], "\u4e16", "the head keeps its character")
    eq(_cell(snap, 3, 0)[2], 2, "and its wide width")
    eq(_row(snap, 0), "abc\u4e16", "the row keeps its text")


@case("vt", "il_new_rows_take_background")
def _vt_il_new_rows_take_background():
    # Inserted and erased cells take the background of the pen (Screen.blankCell), so IL, DL,
    # SU, SD and RI create blank rows of that colour.
    snap = _term(5, 3, b"\x1b[44m\x1b[2;1H\x1b[L").snapshot()
    eq([_bg(snap, x, 1) for x in range(5)], [4] * 5, "IL's new row is blue")


@case("vt", "dl_new_rows_take_background")
def _vt_dl_new_rows_take_background():
    snap = _term(5, 3, b"aaaaa\r\nbbbbb\r\nccccc\x1b[44m\x1b[2;1H\x1b[M").snapshot()
    eq(_row(snap, 1), "ccccc", "DL moves row 3 up")
    eq([_bg(snap, x, 2) for x in range(5)], [4] * 5, "DL's new bottom row is blue")


@case("vt", "su_new_rows_take_background")
def _vt_su_new_rows_take_background():
    snap = _term(5, 3, b"\x1b[46m\x1b[1S").snapshot()
    eq([_bg(snap, x, 2) for x in range(5)], [6] * 5, "SU's new bottom row is cyan (full screen)")
    snap = _term(5, 4, b"\x1b[2;4r\x1b[42m\x1b[1S").snapshot()
    eq([_bg(snap, x, 3) for x in range(5)], [2] * 5,
       "SU inside rows 2 to 4 leaves a green bottom row")


@case("vt", "sd_new_rows_take_background")
def _vt_sd_new_rows_take_background():
    snap = _term(5, 4, b"\x1b[2;4r\x1b[46m\x1b[1T").snapshot()
    eq([_bg(snap, x, 1) for x in range(5)], [6] * 5, "SD's new top row of the region is cyan")


@case("vt", "ri_new_row_takes_background")
def _vt_ri_new_row_takes_background():
    snap = _term(5, 3, b"aaaaa\r\nbbbbb\x1b[44m\x1b[1;1H\x1bM").snapshot()
    eq(_row(snap, 0), "", "RI at the top margin scrolls the rows down")
    eq([_bg(snap, x, 0) for x in range(5)], [4] * 5, "the new top row is blue")


@case("vt", "index_bg_new_row_takes_background")
def _vt_index_bg_new_row_takes_background():
    snap = _term(5, 3, b"\x1b[1;3r\x1b[42m\x1b[3;1H\n").snapshot()
    eq([_bg(snap, x, 2) for x in range(5)], [2] * 5,
       "index at the bottom of rows 1 to 3 leaves a green row")
    snap = _term(5, 4, b"\x1b[2;4r\x1b[42m\x1b[4;1H\n").snapshot()
    eq([_bg(snap, x, 3) for x in range(5)], [2] * 5, "index inside rows 2 to 4 leaves a green row")


@case("vt", "resize_shrink_trims_stop_at_cursor_row")
def _vt_resize_shrink_trims_stop_at_cursor_row():
    # trimTrailingBlankRows stops at the cursor's row, so a blank cursor row is never trimmed:
    # the row above it leaves the top instead, and the cursor moves up with its row.
    t = _term(4, 5, b"r0\r\n\x1b[2;3H")
    t.resize(4, 1)
    snap = t.snapshot()
    eq(_row(snap, 0), "", "r0 left the screen and the cursor's row stayed")
    eq(_cursor_xy(snap), (2, 0), "the cursor keeps its column and moves up with its row")
    eq(t.primary.scrolled, 1, "r0 went into history")


@case("vt", "resize_shrink_history_count")
def _vt_resize_shrink_history_count():
    # Rows that leave the top of the primary screen on a shrink count as history (Screen.scrolled);
    # the alternate screen keeps none.
    t = _term(4, 3, b"a\r\nb\r\nc")
    t.resize(4, 2)
    eq(t.primary.scrolled, 1, "the top row goes into history")
    t = _term(4, 3, b"\x1b[?1049ha\r\nb\r\nc")
    t.resize(4, 2)
    eq(t.alternate.scrolled, 0, "the alternate screen keeps no history")


@case("vt", "split_continuation_at_x1")
def _vt_split_continuation_at_x1():
    # splitCellBoundary runs its continuation branch at x == 1 as well as x == 0: ECH on the
    # tail of a continued wide character clears the spacer head above it.
    snap = _term(5, 2, "\x1b[44mabcd\u4e16\x1b[0m\x1b[2;2H\x1b[X".encode("utf-8")).snapshot()
    eq(_bg(snap, 4, 0), None, "the spacer head above is cleared at boundary 1")
    eq(_row(snap, 1), "", "and the wide character is erased")


@case("vt", "split_continuation_needs_head")
def _vt_split_continuation_needs_head():
    # The continuation branch needs a wide head at the start of the row: a narrow first cell
    # leaves the row above alone.
    snap = _term(5, 2, b"abcdef\x1b[2;2H\x1b[X").snapshot()
    eq(_row(snap, 0), "abcde", "the last cell of the row above is kept")
    eq(_row(snap, 1), "f", "and row 1 keeps its f (ECH at column 1 erases nothing)")
    # The same with a blue spacer head above: row 1 is still a continuation, but its first cell
    # was erased (EL 2 keeps the flag), so the spacer head stays blue.
    # row 0: abcd + blue spacer head; wide char on row 1
    data = ("\x1b[44mabcd\u4e16\x1b[0m"
            "\x1b[2K\x1b[2;2H\x1b[X").encode("utf-8")
    snap = _term(5, 2, data).snapshot()
    eq(_bg(snap, 4, 0), 4, "a continuation row whose first cell is not a head clears nothing above")


@case("vt", "il_clears_continuation")
def _vt_il_clears_continuation():
    # insertLines unsets the continuation flag of every row it moves (both rows of each shift) and
    # narrows the spacer head of the moved row that held the wrap. The wide character that
    # continued row 1 moves to row 3, so ECH at its start leaves the blue cell on row 2.
    # row 1: abcd + blue spacer head; wide char on row 2
    data = ("\x1b[2;1H\x1b[44mabcd\u4e16\x1b[0m"
            "\x1b[2;1H\x1b[L"                      # IL at row 1: the rows move down one
            # ECH with the default pen, at row 3 where wide char now is
            "\x1b[0m\x1b[4;1H\x1b[X").encode("utf-8")
    snap = _term(5, 5, data).snapshot()
    eq(_bg(snap, 4, 2), 4,
       "the shift took the flag and narrowed the spacer head, so the cell stays blue")


@case("vt", "ech_split_spacer_tail_start")
def _vt_ech_split_spacer_tail_start():
    # ECH on a spacer tail takes the wide character to its left with it (splitCellBoundary at x).
    snap = _term(5, 1, "a\u4e16b".encode("utf-8") + b"\x1b[1;3H\x1b[X").snapshot()
    eq([_cell(snap, x, 0)[0] for x in range(5)], ["a", " ", " ", "b", " "],
       "the pair is erased, b stays")
    eq([_cell(snap, x, 0)[2] for x in range(5)], [1, 1, 1, 1, 1], "every cell is narrow")


@case("vt", "dch_split_spacer_tail_start")
def _vt_dch_split_spacer_tail_start():
    # DCH on a spacer tail splits the wide character at its start first: the head is blanked,
    # then the run shifts left from the tail's column.
    snap = _term(5, 1, "a\u4e16bc".encode("utf-8") + b"\x1b[1;3H\x1b[P").snapshot()
    eq([_cell(snap, x, 0)[0] for x in range(5)], ["a", " ", "b", "c", " "], "a blank, then b and c")
    eq([_cell(snap, x, 0)[2] for x in range(5)], [1, 1, 1, 1, 1], "every cell is narrow")


@case("vt", "reset_wrap_uses_cursor_background")
def _vt_reset_wrap_uses_cursor_background():
    # cursorResetWrap clears the spacer head with the cursor's background (Screen.blankCell):
    # here green, while ECH itself erases only the first cell.
    snap = _term(5, 2, "\x1b[44mabcd\u4e16\x1b[42m\x1b[1;1H\x1b[X".encode("utf-8")).snapshot()
    eq(_bg(snap, 4, 0), 2, "the spacer head takes the cursor's green")


@case("vt", "ich_clears_pending_wrap")
def _vt_ich_clears_pending_wrap():
    # insertBlanks clears the pending-wrap flag before anything else, so the next print lands in
    # the last column and does not wrap.
    snap = _term(5, 2, b"abcde\x1b[@Z").snapshot()
    eq(_row(snap, 0), "abcdZ", "Z is printed in the last column")
    eq(_row(snap, 1), "", "and does not wrap")


@case("vt", "sd_clears_moved_flags")
def _vt_sd_clears_moved_flags():
    # Terminal.scrollDown is insertLines at the top margin, which unsets the soft-wrap flags of
    # the rows it moves and narrows their spacer heads, so ECH at the start of the moved row
    # leaves the blue cell.
    data = "\x1b[2;1H\x1b[44mabcd\u4e16\x1b[0m\x1b[1T\x1b[3;1H\x1b[X".encode("utf-8")
    snap = _term(5, 4, data).snapshot()
    eq(_bg(snap, 4, 2), 4, "the moved, narrowed cell keeps its blue")


@case("vt", "index_blank_row_keeps_erased_flags")
def _vt_index_blank_row_keeps_erased_flags():
    # eraseRowBounded (index at the bottom margin of a region below row 0, default background)
    # erases the top row and rotates it to the bottom, so the new blank row keeps that row's
    # flags: here the continuation flag. A wide character printed there and ECH at column 0
    # then clear the spacer head on the row above.
    data = ("\x1b[1;1Habcd\u4e16"                     # row 0: abcd + spacer head; \u4e16 on row 1
            # row 3: abcd + blue spacer head; \u4e16 on row 4
            "\x1b[44m\x1b[4;1Habcd\u4e16\x1b[0m"
            "\x1b[2;4r"                               # region rows 1 to 3
            "\x1b[4;1H\n"                             # index at the bottom margin
            "\x1b[4;1H\u4e16"                         # a wide character on the new bottom row
            "\x1b[4;1H\x1b[X").encode("utf-8")
    snap = _term(5, 5, data).snapshot()
    eq(_bg(snap, 4, 2), None,
       "the spacer head on the row above is cleared: the new row kept its flag")


@case("vt", "el_complete_keeps_continuation")
def _vt_el_complete_keeps_continuation():
    # EL 2 clears the cells and keeps the row's flags (Terminal.eraseLine complete), so the
    # continuation flag of row 1 survives and ECH at its start clears row 0's spacer head.
    data = ("\x1b[44mabcd\u4e16\x1b[0m"
            "\x1b[2K\x1b[1G\u4e16\x1b[1G\x1b[X").encode("utf-8")
    snap = _term(5, 2, data).snapshot()
    eq(_bg(snap, 4, 0), None, "the spacer head above is cleared")


@case("vt", "ed_resets_row_flags")
def _vt_ed_resets_row_flags():
    # Screen.clearRows resets each row it clears (row.* = .{ .cells = ... }), and ED 0 runs
    # eraseLine(.right), which calls cursorResetWrap. No screen shows these flags, so the state
    # is checked directly.
    t = _term(5, 3, b"abcdefg\x1b[2J")
    check(not any(row.wrapped or row.cont for row in t.primary.grid),
          "ED 2 clears the flags of every row")
    t = _term(5, 3, b"abcdefg\x1b[1;3H\x1b[J")
    check(not t.primary.grid[0].wrapped, "ED 0 resets the wrap flag of the cursor row")
    check(not t.primary.grid[1].wrapped and not t.primary.grid[1].cont, "and clears the rows below")
    # Rows 0 and 1 both wrap here, so clearRows (not cursorResetWrap, which only reaches row 1's
    # continuation flag) is what clears row 1's wrap flag and row 2's continuation flag.
    t = _term(5, 4, b"abcdefghijk\x1b[1;1H\x1b[J")
    check(not t.primary.grid[1].wrapped, "ED 0 clears the wrap flag of a wrapped row below")
    check(not t.primary.grid[2].cont, "and the continuation flag of the row after it")
    t = _term(5, 3, b"abcdefg\x1b[3;1H\x1b[1J")
    check(not t.primary.grid[0].wrapped and not t.primary.grid[1].cont,
          "ED 1 clears the flags of the rows above the cursor")
    t = _term(5, 3, b"abcdefg\x1b[2K")
    check(t.primary.grid[0].wrapped and t.primary.grid[1].cont, "EL 2 keeps the flags of its row")


@case("vt", "resize_tabstops_reset_on_columns")
def _vt_resize_tabstops_reset_on_columns():
    # Terminal.resize rebuilds the tab stops when the columns change: the defaults of the new width.
    t = _term(4, 1)
    t.resize(20, 1)
    t.feed(b"\tA")
    eq(_cell(t.snapshot(), 8, 0)[0], "A", "the first default stop of the wider screen is column 8")
    # Only then (`if (self.cols != cols)`): a resize that changes only the rows keeps them, so a
    # stop set with HTS at column 3 still takes TAB from column 0.
    t = _term(10, 2, b"\x1b[4G\x1bH\r")
    t.resize(10, 3)
    t.feed(b"\tX")
    snap = t.snapshot()
    eq(_cell(snap, 3, 0)[0], "X", "a rows-only resize keeps the HTS stop at column 3")
    eq(_cursor_xy(snap), (4, 0), "the cursor follows the X at column 3")


@case("vt", "compare_cursor_y_and_width")
def _vt_compare_cursor_y_and_width():
    # The comparison covers the cursor's row and a cell's width, not only the cursor column and
    # the text.
    from vkitty.grid_tmux import compare, parse_capture
    from vkitty.vt import Terminal
    emu = Terminal(4, 1)
    emu.feed(b"ab")
    diffs = compare(emu.snapshot(), parse_capture("ab  \n", 4, 1), cursor=(2, 1))
    check(any(d.startswith("cursor:") for d in diffs), "a cursor row difference: %r" % diffs)
    wide = Terminal(4, 1)
    wide.feed("\u4e16".encode("utf-8"))
    cap = parse_capture("\u4e16\n", 4, 1)
    text, sid, _width = cap.cells[0][0]
    cap.cells[0][0] = (text, sid, 1)
    diffs = compare(wide.snapshot(), cap, cursor=(2, 0))
    check(any("width" in d for d in diffs), "a width-only difference: %r" % diffs)



@case("vt", "su_partial_region_clears_flags")
def _vt_su_partial_region_clears_flags():
    # SU inside a region that starts lower is deleteLines (Terminal.scrollUp): the moved rows lose
    # their soft-wrap flags and their spacer heads are narrowed, so ECH at the start of the moved
    # row leaves the blue cell.
    # row 2: abcd + blue spacer head (wrap); \u4e16 on row 3
    data = ("\x1b[3;1H\x1b[44mabcd\u4e16\x1b[0m"
            "\x1b[2;4r"                            # region rows 1 to 3
            "\x1b[1S"                              # SU 1: the wrapped row moves up to row 1
            "\x1b[2;1H\x1b[X").encode("utf-8")
    snap = _term(5, 5, data).snapshot()
    eq(_bg(snap, 4, 1), 4, "deleteLines narrowed the moved spacer head: the cell stays blue")


@case("vt", "reset_wrap_clears_next_continuation")
def _vt_reset_wrap_clears_next_continuation():
    # cursorResetWrap on a wrapped row clears the continuation flag of the row below it
    # (Screen.zig cursorResetWrap). No screen shows this flag, so the state is checked directly.
    t = _term(5, 3, b"abcdef")
    check(t.primary.grid[0].wrapped and t.primary.grid[1].cont,
          "row 0 wraps into row 1 before the erase")
    t.feed(b"\x1b[1;1H\x1b[K")
    check(not t.primary.grid[0].wrapped, "EL 0 at the start of a wrapped row clears its wrap flag")
    check(not t.primary.grid[1].cont, "and the continuation flag of the row below")


@case("vt", "resize_saved_pending_wrap_ends")
def _vt_resize_saved_pending_wrap_ends():
    # Screen.resize: a saved pending wrap ends when the saved cursor is no longer in the last
    # column (here the screen widened), so the restored cursor moves on and the next character
    # does not wrap.
    t = _term(5, 2, b"abcde\x1b7")
    t.resize(8, 2)
    t.feed(b"\x1b8Z")
    snap = t.snapshot()
    eq(_row(snap, 0), "abcdeZ", "the restored cursor is one column on, and Z prints there")
    eq(_row(snap, 1), "", "Z does not wrap")


@case("vt", "resize_saved_pending_wrap_clamped")
def _vt_resize_saved_pending_wrap_clamped():
    # On the alternate screen (no reflow) a narrower screen clamps the saved cursor's pin to the new
    # last column (resizeWithoutReflow clamps the tracked pins); the pending wrap stays set, since
    # the cursor is in the last column.
    t = _term(5, 2, b"\x1b[?1049habcde\x1b7")
    t.resize(3, 2)
    t.feed(b"\x1b8Z")
    snap = t.snapshot()
    eq(_row(snap, 0), "abc", "the restored cursor is in the last column with its pending wrap")
    eq(_row(snap, 1), "Z", "so Z wraps to the next row")



@case("vt", "il_narrows_shifted_spacer_heads")
def _vt_il_narrows_shifted_spacer_heads():
    # Terminal.insertLines calls rowWillBeShifted on every row from the cursor to the bottom
    # margin, which turns a spacer head in the last column into a narrow cell. Row 3 lies below
    # the region and keeps its continuation flag, so ECH under its wide head runs the
    # continuation branch of splitCellBoundary, which finds no spacer head above it.
    data = ("\x1b[3;1H\x1b[44mabcd\u4e16\x1b[0m"   # row 2 wraps a blue wide character into row 3
            "\x1b[2;1H\x1b[44mabcd\u4e16\x1b[0m"   # row 1 wraps one into row 2
            "\x1b[1;3r\x1b[2;1H\x1b[L"             # region rows 0 to 2, IL at row 1
            "\x1b[4;1H\x1b[X").encode("utf-8")     # ECH under the wide head on row 3
    snap = _term(5, 5, data).snapshot()
    eq(_bg(snap, 4, 2), 4, "the narrowed last cell of row 2 keeps its blue background")


@case("vt", "dl_narrows_shifted_spacer_heads")
def _vt_dl_narrows_shifted_spacer_heads():
    # The same through Terminal.deleteLines: DL 2 on rows 1 to 3 moves row 3 (a blue spacer
    # head, narrowed by rowWillBeShifted) up to row 1 and only clears the middle row, which
    # keeps its continuation flag. ECH under a wide head there finds a narrow cell above it.
    data = ("\x1b[2;1H\x1b[44mabcd\u4e16\x1b[0m\x1b[4;1H\x1b[44mabcd\u4e16\x1b[0m"
            "\x1b[2;4r\x1b[2;1H\x1b[2M"
            "\x1b[3;1H\u4e16\x1b[3;1H\x1b[X").encode("utf-8")
    snap = _term(5, 6, data).snapshot()
    eq(_bg(snap, 4, 1), 4, "the narrowed last cell of row 1 keeps its blue background")


def _cut_head_term(head_row, extra):
    """An alternate screen 5x4 with `abc` and a blue wide character on head_row, resized to 4x4:
    the column cut keeps the wide head in the new last column without its tail (no reflow on
    the alternate screen). Then `extra` is fed."""
    t = _term(5, 4,
              ("\x1b[?1049h\x1b[%d;1H\x1b[44mabc\u4e16\x1b[0m" % (head_row + 1)).encode("utf-8"))
    t.resize(4, 4)
    t.feed(extra)
    return t


def _check_cleared_head(snap, x, y, what):
    eq(_row(snap, y), "abc", what + ": the shifted row loses the cut wide character")
    eq((_cell(snap, x, y)[0], _cell(snap, x, y)[2]), (" ", 1), what
       + ": the head is a blank narrow cell")
    eq(_bg(snap, x, y), 4, what + ": and keeps its blue background")


@case("vt", "il_clears_cut_wide_head_in_last_column")
def _vt_il_clears_cut_wide_head_in_last_column():
    # Terminal.rowWillBeShifted, second branch: in a full-width region the right cell is
    # cells[cols - 1]. When it is a wide head (a column cut leaves one there without its tail),
    # its codepoint becomes 0 and it becomes narrow, its style kept. insertLines calls it on every
    # row from the cursor to the bottom margin, so IL at row 0 clears the head of row 1 as it
    # moves the row to row 2. A row above the cursor is not shifted and keeps its head.
    _check_cleared_head(_cut_head_term(1, b"\x1b[1;1H\x1b[L").snapshot(), 3, 2, "IL at row 0")
    # The cleared cell is narrow, not a head without text: DCH at column 0 moves it to column 2,
    # and a print there leaves column 3 alone (over a wide head, printCell clears the next cell).
    snap = _cut_head_term(1, b"\x1b[1;1H\x1b[L\x1b[3;1H\x1b[P\x1b[3;4HZ\x1b[3;3HY").snapshot()
    eq(_row(snap, 2), "bcYZ",
       "IL at row 0, then DCH and two prints: the moved blank cell is narrow")
    snap = _cut_head_term(1, b"\x1b[3;1H\x1b[L").snapshot()
    eq(_row(snap, 1), "abc\u4e16", "IL at row 2: row 1 lies above the shift and keeps its head")
    eq(_cell(snap, 3, 1)[2], 2, "IL at row 2: the head of row 1 stays wide")
    # The clearing stops at the bottom margin: rem = bottom - cursor.y + 1, so a row below the
    # region is never passed to rowWillBeShifted. Row 3 keeps its head with rows 0 to 1 as the
    # region, and with rows 0 to 2, where it is the first row below the margin.
    for region, what in ((b"\x1b[1;2r", "IL at row 0 of rows 0 to 1"),
                         (b"\x1b[1;3r", "IL at row 0 of rows 0 to 2")):
        snap = _cut_head_term(3, region + b"\x1b[1;1H\x1b[L").snapshot()
        eq(_row(snap, 3), "abc\u4e16", what
           + ": row 3 lies below the bottom margin and keeps its head")
        eq(_cell(snap, 3, 3)[2], 2, what + ": the head of row 3 stays wide")


@case("vt", "dl_clears_cut_wide_head_in_last_column")
def _vt_dl_clears_cut_wide_head_in_last_column():
    # The same through Terminal.deleteLines: DL at row 0 moves row 1 up to row 0 and clears the
    # cut head on the way.
    _check_cleared_head(_cut_head_term(1, b"\x1b[1;1H\x1b[M").snapshot(), 3, 0, "DL at row 0")
    # deleteLines bounds the clearing by the bottom margin the same way: DL at row 0 of rows 0
    # to 2 leaves row 3, the first row below the margin, with its head.
    snap = _cut_head_term(3, b"\x1b[1;3r\x1b[1;1H\x1b[M").snapshot()
    what = "DL at row 0 of rows 0 to 2"
    eq(_row(snap, 3), "abc\u4e16", what + ": row 3 lies below the bottom margin and keeps its head")
    eq(_cell(snap, 3, 3)[2], 2, what + ": the head of row 3 stays wide")


@case("vt", "scroll_clears_cut_wide_head_by_path")
def _vt_scroll_clears_cut_wide_head_by_path():
    # The scrolls that run insertLines or deleteLines clear the cut head of a moved row: SD
    # (scrollDown) and RI at the top margin (insertLines at the top margin), SU in a region below
    # row 0 (deleteLines at the top margin), and index at the bottom margin of such a region with
    # a background in the pen (scrollUp). The scrolls that move whole rows keep it: index with the
    # default pen below row 0 (PageList.eraseRowBounded), and index or SU in a region whose top
    # is row 0 (cursorScrollAbove).
    _check_cleared_head(_cut_head_term(1, b"\x1b[1T").snapshot(), 3, 2, "SD 1")
    _check_cleared_head(_cut_head_term(1, b"\x1b[1;1H\x1bM").snapshot(), 3, 2,
                        "RI at the top margin")
    _check_cleared_head(_cut_head_term(2, b"\x1b[2;4r\x1b[1S").snapshot(), 3, 1,
                        "SU in rows 1 to 3")
    _check_cleared_head(_cut_head_term(2, b"\x1b[2;4r\x1b[4;1H\x1b[42m\n\x1b[0m").snapshot(), 3, 1,
                        "index with a background in rows 1 to 3")
    whole = [("index with the default pen in rows 1 to 3", 2, b"\x1b[2;4r\x1b[4;1H\n", 1),
             ("index at the bottom of the screen", 1, b"\x1b[4;1H\n", 0),
             ("SU with the top margin at row 0", 1, b"\x1b[1S", 0)]
    for what, head_row, extra, y in whole:
        snap = _cut_head_term(head_row, extra).snapshot()
        eq(_row(snap, y), "abc\u4e16", what + ": the whole row moves with its head")
        eq(_cell(snap, 3, y)[2], 2, what + ": the head stays wide")


@case("vt", "dl_untouched_row_keeps_continuation")
def _vt_dl_untouched_row_keeps_continuation():
    # deleteLines clears a row it does not shift without touching its flags: DL 2 at row 1 of a
    # 3-row screen clears rows 1 and 2 in place, so row 1 keeps its continuation flag, and ECH
    # under a new wide head there clears the spacer head of row 0, which lies above the shift.
    data = ("\x1b[44mabcd\u4e16\x1b[0m"
            "\x1b[2;1H\x1b[2M"
            "\x1b[2;1H\u4e16\x1b[2;1H\x1b[X").encode("utf-8")
    snap = _term(5, 3, data).snapshot()
    eq(_bg(snap, 4, 0), None, "the spacer head of row 0 is cleared with the default background")


@case("vt", "dl_clears_continuation_of_moved_row")
def _vt_dl_clears_continuation_of_moved_row():
    # deleteLines unsets the continuation flag of a row it moves. DL 2 at row 1 brings row 3, a
    # continuation that starts with a wide head, up under row 0, which lies above the shift and
    # keeps its blue spacer head. ECH under the head on row 1 then finds no continuation flag and
    # leaves row 0's spacer head blue.
    data = ("\x1b[44mabcd\u4e16\x1b[0m"            # row 0 wraps a blue wide character into row 1
            "\x1b[3;1H\x1b[44mabcd\u4e16\x1b[0m"   # row 2 wraps one into row 3
            "\x1b[2;1H\x1b[2M"                     # DL 2 at row 1: row 3 moves up to row 1
            "\x1b[2;1H\x1b[X").encode("utf-8")
    snap = _term(5, 5, data).snapshot()
    eq(_cell(snap, 0, 1)[0], " ", "ECH erased the moved wide character")
    eq(_bg(snap, 4, 0), 4,
       "row 0's spacer head stays blue: the moved row lost its continuation flag")


@case("vt", "reset_wrap_needs_wrapped_row")
def _vt_reset_wrap_needs_wrapped_row():
    # cursorResetWrap returns when the cursor row is not wrapped, so it leaves the continuation
    # flag of the row below alone. DL 2 at row 1 of rows 1 to 3 moves a blank row up to row 1
    # (its flags unset) and only clears row 2, which keeps the continuation flag of the old wrap.
    # ECH on row 1 then keeps that flag. No screen shows it (a spacer head only sits on a wrapped
    # row), so the state is checked directly.
    t = _term(5, 4, b"\x1b[2;1Habcdef\x1b[2;1H\x1b[2M")
    grid = t.primary.grid
    eq((grid[1].wrapped, grid[2].cont), (False, True),
       "row 1 is not wrapped and row 2 is a continuation")
    t.feed(b"\x1b[2;1H\x1b[X")
    check(t.primary.grid[2].cont, "ECH on the unwrapped row 1 keeps row 2's continuation flag")


@case("vt", "ed22_scroll_clear")
def _vt_ed22_scroll_clear():
    # ED 22 (Terminal.eraseDisplay scroll_complete) runs Screen.scrollClear: PageList.scrollClear
    # grows the screen by the rows down to the last non-empty one, so they go into history and
    # default rows open at the bottom (no background: clearRows does not run). cursorReload sends
    # a cursor whose row left to the top-left.
    t = _term(5, 3, b"a\r\nb\x1b[44m\x1b[22J")
    snap = t.snapshot()
    eq([_row(snap, y) for y in range(3)], ["", "", ""], "the screen is clear")
    eq(t.primary.scrolled, 2, "rows 0 and 1 went into history")
    eq(_cursor_xy(snap), (0, 0), "the cursor's row left, so the cursor is at the top-left")
    eq([_bg(snap, x, y) for y in range(3) for x in range(5)], [None] * 15,
       "every cell is default, not blue")


@case("vt", "ed22_cursor_moves_with_row")
def _vt_ed22_cursor_moves_with_row():
    # A cursor below the last non-empty row moves up with its row and keeps its column
    # (cursorReload), and ED 22 ends a pending wrap: the restored pending cursor on the blank
    # row 1 prints Z in place after the clear instead of wrapping.
    t = _term(5, 4, b"\x1b[2;1Habcde\x1b7\x1b[2K\x1b[1;1Hx\x1b8\x1b[22J")
    snap = t.snapshot()
    eq(t.primary.scrolled, 1, "only row 0 holds text, so one row goes into history")
    eq(_cursor_xy(snap), (4, 0), "the cursor moved up with row 1")
    t.feed(b"Z")
    snap = t.snapshot()
    eq([_row(snap, y) for y in range(2)], ["    Z", ""], "Z prints at (4, 0): no pending wrap")
    t = _term(5, 4, b"x\x1b[3;3H\x1b[?22J")
    eq((t.primary.scrolled, _cursor_xy(t.snapshot())), (1, (2, 1)), "CSI ? 22 J is the same clear")


@case("vt", "ed22_nonempty_cells")
def _vt_ed22_nonempty_cells():
    # PageList.scrollClear counts a row as long as one of its cells is not Cell.isEmpty: a blank
    # that carries only a background (BCE) is not empty, and neither is a spacer head.
    t = _term(5, 3, b"\x1b[3;1H\x1b[44m\x1b[K\x1b[0m\x1b[1;1H\x1b[22J")
    eq(t.primary.scrolled, 3, "a row of blue blanks counts")
    t = _term(5, 3, "\x1b[1;5H\u4e16\x1b[2K\x1b[22J".encode("utf-8"))
    eq(t.primary.scrolled, 1, "a row whose only cell is a spacer head counts")
    eq(_cursor_xy(t.snapshot()), (2, 0), "and the cursor moves up with its row")


@case("vt", "ed22_styled_codepoint_zero_is_empty")
def _vt_ed22_styled_codepoint_zero_is_empty():
    # Cell.isEmpty looks only at the text and the width of a codepoint cell, not at its style. A
    # spacer head printed with a blue pen and then narrowed (printCell over the wide character it
    # belonged to) is a codepoint 0 cell with the blue style, so it is empty for scrollClear, while
    # an ECH blank of the same blue (a background-only cell) is not.
    t = _term(5, 3, "\x1b[44m\x1b[1;5H\u4e16\x1b[0m\x1b[2;1Hx\x1b[2K\x1b[22J".encode("utf-8"))
    snap = t.snapshot()
    eq(t.primary.scrolled, 0, "no row holds a non-empty cell")
    eq(_bg(snap, 4, 0), 4, "the narrowed blue cell stays on row 0")
    t = _term(5, 3, b"\x1b[44m\x1b[1;5H\x1b[X\x1b[0m\x1b[2;1H\x1b[22J")
    eq(t.primary.scrolled, 1, "the blue ECH blank counts")


@case("vt", "ed22_alternate_and_empty")
def _vt_ed22_alternate_and_empty():
    # On the alternate screen the rows leave the top too, but the model counts history on the
    # primary screen only. On a screen with no non-empty cell nothing moves.
    t = _term(5, 3, b"\x1b[?1049ha\r\nb\x1b[22J")
    snap = t.snapshot()
    eq([_row(snap, y) for y in range(3)], ["", "", ""], "the alternate screen is clear")
    eq((t.alternate.scrolled, t.primary.scrolled), (0, 0), "no history is counted")
    eq(_cursor_xy(snap), (0, 0), "the cursor's row left")
    t = _term(5, 3, b"\x1b[3;4H\x1b[22J")
    eq((t.primary.scrolled, _cursor_xy(t.snapshot())), (0, (3, 2)),
       "an empty screen keeps its cursor")


@case("vt", "resize_alt_cuts_columns_before_trim")
def _vt_resize_alt_cuts_columns_before_trim():
    # PageList.resizeWithoutReflow changes the columns first ("we have to do cols first"), then
    # trims blank rows, so on the alternate screen a row whose only text lies in the cut columns
    # is blank and is trimmed, and no row leaves the top.
    t = _term(8, 3, b"\x1b[?1049htop\x1b[3;7Hzz\x1b[1;1H")
    t.resize(4, 2)
    snap = t.snapshot()
    eq([_row(snap, y) for y in range(2)], ["top", ""], "the row of zz is trimmed and top stays")
    eq(_cursor_xy(snap), (0, 0), "the cursor stays")


@case("vt", "resize_primary_order_follows_wraparound")
def _vt_resize_primary_order_follows_wraparound():
    # Terminal.resize passes reflow = wraparound for the primary screen. With wraparound off the
    # primary takes resizeWithoutReflow too: columns first, so the row of zz is trimmed. With it
    # on, PageList.resize shrinks the rows first with the old width, so the row of zz still has
    # text, nothing is trimmed and top leaves the screen. Then resizeCols reflows every row: the
    # unwrapped row of zz (8 columns of content) becomes two rows at 4 columns, so in Ghostty two
    # rows end above the active area (top and the blank row 1), active row 0 is the first half of
    # the reflowed row (it reads blank), row 1 is "  zz", and the cursor, whose pin went into
    # history, is at the top left (Screen.cursorReload). Reflow is not modelled: the model cuts
    # the columns after the rows, so its row 0 is the blank row 1, its row 1 is blank and one row
    # went into history. Only what holds in both is asserted: row 0 reads blank and the cursor.
    t = _term(8, 3, b"\x1b[?7ltop\x1b[3;7Hzz\x1b[1;1H")
    t.resize(4, 2)
    snap = t.snapshot()
    eq([_row(snap, y) for y in range(2)], ["top", ""], "wraparound off: zz's row is trimmed")
    eq(t.primary.scrolled, 0, "and nothing goes into history")
    t = _term(8, 3, b"top\x1b[3;7Hzz\x1b[1;1H")
    t.resize(4, 2)
    snap = t.snapshot()
    eq(_row(snap, 0), "", "wraparound on: top left the screen and row 0 reads blank")
    eq(_cursor_xy(snap), (0, 0),
       "wraparound on: the cursor row left, so the cursor is at the top left")


@case("vt", "resize_same_size_clears_sync")
def _vt_resize_same_size_clears_sync():
    # Surface.resize mails the IO thread on every size change, also when the grid stays the same
    # (a pixel change), and Termio.resize turns synchronized output off after Terminal.resize,
    # which returns early for an unchanged grid.
    t = _term(5, 2, b"\x1b[?2026h")
    t.resize(5, 2)
    check(not t.sync, "a resize event with the same grid clears the synchronized-output flag")
    check(not t._dec.get(2026, False), "and the mode itself")
    # Everything else stays, the scroll margins too (a real resize resets them): with rows 1 to 2
    # as the region, LF at row 2 after a same-size event scrolls only the region.
    t = _term(5, 4, b"r0\r\nr1\r\nr2\r\nr3\x1b[2;3r")
    t.resize(5, 4)
    t.feed(b"\x1b[3;1H\n")
    snap = t.snapshot()
    eq([_row(snap, y) for y in range(4)], ["r0", "r2", "", "r3"],
       "a same-size event keeps the scroll region: LF at its bottom scrolls rows 1 to 2 only")
    eq(_cursor_xy(snap), (0, 2), "the cursor stays at the bottom margin")
    # and the tab stops (Terminal.resize returns before it makes them again)
    t = _term(10, 2, b"\x1b[4G\x1bH\r")
    t.resize(10, 2)
    t.feed(b"\t")
    eq(_cursor_xy(t.snapshot()), (3, 0), "a same-size event keeps a tab stop set with HTS")
    # and the cursor with its pending wrap: a print after the event wraps to the next row
    t = _term(5, 4, b"\x1b[2;1Habcde")
    t.resize(5, 4)
    t.feed(b"f")
    snap = t.snapshot()
    eq([_row(snap, y) for y in range(4)], ["", "abcde", "f", ""],
       "a same-size event keeps the cursor and its pending wrap")
    eq(_cursor_xy(snap), (1, 2), "the cursor after the wrapped print")


@case("vt", "resize_alt_saved_home_pending_wrap")
def _vt_resize_alt_saved_home_pending_wrap():
    # The alternate screen erases its history after the resize (Screen.resize, no_scrollback), and
    # eraseRows moves a pin in an erased row to x 0, y 0 of the page, the top-left of the active
    # area. The saved cursor then takes the pending-wrap rule: with a pending wrap it ends at
    # (1, 0). On the primary screen the pin stays in history and the cursor goes to (0, 0) with no
    # pending wrap.
    t = _term(5, 4, b"\x1b[?1049habcde\x1b7\x1b[4;1Hr3")
    t.resize(5, 2)
    t.feed(b"\x1b8Z")
    snap = t.snapshot()
    eq([_row(snap, y) for y in range(2)], [" Z", "r3"], "the restored cursor is at (1, 0)")
    t = _term(5, 5, b"abcde\x1b7\x1b[5;1Hr4")
    t.resize(5, 3)
    t.feed(b"\x1b8Z")
    snap = t.snapshot()
    eq([_row(snap, y) for y in range(3)], ["Z", "", "r4"], "primary: (0, 0) and no pending wrap")


@case("vt", "resize_alt_saved_moves_with_row")
def _vt_resize_alt_saved_moves_with_row():
    # The alternate screen's saved cursor follows its row like the primary's (Screen.resize tracks
    # a pin for it on every screen).
    t = _term(5, 5, b"\x1b[?1049hr0\r\nr1\r\nr2\r\nr3\r\nr4\x1b[4;2H\x1b7\x1b[5;3H")
    t.resize(5, 3)
    t.feed(b"\x1b8Z")
    snap = t.snapshot()
    eq([_row(snap, y) for y in range(3)], ["r2", "rZ", "r4"], "the saved cursor moved up two rows")


@case("vt", "resize_new_rows_are_default")
def _vt_resize_new_rows_are_default():
    # Rows a resize adds come from PageList.grow: default cells, whatever the pen's background.
    t = _term(5, 2, b"\x1b[44mab")
    t.resize(5, 4)
    snap = t.snapshot()
    eq([_bg(snap, x, y) for y in (2, 3) for x in range(5)], [None] * 10,
       "the two new rows are default")


@case("vt", "resize_grow_cols_narrows_spacer_head")
def _vt_resize_grow_cols_narrows_spacer_head():
    # Growing the columns without reflow copies the rows into a new page
    # (resizeWithoutReflowGrowCols, cloneRowFrom), and the copy turns a spacer head in the old last
    # column into a narrow cell, which Cell.isEmpty counts as empty: ED 22 then finds no
    # non-empty row and leaves the cursor where it is.
    from vkitty import vt
    t = _term(5, 2, "\x1b[?1049h\x1b[1;5H\u4e16\x1b[2K".encode("utf-8"))
    t.resize(8, 2)
    eq(t.alternate.grid[0].wide[4], vt._WIDE_NARROW, "the old spacer head is a narrow cell")
    t.feed(b"\x1b[22J")
    eq(_cursor_xy(t.snapshot()), (2, 1), "nothing moved: the old spacer head is a narrow cell")


@case("vt", "resize_grow_cols_page_copy_flags")
def _vt_resize_grow_cols_page_copy_flags():
    # cloneRowFrom copies fewer cells than the new page is wide, so it keeps the new row's flags:
    # a row copied on a column grow loses both soft-wrap flags. The copy happens when a row has a
    # spacer head in the old last column or the page is narrower than the new width (its capacity
    # is the width it was made at); otherwise the page just widens and the flags stay. No screen
    # shows these flags, so the state is checked directly.
    t = _term(5, 4, "\x1b[?1049habcdefg\x1b[3;5H\u4e16".encode("utf-8"))
    t.resize(8, 4)
    check(not any(row.wrapped or row.cont for row in t.alternate.grid),
          "a spacer head in the old last column: every row loses its flags")
    t = _term(8, 3, b"\x1b[?1049h")
    t.resize(5, 3)
    t.feed(b"abcdefg")
    t.resize(8, 3)
    check(t.alternate.grid[0].wrapped and t.alternate.grid[1].cont,
          "a page made 8 wide grows back to 8 in place: the flags stay")
    t.resize(5, 3)
    t.resize(10, 3)
    check(not t.alternate.grid[0].wrapped and not t.alternate.grid[1].cont,
          "growing past the page's width copies the rows: the flags go")
    t.resize(5, 3)
    t.feed(b"\x1b[1;1Habcdefg")
    t.resize(10, 3)
    check(t.alternate.grid[0].wrapped and t.alternate.grid[1].cont,
          "the copy made a page 10 wide: growing back to 10 keeps the flags")
    # The in-place grow (resizeWithoutReflowGrowCols, fast path) sets only the page's size, not
    # its capacity: a page made 10 wide and cut to 5 grows to 8 and then to 10 in place.
    t = _term(10, 3, b"\x1b[?1049h")
    t.resize(5, 3)
    t.feed(b"abcdefg")
    t.resize(8, 3)
    t.resize(10, 3)
    check(t.alternate.grid[0].wrapped and t.alternate.grid[1].cont,
          "a page made 10 wide grows 5 to 8 to 10 in place: the flags stay")
    # The primary screen with wraparound on takes the reflow path (resizeCols), which builds new
    # pages at the new width, also on a shrink. Grown later with wraparound off (no reflow), the
    # 5-wide page is copied.
    t = _term(8, 3)
    t.resize(5, 3)
    t.feed(b"abcdefg\x1b[?7l")
    t.resize(8, 3)
    check(not t.primary.grid[0].wrapped and not t.primary.grid[1].cont,
          "a reflow shrink made the page 5 wide: the grow to 8 copies the rows")
    # A reflow grow: Ghostty joins abcde and fg on one row of 8, which is not wrapped (the model
    # does not move the text, a known gap, but the row's flag agrees).
    t = _term(8, 3, b"\x1b[?7l")
    t.resize(5, 3)
    t.feed(b"\x1b[?7habcdefg")
    t.resize(8, 3)
    check(not t.primary.grid[0].wrapped, "after a reflow grow the first row is not wrapped")


@case("vt", "split_continuation_head_check_above")
def _vt_split_continuation_head_check_above():
    # The continuation branch of splitCellBoundary clears the last cell of the row above only when
    # it is a spacer head: after a narrow wrap that cell is the e, which stays.
    t = _term(5, 2, "abcdef\x1b[2;1H\u4e16\x1b[2;1H\x1b[X".encode("utf-8"))
    eq(_row(t.snapshot(), 0), "abcde", "the e above is kept")


@case("vt", "split_clears_with_pen_background")
def _vt_split_clears_with_pen_background():
    # splitCellBoundary clears with Screen.clearCells, so the cleared spacer head takes the pen's
    # background: green for the head above a continuation row (ECH), and green for the head at
    # the end of a wrapped row (DCH), which the shift then carries to column 3.
    t = _term(5, 2, "\x1b[44mabcd\u4e16\x1b[42m\x1b[2;1H\x1b[X".encode("utf-8"))
    eq(_bg(t.snapshot(), 4, 0), 2, "ECH: the spacer head above is cleared in green")
    t = _term(5, 2, "\x1b[44mabcd\u4e16\x1b[42m\x1b[1;1H\x1b[P".encode("utf-8"))
    eq(_bg(t.snapshot(), 3, 0), 2, "DCH: the end split clears in green, shifted to column 3")


@case("vt", "split_end_needs_wrapped_row")
def _vt_split_end_needs_wrapped_row():
    # splitCellBoundary(cols) returns when the row is not wrapped. Ghostty's page integrity rule
    # (a spacer head only in the last column of a wrapped row) makes that state unreachable by a
    # stream, so the row is built directly: DCH keeps the blue spacer head and shifts it.
    from vkitty import vt
    t = _term(5, 2, "\x1b[44mabcd\u4e16\x1b[0m".encode("utf-8"))
    row = t.primary.grid[0]
    check(row.wide[4] == vt._WIDE_SPACER_HEAD and row.wrapped, "row 0 ends in a spacer head")
    row.wrapped = False
    t.feed(b"\x1b[1;1H\x1b[P")
    eq(_bg(t.snapshot(), 3, 0), 4, "the unwrapped row keeps its blue spacer head, now in column 3")


@case("vt", "print_wrap_marks_before_index")
def _vt_print_wrap_marks_before_index():
    # Terminal.printWrap marks the row before it calls index. On the last row below the region the
    # index does not move, so that row gets both flags and the row above it none; at the bottom of
    # a region that deleteLines scrolls (a background is set), the marked row moves up and loses
    # its flag. No screen shows these flags, so the state is checked directly.
    t = _term(5, 5, b"\x1b[1;4r\x1b[5;1Habcdef")
    grid = t.primary.grid
    eq((grid[4].wrapped, grid[4].cont, grid[3].wrapped), (True, True, False),
       "the cursor row below the region is marked, not the row above it")
    t = _term(5, 5, b"\x1b[2;4r\x1b[4;1H\x1b[42mabcdef")
    grid = t.primary.grid
    eq((grid[2].wrapped, grid[3].cont), (False, True),
       "the moved row lost its flag, the new bottom row is a continuation")


@case("vt", "wide_cells_keep_page_integrity")
def _vt_wide_cells_keep_page_integrity():
    # Ghostty's Page.verifyIntegrity rules for wide cells hold after every operation: a spacer head
    # sits in the last column of a wrapped row, and a spacer tail follows a wide head. A seeded mix
    # of prints (wide, emoji with selectors, combining marks), scrolls in regions, edits, erases,
    # screen switches, modes and resizes runs on both screens. A column cut leaves a wide head in
    # the new last column without its tail (page.clearCells has no wide handling), and a later
    # wide print over that head clears the next cell as if it were the tail, in Ghostty too; on a
    # screen where a cut did that, only the spacer head rules are checked from then on.
    from vkitty import vt
    texts = ("ab", "abcdefghij", "\u4e16", "\u4e16\u754c", "x\u4e16", "e\u0301", "\U0001F600",
             "\u2764\ufe0f", "\u2614\ufe0e", "#\ufe0f", "abcd\u4e16", "\u4e16\u4e16\u4e16")
    simple = ("\x1b[0m", "\x1b[44m", "\x1b[42m", "\x1b[1;45m", "\x1b[r", "\x1bM", "\x1bD", "\x1bE",
              "\n", "\r", "\b", "\t", "\x1b7", "\x1b8", "\x1b[?1049h", "\x1b[?1049l", "\x1b[?1047h",
              "\x1b[?1047l", "\x1b[?47h", "\x1b[?47l", "\x1b[4h", "\x1b[4l", "\x1b[?7l", "\x1b[?7h",
              "\x1b[?6h", "\x1b[?6l")
    counted = ("L", "M", "S", "T", "X", "P", "@", "b")
    modes = ("K", "J", "?J", "?K")

    def problems(t, cut):
        out = []
        for key, sc in (("pri", t.primary), ("alt", t.alternate)):
            if sc is None:
                continue
            if len(sc.grid) != t.rows:
                out.append("%s has %d rows, want %d" % (key, len(sc.grid), t.rows))
            for y, row in enumerate(sc.grid):
                if not (len(row.text) == len(row.sid) == len(row.wide) == t.cols):
                    out.append("%s y=%d is not %d cells wide" % (key, y, t.cols))
                    continue
                for x, w in enumerate(row.wide):
                    if w == vt._WIDE_TAIL and (x == 0 or row.wide[x - 1] != vt._WIDE_HEAD):
                        if key not in cut:
                            out.append("%s y=%d x=%d spacer tail not following wide" % (key, y, x))
                    elif w == vt._WIDE_SPACER_HEAD and x != t.cols - 1:
                        out.append("%s y=%d x=%d spacer head not at end" % (key, y, x))
                    elif w == vt._WIDE_SPACER_HEAD and not row.wrapped:
                        out.append("%s y=%d spacer head not wrapped" % (key, y))
            if not (0 <= sc.x < t.cols and 0 <= sc.y < t.rows):
                out.append("%s cursor (%d, %d) off the grid" % (key, sc.x, sc.y))
        return out

    ops = 0
    for seed in range(100):
        rnd = random.Random(9100 + seed)
        t = _term(rnd.randint(2, 8), rnd.randint(2, 6))
        trail = []
        cut = set()
        for _ in range(300):
            r = rnd.random()
            if r < 0.06:
                cols, rows = rnd.randint(1, 9), rnd.randint(1, 6)
                for key, sc in (("pri", t.primary), ("alt", t.alternate)):
                    if sc is not None and cols < t.cols and any(
                            row.wide[cols - 1] == vt._WIDE_HEAD for row in sc.grid):
                        cut.add(key)
                trail.append("resize(%d, %d)" % (cols, rows))
                op = None
            else:
                if r < 0.40:
                    op = ""
                    if rnd.random() < 0.5:
                        op = "\x1b[%d;%dH" % (rnd.randint(1, t.rows),
                                              rnd.randint(max(1, t.cols - 3), t.cols))
                    op += rnd.choice(texts)
                elif r < 0.60:
                    op = rnd.choice(simple)
                elif r < 0.80:
                    op = "\x1b[%d%s" % (rnd.randint(0, 3), rnd.choice(counted))
                elif r < 0.88:
                    final = rnd.choice(modes)
                    private = "?" if final[0] == "?" else ""
                    op = "\x1b[%s%d%s" % (private, rnd.choice((0, 1, 2, 22)), final[-1])
                elif r < 0.94:
                    top = rnd.randint(1, t.rows)
                    op = "\x1b[%d;%dr" % (top, rnd.randint(top, t.rows))
                else:
                    op = "\x1b[%d;%dH" % (rnd.randint(1, t.rows), rnd.randint(1, t.cols))
                trail.append(repr(op))
            try:
                if op is None:
                    t.resize(cols, rows)
                else:
                    t.feed(op.encode("utf-8"))
            except Exception as exc:
                raise AssertionError("seed %d: %s: %s at %s (last ops %s)"
                                     % (seed, type(exc).__name__, exc, trail[-1],
                                        ", ".join(trail[-6:])))
            ops += 1
            bad = problems(t, cut)
            if bad:
                raise AssertionError("seed %d after %s: %s (last ops %s)"
                                     % (seed, trail[-1], bad[:3], ", ".join(trail[-6:])))
    return "%d operations" % ops


@case("vt", "vs15_on_cut_head_in_last_column")
def _vt_vs15_on_cut_head_in_last_column():
    # A column cut leaves the head of a wide emoji in the new last column with no tail, and the
    # resize keeps the cursor's pending wrap there. VS15 then attaches to that head with prev.left
    # 0 (Terminal.print's grapheme block), and Ghostty looks for the tail at
    # cursorCellLeft(prev.left - 1), an unsigned underflow whose result is undefined (a known gap).
    # The model narrows the head, ends the pending wrap and keeps the row whole.
    t = _term(5, 1, "\x1b[?1049h\x1b[1;4H\u2764\ufe0f".encode("utf-8"))
    eq(_cell(t.snapshot(), 3, 0)[2], 2, "the heart is wide at columns 3 and 4")
    t.resize(4, 1)
    t.feed("\ufe0e".encode("utf-8"))
    snap = t.snapshot()
    eq(len(snap.cells[0]), 4, "the row is still 4 cells wide")
    eq(_cell(snap, 3, 0), ("\u2764\ufe0f\ufe0e", _cell(snap, 3, 0)[1], 1),
       "the head is narrow and took VS15")
    eq((_cursor_xy(snap), t.alternate.pending), ((3, 0), False), "the pending wrap ended")


GRAPHEME_CASES = (
    # name, cols, rows, mode 2027, code points, (cursor x, cursor y), checks
    ("vs16_2027_off", 5, 5, False, (0x2764, 0xFE0F), (1, 0), "vs16_2027_off"),
    ("invalid_vs16", 80, 80, True, (ord("x"), 0xFE0F), (1, 0), "invalid_vs16"),
    ("multicodepoint_2027", 80, 80, True, (0x1F468, 0x200D, 0x1F469, 0x200D, 0x1F467), (2, 0),
     "multicodepoint"),
    ("keypad_vs15", 80, 80, True, (0x23, 0xFE0E), (1, 0), "keypad_vs15"),
    ("keypad_vs16", 80, 80, True, (0x23, 0xFE0F), (2, 0), "keypad_vs16"),
    ("skin_tone_valid_base", 80, 80, True, (0x1F44B, 0x1F3FF), (2, 0), "skin_valid"),
    ("skin_tone_non_base", 80, 80, True, (0x22, 0x1F3FF, 0x22), (4, 0), "skin_non_base"),
    ("vs15_narrow", 5, 5, True, (0x2614, 0xFE0E), (1, 0), "vs15_narrow"),
    ("vs15_on_narrow_emoji", 5, 5, True, (0x26C8, 0xFE0E), (1, 0), "vs15_narrow_emoji"),
    ("invalid_vs15_after_emoji", 80, 80, True, (0x1F9E0, 0xFE0E), (2, 0), "invalid_vs15_wide"),
    ("invalid_vs15_in_zwj", 80, 80, True, (0x1F469, 0xFE0E, 0x200D, 0x1F466), (2, 0), "zwj"),
    ("vs15_pending_wrap", 4, 5, True, (0x1F34B, 0x2614, 0xFE0E), (3, 0), "vs15_pending"),
    ("vs16_next_line", 3, 5, True, (0x23, 0xFE0F), (2, 1), "vs16_next_line"),
    ("vs16_pending_wrap", 3, 5, True, (0x23, 0xFE0F), (2, 0), "vs16_pending"),
    ("vs16_2027", 5, 5, True, (0x2764, 0xFE0F), (2, 0), "vs16_2027"),
)


def _grapheme_checks(name, snap, t):
    cells = snap.cells
    if name == "vs16_2027_off":
        eq(cells[0][0][0], "\u2764\ufe0f",
           "the heart keeps its narrow width and takes the selector")
        eq(cells[0][0][2], 1, "narrow")
    elif name == "invalid_vs16":
        eq(cells[0][0][0], "x", "x stays alone")
        eq(cells[0][1][0], " ", "the invalid selector takes no cell")
    elif name == "multicodepoint":
        eq(cells[0][0][0], "\U0001F468\u200d\U0001F469\u200d\U0001F467",
           "the family is one cluster")
        eq(cells[0][0][2], 2, "wide")
        eq(cells[0][1][2], 0, "spacer tail")
    elif name == "keypad_vs15":
        eq(cells[0][0][0], "#\ufe0e", "# with VS15 is one narrow cell")
        eq(cells[0][0][2], 1, "narrow")
    elif name == "keypad_vs16":
        eq(cells[0][0][0], "#\ufe0f", "# with VS16 is one wide cell")
        eq(cells[0][0][2], 2, "wide")
    elif name == "skin_valid":
        eq(cells[0][0][0], "\U0001F44B\U0001F3FF", "the skin tone joins a waving hand")
        eq(cells[0][0][2], 2, "wide")
    elif name == "skin_non_base":
        eq(cells[0][0][0], '"', "the quote is narrow")
        eq(cells[0][1][2], 2, "the skin tone after a quote is its own wide cell")
        eq(cells[0][3][0], '"', "the closing quote follows at column 3")
    elif name == "vs15_narrow":
        eq(_row(snap, 0), "\u2614\ufe0e", "umbrella with VS15 reads as one cluster")
        eq(cells[0][0][2], 1, "narrow after VS15")
        eq(cells[0][1][2], 1, "its old tail is narrow too")
    elif name == "vs15_narrow_emoji":
        eq(cells[0][0][0], "\u26c8\ufe0e", "thunder cloud with VS15")
        eq(cells[0][0][2], 1, "narrow")
    elif name == "invalid_vs15_wide":
        eq(cells[0][0][0], "\U0001F9E0", "brain stays alone")
        eq(cells[0][0][2], 2, "wide")
        eq(cells[0][1][2], 0, "spacer tail")
    elif name == "zwj":
        eq(cells[0][0][0], "\U0001F469\u200d\U0001F466", "the ZWJ sequence joins one wide cell")
        eq(cells[0][0][2], 2, "wide")
    elif name == "vs15_pending":
        eq(_row(snap, 0), "\U0001F34B\u2614\ufe0e", "lemon then umbrella with VS15")
        eq(cells[0][2][0], "\u2614\ufe0e", "the umbrella cell holds VS15")
        eq(cells[0][2][2], 1, "narrow")
        eq(cells[0][0][2], 2, "the lemon is still wide")
        eq(cells[0][1][2], 0, "its tail stays")
        eq(t.active.pending, False, "VS15 ended the pending wrap (Zig: !pending_wrap)")
    elif name == "vs16_next_line":
        eq(cells[0][2][2], 1, "the old cell at the edge became a spacer head (reads blank)")
        eq(t.active.grid[0].wide[2], 3, "spacer head")
        eq(cells[1][0][0], "#\ufe0f", "# with VS16 on the next line")
        eq(cells[1][0][2], 2, "wide")
        eq(cells[1][1][2], 0, "spacer tail")
        eq(t.active.pending, False, "no pending wrap after the wide cell (Zig: !pending_wrap)")
    elif name == "vs16_pending":
        eq(cells[0][1][0], "#\ufe0f", "# with VS16 at column 1")
        eq(cells[0][1][2], 2, "wide")
        eq(cells[0][2][2], 0, "spacer tail at the edge")
        eq(t.active.pending, True,
           "the wide cell ends at the edge: pending wrap (Zig: pending_wrap)")
    elif name == "vs16_2027":
        eq(_row(snap, 0), "\u2764\ufe0f", "heart with VS16")
        eq(cells[0][0][2], 2, "wide")


def _make_grapheme_case(name, cols, rows, mode, cps, cursor, check):
    def run():
        data = GRAPHEME_PREFIX.get(name, b"") + _cp_bytes(cps)
        t = _term(cols, rows, data, grapheme=mode)
        snap = t.snapshot()
        eq(_cursor_xy(snap), cursor, "cursor")
        _grapheme_checks(check, snap, t)
    return run


for _name, _cols, _rows, _mode, _cps, _cur, _check in GRAPHEME_CASES:
    case("vt", "grapheme_"
         + _name)(_make_grapheme_case(_name, _cols, _rows, _mode, _cps, _cur, _check))


@case("perf", "replay_text")
def _perf_replay_text():
    # the budget is 4.5 MB/s for an emulator replay; a test asserts twice the budget as a time: 8 MB
    # in 2 * (8 / 5.0) s, which is 2.5 MB/s. The stream is fed in pieces, each timed on its own
    from vkitty import perfclock as pc
    from vkitty.vt import HOP_TMUX, Terminal
    mb = 1000000
    stream = _tui_stream(8 * mb, 7)
    t = Terminal(160, 50)
    samples = _timed_pieces(t.feed, stream)
    none_note = _perf_limit("perf/replay_text", pc.rate_verdict(samples, 2.5e6),
                            "replay of 8 MB under hop none", _mb_s, "2.5 MB/s")
    # the same model behind tmux (hop tmux, the UTF-8 rule included) on the first 4 MB
    tmux_term = Terminal(160, 50, hop=HOP_TMUX)
    samples = _timed_pieces(tmux_term.feed, stream[:4 * mb])
    tmux_note = _perf_limit("perf/replay_text", pc.rate_verdict(samples, 2.5e6),
                            "replay of 4 MB under hop tmux", _mb_s, "2.5 MB/s")
    return "%s; %s" % (none_note, tmux_note)


# ------------------------------------------------------------ kgp and media ---
# The Kitty graphics core: vkitty.kgp (commands, storage, transmission, responses, deletes) and
# vkitty.media (where the bytes of a non-direct transmission come from). The expected values are
# Ghostty 1.3.1's (graphics_command.zig, graphics_exec.zig, graphics_image.zig,
# graphics_storage.zig, Terminal.zig, stream.zig, device_status.zig, termio/stream_handler.zig)
# and tmux 3.5a's (input.c) for the hop rules. The answer and wire-byte cases use only vkitty.vt.

_SPEC_CREATED = set()   # ("path", path) and ("shm", name) this spec made; removed at the end


def _apc(payload):
    """A graphics APC command: ESC _ G payload ESC backslash."""
    return b"\x1b_G" + payload + b"\x1b\\"


def _ok(image_id, placement_id=0):
    """The bytes of an OK answer (Response.encode) for an image id and placement id."""
    extra = (",p=%d" % placement_id) if placement_id else ""
    return ("\x1b_Gi=%d%s;OK\x1b\\" % (image_id, extra)).encode("ascii")


def _err(image_id, message):
    """The bytes of an error answer (Response.encode) for an image id."""
    return ("\x1b_Gi=%d;%s\x1b\\" % (image_id, message)).encode("ascii")


def _raises(exc_type, fn, *args):
    try:
        fn(*args)
    except exc_type as exc:
        return exc
    raise AssertionError("%s was not raised by %s"
                         % (exc_type.__name__, getattr(fn, "__name__", fn)))


def _b64(data):
    import base64
    if isinstance(data, str):
        data = data.encode("utf-8")
    return base64.b64encode(data)


def _kterm(cols=10, rows=4, hop="none", **kw):
    from vkitty.vt import Terminal
    return Terminal(cols, rows, hop=hop, **kw)


def _kimgs(term):
    """Image ids in the active screen's storage, sorted."""
    return sorted(term._kitty(term.active).images)


def _kplaces(term):
    """Placements of the active screen's storage: 'id:i' (an internal pin), 'id:eP' (a pin with
    placement id P) or 'id:v' (a virtual placement)."""
    out = set()
    for (image_id, pkey), place in term._kitty(term.active).placements.items():
        if place.location is None:
            out.add("%d:v" % image_id)
        elif pkey[0] == "i":
            out.add("%d:i" % image_id)
        else:
            out.add("%d:e%d" % (image_id, pkey[1]))
    return out


def _pil_png(mode, size, values, **save_kw):
    import io
    from PIL import Image as PILImage
    im = PILImage.new(mode, size)
    im.putdata(values)
    buf = io.BytesIO()
    im.save(buf, "PNG", **save_kw)
    return buf.getvalue()


def _raw_png(depth, ctype, width, rows, trns=None):
    """A PNG built by hand, so 16-bit and sub-byte samples are exact: one filter-0 scanline per
    element of rows, and an optional tRNS chunk."""
    import struct
    import zlib

    def chunk(kind, body):
        crc = zlib.crc32(kind + body) & 0xFFFFFFFF
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", crc)

    ihdr = struct.pack(">IIBBBBB", width, len(rows), depth, ctype, 0, 0, 0)
    out = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
    if trns is not None:
        out += chunk(b"tRNS", trns)
    raw = b"".join(b"\x00" + row for row in rows)
    return out + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")


def _png_chunk(kind, body, bad_crc=False):
    """One PNG chunk with its CRC-32 (bad_crc flips the checksum)."""
    import struct
    import zlib
    crc = zlib.crc32(body, zlib.crc32(kind)) & 0xFFFFFFFF
    if bad_crc:
        crc ^= 1
    return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", crc)


def _png_encode_row(ftype, row, prior, bpp):
    """One scanline with filter ftype (PNG 9.2), encoded here so the expected pixels are not the
    decoder's own output."""
    out = bytearray()
    for i, x in enumerate(row):
        a = row[i - bpp] if i >= bpp else 0
        b = prior[i]
        c = prior[i - bpp] if i >= bpp else 0
        if ftype == 0:
            pred = 0
        elif ftype == 1:
            pred = a
        elif ftype == 2:
            pred = b
        elif ftype == 3:
            pred = (a + b) // 2
        else:
            p = a + b - c
            pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
            pred = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
        out.append((x - pred) & 0xFF)
    return bytes([ftype]) + bytes(out)


def _png_filtered(rows, filters, bpp):
    """The filtered scanlines of rows (bytes), with filters[i] for row i."""
    out = b""
    prior = bytes(len(rows[0]))
    for row, ftype in zip(rows, filters):
        out += _png_encode_row(ftype, row, prior, bpp)
        prior = row
    return out


_PNG_SIG = b"\x89PNG\r\n\x1a\n"
_RGB_2X2_RAW = b"".join(b"\x00" + bytes([1, 2, 3, 4, 5, 6]) for _ in range(2))
_RGB_2X2_RGBA = "010203ff040506ff010203ff040506ff"
_PIX16 = (
    ((0x8000, 0x4000, 0x2000), (0x8001, 0x4000, 0x2000), (0x8000, 0x4000, 0x2001)),
    ((0x1234, 0x5678, 0x9ABC), (0x8000, 0x4000, 0x2000), (0xFFFF, 0x0000, 0x8000)),
)


def _png_rows():
    """(name, PNG file bytes, expected RGBA hex, or None for invalid data) for kgp/formats. The
    expected values are what wuffs 0.4.0-alpha.9, the PNG decoder Ghostty 1.3.1 pins, gives for
    these exact bytes (the rules are in kgp._png_walk)."""
    import struct
    import zlib
    z = zlib.compress(_RGB_2X2_RAW)

    def ihdr(w, h, depth, colour, interlace=0, compression=0, bad=False):
        return _png_chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, depth, colour, compression, 0,
                                                interlace), bad)

    def idat(body, bad=False):
        return _png_chunk(b"IDAT", body, bad)

    iend = _png_chunk(b"IEND", b"")
    trns16 = struct.pack(">HHH", 0x8000, 0x4000, 0x2000)
    rows = [
        # valid: damage that wuffs never reads (ancillary CRCs, IEND, what follows the zlib end)
        ("gama_bad_crc", _PNG_SIG + ihdr(2, 2, 8, 2)
         + _png_chunk(b"gAMA", struct.pack(">I", 45455), True) + idat(z) + iend, _RGB_2X2_RGBA),
        ("text_bad_crc", _PNG_SIG + ihdr(2, 2, 8, 2) + _png_chunk(b"tEXt", b"k\x00v", True)
         + idat(z) + iend, _RGB_2X2_RGBA),
        ("unknown_ancillary_bad_crc", _PNG_SIG + ihdr(2, 2, 8, 2)
         + _png_chunk(b"zzZz", b"abc", True) + idat(z) + iend, _RGB_2X2_RGBA),
        ("iend_bad_crc", _PNG_SIG + ihdr(2, 2, 8, 2) + idat(z) + _png_chunk(b"IEND", b"", True),
         _RGB_2X2_RGBA),
        ("no_iend", _PNG_SIG + ihdr(2, 2, 8, 2) + idat(z), _RGB_2X2_RGBA),
        ("junk_after_iend", _PNG_SIG + ihdr(2, 2, 8, 2) + idat(z) + iend + b"junk!",
         _RGB_2X2_RGBA),
        ("idat_after_zlib_end", _PNG_SIG + ihdr(2, 2, 8, 2) + idat(z) + idat(b"garbage!!") + iend,
         _RGB_2X2_RGBA),
        ("idat_bad_crc_after_zlib_end", _PNG_SIG + ihdr(2, 2, 8, 2) + idat(z) + idat(b"xx", True)
         + iend, _RGB_2X2_RGBA),
        ("idat_split_then_tail", _PNG_SIG + ihdr(2, 2, 8, 2) + idat(z[:5]) + idat(z[5:])
         + _png_chunk(b"tEXt", b"a\x00b") + iend, _RGB_2X2_RGBA),
        ("trailer_cut", _PNG_SIG + ihdr(2, 2, 8, 2) + idat(z) + struct.pack(">I", 99) + b"tEXt",
         _RGB_2X2_RGBA),
        ("trns_after_idat", _PNG_SIG + ihdr(1, 1, 8, 0) + idat(zlib.compress(b"\x00\x80"))
         + _png_chunk(b"tRNS", b"\x00\x80") + iend, "808080ff"),
        ("rgb16_trns_lowdiff", _PNG_SIG + ihdr(2, 1, 16, 2) + _png_chunk(b"tRNS", trns16)
         + idat(zlib.compress(b"\x00" + b"\x80\x00\x40\x00\x20\x00\x80\x01\x40\x00\x20\x00"))
         + iend, "00000000804020ff"),
        # damaged: refused
        ("bad_ihdr_crc", _PNG_SIG + ihdr(2, 2, 8, 2, bad=True) + idat(z) + iend, None),
        ("bad_idat_crc", _PNG_SIG + ihdr(2, 2, 8, 2) + idat(z, True) + iend, None),
        ("bad_adler", _PNG_SIG + ihdr(2, 2, 8, 2) + idat(z[:-1] + bytes([z[-1] ^ 1])) + iend,
         None),
        ("no_adler", _PNG_SIG + ihdr(2, 2, 8, 2) + idat(z[:-4]) + iend, None),
        ("bad_filter", _PNG_SIG + ihdr(2, 2, 8, 2)
         + idat(zlib.compress(b"\x07" + _RGB_2X2_RAW[1:])) + iend, None),
        ("extra_raw_bytes", _PNG_SIG + ihdr(2, 2, 8, 2)
         + idat(zlib.compress(_RGB_2X2_RAW + b"\x00\x00\x00")) + iend, None),
        ("short_raw", _PNG_SIG + ihdr(2, 2, 8, 2) + idat(zlib.compress(_RGB_2X2_RAW[:-5])) + iend,
         None),
        ("idat_ends_early_no_iend", _PNG_SIG + ihdr(2, 2, 8, 2) + idat(z[:-4]), None),
        ("file_cut_in_idat", (_PNG_SIG + ihdr(2, 2, 8, 2) + idat(z) + iend)[:-20], None),
        ("zlib_end_mid_chunk", _PNG_SIG + ihdr(2, 2, 8, 2) + idat(z + b"\x00") + iend, None),
        ("extra_one_raw_byte", _PNG_SIG + ihdr(2, 2, 8, 2)
         + idat(zlib.compress(_RGB_2X2_RAW + b"\x00")) + iend, None),
        ("idat_crc_first_of_two", _PNG_SIG + ihdr(2, 2, 8, 2) + idat(z[:5], True) + idat(z[5:])
         + iend, None),
        ("unknown_critical", _PNG_SIG + ihdr(2, 2, 8, 2) + _png_chunk(b"ZZZZ", b"abc") + idat(z)
         + iend, None),
        ("unknown_critical_bad_crc", _PNG_SIG + ihdr(2, 2, 8, 2)
         + _png_chunk(b"ZZZZ", b"abc", True) + idat(z) + iend, None),
        ("iend_before_idat", _PNG_SIG + ihdr(2, 2, 8, 2) + iend + idat(z), None),
        ("text_between_idat", _PNG_SIG + ihdr(2, 2, 8, 2) + idat(z[:5])
         + _png_chunk(b"tEXt", b"a\x00b") + idat(z[5:]) + iend, None),
        ("plte_gray", _PNG_SIG + ihdr(2, 2, 8, 0) + _png_chunk(b"PLTE", b"\x00\x00\x00")
         + idat(zlib.compress((b"\x00\x01\x02") * 2)) + iend, None),
        ("plte_twice", _PNG_SIG + ihdr(2, 2, 8, 3) + _png_chunk(b"PLTE", b"\x00\x00\x00")
         + _png_chunk(b"PLTE", b"\x00\x00\x00") + idat(zlib.compress(b"\x00\x00\x00" * 2)) + iend,
         None),
        ("plte_bad_length", _PNG_SIG + ihdr(2, 2, 8, 3) + _png_chunk(b"PLTE", b"\x00\x00")
         + idat(zlib.compress(b"\x00\x00\x00" * 2)) + iend, None),
        ("missing_palette", _PNG_SIG + ihdr(2, 2, 8, 3) + idat(zlib.compress(b"\x00\x00\x00" * 2))
         + iend, None),
        ("trns_twice", _PNG_SIG + ihdr(1, 1, 8, 0) + _png_chunk(b"tRNS", b"\x00\x01")
         + _png_chunk(b"tRNS", b"\x00\x01") + idat(zlib.compress(b"\x00\x80")) + iend, None),
        ("trns_gray_len3", _PNG_SIG + ihdr(1, 1, 8, 0) + _png_chunk(b"tRNS", b"\x00\x80\x00")
         + idat(zlib.compress(b"\x00\x80")) + iend, None),
        ("trns_rgb_len2", _PNG_SIG + ihdr(1, 1, 8, 2) + _png_chunk(b"tRNS", b"\x00\x80")
         + idat(zlib.compress(b"\x00\x80\x80\x80")) + iend, None),
        ("ihdr_width_zero", _PNG_SIG + ihdr(0, 2, 8, 2) + idat(z) + iend, None),
        ("ihdr_depth4_rgb", _PNG_SIG + ihdr(2, 2, 4, 2) + idat(z) + iend, None),
        ("ihdr_interlace2", _PNG_SIG + ihdr(2, 2, 8, 2, interlace=2) + idat(z) + iend, None),
        ("ihdr_compression1", _PNG_SIG + ihdr(2, 2, 8, 2, compression=1) + idat(z) + iend, None),
    ]
    # 16-bit RGB with tRNS: a pixel matches only when all six bytes match (the low bytes too),
    # and the scanline filters must be undone first (filters 0 to 4, and a mix)
    want16 = "00000000804020ff804020ff12569aff00000000ff0080ff"
    for name, filters in (("t16_f0", (0, 0)), ("t16_f1", (1, 1)), ("t16_f2", (2, 2)),
                          ("t16_f3", (3, 3)), ("t16_f4", (4, 4)), ("t16_mix", (1, 4))):
        raw = _png_filtered([b"".join(struct.pack(">HHH", *p) for p in row) for row in _PIX16],
                            filters, 6)
        rows.append((name, _PNG_SIG + ihdr(3, 2, 16, 2) + _png_chunk(b"tRNS", trns16)
                     + idat(zlib.compress(raw)) + iend, want16))
    # Adam7: a 5 x 3 image, a pixel is transparent where (x + y) % 3 is 0
    width, height = 5, 3
    image = [[(0x8000 if (x + y) % 3 == 0 else 0x1100, 0x4000, 0x2000) for x in range(width)]
             for y in range(height)]
    raw = b""
    for x0, y0, dx, dy in ((0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4),
                           (1, 0, 2, 2), (0, 1, 1, 2)):
        xs, ys = range(x0, width, dx), range(y0, height, dy)
        if not xs or not ys:
            continue
        sub = [b"".join(struct.pack(">HHH", *image[y][x]) for x in xs) for y in ys]
        raw += _png_filtered(sub, [i % 5 for i in range(len(sub))], 6)
    want_adam7 = "".join("00000000" if (x + y) % 3 == 0 else "114020ff"
                         for y in range(height) for x in range(width))
    rows.append(("t16_adam7", _PNG_SIG + ihdr(width, height, 16, 2, interlace=1)
                 + _png_chunk(b"tRNS", trns16) + idat(zlib.compress(raw)) + iend, want_adam7))
    rows.extend(_png_adam7_height1_rows(ihdr, idat, iend))
    rows.extend(_png_adam7_split_rows(ihdr, idat, iend))
    rows.extend(_png_zlib_stream_rows(ihdr, idat, iend, z))
    return rows


def _cut_at_output(z, size):
    """The smallest cut of the zlib stream z whose first part decompresses to exactly `size` bytes
    with the stream not at its end: a chunk that ends where the needed bytes end, with the decoder
    having to read on to see whether more come."""
    import zlib
    for cut in range(2, len(z)):
        d = zlib.decompressobj()
        if len(d.decompress(z[:cut])) == size and not d.eof:
            return cut
    raise AssertionError("no cut of the stream gives %d bytes" % size)


def _png_adam7_split_rows(ihdr, idat, iend):
    """Interlaced images one row high, at the edges of the stop (see _png_adam7_height1_rows).
    The Adler-32 of a stream that goes on by exactly one byte is not read (the stream's end is
    seen only with that byte). A chunk that ends where the needed bytes end: wuffs stops when its
    decoder reports a short write, and a stored block with bytes left says so without reading on,
    so that chunk's CRC is never checked; a Huffman block has to read the next code first (a short
    read), so the chunk's CRC is checked and a bad one is refused. The same holds for a stored
    block that follows a Huffman block. A stream that ends exactly there keeps every check, and
    its Adler-32 may be split over chunks."""
    import struct
    import zlib
    _px, raw5, want5, raw1, want1 = _adam7_images()
    surplus = b"\x07"
    rows = []
    for name, w, raw, want in (("5x1", 5, raw5, want5), ("1x1", 1, raw1, want1)):
        head = _PNG_SIG + ihdr(w, 1, 8, 2, interlace=1)
        for level in (0, 9):
            zx = zlib.compress(raw + surplus, level)
            rows.append(("adam7_%s_extra1_bad_adler_level%d" % (name, level),
                         head + idat(zx[:-4] + b"\x00\x00\x00\x00") + iend, want))
            rows.append(("adam7_%s_extra1_no_adler_level%d" % (name, level),
                         head + idat(zx[:-4]) + iend, want))
        cut = 2 + 5 + len(raw)       # the zlib header, the stored block header, the needed bytes
        for count in (1, 7):
            zx = zlib.compress(raw + surplus * count, 0)
            tag = "adam7_%s_stored_split_extra%d" % (name, count)
            rows.append((tag, head + idat(zx[:cut]) + idat(zx[cut:]) + iend, want))
            rows.append((tag + "_bad_crc_first",
                         head + idat(zx[:cut], True) + idat(zx[cut:]) + iend, want))
            rows.append((tag + "_bad_crc_second",
                         head + idat(zx[:cut]) + idat(zx[cut:], True) + iend, want))
        zx = zlib.compress(raw, 0)
        rows.append(("adam7_%s_stored_split_exact" % name,
                     head + idat(zx[:cut]) + idat(zx[cut:]) + iend, want))
        rows.append(("adam7_%s_stored_split_exact_bad_crc_first" % name,
                     head + idat(zx[:cut], True) + idat(zx[cut:]) + iend, None))
        z = zlib.compress(raw)
        rows.append(("adam7_%s_exact_trailer_split" % name,
                     head + idat(z[:-2]) + idat(z[-2:]) + iend, want))
        rows.append(("adam7_%s_exact_trailer_split_bad" % name,
                     head + idat(z[:-2]) + idat(z[-2:-1] + bytes([z[-1] ^ 1])) + iend, None))
        rows.append(("adam7_%s_exact_trailer_split_then_byte" % name,
                     head + idat(z[:-2]) + idat(z[-2:] + b"\x00") + iend, None))
    head = _PNG_SIG + ihdr(5, 1, 8, 2, interlace=1)
    # a bad zlib header is refused where the stop would otherwise hide it (the file Pillow reads
    # is rebuilt from the needed bytes). The dictionary row: after the header wuffs reads 4 bytes
    # of dictionary id, which a decoder that ignored the flag would take for the start of an empty
    # stored block (00 00 00 ff ff, the last byte being the stream's first)
    zx = zlib.compress(raw5 + surplus * 7)
    empty_stored = b"\x00\x00\x00\xff\xff"
    image = raw5 + surplus * 7
    final = b"\x01" + struct.pack("<HH", len(image), len(image) ^ 0xFFFF) + image
    rows.append(("adam7_5x1_extra_bad_method", head + idat(b"\x79" + zx[1:]) + iend, None))
    rows.append(("adam7_5x1_extra_bad_window", head + idat(b"\x88\x1c" + zx[2:]) + iend, None))
    rows.append(("adam7_5x1_extra_bad_parity",
                 head + idat(zx[:1] + bytes([zx[1] ^ 1]) + zx[2:]) + iend, None))
    rows.append(("adam7_5x1_extra_dictionary",
                 head + idat(b"\x78\xbb" + empty_stored + final
                             + struct.pack(">I", zlib.adler32(image))) + iend, None))
    packer = zlib.compressobj(9, zlib.DEFLATED, 15, 9, zlib.Z_FIXED)
    zx = packer.compress(raw5 + surplus * 40) + packer.flush()
    cut = _cut_at_output(zx, len(raw5))
    rows.append(("adam7_5x1_huffman_split", head + idat(zx[:cut]) + idat(zx[cut:]) + iend, want5))
    rows.append(("adam7_5x1_huffman_split_bad_crc_first",
                 head + idat(zx[:cut], True) + idat(zx[cut:]) + iend, None))
    rows.append(("adam7_5x1_huffman_split_bad_crc_second",
                 head + idat(zx[:cut]) + idat(zx[cut:], True) + iend, want5))
    # a Huffman block, a sync flush (an empty stored block), then a final stored block that
    # holds the rest of the needed bytes and the surplus
    packer = zlib.compressobj(9, zlib.DEFLATED, -15, 9, zlib.Z_FIXED)
    first = packer.compress(raw5[:10]) + packer.flush(zlib.Z_SYNC_FLUSH)
    rest = raw5[10:] + surplus * 3
    stored = b"\x01" + struct.pack("<HH", len(rest), len(rest) ^ 0xFFFF) + rest
    zx = (b"\x78\x01" + first + stored
          + struct.pack(">I", zlib.adler32(raw5 + surplus * 3)))
    cut = 2 + len(first) + 5 + len(raw5) - 10
    rows.append(("adam7_5x1_mixed_split", head + idat(zx[:cut]) + idat(zx[cut:]) + iend, want5))
    rows.append(("adam7_5x1_mixed_split_bad_crc_first",
                 head + idat(zx[:cut], True) + idat(zx[cut:]) + iend, want5))
    rows.append(("adam7_5x1_mixed_split_bad_crc_second",
                 head + idat(zx[:cut]) + idat(zx[cut:], True) + iend, want5))
    return rows


def _png_zlib_stream_rows(ihdr, idat, iend, z):
    """The zlib header and trailer over IDAT chunks (z is a valid stream of the 2 x 2 image):
    each is read as wuffs reads it, whatever the chunks cut."""
    head = _PNG_SIG + ihdr(2, 2, 8, 2)
    return [
        ("zlib_header_split", head + idat(z[:1]) + idat(z[1:]) + iend, _RGB_2X2_RGBA),
        ("zlib_empty_chunk_first", head + idat(b"") + idat(z) + iend, _RGB_2X2_RGBA),
        ("zlib_bad_method", head + idat(b"\x79" + z[1:]) + iend, None),
        ("zlib_bad_window", head + idat(b"\x88\x1c" + z[2:]) + iend, None),
        ("zlib_bad_parity", head + idat(z[:1] + bytes([z[1] ^ 1]) + z[2:]) + iend, None),
        ("zlib_dictionary", head + idat(b"\x78\xbb\x00\x00\x00\x01" + z[2:]) + iend, None),
        ("zlib_trailer_split", head + idat(z[:-2]) + idat(z[-2:]) + iend, _RGB_2X2_RGBA),
        ("zlib_trailer_bytewise", head + idat(z[:-4]) + idat(z[-4:-3]) + idat(z[-3:-2])
         + idat(z[-2:-1]) + idat(z[-1:]) + iend, _RGB_2X2_RGBA),
        ("zlib_trailer_split_bad", head + idat(z[:-2]) + idat(z[-2:-1] + bytes([z[-1] ^ 1]))
         + iend, None),
        ("zlib_trailer_split_then_byte", head + idat(z[:-2]) + idat(z[-2:] + b"\x00") + iend,
         None),
    ]


def _adam7_images():
    """The interlaced images one row high that the Adam7 rows use: (the five pixels, the scanlines
    of the 5 x 1 image, its RGBA hex, the scanlines of the 1 x 1 image, its RGBA hex). In the 5 x 1
    image pass 1 is column 0, pass 2 column 4, pass 4 column 2 and pass 6 columns 1 and 3."""
    px = [bytes([2, 3, 4]), bytes([14, 15, 16]), bytes([10, 11, 12]), bytes([17, 18, 19]),
          bytes([6, 7, 8])]
    raw5 = (b"\x00" + px[0] + b"\x00" + px[4] + b"\x00" + px[2] + b"\x00" + px[1] + px[3])
    want5 = "".join(p.hex() + "ff" for p in px)
    raw1 = b"\x00" + px[0]
    want1 = px[0].hex() + "ff"
    return px, raw5, want5, raw1, want1


def _png_adam7_height1_rows(ihdr, idat, iend):
    """Interlaced images one row high. Adam7's last pass (7) is empty for them, and wuffs
    0.4.0-alpha.9 checks for too much data only in pass 7 (or in a non-interlaced image), so it
    stops once the last non-empty pass is full: data after it is never read, whatever follows (a
    bad Adler-32, a bad CRC of the chunk it ends in). When the stream ends exactly at the needed
    size every check stays, and a taller interlaced image or a non-interlaced one refuses extra
    data as before."""
    import zlib
    px, raw5, want5, raw1, want1 = _adam7_images()
    surplus = b"\x07"
    rows = []
    for name, w, raw, want in (("5x1", 5, raw5, want5), ("1x1", 1, raw1, want1)):
        head = _PNG_SIG + ihdr(w, 1, 8, 2, interlace=1)
        z = zlib.compress(raw)
        rows.append(("adam7_%s_exact" % name, head + idat(z) + iend, want))
        rows.append(("adam7_%s_exact_bad_adler" % name,
                     head + idat(z[:-4] + b"\x00\x00\x00\x00") + iend, None))
        rows.append(("adam7_%s_exact_no_adler" % name, head + idat(z[:-4]) + iend, None))
        for count in (1, 7, 63):
            zx = zlib.compress(raw + surplus * count)
            rows.append(("adam7_%s_extra%d" % (name, count), head + idat(zx) + iend, want))
        zx = zlib.compress(raw + surplus * 40)
        rows.append(("adam7_%s_extra_bad_adler" % name,
                     head + idat(zx[:-4] + b"\x00\x00\x00\x00") + iend, want))
        rows.append(("adam7_%s_extra_bad_idat_crc" % name, head + idat(zx, True) + iend, want))
        rows.append(("adam7_%s_extra_second_idat_bad_crc" % name,
                     head + idat(zx[:12]) + idat(zx[12:], True) + iend, want))
        if w == 5:
            # the needed bytes are not all in the first part of the stream: it must go on, and
            # the next chunk is not an IDAT (the 1 x 1 image's few bytes arrive in the first part)
            rows.append(("adam7_%s_extra_cut_stream" % name,
                         head + idat(zx[:len(zx) // 2 + 6]) + iend, None))
            rows.append(("adam7_%s_extra_then_other_chunk" % name,
                         head + idat(zx[:12]) + _png_chunk(b"tEXt", b"a\x00b") + iend, None))
        rows.append(("adam7_%s_bytes_after_zlib_end" % name,
                     head + idat(z + b"\x00\x00") + iend, None))
    # the same extra data is refused where pass 7 is not empty (two rows: pass 7 is row 1), and
    # without interlacing
    tall = raw5 + b"\x00" + px[0] + px[1] + px[2] + px[3] + px[4]
    head2 = _PNG_SIG + ihdr(5, 2, 8, 2, interlace=1)
    rows.append(("adam7_5x2_exact", head2 + idat(zlib.compress(tall)) + iend, want5 + want5))
    rows.append(("adam7_5x2_extra1", head2 + idat(zlib.compress(tall + surplus)) + iend, None))
    rows.append(("adam7_5x2_extra40", head2 + idat(zlib.compress(tall + surplus * 40)) + iend,
                 None))
    flat = b"\x00" + px[0] + px[1] + px[2] + px[3] + px[4]
    rows.append(("plain_5x1_extra", _PNG_SIG + ihdr(5, 1, 8, 2)
                 + idat(zlib.compress(flat + surplus * 9))
                 + iend, None))
    return rows


# ---------------------------------------------------------------- kgp: parser ---

@case("kgp", "parse_rules")
def _kgp_parse_rules():
    from vkitty import kgp
    cmd = kgp.parse(b"a=T,f=100,i=1,q=2;AAAA")
    eq(cmd.action, "T", "a=T is transmit and display")
    eq(cmd.quiet, 2, "q=2 answers failures only")
    eq(cmd.transmission.format, "png", "f=100 is PNG")
    eq(cmd.transmission.image_id, 1, "i=1")
    eq(cmd.display.image_id, 1, "T also parses the display keys")
    eq(cmd.data, b"\x00\x00\x00", "AAAA decodes to three zero bytes")
    # a value of one non-digit character is stored as its code: t=f is the file medium
    eq(kgp.parse(b"a=t,t=f,f=32,s=1,v=1;AAAA").transmission.medium, "f", "t=f is the file medium")
    # z is a signed 32-bit value
    eq(kgp.parse(b"a=p,i=1,z=-5;").display.z, -5, "z=-5 is signed")
    # a key longer than one character: its value is ignored, and so is every pair after it,
    # because Ghostty's control_key_ignore state waits for the next '=' and then for ';'
    eq(kgp.parse(b"a=p,ab=5,i=3;").display.image_id, 0, "ab=5 and the i=3 after it are ignored")
    # a value longer than 11 characters is ignored, and so is the pair after it: value_ignore
    # moves to key_ignore at the ',', which waits for the next '=' (the pairs before it are kept)
    cmd = kgp.parse(b"a=p,i=1,z=123456789012345,x=5;")
    eq((cmd.display.image_id, cmd.display.z, cmd.display.x), (1, 0, 0),
       "a 15-character z is ignored, i before it is kept, x after it is ignored")
    # the limit is 11 characters: "-2147483648" (11) is kept, "-12345678901" (12) is ignored
    eq(kgp.parse(b"a=p,z=-2147483648;").display.z, -2147483648, "an 11-character z is kept")
    cmd = kgp.parse(b"a=p,i=1,z=-12345678901;")
    eq((cmd.display.image_id, cmd.display.z), (1, 0), "a 12-character z is ignored")
    # Zig's parseInt (lib/std/fmt.zig, 0.15.2): '_' may separate digits but not start or end the
    # value, '+' and '-' are signs, -0 is 0 for an unsigned key, and the value must fit the type
    eq(kgp.parse(b"a=p,i=1_0;").display.image_id, 10, "1_0 is 10")
    eq(kgp.parse(b"a=p,i=1__0;").display.image_id, 10, "two underscores between digits are fine")
    eq(kgp.parse(b"a=p,i=-0;").display.image_id, 0, "-0 is 0 for an unsigned key")
    eq(kgp.parse(b"a=p,i=-00;").display.image_id, 0, "-00 is 0 too")
    eq(kgp.parse(b"a=p,i=4294967295;").display.image_id, 4294967295, "the largest u32")
    eq(kgp.parse(b"a=p,z=+5;").display.z, 5, "a plus sign is accepted")
    eq(kgp.parse(b"a=p,i=_;").display.image_id, ord("_"), "one non-digit character is its code")
    for bad in (b"a=p,i=_10;", b"a=p,i=10_;", b"a=p,i=-1;", b"a=p,i=4294967296;", b"a=p,i=+-1;"):
        _raises(kgp.ParseError, kgp.parse, bad)
    # a=x is an unknown action: a parse error, with the message the answer would carry
    exc = _raises(kgp.ParseError, kgp.parse, b"a=x;")
    check(exc is not None, "a=x is a parse error")
    # base64 without padding decodes; invalid base64 and q=3 are parse errors
    eq(kgp.parse(b"a=t,f=32,s=1,v=1;AAAA/w").data, b"\x00\x00\x00\xff", "base64 without padding")
    exc = _raises(kgp.ParseError, kgp.parse, b"a=t;AAA!")
    eq(str(exc), "EINVAL: invalid data", "invalid base64 is EINVAL: invalid data")
    _raises(kgp.ParseError, kgp.parse, b"a=t,q=3;")
    # a command that ends in a key (the parser is waiting for its '='), and an empty one, are
    # parse errors; U takes only 0 or 1
    exc = _raises(kgp.ParseError, kgp.parse, b"a=p,i=1,x")
    eq(str(exc), "invalid format", "a=p,i=1,x ends in a key")
    exc = _raises(kgp.ParseError, kgp.parse, b"")
    eq(str(exc), "invalid format", "ESC _ G ESC \\ is an empty command")
    _raises(kgp.ParseError, kgp.parse, b"a=p,i=1,U=2;")
    eq(kgp.parse(b"a=p,i=1,U=1;").display.virtual, 1, "U=1 is a virtual placement")


@case("kgp", "parse_error_no_response")
def _kgp_parse_error_no_response():
    # A parse error answers nothing, adds a warning and changes no state (Ghostty apc.zig logs
    # the error and drops the command).
    t = _kterm()
    t.feed(_apc(b"a=x,i=3;"))
    t.feed(_apc(b"a=t,i=4,f=32,s=1,v=1;AAA!"))
    eq(t.responses, [], "no answer to a parse error, even with an id")
    eq(_kimgs(t), [], "no state changed")
    check(any(w.startswith("kitty graphics protocol error") for w in t.warnings),
          "a warning names the protocol error: %r" % t.warnings)
    # an APC that does not start with G is not a graphics command: ignored, no warning at all
    t = _kterm()
    t.feed(_apc(b"")[:2] + b"Xa=t,i=4,f=32,s=1,v=1;AAAA/w==" + b"\x1b\\")
    eq((t.responses, t.warnings, _kimgs(t)), ([], [], []), "a non-G APC is ignored silently")
    # the empty command is a parse error too, and is logged
    t = _kterm()
    t.feed(b"\x1b_G\x1b\\")
    eq(t.responses, [], "an empty graphics command answers nothing")
    check(any(w.startswith("kitty graphics protocol error") for w in t.warnings),
          "and is logged: %r" % t.warnings)


# ------------------------------------------------------ kgp: answers and storage ---

# The base64 payloads of Ghostty 1.3.1's simd build (simdutf 5.2.8 base64_to_binary with its
# default options, kgp._decode_data): ASCII space, tab, LF and CR are skipped anywhere, and a form
# feed too in a short payload or in the tail (a form feed in the first 64 character blocks of a
# long payload is refused on arm64, see _BASE64_FF_ROWS); at most two '=' end the input, and
# padded input has a length that is a multiple of 4; a length of 1 mod 4 is invalid. Each
# expected value (hex, or None for invalid data) is what that build gives for the bytes.
_BASE64_ROWS = (
    (b"AAAA/w==", "000000ff"), (b"AAAA\n/w==", "000000ff"), (b"AAAA/w==\r\n", "000000ff"),
    (b"AA AA/w==", "000000ff"), (b"AAAA\t/w==", "000000ff"), (b"AAAA\x0c/w==", "000000ff"),
    (b"AAAA\x0b/w==", None), (b"AAAA/w= =", "000000ff"), (b"AAAA/w ==", "000000ff"),
    (b"AA== ", "00"), (b"AA==\n", "00"), (b"AA=\n=", "00"), (b"A A==", "00"),
    (b"   ", ""), (b" AAAA", "000000"), (b" =", None), (b"AAAA/w=", None), (b"AAAA=", None),
    (b"AAA==", None), (b"A===", None), (b"AA=", None), (b"AAAA==", None), (b"AAAA====", None),
    (b"AB==", "00"), (b"AB", "00"), (b"ABC", "0010"), (b"AAAAAA==", "00000000"),
    (b"AAAAAAA=", "0000000000"), (b"AAAA/w", "000000ff"), (b"A", None), (b"AAAAA", None),
    (b"AAAA A", None), (b"AAAA/w===", None), (b"AA==AAAA", None), (b"AAAA_w==", None),
    (b"+/+/", "fbffbf"), (b"AA\x00A", None), (b"AA\xc3\xa9", None), (b"", ""),
    (b"AAAA\x00AAAA", None), (b"AAAA\x80AAAA", None), (b"AAA\x00AAA", None),
    (b"AAA\x80AAA", None), (b"AAA\x00AA", None), (b"AAA\x80AA", None),
    (b"AAAA\x00\x00", None), (b"AA\x00AA\x00", None),
    (b"A" * 4096, "00" * 3072),
)


def _ff_row(length, at, tail=None):
    """The base64 text of `length` bytes (0 to 255 cycled) with a form feed inserted at index
    `at` of that text, so the form feed counts in the payload length. With `tail` the '=' padding
    is replaced by it (the padding and white space around it)."""
    import base64
    data = bytes(i % 256 for i in range(length))
    text = base64.b64encode(data)
    if tail is not None:
        text = text.rstrip(b"=") + tail
    return text[:at] + b"\x0c" + text[at:], data.hex()


def _ff_tail_row(length, tail):
    """The base64 text of `length` bytes with its '=' padding replaced by `tail` (a string of the
    padding and white space, form feeds among it). The data must need exactly two '=' (a length
    of 1 mod 3), so that the padding in `tail` is the whole of it."""
    import base64
    data = bytes(i % 256 for i in range(length))
    text = base64.b64encode(data)
    assert text.endswith(b"==") and not text.endswith(b"===")
    return text.rstrip(b"=") + tail, data.hex()


# The form feed in a long payload. simdutf's arm64 kernel (the build for Ghostty 1.3.1 on a Mac
# with an M series chip, which the model follows) refuses a form feed inside the part it decodes
# in 64 character blocks: with srclen the payload length after the end of the input is trimmed,
# an FF at index p is refused when p < 64 * (srclen // 64) and skipped otherwise. The trim is
# simdutf's own and in this order: trailing white space, then one '=', then white space, then a
# second '=', and nothing after that (white space to the left of the second '=' stays in srclen).
# The x86 kernels (westmere, haswell) skip it anywhere. Rows: (text, hex of the data, refused on
# arm64).
_BASE64_FF_ROWS = (
    _ff_row(192, 30) + (True,),     # 257 characters, 64 * 4 = 256 > 30
    _ff_row(201, 260) + (False,),   # 269 characters, 64 * 4 = 256 <= 260: in the tail
    _ff_row(48, 10) + (True,),      # 65 characters, 64 > 10
    _ff_row(48, 63) + (True,),      # 65 characters, 63 < 64: the last index of the first block
    _ff_row(48, 64) + (False,),     # 65 characters, 64 is not below 64: skipped
    _ff_row(94, 100) + (False,),    # 126 characters, the FF and "==": srclen is 127 once the
                                    # padding is cut, so only the first block counts
    # white space between and after the two '=' (simdutf's trim stops at the second '=')
    _ff_tail_row(46, b" \x0c=\n=") + (True,),     # 62 characters, then " FF = LF =": srclen is 64
                                                # (white space left of the second '=' stays),
                                                # the FF at 63 is below 64
    _ff_tail_row(94, b" \x0c=\n=") + (True,),     # 126 characters, the same tail: srclen 128,
                                                # the FF at 127 is below 128
    _ff_tail_row(46, b"\x0c=\n=") + (False,),     # srclen 63, the FF at 62 is in the tail
    _ff_tail_row(46, b"=\x0c=") + (False,),        # srclen 62, the FF at 63 is past it
    _ff_tail_row(46, b"==\x0c") + (False,),        # the trailing FF is cut first, srclen 62
    _ff_tail_row(46, b" =\x0c =\n\x0c") + (False,),  # srclen 63: the FF at 64 is past it
    # the form feed in the body (62 characters and the FF make 63) and the end trimmed in order
    _ff_row(46, 10, b"==") + (False,),           # both '=' cut: srclen 63, below one block
    _ff_row(46, 10, b" ==") + (True,),           # the space is left of both: srclen 64
    _ff_row(46, 10, b"=\n=") + (False,),         # the LF between them is cut: srclen 63
    _ff_row(46, 10, b"==\n") + (False,),         # trailing white space is cut first: srclen 63
)


@case("kgp", "base64")
def _kgp_base64():
    from vkitty import kgp
    problems = []
    for raw, want in _BASE64_ROWS:
        try:
            got = kgp._decode_data(raw).hex()
        except kgp.ParseError:
            got = None
        if got != want:
            problems.append("%r: got %r, want %r" % (raw[:24], got, want))
    check(not problems, "%d of %d rows differ: %s" % (len(problems), len(_BASE64_ROWS),
                                                      "; ".join(problems[:4])))
    # the form feed rule of the arm64 kernel, and the x86 kernels' skip-anywhere rule
    eq(kgp._B64_ARCH, "arm64", "the model follows the arm64 build")
    problems = []
    for raw, want, refused in _BASE64_FF_ROWS:
        for arch in ("arm64", "x86", None):
            expect_refused = refused and arch != "x86"
            if arch is None:
                expect_refused = refused       # the default is the module constant, arm64
            try:
                got = kgp._decode_data(raw, arch=arch).hex()
            except kgp.ParseError:
                got = None
            if got != (None if expect_refused else want):
                problems.append("%d chars, FF at %d, arch %s: got %s" % (
                    len(raw), raw.index(b"\x0c"), arch, "refused" if got is None else "decoded"))
    check(not problems, "form feed rows differ: %s" % "; ".join(problems[:4]))
    # through a whole command: a newline in the payload is skipped; a bad pad is answered with
    # nothing, changes no state and is logged
    t = _kterm()
    t.feed(_apc(b"a=t,f=32,s=1,v=1,i=7;AAAA\n/w=="))
    eq(t.responses, [_ok(7)], "a newline in the payload is skipped")
    eq(t._kitty(t.active).images[7].data, bytes([0, 0, 0, 255]), "and the pixel is decoded")
    t = _kterm()
    t.feed(_apc(b"a=t,f=32,s=1,v=1,i=8;AAAA/w="))
    eq(t.responses, [], "a payload with a bad pad is answered with nothing")
    eq(_kimgs(t), [], "and stores nothing")
    check(any("kitty graphics protocol error" in w for w in t.warnings), "and the error is logged")
    return "%d rows" % len(_BASE64_ROWS)


@case("kgp", "responses")
def _kgp_responses():
    t = _kterm()
    t.feed(_apc(b"a=t,f=32,s=1,v=1,i=7;AAAA/w=="))
    eq(t.responses, [_ok(7)], "q=0 answers OK")
    t = _kterm()
    t.feed(_apc(b"a=t,f=32,s=1,v=1,i=7,q=1;AAAA/w=="))
    eq(t.responses, [], "q=1 answers errors only, and this is OK")
    t = _kterm()
    t.feed(_apc(b"a=t,f=32,s=1,v=1,i=7,q=2;AAAA/w=="))
    eq(t.responses, [], "q=2 answers nothing")
    for q, want in ((0, True), (1, True), (2, False)):
        t = _kterm()
        t.feed(_apc(b"a=t,f=32,s=2,v=2,i=7,q=%d;AAAA/w==" % q))
        eq(t.responses, [_err(7, "EINVAL: invalid data")] if want else [],
           "2x2 RGBA with 4 bytes at q=%d" % q)
    # i and I together: Ghostty's answer for this error carries neither id nor number, so
    # Response.encode writes nothing; the message is logged only
    t = _kterm()
    t.feed(_apc(b"a=t,f=32,s=1,v=1,i=7,I=3;AAAA/w=="))
    eq(t.responses, [], "i and I together: nothing is sent (Ghostty's answer has no id)")
    check(any("image ID and number are mutually exclusive" in w for w in t.warnings),
          "the error is logged: %r" % t.warnings)
    eq(_kimgs(t), [], "and nothing is stored")
    # a placement of an unknown image: ENOENT, answered with q=0 and silent with q=2
    t = _kterm()
    t.feed(_apc(b"a=p,i=99;"))
    eq(t.responses, [_err(99, "ENOENT: image not found")], "a=p,i=99 answers ENOENT")
    t.feed(_apc(b"a=p,i=99,q=2;"))
    eq(t.responses, [_err(99, "ENOENT: image not found")], "q=2 adds nothing")
    eq(t.stats["enoent"], 2, "every ENOENT counts, the q=2 one too")


@case("kgp", "query")
def _kgp_query():
    t = _kterm()
    t.feed(_apc(b"a=q,i=31,s=1,v=1,t=d,f=24;AAAA"))
    eq(t.responses, [_ok(31)], "a=q answers OK when the data loads")
    eq(_kimgs(t), [], "and stores nothing")
    eq(t.stats["queries"], 1, "queries counts Kitty a=q")
    t.feed(_apc(b"a=q,s=1,v=1,t=d,f=24;AAAA"))
    eq(len(t.responses), 1, "a=q without an id answers nothing (Ghostty's answer has no id)")
    # a number without an id: Ghostty's query() returns the error with neither id nor number,
    # so nothing is sent for it, and the error is logged
    t.feed(_apc(b"a=q,I=5,s=1,v=1,t=d,f=24;AAAA"))
    eq(len(t.responses), 1, "a=q with I and no i answers nothing either (no id and no number)")
    check(any("EINVAL: image ID required" in w for w in t.warnings), "and the error is logged")


@case("kgp", "chunked")
def _kgp_chunked():
    png = _pil_png("RGBA", (2, 2), [(i, 2 * i, 3 * i, 255) for i in range(4)], )
    b64 = _b64(png)
    a = (len(b64) // 3) // 4 * 4
    parts = [b64[:a], b64[a:2 * a], b64[2 * a:]]
    t = _kterm()
    t.feed(_apc(b"a=t,f=100,i=9,m=1;" + parts[0]))
    t.feed(_apc(b"i=5,m=1;" + parts[1]))          # keys other than m and q are ignored
    eq(t.responses, [], "no answer before the last chunk")
    check(t._kitty(t.active).loading is not None, "the image is still loading")
    t.feed(_apc(b"m=0;" + parts[2]))
    eq(t.responses, [_ok(9)], "one answer, after the last chunk")
    eq(_kimgs(t), [9], "stored once, under id 9")
    check(t._kitty(t.active).loading is None, "the loading state is cleared")
    # q=1 on the first chunk is inherited by the continuation: the OK is not sent
    t = _kterm()
    t.feed(_apc(b"a=t,f=100,i=9,q=1,m=1;" + parts[0]))
    t.feed(_apc(b"m=0;" + parts[1] + parts[2]))
    eq(t.responses, [], "q=1 is inherited from the first chunk")
    eq(_kimgs(t), [9], "the image is stored")


@case("kgp", "implicit_id")
def _kgp_implicit_id():
    t = _kterm()
    t.feed(_apc(b"a=t,f=32,s=1,v=1;AAAA/w=="))
    eq(t.responses, [], "an implicit id answers nothing")
    eq(_kimgs(t), [2147483647], "the image gets id 2147483647")
    eq(t._kitty(t.active).next_image_id, 2147483648, "the next automatic id is one more")
    # an image with a number and no id gets the automatic id too, and its answer names both
    t = _kterm()
    t.feed(_apc(b"a=t,f=32,s=1,v=1,I=5;AAAA/w=="))
    eq(t.responses, [b"\x1b_Gi=2147483647,I=5;OK\x1b\\"],
       "the answer carries the id and the number")
    eq(_kimgs(t), [2147483647], "the image has the automatic id")


def _check_png_rows():
    """Every row of _png_rows is answered as wuffs answers its file: the RGBA pixels, or invalid
    data with nothing stored. Reports every differing row, not only the first."""
    from vkitty.kgp import rgba_bytes
    rows = _png_rows()
    problems = []
    for name, png, want in rows:
        t = _kterm()
        t.feed(_apc(b"a=t,f=100,i=60;" + _b64(png)))
        if want is None:
            if t.responses != [_err(60, "EINVAL: invalid data")] or _kimgs(t):
                problems.append("%s: answered %r, stored %s" % (name, t.responses, _kimgs(t)))
            continue
        image = t._kitty(t.active).images.get(60)
        got = rgba_bytes(image).hex() if image is not None else None
        if got != want:
            problems.append("%s: got %r, want %r" % (name, got, want))
    check(not problems, "%d of %d PNG rows differ: %s" % (len(problems), len(rows),
                                                          "; ".join(problems[:4])))
    return "%d PNG rows" % len(rows)


@case("kgp", "deflate_walker")
def _kgp_deflate_walker():
    # _deflate_stored_left(data): the bytes the stored block that the end of the deflate input
    # falls inside still owes, and 0 anywhere else. Streams are built from known blocks (a fixed
    # Huffman block, a dynamic one, stored ones, joined by sync flushes), so the answer at every
    # cut of the stream is known: a stored block's length less the bytes of it in the input from
    # where its data starts, 0 in a header, in a Huffman block and past the final block. A block
    # that is walked wrongly (a code length, the extra bits of a length or a distance, a table)
    # moves the next stored block and changes the answer
    import struct
    import zlib
    from vkitty import kgp
    def numbers(seed):
        state = seed
        while True:
            state = (state * 1103515245 + 12345) & 0x7FFFFFFF
            yield state >> 8

    def pieces(seed):
        # random bytes, then copies of earlier stretches of 3 to 258 bytes at all distances, with
        # a few new bytes between them: a block of literals, lengths and distances
        g = numbers(seed)
        buf = bytearray(next(g) & 255 for _ in range(60))
        for _ in range(12):
            start = next(g) % (len(buf) - 5)
            buf += buf[start:start + (3, 4, 5, 9, 17, 40, 130, 258)[next(g) % 8]]
            buf += bytes(next(g) & 255 for _ in range(1 + next(g) % 5))
        return bytes(buf)

    g = numbers(1)
    equal = bytes(40 + next(g) % 50 for _ in range(900))
    fixed = (pieces(1), zlib.Z_FIXED, 1)
    # 50 literals of about the same frequency and no matches: a dynamic block whose code lengths
    # are mostly equal (repeats of the previous length in its header)
    repeated = (equal, zlib.Z_HUFFMAN_ONLY, 2)
    letters = bytes(range(97, 113))
    skewed = bytes(letters[(i * 2654435761 >> 7) % 16] for i in range(600))
    dynamic = (skewed + skewed[100:170] + bytes(letters[(i * 40503 >> 5) % 16] for i in range(100))
               + skewed[300:330], zlib.Z_DEFAULT_STRATEGY, 2)
    stored_a = bytes(range(37))
    stored_b = bytes((i * 7) % 256 for i in range(300))
    quick = b"The quick brown fox jumps over the lazy dog. "
    layouts = (
        [("huffman", fixed), ("stored", stored_a), ("huffman", dynamic), ("stored", stored_b)],
        [("stored", stored_a), ("huffman", dynamic), ("huffman", fixed), ("stored", stored_b)],
        [("huffman", repeated), ("stored", stored_a), ("huffman", fixed), ("stored", stored_b)],
        [("huffman", dynamic), ("stored", b"")],
        # the longest match (length code 285, length 258: 300 equal bytes) and a distance code with
        # extra bits (distance code 5, 7 to 8, one extra bit: "abcdefg" repeated), each in a fixed
        # block that a sync flush ends, then a stored block of 512 bytes
        [("huffman", (quick + b"x" * 300 + quick, zlib.Z_DEFAULT_STRATEGY, 1)),
         ("stored", bytes(range(256)) * 2)],
        [("huffman", (quick + b"abcdefg" * 40 + quick, zlib.Z_DEFAULT_STRATEGY, 1)),
         ("stored", bytes(range(256)) * 2)],
    )
    cuts_checked = 0
    for layout in layouts:
        out = bytearray()
        spans = []
        text = b""
        for kind, block in layout:
            if kind == "stored":
                out += b"\x00" + struct.pack("<HH", len(block), len(block) ^ 0xFFFF)
                spans.append((len(out), len(block)))
                out += block
                text += block
            else:
                data, strategy, want_type = block
                packer = zlib.compressobj(9, zlib.DEFLATED, -15, 9, strategy)
                part = packer.compress(data) + packer.flush(zlib.Z_SYNC_FLUSH)
                eq((part[0] >> 1) & 3, want_type, "the block type of the Huffman block built")
                out += part
                text += data
        out += b"\x03\x00"                   # a final empty fixed block
        eq(zlib.decompressobj(-15).decompress(bytes(out)), text, "the stream inflates")
        # every cut in and around a stored block, and one in 7 of the others (a block walked
        # wrongly shows at the stored blocks after it)
        cuts = set(range(0, len(out) + 1, 7))
        for start, length in spans:
            cuts.update(range(max(0, start - 8), min(len(out), start + length + 3) + 1))
        for cut in sorted(cuts):
            want = 0
            for start, length in spans:
                if start <= cut < start + length:
                    want = length - (cut - start)
            got = kgp._deflate_stored_left(bytes(out[:cut]))
            if got != want:
                eq(got, want, "bytes owed at cut %d of %d" % (cut, len(out)))
            cuts_checked += 1
    eq(kgp._deflate_stored_left(b""), 0, "no input")
    return "%d cuts" % cuts_checked


@case("kgp", "formats")
def _kgp_formats():
    import struct
    from vkitty.kgp import rgba_bytes
    t = _kterm()
    t.feed(_apc(b"a=t,f=24,s=2,v=1,i=1;" + _b64(bytes([10, 20, 30, 40, 50, 60]))))
    eq(rgba_bytes(t._kitty(t.active).images[1]), bytes([10, 20, 30, 255, 40, 50, 60, 255]),
       "f=24 is RGB, shown as RGBA with opaque alpha")
    t.feed(_apc(b"a=t,f=32,s=2,v=1,i=2;" + _b64(bytes([10, 20, 30, 40, 50, 60, 70, 80]))))
    eq(rgba_bytes(t._kitty(t.active).images[2]), bytes([10, 20, 30, 40, 50, 60, 70, 80]),
       "f=32 is RGBA as sent")
    # PNG of each colour type becomes RGBA (f=100)
    rgba_png = _pil_png("RGBA", (2, 1), [(1, 2, 3, 4), (5, 6, 7, 255)])
    rgb_png = _pil_png("RGB", (2, 1), [(1, 2, 3), (4, 5, 6)])
    gray_png = _pil_png("L", (2, 1), [100, 200])
    la_png = _pil_png("LA", (2, 1), [(100, 50), (200, 255)])
    from PIL import Image as PILImage
    import io
    pal = PILImage.new("P", (2, 1))
    pal.putpalette([255, 0, 0, 0, 255, 0] + [0] * (254 * 3))
    pal.putdata([0, 1])
    buf = io.BytesIO()
    pal.save(buf, "PNG", transparency=0)
    cases = (
        (rgba_png, bytes([1, 2, 3, 4, 5, 6, 7, 255])),
        (rgb_png, bytes([1, 2, 3, 255, 4, 5, 6, 255])),
        (gray_png, bytes([100, 100, 100, 255, 200, 200, 200, 255])),
        (la_png, bytes([100, 100, 100, 50, 200, 200, 200, 255])),
        (buf.getvalue(), bytes([255, 0, 0, 0, 0, 255, 0, 255])),
        # 16-bit samples keep their high byte (wuffs swizzle_xxxx__y_16be writes the high byte of
        # each sample); a 16-bit sample of 0x8000 is 0x80, 0x40ff is 0x40
        (_raw_png(16, 0, 2, [b"\x80\x00\x40\xff"]),
         bytes([0x80, 0x80, 0x80, 0xFF, 0x40, 0x40, 0x40, 0xFF])),
        (_raw_png(16, 4, 1, [b"\x80\x00\x40\xff"]), bytes([0x80, 0x80, 0x80, 0x40])),
        (_raw_png(16, 2, 1, [b"\x80\x00\x40\x00\x20\x00"]), bytes([0x80, 0x40, 0x20, 0xFF])),
        (_raw_png(16, 6, 1, [b"\x80\x00\x40\x00\x20\x00\x10\x00"]),
         bytes([0x80, 0x40, 0x20, 0x10])),
        # a tRNS value remaps a matching pixel to transparent black (wuffs remap_transparency:
        # all four bytes become 0), not to alpha 0 with its colour kept
        (_raw_png(16, 0, 2, [b"\x80\x00\x40\xff"], trns=b"\x80\x00"),
         bytes([0, 0, 0, 0, 0x40, 0x40, 0x40, 0xFF])),
        (_raw_png(8, 0, 2, [bytes([0x80, 0x40])], trns=b"\x00\x80"),
         bytes([0, 0, 0, 0, 0x40, 0x40, 0x40, 0xFF])),
        (_raw_png(8, 2, 2, [bytes([1, 2, 3, 4, 5, 6])], trns=struct.pack(">HHH", 1, 2, 3)),
         bytes([0, 0, 0, 0, 4, 5, 6, 0xFF])),
        (_raw_png(16, 2, 1, [b"\x80\x00\x40\x00\x20\x00"],
                  trns=struct.pack(">HHH", 0x8000, 0x4000, 0x2000)), bytes([0, 0, 0, 0])),
        # sub-byte gray is scaled to 8 bits: 1 bit 0 1 0 1, 2 bits 0 1 2 3, 4 bits 0 15
        (_raw_png(1, 0, 4, [bytes([0b01011010])]),
         bytes([0, 0, 0, 255, 255, 255, 255, 255, 0, 0, 0, 255, 255, 255, 255, 255])),
        (_raw_png(2, 0, 4, [bytes([0b00011011])]),
         bytes([0, 0, 0, 255, 85, 85, 85, 255, 170, 170, 170, 255, 255, 255, 255, 255])),
        (_raw_png(4, 0, 2, [bytes([0x0F])]), bytes([0, 0, 0, 255, 255, 255, 255, 255])),
        # a tRNS value of 1 at 2 bits is the sample 1, which is 85 after scaling: that pixel is
        # transparent black, the others keep their scaled gray
        (_raw_png(2, 0, 4, [bytes([0b00011011])], trns=b"\x00\x01"),
         bytes([0, 0, 0, 255, 0, 0, 0, 0, 170, 170, 170, 255, 255, 255, 255, 255])),
    )
    for n, (png, want) in enumerate(cases, start=10):
        t = _kterm()
        t.feed(_apc(b"a=t,f=100,i=%d;" % n + _b64(png)))
        img = t._kitty(t.active).images.get(n)
        check(img is not None and img.format == "rgba", "PNG %d is stored as RGBA: %r"
              % (n, t.responses))
        eq(rgba_bytes(img), want, "PNG %d pixels" % n)
    # zlib compressed RGB: ok; corrupt: decompression failed, and nothing is stored
    import zlib
    t = _kterm()
    t.feed(_apc(b"a=t,f=24,s=1,v=1,o=z,i=5;" + _b64(zlib.compress(bytes([9, 8, 7])))))
    eq(t.responses, [_ok(5)], "zlib data is decompressed")
    eq(rgba_bytes(t._kitty(t.active).images[5]), bytes([9, 8, 7, 255]), "and its pixels")
    t = _kterm()
    t.feed(_apc(b"a=t,f=24,s=1,v=1,o=z,i=6;" + _b64(b"not zlib at all")))
    eq(t.responses, [_err(6, "EINVAL: decompression failed")], "corrupt zlib")
    eq(_kimgs(t), [], "nothing is stored")
    # dimensions: 10001 is too large; 0 is required
    t = _kterm()
    t.feed(_apc(b"a=t,f=32,s=10001,v=1,i=7;AAAA/w=="))
    eq(t.responses, [_err(7, "EINVAL: dimensions too large")], "10001 px wide")
    t.feed(_apc(b"a=t,f=32,s=0,v=1,i=8;AAAA/w=="))
    eq(t.responses[-1], _err(8, "EINVAL: dimensions required"), "0 px wide")
    # the PNG path accepts PNG only: a GIF is invalid data
    import io as _io
    gbuf = _io.BytesIO()
    PILImage.new("RGB", (1, 1)).save(gbuf, "GIF")
    t = _kterm()
    t.feed(_apc(b"a=t,f=100,i=11;" + _b64(gbuf.getvalue())))
    eq(t.responses, [_err(11, "EINVAL: invalid data")], "a GIF given as PNG is invalid data")
    return _check_png_rows()


@case("kgp", "eviction")
def _kgp_eviction():
    from vkitty.vt import Terminal
    payload = _b64(bytes(64))           # one 4 x 4 RGBA image
    t = Terminal(10, 4, storage_limit=3 * 4 * 16)       # 192 bytes: three images
    for i in (1, 2, 3):
        t.feed(_apc(b"a=t,f=32,s=4,v=4,i=%d;" % i + payload))
    eq(_kimgs(t), [1, 2, 3], "three images fill the limit exactly")
    t.feed(_apc(b"a=t,f=32,s=4,v=4,i=4;" + payload))
    # Ghostty evicts while evicted > required: 64 required bytes make it drop two images
    eq(_kimgs(t), [3, 4], "the oldest unused images go first, two of them")
    # a placed image is used, so the unused ones go first even when they are newer
    t = Terminal(10, 4, storage_limit=3 * 4 * 16)
    for i in (1, 2, 3):
        t.feed(_apc(b"a=t,f=32,s=4,v=4,i=%d;" % i + payload))
    t.feed(b"\x1b[1;1H" + _apc(b"a=p,i=1,C=1;"))
    t.feed(_apc(b"a=t,f=32,s=4,v=4,i=4;" + payload))
    eq(_kimgs(t), [1, 4], "the placed image 1 survives; the unused 2 and 3 go")
    eq(_kplaces(t), {"1:i"}, "the placement of image 1 is kept")
    # an image bigger than the limit cannot be stored
    t = Terminal(10, 4, storage_limit=50)
    t.feed(_apc(b"a=t,f=32,s=4,v=4,i=7;" + payload))
    eq(t.responses, [_err(7, "ENOMEM: out of memory")], "a 64-byte image in a 50-byte limit")
    eq(_kimgs(t), [], "nothing is stored")
    # an image exactly the size of the limit is stored
    t = Terminal(10, 4, storage_limit=64)
    t.feed(_apc(b"a=t,f=32,s=4,v=4,i=7;" + payload))
    eq(t.responses, [_ok(7)], "a 64-byte image in a 64-byte limit")
    eq(_kimgs(t), [7], "is stored")


@case("kgp", "inflate_limit")
def _kgp_inflate_limit():
    # Ghostty's decompressZlib reads with .limited(max_size), and appendRemaining fails once the
    # limit is reached, so an output of exactly the limit is decompression failed (the limit is
    # a parameter here, so the edge is cheap to test)
    import zlib
    from vkitty import kgp
    from vkitty.media import MediaError
    data = zlib.compress(bytes(16))
    eq(kgp._inflate(data, limit=17), bytes(16), "a 16-byte output under a 17-byte limit is kept")
    exc = _raises(MediaError, kgp._inflate, data, 16)
    eq(exc.message, "EINVAL: decompression failed", "exactly the limit is decompression failed")
    # a zlib stream cut before its Adler-32 never ends: decompression failed, whatever the limit
    exc = _raises(MediaError, kgp._inflate, data[:-4], 1000)
    eq(exc.message, "EINVAL: decompression failed", "a stream without its Adler-32 is not finished")
    t = _kterm()
    t.feed(_apc(b"a=t,f=24,s=1,v=1,i=3,o=z;" + _b64(zlib.compress(bytes([1, 2, 3]))[:-4])))
    eq(t.responses, [_err(3, "EINVAL: decompression failed")], "answered when a command carries it")


@case("kgp", "ris_storage_limit")
def _kgp_ris_storage_limit():
    # Ghostty's Screen.reset replaces the storage with a new one that has the default limit (320
    # MB), so RIS lifts a configured limit, and a limit of 0 (protocol off) is lifted too. The
    # alternate screen is made with the primary's limit at that moment.
    payload = _b64(bytes(64))              # one 4 x 4 RGBA image
    t = _kterm(10, 4, storage_limit=50)
    t.feed(_apc(b"a=t,f=32,s=4,v=4,i=7;" + payload))
    eq(t.responses, [_err(7, "ENOMEM: out of memory")], "a 64-byte image is too big for 50 bytes")
    t.feed(b"\x1bc")
    t.feed(_apc(b"a=t,f=32,s=4,v=4,i=8;" + payload))
    eq(t.responses[-1], _ok(8), "after RIS the limit is the default, and the image fits")
    t = _kterm(10, 4, storage_limit=50)
    t.feed(b"\x1b[?1049h" + _apc(b"a=t,f=32,s=4,v=4,i=7;" + payload))
    eq(t.responses, [_err(7, "ENOMEM: out of memory")],
       "the alternate screen takes the 50-byte limit")
    t = _kterm(10, 4, storage_limit=0)
    t.feed(_apc(b"a=t,f=32,s=4,v=4,i=7;" + payload))
    eq(t.responses, [], "limit 0 turns the protocol off: no answer")
    t.feed(b"\x1bc" + _apc(b"a=t,f=32,s=4,v=4,i=8;" + payload))
    eq(t.responses, [_ok(8)], "RIS turns the protocol back on with the default limit")


@case("kgp", "virtual_parent")
def _kgp_virtual_parent():
    # a virtual placement (U=1) cannot refer to a parent (P): Ghostty answers the error with the
    # image id, and makes no placement
    t = _kterm()
    t.feed(_apc(b"a=t,f=32,s=1,v=1,i=1;AAAA/w=="))
    t.feed(_apc(b"a=p,i=1,U=1,P=3;"))
    eq(t.responses[-1], _err(1, "EINVAL: virtual placement cannot refer to a parent"),
       "the virtual placement with a parent is refused")
    eq(_kplaces(t), set(), "and nothing is placed")


@case("kgp", "transmit_stats")
def _kgp_transmit_stats():
    # the counters after a chunked upload, a retransmit and a delete: wire bytes are the
    # base64 length of each transmission (per image and in total), a transmission counts once,
    # however many chunks it has, and each delete counts once
    b64 = _b64(bytes(range(12)))            # 3 x 1 RGBA, 16 base64 characters
    t = _kterm()
    t.feed(_apc(b"a=t,f=32,s=3,v=1,i=9,m=1;" + b64[:8]))
    t.feed(_apc(b"m=0;" + b64[8:]))
    eq(t.stats["by_image"]["9"], {"transmissions": 1, "wire_bytes": 16, "medium": "d"},
       "one chunked transmission of 16 wire bytes, direct medium")
    eq(t.stats["transmit_wire_bytes"], 16, "the total counts both chunks")
    eq(t.stats["media"]["d"], 1, "a chunked upload counts once in the media counts")
    t.feed(_apc(b"a=t,f=32,s=3,v=1,i=9;" + b64))
    eq(t.stats["by_image"]["9"], {"transmissions": 2, "wire_bytes": 32, "medium": "d"},
       "a retransmit adds one transmission and its wire bytes")
    eq(t.stats["transmit_wire_bytes"], 32, "the total follows")
    eq(t.stats["since_prev_mark"]["transmit_wire_bytes"], 32, "and so does the count since a mark")
    t.feed(_apc(b"a=d,d=i,i=9"))
    eq(t.stats["deletes"], 1, "a delete counts once")
    eq(t.stats["queries"], 0, "and no transmission is a query")


@case("kgp", "delete_newest_number")
def _kgp_delete_newest_number():
    # d=n removes the placements of the newest image with a number (by transmit time) and d=N
    # also frees it when nothing uses it; the older image with the same number stays
    t = _kterm()
    t.feed(_apc(b"a=t,f=32,s=1,v=1,I=5;AAAA/w=="))        # older: id 2147483647
    t.feed(_apc(b"a=t,f=32,s=1,v=1,I=5;AAAA/w=="))        # newer: id 2147483648
    eq(_kimgs(t), [2147483647, 2147483648], "two images with number 5 and automatic ids")
    t.feed(_apc(b"a=p,I=5,p=1;"))
    eq(_kplaces(t), {"2147483648:e1"}, "a placement by number goes to the newest image")
    t.feed(_apc(b"a=d,d=n,I=5"))
    eq(_kplaces(t), set(), "d=n removes the newest image's placements")
    eq(_kimgs(t), [2147483647, 2147483648], "and keeps both images")
    t.feed(_apc(b"a=p,I=5,p=2;"))
    t.feed(_apc(b"a=d,d=N,I=5"))
    eq(_kplaces(t), set(), "d=N removes the newest image's placements")
    eq(_kimgs(t), [2147483647], "and frees the newest image, which nothing uses; the older stays")


# ------------------------------------------------------------------ kgp: deletes ---
# Base state: images 1 to 4 (1 x 1 RGBA). Placements: 1 is an internal pin at (0, 0); 2 is a pin
# with placement id 5 at (x 3, y 2) with z 5; 3 is a virtual placement; 4 has none. The rows
# give the placements and images left after the command (Ghostty 1.3.1), and kitty's when the
# profile differs (only r and R differ). "error" rows are parse errors: nothing changes.

_ALL_P = {"1:i", "2:e5", "3:v"}
_ALL_I = {1, 2, 3, 4}
_DELETE_MATRIX = [
    # name, command, ghostty placements, ghostty images, kitty override, parse error
    ("a", b"a=d", {"3:v"}, {1, 2, 3, 4}, None, False),
    ("A", b"a=d,d=A", {"3:v"}, {3}, None, False),
    ("i", b"a=d,d=i,i=1", {"2:e5", "3:v"}, {1, 2, 3, 4}, None, False),
    ("I", b"a=d,d=I,i=1", {"2:e5", "3:v"}, {2, 3, 4}, None, False),
    ("i virtual", b"a=d,d=i,i=3", {"1:i", "2:e5"}, {1, 2, 3, 4}, None, False),
    ("i with p", b"a=d,d=i,i=2,p=5", {"1:i", "3:v"}, {1, 2, 3, 4}, None, False),
    ("i p absent", b"a=d,d=i,i=2,p=6", _ALL_P, {1, 2, 3, 4}, None, False),
    ("I with p", b"a=d,d=I,i=2,p=5", {"1:i", "3:v"}, {1, 3, 4}, None, False),
    ("n absent", b"a=d,d=n,I=99", _ALL_P, _ALL_I, None, False),
    ("n without I", b"a=d,d=n", _ALL_P, _ALL_I, None, False),
    ("c", b"a=d,d=c", {"2:e5", "3:v"}, {1, 2, 3, 4}, None, False),
    ("C", b"a=d,d=C", {"2:e5", "3:v"}, {2, 3, 4}, None, False),
    ("p", b"a=d,d=p,x=4,y=3", {"1:i", "3:v"}, {1, 2, 3, 4}, None, False),
    ("P", b"a=d,d=P,x=4,y=3", {"1:i", "3:v"}, {1, 3, 4}, None, False),
    ("p x zero", b"a=d,d=p,x=0,y=3", _ALL_P, _ALL_I, None, False),
    ("p no cell", b"a=d,d=p", _ALL_P, _ALL_I, None, False),
    ("q", b"a=d,d=q,x=1,y=1,z=0", {"2:e5", "3:v"}, _ALL_I, None, False),
    ("q other z", b"a=d,d=q,x=1,y=1,z=1", _ALL_P, _ALL_I, None, False),
    ("Q", b"a=d,d=Q,x=1,y=1,z=0", {"2:e5", "3:v"}, {2, 3, 4}, None, False),
    ("x", b"a=d,d=x,x=1", {"2:e5", "3:v"}, _ALL_I, None, False),
    ("X", b"a=d,d=X,x=1", {"2:e5", "3:v"}, {2, 3, 4}, None, False),
    ("x zero", b"a=d,d=x,x=0", _ALL_P, _ALL_I, None, False),
    ("y", b"a=d,d=y,y=3", {"1:i", "3:v"}, _ALL_I, None, False),
    ("Y", b"a=d,d=Y,y=3", {"1:i", "3:v"}, {1, 3, 4}, None, False),
    ("y zero", b"a=d,d=y,y=0", _ALL_P, _ALL_I, None, False),
    ("z", b"a=d,d=z,z=0", {"2:e5", "3:v"}, _ALL_I, None, False),
    ("Z", b"a=d,d=Z,z=5", {"1:i", "3:v"}, {1, 3, 4}, None, False),
    # r removes every placement in ghostty (its range test is always true); kitty removes the
    # placements of images 1 to 2 only
    ("r", b"a=d,d=r,x=1,y=2", set(), _ALL_I, ({"3:v"}, _ALL_I), False),
    ("R", b"a=d,d=R,x=1,y=2", set(), {4}, ({"3:v"}, {3, 4}), False),
    # image 4 has no placement at all: kitty's R also frees every image of the range that nothing
    # refers to (graphics.c handle_delete_command); Ghostty's R frees only the images whose
    # placements it removed, and the lowercase r frees nothing
    ("r unplaced", b"a=d,d=r,x=1,y=4", set(), _ALL_I, None, False),
    ("R unplaced", b"a=d,d=R,x=1,y=4", set(), {4}, (set(), set()), False),
    ("r zero", b"a=d,d=r,x=0,y=3", _ALL_P, _ALL_I, None, False),
    ("r inverted", b"a=d,d=r,x=3,y=1", _ALL_P, _ALL_I, None, True),
    ("r no y", b"a=d,d=r,x=1", _ALL_P, _ALL_I, None, True),
    ("f", b"a=d,d=f", _ALL_P, _ALL_I, None, False),
    ("F", b"a=d,d=F", _ALL_P, _ALL_I, None, False),
    ("i no id", b"a=d,d=i", _ALL_P, _ALL_I, None, False),
]


# Cursor deletes with the cursor moved first (the base state leaves it at row 1, column 1, where
# placement 1 is): name, cursor move, command, placements and images left
_DELETE_CURSOR_ROWS = [
    ("c other row", b"\x1b[5;1H", b"a=d,d=c", _ALL_P, _ALL_I),
    ("C other row", b"\x1b[5;1H", b"a=d,d=C", _ALL_P, _ALL_I),
    ("c other column", b"\x1b[1;7H", b"a=d,d=c", _ALL_P, _ALL_I),
    ("c on the pin of 2", b"\x1b[3;4H", b"a=d,d=c", {"1:i", "3:v"}, _ALL_I),
]


def _matrix_term(profile):
    from vkitty.vt import Terminal
    t = Terminal(10, 6, profile=profile)
    for i in (1, 2, 3, 4):
        t.feed(_apc(b"a=t,f=32,s=1,v=1,i=%d;AAAA/w==" % i))
    t.feed(b"\x1b[1;1H" + _apc(b"a=p,i=1,C=1;"))
    t.feed(b"\x1b[3;4H" + _apc(b"a=p,i=2,p=5,C=1,z=5;"))
    t.feed(b"\x1b[1;1H" + _apc(b"a=p,i=3,U=1,c=2,r=2;"))
    t.feed(b"\x1b[1;1H")
    return t


@case("kgp", "deletes")
def _kgp_deletes():
    problems = []
    for profile in ("ghostty-1.3.1", "kitty"):
        for name, command, places, images, override, error in _DELETE_MATRIX:
            if profile == "kitty" and override is not None:
                places, images = override
            t = _matrix_term(profile)
            before = len(t.responses)
            t.feed(_apc(command))
            got_places, got_images = _kplaces(t), set(_kimgs(t))
            tag = "%s / %s" % (profile, name)
            if t.responses[before:]:
                problems.append("%s: a delete answered %r" % (tag, t.responses[before:]))
            if got_places != places:
                problems.append("%s: placements %s, want %s"
                                % (tag, sorted(got_places), sorted(places)))
            if got_images != images:
                problems.append("%s: images %s, want %s"
                                % (tag, sorted(got_images), sorted(images)))
            if error and not any("kitty graphics protocol error" in w for w in t.warnings):
                problems.append("%s: a parse error was not logged" % tag)
        # the cursor deletes (d=c, d=C) look at the cursor's row too: with the cursor on a row
        # the placements do not touch they delete nothing, and on their row they delete
        for name, move, command, places, images in _DELETE_CURSOR_ROWS:
            t = _matrix_term(profile)
            t.feed(move)
            t.feed(_apc(command))
            tag = "%s / %s" % (profile, name)
            if _kplaces(t) != places or set(_kimgs(t)) != images:
                problems.append("%s: placements %s images %s, want %s %s" % (
                    tag, sorted(_kplaces(t)), sorted(set(_kimgs(t))), sorted(places),
                    sorted(images)))
    check(not problems, "%d delete rows differ: %s" % (len(problems), "; ".join(problems[:6])))
    return "%d rows x 2 profiles" % (len(_DELETE_MATRIX) + len(_DELETE_CURSOR_ROWS))


@case("kgp", "per_screen")
def _kgp_per_screen():
    # an image sent on the alternate screen is not on the primary screen, and comes back when
    # the alternate screen is entered again while its virtual placement keeps it
    t = _kterm()
    t.feed(b"\x1b[?1049h")
    t.feed(_apc(b"a=t,f=32,s=1,v=1,i=5;AAAA/w=="))
    t.feed(_apc(b"a=p,i=5,U=1,c=1,r=1;"))
    t.feed(b"\x1b[?1049l")
    t.feed(_apc(b"a=p,i=5;"))
    eq(t.responses[-1], _err(5, "ENOENT: image not found"),
       "on the primary screen image 5 is absent")
    t.feed(b"\x1b[?1049h")
    t.feed(_apc(b"a=p,i=5,U=1,c=1,r=1;"))
    eq(t.responses[-1], _ok(5), "back on the alternate screen the image is still there")
    # ED 2 removes pins and keeps virtual placements
    t = _kterm()
    t.feed(_apc(b"a=t,f=32,s=1,v=1,i=6;AAAA/w=="))
    t.feed(_apc(b"a=t,f=32,s=1,v=1,i=7;AAAA/w=="))
    t.feed(_apc(b"a=t,f=32,s=1,v=1,i=8;AAAA/w=="))
    t.feed(_apc(b"a=p,i=6,C=1;"))
    t.feed(_apc(b"a=p,i=7,U=1,c=1,r=1;"))
    t.feed(b"\x1b[2J")
    eq(_kplaces(t), {"7:v"}, "ED 2 removes the pin and keeps the virtual placement")
    eq(_kimgs(t), [7], "image 6 (pin only) and image 8 (never placed) are freed")
    # RIS empties both screens and drops the alternate one
    t = _kterm()
    t.feed(_apc(b"a=t,f=32,s=1,v=1,i=8;AAAA/w=="))
    t.feed(b"\x1b[?1049h")
    t.feed(_apc(b"a=t,f=32,s=1,v=1,i=9;AAAA/w=="))
    t.feed(b"\x1bc")
    eq(_kimgs(t), [], "RIS empties the primary storage")
    check(t.alternate is None, "RIS drops the alternate screen")
    t.feed(b"\x1b[?1049h")
    eq(_kimgs(t), [], "the next alternate screen starts with no images")
    # ED 2 on the alternate screen deletes the alternate storage and leaves the primary one alone
    t = _kterm()
    t.feed(_apc(b"a=t,f=32,s=1,v=1,i=11;AAAA/w=="))
    t.feed(_apc(b"a=p,i=11,C=1;"))
    t.feed(b"\x1b[?1049h")
    t.feed(_apc(b"a=t,f=32,s=1,v=1,i=12;AAAA/w=="))
    t.feed(_apc(b"a=p,i=12,C=1;"))
    t.feed(b"\x1b[2J")
    eq((_kimgs(t), _kplaces(t)), ([], set()), "ED 2 emptied the alternate storage")
    t.feed(b"\x1b[?1049l")
    eq((_kimgs(t), _kplaces(t)), ([11], {"11:i"}), "and the primary storage is untouched")
    # ED 0, 1 and 3 keep every placement
    for mode in (b"0", b"1", b"3"):
        t = _kterm()
        t.feed(_apc(b"a=t,f=32,s=1,v=1,i=13;AAAA/w=="))
        t.feed(_apc(b"a=p,i=13,C=1;"))
        t.feed(b"\x1b[2;2H\x1b[" + mode + b"J")
        eq((_kimgs(t), _kplaces(t)), ([13], {"13:i"}), "ED %s keeps the placement" % mode.decode())


@case("kgp", "per_screen_unplaced")
def _kgp_per_screen_unplaced():
    # ED 2 frees an image that was sent and never placed (Ghostty's delete .all with images),
    # and keeps one that has a virtual placement
    t = _kterm()
    t.feed(_apc(b"a=t,f=32,s=1,v=1,i=8;AAAA/w=="))
    t.feed(_apc(b"a=t,f=32,s=1,v=1,i=9;AAAA/w=="))
    t.feed(_apc(b"a=p,i=9,U=1,c=1,r=1;"))
    t.feed(b"\x1b[2J")
    eq(_kimgs(t), [9], "the never-placed image 8 is freed by ED 2")
    t.feed(_apc(b"a=p,i=8;"))
    eq(t.responses[-1], _err(8, "ENOENT: image not found"), "and a later placement of it is ENOENT")
    t.feed(_apc(b"a=p,i=9,U=1,c=1,r=1;"))
    eq(t.responses[-1], _ok(9), "the virtually placed image 9 is kept")


@case("kgp", "per_screen_ed22_empty")
def _kgp_per_screen_ed22_empty():
    # CSI 22 J on a screen whose rows are all empty does not scroll, and still
    # removes a pin, because the graphics delete runs after the scroll whether it moved or not
    t = _kterm()
    t.feed(_apc(b"a=t,f=32,s=1,v=1,i=10;AAAA/w=="))
    t.feed(_apc(b"a=p,i=10,C=1;"))
    eq(_kplaces(t), {"10:i"}, "the pin is there before the clear")
    t.feed(b"\x1b[22J")
    eq(t._kitty(t.active).placements, {}, "CSI 22 J on an all-empty screen removes the pin")
    eq(_kimgs(t), [], "and frees the image nothing uses")


@case("kgp", "dcs_wrapped")
def _kgp_dcs_wrapped():
    import zlib
    from vkitty.tokens import tmux_wrap
    from vkitty.vt import HOP_TMUX
    png = _pil_png("RGBA", (2, 1), [(9, 8, 7, 255), (6, 5, 4, 255)])
    b64 = _b64(png)
    half = len(b64) // 2 // 4 * 4
    commands = [
        _apc(b"a=t,f=100,i=21,m=1;" + b64[:half]),
        _apc(b"m=0;" + b64[half:]),
        _apc(b"a=t,f=24,s=1,v=1,i=22,o=z,m=0;" + _b64(zlib.compress(bytes([1, 2, 3])))),
        _apc(b"a=q,i=23,s=1,v=1,f=24;AAAA"),
        _apc(b"a=T,f=32,s=1,v=1,i=24,c=1,r=1;AAAA/w=="),
        _apc(b"a=p,i=99;"),
        _apc(b"a=d,d=i,i=22"),
        _apc(b"a=t,f=32,s=2,v=2,i=25;AAAA/w=="),
    ]
    from vkitty.vt import Terminal
    raw = Terminal(10, 4)
    wrapped = Terminal(10, 4, hop=HOP_TMUX)
    for command in commands:
        raw.feed(command)
        wrapped.feed(tmux_wrap(command))
    eq(wrapped.responses, raw.responses, "the same answers behind tmux as raw")
    eq(_kimgs(wrapped), _kimgs(raw), "the same images")
    eq(_kplaces(wrapped), _kplaces(raw), "the same placements")
    eq(wrapped.snapshot().cursor, raw.snapshot().cursor, "the same cursor")
    eq(_tmux(wrapped.snapshot())["dropped_apc"], 0, "nothing dropped: every command was wrapped")


@case("kgp", "hop_rules")
def _kgp_hop_rules():
    from vkitty.tokens import tmux_wrap
    from vkitty.vt import HOP_NONE, HOP_TMUX
    command = _apc(b"a=t,f=32,s=1,v=1,i=7;AAAA/w==")
    t = _kterm(hop=HOP_TMUX)
    t.feed(command)
    eq(_kimgs(t), [], "a raw APC behind tmux stores nothing")
    eq(t.responses, [], "and answers nothing")
    check(any("raw APC dropped by tmux" in w for w in t.warnings), "a warning says so: %r"
          % t.warnings)
    eq(_tmux(t.snapshot())["dropped_apc"], 1, "counted as dropped")
    eq(t.stats["apc"], 0, "and it is not counted as a graphics command")
    t.feed(tmux_wrap(command))
    eq((t.stats["apc"], _kimgs(t)), (1, [7]), "the wrapped one is counted, and executes")
    t = _kterm(hop=HOP_NONE)
    t.feed(tmux_wrap(command))
    eq(_tmux(t.snapshot())["ignored_dcs"], 1, "the DCS tmux; is counted as ignored")
    check("DCS tmux passthrough ignored (hop none)" in t.warnings, "the warning is logged")
    # Ghostty's DCS ends at the first ESC of the doubled ESC (stream.zig and Parser.zig: ESC leaves
    # dcs_passthrough), and the APC after it runs as a raw APC, so a bare Ghostty executes the
    # wrapped command and answers it.
    eq(_kimgs(t), [7], "a bare Ghostty executes the APC inside the wrapper")
    eq(t.responses, [_ok(7)], "and answers it")


@case("kgp", "tmux_limit_drop")
def _kgp_tmux_limit_drop():
    from vkitty.tokens import tmux_wrap
    from vkitty.vt import HOP_TMUX
    data = b"\x01\x02\x03" * 262144                     # 786,432 bytes
    b64 = _b64(data)
    eq(len(b64), 1048576, "the base64 of the image is exactly the tmux input limit")
    t = _kterm(hop=HOP_TMUX)
    t.feed(tmux_wrap(_apc(b"a=t,f=24,s=512,v=512,i=9,q=2;" + b64)))
    eq(_kimgs(t), [], "one DCS of that size is dropped by tmux")
    eq(_tmux(t.snapshot())["discards"], 1, "and counted as a discard")
    t.feed(tmux_wrap(_apc(b"a=p,i=9;")))
    eq(t.responses, [_err(9, "ENOENT: image not found")], "the placement finds no image")
    eq(t.stats["enoent"], 1, "enoent counts that answer")
    half = len(b64) // 2
    t = _kterm(hop=HOP_TMUX)
    t.feed(tmux_wrap(_apc(b"a=t,f=24,s=512,v=512,i=9,q=2,m=1;" + b64[:half])))
    t.feed(tmux_wrap(_apc(b"m=0;" + b64[half:])))
    eq(_tmux(t.snapshot())["discards"], 0, "two halves of 524,288 characters are not dropped")
    t.feed(tmux_wrap(_apc(b"a=p,i=9;")))
    eq(t.responses, [_ok(9)], "and the image is stored and placed")


@case("kgp", "ghostty_rejects_animation")
def _kgp_ghostty_rejects_animation():
    # Ghostty 1.3.1 does not implement the animation actions. Its answer is an ERROR with neither
    # an id nor a number, so Response.encode writes nothing; the error is logged. No state changes.
    t = _kterm()
    for command in (b"a=f,i=7,c=1;AAAA", b"a=a,i=7,s=3", b"a=c,i=7,c=1,r=2"):
        t.feed(_apc(command))
    eq(t.responses, [], "the animation actions answer nothing")
    eq(_kimgs(t), [], "no image is stored")
    eq(_kplaces(t), set(), "no placement is made")
    for letter in ("f", "a", "c"):
        check("unsupported by ghostty-1.3.1: a=%s" % letter in t.warnings,
              "a=%s is warned about: %r" % (letter, t.warnings))
    check(sum("ERROR: unimplemented action" in w for w in t.warnings) == 3,
          "the ERROR is logged for each: %r" % t.warnings)


# ------------------------------------------------------------- answers and wire bytes ---

@case("kgp", "vt_answers_per_hop")
def _kgp_vt_answers_per_hop():
    # Ghostty 1.3.1 answers these itself, so behind tmux (which answers DA and DSR itself,
    # tmux input.c) the model answers none of them. vt_queries counts all seven; queries stays 0.
    from vkitty.tokens import tmux_wrap
    from vkitty.vt import HOP_NONE, HOP_TMUX, Terminal
    cases = [
        (b"\x1b[c", b"\x1b[?62;22;52c"),
        (b"\x1b[>c", b"\x1b[>1;10;0c"),
        (b"\x1b[=c", None),
        (b"\x1b[5n", b"\x1b[0n"),
        (b"\x1b[3;4H\x1b[6n", b"\x1b[3;4R"),
        (b"\x1b[?6n", None),
        (b"\x1b[5;6n", None),
    ]
    for stream, want in cases:
        got = []
        t = Terminal(10, 5, hop=HOP_NONE, respond=got.append)
        t.feed(stream)
        eq(got, [want] if want else [], "hop none answers %r as Ghostty does" % stream)
        eq(t.responses, got, "responses and the callback agree for %r" % stream)
    t = Terminal(10, 5, hop=HOP_NONE)
    t.feed(b"".join(stream for stream, _ in cases))
    eq(t.stats["vt_queries"], 7, "the seven queries are counted")
    eq(t.stats["queries"], 0, "and none of them is a Kitty query")
    got = []
    t = Terminal(10, 5, hop=HOP_TMUX, respond=got.append)
    t.feed(b"".join(stream for stream, _ in cases))
    eq(got, [], "behind tmux no VT query is answered")
    eq(t.responses, [], "and the model holds no answer")
    eq(t.stats["vt_queries"], 7, "they are still counted")
    t.feed(tmux_wrap(b"\x1b_Ga=q,i=31,s=1,v=1,f=24;AAAA\x1b\\"))
    eq(got, [b"\x1b_Gi=31;OK\x1b\\"], "a wrapped Kitty query is answered")
    eq(t.stats["queries"], 1, "and counted as a Kitty query")
    # DECID (ESC Z) is a primary device attributes request too
    t = Terminal(10, 5, hop=HOP_NONE)
    t.feed(b"\x1bZ")
    eq(t.responses, [b"\x1b[?62;22;52c"], "ESC Z answers as primary DA")
    eq(t.stats["vt_queries"], 1, "and is counted")


@case("kgp", "apc_wire_bytes")
def _kgp_apc_wire_bytes():
    # apc_bytes counts the bytes on the wire: a raw APC its own length, and a DCS body once.
    from vkitty.tokens import tmux_wrap
    from vkitty.vt import HOP_NONE, HOP_TMUX, Terminal
    raw = b"\x1b_Ga=d,d=a\x1b\\"
    t = Terminal(10, 4, hop=HOP_NONE)
    t.feed(raw)
    eq(t.stats["apc_bytes"], len(raw), "a raw APC adds its own wire length")
    eq(t.stats["since_prev_mark"]["apc_bytes"], len(raw), "and the same since the last mark")
    wrapped = tmux_wrap(raw + raw)
    t = Terminal(10, 4, hop=HOP_TMUX)
    t.feed(wrapped)
    eq(t.stats["apc"], 2, "two APC tokens reach the terminal")
    eq(t.stats["apc_bytes"], len(wrapped), "the DCS span is added once, not per APC")
    t = Terminal(10, 4, hop=HOP_TMUX)
    t.feed(raw)
    eq(t.stats["apc_bytes"], 0, "a raw APC behind tmux adds nothing")
    eq(_tmux(t.snapshot())["dropped_apc"], 1, "and is counted as dropped")


@case("kgp", "dsr_origin")
def _kgp_dsr_origin():
    # origin mode: CUP is relative to the top margin, and so is the cursor report
    # (device_status.zig reports the row relative to the top margin in origin mode). Row 2 of the
    # region 3..4 is the screen's row 4, which the report gives as row 2.
    t = _kterm(hop="none")
    t.feed(b"\x1b[3;4r\x1b[?6h\x1b[2;1H\x1b[6n")
    eq(t.responses, [b"\x1b[2;1R"],
       "the cursor report is relative to the top margin in origin mode")


@case("kgp", "query_wire_bytes")
def _kgp_query_wire_bytes():
    # a query sends its payload too, so its base64 length is counted in transmit_wire_bytes (the
    # schema says so); it stores nothing, so by_image has no entry for it
    t = _kterm()
    t.feed(_apc(b"a=q,i=31,s=1,v=1,t=d,f=24;AAAA"))
    eq(t.stats["transmit_wire_bytes"], 4, "a query's payload counts as transmitted")
    eq(t.stats["since_prev_mark"]["transmit_wire_bytes"], 4, "and since the last mark")
    eq(t.stats["by_image"], {}, "a query stores no image, so it has no by_image entry")
    t.feed(_apc(b"a=t,i=32,s=1,v=1,f=24;AAAA"))
    eq(t.stats["transmit_wire_bytes"], 8, "a transmission adds its own base64 length")
    eq(t.stats["by_image"]["32"]["wire_bytes"], 4, "and the image's entry counts it")
    # a transmission whose payload decodes but holds too little data for its size is refused when
    # it completes: its payload counts in the total and, the image never having been stored, in no
    # entry
    t = _kterm()
    t.feed(_apc(b"a=t,f=32,s=2,v=2,i=40;" + _b64(bytes(8))))
    eq(t.responses[-1], _err(40, "EINVAL: invalid data"), "too little data is refused")
    eq(t.stats["transmit_wire_bytes"], 12, "the refused payload counts in the total")
    eq(t.stats["by_image"], {}, "and makes no by_image entry")
    # an a=f frame load in the kitty profile counts in its image's entry once its data has been
    # read, whatever happens to the frame after that: too little data is refused, and the 12
    # characters count in the total and in the entry
    t = _kitty_term()
    t.feed(_apc(b"a=t,f=32,s=2,v=2,i=41;" + _b64(bytes(16))))
    eq((t.stats["transmit_wire_bytes"], t.stats["by_image"]["41"]["wire_bytes"]), (24, 24),
       "the image's own transmission")
    t.feed(_apc(b"a=f,f=32,s=2,v=2,i=41;" + _b64(bytes(8))))
    check(b"EINVAL" in t.responses[-1], "a frame with too little data is refused: %r"
          % (t.responses[-1],))
    eq((t.stats["transmit_wire_bytes"], t.stats["by_image"]["41"]["wire_bytes"]), (36, 36),
       "the frame's 12 characters count in the total and in the image's entry")


@case("kgp", "cursor_after_pin")
def _kgp_cursor_after_pin():
    # Terminal.zig: after a pin display with C=0 the cursor moves index() once per image row, then
    # setCursorPos(cursor.y, pin.x + cols + 1), whose row argument is 1-based: the last image row.
    t = _kterm(10, 3)
    t.feed(_apc(b"a=t,f=32,s=1,v=1,i=1;AAAA/w=="))
    t.feed(_apc(b"a=p,i=1;"))
    eq(t.snapshot().cursor[:2], (1, 0), "a 1 x 1 cell image leaves the cursor one column past it")
    t.feed(b"\x1b[2;1H" + _apc(b"a=p,i=1,c=1,r=3;"))
    eq(t.snapshot().cursor[:2], (1, 1),
       "a 3-row image at the bottom scrolls and ends on its last row")
    # C=1 leaves the cursor where it is
    t = _kterm(10, 3)
    t.feed(_apc(b"a=t,f=32,s=1,v=1,i=1;AAAA/w=="))
    t.feed(b"\x1b[2;4H" + _apc(b"a=p,i=1,C=1;"))
    eq(t.snapshot().cursor[:2], (3, 1), "C=1 does not move the cursor")


@case("kgp", "pin_cursor_sequence")
def _kgp_pin_cursor_sequence():
    # a pin display moves the cursor, so a second display lands after the first (C=0)
    t = _kterm(10, 3)
    t.feed(_apc(b"a=t,f=32,s=1,v=1,i=1;AAAA/w=="))
    t.feed(_apc(b"a=p,i=1,p=1;"))
    t.feed(_apc(b"a=p,i=1,p=2;"))
    eq(t.snapshot().cursor[:2], (2, 0), "two cells in a row: the cursor is after the second")
    eq(_kplaces(t), {"1:e1", "1:e2"}, "and both placements exist")
    # two placements of one image with no placement id are two placements (each gets its own
    # internal id), not one that is placed twice
    t = _kterm(10, 3)
    t.feed(_apc(b"a=t,f=32,s=1,v=1,i=1;AAAA/w=="))
    t.feed(_apc(b"a=p,i=1,C=1;"))
    t.feed(b"\x1b[2;3H" + _apc(b"a=p,i=1,C=1;"))
    eq(len(t._kitty(t.active).placements), 2, "two p=0 placements of image 1")
    t.feed(_apc(b"a=d,d=i,i=1"))
    eq(len(t._kitty(t.active).placements), 0, "d=i,i=1 removes both")


# ----------------------------------------------------------------------- media ---
# Shared memory objects and temporary files this spec makes are removed by the cases' finally
# blocks; the SIGTERM and SIGINT handlers and the end of main() remove anything left, and report it.

def _shm_exists(name):
    import _posixshmem
    try:
        fd = _posixshmem.shm_open(name, os.O_RDONLY, 0)
    except OSError:
        return False
    os.close(fd)
    return True


def _shm_make(name, data, size):
    """A shared memory object of `size` bytes holding `data` (one ftruncate, as macOS allows)."""
    import _posixshmem
    import mmap
    _SPEC_CREATED.add(("shm", name))
    try:
        fd = _posixshmem.shm_open(name, os.O_CREAT | os.O_EXCL | os.O_RDWR, 0o600)
    except FileExistsError:
        _posixshmem.shm_unlink(name)
        fd = _posixshmem.shm_open(name, os.O_CREAT | os.O_EXCL | os.O_RDWR, 0o600)
    try:
        os.ftruncate(fd, size)
        mm = mmap.mmap(fd, size)
        mm[:len(data)] = data
        mm.close()
    finally:
        os.close(fd)


def _remove_spec_file(kind, name):
    """Remove one object this spec made, if it still exists. Returns True when it did. A "dir" is
    a temporary folder and is removed with everything in it."""
    import _posixshmem
    if kind == "dir":
        existed = os.path.isdir(name)
        _drop_spec_dir(name)
        return existed
    try:
        if kind == "path":
            os.unlink(name)
        else:
            _posixshmem.shm_unlink(name)
        return True
    except OSError:
        return False


def _spec_tempdir():
    """A new temporary folder, registered so that every exit path removes it with its files."""
    import tempfile
    path = tempfile.mkdtemp(prefix="vk-spec-")
    _SPEC_CREATED.add(("dir", path))
    return path


def _drop_spec_dir(path):
    """Remove a temporary folder of the spec (and its contents) and forget it."""
    import shutil
    shutil.rmtree(path, ignore_errors=True)
    _SPEC_CREATED.discard(("dir", path))


def _spec_path(tmp, name, data):
    path = os.path.join(tmp, name)
    _SPEC_CREATED.add(("path", path))
    with open(path, "wb") as fh:
        fh.write(data)
    return path


@case("media", "file")
def _media_file():
    # Ghostty 1.3.1 reads a file from offset 0 whatever O is: readFile seeks, then reads through
    # File.Reader, which is positional at pos 0 (Zig 0.15.2 lib/std/fs/File.zig), so the seek has
    # no effect. appendRemaining (lib/std/Io/Reader.zig) returns StreamTooLong once the limit is
    # reached, so a file of S bytes or more (or 400 MB or more without S) is invalid data.
    from vkitty.vt import Terminal
    tmp = _spec_tempdir()
    try:
        big = _spec_path(tmp, "data.bin", bytes(range(32)))
        small = _spec_path(tmp, "small.bin", bytes(range(16)))
        t = Terminal(10, 2, tmpdir=tmp)
        t.feed(_apc(b"a=t,t=f,f=32,s=2,v=2,O=4,S=16,i=11;" + _b64(big)))
        eq(t.responses[-1], _err(11, "EINVAL: invalid data"),
           "O=4,S=16 over 32 bytes: the limit is reached, so invalid data")
        check(os.path.exists(big), "a plain file is not removed")
        t.feed(_apc(b"a=t,t=f,f=32,s=2,v=2,O=4,i=12;" + _b64(small)))
        eq(t.responses[-1], _ok(12), "O=4 with no S over 16 bytes is OK: the offset is ignored")
        eq(t._kitty(t.active).images[12].data, bytes(range(16)), "and the bytes are from offset 0")
        t.feed(_apc(b"a=t,t=f,f=32,s=2,v=2,S=17,i=13;" + _b64(small)))
        eq(t.responses[-1], _ok(13), "S=17 over 16 bytes is OK: the limit is not reached")
        t.feed(_apc(b"a=t,t=f,f=32,s=2,v=2,S=16,i=14;" + _b64(small)))
        eq(t.responses[-1], _err(14, "EINVAL: invalid data"),
           "S=16 over 16 bytes: the limit is reached, so invalid data")
        check(os.path.exists(small), "a plain file is never removed")
        eq(t.stats["media"]["f"], 4, "every file transmission is counted")
    finally:
        _drop_spec_dir(tmp)
        for name in ("data.bin", "small.bin"):
            _SPEC_CREATED.discard(("path", os.path.join(tmp, name)))


@case("media", "m_ignored")
def _media_m_ignored():
    # m is honoured only for the direct medium (graphics_command.zig): a temporary file with
    # m=1 is read at once, and no continuation is waited for
    from vkitty.vt import Terminal
    tmp = _spec_tempdir()
    path = os.path.join(tmp, "tty-graphics-protocol-m.rgba")
    try:
        _spec_path(tmp, "tty-graphics-protocol-m.rgba", bytes(range(16)))
        t = Terminal(10, 2, tmpdir=tmp)
        t.feed(_apc(b"a=t,t=t,f=32,s=2,v=2,i=51,m=1;" + _b64(path)))
        eq(t.responses, [_ok(51)], "with m=1 the temporary file is read and answered at once")
        eq(t._kitty(t.active).images[51].data, bytes(range(16)), "its bytes are the image")
        check(t._kitty(t.active).loading is None, "nothing is left loading")
    finally:
        _drop_spec_dir(tmp)
        _SPEC_CREATED.discard(("path", path))


@case("media", "shm_stat_size")
def _media_shm_stat_size():
    # readSharedMemory fails when the stat size is below the declared image (lib graphics_image.zig,
    # "shared memory size too small"). A query loads its data the same way, so it fails too (a
    # complete() length check would not, since a query never completes), and the object is
    # unlinked on that path as on every other after a successful open.
    from vkitty.vt import Terminal
    name = "/vk%d_4" % os.getpid()
    _SPEC_CREATED.add(("shm", name))
    try:
        _shm_make(name, bytes(64), 64)
        t = Terminal(10, 2)
        t.feed(_apc(b"a=q,t=s,f=32,s=100,v=100,i=34;" + _b64(name)))
        eq(t.responses, [_err(34, "EINVAL: invalid data")],
           "a query of 100 x 100 RGBA over a 64-byte object is invalid data")
        check(not _shm_exists(name), "and the object is unlinked")
        eq(t.stats["media"]["s"], 0, "a query is not a transmission, so the medium is not counted")
    finally:
        _remove_spec_file("shm", name)
        _SPEC_CREATED.discard(("shm", name))


@case("media", "temp_ok")
def _media_temp_ok():
    from vkitty.vt import Terminal
    tmp = _spec_tempdir()
    path = os.path.join(tmp, "tty-graphics-protocol-x.rgba")
    try:
        _spec_path(tmp, "tty-graphics-protocol-x.rgba", bytes(range(64)))
        t = Terminal(10, 2, tmpdir=tmp)
        t.feed(_apc(b"a=t,t=t,f=32,s=4,v=4,i=21;" + _b64(path)))
        eq(t.responses, [_ok(21)], "the temporary file is read")
        eq(t._kitty(t.active).images[21].data, bytes(range(64)), "its bytes are the image")
        check(not os.path.exists(path), "the temporary file is removed after it is read")
        eq(t.stats["media"]["t"], 1, "the temporary medium is counted")
    finally:
        _remove_spec_file("path", path)
        _drop_spec_dir(tmp)
        _SPEC_CREATED.discard(("path", path))


@case("media", "temp_rules")
def _media_temp_rules():
    from vkitty.media import DirectMedia
    tmp = _spec_tempdir()
    try:
        m = DirectMedia(tmpdir=tmp, fixed_roots=("/vkroot",))
        check(m.in_temp_dir("/vkroot/x"), "a path under a fixed root")
        check(m.in_temp_dir("/vkrootx/y"), "a fixed root is a plain string prefix, as in Ghostty")
        check(m.in_temp_dir(tmp + "/x"), "a path under the temporary directory")
        check(m.in_temp_dir(os.path.realpath(tmp) + "/x"), "and under its realpath")
        check(not m.in_temp_dir("/elsewhere/x"), "any other path is not")
        # allocTmpDir reads TMPDIR first and TMP second: with both set, only TMPDIR counts
        first = os.path.join(tmp, "first")
        second = os.path.join(tmp, "second")
        os.makedirs(first)
        os.makedirs(second)
        saved = dict((k, os.environ.get(k)) for k in ("TMPDIR", "TMP"))
        try:
            os.environ["TMPDIR"], os.environ["TMP"] = first, second
            env_media = DirectMedia(fixed_roots=())
            eq(env_media._temp_dir(), first, "TMPDIR comes before TMP")
            check(env_media.in_temp_dir(first + "/x"), "a path under TMPDIR")
            check(not env_media.in_temp_dir(second + "/x"), "and not one under TMP")
            del os.environ["TMPDIR"]
            eq(env_media._temp_dir(), second, "TMP is used when TMPDIR is not set")
        finally:
            for key, value in saved.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value
    finally:
        _drop_spec_dir(tmp)


@case("media", "temp_missing_dir")
def _media_temp_missing_dir():
    # Ghostty's isPathInTempDir takes posix.realpath of the temp dir, which fails for a directory
    # that does not exist, so the check is false. A non-strict realpath would give the parent's
    # realpath plus "missing", and "missingx/y" starts with that as a plain string prefix.
    from vkitty.media import DirectMedia
    base = _spec_tempdir()
    try:
        real = os.path.join(base, "real")
        os.makedirs(real)
        os.symlink(real, os.path.join(base, "link"))
        m = DirectMedia(tmpdir=os.path.join(base, "link", "missing"), fixed_roots=())
        check(not m.in_temp_dir(os.path.realpath(real) + "/missingx/y"),
              "a temp dir that does not exist has no realpath, so the check is false")
        os.makedirs(os.path.join(real, "missing"))
        check(m.in_temp_dir(os.path.realpath(real) + "/missing/x"),
              "once the directory exists its realpath counts")
    finally:
        _drop_spec_dir(base)


@case("media", "temp_refused")
def _media_temp_refused():
    from vkitty.media import DirectMedia
    from vkitty.vt import Terminal
    base = _spec_tempdir()
    try:
        in_dir = os.path.join(base, "in")
        out_dir = os.path.join(base, "out")
        os.makedirs(in_dir)
        os.makedirs(out_dir)
        out_file = _spec_path(out_dir, "tty-graphics-protocol-1.rgba", bytes(64))
        in_file = _spec_path(in_dir, "plain.rgba", bytes(64))
        t = Terminal(10, 2, media=DirectMedia(tmpdir=in_dir, fixed_roots=()))
        t.feed(_apc(b"a=t,t=t,f=32,s=4,v=4,i=1;" + _b64(out_file)))
        eq(t.responses[-1], _err(1, "EINVAL: temporary file not in temp dir"),
           "outside the temp dir")
        t.feed(_apc(b"a=t,t=t,f=32,s=4,v=4,i=2;" + _b64(in_file)))
        eq(t.responses[-1], _err(2, "EINVAL: temporary file not named correctly"), "a wrong name")
        check(os.path.exists(out_file) and os.path.exists(in_file), "both refused files remain")
    finally:
        _drop_spec_dir(base)


@case("media", "shm_ok_and_small")
def _media_shm_ok_and_small():
    import _posixshmem
    from vkitty.vt import Terminal
    pid = os.getpid()
    name_ok = "/vk%d_1" % pid
    name_small = "/vk%d_2" % pid
    name_missing = "/vk%d_3" % pid
    _SPEC_CREATED.add(("shm", name_ok))
    try:
        _shm_make(name_ok, bytes(range(64)), 64)
        _shm_make(name_small, bytes(64), 64)
        t = Terminal(10, 2)
        t.feed(_apc(b"a=t,t=s,f=32,s=4,v=4,i=31;" + _b64(name_ok)))
        eq(t.responses[-1], _ok(31), "a 4 x 4 RGBA shared memory object is read")
        eq(t._kitty(t.active).images[31].data, bytes(range(64)), "its bytes are the image")
        check(not _shm_exists(name_ok), "and the object is unlinked after the read")
        t.feed(_apc(b"a=t,t=s,f=32,s=100,v=100,i=32;" + _b64(name_small)))
        eq(t.responses[-1], _err(32, "EINVAL: invalid data"),
           "64 bytes declared as 100 x 100 is too small")
        check(not _shm_exists(name_small), "and that object is unlinked too")
        t.feed(_apc(b"a=t,t=s,f=32,s=4,v=4,i=33;" + _b64(name_missing)))
        eq(t.responses[-1], _err(33, "EINVAL: invalid data"), "a missing name is invalid data")
    finally:
        for name in (name_ok, name_small, name_missing):
            _remove_spec_file("shm", name)
            _SPEC_CREATED.discard(("shm", name))


@case("media", "empty_name")
def _media_empty_name():
    # an empty name is invalid data before any path check: Python's realpath("", strict=True) is
    # the working directory, while libc's realpath("") fails with ENOENT, which Ghostty calls
    from vkitty.media import DirectMedia, MediaError
    from vkitty.vt import Terminal
    tmp = _spec_tempdir()
    try:
        m = DirectMedia(tmpdir=tmp)
        for medium in ("t", "f"):
            err = _raises(MediaError, m.load, medium, b"", 0, 0, "rgba", 1, 1)
            eq(err.message, "EINVAL: invalid data", "t=%s with an empty name" % medium)
        t = Terminal(10, 2, tmpdir=tmp)
        t.feed(_apc(b"a=t,t=t,f=32,s=1,v=1,i=5;"))
        eq(t.responses, [_err(5, "EINVAL: invalid data")],
           "the command is answered as invalid data")
    finally:
        _drop_spec_dir(tmp)


@case("media", "refused_dev")
def _media_refused_dev():
    # a path under /dev (but not /dev/shm) and under /proc or /sys is refused as invalid data
    # before the temporary file check, so the file is not removed. /proc and /sys exist on Linux
    # only; on macOS those paths do not resolve, which is invalid data as well, so the direct
    # calls at the end are what tells the refusals apart there.
    from vkitty.media import DirectMedia, MediaError
    from vkitty.vt import Terminal
    tmp = _spec_tempdir()
    try:
        t = Terminal(10, 2, tmpdir=tmp)
        t.feed(_apc(b"a=t,t=t,f=32,s=1,v=1,i=6;" + _b64("/dev/null")))
        eq(t.responses[-1], _err(6, "EINVAL: invalid data"), "/dev/null is refused")
        t.feed(_apc(b"a=t,t=t,f=32,s=1,v=1,i=7;" + _b64("/proc/self/status")))
        eq(t.responses[-1], _err(7, "EINVAL: invalid data"), "/proc is refused")
        t.feed(_apc(b"a=t,t=f,f=32,s=1,v=1,i=8;" + _b64("/dev/null")))
        eq(t.responses[-1], _err(8, "EINVAL: invalid data"), "/dev/null is not a regular file")
        check(os.path.exists("/dev/null"), "and /dev/null is not removed")
        # the refusal comes before any check of the path, so it holds where the path does not exist
        m = DirectMedia(tmpdir=tmp)
        for path in ("/proc/vk-spec-missing", "/sys/vk-spec-missing", "/dev/vk-spec-missing"):
            err = _raises(MediaError, m._read_file, "t", path, 0)
            eq(err.message, "EINVAL: invalid data",
               "%s is refused before the temporary file checks" % path)
        # /dev/shm is the one place under /dev that is not refused: the temporary file checks run
        # (it is a fixed root of the temp dir check, and the name is wrong)
        err = _raises(MediaError, m._read_file, "t", "/dev/shm/vk-spec-missing", 0)
        eq(err.message, "EINVAL: temporary file not named correctly",
           "/dev/shm/ goes through the temporary file checks")
    finally:
        _drop_spec_dir(tmp)


@case("media", "shm_slice")
def _media_shm_slice():
    # readSharedMemory maps the object and takes [O, O + S), capped at the expected size (w * h
    # times the bytes per pixel), or the expected size when S is 0 (graphics_image.zig)
    from vkitty.media import DirectMedia
    name = "/vk%d_5" % os.getpid()
    _SPEC_CREATED.add(("shm", name))
    try:
        _shm_make(name, bytes(range(256)), 256)
        m = DirectMedia(unlink=False)
        raw = name.encode("ascii")
        eq(m.load("s", raw, 4, 16, "rgba", 4, 4), bytes(range(4, 20)), "O=4 S=16 is bytes 4 to 19")
        eq(m.load("s", raw, 0, 100, "rgba", 4, 4), bytes(range(64)),
           "S=100 is capped at the 64 bytes of a 4 x 4 RGBA image")
        eq(m.load("s", raw, 60, 0, "rgba", 4, 4), bytes(range(60, 64)),
           "O=60 with S=0 runs to the expected size")
        eq(m.load("s", raw, 0, 0, "rgba", 4, 4), bytes(range(64)),
           "S=0 and O=0 is the whole image")
    finally:
        _remove_spec_file("shm", name)
        _SPEC_CREATED.discard(("shm", name))


@case("media", "shm_nul")
def _media_shm_nul():
    # a NUL byte in a shared memory name is invalid data; it must not reach shm_open, which would
    # raise ValueError (not an OSError) and stop the terminal
    from vkitty.media import DirectMedia, MediaError
    from vkitty.vt import Terminal
    err = _raises(MediaError, DirectMedia().load, "s", b"/vk1\x00x", 0, 0, "rgba", 1, 1)
    eq(err.message, "EINVAL: invalid data", "a NUL in the name")
    # a name over the 31 bytes macOS allows makes shm_open fail with an error other than "not
    # found" (Linux has no such limit, and answers not found): invalid data, and nothing is raised
    err = _raises(MediaError, DirectMedia().load, "s", b"/" + b"x" * 40, 0, 0, "rgba", 1, 1)
    eq(err.message, "EINVAL: invalid data", "a name of 41 bytes")
    t = Terminal(10, 2)
    t.feed(_apc(b"a=t,t=s,f=32,s=1,v=1,i=9;" + _b64(b"/vk1\x00x")))
    eq(t.responses, [_err(9, "EINVAL: invalid data")], "answered as invalid data")


@case("media", "shm_png")
def _media_shm_png():
    # a PNG in shared memory: the expected size is the stat size (the file size), not
    # width * height * bytes per pixel, so the object is read whole and decoded
    from vkitty.vt import Terminal
    name = "/vk%d_6" % os.getpid()
    _SPEC_CREATED.add(("shm", name))
    try:
        png = _pil_png("RGBA", (2, 1), [(9, 8, 7, 255), (6, 5, 4, 255)])
        _shm_make(name, png, len(png))
        t = Terminal(10, 2)
        t.feed(_apc(b"a=t,t=s,f=100,i=36;" + _b64(name)))
        eq(t.responses, [_ok(36)], "a PNG in shared memory is stored")
        image = t._kitty(t.active).images[36]
        eq((image.width, image.height), (2, 1), "with the size of the PNG")
        check(not _shm_exists(name), "and the object is unlinked")
        eq(t.stats["media"]["s"], 1, "the shared memory medium is counted")
    finally:
        _remove_spec_file("shm", name)
        _SPEC_CREATED.discard(("shm", name))


@case("media", "non_regular_file")
def _media_non_regular_file():
    # readFile requires a regular file: a FIFO (or any other special file) is invalid data at once.
    # The open is non-blocking, so a FIFO with no writer is refused, not waited for.
    from vkitty.vt import Terminal
    tmp = _spec_tempdir()
    try:
        fifo = os.path.join(tmp, "pipe")
        _SPEC_CREATED.add(("path", fifo))
        os.mkfifo(fifo)
        t = Terminal(10, 2, tmpdir=tmp)
        t.feed(_apc(b"a=q,t=f,f=32,s=1,v=1,i=35;" + _b64(fifo)))
        eq(t.responses, [_err(35, "EINVAL: invalid data")], "a query of a FIFO")
        t.feed(_apc(b"a=t,t=f,f=32,s=1,v=1,i=36;" + _b64(fifo)))
        eq(t.responses[-1], _err(36, "EINVAL: invalid data"), "and a transmission of it")
        check(os.path.exists(fifo), "the FIFO is not removed")
    finally:
        _drop_spec_dir(tmp)
        _SPEC_CREATED.discard(("path", os.path.join(tmp, "pipe")))


_SIGNAL_CHILD = r"""
import importlib.util, os, sys, time
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("vkitty_spec_child", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
tmp = mod._spec_tempdir()
mod._spec_path(tmp, "left.bin", b"x")
name = "/vk%d_c" % os.getpid()
mod._shm_make(name, b"x", 64)
mod._install_cleanup_signals()
print(tmp, name, flush=True)
os.kill(os.getpid(), int(sys.argv[2]))
time.sleep(10)
sys.exit(3)
"""


@case("media", "signal_cleanup")
def _media_signal_cleanup():
    # SIGTERM and SIGINT remove everything the spec registered, folders included. A child process
    # makes a folder with a file in it and a shared memory object, then gets the signal.
    import signal
    import subprocess
    for sig in (signal.SIGTERM, signal.SIGINT):
        child = [sys.executable, "-I", "-B", "-c", _SIGNAL_CHILD, os.path.abspath(__file__),
                 str(int(sig))]
        proc = subprocess.run(child, capture_output=True, text=True, timeout=60)
        tmp, name = proc.stdout.split()[:2]
        try:
            eq(proc.returncode, 128 + int(sig), "%s exits with 128 + its number" % sig.name)
            check(not os.path.exists(tmp), "%s: the folder %s is removed" % (sig.name, tmp))
            check(not _shm_exists(name), "%s: the shared memory object is removed" % sig.name)
        finally:
            _remove_spec_file("dir", tmp)
            _remove_spec_file("shm", name)


@case("media", "recorded")
def _media_recorded():
    from vkitty.media import DirectMedia, MediaError, RecordedMedia
    from vkitty.vt import Terminal

    class _Recording:
        """Wraps DirectMedia and keeps every result by its key, as the relay's blob index does."""
        def __init__(self, inner):
            self.inner = inner
            self.index = {}

        def load(self, medium, name, offset, size, fmt, width, height, key=None):
            try:
                data = self.inner.load(medium, name, offset, size, fmt, width, height, key)
            except MediaError as exc:
                self.index[key] = (None, exc.message)
                raise
            self.index[key] = (data, None)
            return data

    tmp = _spec_tempdir()
    try:
        path = _spec_path(tmp, "tty-graphics-protocol-r.rgba", bytes(range(16)))
        stream = (_apc(b"a=t,t=t,f=32,s=2,v=2,i=41;" + _b64(path))
                  + _apc(b"a=t,t=t,f=32,s=2,v=2,i=42;" + _b64(path))
                  + _apc(b"a=t,t=f,f=32,s=2,v=2,i=43;" + _b64(os.path.join(tmp, "missing.bin"))))
        rec = _Recording(DirectMedia(tmpdir=tmp))
        first = Terminal(10, 2, media=rec)
        first.feed(stream)
        # the temporary file is gone now (the first run removed it): replay from the recording
        replay = Terminal(10, 2, media=RecordedMedia(rec.index))
        replay.feed(stream)
        eq(replay.responses, first.responses, "the replay answers as the live run did")
        eq(replay.responses[-1], _err(43, "EINVAL: invalid data"),
           "a missing file is recorded as its error")
        eq(_kimgs_list(replay), _kimgs_list(first), "the same images")
        eq(replay._kitty(replay.active).images[41].data, bytes(range(16)), "the replayed bytes")
        m = RecordedMedia({})
        _raises(MediaError, m.load, "t", b"x", 0, 0, "rgba", 1, 1, ("tui", 0, 0))
        check(any("no blob for key" in w for w in m.warnings), "a missing key is warned about")
    finally:
        _drop_spec_dir(tmp)


def _kimgs_list(term):
    return sorted((k, v.data) for k, v in term._kitty(term.active).images.items())


@case("media", "spec_leaves_nothing")
def _media_spec_leaves_nothing():
    # every object the media cases made is gone (their finally blocks removed what the library
    # left behind); this checks the registry the spec keeps
    leftover = []
    for kind, name in sorted(_SPEC_CREATED):
        exists = _shm_exists(name) if kind == "shm" else os.path.exists(name)
        if exists:
            leftover.append(name)
    check(not leftover, "left behind: %s" % leftover)


# ------------------------------------------------------------ place and anim ---
# Placements after a text stream: Unicode placeholders (virtual placements, vkitty.unicode_place)
# and pins (placements at a cell that scroll with their content, vkitty.kgp), drawn as
# vkitty.snapshot draws them, and the kitty profile's animation layer (vkitty.anim). The expected
# values come from the sources named in each docstring: Ghostty 1.3.1 (graphics_unicode.zig,
# renderer/image.zig, graphics_storage.zig, PageList.zig, Screen.zig, Terminal.zig) and kitty's
# graphics.c and simd-string.h (commit 81535d9). The oracles below follow those sources, not the
# port.

_PLACEHOLDER = "\U0010EEEE"
_DIA = ("\u0305", "\u030d", "\u030e", "\u0310", "\u0312")   # DIACRITICS[0:5] (graphics_unicode.zig)


def _ph(row, col, high=None):
    """One placeholder cell: U+10EEEE, its row and column diacritics, and the high byte one."""
    text = _PLACEHOLDER + _DIA[row] + _DIA[col]
    if high is not None:
        text += _DIA[high]
    return text


def _grid_text(row, cols, abbreviated=False):
    """The placeholders of image row `row`, one per column. abbreviated gives the diacritics to the
    first cell of the row only (the rest continue it)."""
    out = []
    for c in range(cols):
        if abbreviated and c > 0:
            out.append(_PLACEHOLDER)
        else:
            out.append(_ph(row, c))
    return "".join(out)


def _at(x, y, text):
    """Bytes that write text at cell (x, y), 0-based (CUP first; the text takes the pen's
    colour)."""
    return ("\x1b[%d;%dH" % (y + 1, x + 1) + text).encode("utf-8")


def _fg_rgb(image_id):
    """The 24-bit foreground that names an image id in a placeholder (graphics_unicode.zig)."""
    return "\x1b[38;2;%d;%d;%dm" % ((image_id >> 16) & 255, (image_id >> 8) & 255, image_id & 255)


def _rgba_img(image_id, width, height, pixels=None, fmt=32):
    """An a=t transmission of an image (zero pixels unless given)."""
    if pixels is None:
        pixels = bytes(width * height * (4 if fmt == 32 else 3))
    return _apc(b"a=t,f=%d,s=%d,v=%d,i=%d;" % (fmt, width, height, image_id) + _b64(pixels))


def _draw_tuple(d):
    """A draw as a comparable tuple: image, kind, z, col, row, offsets, src and dest."""
    return (d.image_id, d.kind, d.z, d.col, d.row, d.offset_x, d.offset_y,
            tuple(d.src), tuple(d.dest))


def _draws(snap):
    return [_draw_tuple(d) for d in snap.draws]


def _draws_sorted(snap):
    """The draws in row-major order, for cases where two pins share a z and an image."""
    return sorted(_draws(snap), key=lambda d: (d[4], d[3]))


def _virtual_term(width, height, cols, rows, placeholders, image_id=5, x=5, y=3, placement=b""):
    """A 20 x 6 terminal with an image placed virtually (cols x rows cells, placement id from
    `placement`) and placeholder text: placeholders is a list of (row offset, text) written at
    (x, y + offset) in the image's colour."""
    t = _kterm(20, 6)
    t.feed(_rgba_img(image_id, width, height))
    t.feed(_apc(b"a=p,i=%d,U=1,c=%d,r=%d%s" % (image_id, cols, rows, placement)))
    colour = _fg_rgb(image_id)
    for dy, text in placeholders:
        t.feed(_at(x, y + dy, colour + text))
    return t


_IDENTITY_DRAWS = [
    (5, "virtual", -1, 5, 3, 0, 0, (0, 0, 26, 33), (26, 33)),
    (5, "virtual", -1, 5, 4, 0, 0, (0, 33, 26, 33), (26, 33)),
]
_LETTERBOX_WIDE = [
    (5, "virtual", -1, 5, 3, 0, 22, (0, 0, 26, 11), (26, 11)),
    (5, "virtual", -1, 5, 4, 0, 0, (0, 11, 26, 11), (26, 11)),
]


@case("place", "diacritics_match_lua")
def _place_diacritics_match_lua():
    # lua/jupynvim/notebook/image.lua carries the same row and column diacritics as Ghostty's
    # graphics_unicode.zig (the kitty protocol's list of 297): the port and the Lua table must agree
    import re
    from vkitty.unicode_place import DIACRITICS
    eq(len(DIACRITICS), 297, "the port's table length")
    eq((DIACRITICS[0], DIACRITICS[-1]), (0x0305, 0x1D244), "first and last entries")
    path = os.path.join(HERE, os.pardir, "lua", "jupynvim", "notebook", "image.lua")
    with open(path, "r", encoding="utf-8") as fh:
        text = fh.read()
    start = text.index("local DIACRITICS = {")
    body = text[start:text.index("\n}", start)]
    lua = [int(h, 16) for h in re.findall(r"0x([0-9A-Fa-f]+)", body)]
    missing = ["0x%04X" % c for c in DIACRITICS if c not in lua]
    check(lua == list(DIACRITICS), "image.lua lists %d diacritics, the list has %d; missing %s"
          % (len(lua), len(DIACRITICS), ", ".join(missing) or "none"))


@case("place", "identity")
def _place_identity():
    # renderer/image.zig prepKittyVirtualPlacement: a 26 x 66 image in 2 x 2 cells of 13 x 33 px is
    # exactly the grid, so each row draws its half at 1:1 (renderPlacement, the source and dest)
    t = _virtual_term(26, 66, 2, 2, [(0, _grid_text(0, 2)), (1, _grid_text(1, 2))])
    eq(_draws(t.snapshot()), _IDENTITY_DRAWS, "the two rows of the image")


@case("place", "abbreviated")
def _place_abbreviated():
    # only the first cell of each row carries diacritics: the rest continue the row (the placement
    # iterator's canAppend), and the draws are the same as in place/identity
    t = _virtual_term(26, 66, 2, 2, [(0, _grid_text(0, 2, True)), (1, _grid_text(1, 2, True))])
    eq(_draws(t.snapshot()), _IDENTITY_DRAWS, "the two rows of the image, abbreviated")


@case("place", "high_byte_and_palette")
def _place_high_byte_and_palette():
    # the image id is the fg's 24 bits, plus the high byte from the third diacritic (index 3,
    # U+0310); fg 38;5;42 names image 42 (graphics_unicode.zig IncompletePlacement.init and
    # colorToId)
    big = (3 << 24) | 0x123456
    t = _kterm(20, 6)
    t.feed(_rgba_img(big, 13, 33))
    t.feed(_apc(b"a=p,i=%d,U=1,c=1,r=1" % big))
    t.feed(_at(0, 0, _fg_rgb(0x123456) + _ph(0, 0, high=3)))
    t.feed(_rgba_img(42, 13, 33))
    t.feed(_apc(b"a=p,i=42,U=1,c=1,r=1"))
    t.feed(_at(0, 2, "\x1b[38;5;42m" + _ph(0, 0)))
    eq(_draws(t.snapshot()), [
        (42, "virtual", -1, 0, 2, 0, 0, (0, 0, 13, 33), (13, 33)),
        (big, "virtual", -1, 0, 0, 0, 0, (0, 0, 13, 33), (13, 33)),
    ], "draws, sorted by image id")


@case("place", "placement_id")
def _place_placement_id():
    # the underline colour 58;2;0;0;7 names placement 7: without it the run is missing (placement
    # missing), and with a virtual placement 7 it draws, and the draw carries the id
    t = _virtual_term(13, 33, 1, 1, [(0, _ph(0, 0))], x=0, y=0)
    t.feed(_at(0, 0, _fg_rgb(5) + "\x1b[58;2;0;0;7m" + _ph(0, 0)))
    snap = t.snapshot()
    eq(_draws(snap), [], "no draw without placement 7")
    eq([(m["image_id"], m["placement_id"], m["reason"]) for m in snap.missing],
       [(5, 7, "placement missing")], "the run is missing")
    t.feed(_apc(b"a=p,i=5,p=7,U=1,c=1,r=1"))
    snap = t.snapshot()
    eq(_draws(snap), [(5, "virtual", -1, 0, 0, 0, 0, (0, 0, 13, 33), (13, 33))],
       "placement 7 draws")
    eq(snap.draws[0].placement_id, 7, "the draw names placement 7")


@case("place", "letterbox_wide")
def _place_letterbox_wide():
    # a 26 x 22 image in 26 x 66 px: fitted to the width and centred vertically (the offset 22 on
    # row 0, and the source cut by the bar on each row), renderPlacement's y offset branches
    t = _virtual_term(26, 22, 2, 2, [(0, _grid_text(0, 2)), (1, _grid_text(1, 2))])
    eq(_draws(t.snapshot()), _LETTERBOX_WIDE, "row 0 and row 1 of the letterboxed image")


@case("place", "letterbox_tall")
def _place_letterbox_tall():
    # a 6 x 66 image in 26 x 66 px: fitted to the height and centred horizontally (offset_x 10,
    # width 6 on both rows)
    t = _virtual_term(6, 66, 2, 2, [(0, _grid_text(0, 2)), (1, _grid_text(1, 2))])
    eq(_draws(t.snapshot()), [
        (5, "virtual", -1, 5, 3, 10, 0, (0, 0, 6, 33), (6, 33)),
        (5, "virtual", -1, 5, 4, 10, 0, (0, 33, 6, 33), (6, 33)),
    ], "both rows, centred")


@case("place", "partial_view")
def _place_partial_view():
    # only the row 1 placeholders are on screen: their run draws exactly the row 1 draw of the
    # letterboxed image (the row diacritic says which part of the image the run shows)
    t = _virtual_term(26, 22, 2, 2, [(1, _grid_text(1, 2))])
    eq(_draws(t.snapshot()), [_LETTERBOX_WIDE[1]], "row 1 alone")


@case("place", "missing_image")
def _place_missing_image():
    # placeholders naming an image that is not stored: no draw, and a missing entry with the reason
    t = _virtual_term(13, 33, 1, 1, [(0, _ph(0, 0))], x=0, y=0)
    t.feed(_at(0, 1, _fg_rgb(77) + _ph(0, 0)))
    snap = t.snapshot()
    eq(_draws(snap), [(5, "virtual", -1, 0, 0, 0, 0, (0, 0, 13, 33), (13, 33))],
       "image 5 still draws")
    eq([(m["x"], m["y"], m["w"], m["image_id"], m["reason"]) for m in snap.missing],
       [(0, 1, 1, 77, "image not found")], "image 77 is missing")


@case("place", "pins")
def _place_pins():
    # a=p at the cursor: C=1 keeps the cursor, C=0 moves it past the image (Terminal.zig, the
    # cursor after a display); the source rectangle, the X and Y offsets, c only, r only and c with
    # r (graphics_storage.zig calculatedSize: the cell is 13 x 33 px)
    t = _kterm(20, 10)
    t.feed(_rgba_img(5, 13, 33))
    t.feed(b"\x1b[2;3H" + _apc(b"a=p,i=5,C=1"))
    eq(t.snapshot().cursor[:2], (2, 1), "C=1 keeps the cursor")
    t.feed(b"\x1b[4;1H" + _apc(b"a=p,i=5"))
    eq(t.snapshot().cursor[:2], (1, 3), "C=0 leaves the cursor past the image")
    t.feed(b"\x1b[6;5H" + _apc(b"a=p,i=5,x=2,y=3,w=5,h=6,C=1"))
    t.feed(b"\x1b[6;9H" + _apc(b"a=p,i=5,X=2,Y=3,C=1"))
    t.feed(b"\x1b[8;1H" + _apc(b"a=p,i=5,c=2,C=1"))
    t.feed(b"\x1b[8;6H" + _apc(b"a=p,i=5,r=1,C=1"))
    t.feed(b"\x1b[8;10H" + _apc(b"a=p,i=5,c=3,r=1,C=1"))
    eq(_draws_sorted(t.snapshot()), [
        (5, "pin", 0, 2, 1, 0, 0, (0, 0, 13, 33), (13, 33)),
        (5, "pin", 0, 0, 3, 0, 0, (0, 0, 13, 33), (13, 33)),
        (5, "pin", 0, 4, 5, 0, 0, (2, 3, 5, 6), (5, 6)),
        (5, "pin", 0, 8, 5, 2, 3, (0, 0, 13, 33), (13, 33)),
        (5, "pin", 0, 0, 7, 0, 0, (0, 0, 13, 33), (26, 66)),
        (5, "pin", 0, 5, 7, 0, 0, (0, 0, 13, 33), (13, 33)),
        (5, "pin", 0, 9, 7, 0, 0, (0, 0, 13, 33), (39, 33)),
    ], "the seven pins")
    # a pin on the bottom row moves up one row with the LF that scrolls it (cursorDownScroll)
    t = _kterm(20, 3)
    t.feed(_rgba_img(5, 13, 33))
    t.feed(b"\x1b[3;1H" + _apc(b"a=p,i=5,C=1"))
    eq(_draws(t.snapshot()), [(5, "pin", 0, 0, 2, 0, 0, (0, 0, 13, 33), (13, 33))], "on row 2")
    t.feed(b"\n")
    eq(_draws(t.snapshot()), [(5, "pin", 0, 0, 1, 0, 0, (0, 0, 13, 33), (13, 33))],
       "after the LF, on row 1")


@case("place", "pin_history_partial")
def _place_pin_history_partial():
    # Screen.cursorScrollAbove grows the active area and a pin keeps its page row, so the pin moves
    # into history and still draws its visible part at a negative row (renderer/image.zig)
    t = _kterm(10, 4)
    t.feed(_rgba_img(5, 13, 99))
    t.feed(b"\x1b[1;1H" + _apc(b"a=p,i=5,C=1"))
    t.feed(b"\x1b[4;1H\n")
    eq(_draws(t.snapshot()), [(5, "pin", 0, 0, -1, 0, 0, (0, 0, 13, 99), (13, 99))],
       "one LF: the pin is at row -1 and draws in full")
    t.feed(b"\n\n")
    eq(_draws(t.snapshot()), [], "two LFs more: its bottom row is above the viewport")


@case("place", "pin_alt_scroll")
def _place_pin_alt_scroll():
    # the alternate screen has no history, so its full-screen scroll is eraseRow: the pins below the
    # erased top row move up one row, and a pin on the top row stays where it is
    t = _kterm(10, 4)
    t.feed(b"\x1b[?1049h")
    t.feed(_rgba_img(5, 13, 33) + _rgba_img(6, 13, 33))
    t.feed(b"\x1b[1;1H" + _apc(b"a=p,i=5,C=1"))
    t.feed(b"\x1b[3;1H" + _apc(b"a=p,i=6,C=1"))
    t.feed(b"\x1b[4;1H\n")
    eq(_draws(t.snapshot()), [
        (5, "pin", 0, 0, 0, 0, 0, (0, 0, 13, 33), (13, 33)),
        (6, "pin", 0, 0, 1, 0, 0, (0, 0, 13, 33), (13, 33)),
    ], "the top pin stays on row 0, the one below moves to row 1")


@case("place", "pin_region_index")
def _place_pin_region_index():
    # index at the bottom margin of a region that starts below row 0 with the default background
    # is eraseRowBounded: the pins in the region move up one row, so the top row's pin lands above
    # the region and the pin below it stays
    t = _kterm(10, 6)
    t.feed(b"\x1b[2;4r")
    for image_id, row in ((5, 1), (6, 2), (7, 5)):
        t.feed(_rgba_img(image_id, 13, 33))
        t.feed(b"\x1b[%d;1H" % (row + 1) + _apc(b"a=p,i=%d,C=1" % image_id))
    t.feed(b"\x1b[4;1H\n")
    eq(_draws(t.snapshot()), [
        (5, "pin", 0, 0, 0, 0, 0, (0, 0, 13, 33), (13, 33)),
        (6, "pin", 0, 0, 1, 0, 0, (0, 0, 13, 33), (13, 33)),
        (7, "pin", 0, 0, 5, 0, 0, (0, 0, 13, 33), (13, 33)),
    ], "rows 0, 1 and 5")


@case("place", "pin_swaps_stay")
def _place_pin_swaps_stay():
    # insertLines, deleteLines, scroll down and index with a background swap row structs and never
    # touch the pins (Terminal.insertLines, deleteLines, _move_region): every draw keeps its row
    t = _kterm(10, 6)
    t.feed(_rgba_img(5, 13, 33) + _rgba_img(6, 13, 33))
    t.feed(b"\x1b[2;1H" + _apc(b"a=p,i=5,C=1"))
    t.feed(b"\x1b[4;1H" + _apc(b"a=p,i=6,C=1"))
    want = [
        (5, "pin", 0, 0, 1, 0, 0, (0, 0, 13, 33), (13, 33)),
        (6, "pin", 0, 0, 3, 0, 0, (0, 0, 13, 33), (13, 33)),
    ]
    t.feed(b"\x1b[2;1H\x1b[L")
    eq(_draws(t.snapshot()), want, "after IL")
    t.feed(b"\x1b[M")
    eq(_draws(t.snapshot()), want, "after DL")
    t.feed(b"\x1b[T")
    eq(_draws(t.snapshot()), want, "after SD")
    t.feed(b"\x1b[41m\x1b[2;5r\x1b[5;1H\n")
    eq(_draws(t.snapshot()), want, "after an index with a background at the bottom margin")


@case("place", "pin_partial_top_region")
def _place_pin_partial_top_region():
    # index at the bottom of a region that starts at row 0 grows the active area
    # (cursorScrollAbove): every pin moves up one row, a pin in the region can go into history, and
    # the text on row 4, below the region, stays on row 4
    t = _kterm(10, 5)
    t.feed(b"\x1b[1;3r")
    t.feed(_rgba_img(5, 13, 66) + _rgba_img(6, 13, 33) + _rgba_img(7, 13, 33))
    t.feed(b"\x1b[1;1H" + _apc(b"a=p,i=5,C=1"))
    t.feed(b"\x1b[2;1H" + _apc(b"a=p,i=6,C=1"))
    t.feed(b"\x1b[5;1H" + _apc(b"a=p,i=7,C=1"))
    t.feed(b"\x1b[5;6HR4")
    t.feed(b"\x1b[3;1H\n")
    snap = t.snapshot()
    eq(_draws(snap), [
        (5, "pin", 0, 0, -1, 0, 0, (0, 0, 13, 66), (13, 66)),
        (6, "pin", 0, 0, 0, 0, 0, (0, 0, 13, 33), (13, 33)),
        (7, "pin", 0, 0, 3, 0, 0, (0, 0, 13, 33), (13, 33)),
    ], "rows -1 (its second row shows), 0 and 3")
    eq(snap.row_text(4)[5:7], "R4", "row 4 keeps its text")


@case("place", "pin_ed3")
def _place_pin_ed3():
    # the pin goes into history with the LF; ED 3 erases the history and moves a history pin to row
    # 0, column 0 (PageList.eraseRows)
    t = _kterm(10, 3)
    t.feed(_rgba_img(5, 13, 33))
    t.feed(b"\x1b[1;5H" + _apc(b"a=p,i=5,C=1"))
    t.feed(b"\x1b[3;1H\n")
    eq(_draws(t.snapshot()), [], "in history: its bottom row is above the viewport")
    t.feed(b"\x1b[3J")
    eq(_draws(t.snapshot()), [(5, "pin", 0, 0, 0, 0, 0, (0, 0, 13, 33), (13, 33))],
       "after ED 3: row 0, column 0")


@case("place", "pin_narrow")
def _place_pin_narrow():
    # a narrower screen clamps a pin's column (PageList.resizeWithoutReflow, the alternate screen)
    t = _kterm(10, 3)
    t.feed(b"\x1b[?1049h")
    t.feed(_rgba_img(5, 13, 33))
    t.feed(b"\x1b[1;9H" + _apc(b"a=p,i=5,C=1"))
    t.resize(5, 3)
    eq(_draws(t.snapshot()), [(5, "pin", 0, 4, 0, 0, 0, (0, 0, 13, 33), (13, 33))],
       "column 8 becomes column 4")


@case("place", "pin_alt_resize_erases_history")
def _place_pin_alt_resize_erases_history():
    # the alternate screen's history erase runs after every resize, even a widening one
    # (Screen.resize: `if (self.no_scrollback) self.pages.eraseRows(.{ .history = .{} }, null)`,
    # unconditional): the pin that an index sent into history (cursorScrollAbove grows the active
    # area of a region that starts at row 0) moves to row 0, column 0 (PageList.eraseRows)
    t = _kterm(10, 4)
    t.feed(b"\x1b[?1049h")
    t.feed(b"\x1b[1;3r")
    t.feed(_rgba_img(5, 13, 33))
    t.feed(b"\x1b[1;5H" + _apc(b"a=p,i=5,C=1"))
    t.feed(b"\x1b[3;1H\n")
    eq(_draws(t.snapshot()), [],
       "one LF: the pin is in history and its only row is above the viewport")
    t.resize(12, 4)
    eq(_draws(t.snapshot()), [(5, "pin", 0, 0, 0, 0, 0, (0, 0, 13, 33), (13, 33))],
       "after the widening resize: one draw at row 0, column 0")


@case("place", "pin_delete_history")
def _place_pin_delete_history():
    # a pin in history has a rectangle over rows -1 to 1 at column 0 (Placement.rect): a row delete
    # for row 2 misses it, a column delete for column 1 takes it
    t = _kterm(10, 4)
    t.feed(_rgba_img(5, 13, 99))
    t.feed(b"\x1b[1;1H" + _apc(b"a=p,i=5,C=1"))
    t.feed(b"\x1b[4;1H\n")
    t.feed(_apc(b"a=d,d=y,y=3"))
    eq(len(t._kitty(t.active).placements), 1, "row 2 is not in its rectangle")
    t.feed(_apc(b"a=d,d=x,x=1"))
    eq(len(t._kitty(t.active).placements), 0, "column 1 is")


@case("place", "pin_blocks_trim")
def _place_pin_blocks_trim():
    # trimTrailingBlankRows stops at a row that holds a pin, so the rows that leave the
    # top are rows 0 and 1, the pin moves to row 2, and the cursor (on a row that left) goes home
    t = _kterm(10, 6)
    t.feed(b"top")
    t.feed(b"\x1b[5;1H" + _apc(b"a=T,f=32,s=13,v=33,i=3,C=1;" + _b64(bytes(13 * 33 * 4))))
    t.feed(b"\x1b[H")
    t.resize(10, 3)
    snap = t.snapshot()
    eq(_draws(snap), [(3, "pin", 0, 0, 2, 0, 0, (0, 0, 13, 33), (13, 33))], "the pin is on row 2")
    eq(snap.cursor[:2], (0, 0), "the cursor is at the top left")


@case("place", "z_order")
def _place_z_order():
    # renderer/image.zig: the draws are sorted by z, then by image id (zLessThan); virtual
    # placements draw at z -1 and a pin's z is its z key
    t = _kterm(20, 6)
    for image_id in (9, 3, 7, 4):
        t.feed(_rgba_img(image_id, 13, 33))
    t.feed(b"\x1b[1;1H" + _apc(b"a=p,i=9,C=1"))
    t.feed(b"\x1b[1;3H" + _apc(b"a=p,i=3,C=1"))
    t.feed(b"\x1b[1;5H" + _apc(b"a=p,i=7,C=1,z=-5"))
    t.feed(_apc(b"a=p,i=4,U=1,c=1,r=1"))
    t.feed(_at(0, 2, _fg_rgb(4) + _ph(0, 0)))
    eq(_draws(t.snapshot()), [
        (7, "pin", -5, 4, 0, 0, 0, (0, 0, 13, 33), (13, 33)),
        (4, "virtual", -1, 0, 2, 0, 0, (0, 0, 13, 33), (13, 33)),
        (3, "pin", 0, 2, 0, 0, 0, (0, 0, 13, 33), (13, 33)),
        (9, "pin", 0, 0, 0, 0, 0, (0, 0, 13, 33), (13, 33)),
    ], "z -5, then z -1, then z 0 by image id")


# ------------------------------------------------------------------- anim ---
# The kitty profile's animation layer (vkitty.anim): frames, their coalescing, the blends, a=f,
# a=a, a=c and d=f/F, after kitty 81535d9's graphics.c. Each oracle is written from kitty's source.


def _solid(width, height, pixel):
    """width x height copies of one pixel (bytes of 3 or 4)."""
    return bytes(pixel) * (width * height)


def _div255(x):
    """kitty simd-string.h div255_round."""
    y = x + 128
    return (y + (y >> 8)) >> 8


def _f32(x):
    """x rounded to a float32, as a Python float."""
    import struct
    return struct.unpack("f", struct.pack("f", float(x)))[0]


def _over_opaque(dst, src):
    """kitty blend_pixel_over_opaque: the three colour bytes of src (RGBA) over dst."""
    a = src[3]
    ia = 255 - a
    return [_div255(src[c] * a + dst[c] * ia) for c in range(3)]


def _over_straight(dst, src):
    """kitty blend_pixel_over_straight on RGBA: float32 division rounded to nearest even (lrintf),
    the alpha div255_round(denom), and dst unchanged when both alphas are 0."""
    alpha = src[3]
    da = dst[3]
    ia = 255 - alpha
    denom = alpha * 255 + da * ia
    if denom == 0:
        return list(dst)
    out = []
    for c in range(3):
        num = src[c] * alpha * 255 + dst[c] * da * ia
        out.append(int(round(_f32(_f32(num) / _f32(denom)))))
    out.append(_div255(denom))
    return out


def _grid_bytes(width, height, pixel):
    """RGBA bytes of a width x height image; pixel(x, y) gives a 4-tuple."""
    out = bytearray()
    for y in range(height):
        for x in range(width):
            out += bytes(pixel(x, y))
    return bytes(out)


def _kitty_term(cols=10, rows=4):
    return _kterm(cols, rows, profile="kitty")


def _shown(t, image_id, t_now=None):
    """The image as the snapshot shows it: (frame, seq, rgba)."""
    view = t.snapshot(t_now).images[image_id]
    return view.frame, view.seq, bytes(view.rgba)


def _resp(image_id, message):
    return ("\x1b_Gi=%d;%s\x1b\\" % (image_id, message)).encode("ascii")


@case("anim", "kitty_frames")
def _anim_kitty_frames():
    # the cycle: a root of gap 0 is skipped, a=a r=1 z=100 gives it a gap, and frames change at each
    # due time (graphics.c scan_active_animations), each change with a new seq (Image.version)
    red = _solid(4, 4, b"\xff\x00\x00\xff")
    green = _solid(4, 4, b"\x00\xff\x00\xff")
    t = _kitty_term()
    t.feed(_apc(b"a=t,f=32,s=4,v=4,i=5;" + _b64(red)))
    t.feed(_apc(b"a=f,i=5,s=4,v=4,f=32,z=100;" + _b64(green)), t=8.0)
    t.feed(_apc(b"a=a,i=5,r=1,z=100"), t=9.0)
    t.feed(_apc(b"a=p,i=5,U=1,c=1,r=1"), t=9.0)       # an image advances only while it is drawn
    t.feed(_apc(b"a=a,i=5,s=3,v=1"), t=10.0)
    f1, q1, p1 = _shown(t, 5, 10.05)
    f2, q2, p2 = _shown(t, 5, 10.15)
    f3, q3, p3 = _shown(t, 5, 10.25)
    eq((f1, f2, f3), (1, 2, 1), "frames at 10.05, 10.15 and 10.25")
    eq((p1[:4], p2[:4], p3[:4]), (red[:4], green[:4], red[:4]), "red, green, red")
    check(len({q1, q2, q3}) == 3, "a new seq with each frame change: %r" % ((q1, q2, q3),))
    # stopped on frame 2: a=a c=2 s=1 at 11.0 (the cycle runs up to 11.0 first)
    t.feed(_apc(b"a=a,i=5,c=2,s=1"), t=11.0)
    eq([_shown(t, 5, 11.5)[0], _shown(t, 5, 12.0)[0]], [2, 2], "stopped on frame 2")
    # without the root's gap the cycle never shows the root (kitty skips gapless frames)
    t = _kitty_term()
    t.feed(_apc(b"a=t,f=32,s=4,v=4,i=5;" + _b64(red)))
    t.feed(_apc(b"a=f,i=5,s=4,v=4,f=32,z=100;" + _b64(green)), t=8.0)
    t.feed(_apc(b"a=p,i=5,U=1,c=1,r=1"), t=9.0)
    t.feed(_apc(b"a=a,i=5,s=3,v=1"), t=10.0)
    shots = [_shown(t, 5, when) for when in (10.05, 10.15, 10.25, 10.45)]
    eq([shot[0] for shot in shots], [2, 2, 2, 2],
       "the root has gap 0, so the cycle stays on frame 2")
    eq(len({shot[1] for shot in shots[1:]}), 1, "a due frame that is already shown keeps its seq")


@case("anim", "delta_and_edit")
def _anim_delta_and_edit():
    # a delta frame coalesces over its base when it is shown (kitty get_coalesced_frame_data_impl):
    # the 2 x 2 rectangle is blended over the opaque root, and an edit of the root shows through
    # the delta later (coalescing is lazy), so a store of composed frames would fail the last check
    blue = _solid(4, 4, b"\x00\x00\xff")
    red80 = (255, 0, 0, 128)
    t = _kitty_term()
    t.feed(_apc(b"a=t,f=24,s=4,v=4,i=6;" + _b64(blue)))
    t.feed(_apc(b"a=f,i=6,c=1,x=1,y=1,s=2,v=2,f=32;" + _b64(_solid(2, 2, red80))))
    t.feed(_apc(b"a=a,i=6,c=2"))

    def inside(x, y):
        return 1 <= x <= 2 and 1 <= y <= 2

    def expect(patch, outside):
        return _grid_bytes(4, 4, lambda x, y: tuple(patch) + (255,) if inside(x, y)
                           else tuple(outside) + (255,))
    eq(_shown(t, 6)[2], expect(_over_opaque((0, 0, 255), red80), (0, 0, 255)),
       "the delta over the blue root")
    green3 = _solid(4, 4, b"\x00\xff\x00")
    t.feed(_apc(b"a=f,i=6,r=1,s=4,v=4,f=24;" + _b64(green3)))
    t.feed(_apc(b"a=a,i=6,c=1"))
    t.feed(_apc(b"a=a,i=6,c=2"))
    eq(_shown(t, 6)[2], expect(_over_opaque((0, 255, 0), red80), (0, 255, 0)),
       "after the root is edited to green, the delta shows over the green")


@case("anim", "blend_straight")
def _anim_blend_straight():
    # blend_over_straight on 1000 random RGBA pairs (alpha 0 over alpha 0 among them, which stays as
    # the destination): a delta over an RGBA root blends with the float32 formula; X=1 copies
    rnd = random.Random(7)
    dst = bytearray()
    src = bytearray()
    for i in range(1000):
        if i < 8:
            d_px = (rnd.randrange(256), rnd.randrange(256), rnd.randrange(256), 0)
            s_px = (rnd.randrange(256), rnd.randrange(256), rnd.randrange(256), 0)
        else:
            d_px = tuple(rnd.randrange(256) for _ in range(4))
            s_px = tuple(rnd.randrange(256) for _ in range(4))
        dst += bytes(d_px)
        src += bytes(s_px)
    dst_px = [tuple(dst[4 * i:4 * i + 4]) for i in range(1000)]
    src_px = [tuple(src[4 * i:4 * i + 4]) for i in range(1000)]
    t = _kitty_term()
    t.feed(_apc(b"a=t,f=32,s=1000,v=1,i=7;" + _b64(bytes(dst))))
    t.feed(_apc(b"a=f,i=7,c=1,s=1000,v=1,f=32;" + _b64(bytes(src))))
    t.feed(_apc(b"a=a,i=7,c=2"))
    want = b"".join(bytes(_over_straight(d, s)) for d, s in zip(dst_px, src_px))
    eq(_shown(t, 7)[2], want, "every pixel is the float32 oracle of the blend")
    t = _kitty_term()
    t.feed(_apc(b"a=t,f=32,s=1000,v=1,i=7;" + _b64(bytes(dst))))
    t.feed(_apc(b"a=f,i=7,c=1,X=1,s=1000,v=1,f=32;" + _b64(bytes(src))))
    t.feed(_apc(b"a=a,i=7,c=2"))
    eq(_shown(t, 7)[2], bytes(src), "X=1 copies the frame without blending")


@case("anim", "compose")
def _anim_compose():
    # a=c (graphics.c handle_compose_command): C=1 copies the root's lower right 2 x 2 onto frame
    # 2's upper left, without C it blends it over frame 2 (src is not opaque); kitty's answers for
    # an out of bounds rectangle, an overlap in one frame and a missing source frame
    rnd = random.Random(11)
    root = bytes(rnd.randrange(256) for _ in range(64))
    frame2 = bytes(rnd.randrange(256) for _ in range(64))

    def pixel(data, x, y):
        i = (y * 4 + x) * 4
        return tuple(data[i:i + 4])

    def setup():
        t = _kitty_term()
        t.feed(_apc(b"a=t,f=32,s=4,v=4,i=5;" + _b64(root)))
        t.feed(_apc(b"a=f,i=5,s=4,v=4,f=32;" + _b64(frame2)))
        return t
    t = setup()
    t.feed(_apc(b"a=c,i=5,r=1,c=2,x=0,y=0,X=2,Y=2,w=2,h=2,C=1"))
    t.feed(_apc(b"a=a,i=5,c=2"))
    want = _grid_bytes(4, 4, lambda x, y: pixel(root, x + 2, y + 2) if x < 2 and y < 2
                       else pixel(frame2, x, y))
    eq(_shown(t, 5)[2], want, "C=1 copies the lower right onto the upper left")
    t = setup()
    t.feed(_apc(b"a=c,i=5,r=1,c=2,x=0,y=0,X=2,Y=2,w=2,h=2"))
    t.feed(_apc(b"a=a,i=5,c=2"))
    want = _grid_bytes(4, 4, lambda x, y: tuple(_over_straight(pixel(frame2, x, y),
                                                             pixel(root, x + 2, y + 2)))
                       if x < 2 and y < 2 else pixel(frame2, x, y))
    eq(_shown(t, 5)[2], want, "without C the root's rectangle is blended over frame 2")
    t = setup()
    t.feed(_apc(b"a=c,i=5,r=1,c=2,x=3,y=0,X=0,Y=0,w=2,h=2,C=1"))
    eq(t.responses[-1], _resp(5, "EINVAL:The destination rectangle is out of bounds"),
       "a destination past the edge")
    t.feed(_apc(b"a=c,i=5,r=2,c=2,x=0,y=0,X=1,Y=1,w=2,h=2"))
    eq(t.responses[-1], _resp(5, "EINVAL:The source and destination rectangles overlap and "
                                 "the src and destination frames are the same"),
       "an overlap inside one frame")
    t.feed(_apc(b"a=c,i=5,r=9,c=2,w=2,h=2"))
    eq(t.responses[-1], _resp(5, "ENOENT:No source frame number 9 exists in image id: 5\n"),
       "a missing source frame")
    # a missing image: kitty's finish_command_response prints r only for a=f and a=a, so the a=c
    # answer has no r key although the command had one
    t = _kitty_term()
    gone = "ENOENT:Animation command refers to non-existent image with id: 99 and number: 0"
    t.feed(_apc(b"a=c,i=99,r=1,c=2"))
    eq(t.responses[-1], _resp(99, gone), "a=c on a missing image answers without r=")
    t.feed(_apc(b"a=a,i=99,r=1,z=10"))
    eq(t.responses[-1], b"\x1b_Gi=99,r=1;" + gone.encode("ascii") + b"\x1b\\",
       "a=a on a missing image keeps r=")
    t.feed(_apc(b"a=f,i=99,r=1,s=1,v=1,f=32;AAAA/w=="))
    eq(t.responses[-1], b"\x1b_Gi=99,r=1;" + gone.encode("ascii") + b"\x1b\\",
       "a=f on a missing image keeps r=")


@case("anim", "delete_frame")
def _anim_delete_frame():
    # handle_delete_frame_command: d=f deletes one frame (number r, 1 is the root), the duration
    # drops by its gap, and the current frame index follows the frames; d=F frees the image when no
    # extra frame is left. The ghostty profile changes nothing.
    t = _kitty_term()
    t.feed(_rgba_img(5, 4, 4))
    t.feed(_apc(b"a=f,i=5,s=4,v=4,f=32,z=30;" + _b64(bytes(64))))
    t.feed(_apc(b"a=f,i=5,s=4,v=4,f=32,z=50;" + _b64(bytes(64))))
    t.feed(_apc(b"a=a,i=5,c=2"))
    anim = t._kitty(t.active).images[5].anim
    eq((len(anim.extra), anim.duration, anim.current), (2, 80, 1), "two extra frames, 80 ms")
    t.feed(_apc(b"a=d,d=f,i=5,r=2"))
    eq((len(anim.extra), anim.duration, anim.current), (1, 50, 1), "frame 2 removed")
    eq(_shown(t, 5)[0], 2, "the current frame is now the old frame 3")
    t.feed(_apc(b"a=d,d=f,i=5"))
    eq((len(anim.extra), anim.root.gap, anim.current), (0, 50, 0), "the root was removed")
    eq(_shown(t, 5)[0], 1, "frame 3 is the root")
    t.feed(_apc(b"a=d,d=f,i=5"))
    check(5 in t._kitty(t.active).images, "d=f with no extra frame does nothing")
    t.feed(_apc(b"a=d,d=F,i=5"))
    check(5 not in t._kitty(t.active).images, "d=F with no extra frame frees the image")
    g = _kterm(10, 4)
    g.feed(_rgba_img(5, 4, 4))
    g.feed(b"\x1b[1;1H" + _apc(b"a=p,i=5,C=1"))
    g.feed(_apc(b"a=d,d=f,i=5,r=2"))
    g.feed(_apc(b"a=d,d=F,i=5"))
    eq((_kimgs(g), _kplaces(g)), ([5], {"5:i"}), "the ghostty profile ignores d=f and d=F")


@case("anim", "kitty_deletes_extra")
def _anim_kitty_deletes_extra():
    # graphics.c handle_delete_command: with no p, d=R frees the images of its range that nothing
    # refers to first; with p that step is skipped, so an unplaced image stays. A delete during a
    # chunked load drops the load in the kitty profile only (free_load_data).
    t = _kitty_term()
    t.feed(_rgba_img(4, 1, 1))
    t.feed(_rgba_img(5, 1, 1))
    t.feed(_apc(b"a=p,i=5,p=7,C=1"))
    t.feed(_apc(b"a=d,d=R,x=4,y=5,p=7"))
    eq((_kimgs(t), _kplaces(t)), ([4], set()), "image 5's placement and image 5 go, image 4 stays")
    t.feed(_apc(b"a=d,d=R,x=4,y=5"))
    eq(_kimgs(t), [], "without p the unplaced image 4 goes")
    for profile in ("kitty", "ghostty-1.3.1"):
        g = _kterm(10, 4, profile=profile)
        g.feed(_apc(b"a=t,f=32,s=1,v=1,i=6,m=1;AAAA"))
        g.feed(_apc(b"a=d,d=i,i=99"))
        kept = g._kitty(g.active).loading is not None
        g.feed(_apc(b"m=0;/w=="))
        stored = 6 in _kimgs(g)
        if profile == "kitty":
            check(not kept and not stored, "kitty: the delete drops the load, nothing is stored")
        else:
            check(kept and stored, "ghostty: the load survives and the final chunk stores image 6")


@case("anim", "retransmit_replaces")
def _anim_retransmit_replaces():
    # a second a=t to the same id replaces the pixels (a larger seq), keeps the placement and counts
    # two transmissions; in the kitty profile it also drops the frames and the animation state
    for profile in ("ghostty-1.3.1", "kitty"):
        t = _kterm(10, 4, profile=profile)
        t.feed(_apc(b"a=t,f=32,s=1,v=1,i=8;" + _b64(b"\xff\x00\x00\xff")))
        t.feed(_apc(b"a=p,i=8,U=1,c=1,r=1"))
        first = t.snapshot()
        t.feed(_apc(b"a=t,f=32,s=1,v=1,i=8;" + _b64(b"\x00\xff\x00\xff")))
        second = t.snapshot()
        check(second.images[8].seq > first.images[8].seq, "%s: a larger seq" % profile)
        eq(second.images[8].rgba, b"\x00\xff\x00\xff", "%s: the new pixels" % profile)
        eq(len(t._kitty(t.active).placements), 1, "%s: the placement is kept" % profile)
        eq(second.stats["by_image"]["8"]["transmissions"], 2, "%s: two transmissions" % profile)
    t = _kitty_term()
    t.feed(_apc(b"a=t,f=32,s=1,v=1,i=8;" + _b64(b"\xff\x00\x00\xff")))
    t.feed(_apc(b"a=f,i=8,s=1,v=1,f=32,z=20;" + _b64(b"\x00\xff\x00\xff")))
    eq(t._kitty(t.active).images[8].anim is not None, True, "a frame made the animation state")
    t.feed(_apc(b"a=t,f=32,s=1,v=1,i=8;" + _b64(b"\x00\x00\xff\xff")))
    check(t._kitty(t.active).images[8].anim is None,
          "the retransmit drops the frames and the state")
    eq(_shown(t, 8)[0], 1, "one frame again")


@case("anim", "color_swap")
def _anim_color_swap():
    # changing the placeholder colour from image A to image B switches the draw with no new APC
    t = _kterm(10, 4)
    t.feed(_rgba_img(1, 4, 4) + _rgba_img(2, 4, 4))
    t.feed(_apc(b"a=p,i=1,U=1,c=1,r=1") + _apc(b"a=p,i=2,U=1,c=1,r=1"))
    t.feed(_at(0, 0, "\x1b[38;2;0;0;1m" + _ph(0, 0)))
    first = t.snapshot()
    eq(first.draws[0].image_id, 1, "image 1 first")
    apc_before = first.stats["apc_bytes"]
    t.feed(_at(0, 0, "\x1b[38;2;0;0;2m" + _ph(0, 0)))
    second = t.snapshot()
    eq(second.draws[0].image_id, 2, "image 2 after the colour changes")
    eq(second.stats["apc_bytes"], apc_before, "no APC bytes for the switch")


@case("anim", "no_time_no_advance")
def _anim_no_time_no_advance():
    # with no time given anywhere, a running animation does not advance: every snapshot shows the
    # current frame
    red = _solid(4, 4, b"\xff\x00\x00\xff")
    green = _solid(4, 4, b"\x00\xff\x00\xff")
    t = _kitty_term()
    t.feed(_apc(b"a=t,f=32,s=4,v=4,i=5;" + _b64(red)))
    t.feed(_apc(b"a=f,i=5,s=4,v=4,f=32,z=50;" + _b64(green)))
    t.feed(_apc(b"a=a,i=5,s=3,v=1"))
    for _ in range(5):
        frame, _seq, pixels = _shown(t, 5)
        eq((frame, pixels[:4]), (1, red[:4]), "frame 1 at every snapshot")




@case("anim", "delete_promotes_dependents")
def _anim_delete_promotes_dependents():
    # graphics.c promote_dependents_to_keyframes: removing the root first composes the frames built
    # on it into full frames, so the one that becomes the root shows the same pixels as before
    red = _solid(4, 4, b"\xff\x00\x00\xff")
    blue = _solid(2, 2, b"\x00\x00\xff\xff")
    green = _solid(4, 4, b"\x00\xff\x00\xff")
    t = _kitty_term()
    t.feed(_apc(b"a=t,f=32,s=4,v=4,i=5;" + _b64(red)))
    t.feed(_apc(b"a=f,i=5,c=1,x=1,y=1,s=2,v=2,f=32;" + _b64(blue)))
    t.feed(_apc(b"a=f,i=5,s=4,v=4,f=32,z=10;" + _b64(green)))
    t.feed(_apc(b"a=a,i=5,c=2"))

    def inside(x, y):
        return 1 <= x <= 2 and 1 <= y <= 2
    want = _grid_bytes(4, 4, lambda x, y: (0, 0, 255, 255) if inside(x, y) else (255, 0, 0, 255))
    eq(_shown(t, 5)[2], _grid_bytes(4, 4, lambda x, y: (0, 0, 255, 255) if inside(x, y)
                                    else (255, 0, 0, 255)), "frame 2 before the delete")
    t.feed(_apc(b"a=d,d=f,i=5"))
    eq(len(t._kitty(t.active).images[5].anim.extra), 1, "frame 2 became the root; frame 3 stays")
    t.feed(_apc(b"a=a,i=5,c=2"))
    eq(_shown(t, 5)[2][:4], b"\x00\xff\x00\xff", "frame 3 shows green")
    t.feed(_apc(b"a=a,i=5,c=1"))
    eq((_shown(t, 5)[0], _shown(t, 5)[2]), (1, want), "the new root shows the promoted pixels")


def _anim_run_stream(placed=True, state=3, loops=1, gap2=100, extra=b""):
    """A kitty terminal with a red root of gap 100 ms, a green frame 2 (gap2 ms, none when None)
    and optionally more commands, placed virtually or not, then started with a=a,s=state at 10.0."""
    t = _kitty_term()
    t.feed(_apc(b"a=t,f=32,s=1,v=1,i=5;" + _b64(b"\xff\x00\x00\xff")))
    z = b",z=%d" % gap2 if gap2 is not None else b""
    t.feed(_apc(b"a=f,i=5,s=1,v=1,f=32" + z + b";" + _b64(b"\x00\xff\x00\xff")), t=9.0)
    t.feed(_apc(b"a=a,i=5,r=1,z=100"), t=9.0)
    if extra:
        t.feed(extra, t=9.0)
    if placed:
        t.feed(_apc(b"a=p,i=5,U=1,c=1,r=1"), t=9.0)
    t.feed(_apc(b"a=a,i=5,s=%d,v=%d" % (state, loops)), t=10.0)
    return t


def _frames_at(t, times):
    return [_shown(t, 5, when)[0] for when in times]


@case("anim", "delete_restarts_timer")
def _anim_delete_restarts_timer():
    # kitty's update_current_frame sets current_frame_shown_at to now. Frames of 100 ms, running
    # from 10.0: frame 2 is shown from 10.1. Deleting it at 10.15 makes the old frame 3 the current
    # one, and it is shown from 10.15 to 10.25, so at 10.22 that is frame 2 (the root again would
    # be the answer if the old start time 10.1 were kept)
    t = _kitty_term()
    t.feed(_apc(b"a=t,f=32,s=1,v=1,i=5;" + _b64(b"\xff\x00\x00\xff")))
    t.feed(_apc(b"a=f,i=5,s=1,v=1,f=32,z=100;" + _b64(b"\x00\xff\x00\xff")), t=9.0)
    t.feed(_apc(b"a=f,i=5,s=1,v=1,f=32,z=100;" + _b64(b"\x00\x00\xff\xff")), t=9.0)
    t.feed(_apc(b"a=a,i=5,r=1,z=100"), t=9.0)
    t.feed(_apc(b"a=p,i=5,U=1,c=1,r=1"), t=9.0)
    t.feed(_apc(b"a=a,i=5,s=3,v=1"), t=10.0)
    eq(_shown(t, 5, 10.15)[0], 2, "frame 2 is shown at 10.15")
    t.feed(_apc(b"a=d,d=f,i=5,r=2"), t=10.15)
    eq(_shown(t, 5, 10.22), (2, _shown(t, 5, 10.22)[1], b"\x00\x00\xff\xff"),
       "the old frame 3 (now frame 2) is shown from 10.15, so at 10.22 it still is")
    eq(_shown(t, 5, 10.27)[0], 1, "and the root returns at 10.25")
    # deleting the root while the current frame is the last one: the same restart
    t = _kitty_term()
    t.feed(_apc(b"a=t,f=32,s=1,v=1,i=5;" + _b64(b"\xff\x00\x00\xff")))
    t.feed(_apc(b"a=f,i=5,s=1,v=1,f=32,z=100;" + _b64(b"\x00\xff\x00\xff")), t=9.0)
    t.feed(_apc(b"a=f,i=5,s=1,v=1,f=32,z=100;" + _b64(b"\x00\x00\xff\xff")), t=9.0)
    t.feed(_apc(b"a=a,i=5,r=1,z=100"), t=9.0)
    t.feed(_apc(b"a=p,i=5,U=1,c=1,r=1"), t=9.0)
    t.feed(_apc(b"a=a,i=5,s=3,v=1"), t=10.0)
    eq(_shown(t, 5, 10.25)[0], 3, "frame 3 is shown at 10.25")
    t.feed(_apc(b"a=d,d=f,i=5,r=3"), t=10.25)
    eq(_shown(t, 5, 10.3)[0], 2, "frame 3 deleted: the current index falls back to frame 2")
    eq(_shown(t, 5, 10.34)[0], 2, "which is shown from 10.25 on (a restart), not from 10.2")
    eq(_shown(t, 5, 10.36)[0], 1, "until 10.35")


@case("anim", "compose_copy_modes")
def _anim_compose_copy_modes():
    # graphics.c blends only when !g->compose_mode && !src_opaque, so any C other than 0 copies
    root = b"\x10\x20\x30\x80"
    for mode, copies in ((None, False), (0, False), (1, True), (2, True)):
        t = _kitty_term()
        t.feed(_apc(b"a=t,f=32,s=1,v=1,i=5;" + _b64(root)))
        t.feed(_apc(b"a=f,i=5,s=1,v=1,f=32;" + _b64(b"\xf0\xe0\xd0\x40")))
        key = b",C=%d" % mode if mode is not None else b""
        t.feed(_apc(b"a=c,i=5,r=1,c=2" + key))
        t.feed(_apc(b"a=a,i=5,c=2"))
        got = _shown(t, 5)[2]
        if copies:
            eq(got, root, "C=%s copies the root's pixel unblended" % mode)
        else:
            eq(got, bytes(_over_straight((0xf0, 0xe0, 0xd0, 0x40), tuple(root))),
               "C=%s blends it over frame 2" % mode)


@case("anim", "frame_wire_bytes")
def _anim_frame_wire_bytes():
    # every chunk of an a=f load is image data on the wire and counts, the first one too, in the
    # total, in the count since a mark and in the image's own wire bytes (as an a=t load's chunks
    # do)
    red = _b64(b"\xff\x00\x00\xff")
    t = _kitty_term()
    t.feed(_apc(b"a=t,f=32,s=1,v=1,i=5;" + red))
    eq(t.stats["transmit_wire_bytes"], 8, "the transmission is 8 characters")
    data = _b64(b"\x00\xff\x00\xff\x00\x00\xff\xff")            # a 2 x 1 frame: 12 characters
    t.feed(_apc(b"a=f,i=5,s=2,v=1,f=32,m=1;" + data[:8]))
    eq(t.stats["transmit_wire_bytes"], 16, "the first a=f chunk counts")
    t.feed(_apc(b"m=0;" + data[8:]))
    eq(t.stats["transmit_wire_bytes"], 20, "and its continuation")
    eq(t.stats["since_prev_mark"]["transmit_wire_bytes"], 20, "the count since a mark follows")
    eq(t.stats["by_image"]["5"]["wire_bytes"], 20, "and so do the image's wire bytes")
    # a one chunk frame counts once; the image's transmission count is not a frame count
    t.feed(_apc(b"a=f,i=5,s=1,v=1,f=32;" + red))
    eq((t.stats["transmit_wire_bytes"], t.stats["by_image"]["5"]["wire_bytes"]), (28, 28),
       "a single chunk frame adds its characters once")
    eq(t.stats["by_image"]["5"]["transmissions"], 1, "frames are not transmissions")
    # the ghostty profile does not execute a=f, and counts nothing for it
    g = _kterm(10, 4)
    g.feed(_apc(b"a=t,f=32,s=1,v=1,i=5;" + red))
    g.feed(_apc(b"a=f,i=5,s=1,v=1,f=32;" + red))
    eq(g.stats["transmit_wire_bytes"], 8, "the ghostty profile counts only the transmission")


@case("anim", "placement_starts_animation")
def _anim_placement_starts_animation():
    # graphics.c: an image advances only while it is drawn (image_is_animatable needs is_drawn,
    # which the render pass sets for an image with a visible placement). Started with no placement
    # it shows frame 1 for good; with a virtual placement it runs
    times = (10.05, 10.15, 10.25)
    eq(_frames_at(_anim_run_stream(placed=False), times), [1, 1, 1], "no placement: no advance")
    eq(_frames_at(_anim_run_stream(placed=True), times), [1, 2, 1], "a virtual placement: it runs")


@case("anim", "frame_answers_carry_r")
def _anim_frame_answers_carry_r():
    # finish_command_response prints r for a=f: the frame number the command ended up with (a new
    # frame is extra frames + 2, an edit is its own number), also in an error answer
    t = _kitty_term()
    t.feed(_apc(b"a=t,f=32,s=1,v=1,i=5;" + _b64(b"\xff\x00\x00\xff")))
    t.feed(_apc(b"a=f,i=5,s=1,v=1,f=32;" + _b64(b"\x00\xff\x00\xff")))
    t.feed(_apc(b"a=f,i=5,r=2,s=1,v=1,f=32;" + _b64(b"\x00\xff\x00\xff")))
    t.feed(_apc(b"a=f,i=5,s=2,v=2,f=32;" + _b64(bytes(16))))
    eq(t.responses[1:], [
        b"\x1b_Gi=5,r=2;OK\x1b\\",
        b"\x1b_Gi=5,r=2;OK\x1b\\",
        b"\x1b_Gi=5,r=3;EINVAL:Frame width 2 larger than image width: 1\x1b\\"],
       "a=f answers carry r")


@case("anim", "default_and_negative_gap")
def _anim_default_and_negative_gap():
    # a frame with no z gets the default gap of 40 ms and a negative z means 0 (the frame is skipped
    # in the cycle). Root 100 ms, frame 2 default, frame 3 z=-5, running from 10.0: the root until
    # 10.1, frame 2 until 10.14, then the root again (frame 3 is skipped) until 10.24, frame 2 ...
    t = _anim_run_stream(gap2=None,
                         extra=_apc(b"a=f,i=5,s=1,v=1,f=32,z=-5;" + _b64(b"\x00\x00\xff\xff")))
    eq(_frames_at(t, (10.05, 10.12, 10.16, 10.26)), [1, 2, 1, 2], "frames of the cycle")
    anim = t._kitty(t.active).images[5].anim
    eq((anim.extra[0].gap, anim.extra[1].gap, anim.duration), (40, 0, 140), "gaps and duration")


@case("anim", "long_chain_key_frame")
def _anim_long_chain_key_frame():
    # reference_chain_too_large: a frame built on a chain of 5 deltas is stored as a full key frame
    # when it is made, so a later edit of the root shows through frame 5 and not through frame 6
    t = _kitty_term()
    t.feed(_apc(b"a=t,f=32,s=4,v=1,i=5;" + _b64(_solid(4, 1, b"\xff\x00\x00\xff"))))
    for n in range(1, 6):
        t.feed(_apc(b"a=f,i=5,c=%d,x=3,y=0,s=1,v=1,f=32;" % n
                    + _b64(b"\x00\x00\xff\xff")))
    t.feed(_apc(b"a=f,i=5,r=1,s=4,v=1,f=32;" + _b64(_solid(4, 1, b"\x00\xff\x00\xff"))))
    t.feed(_apc(b"a=a,i=5,c=6"))
    px6 = _shown(t, 5)[2]
    t.feed(_apc(b"a=a,i=5,c=5"))
    px5 = _shown(t, 5)[2]
    eq(px6, b"\xff\x00\x00\xff" * 3 + b"\x00\x00\xff\xff", "frame 6 kept the red root (key frame)")
    eq(px5, b"\x00\xff\x00\xff" * 3 + b"\x00\x00\xff\xff", "frame 5 shows the edited green root")


@case("anim", "loading_state_stops_at_last_frame")
def _anim_loading_state_stops_at_last_frame():
    # scan_active_animations: in the loading state the cycle stops at the last frame (no wrap to the
    # root) so frames can still be added; and when frames after the shown one have no gap, the
    # current index moves on but the shown frame stays (view_frame is the displayed frame's number)
    eq(_frames_at(_anim_run_stream(state=2), (10.05, 10.15, 10.25, 10.55)), [1, 2, 2, 2],
       "loading: the root, then frame 2 for good")
    eq(_frames_at(_anim_run_stream(state=3), (10.05, 10.15, 10.25, 10.55)), [1, 2, 1, 2],
       "running: the cycle goes on")
    t = _anim_run_stream(state=2, gap2=None,
                         extra=_apc(b"a=f,i=5,s=1,v=1,f=32,z=-1;" + _b64(b"\x00\x00\xff\xff")))
    # root 100 ms, frame 2 default 40 ms, frame 3 gapless: the cycle stops at 10.14 on frame 3's
    # step (frame 2 shown from 10.1)
    eq(_frames_at(t, (10.05, 10.12, 10.5)), [1, 2, 2], "the displayed frame stays frame 2")
    anim = t._kitty(t.active).images[5].anim
    eq(anim.current, 2, "while the current index moved on to the gapless frame")
    eq(_shown(t, 5, 10.5)[0], 2, "and the view is the displayed frame, not current + 1")


@case("anim", "sparse_snapshots")
def _anim_sparse_snapshots():
    # frames change at their due times however sparse the snapshots are: a snapshot at 11.5 sees
    # the cycle as if every frame had been shown at its time (the 15th step from the root is frame
    # 2), where stepping at the snapshot's time would be one step late
    t = _anim_run_stream()
    eq(_frames_at(t, (10.05, 10.15, 10.25, 10.55, 11.5)), [1, 2, 1, 2, 2],
       "the cycle at sparse times")
    t = _anim_run_stream()
    eq(_frames_at(t, (11.5,)), [2], "the same state from one late snapshot")


@case("anim", "opaque_blend_rounding")
def _anim_opaque_blend_rounding():
    # blend_pixel_over_opaque rounds with div255_round: colour 1 at alpha 128 over opaque black is
    # (128 + 128 + 1) >> 8 = 1, where a plain division by 255 gives 0
    t = _kitty_term()
    t.feed(_apc(b"a=t,f=24,s=1,v=1,i=6;" + _b64(b"\x00\x00\x00")))
    t.feed(_apc(b"a=f,i=6,c=1,s=1,v=1,f=32;" + _b64(b"\x01\x01\x01\x80")))
    t.feed(_apc(b"a=a,i=6,c=2"))
    eq(list(_over_opaque((0, 0, 0), (1, 1, 1, 128))), [1, 1, 1], "the oracle")
    eq(_shown(t, 6)[2], b"\x01\x01\x01\xff", "colour 1 at alpha 128 over opaque black stays 1")


@case("anim", "loop_count_ends_animation")
def _anim_loop_count_ends_animation():
    # a=a,v=N: N - 1 loops (v=1 is infinite). v=2 runs one loop: the root, frame 2, and the wrap
    # ends the cycle on frame 2 for good
    eq(_frames_at(_anim_run_stream(loops=2), (10.05, 10.15, 10.25, 10.55, 11.5)), [1, 2, 2, 2, 2],
       "v=2: one loop, then frame 2 stays")
    eq(_frames_at(_anim_run_stream(loops=3), (10.05, 10.15, 10.25, 10.35, 10.55, 11.5)),
       [1, 2, 1, 2, 2, 2], "v=3: two loops")


@case("anim", "edit_of_shown_frame_uploads")
def _anim_edit_of_shown_frame_uploads():
    # an edit of the frame being shown uploads it again (a new seq, the new pixels); an edit of a
    # frame that is not shown changes nothing on screen until it is shown
    t = _kitty_term()
    t.feed(_apc(b"a=t,f=32,s=1,v=1,i=5;" + _b64(b"\xff\x00\x00\xff")))
    t.feed(_apc(b"a=f,i=5,s=1,v=1,f=32;" + _b64(b"\x00\xff\x00\xff")))
    t.feed(_apc(b"a=a,i=5,c=2"))
    frame, seq, pixels = _shown(t, 5)
    eq((frame, pixels), (2, b"\x00\xff\x00\xff"), "frame 2 is shown")
    t.feed(_apc(b"a=f,i=5,r=2,s=1,v=1,f=32;" + _b64(b"\x00\x00\xff\xff")))
    frame2, seq2, pixels2 = _shown(t, 5)
    eq(pixels2, b"\x00\x00\xff\xff", "the edit of the shown frame shows at once")
    check(seq2 != seq, "and it is a new upload (seq)")
    t.feed(_apc(b"a=f,i=5,r=1,s=1,v=1,f=32;" + _b64(b"\x11\x11\x11\xff")))
    frame3, seq3, pixels3 = _shown(t, 5)
    eq((seq3, pixels3), (seq2, pixels2),
       "the edit of the root, which is not shown, changes nothing")


@case("anim", "frame_bad_keys")
def _anim_frame_bad_keys():
    # a=f with transmission keys the loader rejects is answered as kitty answers it (graphics.c
    # initialize_load_data, load_image_data and process_image_data), with the r of the frame number
    # the command ended up with; it never raises out of the terminal. The ghostty profile still
    # refuses a=f without an answer
    red = _b64(b"\xff\x00\x00\xff")
    t = _kitty_term()
    t.feed(_apc(b"a=t,f=32,s=1,v=1,i=1;" + red))
    t.feed(_apc(b"a=f,f=99,i=1;AAAA"))
    eq(t.responses[-1], b"\x1b_Gi=1,r=2;EINVAL:Unknown image format: 99\x1b\\", "an unknown format")
    t.feed(_apc(b"a=f,t=x,f=32,s=1,v=1,i=1;AAAA"))
    eq(t.responses[-1], b"\x1b_Gi=1,r=2;EINVAL:Unknown transmission type: x\x1b\\",
       "an unknown medium")
    t.feed(_apc(b"a=f,o=q,f=32,s=1,v=1,i=1;AAAA/w=="))
    eq(t.responses[-1], b"\x1b_Gi=1,r=2;EINVAL:Unknown image compression: q\x1b\\",
       "an unknown compression")
    t.feed(_apc(b"a=f,f=8,i=1,r=1;AAAA"))
    eq(t.responses[-1],
       b"\x1b_Gi=1,r=1;EINVAL:Animation is not supported for indexed color images\x1b\\",
       "an indexed format")
    eq(len(t._kitty(t.active).images[1].anim.extra), 0, "no frame was made")
    t.feed(_apc(b"a=f,f=99,i=1,r=7;AAAA"))
    eq(t.responses[-1], b"\x1b_Gi=1,r=2;EINVAL:Unknown image format: 99\x1b\\",
       "r past the last frame means a new frame")
    # f=0 is RGBA (fmt = g->format ? g->format : RGBA), and a zero width or height is refused by
    # initialize_load_data before the medium and the compression are looked at
    t.feed(_apc(b"a=f,f=0,s=1,v=1,i=1;" + _b64(b"\x01\x02\x03\x04")))
    eq(t.responses[-1], b"\x1b_Gi=1,r=2;OK\x1b\\", "f=0 is accepted")
    eq(t._kitty(t.active).images[1].anim.extra[-1].data, b"\x01\x02\x03\x04", "as RGBA")
    t.feed(_apc(b"a=f,f=32,i=1;AAAA"))
    eq(t.responses[-1], b"\x1b_Gi=1,r=3;EINVAL:Zero width/height not allowed\x1b\\",
       "no size")
    t.feed(_apc(b"a=f,f=32,t=x,s=1,i=1;AAAA"))
    eq(t.responses[-1], b"\x1b_Gi=1,r=3;EINVAL:Zero width/height not allowed\x1b\\",
       "no height, before the medium is looked at")
    # a chunk of a chunked load takes f, o and the size of the first chunk (INIT_CHUNKED_LOAD,
    # graphics.c): only its m counts, so none of its other keys can be refused, with or without
    # an action key
    pixels = bytes(range(16))
    text = _b64(pixels)
    start = b"a=f,i=1,f=32,s=2,v=2,m=1;" + text[:12]
    last = text[12:]

    def started(profile_term=None):
        term = profile_term or _kitty_term()
        term.feed(_apc(b"a=t,f=32,s=2,v=2,i=1;" + _b64(bytes(16))))
        term.feed(_apc(start))
        return term

    for what, chunk in (
            ("an unknown format", b"a=f,f=99,m=0;"),
            ("an unknown compression", b"a=f,o=y,m=0;"),
            ("an id and an unknown format, no m", b"a=f,i=1,f=99;"),
            ("f=0", b"a=f,f=0,m=0;"),
            ("t=d and an unknown format", b"a=f,t=d,f=99,m=0;"),
            ("an indexed format", b"a=f,f=8,m=0;"),
            ("no action key and an unknown format", b"f=99,m=0;"),
            ("no action key and an unknown compression", b"o=y,m=0;")):
        term = started()
        term.feed(_apc(chunk + last))
        eq(term.responses[-1], b"\x1b_Gi=1,r=2;OK\x1b\\", "the frame completes: " + what)
        eq([f.data for f in term._kitty(term.active).images[1].anim.extra], [pixels],
           "and holds the whole payload: " + what)
        check(term._kitty(term.active).loading is None, "and the load is over: " + what)
    term = started()
    before = len(term.responses)
    term.feed(_apc(b"a=f,f=99,m=1;" + _b64(bytes(range(8, 12)))[:4]))
    eq(term.responses[before:], [], "a chunk with m=1 asks for more and is not answered")
    check(term._kitty(term.active).loading is not None, "and the load goes on")
    term.feed(_apc(b"f=0,m=1;" + _b64(bytes(range(8, 12)))[:4]))
    check(term._kitty(term.active).loading is not None, "also with no action key")
    eq(term.responses[before:], [], "which is not answered either")
    # any m above 0 asks for more, not only 1: a three-chunk load whose middle chunk has m=2 stores
    # one frame and is answered once, after the last chunk
    term = _kitty_term()
    term.feed(_apc(b"a=t,f=32,s=2,v=2,i=1;" + _b64(bytes(16))))
    term.feed(_apc(b"a=f,i=1,f=32,s=2,v=2,m=1;" + text[:8]))
    before = len(term.responses)
    term.feed(_apc(b"m=2;" + text[8:16]))
    eq(term.responses[before:], [], "a middle chunk with m=2 is not answered")
    check(term._kitty(term.active).loading is not None, "and the load goes on")
    term.feed(_apc(b"m=0;" + text[16:]))
    eq(term.responses[before:], [b"\x1b_Gi=1,r=2;OK\x1b\\"], "one answer, after the last chunk")
    eq([f.data for f in term._kitty(term.active).images[1].anim.extra], [pixels],
       "one frame, holding the whole payload")
    term = started()
    term.feed(_apc(b"a=f,i=7,m=0;" + last))
    eq(term.responses[-1], b"\x1b_Gi=7,r=2;OK\x1b\\",
       "a chunk that names an id is answered with it")
    # a chunk with another t starts a new load for the image of the one in progress: the load in
    # progress is dropped, and the new chunk is checked like a first chunk
    term = started()
    term.feed(_apc(b"a=f,t=x,f=32,s=2,v=2,m=0;" + last))
    eq(term.responses[-1], b"\x1b_Gi=1,r=2;EINVAL:Unknown transmission type: x\x1b\\",
       "another medium is a new load, answered as a first chunk (with the first chunk's id)")
    check(term._kitty(term.active).loading is None, "and the load in progress is gone")
    eq(len(term._kitty(term.active).images[1].anim.extra), 0, "no frame was made")
    term = started()
    term.feed(_apc(b"a=f,t=x,m=0;" + last))
    eq(term.responses[-1], b"\x1b_Gi=1,r=2;EINVAL:Zero width/height not allowed\x1b\\",
       "the size of the first chunk is not inherited by a new load")
    tmp = _spec_tempdir()
    try:
        path = _spec_path(tmp, "frame.bin", bytes(range(100, 116)))
        term = started(_kterm(10, 4, profile="kitty", tmpdir=tmp))
        term.feed(_apc(b"a=f,t=f,f=32,s=2,v=2;" + _b64(path)))
        eq(term.responses[-1], b"\x1b_Gi=1,r=2;OK\x1b\\", "a file chunk is a new load, answered OK")
        eq([f.data for f in term._kitty(term.active).images[1].anim.extra],
           [bytes(range(100, 116))], "its frame is the file, not the chunks before it")
        check(term._kitty(term.active).loading is None, "and no load is left")
    finally:
        _drop_spec_dir(tmp)
    # a PNG frame needs no size (the size is the PNG's)
    term = _kitty_term()
    term.feed(_apc(b"a=t,f=32,s=2,v=2,i=1;" + _b64(bytes(16))))
    png = _pil_png("RGBA", (2, 2), [(1, 2, 3, 255)] * 4)
    term.feed(_apc(b"a=f,f=100,i=1;" + _b64(png)))
    eq(term.responses[-1], b"\x1b_Gi=1,r=2;OK\x1b\\", "a PNG frame without s and v is OK")
    eq(term._kitty(term.active).images[1].anim.extra[-1].data, bytes([1, 2, 3, 255] * 4),
       "and holds the PNG's pixels")
    # a new load by a chunk with no action key is a frame, not a transmission: media is not counted
    tmp = _spec_tempdir()
    try:
        path = _spec_path(tmp, "frame2.bin", bytes(range(16)))
        term = started(_kterm(10, 4, profile="kitty", tmpdir=tmp))
        before = dict(term.stats["media"])
        term.feed(_apc(b"t=f,f=32,s=2,v=2;" + _b64(path)))
        eq(term.responses[-1], b"\x1b_Gi=1,r=2;OK\x1b\\", "an action-less new load completes")
        eq(term.stats["media"], before, "and counts as no transmission")
    finally:
        _drop_spec_dir(tmp)
    # data past the limit is answered, not raised
    from vkitty import kgp
    term = started()
    saved = kgp.MAX_SIZE
    kgp.MAX_SIZE = 10
    try:
        term.feed(_apc(b"a=f,m=0;" + last))
        eq(term.responses[-1], b"\x1b_Gi=1,r=2;EINVAL:invalid data\x1b\\", "too much data")
        check(term._kitty(term.active).loading is None, "and the load is dropped")
    finally:
        kgp.MAX_SIZE = saved
    # the ghostty profile: no answer, a warning, no exception
    g = _kterm(10, 4)
    g.feed(_apc(b"a=t,f=32,s=1,v=1,i=1;" + red))
    before = len(g.responses)
    g.feed(_apc(b"a=f,f=99,i=1;AAAA"))
    eq(len(g.responses), before, "the ghostty profile answers nothing")
    check(any("unsupported by ghostty-1.3.1: a=f" in w for w in g.warnings), "and logs it")



@case("place", "report")
def _place_report():
    # to_report: JSON-safe, with the keys the report names and the draws in order
    import json
    from vkitty.snapshot import to_report
    t = _virtual_term(26, 22, 2, 2, [(0, _grid_text(0, 2)), (1, _grid_text(1, 2))])
    rep = to_report(t.snapshot())
    json.dumps(rep)
    eq(sorted(rep), sorted(["cols", "rows", "cell", "pad", "profile", "cursor", "text", "images",
                            "virtual", "draws", "missing", "warnings", "stats", "responses"]),
       "the report's keys")
    eq(rep["draws"][0], {"image_id": 5, "placement_id": 0, "kind": "virtual", "z": -1, "col": 5,
                         "row": 3, "offset": [0, 22], "src": [0, 0, 26, 11], "dest": [26, 11]},
       "the first draw")
    eq([(v["image_id"], v["col"], v["row"], v["w"]) for v in rep["virtual"]],
       [(5, 0, 0, 2), (5, 0, 1, 2)], "the two runs")
    eq((rep["images"][0]["w"], rep["images"][0]["h"], rep["images"][0]["frame"]), (26, 22, 1),
       "the image")
    eq(rep["cursor"]["shape"], "block", "the cursor shape")


@case("place", "no_storage_runs_missing")
def _place_no_storage_runs_missing():
    # a screen with no image at all: its placeholder text is still runs, and each one is missing
    # with the reason that no virtual placement exists (Ghostty scans for runs only with one)
    t = _kterm(10, 4)
    t.feed(_at(0, 1, _fg_rgb(5) + _ph(0, 0)))
    snap = t.snapshot()
    eq(_draws(snap), [], "nothing to draw")
    eq([(v["x"], v["y"], v["image_id"]) for v in snap.virtual], [(0, 1, 5)], "the run is listed")
    eq([m["reason"] for m in snap.missing], ["no virtual placement"], "and it is missing")


# ------------------------------------------------ ssim, render and perf/render ---
# The headless renderer (vkitty.render: the drawing of the reference renderer that made the
# calibration images, with Ghostty's image layers) and the structural similarity that scores it
# (vkitty.ssim). The calibration targets are the reference renders of jupynvim v0.4.6 DataFrame
# outputs (fixtures/calib: the first rows of a capture, painted by the reference renderer in
# Chrome). The image cases check pixels against oracles computed here from the same inputs, never
# against the renderer's own output.

_CALIB_CASES = ("pd_long", "pl_series", "pd_to_html")
_CALIB_FULL_MIN = 0.98
_CALIB_BAND_MIN = 0.95
_BG = (0x22, 0x24, 0x36)       # TokyoNight Moon canvas, the reference renderer's THEME.bg
_FG = (0xc8, 0xd3, 0xf5)       # THEME.fg and THEME.cursor


def _cell_origin(x, y):
    """Canvas pixel of the top left corner of cell (x, y): pad 4, cell 13 x 33 (the metrics)."""
    return 4 + x * 13, 4 + y * 33


def _rgba_random(width, height, seed):
    """Opaque random RGBA pixels, seeded (bytes)."""
    import numpy as np
    arr = np.random.default_rng(seed).integers(0, 256, size=(height, width, 4), dtype=np.uint8)
    arr[..., 3] = 255
    return arr.tobytes()


def _virtual_term_px(width, height, cols, rows, pixels, x=5, y=3, image_id=5):
    """A 20 x 6 terminal with an RGBA image (given pixels) placed virtually as cols x rows cells,
    and the placeholders of each row written at (x, y + row) in the image's colour."""
    t = _kterm(20, 6)
    t.feed(_apc(b"a=t,f=32,s=%d,v=%d,i=%d;" % (width, height, image_id) + _b64(pixels)))
    t.feed(_apc(b"a=p,i=%d,U=1,c=%d,r=%d" % (image_id, cols, rows)))
    for row in range(rows):
        t.feed(_at(x, y + row, _fg_rgb(image_id) + _grid_text(row, cols)))
    return t


def _band_masks(shape, rows):
    """Masks over the SSIM map (the image without its 5 px border, as ssim_map computes it), one
    per cell row of a render: band k holds the image rows of cell row k, the first band also the
    top padding and the last band the bottom padding, so the bands cover every row once."""
    import numpy as np
    h, w = shape[0], shape[1]
    mh, mw = h - 10, w - 10
    masks = []
    for k in range(rows):
        start = 0 if k == 0 else 4 + 33 * k
        end = h if k == rows - 1 else 4 + 33 * (k + 1)
        lo, hi = max(0, start - 5), min(mh, end - 5)
        mask = np.zeros((mh, mw), dtype=bool)
        mask[lo:hi, :] = True
        masks.append(mask)
    return masks


@case("ssim", "identity_and_constants")
def _ssim_identity_and_constants():
    # ssim.py: identical images score 1; two constant images score the luminance term alone,
    # (2ab + C1) / (a^2 + b^2 + C1) with C1 = (0.01 * 255)^2; the score is symmetric and falls as
    # noise is added
    import numpy as np
    from vkitty.ssim import ssim, ssim_map
    rng = np.random.default_rng(1)
    x = rng.integers(0, 256, size=(40, 50, 3), dtype=np.uint8)
    y = rng.integers(0, 256, size=(40, 50, 3), dtype=np.uint8)
    same = ssim(x, x)
    check(abs(same - 1.0) <= 1e-12, "ssim(x, x) is %r" % same)
    check(abs(ssim(x, y) - ssim(y, x)) <= 1e-12, "ssim is not symmetric")
    eq(ssim_map(x, y).shape, (30, 40), "the map is on the valid region (5 px border dropped)")
    c1 = (0.01 * 255) ** 2
    for a, b in ((100.0, 180.0), (3.0, 250.0), (128.0, 128.0)):
        want = (2 * a * b + c1) / (a * a + b * b + c1)
        got = ssim(np.full((20, 20, 3), a), np.full((20, 20, 3), b))
        check(abs(got - want) <= 1e-9, "means %g and %g: %r, want %r" % (a, b, got, want))
    scores = []
    z = rng.standard_normal(x.shape)
    for amp in (0.0, 2.0, 8.0, 32.0):
        noisy = np.clip(np.rint(x + amp * z), 0, 255).astype(np.uint8)
        scores.append(ssim(x, noisy))
    check(all(scores[i] > scores[i + 1] for i in range(len(scores) - 1)),
          "scores do not fall with noise: %r" % (scores,))


@case("ssim", "luma_and_rgb")
def _ssim_luma_and_rgb():
    """The default score is of the luma: a field of one color against a field of another color of
    the same luma scores 1, so SSIM alone cannot tell a wrong palette token. channels="rgb" scores
    the three channels on their own and does tell them apart (it equals the luma score for gray)."""
    import numpy as np
    from vkitty.ssim import ssim, ssim_map
    rng = np.random.default_rng(3)
    base = rng.integers(60, 190, size=(30, 40), dtype=np.uint8)
    # two colors of the same luma: a shift with 0.299 dR + 0.587 dG + 0.114 dB = 0
    a = np.stack([base, base, base], axis=-1).astype(np.float64)
    b = a.copy()
    b[..., 0] += 0.587 * 120.0
    b[..., 1] -= 0.299 * 120.0
    check(abs(ssim(a, b) - 1.0) <= 1e-9, "same luma, other color: luma SSIM %r" % ssim(a, b))
    rgb = ssim(a, b, channels="rgb")
    check(rgb < 0.99, "per-channel SSIM sees the other color: %r" % rgb)
    gray = rng.integers(0, 256, size=(30, 40, 3), dtype=np.uint8)
    gray[..., 1] = gray[..., 0]
    gray[..., 2] = gray[..., 0]
    noisy = np.clip(gray + rng.integers(-6, 7, size=gray.shape), 0, 255)
    noisy[..., 1] = noisy[..., 0]
    noisy[..., 2] = noisy[..., 0]
    check(abs(ssim(gray, noisy) - ssim(gray, noisy, channels="rgb")) <= 1e-9,
          "for gray the two agree")
    eq(ssim_map(a, b, channels="rgb").shape, (20, 30), "the map is on the valid region too")
    for bad in ("hsv", "RGB"):
        try:
            ssim(a, b, channels=bad)
        except ValueError:
            pass
        else:
            raise AssertionError("channels=%r was accepted" % bad)
    try:
        ssim(base, base, channels="rgb")
    except ValueError:
        pass
    else:
        raise AssertionError("channels='rgb' accepted a 2-D image")


@case("render", "fonts_sha")
def _render_fonts_sha():
    # the bundled subsets are the ones SOURCE.txt names (sha256 and size), and OFL.txt carries the
    # copyright line of their name table
    import hashlib
    from fontTools.ttLib import TTFont
    folder = os.path.join(LIB, "vkitty", "fonts")
    with open(os.path.join(folder, "SOURCE.txt"), "r", encoding="ascii") as fh:
        text = fh.read()
    check("/Users/" not in text and "/private/" not in text, "SOURCE.txt holds a local path")
    rows = [line.split() for line in text.split("\n") if line.startswith("  subset: ")]
    eq(sorted(r[1] for r in rows),
       sorted("IosevkaCustom-%s.subset.ttf" % s
              for s in ("Regular", "SemiBold", "Italic", "SemiBoldItalic")), "the subsets listed")
    for r in rows:
        name, want_sha, want_size = r[1], r[3], int(r[5])
        with open(os.path.join(folder, name), "rb") as fh:
            data = fh.read()
        eq(len(data), want_size, "%s size" % name)
        eq(hashlib.sha256(data).hexdigest(), want_sha, "%s sha256" % name)
    with open(os.path.join(folder, "OFL.txt"), "r", encoding="ascii") as fh:
        ofl = fh.read()
    first = ofl.split("\n", 1)[0]
    font = TTFont(os.path.join(folder, "IosevkaCustom-Regular.subset.ttf"), lazy=True)
    eq(first, font["name"].getDebugName(0), "OFL.txt copyright line")
    check("SIL OPEN FONT LICENSE Version 1.1" in ofl, "OFL.txt is not the OFL 1.1 text")


@case("render", "metrics")
def _render_metrics():
    # metricsFor (the reference renderer, Ghostty's Metrics.zig) for IosevkaCustom Regular at 26 px:
    # a 13 x 33 cell, baseline 26, underline at 27 and 2 px thick, strikethrough at 19 and 2 px, box
    # line 2 px
    from vkitty.fonts import faces
    from vkitty.render import metrics_for
    m = metrics_for(faces()["regular"])
    eq((m.cw, m.ch, m.base, m.ulPos, m.ulTh, m.stPos, m.stTh, m.boxTh, m.pad, m.adv),
       (13, 33, 26, 27, 2, 19, 2, 2, 4, 500),
       "cell, baseline, underline, strike, box, pad, advance")
    eq(m.cellBase, 7, "the cell base")
    check(abs(m.faceBase - 7.41) <= 1e-9, "the face base is %r, want 7.41" % m.faceBase)


@case("render", "calibration")
def _render_calibration():
    # the three fixtures: the renderer's full image scores >= 0.98 against the reference PNG, and
    # every cell row (33 px, with the padding in the first and last) scores >= 0.95
    import json
    import numpy as np
    from PIL import Image
    from vkitty.grid_tmux import parse_capture
    from vkitty.render import render
    from vkitty.ssim import ssim
    folder = os.path.join(LIB, "vkitty", "fixtures", "calib")
    notes = []
    for name in _CALIB_CASES:
        with open(os.path.join(folder, name + ".json"), "r", encoding="utf-8") as fh:
            meta = json.load(fh)
        with open(os.path.join(folder, name + ".ansi"), "r", encoding="utf-8") as fh:
            ansi = fh.read()
        ref = np.asarray(Image.open(os.path.join(folder, name + ".png")).convert("RGB"))
        cols, rows = meta["cols"], meta["rows"]
        eq(ref.shape, (8 + 33 * rows, 8 + 13 * cols, 3), "%s: the reference size" % name)
        snap = parse_capture(ansi, cols, rows)
        # a capture carries no cursor; the fixture says whether the reference had one
        snap.cursor = (0, 0, bool(meta["cursor_visible"]), "block")
        out = render(snap)
        eq(out.shape, ref.shape, "%s: the rendered size" % name)
        full = ssim(out, ref)
        check(full >= _CALIB_FULL_MIN, "%s: SSIM %.4f is below %.2f"
              % (name, full, _CALIB_FULL_MIN))
        worst = 1.0
        for k, mask in enumerate(_band_masks(ref.shape, rows)):
            score = ssim(out, ref, mask=mask)
            worst = min(worst, score)
            check(score >= _CALIB_BAND_MIN, "%s: row %d scores %.4f, below %.2f"
                  % (name, k, score, _CALIB_BAND_MIN))
        notes.append("%s %.4f (worst row %.4f)" % (name, full, worst))
    return "; ".join(notes)


@case("render", "image_identity")
def _render_image_identity():
    # renderer/image.zig: the placeholder cells of a 26 x 66 image in 2 x 2 cells draw it at 1:1, so
    # the 26 x 66 px box at cell (5, 3) shows the image's own pixels (opaque: exact to one level)
    import numpy as np
    from vkitty.render import render
    pixels = _rgba_random(26, 66, 11)
    img = render(_virtual_term_px(26, 66, 2, 2, pixels).snapshot())
    x0, y0 = _cell_origin(5, 3)
    want = np.frombuffer(pixels, np.uint8).reshape(66, 26, 4)[..., :3].astype(np.int32)
    got = img[y0:y0 + 66, x0:x0 + 26].astype(np.int32)
    diff = int(np.abs(got - want).max())
    check(diff <= 1, "the box differs from the image by up to %d" % diff)


@case("render", "image_letterbox")
def _render_image_letterbox():
    # place/letterbox_wide: a 26 x 22 image in 2 x 2 cells (a 26 x 66 px box) sits at box rows 22 to
    # 43; the rows above and below it are the cell background, exactly
    import numpy as np
    from vkitty.render import render
    pixels = _rgba_random(26, 22, 12)
    img = render(_virtual_term_px(26, 22, 2, 2, pixels).snapshot())
    x0, y0 = _cell_origin(5, 3)
    box = img[y0:y0 + 66, x0:x0 + 26].astype(np.int32)
    bg = np.broadcast_to(np.array(_BG, np.int32), (22, 26, 3))
    check(np.array_equal(box[0:22], bg), "the rows above the image are not the background")
    check(np.array_equal(box[44:66], bg), "the rows below the image are not the background")
    want = np.frombuffer(pixels, np.uint8).reshape(22, 26, 4)[..., :3].astype(np.int32)
    diff = int(np.abs(box[22:44] - want).max())
    check(diff <= 1, "the image rows differ by up to %d" % diff)


@case("render", "linear_filter")
def _render_linear_filter():
    # the image is filtered in linear light: a one-texel black and white checkerboard drawn at half
    # size averages to 0.5 linear, 187.5 in sRGB (an sRGB average would give 127.5)
    import numpy as np
    from vkitty.render import render
    yy, xx = np.mgrid[0:132, 0:52]
    arr = np.zeros((132, 52, 4), dtype=np.uint8)
    arr[..., :3] = np.where(((xx + yy) % 2 == 0)[..., None], 255, 0)
    arr[..., 3] = 255
    img = render(_virtual_term_px(52, 132, 2, 2, arr.tobytes()).snapshot())
    x0, y0 = _cell_origin(5, 3)
    box = img[y0:y0 + 66, x0:x0 + 26]
    lo, hi = int(box.min()), int(box.max())
    check(lo >= 187 and hi <= 188, "the box spans %d to %d, want 187 to 188" % (lo, hi))


@case("render", "alpha_blend")
def _render_alpha_blend():
    # a 50 % red image over a blue cell background: the colour is premultiplied in sRGB and
    # composited over the background (out = src + dst * (1 - a)), each channel within one level
    import numpy as np
    from vkitty.render import render
    t = _kterm(20, 6)
    # the cursor would sit on the cell (C=1 keeps it there) and paint over it
    t.feed(b"\x1b[?25l")
    t.feed(_at(4, 2, "\x1b[48;2;30;60;200m \x1b[0m"))
    t.feed(_apc(b"a=t,f=32,s=13,v=33,i=7;" + _b64(_solid(13, 33, b"\xff\x00\x00\x80"))))
    t.feed(b"\x1b[3;5H" + _apc(b"a=p,i=7,C=1"))
    img = render(t.snapshot())
    a = 128 / 255.0
    want = np.array([255 * a, 0.0, 0.0]) + np.array([30.0, 60.0, 200.0]) * (1 - a)
    x0, y0 = _cell_origin(4, 2)
    got = img[y0:y0 + 33, x0:x0 + 13].astype(np.float64)
    diff = float(np.abs(got - want).max())
    check(diff <= 1.0, "the blend differs from %r by up to %.2f" % (want.round(2).tolist(), diff))


@case("render", "z_layers")
def _render_z_layers():
    # Ghostty's three image layers (image.zig, generic.zig): below the cell backgrounds (z below
    # INT32_MIN / 2), between the backgrounds and the text (z -1), above the text (z 5). Each layer
    # sits in its own cell
    import numpy as np
    from vkitty.render import render
    t = _kterm(20, 6)
    t.feed(b"\x1b[?25l")
    t.feed(_at(0, 0, "\x1b[48;2;10;200;10m\x1b[38;2;255;255;255mX\x1b[0m"))
    t.feed(_at(1, 0, "\x1b[38;2;255;255;255mX\x1b[0m"))
    t.feed(_at(2, 0, "\x1b[38;2;255;255;255mX\x1b[0m"))
    t.feed(_apc(b"a=t,f=32,s=13,v=33,i=21;" + _b64(_solid(13, 33, b"\xff\x00\xff\xff"))))
    t.feed(_apc(b"a=t,f=32,s=13,v=33,i=22;" + _b64(_solid(13, 33, b"\x00\xff\xff\xff"))))
    t.feed(_apc(b"a=t,f=32,s=13,v=33,i=23;" + _b64(_solid(13, 33, b"\xff\xff\x00\xff"))))
    t.feed(b"\x1b[1;1H" + _apc(b"a=p,i=21,C=1,z=-1073741825"))
    t.feed(b"\x1b[1;2H" + _apc(b"a=p,i=22,C=1,z=-1"))
    t.feed(b"\x1b[1;3H" + _apc(b"a=p,i=23,C=1,z=5"))
    snap = t.snapshot()
    img = render(snap)
    bare = render(snap, images=False)
    x0, y0 = _cell_origin(0, 0)
    cell0 = img[y0:y0 + 33, x0:x0 + 13]
    check(not np.any(np.all(cell0 == (255, 0, 255), axis=-1)),
          "the layer below the background shows through the background")
    check(np.any(np.all(cell0 == (10, 200, 10), axis=-1)), "the background is not visible")
    x1, _ = _cell_origin(1, 0)
    cell1 = img[y0:y0 + 33, x1:x1 + 13]
    ink = np.all(bare[y0:y0 + 33, x1:x1 + 13] == (255, 255, 255), axis=-1)
    empty = np.all(bare[y0:y0 + 33, x1:x1 + 13] == _BG, axis=-1)
    check(ink.any() and empty.any(), "the glyph or the background is missing from the bare cell")
    check(np.all(cell1[ink] == (255, 255, 255)), "the glyph is not drawn over the image")
    check(np.all(cell1[empty] == (0, 255, 255)),
          "the image is not drawn between the background and text")
    x2, _ = _cell_origin(2, 0)
    cell2 = img[y0:y0 + 33, x2:x2 + 13]
    check(np.all(cell2 == (255, 255, 0)), "the image above the text does not cover the glyph")
    # the layer below the backgrounds shows where no background covers it (cell 3 has none)
    x3, _ = _cell_origin(3, 0)
    t.feed(b"\x1b[1;4H" + _apc(b"a=p,i=21,C=1,z=-1073741825"))
    cell3 = render(t.snapshot())[y0:y0 + 33, x3:x3 + 13]
    check(np.all(cell3 == (255, 0, 255)), "the layer below the backgrounds is not drawn")


@case("render", "cursor_over_image")
def _render_cursor_over_image():
    # the block cursor is drawn after the images below the text (Ghostty draws it in the text pass):
    # on a placeholder cell it covers the image in the cursor colour, and the next cell shows the
    # image
    import numpy as np
    from vkitty.render import render
    pixels = _rgba_random(26, 33, 14)
    t = _virtual_term_px(26, 33, 2, 1, pixels)
    t.feed(b"\x1b[4;6H")
    img = render(t.snapshot())
    x0, y0 = _cell_origin(5, 3)
    check(np.all(img[y0:y0 + 33, x0:x0 + 13] == _FG), "the cursor cell is not in cursor colour")
    want = np.frombuffer(pixels, np.uint8).reshape(33, 26, 4)[:, 13:, :3].astype(np.int32)
    x1, _ = _cell_origin(6, 3)
    diff = int(np.abs(img[y0:y0 + 33, x1:x1 + 13].astype(np.int32) - want).max())
    check(diff <= 1, "the cell next to the cursor differs from the image by up to %d" % diff)


@case("render", "pin_history_clip")
def _render_pin_history_clip():
    # place/pin_history_partial after one LF: the 13 x 99 image's top two rows are in history, so
    # the draw starts at row -1 and canvas row 0 shows image row 29. Ghostty draws in grid space
    # with no scissor, so the top padding shows the image too; only the canvas edge clips it
    import numpy as np
    from vkitty.render import render
    pixels = _rgba_random(13, 99, 13)
    t = _kterm(10, 4)
    t.feed(_apc(b"a=t,f=32,s=13,v=99,i=5;" + _b64(pixels)))
    t.feed(b"\x1b[1;1H" + _apc(b"a=p,i=5,C=1"))
    t.feed(b"\x1b[4;1H\n")
    img = render(t.snapshot())
    want = np.frombuffer(pixels, np.uint8).reshape(99, 13, 4)[29:99, :, :3].astype(np.int32)
    got = img[0:70, 4:17].astype(np.int32)
    diff = int(np.abs(got - want).max())
    check(diff <= 1, "canvas rows 0 to 69 differ from image rows 29 to 98 by up to %d" % diff)


@case("render", "decorations")
def _render_decorations():
    # the reference renderer's geometry in a 13 x 33 cell: single underline on row 27, double on
    # rows 25 and 29 (2 px each), strikethrough on rows 19 and 20, overline on rows 0 and 1, all in
    # the foreground
    import numpy as np
    from vkitty.render import render
    t = _kterm(20, 6)
    t.feed(_at(0, 0, "\x1b[4m \x1b[0m"))
    t.feed(_at(1, 0, "\x1b[21m \x1b[0m"))
    t.feed(_at(2, 0, "\x1b[9m \x1b[0m"))
    t.feed(_at(3, 0, "\x1b[53m \x1b[0m"))
    img = render(t.snapshot())
    want = [{27, 28}, {25, 26, 29, 30}, {19, 20}, {0, 1}]
    for x, rows in enumerate(want):
        x0, y0 = _cell_origin(x, 0)
        cell = img[y0:y0 + 33, x0:x0 + 13]
        full = {r for r in range(33) if np.all(cell[r] == _FG)}
        eq(full, rows, "the decoration of cell %d" % x)


def _need_fallback_face(cp):
    """The host has a font for a code point outside the bundled subsets, or the case fails with the
    packages to install. These cases test the fallback chain, which reads the host's fonts: on
    macOS Menlo and Arial Unicode, on Linux what fontconfig has (fonts-dejavu-core for U+0250,
    fonts-noto-cjk for U+4E16)."""
    from vkitty import fonts
    if fonts.face_for("regular", cp) is None:
        raise AssertionError(
            "this host has no font with U+%04X (a Linux host needs fontconfig and the packages "
            "fonts-dejavu-core, fonts-noto-cjk and fonts-noto-color-emoji); the fallback chain "
            "of tests/lib/vkitty/fonts.py has nothing to draw it with" % cp)


@case("render", "fallback_glyph")
def _render_fallback_glyph():
    # U+0250 is outside the bundled subset: the fallback chain draws it, and the cell gets ink
    import numpy as np
    from vkitty.render import render
    _need_fallback_face(0x250)
    t = _kterm(20, 6)
    t.feed("\x1b[38;2;255;255;255m\u0250\x1b[0m".encode("utf-8"))
    warn = []
    img = render(t.snapshot(), warn=warn)
    x0, y0 = _cell_origin(0, 0)
    cell = img[y0:y0 + 33, x0:x0 + 13].astype(np.int32)
    bright = int(np.count_nonzero(cell.sum(axis=-1) > 3 * 120))
    check(bright >= 10, "the fallback glyph has %d bright pixels" % bright)
    check(not warn, "a fallback glyph warns: %r" % warn)


@case("render", "missing_glyph_warns")
def _render_missing_glyph_warns():
    # a code point no font carries is drawn as nothing, with the warning "no glyph U+XXXX"
    from vkitty.render import render
    t = _kterm(20, 6)
    t.feed("\U0010FFFD".encode("utf-8"))
    warn = []
    render(t.snapshot(), warn=warn)
    check(any("no glyph U+10FFFD" in line for line in warn), "no warning: %r" % (warn,))


def _with_glyph(fake, fn):
    """Runs fn with fonts.glyph replaced by fake(face, text) (restored afterwards)."""
    from vkitty import fonts as _fonts
    saved = _fonts.glyph
    _fonts.glyph = fake
    try:
        return fn()
    finally:
        _fonts.glyph = saved


@case("render", "symbol_fit")
def _render_symbol_fit():
    # the reference renderer's symbol class (Ghostty's size constraint): an ink box wider than its
    # cells is scaled about its centre to the cell width (f = cells * face width / ink width). A 40
    # px wide ink in one cell draws about 13 px wide inside that cell, and nothing outside it
    import numpy as np
    from vkitty import fonts as _fonts
    from vkitty import render as R
    t = _kterm(20, 6)
    snap = t.snapshot()
    frame = R._Frame(snap, R.DEFAULT_THEME, [])
    fake = _fonts.Glyph(np.ones((33, 40), dtype=np.float32), -20, -26, None)
    X, Y = _cell_origin(3, 2)
    _with_glyph(lambda face, text: fake,
                lambda: R._symbol_glyph(frame, None, "X", X, Y, 1, R._vec(_FG), 1.0))
    band = frame.canvas[Y:Y + 33, X - 4:X + 17]
    lit = np.any(band.sum(axis=-1) > 3 * 60, axis=0)
    cols = [i - 4 for i in range(len(lit)) if lit[i]]
    check(cols and cols[0] >= 0 and cols[-1] <= 12, "ink outside the cell: columns %r" % cols)
    eq(len(cols) >= 12 and len(cols) <= 14, True, "the ink is %d columns wide, want about 13"
       % len(cols))


@case("render", "colour_glyph")
def _render_colour_glyph():
    # a colour glyph (an emoji from a colour font) keeps its own colours: at half coverage its pixel
    # mixes its colour and the background (out = rgb * a + dst * (1 - a)), whatever the text colour
    import numpy as np
    from vkitty import fonts as _fonts
    from vkitty import render as R
    frame = R._Frame(_kterm(20, 6).snapshot(), R.DEFAULT_THEME, [])
    rgb = np.zeros((4, 4, 3), dtype=np.float32)
    rgb[...] = (10.0, 200.0, 30.0)
    glyph = _fonts.Glyph(np.full((4, 4), 0.5, dtype=np.float32), 0, -4, rgb)
    X, Y = _cell_origin(1, 1)
    R._glyph_at(frame, glyph, X, Y + 4, (255, 255, 255), 1.0)
    want = np.array([10.0, 200.0, 30.0]) * 0.5 + np.array(_BG, dtype=np.float64) * 0.5
    got = frame.canvas[Y:Y + 4, X:X + 4].astype(np.float64)
    diff = float(np.abs(got - want).max())
    check(diff <= 1.0, "the colour glyph differs from %r by up to %.2f"
          % (want.round(1).tolist(), diff))


@case("render", "cursor_shapes")
def _render_cursor_shapes():
    # the cursor shapes (the reference renderer's bar; Ghostty's underline sprite and hollow block)
    # in the cursor colour: a bar is 1 px wide just left of the cell's edge, an underline fills the
    # underline row of the cell, a hollow block is a 1 px outline inside the cell
    import numpy as np
    from vkitty import render as R
    t = _kterm(20, 6)
    t.feed(b"\x1b[?25l")
    snap = t.snapshot()
    cur = np.array(_FG, dtype=np.int32)
    snap.cursor = (2, 1, True, "bar")
    img = R.render(snap).astype(np.int32)
    X, Y = _cell_origin(2, 1)
    check(np.all(img[Y:Y + 33, X - 1] == cur), "the bar is not on the column left of the cell")
    check(np.all(img[Y:Y + 33, X] == np.array(_BG)), "the bar covers the cell")
    snap.cursor = (0, 0, True, "underline")
    img = R.render(snap).astype(np.int32)
    X, Y = _cell_origin(0, 0)
    rows = [r for r in range(33) if np.all(img[Y + r, X:X + 13] == cur)]
    eq(rows, [27],
       "the underline cursor is 1 px tall (Metrics.cursor_thickness) at the underline row")
    snap.cursor = (4, 0, True, "block_hollow")
    img = R.render(snap).astype(np.int32)
    X, Y = _cell_origin(4, 0)
    box = img[Y:Y + 33, X:X + 13]
    outline = np.zeros((33, 13), dtype=bool)
    outline[0, :] = outline[-1, :] = outline[:, 0] = outline[:, -1] = True
    check(np.all(box[outline] == cur), "the hollow outline is not in cursor colour")
    check(np.all(box[1:-1, 1:-1] == np.array(_BG)), "the hollow block fills its cell")


@case("render", "cursor_underline_canvas")
def _render_cursor_underline_canvas():
    # Ghostty's cursor_underline draws at min(underline_position, height + canvas.padding_y -
    # underline_thickness): the sprite canvas extends padding_y, a quarter of the cell height, below
    # the cell, and the line may go that far down. A face whose underline sits low draws it below
    # the cell, up to the canvas (cell 13 x 33: padding 8, thickness 2, so the last row is 39)
    import numpy as np
    from vkitty import render as R
    real = R._metrics
    t = _kterm(20, 6)
    t.feed(b"\x1b[?25l")
    snap = t.snapshot()
    cur = np.array(_FG, dtype=np.int32)
    try:
        for position, want in ((27, 27), (36, 36), (39, 39), (40, 39), (50, 39)):
            low = R.Metrics(**vars(real()))
            low.ulPos = position
            R._metrics = lambda low=low: low
            snap.cursor = (0, 0, True, "underline")
            img = R.render(snap).astype(np.int32)
            X, Y = _cell_origin(0, 0)
            rows = [r for r in range(60) if np.all(img[Y + r, X:X + 13] == cur)]
            eq(rows, [want], "underline at %d: the cursor line row" % position)
    finally:
        R._metrics = real


@case("render", "underline_styles")
def _render_underline_styles():
    # the reference renderer's underline kinds in a 13 x 33 cell with the underline on row 27 (2
    # px): dashed is 7 px (Math.round of half the cell) at the left; dotted is three 2 px dots at
    # 4.33 px spacing, so the columns fully covered are 0, 1, 5 and 9; curly is a wave between rows
    # 27 and 31
    import numpy as np
    from vkitty import render as R
    t = _kterm(20, 6)
    t.feed(_at(0, 0, "\x1b[4:5m \x1b[0m"))
    t.feed(_at(1, 0, "\x1b[4:4m \x1b[0m"))
    t.feed(_at(2, 0, "\x1b[4:3m \x1b[0m"))
    img = R.render(t.snapshot()).astype(np.int32)
    fg = np.array(_FG)
    X, Y = _cell_origin(0, 0)
    dashed = img[Y + 27, X:X + 13]
    eq([i for i in range(13) if np.all(dashed[i] == fg)], list(range(7)), "dashed columns")
    X, Y = _cell_origin(1, 0)
    dotted = img[Y + 27, X:X + 13]
    eq([i for i in range(13) if np.all(dotted[i] == fg)], [0, 1, 5, 9], "dotted columns")
    X, Y = _cell_origin(2, 0)
    curly = img[Y:Y + 33, X:X + 13]
    ink_rows = sorted({r for r in range(33) for c in range(13) if not np.all(curly[r, c] == _BG)})
    check(ink_rows and min(ink_rows) >= 24 and max(ink_rows) <= 32 and len(ink_rows) >= 3,
          "curly rows %r" % (ink_rows,))
    check(not np.all(curly[:, 0] == np.array(_BG)) and not np.all(curly[:, 12] == np.array(_BG)),
          "curly has no ink at the cell's ends")


@case("render", "faint_and_inverse")
def _render_faint_and_inverse():
    # faint (SGR 2) takes the alpha 0.5 of the theme: a faint underline is the mean of the text
    # colour and the background; inverse (SGR 7) swaps them, so a blank cell shows the text colour
    import numpy as np
    from vkitty import render as R
    t = _kterm(20, 6)
    t.feed(_at(0, 0, "\x1b[2;4m \x1b[0m"))
    t.feed(_at(1, 0, "\x1b[7m \x1b[0m"))
    img = R.render(t.snapshot()).astype(np.float64)
    X, Y = _cell_origin(0, 0)
    want = (np.array(_FG, dtype=np.float64) + np.array(_BG, dtype=np.float64)) / 2
    diff = float(np.abs(img[Y + 27, X:X + 13] - want).max())
    check(diff <= 1.0, "the faint underline differs from %r by up to %.2f" % (want.tolist(), diff))
    X, Y = _cell_origin(1, 0)
    check(np.all(img[Y:Y + 33, X:X + 13] == np.array(_FG, dtype=np.float64)),
          "the inverse cell is not the text colour")


@case("render", "crop_and_theme")
def _render_crop_and_theme():
    # crop_rows keeps the rows r0 to r1 as the reference renderer crops them (from the top of row r0
    # to the bottom padding under row r1); theme replaces the colours (a black background shows as
    # black)
    import numpy as np
    from vkitty import render as R
    t = _kterm(10, 6)
    t.feed(b"\x1b[?25l")
    snap = t.snapshot()
    full = R.render(snap)
    part = R.render(snap, crop_rows=(2, 4))
    # rows 2 to 4: from the top of row 2 (y 70) to the bottom padding under row 4 (y 173)
    eq(part.shape, (103, full.shape[1], 3), "the cropped shape")
    check(np.array_equal(part, full[70:173]), "the crop is not the rows of the render")
    dark = dict(R.DEFAULT_THEME, bg="#000000")
    black = R.render(snap, theme=dark)
    check(np.all(black[0:4, 0:4] == 0) and np.all(black[40:70, 10:30] == 0),
          "the theme background is not black")


@case("render", "texture_follows_seq")
def _render_texture_follows_seq():
    # the texture of an image is cached per (id, seq): a retransmission to the same id bumps seq and
    # the renderer shows the new pixels (a cache keyed on the id alone would keep the old ones)
    import numpy as np
    from vkitty import render as R
    red = _solid(13, 33, b"\xff\x00\x00\xff")
    green = _solid(13, 33, b"\x00\xff\x00\xff")
    t = _kterm(20, 6)
    t.feed(b"\x1b[?25l")
    t.feed(_apc(b"a=t,f=32,s=13,v=33,i=5;" + _b64(red)))
    t.feed(b"\x1b[1;1H" + _apc(b"a=p,i=5,C=1"))
    x0, y0 = _cell_origin(0, 0)
    first = R.render(t.snapshot())[y0:y0 + 33, x0:x0 + 13]
    check(np.all(first == (255, 0, 0)), "the first transmission does not show red")
    t.feed(_apc(b"a=t,f=32,s=13,v=33,i=5;" + _b64(green)))
    second = R.render(t.snapshot())[y0:y0 + 33, x0:x0 + 13]
    check(np.all(second == (0, 255, 0)), "the retransmitted image still shows the old pixels")


# ---- render cases added to hold the rules of the renderer one by one (oracles are computed here
# from the inputs: Pillow's own masks, the rectangles of the cell geometry, the 256 colour table)
# --------

_BG_ARR = (0x22, 0x24, 0x36)
_CELL_W, _CELL_H, _BASE = 13, 33, 26


def _cell_pixels(img, x, y, cells=1):
    """The pixels of `cells` cells starting at cell (x, y), (33, 13 * cells, 3) int."""
    x0, y0 = _cell_origin(x, y)
    return img[y0:y0 + _CELL_H, x0:x0 + _CELL_W * cells].astype(int)


def _pillow_mask(style, text):
    """Pillow's own coverage of text in the bundled face of a style at 26 px (RAQM shaping, as
    fonts.py rasterizes it) with the coverage gamma applied here: (alpha float64 (h, w), left, top)
    relative to the origin (left edge, baseline)."""
    import numpy as np
    from PIL import Image, ImageFont
    from vkitty.fonts import faces
    font = ImageFont.truetype(faces()[style], 26, layout_engine=ImageFont.Layout.RAQM)
    raw = font.getmask2(text, mode="L", anchor="ls")
    arr = np.asarray(Image.Image()._new(raw[0]))
    return (arr.astype(np.float64) / 255.0) ** 0.6, raw[1][0], raw[1][1], arr


def _blank_cell(colour=_BG_ARR, cells=1):
    import numpy as np
    out = np.zeros((_CELL_H, _CELL_W * cells, 3), dtype=np.float64)
    out[...] = colour
    return out


def _put_mask(cell, mask, left, top, colour, alpha=1.0, x_cells=0):
    """Blend a coverage mask into an expected cell array, with its origin at the baseline."""
    import numpy as np
    h, w = mask.shape
    x0 = left + x_cells * _CELL_W
    y0 = _BASE + top
    for j in range(h):
        for i in range(w):
            yy, xx = y0 + j, x0 + i
            if 0 <= yy < cell.shape[0] and 0 <= xx < cell.shape[1]:
                a = mask[j, i] * alpha
                cell[yy, xx] = cell[yy, xx] + (np.array(colour, dtype=np.float64)
                                               - cell[yy, xx]) * a


def _rects(rects, colour, alpha=1.0, base=_BG_ARR):
    """An expected cell with the given (x0, x1, y0, y1) rectangles (end exclusive) in colour."""
    cell = _blank_cell(base)
    for x0, x1, y0, y1 in rects:
        for yy in range(y0, y1):
            for xx in range(x0, x1):
                cell[yy, xx] = cell[yy, xx] + (cell[yy, xx] * 0 + colour - cell[yy, xx]) * alpha
    return cell


def _max_diff(got, want):
    import numpy as np
    return float(np.abs(np.asarray(got, dtype=np.float64)
                        - np.asarray(want, dtype=np.float64)).max())


@case("render", "coverage_gamma")
def _render_coverage_gamma():
    # the coverage of a glyph is Pillow's mask raised to 0.6 (fonts.COVERAGE_GAMMA): a calibration
    # against the reference renderer, whose text is heavier than FreeType's, not a Ghostty rule. A
    # white X on the canvas background has pixels bg + (white - bg) * (raw / 255) ** 0.6
    import numpy as np
    from vkitty import fonts as _fonts
    from vkitty.render import render
    eq(_fonts.COVERAGE_GAMMA, 0.6, "the pinned gamma")
    check(abs(float(_fonts._COVERAGE_LUT[128]) - (128 / 255.0) ** 0.6) < 1e-6, "the lookup table")
    t = _kterm(20, 6)
    t.feed(b"\x1b[?25l")
    t.feed(_at(2, 1, "\x1b[38;2;255;255;255mX\x1b[0m"))
    got = _cell_pixels(render(t.snapshot()), 2, 1)
    mask, left, top, raw = _pillow_mask("regular", "X")
    want = _blank_cell()
    _put_mask(want, mask, left, top, (255, 255, 255))
    diff = _max_diff(got, want)
    check(diff <= 1.5, "the X differs from the gamma 0.6 coverage by up to %.2f" % diff)
    half = [(j, i) for j in range(raw.shape[0]) for i in range(raw.shape[1]) if 40 < raw[j, i]
            < 215]
    check(half, "the X has anti-aliased pixels (the gamma shows there)")
    j, i = half[0]
    linear = _BG_ARR[0] + (255 - _BG_ARR[0]) * int(raw[j, i]) / 255.0
    pixel = got[_BASE + top + j, left + i, 0]
    check(abs(pixel - linear) > 3, "the pixel %r would be the same at gamma 1" % pixel)


@case("render", "face_styles")
def _render_face_styles():
    # bold (SGR 1), italic (3) and both draw with the SemiBold, Italic and SemiBoldItalic faces:
    # each cell is Pillow's own mask of that face, and none equals the regular one
    import numpy as np
    from vkitty.render import render
    t = _kterm(20, 6)
    t.feed(b"\x1b[?25l")
    names = ("regular", "bold", "italic", "bold_italic")
    for k, sgr in enumerate(("0", "1", "3", "1;3")):
        t.feed(_at(3 * k, 0, "\x1b[%sm\x1b[38;2;255;255;255mX\x1b[0m" % sgr))
    img = render(t.snapshot())
    cells = []
    for k, style in enumerate(names):
        got = _cell_pixels(img, 3 * k, 0)
        mask, left, top, _raw = _pillow_mask(style, "X")
        want = _blank_cell()
        _put_mask(want, mask, left, top, (255, 255, 255))
        diff = _max_diff(got, want)
        check(diff <= 1.5, "%s X differs from Pillow's mask of that face by up to %.2f"
              % (style, diff))
        cells.append(got)
    for k in (1, 2, 3):
        check(not np.array_equal(cells[0], cells[k]), "%s looks like regular" % names[k])
    check(not np.array_equal(cells[1], cells[3]) and not np.array_equal(cells[2], cells[3]),
          "bold italic looks like bold or italic")


@case("render", "palette_colours")
def _render_palette_colours():
    # SGR 30 to 37 and 90 to 97 index the theme's 16 colours, 38;5;N the 6 x 6 x 6 cube
    # (levels 0, 95, 135, 175, 215, 255) from 16 and the grey ramp 8 + 10 * k from 232. A full block
    # in the colour, and a blank cell with it as background, show the exact value
    import numpy as np
    from vkitty.render import DEFAULT_THEME, render
    pal = DEFAULT_THEME["palette"]

    def hexrgb(text):
        return (int(text[1:3], 16), int(text[3:5], 16), int(text[5:7], 16))
    # (foreground SGR, background SGR, the colour)
    rows = [("31", "41", hexrgb(pal[1])), ("32", "42", hexrgb(pal[2])),
            ("37", "47", hexrgb(pal[7])),
            ("90", "100", hexrgb(pal[8])), ("91", "101", hexrgb(pal[9])),
            ("97", "107", hexrgb(pal[15])),
            ("38;5;1", "48;5;1", hexrgb(pal[1])), ("38;5;8", "48;5;8", hexrgb(pal[8])),
            ("38;5;16", "48;5;16", (0, 0, 0)), ("38;5;21", "48;5;21", (0, 0, 255)),
            ("38;5;100", "48;5;100", (135, 135, 0)), ("38;5;196", "48;5;196", (255, 0, 0)),
            ("38;5;231", "48;5;231", (255, 255, 255)), ("38;5;232", "48;5;232", (8, 8, 8)),
            ("38;5;240", "48;5;240", (88, 88, 88)), ("38;5;255", "48;5;255", (238, 238, 238))]
    eq(hexrgb(pal[7]), (130, 139, 184), "the theme's colour 7")
    t = _kterm(30, 6)
    t.feed(b"\x1b[?25l")
    for x, (fg_sgr, bg_sgr, _want) in enumerate(rows):
        t.feed(_at(x, 0, "\x1b[%sm\u2588\x1b[0m" % fg_sgr))
        t.feed(_at(x, 1, "\x1b[%sm \x1b[0m" % bg_sgr))
    img = render(t.snapshot())
    for x, (fg_sgr, bg_sgr, want) in enumerate(rows):
        for y, sgr, what in ((0, fg_sgr, "foreground"), (1, bg_sgr, "background")):
            px = _cell_pixels(img, x, y)
            check(np.all(px == want), "SGR %s %s: %r, want %r"
                  % (sgr, what, px[10, 5].tolist(), want))
    # the faint, inverse and the named colours are still the theme's: a default cell is the canvas
    check(np.all(_cell_pixels(img, 29, 0) == _BG_ARR), "an untouched cell is the canvas")


@case("render", "cursor_block_text")
def _render_cursor_block_text():
    # a block cursor on a letter: the cell is the cursor colour and the glyph's pixels are the
    # cursor text colour (with its coverage), whatever colour the letter had
    import numpy as np
    from vkitty.render import DEFAULT_THEME, render
    t = _kterm(20, 6)
    t.feed(_at(3, 2, "\x1b[38;2;255;0;0mX\x1b[0m") + b"\x1b[3;4H")
    got = _cell_pixels(render(t.snapshot()), 3, 2)
    mask, left, top, raw = _pillow_mask("regular", "X")
    cursor = tuple(int(DEFAULT_THEME["cursor"][k:k + 2], 16) for k in (1, 3, 5))
    text = tuple(int(DEFAULT_THEME["cursor_text"][k:k + 2], 16) for k in (1, 3, 5))
    want = _blank_cell(cursor)
    _put_mask(want, mask, left, top, text)
    diff = _max_diff(got, want)
    check(diff <= 1.5, "the cursor cell differs from cursor colour plus cursor text by up to %.2f"
          % diff)
    full = np.argwhere(raw == 255)
    check(len(full) >= 10, "the X has full coverage pixels")
    for j, i in full[:50]:
        check(tuple(got[_BASE + top + j, left + i]) == text,
              "a full pixel is not in the cursor text colour")
    check(tuple(got[0, 0]) == cursor, "the cell corner is the cursor colour")


def _block_cells(chars):
    """Render the characters in white, one per cell on row 0, and return the cells' pixels."""
    from vkitty.render import render
    t = _kterm(max(20, len(chars)), 4)
    t.feed(b"\x1b[?25l\x1b[38;2;255;255;255m")
    t.feed(_at(0, 0, chars))
    img = render(t.snapshot())
    return [_cell_pixels(img, x, 0) for x in range(len(chars))]


@case("render", "block_and_box_sprites")
def _render_block_and_box_sprites():
    # the sprites of the block elements and the box lines in a 13 x 33 cell, against rectangles
    # worked out from the cell geometry (the reference renderer): halves round up (7 of 13 columns,
    # 17 of 33 rows), quadrants share that split, shades blend at 25, 50 and 75 %, a heavy line is 4
    # px, a double line is two 2 px lines 2 px apart
    white = (255, 255, 255)
    ul, ur, ll, lr = (0, 7, 0, 17), (7, 13, 0, 17), (0, 7, 17, 33), (7, 13, 17, 33)
    cases = [
        ("\u2588", [(0, 13, 0, 33)], 1.0), ("\u258c", [(0, 7, 0, 33)], 1.0),
        ("\u2590", [(6, 13, 0, 33)], 1.0), ("\u2580", [(0, 13, 0, 17)], 1.0),
        ("\u2584", [(0, 13, 16, 33)], 1.0),
        ("\u2596", [ll], 1.0), ("\u2597", [lr], 1.0), ("\u2598", [ul], 1.0),
        ("\u2599", [ul, ll, lr], 1.0), ("\u259a", [ul, lr], 1.0), ("\u259b", [ul, ur, ll], 1.0),
        ("\u259c", [ul, ur, lr], 1.0), ("\u259d", [ur], 1.0), ("\u259e", [ur, ll], 1.0),
        ("\u259f", [ur, ll, lr], 1.0),
        ("\u2591", [(0, 13, 0, 33)], 0x40 / 255.0), ("\u2592", [(0, 13, 0, 33)], 0x80 / 255.0),
        ("\u2593", [(0, 13, 0, 33)], 0xC0 / 255.0),
        ("\u2501", [(0, 13, 14, 18)], 1.0), ("\u2503", [(4, 8, 0, 33)], 1.0),
        ("\u2550", [(0, 13, 13, 15), (0, 13, 17, 19)], 1.0),
        ("\u2551", [(3, 5, 0, 33), (7, 9, 0, 33)], 1.0),
    ]
    got = _block_cells("".join(c[0] for c in cases))
    problems = []
    for (char, rects, alpha), px in zip(cases, got):
        want = _rects(rects, white, alpha)
        diff = _max_diff(px, want)
        if diff > 1.0:
            problems.append("U+%04X differs by %.1f" % (ord(char), diff))
    check(not problems, "; ".join(problems))


@case("render", "arc_sprite")
def _render_arc_sprite():
    # a rounded corner (U+256D) is a 2 px stroke along the cell's vertical centre line from the
    # bottom edge, a quarter curve of radius 6.5 (cubic Bezier with control points a quarter of the
    # radius from the corner) and the horizontal centre line to the right edge. The oracle is a
    # distance field of that path, sampled 8 x 8 per pixel, against the renderer's supersampled
    # stroke
    import numpy as np
    cx, cy, r = 6.0, 16.0, 6.5
    p0, p1, p2, p3 = (cx, cy + r), (cx, cy + 0.25 * r), (cx + 0.25 * r, cy), (cx + r, cy)
    pts = [(cx, 33.0), (cx, cy + r)]
    for k in range(1, 401):
        u = k / 400.0
        w = 1 - u
        pts.append((w ** 3 * p0[0] + 3 * w * w * u * p1[0] + 3 * w * u * u * p2[0] + u ** 3 * p3[0],
                    w ** 3 * p0[1] + 3 * w * w * u * p1[1] + 3 * w * u * u * p2[1] + u ** 3
                    * p3[1]))
    pts.append((13.0, cy))
    dense = []
    for (ax, ay), (bx, by) in zip(pts, pts[1:]):
        n = max(2, int(max(abs(bx - ax), abs(by - ay)) * 20))
        for k in range(n + 1):
            dense.append((ax + (bx - ax) * k / n, ay + (by - ay) * k / n))
    dense = np.array(dense)
    sub = 8
    xs = (np.arange(13 * sub) + 0.5) / sub
    ys = (np.arange(33 * sub) + 0.5) / sub
    cover = np.zeros((33, 13))
    for j in range(33):
        gy = ys[j * sub:(j + 1) * sub]
        gx = xs
        dy = gy[:, None, None] - dense[None, None, :, 1]
        dx = gx[None, :, None] - dense[None, None, :, 0]
        near = ((dx * dx + dy * dy) <= 1.0).any(axis=-1)               # (sub, 13 * sub)
        cover[j] = near.reshape(sub, 13, sub).mean(axis=(0, 2))
    px = _block_cells("\u256d")[0]
    got = (px[..., 0] - _BG_ARR[0]) / (255.0 - _BG_ARR[0])
    err = np.abs(got - cover)
    # the renderer's stroke is a polygon, the oracle a distance field: they agree to 0.25 at the
    # worst pixel and 0.012 on average, where a curve with its control points 0.6 of the radius out
    # (instead of 0.25) is 0.94 and 0.035 away
    check(float(err.max()) <= 0.35, "the arc differs from the path by up to %.2f of the stroke"
          % err.max())
    check(float(err.mean()) <= 0.018, "the arc differs from the path by %.4f on average"
          % err.mean())


@case("render", "symbol_neighbours")
def _render_symbol_neighbours():
    # Ghostty's constraint width (renderer/cell.zig constraintWidth): a symbol is fitted to two
    # cells when the next cell is empty, a space (U+0020) or an EN SPACE (U+2002), else to one.
    # U+2192 is wider than a cell in the face, so its ink is wider before a blank than before a
    # letter
    import numpy as np
    from vkitty.render import render

    def ink_columns(after):
        t = _kterm(20, 4)
        t.feed(b"\x1b[?25l")
        # the neighbour is drawn in the background colour, so only the arrow's ink counts
        t.feed(_at(0, 0, "\x1b[38;2;255;255;255m\u2192\x1b[38;2;34;36;54m" + after + "\x1b[0m"))
        img = render(t.snapshot()).astype(int)
        lit = np.any(img[4:37, 4:4 + 39].sum(axis=-1) > 3 * 120, axis=0)
        cols = [i for i in range(len(lit)) if lit[i]]
        return cols[0], cols[-1], len(cols)
    space = ink_columns(" ")
    en_space = ink_columns("\u2002")
    letter = ink_columns("a")
    eq(en_space, space, "an EN SPACE neighbour counts as a space")
    check(space[2] >= 20 and space[1] <= 25, "before a space the arrow is about 2 cells wide: %r"
          % (space,))
    check(letter[2] <= 13 and letter[1] <= 12, "before a letter it stays in its cell: %r"
          % (letter,))


@case("render", "symbol_clipped")
def _render_symbol_clipped():
    # a symbol scaled into one cell is resampled with Lanczos, which rings; the mask is clipped to
    # [0, 1] so no pixel is brighter than the text colour or darker than the background
    import numpy as np
    from vkitty.render import render
    fg = (200, 211, 245)
    for symbol in ("\u2714", "\u2192", "\u263a", "\u2460", "\u27a1"):
        t = _kterm(20, 4)
        t.feed(b"\x1b[?25l")
        t.feed(_at(0, 0, "\x1b[38;2;200;211;245m" + symbol + "a\x1b[0m"))
        cell = _cell_pixels(render(t.snapshot()), 0, 0)
        for c in range(3):
            lo, hi = min(_BG_ARR[c], fg[c]), max(_BG_ARR[c], fg[c])
            check(cell[..., c].min() >= lo and cell[..., c].max() <= hi,
                  "U+%04X channel %d runs from %d to %d, outside [%d, %d]"
                  % (ord(symbol), c, cell[..., c].min(), cell[..., c].max(), lo, hi))
    # a colour glyph (an emoji) with a hard edge in its colours rings the same way when it is scaled
    # down; at half coverage each channel stays between the background * 0.5 (colour 0) and
    # background * 0.5 + 127.5 (colour 255), where a colour past 255 would go higher
    from vkitty import fonts as _fonts
    from vkitty import render as R
    rgb = np.zeros((33, 40, 3), dtype=np.float32)
    rgb[:, 20:] = 255.0
    fake = _fonts.Glyph(np.full((33, 40), 0.5, dtype=np.float32), -20, -26, rgb)
    frame = R._Frame(_kterm(20, 6).snapshot(), R.DEFAULT_THEME, [])
    X, Y = _cell_origin(3, 2)
    _with_glyph(lambda face, text: fake,
                lambda: R._symbol_glyph(frame, None, "X", X, Y, 1, R._vec(_FG), 1.0))
    band = frame.canvas[Y:Y + 33, X:X + 13]
    for c in range(3):
        lo, hi = _BG_ARR[c] * 0.5, _BG_ARR[c] * 0.5 + 127.5
        check(float(band[..., c].min()) >= lo - 0.5 and float(band[..., c].max()) <= hi + 0.5,
              "a scaled colour glyph rings in channel %d: %.1f to %.1f, allowed %.1f to %.1f"
              % (c, band[..., c].min(), band[..., c].max(), lo, hi))


@case("render", "symbol_centred")
def _render_symbol_centred():
    # a symbol taller than the face is scaled about its own centre and placed there: an ink box 10
    # wide and 60 tall with its left edge at 4 shrinks by 33 / 60 to 5.5 wide and sits at
    # 4 + 5 - 2.75 = 6.25, so its first column is the cell's column 6 (not 4, where it would start
    # if it kept its left edge)
    import numpy as np
    from vkitty import fonts as _fonts
    from vkitty import render as R
    t = _kterm(20, 6)
    frame = R._Frame(t.snapshot(), R.DEFAULT_THEME, [])
    fake = _fonts.Glyph(np.ones((60, 10), dtype=np.float32), 4, -50, None)
    X, Y = _cell_origin(3, 2)
    _with_glyph(lambda face, text: fake,
                lambda: R._symbol_glyph(frame, None, "X", X, Y, 1, R._vec(_FG), 1.0))
    band = frame.canvas[Y:Y + 33, X:X + 13]
    lit = np.any(band.sum(axis=-1) > 3 * 60, axis=0)
    cols = [i for i in range(13) if lit[i]]
    eq(cols[0], 6, "the first ink column of the centred glyph")


@case("render", "ligature_runs")
def _render_ligature_runs():
    # a run is broken between f and l (and f and i, s and t) so no ligature forms: "fl" is the mask
    # of f in cell 0 and the mask of l in cell 1, and the glyph pass hands the two letters to the
    # shaper as two runs (the bundled face has no such ligature, so the pixels alone cannot tell the
    # two apart; the runs can). Other pairs stay one run
    from vkitty import render as R
    t = _kterm(20, 6)
    t.feed(b"\x1b[?25l")
    for row, word in enumerate(("fl", "fi", "st", "fa", "ab")):
        t.feed(_at(0, row, "\x1b[38;2;255;255;255m" + word + "\x1b[0m"))
    runs = []
    real = R._flush_run

    def spy(frame, run, y):
        text = "".join(run[1])
        if text.strip():
            runs.append((y, text))
        return real(frame, run, y)
    R._flush_run = spy
    try:
        img = R.render(t.snapshot())
    finally:
        R._flush_run = real
    eq(runs, [(0, "f"), (0, "l"), (1, "f"), (1, "i"), (2, "s"), (2, "t"), (3, "fa"), (4, "ab")],
       "the runs of each word")
    got = _cell_pixels(img, 0, 0, cells=2)
    want = _blank_cell(cells=2)
    for k, ch in enumerate("fl"):
        mask, left, top, _raw = _pillow_mask("regular", ch)
        _put_mask(want, mask, left, top, (255, 255, 255), x_cells=k)
    diff = _max_diff(got, want)
    check(diff <= 1.5, "fl differs from f and l drawn one per cell by up to %.2f" % diff)


@case("render", "decoration_order")
def _render_decoration_order():
    # underlines are drawn before the glyphs and strikethroughs after them. A colour glyph (the
    # emoji kind, faked here to fill its cell) shows over an underline and under a strikethrough; a
    # real g with an underline in its own colour (SGR 58) shows its ink over that underline
    import numpy as np
    from vkitty import fonts as _fonts
    from vkitty.render import render
    fake = _fonts.Glyph(np.ones((33, 13), dtype=np.float32), 0, -26,
                        np.full((33, 13, 3), (10.0, 200.0, 30.0), dtype=np.float32))
    t = _kterm(20, 4)
    t.feed(b"\x1b[?25l")
    t.feed(_at(0, 0, "\x1b[9mX\x1b[0m") + _at(1, 0, "\x1b[4mX\x1b[0m"))
    img = _with_glyph(lambda face, text: fake, lambda: render(t.snapshot()))
    strike = _cell_pixels(img, 0, 0)
    for r in range(33):
        want = _FG if r in (19, 20) else (10, 200, 30)
        check(tuple(strike[r, 6]) == want, "strike cell row %d is %r, want %r"
              % (r, tuple(strike[r, 6]), want))
    under = _cell_pixels(img, 1, 0)
    for r in range(33):
        check(tuple(under[r, 6]) == (10, 200, 30),
              "underline cell row %d is %r: the glyph is under the underline"
              % (r, tuple(under[r, 6])))
    # a real g: underline rows 27 and 28 in green, the g's full coverage ink over them in white
    t = _kterm(20, 4)
    t.feed(b"\x1b[?25l")
    t.feed(_at(0, 0, "\x1b[4;38;2;255;255;255;58;2;0;255;0mg\x1b[0m"))
    got = _cell_pixels(render(t.snapshot()), 0, 0)
    mask, left, top, raw = _pillow_mask("regular", "g")
    ink = 0
    free = 0
    for r in (27, 28):
        for c in range(13):
            j, i = r - _BASE - top, c - left
            inside = 0 <= j < raw.shape[0] and 0 <= i < raw.shape[1]
            cov = int(raw[j, i]) if inside else 0
            if cov == 255:
                ink += 1
                check(tuple(got[r, c]) == (255, 255, 255), "g ink at row %d column %d is %r"
                      % (r, c, tuple(got[r, c])))
            elif cov == 0:
                free += 1
                check(tuple(got[r, c]) == (0, 255, 0), "underline at row %d column %d is %r"
                      % (r, c, tuple(got[r, c])))
    check(ink >= 2 and free >= 6, "the g crosses the underline (%d ink, %d free pixels)"
          % (ink, free))


@case("render", "decoration_details")
def _render_decoration_details():
    # an underline takes its own colour (SGR 58) and not the text's; an underline on a wide
    # character spans both its cells; a faint letter's ink is half alpha (theme faint 0.5)
    import numpy as np
    from vkitty.render import render
    t = _kterm(20, 4)
    t.feed(b"\x1b[?25l")
    t.feed(_at(0, 0, "\x1b[4;58;2;255;0;0m \x1b[0m"))
    t.feed(_at(1, 0, "\x1b[4;38;2;255;255;255m\u4e16\x1b[0m"))
    t.feed(_at(4, 0, "\x1b[2;38;2;255;255;255mX\x1b[0m"))
    img = render(t.snapshot())
    ul = _cell_pixels(img, 0, 0)
    check(np.all(ul[27:29] == (255, 0, 0)) and np.all(ul[0:27] == _BG_ARR),
          "the underline is in the SGR 58 colour on rows 27 and 28")
    wide = _cell_pixels(img, 1, 0, cells=2)
    check(np.all(wide[27:29, :] == (255, 255, 255)),
          "the underline spans both cells of a wide character")
    faint = _cell_pixels(img, 4, 0)
    mask, left, top, raw = _pillow_mask("regular", "X")
    want = _blank_cell()
    _put_mask(want, mask, left, top, (255, 255, 255), alpha=0.5)
    diff = _max_diff(faint, want)
    check(diff <= 1.5, "the faint X differs from half alpha ink by up to %.2f" % diff)
    j, i = np.argwhere(raw == 255)[0]
    half = tuple(int(round((_BG_ARR[c] + 255) / 2.0)) for c in range(3))
    got = tuple(faint[_BASE + top + j, left + i])
    check(max(abs(got[c] - half[c]) for c in range(3)) <= 1, "a full pixel of the faint X is %r"
          % (got,))


@case("render", "cursor_block_decorations")
def _render_cursor_block_decorations():
    # a block cursor is painted before the decorations and the glyph of its cell (Ghostty's text
    # pass puts the block cursor first), and they are drawn in the cursor text colour: under a block
    # cursor an underlined g keeps its underline rows 27 and 28, an overline keeps rows 0 and 1, a
    # strikethrough keeps rows 19 and 20
    import numpy as np
    from vkitty.render import DEFAULT_THEME, render
    text = tuple(int(DEFAULT_THEME["cursor_text"][k:k + 2], 16) for k in (1, 3, 5))
    cursor = tuple(int(DEFAULT_THEME["cursor"][k:k + 2], 16) for k in (1, 3, 5))
    for sgr, rows, name in (("4", (27, 28), "underline"), ("53", (0, 1), "overline"),
                            ("9", (19, 20), "strikethrough")):
        t = _kterm(20, 6)
        t.feed(_at(2, 1, "\x1b[%smg\x1b[0m" % sgr) + b"\x1b[2;3H")
        got = _cell_pixels(render(t.snapshot()), 2, 1)
        for r in rows:
            check(np.all(got[r] == text),
                  "%s: row %d is %r in the cursor cell, not the cursor text colour"
                  % (name, r, tuple(got[r, 0])))
        other = [r for r in range(33) if r not in rows and np.all(got[r] == cursor)]
        check(len(other) >= 10, "%s: the rest of the cell is the cursor colour" % name)


@case("render", "bitmap_strike_face")
def _render_bitmap_strike_face():
    """A color bitmap font (Noto Color Emoji, CBDT) has one strike size, and Pillow refuses any
    other ("invalid pixel size"): the face then loads at the strike (109 px) and its glyphs are
    scaled to the cell size (26 px). Pillow's font is replaced by a stub that refuses 26 and draws a
    136 x 128 red glyph at the strike, because no such font exists on every host."""
    from PIL import Image, ImageFont
    from vkitty import fonts

    class Stub:
        def getmask2(self, text, mode, embedded_color, anchor):
            return Image.new("RGBA", (136, 128), (255, 0, 0, 255)).im, (5, -100)
    sizes = []

    def truetype(path, size, **_kw):
        sizes.append(size)
        if size != fonts.BITMAP_STRIKE:
            raise OSError("invalid pixel size")
        return Stub()
    real = ImageFont.truetype
    ImageFont.truetype = truetype
    try:
        face = fonts.Face("/nonexistent/NotoColorEmoji.ttf", 0, True)
        got = face.mask("x")
        try:
            fonts.Face("/nonexistent/NotoSansMono.ttf", 0, False)
        except OSError:
            pass
        else:
            raise AssertionError("a face that is not a color font swallowed the error")
    finally:
        ImageFont.truetype = real
    eq(sizes[:2], [fonts.PX, fonts.BITMAP_STRIKE], "the face asked for 26 px, then the strike")
    eq((face.scale == fonts.PX / fonts.BITMAP_STRIKE, got.alpha.shape), (True, (31, 32)),
       "the glyph is scaled to 26/109")
    eq((got.ox, got.oy), (1, -24), "and so is its origin")
    check(float(got.alpha.min()) == 1.0 and tuple(got.rgb[0, 0]) == (255.0, 0.0, 0.0),
          "the scaled glyph keeps its color and alpha")


@case("render", "cursor_block_wide")
def _render_cursor_block_wide():
    # Ghostty's addCursor moves a block cursor on a wide character to its head and draws it two
    # cells wide: on the head or on the tail it covers 26 px, and the glyph is drawn in the cursor
    # text
    import numpy as np
    from vkitty.render import DEFAULT_THEME, render
    text = tuple(int(DEFAULT_THEME["cursor_text"][k:k + 2], 16) for k in (1, 3, 5))
    cursor = tuple(int(DEFAULT_THEME["cursor"][k:k + 2], 16) for k in (1, 3, 5))
    _need_fallback_face(0x4E16)
    for column in (3, 4):
        t = _kterm(20, 6)
        t.feed(_at(3, 1, "\u4e16") + _at(column, 1, ""))
        got = _cell_pixels(render(t.snapshot()), 3, 1, cells=2)
        check(tuple(got[0, 0]) == cursor and tuple(got[0, 25]) == cursor,
              "cursor at column %d: the top row of the two cells is not the cursor colour" % column)
        check(int(np.all(got == cursor, axis=-1).sum()) > 26 * 33 // 2,
              "cursor at column %d: the two cells are mostly the cursor colour" % column)
        check(bool(np.any(np.all(got == text, axis=-1))),
              "cursor at column %d: no glyph pixel in the text colour"
              % column)
        outside = _cell_pixels(render(t.snapshot()), 5, 1)
        check(np.all(outside == _BG_ARR), "the cell after the wide character is untouched")


@case("render", "save_png_roundtrip")
def _render_save_png_roundtrip():
    # render.save_png writes the canvas with Pillow: read back, it is the same pixels, and the name
    # is exported by the package (lazily, so importing vkitty stays cheap)
    import numpy as np
    from PIL import Image
    t = _kterm(10, 3)
    t.feed(b"\x1b[?25l")
    t.feed(_at(1, 1, "\x1b[38;2;255;120;10mX\x1b[0m"))
    from vkitty import render as R
    pixels = R.render(t.snapshot())
    tmp = _spec_tempdir()
    try:
        path = os.path.join(tmp, "canvas.png")
        R.save_png(pixels, path)
        back = np.asarray(Image.open(path).convert("RGB"))
        check(np.array_equal(back, pixels), "the PNG read back differs from the canvas")
        import vkitty
        from vkitty import save_png
        check(save_png is R.save_png and "save_png" in vkitty.__all__, "save_png is exported")
    finally:
        _drop_spec_dir(tmp)


@case("render", "subset_source_label")
def _render_subset_source_label():
    # SOURCE.txt names the folder the source fonts were read from: the default folder as
    # ~/Library/Fonts, a folder under the home folder with ~, any other folder as an absolute path
    import importlib.util
    path = os.path.join(VK_DIR, "tools", "subset_fonts.py")
    spec = importlib.util.spec_from_file_location("vkitty_subset_fonts", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    home = os.path.expanduser("~")
    eq(module.source_label(os.path.expanduser("~/Library/Fonts")), "~/Library/Fonts",
       "the default folder")
    eq(module.source_label("~/Library/Fonts"), "~/Library/Fonts", "a folder written with ~")
    eq(module.source_label(os.path.join(home, "fonts", "iosevka")), "~/fonts/iosevka",
       "a folder under home")
    eq(module.source_label(home), "~", "the home folder itself")
    other = os.path.join(os.sep, "opt", "fonts")
    eq(module.source_label(other), other, "a folder outside home")
    check(module.source_label(home + "x") == os.path.abspath(home + "x"),
          "a folder that only starts with the home path is not under it")


@case("render", "layer_boundary")
def _render_layer_boundary():
    # an image at z = INT32_MIN / 2 exactly is between the cell backgrounds and the text, so it
    # shows over a cell background; one step lower sits under the backgrounds and is hidden by it
    import numpy as np
    from vkitty.render import render
    t = _kterm(20, 4)
    t.feed(b"\x1b[?25l")
    t.feed(_at(0, 0, "\x1b[48;2;10;200;10m \x1b[0m") + _at(1, 0, "\x1b[48;2;10;200;10m \x1b[0m"))
    t.feed(_apc(b"a=t,f=32,s=13,v=33,i=21;" + _b64(_solid(13, 33, b"\xff\x00\xff\xff"))))
    t.feed(b"\x1b[1;1H" + _apc(b"a=p,i=21,C=1,z=-1073741824"))
    t.feed(b"\x1b[1;2H" + _apc(b"a=p,i=21,p=2,C=1,z=-1073741825"))
    img = render(t.snapshot())
    check(np.all(_cell_pixels(img, 0, 0) == (255, 0, 255)), "z = -2^30 shows over the background")
    check(np.all(_cell_pixels(img, 1, 0) == (10, 200, 10)), "z = -2^30 - 1 is under the background")



@case("perf", "render")
def _perf_render():
    # the performance budget: a 160 x 50 screen at 2x with two 624 x 528 images renders in <= 300 ms
    # warm and <= 1 s cold (the cold figure includes loading the fonts); the test asserts twice each
    # budget
    from vkitty import perfclock as pc
    from vkitty.render import drop_caches, render
    rnd = random.Random(3)
    parts = ["\x1b[?25l"]
    for y in range(50):
        parts.append("\x1b[%d;1H" % (y + 1))
        for x0 in range(0, 160, 16):
            parts.append("\x1b[38;2;%d;%d;%dm" % (rnd.randrange(256), rnd.randrange(256),
                                                 rnd.randrange(256)))
            parts.append("".join(rnd.choice("abcdefgh ijk()[]{}=+-_") for _ in range(16)))
    t = _kterm(160, 50)
    t.feed("".join(parts).encode("utf-8"))
    for image_id, (x, y) in ((1, (10, 5)), (2, (80, 20))):
        t.feed(_apc(b"a=t,f=32,s=624,v=528,i=%d;" % image_id
                    + _b64(_rgba_random(624, 528, image_id))))
        t.feed(b"\x1b[%d;%dH" % (y + 1, x + 1) + _apc(b"a=p,i=%d,C=1,c=48,r=16" % image_id))
    snap = t.snapshot()
    eq(len(snap.draws), 2, "the two image draws")

    def measure_cold():
        drop_caches()
        _, sample = pc.timed(render, snap)
        return sample.wall, sample.clean
    cold_verdict, _made = pc.retry(measure_cold, 2.0)
    # warm: three renders always; when none is within the limit and none is clean, up to three more
    # (stopping at the first that is), and the verdict is over every render made
    tries = []
    for _ in range(6):
        _, sample = pc.timed(render, snap)
        tries.append((sample.wall, sample.clean))
        if len(tries) >= 3 and any(wall <= 0.6 or clean for wall, clean in tries):
            break
    warm_verdict = pc.tries_verdict(tries, 0.6)
    warm_note = _perf_limit("perf/render", warm_verdict, "warm (best of %d)" % len(tries), _ms,
                            "600 ms")
    cold_note = _perf_limit("perf/render", cold_verdict, "cold", _ms, "2000 ms")
    return "%s; %s" % (warm_note, cold_note)


# ------------------------------------------------ relay, recording and replay ---
# The live recorder (relay.py: a pty relay between a child and the terminal it runs in), the
# recording it writes (recording.py) and the replay CLI (replay.py). The child is testchild.py, a
# scripted program. Every case runs the relay headless (stdin is /dev/null, so it never enters tty
# mode) and reads the recording back: the bytes it holds, the answers the child got, the files and
# shared memory objects the relay read and removed, and what is left behind (FIFOs, files, shared
# memory objects and processes).

VK_DIR = os.path.join(LIB, "vkitty")
RELAY_PY = os.path.join(VK_DIR, "relay.py")
LIVE_PY = os.path.join(VK_DIR, "live.py")
TESTCHILD_PY = os.path.join(VK_DIR, "testchild.py")
REPLAY_PY = os.path.join(VK_DIR, "replay.py")
_RELAY_RUNS = [0]


def _json_write(path, value):
    import json
    with open(path, "w", encoding="ascii") as fh:
        json.dump(value, fh)


def _json_read(path):
    import json
    with open(path, encoding="ascii") as fh:
        return json.load(fh)


def _normal(value):
    """The JSON form of a value (tuples become lists), for comparing reports with files."""
    import json
    return json.loads(json.dumps(value))


def _report_form(report):
    """A report as the comparisons see it: its JSON form, without the images' seq. seq is a version
    stamp from a counter that every terminal of a process shares, so two terminals (the live one in
    the relay and the replay here, or two replays) never agree on it; the pixels are compared by
    their sha256 and the rest of the report as it is."""
    out = _normal(report)
    for image in out.get("images", []):
        image.pop("seq", None)
    return out


def _wait_for(pred, what, timeout=15.0, run=None, cap=900.0, clock=time.monotonic,
              nap=time.sleep):
    """Wait until pred() holds. Without `run` the bound is the clock: `timeout` seconds. With the
    relay run `run` the bound is progress (_wait_progress with _run_progress): the wait fails when
    nothing of the run moved for `timeout` seconds, or after `cap` seconds in all, so a host that
    is slow but serves the run is waited for."""
    if run is None:
        deadline = time.monotonic() + timeout
        while not pred():
            if time.monotonic() > deadline:
                raise AssertionError("timed out waiting for %s" % what)
            time.sleep(0.02)
        return
    if not _wait_progress(pred, lambda: _run_progress(run), timeout, cap, clock=clock, nap=nap):
        raise AssertionError("timed out waiting for %s (the run made no progress for %g s, or "
                             "%g s passed)" % (what, timeout, cap))


def _run_progress(run):
    """What moves while a relay run is served: the bytes of its recording folder and the CPU time
    of the relay, of its child and of its live worker, in steps of 0.1 s (a creep of a starved
    process does not count). The pids are looked up as they appear in the recording."""
    from vkitty import perfclock
    size = 0
    try:
        for entry in os.scandir(run["rec"]):
            if entry.is_file(follow_symlinks=False):
                size += entry.stat(follow_symlinks=False).st_size
    except OSError:
        pass
    pids = run.setdefault("progress_pids", {})
    proc = run.get("proc")
    if proc is not None:
        pids["relay"] = proc.pid
    for name, find in (("child", _child_pid_head), ("worker", _live_pid)):
        if name not in pids:
            found = find(run)
            if found is not None:
                pids[name] = found
    steps = []
    for name in sorted(pids):
        counters = perfclock.proc_counters(pids[name])
        steps.append(None if counters is None else int(counters[0] * 10))
    return size, tuple(steps)


def _wait_progress(done, progress, stall, cap, clock=time.monotonic, nap=time.sleep):
    """Wait until done() holds and return True. Progress and not the clock sets the bound: the wait
    gives up (returns False) when progress() has not changed for `stall` seconds (a reader that
    blocks stops writing, a starved process uses no CPU) or after `cap` seconds in all, so a slow
    host that keeps things moving is waited for. clock and nap are replaceable for a virtual
    clock."""
    start = clock()
    changed = start
    last = progress()
    while not done():
        now = clock()
        if now - changed >= stall or now - start >= cap:
            return False
        nap(0.05)
        value = progress()
        if value != last:
            last = value
            changed = clock()
    return True


def _wait_recorded(read, data, stall=8.0, cap=120.0, clock=time.monotonic, nap=time.sleep):
    """Poll read() until what it returns ends with data, and return the last thing read; the wait
    ends early when the size has not changed for `stall` seconds or after `cap` seconds
    (_wait_progress with the size as the progress)."""
    seen = [b""]

    def size():
        seen[0] = read()
        return len(seen[0])

    _wait_progress(lambda: seen[0].endswith(data), size, stall, cap, clock=clock, nap=nap)
    return seen[0]


def _read_bytes(path):
    try:
        with open(path, "rb") as fh:
            return fh.read()
    except OSError:
        return b""


def _read_text(path):
    return _read_bytes(path).decode("utf-8", "replace")


def _relay_env(tmp, tmux=None):
    env = dict(os.environ)
    env["TMPDIR"] = tmp
    env.pop("TMUX", None)
    if tmux is not None:
        env["TMUX"] = tmux
    return env


def _relay_run_paths(tmp):
    _RELAY_RUNS[0] += 1
    base = os.path.join(tmp, "run%d" % _RELAY_RUNS[0])
    os.mkdir(base)
    return {"base": base, "rec": os.path.join(base, "rec"),
            "script": os.path.join(base, "child.json"),
            "result_path": os.path.join(base, "result.json"),
            "ctl": os.path.join(base, "ctl"), "gfx": os.path.join(base, "gfx"),
            "out": os.path.join(base, "relay.out")}


def _relay_argv(run, extra):
    argv = [sys.executable, "-I", RELAY_PY, "--rec", run["rec"], "--size", "80x24"]
    argv += list(extra)
    return argv + ["--", sys.executable, "-I", TESTCHILD_PY, run["script"], run["result_path"]]


def _child_pid_from_rec(run):
    """The pid the scripted child printed (print_pid), read from its recording; None if absent."""
    import re
    found = re.search(rb"PID (\d+)", _read_bytes(os.path.join(run["rec"], "tui.bin")))
    return int(found.group(1)) if found else None


def _event_lines(run):
    """The events of a run's recording, read from events.jsonl itself (not through Recording, so a
    run whose tui.bin was removed still has its events)."""
    import json
    with open(os.path.join(run["rec"], "events.jsonl"), encoding="ascii") as fh:
        return [json.loads(line) for line in fh if line.strip()]


def _live_pid(run):
    """The pid of the live terminal's worker, from the start event (written at once, before the
    child runs). None when the run has no live terminal (no --respond ghostty) or the start event is
    not complete yet."""
    import json
    try:
        with open(os.path.join(run["rec"], "events.jsonl"), encoding="ascii") as fh:
            first = fh.readline()
        return json.loads(first).get("live_pid") if first.strip() else None
    except (OSError, ValueError):
        return None


def _gone_or_fail(pid, what):
    """The process pid (the child or the live terminal of a finished run) no longer exists."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return
    raise AssertionError("%s (pid %d) still exists after the relay exited" % (what, pid))


def _pid_gone(pid):
    """The process no longer exists, or is a zombie nobody has reaped yet: its parent was killed
    and the process that adopted it (a container's PID 1, which is not an init) never waits."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    return _proc_state(pid).startswith("Z")


def _child_gone(run):
    """The child of the run no longer exists (the relay reaped it), and neither does the live
    terminal's worker (its pid is in the start event). The child's pid is the one its result file
    names; a child that died of a signal wrote no result, so its printed pid is used then."""
    pid = run["res"].get("pid") if run.get("res") else _child_pid_from_rec(run)
    if pid is not None:
        _gone_or_fail(pid, "the child")
    live = _live_pid(run)
    if live is not None:
        _gone_or_fail(live, "the live terminal")


def _relay_once(tmp, steps, extra=(), tmux=None, timeout=60):
    """One headless relay run with the scripted child. Returns the run's paths, the relay's exit
    status (rc), its stderr (err) and the child's result (res, None when it wrote none). The
    child must be gone afterwards."""
    import subprocess
    run = _relay_run_paths(tmp)
    _json_write(run["script"], steps)
    proc = subprocess.run(_relay_argv(run, ["--no-forward"] + list(extra)),
                          env=_relay_env(tmp, tmux), stdin=subprocess.DEVNULL,
                          capture_output=True, timeout=timeout)
    run["rc"] = proc.returncode
    run["err"] = proc.stderr.decode("utf-8", "replace")
    run["res"] = _json_read(run["result_path"]) if os.path.exists(run["result_path"]) else None
    _child_gone(run)
    return run


def _relay_start(tmp, steps, extra=(), tmux=None, gfx=False):
    """A relay run in the background (Popen). Its output goes to run["out"]; the caller ends it
    with _relay_end, and _relay_stop cleans up after an exception. gfx adds --gfx-fifo
    run["gfx"]."""
    import subprocess
    run = _relay_run_paths(tmp)
    _json_write(run["script"], steps)
    flags = ["--no-forward", "--ctl", run["ctl"]] + list(extra)
    if gfx:
        flags += ["--gfx-fifo", run["gfx"]]
    out = open(run["out"], "wb")
    try:
        run["proc"] = subprocess.Popen(_relay_argv(run, flags), env=_relay_env(tmp, tmux),
                                       stdin=subprocess.DEVNULL, stdout=out,
                                       stderr=subprocess.STDOUT)
    finally:
        out.close()
    return run


def _relay_end(run, timeout=30):
    """Wait for a background relay to exit, then fill rc, err and res as _relay_once does, and
    check that its child is gone. The wait is bounded by progress, not by the clock: a relay that
    made none (the bytes of its recording, the CPU of its processes) for `timeout` seconds, or
    that did not exit in 20 times that, is terminated and killed, and so is its child (by the pid
    the child printed); the case then fails."""
    import subprocess
    proc = run["proc"]
    cap = max(20 * timeout, 600)
    if not _wait_progress(lambda: proc.poll() is not None, lambda: _run_progress(run), timeout,
                          cap):
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
        _kill_child_by_pid(run)
        raise AssertionError("the relay did not exit: no progress for %g s, or %g s passed"
                             % (timeout, cap))
    run["rc"] = proc.returncode
    run["err"] = _read_text(run["out"])
    run["res"] = _json_read(run["result_path"]) if os.path.exists(run["result_path"]) else None
    _child_gone(run)
    return run


def _kill_child_by_pid(run):
    """A child still alive after its relay was stopped is killed, by the pid it printed; so is the
    live terminal's worker, by the pid of the start event. A pid that is already gone is left
    alone (no signal goes to a pid that may be free)."""
    for pid in (_child_pid_from_rec(run), _live_pid(run)):
        if pid is None or _pid_gone(pid):
            continue
        try:
            os.kill(pid, 9)
        except ProcessLookupError:
            pass


def _relay_stop(run):
    """Cleanup for a background relay that is still running (an exception before _relay_end)."""
    import subprocess
    proc = run.get("proc")
    if proc is not None and proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
        _kill_child_by_pid(run)


def _child_pid_head(run):
    """The pid the scripted child printed as its first output (print_pid as its first step), read
    from the first bytes of its recording, so a recording of 20 MB is not read to find it. None
    until the line is there."""
    import re
    try:
        with open(os.path.join(run["rec"], "tui.bin"), "rb") as fh:
            head = fh.read(256)
    except OSError:
        return None
    found = re.match(rb"PID (\d+)\r\n", head)
    return int(found.group(1)) if found else None


def _relay_end_followed(run, sampler, timeout, worker):
    """_relay_end for a background relay that a perfclock.ProcSampler follows: the relay's pid is
    added at once, its child's (print_pid as its first step) and, with worker, the live terminal's
    as soon as the recording names them. A pid the run outlives before the recording names it is
    simply not followed."""
    deadline = time.monotonic() + timeout
    sampler.add(run["proc"].pid)
    pending = [_child_pid_head] + ([_live_pid] if worker else [])
    while run["proc"].poll() is None and time.monotonic() < deadline:
        for find in list(pending):
            pid = find(run)
            if pid is not None:
                sampler.add(pid)
                pending.remove(find)
        time.sleep(0.005)
    return _relay_end(run, timeout=max(1.0, deadline - time.monotonic()))


def _relay_run_followed(tmp, steps, respond):
    """One relay run of the timed cases (perf/relay, perf/relay_answer), from before the relay
    starts to after it exited, followed by a perfclock.ProcSampler: the relay, its child and, with
    a live terminal (--respond ghostty), its worker. Returns (the run, the sampler, the seconds the
    run took, measured inside the sampler's span). The caller checks the run's exit status."""
    from vkitty import perfclock as pc
    with pc.ProcSampler() as sampler:
        t0 = time.perf_counter()
        run = _relay_start(tmp, steps, ["--hop", "none", "--respond", respond])
        try:
            _relay_end_followed(run, sampler, 120, respond == "ghostty")
        finally:
            _relay_stop(run)
        elapsed = time.perf_counter() - t0
    return run, sampler, elapsed


def _fifo_write(path, data, timeout=10.0):
    """Write bytes to a FIFO the relay reads: open it without blocking (the relay holds the reader
    open once it is up), write, close. Retries while the relay has not created or opened it."""
    import errno
    deadline = time.monotonic() + timeout
    while True:
        try:
            fd = os.open(path, os.O_WRONLY | os.O_NONBLOCK)
            break
        except OSError as exc:
            if exc.errno not in (errno.ENXIO, errno.ENOENT) or time.monotonic() > deadline:
                raise AssertionError("cannot open %s for writing: %s" % (path, exc))
            time.sleep(0.01)
    try:
        view = memoryview(data)
        while view:
            view = view[os.write(fd, view):]
    finally:
        os.close(fd)


def _remove_ack(run):
    """Remove the ack of an earlier mark before the next one is sent (a repeated name would
    otherwise look acknowledged at once)."""
    try:
        os.unlink(run["ctl"] + ".ack")
    except FileNotFoundError:
        pass


def _mark(run, name):
    """A mark through the ctl FIFO, acknowledged when the relay has drained and recorded it."""
    _remove_ack(run)
    _fifo_write(run["ctl"], ("mark %s\n" % name).encode("ascii"))
    _wait_for(lambda: _read_text(run["ctl"] + ".ack") == name, "the ack of mark " + name, run=run)


def _proc_state(pid):
    """The ps state letter(s) of a process ("T" when stopped); empty when it does not exist."""
    import subprocess
    return subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True,
                          text=True).stdout.strip()


# seconds a stopped relay is left parked: several of its 50 ms select timeouts, so that its select
# has returned with nothing ready before the output and the mark are queued
_PARKED_WAIT = 0.2


def _recording(run):
    from vkitty.recording import Recording
    return Recording.load(run["rec"])


def _stream_steps(stream):
    """Child steps that write one byte stream and let the relay read it."""
    return [{"write_b64": _b64(stream).decode("ascii")}, {"sleep": 0.1}]


def _check_live_equal(run):
    """The replayed final report equals the live terminal's report (live_final.json)."""
    from vkitty.snapshot import to_report
    got = _report_form(to_report(_recording(run).snapshot()))
    live = _report_form(_json_read(os.path.join(run["rec"], "live_final.json")))
    eq(got, live, "the replayed report differs from the live report")


def _record_stream():
    """A session for the record and replay case: text with styles, a direct PNG, a chunked zlib
    RGBA image, placeholders of that image, and a delete."""
    import io
    import zlib
    from PIL import Image
    buf = io.BytesIO()
    Image.new("RGBA", (4, 3), (200, 30, 40, 255)).save(buf, "PNG")
    raw = bytes(range(16))
    b64 = _b64(zlib.compress(raw))
    cut = (len(b64) // 2) // 4 * 4
    text = (b"hello world\r\n\x1b[1mBOLD\x1b[0m plain\r\n")
    return (text
            + _apc(b"a=t,f=100,i=71;" + _b64(buf.getvalue()))
            + _apc(b"a=t,f=32,o=z,s=2,v=2,i=72,m=1;" + b64[:cut])
            + _apc(b"m=0;" + b64[cut:])
            + _apc(b"a=p,i=72,U=1,c=2,r=2")
            + _at(2, 5, _fg_rgb(72) + _ph(0, 0) + _ph(0, 1))
            + _at(2, 6, _fg_rgb(72) + _ph(1, 0) + _ph(1, 1))
            + _apc(b"a=d,d=i,i=71")
            + b"tail\r\n")


@case("relay", "hop_auto")
def _relay_hop_auto():
    # --hop auto is tmux when TMUX is set in the relay's environment, else none. Under tmux a raw
    # APC never reaches the terminal (tmux takes it for the pane title), so the temporary file it
    # names stays in place and no blob is recorded. Under none the same APC loads the file.
    tmp = _spec_tempdir()
    try:
        under_tmux = _spec_path(tmp, "tty-graphics-protocol-auto-tmux.rgba", bytes(range(16)))
        under_none = _spec_path(tmp, "tty-graphics-protocol-auto-none.rgba", bytes(range(16)))
        run_t = _relay_once(tmp, _stream_steps(_apc(b"a=t,t=t,f=32,s=2,v=2,i=61;"
                                                    + _b64(under_tmux))),
                            ["--hop", "auto", "--respond", "none"], tmux="/dummy,1,0")
        from vkitty.vt import HOP_TMUX
        eq(_recording(run_t).meta["hop"], HOP_TMUX, "TMUX set: the start event says tmux")
        check(os.path.exists(under_tmux), "under tmux the raw APC leaves its file in place")
        eq(_recording(run_t).blobs, {}, "under tmux no blob is recorded")
        run_n = _relay_once(tmp, _stream_steps(_apc(b"a=t,t=t,f=32,s=2,v=2,i=62;"
                                                    + _b64(under_none))),
                            ["--hop", "auto", "--respond", "none"], tmux=None)
        eq(_recording(run_n).meta["hop"], "none", "TMUX unset: the start event says none")
        check(not os.path.exists(under_none), "under none the raw APC loads and removes its file")
        eq(len(_recording(run_n).blobs), 1, "under none the blob is recorded")
    finally:
        _drop_spec_dir(tmp)


def _default_profile():
    from vkitty import kgp
    return kgp.DEFAULT_PROFILE


_DEFAULT_PROFILE = _default_profile()   # of the relay and the replay tool (Ghostty 1.4.0)


@case("relay", "record_replay_equal")
def _relay_record_replay_equal():
    # the recording replayed offline equals the live terminal's final report, and equals an
    # in-process terminal fed the same bytes (the images' seq stamp is left out, see _report_form)
    from vkitty.snapshot import to_report
    from vkitty.vt import Terminal
    tmp = _spec_tempdir()
    try:
        stream = _record_stream()
        run = _relay_once(tmp, _stream_steps(stream), ["--hop", "none", "--respond", "ghostty"])
        eq(run["rc"], 0, "relay exit status (stderr: %s)" % run["err"][-400:])
        _check_live_equal(run)
        got = _report_form(to_report(_recording(run).snapshot()))
        plain = Terminal(80, 24, hop="none", profile=_DEFAULT_PROFILE)
        plain.feed(stream)
        eq(got, _report_form(to_report(plain.snapshot())), "the in-process terminal differs")
        check(got["virtual"], "the session holds placeholders")
        eq(_recording(run).blobs, {}, "no file or shared memory object: no blob")
    finally:
        _drop_spec_dir(tmp)


@case("relay", "temp_unlinked")
def _relay_temp_unlinked():
    # a temporary file named by a=t,t=t is read by the tap, which removes it as the terminal would:
    # gone after the exit, a blob with the bytes, and the replayed pixels equal the data
    tmp = _spec_tempdir()
    try:
        data = bytes(range(16))
        path = os.path.join(tmp, "tty-graphics-protocol-%d.rgba" % os.getpid())
        steps = [{"tmp_create": {"dir": tmp, "name": os.path.basename(path),
                                 "data_b64": _b64(data).decode("ascii")}}]
        steps += _stream_steps(_apc(b"a=t,t=t,f=32,s=2,v=2,i=81;" + _b64(path)))
        run = _relay_once(tmp, steps, ["--hop", "none", "--respond", "none"])
        eq(run["rc"], 0, "relay exit status (stderr: %s)" % run["err"][-400:])
        check(not os.path.exists(path), "the temporary file is gone after the exit")
        rec = _recording(run)
        eq([v[0] for v in rec.blobs.values()], [data], "the blob holds the file's bytes")
        term = rec.replay()
        eq(term._kitty(term.active).images[81].data, data, "the replayed pixels")
    finally:
        _drop_spec_dir(tmp)


@case("relay", "shm_unlinked")
def _relay_shm_unlinked():
    # a shared memory object named by a=t,t=s is read and unlinked by the tap: after the exit the
    # name does not open any more, and the blob holds the object's bytes
    import _posixshmem
    tmp = _spec_tempdir()
    name = "/vk%d_r" % os.getpid()
    _remove_spec_file("shm", name)
    _SPEC_CREATED.add(("shm", name))
    try:
        data = bytes(range(16))
        steps = [{"shm_create": {"name": name, "data_b64": _b64(data).decode("ascii")}}]
        steps += _stream_steps(_apc(b"a=t,t=s,f=32,s=2,v=2,i=82;" + _b64(name)))
        run = _relay_once(tmp, steps, ["--hop", "none", "--respond", "none"])
        eq(run["rc"], 0, "relay exit status (stderr: %s)" % run["err"][-400:])
        _raises(FileNotFoundError, _posixshmem.shm_open, name, os.O_RDONLY, 0)
        eq([v[0] for v in _recording(run).blobs.values()], [data], "the blob holds the object")
    finally:
        _remove_spec_file("shm", name)
        _drop_spec_dir(tmp)


@case("relay", "media_keep")
def _relay_media_keep():
    # --media-unlink no: the tap reads the temporary file and records it, but leaves it in place
    tmp = _spec_tempdir()
    try:
        data = bytes(range(16))
        path = os.path.join(tmp, "tty-graphics-protocol-keep.rgba")
        steps = [{"tmp_create": {"dir": tmp, "name": os.path.basename(path),
                                 "data_b64": _b64(data).decode("ascii")}}]
        steps += _stream_steps(_apc(b"a=t,t=t,f=32,s=2,v=2,i=83;" + _b64(path)))
        run = _relay_once(tmp, steps, ["--hop", "none", "--respond", "none",
                                       "--media-unlink", "no"])
        eq(run["rc"], 0, "relay exit status (stderr: %s)" % run["err"][-400:])
        check(os.path.exists(path), "with --media-unlink no the file stays")
        eq([v[0] for v in _recording(run).blobs.values()], [data], "the blob holds the bytes")
    finally:
        _drop_spec_dir(tmp)


@case("relay", "tap_frame_chunks")
def _relay_tap_frame_chunks():
    # the tap's loading slot follows the terminal's through a chunked kitty a=f load, whatever keys
    # the chunks carry: a chunk with no t or t=d continues the load and only its m counts (so a
    # rejected f or o on it changes nothing), another t is a first chunk that drops the load in
    # progress, and a first chunk whose keys are rejected loads nothing. After every command the
    # tap's slot and the terminal's agree, and the Transmission the tap hands to the media layer is
    # the one of a non direct medium
    from vkitty import kgp
    from vkitty import relay as relay_mod
    term = _kitty_term()
    tap = relay_mod.Tap(None, None, _hop_none(), "kitty")
    first = b"a=f,i=1,f=32,s=2,v=2,m=1;AAAA"

    def step(payload):
        cmd = kgp.parse(payload, True, tap.loading == "f")
        loaded = tap._loads(cmd)
        term.feed(_apc(payload))
        slot = term._kitty(term.active).loading is not None
        eq(tap.loading == "f", slot, "the tap and the terminal agree after %r" % payload[:24])
        return loaded

    step(b"a=t,f=32,s=2,v=2,i=1;" + _b64(bytes(16)))
    for chunk, still in ((first, True), (b"a=f,f=99,m=1;AAAA", True), (b"o=y,m=1;AAAA", True),
                         (b"f=0,t=d,m=1;AAAA", True), (b"a=f,f=99,m=0;AAAA", False),
                         (first, True), (b"a=f,i=1,f=8,m=0;AAAA", False),
                         (first, True), (b"o=y;AAAA", False)):
        eq(step(chunk), None, "a chunk loads nothing from the media layer: %r" % chunk[:20])
        eq(tap.loading == "f", still, "the slot after %r" % chunk[:20])
    # another t: a new first chunk. A rejected key drops the load and loads nothing; a valid one
    # drops it and hands its medium to the media layer
    step(first)
    eq(step(b"a=f,t=x,s=1,v=1;AAAA"), None, "an unknown medium loads nothing")
    eq(tap.loading, None, "and the load is dropped")
    step(first)
    loaded = step(b"a=f,t=f,f=32,s=2,v=2;AAAA")
    eq(loaded.medium, "f", "another medium is loaded")
    eq(tap.loading, None, "and the load is dropped")
    # f=0 is RGBA in a first chunk, so the file is loaded
    loaded = step(b"a=f,i=1,t=f,f=0,s=1,v=1;AAAA")
    eq((loaded.medium, loaded.format), ("f", "rgba"), "f=0 loads as RGBA")
    # no size: refused before the medium is looked at
    eq(step(b"a=f,i=1,t=f,f=32;AAAA"), None, "no size loads nothing")


@case("relay", "tap_frame_chunks_live")
def _relay_tap_frame_chunks_live():
    # through a real relay: a chunked kitty a=f whose last chunk carries a key that would be
    # refused as a first chunk (f=99, and no action key) completes the frame, and the tap sees the
    # load end, so the file transmission (a=T) after it is loaded (a tap that missed the end would
    # take it for another chunk and record no blob, and the replay would hold no such image)
    tmp = _spec_tempdir()
    try:
        pixels = bytes(range(16))
        text = _b64(pixels)
        green = bytes([0, 255, 0, 255])
        path = os.path.join(tmp, "tty-graphics-protocol-after.rgba")
        steps = [{"write_b64": _b64(_apc(b"a=t,f=32,s=2,v=2,i=5;" + _b64(bytes(16))))
                  .decode("ascii")},
                 {"read_until": "ST", "timeout": 5, "save": "t5"},
                 {"write_b64": _b64(_apc(b"a=f,i=5,f=32,s=2,v=2,m=1;" + text[:12]))
                  .decode("ascii")},
                 {"write_b64": _b64(_apc(b"f=99,m=0;" + text[12:])).decode("ascii")},
                 {"read_until": "ST", "timeout": 5, "save": "f5"},
                 {"tmp_create": {"dir": tmp, "name": os.path.basename(path),
                                 "data_b64": _b64(green).decode("ascii")}},
                 {"write_b64": _b64(_apc(b"a=T,t=t,f=32,s=1,v=1,i=6;" + _b64(path)))
                  .decode("ascii")},
                 {"read_until": "ST", "timeout": 5, "save": "t6"},
                 {"sleep": 0.1}]
        run = _relay_once(tmp, steps, ["--hop", "none", "--respond", "ghostty",
                                       "--profile", "kitty"])
        eq(run["rc"], 0, "relay exit status (stderr: %s)" % run["err"][-400:])
        eq(_read_b64(run, "f5"), b"\x1b_Gi=5,r=2;OK\x1b\\", "the frame completes")
        eq(_read_b64(run, "t6"), b"\x1b_Gi=6;OK\x1b\\", "the file transmission is answered OK")
        check(not os.path.exists(path), "and its file is removed")
        eq([v[0] for v in _recording(run).blobs.values() if v[0] is not None], [green],
           "the only blob is that file's bytes")
        term = _recording(run).replay()
        eq(term.snapshot().images[6].rgba, green, "the replay holds the image")
        _check_live_equal(run)
    finally:
        _drop_spec_dir(tmp)


@case("relay", "tap_rules")
def _relay_tap_rules():
    # the tap loads exactly the media the terminal loads (kgp.execute), keyed as the terminal keys
    # them. (a) a query loads its file and removes it, answering OK. (b) a chunked direct load
    # makes the next a=t a continuation: its payload is data, not a file name, so the temporary
    # file it names is not read, stays in place, and no image is stored. (c) kitty's a=f loads its
    # file, and the replayed frame holds the file's pixels.
    tmp = _spec_tempdir()
    try:
        query_path = os.path.join(tmp, "tty-graphics-protocol-query.rgba")
        steps = [{"tmp_create": {"dir": tmp, "name": os.path.basename(query_path),
                                 "data_b64": _b64(b"\x01\x02\x03").decode("ascii")}},
                 {"write_b64": _b64(_apc(b"a=q,i=40,t=t,f=24,s=1,v=1;" + _b64(query_path)))
                  .decode("ascii")},
                 {"read_until": "ST", "timeout": 5, "save": "q40"}]
        run_a = _relay_once(tmp, steps, ["--hop", "none", "--respond", "ghostty"])
        eq(run_a["rc"], 0, "(a) relay exit status (stderr: %s)" % run_a["err"][-400:])
        eq(_read_b64(run_a, "q40"), b"\x1b_Gi=40;OK\x1b\\", "(a) the query is answered OK")
        check(not os.path.exists(query_path), "(a) the query's file is removed")
        eq([v[0] for v in _recording(run_a).blobs.values()], [b"\x01\x02\x03"],
           "(a) one blob, the file's bytes")
        _check_live_equal(run_a)

        chunk_path = os.path.join(tmp, "tty-graphics-protocol-chunk.rgba")
        steps = [{"tmp_create": {"dir": tmp, "name": os.path.basename(chunk_path),
                                 "data_b64": _b64(bytes(range(16))).decode("ascii")}},
                 {"write_b64": _b64(_apc(b"a=t,i=41,f=24,s=2,v=1,m=1;" + _b64(b"abc")))
                  .decode("ascii")},
                 {"write_b64": _b64(_apc(b"a=t,t=t;" + _b64(chunk_path))).decode("ascii")},
                 {"read_until": 1, "timeout": 0.5, "save": "none"},
                 {"sleep": 0.1}]
        run_b = _relay_once(tmp, steps, ["--hop", "none", "--respond", "ghostty",
                                         "--profile", _G131])
        eq(run_b["rc"], 0, "(b) relay exit status (stderr: %s)" % run_b["err"][-400:])
        eq(_read_b64(run_b, "none"), b"", "(b) the continuation's error has no id, so no answer")
        check(os.path.exists(chunk_path), "(b) the file named by the continuation stays")
        eq(_recording(run_b).blobs, {}, "(b) no blob at all: the continuation loads nothing")
        live_b = _json_read(os.path.join(run_b["rec"], "live_final.json"))
        check(41 not in [img["id"] for img in live_b["images"]], "(b) image 41 is not stored")
        _check_live_equal(run_b)

        # (b14) 1.4.0 abandons the load when a command names another medium and handles it as a new
        # transmission: the temporary file is read (one blob) and removed
        steps_14 = [{"tmp_create": {"dir": tmp, "name": os.path.basename(chunk_path),
                                    "data_b64": _b64(bytes(range(16))).decode("ascii")}}
                    ] + steps[1:]
        run_b14 = _relay_once(tmp, steps_14, ["--hop", "none", "--respond", "ghostty",
                                              "--profile", _G140])
        eq(run_b14["rc"], 0, "(b14) relay exit status (stderr: %s)" % run_b14["err"][-400:])
        check(not os.path.exists(chunk_path), "(b14) the file named by the new command is read "
              "and removed")
        eq([v[0] for v in _recording(run_b14).blobs.values()], [bytes(range(16))],
           "(b14) one blob: the file's bytes")
        _check_live_equal(run_b14)

        frame_path = os.path.join(tmp, "tty-graphics-protocol-frame.rgba")
        green = bytes([0, 255, 0, 255])
        steps = [{"write_b64": _b64(_apc(b"a=t,f=32,s=1,v=1,i=5;"
                                         + _b64(bytes([255, 0, 0, 255])))).decode("ascii")},
                 {"read_until": "ST", "timeout": 5, "save": "t5"},
                 {"tmp_create": {"dir": tmp, "name": os.path.basename(frame_path),
                                 "data_b64": _b64(green).decode("ascii")}},
                 {"write_b64": _b64(_apc(b"a=f,i=5,r=1,t=t,f=32,s=1,v=1;" + _b64(frame_path)))
                  .decode("ascii")},
                 {"read_until": "ST", "timeout": 5, "save": "f5"},
                 {"sleep": 0.1}]
        run_c = _relay_once(tmp, steps, ["--hop", "none", "--respond", "ghostty",
                                         "--profile", "kitty"])
        eq(run_c["rc"], 0, "(c) relay exit status (stderr: %s)" % run_c["err"][-400:])
        eq(_read_b64(run_c, "t5"), b"\x1b_Gi=5;OK\x1b\\", "(c) the image is stored")
        eq(_read_b64(run_c, "f5"), b"\x1b_Gi=5,r=1;OK\x1b\\", "(c) the frame is answered OK")
        check(not os.path.exists(frame_path), "(c) the frame's file is removed")
        eq([v[0] for v in _recording(run_c).blobs.values() if v[0] is not None], [green],
           "(c) the blob holds the frame's bytes")
        term = _recording(run_c).replay()
        eq(term.snapshot().images[5].rgba, green, "(c) the replayed frame holds the file's pixels")
        _check_live_equal(run_c)
    finally:
        _drop_spec_dir(tmp)


def _read_b64(run, name):
    """The bytes the child saved under name (its result holds them base64 encoded)."""
    import base64
    entry = run["res"]["reads"][name]
    return base64.b64decode(entry["b64"])


@case("relay", "query_response")
def _relay_query_response():
    # a query is answered (q=0), a q=2 query is silent, and a placement of an image that does not
    # exist is answered ENOENT, all through the live terminal's answers to the child
    tmp = _spec_tempdir()
    try:
        steps = [{"write_b64": _b64(_apc(b"a=q,i=31,s=1,v=1,f=24;AAAA")).decode("ascii")},
                 {"read_until": "ST", "timeout": 5, "save": "ok"},
                 {"write_b64": _b64(_apc(b"a=q,i=32,q=2,s=1,v=1,f=24;AAAA")).decode("ascii")},
                 {"read_until": 1, "timeout": 0.3, "save": "silent"},
                 {"write_b64": _b64(_apc(b"a=p,i=99")).decode("ascii")},
                 {"read_until": "ST", "timeout": 5, "save": "enoent"},
                 {"sleep": 0.05}]
        run = _relay_once(tmp, steps, ["--hop", "none", "--respond", "ghostty"])
        eq(run["rc"], 0, "relay exit status (stderr: %s)" % run["err"][-400:])
        eq(_read_b64(run, "ok"), b"\x1b_Gi=31;OK\x1b\\", "the query is answered OK")
        eq(_read_b64(run, "silent"), b"", "a q=2 query gets no answer")
        eq(_read_b64(run, "enoent"), b"\x1b_Gi=99;ENOENT: image not found\x1b\\",
           "a placement of a missing image is answered ENOENT")
        _check_live_equal(run)
    finally:
        _drop_spec_dir(tmp)


@case("relay", "vt_answers_per_hop")
def _relay_vt_answers_per_hop():
    # hop none: the live terminal answers DSR and DA1 itself. hop tmux: tmux answers those (in a
    # real pane), so the relay answers neither, and a Kitty query is still answered wrapped
    from vkitty.tokens import tmux_wrap
    tmp = _spec_tempdir()
    try:
        steps = [{"write_b64": _b64(b"\x1b[5n").decode("ascii")},
                 {"read_until": 4, "timeout": 5, "save": "dsr"},
                 {"write_b64": _b64(b"\x1b[c").decode("ascii")},
                 {"read_until": 12, "timeout": 5, "save": "da"},
                 {"sleep": 0.05}]
        run_n = _relay_once(tmp, steps, ["--hop", "none", "--respond", "ghostty"])
        eq(run_n["rc"], 0, "hop none: relay exit status (stderr: %s)" % run_n["err"][-400:])
        eq(_read_b64(run_n, "dsr"), b"\x1b[0n", "hop none: DSR is answered by the terminal")
        eq(_read_b64(run_n, "da"), b"\x1b[?62;22;52c", "hop none: DA1 is answered")
        eq(_recording(run_n).snapshot().responses, [b"\x1b[0n", b"\x1b[?62;22;52c"],
           "hop none: the recorded answers are the replayed ones")
        _check_live_equal(run_n)

        wrapped_query = _b64(tmux_wrap(_apc(b"a=q,i=31,s=1,v=1,f=24;AAAA"))).decode("ascii")
        steps = [{"write_b64": _b64(b"\x1b[5n").decode("ascii")},
                 {"read_until": 4, "timeout": 0.3, "save": "dsr"},
                 {"write_b64": _b64(b"\x1b[c").decode("ascii")},
                 {"read_until": 12, "timeout": 0.3, "save": "da"},
                 {"write_b64": wrapped_query},
                 {"read_until": "ST", "timeout": 5, "save": "kitty"},
                 {"sleep": 0.05}]
        from vkitty.vt import HOP_TMUX
        run_t = _relay_once(tmp, steps, ["--hop", HOP_TMUX, "--respond", "ghostty"])
        eq(run_t["rc"], 0, "hop tmux: relay exit status (stderr: %s)" % run_t["err"][-400:])
        eq(_read_b64(run_t, "dsr"), b"", "hop tmux: the relay does not answer DSR")
        eq(_read_b64(run_t, "da"), b"", "hop tmux: the relay does not answer DA1")
        eq(_read_b64(run_t, "kitty"), b"\x1b_Gi=31;OK\x1b\\",
           "hop tmux: the wrapped query is answered")
        eq(_recording(run_t).snapshot().responses, [b"\x1b_Gi=31;OK\x1b\\"],
           "hop tmux: the recorded answers are the replayed ones")
        _check_live_equal(run_t)
    finally:
        _drop_spec_dir(tmp)


@case("relay", "hop_tmux_off")
def _relay_hop_tmux_off():
    """tmux with allow-passthrough off (the tmux default) shows the terminal nothing graphical:
    the model drops every passthrough DCS and every raw APC, no image is stored and no a=q is
    answered, where hop tmux (passthrough on) stores and answers. --hop auto reads the pane's
    allow-passthrough through `tmux show-options -Apv allow-passthrough` (a stub program named by
    $VKITTY_TMUX here): off gives tmux-off, on and all give tmux, and an old tmux (the option is
    unknown), a missing tmux and an answer nobody expects give tmux, the assumption that held
    before."""
    from vkitty import relay as relay_mod
    from vkitty.tokens import tmux_wrap
    from vkitty.vt import HOP_TMUX, HOP_TMUX_OFF, Terminal
    send = _apc(b"a=t,f=24,s=1,v=1,i=7;AAAA")
    stream = tmux_wrap(send) + send + tmux_wrap(b"\x1b[31mred") + b"x"
    on = Terminal(20, 4, hop=HOP_TMUX)
    on.feed(stream)
    snap = on.snapshot()
    eq(sorted(snap.images), [7], "hop tmux: the wrapped transmission stores the image")
    off = Terminal(20, 4, hop=HOP_TMUX_OFF)
    off.feed(stream)
    snap = off.snapshot()
    eq(sorted(snap.images), [], "hop tmux-off: no image is stored")
    tmux = _tmux(snap)
    eq((tmux["ignored_dcs"], tmux["dropped_apc"], tmux["body_other"]), (2, 1, 0),
       "hop tmux-off: both passthrough DCS are ignored, the raw APC is dropped, nothing else "
       "came out of a body")
    check(any("allow-passthrough off" in line for line in snap.warnings), "a warning says why: %r"
          % (snap.warnings,))
    eq(snap.text()[0].strip(), "x", "only the plain text after the sequences is drawn")
    off_q = Terminal(20, 4, hop=HOP_TMUX_OFF, respond="ghostty")
    off_q.feed(tmux_wrap(_apc(b"a=q,i=31,s=1,v=1,f=24;AAAA")))
    eq(off_q.responses, [], "hop tmux-off: a wrapped query is not answered")
    tmp = _spec_tempdir()
    try:
        stubs = os.path.join(tmp, "bin")
        os.mkdir(stubs)
        stub = _spec_path(stubs, "stub-answer", b'#!/bin/sh\nprintf "%s\\n" "$STUB_TMUX_OUT"\n'
                                                b'exit ${STUB_TMUX_RC:-0}\n')
        os.chmod(stub, 0o755)
        os.environ["VKITTY_TMUX"] = stub
        for says, rc, want in (("off", "0", False), ("on", "0", True), ("all", "0", True),
                               ("", "1", True), ("unknown option: allow-passthrough", "1", True),
                               ("maybe", "0", True)):
            os.environ["STUB_TMUX_OUT"], os.environ["STUB_TMUX_RC"] = says, rc
            eq(relay_mod._tmux_passthrough_allowed(), want,
               "tmux says %r (exit %s): passthrough allowed" % (says, rc))
        os.environ["VKITTY_TMUX"] = os.path.join(tmp, "no-such-program")
        eq(relay_mod._tmux_passthrough_allowed(), True, "no tmux binary: allowed (assumed)")
        os.environ["VKITTY_TMUX"] = stub
        wrapped_query = _b64(tmux_wrap(_apc(b"a=q,i=31,s=1,v=1,f=24;AAAA"))).decode("ascii")
        pixel = _spec_path(tmp, "px.rgb", b"abc")
        wrapped_file = _b64(tmux_wrap(_apc(b"a=t,t=f,f=24,s=1,v=1,i=9;" + _b64(pixel)))
                            ).decode("ascii")
        steps = [{"write_b64": wrapped_file}, {"write_b64": wrapped_query},
                 {"read_until": "ST", "timeout": 0.4, "save": "kitty"},
                 {"sleep": 0.05}]
        # the hop the relay picks, the answer the child gets, the APCs the model took and the
        # files the tap read (a blob each: the tap reads what reaches the terminal, no more)
        for says, want_hop, respond, apcs in (("off", HOP_TMUX_OFF, "ghostty", 0),
                                              ("on", HOP_TMUX, "none", 1)):
            os.environ["STUB_TMUX_OUT"], os.environ["STUB_TMUX_RC"] = says, "0"
            run = _relay_once(tmp, steps, ["--respond", respond],
                              tmux=os.path.join(tmp, "stub") + ",1,0")
            eq(run["rc"], 0, "auto, passthrough %s: relay exit status (stderr: %s)"
               % (says, run["err"][-400:]))
            rec = _recording(run)
            eq(rec.meta["hop"], want_hop, "auto, passthrough %s: the recorded hop" % says)
            eq(rec.snapshot().stats["apc"], apcs * 2,
               "auto, passthrough %s: the APCs the model took" % says)
            eq(len([e for e in rec.events if e.get("e") == "blob"]), apcs,
               "auto, passthrough %s: the files the tap read" % says)
            if respond == "ghostty":
                eq(_read_b64(run, "kitty"), b"", "auto, passthrough %s: no answer" % says)
                _check_live_equal(run)
    finally:
        os.environ.pop("VKITTY_TMUX", None)
        os.environ.pop("STUB_TMUX_OUT", None)
        os.environ.pop("STUB_TMUX_RC", None)
        _drop_spec_dir(tmp)


@case("relay", "reattach")
def _relay_reattach():
    """A reattach (a new outer terminal) is a ctl command and a recorded event: after it the
    terminal's graphics storage is empty while the screen text stays, so the placeholder cells name
    an image that is not there (missing) until the program sends the image and its placement again.
    The replay and the live terminal both apply it, so their reports are equal, and a mark before
    and after it shows the difference. This is what lets a remote test assert that every placement
    references an uploaded image after a reattach."""
    tmp = _spec_tempdir()
    try:
        upload = (_apc(b"a=t,f=32,s=1,v=1,i=21;" + _b64(bytes(range(4))))
                  + _apc(b"a=p,i=21,U=1,c=1,r=1"))
        show = _at(2, 1, _fg_rgb(21) + _ph(0, 0))
        # what the program sends after the reattach: another image, so that the final state of
        # the live terminal (one image) tells a reattach it applied from one it did not (two)
        again_send = (_apc(b"a=t,f=32,s=1,v=1,i=22;" + _b64(bytes(range(8, 12))))
                      + _apc(b"a=p,i=22,U=1,c=1,r=1") + _at(4, 1, _fg_rgb(22) + _ph(0, 0)))
        go1 = os.path.join(tmp, "go1")
        steps = [{"write_b64": _b64(upload + show).decode("ascii")},
                 {"wait_file": go1, "timeout": 60},
                 {"write_b64": _b64(again_send).decode("ascii")}, {"sleep": 0.1}]
        run = _relay_start(tmp, steps, ["--hop", "none", "--respond", "ghostty"])
        try:
            tui = os.path.join(run["rec"], "tui.bin")
            _wait_for(lambda: show in _read_bytes(tui), "the image and its placeholder", run=run)
            _mark(run, "before")
            _fifo_write(run["ctl"], b"reattach\n")
            _mark(run, "after")
            _spec_path(tmp, "go1", b"")
            _wait_for(lambda: again_send in _read_bytes(tui), "the second upload", run=run)
            _mark(run, "again")
            _relay_end(run)
        finally:
            _relay_stop(run)
        eq(run["rc"], 0, "relay exit status (stderr: %s)" % run["err"][-400:])
        eq(run["res"].get("timeouts", []), [], "the child never gave up waiting for the case")
        rec = _recording(run)
        eq([e["e"] for e in rec.events if e["e"] == "reattach"], ["reattach"],
           "the reattach is one event of the recording")
        before, after, again = (rec.snapshot(at=name) for name in ("before", "after", "again"))
        eq((sorted(before.images), before.missing), ([21], []), "before: the image is stored")
        eq(len(before.virtual), 1, "before: one placeholder run draws")
        eq(sorted(after.images), [], "after the reattach the storage is empty")
        eq([m["reason"] for m in after.missing], ["no virtual placement"],
           "after: the placeholder cell names an image and a placement that are not there")
        eq(after.text()[1], before.text()[1], "after: the screen text is kept (tmux redraws it)")
        check(after.text()[1][2].startswith("\U0010eeee"), "after: the placeholder cell is there")
        eq(sorted(again.images), [22], "again: only what the program sent after the reattach")
        eq([m["x"] for m in again.missing], [2],
           "again: the old cell still names image 21, which is gone; the new one resolves")
        eq([v["image_id"] for v in again.virtual], [21, 22],
           "again: both placeholder runs are listed")
        _check_live_equal(run)
    finally:
        _drop_spec_dir(tmp)


@case("relay", "resize_order")
def _relay_resize_order():
    # a resize is recorded before the child is told about it, and everything the child wrote for the
    # old size is recorded before the resize. The child prints its window size every 30 ms. First
    # resize, the child running: every "WS 100 30" line is after the resize's position in the byte
    # stream (a child told first would print the new size before the resize is recorded). An
    # old-size line after that position is not checked here: the child can write one in the few
    # microseconds between the relay's drain and the resize, a window that a host with a load
    # average of 100 stretches to milliseconds (it failed the case there). Second resize, the child
    # stopped (SIGSTOP, by its pid) while it is sent and recorded, so that window cannot hold a
    # line: every "WS 100 30" line is before the second resize's position and every "WS 90 28"
    # line after it. The child continues once the relay has applied the second resize (a mark sent
    # behind it is acknowledged); quit ends the run
    import re
    import signal
    tmp = _spec_tempdir()
    run = None
    pid = None
    try:
        run = _relay_start(tmp, [{"print_pid": True},
                                 {"print_winsize_every": 30, "count": 2000}],
                           ["--hop", "none", "--respond", "none"])
        tui = os.path.join(run["rec"], "tui.bin")
        _wait_for(lambda: b"WS 80 24 1048 800" in _read_bytes(tui), "the first size report",
                  run=run)
        _fifo_write(run["ctl"], b"resize 100 30\n")
        _wait_for(lambda: b"WS 100 30 1308 998" in _read_bytes(tui), "the new size report", run=run)
        pid = _child_pid_from_rec(run)
        os.kill(pid, signal.SIGSTOP)
        _wait_for(lambda: _proc_state(pid).startswith("T"), "the child to stop", run=run)
        _fifo_write(run["ctl"], b"resize 90 28\n")
        # the mark behind it is acknowledged only when the relay has applied the resize (the
        # control lines are handled in order): the child continues then and not when the event is
        # on disk, so it never runs in the window between the event and the new size
        _mark(run, "r2")
        os.kill(pid, signal.SIGCONT)
        _wait_for(lambda: b"WS 90 28 1178 932" in _read_bytes(tui), "the second new size report",
                  run=run)
        _fifo_write(run["ctl"], b"quit\n")
        _relay_end(run)
        eq(run["rc"], 143, "relay exit status (stderr: %s)" % run["err"][-400:])
        rec = _recording(run)
        at = 0
        positions = []
        for ev in rec.events:
            if ev.get("e") == "data" and ev.get("ch") == "tui":
                at = ev["off"] + ev["n"]
            elif ev.get("e") == "resize":
                positions.append(at)
        eq(len(positions), 2, "both resizes are recorded")
        data = _read_bytes(tui)
        new1 = [m.start() for m in re.finditer(rb"WS 100 30 1308 998", data)]
        old2 = [m.end() for m in re.finditer(rb"WS 100 30 1308 998", data)]
        new2 = [m.start() for m in re.finditer(rb"WS 90 28 1178 932", data)]
        check(new1 and all(p >= positions[0] for p in new1),
              "a new-size line is before the first resize")
        check(old2 and all(p <= positions[1] for p in old2),
              "an old-size line is after the second resize")
        check(new2 and all(p >= positions[1] for p in new2),
              "a new-size line is before the second resize")
    finally:
        if pid is not None and not _pid_gone(pid):
            try:
                os.kill(pid, signal.SIGCONT)
            except ProcessLookupError:
                pass
        if run is not None:
            _relay_stop(run)
        _drop_spec_dir(tmp)


@case("relay", "resize_drain")
def _relay_resize_drain():
    """A resize and a mark drain what the child and the graphics FIFO have already written before
    they are recorded. The running relay reads those descriptors before the control FIFO, so the
    drain changes nothing in a live run (relay/resize_order, relay/mark_drain); it is the guarantee
    that does not depend on that order, and this row holds it in-process: a Relay object with a
    scripted writer and two pipes that already hold more bytes than one read takes (CHUNK is cut to
    1000), then _resize and _mark are called. Every data event must come before the resize event
    and the mark event. A _resize or a _mark without its drain records the event first."""
    import types
    from vkitty import relay as relay_mod

    class Writer:
        def __init__(self):
            self.log = []

        def now(self):
            return 1.0

        def data(self, channel, chunk, _t):
            self.log.append(("data", channel, len(chunk)))
            return 0

        def event(self, obj):
            self.log.append((obj["e"], obj.get("name", "")))

    tmp = _spec_tempdir()
    saved_chunk = relay_mod.CHUNK
    fds = []
    try:
        relay_mod.CHUNK = 1000
        for what in ("resize", "mark"):
            opts = types.SimpleNamespace(cols=80, rows=24, cell_w=13, cell_h=33, pad=4,
                                         no_forward=True, ctl=os.path.join(tmp, "ctl"))
            relay = relay_mod.Relay(opts)
            relay.writer = Writer()
            relay._feed = lambda *_args: None
            relay._signal_child = lambda _sig: None
            tui_r, tui_w = os.pipe()
            gfx_r, gfx_w = os.pipe()
            fds += [tui_r, tui_w, gfx_r, gfx_w]
            for fd in (tui_r, gfx_r):
                os.set_blocking(fd, False)
            relay.master, relay.gfx_fd = tui_r, gfx_r
            os.write(tui_w, b"t" * 3500)
            os.write(gfx_w, b"g" * 2500)
            if what == "resize":
                relay._resize(100, 30)
            else:
                relay._mark("m1")
            log = relay.writer.log
            event = [i for i, entry in enumerate(log) if entry[0] in ("resize", "mark")]
            eq(len(event), 1, "%s: the event is recorded once (%r)" % (what, log))
            check(all(entry[0] == "data" for entry in log[:event[0]]) and event[0] == len(log) - 1,
                  "%s: every data event is before it: %r" % (what, log))
            eq(sum(entry[2] for entry in log if entry[0] == "data" and entry[1] == "tui"), 3500,
               "%s: all the child's bytes were recorded" % what)
            eq(sum(entry[2] for entry in log if entry[0] == "data" and entry[1] == "gfx"), 2500,
               "%s: all the FIFO's bytes were recorded" % what)
    finally:
        relay_mod.CHUNK = saved_chunk
        for fd in fds:
            try:
                os.close(fd)
            except OSError:
                pass
        _drop_spec_dir(tmp)


@case("relay", "mark_drain")
def _relay_mark_drain():
    # a mark is recorded after the output the child wrote before the mark was read. The child
    # writes its last line and stops itself. The relay is stopped (SIGSTOP) meanwhile, so the line
    # is in the child's terminal and not yet in tui.bin; the mark is queued while the relay is still
    # stopped, and SIGCONT makes the relay's next select see the output and the mark together. The
    # snapshot at the mark shows the line only if the output is read before the mark is recorded (a
    # loop that takes the control FIFO before the child's terminal records the mark first)
    import signal
    tmp = _spec_tempdir()
    try:
        run = _relay_start(tmp, [{"print_pid": True}, {"sleep": 0.4},
                                 {"write_b64": _b64(b"MARKER-END\r\n").decode("ascii")},
                                 {"stop_self": True}, {"sleep": 30}],
                           ["--hop", "none", "--respond", "none"])
        try:
            tui = os.path.join(run["rec"], "tui.bin")
            _wait_for(lambda: _child_pid_from_rec(run) is not None, "the child's pid", run=run)
            pid = _child_pid_from_rec(run)
            relay_pid = run["proc"].pid
            os.kill(relay_pid, signal.SIGSTOP)
            _wait_for(lambda: _proc_state(relay_pid).startswith("T"), "the relay to stop", run=run)
            time.sleep(_PARKED_WAIT)
            _wait_for(lambda: _proc_state(pid).startswith("T"), "the child to write and stop",
                      run=run)
            check(b"MARKER-END" not in _read_bytes(tui),
                  "the relay is stopped, so the child's last line is not read yet")
            _fifo_write(run["ctl"], b"mark m1\n")
            os.kill(relay_pid, signal.SIGCONT)
            _wait_for(lambda: _read_text(run["ctl"] + ".ack") == "m1", "the ack of mark m1",
                      run=run)
            os.kill(pid, signal.SIGCONT)
            _fifo_write(run["ctl"], b"quit\n")
            _relay_end(run)
        finally:
            _relay_stop(run)
        eq(run["rc"], 143, "relay exit status (stderr: %s)" % run["err"][-400:])
        rec = _recording(run)
        check(any("MARKER-END" in row for row in rec.snapshot("m1").text()),
              "the snapshot at mark m1 shows the output written before it")
    finally:
        _drop_spec_dir(tmp)


@case("relay", "gfx_fifo")
def _relay_gfx_fifo():
    # the backend's graphics arrive on the gfx FIFO (a channel of its own): the writes are kept in
    # gfx.bin in the order they came, and the replayed state has the image and its placement. The
    # transmission and the placement are written while the relay is stopped, with the mark queued
    # behind them (as in relay/mark_drain): the mark must come after the graphics it follows
    import signal
    from vkitty.tokens import tmux_wrap
    from vkitty.vt import HOP_TMUX
    tmp = _spec_tempdir()
    try:
        run = _relay_start(tmp, [{"print_pid": True}, {"sleep": 30}],
                           ["--hop", HOP_TMUX, "--respond", "none"], gfx=True)
        try:
            transmit = tmux_wrap(_apc(b"a=t,f=32,s=1,v=1,i=91;" + _b64(bytes(range(4)))))
            place = tmux_wrap(_apc(b"a=p,i=91,U=1,c=1,r=1"))
            _wait_for(lambda: _child_pid_from_rec(run) is not None, "the child's pid", run=run)
            _wait_for(lambda: os.path.exists(run["gfx"]), "the gfx FIFO", run=run)
            relay_pid = run["proc"].pid
            os.kill(relay_pid, signal.SIGSTOP)
            _wait_for(lambda: _proc_state(relay_pid).startswith("T"), "the relay to stop", run=run)
            time.sleep(_PARKED_WAIT)
            _fifo_write(run["gfx"], transmit)
            _fifo_write(run["gfx"], place)
            _fifo_write(run["ctl"], b"mark g1\n")
            os.kill(relay_pid, signal.SIGCONT)
            _wait_for(lambda: _read_text(run["ctl"] + ".ack") == "g1", "the ack of mark g1",
                      run=run)
            _fifo_write(run["ctl"], b"quit\n")
            _relay_end(run)
        finally:
            _relay_stop(run)
        # quit sends SIGTERM to the child, which dies of it: the relay exits 128 + 15
        eq(run["rc"], 143, "relay exit status (stderr: %s)" % run["err"][-400:])
        eq(_read_bytes(os.path.join(run["rec"], "gfx.bin")), transmit + place,
           "gfx.bin holds both writes, in order")
        check(not os.path.exists(run["gfx"]) and not os.path.exists(run["ctl"]),
              "the FIFOs are removed after the exit")
        check(not os.path.exists(run["ctl"] + ".ack"), "the ack is removed after the exit")
        term = _recording(run).replay(at="g1")
        check(term.snapshot().images.get(91) is not None, "the image is in the replayed state")
        check(term._kitty(term.active).placements, "the placement is in the replayed state")
    finally:
        _drop_spec_dir(tmp)


@case("relay", "child_reaped")
def _relay_child_reaped():
    # after the relay exits the child is gone (reaped); when the relay itself is terminated, it
    # forwards the signal to the child, waits for it and exits with the child's signal status
    tmp = _spec_tempdir()
    try:
        run = _relay_once(tmp, [{"sleep": 0.05}], ["--hop", "none", "--respond", "none"])
        eq(run["rc"], 0, "relay exit status")
        check(run["res"] is not None and run["res"].get("pid"), "the child wrote its result")
        try:
            os.kill(run["res"]["pid"], 0)
        except ProcessLookupError:
            pass
        else:
            raise AssertionError("the child still exists after the relay exited")
        run = _relay_start(tmp, [{"print_pid": True}, {"sleep": 30}],
                           ["--hop", "none", "--respond", "none"])
        try:
            _wait_for(lambda: _child_pid_from_rec(run) is not None, "the child's pid", run=run)
            run["proc"].terminate()
            _relay_end(run)
        finally:
            _relay_stop(run)
        eq(run["rc"], 143, "a relay stopped by SIGTERM exits 128 + 15 when its child died of it")
        pid = _child_pid_from_rec(run)
        check(pid is not None, "the child printed its pid")
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            pass
        else:
            raise AssertionError("the child (pid %d) survived its relay" % pid)
    finally:
        _drop_spec_dir(tmp)


@case("relay", "recording_marks")
def _relay_recording_marks():
    # a recording made by RecordingWriter directly (no timing): a mark taken inside a synchronized
    # update (DECSET 2026) is replayed to the end of that update, with a warning, and not beyond; a
    # mark's since_prev_mark counts from the previous mark; a mark name used twice resolves to its
    # last occurrence
    from vkitty.recording import Recording, RecordingWriter
    tmp = _spec_tempdir()
    try:
        rec_dir = os.path.join(tmp, "rec")
        meta = {"cols": 20, "rows": 4, "cell": [13, 33], "pad": 4, "profile": "ghostty-1.3.1",
                "hop": "none", "tmpdir": tmp, "t": 0.0}
        writer = RecordingWriter(rec_dir, meta)
        apc1 = _apc(b"a=t,f=32,s=1,v=1,i=1;" + _b64(bytes(4)))
        apc2 = _apc(b"a=t,f=32,s=1,v=1,i=2;" + _b64(bytes(range(4))))
        apc3 = _apc(b"a=t,f=32,s=1,v=1,i=3;" + _b64(bytes(range(8, 12))))
        writer.data("tui", b"\x1b[?2026h" + apc1 + b"A", 0.1)
        writer.event({"e": "mark", "name": "u1", "t": 0.2})
        writer.data("tui", b"B\x1b[?2026l", 0.3)
        writer.data("tui", b"C", 0.4)
        writer.event({"e": "mark", "name": "m1", "t": 0.45})
        writer.data("tui", b"D" + apc2, 0.5)
        writer.event({"e": "mark", "name": "m1", "t": 0.6})
        writer.data("tui", b"E" + apc3, 0.65)
        writer.close(0, 0.7)
        rec = Recording.load(rec_dir)
        check(rec.done and rec.end is not None, "the recording is complete")
        eq(rec.marks["m1"], max(i for i, ev in enumerate(rec.events)
                                if ev.get("e") == "mark" and ev.get("name") == "m1"),
           "a repeated mark name is the last occurrence")
        at_u1 = rec.snapshot("u1")
        eq(at_u1.text()[0].rstrip(), "AB", "the mark inside the update is fed to the update's end")
        check(not any("C" in row for row in at_u1.text()), "and not beyond it")
        check(any("synchronized update" in w and "u1" in w for w in at_u1.warnings),
              "with a warning naming the mark")
        eq(at_u1.stats["since_prev_mark"]["apc_bytes"], len(apc1),
           "since_prev_mark counts the APC before the mark")
        at_m1 = rec.snapshot("m1")
        eq(at_m1.text()[0].rstrip(), "ABCD", "the last m1 is after the update and the text")
        eq(at_m1.stats["since_prev_mark"]["apc_bytes"], len(apc2),
           "since_prev_mark restarts at the earlier mark")
        end = rec.snapshot()
        eq(end.text()[0].rstrip(), "ABCDE", "the end shows the same screen")
        eq(end.stats["apc_bytes"], len(apc1) + len(apc2) + len(apc3),
           "the APC bytes of the whole recording")
        eq(end.stats["since_prev_mark"]["apc_bytes"], len(apc3),
           "at the end, since_prev_mark counts from the last mark")
    finally:
        _drop_spec_dir(tmp)


def _synthetic_meta(tmp, profile="ghostty-1.3.1", hop="none", cols=20, rows=4):
    """The start metadata of a recording the case writes itself (RecordingWriter's meta)."""
    return {"cols": cols, "rows": rows, "cell": [13, 33], "pad": 4, "profile": profile,
            "hop": hop, "tmpdir": tmp, "t": 0.0}


@case("relay", "recording_sync_edge")
def _relay_recording_sync_edge():
    # a mark taken inside a synchronized update (DECSET 2026) shows the screen at the byte where
    # that update ends. The data event that ends the update may carry more bytes: an update opened
    # in it, or text after its end, is not part of the mark's screen
    from vkitty.recording import Recording, RecordingWriter
    tmp = _spec_tempdir()
    try:
        cases = (("the next update opens in the same event",
                  [b"\x1b[?2026hA", "mark", b"B\x1b[?2026l\x1b[?2026hC", b"D\x1b[?2026l", b"E"]),
                 ("text follows the end in the same event",
                  [b"\x1b[?2026hA", "mark", b"B\x1b[?2026lXYZ", b"E"]))
        for index, (what, parts) in enumerate(cases):
            rec_dir = os.path.join(tmp, "rec%d" % index)
            writer = RecordingWriter(rec_dir, _synthetic_meta(tmp))
            t = 0.1
            for part in parts:
                if isinstance(part, str):
                    writer.event({"e": "mark", "name": "u1", "t": t})
                else:
                    writer.data("tui", part, t)
                t += 0.1
            writer.close(0, t)
            snap = Recording.load(rec_dir).snapshot("u1")
            eq(snap.text()[0].rstrip(), "AB", "%s: the mark's screen ends with the update" % what)
            check(any("synchronized update" in w and "u1" in w for w in snap.warnings),
                  "%s: with a warning naming the mark" % what)
    finally:
        _drop_spec_dir(tmp)


@case("relay", "checks_interleave_and_stats")
def _relay_checks_interleave_and_stats():
    """checks.py on recordings the case writes: `cuts` prints the five counts (cuts, splices,
    tmux_drops, body_other, warnings) and the first warnings, and `stats` holds the per-image wire
    bytes to the exact total when the stream has no a=q query and to at most the total when it has
    one (a query's payload counts in the total and in no image)."""
    import subprocess
    from vkitty import tokens
    from vkitty.recording import RecordingWriter
    from vkitty.vt import HOP_TMUX
    checks_py = os.path.join(LIB, "vkitty", "checks.py")

    def make(tmp, name, hop, parts):
        rec_dir = os.path.join(tmp, name)
        writer = RecordingWriter(rec_dir, _synthetic_meta(tmp, hop=hop, cols=20, rows=2))
        t = 0.1
        for part in parts:
            writer.data("tui", part, t)
            t += 0.1
        writer.close(0, t)
        return rec_dir

    def run(sub, rec_dir):
        proc = subprocess.run([sys.executable, "-I", "-B", checks_py, sub, rec_dir],
                              capture_output=True, text=True, timeout=120)
        return proc.returncode, proc.stdout, proc.stderr

    tmp = _spec_tempdir()
    try:
        # a character split by a CSI behind tmux: one splice, nothing else
        rec = make(tmp, "splice", HOP_TMUX, [b"A\xe4\x1b[31m\xb8\x96Z"])
        code, out, err = run("cuts", rec)
        eq((code, out), (0, "cuts=0 splices=1 tmux_drops=0 body_other=0 warnings=0\n"),
           "a splice (%s)" % err)
        # a cut CSI, a DCS t that is not a tmux passthrough (tmux drops it), and a body that
        # carries text and a CSI
        rec = make(tmp, "mixed", HOP_TMUX, [b"\x1b[1;2\x18", b"\x1bPtmuy;abc\x1b\\",
                                           tokens.tmux_wrap(b"xy\x1b[2J")])
        code, out, err = run("cuts", rec)
        lines = out.splitlines()
        eq(code, 0, "mixed exit (%s)" % err)
        check(lines and lines[0].startswith("cuts=1 splices=0 tmux_drops=1 body_other=2 warnings="),
              "the mixed counts: %r" % (lines[:1],))
        warns = int(lines[0].rsplit("=", 1)[1])
        check(warns >= 1 and len(lines) == 1 + min(warns, 5), "a warning line per warning: %r"
              % (lines,))
        check(all(line.startswith("warning: ") for line in lines[1:]), "warning lines: %r"
              % (lines,))
        # a passthrough DCS that tmux's 5 s timer drops (the next chunk comes 6 s after it opened)
        # counts in tmux_drops, and the character the tmux rule kept across it is a splice
        rec_dir = os.path.join(tmp, "timer")
        writer = RecordingWriter(rec_dir, _synthetic_meta(tmp, hop=HOP_TMUX, cols=20, rows=2))
        writer.data("tui", b"A\xe4\x1bPtmux;", 0.0)
        writer.data("tui", b"\xb8\x96Z", 6.0)
        writer.close(0, 6.1)
        code, out, err = run("cuts", rec_dir)
        eq(code, 0, "timer drop exit (%s)" % err)
        eq(out.splitlines(), ["cuts=1 splices=1 tmux_drops=1 body_other=0 warnings=1",
                              "warning: tmux timer: passthrough DCS open 6.0 s, dropped"],
           "a timer drop is counted in tmux_drops")
        # stats: the same one-pixel transmission with and without a query ahead of it
        send = b"\x1b_Ga=t,i=1,s=1,v=1,f=24;AAAA\x1b\\"
        query = b"\x1b_Ga=q,i=31,s=1,v=1,f=24;AAAA\x1b\\"
        rec = make(tmp, "plain", "none", [send])
        code, out, err = run("stats", rec)
        eq(code, 0, "stats without a query exits 0 (%s)" % err)
        check("rule: no a=q query" in out
              and "ok stats: per-image wire bytes add up to the total (4)" in out,
              "the exact rule applies without a query: %r" % out)
        rec = make(tmp, "queried", "none", [query, send])
        code, out, err = run("stats", rec)
        eq(code, 0, "stats with a query exits 0 (%s)" % err)
        check("rule: 1 a=q queries" in out and "do not exceed the total (8)" in out,
              "the at-most rule applies with a query: %r" % out)
        check("splices=0" in out, "the totals line has splices: %r" % out)
    finally:
        _drop_spec_dir(tmp)


@case("relay", "checks_tiles_columns")
def _relay_checks_tiles_columns():
    """`checks.py tiles --expect-cols A:B`: the columns the placeholder runs cover. A grid one
    column short draws the right pixels in every cell it has, so the pixel comparison alone passes
    it; --expect-cols is what fails it. The picture is one solid colour, which keeps the pixel
    comparison trivially true: only the rows and columns can fail here."""
    import subprocess
    import zlib
    from vkitty.recording import RecordingWriter
    checks_py = os.path.join(LIB, "vkitty", "checks.py")

    def make(tmp, name, cols):
        rec_dir = os.path.join(tmp, name)
        writer = RecordingWriter(rec_dir, _synthetic_meta(tmp, cols=50, rows=4))
        raw = bytes((200, 30, 60)) * (624 * 528)
        stream = _apc(b"a=t,f=24,s=624,v=528,i=5,o=z,q=2;" + _b64(zlib.compress(raw)))
        stream += _apc(b"a=p,i=5,U=1,c=48,r=16,q=2")
        from vkitty.unicode_place import DIACRITICS
        for row in range(2):
            cells = "".join("\U0010EEEE" + chr(DIACRITICS[row]) + chr(DIACRITICS[col])
                            for col in range(cols))
            stream += _at(0, row, _fg_rgb(5) + cells)
        writer.data("tui", stream, 0.1)
        writer.event({"e": "mark", "name": "shown", "t": 0.2})
        writer.close(0, 0.3)
        return rec_dir

    def run(rec_dir, png, *extra):
        proc = subprocess.run([sys.executable, "-I", "-B", checks_py, "tiles", rec_dir, "shown",
                               png] + list(extra), capture_output=True, text=True, timeout=120)
        return proc.returncode, proc.stdout + proc.stderr

    tmp = _spec_tempdir()
    try:
        from PIL import Image
        png = os.path.join(tmp, "solid.png")
        Image.new("RGB", (624, 528), (200, 30, 60)).save(png)
        full = make(tmp, "full", 48)
        code, out = run(full, png, "--expect-rows", "0:1", "--expect-cols", "0:47")
        eq(code, 0, "a grid of all 48 columns meets 0:47 (%s)" % out)
        check("columns 0:47" in out, "the columns are printed: %r" % out)
        short = make(tmp, "short", 47)
        code, out = run(short, png, "--expect-rows", "0:1")
        eq(code, 0, "without --expect-cols a grid one column short passes, as before (%s)" % out)
        code, out = run(short, png, "--expect-rows", "0:1", "--expect-cols", "0:47")
        eq(code, 1, "--expect-cols 0:47 fails a grid of 47 columns (%s)" % out)
        check("visible image columns 0:46, 0:47 expected" in out,
              "the failure names the columns: %r" % out)
        code, out = run(full, png, "--expect-cols", "0")
        eq(code, 2, "a malformed --expect-cols is a usage error (%s)" % out)
    finally:
        _drop_spec_dir(tmp)


@case("relay", "case3_rule")
def _relay_case3_rule():
    """`checks.py case3`, the rule tests/vkitty_screen.sh case 3 follows: given the writer in the
    tree and the counts `cuts` printed, whether the case fails and whether its grid and tile checks
    run. With the in-order writer any cut, splice, drop or foreign token fails and every check
    runs; without it nothing fails, the grid is skipped when foreign tokens came out of passthrough
    bodies, and the tiles are skipped when anything but splices mixed in (splices alone never skip
    a check: behind tmux the character survives)."""
    import subprocess
    checks_py = os.path.join(LIB, "vkitty", "checks.py")
    run_yes, run_skip = "fail=yes grid=run tiles=run", "fail=no grid=run tiles=skip"
    rows = (
        ("yes", (0, 0, 0, 0, 0), "fail=no grid=run tiles=run"),
        ("yes", (1, 0, 0, 0, 0), run_yes),
        ("yes", (0, 1, 0, 0, 0), run_yes),
        ("yes", (0, 0, 0, 0, 2), "fail=no grid=run tiles=run"),
        ("no", (0, 0, 0, 0, 0), "fail=no grid=run tiles=run"),
        ("no", (0, 3, 0, 0, 0), "fail=no grid=run tiles=run"),
        ("no", (1, 0, 0, 0, 0), run_skip),
        ("no", (0, 0, 1, 0, 0), run_skip),
        ("no", (0, 0, 0, 1, 0), "fail=no grid=skip tiles=skip"),
        ("no", (0, 0, 0, 0, 1), run_skip),
    )
    for writer, counts, want in rows:
        proc = subprocess.run([sys.executable, "-I", "-B", checks_py, "case3", "--writer", writer]
                              + [str(n) for n in counts], capture_output=True, text=True,
                              timeout=60)
        eq((proc.returncode, proc.stdout), (0, want + "\n"),
           "writer %s, counts %r (stderr: %s)" % (writer, counts, proc.stderr[-200:]))
    proc = subprocess.run([sys.executable, "-I", "-B", checks_py, "case3", "--writer", "maybe",
                           "0", "0", "0", "0", "0"], capture_output=True, text=True, timeout=60)
    eq(proc.returncode, 2, "an unknown writer is a usage error")
    return "%d rows" % len(rows)


@case("relay", "recording_flush_mark")
def _relay_recording_flush_mark():
    # events.jsonl is flushed at a mark, so a reader in another process finds the mark (and the data
    # before it) on disk while the recording is still open
    from vkitty.recording import RecordingWriter
    tmp = _spec_tempdir()
    try:
        rec_dir = os.path.join(tmp, "rec")
        writer = RecordingWriter(rec_dir, _synthetic_meta(tmp))
        writer.data("tui", b"abc", 0.1)
        writer.event({"e": "mark", "name": "k", "t": 0.2})
        on_disk = _read_text(os.path.join(rec_dir, "events.jsonl"))
        check('"name":"k"' in on_disk, "the mark is on disk before the recording is closed")
        check('"e":"data"' in on_disk, "the data event before the mark is on disk too")
        writer.close(0, 0.3)
    finally:
        _drop_spec_dir(tmp)


@case("relay", "recording_timer")
def _relay_recording_timer():
    # replay gives each data event its arrival time. A passthrough DCS still open when the next
    # chunk arrives more than 5 s later is dropped by tmux's timer, as the live terminal drops it;
    # within 5 s its APC is delivered
    from vkitty.recording import Recording, RecordingWriter
    from vkitty.vt import HOP_TMUX
    tmp = _spec_tempdir()
    try:
        for index, (late, apcs) in enumerate(((5.5, 0), (4.9, 1))):
            rec_dir = os.path.join(tmp, "rec%d" % index)
            writer = RecordingWriter(rec_dir, _synthetic_meta(tmp, hop=HOP_TMUX, cols=10, rows=3))
            writer.data("tui", b"\x1bPtmux;\x1b\x1b_Gi=1;AA", 0.0)
            writer.data("tui", b"AA\x1b\x1b\\\x1b\\xy", late)
            writer.close(0, late + 0.1)
            snap = Recording.load(rec_dir).snapshot()
            eq(snap.stats["apc"], apcs, "a DCS open for %.1f s: APCs delivered" % late)
            eq(_tmux(snap)["timer_drops"], 1 - apcs,
               "a DCS open for %.1f s: timer drops" % late)
    finally:
        _drop_spec_dir(tmp)


@case("relay", "recording_anim_mark")
def _relay_recording_anim_mark():
    # a snapshot at a mark shows the animation at the mark's time, and the end's snapshot the one at
    # the end's time (kitty profile). The a=a command at 0.3 s starts the clock, with 100 ms frames:
    # frame 1 is shown on [0.3, 0.4), frame 2 on [0.4, 0.5). At 0.35 s that is frame 1, at 0.47 s
    # frame 2 (both away from the frame changes)
    from vkitty.recording import Recording, RecordingWriter
    tmp = _spec_tempdir()
    try:
        red = _solid(4, 4, b"\xff\x00\x00\xff")
        green = _solid(4, 4, b"\x00\xff\x00\xff")
        rec_dir = os.path.join(tmp, "rec")
        writer = RecordingWriter(rec_dir, _synthetic_meta(tmp, profile="kitty"))
        writer.data("tui", _apc(b"a=t,f=32,s=4,v=4,i=5;" + _b64(red)), 0.0)
        writer.data("tui", _apc(b"a=f,i=5,s=4,v=4,f=32,z=100;" + _b64(green)), 0.1)
        writer.data("tui", _apc(b"a=a,i=5,r=1,z=100"), 0.2)
        # an image advances only when drawn
        writer.data("tui", _apc(b"a=p,i=5,U=1,c=1,r=1"), 0.25)
        writer.data("tui", _apc(b"a=a,i=5,s=3,v=1"), 0.3)
        writer.event({"e": "mark", "name": "m", "t": 0.35})
        writer.data("tui", b"x", 0.47)
        writer.close(0, 0.48)
        rec = Recording.load(rec_dir)
        eq(rec.snapshot("m").images[5].frame, 1, "at the mark (0.35 s) frame 1 is shown")
        eq(rec.snapshot().images[5].frame, 2, "at the end (0.47 s) frame 2 is shown")
    finally:
        _drop_spec_dir(tmp)


@case("relay", "recording_responses")
def _relay_recording_responses():
    # snapshot().responses are the answers the child got, as recorded: a recording made without a
    # live terminal has none, though the replayed terminal would answer the query. With a live
    # terminal, a recorded answer that differs from the replayed one is a warning
    import base64
    from vkitty.recording import Recording, RecordingWriter
    tmp = _spec_tempdir()
    try:
        query = _apc(b"a=q,i=31,s=1,v=1,f=24;AAAA")
        rec_dir = os.path.join(tmp, "none")
        writer = RecordingWriter(rec_dir, _synthetic_meta(tmp))
        writer.data("tui", query, 0.1)
        writer.close(0, 0.2)
        rec = Recording.load(rec_dir)
        eq(rec.snapshot().responses, [], "no answer was recorded, so none is reported")
        eq(rec.replay().responses, [_ok(31)], "the replayed terminal answers the query")
        check(not any("responses differ" in w for w in rec.snapshot().warnings),
              "without a live terminal there is no comparison")

        rec_dir = os.path.join(tmp, "live")
        enoent = _err(31, "ENOENT: image not found")
        writer = RecordingWriter(rec_dir, _synthetic_meta(tmp))
        writer.data("tui", query, 0.1)
        writer.event({"e": "resp", "b64": base64.b64encode(enoent).decode("ascii"), "t": 0.15})
        writer.close(0, 0.2)
        _json_write(os.path.join(rec_dir, "live_final.json"), {})
        snap = Recording.load(rec_dir).snapshot()
        eq(snap.responses, [enoent], "the recorded answer is the one reported")
        check(any("responses differ" in w for w in snap.warnings),
              "a recorded answer that differs from the replayed one is a warning")
    finally:
        _drop_spec_dir(tmp)


@case("relay", "tap_skip_exact")
def _relay_tap_skip_exact():
    # Tap.feed skips the bytes that cannot start or end an APC (the ground-state path). For random
    # streams cut at random places, under both hops and with arrival times that cross tmux's 5 s
    # timer, the APC tokens and the tokenizer's state after every chunk equal those of a tokenizer
    # fed every byte. The streams hold APCs, string openers, raw C1 bytes (0x90 to 0x9f, which start
    # a string or a CSI from an unfinished sequence), partial sequences and text, and a TUI stream
    # is checked as well
    from vkitty import relay as relay_mod
    from vkitty import tokens
    rnd = random.Random(20260615)
    pieces = [b"\x1b[31m", b"\x1b[38;5;200;1m", b"\x1b[?2026h", b"\x1b[?2026l", b"\x1b(B", b"\x1b7",
              b"\x1bM", b"\x1b=", b"\x1b\\", b"\x1b[", b"\x1b[3", b"\x1b(", b"\x1b",
              b"\x1b_Gi=1;QUFB\x1b\\", b"\x1b_G", b"\x1bPtmux;\x1b\x1b_Gi=2;AA\x1b\x1b\\\x1b\\",
              b"\x1bPq\x1b\\", b"\x1b]0;t\x07", b"\x1b]2;x\x1b\\", b"\x1bXsos\x1b\\",
              b"\x1b^pm\x1b\\", b"\x90", b"\x98", b"\x9b", b"\x9d", b"\x9e", b"\x9f", b"\x9c",
              b"\x9fGi=3;QUFB\x9c", b"\x07", b"\r\n", b"\x18", b"\x1a", b"\x1c", b"plain text ",
              b"\xc3\xa9", b"\xe4\xb8\x96", b"\xf0\x9f\x98\x80", b"\x80\xbf", b"\x3b\x31",
              b"x" * 20, b"\x1b[2;3 q", b"\x1b[>4;2m"]
    apcs = [0]
    for trial in range(1200):
        data = b"".join(rnd.choice(pieces) for _ in range(rnd.randrange(1, 24)))
        cuts = []
        if len(data) > 1:
            cuts = sorted(set(rnd.randrange(1, len(data)) for _ in range(rnd.randrange(0, 7))))
        bounds = [0] + cuts + [len(data)]
        chunks = [data[a:b] for a, b in zip(bounds, bounds[1:]) if b > a]
        times = []
        when = 0.0
        for _ in chunks:
            when += rnd.choice((0.001, 0.5, 6.0))
            times.append(when)
        for hop in (_hop_none(), _hop_tmux()):
            apcs[0] += _tap_check(chunks, times, hop, relay_mod, tokens)
    tui = _tui_stream(300000, 11)
    chunks, pos = [], 0
    while pos < len(tui):
        size = rnd.randrange(1, 65537)
        chunks.append(tui[pos:pos + size])
        pos += size
    times = [0.001 * i for i in range(len(chunks))]
    for hop in (_hop_none(), _hop_tmux()):
        apcs[0] += _tap_check(chunks, times, hop, relay_mod, tokens)
    check(apcs[0] > 300, "the streams hold APC tokens (%d seen)" % apcs[0])


def _hop_none():
    from vkitty.vt import HOP_NONE
    return HOP_NONE


def _hop_tmux():
    from vkitty.vt import HOP_TMUX
    return HOP_TMUX


def _tap_check(chunks, times, hop, relay_mod, tokens):
    """Feed the chunks to a Tap and to a full tokenizer; the APC tokens must be equal, and the
    tokenizer states must agree after every chunk. Returns the number of APC tokens."""
    tap_seen = []
    ref_seen = []
    tap = relay_mod.Tap(None, None, hop, "ghostty-1.3.1")
    tap._apc = lambda tok, channel: tap_seen.append((tok.start, tok.ordinal, bytes(tok.payload)))
    ref = tokens.Tokenizer(
        lambda tok: ref_seen.append((tok.start, tok.ordinal, bytes(tok.payload)))
        if tok.kind == tokens.APC else None,
        strings_only=True, tmux_passthrough=(hop == _hop_tmux()))
    offset = 0
    for chunk, when in zip(chunks, times):
        tap.feed("tui", chunk, when)
        ref.feed(chunk, offset, when)
        offset += len(chunk)
        got = tap._tokenizers["tui"].state
        eq(got, ref.state, "the tokenizer state after %d bytes (hop %s)" % (offset, hop))
    # the tokens the feeds emit (the relay never calls finish, so neither side does here)
    eq(tap_seen, ref_seen, "the APC tokens of a stream cut as %r (hop %s)"
       % ([len(c) for c in chunks][:12], hop))
    return len(ref_seen)


def _relay_read_samples(tmp, stream, respond):
    """One in-process relay run of a child that writes stream, with --respond respond. Each call of
    Relay._read_master is timed through perfclock (the relay's own work on one read: the recording,
    the tap, the live terminal's frame and the forwarding are all inside it); a Sample's value is
    its wall time in ms normalized to 64 KB. A perfclock.ProcSampler follows this process over the
    whole run, and when it finds the run disturbed no sample is clean: a read is shorter than the
    allowance of one sample, so a read alone cannot show it. Returns the samples, the relay's exit
    status, the recording folder and the number of bytes it recorded."""
    import signal
    from vkitty import perfclock as pc
    from vkitty import relay as relay_mod
    saved_env = {key: os.environ.get(key) for key in ("TMPDIR", "TMUX")}
    saved_sig = {sig: signal.getsignal(sig) for sig in (signal.SIGTERM, signal.SIGHUP,
                                                        signal.SIGINT, signal.SIGWINCH)}
    samples = []
    original = relay_mod.Relay._read_master

    def timed_read(self):
        n, sample = pc.timed(original, self)
        if n:
            sample.value = sample.wall * 1000.0 * 65536.0 / n
            samples.append(sample)
        return n
    run = _relay_run_paths(tmp)
    stream_path = _spec_path(run["base"], "stream.bin", stream)
    _json_write(run["script"], [{"write_file": stream_path}, {"sleep": 0.05}])
    sampler = pc.ProcSampler()
    sampler.add(os.getpid())
    try:
        with sampler:
            os.environ["TMPDIR"] = tmp
            os.environ.pop("TMUX", None)
            relay_mod.Relay._read_master = timed_read
            rc = relay_mod.main(["--rec", run["rec"], "--size", "80x24", "--no-forward",
                                 "--hop", "none", "--respond", respond, "--",
                                 sys.executable, "-I", TESTCHILD_PY, run["script"],
                                 run["result_path"]])
    finally:
        relay_mod.Relay._read_master = original
        for key, value in saved_env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        for sig, handler in saved_sig.items():
            signal.signal(sig, handler)
    recorded = os.path.getsize(os.path.join(run["rec"], "tui.bin"))
    if not sampler.clean():
        for sample in samples:
            sample.clean = False
    return samples, rc, run["rec"], recorded, len(stream)


def _p50_p95(samples):
    ordered = sorted(samples)
    return ordered[len(ordered) // 2], ordered[int(len(ordered) * 0.95)]


_PERF_UNDECIDED = []   # the timed cases whose limit the host left undecided (see _perf_limit)


def _perf_summary(names):
    """The line main prints before its verdict when limits were left undecided."""
    return "%d timed cases undecided (host busy): %s" % (len(names), ", ".join(names))


def _perf_limit(case, verdict, what, shown, limit_text):
    """A timed case's note for a perfclock verdict. A failed limit (the clean measurements are
    beyond it) raises; an undecided one (the host left no clean measurement) records the case once
    for the summary line and says so in the note; a passed one says on which samples."""
    from vkitty import perfclock as pc
    if verdict.state == pc.FAIL:
        raise AssertionError("%s %s on clean samples (%d %% of the work), limit %s"
                             % (what, shown(verdict.value), round(100 * verdict.share),
                                limit_text))
    if verdict.state == pc.UNDECIDED:
        if case not in _PERF_UNDECIDED:
            _PERF_UNDECIDED.append(case)
        return ("%s %s, UNDECIDED: host busy, clean %d %% of the work (limit %s)"
                % (what, shown(verdict.value), round(100 * verdict.share), limit_text))
    if verdict.basis == "all":
        return "%s %s (all samples)" % (what, shown(verdict.value))
    return "%s %s (clean samples, %d %% of the work)" % (what, shown(verdict.value),
                                                         round(100 * verdict.share))


@case("perf", "relay_tui")
def _perf_relay_tui():
    # the relay's cost per chunk of TUI text on the real read path: the relay runs (in this process,
    # with a child that writes a TUI stream) and each call of Relay._read_master is timed. The
    # budget is 1 ms per chunk of at most 64 KB with --respond none, asserted at twice that for the
    # median (the 4 MB stream of perf/tokens). With --respond ghostty the live terminal is a worker
    # process, so the relay only frames each read for it: its budget is 1.5 ms, asserted at 3 ms for
    # the median, on a 2 MB stream (about 2000 reads). The live run must record no error and leave
    # its report, and the catch-up of the worker after the child's last write is printed. Each read
    # is a sample for perfclock, which decides the median on the reads the host did not disturb; a
    # read is too short to show that by itself, so the whole relay run is judged as well
    from vkitty import perfclock as pc
    from vkitty.recording import Recording
    tmp = _spec_tempdir()
    try:
        plain, rc, rec, recorded, size = _relay_read_samples(tmp, _tui_stream(4 * 1000000, 7),
                                                             "none")
        eq(rc, 0, "--respond none: the relay exit status")
        eq(recorded, size, "--respond none: every byte of the stream is recorded")
        live, rc2, rec2, recorded2, size2 = _relay_read_samples(tmp, _tui_stream(2 * 1000000, 7),
                                                                "ghostty")
        eq(rc2, 0, "--respond ghostty: the relay exit status")
        eq(recorded2, size2, "--respond ghostty: every byte of the stream is recorded")
        loaded = Recording.load(rec2)
        eq(loaded.errors, [], "--respond ghostty: the run records no error")
        live_pid = _live_pid({"rec": rec2})
        check(live_pid is not None and _pid_gone(live_pid),
              "--respond ghostty: the worker (pid %r) is gone after the relay returned"
              % (live_pid,))
        check(os.path.exists(os.path.join(rec2, "live_final.json")),
              "--respond ghostty: the live terminal's report exists")
        last_data = [ev for ev in loaded.events if ev.get("e") == "data"][-1]
        catch_up = loaded.end["t"] - last_data["t"]
    finally:
        _drop_spec_dir(tmp)
    plain_p50, plain_p95 = _p50_p95([s.value for s in plain])
    live_p50, live_p95 = _p50_p95([s.value for s in live])
    plain_note = _perf_limit("perf/relay_tui", pc.p50_verdict(plain, 2.0),
                             "none p50", _ms3, "2 ms (budget 1 ms)")
    live_note = _perf_limit("perf/relay_tui", pc.p50_verdict(live, 3.0),
                            "ghostty p50", _ms3, "3 ms (budget 1.5 ms)")
    return ("TUI text, per 64 KB of read: %s, p95 %.2f ms (%d reads); %s, p95 %.2f ms (%d reads); "
            "live catch-up %.3f s"
            % (plain_note, plain_p95, len(plain), live_note, live_p95, len(live), catch_up))


@case("perf", "relay_answer")
def _perf_relay_answer():
    # the live terminal's answer latency: 30 queries, each sent after the answer to the one before
    # has been read by the child. A query's latency is the resp event's t minus the t of the data
    # event that holds the query's first byte (when the relay read it). The worker answers on the
    # relay's loop, so the latency is the worker's round trip; its budget is 5 ms, asserted at 10 ms
    # for the median. A run is one measurement: the relay, its child and its worker are followed by
    # a perfclock.ProcSampler, and the run is repeated (up to three times) while the host disturbed
    # it and the median is beyond the limit
    import base64
    from vkitty import perfclock as pc
    tmp = _spec_tempdir()
    figures = []

    def measure():
        queries = [_apc(b"a=q,i=%d,s=1,v=1,f=24;AAAA" % (200 + i)) for i in range(30)]
        steps = [{"print_pid": True}]
        for i, query in enumerate(queries):
            steps += [{"write_b64": _b64(query).decode("ascii")},
                      {"read_until": "ST", "timeout": 5, "save": "a%d" % i}]
        run, sampler, _elapsed = _relay_run_followed(tmp, steps, "ghostty")
        eq(run["rc"], 0, "relay exit status (stderr: %s)" % run["err"][-400:])
        events = _event_lines(run)
        tui = _read_bytes(os.path.join(run["rec"], "tui.bin"))
        resp = [ev for ev in events if ev.get("e") == "resp"]
        eq(len(resp), len(queries), "one answer is recorded per query")
        latencies = []
        for i, query in enumerate(queries):
            answer = b"\x1b_Gi=%d;OK\x1b\\" % (200 + i)
            eq(_read_b64(run, "a%d" % i), answer, "query %d is answered" % i)
            eq(base64.b64decode(resp[i]["b64"]), answer, "query %d's answer is recorded in order"
               % i)
            latencies.append((resp[i]["t"] - _data_time_at(events, tui.find(query))) * 1000.0)
        latencies.sort()
        figures.append((latencies[len(latencies) // 2], latencies[-1]))
        return figures[-1][0], sampler.clean()
    try:
        verdict, made = pc.retry(measure, 10.0)
    finally:
        _drop_spec_dir(tmp)
    note = _perf_limit("perf/relay_answer", verdict, "median answer latency", _ms3, "10 ms")
    best = min(figures)
    return "%s over 30 queries (maximum %.2f ms, %d run%s)" % (note, best[1], len(made),
                                                               "" if len(made) == 1 else "s")


@case("relay", "answers_queued")
def _relay_answers_queued():
    # answers wait in the relay while the child does not read its input: the relay keeps reading the
    # child's output meanwhile, so a child that writes more than its terminal's buffers hold is not
    # stalled, and every answer is delivered in order when the child reads them. The 87 answers
    # overfill the input buffer by one answer, and the output after them overfills the child's
    # output
    tmp = _spec_tempdir()
    try:
        answers = b"\x1b[?62;22;52c" * 87
        steps = [{"write_b64": _b64(b"\x1b[c" * 87).decode("ascii")},
                 {"write_b64": _b64(b"O" * 65536 + b"END\r\n").decode("ascii")},
                 {"read_until": len(answers), "timeout": 10, "save": "answers"},
                 {"sleep": 0.05}]
        run = _relay_once(tmp, steps, ["--hop", "none", "--respond", "ghostty"])
        eq(run["rc"], 0, "relay exit status (stderr: %s)" % run["err"][-400:])
        eq(_recording(run).errors, [], "no error event: no answer is dropped")
        eq(_read_b64(run, "answers"), answers, "every answer is delivered, in order")
        check(b"END\r\n" in _read_bytes(os.path.join(run["rec"], "tui.bin")),
              "the output after the answers is recorded")
    finally:
        _drop_spec_dir(tmp)


@case("relay", "child_gone")
def _relay_child_gone():
    # the check that a run's child is gone finds a child that wrote no result (it died of a signal)
    # by the pid it printed: a live child is reported, and the same run passes once it is reaped
    import subprocess
    tmp = _spec_tempdir()
    try:
        rec = os.path.join(tmp, "rec")
        os.mkdir(rec)
        sleeper = subprocess.Popen([sys.executable, "-B", "-c", "import time; time.sleep(30)"])
        try:
            with open(os.path.join(rec, "tui.bin"), "wb") as fh:
                fh.write(b"PID %d\r\n" % sleeper.pid)
            try:
                _child_gone({"rec": rec, "res": None})
            except AssertionError as exc:
                check("still exists" in str(exc), "the live child is named: %s" % exc)
            else:
                raise AssertionError("a live child with no result file was not reported")
        finally:
            sleeper.kill()
            sleeper.wait()
        _child_gone({"rec": rec, "res": None})
    finally:
        _drop_spec_dir(tmp)


@case("relay", "ack_lifecycle")
def _relay_ack_lifecycle():
    # the ack of a mark (ctl.ack) belongs to one run: an ack left by an earlier run with the same
    # ctl path is removed when the relay starts, and none is left after the exit. Repeated names are
    # each acknowledged in order, the waiter removing the earlier ack first (_mark does)
    import subprocess
    tmp = _spec_tempdir()
    try:
        run = _relay_run_paths(tmp)
        _json_write(run["script"], [{"print_pid": True}, {"sleep": 30}])
        with open(run["ctl"] + ".ack", "w", encoding="ascii") as fh:
            fh.write("stale")
        out = open(run["out"], "wb")
        try:
            run["proc"] = subprocess.Popen(
                _relay_argv(run, ["--no-forward", "--ctl", run["ctl"], "--hop", "none",
                                  "--respond", "none"]),
                env=_relay_env(tmp), stdin=subprocess.DEVNULL, stdout=out,
                stderr=subprocess.STDOUT)
        finally:
            out.close()
        try:
            _wait_for(lambda: _child_pid_from_rec(run) is not None, "the child's pid", run=run)
            check(not os.path.exists(run["ctl"] + ".ack"),
                  "a stale ack from an earlier run is removed when the relay starts")
            for _ in range(3):
                _mark(run, "x")
            _fifo_write(run["ctl"], b"quit\n")
            _relay_end(run)
        finally:
            _relay_stop(run)
        check(not os.path.exists(run["ctl"] + ".ack"), "no ack is left after the exit")
        rec = _recording(run)
        marks = [ev["name"] for ev in rec.events if ev.get("e") == "mark"]
        eq(marks, ["x", "x", "x"], "three marks with the same name are recorded")
        eq(rec.marks["x"], max(i for i, ev in enumerate(rec.events)
                               if ev.get("e") == "mark"), "the name resolves to the last one")
    finally:
        _drop_spec_dir(tmp)


@case("relay", "live_mark_resize")
def _relay_live_mark_resize():
    # with a live terminal, a resize and a mark: the replay applies the resize (the screen is the
    # new size), a mark restarts since_prev_mark in the live terminal as in the replay, and the live
    # report equals the replayed one. The child writes each image only after the case has made the
    # mark before it (it waits for a file the case writes), so the order of the marks and the
    # images does not depend on how fast the host is
    tmp = _spec_tempdir()
    try:
        apc1 = _apc(b"a=t,f=32,s=1,v=1,i=21;" + _b64(bytes(4)))
        apc2 = _apc(b"a=t,f=32,s=1,v=1,i=22;" + _b64(bytes(range(4))))
        apc3 = _apc(b"a=t,f=32,s=1,v=1,i=23;" + _b64(bytes(range(8, 12))))
        go1 = os.path.join(tmp, "go1")
        go2 = os.path.join(tmp, "go2")
        steps = [{"write_b64": _b64(apc1).decode("ascii")}, {"wait_file": go1, "timeout": 60},
                 {"write_b64": _b64(apc2).decode("ascii")}, {"wait_file": go2, "timeout": 60},
                 {"write_b64": _b64(apc3).decode("ascii")}, {"sleep": 0.1}]
        run = _relay_start(tmp, steps, ["--hop", "none", "--respond", "ghostty"])
        try:
            tui = os.path.join(run["rec"], "tui.bin")
            _wait_for(lambda: apc1 in _read_bytes(tui), "the first image", run=run)
            _mark(run, "a")
            _fifo_write(run["ctl"], b"resize 100 30\n")
            _spec_path(tmp, "go1", b"")
            _wait_for(lambda: apc2 in _read_bytes(tui), "the second image", run=run)
            _mark(run, "b")
            _spec_path(tmp, "go2", b"")
            _wait_for(lambda: apc3 in _read_bytes(tui), "the third image", run=run)
            _relay_end(run)
        finally:
            _relay_stop(run)
        eq(run["rc"], 0, "relay exit status (stderr: %s)" % run["err"][-400:])
        eq(run["res"]["error"], None, "the child ran every step")
        eq(run["res"].get("timeouts", []), [], "the child never gave up waiting for the case")
        _check_live_equal(run)
        live = _json_read(os.path.join(run["rec"], "live_final.json"))
        eq((live["cols"], live["rows"]), (100, 30), "the live terminal has the new size")
        snap = _recording(run).snapshot()
        eq((snap.cols, snap.rows), (100, 30), "the replay applies the resize")
        eq(snap.stats["since_prev_mark"]["apc_bytes"], len(apc3),
           "since_prev_mark counts from the last mark")
    finally:
        _drop_spec_dir(tmp)


def _data_time_at(events, off):
    """The t of the TUI data event whose bytes hold the offset off (when the relay read that
    byte)."""
    for ev in events:
        if ev.get("e") == "data" and ev.get("ch") == "tui" \
                and ev["off"] <= off < ev["off"] + ev["n"]:
            return ev["t"]
    raise AssertionError("no tui data event holds offset %d" % off)


@case("relay", "live_worker")
def _relay_live_worker():
    # --respond ghostty runs the live terminal in a worker process of its own (live.py). Run A: the
    # start event names the worker's pid (not the child's), the run leaves no worker behind
    # (_child_gone checks it), the relay's stderr is empty and the live report equals the replay.
    # Run B: the worker leads its own session, and when its relay is killed (SIGKILL, so nothing is
    # cleaned up) its input ends and it exits by itself within 3 s
    import signal
    tmp = _spec_tempdir()
    try:
        run = _relay_once(tmp, _stream_steps(_record_stream()),
                          ["--hop", "none", "--respond", "ghostty"])
        live = _live_pid(run)
        check(isinstance(live, int) and live > 0,
              "the start event names the live terminal's pid (%r)" % (live,))
        check(live != run["res"]["pid"], "the live terminal is not the child")
        eq(run["rc"], 0, "relay exit status (stderr: %s)" % run["err"][-400:])
        eq(run["err"], "", "the relay's stderr is empty")
        _check_live_equal(run)
    finally:
        _drop_spec_dir(tmp)

    tmp = _spec_tempdir()
    try:
        run = _relay_start(tmp, [{"print_pid": True}, {"sleep": 30}],
                           ["--hop", "none", "--respond", "ghostty"])
        try:
            _wait_for(lambda: _child_pid_from_rec(run) is not None and _live_pid(run) is not None,
                      "the child's pid and the live terminal's pid", run=run)
            live = _live_pid(run)
            eq(os.getsid(live), live, "the live terminal leads its own session")
            os.kill(run["proc"].pid, signal.SIGKILL)
            run["proc"].wait()
            _wait_for(lambda: _pid_gone(live),
                      "the live terminal to exit after its relay was killed", run=run)
        finally:
            _kill_child_by_pid(run)
            _relay_stop(run)
    finally:
        _drop_spec_dir(tmp)


@case("relay", "live_mark_barrier")
def _relay_live_mark_barrier():
    # a mark waits for the live terminal. The run's own worker is stopped (SIGSTOP, by its pid)
    # before the child writes 1 MB of TUI text and then a query, so the worker is behind when the
    # query arrives however fast or loaded the host is (a precondition on how long the answer took
    # failed on a host with a load average of 100, where the relay was slower than the worker). The
    # mark is sent as soon as the query is in tui.bin and must not be acknowledged while the worker
    # is stopped (a relay that records the mark at once acknowledges it in milliseconds); then the
    # worker continues: the answer's resp event must come before the mark event, the snapshot at m1
    # holds the answer with no warning, and the child reads the answer. Everything the case started
    # is stopped by pid in the finally (SIGCONT first)
    import base64
    import signal
    tmp = _spec_tempdir()
    run = None
    live = None
    try:
        query = _apc(b"a=q,i=31,s=1,v=1,f=24;AAAA")
        backlog = _spec_path(tmp, "backlog.bin", _tui_stream(1000000, 13))
        go = os.path.join(tmp, "go")
        # the child waits for the go file until the worker is stopped, then writes; it stops itself
        # after its answer and stays stopped until the mark is acknowledged: a mark that the relay
        # reads after the child exited is never handled (the relay's loop has ended with the
        # child), so the child must still be there when the mark is read
        steps = [{"print_pid": True}, {"wait_file": go, "timeout": 60}, {"write_file": backlog},
                 {"write_b64": _b64(query).decode("ascii")},
                 {"read_until": "ST", "timeout": 30, "save": "ans"}, {"stop_self": True}]
        run = _relay_start(tmp, steps, ["--hop", "none", "--respond", "ghostty"])
        tui = os.path.join(run["rec"], "tui.bin")
        _wait_for(lambda: _live_pid(run) is not None and _child_pid_from_rec(run) is not None,
                  "the start event and the child's pid", run=run)
        live = _live_pid(run)
        os.kill(live, signal.SIGSTOP)
        _wait_for(lambda: _proc_state(live).startswith("T"), "the worker to stop", run=run)
        _spec_path(tmp, "go", b"")
        _wait_for(lambda: query in _read_bytes(tui), "the query in tui.bin", run=run)
        _remove_ack(run)
        _fifo_write(run["ctl"], b"mark m1\n")
        time.sleep(0.6)
        check(_read_text(run["ctl"] + ".ack") != "m1",
              "the mark is not acknowledged while the worker is stopped")
        os.kill(live, signal.SIGCONT)
        _wait_for(lambda: _read_text(run["ctl"] + ".ack") == "m1", "the ack of mark m1", run=run)
        pid = _child_pid_from_rec(run)
        _wait_for(lambda: _proc_state(pid).startswith("T"), "the child to stop after its answer",
                  run=run)
        os.kill(pid, signal.SIGCONT)
        _relay_end(run, timeout=60)
        eq(run["rc"], 0, "relay exit status (stderr: %s)" % run["err"][-400:])
        answer = b"\x1b_Gi=31;OK\x1b\\"
        eq(_read_b64(run, "ans"), answer, "the child reads the answer")
        events = _event_lines(run)
        resp = [i for i, ev in enumerate(events) if ev.get("e") == "resp"]
        marks = [i for i, ev in enumerate(events) if ev.get("e") == "mark" and ev.get("name")
                 == "m1"]
        eq(len(resp), 1, "one answer is recorded")
        eq(base64.b64decode(events[resp[0]]["b64"]), answer, "the recorded answer")
        check(resp[0] < marks[0], "the answer's resp event comes before the mark m1")
        snap = _recording(run).snapshot("m1")
        eq(snap.responses, [answer], "the snapshot at m1 holds the answer")
        check(not any("responses differ" in w for w in snap.warnings),
              "no responses differ warning at m1")
        _check_live_equal(run)
    finally:
        if live is not None and not _pid_gone(live):
            try:
                os.kill(live, signal.SIGCONT)
            except ProcessLookupError:
                pass
        if run is not None:
            _relay_stop(run)
        _drop_spec_dir(tmp)


@case("relay", "live_answer_after_exit")
def _relay_live_answer_after_exit():
    # the child writes 2 MB of TUI text, then a query, and exits at once. The run's own worker is
    # stopped (SIGSTOP, by its pid) until the child has exited and been reaped, so the answer comes
    # after the exit however fast or loaded the host is (a precondition on how long the answer took
    # failed on a host with a load average of 100): it is recorded, it is not delivered (no process
    # reads it), and it is not an error. Everything the case started is stopped by pid in the
    # finally (SIGCONT first)
    import base64
    import signal
    from vkitty.snapshot import to_report
    tmp = _spec_tempdir()
    run = None
    live = None
    try:
        query = _apc(b"a=q,i=31,s=1,v=1,f=24;AAAA")
        backlog = _spec_path(tmp, "backlog.bin", _tui_stream(2 * 1000000, 13))
        go = os.path.join(tmp, "go")
        steps = [{"print_pid": True}, {"wait_file": go, "timeout": 60}, {"write_file": backlog},
                 {"write_b64": _b64(query).decode("ascii")}]
        run = _relay_start(tmp, steps, ["--hop", "none", "--respond", "ghostty"])
        tui = os.path.join(run["rec"], "tui.bin")
        _wait_for(lambda: _live_pid(run) is not None and _child_pid_from_rec(run) is not None,
                  "the start event and the child's pid", run=run)
        live = _live_pid(run)
        child = _child_pid_from_rec(run)
        os.kill(live, signal.SIGSTOP)
        _wait_for(lambda: _proc_state(live).startswith("T"), "the worker to stop", run=run)
        _spec_path(tmp, "go", b"")
        _wait_for(lambda: query in _read_bytes(tui), "the query in tui.bin", run=run)
        _wait_for(lambda: _pid_gone(child), "the child to exit and be reaped", timeout=30.0,
                  run=run)
        check(run["proc"].poll() is None, "the relay waits for the stopped worker at the end")
        os.kill(live, signal.SIGCONT)
        _relay_end(run, timeout=60)
        eq(run["rc"], 0, "relay exit status (stderr: %s)" % run["err"][-400:])
        events = _event_lines(run)
        eq([ev for ev in events if ev.get("e") == "error"], [], "no error event")
        answer = b"\x1b_Gi=31;OK\x1b\\"
        resp = [ev for ev in events if ev.get("e") == "resp"]
        eq([base64.b64decode(ev["b64"]) for ev in resp], [answer], "the answer is recorded")
        # one replay serves both checks: the replayed report holds the recorded answers and the
        # warnings, and it must equal the live report
        report = _report_form(to_report(_recording(run).snapshot()))
        eq(report["responses"], [answer.decode("ascii", "backslashreplace")],
           "the replayed report holds the recorded answer")
        check(not any("responses differ" in w for w in report["warnings"]),
              "no responses differ warning")
        eq(report, _report_form(_json_read(os.path.join(run["rec"], "live_final.json"))),
           "the replayed report equals the live report")
    finally:
        if live is not None and not _pid_gone(live):
            try:
                os.kill(live, signal.SIGCONT)
            except ProcessLookupError:
                pass
        if run is not None:
            _relay_stop(run)
        _drop_spec_dir(tmp)


@case("relay", "live_worker_failures")
def _relay_live_worker_failures():
    # (a) the worker is SIGKILLed before the child writes its query: one live error event naming the
    # worker's exit status -9, the relay goes on (the child's later output is recorded), no answer
    # and no live_final.json. (b) the recording's tui.bin is removed before the first output: the
    # worker cannot open it (FileNotFoundError), one live error event starting with that name, the
    # relay goes on, no answer and no live_final.json. Both fail without the worker's error line and
    # the relay's end-of-output check.
    import signal
    query = _apc(b"a=q,i=31,s=1,v=1,f=24;AAAA")
    tmp = _spec_tempdir()
    try:
        # the child stops before it writes: the worker is killed while the child waits, and the
        # child goes on only once the worker is dead (a zombie until the relay reaps it), so the
        # query meets no worker
        run = _relay_start(tmp, [{"print_pid": True}, {"stop_self": True},
                                 {"write_b64": _b64(query + b"AFTER-KILL\r\n").decode("ascii")},
                                 {"sleep": 0.05}],
                           ["--hop", "none", "--respond", "ghostty"])
        try:
            _wait_for(lambda: _child_pid_from_rec(run) is not None and _live_pid(run) is not None,
                      "the child's pid and the live terminal's pid", run=run)
            child, live = _child_pid_from_rec(run), _live_pid(run)
            _wait_for(lambda: _proc_state(child).startswith("T"), "the child to stop", run=run)
            os.kill(live, signal.SIGKILL)
            _wait_for(lambda: _proc_state(live) in ("",) or _proc_state(live).startswith("Z"),
                      "the killed live terminal to die", run=run)
            os.kill(child, signal.SIGCONT)
            _relay_end(run)
        finally:
            _relay_stop(run)
        eq(run["rc"], 0, "(a) relay exit status (stderr: %s)" % run["err"][-400:])
        errors = [ev for ev in _event_lines(run) if ev.get("e") == "error"]
        eq(len(errors), 1, "(a) exactly one error event")
        eq(errors[0]["where"], "live", "(a) the error is the live terminal's")
        check("ended before its report" in errors[0]["msg"] and "exit status -9"
              in errors[0]["msg"],
              "(a) the error names the lost worker and its exit status: %r" % errors[0]["msg"])
        check(b"AFTER-KILL" in _read_bytes(os.path.join(run["rec"], "tui.bin")),
              "(a) the output after the loss is recorded")
        check(not any(ev.get("e") == "resp" for ev in _event_lines(run)), "(a) no answer")
        check(not os.path.exists(os.path.join(run["rec"], "live_final.json")),
              "(a) no live_final.json")
        check(os.path.exists(os.path.join(run["rec"], "done")), "(a) the recording is done")
    finally:
        _drop_spec_dir(tmp)

    tmp = _spec_tempdir()
    try:
        run = _relay_start(tmp,
                           [{"sleep": 0.5},
                            {"write_b64": _b64(b"hello\r\n" + query).decode("ascii")},
                                 {"sleep": 0.05}],
                           ["--hop", "none", "--respond", "ghostty"])
        try:
            _wait_for(lambda: _live_pid(run) is not None, "the start event", run=run)
            os.unlink(os.path.join(run["rec"], "tui.bin"))
            _relay_end(run)
        finally:
            _relay_stop(run)
        eq(run["rc"], 0, "(b) relay exit status (stderr: %s)" % run["err"][-400:])
        events = _event_lines(run)
        errors = [ev for ev in events if ev.get("e") == "error"]
        eq(len(errors), 1, "(b) exactly one error event")
        eq(errors[0]["where"], "live", "(b) the error is the live terminal's")
        check(errors[0]["msg"].startswith("FileNotFoundError"),
              "(b) the worker could not open tui.bin: %r" % errors[0]["msg"])
        check(not any(ev.get("e") == "resp" for ev in events), "(b) no answer")
        check(not os.path.exists(os.path.join(run["rec"], "live_final.json")),
              "(b) no live_final.json")
        check(os.path.exists(os.path.join(run["rec"], "done")), "(b) the recording is done")
    finally:
        _drop_spec_dir(tmp)


@case("relay", "live_protocol")
def _relay_live_protocol():
    # live.py driven directly, as the relay drives it: the lines it reads and writes and the files
    # it keeps. Run 1 feeds three chunks (a query after text; a session with a direct PNG, a chunked
    # image, placeholders and a delete; an APC naming a temporary file, whose bytes a blob line
    # supplies), a mark, a resize and the end. Its answers, the marked and done lines and
    # live_final.json equal those of an in-process terminal fed the same bytes. Run 2 sends a line
    # that is no frame: an error line and exit status 1. Run 3 ends its input before the end line:
    # exit status 3 and no report
    import base64
    import json
    import subprocess
    from vkitty.media import RecordedMedia
    from vkitty.snapshot import to_report
    from vkitty.vt import Terminal
    tmp = _spec_tempdir()
    try:
        query = _apc(b"a=q,i=31,s=1,v=1,f=24;AAAA")
        chunk_a = b"hi\r\n" + query
        chunk_b = _record_stream()
        pixels = bytes([10, 20, 30, 255])
        chunk_c = _apc(b"a=t,i=77,t=t,f=32,s=1,v=1;"
                       + _b64(os.path.join(tmp, "tty-graphics-protocol-live.rgba")))
        blob_key = ["tui", len(chunk_a) + len(chunk_b), 0]
        tui = chunk_a + chunk_b + chunk_c

        def make_rec(name):
            rec = os.path.join(tmp, name)
            os.makedirs(os.path.join(rec, "blobs"))
            with open(os.path.join(rec, "tui.bin"), "wb") as fh:
                fh.write(tui)
            with open(os.path.join(rec, "blobs", "000001.bin"), "wb") as fh:
                fh.write(pixels)
            return rec

        def run_live(rec, lines):
            proc = subprocess.Popen(
                [sys.executable, "-I", "-B", LIVE_PY, "--rec", rec, "--size", "80x24",
                 "--cell", "13x33", "--pad", "4", "--profile", "ghostty-1.3.1", "--hop", "none"],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            payload = b"".join(json.dumps(line, separators=(",", ":")).encode("ascii") + b"\n"
                               for line in lines)
            try:
                out, err = proc.communicate(payload, timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.communicate()
                raise AssertionError("live.py did not exit within 10 s")
            frames = [json.loads(text) for text in out.decode("ascii").splitlines()]
            return proc.returncode, frames, err

        lines = [
            {"e": "data", "ch": "tui", "off": 0, "n": len(chunk_a), "t": 0.1},
            {"e": "mark", "seq": 1},
            {"e": "data", "ch": "tui", "off": len(chunk_a), "n": len(chunk_b), "t": 0.2},
            {"e": "blob", "key": blob_key, "file": "blobs/000001.bin", "err": None},
            {"e": "data", "ch": "tui", "off": len(chunk_a) + len(chunk_b), "n": len(chunk_c),
             "t": 0.3},
            {"e": "resize", "cols": 60, "rows": 20},
            {"e": "end", "t": 1.0},
        ]
        ref = Terminal(80, 24, cell=(13, 33), pad=4, profile="ghostty-1.3.1", hop="none")
        ref.media = RecordedMedia({tuple(blob_key): (pixels, None)}, warnings=ref.warnings)
        ref.feed(chunk_a, "tui", 0.1)
        answers_a = len(ref.responses)
        ref.stats["since_prev_mark"] = {"apc_bytes": 0, "transmit_wire_bytes": 0}
        ref.feed(chunk_b, "tui", 0.2)
        ref.feed(chunk_c, "tui", 0.3)
        ref.resize(60, 20)
        check(not any("no blob" in w for w in ref.warnings), "the reference finds its blob")
        check(ref.snapshot(t=1.0).images[77].rgba == pixels,
              "the reference stores the blob's pixels")
        ref_report = _report_form(to_report(ref.snapshot(t=1.0)))

        rec1 = make_rec("rec1")
        code, frames, err = run_live(rec1, lines)
        eq(code, 0, "run 1: exit status 0 after the end line")
        eq(err, b"", "run 1: no stderr")
        kinds = [frame["r"] for frame in frames]
        eq(kinds, ["resp"] * answers_a + ["marked"] + ["resp"] * (len(ref.responses) - answers_a)
           + ["done"], "run 1: the lines, in order")
        eq(frames[answers_a], {"r": "marked", "seq": 1}, "run 1: the mark is acknowledged")
        got = [base64.b64decode(frame["b64"]) for frame in frames if frame["r"] == "resp"]
        eq(got, ref.responses, "run 1: the answers equal the in-process terminal's")
        eq(_report_form(_json_read(os.path.join(rec1, "live_final.json"))), ref_report,
           "run 1: live_final.json equals the in-process report")

        rec2 = make_rec("rec2")
        code, frames, err = run_live(rec2, [lines[0], {"e": "bogus"}])
        eq(code, 1, "run 2: a line that is no frame: exit status 1")
        eq([frame["r"] for frame in frames], ["resp", "error"], "run 2: an answer, then an error")
        eq(frames[1], {"r": "error", "msg": "ValueError: unknown frame 'bogus'", "t": 0.1},
           "run 2: the error line names the frame")
        check(not os.path.exists(os.path.join(rec2, "live_final.json")),
              "run 2: no live_final.json")

        rec3 = make_rec("rec3")
        code, frames, err = run_live(rec3, [lines[0]])
        eq(code, 3, "run 3: input that ends before the end line: exit status 3")
        eq([frame["r"] for frame in frames], ["resp"], "run 3: only the answer of the first chunk")
        check(not os.path.exists(os.path.join(rec3, "live_final.json")),
              "run 3: no live_final.json")
    finally:
        _drop_spec_dir(tmp)


@case("relay", "gfx_fifo_live")
def _relay_gfx_fifo_live():
    # the gfx FIFO with a live terminal (--gfx-fifo and --respond ghostty): the worker reads gfx.bin
    # as well as tui.bin. A transmission and a query written to the FIFO are both answered to the
    # child, the recording holds the two answers and no error, the worker's report equals the
    # replay, and the worker is gone afterwards (_relay_end checks it)
    import base64
    tmp = _spec_tempdir()
    try:
        steps = [{"print_pid": True}, {"read_until": "ST", "timeout": 10, "save": "a1"},
                 {"read_until": "ST", "timeout": 10, "save": "a2"}, {"sleep": 0.3}]
        run = _relay_start(tmp, steps, ["--hop", "none", "--respond", "ghostty"], gfx=True)
        try:
            transmit = _apc(b"a=t,f=32,s=1,v=1,i=91;" + _b64(bytes(range(4))))
            query = _apc(b"a=q,i=92,s=1,v=1,f=24;AAAA")
            _wait_for(lambda: _child_pid_from_rec(run) is not None, "the child's pid", run=run)
            _wait_for(lambda: os.path.exists(run["gfx"]), "the gfx FIFO", run=run)
            _fifo_write(run["gfx"], transmit)
            _fifo_write(run["gfx"], query)
            _relay_end(run)
        finally:
            _relay_stop(run)
        eq(run["rc"], 0, "relay exit status (stderr: %s)" % run["err"][-400:])
        eq(_read_b64(run, "a1"), _ok(91), "the child reads the answer to the transmission")
        eq(_read_b64(run, "a2"), _ok(92), "the child reads the answer to the query")
        events = _event_lines(run)
        eq([base64.b64decode(ev["b64"]) for ev in events if ev.get("e") == "resp"],
           [_ok(91), _ok(92)], "the recording holds the two answers, in order")
        eq([ev for ev in events if ev.get("e") == "error"], [], "no error event")
        check(_recording(run).snapshot().images.get(91) is not None, "the replay has the image")
        _check_live_equal(run)
    finally:
        _drop_spec_dir(tmp)


@case("relay", "progress_wait")
def _relay_progress_wait():
    # _wait_recorded, which live_worker_stalled waits with, follows progress and not the clock: a
    # file that keeps growing is waited for however long it takes (up to the cap), one that stops
    # growing is given up on `stall` seconds after its last growth, and a file that never ends
    # right is given up on at the cap. A fixed bound failed the relay case on a host with a load
    # average of 60 to 100 on 16 cores, where the same 4 MB took more than 10 s. The clock and the
    # sleep are replaced by a virtual clock, so the case takes no time and no host load can change
    # its result. The file is a function of the virtual time: one 10-byte piece per 0.15 s
    data = b"0123456789" * 20

    def wait(grow_until, stall=1.0, cap=30.0, forever=False):
        now = [0.0]
        naps = []

        def clock():
            return now[0]

        def nap(seconds):
            now[0] += seconds
            naps.append(seconds)

        def read():
            if forever:
                return b"x" * int(now[0] / 0.05)
            return data[:10 * min(len(data) // 10, int(min(now[0], grow_until) / 0.15 + 1e-9))]

        blob = _wait_recorded(read, data, stall=stall, cap=cap, clock=clock, nap=nap)
        return blob, now[0], naps

    blob, t, naps = wait(grow_until=100.0)
    check(blob == data, "steady growth that takes 3 s is waited for although the stall bound "
          "is 1 s: got %d of %d bytes" % (len(blob), len(data)))
    check(2.99 <= t < 3.2, "the wait ends when the file is whole, at 3.0 s: ended at %.2f s" % t)
    blob, t, naps = wait(grow_until=0.6)
    eq(blob, data[:40], "a file that stopped growing at 0.6 s is returned as it was")
    check(1.55 <= t <= 1.75, "the wait ends 1 s (the stall bound) after the last growth, at "
          "1.6 s: ended at %.2f s" % t)
    blob, t, naps = wait(grow_until=0.0, forever=True, cap=2.5)
    check(not blob.endswith(data), "a file that never ends right does not end the wait")
    check(2.5 <= t <= 2.6, "the cap ends a file that keeps growing and never ends right, at "
          "2.5 s: ended at %.2f s" % t)
    blob, t, naps = wait(grow_until=0.0, stall=1.0)
    eq(blob, b"", "a file that never grows is returned as it was")
    check(0.99 <= t <= 1.06, "a file that never grows ends the wait after the stall bound, at "
          "1 s: ended at %.2f s" % t)
    now = [0.0]
    blob = _wait_recorded(lambda: data, data, stall=1.0, cap=2.0,
                          clock=lambda: now[0], nap=lambda s: now.__setitem__(0, now[0] + s))
    eq((blob, now[0]), (data, 0.0), "a file that is whole at the first read costs no wait")


@case("relay", "run_progress_wait")
def _relay_run_progress_wait():
    """The relay cases wait for a run by its progress (_wait_for with run=), not by the clock: a
    run whose recording keeps growing is waited for past the stall bound, one that moves no byte
    and uses no CPU is given up on after the stall bound, and the cap ends a run that moves
    forever. The "run" is a folder (no relay, no pid) that the virtual clock's sleep appends a byte
    to every 0.1 s while it is "alive"; the stall bound is 0.5 s, so the case takes no time."""
    tmp = _spec_tempdir()
    try:
        rec = os.path.join(tmp, "rec")
        os.makedirs(rec)
        run = {"rec": rec}
        grown = os.path.join(rec, "tui.bin")
        now = [0.0]
        last_byte = [0.0]

        def make(alive_until):
            now[0] = 0.0
            last_byte[0] = 0.0
            if os.path.exists(grown):
                os.remove(grown)

            def clock():
                return now[0]

            def nap(seconds):
                now[0] += seconds
                if now[0] < alive_until and now[0] - last_byte[0] >= 0.1 - 1e-9:
                    last_byte[0] = now[0]
                    with open(grown, "ab") as fh:
                        fh.write(b"x")
            return clock, nap

        clock, nap = make(alive_until=1.6)
        _wait_for(lambda: now[0] >= 1.6, "a run that keeps growing", timeout=0.5, run=run,
                  clock=clock, nap=nap)
        check(1.59 <= now[0] < 1.8, "the wait went on past the 0.5 s stall bound while bytes "
              "arrived, to 1.6 s: %.2f s" % now[0])
        clock, nap = make(alive_until=0.55)
        try:
            _wait_for(lambda: False, "a run that stops moving", timeout=0.5, run=run,
                      clock=clock, nap=nap)
        except AssertionError as exc:
            check("no progress for 0.5 s" in str(exc), "the failure says why: %s" % exc)
        else:
            raise AssertionError("a run that moves nothing did not end the wait")
        check(1.0 <= now[0] < 1.2, "given up on 0.5 s after the last byte (0.5 s): %.2f s"
              % now[0])
        clock, nap = make(alive_until=1e9)
        try:
            _wait_for(lambda: False, "a run that moves forever", timeout=0.5, run=run, cap=3.0,
                      clock=clock, nap=nap)
        except AssertionError as exc:
            check("3 s passed" in str(exc), "the cap is named: %s" % exc)
        else:
            raise AssertionError("a run that moves forever did not end the wait at the cap")
        check(3.0 <= now[0] < 3.2, "the cap ended it at 3 s: %.2f s" % now[0])
        clock, nap = make(alive_until=0.0)
        _wait_for(lambda: True, "a run that is done at the first look", timeout=0.5, run=run,
                  clock=clock, nap=nap)
        eq(now[0], 0.0, "nothing is waited for when the condition already holds")
    finally:
        _drop_spec_dir(tmp)


@case("relay", "live_worker_stalled")
def _relay_live_worker_stalled():
    # the relay never blocks on a worker that is far behind: the run's own worker is stopped
    # (SIGSTOP, by its pid) before the child writes 4 MB of TUI text, so about 4000 data lines queue
    # in the relay, far more than a pipe holds. All of the text must reach tui.bin while the worker
    # is stopped: the wait ends as soon as tui.bin ends with all of it and gives up only when the
    # file has not grown for 8 s (a relay that blocks on the worker stops writing), or after 120 s
    # (_wait_recorded; a fixed 10 s bound failed on a host with a load average of 60 to 100); then
    # the worker continues, the end waits for it, and its report equals the replay.
    # Everything the case started is stopped by pid in the finally (SIGCONT first)
    import signal
    tmp = _spec_tempdir()
    run = None
    live = None
    try:
        data = _tui_stream(4 * 1000000, 5)
        path = _spec_path(tmp, "stream.bin", data)
        run = _relay_start(tmp, [{"print_pid": True}, {"sleep": 0.5}, {"write_file": path},
                                 {"sleep": 0.05}], ["--hop", "none", "--respond", "ghostty"])
        _wait_for(lambda: _live_pid(run) is not None, "the start event", run=run)
        live = _live_pid(run)
        os.kill(live, signal.SIGSTOP)
        tui = os.path.join(run["rec"], "tui.bin")
        blob = _wait_recorded(lambda: _read_bytes(tui), data)
        check(blob.endswith(data),
              "while its worker is stopped the relay recorded only %d of %d bytes and then "
              "stopped writing: it blocks on the worker" % (len(blob), len(data)))
        check(run["proc"].poll() is None, "the relay waits for the stopped worker at the end")
        os.kill(live, signal.SIGCONT)
        _relay_end(run, timeout=60)
        eq(run["rc"], 0, "relay exit status (stderr: %s)" % run["err"][-400:])
        eq([ev for ev in _event_lines(run) if ev.get("e") == "error"], [], "no error event")
        _check_live_equal(run)
    finally:
        if live is not None and not _pid_gone(live):
            try:
                os.kill(live, signal.SIGCONT)
            except ProcessLookupError:
                pass
        if run is not None:
            _relay_stop(run)
        _drop_spec_dir(tmp)


@case("relay", "live_client_partial_line")
def _relay_live_client_partial_line():
    # LiveClient.read keeps the last, unfinished line of the worker's output for the next read: a
    # stand-in worker writes half of a resp line, waits 0.2 s, and writes the rest and a done line.
    # The frames are exactly the resp and the done (the half line is not dropped or taken for an
    # error). LIVE_PY is pointed at the stand-in for the call and restored
    import time as _time
    from vkitty import live as live_mod
    tmp = _spec_tempdir()
    saved = live_mod.LIVE_PY
    client = None
    try:
        standin = os.path.join(tmp, "standin_worker.py")
        with open(standin, "w", encoding="ascii") as fh:
            fh.write("import sys, time\n"
                     "sys.stdout.write('{\"r\":\"resp\",\"b64\":\"')\n"
                     "sys.stdout.flush()\n"
                     "time.sleep(0.2)\n"
                     "sys.stdout.write('QUJD\"}\\n{\"r\":\"done\"}\\n')\n"
                     "sys.stdout.flush()\n")
        _SPEC_CREATED.add(("path", standin))
        live_mod.LIVE_PY = standin
        client = live_mod.LiveClient(tmp, 80, 24, (13, 33), 4, "ghostty-1.3.1", "none")
        frames = []
        deadline = _time.monotonic() + 5.0
        while not client.done and _time.monotonic() < deadline:
            frames += client.read()
            _time.sleep(0.01)
        eq(frames, [{"r": "resp", "b64": "QUJD"}, {"r": "done"}],
           "the frames of the stand-in worker")
        check(client.done, "the done line was read")
    finally:
        live_mod.LIVE_PY = saved
        if client is not None:
            client.stop()
        _drop_spec_dir(tmp)


@case("relay", "live_report_time")
def _relay_live_report_time():
    # the worker's final report is the terminal's state at the END time, not at the last data: a
    # kitty profile animation advances with time. The child transmits an image, adds a second frame
    # (3 s long), gives the root a short gap, places the image virtually, starts the animation and
    # sleeps 0.5 s. At the last data event's time frame 1 is shown, at the end's time frame 2
    # (precondition, asserted so the case proves something: the two snapshots differ), and the live
    # report must equal the replay's, which is taken at the end
    tmp = _spec_tempdir()
    try:
        red = _b64(b"\xff\x00\x00\xff")
        green = _b64(b"\x00\xff\x00\xff")
        commands = (_apc(b"a=t,f=32,s=1,v=1,i=5;" + red)
                    + _apc(b"a=f,i=5,s=1,v=1,f=32,z=3000;" + green)
                    + _apc(b"a=a,i=5,r=1,z=100")
                    + _apc(b"a=p,i=5,U=1,c=1,r=1")
                    + _apc(b"a=a,i=5,s=3,v=1"))
        steps = [{"write_b64": _b64(commands).decode("ascii")}, {"sleep": 0.5}]
        run = _relay_once(tmp, steps,
                          ["--hop", "none", "--respond", "ghostty", "--profile", "kitty"])
        eq(run["rc"], 0, "relay exit status (stderr: %s)" % run["err"][-400:])
        rec = _recording(run)
        last_data = [ev for ev in rec.events if ev.get("e") == "data"][-1]
        at_data = rec.replay().snapshot(t=last_data["t"]).images[5].frame
        at_end = rec.snapshot().images[5].frame
        check(at_data != at_end,
              "precondition: frame %d at the last data and frame %d at the end are "
              "the same (lengthen the child's sleep)" % (at_data, at_end))
        _check_live_equal(run)
        live = _json_read(os.path.join(run["rec"], "live_final.json"))
        eq([img["frame"] for img in live["images"] if img["id"] == 5], [at_end],
           "the live report's frame is the one at the end time")
    finally:
        _drop_spec_dir(tmp)


def _replay_cli(*args, timeout=60):
    import subprocess
    return subprocess.run([sys.executable, "-I", REPLAY_PY] + list(args),
                          stdin=subprocess.DEVNULL, capture_output=True, timeout=timeout)


@case("relay", "replay_cli")
def _relay_replay_cli():
    # replay.py on a recording (report and PNG equal the library's), on a byte stream (--stream:
    # equal to an in-process terminal), on a capture with its graphics stream (--capture: the
    # placeholder runs of the capture show the stream's image), exit 1 for a recording with an
    # error event, exit 2 for a usage error
    import subprocess
    from PIL import Image
    from vkitty.snapshot import to_report
    from vkitty.tokens import tmux_wrap
    from vkitty.vt import Terminal
    tmp = _spec_tempdir()
    try:
        stream = _record_stream()
        run = _relay_once(tmp, _stream_steps(stream), ["--hop", "none", "--respond", "ghostty"])
        eq(run["rc"], 0, "relay exit status (stderr: %s)" % run["err"][-400:])
        report = os.path.join(tmp, "report.json")
        png = os.path.join(tmp, "screen.png")
        proc = _replay_cli(run["rec"], "--report", report, "--png", png)
        eq(proc.returncode, 0, "replay of a recording (stderr: %s)" % proc.stderr[-400:])
        eq(_report_form(_json_read(report)), _report_form(to_report(_recording(run).snapshot())),
           "the CLI's report is the library's report")
        eq(Image.open(png).size, (80 * 13 + 8, 24 * 33 + 8), "the picture is the screen")

        stream_path = _spec_path(tmp, "session.bin", stream)
        report2 = os.path.join(tmp, "report2.json")
        proc = _replay_cli("--stream", stream_path, "--size", "80x24", "--report", report2)
        eq(proc.returncode, 0, "replay of a stream (stderr: %s)" % proc.stderr[-400:])
        plain = Terminal(80, 24, hop="none", profile=_DEFAULT_PROFILE)
        plain.feed(stream)
        eq(_report_form(_json_read(report2)), _report_form(to_report(plain.snapshot())),
           "--stream equals the in-process terminal")

        capture = os.path.join(tmp, "capture.ansi")
        rows = [""] * 24
        rows[5] = "   " + _fg_rgb(72) + _ph(0, 0) + _ph(0, 1) + "\x1b[0m"
        rows[6] = "   " + _fg_rgb(72) + _ph(1, 0) + _ph(1, 1) + "\x1b[0m"
        with open(capture, "w", encoding="utf-8") as fh:
            fh.write("\n".join(rows) + "\n")
        gfx = os.path.join(tmp, "gfx.bin")
        with open(gfx, "wb") as fh:
            fh.write(tmux_wrap(_apc(b"a=t,f=32,s=2,v=2,i=72;" + _b64(bytes(range(16)))))
                     + tmux_wrap(_apc(b"a=p,i=72,U=1,c=2,r=2")))
        report3 = os.path.join(tmp, "report3.json")
        png3 = os.path.join(tmp, "capture.png")
        proc = _replay_cli("--capture", capture, "--size", "80x24", "--gfx", gfx,
                           "--report", report3, "--png", png3)
        eq(proc.returncode, 0, "replay of a capture (stderr: %s)" % proc.stderr[-400:])
        got = _json_read(report3)
        eq([(v["x"], v["y"], v["w"], v["image_id"]) for v in got["virtual"]],
           [(3, 5, 2, 72), (3, 6, 2, 72)], "the capture's placeholder runs")
        eq([img["id"] for img in got["images"]], [72], "the stream's image")
        eq(sorted(d["kind"] for d in got["draws"]), ["virtual", "virtual"],
           "both runs are drawn from the image")
        eq(got["missing"], [], "no run is missing its image")
        eq(Image.open(png3).size, (80 * 13 + 8, 24 * 33 + 8), "the capture's picture")

        # a placement without U=1 is a pin: its graphics come from the stream, its place from the
        # stream's own screen (a capture holds no cursor history)
        pin_gfx = os.path.join(tmp, "pin.bin")
        with open(pin_gfx, "wb") as fh:
            fh.write(tmux_wrap(_apc(b"a=t,f=32,s=2,v=2,i=73;" + _b64(bytes(range(16)))))
                     + tmux_wrap(_apc(b"a=p,i=73,c=2,r=2")))
        report4 = os.path.join(tmp, "report4.json")
        png4 = os.path.join(tmp, "pin.png")
        proc = _replay_cli("--capture", capture, "--size", "80x24", "--gfx", pin_gfx,
                           "--report", report4, "--png", png4)
        eq(proc.returncode, 0, "replay of a capture with a pin (stderr: %s)" % proc.stderr[-400:])
        got4 = _json_read(report4)
        eq([(d["kind"], d["image_id"]) for d in got4["draws"]], [("pin", 73)],
           "the pin is drawn from the stream's image")
        eq(Image.open(png4).size, (80 * 13 + 8, 24 * 33 + 8), "the capture's picture with a pin")
        proc = _replay_cli("--stream", stream_path, "--size", "80x24", "--at", "m1")
        eq(proc.returncode, 2, "--at with --stream is a usage error")
        proc = _replay_cli("--capture", capture, "--size", "80x24", "--at", "m1")
        eq(proc.returncode, 2, "--at with --capture is a usage error")

        steps = [{"sleep": 0.05}]
        bad = _relay_start(tmp, steps, ["--hop", "none", "--respond", "none"])
        try:
            _fifo_write(bad["ctl"], b"bogus control line\n")
            _mark(bad, "e1")
            _fifo_write(bad["ctl"], b"quit\n")
            _relay_end(bad)
        finally:
            _relay_stop(bad)
        proc = _replay_cli(bad["rec"])
        eq(proc.returncode, 1, "a recording with an error event exits 1")
        check(b"error relay" in proc.stderr, "the error is named on stderr")
        eq(_replay_cli().returncode, 2, "no input is a usage error")
    finally:
        _drop_spec_dir(tmp)


@case("perf", "relay")
def _perf_relay():
    # 20 MB of APC data (a 1000 x 5000 RGB image in 4096-character chunks) through the relay: the
    # budget is 1 s with --respond none and 2 s with the live terminal; a case asserts twice that.
    # A run is one measurement (see perf/relay_answer): up to three while the host disturbed it
    import base64
    from vkitty import perfclock as pc
    tmp = _spec_tempdir()
    try:
        raw = bytes(15000000)
        b64 = base64.b64encode(raw)
        pieces = [b64[i:i + 4096] for i in range(0, len(b64), 4096)]
        parts = []
        for i, piece in enumerate(pieces):
            if i == 0:
                head = b"a=t,f=24,s=1000,v=5000,i=7,q=2,m=1;"
            elif i == len(pieces) - 1:
                head = b"m=0,q=2;"
            else:
                head = b"m=1,q=2;"
            parts.append(_apc(head + piece))
        stream = b"".join(parts)
        stream_path = _spec_path(tmp, "stream.bin", stream)
        notes = []
        for respond, budget in (("none", 1.0), ("ghostty", 2.0)):
            def measure(respond=respond):
                # one run: from before the relay starts to after it exited, with the relay, its
                # child and (with a live terminal) its worker followed by a ProcSampler
                steps = [{"print_pid": True}, {"write_file": stream_path}, {"sleep": 0.05}]
                run, sampler, elapsed = _relay_run_followed(tmp, steps, respond)
                eq(run["rc"], 0, "--respond %s: relay exit status (stderr: %s)"
                   % (respond, run["err"][-400:]))
                pid_line = len(b"PID %d\r\n" % _child_pid_head(run))
                eq(os.path.getsize(os.path.join(run["rec"], "tui.bin")), pid_line + len(stream),
                   "--respond %s: every byte is recorded (after the child's own pid line)"
                   % respond)
                if respond == "ghostty":
                    live = _json_read(os.path.join(run["rec"], "live_final.json"))
                    check([(img["w"], img["h"]) for img in live["images"] if img["id"] == 7]
                          == [(1000, 5000)], "the live terminal stored the 1000 x 5000 image")
                return elapsed, sampler.clean()
            verdict, made = pc.retry(measure, 2 * budget)
            notes.append(_perf_limit("perf/relay", verdict, "--respond " + respond,
                                     lambda v: "%.2f s" % v, "%.1f s" % (2 * budget)))
        return "20 MB of APC data: " + "; ".join(notes)
    finally:
        _drop_spec_dir(tmp)


# ------------------------------------------------------------ perfclock ---
# The clock the timed cases decide with (tests/lib/vkitty/perfclock.py): a limit is decided only on
# measurements the host did not disturb. These cases check its verdict rules on synthetic samples,
# that blocking counts as the code's own time, that the counters are read outside the timed span,
# that real contention is seen (macOS: background-policy busy loops; Linux: one pinned CPU), and
# that a busy host leaves a limit undecided, never failed.

def _pc_sample(units, wall, clean, value=None):
    """A synthetic Sample: units of work in wall seconds, flagged clean or not."""
    from vkitty.perfclock import Sample
    return Sample(units, wall if value is None else value, wall, wall, 0.0, 0, 0.0, clean)


def _pc_rate_samples(clean_n, clean_rate, busy_n, busy_rate, clean_units=1000, busy_units=1000):
    """clean_n clean samples at clean_rate units per second, then busy_n others at busy_rate."""
    return ([_pc_sample(clean_units, clean_units / clean_rate, True) for _ in range(clean_n)]
            + [_pc_sample(busy_units, busy_units / busy_rate, False) for _ in range(busy_n)])


def _pc_value_samples(clean_n, clean_value, busy_n, busy_value):
    """Samples whose value is the figure a median is taken over."""
    return ([_pc_sample(1, 0.001, True, clean_value) for _ in range(clean_n)]
            + [_pc_sample(1, 0.001, False, busy_value) for _ in range(busy_n)])


def _pc_expect(got, state, basis, share=None, what=""):
    eq((got.state, got.basis), (state, basis), what or "verdict")
    if share is not None:
        check(abs(got.share - share) < 1e-9, "%s: share %r, want %r" % (what or "verdict",
                                                                          got.share, share))


@case("perfclock", "verdicts")
def _perfclock_verdicts():
    from vkitty import perfclock as pc
    # rates, larger is better, limit 10 units per second
    got = pc.rate_verdict(_pc_rate_samples(20, 20.0, 0, 1.0), 10.0)
    _pc_expect(got, pc.PASS, "all", 1.0, "every sample within the limit")
    got = pc.rate_verdict(_pc_rate_samples(10, 20.0, 10, 1.0), 10.0)
    _pc_expect(got, pc.PASS, "clean", 0.5, "all beyond, clean within")
    check(abs(got.value - 20.0) < 1e-6, "the clean rate is the value (%r)" % (got.value,))
    got = pc.rate_verdict(_pc_rate_samples(10, 5.0, 10, 1.0), 10.0)
    _pc_expect(got, pc.FAIL, "clean", 0.5, "all beyond, clean beyond")
    check(abs(got.value - 5.0) < 1e-6, "the failing clean rate is the value (%r)" % (got.value,))
    got = pc.rate_verdict(_pc_rate_samples(8, 20.0, 32, 1.0, 100, 100), 10.0)
    _pc_expect(got, pc.PASS, "clean", 0.2, "a clean share of exactly 0.2 with 8 clean decides")
    got = pc.rate_verdict(_pc_rate_samples(8, 20.0, 8, 1.0, 19, 81), 10.0)
    _pc_expect(got, pc.UNDECIDED, "busy", 0.19, "a clean share of 0.19 does not decide")
    got = pc.rate_verdict(_pc_rate_samples(7, 20.0, 7, 1.0), 10.0)
    _pc_expect(got, pc.UNDECIDED, "busy", 0.5, "7 clean samples do not decide")
    got = pc.rate_verdict([_pc_sample(10, 1.0, False)], 10.0)
    _pc_expect(got, pc.PASS, "all", 1.0, "a rate exactly at the limit passes")
    # medians, smaller is better, limit 2
    got = pc.p50_verdict(_pc_value_samples(200, 1.0, 0, 0.0), 2.0)
    _pc_expect(got, pc.PASS, "all", 1.0, "median of all within")
    got = pc.p50_verdict(_pc_value_samples(100, 1.0, 100, 5.0), 2.0)
    _pc_expect(got, pc.PASS, "clean", 0.5, "median of all beyond, of the clean within")
    got = pc.p50_verdict(_pc_value_samples(100, 3.0, 100, 5.0), 2.0)
    _pc_expect(got, pc.FAIL, "clean", 0.5, "median of the clean beyond")
    check(got.value == 3.0, "the clean median is the value (%r)" % (got.value,))
    got = pc.p50_verdict(_pc_value_samples(100, 1.0, 200, 5.0), 2.0)
    _pc_expect(got, pc.PASS, "clean", None, "100 clean reads decide")
    got = pc.p50_verdict(_pc_value_samples(99, 1.0, 201, 5.0), 2.0)
    _pc_expect(got, pc.UNDECIDED, "busy", None, "99 clean reads do not decide")
    # tries, smaller is better, limit 2
    got = pc.tries_verdict([(5.0, False), (1.5, False), (6.0, False)], 2.0)
    _pc_expect(got, pc.PASS, "all", None, "the second of three tries passes")
    check(got.value == 1.5, "the passing value (%r)" % (got.value,))
    got = pc.tries_verdict([(5.0, False), (6.0, True)], 2.0)
    _pc_expect(got, pc.FAIL, "clean", None, "a clean try beyond fails")
    check(got.value == 6.0, "the failing value is the smallest clean one (%r)" % (got.value,))
    got = pc.tries_verdict([(5.0, False), (4.0, False)], 2.0)
    _pc_expect(got, pc.UNDECIDED, "busy", 0.0, "no clean try is undecided")
    check(got.value == 4.0, "the undecided value is the smallest (%r)" % (got.value,))
    # retry: how many measurements it makes
    for script, calls, state in (([(5.0, False), (1.0, False), (0.5, False)], 2, pc.PASS),
                                 ([(5.0, True), (1.0, False), (0.5, False)], 1, pc.FAIL),
                                 ([(5.0, False), (6.0, False), (7.0, False)], 3, pc.UNDECIDED),
                                 ([(1.0, False), (6.0, False), (7.0, False)], 1, pc.PASS)):
        seen = []

        def measure(script=script, seen=seen):
            seen.append(1)
            return script[len(seen) - 1]
        verdict, made = pc.retry(measure, 2.0)
        eq((len(seen), len(made), verdict.state), (calls, calls, state),
           "retry over %r" % (script,))
    # classify(wall, cpu, switches, offcore)
    check(pc.classify(0.03, 0.0005, 0, 0.0), "blocking is clean: a voluntary wait is not lost time")
    check(not pc.classify(0.03, 0.01, 3, 0.0), "a preempted sample is not clean")
    check(pc.classify(0.03, 0.0295, 1, 0.0), "a short preemption is clean")
    check(not pc.classify(0.03, 0.03, 0, 0.01), "time on efficiency cores is not clean")
    check(pc.classify(0.03, 0.03, 0, None), "unknown off core time with no switch is clean")
    check(not pc.classify(0.03, 0.01, 3, None), "unknown off core time does not hide preemption")
    # ProcSampler over scripted counters (cpu, wait, off core) of one process: its first reading
    # and its latest decide, and a run it could not read twice is judged clean
    def sampled(readings):
        script = iter(readings)
        saved = pc.proc_counters
        pc.proc_counters = lambda _pid: next(script)
        try:
            sampler = pc.ProcSampler()
            for _ in readings:
                sampler.add(4242)
        finally:
            pc.proc_counters = saved
        return sampler
    for readings, known, clean, why in (
            ([(1.0, 0.0, 0.0), (2.0, 0.05, 0.0)], True, True, "waiting 5 % of the CPU time"),
            ([(1.0, 0.0, 0.0), (2.0, 0.5, 0.0)], True, False, "waiting 50 % of the CPU time"),
            ([(1.0, 0.0, 0.0), (2.0, 0.0, 0.5)], True, False, "50 % of the CPU on slow cores"),
            ([(1.0, 0.0, None), (2.0, 0.5, None)], True, False, "waiting, off core unknown"),
            ([(1.0, 0.0, None), (2.0, 0.05, None)], True, True, "off core unknown, little wait"),
            ([(1.0, 0.0, 0.0), (1.0, 0.004, 0.0)], True, True, "no CPU, 4 ms of wait (slack)"),
            ([(1.0, 0.0, 0.0)], False, True, "one reading only: nothing is known")):
        sampler = sampled(readings)
        eq((sampler.known, sampler.clean()), (known, clean), "ProcSampler with " + why)
    eq(pc.ProcSampler().clean(), True, "a sampler that followed nothing is clean")
    return "rate, median and tries verdicts, retry counts, classify and ProcSampler.clean"


@case("perfclock", "blocking_is_work")
def _perfclock_blocking_is_work():
    # a wait is the code's own time: blocking is a voluntary switch, so the sample is clean although
    # most of its wall time was not CPU time, and a regression that waits fails its limit instead
    # of going undecided. The wait is a select with a timeout, as the relay's own waits are:
    # macOS counts a time.sleep as an involuntary switch (measured: one per sleep), which would
    # make the sample look preempted
    import select
    from vkitty import perfclock as pc
    seen = []
    for _ in range(5):
        _, sample = pc.timed(select.select, [], [], [], 0.03)
        seen.append((sample.switches, round(sample.lost, 4), sample.clean))
        if sample.switches == 0 and sample.lost >= 0.025 and sample.clean:
            return "a 30 ms wait is clean (lost %.1f ms)" % (sample.lost * 1000)
    raise AssertionError("no waiting sample was clean with no involuntary switch: %r" % (seen,))


@case("perfclock", "counters_outside_span")
def _perfclock_counters_outside_span():
    # timed reads its counters before it starts the clock and after it stopped it: the median wall
    # time of an empty function is below the time of one pair of counter reads. Reads inside the
    # span would put every wall time above it
    from vkitty import perfclock as pc

    def noop():
        return None
    walls = []
    for _ in range(1000):
        walls.append(pc.timed(noop)[1].wall)
    reads = []
    for _ in range(1000):
        t0 = time.perf_counter()
        pc._switches()
        pc.offcore_seconds()
        reads.append(time.perf_counter() - t0)
    walls.sort()
    reads.sort()
    wall, read = walls[500], reads[500]
    check(wall < read, "the median wall of an empty sample (%.2f us) is not below the median "
          "time of a pair of counter reads (%.2f us)" % (wall * 1e6, read * 1e6))
    return "empty sample %.2f us, counter reads %.2f us" % (wall * 1e6, read * 1e6)


_PC_SPIN = ("import time\nend = time.monotonic() + 1.5\n"
            "while time.monotonic() < end:\n    pass\n")
# the measuring children: argv[1] the library folder, argv[2] a CPU to pin to ("-" for none)
_PC_PIN = ("import os, sys\n"
           "if sys.argv[2] != '-':\n    os.sched_setaffinity(0, {int(sys.argv[2])})\n")
_PC_CHILD_SPIN = (
    "import json, sys, time\n" + _PC_PIN + "sys.path.insert(0, sys.argv[1])\n"
    "from vkitty import perfclock\n"
    "def spin(seconds):\n"
    "    end = time.perf_counter() + seconds\n"
    "    while time.perf_counter() < end:\n        pass\n"
    "rows = []\n"
    "for _ in range(10):\n"
    "    _, s = perfclock.timed(spin, 0.02)\n"
    "    rows.append([s.units, s.value, s.wall, s.cpu, s.lost, s.switches, s.offcore, s.clean])\n"
    "print(json.dumps(rows))\n")
_PC_CHILD_STREAM = (
    "import json, sys\n" + _PC_PIN + "sys.path.insert(0, sys.argv[1])\n"
    "from vkitty import perfclock\n"
    "from vkitty.tokens import Tokenizer\n"
    "with open(sys.argv[3], 'rb') as fh:\n    data = fh.read()\n"
    "tk = Tokenizer(lambda tok: None)\n"
    "rows = []\n"
    "for i in range(0, len(data), 131072):\n"
    "    piece = data[i:i + 131072]\n"
    "    _, s = perfclock.timed(tk.feed, piece, i, units=len(piece))\n"
    "    rows.append([s.units, s.value, s.wall, s.cpu, s.lost, s.switches, s.offcore, s.clean])\n"
    "print(json.dumps(rows))\n")


# seconds: less than _PC_QUANTUM seconds of CPU in _PC_STALL, or running _PC_CAP in all
_PC_STALL, _PC_CAP, _PC_QUANTUM = 60.0, 900.0, 0.25
_STARVED_STATES = "RUD"   # ps states of a process that waits for a CPU (R) or in the kernel (U, D)


def _child_state(pid):
    """The ps state of a process; "?" where ps cannot be run."""
    import subprocess
    try:
        return _proc_state(pid)
    except (OSError, subprocess.SubprocessError):
        return "?"


def _wait_measuring_child(poll, cpu_used, state_of, stall, cap, quantum, clock=time.monotonic,
                          nap=time.sleep):
    """Wait for the measuring child of a contention case and say how the wait ended, as (outcome,
    ps state): "done" (poll() says it finished), "capped" (it kept using CPU for `cap` seconds and
    did not finish), "starved" or "hung". The progress is the child's CPU time (cpu_used(), in
    seconds) in steps of `quantum` seconds, and the wait gives up when it has not moved for `stall`
    seconds; then the ps state tells the two apart. A child under the background policy gets next
    to no CPU while the host has more normal priority work than cores (macOS: state R, priority 4,
    no CPU at all for minutes, or a few milliseconds every ten seconds or so), so a CPU time that
    stands still or creeps does not mean a hung child, and a creep must not count as progress
    (hence the quantum: a child that needs less than a quantum of CPU to finish, and does not in
    `stall` seconds, got none to speak of). A child that is runnable (R), or in an uninterruptible
    wait (U on macOS, D on Linux), is starved, and what the host starves cannot be measured. One
    that sleeps, is stopped, is gone or whose state cannot be read is hung. The state is read once,
    and only when the wait gives up. clock and nap are replaceable for a virtual clock."""
    def stepped():
        used = cpu_used()
        return None if used is None else int(used / quantum)
    start = clock()
    if _wait_progress(lambda: poll() is not None, stepped, stall, cap, clock=clock, nap=nap):
        return "done", ""
    if clock() - start >= cap:
        return "capped", ""
    if poll() is not None:   # it finished while the wait was giving up
        return "done", ""
    state = state_of()
    return ("starved" if state[:1] in _STARVED_STATES and state else "hung"), state


def _wait_measuring_default(poll, cpu_used, state_of, clock=time.monotonic, nap=time.sleep):
    """The wait of the contention cases: _wait_measuring_child with the bounds above."""
    return _wait_measuring_child(poll, cpu_used, state_of, _PC_STALL, _PC_CAP, _PC_QUANTUM,
                                 clock=clock, nap=nap)


def _pc_starved(case, how):
    """The note of a contention case whose measuring child the host gave next to no CPU: the case
    is recorded as undecided (see _perf_limit) and passes, as a limit does that the host left
    undecided."""
    if case not in _PERF_UNDECIDED:
        _PERF_UNDECIDED.append(case)
    return ("UNDECIDED: host busy, the measuring child (%s) got next to no CPU for %d s while it "
            "was runnable or in an uninterruptible wait (the background policy also throttles disk "
            "I/O), so nothing was measured" % (how, _PC_STALL))


def _pc_contention(code, extra_args, sampler=None, wait=None):
    """Run a measuring child on a contended host and return (its Sample rows, how it was made).
    macOS: six busy loops and the child all under the background policy (efficiency cores only).
    Linux: two busy loops and the child pinned to one CPU. Every loop ends at its own deadline,
    1.5 s after it started, and is killed by pid in any case. Returns None where the platform has
    neither. When the host gives the child next to no CPU for _PC_STALL seconds (less than
    _PC_QUANTUM seconds) although it is runnable (R) or in an uninterruptible wait (it is
    starved, which the background policy does on a busy host, I/O included), the rows are None and
    the second value says so: there is nothing to measure, and the caller reports the case as
    undecided. A child that is hung or runs more than _PC_CAP seconds fails. wait(poll, cpu_used,
    state_of) -> (outcome, state) replaces the wait (see _wait_measuring_child) in a case that
    scripts it."""
    import json
    import shutil
    import subprocess
    if sys.platform == "darwin" and shutil.which("taskpolicy"):
        prefix, loops, pin = ["taskpolicy", "-b"], 6, "-"
    elif hasattr(os, "sched_setaffinity"):
        prefix, loops = [], 2
        pin = str(sorted(os.sched_getaffinity(0))[0])
    else:
        return None
    spin_code = _PC_SPIN if pin == "-" else (
        "import os\nos.sched_setaffinity(0, {%s})\n" % pin) + _PC_SPIN
    started = []
    try:
        for _ in range(loops):
            started.append(subprocess.Popen(prefix + [sys.executable, "-I", "-B", "-c", spin_code],
                                            start_new_session=True,
                                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        child = subprocess.Popen(prefix + [sys.executable, "-I", "-B", "-c", code, LIB, pin]
                                 + list(extra_args), stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE)
        started.append(child)
        if sampler is not None:
            sampler.add(child.pid)
        # the child ends with a few lines of output (a pipe holds them): wait for it by its CPU
        # time, so a child that uses CPU slowly is waited for however long it takes. One that gets
        # next to no CPU for _PC_STALL seconds is either starved by the host (runnable or in an
        # uninterruptible wait, which the background policy does on a busy host: the case is
        # undecided) or hung (it fails)
        from vkitty import perfclock
        how = "background policy" if pin == "-" else "one pinned CPU"

        def cpu_used():
            counters = perfclock.proc_counters(child.pid)
            return counters[0] if counters else None

        outcome, state = (wait or _wait_measuring_default)(child.poll, cpu_used,
                                                           lambda: _child_state(child.pid))
        if outcome == "starved":
            return None, "%s, ps state %s" % (how, state)
        if outcome == "hung":
            raise AssertionError("the measuring child is hung: next to no CPU for %d s and neither "
                                 "runnable nor in an uninterruptible wait (ps state %r)"
                                 % (_PC_STALL, state))
        if outcome == "capped":
            raise AssertionError("the measuring child kept running for %d s and did not finish"
                                 % _PC_CAP)
        out, err = child.communicate(timeout=10)
        if child.returncode != 0:
            raise AssertionError("the measuring child failed: %s" % err.decode("utf-8", "replace")
                                 [-400:])
        return json.loads(out.decode("ascii")), how
    finally:
        for proc in started:
            if proc.poll() is None:
                proc.kill()
            proc.wait()


@case("perfclock", "wait_progress")
def _perfclock_wait_progress():
    # _wait_progress bounds a wait by progress and not by the clock: a wait whose progress value
    # keeps changing is waited for however long it takes (up to the cap), one whose progress stops
    # is given up on `stall` seconds after its last change, and the cap ends a wait that
    # progresses and never completes. The measuring children of the contention cases wait with it:
    # a child under the background policy on a host with a load average of 100 took more than the
    # 60 s that a fixed bound gave it (perfclock/contention_seen and busy_host_undecided failed
    # with TimeoutExpired). A child that uses no CPU for the stall bound is not necessarily hung:
    # perfclock/starved_child covers how that ends. The clock and the sleep are virtual, so the
    # case takes no time and no host load can change its result
    now = [0.0]

    def clock():
        return now[0]

    def nap(seconds):
        now[0] += seconds

    def wait(done_at, progress_until, stall=1.0, cap=30.0):
        now[0] = 0.0
        done = _wait_progress(lambda: now[0] >= done_at,
                              lambda: int(min(now[0], progress_until) / 0.15 + 1e-9),
                              stall, cap, clock=clock, nap=nap)
        return done, now[0]

    done, t = wait(done_at=3.0, progress_until=100.0)
    check(done and 2.99 <= t < 3.2, "progress that takes 3 s is waited for although the stall "
          "bound is 1 s: done %r at %.2f s" % (done, t))
    done, t = wait(done_at=100.0, progress_until=0.6)
    check(not done and 1.55 <= t <= 1.75, "a wait whose progress stopped at 0.6 s ends 1 s later, "
          "at 1.6 s: done %r at %.2f s" % (done, t))
    done, t = wait(done_at=100.0, progress_until=100.0, cap=2.5)
    check(not done and 2.5 <= t <= 2.6, "the cap ends a wait that progresses and never "
          "completes, at 2.5 s: done %r at %.2f s" % (done, t))
    done, t = wait(done_at=100.0, progress_until=0.0)
    check(not done and 0.99 <= t <= 1.06, "a wait that never progresses ends at the stall bound, "
          "1 s: done %r at %.2f s" % (done, t))
    done, t = wait(done_at=0.0, progress_until=0.0)
    eq((done, t), (True, 0.0), "a wait that is done at the first look costs no wait")


@case("perfclock", "contention_seen")
def _perfclock_contention_seen():
    # a child that spins 20 ms ten times while busy loops compete for the same cores: every sample
    # is flagged (macOS: its CPU time is on efficiency cores), at least one lost time to
    # preemption, and a ProcSampler following the child calls the run busy
    from vkitty import perfclock as pc
    if not (sys.platform == "darwin" or hasattr(os, "sched_setaffinity")):
        return "no counters on this platform"
    with pc.ProcSampler() as sampler:
        rows, how = _pc_contention(_PC_CHILD_SPIN, [], sampler)
    if rows is None:
        return _pc_starved("perfclock/contention_seen", how)
    samples = [pc.Sample(*row) for row in rows]
    eq(len(samples), 10, "ten samples")
    flagged = [s for s in samples if not s.clean]
    eq(len(flagged), 10, "every sample of a contended child is flagged (%s)"
       % [(round(s.wall, 4), round(s.cpu, 4), s.switches, s.offcore) for s in samples])
    if how == "background policy":
        for s in samples:
            check(s.offcore is not None and s.offcore >= 0.8 * s.cpu,
                  "a sample under the background policy ran on efficiency cores: off core %r, "
                  "cpu %.4f" % (s.offcore, s.cpu))
    lost = [s for s in samples if s.switches > 0 and s.lost >= 0.3 * s.wall
            and not pc.classify(s.wall, s.cpu, s.switches, 0.0)]
    check(lost, "no sample was preempted (switches and lost time): %r"
          % [(round(s.wall, 4), round(s.cpu, 4), s.switches) for s in samples])
    check(sampler.known, "the sampler read the child twice")
    check(not sampler.clean(), "the sampler calls a contended child busy: %r" % (sampler.totals(),))
    return "%s: %d of 10 preempted, sampler wait %.0f ms, off core %s" % (
        how, len(lost), sampler.totals()["wait"] * 1000,
        "n/a" if sampler.totals()["offcore"] is None
        else "%.0f ms" % (sampler.totals()["offcore"] * 1000))


@case("perfclock", "busy_host_undecided")
def _perfclock_busy_host_undecided():
    # the regression case of the clock: the tokenizer over the first 1,000,000 bytes of the
    # perf/tokens stream (the stream is cut from the same generator run, so the first 1,000,000
    # bytes of the 8 MB one are this one) in 131,072-byte pieces, measured by a child on a
    # contended host. A plain rate against the 10 MB/s limit would fail here; the limit is
    # undecided instead
    from vkitty import perfclock as pc
    if not (sys.platform == "darwin" or hasattr(os, "sched_setaffinity")):
        return "no counters on this platform"
    tmp = _spec_tempdir()
    try:
        path = _spec_path(tmp, "tui1m.bin", _tui_stream(1000000, 7))
        rows, how = _pc_contention(_PC_CHILD_STREAM, [path])
    finally:
        _drop_spec_dir(tmp)
    if rows is None:
        return _pc_starved("perfclock/busy_host_undecided", how)
    samples = [pc.Sample(*row) for row in rows]
    rate = sum(s.units for s in samples) / sum(s.wall for s in samples)
    check(rate < 10e6, "the tokenizer reached %.1f MB/s on a contended host (%s), so the plain "
          "limit of 10 MB/s would not fail here: add contention to this case, never drop the check"
          % (rate / 1e6, how))
    verdict = pc.rate_verdict(samples, 10e6)
    eq(verdict.state, pc.UNDECIDED, "the verdict of a contended run (clean %d of %d samples)"
       % (sum(1 for s in samples if s.clean), len(samples)))
    return "%s: %.1f MB/s, undecided (clean %d of %d samples)" % (
        how, rate / 1e6, sum(1 for s in samples if s.clean), len(samples))


@case("perfclock", "undecided_reported")
def _perfclock_undecided_reported():
    # _perf_limit turns a verdict into a note or a failure: an undecided limit passes with a note
    # that says so and is recorded once for the summary line; a failed one raises
    from vkitty import perfclock as pc
    saved = list(_PERF_UNDECIDED)
    del _PERF_UNDECIDED[:]
    try:
        busy = pc.Verdict(pc.UNDECIDED, 1.5, "busy", 0.1)
        note = _perf_limit("perf/x", busy, "tokenizer", lambda v: "%.1f MB/s" % v, "10 MB/s")
        check("UNDECIDED" in note and "host busy" in note, "the undecided note: %r" % note)
        _perf_limit("perf/x", busy, "tokenizer", lambda v: "%.1f MB/s" % v, "10 MB/s")
        eq(_PERF_UNDECIDED, ["perf/x"], "an undecided case is recorded once")
        failed = pc.Verdict(pc.FAIL, 7.5, "clean", 0.5)
        try:
            _perf_limit("perf/y", failed, "tokenizer", lambda v: "%.1f MB/s" % v, "10 MB/s")
        except AssertionError as exc:
            check("10 MB/s" in str(exc) and "7.5 MB/s" in str(exc), "the failure text: %s" % exc)
        else:
            raise AssertionError("a failed verdict did not raise")
        eq(_PERF_UNDECIDED, ["perf/x"], "a failed limit is not recorded as undecided")
        passed = pc.Verdict(pc.PASS, 12.0, "all", 1.0)
        note = _perf_limit("perf/z", passed, "tokenizer", lambda v: "%.1f MB/s" % v, "10 MB/s")
        check("all samples" in note, "the pass note on all samples: %r" % note)
        passed = pc.Verdict(pc.PASS, 12.0, "clean", 0.4)
        note = _perf_limit("perf/z", passed, "tokenizer", lambda v: "%.1f MB/s" % v, "10 MB/s")
        check("clean samples" in note and "40 %" in note, "the pass note on clean ones: %r" % note)
        eq(_PERF_UNDECIDED, ["perf/x"], "a passing limit is not recorded")
        eq(_perf_summary(["perf/a", "perf/b"]),
           "2 timed cases undecided (host busy): perf/a, perf/b", "the summary line")
    finally:
        _PERF_UNDECIDED[:] = saved
    return "undecided note, failure text, pass notes and the summary line"


@case("perfclock", "relay_reads_gated")
def _perfclock_relay_reads_gated():
    # A read of the relay takes a few tens of microseconds, less than the allowance of one sample,
    # so a read alone cannot show that the host disturbed it, and the timed relay case judges the
    # whole in-process run with a ProcSampler of this process instead: when the run was disturbed,
    # no read counts. This case fixes that wiring on any host by replacing the sampler with a
    # scripted one that answers as told: one sampler per run, following this process, running over
    # the relay run, and the reads' flags cleared exactly when it calls the run disturbed
    import vkitty.perfclock as pcmod
    real = pcmod.ProcSampler
    made = []

    class Scripted:
        verdict = None      # what clean() answers in this leg
        known = True

        def __init__(self, interval=0.02):
            self.pids, self.entered, self.exited = [], 0, 0
            made.append(self)

        def add(self, pid):
            self.pids.append(pid)

        def __enter__(self):
            self.entered += 1
            return self

        def __exit__(self, *_exc):
            self.exited += 1
            return False

        def clean(self):
            return Scripted.verdict

    tmp = _spec_tempdir()
    notes = []
    try:
        pcmod.ProcSampler = Scripted
        for leg, verdict in (("disturbed", False), ("clean", True)):
            del made[:]
            Scripted.verdict = verdict
            samples, rc, rec, recorded, size = _relay_read_samples(
                tmp, _tui_stream(150000, 7), "none")
            eq(rc, 0, "%s run: the relay exit status" % leg)
            eq(recorded, size, "%s run: every byte of the stream is recorded" % leg)
            eq(len(made), 1, "one sampler follows each relay run (%s run)" % leg)
            eq(made[0].pids, [os.getpid()], "the sampler follows this process (%s run)" % leg)
            eq((made[0].entered, made[0].exited), (1, 1),
               "the sampler runs over the relay run (%s run)" % leg)
            check(len(samples) >= 20, "the %s run made %d reads, want at least 20"
                  % (leg, len(samples)))
            clean = sum(1 for s in samples if s.clean)
            if verdict:
                check(clean > 0, "a run the sampler finds clean keeps the reads' own flags "
                      "(0 of %d clean)" % len(samples))
            else:
                eq(clean, 0, "a run the sampler finds disturbed has no clean read "
                   "(%d of %d clean)" % (clean, len(samples)))
            notes.append("%s run: %d of %d reads clean" % (leg, clean, len(samples)))
    finally:
        pcmod.ProcSampler = real
        _drop_spec_dir(tmp)
    return "; ".join(notes)


@case("perfclock", "counter_formulas")
def _perfclock_counter_formulas():
    # The counters decide every timed limit, and a wrong formula only turns a limit into one that
    # can never fail, so no timing case would notice. This case replaces the kernel's answer
    # (perfclock._v6) with a scripted rusage_info_v6 of fixed tick values and asserts the three
    # formulas exactly, on any host: CPU is user + system, off core time is the CPU that did not run
    # on performance cores (user_p + system_p), and the wait is the runnable time not spent running.
    # The tick is a quarter second so that every figure is exact
    import types
    import vkitty.perfclock as pcmod
    saved = (pcmod._libc, pcmod._tick, pcmod._v6)
    fake = [None]
    pcmod._libc, pcmod._tick, pcmod._v6 = object(), 0.25, lambda _pid: fake[0]
    try:
        # user 100 + system 50 = 150 ticks of CPU, 60 + 20 = 80 of them on performance cores, 400
        # ticks runnable: CPU 37.5 s, off core 70 ticks = 17.5 s, wait 400 - 150 ticks = 62.5 s
        fake[0] = types.SimpleNamespace(user=100, system=50, user_p=60, system_p=20, runnable=400)
        eq(pcmod.offcore_seconds(), 17.5, "offcore_seconds: (user + system) - (user_p + system_p)")
        eq(pcmod.proc_counters(1), (37.5, 62.5, 17.5),
           "proc_counters: (cpu, runnable - cpu, cpu - performance core time)")
        # all on performance cores: no off core time at all
        fake[0] = types.SimpleNamespace(user=100, system=50, user_p=100, system_p=50, runnable=400)
        eq(pcmod.offcore_seconds(), 0.0, "all CPU on performance cores is not off core")
        eq(pcmod.proc_counters(1)[2], 0.0, "all CPU on performance cores: no off core time")
        # all on efficiency cores: all of it
        fake[0] = types.SimpleNamespace(user=100, system=50, user_p=0, system_p=0, runnable=400)
        eq(pcmod.offcore_seconds(), 37.5, "all CPU on efficiency cores is all off core")
        eq(pcmod.proc_counters(1)[2], 37.5, "all CPU on efficiency cores: all off core")
        # the two parts are summed, not one of them: user alone and system alone differ
        fake[0] = types.SimpleNamespace(user=100, system=50, user_p=0, system_p=50, runnable=400)
        eq(pcmod.proc_counters(1), (37.5, 62.5, 25.0), "user and system are both counted")
        # a wait never goes below zero (runnable time under the CPU time), nor off core time
        fake[0] = types.SimpleNamespace(user=100, system=50, user_p=150, system_p=60, runnable=100)
        eq(pcmod.proc_counters(1), (37.5, 0.0, 0.0), "wait and off core time are not negative")
        # a process or counters that cannot be read
        fake[0] = None
        eq((pcmod.offcore_seconds(), pcmod.proc_counters(1)), (None, None),
           "a process that cannot be read has no counters")
        # no counters at all (not macOS): the Linux file, then nothing
        pcmod._libc = None
        pcmod.sys = types.SimpleNamespace(platform="linux")
        seen = []

        class Reader:
            def __init__(self, text):
                self.text = text

            def __enter__(self):
                return self

            def __exit__(self, *_exc):
                return False

            def read(self):
                return self.text

        def reading(text):
            def fake_open(path, *_args, **_kwargs):
                seen.append(path)
                if isinstance(text, Exception):
                    raise text
                return Reader(text)
            return fake_open
        pcmod.open = reading("3000000000 500000000 7\n")
        eq(pcmod.proc_counters(321), (3.0, 0.5, None), "schedstat: CPU ns, run delay ns")
        eq(seen, ["/proc/321/schedstat"], "the schedstat file of the process")
        pcmod.open = reading("garbage\n")
        eq(pcmod.proc_counters(321), None, "an unreadable schedstat is no counters")
        pcmod.open = reading(OSError("gone"))
        eq(pcmod.proc_counters(321), None, "a process that is gone is no counters")
        pcmod.sys = types.SimpleNamespace(platform="freebsd")
        eq(pcmod.proc_counters(321), None, "a platform with no counters")
    finally:
        pcmod._libc, pcmod._tick, pcmod._v6 = saved
        pcmod.sys = sys
        if "open" in vars(pcmod):
            del pcmod.open
    # the real counters, once: the CPU time that proc_counters reports for this process grows with
    # the process's own CPU clock (so the tick length is right), on any host
    if pcmod._libc is None and not sys.platform.startswith("linux"):
        return "formulas exact on scripted counters; no real counters on this platform"
    first = pcmod.proc_counters(os.getpid())
    clock0 = time.process_time()
    while time.process_time() - clock0 < 0.05:
        pass
    second = pcmod.proc_counters(os.getpid())
    clock1 = time.process_time()
    grew, spent = second[0] - first[0], clock1 - clock0
    check(0.8 * spent <= grew <= 1.25 * spent,
          "the CPU time of proc_counters grew by %.4f s while the process clock grew by %.4f s"
          % (grew, spent))
    return "formulas exact on scripted counters; real CPU %.1f ms against clock %.1f ms" % (
        grew * 1000, spent * 1000)


@case("perfclock", "starved_child")
def _perfclock_starved_child():
    # Under the background policy a child can get next to no CPU while the host has more normal
    # priority work than cores (macOS: ps state R, priority 4, no CPU at all for minutes, or a few
    # milliseconds every ten seconds), and a CPU counter that stands still or creeps looks like a
    # hung child. This case fixes how the wait for a measuring child ends, on scripted ps states and
    # counters with a virtual clock (no time passes, no host load changes the result): a child that
    # is runnable (or in an uninterruptible wait) and gets less than a quantum of CPU in the stall
    # bound is starved and the case goes undecided; one that sleeps, is stopped, is gone or cannot
    # be read is hung and fails; one that keeps using CPU is waited for up to the cap and then
    # fails; one that finished meanwhile is done
    now = [0.0]

    def clock():
        return now[0]

    def nap(seconds):
        now[0] += seconds

    def wait(state, done_at=1e9, cpu_until=0.0, stall=1.0, cap=30.0, at_recheck=False,
             creep=0.0):
        now[0] = 0.0
        looked, last_poll = [], [None]

        def poll():
            before, last_poll[0] = last_poll[0], now[0]
            if at_recheck:
                # finished only when asked a second time with no nap in between: the wait asks
                # once more as it gives up
                return 0 if before == now[0] else None
            return 0 if now[0] >= done_at else None

        def state_of():
            looked.append(now[0])
            return state
        got = _wait_measuring_child(poll, lambda: min(now[0], cpu_until) + creep * now[0],
                                    state_of, stall, cap, 0.25, clock=clock, nap=nap)
        return got, now[0], looked

    for state in ("R", "R+", "RN", "U", "U+", "D"):
        got, t, looked = wait(state)
        eq(got, ("starved", state), "ps state %r with no CPU is starved" % state)
        check(0.99 <= t <= 1.06, "the starved child is given up on at the stall bound (1 s): "
              "%.2f s" % t)
        eq(len(looked), 1, "the state is read once, when the wait gives up (state %r)" % state)
    for state in ("S", "Ss", "I", "I+", "T", "Z", "", "?"):
        got, t, looked = wait(state)
        eq(got, ("hung", state), "ps state %r with no CPU is hung" % state)
        check(0.99 <= t <= 1.06, "the hung child is given up on at the stall bound (1 s): "
              "%.2f s" % t)
    got, t, _looked = wait("R", cpu_until=0.6)
    eq(got, ("starved", "R"), "a child that stopped using CPU at 0.6 s and is runnable")
    check(1.45 <= t <= 1.6, "the stall bound counts from the last quantum of CPU (at 0.5 s): "
          "%.2f s" % t)
    got, t, _looked = wait("S", cpu_until=0.6)
    eq(got, ("hung", "S"), "a child that stopped using CPU at 0.6 s and sleeps")
    # a starved child still gets a few milliseconds now and then (macOS: a boost every ten
    # seconds or so); that creep is not progress, so the child is starved (or hung) all the same
    got, t, _looked = wait("R", creep=0.05)
    eq(got, ("starved", "R"),
       "a runnable child whose CPU creeps (50 ms per second, quantum 250 ms)")
    check(0.99 <= t <= 1.06, "the creeping child is given up on at the stall bound: %.2f s" % t)
    got, t, _looked = wait("S", creep=0.05)
    eq(got, ("hung", "S"), "a sleeping child whose CPU creeps")
    got, t, looked = wait("S", creep=0.5, done_at=3.0)
    eq((got[0], looked), ("done", []), "a child at half a CPU is progressing: waited for")
    got, t, looked = wait("S", done_at=3.0, cpu_until=100.0)
    eq((got[0], looked), ("done", []), "a child that keeps using CPU is waited for, past the "
       "stall bound, and its state is never asked")
    check(2.99 <= t < 3.2, "waited until it finished: %.2f s" % t)
    got, t, _looked = wait("R", cpu_until=100.0, cap=2.5)
    eq(got[0], "capped", "a child that keeps using CPU and does not finish ends at the cap")
    check(2.5 <= t <= 2.6, "the cap ends it at 2.5 s: %.2f s" % t)
    got, t, _looked = wait("R", done_at=0.0)
    eq((got[0], t), ("done", 0.0), "a child that is done at the first look costs no wait")
    # the shipped bounds (60 s without a quarter second of CPU, 900 s in all), on the same virtual
    # clock, in steps of a second: a child that creeps along at 1 ms of CPU per second (about what
    # the background policy gave a child in the measured runs) is starved after 60 s if it is
    # runnable and hung if it is not, a child that uses half a CPU and never finishes ends at 900 s,
    # and one that finishes is waited for
    def second(_seconds):
        now[0] += 1.0
    for state, outcome in (("R", "starved"), ("S", "hung")):
        now[0] = 0.0
        got = _wait_measuring_default(lambda: None, lambda: 0.001 * now[0], lambda: state,
                                      clock=clock, nap=second)
        eq(got, (outcome, state), "the shipped bounds: a creeping child in state %r" % state)
        check(59.9 <= now[0] <= 61.1, "given up on after 60 s: %.2f s" % now[0])
    now[0] = 0.0
    got = _wait_measuring_default(lambda: None, lambda: 0.5 * now[0], lambda: "R", clock=clock,
                                  nap=second)
    eq(got[0], "capped", "the shipped bounds: a child using half a CPU never finishes")
    check(899.9 <= now[0] <= 901.1, "ended at the 900 s cap: %.2f s" % now[0])
    now[0] = 0.0
    got = _wait_measuring_default(lambda: 0 if now[0] >= 200.0 else None,
                                  lambda: 0.005 * now[0], lambda: "R", clock=clock, nap=second)
    eq(got[0], "done", "the shipped bounds: a child at half a percent of a CPU is waited for")
    # a child that finishes in the very moment the wait gives up is done, not hung or starved
    # (its ps state is empty once it is gone)
    got, _t, looked = wait("", at_recheck=True)
    eq((got[0], looked), ("done", []), "a child that finished as the wait gave up is done")

    # the glue: _pc_contention turns the outcome into a return value or an error. It starts a real
    # child and its busy loops, which its own cleanup kills at once; the wait is the scripted one
    if not (sys.platform == "darwin" or hasattr(os, "sched_setaffinity")):
        return "outcomes on scripted ps states; no contention on this platform"
    asked = []

    def scripted(outcome):
        def waiter(poll, cpu_used, state_of):
            asked.append((poll(), isinstance(state_of(), str)))
            return outcome
        return waiter
    rows = "print('[[1]]')"
    got = _pc_contention(rows, [], wait=scripted(("starved", "R")))
    check(got[0] is None and isinstance(got[1], str) and "ps state R" in got[1],
          "a starved child gives no rows and its state: %r" % (got,))
    eq(asked, [(None, True)], "the wait is given the child's poll and its state")
    for outcome, words in ((("hung", "S"), ("hung", "'S'")), (("capped", "R"), ("900",))):
        try:
            _pc_contention(rows, [], wait=scripted(outcome))
        except AssertionError as exc:
            check(all(word in str(exc) for word in words),
                  "the failure for %r names %r: %s" % (outcome, words, exc))
        else:
            raise AssertionError("a %s measuring child did not fail the case" % outcome[0])

    # the state the glue reads is the measuring child's own: stopped (SIGSTOP) it reads T, which a
    # busy loop (running) or the interpreter running this case (not stopped) never does
    import signal
    import subprocess
    sleeper = "import time\ntime.sleep(60)"
    seen = []

    def stopper(poll, cpu_used, state_of):
        pid = poll.__self__.pid
        os.kill(pid, signal.SIGSTOP)
        state = ""
        for _ in range(200):
            state = state_of()
            if state.startswith("T"):
                break
            time.sleep(0.02)
        seen.append((state, _proc_state(os.getpid()), _proc_state(pid)))
        return ("starved", state)
    got = _pc_contention(sleeper, [], wait=stopper)
    check(seen and seen[0][0].startswith("T"),
          "the state the glue reads for a stopped measuring child starts with T: %r" % (seen,))
    check(seen[0][1][:1] in "RSU" and not seen[0][1].startswith("T"),
          "this case's own interpreter is not stopped: %r" % (seen,))
    check("ps state T" in got[1], "the state reaches the return value: %r" % (got,))
    # ps cannot be run: the state reads "?", which is neither runnable nor waiting in the kernel,
    # so the wait calls the child hung and the case fails (it must not pass as undecided)
    real_proc_state = globals()["_proc_state"]
    try:
        for exc in (OSError("no ps"), subprocess.SubprocessError("ps failed"),
                    subprocess.TimeoutExpired("ps", 1)):
            def broken(_pid, exc=exc):
                raise exc
            globals()["_proc_state"] = broken
            eq(_child_state(os.getpid()), "?",
               "_child_state when ps raises %s" % type(exc).__name__)
        globals()["_proc_state"] = broken
        try:
            _pc_contention(sleeper, [], wait=lambda poll, cpu_used, state_of: _wait_measuring_child(
                poll, cpu_used, state_of, 0.3, 30.0, 0.25))
        except AssertionError as exc:
            check("hung" in str(exc) and "'?'" in str(exc),
                  "the failure names a hung child and the state '?': %s" % exc)
        else:
            raise AssertionError("a measuring child whose state cannot be read did not fail")
    finally:
        globals()["_proc_state"] = real_proc_state
    eq(_child_state(2 ** 22 + 12345), "", "_child_state of a process that does not exist")
    check(_child_state(os.getpid())[:1] in "RSU", "_child_state of this process is a ps state")

    # the two contention cases turn a starved child into an undecided note and not a failure
    saved = (_pc_contention, list(_PERF_UNDECIDED))
    del _PERF_UNDECIDED[:]
    globals()["_pc_contention"] = lambda *_args, **_kwargs: (None, "background policy")
    try:
        for run_case in (_perfclock_contention_seen, _perfclock_busy_host_undecided):
            note = run_case()
            check(note.startswith("UNDECIDED") and "no CPU" in note,
                  "the note of %s for a starved child: %r" % (run_case.__name__, note))
        eq(_PERF_UNDECIDED, ["perfclock/contention_seen", "perfclock/busy_host_undecided"],
           "both cases are recorded for the summary line")
        eq(_perf_summary(_PERF_UNDECIDED), "2 timed cases undecided (host busy): "
           "perfclock/contention_seen, perfclock/busy_host_undecided", "the summary line")
    finally:
        globals()["_pc_contention"] = saved[0]
        _PERF_UNDECIDED[:] = saved[1]
    return "starved, hung, capped and done outcomes; both contention cases go undecided"


@case("perfclock", "relay_followed")
def _perfclock_relay_followed():
    # Which processes the relay cases follow decides whether a starved child or worker is counted
    # as disturbed (the run goes undecided) or as clean (a slow run fails): the relay itself, its
    # child by the pid line the child prints first, and with a live terminal its worker by the
    # start event. perf/relay and perf/relay_answer both run through _relay_run_followed. This case
    # runs it for real with a scripted sampler that records every pid it is told to follow and that
    # lets the child go on only once all of them were given (the child waits for a file, so no
    # clock decides when), and compares them with the run's own pids
    import vkitty.perfclock as pcmod
    real = pcmod.ProcSampler
    made = []

    class Scripted:
        expect = 0
        gate = None

        def __init__(self, interval=0.02):
            self.pids, self.entered, self.exited = [], 0, 0
            made.append(self)

        def add(self, pid):
            self.pids.append(pid)
            if len(self.pids) == Scripted.expect:
                with open(Scripted.gate, "wb"):
                    pass

        def __enter__(self):
            self.entered += 1
            return self

        def __exit__(self, *_exc):
            self.exited += 1
            return False

        def clean(self):
            return True

    tmp = _spec_tempdir()
    notes = []
    try:
        pcmod.ProcSampler = Scripted
        for respond, expect in (("ghostty", 3), ("none", 2)):
            del made[:]
            Scripted.expect = expect
            Scripted.gate = os.path.join(tmp, "followed-" + respond)
            steps = [{"print_pid": True}, {"wait_file": Scripted.gate, "timeout": 60}]
            run, sampler, elapsed = _relay_run_followed(tmp, steps, respond)
            eq(len(made), 1, "--respond %s: one sampler follows the run" % respond)
            eq((sampler.entered, sampler.exited), (1, 1),
               "--respond %s: the sampler runs over the relay run" % respond)
            relay, child, worker = run["proc"].pid, _child_pid_head(run), _live_pid(run)
            check(child is not None and child != relay,
                  "--respond %s: the child printed its pid (%r, relay %r)"
                  % (respond, child, relay))
            if respond == "ghostty":
                check(worker is not None and worker not in (relay, child),
                      "--respond ghostty: the start event names the worker (%r)" % (worker,))
                want = sorted([relay, child, worker])
            else:
                eq(worker, None, "--respond none: there is no live terminal")
                want = sorted([relay, child])
            eq(sorted(sampler.pids), want, "--respond %s: the sampler follows the relay (%d), its "
               "child (%r)%s, each once, and nothing else" % (
                   respond, relay, child, " and its worker (%r)" % (worker,)
                   if respond == "ghostty" else ""))
            eq(run["rc"], 0, "--respond %s: relay exit status (stderr: %s)"
               % (respond, run["err"][-400:]))
            check(isinstance(elapsed, float) and elapsed > 0, "the run's own elapsed time")
            notes.append("--respond %s follows %d processes" % (respond, expect))
    finally:
        pcmod.ProcSampler = real
        _drop_spec_dir(tmp)
    return "; ".join(notes)


# ------------------------------------------------------------------ meta ---
# Checks on the harness's own files: they read the sources, so they need no emulator.

REPO_ROOT = os.path.dirname(HERE)
VK_DIR = os.path.join(HERE, "lib", "vkitty")
# every Python file that is run as a program (python -I FILE): each must stop the interpreter
# writing bytecode into the repository tree before it imports the package
ENTRY_POINTS = (
    os.path.join(HERE, "vkitty_spec.py"),
    os.path.join(VK_DIR, "relay.py"),
    os.path.join(VK_DIR, "live.py"),
    os.path.join(VK_DIR, "replay.py"),
    os.path.join(VK_DIR, "checks.py"),
    os.path.join(VK_DIR, "grid_tmux.py"),
    os.path.join(VK_DIR, "battery.py"),
    os.path.join(VK_DIR, "testchild.py"),
    os.path.join(VK_DIR, "tools", "gen_widths.py"),
    os.path.join(VK_DIR, "tools", "subset_fonts.py"),
)


def _read_source(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read().splitlines()


# ------------------------------------------------------------- ghostty 1.4.0 ---
# The ghostty-1.4.0 profile (Ghostty v1.4.0, released 2026-10-27) against ghostty-1.3.1. Each case
# runs the same bytes under both profiles and asserts the difference, so a case fails when the 1.4.0
# behavior is missing (it then equals 1.3.1) and when 1.3.1 changed (it then equals 1.4.0).

_G131, _G140 = "ghostty-1.3.1", "ghostty-1.4.0"


def _tok14(data, v14, **kw):
    from vkitty import tokens
    out = []
    tk = tokens.Tokenizer(out.append, v14=v14, **kw)
    tk.feed(data)
    tk.finish()
    return [(t.kind, t.payload) for t in out]


@case("g140", "c0_executed")
def _g140_c0_executed():
    """stream.zig handleCodepoint: 1.4.0 executes every C0 control (0x10 to 0x1F, apart from ESC)
    and ignores the C1 code points that UTF-8 decoding produces (U+0080 to U+009F); 1.3.1 prints
    both as cells. The text around them is the same, so only the controls differ."""
    from vkitty import tokens
    data = b"a\x10b\x1fc\xc2\x85d\x7fe"
    old, new = _tok14(data, False), _tok14(data, True)
    check((tokens.EXEC, 0x10) not in old and (tokens.PRINT, "a\x10b\x1fc\x85d\x7fe") in old,
          "1.3.1 prints the controls: %r" % (old,))
    eq(new, [(tokens.PRINT, "a"), (tokens.EXEC, 0x10), (tokens.PRINT, "b"), (tokens.EXEC, 0x1F),
             (tokens.PRINT, "cd\x7fe")], "1.4.0 executes them and drops the C1 character")
    for what, slow in (("fast", False), ("slow", True)):
        eq(_tok14(data, True, _force_slow=slow), new, "%s path equals the other" % what)
    for profile, want in ((_G131, "a\x10b\x1fc\x85d\x7fe"), (_G140, "abcd\x7fe")):
        t = _kterm(12, 2, profile=profile)
        t.feed(data)
        eq(t.snapshot().text()[0].rstrip(), want, "%s: the row" % profile)
        eq(t.snapshot().cursor[0], len(want), "%s: the cursor follows the printed cells" % profile)
    # a control in the middle of a UTF-8 character ends it, as before
    check(_tok14(b"\xe4\x1f\xb8", True) == _tok14(b"\xe4\x1f\xb8", True, _force_slow=True),
          "a control inside a character: fast and slow paths agree")


@case("g140", "can_sub_discard")
def _g140_can_sub_discard():
    """Parser and stream.zig apc_end/osc: 1.4.0 throws away an APC or OSC that CAN or SUB canceled
    or that a C1 control other than ST aborted (the handler runs it only when terminated is true,
    and ESC and 0x9C terminate); 1.3.1 runs the partial string. An APC ended by ESC runs in both."""
    from vkitty import tokens
    image = b"\x1b_Ga=t,f=24,s=1,v=1,i=5;AAAA"
    for ender, stored_131, stored_140 in ((b"\x18", True, False), (b"\x1a", True, False),
                                          (b"\x9b", True, False), (b"\x1b[0m", True, True),
                                          (b"\x1b\\", True, True), (b"\x9c", True, True)):
        for profile, stored in ((_G131, stored_131), (_G140, stored_140)):
            t = _kterm(10, 2, profile=profile)
            t.feed(image + ender)
            eq(sorted(t.snapshot().images), [5] if stored else [],
               "%s: an APC ended by %r %s" % (profile, ender, "runs" if stored else "is discarded"))
    for ender in (b"\x18", b"\x1a"):    # (0x9B is OSC payload: the OSC row of the table keeps it)
        osc = b"\x1b]0;t" + ender + b"z"
        old, new = _tok14(osc, False), _tok14(osc, True)
        check(any(kind == tokens.OSC for kind, _ in old), "1.3.1 dispatches the OSC: %r" % (old,))
        check(not any(kind == tokens.OSC for kind, _ in new), "1.4.0 drops the OSC: %r" % (new,))
    # the cut is still counted, so the interleaving checks see it under both profiles
    for profile in (_G131, _G140):
        t = _kterm(10, 2, profile=profile)
        t.feed(image + b"\x18")
        eq(t.snapshot().stats["cuts"], 1, "%s: the canceled APC is one cut" % profile)


@case("g140", "dcs_high_bytes")
def _g140_dcs_high_bytes():
    """parse_table.zig: 1.4.0 reads the bytes 0x80 to 0xFF in a DCS string as payload (a UTF-8
    payload used to end the string at 0x9C or open a sequence at 0x9B); 1.3.1 reads them as C1
    controls."""
    from vkitty import tokens
    data = b"\x1bPqab\x9ccd\x1b\\Z"
    old, new = _tok14(data, False), _tok14(data, True)
    eq(old[0], (tokens.DCS, (b"", b"", 0x71, b"ab")), "1.3.1: 0x9C ends the DCS")
    eq(new, [(tokens.DCS, (b"", b"", 0x71, b"ab\x9ccd")), (tokens.PRINT, "Z")],
       "1.4.0: the DCS carries the high bytes and ends at ESC \\")
    for slow in (False, True):
        eq(_tok14(data, True, _force_slow=slow), new, "slow=%s" % slow)
    # a DCS the parser ignores (a colon in the parameters) reads them as payload too
    ignored = b"\x1bP1:2q\x9bxx\x1b\\Z"
    check(_tok14(ignored, False) != _tok14(ignored, True),
          "the ignored DCS differs between versions")
    eq(_tok14(ignored, True), [(tokens.ESC, (b"", 0x5C)), (tokens.PRINT, "Z")],
       "1.4.0: the ignored DCS swallows 0x9B and ends at ESC \\")


def _pair_terms(feed, cols=20, rows=6, **kw):
    """The same bytes fed to a 1.3.1 and a 1.4.0 terminal: (snapshot under 1.3.1, under 1.4.0)."""
    out = []
    for profile in (_G131, _G140):
        t = _kterm(cols, rows, profile=profile, **kw)
        feed(t)
        out.append(t)
    return out


def _runs_missing(snap):
    return sorted((m["x"], m["y"], m["reason"]) for m in snap.missing)


def _stored_image(image_id):
    from vkitty import kgp
    image = kgp.Image(image_id, 0, 1, 1, "rgba")
    image.data = bytes(4)
    return image


@case("g140", "reupload_removes_placements")
def _g140_reupload_removes_placements():
    """graphics_storage.zig addImage and graphics_exec.zig loadAndAddImage: transmitting to an
    image id that exists removes the old image's placements (1.3.1 keeps them and the new pixels
    show in the old places). 1.4.0 does it when the transmission begins, so a chunked transmission
    has dropped the old image and its placements before its last chunk arrives. A user's Ghostty
    1.4.0 then shows blank cells for placeholders of a re-uploaded image until the placement is
    sent again: a pin placement and a virtual one are both gone."""
    pixels = bytes(range(4)) * (13 * 33)

    def feed(t):
        t.feed(_rgba_img(5, 13, 33) + _at(2, 1, "") + _apc(b"a=p,i=5,C=1,p=2"))
        t.feed(_rgba_img(6, 13, 33) + _apc(b"a=p,i=6,U=1,c=1,r=1,p=3"))
        t.feed(_at(5, 3, _fg_rgb(6) + _ph(0, 0)))
        t.feed(_rgba_img(5, 13, 33, pixels) + _rgba_img(6, 13, 33, pixels))
    old, new = _pair_terms(feed)
    s_old, s_new = old.snapshot(), new.snapshot()
    eq(sorted(s_old.images), [5, 6], "1.3.1 stores the new images")
    eq([(d.image_id, d.kind) for d in s_old.draws], [(6, "virtual"), (5, "pin")],
       "1.3.1: both placements survive the retransmission")
    eq(s_old.missing, [], "1.3.1: the placeholder still resolves")
    eq(sorted(s_new.images), [5, 6], "1.4.0 stores the new images")
    eq(s_new.draws, [], "1.4.0: the retransmission removed both placements")
    eq(_runs_missing(s_new), [(5, 3, "no virtual placement")],
       "1.4.0: the placeholder cell shows nothing (no placement)")
    # the transmission begins: the old image and its placements go at the first chunk
    def start(t):
        t.feed(_rgba_img(5, 13, 33) + _apc(b"a=p,i=5,C=1"))
        t.feed(_apc(b"a=t,i=5,f=32,s=1,v=1,m=1;AAAA"))
    old, new = _pair_terms(start)
    eq((sorted(old.snapshot().images), len(old.snapshot().draws)), ([5], 1),
       "1.3.1: the old image and its placement stay while the new one loads")
    eq((sorted(new.snapshot().images), len(new.snapshot().draws)), ([], 0),
       "1.4.0: both went when the transmission began")
    # addImage itself removes the placements of the id it replaces, whatever way the image arrives
    # (the transmission also deleted them when it began; this is the second removal)
    from vkitty import kgp
    storage = kgp.ImageStorage(v14=True)
    storage.add_image(_stored_image(5))
    storage.add_placement(5, 0, kgp.Placement(None, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    storage.add_placement(5, 7, kgp.Placement(kgp.PinRef(0, 0), 0, 0, 0, 0, 0, 0, 0, 0, 0))
    storage.add_image(_stored_image(5))
    eq(sorted(storage.placements), [], "add_image removes the placements of the replaced image")
    keep = kgp.ImageStorage(v14=False)
    keep.add_image(_stored_image(5))
    keep.add_placement(5, 7, kgp.Placement(kgp.PinRef(0, 0), 0, 0, 0, 0, 0, 0, 0, 0, 0))
    keep.add_image(_stored_image(5))
    eq(sorted(keep.placements), [(5, ("e", 7))], "1.3.1 keeps them")
    # an automatic id is not reuse: no deletion
    def auto(t):
        t.feed(_rgba_img(5, 13, 33) + _apc(b"a=p,i=5,C=1") + _apc(b"a=t,f=32,s=1,v=1;AAAAAA=="))
    old, new = _pair_terms(auto)
    eq((len(old.snapshot().draws), len(new.snapshot().draws)), (1, 1),
       "a transmission with no id leaves the placement of image 5")


@case("g140", "delete_rules")
def _g140_delete_rules():
    """graphics_storage.zig delete: d=a/A removes only the placements that are on the screen (a
    pin whose image is wholly in the scrollback stays); d=i/I with a placement id that matches
    nothing frees nothing; d=r/R takes a missing or inverted range as selecting nothing and deletes
    only the images of the range (1.3.1 removed every placement, and parse-rejected an inverted
    range); d=p/P at a cell beside a tall image deletes nothing (1.3.1 compared row-major and
    deleted it)."""
    # d=a: the image has scrolled into history; its rectangle ends above the screen
    def history(t):
        t.feed(_rgba_img(5, 13, 33) + _at(0, 0, "") + _apc(b"a=p,i=5,C=1"))
        t.feed(b"\n" * 6)           # the screen scrolls: the pin is in the scrollback
        t.feed(_apc(b"a=d,d=a"))
    old, new = _pair_terms(history, rows=3)
    eq(sorted(old.active.kitty.placements), [], "1.3.1: d=a removes the placement in history")
    eq(len(new.active.kitty.placements), 1, "1.4.0: d=a keeps a placement that is not on screen")
    # d=A frees only the images of the placements it removed: 6 has no placement and stays
    def freed(t):
        t.feed(_rgba_img(5, 13, 33) + _apc(b"a=p,i=5,C=1") + _rgba_img(6, 13, 33))
        t.feed(_apc(b"a=d,d=A"))
    old, new = _pair_terms(freed)
    eq(sorted(old.active.kitty.images), [], "1.3.1: d=A frees every unused image")
    eq(sorted(new.active.kitty.images), [6], "1.4.0: d=A frees the images of the placements only")
    # d=I,i,p: no placement 9: nothing to free; the image has no placements, so only a match frees
    def narrowed(t):
        t.feed(_rgba_img(5, 13, 33) + _apc(b"a=d,d=I,i=5,p=9"))
    old, new = _pair_terms(narrowed)
    eq((sorted(old.active.kitty.images), sorted(new.active.kitty.images)), ([], [5]),
       "an unmatched placement id frees the unused image only in 1.3.1")
    # ranges
    def ranges(t):
        for i in (1, 2, 3, 9):
            t.feed(_rgba_img(i, 13, 33) + _apc(b"a=p,i=%d,C=1" % i))
        t.feed(_apc(b"a=d,d=r,x=2,y=3"))
        t.feed(_apc(b"a=d,d=r,x=5,y=4"))       # inverted: 1.3.1 rejects it, 1.4.0 selects nothing
        t.feed(_apc(b"a=d,d=r,y=3"))           # no lower bound: 0 to 3
    old, new = _pair_terms(ranges)
    eq(sorted(k[0] for k in old.active.kitty.placements), [], "1.3.1: d=r removes them all")
    eq(sorted(k[0] for k in new.active.kitty.placements), [9],
       "1.4.0: d=r removes the placements of the images 0 to 3 only")
    def range_images(t):
        t.feed(_rgba_img(1, 13, 33) + _rgba_img(2, 13, 33) + _apc(b"a=p,i=2,C=1")
               + _rgba_img(9, 13, 33))
        t.feed(_apc(b"a=d,d=R,x=1,y=5"))
    _old, new = _pair_terms(range_images)
    eq(sorted(new.active.kitty.images), [9], "1.4.0: d=R frees the images 1 to 5, 1 never placed")
    # d=p beside a tall image
    def beside(t):
        t.feed(_rgba_img(5, 13, 99) + _at(2, 0, "") + _apc(b"a=p,i=5,C=1"))
        t.feed(_apc(b"a=d,d=p,x=1,y=2"))       # column 1, row 2: below-left of the image
    old, new = _pair_terms(beside)
    eq((len(old.active.kitty.placements), len(new.active.kitty.placements)), (0, 1),
       "a cell beside the image: deleted by the row-major test of 1.3.1, kept by 1.4.0")
    def inside(t):
        t.feed(_rgba_img(5, 13, 99) + _at(2, 0, "") + _apc(b"a=p,i=5,C=1"))
        t.feed(_apc(b"a=d,d=p,x=3,y=2"))
    old, new = _pair_terms(inside)
    eq((len(old.active.kitty.placements), len(new.active.kitty.placements)), (0, 0),
       "a cell of the image is deleted by both")


def _answers(t):
    return list(t.responses)


@case("g140", "refusals_and_parse")
def _g140_refusals_and_parse():
    """graphics_exec.zig execute and graphics_command.zig: 1.4.0 refuses an image id together with
    an image number for every action, with an answer that names both (1.3.1 knows the check only
    for a transmission and sends nothing); it takes any q (above 1 is quiet), any C (only 1 keeps
    the cursor) and any U (non-zero is virtual), f=0 is RGBA, an unknown f is answered EINVAL:
    unsupported format by the load, and a command whose data is over 65 MiB is dropped."""
    def refuse(t):
        t.feed(_rgba_img(5, 13, 33))
        t.feed(_apc(b"a=p,i=5,I=3,C=1"))
        t.feed(_apc(b"a=d,d=i,i=5,I=3"))
        t.feed(_apc(b"a=t,i=7,I=3,f=24,s=1,v=1;AAAA"))
        t.feed(_apc(b"a=t,i=8,I=3,q=1,f=24,s=1,v=1;AAAA"))     # q=1: an error still answers
    old, new = _pair_terms(refuse)
    eq(_answers(old), [b"\x1b_Gi=5;OK\x1b\\", b"\x1b_Gi=5,I=3;OK\x1b\\"],
       "1.3.1 answers the transmission and places the image, the refusal exists for a transmission")
    eq(_answers(new), [b"\x1b_Gi=5;OK\x1b\\",
                       b"\x1b_Gi=5,I=3;EINVAL: image ID and number are mutually exclusive\x1b\\",
                       b"\x1b_Gi=5,I=3;EINVAL: image ID and number are mutually exclusive\x1b\\",
                       b"\x1b_Gi=7,I=3;EINVAL: image ID and number are mutually exclusive\x1b\\",
                       b"\x1b_Gi=8,I=3;EINVAL: image ID and number are mutually exclusive\x1b\\"],
       "1.4.0 answers each, with both ids")
    eq(sorted(new.snapshot().images), [5], "and the delete and the placement did nothing")
    eq(len(new.snapshot().draws), 0, "the refused placement made no draw")
    # q above 1, f=0, unknown f
    def relaxed(t):
        t.feed(_apc(b"a=t,i=1,f=0,s=1,v=1;AAAAAA=="))            # f=0 is RGBA
        t.feed(_apc(b"a=t,i=2,f=7,s=1,v=1;AAAA"))                # an unknown format
        t.feed(_apc(b"a=t,i=3,f=24,s=1,v=1,q=3;AA"))             # bad data, q=3: silent
        t.feed(_apc(b"a=p,i=1,C=2"))                              # C=2: the cursor moves
        t.feed(_apc(b"a=p,i=1,U=2,c=1,r=1"))                      # U=2: virtual
    old, new = _pair_terms(relaxed)
    eq(sorted(old.snapshot().images), [], "1.3.1 rejects every one of these commands")
    eq(sorted(new.snapshot().images), [1], "1.4.0 stores the f=0 image")
    eq(_answers(new), [b"\x1b_Gi=1;OK\x1b\\", b"\x1b_Gi=2;EINVAL: unsupported format\x1b\\",
                       b"\x1b_Gi=1;OK\x1b\\", b"\x1b_Gi=1;OK\x1b\\"],
       "1.4.0 answers the transmission, the unknown format and the two placements (q=3 is silent)")
    eq(sorted(k[1] for k in new.active.kitty.placements), [("i", 0), ("i", 1)],
       "and both placements exist")
    eq([p.location is None for p in new.active.kitty.placements.values()], [False, True],
       "C=2 made a pin placement, U=2 a virtual one")


@case("g140", "payload_cap")
def _g140_payload_cap():
    """apc.zig defaultMaxBytes: a graphics command whose data is over 65 MiB is dropped whole (the
    parser errors out of memory, the handler ignores the rest), with no answer and no change.
    1.3.1 has no such cap. The bound is exact: 65 MiB of data parses, one byte more does not."""
    from vkitty import kgp
    big = b"a=t,i=1,f=24,s=1,v=1;" + b"A" * (kgp.MAX_APC_BYTES + 1)
    try:
        kgp.parse(big, v14=True)
    except kgp.ParseError as exc:
        check("65" in str(exc) or str(kgp.MAX_APC_BYTES) in str(exc), "the reason names the cap: %s"
              % exc)
    else:
        raise AssertionError("1.4.0 parsed a command with data over the cap")
    eq(kgp.MAX_APC_BYTES, 65 * 1024 * 1024, "the cap is 65 MiB")
    saved = kgp.MAX_APC_BYTES
    kgp.MAX_APC_BYTES = 64
    try:
        edge = b"a=t,i=1,f=24,s=1,v=1;" + b"A" * 64
        eq(kgp.parse(edge, v14=True).wire, 64, "data of exactly the cap parses")
        try:
            kgp.parse(edge + b"A", v14=True)
        except kgp.ParseError:
            pass
        else:
            raise AssertionError("one byte over the cap parsed")
        eq(kgp.parse(edge + b"A" * 4, v14=False).wire, 68, "1.3.1 has no cap")
        t = _kterm(10, 3, profile=_G140)
        t.feed(_apc(b"a=t,i=1,f=24,s=1,v=1;" + b"A" * 68))
        eq((sorted(t.snapshot().images), _answers(t)), ([], []), "the terminal drops the command")
        check(any("kitty graphics protocol error" in w for w in t.warnings), "and says why")
    finally:
        kgp.MAX_APC_BYTES = saved


@case("g140", "query_completes")
def _g140_query_completes():
    """graphics_exec.zig query: 1.4.0 completes the load and discards it, so a query for data that
    cannot be an image (a PNG that is not one, a size that does not match) is answered with the
    error. 1.3.1 loads the bytes and answers OK."""
    def query(t):
        t.feed(_apc(b"a=q,i=31,f=100,s=1,v=1;" + _b64(b"not a png")))
        t.feed(_apc(b"a=q,i=32,f=24,s=2,v=2;" + _b64(b"abc")))
        t.feed(_apc(b"a=q,i=33,f=24,s=1,v=1;" + _b64(b"abc")))
    old, new = _pair_terms(query)
    eq(_answers(old), [b"\x1b_Gi=31;OK\x1b\\", b"\x1b_Gi=32;OK\x1b\\", b"\x1b_Gi=33;OK\x1b\\"],
       "1.3.1 answers OK to all three")
    got = _answers(new)
    check(got[0].startswith(b"\x1b_Gi=31;EINVAL") and got[1].startswith(b"\x1b_Gi=32;")
          and got[1] != b"\x1b_Gi=32;OK\x1b\\" and got[2] == b"\x1b_Gi=33;OK\x1b\\",
          "1.4.0 answers the two bad queries with an error and the good one OK: %r" % (got,))
    eq(sorted(new.snapshot().images), [], "a query stores nothing")


@case("g140", "image_ids_and_eviction")
def _g140_image_ids_and_eviction():
    """graphics_storage.zig nextImageId and evictImageExcept: an image given a number takes the
    lowest free id from 1 (1.3.1: the automatic counter); eviction frees the image with the lowest
    (priority, generation, id), transient images (the N usage hint) first, used before unused
    within a transience, never the id being replaced, and stops as soon as enough bytes are free
    (1.3.1 went on to one more image when the freed bytes only equalled the need); the old image's
    bytes count toward the room for its own replacement."""
    def numbers(t):
        t.feed(_apc(b"a=t,I=5,f=24,s=1,v=1;AAAA") + _apc(b"a=t,I=5,f=24,s=1,v=1;AAAA"))
        t.feed(_apc(b"a=t,f=24,s=1,v=1;AAAA"))
    old, new = _pair_terms(numbers)
    eq(sorted(old.snapshot().images), [2147483647, 2147483648, 2147483649], "1.3.1: counter ids")
    eq(sorted(new.snapshot().images), [1, 2, 2147483647],
       "1.4.0: numbers take 1 and 2, a no-number image the automatic id")
    # eviction: a store of 100 bytes; images of 40 bytes
    def pixels(n):
        return _b64(bytes(n))
    for profile, want_unused in ((_G131, [3, 4]), (_G140, [2, 3, 4])):
        t = _kterm(10, 3, profile=profile, storage_limit=100)
        for i in (1, 2, 3):
            t.feed(_apc(b"a=t,i=%d,f=24,s=10,v=1;" % i + pixels(30)))        # 30 bytes each
        t.feed(_apc(b"a=t,i=4,f=32,s=10,v=1;" + pixels(40)))               # needs exactly 30 freed
        eq(sorted(t.snapshot().images), want_unused, "%s: after the fourth image" % profile)
    # transient first, then unused before used; the replaced id is never evicted
    t = _kterm(10, 3, profile=_G140, storage_limit=100)
    t.feed(_apc(b"a=t,i=1,f=24,s=10,v=1;" + pixels(30)))                       # unused, oldest
    t.feed(_apc(b"a=t,i=2,f=24,s=10,v=1,N=1;" + pixels(30)))                   # transient, newer
    t.feed(_apc(b"a=t,i=3,f=24,s=10,v=1;" + pixels(30)) + _apc(b"a=p,i=3,C=1"))  # used
    t.feed(_apc(b"a=t,i=4,f=24,s=10,v=1;" + pixels(30)))
    eq(sorted(t.snapshot().images), [1, 3, 4], "the transient image goes before the older one")
    t.feed(_apc(b"a=t,i=3,f=24,s=10,v=1;" + pixels(30)))
    eq(sorted(t.snapshot().images), [1, 3, 4],
       "replacing image 3 (30 bytes for 30) needs no room and evicts nothing")
    big = _kterm(10, 3, profile=_G140, storage_limit=100)
    big.feed(_apc(b"a=t,i=1,f=24,s=10,v=2;" + pixels(60)) + _apc(b"a=p,i=1,C=1"))
    big.feed(_apc(b"a=t,i=2,f=24,s=10,v=1;" + pixels(30)))
    big.feed(_apc(b"a=t,i=1,f=24,s=10,v=3;" + pixels(90)))
    eq(sorted(big.snapshot().images), [1], "a replacement evicts the others, never itself")
    eq(big.snapshot().draws, [], "and the old placement went with the old image")


@case("g140", "placement_geometry")
def _g140_placement_geometry():
    """graphics_storage.zig Placement.sourceRect, cellOffset, pixelSize and gridSize: the X and Y
    offsets are kept inside the first cell (1.3.1 keeps any value), the source rectangle is cut to
    the image (1.3.1 passes a crop past the edge on, which stretches the draw), the pixel size
    leaves out the pixels the offset takes from the first cell, and the grid counts the offset
    rounded up."""
    def feed(t):
        t.feed(_rgba_img(5, 26, 66) + _at(1, 1, "") + _apc(b"a=p,i=5,C=1,X=100,Y=100"))
        t.feed(_at(8, 1, "") + _apc(b"a=p,i=5,C=1,x=20,y=60,w=100,h=100"))
        t.feed(_at(12, 1, "") + _apc(b"a=p,i=5,C=1,c=3,X=5"))
    old, new = _pair_terms(feed, cols=20, rows=6)
    d_old = sorted(_draws(old.snapshot()), key=lambda d: d[3])
    d_new = sorted(_draws(new.snapshot()), key=lambda d: d[3])
    # (image, kind, z, col, row, offset x, offset y, src, dest)
    eq(d_old[0][5:7], (100, 100), "1.3.1 keeps the offsets as given")
    eq(d_new[0][5:7], (12, 32), "1.4.0 keeps them inside the 13 x 33 first cell")
    eq(d_old[1][7:9], ((20, 60, 6, 6), (100, 100)),
       "1.3.1: the 6 x 6 pixels left of the crop are stretched to the 100 x 100 asked for")
    eq(d_new[1][7:9], ((20, 60, 6, 6), (6, 6)), "1.4.0: the crop is cut to the 26 x 66 image")
    eq(d_old[2][8], (39, 99), "1.3.1: 3 columns of pixels, the height by the ratio")
    eq(d_new[2][8], (34, 86), "1.4.0: the 5 offset pixels are not part of the size")
    eq(d_new[2][5], 5, "and the offset is kept")
    # the grid: a pixel size of 34 and an offset of 5 fill 3 cells
    from vkitty import kgp
    place = kgp.Placement(None, 5, 0, 0, 0, 0, 0, 3, 0, 0)
    image = kgp.Image(5, 0, 26, 66)
    cols, rows = kgp.grid_size(place, image, new)
    eq((cols, rows), (3, 3), "the grid of 3 columns by the aspect ratio: 34 x 86 plus the offset")
    # a zero grid has no rectangle
    tiny = _kterm(10, 4, profile=_G140, cell=(0, 33))
    place = kgp.Placement(kgp.PinRef(0, 0), 0, 0, 0, 0, 0, 0, 0, 0, 0)
    eq(kgp._rect(tiny, place, image), None, "a placement with no cell width occupies no rectangle")


@case("g140", "cursor_after_image")
def _g140_cursor_after_image():
    """graphics_exec.zig display: after a pin placement without C=1 the cursor goes to the last
    row of the image, in the column after it; when that column is past the right edge it goes to
    column 0 of the next row. The rows it moves through are indexed once each, but never more than
    the rows to the region's bottom plus one screen (1.3.1 indexed every row of the image and
    set the cursor on the last row at the column after the image, clamped)."""
    def feed(t):
        t.feed(_rgba_img(5, 13, 99) + _at(4, 0, "") + _apc(b"a=p,i=5"))      # 3 rows, column 4
    old, new = _pair_terms(feed, cols=10, rows=6)
    eq(old.snapshot().cursor[:2], (5, 2), "1.3.1: column after the image, last row")
    eq(new.snapshot().cursor[:2], (5, 2), "1.4.0: the same when there is room")
    def wide(t):
        t.feed(_rgba_img(5, 26, 33) + _at(8, 0, "") + _apc(b"a=p,i=5"))     # 2 columns, from 8
    old, new = _pair_terms(wide, cols=10, rows=6)
    eq(old.snapshot().cursor[:2], (9, 0), "1.3.1: the column is clamped to the edge")
    eq(new.snapshot().cursor[:2], (0, 1), "1.4.0: past the right edge: column 0 of the next row")
    def tall(t):
        t.feed(_rgba_img(5, 13, 33 * 100) + _at(0, 0, "") + _apc(b"a=p,i=5,r=100"))
        t.feed(b"X")
    old, new = _pair_terms(tall, cols=10, rows=4)
    eq(new.snapshot().cursor[:2], (2, 3), "1.4.0: a 100 row image ends on the last screen row")
    eq(new.active.kitty is not None, True, "(the image is placed)")
    t = _kterm(10, 4, profile=_G140)
    t.feed(_rgba_img(5, 13, 33 * 100) + _at(0, 0, "") + _apc(b"a=p,i=5,r=100,C=1"))
    eq(t.snapshot().cursor[:2], (0, 0), "C=1 keeps the cursor")


@case("g140", "scroll_margins")
def _g140_scroll_margins():
    """graphics_storage.zig scrollMarginsBegin and Terminal.zig scrollUp, scrollDown, index: a
    scroll of a region that is not the whole screen moves the placements that lie wholly inside
    the region with the content, clips the ones it pushes over a margin and deletes the ones
    clipped away; a placement outside or across the region stays. IL and DL leave all of them
    alone. 1.3.1 moved pins with the row operation: into the scrollback at the top, or by the
    erased rows."""
    def feed(t):
        t.feed(b"\x1b[3;8r")                                    # rows 3 to 8
        t.feed(_rgba_img(5, 13, 33) + _at(2, 5, "") + _apc(b"a=p,i=5,C=1"))      # row 5, inside
        t.feed(_rgba_img(6, 13, 33) + _at(3, 0, "") + _apc(b"a=p,i=6,C=1"))      # row 0, outside
        t.feed(_rgba_img(7, 13, 66) + _at(4, 7, "") + _apc(b"a=p,i=7,C=1"))   # rows 7 to 8: across
        t.feed(_rgba_img(9, 13, 66) + _at(6, 6, "") + _apc(b"a=p,i=9,C=1"))   # rows 6 to 7: inside
        t.feed(_rgba_img(8, 13, 33) + _at(5, 2, "") + _apc(b"a=p,i=8,C=1"))      # row 2: top margin
        t.feed(b"\x1b[S")                                       # SU 1
    old, new = _pair_terms(feed, cols=10, rows=10)
    by_image = lambda t: {d[0]: (d[3], d[4], d[7]) for d in _draws(t.snapshot())}
    got_new = by_image(new)
    eq(got_new[6][:2], (3, 0), "1.4.0: a placement outside the region stays")
    eq(got_new[5][:2], (2, 4), "1.4.0: the placement inside moves up one row with the text")
    eq(got_new[7][:2], (4, 7), "1.4.0: a placement across the bottom margin stays")
    eq(got_new[9][:2], (6, 5), "1.4.0: the one wholly inside moves up with the text")
    check(8 not in got_new, "1.4.0: the placement pushed past the top margin is deleted")
    got_old = by_image(old)
    check(got_old != got_new and 5 in got_old, "1.3.1 moved them differently: %r" % (got_old,))
    # a taller placement clipped at the top margin: its source shrinks by the rows scrolled out
    def clip(t):
        t.feed(b"\x1b[3;8r")
        t.feed(_rgba_img(5, 13, 99) + _at(2, 2, "") + _apc(b"a=p,i=5,C=1,r=3"))   # rows 2 to 4
        t.feed(b"\x1b[S")
    _old, new = _pair_terms(clip, cols=10, rows=10)
    draw = _draws(new.snapshot())[0]
    eq((draw[4], draw[7]), (2, (0, 33, 13, 66)), "the top row is clipped off: source from y=33")
    # IL and DL do not move them
    def lines(t):
        t.feed(b"\x1b[3;8r")
        t.feed(_rgba_img(5, 13, 33) + _at(2, 5, "") + _apc(b"a=p,i=5,C=1"))
        t.feed(b"\x1b[3;1H\x1b[L")
    _old, new = _pair_terms(lines, cols=10, rows=10)
    eq(_draws(new.snapshot())[0][4], 5, "insert line leaves the placement alone")
    # reverse index at the top margin and SD move them down
    def down(t):
        t.feed(b"\x1b[3;8r")
        t.feed(_rgba_img(5, 13, 33) + _at(2, 5, "") + _apc(b"a=p,i=5,C=1"))
        t.feed(b"\x1b[3;1H\x1bM\x1b[T")                        # RI at the top margin, then SD
    _old, new = _pair_terms(down, cols=10, rows=10)
    eq(_draws(new.snapshot())[0][4], 7, "reverse index and SD move it down two rows")
    # a relative placement lives with its parent: the parent clipped away takes the child along
    def child(t):
        t.feed(b"\x1b[3;8r")
        t.feed(_rgba_img(8, 13, 33) + _at(5, 2, "") + _apc(b"a=p,i=8,p=1,C=1"))   # top margin row
        t.feed(_rgba_img(9, 13, 33) + _apc(b"a=p,i=9,p=2,P=8,Q=1,C=1"))
        t.feed(b"\x1b[S")
    _old, new = _pair_terms(child, cols=10, rows=10)
    eq(sorted(new.active.kitty.placements), [], "the parent scrolled out of the region: both go")
    # a full-screen scroll keeps the pins' own movement (into the scrollback): both versions agree
    def full(t):
        t.feed(_rgba_img(5, 13, 33) + _at(2, 1, "") + _apc(b"a=p,i=5,C=1"))
        t.feed(b"\x1b[S")
    old, new = _pair_terms(full, cols=10, rows=4)
    eq(_draws(old.snapshot()), _draws(new.snapshot()), "no margins: no difference")


@case("g140", "relative_placements")
def _g140_relative_placements():
    """graphics_exec.zig display and graphics_storage.zig resolveParent, removeOrphans: 1.4.0 takes
    a placement with P= as a relative one: it needs its parent image and placement (ENOPARENT), may
    not be its own parent (EINVAL) or make a cycle (ECYCLE), is not placed at the cursor, and lives
    only as long as its parent chain. The model stores it and never draws it (a known gap). 1.3.1
    ignores P and places the image at the cursor."""
    def feed(t):
        t.feed(_rgba_img(5, 13, 33) + _at(1, 1, "") + _apc(b"a=p,i=5,p=2,C=1"))
        t.feed(_rgba_img(6, 13, 33))
        t.feed(_at(5, 3, "") + _apc(b"a=p,i=6,p=3,P=5,Q=2,H=1,V=1,C=1"))
    old, new = _pair_terms(feed)
    eq(sorted(d[0] for d in _draws(old.snapshot())), [5, 6], "1.3.1: P is ignored, 6 is placed")
    eq(sorted(d[0] for d in _draws(new.snapshot())), [5],
       "1.4.0: the relative placement is not drawn")
    eq(sorted(new.active.kitty.placements), [(5, ("e", 2)), (6, ("e", 3))], "but it is stored")
    check(any("relative placement" in w for w in new.warnings), "and the model says so")
    def refusals(t):
        t.feed(_rgba_img(5, 13, 33) + _apc(b"a=p,i=5,p=2,C=1") + _rgba_img(6, 13, 33))
        t.feed(_apc(b"a=p,i=6,p=3,P=99,C=1"))                    # no such parent image
        t.feed(_apc(b"a=p,i=6,p=3,P=5,Q=77,C=1"))                # no such parent placement
        t.feed(_apc(b"a=p,i=6,p=4,P=7,C=1"))                     # the image 7 does not exist
        t.feed(_apc(b"a=p,i=6,p=6,C=1") + _apc(b"a=p,i=6,p=6,P=6,Q=6,C=1"))   # its own parent
        t.feed(_apc(b"a=p,i=6,p=3,P=5,Q=2,C=1"))                 # a child of 5.2
        t.feed(_apc(b"a=p,i=5,p=2,P=6,Q=3,C=1"))                 # 5.2 under its own child
        t.feed(_apc(b"a=p,i=6,p=8,U=1,P=5,Q=2"))                 # virtual with a parent
    _old, new = _pair_terms(refusals)
    answers = [a.split(b";", 1)[1][:-2].decode() for a in _answers(new)]
    eq(answers[3:], ["ENOPARENT: parent image not found",
                     "ENOPARENT: parent placement not found",
                     "ENOPARENT: parent image not found", "OK",
                     "EINVAL: placement cannot be its own parent", "OK",
                     "ECYCLE: parent chain creates a cycle",
                     "EINVAL: virtual placement cannot refer to a parent"],
       "the answers of the refused and the accepted ones")
    # the chain: the child lives as long as its parent
    def orphan(t):
        t.feed(_rgba_img(5, 13, 33) + _apc(b"a=p,i=5,p=2,C=1") + _rgba_img(6, 13, 33))
        t.feed(_apc(b"a=p,i=6,p=3,P=5,Q=2,C=1") + _apc(b"a=p,i=6,p=4,P=6,Q=3,C=1"))
        t.feed(_apc(b"a=d,d=i,i=5,p=2"))
    old, new = _pair_terms(orphan)
    eq(sorted(new.active.kitty.placements), [], "deleting the root removes its whole chain")
    eq(sorted(new.active.kitty.images), [5, 6], "(and keeps the images of a lowercase delete)")
    def orphan_upper(t):
        t.feed(_rgba_img(5, 13, 33) + _apc(b"a=p,i=5,p=2,C=1") + _rgba_img(6, 13, 33))
        t.feed(_apc(b"a=p,i=6,p=3,P=5,Q=2,C=1") + _apc(b"a=d,d=I,i=5,p=2"))
    _old, new = _pair_terms(orphan_upper)
    eq(sorted(new.active.kitty.images), [],
       "an uppercase delete frees the images the cascade emptied")
    # a retransmission of the parent image removes its placements and so the child
    def retransmit(t):
        t.feed(_rgba_img(5, 13, 33) + _apc(b"a=p,i=5,p=2,C=1") + _rgba_img(6, 13, 33))
        t.feed(_apc(b"a=p,i=6,p=3,P=5,Q=2,C=1") + _rgba_img(5, 13, 33))
    _old, new = _pair_terms(retransmit)
    eq(sorted(new.active.kitty.placements), [],
       "the child of a replaced image's placement goes too")


@case("g140", "placeholder_target")
def _g140_placeholder_target():
    """graphics_storage.zig placeholderTarget: a placeholder without a placement id shows the
    image's virtual placement that PlacementId.preferredOver picks, an external id before an
    internal one and the lowest id first, so the choice does not depend on the order the
    placements were made in (1.3.1: the first one found)."""
    def feed(t):
        t.feed(_rgba_img(5, 39, 33))
        t.feed(_apc(b"a=p,i=5,U=1,c=3,r=1"))            # internal, made first
        t.feed(_apc(b"a=p,i=5,U=1,c=1,r=1,p=7"))        # external 7
        t.feed(_at(2, 1, _fg_rgb(5) + _ph(0, 0)))
    old, new = _pair_terms(feed)
    src_old = [d[7] for d in _draws(old.snapshot())]
    src_new = [d[7] for d in _draws(new.snapshot())]
    eq(src_old, [(0, 0, 13, 33)], "1.3.1: the first virtual placement (3 columns): 13 pixels wide")
    eq(src_new, [(0, 0, 39, 33)], "1.4.0: the external id 7 (1 column) wins: all 39 pixels")


@case("g140", "clear_screen")
def _g140_clear_screen():
    """graphics_storage.zig clearScreen (ED 2 and ED 22): the placements that are on the screen
    go, and every image nothing uses; a placement wholly in the scrollback stays (1.3.1 removed
    every pin placement)."""
    def feed(t):
        t.feed(_rgba_img(5, 13, 33) + _apc(b"a=p,i=5,C=1"))
        t.feed(b"\n" * 6)
        t.feed(_rgba_img(6, 13, 33) + _at(0, 0, "") + _apc(b"a=p,i=6,C=1") + b"\x1b[2J")
    old, new = _pair_terms(feed, rows=3)
    eq(sorted(old.active.kitty.images), [], "1.3.1: everything goes")
    eq(sorted(new.active.kitty.images), [5], "1.4.0: only what is on screen goes, image 5 stays")
    eq(len(new.active.kitty.placements), 1, "with its placement in the scrollback")


@case("g140", "animation_accepted")
def _g140_animation_accepted():
    """Ghostty 1.4.0 implements the Kitty animation actions: a=f adds a frame, a=a controls the
    animation and a=c composes frames. The model runs the animation layer of anim.py (kitty's
    graphics.c) for the 1.4.0 profile too, with Ghostty's words for the failures that name a
    missing image or frame; 1.3.1 answers none of them."""
    def feed(t):
        t.feed(_rgba_img(5, 1, 1) + _apc(b"a=f,i=5,s=1,v=1,f=32,z=100;" + _b64(bytes(4))))
        t.feed(_apc(b"a=f,i=77,s=1,v=1,f=32;" + _b64(bytes(4))))
    old, new = _pair_terms(feed)
    eq(_answers(old), [b"\x1b_Gi=5;OK\x1b\\"], "1.3.1: only the transmission is answered")
    eq(_answers(new), [b"\x1b_Gi=5;OK\x1b\\", b"\x1b_Gi=5,r=2;OK\x1b\\",
                       b"\x1b_Gi=77;ENOENT: image not found\x1b\\"],
       "1.4.0: the frame is added as frame 2, a missing image is Ghostty's ENOENT")
    eq(new.snapshot().images[5].frame, 1, "the animation starts on the root frame")
    check(not any("unsupported by ghostty" in w for w in new.warnings), "no refusal warning")
    check(any("unsupported by ghostty-1.3.1" in w for w in old.warnings), "1.3.1 logs its refusal")


@case("g140", "relay_default_profile")
def _g140_relay_default_profile():
    """The relay, the replay tool and a screen test's recording run the profile of the user's
    terminal, ghostty-1.4.0, unless --profile names another; the library's Terminal keeps
    ghostty-1.3.1 as its default (the oldest supported version, which the older cases test)."""
    from vkitty import kgp
    from vkitty.vt import Terminal
    eq(kgp.DEFAULT_PROFILE, "ghostty-1.4.0", "the default profile")
    eq(Terminal(4, 2).profile, "ghostty-1.3.1", "the library default stays the oldest version")
    eq(Terminal(4, 2, profile=_G140).snapshot().profile, "ghostty-1.4.0", "and snapshots say it")
    tmp = _spec_tempdir()
    try:
        steps = [{"write_b64": _b64(b"x").decode("ascii")}]
        run = _relay_once(tmp, steps, ["--hop", "none"])
        eq(_recording(run).meta["profile"], "ghostty-1.4.0", "the relay's recording")
        eq(_recording(run).snapshot().profile, "ghostty-1.4.0", "and its replay")
        run = _relay_once(tmp, steps, ["--hop", "none", "--profile", _G131])
        eq(_recording(run).snapshot().profile, "ghostty-1.3.1", "--profile names the older one")
        out = _replay_cli(run["rec"], "--profile", _G140, "--report", os.path.join(tmp, "r.json"))
        eq(out.returncode, 0, "replay.py --profile %s" % out.stderr[-200:])
        eq(_json_read(os.path.join(tmp, "r.json"))["profile"], "ghostty-1.4.0",
           "the replay tool takes the profile of the command line over the recorded one")
    finally:
        _drop_spec_dir(tmp)


def _breaks(tables, cps):
    """Is there a grapheme break between each pair of cps, from the state after the pairs before."""
    state = 0
    out = []
    for cp1, cp2 in zip(cps, cps[1:]):
        is_break, state = tables.grapheme_break(cp1, cp2, state)
        out.append(is_break)
    return out


@case("g140", "unicode_18")
def _g140_unicode_18():
    """Ghostty 1.4.0 ships Unicode 18.0.0 (its uucode), where 1.3.1 has 17.0.0: new code points
    have the widths and break classes of their own, and the Indic conjunct rules changed (a linker
    that is not Extend, U+1CF5 and U+1CF6 and U+11A3A, is a class of its own; GB9c reads a linker,
    Extend characters and a consonant as one cluster). The tables are generated by
    tools/gen_widths.py --profile ghostty-1.4.0 from the pinned uucode and checked against its
    GraphemeBreakTest.txt of 18.0.0 (853 lines) when they are generated."""
    from vkitty import widths
    t131, t140 = widths.tables_for(_G131), widths.tables_for(_G140)
    eq((t131.UNICODE_VERSION, t140.UNICODE_VERSION), ("17.0.0", "18.0.0"), "the versions")
    eq(widths.tables_for("kitty"), t131, "the other profiles keep the 1.3.1 tables")
    check(t131 is widths._T131 and widths.props is t131.props, "the module level names are 1.3.1's")
    # U+10ECB is assigned in 18: a combining character (width 0, Extend); in 17 it is unassigned
    eq((t131.props(0x10ECB)[0], t140.props(0x10ECB)[0]), (1, 0), "U+10ECB: width 1, then 0")
    old, new = _pair_terms(lambda t: t.feed("a\U00010ECBb".encode("utf-8")), cols=10, rows=2)
    eq((old.snapshot().text()[0][:3], new.snapshot().text()[0][:3]),
       ("a\U00010ECBb", "a\U00010ECBb"), "the text is the same")
    eq((old.snapshot().cursor[0], new.snapshot().cursor[0]), (3, 2),
       "but 1.3.1 gave U+10ECB a cell of its own and 1.4.0 joined it to the 'a'")
    # GB9c with a linker that is not Extend
    cps = [0x61, 0x1CF5, 0x300, 0x915]
    eq(_breaks(t140, cps), [True, False, False], "1.4.0: a, linker, extend, consonant: one cluster")
    check(_breaks(t131, cps) != _breaks(t140, cps), "1.3.1 breaks this differently")
    for cps, want in (([0x94D, 0x915], [False]), ([0x915, 0x300, 0x915], [False, True]),
                      ([0x94D, 0x903, 0x915], [False, True]),
                      ([0x1F600, 0x94D, 0x300, 0x200D, 0x1F600], [False, False, False, False]),
                      ([0x61, 0x11A3A, 0x11A0B], [True, False])):
        eq(_breaks(t140, cps), want, "uucode's own cases: %s" % " ".join("%X" % c for c in cps))


@case("g140", "variation_selectors")
def _g140_variation_selectors():
    """Terminal.print, graphemeWidthEffect: in 1.4.0 a variation selector applies to the code point
    before it in the cell (the last one of the cluster), so the selector after 'black flag, ZWJ,
    skull and crossbones' counts as an emoji selector for U+2620; 1.3.1 asked about the cell's
    first code point (a flag, which has no emoji variation sequence) and dropped it. VS15 on a wide
    emoji makes it one cell and puts the cursor after it, whatever the tail was."""
    def pirate(t):
        t.feed(b"\x1b[?2027h" + "\U0001F3F4\u200d\u2620\ufe0f".encode("utf-8"))
    old, new = _pair_terms(pirate, cols=10, rows=2)
    eq(old.active.grid[0].text[0], "\U0001F3F4\u200d\u2620", "1.3.1 drops the selector")
    eq(new.active.grid[0].text[0], "\U0001F3F4\u200d\u2620\ufe0f", "1.4.0 keeps it")
    # an invalid selector (the base is no emoji) is dropped by both
    def invalid(t):
        t.feed(b"\x1b[?2027h" + "x\ufe0f".encode("utf-8"))
    old, new = _pair_terms(invalid, cols=10, rows=2)
    eq((old.active.grid[0].text[0], new.active.grid[0].text[0]), ("x", "x"), "an invalid VS16")
    # VS15 makes the wide watch narrow: the tail cell goes narrow and the cursor follows the base
    def narrow(t):
        t.feed(b"\x1b[?2027h" + "\u231a".encode("utf-8"))
        t.feed("\ufe0e".encode("utf-8"))
    old, new = _pair_terms(narrow, cols=10, rows=2)
    from vkitty import vt
    eq(new.active.grid[0].wide[:2], [vt._WIDE_NARROW] * 2, "1.4.0: both cells narrow")
    eq(new.snapshot().cursor[:2], (1, 0), "1.4.0: the cursor is on the cell after the base")
    # at the right edge the cursor stays on the last column when the base is the last cell
    def edge(t):
        t.feed(b"\x1b[?2027h" + b"abcdefgh" + "\u231a".encode("utf-8") + "\ufe0e".encode("utf-8"))
    _old, new = _pair_terms(edge, cols=10, rows=2)
    eq((new.snapshot().cursor[0], new.active.pending), (9, False),
       "1.4.0: a narrow base in the second last column: the cursor on the last one")


@case("meta", "no_bytecode")
def _meta_no_bytecode():
    """python -I ignores PYTHONDONTWRITEBYTECODE, so every program of the harness sets
    sys.dont_write_bytecode itself, before its first import of the package; and every
    interpreter that vkitty_screen.sh starts is either told -B or runs one of those programs."""
    import re
    flag = re.compile(r"^sys\.dont_write_bytecode = True\b")
    imports_pkg = re.compile(r"^\s*(from|import)\s+vkitty\b")
    problems = []
    for path in ENTRY_POINTS:
        lines = _read_source(path)
        flag_at = next((i for i, line in enumerate(lines) if flag.match(line)), None)
        pkg_at = next((i for i, line in enumerate(lines) if imports_pkg.match(line)), None)
        name = os.path.relpath(path, REPO_ROOT)
        if flag_at is None:
            problems.append("%s never sets sys.dont_write_bytecode = True" % name)
        elif pkg_at is not None and pkg_at < flag_at:
            problems.append("%s imports vkitty (line %d) before it sets the flag (line %d)"
                            % (name, pkg_at + 1, flag_at + 1))
    entry_names = set(os.path.basename(p) for p in ENTRY_POINTS)
    shell = _read_source(os.path.join(HERE, "vkitty_screen.sh"))
    started = 0
    for number, line in enumerate(shell, 1):
        if "VKPY" not in line or line.lstrip().startswith("#") or line.startswith("VKPY="):
            continue
        for m in re.finditer(r'"?\$VKPY"?((?:\s+-[A-Za-z]+)*)\s*(\S*)', line):
            started += 1
            options = m.group(1).split()
            program = m.group(2).strip('"')
            if "-B" in options:
                continue
            base = os.path.basename(program.replace('"', ""))
            if base in entry_names:
                continue
            problems.append("vkitty_screen.sh line %d starts python without -B and not on a "
                            "program that sets the flag: %s" % (number, line.strip()[:100]))
    check(started >= 10, "the scan found only %d interpreter starts in vkitty_screen.sh" % started)
    # the interpreters the spec and the library start themselves: -B, or one of the programs above
    entry_vars = ("RELAY_PY", "TESTCHILD_PY", "REPLAY_PY", "LIVE_PY", "checks_py",
                  "os.path.abspath(__file__)")
    library = [os.path.join(VK_DIR, name) for name in sorted(os.listdir(VK_DIR))
               if name.endswith(".py")]
    for path in [os.path.join(HERE, "vkitty_spec.py")] + library:
        text = "\n".join(_read_source(path))
        for m in re.finditer(r'sys\.executable,\s*("-[A-Za-z]+",\s*)*([A-Za-z_.()]+)', text):
            options = re.findall(r'"(-[A-Za-z]+)"', m.group(0))
            if "-B" not in options and m.group(2) not in entry_vars:
                problems.append("%s starts python without -B: %s"
                                % (os.path.basename(path), m.group(0)[:80]))
    check(not problems, "bytecode may be written into the repository tree:\n  "
          + "\n  ".join(problems))
    return "%d programs, %d interpreter starts in the screen test" % (len(ENTRY_POINTS), started)


@case("meta", "line_length")
def _meta_line_length():
    """No line of the harness's Python files is longer than 100 characters: the library, its tools
    and this spec (the generated widths_data.py is not read by hand and is left out)."""
    import glob
    paths = sorted(glob.glob(os.path.join(VK_DIR, "*.py"))
                   + glob.glob(os.path.join(VK_DIR, "tools", "*.py"))
                   + [os.path.join(HERE, "vkitty_spec.py")])
    problems = []
    checked = 0
    for path in paths:
        if os.path.basename(path).startswith("widths_data"):
            continue
        checked += 1
        for number, line in enumerate(_read_source(path), 1):
            if len(line) > 100:
                problems.append("%s:%d (%d)"
                                % (os.path.relpath(path, REPO_ROOT), number, len(line)))
    check(checked >= 20, "only %d files were checked" % checked)
    check(not problems, "%d lines are longer than 100 characters: %s"
          % (len(problems), ", ".join(problems[:8])))
    return "%d files" % checked


@case("meta", "run_all_grep")
def _meta_run_all_grep():
    """The grep that tests/run_all.sh puts on this spec's output keeps what a reader of the suite
    log needs: every FAIL line, the lines of the timed cases (perf/ and perfclock/, which carry
    the UNDECIDED reasons) and the summary line main prints for undecided cases; and it drops the
    other ok lines. The summary line is the one _perf_summary builds, so the wording and the grep
    cannot drift apart."""
    import re
    with open(os.path.join(HERE, "run_all.sh"), encoding="utf-8") as fh:
        text = fh.read()
    found = re.findall(r"vk_out\" \| grep -E '([^']+)'", text)
    eq(len(found), 1, "tests/run_all.sh has one grep on the vkitty spec output")
    pattern = re.compile(found[0])
    summary = _perf_summary(["perfclock/contention_seen", "perf/relay"])
    keep = ["FAIL tokens/x: broken",
            "ok perf/tokens (900 ms): UNDECIDED: host busy",
            "ok perfclock/contention_seen (60445 ms): UNDECIDED: host busy",
            summary]
    drop = ["ok tokens/fast_equals_slow (12 ms)",
            "ok perfect/x (1 ms)",
            "ALL VKITTY CHECKS PASSED",
            "note: 2 perf limits undecided"]
    for line in keep:
        check(pattern.match(line), "the grep drops %r" % line)
    for line in drop:
        check(not pattern.match(line), "the grep keeps %r" % line)
    check(summary.startswith("2 timed cases undecided (host busy): "), "the summary: %r" % summary)


_ANIM_IMPORT_PROGRAM = r"""
import base64, sys
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
from vkitty.vt import Terminal
pixel = base64.b64encode(b"\x00\x00\x00\xff")
t = Terminal(10, 4, profile=sys.argv[2])
t.feed(b"\x1b_Ga=t,f=32,s=1,v=1,i=1;" + pixel + b"\x1b\\")
t.feed(b"\x1b_Ga=p,i=1,C=1\x1b\\")
if sys.argv[3] == "frame":
    t.feed(b"\x1b_Ga=f,i=1,s=1,v=1,f=32;" + pixel + b"\x1b\\")
t.snapshot(1.0)
print("vkitty.anim" in sys.modules)
"""


@case("meta", "ghostty_no_anim_import")
def _meta_ghostty_no_anim_import():
    """The animation layer belongs to the kitty profile and to ghostty-1.4.0 (which implements the
    animation actions): a terminal of any profile with an image and a placement takes a snapshot
    without importing vkitty.anim, and ghostty-1.3.1 does not load it for a frame either. A fresh
    interpreter, because this process may have imported it already; the kitty terminal with a frame
    is the control."""
    import subprocess

    def run(profile, mode):
        proc = subprocess.run([sys.executable, "-I", "-B", "-c", _ANIM_IMPORT_PROGRAM, LIB, profile,
                               mode], capture_output=True, text=True, timeout=60)
        eq(proc.returncode, 0, "the probe program ran: %s" % proc.stderr[-300:])
        return proc.stdout.strip()
    eq(run("ghostty-1.3.1", "image"), "False", "a ghostty profile image with a placement")
    eq(run("ghostty-1.4.0", "image"), "False", "a 1.4.0 profile image with a placement")
    eq(run("ghostty-1.3.1", "frame"), "False", "1.3.1 refuses a frame: the layer is not loaded")
    eq(run("kitty", "image"), "False", "a kitty profile image with no frame")
    eq(run("kitty", "frame"), "True", "a kitty profile image with a frame (the control)")
    eq(run("ghostty-1.4.0", "frame"), "True", "a 1.4.0 profile image with a frame runs the layer")


# ---------------------------------------------------------------- faults ---
# Each fault of tests/lib/vkitty/faults.py breaks one component on purpose, and lists the cases that
# must fail while it is set. A case here runs the listed cases in a fresh spec process with the
# fault in the environment (never this group itself), and asserts that the process fails and that
# every listed case has a FAIL line. The same cases pass in the main run, so a case that does not
# fail under its fault does not guard the component. The runs name the cases, not their groups, to
# keep the cost to the cases themselves.

def _fault_case(name):
    def run():
        import re
        import subprocess
        from vkitty.faults import FAULTS
        listed = FAULTS[name]
        env = dict(os.environ)
        env["VKITTY_FAULT"] = name
        proc = subprocess.run([sys.executable, "-I", os.path.abspath(__file__), "--only",
                               ",".join(listed)], env=env, stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=300)
        out = proc.stdout.decode("utf-8", "replace")
        failed = set(re.findall(r"^FAIL (\S+?):", out, re.M))
        check(proc.returncode == 1, "fault %s: the spec exited %d, want 1 (a failing case): %s"
              % (name, proc.returncode, out[-300:]))
        survivors = [c for c in listed if c not in failed]
        check(not survivors, "fault %s: %d listed cases still pass: %s"
              % (name, len(survivors), ", ".join(survivors)))
        return "%d cases fail" % len(listed)
    return run


def _register_fault_cases():
    from vkitty.faults import FAULTS
    for fault_name in FAULTS:
        case("faults", fault_name)(_fault_case(fault_name))


_register_fault_cases()


# ------------------------------------------------------------------ main ---

def group_of(name):
    return name.split("/", 1)[0]


def selected(only):
    if not only:
        return list(CASES)
    picks = [p.strip() for p in only.split(",") if p.strip()]
    out = []
    for group, name, fn in CASES:
        full = "%s/%s" % (group, name)
        if any(p == group or p == full for p in picks):
            out.append((group, name, fn))
    return out


def report_missing(exc, group, name):
    module = getattr(exc, "name", None) or str(exc)
    if module and not module.startswith("vkitty"):
        print("FAIL vkitty: missing Python module %s (use a python with "
              "tests/lib/vkitty/requirements.txt)" % module)
    print("FAIL %s/%s: ImportError: %s" % (group, name, exc))


def _cleanup_spec_files():
    """Remove every shared memory object and temporary path the spec made that still exists."""
    for kind, name in sorted(_SPEC_CREATED):
        _remove_spec_file(kind, name)


def _install_cleanup_signals():
    """SIGTERM and SIGINT remove the spec's leftovers before the process exits."""
    import signal

    def handler(signum, _frame):
        _cleanup_spec_files()
        sys.exit(128 + signum)

    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, handler)


def _check_spec_leftovers(failures):
    """Once, at the end of main (after every selected case has run): nothing this spec made may
    still exist. Anything found is reported as a failure and removed."""
    left = []
    for kind, name in sorted(_SPEC_CREATED):
        exists = _shm_exists(name) if kind == "shm" else os.path.exists(name)
        if exists:
            left.append("%s %s" % (kind, name))
    _cleanup_spec_files()
    _SPEC_CREATED.clear()
    if left:
        print("FAIL media/leftovers: left behind by the spec: %s" % ", ".join(left))
        failures.append("media/leftovers")


def main(argv):
    only = None
    list_only = False
    args = list(argv)
    while args:
        arg = args.pop(0)
        if arg == "--only":
            if not args:
                print("usage: vkitty_spec.py [--only GROUPS] [--list]")
                return 2
            only = args.pop(0)
        elif arg.startswith("--only="):
            only = arg.split("=", 1)[1]
        elif arg == "--list":
            list_only = True
        else:
            print("usage: vkitty_spec.py [--only GROUPS] [--list]")
            return 2
    chosen = selected(only)
    if only and not chosen:
        print("usage: no case matches --only %s" % only)
        return 2
    if list_only:
        for group, name, _fn in chosen:
            print("%s/%s" % (group, name))
        return 0
    fault = os.environ.get("VKITTY_FAULT", "")
    if fault:
        print("fault: VKITTY_FAULT=%s" % fault)
    _install_cleanup_signals()
    failures = []
    for group, name, fn in chosen:
        t0 = time.perf_counter()
        try:
            note = fn()
        except ImportError as exc:
            report_missing(exc, group, name)
            failures.append("%s/%s" % (group, name))
            continue
        except AssertionError as exc:
            print("FAIL %s/%s: %s" % (group, name, exc))
            failures.append("%s/%s" % (group, name))
            continue
        except Exception as exc:  # a crash in a case is a failure of that case
            print("FAIL %s/%s: %s: %s" % (group, name, type(exc).__name__, exc))
            traceback.print_exc(limit=3, file=sys.stdout)
            failures.append("%s/%s" % (group, name))
            continue
        ms = (time.perf_counter() - t0) * 1000
        line = "ok %s/%s (%d ms)" % (group, name, round(ms))
        if note:
            line += ": " + note
        print(line)
    _check_spec_leftovers(failures)
    if _PERF_UNDECIDED:
        print(_perf_summary(_PERF_UNDECIDED))
    if failures:
        print("%d VKITTY CHECKS FAILED" % len(failures))
        return 1
    print("ALL VKITTY CHECKS PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

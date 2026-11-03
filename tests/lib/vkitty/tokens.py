"""Byte stream to tokens, the way Ghostty 1.3.1 parses a terminal stream.

A Tokenizer reads bytes in feeds and emits tokens to a sink, in stream order:

    PRINT    payload str     a run of printed code points (one per feed call at most)
    EXEC     payload int     a C0 control (or a C1 byte in a string or sequence)
    ESC      payload (inter, final)
    CSI      payload (params, inter, final); inter holds the private leader too
    OSC      payload (data, term); term is BEL, ESC \\ or b"" when cut
    DCS      payload (params, inter, final, data)
    APC      payload bytes after ESC _ (SOS and PM strings use SOS_PM)
    SOS_PM   payload bytes

Every token has a channel span: start is the offset of its first byte and end
the offset after its last byte. A string or sequence ended by ESC, CAN or SUB
is a cut (cut=True, end at the aborting byte); a string ended by ESC \\ or BEL
is not. ``cuts`` lists (start, kind) for every aborted sequence, kind one of
csi, esc, osc, dcs, apc (SOS and PM count as apc).

The state machine is Ghostty's: the transition table is generated from
src/terminal/parse_table.zig (genTable, literally), the actions are those of
src/terminal/Parser.zig, and the byte rules outside the table are those of
src/terminal/stream.zig (ground: code points up to 0x0F execute, ESC starts an
escape, everything else prints; csi_param: the nextNonUtf8 fast path). One
deliberate difference from a bare table walk: a CAN or SUB inside csi_param
moves to ground without an EXEC token, because stream.zig does that.

tmux passthrough (tmux 3.5a input.c): a DCS with
final t and no parameters is read by tmux's own rules from the t to the ESC \\
that ends it (input_state_dcs_handler_table and input_state_dcs_escape_table,
the four bytes "mux;" included). CAN and SUB are data. ESC ESC stores one ESC.
An ESC before any other byte is dropped and that byte is kept, with a warning.
The stored data (the t included) may not reach TMUX_INPUT_BUF_LIMIT bytes
(input_input); a DCS that would is dropped whole, and the drop is recorded in
``discards``. A DCS open longer than TMUX_DCS_TIMEOUT by the arrival times of
its chunks is dropped and the rest of the input is parsed from ground
(input_start_timer, input_reset). At ESC \\ tmux forwards the body only when
the data starts with "tmux;" (input_dcs_dispatch); any other DCS is dropped and
recorded in ``discards`` with reason "not_tmux". A forwarded body is parsed by a
fresh Tokenizer and its tokens carry the DCS span, via_tmux=True, and an ordinal
numbering the APC tokens of the body.

Fast paths (disabled by _force_slow=True, which must give the same tokens):
ground runs, complete CSI sequences, string bodies and tmux body runs are matched
with regular expressions.

Invalid UTF-8 (utf8="ghostty", the default) uses Python's incremental decoder with
"replace" (maximal subparts). Ghostty's own replacement depends on where its reads
split the stream, so byte-exact agreement on invalid input is not claimed (nvim never
sends it).

UTF-8 behind tmux (utf8="tmux"): tmux 3.5a decodes ground text byte by byte, not as
Ghostty does. input_top_bit_set opens a character at a lead byte (0xC2 to 0xDF: 2
bytes, 0xE0 to 0xEF: 3, 0xF0 to 0xF4: 4; any other byte above 0x7F in ground is
dropped) and utf8_append stores the following bytes up to that size; utf8_open and
utf8_append decide at the last byte, so a value that is not valid UTF-8 (a stored byte
that is not 10xxxxxx, an overlong form, a surrogate, a value above U+10FFFF) prints
nothing. An escape sequence or a string in the middle of a character does not end it:
the state lives in the input context and only input_print (a printable ASCII byte) and
input_c0_dispatch (a C0 byte reaching it, in ground, in the escape and CSI states, and
through INPUT_STATE_ANYWHERE for CAN and SUB) reset it, DEL (ignored in ground) and ESC
do not. The tokenizer follows that with a held character that spans sequences: the PRINT
token of the finished character covers its first to its last byte, and every ESC that
interrupts an open character appends (offset of the lead byte, offset of the ESC) to
``splices``. Both modes record splices; ``utf8`` only changes what is printed.
"""
import codecs
import re
from typing import NamedTuple

from vkitty import faults

PRINT, EXEC, ESC, CSI, OSC, DCS, APC, SOS_PM = range(8)
KIND_NAMES = ("PRINT", "EXEC", "ESC", "CSI", "OSC", "DCS", "APC", "SOS_PM")
MAX_PARAMS = 24      # Ghostty Parser.zig MAX_PARAMS
MAX_INTERMEDIATE = 4  # Ghostty Parser.zig MAX_INTERMEDIATE
# tmux 3.5a input.c INPUT_BUF_LIMIT (input_input): the stored data of a DCS, the t
# included, stays below it. The store that would reach it sets INPUT_DISCARD and
# input_dcs_dispatch forwards nothing.
TMUX_INPUT_BUF_LIMIT = 1048576
# tmux 3.5a input.c input_start_timer: a DCS left open for 5 s is reset.
TMUX_DCS_TIMEOUT = 5.0
# The values of Tokenizer's utf8 keyword: the decoder of ground text.
UTF8_GHOSTTY = "ghostty"   # Ghostty's own decoder (the default)
UTF8_TMUX = "tmux"         # tmux 3.5a's byte rule, for a stream that went through tmux


class Token(NamedTuple):
    kind: int
    payload: object
    start: int
    end: int
    cut: bool
    ordinal: int
    via_tmux: bool


_TOKEN_NEW = tuple.__new__
_C1_DROP = {c: None for c in range(0x80, 0xA0)}   # 1.4.0 ignores C1 code points decoded from UTF-8

# ------------------------------------------------------------ the table ---
# Parser.zig State (order as in the Zig enum)
GROUND, ESCAPE, ESCAPE_INTERMEDIATE, CSI_ENTRY, CSI_INTERMEDIATE, CSI_PARAM, CSI_IGNORE, \
    DCS_ENTRY, DCS_PARAM, DCS_INTERMEDIATE, DCS_PASSTHROUGH, DCS_IGNORE, OSC_STRING, \
    SOS_PM_APC_STRING = range(14)
NSTATES = 14
# Tokenizer-only states (not in the table)
ST_PENDING, TMUX_BODY, TMUX_ESC = 14, 15, 16

# Parser.zig TransitionAction (order as in the Zig enum)
A_NONE, A_IGNORE, A_PRINT, A_EXECUTE, A_COLLECT, A_PARAM, A_ESC_DISPATCH, A_CSI_DISPATCH, \
    A_PUT, A_OSC_PUT, A_APC_PUT = range(11)


def _build_table(v14=False):
    """parse_table.zig genTable, literal: anywhere transitions first, then each
    state's own rows (later writes win), then the default (stay, no action).
    Returns (next_state, action) pairs indexed [byte][state]. v14 is Ghostty 1.4.0's table: the
    bytes 0x80 to 0xFF are payload in dcs_passthrough (put) and dcs_ignore (ignore), where 1.3.1
    reads them as C1 controls (a UTF-8 payload would end the string or open a sequence)."""
    res = [[None] * NSTATES for _ in range(256)]

    def single(c, s0, s1, a):
        res[c][s0] = (s1, a)

    def rng(lo, hi, s0, s1, a):
        for c in range(lo, hi + 1):
            res[c][s0] = (s1, a)

    for src in range(NSTATES):
        single(0x18, src, GROUND, A_EXECUTE)
        single(0x1A, src, GROUND, A_EXECUTE)
        rng(0x80, 0x8F, src, GROUND, A_EXECUTE)
        rng(0x91, 0x97, src, GROUND, A_EXECUTE)
        single(0x99, src, GROUND, A_EXECUTE)
        single(0x9A, src, GROUND, A_EXECUTE)
        single(0x9C, src, GROUND, A_NONE)
        single(0x1B, src, ESCAPE, A_NONE)
        single(0x98, src, SOS_PM_APC_STRING, A_NONE)
        single(0x9E, src, SOS_PM_APC_STRING, A_NONE)
        single(0x9F, src, SOS_PM_APC_STRING, A_NONE)
        single(0x9B, src, CSI_ENTRY, A_NONE)
        single(0x90, src, DCS_ENTRY, A_NONE)
        single(0x9D, src, OSC_STRING, A_NONE)

    # ground (the table is never used for ground bytes; kept for completeness)
    single(0x19, GROUND, GROUND, A_EXECUTE)
    rng(0, 0x17, GROUND, GROUND, A_EXECUTE)
    rng(0x1C, 0x1F, GROUND, GROUND, A_EXECUTE)
    rng(0x20, 0x7F, GROUND, GROUND, A_PRINT)

    src = ESCAPE_INTERMEDIATE
    single(0x19, src, src, A_EXECUTE)
    rng(0, 0x17, src, src, A_EXECUTE)
    rng(0x1C, 0x1F, src, src, A_EXECUTE)
    rng(0x20, 0x2F, src, src, A_COLLECT)
    single(0x7F, src, src, A_IGNORE)
    rng(0x30, 0x7E, src, GROUND, A_ESC_DISPATCH)

    src = SOS_PM_APC_STRING
    single(0x19, src, src, A_APC_PUT)
    rng(0, 0x17, src, src, A_APC_PUT)
    rng(0x1C, 0x1F, src, src, A_APC_PUT)
    rng(0x20, 0x7F, src, src, A_APC_PUT)

    src = ESCAPE
    single(0x19, src, src, A_EXECUTE)
    rng(0, 0x17, src, src, A_EXECUTE)
    rng(0x1C, 0x1F, src, src, A_EXECUTE)
    single(0x7F, src, src, A_IGNORE)
    rng(0x30, 0x4F, src, GROUND, A_ESC_DISPATCH)
    rng(0x51, 0x57, src, GROUND, A_ESC_DISPATCH)
    rng(0x60, 0x7E, src, GROUND, A_ESC_DISPATCH)
    single(0x59, src, GROUND, A_ESC_DISPATCH)
    single(0x5A, src, GROUND, A_ESC_DISPATCH)
    single(0x5C, src, GROUND, A_ESC_DISPATCH)
    rng(0x20, 0x2F, src, ESCAPE_INTERMEDIATE, A_COLLECT)
    single(0x58, src, SOS_PM_APC_STRING, A_NONE)
    single(0x5E, src, SOS_PM_APC_STRING, A_NONE)
    single(0x5F, src, SOS_PM_APC_STRING, A_NONE)
    single(0x50, src, DCS_ENTRY, A_NONE)
    single(0x5B, src, CSI_ENTRY, A_NONE)
    single(0x5D, src, OSC_STRING, A_NONE)

    src = DCS_ENTRY
    single(0x19, src, src, A_IGNORE)
    rng(0, 0x17, src, src, A_IGNORE)
    rng(0x1C, 0x1F, src, src, A_IGNORE)
    single(0x7F, src, src, A_IGNORE)
    rng(0x20, 0x2F, src, DCS_INTERMEDIATE, A_COLLECT)
    single(0x3A, src, DCS_IGNORE, A_NONE)
    rng(0x30, 0x39, src, DCS_PARAM, A_PARAM)
    single(0x3B, src, DCS_PARAM, A_PARAM)
    rng(0x3C, 0x3F, src, DCS_PARAM, A_COLLECT)
    rng(0x40, 0x7E, src, DCS_PASSTHROUGH, A_NONE)

    src = DCS_INTERMEDIATE
    single(0x19, src, src, A_IGNORE)
    rng(0, 0x17, src, src, A_IGNORE)
    rng(0x1C, 0x1F, src, src, A_IGNORE)
    rng(0x20, 0x2F, src, src, A_COLLECT)
    single(0x7F, src, src, A_IGNORE)
    rng(0x30, 0x3F, src, DCS_IGNORE, A_NONE)
    rng(0x40, 0x7E, src, DCS_PASSTHROUGH, A_NONE)

    src = DCS_IGNORE
    single(0x19, src, src, A_IGNORE)
    rng(0, 0x17, src, src, A_IGNORE)
    rng(0x1C, 0x1F, src, src, A_IGNORE)
    if v14:
        rng(0x80, 0xFF, src, src, A_IGNORE)

    src = DCS_PARAM
    single(0x19, src, src, A_IGNORE)
    rng(0, 0x17, src, src, A_IGNORE)
    rng(0x1C, 0x1F, src, src, A_IGNORE)
    rng(0x30, 0x39, src, src, A_PARAM)
    single(0x3B, src, src, A_PARAM)
    single(0x7F, src, src, A_IGNORE)
    single(0x3A, src, DCS_IGNORE, A_NONE)
    rng(0x3C, 0x3F, src, DCS_IGNORE, A_NONE)
    rng(0x20, 0x2F, src, DCS_INTERMEDIATE, A_COLLECT)
    rng(0x40, 0x7E, src, DCS_PASSTHROUGH, A_NONE)

    src = DCS_PASSTHROUGH
    single(0x19, src, src, A_PUT)
    rng(0, 0x17, src, src, A_PUT)
    rng(0x1C, 0x1F, src, src, A_PUT)
    rng(0x20, 0x7E, src, src, A_PUT)
    single(0x7F, src, src, A_IGNORE)
    if v14:
        rng(0x80, 0xFF, src, src, A_PUT)

    src = CSI_PARAM
    single(0x19, src, src, A_EXECUTE)
    rng(0, 0x17, src, src, A_EXECUTE)
    rng(0x1C, 0x1F, src, src, A_EXECUTE)
    rng(0x30, 0x39, src, src, A_PARAM)
    single(0x3A, src, src, A_PARAM)
    single(0x3B, src, src, A_PARAM)
    single(0x7F, src, src, A_IGNORE)
    rng(0x40, 0x7E, src, GROUND, A_CSI_DISPATCH)
    rng(0x3C, 0x3F, src, CSI_IGNORE, A_NONE)
    rng(0x20, 0x2F, src, CSI_INTERMEDIATE, A_COLLECT)

    src = CSI_IGNORE
    single(0x19, src, src, A_EXECUTE)
    rng(0, 0x17, src, src, A_EXECUTE)
    rng(0x1C, 0x1F, src, src, A_EXECUTE)
    rng(0x20, 0x3F, src, src, A_IGNORE)
    single(0x7F, src, src, A_IGNORE)
    rng(0x40, 0x7E, src, GROUND, A_NONE)

    src = CSI_INTERMEDIATE
    single(0x19, src, src, A_EXECUTE)
    rng(0, 0x17, src, src, A_EXECUTE)
    rng(0x1C, 0x1F, src, src, A_EXECUTE)
    rng(0x20, 0x2F, src, src, A_COLLECT)
    single(0x7F, src, src, A_IGNORE)
    rng(0x40, 0x7E, src, GROUND, A_CSI_DISPATCH)
    rng(0x30, 0x3F, src, CSI_IGNORE, A_NONE)

    src = CSI_ENTRY
    single(0x19, src, src, A_EXECUTE)
    rng(0, 0x17, src, src, A_EXECUTE)
    rng(0x1C, 0x1F, src, src, A_EXECUTE)
    single(0x7F, src, src, A_IGNORE)
    rng(0x40, 0x7E, src, GROUND, A_CSI_DISPATCH)
    single(0x3A, src, CSI_IGNORE, A_NONE)
    rng(0x20, 0x2F, src, CSI_INTERMEDIATE, A_COLLECT)
    rng(0x30, 0x39, src, CSI_PARAM, A_PARAM)
    single(0x3B, src, CSI_PARAM, A_PARAM)
    rng(0x3C, 0x3F, src, CSI_PARAM, A_COLLECT)

    src = OSC_STRING
    single(0x19, src, src, A_IGNORE)
    rng(0, 0x06, src, src, A_IGNORE)
    rng(0x08, 0x17, src, src, A_IGNORE)
    rng(0x1C, 0x1F, src, src, A_IGNORE)
    rng(0x20, 0xFF, src, src, A_OSC_PUT)
    single(0x07, src, GROUND, A_NONE)

    table = []
    for s in range(NSTATES):          # index: state * 256 + byte
        for c in range(256):
            entry = res[c][s]
            if entry is None:
                entry = (s, A_NONE)
            table.append(entry)
    next_state = bytes(entry[0] for entry in table)
    action = bytes(entry[1] for entry in table)
    return next_state, action


_NEXT, _ACT = _build_table()  # index: state * 256 + byte
_NEXT14, _ACT14 = _build_table(True)

# ------------------------------------------------------------- fast paths ---
_GROUND_RUN = re.compile(rb"[^\x00-\x0f\x1b]+")
_GROUND_RUN14 = re.compile(rb"[^\x00-\x1f]+")      # 1.4.0 executes every C0 control
# A complete CSI that the table walk would dispatch: an optional private leader
# then parameters (a leading ':' would start ignore, so it is excluded), then
# intermediates, then the final byte.
_CSI_COMPLETE = re.compile(
    rb"\x1b\[(?:([\x3c-\x3f])([\x30-\x3b]*)|([\x30-\x39\x3b][\x30-\x3b]*))?"
    rb"([\x20-\x2f]*)([\x40-\x7e])")
_TMUX_BODY_RUN = re.compile(rb"[^\x1b]+")   # tmux stores CAN and SUB as data
_OSC_RUN = re.compile(rb"[\x20-\xff]+")
_APC_RUN = re.compile(rb"[\x00-\x17\x19\x1c-\x7f]+")
_DCS_RUN = re.compile(rb"[\x00-\x17\x19\x1c-\x7e]+")
_DCS_RUN14 = re.compile(rb"[\x00-\x17\x19\x1c-\x7e\x80-\xff]+")

_SOS_INTRO = {0x58: SOS_PM, 0x98: SOS_PM, 0x5E: SOS_PM, 0x9E: SOS_PM, 0x5F: APC, 0x9F: APC}
_STRING_STATES = (OSC_STRING, SOS_PM_APC_STRING, DCS_PASSTHROUGH)
_CSI_STATES = (CSI_ENTRY, CSI_PARAM, CSI_INTERMEDIATE, CSI_IGNORE)
_ESC_STATES = (ESCAPE, ESCAPE_INTERMEDIATE)
_DCS_STATES = (DCS_ENTRY, DCS_PARAM, DCS_INTERMEDIATE, DCS_IGNORE)
# a DCS whose final byte has not come: tmux's timer is already running (input_enter_dcs)
_DCS_OPENING_STATES = (DCS_ENTRY, DCS_PARAM, DCS_INTERMEDIATE)
_SEQ_INTRO_STATES = (ESCAPE, CSI_ENTRY, DCS_ENTRY, OSC_STRING, SOS_PM_APC_STRING)
_STATE_NAMES = {
    GROUND: "ground", ESCAPE: "escape", ESCAPE_INTERMEDIATE: "escape_intermediate",
    CSI_ENTRY: "csi_entry", CSI_INTERMEDIATE: "csi_intermediate", CSI_PARAM: "csi_param",
    CSI_IGNORE: "csi_ignore", DCS_ENTRY: "dcs_entry", DCS_PARAM: "dcs_param",
    DCS_INTERMEDIATE: "dcs_intermediate", DCS_PASSTHROUGH: "dcs_passthrough",
    DCS_IGNORE: "dcs_ignore", OSC_STRING: "osc_string", SOS_PM_APC_STRING: "sos_pm_apc_string",
    ST_PENDING: "string ended by ESC", TMUX_BODY: "tmux body", TMUX_ESC: "tmux body ESC",
}


def tmux_wrap(data):
    """DCS tmux; wrapping as core/src/kitty.rs LocalTty::write does it: every ESC
    is doubled inside, and the wrapper ends with ESC \\."""
    return b"\x1bPtmux;" + data.replace(b"\x1b", b"\x1b\x1b") + b"\x1b\\"


class Tokenizer:
    """Feed bytes with their channel offsets; call finish() at the end.

    sink receives each Token. strings_only keeps only APC tokens (the parse is
    the same; ground text and CSI, OSC and DCS are not materialized). utf8 is the
    rule for bytes above 0x7F in ground: "ghostty" (the default) decodes as Ghostty
    does, "tmux" as tmux 3.5a does (see the module docstring).
    """

    def __init__(self, sink, *, strings_only=False, tmux_passthrough=True, _force_slow=False,
                 _tmux_limit=TMUX_INPUT_BUF_LIMIT, utf8=UTF8_GHOSTTY, v14=False):
        if utf8 not in (UTF8_GHOSTTY, UTF8_TMUX):
            raise ValueError("utf8 must be 'ghostty' or 'tmux'")
        # Ghostty 1.4.0 (v14): C0 controls 0x10 to 0x1F are executed (1.3.1 prints them), C1 code
        # points decoded from UTF-8 are ignored (1.3.1 prints them), a string canceled by CAN or
        # SUB, or aborted by a C1 control other than ST, is discarded (1.3.1 runs it), and the
        # DCS table reads 0x80 to 0xFF as payload.
        self._v14 = bool(v14)
        self._next, self._act = (_NEXT14, _ACT14) if v14 else (_NEXT, _ACT)
        self._c0_max = 0x1F if v14 else 0x0F
        self._ground_run = _GROUND_RUN14 if v14 else _GROUND_RUN
        self._dcs_run = _DCS_RUN14 if v14 else _DCS_RUN
        self._u8_tmux = utf8 == UTF8_TMUX
        # (offset of an unfinished character's first byte, offset of the ESC)
        self.splices = []
        # tmux mode: the unfinished character (its bytes, its size, a stored byte that was not a
        # continuation); _tail_start is the offset of its first byte in both modes
        self._u8 = bytearray()
        self._u8_size = 0
        self._u8_bad = False
        self._sink = sink
        self._strings_only = bool(strings_only)
        self._tmux_on = bool(tmux_passthrough) and not faults.active("no_unwrap")
        self._fast = not _force_slow
        self._force_slow = bool(_force_slow)
        self._tmux_limit = int(_tmux_limit)   # private: the tests reach the edge cheaply
        self.state = GROUND
        self.cuts = []
        self.discards = []    # passthrough DCSs tmux drops: (DCS start, bytes, reason)
        self.warnings = []
        self._dec = codecs.getincrementaldecoder("utf-8")("replace")
        self._tail_start = None      # offset of the bytes the decoder holds
        self._pr_start = None        # the open PRINT run
        self._pr_end = None
        self._pr_parts = []
        self._seq_start = 0
        self._params = bytearray()
        self._inter = bytearray()
        self._str = bytearray()
        self._str_kind = None        # SOS_PM_APC_STRING: APC or SOS_PM
        self._pend_kind = None
        self._pend_pos = 0
        self._dcs_mode = None        # None, "normal", "tmux"
        self._dcs_final = 0
        self._dcs_params = b""
        self._dcs_inter = b""
        self._dcs_ok = True
        # tmux passthrough state (only while state is TMUX_BODY or TMUX_ESC)
        self._body = bytearray()     # the stored data, the t first; kept below the limit
        self._tmux_start = 0         # the DCS's ESC
        self._tmux_n = 0             # bytes tmux stores or tries to store (attempted count)
        self._tmux_discard = False   # INPUT_DISCARD: the limit was reached
        self._dcs_t0 = None          # arrival time of the chunk in which the DCS opened (ESC P)
        self._tmux_t0 = None         # the same, kept for the passthrough DCS after its final byte
        self._feed_t = None          # arrival time of the chunk being fed

    # ----------------------------------------------------------- public ---

    def feed(self, data, offset=0, t=None):
        """Process data, whose first byte is at channel offset `offset`.

        t is the arrival time in seconds of this chunk (None when unknown). It only
        matters for tmux's 5 s timer, which tmux starts when the DCS opens (ESC P, in
        input_enter_dcs), not at its final byte: a chunk that arrives more than
        TMUX_DCS_TIMEOUT after the DCS opened finds the parser reset, whether the DCS had
        reached its passthrough body or was still before its final byte, and the chunk is
        parsed from ground.
        """
        self._feed_t = t
        if t is not None and self._tmux_on:
            if self.state == TMUX_BODY or self.state == TMUX_ESC:
                if self._tmux_t0 is not None and t - self._tmux_t0 > TMUX_DCS_TIMEOUT:
                    self._timer_drop(t - self._tmux_t0)
            elif self.state in _DCS_OPENING_STATES:
                if self._dcs_t0 is not None and t - self._dcs_t0 > TMUX_DCS_TIMEOUT:
                    self._timer_drop_open(t - self._dcs_t0)
        n = len(data)
        i = 0
        if not self._fast:
            while i < n:
                self._byte(data[i], offset + i)
                i += 1
            self._flush_print()
            return
        sink = self._sink
        strings_only = self._strings_only
        while i < n:
            st = self.state
            if st == GROUND:
                c = data[i]
                if c == 0x1B:
                    m = _CSI_COMPLETE.match(data, i)
                    if m is not None:
                        if not strings_only:
                            if self._tail_start is not None or self._pr_parts:
                                self._ground_esc(offset + i)
                            lead, params_a, params_b, inter, _f = m.groups()
                            e = m.end()
                            if params_a is not None:
                                params = params_a
                            elif params_b is not None:
                                params = params_b
                            else:
                                params = b""
                            final = data[e - 1]
                            if lead is None and inter is None:
                                inter_all = b""
                            else:
                                inter_all = ((lead or b"") + (inter or b""))[:MAX_INTERMEDIATE]
                            if len(params) < MAX_PARAMS and (final == 0x6D or 0x3A not in params):
                                sink(_TOKEN_NEW(Token, (CSI, (params, inter_all, final), offset + i,
                                                        offset + e, False, 0, False)))
                            else:
                                self._dispatch_csi(params, inter_all, final, offset + i, offset + e)
                        else:
                            e = m.end()
                        i = e
                        continue
                elif c > self._c0_max:
                    # a maximal run of ground text: it ends at the next C0 byte or ESC
                    j = self._ground_run.match(data, i).end()
                    if not strings_only:
                        seg = data[i:j]
                        if self._tail_start is None and not self._pr_parts and seg.isascii():
                            sink(_TOKEN_NEW(Token, (PRINT, seg.decode("ascii"), offset + i,
                                                    offset + j, False, 0, False)))
                        else:
                            self._ground_text(seg, offset + i)
                    i = j
                    continue
            elif st == TMUX_BODY:
                m = _TMUX_BODY_RUN.match(data, i)
                if m is not None:
                    self._tmux_run(data[i:m.end()])
                    i = m.end()
                    continue
            elif st == SOS_PM_APC_STRING:
                m = _APC_RUN.match(data, i)
                if m is not None:
                    self._str += data[i:m.end()]
                    i = m.end()
                    continue
            elif st == OSC_STRING:
                m = _OSC_RUN.match(data, i)
                if m is not None:
                    self._str += data[i:m.end()]
                    i = m.end()
                    continue
            elif st == DCS_PASSTHROUGH and self._dcs_mode == "normal":
                m = self._dcs_run.match(data, i)
                if m is not None:
                    self._str += data[i:m.end()]
                    i = m.end()
                    continue
            self._byte(data[i], offset + i)
            i += 1
        self._flush_print()

    def finish(self):
        """End of input: resolve an ESC waiting in a string, and warn about what
        is still open. An incomplete UTF-8 sequence is left undecoded (a warning)."""
        if self.state == ST_PENDING:
            kind = self._pend_kind
            self._end_string(kind, self._pend_pos, True, b"")
            self._cut_string(kind, self._seq_start)
            self.state = GROUND
        elif self.state in (TMUX_BODY, TMUX_ESC):
            self.warnings.append("unfinished DCS tmux body at end of input")
            self.state = GROUND
            self._reset_tmux()
        elif self.state != GROUND:
            self.warnings.append("unfinished %s at end of input"
                                 % _STATE_NAMES.get(self.state, self.state))
        if self._tail_start is not None:
            self.warnings.append("incomplete UTF-8 sequence at end of input")
        self._flush_print()

    # ------------------------------------------------------------ output ---

    def _emit(self, kind, payload, start, end, cut=False, ordinal=0):
        if self._strings_only and kind != APC:
            return
        if self._pr_parts:
            self._flush_print()
        self._sink(_TOKEN_NEW(Token, (kind, payload, start, end, cut, ordinal, False)))

    def _flush_print(self):
        if self._pr_parts:
            text = "".join(self._pr_parts)
            start = self._pr_start
            end = self._pr_end
            self._pr_parts = []
            self._pr_start = None
            self._pr_end = None
            if not self._strings_only:
                self._sink(_TOKEN_NEW(Token, (PRINT, text, start, end, False, 0, False)))

    def _cut(self, kind, start):
        self.cuts.append((start, kind))

    def _cut_string(self, kind, start):
        self.cuts.append((start, {OSC_STRING: "osc", DCS_PASSTHROUGH: "dcs"}.get(kind, "apc")))

    # ------------------------------------------------------------ ground ---

    def _ground_text(self, seg, abs_start):
        """Decode a run of ground bytes that holds no C0 byte and no ESC."""
        if self._strings_only:
            return
        if self._u8_tmux:
            return self._ground_text_tmux(seg, abs_start)
        abs_end = abs_start + len(seg)
        if self._tail_start is None and seg.isascii():
            if self._pr_start is None:
                self._pr_start = abs_start
            self._pr_parts.append(seg.decode("ascii"))
            self._pr_end = abs_end
            return
        old_tail = self._tail_start
        text = self._dec.decode(seg)
        if self._v14 and text and not text.isascii():
            text = text.translate(_C1_DROP)
        buf_len = len(self._dec.getstate()[0])
        new_tail = abs_end - buf_len if buf_len else None
        self._tail_start = new_tail
        if text:
            if self._pr_start is None:
                self._pr_start = old_tail if old_tail is not None else abs_start
            self._pr_parts.append(text)
            self._pr_end = new_tail if new_tail is not None else abs_end

    def _ground_c0(self, pos):
        """Before a C0 byte (not ESC) in ground. Ghostty mode: a held UTF-8 tail becomes
        U+FFFD (_ground_control). tmux mode: input_c0_dispatch drops an open character, which
        prints nothing, and the printed run ends."""
        if self._strings_only:
            return
        if self._u8_tmux:
            if self._u8:
                self._u8_drop()
            self._flush_print()
            return
        self._ground_control(pos)

    def _ground_esc(self, pos):
        """Before an ESC in ground. An unfinished character here is a splice (recorded in both
        modes). Ghostty mode: the held tail becomes U+FFFD (_ground_control). tmux mode: the
        printed run ends and the character stays open across the sequence."""
        if self._strings_only:
            return
        if self._tail_start is not None:
            self.splices.append((self._tail_start, pos))
        if self._u8_tmux:
            self._flush_print()
            return
        self._ground_control(pos)

    def _u8_drop(self):
        """tmux mode: forget the open character; nothing is printed for it."""
        self._u8.clear()
        self._u8_size = 0
        self._u8_bad = False
        self._tail_start = None

    def _add_print(self, text, start, end):
        """tmux mode: add text printed from bytes start to end. A PRINT token covers one
        contiguous byte range, so text that does not touch the open run (after dropped bytes,
        or a character finished after an escape sequence) starts a new one; the fast path
        and the byte path then give the same tokens."""
        if self._pr_parts and self._pr_end != start:
            self._flush_print()
        if self._pr_start is None:
            self._pr_start = start
        self._pr_parts.append(text)
        self._pr_end = end

    def _u8_resets(self, st, c):
        """tmux mode: does C0 byte c (not ESC) in non-ground state st drop an open character?
        It does where tmux reaches input_c0_dispatch: the escape and CSI states for every C0
        byte, an ESC-terminated string's pending byte (tmux is in esc_enter then) except in a
        DCS (dcs_escape stores every byte), and CAN and SUB in the DCS entry states, OSC and
        APC strings (INPUT_STATE_ANYWHERE). A passthrough body keeps it."""
        if st in _ESC_STATES or st in _CSI_STATES:
            return True
        if st == ST_PENDING:
            return self._pend_kind != DCS_PASSTHROUGH
        if st in _DCS_STATES or st == OSC_STRING or st == SOS_PM_APC_STRING:
            return c == 0x18 or c == 0x1A
        return False

    def _u8_byte(self, c, pos):
        """tmux mode: one ground byte that is neither C0 below 0x10 nor ESC, the way tmux's
        input_top_bit_set and input_print take it (see the module docstring)."""
        if c >= 0x80:
            if not self._u8:
                if 0xC2 <= c <= 0xDF:
                    size = 2
                elif 0xE0 <= c <= 0xEF:
                    size = 3
                elif 0xF0 <= c <= 0xF4:
                    size = 4
                else:
                    return
                self._u8 = bytearray((c,))
                self._u8_size = size
                self._u8_bad = False
                self._tail_start = pos
                return
            self._u8.append(c)
            if c & 0xC0 != 0x80:
                self._u8_bad = True
            if len(self._u8) == self._u8_size:
                start = self._tail_start
                text = None
                if not self._u8_bad:
                    try:
                        text = bytes(self._u8).decode("utf-8")
                    except UnicodeDecodeError:
                        text = None
                self._u8_drop()
                if text:
                    self._add_print(text, start, pos + 1)
            return
        if c != 0x7F and self._u8:
            self._u8_drop()
        self._add_print(chr(c), pos, pos + 1)

    def _ground_text_tmux(self, seg, abs_start):
        """tmux mode: a run of ground bytes with no C0 below 0x10 and no ESC. Bytes of an open
        character go through _u8_byte; after that, valid UTF-8 prints at once (every character
        completes, so the byte rule gives the same text), a truncated last character is opened
        with the byte rule, and any other invalid run is fed to the byte rule whole."""
        i = 0
        n = len(seg)
        while self._u8 and i < n:
            self._u8_byte(seg[i], abs_start + i)
            i += 1
        if i >= n:
            return
        rest = seg[i:]
        base = abs_start + i
        try:
            text = rest.decode("utf-8")
        except UnicodeDecodeError as exc:
            if exc.reason == "unexpected end of data" and exc.end == len(rest):
                if exc.start:
                    self._add_print(rest[:exc.start].decode("utf-8"), base, base + exc.start)
                for k in range(exc.start, len(rest)):
                    self._u8_byte(rest[k], base + k)
                return
            for k in range(len(rest)):
                self._u8_byte(rest[k], base + k)
            return
        self._add_print(text, base, abs_start + n)

    def _ground_control(self, pos):
        """Before a C0 byte or an ESC in ground: a held UTF-8 tail becomes U+FFFD
        (the decoder's answer to an interrupted sequence), then the run ends."""
        if self._strings_only:
            return
        if self._tail_start is not None:
            text = self._dec.decode(b"", final=True)
            self._dec.reset()
            if self._v14 and text and not text.isascii():
                text = text.translate(_C1_DROP)
            if text:
                if self._pr_start is None:
                    self._pr_start = self._tail_start
                self._pr_parts.append(text)
                self._pr_end = pos
            self._tail_start = None
        self._flush_print()

    # ------------------------------------------------------------ bytes ---

    def _byte(self, c, pos):
        st = self.state
        if self._u8 and c < 0x20 and c != 0x1B and st != GROUND and self._u8_resets(st, c):
            self._u8_drop()
        if st == GROUND:
            if c == 0x1B:
                self._ground_esc(pos)
                self.state = ESCAPE
                self._params.clear()
                self._inter.clear()
                self._seq_start = pos
            elif c <= self._c0_max:
                self._ground_c0(pos)
                self._execute(c, pos)
            else:
                self._ground_text(bytes((c,)), pos)
        elif st == ST_PENDING:
            self._pending_byte(c, pos)
        elif st == TMUX_BODY:
            self._tmux_byte(c, pos)
        elif st == TMUX_ESC:
            self._tmux_esc_byte(c, pos)
        else:
            self._table_byte(c, pos)

    def _table_byte(self, c, pos):
        st = self.state
        if st == CSI_PARAM:
            # stream.zig nextNonUtf8, csi_param fast path (ahead of the table)
            if c <= 0x0F:
                self._execute(c, pos)
                return
            if c == 0x18 or c == 0x1A:
                self._cut("csi", self._seq_start)
                self.state = GROUND
                return
            if 0x10 <= c <= 0x17 or c == 0x19 or 0x1C <= c <= 0x1F or c == 0x7F:
                return
            if 0x30 <= c <= 0x39 or c == 0x3A or c == 0x3B:
                self._params.append(c)
                return
        if c == 0x1B and st in _STRING_STATES:
            # the string may end with ESC \ (ST): wait for the next byte
            self._pend_kind = st
            self._pend_pos = pos
            self.state = ST_PENDING
            return
        if c == 0x1B or c == 0x18 or c == 0x1A:
            self._abort(st, c, pos)
            if c == 0x1B:
                # an ESC always starts a new escape sequence, even inside one
                self._seq_start = pos
                self._params.clear()
                self._inter.clear()
        idx = (st << 8) | c
        nxt = self._next[idx]
        act = self._act[idx]
        if nxt != st and st in _STRING_STATES and c != 0x1B and c != 0x18 and c != 0x1A:
            # a string left by a C1 byte or BEL (BEL ends OSC; 0x9C ends with ST)
            if st == OSC_STRING and c == 0x07:
                self._end_string(st, pos + 1, False, b"\x07")
            elif c == 0x9C:
                self._end_string(st, pos + 1, False, b"\x9c")
            else:
                self._end_string(st, pos, True, b"", self._v14)
                self._cut_string(st, self._seq_start)
        self.state = nxt
        if nxt != st and nxt in _SEQ_INTRO_STATES:
            if nxt == ESCAPE or st != ESCAPE:
                self._seq_start = pos
            if nxt in (ESCAPE, CSI_ENTRY, DCS_ENTRY):
                self._params.clear()
                self._inter.clear()
            if nxt == OSC_STRING:
                self._str = bytearray()
            elif nxt == SOS_PM_APC_STRING:
                self._str = bytearray()
                self._str_kind = _SOS_INTRO.get(c, APC)
        if nxt == DCS_ENTRY and st != DCS_ENTRY:
            self._dcs_t0 = self._feed_t
        if nxt == DCS_PASSTHROUGH and st != DCS_PASSTHROUGH:
            self._enter_dcs(c)
        if act == A_NONE or act == A_IGNORE:
            return
        if act == A_EXECUTE:
            self._execute(c, pos)
        elif act == A_COLLECT:
            if len(self._inter) < MAX_INTERMEDIATE:
                self._inter.append(c)
        elif act == A_PARAM:
            self._params.append(c)
        elif act == A_ESC_DISPATCH:
            self._emit(ESC, (bytes(self._inter), c), self._seq_start, pos + 1)
        elif act == A_CSI_DISPATCH:
            self._dispatch_csi(bytes(self._params), bytes(self._inter), c, self._seq_start, pos + 1)
        elif act == A_PUT:
            self._dcs_put(c)
        elif act == A_OSC_PUT or act == A_APC_PUT:
            self._str.append(c)

    def _abort(self, st, c, pos):
        """ESC, CAN or SUB arrives in a non-ground state (strings handled elsewhere)."""
        if st in _CSI_STATES:
            self._cut("csi", self._seq_start)
        elif st in _ESC_STATES:
            self._cut("esc", self._seq_start)
        elif st in _DCS_STATES:
            self._cut("dcs", self._seq_start)
        elif st == DCS_PASSTHROUGH:
            self._end_string(st, pos, True, b"")
            self._cut_string(st, self._seq_start)
        elif st == OSC_STRING:
            self._end_string(st, pos, True, b"", self._v14 and c != 0x1B)
            self._cut_string(st, self._seq_start)
        elif st == SOS_PM_APC_STRING:
            self._end_string(st, pos, True, b"", self._v14 and c != 0x1B)
            self._cut_string(st, self._seq_start)

    def _execute(self, c, pos):
        self._emit(EXEC, c, pos, pos + 1)

    def _enter_dcs(self, final):
        """The DCS hook: its params and intermediates are fixed now."""
        nsep = self._params.count(b";") + self._params.count(b":")
        self._dcs_ok = nsep < MAX_PARAMS
        self._dcs_final = final
        self._dcs_params = bytes(self._params)
        self._dcs_inter = bytes(self._inter)
        self._str = bytearray()
        if self._tmux_on and final == 0x74 and not self._dcs_params and not self._dcs_inter:
            # tmux's dcs_handler state from here to ESC \. The final t is the first
            # stored byte (tmux input_input in dcs_enter); the t is counted as 1.
            self._dcs_mode = "tmux"
            self._tmux_start = self._seq_start
            self._tmux_t0 = self._dcs_t0
            self._body = bytearray(b"t")
            self._tmux_n = 1
            self._tmux_discard = False
            self.state = TMUX_BODY
        else:
            self._dcs_mode = "normal"

    def _dcs_put(self, c):
        self._str.append(c)

    def _reset_tmux(self):
        """Forget the passthrough DCS in progress (the parser goes to ground)."""
        self._dcs_mode = None
        self._body = bytearray()
        self._tmux_n = 0
        self._tmux_discard = False
        self._tmux_t0 = None

    def _tmux_store(self, c):
        """tmux input_input for one byte. The store that would make the stored data
        reach the limit sets INPUT_DISCARD; after that bytes are only counted."""
        if not self._tmux_discard and self._tmux_n == self._tmux_limit - 1:
            self._tmux_discard = True
            self._body = bytearray()
        if not self._tmux_discard:
            self._body.append(c)
        self._tmux_n += 1

    def _tmux_run(self, run):
        """A run of tmux body bytes with no ESC: the same as storing each byte."""
        count = len(run)
        if not self._tmux_discard and self._tmux_n + count >= self._tmux_limit:
            self._tmux_discard = True
            self._body = bytearray()
        if not self._tmux_discard:
            self._body += run
        self._tmux_n += count

    def _timer_drop(self, elapsed):
        """tmux's 5 s timer fired before this chunk arrived: input_reset drops the
        DCS, and the chunk is parsed from ground."""
        start = self._tmux_start
        self.discards.append((start, self._tmux_n, "timer"))
        self.cuts.append((start, "dcs"))
        self.warnings.append("tmux timer: passthrough DCS open %.1f s, dropped" % elapsed)
        self._reset_tmux()
        self._dcs_t0 = None
        self.state = GROUND

    def _timer_drop_open(self, elapsed):
        """The same timer, fired while the DCS was still before its final byte (dcs_entry,
        dcs_param, dcs_intermediate). tmux has stored nothing yet, so the discard is
        0 bytes; the chunk is parsed from ground."""
        start = self._seq_start
        self.discards.append((start, 0, "timer"))
        self.cuts.append((start, "dcs"))
        self.warnings.append("tmux timer: DCS open %.1f s before its final byte, dropped" % elapsed)
        self._dcs_t0 = None
        self.state = GROUND

    def _dispatch_csi(self, params, inter, final, start, end):
        if len(inter) > MAX_INTERMEDIATE:
            inter = inter[:MAX_INTERMEDIATE]
        nsep = params.count(b";") + params.count(b":")
        if nsep >= MAX_PARAMS:
            self.warnings.append("CSI with too many parameters dropped")
            return
        if b":" in params and final != 0x6D:
            self.warnings.append("CSI colon separators only allowed for m, dropped")
            return
        self._emit(CSI, (params, inter, final), start, end)

    # ------------------------------------------------------------ strings ---

    def _end_string(self, kind, end, cut, term, discard=False):
        """Emit the token of a string that ends at `end`. discard drops an OSC or an APC (SOS, PM)
        that CAN, SUB or a C1 control other than ST ended (1.4.0: the string is thrown away)."""
        start = self._seq_start
        if discard and kind in (OSC_STRING, SOS_PM_APC_STRING):
            return
        if kind == OSC_STRING:
            self._emit(OSC, (bytes(self._str), term), start, end, cut)
        elif kind == SOS_PM_APC_STRING:
            self._emit(self._str_kind or APC, bytes(self._str), start, end, cut)
        elif kind == DCS_PASSTHROUGH:
            if not self._dcs_ok:
                self.warnings.append("DCS with too many parameters dropped")
                return
            self._emit(DCS, (self._dcs_params, self._dcs_inter, self._dcs_final, bytes(self._str)),
                       start, end, cut)

    def _pending_byte(self, c, pos):
        kind = self._pend_kind
        if c == 0x5C:
            self.state = GROUND
            self._end_string(kind, pos + 1, False, b"\x1b\\")
            return
        esc = self._pend_pos
        self._end_string(kind, esc, True, b"")
        self._cut_string(kind, self._seq_start)
        self.state = ESCAPE
        self._seq_start = esc
        self._params.clear()
        self._inter.clear()
        self._table_byte(c, pos)

    # ------------------------------------------------------------- tmux ---

    def _tmux_byte(self, c, pos):
        """dcs_handler: ESC leaves for dcs_escape; every other byte, CAN and SUB
        included, is stored."""
        if c == 0x1B:
            self.state = TMUX_ESC
            return
        self._tmux_store(c)

    def _tmux_esc_byte(self, c, pos):
        """dcs_escape: ESC ESC stores one ESC, ESC \\ ends the DCS, and ESC before any
        other byte is dropped while that byte is stored."""
        if c == 0x1B:
            self._tmux_store(0x1B)
            self.state = TMUX_BODY
            return
        if c == 0x5C:
            self.state = GROUND
            self._finish_tmux(pos + 1)
            return
        self.warnings.append("tmux body: lone ESC before 0x%02x dropped" % c)
        self._tmux_store(c)
        self.state = TMUX_BODY

    def _finish_tmux(self, end):
        """input_dcs_dispatch: forward the body when the data starts with tmux; and
        parse it with a fresh tokenizer, its tokens taking the DCS span. Otherwise,
        or when the buffer hit the limit, the DCS is dropped and recorded."""
        start = self._tmux_start
        stored = self._tmux_n
        if self._tmux_discard:
            self.discards.append((start, stored, "limit"))
            self.warnings.append("tmux drops a passthrough DCS of %d bytes (limit %d)"
                                 % (stored, self._tmux_limit - 1))
            self._reset_tmux()
            self._flush_print()
            return
        data = bytes(self._body)
        if data[:5] != b"tmux;":
            self.discards.append((start, stored, "not_tmux"))
            self.warnings.append("DCS dropped by tmux: not a tmux; passthrough")
            self._reset_tmux()
            self._flush_print()
            return
        body = data[5:]
        self._reset_tmux()
        self._flush_print()
        inner_tokens = []
        # the body goes to Ghostty, which decodes it by its own rule (utf8 stays "ghostty")
        inner = Tokenizer(inner_tokens.append, strings_only=self._strings_only,
                          tmux_passthrough=False, _force_slow=self._force_slow)
        inner.feed(body, 0)
        inner.finish()
        ordinal = 0
        for tok in inner_tokens:
            if tok.kind == APC:
                number = ordinal
                ordinal += 1
            else:
                number = 0
            if self._strings_only and tok.kind != APC:
                continue
            self._sink(_TOKEN_NEW(Token,
                                  (tok.kind, tok.payload, start, end, tok.cut, number, True)))
        for _start, kind in inner.cuts:
            self.cuts.append((start, kind))
        self.warnings.extend(inner.warnings)

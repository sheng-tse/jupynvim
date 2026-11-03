"""A Ghostty terminal model (profiles for 1.4.0 and 1.3.1): the text grid, styles, modes,
cursor, scroll regions, alternate screens and mode 2027 grapheme clustering.

The operations follow Ghostty's sources (paths relative to the Ghostty repo):

    src/terminal/Terminal.zig     print (mode 2027 block, VS15/VS16, wide
                                  handling), printWrap, printCell, index,
                                  reverseIndex, cursor moves, setCursorPos,
                                  margins, scrollUp/Down, insert/deleteLines,
                                  insert/deleteBlanks, deleteChars, eraseChars,
                                  eraseLine, eraseDisplay, tab stops,
                                  saveCursor/restoreCursor, switchScreenMode
    src/terminal/stream.zig       execute (C0, and C1 as ESC), csiDispatch
                                  (parameter defaults per final byte), escDispatch
                                  and configureCharset, the csi_param fast path
    src/terminal/stream_readonly.zig   setMode side effects (origin, screens, ...)
    src/terminal/Screen.zig       setAttribute, clearCells (blank = background
                                  colour only: erase colour, BCE)
    src/terminal/charsets.zig     ASCII, British and DEC special graphics tables
    src/terminal/modes.zig        mode numbers and defaults

Cells are stored per row as three parallel lists (text, style id, wide), so a run
of text is one list slice assignment. A blank cell has text "" and width 1 (Ghostty's
codepoint 0); a spacer tail has text "" and wide 0; a spacer head has text "" and
wide 3. The snapshot maps these to the (text, style, width) triples of
snapshot.py.

Sequences reach the model through tokens.Tokenizer, one per channel. The hop
is "none" (a bare Ghostty: a raw APC executes, a
DCS tmux; is ignored) or "tmux" (the tokenizer unwraps passthrough DCSs by tmux
3.5a's rules; a raw APC never reaches the terminal, so it is dropped). Under hop "tmux" the
ground text is also decoded by tmux's UTF-8 rule, not Ghostty's: an unfinished character
stays open across an escape sequence, a string or a passthrough body, and finishes when its
last byte arrives (tokens.py, module docstring). With hop "none" the tokenizer keeps
Ghostty's decoder, which prints a replacement character for the interrupted bytes.

Not modelled (documented gaps, see tests/lib/vkitty/README.md):

- Reflow on resize. The primary screen reflows when wraparound is on; here its columns are
  cut or extended as on the alternate screen (resizeWithoutReflow), and a column grow treats
  its rows as copied into new pages (resizeCols): soft-wrap flags reset, a spacer head in the
  old last column narrowed. Rows shrink and grow as resizeWithoutReflow does, in the order of
  PageList.resize.
- Rows pulled back from history when the rows grow with the cursor on the bottom row: the
  primary screen's history, and the rows ED 22 sends above the alternate screen's active
  area (Ghostty keeps them there until a resize erases them).
- Page boundaries and page memory. Each screen is one page whose column capacity is the
  width it was made at (Screen.cap_cols). Rows that PageList.grow takes back within a page
  after a trim (their old cells and flags) and screens split across pages are not modelled.
- Reverse wrap (modes 45 and 1045), left and right margins (DECLRMM 69), protected cells
  (DECSCA, selective erase), scrollback contents (only the count of rows sent into history
  is kept, in Screen.scrolled, on the primary screen), DECALN (ESC # 8), DECRQSS and
  capability replies, among them the in-band size report of mode 2048 on a resize.
- Semantic prompts (OSC 133): ED 2 never takes Ghostty's at-prompt scroll clear, and a
  resize never clears a prompt line.
- VS15 on the head of a wide character that a column cut left in the last column, with the
  cursor on it: Ghostty looks for the tail at cursorCellLeft(prev.left - 1) with prev.left
  0, an unsigned underflow whose result is undefined. The model narrows the head only.

A column cut keeps a wide head in the new last column without its tail (page.clearCells has
no wide handling), as Ghostty does. A line shift (insertLines or deleteLines, through
rowWillBeShifted) turns that head into a blank narrow cell; a whole-row scroll keeps it. A
later wide print over that head clears the next cell as if it were the tail, in Ghostty too,
so a spacer tail can then follow a cleared cell, against Ghostty's own page integrity rule for
spacer tails (vt/wide_cells_keep_page_integrity checks the spacer head rules on such a screen
and the spacer tail rule everywhere else).

Soft-wrap flags (Row.wrapped and Row.cont) follow Ghostty's row structs. The blank row
that a partial-region index creates gets the erased row's flags (eraseRowBounded, one
row, single page). The other whole-row scrolls (cursorScrollAbove, cursorDownScroll, and
eraseRow on the alternate screen, which keeps the erased top row's flags in Ghostty) give
the new row no flags here: the page memory Ghostty reuses is not modelled, and no screen
the battery or the spec can build makes that row's flag visible. A continuation at row 0
would clear a spacer head in history (not modelled; no screen shows it).
"""
import copy

from vkitty import charsets_dec as _charsets_dec
from vkitty import style as _style
from vkitty import tokens as _tokens
from vkitty import widths as _widths
from vkitty import kgp as _kgp
from vkitty import media as _media
from vkitty import snapshot as _snapshot
from vkitty.snapshot import Snapshot

PRINT, EXEC, ESC, CSI, OSC, DCS, APC, SOS_PM = range(8)
HOP_NONE = "none"     # a bare Ghostty: a raw APC executes, a passthrough DCS is ignored
HOP_TMUX = "tmux"     # behind tmux 3.5a: passthrough unwrapped by tmux's rules, raw APC dropped
# behind tmux 3.5a with allow-passthrough off (the tmux default): tmux drops every DCS tmux; and
# every raw APC, so nothing graphical reaches the terminal. Internally the hop is HOP_TMUX (the
# tokenizer, the UTF-8 rule, the VT queries tmux answers) with `passthrough` false.
HOP_TMUX_OFF = "tmux-off"

_GB_EXT_PICT = _widths.GB_INDEX["extended_pictographic"]
_DEFAULT_TABSTOP_INTERVAL = 8
_WIDE_TAIL, _WIDE_NARROW, _WIDE_HEAD, _WIDE_SPACER_HEAD = 0, 1, 2, 3

# charsets.zig: the tables Ghostty maps through (a code point above 0xFF becomes a space)
_BRITISH = {0x23: 0x00A3}
_DEC_SPECIAL = _charsets_dec.DEC_SPECIAL
_CHARSET_TABLES = {"british": _BRITISH, "dec_special": _DEC_SPECIAL}
_DEC_TRANSLATE = {k: chr(v) for k, v in _DEC_SPECIAL.items()}

# modes.zig: the numbers this model knows (ANSI and DEC private)
_ANSI_MODES = (2, 4, 12, 20)
_DEC_MODES = (1, 3, 4, 5, 6, 7, 8, 9, 12, 25, 40, 45, 47, 66, 69, 1000, 1002, 1003, 1004,
              1005, 1006, 1007, 1015, 1016, 1035, 1036, 1039, 1045, 1047, 1048, 1049,
              2004, 2026, 2027, 2031, 2048)
_DEC_DEFAULT_ON = (7, 25, 1007, 1035, 1036)


def _default_tabstops(cols):
    return [(x % _DEFAULT_TABSTOP_INTERVAL == 0 and x > 0) for x in range(cols)]


class Row:
    """One row. `wrapped` is Ghostty's Row.wrap (the row ends in a soft wrap) and `cont` is
    Row.wrap_continuation (the row starts with the rest of a wrapped line); they are kept apart
    because they are set, cleared and moved independently."""
    __slots__ = ("text", "sid", "wide", "wrapped", "cont")

    def __init__(self, cols, sid=0):
        self.text = [""] * cols
        self.sid = [sid] * cols
        self.wide = [_WIDE_NARROW] * cols
        self.wrapped = False
        self.cont = False


class Screen:
    """One screen (primary or alternate): the grid, the cursor and its pen, the
    saved cursor and the character sets. `base` is the row space offset of the pins: the rows
    Ghostty's grow moved this screen's active area down, so a pin's row in the screen is abs_y -
    base."""

    def __init__(self, cols, rows, kitty_limit=_kgp.DEFAULT_STORAGE_LIMIT):
        self.grid = [Row(cols) for _ in range(rows)]
        self.x = 0
        self.y = 0
        self.base = 0
        self.pending = False          # the pending-wrap flag
        self.pen = _style.DEFAULT_STYLE
        self.pen_sid = 0
        self.shape = "block"
        self.saved = None
        self.charsets = ["ascii", "ascii", "ascii", "ascii"]   # G0..G3
        self.gl = 0
        self.gr = 1
        self.single = None            # single shift slot (SS2/SS3) for the next print
        self.scrolled = 0             # rows that left the top of this screen into history
        self.cap_cols = cols          # the page's column capacity: the width it was made at
        self.kitty = None             # the image storage, made on first use (Terminal._kitty)
        self.kitty_limit = int(kitty_limit)   # the limit that storage is made with


def _pins_of(sc):
    """The pins of a screen's image storage (none before the storage exists, or with no pin)."""
    st = sc.kitty
    if st is None or not st.pins:
        return ()
    return [pl.location for pl in st.placements.values() if pl.location is not None]


def _erase_history_pins(sc):
    """eraseRows over history (ED 3, and the alternate screen's history erase after a resize): a pin
    in an erased row moves to row 0, column 0 of the page (PageList.eraseRows). The pins of the
    active area keep their place in the row space."""
    for pin in _pins_of(sc):
        if pin.abs_y < sc.base:
            pin.abs_y = sc.base
            pin.x = 0


def _storage_limit(sc):
    """The byte limit of a screen's image storage: the storage's own once it exists, else the limit
    it will be made with (Ghostty's Screen.kitty_images.total_limit)."""
    return sc.kitty.total_limit if sc.kitty is not None else sc.kitty_limit


class Terminal:
    """A Ghostty terminal model (1.4.0 or 1.3.1, by profile) that takes a byte stream per channel.

    hop says what sits between the program and the terminal. Under "tmux" the outer stream's UTF-8
    is decoded as tmux 3.5a decodes it and passthrough bodies follow tmux's rules (the size
    limit, the 5 s timer, what reaches the terminal); under "none" Ghostty's rules apply.
    """

    def __init__(self, cols, rows, *, cell=(13, 33), pad=4, profile="ghostty-1.3.1", hop="none",
                 media=None, tmpdir=None, storage_limit=320_000_000, respond=None, clock=None,
                 grapheme_cluster=True):
        if hop not in (HOP_NONE, HOP_TMUX, HOP_TMUX_OFF):
            raise ValueError("hop must be none, tmux or tmux-off, not %r" % (hop,))
        if cols < 1 or rows < 1:
            raise ValueError("a terminal needs at least 1 column and 1 row")
        self.cols = int(cols)
        self.rows = int(rows)
        self.cell = tuple(cell)
        self.pad = int(pad)
        self.profile = profile
        self._w = _widths.tables_for(profile)        # the widths and grapheme breaks of its version
        self._v14 = _kgp.is_140(profile)
        self.passthrough = hop != HOP_TMUX_OFF
        self._off_span = None
        self.hop = HOP_TMUX if hop == HOP_TMUX_OFF else hop
        self.media = media if media is not None else _media.DirectMedia(tmpdir)
        self.tmpdir = tmpdir
        self.storage_limit = storage_limit
        self.respond = respond
        self.clock = clock
        self.styles = _style.StyleTable()
        self.warnings = []
        self.responses = []
        # Schema notes: transmit_wire_bytes is the base64 length of the payload of every
        # a=t, a=T and a=q command, a query included, since a query sends its payload too; a query
        # stores nothing, so only a transmission has a by_image entry. queries counts the Kitty a=q
        # commands; vt_queries counts every DA and DSR the model parses, under both hops. splices
        # counts the escape sequences that interrupted an unfinished UTF-8 character (both hops).
        # tmux body_other counts the tokens other than APC that passthrough bodies carry: tmux
        # hands them to the outer terminal, which draws them outside tmux's own grid.
        self.stats = {
            "tui_bytes": 0, "gfx_bytes": 0, "apc": 0, "apc_bytes": 0, "transmit_wire_bytes": 0,
            "cuts": 0, "splices": 0, "queries": 0, "vt_queries": 0, "enoent": 0, "deletes": 0,
            "media": {"d": 0, "f": 0, "t": 0, "s": 0},
            "tmux": {"discards": 0, "timer_drops": 0, "dropped_apc": 0, "ignored_dcs": 0,
                     "body_other": 0},
            "by_image": {},
            "since_prev_mark": {"apc_bytes": 0, "transmit_wire_bytes": 0},
        }
        self._tokenizers = {}
        self._offsets = {}
        self._tk_seen = {}
        self._apc_handler = self._graphics_apc   # the Kitty graphics layer (kgp)
        self._now = None               # the latest arrival time given to feed (animation time)
        self._dec = {}
        self._ansi = {}
        self._saved_dec = {}
        self.previous_char = None
        self.sync = False              # DECSET 2026 is on
        self.primary = Screen(self.cols, self.rows, self.storage_limit)   # the configured limit
        self.alternate = None
        self.active = self.primary
        self.key = "pri"
        self.top = 0
        self.bottom = self.rows - 1
        self.tabstops = _default_tabstops(self.cols)
        self._grapheme_default = bool(grapheme_cluster)   # what RIS restores (modes.reset)
        self._reset_modes(grapheme_cluster)

    # ------------------------------------------------------------ modes ---

    @property
    def grapheme_cluster(self):
        return self._dec.get(2027, False)

    def _reset_modes(self, grapheme_cluster=None):
        if grapheme_cluster is None:
            grapheme_cluster = self.grapheme_cluster
        self._dec = {m: True for m in _DEC_DEFAULT_ON}
        self._dec[2027] = bool(grapheme_cluster)
        self._ansi = {12: True}
        self._saved_dec = {}

    def _wrap_on(self):
        return self._dec.get(7, False)

    def _insert_on(self):
        return self._ansi.get(4, False)

    # ------------------------------------------------------------ feeding ---

    def feed(self, data, channel="tui", t=None):
        """Process bytes of one channel ("tui" or "gfx"); t is the arrival time in
        seconds (tmux's passthrough timer), None when unknown."""
        data = bytes(data)
        if t is not None:
            self._now = t
        if channel == "gfx":
            self.stats["gfx_bytes"] += len(data)
        else:
            self.stats["tui_bytes"] += len(data)
        tk = self._tokenizers.get(channel)
        if tk is None:
            tk = self._make_tokenizer(channel)
        off = self._offsets.get(channel, 0)
        tk.feed(data, off, t)
        self._offsets[channel] = off + len(data)
        self._collect(channel, tk)

    def _make_tokenizer(self, channel):
        def sink(tok, _ch=channel):
            self._on_token(tok, _ch)
        tk = _tokens.Tokenizer(sink, tmux_passthrough=(self.hop == HOP_TMUX),
                               utf8=(_tokens.UTF8_TMUX if self.hop == HOP_TMUX
                                     else _tokens.UTF8_GHOSTTY),
                               v14=_kgp.is_140(self.profile))
        self._tokenizers[channel] = tk
        # cuts, discards, warnings, splices already counted
        self._tk_seen[channel] = [0, 0, 0, 0]
        return tk

    def _collect(self, channel, tk):
        """Count what the tokenizer recorded since the last feed."""
        seen = self._tk_seen[channel]
        if len(tk.cuts) > seen[0]:
            self.stats["cuts"] += len(tk.cuts) - seen[0]
            seen[0] = len(tk.cuts)
        if len(tk.splices) > seen[3]:
            self.stats["splices"] += len(tk.splices) - seen[3]
            seen[3] = len(tk.splices)
        if len(tk.discards) > seen[1]:
            tmux = self.stats["tmux"]
            for _start, _n, reason in tk.discards[seen[1]:]:
                if reason == "timer":
                    tmux["timer_drops"] += 1
                else:
                    tmux["discards"] += 1
            seen[1] = len(tk.discards)
        if len(tk.warnings) > seen[2]:
            self.warnings.extend(tk.warnings[seen[2]:])
            seen[2] = len(tk.warnings)

    def _on_token(self, tok, channel):
        kind = tok.kind
        if tok.via_tmux and not self.passthrough:
            # allow-passthrough off: tmux ignores the whole DCS, its body reaches nobody. The
            # tokens of one DCS share its span, which counts the DCS once
            span = (channel, tok.start, tok.end)
            if span != self._off_span:
                self._off_span = span
                self.stats["tmux"]["ignored_dcs"] += 1
                self.warnings.append("DCS tmux passthrough ignored (allow-passthrough off)")
            return
        if tok.via_tmux and kind != APC:
            self.stats["tmux"]["body_other"] += 1
        if kind == PRINT:
            self._print_text(tok.payload)
        elif kind == CSI:
            self._csi(*tok.payload)
        elif kind == EXEC:
            self._execute(tok.payload)
        elif kind == ESC:
            self._esc(*tok.payload)
        elif kind == APC:
            self._apc(tok, channel)
        elif kind == DCS:
            # DCS tmux; is final t with data "mux;..." (the t is the final byte, not data)
            _params, _inter, final, data = tok.payload
            if final == 0x74 and data[:4] == b"mux;" and self.hop == HOP_NONE:
                self.stats["tmux"]["ignored_dcs"] += 1
                self.warnings.append("DCS tmux passthrough ignored (hop none)")
        # OSC and SOS/PM strings: nothing a snapshot shows

    def _apc(self, tok, channel):
        if self.hop == HOP_TMUX and not tok.via_tmux:
            # tmux takes a raw APC for the pane title and never forwards it
            self.stats["tmux"]["dropped_apc"] += 1
            self.warnings.append("raw APC dropped by tmux (tmux sets the pane title from it)")
            return
        self.stats["apc"] += 1
        # wire bytes: a raw APC is its own span; the APC tokens of one DCS tmux body share
        # the span of that DCS, which is counted once, on the token with ordinal 0
        if not tok.via_tmux or tok.ordinal == 0:
            wire = tok.end - tok.start
            self.stats["apc_bytes"] += wire
            self.stats["since_prev_mark"]["apc_bytes"] += wire
        if self._apc_handler is not None:
            self._apc_handler(tok, channel)

    def finish(self):
        """End of input on every channel (warnings for unfinished sequences)."""
        for channel, tk in self._tokenizers.items():
            tk.finish()
            self._collect(channel, tk)

    # ------------------------------------------------------------ geometry ---

    def _scroll_region_full(self):
        return self.top == 0 and self.bottom == self.rows - 1

    def _blank_sid(self):
        """Erased cells take the background colour only (Ghostty bgCell, BCE), as a
        background-only blank (StyleTable.intern_bg)."""
        bg = self.active.pen[1]
        if bg is None:
            return 0
        return self.styles.intern_bg(bg)

    def _new_blank_row(self, sid):
        return Row(self.cols, sid)

    def _index(self):
        """Terminal.index: move down, scrolling the region at its bottom margin."""
        sc = self.active
        sc.pending = False
        if sc.y < self.top or sc.y > self.bottom:
            if sc.y < self.rows - 1:
                sc.y += 1
            return
        if sc.y == self.bottom:
            self._scroll_up_region(1, kind="index")
            return
        sc.y += 1

    def _kitty_scroll_begin(self, delta):
        """Ghostty 1.4.0 adjusts the Kitty placements around a scroll of a region that is not the
        whole screen (Terminal.kittyScrollMarginsBegin): see ImageStorage.scroll_margins_begin.
        None when there is nothing to adjust (the 1.3.1 profile, no placements, a full-screen
        region, where placements follow their rows through the pins)."""
        storage = self.active.kitty
        if storage is None or not storage.v14 or not storage.placements:
            return None
        if self._scroll_region_full():
            return None
        return storage.scroll_margins_begin(self, delta)

    def _scroll_up_region(self, count, kind="index"):
        """Scroll the region up (index at the bottom margin, SU) with the placements of the
        1.4.0 profile adjusted around the row operation."""
        margins = self._kitty_scroll_begin(-min(count, self.bottom - self.top + 1)) \
            if count > 0 else None
        self._scroll_up_rows(count, kind)
        if margins is not None:
            margins.end()

    def _scroll_up_rows(self, count, kind="index"):
        """Scroll the region up by count rows. Terminal.zig: a region whose top is row 0 moves
        whole rows whatever its bottom margin (index and scrollUp call cursorScrollAbove, which
        sends the top row into history on the primary screen). Below row 0, index with the default
        background moves whole rows too (eraseRowBounded), and scrollUp or index with a background
        delete lines (_move_region), which unsets the soft-wrap flags of the rows it moves."""
        height = self.bottom - self.top + 1
        count = min(count, height)
        if count <= 0:
            return
        sc = self.active
        if self.top == 0 or (kind == "index" and self._blank_sid() == 0):
            if self.top == 0:
                self._pins_scroll_top(count)
                if self.key == "pri":
                    sc.scrolled += count
            else:
                self._pins_erase_bounded(count)
            sid = self._blank_sid()
            erased = sc.grid[self.top:self.top + count]
            keep = sc.grid[self.top + count:self.bottom + 1]
            fresh = [self._new_blank_row(sid) for _ in range(count)]
            if self.top > 0:
                # eraseRowBounded rotates the erased row to the bottom, flags included
                for new, old in zip(fresh, erased):
                    new.wrapped = old.wrapped
                    new.cont = old.cont
            sc.grid[self.top:self.bottom + 1] = keep + fresh
        else:
            self._move_region(self.top, height, count, insert=False)

    def _pins_scroll_top(self, count):
        """The pins of a whole-row scroll of a region whose top is row 0. Index at the bottom margin
        and scrollUp call cursorScrollAbove (Screen.zig): where it grows the active area (the
        primary screen always, the alternate screen when its region ends above the last row) the
        pins keep their row in the row space and the base moves on; on the alternate screen's
        full-height region cursorDownScroll is eraseRow, which moves every pin below row 0 up one
        row (PageList eraseRow: a pin on the erased row stays put)."""
        sc = self.active
        if self.key == "alt" and self.bottom == self.rows - 1:
            for pin in _pins_of(sc):
                y = pin.abs_y - sc.base
                if y > 0:
                    pin.abs_y -= min(count, y)
        else:
            sc.base += count

    def _pins_erase_bounded(self, count):
        """The pins of eraseRowBounded (index at the bottom margin of a region below row 0, with the
        default background): every pin in the region moves up one row per erased row, so the erased
        top row's pins land above the region (PageList.eraseRowBounded)."""
        sc = self.active
        for pin in _pins_of(sc):
            y = pin.abs_y - sc.base
            if self.top <= y <= self.bottom:
                pin.abs_y -= min(count, y - self.top + 1)

    def _scroll_down_region(self, count):
        """Terminal.scrollDown: insertLines at the top margin (SD, reverse index at the top
        margin), with the placements of the 1.4.0 profile adjusted around it."""
        height = self.bottom - self.top + 1
        count = min(count, height)
        if count <= 0:
            return
        margins = self._kitty_scroll_begin(count)
        self._move_region(self.top, height, count, insert=True)
        if margins is not None:
            margins.end()

    def _in_region_row(self):
        y = self.active.y
        return self.top <= y <= self.bottom

    def _insert_lines(self, count):
        if count == 0 or not self._in_region_row():
            return
        sc = self.active
        rem = self.bottom - sc.y + 1
        self._move_region(sc.y, rem, min(count, rem), insert=True)
        sc.x = 0
        sc.pending = False

    def _delete_lines(self, count):
        if count == 0 or not self._in_region_row():
            return
        sc = self.active
        rem = self.bottom - sc.y + 1
        self._move_region(sc.y, rem, min(count, rem), insert=False)
        sc.x = 0
        sc.pending = False

    def _move_region(self, y, rem, adjusted, insert):
        """Shift rows y .. y+rem-1 by `adjusted` rows (insertLines when insert, else
        deleteLines) and blank the rows that open up. Both call rowWillBeShifted on every row from
        y to the bottom margin. In a full-width region its right cell is the last column: a spacer
        head there becomes a narrow cell, and a wide head there (one a column cut left without its
        tail) becomes a blank narrow cell (codepoint 0, graphemes cleared), both with their style
        kept. Its tail would lie in cells[cols], outside the screen after the cut, so nothing else
        changes. (Its left-cell branch needs a left margin, not modelled: a spacer tail is never
        in column 0.) They unset both flags (wrap and wrap_continuation) of every row a full-width
        shift touches; those are the positions p with p <= rem-1-adjusted or p >= adjusted. The
        other positions are blank rows that keep their own flags, since a flag belongs to the
        physical row."""
        sc = self.active
        region = sc.grid[y:y + rem]
        last = self.cols - 1
        for row in region:
            w = row.wide[last]
            if w == _WIDE_SPACER_HEAD:
                row.wide[last] = _WIDE_NARROW
            elif w == _WIDE_HEAD:
                row.text[last] = ""
                row.wide[last] = _WIDE_NARROW
        old_flags = [(row.wrapped, row.cont) for row in region]
        if insert:
            moved = [None] * adjusted + region[:rem - adjusted]
        else:
            moved = region[adjusted:] + [None] * adjusted
        sid = self._blank_sid()
        out = []
        for p in range(rem):
            row = moved[p]
            if row is None:
                row = self._new_blank_row(sid)
            if p <= rem - 1 - adjusted or p >= adjusted:
                row.wrapped = False
                row.cont = False
            else:
                row.wrapped, row.cont = old_flags[p]
            out.append(row)
        sc.grid[y:y + rem] = out

    def _reverse_index(self):
        sc = self.active
        if sc.y != self.top:
            self._cursor_up(1)
            return
        # scrollDown restores the cursor, its column and its pending-wrap flag
        self._scroll_down_region(1)

    # ------------------------------------------------------------ cursor ---

    def _cursor_up(self, count_req):
        sc = self.active
        sc.pending = False
        if sc.y >= self.top:
            limit = sc.y - self.top
        else:
            limit = sc.y
        sc.y -= min(limit, max(count_req, 1))

    def _cursor_down(self, count_req):
        sc = self.active
        sc.pending = False
        if sc.y <= self.bottom:
            limit = self.bottom - sc.y
        else:
            limit = self.rows - sc.y - 1
        sc.y += min(limit, max(count_req, 1))

    def _cursor_right(self, count_req):
        sc = self.active
        sc.pending = False
        limit = (self.cols - 1) - sc.x          # the right margin is the last column
        sc.x += min(limit, max(count_req, 1))

    def _cursor_left(self, count_req):
        """Terminal.cursorLeft with reverse wrap off (modes 45 and 1045 are not modelled)."""
        sc = self.active
        count = max(count_req, 1)
        sc.x -= min(count, sc.x)
        sc.pending = False

    def _set_pos(self, row_req, col_req):
        """Terminal.setCursorPos: 1-based, 0 counts as 1, clamped; origin mode
        counts from the margins."""
        sc = self.active
        if self._dec.get(6, False):
            y_off = self.top
            x_max = self.cols
            y_max = self.bottom + 1
        else:
            y_off = 0
            x_max = self.cols
            y_max = self.rows
        sc.pending = False
        row = row_req if row_req else 1
        col = col_req if col_req else 1
        sc.x = max(0, min(x_max, col) - 1)
        sc.y = max(0, min(y_max, row + y_off) - 1)

    def _set_top_bottom(self, top_req, bottom_req):
        top = max(1, top_req)
        bottom = min(self.rows, self.rows if bottom_req == 0 else bottom_req)
        if top >= bottom:
            return
        self.top = top - 1
        self.bottom = bottom - 1
        self._set_pos(1, 1)

    def _save_cursor(self):
        sc = self.active
        sc.saved = (sc.x, sc.y, sc.pen, sc.pending, bool(self._dec.get(6, False)),
                    list(sc.charsets), sc.gl, sc.gr, sc.single)

    def _restore_cursor(self):
        sc = self.active
        if sc.saved is None:
            x, y, pen, pending, origin = 0, 0, _style.DEFAULT_STYLE, False, False
            charsets, gl, gr, single = ["ascii"] * 4, 0, 1, None
        else:
            x, y, pen, pending, origin, charsets, gl, gr, single = sc.saved
        sc.pen = pen
        sc.pen_sid = self.styles.intern(pen)
        sc.charsets = list(charsets)
        sc.gl = gl
        sc.gr = gr
        sc.single = single
        self._dec[6] = origin
        sc.pending = pending
        sc.x = min(x, self.cols - 1)
        sc.y = min(y, self.rows - 1)

    def _carriage_return(self):
        sc = self.active
        sc.pending = False
        sc.x = 0

    def _linefeed(self):
        # termio/stream_handler.zig runs LF as terminal.index() only, so LNM (mode 20, which
        # Terminal.linefeed would follow with a carriage return) does not change output LF
        # in the app. The mode is still recorded.
        self._index()

    def _horizontal_tab(self, count):
        for _ in range(count):
            sc = self.active
            before = sc.x
            while sc.x < self.cols - 1:
                sc.x += 1
                if self.tabstops[sc.x]:
                    break
            if sc.x == before:
                break

    def _horizontal_tab_back(self, count):
        for _ in range(count):
            sc = self.active
            before = sc.x
            while sc.x > 0:
                sc.x -= 1
                if self.tabstops[sc.x]:
                    break
            if sc.x == before:
                break

    # ------------------------------------------------------------ erasing ---

    def _erase_cells(self, row, x0, x1, sid):
        """Blank cells [x0, x1) of a row with style sid, as Screen.clearCells: a
        wide character split by the range loses its other half too."""
        cols = self.cols
        if x0 > 0 and row.wide[x0] == _WIDE_TAIL:
            row.text[x0 - 1] = ""
            row.sid[x0 - 1] = sid
            row.wide[x0 - 1] = _WIDE_NARROW
        if x1 < cols and row.wide[x1] == _WIDE_TAIL:
            row.text[x1] = ""
            row.sid[x1] = sid
            row.wide[x1] = _WIDE_NARROW
        if x1 - x0 <= 0:
            return
        row.text[x0:x1] = [""] * (x1 - x0)
        row.sid[x0:x1] = [sid] * (x1 - x0)
        row.wide[x0:x1] = [_WIDE_NARROW] * (x1 - x0)

    def _erase_row(self, row, sid):
        cols = self.cols
        row.text = [""] * cols
        row.sid = [sid] * cols
        row.wide = [_WIDE_NARROW] * cols

    def _clear_row(self, row, sid):
        """Screen.clearRows: the row is cleared and its flags are reset (row.* = .{ .cells })."""
        self._erase_row(row, sid)
        row.wrapped = False
        row.cont = False

    def _erase_line(self, mode):
        sc = self.active
        sc.pending = False
        row = sc.grid[sc.y]
        sid = self._blank_sid()
        if mode == 0:
            # Terminal.eraseLine(.right): a cursor on a spacer tail takes the head with it,
            # and cursorResetWrap runs before the cells are cleared
            x = sc.x
            if x > 0 and row.wide[x] == _WIDE_TAIL:
                x -= 1
            self._reset_wrap()
            self._erase_cells(row, x, self.cols, sid)
        elif mode == 1:
            self._erase_cells(row, 0, sc.x + 1, sid)
        elif mode == 2:
            self._erase_row(row, sid)

    def _erase_display(self, mode):
        """Terminal.eraseDisplay: ED 0 is eraseLine(.right) on the cursor row (with
        cursorResetWrap) and clearRows below; ED 1 is eraseLine(.left) and clearRows above; ED 2
        clears every row; ED 22 is Screen.scrollClear (_scroll_clear). Rows that clearRows clears
        lose their flags, as the row struct is reset."""
        sc = self.active
        if mode == 3:
            _erase_history_pins(sc)      # scrollback only: the visible grid is kept
            return
        grid = sc.grid
        if mode == 0:
            self._erase_line(0)
            sid = self._blank_sid()
            for y in range(sc.y + 1, self.rows):
                self._clear_row(grid[y], sid)
        elif mode == 1:
            self._erase_line(1)
            sid = self._blank_sid()
            for y in range(0, sc.y):
                self._clear_row(grid[y], sid)
        elif mode == 22:
            self._scroll_clear()
            sc.pending = False
            self._kitty_delete_all()     # after the scroll, whether or not it moved a row
        else:                            # 2 complete
            sc.pending = False
            sid = self._blank_sid()
            for row in grid:
                self._clear_row(row, sid)
            self._kitty_delete_all()     # Ghostty's delete .all with images

    def _scroll_clear(self):
        """Screen.scrollClear. PageList.scrollClear finds the last row that holds a cell which is
        not Cell.isEmpty (_row_is_empty) and grows the screen by the rows down to it, so they leave
        the top (into history on the primary screen) and default rows open at the bottom: no
        background, as clearRows does not run. cursorReload then moves the cursor up with its row,
        or to the top-left when its row left."""
        sc = self.active
        grid = sc.grid
        bg_cells = self.styles.bg_cells
        n = 0
        for y in range(len(grid) - 1, -1, -1):
            if not _row_is_empty(grid[y], bg_cells):
                n = y + 1
                break
        if n == 0:
            return
        del grid[:n]
        grid.extend(Row(self.cols) for _ in range(n))
        sc.base += n                   # PageList.scrollClear grows the screen: pins keep their row
        if self.key == "pri":
            sc.scrolled += n
        if sc.y < n:
            sc.x = 0
            sc.y = 0
        else:
            sc.y -= n

    def _split_boundary(self, x):
        """Screen.splitCellBoundary on the cursor row, for the boundary before cell x. A wide
        character that the boundary would cut is cleared with its partner. A spacer head at the
        end of a wrapped row is cleared at the right margin. At the start of a continuation row
        (the row's own flag) whose first cell is a wide head, the spacer head on the row above is
        cleared too."""
        sc = self.active
        cols = self.cols
        y = sc.y
        row = sc.grid[y]
        sid = self._blank_sid()
        if x == cols:
            if row.wrapped and row.wide[cols - 1] == _WIDE_SPACER_HEAD:
                self._blank_raw(row, cols - 1, cols, sid)
            return
        if (x == 0 or x == 1) and row.cont and y > 0 and row.wide[0] == _WIDE_HEAD:
            above = sc.grid[y - 1]
            if above.wide[cols - 1] == _WIDE_SPACER_HEAD:
                self._blank_raw(above, cols - 1, cols, sid)
        if x == 0:
            return
        if row.wide[x - 1] == _WIDE_HEAD:
            self._blank_raw(row, x - 1, x + 1, sid)

    def _reset_wrap(self):
        """Screen.cursorResetWrap: clear the pending-wrap flag. If the row wraps, clear its wrap
        flag and the continuation flag of the row below, and clear a spacer head in the last
        column with the cursor's background (blankCell)."""
        sc = self.active
        sc.pending = False
        y = sc.y
        row = sc.grid[y]
        if not row.wrapped:
            return
        row.wrapped = False
        if y + 1 < self.rows:
            sc.grid[y + 1].cont = False
        cols = self.cols
        if row.wide[cols - 1] == _WIDE_SPACER_HEAD:
            self._blank_raw(row, cols - 1, cols, self._blank_sid())

    def _blank_raw(self, row, x0, x1, sid):
        """Screen.clearCells: blank cells [x0, x1) with one style. The callers split the
        wide characters at the edges first (splitCellBoundary)."""
        if x1 <= x0:
            return
        row.text[x0:x1] = [""] * (x1 - x0)
        row.sid[x0:x1] = [sid] * (x1 - x0)
        row.wide[x0:x1] = [_WIDE_NARROW] * (x1 - x0)

    def _erase_chars(self, count_req):
        """Terminal.eraseChars: a count of 0 is 1, a range that ends on a wide head takes
        its tail too, the range's edges are split, and the wrap state is reset."""
        sc = self.active
        x = sc.x
        row = sc.grid[sc.y]
        cols = self.cols
        remaining = cols - x
        count = min(remaining, max(count_req, 1))
        if count != remaining and row.wide[x + count - 1] == _WIDE_HEAD:
            count += 1
        self._split_boundary(x)
        self._split_boundary(x + count)
        self._reset_wrap()
        self._blank_raw(row, x, x + count, self._blank_sid())

    def _delete_chars(self, count_req):
        """Terminal.deleteChars: the run is split at its start, its end and the right
        margin, the cells to its right shift left, and the freed cells take the background."""
        if count_req == 0:
            return
        sc = self.active
        x = sc.x
        row = sc.grid[sc.y]
        cols = self.cols
        rem = cols - x
        count = min(count_req, rem)
        self._split_boundary(x)
        self._split_boundary(x + count)
        self._split_boundary(cols)
        keep = cols - count
        row.text[x:keep] = row.text[x + count:cols]
        row.sid[x:keep] = row.sid[x + count:cols]
        row.wide[x:keep] = row.wide[x + count:cols]
        self._blank_raw(row, keep, cols, self._blank_sid())
        self._reset_wrap()

    def _insert_blanks(self, count_req):
        """Terminal.insertBlanks: a cursor on a spacer tail takes the pair left of it with it
        ((left - 1)[0..2]); a wide character that the shift would carry onto the last column
        is cleared first; then the cells shift right and the gap takes the background."""
        sc = self.active
        sc.pending = False
        if count_req == 0:
            return
        x = sc.x
        row = sc.grid[sc.y]
        cols = self.cols
        sid = self._blank_sid()
        if x > 0 and row.wide[x] == _WIDE_TAIL:
            self._blank_raw(row, x - 1, x + 1, sid)
        rem = cols - x
        count = min(count_req, rem)
        scroll = rem - count
        if scroll > 0:
            end = x + scroll - 1
            if row.wide[end] == _WIDE_HEAD:
                self._blank_raw(row, end, end + 2, sid)
            row.text[x + count:cols] = row.text[x:cols - count]
            row.sid[x + count:cols] = row.sid[x:cols - count]
            row.wide[x + count:cols] = row.wide[x:cols - count]
        self._blank_raw(row, x, x + count, sid)

    # ------------------------------------------------------------ printing ---

    def _put(self, x, y, text, wide):
        """The cell write of Terminal.printCell: write one cell with the pen, fixing a wide
        character it overwrites (the other half is cleared, a spacer head before it is
        narrowed). printCell's charset block runs first, on every call; callers do it
        through _mapped (a printed character) or _put_spacer (a spacer or blank)."""
        sc = self.active
        row = sc.grid[y]
        cur = row.wide[x]
        if cur != wide:
            if cur == _WIDE_HEAD:
                if x < self.cols - 1:
                    row.text[x + 1] = ""
                    row.sid[x + 1] = self._blank_sid()
                    row.wide[x + 1] = _WIDE_NARROW
                    if y > 0 and x <= 1:
                        self._narrow_prev_head(y)
            elif cur == _WIDE_TAIL:
                if x > 0:
                    row.text[x - 1] = ""
                    row.sid[x - 1] = self._blank_sid()
                    row.wide[x - 1] = _WIDE_NARROW
                if y > 0 and x <= 1:
                    self._narrow_prev_head(y)
        row.text[x] = text
        row.sid[x] = sc.pen_sid
        row.wide[x] = wide

    def _put_spacer(self, x, y, wide):
        """printCell(0, wide) for a spacer head, a spacer tail or the blank written on a
        one column screen. printCell maps its character on every call, so a pending single
        shift is spent here as well."""
        self._mapped(0)
        self._put(x, y, "", wide)

    def _narrow_prev_head(self, y):
        prev = self.active.grid[y - 1]
        if prev.wide[self.cols - 1] == _WIDE_SPACER_HEAD:
            prev.wide[self.cols - 1] = _WIDE_NARROW

    def _mapped(self, cp):
        """printCell's character set mapping for one printed code point."""
        sc = self.active
        if sc.single is not None:
            slot = sc.single
            sc.single = None
        else:
            slot = sc.gl
        name = sc.charsets[slot]
        if name == "ascii" or name == "utf8":
            return cp
        if cp > 0xFF:
            return 0x20
        table = _CHARSET_TABLES.get(name)
        if table is None:
            return cp
        return table.get(cp, cp)

    def _print_wrap(self):
        """Terminal.printWrap: mark the row when the cursor is in the last column, index, and
        return to the left margin. The row the cursor moves to is a continuation then."""
        sc = self.active
        mark = sc.x == self.cols - 1
        if mark:
            sc.grid[sc.y].wrapped = True
        self._index()
        sc.x = 0
        if mark:
            sc.grid[sc.y].cont = True

    def _print_text(self, text):
        """A PRINT token: a run of code points. ASCII under the ASCII or DEC
        special graphics set takes the slice path, which gives the same cells as
        _print_cp one at a time (every DEC graphics character is one cell wide)."""
        sc = self.active
        if text.isascii() and sc.single is None and not self._insert_on():
            name = sc.charsets[sc.gl]
            if name == "ascii" or name == "utf8":
                self.previous_char = ord(text[-1])
                self._print_ascii(text)
                return
            if name == "dec_special":
                self.previous_char = ord(text[-1])
                self._print_ascii(text.translate(_DEC_TRANSLATE))
                return
        self._print_slow(text)

    def _print_slow(self, text):
        for ch in text:
            self._print_cp(ord(ch))

    def _print_ascii(self, text):
        cols = self.cols
        n = len(text)
        i = 0
        wrap = self._wrap_on()
        while i < n:
            sc = self.active
            if sc.pending:
                if wrap:
                    self._print_wrap()
                    sc = self.active
                else:
                    # no autowrap: the cursor stays on the last column and each
                    # character overwrites it
                    self._put(sc.x, sc.y, text[i], _WIDE_NARROW)
                    i += 1
                    continue
            x = sc.x
            y = sc.y
            k = min(n - i, cols - x)
            row = sc.grid[y]
            ws = row.wide[x:x + k]
            if _WIDE_TAIL in ws or _WIDE_HEAD in ws or _WIDE_SPACER_HEAD in ws:
                for j in range(k):
                    self._put(x + j, y, text[i + j], _WIDE_NARROW)
            else:
                row.text[x:x + k] = text[i:i + k]
                row.sid[x:x + k] = [sc.pen_sid] * k
            i += k
            if x + k == cols:
                sc.x = cols - 1
                sc.pending = True
            else:
                sc.x = x + k

    def _print_cp(self, cp):
        """Terminal.print for one code point, Ghostty's order of decisions."""
        sc = self.active
        cols = self.cols
        wrap = self._wrap_on()
        if cp > 255 and self.grapheme_cluster and sc.x > 0:
            if self._grapheme_block(cp):
                return
        width = 1 if cp <= 255 else self._w.props(cp)[0]
        if width == 0:
            if self.grapheme_cluster or sc.x == 0:
                return
            row = sc.grid[sc.y]
            px = sc.x - 1
            if row.wide[px] == _WIDE_TAIL:
                px -= 1
            if px < 0 or row.text[px] == "":
                return
            base = ord(row.text[px][0])
            if cp == 0xFE0F or cp == 0xFE0E:
                if self._w.props(base)[2] != self._w.GB_INDEX["extended_pictographic"]:
                    return
            row.text[px] += chr(cp)
            return
        self.previous_char = cp
        if sc.pending and wrap:
            self._print_wrap()
        if self._insert_on() and sc.x + width < cols:
            self._insert_blanks(width)
        if width == 1:
            self._put(sc.x, sc.y, chr(self._mapped(cp)), _WIDE_NARROW)
        else:
            if cols > 1:
                if sc.x == cols - 1:
                    if not wrap:
                        return
                    sc.grid[sc.y].wrapped = True
                    self._put_spacer(sc.x, sc.y, _WIDE_SPACER_HEAD)
                    self._print_wrap()
                self._put(sc.x, sc.y, chr(self._mapped(cp)), _WIDE_HEAD)
                sc.x += 1
                self._put_spacer(sc.x, sc.y, _WIDE_TAIL)
            else:
                self._put_spacer(sc.x, sc.y, _WIDE_NARROW)
        if sc.x == cols - 1:
            sc.pending = True
            return
        sc.x += 1

    def _grapheme_block(self, cp):
        """Terminal.print's mode 2027 block. Returns True when the code point is
        used up (attached to the previous cell, or dropped), False when it starts a
        new cell and the normal path runs."""
        sc = self.active
        cols = self.cols
        wrap = self._wrap_on()
        x = sc.x
        y = sc.y
        row = sc.grid[y]
        if wrap:
            left = 0 if sc.pending else 1
        elif x != cols - 1:
            left = 1
        else:
            left = 1 if row.text[x] == "" else 0
        ix = x - left
        if ix < 0:
            return False
        if row.wide[ix] == _WIDE_TAIL:
            px = ix - 1
            pleft = left + 1
        else:
            px = ix
            pleft = left
        if px < 0:
            return False
        ptext = row.text[px]
        if ptext == "":
            return False
        cps = [ord(c) for c in ptext]
        state = 0
        cp1 = cps[0]
        for cp2 in cps[1:]:
            _brk, state = self._w.grapheme_break(cp1, cp2, state)
            cp1 = cp2
        brk, state = self._w.grapheme_break(cp1, cp, state)
        if brk:
            return False
        desired = None
        if cp == 0xFE0F or cp == 0xFE0E:
            # 1.4.0: a variation selector applies to the codepoint before it in the cell (the last
            # one of the cluster); 1.3.1 looked at the cell's first codepoint
            if not self._w.props(cps[-1] if self._v14 else cps[0])[3]:
                return True                      # invalid selector: dropped
            desired = "wide" if cp == 0xFE0F else "narrow"
        elif not self._w.props(cp)[1]:
            desired = "wide"
        ppx, ppy = px, y
        if desired == "wide":
            if row.wide[px] != _WIDE_HEAD:
                sc.x = x - pleft
                if sc.x == cols - 1:
                    if not wrap:
                        return True
                    row.wrapped = True
                    # printCell(prev_cp, .wide) maps the base code point again. With grapheme
                    # data on the base, Ghostty sets the spacer head by hand ("like printCell
                    # but without clearing the grapheme data"), so no mapping runs for it.
                    if len(cps) > 1:
                        row.wide[px] = _WIDE_SPACER_HEAD
                        row.text[px] = ""
                        self._print_wrap()
                        base = chr(self._mapped(cps[0]))
                        self._put(sc.x, sc.y, base, _WIDE_HEAD)
                        ppx, ppy = sc.x, sc.y
                        sc.grid[ppy].text[ppx] = base + ptext[1:]
                    else:
                        self._put_spacer(sc.x, sc.y, _WIDE_SPACER_HEAD)
                        self._print_wrap()
                        self._put(sc.x, sc.y, chr(self._mapped(cps[0])), _WIDE_HEAD)
                        ppx, ppy = sc.x, sc.y
                else:
                    row.wide[sc.x] = _WIDE_HEAD
                    ppx, ppy = sc.x, y
                sc.x += 1
                self._put_spacer(sc.x, sc.y, _WIDE_TAIL)
                if sc.x == cols - 1:
                    sc.pending = True
                else:
                    sc.x += 1
        elif desired == "narrow" and self._v14:
            if row.wide[px] == _WIDE_HEAD:
                # 1.4.0: the tail is the cell right of the base, and the cursor goes to the cell
                # after the now narrow base, clamped to the right edge
                row.wide[px] = _WIDE_NARROW
                if px < cols - 1:
                    row.wide[px + 1] = _WIDE_NARROW
                sc.pending = False
                sc.x = min(px + 1, cols - 1)
        elif desired == "narrow":
            if row.wide[px] == _WIDE_HEAD:
                row.wide[px] = _WIDE_NARROW
                if pleft > 0:
                    # the spacer tail, at cursorCellLeft(prev.left - 1). With prev.left 0 the
                    # head is the cursor cell itself, a head that a column cut left in the last
                    # column with no tail; Ghostty's prev.left - 1 then underflows (a known gap)
                    tail = x - (pleft - 1)
                    row.wide[tail] = _WIDE_NARROW
                if x == cols - 1:
                    sc.pending = False
                else:
                    sc.x = x - 1
        grid_row = sc.grid[ppy]
        grid_row.text[ppx] += chr(cp)
        return True

    # ------------------------------------------------------------ execute ---

    def _execute(self, c):
        if c > 0x7F:
            # a C1 byte outside ground is the ESC form (stream.zig execute)
            self._esc(b"", c - 0x40)
            return
        if c == 0x08:
            self._cursor_left(1)
        elif c == 0x09:
            self._horizontal_tab(1)
        elif c == 0x0A or c == 0x0B or c == 0x0C:
            self._linefeed()
        elif c == 0x0D:
            self._carriage_return()
        elif c == 0x0E:
            self.active.gl = 1
        elif c == 0x0F:
            self.active.gl = 0
        # NUL, SOH, STX, ENQ, BEL and the other C0 bytes do nothing here

    # ------------------------------------------------------------ escapes ---

    def _esc(self, inter, final):
        if inter == b"":
            if final == 0x37:                       # 7
                self._save_cursor()
            elif final == 0x38:                     # 8
                self._restore_cursor()
            elif final == 0x44:                     # D
                self._index()
            elif final == 0x45:                     # E
                self._index()
                self._carriage_return()
            elif final == 0x48:                     # H
                self.tabstops[self.active.x] = True
            elif final == 0x4D:                     # M
                self._reverse_index()
            elif final == 0x63:                     # c
                self._full_reset()
            elif final == 0x4E:                     # N: SS2
                self.active.single = 2
            elif final == 0x4F:                     # O: SS3
                self.active.single = 3
            elif final == 0x6E:                     # n: LS2
                self.active.gl = 2
            elif final == 0x6F:                     # o: LS3
                self.active.gl = 3
            elif final == 0x7E:                     # ~: LS1R
                self.active.gr = 1
            elif final == 0x7D:                     # }: LS2R
                self.active.gr = 2
            elif final == 0x7C:                     # |: LS3R
                self.active.gr = 3
            elif final == 0x5A:                     # Z: DECID, a primary device attributes request
                self._device_attributes("primary")
            return
        if len(inter) == 1 and inter in (b"(", b")", b"*", b"+"):
            slot = b"()*+".index(inter)
            name = {0x42: "ascii", 0x41: "british", 0x30: "dec_special"}.get(final)
            if name is not None:
                self.active.charsets[slot] = name

    def _full_reset(self):
        # Ghostty's fullReset removes the alternate screen and resets the primary, whose
        # Screen.reset gives it an image storage with the default limit: RIS lifts a configured
        # limit (and a limit of 0), as the configured value was only applied to existing screens
        self.primary = Screen(self.cols, self.rows)
        self.alternate = None
        self.active = self.primary
        self.key = "pri"
        self.top = 0
        self.bottom = self.rows - 1
        self.tabstops = _default_tabstops(self.cols)
        self._reset_modes(self._grapheme_default)
        self.previous_char = None
        self.sync = False

    # ------------------------------------------------------------ CSI ---

    def _csi(self, params, inter, final):
        if inter == b"":
            self._csi_plain(params, final)
        elif inter == b"?":
            self._csi_private(params, final)
        elif inter == b">" and final == 0x63:       # > c: secondary device attributes
            self._device_attributes("secondary")
        elif inter == b"=" and final == 0x63:       # = c: tertiary device attributes
            self._device_attributes("tertiary")
        elif inter == b" " and final == 0x71:       # SP q: DECSCUSR
            self._decscusr(params)
        elif inter == b">" and final == 0x6D:       # > m: key format (not shown)
            return
        elif inter == b"$" and final == 0x7D:       # $ }: DECSASD
            return

    def _csi_plain(self, params, final):
        vals, seps = _style.csi_params(params)
        n = len(vals)
        if final == 0x6D:                           # m
            self._sgr(params)
        elif final == 0x48 or final == 0x66:        # H f
            if n == 0:
                self._set_pos(1, 1)
            elif n == 1:
                self._set_pos(vals[0], 1)
            elif n == 2:
                self._set_pos(vals[0], vals[1])
        elif final == 0x41 or final == 0x6B:        # A k
            if n <= 1:
                self._cursor_up(vals[0] if n else 1)
        elif final == 0x42:                         # B
            if n <= 1:
                self._cursor_down(vals[0] if n else 1)
        elif final == 0x43:                         # C
            if n <= 1:
                self._cursor_right(vals[0] if n else 1)
        elif final == 0x44 or final == 0x6A:        # D j
            if n <= 1:
                self._cursor_left(vals[0] if n else 1)
        elif final == 0x45:                         # E
            if n <= 1:
                self._cursor_down(vals[0] if n else 1)
                self._carriage_return()
        elif final == 0x46:                         # F
            if n <= 1:
                self._cursor_up(vals[0] if n else 1)
                self._carriage_return()
        elif final == 0x47 or final == 0x60:        # G `
            if n <= 1:
                self._set_pos(self.active.y + 1, vals[0] if n else 1)
        elif final == 0x64:                         # d
            if n <= 1:
                self._set_pos(vals[0] if n else 1, self.active.x + 1)
        elif final == 0x65:                         # e
            if n <= 1:
                self._set_pos(self.active.y + 1 + (vals[0] if n else 1), self.active.x + 1)
        elif final == 0x61:                         # a
            if n <= 1:
                self._set_pos(self.active.y + 1, self.active.x + 1 + (vals[0] if n else 1))
        elif final == 0x49:                         # I
            if n <= 1:
                self._horizontal_tab(vals[0] if n else 1)
        elif final == 0x5A:                         # Z
            if n <= 1:
                self._horizontal_tab_back(vals[0] if n else 1)
        elif final == 0x4A:                         # J
            if n == 0:
                self._erase_display(0)
            elif n == 1 and vals[0] in (0, 1, 2, 3, 22):
                self._erase_display(vals[0])
        elif final == 0x4B:                         # K
            if n == 0:
                self._erase_line(0)
            elif n == 1 and vals[0] < 3:
                self._erase_line(vals[0])
        elif final == 0x4C:                         # L
            if n <= 1:
                self._insert_lines(vals[0] if n else 1)
        elif final == 0x4D:                         # M
            if n <= 1:
                self._delete_lines(vals[0] if n else 1)
        elif final == 0x50:                         # P
            if n <= 1:
                self._delete_chars(vals[0] if n else 1)
        elif final == 0x53:                         # S
            if n <= 1:
                self._scroll_up_region(vals[0] if n else 1, kind="su")
        elif final == 0x54:                         # T
            if n <= 1:
                self._scroll_down_region(vals[0] if n else 1)
        elif final == 0x58:                         # X
            if n <= 1:
                self._erase_chars(vals[0] if n else 1)
        elif final == 0x40:                         # @
            if n == 0:
                self._insert_blanks(1)
            elif n == 1:
                self._insert_blanks(max(1, vals[0]))
        elif final == 0x62:                         # b
            if n <= 1:
                self._print_repeat(vals[0] if n else 1)
        elif final == 0x67:                         # g
            if n == 1:
                if vals[0] == 0:
                    self.tabstops[self.active.x] = False
                elif vals[0] == 3:
                    self.tabstops = [False] * self.cols
        elif final == 0x57:                         # W
            if n == 0 or (n == 1 and vals[0] == 0):
                self.tabstops[self.active.x] = True
            elif n == 1:
                if vals[0] == 2:
                    self.tabstops[self.active.x] = False
                elif vals[0] == 5:
                    self.tabstops = [False] * self.cols
        elif final == 0x68:                         # h
            self._set_modes(vals, b"", True)
        elif final == 0x6C:                         # l
            self._set_modes(vals, b"", False)
        elif final == 0x72:                         # r
            if n == 0:
                self._set_top_bottom(0, 0)
            elif n == 1:
                self._set_top_bottom(vals[0], 0)
            elif n == 2:
                self._set_top_bottom(vals[0], vals[1])
        elif final == 0x73:                         # s
            if n == 0:
                self._save_cursor()
        elif final == 0x75:                         # u
            self._restore_cursor()
        elif final == 0x6E:                         # n
            self.stats["vt_queries"] += 1
            if n == 1:
                self._device_status(vals[0], False)
        elif final == 0x63:                         # c: primary device attributes
            self._device_attributes("primary")

    def _csi_private(self, params, final):
        vals, _seps = _style.csi_params(params)
        if final == 0x68:                           # ?h
            self._set_modes(vals, b"?", True)
        elif final == 0x6C:                         # ?l
            self._set_modes(vals, b"?", False)
        elif final == 0x72:                         # ?r: restore saved modes
            for v in vals:
                if v in self._saved_dec:
                    self._set_dec(v, self._saved_dec[v])
        elif final == 0x73:                         # ?s: save modes
            for v in vals:
                if v in _DEC_MODES:
                    self._saved_dec[v] = bool(self._dec.get(v, False))
        elif final == 0x4A:                         # ?J selective erase: no protected cells here
            if len(vals) == 0:
                self._erase_display(0)
            elif len(vals) == 1 and vals[0] in (0, 1, 2, 3, 22):
                self._erase_display(vals[0])
        elif final == 0x4B:                         # ?K
            if len(vals) == 0:
                self._erase_line(0)
            elif len(vals) == 1 and vals[0] < 3:
                self._erase_line(vals[0])
        elif final == 0x57 and vals == [5]:         # ?5W: tab stops reset
            self.tabstops = _default_tabstops(self.cols)
        elif final == 0x6E:                         # ?n: the question form of DSR
            self.stats["vt_queries"] += 1
            if len(vals) == 1:
                self._device_status(vals[0], True)

    def _print_repeat(self, count):
        if self.previous_char is None:
            return
        for _ in range(max(count, 1)):
            self._print_cp(self.previous_char)

    def _sgr(self, params):
        sc = self.active
        pen = sc.pen
        for attr in _style.sgr_attributes(params):
            pen = _style.apply_attr(pen, attr)
        sc.pen = pen
        sc.pen_sid = self.styles.intern(pen)

    def _decscusr(self, params):
        vals, _seps = _style.csi_params(params)
        if len(vals) == 0:
            shape = "block"
        elif len(vals) == 1:
            shape = {0: "block", 1: "block", 2: "block", 3: "underline", 4: "underline",
                     5: "bar", 6: "bar"}.get(vals[0])
            if shape is None:
                return
        else:
            return
        self.active.shape = shape

    def _device_attributes(self, kind):
        """A device attributes request (DA1 primary, DA2 secondary, DA3 tertiary). Each one counts
        as a VT query. Ghostty 1.3.1 answers primary and secondary (stream_handler.zig
        deviceAttributes) and logs the tertiary one; tmux answers them itself, so behind tmux the
        model answers none."""
        self.stats["vt_queries"] += 1
        if kind == "primary":
            self._respond_vt(b"\x1b[?62;22;52c")
        elif kind == "secondary":
            self._respond_vt(b"\x1b[>1;10;0c")

    def _device_status(self, request, question):
        """A device status report (stream_handler.zig deviceStatusReport). CSI 5 n answers
        operating OK; CSI 6 n the cursor, relative to the top margin in origin mode (saturating, as
        Ghostty's -|). Ghostty has no question form of 6, and its ?996 (colour scheme) is not
        modelled, so the question forms answer nothing."""
        if question:
            return
        if request == 5:
            self._respond_vt(b"\x1b[0n")
        elif request == 6:
            sc = self.active
            row = max(0, sc.y - self.top) if self._dec.get(6, False) else sc.y
            self._respond_vt(("\x1b[%d;%dR" % (row + 1, sc.x + 1)).encode("ascii"))

    def _respond(self, data):
        self.responses.append(data)
        if self.respond is not None:
            self.respond(data)

    def _respond_vt(self, data):
        """An answer to a VT query. Behind tmux (hop tmux) tmux answers these itself, so the model
        sends none; without tmux the answer is the terminal's own."""
        if self.hop == HOP_TMUX:
            return
        self._respond(data)

    # ------------------------------------------------------ Kitty graphics ---

    def _kitty(self, sc):
        """The image storage of a screen, made on first use with the limit the screen was made
        with (kitty_limit: the configured limit for the primary screen, the primary's limit for
        the alternate one). RIS replaces both screens, so it empties them and restores the default
        limit."""
        if sc.kitty is None:
            sc.kitty = _kgp.ImageStorage(sc.kitty_limit, _kgp.is_140(self.profile))
        return sc.kitty

    def _kitty_delete_all(self):
        """Ghostty's delete .all with images, which ED 2 and ED 22 run on the active screen:
        pins are removed, images nothing uses are freed, virtual placements stay."""
        sc = self.active
        if sc.kitty is not None:
            if sc.kitty.v14:
                sc.kitty.clear_screen(self)
            else:
                sc.kitty.delete_all(True)

    def _graphics_apc(self, tok, channel):
        """An APC whose payload starts with G is a Kitty graphics command (Ghostty apc.zig). A
        command the parser rejects is answered with nothing, logged, and changes no state. Any
        other APC is ignored."""
        payload = tok.payload
        if payload[:1] != b"G":
            return
        try:
            kitty = self.profile == _kgp.KITTY
            frame_load = (kitty or _kgp.is_140(self.profile)) and self.active.kitty is not None \
                and self.active.kitty.loading is not None \
                and self.active.kitty.loading.action == "f"
            cmd = _kgp.parse(payload[1:], kitty, frame_load, _kgp.is_140(self.profile))
        except _kgp.ParseError as exc:
            self.warnings.append("kitty graphics protocol error: %s" % exc)
            return
        answer = _kgp.execute(self, cmd, (channel, tok.start, tok.ordinal))
        if answer is not None:
            self._respond(answer)

    def _set_modes(self, vals, inter, enable):
        ansi = inter == b""
        for v in vals:
            if ansi:
                if v in _ANSI_MODES:
                    self._ansi[v] = enable
            elif v in _DEC_MODES:
                self._set_dec(v, enable)

    def _set_dec(self, v, enable):
        if v == 3 or v == 40:
            return                       # DECCOLM is off: enable_mode_3 is never set
        self._dec[v] = enable
        if v == 2026:
            self.sync = bool(enable)
        if v == 6:
            self._set_pos(1, 1)
        elif v == 47 or v == 1047 or v == 1049:
            self._switch_screen_mode(v, enable)
        elif v == 1048:
            if enable:
                self._save_cursor()
            else:
                self._restore_cursor()

    def _switch_screen_mode(self, mode, enable):
        if mode == 1047 and not enable and self.key == "alt":
            self._erase_display(2)
        if mode == 1049 and enable:
            self._save_cursor()
        old = self._switch_screen("alt" if enable else "pri")
        if mode in (47, 1047) and old is not None:
            self._copy_cursor(old)
        if mode == 1049:
            if enable:
                self._erase_display(2)
                if old is not None:
                    self._copy_cursor(old)
            else:
                self._restore_cursor()

    def _switch_screen(self, key):
        if self.key == key:
            return None
        old = self.active
        if key == "alt" and self.alternate is None:
            # Ghostty's switchScreen makes the alternate screen with the primary's current limit
            self.alternate = Screen(self.cols, self.rows, _storage_limit(self.primary))
        new = self.alternate if key == "alt" else self.primary
        new.charsets = list(old.charsets)
        new.gl = old.gl
        new.gr = old.gr
        new.single = old.single
        self.active = new
        self.key = key
        return old

    def _copy_cursor(self, old):
        sc = self.active
        sc.x = min(old.x, self.cols - 1)
        sc.y = min(old.y, self.rows - 1)
        sc.pen = old.pen
        sc.pen_sid = old.pen_sid
        sc.pending = old.pending
        sc.shape = old.shape

    # ------------------------------------------------------------ resize ---

    def reattach(self):
        """A new outer terminal takes the place of the old one (a tmux client attaches from
        somewhere else, or a terminal window is opened on the same pane). tmux redraws the screen
        for it, so the text, the styles and the cursor stay; the terminal itself starts with empty
        graphics storage on both screens: every image, placement and load in progress the old one
        held is gone (placeholder cells stay on the screen and name images that are not there
        until the program sends them again). The tokenizers keep their state: the bytes of the
        program's stream go on unchanged."""
        for screen in (self.primary, self.alternate):
            if screen is not None:
                screen.kitty = None

    def resize(self, cols, rows):
        """A resize event (Termio.resize, then Terminal.resize). Termio.resize turns synchronized
        output off so that the resize shows at once, on every event, also one that keeps the grid
        (Surface.resize mails the IO thread whenever the pixel size changes), which clears the 2026
        flag. Terminal.resize returns for an unchanged grid; otherwise it resizes both screens
        (_resize_screen). The primary screen reflows when wraparound is on: reflow is not modelled
        (a known gap; nvim redraws), its columns are cut or extended as without reflow."""
        cols = int(cols)
        rows = int(rows)
        self.sync = False
        self._dec[2026] = False
        if cols == self.cols and rows == self.rows:
            return
        if cols != self.cols:
            self.tabstops = _default_tabstops(cols)
        reflow = self._wrap_on()
        for sc in (self.primary, self.alternate):
            if sc is not None:
                primary = sc is self.primary
                pins = _pins_of(sc)
                if cols < self.cols:
                    for pin in pins:
                        if pin.x >= cols:          # PageList.resizeWithoutReflow clamps pin columns
                            pin.x = cols - 1
                pinned = frozenset(pin.abs_y - sc.base for pin in pins
                                   if 0 <= pin.abs_y - sc.base < len(sc.grid))
                _resize_screen(sc, self.cols, cols, rows, primary, primary and reflow, pinned)
                if not primary:
                    _erase_history_pins(sc)       # Screen.resize: no_scrollback erases the history
        self.cols = cols
        self.rows = rows
        self.top = 0
        self.bottom = rows - 1
        for sc in (self.primary, self.alternate):
            if sc is not None:
                # the pending-wrap flag is kept: Ghostty's resize does not reset the active
                # cursor's (Screen.resize resets only a saved cursor's)
                sc.x = min(sc.x, cols - 1)
                sc.y = min(sc.y, rows - 1)

    # ------------------------------------------------------------ snapshot ---

    def snapshot(self, t=None):
        """The grid, styles, cursor and images now. t is the time the animations are shown at:
        None means the clock when one is set, else the arrival time of the last feed that had one,
        else no animation advance. Inside a synchronized update (DECSET 2026) this is the middle of
        an update; Recording defers it."""
        if self.sync:
            self.warnings.append("snapshot taken inside a synchronized update (DECSET 2026)")
        if t is None and self.clock is not None:
            t = self.clock()
        if t is None:
            t = self._now
        sc = self.active
        cells = []
        for row in sc.grid:
            out = []
            append = out.append
            for text, sid, wide in zip(row.text, row.sid, row.wide):
                if wide == _WIDE_TAIL:
                    append(("", sid, 0))
                elif wide == _WIDE_SPACER_HEAD:
                    append((" ", sid, 1))
                elif text == "":
                    append((" ", sid, 1))
                else:
                    append((text, sid, wide))
            cells.append(out)
        cursor = (sc.x, sc.y, bool(self._dec.get(25, False)), sc.shape)
        stats = copy.deepcopy(self.stats)
        graphics = _snapshot.graphics(self, t)
        return Snapshot(cols=self.cols, rows=self.rows, cell_w=self.cell[0], cell_h=self.cell[1],
                        pad=self.pad, cells=cells, styles=list(self.styles.styles), cursor=cursor,
                        warnings=list(self.warnings), stats=stats, responses=list(self.responses),
                        profile=self.profile, t=t, images=graphics.images, draws=graphics.draws,
                        missing=graphics.missing, virtual=graphics.virtual)


def tmux_counts(snap):
    """The tmux hop's counters of a snapshot: discards, timer_drops, dropped_apc, ignored_dcs
    and body_other."""
    return snap.stats["tmux"]


def _row_has_text(row):
    """Ghostty's Page.Cell.hasTextAny: a cell with a codepoint (a blank has none)."""
    return any(text != "" for text in row.text)


def _row_is_empty(row, bg_cells):
    """Ghostty's Cell.isEmpty on every cell of the row. A codepoint cell is empty when it has no
    text and is narrow, whatever its style; a spacer is not empty, and neither is a
    background-only blank (an id in bg_cells, StyleTable.intern_bg)."""
    if any(row.text):
        return False
    for sid, wide in zip(row.sid, row.wide):
        if wide != _WIDE_NARROW or sid in bg_cells:
            return False
    return True


def _shrink_rows(sc, rows, primary, saved_y, pinned=frozenset()):
    """Rows shrink as PageList.resizeWithoutReflow does. Blank rows below the cursor's row go
    first: trimTrailingBlankRows stops at a row with text and at a row with a tracked pin (the
    rows in `pinned`, screen rows of this screen's pins), the cursor's row and the saved cursor's
    row (saved_y, None without one). The rows still above the new active area then leave the top,
    into history on the primary screen, and the base moves on by that many rows (the pins of those
    rows stay with them). A cursor on a row that leaves moves to the top-left, as
    Screen.cursorReload does. Returns how many rows left the top."""
    grid = sc.grid
    needed = len(grid) - rows
    stop = sc.y if saved_y is None else max(sc.y, saved_y)
    trimmed = 0
    y = len(grid) - 1
    while trimmed < needed and y > stop and y not in pinned and not _row_has_text(grid[y]):
        del grid[y]
        trimmed += 1
        y -= 1
    extra = len(grid) - rows
    if extra > 0:
        del grid[:extra]
        sc.base += extra
        if primary:
            sc.scrolled += extra
        if sc.y < extra:
            sc.x = 0
            sc.y = 0
        else:
            sc.y -= extra
        return extra
    return 0


def _resize_saved(saved, cols, left, primary):
    """Screen.resize on the saved cursor, whose pin moves with its row: the row moves up by
    `left` and the column is clamped to a narrower screen. A row that left the primary screen
    holds the pin in history, so the cursor goes to the top-left with no pending wrap. The
    alternate screen erases its history after the resize (no_scrollback), and eraseRows moves a
    pin in an erased row to x 0, y 0 of the page, the top-left of the active area. Then, on the
    pin's point, a pending wrap ends when the cursor is not in the last column, and the cursor
    moves one column on."""
    x, y, pen, pending, origin, charsets, gl, gr, single = saved
    if y < left:
        if primary:
            return (0, 0, pen, False, origin, charsets, gl, gr, single)
        x = 0
        y = 0
    else:
        x = min(x, cols - 1)
        y -= left
    if pending and x != cols - 1:
        pending = False
        x += 1
    return (x, y, pen, pending, origin, charsets, gl, gr, single)


def _resize_cols(sc, old_cols, cols, reflow):
    """The column change of one screen. A shrink clears only the cells it cuts
    (page.clearCells from the new count), so a wide head that stays on the last column keeps its
    character and width. A grow (resizeWithoutReflowGrowCols) widens the page in place when it
    was made at least that wide (sc.cap_cols) and no row has a spacer head in the old last
    column; otherwise every row is copied into a new page at the new width (cloneRowFrom), which
    turns that spacer head into a narrow cell and, being a partial copy, keeps the new row's
    flags: the row loses both soft-wrap flags. The reflow path (resizeCols) always builds new
    pages at the new width; its reflow is not modelled."""
    grid = sc.grid
    if cols < old_cols:
        for row in grid:
            del row.text[cols:]
            del row.sid[cols:]
            del row.wide[cols:]
        if reflow:
            sc.cap_cols = cols
    elif cols > old_cols:
        last = old_cols - 1
        extra = cols - old_cols
        copy_rows = (reflow or sc.cap_cols < cols
                     or any(row.wide[last] == _WIDE_SPACER_HEAD for row in grid))
        for row in grid:
            if copy_rows:
                row.wrapped = False
                row.cont = False
                if row.wide[last] == _WIDE_SPACER_HEAD:
                    row.wide[last] = _WIDE_NARROW
            row.text.extend([""] * extra)
            row.sid.extend([0] * extra)
            row.wide.extend([_WIDE_NARROW] * extra)
        if copy_rows:
            sc.cap_cols = cols


def _resize_screen(sc, old_cols, cols, rows, primary, reflow, pinned=frozenset()):
    """One screen of Terminal.resize. Without reflow (the alternate screen, and the primary with
    wraparound off) PageList.resizeWithoutReflow changes the columns first ("we have to do cols
    first"), so a row whose only text lies in the cut columns is blank when the rows shrink. On
    the reflow path PageList.resize changes the rows first for a column shrink (with the old
    width) and the columns first for a grow. Rows shrink as _shrink_rows says and grow with
    default rows (PageList.grow). The saved cursor follows its row (_resize_saved)."""
    grid = sc.grid
    cols_first = not reflow or cols > old_cols
    if cols_first:
        _resize_cols(sc, old_cols, cols, reflow)
    width = cols if cols_first else old_cols
    left = 0
    if rows < len(grid):
        saved_y = sc.saved[1] if sc.saved is not None else None
        left = _shrink_rows(sc, rows, primary, saved_y, pinned)
    while len(grid) < rows:
        grid.append(Row(width))
    if not cols_first:
        _resize_cols(sc, old_cols, cols, reflow)
    if sc.saved is not None:
        sc.saved = _resize_saved(sc.saved, cols, left, primary)

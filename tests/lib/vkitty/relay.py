#!/usr/bin/env python3
"""The live recorder: a pty relay between a child program and the terminal it runs in.

    relay.py --rec DIR [--size CxR] [--cell 13x33] [--pad 4]
             [--profile ghostty-1.4.0|ghostty-1.3.1|kitty]
             [--hop auto|tmux|tmux-off|none] [--respond ghostty|none] [--gfx-fifo PATH] [--ctl PATH]
             [--no-forward] [--media-unlink yes|no] -- CMD ARGS...

The child runs on a new pty. Every byte the child writes is recorded in tui.bin (and forwarded
to this process's stdout unless --no-forward). Input from this process's stdin (in tty mode) goes
to the child. A FIFO given by --gfx-fifo is a second byte channel (the backend's graphics, when
its tty is that FIFO); it is recorded in gfx.bin and never forwarded.

Media: the tap reads every file or shared memory object the terminal would read, once, and
removes it as the terminal does (--media-unlink yes, the default). --media-unlink no leaves the
files for a real terminal downstream.

Live terminal: with --respond ghostty the child is answered by a live terminal (the answers are
those of vt.Terminal in the recorded profile). It runs in a worker process of its own (live.py),
which the relay feeds with one line per event: the bytes themselves stay in the recording's
files, and the media the tap read are named by their file. The answers come back asynchronously,
when the worker has handled the bytes that asked for them, as a real terminal's do, and they are
recorded and delivered to the child while it runs. A mark, and the end of the run, wait until the
worker has handled everything before them, so every answer before a mark is recorded before the
mark. An answer that arrives after the child exited is recorded and not delivered. A failure of the
worker is an error event (where "live") and the relay goes on without it, as does a worker that
does not answer a mark or the end within LIVE_WAIT seconds. The worker's pid is in the start event
as live_pid.

Control: --ctl PATH is a FIFO with lines, each acknowledged or applied in order:
    mark NAME     drain what the child and the graphics FIFO have written, wait until the live
                  terminal (when there is one) has handled all of it, record a mark, then write
                  NAME to PATH.ack (atomically). A waiter removes PATH.ack before it sends a mark:
                  an ack left by an earlier mark of the same name would look like this one.
    resize C R    drain, record the resize, then resize the pty and send SIGWINCH to the child
    reattach      drain, record a reattach: a new outer terminal (a tmux client attached from
                  somewhere else) replaces the old one. The screen text stays, as tmux redraws
                  it for the new client, and the terminal's graphics storage is empty: every
                  image and placement the old terminal held is gone, and a program has to send
                  the images again. Nothing is sent to the child
    quit          SIGTERM to the child
PATH.ack is removed when the relay starts (a stale one from an earlier run) and when it exits.

Input for the child (the answers of the live terminal, and typed input in tty mode) is written
when the child's terminal takes it. What it does not take at once waits in a queue, and the loop
goes on reading the child's output meanwhile; a queue that makes no progress for DRAIN_WRITE
seconds is recorded as an error and dropped.

Tty mode: when stdin is a terminal, it is put in raw mode for the run and restored at exit, and
SIGWINCH is handled by recording the new size before the child sees it.

Exit status: the child's, or 128 + the signal that killed it. The recording gets its end event
and the done file. The FIFOs and the ack are removed; the child is always reaped (on an error the
child is stopped by its pid first).

Hops (the tmux 3.5a passthrough rules, see vt.HOP_TMUX): --hop tmux means the child's bytes come
through tmux, so a DCS tmux; wrapped APC is unwrapped and a raw APC is dropped; --hop none means
a bare terminal; --hop tmux-off is tmux with allow-passthrough off (the tmux default): every
passthrough DCS and every raw APC is dropped, so no graphics command ever reaches the terminal
and a=q is never answered. auto is none when TMUX is not set in this process's environment, and
when it is set, tmux or tmux-off by the pane's allow-passthrough ("tmux show-options -Apv
allow-passthrough": on and all mean tmux, off means tmux-off; an unreadable value means tmux)

Under hop tmux the relay answers no VT query (DA, DSR): a real tmux answers those itself, and
the relay passes tmux's answers from its stdin to the child. A headless relay under hop tmux
has nobody to answer them, so a recording that needs those answers runs inside a tmux pane.

Known gaps: a chunked load that is open while the screen switches (Ghostty keeps one slot per
screen) is not tracked per screen. The tap does not mirror two checks kgp makes before it loads.
(1) A kitty a=f that names an image which does not exist is answered ENOENT by kgp, which reads
nothing and leaves its loading state alone; the tap still sets its loading flag when that a=f is
chunked (m=1). From then on the tap takes every a=t and a=T for a continuation and reads none of
their files, while kgp loads them: the replay warns `no blob for key` for each such command, and
the live terminal answers EINVAL where kitty loads the image. Only a chunked a=f (m=1) that names
a missing image does this; an a=f that is not chunked, or that names an existing image, does not.
(2) A screen whose graphics storage is disabled still gets its files read (and removed) by the
tap, where kgp leaves them in place. In all of these the replay has a blob nothing asks for, or
warns about a missing one. A child that read the old size just before a resize can still write
one line of old-size output after the resize event: the window is the time between its read and
the relay's ioctl, a few microseconds.
"""
import argparse
import base64
import errno
import fcntl
import os
import pty
import re
import select
import signal
import struct
import sys
import termios
import time
import tty

sys.dont_write_bytecode = True   # a run of the harness writes no bytecode into the repository tree

_LIB = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _LIB not in sys.path:
    sys.path.insert(0, _LIB)

from vkitty import kgp, media, tokens, vt  # noqa: E402
from vkitty.live import LiveClient  # noqa: E402
from vkitty.recording import RecordingWriter  # noqa: E402

_TMUX_HOPS = (vt.HOP_TMUX, vt.HOP_TMUX_OFF)
CHUNK = 65536          # the most bytes one read takes from the child's terminal
POLL_SECONDS = 0.05    # how often the loop checks for the child's exit and for signals
KILL_AFTER = 5.0       # seconds between a signal to the child and SIGKILL
DRAIN_WRITE = 5.0      # seconds the input queued for the child may go without progress
# queued input beyond this stops the reading of stdin (tty mode) until it drains
OUT_LIMIT = 1 << 20
LIVE_WAIT = 30.0       # seconds a mark or the end waits for the live terminal before it is dropped


class UsageError(Exception):
    pass


def _tmux_passthrough_allowed():
    """Whether the tmux server this process runs under passes DCS tmux; through: the pane's
    allow-passthrough ("tmux show-options -Apv allow-passthrough" prints on, all or off; the program
    is $VKITTY_TMUX when set, so a test can put a stub there). Off means
    no. An older tmux (no such option), a tmux that cannot be run or an answer that is none of the
    three mean yes, the assumption of a tmux whose setting is not known."""
    import subprocess
    try:
        proc = subprocess.run([os.environ.get("VKITTY_TMUX", "tmux"), "show-options", "-Apv",
                               "allow-passthrough"],
                              capture_output=True, text=True, timeout=10, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError):
        return True
    return not (proc.returncode == 0 and proc.stdout.strip() == "off")


def parse_size(text):
    match = re.match(r"^(\d+)x(\d+)$", text)
    if match is None:
        raise UsageError("a size is CxR, not %r" % (text,))
    cols, rows = int(match.group(1)), int(match.group(2))
    if cols < 1 or rows < 1:
        raise UsageError("a size needs at least 1 column and 1 row")
    return cols, rows


def parse_args(argv):
    """The options before -- and the child command after it."""
    argv = list(argv)
    if "--" not in argv:
        raise UsageError("the child command must follow --")
    cut = argv.index("--")
    options, command = argv[:cut], argv[cut + 1:]
    if not command:
        raise UsageError("no child command after --")
    parser = argparse.ArgumentParser(prog="relay.py", description="record a child on a pty")
    parser.add_argument("--rec", required=True, help="the recording folder (made if absent)")
    parser.add_argument("--size", default=None, help="CxR when stdin is not a terminal")
    parser.add_argument("--cell", default="13x33", help="cell size in device pixels, WxH")
    parser.add_argument("--pad", type=int, default=4)
    parser.add_argument("--profile", default=kgp.DEFAULT_PROFILE, choices=kgp.PROFILES)
    parser.add_argument("--hop", default="auto", choices=("auto", "tmux", "tmux-off", "none"))
    parser.add_argument("--respond", default="none", choices=("ghostty", "none"))
    parser.add_argument("--gfx-fifo", default=None)
    parser.add_argument("--ctl", default=None)
    parser.add_argument("--no-forward", action="store_true")
    parser.add_argument("--media-unlink", default="yes", choices=("yes", "no"))
    ns = parser.parse_args(options)
    ns.cols, ns.rows = parse_size(ns.size or "80x24")
    ns.cell_w, ns.cell_h = parse_size(ns.cell)
    ns.command = command
    return ns


def _tty_size(fd):
    rows, cols, _x, _y = struct.unpack("HHHH", fcntl.ioctl(fd, termios.TIOCGWINSZ, b"\0" * 8))
    return cols, rows


def _winsize_bytes(cols, rows, cell, pad):
    """struct winsize for a screen of cols x rows cells: the pixel size is the screen's, as Ghostty
    reports it (cells times the cell size, plus the padding on both sides)."""
    xpx = min(cols * cell[0] + 2 * pad, 65535)
    ypx = min(rows * cell[1] + 2 * pad, 65535)
    return struct.pack("HHHH", rows, cols, xpx, ypx)


def _exit_status(status):
    code = os.waitstatus_to_exitcode(status)
    return 128 - code if code < 0 else code


def _make_fifo(path):
    """A FIFO the relay reads. It holds a writer of its own, so that the readers never see end of
    file when the writers of the test or of the backend close their ends."""
    os.mkfifo(path, 0o600)
    reader = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    writer = os.open(path, os.O_WRONLY)
    return reader, writer


def _write_text_atomic(path, text):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="ascii") as fh:
        fh.write(text)
    os.replace(tmp, path)


def _write_fd(fd, data):
    view = memoryview(data)
    while view:
        try:
            view = view[os.write(fd, view):]
        except BlockingIOError:
            select.select([], [fd], [], POLL_SECONDS)


def _remove_acks(ctl):
    """Remove the ack of a control FIFO and the temporary name it is written under."""
    for path in (ctl + ".ack", ctl + ".ack.tmp"):
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass


# The tap's ground-state skip (Tap.feed). From the ground state, a run of bytes other than ESC
# (text, C0 controls and C1 bytes, which are text there), and each complete escape sequence (a CSI,
# or an escape sequence that opens no string) comes back to the ground state and starts no APC: an
# ESC opens a string only as ESC P, ESC ], ESC X, ESC ^ or ESC _, and the units below leave those
# out. So such a prefix of a chunk need not be fed to the tokenizer, and _GROUND_UNITS matches the
# longest such prefix. A unit that the end of the chunk cuts off is not matched, so it is fed and
# the tokenizer's state stays exact. A raw C1 byte after an unfinished sequence is not a unit: in
# the CSI states it starts a string, so the continuation of such a sequence is matched by
# _REST_BY_STATE only when it holds no C1 byte, and otherwise the whole chunk is fed.
_GROUND_UNITS = re.compile(
    rb"[^\x1b]*(?:\x1b(?:\[[\x20-\x3f]*[\x40-\x7e]|[\x20-\x2f]+[\x30-\x7e]"
    rb"|[\x30-\x4f\x51-\x57\x59\x5a\x5c\x60-\x7e])[^\x1b]*)*")
# The rest of an open sequence, by the state the tokenizer is in (the match ends it).
_REST_OF_CSI = re.compile(rb"[\x20-\x3f]*[\x40-\x7e]")
_REST_OF_ESC_INTERMEDIATE = re.compile(rb"[\x20-\x2f]*[\x30-\x7e]")
_REST_OF_ESC = re.compile(
    rb"\[[\x20-\x3f]*[\x40-\x7e]|[\x20-\x2f]+[\x30-\x7e]|[\x30-\x4f\x51-\x57\x59\x5a\x5c\x60-\x7e]")
_REST_BY_STATE = {
    tokens.CSI_ENTRY: _REST_OF_CSI, tokens.CSI_PARAM: _REST_OF_CSI,
    tokens.CSI_INTERMEDIATE: _REST_OF_CSI, tokens.CSI_IGNORE: _REST_OF_CSI,
    tokens.ESCAPE_INTERMEDIATE: _REST_OF_ESC_INTERMEDIATE, tokens.ESCAPE: _REST_OF_ESC,
}


class Tap:
    """Reads every file and shared memory object the terminal would read, once, and records what
    it read. It runs a tokenizer per channel on the bytes as they arrive and mirrors
    which commands reach the media layer in kgp.execute: an APC that is not a Kitty graphics
    command, that the parser rejects, or that a raw APC under the tmux hop never delivers, loads
    nothing. A chunked direct load (m=1) makes the next a=t or a=T a continuation, which loads
    nothing; a query (a=q) always loads when it names an image. kitty's a=f loads its file unless
    it continues a frame load; a=d clears a chunked load in kitty only."""

    def __init__(self, writer, direct, hop, profile, on_blob=None):
        self.writer = writer
        self.direct = direct
        self.hop = hop
        self.profile = profile
        # called as on_blob(key, file name or None, error text or None) after each blob is recorded;
        # the recording keeps the bytes, so the tap keeps none
        self.on_blob = on_blob
        self.loading = None    # None, "t" (a chunked transmission) or "f" (a chunked frame, kitty)
        self._tokenizers = {}
        self._offsets = {}
        self._t = None

    def feed(self, channel, data, t):
        """Feed a chunk. The tokenizer's state is kept exact: an open sequence at the start of the
        chunk is closed by the bytes that close it, then the ground-state prefix is skipped (see
        _GROUND_UNITS), and whatever is left is fed. The offsets count every byte, skipped or
        not."""
        tk = self._tokenizers.get(channel)
        if tk is None:
            tk = tokens.Tokenizer(self._sink(channel), strings_only=True,
                                  tmux_passthrough=(self.hop in _TMUX_HOPS),
                                  v14=kgp.is_140(self.profile))
            self._tokenizers[channel] = tk
        off = self._offsets.get(channel, 0)
        self._offsets[channel] = off + len(data)
        self._t = t
        pos = 0
        rest = _REST_BY_STATE.get(tk.state)
        if rest is not None:
            m = rest.match(data)
            if m is None:
                tk.feed(data, off, t)     # the open sequence is not closed in this chunk
                return
            pos = m.end()
            tk.feed(data[:pos], off, t)   # now in the ground state
        if tk.state == tokens.GROUND:
            pos = _GROUND_UNITS.match(data, pos).end()
        if pos < len(data):
            tk.feed(data[pos:], off + pos, t)

    def _sink(self, channel):
        def sink(tok):
            self._apc(tok, channel)
        return sink

    def _apc(self, tok, channel):
        if self.hop in _TMUX_HOPS and not tok.via_tmux:
            return
        if self.hop == vt.HOP_TMUX_OFF:
            return    # allow-passthrough off: tmux drops the DCS, nothing is loaded
        payload = tok.payload
        if payload[:1] != b"G":
            return
        kitty = self.profile == "kitty"
        animated = kitty or kgp.is_140(self.profile)
        try:
            cmd = kgp.parse(payload[1:], kitty, animated and self.loading == "f",
                            kgp.is_140(self.profile))
            transmission = self._loads(cmd)
        except kgp.ParseError:
            return
        if transmission is None:
            return
        key = (channel, tok.start, tok.ordinal)
        try:
            data = self.direct.load(transmission.medium, cmd.data, transmission.offset,
                                    transmission.size, transmission.format, transmission.width,
                                    transmission.height, key)
            entry = (data, None)
        except media.MediaError as exc:
            entry = (None, exc.message)
        name = self.writer.blob(key, entry[0], entry[1], transmission.medium, self._t)
        if self.on_blob is not None:
            self.on_blob(key, name, entry[1])

    def _loads(self, cmd):
        """The Transmission of a command that reaches the media layer (kgp.execute), or None when it
        loads nothing; the loading slot is updated as kgp does it. Mirrors _query, _transmit,
        _load_and_add, frame_command and the delete of kitty; the storage's enabled check and an
        a=f naming a missing image are not mirrored (see the module's known gaps)."""
        v14 = kgp.is_140(self.profile)
        kitty = self.profile == "kitty" or v14      # the profiles with the animation layer
        action = cmd.action
        ids = cmd.kv.get("i", 0) > 0 and cmd.kv.get("I", 0) > 0
        if v14 and ids:
            return None       # 1.4.0 refuses an i and I together before any action runs
        if action == "q":
            t = cmd.transmission
            if v14 and t.format_unknown:
                return None
            return t if t.image_id != 0 and t.medium != "d" else None
        if action in ("t", "T"):
            t = cmd.transmission
            if kitty and action == "t" and self.loading == "f":
                return self._frame_chunk(cmd)
            if t.image_id > 0 and t.image_number > 0:
                return None
            if v14 and self.loading is not None and t.medium != "d":
                self.loading = None     # a command with another medium abandons the load
            if self.loading is not None:
                return self._chunk_end(t)
            if v14 and t.format_unknown:
                return None
            if t.medium == "d":
                if t.more:
                    self.loading = "t"
                return None
            return t
        if action == "f" and kitty:
            return self._frame_chunk(cmd)
        if action == "d" and kitty:
            self.loading = None
        return None

    def _frame_chunk(self, cmd):
        """A chunk that reaches anim.frame_command: while a load is in progress, one with no t or
        t=d continues it (only its m counts); any other is a first chunk, which drops the load in
        progress, is checked for its keys and loads its medium."""
        kv = cmd.kv
        if self.loading == "f" and kv.get("t", kgp.FRAME_DIRECT) == kgp.FRAME_DIRECT:
            if kv.get("m", 0) <= 0:
                self.loading = None
            return None
        self.loading = None
        kgp.frame_default_format(kv)
        if kgp.frame_key_error(kv) is not None:
            return None
        t = kgp._transmission(kv)
        if t.medium == "d":
            if t.more:
                self.loading = "f"
            return None
        return t

    def _chunk_end(self, t):
        """A continuation chunk: it loads nothing, and the last one (m not set) closes the load."""
        if not t.more:
            self.loading = None
        return None


class Relay:
    """One run: the pty, the FIFOs, the recording, the tap and the live terminal."""

    def __init__(self, opts):
        self.opts = opts
        self.writer = None
        self.direct = None
        self.tap = None
        self.live = None
        self.master = None
        self.pid = None
        self.hop = None
        self.cols = opts.cols
        self.rows = opts.rows
        self.cell = (opts.cell_w, opts.cell_h)
        self.pad = opts.pad
        self.child_exited = False
        self.status = None
        self.master_closed = False
        self.stdin_closed = False
        self.tty_mode = False
        self.tty_saved = None
        self.pending_signals = []
        self.kill_deadline = None
        self.winch = False
        self.gfx_fd = None
        self.gfx_writer = None
        self.ctl_fd = None
        self.ctl_writer = None
        self.ctl_buf = b""
        self.fifos = []
        self.in_queue = bytearray()   # input for the child that its terminal has not taken yet
        self.in_pos = 0               # the bytes of in_queue already written
        self.in_since = None          # when the queue last made progress (None when it is empty)

    # ------------------------------------------------------------- setup ---

    def start(self):
        opts = self.opts
        if os.isatty(0):
            self.tty_mode = True
            self.cols, self.rows = _tty_size(0)
        if opts.hop == "auto":
            if "TMUX" not in os.environ:
                self.hop = vt.HOP_NONE
            else:
                self.hop = vt.HOP_TMUX if _tmux_passthrough_allowed() else vt.HOP_TMUX_OFF
        else:
            self.hop = opts.hop
        for path in (opts.ctl, opts.gfx_fifo):
            if path is not None and os.path.lexists(path):
                raise UsageError("%s already exists" % path)
        if opts.ctl is not None:
            # an ack from an earlier run must not look like one of this run
            _remove_acks(opts.ctl)
        direct = media.DirectMedia(unlink=(opts.media_unlink == "yes"))
        meta = {"cols": self.cols, "rows": self.rows, "cell": [self.cell[0], self.cell[1]],
                "pad": self.pad, "profile": opts.profile, "hop": self.hop,
                "tmpdir": direct._temp_dir(), "t": 0.0}
        if opts.respond == "ghostty":
            self.live = LiveClient(os.path.abspath(opts.rec), self.cols, self.rows, self.cell,
                                   self.pad, opts.profile, self.hop)
            meta["live_pid"] = self.live.pid
        self.writer = RecordingWriter(opts.rec, meta, gfx=opts.gfx_fifo is not None)
        self.direct = direct
        self.tap = Tap(self.writer, direct, self.hop, opts.profile,
                       on_blob=self._live_blob if self.live is not None else None)
        if opts.ctl is not None:
            self.ctl_fd, self.ctl_writer = _make_fifo(opts.ctl)
            self.fifos.append(opts.ctl)
        if opts.gfx_fifo is not None:
            self.gfx_fd, self.gfx_writer = _make_fifo(opts.gfx_fifo)
            self.fifos.append(opts.gfx_fifo)
        for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
            signal.signal(sig, self._on_signal)
        signal.signal(signal.SIGWINCH, self._on_winch)
        self._fork()
        if self.tty_mode:
            self.tty_saved = termios.tcgetattr(0)
            tty.setraw(0)

    def _fork(self):
        command = self.opts.command
        winsize = _winsize_bytes(self.cols, self.rows, self.cell, self.pad)
        pid, master = pty.fork()
        if pid == 0:
            try:
                signal.signal(signal.SIGPIPE, signal.SIG_DFL)
                fcntl.ioctl(0, termios.TIOCSWINSZ, winsize)
                os.execvpe(command[0], command, os.environ)
            except BaseException as exc:
                os.write(2, ("relay: cannot run %s: %s\n" % (command[0], exc)).encode("utf-8",
                                                                                      "replace"))
                os._exit(127)
        self.pid = pid
        self.master = master
        os.set_blocking(master, False)

    # ------------------------------------------------------------ signals ---

    def _on_signal(self, signum, _frame):
        self.pending_signals.append(signum)

    def _on_winch(self, _signum, _frame):
        self.winch = True

    def _signal_child(self, signum):
        if self.child_exited or self.pid is None:
            return
        try:
            os.kill(self.pid, signum)
        except ProcessLookupError:
            pass

    def _deliver_signals(self):
        while self.pending_signals:
            signum = self.pending_signals.pop(0)
            if self.kill_deadline is None:
                self.kill_deadline = time.monotonic() + KILL_AFTER
            self._signal_child(signum)

    def _check_kill(self):
        if self.kill_deadline is not None and not self.child_exited \
                and time.monotonic() > self.kill_deadline:
            self._signal_child(signal.SIGKILL)
            self.kill_deadline = float("inf")

    # -------------------------------------------------------------- loop ---

    def loop(self):
        while not self.child_exited:
            self._deliver_signals()
            self._check_kill()
            if self.winch:
                self.winch = False
                if self.tty_mode:
                    cols, rows = _tty_size(0)
                    if (cols, rows) != (self.cols, self.rows):
                        self._resize(cols, rows)
            fds = []
            wfds = []
            if not self.master_closed:
                fds.append(self.master)
                if self._pending():
                    wfds.append(self.master)
            if self.tty_mode and not self.stdin_closed and self._pending() < OUT_LIMIT:
                fds.append(0)
            if self.gfx_fd is not None:
                fds.append(self.gfx_fd)
            if self.ctl_fd is not None:
                fds.append(self.ctl_fd)
            if self.live is not None and not self.live.eof:
                fds.append(self.live.in_fd)
                if self.live.pending():
                    wfds.append(self.live.out_fd)
            if fds or wfds:
                ready, writable = select.select(fds, wfds, [], POLL_SECONDS)[0:2]
            else:
                time.sleep(POLL_SECONDS)
                ready, writable = [], []
            for fd in writable:
                if fd == self.master:
                    self._flush_input()
                elif self.live is not None and fd == self.live.out_fd:
                    self.live.flush()
            for fd in ready:
                if fd == self.master:
                    self._read_master()
                elif fd == 0:
                    self._read_stdin()
                elif fd == self.gfx_fd:
                    self._read_gfx()
                elif fd == self.ctl_fd:
                    self._read_ctl()
                elif self.live is not None and fd == self.live.in_fd:
                    self._live_read()
            self._check_stall()
            self._reap()
        self._final_drain()

    def _reap(self):
        if self.child_exited:
            return
        pid, status = os.waitpid(self.pid, os.WNOHANG)
        if pid == self.pid:
            self.child_exited = True
            self.status = _exit_status(status)

    def _read_master(self):
        """Read what the child wrote (one read: what the terminal holds, at most a chunk) and
        process it. Returns the number of bytes read. The loop calls this again whenever the
        terminal is readable, so a second read here would only cost a syscall that finds nothing."""
        if self.master_closed:
            return 0
        try:
            data = os.read(self.master, CHUNK)
        except BlockingIOError:
            return 0
        except OSError:
            self.master_closed = True      # EIO: no process holds the child's terminal any more
            return 0
        if not data:
            self.master_closed = True
            return 0
        t = self.writer.now()
        off = self.writer.data("tui", data, t)
        self._feed("tui", data, t, off)
        if not self.opts.no_forward:
            try:
                _write_fd(1, data)
            except OSError:
                pass
        return len(data)

    def _read_gfx(self):
        try:
            data = os.read(self.gfx_fd, CHUNK)
        except BlockingIOError:
            return 0
        if not data:
            return 0
        t = self.writer.now()
        off = self.writer.data("gfx", data, t)
        self._feed("gfx", data, t, off)
        return len(data)

    def _read_stdin(self):
        try:
            data = os.read(0, 1024)
        except OSError:
            data = b""
        if not data:
            self.stdin_closed = True
            return
        try:
            self._queue_input(data)
        except OSError:
            pass

    def _read_ctl(self):
        try:
            data = os.read(self.ctl_fd, 4096)
        except BlockingIOError:
            return
        if not data:
            return
        self.ctl_buf += data
        while b"\n" in self.ctl_buf:
            line, self.ctl_buf = self.ctl_buf.split(b"\n", 1)
            self._command(line.decode("ascii", "replace").strip())

    def _command(self, line):
        parts = line.split()
        if not parts:
            return
        if parts[0] == "mark" and len(parts) == 2:
            self._mark(parts[1])
        elif parts[0] == "resize" and len(parts) == 3 and parts[1].isdigit() \
                and parts[2].isdigit() and int(parts[1]) >= 1 and int(parts[2]) >= 1:
            self._resize(int(parts[1]), int(parts[2]))
        elif parts == ["reattach"]:
            self._reattach()
        elif parts == ["quit"]:
            self._signal_child(signal.SIGTERM)
        else:
            self._error("relay", "unknown control line %r" % (line,), self.writer.now())

    def _mark(self, name):
        # The drain makes the mark follow every byte the child wrote before the mark was read. The
        # loop reads the child's terminal before the control FIFO, and one read takes what a pty
        # holds (at most 1024 unread bytes here), so under that order the drain changes nothing; it
        # stays as the guarantee that does not depend on the order of the descriptors.
        self._drain()
        if self.live is not None:
            # the live terminal handles everything before the mark first, so every answer to it
            # is recorded before the mark (the worker resets its since_prev_mark at the same line)
            seq = self.live.mark()
            self._live_wait(lambda: self.live.marked >= seq)
        t = self.writer.now()
        self.writer.event({"e": "mark", "name": name, "t": t})
        _write_text_atomic(self.opts.ctl + ".ack", name)

    def _resize(self, cols, rows):
        """Everything the child wrote for the old size is recorded first; then the resize is
        recorded; then the pty and the child learn the new size."""
        self._drain()
        t = self.writer.now()
        self.writer.event({"e": "resize", "cols": cols, "rows": rows, "t": t})
        self.cols, self.rows = cols, rows
        if self.live is not None:
            self.live.resize(cols, rows)
        try:
            fcntl.ioctl(self.master, termios.TIOCSWINSZ,
                        _winsize_bytes(cols, rows, self.cell, self.pad))
        except OSError:
            pass
        self._signal_child(signal.SIGWINCH)

    def _reattach(self):
        """Everything the child wrote before is recorded first; then the reattach is recorded, and
        the tap and the live terminal start over with an empty graphics storage."""
        self._drain()
        t = self.writer.now()
        self.writer.event({"e": "reattach", "t": t})
        self.tap.loading = None
        if self.live is not None:
            self.live.reattach()

    def _drain(self):
        """Process what the child and the graphics FIFO have already written; no waiting."""
        while not self.master_closed:
            if not select.select([self.master], [], [], 0)[0]:
                break
            if self._read_master() == 0:
                break
        while self.gfx_fd is not None:
            if not select.select([self.gfx_fd], [], [], 0)[0]:
                break
            if self._read_gfx() == 0:
                break

    def _final_drain(self):
        """After the child exited: what it wrote last, until its terminal is closed or quiet."""
        while not self.master_closed:
            if not select.select([self.master], [], [], 0.2)[0]:
                break
            if self._read_master() == 0:
                break
        self._drain()

    # ------------------------------------------------------ channels ---

    def _feed(self, channel, data, t, off):
        """The tap, then the live terminal, see the same bytes in the same order: the tap's blob
        lines go to the live terminal before the chunk's data line, so the media an APC names is
        known when the APC is fed. off is the offset of the chunk in the channel's file. A tap that
        fails is recorded as an error and disabled; the relay keeps relaying."""
        if self.tap is not None:
            try:
                self.tap.feed(channel, data, t)
            except Exception as exc:
                self._fail("tap", exc, t)
                self.tap = None
        if self.live is not None:
            self.live.data(channel, off, len(data), t)

    def _respond(self, data):
        """An answer of the live terminal: recorded at once. It is delivered to the child only while
        the child runs, since no process reads it after the child exited; after the exit it is
        recorded and that is all (not an error)."""
        self._reap()
        self.writer.event({"e": "resp", "b64": base64.b64encode(data).decode("ascii"),
                           "t": self.writer.now()})
        if not self.child_exited and not self.master_closed:
            try:
                self._queue_input(data)
            except OSError as exc:
                self._error("relay", "answer not delivered: %s" % exc, self.writer.now())

    # --------------------------------------------------- live terminal ---

    def _live_blob(self, key, name, err):
        """A blob the tap recorded (the live terminal reads its file, if it has one)."""
        if self.live is not None:
            self.live.blob(key, name, err)

    def _live_read(self):
        """What the live terminal has written: an answer is recorded and delivered; an error line is
        an error event and drops the live terminal; its output ending before its report is an error
        too (the worker died)."""
        if self.live is None:
            return
        for frame in self.live.read():
            kind = frame.get("r")
            if kind == "resp":
                self._respond(base64.b64decode(frame["b64"]))
            elif kind == "error":
                t = frame.get("t")
                when = t if t is not None else self.writer.now()
                self._error("live", str(frame.get("msg")), when)
                self._live_drop()
                return
        if self.live is not None and self.live.eof and not self.live.done:
            self._live_lost("the live terminal ended before its report")

    def _live_drop(self):
        """Stop the live terminal (by its pid) and forget it: no more lines, and no live_final.json.
        Returns its exit status."""
        live, self.live = self.live, None
        return live.stop()

    def _live_lost(self, reason):
        status = self._live_drop()
        self._error("live", "%s (exit status %s)" % (reason, status), self.writer.now())

    def _live_wait(self, done):
        """Serve the live terminal until done() holds or it is lost (LIVE_WAIT seconds at most). Its
        output is read and its input written; while the child runs, its queued input is written
        and the stall and signal checks run as in the loop. The child's output and the control FIFO
        are not read meanwhile: the child may block on its output for that long, and nothing is
        recorded until the wait ends."""
        deadline = time.monotonic() + LIVE_WAIT
        while self.live is not None and not done():
            if time.monotonic() > deadline:
                self._live_lost("no answer from the live terminal within %d s" % LIVE_WAIT)
                return
            fds = []
            wfds = []
            if not self.live.eof:
                fds.append(self.live.in_fd)
            if self.live.pending():
                wfds.append(self.live.out_fd)
            if not self.child_exited and not self.master_closed and self._pending():
                wfds.append(self.master)
            ready, writable = select.select(fds, wfds, [], POLL_SECONDS)[0:2]
            for fd in writable:
                if fd == self.master:
                    self._flush_input()
                elif self.live is not None and fd == self.live.out_fd:
                    self.live.flush()
            if self.live is not None and self.live.in_fd in ready:
                self._live_read()
            self._reap()
            if not self.child_exited and not self.master_closed:
                self._flush_input()
                self._check_stall()
            self._deliver_signals()
            self._check_kill()

    def _pending(self):
        """The input for the child that is queued and not written yet, in bytes."""
        return len(self.in_queue) - self.in_pos

    def _queue_input(self, data):
        """Input for the child: written now as far as its terminal takes it, the rest queued
        (the loop writes it when the terminal is writable again)."""
        if self.master_closed:
            raise OSError(errno.EIO, "the child has closed its terminal")
        if self.in_since is None:
            self.in_since = time.monotonic()
        self.in_queue += data
        self._flush_input()

    def _flush_input(self):
        while self._pending():
            try:
                n = os.write(self.master, bytes(self.in_queue[self.in_pos:self.in_pos + CHUNK]))
            except BlockingIOError:
                break
            except OSError as exc:
                self._drop_input("the child closed its terminal: %s" % exc)
                return
            if n == 0:
                break
            self.in_pos += n
            self.in_since = time.monotonic()
        if not self._pending():
            self.in_queue = bytearray()
            self.in_pos = 0
            self.in_since = None
        elif self.in_pos >= CHUNK:
            del self.in_queue[:self.in_pos]     # what the child has taken is not kept
            self.in_pos = 0

    def _check_stall(self):
        """Input that the child has not read for DRAIN_WRITE seconds is dropped, with an error."""
        if self._pending() and time.monotonic() - self.in_since > DRAIN_WRITE:
            self._drop_input("the child does not read its input")

    def _drop_input(self, message):
        self._error("relay", "input not delivered: %s" % message, self.writer.now())
        self.in_queue = bytearray()
        self.in_pos = 0
        self.in_since = None

    def _fail(self, where, exc, t):
        self._error(where, "%s: %s" % (type(exc).__name__, exc), t)

    def _error(self, where, message, t):
        self.writer.event({"e": "error", "where": where, "msg": message, "t": t})

    # ------------------------------------------------------------ end ---

    def finish(self):
        """The end of the run: the live terminal gets the end line and its report is waited for (the
        worker writes live_final.json before it says done); then the worker is stopped and the
        recording is closed with the same time."""
        t = self.writer.now()
        if self.live is not None:
            self.live.end(t)
            self._live_wait(lambda: self.live.done)
            if self.live is not None:
                self._live_drop()
        self.writer.close(self.status, t)

    def run(self):
        self.start()
        self.loop()
        self.finish()
        return self.status

    def cleanup(self):
        """Always: the tty restored, a child that is still running stopped (by pid) and reaped,
        the descriptors closed and the FIFOs removed."""
        if self.tty_saved is not None:
            try:
                termios.tcsetattr(0, termios.TCSADRAIN, self.tty_saved)
            except termios.error:
                pass
        if self.live is not None:
            self._live_drop()
        if self.pid is not None and not self.child_exited:
            self._signal_child(signal.SIGTERM)
            deadline = time.monotonic() + KILL_AFTER
            while True:
                try:
                    pid, _status = os.waitpid(self.pid, os.WNOHANG)
                except ChildProcessError:
                    break
                if pid == self.pid:
                    break
                if time.monotonic() > deadline:
                    self._signal_child(signal.SIGKILL)
                    try:
                        os.waitpid(self.pid, 0)
                    except ChildProcessError:
                        pass
                    break
                time.sleep(0.02)
            self.child_exited = True
        for fd in (self.master, self.ctl_fd, self.ctl_writer, self.gfx_fd, self.gfx_writer):
            if fd is not None:
                try:
                    os.close(fd)
                except OSError:
                    pass
        for path in self.fifos:
            try:
                os.unlink(path)
            except OSError:
                pass
        if self.ctl_fd is not None:
            _remove_acks(self.opts.ctl)
        if self.writer is not None and not self.writer.closed:
            self.writer.close(self.status if self.status is not None else 70)


def main(argv=None):
    argv = sys.argv[1:] if argv is None else list(argv)
    try:
        opts = parse_args(argv)
    except UsageError as exc:
        print("relay.py: %s" % exc, file=sys.stderr)
        return 2
    relay = Relay(opts)
    status = 1
    try:
        status = relay.run()
    except UsageError as exc:
        print("relay.py: %s" % exc, file=sys.stderr)
        status = 2
    except Exception as exc:
        status = 70
        print("relay.py: %s: %s" % (type(exc).__name__, exc), file=sys.stderr)
        if relay.writer is not None and not relay.writer.closed:
            relay._error("relay", "%s: %s" % (type(exc).__name__, exc), relay.writer.now())
    finally:
        relay.cleanup()
    return status


if __name__ == "__main__":
    sys.exit(main())

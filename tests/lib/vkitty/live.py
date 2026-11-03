#!/usr/bin/env python3
"""The live terminal of the relay (relay.py --respond ghostty): a worker process that replays what
the child wrote into a vt.Terminal and answers the child as Ghostty would, in a process of its own.

    live.py --rec DIR --size CxR --cell WxH --pad N --profile ghostty-1.4.0|ghostty-1.3.1|kitty
            --hop tmux|tmux-off|none

The relay starts it with LiveClient (below) and talks to it in JSON lines, ASCII, one object per
line. The relay sends
    {"e":"data","ch":"tui"|"gfx","off":N,"n":L,"t":T}
            the bytes are the L bytes at offset N of <rec>/<ch>.bin, which the relay has already
            written (unbuffered); the worker reads them with os.pread when the line comes
    {"e":"blob","key":[CH,START,ORDINAL],"file":"blobs/NNNNNN.bin"|null,"err":null|TEXT}
            the media the tap read for one APC (the bytes are in <rec>/<file>); it comes before the
            data line of the chunk that holds the APC
    {"e":"resize","cols":C,"rows":R}
    {"e":"reattach"}
    {"e":"mark","seq":S}
    {"e":"end","t":T}
and reads back
    {"r":"resp","b64":B}            an answer, in the order the terminal gives them
    {"r":"marked","seq":S}          the mark S: everything before it is fed, its answers sent
    {"r":"error","msg":TEXT,"t":T|null}
                                    the worker stops; t is the last data line's time (null
                                    before any)
    {"r":"done"}                    written after live_final.json is complete; the worker exits 0

At the end line the worker writes <rec>/live_final.json (the report of the terminal at the end
time, written whole or not at all) and says done. When its input ends before the end line (the
relay is gone) it exits 3 with no report and no error line. An exception sends one error line and
exits 1. The worker ignores SIGINT and SIGHUP and runs in a session of its own, so a terminal's
signals do not reach it; the relay stops it by its pid only.

Not meant to be run by hand: tests/vkitty_spec.py drives it (relay/live_protocol) and the relay
starts it.
"""
import sys

sys.dont_write_bytecode = True   # a run of the harness writes no bytecode into the repository tree

import argparse  # noqa: E402
import base64  # noqa: E402
import json  # noqa: E402
import os  # noqa: E402
import re  # noqa: E402
import signal  # noqa: E402
import subprocess  # noqa: E402

_LIB = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _LIB not in sys.path:
    sys.path.insert(0, _LIB)

LIVE_PY = os.path.abspath(__file__)
KILL_AFTER = 5.0      # seconds the relay gives the worker to exit before it terminates it
CHUNK = 65536         # the most bytes one write or read takes from a pipe at a time


def _line(obj):
    """One protocol line: the JSON of obj, compact, then a newline."""
    return (json.dumps(obj, separators=(",", ":")) + "\n").encode("ascii")


def _send(fd, obj):
    """Write one line to the relay. The worker's stdout is blocking, so every byte is written."""
    view = memoryview(_line(obj))
    while view:
        view = view[os.write(fd, view):]


def worker(rec, cols, rows, cell, pad, profile, hop, inp=0, out=1):
    """Replay the lines of the relay into one terminal, answering on out. Returns the exit status:
    0 after the end line, 3 when the input ends before it, 1 after an error (one error line
    sent)."""
    files = {}
    last_t = None
    try:
        from vkitty import vt
        from vkitty.media import RecordedMedia
        from vkitty.recording import write_json_atomic
        from vkitty.snapshot import to_report

        def respond(data):
            _send(out, {"r": "resp", "b64": base64.b64encode(data).decode("ascii")})

        term = vt.Terminal(cols, rows, cell=cell, pad=pad, profile=profile, hop=hop,
                           respond=respond)
        term.media = RecordedMedia({}, warnings=term.warnings)
        with os.fdopen(inp, "rb", buffering=1 << 16, closefd=False) as lines:
            for raw in lines:
                frame = json.loads(raw)
                kind = frame.get("e")
                if kind == "data":
                    ch = frame["ch"]
                    if ch not in ("tui", "gfx"):
                        raise ValueError("unknown channel %r" % (ch,))
                    fd = files.get(ch)
                    if fd is None:
                        fd = files[ch] = os.open(os.path.join(rec, ch + ".bin"), os.O_RDONLY)
                    chunk = os.pread(fd, frame["n"], frame["off"])
                    if len(chunk) != frame["n"]:
                        raise OSError("short read: %d of %d bytes at %d in %s.bin"
                                      % (len(chunk), frame["n"], frame["off"], ch))
                    last_t = frame["t"]
                    term.feed(chunk, ch, last_t)
                elif kind == "blob":
                    payload = None
                    if frame.get("file") is not None:
                        with open(os.path.join(rec, frame["file"]), "rb") as fh:
                            payload = fh.read()
                    term.media.index[tuple(frame["key"])] = (payload, frame.get("err"))
                elif kind == "resize":
                    term.resize(frame["cols"], frame["rows"])
                elif kind == "reattach":
                    term.reattach()
                elif kind == "mark":
                    term.stats["since_prev_mark"] = {"apc_bytes": 0, "transmit_wire_bytes": 0}
                    _send(out, {"r": "marked", "seq": frame["seq"]})
                elif kind == "end":
                    write_json_atomic(os.path.join(rec, "live_final.json"),
                                      to_report(term.snapshot(t=frame["t"])))
                    _send(out, {"r": "done"})
                    return 0
                else:
                    raise ValueError("unknown frame %r" % (kind,))
        return 3
    except Exception as exc:  # the relay records the failure; the worker stops here
        try:
            _send(out, {"r": "error", "msg": "%s: %s" % (type(exc).__name__, exc), "t": last_t})
        except OSError:
            pass
        return 1
    finally:
        for fd in files.values():
            os.close(fd)


def _size(text):
    match = re.match(r"^(\d+)x(\d+)$", text)
    if match is None:
        raise argparse.ArgumentTypeError("a size is CxR, not %r" % (text,))
    return int(match.group(1)), int(match.group(2))


def main(argv=None):
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    from vkitty import kgp
    parser = argparse.ArgumentParser(prog="live.py", description="the live terminal of relay.py")
    parser.add_argument("--rec", required=True, help="the recording folder")
    parser.add_argument("--size", type=_size, required=True, help="CxR")
    parser.add_argument("--cell", type=_size, default=(13, 33), help="cell size, WxH")
    parser.add_argument("--pad", type=int, default=4)
    parser.add_argument("--profile", required=True, choices=kgp.PROFILES)
    parser.add_argument("--hop", required=True, choices=("tmux", "tmux-off", "none"))
    ns = parser.parse_args(argv)
    cols, rows = ns.size
    return worker(os.path.abspath(ns.rec), cols, rows, ns.cell, ns.pad, ns.profile, ns.hop)


class LiveClient:
    """The relay's side of the live terminal: one worker process, started in a session of its own
    with its own pipes (stderr discarded), both pipe ends non-blocking. Lines the worker's input
    does not take yet wait in a queue that flush() writes when the pipe is writable again, so the
    relay never blocks on the worker. Only self.proc is ever signalled."""

    def __init__(self, rec, cols, rows, cell, pad, profile, hop):
        self.proc = subprocess.Popen(
            [sys.executable, "-I", "-B", LIVE_PY, "--rec", rec, "--size", "%dx%d" % (cols, rows),
             "--cell", "%dx%d" % tuple(cell), "--pad", str(pad), "--profile", profile,
             "--hop", hop],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            start_new_session=True, bufsize=0)
        self.pid = self.proc.pid
        self.out_fd = self.proc.stdin.fileno()     # the worker's input (we write)
        self.in_fd = self.proc.stdout.fileno()     # the worker's output (we read)
        os.set_blocking(self.out_fd, False)
        os.set_blocking(self.in_fd, False)
        self.queue = bytearray()     # lines not written yet; queue[qpos:] is what is left
        self.qpos = 0
        self.inbuf = bytearray()     # output not split into lines yet
        self.seq = 0                 # the last mark sent
        self.marked = 0              # the last mark acknowledged
        self.done = False            # the worker's report is complete
        self.eof = False             # the worker's output ended (read side)
        self.closing = False         # the end line is queued: the input closes after it
        self.write_closed = False    # a write failed (the worker is gone): nothing more is written
        self.stdin_closed = False
        self.stopped = False

    # ----------------------------------------------------------- sending ---

    def _append(self, text):
        self.queue += text.encode("ascii") if isinstance(text, str) else text
        self.flush()

    def data(self, ch, off, n, t):
        """A data line: n bytes of channel ch at offset off, arrived at t."""
        if isinstance(t, float) and ch.isalpha() and ch.isascii():
            self._append('{"e":"data","ch":"%s","off":%d,"n":%d,"t":%r}\n' % (ch, off, n, t))
        else:
            self._append(_line({"e": "data", "ch": ch, "off": off, "n": n, "t": t}))

    def blob(self, key, file, err):
        self._append(_line({"e": "blob", "key": list(key), "file": file, "err": err}))

    def resize(self, cols, rows):
        self._append(_line({"e": "resize", "cols": cols, "rows": rows}))

    def reattach(self):
        self._append(_line({"e": "reattach"}))

    def mark(self):
        """Send a mark line; returns its sequence number (handled when marked reaches it)."""
        self.seq += 1
        self._append(_line({"e": "mark", "seq": self.seq}))
        return self.seq

    def end(self, t):
        """Send the end line; the input closes once it is written."""
        self.closing = True
        self._append(_line({"e": "end", "t": t}))

    def pending(self):
        """True when lines are queued and the worker's input is still open."""
        return self.qpos < len(self.queue) and not self.write_closed and not self.stdin_closed

    def flush(self):
        """Write the queue as far as the pipe takes it, without blocking."""
        if self.write_closed or self.stdin_closed:
            return
        while self.qpos < len(self.queue):
            try:
                n = os.write(self.out_fd, bytes(self.queue[self.qpos:self.qpos + CHUNK]))
            except BlockingIOError:
                break
            except OSError:
                # the worker is gone; its output's end reports it, so the reads go on
                self.write_closed = True
                self.queue = bytearray()
                self.qpos = 0
                return
            self.qpos += n
        if self.qpos >= len(self.queue):
            self.queue = bytearray()
            self.qpos = 0
            if self.closing:
                self._close_input()
        elif self.qpos >= CHUNK:
            del self.queue[:self.qpos]
            self.qpos = 0

    def _close_input(self):
        if not self.stdin_closed:
            self.stdin_closed = True
            self.proc.stdin.close()

    # ---------------------------------------------------------- reading ---

    def read(self):
        """The lines the worker has written: one non-blocking read, then every complete line,
        parsed. marked and done set the matching fields; a line that is not JSON becomes an error
        line. An empty read is the end of the worker's output (eof)."""
        if self.eof:
            return []
        try:
            chunk = os.read(self.in_fd, CHUNK)
        except BlockingIOError:
            return []
        if not chunk:
            self.eof = True
        self.inbuf += chunk
        frames = []
        start = 0
        while True:
            cut = self.inbuf.find(b"\n", start)
            if cut < 0:
                break
            raw = bytes(self.inbuf[start:cut])
            start = cut + 1
            if not raw.strip():
                continue
            try:
                frame = json.loads(raw)
            except ValueError:
                frame = None
            if not isinstance(frame, dict):
                frame = {"r": "error", "msg": "bad line from the live terminal: %r" % (raw[:200],),
                         "t": None}
            if frame.get("r") == "marked":
                self.marked = max(self.marked, frame.get("seq", 0))
            elif frame.get("r") == "done":
                self.done = True
            frames.append(frame)
        del self.inbuf[:start]
        return frames

    # ---------------------------------------------------------- stopping ---

    def stop(self):
        """Close both pipes, then wait for the worker: it reads the end of its input and exits. It
        is terminated after KILL_AFTER seconds and killed after another KILL_AFTER seconds. Returns
        its exit status (a negative number when a signal ended it)."""
        if self.stopped:
            return self.proc.returncode
        self.stopped = True
        self.proc.stdin.close()
        self.proc.stdout.close()
        try:
            return self.proc.wait(KILL_AFTER)
        except subprocess.TimeoutExpired:
            self.proc.terminate()
        try:
            return self.proc.wait(KILL_AFTER)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            return self.proc.wait()


if __name__ == "__main__":
    sys.exit(main())

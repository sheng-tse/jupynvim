#!/usr/bin/env python3
"""A terminal chain that answers out of order, or late, for the real-screen tests.

Runs a command on a pty of its own between the real terminal and the command and
hands the command what the terminal says with one change: every complete OSC 11
answer (the terminal's background color) is held back DELAY_MS behind everything
else, so the answer to a DSR written after the OSC 11 question arrives first.
DELAY_MS 0 passes everything through unchanged.

  python3 -I tests/lib/reorder_pty.py DELAY_MS [--out FILE] [--slow-after MS] -- command [args...]

--slow-after MS: a slow link instead. What the terminal says in the first MS ms
(the answers to the command's own start-up questions) is passed on at once;
from then on every chunk is passed on DELAY_MS late, in order (nothing is
reordered). The command's output goes to the terminal as it is (and, with
--out, is also appended to FILE as it comes, byte for byte: what was drawn, and
in which order). The exit status is the command's.
"""
import errno
import fcntl
import os
import pty
import re
import select
import signal
import sys
import termios
import time
import tty

# a complete OSC 11 answer, ended by BEL or ST
OSC11 = re.compile(rb"\x1b\]11;[^\x07\x1b]*(?:\x07|\x1b\\)")
# a started answer that does not end within this long is not one: it is passed on
PARTIAL_MS = 500


def main():
    args = sys.argv[1:]
    out_path, slow_after = None, None
    while len(args) >= 3 and args[1] in ("--out", "--slow-after"):
        if args[1] == "--out":
            out_path = args[2]
        else:
            slow_after = float(args[2]) / 1000.0
        del args[1:3]
    if len(args) < 3 or args[1] != "--":
        sys.stderr.write(__doc__)
        return 2
    delay = float(args[0]) / 1000.0
    cmd = args[2:]
    pid, fd = pty.fork()
    if pid == 0:
        try:
            os.execvp(cmd[0], cmd)
        finally:
            os._exit(127)
    out_log = open(out_path, "ab", buffering=0) if out_path else None

    def winsz(*_):
        try:
            size = fcntl.ioctl(0, termios.TIOCGWINSZ, b"\0" * 8)
            fcntl.ioctl(fd, termios.TIOCSWINSZ, size)
        except OSError:
            pass

    winsz()
    signal.signal(signal.SIGWINCH, winsz)
    saved = termios.tcgetattr(0) if os.isatty(0) else None
    if saved is not None:
        tty.setraw(0)
    pending = b""  # terminal input not passed on yet: a started OSC 11 answer
    pending_since = 0.0
    held = []  # [due, bytes]: complete OSC 11 answers waiting (a slow link: every chunk)
    t0 = time.time()
    try:
        while True:
            now = time.time()
            while held and held[0][0] <= now:
                os.write(fd, held.pop(0)[1])
            timeout = 0.5
            if held:
                timeout = min(timeout, max(0.0, held[0][0] - now))
            if pending:
                timeout = min(timeout, max(0.0, pending_since + PARTIAL_MS / 1000.0 - now))
            try:
                ready, _, _ = select.select([0, fd], [], [], timeout)
            except InterruptedError:
                continue
            if fd in ready:
                try:
                    data = os.read(fd, 65536)
                except OSError as e:
                    if e.errno in (errno.EIO, errno.EBADF):
                        break
                    raise
                if not data:
                    break
                os.write(1, data)
                if out_log is not None:
                    out_log.write(data)
            if 0 in ready:
                data = os.read(0, 65536)
                if not data:
                    break
                if slow_after is not None:
                    if time.time() - t0 >= slow_after:
                        held.append([time.time() + delay, data])
                    else:
                        os.write(fd, data)
                    continue
                if not pending:
                    pending_since = time.time()
                pending += data
            elif pending and time.time() - pending_since > PARTIAL_MS / 1000.0:
                os.write(fd, pending)
                pending = b""
                continue
            if not pending:
                continue
            if delay <= 0:
                os.write(fd, pending)
                pending = b""
                continue
            out = b""
            while True:
                start = pending.find(b"\x1b]11;")
                m = OSC11.search(pending)
                if m and m.start() == start:
                    out += pending[: m.start()]
                    held.append([time.time() + delay, m.group(0)])
                    pending = pending[m.end():]
                    continue
                if start >= 0:
                    # a started answer that is not complete: what is before it goes on
                    out += pending[:start]
                    pending = pending[start:]
                else:
                    out += pending
                    pending = b""
                break
            if out:
                os.write(fd, out)
    finally:
        if saved is not None:
            termios.tcsetattr(0, termios.TCSADRAIN, saved)
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass
    try:
        _, status = os.waitpid(pid, 0)
    except OSError:
        return 0
    return os.waitstatus_to_exitcode(status)


if __name__ == "__main__":
    sys.exit(main())

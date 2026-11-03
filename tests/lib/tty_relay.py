"""Run a command on its own pty and relay its output at a bounded rate.

usage: python3 -I tests/lib/tty_relay.py [--read BYTES] [--delay-ms MS] [--stall-ms MS]
       [--pause PERIOD_MS:PAUSE_MS] [--answer-delay-ms MS [--answer-gap-ms MS]] [--out-rate KBPS]
       [--hold-answers-ms MS [--hold-until-frame-request | --hold-from-marker] [--hold-log FILE]]
       [--drop-xtversion] -- cmd args...

Stands in for a terminal that does not drain the pty instantly (Ghostty
parses kitty graphics and decodes each PNG on its I/O thread before it reads
on). The child gets the pty as its controlling terminal (pty.fork does
setsid + TIOCSCTTY), so /dev/tty in the child and its children is this pty,
exactly as under a real terminal. Every read is at most --read bytes and is
followed by a --delay-ms pause; that lets the kernel's tty output queue
(hiwat about 2 KB on macOS) fill, so writers block or write partially, as
they do under a busy terminal. Input and window size pass straight through,
unless --answer-delay-ms holds input back: then what the terminal sends (its
answers to the program's requests, and keys) reaches the child that much
later, split before each ESC and, with --answer-gap-ms, that much apart, as
from a terminal on a slow link that answers each request on its own. With
--hold-answers-ms everything the terminal sends in the first MS of the run (the
answers to the program's start queries) is held and passed on together at MS,
so a program that is busy writing reads them late, as over a slow link. With
--hold-until-frame-request as well, they are passed on 1 s after the relay
passed on to the terminal the first status request (ESC [ 5 n) that follows
a graphics command (ESC _ G) in the program's output, if that comes before
MS: the terminal's answer to that request is held with the others and they
reach the program in one write. With --hold-from-marker instead, MS counts
from when the relay passed on to the terminal the program's first XTVERSION
request (ESC [ > q, the marker jupynvim sends before its first frame), not
from the start, so the hold outlasts a limit the program counts from that
request however long the program took to start; everything is held until
then, and if no such request has gone out MS + 60 s after the start, the
held input is passed on then. --hold-log FILE gets one line when they are
passed on (ms since the start, bytes, and why: request, marker or time;
with --hold-from-marker also when the request went out and how long after it
the input was passed on, in ms). With
--out-rate the output is instead read as soon as the program writes it and
passed on at that rate from a buffer of any size, as over a link with large
buffers (SSH): the program's writes finish at once, and the terminal gets
them seconds later. With --drop-xtversion the terminal's answers to an
XTVERSION request (ESC P > | name ESC \\) never reach the program, standing
in for a terminal that answers status requests but not that (tmux before 3.2,
Apple Terminal).
"""
import argparse, fcntl, os, pty, select, signal, sys, termios, time, tty

ap = argparse.ArgumentParser()
ap.add_argument("--read", type=int, default=16384)
ap.add_argument("--delay-ms", type=float, default=1.0)
ap.add_argument("--stall-ms", type=float, default=0.0,
                help="extra pause after a read that completes a kitty transmit (m=0), "
                     "standing in for the terminal decoding the PNG before it reads on")
ap.add_argument("--pause", default="",
                help="PERIOD_MS:PAUSE_MS - stop reading for PAUSE_MS every PERIOD_MS, standing in "
                     "for the terminal's renderer holding the screen lock once per frame")
ap.add_argument("--answer-delay-ms", type=float, default=0.0,
                help="hold what comes from the terminal this long before it reaches the child")
ap.add_argument("--answer-gap-ms", type=float, default=0.0,
                help="with --answer-delay-ms: at least this long between the pieces of input, "
                     "split before each ESC (one answer or key each)")
ap.add_argument("--hold-answers-ms", type=float, default=0.0,
                help="hold what comes from the terminal in the first MS of the run until MS, then pass it on together")
ap.add_argument("--hold-until-frame-request", action="store_true",
                help="with --hold-answers-ms: pass the held input on 1 s after the first ESC [ 5 n that follows "
                     "an ESC _ G in the output went to the terminal, if that is sooner")
ap.add_argument("--hold-from-marker", action="store_true",
                help="with --hold-answers-ms: count MS from the first ESC [ > q passed on to the terminal, "
                     "not from the start (held until then; passed on at MS + 60 s if none goes out)")
ap.add_argument("--hold-log", default="",
                help="with --hold-answers-ms: append one line here when the held input is passed on")
ap.add_argument("--drop-xtversion", action="store_true",
                help="drop the terminal's answers to XTVERSION (ESC P > | ... ESC \\) before they reach the child")
ap.add_argument("--out-rate", type=float, default=0.0,
                help="KB/s: read the program's output at once and pass it on at this rate")
ap.add_argument("cmd", nargs=argparse.REMAINDER)
a = ap.parse_args()
cmd = a.cmd[1:] if a.cmd and a.cmd[0] == "--" else a.cmd
if a.hold_from_marker and a.hold_until_frame_request:
    ap.error("--hold-from-marker and --hold-until-frame-request do not go together")

def winsz(fd):
    return fcntl.ioctl(fd, termios.TIOCGWINSZ, b"\0" * 8)

pid, master = pty.fork()
if pid == 0:
    os.execvp(cmd[0], cmd)

fcntl.ioctl(master, termios.TIOCSWINSZ, winsz(0))
def on_winch(*_):
    try:
        fcntl.ioctl(master, termios.TIOCSWINSZ, winsz(0))
        os.kill(pid, signal.SIGWINCH)
    except OSError:
        pass
signal.signal(signal.SIGWINCH, on_winch)
period = pause = 0.0
if a.pause:
    period, pause = [float(x) / 1000.0 for x in a.pause.split(":")]
last_pause = time.monotonic()
held = []  # input held back, oldest first: [time it is due, bytes]
t_start = time.monotonic()
hold_until = t_start + a.hold_answers_ms / 1000.0
if a.hold_from_marker:
    hold_until += 60.0  # until a marker request goes out (see watch_marker)
hold_done = a.hold_answers_ms <= 0  # the held input has been passed on
seen_apc, out_tail = False, b""  # a graphics command went out; the last bytes passed on
def watch_out(d):
    # with --hold-until-frame-request: the first status request after a
    # graphics command moves the release to 1 s from now
    global seen_apc, out_tail, hold_until
    if hold_done or not a.hold_until_frame_request:
        return
    buf = out_tail + d
    out_tail = buf[-8:]
    if not seen_apc:
        i = buf.find(b"\x1b_G")
        if i < 0:
            return
        seen_apc, buf = True, buf[i:]
    if b"\x1b[5n" in buf:
        hold_until = min(hold_until, time.monotonic() + 1.0)
        a.hold_until_frame_request = False
        hold_why[0] = "request"
hold_why = ["time"]
MARKER = b"\x1b[>q"
marker_at, marker_tail = None, b""  # when the first marker request went out; the last bytes passed on
def watch_marker(d):
    # with --hold-from-marker: the first marker request passed on to the
    # terminal moves the release to MS from now
    global marker_at, marker_tail, hold_until
    if hold_done or not a.hold_from_marker or marker_at is not None:
        return
    buf = marker_tail + d
    marker_tail = buf[-(len(MARKER) - 1):]
    if MARKER in buf:
        marker_at = time.monotonic()
        hold_until = marker_at + a.hold_answers_ms / 1000.0
        hold_why[0] = "marker"
def release_held():
    # pass on everything held, in one write
    global hold_done
    data = b"".join(x[1] for x in held)
    del held[:]
    if data:
        os.write(master, data)
    hold_done = True
    if a.hold_log:
        now = time.monotonic()
        line = "release ms=%d bytes=%d why=%s" % ((now - t_start) * 1000, len(data), hold_why[0])
        if a.hold_from_marker:
            line += " marker_ms=%s held_ms=%s" % (
                "none" if marker_at is None else "%d" % ((marker_at - t_start) * 1000),
                "none" if marker_at is None else "%d" % round((now - marker_at) * 1000))
        with open(a.hold_log, "a") as f:
            f.write(line + "\n")
def hold_input(d):
    # split before each ESC that starts an answer, not before the ESC of a
    # string terminator (ESC \, which ends a DCS or OSC answer and belongs to
    # it); a piece that starts with no ESC (the rest of a sequence a read
    # cut, or keys) goes with the piece held before it
    pieces, start = [], 0
    for i in range(1, len(d)):
        if d[i] == 0x1B and d[i + 1:i + 2] != b"\\":
            pieces.append(d[start:i])
            start = i
    pieces.append(d[start:])
    now = time.monotonic()
    for x in pieces:
        if held and (not x.startswith(b"\x1b") or x.startswith(b"\x1b\\")):
            held[-1][1] += x
            continue
        due = now + a.answer_delay_ms / 1000.0
        if not hold_done:
            due = max(due, hold_until)
        if held and x.startswith(b"\x1b"):
            due = max(due, held[-1][0] + a.answer_gap_ms / 1000.0)
        held.append([due, x])
xt_in, xt_hold = False, b""  # --drop-xtversion: inside an answer being dropped; a possible start/end cut by a read
def drop_xtversion(d):
    # the input without the XTVERSION answers; a piece cut at the end of a read waits for the next
    global xt_in, xt_hold
    data, xt_hold, out_b, i = xt_hold + d, b"", bytearray(), 0
    start = b"\x1bP>|"
    while i < len(data):
        if xt_in:
            j = data.find(b"\x1b\\", i)
            if j < 0:
                if data.endswith(b"\x1b"):
                    xt_hold = b"\x1b"
                return bytes(out_b)
            i, xt_in = j + 2, False
            continue
        j = data.find(b"\x1b", i)
        if j < 0:
            out_b += data[i:]
            break
        out_b += data[i:j]
        if data.startswith(start, j):
            i, xt_in = j + len(start), True
        elif len(data) - j < len(start) and start.startswith(data[j:]):
            xt_hold = data[j:]
            break
        else:
            out_b.append(0x1b)
            i = j + 1
    return bytes(out_b)
out = bytearray()  # with --out-rate: output read, not passed on yet
rate = a.out_rate * 1024.0
tokens, last_t = 0.0, time.monotonic()
def pass_out(final=False):
    # pass on what the rate allows since the last call (bursts of 20 ms)
    global tokens, last_t
    while out:
        now = time.monotonic()
        tokens = min(tokens + (now - last_t) * rate, rate * 0.02)
        last_t = now
        k = min(len(out), int(tokens))
        if k > 0:
            watch_out(bytes(out[:k]))
            watch_marker(bytes(out[:k]))
            v = memoryview(bytes(out[:k]))
            while v:
                n = os.write(1, v)
                v = v[n:]
            del out[:k]
            tokens -= k
        if not final:
            return
        time.sleep(0.005)
old = termios.tcgetattr(0)
tty.setraw(0)
try:
    while True:
        if not hold_done and time.monotonic() >= hold_until:
            release_held()
        while held and held[0][0] <= time.monotonic():
            os.write(master, held.pop(0)[1])
        if out:
            pass_out()
        else:
            tokens, last_t = 0.0, time.monotonic()
        wait = max(0.0, held[0][0] - time.monotonic()) if held else None
        if not hold_done:
            w = max(0.0, hold_until - time.monotonic())
            wait = w if wait is None else min(wait, w)
        if out:
            wait = 0.005 if wait is None else min(wait, 0.005)
        try:
            r, _, _ = select.select([0, master], [], [], wait)
        except InterruptedError:
            continue
        if 0 in r:
            d = os.read(0, 4096)
            if not d:
                break
            if a.drop_xtversion:
                d = drop_xtversion(d)
                if not d:
                    continue
            if a.answer_delay_ms > 0 or not hold_done:
                hold_input(d)
            else:
                os.write(master, d)
        if period > 0 and time.monotonic() - last_pause >= period:
            time.sleep(pause)
            last_pause = time.monotonic()
        if master in r:
            try:
                d = os.read(master, 65536 if rate > 0 else a.read)
            except OSError:
                break
            if not d:
                break
            if rate > 0:
                out += d
                continue
            watch_out(d)
            watch_marker(d)
            v = memoryview(d)
            while v:
                n = os.write(1, v)
                v = v[n:]
            if a.delay_ms > 0:
                time.sleep(a.delay_ms / 1000.0)
            if a.stall_ms > 0 and (b"m=0;" in d or b"m=0,q=2;" in d):
                time.sleep(a.stall_ms / 1000.0)
finally:
    try:
        pass_out(final=True)
    except OSError:
        pass
    termios.tcsetattr(0, termios.TCSADRAIN, old)
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError:
        pass

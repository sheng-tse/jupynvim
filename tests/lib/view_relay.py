#!/usr/bin/env python3
"""Relay a backend's stdio, hiding one directory of this machine from it.

    python3 -I tests/lib/view_relay.py FROM TO CMD...

Runs CMD with the relay's stdin passed to it, every occurrence of the bytes
FROM replaced by TO, and CMD's stdout passed back unchanged. FROM and TO have
the same length, so every msgpack length stays right: a request for a path
that has FROM in it reaches CMD as the same path with TO, a directory that
does not exist there. A remote backend started through it finds this
machine's FROM directory missing, as a backend on another machine does,
although the two share a disk here. tests/routing_spec.lua starts its stub
remote through it.

Bytes at the end of a read that may begin FROM are held for the next read,
or for 20 ms when none comes, so a match split across two reads is still
replaced and nothing waits longer than that. A SIGTERM is passed on to CMD,
the end of the relay's stdin closes CMD's stdin, and the relay exits with
CMD's exit code once CMD's output ends.
"""
import os
import select
import signal
import subprocess
import sys
import threading


def write_all(fd, data):
    view = memoryview(data)
    while view:
        n = os.write(fd, view)
        view = view[n:]


def main():
    if len(sys.argv) < 4:
        sys.exit("usage: view_relay.py FROM TO CMD...")
    src, dst = os.fsencode(sys.argv[1]), os.fsencode(sys.argv[2])
    if not src or len(src) != len(dst):
        sys.exit("view_relay.py: FROM and TO must be non-empty and the same length")
    child = subprocess.Popen(sys.argv[3:], stdin=subprocess.PIPE, stdout=subprocess.PIPE, bufsize=0)
    signal.signal(signal.SIGTERM, lambda *_: child.send_signal(signal.SIGTERM))

    def held(buf):
        # the longest tail of buf that is the start of FROM, never all of it
        for k in range(min(len(src) - 1, len(buf)), 0, -1):
            if src.startswith(buf[-k:]):
                return k
        return 0

    def pump_in():
        to_child = child.stdin.fileno()
        pending = b""
        try:
            while True:
                ready, _, _ = select.select([0], [], [], 0.02 if pending else None)
                if not ready:
                    write_all(to_child, pending)
                    pending = b""
                    continue
                data = os.read(0, 65536)
                if not data:
                    break
                buf = (pending + data).replace(src, dst)
                k = held(buf)
                pending = buf[len(buf) - k:]
                write_all(to_child, buf[:len(buf) - k])
            if pending:
                write_all(to_child, pending)
        except OSError:
            pass
        finally:
            try:
                child.stdin.close()
            except OSError:
                pass

    threading.Thread(target=pump_in, daemon=True).start()
    out = child.stdout.fileno()
    while True:
        data = os.read(out, 65536)
        if not data:
            break
        write_all(1, data)
    sys.exit(child.wait())


main()

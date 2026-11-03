#!/usr/bin/env python3
"""Relay a backend's stdio and hold its output back once, on request.

    python3 -I tests/lib/delay_relay.py TRIGGER CMD...

Runs CMD with the relay's stdin passed to it and its stdout passed back. When
output arrives while the file TRIGGER exists, the relay removes TRIGGER and
holds that output, and everything queued behind it, for the number of
milliseconds TRIGGER holds: one slow answer, as over a loaded link, at the
moment a test asks for it. Write TRIGGER to another name and rename it into
place, so the relay never reads it half written.

A SIGTERM is passed on to CMD, the end of the relay's stdin closes CMD's
stdin, and the relay exits with CMD's exit code once CMD's output ends.
tests/routing_spec.lua starts a remote backend through it to time a save.
"""
import os
import signal
import subprocess
import sys
import threading
import time


def write_all(fd, data):
    view = memoryview(data)
    while view:
        n = os.write(fd, view)
        view = view[n:]


def main():
    if len(sys.argv) < 3:
        sys.exit("usage: delay_relay.py TRIGGER CMD...")
    trigger, cmd = sys.argv[1], sys.argv[2:]
    child = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, bufsize=0)
    signal.signal(signal.SIGTERM, lambda *_: child.send_signal(signal.SIGTERM))

    def pump_in():
        try:
            while True:
                data = os.read(0, 65536)
                if not data:
                    break
                write_all(child.stdin.fileno(), data)
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
        try:
            with open(trigger) as f:
                ms = int(f.read().strip() or "0")
            os.unlink(trigger)
            time.sleep(ms / 1000)
        except (FileNotFoundError, ValueError):
            pass
        write_all(1, data)
    sys.exit(child.wait())


main()

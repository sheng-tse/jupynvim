#!/usr/bin/env python3
"""A scripted child program for the relay tests: it runs the steps of a JSON script on its
terminal, then writes a result JSON file and exits 0.

    python3 -I testchild.py SCRIPT.json RESULT.json

The script is a list of steps, run in order. Each step is an object with one key:

    {"write_b64": "<base64>"}          write the bytes to the terminal
    {"write_file": "<path>"}           write the bytes of a file to the terminal
    {"sleep": seconds}
    {"wait_file": path, "timeout": s}  wait (up to s seconds, default 10) until the path exists; a
                                       timeout is listed in the result's timeouts and the script
                                       goes on
    {"read_until": "ST" | N, "timeout": s, "save": name}
                                       read the terminal's input until ESC backslash ("ST") or N
                                       bytes; a timeout keeps what was read
    {"winsize": name}                  the terminal's size (rows, cols, xpixel, ypixel)
    {"print_winsize_every": ms, "count": n}
                                       n lines "WS cols rows xpixel ypixel", ms apart
    {"print_pid": true}                a line "PID n" with this process's pid
    {"stop_self": true}                stop this process (SIGSTOP) until it is continued
    {"tmp_create": {"dir": d, "name": n, "data_b64": b}}
                                       a file in d (default: the temporary folder of TMPDIR)
    {"shm_create": {"name": n, "data_b64": b}}
                                       a shared memory object that is left for the reader

The terminal is put in raw mode first (no echo, no output processing), so the bytes arrive
unchanged. The result file holds the pid of this process, every read (base64, with a timeout
flag), every winsize, the files and shared memory objects created, and the paths a wait_file
gave up on (timeouts, present only when there were any). A failing step writes the
error into the result and exits 1.
"""
import base64
import fcntl
import json
import os
import select
import signal
import struct
import sys
import tempfile
import termios
import time
import tty

sys.dont_write_bytecode = True   # a run of the harness writes no bytecode into the repository tree

_LIB = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _LIB not in sys.path:
    sys.path.insert(0, _LIB)

ST = b"\x1b\\"
_KINDS = ("write_b64", "write_file", "sleep", "read_until", "winsize", "print_winsize_every",
          "print_pid", "tmp_create", "shm_create", "stop_self", "wait_file")


def _write_all(fd, data):
    view = memoryview(data)
    while view:
        view = view[os.write(fd, view):]


def _wait_file(path, timeout):
    """Poll every 5 ms until the path exists; False when the timeout passed first."""
    deadline = time.monotonic() + timeout
    while not os.path.exists(path):
        if time.monotonic() > deadline:
            return False
        time.sleep(0.005)
    return True


def _read_some(fd, timeout):
    """One byte (or more) from fd within timeout seconds; b"" on timeout."""
    ready = select.select([fd], [], [], timeout)[0]
    return os.read(fd, 1) if ready else b""


def _read_until(fd, want, timeout):
    """Read from fd until the terminator (ST) or a count of bytes, or until the timeout. Returns
    (bytes read, timed out). Byte at a time, so nothing after the terminator is consumed."""
    deadline = time.monotonic() + timeout
    got = bytearray()
    while True:
        if want == "ST":
            if got.endswith(ST):
                return bytes(got), False
        elif len(got) >= want:
            return bytes(got), False
        left = deadline - time.monotonic()
        if left <= 0:
            return bytes(got), True
        chunk = _read_some(fd, left)
        if not chunk:
            if time.monotonic() >= deadline:
                return bytes(got), True
            continue
        got += chunk


def _winsize(fd):
    raw = fcntl.ioctl(fd, termios.TIOCGWINSZ, struct.pack("HHHH", 0, 0, 0, 0))
    rows, cols, xpx, ypx = struct.unpack("HHHH", raw)
    return [rows, cols, xpx, ypx]


def _create_file(directory, name, data):
    path = os.path.join(directory or tempfile.gettempdir(), name)
    with open(path, "wb") as fh:
        fh.write(data)
    return path


def _create_shm(name, data):
    import mmap
    import _posixshmem
    fd = _posixshmem.shm_open(name, os.O_CREAT | os.O_EXCL | os.O_RDWR, 0o600)
    try:
        os.ftruncate(fd, len(data))
        mapped = mmap.mmap(fd, len(data))
        mapped[:len(data)] = data
        mapped.close()
    finally:
        os.close(fd)


def _write_result(path, result):
    """The result whole or not at all: a temporary name, then a rename."""
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="ascii") as fh:
        json.dump(result, fh)
    os.replace(tmp, path)


def run(script_path, result_path):
    with open(script_path, encoding="ascii") as fh:
        steps = json.load(fh)
    result = {"pid": os.getpid(), "reads": {}, "winsizes": {}, "created": [], "shm": [],
              "error": None}
    stdin = 0
    stdout = 1
    try:
        if os.isatty(stdin):
            tty.setraw(stdin)
        for step in steps:
            kinds = [key for key in step if key in _KINDS]
            if len(kinds) != 1:
                raise ValueError("a step names exactly one action: %r" % (step,))
            kind = kinds[0]
            arg = step[kind]
            if kind == "write_b64":
                _write_all(stdout, base64.b64decode(arg))
            elif kind == "write_file":
                with open(arg, "rb") as fh:
                    while True:
                        block = fh.read(65536)
                        if not block:
                            break
                        _write_all(stdout, block)
            elif kind == "sleep":
                time.sleep(float(arg))
            elif kind == "wait_file":
                if not _wait_file(arg, float(step.get("timeout", 10))):
                    result.setdefault("timeouts", []).append(arg)
            elif kind == "read_until":
                got, timed_out = _read_until(stdin, arg, float(step.get("timeout", 5)))
                result["reads"][step["save"]] = {
                    "b64": base64.b64encode(got).decode("ascii"), "timeout": timed_out}
            elif kind == "winsize":
                result["winsizes"][arg] = _winsize(stdin)
            elif kind == "print_winsize_every":
                for _ in range(int(step["count"])):
                    rows, cols, xpx, ypx = _winsize(stdin)
                    line = "WS %d %d %d %d\n" % (cols, rows, xpx, ypx)
                    _write_all(stdout, line.encode("ascii"))
                    time.sleep(float(arg) / 1000.0)
            elif kind == "print_pid":
                _write_all(stdout, ("PID %d\r\n" % os.getpid()).encode("ascii"))
            elif kind == "tmp_create":
                result["created"].append(_create_file(arg.get("dir"), arg["name"],
                                                      base64.b64decode(arg["data_b64"])))
            elif kind == "shm_create":
                _create_shm(arg["name"], base64.b64decode(arg["data_b64"]))
                result["shm"].append(arg["name"])
            elif kind == "stop_self":
                os.kill(os.getpid(), signal.SIGSTOP)
    except Exception as exc:  # the relay reports the failure; the result says what went wrong
        result["error"] = "%s: %s" % (type(exc).__name__, exc)
        _write_result(result_path, result)
        return 1
    _write_result(result_path, result)
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("usage: testchild.py SCRIPT.json RESULT.json", file=sys.stderr)
        sys.exit(2)
    sys.exit(run(sys.argv[1], sys.argv[2]))

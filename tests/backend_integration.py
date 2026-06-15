#!/usr/bin/env python3
"""
Backend integration tests — drive jupynvim-core directly via length-prefixed
msgpack-rpc on stdin/stdout. Verifies wire protocol, kernel lifecycle,
notebook ops, output streaming, save round-trip.
"""
import json
import os
import signal
import struct
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

import msgpack

CORE = Path(__file__).resolve().parent.parent / "core/target/release/jupynvim-core"
PASS, FAIL = 0, 0
RESULTS = []


def report(name, ok, detail=""):
    global PASS, FAIL
    PASS += int(ok)
    FAIL += int(not ok)
    RESULTS.append((name, ok, detail))
    sym = "[PASS]" if ok else "[FAIL]"
    print(f"  {sym} {name}{(' — ' + detail) if detail and not ok else ''}")


class Client:
    def __init__(self):
        self.p = subprocess.Popen(
            [str(CORE)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
        )
        self.events = []
        self.next_id = 1
        self.unpacker = msgpack.Unpacker(raw=False)
        self._stop = False
        threading.Thread(target=self._read_loop, daemon=True).start()

    def _read_loop(self):
        while not self._stop:
            hdr = b""
            try:
                while len(hdr) < 4:
                    chunk = os.read(self.p.stdout.fileno(), 4 - len(hdr))
                    if not chunk:
                        return
                    hdr += chunk
                (n,) = struct.unpack(">I", hdr)
                payload = b""
                while len(payload) < n:
                    chunk = os.read(self.p.stdout.fileno(), n - len(payload))
                    if not chunk:
                        return
                    payload += chunk
                msg = msgpack.unpackb(payload, raw=False)
                self.events.append(msg)
            except OSError:
                return

    def _send(self, method, params, msgid=None, notify=False):
        if notify:
            payload = msgpack.packb([2, method, [params]])
        else:
            payload = msgpack.packb([0, msgid, method, [params]])
        hdr = struct.pack(">I", len(payload))
        self.p.stdin.write(hdr + payload)
        self.p.stdin.flush()

    def call(self, method, params, timeout=10):
        msgid = self.next_id
        self.next_id += 1
        self._send(method, params, msgid)
        start = time.time()
        while time.time() - start < timeout:
            for ev in self.events:
                if isinstance(ev, list) and ev[0] == 1 and ev[1] == msgid:
                    return ev[2], ev[3]
            time.sleep(0.02)
        return "timeout", None

    def wait_event(self, predicate, timeout=5):
        start = time.time()
        while time.time() - start < timeout:
            for ev in self.events:
                if predicate(ev):
                    return ev
            time.sleep(0.02)
        return None

    def stop(self):
        self._stop = True
        self.p.terminate()
        try:
            self.p.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self.p.kill()


def make_test_nb():
    return {
        "cells": [
            {"cell_type": "markdown", "id": "m1", "metadata": {}, "source": "# Title"},
            {"cell_type": "code", "id": "c1", "metadata": {}, "source": "import numpy as np\nprint('hi')", "execution_count": None, "outputs": []},
            {"cell_type": "code", "id": "c2", "metadata": {}, "source": "x = np.arange(5)\nx ** 2", "execution_count": None, "outputs": []},
            {"cell_type": "code", "id": "c3", "metadata": {}, "source": "1 / 0", "execution_count": None, "outputs": []},
        ],
        "metadata": {"kernelspec": {"display_name": "Python 3", "language": "python", "name": "python3"}},
        "nbformat": 4, "nbformat_minor": 5,
    }


def t_ping():
    cl = Client()
    err, res = cl.call("ping", {})
    report("ping", err is None and res == "pong", str(err))
    cl.stop()


def t_list_kernels():
    cl = Client()
    err, res = cl.call("list_kernels", {})
    ok = err is None and isinstance(res, list) and any(k.get("name") == "python3" for k in res)
    report("list_kernels finds python3", ok, str(err))
    cl.stop()


def t_open_close():
    cl = Client()
    nb_path = tempfile.mktemp(suffix=".ipynb")
    json.dump(make_test_nb(), open(nb_path, "w"))
    err, res = cl.call("open", {"path": nb_path})
    ok = err is None and res and "session_id" in res and len(res["snapshot"]["cells"]) == 4
    report("open returns 4 cells", ok, str(err))
    sid = res["session_id"]
    err, _ = cl.call("close", {"session_id": sid})
    report("close works", err is None, str(err))
    cl.stop()
    os.unlink(nb_path)


def t_kernel_lifecycle():
    cl = Client()
    nb_path = tempfile.mktemp(suffix=".ipynb")
    json.dump(make_test_nb(), open(nb_path, "w"))
    _, res = cl.call("open", {"path": nb_path})
    sid = res["session_id"]
    err, res2 = cl.call("start_kernel", {"session_id": sid}, timeout=15)
    report("start_kernel returns", err is None, str(err))
    err, _ = cl.call("stop_kernel", {"session_id": sid})
    report("stop_kernel returns", err is None, str(err))
    cl.stop()
    os.unlink(nb_path)


def t_run_cell_streams():
    cl = Client()
    nb_path = tempfile.mktemp(suffix=".ipynb")
    json.dump(make_test_nb(), open(nb_path, "w"))
    _, res = cl.call("open", {"path": nb_path})
    sid = res["session_id"]
    cl.call("start_kernel", {"session_id": sid}, timeout=15)
    cl.events.clear()
    err, _ = cl.call("execute", {"session_id": sid, "cell_id": "c1"})
    report("execute c1 returns", err is None, str(err))
    ev = cl.wait_event(lambda e: e[0] == 2 and e[1] == "cell_event"
                       and e[2][0]["cell_id"] == "c1"
                       and e[2][0]["event"]["kind"] == "stream", timeout=10)
    ok = ev is not None and ev[2][0]["event"]["text"].rstrip() == "hi"
    report("c1 stream stdout 'hi'", ok, "no event" if ev is None else "")
    cl.call("stop_kernel", {"session_id": sid})
    cl.stop()
    os.unlink(nb_path)


def t_run_cell_expression():
    cl = Client()
    nb_path = tempfile.mktemp(suffix=".ipynb")
    json.dump(make_test_nb(), open(nb_path, "w"))
    _, res = cl.call("open", {"path": nb_path})
    sid = res["session_id"]
    cl.call("start_kernel", {"session_id": sid}, timeout=15)
    cl.call("execute", {"session_id": sid, "cell_id": "c1"})
    cl.wait_event(lambda e: e[0]==2 and e[1]=="cell_event" and e[2][0]["cell_id"]=="c1" and e[2][0]["event"]["kind"]=="execute_reply", timeout=5)
    cl.events.clear()
    cl.call("execute", {"session_id": sid, "cell_id": "c2"})
    ev = cl.wait_event(lambda e: e[0]==2 and e[1]=="cell_event" and e[2][0]["cell_id"]=="c2" and e[2][0]["event"]["kind"]=="execute_result", timeout=5)
    ok = ev is not None and "text/plain" in ev[2][0]["event"]["data"]
    report("c2 expression result text/plain", ok)
    cl.call("stop_kernel", {"session_id": sid})
    cl.stop()
    os.unlink(nb_path)


def t_run_cell_error():
    cl = Client()
    nb_path = tempfile.mktemp(suffix=".ipynb")
    json.dump(make_test_nb(), open(nb_path, "w"))
    _, res = cl.call("open", {"path": nb_path})
    sid = res["session_id"]
    cl.call("start_kernel", {"session_id": sid}, timeout=15)
    cl.events.clear()
    cl.call("execute", {"session_id": sid, "cell_id": "c3"})
    ev = cl.wait_event(lambda e: e[0]==2 and e[1]=="cell_event" and e[2][0]["cell_id"]=="c3" and e[2][0]["event"]["kind"]=="error", timeout=5)
    ok = ev is not None and ev[2][0]["event"]["ename"] == "ZeroDivisionError"
    report("c3 ZeroDivisionError", ok)
    cl.call("stop_kernel", {"session_id": sid})
    cl.stop()
    os.unlink(nb_path)


def t_save_roundtrip():
    cl = Client()
    nb_path = tempfile.mktemp(suffix=".ipynb")
    json.dump(make_test_nb(), open(nb_path, "w"))
    _, res = cl.call("open", {"path": nb_path})
    sid = res["session_id"]
    cl.call("start_kernel", {"session_id": sid}, timeout=15)
    cl.call("execute", {"session_id": sid, "cell_id": "c1"})
    cl.wait_event(lambda e: e[0]==2 and e[1]=="cell_event" and e[2][0]["cell_id"]=="c1" and e[2][0]["event"]["kind"]=="execute_reply", timeout=5)
    err, _ = cl.call("save", {"session_id": sid})
    report("save returns ok", err is None, str(err))
    saved = json.load(open(nb_path))
    cell_c1 = next(c for c in saved["cells"] if c["id"] == "c1")
    ok = cell_c1["execution_count"] == 1 and any(o["output_type"] == "stream" for o in cell_c1["outputs"])
    report("save preserves c1 stream output", ok)
    cl.call("stop_kernel", {"session_id": sid})
    cl.stop()
    os.unlink(nb_path)


def t_image_output():
    cl = Client()
    nb_path = tempfile.mktemp(suffix=".ipynb")
    nb = make_test_nb()
    nb["cells"].append({
        "cell_type": "code", "id": "c4", "metadata": {},
        "source": "import matplotlib\nmatplotlib.use('Agg')\nimport matplotlib.pyplot as plt\n%matplotlib inline\nfig, ax = plt.subplots()\nax.plot([1,2,3])\nplt.show()",
        "execution_count": None, "outputs": [],
    })
    json.dump(nb, open(nb_path, "w"))
    _, res = cl.call("open", {"path": nb_path})
    sid = res["session_id"]
    cl.call("start_kernel", {"session_id": sid}, timeout=15)
    cl.events.clear()
    cl.call("execute", {"session_id": sid, "cell_id": "c4"})
    ev = cl.wait_event(lambda e: e[0]==2 and e[1]=="cell_event"
                       and e[2][0]["cell_id"]=="c4"
                       and e[2][0]["event"]["kind"]=="display_data"
                       and "image/png" in (e[2][0]["event"].get("data") or {}), timeout=15)
    ok = ev is not None
    if ok:
        b64 = ev[2][0]["event"]["data"]["image/png"]
        ok = isinstance(b64, str) and len(b64) > 100
    report("c4 produces image/png display_data", ok)
    cl.call("stop_kernel", {"session_id": sid})
    cl.stop()
    os.unlink(nb_path)


def t_insert_delete_move():
    cl = Client()
    nb_path = tempfile.mktemp(suffix=".ipynb")
    json.dump(make_test_nb(), open(nb_path, "w"))
    _, res = cl.call("open", {"path": nb_path})
    sid = res["session_id"]

    err, ins = cl.call("insert_cell", {"session_id": sid, "after_index": 1, "cell_type": "markdown"})
    report("insert_cell returns id", err is None and "cell_id" in (ins or {}), str(err))
    new_id = ins["cell_id"]

    err, snap = cl.call("snapshot", {"session_id": sid})
    ok = err is None and len(snap["cells"]) == 5
    report("snapshot shows 5 cells after insert", ok)

    err, _ = cl.call("delete_cell", {"session_id": sid, "cell_id": new_id})
    report("delete_cell removes inserted", err is None, str(err))

    err, snap = cl.call("snapshot", {"session_id": sid})
    report("snapshot back to 4 after delete", err is None and len(snap["cells"]) == 4)

    err, mv = cl.call("move_cell", {"session_id": sid, "cell_id": "c2", "delta": -1})
    report("move_cell up returns new index", err is None and mv.get("new_index") is not None, str(err))

    cl.stop()
    os.unlink(nb_path)


def t_silent_execute():
    cl = Client()
    nb_path = tempfile.mktemp(suffix=".ipynb")
    json.dump(make_test_nb(), open(nb_path, "w"))
    _, res = cl.call("open", {"path": nb_path})
    sid = res["session_id"]
    cl.call("start_kernel", {"session_id": sid}, timeout=15)
    err, _ = cl.call("execute_silent", {"session_id": sid, "code": "secret_var = 999"})
    report("execute_silent returns", err is None, str(err))
    # Verify the variable was set by running a follow-up that prints it
    cl.events.clear()
    cl.call("execute", {"session_id": sid, "cell_id": "c1"})  # use cell to send arbitrary code
    cl.call("update_cell_source", {"session_id": sid, "cell_id": "c1", "source": "print(secret_var)"})
    cl.events.clear()
    cl.call("execute", {"session_id": sid, "cell_id": "c1"})
    ev = cl.wait_event(lambda e: e[0]==2 and e[1]=="cell_event" and e[2][0]["cell_id"]=="c1" and e[2][0]["event"]["kind"]=="stream", timeout=5)
    ok = ev is not None and ev[2][0]["event"]["text"].rstrip() == "999"
    report("execute_silent state visible to next execute", ok)
    cl.call("stop_kernel", {"session_id": sid})
    cl.stop()
    os.unlink(nb_path)


# ── kernel-cleanup helpers ──────────────────────────────────────────────
def _child_pids(ppid):
    out = subprocess.run(["pgrep", "-P", str(ppid)], capture_output=True, text=True).stdout
    return [int(x) for x in out.split()]


def _proc_cmd(pid):
    return subprocess.run(["ps", "-p", str(pid), "-o", "command="],
                          capture_output=True, text=True).stdout.strip()


def _alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def _kernel_pids_of(core_pid):
    # The ipykernel process is a direct child of jupynvim-core.
    return [p for p in _child_pids(core_pid) if "ipykernel" in _proc_cmd(p)]


def _wait_all_dead(pids, timeout=6):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if not any(_alive(p) for p in pids):
            return []
        time.sleep(0.1)
    return [p for p in pids if _alive(p)]


def _kernel_cleanup_case(name, terminate):
    """Start a kernel, trigger terminate(client), assert the kernel process dies.

    Reproduces the leak where core exits but orphans its ipykernel (the procs
    that pile up as PPID-1). Without explicit kill on disconnect/signal, the
    kernel survives and this fails.
    """
    cl = Client()
    nb_path = tempfile.mktemp(suffix=".ipynb")
    json.dump(make_test_nb(), open(nb_path, "w"))
    _, res = cl.call("open", {"path": nb_path})
    sid = res["session_id"]
    cl.call("start_kernel", {"session_id": sid}, timeout=15)
    time.sleep(0.5)
    kpids = _kernel_pids_of(cl.p.pid)
    if not kpids:
        report(name, False, "no kernel process found to test")
        cl.stop()
        os.unlink(nb_path)
        return
    cl._stop = True
    terminate(cl)
    try:
        cl.p.wait(timeout=10)
    except subprocess.TimeoutExpired:
        cl.p.kill()
    survivors = _wait_all_dead(kpids)
    report(name, not survivors, f"orphaned kernels: {survivors}")
    for p in survivors:  # don't let a failing test leak the kernel itself
        try:
            os.kill(p, 9)
        except OSError:
            pass
    os.unlink(nb_path)


def t_kernel_killed_on_disconnect():
    # Frontend (nvim) exiting closes core's stdin. Core must kill its kernel.
    _kernel_cleanup_case(
        "kernel killed on frontend disconnect (stdin EOF)",
        lambda cl: cl.p.stdin.close(),
    )


def t_kernel_killed_on_sigterm():
    # Core receiving SIGTERM must kill its kernel before exiting.
    _kernel_cleanup_case(
        "kernel killed on SIGTERM",
        lambda cl: cl.p.send_signal(signal.SIGTERM),
    )


TESTS = [
    t_ping, t_list_kernels, t_open_close, t_kernel_lifecycle,
    t_run_cell_streams, t_run_cell_expression, t_run_cell_error,
    t_save_roundtrip, t_image_output, t_insert_delete_move, t_silent_execute,
    t_kernel_killed_on_disconnect, t_kernel_killed_on_sigterm,
]


if __name__ == "__main__":
    print(f"backend integration tests ({len(TESTS)} cases)")
    for t in TESTS:
        try:
            t()
        except Exception as e:
            report(t.__name__, False, f"crash: {e!r}")
    print(f"\nbackend: {PASS}/{PASS+FAIL} passed")
    sys.exit(0 if FAIL == 0 else 1)

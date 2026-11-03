#!/usr/bin/env python3
"""
Backend integration tests: drive jupynvim-core directly via length-prefixed
msgpack-rpc on stdin/stdout. Verifies wire protocol, kernel lifecycle,
notebook ops, output streaming, save round-trip.
"""
import json
import os
import shutil
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
    print(f"  {sym} {name}{(' -- ' + detail) if detail and not ok else ''}")


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


def tmp_nb():
    # A new, already created file in $TMPDIR: mkstemp picks the name and
    # creates the file in one step, so no other process can take the name in
    # between (tempfile.mktemp only picks a name).
    fd, p = tempfile.mkstemp(suffix=".ipynb")
    os.close(fd)
    return p


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
    nb_path = tmp_nb()
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
    nb_path = tmp_nb()
    json.dump(make_test_nb(), open(nb_path, "w"))
    _, res = cl.call("open", {"path": nb_path})
    sid = res["session_id"]
    err, res2 = cl.call("start_kernel", {"session_id": sid}, timeout=15)
    report("start_kernel returns", err is None, str(err))
    # the frontend gates python-only behavior on the kernel that started
    res2 = res2 or {}
    report("start_kernel reports the kernel's language", res2.get("language") == "python",
           str(res2.get("language")))
    argv = res2.get("argv") or []
    report("start_kernel reports the kernel's argv", bool(argv) and "python" in argv[0].lower(),
           str(argv[:1]))
    err, _ = cl.call("stop_kernel", {"session_id": sid})
    report("stop_kernel returns", err is None, str(err))
    cl.stop()
    os.unlink(nb_path)


def t_run_cell_streams():
    cl = Client()
    nb_path = tmp_nb()
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
    nb_path = tmp_nb()
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
    nb_path = tmp_nb()
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
    nb_path = tmp_nb()
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
    nb_path = tmp_nb()
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
    nb_path = tmp_nb()
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
    nb_path = tmp_nb()
    json.dump(make_test_nb(), open(nb_path, "w"))
    _, res = cl.call("open", {"path": nb_path})
    sid = res["session_id"]
    cl.call("start_kernel", {"session_id": sid}, timeout=15)
    err, _ = cl.call("execute_silent", {"session_id": sid, "code": "secret_var = 999"})
    report("execute_silent returns", err is None, str(err))
    # Verify the variable was set by running a follow-up that prints it.
    # Only ONE execute here: an earlier version ran the cell before rewriting
    # its source, and that run's "hi" raced the events.clear() below. Whichever
    # stream landed first won, so the assert compared "hi" to "999" and the
    # case failed at random, more often on a loaded machine.
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
    nb_path = tmp_nb()
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


# ── Pixi environments (#47) ─────────────────────────────────────────────
# A project that holds its interpreter in .pixi/envs/default is used by
# auto_venv like a .venv, but only when ipykernel is installed there.
def _kernel_python():
    # The interpreter the suite's python3 kernel runs on (tests/lib/test_env.sh).
    return os.environ.get("JNV_KERNEL_PYTHON")


def _same_dir(a, b):
    return os.path.realpath(os.path.dirname(a)) == os.path.realpath(os.path.dirname(b))


def _pixi_env_with_kernel(env, py):
    """An env at `env` whose bin/python is `py` and that registers the python3 kernel."""
    (env / "bin").mkdir(parents=True)
    os.symlink(py, env / "bin" / "python")
    kdir = env / "share" / "jupyter" / "kernels" / "python3"
    kdir.mkdir(parents=True)
    (kdir / "kernel.json").write_text(json.dumps({
        "argv": ["python", "-m", "ipykernel_launcher", "-f", "{connection_file}"],
        "display_name": "Python 3 (ipykernel)", "language": "python",
    }))


def _open_in(root_nb):
    cl = Client()
    json.dump(make_test_nb(), open(root_nb, "w"))
    _, res = cl.call("open", {"path": str(root_nb)})
    return cl, res["session_id"]


def t_pixi_auto_venv():
    py = _kernel_python()
    if not py:
        report("pixi auto_venv: JNV_KERNEL_PYTHON is set", False, "run through tests/lib/test_env.sh")
        return
    root = Path(tempfile.mkdtemp(prefix="jnv-pixi-"))
    cl = None
    try:
        env = root / "proj" / ".pixi" / "envs" / "default"
        _pixi_env_with_kernel(env, py)
        cl, sid = _open_in(root / "proj" / "nb.ipynb")
        err, st = cl.call("start_kernel", {"session_id": sid, "auto_venv": True}, timeout=30)
        argv = (st or {}).get("argv") or []
        want = str(env / "bin" / "python")
        report("pixi auto_venv: the kernel runs on the Pixi env's python",
               err is None and bool(argv) and _same_dir(argv[0], want)
               and os.path.basename(argv[0]) == "python",
               f"err={err} argv0={argv[:1]} want {want}")
        cl.call("update_cell_source", {"session_id": sid, "cell_id": "c1", "source": "import sys; print(1)"})
        cl.events.clear()
        cl.call("execute", {"session_id": sid, "cell_id": "c1"})
        ev = cl.wait_event(lambda e: e[0] == 2 and e[1] == "cell_event" and e[2][0]["cell_id"] == "c1"
                           and e[2][0]["event"]["kind"] == "stream", timeout=15)
        report("pixi auto_venv: a cell runs on it",
               ev is not None and ev[2][0]["event"]["text"].rstrip() == "1", "no stream event" if ev is None else "")
        cl.call("stop_kernel", {"session_id": sid})
    finally:
        if cl:
            cl.stop()
        shutil.rmtree(root, ignore_errors=True)


def t_pixi_without_ipykernel():
    py = _kernel_python()
    if not py:
        report("pixi without ipykernel: JNV_KERNEL_PYTHON is set", False, "run through tests/lib/test_env.sh")
        return
    root = Path(tempfile.mkdtemp(prefix="jnv-pixi-"))
    cl = None
    try:
        # an outer .venv that has a kernel, and a closer Pixi env whose python
        # has no ipykernel (a script that fails any use, and no kernels dir)
        outer = root / ".venv"
        _pixi_env_with_kernel(outer, py)
        pixi_py = root / "proj" / ".pixi" / "envs" / "default" / "bin" / "python"
        pixi_py.parent.mkdir(parents=True)
        pixi_py.write_text("#!/bin/sh\nexit 1\n")
        pixi_py.chmod(0o755)
        cl, sid = _open_in(root / "proj" / "nb.ipynb")
        err, st = cl.call("start_kernel", {"session_id": sid, "auto_venv": True}, timeout=30)
        argv = (st or {}).get("argv") or []
        a0 = argv[0] if argv else ""
        report("pixi without ipykernel: the Pixi python is not used", err is None and bool(argv)
               and not a0.startswith(str(pixi_py.parent)) and not _same_dir(a0, str(pixi_py)),
               f"err={err} argv0={a0}")
        report("pixi without ipykernel: the outer .venv is not taken in its place",
               err is None and bool(argv) and not _same_dir(a0, str(outer / "bin" / "python")),
               f"argv0={a0}")
        msgs = [e for e in cl.events if isinstance(e, list) and len(e) > 2 and e[0] == 2 and e[1] == "user_message"]
        installing = [m for m in msgs if "installing ipykernel" in json.dumps(m[2])]
        report("pixi without ipykernel: no ipykernel is installed into it", not installing, str(installing[:1]))
        cl.call("stop_kernel", {"session_id": sid})
    finally:
        if cl:
            cl.stop()
        shutil.rmtree(root, ignore_errors=True)


def t_pixi_python_path():
    py = _kernel_python()
    if not py:
        report("pixi python_path: JNV_KERNEL_PYTHON is set", False, "run through tests/lib/test_env.sh")
        return
    root = Path(tempfile.mkdtemp(prefix="jnv-pixi-"))
    cl = None
    try:
        env = root / "proj" / ".pixi" / "envs" / "default"
        _pixi_env_with_kernel(env, py)
        cl, sid = _open_in(root / "proj" / "nb.ipynb")
        err, st = cl.call("start_kernel", {"session_id": sid, "python_path": str(env / "bin" / "python")},
                          timeout=30)
        report("pixi python_path: the kernel is named pixi-python",
               err is None and (st or {}).get("kernel_name") == "pixi-python",
               f"err={err} kernel_name={(st or {}).get('kernel_name')}")
        cl.call("stop_kernel", {"session_id": sid})
    finally:
        if cl:
            cl.stop()
        shutil.rmtree(root, ignore_errors=True)


TESTS = [
    t_ping, t_list_kernels, t_open_close, t_kernel_lifecycle,
    t_run_cell_streams, t_run_cell_expression, t_run_cell_error,
    t_save_roundtrip, t_image_output, t_insert_delete_move, t_silent_execute,
    t_kernel_killed_on_disconnect, t_kernel_killed_on_sigterm,
    t_pixi_auto_venv, t_pixi_without_ipykernel, t_pixi_python_path,
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
